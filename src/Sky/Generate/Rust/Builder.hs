module Sky.Generate.Rust.Builder where

import Data.List (isSuffixOf)
import qualified Data.Map.Strict as Map
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
    = RustFunction String [String] String
    | RustStruct String [(String, String)]
    | RustEnum String [(String, Maybe String)]
    | RustTypeAlias String String

data RustTypeDef
    = REnumDef String [(String, Maybe String)]
    | RStructDef String [(String, String)]
    | RAliasDef String String

buildModule :: Can.Module -> RustModule
buildModule mod = RustModule
    { modName = moduleNameToRust (Can._name mod)
    , modItems = declsToRustItems (Can._decls mod)
    }

moduleNameToRust :: ModuleName.Canonical -> String
moduleNameToRust mod = 
    map (\c -> if c == '.' then '_' else c) (ModuleName._name mod)

declsToRustItems :: Can.Decls -> [RustItem]
declsToRustItems Can.SaveTheEnvironment = []
declsToRustItems (Can.Declare def rest) = defToRustItem def : declsToRustItems rest
declsToRustItems (Can.DeclareRec def defs rest) = 
    map defToRustItem (def : defs) ++ declsToRustItems rest

defToRustItem :: Can.Def -> RustItem
defToRustItem (Can.Def (Ann.At _ name) params body) = 
    let rustName = if name == "main" then "sky_main" else name
    in RustFunction rustName (map patternToRustParam params) (exprToRustString body)
defToRustItem (Can.TypedDef (Ann.At _ name) _ pats body _) = 
    let rustName = if name == "main" then "sky_main" else name
    in RustFunction rustName (map (patternToRustParam . fst) pats) (exprToRustString body)
defToRustItem (Can.DestructDef pat expr) =
    RustFunction "_destruct" [patternToRustParam pat] (exprToRustString expr)

unionsToRustTypes :: Map.Map String Can.Union -> [RustTypeDef]
unionsToRustTypes unions = map unionToRustTypeDef (Map.elems unions)

unionToRustTypeDef :: Can.Union -> RustTypeDef
unionToRustTypeDef (Can.Union _ alts _ _) = 
    REnumDef "SkyEnum" (map ctorToRust alts)
  where
    ctorToRust (Can.Ctor name idx arity _) = 
        (name, if arity == 0 then Nothing else Just (intercalate ", " (replicate arity "()")))

aliasesToRustTypes :: Map.Map String Can.Alias -> [RustTypeDef]
aliasesToRustTypes aliases = map aliasToRustTypeDef (Map.elems aliases)

aliasToRustTypeDef :: Can.Alias -> RustTypeDef
aliasToRustTypeDef (Can.Alias vars ty) = 
    RAliasDef ("Alias" ++ show (length vars)) (typeToRustString ty)

typeToRustString :: Can.Type -> String
typeToRustString t = case t of
    Can.TType _ "Int" [] -> "i64"
    Can.TType _ "Float" [] -> "f64"
    Can.TType _ "Bool" [] -> "bool"
    Can.TType _ "Char" [] -> "char"
    Can.TType _ "String" [] -> "String"
    Can.TType _ "Task" [_, a] -> "Box<dyn Future<Output = Result<" ++ typeToRustString a ++ ", Error>> + Send>"
    Can.TUnit -> "()"
    Can.TType _ "List" [a] -> "Vec<" ++ typeToRustString a ++ ">"
    Can.TType _ "Maybe" [a] -> "Option<" ++ typeToRustString a ++ ">"
    Can.TType _ "Result" [e, a] -> "Result<" ++ typeToRustString a ++ ", " ++ typeToRustString e ++ ">"
    Can.TRecord fields _ -> "{" ++ intercalate ", " (map fieldToRust (Map.toList fields)) ++ "}"
        where fieldToRust (n, Can.FieldType _ ty) = n ++ ": " ++ typeToRustString ty
    Can.TTuple a b rest -> "(" ++ intercalate ", " (map typeToRustString (a:b:rest)) ++ ")"
    Can.TVar v -> v
    Can.TType _ name [] -> name  -- User-defined type
    Can.TType _ name args -> name ++ "<" ++ intercalate ", " (map typeToRustString args) ++ ">"
    Can.TLambda a b -> "fn(" ++ typeToRustString a ++ ") -> " ++ typeToRustString b
    _ -> "SkyValue"

patternToRustParam :: Can.Pattern -> String
patternToRustParam (Ann.At _ pat) = case pat of
    Can.PVar n -> n
    Can.PAnything -> "_"
    _ -> "_"

exprToRustString :: Can.Expr -> String
exprToRustString (Ann.At _ expr) = exprToRustInner expr

exprToRustInner :: Can.Expr_ -> String
exprToRustInner e = case e of
    Can.VarLocal name -> name
    Can.VarTopLevel mod name -> 
        map (\c -> if c == '.' then '_' else c) (ModuleName._name mod) ++ "_" ++ name
    Can.VarKernel mod name -> kernelToRust mod name
    Can.VarCtor{} -> "Ctor"  -- constructor value
    Can.Chr c -> show c
    Can.Str s -> show s
    Can.Int i -> show i
    Can.Float f -> show f
    Can.List es -> "vec![" ++ intercalate ", " (map exprToRustString es) ++ "]"
    Can.Negate e -> "-" ++ exprToRustString e
    Can.Binop op _ _ _ a b -> 
        "(" ++ exprToRustString a ++ " " ++ binopToRust op ++ " " ++ exprToRustString b ++ ")"
    Can.Lambda params body -> 
        "|" ++ intercalate ", " (map patternToRustParam params ++ [""]) ++ "| { " ++ exprToRustString body ++ " }"
    Can.Call fn args -> case exprToRustString fn of
        fnName | "println" `isSuffixOf` fnName -> 
            "println!(\"{}\", " ++ intercalate ", " (map exprToRustString args) ++ ")"
        _ -> exprToRustString fn ++ "(" ++ intercalate ", " (map exprToRustString args) ++ ")"
    Can.If branches elseBranch -> 
        "if " ++ intercalate " else " (map (\(c, t) -> exprToRustString c ++ " { " ++ exprToRustString t ++ " }") branches)
        ++ " else { " ++ exprToRustString elseBranch ++ " }"
    Can.Let def body -> 
        "let " ++ defToRustString def ++ "; " ++ exprToRustString body
    Can.LetRec defs body ->
        "let mut " ++ intercalate "; let mut " (map defToRustString defs) ++ "; " ++ exprToRustString body
    Can.LetDestruct pat expr body ->
        "let " ++ patternToMatchString pat ++ " = " ++ exprToRustString expr ++ "; " ++ exprToRustString body
    Can.Case scrut branches -> 
        "match " ++ exprToRustString scrut ++ " { " ++ 
        intercalate ", " (map branchToRustString branches) ++ " }"
    Can.Accessor field -> "|_record| _record." ++ field
    Can.Access record (Ann.At _ field) -> 
        exprToRustString record ++ "." ++ field
    Can.Update (Ann.At _ _field) record updates ->
        "let mut result = " ++ exprToRustString record ++ "; " ++
        intercalate "; " (map (\(f, Can.FieldUpdate _ expr) -> "result." ++ f ++ " = " ++ exprToRustString expr) (Map.toList updates)) ++
        "; result"
    Can.Record fields -> 
        "struct { " ++ intercalate ", " (map (\(k, v) -> k ++ ": " ++ exprToRustString v) (Map.toList fields)) ++ " }"
    Can.Unit -> "()"
    Can.Tuple a b rest -> 
        "(" ++ intercalate ", " (map exprToRustString (a:b:rest)) ++ ")"

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

defToRustString :: Can.Def -> String
defToRustString (Can.Def (Ann.At _ name) params body) =
    name ++ " = |" ++ intercalate ", " (map patternToRustParam params) ++ "| { " ++ exprToRustString body ++ " }"
defToRustString _ = "_ = unimplemented()"

branchToRustString :: Can.CaseBranch -> String
branchToRustString (Can.CaseBranch pat body) =
    patternToMatchString pat ++ " => " ++ exprToRustString body

patternToMatchString :: Can.Pattern -> String
patternToMatchString (Ann.At _ pat) = case pat of
    Can.PVar n -> n
    Can.PAnything -> "_"
    Can.PInt i -> show i
    Can.PBool b -> if b then "true" else "false"
    Can.PChr c -> show c
    Can.PStr s -> show s
    Can.PUnit -> "()"
    Can.PCtor{Can._p_name = name} -> name  -- constructor pattern
    Can.PTuple a b rest -> 
        "(" ++ intercalate ", " (map patternToMatchString (a:b:rest)) ++ ")"
    Can.PRecord fields -> "{" ++ intercalate ", " fields ++ "}"
    Can.PCons a b -> "::"  -- cons pattern
    Can.PList items -> "[" ++ intercalate ", " (map patternToMatchString items) ++ "]"
    Can.PAlias pat _ -> patternToMatchString pat
    _ -> "_"

buildProgram :: [Can.Module] -> RustBuilder
buildProgram mods = RustBuilder
    { builderModules = map buildModule mods
    , builderTypes = concatMap (\m -> unionsToRustTypes (Can._unions m) ++ aliasesToRustTypes (Can._aliases m)) mods
    }

emitRust :: RustBuilder -> String
emitRust b = unlines $
    [ "// Generated by Sky compiler (Rust target)"
    , ""
    , "// ==========================================="
    , "// SKY RUNTIME (inline)"
    , "// ==========================================="
    , ""
    , "use std::fmt;"
    , ""
    , "// Basic types"
    , "type SkyInt = i64;"
    , "type SkyFloat = f64;"
    , "type SkyBool = bool;"
    , "type SkyString = String;"
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
itemToRustStrings (RustFunction name params body) = 
    ["fn " ++ name ++ "(" ++ intercalate ", " params ++ ") {", "    " ++ exprToStatement body, "}"]
itemToRustStrings (RustStruct name fields) = 
    ["struct " ++ name ++ " {", 
     intercalate ",\n" (map (\(n, t) -> "    " ++ n ++ ": " ++ t) fields), 
     "}"]
itemToRustStrings (RustEnum name variants) = 
    ["enum " ++ name ++ " {",
     intercalate ",\n" (map (\(n, mt) -> "    " ++ n ++ maybe "" (\x -> "(" ++ x ++ ")") mt) variants),
     "}"]
itemToRustStrings (RustTypeAlias name ty) = ["type " ++ name ++ " = " ++ ty ++ ";"]

intercalate :: String -> [String] -> String
intercalate _ [] = ""
intercalate _ [x] = x
intercalate s (x:xs) = x ++ s ++ intercalate s xs