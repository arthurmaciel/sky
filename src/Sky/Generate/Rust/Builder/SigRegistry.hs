module Sky.Generate.Rust.Builder.SigRegistry
  ( knownDefSig
  , listSig
  , stringSig
  , maybeSig
  , resultSig
  , errorSig
  , sigTVars
  , scanTVars
  , matchesModulePrefix
  ) where

import Data.Char (isDigit)
import Data.List (isPrefixOf)
import qualified Data.Set as Set
import Sky.Generate.Rust.Builder.Naming (toCamelCase)

-- | Does a mangled module prefix `p` name exactly the stdlib module `seg`
-- (or one of its sub-modules)? An exact `==` match, or `seg` followed by a `_`
-- boundary — so the stdlib `Sky_Core_List` matches but a USER module
-- `Sky_Core_ListExtra` (which would mangle to a single segment `…ListExtra`)
-- does NOT get hijacked onto listSig. `isPrefixOf` alone was too loose.
matchesModulePrefix :: String -> String -> Bool
matchesModulePrefix seg p = p == seg || (seg ++ "_") `isPrefixOf` p

-- | Known signatures for common Def functions (stdlib etc.), keyed by (module_prefix, name, arity)
knownDefSig :: String -> String -> Int -> Maybe ([String], String)
-- List module
knownDefSig p n a | matchesModulePrefix "Sky_Core_List" p = listSig n a
-- Maybe module
knownDefSig p n a | matchesModulePrefix "Sky_Core_Maybe" p = maybeSig n a
-- Error module
knownDefSig p n a | matchesModulePrefix "Sky_Core_Error" p = errorSig n a
knownDefSig p n a | matchesModulePrefix "Sky_Core_Result" p = resultSig n a
knownDefSig p n a | matchesModulePrefix "Sky_Core_String" p = stringSig n a
-- Main module helpers
knownDefSig _ _ _ = Nothing

listSig :: String -> Int -> Maybe ([String], String)
listSig "map" 2 = Just (["impl Fn(T0) -> T1 + Clone", "Vec<T0>"], "Vec<T1>")
-- v0.17 CPS/accumulator helpers. Upstream dropped their explicit `.sky`
-- signatures (their bodies over-constrained Go-side HM cross-module unification —
-- see the concatMapHelp note in List.sky). The Go backend infers these per-region
-- from the solver; the Rust backend's solved-sig path can't render a polymorphic
-- higher-order param (a `(a -> b)` TLambda is neither concrete nor an open
-- record), so it fell through to the body-analysis fallback and mis-emitted the
-- function param as `Vec<T0>` with no return type. Register them here (same
-- mechanism as the already-listed `indexedMapHelp`/`reverseHelp`) so the recursion
-- helpers get their proper generic bounds. These are private stdlib helpers — the
-- shapes mirror their public partners (`map`/`filter`/`concatMap`/`take`/`append`/
-- `concat`) exactly.
listSig "mapHelp" 3 = Just (["impl Fn(T0) -> T1 + Clone", "Vec<T0>", "Vec<T1>"], "Vec<T1>")
listSig "filterHelp" 3 = Just (["impl Fn(T0) -> bool + Clone", "Vec<T0>", "Vec<T0>"], "Vec<T0>")
listSig "concatMapHelp" 3 = Just (["impl Fn(T0) -> Vec<T1> + Clone", "Vec<T0>", "Vec<T1>"], "Vec<T1>")
listSig "takeHelp" 3 = Just (["i64", "Vec<T0>", "Vec<T0>"], "Vec<T0>")
listSig "appendHelp" 2 = Just (["Vec<T0>", "Vec<T0>"], "Vec<T0>")
listSig "concatHelp" 2 = Just (["Vec<Vec<T0>>", "Vec<T0>"], "Vec<T0>")
listSig "appendReverseOnto" 2 = Just (["Vec<T0>", "Vec<T0>"], "Vec<T0>")
-- `filterMap` return T1 doesn't need Clone (Task or other non-Clone types)
listSig "filterMap" 2 = Just (["impl Fn(T0) -> SkyMaybe<T1> + Clone", "Vec<T0>"], "Vec<T1>")
-- `map` with discarded side effects: T1 doesn't need Clone (Task results)
listSig "mapToList" 2 = Just (["impl Fn(T0) -> T1 + Clone", "Vec<T0>"], "Vec<T1>")
-- filter pred takes T0 by value; double-clone in branch prefix + VarLocal clone in body covers the two uses
listSig "filter" 2 = Just (["impl Fn(T0) -> bool + Clone", "Vec<T0>"], "Vec<T0>")
-- Generated body calls r#fn(x, acc) — element first, accumulator second
listSig "foldl" 3 = Just (["impl Fn(T0, T1) -> T1 + Clone", "T1", "Vec<T0>"], "T1")
listSig "foldr" 3 = Just (["impl Fn(T0, T1) -> T1 + Clone", "T1", "Vec<T0>"], "T1")
listSig "cons" 2 = Just (["T0", "Vec<T0>"], "Vec<T0>")
listSig "head" 1 = Just (["Vec<T0>"], "SkyMaybe<T0>")
listSig "tail" 1 = Just (["Vec<T0>"], "SkyMaybe<Vec<T0>>")
listSig "isEmpty" 1 = Just (["Vec<T0>"], "bool")
-- length needs no Clone (just counts elements)
listSig "length" 1 = Just (["Vec<T0>"], "i64")
listSig "reverse" 1 = Just (["Vec<T0>"], "Vec<T0>")
-- reverseHelp list acc = case list of { [] -> acc; x::rest -> reverseHelp rest (x::acc) }
listSig "reverseHelp" 2 = Just (["Vec<T0>", "Vec<T0>"], "Vec<T0>")
listSig "append" 2 = Just (["Vec<T0>", "Vec<T0>"], "Vec<T0>")
-- concat : List (List a) -> List a
listSig "concat" 1 = Just (["Vec<Vec<T0>>"], "Vec<T0>")
listSig "member" 2 = Just (["T0", "Vec<T0>"], "bool")
-- any/all: pred takes T0 by value; Clone required for recursive pass
listSig "any" 2 = Just (["impl Fn(T0) -> bool + Clone", "Vec<T0>"], "bool")
listSig "all" 2 = Just (["impl Fn(T0) -> bool + Clone", "Vec<T0>"], "bool")
-- find pred takes T0 by value; Clone for recursive pass
listSig "find" 2 = Just (["impl Fn(T0) -> bool + Clone", "Vec<T0>"], "SkyMaybe<T0>")
listSig "range" 2 = Just (["i64", "i64"], "Vec<i64>")
listSig "take" 2 = Just (["i64", "Vec<T0>"], "Vec<T0>")
listSig "drop" 2 = Just (["i64", "Vec<T0>"], "Vec<T0>")
listSig "concatMap" 2 = Just (["impl Fn(T0) -> Vec<T1> + Clone", "Vec<T0>"], "Vec<T1>")
-- zip : List a -> List b -> List (a, b)
listSig "zip" 2 = Just (["Vec<T0>", "Vec<T1>"], "Vec<(T0, T1)>")
listSig "indexedMap" 2 = Just (["impl Fn(i64, T0) -> T1 + Clone", "Vec<T0>"], "Vec<T1>")
listSig "indexedMapHelp" 3 = Just (["impl Fn(i64, T0) -> T1 + Clone", "i64", "Vec<T0>"], "Vec<T1>")
listSig _ _ = Nothing

stringSig :: String -> Int -> Maybe ([String], String)
stringSig "fromInt" 1  = Just (["i64"], "String")
stringSig "fromFloat" 1  = Just (["f64"], "String")
stringSig "length" 1  = Just (["String"], "i64")
stringSig "isEmpty" 1  = Just (["String"], "bool")
stringSig "reverse" 1  = Just (["String"], "String")
stringSig "append" 2  = Just (["String", "String"], "String")
stringSig "contains" 2  = Just (["String", "String"], "bool")
stringSig "startsWith" 2 = Just (["String", "String"], "bool")
stringSig "endsWith" 2 = Just (["String", "String"], "bool")
stringSig "toInt" 1  = Just (["String"], "SkyMaybe<i64>")
stringSig "toLower" 1  = Just (["String"], "String")
stringSig "toUpper" 1  = Just (["String"], "String")
stringSig "trim" 1  = Just (["String"], "String")
stringSig "split" 2  = Just (["String", "String"], "Vec<String>")
stringSig "join" 2  = Just (["Vec<String>", "String"], "String")
stringSig "replace" 3 = Just (["String", "String", "String"], "String")
stringSig "slice" 3 = Just (["String", "i64", "i64"], "String")
stringSig _ _ = Nothing

maybeSig :: String -> Int -> Maybe ([String], String)
maybeSig "map" 2 = Just (["impl Fn(T0) -> T1 + Clone", "SkyMaybe<T0>"], "SkyMaybe<T1>")
maybeSig "andThen" 2 = Just (["impl Fn(T0) -> SkyMaybe<T1> + Clone", "SkyMaybe<T0>"], "SkyMaybe<T1>")
maybeSig "withDefault" 2 = Just (["T0", "SkyMaybe<T0>"], "T0")
maybeSig "map2" 3 = Just (["impl Fn(T0, T1) -> T2 + Clone", "SkyMaybe<T0>", "SkyMaybe<T1>"], "SkyMaybe<T2>")
maybeSig "map3" 4 = Just (["impl Fn(T0, T1, T2) -> T3 + Clone", "SkyMaybe<T0>", "SkyMaybe<T1>", "SkyMaybe<T2>"], "SkyMaybe<T3>")
maybeSig "map4" 5 = Just (["impl Fn(T0, T1, T2, T3) -> T4 + Clone", "SkyMaybe<T0>", "SkyMaybe<T1>", "SkyMaybe<T2>", "SkyMaybe<T3>"], "SkyMaybe<T4>")
maybeSig "map5" 6 = Just (["impl Fn(T0, T1, T2, T3, T4) -> T5 + Clone", "SkyMaybe<T0>", "SkyMaybe<T1>", "SkyMaybe<T2>", "SkyMaybe<T3>", "SkyMaybe<T4>"], "SkyMaybe<T5>")
maybeSig "andMap" 2 = Just (["SkyMaybe<T0>", "SkyMaybe<impl Fn(T0) -> T1 + Clone>"], "SkyMaybe<T1>")
maybeSig "isJust" 1 = Just (["SkyMaybe<T0>"], "bool")
maybeSig "isNothing" 1 = Just (["SkyMaybe<T0>"], "bool")
-- combine : List (Maybe a) -> Maybe (List a)
maybeSig "combine" 1 = Just (["Vec<SkyMaybe<T0>>"], "SkyMaybe<Vec<T0>>")
-- v0.17 CPS helpers for `combine` (unsigned in Maybe.sky). `combineHelp` builds
-- the unwrapped list in a reversed accumulator; `reverseHelp` is Maybe.sky's own
-- inlined list-reverse (kept private to avoid a Maybe↔List import cycle).
maybeSig "combineHelp" 2 = Just (["Vec<SkyMaybe<T0>>", "Vec<T0>"], "SkyMaybe<Vec<T0>>")
maybeSig "reverseHelp" 2 = Just (["Vec<T0>", "Vec<T0>"], "Vec<T0>")
maybeSig _ _ = Nothing

resultSig :: String -> Int -> Maybe ([String], String)
resultSig "map" 2 = Just (["impl Fn(T0) -> T1 + Clone", "SkyResult<SkyError, T0>"], "SkyResult<SkyError, T1>")
resultSig "andThen" 2 = Just (["impl Fn(T0) -> SkyResult<SkyError, T1> + Clone", "SkyResult<SkyError, T0>"], "SkyResult<SkyError, T1>")
-- sub-A.12 F1: Sky source `mapError : (e -> e2) -> Result e a -> Result e2 a`
-- is fully polymorphic in BOTH error types. Previously hardcoded as
-- (SkyError -> String) which mis-typed wrapper calls — the closure may
-- well return Error not String. Use T1/T2 for the error transform.
resultSig "mapError" 2 = Just (["impl Fn(T1) -> T2 + Clone", "SkyResult<T1, T0>"], "SkyResult<T2, T0>")
resultSig "withDefault" 2 = Just (["T0", "SkyResult<SkyError, T0>"], "T0")
resultSig "map2" 3 = Just (["impl Fn(T0, T1) -> T2 + Clone", "SkyResult<SkyError, T0>", "SkyResult<SkyError, T1>"], "SkyResult<SkyError, T2>")
resultSig "map3" 4 = Just (["impl Fn(T0, T1, T2) -> T3 + Clone", "SkyResult<SkyError, T0>", "SkyResult<SkyError, T1>", "SkyResult<SkyError, T2>"], "SkyResult<SkyError, T3>")
resultSig "map4" 5 = Just (["impl Fn(T0, T1, T2, T3) -> T4 + Clone", "SkyResult<SkyError, T0>", "SkyResult<SkyError, T1>", "SkyResult<SkyError, T2>", "SkyResult<SkyError, T3>"], "SkyResult<SkyError, T4>")
resultSig "map5" 6 = Just (["impl Fn(T0, T1, T2, T3, T4) -> T5 + Clone", "SkyResult<SkyError, T0>", "SkyResult<SkyError, T1>", "SkyResult<SkyError, T2>", "SkyResult<SkyError, T3>", "SkyResult<SkyError, T4>"], "SkyResult<SkyError, T5>")
resultSig "andMap" 2 = Just (["SkyResult<SkyError, T0>", "SkyResult<SkyError, impl Fn(T0) -> T1 + Clone>"], "SkyResult<SkyError, T1>")
resultSig "combine" 1 = Just (["Vec<SkyResult<SkyError, T0>>"], "SkyResult<SkyError, Vec<T0>>")
resultSig "traverse" 2 = Just (["impl Fn(T0) -> SkyResult<SkyError, T1> + Clone", "Vec<T0>"], "SkyResult<SkyError, Vec<T1>>")
-- v0.17 CPS helpers for `combine` (unsigned in Result.sky). `combineHelp` builds
-- the unwrapped list in a reversed accumulator; `reverseHelp` is Result.sky's own
-- inlined list-reverse (kept private to avoid a Result↔List import cycle).
resultSig "combineHelp" 2 = Just (["Vec<SkyResult<SkyError, T0>>", "Vec<T0>"], "SkyResult<SkyError, Vec<T0>>")
resultSig "reverseHelp" 2 = Just (["Vec<T0>", "Vec<T0>"], "Vec<T0>")
resultSig _ _ = Nothing

errorSig :: String -> Int -> Maybe ([String], String)
errorSig "mkInfo" 1 = Just (["String"], "SkyError")
errorSig "io" 1 = Just (["String"], "SkyError")
errorSig "network" 1 = Just (["String"], "SkyError")
errorSig "ffi" 1 = Just (["String"], "SkyError")
errorSig "decode" 1 = Just (["String"], "SkyError")
errorSig "timeout" 0 = Just ([], "SkyError")
errorSig "notFound" 0 = Just ([], "SkyError")
errorSig "permissionDenied" 0 = Just ([], "SkyError")
errorSig "invalidInput" 1 = Just (["String"], "SkyError")
errorSig "conflict" 1 = Just (["String"], "SkyError")
errorSig "unavailable" 1 = Just (["String"], "SkyError")
errorSig "unexpected" 1 = Just (["String"], "SkyError")
errorSig "withMessage" 2 = Just (["String", "SkyError"], "SkyError")
errorSig "withDetails" 2 = Just ([toCamelCase "Sky_Core_Error_ErrorDetails", "SkyError"], "SkyError")
errorSig "kindLabel" 1 = Just ([toCamelCase "Sky_Core_Error_ErrorKind"], "String")
errorSig "toString" 1 = Just (["SkyError"], "String")
errorSig "isRetryable" 1 = Just (["SkyError"], "bool")
errorSig _ _ = Nothing

-- | Extract type variable names (T0, T1, …) from parameter and return type strings.
-- Works for any nesting depth: Vec<Vec<T0>>, Vec<(T0,T1)>, SkyMaybe<Vec<T0>>, etc.
sigTVars :: [String] -> String -> [String]
sigTVars paramTypes retType =
    Set.toList $ Set.fromList $ concatMap scanTVars (paramTypes ++ [retType])

-- | Scan a type string for all Tnn identifiers (T0, T1, T10, …).
scanTVars :: String -> [String]
scanTVars [] = []
scanTVars ('T':rest)
    | not (null digits) && (null after || not (isIdentChar (head after))) =
        ('T':digits) : scanTVars after
  where
    digits = takeWhile isDigit rest
    after  = dropWhile isDigit rest
    isDigit c = c >= '0' && c <= '9'
    isIdentChar c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || isDigit c || c == '_'
scanTVars (_:rest) = scanTVars rest
