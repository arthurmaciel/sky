module Sky.Generate.Rust.Types where

import qualified Sky.AST.Canonical as Can
import qualified Sky.Type.Type as T
import qualified Data.Map.Strict as Map

data RustType
    = RustPrim PrimType
    | RustVec RustType
    | RustOption RustType
    | RustResult RustType RustType
    | RustFuture RustType
    | RustTuple [RustType]
    | RustRecord [(String, RustType)]
    | RustEnum [(String, Maybe RustType)]
    | RustCustom String
    | RustFunction [RustType] RustType
    | RustOpaque
    deriving (Eq, Show)

data PrimType
    = PInt
    | PFloat
    | PBool
    | PChar
    | PString
    | PUnit
    deriving (Eq, Show)

typeToRust :: T.Type -> RustType
typeToRust t = case t of
    T.TType _ "Int" [] -> RustPrim PInt
    T.TType _ "Float" [] -> RustPrim PFloat
    T.TType _ "Bool" [] -> RustPrim PBool
    T.TType _ "Char" [] -> RustPrim PChar
    T.TType _ "String" [] -> RustPrim PString
    T.TUnit -> RustPrim PUnit
    T.TVar _ -> RustOpaque
    T.TType _ "List" [a] -> RustVec (typeToRust a)
    T.TType _ "Maybe" [a] -> RustOption (typeToRust a)
    T.TType _ "Result" [e, a] -> RustResult (typeToRust e) (typeToRust a)
    T.TType _ "Task" [_, a] -> RustFuture (typeToRust a)
    T.TTuple a b rest -> RustTuple (map typeToRust (a:b:rest))
    T.TRecord fields _ -> RustRecord (map (\(k, T.FieldType _ v) -> (k, typeToRust v)) (Map.toList fields))
    T.TType _ name [] -> RustCustom name
    T.TLambda a b -> RustFunction [typeToRust a] (typeToRust b)
    T.TAlias _ name _ _ -> RustCustom name
    _ -> RustOpaque

rustTypeToString :: RustType -> String
rustTypeToString rt = case rt of
    RustPrim p -> case p of
        PInt -> "i64"
        PFloat -> "f64"
        PBool -> "bool"
        PChar -> "char"
        PString -> "String"
        PUnit -> "()"
    RustVec a -> formatGeneric "Vec" [a]
    RustOption a -> formatGeneric "Option" [a]
    RustResult e a -> formatGeneric "Result" [e, a]
    RustFuture _a -> "impl Future<Output = ()>"
    RustTuple ts -> "(" ++ intercalate ", " (map rustTypeToString ts) ++ ")"
    RustRecord fields -> "{" ++ intercalate ", " (map (\(n, t) -> n ++ ": " ++ rustTypeToString t) fields) ++ "}"
    RustEnum variants -> "enum with " ++ show (length variants) ++ " variants"
    RustCustom name -> name
    RustFunction args ret -> "fn(" ++ intercalate ", " (map rustTypeToString args) ++ ") -> " ++ rustTypeToString ret
    RustOpaque -> "SkyValue"
  where
    formatGeneric name args = name ++ "<" ++ intercalate ", " (map rustTypeToString args) ++ ">"

intercalate :: String -> [String] -> String
intercalate _ [] = ""
intercalate _ [x] = x
intercalate s (x:xs) = x ++ s ++ intercalate s xs