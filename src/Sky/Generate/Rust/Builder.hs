module Sky.Generate.Rust.Builder where

import Sky.AST.Canonical
import Sky.AST.Source
import Sky.Generate.Rust.Module
import Sky.Generate.Rust.Decl
import Sky.Generate.Rust.Expr
import Sky.Generate.Rust.Types
import Sky.Generate.Rust.Kernel

data RustBuilder = RustBuilder
    { builderModules :: [RustModule]
    , builderErrors :: [String]
    , builderWarnings :: [String]
    } deriving (Show)

emptyBuilder :: RustBuilder
emptyBuilder = RustBuilder
    { builderModules = []
    , builderErrors = []
    , builderWarnings = []
    }

buildModule :: CanonicalModule -> RustModule
buildModule mod = moduleToRust mod

buildProgram :: [CanonicalModule] -> RustBuilder
buildProgram mods = emptyBuilder
    { builderModules = map buildModule mods
    }

emitRust :: RustBuilder -> String
emitRust b = intercalate "\n\n" (map moduleToRustString (builderModules b))

emitCrate :: RustBuilder -> String
emitCrate b = moduleToCrate (builderModules b)

emitFiles :: RustBuilder -> [(String, String)]
emitFiles b = generateCrateFiles (builderModules b)

addError :: String -> RustBuilder -> RustBuilder
addError err b = b { builderErrors = builderErrors b ++ [err] }

addWarning :: String -> RustBuilder -> RustBuilder
addWarning warn b = b { builderWarnings = builderWarnings b ++ [warn] }

hasErrors :: RustBuilder -> Bool
hasErrors b = not (null (builderErrors b))

validateModule :: CanonicalModule -> RustBuilder -> RustBuilder
validateModule mod b = b'
  where
    b' = foldl checkDecl b (moduleDecls mod)
    checkDecl b'' decl = case decl of
        DAnnot name params body (Just typ) ->
            let inferred = inferExprType body
            in if not (typesCompatible (typeToRust typ) inferred)
                then addError ("Type mismatch in " ++ name ++ ": inferred " ++ show inferred ++ " vs declared " ++ show (typeToRust typ)) b''
                else b''
        _ -> b''

inferExprType :: CanonicalExpr -> RustType
inferExprType expr = case expr of
    EVar _ -> RustOpaque
    ELit lit -> case lit of
        LInt _ -> RustPrim PInt
        LFloat _ -> RustPrim PFloat
        LBool _ -> RustPrim PBool
        LChar _ -> RustPrim PChar
        LString _ -> RustPrim PString
        LUnit _ -> RustPrim PUnit
    EApp f args ->
        let
            funcType = inferExprType f
            argTypes = map inferExprType args
        in case funcType of
            RustFunction _ ret -> ret
            _ -> RustOpaque
    ELam _ body -> RustFunction [] (inferExprType body)
    ELet _ body -> inferExprType body
    EIf _ thenE _ -> inferExprType thenE
    ECase _ branches -> case branches of
        (_, expr):_ -> inferExprType expr
        [] -> RustOpaque
    ERecord fields -> RustRecord (map (\(n, e) -> (n, inferExprType e)) fields)
    EAccess _ _ -> RustOpaque
    ETuple els -> RustTuple (map inferExprType els)
    EBinOp _ _ _ -> RustOpaque
    _ -> RustOpaque

typesCompatible :: RustType -> RustType -> Bool
typesCompatible a b = case (a, b) of
    (RustPrim p1, RustPrim p2) -> p1 == p2
    (RustVec a1, RustVec a2) -> typesCompatible a1 a2
    (RustOption a1, RustOption a2) -> typesCompatible a1 a2
    (RustResult e1 a1, RustResult e2 a2) -> typesCompatible e1 e2 && typesCompatible a1 a2
    (RustTuple ts1, RustTuple ts2) -> length ts1 == length ts2 && all (uncurry typesCompatible) (zip ts1 ts2)
    (RustRecord fs1, RustRecord fs2) -> all (\(k, t) -> lookup k fs2 == Just t) fs1
    (RustOpaque, _) -> True
    (_, RustOpaque) -> True
    _ -> False

intercalate :: String -> [String] -> String
intercalate _ [] = ""
intercalate _ [x] = x
intercalate s (x:xs) = x ++ s ++ intercalate s xs

runRustCodegen :: [CanonicalModule] -> Either [String] RustBuilder
runRustCodegen mods = case errors of
    [] -> Right (buildProgram mods)
    _ -> Left errors
  where
    builder = buildProgram mods
    errors = builderErrors (foldl validateModule builder mods)