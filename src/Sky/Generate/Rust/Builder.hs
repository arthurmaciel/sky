module Sky.Generate.Rust.Builder where

import Data.List (isSuffixOf, isPrefixOf, stripPrefix, span, sortBy)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Sky.AST.Canonical as Can
import qualified Sky.Sky.ModuleName as ModuleName
import qualified Sky.Reporting.Annotation as Ann
import Data.Char (toLower, toUpper, isUpper)

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
            mconcat
                [ if "Db" `isSuffixOf` modName || modName == "Db"
                  then mempty { usesDb = True } else mempty
                , if modName == "Task" && (fnName == "run" || fnName == "sequence" || fnName == "perform")
                  then mempty { usesTaskRun = True } else mempty
                , if modName == "Task" && fnName == "parallel"
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
    walkDef _ _ = mempty

data RustBuilder = RustBuilder
    { builderModules :: [RustModule]
    , builderTypes   :: [RustTypeDef]
    , builderKernels :: UsedKernels
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

-- | Context threaded through expression emission
data EmitCtx = EmitCtx
    { ecRecordMap :: Map.Map String String  -- field-key -> struct name
    , ecSolvedTypes :: Map.Map String Can.Type  -- function name -> inferred type
    , ecCloneVars :: Set.Set String  -- vars that need .clone() at every use site
    , ecPipeInnerType :: Maybe String  -- inner type of piped Task<A>, set by |>
    , ecUsesTaskRun :: Bool  -- user calls Task.run → main returns ()
    , ecZeroArgDefs :: Set.Set (String, String)  -- (modPrefix, name) for zero-arg definitions
    , ecNoCloneVars :: Set.Set String  -- vars whose types don't implement Clone (e.g. Decoder)
    , ecCtorArity :: Map.Map String Int  -- alias name -> field count (for succeed curry wrapping)
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
-- Main module helpers
knownDefSig _ _ _ = Nothing

listSig :: String -> Int -> Maybe ([String], String)
listSig "map" 2 = Just (["impl Fn(T0) -> T1 + Clone", "Vec<T0>"], "Vec<T1>")
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
        -- sky_main returns SkyTask<()> when the user doesn't use Task.run
        -- (body is the Task, e.g. `main = println "Hello"`).
        -- When Task.run is used, main returns () (side effect is piped through run).
        retTy = if name == "main"
                then if ecUsesTaskRun ctx then "()" else "SkyTask<()>"
                else case Map.lookup name (ecSolvedTypes ctx) of
                    Just ty | not (hasTypeVars (extractReturnType ty)) ->
                        let ret = extractReturnType ty
                        in typeToRustString (ecRecordMap ctx) ret
                    _ ->
                        let bodyInner = taskExprInnerType (ecSolvedTypes ctx) body
                        in if null bodyInner
                           then case knownDefSig modPrefix name n of
                               Just (_, knownRetType) -> knownRetType
                               Nothing -> "()"
                           else "SkyTask<" ++ bodyInner ++ ">"
        -- Track multi-use variables in the function body so they get
        -- cloned at each function-call argument site (ownership safety).
        multiBody = collectVarLocalsMulti body
        multiVars = [ v | (v, c) <- Map.toList multiBody, c >= 2 ]
        ctx' = ctx { ecCloneVars = Set.fromList multiVars }
    in RustFunction rustName genVars paramStrs retTy (exprToRustString ctx' body)
defToRustItem ctx _modPrefix (Can.TypedDef (Ann.At _ name) _ pats body retTy) = 
    let rm = ecRecordMap ctx
        rustName = if name == "main" then "sky_main" else name
        params = map (\(pat, ty) -> patternToRustParam pat ++ ": " ++ typeToRustString rm ty) pats
        ret = if name == "main" then "()" else typeToRustString rm retTy
        multiBody = collectVarLocalsMulti body
        multiVars = [ v | (v, c) <- Map.toList multiBody, c >= 2 ]
        ctx' = ctx { ecCloneVars = Set.fromList multiVars }
    in RustFunction rustName "" params ret (exprToRustString ctx' body)
defToRustItem ctx modPrefix (Can.DestructDef pat expr) =
    let vars = intercalate "_" (patBindingVars pat)
        fnName = if null vars then "__destruct" else "__destruct_" ++ vars
    in RustFunction fnName "" [patternToRustParam pat] "()" (exprToRustString ctx expr)

unionsToRustTypes :: Map.Map String String -> String -> Map.Map String Can.Union -> [RustTypeDef]
unionsToRustTypes recordMap modPrefix unions = map (\(name, u) -> unionToRustTypeDef recordMap modPrefix name u) (Map.toList unions)

unionToRustTypeDef :: Map.Map String String -> String -> String -> Can.Union -> RustTypeDef
unionToRustTypeDef recordMap modPrefix typeName (Can.Union _ alts _ _) = 
    REnumDef (toCamelCase (modPrefix ++ "_" ++ typeName)) (map ctorToRust alts)
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
    _ -> "_"

-- | Walk an expression and collect VarLocal names, counting occurrences.
-- Used to decide which variables need .clone() (those used ≥ 2 times).
-- | Substitute every VarLocal matching a name with an inline string
-- (e.g. `vec![...]`).  Handles common expression forms.  The println
-- special case (Log.println → log_info) is mirrored from exprToRustInner.
substVar :: EmitCtx -> String -> String -> Can.Expr -> String
substVar ctx name inline = go
  where
    go (Ann.At _ expr) = case expr of
        Can.VarLocal n | n == name -> inline
        Can.VarLocal n -> rustSafeIdent n ++ if n `Set.member` ecCloneVars ctx then ".clone()" else ""
        Can.VarTopLevel mod n ->
            let modPrefix = map (\c -> if c == '.' then '_' else c) (ModuleName._name mod)
                fnName = toSnakeCase (modPrefix ++ "_" ++ n)
            in if Set.member (modPrefix, n) (ecZeroArgDefs ctx) then fnName ++ "()" else fnName
        Can.VarKernel mod n ->
            let fnName = kernelToRust mod n
            in if Set.member (mod, n) (ecZeroArgDefs ctx) then fnName ++ "()" else fnName
        Can.VarCtor _ mn tn cn _ -> kernelCtorToRust mn tn cn
        Can.Chr c -> "'" ++ c ++ "'"
        Can.Str s -> show s ++ ".to_string()"
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
                                 (let needClone = Set.member n2 (ecCloneVars ctx)
                                  in if needClone then rustSafeIdent n2 ++ ".clone()" else rustSafeIdent n2)
                             _ -> go a) args
                    in fs ++ "(" ++ intercalate ", " as ++ ")"
        Can.Let def body -> goDef def ++ go body
          where
            goDef (Can.Def (Ann.At _ n) [] dBody) = "let " ++ n ++ " = " ++ go dBody ++ "; "
            goDef (Can.Def (Ann.At _ n) ps dBody) = "let " ++ n ++ " = |" ++ intercalate ", " (map patternToRustParam ps) ++ "| { " ++ go dBody ++ " }; "
            goDef _ = "_ = unimplemented(); "
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
        Can.Record _ -> exprToRustString ctx (Ann.At (error "substVar span") expr)
        Can.Tuple _ _ _ -> exprToRustString ctx (Ann.At (error "substVar span") expr)
        Can.Access _ _ -> exprToRustString ctx (Ann.At (error "substVar span") expr)
        Can.Accessor _ -> exprToRustString ctx (Ann.At (error "substVar span") expr)
        Can.Update _ _ _ -> exprToRustString ctx (Ann.At (error "substVar span") expr)

collectVarLocalsMulti :: Can.Expr -> Map.Map String Int
collectVarLocalsMulti = go Set.empty
  where
    go bound (Ann.At _ expr) = case expr of
        Can.VarLocal n | n `Set.notMember` bound -> Map.singleton n 1
        Can.VarLocal _ -> Map.empty
        Can.Call fn args -> Map.unionsWith (+) (go bound fn : map (go bound) args)
        Can.Lambda params body ->
            let bound' = foldl (\s p -> case p of { Ann.At _ (Can.PVar n) -> Set.insert n s; _ -> s }) bound params
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
            let bound' = foldl (\s p -> case p of { Ann.At _ (Can.PVar n) -> Set.insert n s; _ -> s }) bound params
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
        let paramNames = Set.fromList [ n | Ann.At _ p <- ps, let n = case p of Can.PVar s -> s; _ -> "_" ]
            captured = Set.toList (Set.difference (collectVarLocals body) paramNames)
            clones = concatMap (\v -> "let " ++ v ++ " = " ++ v ++ ".clone(); ") captured
            innerCounts = collectVarLocalsMulti body
            innerMulti = [ v | (v, c) <- Map.toList innerCounts, c >= 2 ]
            ctx' = ctx { ecCloneVars = Set.fromList innerMulti }
            annot = case ecPipeInnerType ctx of
                Just t | length ps == 1 -> ": " ++ t
                _ -> ""
            psStr = intercalate ", " (map (\p -> patternToRustParam p ++ annot) ps)
        in if null captured
           then "move |" ++ psStr ++ "| { " ++ exprToRustString ctx' body ++ " }"
           else "{ " ++ clones ++ "move |" ++ psStr ++ "| { " ++ exprToRustString ctx' body ++ " } }"
    Can.VarLocal n ->
        let needsClone = (not noCloneFn) && (n `Set.member` ecCloneVars ctx)
        in if needsClone then rustSafeIdent n ++ ".clone()" else rustSafeIdent n
    _ -> exprToRustString ctx (Ann.At Ann.one a)

exprToRustString :: EmitCtx -> Can.Expr -> String
exprToRustString ctx (Ann.At _ expr) = exprToRustInner ctx expr

exprToRustInner :: EmitCtx -> Can.Expr_ -> String
exprToRustInner ctx e = case e of
    Can.VarLocal name -> rustSafeIdent name ++ if name `Set.member` ecCloneVars ctx then ".clone()" else ""
    Can.VarTopLevel mod name ->
        let modPrefix = map (\c -> if c == '.' then '_' else c) (ModuleName._name mod)
            fnName = toSnakeCase (modPrefix ++ "_" ++ name)
        in if Set.member (modPrefix, name) (ecZeroArgDefs ctx) then fnName ++ "()" else fnName
    Can.VarKernel mod name ->
        let fnName = kernelToRust mod name
        in if Set.member (mod, name) (ecZeroArgDefs ctx) then fnName ++ "()" else fnName
    Can.VarCtor _ modName typeName ctorName _ -> kernelCtorToRust modName typeName ctorName
    Can.Chr c -> "'" ++ c ++ "'"
    Can.Str s -> show s ++ ".to_string()"
    Can.Int i -> show i
    Can.Float f -> show f
    Can.List es -> "vec![" ++ intercalate ", " (map (exprToRustString ctx) es) ++ "]"
    Can.Negate e -> "-" ++ exprToRustString ctx e
    Can.Binop op _ _ _ a b 
        | op == "|>" ->
            let inner = taskExprInnerType (ecSolvedTypes ctx) a
                ctx' = ctx { ecPipeInnerType = if null inner then Nothing else Just inner }
            in exprToRustString ctx' b ++ "(" ++ exprToRustString ctx a ++ ")"
        | op == "<|" -> exprToRustString ctx a ++ "(" ++ exprToRustString ctx b ++ ")"
        | op == "::" -> "sky_list_cons(" ++ exprToRustString ctx a ++ ", " ++ exprToRustString ctx b ++ ")"
        | op == "++" -> "format!(\"{}{}\", " ++ exprToRustString ctx a ++ ", " ++ exprToRustString ctx b ++ ")"
        | otherwise -> 
            "(" ++ exprToRustString ctx a ++ " " ++ binopToRust op ++ " " ++ exprToRustString ctx b ++ ")"
    Can.Lambda params body -> 
        let counts = collectVarLocalsMulti body
            innerMulti = [ v | (v, c) <- Map.toList counts, c >= 2 ]
            ctx' = ctx { ecCloneVars = Set.fromList innerMulti }
        in "|" ++ intercalate ", " (map patternToRustParam params) ++ "| { " ++ exprToRustString ctx' body ++ " }"
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
                            ctx' = ctx { ecCloneVars = Set.fromList innerMulti }
                            psStr = intercalate ", " (map patternToRustParam params)
                        in calleeName ++ "(curry" ++ show n ++ "(|" ++ psStr ++ "| { " ++ exprToRustString ctx' body ++ " }))"
                    _ ->
                        calleeName ++ "(curry" ++ show n ++ "(" ++ exprToRustString ctx arg ++ "))"
            Nothing -> case calleeName of
                fn | "println" `isSuffixOf` fn ->
                    "log_info(" ++ intercalate " ++ \" \" ++ " (map (\a -> exprToRustString ctx a) args) ++ ")"
                _ ->
                    -- Clone VarLocal args for every function call EXCEPT Task_run,
                    -- whose argument is a Pin<Box<dyn Future>> which does not implement Clone.
                    let noCloneFn = case fn of
                            Ann.At _ (Can.VarKernel _ n) -> n == "run"
                            _ -> False
                        -- json_dec_list wraps the decoder in a factory closure so each
                        -- list element gets a fresh decoder (json_dec_succeed is single-use).
                        isListDec = "json_dec_list" `isSuffixOf` calleeName
                        argsStrs = if isListDec && not (null args)
                                   then ("|| " ++ argToRustString ctx noCloneFn (head args)) : map (argToRustString ctx noCloneFn) (tail args)
                                   else map (argToRustString ctx noCloneFn) args
                    in exprToRustString ctx fn ++ "(" ++ intercalate ", " argsStrs ++ ")"
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
    Can.Call (Ann.At _ (Can.VarKernel modName fnName)) args
        | "Task" `isSuffixOf` modName || modName == "Task" -> case fnName of
            "succeed"  -> case args of
                [arg] -> solveArgType solved arg
                _ -> "String"
            "fail"     -> "()"
            "map"      -> "String"
            "andThen"  -> "String"
            "onError"  -> "String"
            _ -> ""
        | "Db" `isSuffixOf` modName || modName == "Db" -> case fnName of
            "query"    -> "Vec<HashMap<String, String>>"
            "exec"     -> "()"
            "execRaw"  -> "()"
            "connect"  -> "Db"
            "getField" -> "String"
            _ -> ""
        | "System" `isSuffixOf` modName || modName == "System" -> case fnName of
            "args"        -> "Vec<String>"
            "exit"        -> "()"
            "setenv"      -> "()"
            "unsetenv"    -> "()"
            _ -> ""
        | "Log" `isSuffixOf` modName || modName == "Log" -> "()"
        | "Time" `isSuffixOf` modName || modName == "Time" -> case fnName of
            "now"       -> "i64"
            "sleep"     -> "()"
            "unixMillis" -> "i64"
            _ -> ""
        | "Random" `isSuffixOf` modName || modName == "Random" -> case fnName of
            "int"    -> "i64"
            "float"  -> "f64"
            "choice" -> "String"
            _ -> ""
        | "Crypto" `isSuffixOf` modName || modName == "Crypto" -> case fnName of
            "randomBytes"  -> "Vec<i64>"
            "randomToken"  -> "String"
            _ -> ""
        | "File" `isSuffixOf` modName || modName == "File" -> case fnName of
            "readFile"  -> "String"
            "writeFile" -> "()"
            "exists"    -> "bool"
            _ -> ""
    -- Fallback: look up the callee's type in solvedTypes and extract Task inner type
    Can.VarTopLevel modName name ->
        case Map.lookup name solved of
            Just ty -> typeToRustString Map.empty (extractTaskInner (extractReturnType ty))
            Nothing -> ""
    _ -> ""
  where
    extractTaskInner (Can.TType _ "Task" [_, a]) = a
    extractTaskInner _ = Can.TVar "_"
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
    in if null prefix
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

buildProgram :: [Can.Module] -> Map.Map String Can.Type -> RustBuilder
buildProgram mods solvedTypes = 
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

        ctx = EmitCtx { ecRecordMap = recordMap, ecSolvedTypes = solvedTypes, ecCloneVars = Set.empty, ecPipeInnerType = Nothing, ecUsesTaskRun = usesTaskRun usage, ecZeroArgDefs = zeroArgDefs, ecNoCloneVars = noCloneVars, ecCtorArity = ctorArity }
        usage = analyzeKernelUsage mods
        zeroArgDefs = collectZeroArgDefs mods
        noCloneVars = Set.empty
        existingTypes = concatMap (\m -> 
            let prefix = moduleNameToRust (Can._name m)
            in unionsToRustTypes recordMap prefix (Can._unions m) ++ aliasesToRustTypes recordMap prefix (Can._aliases m)) mods
    in RustBuilder
        { builderModules = map (buildModule ctx) mods
        , builderTypes = existingTypes ++ anonDefs
        , builderKernels = usage
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

emitRust :: RustBuilder -> String -> String -> String
emitRust b dbPath dbDriver = unlines $ concat
    [ headerSection
    , importSection (builderKernels b) dbDriver
    , basicTypeSection
    , coreHelperSection
    , userTypeSection b
    , skyErrorLine b
    , taskSection (builderKernels b)
    , dbSection (builderKernels b) dbPath dbDriver b
    , systemHelperSection
    , logHelperSection
    , jsonSection (builderKernels b)
    , extraKernelSection (builderKernels b) b
    , miscHelperSection
    , userModuleSection b
    , ffiPlaceholderSection b
    , entryPointSection (builderKernels b)
    ]

-- | Header and file-level attributes
headerSection :: [String]
headerSection =
    [ "// Generated by Sky compiler (Rust target)"
    , "#![allow(unused, non_snake_case)]"
    , ""
    , "mod sky_runtime;"
    , "use sky_runtime::*;"
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

-- | Core types and helpers (only SkyError-dependent parts — the rest are in sky_runtime crate)
coreHelperSection :: [String]
coreHelperSection =
    [ ""
    , "// Error type for Task (also used as SkyError default)"
    , "pub struct Error(pub String);"
    , ""
    , "// Helper: construct Ok with implicit SkyError type"
    , "pub fn ok_res<A>(a: A) -> SkyResult<SkyError, A> { SkyResult::Ok(a) }"
    , ""
    ]

-- | Basic type aliases (always emitted)
basicTypeSection :: [String]
basicTypeSection =
    [ ""
    , "// Basic types"
    , "type SkyInt = i64;"
    , "type SkyFloat = f64;"
    , "type SkyBool = bool;"
    , "type SkyString = String;"
    , ""
    ]

-- | Task combinators — conditional on usage
taskSection :: UsedKernels -> [String]
taskSection uk =
    let needsTokio = usesTaskRun uk || usesTaskParallel uk || usesDb uk
    in
    [ ""
    , "// ==========================================="
    , "// TASK HELPERS"
    , "// ==========================================="
    ] ++
    (if needsTokio
     then
        [ ""
        , "// --- Tokio runtime glue (only when Task.run, Task.parallel, or Db is used) ---"
        , "fn block_on<F: Future + Send + 'static>(future: F) -> F::Output where F::Output: Send + 'static {"
        ,         "    std::thread::spawn(move || Runtime::new().unwrap().block_on(future))"
        , "        .join().expect(\"Internal error: async task panicked\")"
        , "}"
        ]
     else []) ++
    [ ""
    , "// --- Task type (unified error type = SkyError) ---"
    , "type SkyTask<A> = Pin<Box<dyn Future<Output = SkyResult<SkyError, A>> + Send + 'static>>;"
    , ""
    , "// --- Task combinators (std::future only, no tokio needed) ---"
    , "pub fn task_succeed<A: Send + 'static>(a: A) -> SkyTask<A> {"
    , "    Box::pin(ready(ok_res(a)))"
    , "}"
    , "pub fn task_map<A: Send + 'static, B: Send + 'static>("
    , "    f: impl FnOnce(A) -> B + Send + 'static,"
    , ") -> impl FnOnce(SkyTask<A>) -> SkyTask<B> + Send + 'static {"
    , "    |task| Box::pin(async move {"
    , "        match task.await {"
    , "            SkyResult::Ok(a) => ok_res(f(a)),"
    , "            SkyResult::Err(e) => SkyResult::Err(e),"
    , "        }"
    , "    })"
    , "}"
    , "pub fn task_and_then<A: Send + 'static, B: Send + 'static>("
    , "    f: impl FnOnce(A) -> SkyTask<B> + Send + 'static,"
    , ") -> impl FnOnce(SkyTask<A>) -> SkyTask<B> + Send + 'static {"
    , "    |task| Box::pin(async move {"
    , "        match task.await {"
    , "            SkyResult::Ok(a) => f(a).await,"
    , "            SkyResult::Err(e) => SkyResult::Err(e),"
    , "        }"
    , "    })"
    , "}"
    , "pub fn task_on_error<A: Send + 'static>("
    , "    f: impl FnOnce(SkyError) -> SkyTask<A> + Send + 'static,"
    , ") -> impl FnOnce(SkyTask<A>) -> SkyTask<A> + Send + 'static {"
    , "    |task| Box::pin(async move {"
    , "        match task.await {"
    , "            SkyResult::Ok(a) => ok_res(a),"
    , "            SkyResult::Err(e) => f(e).await,"
    , "        }"
    , "    })"
    , "}"
    , "pub fn task_fail<A: Send + 'static>(e: SkyError) -> SkyTask<A> {"
    , "    Box::pin(ready(SkyResult::Err(e)))"
    , "}"
    , "pub fn task_perform<A: Send + 'static>(task: SkyTask<A>) -> SkyTask<()> {"
    , "    Box::pin(async move { match task.await { SkyResult::Ok(_) => ok_res(()), SkyResult::Err(e) => SkyResult::Err(e) } })"
    , "}"
    , "pub fn task_sequence<A: Send + 'static>(tasks: Vec<SkyTask<A>>) -> SkyTask<Vec<A>> {"
    , "    Box::pin(async move {"
    , "        let mut out = Vec::with_capacity(tasks.len());"
    , "        for t in tasks { match t.await { SkyResult::Ok(a) => out.push(a), SkyResult::Err(e) => return SkyResult::Err(e) } }"
    , "        ok_res(out)"
    , "    })"
    , "}"
    ] ++
    (if needsTokio
     then
        [ "pub fn task_run<A: Send + 'static>(task: SkyTask<A>) -> SkyResult<SkyError, A> {"
        , "    block_on(task)"
        , "}"
        ]
     else []) ++
    (if usesTaskParallel uk
     then
        [ "// --- Parallel execution (tokio::spawn, ~Go goroutines) ---"
        , "pub fn task_parallel<A: Send + 'static>(tasks: Vec<SkyTask<A>>) -> SkyTask<Vec<A>> {"
        , "    Box::pin(async move {"
        , "        let handles: Vec<tokio::task::JoinHandle<SkyResult<SkyError, A>>> ="
        , "            tasks.into_iter().map(|t| tokio::spawn(t)).collect();"
        , "        let mut out = Vec::with_capacity(handles.len());"
        , "        for h in handles {"
        ,             "            match h.await.expect(\"Internal error: parallel task panicked\") {"
        , "                SkyResult::Ok(a) => out.push(a),"
        , "                SkyResult::Err(e) => return SkyResult::Err(e),"
        , "            }"
        , "        }"
        , "        ok_res(out)"
        , "    })"
        , "}"
        ]
     else [])

-- | DB runtime — conditional on usage, backend-specific types (no AnyPool)
dbSection :: UsedKernels -> String -> String -> RustBuilder -> [String]
dbSection uk dbPath dbDriver b =
    if not (usesDb uk) then [] else
    let _poolT = dbPoolType dbDriver
        _rowT  = dbRowType dbDriver
    in
    [ ""
    , "// ==========================================="
    , "// DB runtime (sqlx-backed, backend: " ++ dbDriver ++ ")"
    , "// ==========================================="
    , "type Db = DbPool;"
    ] ++
    [ if hasErrorType b
        then unlines
            [ "fn sky_err(e: &sqlx::Error) -> SkyError {"
            , "    let msg = format!(\"{}\", e);"
            , "    let kind = match e {"
            , "        sqlx::Error::Io(io) => {"
            , "            let s = format!(\"{}\", io);"
            , "            if s.contains(\"refused\") || s.contains(\"Connection refused\") { " ++ toCamelCase "Sky_Core_Error_ErrorKind" ++ "::Network }"
            , "            else { " ++ toCamelCase "Sky_Core_Error_ErrorKind" ++ "::Io }"
            , "        }"
            , "        sqlx::Error::Database(db) => {"
            , "            let code = db.code().map(|c| c.to_string()).unwrap_or_default();"
            , "            if code == \"2067\" || code == \"1555\" || code == \"23505\" || code == \"1062\" || msg.contains(\"UNIQUE constraint\") {"
            , "                " ++ toCamelCase "Sky_Core_Error_ErrorKind" ++ "::Conflict"
            , "            } else { " ++ toCamelCase "Sky_Core_Error_ErrorKind" ++ "::Unexpected }"
            , "        }"
            , "        sqlx::Error::PoolTimedOut => " ++ toCamelCase "Sky_Core_Error_ErrorKind" ++ "::Timeout,"
            , "        sqlx::Error::PoolClosed  => " ++ toCamelCase "Sky_Core_Error_ErrorKind" ++ "::Unavailable,"
            , "        sqlx::Error::Tls(_)     => " ++ toCamelCase "Sky_Core_Error_ErrorKind" ++ "::Network,"
            , "        _ => " ++ toCamelCase "Sky_Core_Error_ErrorKind" ++ "::Unexpected,"
            , "    };"
            , "    " ++ toCamelCase "Sky_Core_Error_Error" ++ "::Error(kind, " ++ toCamelCase "Sky_Core_Error_ErrorInfo" ++ " { details: SkyMaybe::Nothing, message: msg })"
            , "}"
            ]
        else "fn sky_err(e: &sqlx::Error) -> SkyError { format!(\"{}\", e) }"
    ] ++ [ ""
    , "// Build a SQL string by replacing ? with escaped param values."
    , "fn build_sql(sql: &str, params: &[String]) -> String {"
    , "    let mut result = String::new();"
    , "    let mut remaining = sql;"
    , "    for p in params {"
    , "        if let Some(pos) = remaining.find('?') {"
    , "            result.push_str(&remaining[..pos]);"
    , "            result.push('\\'');"
    , "            result.push_str(&p.replace('\\'', \"''\"));"
    , "            result.push('\\'');"
    , "            remaining = &remaining[pos + 1..];"
    , "        }"
    , "    }"
    , "    result.push_str(remaining);"
    , "    result"
    , "}"
    , ""
    , "// Convert a DbRow to HashMap<String, String>"
    , "fn row_to_map(row: &DbRow) -> HashMap<String, String> {"
    , "    let mut map = HashMap::new();"
    , "    let cols = row.columns();"
    , "    for i in 0..cols.len() {"
    , "        let name = cols[i].name().to_string();"
    , "        let value: String = match row.try_get::<Option<String>, _>(i) {"
    , "            Ok(Some(v)) => v,"
    , "            Ok(None) => String::new(),"
    , "            _ => match row.try_get::<Option<i64>, _>(i) {"
    , "                Ok(Some(v)) => v.to_string(),"
    , "                _ => match row.try_get::<Option<f64>, _>(i) {"
    , "                    Ok(Some(v)) => v.to_string(),"
    , "                    _ => String::new(),"
    , "                }"
    , "            }"
    , "        };"
    , "        map.insert(name, value);"
    , "    }"
    , "    map"
    , "}"
    , ""
    , "const SKY_DB_URL: &str = " ++ show dbPath ++ ";"
    , ""
    , "// DB kernel functions"
    , "pub fn db_connect(_unit: ()) -> SkyTask<Db> {"
    , "    Box::pin(async move {"
    , "        match DbPool::connect(SKY_DB_URL).await {"
    , "            Ok(pool) => ok_res(pool),"
    , "            Err(e) => SkyResult::Err(sky_err(&e)),"
    , "        }"
    , "    })"
    , "}"
    , "pub fn db_exec_raw(conn: Db, sql: String) -> SkyTask<()> {"
    , "    Box::pin(async move {"
    , "        match sqlx::query(&sql).execute(&conn).await {"
    , "            Ok(_) => ok_res(()),"
    , "            Err(e) => SkyResult::Err(sky_err(&e)),"
    , "        }"
    , "    })"
    , "}"
    , "pub fn db_exec(conn: Db, sql: String, params: Vec<String>) -> SkyTask<()> {"
    , "    Box::pin(async move {"
    , "        let final_sql = build_sql(&sql, &params);"
    , "        match sqlx::query(&final_sql).execute(&conn).await {"
    , "            Ok(_) => ok_res(()),"
    , "            Err(e) => SkyResult::Err(sky_err(&e)),"
    , "        }"
    , "    })"
    , "}"
    , "pub fn db_query(conn: Db, sql: String, params: Vec<String>) -> SkyTask<Vec<HashMap<String, String>>> {"
    , "    Box::pin(async move {"
    , "        let final_sql = build_sql(&sql, &params);"
    , "        match sqlx::query(&final_sql).fetch_all(&conn).await {"
    , "            Ok(rows) => {"
    , "                let result: Vec<HashMap<String, String>> = rows.iter().map(|r| row_to_map(r)).collect();"
    , "                ok_res(result)"
    , "            },"
    , "            Err(e) => SkyResult::Err(sky_err(&e)),"
    , "        }"
    , "    })"
    , "}"
    , "// Alias: Db.open is the same as Db.connect"
    , "pub fn db_open(_unit: ()) -> SkyTask<Db> { db_connect(_unit) }"
    , "pub fn db_open_with_path(path: String) -> SkyTask<Db> {"
    , "    Box::pin(async move { match DbPool::connect(&path).await {"
    , "        Ok(pool) => ok_res(pool),"
    , "        Err(e) => SkyResult::Err(sky_err(&e)),"
    , "    } })"
    , "}"
    , ""
    , "pub fn db_get_field(field: String, row: HashMap<String, String>) -> String {"
    , "    row.get(&field).cloned().unwrap_or_default()"
    , "}"
    , "pub fn db_get_field_or_null(field: String, row: HashMap<String, String>) -> SkyMaybe<String> {"
    , "    match row.get(&field) { Some(v) => SkyMaybe::Just(v.clone()), None => SkyMaybe::Nothing }"
    , "}"
    ]

-- | System helpers (always emitted — no external deps)
systemHelperSection :: [String]
systemHelperSection =
    [ ""
    , "// System helpers"
    , "pub fn system_args(_: ()) -> SkyTask<Vec<String>> { Box::pin(ready(ok_res(std::env::args().skip(1).collect()))) }"
    , "pub fn system_exit(code: i64) -> ! { std::process::exit(code as i32) }"
    , "pub fn system_setenv(name: String, value: String) -> SkyTask<()> {"
    , "    std::env::set_var(&name, &value); Box::pin(ready(ok_res(())))"
    , "}"
    , "pub fn system_unsetenv(name: String) -> SkyTask<()> {"
    , "    std::env::remove_var(&name); Box::pin(ready(ok_res(())))"
    , "}"
    ]

-- | Log helpers (always emitted — just println!)
logHelperSection :: [String]
logHelperSection =
    [ ""
    , "// Log helpers"
    , "pub fn log_info(msg: String) -> SkyTask<()> {"
    , "    println!(\"{}\", msg); Box::pin(ready(ok_res(())))"
    , "}"
    , ""
    , "// Format attrs list [k,v,k,v,...] into \" key=value\" segments"
    , "fn fmt_attrs(attrs: &[String]) -> String {"
    , "    let mut out = String::new();"
    , "    let mut i = 0;"
    , "    while i + 1 < attrs.len() {"
    , "        out.push(' ');"
    , "        out.push_str(&attrs[i]);"
    , "        out.push('=');"
    , "        out.push_str(&attrs[i + 1]);"
    , "        i += 2;"
    , "    }"
    , "    out"
    , "}"
    , ""
    , "pub fn log_info_with(msg: String, attrs: Vec<String>) -> SkyTask<()> {"
    , "    println!(\"{}{}\", msg, fmt_attrs(&attrs)); Box::pin(ready(ok_res(())))"
    , "}"
    , "pub fn log_error_with(msg: String, attrs: Vec<String>) -> SkyTask<()> {"
    , "    eprintln!(\"{}{}\", msg, fmt_attrs(&attrs)); Box::pin(ready(ok_res(())))"
    , "}"
    , ""
    , "pub fn log_debug(msg: String) -> SkyTask<()> {"
    , "    eprintln!(\"{}\", msg); Box::pin(ready(ok_res(())))"
    , "}"
    , "pub fn log_warn(msg: String) -> SkyTask<()> {"
    , "    eprintln!(\"{}\", msg); Box::pin(ready(ok_res(())))"
    , "}"
    ]

-- | Misc helpers + Debug impl
-- | JSON encode/decode stubs (serde_json-backed)
jsonSection :: UsedKernels -> [String]
jsonSection uk =
    if not (usesJson uk) then [] else
    [ ""
    , "// ==========================================="
    , "// JSON helpers (serde_json-backed)"
    , "// ==========================================="
    , "type JsonVal = serde_json::Value;"
    , "type Decoder<T> = Box<dyn Fn(&JsonVal) -> SkyResult<SkyError, T> + Send>;"
    , ""
    , "fn json_dec_ok<T>(t: T) -> SkyResult<SkyError, T> { SkyResult::Ok(t) }"
    , "fn json_dec_err_str<T>(s: String) -> SkyResult<SkyError, T> { SkyResult::Err(str_err(&s)) }"
    , ""
    , "// --- Encode ---"
    , "pub fn json_enc_encode(indent: i64, val: JsonVal) -> String {"
    , "    if indent > 0 { serde_json::to_string_pretty(&val).unwrap_or_default() }"
    , "    else { serde_json::to_string(&val).unwrap_or_default() }"
    , "}"
    , "pub fn json_enc_string(s: String) -> JsonVal { JsonVal::String(s) }"
    , "pub fn json_enc_int(i: i64) -> JsonVal { JsonVal::Number(i.into()) }"
    , "pub fn json_enc_float(f: f64) -> JsonVal { JsonVal::from(f) }"
    , "pub fn json_enc_bool(b: bool) -> JsonVal { JsonVal::Bool(b) }"
    , "pub fn json_enc_null(_: ()) -> JsonVal { JsonVal::Null }"
    , "pub fn json_enc_list<A>(f: impl Fn(A) -> JsonVal, items: Vec<A>) -> JsonVal {"
    , "    JsonVal::Array(items.into_iter().map(|x| f(x)).collect())"
    , "}"
    , "pub fn json_enc_object(pairs: Vec<(String, JsonVal)>) -> JsonVal {"
    , "    JsonVal::Object(pairs.into_iter().collect())"
    , "}"
    , ""
    , "// --- Decode primitives ---"
    , "pub fn json_dec_string() -> Decoder<String> {"
    , "    Box::new(|v| match v { JsonVal::String(s) => json_dec_ok(s.clone()), _ => json_dec_err_str(\"expected string\".into()) })"
    , "}"
    , "pub fn json_dec_int() -> Decoder<i64> {"
    , "    Box::new(|v| match v.as_i64() { Some(i) => json_dec_ok(i), None => json_dec_err_str(\"expected int\".into()) })"
    , "}"
    , "pub fn json_dec_float() -> Decoder<f64> {"
    , "    Box::new(|v| match v.as_f64() { Some(f) => json_dec_ok(f), None => json_dec_err_str(\"expected float\".into()) })"
    , "}"
    , "pub fn json_dec_bool() -> Decoder<bool> {"
    , "    Box::new(|v| match v.as_bool() { Some(b) => json_dec_ok(b), None => json_dec_err_str(\"expected bool\".into()) })"
    , "}"
    , "pub fn json_dec_null<A: Default + Send>() -> Decoder<A> {"
    , "    Box::new(|v| match v { JsonVal::Null => json_dec_ok(A::default()), _ => json_dec_err_str(\"expected null\".into()) })"
    , "}"
    , ""
    , "// --- Decode combinators ---"
    , "pub fn json_dec_field<T: 'static + Send>(name: String, decoder: Decoder<T>) -> Decoder<T> {"
    , "    Box::new(move |v| match v.get(&name) { Some(field) => decoder(field), None => json_dec_err_str(format!(\"missing field: {}\", name)) })"
    , "}"
    , "pub fn json_dec_at<T: 'static + Send>(path: Vec<String>, decoder: Decoder<T>) -> Decoder<T> {"
    , "    Box::new(move |v| {"
    , "        let mut cur = v;"
    , "        for key in &path { match cur.get(key) { Some(n) => cur = n, None => return json_dec_err_str(format!(\"missing path: {}\", key)) } }"
    , "        decoder(cur)"
    , "    })"
    , "}"
    , "pub fn json_dec_list<T: 'static + Send>(decoder: impl Fn() -> Decoder<T> + Send + 'static) -> Decoder<Vec<T>> {"
    , "    Box::new(move |v| match v.as_array() {"
    , "        Some(arr) => {"
    , "            let mut out = Vec::with_capacity(arr.len());"
    , "            for item in arr { let d = decoder(); match d(item) { SkyResult::Ok(t) => out.push(t), SkyResult::Err(_) => return json_dec_err_str(\"decode error\".into()) } }"
    , "            json_dec_ok(out)"
    , "        },"
    , "        None => json_dec_err_str(\"expected array\".into())"
    , "    })"
    , "}"
    , "pub fn json_dec_map<A: 'static + Send, B: 'static + Send>(f: impl Fn(A) -> B + Send + 'static, decoder: Decoder<A>) -> Decoder<B> {"
    , "    Box::new(move |v| match decoder(v) { SkyResult::Ok(a) => json_dec_ok(f(a)), SkyResult::Err(_) => json_dec_err_str(\"map error\".into()) })"
    , "}"
    , "pub fn json_dec_map2<A: 'static + Send, B: 'static + Send, C: 'static + Send>("
    , "    f: impl Fn(A, B) -> C + Send + 'static, da: Decoder<A>, db: Decoder<B>"
    , ") -> Decoder<C> {"
    , "    Box::new(move |v| { let a = da(v); let b = db(v); match a { SkyResult::Ok(av) => match b { SkyResult::Ok(bv) => json_dec_ok(f(av, bv)), SkyResult::Err(_) => json_dec_err_str(\"decode error\".into()) }, SkyResult::Err(_) => json_dec_err_str(\"decode error\".into()) } })"
    , "}"
    , "pub fn json_dec_succeed<A: 'static + Send>(a: A) -> Decoder<A> {"
    , "    let cell = std::cell::RefCell::new(Some(a));"
    , "    Box::new(move |_| {"
    , "        cell.borrow_mut().take().map(SkyResult::Ok).unwrap_or_else(|| {"
    , "        SkyResult::Err(str_err(\"Internal compiler error: a Decode.succeed value was consumed twice. This should not happen — please file a bug report.\".into()))"
    , "        })"
    , "    })"
    , "}"
    , "pub fn json_dec_fail<A: 'static + Send>(msg: String) -> Decoder<A> {"
    , "    let m = msg; Box::new(move |_| json_dec_err_str(m.clone()))"
    , "}"
    , "pub fn json_dec_one_of<T: 'static + Send>(decoders: Vec<Decoder<T>>) -> Decoder<T> {"
    , "    Box::new(move |v| { for d in &decoders { let r = d(v); if r.is_ok() { return r; } } json_dec_err_str(\"oneOf: no match\".into()) })"
    , "}"
    , "pub fn json_dec_decode_string<T>(decoder: Decoder<T>, json: String) -> SkyResult<SkyError, T> {"
    , "    match serde_json::from_str(&json) {"
    , "        Ok(val) => decoder(&val),"
    , "        Err(e) => json_dec_err_str(format!(\"json parse: {}\", e))"
    , "    }"
    , "}"
    , ""
    , "// --- Currying helpers (for pipeline decoder composition) ---"
    , "fn curry1<A, R, F: FnOnce(A) -> R + Send + 'static>(f: F) -> Box<dyn FnOnce(A) -> R + Send> {"
    , "    Box::new(f)"
    , "}"
    , "fn curry2<A1: 'static + Send, A2: 'static + Send, R: 'static, F: FnOnce(A1, A2) -> R + Send + 'static>("
    , "    f: F,"
    , ") -> Box<dyn FnOnce(A1) -> Box<dyn FnOnce(A2) -> R + Send> + Send> {"
    , "    Box::new(move |a1| Box::new(move |a2| f(a1, a2)))"
    , "}"
    , "fn curry3<A1: 'static + Send, A2: 'static + Send, A3: 'static + Send, R: 'static, F: FnOnce(A1, A2, A3) -> R + Send + 'static>("
    , "    f: F,"
    , ") -> Box<dyn FnOnce(A1) -> Box<dyn FnOnce(A2) -> Box<dyn FnOnce(A3) -> R + Send> + Send> + Send> {"
    , "    Box::new(move |a1| Box::new(move |a2| Box::new(move |a3| f(a1, a2, a3))))"
    , "}"
    , "fn curry4<A1: 'static + Send, A2: 'static + Send, A3: 'static + Send, A4: 'static + Send, R: 'static, F: FnOnce(A1, A2, A3, A4) -> R + Send + 'static>("
    , "    f: F,"
    , ") -> Box<dyn FnOnce(A1) -> Box<dyn FnOnce(A2) -> Box<dyn FnOnce(A3) -> Box<dyn FnOnce(A4) -> R + Send> + Send> + Send> + Send> {"
    , "    Box::new(move |a1| Box::new(move |a2| Box::new(move |a3| Box::new(move |a4| f(a1, a2, a3, a4)))))"
    , "}"
    , "fn curry5<A1: 'static + Send, A2: 'static + Send, A3: 'static + Send, A4: 'static + Send, A5: 'static + Send, R: 'static, F: FnOnce(A1, A2, A3, A4, A5) -> R + Send + 'static>("
    , "    f: F,"
    , ") -> Box<dyn FnOnce(A1) -> Box<dyn FnOnce(A2) -> Box<dyn FnOnce(A3) -> Box<dyn FnOnce(A4) -> Box<dyn FnOnce(A5) -> R + Send> + Send> + Send> + Send> + Send> {"
    , "    Box::new(move |a1| Box::new(move |a2| Box::new(move |a3| Box::new(move |a4| Box::new(move |a5| f(a1, a2, a3, a4, a5))))))"
    , "}"
    , ""
    , "// --- Pipeline (curried decoder combinators) ---"
    , "pub fn json_dec_p_required<T: 'static, F: 'static>(name: String, decoder: Decoder<T>) -> impl FnOnce(Decoder<Box<dyn FnOnce(T) -> F + Send>>) -> Decoder<F> {"
    , "    move |next_decoder| {"
    , "        let n = name; let d = decoder; let nd = next_decoder;"
    , "        Box::new(move |v| {"
    , "            let field_val = match v.get(&n) { Some(f) => match d(f) { SkyResult::Ok(t) => t, _ => return json_dec_err_str(\"required decode error\".into()) }, None => return json_dec_err_str(format!(\"missing required: {}\", n)) };"
    , "            match nd(v) { SkyResult::Ok(f) => ok_res(f(field_val)), _ => json_dec_err_str(\"next decode error\".into()) }"
    , "        })"
    , "    }"
    , "}"
    , "pub fn json_dec_p_optional<T: Clone + 'static + Send, F: 'static>(name: String, decoder: Decoder<T>, default: T) -> impl FnOnce(Decoder<Box<dyn FnOnce(T) -> F + Send>>) -> Decoder<F> {"
    , "    move |next_decoder| {"
    , "        let n = name; let d = decoder; let nd = next_decoder; let def = default;"
    , "        Box::new(move |v| {"
    , "            let field_val = match v.get(&n) { Some(val) => match d(val) { SkyResult::Ok(t) => t, _ => def.clone() }, None => def.clone() };"
    , "            match nd(v) { SkyResult::Ok(f) => SkyResult::Ok(f(field_val)), _ => json_dec_err_str(\"opt next error\".into()) }"
    , "        })"
    , "    }"
    , "}"

    ]

-- | Extra kernel stubs: Time, Random, File, Crypto (std-only, no extra deps)
extraKernelSection :: UsedKernels -> RustBuilder -> [String]
extraKernelSection uk b =
    concat
    [ [ ""
      , "// ==========================================="
      , "// EXTRA KERNEL STUBS (Time, Random, File, Crypto)"
      , "// ==========================================="
      , "" ]
    ++ (if usesTime uk then timeSection else [])
    ++ (if usesRandom uk then randomSection else [])
    ++ (if usesFile uk then fileSection else [])
    ++ (if usesCrypto uk then cryptoSections else [])
    ]

-- | Time kernel stubs (→ usesTime)
timeSection :: [String]
timeSection = [ "// --- Time ---"
    , "pub fn time_now(_: ()) -> SkyTask<i64> {"
    , "    let ms = std::time::SystemTime::now()"
    , "        .duration_since(std::time::UNIX_EPOCH)"
    , "        .unwrap_or_default()"
    , "        .as_millis() as i64;"
    , "    Box::pin(ready(ok_res(ms)))"
    , "}"
    , "pub fn time_sleep(ms: i64) -> SkyTask<()> {"
    , "    Box::pin(async move {"
    , "        tokio::time::sleep(std::time::Duration::from_millis(ms as u64)).await;"
    , "        ok_res(())"
    , "    })"
    , "}"
    , "pub fn time_unix_millis(_: ()) -> SkyTask<i64> { time_now(()) }"
    , "pub fn time_time_string(ms: i64) -> String {"
    , "    format!(\"timestamp:{}\", ms)"
    , "}"
    ]

-- | Random kernel stubs (→ usesRandom)
randomSection :: [String]
randomSection = [ ""
    , "// --- Random (LCG, persisted across calls via AtomicU64) ---"
    , "use std::sync::atomic::{AtomicU64, Ordering};"
    , "static LCG_STATE: AtomicU64 = AtomicU64::new(0);"
    , "fn lcg_init() {"
    , "    LCG_STATE.store(std::time::SystemTime::now()"
    , "        .duration_since(std::time::UNIX_EPOCH)"
    , "        .unwrap_or_default()"
    , "        .as_nanos() as u64, Ordering::Relaxed);"
    , "}"
    , "fn lcg_next() -> u64 {"
    , "    let s = LCG_STATE.load(Ordering::Relaxed);"
    , "    let n = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);"
    , "    LCG_STATE.store(n, Ordering::Relaxed);"
    , "    n"
    , "}"
    , "pub fn random_int(_: ()) -> SkyTask<i64> {"
    , "    lcg_init();"
    , "    let v = lcg_next() as i64;"
    , "    Box::pin(ready(ok_res(v)))"
    , "}"
    , "pub fn random_float(_: ()) -> SkyTask<f64> {"
    , "    lcg_init();"
    , "    let v = (lcg_next() >> 11) as f64 * (1.0 / 9007199254740992.0);"
    , "    Box::pin(ready(ok_res(v)))"
    , "}"
    , "pub fn random_choice(items: Vec<String>) -> SkyTask<String> {"
    , "    lcg_init();"
    , "    if items.is_empty() { return Box::pin(ready(SkyResult::Err(str_err(\"Random.choice: empty list\".into())))); }"
    , "    let idx = lcg_next() as usize % items.len();"
    , "    Box::pin(ready(ok_res(items.get(idx).cloned().unwrap_or_default())))"
    , "}"
    ]

-- | File kernel stubs (→ usesFile)
fileSection :: [String]
fileSection = [ ""
    , "// --- File ---"
    , "pub fn file_read_file(path: String) -> SkyTask<String> {"
    , "    match std::fs::read_to_string(&path) {"
    , "        Ok(s) => Box::pin(ready(ok_res(s))),"
    , "        Err(e) => Box::pin(ready(SkyResult::Err(str_err(format!(\"{}\", e)))))"
    , "    }"
    , "}"
    , "pub fn file_write_file(path: String, content: String) -> SkyTask<()> {"
    , "    match std::fs::write(&path, &content) {"
    , "        Ok(_) => Box::pin(ready(ok_res(()))),"
    , "        Err(e) => Box::pin(ready(SkyResult::Err(str_err(format!(\"{}\", e)))))"
    , "    }"
    , "}"
    , "pub fn file_exists(path: String) -> SkyTask<bool> {"
    , "    Box::pin(ready(ok_res(std::path::Path::new(&path).exists())))"
    , "}"
    , "pub fn file_delete(path: String) -> SkyTask<()> {"
    , "    match std::fs::remove_file(&path) {"
    , "        Ok(_) => Box::pin(ready(ok_res(()))),"
    , "        Err(e) => Box::pin(ready(SkyResult::Err(str_err(format!(\"{}\", e)))))"
    , "    }"
    , "}"
    ]

-- | Crypto kernel stubs (→ usesCrypto)
cryptoSections :: [String]
cryptoSections = [ ""
    , "// --- Crypto ---"
    , "pub fn crypto_random_bytes(n: i64) -> SkyTask<Vec<i64>> {"
    , "    lcg_init();"
    , "    let mut out = Vec::with_capacity(n as usize);"
    , "    for _ in 0..n {"
    , "        out.push(lcg_next() as i64);"
    , "    }"
    , "    Box::pin(ready(ok_res(out)))"
    , "}"
    , "pub fn crypto_random_token(n: i64) -> SkyTask<String> {"
    , "    lcg_init();"
    , "    let hex = \"0123456789abcdef\";"
    , "    let mut out = String::with_capacity((n * 2) as usize);"
    , "    for _ in 0..n {"
    , "        let b = lcg_next();"
    , "        out.push(hex.as_bytes()[(b & 0x0f) as usize] as char);"
    , "        out.push(hex.as_bytes()[((b >> 4) & 0x0f) as usize] as char);"
    , "    }"
    , "    Box::pin(ready(ok_res(out)))"
    , "}"
    , "pub fn crypto_sha256(s: String) -> String {"
    , "    use sha2::{Sha256, Digest};"
    , "    let mut h = Sha256::new();"
    , "    h.update(s.as_bytes());"
    , "    let result = h.finalize();"
    , "    result.iter().map(|b| format!(\"{:02x}\", b)).collect::<Vec<_>>().join(\"\")"
    , "}"
    , ""
    , "// --- Http stub (returns error — no HTTP client yet) ---"
    , "#[derive(Clone, Debug)]"
    , "pub struct SkyCoreHttpResponse { pub body: String, pub status: i64 }"
    , "pub fn http_get(url: String) -> SkyTask<SkyCoreHttpResponse> {"
    , "    let _ = url;"
    , "    Box::pin(ready(SkyResult::Err(str_err(\"Http.get/post: not yet implemented\".into()))))"
    , "}"
    , ""
    , "// --- Basics helper ---"
    , "pub fn basics_error_to_string(e: SkyError) -> String {"
    , "    format!(\"{:?}\", e)"
    , "}"
    ]

miscHelperSection :: [String]
miscHelperSection =
    [ ""
    , "// String helpers (used by Sky.Core.String via VarTopLevel)"
    , "pub fn string_from_int(i: i64) -> String { format!(\"{}\", i) }"
    , "pub fn string_join(sep: String, strs: Vec<String>) -> String { strs.join(&sep) }"
    , "pub fn string_append(a: String, b: String) -> String { a + &b }"
    , "pub fn string_length(s: String) -> i64 { s.len() as i64 }"
    , "pub fn string_is_empty(s: String) -> bool { s.is_empty() }"
    , "pub fn string_reverse(s: String) -> String { s.chars().rev().collect() }"
    , "pub fn string_to_upper(s: String) -> String { s.to_uppercase() }"
    , "pub fn string_to_lower(s: String) -> String { s.to_lowercase() }"
    , "pub fn string_trim(s: String) -> String { s.trim().to_string() }"
    , "pub fn string_contains(haystack: String, needle: String) -> bool { haystack.contains(&needle) }"
    , "pub fn string_to_int(s: String) -> SkyMaybe<i64> {"
    , "    match s.parse::<i64>() { Ok(v) => SkyMaybe::Just(v), Err(_) => SkyMaybe::Nothing }"
    , "}"
    , ""
    , "// Debug trait for logging"
    , "impl fmt::Debug for Error {"
    , "    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {"
    , "        write!(f, \"Error({})\", self.0)"
    , "    }"
    , "}"
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
userModuleSection :: RustBuilder -> [String]
userModuleSection b = concatMap moduleToRustStrings (builderModules b)

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
    "#[derive(Clone, Debug)]\npub enum " ++ name ++ " {\n" ++ intercalate ",\n" (map (\(n, mt) -> "    " ++ n ++ maybe "" (\x -> "(" ++ x ++ ")") mt) variants) ++ "\n}"
typeDefToString (RStructDef name gens fields) =
    "#[derive(Clone, Debug)]\npub struct " ++ name ++ gens ++ " {\n" ++ intercalate ",\n" (map (\(n, t) -> "    " ++ n ++ ": " ++ t) fields) ++ "\n}"
typeDefToString (RAliasDef name ty) = "pub type " ++ name ++ " = " ++ ty ++ ";"

moduleToRustStrings :: RustModule -> [String]
moduleToRustStrings m = 
    ["// Module: " ++ modName m, ""] ++
    concatMap itemToRustStrings (modItems m) ++ [""]

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
    ("Log", "println") -> "println"
    ("Std.Log", "println") -> "println"
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
    in ["fn " ++ name ++ generics ++ "(" ++ intercalate ", " params ++ ")" ++ ret ++ " {", "    " ++ bodyLine, "}"]
itemToRustStrings (RustStruct name fields) = 
    ["#[derive(Clone, Debug)]",
     "pub struct " ++ name ++ " {", 
     intercalate ",\n" (map (\(n, t) -> "    " ++ n ++ ": " ++ t) fields), 
     "}"]
itemToRustStrings (RustEnum name variants) = 
    ["#[derive(Clone, Debug)]",
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
emitCargoToml :: UsedKernels -> String -> String
emitCargoToml uk dbDriver = unlines $
    [ "[package]"
    , "name = \"sky-app\""
    , "version = \"0.1.0\""
    , "edition = \"2021\""
    , ""
    , "[dependencies]"
    ] ++ tokioDep ++ sqlxDep ++ jsonDep ++ cryptoDep
  where
    needsTokio = usesTaskRun uk || usesTaskParallel uk || usesDb uk
    tokioDep = if needsTokio
        then [ "tokio = { version = \"1\", features = [\"rt\", \"rt-multi-thread\", \"macros\"] }" ]
        else []
    sqlxDep = if usesDb uk
        then [ "sqlx = { version = \"0.8\", features = [\"runtime-tokio-rustls\", \"" ++ dbFeature dbDriver ++ "\"] }" ]
        else []
    jsonDep = if usesJson uk
        then [ "serde_json = \"1\"" ]
        else []
    cryptoDep = if usesCrypto uk
        then [ "sha2 = \"0.10\"" ]
        else []

-- | Map sky.toml driver name to sqlx cargo feature
dbFeature :: String -> String
dbFeature "postgres" = "postgres"
dbFeature "mysql"    = "mysql"
dbFeature _          = "sqlite"

intercalate :: String -> [String] -> String
intercalate _ [] = ""
intercalate _ [x] = x
intercalate s (x:xs) = x ++ s ++ intercalate s xs