# Rust FFI typed-surface parity with Go (task #14) — plan

Status: SHIPPED (corrected 2026-06-27 by principles-audit). Slices S1–S4 are implemented with fixtures — the inspector emits `is_field: true` / `is_field_set: true` (`tools/sky-ffi-inspect-rs/src/main.rs:1950/2021`) and `Rust/Ffi.hs` has `isField` handling. The original plan + 'Confirmed gaps' section below are RETAINED FOR CONTEXT ONLY and are STALE: gaps #1–#3 are closed; the cited `main.rs:1103/1524/1552` line numbers no longer hold.
Boundary: `tools/sky-ffi-inspect-rs/`, `src/Sky/Build/Rust/`, `src/Sky/Generate/Rust/`,
`runtime-rust/`. NEVER `runtime-go/`, `sky-stdlib/`, the shared Go `FfiGen` Go-glue, or
author `examples/` (except `examples/rust/`).

## Goal
Bring the Sky→Rust auto-FFI up to the Go backend's full-typed-surface generation, so
rich/framework crates (stripe / firestore / firebase) bind with NO hand shim — the
`examples/rust/skyshop-rs` wrapper crates become unnecessary. Go auto-generates ~76k
Stripe symbols (opaque handles + field/method accessors + typed records) and DCE
tree-shakes to ~4k reached lines.

## Verified current state (2026-06-22, two read-only mappers + firsthand grep)
The Rust FFI path is more developed than "nothing":
- Inspector (`tools/sky-ffi-inspect-rs/src/main.rs`, 2827 ln) runs `cargo +nightly
  rustdoc --output-format json`, emits `PkgInfo { functions:[Function], modules }`.
  Captures free fns, inherent + associated methods (receiver threading), async
  (`effect="effectful"`), self-returning builder setters (`selfReturning`). Maps
  `Vec/Option/Result/&str` to Sky types; crate-local opaque types qualified to
  `::crate::Type`.
- Haskell glue `src/Sky/Build/Rust/Ffi.hs` (784 ln) emits Rust wrappers: opaque
  by-value `::crate::Type` params, instance/static/free method dispatch,
  `Result<T,E>`→Sky-Result and async→`Box::pin(async{…})`→Sky-Task bridging,
  self-returning setter owned-threading. `.skyi` opaque fallback = Sky `String`.

### Confirmed gaps (priority order)
1. **No struct FIELD accessors.** `is_field`/`is_field_set` are hardcoded `false`
   in the inspector (main.rs:1103/1524/1552); `Rust/Ffi.hs` has ZERO `isField`
   handling. So a foreign opaque struct exposes only its METHODS — Sky can hold a
   `CheckoutSession` but cannot read `.id`/`.url`/`.status`. This is THE reason the
   skyshop shims flatten to `Dict String String`. (Go's `FfiGen` DOES synthesize
   field accessors — parity gap, with a reference.)
2. **No enum-variant binding.** Foreign enums are opaque names; Sky cannot
   construct or `case` them.
3. **No tree-shake / DCE** on the FFI surface — every discovered symbol is emitted
   (`Rust/Ffi.hs` blindly emits all `_pkgFns`). The 76k→4k gap.
4. **Generic / lifetime / trait-bound fns dropped** by the inspector — coverage loss.

## Slices (each independently shippable + verifiable; guardian-gated)
- **S1 — field GETTERS (this slice, de-risks the spine).** Inspector emits public
  fields of crate-local public structs as field-getter `Function`s; `Rust/Ffi.hs`
  synthesizes a getter wrapper `fn get(recv) -> FieldTy { recv.field }`. Proves the
  end-to-end pipeline for a NEW metadata kind. Smallest unit: one struct, one public
  `Copy` field (e.g. `i64`), read from Sky.
- **S2 — field SETTERS + Clone-typed getters.** `is_field_set`; getters for
  non-Copy `Clone` fields (return an owned clone — never move the field out of a
  borrowed receiver). Builds on S1.
- **S3 — enum-variant binding** (construct + discriminate foreign enums). DESIGN below.
- **S4 — FFI-surface DCE / tree-shake** (reachability filter so binding a huge crate
  emits only reached symbols). Highest blast radius — last. DESIGN below.

## S4 design — reachability-filter the emitted Rust FFI bindings
### Verified current state
- `RustFfi.n` (`src/Sky/Build/Rust/Ffi.hs`) emits the FULL `*_bindings.rs` (every
  `_pkgFns` symbol, deduped, `#![allow(dead_code)]`) at **`sky add` / FFI-install time**
  (invoked from `app/Main.hs`), cached under `.skycache/ffi/rust/<slug>_bindings.rs`.
- Build time just COPIES the cached file (`src/Sky/Generate/Rust/Project.hs:230-231`).
- The shared whole-program DCE (`Sky.Build.Dce.reachableWholeProgram`, result in
  `globalReachableProgram :: IORef (Set Dce.Ref)`, kinds `TopRef`/`FfiRef`/`CtorRef`)
  already gates `main.rs` user-code emission — but NOTHING filters the copied wrappers.
  So `main.rs` is already reachability-pruned (Go-parity for the user file); the gap is
  only the wrapper crate, which cargo compiles in full (compile-time + the 76k→4k
  source-size parity).
### Approach (build-time filter, conservative superset) — CORRECTED per guardian review
**Name-mapping reality (the guardian's design-breaking correction).** An FFI dep call
site canonicalises to `Can.VarKernel kernelMod name` → recorded by `Dce.collectRefs` as
**`FfiRef km fn`**, NEVER `TopRef`. So the reached key for a wrapper is
`FfiRef (rustKernelName pkg) (wrapperRefName fn)` where `rustKernelName = "Rust_"++base`
(underscore, NOT the dotted `mname="Rust."++base`) and `wrapperRefName` is the EXACT
disambiguated name `emitRustKernelJson`/`emitSkyiRustFn` emit (`lowerFirst (_fnName fn)`
+ `_from_<lowerFirst recv>` for accessors; field getters already bake `_field`, setters
`_set_field`, enums `_new_variant`/`tag_of_`/`_as_variant`). The earlier `TopRef
"Rust.X" (lowerFirst fnName)` premise was WRONG (that shape is the stdlib `.sky`-dep
path, a different code path) — it would never match → silent no-op, or if mis-gated,
drop every used wrapper (E0425 on every FFI call).
**Mechanism.** Re-emit/filter at build time from the on-disk `*.kernel.json` (structured,
key-aligned: its `name` IS the `FfiRef` key by construction) ∩ the reached set — NOT by
regex over the rendered `.rs` (unsound: multi-line bodies, orphaned impls, rustfmt
reflow). If text-slicing the cached `.rs` is used instead, each per-fn wrapper MUST be
emitted at `sky add` time wrapped in `// SKY-FFI-WRAPPER BEGIN <name>` … `END` sentinels.
### S4 LOCKED invariants (guardian-reviewed — R-D / R-A / R-B / R-2 / R-3 / R-4)
- **R-D (keying, CARDINAL).** Filter keys on `FfiRef (rustKernelName pkg) (wrapperRefName
  fn)` via a SINGLE shared `wrapperRefName :: FnInfo -> String` consumed by kernel.json
  emit, `.skyi` emit, `dedupByRustName`, AND the S4 filter — so the reached key and the
  emitted item can never diverge (today the disamb name is hand-inlined in ≥4 places; unify
  it first, ideally `newtype WrapperRef`). Add a build-time BIJECTION check: if the computed
  key set and the emitted-wrapper-name set are not in bijection ⇒ FULL-EMIT (R-3).
- **R-A (Display/FromStr).** The synthetic `to_string`/`from_string` bridges emit as
  `impl Display`/`FromStr` on the opaque type (NOT free `pub fn`s with a kernel.json name).
  They are PREAMBLE-class — kept unconditionally, never per-fn filtered (a kept wrapper may
  format the opaque value).
- **R-B (preamble + only-1:1-wrappers-filtered).** Keep UNCONDITIONALLY: the preamble
  (`use crate::*`, `use std::collections::HashMap`), every `use`, every opaque type alias,
  ALL trait impls, and any item that is NOT a recognised 1:1 kernel.json wrapper. Filter
  ONLY the per-fn wrapper items that have an exact kernel.json `name`. Enforce: any
  unrecognised item is preamble-class (kept). This makes "no per-fn→per-fn call edge"
  (true today) an ENFORCED invariant, not an observed accident — so a future
  wrapper→wrapper edge (e.g. async-bridge helpers, #15) can't silently break it.
- **R-2 (sound mechanism).** Re-emit from kernel.json (on-disk, key-aligned) ∩ reached;
  do NOT regex-filter the bare `.rs` unless BEGIN/END sentinels are emitted at add time.
- **R-3 (fail-safe).** FULL-EMIT on ANY of: `SKY_DCE=0`/`globalDceDisabled`,
  `Set.null reached`, OR an R-D bijection/ambiguity failure. Never drop on doubt.
- **R-4 (cache staleness — I1 trap).** The filtered `.rs` is a function of the WHOLE-PROGRAM
  reached set, not one file's bytes. NEVER serve a filtered `.rs` cached on `source.hash`
  alone (edit Main.sky to newly call `Foo.bar` ⇒ stale filtered `.rs` missing `bar` ⇒
  E0425). Either fold the sorted kept-wrapper-name set into the cache key, OR re-filter
  every build (cheap; cargo's own incremental handles no-change). DEFAULT: re-filter each
  build from kernel.json ∩ reached.
- **D4 proof obligation.** Filtered build ≡ full build except absent dead wrappers — holds
  because (kept set) = (all preamble/impls) ∪ (reachable wrappers) ⊇ closure of any kept
  wrapper's deps, since every kept-wrapper dependency is preamble-class (R-A/R-B).
- **D5 (boundary).** In-boundary: `src/Sky/Build/Rust/Ffi.hs`, `src/Sky/Generate/Rust/
  Project.hs`, reads shared `Dce`/`globalReachableProgram` WITHOUT changing its semantics.
### S4 PRECONDITION (guardian DEFER→APPROVE gate)
Before/with implementation: a fixture under `runtime-rust/tests/sky/` that binds a real
MULTI-symbol crate and calls 1-of-N, asserting (a) the emitted bindings `.rs` contains the
used wrapper + preamble + impls and NOT the unused wrappers, (b) the program builds + runs
identically to a full-emit (`SKY_DCE=0`) build, (c) a measured source-size/compile delta.
This is both the value-proof the guardian required and the D4 regression guard.

## S1 design (the slice under guardian review)
### Inspector (`tools/sky-ffi-inspect-rs/src/main.rs`)
- When walking crate-local public structs (the `TYPE_KINDS` reachability pass already
  visits them, ~1207/1258-1371), additionally enumerate each `struct` item's PUBLIC
  named fields (rustdoc `kind:"struct"` → `inner.struct.kind.plain.fields` → resolve
  each field item, `is_public` only).
- For each public field whose type maps to a Sky type OR a crate-local opaque type,
  emit a `Function` with: `name = field`, `methodName = field`, `recvType` /
  `recvRustType` = the owning struct, `params = []`, `results = [Param{ ty, rustType
  = fieldRustType }]`, `effect = "pure"`, `isField = true`.
- **Soundness gates (designed-in, total by construction):**
  - PUBLIC fields only (respect rustdoc visibility) — never expose a private field.
  - Field type must be `Sized`. For S1 restrict to `Copy`-or-primitive/String/Vec/
    Option field types (Clone-clone deferred to S2) so the getter is `{ recv.field }`
    / `{ recv.field.clone() }` with no move-out-of-borrow hazard.
  - Skip reference / lifetime-bearing field types (same rule the fn path already uses)
    — a borrowed field can't cross the owned FFI boundary.
  - A field getter is a pure projection — it CANNOT panic. No `unwrap`/index/arith.
### Haskell (`src/Sky/Build/Rust/Ffi.hs`)
- Parse the new `isField` flag onto `FnInfo` (FromJSON).
- In the emit path, an `isField` getter emits a wrapper that takes the receiver
  by value (or `&` if the field is `Copy`) and returns `recv.field` coerced via the
  existing `translateRustRet`. Receiver threading reuses the instance-method path.
- `.skyi`: `field : Recv -> FieldTy` (pure; NOT `Result`-wrapped — a field read is
  infallible, mirroring the `effect="pure"` non-fallible wrapper shape).
### S1 LOCKED constraints (guardian design review 2026-06-22 — APPROVE-WITH-CONSTRAINTS)
- **C1 (F1, int gate).** Field type eligible only if int width is value-preserving into
  Sky `i64`: `{i8,i16,i32,i64,u8,u16,u32}`. DROP `u64/u128/i128/usize/isize` (reason
  `wide_int_lossy`) — never widen Sky Int (out of boundary). (The same lossy bug on the
  EXISTING method-return path is task #16, separate commit.)
- **C2 (F4, dedup key).** Bake an `isField` discriminator into the Haskell dedup +
  `.skyi` name key (e.g. `_field_from_<Recv>` vs the method `_from_<Recv>`) so a `pub id`
  field + `id()` method on the same struct don't collide (silent drop / Rust `E0428`).
  MANDATORY regression fixture: a struct with a same-named field AND method.
- **C3 (F2, doc-hidden).** A `#[doc(hidden)] pub` field reads as `visibility=="public"`;
  add a `doc_hidden()` check and AND it into BOTH the field gate and the owning-struct
  reachability gate. (`pub(crate)`/`pub(in path)` already safely excluded by the exact
  `is_public` string compare.)
- **C4 (F5, receiver).** Receiver ALWAYS `&recv` (never by-value — avoids
  move-out/partial-drop + preserves Sky value semantics). Body: `recv.field` (Copy) /
  `recv.field.clone()` (eligible non-Copy). A crate-local opaque field is eligible ONLY
  if it derives `Clone`.
- **C5 (F3, closed type set).** S1 eligible field types = the closed set: `Copy` ∪
  `String` ∪ `Vec<T>` ∪ `Option<T>` (T recursive in the set) ∪ Clone-DERIVING opaque.
  NO arbitrary `T: Clone` in S1 (a hand-written `Clone` impl can panic/abort → would
  breach the no-panic thesis; deferred to S2 with a documented caveat).
- **C6 (.skyi).** Field getter `.skyi` type is INFALLIBLE: `field : Recv -> FieldTy`
  (pure, NOT `Result`-wrapped).

### Verification (S1 done = all green)
- A NEW minimal fixture crate under `examples/rust/` (or a local `["rust.dependencies]`
  git/path dep) with `pub struct P { pub n: i64, pub label: String }` + a ctor fn.
  A Sky program binds it, constructs a `P`, reads `p.n` and `p.label`, prints them.
- `sky build --backend rust` + run → correct values. The getter is auto-generated,
  NO hand wrapper for the field reads.
- Inspector unit: run it on the fixture crate, assert the JSON `functions` now
  contains `isField:true` entries for `n` and `label`.
- clippy HARD-DENY clean on generated + runtime; pre-final code gate; guardian final.
- Checkpoint-commit S1 before S2.

## S3 design — enum-variant binding (opaque handle + TOTAL accessors)
A foreign enum stays an OPAQUE handle to Sky (Rust `::crate::E`), exactly like a
foreign struct — we do NOT lower it to a generated Sky ADT (the runtime can't name /
destructure a per-project ADT across the FFI boundary — see CLAUDE.md learning). Bind
three accessor kinds, all total-by-construction:
- **Unit-variant constructor** `<variant> : () -> E` → `::crate::E::<Variant>`. Emitted
  ONLY for a crate-local PUBLIC enum that is NOT `#[non_exhaustive]` and whose variant
  is not `#[non_exhaustive]`/doc-hidden (external code cannot construct a non_exhaustive
  enum's variants — would be `E0639`/cargo-fail).
- **Data-variant constructor** for tuple variants `V(F1,..)` → `<variant> : F1 -> .. -> E`
  and struct variants `V{a,b}` → `<variant> : A -> B -> E` (fields in declaration order),
  ONLY when EVERY field type is in the S1 closed set (C5) and the enum is constructible
  (not non_exhaustive). Skip a variant with any non-closed field.
- **Tag accessor** `tag : E -> String` → generated `match e { E::A => "A", E::B(..) =>
  "B", .. }`; a `#[non_exhaustive]` enum (or one with a skipped variant) gets a trailing
  `_ => "<unknown>"` arm so the match is TOTAL. Lets Sky branch on the variant name.
- **Payload extractor** `as_<variant> : E -> Maybe T` for a SINGLE-field tuple/struct
  variant whose field is in the closed set → `match e { E::V(x) => Just x.clone(), _ =>
  Nothing }` (total; clones before the by-value receiver drops). Multi-field variants:
  SKIP in S3 (Sky has no clean FFI tuple) — defer. No payload extractor → Sky still
  discriminates via `tag` and reconstructs via the constructor if needed.
### S3 locked constraints
- **E1 (totality).** Every generated `match` is exhaustive OR has a `_` wildcard arm —
  NO non-exhaustive match (cargo-fail) and NO panic. `#[non_exhaustive]` ⇒ wildcard
  mandatory on tag + every `as_`.
- **E2 (constructibility).** No constructor for a `#[non_exhaustive]` enum or variant,
  or a variant with any non-closed-set / generic / ref / lifetime field. Discriminators
  (tag/as_) are still emitted for non_exhaustive enums.
- **E3 (visibility).** PUBLIC enums + PUBLIC variants only; `#[doc(hidden)]` enum or
  variant skipped (both levels), mirroring C3.
- **E4 (closed types).** Variant field types obey the S1 closed set (C5) + the C1
  wide-int gate; a variant with an ineligible field gets no constructor/extractor (but
  still appears in `tag`'s match, via the wildcard if needed).
- **E5 (dedup).** Distinct keys per kind: constructor `<v>_new_variant_from_<E>`, tag
  `tag_of_<E>`, extractor `<v>_as_variant_from_<E>` — non-colliding with each other,
  with struct field/method bindings, and across variants. Fixture must witness an enum
  with a unit variant + a single-field tuple variant + (ideally) a `#[non_exhaustive]`
  case.
- **E6 (.skyi infallible).** Constructors/tag are pure (`() -> E` / `E -> String`);
  extractors are pure `E -> Maybe T`. NONE Result-wrapped; bodies are
  match/clone/construct — no unwrap/index/arith/panic.
- **E7 (generics).** Generic enums (`Option<T>`-style, any `E<T>`) are SKIPPED in S3
  (monomorphisation is out of scope) — drop with an audited reason.

### S3 LOCKED refinements (guardian design review 2026-06-22 — APPROVE-WITH-CONSTRAINTS)
- **R1 (F1 CRITICAL, refines E3).** A variant's rustdoc `visibility` is `"default"`, NOT
  `"public"` — variant visibility is INHERITED from the enum. Do NOT call `is_public()`
  on a variant (it returns false → S3 silently emits NOTHING). Gate on the ENUM's
  visibility + the enum's/variant's doc-hidden only.
- **R2 (F2 CRITICAL, refines E2).** `doc_hidden()` does NOT detect `#[non_exhaustive]`.
  Add a `non_exhaustive(item)` detector (rustdoc `attrs` contains the bare string
  `"non_exhaustive"`). Detection FAILURE ⇒ assume non_exhaustive (losing a ctor is safe;
  emitting one on a real non_exhaustive enum is E0639 cargo-fail).
- **R3 (F3+F4 HIGH, refines E1).** The `tag`/`as_` match needs a `_ => …` wildcard arm
  iff (enum is `#[non_exhaustive]`) OR (ANY variant was skipped: doc-hidden / ineligible
  field / multi-field). Both conditions independently force E0004 without it.
- **R4 (F5 MEDIUM).** SKIP an enum with zero variants (uninhabited) or all-variants-
  skipped — audited reason; don't emit a dead/all-`<unknown>` tag.
- **R5 (F6 MEDIUM, refines E1).** Match-arm syntax dispatches on variant KIND: unit →
  `E::V`, tuple → `E::V(..)`, struct → `E::V{..}`. A uniform `(..)` is E0769 on struct
  variants.
- **R6 (F7 MEDIUM, refines E6).** Extractor receiver is BY VALUE (the established
  convention): `match e { E::V(x) => Just(x), .. }` — an owned `e` MOVES the single
  closed-set field out (no clone needed, no E0509). For a struct variant: `E::V{ a } =>
  Just(a)`. (If a future variant binds the receiver by `&E`, switch to `ref a` +
  `.clone()`.) `T: Clone`/closed-set already guaranteed by reusing the S1 field gate.
- **R7 (F9 LOW, refines E7).** Detect generics at the ENUM level (`generics.params`
  non-empty ⇒ skip `generic_enum`), not via per-field failure. Variant fields are always
  as-public-as the enum (no S1-style private-field trap).
- **Fixture (refines E5).** One crate witnessing: unit + single-closed-tuple + single-
  closed-struct + multi-field (deferred → tag-only) + non-closed-field (tag-only) variants;
  AND a separate `#[non_exhaustive]` enum with a `#[non_exhaustive]` variant. Assert:
  non_exhaustive ⇒ tag/as_ carry a wildcard + NO constructors; skipped variants reachable
  via the tag wildcard; feature-minimal `cargo build` clean (proves no E0639/E0004/E0509/
  E0769) + clippy HARD-DENY clean.

## Invariants (apply to every slice)
- **No-runtime-panic thesis holds.** Every generated accessor is total by
  construction (projection / `.clone()` — never index/unwrap/move-out-of-borrow).
- **Visibility honored.** Only `pub` fields/variants/methods ever surface.
- **Go backend untouched.** Shared `FfiGen` Go-glue + `runtime-go` are out of
  boundary; only the Rust inspector + `Rust/Ffi.hs` + Rust codegen change.
- **Coverage measured, not assumed.** `sky-rust-backend:ffi-audit` before/after to
  quantify the surface delta; the inspector `--audit` drop-report tracks what's still
  dropped.
