{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Bundle the `sky-ffi-inspect-rs` Rust helper into the sky binary so
-- releases ship a single executable rather than a pair.  On first use,
-- `ensureInspectorRust` materialises the binary into
-- `$XDG_CACHE_HOME/sky/tools/sky-ffi-inspect-rs/` and returns its path.
--
-- Embedding strategy (checked at compile time, in order):
--   1. Pre-built release binary at `tools/sky-ffi-inspect-rs/target/release/sky-ffi-inspect-rs`
--      → embed via `embedFile` (fast, zero cargo runtime).
--   2. Source tree at `tools/sky-ffi-inspect-rs/` (excluding target/)
--      → embed via `embedDirFiltered`; first-use does a cargo build.
--
-- Strategy 2 is the development fallback — it matches what the Go
-- inspector does (EmbeddedInspector.hs).  Strategy 1 is the preferred
-- path for releases: run `cargo build --release` in
-- `tools/sky-ffi-inspect-rs/` before `cabal build` so TH picks up the
-- binary.
module Sky.Build.EmbeddedInspectorRust
    ( ensureInspectorRust
    , embeddedInspectorRustBytes
    ) where

import Control.Monad (unless, forM_, when)
import qualified Crypto.Hash.SHA256 as SHA256
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.List (sortOn, isPrefixOf)
import Language.Haskell.TH
import Language.Haskell.TH.Syntax (qAddDependentFile, runIO)
import qualified Data.FileEmbed as FE
import Numeric (showHex)
import System.Directory (copyFile, createDirectoryIfMissing, doesDirectoryExist, doesFileExist,
                         getPermissions, setPermissions, setOwnerExecutable,
                         getModificationTime,
                         getXdgDirectory, XdgDirectory(..), listDirectory,
                         removeDirectoryRecursive)
import System.FilePath ((</>), takeDirectory)
import System.Exit (ExitCode(..))
import System.IO (readFile')
import System.Process (readCreateProcessWithExitCode, proc, CreateProcess(..))
import qualified Sky.Build.EmbedDirTH as EmbedDir


-- | Try to embed the pre-built release binary; fall back to source tree.
-- The TH splice runs at compile time.
embeddedInspectorRustBytes :: [(FilePath, ByteString)]
embeddedInspectorRustBytes = $(do
    let binaryPath = "tools/sky-ffi-inspect-rs/target/release/sky-ffi-inspect-rs"
    binExists <- runIO $ doesFileExist binaryPath
    -- Check freshness: if any src/*.rs is newer than the pre-built binary,
    -- fall through to source-tree embed so qAddDependentFile registers the
    -- .rs files as TH dependencies and source edits trigger recompilation.
    binFresh <- runIO $ do
        srcExists <- doesFileExist "tools/sky-ffi-inspect-rs/src/main.rs"
        if binExists && srcExists
            then do
                binMtime <- getModificationTime binaryPath
                srcMtime <- getModificationTime "tools/sky-ffi-inspect-rs/src/main.rs"
                return (srcMtime <= binMtime)
            else return False
    if binFresh
        then do
            -- Strategy 1: embed the pre-built binary (fresh).
            -- Also register source files as TH deps so future edits
            -- trigger recompilation, even with a fresh binary. When
            -- recompilation does happen, the freshness check above
            -- detects the newer source and falls through to Strategy 2.
            qAddDependentFile binaryPath
            let srcPath = "tools/sky-ffi-inspect-rs/src/main.rs"
            srcExists <- runIO $ doesFileExist srcPath
            when srcExists $ qAddDependentFile srcPath
            bs <- runIO $ BS.readFile binaryPath
            bsExp <- FE.bsToExp bs
            [| [("sky-ffi-inspect-rs", $(return bsExp))] |]
        else do
            -- Strategy 2: fall back to source tree embed (either no binary
            -- or source files are newer)
            let warn = if binExists
                    then "EmbeddedInspectorRust: pre-built binary at " ++ binaryPath
                         ++ " is stale (source files are newer); falling back to "
                         ++ "source-tree embed for correct TH dependency tracking."
                    else "EmbeddedInspectorRust: no pre-built binary at " ++ binaryPath
                         ++ "; falling back to source-tree embed (first 'sky add' "
                         ++ "will do a slow cargo build).  Run 'cargo build --release' "
                         ++ "in tools/sky-ffi-inspect-rs/ before cabal build to avoid this."
            reportWarning warn
            EmbedDir.embedDirFiltered "tools/sky-ffi-inspect-rs" ["target"]
    )


-- | Content hash of the embedded data.  For the binary path this is the
-- SHA-256 of the binary itself (stable for identical builds).  For the
-- source-tree fallback it's the hash of all source bytes (sorted by path).
inspectorRustHash :: String
inspectorRustHash =
    let sorted = sortOn fst embeddedInspectorRustBytes
        combined = BS.concat [BS.concat [BS.pack (map (fromIntegral . fromEnum) p), b]
                              | (p, b) <- sorted]
        digest = SHA256.hash combined
    in take 12 (concatMap (pad2 . (`showHex` "")) (BS.unpack digest))
  where
    pad2 [c] = ['0', c]
    pad2 s   = s


-- | Return the path to a ready-to-run `sky-ffi-inspect-rs`.
-- Materialises the embedded binary/source to a stable cache path
-- (`$XDG_CACHE_HOME/sky/tools/sky-ffi-inspect-rs/`).  For the source-tree
-- fallback, runs `cargo build` on first materialisation.
ensureInspectorRust :: IO (Either String FilePath)
ensureInspectorRust = do
    cache <- getXdgDirectory XdgCache "sky"
    let root = cache </> "tools" </> "sky-ffi-inspect-rs"
        bin  = root </> "sky-ffi-inspect-rs"
        hashFile = root </> ".hash"
    -- Check if a cached binary exists with matching hash
    binReady <- doesFileExist bin
    hashMatch <- if binReady then do
        hashOk <- doesFileExist hashFile
        if hashOk then do
            oldHash <- readFile' hashFile
            return (oldHash == inspectorRustHash)
        else return False
    else return False
    if hashMatch
        then return (Right bin)
        else materialiseInspector root bin hashFile cache


-- | Materialise the embedded data and make the binary executable.
-- For the source-tree path, also runs `cargo build`.
materialiseInspector :: FilePath -> FilePath -> FilePath -> FilePath -> IO (Either String FilePath)
materialiseInspector root bin hashFile cache = do
    createDirectoryIfMissing True root
    let entries = embeddedInspectorRustBytes
        isBinary = length entries == 1 && fst (head entries) == "sky-ffi-inspect-rs"
    if isBinary
        then do
            -- Strategy 1: just write the binary and make it executable
            let (_rel, bytes) = head entries
            BS.writeFile bin bytes
            perms <- getPermissions bin
            setPermissions bin (setOwnerExecutable True perms)
            writeFile hashFile inspectorRustHash
            -- Remove old source-tree caches (target/ subdirs from prior builds)
            cleanupOldCaches cache
            return (Right bin)
        else do
            -- Strategy 2: write source tree, then cargo build
            forM_ entries $ \(rel, bytes) -> do
                let dst = root </> rel
                createDirectoryIfMissing True (takeDirectory dst)
                BS.writeFile dst bytes
            let cargoBuild = (proc "cargo" ["build", "--manifest-path", root </> "Cargo.toml"])
                              { cwd = Just root }
            (ec, _out, err) <- readCreateProcessWithExitCode cargoBuild ""
            case ec of
                ExitSuccess -> do
                    let bin' = root </> "target" </> "debug" </> "sky-ffi-inspect-rs"
                    perms <- getPermissions bin'
                    setPermissions bin' (setOwnerExecutable True perms)
                    -- Also copy to the canonical bin path so subsequent
                    -- ensureInspectorRust calls (which check doesFileExist bin)
                    -- find the freshly compiled binary, not a stale one.
                    copyFile bin' bin
                    writeFile hashFile inspectorRustHash
                    return (Right bin')
                _ ->
                    return (Left $ "sky-ffi-inspect-rs: cargo build failed:\n" ++ err)


-- | Remove old source-tree cache directories that still have `target/`
-- subdirectories (accumulated from prior embed-source builds).
cleanupOldCaches :: FilePath -> IO ()
cleanupOldCaches root = do
    -- root = ~/.cache/sky; hash-suffixed dirs live in ~/.cache/sky/tools/
    let toolsDir = root </> "tools"
    hasTools <- doesDirectoryExist toolsDir
    when hasTools $ do
        entries <- listDirectory toolsDir
        mapM_ (\entry -> do
            let full = toolsDir </> entry
            if "sky-ffi-inspect-rs-" `isPrefixOf` entry then do
                hasTarget <- doesDirectoryExist (full </> "target")
                when hasTarget $
                    removeDirectoryRecursive full
            else return ()
            ) entries
