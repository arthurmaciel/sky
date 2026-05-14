module Sky.Generate.Rust.Types where

import Sky.AST.Canonical (CanonicalType, Type(..))
import Sky.AST.Source (SourceType)

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

typeToRust :: CanonicalType -> RustType
typeToRust t = case t of
    TInt -> RustPrim PInt
    TFloat -> RustPrim PFloat
    TBool -> RustPrim PBool
    TChar -> RustPrim PChar
    TString -> RustPrim PString
    TUnit -> RustPrim PUnit
    TVar _ -> RustOpaque
    TCon "List" [a] -> RustVec (typeToRust a)
    TCon "Maybe" [a] -> RustOption (typeToRust a)
    TCon "Result" [e, a] -> RustResult (typeToRust e) (typeToRust a)
    TCon "Task" [e, a] -> RustFuture (typeToRust a)
    TTuple ts -> RustTuple (map typeToRust ts)
    TRecord fields -> RustRecord (map (\(k, v) -> (k, typeToRust v)) fields)
    TApp (TCon name _) [] -> RustCustom name
    TLambda a b -> RustFunction [typeToRust a] (typeToRust b)
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
    RustResult e a -> formatGeneric "Result" [a, e]
    RustFuture a -> formatGeneric "impl Future" [formatGeneric "Output" [a]]
    RustTuple ts -> "(" ++ intercalate ", " (map rustTypeToString ts) ++ ")"
    RustRecord fields -> "{" ++ intercalate ", " (map (\(n, t) -> n ++ " : " ++ rustTypeToString t) fields) ++ "}"
    RustEnum variants -> "enum with variants: " ++ show (length variants)
    RustCustom name -> name
    RustFunction args ret -> formatGeneric "fn" [intercalate " -> " (map rustTypeToString args ++ [rustTypeToString ret])]
    RustOpaque -> "SkyValue"
  where
    formatGeneric name args = name ++ "<" ++ intercalate ", " (map rustTypeToString args) ++ ">"

intercalate :: String -> [String] -> String
intercalate _ [] = ""
intercalate _ [x] = x
intercalate s (x:xs) = x ++ s ++ intercalate s xs