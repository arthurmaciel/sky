module Sky.Generate.Rust.Builder.Naming
  ( toCamelCase
  , toSnakeCase
  , anonStructName
  , moduleNameToRust
  , rustSafeIdent
  , kernelCtorToRust
  ) where

import Data.Char (toLower, toUpper, isUpper)
import qualified Sky.Sky.ModuleName as ModuleName

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

-- | Anonymous record struct name prefix
anonStructName :: String -> String
anonStructName key = toCamelCase ("Anon_" ++ map (\c -> if c == ',' then '_' else c) key)

moduleNameToRust :: ModuleName.Canonical -> String
moduleNameToRust mod =
    map (\c -> if c == '.' then '_' else c) (ModuleName._name mod)

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
