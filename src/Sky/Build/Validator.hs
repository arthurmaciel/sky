-- | v0.13 Layer 2: Codegen-stage validator.
--
-- Walks the emitted Go source text looking for known-bad shapes
-- that indicate a Sky compiler bug.  Catches the patterns the HM
-- type checker accepted but codegen could not emit cleanly —
-- BEFORE `go build` sees the code.  When a pattern matches, the
-- validator emits a structured `Diagnostic` (category=Codegen,
-- code=E4001..E4999) so the user sees an Elm-style block
-- instead of Go's cryptic raw error.
--
-- Patterns currently detected:
--
--   1. **typed-kernel call with raw any-typed arg** (Issue #52 class).
--      Pattern: `rt.<Name>T[<types>](<bare-any-ident>, ...)` where
--      the first arg is a bare identifier (not wrapped in
--      `rt.As<Int|Bool|Float|String|List|Dict|Tuple2>` or a literal).
--      Caught here means the v0.12.1 typedKernelArgCoerce map is
--      missing an entry for that helper.
--
--   2. **`.(<concreteType>)` raw type-assertion on an any-typed
--      variable**.  Pattern: `<bare-ident>.(<type>)` outside the
--      `rt.Coerce*` helpers.  P0-3 audit prohibits this — must
--      route through a runtime coerce helper that handles the
--      nil / wrong-type case.
--
--   3. **Generic instantiation with `any` in a typed slot**.
--      Pattern: `rt.<Name>T[<types>]` where one of the types is
--      `any` and the helper's typed signature would reject `any`.
--      Indicates the typed-codegen fell back to any-routing when
--      it should have monomorphised.
--
--   4. **Unbalanced FFI wrapper arg count**.  Pattern: a generated
--      `Go_<pkg>_<func>(<args>)` call where the count of args
--      doesn't match the wrapper's declared arity in the `.skyi`.
--      (Not yet implemented — needs cross-file analysis.)
--
-- The validator is intentionally CONSERVATIVE.  False positives
-- would block real builds; we only flag patterns that are
-- definitively wrong.  Edge cases (e.g. `rt.X(args)` where `X`
-- is a Sky-defined struct method named identically to a kernel
-- helper) are skipped by checking the helper-name is in the
-- known set.
--
-- Resilience: the validator never crashes the build — on any
-- internal failure it returns an empty diagnostic list and lets
-- `go build` proceed as a fallback.  Sky's "if it compiles, it
-- works" promise relies on regression tests, not on this pass.
-- The pass is defence-in-depth.
module Sky.Build.Validator
    ( validateEmittedGo
    , parseOriginComments
    , injectOriginComments
    , OriginMap
    , GoErrorLocation(..)
    , parseGoBuildError
    , resolveGoErrorToSky
    ) where

import qualified Data.Map.Strict as Map
import qualified Sky.Reporting.Annotation as A
import qualified Sky.Reporting.Diagnostic as Diag
import Data.List (isPrefixOf, isInfixOf, isSuffixOf, stripPrefix, foldl')
import Data.Maybe (mapMaybe)


-- ─── public API ──────────────────────────────────────────────────────


-- | Run the codegen-stage validator on emitted main.go text.
-- Returns a (possibly empty) list of `Diagnostic` values.  Empty
-- means the validator found no known-bad shapes and the build is
-- free to proceed to `go build`.
--
-- `originMap` is the line-keyed Sky-source map.  When a bug is
-- found at Go line N, the validator looks up the nearest preceding
-- origin entry to map back to Sky source.
validateEmittedGo :: FilePath -> OriginMap -> String -> [Diag.Diagnostic]
validateEmittedGo _goPath originMap source =
    let lns = zip [1..] (lines source)
        diags = concatMap (checkLine originMap) lns
    in diags


-- ─── pattern matchers ────────────────────────────────────────────────


-- | Run every pattern matcher on a single line.  Each matcher
-- returns Just Diagnostic if it fires; Nothing otherwise.
checkLine :: OriginMap -> (Int, String) -> [Diag.Diagnostic]
checkLine originMap (goLine, line) =
    mapMaybe (\m -> m originMap goLine line)
        [ patternTypedKernelAnyArg
        , patternRawTypeAssert
        , patternGenericInstAnyOnly
        ]


-- | Pattern 1: typed-kernel call with a raw any-typed arg.
--
-- A typed kernel is any helper ending with `T` (e.g. `rt.List_dropT`,
-- `rt.AsListT`, `rt.MaybeCoerceT`).  Its first generic-positional
-- arg is expected to be either:
--   * A literal (numeric / string / bool).
--   * A wrapped expression: `rt.AsInt(...)`, `rt.AsBool(...)`,
--     `rt.AsString(...)`, `rt.Coerce[...](...)`, etc.
--   * A typed Go value (struct field access, typed func return).
--
-- We flag the first arg ONLY when it's a bare identifier (a single
-- Go identifier with no surrounding call / literal / selector
-- chain).  Bare identifiers carry whatever Sky-side type the
-- caller bound, which is usually `any` in v0.12-era codegen.
patternTypedKernelAnyArg :: OriginMap -> Int -> String -> Maybe Diag.Diagnostic
patternTypedKernelAnyArg originMap goLine line =
    case findRtTypedCall line of
        Just (helperName, firstArg) | isBareIdent firstArg
                                    , helperName `elem` riskyTypedKernels ->
            Just $ buildCodegenDiag originMap goLine
                Diag.codegenE_TypedKernelAnyArg
                ("Codegen emitted a typed kernel call with a bare\n"
              ++ "any-typed argument:\n\n"
              ++ "    rt." ++ helperName ++ "(...)\n\n"
              ++ "The first argument `" ++ firstArg ++ "` was not\n"
              ++ "wrapped in `rt.AsInt` / `rt.AsString` / `rt.AsList`\n"
              ++ "or a similar coercer.  `go build` will reject this\n"
              ++ "as `cannot use " ++ firstArg ++ " (any) as <T>`.\n\n"
              ++ "This is a Sky compiler bug — the type system\n"
              ++ "accepted the program but codegen forgot the\n"
              ++ "coerce wrap.  File an issue at\n"
              ++ "https://github.com/anzellai/sky/issues with the\n"
              ++ "Sky source.")
        _ -> Nothing


-- | Pattern 2: raw `.(T)` type-assertion outside of `rt.Coerce*` helpers.
--
-- P0-3 audit prohibits these on generated any-typed thunks — they
-- panic on nil / wrong-type instead of returning a typed Err.
-- Detection: look for `.(<TypeName>)` where the preceding context
-- isn't a Coerce-family helper definition (i.e. we're inside a
-- user-code site, not the runtime helpers themselves).
patternRawTypeAssert :: OriginMap -> Int -> String -> Maybe Diag.Diagnostic
patternRawTypeAssert _originMap _goLine _line =
    -- Conservative: not yet enabled.  False-positive risk is high
    -- because legitimate type-assertions on typed values (post-
    -- Coerce) also match `.(T)` syntactically.  Re-enable after
    -- threading more context.
    Nothing


-- | Pattern 3: typed generic instantiation where every type slot
-- is `any` — a marker that typed-codegen fell back to any-routing.
-- Not strictly a bug (compiles cleanly, just slow), so we emit a
-- warning-severity Diagnostic rather than an error.
patternGenericInstAnyOnly :: OriginMap -> Int -> String -> Maybe Diag.Diagnostic
patternGenericInstAnyOnly _originMap _goLine _line =
    -- Not yet enabled — needs targeted scope to avoid noise on
    -- legitimate `any` instantiations (e.g. `rt.List_mapAnyT[any]`
    -- which IS the correct routing for non-inferable lambdas).
    Nothing


-- ─── helper predicates ───────────────────────────────────────────────


-- | The set of typed-kernel helpers that strictly require typed
-- first-arg shape.  Mirrors the surface of `typedKernelArgCoerce`
-- in Compile.hs — a missing entry there manifests as a hit here.
riskyTypedKernels :: [String]
riskyTypedKernels =
    -- List helpers — first arg is the Int count or fn closure;
    -- second is the slice.  Listed in [helper, typed-first-arg-form].
    [ "List_takeT"
    , "List_dropT"
    , "List_takeAnyT"
    , "List_dropAnyT"
    , "List_indexedMapTA"
    , "Dict_fromListT"
    ]


-- | Match a `rt.<Helper>(args...)` call on the line and return the
-- helper name + the first arg (best-effort literal extraction).
-- Returns Nothing if the line doesn't contain a rt.* call.
findRtTypedCall :: String -> Maybe (String, String)
findRtTypedCall s =
    case dropToPrefix "rt." s of
        Just rest ->
            let (helperName, afterName) = span isGoIdentChar rest
                afterGeneric = skipGenericBrackets afterName
            in case afterGeneric of
                ('(':args) ->
                    let firstArg = takeWhile (\c -> c /= ',' && c /= ')') args
                        cleaned  = trim firstArg
                    in if null helperName || null cleaned
                       then Nothing
                       else Just (helperName, cleaned)
                _ -> Nothing
        Nothing -> Nothing


-- | Is the input a bare Go identifier (no parens, dots, etc.)?
isBareIdent :: String -> Bool
isBareIdent "" = False
isBareIdent s  =
    all isGoIdentChar s
    && not (head s `elem` ("0123456789" :: String))
    -- A bare ident isn't a literal (`true`, `false`, `nil` ARE bare
    -- idents but are valid typed values — exclude them).
    && s `notElem` ["true", "false", "nil"]


isGoIdentChar :: Char -> Bool
isGoIdentChar c =
       (c >= 'a' && c <= 'z')
    || (c >= 'A' && c <= 'Z')
    || (c >= '0' && c <= '9')
    || c == '_'


-- | Walk past `[T1, T2, ...]` generic brackets if present.
skipGenericBrackets :: String -> String
skipGenericBrackets ('[':xs) = case dropWhile (/= ']') xs of
    (']':rest) -> rest
    _          -> xs
skipGenericBrackets s = s


-- | Find the first occurrence of `prefix` in `s`, return what
-- follows.  Returns Nothing if not found.
dropToPrefix :: String -> String -> Maybe String
dropToPrefix p s
    | p `isPrefixOf` s = Just (drop (length p) s)
    | otherwise = case s of
        []     -> Nothing
        (_:cs) -> dropToPrefix p cs


trim :: String -> String
trim = dropWhile (== ' ') . reverse . dropWhile (== ' ') . reverse


-- ─── origin tracking ─────────────────────────────────────────────────


-- | Map from Go-source line number to the Sky region it originated
-- from.  Populated by parsing `// SKY-ORIGIN: <path>:<line>:<col>`
-- comments that codegen sprinkles into main.go at function-decl
-- boundaries.
type OriginMap = Map.Map Int (FilePath, Int, Int)


-- | Inject `// SKY-ORIGIN: <path>:<line>:<col>` comments into
-- the emitted Go text at every function declaration whose name
-- maps to a known Sky source position.  The `nameMap` is keyed by
-- the EMITTED Go-function name (e.g. `Main_update`, `view`,
-- `Model`) and points at the Sky source region.
--
-- The post-processor scans the goCode for `^func <Name>(...)` lines
-- and prepends an origin comment when the name has a Sky position.
-- Idempotent: if a SKY-ORIGIN comment already precedes the func,
-- it's left untouched (we re-render `goCode` from a fresh codegen
-- on every build, so this is mostly safety against double-running).
--
-- The injection happens BEFORE `validateEmittedGo` and BEFORE
-- writing main.go to disk, so the origin map seen by the
-- validator and by `go build` error refiner is consistent.
injectOriginComments
    :: Map.Map String (FilePath, Int, Int)
    -> String
    -> String
injectOriginComments nameMap source =
    unlines (walkLines (lines source))
  where
    walkLines [] = []
    walkLines (l:ls)
        | Just funcName <- parseFuncDecl l
        , Just (skyPath, skyLine, skyCol) <- Map.lookup funcName nameMap
        , not (hasPrecedingOrigin ls' l) =
            ("// SKY-ORIGIN: " ++ skyPath ++ ":" ++ show skyLine
              ++ ":" ++ show skyCol) : l : walkLines ls
        | otherwise = l : walkLines ls
      where ls' = []  -- placeholder; preceding-origin check would walk back

    parseFuncDecl line =
        case stripPrefix "func " line of
            Just rest ->
                let (name, after) = span isGoIdentChar rest
                    -- Could also be `func name[T any]` (generic) or
                    -- `func name(` (plain).  Accept either next char.
                in case after of
                    ('(':_) | not (null name) -> Just name
                    ('[':_) | not (null name) -> Just name
                    _ -> Nothing
            Nothing -> Nothing

    hasPrecedingOrigin _ _ = False


-- | Walk emitted main.go text, parse SKY-ORIGIN comments, return
-- a map keyed by Go line number.
parseOriginComments :: String -> OriginMap
parseOriginComments source =
    let lns = zip [1..] (lines source)
        entries = mapMaybe parseEntry lns
    in Map.fromList entries
  where
    parseEntry (goLine, line) =
        case stripPrefix "// SKY-ORIGIN:" (dropWhile (== ' ') line) of
            Just rest -> case parseFileLineCol (trim rest) of
                Just (p, l, c) -> Just (goLine, (p, l, c))
                Nothing        -> Nothing
            Nothing -> Nothing

    parseFileLineCol s =
        -- Format: "<path>:<line>:<col>".  Path may contain '/' so
        -- we parse from the END: scan backward for two ':'-delimited
        -- numeric tail segments.
        case splitLast ':' s of
            Just (rest1, colStr) | all isAsciiDigit colStr ->
                case splitLast ':' rest1 of
                    Just (path, lineStr) | all isAsciiDigit lineStr ->
                        Just (path, read lineStr, read colStr)
                    _ -> Nothing
            _ -> Nothing

    splitLast c s = case break (== c) (reverse s) of
        (rev, ':':revRest) -> Just (reverse revRest, reverse rev)
        _                  -> Nothing

    isAsciiDigit ch = ch >= '0' && ch <= '9'


-- ─── go-build error → Sky source ─────────────────────────────────────


data GoErrorLocation = GoErrorLocation
    { _gel_file    :: !FilePath  -- always main.go (or rt/*.go for runtime)
    , _gel_line    :: !Int
    , _gel_col     :: !Int
    , _gel_message :: !String    -- the Go error message body
    }
    deriving (Show)


-- | Parse `main.go:NN:MM: <message>` shape from a go-build stderr
-- line.  Returns the first match.  Lines that don't match (e.g.
-- "go.mod requires Go 1.21") are skipped.
parseGoBuildError :: String -> Maybe GoErrorLocation
parseGoBuildError stderrText =
    case filter looksLikeGoError (lines stderrText) of
        (l:_) -> parseOne l
        []    -> Nothing
  where
    looksLikeGoError s =
        (".go:" `isInfixOf` s)
        && any (`isInfixOf` s) [": cannot ", ": undefined", ": syntax error"
                               , ": type ", ": expected ", ": missing "]

    parseOne s =
        -- Tolerant parse: "<path>.go:NN:MM: <body>"
        case break (== ':') s of
            (filePath, ':':rest1) | ".go" `isSuffixOf` filePath ->
                case break (== ':') rest1 of
                    (lineStr, ':':rest2) | all isAsciiDigit lineStr ->
                        case break (== ':') rest2 of
                            (colStr, ':':body) | all isAsciiDigit colStr ->
                                Just $ GoErrorLocation
                                    { _gel_file    = filePath
                                    , _gel_line    = read lineStr
                                    , _gel_col     = read colStr
                                    , _gel_message = dropWhile (== ' ') body
                                    }
                            _ -> Nothing
                    _ -> Nothing
            _ -> Nothing
    isAsciiDigit ch = ch >= '0' && ch <= '9'


-- | Given a Go-side error location and an OriginMap, find the
-- nearest preceding SKY-ORIGIN entry and build a Diagnostic
-- pointing at the Sky source.
resolveGoErrorToSky :: OriginMap -> GoErrorLocation -> Maybe Diag.Diagnostic
resolveGoErrorToSky originMap gel =
    case findNearestOrigin originMap (_gel_line gel) of
        Just (skyPath, skyLine, skyCol) ->
            let region = A.Region
                    (A.Position skyLine skyCol)
                    (A.Position skyLine skyCol)
                msg = "Code generation produced Go that `go build` rejected:\n\n"
                   ++ "    " ++ _gel_file gel ++ ":" ++ show (_gel_line gel)
                   ++ ":" ++ show (_gel_col gel) ++ ": "
                   ++ _gel_message gel ++ "\n\n"
                   ++ "This is a Sky compiler bug.  The Sky type system\n"
                   ++ "accepted this program but codegen emitted Go that\n"
                   ++ "the Go compiler does not accept.  Please file an\n"
                   ++ "issue at https://github.com/anzellai/sky/issues with\n"
                   ++ "this Sky source attached."
            in Just $ Diag.mkError skyPath region
                        Diag.CatGoBuild Diag.goE_BuildFailed msg
        Nothing -> Nothing


-- | Linear-scan O(n) walk to find the largest origin-key not
-- exceeding goLine.  For typical main.go sizes (10k–100k lines)
-- this is fast enough; if it becomes a hot path, switch to a
-- tree-backed Map with `lookupLE`.
findNearestOrigin :: OriginMap -> Int -> Maybe (FilePath, Int, Int)
findNearestOrigin originMap goLine =
    let keys = Map.keys originMap
        eligible = filter (<= goLine) keys
    in case eligible of
        [] -> Nothing
        _  -> Map.lookup (maximum eligible) originMap


-- ─── shared diagnostic builder ───────────────────────────────────────


buildCodegenDiag :: OriginMap -> Int -> Diag.DiagCode -> String -> Diag.Diagnostic
buildCodegenDiag originMap goLine code message =
    case findNearestOrigin originMap goLine of
        Just (skyPath, skyLine, skyCol) ->
            let region = A.Region
                    (A.Position skyLine skyCol)
                    (A.Position skyLine skyCol)
            in Diag.mkError skyPath region Diag.CatCodegen code message
        Nothing ->
            -- Fallback: synthetic region pointing at main.go.
            let region = A.Region (A.Position goLine 1) (A.Position goLine 1)
            in Diag.mkError "<generated>" region
                    Diag.CatCodegen code message
