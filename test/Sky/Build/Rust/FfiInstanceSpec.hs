module Sky.Build.Rust.FfiInstanceSpec (spec) where

-- Wall #2 of the demand-driven generic Sky→Rust FFI epic (the (A)-model):
-- unit fences for the per-instance bindability check, the closed-set Sky→Rust
-- mapping, the static trait table (F3 — the security-critical cells), and the
-- one-generic-wrapper synthesis. These are the cheap, deterministic gates the
-- fixture build can't give at unit granularity.

import Test.Hspec

import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import qualified Sky.AST.Canonical as Can
import qualified Sky.Sky.ModuleName as ModuleName
import qualified Sky.Build.FfiRegistry as FfiReg
import qualified Sky.Build.Rust.FfiCall as Call
import qualified Sky.Reporting.Annotation as A
import qualified Sky.Reporting.Diagnostic as Diag
import Sky.Build.Rust.FfiInstance
    ( checkInstance, checkInstances
    , FfiInstance(..), GenericFn(..)
    , WrapperResult(..)
    , synthesiseGenericWrapper, synthesiseGenericWrappers
    , skyTypeToRustClosed, traitsOfRustType, traitToRustPath, modellableTrait
    , rustTypeIsClone, skyCaptureIsClone, mkCaptureNotCloneError
    )
import Sky.Build.Rust.Ffi (translateRustRet)


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


-- A generic-FFI metadata block with the given params/bounds/Call-AST.
mkGen :: [String] -> [(String, [String])] -> Call.Call -> FfiReg.FfiGeneric
mkGen ps bs call = FfiReg.FfiGeneric ps (Map.fromList bs) call

-- The canonical `make : a -> Box1 a` call-AST: static assoc-fn (no receiver),
-- one value-arg of type `a`, returns `::box1::Box1<a>`.
makeCall :: Call.Call
makeCall = Call.Call
    { Call._call_kind     = Call.CallFunction
    , Call._call_path     = ["::box1", "Box1"]
    , Call._call_typeArgs = [Call.TRParam 0]
    , Call._call_method   = Just "make"
    , Call._call_receiver = Nothing
    , Call._call_args     = [0]
    , Call._call_argTypes = [Call.TRParam 0]
    , Call._call_ret      = Call.TRCtor "::box1::Box1" [Call.TRParam 0]
    }

-- An instance over a single param `a` at type `ty`, with the given bounds.
mkInst :: [(String, [String])] -> Can.Type -> FfiInstance
mkInst bs ty = FfiInstance
    { _fi_callee  = "Rust.Box1.make"
    , _fi_types   = [ty]
    , _fi_region  = A.one
    , _fi_file    = "T.sky"
    , _fi_generic = mkGen ["a"] bs makeCall
    }

isE4400 :: Diag.Diagnostic -> Bool
isE4400 d = Diag._diag_code d == Diag.ffiE_GenericNotBindable


spec :: Spec
spec = do
    describe "#22 List-element coercion (translateRustRet seq arm)" $ do
        let decl t = fst (translateRustRet t)
            body t e = snd (translateRustRet t) e
        it "identity-mapping elements: decl is the element type, borrowed clones" $ do
            -- i64 / f64 / bool / char / String map to themselves → no per-element
            -- coercion: owned is identity, borrowed `.to_vec()`.
            decl "Vec<i64>"  `shouldBe` "Vec<i64>"
            body "Vec<i64>" "v" `shouldBe` "v"
            decl "&[f64]"    `shouldBe` "Vec<f64>"
            body "&[f64]" "v" `shouldBe` "v.to_vec()"
            decl "Vec<String>" `shouldBe` "Vec<String>"
        it "wide-int element saturates per element; decl is Vec<i64> (not Vec<u64>)" $ do
            decl "&[u64]" `shouldBe` "Vec<i64>"
            body "&[u64]" "v"
                `shouldBe` "v.iter().map(|&x| (x).min(i64::MAX as u64) as i64).collect::<Vec<_>>()"
            decl "Vec<u64>" `shouldBe` "Vec<i64>"
            body "Vec<u64>" "v"
                `shouldBe` "v.into_iter().map(|x| (x).min(i64::MAX as u64) as i64).collect::<Vec<_>>()"
        it "narrow-int + f32 elements widen per element to Vec<i64> / Vec<f64>" $ do
            decl "&[u32]" `shouldBe` "Vec<i64>"
            body "&[u32]" "v"
                `shouldBe` "v.iter().map(|&x| (x) as i64).collect::<Vec<_>>()"
            decl "&[f32]" `shouldBe` "Vec<f64>"
            body "&[f32]" "v"
                `shouldBe` "v.iter().map(|&x| (x) as f64).collect::<Vec<_>>()"
        it "u8 stays the byte fast-path (ElemU8), unaffected" $ do
            decl "&[u8]" `shouldBe` "Vec<i64>"
            body "&[u8]" "v" `shouldBe` "from_u8_slice(v)"
        it "fixed-size array of a wide int saturates per element" $ do
            decl "[u64; 4]" `shouldBe` "Vec<i64>"
            body "[u64; 4]" "v"
                `shouldBe` "v.into_iter().map(|x| (x).min(i64::MAX as u64) as i64).collect::<Vec<_>>()"

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
        -- Drift fence 4a: the modellable-5 set is duplicated in the inspector
        -- (`MODELLABLE_5`). This asserts the Haskell side is EXACTLY these five
        -- and no more; the inspector crate has the mirror assertion
        -- (test_modellable_5_matches). If either side adds/removes a trait
        -- without the other, one of the two fails — the cross-language set
        -- can't silently drift.
        it "the modellable-5 set is EXACTLY {Hash,Eq,Ord,Clone,Default} (drift 4a)" $ do
            let candidates =
                    [ "Hash", "Eq", "Ord", "Clone", "Default"
                    , "Sized", "Send", "Sync", "Copy", "Debug", "Serialize"
                    , "PartialEq", "PartialOrd", "Display", "FromStr" ]
                modellable = filter modellableTrait candidates
            Set.fromList modellable
                `shouldBe` Set.fromList ["Hash", "Eq", "Ord", "Clone", "Default"]

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

    describe "synthesiseGenericWrapper (one generic wrapper, A-model, Scheme-A AST)" $ do
        let mkFn bs call = GenericFn
                { _gf_kernelName = "Rust_Box1"
                , _gf_baseName   = "rust_box1_make"
                , _gf_refName    = "make"
                , _gf_generic    = mkGen ["a"] bs call
                , _gf_region     = A.one
                , _gf_file       = "T.sky"
                }
            okSrc r = case r of WrapperOk _ _ s -> s; _ -> ""
            -- `get : Box1 a -> a` — static-style assoc fn with a foreign-typed
            -- VALUE arg (`::box1::Box1<a>`), returns the bare param.
            getCall = Call.Call
                { Call._call_kind     = Call.CallFunction
                , Call._call_path     = ["::box1", "Box1"]
                , Call._call_typeArgs = [Call.TRParam 0]
                , Call._call_method   = Just "get"
                , Call._call_receiver = Nothing
                , Call._call_args     = [0]
                , Call._call_argTypes = [Call.TRCtor "::box1::Box1" [Call.TRParam 0]]
                , Call._call_ret      = Call.TRParam 0
                }
            -- `Idx::of : a -> Idx a` — a bounded ctor for the bounds-render test.
            idxOfCall = Call.Call
                { Call._call_kind     = Call.CallFunction
                , Call._call_path     = ["::idx", "Idx"]
                , Call._call_typeArgs = [Call.TRParam 0]
                , Call._call_method   = Just "of"
                , Call._call_receiver = Nothing
                , Call._call_args     = [0]
                , Call._call_argTypes = [Call.TRParam 0]
                , Call._call_ret      = Call.TRCtor "::idx::Idx" [Call.TRParam 0]
                }
        it "emits a generic <T> wrapper for an unconstrained fn (TVar→UpperCamel)" $ do
            let src = okSrc (synthesiseGenericWrapper (mkFn [] makeCall))
            src `shouldContain` "pub fn rust_box1_make<A>(arg0: A)"
            src `shouldContain` "-> SkyResult<SkyError, ::box1::Box1<A>>"
            src `shouldContain` "ok_res(::box1::Box1::<A>::make(arg0))"
        it "renders a foreign-typed value arg from the call's argTypes" $ do
            let src = okSrc (synthesiseGenericWrapper (mkFn [] getCall))
            src `shouldContain` "pub fn rust_box1_make<A>(arg0: ::box1::Box1<A>)"
            src `shouldContain` "ok_res(::box1::Box1::<A>::get(arg0))"
        it "renders bounds onto <T: ...> from metadata" $ do
            let src = okSrc (synthesiseGenericWrapper
                      (mkFn [("a",["Hash","Eq"])] idxOfCall))
            src `shouldContain`
                "<A: ::std::hash::Hash + ::std::cmp::Eq>"
        it "REJECTS an unmodellable bound (no emit-and-hope)" $
            case synthesiseGenericWrapper (mkFn [("a",["Serialize"])] idxOfCall) of
                WrapperRejected d -> isE4400 d `shouldBe` True
                _ -> expectationFailure "unmodellable bound must reject"
    describe "#28 closure-capture Clone allowlist" $ do
        it "rustTypeIsClone is a positive allowlist over closed Clone types" $ do
            map rustTypeIsClone ["i64","String","bool","char","()","Vec<i64>","SkyMaybe<i64>","f64"]
                `shouldBe` replicate 8 True   -- f64 IS Clone (only Hash/Eq/Ord fail)
            rustTypeIsClone "SomeOpaque" `shouldBe` False   -- not closed => not provably Clone
        it "skyCaptureIsClone admits closed Clone Sky types, rejects non-closed" $ do
            skyCaptureIsClone tInt  `shouldBe` True
            skyCaptureIsClone tStr  `shouldBe` True
            -- a record type is NOT closed => rejected
            skyCaptureIsClone (Can.TRecord Map.empty Nothing) `shouldBe` False
        it "non-Clone capture into a multi-call Fn slot => E4400 (not cargo-fail)" $ do
            let d = mkCaptureNotCloneError A.one "myFile.sky" "task0" "Task Error ()"
            Diag._diag_code d `shouldBe` Diag.ffiE_GenericNotBindable
            isInfixOf "must be Clone" (Diag._diag_message d) `shouldBe` True

  where
    isLeft (Left _)  = True
    isLeft (Right _) = False
