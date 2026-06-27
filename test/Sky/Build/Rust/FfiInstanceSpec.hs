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
    , closureDropReason
    , gateClosureArg, gateClosureArgNames
    )
import Sky.Build.Rust.Ffi (translateRustRet, cargoProfilePanicIsUnwind, numSaturate)
import Sky.Generate.Rust.Builder.ExprEmitter (mkIndirectClosureDropDiag)


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

tError :: Can.Type
tError = Can.TType (ModuleName.Canonical "") "Error" []

-- `Task Error ()` — an effectful, non-closed (so non-Clone) capture type.
tTaskErrorUnit :: Can.Type
tTaskErrorUnit = Can.TType (ModuleName.Canonical "") "Task" [tError, tUnit]


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
    , Call._call_assocOnType = True
    , Call._call_iterAdapters = []
    , Call._call_traitQualifier = Nothing
    , Call._call_borrowAsRefArgs = []
    , Call._call_isAsync = False
    , Call._call_methodTurbofish = []
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

    describe "#82 numSaturate (param-width SATURATING coercion, no silent wraparound)" $ do
        it "signed narrowing clamps into [MIN,MAX] then lossless `as` (never wraps)" $ do
            numSaturate "i8"  "a" `shouldBe` "(a).clamp(i8::MIN as i64, i8::MAX as i64) as i8"
            numSaturate "i32" "a" `shouldBe` "(a).clamp(i32::MIN as i64, i32::MAX as i64) as i32"
        it "unsigned narrowing clamps into [0,MAX] then lossless `as`" $ do
            numSaturate "u8"  "a" `shouldBe` "(a).clamp(0, u8::MAX as i64) as u8"
            numSaturate "u32" "a" `shouldBe` "(a).clamp(0, u32::MAX as i64) as u32"
        it "u64/u128 saturate negatives to 0; i128 pure widen" $ do
            numSaturate "u64"  "a" `shouldBe` "(a).max(0) as u64"
            numSaturate "u128" "a" `shouldBe` "(a).max(0) as u128"
            numSaturate "i128" "a" `shouldBe` "(a) as i128"
        it "platform-width usize/isize via try_from (32-bit-correct, total)" $ do
            numSaturate "usize" "a" `shouldBe` "usize::try_from((a).max(0)).unwrap_or(usize::MAX)"
            numSaturate "isize" "a"
                `shouldBe` "isize::try_from(a).unwrap_or_else(|_| if (a) < 0 { isize::MIN } else { isize::MAX })"
        it "f32 precision-lossy cast; f64/i64 identity (no cast)" $ do
            numSaturate "f32" "a" `shouldBe` "(a) as f32"
            numSaturate "f64" "a" `shouldBe` "a"
            numSaturate "i64" "a" `shouldBe` "a"

    -- #94 (Vec<numeric> element saturation in field-setter/enum-ctor) routes the
    -- int→int-narrowing element through numSaturate (above) and keeps bare `as`
    -- for a float-source element (gated on the carried `ElemGeneral _ "Float"`
    -- classification). The end-to-end proof is fixture 97 (Pack::Nums(Vec<u32>):
    -- 5_000_000_000 → 4294967295 per element). No separate unit here — the
    -- per-element string is exactly numSaturate's, already covered above.

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
                , Call._call_assocOnType = True
                , Call._call_iterAdapters = []
                , Call._call_traitQualifier = Nothing
                , Call._call_borrowAsRefArgs = []
                , Call._call_isAsync = False
                , Call._call_methodTurbofish = []
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
                , Call._call_assocOnType = True
                , Call._call_iterAdapters = []
                , Call._call_traitQualifier = Nothing
                , Call._call_borrowAsRefArgs = []
                , Call._call_isAsync = False
                , Call._call_methodTurbofish = []
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
        -- #21 — UFCS trait methods on a concrete type. The wrapper renders the
        -- `<Self as Trait>::method` callee and threads the receiver borrow.
        it "emits a UFCS callee + immutable recv binding for a &self trait method" $ do
            -- `keyed<T: Ord>(&self, k: T) -> i64` on `impl Scale for Circle`.
            let keyedFn = GenericFn
                    { _gf_kernelName = "Rust_Tm"
                    , _gf_baseName   = "rust_tm_keyed"
                    , _gf_refName    = "keyed"
                    , _gf_generic    = mkGen ["T"] [("T",["Ord"])] keyedCall
                    , _gf_region     = A.one
                    , _gf_file       = "T.sky"
                    }
                keyedCall = Call.Call
                    { Call._call_kind     = Call.CallMethod
                    , Call._call_path     = ["::tm", "Circle"]
                    , Call._call_typeArgs = []
                    , Call._call_method   = Just "keyed"
                    , Call._call_receiver = Just (Call.Receiver 0 Call.ByRef)
                    , Call._call_args     = [1]
                    , Call._call_argTypes = [ Call.TRCtor "::tm::Circle" []
                                            , Call.TRParam 0 ]
                    , Call._call_ret      = Call.TRPrim "i64"
                    , Call._call_assocOnType = True
                    , Call._call_iterAdapters = []
                    , Call._call_traitQualifier = Just ("::tm::Circle", "::tm::Scale")
                    , Call._call_borrowAsRefArgs = []
                    , Call._call_isAsync = False
                    , Call._call_methodTurbofish = []
                    }
                src = okSrc (synthesiseGenericWrapper keyedFn)
            -- by-ref receiver: immutable param binding + `&arg0` UFCS first-arg.
            src `shouldContain` "pub fn rust_tm_keyed<T: ::std::cmp::Ord>(arg0: ::tm::Circle, arg1: T)"
            src `shouldContain` "<::tm::Circle as ::tm::Scale>::keyed(&arg0, arg1)"
            -- NOT marked `mut` (a &self receiver needs no mutable binding).
            ("mut arg0" `isInfixOf` src) `shouldBe` False
        it "marks the receiver `mut` for a &mut self trait method (&mut arg0)" $ do
            -- `push(&mut self, x: i64) -> ()`-shaped setter on a trait impl,
            -- returning the receiver by own-thread → ret is the receiver type.
            let pushFn = GenericFn
                    { _gf_kernelName = "Rust_Tm"
                    , _gf_baseName   = "rust_tm_push"
                    , _gf_refName    = "push"
                    , _gf_generic    = mkGen ["T"] [("T",["Ord"])] pushCall
                    , _gf_region     = A.one
                    , _gf_file       = "T.sky"
                    }
                pushCall = Call.Call
                    { Call._call_kind     = Call.CallMethod
                    , Call._call_path     = ["::tm", "Bag"]
                    , Call._call_typeArgs = []
                    , Call._call_method   = Just "insert"
                    , Call._call_receiver = Just (Call.Receiver 0 Call.ByRefMut)
                    , Call._call_args     = [1]
                    , Call._call_argTypes = [ Call.TRCtor "::tm::Bag" [Call.TRParam 0]
                                            , Call.TRParam 0 ]
                    , Call._call_ret      = Call.TRPrim "i64"
                    , Call._call_assocOnType = True
                    , Call._call_iterAdapters = []
                    , Call._call_traitQualifier = Just ("::tm::Bag", "::tm::Insertable")
                    , Call._call_borrowAsRefArgs = []
                    , Call._call_isAsync = False
                    , Call._call_methodTurbofish = []
                    }
                src = okSrc (synthesiseGenericWrapper pushFn)
            -- by-mut-ref receiver: `mut arg0` binding + `&mut arg0` first-arg.
            src `shouldContain` "mut arg0: ::tm::Bag<T>"
            src `shouldContain` "<::tm::Bag as ::tm::Insertable>::insert(&mut arg0, arg1)"
        -- [#95] SATURATING numeric param + return coercion on the projected/UFCS
        -- path: a `widen(&self, n: usize, w: u32, x: f32) -> usize` trait method.
        it "saturates numeric params (carrier sig + numSaturate call site) and widens a numeric return" $ do
            let widenFn = GenericFn
                    { _gf_kernelName = "Rust_Np"
                    , _gf_baseName   = "rust_np_widen"
                    , _gf_refName    = "widen"
                    , _gf_generic    = mkGen [] [] widenCall
                    , _gf_region     = A.one
                    , _gf_file       = "T.sky"
                    }
                widenCall = Call.Call
                    { Call._call_kind     = Call.CallMethod
                    , Call._call_path     = ["::np", "Calc"]
                    , Call._call_typeArgs = []
                    , Call._call_method   = Just "widen"
                    , Call._call_receiver = Just (Call.Receiver 0 Call.ByRef)
                    , Call._call_args     = [1, 2, 3]
                    , Call._call_argTypes = [ Call.TRCtor "::np::Calc" []
                                            , Call.TRPrim "usize"
                                            , Call.TRPrim "u32"
                                            , Call.TRPrim "f32" ]
                    , Call._call_ret      = Call.TRPrim "usize"
                    , Call._call_assocOnType = True
                    , Call._call_iterAdapters = []
                    , Call._call_traitQualifier = Just ("::np::Calc", "::np::Widen")
                    , Call._call_borrowAsRefArgs = []
                    , Call._call_isAsync = False
                    , Call._call_methodTurbofish = []
                    }
                src = okSrc (synthesiseGenericWrapper widenFn)
            -- params travel as the Sky CARRIER (i64/f64), NOT the foreign width.
            src `shouldContain` "arg1: i64, arg2: i64, arg3: f64"
            -- call site narrows each via the SATURATING numSaturate (no wraparound).
            src `shouldContain` "usize::try_from((arg1).max(0)).unwrap_or(usize::MAX)"
            src `shouldContain` "(arg2).clamp(0, u32::MAX as i64) as u32"
            src `shouldContain` "(arg3) as f32"
            -- usize RETURN: carrier-i64 wrapper type + C5 `__ret` bind + widen.
            src `shouldContain` "-> SkyResult<SkyError, i64>"
            src `shouldContain` "let __ret ="
            src `shouldContain` "ok_res((__ret).min(i64::MAX as usize) as i64)"
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

    describe "#28 closureDropReason (Task 3.3 — drop+report unsound closure shapes)" $ do
        it "drops an FnMut/FnOnce by-ref (&mut) slot: closure-mut-slot" $ do
            -- An FnMut/FnOnce + byRef means the host wants Fn{Mut,Once}(&mut T);
            -- the owned-clone bridge can't propagate mutations back, so it is
            -- unsound to bind — drop with a recorded reason.
            closureDropReason
                (Call.TRClosure Call.FnMutKind True [Call.TRParam 0] (Call.TRParam 0))
                `shouldBe` Just "closure-mut-slot"
            closureDropReason
                (Call.TRClosure Call.FnOnceKind True [Call.TRParam 0] (Call.TRParam 0))
                `shouldBe` Just "closure-mut-slot"
        it "drops a higher-order RETURN (closure returns a closure): closure-ho-return" $
            closureDropReason
                (Call.TRClosure Call.FnKind False [Call.TRParam 0]
                    (Call.TRClosure Call.FnKind False [Call.TRParam 1] (Call.TRPrim "bool")))
                `shouldBe` Just "closure-ho-return"
        it "drops a by-ref closure over a concrete non-Clone leaf: closure-by-ref-noclone" $
            -- a concrete foreign ctor with no provable Clone, borrowed → bridge
            -- can't clone it → drop.
            closureDropReason
                (Call.TRClosure Call.FnKind True [Call.TRCtor "::opaque::Handle" []] (Call.TRPrim "bool"))
                `shouldBe` Just "closure-by-ref-noclone"
        it "keeps a bindable by-value Fn(A) -> B: Nothing" $
            closureDropReason
                (Call.TRClosure Call.FnKind False [Call.TRParam 0] (Call.TRParam 1))
                `shouldBe` Nothing
        it "keeps a by-ref Fn(&A) over a generic param (the +Clone bound covers it): Nothing" $
            -- a TRParam borrowed arg is generic; the Fn/FnMut + Clone bound from
            -- closureBounds enforces Clone at instantiation, so it is NOT dropped.
            closureDropReason
                (Call.TRClosure Call.FnKind True [Call.TRParam 0] (Call.TRPrim "bool"))
                `shouldBe` Nothing
        it "keeps a by-ref Fn(&i64) over a Clone primitive: Nothing" $
            closureDropReason
                (Call.TRClosure Call.FnKind True [Call.TRPrim "i64"] (Call.TRPrim "bool"))
                `shouldBe` Nothing
        it "a non-closure TypeRef is never a closure drop: Nothing" $ do
            closureDropReason (Call.TRParam 0) `shouldBe` Nothing
            closureDropReason (Call.TRCtor "Vec" [Call.TRParam 0]) `shouldBe` Nothing

    describe "#28 closureSlotKinds (Task 4.1 — argTypes -> Map argIndex ClosureKind)" $ do
        -- A call AST with arg0 = Vec<a> (non-closure) and arg1 = Fn-closure:
        -- only index 1 maps to a ClosureKind; index 0 is absent.
        let twoArg k = Call.Call
                { Call._call_kind     = Call.CallFunction
                , Call._call_path     = ["::clo"]
                , Call._call_typeArgs = []
                , Call._call_method   = Just "map_each"
                , Call._call_receiver = Nothing
                , Call._call_args     = [0, 1]
                , Call._call_argTypes =
                    [ Call.TRCtor "Vec" [Call.TRParam 0]
                    , Call.TRClosure k False [Call.TRParam 0] (Call.TRParam 1) ]
                , Call._call_ret      = Call.TRCtor "Vec" [Call.TRParam 1]
                , Call._call_assocOnType = False
                , Call._call_iterAdapters = []
                , Call._call_traitQualifier = Nothing
                , Call._call_borrowAsRefArgs = []
                , Call._call_isAsync = False
                , Call._call_methodTurbofish = []
                }
        it "maps each closure-typed argTypes slot to its ClosureKind by index" $ do
            Call.closureSlotKinds (twoArg Call.FnKind)
                `shouldBe` Map.fromList [(1, Call.FnKind)]
            Call.closureSlotKinds (twoArg Call.FnOnceKind)
                `shouldBe` Map.fromList [(1, Call.FnOnceKind)]
        it "a call with no closure slots yields an empty map" $
            Call.closureSlotKinds makeCall `shouldBe` Map.empty

    describe "#28 gateClosureArg / gateClosureArgNames (Task 4.1 — capture gate)" $ do
        it "gate passes all-Clone captures, rejects a non-Clone capture (multi-call Fn)" $ do
            -- all-Clone capture (String) into a multi-call Fn slot → OK
            gateClosureArgNames Call.FnKind [("name", tStr)] `shouldBe` Nothing
            -- a Task-typed capture into a multi-call Fn slot → rejected, naming it
            gateClosureArgNames Call.FnKind [("task0", tTaskErrorUnit)]
                `shouldBe` Just ("task0", "Task Error ()")
            -- the SAME Task-typed capture into an FnOnce slot → OK (no gate)
            gateClosureArgNames Call.FnOnceKind [("task0", tTaskErrorUnit)] `shouldBe` Nothing
        it "gateClosureArg surfaces E4400 for a non-Clone capture in a multi-call slot" $ do
            case gateClosureArg Call.FnKind A.one "t.sky" [("task0", tTaskErrorUnit)] of
                Left d -> do
                    Diag._diag_code d `shouldBe` Diag.ffiE_GenericNotBindable
                    isInfixOf "must be Clone" (Diag._diag_message d) `shouldBe` True
                Right () -> expectationFailure "expected a Left E4400 diagnostic"
        it "gateClosureArg admits an all-Clone Fn slot and any FnOnce slot" $ do
            gateClosureArg Call.FnKind A.one "t.sky" [("name", tStr)] `shouldBe` Right ()
            gateClosureArg Call.FnMutKind A.one "t.sky" [("n", tInt)] `shouldBe` Right ()
            gateClosureArg Call.FnOnceKind A.one "t.sky" [("task0", tTaskErrorUnit)] `shouldBe` Right ()

    describe "#28 indirect-closure coverage drop (Task 4.2 — non-lambda closure arg)" $ do
        -- An FFI closure slot fed a value the gate can't inspect (a let-bound
        -- closure var, a fn returning a closure) is dropped with a recorded
        -- E4400 carrying the "closure-indirect-noanalysis" coverage marker.
        it "builds an E4400 naming the arg index + base name + coverage marker" $ do
            let d = mkIndirectClosureDropDiag A.one "app.sky" "clo_map_each" 1
            Diag._diag_code d `shouldBe` Diag.ffiE_GenericNotBindable
            isInfixOf "closure-indirect-noanalysis" (Diag._diag_message d) `shouldBe` True
            isInfixOf "clo_map_each" (Diag._diag_message d) `shouldBe` True
            isInfixOf "1" (Diag._diag_message d) `shouldBe` True

    describe "#28 closure wrapper synthesis (Task 3.1 — B1/B2 catch_unwind boundary)" $ do
        -- `map_each : List a -> (a -> b) -> List b` over two real params ["a","b"].
        -- arg0 is the Vec<a>; arg1 is the closure (an owned `Fn(A) -> B`).
        let mapEachFn = GenericFn
                { _gf_kernelName = "Rust_Clo"
                , _gf_baseName   = "rust_clo_map_each"
                , _gf_refName    = "mapEach"
                , _gf_generic    = mkGen ["a", "b"] [] mapEachCall
                , _gf_region     = A.one
                , _gf_file       = "T.sky"
                }
            mapEachCall = Call.Call
                { Call._call_kind     = Call.CallFunction
                , Call._call_path     = ["::clo"]
                , Call._call_typeArgs = [Call.TRParam 0, Call.TRParam 1]
                , Call._call_method   = Just "map_each"
                , Call._call_receiver = Nothing
                , Call._call_args     = [0, 1]
                , Call._call_argTypes =
                    [ Call.TRCtor "Vec" [Call.TRParam 0]
                    , Call.TRClosure Call.FnKind False
                        [Call.TRParam 0] (Call.TRParam 1) ]
                , Call._call_ret      = Call.TRCtor "Vec" [Call.TRParam 1]
                , Call._call_assocOnType = False
                , Call._call_iterAdapters = []
                , Call._call_traitQualifier = Nothing
                , Call._call_borrowAsRefArgs = []
                , Call._call_isAsync = False
                , Call._call_methodTurbofish = []
                }
            okSrc' r = case r of WrapperOk _ _ s -> s; _ -> ""
        it "carries the <Fj: Fn(..) -> R + Clone> bound in the generics clause" $ do
            let src = okSrc' (synthesiseGenericWrapper mapEachFn)
            src `shouldContain` "F1: Fn(A) -> B + ::core::clone::Clone"
        it "uses Fj as the closure param's Rust type (not F?)" $ do
            let src = okSrc' (synthesiseGenericWrapper mapEachFn)
            src `shouldContain` "arg1: F1"
            isInfixOf "F?" src `shouldBe` False
        it "wraps the host call in catch_unwind + AssertUnwindSafe" $ do
            let src = okSrc' (synthesiseGenericWrapper mapEachFn)
            isInfixOf "::std::panic::catch_unwind" src `shouldBe` True
            isInfixOf "::std::panic::AssertUnwindSafe" src `shouldBe` True
        it "maps the panic Err arm to a SkyError (no .unwrap / panic! in output)" $ do
            let src = okSrc' (synthesiseGenericWrapper mapEachFn)
            isInfixOf "a Sky closure passed to FFI panicked" src `shouldBe` True
            isInfixOf ".unwrap()" src `shouldBe` False
            isInfixOf "panic!" src `shouldBe` False
        it "B2: catch_unwind requires a panic=unwind cargo profile (guard)" $ do
            -- The emitted profile (Emitter.hs) sets no `panic =`, so cargo
            -- defaults to "unwind" — the catch_unwind in the closure wrapper is
            -- live. This guard rejects a profile that flips to `panic = "abort"`
            -- (which would silently turn catch_unwind into an abort, defeating
            -- the boundary). Whitespace / quote-style tolerant.
            cargoProfilePanicIsUnwind
                "[profile.dev]\ndebug = 0\noverflow-checks = false\n"
                `shouldBe` True
            cargoProfilePanicIsUnwind
                "[profile.release]\nstrip = true\n" `shouldBe` True
            cargoProfilePanicIsUnwind
                "[profile.release]\npanic = \"abort\"\n" `shouldBe` False
            cargoProfilePanicIsUnwind
                "[profile.dev]\npanic='abort'\n" `shouldBe` False
            cargoProfilePanicIsUnwind
                "[profile.release]\npanic = \"unwind\"\n" `shouldBe` True
        it "a closure-free fn keeps the plain ok_res body (no catch_unwind)" $ do
            -- regression: the non-closure path must be byte-identical (no spurious
            -- catch_unwind wrap on a wrapper with no closure arg).
            let plain = GenericFn
                    { _gf_kernelName = "Rust_Box1"
                    , _gf_baseName   = "rust_box1_make"
                    , _gf_refName    = "make"
                    , _gf_generic    = mkGen ["a"] [] makeCall
                    , _gf_region     = A.one
                    , _gf_file       = "T.sky"
                    }
                src = okSrc' (synthesiseGenericWrapper plain)
            src `shouldContain` "ok_res(::box1::Box1::<A>::make(arg0))"
            isInfixOf "catch_unwind" src `shouldBe` False

    describe "#28 by-ref closure params force +Clone on the borrowed param (guardian-final E0308 hole)" $ do
        -- `keep : List a -> (a -> Bool) -> List a` over ONE param ["a"]. arg0 is
        -- the Vec<a>; arg1 is a BY-REF closure `Fn(&A) -> bool`. The owned-clone
        -- bridge emits `__r0.clone()` on `&A`, which needs `A: Clone` IN THE
        -- WRAPPER'S bounds — even when the host fn (filter-only) declares no
        -- `A: Clone`.
        let keepCall = Call.Call
                { Call._call_kind     = Call.CallFunction
                , Call._call_path     = ["::clo"]
                , Call._call_typeArgs = [Call.TRParam 0]
                , Call._call_method   = Just "keep"
                , Call._call_receiver = Nothing
                , Call._call_args     = [0, 1]
                , Call._call_argTypes =
                    [ Call.TRCtor "Vec" [Call.TRParam 0]
                    , Call.TRClosure Call.FnKind True
                        [Call.TRParam 0] (Call.TRPrim "bool") ]
                , Call._call_ret      = Call.TRCtor "Vec" [Call.TRParam 0]
                , Call._call_assocOnType = False
                , Call._call_iterAdapters = []
                , Call._call_traitQualifier = Nothing
                , Call._call_borrowAsRefArgs = []
                , Call._call_isAsync = False
                , Call._call_methodTurbofish = []
                }
            mkKeepFn bs = GenericFn
                { _gf_kernelName = "Rust_Clo"
                , _gf_baseName   = "rust_clo_keep"
                , _gf_refName    = "keep"
                , _gf_generic    = mkGen ["a"] bs keepCall
                , _gf_region     = A.one
                , _gf_file       = "T.sky"
                }
            okSrcK r = case r of WrapperOk _ _ s -> s; _ -> ""
        it "forces A: ::core::clone::Clone onto the borrowed param when source bounds are EMPTY" $ do
            let src = okSrcK (synthesiseGenericWrapper (mkKeepFn []))
            -- The named param `A` must carry the forced Clone bound (so the
            -- bridge's `__r0.clone()` resolves to owned `A`, not `&A`).
            src `shouldContain` "A: ::core::clone::Clone"
        it "does NOT double-emit Clone when the source already declares A: Clone (dedupe)" $ do
            let src = okSrcK (synthesiseGenericWrapper (mkKeepFn [("a", ["Clone"])]))
            -- Exactly one Clone path on A — never `Clone + Clone` / a duplicate.
            src `shouldContain` "A: ::core::clone::Clone"
            isInfixOf "Clone + ::core::clone::Clone" src `shouldBe` False
            isInfixOf "::core::clone::Clone + ::core::clone::Clone" src `shouldBe` False
        it "merges the forced Clone after a pre-existing modellable bound (Hash) without dropping it" $ do
            let src = okSrcK (synthesiseGenericWrapper (mkKeepFn [("a", ["Hash"])]))
            src `shouldContain` "::std::hash::Hash"
            src `shouldContain` "::core::clone::Clone"
        it "leaves a by-VALUE closure param untouched (no spurious Clone force)" $ do
            -- map_each's closure is by-VALUE (byRef=False), so its arg is MOVED in,
            -- not cloned — the param must NOT pick up a forced Clone.
            let byValCall = keepCall
                    { Call._call_argTypes =
                        [ Call.TRCtor "Vec" [Call.TRParam 0]
                        , Call.TRClosure Call.FnKind False
                            [Call.TRParam 0] (Call.TRPrim "bool") ] }
                fn = (mkKeepFn []) { _gf_generic = mkGen ["a"] [] byValCall }
                src = okSrcK (synthesiseGenericWrapper fn)
            -- The param `A` appears bare in the generics clause (no Clone forced).
            isInfixOf "A: ::core::clone::Clone" src `shouldBe` False

  where
    isLeft (Left _)  = True
    isLeft (Right _) = False
