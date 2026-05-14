module Sky.Generate.Rust.Module where

import Sky.AST.Canonical (CanonicalModule(..))
import Sky.Generate.Rust.Decl
import Sky.Generate.Rust.Expr

data RustModule = RustModule
    { modName :: String
    , modImports :: [String]
    , modDecls :: [RustDecl]
    , modExports :: [String]
    } deriving (Eq, Show)

moduleToRust :: CanonicalModule -> RustModule
moduleToRust mod = RustModule
    { modName = moduleName mod
    , modImports = map (\(n, _) -> n) (moduleImports mod)
    , modDecls = concatMap declToRust (moduleDecls mod)
    , modExports = moduleExports mod
    }

moduleToRustString :: RustModule -> String
moduleToRustString m = unlines
    [ "//! Rust code generated from Sky module: " ++ modName m
    , ""
    , "use sky_runtime::*;"
    , ""
    , "// Module: " ++ modName m
    , ""
    , "pub mod " ++ rustModuleName (modName m) ++ " {"
    , "    use super::*;"
    , ""
    , intercalate "\n\n" (map declToString (modDecls m))
    , ""
    , "}"
    ]
  where
    rustModuleName name = case last (splitOn '.' name) of
        n -> toSnakeCase n

    toSnakeCase [] = ""
    toSnakeCase (c:cs)
        | isUpper c = if null cs then [toLower c] else toLower c : toSnakeCase cs
        | c == '_' = toSnakeCase cs
        | otherwise = c : toSnakeCase cs

    isUpper c = c >= 'A' && c <= 'Z'
    toLower c = if isUpper c then toEnum (fromEnum c - fromEnum 'A' + fromEnum 'a') else c

moduleToFile :: RustModule -> (String, String)
moduleToFile m = (filePath, content)
  where
    filePath = rustModuleName (modName m) ++ ".rs"
    content = moduleToRustString m

splitOn :: Char -> String -> [String]
splitOn _ "" = [""]
splitOn c (x:xs)
    | x == c = "" : splitOn c xs
    | otherwise = case splitOn c xs of
        (y:ys) -> (x:y) : ys
        [] -> [x : ""]

intercalate :: String -> [String] -> String
intercalate _ [] = ""
intercalate _ [x] = x
intercalate s (x:xs) = x ++ s ++ intercalate s xs

moduleToCrate :: [RustModule] -> String
moduleToCrate mods = unlines
    [ "[package]"
    , "name = \"sky_generated\""
    , "version = \"0.1.0\""
    , "edition = \"2021\""
    , ""
    , "[dependencies]"
    , "sky-runtime = { path = \"../sky-runtime-rust\" }"
    , "tokio = { version = \"1\", features = [\"full\"] }"
    , "serde = { version = \"1\", features = [\"derive\"] }"
    , "serde_json = \"1\""
    , ""
    , "[lib]"
    , "path = \"lib.rs\""
    , ""
    , "pub mod runtime {"
    , "    pub use sky_runtime::*;"
    , "}"
    , ""
    , intercalate "\n" (map moduleToRustString mods)
    ]

generateCrateFiles :: [RustModule] -> [(String, String)]
generateCrateFiles mods = ("Cargo.toml", crateToml) : map moduleToFile mods
  where
    crateToml = unlines
        [ "[package]"
        , "name = \"sky_generated\""
        , "version = \"0.1.0\""
        , "edition = \"2021\""
        , ""
        , "[dependencies]"
        , "sky-runtime = { path = \"../sky-runtime-rust\" }"
        , "tokio = { version = \"1\", features = [\"full\"] }"
        , "serde = { version = \"1\", features = [\"derive\"] }"
        , "serde_json = \"1\""
        , ""
        , "[[bin]]"
        , "name = \"app\""
        , "path = \"main.rs\""
        ]

mainModule :: RustModule -> String
mainModule m = unlines
    [ "use sky_runtime::*;"
    , "use " ++ rustModuleName (modName m) ++ "::*;"
    , ""
    , "#[tokio::main]"
    , "async fn main() {"
    , "    println!(\"Sky module: " ++ modName m ++ "\");"
    , "}"
    ]
  where
    rustModuleName name = case last (splitOn '.' name) of
        n -> toSnakeCase n

    toSnakeCase [] = ""
    toSnakeCase (c:cs)
        | isUpper c = if null cs then [toLower c] else toLower c : toSnakeCase cs
        | c == '_' = toSnakeCase cs
        | otherwise = c : toSnakeCase cs

    isUpper c = c >= 'A' && c <= 'Z'
    toLower c = if isUpper c then toEnum (fromEnum c - fromEnum 'A' + fromEnum 'a') else c