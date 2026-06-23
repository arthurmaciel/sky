{-# LANGUAGE OverloadedStrings #-}

-- | Regression fence for #32 and #34 — the FFI Result-error-type lowering mismatch.
--
-- #32: An auto-FFI `.skyi` can advertise a foreign Result as `Result String a`
-- (the error slot rendered as `String`). But the generated FFI wrapper ALWAYS
-- returns `SkyResult<SkyError, _>` (the documented design: an FFI Result's
-- error slot is unusable on the Sky side — codegen forces `SkyError`). When
-- such a Result flows through a top-level Sky binding, the binding's lowered
-- return type came straight from the advertised annotation — `SkyResult<String, _>`
-- — while the value is `SkyResult<SkyError, _>`. That mismatch is a cargo E0308
-- on the NORMAL (DCE-on) path, for BOTH an explicitly-annotated `Result String a`
-- binding and an UNANNOTATED binding (inferred type follows the skyi).
--
-- The fix normalises the `Result` ERROR slot to `SkyError` for `Can.TType "String"`.
-- This is sound because `String` in a Result error slot is never legitimate in
-- the Rust backend — Sky bans `Result String a` in public surfaces, the runtime
-- never constructs a `SkyResult<String, _>` value, and the only origin is an
-- FFI `.skyi` advertising `String`. `Result Error a` already rendered `SkyError`
-- and is unchanged.
--
-- #34: The #32 fix MUST key on the Can.Type CONSTRUCTOR (`Can.TType _ "String" []`),
-- NOT on the rendered string `"String"`. An unmatched anonymous TRecord (e.g.
-- `{ foo : Int }` with no alias in the record-map) also renders `"String"` via
-- the fallback branch (`otherwise -> "String"` in typeToRustString). If such a
-- TRecord landed in a Result ERROR slot, the rendered-string match would wrongly
-- normalise it to `SkyError` — a latent type-safety foot-gun. By matching on the
-- Can.Type AST node BEFORE rendering, only a genuine `Can.TType _ "String" []`
-- triggers the normalisation; an anon-record fallback does not.
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

-- | An anonymous TRecord with one field that has no alias in the record-map —
-- typeToRustString falls back to `"String"` for it.  Used in #34 tests.
anonRecordStringFallback :: Can.Type
anonRecordStringFallback =
    -- `{ foo : Int }` — field present but empty record-map has no matching alias
    Can.TRecord
        (Map.singleton "foo" (Can.FieldType 0 (tcon "Int")))
        Nothing

render :: Can.Type -> String
render = typeToRustString Map.empty


spec :: Spec
spec = do
    describe "typeToRustString — Result error slot (#32)" $ do

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

    describe "typeToRustString — Result error slot anon-record guard (#34)" $ do

        it "anon TRecord with no alias renders to String (fallback baseline — confirm the fallback)" $
            render anonRecordStringFallback `shouldBe` "String"

        it "#34: anon TRecord in Result ERROR slot must NOT be normalised to SkyError (only Can.TType String gets that)" $
            -- Before the #34 fix this wrongly returns "SkyResult<SkyError, i64>".
            -- After the fix it must return "SkyResult<String, i64>" because the
            -- error type is a TRecord, not a genuine Can.TType "String" [].
            render (resultTy anonRecordStringFallback (tcon "Int"))
                `shouldBe` "SkyResult<String, i64>"
