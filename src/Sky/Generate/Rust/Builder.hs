module Sky.Generate.Rust.Builder where

import Data.List (isSuffixOf, isPrefixOf)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Sky.AST.Canonical as Can
import qualified Sky.Sky.ModuleName as ModuleName
import qualified Sky.Reporting.Annotation as Ann

type CanonicalModule = Can.Module

data RustBuilder = RustBuilder
    { builderModules :: [RustModule]
    , builderTypes   :: [RustTypeDef]
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
    }

-- | Build a map from field-name-signature to struct name
buildRecordMap :: [Can.Module] -> Map.Map String String
buildRecordMap mods = Map.fromList
    [ (intercalate "," (Map.keys fields), modPrefix ++ "_" ++ name)
    | mod <- mods
    , let modPrefix = moduleNameToRust (Can._name mod)
    , (name, Can.Alias _ (Can.TRecord fields _)) <- Map.toList (Can._aliases mod)
    ]

buildModule :: EmitCtx -> Can.Module -> RustModule
buildModule ctx mod = 
    let modPrefix = moduleNameToRust (Can._name mod)
        items = declsToRustItems ctx (Can._decls mod)
        prefixItem (RustFunction n g p r b)
            | n == "sky_main" || n == "main" = RustFunction n g p r b
            | otherwise = RustFunction (modPrefix ++ "_" ++ n) g p r b
        prefixItem other = other
    in RustModule
        { modName = modPrefix
        , modItems = map prefixItem items
        }

moduleNameToRust :: ModuleName.Canonical -> String
moduleNameToRust mod = 
    map (\c -> if c == '.' then '_' else c) (ModuleName._name mod)

declsToRustItems :: EmitCtx -> Can.Decls -> [RustItem]
declsToRustItems _ctx Can.SaveTheEnvironment = []
declsToRustItems ctx (Can.Declare def rest) = defToRustItem ctx def : declsToRustItems ctx rest
declsToRustItems ctx (Can.DeclareRec def defs rest) = 
    map (defToRustItem ctx) (def : defs) ++ declsToRustItems ctx rest

-- | Walk TLambda chain to extract the innermost (return) type
extractReturnType :: Can.Type -> Can.Type
extractReturnType (Can.TLambda _ ret) = extractReturnType ret
extractReturnType ty = ty

-- | Check if a type contains unresolved type variables (should not be emitted)
hasTypeVars :: Can.Type -> Bool
hasTypeVars (Can.TVar _) = True
hasTypeVars (Can.TLambda a b) = hasTypeVars a || hasTypeVars b
hasTypeVars (Can.TType _ _ args) = any hasTypeVars args
hasTypeVars (Can.TTuple a b rest) = any hasTypeVars (a:b:rest)
hasTypeVars (Can.TRecord fields _) = any (hasTypeVars . Can._fieldType) (Map.elems fields)
hasTypeVars _ = False

defToRustItem :: EmitCtx -> Can.Def -> RustItem
defToRustItem ctx (Can.Def (Ann.At _ name) params body) = 
    let rustName = if name == "main" then "sky_main" else name
        n = length params
        genVars = if null params then "" 
                  else "<" ++ intercalate ", " (map (\i -> "T" ++ show i) [0..n-1]) ++ ">"
        params' = map (\(i, p) -> patternToRustParam p ++ ": T" ++ show i) (zip [0..] params)
        -- sky_main always returns () since the entry wrapper handles the Task
        retTy = if name == "main" then "()"
                else case Map.lookup name (ecSolvedTypes ctx) of
                    Just ty -> let ret = extractReturnType ty
                              in if hasTypeVars ret then "()" else typeToRustString ret
                    Nothing -> "()"
    in RustFunction rustName genVars params' retTy (exprToRustString ctx body)
defToRustItem ctx (Can.TypedDef (Ann.At _ name) _ pats body retTy) = 
    let rustName = if name == "main" then "sky_main" else name
        params = map (\(pat, ty) -> patternToRustParam pat ++ ": " ++ typeToRustString ty) pats
        -- sky_main always returns () since the entry wrapper handles the Task
        ret = if name == "main" then "()" else typeToRustString retTy
    in RustFunction rustName "" params ret (exprToRustString ctx body)
defToRustItem ctx (Can.DestructDef pat expr) =
    RustFunction "_destruct" "" [patternToRustParam pat] "()" (exprToRustString ctx expr)

unionsToRustTypes :: String -> Map.Map String Can.Union -> [RustTypeDef]
unionsToRustTypes modPrefix unions = map (\(name, u) -> unionToRustTypeDef modPrefix name u) (Map.toList unions)

unionToRustTypeDef :: String -> String -> Can.Union -> RustTypeDef
unionToRustTypeDef modPrefix typeName (Can.Union _ alts _ _) = 
    REnumDef (modPrefix ++ "_" ++ typeName) (map ctorToRust alts)
  where
    ctorToRust (Can.Ctor name idx arity _) = 
        (name, if arity == 0 then Nothing else Just (intercalate ", " (replicate arity "()")))

aliasesToRustTypes :: String -> Map.Map String Can.Alias -> [RustTypeDef]
aliasesToRustTypes modPrefix aliases = concatMap (\(name, alias) -> aliasToRustTypeDef modPrefix name alias) (Map.toList aliases)

aliasToRustTypeDef :: String -> String -> Can.Alias -> [RustTypeDef]
aliasToRustTypeDef modPrefix name (Can.Alias _vars ty) = case ty of
    Can.TRecord fields _ -> 
        [RStructDef (modPrefix ++ "_" ++ name) (map (\(n, Can.FieldType _ ft) -> (n, typeToRustString ft)) (Map.toList fields))]
    _ -> 
        [RAliasDef (modPrefix ++ "_" ++ name) (typeToRustString ty)]

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
    Can.TType _ "Result" [e, a] -> "SkyResult<" ++ typeToRustString a ++ ", " ++ typeToRustString e ++ ">"
    Can.TRecord _fields _ -> "()"  -- TRecord: emitted as named struct via alias
    Can.TTuple a b rest -> "(" ++ intercalate ", " (map typeToRustString (a:b:rest)) ++ ")"
    Can.TVar v -> v
    Can.TType modName name [] ->
        let modStr = ModuleName._name modName
            modPrefix = if null modStr then "" else map (\c -> if c == '.' then '_' else c) modStr ++ "_"
        in modPrefix ++ name
    Can.TType modName name args ->
        let modStr = ModuleName._name modName
            modPrefix = if null modStr then "" else map (\c -> if c == '.' then '_' else c) modStr ++ "_"
        in modPrefix ++ name ++ "<" ++ intercalate ", " (map typeToRustString args) ++ ">"
    Can.TLambda a b -> "fn(" ++ typeToRustString a ++ ") -> " ++ typeToRustString b
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

patternToRustParam :: Can.Pattern -> String
patternToRustParam (Ann.At _ pat) = case pat of
    Can.PVar n -> rustSafeIdent n
    Can.PAnything -> "_"
    _ -> "_"

exprToRustString :: EmitCtx -> Can.Expr -> String
exprToRustString ctx (Ann.At _ expr) = exprToRustInner ctx expr

exprToRustInner :: EmitCtx -> Can.Expr_ -> String
exprToRustInner ctx e = case e of
    Can.VarLocal name -> rustSafeIdent name
    Can.VarTopLevel mod name -> 
        map (\c -> if c == '.' then '_' else c) (ModuleName._name mod) ++ "_" ++ name
    Can.VarKernel mod name -> kernelToRust mod name
    Can.VarCtor _ modName typeName ctorName _ -> kernelCtorToRust modName typeName ctorName
    Can.Chr c -> show c
    Can.Str s -> show s ++ ".to_string()"
    Can.Int i -> show i
    Can.Float f -> show f
    Can.List es -> "vec![" ++ intercalate ", " (map (exprToRustString ctx) es) ++ "]"
    Can.Negate e -> "-" ++ exprToRustString ctx e
    Can.Binop op _ _ _ a b 
        | op == "|>" -> exprToRustString ctx b ++ "(" ++ exprToRustString ctx a ++ ")"
        | op == "<|" -> exprToRustString ctx a ++ "(" ++ exprToRustString ctx b ++ ")"
        | op == "::" -> "sky_list_cons(" ++ exprToRustString ctx a ++ ", " ++ exprToRustString ctx b ++ ")"
        | op == "++" -> "(" ++ exprToRustString ctx a ++ " + " ++ exprToRustString ctx b ++ ")"
        | otherwise -> 
            "(" ++ exprToRustString ctx a ++ " " ++ binopToRust op ++ " " ++ exprToRustString ctx b ++ ")"
    Can.Lambda params body -> 
        "|" ++ intercalate ", " (map patternToRustParam params) ++ "| { " ++ exprToRustString ctx body ++ " }"
    Can.Call fn args -> case exprToRustString ctx fn of
        fnName | "println" `isSuffixOf` fnName -> 
            let fmt = concat (replicate (length args) "{}")
            in "println!(\"" ++ fmt ++ "\", " ++ intercalate ", " (map (exprToRustString ctx) args) ++ ")"
        _ -> exprToRustString ctx fn ++ "(" ++ intercalate ", " (map (exprToRustString ctx) args) ++ ")"
    Can.If branches elseBranch -> 
        "if " ++ intercalate " else " (map (\(c, t) -> exprToRustString ctx c ++ " { " ++ exprToRustString ctx t ++ " }") branches)
        ++ " else { " ++ exprToRustString ctx elseBranch ++ " }"
    Can.Let def body -> 
        "let " ++ defToRustString ctx def ++ "; " ++ exprToRustString ctx body
    Can.LetRec defs body ->
        "let mut " ++ intercalate "; let mut " (map (defToRustString ctx) defs) ++ "; " ++ exprToRustString ctx body
    Can.LetDestruct pat expr body ->
        "let " ++ patternToMatchString pat ++ " = " ++ exprToRustString ctx expr ++ "; " ++ exprToRustString ctx body
    Can.Case scrut branches -> 
        "match " ++ exprToRustString ctx scrut ++ " { " ++ 
        intercalate ", " (map (branchToRustString ctx) branches) ++ " }"
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
defToRustString ctx (Can.Def (Ann.At _ name) params body) =
    name ++ " = |" ++ intercalate ", " (map patternToRustParam params) ++ "| { " ++ exprToRustString ctx body ++ " }"
defToRustString _ctx _ = "_ = unimplemented()"

branchToRustString :: EmitCtx -> Can.CaseBranch -> String
branchToRustString ctx (Can.CaseBranch pat body) =
    patternToMatchString pat ++ " => " ++ exprToRustString ctx body

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
        ctx = EmitCtx { ecRecordMap = recordMap, ecSolvedTypes = solvedTypes }
    in RustBuilder
        { builderModules = map (buildModule ctx) mods
        , builderTypes = concatMap (\m -> 
            let prefix = moduleNameToRust (Can._name m)
            in unionsToRustTypes prefix (Can._unions m) ++ aliasesToRustTypes prefix (Can._aliases m)) mods
        }

emitRust :: RustBuilder -> String
emitRust b = unlines $
    [ "// Generated by Sky compiler (Rust target)"
    , "#![allow(unused)]"
    , ""
    , "// ==========================================="
    , "// SKY RUNTIME (inline)"
    , "// ==========================================="
    , ""
    , "use std::fmt;"
    , "use std::future::Future;"
    , "use std::future::ready;"
    , "use std::pin::Pin;"
    , ""
    , "// Basic types"
    , "type SkyInt = i64;"
    , "type SkyFloat = f64;"
    , "type SkyBool = bool;"
    , "type SkyString = String;"
    , "type SkyValue = String;"

    , ""
    , "// Error type for Task"
    , "pub struct Error(pub String);"
    , ""
    , "// Maybe equivalent"
    , "pub enum SkyMaybe<T> {"
    , "    Nothing,"
    , "    Just(T),"
    , "}"
    , ""
    , "// Result equivalent"
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
    , "    match s.parse::<i64>() { Ok(v) => SkyResult::Ok(v), Err(_) => SkyResult::Err(\"parse error\".to_string()) }"
    , "}"
    , ""
    , "// Float helpers"
    , "pub fn sky_float_to_string(f: f64) -> String { format!(\"{}\", f) }"
    , ""
    , "// ==========================================="
    , "// KERNEL HELPER STUBS (sync impl, no async/await)"
    , "// ==========================================="
    , ""
    , "// Task helpers (all stubs - real async needs external crate)"
    , "type SkyTask<A> = Pin<Box<dyn Future<Output = SkyResult<String, A>> + Send>>;"
    , "pub fn Task_succeed<A: Send + 'static>(a: A) -> SkyTask<A> { Box::pin(ready(SkyResult::Ok(a))) }"
    , "pub fn Task_map<A: Send + 'static, B: Send + 'static>(_f: impl FnOnce(A) -> B + Clone + Send + 'static) -> impl FnOnce(SkyTask<A>) -> SkyTask<B> {"
    , "    move |_task| Box::pin(ready(SkyResult::Err(String::new())))"
    , "}"
    , "pub fn Task_andThen<A: Send + 'static, B: Send + 'static>(_f: impl FnOnce(A) -> SkyTask<B> + Clone + Send + 'static) -> impl FnOnce(SkyTask<A>) -> SkyTask<B> {"
    , "    move |_task| Box::pin(ready(SkyResult::Err(String::new())))"
    , "}"
    , "pub fn Task_onError<A: Send + 'static>(_f: impl FnOnce(SkyResult<String, A>) -> SkyTask<A> + Clone + Send + 'static) -> impl FnOnce(SkyTask<A>) -> SkyTask<A> {"
    , "    move |_task| Box::pin(ready(SkyResult::Err(String::new())))"
    , "}"
    , "pub fn Task_run<A>(_task: SkyTask<A>) -> SkyResult<String, A> { unimplemented!() }"
    , ""
    , "// System helpers"
    , "pub fn System_args() -> SkyTask<Vec<String>> { Box::pin(ready(SkyResult::Ok(std::env::args().collect()))) }"
    , "pub fn System_exit(code: i64) -> ! { std::process::exit(code as i32) }"
    , ""
    , "// Log helpers"
    , "pub fn Log_info(msg: String) -> SkyTask<()> { println!(\"{}\", msg); Box::pin(ready(SkyResult::Ok(()))) }"
    , "pub fn Log_infoWith(msg: String, _attrs: Vec<String>) -> SkyTask<()> { println!(\"{}\", msg); Box::pin(ready(SkyResult::Ok(()))) }"
    , "pub fn Log_errorWith(msg: String, _attrs: Vec<String>) -> SkyTask<()> { eprintln!(\"{}\", msg); Box::pin(ready(SkyResult::Ok(()))) }"
    , ""
    , "// DB stubs"
    , "type Db = String;"
    , "pub fn Db_connect(_url: String) -> SkyTask<Db> { Box::pin(ready(SkyResult::Ok(String::new()))) }"
    , "pub fn Db_exec(_conn: Db, _sql: String, _params: Vec<String>) -> SkyTask<()> { Box::pin(ready(SkyResult::Ok(()))) }"
    , "pub fn Db_execRaw(_conn: Db, _sql: String) -> SkyTask<()> { Box::pin(ready(SkyResult::Ok(()))) }"
    , "pub fn Db_query(_conn: Db, _sql: String, _params: Vec<String>) -> SkyTask<Vec<Vec<String>>> { Box::pin(ready(SkyResult::Ok(vec![]))) }"
    , "pub fn Db_getField(_field: String, _row: Vec<String>) -> String { String::new() }"
    , ""
    , "// String helpers"
    , "pub fn String_join(sep: String, strs: Vec<String>) -> String { strs.join(&sep) }"
    , ""
    , "// Result helper"
    , "pub fn Result_withDefault<A: Send + 'static>(def: A) -> impl FnOnce(SkyResult<String, A>) -> A {"
    , "    move |r| match r { SkyResult::Ok(v) => v, SkyResult::Err(_) => def }"
    , "}"
    , "// Debug trait for logging"
    , "impl fmt::Debug for Error {"
    , "    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {"
    , "        write!(f, \"Error({})\", self.0)"
    , "    }"
    , "}"
    , ""
    , "// ==========================================="
    , "// USER TYPES"
    , "// ==========================================="
    , ""
    ] ++ map typeDefToString (builderTypes b) ++
    [ "" ] ++ concatMap moduleToRustStrings (builderModules b) ++
    [ ""
    , "// ==========================================="
    , "// FFI PLACEHOLDER TYPES (types referenced but not defined)"
    , "// ==========================================="
    , ""
    ] ++ map ffiPlaceholder (collectUndefinedTypes b) ++
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
    "enum " ++ name ++ " {\n" ++ intercalate ",\n" (map (\(n, mt) -> "    " ++ n ++ maybe "" (\x -> "(" ++ x ++ ")") mt) variants) ++ "\n}"
typeDefToString (RStructDef name fields) =
    "struct " ++ name ++ " {\n" ++ intercalate ",\n" (map (\(n, t) -> "    " ++ n ++ ": " ++ t) fields) ++ "\n}"
typeDefToString (RAliasDef name ty) = "type " ++ name ++ " = " ++ ty ++ ";"

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
             in modPrefix ++ typeName ++ "::" ++ ctorName

kernelToRust :: String -> String -> String
kernelToRust mod name = case (mod, name) of
    ("Log", "println") -> "println"
    ("Std.Log", "println") -> "println"
    _ -> mod ++ "_" ++ name

exprToStatement :: String -> String
exprToStatement expr = if null expr then "" 
    else if last expr == '}' then expr  -- block expression
    else expr ++ ";"  -- add semicolon for statement

itemToRustStrings :: RustItem -> [String]
itemToRustStrings (RustFunction name generics params retType body) = 
    let ret = if retType == "()" then "" else " -> " ++ retType
    in ["fn " ++ name ++ generics ++ "(" ++ intercalate ", " params ++ ")" ++ ret ++ " {", "    " ++ exprToStatement body, "}"]
itemToRustStrings (RustStruct name fields) = 
    ["struct " ++ name ++ " {", 
     intercalate ",\n" (map (\(n, t) -> "    " ++ n ++ ": " ++ t) fields), 
     "}"]
itemToRustStrings (RustEnum name variants) = 
    ["enum " ++ name ++ " {",
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
                , not (elem t ["String", "i64", "f64", "bool", "char", "()", "SkyValue", "Db"])
                , not ("T" `isPrefixOf` t && all (\c -> c >= '0' && c <= '9') (drop 1 t))  -- generic params T0, T1, etc.
                , not ("Vec<" `isPrefixOf` t)
                , not ("Option" `isPrefixOf` t)
                , not ("Result" `isPrefixOf` t)
                , not ("SkyMaybe" `isPrefixOf` t)
                , not ("SkyResult" `isPrefixOf` t)
                , not ("Box<" `isPrefixOf` t)
                , not ("fn(" `isPrefixOf` t)
            ]
    in Set.toList (Set.difference referenced defined)

ffiPlaceholder :: String -> String
ffiPlaceholder name = "type " ++ name ++ " = String;"

intercalate :: String -> [String] -> String
intercalate _ [] = ""
intercalate _ [x] = x
intercalate s (x:xs) = x ++ s ++ intercalate s xs