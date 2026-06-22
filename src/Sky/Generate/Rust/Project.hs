{-# LANGUAGE OverloadedStrings #-}
-- | Rust-target project codegen orchestration: emit main.rs + module files,
-- copy the runtime, write Cargo.toml, copy FFI bindings. Extracted from the
-- Compile.hs `BackendRust` branch (plus the Rust-only helpers `generateRust`
-- and `copyRustRuntime`) so upstream's Go-codegen block in Compile.hs stays
-- minimally wrapped and merges cleanly. Dependency is one-way: Compile.hs
-- imports this module, never the reverse.
module Sky.Generate.Rust.Project
    ( generateRustProject
    , generateRust
    , copyRustRuntime
    ) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Char as Char
import Data.List (isInfixOf, stripPrefix)
import Control.Monad (when)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import qualified Data.Foldable as Foldable
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory
    ( createDirectoryIfMissing, doesFileExist, doesDirectoryExist
    , copyFile, getCurrentDirectory, listDirectory )
import qualified System.Directory
import qualified System.Environment
import qualified System.Process
import qualified Control.Exception
import System.Exit (ExitCode(..))
import System.FilePath ((</>), takeDirectory, takeExtension)

import qualified Sky.AST.Source as Src
import qualified Sky.AST.Canonical as Can
import qualified Sky.Sky.ModuleName as ModuleName
import qualified Sky.Type.Solve as Solve
import qualified Sky.Generate.Rust.Builder as RustBuilder
import qualified Sky.Sky.Toml as Toml
import qualified Sky.Build.Dce as Dce
import qualified Sky.Build.Rust.Ffi as RustFfi


-- | Orchestrate Rust-target codegen for the whole program. `rawAliases` is the
-- contents of Compile.hs's global kernel-alias IORef (read by the caller and
-- passed in to avoid depending on that module-global here).
generateRustProject
    :: Toml.SkyConfig
    -> [Can.Module]                                                -- ^ all modules (entry : deps)
    -> Src.Module                                                  -- ^ entry source module
    -> Solve.SolvedTypes
    -> Map.Map (ModuleName.Canonical, String) (String, String)     -- ^ raw kernel aliases
    -> FilePath                                                    -- ^ output dir
    -> String                                                      -- ^ source hash
    -> Set.Set Dce.Ref                                             -- ^ whole-program reachable set (S4 FFI tree-shake)
    -> Bool                                                        -- ^ DCE disabled (SKY_DCE=0)
    -> [(String, String, String)]                                  -- ^ Wall #2: synthesised generic wrappers (kernelName, refName, source)
    -> IO (Either String FilePath)
generateRustProject config allMods entrySrcMod typesWithDeps rawAliases outDir srcHash reached dceDisabled genericWrappers = do
    let dbUrl = case Toml._dbDriver config of
            "sqlite" -> "sqlite:" ++ Toml._dbPath config ++ "?mode=rwc"
            _        -> Toml._dbPath config
        dbDriver = if null (Toml._dbDriver config) then "sqlite" else Toml._dbDriver config
        -- Derive a Rust-valid module name from the dep name.
        -- Replaces non-alphanumeric (including hyphens) with _.
        depToIdent = map (\c -> if Char.isAlphaNum c then c else '_')
        depSlugs = [ depToIdent (fst dep) ++ "_bindings"
                   | dep <- Toml._rustDeps config ]
        -- Wall #2 (A)-model: the synthesised generic wrappers (one per generic
        -- FFI fn, base-named, `<T: bounds>`) arrive pre-checked from Compile.hs
        -- (the per-instance bindability gate + the per-fn unmodellable-bound /
        -- malformed-stub gate both ran there). Aggregated into a single
        -- `sky_ffi_generics.rs` — SEPARATE from each crate's pre-generated
        -- `_bindings.rs`, which is untouched — declared via an extra slug only
        -- when there is at least one generic wrapper, and tree-shaken
        -- per-wrapper by its base `FfiRef`.
        hasGenerics = not (null genericWrappers)
        genericsSlug = "sky_ffi_generics"
        ffiSlugs = depSlugs ++ [ genericsSlug | hasGenerics ]
        kernelAliases = Map.mapKeys (\(cn, fn) -> (ModuleName._name cn, fn)) rawAliases
        -- sky.toml [live] config baked into the generated main() as env fallbacks
        -- (Go parity: rt.SetPortDefault + tomlSkyEnv "LIVE_STATIC_DIR"). The Rust
        -- Live runtime reads these via SKY_LIVE_*; env still wins (set-only-when-
        -- unset). `static` only baked when set → the runtime nests a ServeDir at
        -- /static. (Values are emitted via rustStringLit, so a path with quotes/
        -- spaces is escaped correctly — not via Haskell `show`.)
        liveDefaults = [ ("SKY_LIVE_PORT", show (Toml._livePort config)) ]
                    ++ [ ("SKY_LIVE_STATIC_DIR", Toml._liveStatic config)
                       | not (null (Toml._liveStatic config)) ]
        (rustCode, moduleFiles, usage0) = generateRust allMods entrySrcMod typesWithDeps dbUrl dbDriver ffiSlugs kernelAliases (Toml._liveStore config) (Toml._liveStorePath config) liveDefaults
        -- usesUuid is detected from Sky-module usage (Uuid.*), but a transitive
        -- reference can slip past it: importing Sky.Core.Pure emits its whole
        -- module incl. uuidV4/uuidV7 bindings that call the uuid_v4/uuid_v7
        -- kernels, even when the app only used Pure.systemArgs. The emitted Rust
        -- then references the kernel while usesUuid stays false → undefined
        -- (35-composite-generics). Scan the final emitted code for the kernel
        -- references and force the gate (pulls uuid_kernel + the uuid crate).
        -- An app that FFIs the uuid crate itself never emits the bare
        -- `uuid_v4`/`uuid_v7` kernel name, so this can't false-trigger it.
        allEmitted = rustCode ++ concatMap snd moduleFiles
        uuidReferenced = "uuid_v4" `isInfixOf` allEmitted || "uuid_v7" `isInfixOf` allEmitted
        usage = usage0 { RustBuilder.usesUuid = RustBuilder.usesUuid usage0 || uuidReferenced }
        rustDir = outDir </> "rust"
    createDirectoryIfMissing True rustDir
    let srcDir = rustDir </> "src"
        mainRustPath = srcDir </> "main.rs"
        cargoTomlPath = rustDir </> "Cargo.toml"
    createDirectoryIfMissing True srcDir
    copyRustRuntime outDir
    let configPath = srcDir </> "sky_runtime" </> "config.rs"
        usesDb = RustBuilder.usesDb usage
        dbPool = RustBuilder.dbPoolType dbDriver
        dbRow = RustBuilder.dbRowType dbDriver
        configCode = unlines
            ([ "// GENERATED by Sky compiler — do not edit" ] ++
             (if usesDb
              then [ "pub type DbPool = " ++ dbPool ++ ";"
                   , "pub type DbRow = " ++ dbRow ++ ";"
                   , "pub const SKY_DB_URL: &str = " ++ show dbUrl ++ ";"
                   , ""
                   -- sub-B.1: driver-specific helpers so db.rs stays backend-agnostic
                   ] ++ RustBuilder.dbBackendHelpers dbDriver
              else [ "// (no DB)" ]))
    writeFileIfChanged configPath configCode
    putStrLn $ "   Wrote " ++ configPath
    let modPath = srcDir </> "sky_runtime" </> "mod.rs"
        baseMods = ["// GENERATED by Sky compiler — do not edit"
                   ,"pub mod config;","pub mod core;","pub mod task;"
                   -- telemetry: the in-process log/error/request sink that
                   -- `log` feeds and the Sky.Live `console` serves. Always on.
                   ,"pub mod telemetry;"
                   ,"pub mod log;","pub mod trace;","pub mod system;","pub mod time;"
                   ,"pub mod random;","pub mod file;","pub mod crypto;"
                   -- Sky.Core.Path — pure, dependency-free (go-parity 2026-06-15)
                   ,"pub mod path;"
                   ,"pub mod json;"
                   -- Sub-project A — stdlib kernel modules (sub-A.1, A.2, A.4, A.6)
                   ,"pub mod encoding;","pub mod regex_kernel;","pub mod jwt;"
                   ,"pub mod decimal;"
                   -- Sub-A codegen completion — Ffi.* runtime polyfills
                   ,"pub mod ffi_polyfills;"
                   -- Sub-A.8 — runtime kernel coverage
                   ,"pub mod money;","pub mod math;","pub mod dict;","pub mod set;","pub mod string;"
                   ,"pub mod basics;","pub mod char_kernel;","pub mod list;","pub mod io;"
                   ,"pub mod stringify;"
                   -- v0.15.47 stdlib modules
                   ,"pub mod compression;","pub mod csv;","pub mod config_decode;"
                   -- Std.Cache — pure-std LRU+TTL, no external dep (always declared)
                   ,"pub mod cache;"]
        -- sub-C — Std.Auth requires db.rs + jwt; gated together
        -- telemetry_spill (#69 / epic D): the write-through SQLite spill the
        -- always-compiled telemetry sink dual-writes to. Gated on db (it needs
        -- sqlx + tokio); telemetry.rs's spill hook is the matching cfg-dispatch.
        dbMod = if usesDb then ["pub mod db;", "pub mod auth;", "pub mod telemetry_spill;"] else []
        baseUse = ["pub use config::*;","pub use core::*;"
                  ,"pub use task::*;","pub use log::*;","pub use trace::*;"
                  ,"pub use system::*;","pub use time::*;"
                  ,"pub use random::*;","pub use file::*;"
                  ,"pub use path::*;"
                  ,"pub use crypto::*;","pub use json::*;"
                  ,"pub use encoding::*;","pub use regex_kernel::*;"
                  ,"pub use jwt::*;","pub use decimal::*;"
                  ,"pub use ffi_polyfills::*;"
                  ,"pub use money::*;","pub use math::*;"
                  ,"pub use dict::*;","pub use set::*;","pub use string::*;"
                  ,"pub use basics::*;","pub use char_kernel::*;","pub use list::*;"
                  ,"pub use io::*;","pub use stringify::*;"
                  ,"pub use compression::*;","pub use csv::*;"
                  ,"pub use config_decode::*;","pub use cache::*;"]
        dbUse = if usesDb then ["pub use db::*;", "pub use auth::*;"] else []
        -- uuid_kernel only when Sky.Core.Uuid is used — it needs the uuid crate
        -- with v4+v7; including it unconditionally clashes with projects that
        -- FFI the uuid crate themselves with different features (e.g. 04-uuid).
        uuidMod = if RustBuilder.usesUuid usage then ["pub mod uuid_kernel;"] else []
        uuidUse = if RustBuilder.usesUuid usage then ["pub use uuid_kernel::*;"] else []
        -- Sub-D.1: Sky.Http.Server only when used (pulls axum at step 4).
        srvMod = if RustBuilder.usesHttpServer usage then ["pub mod server;", "pub mod server_stream;"] else []
        srvUse = if RustBuilder.usesHttpServer usage then ["pub use server::*;", "pub use server_stream::*;"] else []
        -- Sky.Core.Http client only when used (pulls reqwest). http_stream rides
        -- along — it shares the reqwest dep + the HttpRequest bridge struct.
        -- http_client.rs carries `ssrf_apply` (reqwest), which Std.Email's SES path
        -- reuses — so the MODULE is needed on usesHttp OR usesEmail. The Http kernel
        -- surface (`pub use http_client::*;`) + http_stream stay usesHttp-only (email
        -- calls `ssrf_apply` by full path, not the kernel glob).
        needsHttpClientMod = RustBuilder.usesHttp usage || RustBuilder.usesEmail usage
        httpMod = [ "pub mod http_client;" | needsHttpClientMod ]
                  ++ [ "pub mod http_stream;" | RustBuilder.usesHttp usage ]
        httpUse = [ "pub use http_client::*;" | RustBuilder.usesHttp usage ]
                  ++ [ "pub use http_stream::*;" | RustBuilder.usesHttp usage ]
        -- ssrf.rs: reqwest-free SSRF validators shared by http_client (reqwest) and
        -- ws_client (no reqwest). Present whenever any consumer compiles. No glob
        -- re-export — the fns are pub(crate), consumed via full `ssrf::…` path.
        ssrfMod = [ "pub mod ssrf;"
                  | RustBuilder.usesHttp usage || RustBuilder.usesEmail usage || RustBuilder.usesWsClient usage ]
        -- Std.Email only when used (pulls reqwest; mirrors http_client).
        emailMod = if RustBuilder.usesEmail usage then ["pub mod email;"] else []
        emailUse = if RustBuilder.usesEmail usage then ["pub use email::*;"] else []
        -- Sub-E: TEA (Cmd/Sub/Cli.program) only when used. Std.Live's live/mod.rs
        -- imports SkyCmd/SkySub from tea, so usesLive pulls tea too.
        teaMod = if RustBuilder.usesTea usage || RustBuilder.usesLive usage then ["pub mod tea;"] else []
        teaUse = if RustBuilder.usesTea usage || RustBuilder.usesLive usage then ["pub use tea::*;"] else []
        -- Sky.Core.WebSocket client only when used (pulls tokio-tungstenite).
        wscMod = if RustBuilder.usesWsClient usage then ["pub mod ws_client;"] else []
        wscUse = if RustBuilder.usesWsClient usage then ["pub use ws_client::*;"] else []
        -- Std.Html / Std.Ui render surface — the standalone, PURE `html` module
        -- (Html/Attribute/Event ADTs + render_html + htmlXxx kernels). A non-Live
        -- CLI/Tui app that renders via Html.toString needs ONLY this, no server,
        -- no tea, no tokio. The live module (below) re-exports from it, so Live
        -- apps pull it too. Declared before live so live's re-export resolves.
        -- The Tui Element renderer (`tui::render`) walks the `Html` tree, so the
        -- html module must be present whenever tui is — even for a String-view
        -- Tui app that uses no Std.Ui itself.
        htmlMod = if RustBuilder.usesHtml usage || RustBuilder.usesLive usage || RustBuilder.usesTui usage then ["pub mod html;"] else []
        htmlUse = if RustBuilder.usesHtml usage || RustBuilder.usesLive usage || RustBuilder.usesTui usage then ["pub use html::*;"] else []
        -- Std.Ui shared element tree. Declared (not glob-re-exported; generated
        -- code uses the qualified `sky_runtime::ui::*` path) whenever Std.Ui /
        -- Html UI is in play. The Tui Element renderer also needs it.
        uiMod = if RustBuilder.usesHtml usage || RustBuilder.usesLive usage || RustBuilder.usesTui usage then ["pub mod ui;"] else []
        -- Std.Live when used — live submodule (the Sky.Live server). Sky.Webview
        -- ALSO needs it: webview.rs reuses live::dispatch::{build_index,
        -- HandlerIndex} for its in-process IPC event bridge.
        needsLiveMod = RustBuilder.usesLive usage || RustBuilder.usesWebview usage
        liveMod = if needsLiveMod then ["pub mod live;"] else []
        liveUse = if needsLiveMod then ["pub use live::*;"] else []
        -- Std.Tui — terminal backend (pulls crossterm). Only when used.
        tuiMod = if RustBuilder.usesTui usage then ["pub mod tui;"] else []
        tuiUse = if RustBuilder.usesTui usage then ["pub use tui::{tui_app, tui_app_ui};"] else []
        webviewMod = if RustBuilder.usesWebview usage then ["pub mod webview;"] else []
        webviewUse = if RustBuilder.usesWebview usage then ["pub use webview::{webview_app, WebviewAppCfg, WebviewWindowCfg};"] else []
        modCode = unlines (baseMods ++ dbMod ++ uuidMod ++ srvMod ++ ssrfMod ++ httpMod ++ emailMod ++ teaMod ++ wscMod ++ htmlMod ++ uiMod ++ liveMod ++ tuiMod ++ webviewMod ++ baseUse ++ dbUse ++ uuidUse ++ srvUse ++ httpUse ++ emailUse ++ teaUse ++ wscUse ++ htmlUse ++ liveUse ++ tuiUse ++ webviewUse)
    writeFileIfChanged modPath modCode
    putStrLn $ "   Wrote " ++ modPath
    writeFileIfChanged mainRustPath rustCode
    putStrLn $ "   Wrote " ++ mainRustPath
    mapM_ (\(modName, modContent) -> do
        let modPath' = srcDir </> modName ++ ".rs"
        writeFileIfChanged modPath' modContent
        putStrLn $ "   Wrote " ++ modPath'
        ) moduleFiles
    let sqlxTls = Toml._sqlxTls config
        rustDeps = Toml._rustDeps config
    writeFileIfChanged cargoTomlPath (RustBuilder.emitCargoToml usage dbDriver sqlxTls rustDeps (Toml._liveStore config))
    putStrLn $ "   Wrote " ++ cargoTomlPath
    -- Copy Rust FFI binding files into sky-out/rust/src/, REACHABILITY-FILTERED
    -- (S4 FFI tree-shake). Slugs must match what generateRustBindings writes
    -- (via slugify). Rather than copy the whole cached `*_bindings.rs`, we drop
    -- the per-fn wrapper regions whose `FfiRef` key is not in the whole-program
    -- reachable set — so binding a 76k-symbol crate and calling 4 of them emits
    -- only those 4 wrappers, matching the Go backend's `dceFfiWrappers`.
    mapM_ (\(depName, _) -> do
        let fileSlug = map (\c -> if c `elem` ("./" :: String) then '_' else c) depName
            modSlug  = map (\c -> if Char.isAlphaNum c then c else '_') depName
            srcPath' = ".skycache/ffi/rust" </> fileSlug ++ "_bindings.rs"
            jsonPath' = ".skycache/ffi/rust" </> fileSlug ++ ".kernel.json"
            dstPath' = srcDir </> modSlug ++ "_bindings.rs"
        exists <- doesFileExist srcPath'
        when exists $ do
            written <- writeFilteredBindings srcPath' jsonPath' dstPath' reached dceDisabled
            putStrLn $ "   " ++ written ++ " " ++ srcPath'
        ) (Toml._rustDeps config)
    -- Wall #2 (A)-model: write the BUILD-synthesised generic wrappers into a
    -- SINGLE `sky_ffi_generics.rs` (separate from the per-crate `_bindings.rs`).
    -- Each wrapper is sentinel-wrapped and run through the SAME S4 tree-shake:
    -- emitted iff its base `FfiRef kernelName refName` is reached (or DCE off).
    -- The preamble mirrors a `_bindings.rs` (`use crate::*;` brings SkyResult /
    -- SkyError / ok_res / SkyMaybe; wrapper bodies reference crate types
    -- absolutely as `::crate::Type`). hasGenerics already added the matching
    -- `pub mod sky_ffi_generics;` to ffiSlugs, so this file is wired into the
    -- crate root only when it exists.
    when hasGenerics $ do
        let keepWrapper (kn, ref, _) =
                dceDisabled || Set.null reached
                    || Set.member (Dce.FfiRef kn ref) reached
            keptWrappers = filter keepWrapper genericWrappers
            wrapperBlocks =
                [ unlines
                    [ RustFfi.wrapperBeginSentinel ref
                    , src
                    , RustFfi.wrapperEndSentinel ]
                | (_, ref, src) <- keptWrappers ]
            genericsCode = unlines
                ([ "// GENERATED by Sky compiler (Wall #2 generic FFI) — do not edit"
                 , "#![allow(unused_imports, unused_mut, dead_code)]"
                 , "use crate::*;"
                 , "use std::collections::HashMap;"
                 , "" ] ++ wrapperBlocks)
            genericsPath = srcDir </> genericsSlug ++ ".rs"
        writeFileIfChanged genericsPath genericsCode
        putStrLn $ "   Wrote " ++ genericsPath
            ++ " (" ++ show (length keptWrappers) ++ " generic wrapper(s))"
    let cacheDir = ".skycache"
    createDirectoryIfMissing True cacheDir
    writeFile (cacheDir </> "source.hash") srcHash
    -- Best-effort: format the GENERATED Rust (NOT the already-formatted copied
    -- runtime modules) with rustfmt so `sky-out/rust/src` is human-readable — the
    -- codegen emits cramped Strings. rustfmt is syntactic (no type-check, no
    -- compile needed), so it runs before `cargo build`; the formatted file is
    -- what compiles AND what a human inspects, including when the build fails.
    -- `--edition 2021` is MANDATORY (rustfmt defaults to 2015 when invoked
    -- directly and would reject the 2021 syntax in the generated code).
    -- NEVER fails the build: a missing rustfmt or any non-zero exit is swallowed
    -- (readProcessWithExitCode doesn't throw on non-zero; `try` catches a missing
    -- binary; rustfmt leaves the file untouched on a parse error, so the valid
    -- output still stands). Opt out via SKY_RUST_FMT=0 (e.g. sky watch's hot loop).
    fmtOptOut <- System.Environment.lookupEnv "SKY_RUST_FMT"
    when (fmtOptOut /= Just "0") $ do
        let genRustFiles = mainRustPath : modPath : configPath
                         : [ srcDir </> modName ++ ".rs" | (modName, _) <- moduleFiles ]
        mapM_ rustfmtFileInPlace genRustFiles
    -- Match the Go path's v0.15.42 §3.4 fix: do NOT print "Compilation
    -- successful" here — this function only EMITS Rust sources; `cargo build`
    -- runs in the caller and is the real success gate. Printing success before
    -- the compiler runs is the misleading-success regression the project bans.
    putStrLn "Sky lowering succeeded"
    return (Right mainRustPath)


-- | Best-effort, RECURSION-FREE rustfmt of one GENERATED Rust file: pipe the file
-- through `rustfmt` on STDIN (no path arg ⇒ rustfmt can't recurse into `mod`
-- children — that recursion would re-format the already-formatted copied runtime
-- AND let one odd/unresolvable module silently abort the whole pass), then write
-- the result back ONLY on success. NEVER throws / never fails the build: a missing
-- rustfmt or a non-zero exit leaves the valid (unformatted) file untouched —
-- formatting is the lowest principle (readability) and must not risk correctness.
-- `--edition 2021` is mandatory (rustfmt defaults to edition 2015 on stdin).
rustfmtFileInPlace :: FilePath -> IO ()
rustfmtFileInPlace path = do
    exists <- doesFileExist path
    when exists $ do
        src <- readFile path
        _   <- Control.Exception.evaluate (length src)   -- force the read; close the handle before write-back
        res <- Control.Exception.try
                 (System.Process.readProcessWithExitCode "rustfmt" ["--edition", "2021"] src)
                 :: IO (Either Control.Exception.SomeException (ExitCode, String, String))
        case res of
            Right (ExitSuccess, out, _) | not (null out) -> writeFile path out
            _                                            -> return ()


-- | Run the Rust code generator over the whole canonicalised program.
generateRust :: [Can.Module] -> Src.Module -> Solve.SolvedTypes
    -> String -> String -> [String]
    -> Map.Map (String, String) (String, String)  -- kernel alias map (keys as strings)
    -> String -> String                            -- [live] store kind + store path
    -> [(String, String)]                          -- sky.toml [live] env defaults baked into main()
    -> (String, [(String, String)], RustBuilder.UsedKernels)
generateRust canMods _srcMod solvedTypes dbPath dbDriver ffiSlugs kernelAliases liveStore liveStorePath liveDefaults =
    -- v0.15: Solve.SolvedTypes became a record; the Rust codegen (RustBuilder)
    -- consumes the bare env map, so project the `_stEnv` field out.
    let builder = RustBuilder.buildProgram canMods
                                            (Solve._stEnv solvedTypes)
                                            (Solve._stPerModuleEnv solvedTypes)
                                            (Solve._stRegions solvedTypes)
                                            kernelAliases
                                            liveStore
                                            liveStorePath
        (code, moduleFiles) = RustBuilder.emitRust builder dbPath dbDriver ffiSlugs liveDefaults
        usage = RustBuilder.builderKernels builder
    in (code, moduleFiles, usage)


-- | Copy the Rust sky_runtime module into sky-out/rust/src/sky_runtime/
-- so `mod sky_runtime; use sky_runtime::*;` resolves at compile time.
copyRustRuntime :: FilePath -> IO ()
copyRustRuntime outDir = do
    let targetDir = outDir </> "rust" </> "src" </> "sky_runtime"
    createDirectoryIfMissing True targetDir
    exePath <- System.Environment.getExecutablePath
    -- Walk up from the exe directory looking for runtime-rust/src/sky_runtime/
    let dir = takeDirectory exePath
        walkUp d = do
            let candidate = d </> "runtime-rust" </> "src" </> "sky_runtime"
            ok <- doesDirectoryExist candidate
            if ok then return (Just candidate) else
                if takeDirectory d == d then return Nothing  -- reached filesystem root
                else walkUp (takeDirectory d)
    mSrcDir <- walkUp dir
    case mSrcDir of
        Nothing -> do
            -- Fallback: walk up from CWD to find the repo root
            cwd <- getCurrentDirectory
            let walkUpFromCwd d = do
                    let candidate = d </> "runtime-rust" </> "src" </> "sky_runtime"
                    ok <- doesDirectoryExist candidate
                    if ok then return (Just candidate)
                    else if takeDirectory d == d then return Nothing
                    else walkUpFromCwd (takeDirectory d)
            mCwdSrc <- walkUpFromCwd cwd
            case mCwdSrc of
                Just srcDir -> do
                    copyRuntimeDir srcDir targetDir
                Nothing -> putStrLn "  [warn] could not locate runtime-rust/src/sky_runtime/"
        Just srcDir -> copyRuntimeDir srcDir targetDir

-- | Copy all .rs files (plus the non-Rust assets the runtime include_str!'s,
-- e.g. live/client.js) from srcDir to targetDir, recursing into EVERY
-- subdirectory at arbitrary depth. Previously this was one level deep only,
-- so a grandchild dir (e.g. live/dispatch/) would be silently dropped →
-- E0583/E0432 cargo-fail with no compiler diagnostic. Full recursion removes
-- that footgun.
copyRuntimeDir :: FilePath -> FilePath -> IO ()
copyRuntimeDir srcDir targetDir = do
    total <- copyRuntimeDirRec srcDir targetDir
    putStrLn $ "   Copied runtime-rust/src/sky_runtime/ (" ++ show total ++ " files)"

-- | Recursive worker: copies the asset files in srcDir into targetDir, then
-- recurses into every real subdirectory. Returns the count of files copied.
-- | Copy `src`→`dst` ONLY when the byte content differs (or `dst` is absent).
-- `System.Directory.copyFile` always stamps `dst`'s mtime to NOW, so copying the
-- ~74 unchanged runtime files on every `sky build` made cargo's incremental
-- compiler treat the WHOLE `sky_runtime` as changed and recompile it each time —
-- the dominant cost of a `sky watch --backend rust` rebuild. Skipping the write
-- when content is identical preserves the mtime, so cargo recompiles only the
-- edited generated Sky code. (Content compare, not mtime, is the correct
-- discriminant: a same-mtime-different-content file must still be recopied; an
-- identical file must NOT be touched.)
copyFileIfChanged :: FilePath -> FilePath -> IO ()
copyFileIfChanged src dst = do
    exists <- doesFileExist dst
    same <- if exists
        then do
            a <- BS.readFile src
            b <- BS.readFile dst
            pure (a == b)
        else pure False
    when (not same) (copyFile src dst)

-- | Write `content` to `path` ONLY when it differs from what's already there.
-- Same rationale as copyFileIfChanged: a generated `.rs` rewritten with identical
-- content still bumps its mtime, which makes cargo re-codegen that module on every
-- `sky watch` rebuild. Skipping the no-op write lets cargo's incremental compiler
-- touch only the Sky modules that actually changed (the lowered stdlib
-- `sky_core_*.rs` never change between rebuilds of the same source). Byte-exact
-- UTF-8 compare + write: comparing as `String` via readFile'/writeFile is at the
-- mercy of the locale text codec and was NOT byte-exact; encoding to UTF-8 bytes
-- and comparing the raw bytes is definitive and locale-independent. NB: this only
-- pays off when rustfmt is OFF (SKY_RUST_FMT=0 — sky watch's hot loop); with
-- rustfmt on, the post-codegen reformat rewrites the file regardless.
writeFileIfChanged :: FilePath -> String -> IO ()
writeFileIfChanged path content = do
    let new = TE.encodeUtf8 (T.pack content)
    exists <- doesFileExist path
    same <- if exists then (== new) <$> BS.readFile path else pure False
    when (not same) (BS.writeFile path new)

-- ── S4: FFI-surface DCE (reachability filter) ────────────────────────────────
--
-- The cached `<slug>_bindings.rs` is written at `sky add` time with EVERY
-- discovered wrapper, each bracketed by `// SKY-FFI-WRAPPER BEGIN <ref>` …
-- `// SKY-FFI-WRAPPER END` sentinels (Sky.Build.Rust.Ffi). Everything OUTSIDE a
-- sentinel pair (the preamble, `use`s, opaque type aliases, all trait impls —
-- the Display/FromStr bridges) is PREAMBLE-class and kept unconditionally
-- (R-A/R-B). At BUILD time — when the whole-program reachable set is finally
-- known — we drop the wrapper regions whose `FfiRef` key is unreached.
--
-- KEYING (R-D). A wrapper's reached key is `Dce.FfiRef kernelName <ref>` where
-- `kernelName` is the kernel.json `"kernelName"` (the registry's
-- `_fm_kernelName`, e.g. "Rust_Fieldtest") and `<ref>` is the sentinel name (==
-- the kernel.json function `"name"` == `wrapperRefName fn`). The kernel.json is
-- the on-disk, key-aligned source of those keys (its `name`s ARE the keys by
-- construction), so the build-time key and the emitted item can never diverge.
--
-- FAIL-SAFE (R-3). FULL-EMIT (copy the file verbatim) on ANY of:
--   * `SKY_DCE=0` / `dceDisabled`,
--   * `Set.null reached` (no reachability info — same fallback as the Go path),
--   * a missing / unparseable kernel.json,
--   * a BIJECTION failure: a sentinel `<ref>` in the `.rs` that is NOT a unique
--     kernel.json `name`, or a duplicate sentinel name. Then the keying is
--     suspect and we MUST NOT drop on doubt.
--
-- STALENESS (R-4). This runs EVERY build from (sentinels ∩ reached); it is never
-- served from a `source.hash`-keyed cache, so a `Main.sky` edit that newly calls
-- `Foo.bar` re-includes `bar` on the next build. Cargo's own incremental tracker
-- handles the no-change case (writeFileIfChanged preserves the mtime on identity).
--
-- Returns a short verb ("Filtered" / "Copied") for the build log.
writeFilteredBindings
    :: FilePath           -- ^ cached `<slug>_bindings.rs`
    -> FilePath           -- ^ cached `<slug>.kernel.json`
    -> FilePath           -- ^ destination `<modSlug>_bindings.rs`
    -> Set.Set Dce.Ref    -- ^ whole-program reachable set
    -> Bool               -- ^ DCE disabled
    -> IO String
writeFilteredBindings srcPath jsonPath dstPath reached dceDisabled = do
    raw <- readFileUtf8 srcPath
    -- The set of every sentinel name physically present in the cached `.rs`.
    let emittedRefsList = sentinelNames raw
        emittedRefs = Set.fromList emittedRefsList
        duplicateSentinel = length emittedRefsList /= Set.size emittedRefs
        -- A balanced BEGIN/END structure is a precondition for `filterWrapperRegions`
        -- to span regions correctly. The emitter always pairs them, but a dangling
        -- BEGIN (or stray END) means the `.rs` is malformed — full-emit rather than
        -- risk dropping the unterminated remainder (R-3: never drop on doubt).
        beginCount = length emittedRefsList
        endCount = length (filter isEndSentinel (lines raw))
        sentinelsBalanced = beginCount == endCount
    if dceDisabled || Set.null reached
        then fullEmit raw "Copied"
        else do
            mMeta <- readKernelMeta jsonPath
            case mMeta of
                -- No / unparseable kernel.json → can't key soundly → full-emit.
                Nothing -> fullEmit raw "Copied"
                Just (kernelName, jsonNames) ->
                    let jsonNameSet = Set.fromList jsonNames
                        -- BIJECTION (R-D): every emitted sentinel must be a
                        -- unique kernel.json name; no duplicate sentinels; and
                        -- the BEGIN/END structure must be balanced.
                        bijectionOk =
                            not duplicateSentinel
                                && sentinelsBalanced
                                && emittedRefs `Set.isSubsetOf` jsonNameSet
                    in if not bijectionOk
                        then fullEmit raw "Copied"
                        else do
                            let keep ref = Set.member
                                    (Dce.FfiRef kernelName ref) reached
                                filtered = filterWrapperRegions keep raw
                            writeFileIfChanged dstPath filtered
                            pure "Filtered"
  where
    fullEmit raw verb = do
        writeFileIfChanged dstPath raw
        pure verb


-- | Read a UTF-8 text file (locale-independent), returning "" if absent.
readFileUtf8 :: FilePath -> IO String
readFileUtf8 path = do
    exists <- doesFileExist path
    if exists
        then (T.unpack . TE.decodeUtf8) <$> BS.readFile path
        else pure ""


-- | Every wrapper-reference name opened by a `// SKY-FFI-WRAPPER BEGIN <ref>`
-- line in the bindings text (whitespace-trimmed). rustfmt is NOT run on the
-- cached `.skycache/...` source (only on the generated `sky-out` files), so the
-- sentinel lines survive verbatim; we still tolerate leading indentation.
sentinelNames :: String -> [String]
sentinelNames txt =
    [ trimStr rest
    | line <- lines txt
    , let stripped = dropWhile (== ' ') line
    , Just rest <- [stripPrefix RustFfi.wrapperSentinelPrefix stripped]
    ]


-- | True for a wrapper END sentinel line (indentation-tolerant).
isEndSentinel :: String -> Bool
isEndSentinel line = dropWhile (== ' ') line == RustFfi.wrapperEndSentinel


-- | Keep only the wrapper regions whose ref satisfies `keep`; everything outside
-- any BEGIN/END pair is preamble-class and kept unconditionally (R-A/R-B). A
-- malformed nesting (a BEGIN with no END, or an END with no open BEGIN) is
-- treated conservatively as "keep" — we never silently swallow lines on doubt.
filterWrapperRegions :: (String -> Bool) -> String -> String
filterWrapperRegions keep txt = unlines (go (lines txt))
  where
    go [] = []
    go (line : rest) =
        let stripped = dropWhile (== ' ') line
        in case stripPrefix RustFfi.wrapperSentinelPrefix stripped of
            Just refRaw ->
                let ref = trimStr refRaw
                    (region, after) = spanRegion rest
                in if keep ref
                    then line : region ++ go after
                    else go after
            Nothing -> line : go rest

    -- Collect lines up to and INCLUDING the matching END sentinel. If no END is
    -- found (malformed), the rest is returned as the region (kept) — total, no
    -- silent drop.
    spanRegion [] = ([], [])
    spanRegion (l : ls) =
        let stripped = dropWhile (== ' ') l
        in if stripped == RustFfi.wrapperEndSentinel
            then ([l], ls)
            else let (reg, after) = spanRegion ls in (l : reg, after)


-- | Parse the kernel.json for its `"kernelName"` and the list of function
-- `"name"`s. Returns Nothing on a missing / unparseable file (→ full-emit).
readKernelMeta :: FilePath -> IO (Maybe (String, [String]))
readKernelMeta path = do
    exists <- doesFileExist path
    if not exists
        then pure Nothing
        else do
            bytes <- BS.readFile path
            case Aeson.decodeStrict' bytes :: Maybe Aeson.Value of
                Just (Aeson.Object o) ->
                    let kname = case KeyMap.lookup "kernelName" o of
                            Just (Aeson.String s) -> T.unpack s
                            _                     -> ""
                        names = case KeyMap.lookup "functions" o of
                            Just (Aeson.Array arr) ->
                                [ T.unpack s
                                | Aeson.Object fo <- foldrToList arr
                                , Just (Aeson.String s) <- [KeyMap.lookup "name" fo]
                                ]
                            _ -> []
                    in if null kname then pure Nothing else pure (Just (kname, names))
                _ -> pure Nothing
  where
    foldrToList = Foldable.toList


-- | Strip leading/trailing spaces.
trimStr :: String -> String
trimStr = f . f where f = reverse . dropWhile (== ' ')


copyRuntimeDirRec :: FilePath -> FilePath -> IO Int
copyRuntimeDirRec srcDir targetDir = do
    files <- listDirectory srcDir
    let assets = filter (\f -> takeExtension f `elem` [".rs", ".js"]) files
    mapM_ (\name -> copyFileIfChanged (srcDir </> name) (targetDir </> name)) assets
    -- Candidate subdirs: any entry that is a real directory. doesDirectoryExist
    -- is the discriminant (a plain file is probed then skipped).
    subCounts <- mapM (\sub -> do
        let srcSub = srcDir </> sub
            tgtSub = targetDir </> sub
        isDir <- doesDirectoryExist srcSub
        if isDir
            then do
                createDirectoryIfMissing True tgtSub
                copyRuntimeDirRec srcSub tgtSub
            else pure 0
        ) files
    pure (length assets + sum subCounts)
