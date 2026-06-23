{-# LANGUAGE OverloadedStrings #-}

-- | Regression fence for #32 — the FFI Result-error-type lowering mismatch.
--
-- An auto-FFI `.skyi` can advertise a foreign Result as `Result String a`
-- (the error slot rendered as `String`). But the generated FFI wrapper ALWAYS
-- returns `SkyResult<SkyError, _>` (the documented design: an FFI Result's
-- error slot is unusable on the Sky side — codegen forces `SkyError`). When
-- such a Result flows through a top-level Sky binding, the binding's lowered
-- return type came straight from the advertised annotation — `SkyResult<String, _>`
-- — while the value is `SkyResult<SkyError, _>`. That mismatch is a cargo E0308
-- on the NORMAL (DCE-on) path, for BOTH an explicitly-annotated `Result String a`
-- binding and an UNANNOTATED binding (inferred type follows the skyi).
--
-- The fix normalises the `Result` ERROR slot to `SkyError` whenever it would
-- render to `String`. This is sound because `String` in a Result error slot is
-- never legitimate in the Rust backend — Sky bans `Result String a` in public
-- surfaces, the runtime never constructs a `SkyResult<String, _>` value, and
-- the only origin is an FFI `.skyi` advertising `String`. `Result Error a`
-- already rendered `SkyError` and is unchanged.
module Sky.Generate.Rust.TypeRendererSpec (spec) where

import Test.Hspec

import qualified Data.Map.Strict as Map
import qualified Sky.AST.Canonical as Can
import qualified Sky.Sky.ModuleName as ModuleName

import Sky.Generate.Rust.Builder.TypeRenderer (typeToRustString)


-- | Build a nominal `Can.Type` with no args (e.g. `String`, `Error`, `Int`).
tcon :: String -> Can.Type
tcon n = Can.TType (ModuleName.Canonical "") n []

-- | Build `Result e a`.
resultTy :: Can.Type -> Can.Type -> Can.Type
resultTy e a = Can.TType (ModuleName.Canonical "") "Result" [e, a]

render :: Can.Type -> String
render = typeToRustString Map.empty


spec :: Spec
spec = describe "typeToRustString — Result error slot (#32)" $ do

    it "renders `Result Error a` error slot as SkyError (baseline, unchanged)" $
        render (resultTy (tcon "Error") (tcon "Int"))
            `shouldBe` "SkyResult<SkyError, i64>"

    it "renders `Result String a` error slot as SkyError too (#32 fix — matches the FFI wrapper's SkyResult<SkyError, _>)" $
        render (resultTy (tcon "String") (tcon "Int"))
            `shouldBe` "SkyResult<SkyError, i64>"

    it "keeps an OK-slot String intact — only the ERROR slot normalises" $
        render (resultTy (tcon "Error") (tcon "String"))
            `shouldBe` "SkyResult<SkyError, String>"

    it "normalises only the error slot when OK slot is also String" $
        render (resultTy (tcon "String") (tcon "String"))
            `shouldBe` "SkyResult<SkyError, String>"

    it "leaves a bare `String` (not in a Result error slot) untouched" $
        render (tcon "String") `shouldBe` "String"

    it "leaves a `List String` untouched" $
        render (Can.TType (ModuleName.Canonical "") "List" [tcon "String"])
            `shouldBe` "Vec<String>"
