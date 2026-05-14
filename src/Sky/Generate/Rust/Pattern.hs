module Sky.Generate.Rust.Pattern where

import Sky.Generate.Rust.Expr

data RustPattern
    = RPWild
    | RPVar String
    | RPInt Int
    | RPFloat Double
    | RPBool Bool
    | RPChar Char
    | RPString String
    | RPConstructor String [RustPattern]
    | RPTuple [RustPattern]
    | RPRecord [(String, RustPattern)]
    | RPOr [RustPattern]
    deriving (Eq, Show)

patternToRust :: CanonicalPattern -> RustPattern
patternToRust pat = case pat of
    PWildcard -> RPWild
    PVar name -> RPVar name
    PInt n -> RPInt n
    PFloat f -> RPFloat f
    PBool b -> RPBool b
    PChar c -> RPChar c
    PString s -> RPString s
    PCtor name args -> RPConstructor name (map patternToRust args)
    PTuple pats -> RPTuple (map patternToRust pats)
    PRecord fields -> RPRecord (map (\(n, p) -> (n, patternToRust p)) fields)
    PAs name pat' -> RPVar name
    POr pats -> RPOr (map patternToRust pats)
    _ -> RPWild

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
    RPConstructor name args -> name ++ " " ++ intercalate " " (map patternToString args)
    RPTuple pats -> "(" ++ intercalate ", " (map patternToString pats) ++ ")"
    RPRecord fields -> "{ " ++ intercalate ", " (map (\(n, p) -> n ++ " : " ++ patternToString p) fields) ++ " }"
    RPOr pats -> intercalate " | " (map patternToString pats)

intercalate :: String -> [String] -> String
intercalate _ [] = ""
intercalate _ [x] = x
intercalate s (x:xs) = x ++ s ++ intercalate s xs

generateMatchArms :: [(Pattern, RustExpr)] -> String
generateMatchArms branches = intercalate ",\n" (map branchToArm branches)
  where
    branchToArm (pat, expr) = patternToString (patternToRust pat) ++ " => " ++ exprToRustString expr

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
        "let " ++ intercalate ", " (map (\(n, v) -> n ++ " = " ++ exprToRustString v) bindings) ++ "; " ++ exprToRustString body
    RustIf cond thenE elseE ->
        "if " ++ exprToRustString cond ++ " { " ++ exprToRustString thenE ++ " } else { " ++ exprToRustString elseE ++ " }"
    RustCase scrut branches -> "match " ++ exprToRustString scrut ++ " { " ++ generateMatchArms branches ++ " }"
    RustRecord fields -> "{ " ++ intercalate ", " (map (\(n, v) -> n ++ " : " ++ exprToRustString v) fields) ++ " }"
    RustAccess rec field -> exprToRustString rec ++ "." ++ field
    RustTuple els -> "(" ++ intercalate ", " (map exprToRustString els) ++ ")"
    RustBinOp op a b -> exprToRustString a ++ " " ++ binOpStr op ++ " " ++ exprToRustString b
    RustNative name -> name

binOpStr op = case op of
    Add -> "+"; Sub -> "-"; Mul -> "*"; Div -> "/"; Mod -> "%"
    Eq -> "=="; Neq -> "!="; Lt -> "<"; Gt -> ">"; Le -> "<="; Ge -> ">="
    And -> "&&"; Or -> "||"
    Cons -> "::"
    Append -> "++"