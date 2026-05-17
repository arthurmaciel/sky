module Sky.Type.UfCycleGuardSpec (spec) where

-- Regression fence for the v0.13.0 dep-fixpoint OOM fix: a missed
-- occurs check in `Sky.Type.Unify.actuallyUnify`'s FlexVar↔Structure
-- merge could splice a self-referential cycle into the union-find
-- graph. The downstream `Sky.Type.Solve.variableToType` walk then
-- recursed forever through the cyclic `App1` args, allocating GB
-- of heap before mem-guard / RTS killed the host.
--
-- Symptom triggered by importing `Std.Ui.Events` (or any sky-source
-- stdlib module that re-exports a polymorphic helper across the
-- recursive `Element msg` / `Attribute msg` ADT). Under +RTS -M256M
-- the pre-fix compiler dies with "Heap exhausted". Post-fix it
-- finishes in a few hundred MB with the legitimate type error
-- (or success when the source is well-typed).
--
-- Fix landed in two layers:
--   1. `Unify.actuallyUnify` now occurs-checks every FlexVar
--      ↔ Structure / FlexVar ↔ Alias merge — prevents new cycles
--      from being introduced.
--   2. `Solve.variableToType` carries a path-tracking `seen` set
--      so any pre-existing cycle reads back as a `TVar "_cycle"`
--      sentinel instead of looping forever.

import Test.Hspec
import qualified System.Exit as Exit
import System.Directory (getCurrentDirectory, doesFileExist, createDirectoryIfMissing)
import System.FilePath ((</>))
import System.Process (readCreateProcessWithExitCode, shell)
import System.IO.Temp (withSystemTempDirectory)
import Data.List (isInfixOf)


findSky :: IO FilePath
findSky = do
    cwd <- getCurrentDirectory
    let c = cwd </> "sky-out" </> "sky"
    ok <- doesFileExist c
    if ok then return c else fail ("missing: " ++ c)


buildHeapBounded :: String -> Int -> IO (Int, String, String)
buildHeapBounded src heapMb =
    withSystemTempDirectory "sky-uf-cycle" $ \tmp -> do
        sky <- findSky
        createDirectoryIfMissing True (tmp </> "src")
        writeFile (tmp </> "src" </> "Main.sky") src
        writeFile (tmp </> "sky.toml") "name = \"tmp\"\nversion = \"0.0.0\"\n"
        let cmd = sky ++ " build " ++ tmp ++ "/src/Main.sky +RTS -M"
                ++ show heapMb ++ "M -RTS"
        (ec, out, err) <- readCreateProcessWithExitCode (shell cmd) ""
        let code = case ec of
                Exit.ExitSuccess   -> 0
                Exit.ExitFailure n -> n
        return (code, out, err)


spec :: Spec
spec = describe "UF cycle guard" $ do

    it "trivial Std.Ui.Events importer does not OOM at 256 MB heap" $ do
        -- Minimal reproducer extracted from mini-notion. Pre-fix
        -- this allocates >3 GB during the dep-fixpoint round-1
        -- solve of Std.Ui.Events; +RTS -M256M dies with "Heap
        -- exhausted". Post-fix it completes in <50 MB residency.
        let src = unlines
                [ "module Main exposing (main)"
                , ""
                , "import Std.Ui as Ui"
                , "import Std.Ui exposing (Element)"
                , "import Std.Ui.Events as Events"
                , "import Std.Log exposing (println)"
                , ""
                , ""
                , "type Msg = Click"
                , ""
                , "view : Element Msg"
                , "view = Ui.el [ Events.onClick Click ] (Ui.text \"hi\")"
                , ""
                , "main = println \"compiled\""
                ]
        -- ec may be 0 (success) or 1 (legit type error elsewhere),
        -- but MUST NOT be 251 (RTS heap-exhausted exit) or any
        -- signal-killed code. The point of the test is "compiler
        -- terminates under bounded heap", not "source is correct".
        (ec, _, err) <- buildHeapBounded src 256
        ec `shouldSatisfy` (\c -> c == 0 || c == 1)
        err `shouldNotSatisfy` (\e ->
            "Heap exhausted" `isInfixOf` e
            || "stack overflow" `isInfixOf` e)
