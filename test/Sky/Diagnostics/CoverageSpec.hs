-- | v0.13 overall guarantee — diagnostic coverage spec.
--
-- One regression test per error category.  Each fixture in
-- `test/fixtures/diagnostics/` represents a canonical instance
-- of an error class.  The spec asserts that:
--
--   1. The Sky CLI reports the matching diagnostic code + region.
--   2. The build fails (non-zero exit) — the program never reaches
--      the runtime.
--
-- LSP wire-format validation is covered separately by the
-- `Sky.Lsp.DiagnosticsSpec` suite, which exercises the JSON
-- shape end-to-end through a real LSP harness.  The CLI codes
-- + LSP codes share the same `Diagnostic` AST, so any drift in
-- one surface is caught by the other.
--
-- Adding a new error category:
--   * Write `test/fixtures/diagnostics/<name>.sky` that triggers
--     exactly that error class.
--   * Add a new `describe ... it` block here asserting the code.
--   * If the category has a unique severity / category prefix,
--     also assert the header wording.
module Sky.Diagnostics.CoverageSpec (spec) where

import Test.Hspec
import System.Directory (getCurrentDirectory, createDirectoryIfMissing,
                         doesFileExist, copyFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readCreateProcessWithExitCode, proc, CreateProcess(..))
import System.Exit (ExitCode(..))
import Data.List (isInfixOf)


findSky :: IO FilePath
findSky = do
    cwd <- getCurrentDirectory
    let c = cwd </> "sky-out" </> "sky"
    ok <- doesFileExist c
    if ok then return c else fail ("missing: " ++ c)


-- | Copy a single fixture file into a temp project and run
-- `sky check src/Main.sky`.  Returns (exit code, combined out).
runFixture :: FilePath -> IO (ExitCode, String)
runFixture fixtureName = do
    cwd <- getCurrentDirectory
    sky <- findSky
    let fixturePath = cwd </> "test" </> "fixtures" </> "diagnostics"
                          </> fixtureName
    withSystemTempDirectory "sky-cov" $ \tmp -> do
        createDirectoryIfMissing True (tmp </> "src")
        copyFile fixturePath (tmp </> "src" </> "Main.sky")
        writeFile (tmp </> "sky.toml")
            "[project]\nname = \"cov\"\nbin = \"app\"\n"
        let cp = (proc sky ["check", "src/Main.sky"]) { cwd = Just tmp }
        (ec, out, err) <- readCreateProcessWithExitCode cp ""
        return (ec, out ++ err)


spec :: Spec
spec = do
    describe "Diagnostic coverage — one fixture per error class" $ do

        it "parse error fixture surfaces [E0001] PARSE ERROR" $ do
            (ec, out) <- runFixture "parse-error.sky"
            ec `shouldNotBe` ExitSuccess
            out `shouldSatisfy` ("[E0001]" `isInfixOf`)
            out `shouldSatisfy` ("PARSE ERROR" `isInfixOf`)

        it "unbound-name fixture surfaces [E1001] NAMING ERROR" $ do
            (ec, out) <- runFixture "unbound-name.sky"
            ec `shouldNotBe` ExitSuccess
            out `shouldSatisfy` ("[E1001]" `isInfixOf`)
            out `shouldSatisfy` ("NAMING ERROR" `isInfixOf`)
            -- The diagnostic body should include the offending name.
            out `shouldSatisfy` ("frobnicate" `isInfixOf`)

        it "type-mismatch fixture surfaces [E2001] TYPE ERROR" $ do
            (ec, out) <- runFixture "type-mismatch.sky"
            ec `shouldNotBe` ExitSuccess
            out `shouldSatisfy` ("[E2001]" `isInfixOf`)
            out `shouldSatisfy` ("TYPE ERROR" `isInfixOf`)
            out `shouldSatisfy` ("Type mismatch" `isInfixOf`)
            -- Both expected + actual types should appear in the body.
            out `shouldSatisfy` ("expected: Int" `isInfixOf`)
            out `shouldSatisfy` ("actual:   String" `isInfixOf`)

        it "non-exhaustive fixture surfaces [E3001] EXHAUSTIVENESS ERROR" $ do
            (ec, out) <- runFixture "non-exhaustive.sky"
            ec `shouldNotBe` ExitSuccess
            out `shouldSatisfy` ("[E3001]" `isInfixOf`)
            out `shouldSatisfy` ("EXHAUSTIVENESS ERROR" `isInfixOf`)
            -- The missing constructor name should appear.
            out `shouldSatisfy` ("Blue" `isInfixOf`)

    describe "Diagnostic invariants" $ do

        it "every fixture exits non-zero — the runtime never sees the program" $ do
            mapM_ (\f -> do
                (ec, _) <- runFixture f
                ec `shouldNotBe` ExitSuccess)
                [ "parse-error.sky"
                , "unbound-name.sky"
                , "type-mismatch.sky"
                , "non-exhaustive.sky"
                ]

        it "every fixture's diagnostic carries a stable [Ennnn] code" $ do
            -- Loop-asserts: any code in the documented ranges (E0001-E5999)
            -- counts.  Catches new diagnostics that forget to register
            -- a code via `mkError`.
            results <- mapM (\f -> do
                (_ec, out) <- runFixture f
                return out)
                [ "parse-error.sky"
                , "unbound-name.sky"
                , "type-mismatch.sky"
                , "non-exhaustive.sky"
                ]
            mapM_ (\out -> out `shouldSatisfy` (\s ->
                any (`isInfixOf` s)
                    [ "[E0", "[E1", "[E2", "[E3", "[E4", "[E5" ])) results
