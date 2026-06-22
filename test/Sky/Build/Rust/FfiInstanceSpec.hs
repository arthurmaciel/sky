module Sky.Build.Rust.FfiInstanceSpec (spec) where

-- Wall #2 of the demand-driven generic Sky→Rust FFI epic (the (A)-model):
-- unit fences for the per-instance bindability check, the closed-set Sky→Rust
-- mapping, the static trait table (F3 — the security-critical cells), and the
-- one-generic-wrapper synthesis. These are the cheap, deterministic gates the
-- fixture build can't give at unit granularity.

import Test.Hspec

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import qualified Sky.AST.Canonical as Can
import qualified Sky.Sky.ModuleName as ModuleName
import qualified Sky.Build.FfiRegistry as FfiReg
import qualified Sky.Reporting.Annotation as A
import qualified Sky.Reporting.Diagnostic as Diag
import Sky.Build.Rust.FfiInstance


-- ── Can.Type builders ────────────────────────────────────────────────
tInt, tFloat, tBool, tChar, tStr, tUnit :: Can.Type
tInt   = Can.TType (ModuleName.Canonical "") "Int" []
tFloat = Can.TType (ModuleName.Canonical "") "Float" []
tBool  = Can.TType (ModuleName.Canonical "") "Bool" []
tChar  = Can.TType (ModuleName.Canonical "") "Char" []
tStr   = Can.TType (ModuleName.Canonical "") "String" []
tUnit  = Can.TUnit

tList, tMaybe :: Can.Type -> Can.Type
tList el  = Can.TType (ModuleName.Canonical "") "List" [el]
tMaybe el = Can.TType (ModuleName.Canonical "") "Maybe" [el]


-- A generic-FFI metadata block with the given params/bounds/template.
mkGen :: [String] -> [(String, [String])] -> String -> FfiReg.FfiGeneric
mkGen ps bs tmpl = FfiReg.FfiGeneric ps (Map.fromList bs) tmpl

-- An instance over a single param `a` at type `ty`, with the given bounds.
mkInst :: [(String, [String])] -> Can.Type -> FfiInstance
mkInst bs ty = FfiInstance
    { _fi_callee  = "Rust.Box1.make"
    , _fi_types   = [ty]
    , _fi_region  = A.one
    , _fi_file    = "T.sky"
    , _fi_generic = mkGen ["a"] bs "// ret: ::box1::Box1<{a}>\n::box1::Box1::<{a}>::make({arg0})"
    }

isE4400 :: Diag.Diagnostic -> Bool
isE4400 d = Diag._diag_code d == Diag.ffiE_GenericNotBindable


spec :: Spec
spec = do
    describe "skyTypeToRustClosed (closed set)" $ do
        it "maps every primitive" $ do
            skyTypeToRustClosed tInt   `shouldBe` Right "i64"
            skyTypeToRustClosed tFloat `shouldBe` Right "f64"
            skyTypeToRustClosed tBool  `shouldBe` Right "bool"
            skyTypeToRustClosed tChar  `shouldBe` Right "char"
            skyTypeToRustClosed tStr   `shouldBe` Right "String"
            skyTypeToRustClosed tUnit  `shouldBe` Right "()"
        it "maps List / Maybe recursively" $ do
            skyTypeToRustClosed (tList tInt)        `shouldBe` Right "Vec<i64>"
            skyTypeToRustClosed (tMaybe tStr)       `shouldBe` Right "SkyMaybe<String>"
            skyTypeToRustClosed (tList (tMaybe tInt))
                `shouldBe` Right "Vec<SkyMaybe<i64>>"
        it "rejects a residual TVar (F2: never a boxed fallback)" $
            case skyTypeToRustClosed (Can.TVar "a") of
                Left _  -> True `shouldBe` True
                Right _ -> expectationFailure "TVar must be Left"
        it "rejects records / tuples / functions / opaque ctors" $ do
            skyTypeToRustClosed (Can.TTuple tInt tStr [])    `shouldSatisfy` isLeft
            skyTypeToRustClosed (Can.TLambda tInt tStr)      `shouldSatisfy` isLeft
            skyTypeToRustClosed (Can.TType (ModuleName.Canonical "") "Foo" [])
                `shouldSatisfy` isLeft

    describe "traitsOfRustType (F3 static table)" $ do
        it "i64 / String / bool / char / () : Hash+Eq+Ord+Clone+Default" $
            mapM_ (\t -> traitsOfRustType t
                    `shouldBe` Set.fromList ["Hash","Eq","Ord","Clone","Default"])
                ["i64", "String", "bool", "char", "()"]
        it "f64 / f32 : Clone+Default ONLY — never Hash/Eq/Ord (security cell)" $ do
            traitsOfRustType "f64" `shouldBe` Set.fromList ["Clone","Default"]
            traitsOfRustType "f32" `shouldBe` Set.fromList ["Clone","Default"]
        it "Vec<T>: Default always; Hash/Eq/Ord/Clone propagate from T" $ do
            traitsOfRustType "Vec<i64>"
                `shouldBe` Set.fromList ["Hash","Eq","Ord","Clone","Default"]
            -- Vec<f64>: float drops Hash/Eq/Ord, keeps Clone; Vec adds Default.
            traitsOfRustType "Vec<f64>"
                `shouldBe` Set.fromList ["Clone","Default"]
        it "SkyMaybe<T>: Clone IFF T:Clone, nothing else (runtime enum derives)" $ do
            -- NOT std Option: the runtime SkyMaybe derives only Clone/PartialEq.
            traitsOfRustType "SkyMaybe<i64>" `shouldBe` Set.fromList ["Clone"]
            traitsOfRustType "SkyMaybe<f64>" `shouldBe` Set.fromList ["Clone"]

    describe "modellableTrait / traitToRustPath" $ do
        it "the five table traits are modellable + path-renderable" $
            mapM_ (\t -> do
                    modellableTrait t `shouldBe` True
                    traitToRustPath t `shouldNotBe` Nothing)
                ["Hash","Eq","Ord","Clone","Default"]
        it "a crate-specific trait (Serialize) is NOT modellable" $ do
            modellableTrait "Serialize" `shouldBe` False
            traitToRustPath "Serialize" `shouldBe` Nothing

    describe "checkInstance (per-instance bindability)" $ do
        it "accepts an unconstrained primitive instantiation" $
            checkInstance (mkInst [] tInt) `shouldBe` []
        it "accepts a Hash-bounded Int / String" $ do
            checkInstance (mkInst [("a",["Hash","Eq"])] tInt)   `shouldBe` []
            checkInstance (mkInst [("a",["Hash","Eq"])] tStr)   `shouldBe` []
        it "REJECTS a Hash-bounded Float with E4400 (Float not Hash)" $ do
            let ds = checkInstance (mkInst [("a",["Hash"])] tFloat)
            ds `shouldSatisfy` (not . null)
            all isE4400 ds `shouldBe` True
        it "REJECTS an out-of-closed-set type-arg with E4400" $ do
            let recTy = Can.TRecord Map.empty Nothing
                ds = checkInstance (mkInst [] recTy)
            ds `shouldSatisfy` (not . null)
            all isE4400 ds `shouldBe` True
        it "REJECTS an unmodellable declared bound (Serialize) with E4400" $ do
            -- Even though String *does* impl Serialize, the BACKEND can't model
            -- the bound → reject (F1: never emit-and-hope).
            let ds = checkInstance (mkInst [("a",["Serialize"])] tStr)
            ds `shouldSatisfy` (not . null)
            all isE4400 ds `shouldBe` True

    describe "synthesiseGenericWrapper (one generic wrapper, A-model)" $ do
        let mkFn bs tmpl = GenericFn
                { _gf_kernelName = "Rust_Box1"
                , _gf_baseName   = "rust_box1_make"
                , _gf_refName    = "make"
                , _gf_generic    = mkGen ["a"] bs tmpl
                , _gf_region     = A.one
                , _gf_file       = "T.sky"
                }
            okSrc r = case r of WrapperOk _ _ s -> s; _ -> ""
        it "emits a generic <T> wrapper for an unconstrained fn (TVar→UpperCamel)" $ do
            let r = synthesiseGenericWrapper
                      (mkFn [] "// ret: ::box1::Box1<{a}>\n::box1::Box1::<{a}>::make({arg0})")
                src = okSrc r
            src `shouldContain` "pub fn rust_box1_make<A>(arg0: A)"
            src `shouldContain` "-> SkyResult<SkyError, ::box1::Box1<A>>"
            src `shouldContain` "ok_res(::box1::Box1::<A>::make(arg0))"
        it "renders the arg type from an // arg0: marker (foreign-typed arg)" $ do
            let src = okSrc (synthesiseGenericWrapper
                      (mkFn []
                        "// ret: {a}\n// arg0: ::box1::Box1<{a}>\n::box1::Box1::<{a}>::get({arg0})"))
            src `shouldContain` "pub fn rust_box1_make<A>(arg0: ::box1::Box1<A>)"
        it "renders bounds onto <T: ...> from metadata" $ do
            let src = okSrc (synthesiseGenericWrapper
                      (mkFn [("a",["Hash","Eq"])]
                        "// ret: ::idx::Idx<{a}>\n::idx::Idx::<{a}>::of({arg0})"))
            src `shouldContain`
                "<A: ::std::hash::Hash + ::std::cmp::Eq>"
        it "REJECTS an unmodellable bound (no emit-and-hope)" $
            case synthesiseGenericWrapper
                   (mkFn [("a",["Serialize"])]
                     "// ret: ::s::S<{a}>\n::s::S::<{a}>::of({arg0})") of
                WrapperRejected d -> isE4400 d `shouldBe` True
                _ -> expectationFailure "unmodellable bound must reject"
        it "REJECTS a template with no // ret: marker" $
            case synthesiseGenericWrapper
                   (mkFn [] "::box1::Box1::<{a}>::make({arg0})") of
                WrapperRejected d -> isE4400 d `shouldBe` True
                _ -> expectationFailure "missing // ret: must reject"
        it "REJECTS an unknown {hole} not in params/argN (would leak)" $
            case synthesiseGenericWrapper
                   (mkFn [] "// ret: ::s::S<{a}>\n::s::S::<{a}>::of({arg0}, {b})") of
                WrapperRejected d -> isE4400 d `shouldBe` True
                _ -> expectationFailure "unknown hole {b} must reject"
        it "REJECTS a gap in {argN} indices ({arg0}+{arg2}, no {arg1})" $
            case synthesiseGenericWrapper
                   (mkFn [] "// ret: i64\n::f::g({arg0}, {arg2})") of
                WrapperRejected d -> isE4400 d `shouldBe` True
                _ -> expectationFailure "arg-index gap must reject"
  where
    isLeft (Left _)  = True
    isLeft (Right _) = False
