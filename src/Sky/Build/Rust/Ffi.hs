{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Rust-target FFI binding generation. Owns everything the Go FFI generator
-- (Sky.Build.FfiGen) does not need: the rustdoc-JSON inspector runner for the
-- Rust crate inspector, the Rust type-coercion logic, and the wrapper/skyi/
-- kernel-json emitters for the Rust target. Imports the Go-neutral shared
-- helpers + types from Sky.Build.FfiGen; FfiGen never imports this module
-- (one-way dependency, no cycle), keeping FfiGen byte-identical to upstream.
module Sky.Build.Rust.Ffi
    ( generateRustBindings   -- :: PkgInfo -> IO [String]
    , runRustInspector       -- :: String -> [String] -> IO (Either String PkgInfo)
    , runRustInspectorGit    -- :: String -> String -> Maybe String -> Maybe String -> Maybe String -> [String] -> IO (Either String PkgInfo)
    , runRustInspectorMulti  -- :: [String] -> [String] -> IO [Either String PkgInfo]
    , emitRustSkyi           -- :: PkgInfo -> String
    , rustModuleName         -- :: String -> String
    , rustKernelName         -- :: PkgInfo -> String
    , emitRustFile           -- :: String -> PkgInfo -> String
    , dedupByRustName        -- :: [FnInfo] -> [FnInfo]
    ) where

import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as BL
import Data.Char (isAlpha, isAlphaNum, isDigit, isLower, isUpper, toUpper)
import Data.List (intercalate, isPrefixOf, stripPrefix)
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (createDirectoryIfMissing, doesFileExist, getCurrentDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>), takeDirectory)
import System.Process (readProcessWithExitCode)
import qualified Sky.Build.EmbeddedInspectorRust as EIRust
import Sky.Build.FfiGen
    ( PkgInfo(..), FnInfo(..)
    , slugify, lowerFirst, capitaliseFirst, splitOnChar, emitKernelJson, wrapperSkyType
    )
import Sky.Generate.Rust.Builder.Naming (toSnakeCase)


-- | Inspect a single Rust crate (rustdoc-JSON backend). Optional features are
-- comma-joined and passed as `--features`.
runRustInspector :: String -> [String] -> IO (Either String PkgInfo)
runRustInspector pkgPath features = runRustInspectorWith pkgPath features Nothing


-- | Inspect a crate sourced from a git URL. The inspector clones via Cargo's
-- usual git resolution (`~/.cargo/git/checkouts/...`) and feeds the resolved
-- path to rustdoc. `mRev` / `mBranch` / `mTag` pin the revision (mutually
-- exclusive per `Cargo` semantics; the caller is expected to enforce that).
runRustInspectorGit
    :: String              -- crate name
    -> String              -- git URL
    -> Maybe String        -- rev
    -> Maybe String        -- branch
    -> Maybe String        -- tag
    -> [String]            -- features
    -> IO (Either String PkgInfo)
runRustInspectorGit crateName url mRev mBranch mTag features =
    runRustInspectorWith crateName features (Just (url, mRev, mBranch, mTag))


-- | Shared back-end for the two front-doors above.
runRustInspectorWith
    :: String
    -> [String]
    -> Maybe (String, Maybe String, Maybe String, Maybe String)
    -> IO (Either String PkgInfo)
runRustInspectorWith pkgPath features mGit = do
    resolved <- resolveRustInspector
    case resolved of
        Left e    -> return (Left e)
        Right bin -> do
            let featuresArg = if null features then "" else " --features " ++ quoteShell (intercalate "," features)
                gitArg = case mGit of
                    Nothing -> ""
                    Just (url, mr, mb, mt) ->
                        " --git " ++ quoteShell url
                            ++ maybe "" (\r -> " --rev "    ++ quoteShell r) mr
                            ++ maybe "" (\b -> " --branch " ++ quoteShell b) mb
                            ++ maybe "" (\t -> " --tag "    ++ quoteShell t) mt
                -- Shell-quote pkgPath exactly as the git URL/rev/branch/tag are
                -- quoted below: the crate path/name can originate from sky.toml,
                -- so a space or shell metachar would otherwise break the
                -- invocation (or be an injection vector via a crafted dep name).
                cmd' = quoteShell bin ++ " " ++ quoteShell pkgPath ++ featuresArg ++ gitArg
            (_, out, err) <- readProcessWithExitCode "sh" ["-c", cmd'] ""
            if null out
                then return (Left $ "sky-ffi-inspect-rs: empty output; stderr: " ++ err)
                else case A.eitherDecode (BL.fromStrict (TE.encodeUtf8 (T.pack out))) of
                    Left e  -> return (Left $ "sky-ffi-inspect-rs: json: " ++ e)
                    Right p -> return (Right p)


-- Conservative shell-quote: wrap in single-quotes and escape embedded single
-- quotes. Git URLs are unlikely to contain quotes but better safe than sorry.
quoteShell :: String -> String
quoteShell s = "'" ++ concatMap esc s ++ "'"
  where
    esc '\'' = "'\\''"
    esc c    = [c]


-- | Multi-crate mode: the Rust inspector resolves each crate independently, so
-- this loops single-mode (one result per requested crate, in input order).
runRustInspectorMulti :: [String] -> [String] -> IO [Either String PkgInfo]
runRustInspectorMulti []       _    = return []
runRustInspectorMulti pkgPaths feats = mapM (\p -> runRustInspector p feats) pkgPaths


-- | Generate the Rust FFI binding artifacts (.rs wrapper, .skyi catalogue,
-- .kernel.json dispatch table) for a crate, all under .skycache/ffi/rust/.
-- Dedup once at the source so all three agree (a real to_string/from_string
-- colliding with the synthetic Display/FromStr bridge collapses to one entry).
generateRustBindings :: PkgInfo -> IO [String]
generateRustBindings pkg0 = do
    createDirectoryIfMissing True ".skycache/ffi/rust"
    let pkg = pkg0 { _pkgFns = dedupByRustName (_pkgFns pkg0) }
        slug = slugify (_pkgName pkg)
        kname = rustKernelName pkg
        mname = rustModuleName (_pkgPath pkg)
        rsFile   = ".skycache/ffi/rust" </> (slug ++ "_bindings.rs")
        skyiFile = ".skycache/ffi/rust" </> (slug ++ ".skyi")
        jsonFile = ".skycache/ffi/rust" </> (slug ++ ".kernel.json")
        names = map (\fn -> mname ++ "." ++ lowerFirst (_fnName fn)) (_pkgFns pkg)
    writeFile rsFile (emitRustFile kname pkg)
    writeFile skyiFile (emitRustSkyi pkg)
    -- Rust target: methods get `_from_<RecvType>` suffix so users can
    -- disambiguate `Chrono.now_from_utc` etc. (rustdoc preserves receiver
    -- info; the Sky source explicitly references suffixed names).
    --
    -- Rust-LOCAL kernel.json emitter (not the shared `emitKernelJson`): a field
    -- getter's HM type must be INFALLIBLE (`Recv -> FieldTy`, C6), matching the
    -- infallible wrapper + `.skyi`. The shared emitter always Result-wraps via
    -- `wrapperSkyType`, which would type a getter as `Recv -> Result Error
    -- FieldTy` and make every read need an `Ok`-unwrap. The FFI registry seeds
    -- HM from THIS json, so it is the load-bearing type source.
    writeFile jsonFile (emitRustKernelJson mname kname pkg)
    return names


-- | Rust-side module name: "github.com/google/uuid" / "uuid" → "Rust.Uuid".
rustModuleName :: String -> String
rustModuleName path =
    let clean = map (\c -> if isAlphaNum c then c else '_') path
        cap   = capitaliseFirst clean
    in "Rust." ++ cap


-- | Rust-side kernel-name prefix ("Rust_") + capitalised crate base name.
rustKernelName :: PkgInfo -> String
rustKernelName pkg =
    let segs = filter (not . null) (splitOnChar '/' (_pkgPath pkg))
        capOf s = capitaliseFirst (map (\c -> if isAlphaNum c then c else '_') s)
        baseName = case reverse segs of
            (last1 : prev : _) | isVersion last1 -> capOf prev ++ capOf last1
            (last1 : _)                          -> capOf last1
            []                                   -> "Ffi"
    in "Rust_" ++ baseName
  where
    isVersion ('v':rest) = all (`elem` ("0123456789" :: String)) rest && not (null rest)
    isVersion _ = False


-- | Rust-target .skyi catalogue.
emitRustSkyi :: PkgInfo -> String
emitRustSkyi pkg =
    let mname = rustModuleName (_pkgPath pkg)
    in unlines $
        [ "module " ++ mname ++ " exposing (..)"
        , ""
        ]
        ++ map emitSkyiRustFn (_pkgFns pkg)

-- ── Rust inspector resolver ──────────────────────────────────────────
resolveRustInspector :: IO (Either String FilePath)
resolveRustInspector = do
    disk <- findRustInspector
    case disk of
        Just p  -> return (Right p)
        Nothing -> EIRust.ensureInspectorRust


-- | Probe common locations for the sky-ffi-inspect binary.
-- Looks at: SKY_FFI_INSPECTOR env var, ./bin, ../bin … walking up ancestors.
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



-- ── Rust type coercion + emit (skyTypeToRust … pkgToCrateImport) ──────
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


-- | True when the given Rust type string is a primitive numeric type.
-- Used to pick `as <T>` casts instead of `.try_into().unwrap()` or `.into()`.
isNumericRust :: String -> Bool
isNumericRust t = t `elem`
    [ "i8", "i16", "i32", "i64", "i128"
    , "u8", "u16", "u32", "u64", "u128"
    , "isize", "usize", "f32", "f64" ]


-- | True when the given Rust type string is a `Copy` primitive, so a field
-- getter can read it as `recv.field` (no `.clone()`). The S1 closed set's Copy
-- members are the inspector-allowed ints (i8..i64 / u8..u32), the floats, bool,
-- and char. Everything else eligible (String / Vec / Option / Clone-opaque) is
-- non-Copy and must be `.clone()`d out of the borrowed receiver.
isCopyRust :: String -> Bool
isCopyRust t = trimStr t `elem`
    [ "i8", "i16", "i32", "i64"
    , "u8", "u16", "u32"
    , "f32", "f64", "bool", "char" ]


-- | Make extern-crate references absolute (`csv::X` → `::csv::X`) so they never
-- collide with a same-named runtime kernel module that `pub use sky_runtime::*`
-- re-exports at the app crate root. The `uuid`/`regex`/`char` kernels are
-- `_kernel`-suffixed, but `csv`/`time`/`log`/`json`/`config`/`email`/`html` are
-- not — so a `csv`/`time`/… crate dep collides (`use crate::*` brings
-- `crate::csv`, ambiguous with the extern `csv`). A leading `::` resolves from
-- the extern prelude, never `crate::<name>`. Rewrites `<crate>::` only at a path
-- start (preceded by a delimiter, not an identifier char or `:`) so nested
-- generics (`Vec<csv::X>`) and already-absolute paths are handled correctly.
absolutizeCrate :: String -> String -> String
absolutizeCrate crate = go ' '
  where
    pat = crate ++ "::"
    isIdentCh ch = isAlphaNum ch || ch == '_'
    go _ [] = []
    go prev s@(c:cs)
      | pat `isPrefixOf` s && not (isIdentCh prev) && prev /= ':' =
          "::" ++ pat ++ go ':' (drop (length pat) s)
      | otherwise = c : go c cs


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


-- | Shape of a slice/array Rust type.
data SeqShape = Slice | Owned | Arr Int | RefArr Int
  deriving (Show, Eq)

-- | Element kind. ElemU8 is the byte-sequence fast path (List Int via
-- to_u8_vec / from_u8_slice / to_u8_array — the existing v1 helpers).
-- ElemGeneral carries the (rust_type, sky_type) of a non-byte coercible
-- element (e.g. ("String","String"), ("f64","Float")).
data SeqElem = ElemU8
             | ElemGeneral String String   -- (elem rust_type, elem sky_type)
  deriving (Show, Eq)

data SeqKind = SeqKind SeqShape SeqElem
  deriving (Show, Eq)

-- | Classify a raw Rust type as a Sky-coercible sequence (mirrors the
-- inspector's is_coercible_seq). Returns the shape and element kind.
-- N is parsed from `[T; N]` / `&[T; N]`. Excludes &mut [T] and non-coercible
-- elements (nested generics, borrowed elements).
seqKind :: String -> Maybe SeqKind
seqKind raw =
    let s = trimStr raw in
    if "&mut " `isPrefixOf` s then Nothing
    else case s of
        "&[u8]"   -> Just (SeqKind Slice ElemU8)
        "Vec<u8>" -> Just (SeqKind Owned ElemU8)
        _ -> case stripPrefix "&[u8; " s of
               Just rest | Just n <- digitsBeforeClose rest ->
                 Just (SeqKind (RefArr n) ElemU8)
               _ -> case stripPrefix "[u8; " s of
                 Just rest | Just n <- digitsBeforeClose rest ->
                   Just (SeqKind (Arr n) ElemU8)
                 _ -> seqGeneral s
  where
    -- Clamp N to a sane array-size ceiling: a pathological `[u8; 999999999999]`
    -- from odd/malicious rustdoc JSON would otherwise emit an absurd array type.
    -- Above the ceiling we reject so the caller falls through to the opaque path.
    maxArrayLen = 65536
    digitsBeforeClose rest =
        case span (/= ']') rest of
            (digits, "]")
              | not (null digits) && all isDigit digits
              -- Parse as Integer (unbounded) first so a giant literal can't
              -- wrap a fixed-width Int negative, then range-check before
              -- narrowing to the Int the codegen uses.
              , n <- (read digits :: Integer)
              , n >= 0 && n <= maxArrayLen -> Just (fromInteger n)
            _ -> Nothing

    seqGeneral s =
        let try shape e = if isCoercibleElem e
                          then Just (SeqKind shape (ElemGeneral e (skyOfElem e)))
                          else Nothing
        in case stripPrefix "Vec<" s of
             Just rest | Just e <- stripSuffix' ">" rest -> try Owned (trimStr e)
             _ -> case stripPrefix "&[" s of
               Just rest | Just inner <- stripSuffix' "]" rest ->
                 case break (== ';') inner of
                   (e, ';':n) -> case reads (trimStr n) :: [(Int,String)] of
                                   [(k, "")] -> try (RefArr k) (trimStr e)
                                   _ -> Nothing
                   (e, "")    -> try Slice (trimStr e)
                   _ -> Nothing
               _ -> case stripPrefix "[" s of
                 Just rest | Just inner <- stripSuffix' "]" rest ->
                   case break (== ';') inner of
                     (e, ';':n) -> case reads (trimStr n) :: [(Int,String)] of
                                     [(k, "")] -> try (Arr k) (trimStr e)
                                     _ -> Nothing
                     _ -> Nothing
                 _ -> Nothing

    isCoercibleElem e =
        let t = trimStr e in
        not (null t)
        && not ('&' `elem` t || ' ' `elem` t || '<' `elem` t
                || '[' `elem` t || ',' `elem` t)
        && (t `elem` knownPrim
            || (not (null t)
                && (isAlpha (head t) || head t == '_')))
      where
        knownPrim = ["u8","u16","u32","u64","usize"
                    ,"i8","i16","i32","i64","isize"
                    ,"f32","f64","bool","char","str"
                    ,"String","OsString","PathBuf"]

    skyOfElem e
        | e `elem` intLike   = "Int"
        | e `elem` floatLike = "Float"
        | e == "bool"        = "Bool"
        | e == "char"        = "Char"
        | e == "str" || e == "String" || e == "OsString" || e == "PathBuf" = "String"
        | otherwise          = e
      where
        intLike   = ["u8","u16","u32","u64","usize"
                    ,"i8","i16","i32","i64","isize"]
        floatLike = ["f32","f64"]

    -- Manual suffix-strip; modern Data.List.stripSuffix is also fine if it's imported.
    stripSuffix' suf xs =
        let n = length xs - length suf in
        if n >= 0 && drop n xs == suf
        then Just (take n xs)
        else Nothing


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
    else case seqKind raw of
      Just (SeqKind shape ElemU8) ->
        -- BYTE PATH (byte-identical to v1)
        ( "Vec<i64>"
        , \e -> case shape of
            Owned    -> "from_u8_slice(&" ++ e ++ ")"
            Arr _    -> "from_u8_slice(&" ++ e ++ ")"
            Slice    -> "from_u8_slice(" ++ e ++ ")"
            RefArr _ -> "from_u8_slice(" ++ e ++ ")" )
      Just (SeqKind shape (ElemGeneral elemRust _elemSky)) ->
        -- General element coercion. Sky `List T` is `Vec<T>` in the runtime,
        -- so Vec<T> result is identity; &[T] / [T; N] / &[T; N] all clone to
        -- owned Vec<T> via .to_vec() (T: Clone required and assumed for
        -- coercible elems).
        ( "Vec<" ++ elemRust ++ ">"
        , \e -> case shape of
            Owned    -> e                       -- Vec<T> identity
            Slice    -> e ++ ".to_vec()"
            Arr _    -> e ++ ".to_vec()"
            RefArr _ -> e ++ ".to_vec()" )
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
        -- No `use ::<crate>::*;` glob: every crate-type reference is emitted
        -- absolute (`::<crate>::Type`), and a glob would SHADOW the std prelude
        -- (e.g. csv's `Result<T>` alias shadowing `std::result::Result`).
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
    resolveRustType crate st rtOverride
        -- `Maybe <opaque>`: skyTypeToRust would collapse the opaque inner to
        -- "String" (SkyMaybe<String>) — wrong. Take the inner from the raw
        -- `Option<inner>` override, owned (&T → T), so the decl is
        -- SkyMaybe<::crate::T> and argCall's Option coercion lines up.
        | "Maybe " `isPrefixOf` st
        , not (isKnownSky (trimStr (drop 6 st)))
        , Just optInner <- stripGeneric1 "Option" rtOverride
            = "SkyMaybe<" ++ ownedInner crate optInner ++ ">"
        | isKnownSky st                = skyTypeToRust st
        | not (null rtOverride)        = absolutizeCrate crate rtOverride
        | otherwise                    = "String"
      where
        ownedInner cr raw =
            let t  = trimStr raw
                t1 = dropWhile (\c -> c == '&' || c == ' ') t
                t2 = maybe t1 id (stripPrefix "mut " t1)
            in absolutizeCrate cr (trimStr t2)

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
            rustName  = toSnakeCase (drop 5 kernelName ++ "_" ++ skyName ++ disambSfx)
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
            -- Owned-threading setter: the wrapper returns the receiver by value
            -- (`head paramTypes` is arg0's resolved type), no coercion — the
            -- raw `&mut Self`/`()` Rust return is discarded in the body.
            (retInner, retCoerce)
                | _fnSelfReturning fn =
                    -- paramTypes already absolutized via resolveRustType.
                    (case paramTypes of (t:_) -> t; [] -> "()", id)
                | otherwise =
                    let (t, co) = case _fnEffect fn of
                            "fallible" -> translateRustRet (okTypeOfResult effRawResult)
                            _          -> translateRustRet effRawResult
                    in (absolutizeCrate crateImport t, co)
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
                in case seqKind rawTy of
                    Just (SeqKind Slice    ElemU8) -> "&to_u8_vec(&" ++ base ++ ")"
                    Just (SeqKind Owned    ElemU8) -> "to_u8_vec(&" ++ base ++ ")"
                    Just (SeqKind (Arr _)    ElemU8) -> "b" ++ show j        -- prelude local (owned)
                    Just (SeqKind (RefArr _) ElemU8) -> "&b" ++ show j       -- prelude local (by ref)
                    Just (SeqKind Slice    (ElemGeneral _ _)) -> base ++ ".as_slice()"
                    Just (SeqKind Owned    (ElemGeneral _ _)) -> base    -- Vec<T> identity
                    Just (SeqKind (Arr _)    (ElemGeneral _ _)) -> "b" ++ show j   -- prelude local (owned)
                    Just (SeqKind (RefArr _) (ElemGeneral _ _)) -> "&b" ++ show j  -- prelude local (by ref)
                    Nothing
                        -- Option<inner> param: the wrapper takes SkyMaybe<declInner>;
                        -- convert to Option<declInner> then adapt the inner value to
                        -- the crate fn's Option<rawInner>. The temp Option<String>
                        -- lives for the call, so `.as_deref()` borrow is sound.
                        | Just innerRaw <- stripGeneric1 "Option" rawTy ->
                            let inner = trimStr innerRaw
                                opt   = "sky_maybe_to_option(" ++ base ++ ")"
                            in case inner of
                                 "&str"    -> opt ++ ".as_deref()"
                                 "&String" -> opt ++ ".as_ref()"
                                 _ | isNumericRust inner       -> opt ++ ".map(|x| x as " ++ inner ++ ")"
                                   | "&" `isPrefixOf` inner     -> opt ++ ".as_ref()"  -- Option<&T> borrowed opaque
                                   | otherwise                  -> opt   -- String/bool/owned opaque: identity
                        | declTy == "String" -> "&" ++ base          -- Sky String → &str
                        | null rawTy || rawTy == declTy -> base      -- same type, pass through
                        | isNumericRust rawTy && (declTy == "i64" || declTy == "f64")
                            -> base ++ " as " ++ rawTy               -- narrowing cast (e.g. i64 → u32)
                        | otherwise -> base                          -- opaque: pass through unchanged
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
                    -- Absolute `::<crate>` path: never collide with a same-named
                    -- runtime kernel module re-exported at the app crate root.
                    if null params then "::" ++ crateImport ++ "::" ++ fnName ++ "()"
                    else "::" ++ crateImport ++ "::" ++ fnName ++ "(" ++ callArgs ++ ")"
            -- Build the function body based on effect.  retCoerce lifts the
            -- raw Rust value into the declared return type (Option→SkyMaybe,
            -- Vec element map, numeric widening to i64/f64, &T→owned, opaque
            -- → identity).
            -- Owned-threading setter body: call the `&mut self`/`self` method on
            -- the (already `mut`) receiver, discard its borrowed `&mut Self`/`()`
            -- return, and return the owned receiver. No lifetime, no Clone.
            ownThreadArgs = intercalate ", " (map argCall [1 .. nParams - 1])
            body
                | _fnSelfReturning fn =
                    "ok_res({ arg0." ++ fnName ++ "(" ++ ownThreadArgs ++ "); arg0 })"
                | otherwise = case _fnEffect fn of
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
                [ case se of
                    ElemU8 ->
                      "let b" ++ show j ++ ": [u8; " ++ show n ++ "] = "
                      ++ "match to_u8_array::<SkyError, " ++ show n
                      ++ ">(&arg" ++ show j ++ ") { SkyResult::Ok(a) => a, "
                      ++ "SkyResult::Err(e) => return SkyResult::Err(e), };"
                    ElemGeneral elemRust _ ->
                      "let b" ++ show j ++ ": [" ++ elemRust ++ "; " ++ show n ++ "] = "
                      ++ "match to_array::<SkyError, " ++ elemRust ++ ", " ++ show n
                      ++ ">(&arg" ++ show j ++ ") { SkyResult::Ok(a) => a, "
                      ++ "SkyResult::Err(e) => return SkyResult::Err(e), };"
                | j <- [0 .. nParams - 1]
                , let rawTy = if j < nRawRustParam then rawRustParamTypes !! j else ""
                , (n, se) <- case seqKind rawTy of
                         Just (SeqKind (Arr m)    e) -> [(m, e)]
                         Just (SeqKind (RefArr m) e) -> [(m, e)]
                         _                           -> []
                ]
            -- ── Field GETTER (S1) ──────────────────────────────────────
            -- A field getter reads the field BY VALUE from the receiver —
            -- `recv.field` for a `Copy` primitive, `recv.field.clone()` for the
            -- eligible non-Copy set (String / Vec / Option / a Clone-deriving
            -- opaque). The read is INFALLIBLE (C6): the wrapper returns the bare
            -- field type, NOT a `SkyResult`, and the `.skyi` advertises
            -- `Recv -> FieldTy`. The inspector already gated the field type to
            -- the closed eligible set, so the projection / `.clone()` is total —
            -- it can never panic, index, or partially move the field out.
            --
            -- The receiver param is taken by VALUE to match the FFI call-site
            -- convention (the Sky→Rust codegen passes the receiver owned, e.g.
            -- `getter(p)` / `getter(p.clone())` for a multi-use value). Reading
            -- a `Copy` field copies it out (the moved-in receiver then drops
            -- intact); reading a non-`Copy` field `.clone()`s it before the
            -- receiver drops. Neither moves the field out of a partial borrow,
            -- so C4's value-semantics + no-partial-drop intent holds.
            fieldRecvRust   = resolveRustType crateImport recvType (_fnRecvRustType fn)
            fieldName       = _fnMethodName fn   -- the REAL Rust field name
            fieldRawTy      = if nRawRustResult > 0 then rawRustResultTypes !! 0 else ""
            (fieldRetInner0, fieldCoerce) = translateRustRet fieldRawTy
            fieldRetInner   = absolutizeCrate crateImport fieldRetInner0
            -- `Copy` field → copy-out read; everything else in the closed set is
            -- `Clone` → `.clone()` the field before the receiver drops.
            fieldAccess     = if isCopyRust fieldRawTy
                              then "arg0." ++ fieldName
                              else "arg0." ++ fieldName ++ ".clone()"
            fieldBody       = fieldCoerce fieldAccess
            -- Total-by-construction guard: a getter needs exactly one result
            -- (the field type), a real field name, and a nameable receiver. The
            -- inspector always supplies these for an `is_field` entry, but if a
            -- future inspector change emitted a degenerate one we DROP it (emit
            -- nothing) rather than synthesise a `()`-returning broken wrapper.
            fieldWellFormed =
                nRawRustResult == 1
                    && not (null (trimStr fieldRawTy))
                    && not (null fieldName)
                    && not (null (trimStr fieldRecvRust))
            fieldLines =
                [ "// [field] " ++ wrapper
                , "pub fn " ++ rustName ++ "(arg0: " ++ fieldRecvRust ++ ") -> "
                  ++ fieldRetInner ++ " {"
                , "    " ++ fieldBody
                , "}"
                ]
        in if _fnIsField fn
           then if fieldWellFormed then fieldLines else []
           else if isDegenerateMethod || ((isInstance || isStaticFn) && hasGenericRecvParam)
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

-- ── dedup + skyi helper ─────────────────────────────────────────────
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


-- | Rust-target kernel.json emitter. Mirrors the shared `emitKernelJson True`
-- (method `_from_<Recv>` disamb, `{name, arity, skyType}` entries) EXCEPT that a
-- field getter's `skyType` is the INFALLIBLE `Recv -> FieldTy` (C6) — the FFI
-- registry seeds HM inference from this file, so the type here is what the Sky
-- type-checker enforces at every call site.
emitRustKernelJson :: String -> String -> PkgInfo -> String
emitRustKernelJson moduleName kernelName pkg =
    let fns = _pkgFns pkg
        entries = intercalate ",\n" (map emitFnEntry fns)
        emitFnEntry fn =
            let st = if _fnIsField fn then fieldSkyType fn else wrapperSkyType fn
                recv = _fnRecvType fn
                disamb = if null recv then "" else "_from_" ++ lowerFirst recv
                nm = lowerFirst (_fnName fn) ++ disamb
                arity = max 1 (length (_fnParams fn))
            in "    {\"name\": " ++ jsonQuote nm
               ++ ", \"arity\": " ++ show arity
               ++ ", \"skyType\": " ++ jsonQuote st ++ "}"
    in unlines
        [ "{"
        , "  \"moduleName\": " ++ jsonQuote moduleName ++ ","
        , "  \"kernelName\": " ++ jsonQuote kernelName ++ ","
        , "  \"package\": " ++ jsonQuote (_pkgPath pkg) ++ ","
        , "  \"functions\": ["
        , entries
        , "  ]"
        , "}"
        ]
  where
    -- Minimal JSON string escaper (mirrors FfiGen.quote, which isn't exported).
    jsonQuote s = "\"" ++ concatMap esc s ++ "\""
      where
        esc '"'  = "\\\""
        esc '\\' = "\\\\"
        esc c    = [c]


emitSkyiRustFn :: FnInfo -> String
emitSkyiRustFn fn =
    let sig = if _fnIsField fn then fieldSkyType fn else wrapperSkyType fn
        recvt = _fnRecvType fn
        -- C2: the `_field` discriminator is already baked into `_fnName` by the
        -- inspector, so a field getter's name (`id_field_from_<Recv>`) can never
        -- collide with a same-named method's (`id_from_<Recv>`) in the `.skyi`,
        -- the kernel.json, or `dedupByRustName` — they all key off `_fnName`.
        disamb = if null recvt then "" else "_from_" ++ lowerFirst recvt
        name = lowerFirst (_fnName fn) ++ disamb
    in name ++ " : " ++ sig


-- | C6: a field getter's `.skyi` type is INFALLIBLE — `Recv -> FieldTy`, NOT
-- `Recv -> Result Error FieldTy`. `wrapperSkyType` always Result-wraps the
-- result (every other FFI wrapper can fail), so for a field getter we take its
-- rendering and strip the leading `Result Error ` from the result segment. The
-- receiver-side rendering (left of the final ` -> `) is reused verbatim so the
-- receiver type matches the struct's methods exactly.
fieldSkyType :: FnInfo -> String
fieldSkyType fn =
    let full = wrapperSkyType fn               -- "<Recv> -> Result Error <FieldTy>"
        (lhs, rhs) = splitLastArrow full
        stripped = case stripPrefix "Result Error " (trimStr rhs) of
            Just inner -> unParen (trimStr inner)
            Nothing    -> trimStr rhs           -- already infallible (defensive)
    in lhs ++ " -> " ++ stripped
  where
    -- Split on the LAST " -> " separator. A field getter's wrapperSkyType has
    -- exactly one arrow (`Recv -> Result Error Field`), so "last" == "only";
    -- using "last" is robust even if a receiver type ever curried.
    splitLastArrow s =
        case reverse (splitOnArrow s) of
            (r : ls@(_:_)) -> (intercalate " -> " (reverse ls), r)
            [r]            -> ("()", r)
            []             -> ("()", s)
    -- Split a type string on top-level " -> " occurrences.
    splitOnArrow = go "" []
      where
        go cur acc [] = reverse (reverse cur : acc)
        go cur acc s@(c:cs)
            | " -> " `isPrefixOf` s = go "" (reverse cur : acc) (drop 4 s)
            | otherwise             = go (c : cur) acc cs
    -- Drop one matching outer paren pair if present (`(Maybe Int)` → `Maybe Int`).
    unParen ('(':r) | not (null r) && last r == ')' = init r
    unParen s = s


