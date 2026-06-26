{-# LANGUAGE OverloadedStrings #-}

-- | Regression fence for WALL-B (#75) — the transitive-dep crate-path E0433.
--
-- A synthesised generic/UFCS wrapper in `sky_ffi_generics.rs` references a type
-- or trait from a crate that is only a TRANSITIVE dep of the directly-`sky add`ed
-- crate, rendered crate-absolutely (`<Tag as ::equivalent::Equivalent<str>>::…`,
-- `… -> ::http::HeaderMap`). The generated `[dependencies]` listed only the
-- direct crate + the Sky stdlib crates, so the transitive crate was unresolvable
-- → cargo E0433 `unresolved crate <crate>` (the firebase wall: `http`,
-- `google_cloud_auth`, … ×19). The fix collects the referenced external crates
-- from the kept wrapper sources (`referencedExternalCrates`) and emits each as a
-- `<crate> = "*"` dependency (cargo unifies `"*"` with the already-present
-- transitive lockfile node).
--
-- These tests lock the SCANNER (the load-bearing, fiddly part): a crate-absolute
-- path START is a `::` in path position (string start or after `< ( & , = [ { | ;`
-- or whitespace); a `::` after an identifier (`Tag::method`) or after `>`/`)`/`]`
-- (`…>::method` UFCS / call / index member access) is NOT a crate. Std-family
-- pseudo-crates (`core`/`std`/`alloc`) and `crate`/`self`/`Self`/`super` are
-- dropped (`alloc` remaps to `std` then drops). Output is sorted + deduped.
module Sky.Generate.Rust.TransitiveDepCrateSpec (spec) where

import Test.Hspec
import Data.List (sort)
import Sky.Generate.Rust.Builder.Emitter (referencedExternalCrates, resolveTransitiveDeps)

spec :: Spec
spec = do
    resolveSpec
    describe "referencedExternalCrates — WALL-B (#75) crate-absolute scan" $ do

        it "extracts the transitive crate from a UFCS trait wrapper, skipping the member-access ::" $
            -- The fixture-86 wrapper shape. `transdep86` is direct; `equivalent`
            -- is the TRANSITIVE crate. `::Tag` after `transdep86` and `>::equivalent`
            -- after `Signer>` are MEMBER accesses, never crates.
            referencedExternalCrates
                [ "ok_res(<::transdep86::Tag as ::equivalent::Equivalent<str>>::equivalent(&arg0, arg1.as_ref()))" ]
                `shouldBe` ["equivalent", "transdep86"]

        it "extracts a transitive RETURN-type crate (firebase ::http::HeaderMap shape)" $
            referencedExternalCrates
                [ "pub fn f(a: ::transdep86::Tag) -> SkyResult<SkyError, ::http::HeaderMap> { ok_res(a.headers()) }" ]
                `shouldBe` ["http", "transdep86"]

        it "drops std-family pseudo-crates (core/std/alloc) — they are always linked" $
            -- The `type_id` wrapper references `::core::any::Any` + `::core::any::TypeId`;
            -- a `String` return is `::std::string::String`. None is a [dependencies] crate.
            referencedExternalCrates
                [ "ok_res(<::transdep86::Tag as ::core::any::Any>::type_id(&arg0))"
                , "use ::std::collections::HashMap; ok_res(::alloc::vec::Vec::new())"
                ]
                `shouldBe` ["transdep86"]

        it "does NOT treat a `>::method` UFCS close as a crate (member, prev char `>`)" $
            -- `Signer>::sign` — the `::` is preceded by `>` (UFCS close), so `sign`
            -- must NOT be collected as a crate.
            referencedExternalCrates
                [ "<::a::T as ::b::Tr>::sign(&x)" ]
                `shouldBe` ["a", "b"]

        it "does NOT treat a `)::` or `]::` (call / index) result as a crate" $
            referencedExternalCrates
                [ "foo()::bar(); arr[0]::baz()" ]
                `shouldBe` []

        it "dedups + sorts across multiple wrapper sources" $
            referencedExternalCrates
                [ "x: ::http::HeaderMap"
                , "y: ::http::Request"            -- same crate again
                , "z: ::bytes::Bytes"
                ]
                `shouldBe` ["bytes", "http"]

        it "drops crate / self / Self / super path keywords" $
            referencedExternalCrates
                [ "::crate::foo(); ::self::bar(); ::Self::baz(); ::super::qux()" ]
                `shouldBe` []

        it "returns [] for a wrapper that references ONLY the direct crate + std (no spurious dep — fixture 74)" $
            -- Mirrors fixture 74: every wrapper path is `::opaqueffi74::…` (direct)
            -- or `::core::…`/`::std::…`. The collector still yields the direct crate;
            -- emitCargoToml's dedup against the manifest drops it. The point here is
            -- NO third-party transitive crate is invented.
            referencedExternalCrates
                [ "ok_res(<::opaqueffi74::Req as ::core::clone::Clone>::clone(&arg0))" ]
                `shouldBe` ["opaqueffi74"]

        it "ignores an empty source list" $
            referencedExternalCrates [] `shouldBe` []


resolveSpec :: Spec
resolveSpec =
    describe "resolveTransitiveDeps — WALL-B (#75) cargo-metadata resolution (SOUND)" $ do

        let transMap =
                [ ("equivalent", "equivalent", "1.0.2")
                , ("tower_service", "tower-service", "0.3.3")
                , ("google_cloud_auth", "google-cloud-auth", "0.17.2")
                , ("transdep86", "transdep86", "0.1.0")
                ]

        it "resolves an underscore lib ident to its CANONICAL hyphen name + exact version" $
            -- The decisive WALL-B case: `::tower_service::` → `tower-service` (HYPHEN,
            -- from cargo metadata) with a PINNED exact version, never `"*"` / `_`-guess.
            resolveTransitiveDeps transMap ["transdep86"] ["tower_service"]
                `shouldBe` ([("tower-service", "0.3.3")], [])

        it "resolves the firebase google_cloud_auth ident → google-cloud-auth (the BLOCK case)" $
            resolveTransitiveDeps transMap ["rs_firebase_admin_sdk"] ["google_cloud_auth"]
                `shouldBe` ([("google-cloud-auth", "0.17.2")], [])

        it "treats a single-segment crate (no `_`) verbatim with its exact version" $
            resolveTransitiveDeps transMap ["transdep86"] ["equivalent"]
                `shouldBe` ([("equivalent", "1.0.2")], [])

        it "drops a crate already covered by the manifest (the direct sky-added crate)" $
            -- `transdep86` is the direct crate (covered); its own `::transdep86::Tag`
            -- references must not produce a self-dep.
            resolveTransitiveDeps transMap ["transdep86"] ["transdep86", "equivalent"]
                `shouldBe` ([("equivalent", "1.0.2")], [])

        it "covered-compare is `-`≡`_` normalised (hyphen manifest dep vs underscore scan)" $
            -- A directly-added HYPHEN crate (`nested-glob-crate`) referenced by its
            -- underscore path (`::nested_glob_crate::`) is recognised as covered.
            resolveTransitiveDeps transMap ["nested-glob-crate"] ["nested_glob_crate"]
                `shouldBe` ([], [])

        it "reports an UNRESOLVABLE crate (absent from cargo metadata) for a coverage-DROP — never a `*` dep" $
            -- A scanned ident the metadata couldn't resolve: the caller must drop
            -- the wrapper. It is NEVER emitted as a guessed / `"*"` dependency.
            resolveTransitiveDeps transMap ["transdep86"] ["some_unknown_crate"]
                `shouldBe` ([], ["some_unknown_crate"])

        it "partitions a mixed wrapper into resolved deps + unresolvable drops" $
            let (deps, unres) =
                    resolveTransitiveDeps transMap ["transdep86"]
                        ["equivalent", "tower_service", "ghost_crate", "transdep86"]
            in do
                sort deps `shouldBe` [("equivalent", "1.0.2"), ("tower-service", "0.3.3")]
                unres `shouldBe` ["ghost_crate"]

        it "dedups repeated idents across multiple wrappers" $
            resolveTransitiveDeps transMap ["transdep86"]
                ["tower_service", "tower_service", "equivalent", "equivalent"]
                `shouldBe` ([("equivalent", "1.0.2"), ("tower-service", "0.3.3")], [])

        it "empty scan → no deps, no drops" $
            resolveTransitiveDeps transMap ["transdep86"] [] `shouldBe` ([], [])
