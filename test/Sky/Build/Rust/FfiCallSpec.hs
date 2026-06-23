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
                    }
            renderCall c ["k", "v"] `shouldBe`
                "::mycrate::Pair::<K, V>::left(&arg0)"
            renderRetType c ["k", "v"] `shouldBe` "K"
  where
    isLeft  = either (const True) (const False)
    isRight = either (const False) (const True)
    isLeft' :: Either String Call -> Bool
    isLeft' = either (const True) (const False)
