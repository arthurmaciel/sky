{-# LANGUAGE OverloadedStrings #-}
-- | Wall #3 drift + validation fences for the Scheme-A typed call-AST.
--
--   * 4b (the Call schema) — a round-trip corpus: a fixed set of @call@ JSON
--     objects decode (via the SAME 'FfiCall.parseCall' the registry uses) to
--     the EXPECTED ADT, PLUS negative cases (unknown @kind@/@by@, out-of-range
--     @{param}@, missing required field, duplicate / gapped arg refs) that the
--     Haskell decoder REJECTS — never silently defaults. If either side drifts
--     (the inspector emits a shape the decoder accepts-but-mis-reads, or
--     rejects a shape the inspector emits), one of these fails.
--   * #2 (parse-time validity) — 'FfiCall.validateCall' is the structural gate
--     that replaced the retired @{hole}@ contiguity check; every param/arg ref
--     bound + the receiver-iff-method rule is proven here directly.
--
-- The 4a (modellable-5) drift fence lives in 'FfiInstanceSpec' (it asserts the
-- Haskell 'modellableTrait' set; the inspector-side equality is a Rust unit
-- test in the inspector crate — see tools/sky-ffi-inspect-rs MODELLABLE_5).
module Sky.Build.Rust.FfiCallSpec (spec) where

import Test.Hspec

import qualified Data.Aeson as A
import qualified Data.Aeson.Types as AT
import Data.List (isInfixOf)

import Sky.Build.Rust.FfiCall


-- | Decode a @call@ JSON value against @nParams@ via the registry's parser.
decodeCall :: Int -> A.Value -> Either String Call
decodeCall nParams v = AT.parseEither (parseCall nParams) v


spec :: Spec
spec = do
    describe "Call round-trip corpus (drift 4b — positive)" $ do
        it "decodes a static ctor `make : a -> Box1 a`" $ do
            let j = A.object
                    [ "kind"     A..= ("function" :: String)
                    , "path"     A..= (["::box1", "Box1"] :: [String])
                    , "typeArgs" A..= [A.object ["param" A..= (0 :: Int)]]
                    , "method"   A..= ("make" :: String)
                    , "args"     A..= ([0] :: [Int])
                    , "argTypes" A..= [A.object ["param" A..= (0 :: Int)]]
                    , "ret"      A..= A.object
                        [ "ctor" A..= ("::box1::Box1" :: String)
                        , "args" A..= [A.object ["param" A..= (0 :: Int)]] ]
                    ]
            decodeCall 1 j `shouldBe` Right Call
                { _call_kind     = CallFunction
                , _call_path     = ["::box1", "Box1"]
                , _call_typeArgs = [TRParam 0]
                , _call_method   = Just "make"
                , _call_receiver = Nothing
                , _call_args     = [0]
                , _call_argTypes = [TRParam 0]
                , _call_ret      = TRCtor "::box1::Box1" [TRParam 0]
                , _call_assocOnType = True
                , _call_iterAdapters = []
                , _call_traitQualifier = Nothing
                }
        it "decodes a method call with a ref receiver `left : Pair a b -> a`" $ do
            let j = A.object
                    [ "kind"     A..= ("method" :: String)
                    , "path"     A..= (["::mycrate", "Pair"] :: [String])
                    , "typeArgs" A..= [ A.object ["param" A..= (0 :: Int)]
                                      , A.object ["param" A..= (1 :: Int)] ]
                    , "method"   A..= ("left" :: String)
                    , "receiver" A..= A.object
                        [ "arg" A..= (0 :: Int), "by" A..= ("ref" :: String) ]
                    , "args"     A..= ([] :: [Int])
                    , "argTypes" A..= [ A.object
                        [ "ctor" A..= ("::mycrate::Pair" :: String)
                        , "args" A..= [ A.object ["param" A..= (0 :: Int)]
                                      , A.object ["param" A..= (1 :: Int)] ] ] ]
                    , "ret"      A..= A.object ["param" A..= (0 :: Int)]
                    ]
            decodeCall 2 j `shouldBe` Right Call
                { _call_kind     = CallMethod
                , _call_path     = ["::mycrate", "Pair"]
                , _call_typeArgs = [TRParam 0, TRParam 1]
                , _call_method   = Just "left"
                , _call_receiver = Just (Receiver 0 ByRef)
                , _call_args     = []
                , _call_argTypes = [TRCtor "::mycrate::Pair" [TRParam 0, TRParam 1]]
                , _call_ret      = TRParam 0
                , _call_assocOnType = True
                , _call_iterAdapters = []
                , _call_traitQualifier = Nothing
                }
        it "decodes a prim TypeRef leaf in ret (`count : Keyed a -> Int`)" $ do
            let j = A.object
                    [ "kind"     A..= ("function" :: String)
                    , "path"     A..= (["::box1", "Keyed"] :: [String])
                    , "typeArgs" A..= [A.object ["param" A..= (0 :: Int)]]
                    , "method"   A..= ("count" :: String)
                    , "args"     A..= ([0] :: [Int])
                    , "argTypes" A..= [A.object
                        [ "ctor" A..= ("::box1::Keyed" :: String)
                        , "args" A..= [A.object ["param" A..= (0 :: Int)]] ]]
                    , "ret"      A..= A.object ["prim" A..= ("i64" :: String)]
                    ]
            (_call_ret <$> decodeCall 1 j) `shouldBe` Right (TRPrim "i64")

    describe "Call negative cases (drift 4b — REJECT, never default)" $ do
        let baseObj extra = A.object
                ([ "kind"     A..= ("function" :: String)
                 , "path"     A..= (["::c", "T"] :: [String])
                 , "args"     A..= ([0] :: [Int])
                 , "argTypes" A..= [A.object ["param" A..= (0 :: Int)]]
                 , "ret"      A..= A.object ["param" A..= (0 :: Int)]
                 ] ++ extra)
        it "rejects an unknown `kind`" $ do
            let j = baseObj ["kind" A..= ("staticmethod" :: String)]
            decodeCall 1 j `shouldSatisfy` isLeft
        it "rejects an unknown receiver `by`" $ do
            let j = A.object
                    [ "kind"     A..= ("method" :: String)
                    , "path"     A..= (["::c", "T"] :: [String])
                    , "method"   A..= ("m" :: String)
                    , "receiver" A..= A.object
                        [ "arg" A..= (0 :: Int), "by" A..= ("borrow" :: String) ]
                    , "args"     A..= ([] :: [Int])
                    , "argTypes" A..= [A.object ["param" A..= (0 :: Int)]]
                    , "ret"      A..= A.object ["param" A..= (0 :: Int)]
                    ]
            decodeCall 1 j `shouldSatisfy` isLeft
        it "rejects an out-of-range {param} index" $ do
            -- nParams = 1, but ret references {param:5}.
            let j = A.object
                    [ "kind"     A..= ("function" :: String)
                    , "path"     A..= (["::c", "T"] :: [String])
                    , "method"   A..= ("m" :: String)
                    , "args"     A..= ([0] :: [Int])
                    , "argTypes" A..= [A.object ["param" A..= (0 :: Int)]]
                    , "ret"      A..= A.object ["param" A..= (5 :: Int)]
                    ]
            decodeCall 1 j `shouldSatisfy` isLeft
        it "rejects a missing required field (`ret`)" $ do
            let j = A.object
                    [ "kind"     A..= ("function" :: String)
                    , "path"     A..= (["::c", "T"] :: [String])
                    , "args"     A..= ([0] :: [Int])
                    , "argTypes" A..= [A.object ["param" A..= (0 :: Int)]]
                    ]
            decodeCall 1 j `shouldSatisfy` isLeft
        it "rejects a method with no receiver (receiver-iff-method)" $ do
            let j = A.object
                    [ "kind"     A..= ("method" :: String)
                    , "path"     A..= (["::c", "T"] :: [String])
                    , "method"   A..= ("m" :: String)
                    , "args"     A..= ([0] :: [Int])
                    , "argTypes" A..= [A.object ["param" A..= (0 :: Int)]]
                    , "ret"      A..= A.object ["param" A..= (0 :: Int)]
                    ]
            decodeCall 1 j `shouldSatisfy` isLeft
        it "rejects a function carrying a receiver (receiver-iff-method)" $ do
            let j = baseObj
                    [ "receiver" A..= A.object
                        [ "arg" A..= (0 :: Int), "by" A..= ("ref" :: String) ] ]
            decodeCall 1 j `shouldSatisfy` isLeft
        it "rejects a gapped arg index ({arg0}+{arg2}, no {arg1})" $ do
            let j = A.object
                    [ "kind"     A..= ("function" :: String)
                    , "path"     A..= (["::c", "g"] :: [String])
                    , "args"     A..= ([0, 2] :: [Int])
                    , "argTypes" A..= [ A.object ["param" A..= (0 :: Int)]
                                      , A.object ["param" A..= (0 :: Int)] ]
                    , "ret"      A..= A.object ["prim" A..= ("i64" :: String)]
                    ]
            decodeCall 1 j `shouldSatisfy` isLeft
        it "rejects argTypes whose length ≠ arity" $ do
            let j = A.object
                    [ "kind"     A..= ("function" :: String)
                    , "path"     A..= (["::c", "g"] :: [String])
                    , "args"     A..= ([0] :: [Int])
                    , "argTypes" A..= ([] :: [A.Value])   -- arity 1, 0 types
                    , "ret"      A..= A.object ["prim" A..= ("i64" :: String)]
                    ]
            decodeCall 1 j `shouldSatisfy` isLeft
        it "rejects a TypeRef with two discriminators (param + prim)" $ do
            let j = A.object
                    [ "kind"     A..= ("function" :: String)
                    , "path"     A..= (["::c", "g"] :: [String])
                    , "args"     A..= ([0] :: [Int])
                    , "argTypes" A..= [A.object ["param" A..= (0 :: Int)]]
                    , "ret"      A..= A.object
                        [ "param" A..= (0 :: Int), "prim" A..= ("i64" :: String) ]
                    ]
            decodeCall 1 j `shouldSatisfy` isLeft

    describe "validateCall (#2 — structural validity, post-decode)" $ do
        let okCall = Call
                { _call_kind     = CallFunction
                , _call_path     = ["::c", "T"]
                , _call_typeArgs = [TRParam 0]
                , _call_method   = Just "make"
                , _call_receiver = Nothing
                , _call_args     = [0]
                , _call_argTypes = [TRParam 0]
                , _call_ret      = TRCtor "::c::T" [TRParam 0]
                , _call_assocOnType = True
                , _call_iterAdapters = []
                , _call_traitQualifier = Nothing
                }
        it "accepts a valid single-param call" $
            validateCall 1 okCall `shouldSatisfy` isRight
        it "rejects a param ref ≥ nParams" $
            validateCall 0 okCall `shouldSatisfy` isLeft'
        it "rejects a method missing its receiver" $
            validateCall 1 okCall { _call_kind = CallMethod }
                `shouldSatisfy` isLeft'
        it "callArity counts receiver + args" $ do
            callArity okCall `shouldBe` 1
            callArity okCall { _call_receiver = Just (Receiver 1 ByValue)
                             , _call_args = [0]
                             , _call_argTypes = [TRParam 0, TRParam 0] }
                `shouldBe` 2

    describe "#28 — TRClosure variant" $ do
        it "#28: decodes a closure argType" $ do
            let j = "{\"closure\":{\"kind\":\"Fn\",\"byRef\":false,\
                    \\"argTypes\":[{\"param\":0}],\"ret\":{\"param\":1}}}"
            (A.decode j :: Maybe TypeRef) `shouldBe`
                Just (TRClosure FnKind False [TRParam 0] (TRParam 1))
        it "#28: closureBounds renders a multi-call Fn closure param as <Fj: Fn(..)+Clone>" $ do
            let call = Call
                    { _call_kind     = CallFunction
                    , _call_path     = ["::clo"]
                    , _call_typeArgs = [TRParam 0, TRParam 1]
                    , _call_method   = Just "map_each"
                    , _call_receiver = Nothing
                    , _call_args     = [0, 1]
                    , _call_argTypes =
                        [ TRCtor "Vec" [TRParam 0]
                        , TRClosure FnKind False [TRParam 0] (TRParam 1) ]
                    , _call_ret      = TRCtor "Vec" [TRParam 1]
                    , _call_assocOnType = False
                    , _call_iterAdapters = []
                    , _call_traitQualifier = Nothing
                    }
            -- C-A: real params ["a","b"] → TRParam 0 → A, TRParam 1 → B
            closureBounds call ["a", "b"] `shouldBe` ["F1: Fn(A) -> B + ::core::clone::Clone"]
        it "#28: rejects a closure nested inside a container (Vec<closure>)" $ do
            let call = Call
                    { _call_kind     = CallFunction
                    , _call_path     = ["::clo"]
                    , _call_typeArgs = [TRParam 0]
                    , _call_method   = Nothing
                    , _call_receiver = Nothing
                    , _call_args     = [0]
                    , _call_argTypes =
                        [ TRCtor "Vec"
                            [TRClosure FnKind False [TRParam 0] (TRPrim "bool")] ]
                    , _call_ret      = TRPrim "i64"
                    , _call_assocOnType = False
                    , _call_iterAdapters = []
                    , _call_traitQualifier = Nothing
                    }
            -- C-B: a closure nested inside Vec<_> must be rejected by validateCall
            isLeft (validateCall 1 call) `shouldBe` True

    describe "renderCall / renderRetType (total over a validated Call)" $ do
        it "renders a static ctor body + ret + arg type" $ do
            let c = Call
                    { _call_kind     = CallFunction
                    , _call_path     = ["::box1", "Box1"]
                    , _call_typeArgs = [TRParam 0]
                    , _call_method   = Just "make"
                    , _call_receiver = Nothing
                    , _call_args     = [0]
                    , _call_argTypes = [TRParam 0]
                    , _call_ret      = TRCtor "::box1::Box1" [TRParam 0]
                    , _call_assocOnType = True
                    , _call_iterAdapters = []
                    , _call_traitQualifier = Nothing
                    }
            renderCall c ["a"]    `shouldBe` "::box1::Box1::<A>::make(arg0)"
            renderRetType c ["a"] `shouldBe` "::box1::Box1<A>"
            renderArgType c ["a"] 0 `shouldBe` "A"
        it "renders a method body with a &receiver" $ do
            let c = Call
                    { _call_kind     = CallMethod
                    , _call_path     = ["::mycrate", "Pair"]
                    , _call_typeArgs = [TRParam 0, TRParam 1]
                    , _call_method   = Just "left"
                    , _call_receiver = Just (Receiver 0 ByRef)
                    , _call_args     = []
                    , _call_argTypes = [TRCtor "::mycrate::Pair" [TRParam 0, TRParam 1]]
                    , _call_ret      = TRParam 0
                    , _call_assocOnType = True
                    , _call_iterAdapters = []
                    , _call_traitQualifier = Nothing
                    }
            renderCall c ["k", "v"] `shouldBe`
                "::mycrate::Pair::<K, V>::left(&arg0)"
            renderRetType c ["k", "v"] `shouldBe` "K"
        it "renders a FREE crate function with NO turbofish (assocOnType=False)" $ do
            -- `map_each : List a -> (a -> b) -> Result Error (List b)` from a
            -- crate-level free fn `map_each<A, B, F: Fn(A) -> B>`. The closure
            -- type-param `F` is NOT in the kernel.json typeArgs, so a partial
            -- `::<A, B>` is an arity error (E0107) and a turbofish on the crate
            -- path is E0109 — the only sound form omits the turbofish and lets
            -- Rust infer A from `arg0: Vec<A>`, F from `arg1`, B from F's return.
            let c = Call
                    { _call_kind     = CallFunction
                    , _call_path     = ["::clo"]
                    , _call_typeArgs = [TRParam 0, TRParam 1]
                    , _call_method   = Just "map_each"
                    , _call_receiver = Nothing
                    , _call_args     = [0, 1]
                    , _call_argTypes =
                        [ TRCtor "Vec" [TRParam 0]
                        , TRClosure FnKind False [TRParam 0] (TRParam 1) ]
                    , _call_ret      = TRCtor "Vec" [TRParam 1]
                    , _call_assocOnType = False
                    , _call_iterAdapters = []
                    , _call_traitQualifier = Nothing
                    }
            renderCall c ["a", "b"] `shouldBe`
                "::clo::map_each(arg0, arg1)"

    describe "#30 — iterator param call form (Iterator → arg.into_iter())" $ do
        -- `sum_all<I: IntoIterator<Item=i64>>(xs: I) -> i64` — the Vec arg passes
        -- DIRECTLY (a Vec IS IntoIterator); no adapter. `count<I: Iterator<Item=
        -- i64>>(it: I)` — the Vec is not itself an Iterator, so the call site
        -- must pass `arg0.into_iter()` (the adapter at arg index 0).
        let iterCall adapters = Call
                { _call_kind     = CallFunction
                , _call_path     = ["::iter"]
                , _call_typeArgs = []
                , _call_method   = Just "go"
                , _call_receiver = Nothing
                , _call_args     = [0]
                , _call_argTypes = [TRCtor "Vec" [TRPrim "i64"]]
                , _call_ret      = TRPrim "i64"
                , _call_assocOnType = False
                , _call_iterAdapters = adapters
                , _call_traitQualifier = Nothing
                }
        it "an Iterator-kind arg (in iterAdapters) renders arg0.into_iter()" $
            renderCall (iterCall [0]) [] `shouldBe` "::iter::go(arg0.into_iter())"
        it "an IntoIterator-kind arg (empty iterAdapters) renders the bare arg0" $ do
            let rendered = renderCall (iterCall []) []
            rendered `shouldBe` "::iter::go(arg0)"
            (".into_iter()" `isInfixOf` rendered) `shouldBe` False
        it "only the tagged index gets the adapter (arg1 tagged, arg0 bare)" $ do
            let c = Call
                    { _call_kind     = CallFunction
                    , _call_path     = ["::iter"]
                    , _call_typeArgs = []
                    , _call_method   = Just "zip2"
                    , _call_receiver = Nothing
                    , _call_args     = [0, 1]
                    , _call_argTypes = [TRCtor "Vec" [TRPrim "i64"], TRCtor "Vec" [TRPrim "i64"]]
                    , _call_ret      = TRPrim "i64"
                    , _call_assocOnType = False
                    , _call_iterAdapters = [1]
                    , _call_traitQualifier = Nothing
                    }
            renderCall c [] `shouldBe` "::iter::zip2(arg0, arg1.into_iter())"
        it "validateCall REJECTS an out-of-range iterAdapters index" $ do
            let bad = Call
                    { _call_kind     = CallFunction
                    , _call_path     = ["::iter"]
                    , _call_typeArgs = []
                    , _call_method   = Just "go"
                    , _call_receiver = Nothing
                    , _call_args     = [0]
                    , _call_argTypes = [TRCtor "::Vec" [TRPrim "i64"]]
                    , _call_ret      = TRPrim "i64"
                    , _call_assocOnType = False
                    , _call_iterAdapters = [3]   -- arity is 1 → out of range
                    , _call_traitQualifier = Nothing
                    }
            isLeft' (validateCall 0 bad) `shouldBe` True
        it "validateCall REJECTS an iterAdapters index on a non-Vec arg" $ do
            let bad = Call
                    { _call_kind     = CallFunction
                    , _call_path     = ["::iter"]
                    , _call_typeArgs = []
                    , _call_method   = Just "go"
                    , _call_receiver = Nothing
                    , _call_args     = [0]
                    , _call_argTypes = [TRPrim "i64"]   -- not a Vec — .into_iter() unsound
                    , _call_ret      = TRPrim "i64"
                    , _call_assocOnType = False
                    , _call_iterAdapters = [0]
                    , _call_traitQualifier = Nothing
                    }
            isLeft' (validateCall 0 bad) `shouldBe` True
        it "validateCall ACCEPTS a well-formed iterAdapters index on a Vec arg" $ do
            let ok = Call
                    { _call_kind     = CallFunction
                    , _call_path     = ["::iter"]
                    , _call_typeArgs = []
                    , _call_method   = Just "go"
                    , _call_receiver = Nothing
                    , _call_args     = [0]
                    , _call_argTypes = [TRCtor "::Vec" [TRPrim "i64"]]
                    , _call_ret      = TRPrim "i64"
                    , _call_assocOnType = False
                    , _call_iterAdapters = [0]
                    , _call_traitQualifier = Nothing
                    }
            isRight (validateCall 0 ok) `shouldBe` True

    describe "#28 — owned-clone bridge for Fn(&A) closure params (Task 3.2, B4)" $ do
        -- `keep : List a -> (&a -> Bool) -> List a` — the host wants Fn(&A) but
        -- the Sky closure (arg1) only ever sees an OWNED value. The bridge clones
        -- the borrowed arg to owned before invoking arg1, so a reference can
        -- never escape into Sky (B4 invariant — identity-escape impossible).
        let keepCall byRef = Call
                { _call_kind     = CallFunction
                , _call_path     = ["::clo"]
                , _call_typeArgs = [TRParam 0]
                , _call_method   = Just "keep"
                , _call_receiver = Nothing
                , _call_args     = [0, 1]
                , _call_argTypes =
                    [ TRCtor "Vec" [TRParam 0]
                    , TRClosure FnKind byRef [TRParam 0] (TRPrim "bool") ]
                , _call_ret      = TRCtor "Vec" [TRParam 0]
                , _call_assocOnType = False
                , _call_iterAdapters = []
                , _call_traitQualifier = Nothing
                }
        it "byRef closure arg passes an owned-clone bridge, not arg1 directly" $
            renderCall (keepCall True) ["a"] `shouldContain`
                "move |__r0| { let __v0 = __r0.clone(); arg1(__v0) }"
        it "a by-value (byRef=False) closure arg passes arg1 directly (no bridge)" $ do
            let rendered = renderCall (keepCall False) ["a"]
            rendered `shouldContain` "(arg0, arg1)"
            (".clone()" `isInfixOf` rendered) `shouldBe` False
        it "multi-& Fn(&A, &B) clones each borrowed arg independently" $ do
            let zipCall = Call
                    { _call_kind     = CallFunction
                    , _call_path     = ["::clo"]
                    , _call_typeArgs = [TRParam 0, TRParam 1]
                    , _call_method   = Just "zip_with"
                    , _call_receiver = Nothing
                    , _call_args     = [0]
                    , _call_argTypes =
                        [ TRClosure FnKind True
                            [TRParam 0, TRParam 1] (TRParam 0) ]
                    , _call_ret      = TRParam 0
                    , _call_assocOnType = False
                    , _call_iterAdapters = []
                    , _call_traitQualifier = Nothing
                    }
            renderCall zipCall ["a", "b"] `shouldContain`
                "move |__r0, __r1| { let __v0 = __r0.clone(); \
                \let __v1 = __r1.clone(); arg0(__v0, __v1) }"

    describe "#21 — UFCS trait-method qualifier (call-path, #25)" $ do
        let keyedJson = A.object
                [ "kind"     A..= ("method" :: String)
                , "path"     A..= (["::tm", "Circle"] :: [String])
                , "method"   A..= ("keyed" :: String)
                , "receiver" A..= A.object
                    [ "arg" A..= (0 :: Int), "by" A..= ("ref" :: String) ]
                , "args"     A..= ([1] :: [Int])
                , "argTypes" A..=
                    [ A.object ["ctor" A..= ("::tm::Circle" :: String)]
                    , A.object ["param" A..= (0 :: Int)] ]
                , "ret"      A..= A.object ["prim" A..= ("i64" :: String)]
                , "traitQualifier" A..=
                    (["::tm::Circle", "::tm::Scale"] :: [String])
                ]
        it "decodes the traitQualifier into _call_traitQualifier" $ do
            (_call_traitQualifier <$> decodeCall 1 keyedJson)
                `shouldBe` Right (Just ("::tm::Circle", "::tm::Scale"))
        it "renders the UFCS callee `<Self as Trait>::method` (not path::method)" $ do
            case decodeCall 1 keyedJson of
                Left e  -> expectationFailure ("decode failed: " ++ e)
                Right c -> do
                    let r = renderCall c ["T"]
                    r `shouldBe` "<::tm::Circle as ::tm::Scale>::keyed(&arg0, arg1)"
                    ("::tm::Circle::keyed" `isInfixOf` r) `shouldBe` False
        it "a trait method OMITS the method turbofish (type-params inferred)" $ do
            let withTArgs = A.object
                    [ "kind"     A..= ("method" :: String)
                    , "path"     A..= (["::tm", "Circle"] :: [String])
                    , "typeArgs" A..= [A.object ["param" A..= (0 :: Int)]]
                    , "method"   A..= ("keyed" :: String)
                    , "receiver" A..= A.object
                        [ "arg" A..= (0 :: Int), "by" A..= ("ref" :: String) ]
                    , "args"     A..= ([1] :: [Int])
                    , "argTypes" A..=
                        [ A.object ["ctor" A..= ("::tm::Circle" :: String)]
                        , A.object ["param" A..= (0 :: Int)] ]
                    , "ret"      A..= A.object ["prim" A..= ("i64" :: String)]
                    , "traitQualifier" A..=
                        (["::tm::Circle", "::tm::Scale"] :: [String])
                    ]
            case decodeCall 1 withTArgs of
                Left e  -> expectationFailure ("decode failed: " ++ e)
                Right c -> ("::<" `isInfixOf` renderCall c ["T"]) `shouldBe` False
        it "Nothing traitQualifier renders the historical inherent callee" $ do
            let inherentJson = A.object
                    [ "kind"     A..= ("function" :: String)
                    , "path"     A..= (["::box1", "Box1"] :: [String])
                    , "typeArgs" A..= [A.object ["param" A..= (0 :: Int)]]
                    , "method"   A..= ("make" :: String)
                    , "args"     A..= ([0] :: [Int])
                    , "argTypes" A..= [A.object ["param" A..= (0 :: Int)]]
                    , "ret"      A..= A.object ["param" A..= (0 :: Int)]
                    ]
            case decodeCall 1 inherentJson of
                Left e  -> expectationFailure ("decode failed: " ++ e)
                Right c -> do
                    _call_traitQualifier c `shouldBe` Nothing
                    renderCall c ["A"] `shouldBe` "::box1::Box1::<A>::make(arg0)"
  where
    isLeft  = either (const True) (const False)
    isRight = either (const False) (const True)
    isLeft' :: Either String Call -> Bool
    isLeft' = either (const True) (const False)
