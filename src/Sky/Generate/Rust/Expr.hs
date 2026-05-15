module Sky.Generate.Rust.Expr where

import qualified Data.Map.Strict as Map
import qualified Sky.AST.Canonical as Can
import qualified Sky.Reporting.Annotation as A
import qualified Sky.Sky.ModuleName as ModuleName
import Sky.Generate.Rust.Types hiding (RustTuple, RustRecord)

data RustExpr
    = RustLit Literal
    | RustVar String
    | RustApp RustExpr [RustExpr]
    | RustLambda String RustExpr
    | RustLet [(String, RustExpr)] RustExpr
    | RustIf RustExpr RustExpr RustExpr
    | RustCase RustExpr [(Pattern, RustExpr)]
    | RustRecord [(String, RustExpr)]
    | RustAccess RustExpr String
    | RustTuple [RustExpr]
    | RustBinOp BinOp RustExpr RustExpr
    | RustFieldUpdate RustExpr [(String, RustExpr)]
    | RustUnit
    | RustList [RustExpr]
    | RustNegate RustExpr
    | RustNative String
    deriving (Eq, Show)

data Literal
    = LInt Int
    | LFloat Double
    | LBool Bool
    | LChar Char
    | LString String
    | LUnit
    deriving (Eq, Show)

data BinOp
    = Add | Sub | Mul | Div | Mod
    | Eq | Neq | Lt | Gt | Le | Ge
    | And | Or
    | Cons
    | Append
    deriving (Eq, Show)

data Pattern
    = PWild
    | PVar String
    | PInt Int
    | PFloat Double
    | PBool Bool
    | PChar Char
    | PString String
    | PConstructor String [Pattern]
    | PTuple [Pattern]
    | PRecord [(String, Pattern)]
    | PUnit
    deriving (Eq, Show)

exprToRust :: Can.Expr -> RustExpr
exprToRust (A.Located _ expr) = exprToRust_ expr

exprToRust_ :: Can.Expr_ -> RustExpr
exprToRust_ expr = case expr of
    Can.VarLocal name -> RustVar (varToRust name)
    Can.VarTopLevel (ModuleName.Canonical _ modName) name ->
        RustVar (modName ++ "_" ++ name)
    Can.VarKernel modName name ->
        RustVar (kernelToRust modName name)
    Can.VarCtor _ _modName name _ann -> RustVar (constructorToRust name)
    Can.Chr c -> RustLit (LChar (head c))
    Can.Str s -> RustLit (LString s)
    Can.Int i -> RustLit (LInt i)
    Can.Float f -> RustLit (LFloat f)
    Can.List elems -> RustList (map exprToRust elems)
    Can.Negate e -> RustNegate (exprToRust e)
    Can.Binop opName _modName _ann a b ->
        RustBinOp (binopToRust opName) (exprToRust a) (exprToRust b)
    Can.Lambda params body ->
        foldr (\p acc -> RustLambda (patternToVar p) acc)
              (exprToRust body) params
    Can.Call fn args ->
        RustApp (exprToRust fn) (map exprToRust args)
    Can.If branches elseBranch ->
        foldr (\(cond, thenExpr) acc ->
            RustIf (exprToRust cond) (exprToRust thenExpr) acc)
            (exprToRust elseBranch) branches
    Can.Let def body -> RustLet (defToBindings def) (exprToRust body)
    Can.LetRec defs body ->
        RustLet (concatMap defToBindings defs) (exprToRust body)
    Can.LetDestruct pat expr body ->
        RustLet [(patternToVar pat, exprToRust expr)] (exprToRust body)
    Can.Case scrut branches ->
        RustCase (exprToRust scrut) (map branchToRust branches)
    Can.Accessor field -> RustLambda "self" (RustAccess (RustVar "self") field)
    Can.Access record (A.Located _ field) ->
        RustAccess (exprToRust record) field
    Can.Update _name record updates ->
        RustFieldUpdate (exprToRust record)
            (map (\(f, e) -> (f, exprToRust e)) (map snd (Map.toList updates)))
    Can.Record fields ->
        RustRecord (map (\(k, v) -> (k, exprToRust v)) (Map.toList fields))
    Can.Unit -> RustUnit
    Can.Tuple a b rest -> RustTuple (exprToRust a : exprToRust b : map exprToRust rest)
    _ -> RustNative "unhandled"
  where
    branchToRust (Can.CaseBranch pat body) =
        (patternToRust pat, exprToRust body)

varToRust :: String -> String
varToRust name = case name of
    "True" -> "true"
    "False" -> "false"
    "Nothing" -> "None"
    "Just" -> "Some"
    _ -> case reverse name of
        c:_ | c == '_' -> reverse (tail (reverse name))
        _ -> name

defToBindings :: Can.Def -> [(String, RustExpr)]
defToBindings def = case def of
    Can.Def (A.Located _ name) pats body ->
        case pats of
            [] -> [(name, exprToRust body)]
            (p:_) -> [(name, foldr (\ap acc -> RustLambda (patternToVar ap) acc)
                              (exprToRust body) pats)]
    Can.TypedDef (A.Located _ name) _ pats body _ ->
        case pats of
            [] -> [(name, exprToRust body)]
            (p:_) -> [(name, foldr (\(ap, _) acc -> RustLambda (patternToVar ap) acc)
                              (exprToRust body) pats)]
    Can.DestructDef pat body ->
        [(patternToVar pat, exprToRust body)]

kernelToRust :: String -> String -> String
kernelToRust modName name = case (modName, name) of
    ("Task", "succeed") -> "Ok"
    ("Task", "fail") -> "Err"
    ("Task", "map") -> "task_map"
    ("Task", "andThen") -> "task_and_then"
    ("Result", "Ok") -> "Ok"
    ("Result", "Err") -> "Err"
    ("Result", "map") -> "result_map"
    ("Maybe", "Just") -> "Some"
    ("Maybe", "Nothing") -> "None"
    ("Maybe", "map") -> "maybe_map"
    ("List", "map") -> "list_map"
    ("List", "head") -> "list_head"
    ("List", "tail") -> "list_tail"
    _ -> modName ++ "_" ++ name

constructorToRust :: String -> String
constructorToRust name = case name of
    "True" -> "true"
    "False" -> "false"
    "Nothing" -> "None"
    "Just" -> "Some"
    _ -> name

binopToRust :: String -> BinOp
binopToRust op = case op of
    "+" -> Add
    "-" -> Sub
    "*" -> Mul
    "/" -> Div
    "%" -> Mod
    "==" -> Eq
    "/=" -> Neq
    "<" -> Lt
    ">" -> Gt
    "<=" -> Le
    ">=" -> Ge
    "&&" -> And
    "||" -> Or
    "::" -> Cons
    "++" -> Append
    _ -> Add

patternToRust :: Can.Pattern -> Pattern
patternToRust (A.Located _ pat) = case pat of
    Can.PVar name -> PVar name
    Can.PAnything -> PWild
    Can.PUnit -> PUnit
    Can.PInt i -> PInt i
    Can.PBool b -> PBool b
    Can.PChr c -> PChar c
    Can.PStr s -> PString s
    Can.PTuple a b rest ->
        PTuple (patternToRust a : patternToRust b : map patternToRust rest)
    Can.PList pats -> PTuple (map patternToRust pats)
    Can.PCons a b -> PConstructor "Cons" [patternToRust a, patternToRust b]
    Can.PRecord fields -> PRecord (map (\f -> (f, PWild)) fields)
    Can.PCtor ctor -> PConstructor (Can._p_name ctor) (map (\arg -> patternToRust (Can._pca_pat arg)) (Can._p_args ctor))
    Can.PAlias pat _ -> patternToRust pat

patternToVar :: Can.Pattern -> String
patternToVar pat = case pat of
    Can.PVar name -> name
    Can.PWild -> "_"
    Can.PInt i -> show i
    Can.PFloat f -> show f
    Can.PBool b -> if b then "true" else "false"
    Can.PChr c -> [c]
    Can.PStr s -> s
    Can.PUnit -> "()"
    Can.PConstructor name _ -> name
    Can.PTuple a b rest -> "(" ++ patternToVar a ++ ", " ++ patternToVar b ++ concatMap ((", " ++) . patternToVar) rest ++ ")"
    Can.PRecord fields -> "record"
    Can.PCons a b -> "list"
    _ -> "_"

litToRust :: Literal -> Literal
litToRust = id

binOpToRust :: String -> BinOp
binOpToRust op = case op of
    "+" -> Add
    "-" -> Sub
    "*" -> Mul
    "/" -> Div
    "%" -> Mod
    "==" -> Eq
    "/=" -> Neq
    "<" -> Lt
    ">" -> Gt
    "<=" -> Le
    ">=" -> Ge
    "&&" -> And
    "||" -> Or
    "::" -> Cons
    "++" -> Append
    _ -> Add

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
    RustCase scrut branches ->
        "match " ++ exprToRustString scrut ++ " { " ++ intercalate "; " (map branchToString branches) ++ " }"
    RustRecord fields -> "{ " ++ intercalate ", " (map (\(n, v) -> n ++ " : " ++ exprToRustString v) fields) ++ " }"
    RustAccess rec field -> exprToRustString rec ++ "." ++ field
    RustTuple els -> "(" ++ intercalate ", " (map exprToRustString els) ++ ")"
    RustBinOp op a b -> binOpToString op ++ " " ++ exprToRustString a ++ " " ++ exprToRustString b
    RustNative name -> name
  where
    branchToString (pat, body) = patternToString pat ++ " => " ++ exprToRustString body
    binOpToString op = case op of
        Add -> "+"; Sub -> "-"; Mul -> "*"; Div -> "/"; Mod -> "%"
        Eq -> "=="; Neq -> "!="; Lt -> "<"; Gt -> ">"; Le -> "<="; Ge -> ">="
        And -> "&&"; Or -> "||"
        Cons -> "::"
        Append -> "++"
    intercalate s [] = ""
    intercalate s [x] = x
    intercalate s (x:xs) = x ++ s ++ intercalate s xs