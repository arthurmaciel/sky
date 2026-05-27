{-# LANGUAGE OverloadedStrings #-}

module Sky.Build.FfiGenGoKernelJsonSpec (spec) where

import Test.Hspec
import System.Directory (createDirectoryIfMissing, withCurrentDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import qualified Data.Aeson as A
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Sky.Sky.Toml (CompileTarget(..))
import qualified Sky.Build.FfiGen as FfiGen


spec :: Spec
spec = describe "FfiGen Go kernel.json byte-identity (Cross-backend rule 5)" $ do
    it "produces byte-identical .kernel.json output across rebuilds" $ do
        -- Read fixtures BEFORE changing to temp dir (paths are project-relative)
        goldenInput <- BS.readFile "test/fixtures/go-kernel-json/uuid.pkg-info.json"
        expectedBytes <- BS.readFile "test/fixtures/go-kernel-json/uuid.golden.json"
        -- Run in a temp dir so generateBindings doesn't pollute the source tree
        withSystemTempDirectory "sky-go-kernel-json" $ \tmp -> do
            withCurrentDirectory tmp $ do
                createDirectoryIfMissing True ".skycache/ffi"
                case A.eitherDecode (BL.fromStrict goldenInput) of
                    Left  e -> expectationFailure ("Failed to decode PkgInfo fixture: " ++ e)
                    Right pkgInfo -> do
                        _ <- FfiGen.generateBindings pkgInfo
                        -- generateBindings uses slugify (_pkgName pkg), which
                        -- for this fixture is "uuid" → slug "uuid".
                        let jsonPath = ".skycache/ffi/uuid.kernel.json"
                        actualBytes <- BS.readFile jsonPath
                        actualBytes `shouldBe` expectedBytes
