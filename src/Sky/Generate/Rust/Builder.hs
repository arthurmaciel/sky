module Sky.Generate.Rust.Builder where

import Data.List (isSuffixOf, isPrefixOf, stripPrefix, sortBy, nub)
import Data.Maybe (fromMaybe)
import qualified Sky.Sky.Toml as Toml (RustDepSpec(..))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Sky.AST.Canonical as Can
import qualified Sky.Sky.ModuleName as ModuleName
import qualified Sky.Reporting.Annotation as Ann
import Data.Char (toLower, toUpper, isUpper)
import Numeric (showHex)

-- | Convert Sky module-prefixed names to Rust conventions:
--   Types:     Sky_Core_Error_Error  →  SkyCoreErrorError     (CamelCase)
--   Functions: Sky_Core_List_map     →  sky_core_list_map     (snake_case)
toCamelCase :: String -> String
toCamelCase [] = []
toCamelCase (c:cs) = toUpper c : go cs
  where go [] = []
        go ('_':c:cs) = toUpper c : go cs
        go (c:cs) = c : go cs

toSnakeCase :: String -> String
toSnakeCase [] = []
toSnakeCase (c:cs) = toLower c : go cs
  where go [] = []
        go (c:cs) | c == '_' && not (null cs) = '_' : toLower (head cs) : go (tail cs)
                  | isUpper c = '_' : toLower c : go cs
                  | otherwise = c : go cs



type CanonicalModule = Can.Module

-- | Which kernel features the user's code actually uses (scanned from AST)
data UsedKernels = UsedKernels
    { usesDb :: Bool           -- Std.Db imported → needs sqlx
    , usesTaskRun :: Bool       -- Task.run called → needs tokio runtime
    , usesTaskParallel :: Bool  -- Task.parallel called → needs tokio::spawn
    , usesJson :: Bool          -- Json.* imported → needs serde_json
    , usesCrypto :: Bool         -- Crypto.* imported → needs sha2
    , usesTime :: Bool            -- Time.* imported
    , usesRandom :: Bool          -- Random.* imported
    , usesFile :: Bool            -- File.* imported
    } deriving (Show, Eq)

instance Semigroup UsedKernels where
    a <> b = UsedKernels
        { usesDb = usesDb a || usesDb b
        , usesTaskRun = usesTaskRun a || usesTaskRun b
        , usesTaskParallel = usesTaskParallel a || usesTaskParallel b
        , usesJson = usesJson a || usesJson b
        , usesCrypto = usesCrypto a || usesCrypto b
        , usesTime = usesTime a || usesTime b
        , usesRandom = usesRandom a || usesRandom b
        , usesFile = usesFile a || usesFile b
        }
instance Monoid UsedKernels where
    mempty = UsedKernels False False False False False False False False

-- | Walk all expressions across all modules to detect kernel usage.
-- Ensures we only emit the runtime stubs and Cargo deps that are actually needed.
analyzeKernelUsage :: [Can.Module] -> UsedKernels
analyzeKernelUsage = foldMap analyzeMod
  where
    analyzeMod mod = walkDecls (Can._decls mod)

    walkDecls Can.SaveTheEnvironment = mempty
    walkDecls (Can.Declare def rest) = walkDef def <> walkDecls rest
    walkDecls (Can.DeclareRec def defs rest) = walkDef def <> foldMap walkDef defs <> walkDecls rest

    walkDef (Can.Def _ _ body) = walkExpr body
    walkDef (Can.TypedDef _ _ _ body _) = walkExpr body
    walkDef (Can.DestructDef _ expr) = walkExpr expr

    walkExpr (Ann.At _ expr) = case expr of
        Can.VarKernel modName fnName ->
            detectKernelUsage modName fnName
        Can.VarTopLevel modName _ ->
            detectKernelUsage (ModuleName._name modName) ""
        Can.Call fn args -> walkExpr fn <> foldMap walkExpr args
        Can.Lambda _ body -> walkExpr body
        Can.Let def body -> walkDef def <> walkExpr body
        Can.LetRec defs body -> foldMap walkDef defs <> walkExpr body
        Can.LetDestruct _ e body -> walkExpr e <> walkExpr body
        Can.Case scrut branches -> walkExpr scrut <> foldMap (\(Can.CaseBranch _ b) -> walkExpr b) branches
        Can.If branches elseBranch ->
            foldMap (\(c, t) -> walkExpr c <> walkExpr t) branches <> walkExpr elseBranch
        Can.Binop _ _ _ _ a b -> walkExpr a <> walkExpr b
        Can.Access r _ -> walkExpr r
        Can.Update _ r updates -> walkExpr r <> foldMap (\(_, Can.FieldUpdate _ e) -> walkExpr e) (Map.toList updates)
        Can.Record fields -> foldMap (\(_, v) -> walkExpr v) (Map.toList fields)
        Can.List es -> foldMap walkExpr es
        Can.Tuple a b rest -> foldMap walkExpr (a:b:rest)
        Can.Negate e -> walkExpr e
        _ -> mempty

    detectKernelUsage modName fnName =
        mconcat
            [ if "Db" `isSuffixOf` modName || modName == "Db"
              then mempty { usesDb = True } else mempty
            , if (modName == "Task" || "Sky.Core.Task" `isSuffixOf` modName)
                  && (fnName == "run" || fnName == "sequence" || fnName == "perform")
              then mempty { usesTaskRun = True } else mempty
            , if (modName == "Task" || "Sky.Core.Task" `isSuffixOf` modName) && fnName == "parallel"
              then mempty { usesTaskParallel = True } else mempty
            , if "System" `isSuffixOf` modName || modName == "System"
              then mempty { usesTaskRun = True } else mempty
            , if "Json" `isPrefixOf` modName || "Sky.Core.Json" `isPrefixOf` modName
              then mempty { usesJson = True } else mempty
            , if "Crypto" `isPrefixOf` modName || "Sky.Core.Crypto" `isPrefixOf` modName
              then mempty { usesCrypto = True } else mempty
            , if "Time" `isPrefixOf` modName || "Sky.Core.Time" `isPrefixOf` modName
              then mempty { usesTime = True } <> (if fnName == "sleep" then mempty { usesTaskRun = True } else mempty)
              else mempty
            , if "Random" `isPrefixOf` modName || "Sky.Core.Random" `isPrefixOf` modName
              then mempty { usesRandom = True } else mempty
            , if "File" `isPrefixOf` modName || "Sky.Core.File" `isPrefixOf` modName
              then mempty { usesFile = True } else mempty
            ]

-- | Known zero-argument kernel stubs that must be called with () when referenced.
-- These emit Rust `fn name() -> T` but are used as value `T` in Sky expressions.
zeroArgKernelDefs :: Set.Set (String, String)
zeroArgKernelDefs = Set.fromList
    [ ("JsonDec", "string")
    , ("JsonDec", "int")
    , ("JsonDec", "float")
    , ("JsonDec", "bool")
    , ("JsonDec", "null")
    ]

-- | Collect all zero-argument user-defined definitions across all modules.
-- Every such definition emits `fn name() -> T` in Rust, so VarTopLevel references
-- must emit `name()` instead of bare `name`.
collectZeroArgDefs :: [Can.Module] -> Set.Set (String, String)
collectZeroArgDefs mods = foldMap walkMod mods `Set.union` zeroArgKernelDefs
  where
    walkMod m = walkDecls (moduleNameToRust (Can._name m)) (Can._decls m)
    walkDecls prefix Can.SaveTheEnvironment = mempty
    walkDecls prefix (Can.Declare def rest) = walkDef prefix def <> walkDecls prefix rest
    walkDecls prefix (Can.DeclareRec def defs rest) =
        walkDef prefix def <> foldMap (walkDef prefix) defs <> walkDecls prefix rest
    walkDef prefix (Can.Def (Ann.At _ name) [] _body) = Set.singleton (prefix, name)
    walkDef prefix (Can.TypedDef (Ann.At _ name) _ [] _body _) = Set.singleton (prefix, name)
    walkDef _ _ = mempty

data RustBuilder = RustBuilder
    { builderModules    :: [RustModule]
    , builderTypes      :: [RustTypeDef]
    , builderKernels    :: UsedKernels
    , builderFfiOpaques :: Set.Set String  -- types defined by Rust FFI bindings, skip placeholders
    }

data RustModule = RustModule
    { modName :: String
    , modItems :: [RustItem]
    }

data RustItem
    = RustFunction String String [String] String String  -- name, generics_decl, params, ret_type, body
    | RustStruct String [(String, String)]
    | RustEnum String [(String, Maybe String)]
    | RustTypeAlias String String

data RustTypeDef
    = REnumDef String [(String, Maybe String)]
    | RStructDef String String [(String, String)]  -- name, generics_decl, fields
    | RAliasDef String String
    -- | Bridge for Sky opaque types whose representation lives in `sky_runtime`.
    -- Codegen emits `pub use <rustPath> as <codegenName>;` instead of a
    -- placeholder enum. Populated via runtimeOpaqueTypes registry hit in
    -- unionToRustTypeDef. See typeDefToString for the emission shape.
    | RPubUseAlias String String  -- codegenName, rustPath

-- | Sky opaque types whose Rust representation lives in `sky_runtime`.
-- Keyed on (Sky module name with dots, Sky type name). When unionToRustTypeDef
-- would otherwise produce a placeholder enum (e.g.
-- `pub enum StdDecimalDecimal { Decimal__Internal(f64) }`), this registry hit
-- redirects the emission to an `RPubUseAlias` — the runtime newtype IS the
-- canonical representation.
--
-- Sub-projects B-F add entries here as their runtime newtypes land.
runtimeOpaqueTypes :: Map.Map (String, String) String
runtimeOpaqueTypes = Map.fromList
    [ (("Std.Decimal", "Decimal"), "sky_runtime::Decimal")
    ]

-- | Context threaded through expression emission
data EmitCtx = EmitCtx
    { ecRecordMap :: Map.Map String String  -- field-key -> struct name
    , ecSolvedTypes :: Map.Map String Can.Type  -- function name -> inferred type
    , ecCloneVars :: Set.Set String  -- vars that need .clone() at every use site
    , ecCopyVars  :: Set.Set String  -- vars whose type is Rust Copy (i64, f64, bool, ...)
    , ecPipeInnerType :: Maybe String  -- inner type of piped Task<A>, set by |>
    , ecUsesTaskRun :: Bool  -- user calls Task.run → main returns ()
    , ecZeroArgDefs :: Set.Set (String, String)  -- (modPrefix, name) for zero-arg definitions
    , ecNoCloneVars :: Set.Set String  -- vars whose types don't implement Clone (e.g. Decoder)
    , ecCtorArity :: Map.Map String Int  -- alias name -> field count (for succeed curry wrapping)
    , ecKernelAliases :: Map.Map (String, String) (String, String)
        -- ^ Stage-4 kernel alias map: (canonicalModuleName, fnName) ->
        --   (kernelMod, kernelFn).  Populated during generateRust from
        --   the same Ffi.kernel dispatch table the Go codegen uses.
    }

-- | Build a map from field-name-signature to struct name
buildRecordMap :: [Can.Module] -> Map.Map String String
buildRecordMap mods = Map.fromList
    [ (intercalate "," (Map.keys fields), toCamelCase (modPrefix ++ "_" ++ name))
    | mod <- mods
    , let modPrefix = moduleNameToRust (Can._name mod)
    , (name, Can.Alias _ (Can.TRecord fields _)) <- Map.toList (Can._aliases mod)
    ]

-- | Anonymous record struct name prefix
anonStructName :: String -> String
anonStructName key = toCamelCase ("Anon_" ++ map (\c -> if c == ',' then '_' else c) key)

-- | Walk all expressions collecting anonymous record field signatures.
-- Returns field-key → [(field-name, HM-inferred-type)] for records NOT
-- covered by type-alias-defined structs.  Skips records with unresolved
-- type variables (TVar) to avoid emitting invalid generic struct fields.
collectAnonRecordTypes :: [Can.Module] -> Map.Map String [String]
collectAnonRecordTypes = foldMap walkMod
  where
    walkMod m = walkDecls (Can._decls m)

    walkDecls Can.SaveTheEnvironment = Map.empty
    walkDecls (Can.Declare def rest) = walkDef def <> walkDecls rest
    walkDecls (Can.DeclareRec def defs rest) = walkDef def <> foldMap walkDef defs <> walkDecls rest

    walkDef (Can.Def _ _ body) = walkExpr body
    walkDef (Can.TypedDef _ _ _ body _) = walkExpr body
    walkDef (Can.DestructDef _ expr) = walkExpr expr

    walkExpr (Ann.At _ expr) = case expr of
        Can.Record fields ->
            let key = intercalate "," (Map.keys fields)
                fieldNames = map fst (Map.toList fields)
            in Map.singleton key fieldNames <> walkFields fields
        _ -> walkSubExprs expr
      where
        walkFields flds = foldMap (\(_, e) -> walkExpr e) (Map.toList flds)

        walkSubExprs e = case e of
            Can.Call fn args -> walkExpr fn <> foldMap walkExpr args
            Can.Lambda _ body -> walkExpr body
            Can.Let def body -> walkDef def <> walkExpr body
            Can.LetRec defs body -> foldMap walkDef defs <> walkExpr body
            Can.LetDestruct _ e0 body -> walkExpr e0 <> walkExpr body
            Can.Case scrut branches -> walkExpr scrut <> foldMap (\(Can.CaseBranch _ b) -> walkExpr b) branches
            Can.If branches elseBranch -> foldMap (\(c, t) -> walkExpr c <> walkExpr t) branches <> walkExpr elseBranch
            Can.Binop _ _ _ _ a b -> walkExpr a <> walkExpr b
            Can.Access r _ -> walkExpr r
            Can.Update _ r updates -> walkExpr r <> foldMap (\(_, Can.FieldUpdate _ e) -> walkExpr e) (Map.toList updates)
            Can.Record _ -> mempty  -- already handled above
            Can.List es -> foldMap walkExpr es
            Can.Tuple a b rest -> foldMap walkExpr (a:b:rest)
            Can.Negate e0 -> walkExpr e0
            _ -> mempty  -- literals, variables: no sub-expressions

buildModule :: EmitCtx -> Can.Module -> RustModule
buildModule ctx mod = 
    let modPrefix = moduleNameToRust (Can._name mod)
        items = declsToRustItems ctx modPrefix (Can._decls mod)
        -- Existing function names after prefixing (to avoid double-emit)
        prefixed = map (\(RustFunction n g p r b) -> toSnakeCase (modPrefix ++ "_" ++ n)) 
                    [ f | f@(RustFunction _ _ _ _ _) <- items ]
        existingNames = Set.fromList prefixed
        -- Synthesize record alias constructors
        synCtorItems = concat [synCtor aliasName fields | (aliasName, Can.Alias _ (Can.TRecord fields _)) <- Map.toList (Can._aliases mod)]
        synCtor aliasName fields =
            let rm = ecRecordMap ctx
                ctorName = toSnakeCase (modPrefix ++ "_" ++ aliasName)
                structName = toCamelCase (modPrefix ++ "_" ++ aliasName)
                sortedFields = sortFieldsByIndex (Map.toList fields)
                rustFlds = [(n, typeToRustString rm ft) | (n, Can.FieldType _ ft) <- sortedFields]
                body = structName ++ " { " ++ intercalate ", " (map (\(n, _) -> n ++ ": " ++ n) sortedFields) ++ " }"
            in if Set.member ctorName existingNames then []
               else [RustFunction ctorName "" (map (\(n, t) -> n ++ ": " ++ t) rustFlds) structName body]
        prefixItem (RustFunction n g p r b)
            | n == "sky_main" || n == "main" = RustFunction n g p r b
            | otherwise = RustFunction (toSnakeCase (modPrefix ++ "_" ++ n)) g p r b
        prefixItem (RustStruct n f) = RustStruct (toCamelCase (modPrefix ++ "_" ++ n)) f
        prefixItem (RustEnum n v) = RustEnum (toCamelCase (modPrefix ++ "_" ++ n)) v
        prefixItem (RustTypeAlias n t) = RustTypeAlias (toCamelCase (modPrefix ++ "_" ++ n)) t
        prefixItem other = other
    in RustModule
        { modName = modPrefix
        , modItems = map prefixItem items ++ synCtorItems
        }

moduleNameToRust :: ModuleName.Canonical -> String
moduleNameToRust mod = 
    map (\c -> if c == '.' then '_' else c) (ModuleName._name mod)

declsToRustItems :: EmitCtx -> String -> Can.Decls -> [RustItem]
declsToRustItems _ctx _mod Can.SaveTheEnvironment = []
declsToRustItems ctx modPrefix (Can.Declare def rest) = defToRustItem ctx modPrefix def : declsToRustItems ctx modPrefix rest
declsToRustItems ctx modPrefix (Can.DeclareRec def defs rest) = 
    map (defToRustItem ctx modPrefix) (def : defs) ++ declsToRustItems ctx modPrefix rest

-- | Walk TLambda chain to extract the innermost (return) type
extractReturnType :: Can.Type -> Can.Type
extractReturnType (Can.TLambda _ ret) = extractReturnType ret
extractReturnType ty = ty

-- | Extract parameter types from a function type (TLambda chain), converting
-- each to a Rust type string.  Returns [] for non-function types.
extractParamTypes :: Can.Type -> [Can.Type]
extractParamTypes (Can.TLambda paramTy restTy) = paramTy : extractParamTypes restTy
extractParamTypes _ = []

-- | Check if a type contains unresolved type variables (should not be emitted)
hasTypeVars :: Can.Type -> Bool
hasTypeVars (Can.TVar _) = True
hasTypeVars (Can.TLambda a b) = hasTypeVars a || hasTypeVars b
hasTypeVars (Can.TType _ _ args) = any hasTypeVars args
hasTypeVars (Can.TTuple a b rest) = any hasTypeVars (a:b:rest)
hasTypeVars (Can.TRecord fields _) = any (hasTypeVars . Can._fieldType) (Map.elems fields)
hasTypeVars _ = False

-- | Collect all type variable names from a type (for generic param declaration).
collectTVars :: Can.Type -> [String]
collectTVars (Can.TVar v) = [v]
collectTVars (Can.TLambda a b) = collectTVars a ++ collectTVars b
collectTVars (Can.TType _ _ args) = concatMap collectTVars args
collectTVars (Can.TTuple a b rest) = concatMap collectTVars (a:b:rest)
collectTVars (Can.TRecord fields _) = concatMap (collectTVars . Can._fieldType) (Map.elems fields)
collectTVars _ = []

-- | Simple check: does the body match a parameter with list patterns (cons, list)?
bodyUsesList :: Can.Expr -> Bool
bodyUsesList (Ann.At _ e) = case e of
    Can.Case scrut branches ->
        any (\(Can.CaseBranch pat _) -> isListPat pat) branches
        || any (\(Can.CaseBranch _ body) -> bodyUsesList body) branches
    Can.Let _ body -> bodyUsesList body
    Can.LetRec _ body -> bodyUsesList body
    Can.LetDestruct _ _ body -> bodyUsesList body
    Can.If branches elseBranch -> any (\(_, t) -> bodyUsesList t) branches || bodyUsesList elseBranch
    _ -> False
  where
    isListPat (Ann.At _ p) = case p of
        Can.PCons _ _ -> True
        Can.PList _ -> True
        Can.PAlias pat _ -> isListPat pat
        _ -> False

-- | Does this top-level pattern match a string literal?
hasStrPat :: Can.Pattern -> Bool
hasStrPat (Ann.At _ p) = case p of
    Can.PStr _ -> True
    _ -> False

-- | Collect all (non-wildcard) variable names bound by a pattern.
-- For PCons head bindings these will be &T0; for tail bindings &[T0].
patBindingVars :: Can.Pattern -> [String]
patBindingVars (Ann.At _ pat) = case pat of
    Can.PVar n -> [n]
    Can.PCons a b -> patBindingVars a ++ patBindingVars b
    Can.PList items -> concatMap patBindingVars items
    Can.PAlias inner n -> n : patBindingVars inner
    Can.PTuple a b rest -> concatMap patBindingVars (a:b:rest)
    Can.PCtor{Can._p_args = args} -> concatMap (\(Can.PatternCtorArg _ _ p) -> patBindingVars p) args
    Can.PRecord fields -> fields
    _ -> []

-- | Known signatures for common Def functions (stdlib etc.), keyed by (module_prefix, name, arity)
knownDefSig :: String -> String -> Int -> Maybe ([String], String)
-- List module
knownDefSig p n a | "Sky_Core_List" `isPrefixOf` p = listSig n a
-- Maybe module
knownDefSig p n a | "Sky_Core_Maybe" `isPrefixOf` p = maybeSig n a
-- Error module
knownDefSig p n a | "Sky_Core_Error" `isPrefixOf` p = errorSig n a
knownDefSig p n a | "Sky_Core_Result" `isPrefixOf` p = resultSig n a
knownDefSig p n a | "Sky_Core_String" `isPrefixOf` p = stringSig n a
-- Main module helpers
knownDefSig _ _ _ = Nothing

listSig :: String -> Int -> Maybe ([String], String)
listSig "map" 2 = Just (["impl Fn(T0) -> T1 + Clone", "Vec<T0>"], "Vec<T1>")
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
maybeSig _ _ = Nothing

resultSig :: String -> Int -> Maybe ([String], String)
resultSig "map" 2 = Just (["impl Fn(T0) -> T1 + Clone", "SkyResult<SkyError, T0>"], "SkyResult<SkyError, T1>")
resultSig "andThen" 2 = Just (["impl Fn(T0) -> SkyResult<SkyError, T1> + Clone", "SkyResult<SkyError, T0>"], "SkyResult<SkyError, T1>")
resultSig "mapError" 2 = Just (["impl Fn(SkyError) -> String + Clone", "SkyResult<SkyError, T0>"], "SkyResult<String, T0>")
resultSig "withDefault" 2 = Just (["T0", "SkyResult<SkyError, T0>"], "T0")
resultSig "map2" 3 = Just (["impl Fn(T0, T1) -> T2 + Clone", "SkyResult<SkyError, T0>", "SkyResult<SkyError, T1>"], "SkyResult<SkyError, T2>")
resultSig "map3" 4 = Just (["impl Fn(T0, T1, T2) -> T3 + Clone", "SkyResult<SkyError, T0>", "SkyResult<SkyError, T1>", "SkyResult<SkyError, T2>"], "SkyResult<SkyError, T3>")
resultSig "map4" 5 = Just (["impl Fn(T0, T1, T2, T3) -> T4 + Clone", "SkyResult<SkyError, T0>", "SkyResult<SkyError, T1>", "SkyResult<SkyError, T2>", "SkyResult<SkyError, T3>"], "SkyResult<SkyError, T4>")
resultSig "map5" 6 = Just (["impl Fn(T0, T1, T2, T3, T4) -> T5 + Clone", "SkyResult<SkyError, T0>", "SkyResult<SkyError, T1>", "SkyResult<SkyError, T2>", "SkyResult<SkyError, T3>", "SkyResult<SkyError, T4>"], "SkyResult<SkyError, T5>")
resultSig "andMap" 2 = Just (["SkyResult<SkyError, T0>", "SkyResult<SkyError, impl Fn(T0) -> T1 + Clone>"], "SkyResult<SkyError, T1>")
resultSig "combine" 1 = Just (["Vec<SkyResult<SkyError, T0>>"], "SkyResult<SkyError, Vec<T0>>")
resultSig "traverse" 2 = Just (["impl Fn(T0) -> SkyResult<SkyError, T1> + Clone", "Vec<T0>"], "SkyResult<SkyError, Vec<T1>>")
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

defToRustItem :: EmitCtx -> String -> Can.Def -> RustItem
defToRustItem ctx modPrefix (Can.Def (Ann.At _ name) params body) = 
    let rustName = if name == "main" then "sky_main" else name
        n = length params
        (paramStrs, genVars) =
            -- Try solvedTypes FIRST (HM-inferred types, most accurate).
            -- Falls through to knownDefSig (stdlib overrides) then body analysis.
            let solvedParamTys = case Map.lookup name (ecSolvedTypes ctx) of
                    Just ty -> extractParamTypes ty
                    Nothing -> []
            -- Only use solved types when they're fully concrete (no TVars).
            -- Polymorphic functions still route through knownDefSig for
            -- proper generic bounds like `T0: Clone`.
            in if length solvedParamTys == length params
                  && all (not . hasTypeVars) solvedParamTys
               then -- Use solved types (all concrete, no TVars)
                    let rm = ecRecordMap ctx
                        pStrs = map (\(p, t) -> patternToRustParam p ++ ": " ++ typeToRustString rm t)
                                    (zip params solvedParamTys)
                   in (pStrs, "")
               else case knownDefSig modPrefix name n of
                   Just (paramTypes, retType) ->
                        let safeParams = map (\(p, t) -> patternToRustParam p ++ ": " ++ t) (zip params paramTypes)
                            tvars = sigTVars paramTypes retType
                            extraBound tv = if name == "member" && tv == "T0" then " + PartialEq" else ""
                            genList = map (\tv -> tv ++ ": Clone" ++ extraBound tv) tvars
                            gens = if null genList then "" else "<" ++ intercalate ", " genList ++ ">"
                       in (safeParams, gens)
                   Nothing ->
                       -- Fallback: body analysis
                       let counts = collectVarLocalsMulti body
                           paramNames = [ n | Ann.At _ (Can.PVar n) <- params ]
                           anyCloneNeeded = any (\n -> Map.lookup n counts >= Just 2) paramNames
                               || bodyUsesList body
                           useVec = bodyUsesList body
                           pStrs = map (\(i, p) ->
                               let tn = "T" ++ show i
                               in patternToRustParam p ++ ": " ++ (if useVec then "Vec<" ++ tn ++ ">" else "String")
                               ) (zip [0..] params)
                           genList = if anyCloneNeeded
                                     then map (\i -> "T" ++ show i ++ ": Clone") [0..length params - 1]
                                     else []
                           gs = if null genList then "" else "<" ++ intercalate ", " genList ++ ">"
                       in (pStrs, gs)
        retTy = case Map.lookup name (ecSolvedTypes ctx) of
                    Just ty ->
                        let ret = extractReturnType ty
                        in if not (hasTypeVars ret)
                           then typeToRustString (ecRecordMap ctx) ret
                            else case knownDefSig modPrefix name n of
                                Just (_, knownRetType) -> knownRetType
                                Nothing ->
                                    -- Return type has TVars: try constructor-shape inference (Q1a)
                                    let ctorTy = inferCtorReturnType (ecRecordMap ctx) (ecSolvedTypes ctx) body
                                    in if null ctorTy
                                       then -- Fallback: body inference for Task returns
                                            let bodyInner = taskExprInnerType (ecSolvedTypes ctx) body
                                            in if null bodyInner
                                               then case knownDefSig modPrefix name n of
                                                   Just (_, knownRetType2) -> knownRetType2
                                                   Nothing -> "()"
                                               else "SkyTask<" ++ bodyInner ++ ">"
                                       else ctorTy
                    Nothing ->
                         -- No solved type available — use knownDefSig, body inference,
                         -- or (for main) the hardcoded Task/unit convention.
                         let bodyInner = taskExprInnerType (ecSolvedTypes ctx) body
                         in if null bodyInner
                            then case knownDefSig modPrefix name n of
                                Just (_, knownRetType) -> knownRetType
                                Nothing -> if name == "main"
                                           then if ecUsesTaskRun ctx then "()" else "SkyTask<()>"
                                           else "()"
                            else "SkyTask<" ++ bodyInner ++ ">"
        -- Track multi-use variables in the function body so they get
        -- cloned at each function-call argument site (ownership safety).
        multiBody = collectVarLocalsMulti body
        multiVars = [ v | (v, c) <- Map.toList multiBody, c >= 2 ]
        -- Step 4: skip .clone() for params whose type is Rust Copy (i64, f64, bool, ...)
        paramNames = [ n | Ann.At _ (Can.PVar n) <- params ]
        paramTys = case Map.lookup name (ecSolvedTypes ctx) of
            Just ty -> extractParamTypes ty
            Nothing -> []
        copyVars = Set.fromList
            [ n | (n, t) <- zip paramNames paramTys
            , not (hasTypeVars t) && isCanTypeCopy t ]
        ctx' = ctx { ecCloneVars = Set.fromList multiVars
                   , ecCopyVars = copyVars }
        bodyStr = exprToRustString ctx' body
        -- S6: When the function returns SkyTask<T> but the body tail is a
        -- bare value (not already a Task expression), wrap in task_succeed({...}).
        -- Walk through let chains to find the tail expression, then check
        -- whether the tail is already a Task expression.
        bodyWrapped = if "SkyTask<" `isPrefixOf` retTy && needsTaskWrap (ecSolvedTypes ctx) body
                      then "task_succeed({ " ++ bodyStr ++ " })"
                      else bodyStr
     in RustFunction rustName genVars paramStrs retTy bodyWrapped
defToRustItem ctx _modPrefix (Can.TypedDef (Ann.At _ name) _ pats body retTy) = 
    let rm = ecRecordMap ctx
        rustName = if name == "main" then "sky_main" else name
        params = map (\(pat, ty) -> patternToRustParam pat ++ ": " ++ typeToRustString rm ty) pats
        ret = if name == "main" then "()" else typeToRustString rm retTy
        -- Collect type variable names from annotation types, emit as generic params
        allAnnotTys = map snd pats ++ [retTy | name /= "main"]
        tvarNames = nub [ v | t <- allAnnotTys, v <- collectTVars t ]
        genDecl = if null tvarNames then ""
                  else "<" ++ intercalate ", " (map (\v -> v ++ ": Clone + PartialEq + std::fmt::Debug") tvarNames) ++ ">"
        multiBody = collectVarLocalsMulti body
        multiVars = [ v | (v, c) <- Map.toList multiBody, c >= 2 ]
        ctx' = ctx { ecCloneVars = Set.fromList multiVars, ecCopyVars = ecCopyVars ctx }
    in RustFunction rustName genDecl params ret (exprToRustString ctx' body)
defToRustItem ctx modPrefix (Can.DestructDef pat expr) =
    let vars = intercalate "_" (patBindingVars pat)
        fnName = if null vars then "__destruct" else "__destruct_" ++ vars
    in RustFunction fnName "" [patternToRustParam pat] "()" (exprToRustString ctx expr)

-- | Lower a Sky return type that may contain TVars to a Rust type string,
-- generating fresh generic parameters for unresolved TVars.
returnTypeWithGenerics
    :: Map.Map String String         -- record map
    -> Can.Type                      -- Sky return type (may have TVars)
    -> Map.Map String Can.Type       -- solved types (for inference)
    -> (String, [String])            -- (Rust type, generic params to add)
returnTypeWithGenerics recMap ty solved = case ty of
    Can.TType _ "Task" [_e, a] ->
        let (innerStr, gens) = returnTypeWithGenerics recMap a solved
        in ("SkyTask<" ++ innerStr ++ ">", gens)
    Can.TType _ "Result" [e, a] ->
        let (errStr, gs1) = returnTypeWithGenerics recMap e solved
            (okStr,  gs2) = returnTypeWithGenerics recMap a solved
        in ("SkyResult<" ++ errStr ++ ", " ++ okStr ++ ">", gs1 ++ gs2)
    Can.TType _ "Maybe" [a] ->
        let (s, gs) = returnTypeWithGenerics recMap a solved
        in ("SkyMaybe<" ++ s ++ ">", gs)
    Can.TVar n ->
        let g = if "_" `isPrefixOf` n
                then "__T" ++ drop 1 n   -- private generic for Skolems
                else "T_" ++ n           -- user-facing generic
        in (g, [g])
    _ ->
        (typeToRustString recMap ty, [])

-- | Infer the return type of a function whose body is a constructor call
-- (Ok x, Err e, Just y, Nothing, ::, etc.) by inspecting the constructor
-- and the types of its arguments via solveArgType.
inferCtorReturnType :: Map.Map String String -> Map.Map String Can.Type -> Can.Expr -> String
inferCtorReturnType recMap solved (Ann.At _ expr) = case expr of
    Can.Call (Ann.At _ (Can.VarCtor _ _ tyName ctorName _)) args ->
        case (tyName, ctorName, args) of
            -- Result: Ok x / Err e
            ("Result", "Ok", [arg]) ->
                let okT = solveArgType solved arg
                in "SkyResult<SkyError, " ++ okT ++ ">"
            ("Result", "Err", [arg]) ->
                let errT = solveArgType solved arg
                in "SkyResult<" ++ errT ++ ", String>"
            -- Maybe: Just y / Nothing
            ("Maybe", "Just", [arg]) ->
                let valT = solveArgType solved arg
                in "SkyMaybe<" ++ valT ++ ">"
            ("Maybe", "Nothing", []) -> "SkyMaybe<String>"
            -- List: cons (::) / empty
            ("List", "::", [arg, _]) ->
                let elT = solveArgType solved arg
                in "Vec<" ++ elT ++ ">"
            ("List", "[]", []) -> "Vec<String>"
            _ -> ""
    -- For a plain local variable, look up its solved type
    Can.VarLocal name -> case Map.lookup name solved of
        Just ty -> typeToRustString recMap ty
        Nothing -> ""
    _ -> ""

-- | Is a Can.Type a Rust `Copy` type?  When true, the codegen should
-- skip `.clone()` even if the variable is used ≥ 2 times, because
-- `Copy` types are cheap to copy and Rust's borrow checker doesn't
-- require explicit `.clone()` for them.
isCanTypeCopy :: Can.Type -> Bool
isCanTypeCopy Can.TUnit                          = True
isCanTypeCopy (Can.TType _ "Int" [])             = True
isCanTypeCopy (Can.TType _ "Float" [])           = True
isCanTypeCopy (Can.TType _ "Bool" [])            = True
isCanTypeCopy (Can.TType _ "Char" [])            = True
isCanTypeCopy _                                   = False

-- | Walk through let chains to find the tail expression.
tailExpr :: Can.Expr -> Can.Expr
tailExpr (Ann.At _ (Can.Let _ b))         = tailExpr b
tailExpr (Ann.At _ (Can.LetRec _ b))      = tailExpr b
tailExpr (Ann.At _ (Can.LetDestruct _ _ b)) = tailExpr b
tailExpr e                                = e

-- | Does the body need a task_succeed(...) wrap? True when the tail
-- expression is a bare value (not already a Task expression).
-- Uses solved types to check if known bindings have Task type.
needsTaskWrap :: Map.Map String Can.Type -> Can.Expr -> Bool
needsTaskWrap solved body =
    case tailExpr body of
        Ann.At _ Can.Unit          -> True
        Ann.At _ (Can.Int _)       -> True
        Ann.At _ (Can.Float _)     -> True
        Ann.At _ (Can.Str _)       -> True
        Ann.At _ (Can.Chr _)       -> True
        tail                      -> not (isTaskExpr tail)
  where
    isTaskExpr e =
        -- Use taskExprInnerType: if it returns non-empty, e is a Task expression
        let inner = taskExprInnerType solved e
        in not (null inner)

-- | `skyModName` is the un-mangled Sky module name (dots preserved, e.g.
-- "Std.Decimal") used to look up the runtimeOpaqueTypes registry.
-- `modPrefix` is the mangled form (dots -> underscores) used in the
-- generated Rust type name.
unionsToRustTypes :: Map.Map String String -> String -> String -> Map.Map String Can.Union -> [RustTypeDef]
unionsToRustTypes recordMap skyModName modPrefix unions =
    map (\(name, u) -> unionToRustTypeDef recordMap skyModName modPrefix name u) (Map.toList unions)

unionToRustTypeDef :: Map.Map String String -> String -> String -> String -> Can.Union -> RustTypeDef
unionToRustTypeDef recordMap skyModName modPrefix typeName (Can.Union _ alts _ _) =
    let codegenName = toCamelCase (modPrefix ++ "_" ++ typeName)
    in case Map.lookup (skyModName, typeName) runtimeOpaqueTypes of
        -- Registry hit: emit a `pub use sky_runtime::X as <codegenName>;` alias.
        -- The runtime newtype IS the canonical representation; the Sky-side
        -- placeholder constructor (e.g. `Decimal__Internal Float`) is a
        -- phantom-shape that exists only so the Sky type has a slot.
        Just rustPath -> RPubUseAlias codegenName rustPath
        -- No registry entry: emit the regular enum/ADT (one constructor per alt).
        Nothing       -> REnumDef codegenName (map ctorToRust alts)
  where
    ctorToRust (Can.Ctor name _idx _arity argTypes) =
        (name, if null argTypes then Nothing
               else Just (intercalate ", " (map (typeToRustString recordMap) argTypes)))

aliasesToRustTypes :: Map.Map String String -> String -> Map.Map String Can.Alias -> [RustTypeDef]
aliasesToRustTypes recordMap modPrefix aliases = concatMap (\(name, alias) -> aliasToRustTypeDef recordMap modPrefix name alias) (Map.toList aliases)

-- | Sort record fields by their declaration index (_fieldIndex)
sortFieldsByIndex :: [(String, Can.FieldType)] -> [(String, Can.FieldType)]
sortFieldsByIndex = sortBy (\(_, Can.FieldType i _) (_, Can.FieldType j _) -> compare i j)

aliasToRustTypeDef :: Map.Map String String -> String -> String -> Can.Alias -> [RustTypeDef]
aliasToRustTypeDef recordMap modPrefix name (Can.Alias _vars ty) = case ty of
    Can.TRecord fields _ -> 
        let sortedFields = sortFieldsByIndex (Map.toList fields)
        in [RStructDef (toCamelCase (modPrefix ++ "_" ++ name)) "" (map (\(n, Can.FieldType _ ft) -> (n, typeToRustString recordMap ft)) sortedFields)]
    _ -> 
        [RAliasDef (toCamelCase (modPrefix ++ "_" ++ name)) (typeToRustString recordMap ty)]

typeToRustString :: Map.Map String String -> Can.Type -> String
typeToRustString recordMap t = case t of
    Can.TType modName "Int" [] -> "i64"
    Can.TType _ "Float" [] -> "f64"
    Can.TType _ "Bool" [] -> "bool"
    Can.TType _ "Char" [] -> "char"
    Can.TType _ "String" [] -> "String"
    Can.TType _ "Task" [_, a] -> "SkyTask<" ++ typeToRustString recordMap a ++ ">"
    Can.TUnit -> "()"
    Can.TType _ "List" [a] -> "Vec<" ++ typeToRustString recordMap a ++ ">"
    Can.TType _ "Maybe" [a] -> "SkyMaybe<" ++ typeToRustString recordMap a ++ ">"
    Can.TType _ "Dict" [k, v] -> "HashMap<" ++ typeToRustString recordMap k ++ ", " ++ typeToRustString recordMap v ++ ">"
    Can.TType _ "Result" [e, a] -> "SkyResult<" ++ typeToRustString recordMap e ++ ", " ++ typeToRustString recordMap a ++ ">"
    Can.TType _ "Error" [] -> "SkyError"
    Can.TRecord fields _ ->
        let key = intercalate "," (Map.keys fields)
            fieldSet = Set.fromList (Map.keys fields)
            -- When exact key misses, find the alias with the FEWEST extra
            -- fields that is a superset of the TRecord's fields.
            -- HM's row polymorphism narrows inferred record types to only
            -- the accessed fields — we widen back to the full alias.
            bestMatch = foldr (\(k, name) best ->
                let kSet = Set.fromList (words (map (\c -> if c == ',' then ' ' else c) k))
                    extras = Set.size kSet - Set.size fieldSet
                in if fieldSet `Set.isSubsetOf` kSet && extras >= 0
                   then case best of
                        Nothing -> Just (extras, name)
                        Just (e, _) | extras < e -> Just (extras, name)
                        _ -> best
                   else best
                ) Nothing (Map.toList recordMap)
            structName = case bestMatch of
                Just (_, n) -> n
                Nothing -> "String"
            -- Anonymous record structs have generic type params (T0..Tn).
            -- Fill them from the TRecord's actual field types so references
            -- like `AnonXxx<String, i64, bool>` compile correctly.
            gens = if "Anon" `isPrefixOf` structName
                   then let sorted = sortFieldsByIndex (Map.toList fields)
                        in "<" ++ intercalate ", " [typeToRustString recordMap (Can._fieldType ft) | (_, ft) <- sorted] ++ ">"
                   else ""
        in structName ++ gens
    Can.TTuple a b rest -> "(" ++ intercalate ", " (map (typeToRustString recordMap) (a:b:rest)) ++ ")"
    Can.TVar v -> v
    Can.TType modName name [] ->
        let modStr = ModuleName._name modName
            modPrefix = if null modStr then "" else map (\c -> if c == '.' then '_' else c) modStr ++ "_"
        in toCamelCase (modPrefix ++ name)
    Can.TType modName name args ->
        let modStr = ModuleName._name modName
            modPrefix = if null modStr then "" else map (\c -> if c == '.' then '_' else c) modStr ++ "_"
        in toCamelCase (modPrefix ++ name) ++ "<" ++ intercalate ", " (map (typeToRustString recordMap) args) ++ ">"
    Can.TLambda a b -> "fn(" ++ typeToRustString recordMap a ++ ") -> " ++ typeToRustString recordMap b
    Can.TAlias modName name _pairs _inner ->
        let modStr = ModuleName._name modName
            modPrefix = if null modStr then "" else map (\c -> if c == '.' then '_' else c) modStr ++ "_"
        in toCamelCase (modPrefix ++ name)
    _ -> "String"

rustSafeIdent :: String -> String
rustSafeIdent "fn" = "r#fn"
rustSafeIdent "match" = "r#match"
rustSafeIdent "let" = "r#let"
rustSafeIdent "mod" = "r#mod"
rustSafeIdent "type" = "r#type"
rustSafeIdent "ref" = "r#ref"
rustSafeIdent "self" = "r#self"
rustSafeIdent "Self" = "r#Self"
rustSafeIdent "static" = "r#static"
rustSafeIdent "mut" = "r#mut"
rustSafeIdent "return" = "r#return"
rustSafeIdent "while" = "r#while"
rustSafeIdent "for" = "r#for"
rustSafeIdent "in" = "r#in"
rustSafeIdent "if" = "r#if"
rustSafeIdent "else" = "r#else"
rustSafeIdent "loop" = "r#loop"
rustSafeIdent "where" = "r#where"
rustSafeIdent "async" = "r#async"
rustSafeIdent "await" = "r#await"
rustSafeIdent "dyn" = "r#dyn"
rustSafeIdent "impl" = "r#impl"
rustSafeIdent "trait" = "r#trait"
rustSafeIdent "enum" = "r#enum"
rustSafeIdent "struct" = "r#struct"
rustSafeIdent "union" = "r#union"
rustSafeIdent "use" = "r#use"
rustSafeIdent "crate" = "r#crate"
rustSafeIdent "super" = "r#super"
rustSafeIdent "pub" = "r#pub"
rustSafeIdent "move" = "r#move"
rustSafeIdent name = name

isWildcard :: Can.Pattern -> Bool
isWildcard (Ann.At _ Can.PAnything) = True
isWildcard _ = False

patternToRustParam :: Can.Pattern -> String
patternToRustParam (Ann.At _ pat) = case pat of
    Can.PVar n -> rustSafeIdent n
    Can.PAnything -> "_"
    Can.PTuple a b rest ->
        "(" ++ intercalate ", " (map patternToRustParam (a:b:rest)) ++ ")"
    _ -> "_"

-- | Walk an expression and collect VarLocal names, counting occurrences.
-- Used to decide which variables need .clone() (those used ≥ 2 times).
-- | Substitute every VarLocal matching a name with an inline string
-- (e.g. `vec![...]`).  Handles common expression forms.  The println
-- special case (Log.println → log_info) is mirrored from exprToRustInner.
substVar :: EmitCtx -> String -> String -> Can.Expr -> String
substVar ctx name inline = go
  where
    go e@(Ann.At _ expr) = case expr of
        Can.VarLocal n | n == name -> inline
        Can.VarLocal n -> rustSafeIdent n ++ if n `Set.member` ecCloneVars ctx && not (n `Set.member` ecCopyVars ctx) then ".clone()" else ""
        Can.VarTopLevel mod n ->
            let modName = ModuleName._name mod
                modPrefix = map (\c -> if c == '.' then '_' else c) modName
                fnName = toSnakeCase (modPrefix ++ "_" ++ n)
                -- Check kernel aliases so VarTopLevel routes through kernel dispatch
                kernelName = kernelToRust modName n
            in if fnName /= kernelName && not ("ffi_kernel" `isPrefixOf` kernelName)
               then kernelName
               else case Map.lookup (modName, n) (ecKernelAliases ctx) of
                    Just (kMod, kFn) -> kernelToRust kMod kFn
                    Nothing -> if Set.member (modPrefix, n) (ecZeroArgDefs ctx) then fnName ++ "()" else fnName
        Can.VarKernel mod n ->
            let fnName = kernelToRust mod n
            in if Set.member (mod, n) (ecZeroArgDefs ctx) then fnName ++ "()" else fnName
        Can.VarCtor _ mn tn cn _ -> kernelCtorToRust mn tn cn
        Can.Chr [c] -> rustCharLit c
        Can.Chr s -> rustStringLit s  -- multi-char or empty: fall back to string
        Can.Str s -> rustStringLit s ++ ".to_string()"
        Can.Int i -> show i
        Can.Float f -> show f
        Can.Unit -> "()"
        Can.List es -> "vec![" ++ intercalate ", " (map go es) ++ "]"
        Can.Negate e -> "-" ++ go e
        Can.Lambda params body ->
            "|" ++ intercalate ", " (map patternToRustParam params) ++ "| { " ++ go body ++ " }"
        Can.Call fn args ->
            let fs = go fn
                isPrintln = "println" `isSuffixOf` fs
            in if isPrintln
               then "log_info(" ++ intercalate " ++ \" \" ++ " (map go args) ++ ")"
               else let noClone = case fn of
                            Ann.At _ (Can.VarKernel _ n2) -> n2 == "run" || n2 == "sequence" || n2 == "parallel"
                            _ -> False
                        as = map (\a -> case a of
                             Ann.At _ (Can.VarLocal n2) | n2 == name -> inline
                             Ann.At _ (Can.VarLocal n2) | noClone -> rustSafeIdent n2
                             Ann.At _ (Can.VarLocal n2) ->
                                 (let needClone = Set.member n2 (ecCloneVars ctx) && not (Set.member n2 (ecCopyVars ctx))
                                  in if needClone then rustSafeIdent n2 ++ ".clone()" else rustSafeIdent n2)
                             _ -> go a) args
                    in fs ++ "(" ++ intercalate ", " as ++ ")"
        Can.Let def body -> goDef def ++ go body
          where
            goDef (Can.Def (Ann.At _ n) [] dBody) = "let " ++ n ++ " = " ++ go dBody ++ "; "
            goDef (Can.Def (Ann.At _ n) ps dBody) = "let " ++ n ++ " = |" ++ intercalate ", " (map patternToRustParam ps) ++ "| { " ++ go dBody ++ " }; "
            goDef _ = error "Builder.Rust.substVar.goDef: unsupported Can.Def variant"
        Can.LetRec defs body ->
            let strs = map (\(Can.Def (Ann.At _ n) ps d) -> n ++ " = |" ++ intercalate ", " (map patternToRustParam ps) ++ "| { " ++ go d ++ " }") defs
            in "let mut " ++ intercalate "; let mut " strs ++ "; " ++ go body
        Can.LetDestruct pat e0 body ->
            "let " ++ patternToMatchString (ecRecordMap ctx) pat ++ " = " ++ go e0 ++ "; " ++ go body
        Can.Case scrut branches ->
            "match " ++ go scrut ++ " { " ++ intercalate ", " (map (\(Can.CaseBranch p b) -> patternToMatchString (ecRecordMap ctx) p ++ " => " ++ go b) branches) ++ " }"
        Can.If [] elseExpr -> go elseExpr
        Can.If ((c,t):rest) elseExpr ->
            "if " ++ go c ++ " { " ++ go t ++ " }"
            ++ concatMap (\(c2,t2) -> " else if " ++ go c2 ++ " { " ++ go t2 ++ " }") rest
            ++ " else { " ++ go elseExpr ++ " }"
        Can.Binop op _ _ _ a b
            | op == "|>" -> go b ++ "(" ++ go a ++ ")"
            | op == "<|" -> go a ++ "(" ++ go b ++ ")"
            | op == "::" -> "sky_list_cons(" ++ go a ++ ", " ++ go b ++ ")"
            | op == "++" -> "format!(\"{}{}\", " ++ go a ++ ", " ++ go b ++ ")"
            | otherwise -> "(" ++ go a ++ " " ++ binopToRust op ++ " " ++ go b ++ ")"
        -- Uncommon expression forms — fall back to normal emission
        Can.Record _ -> exprToRustString ctx e
        Can.Tuple _ _ _ -> exprToRustString ctx e
        Can.Access _ _ -> exprToRustString ctx e
        Can.Accessor _ -> exprToRustString ctx e
        Can.Update _ _ _ -> exprToRustString ctx e

collectVarLocalsMulti :: Can.Expr -> Map.Map String Int
collectVarLocalsMulti = go Set.empty
  where
    go bound (Ann.At _ expr) = case expr of
        Can.VarLocal n | n `Set.notMember` bound -> Map.singleton n 1
        Can.VarLocal _ -> Map.empty
        Can.Call fn args -> Map.unionsWith (+) (go bound fn : map (go bound) args)
        Can.Lambda params body ->
            let bound' = foldl (\s p -> foldr Set.insert s (patBindingVars p)) bound params
            in go bound' body
        Can.Let (Can.Def _ _ defBody) body ->
            Map.unionWith (+) (go bound defBody) (go bound body)
        Can.LetRec defs body ->
            let goDefs = foldl (\a (Can.Def _ _ d) -> Map.unionWith (+) a (go bound d)) Map.empty defs
            in Map.unionWith (+) (go bound body) goDefs
        Can.LetDestruct pat expr body ->
            Map.unionWith (+) (go bound expr) (go bound body)
        Can.Case _ branches -> foldl (\a (Can.CaseBranch _ b) ->
            Map.unionWith (+) a (go bound b)) Map.empty branches
        Can.If branches elseBranch ->
            foldl (\a (c, t) -> Map.unionWith (+) a (Map.unionWith (+) (go bound c) (go bound t))) (go bound elseBranch) branches
        Can.Binop _ _ _ _ a b -> Map.unionWith (+) (go bound a) (go bound b)
        Can.Access r _ -> go bound r
        Can.Update _ r updates -> Map.unionWith (+) (go bound r) (foldl (\a (_, Can.FieldUpdate _ e) -> Map.unionWith (+) a (go bound e)) Map.empty (Map.toList updates))
        Can.Record fields -> foldl (\a (_, v) -> Map.unionWith (+) a (go bound v)) Map.empty (Map.toList fields)
        Can.List es -> foldl (\a e -> Map.unionWith (+) a (go bound e)) Map.empty es
        Can.Tuple a b rest -> foldl (\a e -> Map.unionWith (+) a (go bound e)) Map.empty (a:b:rest)
        Can.Negate e -> go bound e
        Can.Accessor _ -> Map.empty
        Can.VarTopLevel _ _ -> Map.empty
        Can.VarKernel _ _ -> Map.empty
        Can.VarCtor _ _ _ _ _ -> Map.empty
        Can.Chr _ -> Map.empty
        Can.Str _ -> Map.empty
        Can.Int _ -> Map.empty
        Can.Float _ -> Map.empty
        Can.Unit -> Map.empty

-- | Walk an expression and collect VarLocal names that refer to variables
-- from ENCLOSING scopes (not bound within the expression itself).
-- Used to insert .clone() calls for ownership-safe closure capture.
collectVarLocals :: Can.Expr -> Set.Set String
collectVarLocals = go Set.empty
  where
    go :: Set.Set String -> Can.Expr -> Set.Set String
    go bound (Ann.At _ expr) = case expr of
        Can.VarLocal n | n `Set.notMember` bound -> Set.singleton n
        Can.VarLocal _ -> Set.empty
        Can.Call fn args -> foldl (\a e -> Set.union a (go bound e)) (go bound fn) args
        Can.Lambda params body ->
            let bound' = foldl (\s p -> foldr Set.insert s (patBindingVars p)) bound params
            in go bound' body
        Can.Let (Can.Def (Ann.At _ name) _ defBody) body ->
            let bound' = Set.insert name bound
            in Set.union (go bound' defBody) (go bound' body)
        Can.LetRec defs body ->
            let bound' = foldl (\s (Can.Def (Ann.At _ n) _ _) -> Set.insert n s) bound defs
                goDefs = foldl (\a (Can.Def _ _ d) -> Set.union a (go bound' d)) Set.empty defs
            in Set.union (go bound' body) goDefs
        Can.LetDestruct pat expr body ->
            let bound' = foldr Set.insert bound (patBindingVars pat)
            in Set.union (go bound expr) (go bound' body)
        Can.Case _ branches -> foldl (\a (Can.CaseBranch pat b) ->
            let bound' = foldr Set.insert bound (patBindingVars pat)
            in Set.union a (go bound' b)) Set.empty branches
        Can.If branches elseBranch ->
            foldl (\a (c, t) -> Set.union a (Set.union (go bound c) (go bound t))) (go bound elseBranch) branches
        Can.Binop _ _ _ _ a b -> Set.union (go bound a) (go bound b)
        Can.Access r _ -> go bound r
        Can.Update _ r updates -> Set.union (go bound r) (foldl (\a (_, Can.FieldUpdate _ e) -> Set.union a (go bound e)) Set.empty (Map.toList updates))
        Can.Record fields -> foldl (\a (_, v) -> Set.union a (go bound v)) Set.empty (Map.toList fields)
        Can.List es -> foldl (\a e -> Set.union a (go bound e)) Set.empty es
        Can.Tuple a b rest -> foldl (\a e -> Set.union a (go bound e)) Set.empty (a:b:rest)
        Can.Negate e -> go bound e
        Can.Accessor _ -> Set.empty
        Can.VarTopLevel _ _ -> Set.empty
        Can.VarKernel _ _ -> Set.empty
        Can.VarCtor _ _ _ _ _ -> Set.empty
        Can.Chr _ -> Set.empty
        Can.Str _ -> Set.empty
        Can.Int _ -> Set.empty
        Can.Float _ -> Set.empty
        Can.Unit -> Set.empty

-- | Helper: render a single function-call argument string, handling
-- lambda capture cloning and VarLocal ownership.
-- Clones every VarLocal argument by default (most Sky types implement Clone).
-- Exceptions: Task.run (Pin<Box<dyn Future>> which is not Clone).
argToRustString :: EmitCtx -> Bool -> Can.Expr -> String
argToRustString ctx noCloneFn (Ann.At _ a) = case a of
    Can.Lambda ps body ->
        let paramNames = Set.fromList (concatMap patBindingVars ps)
            captured = Set.toList (Set.difference (collectVarLocals body) paramNames)
            clones = concatMap (\v -> "let " ++ v ++ " = " ++ v ++ ".clone(); ") captured
            innerCounts = collectVarLocalsMulti body
            innerMulti = [ v | (v, c) <- Map.toList innerCounts, c >= 2 ]
            ctx' = ctx { ecCloneVars = Set.fromList innerMulti, ecCopyVars = ecCopyVars ctx }
            annot = case ecPipeInnerType ctx of
                Just t | length ps == 1 -> ": " ++ t
                _ -> ""
            psStr = intercalate ", " (map (\p -> patternToRustParam p ++ annot) ps)
            retAnnot = case ecPipeInnerType ctx of
                Just t -> " -> SkyTask<" ++ t ++ ">"
                Nothing -> ""
            hasTaskRet = case ecPipeInnerType ctx of
                Just _ -> True
                Nothing -> False
            closure = "move |" ++ psStr ++ "|" ++ retAnnot ++ " { " ++ exprToRustString ctx' body ++ " }"
        in if not hasTaskRet && null captured
           then "move |" ++ psStr ++ "| { " ++ exprToRustString ctx' body ++ " }"
           else if null captured
                then closure
                else "{ " ++ clones ++ closure ++ " }"
    Can.VarLocal n ->
        let needsClone = (not noCloneFn) && (n `Set.member` ecCloneVars ctx)
                         && not (n `Set.member` ecCopyVars ctx)
        in if needsClone then rustSafeIdent n ++ ".clone()" else rustSafeIdent n
    _ -> exprToRustString ctx (Ann.At Ann.one a)

-- | Emit a Rust string literal from a Haskell string.
-- Handles non-ASCII characters via \\u{NNNN} escapes (Rust uses hex, not
-- Haskell's decimal \\NNN).  Inline UTF-8 for ASCII-safe chars.
rustStringLit :: String -> String
rustStringLit s = "\"" ++ concatMap escapeChar s ++ "\""
  where
    escapeChar '\"' = "\\\""
    escapeChar '\\' = "\\\\"
    escapeChar '\n' = "\\n"
    escapeChar '\t' = "\\t"
    escapeChar '\r' = "\\r"
    escapeChar c
        | c < ' ' || c == '\x7f' = "\\u{" ++ showHex (fromEnum c) "}"
        | c > '\x7f'             = "\\u{" ++ showHex (fromEnum c) "}"
        | otherwise              = [c]

-- | Emit a Rust char literal, using \\u{NNNN} for non-ASCII.
rustCharLit :: Char -> String
rustCharLit c
    | c > '\x7f' = "'\\u{" ++ showHex (fromEnum c) "}'"
    | c == '\''  = "'\\''"
    | c == '\\'  = "'\\\\'"
    | otherwise  = "'" ++ [c] ++ "'"

exprToRustString :: EmitCtx -> Can.Expr -> String
exprToRustString ctx (Ann.At _ expr) = exprToRustInner ctx expr

-- | Does a closure pattern discard its argument (wildcard / `_`-prefixed)?
isWildcardPat :: Can.Pattern -> Bool
isWildcardPat (Ann.At _ Can.PAnything) = True
isWildcardPat (Ann.At _ (Can.PVar n)) | "_" `isPrefixOf` n = True
isWildcardPat _ = False

-- | Does a closure argument discard its argument entirely?
isWildcardClosure :: Can.Expr -> Bool
isWildcardClosure (Ann.At _ (Can.Lambda [pat] _)) = isWildcardPat pat
isWildcardClosure _ = False

-- | When a Task combinator's closure argument is a wildcard and the task
-- argument has an unconstrained success type, emit the task call with a
-- `::<_, ()>` turbofish so Rust can infer the success type.
pinTaskCall :: EmitCtx -> String -> [Can.Expr] -> Map.Map String Can.Type -> Maybe String
pinTaskCall ctx nameStr (closeExpr : taskExpr : rest) solved
    | isWildcardClosure closeExpr
    , null (taskExprInnerType solved taskExpr) =
        let closeStr = exprToRustString ctx closeExpr
            taskStr  = emitPinnedTask ctx solved taskExpr
            restStrs = map (exprToRustString ctx) rest
        in Just $ nameStr ++ "(" ++ intercalate ", " (closeStr : taskStr : restStrs) ++ ")"
    | otherwise = Nothing
pinTaskCall _ _ _ _ = Nothing

emitPinnedTask :: EmitCtx -> Map.Map String Can.Type -> Can.Expr -> String
emitPinnedTask ctx solved (Ann.At _ (Can.Call fnExpr taskArgs)) =
    let fnStr = exprToRustString ctx fnExpr
        argStrs = map (exprToRustString ctx) taskArgs
    in fnStr ++ "::<_, ()>(" ++ intercalate ", " argStrs ++ ")"
emitPinnedTask ctx _ other = exprToRustString ctx other  -- fallback: no pin

-- | Split a Sky kernel-name like "Decimal_fromInt" into ("Decimal", "fromInt").
-- The FIRST underscore is the module/fn boundary; subsequent underscores
-- stay in the function name ("Decimal_toStringFixed" -> ("Decimal", "toStringFixed")).
-- Used by the Ffi.callPure peephole to feed kernelToRust.
splitKernelName :: String -> (String, String)
splitKernelName s = case break (== '_') s of
    (m, '_' : f) -> (m, f)
    (m, "")      -> (m, "")  -- malformed; kernelToRust returns the snake-cased default

-- | Argument emission inside a matched Ffi.callPure peephole.
-- `Ffi.toAny x` collapses to bare `x` — the value retains its concrete Rust
-- type. Everything else routes to the standard expression emit.
peepholeArg :: EmitCtx -> Can.Expr -> String
peepholeArg ctx (Ann.At _ (Can.Call (Ann.At _ (Can.VarKernel "Ffi" "toAny")) [inner])) =
    exprToRustString ctx inner
peepholeArg ctx e = exprToRustString ctx e

exprToRustInner :: EmitCtx -> Can.Expr_ -> String
exprToRustInner ctx e = case e of
    Can.VarLocal name -> rustSafeIdent name ++ if name `Set.member` ecCloneVars ctx && not (name `Set.member` ecCopyVars ctx) then ".clone()" else ""
    Can.VarTopLevel mod name ->
        let modName = ModuleName._name mod
            modPrefix = map (\c -> if c == '.' then '_' else c) modName
            fnName = toSnakeCase (modPrefix ++ "_" ++ name)
            -- Check kernelToRust first (direct kernel dispatch)
            kernelName = kernelToRust modName name
        in if fnName /= kernelName && not ("ffi_kernel" `isPrefixOf` kernelName)
           then kernelName
           else -- Check Stage-4 alias table: some VarTopLevel bindings are
                -- Ffi.kernel aliases that should route through kernel dispatch.
                case Map.lookup (modName, name) (ecKernelAliases ctx) of
                    Just (kMod, kFn) -> kernelToRust kMod kFn
                    Nothing ->
                        if Set.member (modPrefix, name) (ecZeroArgDefs ctx) then fnName ++ "()" else fnName
    Can.VarKernel mod name ->
        let fnName = kernelToRust mod name
        in if mod == "Basics" && name == "not" then "!"
           else if Set.member (mod, name) (ecZeroArgDefs ctx) then fnName ++ "()" else fnName
    Can.VarCtor _ modName typeName ctorName _ -> kernelCtorToRust modName typeName ctorName
    Can.Chr [c] -> rustCharLit c
    Can.Chr s -> rustStringLit s
    Can.Str s -> rustStringLit s ++ ".to_string()"
    Can.Int i -> show i
    Can.Float f -> show f
    Can.List es -> "vec![" ++ intercalate ", " (map (exprToRustString ctx) es) ++ "]"
    Can.Negate e -> "-" ++ exprToRustString ctx e
    Can.Binop op _ _ _ a b 
        | op == "|>" -> case b of
            Ann.At _ (Can.Call fn callArgs) ->
                let dummySpan = Ann.Region (Ann.Position 1 1) (Ann.Position 1 1)
                in exprToRustString ctx (Ann.At dummySpan (Can.Call fn (callArgs ++ [a])))
            _ ->
                let inner = taskExprInnerType (ecSolvedTypes ctx) a
                    ctx' = ctx { ecPipeInnerType = if null inner then Nothing else Just inner }
                in exprToRustString ctx' b ++ "(" ++ exprToRustString ctx' a ++ ")"
        | op == "<|" -> case a of
            Ann.At _ (Can.Call fn callArgs) ->
                let dummySpan = Ann.Region (Ann.Position 1 1) (Ann.Position 1 1)
                in exprToRustString ctx (Ann.At dummySpan (Can.Call fn (callArgs ++ [b])))
            _ ->
                exprToRustString ctx a ++ "(" ++ exprToRustString ctx b ++ ")"
        | op == "::" -> "sky_list_cons(" ++ exprToRustString ctx a ++ ", " ++ exprToRustString ctx b ++ ")"
        | op == "++" -> "format!(\"{}{}\", " ++ exprToRustString ctx a ++ ", " ++ exprToRustString ctx b ++ ")"
        | otherwise -> 
            "(" ++ exprToRustString ctx a ++ " " ++ binopToRust op ++ " " ++ exprToRustString ctx b ++ ")"
    Can.Lambda params body -> 
        let counts = collectVarLocalsMulti body
            innerMulti = [ v | (v, c) <- Map.toList counts, c >= 2 ]
            ctx' = ctx { ecCloneVars = Set.fromList innerMulti, ecCopyVars = ecCopyVars ctx }
        in "|" ++ intercalate ", " (map patternToRustParam params) ++ "| { " ++ exprToRustString ctx' body ++ " }"
    -- Ffi.callPure peephole — literal kernel name + literal args list -> direct
    -- kernel call. Splits "Decimal_fromInt" -> ("Decimal", "fromInt"), looks up
    -- kernelToRust, emits the resolved kernel name with the args spliced inline.
    -- Ffi.toAny inside a matched args list collapses to identity (see peepholeArg).
    -- The deprecated Ffi.call alias gets the same treatment.
    -- Non-matched shapes (variable kernel name, non-literal args list) fall
    -- through to the existing Can.Call arm, which routes to the polyfill via
    -- kernelToRust's "Ffi.callPure" -> "ffi_call_pure_polyfill" arm.
    Can.Call (Ann.At _ (Can.VarKernel "Ffi" fnName))
             [Ann.At _ (Can.Str kernelName), Ann.At _ (Can.List argExprs)]
        | fnName == "callPure" || fnName == "call" ->
            let (skyMod, skyFn) = splitKernelName kernelName
                rustFn = kernelToRust skyMod skyFn
                args = map (peepholeArg ctx) argExprs
            in rustFn ++ "(" ++ intercalate ", " args ++ ")"
    -- Standalone Ffi.toAny peephole — outside a matched Ffi.callPure args list,
    -- Ffi.toAny x collapses to bare x. The value retains its concrete Rust type;
    -- the toAny call is dropped entirely (kernelToRust's polyfill arm is a safety
    -- net for indirect references, but most call sites match here).
    Can.Call (Ann.At _ (Can.VarKernel "Ffi" "toAny")) [inner] ->
        exprToRustString ctx inner
    Can.Call fn args ->
        let calleeName = exprToRustString ctx fn
            succeedArity = case fn of
                Ann.At _ (Can.VarKernel _ name) | name == "succeed" && not (null args) ->
                    case head args of
                        Ann.At _ (Can.Lambda ps _) | length ps > 1 -> Just (length ps)
                        Ann.At _ (Can.VarTopLevel _ fnName) ->
                            case Map.lookup fnName (ecSolvedTypes ctx) of
                                Just ty | let n = length (extractParamTypes ty), n > 1 -> Just n
                                _ -> case Map.lookup fnName (ecCtorArity ctx) of
                                    Just n | n > 1 -> Just n
                                    _ -> Nothing
                        _ -> Nothing
                _ -> Nothing
        in case succeedArity of
            Just n ->
                let [arg] = args
                in case arg of
                    Ann.At _ (Can.Lambda params body) ->
                        let counts = collectVarLocalsMulti body
                            innerMulti = [v | (v, c) <- Map.toList counts, c >= 2]
                            ctx' = ctx { ecCloneVars = Set.fromList innerMulti, ecCopyVars = ecCopyVars ctx }
                            psStr = intercalate ", " (map patternToRustParam params)
                        in calleeName ++ "(curry" ++ show n ++ "(|" ++ psStr ++ "| { " ++ exprToRustString ctx' body ++ " }))"
                    _ ->
                        calleeName ++ "(curry" ++ show n ++ "(" ++ exprToRustString ctx arg ++ "))"
            Nothing -> case calleeName of
                fn | "println" `isSuffixOf` fn ->
                    "log_info(" ++ intercalate " ++ \" \" ++ " (map (\a -> exprToRustString ctx a) args) ++ ")"
                cname | cname `elem` ["task_and_then", "task_on_error", "task_map_error"] ->
                    case pinTaskCall ctx cname args (ecSolvedTypes ctx) of
                        Just pinned -> pinned
                        Nothing -> emitDefaultCall ctx fn calleeName args
                _ -> emitDefaultCall ctx fn calleeName args
    Can.If [] elseBranch ->
        exprToRustString ctx elseBranch
    Can.If ((firstCond, firstBody):rest) elseBranch ->
        "if " ++ exprToRustString ctx firstCond ++ " { " ++ exprToRustString ctx firstBody ++ " }"
        ++ concatMap (\(c, t) -> " else if " ++ exprToRustString ctx c ++ " { " ++ exprToRustString ctx t ++ " }") rest
        ++ " else { " ++ exprToRustString ctx elseBranch ++ " }"
    Can.Let def body ->
        case def of
            Can.Def (Ann.At _ name) [] (Ann.At _ (Can.List items))
                | Just n <- Map.lookup name (collectVarLocalsMulti body), n >= 2 ->
                    let inline = "vec![" ++ intercalate ", " (map (exprToRustString ctx) items) ++ "]"
                    in substVar ctx name inline body
            _ -> "let " ++ defToRustString ctx def ++ "; " ++ exprToRustString ctx body
    Can.LetRec defs body ->
        "let mut " ++ intercalate "; let mut " (map (defToRustString ctx) defs) ++ "; " ++ exprToRustString ctx body
    Can.LetDestruct pat expr body ->
        -- Clone captured locals used ≥ 2 times so each use gets its own copy.
        let counts = collectVarLocalsMulti expr
            multi = [ v | (v, c) <- Map.toList counts, c >= 2 ]
            clones = concatMap (\v -> "let " ++ v ++ " = " ++ v ++ ".clone(); ") multi
            hasClone = not (null multi)
            exprStr = case expr of
                Ann.At _ (Can.Lambda ps lambdaBody)
                    | null ps || all isWildcard ps ->
                        let inner = "(move || { " ++ exprToRustString ctx lambdaBody ++ " })()"
                        in if not hasClone then inner else "{ " ++ clones ++ inner ++ " }"
                Ann.At _ (Can.Lambda ps lambdaBody) ->
                    let paramNames = Set.fromList [ n | Ann.At _ p <- ps, let n = case p of Can.PVar s -> s; _ -> "_" ]
                        innerCapt = Set.toList (Set.difference (collectVarLocals lambdaBody) paramNames)
                        innerClones = concatMap (\v -> "let " ++ v ++ " = " ++ v ++ ".clone(); ") innerCapt
                        psStr = intercalate ", " (map patternToRustParam ps)
                        inner = "move |" ++ psStr ++ "| { " ++ exprToRustString ctx lambdaBody ++ " }"
                    in if null innerCapt && not hasClone then inner
                       else "{ " ++ clones ++ innerClones ++ inner ++ " }"
                _ -> if not hasClone then exprToRustString ctx expr
                     else "{ " ++ clones ++ exprToRustString ctx expr ++ " }"
        in "let " ++ patternToMatchString (ecRecordMap ctx) pat ++ " = " ++ exprStr ++ "; " ++ exprToRustString ctx body
    Can.Case scrut branches ->
        let scrutStr = exprToRustString ctx scrut
            -- Detect slice patterns → wrap with .as_slice()
            hasCons = any (\(Can.CaseBranch pat _) -> hasConsP pat) branches
            -- Detect string literal patterns → wrap with .as_str() so &str patterns compile
            hasStr  = any (\(Can.CaseBranch pat _) -> hasStrPat pat) branches
            wrapped = if hasCons then "(" ++ scrutStr ++ ").as_slice()"
                      else if hasStr then scrutStr ++ ".as_str()"
                      else scrutStr
        in "match " ++ wrapped ++ " { " ++
        intercalate ", " (map (branchToRustString ctx) branches) ++ " }"
      where
        hasConsP (Ann.At _ p) = case p of
            Can.PCons _ _ -> True
            Can.PList _ -> True
            Can.PAlias pat _ -> hasConsP pat
            _ -> False
    Can.Accessor field -> "|_record| _record." ++ field
    Can.Access record (Ann.At _ field) -> 
        exprToRustString ctx record ++ "." ++ field
    Can.Update (Ann.At _ _field) record updates ->
        let sorted = sortBy (\(_, Can.FieldUpdate r1 _) (_, Can.FieldUpdate r2 _) -> compare (Ann._line (Ann._start r1)) (Ann._line (Ann._start r2))) (Map.toList updates)
        in "{ let mut result = " ++ exprToRustString ctx record ++ "; " ++
        intercalate "; " (map (\(f, Can.FieldUpdate _ expr) -> "result." ++ f ++ " = " ++ exprToRustString ctx expr) sorted) ++
        "; result }"
    Can.Record fields -> 
        let key = intercalate "," (Map.keys fields)
        in case Map.lookup key (ecRecordMap ctx) of
            Just structName -> 
                structName ++ " { " ++ intercalate ", " (map (\(k, v) -> 
                    k ++ ": " ++ exprToRustString ctx v) (Map.toList fields)) ++ " }"
            Nothing -> 
                "{ " ++ intercalate ", " (map (\(k, v) -> k ++ ": " ++ exprToRustString ctx v) (Map.toList fields)) ++ " }"
    Can.Unit -> "()"
    Can.Tuple a b rest -> 
        "(" ++ intercalate ", " (map (exprToRustString ctx) (a:b:rest)) ++ ")"

-- | Given a Task-typed expression (like Db_query(…)), return the Rust type
-- string of the SkyTask's inner success type A (i.e.  SkyTask<A> → A).
-- Returns "" when the type can't be determined.
-- Takes a solvedTypes map so Task.succeed(arg) can look up arg's type.
taskExprInnerType :: Map.Map String Can.Type -> Can.Expr -> String
taskExprInnerType solved (Ann.At _ expr) = case expr of
    Can.VarLocal name -> case Map.lookup name solved of
        Just ty -> taskInnerTypeStr (extractReturnType ty)
        Nothing -> ""
    -- Check kernel calls (VarKernel or VarTopLevel with kernel alias)
    Can.Call callee args -> taskExprInnerTypeCall solved callee args
    -- Pipeline: extract type from left side (the task being piped)
    Can.Binop "|>" _ _ _ a _ ->
        let t = taskExprInnerType solved a
        in if null t then "String" else t
    Can.Case _ branches ->
        -- If ALL case branches are Task expressions, propagate the inner type
        let innerTypes = [ taskExprInnerType solved b | Can.CaseBranch _ b <- branches ]
        in if not (null innerTypes) && all (not . null) innerTypes
           then head innerTypes  -- same inner type for all branches
           else ""
    Can.VarTopLevel mod name ->
        -- Look up the solved type of this VarTopLevel and extract Task inner type
        case Map.lookup name solved of
            Just ty -> let ret = extractReturnType ty in taskInnerTypeStr ret
            Nothing -> ""
    _ -> ""

-- | Extract the inner type string from a Sky type (task or not).
-- If the type is Task e a, return the Rust string of a.
-- Otherwise return "" (not a Task expression).
taskInnerTypeStr :: Can.Type -> String
taskInnerTypeStr (Can.TType _ "Task" [_, a]) = typeToRustString Map.empty a
taskInnerTypeStr _                           = ""

-- | Inner helper for taskExprInnerType: try to determine the Task inner
-- type from a call expression.  Handles both VarKernel and VarTopLevel
-- callees that route through kernelToRust.
taskExprInnerTypeCall :: Map.Map String Can.Type -> Can.Expr -> [Can.Expr] -> String
taskExprInnerTypeCall solved (Ann.At _ (Can.VarTopLevel mod name)) args =
    let rawMod = ModuleName._name mod
        snakeName = toSnakeCase (map (\c -> if c == '.' then '_' else c) rawMod ++ "_" ++ name)
        kName = kernelToRust rawMod name
        fakeSpan = Ann.Region (Ann.Position 0 0) (Ann.Position 0 0)
    in if snakeName /= kName
       then taskExprInnerTypeCall solved (Ann.At fakeSpan (Can.VarKernel rawMod name)) args
       else -- Not a kernel: check solved types for the function name
            case Map.lookup name solved of
                Just ty -> let ret = extractReturnType ty in taskInnerTypeStr ret
                Nothing -> ""
taskExprInnerTypeCall solved (Ann.At _ (Can.VarKernel modName fnName)) args
        | "Task" `isSuffixOf` modName || modName == "Task" = case fnName of
            "succeed"  -> case args of
                [arg] -> solveArgType solved arg
                _ -> "String"
            "fail"     -> ""  -- polymorphic success type A — empty signals unconstrained
            "map"      -> "String"  -- result type is B (fn's return), not derivable statically
            "andThen"  -> "String"  -- same
            "onError"  -> case args of
                [_, task] -> taskExprInnerType solved task
                _ -> "String"
            "mapError" -> case args of
                [_, task] -> taskExprInnerType solved task  -- same success type A
                _ -> "String"
            _ -> ""
        | "Db" `isSuffixOf` modName || modName == "Db" = case fnName of
            "query"    -> "Vec<HashMap<String, String>>"
            "exec"     -> "()"
            "execRaw"  -> "()"
            "connect"  -> "Db"
            "getField" -> "String"
            "getString" -> "String"
            "getInt"   -> "i64"
            _ -> ""
        | "System" `isSuffixOf` modName || modName == "System" = case fnName of
            "args"        -> "Vec<String>"
            "exit"        -> "()"
            "setenv"      -> "()"
            "unsetenv"    -> "()"
            _ -> ""
        | "Log" `isSuffixOf` modName || modName == "Log" = "()"
        | "Time" `isSuffixOf` modName || modName == "Time" = case fnName of
            "now"       -> "i64"
            "sleep"     -> "()"
            "unixMillis" -> "i64"
            _ -> ""
        | "Random" `isSuffixOf` modName || modName == "Random" = case fnName of
            "int"    -> "i64"
            "float"  -> "f64"
            "choice" -> "String"
            _ -> ""
        | "Crypto" `isSuffixOf` modName || modName == "Crypto" = case fnName of
            "randomBytes"  -> "Vec<i64>"
            "randomToken"  -> "String"
            _ -> ""
        | "File" `isSuffixOf` modName || modName == "File" = case fnName of
            "readFile"  -> "String"
            "writeFile" -> "()"
            "exists"    -> "bool"
            _ -> ""
        | otherwise = ""
taskExprInnerTypeCall _ _ _ = ""

-- | Default call emission for non-special-cased function calls.
-- Handles `isZeroArgFn` wrapping (Ffi.kernel stubs) and `isListDec`
-- factory closures.
emitDefaultCall :: EmitCtx -> Can.Expr -> String -> [Can.Expr] -> String
emitDefaultCall ctx fn calleeName args =
    let noCloneFn = case fn of
            Ann.At _ (Can.VarKernel _ n) -> n == "run"
            _ -> False
        isListDec = "json_dec_list" `isSuffixOf` calleeName
        argsStrs = if isListDec && not (null args)
                   then ("|| " ++ argToRustString ctx noCloneFn (head args)) : map (argToRustString ctx noCloneFn) (tail args)
                   else map (argToRustString ctx noCloneFn) args
        isZeroArgFn = case fn of
            Ann.At _ (Can.VarKernel modName name) ->
                let fnName = kernelToRust modName name
                    defaultName = toSnakeCase (map (\c -> if c == '.' then '_' else c) modName ++ "_" ++ name)
                in Set.member (modName, name) (ecZeroArgDefs ctx)
                   && fnName == defaultName
            Ann.At _ (Can.VarTopLevel modName name) ->
                let modPrefix = map (\c -> if c == '.' then '_' else c) (ModuleName._name modName)
                    fnName = toSnakeCase (modPrefix ++ "_" ++ name)
                    kernelName = kernelToRust (ModuleName._name modName) name
                in Set.member (modPrefix, name) (ecZeroArgDefs ctx)
                   && (fnName == kernelName || kernelName == "ffi_kernel")
            _ -> False
        callee = exprToRustString ctx fn
    in if isZeroArgFn && not (null args)
       then callee ++ "()(" ++ intercalate ", " argsStrs ++ ")"
       else callee ++ "(" ++ intercalate ", " argsStrs ++ ")"

-- | Try to extract the Rust type string from a single argument expression
-- by looking up its type in solvedTypes.
solveArgType :: Map.Map String Can.Type -> Can.Expr -> String
solveArgType solvedMap arg = case arg of
    Ann.At _ (Can.Int _)   -> "i64"
    Ann.At _ (Can.Float _) -> "f64"
    Ann.At _ (Can.Str _)   -> "String"
    Ann.At _ (Can.Chr _)   -> "char"
    Ann.At _ (Can.VarLocal name) ->
        case Map.lookup name solvedMap of
            Just ty -> typeToRustString Map.empty ty
            Nothing -> "String"
    Ann.At _ (Can.Binop op _ _ _ a _) ->
        case op of
            "+" -> "i64"; "-" -> "i64"; "*" -> "i64"
            "/" -> "i64"; "%" -> "i64"
            "++" -> "String"
            "&&" -> "bool"; "||" -> "bool"
            "==" -> "bool"; "/=" -> "bool"
            _ -> solveArgType solvedMap a
    _ -> "String"

binopToRust :: String -> String
binopToRust op = case op of
    "+" -> "+"
    "-" -> "-"
    "*" -> "*"
    "/" -> "/"
    "%" -> "%"
    "==" -> "=="
    "/=" -> "!="
    "<" -> "<"
    ">" -> ">"
    "<=" -> "<="
    ">=" -> ">="
    "&&" -> "&&"
    "||" -> "||"
    "::" -> "::"  -- cons
    "++" -> "++"
    _ -> op

defToRustString :: EmitCtx -> Can.Def -> String
-- Zero-arg Def: inject .clone() for captured locals that are used ≥ 2 times,
-- so multiple uses of the same variable (f(x); g(x) pattern) compile.
defToRustString ctx (Can.Def (Ann.At _ name) [] body) =
    let counts = collectVarLocalsMulti body
        multi = [ v | (v, c) <- Map.toList counts, c >= 2 ]
        clones = concatMap (\v -> "let " ++ v ++ " = " ++ v ++ ".clone(); ") multi
    in case body of
        Ann.At _ (Can.Lambda [] lambdaBody) ->
            let inner = "|| { " ++ exprToRustString ctx lambdaBody ++ " }"
            in name ++ " = " ++ if null multi then inner else "{ " ++ clones ++ inner ++ " }"
        _ ->
            let inner = exprToRustString ctx body
            in name ++ " = " ++ if null multi then inner else "{ " ++ clones ++ inner ++ " }"
-- Multi-arg Def: closure binding.
defToRustString ctx (Can.Def (Ann.At _ name) params body) =
    name ++ " = |" ++ intercalate ", " (map patternToRustParam params) ++ "| { " ++ exprToRustString ctx body ++ " }"
defToRustString _ctx _ = "_ = unimplemented()"

branchToRustString :: EmitCtx -> Can.CaseBranch -> String
branchToRustString ctx (Can.CaseBranch pat body) =
    let patStr  = patternToMatchString (ecRecordMap ctx) pat
        -- Zero-arg top-level functions used as case values must be called.
        bodyExpr = case body of
            Ann.At _ (Can.VarTopLevel mod name) ->
                let modStr = ModuleName._name mod
                    rawName = (if null modStr then "" else map (\c -> if c == '.' then '_' else c) modStr ++ "_") ++ name
                in toSnakeCase rawName ++ "()"
            _ -> exprToRustString ctx body
        -- Slice patterns bind references (&T for head, &[T] for tail).
        -- Inject .clone() / .to_vec() so the body sees owned values.
        prefix = case pat of
            Ann.At _ (Can.PCons headPat tailPat) ->
                let hc = concatMap (\v -> "let " ++ v ++ " = " ++ v ++ ".clone(); ") (patBindingVars headPat)
                    tv = concatMap (\v -> "let " ++ v ++ " = " ++ v ++ ".to_vec(); ") (patBindingVars tailPat)
                in hc ++ tv
            Ann.At _ (Can.PList items) ->
                concatMap (\v -> "let " ++ v ++ " = " ++ v ++ ".clone(); ") (concatMap patBindingVars items)
            _ -> ""
    in if null prefix && not ("let " `isPrefixOf` bodyExpr) && not ("if " `isPrefixOf` bodyExpr)
       then patStr ++ " => " ++ bodyExpr
       else patStr ++ " => { " ++ prefix ++ bodyExpr ++ " }"

patternToMatchString :: Map.Map String String -> Can.Pattern -> String
patternToMatchString _recMap (Ann.At _ pat) = case pat of
    Can.PVar n -> rustSafeIdent n
    Can.PAnything -> "_"
    Can.PInt i -> show i
    Can.PBool b -> if b then "true" else "false"
    Can.PChr c -> "'" ++ c ++ "'"
    Can.PStr s -> show s
    Can.PUnit -> "()"
    Can.PCtor{Can._p_home = home, Can._p_type = typeName, Can._p_name = name, Can._p_args = args} ->
        let subPats = map (\(Can.PatternCtorArg _ _ p) -> patternToMatchString _recMap p) args
            fullName = kernelCtorToRust home typeName name
        in fullName ++ if null subPats then "" else "(" ++ intercalate ", " subPats ++ ")"
    Can.PTuple a b rest -> 
        "(" ++ intercalate ", " (map (patternToMatchString _recMap) (a:b:rest)) ++ ")"
    Can.PRecord fields ->
        let key = intercalate "," fields
        in case Map.lookup key _recMap of
            Just structName -> structName ++ " { " ++ intercalate ", " fields ++ " }"
            Nothing -> "{ " ++ intercalate ", " fields ++ " }"
    Can.PCons a b ->
        let (heads, tailPat) = flattenCons _recMap a b
            allParts = heads ++ if tailPat == "_" then [".."] else [tailPat ++ " @ .."]
        in "[" ++ intercalate ", " allParts ++ "]"
    Can.PList items -> "[" ++ intercalate ", " (map (patternToMatchString _recMap) items) ++ "]"
    Can.PAlias pat _ -> patternToMatchString _recMap pat
    _ -> "_"

ctorArgToPattern :: Can.PatternCtorArg -> String
ctorArgToPattern (Can.PatternCtorArg _ _ pat) = patternToMatchString Map.empty pat

-- | Flatten nested cons patterns into a head-list and tail.
-- e.g. x::y::rest → (["x", "y"], "rest")  → emits [x, y, rest @ ..]
flattenCons :: Map.Map String String -> Can.Pattern -> Can.Pattern -> ([String], String)
flattenCons recMap headPat tailPat =
    let h = patternToMatchString recMap headPat
    in case tailPat of
        Ann.At _ (Can.PCons h2 t2) ->
            let (moreHeads, tail) = flattenCons recMap h2 t2
            in (h : moreHeads, tail)
        Ann.At _ (Can.PList items) ->
            let itemStrs = map (patternToMatchString recMap) items
            in (h : itemStrs, "_")
        Ann.At _ (Can.PVar v) ->
            ([h], v)
        Ann.At _ Can.PAnything ->
            ([h], "_")
        _ ->
            ([h], "_")
    where
    unwrapPat (Ann.At _ (Can.PAlias inner _)) = inner
    unwrapPat p = p

buildProgram :: [Can.Module] -> Map.Map String Can.Type -> Map.Map (String, String) (String, String) -> RustBuilder
buildProgram mods solvedTypes kernelAliases = 
    let aliasMap = buildRecordMap mods
        rawAnon = collectAnonRecordTypes mods
        -- Only include anonymous record keys NOT already covered by a type alias
        anonEntries = Map.filterWithKey (\k _ -> not (Map.member k aliasMap)) rawAnon
        
        -- Generate RStructDef entries with generic type params per field.
        -- Each field gets a distinct type param T0..Tn so the struct works
        -- with heterogeneous decoder pipelines (String, i64, bool, ...).
        (anonDefs, anonKeyMap) =
            foldr (\(key, flds) (defs, km) ->
                let name = anonStructName key
                    n = length flds
                    typeParams = ["T" ++ show i | i <- [0..n-1]]
                    gens = if null typeParams then "" else "<" ++ intercalate ", " typeParams ++ ">"
                    rustFlds = zipWith (\f t -> (f, t)) flds typeParams
                in if null rustFlds then (defs, km)
                   else (RStructDef name gens rustFlds : defs, Map.insert key name km)
                ) ([], Map.empty) (Map.toList anonEntries)
        
        recordMap = Map.union aliasMap anonKeyMap

        ctorArity = Map.fromList
            [ (name, Map.size fields)
            | mod <- mods
            , (name, Can.Alias _ (Can.TRecord fields _)) <- Map.toList (Can._aliases mod)
            ]

        ctx = EmitCtx { ecRecordMap = recordMap, ecSolvedTypes = solvedTypes, ecCloneVars = Set.empty, ecCopyVars = Set.empty, ecPipeInnerType = Nothing, ecUsesTaskRun = usesTaskRun usage, ecZeroArgDefs = zeroArgDefs, ecNoCloneVars = noCloneVars, ecCtorArity = ctorArity, ecKernelAliases = kernelAliases }
        usage = analyzeKernelUsage mods
        zeroArgDefs = collectZeroArgDefs mods
        noCloneVars = Set.empty
        existingTypes = concatMap (\m ->
            let skyModName = ModuleName._name (Can._name m)         -- "Std.Decimal" — un-mangled, for runtimeOpaqueTypes lookup
                prefix     = moduleNameToRust (Can._name m)          -- "Std_Decimal" — mangled, for codegen names
            in unionsToRustTypes recordMap skyModName prefix (Can._unions m)
            ++ aliasesToRustTypes recordMap prefix (Can._aliases m)) mods
    in RustBuilder
        { builderModules = map (buildModule ctx) mods
        , builderTypes = existingTypes ++ anonDefs
        , builderKernels = usage
        , builderFfiOpaques = Set.empty  -- populated by generateRust via passed FFI types
        }

-- | Backend-specific sqlx types
dbPoolType :: String -> String
dbPoolType "postgres" = "sqlx::postgres::PgPool"
dbPoolType "mysql"    = "sqlx::mysql::MySqlPool"
dbPoolType _          = "sqlx::sqlite::SqlitePool"

dbRowType :: String -> String
dbRowType "postgres" = "sqlx::postgres::PgRow"
dbRowType "mysql"    = "sqlx::mysql::MySqlRow"
dbRowType _          = "sqlx::sqlite::SqliteRow"

emitRust :: RustBuilder -> String -> String -> [String] -> (String, [(String, String)])
emitRust b dbPath dbDriver ffiSlugs =
    let modules = builderModules b
        -- Each module gets its own .rs file (except Main — kept inline
        -- to avoid naming conflict with main.rs).  Included via
        -- pub mod + pub use so re-exports keep bare names working.
        moduleFiles = map moduleToRustFile (filter (\m -> modName m /= "Main") modules)
        inlineModules = filter (\m -> modName m == "Main") modules
        modDecls = concatMap (\(name, _) ->
            [ "pub mod " ++ toSnakeCase name ++ ";"
            , "pub use " ++ toSnakeCase name ++ "::*;"
            ]) moduleFiles
            ++ concatMap (\slug ->
            [ "pub mod " ++ slug ++ ";"
            , "pub use " ++ slug ++ "::*;"
            ]) ffiSlugs
        -- Wrappers for functions where E can't be inferred from args.
        -- These delegate to the generic sky_runtime functions, instantiating E = SkyError.
        wrapperFns = 
            [ "type SkyTask<A> = sky_runtime::SkyTask<SkyError, A>;"
            , "type Decoder<T> = sky_runtime::json::Decoder<SkyError, T>;"
            , ""
            ] ++
            -- Wrappers for functions where E can't be inferred from args.
            -- These shadow the re-exported generic versions from sky_runtime
            -- (with #[allow(unused)] the warning is suppressed).
            [ "pub fn ok_res<A>(a: A) -> SkyResult<SkyError, A> { sky_runtime::core::ok_res(a) }"
            , "pub fn task_succeed<A: Send + 'static>(a: A) -> SkyTask<A> { sky_runtime::task::task_succeed(a) }"
            , "pub fn log_info(msg: String) -> SkyTask<()> { sky_runtime::log::log_info(msg) }"
            , "pub fn log_debug(msg: String) -> SkyTask<()> { sky_runtime::log::log_debug(msg) }"
            , "pub fn log_warn(msg: String) -> SkyTask<()> { sky_runtime::log::log_warn(msg) }"
            , "pub fn log_info_with(msg: String, attrs: Vec<String>) -> SkyTask<()> { sky_runtime::log::log_info_with(msg, attrs) }"
            , "pub fn log_error_with(msg: String, attrs: Vec<String>) -> SkyTask<()> { sky_runtime::log::log_error_with(msg, attrs) }"
            , "pub fn system_args(_: ()) -> SkyTask<Vec<String>> { sky_runtime::system::system_args(()) }"
            , "pub fn system_setenv(key: String, val: String) -> SkyTask<()> { sky_runtime::system::system_setenv(key, val) }"
            , "pub fn system_unsetenv(key: String) -> SkyTask<()> { sky_runtime::system::system_unsetenv(key) }"
            , "pub fn time_now(_: ()) -> SkyTask<i64> { sky_runtime::time::time_now(()) }"
            , "pub fn time_sleep(ms: i64) -> SkyTask<()> { sky_runtime::time::time_sleep(ms) }"
            , "pub fn time_unix_millis(_: ()) -> SkyTask<i64> { sky_runtime::time::time_unix_millis(()) }"
            , "pub fn random_int(lo: i64, hi: i64) -> SkyTask<i64> { sky_runtime::random::random_int(lo, hi) }"
            , "pub fn random_float(_: ()) -> SkyTask<f64> { sky_runtime::random::random_float(()) }"
            , "pub fn random_choice(items: Vec<String>) -> SkyTask<String> { sky_runtime::random::random_choice(items) }"
            , "pub fn file_read_file(path: String) -> SkyTask<String> { sky_runtime::file::file_read_file(path) }"
            , "pub fn file_write_file(path: String, content: String) -> SkyTask<()> { sky_runtime::file::file_write_file(path, content) }"
            , "pub fn file_delete(path: String) -> SkyTask<()> { sky_runtime::file::file_delete(path) }"
            , "pub fn crypto_random_bytes(n: i64) -> SkyTask<Vec<i64>> { sky_runtime::crypto::crypto_random_bytes(n) }"
            , "pub fn crypto_random_token(n: i64) -> SkyTask<String> { sky_runtime::crypto::crypto_random_token(n) }"
            ] ++
            (if usesDb (builderKernels b)
             then [ "pub fn db_connect(_: ()) -> SkyTask<Db> { sky_runtime::db::db_connect(()) }"
                  , "pub fn db_open(_: ()) -> SkyTask<Db> { sky_runtime::db::db_open(()) }"
                  , "pub fn db_open_with_path(path: String) -> SkyTask<Db> { sky_runtime::db::db_open_with_path(path) }"
                  , "pub fn db_exec_raw(conn: Db, sql: String) -> SkyTask<()> { sky_runtime::db::db_exec_raw(conn, sql) }"
                  , "pub fn db_exec(conn: Db, sql: String, params: Vec<String>) -> SkyTask<()> { sky_runtime::db::db_exec(conn, sql, params) }"
                   , "pub fn db_query(conn: Db, sql: String, params: Vec<String>) -> SkyTask<Vec<HashMap<String, String>>> { sky_runtime::db::db_query(conn, sql, params) }"
                   , "pub fn db_migrate_apply(db: Db, migrations: Vec<(String, String)>) -> SkyTask<Vec<String>> { sky_runtime::db::db_migrate_apply::<SkyError>(db, migrations) }"
                   ]
              else [])
        -- impl From<String> for SkyError when Sky.Core.Error is present
        fromStrImpl = if hasErrorType b
            then let errName = "SkyCoreErrorError"
                     kindName = "SkyCoreErrorErrorKind"
                     infoName = "SkyCoreErrorErrorInfo"
                 in [ "impl From<String> for " ++ errName ++ " {"
                    , "    fn from(s: String) -> Self {"
                    , "        " ++ errName ++ "::Error("
                    , "            " ++ kindName ++ "::Unexpected,"
                    , "            " ++ infoName ++ " { details: SkyMaybe::Nothing, message: s }"
                    , "        )"
                    , "    }"
                    , "}"
                    ]
            else []
        mainCode = unlines $ concat
            [ headerSection
            , modDecls
            , [""]
            , importSection (builderKernels b) dbDriver
            , basicTypeSection
            , userTypeSection b
            , fromStrImpl
            , skyErrorLine b
            , wrapperFns
            , [""]
            , concatMap (concatMap itemToRustStrings . modItems) inlineModules
            , kernelHelperSection
            , ffiPlaceholderSection b
            , entryPointSection (builderKernels b)
            ]
    in (mainCode, moduleFiles)

-- | Header and file-level attributes
headerSection :: [String]
headerSection =
    [ "// Generated by Sky compiler (Rust target)"
    , "#![allow(unused, non_snake_case)]"
    , ""
    , "pub mod sky_runtime;"
    , "pub use sky_runtime::*;"
    , ""
    ]

-- | Conditional imports — only include tokio/sqlx when actually used
importSection :: UsedKernels -> String -> [String]
importSection uk dbDriver =
    [ "use std::collections::HashMap;"
    , "use std::fmt;"
    , "use std::future::Future;"
    , "use std::future::ready;"
    , "use std::pin::Pin;"
    , "use std::sync::Arc;"
    , "use std::task::{Wake, Waker, Context, Poll};"
    ] ++
    (if usesTaskRun uk || usesTaskParallel uk || usesDb uk
     then ["use tokio::runtime::Runtime;"] else []) ++
    (if usesTaskParallel uk
     then [] else []) ++  -- tokio::spawn used via fully-qualified path
    (if usesDb uk
     then
        [ "use " ++ dbPoolType dbDriver ++ " as DbPool;"
        , "use " ++ dbRowType dbDriver ++ " as DbRow;"
        , "use sqlx::{Column, Row};"
        ]
     else [])

-- | Basic type aliases (always emitted)
basicTypeSection :: [String]
basicTypeSection =
    [ ""
    , "// Basic types"
    , "type SkyInt = i64;"
    , "type SkyFloat = f64;"
    , "type SkyBool = bool;"
    , "type SkyString = String;"
    , "type Value = JsonVal;"
    , ""
    ]

-- | Ffi.kernel polyfill — kernel dispatch stubs that are never called at
-- runtime (codegen routes calls directly to kernel implementations).
-- | Non-recursive List.map for Task-returning closures (no T1: Clone required).
-- Referenced from kernelToRust for List.map.
kernelHelperSection :: [String]
kernelHelperSection =
    [ ""
    , "// Ffi.kernel polyfill — should be unreachable in Rust target;"
    , "// the codegen routes Ffi.kernel calls directly, but some construction"
    , "// paths (e.g. inline let-bindings of Ffi.kernel) leave a residual call."
    , "#[allow(unreachable_code)]"
    , "fn ffi_kernel_polyfill<T>(_name: String) -> T { panic!(\"Ffi.kernel '{}' should not be called in Rust target\", _name) }"
    , ""
    , "// List helpers"
    , "pub fn list_map_consume<T0, T1>(f: impl Fn(T0) -> T1, list: Vec<T0>) -> Vec<T1> {"
    , "    list.into_iter().map(f).collect()"
    , "}"
    , ""
    ]
 
-- | User defined types (unions, aliases)
userTypeSection :: RustBuilder -> [String]
userTypeSection b =
    [ ""
    , "// ==========================================="
    , "// USER TYPES"
    , "// ==========================================="
    , ""
    ] ++ map typeDefToString (builderTypes b)

-- | SkyError type alias + str_err helper — conditional on Error module presence.
-- Must be emitted AFTER userTypeSection (SkyCoreErrorError ADT) and BEFORE
-- dbSection/jsonSection/extraKernelSection (which call str_err).
skyErrorLine :: RustBuilder -> [String]
skyErrorLine b =
    [ ""
    , if hasErrorType b
      then let errName = toCamelCase "Sky_Core_Error_Error"
               kindName = toCamelCase "Sky_Core_Error_ErrorKind"
               infoName = toCamelCase "Sky_Core_Error_ErrorInfo"
           in unlines
                [ "type SkyError = " ++ errName ++ ";"
                , "fn str_err(s: &str) -> SkyError {"
                , "    " ++ errName ++ "::Error("
                , "        " ++ kindName ++ "::Unexpected,"
                , "        " ++ infoName ++ " { details: SkyMaybe::Nothing, message: s.to_string() }"
                , "    )"
                , "}"
                ]
      else "type SkyError = String;\nfn str_err(s: &str) -> SkyError { s.to_string() }"
    , ""
    ]

-- | User modules (functions, types, etc.)
-- | FFI placeholder types
ffiPlaceholderSection :: RustBuilder -> [String]
ffiPlaceholderSection b =
    [ ""
    , "// ==========================================="
    , "// FFI PLACEHOLDER TYPES (types referenced but not defined)"
    , "// ==========================================="
    , ""
    ] ++ map ffiPlaceholder (collectUndefinedTypes b)

-- | Entry point
entryPointSection :: UsedKernels -> [String]
entryPointSection uk =
    let hasTokio = usesTaskRun uk || usesTaskParallel uk || usesDb uk
        mainIsTask = not (usesTaskRun uk)  -- if user uses Task.run, main returns ()
    in
    [ ""
    , "// ==========================================="
    , "// ENTRY POINT"
    , "// ==========================================="
    , ""
    , "fn main() {"
    ] ++ (if hasTokio && mainIsTask then
        -- sky_main returns SkyTask<()>, run it via block_on
        [ "    match block_on(sky_main()) {"
        , "        SkyResult::Ok(_) => (),"
        , "        SkyResult::Err(e) => { eprintln!(\"{:?}\", e); std::process::exit(1); }"
        , "    }"
        , "}"
        ]
      else if mainIsTask then
        -- sky_main returns SkyTask<()> but no tokio: side effects fire
        -- eagerly inside log_info etc.  Call and drop.
        [ "    sky_main();",
          "}"
        ]
      else
        -- sky_main returns (), Task.run is used inside
        [ "    sky_main();"
        , "}"
        ])

typeDefToString :: RustTypeDef -> String
typeDefToString (REnumDef name variants) =
    "#[derive(Clone, Debug, PartialEq)]\npub enum " ++ name ++ " {\n" ++ intercalate ",\n" (map (\(n, mt) -> "    " ++ n ++ maybe "" (\x -> "(" ++ x ++ ")") mt) variants) ++ "\n}"
typeDefToString (RStructDef name gens fields) =
    "#[derive(Clone, Debug, PartialEq)]\npub struct " ++ name ++ gens ++ " {\n" ++ intercalate ",\n" (map (\(n, t) -> "    " ++ n ++ ": " ++ t) fields) ++ "\n}"
typeDefToString (RAliasDef name ty) = "pub type " ++ name ++ " = " ++ ty ++ ";"
typeDefToString (RPubUseAlias codegenName rustPath) =
    "pub use " ++ rustPath ++ " as " ++ codegenName ++ ";"

-- | Extract a module's content as (snake_case_file_stem, source_content).
-- Used by emitRust to produce per-module .rs files.
-- Each module file starts with `use crate::*;` so inline stubs (ok_res,
-- SkyResult, task_*, etc.) and sky_runtime types are visible inside the
-- real module boundary created by `pub mod`.
moduleToRustFile :: RustModule -> (String, String)
moduleToRustFile m =
    let name = modName m
        items = concatMap itemToRustStrings (modItems m)
    in (toSnakeCase name, "#[allow(unused)]\nuse crate::*;\n\n" ++ unlines items)

kernelCtorToRust :: ModuleName.Canonical -> String -> String -> String
kernelCtorToRust modName typeName ctorName =
    let modStr = ModuleName._name modName
    in case (modStr, typeName, ctorName) of
        ("Sky.Core.Basics", "Bool", "True") -> "true"
        ("Sky.Core.Basics", "Bool", "False") -> "false"
        ("Sky.Core.Maybe", "Maybe", c) -> "SkyMaybe::" ++ c
        ("Sky.Core.Result", "Result", c) -> "SkyResult::" ++ c
        _ -> let modPrefix = if null modStr then "" else map (\c -> if c == '.' then '_' else c) modStr ++ "_"
             in toCamelCase (modPrefix ++ typeName) ++ "::" ++ ctorName

kernelToRust :: String -> String -> String
kernelToRust mod name = case (mod, name) of
    -- List functions (Q3)
    ("List", "map") -> "list_map_consume"
    ("Sky.Core.List", "map") -> "list_map_consume"
    ("List", "foldl") -> "list_foldl"
    ("Sky.Core.List", "foldl") -> "list_foldl"
    ("List", "foldr") -> "list_foldr"
    ("Sky.Core.List", "foldr") -> "list_foldr"
    ("List", "range") -> "list_range"
    ("Sky.Core.List", "range") -> "list_range"
    ("List", "indexedMap") -> "list_indexed_map"
    ("Sky.Core.List", "indexedMap") -> "list_indexed_map"
    ("List", "concatMap") -> "list_concat_map"
    ("Sky.Core.List", "concatMap") -> "list_concat_map"
    ("List", "zip") -> "list_zip"
    ("Sky.Core.List", "zip") -> "list_zip"
    ("List", "filter") -> "list_filter"
    ("Sky.Core.List", "filter") -> "list_filter"
    ("List", "member") -> "list_member"
    ("Sky.Core.List", "member") -> "list_member"
    ("List", "any") -> "list_any"
    ("Sky.Core.List", "any") -> "list_any"
    ("List", "all") -> "list_all"
    ("Sky.Core.List", "all") -> "list_all"
    -- String kernel functions: route directly to runtime implementations
    ("String", "fromInt") -> "string_from_int"
    ("Sky.Core.String", "fromInt") -> "string_from_int"
    ("String", "fromFloat") -> "string_from_float"
    ("Sky.Core.String", "fromFloat") -> "string_from_float"
    ("String", "length") -> "string_length"
    ("Sky.Core.String", "length") -> "string_length"
    ("String", "isEmpty") -> "string_is_empty"
    ("Sky.Core.String", "isEmpty") -> "string_is_empty"
    ("String", "reverse") -> "string_reverse"
    ("Sky.Core.String", "reverse") -> "string_reverse"
    ("String", "append") -> "string_append"
    ("Sky.Core.String", "append") -> "string_append"
    ("String", "toInt") -> "string_to_int"
    ("Sky.Core.String", "toInt") -> "string_to_int"
    ("String", "toLower") -> "string_to_lower"
    ("Sky.Core.String", "toLower") -> "string_to_lower"
    ("String", "toUpper") -> "string_to_upper"
    ("Sky.Core.String", "toUpper") -> "string_to_upper"
    ("String", "trim") -> "string_trim"
    ("Sky.Core.String", "trim") -> "string_trim"
    ("String", "split") -> "string_split"
    ("Sky.Core.String", "split") -> "string_split"
    ("String", "join") -> "string_join"
    ("Sky.Core.String", "join") -> "string_join"
    -- Encoding (sub-A.1)
    ("Encoding", "base64Encode")        -> "base64_encode"
    ("Sky.Core.Encoding", "base64Encode") -> "base64_encode"
    ("Encoding", "base64Decode")        -> "base64_decode"
    ("Sky.Core.Encoding", "base64Decode") -> "base64_decode"
    ("Encoding", "urlEncode")           -> "url_encode"
    ("Sky.Core.Encoding", "urlEncode")  -> "url_encode"
    ("Encoding", "urlDecode")           -> "url_decode"
    ("Sky.Core.Encoding", "urlDecode")  -> "url_decode"
    -- Renamed (was hex_encode/hex_decode) to avoid colliding with
    -- user-FFI bindings to the `hex` crate (examples/rust/16-hex).
    ("Encoding", "hexEncode")           -> "encoding_hex_encode"
    ("Sky.Core.Encoding", "hexEncode")  -> "encoding_hex_encode"
    ("Encoding", "hexDecode")           -> "encoding_hex_decode"
    ("Sky.Core.Encoding", "hexDecode")  -> "encoding_hex_decode"
    -- Regex (sub-A.2)
    ("Regex", "match")              -> "regex_match"
    ("Sky.Core.Regex", "match")     -> "regex_match"
    ("Regex", "find")               -> "regex_find"
    ("Sky.Core.Regex", "find")      -> "regex_find"
    ("Regex", "findAll")            -> "regex_find_all"
    ("Sky.Core.Regex", "findAll")   -> "regex_find_all"
    ("Regex", "replace")            -> "regex_replace"
    ("Sky.Core.Regex", "replace")   -> "regex_replace"
    ("Regex", "split")              -> "regex_split"
    ("Sky.Core.Regex", "split")     -> "regex_split"
    -- Crypto completion (sub-A.3) — sha256 + random* already present
    ("Crypto", "sha512")                       -> "crypto_sha512"
    ("Sky.Core.Crypto", "sha512")              -> "crypto_sha512"
    ("Crypto", "sha1")                         -> "crypto_sha1"
    ("Sky.Core.Crypto", "sha1")                -> "crypto_sha1"
    ("Crypto", "md5")                          -> "crypto_md5"
    ("Sky.Core.Crypto", "md5")                 -> "crypto_md5"
    ("Crypto", "hmacSha256")                   -> "crypto_hmac_sha256"
    ("Sky.Core.Crypto", "hmacSha256")          -> "crypto_hmac_sha256"
    ("Crypto", "hmacSha512")                   -> "crypto_hmac_sha512"
    ("Sky.Core.Crypto", "hmacSha512")          -> "crypto_hmac_sha512"
    ("Crypto", "rsaSha256Sign")                -> "crypto_rsa_sha256_sign"
    ("Sky.Core.Crypto", "rsaSha256Sign")       -> "crypto_rsa_sha256_sign"
    ("Crypto", "rsaSha256Verify")              -> "crypto_rsa_sha256_verify"
    ("Sky.Core.Crypto", "rsaSha256Verify")     -> "crypto_rsa_sha256_verify"
    ("Crypto", "constantTimeEqual")            -> "crypto_constant_time_equal"
    ("Sky.Core.Crypto", "constantTimeEqual")   -> "crypto_constant_time_equal"
    -- Std.Time advanced (sub-A.5)
    ("Time", "inZone")            -> "time_in_zone"
    ("Std.Time", "inZone")        -> "time_in_zone"
    ("Time", "formatInZone")      -> "time_format_in_zone"
    ("Std.Time", "formatInZone")  -> "time_format_in_zone"
    ("Time", "addDays")           -> "time_add_days"
    ("Std.Time", "addDays")       -> "time_add_days"
    ("Time", "addHours")          -> "time_add_hours"
    ("Std.Time", "addHours")      -> "time_add_hours"
    ("Time", "addMinutes")        -> "time_add_minutes"
    ("Std.Time", "addMinutes")    -> "time_add_minutes"
    ("Time", "addSeconds")        -> "time_add_seconds"
    ("Std.Time", "addSeconds")    -> "time_add_seconds"
    ("Time", "addMonths")         -> "time_add_months"
    ("Std.Time", "addMonths")     -> "time_add_months"
    ("Time", "addYears")          -> "time_add_years"
    ("Std.Time", "addYears")      -> "time_add_years"
    ("Time", "year")              -> "time_year"
    ("Std.Time", "year")          -> "time_year"
    ("Time", "month")             -> "time_month"
    ("Std.Time", "month")         -> "time_month"
    ("Time", "day")               -> "time_day"
    ("Std.Time", "day")           -> "time_day"
    ("Time", "dayOfWeek")         -> "time_day_of_week"
    ("Std.Time", "dayOfWeek")     -> "time_day_of_week"
    ("Time", "dayOfYear")         -> "time_day_of_year"
    ("Std.Time", "dayOfYear")     -> "time_day_of_year"
    ("Time", "weekOfYear")        -> "time_week_of_year"
    ("Std.Time", "weekOfYear")    -> "time_week_of_year"
    ("Time", "isWeekend")         -> "time_is_weekend"
    ("Std.Time", "isWeekend")     -> "time_is_weekend"
    ("Time", "daysInMonth")       -> "time_days_in_month"
    ("Std.Time", "daysInMonth")   -> "time_days_in_month"
    ("Time", "isLeapYear")        -> "time_is_leap_year"
    ("Std.Time", "isLeapYear")    -> "time_is_leap_year"
    ("Time", "startOfDay")        -> "time_start_of_day"
    ("Std.Time", "startOfDay")    -> "time_start_of_day"
    ("Time", "endOfDay")          -> "time_end_of_day"
    ("Std.Time", "endOfDay")      -> "time_end_of_day"
    ("Time", "startOfWeek")       -> "time_start_of_week"
    ("Std.Time", "startOfWeek")   -> "time_start_of_week"
    ("Time", "startOfMonth")      -> "time_start_of_month"
    ("Std.Time", "startOfMonth")  -> "time_start_of_month"
    ("Time", "endOfMonth")        -> "time_end_of_month"
    ("Std.Time", "endOfMonth")    -> "time_end_of_month"
    ("Time", "startOfYear")       -> "time_start_of_year"
    ("Std.Time", "startOfYear")   -> "time_start_of_year"
    ("Time", "endOfYear")         -> "time_end_of_year"
    ("Std.Time", "endOfYear")     -> "time_end_of_year"
    -- Std.Decimal (sub-A.6)
    ("Decimal", "fromString")     -> "decimal_from_string"
    ("Std.Decimal", "fromString") -> "decimal_from_string"
    ("Decimal", "fromInt")        -> "decimal_from_int"
    ("Std.Decimal", "fromInt")    -> "decimal_from_int"
    ("Decimal", "fromFloat")      -> "decimal_from_float"
    ("Std.Decimal", "fromFloat")  -> "decimal_from_float"
    ("Decimal", "fromMinor")      -> "decimal_from_minor"
    ("Std.Decimal", "fromMinor")  -> "decimal_from_minor"
    ("Decimal", "zero")           -> "decimal_zero"
    ("Std.Decimal", "zero")       -> "decimal_zero"
    ("Decimal", "one")            -> "decimal_one"
    ("Std.Decimal", "one")        -> "decimal_one"
    ("Decimal", "oneHundred")     -> "decimal_one_hundred"
    ("Std.Decimal", "oneHundred") -> "decimal_one_hundred"
    ("Decimal", "toString")       -> "decimal_to_string"
    ("Std.Decimal", "toString")   -> "decimal_to_string"
    ("Decimal", "toStringFixed")  -> "decimal_to_string_fixed"
    ("Std.Decimal", "toStringFixed") -> "decimal_to_string_fixed"
    ("Decimal", "toFloat")        -> "decimal_to_float"
    ("Std.Decimal", "toFloat")    -> "decimal_to_float"
    ("Decimal", "toInt")          -> "decimal_to_int"
    ("Std.Decimal", "toInt")      -> "decimal_to_int"
    ("Decimal", "toMinor")        -> "decimal_to_minor"
    ("Std.Decimal", "toMinor")    -> "decimal_to_minor"
    ("Decimal", "add")            -> "decimal_add"
    ("Std.Decimal", "add")        -> "decimal_add"
    ("Decimal", "sub")            -> "decimal_sub"
    ("Std.Decimal", "sub")        -> "decimal_sub"
    ("Decimal", "mul")            -> "decimal_mul"
    ("Std.Decimal", "mul")        -> "decimal_mul"
    ("Decimal", "div")            -> "decimal_div"
    ("Std.Decimal", "div")        -> "decimal_div"
    ("Decimal", "mod")            -> "decimal_mod"
    ("Std.Decimal", "mod")        -> "decimal_mod"
    ("Decimal", "neg")            -> "decimal_neg"
    ("Std.Decimal", "neg")        -> "decimal_neg"
    ("Decimal", "abs")            -> "decimal_abs"
    ("Std.Decimal", "abs")        -> "decimal_abs"
    ("Decimal", "round")          -> "decimal_round"
    ("Std.Decimal", "round")      -> "decimal_round"
    ("Decimal", "roundHalfUp")    -> "decimal_round_half_up"
    ("Std.Decimal", "roundHalfUp")-> "decimal_round_half_up"
    ("Decimal", "truncate")       -> "decimal_truncate"
    ("Std.Decimal", "truncate")   -> "decimal_truncate"
    ("Decimal", "floor")          -> "decimal_floor"
    ("Std.Decimal", "floor")      -> "decimal_floor"
    ("Decimal", "ceil")           -> "decimal_ceil"
    ("Std.Decimal", "ceil")       -> "decimal_ceil"
    ("Decimal", "compare")        -> "decimal_compare"
    ("Std.Decimal", "compare")    -> "decimal_compare"
    -- Json.Encode kernel functions: route to runtime implementations
    ("JsonEnc", "string") -> "json_enc_string"
    ("Sky.Core.Json.Encode", "string") -> "json_enc_string"
    ("JsonEnc", "int") -> "json_enc_int"
    ("Sky.Core.Json.Encode", "int") -> "json_enc_int"
    ("JsonEnc", "float") -> "json_enc_float"
    ("Sky.Core.Json.Encode", "float") -> "json_enc_float"
    ("JsonEnc", "bool") -> "json_enc_bool"
    ("Sky.Core.Json.Encode", "bool") -> "json_enc_bool"
    ("JsonEnc", "null") -> "json_enc_null"
    ("Sky.Core.Json.Encode", "null") -> "json_enc_null"
    ("JsonEnc", "encode") -> "json_enc_encode"
    ("Sky.Core.Json.Encode", "encode") -> "json_enc_encode"
    ("JsonEnc", "list") -> "json_enc_list"
    ("Sky.Core.Json.Encode", "list") -> "json_enc_list"
    ("JsonEnc", "object") -> "json_enc_object"
    ("Sky.Core.Json.Encode", "object") -> "json_enc_object"
    -- Json.Decode kernel functions: route to runtime implementations
    ("JsonDec", "string") -> "json_dec_string"
    ("Sky.Core.Json.Decode", "string") -> "json_dec_string"
    ("JsonDec", "int") -> "json_dec_int"
    ("Sky.Core.Json.Decode", "int") -> "json_dec_int"
    ("JsonDec", "float") -> "json_dec_float"
    ("Sky.Core.Json.Decode", "float") -> "json_dec_float"
    ("JsonDec", "bool") -> "json_dec_bool"
    ("Sky.Core.Json.Decode", "bool") -> "json_dec_bool"
    ("JsonDec", "null") -> "json_dec_null"
    ("Sky.Core.Json.Decode", "null") -> "json_dec_null"
    ("JsonDec", "field") -> "json_dec_field"
    ("Sky.Core.Json.Decode", "field") -> "json_dec_field"
    ("JsonDec", "at") -> "json_dec_at"
    ("Sky.Core.Json.Decode", "at") -> "json_dec_at"
    ("JsonDec", "list") -> "json_dec_list"
    ("Sky.Core.Json.Decode", "list") -> "json_dec_list"
    ("JsonDec", "map") -> "json_dec_map"
    ("Sky.Core.Json.Decode", "map") -> "json_dec_map"
    ("JsonDec", "andThen") -> "json_dec_and_then"
    ("Sky.Core.Json.Decode", "andThen") -> "json_dec_and_then"
    ("JsonDec", "succeed") -> "json_dec_succeed"
    ("Sky.Core.Json.Decode", "succeed") -> "json_dec_succeed"
    ("JsonDec", "fail") -> "json_dec_fail"
    ("Sky.Core.Json.Decode", "fail") -> "json_dec_fail"
    ("JsonDec", "decodeString") -> "json_dec_decode_string"
    ("Sky.Core.Json.Decode", "decodeString") -> "json_dec_decode_string"
    ("JsonDec", "oneOf") -> "json_dec_one_of"
    ("Sky.Core.Json.Decode", "oneOf") -> "json_dec_one_of"
    -- Task kernel functions: route to runtime implementations
    ("Task", "succeed") -> "task_succeed"
    ("Sky.Core.Task", "succeed") -> "task_succeed"
    ("Task", "map") -> "task_map"
    ("Sky.Core.Task", "map") -> "task_map"
    ("Task", "andThen") -> "task_and_then"
    ("Sky.Core.Task", "andThen") -> "task_and_then"
    ("Task", "mapError") -> "task_map_error"
    ("Sky.Core.Task", "mapError") -> "task_map_error"
    ("Task", "onError") -> "task_on_error"
    ("Sky.Core.Task", "onError") -> "task_on_error"
    ("Task", "perform") -> "task_perform"
    ("Sky.Core.Task", "perform") -> "task_perform"
    ("Task", "sequence") -> "task_sequence"
    ("Sky.Core.Task", "sequence") -> "task_sequence"
    ("Task", "run") -> "task_run"
    ("Sky.Core.Task", "run") -> "task_run"
    ("Task", "parallel") -> "task_parallel"
    ("Sky.Core.Task", "parallel") -> "task_parallel"
    ("Task", "lazy") -> "task_lazy"
    ("Sky.Core.Task", "lazy") -> "task_lazy"
    ("Task", "fail") -> "task_fail"
    ("Sky.Core.Task", "fail") -> "task_fail"
    ("Task", "fromResult") -> "task_from_result"
    ("Sky.Core.Task", "fromResult") -> "task_from_result"
    ("Task", "andThenResult") -> "task_and_then_result"
    ("Sky.Core.Task", "andThenResult") -> "task_and_then_result"
    -- Json.Decode.Pipeline
    ("JsonDecP", "required") -> "json_dec_p_required"
    ("Sky.Core.Json.Decode.Pipeline", "required") -> "json_dec_p_required"
    ("JsonDecP", "optional") -> "json_dec_p_optional"
    ("Sky.Core.Json.Decode.Pipeline", "optional") -> "json_dec_p_optional"
    -- Log kernel functions: route to runtime implementations
    ("Log", "println") -> "log_info"
    ("Std.Log", "println") -> "log_info"
    ("Log", "info") -> "log_info"
    ("Std.Log", "info") -> "log_info"
    ("Log", "debug") -> "log_debug"
    ("Std.Log", "debug") -> "log_debug"
    ("Log", "warn") -> "log_warn"
    ("Std.Log", "warn") -> "log_warn"
    ("Log", "error") -> "log_error"
    ("Std.Log", "error") -> "log_error"
    ("Log", "infoWith") -> "log_info_with"
    ("Std.Log", "infoWith") -> "log_info_with"
    ("Log", "debugWith") -> "log_debug_with"
    ("Std.Log", "debugWith") -> "log_debug_with"
    ("Log", "warnWith") -> "log_warn_with"
    ("Std.Log", "warnWith") -> "log_warn_with"
    ("Log", "errorWith") -> "log_error_with"
    ("Std.Log", "errorWith") -> "log_error_with"
    -- Db kernel functions: route to runtime implementations
    ("Db", "open") -> "db_open"
    ("Std.Db", "open") -> "db_open"
    ("Db", "connect") -> "db_connect"
    ("Std.Db", "connect") -> "db_connect"
    ("Db", "exec") -> "db_exec"
    ("Std.Db", "exec") -> "db_exec"
    ("Db", "execRaw") -> "db_exec_raw"
    ("Std.Db", "execRaw") -> "db_exec_raw"
    ("Db", "query") -> "db_query"
    ("Std.Db", "query") -> "db_query"
    ("Db", "getField") -> "db_get_field"
    ("Std.Db", "getField") -> "db_get_field"
    ("Db", "getString") -> "db_get_string"
    ("Std.Db", "getString") -> "db_get_string"
    ("Db", "getInt") -> "db_get_int"
    ("Std.Db", "getInt") -> "db_get_int"
    ("Db", "migrateApply") -> "db_migrate_apply"
    ("Std.Db", "migrateApply") -> "db_migrate_apply"
    -- Ffi.kernel: the codegen routes every call through the kernel dispatch,
    -- but the Rust target resolves Ffi.kernel calls directly during
    -- canonicalisation.  Any Ffi.kernel reference that reaches codegen is
    -- a polyfill call site — emit a diagnostic panic.
    ("Ffi", "kernel") -> "ffi_kernel_polyfill"
    -- Ffi.callPure / callTask / toAny: the peephole rewriter in exprToRustInner
    -- handles the common case (literal kernel name + literal args list) by
    -- emitting a direct kernel call. Non-peephole-matched references land
    -- here and route to runtime polyfills: ffi_to_any_polyfill is compile-
    -- time identity; ffi_call_pure_polyfill / ffi_call_task_polyfill panic
    -- with an actionable message. See runtime-rust/src/sky_runtime/ffi_polyfills.rs.
    ("Ffi", "callPure") -> "ffi_call_pure_polyfill"
    ("Ffi", "callTask") -> "ffi_call_task_polyfill"
    ("Ffi", "call")     -> "ffi_call_pure_polyfill"  -- deprecated alias of callPure
    ("Ffi", "toAny")    -> "ffi_to_any_polyfill"
    -- Rust user-FFI kernel: snake_case the suffix, no panic stub.
    -- The wrapper function lives in a .skycache/ffi/rust/*_bindings.rs file
    -- that gets copied into sky-out/Rust/src/ at codegen time.
    _ | "Rust_" `isPrefixOf` mod ->
        toSnakeCase (drop 5 mod ++ "_" ++ name)
    _ -> toSnakeCase (map (\c -> if c == '.' then '_' else c) mod ++ "_" ++ name)

exprToStatement :: String -> String
exprToStatement expr = if null expr then "" 
    else if last expr == '}' then expr  -- block expression
    else expr ++ ";"  -- add semicolon for statement

itemToRustStrings :: RustItem -> [String]
itemToRustStrings (RustFunction name generics params retType body) = 
    let ret = if retType == "()" then "" else " -> " ++ retType
        -- Task-returning functions must NOT have semicolon after the body expression:
        -- the last expression IS the return value (Task combinator chain).
        bodyLine = if retType == "()" then exprToStatement body else body
    in ["pub fn " ++ name ++ generics ++ "(" ++ intercalate ", " params ++ ")" ++ ret ++ " {", "    " ++ bodyLine, "}"]
itemToRustStrings (RustStruct name fields) = 
    ["#[derive(Clone, Debug, PartialEq)]",
     "pub struct " ++ name ++ " {", 
     intercalate ",\n" (map (\(n, t) -> "    " ++ n ++ ": " ++ t) fields), 
     "}"]
itemToRustStrings (RustEnum name variants) = 
    ["#[derive(Clone, Debug, PartialEq)]",
     "pub enum " ++ name ++ " {",
     intercalate ",\n" (map (\(n, mt) -> "    " ++ n ++ maybe "" (\x -> "(" ++ x ++ ")") mt) variants),
     "}"]
itemToRustStrings (RustTypeAlias name ty) = ["type " ++ name ++ " = " ++ ty ++ ";"]

-- | Collect the set of type names referenced in func signatures but not defined
collectUndefinedTypes :: RustBuilder -> [String]
collectUndefinedTypes b = 
    let allItems = concatMap modItems (builderModules b)
        defined = Set.fromList
            [ name | RustStruct name _ <- allItems ]
            `Set.union` Set.fromList
            [ name | RStructDef name _ _ <- builderTypes b ]
            `Set.union` Set.fromList
            [ name | REnumDef name _ <- builderTypes b ]
            `Set.union` Set.fromList
            [ name | RAliasDef name _ <- builderTypes b ]
            `Set.union` Set.fromList
            [ name | RPubUseAlias name _ <- builderTypes b ]
            `Set.union` builderFfiOpaques b  -- types defined by Rust FFI bindings
        -- Collect type names from function parameter types (after ": ")
        referenced = Set.fromList
            [ t | RustFunction _ _ params _ _ <- allItems
                , p <- params
                , let (_, ':':ty) = break (== ':') p
                , let t = dropWhile (== ' ') ty
                , not (null t)
                , not (elem t ["String", "i64", "f64", "bool", "char", "()", "Db", "SkyTask", "SkyError", "HashMap"])
                , not ("impl " `isPrefixOf` t)
                , not ("&" `isPrefixOf` t)
                , not ("Vec<" `isPrefixOf` t)
                , not ("HashMap" `isPrefixOf` t)
                , not ("Option" `isPrefixOf` t)
                , not ("Result" `isPrefixOf` t)
                , not ("SkyMaybe" `isPrefixOf` t)
                , not ("SkyResult" `isPrefixOf` t)
                , not ("Box<" `isPrefixOf` t)
                , not ("fn(" `isPrefixOf` t)
            ]
    in Set.toList (Set.difference referenced defined)

-- | Check if the generated output contains the Sky.Core.Error.Error ADT.
-- If so, SkyError points to it; otherwise SkyError = String.
hasErrorType :: RustBuilder -> Bool
hasErrorType b = any isErrorTypeName (builderTypes b) || any isUserError (builderModules b)
  where
    isErrorTypeName (REnumDef n _) = n == toCamelCase "Sky_Core_Error_Error"
    isErrorTypeName _ = False
    isUserError m = any isErrorItem (modItems m)
    isErrorItem (RustTypeAlias n _) = n == "Error" || n == "SkyError"
    isErrorItem _ = False

ffiPlaceholder :: String -> String
ffiPlaceholder name = "type " ++ name ++ " = String;"

-- | Generate Cargo.toml for the Rust project
emitCargoToml :: UsedKernels -> String -> String -> [(String, Toml.RustDepSpec)] -> String
emitCargoToml uk dbDriver sqlxTls rustDeps = unlines $
    -- The sky_runtime files copied into sky-out/Rust/src/ carry cfg(feature = "X")
    -- gates inherited from runtime-rust/Cargo.toml. The generated Cargo.toml
    -- below declares a [features] section enabling everything by default so the
    -- gates evaluate as true. We also pull in the matching crates directly
    -- (rather than via the optional-dep mechanism the runtime crate uses) so
    -- this project compiles standalone with no `--features` flag.
    [ "[package]"
    , "name = \"sky-app\""
    , "version = \"0.1.0\""
    , "edition = \"2021\""
    , ""
    , "[features]"
    , "default = [\"tokio\", \"crypto\", \"json\", \"db\"]"
    , "tokio = []"
    , "crypto = []"
    , "json = []"
    , "db = []"
    , ""
    , "[dependencies]"
    , "tokio = { version = \"1\", features = [\"rt\", \"rt-multi-thread\", \"macros\", \"time\"] }"
    ] ++
    (if usesDb uk
     then let sqlxTlsFeature = if sqlxTls == "native-tls" then "runtime-tokio-native-tls" else "runtime-tokio-rustls"
          in [ "sqlx = { version = \"0.8\", features = [\"" ++ sqlxTlsFeature ++ "\", \"" ++ dbFeature dbDriver ++ "\"] }" ]
     else []) ++
    [ "serde_json = \"1\""
    , "sha2 = \"0.10\""
    ] ++
    -- Sub-project A — stdlib kernel crates. Always pulled in because
    -- Project.hs declares the corresponding sky_runtime modules in mod.rs
    -- unconditionally. Mostly small pure-Rust crates; cold-build impact is
    -- modest. When sub-A modules become demand-loaded these can match.
    --
    -- Skip names already declared by the user in [rust.dependencies] — Cargo
    -- errors on duplicate keys, and a user-declared entry takes precedence.
    [ name ++ " = " ++ spec
    | (name, spec) <-
        [ ("regex",            "\"1\"")
        , ("base64",           "\"0.22\"")
        , ("hex",              "\"0.4\"")
        , ("percent-encoding", "\"2\"")
        , ("chrono",           "\"0.4\"")
        , ("chrono-tz",        "\"0.10\"")
        , ("rust_decimal",     "{ version = \"1\", features = [\"serde\"] }")
        , ("hmac",             "\"0.12\"")
        , ("sha1",             "\"0.10\"")
        , ("md-5",             "\"0.10\"")
        , ("subtle",           "\"2\"")
        , ("rsa",              "{ version = \"0.9\", features = [\"sha2\"] }")
        , ("jsonwebtoken",     "\"9\"")
        ]
    , name `notElem` userDepNames
    ] ++
    [ emitDepLine name spec
    | (name, spec) <- rustDeps
    , not (null name)
    ]
  where
    userDepNames = [ n | (n, _) <- rustDeps, not (null n) ]
    dbFeature "postgres" = "postgres"
    dbFeature "mysql"    = "mysql"
    dbFeature _          = "sqlite"
    emitDepLine name (Toml.RustVersion ver feats) =
        if null feats
            then name ++ " = \"" ++ ver ++ "\""
            else name ++ " = { version = \"" ++ ver ++ "\", features = [" ++ intercalate ", " (map show feats) ++ "] }"
    emitDepLine name (Toml.RustGitDep url mRev mBranch mTag) =
        let fields = [ "git = " ++ show url ]
                ++ maybe [] (\r -> ["rev = " ++ show r]) mRev
                ++ maybe [] (\b -> ["branch = " ++ show b]) mBranch
                ++ maybe [] (\t -> ["tag = " ++ show t]) mTag
        in name ++ " = { " ++ intercalate ", " fields ++ " }"

intercalate :: String -> [String] -> String
intercalate _ [] = ""
intercalate _ [x] = x
intercalate s (x:xs) = x ++ s ++ intercalate s xs
