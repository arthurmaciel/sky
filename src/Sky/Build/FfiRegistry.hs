{-# LANGUAGE OverloadedStrings #-}
-- | Reads ffi/*.kernel.json files into a registry used by the canonicaliser
-- and Kernel.lookup so FFI packages flow through the same resolution path as
-- stdlib kernel modules.
module Sky.Build.FfiRegistry
    ( FfiRegistry(..)
    , FfiModule(..)
    , FfiFunction(..)
    , FfiGeneric(..)
    , loadRegistry
    , emptyRegistry
    , lookupFunction
    ) where

import qualified Data.Aeson as A
import Data.Aeson ((.:), (.:?), (.!=))
import qualified Data.ByteString.Lazy as BL
import Control.Monad (filterM, when)
import Data.List (isPrefixOf, isSuffixOf)
import qualified Data.Map.Strict as Map
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import System.IO (putStrLn)

import Sky.Build.FfiTypeParser (FtyAst, parseFty)
import Sky.Build.Rust.FfiCall (Call, parseCall)
import Sky.Sky.Toml (Backend(BackendGo, BackendRust))


data FfiFunction = FfiFunction
    { _ffn_name    :: !String     -- Sky-side name, e.g. "newString"
    , _ffn_arity   :: !Int        -- Sky-side arity (unit param for zero-Go-arg)
    , _ffn_skyType :: !(Maybe FtyAst)
        -- ^ Parsed Sky-side wrapper type, including the runtime
        -- @Result Error _@ wrap (see Sky.Build.FfiGen.wrapperSkyType).
        -- 'Nothing' when the JSON entry omits @skyType@ — happens
        -- for FFI shapes the inspector can't faithfully render
        -- (channels, deeply-nested inline-struct callback bundles)
        -- and for older kernel.json files written before this field
        -- existed. The HM-wire path falls back to the legacy
        -- "no Sky type known" branch in those cases.
    , _ffn_generic :: !(Maybe FfiGeneric)
        -- ^ Wall #2 (demand-driven generic Sky→Rust FFI epic): the
        -- parametric synthesis metadata for a GENERIC FFI function.
        -- 'Nothing' for every non-generic binding — i.e. every
        -- inspector-emitted kernel.json today and every existing
        -- fixture (the field decodes via @.:?@, so byte-identical
        -- behaviour for files that omit it). Present ONLY when a
        -- (currently hand-written, Wall #3 inspector-written) stub
        -- declares a Rust template + per-type-param trait bounds so
        -- codegen can monomorphise a concrete wrapper per used
        -- instantiation.
    }
    deriving (Show, Eq)


-- | Wall #2 parametric-synthesis metadata for a generic FFI function.
-- Carried in the kernel.json @generic@ object. All three fields are
-- load-bearing for the per-instance synthesis + the bindability gate:
--
--   * @_fg_params@   — the type-param names (Sky-source @Forall@ order),
--                      e.g. @["a"]@ for @make : a -> Box1 a@. Positional
--                      with the call instance's resolved type-args.
--   * @_fg_bounds@   — per-param declared Rust trait bounds (a list of
--                      bound names like @["Hash","Eq"]@). A param absent
--                      from the map carries no bound (unconstrained
--                      generic). The bindability gate checks each
--                      concrete arg satisfies every declared bound via a
--                      static closed-set × trait table.
--   * @_fg_call@     — Wall #3 (Scheme A) typed call-AST that REPLACES the
--                      retired @{hole}@ Rust string template. A closed
--                      'Call' ADT (path + turbofish type-args + receiver +
--                      value-args + return TypeRef) over which codegen's
--                      'renderCall' walker is TOTAL — illegal param
--                      placement is unrepresentable, so a malformed AST is a
--                      hard parse error (validated at decode against
--                      @_fg_params@), never a leaked un-substituted hole.
data FfiGeneric = FfiGeneric
    { _fg_params   :: ![String]
    , _fg_bounds   :: !(Map.Map String [String])
    , _fg_call     :: !Call
    }
    deriving (Show, Eq)


data FfiModule = FfiModule
    { _fm_moduleName :: !String  -- e.g. "Github.Com.Google.Uuid"
    , _fm_kernelName :: !String  -- e.g. "Uuid"
    , _fm_package    :: !String  -- e.g. "github.com/google/uuid"
    , _fm_functions  :: ![FfiFunction]
    }
    deriving (Show, Eq)


data FfiRegistry = FfiRegistry
    { _fr_modules :: ![FfiModule]
    }
    deriving (Show, Eq)


emptyRegistry :: FfiRegistry
emptyRegistry = FfiRegistry []


-- | Find function arity by (kernelName, funcName). Nothing if unknown.
lookupFunction :: FfiRegistry -> String -> String -> Maybe Int
lookupFunction reg kname fname =
    let ms = filter (\m -> _fm_kernelName m == kname) (_fr_modules reg)
        fs = concatMap _fm_functions ms
    in  case filter (\f -> _ffn_name f == fname) fs of
            (f:_) -> Just (_ffn_arity f)
            []    -> Nothing


-- ═══════════════════════════════════════════════════════════
-- JSON decoding
-- ═══════════════════════════════════════════════════════════

instance A.FromJSON FfiFunction where
    parseJSON = A.withObject "FfiFunction" $ \o -> do
        n <- o .: "name"
        a <- o .:? "arity" .!= 1
        rawSky <- o .:? "skyType"
        let parsed = rawSky >>= parseFty
        gen <- o .:? "generic"
        return (FfiFunction n a parsed gen)


instance A.FromJSON FfiGeneric where
    parseJSON = A.withObject "FfiGeneric" $ \o -> do
        ps <- o .:? "params" .!= []
        bs <- o .:? "bounds" .!= Map.empty
        -- The Scheme-A call-AST. Decoded + VALIDATED against the declared
        -- param count (every {param:i} < |params|, receiver-iff-method,
        -- gap-free arg refs) — a malformed AST is a hard parse error, never a
        -- silent default (guardian constraint #2). The `call` key is REQUIRED
        -- for a `generic` block (a generic stub without a call body is
        -- malformed); the whole `generic` object is itself `.:?`-optional on
        -- the parent FfiFunction, so non-generic bindings are unaffected.
        callV <- o .: "call"
        call  <- parseCall (length ps) callV
        return (FfiGeneric ps bs call)


instance A.FromJSON FfiModule where
    parseJSON = A.withObject "FfiModule" $ \o -> do
        m  <- o .: "moduleName"
        k  <- o .: "kernelName"
        p  <- o .:? "package" .!= ""
        fs <- o .:? "functions" .!= []
        return (FfiModule m k p fs)


-- ═══════════════════════════════════════════════════════════
-- Disk scanning
-- ═══════════════════════════════════════════════════════════

-- | Load the FfiRegistry from the target-appropriate .skycache/ffi/ directory.
-- For Go target: reads `.skycache/ffi/*.kernel.json` at the root (unchanged
-- behavior). For Rust target: reads `.skycache/ffi/rust/*.kernel.json`.
-- Silently returns an empty registry if the cache directory is absent.
loadRegistry :: Backend -> IO FfiRegistry
loadRegistry BackendGo =
    loadFromDir ".skycache/ffi"
loadRegistry BackendRust = do
    reg <- loadFromDir ".skycache/ffi/rust"
    if null (_fr_modules reg)
        then do
            stale <- findStaleRustFiles
            when stale $
                putStrLn "   legacy Rust FFI cache layout detected at .skycache/ffi/<slug>.kernel.json; re-run `sky install` or re-add the dep -- file ignored"
            return emptyRegistry
        else return reg

-- | Load all valid .kernel.json files from a given directory.
loadFromDir :: FilePath -> IO FfiRegistry
loadFromDir ffiDir = do
    exists <- doesDirectoryExist ffiDir
    if not exists
        then return emptyRegistry
        else do
            entries <- listDirectory ffiDir
            let regs = filter (".kernel.json" `isSuffixOf`) entries
            mods <- mapM (parseOne . (ffiDir </>)) regs
            return (FfiRegistry (concat mods))
  where
    parseOne :: FilePath -> IO [FfiModule]
    parseOne path = do
        bytes <- BL.readFile path
        case A.eitherDecode bytes of
            Left _  -> return []  -- bad JSON: ignore so partial registry still works
            Right m -> return [m]

-- | Check for legacy Rust FFI .kernel.json files sitting flat at
-- `.skycache/ffi/` root (from before the U1 layout change).  Any file
-- whose kernelName starts with "Rust_" is a stale Rust artifact.
findStaleRustFiles :: IO Bool
findStaleRustFiles = do
    let ffiDir = ".skycache/ffi"
    exists <- doesDirectoryExist ffiDir
    if not exists then return False else do
        entries <- listDirectory ffiDir
        let kernelJsons = filter (".kernel.json" `isSuffixOf`) entries
        results <- mapM hasRustKernelName (map (ffiDir </>) kernelJsons)
        return (or results)
  where
    hasRustKernelName path = do
        bytes <- BL.readFile path
        case A.eitherDecode bytes of
            Left _  -> return False
            Right m -> return $ "Rust_" `isPrefixOf` _fm_kernelName m
