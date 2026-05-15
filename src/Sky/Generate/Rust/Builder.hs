module Sky.Generate.Rust.Builder where

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
    RustFunction name (map patternToRustParam params) (exprToRustString body)
defToRustItem (Can.TypedDef (Ann.At _ name) _ pats body _) = 
    RustFunction name (map (patternToRustParam . fst) pats) (exprToRustString body)
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
    Can.TUnit -> "()"
    Can.TType _ "List" [a] -> "Vec<" ++ typeToRustString a ++ ">"
    Can.TType _ "Maybe" [a] -> "Option<" ++ typeToRustString a ++ ">"
    Can.TType _ "Result" [e, a] -> "Result<" ++ typeToRustString a ++ ", " ++ typeToRustString e ++ ">"
    Can.TVar v -> v
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
    Can.VarKernel mod name -> mod ++ "::" ++ name
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
    Can.Call fn args -> 
        exprToRustString fn ++ "(" ++ intercalate ", " (map exprToRustString args) ++ ")"
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
    , "// Sky runtime types"
    , "type SkyInt = i64;"
    , "type SkyFloat = f64;"
    , "type SkyBool = bool;"
    , "type SkyString = String;"
    , ""
    , "struct SkyMaybe<T> { value: Option<T> }"
    , "struct SkyResult<E, A> { result: Result<A, E> }"
    , ""
    , "// User-defined types"
    , ""
    ] ++ map typeDefToString (builderTypes b) ++
    [ "" ] ++ concatMap moduleToRustStrings (builderModules b) ++
    [ ""
    , "fn main() {"
    , "    main_();"
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

itemToRustStrings :: RustItem -> [String]
itemToRustStrings (RustFunction name params body) = 
    ["fn " ++ name ++ "(" ++ intercalate ", " params ++ ") -> () {", "    " ++ body, "}"]
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