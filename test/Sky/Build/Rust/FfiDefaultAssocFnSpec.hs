{-# LANGUAGE OverloadedStrings #-}

-- | WALL-D regression: a trait associated function with NO @self@ receiver
-- (the canonical @Default::default()@ shape) must NOT get a flat-field
-- @_bindings.rs@ wrapper — its only correct render is the UFCS
-- @\<Self as Trait\>::default()@ emitted from the @generic.call@ AST into
-- @sky_ffi_generics.rs@. The flat-field path would emit a non-existent free
-- function @::crate::default()@ (E0425) AND duplicate the generics-path
-- definition (E0659).
--
-- The skip is driven by 'genericHasTraitQualifier': a fn whose inspector
-- @generic@ block carries a two-element @[selfPath, traitPath]@
-- @traitQualifier@ is owned by the UFCS path, so @emitRustFnSimple@ emits
-- nothing for it. This spec proves the predicate fires for the trait-fn shapes
-- (with AND without a @self@ param, with AND without args) and stays @False@
-- for an inherent generic method (no qualifier) and a non-generic fn.
module Sky.Build.Rust.FfiDefaultAssocFnSpec (spec) where

import Test.Hspec

import qualified Data.Aeson as A

import Sky.Build.FfiGen (FnInfo)
import Sky.Build.Rust.Ffi (genericHasTraitQualifier)

-- | Decode an 'FnInfo' from a minimal JSON object (the FromJSON instance fills
-- every optional field with its default). @name@/@params@/@results@/@effect@
-- are the only mandatory keys. A decode failure @error@s loudly (the literal is
-- a test fixture, not external input).
fnFromJson :: A.Value -> FnInfo
fnFromJson v = case A.fromJSON v of
    A.Success a -> a
    A.Error e   -> error ("FfiDefaultAssocFnSpec fixture decode failed: " ++ e)

-- A no-self, no-arg trait assoc fn (`Default::default`): the WALL-D target.
defaultFn :: FnInfo
defaultFn = fnFromJson $ A.object
    [ "name"    A..= ("default" :: String)
    , "params"  A..= ([] :: [A.Value])
    , "results" A..= [ A.object [ "type" A..= ("Cfg" :: String) ] ]
    , "effect"  A..= ("pure" :: String)
    , "generic" A..= A.object
        [ "params" A..= ([] :: [A.Value])
        , "bounds" A..= A.object []
        , "call"   A..= A.object
            [ "kind"   A..= ("function" :: String)
            , "method" A..= ("default" :: String)
            , "path"   A..= (["::default_crate", "Cfg"] :: [String])
            , "ret"    A..= A.object [ "ctor" A..= ("::default_crate::Cfg" :: String) ]
            , "traitQualifier"
                A..= (["::default_crate::Cfg", "::core::default::Default"] :: [String])
            ]
        ]
    ]

-- A trait method WITH a self receiver (`Any::type_id`): also UFCS-owned.
selfTraitFn :: FnInfo
selfTraitFn = fnFromJson $ A.object
    [ "name"    A..= ("type_id" :: String)
    , "params"  A..= [ A.object [ "name" A..= ("self" :: String), "type" A..= ("Cfg" :: String) ] ]
    , "results" A..= [ A.object [ "type" A..= ("TypeId" :: String) ] ]
    , "effect"  A..= ("pure" :: String)
    , "generic" A..= A.object
        [ "params" A..= ([] :: [A.Value])
        , "bounds" A..= A.object []
        , "call"   A..= A.object
            [ "kind"     A..= ("method" :: String)
            , "method"   A..= ("type_id" :: String)
            , "path"     A..= (["::default_crate", "Cfg"] :: [String])
            , "receiver" A..= A.object [ "arg" A..= (0 :: Int), "by" A..= ("ref" :: String) ]
            , "ret"      A..= A.object [ "ctor" A..= ("::core::any::TypeId" :: String) ]
            , "traitQualifier"
                A..= (["::default_crate::Cfg", "::core::any::Any"] :: [String])
            ]
        ]
    ]

-- An INHERENT generic method (no traitQualifier): the flat-field path owns it.
inherentGenericFn :: FnInfo
inherentGenericFn = fnFromJson $ A.object
    [ "name"    A..= ("get" :: String)
    , "params"  A..= [ A.object [ "name" A..= ("self" :: String), "type" A..= ("Store" :: String) ]
                     , A.object [ "name" A..= ("key" :: String),  "type" A..= ("String" :: String) ] ]
    , "results" A..= [ A.object [ "type" A..= ("String" :: String) ] ]
    , "effect"  A..= ("pure" :: String)
    , "generic" A..= A.object
        [ "params" A..= ([] :: [A.Value])
        , "bounds" A..= A.object []
        , "call"   A..= A.object
            [ "kind"     A..= ("method" :: String)
            , "method"   A..= ("get" :: String)
            , "path"     A..= (["::store", "Store"] :: [String])
            , "receiver" A..= A.object [ "arg" A..= (0 :: Int), "by" A..= ("ref" :: String) ]
            , "ret"      A..= A.object [ "ctor" A..= ("String" :: String) ]
            ]
        ]
    ]

-- A plain non-generic fn (no `generic` block at all).
nonGenericFn :: FnInfo
nonGenericFn = fnFromJson $ A.object
    [ "name"    A..= ("new" :: String)
    , "params"  A..= ([] :: [A.Value])
    , "results" A..= [ A.object [ "type" A..= ("Cfg" :: String) ] ]
    , "effect"  A..= ("pure" :: String)
    ]

spec :: Spec
spec = describe "WALL-D · genericHasTraitQualifier" $ do
    it "fires for a no-self, no-arg trait assoc fn (Default::default)" $
        genericHasTraitQualifier defaultFn `shouldBe` True

    it "fires for a self-receiving trait method (Any::type_id)" $
        genericHasTraitQualifier selfTraitFn `shouldBe` True

    it "stays False for an inherent generic method (no traitQualifier)" $
        genericHasTraitQualifier inherentGenericFn `shouldBe` False

    it "stays False for a non-generic fn (no generic block)" $
        genericHasTraitQualifier nonGenericFn `shouldBe` False
