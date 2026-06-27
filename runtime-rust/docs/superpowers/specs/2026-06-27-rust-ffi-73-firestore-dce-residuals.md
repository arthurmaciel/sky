# #73 — firestore SKY_DCE=0 full-surface residuals: validated analysis + 2-part plan

> **Status:** ANALYSIS COMPLETE + Part B empirically validated. Implementation in
> progress. Branch `feat/runtime-rust`. Reproduced on real firestore 0.49.0 with a
> `firestore = "0.49.0"` scratch project under `SKY_DCE=0` (keeps ALL 862 wrappers).

## The real residual count: 124 (not the filed 66)

`SKY_DCE=0` firestore build = **124 cargo errors** (the filed "66" undercounted; more
walls have since landed, surfacing more of the full surface). Histogram:

| code | n | class |
|---|---|---|
| E0412 | 93 | feature-gated type absent (`FirestoreCacheName`…) |
| E0433 | 12 | feature-gated path absent (`firestore::FirestoreCacheName`) |
| E0405 | 4 | feature-gated trait absent (`FirestoreCacheBackend`) |
| E0599 | 3 | feature-gated variant absent (`FirestoreDbSessionCacheMode::ReadThroughCache`) |
| E0308 | 6 | UFCS/trait-method return mismatch (see Part A) |
| E0603 | 3 | `fluent_api` private — fluent builder leak on the UFCS path |
| E0107 | 3 | `FirestoreWithMetadata<T>` field-accessor emitted without `<T>` |
| E0261 | 1 | serde-internal `VariantAccess<'de>` method leaks `'de` |

## Part B — feature mismatch (113 errors: E0412/E0433/E0405/E0599). DOMINANT.

**Root cause.** The inspector's `choose_visibility_features` (#89, `main.rs`) auto-injects
features for rustdoc visibility — for firestore (no `full` feature) it returns
`avail.to_vec()` = ALL features incl. `caching*`. So it BINDS the caching API
(`FirestoreCacheName` etc.). But the generated `Cargo.toml` emits bare
`firestore = "0.49.0"` (default features, NO caching) → those types don't exist →
113 errors.

**EMPIRICALLY VALIDATED FIX (Option P — propagate).** Patching the generated
`Cargo.toml` to `firestore = { version="0.49.0", features=["caching","caching-memory","caching-persistent"] }`
drops the build from **124 → 13 errors** with ZERO new feature-conflict errors. So
propagating the inspector's chosen feature set to the generated dep is sound + clean
+ max-coverage + NO stripe regression (keeps auto-inject, just makes the build match
what was bound). The remaining 13 are exactly Part A.

**Implementation (codegen + cabal):**
1. Inspector (`tools/sky-ffi-inspect-rs`): surface the effective (post-fallback)
   feature set in `PkgInfo` → `kernel.json` (new `features` field), mirroring
   `transitiveDeps`.
2. Codegen (`src/Sky/Generate/Rust/Project.hs` — the primary FFI crate dep line;
   `readTransitiveDepMap` is the sibling for transitive deps): read `features` and
   augment the primary crate's `[dependencies]` line to
   `{ version=…, features=[…] }`. Merge with any user-declared sky.toml features.
3. **Guardian-check (soundness):** confirm propagating `avail.to_vec()` can't enable
   MUTUALLY-EXCLUSIVE features for some crate (firestore was fine; a general crate
   may have exclusive features → the propagated set must be the one the inspector's
   rustdoc actually SUCCEEDED with, and ideally drop known-conflicting pairs). Verify
   no regression on stripe/firebase (their Cargo.toml now gets features too).

## Part A — UFCS/generic-path missing drop gates (13 errors). Inspector-side.

Theme: the `sky_ffi_generics.rs` (UFCS / generic-stub / trait-method / field-accessor)
emission path lacks the fail-closed gates the main `parse_fn_item` path has. Each is
a fail-closed-DROP (or owned-conversion). Exact sites (from the real build):

| site | shape | fix |
|---|---|---|
| `get_documents_path -> &String` (UFCS) | return-borrow not owned | owned-copy (`.to_string()`) OR drop |
| `ParentPathBuilder::as_ref -> &str` (UFCS) | return-borrow `&str` | owned-copy OR drop |
| `try_into -> Result<i32>` (UFCS) | Result-returning ok_res-double-wrapped | flatten OR drop |
| `parent_path -> FirestoreResult<ParentPathBuilder>` | Result double-wrap | flatten OR drop |
| `from_message(&arg0)` | arg/return mismatch | inspect + drop/fix |
| `FirestoreWithMetadata<T>` field-accessor | generic struct w/o `<T>` | DROP (can't monomorphise T) |
| `VariantAccess<'de>::unit_variant` | serde-internal `'de` method | DROP |
| `fluent_api::*::build_filter/aggregation/transform` ×3 | private-module fluent trait method on UFCS path | DROP (private module + the #68 fluent class) |

All are conservative drops (fail-closed) except the return-borrow ones, which can bind
via owned-copy (coverage win) — apply the existing `owned_copy_admissible` treatment
on the UFCS path.

## Verification
- firestore `SKY_DCE=0` → 0 errors (124 → 0).
- Cross-crate regression: stripe / firebase / the fixture sweep stay green (Part B
  changes every FFI crate's Cargo.toml features).
- New regression fixtures for the Part A shapes + a feature-propagation fixture.

## Note
The filed #73 ("66 / return-AsRef + generic-hole") = Part A. The 113-error feature
mismatch (Part B) is a distinct, newly-discovered bug → tracked separately (#100).
