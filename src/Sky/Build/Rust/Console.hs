{-# LANGUAGE ScopedTypeVariables #-}

-- | Epic A1 — build the bundled Sky Console as a standalone Rust binary at the
-- user's `sky build --target rust` time, cached once per sky version, so the
-- Live runtime's reverse-proxy (`live/console_proxy.rs`) can spawn it. NEVER a
-- runtime build — the only reason the Go backend dropped its subprocess console
-- (see `runtime-rust/README.md` §"divergent strategies").
--
-- Flow: materialise the TH-embedded console source (`Sky.Build.EmbeddedConsole`)
-- into a version-keyed cache build dir, recursively invoke THIS sky binary
-- (`getExecutablePath`) with `build --target rust`, and copy the resulting
-- binary to `~/.cache/sky/rust-console/<version>/sky-console` (the exact path
-- `console_bin_path()` resolves at runtime). Cache hit → no-op.
--
-- The whole thing is best-effort: any failure (no cargo, build error, no HOME)
-- logs a warning and returns — the runtime proxy then falls back to the
-- in-process console. A failed pre-build must never fail the user's own build.
module Sky.Build.Rust.Console
    ( ensureConsoleBinary
    ) where

import Control.Exception (SomeException, try)
import Control.Monad (forM_, when, filterM)
import qualified Crypto.Hash.SHA256 as SHA256
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Char (toLower)
import Data.List (sortOn)
import Numeric (showHex)
import System.Directory
    ( createDirectoryIfMissing, doesDirectoryExist, doesFileExist
    , getCurrentDirectory, getHomeDirectory, listDirectory
    , removePathForcibly, renameFile, copyFile )
import System.Environment (getEnvironment, getExecutablePath, lookupEnv)
import System.Exit (ExitCode(..))
import System.FilePath (takeDirectory, takeExtension, (</>))
import System.IO (hPutStrLn, stderr)
import System.Process
    ( CreateProcess(..), proc, readCreateProcessWithExitCode )

import Sky.Build.EmbeddedConsole (embeddedConsoleApp)

-- | Env var set on the recursive console build so its own post-build hook does
-- NOT try to build the console again (infinite recursion). Mirrors the Go
-- backend's `SKY_BUILD_IS_INLINE_CONSOLE` guard.
recursionGuardEnv :: String
recursionGuardEnv = "SKY_BUILD_IS_CONSOLE"

-- | Opt-out: `SKY_CONSOLE_PREBUILD=off|0|false` skips the pre-build entirely
-- (the in-process console still serves).
prebuildOptOutEnv :: String
prebuildOptOutEnv = "SKY_CONSOLE_PREBUILD"

-- | Cache layout under the user's home (must match `console_bin_path()` in
-- `live/console_proxy.rs`, which resolves `$HOME/.cache/sky/rust-console/<ver>/sky-console`).
consoleCacheDir :: String -> IO FilePath
consoleCacheDir ver = do
    home <- getHomeDirectory
    return (home </> ".cache" </> "sky" </> "rust-console" </> ver)

-- | Ensure the pre-built console binary exists in the version-keyed cache.
-- Non-fatal end to end: never throws, never fails the caller's build.
ensureConsoleBinary :: String -> IO ()
ensureConsoleBinary ver = do
    guard   <- lookupEnv recursionGuardEnv
    optOut  <- lookupEnv prebuildOptOutEnv
    let isOff v = map toLower v `elem` ["off", "0", "false", "no"]
    case () of
        _ | maybe False (not . null) guard -> return ()          -- building the console itself
          | maybe False isOff optOut       -> return ()          -- user opted out
          | otherwise -> do
                r <- try (buildIfMissing ver)
                case r of
                    Right () -> return ()
                    Left (e :: SomeException) ->
                        hPutStrLn stderr $
                            "[sky.console] pre-build skipped (" ++ show e
                            ++ "); the in-process console will serve instead"

buildIfMissing :: String -> IO ()
buildIfMissing ver = do
    cacheDir <- consoleCacheDir ver
    let cacheBin = cacheDir </> "sky-console"
        fpFile   = cacheDir </> ".fingerprint"
    -- Validate the cache by a CONTENT fingerprint, not just existence. The
    -- version dir keys releases apart, but the Rust backend is currently
    -- dev-only (SKY_VERSION == "dev" always — the runtime is sourced from disk,
    -- never embedded), so a version-only key would never invalidate as the
    -- console/runtime source evolves. The fingerprint (console source + the
    -- runtime .rs it compiles against) makes the cache rebuild on any change.
    want <- computeFingerprint
    binOk <- doesFileExist cacheBin
    fpOk  <- if binOk
                then do
                    r <- try (readFile fpFile) :: IO (Either SomeException String)
                    return (either (const False) ((== want) . trimNL) r)
                else return False
    if binOk && fpOk
        then return ()
        else buildConsole ver cacheDir cacheBin fpFile want

-- | Fingerprint of everything that determines the console binary: the embedded
-- console source + the runtime `.rs` sources it compiles against (when present
-- on disk — dev). Stable per release (console source pinned), changes on any dev
-- edit. SHA-256 over sorted (path, bytes), hex-truncated.
computeFingerprint :: IO String
computeFingerprint = do
    runtimeBytes <- runtimeSourceBytes
    let consoleBytes = [ (p, b) | (p, b) <- embeddedConsoleApp ]
        allParts = sortOn fst (consoleBytes ++ runtimeBytes)
        combined = BS.concat (concatMap (\(p, b) -> [ pack p, b ]) allParts)
        digest   = SHA256.hash combined
    return (take 16 (concatMap pad2 (BS.unpack digest)))
  where
    pad2 w = let s = showHex w "" in if length s == 1 then '0' : s else s
    pack   = BS.pack . map (fromIntegral . fromEnum)

-- | Read the runtime `.rs` sources (one level deep, matching what
-- `copyRustRuntime` copies into a generated project) so a runtime edit
-- invalidates the console cache. `[]` when the dir can't be located (release:
-- no on-disk runtime — fine, the version key handles release).
runtimeSourceBytes :: IO [(FilePath, ByteString)]
runtimeSourceBytes = do
    mDir <- locateRuntimeSrc
    case mDir of
        Nothing  -> return []
        Just dir -> do
            top <- readRsIn dir
            entries <- listDirectory dir
            subDirs <- filterM (doesDirectoryExist . (dir </>)) entries
            subs <- concat <$> mapM (\s -> readRsIn (dir </> s)) subDirs
            return (top ++ subs)
  where
    readRsIn d = do
        present <- doesDirectoryExist d
        if not present then return [] else do
            names <- listDirectory d
            let rs = filter (\f -> takeExtension f `elem` [".rs", ".js"]) names
            mapM (\n -> do b <- BS.readFile (d </> n); return (d </> n, b)) rs

-- | Locate `runtime-rust/src/sky_runtime` by walking up from the sky exe, then
-- the cwd — the same resolution `copyRustRuntime` uses, so we fingerprint the
-- exact tree that gets compiled into the console.
locateRuntimeSrc :: IO (Maybe FilePath)
locateRuntimeSrc = do
    exe <- getExecutablePath
    cwd <- getCurrentDirectory
    let walk d = do
            let cand = d </> "runtime-rust" </> "src" </> "sky_runtime"
            ok <- doesDirectoryExist cand
            if ok then return (Just cand)
            else if takeDirectory d == d then return Nothing else walk (takeDirectory d)
    fromExe <- walk (takeDirectory exe)
    case fromExe of
        Just p  -> return (Just p)
        Nothing -> walk cwd

trimNL :: String -> String
trimNL = reverse . dropWhile (`elem` "\r\n ") . reverse

buildConsole :: String -> FilePath -> FilePath -> FilePath -> String -> IO ()
buildConsole ver cacheDir cacheBin fpFile fingerprint = do
    skyBin <- getExecutablePath
    let buildDir = cacheDir </> "build"
    -- Fresh build dir (a previous partial build may have left a stale tree).
    removePathForcibly buildDir
    createDirectoryIfMissing True buildDir
    forM_ embeddedConsoleApp $ \(rel, bytes) -> do
        let dst = buildDir </> rel
        createDirectoryIfMissing True (takeDirectory dst)
        BS.writeFile dst bytes

    hPutStrLn stderr $
        "[sky] pre-building the bundled console for sky " ++ ver
        ++ " (rebuilds on console/runtime change; set " ++ prebuildOptOutEnv ++ "=off to skip)..."

    -- Build profile: DEBUG today. The Rust backend is dev-only (no embedded
    -- runtime), so the cache is fingerprint-invalidated and rebuilt on every
    -- console/runtime edit — debug keeps that fast, and binary size is moot on a
    -- dev box. When the Rust backend gains a shipping path (embedded runtime +
    -- versioned releases), switch to `--release` for the version-keyed,
    -- build-once console artifact (smaller + faster startup).

    -- Isolated env: drop CARGO_TARGET_DIR so the console builds into its own
    -- buildDir/sky-out/Rust/target (every generated crate is "sky-app" — sharing
    -- the user's target dir would clobber their binary). Keep RUSTC_WRAPPER so
    -- sccache still de-dupes the shared deps (axum/tokio/sqlx) at the rustc
    -- level. Set the recursion guard so the child build skips THIS hook.
    baseEnv <- getEnvironment
    let childEnv =
            (recursionGuardEnv, "1")
            : filter ((/= "CARGO_TARGET_DIR") . fst) baseEnv
        cp = (proc skyBin ["build", "src/Main.sky", "--target", "rust"])
                 { cwd = Just buildDir, env = Just childEnv }
    (ec, _out, errOut) <- readCreateProcessWithExitCode cp ""
    case ec of
        ExitFailure _ ->
            hPutStrLn stderr $
                "[sky.console] console pre-build failed; the in-process console will serve.\n"
                ++ unlines (lastN 8 (lines errOut))
        ExitSuccess -> do
            let built = buildDir </> "sky-out" </> "Rust" </> "target" </> "debug" </> "sky-app"
            builtExists <- doesFileExist built
            if not builtExists
                then hPutStrLn stderr
                        "[sky.console] console pre-build produced no binary; the in-process console will serve."
                else do
                    createDirectoryIfMissing True (takeDirectory cacheBin)
                    -- Atomic publish: copy to a sibling temp then rename into place
                    -- (rename is atomic on the same filesystem), so a concurrent
                    -- build can never observe a half-copied binary.
                    let tmpBin = cacheBin ++ ".tmp"
                    copyFile built tmpBin
                    renameFile tmpBin cacheBin
                    -- Record the fingerprint so the next build can validate the
                    -- cache (write AFTER the binary is in place; a crash between
                    -- the two leaves a stale-but-detectable fingerprint mismatch
                    -- → safe rebuild, never a false hit).
                    writeFile fpFile fingerprint
                    -- Reclaim the (large) build tree; the cached binary is all we keep.
                    removePathForcibly buildDir
                    hPutStrLn stderr $ "[sky.console] cached → " ++ cacheBin

lastN :: Int -> [a] -> [a]
lastN n xs = drop (length xs - n) xs
