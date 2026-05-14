module Main where

import Sky.AST.Canonical
import Sky.Generate.Rust.Module
import Sky.Generate.Rust.Builder
import Sky.Generate.Rust.Types
import Sky.Generate.Rust.Expr
import Sky.Generate.Rust.Decl

main :: IO ()
main = putStrLn "Rust codegen module loaded successfully"

testModule :: RustModule
testModule = RustModule
    { modName = "Test"
    , modImports = []
    , modDecls = testDecls
    , modExports = ["add", "factorial"]
    }

testDecls :: [RustDecl]
testDecls =
    [ DFunction "add" ["a", "b"] (RustBinOp Add (RustVar "a") (RustVar "b")) (Just (RustPrim PInt))
    , DFunction "factorial" ["n"] body Nothing
    ]
  where
    body = RustCase (RustVar "n")
        [ (PInt 0, RustLit (LInt 1))
        , (PVar "_", RustApp (RustVar "mul")
            [ RustVar "n"
            , RustApp (RustVar "factorial") [RustBinOp Sub (RustVar "n") (RustLit (LInt 1)]]
            )
        ]

testGenerate :: IO ()
testGenerate = do
    let rust = moduleToRustString testModule
    putStrLn "Generated Rust code:"
    putStrLn rust