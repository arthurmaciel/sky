module Sky.Generate.Rust.Builder where

import Data.List (isSuffixOf, isPrefixOf, stripPrefix, span)
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
    } deriving (Show, Eq)

instance Semigroup UsedKernels where
    a <> b = UsedKernels
        { usesDb = usesDb a || usesDb b
        , usesTaskRun = usesTaskRun a || usesTaskRun b
        , usesTaskParallel = usesTaskParallel a || usesTaskParallel b
        , usesJson = usesJson a || usesJson b
        }
instance Monoid UsedKernels where
    mempty = UsedKernels False False False False

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
                , if modName == "Task" && fnName == "run"
                  then mempty { usesTaskRun = True } else mempty
                , if modName == "Task" && fnName == "parallel"
                  then mempty { usesTaskParallel = True } else mempty
                , if "Json" `isPrefixOf` modName || "Sky.Core.Json" `isPrefixOf` modName
                  then mempty { usesJson = True } else mempty
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
    | RStructDef String [(String, String)]
    | RAliasDef String String

-- | Context threaded through expression emission
data EmitCtx = EmitCtx
    { ecRecordMap :: Map.Map String String  -- field-key -> struct name
    , ecSolvedTypes :: Map.Map String Can.Type  -- function name -> inferred type
    , ecCloneVars :: Set.Set String  -- vars that need .clone() at every use site
    , ecPipeInnerType :: Maybe String  -- inner type of piped Task<A>, set by |>
    }

-- | Build a map from field-name-signature to struct name
buildRecordMap :: [Can.Module] -> Map.Map String String
buildRecordMap mods = Map.fromList
    [ (intercalate "," (Map.keys fields), toCamelCase (modPrefix ++ "_" ++ name))
    | mod <- mods
    , let modPrefix = moduleNameToRust (Can._name mod)
    , (name, Can.Alias _ (Can.TRecord fields _)) <- Map.toList (Can._aliases mod)
    ]

buildModule :: EmitCtx -> Can.Module -> RustModule
buildModule ctx mod = 
    let modPrefix = moduleNameToRust (Can._name mod)
        items = declsToRustItems ctx modPrefix (Can._decls mod)
        prefixItem (RustFunction n g p r b)
            | n == "sky_main" || n == "main" = RustFunction n g p r b
            | otherwise = RustFunction (toSnakeCase (modPrefix ++ "_" ++ n)) g p r b
        prefixItem (RustStruct n f) = RustStruct (toCamelCase (modPrefix ++ "_" ++ n)) f
        prefixItem (RustEnum n v) = RustEnum (toCamelCase (modPrefix ++ "_" ++ n)) v
        prefixItem (RustTypeAlias n t) = RustTypeAlias (toCamelCase (modPrefix ++ "_" ++ n)) t
        prefixItem other = other
    in RustModule
        { modName = modPrefix
        , modItems = map prefixItem items
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
-- Main module helpers
knownDefSig p n a | p == "Main" = mainSig n a
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

mainSig :: String -> Int -> Maybe ([String], String)
mainSig "formatTodo" 1 = Just (["HashMap<String, String>"], "String")
mainSig _ _ = Nothing

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
        (paramStrs, genVars) = case knownDefSig modPrefix name n of
            Just (paramTypes, retType) ->
                let safeParams = map (\(p, t) -> patternToRustParam p ++ ": " ++ t) (zip params paramTypes)
                    tvars = sigTVars paramTypes retType
                    extraBound tv = if name == "member" && tv == "T0" then " + PartialEq" else ""
                    genList = map (\tv -> tv ++ ": Clone" ++ extraBound tv) tvars
                    gens = if null genList then "" else "<" ++ intercalate ", " genList ++ ">"
                in (safeParams, gens)
            Nothing ->
                -- Try solvedTypes (HM-inferred types) for param types.
                -- This correctly types Def functions like getArg : List String -> String
                -- even when the lowerer desugars case expressions.
                let solvedParamTys = case Map.lookup name (ecSolvedTypes ctx) of
                        Just ty -> extractParamTypes ty
                        Nothing -> []
                    (safeParams, genVars) =
                        if length solvedParamTys == length params
                           && all (not . hasTypeVars) solvedParamTys
                        then -- Use solved types (all concrete, no TVars)
                            let pStrs = map (\(p, t) -> patternToRustParam p ++ ": " ++ typeToRustString t)
                                        (zip params solvedParamTys)
                            in (pStrs, "")
                        else -- Fallback: body analysis or SkyValue
                            let useVec = bodyUsesList body
                                pStrs = map (\(i, p) ->
                                    let tn = "T" ++ show i
                                    in patternToRustParam p ++ ": " ++ (if useVec then "Vec<" ++ tn ++ ">" else "SkyValue")
                                    ) (zip [0..] params)
                                genList = if useVec
                                          then map (\i -> "T" ++ show i ++ ": Clone") [0..length params - 1]
                                          else []
                                gs = if null genList then "" else "<" ++ intercalate ", " genList ++ ">"
                            in (pStrs, gs)
                in (safeParams, genVars)
        -- sky_main always returns () since the entry wrapper handles the Task.
        -- knownDefSig takes priority so stdlib functions get correct return types
        -- even when not in ecSolvedTypes (which only covers the entry module).
        retTy = if name == "main" then "()"
                else case knownDefSig modPrefix name n of
                    Just (_, knownRetType) -> knownRetType
                    Nothing -> case Map.lookup name (ecSolvedTypes ctx) of
                        Just ty -> let ret = extractReturnType ty
                                  in if hasTypeVars ret then "()" else typeToRustString ret
                        Nothing -> "()"
    in RustFunction rustName genVars paramStrs retTy (exprToRustString ctx body)
defToRustItem _ctx _modPrefix (Can.TypedDef (Ann.At _ name) _ pats body retTy) = 
    let rustName = if name == "main" then "sky_main" else name
        params = map (\(pat, ty) -> patternToRustParam pat ++ ": " ++ typeToRustString ty) pats
        ret = if name == "main" then "()" else typeToRustString retTy
    in RustFunction rustName "" params ret (exprToRustString _ctx body)
defToRustItem _ctx _modPrefix (Can.DestructDef pat expr) =
    RustFunction "_destruct" "" [patternToRustParam pat] "()" (exprToRustString _ctx expr)

unionsToRustTypes :: String -> Map.Map String Can.Union -> [RustTypeDef]
unionsToRustTypes modPrefix unions = map (\(name, u) -> unionToRustTypeDef modPrefix name u) (Map.toList unions)

unionToRustTypeDef :: String -> String -> Can.Union -> RustTypeDef
unionToRustTypeDef modPrefix typeName (Can.Union _ alts _ _) = 
    REnumDef (toCamelCase (modPrefix ++ "_" ++ typeName)) (map ctorToRust alts)
  where
    ctorToRust (Can.Ctor name _idx _arity argTypes) = 
        (name, if null argTypes then Nothing 
               else Just (intercalate ", " (map typeToRustString argTypes)))

aliasesToRustTypes :: String -> Map.Map String Can.Alias -> [RustTypeDef]
aliasesToRustTypes modPrefix aliases = concatMap (\(name, alias) -> aliasToRustTypeDef modPrefix name alias) (Map.toList aliases)

aliasToRustTypeDef :: String -> String -> Can.Alias -> [RustTypeDef]
aliasToRustTypeDef modPrefix name (Can.Alias _vars ty) = case ty of
    Can.TRecord fields _ -> 
        [RStructDef (toCamelCase (modPrefix ++ "_" ++ name)) (map (\(n, Can.FieldType _ ft) -> (n, typeToRustString ft)) (Map.toList fields))]
    _ -> 
        [RAliasDef (toCamelCase (modPrefix ++ "_" ++ name)) (typeToRustString ty)]

typeToRustString :: Can.Type -> String
typeToRustString t = case t of
    Can.TType modName "Int" [] -> "i64"
    Can.TType _ "Float" [] -> "f64"
    Can.TType _ "Bool" [] -> "bool"
    Can.TType _ "Char" [] -> "char"
    Can.TType _ "String" [] -> "String"
    Can.TType _ "Task" [_, a] -> "SkyTask<" ++ typeToRustString a ++ ">"
    Can.TUnit -> "()"
    Can.TType _ "List" [a] -> "Vec<" ++ typeToRustString a ++ ">"
    Can.TType _ "Maybe" [a] -> "SkyMaybe<" ++ typeToRustString a ++ ">"
    Can.TType _ "Dict" [k, v] -> "HashMap<" ++ typeToRustString k ++ ", " ++ typeToRustString v ++ ">"
    Can.TType _ "Result" [e, a] -> "SkyResult<" ++ typeToRustString e ++ ", " ++ typeToRustString a ++ ">"
    Can.TType _ "Error" [] -> "SkyError"  -- Sky unified error type (maps to Error ADT or String)
    Can.TRecord _fields _ -> "()"  -- TRecord: emitted as named struct via alias
    Can.TTuple a b rest -> "(" ++ intercalate ", " (map typeToRustString (a:b:rest)) ++ ")"
    Can.TVar v -> v
    Can.TType modName name [] ->
        let modStr = ModuleName._name modName
            modPrefix = if null modStr then "" else map (\c -> if c == '.' then '_' else c) modStr ++ "_"
        in toCamelCase (modPrefix ++ name)
    Can.TType modName name args ->
        let modStr = ModuleName._name modName
            modPrefix = if null modStr then "" else map (\c -> if c == '.' then '_' else c) modStr ++ "_"
        in toCamelCase (modPrefix ++ name) ++ "<" ++ intercalate ", " (map typeToRustString args) ++ ">"
    Can.TLambda a b -> "fn(" ++ typeToRustString a ++ ") -> " ++ typeToRustString b
    Can.TAlias modName name _pairs _inner ->
        let modStr = ModuleName._name modName
            modPrefix = if null modStr then "" else map (\c -> if c == '.' then '_' else c) modStr ++ "_"
        in toCamelCase (modPrefix ++ name)
    _ -> "SkyValue"

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
        Can.Let (Can.Def (Ann.At _ name) _ defBody) body ->
            let bound' = Set.insert name bound
            in Map.unionWith (+) (go bound' defBody) (go bound' body)
        Can.LetRec defs body ->
            let bound' = foldl (\s (Can.Def (Ann.At _ n) _ _) -> Set.insert n s) bound defs
                goDefs = foldl (\a (Can.Def _ _ d) -> Map.unionWith (+) a (go bound' d)) Map.empty defs
            in Map.unionWith (+) (go bound' body) goDefs
        Can.LetDestruct _ expr body -> Map.unionWith (+) (go bound expr) (go bound body)
        Can.Case _ branches -> foldl (\a (Can.CaseBranch _ b) -> Map.unionWith (+) a (go bound b)) Map.empty branches
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
        Can.LetDestruct _ expr body -> Set.union (go bound expr) (go bound body)
        Can.Case _ branches -> foldl (\a (Can.CaseBranch _ b) -> Set.union a (go bound b)) Set.empty branches
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

exprToRustString :: EmitCtx -> Can.Expr -> String
exprToRustString ctx (Ann.At _ expr) = exprToRustInner ctx expr

exprToRustInner :: EmitCtx -> Can.Expr_ -> String
exprToRustInner ctx e = case e of
    Can.VarLocal name -> rustSafeIdent name ++ if name `Set.member` ecCloneVars ctx then ".clone()" else ""
    Can.VarTopLevel mod name -> 
        toSnakeCase (map (\c -> if c == '.' then '_' else c) (ModuleName._name mod) ++ "_" ++ name)
    Can.VarKernel mod name -> kernelToRust mod name
    Can.VarCtor _ modName typeName ctorName _ -> kernelCtorToRust modName typeName ctorName
    Can.Chr c -> show c
    Can.Str s -> show s ++ ".to_string()"
    Can.Int i -> show i
    Can.Float f -> show f
    Can.List es -> "vec![" ++ intercalate ", " (map (exprToRustString ctx) es) ++ "]"
    Can.Negate e -> "-" ++ exprToRustString ctx e
    Can.Binop op _ _ _ a b 
        | op == "|>" ->
            let inner = taskExprInnerType a
                ctx' = ctx { ecPipeInnerType = if null inner then Nothing else Just inner }
            in exprToRustString ctx' b ++ "(" ++ exprToRustString ctx a ++ ")"
        | op == "<|" -> exprToRustString ctx a ++ "(" ++ exprToRustString ctx b ++ ")"
        | op == "::" -> "sky_list_cons(" ++ exprToRustString ctx a ++ ", " ++ exprToRustString ctx b ++ ")"
        | op == "++" -> "format!(\"{}{}\", " ++ exprToRustString ctx a ++ ", " ++ exprToRustString ctx b ++ ")"
        | otherwise -> 
            "(" ++ exprToRustString ctx a ++ " " ++ binopToRust op ++ " " ++ exprToRustString ctx b ++ ")"
    Can.Lambda params body -> 
        "|" ++ intercalate ", " (map patternToRustParam params) ++ "| { " ++ exprToRustString ctx body ++ " }"
    Can.Call fn args -> case exprToRustString ctx fn of
        fnName | "println" `isSuffixOf` fnName -> 
            let fmt = concat (replicate (length args) "{}")
            in "{ println!(\"" ++ fmt ++ "\", " ++ intercalate ", " (map (exprToRustString ctx) args) ++ "); Box::pin(ready(SkyResult::Ok(()))) }"
        _ -> 
            -- Clone VarLocal args for every function call EXCEPT Task_run,
            -- whose argument is a Pin<Box<dyn Future>> which does not implement Clone.
            let noCloneFn = case fn of
                    Ann.At _ (Can.VarKernel _ n) -> n == "run"
                    _ -> False
                argsStrs = map (\a -> case a of
                    Ann.At _ (Can.Lambda ps body) ->
                        let paramNames = Set.fromList [ n | Ann.At _ p <- ps, let n = case p of Can.PVar s -> s; _ -> "_" ]
                            captured = Set.toList (Set.difference (collectVarLocals body) paramNames)
                            clones = concatMap (\v -> "let " ++ v ++ " = " ++ v ++ ".clone(); ") captured
                            innerCounts = collectVarLocalsMulti body
                            innerMulti = [ v | (v, c) <- Map.toList innerCounts, c >= 2
                                           , v `notElem` paramNames ]
                            ctx' = ctx { ecCloneVars = Set.fromList innerMulti }
                            -- Add type annotation on closure params when the
                            -- enclosing pipeline's task type is known (E0282 fix).
                            annot = case ecPipeInnerType ctx of
                                Just t | length ps == 1 -> ": " ++ t
                                _ -> ""
                            psStr = intercalate ", " (map (\p -> patternToRustParam p ++ annot) ps)
                        in if null captured
                           then "move |" ++ psStr ++ "| { " ++ exprToRustString ctx' body ++ " }"
                           else "{ " ++ clones ++ "move |" ++ psStr ++ "| { " ++ exprToRustString ctx' body ++ " } }"
                    Ann.At _ (Can.VarLocal n) | not noCloneFn -> rustSafeIdent n ++ ".clone()"
                    _ -> exprToRustString ctx a) args
            in exprToRustString ctx fn ++ "(" ++ intercalate ", " argsStrs ++ ")"
    Can.If [] elseBranch ->
        exprToRustString ctx elseBranch
    Can.If ((firstCond, firstBody):rest) elseBranch ->
        "if " ++ exprToRustString ctx firstCond ++ " { " ++ exprToRustString ctx firstBody ++ " }"
        ++ concatMap (\(c, t) -> " else if " ++ exprToRustString ctx c ++ " { " ++ exprToRustString ctx t ++ " }") rest
        ++ " else { " ++ exprToRustString ctx elseBranch ++ " }"
    Can.Let def body -> 
        "let " ++ defToRustString ctx def ++ "; " ++ exprToRustString ctx body
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
        in "let " ++ patternToMatchString pat ++ " = " ++ exprStr ++ "; " ++ exprToRustString ctx body
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
        "let mut result = " ++ exprToRustString ctx record ++ "; " ++
        intercalate "; " (map (\(f, Can.FieldUpdate _ expr) -> "result." ++ f ++ " = " ++ exprToRustString ctx expr) (Map.toList updates)) ++
        "; result"
    Can.Record fields -> 
        let key = intercalate "," (Map.keys fields)
        in case Map.lookup key (ecRecordMap ctx) of
            Just structName -> 
                structName ++ " { " ++ intercalate ", " (map (\(k, v) -> k ++ ": " ++ exprToRustString ctx v) (Map.toList fields)) ++ " }"
            Nothing -> 
                "{ " ++ intercalate ", " (map (\(k, v) -> k ++ ": " ++ exprToRustString ctx v) (Map.toList fields)) ++ " }"
    Can.Unit -> "()"
    Can.Tuple a b rest -> 
        "(" ++ intercalate ", " (map (exprToRustString ctx) (a:b:rest)) ++ ")"

-- | Emit a function-call argument, cloning captured locals when the argument
-- is a closure (the Task_map(|_| { use(x) })(f(x)) pattern).  Uses move so
-- each closure owns its clones; outer scope keeps the original.
argToRust :: EmitCtx -> Can.Expr -> String
argToRust ctx (Ann.At _ (Can.Lambda params body)) =
    let paramNames = Set.fromList [ n | Ann.At _ p <- params, let n = case p of Can.PVar s -> s; _ -> "_" ]
        captured = Set.toList (Set.difference (collectVarLocals body) paramNames)
        clones = concatMap (\v -> "let " ++ v ++ " = " ++ v ++ ".clone(); ") captured
        paramsStr = intercalate ", " (map patternToRustParam params)
    in if null captured
       then "|" ++ paramsStr ++ "| { " ++ exprToRustString ctx body ++ " }"
       else "{ " ++ clones ++ "move |" ++ paramsStr ++ "| { " ++ exprToRustString ctx body ++ " } }"
argToRust ctx (Ann.At _ (Can.VarLocal name)) = rustSafeIdent name  -- keep as is
argToRust ctx expr = exprToRustString ctx expr

-- | Given a Task-typed expression (like Db_query(…)), return the Rust type
-- string of the SkyTask's inner success type A (i.e.  SkyTask<A> → A).
-- Returns "" when the type can't be determined.
taskExprInnerType :: Can.Expr -> String
taskExprInnerType (Ann.At _ expr) = case expr of
    Can.Call (Ann.At _ (Can.VarKernel modName fnName)) _args
        | "Task" `isSuffixOf` modName || modName == "Task" -> case fnName of
            "succeed"  -> "String"
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
            "args"     -> "Vec<String>"
            "exit"     -> "()"
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
    -- Fallback: try to look up known signature from solvedTypes
    Can.VarTopLevel modName name ->
        let modStr = ModuleName._name modName
            modPrefix = if null modStr then "" else map (\c -> if c == '.' then '_' else c) modStr ++ "_"
            qualified = modPrefix ++ name
        in ""  -- solvedTypes lookup would go here (complex, defer for now)
    _ -> ""

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
    let patStr  = patternToMatchString pat
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

patternToMatchString :: Can.Pattern -> String
patternToMatchString (Ann.At _ pat) = case pat of
    Can.PVar n -> rustSafeIdent n
    Can.PAnything -> "_"
    Can.PInt i -> show i
    Can.PBool b -> if b then "true" else "false"
    Can.PChr c -> show c
    Can.PStr s -> show s
    Can.PUnit -> "()"
    Can.PCtor{Can._p_home = home, Can._p_type = typeName, Can._p_name = name, Can._p_args = args} ->
        let subPats = map ctorArgToPattern args
            fullName = kernelCtorToRust home typeName name
        in fullName ++ if null subPats then "" else "(" ++ intercalate ", " subPats ++ ")"
    Can.PTuple a b rest -> 
        "(" ++ intercalate ", " (map patternToMatchString (a:b:rest)) ++ ")"
    Can.PRecord fields -> "{" ++ intercalate ", " fields ++ "}"
    Can.PCons a b -> 
        let headPat = patternToMatchString a
            restPat = patternToMatchString b
            restPart = if restPat == "_" then ".." else restPat ++ " @ .."
        in "[" ++ headPat ++ ", " ++ restPart ++ "]"
    Can.PList items -> "[" ++ intercalate ", " (map patternToMatchString items) ++ "]"
    Can.PAlias pat _ -> patternToMatchString pat
    _ -> "_"

ctorArgToPattern :: Can.PatternCtorArg -> String
ctorArgToPattern (Can.PatternCtorArg _ _ pat) = patternToMatchString pat

buildProgram :: [Can.Module] -> Map.Map String Can.Type -> RustBuilder
buildProgram mods solvedTypes = 
    let recordMap = buildRecordMap mods
        ctx = EmitCtx { ecRecordMap = recordMap, ecSolvedTypes = solvedTypes, ecCloneVars = Set.empty, ecPipeInnerType = Nothing }
        usage = analyzeKernelUsage mods
    in RustBuilder
        { builderModules = map (buildModule ctx) mods
        , builderTypes = concatMap (\m -> 
            let prefix = moduleNameToRust (Can._name m)
            in unionsToRustTypes prefix (Can._unions m) ++ aliasesToRustTypes prefix (Can._aliases m)) mods
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
    , taskSection (builderKernels b)
    , dbSection (builderKernels b) dbPath dbDriver b
    , systemHelperSection
    , logHelperSection
    , jsonSection (builderKernels b)
    , extraKernelSection b
    , miscHelperSection
    , userTypeSection b
    , skyErrorLine b
    , userModuleSection b
    , ffiPlaceholderSection b
    , entryPointSection
    ]

-- | Header and file-level attributes
headerSection :: [String]
headerSection =
    [ "// Generated by Sky compiler (Rust target)"
    , "#![allow(unused, non_snake_case)]"
    , ""
    , "// ==========================================="
    , "// SKY RUNTIME (inline)"
    , "// ==========================================="
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
    , "type SkyValue = String;"
    , ""
    , "// Error type for Task"
    , "pub struct Error(pub String);"
    ]

-- | Core types and helpers (Maybe, Result, List, String, Int, Float — always emitted)
coreHelperSection :: [String]
coreHelperSection =
    [ ""
    , "// Maybe equivalent"
    , "#[derive(Clone)]"
    , "pub enum SkyMaybe<T> {"
    , "    Nothing,"
    , "    Just(T),"
    , "}"
    , ""
    , "// Result equivalent"
    , "#[derive(Clone)]"
    , "pub enum SkyResult<E, A> {"
    , "    Err(E),"
    , "    Ok(A),"
    , "}"
    , ""
    , "// Maybe helpers"
    , "impl<T> SkyMaybe<T> {"
    , "    pub fn with_default(self, def: T) -> T {"
    , "        match self { SkyMaybe::Just(v) => v, SkyMaybe::Nothing => def }"
    , "    }"
    , "    pub fn is_just(&self) -> bool { matches!(self, SkyMaybe::Just(_)) }"
    , "}"
    , ""
    , "pub fn sky_maybe_map<T, U>(m: SkyMaybe<T>, f: impl FnOnce(T) -> U) -> SkyMaybe<U> {"
    , "    match m { SkyMaybe::Just(v) => SkyMaybe::Just(f(v)), SkyMaybe::Nothing => SkyMaybe::Nothing }"
    , "}"
    , ""
    , "pub fn sky_maybe_and_then<T, U>(m: SkyMaybe<T>, f: impl FnOnce(T) -> SkyMaybe<U>) -> SkyMaybe<U> {"
    , "    match m { SkyMaybe::Just(v) => f(v), SkyMaybe::Nothing => SkyMaybe::Nothing }"
    , "}"
    , ""
    , "// Result helpers"
    , "impl<E, A> SkyResult<E, A> {"
    , "    pub fn is_ok(&self) -> bool { matches!(self, SkyResult::Ok(_)) }"
    , "    pub fn is_err(&self) -> bool { matches!(self, SkyResult::Err(_)) }"
    , "    pub fn with_default(self, def: A) -> A {"
    , "        match self { SkyResult::Ok(v) => v, SkyResult::Err(_) => def }"
    , "    }"
    , "}"
    , ""
    , "pub fn sky_result_map<E, A, B>(r: SkyResult<E, A>, f: impl FnOnce(A) -> B) -> SkyResult<E, B> {"
    , "    match r { SkyResult::Ok(v) => SkyResult::Ok(f(v)), SkyResult::Err(e) => SkyResult::Err(e) }"
    , "}"
    , ""
    , "pub fn sky_result_and_then<E, A, B>(r: SkyResult<E, A>, f: impl FnOnce(A) -> SkyResult<E, B>) -> SkyResult<E, B> {"
    , "    match r { SkyResult::Ok(v) => f(v), SkyResult::Err(e) => SkyResult::Err(e) }"
    , "}"
    , ""
    , "// List helpers"
    , "pub fn sky_list_is_empty<T>(v: &Vec<T>) -> bool { v.is_empty() }"
    , ""
    , "pub fn sky_list_head<T: Clone>(v: &Vec<T>) -> SkyMaybe<T> {"
    , "    v.first().map(|x| SkyMaybe::Just(x.clone())).unwrap_or(SkyMaybe::Nothing)"
    , "}"
    , ""
    , "pub fn sky_list_map<T: Clone, U>(f: impl Fn(T) -> U, v: &Vec<T>) -> Vec<U> {"
    , "    v.iter().map(|x| f(x.clone())).collect()"
    , "}"
    , ""
    , "pub fn sky_list_filter<T: Clone>(f: impl Fn(&T) -> bool, v: &Vec<T>) -> Vec<T> {"
    , "    v.iter().filter(|x| f(*x)).cloned().collect()"
    , "}"
    , ""
    , "pub fn sky_list_fold<T: Clone, B>(f: impl Fn(B, T) -> B, init: B, v: &Vec<T>) -> B {"
    , "    v.iter().fold(init, |acc, x| f(acc, x.clone()))"
    , "}"
    , ""
    , "pub fn sky_list_drop<T: Clone>(n: usize, v: &Vec<T>) -> Vec<T> {"
    , "    v.iter().skip(n).cloned().collect()"
    , "}"
    , ""
    , "pub fn sky_list_cons<T: Clone>(x: T, xs: Vec<T>) -> Vec<T> {"
    , "    std::iter::once(x).chain(xs).collect()"
    , "}"
    , ""
    , "// String helpers"
    , "pub fn sky_string_append(a: String, b: String) -> String { a + &b }"
    , "pub fn sky_string_len(s: &String) -> usize { s.len() }"
    , "pub fn sky_string_is_empty(s: &String) -> bool { s.is_empty() }"
    , ""
    , "// Int helpers"
    , "pub fn sky_int_to_string(i: i64) -> String { format!(\"{}\", i) }"
    , "pub fn sky_string_to_int(s: &String) -> SkyResult<String, i64> {"
    , "    match s.parse::<i64>() { Ok(v) => SkyResult::Ok(v), Err(_) => SkyResult::Err(String::new()) }"
    , "}"
    , ""
    , "// Float helpers"
    , "pub fn sky_float_to_string(f: f64) -> String { format!(\"{}\", f) }"
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
        , "    std::thread::spawn(move || Runtime::new().unwrap().block_on(future))"
        , "        .join().expect(\"block_on thread panicked\")"
        , "}"
        ]
     else []) ++
    [ ""
    , "// --- Task type (unified error type = SkyError) ---"
    , "type SkyTask<A> = Pin<Box<dyn Future<Output = SkyResult<SkyError, A>> + Send + 'static>>;"
    , ""
    , "// --- Task combinators (std::future only, no tokio needed) ---"
    , "pub fn task_succeed<A: Send + 'static>(a: A) -> SkyTask<A> {"
    , "    Box::pin(ready(SkyResult::Ok(a)))"
    , "}"
    , "pub fn task_map<A: Send + 'static, B: Send + 'static>("
    , "    f: impl FnOnce(A) -> B + Send + 'static,"
    , ") -> impl FnOnce(SkyTask<A>) -> SkyTask<B> + Send + 'static {"
    , "    |task| Box::pin(async move {"
    , "        match task.await {"
    , "            SkyResult::Ok(a) => SkyResult::Ok(f(a)),"
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
    , "            SkyResult::Ok(a) => SkyResult::Ok(a),"
    , "            SkyResult::Err(e) => f(e).await,"
    , "        }"
    , "    })"
    , "}"
    , "pub fn task_fail<A: Send + 'static>(e: SkyError) -> SkyTask<A> {"
    , "    Box::pin(ready(SkyResult::Err(e)))"
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
        , "            match h.await.expect(\"tokio::spawn panicked\") {"
        , "                SkyResult::Ok(a) => out.push(a),"
        , "                SkyResult::Err(e) => return SkyResult::Err(e),"
        , "            }"
        , "        }"
        , "        SkyResult::Ok(out)"
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
    , "        let value: String = match row.try_get::<&str, _>(i) {"
    , "            Ok(v) => v.to_string(),"
    , "            _ => match row.try_get::<i64, _>(i) {"
    , "                Ok(v) => v.to_string(),"
    , "                _ => match row.try_get::<f64, _>(i) {"
    , "                    Ok(v) => v.to_string(),"
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
    , "            Ok(pool) => SkyResult::Ok(pool),"
    , "            Err(e) => SkyResult::Err(sky_err(&e)),"
    , "        }"
    , "    })"
    , "}"
    , "pub fn db_exec_raw(conn: Db, sql: String) -> SkyTask<()> {"
    , "    Box::pin(async move {"
    , "        match sqlx::query(&sql).execute(&conn).await {"
    , "            Ok(_) => SkyResult::Ok(()),"
    , "            Err(e) => SkyResult::Err(sky_err(&e)),"
    , "        }"
    , "    })"
    , "}"
    , "pub fn db_exec(conn: Db, sql: String, params: Vec<String>) -> SkyTask<()> {"
    , "    Box::pin(async move {"
    , "        let final_sql = build_sql(&sql, &params);"
    , "        match sqlx::query(&final_sql).execute(&conn).await {"
    , "            Ok(_) => SkyResult::Ok(()),"
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
    , "                SkyResult::Ok(result)"
    , "            },"
    , "            Err(e) => SkyResult::Err(sky_err(&e)),"
    , "        }"
    , "    })"
    , "}"
    , "// Alias: Db.open is the same as Db.connect"
    , "pub fn db_open(_unit: ()) -> SkyTask<Db> { db_connect(_unit) }"
    , "pub fn db_open_with_path(_path: String) -> SkyTask<Db> { db_connect(()) }"
    , ""
    , "pub fn db_get_field(field: String, row: HashMap<String, String>) -> String {"
    , "    row.get(&field).cloned().unwrap_or_default()"
    , "}"
    ]

-- | System helpers (always emitted — no external deps)
systemHelperSection :: [String]
systemHelperSection =
    [ ""
    , "// System helpers"
    , "pub fn system_args(_: ()) -> SkyTask<Vec<String>> { Box::pin(ready(SkyResult::Ok(std::env::args().skip(1).collect()))) }"
    , "pub fn system_exit(code: i64) -> ! { std::process::exit(code as i32) }"
    ]

-- | Log helpers (always emitted — just println!)
logHelperSection :: [String]
logHelperSection =
    [ ""
    , "// Log helpers"
    , "pub fn log_info(msg: String) -> SkyTask<()> {"
    , "    println!(\"{}\", msg); Box::pin(ready(SkyResult::Ok(())))"
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
    , "    println!(\"{}{}\", msg, fmt_attrs(&attrs)); Box::pin(ready(SkyResult::Ok(())))"
    , "}"
    , "pub fn log_error_with(msg: String, attrs: Vec<String>) -> SkyTask<()> {"
    , "    eprintln!(\"{}{}\", msg, fmt_attrs(&attrs)); Box::pin(ready(SkyResult::Ok(())))"
    , "}"
    , ""
    , "pub fn log_debug(msg: String) -> SkyTask<()> {"
    , "    eprintln!(\"{}\", msg); Box::pin(ready(SkyResult::Ok(())))"
    , "}"
    , "pub fn log_warn(msg: String) -> SkyTask<()> {"
    , "    eprintln!(\"{}\", msg); Box::pin(ready(SkyResult::Ok(())))"
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
    , "type Decoder<T> = Box<dyn Fn(&JsonVal) -> SkyResult<SkyError, T> + Send + Sync>;"
    , ""
    , "fn json_dec_ok<T>(t: T) -> SkyResult<SkyError, T> { SkyResult::Ok(t) }"
    , "fn json_dec_err_str<T>(s: String) -> SkyResult<SkyError, T> { SkyResult::Err(s) }"
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
    , "pub fn json_dec_null<A: Default>() -> Decoder<A> {"
    , "    Box::new(|v| match v { JsonVal::Null => json_dec_ok(A::default()), _ => json_dec_err_str(\"expected null\".into()) })"
    , "}"
    , ""
    , "// --- Decode combinators ---"
    , "pub fn json_dec_field<T>(name: String, decoder: Decoder<T>) -> Decoder<T> {"
    , "    Box::new(move |v| match v.get(&name) { Some(field) => decoder(field), None => json_dec_err_str(format!(\"missing field: {}\", name)) })"
    , "}"
    , "pub fn json_dec_at<T>(path: Vec<String>, decoder: Decoder<T>) -> Decoder<T> {"
    , "    Box::new(move |v| {"
    , "        let mut cur = v;"
    , "        for key in &path { match cur.get(key) { Some(n) => cur = n, None => return json_dec_err_str(format!(\"missing path: {}\", key)) } }"
    , "        decoder(cur)"
    , "    })"
    , "}"
    , "pub fn json_dec_list<T>(decoder: Decoder<T>) -> Decoder<Vec<T>> {"
    , "    Box::new(move |v| match v.as_array() {"
    , "        Some(arr) => {"
    , "            let mut out = Vec::with_capacity(arr.len());"
    , "            for item in arr { match decoder(item) { SkyResult::Ok(t) => out.push(t), SkyResult::Err(_) => return json_dec_err_str(\"decode error\".into()) } }"
    , "            json_dec_ok(out)"
    , "        },"
    , "        None => json_dec_err_str(\"expected array\".into())"
    , "    })"
    , "}"
    , "pub fn json_dec_map<A, B>(f: impl Fn(A) -> B + Send + Sync + 'static, decoder: Decoder<A>) -> Decoder<B> {"
    , "    Box::new(move |v| match decoder(v) { SkyResult::Ok(a) => json_dec_ok(f(a)), SkyResult::Err(_) => json_dec_err_str(\"map error\".into()) })"
    , "}"
    , "pub fn json_dec_map2<A, B, C>("
    , "    f: impl Fn(A, B) -> C + Send + Sync + 'static, da: Decoder<A>, db: Decoder<B>"
    , ") -> Decoder<C> {"
    , "    Box::new(move |v| { let a = da(v); let b = db(v); match a { SkyResult::Ok(av) => match b { SkyResult::Ok(bv) => json_dec_ok(f(av, bv)), SkyResult::Err(_) => json_dec_err_str(\"decode error\".into()) }, SkyResult::Err(_) => json_dec_err_str(\"decode error\".into()) } })"
    , "}"
    , "pub fn json_dec_succeed<A>(a: A) -> Decoder<A> {"
    , "    Box::new(move |_| SkyResult::Ok(a))"
    , "}"
    , "pub fn json_dec_fail<A>(msg: String) -> Decoder<A> {"
    , "    Box::new(move |_| json_dec_err_str(msg))"
    , "}"
    , "pub fn json_dec_one_of<T>(decoders: Vec<Decoder<T>>) -> Decoder<T> {"
    , "    Box::new(move |v| { for d in &decoders { let r = d(v); if r.is_ok() { return r; } } json_dec_err_str(\"oneOf: no match\".into()) })"
    , "}"
    , "pub fn json_dec_decode_string<T>(decoder: Decoder<T>, json: String) -> SkyResult<SkyError, T> {"
    , "    match serde_json::from_str(&json) {"
    , "        Ok(val) => decoder(&val),"
    , "        Err(e) => json_dec_err_str(format!(\"json parse: {}\", e))"
    , "    }"
    , "}"
    , ""
    , "// --- Pipeline (curried decoder combinators) ---"
    , "pub fn json_dec_p_required<T, F>(name: String, decoder: Decoder<T>) -> impl Fn(Decoder<Box<dyn Fn(T) -> F + Send + Sync>>) -> Decoder<F> {"
    , "    move |next_decoder| {"
    , "        Box::new(move |v| {"
    , "            let field_val = match v.get(&name) { Some(f) => match decoder(f) { SkyResult::Ok(t) => t, SkyResult::Err(_) => return json_dec_err_str(\"required field decode error\".into()) }, None => return json_dec_err_str(format!(\"missing required: {}\", name)) };"
    , "            match next_decoder(v) { SkyResult::Ok(f) => SkyResult::Ok(f(field_val)), SkyResult::Err(_) => json_dec_err_str(\"next decode error\".into()) }"
    , "        })"
    , "    }"
    , "}"
    , "pub fn json_dec_p_optional<T: Clone, F>(name: String, decoder: Decoder<T>, default: T) -> impl Fn(Decoder<Box<dyn Fn(T) -> F + Send + Sync>>) -> Decoder<F> {"
    , "    move |next_decoder| {"
    , "        Box::new(move |v| {"
    , "            let field_val = match v.get(&name) { Some(_) => match decoder(v.get(&name)) { SkyResult::Ok(t) => t, SkyResult::Err(_) => default.clone() }, None => default.clone() };"
    , "            match next_decoder(v) { SkyResult::Ok(f) => SkyResult::Ok(f(field_val)), SkyResult::Err(_) => json_dec_err_str(\"next decode error\".into()) }"
    , "        })"
    , "    }"
    , "}"
    ]

-- | Extra kernel stubs: Time, Random, File, Crypto (std-only, no extra deps)
extraKernelSection :: RustBuilder -> [String]
extraKernelSection b =
    let errCtor = if hasErrorType b
            then "fn str_err(s: String) -> SkyError { " ++ toCamelCase "Sky_Core_Error_Error" ++ "::Error(" ++ toCamelCase "Sky_Core_Error_ErrorKind" ++ "::Unexpected, " ++ toCamelCase "Sky_Core_Error_ErrorInfo" ++ " { details: SkyMaybe::Nothing, message: s }) }"
            else "fn str_err(s: String) -> SkyError { s }"
    in
    [ ""
    , "// ==========================================="
    , "// EXTRA KERNEL STUBS (Time, Random, File, Crypto)"
    , "// ==========================================="
    , ""
    , errCtor
    , ""
    , "// --- Time ---"
    , "pub fn time_now(_: ()) -> SkyTask<i64> {"
    , "    let ms = std::time::SystemTime::now()"
    , "        .duration_since(std::time::UNIX_EPOCH)"
    , "        .unwrap_or_default()"
    , "        .as_millis() as i64;"
    , "    Box::pin(ready(SkyResult::Ok(ms)))"
    , "}"
    , "pub fn time_sleep(ms: i64) -> SkyTask<()> {"
    , "    std::thread::sleep(std::time::Duration::from_millis(ms as u64));"
    , "    Box::pin(ready(SkyResult::Ok(())))"
    , "}"
    , "pub fn time_unix_millis(_: ()) -> SkyTask<i64> { time_now(()) }"
    , ""
    , "// --- Random (std-hash-based, not cryptographically secure) ---"
    , "fn lcg_seed() -> u64 {"
    , "    std::time::SystemTime::now()"
    , "        .duration_since(std::time::UNIX_EPOCH)"
    , "        .unwrap_or_default()"
    , "        .as_nanos() as u64"
    , "}"
    , "fn lcg_next(seed: &mut u64) -> u64 {"
    , "    // LCG constants (Numerical Recipes)"
    , "    *seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);"
    , "    *seed"
    , "}"
    , "pub fn random_int(_: ()) -> SkyTask<i64> {"
    , "    let mut seed = lcg_seed();"
    , "    let v = lcg_next(&mut seed) as i64;"
    , "    Box::pin(ready(SkyResult::Ok(v)))"
    , "}"
    , "pub fn random_float(_: ()) -> SkyTask<f64> {"
    , "    let mut seed = lcg_seed();"
    , "    let v = (lcg_next(&mut seed) >> 11) as f64 * (1.0 / 9007199254740992.0);"
    , "    Box::pin(ready(SkyResult::Ok(v)))"
    , "}"
    , "pub fn random_choice(items: Vec<String>) -> SkyTask<String> {"
    , "    let mut seed = lcg_seed();"
    , "    let idx = (lcg_next(&mut seed) as usize) % items.len().max(1);"
    , "    Box::pin(ready(SkyResult::Ok(items.get(idx).cloned().unwrap_or_default())))"
    , "}"
    , ""
    , "// --- File ---"
    , "pub fn file_read_file(path: String) -> SkyTask<String> {"
    , "    match std::fs::read_to_string(&path) {"
    , "        Ok(s) => Box::pin(ready(SkyResult::Ok(s))),"
    , "        Err(e) => Box::pin(ready(SkyResult::Err(str_err(format!(\"{}\", e)))))"
    , "    }"
    , "}"
    , "pub fn file_write_file(path: String, content: String) -> SkyTask<()> {"
    , "    match std::fs::write(&path, &content) {"
    , "        Ok(_) => Box::pin(ready(SkyResult::Ok(()))),"
    , "        Err(e) => Box::pin(ready(SkyResult::Err(str_err(format!(\"{}\", e)))))"
    , "    }"
    , "}"
    , "pub fn file_exists(path: String) -> SkyTask<bool> {"
    , "    Box::pin(ready(SkyResult::Ok(std::path::Path::new(&path).exists())))"
    , "}"
    , "pub fn file_delete(path: String) -> SkyTask<()> {"
    , "    match std::fs::remove_file(&path) {"
    , "        Ok(_) => Box::pin(ready(SkyResult::Ok(()))),"
    , "        Err(e) => Box::pin(ready(SkyResult::Err(str_err(format!(\"{}\", e)))))"
    , "    }"
    , "}"
    , ""
    , "// --- Crypto (deterministic LCG-based, NOT cryptographically secure) ---"
    , "pub fn crypto_random_bytes(n: i64) -> SkyTask<Vec<i64>> {"
    , "    let mut seed = lcg_seed();"
    , "    let mut out = Vec::with_capacity(n as usize);"
    , "    for _ in 0..n {"
    , "        out.push(lcg_next(&mut seed) as i64);"
    , "    }"
    , "    Box::pin(ready(SkyResult::Ok(out)))"
    , "}"
    , "pub fn crypto_random_token(n: i64) -> SkyTask<String> {"
    , "    let mut seed = lcg_seed();"
    , "    let hex = \"0123456789abcdef\";"
    , "    let mut out = String::with_capacity((n * 2) as usize);"
    , "    for _ in 0..n {"
    , "        let b = lcg_next(&mut seed);"
    , "        out.push(hex.as_bytes()[(b & 0x0f) as usize] as char);"
    , "        out.push(hex.as_bytes()[((b >> 4) & 0x0f) as usize] as char);"
    , "    }"
    , "    Box::pin(ready(SkyResult::Ok(out)))"
    , "}"
    , ""
    , "// --- Crypto.sha256 (HEX stub) ---"
    , "pub fn crypto_sha256(s: String) -> String {"
    , "    let hex = \"0123456789abcdef\";"
    , "    use std::collections::hash_map::DefaultHasher;"
    , "    use std::hash::{Hash, Hasher};"
    , "    let mut h = DefaultHasher::new();"
    , "    s.hash(&mut h);"
    , "    let v = h.finish();"
    , "    format!(\"{:016x}\", v)"
    , "}"
    , ""
    , "// --- Time helpers ---"
    , "pub fn time_time_string(ms: i64) -> String {"
    , "    format!(\"timestamp:{}\", ms)"
    , "}"
    , ""
    , "// --- Http stub (returns error — no HTTP client yet) ---"
    , "#[derive(Clone)]"
    , "pub struct SkyCoreHttpResponse { pub body: String, pub status: i64 }"
    , "pub fn http_get(url: String) -> SkyTask<SkyCoreHttpResponse> {"
    , "    let _ = url;"
    , "    Box::pin(ready(SkyResult::Err(str_err(\"HTTP client not available in Rust target\".into()))))"
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
    , "pub fn string_to_int(s: String) -> SkyResult<String, i64> {"
    , "    match s.parse::<i64>() { Ok(v) => SkyResult::Ok(v), Err(_) => SkyResult::Err(String::new()) }"
    , "}"
    , ""
    , "// Result helper"
    , "pub fn result_with_default<A>(def: A) -> impl FnOnce(SkyResult<SkyError, A>) -> A {"
    , "    |r| match r { SkyResult::Ok(v) => v, SkyResult::Err(_) => def }"
    , "}"
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

-- | SkyError type alias — conditional on Error module presence
skyErrorLine :: RustBuilder -> [String]
skyErrorLine b =
    [ ""
    , if hasErrorType b
      then "type SkyError = " ++ toCamelCase "Sky_Core_Error_Error" ++ ";"
      else "type SkyError = String;"
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
entryPointSection :: [String]
entryPointSection =
    [ ""
    , "// ==========================================="
    , "// ENTRY POINT"
    , "// ==========================================="
    , ""
    , "fn main() {"
    , "    sky_main();"
    , "}"
    ]

typeDefToString :: RustTypeDef -> String
typeDefToString (REnumDef name variants) = 
    "#[derive(Clone)]\npub enum " ++ name ++ " {\n" ++ intercalate ",\n" (map (\(n, mt) -> "    " ++ n ++ maybe "" (\x -> "(" ++ x ++ ")") mt) variants) ++ "\n}"
typeDefToString (RStructDef name fields) =
    "#[derive(Clone)]\npub struct " ++ name ++ " {\n" ++ intercalate ",\n" (map (\(n, t) -> "    " ++ n ++ ": " ++ t) fields) ++ "\n}"
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
    _ -> toSnakeCase (mod ++ "_" ++ name)

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
    ["#[derive(Clone)]",
     "pub struct " ++ name ++ " {", 
     intercalate ",\n" (map (\(n, t) -> "    " ++ n ++ ": " ++ t) fields), 
     "}"]
itemToRustStrings (RustEnum name variants) = 
    ["#[derive(Clone)]",
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
            [ name | RStructDef name _ <- builderTypes b ]
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
                , not (elem t ["String", "i64", "f64", "bool", "char", "()", "SkyValue", "Db", "SkyTask", "SkyError", "HashMap"])
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
hasErrorType b = any isErrorEnum (builderTypes b)
  where
    isErrorEnum (REnumDef n _) = n == toCamelCase "Sky_Core_Error_Error"
    isErrorEnum _ = False

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
    ] ++ tokioDep ++ sqlxDep ++ jsonDep
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

-- | Map sky.toml driver name to sqlx cargo feature
dbFeature :: String -> String
dbFeature "postgres" = "postgres"
dbFeature "mysql"    = "mysql"
dbFeature _          = "sqlite"

intercalate :: String -> [String] -> String
intercalate _ [] = ""
intercalate _ [x] = x
intercalate s (x:xs) = x ++ s ++ intercalate s xs