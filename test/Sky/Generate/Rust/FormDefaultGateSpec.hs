{-# LANGUAGE OverloadedStrings #-}

-- | Regression fence for #37 — the form-decode `Default` stamp must be gated on
-- "all fields provably Default-able".
--
-- #37's first fix gave every `onSubmit`-handler record-arg struct (a
-- `formTarget`) `#[derive(..., Default)] #[serde(default)]` so a MISSING form
-- field decodes to its zero value (Go `json.Unmarshal` parity — missing key →
-- zero value, decode succeeds, Msg dispatches). But `#[derive(Default)]` is
-- STRUCTURAL: it demands EVERY field type impl `Default`. A form-target record
-- with a `Maybe`/`Result`/ADT/nested-record field then fails cargo with E0277
-- (`<T>: Default is not satisfied`) — a "type-checks-but-cargo-fails" floor
-- breach, even though a `Maybe`-typed optional form field is idiomatic.
--
-- The fix (Part B) gates the lenient stamp on `allFieldsDefaultable`: it fires
-- ONLY when EVERY field renders to a provably-`Default` Rust type. When a field
-- does not (e.g. a `SkyResult`/generated-enum/nested-record field), the stamp is
-- DROPPED and the struct keeps its strict pre-#37 emission (plain
-- `serde::Deserialize`, no `Default`/`serde(default)`) — which still cargo-builds,
-- it just lacks missing-field leniency. Either branch compiles; the floor holds.
--
-- `SkyMaybe<_>` is Default-able because the runtime (Part A) added an unbounded
-- `impl<T> Default for SkyMaybe<T>` (= `Nothing`).
module Sky.Generate.Rust.FormDefaultGateSpec (spec) where

import Test.Hspec
import Data.List (isInfixOf)
import qualified Data.Set as Set

import Sky.Generate.Rust.Builder.Types (RustTypeDef (RStructDef))
import Sky.Generate.Rust.Builder.Emitter (typeDefToString)


-- | Render a struct as a form target (its name ∈ formTargets), not a serde type,
-- not a fn-field struct — isolating the #37 gate.
renderFormTarget :: [(String, String)] -> String
renderFormTarget fields =
    typeDefToString
        (Set.singleton "T")        -- formTargets: this struct
        Set.empty                  -- serdeTypes
        Set.empty                  -- fnFieldStructs
        (RStructDef "T" "" fields)

-- | The lenient stamp is present iff BOTH `Default` (in the derive) AND
-- `#[serde(default)]` are emitted.
hasLenientStamp :: String -> Bool
hasLenientStamp out =
    ("Default" `isInfixOf` out) && ("#[serde(default)]" `isInfixOf` out)

spec :: Spec
spec = do
    describe "#37 form-decode Default stamp gate (allFieldsDefaultable)" $ do
        it "stamps a form target whose fields are all scalar/String (the #37 base case)" $ do
            let out = renderFormTarget [("email", "String"), ("count", "i64")]
            hasLenientStamp out `shouldBe` True

        it "stamps a form target with a SkyMaybe field (Part A makes it Default-able)" $ do
            let out = renderFormTarget
                        [ ("email", "String")
                        , ("note", "SkyMaybe<String>")
                        ]
            hasLenientStamp out `shouldBe` True

        it "stamps a form target with Vec / HashMap / Option / BTreeSet fields" $ do
            let out = renderFormTarget
                        [ ("tags", "Vec<String>")
                        , ("meta", "HashMap<String, String>")
                        , ("opt", "Option<i64>")
                        , ("set", "BTreeSet<i64>")
                        ]
            hasLenientStamp out `shouldBe` True

        it "DROPS the stamp for a form target with a SkyResult field (no canonical zero)" $ do
            let out = renderFormTarget
                        [ ("email", "String")
                        , ("parsed", "SkyResult<SkyError, i64>")
                        ]
            hasLenientStamp out `shouldBe` False

        it "DROPS the stamp for a form target with a generated-enum / nested-record field" $ do
            let out = renderFormTarget
                        [ ("email", "String")
                        , ("tier", "MainTier")          -- a generated ADT enum
                        ]
            hasLenientStamp out `shouldBe` False

        it "a DROPPED-stamp form target STILL derives serde::Deserialize (strict, cargo-builds)" $ do
            let out = renderFormTarget
                        [ ("email", "String")
                        , ("parsed", "SkyResult<SkyError, i64>")
                        ]
            ("serde::Deserialize" `isInfixOf` out) `shouldBe` True
            -- and it must NOT carry Default / serde(default)
            hasLenientStamp out `shouldBe` False
