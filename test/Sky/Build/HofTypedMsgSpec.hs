module Sky.Build.HofTypedMsgSpec (spec) where

import Test.Hspec
import System.Directory (getCurrentDirectory, createDirectoryIfMissing,
                         copyFile, doesFileExist, listDirectory, doesDirectoryExist)
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


copyTree :: FilePath -> FilePath -> IO ()
copyTree src dst = do
    createDirectoryIfMissing True dst
    entries <- listDirectory src
    mapM_ (\e -> do
        let s = src </> e
            d = dst </> e
        isF <- doesFileExist s
        if isF
            then copyFile s d
            else do
                isD <- doesDirectoryExist s
                if isD then copyTree s d else return ()) entries


spec :: Spec
spec = do
    describe "Helper with (String -> Msg) typed callback (Limitation #18)" $ do
        it "compiles a helper that takes a (String -> Msg) callback" $ do
            -- Reproducer: `field : String -> (String -> Msg) -> Msg`
            -- with `field "alice" UserChanged` at the call site. Pre-fix
            -- the helper sig emitted `cb func(string) any` and `go build`
            -- rejected the `Msg_UserChanged : func(string) Msg` arg.
            sky <- findSky
            cwd <- getCurrentDirectory
            let fixtureRoot = cwd </> "test" </> "fixtures" </> "hof-typed-msg"
            withSystemTempDirectory "sky-htm" $ \tmp -> do
                copyTree fixtureRoot tmp
                let cp = (proc sky ["build", "src/Main.sky"]) { cwd = Just tmp }
                (ec, out, err) <- readCreateProcessWithExitCode cp ""
                let combined = out ++ err
                ec `shouldBe` ExitSuccess
                ("Build complete" `isInfixOf` combined) `shouldBe` True

        it "coerces the typed Msg ctor at the call site via rt.Coerce" $ do
            -- v0.13 D1 update: helper sig emits the typed return
            -- (`cb func(string) Msg`) — D-Lambda-Lowerer routes
            -- literal `\x -> ...` lambdas at typed-func slots through
            -- `curryLambdaPatTyped` so the lowered shape matches the
            -- sig. Typed ctor args like
            -- `Msg_UserChanged : func(string) Msg` still pass through
            -- `rt.Coerce` — but now `rt.Coerce[func(string) Msg]`
            -- (typed) rather than `rt.Coerce[func(string) any]`
            -- (pre-D1 widened). The reflect adapter handles both;
            -- the typed shape unblocks Go's call-site inference at
            -- user-defined HOF slots.
            sky <- findSky
            cwd <- getCurrentDirectory
            let fixtureRoot = cwd </> "test" </> "fixtures" </> "hof-typed-msg"
            withSystemTempDirectory "sky-htm-emit" $ \tmp -> do
                copyTree fixtureRoot tmp
                let cp = (proc sky ["build", "src/Main.sky"]) { cwd = Just tmp }
                (_, _, _) <- readCreateProcessWithExitCode cp ""
                body <- readFile (tmp </> "sky-out" </> "main.go")
                -- Helper sig emits the typed return shape (D1).
                ("cb func(string) Msg" `isInfixOf` body) `shouldBe` True
                -- Call site routes the typed Msg ctor through
                -- `rt.Coerce[func(string) Msg]` (typed coerce).
                ("rt.Coerce[func(string) Msg](Msg_UserChanged)"
                    `isInfixOf` body) `shouldBe` True
                -- Bare-pass form (pre-fix shape) must be GONE.
                ("field(\"alice\", Msg_UserChanged)" `isInfixOf` body)
                    `shouldBe` False
