# #73 — firestore SKY_DCE=0 full-surface residuals: validated analysis + 2-part plan

> **Status:** ANALYSIS COMPLETE. **Part B SHIPPED + guardian-approved** (feature
> propagation, incl. git deps). **Part A: E0107 gate SHIPPED**; 9-error UFCS tail
> remaining. Branch `feat/runtime-rust`. Reproduced on real firestore 0.49.0 with a
> `firestore = "0.49.0"` scratch project under `SKY_DCE=0` (keeps ALL 862 wrappers).

## OUTCOME (2026-06-27)

**Part B (#100) — SHIPPED.** Feature propagation closes the dominant 112-error
class. Real firestore `SKY_DCE=0`: **124 → 11 errors** (the 11 = Part A tail). Both
guardian gates passed (design APPROVE-WITH-CONSTRAINTS → all constraints applied →
final APPROVE-WITH-CONSTRAINTS, safe to commit).
- Inspector (`tools/sky-ffi-inspect-rs`): `PkgInfo.features` = the EFFECTIVE
  feature set rustdoc SUCCEEDED with (threaded through `run_rustdoc`; the existing
  mutually-exclusive fallback ⇒ `effective=[]`). Serialized into kernel.json.
- Codegen: `readPkgFeatures` + `mergePkgFeatures` (`src/Sky/Generate/Rust/Project.hs`)
  union the inspector set into the user's sky.toml dep spec (charset fail-safe-drop
  on inspector features; user features keep the strict emit gate; `try`-guarded read).
- **Generalised to git deps** (not just crates.io `RustVersion`): `_gitFeatures`
  on `RustGitDep` + parse + `emitDepLine` + `mergePkgFeatures` git arm — a
  git-sourced complex crate gets its gated APIs too. Soundness is dep-source-agnostic.
- Regression: hermetic fixture `106-ffi-feature-propagation` (git dep, gated
  `extra_value`) builds + runs `[ALL OK]` — the gated fn links ONLY because the
  feature was propagated. Existing git-dep fixtures 104/105 stay `[ALL OK]` (bare
  dep lines; their crates have no features → byte-identical).
- Soundness keystone: every propagated set is one rustdoc (macro-expand +
  type-check) accepted ⇒ free of the `compile_error!`-class conflict; residual
  rustdoc-vs-cargo divergences are all FAIL-CLOSED (loud cargo error). Inspector
  features are TRIPLE-gated (cargo charset + jsonQuote + validCargoFeature drop +
  validTomlStr) ⇒ can never inject TOML nor reach the emit-time `error`.
- Follow-up filed: #103 (pre-existing `parseInlineTable` multi-element user-feature
  array drop — fail-safe under-featuring; doesn't affect any current crate).

**Part A — E0107 gate SHIPPED** (generic-struct field-accessor drop; fixture 105).
Remaining: the 9-error UFCS/external-trait tail (6 E0308 + 3 E0603 — wait, now 5
E0308 + 3 E0603 + 1 E0261 = 9 after E0107). See §"Part A" below.

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

## Part A — remaining tail (10 errors, post-E0107, post-Part-B). Inspector-side.

E0107 gate SHIPPED (generic-struct field accessor; fixture 105). With Part B
applied, the CLEAN-MEASURED remaining firestore `SKY_DCE=0` residual is **10**
(`/tmp/fs73-partA.log`, committed Part B compiler). Two distinct emission paths:

### A1 — `sky_ffi_generics.rs` (UFCS/external-trait path), 4 errors — CLEAN DROPS

| site (sky_ffi_generics.rs) | shape | fix |
|---|---|---|
| `:33` `<FirestoreValue as ::serde_core::de::VariantAccess<'de>>::unit_variant` | UFCS method sig references an undeclared lifetime `'de` (serde Deserialize-internal trait) | DROP — gate: a UFCS trait-method whose rendered path/sig introduces a lifetime the wrapper fn doesn't declare |
| `:165` `<_ as ::firestore::fluent_api::select_filter_builder::FirestoreQueryFilterExpr>::build_filter` | E0603 — trait path runs through the PRIVATE `fluent_api` module (not publicly re-exported) | DROP — gate: UFCS trait path with a private-module segment + no public re-export (the #68 fluent class on the UFCS path) |
| `:183` `…fluent_api::select_aggregation_builder::FirestoreAggregationExpr>::build_aggregation` | same (private `fluent_api`) | DROP |
| `:254` `…fluent_api::document_transform_builder::FirestoreTransformExpr>::build_transform` | same (private `fluent_api`) | DROP |

The existing private-module machinery (`REACHABLE_PATHS`, the ~line-2093 "external
type whose canonical path runs through a private module" gate, the ~line-2493
`trait_reachable` gate) does NOT catch these on the UFCS external-trait emission.
**DELICATE: shares the path with WORKING public external-trait bindings** (From/Into/
Display — fixtures 46/96), so the private-module gate must drop ONLY genuinely-private
trait refs. Needs guardian review + verify 46/96 + firestore CRUD UFCS still bind.

### A2 — 6 E0308, mostly UFCS path (`sky_ffi_generics.rs`) — 3 sub-classes

| site | shape | fix |
|---|---|---|
| `generics:238` `<FirestoreTransactionData as FirestoreTransactionOps>::get_documents_path(&arg0) -> &String` | UFCS return-borrow, `ok_res` wants owned | **owned-copy** `.to_string()` (COVERAGE WIN — the #22 owned-copy treatment, not applied on the UFCS path) OR drop |
| `generics:246` `<ParentPathBuilder as AsRef<str>>::as_ref(&arg0) -> &str` | UFCS return-borrow | owned-copy `.to_string()` OR drop |
| `generics:270` `<FirestoreCacheName as rvstruct::ValueStruct>::value(&arg0) -> &String` | UFCS return-borrow | owned-copy `.to_string()` OR drop |
| `generics:230` `<FirestoreListenerTarget as TryInto<i32>>::try_into(arg0) -> Result<i32>` | declared return `Result<i64>` (Sky Int) but method gives `Result<i32>` — UFCS Result-INNER numeric width not saturated (#95 on the Result-Ok position) | saturate Result-inner numeric (`.map(\|v\| v as i64)`) OR drop |
| `bindings:4328` `ok_res(arg0.parent_path(…))` | `parent_path -> Result<ParentPathBuilder, FirestoreError>` double-wrapped in `ok_res` | flatten (`match`) OR drop |
| `bindings:5489` `ok_res(FirestoreSerializationError::from_message(&arg0))` | method returns an ERROR struct, declared String | DROP (error-ctor not useful) |

The 3 return-borrow ones are the strongest fix (owned-copy = bind, coverage win) —
the inherent path already does this (#22); the UFCS/external-trait path doesn't.
`:230` is the #95 saturating coercion not reaching the Result-Ok inner type on the
UFCS path. `:4328`/`:5489` are conservative flatten/drop. All fail-closed.

### Plan (next pass)
1. A1 first (cleanest, general): add the UFCS private-module + undeclared-lifetime
   gates; verify firestore 10→6, no over-drop (fixtures 46/96 + 104/105 green).
2. A2: characterise the 6 E0308, flatten Result-returning methods / drop error-ctors.
3. Guardian-review each gate (over-drop risk on the shared UFCS path). Per-class
   regression fixtures. Target firestore `SKY_DCE=0` → 0.

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
