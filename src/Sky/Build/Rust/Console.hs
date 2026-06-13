{-# LANGUAGE ScopedTypeVariables #-}

-- | Epic A1 — build the bundled Sky Console as a standalone Rust binary at the
-- user's `sky build --target rust` time, cached once per sky version, so the
-- Live runtime's reverse-proxy (`live/console_proxy.rs`) can spawn it. NEVER a
-- runtime build — the only reason the Go backend dropped its subprocess console
-- (see `runtime-rust/README.md` §"divergent strategies").
--
-- Flow: materialise the TH-embedded console source (`Sky.Build.EmbeddedConsole`)
-- into a version-keyed cache build dir, recursively invoke THIS sky binary
-- (`getExecutablePath`) with `build --target rust`, and copy the resulting
-- binary to `~/.cache/sky/rust-console/<version>/sky-console` (the exact path
-- `console_bin_path()` resolves at runtime). Cache hit → no-op.
--
-- The whole thing is best-effort: any failure (no cargo, build error, no HOME)
-- logs a warning and returns — the runtime proxy then falls back to the
-- in-process console. A failed pre-build must never fail the user's own build.
module Sky.Build.Rust.Console
    ( ensureConsoleBinary
    ) where

import Control.Exception (SomeException, try)
import Control.Monad (forM_, when)
import qualified Data.ByteString as BS
import Data.Char (toLower)
import System.Directory
    ( createDirectoryIfMissing, doesFileExist, getHomeDirectory
    , removePathForcibly, renameFile, copyFile )
import System.Environment (getEnvironment, getExecutablePath, lookupEnv)
import System.Exit (ExitCode(..))
import System.FilePath (takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)
import System.Process
    ( CreateProcess(..), proc, readCreateProcessWithExitCode )

import Sky.Build.EmbeddedConsole (embeddedConsoleApp)

-- | Env var set on the recursive console build so its own post-build hook does
-- NOT try to build the console again (infinite recursion). Mirrors the Go
-- backend's `SKY_BUILD_IS_INLINE_CONSOLE` guard.
recursionGuardEnv :: String
recursionGuardEnv = "SKY_BUILD_IS_CONSOLE"

-- | Opt-out: `SKY_CONSOLE_PREBUILD=off|0|false` skips the pre-build entirely
-- (the in-process console still serves).
prebuildOptOutEnv :: String
prebuildOptOutEnv = "SKY_CONSOLE_PREBUILD"

-- | Cache layout under the user's home (must match `console_bin_path()` in
-- `live/console_proxy.rs`, which resolves `$HOME/.cache/sky/rust-console/<ver>/sky-console`).
consoleCacheDir :: String -> IO FilePath
consoleCacheDir ver = do
    home <- getHomeDirectory
    return (home </> ".cache" </> "sky" </> "rust-console" </> ver)

-- | Ensure the pre-built console binary exists in the version-keyed cache.
-- Non-fatal end to end: never throws, never fails the caller's build.
ensureConsoleBinary :: String -> IO ()
ensureConsoleBinary ver = do
    guard   <- lookupEnv recursionGuardEnv
    optOut  <- lookupEnv prebuildOptOutEnv
    let isOff v = map toLower v `elem` ["off", "0", "false", "no"]
    case () of
        _ | maybe False (not . null) guard -> return ()          -- building the console itself
          | maybe False isOff optOut       -> return ()          -- user opted out
          | otherwise -> do
                r <- try (buildIfMissing ver)
                case r of
                    Right () -> return ()
                    Left (e :: SomeException) ->
                        hPutStrLn stderr $
                            "[sky.console] pre-build skipped (" ++ show e
                            ++ "); the in-process console will serve instead"

buildIfMissing :: String -> IO ()
buildIfMissing ver = do
    cacheDir <- consoleCacheDir ver
    let cacheBin = cacheDir </> "sky-console"
    hit <- doesFileExist cacheBin
    if hit
        then return ()
        else buildConsole ver cacheDir cacheBin

buildConsole :: String -> FilePath -> FilePath -> IO ()
buildConsole ver cacheDir cacheBin = do
    skyBin <- getExecutablePath
    let buildDir = cacheDir </> "build"
    -- Fresh build dir (a previous partial build may have left a stale tree).
    removePathForcibly buildDir
    createDirectoryIfMissing True buildDir
    forM_ embeddedConsoleApp $ \(rel, bytes) -> do
        let dst = buildDir </> rel
        createDirectoryIfMissing True (takeDirectory dst)
        BS.writeFile dst bytes

    hPutStrLn stderr $
        "[sky] pre-building the bundled console for sky " ++ ver
        ++ " (one-time per version; set " ++ prebuildOptOutEnv ++ "=off to skip)..."

    -- Isolated env: drop CARGO_TARGET_DIR so the console builds into its own
    -- buildDir/sky-out/Rust/target (every generated crate is "sky-app" — sharing
    -- the user's target dir would clobber their binary). Keep RUSTC_WRAPPER so
    -- sccache still de-dupes the shared deps (axum/tokio/sqlx) at the rustc
    -- level. Set the recursion guard so the child build skips THIS hook.
    baseEnv <- getEnvironment
    let childEnv =
            (recursionGuardEnv, "1")
            : filter ((/= "CARGO_TARGET_DIR") . fst) baseEnv
        cp = (proc skyBin ["build", "src/Main.sky", "--target", "rust"])
                 { cwd = Just buildDir, env = Just childEnv }
    (ec, _out, errOut) <- readCreateProcessWithExitCode cp ""
    case ec of
        ExitFailure _ ->
            hPutStrLn stderr $
                "[sky.console] console pre-build failed; the in-process console will serve.\n"
                ++ unlines (lastN 8 (lines errOut))
        ExitSuccess -> do
            let built = buildDir </> "sky-out" </> "Rust" </> "target" </> "debug" </> "sky-app"
            builtExists <- doesFileExist built
            if not builtExists
                then hPutStrLn stderr
                        "[sky.console] console pre-build produced no binary; the in-process console will serve."
                else do
                    createDirectoryIfMissing True (takeDirectory cacheBin)
                    -- Atomic publish: copy to a sibling temp then rename into place
                    -- (rename is atomic on the same filesystem), so a concurrent
                    -- build can never observe a half-copied binary.
                    let tmpBin = cacheBin ++ ".tmp"
                    copyFile built tmpBin
                    renameFile tmpBin cacheBin
                    -- Reclaim the (large) build tree; the cached binary is all we keep.
                    removePathForcibly buildDir
                    hPutStrLn stderr $ "[sky.console] cached → " ++ cacheBin

lastN :: Int -> [a] -> [a]
lastN n xs = drop (length xs - n) xs
