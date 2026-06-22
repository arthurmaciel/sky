module Sky.Build.FfiTypeResolveSpec (spec) where

-- Wall #1 of the demand-driven generic Sky->Rust FFI epic: a
-- non-builtin type constructor that CARRIES type arguments must
-- survive 'ftyToType' as a genuine parametric 'Can.TType' (args
-- preserved, non-empty home), NOT collapse to the opaque @Value@
-- sentinel. A NULLARY non-builtin ctor (a concrete foreign type)
-- must stay byte-for-byte at the existing @Value@ representation.
--
-- This spec is a SHARED-compiler regression fence: it locks both
-- the new parametric branch (constraints A/C/D-E) and the unchanged
-- nullary branch (constraint B). The Go backend never reaches the
-- parametric branch — its inspector drops generic functions
-- (FfiGen.shouldSkipFn) before a parametric skyType is emitted — so
-- this surface is Rust-only at runtime but lives in the shared HM
-- type-resolution layer.

import Test.Hspec
import qualified Sky.AST.Canonical as Can
import qualified Sky.Sky.ModuleName as ModuleName
import Sky.Build.FfiTypeParser (FtyAst(..))
import Sky.Build.FfiTypeResolve (ftyToType, ftyToAnnotation)


-- Builders mirroring the FfiTypeParserSpec conventions.
str, int_ :: FtyAst
str  = FtyApp "String" []
int_ = FtyApp "Int" []

opaque :: String -> FtyAst
opaque n = FtyApp n []

opaqueValueTy :: Can.Type
opaqueValueTy = Can.TType (ModuleName.Canonical "") "Value" []


spec :: Spec
spec = do
    describe "ftyToType (Wall #1: parametric foreign types)" $ do

        it "preserves a parametric foreign ctor as TType <home> Name [args]" $ do
            -- IndexMap k v  ==>  TType (Canonical "Sky.Core.Collections")
            --                          "IndexMap" [TVar "k", TVar "v"]
            let ast = FtyApp "IndexMap" [FtyVar "k", FtyVar "v"]
                resolved = ftyToType "Sky.Core.Collections" ast
            resolved `shouldBe`
                Can.TType (ModuleName.Canonical "Sky.Core.Collections")
                          "IndexMap"
                          [Can.TVar "k", Can.TVar "v"]
            -- (A/D) NOT the opaque sentinel — args were preserved.
            resolved `shouldNotBe` opaqueValueTy

        it "uses a NON-EMPTY home derived from the kernel name (constraint C)" $ do
            let ast = FtyApp "IndexMap" [FtyVar "k", FtyVar "v"]
            case ftyToType "Auth" ast of
                Can.TType (ModuleName.Canonical home) _ _ ->
                    home `shouldBe` "Auth"
                other ->
                    expectationFailure
                        ("expected parametric TType, got: " ++ show other)

        it "keeps two crates' same-named parametric type nominally DISTINCT" $ do
            -- Same Name + same args, different kernel/crate home =>
            -- different TType identity (the unifier keys on home).
            let ast = FtyApp "IndexMap" [FtyVar "k", FtyVar "v"]
                fromCrateA = ftyToType "crate_a" ast
                fromCrateB = ftyToType "crate_b" ast
            fromCrateA `shouldNotBe` fromCrateB

        it "recursively resolves nested parametric args (constraint D)" $ do
            -- IndexMap k (Maybe v)  preserves the nested Maybe shape.
            let ast = FtyApp "IndexMap"
                        [ FtyVar "k"
                        , FtyApp "Maybe" [FtyVar "v"]
                        ]
                resolved = ftyToType "crate_x" ast
            resolved `shouldBe`
                Can.TType (ModuleName.Canonical "crate_x") "IndexMap"
                    [ Can.TVar "k"
                    , Can.TType ModuleName.maybe_ "Maybe" [Can.TVar "v"]
                    ]

        it "leaves a NULLARY foreign ctor unchanged (constraint B)" $ do
            -- NaiveDate (no args) stays at the existing @Value@
            -- sentinel byte-for-byte — must NOT take the new branch.
            ftyToType "Chrono" (opaque "NaiveDate") `shouldBe` opaqueValueTy
            ftyToType "Auth" (opaque "ActionCodeSettings") `shouldBe` opaqueValueTy

        it "still routes builtin parametric ctors to their canonical home" $ do
            -- List / Result / Maybe / Dict etc. are unaffected — they
            -- match builtinHome before the new branch is reached.
            ftyToType "AnyKernel" (FtyApp "List" [str]) `shouldBe`
                Can.TType ModuleName.list "List" [Can.TType ModuleName.basics "String" []]
            ftyToType "AnyKernel" (FtyApp "Dict" [str, int_]) `shouldBe`
                Can.TType ModuleName.dict "Dict"
                    [ Can.TType ModuleName.basics "String" []
                    , Can.TType ModuleName.basics "Int" []
                    ]

    describe "ftyToAnnotation (Wall #1: generalisation)" $ do

        it "generalises the parametric foreign ctor's free TVars" $ do
            -- insert : k -> v -> IndexMap k v -> Maybe v
            -- must Forall over k and v (collected via collectTVars
            -- through the preserved TType args).
            let ast = FtyArrow (FtyVar "k")
                        (FtyArrow (FtyVar "v")
                            (FtyArrow (FtyApp "IndexMap" [FtyVar "k", FtyVar "v"])
                                (FtyApp "Maybe" [FtyVar "v"])))
            case ftyToAnnotation "crate_x" ast of
                Can.Forall tvars _ ->
                    -- order is first-seen, deduped: k then v.
                    tvars `shouldBe` ["k", "v"]

        it "a nullary foreign sig generalises over nothing new" $ do
            -- NaiveDate -> Result Error NaiveDate : no TVars.
            let ast = FtyArrow (opaque "NaiveDate")
                        (FtyApp "Result" [opaque "Error", opaque "NaiveDate"])
            case ftyToAnnotation "Chrono" ast of
                Can.Forall tvars _ -> tvars `shouldBe` []
