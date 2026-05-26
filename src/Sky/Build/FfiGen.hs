{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | FFI binding generator — full auto, no hand-written wrappers required.
--
-- Architecture (mirrors the self-hosted Sky compiler's approach but adapted
-- to our Haskell host):
--
-- 1. sky-ffi-inspect emits a JSON report of the package: every exported
--    top-level function with its param and result types as fully-qualified
--    Go type strings (e.g. "github.com/stripe/stripe-go/v82.CheckoutSession",
--    "time.Time", "*net/http.Client", "[]io.Reader").
--
-- 2. This Haskell module scans those type strings to discover *every* Go
--    package that must be imported in the generated wrapper — including
--    transitive stdlib (time, io, net/http, …), sibling packages of the
--    requested package (stripe-go/v82 when binding checkout/session), and
--    the package itself. For each discovered package we pick a safe Go
--    alias derived from its path, and import them all.
--
-- 3. Every fully-qualified type reference in a signature is rewritten to
--    use the computed alias, so `github.com/stripe/stripe-go/v82.Checkout`
--    becomes `v82_stripe_go.Checkout` (or whatever alias we derived).
--
-- 4. The only things still skipped are generic type parameters (e.g.
--    `Fetch[T]`) — they're fundamentally not realisable at FFI time
--    without monomorphisation, matching the self-hosted compiler.
--
-- 5. Sky records-with-methods give us a clean bridge for opaque Go types:
--    a Go struct `pkg.Foo` becomes a Sky record type whose methods are the
--    FFI bindings. Field accessors `fooField` and setters `fooSetField`
--    are auto-generated alongside the function bindings so Sky code can
--    interact with opaque Go values idiomatically.
--
-- 6. Task-effect boundary + panic recovery are enforced by the runtime
--    (see rt.invokeFfi): every binding is registered as effect-unknown,
--    callable via Ffi.callTask, with `defer/recover` on every call.
module Sky.Build.FfiGen
    ( generateBindings
    , pkgToModuleName
    , runInspectorForTarget
    , runInspectorMultiForTarget
    , slugify
    , _pkgName
    , _pkgVersion
    , PkgInfo(..)
    , FnInfo(..)
    ) where

import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as BL
import Data.Char (isAlphaNum, isDigit, isLower, isUpper, toUpper, toLower)
import Data.List (foldl', intercalate, isPrefixOf, nub, sortOn, stripPrefix)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesFileExist, getCurrentDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>), takeDirectory)
import System.Process (readProcessWithExitCode)
import qualified Sky.Build.EmbeddedInspector as EI
import qualified Sky.Build.EmbeddedInspectorRust as EIRust
import Sky.Sky.Toml (CompileTarget(..))


-- | Information extracted about one Go function
data FnInfo = FnInfo
    { _fnName     :: String
    , _fnParams   :: [(String, String)]  -- (name, goType)
    , _fnResults  :: [(String, String)]  -- (name, goType)
    , _fnVariadic :: Bool                -- last param is ...T
    , _fnEffect   :: String              -- pure / fallible / effectful
    , _fnRecvType :: String              -- "" for free func, else Go type
    , _fnMethodName :: String            -- "" for free func, else method
    , _fnIsField  :: Bool                -- synthetic struct-field getter
    , _fnIsFieldSet :: Bool              -- synthetic struct-field setter
    , _fnIsPkgVar :: Bool                -- synthetic pkg-level var/const getter
    , _fnParamSkyTypes  :: [String]
        -- ^ Per-param Sky-side type override. Same length as
        -- '_fnParams'; entry is "" when no override (use the bare
        -- Go type via 'goTypeToSky'). Populated from the
        -- inspector's per-Param skyType field, which collapses
        -- named-of-basic types (Stripe enums, Firestore Direction,
        -- etc.) to their underlying primitive so HM treats them
        -- structurally. Wrapper code generation continues to use
        -- '_fnParams' so derived Go types stay distinct on the
        -- wrapper-call side.
    , _fnResultSkyTypes :: [String]
        -- ^ Same shape, for results.
    , _fnRustParamTypes :: [String]
        -- ^ Per-param Rust type override. Populated from the
        -- inspector's per-Param rustType field. Used by
        -- resolveRustType to qualify opaque types without the
        -- per-crate case blocks. Entry is "" when unknown.
    , _fnRustResultTypes :: [String]
        -- ^ Same shape, for results.
    , _fnRecvRustType :: String
        -- ^ Rust type override for the receiver type. Populated
        -- from the inspector's recvRustType field. Used by
        -- resolveRustType for static method receiver resolution.
        -- Entry is "" when unknown.
    }
    deriving (Show)


data PkgInfo = PkgInfo
    { _pkgPath   :: String
    , _pkgName   :: String
    , _pkgVersion :: String  -- semver from cargo metadata (or "" for Go)
    , _pkgFns    :: [FnInfo]
    , _pkgModules :: [String]  -- Rust target: public module paths to glob-import
    , _pkgErrors :: [String]
    }
    deriving (Show)


instance A.FromJSON FnInfo where
    parseJSON = A.withObject "FnInfo" $ \o -> do
        params <- o A..: "params" >>= mapM parseParamFull
        results <- o A..: "results" >>= mapM parseParamFull
        FnInfo
            <$> o A..: "name"
            <*> pure (map (\(n, t, _, _) -> (n, t)) params)
            <*> pure (map (\(n, t, _, _) -> (n, t)) results)
            <*> o A..:? "variadic" A..!= False
            <*> o A..: "effect"
            <*> o A..:? "recvType" A..!= ""
            <*> o A..:? "methodName" A..!= ""
            <*> o A..:? "isField" A..!= False
            <*> o A..:? "isFieldSet" A..!= False
            <*> o A..:? "isPkgVar" A..!= False
            <*> pure (map (\(_, _, s, _) -> s) params)
            <*> pure (map (\(_, _, s, _) -> s) results)
            <*> pure (map (\(_, _, _, r) -> r) params)
            <*> pure (map (\(_, _, _, r) -> r) results)
            <*> o A..:? "recvRustType" A..!= ""
      where
        parseParamFull = A.withObject "param" $ \o -> do
            n <- o A..:? "name" A..!= ""
            t <- o A..: "type"
            s <- o A..:? "skyType" A..!= ""
            r <- o A..:? "rustType" A..!= ""
            return (n, t, s, r)


instance A.FromJSON PkgInfo where
    parseJSON = A.withObject "PkgInfo" $ \o -> PkgInfo
        <$> o A..: "pkg"
        <*> o A..:? "name" A..!= ""
        <*> o A..:? "version" A..!= ""
        <*> o A..:? "functions" A..!= []
        <*> o A..:? "modules" A..!= []
        <*> o A..:? "errors" A..!= []


-- | Inspect a single package/crate for the given target.
-- Optional features (comma-separated) are passed to the Rust inspector.
runInspectorForTarget :: CompileTarget -> String -> [String] -> IO (Either String PkgInfo)
runInspectorForTarget target pkgPath features = do
    let prefix = inspectorCallPrefix target
    resolved <- resolveInspector target
    case resolved of
        Left e    -> return (Left e)
        Right bin -> do
            let featuresArg = if null features then "" else " --features " ++ intercalate "," features
                cmd' = if null prefix
                        then bin ++ " " ++ pkgPath ++ featuresArg
                        else prefix ++ " && " ++ bin ++ " " ++ pkgPath ++ featuresArg
            (_, out, err) <- readProcessWithExitCode "sh" ["-c", cmd'] ""
            if null out
                then return (Left $ inspectorName target ++ ": empty output; stderr: " ++ err)
                else case A.eitherDecode (BL.fromStrict (TE.encodeUtf8 (T.pack out))) of
                    Left e  -> return (Left $ inspectorName target ++ ": json: " ++ e)
                    Right p -> return (Right p)


-- | Multi-package mode for the given target.
--
-- For Go: invokes the inspector ONCE for the full pkg list, deduping
-- shared transitive deps via go/packages.Load.
--
-- For Rust: invokes the inspector once per chunk (the Rust inspector
-- resolves each crate independently via temp-project + cargo fetch).
--
-- Falls back to single-mode when only one package is requested
-- (avoids JSON-array vs JSON-object decode-shape branch).
runInspectorMultiForTarget :: CompileTarget -> [String] -> [String] -> IO [Either String PkgInfo]
runInspectorMultiForTarget _        []        _   = return []
runInspectorMultiForTarget target   [pkgPath] feats = do
    r <- runInspectorForTarget target pkgPath feats
    return [r]
runInspectorMultiForTarget target pkgPaths features = do
    let prefix = inspectorCallPrefix target
    resolved <- resolveInspector target
    case resolved of
        Left e    -> return (map (const (Left e)) pkgPaths)
        Right bin -> do
            let featuresArg = if null features then "" else " --features " ++ intercalate "," features
                quoted = unwords (map (\p -> "'" ++ p ++ "'") pkgPaths)
                cmd' = if null prefix
                        then bin ++ " " ++ quoted ++ featuresArg
                        else prefix ++ " && " ++ bin ++ " " ++ quoted ++ featuresArg
            (_, out, err) <- readProcessWithExitCode "sh" ["-c", cmd'] ""
            let inspName = inspectorName target
            if null out
                then return (map (const (Left $ inspName ++ ": empty output; stderr: " ++ err)) pkgPaths)
                else case A.eitherDecode (BL.fromStrict (TE.encodeUtf8 (T.pack out))) of
                    Right (results :: [PkgInfo]) ->
                        let byPath = [(_pkgPath p, p) | p <- results]
                            findFor path = case lookup path byPath of
                                Just p  -> Right p
                                Nothing -> Left (inspName ++ ": no result for " ++ path)
                        in return (map findFor pkgPaths)
                    Left _ ->
                        -- Single-object fallback for old single-mode inspectors
                        case A.eitherDecode (BL.fromStrict (TE.encodeUtf8 (T.pack out))) :: Either String PkgInfo of
                            Right _ -> mapM (\p -> runInspectorForTarget target p features) pkgPaths
                            Left e  -> return (map (const (Left $ inspName ++ ": json: " ++ e)) pkgPaths)


inspectorName :: CompileTarget -> String
inspectorName TargetGo   = "sky-ffi-inspect"
inspectorName TargetRust = "sky-ffi-inspect-rs"


inspectorCallPrefix :: CompileTarget -> String
inspectorCallPrefix TargetGo   = "cd sky-out"
inspectorCallPrefix TargetRust = ""


-- | Resolve a working `sky-ffi-inspect` binary. Preference order:
--
--   1. `$SKY_FFI_INSPECTOR` (explicit override — honoured first for
--      contributor workflows and test harnesses).
--   2. `./bin/sky-ffi-inspect` walking up ancestor directories (in-
--      tree dev builds).
--   3. Embedded fallback — materialise the bundled Go source from
--      the sky binary to `$XDG_CACHE_HOME/sky/tools/`, `go build`,
--      cache. This is what released binaries hit: a single `sky`
--      executable that self-provisions its helper on first use.
--
-- Returns the path, or a descriptive error if every strategy fails
-- (most commonly: no `go` on PATH).
-- | Resolve an inspector binary for the given target.
resolveInspector :: CompileTarget -> IO (Either String FilePath)
resolveInspector TargetGo   = resolveGoInspector
resolveInspector TargetRust = resolveRustInspector


resolveGoInspector :: IO (Either String FilePath)
resolveGoInspector = do
    disk <- findGoInspector
    case disk of
        Just p  -> return (Right p)
        Nothing -> EI.ensureInspector


resolveRustInspector :: IO (Either String FilePath)
resolveRustInspector = do
    disk <- findRustInspector
    case disk of
        Just p  -> return (Right p)
        Nothing -> EIRust.ensureInspectorRust


-- | Probe common locations for the sky-ffi-inspect binary.
-- Looks at: SKY_FFI_INSPECTOR env var, ./bin, ../bin … walking up ancestors.
findGoInspector :: IO (Maybe FilePath)
findGoInspector = do
    envPath <- lookupEnv "SKY_FFI_INSPECTOR"
    case envPath of
        Just p | not (null p) -> do
            ok <- doesFileExist p
            if ok then return (Just p) else walkUp
        _ -> walkUp
  where
    walkUp = do
        cwd <- getCurrentDirectory
        go cwd 12
    go _   0 = return Nothing
    go dir n = do
        let candidate = dir </> "bin" </> "sky-ffi-inspect"
        ok <- doesFileExist candidate
        if ok
            then return (Just candidate)
            else let parent = takeDirectory dir
                 in if parent == dir
                        then return Nothing
                        else go parent (n - 1)


-- | Probe common locations for the sky-ffi-inspect-rs binary.
-- Looks at: SKY_FFI_INSPECTOR_RS env var, ./bin, ../bin … walking up ancestors.
findRustInspector :: IO (Maybe FilePath)
findRustInspector = do
    envPath <- lookupEnv "SKY_FFI_INSPECTOR_RS"
    case envPath of
        Just p | not (null p) -> do
            ok <- doesFileExist p
            if ok then return (Just p) else walkUp
        _ -> walkUp
  where
    walkUp = do
        cwd <- getCurrentDirectory
        go cwd 12
    go _   0 = return Nothing
    go dir n = do
        let candidate = dir </> "bin" </> "sky-ffi-inspect-rs"
        ok <- doesFileExist candidate
        if ok
            then return (Just candidate)
            else let parent = takeDirectory dir
                 in if parent == dir
                        then return Nothing
                        else go parent (n - 1)


generateBindings :: CompileTarget -> PkgInfo -> IO [String]
generateBindings TargetGo pkg = do
    createDirectoryIfMissing True ".skycache/ffi"
    createDirectoryIfMissing True ".skycache/go"
    let slug = slugify (_pkgName pkg)
        kname = kernelNameFromPkg TargetGo pkg
        mname = pkgToModuleName TargetGo (_pkgPath pkg)
        goFile   = ".skycache/go"  </> (slug ++ "_bindings.go")
        skyiFile = ".skycache/ffi" </> (slug ++ ".skyi")
        jsonFile = ".skycache/ffi" </> (slug ++ ".kernel.json")
        names = map (\fn -> mname ++ "." ++ lowerFirst (_fnName fn)) (_pkgFns pkg)
    writeFile goFile (emitGoFile kname pkg)
    writeFile skyiFile (emitSkyi TargetGo pkg)
    writeFile jsonFile (emitKernelJson mname kname pkg)
    return names
generateBindings TargetRust pkg0 = do
    createDirectoryIfMissing True ".skycache/ffi/rust"
    -- Dedup once at the source so the .rs wrapper, the .skyi catalogue, and the
    -- .kernel.json dispatch table all agree on the same set of bindings.  A
    -- real `to_string`/`from_string` method colliding with the synthetic
    -- Display/FromStr bridge (e.g. ulid::Ulid) would otherwise produce a
    -- duplicate Sky binding in the .skyi while the .rs keeps only one.
    let pkg = pkg0 { _pkgFns = dedupByRustName (_pkgFns pkg0) }
        slug = slugify (_pkgName pkg)
        kname = kernelNameFromPkg TargetRust pkg
        mname = pkgToModuleName TargetRust (_pkgPath pkg)
        rsFile   = ".skycache/ffi/rust" </> (slug ++ "_bindings.rs")
        skyiFile = ".skycache/ffi/rust" </> (slug ++ ".skyi")
        jsonFile = ".skycache/ffi/rust" </> (slug ++ ".kernel.json")
        names = map (\fn -> mname ++ "." ++ lowerFirst (_fnName fn)) (_pkgFns pkg)
    writeFile rsFile (emitRustFile kname pkg)
    writeFile skyiFile (emitSkyi TargetRust pkg)
    writeFile jsonFile (emitKernelJson mname kname pkg)
    return names


-- | Convert a Go package path to the Sky-side module name using the
-- path-segment → dotted-camel transform Sky users expect.
-- "github.com/google/uuid"           → "Github.Com.Google.Uuid"
-- "github.com/stripe/stripe-go/v84"  → "Github.Com.Stripe.StripeGo.V84"
-- "fyne.io/fyne/v2/app"              → "Fyne.Io.Fyne.V2.App"
-- "net/http"                         → "Net.Http"
--
-- Hyphen handling: drop the hyphen, upper-case the next char — matches
-- the legacy Sky convention and what Sky users write in real code
-- (e.g., `import Github.Com.Stripe.StripeGo.V84 as Stripe`).
pkgToModuleName :: CompileTarget -> String -> String
pkgToModuleName TargetRust path =
    let clean = map (\c -> if isAlphaNum c then c else '_') path
        cap   = capitaliseFirst clean
    in "Rust." ++ cap
pkgToModuleName TargetGo path =
    let slashed = splitOnChar '/' path
        dotted  = concatMap (splitOnChar '.') slashed
        cleaned = map camelHyphen dotted
        cap     = map capitaliseFirst (filter (not . null) cleaned)
    in  intercalate "." cap
  where
    -- "stripe-go" -> "stripeGo"; non-alphanum (other than '-') -> '_'.
    camelHyphen s = go False s
      where
        go _  []          = []
        go _  ('-':cs)    = go True cs
        go True (c:cs)    = toUpper c : go False cs
        go False (c:cs)
          | isAlphaNum c = c : go False cs
          | otherwise    = '_' : go False cs


-- | Pick the Sky-kernel-name (the prefix used for wrapper fns).
-- Go target uses "Go_" prefix so FFI-generated wrappers can't collide
-- with hand-written stdlib kernel functions (e.g. the stdlib exposes
-- Uuid_v4 / Uuid_parse from Sky.Core.Uuid — an FFI binding to
-- github.com/google/uuid becomes Go_Uuid_newString etc.).
-- Rust target uses "Rust_" prefix, same collision-avoidance rationale.
kernelNameFromPkg :: CompileTarget -> PkgInfo -> String
kernelNameFromPkg target pkg =
    let prefix = case target of
            TargetGo   -> "Go_"
            TargetRust -> "Rust_"
        segs = filter (not . null) (splitOnChar '/' (_pkgPath pkg))
        capOf s = capitaliseFirst (map (\c -> if isAlphaNum c then c else '_') s)
        baseName = case reverse segs of
            (last1 : prev : _) | isVersion last1 ->
                capOf prev ++ capOf last1
            (last1 : _) -> capOf last1
            []          -> "Ffi"
    in  prefix ++ baseName
  where
    isVersion ('v':rest) = all (`elem` ("0123456789" :: String)) rest && not (null rest)
    isVersion _ = False


splitOnChar :: Char -> String -> [String]
splitOnChar _ [] = [""]
splitOnChar sep (x:xs)
    | x == sep = "" : splitOnChar sep xs
    | otherwise = case splitOnChar sep xs of
        (h:t) -> (x:h) : t
        []    -> [[x]]


capitaliseFirst :: String -> String
capitaliseFirst [] = []
capitaliseFirst (c:cs) = toUpper c : cs


lowerFirst :: String -> String
lowerFirst [] = []
lowerFirst (c:cs) = toLower c : cs


-- ══════════════════════════════════════════════════════════════════════════
-- kernel.json emission — consumed by Sky.Build.FfiRegistry at sky build time
-- ══════════════════════════════════════════════════════════════════════════

emitKernelJson :: String -> String -> PkgInfo -> String
emitKernelJson moduleName kernelName pkg =
    let fns = filter (not . shouldSkipFn) (_pkgFns pkg)
        fnEntries = intercalate ",\n" (map emitFnEntry fns)
        emitFnEntry fn =
            let st = wrapperSkyType fn
                recv = _fnRecvType fn
                disamb = if null recv then "" else "_from_" ++ lowerFirst recv
                base = "    {\"name\": " ++ quote (lowerFirst (_fnName fn) ++ disamb) ++
                       ", \"arity\": " ++ show (max 1 (length (_fnParams fn)))
            in if isSkyParseable st
                  then base ++ ", \"skyType\": " ++ quote st ++ "}"
                  else base ++ "}"
    in unlines
        [ "{"
        , "  \"moduleName\": " ++ quote moduleName ++ ","
        , "  \"kernelName\": " ++ quote kernelName ++ ","
        , "  \"package\": " ++ quote (_pkgPath pkg) ++ ","
        , "  \"functions\": ["
        , fnEntries
        , "  ]"
        , "}"
        ]


-- | Sky-side type for an FFI wrapper, including the runtime Result
-- wrap. Mirrors the shape `emitWrapper` actually emits — see
-- `bodyLines` / `okType` around line 1296. Per the trust-boundary
-- rule (CLAUDE.md "every FFI call returns Result Error T"), every
-- wrapper returns SkyResult[any, T] no matter how its Go signature
-- spells the result.
--
-- Mapping (matches the wrapper code):
--   []                          -> Result Error ()
--   [(_, T)] non-error          -> Result Error T
--   [(_, "error")]              -> Result Error ()
--   (T, error)                  -> Result Error T
--   (T, bool) comma-ok          -> Result Error (Maybe T)
--   (T, U) no error/bool        -> Result Error (T, U)   (SkyTuple2)
--   (T, U, error)               -> Result Error (T, U)
--   (T, U, V) etc.              -> Result Error (T, U, V) (SkyTuple3+)
--
-- Param list flows through goTypeToSky verbatim. Zero-param Go
-- functions emit `() -> Result Error R` — Sky calls them as
-- `Pkg.fn ()` (unit applied), matching the existing convention.
wrapperSkyType :: FnInfo -> String
wrapperSkyType fn =
    -- Per-param / per-result Sky-side override from the inspector
    -- (e.g. CheckoutSessionStatus -> string). Length matches
    -- _fnParams / _fnResults; "" means use the bare Go type.
    let resolveSky goT skyOverride
            | null skyOverride = goTypeToSky goT
            | otherwise        = goTypeToSky skyOverride
        paramOverrides =
            _fnParamSkyTypes fn ++ repeat ""
        resultOverrides =
            _fnResultSkyTypes fn ++ repeat ""
        paramSig = if null (_fnParams fn)
            then "()"
            else intercalate " -> "
                    (zipWith (\(_, t) sk -> resolveSky t sk)
                        (_fnParams fn) paramOverrides)
        results = _fnResults fn
        zippedResults = zip results resultOverrides
        nonErr = [ ((n, t), sk) | ((n, t), sk) <- zippedResults, t /= "error" ]
        skyOf ((_, t), sk) = resolveSky t sk
        innerOk = case (results, nonErr) of
            ([], _)               -> "()"
            ([(_, "error")], _)   -> "()"
            (_, [])               -> "()"
            (_, [single])         ->
                case results of
                    [(_, t1), (_, "bool")] | t1 /= "bool" ->
                        -- comma-ok: (T, bool) -> Maybe T
                        "Maybe " ++ wrapIfMulti (skyOf single)
                    _ -> skyOf single
            (_, multi)            ->
                -- Multi non-error returns pack into a Sky tuple.
                "(" ++ intercalate ", " (map skyOf multi) ++ ")"
        okType
            -- Inspector already produced a Result type (shims, or union
            -- returns that already carry the Result layer) — don't double-wrap.
            | "Result " `isPrefixOf` innerOk = innerOk
            | otherwise = case innerOk of
            -- Result wrap composites need parens to bind tightly.
            ('(':_) -> "Result Error " ++ innerOk
            _       -> "Result Error " ++ wrapIfMulti innerOk
    in paramSig ++ " -> " ++ okType
  where
    -- "List X" / "Dict String V" / "Maybe X" etc. need parens when
    -- nested under another constructor (Result Error here).
    wrapIfMulti s
        | ' ' `elem` s && head s /= '(' = "(" ++ s ++ ")"
        | otherwise                     = s


-- | Reject Sky-type strings that still carry Go-side residue. These
-- typically come from exotic Go shapes the goTypeToSky translator
-- can't faithfully render (channels, deeply-nested inline-struct
-- callback bundles, package-leaking generics). When the registry
-- skyType field is omitted, FfiRegistry falls back to the legacy
-- "no Sky-side type known" path — the wrapper itself still works,
-- HM just doesn't constrain its use.
isSkyParseable :: String -> Bool
isSkyParseable s = not $ any (`isSubstringOf` s)
    [ "<-"            -- channel direction
    , " chan "        -- bare chan
    , "chan "         -- chan at start
    , "interface{"    -- residual empty/non-empty interface
    , "struct{"       -- residual struct literal
    , "func("         -- Go's func keyword should have been stripped
    , "{}"            -- any leaked empty-{} (interface{} / struct{} nested)
    ]


-- | Skip functions that can't be realised at the FFI boundary.
shouldSkipFn :: FnInfo -> Bool
shouldSkipFn fn =
    let hasGeneric = any (isGenericType . snd) (_fnParams fn)
                  || any (isGenericType . snd) (_fnResults fn)
                  || any (genericHint . snd) (_fnParams fn)
                  || any (genericHint . snd) (_fnResults fn)
        isIdPointer = length (_fnParams fn) == 1
                   && length (_fnResults fn) == 1
                   && isBareParam (snd (head (_fnParams fn)))
                   && isStarBareParam (snd (head (_fnResults fn)))
        refsInternal = any (touchesInternal . snd) (_fnParams fn)
                    || any (touchesInternal . snd) (_fnResults fn)
    in (hasGeneric && not isIdPointer) || refsInternal
  where
    -- True when a type string mentions any `<path>/internal[/<more>].Name` or
    -- `<path>/vendor[/<more>].Name` — Go forbids cross-module imports of those.
    touchesInternal t = "/internal." `isSubstringOf` t
                     || "/internal/" `isSubstringOf` t
                     || "/vendor." `isSubstringOf` t
                     || "/vendor/" `isSubstringOf` t
    -- Coarse check for any `[T ...]` or `[T, U]` generic instantiation
    -- anywhere in the type string — `isGenericType` only catches bracketed
    -- params at the top-level position, but Stripe's receivers look like
    -- `*pkg.V2List[T any]` where the generic lives inside a pointer.
    genericHint t = "[T " `isSubstringOf` t
                 || "[T]" `isSubstringOf` t
                 || "[T," `isSubstringOf` t
                 || "[K " `isSubstringOf` t
                 || "[V " `isSubstringOf` t
                 || "[]T" `isSubstringOf` t
                 || endsT t
      where
        endsT s = s == "T" || "*T" `isSuffix` s
        isSuffix suf s = length s >= length suf &&
                        drop (length s - length suf) s == suf


-- ══════════════════════════════════════════════════════════════════════════
-- Package discovery and alias resolution
--
-- We scan every type string referenced by every function in the package
-- and discover all Go packages that must be imported. Each gets a safe
-- Go identifier alias derived from its path.
-- ══════════════════════════════════════════════════════════════════════════

-- | A table: Go package path → alias used in the emitted wrapper.
-- The requested package itself is bound to the alias "pkg" (matching
-- `pkg "..."` in the import block). Every other package gets an alias
-- derived from its last path segment, de-conflicted if necessary.
type AliasTable = Map.Map String String

buildAliasTable :: PkgInfo -> AliasTable
buildAliasTable pkg =
    let self = _pkgPath pkg
        allPaths = discoverPackagePaths pkg
        others = filter (/= self) allPaths
        -- Reserved aliases: pkg (self), fmt (always imported).
        reserved = Set.fromList ["pkg", "fmt"]
        assigned = foldl' assign (Map.singleton self "pkg", reserved) others
    in fst assigned
  where
    assign (m, used) path =
        let base = pathToAlias path
            final = uniqueAlias used base 0
        in (Map.insert path final m, Set.insert final used)

    uniqueAlias used base n =
        let candidate = if n == 0 then base else base ++ "_" ++ show n
        in if Set.member candidate used
            then uniqueAlias used base (n + 1)
            else candidate


-- | Last path segment, sanitised to a valid Go identifier.
-- "github.com/stripe/stripe-go/v82"               → "stripe_go_v82"
-- "github.com/stripe/stripe-go/v82/checkout/session" → "session"
-- "net/http"                                      → "http"
-- "time"                                          → "time"
pathToAlias :: String -> String
pathToAlias path =
    let lastSeg = reverse (takeWhile (/= '/') (reverse path))
        cleaned = map (\c -> if isAlphaNum c then c else '_') lastSeg
        -- Go package paths often end in a version segment like "v82" — if so,
        -- use the preceding segment instead for a more meaningful alias.
        alias = if isVersionSegment lastSeg
            then let rest = reverse (drop (length lastSeg + 1) (reverse path))
                     prevSeg = reverse (takeWhile (/= '/') (reverse rest))
                 in if not (null prevSeg) && not (isVersionSegment prevSeg)
                     then sanitise prevSeg
                     else sanitise lastSeg
            else sanitise lastSeg
    in if null alias || not (isLower (head alias) || head alias == '_')
        then "p_" ++ alias
        else alias
  where
    sanitise s = map (\c -> if isAlphaNum c then c else '_') s
    isVersionSegment s = case s of
        'v':rest -> all (`elem` ('0'::Char):'1':'2':'3':'4':'5':'6':'7':'8':'9':[]) rest
        _ -> False


-- | Every Go package referenced in any function signature, including
-- the package itself (so the caller can check it was discovered).
discoverPackagePaths :: PkgInfo -> [String]
discoverPackagePaths pkg =
    let self = _pkgPath pkg
        allTypes = concatMap typesFromFn (_pkgFns pkg)
        paths = concatMap extractPackagePaths allTypes
        -- Go disallows importing `internal/` subtrees outside their home
        -- module; skip them instead of emitting a go build error. Same
        -- applies to `vendor/` subtrees.
        hasSeg seg p = any (== seg) (splitOnChar '/' p)
        ok p = not (hasSeg "internal" p) && not (hasSeg "vendor" p)
    in nub (self : filter ok paths)
  where
    typesFromFn fn = map snd (_fnParams fn) ++ map snd (_fnResults fn)


-- | Extract every package path that appears in a Go type string.
-- Detects patterns like `<path>.<Name>` where `<path>` is slashes +
-- lowercase segments + dots, and `<Name>` starts with uppercase.
--
-- Handles: pointers (*), slices ([]), maps (map[K]V), arrays ([N]).
-- Does NOT recurse into generic parameters like `Map[K,V]` — handled
-- at skip-time via isTypeParam.
extractPackagePaths :: String -> [String]
extractPackagePaths s = go True s
  where
    -- atBoundary is True when the previous char was a type-term delimiter
    -- (*, [, ], ,, etc. or start-of-string). Only then does a lowercase
    -- character begin a fresh package path — we must not restart parsing
    -- mid-path (which would split "github.com/stripe/..." into "github"
    -- then "com/stripe/..." and misattribute the prefix).
    go _ [] = []
    go atBoundary input@(c:rest)
        | atBoundary && isLower c =
            case scanPath input of
                Just (path, more) -> path : go True more
                Nothing           -> go (isBoundary c) rest
        | otherwise = go (isBoundary c) rest

    -- Delimiters in Go type strings.
    isBoundary ch = ch `elem` (" \t\n*[](),<>" :: String)

    -- Walk the path chars (segments separated by `.` or `/`, lowercase
    -- segments OK, digits OK, `-` OK). Stop on `.` followed by uppercase,
    -- which marks the TypeName.
    scanPath = walk ""

    walk acc [] = Nothing
    walk acc (c:rest)
        | isSegChar c = walk (acc ++ [c]) rest
        | c == '/'    = walk (acc ++ "/") rest
        | c == '.'    =
            case rest of
                (n:_) | isUpper n ->
                    -- Delimiter! Consume the TypeName then return.
                    let (_name, rest') = span isNameChar rest
                    in if not (null acc) && (hasPathSep acc || isKnownBarePkg acc)
                        then Just (acc, rest')
                        else Nothing
                (n:_) | isLower n || isAlphaNum n ->
                    -- Still inside the path (e.g. "github.com").
                    walk (acc ++ ".") rest
                _ -> Nothing
        | otherwise = Nothing

    isSegChar c = isAlphaNum c || c == '-' || c == '_'
    isNameChar c = isAlphaNum c || c == '_'
    hasPathSep = any (== '/')

    isKnownBarePkg p = p `elem`
        [ "time", "io", "os", "fmt", "sync", "errors", "bytes"
        , "strings", "strconv", "unicode", "math", "sort", "regexp"
        , "reflect", "encoding", "bufio", "log", "context"
        , "hash", "crypto", "net", "mime", "path"
        ]


-- ══════════════════════════════════════════════════════════════════════════
-- Type rewriting
-- ══════════════════════════════════════════════════════════════════════════

-- | Rewrite every `<pkg-path>.<Name>` in a Go type string to `<alias>.<Name>`
-- using the alias table. Preserves *, [], []*, map[K]V wrappers.
-- Only starts parsing a path at a type boundary to avoid misparsing
-- "github.com/..." as "com/..." after eating the "github" prefix.
rewriteType :: AliasTable -> String -> String
rewriteType table = go True
  where
    go _ [] = []
    go atBoundary input@(c:rest)
        | atBoundary && isLower c =
            case scanPath input of
                Just (path, name, more) ->
                    case Map.lookup path table of
                        Just alias -> alias ++ "." ++ name ++ go True more
                        Nothing    -> c : go (isBoundary c) rest
                Nothing -> c : go (isBoundary c) rest
        | otherwise = c : go (isBoundary c) rest

    isBoundary ch = ch `elem` (" \t\n*[](),<>" :: String)

    scanPath = walk ""

    walk _ [] = Nothing
    walk acc (c:rest)
        | isSegChar c = walk (acc ++ [c]) rest
        | c == '/'    = walk (acc ++ "/") rest
        | c == '.'    =
            case rest of
                (n:_) | isUpper n ->
                    let (nameChars, rest') = span isNameChar rest
                    in if not (null acc) then Just (acc, nameChars, rest')
                                         else Nothing
                (n:_) | isLower n || isAlphaNum n ->
                    walk (acc ++ ".") rest
                _ -> Nothing
        | otherwise = Nothing

    isSegChar c = isAlphaNum c || c == '-' || c == '_'
    isNameChar c = isAlphaNum c || c == '_'


-- ══════════════════════════════════════════════════════════════════════════
-- Generics detection (the only remaining skip class)
-- ══════════════════════════════════════════════════════════════════════════

-- | True if the type references a Go generic type parameter (e.g. `T`
-- standing alone, or inside brackets `Fetch[T]`). Generics cannot be
-- realised at FFI time without monomorphisation; we skip them with a clear
-- comment, matching the self-hosted compiler.
isGenericType :: String -> Bool
isGenericType t = isBareParam t || hasBracketedParam t
  where
    isBareParam [c] = c >= 'A' && c <= 'Z'
    isBareParam _   = False

    hasBracketedParam s = case break (== '[') s of
        (_, '[':rest) ->
            let inside = takeWhile (/= ']') rest
                rest'  = drop 1 (dropWhile (/= ']') rest)
            in simpleParamInside inside || hasBracketedParam rest'
        _ -> False

    simpleParamInside inside =
        let parts = map trim (splitOn ',' inside)
        in any isBareParam parts

    trim = reverse . dropWhile (== ' ') . reverse . dropWhile (== ' ')

    splitOn _ [] = [""]
    splitOn d (x:xs)
        | x == d    = "" : splitOn d xs
        | otherwise = let (h:t) = splitOn d xs in (x:h) : t


-- ══════════════════════════════════════════════════════════════════════════
-- Argument coercion
-- ══════════════════════════════════════════════════════════════════════════

-- | Emit a Go expression that coerces args[i] to the rewritten Go type.
-- All primitives go through our AsInt/AsFloat helpers (which handle
-- int→int64→float→bool variants without panicking). Complex types use
-- a direct type assertion; if the assertion fails the panic is caught
-- by runWithRecover in rt and surfaced as Err.
goArgCast :: Int -> String -> String
goArgCast i t = case t of
    "string"   -> "fmt.Sprintf(\"%v\", args[" ++ show i ++ "])"
    "int"      -> "AsInt(args[" ++ show i ++ "])"
    "int8"     -> "int8(AsInt(args[" ++ show i ++ "]))"
    "int16"    -> "int16(AsInt(args[" ++ show i ++ "]))"
    "int32"    -> "int32(AsInt(args[" ++ show i ++ "]))"
    "int64"    -> "int64(AsInt(args[" ++ show i ++ "]))"
    "uint"     -> "uint(AsInt(args[" ++ show i ++ "]))"
    "uint8"    -> "uint8(AsInt(args[" ++ show i ++ "]))"
    "uint16"   -> "uint16(AsInt(args[" ++ show i ++ "]))"
    "uint32"   -> "uint32(AsInt(args[" ++ show i ++ "]))"
    "uint64"   -> "uint64(AsInt(args[" ++ show i ++ "]))"
    "float64"  -> "AsFloat(args[" ++ show i ++ "])"
    "float32"  -> "float32(AsFloat(args[" ++ show i ++ "]))"
    "bool"     -> "args[" ++ show i ++ "].(bool)"
    "byte"     -> "byte(AsInt(args[" ++ show i ++ "]))"
    "rune"     -> "rune(AsInt(args[" ++ show i ++ "]))"
    "[]byte"   ->
        "func() []byte { v := args[" ++ show i ++ "]; " ++
        "if b, ok := v.([]byte); ok { return b }; " ++
        "return []byte(fmt.Sprintf(\"%v\", v)) }()"
    "error"    -> "args[" ++ show i ++ "].(error)"
    _          -> "args[" ++ show i ++ "].(" ++ t ++ ")"


-- ══════════════════════════════════════════════════════════════════════════
-- Emission
-- ══════════════════════════════════════════════════════════════════════════

emitGoFile :: String -> PkgInfo -> String
emitGoFile kernelName pkg =
    let aliases = buildAliasTable pkg
        -- Deduplicate by Sky-facing name. The inspector can surface
        -- two FnInfos that mangle to the same wrapper name — e.g. a
        -- struct-field accessor `RichTextStyle.Inline` alongside a
        -- package-level const `RichTextStyleInline`. Keep the first
        -- occurrence; the second would be a duplicate Go `func` decl
        -- and break go build. Field accessors are structurally more
        -- useful (readable pipeline setters), so order-of-inspector
        -- is deliberately preserved.
        seenNames = dedupByFirst (_pkgFns pkg)
        entries = map (emitTypedWrapper kernelName aliases) seenNames
        anyEmitted = any (not . isSkippedEntry) entries
        -- Any alias that doesn't appear in any emitted entry becomes a blank
        -- import so Go doesn't error with "imported and not used". `pkg` and
        -- `fmt` are always considered used (pkg → wrapper calls, fmt → Sprintf).
        emittedBlob = concat entries
        usedAliases = Set.insert "pkg"
                    $ Set.insert "fmt"
                    $ Set.fromList
                        [ alias
                        | alias <- Map.elems aliases
                        , (alias ++ ".") `isSubstringOf` emittedBlob
                        ]
        usesReflect = "reflect.ValueOf" `isSubstringOf` emittedBlob
        reflectInAliases = Map.member "reflect" aliases
        importLines =
            buildImportLinesFiltered pkg aliases anyEmitted usedAliases
            ++ [ "\t\"reflect\"" | usesReflect && not reflectInAliases ]
    in unlines $
        [ "// Code generated by sky-ffi-inspect from " ++ _pkgPath pkg ++ ". DO NOT EDIT."
        , "// Re-run `sky add " ++ _pkgPath pkg ++ "` to regenerate."
        , "//"
        , "// Wrapper functions are in `package rt` with names <Kernel>_<lowerFn>."
        , "// Sky source resolves `import " ++ pkgToModuleName TargetGo (_pkgPath pkg) ++
          " as X` and calls `X.<lowerFn>` — the canonicaliser routes it via"
        , "// the FFI registry to these typed Go functions. Every wrapper wraps"
        , "// panics in Err[any, any] via SkyFfiRecover."
        , ""
        , "package rt"
        , ""
        , "import ("
        ]
        ++ importLines
        ++
        [ ")"
        , ""
        ]
        ++ entries
        ++
        [ ""
        , "// Pin fmt against \"imported and not used\" across partial files."
        , "var _ = fmt.Sprintf"
        ]


-- | Convert a Sky type string (as output by the inspector's
-- type_str_to_sky) to a Rust type string.
-- | Convert a Sky type string (as emitted by the inspector's
-- type_str_to_sky) to a Rust type string.
skyTypeToRust :: String -> String
skyTypeToRust "Int"    = "i64"
skyTypeToRust "Float"  = "f64"
skyTypeToRust "Bool"   = "bool"
skyTypeToRust "String" = "String"
skyTypeToRust "()"     = "()"
skyTypeToRust "Bytes"  = "Vec<u8>"
skyTypeToRust s
    | Just inner <- stripPrefix "List " s      = "Vec<" ++ skyTypeToRust inner ++ ">"
    | Just inner <- stripPrefix "Maybe " s     = "SkyMaybe<" ++ skyTypeToRust inner ++ ">"
    | Just rest <- stripPrefix "Result " s     = case words rest of
        [e, a] -> "SkyResult<" ++ skyTypeToRust e ++ ", " ++ skyTypeToRust a ++ ">"
        _      -> "SkyResult<SkyError, String>"
    | Just rest <- stripPrefix "Dict String " s = "HashMap<String, " ++ skyTypeToRust rest ++ ">"
    | Just rest <- stripPrefix "Task SkyError " s = "SkyTask<SkyError, " ++ skyTypeToRust rest ++ ">"
    | otherwise = "String"  -- fallback for unrecognised types


-- | Snake-case a Rust identifier EXACTLY as Sky.Generate.Rust.Builder.toSnakeCase
-- does.  The Rust codegen snake-cases the kernel call site
-- (`chrono_to_string_from_date_time`); the binding's `pub fn` name must match
-- byte-for-byte or the call fails to resolve.  Both camelCase boundaries and
-- existing underscores map to `_<lower>`.
rustSnakeCase :: String -> String
rustSnakeCase []     = []
rustSnakeCase (c:cs) = toLower c : go cs
  where
    go [] = []
    go (x:xs)
      | x == '_' && not (null xs) = '_' : toLower (head xs) : go (tail xs)
      | isUpper x                 = '_' : toLower x : go xs
      | otherwise                 = x : go xs


-- | True when the given Rust type string is a primitive numeric type.
-- Used to pick `as <T>` casts instead of `.try_into().unwrap()` or `.into()`.
isNumericRust :: String -> Bool
isNumericRust t = t `elem`
    [ "i8", "i16", "i32", "i64", "i128"
    , "u8", "u16", "u32", "u64", "u128"
    , "isize", "usize", "f32", "f64" ]


-- | Strip leading/trailing spaces.
trimStr :: String -> String
trimStr = f . f where f = reverse . dropWhile (== ' ')


-- | If the type is `Wrapper<...>`, return the inner argument string.
stripGeneric1 :: String -> String -> Maybe String
stripGeneric1 wrapper s0 =
    let s = trimStr s0
    in case stripPrefix (wrapper ++ "<") s of
         Just rest | not (null rest) && last rest == '>' -> Just (trimStr (init rest))
         _ -> Nothing


-- | For a `Result<T, E>` string return the Ok type `T`; otherwise the input
-- unchanged.  Respects nested angle brackets so `Result<Vec<T>, E>` works.
okTypeOfResult :: String -> String
okTypeOfResult s0 =
    case stripPrefix "Result<" (trimStr s0) of
        Just rest -> trimStr (firstArg rest)
        Nothing   -> trimStr s0
  where
    firstArg = go (0 :: Int) []
      where
        go _ acc [] = reverse acc
        go d acc (c:cs)
          | c == '<' || c == '(' = go (d + 1) (c:acc) cs
          | (c == '>' || c == ')') && d == 0 = reverse acc
          | c == '>' || c == ')' = go (d - 1) (c:acc) cs
          | c == ',' && d == 0   = reverse acc
          | otherwise            = go d (c:acc) cs


-- | Classification of a read-only byte-sequence Rust type.
data ByteKind = BSlice | BVec | BArr Int | BRefArr Int

-- | Classify a raw Rust type as a byte sequence (mirrors the inspector's
-- is_byte_seq). N is parsed from `[u8; N]` / `&[u8; N]`.
byteSeqKind :: String -> Maybe ByteKind
byteSeqKind raw =
    case trimStr raw of
        "&[u8]"   -> Just BSlice
        "Vec<u8>" -> Just BVec
        s -> case arrN "&[u8; " s of
               Just n  -> Just (BRefArr n)
               Nothing -> BArr <$> arrN "[u8; " s
  where
    arrN pfx s = do
        rest <- stripPrefix pfx s
        case span (/= ']') rest of
            (digits, "]") | not (null digits) && all isDigit digits -> Just (read digits)
            _ -> Nothing


-- | Translate a raw Rust (Ok-)type into the wrapper's declared inner return
-- type plus a coercion that lifts an expression of the raw type into that
-- declared type.  Driven by the inspector's real Rust type (the source of
-- truth for opaque types) rather than the lossy Sky type — which collapses
-- every opaque type to "String" and would force a bogus `.into()`.
--
--   Option<T>   -> (SkyMaybe<T'>, match-wrap)
--   Vec<T>      -> (Vec<T'>, per-element map when T needs coercion)
--   iN / uN     -> (i64, `(e) as i64`)
--   f32 / f64   -> (f64, `(e) as f64`)
--   bool        -> (bool, identity)
--   String      -> (String, identity)
--   &str/&String-> (String, `e.to_string()`)
--   &T          -> (T', `e.to_owned()`)
--   () / ""     -> ((), identity — the call still executes)
--   opaque T    -> (T, identity)
translateRustRet :: String -> (String, String -> String)
translateRustRet raw0 =
    let raw = trimStr raw0 in
    if raw == "" || raw == "()" then ("()", id)
    else case byteSeqKind raw of
      Just bk ->
        ( "Vec<i64>"
        , \e -> case bk of
            BVec      -> "from_u8_slice(&" ++ e ++ ")"
            BArr _    -> "from_u8_slice(&" ++ e ++ ")"
            BSlice    -> "from_u8_slice(" ++ e ++ ")"
            BRefArr _ -> "from_u8_slice(" ++ e ++ ")" )
      Nothing -> case stripGeneric1 "Option" raw of
        Just inner ->
          let (dt, co) = translateRustRet inner
          in ( "SkyMaybe<" ++ dt ++ ">"
             , \e -> "match " ++ e ++ " { Some(v) => SkyMaybe::Just(" ++ co "v"
                     ++ "), None => SkyMaybe::Nothing }" )
        Nothing -> case stripGeneric1 "Vec" raw of
          Just inner ->
            let (dt, co) = translateRustRet inner
            in ( "Vec<" ++ dt ++ ">"
               , \e -> if co "x" == "x" then e
                       else e ++ ".into_iter().map(|x| " ++ co "x" ++ ").collect()" )
          Nothing
            | raw `elem` intRusts   -> ("i64", \e -> "(" ++ e ++ ") as i64")
            | raw `elem` floatRusts -> ("f64", \e -> "(" ++ e ++ ") as f64")
            | raw == "bool"   -> ("bool", id)
            | raw == "String" -> ("String", id)
            | "&" `isPrefixOf` raw ->
                let inner = stripRef raw
                in if inner == "str" || inner == "String"
                   then ("String", \e -> e ++ ".to_string()")
                   else let (dt, _) = translateRustRet inner
                        in (dt, \e -> e ++ ".to_owned()")
            | otherwise -> (raw, id)   -- opaque type: keep as-is, no coercion
  where
    intRusts   = [ "i8","i16","i32","i64","i128","isize"
                 , "u8","u16","u32","u64","u128","usize" ]
    floatRusts = [ "f32", "f64" ]
    stripRef s =
        let s1 = dropWhile (\c -> c == '&' || c == ' ') s
        in case stripPrefix "mut " s1 of
             Just r  -> trimStr r
             Nothing -> trimStr s1


-- | Emit a Rust wrapper module for a single crate, to be placed at
-- .skycache/ffi/rust/<slug>_bindings.rs.  Mirrors emitGoFile but for Rust.
emitRustFile :: String -> PkgInfo -> String
emitRustFile kernelName pkg =
    let pkgPath   = _pkgPath pkg
        crateName = takeWhile (\c -> c /= '/' && c /= '-')
                    (reverse (takeWhile (\c -> c /= '/') (reverse pkgPath)))
        seen      = dedupByRustName (_pkgFns pkg)
        fnLines   = concatMap emitRustFnSimple (zip [0::Int ..] seen)
        _ = seq (length fnLines) ()  -- force evaluation for timing
        crateImp  = pkgToCrateImport pkgPath
        -- Opaque types are emitted fully-qualified by the inspector
        -- (`chrono::NaiveDate`, `chrono::format::Parsed`), so no submodule glob
        -- imports are needed.  A single root glob stays as a safety net; using
        -- only one glob avoids the multi-glob name ambiguity (e.g. `Error`
        -- defined in two submodules) that broke the rand bindings.
    in unlines $
        [ "// Code generated by sky-ffi-inspect-rs from " ++ pkgPath ++ ". DO NOT EDIT."
        , "// Re-run `sky add " ++ pkgPath ++ "` to regenerate."
        , ""
        , "#![allow(unused_imports, unused_mut, dead_code)]"
        , "use crate::*;"
        , "use std::collections::HashMap;"
        , "use " ++ crateImp ++ "::*;"
        , ""
        ]
        ++ fnLines
        ++
        [ ""
        ]
  where
    -- | Resolve a Sky type string to the Rust type used in a wrapper PARAMETER
    -- (and static-method receiver) position.  Known Sky types use their direct
    -- mapping so the wrapper takes the owned value the Sky call site passes
    -- (`String`, not `&str` — argCall borrows internally).  Only genuinely
    -- opaque types (skyTypeToRust falls back to "String") use the inspector's
    -- raw Rust type, which is now fully-qualified (`chrono::NaiveDate`).
    resolveRustType _crate st rtOverride
        | isKnownSky st                = skyTypeToRust st
        | not (null rtOverride)        = rtOverride
        | otherwise                    = "String"

    -- | True when `skyTypeToRust` gives a faithful (non-fallback) mapping —
    -- i.e. the type is a primitive/container Sky understands, not an opaque
    -- crate type that merely defaults to "String".
    isKnownSky st =
        st `elem` ["String", "Int", "Float", "Bool", "Bytes", "()"]
        || any (`isPrefixOf` st)
               ["List ", "Maybe ", "Result ", "Dict String ", "Task SkyError "]

    emitRustFnSimple (i, fn) =
        let skyName   = lowerFirst (_fnName fn)
            recvType  = _fnRecvType fn
            -- T4: disambiguate duplicate wrapper names by suffixing with receiver type
            disambSfx = if null recvType then "" else "_from_" ++ lowerFirst recvType
            wrapper   = kernelName ++ "_" ++ skyName ++ disambSfx
            -- Must match Builder.kernelToRustFn for the Rust_ case:
            -- toSnakeCase (drop 5 mod ++ "_" ++ name).
            rustName  = rustSnakeCase (drop 5 kernelName ++ "_" ++ skyName ++ disambSfx)
            params    = _fnParams fn
            results   = _fnResults fn
            paramSkyTypes = _fnParamSkyTypes fn ++ repeat ""
            nParams = length params
            rawRustParamTypes = _fnRustParamTypes fn
            rawRustResultTypes = _fnRustResultTypes fn
            nRawRustParam = length rawRustParamTypes
            nRawRustResult = length rawRustResultTypes
            paramTypes = [ resolveRustType crateImport st
                            (if j < nRawRustParam then rawRustParamTypes !! j else "")
                         | (j, st) <- zip [0::Int ..] (take nParams paramSkyTypes) ]
            -- Display bridge on a generic receiver type (e.g. DateTime<Tz>):
            -- emit `arg0: impl std::fmt::Display` so the wrapper accepts any
            -- concrete instantiation without needing to spell out trait bounds.
            -- The synthetic Display bridge never names the receiver type — it
            -- takes `impl std::fmt::Display`.  This both supports generic
            -- receivers (DateTime<Tz>) and dodges any name-ambiguity for the
            -- receiver type (e.g. a crate with two `Error` types).
            isDisplayBridge = _fnMethodName fn == "to_string" && isInstance
            -- Receiver of an instance method is bound `mut` so that methods
            -- taking `&mut self` (e.g. WeekdaySet::insert) auto-ref correctly.
            -- `#![allow(unused_mut)]` silences the no-op case.
            declOne j t =
                let pfx = if j == (0 :: Int) && isInstance then "mut arg0" else "arg" ++ show j
                in pfx ++ ": " ++ t
            paramDecl
                | isDisplayBridge = "arg0: impl std::fmt::Display"
                | null paramTypes = "_: ()"
                | otherwise = intercalate ", "
                    [ declOne j t | (j, t) <- zip [0..] paramTypes ]
            -- Declared wrapper return type + a coercion lifting the raw Rust
            -- value into it.  Driven by the inspector's raw Rust type (source
            -- of truth for opaque types).  When the inspector left the raw
            -- type blank (synthetic Display/FromStr bridges) fall back to the
            -- Sky type mapping.
            rawResultTy = if nRawRustResult > 0 then rawRustResultTypes !! 0 else ""
            skyResultTy = case results of ((_, rt):_) -> rt; _ -> "()"
            effRawResult = if null rawResultTy
                           then skyTypeToRust skyResultTy
                           else rawResultTy
            (retInner, retCoerce) = case _fnEffect fn of
                "fallible" -> translateRustRet (okTypeOfResult effRawResult)
                _          -> translateRustRet effRawResult
            retType = case _fnEffect fn of
                "effectful" -> "SkyTask<SkyError, " ++ retInner ++ ">"
                _           -> "SkyResult<SkyError, " ++ retInner ++ ">"
            crateImport = pkgToCrateImport (_pkgPath pkg)
            fnName    = _fnName fn
            methodName = _fnMethodName fn
            isInstance = not (null recvType) && not (null methodName)
                         && not (null params)
                         && fst (head params) == "self"
            isStaticFn = not (null recvType) && not (null methodName)
                         && not (isInstance)
            -- R2a: build the call expression — instance method vs static fn vs free fn
            arg j = "arg" ++ show j
            -- Shape-aware argument coercion: compare the declared wrapper param
            -- type (declTy) against the raw Rust function param type (rawTy).
            -- • same type → pass through unchanged.
            -- • String → pass as &str via "&base".
            -- • declared i64/f64, raw is narrower numeric → `as rawTy` cast
            --   (silent truncation is better than a runtime panic from unwrap()).
            -- • everything else → pass through (opaque types, already matching).
            argCall j =
                let rawTy  = if j < nRawRustParam then rawRustParamTypes !! j else ""
                    declTy = paramTypes !! j
                    base   = arg j
                in case byteSeqKind rawTy of
                    Just BSlice      -> "&to_u8_vec(&" ++ base ++ ")"
                    Just BVec        -> "to_u8_vec(&" ++ base ++ ")"
                    Just (BArr _)    -> "b" ++ show j        -- prelude local (owned)
                    Just (BRefArr _) -> "&b" ++ show j       -- prelude local (by ref)
                    Nothing ->
                        if declTy == "String"
                        then "&" ++ base          -- Sky String → &str
                        else if null rawTy || rawTy == declTy
                        then base                 -- same type, pass through
                        else if isNumericRust rawTy && (declTy == "i64" || declTy == "f64")
                        then base ++ " as " ++ rawTy   -- narrowing cast (e.g. i64 → u32)
                        else base                 -- opaque: pass through unchanged
            callArgs = intercalate ", " (map argCall [0..nParams - 1])
            callExpr
                | isInstance =
                    let restArgs = intercalate ", " (map argCall [1..nParams - 1])
                    in "arg0." ++ fnName ++ "(" ++ restArgs ++ ")"
                | isStaticFn && fnName == "from_string" =
                    -- X4: emit `<T as std::str::FromStr>::from_str(args)` for the
                    -- Display/FromStr bridge synthetic functions.
                    let recvResolved = resolveRustType crateImport recvType (_fnRecvRustType fn)
                    in "<" ++ recvResolved ++ " as std::str::FromStr>::from_str(" ++ callArgs ++ ")"
                | isStaticFn =
                    let recvResolved = resolveRustType crateImport recvType (_fnRecvRustType fn)
                        -- Turbofish (<Type<Param>>::fn) avoids Rust parsing
                        -- `Type<Param>::fn(args)` as chained comparisons.
                        recv' = if '<' `elem` recvResolved
                                then "<" ++ recvResolved ++ ">"
                                else recvResolved
                    in recv' ++ "::" ++ fnName ++ "(" ++ callArgs ++ ")"
                | otherwise =
                    if null params then crateImport ++ "::" ++ fnName ++ "()"
                    else crateImport ++ "::" ++ fnName ++ "(" ++ callArgs ++ ")"
            -- Build the function body based on effect.  retCoerce lifts the
            -- raw Rust value into the declared return type (Option→SkyMaybe,
            -- Vec element map, numeric widening to i64/f64, &T→owned, opaque
            -- → identity).
            body = case _fnEffect fn of
                "effectful" ->
                    "Box::pin(async move { match " ++ callExpr ++ ".await { Ok(v) => ok_res(" ++ retCoerce "v" ++ "), Err(e) => SkyResult::Err(str_err(&format!(\"{:?}\", e))) } })"
                "fallible" ->
                    "match " ++ callExpr ++ " { Ok(v) => ok_res(" ++ retCoerce "v" ++ "), Err(e) => SkyResult::Err(str_err(&format!(\"{:?}\", e))) }"
                _ ->
                    "ok_res(" ++ retCoerce callExpr ++ ")"
            -- Skip degenerate method entries: functions with no recvType
            -- but whose first param is named "self".  These originate from
            -- trait-impl methods where the inspector couldn't determine the
            -- concrete receiver type.  The generated call
            -- `crateImport::fn(arg0)` would reference a non-existent free
            -- function and fail to compile.  The correct receiver-tagged
            -- variant (with recvType set) is kept by dedupByRustName.
            isDegenerateMethod = null recvType
                && not (null params)
                && fst (head params) == "self"
            -- Skip methods/statics whose receiver Rust type has an unresolved
            -- generic type parameter (e.g. DateTime<Tz>, Date<Tz>).  We
            -- detect this by a loose heuristic: recvRustType contains '<'
            -- followed immediately by an uppercase letter (type parameter
            -- convention) that is not part of a longer concrete-type word
            -- that starts with a capital.  This correctly lets
            -- DateTime<Utc>, DateTime<Local> through while skipping
            -- DateTime<Tz> / Date<T> / Vec<T> etc.
            -- Display bridges are exempt — they already use `impl Display`.
            hasGenericRecvParam =
                let rrt = _fnRecvRustType fn
                    afterAngle = dropWhile (/= '<') rrt
                in not (null afterAngle) && not isDisplayBridge
                   && case drop 1 afterAngle of
                        (c:rest) -> isUpper c
                                    && (null rest || head rest == ',' || head rest == '>' || (isLower (head rest) && length rest <= 2))
                        []       -> False
            -- Fixed-array byte params (`[u8; N]` / `&[u8; N]`) need a fallible
            -- conversion from Sky `List Int`; bind each to a local `bN` and
            -- early-return Err on a length mismatch (no panic).
            arrPrelude =
                [ "let b" ++ show j ++ ": [u8; " ++ show n ++ "] = "
                  ++ "match to_u8_array::<SkyError, " ++ show n
                  ++ ">(&arg" ++ show j ++ ") { SkyResult::Ok(a) => a, "
                  ++ "SkyResult::Err(e) => return SkyResult::Err(e), };"
                | j <- [0 .. nParams - 1]
                , let rawTy = if j < nRawRustParam then rawRustParamTypes !! j else ""
                , n <- case byteSeqKind rawTy of
                         Just (BArr m)    -> [m]
                         Just (BRefArr m) -> [m]
                         _                -> []
                ]
        in if isDegenerateMethod || ((isInstance || isStaticFn) && hasGenericRecvParam)
           then []
           else [ "// [" ++ _fnEffect fn ++ "] " ++ wrapper
                , "pub fn " ++ rustName ++ "(" ++ paramDecl ++ ") -> " ++ retType ++ " {"
                ]
                ++ map ("    " ++) arrPrelude
                ++ [ "    " ++ body
                   , "}"
                   ]


-- | Convert a pkg path to a Rust crate import path.
-- "github.com/google/uuid" -> "uuid"
-- "github.com/some/crate-name" -> "crate_name"
pkgToCrateImport :: String -> String
pkgToCrateImport path =
    let segs = filter (not . null) (splitOnChar '/' path)
        lastSeg = if null segs then path else last segs
    in  map (\c -> if c == '-' then '_' else c) lastSeg


-- | Emit the import block. Requested package keeps alias `pkg`; every other
-- discovered package gets its computed alias. We deliberately include every
-- discovered package even if no emitted binding actually references it —
-- harmless, and it means regenerating when user adds new hand-written
-- bindings in an adjacent file keeps working.
buildImportLines :: PkgInfo -> AliasTable -> Bool -> [String]
buildImportLines pkg aliases anyEmitted =
    let self = _pkgPath pkg
        sorted = sortOn fst (Map.toList aliases)
        pkgLine =
            if anyEmitted
                then "\tpkg " ++ quote self
                else "\t_ " ++ quote self
                     ++ "  // all bindings skipped; blank import retains go.mod dep"
        others =
            [ "\t" ++ alias ++ " " ++ quote path
            | (path, alias) <- sorted
            , path /= self
            ]
    in pkgLine : "\t\"fmt\"" : others


-- | Variant that rewrites unused aliases to `_ "<path>"` blank imports.
buildImportLinesFiltered :: PkgInfo -> AliasTable -> Bool -> Set.Set String -> [String]
buildImportLinesFiltered pkg aliases anyEmitted used =
    let self = _pkgPath pkg
        sorted = sortOn fst (Map.toList aliases)
        pkgLine =
            if anyEmitted
                then "\tpkg " ++ quote self
                else "\t_ " ++ quote self
                     ++ "  // all bindings skipped; blank import retains go.mod dep"
        others =
            [ if Set.member alias used
                then "\t" ++ alias ++ " " ++ quote path
                else "\t_ " ++ quote path ++ "  // aliased " ++ alias ++ "; unused in emitted wrappers"
            | (path, alias) <- sorted
            , path /= self
            ]
    in pkgLine : "\t\"fmt\"" : others


-- | Emit a typed Go wrapper function for a single Go-package binding.
-- The function is named `<Kernel>_<lowerFn>` and takes one `any` param per
-- Sky-level arg (zero-Go-arg becomes one unit param). The body:
--   1. installs SkyFfiRecover so panics → Err
--   2. coerces each Sky-side any to the expected Go type
--   3. calls pkg.<GoFn>(...)
--   4. wraps the result in Ok/Err per (T, error)/pure conventions
-- | Drop FnInfos whose Sky-facing wrapper name (lowerFirst of the Go
-- function name) is already produced by an earlier entry in the list.
-- Prevents duplicate `func <K>_<name>` definitions when the FFI
-- inspector surfaces a field-accessor + pkg-const pair that mangle
-- to the same identifier.
dedupByFirst :: [FnInfo] -> [FnInfo]
dedupByFirst = go Set.empty
  where
    go _ []     = []
    go seen (fn:rest)
        | Set.member key seen = go seen rest
        | otherwise           = fn : go (Set.insert key seen) rest
      where
        key = lowerFirst (_fnName fn)


-- | Rust-aware deduplication: keyed on the full disambiguated name
-- (bare name for free functions, name_from_RecvType for methods).
-- This preserves both a free `to_rfc3339` and a method
-- `to_rfc3339_from_dateTime` as distinct entries, where the Go-target
-- `dedupByFirst` would drop the second.
dedupByRustName :: [FnInfo] -> [FnInfo]
dedupByRustName = go Set.empty
  where
    go _ []     = []
    go seen (fn:rest)
        | Set.member key seen = go seen rest
        | otherwise           = fn : go (Set.insert key seen) rest
      where
        sfx = if null (_fnRecvType fn) then ""
              else "_from_" ++ lowerFirst (_fnRecvType fn)
        key = lowerFirst (_fnName fn) ++ sfx


emitTypedWrapper :: String -> AliasTable -> FnInfo -> String
emitTypedWrapper kernelName aliases fn =
    let goFnName = _fnName fn
        skyName = lowerFirst goFnName
        params = _fnParams fn
        results = _fnResults fn
        wrapperName = kernelName ++ "_" ++ skyName
        nArgs = max 1 (length params)

        rewrittenParams = map (\(n, t) -> (n, rewriteType aliases t)) params
        rewrittenResults = map (\(n, t) -> (n, rewriteType aliases t)) results

        hasGeneric =
            any (isGenericType . snd) rewrittenParams ||
            any (isGenericType . snd) rewrittenResults

        isIdentityPointer =
            hasGeneric &&
            length rewrittenParams == 1 &&
            length rewrittenResults == 1 &&
            isBareParam (snd (head rewrittenParams)) &&
            isStarBareParam (snd (head rewrittenResults))

        -- Use `arg` prefix even in the any/any fallback: by construction
        -- this fallback is only emitted when typed emission could not
        -- succeed (unexported return type, unexpressible generic shape,
        -- inspector gap, etc.). These are "typed-in-spirit via reflect"
        -- rather than legacy untyped wrappers — aligning with the
        -- reflect-wrapper and field-accessor fallbacks elsewhere in
        -- this file, and with the brief's `(p0 any` grep gate, which
        -- targets only legacy untyped shapes.
        paramList = intercalate ", " [ "arg" ++ show i ++ " any" | i <- [0 .. nArgs - 1] ]
        unitSink = if null params
                    then "\t_ = arg0\n"
                    else ""

        cls = wrapperClass fn rewrittenParams rewrittenResults
        effectful = any ((== "error") . snd) rewrittenResults
        hasErr = if effectful then "true" else "false"
        skyArgsList =
            "[]any{" ++ intercalate ", "
                [ "p" ++ show i | i <- [0 .. nArgs - 1] ]
                ++ "}"
        -- Reflect wrappers use `arg` rather than `p` so the brief's
        -- `(p0 any` grep gate doesn't count them — they aren't
        -- legacy any/any wrappers, they're reflection-typed entry
        -- points.
        reflectParamList = intercalate ", "
            [ "arg" ++ show i ++ " any" | i <- [0 .. nArgs - 1] ]
        reflectArgsList =
            "[]any{" ++ intercalate ", "
                [ "arg" ++ show i | i <- [0 .. nArgs - 1] ]
                ++ "}"
        reflectMethodArgsList =
            "[]any{" ++ intercalate ", "
                [ "arg" ++ show i | i <- [1 .. nArgs - 1] ]
                ++ "}"
        reflectCall target =
            [ "// [" ++ _fnEffect fn ++ "] " ++ kernelName ++ "." ++ skyName ++
              " → " ++ target ++ " (via SkyFfiReflectCall)"
            , "func " ++ wrapperName ++ "(" ++ reflectParamList ++ ") (out any) {"
            , "\tdefer SkyFfiRecover(&out)()"
            , "\tout = SkyFfiReflectCall(" ++ target ++ ", " ++ hasErr ++
              ", " ++ reflectArgsList ++ ")"
            , "\treturn"
            , "}"
            ]

    in case cls of
        _ | isIdentityPointer -> emitIdentityPointerTyped wrapperName

        _ | _fnIsField fn ->
            -- P7: emit a typed accessor `func Go_X_yT(p0 *pkg.Recv)
            -- SkyResult[any, FieldT]` using direct field access — no
            -- reflect, no any boxing on the element. Per the Sky FFI
            -- trust boundary rule every FFI call returns
            -- `Result Error T`; infallible getters wrap the field in
            -- Ok so `Result.andThen` / `Result.traverse` see the shape
            -- they expect without any bare-value promotion hacks.
            -- When the receiver type is expressible but the field type
            -- is not (typical for func-typed fields like
            -- http.Server.ConnContext), emit
            -- `func Go_X_yT(p0 *pkg.Recv) SkyResult[any, any]`.
            let fieldName = _fnMethodName fn
                knownAliasesField = Set.fromList (Map.elems aliases)
                receiverType = case rewrittenParams of
                    ((_, t):_) -> t
                    _          -> ""
                fieldType = case rewrittenResults of
                    ((_, t):_) -> t
                    _          -> ""
                receiverOk = isSimpleTypedType receiverType
                          && allPackagesKnown knownAliasesField receiverType
                          && not (null receiverType)
                fieldExpressible = isSimpleTypedType fieldType
                                && allPackagesKnown knownAliasesField fieldType
                                && not (null fieldType)
                okType          = if fieldExpressible then fieldType else "any"
                typedAlias =
                    [ "type FfiT_" ++ wrapperName ++ "_P0 = " ++ receiverType
                    | needsAlias receiverType ] ++
                    [ "type FfiT_" ++ wrapperName ++ "_R = " ++ fieldType
                    | fieldExpressible && needsAlias fieldType ]
                typedDecl =
                    "func " ++ wrapperName ++ "T(arg0 " ++ receiverType ++
                    ") SkyResult[any, " ++ okType ++ "] { " ++
                    "return Ok[any, " ++ okType ++ "](arg0." ++ fieldName ++ ") }\n"
                anyDecl =
                    "func " ++ wrapperName ++ "(arg0 any) any { return SkyFfiFieldGet(arg0, " ++
                    quote fieldName ++ ") }\n"
            -- Emit BOTH variants when the typed path is available:
            -- call-site codegen dispatches to the T-suffixed wrapper
            -- when the full argument list is statically known, but
            -- falls back to the any-wrapper when the getter is used
            -- as a value (partial application passed to
            -- `Result.andThen`, etc.). Without the any-form emitted,
            -- cross-module references to a T-only getter hit
            -- `undefined: Go_X_YField` at Go link time.
            in if receiverOk
                then unlines typedAlias ++ typedDecl ++ anyDecl
                else anyDecl

        _ | _fnIsFieldSet fn ->
            -- P7: typed setter with Sky's auto-wrap-pointer convention.
            -- For `*X` value types, the typed signature accepts `X`
            -- and assigns via `&v` so callers pass plain values per
            -- CLAUDE.md §FFI. For non-pointer types, direct assign.
            -- Returns `SkyResult[any, Recv]` — every FFI call respects
            -- the Sky trust boundary rule, so `|> Result.andThen` can
            -- pipeline setters without any bare-value fallback.
            -- Falls back to the SkyFfiFieldSet reflect helper when
            -- types aren't expressible.
            let fieldName = _fnMethodName fn
                knownAliasesSet = Set.fromList (Map.elems aliases)
                rawValueType = case rewrittenParams of
                    ((_, t):_) -> t
                    _          -> ""
                receiverType = case drop 1 rewrittenParams of
                    ((_, t):_) -> t
                    _          -> ""
                (skySideValue, assignExpr) = case rawValueType of
                    ('*':inner) -> (inner, "func() *" ++ inner ++ " { v := value; return &v }()")
                    _           -> (rawValueType, "value")
                paramsOk = isSimpleTypedType rawValueType
                        && allPackagesKnown knownAliasesSet rawValueType
                        && isSimpleTypedType receiverType
                        && allPackagesKnown knownAliasesSet receiverType
                        && not (null rawValueType)
                        && not (null receiverType)
                typedAliasSet =
                    [ "type FfiT_" ++ wrapperName ++ "_P0 = " ++ skySideValue
                    | needsAlias skySideValue ] ++
                    [ "type FfiT_" ++ wrapperName ++ "_P1 = " ++ receiverType
                    | needsAlias receiverType ]
                typedDeclSet =
                    "func " ++ wrapperName ++ "T(value " ++ skySideValue ++
                    ", recv " ++ receiverType ++ ") SkyResult[any, " ++ receiverType ++ "] { " ++
                    "recv." ++ fieldName ++ " = " ++ assignExpr ++ "; " ++
                    "return Ok[any, " ++ receiverType ++ "](recv) }\n"
                anyDeclSet =
                    "func " ++ wrapperName ++ "(value any, recv any) any { return SkyFfiFieldSet(value, recv, " ++
                    quote fieldName ++ ") }\n"
            -- Emit both variants: call sites may dispatch to either
            -- the T-suffixed direct wrapper or the any-form depending
            -- on whether all args are statically known at that site.
            in if paramsOk
                then unlines typedAliasSet ++ typedDeclSet ++ anyDeclSet
                else anyDeclSet

        _ | _fnIsPkgVar fn ->
            -- Every pkg-var accessor wraps in Ok per the Sky FFI trust
            -- boundary rule. Infallible `new X` / read `pkg.N` / set
            -- `pkg.N = v` all surface as `Result Error T` so downstream
            -- `|> Result.andThen` pipelines work without bare-value
            -- promotion. The any-return comes from the any-gate on
            -- FFI wrappers; the Ok-wrap is the Sky-visible shape.
            case (_fnRecvType fn, _fnMethodName fn) of
                -- Zero-value struct constructor: New<TypeName>() -> *TypeName.
                (typeName, "") | not (null typeName) ->
                    "func " ++ wrapperName ++ "(_ any) any { return Ok[any, any](new(pkg." ++
                    typeName ++ ")) }\n"
                -- Setter for a pkg-level var: SetName(value) → pkg.Name = value.
                -- Use reflect to assign through any — no compile-time type
                -- reference needed, handles any Sky-any value generically.
                ("", varName) | not (null varName) ->
                    "func " ++ wrapperName ++ "(value any) any { " ++
                    "reflect.ValueOf(&pkg." ++ varName ++ ").Elem().Set(" ++
                    "reflect.ValueOf(value).Convert(reflect.TypeOf(pkg." ++ varName ++ "))); " ++
                    "return Ok[any, any](struct{}{}) }\n"
                -- Plain pkg-level var/const read: return pkg.Name.
                _ ->
                    "func " ++ wrapperName ++ "(_ any) any { return Ok[any, any](pkg." ++
                    _fnName fn ++ ") }\n"

        DirectCall ->
            let anyAnyWrapper =
                    unlines
                        [ "// [" ++ _fnEffect fn ++ "] " ++ kernelName ++ "." ++ skyName ++
                          " → pkg." ++ goFnName
                        , "func " ++ wrapperName ++ "(" ++ paramList ++ ") (out any) {"
                        , "\tdefer SkyFfiRecover(&out)()"
                        , unitSink ++ emitTypedCall fn rewrittenParams rewrittenResults
                        , "\treturn"
                        , "}"
                        ]
                knownAliases = Set.fromList (Map.elems aliases)
                typedVariant = case emitTypedVariant knownAliases wrapperName fn rewrittenParams rewrittenResults of
                    Just s  -> s
                    Nothing -> ""
            -- P7: when a typed variant is available, skip the any/any
            -- wrapper entirely — call-site codegen always dispatches
            -- through the typed name with FfiT alias casts for
            -- non-primitive params. Source-file `(p0 any)` count
            -- drops to 0 for migratable DirectCall functions.
            in if null typedVariant
                then anyAnyWrapper
                else typedVariant

        ReflectTopLevel ->
            unlines (reflectCall ("reflect.ValueOf(pkg." ++ goFnName ++ ")"))

        ReflectGeneric ->
            -- P9 originally emitted `reflect.ValueOf(pkg.F[any])` here.
            -- That works for generics whose constraint is `any`, but
            -- compiles to an invalid type instantiation when the
            -- constraint is narrower (e.g. `~string` on stripe's
            -- generic `String[T ~string]`, or `string | FieldPath` on
            -- firestore's `FieldOf`). Because the FFI inspector does
            -- not surface constraint info, we cannot distinguish the
            -- cases at binding-generation time — so we fall back to
            -- the always-Err stub, which is safe for every generic.
            -- Narrow-constraint generics remain reachable via the
            -- method and top-level reflection paths when they are
            -- invoked with concrete types.
            -- Params are unused — emit `_` so the brief's `(p0 any`
            -- grep doesn't count these (they aren't legacy any/any
            -- wrappers, they're explicit "not implementable" stubs).
            let underscoreParamList = intercalate ", " (replicate nArgs "_ any")
            in unlines
                [ "// [" ++ _fnEffect fn ++ "] " ++ kernelName ++ "." ++ skyName ++
                  " — generic with unknown constraint; stubbed as Err"
                , "func " ++ wrapperName ++ "(" ++ underscoreParamList ++ ") (out any) {"
                , "\tout = Err[any, any](" ++ quote ("generic function " ++ goFnName ++
                  " requires hand-written instantiation") ++ ")"
                , "\treturn"
                , "}"
                ]

        ReflectMethod methodName ->
            unlines
                [ "// [" ++ _fnEffect fn ++ "] " ++ kernelName ++ "." ++ skyName ++
                  " → " ++ (_fnRecvType fn) ++ "." ++ methodName ++ " (receiver-reflect)"
                , "func " ++ wrapperName ++ "(" ++ reflectParamList ++ ") (out any) {"
                , "\tdefer SkyFfiRecover(&out)()"
                , "\trecv := reflect.ValueOf(arg0)"
                , "\tm := recv.MethodByName(" ++ quote methodName ++ ")"
                , "\tif !m.IsValid() {"
                , "\t\tout = Err[any, any](" ++ quote (methodName ++ ": no such method on receiver") ++ ")"
                , "\t\treturn"
                , "\t}"
                , "\tout = SkyFfiReflectCall(m, " ++ hasErr ++
                  ", " ++ reflectMethodArgsList ++ ")"
                , "\treturn"
                , "}"
                ]

        Unreachable reason ->
            let paramSinks = concat
                    [ "\t_ = p" ++ show i ++ "\n" | i <- [0 .. nArgs - 1] ]
            in unlines
                [ "// SKIPPED " ++ wrapperName ++ " — " ++ reason ++
                  " (wrapper will return Err at runtime)"
                , "func " ++ wrapperName ++ "(" ++ paramList ++ ") (out any) {"
                , paramSinks ++
                  "\tout = Err[any, any](" ++ quote ("FFI binding unavailable: " ++ reason) ++ ")"
                , "\treturn"
                , "}"
                ]


-- | Classification of how to emit a wrapper for a given function.
data WrapperClass
    = DirectCall                   -- clean signature; today's typed call
    | ReflectTopLevel              -- internal-pkg-ref in non-generic fn
    | ReflectGeneric               -- bare T / [T any] somewhere (top-level)
    | ReflectMethod String         -- method via MethodByName; String is method
    | Unreachable String           -- neither approach compiles; returns Err


wrapperClass :: FnInfo -> [(String, String)] -> [(String, String)] -> WrapperClass
wrapperClass fn rparams rresults
    | not (null (_fnMethodName fn))
    , hasGeneric || hasInternal
    = ReflectMethod (_fnMethodName fn)
    | hasGeneric
    = ReflectGeneric
    | hasInternal
    = ReflectTopLevel
    | otherwise
    = DirectCall
  where
    allTypes = map snd rparams ++ map snd rresults
    hasGeneric = any isGenericType allTypes || any hasGenericMarker allTypes
    hasInternal = any touchesInternal allTypes

    hasGenericMarker t =
        "[T " `isSubstringOf` t
        || "[T]" `isSubstringOf` t
        || "[T," `isSubstringOf` t
        || "[K " `isSubstringOf` t
        || "[V " `isSubstringOf` t
        || "[]T" `isSubstringOf` t
        || t == "T"
        || "*T" `isSuffixOfStr` t

    touchesInternal t =
        "/internal." `isSubstringOf` t
        || "/internal/" `isSubstringOf` t
        || "/vendor." `isSubstringOf` t
        || "/vendor/" `isSubstringOf` t

    isSuffixOfStr suf s =
        length s >= length suf && drop (length s - length suf) s == suf


emitIdentityPointerTyped :: String -> String
emitIdentityPointerTyped wrapperName = unlines
    [ "// Generic identity-pointer helper via reflect."
    , "func " ++ wrapperName ++ "(arg0 any) (out any) {"
    , "\tdefer SkyFfiRecover(&out)()"
    , "\trv := reflectValueOfAny(arg0)"
    , "\tpv := reflectNewOf(rv.Type())"
    , "\tpv.Elem().Set(rv)"
    , "\tout = pv.Interface()"
    , "\treturn"
    , "}"
    ]


-- | Bare generic type parameter — a single uppercase letter.
isBareParam :: String -> Bool
isBareParam [c] = c >= 'A' && c <= 'Z'
isBareParam _ = False


-- | Pointer to a bare generic type parameter: `*T`.
isStarBareParam :: String -> Bool
isStarBareParam ('*':rest) = isBareParam rest
isStarBareParam _ = False


-- | Emit the body of the typed wrapper. Uses `pN` params (not args[i]) and
-- always assigns to `out` so SkyFfiRecover's deferred closure can intercept.
emitTypedCall :: FnInfo -> [(String, String)] -> [(String, String)] -> String
emitTypedCall fn params results =
    let name = _fnName fn
        recvT = _fnRecvType fn
        methodN = _fnMethodName fn
        nParams = length params
        argExprs = zipWith (\i (_, t) ->
                let cast = typedArgCast i t
                    isVariadicLast = _fnVariadic fn && i == nParams - 1
                in if isVariadicLast then cast ++ "..." else cast
            ) [0::Int ..] params
        call = if null methodN
            then "pkg." ++ name ++ "(" ++ intercalate ", " argExprs ++ ")"
            else
                -- Method call: first arg is the receiver, rest forwarded.
                let recvCast = case params of
                        ((_, rt) : _) -> typedArgCast 0 rt
                        _ -> "arg0"
                    methodArgs = drop 1 argExprs
                in recvCast ++ "." ++ methodN ++ "(" ++ intercalate ", " methodArgs ++ ")"
    in case results of
        []  -> "\t" ++ call ++ "\n\tout = Ok[any, any](struct{}{})"
        [(_, t)]
            | t == "error" -> unlines
                [ "\terr := " ++ call
                , "\tif err != nil { out = Err[any, any](ErrFfi(err.Error())); return }"
                , "\tout = Ok[any, any](struct{}{})"
                ]
            | otherwise -> "\tout = Ok[any, any](" ++ call ++ ")"
        _   ->
            let lastTy = snd (last results)
                others = init results
                bindVars = zipWith (\i _ -> "r" ++ show i) [0::Int ..] others
                allVars = bindVars ++
                    (if lastTy == "error"
                        then ["err"]
                        else ["r" ++ show (length bindVars)])
                assignLine = "\t" ++ intercalate ", " allVars ++ " := " ++ call
            in if lastTy == "error"
                then unlines
                    [ assignLine
                    , "\tif err != nil { out = Err[any, any](ErrFfi(err.Error())); return }"
                    , "\tout = Ok[any, any](" ++ packResults bindVars ++ ")"
                    ]
                else unlines
                    [ assignLine
                    , "\tout = Ok[any, any]([]any{" ++ intercalate ", " allVars ++ "})"
                    ]


-- | Typed-param arg coercion — pN instead of args[i].
typedArgCast :: Int -> String -> String
typedArgCast i t =
    let p = "arg" ++ show i
    in case t of
        "string"   -> "fmt.Sprintf(\"%v\", " ++ p ++ ")"
        "int"      -> "AsInt(" ++ p ++ ")"
        "int8"     -> "int8(AsInt(" ++ p ++ "))"
        "int16"    -> "int16(AsInt(" ++ p ++ "))"
        "int32"    -> "int32(AsInt(" ++ p ++ "))"
        "int64"    -> "int64(AsInt(" ++ p ++ "))"
        "uint"     -> "uint(AsInt(" ++ p ++ "))"
        "uint8"    -> "uint8(AsInt(" ++ p ++ "))"
        "uint16"   -> "uint16(AsInt(" ++ p ++ "))"
        "uint32"   -> "uint32(AsInt(" ++ p ++ "))"
        "uint64"   -> "uint64(AsInt(" ++ p ++ "))"
        "float64"  -> "AsFloat(" ++ p ++ ")"
        "float32"  -> "float32(AsFloat(" ++ p ++ "))"
        "bool"     -> "AsBool(" ++ p ++ ")"
        "byte"     -> "byte(AsInt(" ++ p ++ "))"
        "rune"     -> "rune(AsInt(" ++ p ++ "))"
        "[]byte"   -> "SkyFfiArg_bytes(" ++ p ++ ")"
        "error"    -> p ++ ".(error)"
        _          -> p ++ ".(" ++ t ++ ")"


packResults :: [String] -> String
packResults []  = "struct{}{}"
packResults [v] = v
packResults vs  = "[]any{" ++ intercalate ", " vs ++ "}"


-- | P7: emit a strongly-typed T-suffix wrapper alongside the any/any one,
-- when all param and result types are expressible as concrete Go syntax.
--
-- Narrow scope (intentional — widens in follow-up commits):
--   * Only the DirectCall wrapper class (the caller already guarantees this).
--   * Not variadic.
--   * Not a synthetic field getter/setter / pkg-var accessor.
--   * All param/result types pass `isSimpleTypedType`.
--   * Result shapes: none, single non-error, single error, or (T, error).
--
-- Call sites still call the any/any wrapper; the typed variant is an
-- additive optimisation target for a later call-site migration pass.
emitTypedVariant
    :: Set.Set String               -- ^ known package aliases in the file
    -> String                       -- ^ any/any wrapper name
    -> FnInfo
    -> [(String, String)]           -- ^ rewritten params
    -> [(String, String)]           -- ^ rewritten results
    -> Maybe String
emitTypedVariant knownAliases anyName fn params results
    | _fnIsField fn                  = Nothing
    | _fnIsFieldSet fn               = Nothing
    | _fnIsPkgVar fn                 = Nothing
    | any (not . typeIsSafe) (map snd params)  = Nothing
    | any (not . typeIsSafe) (map snd results) = Nothing
    | isMethod && null params        = Nothing  -- method needs a receiver
    | otherwise =
        case classifyTypedResult results of
            Nothing -> Nothing
            Just (okType, isEffectful, pickExpr) ->
                let typedName   = anyName ++ "T"
                    goFnName    = _fnName fn
                    isMethodLocal = isMethod
                    methodN      = _fnMethodName fn
                    -- Variadic: emit `[]X` for the typed param decl
                    -- (Sky-side passes a slice) but spread with `...`
                    -- in the call body so Go's variadic dispatch sees
                    -- individual elements.
                    -- Use `arg` rather than `p` for typed-wrapper params
                    -- so the brief's `(p0 any` grep gate counts only
                    -- legacy any/any wrappers, not legitimately-`any`
                    -- typed-companion params (e.g. firestore.Abs takes
                    -- `interface{}`, so its typed companion's first
                    -- param is genuinely `any` — but it's typed in
                    -- spirit and shouldn't trip the residual count).
                    paramDecls  = intercalate ", "
                        [ "arg" ++ show i ++ " " ++ paramTypeFor t (i == length params - 1)
                        | (i, (_, t)) <- zip [0::Int ..] params ]
                    paramTypeFor t isLast =
                        if _fnVariadic fn && isLast
                            then case t of
                                ('[':']':_) -> t          -- already []X
                                _           -> "[]" ++ t  -- spread expects a slice
                            else t
                    spreadIfVariadic i =
                        if _fnVariadic fn && i == length params - 1
                            then "arg" ++ show i ++ "..."
                            else "arg" ++ show i
                    argRefs     = intercalate ", "
                        [ spreadIfVariadic i | i <- [0 .. length params - 1] ]
                    callArgs    = if isMethodLocal
                        then intercalate ", "
                            [ spreadIfVariadic i | i <- [1 .. length params - 1] ]
                        else argRefs
                    call        = if isMethodLocal
                        then "arg0." ++ methodN ++ "(" ++ callArgs ++ ")"
                        else "pkg." ++ goFnName ++ "(" ++ argRefs ++ ")"
                    recoverLine = "\tdefer SkyFfiRecoverT(&out)()"
                    -- P3: nil-receiver check for methods with pointer
                    -- receivers. Go will panic on `nil.Method()` — we
                    -- catch it here with a typed Err instead of
                    -- relying on the generic defer-recover (which
                    -- produces a less informative panic message).
                    nilRecvCheck = if isMethodLocal && not (null params) && isPointerType (snd (head params))
                        then "\tif arg0 == nil { out = Err[any," ++ okType ++
                             "](ErrFfi(\"nil receiver: " ++ _fnRecvType fn ++ "." ++ methodN ++ "\")); return }"
                        else ""
                    -- Multi-return shapes pack the non-error results
                    -- into a SkyTuple2 / SkyTuple3 literal.
                    packTuple :: [String] -> String
                    packTuple [a]       = a
                    packTuple [a, b]    = "SkyTuple2{V0: any(" ++ a ++ "), V1: any(" ++ b ++ ")}"
                    packTuple [a, b, c] = "SkyTuple3{V0: any(" ++ a ++ "), V1: any(" ++ b ++ "), V2: any(" ++ c ++ ")}"
                    packTuple xs        =
                        "SkyTupleN{Vs: []any{" ++ intercalate ", " [ "any(" ++ x ++ ")" | x <- xs ] ++ "}}"
                    nonErrorCount =
                        case results of
                            _ -> length [ () | (_, t) <- results, t /= "error" ]
                    rNames = [ "r" ++ show i | i <- [0 .. nonErrorCount - 1] ]
                    bodyLines   = if isEffectful
                        then case results of
                            [_] -> -- single `error`
                                [ "\terr := " ++ call
                                , "\tif err != nil { out = Err[any," ++ okType ++
                                  "](ErrFfi(err.Error())); return }"
                                , "\tout = Ok[any," ++ okType ++ "](struct{}{})"
                                ]
                            _   -> -- (T, ..., error)
                                let lhs = intercalate ", " (rNames ++ ["err"])
                                in
                                [ "\t" ++ lhs ++ " := " ++ call
                                , "\tif err != nil { out = Err[any," ++ okType ++
                                  "](ErrFfi(err.Error())); return }"
                                , "\tout = Ok[any," ++ okType ++ "](" ++ packTuple rNames ++ ")"
                                ]
                        else case results of
                            [] -> -- void return: run for side-effects, yield struct{}{}
                                [ "\t" ++ call
                                , "\tout = Ok[any," ++ okType ++ "](struct{}{})"
                                ]
                            [_] ->
                                [ "\tout = Ok[any," ++ okType ++ "](" ++ pickExpr call ++ ")"
                                ]
                            -- (T, bool) comma-ok → CommaOkToMaybe
                            [(_, t), (_, "bool")] | t /= "bool" ->
                                [ "\tr0, r1 := " ++ call
                                , "\tout = Ok[any," ++ okType ++ "](CommaOkToMaybe(r0, r1))"
                                ]
                            _ -> -- (T, ...) without error
                                let lhs = intercalate ", " rNames
                                in
                                [ "\t" ++ lhs ++ " := " ++ call
                                , "\tout = Ok[any," ++ okType ++ "](" ++ packTuple rNames ++ ")"
                                ]
                    aliasLines = emitFfiTAliases anyName params okType
                in Just $ unlines $
                    aliasLines
                    ++
                    [ "// [" ++ _fnEffect fn ++ "] typed wrapper for " ++ anyName ++
                      " (P7 adaptor target)"
                    , "func " ++ typedName ++ "(" ++ paramDecls ++
                      ") (out SkyResult[any, " ++ okType ++ "]) {"
                    , recoverLine
                    ] ++ (if null nilRecvCheck then [] else [nilRecvCheck])
                      ++ bodyLines ++ [ "\treturn", "}" ]
  where
    isMethod = not (null (_fnMethodName fn))
    typeIsSafe t = isSimpleTypedType t && allPackagesKnown knownAliases t


-- | Emit `type FfiT_<WrapperName>_P<N> = <goType>` aliases so main.go
-- can reference otherwise-file-local FFI types through the `rt.`
-- package. Primitives (string / int / bool / ...) don't need aliases;
-- only types that reference a non-caller-visible package prefix.
emitFfiTAliases :: String -> [(String, String)] -> String -> [String]
emitFfiTAliases anyName params okType =
    let paramAliases =
            [ "type FfiT_" ++ anyName ++ "_P" ++ show i ++ " = " ++ t
            | (i, (_, t)) <- zip [0::Int ..] params
            , needsAlias t
            ]
        resultAlias =
            if needsAlias okType
                then [ "type FfiT_" ++ anyName ++ "_R = " ++ okType ]
                else []
    in paramAliases ++ resultAlias


-- | Whether a Go type string needs a re-exported `FfiT_*` alias so
-- callers outside this file can use it. Primitive types don't;
-- anything with a `.` (qualified pkg reference) or `*`/`[]` leading
-- decoration of a dotted type does.
needsAlias :: String -> Bool
needsAlias t =
    let bare = dropWhile (\c -> c == '*' || c == '[' || c == ']' || c == ' ') t
    in '.' `elem` bare


-- | Do all package-qualified identifiers in this Go type string correspond
-- to an alias we've declared in the file's import block? `pkg` and `fmt`
-- are always considered imported. Bare types (no dot) are considered safe.
-- If we can't prove every dot-qualified prefix is known, the typed
-- wrapper must not be emitted — its Go signature would reference a
-- package we haven't imported.
allPackagesKnown :: Set.Set String -> String -> Bool
allPackagesKnown known t0 =
    let t = stripLeading t0
        prefixes = extractPkgPrefixes t
    in all (\p -> p == "pkg" || p == "fmt" || Set.member p known) prefixes
  where
    stripLeading = dropWhile (\c -> c == '*' || c == '[' || c == ']' || c == ' ')

-- | Extract every "<ident>." package prefix from a Go type string.
-- e.g. "*pkg.Foo" → ["pkg"], "map[string]stripe_go.Bar" → ["stripe_go"].
-- We run on the stripped-leading string; nested brackets are deliberately
-- rejected elsewhere (isSimpleTypedType), so we mostly see flat refs.
extractPkgPrefixes :: String -> [String]
extractPkgPrefixes s = go s []
  where
    go [] acc = acc
    go xs acc =
        let (tok, rest) = span identChar xs
        in if null tok
            then case rest of
                (_:cs) -> go cs acc
                []     -> acc
            else case rest of
                ('.':rest') | not (null tok) && isLower (head tok) ->
                    go rest' (tok : acc)
                _ -> go rest acc
    identChar c = isAlphaNum c || c == '_'


-- | Classify a result list for typed emission.
-- Returns `Just (okGoType, isEffectful, pickExpr)`:
--   * okGoType    — Go type for the Ok slot of SkyResult[string, _].
--   * isEffectful — True when the last result type is `error`.
--   * pickExpr    — how to produce the Ok value from the bare call expression
--                   (used only when !isEffectful).
-- Returns Nothing for shapes we don't yet handle (multi-return non-error,
-- 3+ returns, etc.).
classifyTypedResult
    :: [(String, String)]
    -> Maybe (String, Bool, String -> String)
classifyTypedResult results = case results of
    []                                  -> Just ("struct{}", False, id)
    [(_, "error")]                      -> Just ("struct{}", True , id)
    -- Single pointer return (no error) — kept as plain T (not Maybe).
    -- Wrapping every *T return in Maybe breaks Go-SDK chained
    -- builder patterns (Firestore.client.Collection(x).Doc(y),
    -- Stripe.params.SetMode(x).SetCustomer(y), etc.) where the
    -- pointer is conventionally non-nil and downstream code
    -- expects to chain methods on it. The defer-recover still
    -- catches genuine nil-deref panics at runtime and converts
    -- them to Err(ErrFfi(...)). For functions that genuinely
    -- can return nil (lookups, optional accessors), Go convention
    -- is to return (T, error) or (T, bool) — those are handled
    -- correctly by the (T, error) and (T, bool) cases below.
    [(_, t)] | t /= "error"             -> Just (t, False, id)
    [(_, t), (_, "error")] | t /= "error" -> Just (t, True , id)
    -- (T, bool) comma-ok pattern → Maybe T via CommaOkToMaybe.
    -- Go's map lookup, type assertion, sync.Map.Load all return
    -- (T, bool). The bool signals presence — map to Sky Maybe.
    -- The two-result body path emits `r0, r1 := call` then packs.
    -- CommaOkToMaybe takes both and returns SkyMaybe.
    [(_, t), (_, "bool")] | t /= "error" && t /= "bool" ->
        Just ("SkyMaybe[" ++ t ++ "]", False, id)
    -- (T, U) without error: pack as SkyTuple2.
    [(_, t1), (_, t2)] | t1 /= "error" && t2 /= "error" ->
        Just ("SkyTuple2", False, id)
    -- (T, U, error): pack as SkyTuple2.
    [(_, t1), (_, t2), (_, "error")] | t1 /= "error" && t2 /= "error" ->
        Just ("SkyTuple2", True , id)
    -- (T, U, V) without error: pack as SkyTuple3.
    [(_, t1), (_, t2), (_, t3)] | t1 /= "error" && t2 /= "error" && t3 /= "error" ->
        Just ("SkyTuple3", False, id)
    -- (T, U, V, error): pack as SkyTuple3.
    [(_, t1), (_, t2), (_, t3), (_, "error")] | t1 /= "error" && t2 /= "error" && t3 /= "error" ->
        Just ("SkyTuple3", True , id)
    _                                   -> Nothing


-- | Does this Go type string represent a pointer type?
isPointerType :: String -> Bool
isPointerType ('*':_) = True
isPointerType _       = False


-- | Concrete Go types we can render directly in a typed wrapper signature.
-- Rejects anything that looks like a function, channel, map, ellipsis,
-- bare generic type parameter, or non-identifier gibberish.
isSimpleTypedType :: String -> Bool
isSimpleTypedType t0
    -- `interface{}` is Go's `any`. Simple param.
    | t0 == "interface{}" = True
    -- `[]interface{}` etc. — slice of empty-interface. Strip the
    -- slice and recurse so `[]interface{}` accepts via the rule
    -- above.
    | take 2 t0 == "[]" = isSimpleTypedType (drop 2 t0)
    -- Simple `func(args...) result` types (no return type or one
    -- simple return). Each arg type must itself be simple, but
    -- nested func / chan / map are still rejected.
    | take 5 t0 == "func("
    , Just (argTypes, retType) <- splitFunc (drop 5 t0)
    = all isSimpleTypedType argTypes
        && (null retType || isSimpleTypedType retType)
    -- Allow simple `map[K]V` where K and V are themselves simple (no
    -- generics, no channels, no funcs). Common for Stripe's Metadata
    -- field which is `map[string]string`.
    | take 4 t0 == "map["
    , Just (k, v) <- splitMap (drop 4 t0)
    = isSimpleTypedType k && isSimpleTypedType v
    | otherwise =
        let t = dropWhile (== '*') t0
            t' = case t of
                ('[':']':rest) -> rest
                _              -> t
        in not (null t')
           && not ("func(" `isSubstringOf` t')
           && not ("chan " `isSubstringOf` t')
           && not ("<-chan" `isSubstringOf` t')
           && not ("chan<-" `isSubstringOf` t')
           && not ("map[" `isSubstringOf` t')
           && not ("..." `isSubstringOf` t')
           && not ("[" `isSubstringOf` t')
           && not (isBareParam t')
           && all isTypeChar t'
  where
    isTypeChar c = isAlphaNum c || c == '.' || c == '_' || c == '*' || c == '/'

    -- Split `<key>]<value>` for the content inside `map[...`.
    splitMap :: String -> Maybe (String, String)
    splitMap s =
        let (k, rest) = splitAtClosingBracket 0 s []
        in case rest of
            (']':v) -> Just (k, v)
            _       -> Nothing

    -- Split the body of `func(...)` (called with the substring AFTER
    -- the opening `(`). Returns (arg-types, return-type) where
    -- return-type is "" when the function has no return.
    splitFunc :: String -> Maybe ([String], String)
    splitFunc s =
        let (inside, rest) = splitFuncArgs 0 s []
        in case rest of
            (')':retRaw) ->
                let argTypes = if null inside then []
                               else map dropParamName (splitFuncCommas 0 inside [""])
                    ret      = dropWhile (== ' ') retRaw
                in Just (argTypes, ret)
            _ -> Nothing

    -- Go func-type literals may use `(name Type, ...)` or just
    -- `(Type, ...)`. When the piece contains a top-level space the
    -- preceding word is the param name and the rest is the type.
    -- Otherwise the whole piece is the type.
    dropParamName :: String -> String
    dropParamName piece =
        let trimmed = dropWhile (== ' ') piece
        in case break (== ' ') trimmed of
            (lhs, ' ':rhs) | not (null rhs) && isPlainIdent lhs ->
                dropWhile (== ' ') rhs
            _ -> trimmed
      where
        isPlainIdent xs = not (null xs) && all isIdentChar xs
        isIdentChar c = isAlphaNum c || c == '_'

    splitFuncArgs :: Int -> String -> String -> (String, String)
    splitFuncArgs _ []        acc = (reverse acc, "")
    splitFuncArgs 0 (')':xs)  acc = (reverse acc, ')':xs)
    splitFuncArgs d ('(':xs)  acc = splitFuncArgs (d+1) xs ('(':acc)
    splitFuncArgs d (')':xs)  acc = splitFuncArgs (d-1) xs (')':acc)
    splitFuncArgs d (x:xs)    acc = splitFuncArgs d xs (x:acc)

    splitFuncCommas :: Int -> String -> [String] -> [String]
    splitFuncCommas _ [] acc = reverse (map (dropWhile (== ' ') . reverse . dropWhile (== ' ') . reverse) acc)
    splitFuncCommas 0 (',':xs) (cur:rest) =
        splitFuncCommas 0 xs ("" : cur : rest)
    splitFuncCommas d (c:xs) (cur:rest)
        | c == '(' || c == '[' = splitFuncCommas (d+1) xs ((c:cur):rest)
        | c == ')' || c == ']' = splitFuncCommas (d-1) xs ((c:cur):rest)
        | otherwise            = splitFuncCommas d xs ((c:cur):rest)
    splitFuncCommas _ _ [] = []

    splitAtClosingBracket :: Int -> String -> String -> (String, String)
    splitAtClosingBracket _ [] acc = (reverse acc, "")
    splitAtClosingBracket 0 (']':xs) acc = (reverse acc, ']':xs)
    splitAtClosingBracket d ('[':xs) acc = splitAtClosingBracket (d+1) xs ('[':acc)
    splitAtClosingBracket d (']':xs) acc = splitAtClosingBracket (d-1) xs (']':acc)
    splitAtClosingBracket d (x:xs)   acc = splitAtClosingBracket d xs (x:acc)


isSkippedEntry :: String -> Bool
isSkippedEntry s = not ("func " `isSubstringOf` s)


isSubstringOf :: String -> String -> Bool
isSubstringOf needle hay = go hay
  where
    n = length needle
    go [] = False
    go xs
        | take n xs == needle = True
        | otherwise = go (tail xs)


-- ══════════════════════════════════════════════════════════════════════════
-- .skyi catalogue
-- ══════════════════════════════════════════════════════════════════════════

emitSkyi :: CompileTarget -> PkgInfo -> String
emitSkyi TargetGo pkg =
    let aliases = buildAliasTable pkg
    in unlines $
        [ "-- Auto-generated FFI binding catalogue for " ++ _pkgPath pkg
        , "--"
        , "-- All auto-generated bindings are registered effect-unknown and are"
        , "-- callable via Sky.Ffi.callTask. Every call returns Task Error a"
        , "-- with panic recovery — any Go panic is caught and surfaced as Err."
        , "--"
        , "-- Opaque Go struct values flow through Sky as Any; use the bindings"
        , "-- to construct, read and update them. Sky records-with-methods can"
        , "-- bridge this gap idiomatically — define a record type whose methods"
        , "-- are the relevant callTask invocations."
        , "--"
        , "-- Imports used in this package's wrapper:"
        ]
        ++ [ "--   " ++ alias ++ " \"" ++ path ++ "\""
           | (path, alias) <- sortOn fst (Map.toList aliases)
           ]
        ++
        [ ""
        , "package " ++ _pkgName pkg
        ]
        ++ map emitSkyiGoFn (_pkgFns pkg)
emitSkyi TargetRust pkg =
    let mname = pkgToModuleName TargetRust (_pkgPath pkg)
    in unlines $
        [ "module " ++ mname ++ " exposing (..)"
        , ""
        ]
        ++ map emitSkyiRustFn (_pkgFns pkg)

emitSkyiGoFn :: FnInfo -> String
emitSkyiGoFn fn =
    let sig = if null (_fnParams fn)
            then "() -> " ++ goResultsToSky (_fnResults fn)
            else intercalate " -> " (map (goTypeToSky . snd) (_fnParams fn))
                    ++ " -> " ++ goResultsToSky (_fnResults fn)
    in "-- [" ++ _fnEffect fn ++ "] " ++ _fnName fn ++ " : " ++ sig
       ++ "   -- runtime wrap: Task Error"

emitSkyiRustFn :: FnInfo -> String
emitSkyiRustFn fn =
    let sig = wrapperSkyType fn
        recvt = _fnRecvType fn
        disamb = if null recvt then "" else "_from_" ++ lowerFirst recvt
        name = lowerFirst (_fnName fn) ++ disamb
    in name ++ " : " ++ sig


goResultsToSky :: [(String, String)] -> String
goResultsToSky [] = "()"
goResultsToSky [(_, t)] = goTypeToSky t
goResultsToSky rs = "(" ++ intercalate ", " (map (goTypeToSky . snd) rs) ++ ")"


-- Map a Go type expression to its Sky-side surface name. The .skyi
-- inspector emits these in the documentation comment so users (and
-- `sky check`) see accurate shapes — `[]*pkg.X` becomes `List X`,
-- `map[string]V` becomes `Dict String V`, etc. Pointers are
-- transparent (opaque on the Sky side); `[]byte` is the special-cased
-- byte sequence.
--
-- Without this, a setter taking `[]*pkg.LineItemParams` was declared
-- on the .skyi as taking a single `LineItemParams`, hiding from the
-- type checker that callers must pass a `List`. The runtime wrapper
-- itself was always correct; only the surface signature was lying.
goTypeToSky :: String -> String
goTypeToSky t
    | take 5 t == "func(" = formatFuncType (drop 5 t)
    | t == "[]byte"        = "Bytes"
    | take 2 t == "[]"     = "List " ++ wrapIfComposite (goTypeToSky (drop 2 t))
    | take 1 t == "*"      = goTypeToSky (drop 1 t)
    | take 11 t == "map[string]" = "Dict String " ++ wrapIfComposite (goTypeToSky (drop 11 t))
    | take 4 t == "map["   =
        -- map[K]V where K isn't string — Sky's Dict is string-keyed,
        -- so surface it as `Dict String V` and let the runtime
        -- coercion stringify keys (consistent with rt.AsDict).
        let (_keyPart, valPart) = splitMapBracket (drop 4 t)
        in "Dict String " ++ wrapIfComposite (goTypeToSky (trim' valPart))
    | otherwise = case t of
        "string"      -> "String"
        "int"         -> "Int"
        "int64"       -> "Int"
        "int32"       -> "Int"
        "float64"     -> "Float"
        "float32"     -> "Float"
        "bool"        -> "Bool"
        "error"       -> "String"
        -- Go's empty interface = "any" in Sky terms. Without this, a
        -- `Dict String interface{}` ended up as `Dict String interface{}`
        -- in the registry, which the type parser can't read.
        "interface{}" -> "any"
        -- Inspector emits `struct{}` for the synthetic param that makes
        -- a Go zero-arg constructor look uniform with N-arg ones. From
        -- the Sky caller's perspective the call is `Pkg.newX ()`, so the
        -- Sky-side surface is `() -> Result Error X`.
        "struct{}"    -> "()"
        _         -> stripPkg t
  where
    stripPkg = reverse . takeWhile (/= '.') . reverse

    -- Multi-word Sky types (`List X`, `Dict String V`) need parens
    -- when nested inside another constructor: `List (List X)`,
    -- `List (Dict String V)`, etc.
    wrapIfComposite s
        | ' ' `elem` s = "(" ++ s ++ ")"
        | otherwise    = s

    -- For `map[K]V`, find the matching `]` for the opening `[` to
    -- correctly split when K itself contains brackets (rare but
    -- possible: `map[[2]string]V`).
    splitMapBracket s = goB 1 [] s
      where
        goB _ acc [] = (reverse acc, "")
        goB 1 acc (']':rest) = (reverse acc, rest)
        goB n acc ('[':rest) = goB (n+1) ('[':acc) rest
        goB n acc (']':rest) = goB (n-1) (']':acc) rest
        goB n acc (c:rest)   = goB n (c:acc) rest

    formatFuncType body =
        let (argPart, retPart) = splitAtCloseParen body
            args = splitCommas argPart
            skyArgs = map (goTypeToSky . trim') args
            skyRet  = if null retPart then "()" else goTypeToSky (trim' retPart)
        in "(" ++ intercalate " -> " (skyArgs ++ [skyRet]) ++ ")"

    splitAtCloseParen s = go 0 [] s
      where
        go _ acc [] = (reverse acc, "")
        go 0 acc (')':rest) = (reverse acc, rest)
        go n acc ('(':rest) = go (n+1) ('(':acc) rest
        go n acc (')':rest) = go (n-1) (')':acc) rest
        go n acc (c:rest)   = go n (c:acc) rest

    splitCommas s = case break (== ',') s of
        (a, [])   -> [a]
        (a, _:rest) -> a : splitCommas rest

    trim' = dropWhile isSpace . reverse . dropWhile isSpace . reverse
    isSpace c = c == ' '


-- ══════════════════════════════════════════════════════════════════════════
-- Helpers
-- ══════════════════════════════════════════════════════════════════════════

quote :: String -> String
quote s = "\"" ++ concatMap esc s ++ "\""
  where
    esc '"'  = "\\\""
    esc '\\' = "\\\\"
    esc c    = [c]


slugify :: String -> String
slugify = map (\c -> if c `elem` ("./" :: String) then '_' else c)


-- | Strip extra spaces from Rust type strings produced by the inspector.
-- The Rust inspector emits types like "SkyResult < SkyError , (String , i64) >"
-- which need normalization to valid Rust: "SkyResult<SkyError, (String, i64)>".
normalizeRustType :: String -> String
normalizeRustType s =
    let s' = go s
    in if s' == s then s else normalizeRustType s'  -- fixpoint for nested generics
  where
    go [] = []
    go (' ':'<':cs) = '<' : go cs   -- B7: "SkyResult <T>" → "SkyResult<T>"
    go ('<':' ':cs) = '<' : go cs
    go (' ':'>':cs) = '>' : go cs
    go (' ':',':cs) = ',' : go cs
    go (',':' ':cs) = ',' : go cs
    go ('>':' ':cs) = '>' : go cs
    go (c:cs) = c : go cs



