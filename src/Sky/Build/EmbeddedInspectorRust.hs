{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Bundle the `sky-ffi-inspect-rs` Rust helper into the sky binary so
-- releases ship a single executable rather than a pair. The source
-- tree (`tools/sky-ffi-inspect-rs/`) is embedded via Template Haskell
-- at build time. On first use, `ensureInspectorRust` materialises the
-- tree into a content-hashed cache dir under `$XDG_CACHE_HOME/sky/tools/`,
-- runs `cargo build`, and returns the path to the compiled binary.
-- Subsequent calls are O(stat) — the hash changes only when sky is
-- rebuilt with new inspector source, so `sky upgrade` auto-invalidates
-- without manual cleanup.
--
-- Trust model: Rust (cargo) is already a hard requirement of `sky build
-- --target rust`, so building a small helper on first `sky add` is a
-- no-new-dependency cost. The embedded Cargo.lock + vendored-ish deps
-- (via cargo metadata resolution) keep builds reproducible.
module Sky.Build.EmbeddedInspectorRust
    ( ensureInspectorRust
    , embeddedInspectorRustBytes
    ) where

import Control.Monad (unless, forM_)
import qualified Crypto.Hash.SHA256 as SHA256
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.List (sortOn)
import qualified Sky.Build.EmbedDirTH as EmbedDir
import Numeric (showHex)
import System.Directory (createDirectoryIfMissing, doesFileExist,
                         getPermissions, setPermissions, setOwnerExecutable,
                         getXdgDirectory, XdgDirectory(..))
import System.FilePath ((</>), takeDirectory)
import System.Process (readCreateProcessWithExitCode, proc, CreateProcess(..))
import System.Exit (ExitCode(..))


-- | The `tools/sky-ffi-inspect-rs/` source tree, keyed by relative
-- path. Re-embedded whenever any file changes (file-embed registers
-- each file via qAddDependentFile).
embeddedInspectorRustBytes :: [(FilePath, ByteString)]
embeddedInspectorRustBytes = $(EmbedDir.embedDirFiltered "tools/sky-ffi-inspect-rs" ["target"])


-- | Content hash of the embedded tree. Entries are sorted by path
-- so the hash is independent of embed-order. First 12 hex chars
-- are plenty to disambiguate across sky versions.
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


-- | Return the path to a ready-to-run `sky-ffi-inspect-rs`. Builds
-- into `$XDG_CACHE_HOME/sky/tools/sky-ffi-inspect-rs-<hash>/` on first
-- use; reuses the cached binary thereafter.
ensureInspectorRust :: IO (Either String FilePath)
ensureInspectorRust = do
    cache <- getXdgDirectory XdgCache "sky"
    let root = cache </> "tools" </> ("sky-ffi-inspect-rs-" ++ inspectorRustHash)
        bin  = root </> "target" </> "debug" </> "sky-ffi-inspect-rs"
    ready <- doesFileExist bin
    if ready
        then return (Right bin)
        else buildInspectorRust root bin


buildInspectorRust :: FilePath -> FilePath -> IO (Either String FilePath)
buildInspectorRust root bin = do
    createDirectoryIfMissing True root
    -- Materialise source.
    forM_ embeddedInspectorRustBytes $ \(rel, bytes) -> do
        let dst = root </> rel
        createDirectoryIfMissing True (takeDirectory dst)
        BS.writeFile dst bytes
    -- cargo build .
    let cargoBuild = (proc "cargo" ["build", "--manifest-path", root </> "Cargo.toml"])
                      { cwd = Just root }
    (ec, _out, err) <- readCreateProcessWithExitCode cargoBuild ""
    case ec of
        ExitSuccess -> do
            let bin' = root </> "target" </> "debug" </> "sky-ffi-inspect-rs"
            perms <- getPermissions bin'
            setPermissions bin' (setOwnerExecutable True perms)
            exists <- doesFileExist bin'
            unless exists $
                return ()
            return (Right bin')
        _ ->
            return (Left $ "sky-ffi-inspect-rs: cargo build failed:\n" ++ err)
