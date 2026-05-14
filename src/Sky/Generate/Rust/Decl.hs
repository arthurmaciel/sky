module Sky.Generate.Rust.Decl where

import Sky.AST.Canonical
import Sky.Generate.Rust.Expr
import Sky.Generate.Rust.Types
import Sky.Generate.Rust.Pattern

data RustDecl
    = DFunction String [String] RustExpr (Maybe RustType)
    | DTypeAlias String RustType
    | DStruct String [(String, RustType)]
    | DEnum String [(String, Maybe RustType)]
    | DConst String RustExpr
    | DImport String
    | DModule String [RustDecl]
    deriving (Eq, Show)

declToRust :: CanonicalDecl -> [RustDecl]
declToRust decl = case decl of
    DAnnot name params body typ ->
        [DFunction (varToRustName name)
            (map varToRustName params)
            (exprToRust body)
            (fmap typeToRust typ)]
    DDef name params body ->
        [DFunction (varToRustName name)
            (map varToRustName params)
            (exprToRust body)
            Nothing]
    DType name vars constrs ->
        case constrs of
            [] -> [DTypeAlias name (RustCustom name)]
            [(cname, Nothing)] -> [DEnum name [(cname, Nothing)]]
            [(cname, Just (TRecord fields))] -> [DStruct name (map (\(n, t) -> (n, typeToRust t)) fields)]
            _ -> [DEnum name (map (\(n, mt) -> (n, fmap typeToRust mt)) constrs)]
    DImportModule name exps -> [DImport name]
    _ -> []

varToRustName :: String -> String
varToRustName name = case name of
    "True" -> "true"
    "False" -> "false"
    "Nothing" -> "None"
    "Just" -> "Some"
    _ -> name

declToString :: RustDecl -> String
declToString d = case d of
    DFunction name params body retType ->
        let
            paramsStr = intercalate ", " params
            retStr = case retType of
                Just t -> " -> " ++ rustTypeToString t
                Nothing -> ""
            implStr = "fn " ++ name ++ "(" ++ paramsStr ++ ")" ++ retStr ++ " { " ++ exprToRustString body ++ " }"
        in implStr

    DTypeAlias name typ ->
        "type " ++ name ++ " = " ++ rustTypeToString typ ++ ";"

    DStruct name fields ->
        "struct " ++ name ++ " {\n" ++ intercalate ",\n" (map fieldToStr fields) ++ "\n}"
      where
        fieldToStr (n, t) = "    " ++ n ++ " : " ++ rustTypeToString t

    DEnum name variants ->
        "enum " ++ name ++ " {\n" ++ intercalate ",\n" (map variantToStr variants) ++ "\n}"
      where
        variantToStr (vname, Nothing) = "    " ++ vname
        variantToStr (vname, Just t) = "    " ++ vname "(" ++ rustTypeToString t ++ ")"

    DConst name expr ->
        "const " ++ name ++ " : _ = " ++ exprToRustString expr ++ ";"

    DImport path ->
        "// import: " ++ path

    DModule name decls ->
        "mod " ++ name ++ " {\n" ++ intercalate "\n\n" (map declToString decls) ++ "\n}"

exprToRustString :: RustExpr -> String
exprToRustString e = case e of
    RustLit lit -> case lit of
        LInt n -> show n
        LFloat f -> show f
        LBool True -> "true"
        LBool False -> "false"
        LChar c -> show c
        LString s -> show s
        LUnit -> "()"
    RustVar name -> name
    RustApp f args -> exprToRustString f ++ "(" ++ intercalate ", " (map exprToRustString args) ++ ")"
    RustLambda param body -> "move |" ++ param ++ "| -> _ { " ++ exprToRustString body ++ " }"
    RustLet bindings body ->
        "let " ++ intercalate "; " (map (\(n, v) -> n ++ " = " ++ exprToRustString v) bindings) ++ "; " ++ exprToRustString body
    RustIf cond thenE elseE ->
        "if " ++ exprToRustString cond ++ " { " ++ exprToRustString thenE ++ " } else { " ++ exprToRustString elseE ++ " }"
    RustCase scrut branches -> "match " ++ exprToRustString scrut ++ " { " ++ generateMatchArms branches ++ " }"
    RustRecord fields -> "{ " ++ intercalate ", " (map (\(n, v) -> n ++ " : " ++ exprToRustString v) fields) ++ " }"
    RustAccess rec field -> exprToRustString rec ++ "." ++ field
    RustTuple els -> "(" ++ intercalate ", " (map exprToRustString els) ++ ")"
    RustBinOp op a b -> "(" ++ exprToRustString a ++ " " ++ binOpStr op ++ " " ++ exprToRustString b ++ ")"
    RustNative name -> "/* native: " ++ name ++ " */"

binOpStr op = case op of
    Add -> "+"; Sub -> "-"; Mul -> "*"; Div -> "/"; Mod -> "%"
    Eq -> "=="; Neq -> "!="; Lt -> "<"; Gt -> ">"; Le -> "<="; Ge -> ">="
    And -> "&&"; Or -> "||"
    Cons -> "..."
    Append -> "..."

generateMatchArms :: [(Pattern, RustExpr)] -> String
generateMatchArms branches = intercalate ", " (map branchToArm branches)
  where
    branchToArm (pat, expr) -> patternToString (patternToRust pat) ++ " => " ++ exprToRustString expr

patternToString :: RustPattern -> String
patternToString p = case p of
    RPWild -> "_"
    RPVar name -> name
    RPInt n -> show n
    RPFloat f -> show f
    RPBool True -> "true"
    RPBool False -> "false"
    RPChar c -> show c
    RPString s -> show s
    RPConstructor name args -> name ++ (if null args then "" else " " ++ intercalate " " (map patternToString args))
    RPTuple pats -> "(" ++ intercalate ", " (map patternToString pats) ++ ")"
    RPRecord fields -> "{ " ++ intercalate ", " (map (\(n, p) -> n ++ " : " ++ patternToString p) fields) ++ " }"
    RPOr pats -> intercalate " | " (map patternToString pats)

intercalate :: String -> [String] -> String
intercalate _ [] = ""
intercalate _ [x] = x
intercalate s (x:xs) = x ++ s ++ intercalate s xs

rustTypeToString :: RustType -> String
rustTypeToString rt = case rt of
    RustPrim p -> case p of
        PInt -> "i64"
        PFloat -> "f64"
        PBool -> "bool"
        PChar -> "char"
        PString -> "String"
        PUnit -> "()"
    RustVec a -> "Vec<" ++ rustTypeToString a ++ ">"
    RustOption a -> "Option<" ++ rustTypeToString a ++ ">"
    RustResult e a -> "Result<" ++ rustTypeToString a ++ ", " ++ rustTypeToString e ++ ">"
    RustFuture a -> "impl Future<Output = Result<" ++ rustTypeToString a ++ ", SkyError>>"
    RustTuple ts -> "(" ++ intercalate ", " (map rustTypeToString ts) ++ ")"
    RustRecord fields -> "struct { " ++ intercalate "; " (map (\(n, t) -> n ++ ": " ++ rustTypeToString t) fields) ++ " }"
    RustEnum _ -> "enum"
    RustCustom name -> name
    RustFunction args ret -> "fn(" ++ intercalate ", " (map rustTypeToString args) ++ ") -> " ++ rustTypeToString ret
    RustOpaque -> "SkyValue"