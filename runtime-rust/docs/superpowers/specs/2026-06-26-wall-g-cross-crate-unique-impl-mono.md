# WALL-G — Cross-crate unique-impl concrete monomorphization

**Status:** SHIPPED — implemented + guardian-final APPROVE-WITH-FIXES (B-1 fixed). Fixture
`91-ffi-cross-crate-impl` GREEN under `SKY_DCE=0` + runs `op=real:hi [ALL OK]`; full FFI
gate 37 ok · 0 fail; 208 inspector unit tests.

**Implementation notes (vs design):**
- **B-1 (guardian-final, fixed):** the async-Send OPAQUE gate (`recv_provably_async_send`)
  now matches a cross-crate concrete by its FULL owning-crate path only — a bare-last-
  segment fallback would have admitted a sibling crate's same-named `!Send` concrete when
  the binding crate also defines a Send `Client` (E0277). Unit test
  `wallg_async_send_opaque_full_path_only`.
- **B4 (version skew) — closed by cargo unification, not implemented.** All bindings live
  in one `sky-app` crate that deps every project crate; cargo unifies a shared semver-
  compatible trait crate to ONE version across the graph, so two project crates can't see
  path-equal-but-type-incompatible traits. An incompatible major resolves as a *distinct*
  crate → distinct canonical path → no false key-equality. The skew refusal is unreachable
  here; `XcImpl` omits the version fields.
- **Owning-crate dep:** WALL-G requires the impl-providing crate to be an explicit project
  `[rust.dependencies]` (true for the stripe facade) — its types resolve in `sky-app`'s
  Cargo.toml because the user added it.

**Original design + B1–B7 below.**
**Epic:** stripe (#70) auto-FFI — the gating sub-step of the stripe *operation* arc.
**Date:** 2026-06-26
**Author:** runtime-rust agent (measurement-grounded)

---

## 1. The problem, measured (solid — corrects the earlier "multi-impl ambiguous" framing)

The keystone stripe operation is `request.send(&client)`. Live rustdoc measurement
(async-stripe 1.0.0-rc.6) shows it is **cross-crate**:

| Fact | Where | rustdoc evidence |
|---|---|---|
| `fn send<C: StripeClient>(self, client: &C)` is a method on `impl<T> CustomizableStripeRequest<T>` | crate **`async-stripe-client-core`** (lib `stripe_client_core`) | method ids 330/331/126/123, each generic param `C`, on the `CustomizableStripeRequest<T>` impl block |
| `StripeClient` / `StripeBlockingClient` **traits** are *defined* here, with **0 impls in-crate** | `async-stripe-client-core` | `collect_trait_concrete_impls` finds 0 → `concrete_for_unique_impl` = None → **`trait-bounded-param-ambiguous`** drop |
| `impl StripeClient for stripe::hyper::client::Client` (async) **and** `impl StripeBlockingClient for stripe::hyper::blocking::Client` (blocking) | crate **`async-stripe`** facade (features `default-tls`,`blocking`) | each trait **uniquely** impl'd by ONE crate-local `Client` |
| The facade does **not** re-export `send`/`CustomizableStripeRequest` (only `CustomizedStripeRequest`/`StripeRequest`/`RequestStrategy`) | `async-stripe` | so `send` cannot be bound from the facade rustdoc alone |

**Consequence:** the user's "both clients configurable" decision is satisfied
*automatically* — `send` → the unique async `Client`, `send_blocking` → the unique
blocking `Client`. There is **no N-impl ambiguity to disambiguate**. The actual gap
is that #52/WALL-F's concrete-impl index (`collect_trait_concrete_impls`) is
**crate-local only** (`crate_id == 0`), so it never sees the facade's impl while
binding client-core.

## 2. Feasibility proof — cross-crate trait identity is stable

rustdoc's per-crate `index` ids are NOT comparable across crates, but the top-level
`paths` table maps every id (local *and* external) to a **canonical path**:

```
facade  impl-trait-ref id 159  → paths["159"].path = ["stripe_client_core","stripe_request","StripeClient"]
client-core trait def id 128   → paths["128"].path = ["stripe_client_core","stripe_request","StripeClient"]   ← SAME
```

Joining the canonical path (`"stripe_client_core::stripe_request::StripeClient"`)
gives a **cross-crate-stable key**. Verified live, both directions.

## 3. Design — global canonical-path-keyed concrete-impl index

### 3.1 One inspector invocation, all project FFI crates
`main()` already accepts `<crate>...`. Today `regenMissingRustBindings` (Haskell)
spawns one inspector **per** crate, so cross-crate impls are invisible. Change:
- **Haskell:** when the project has ≥1 Rust FFI dep, pass the **whole** rust-crate
  set (name + version + features) to a **single** `runRustInspector` call. Preserve
  the existing per-crate *output* slug (one `<crate>_bindings.rs` each) — only the
  *index build* becomes global.
- **Caching:** the per-crate `.skyi`/bindings cache stays keyed per crate; the
  cross-crate index is rebuilt only when the *set* changes. (Open question G-Q1:
  simplest correct cache invalidation — rebuild-all when any member changes, vs
  hash the set. Default: rebuild-all; it is bounded and rare.)

### 3.2 Global index, canonical-path keyed
Add a process-global (not per-crate-reset) `GLOBAL_TRAIT_CONCRETE_IMPLS:
HashMap<String /*canonical trait path*/, Vec<ConcreteImpl>>` where
`ConcreteImpl = { for_canonical_path, owning_crate, reachable_public_path }`.
Populate from **every** crate arg's rustdoc during a first pass, applying the SAME
soundness filters as `collect_trait_concrete_impls` (the `for` type concrete +
nameable + reachable **in its owning crate**; trait keyed by canonical path).

### 3.3 Resolution + emission
`single_concrete_impl_trait_key` resolves the bound trait → its canonical path
(via the *current* crate's `paths`); `concrete_for_unique_impl` consults the
GLOBAL index; **exactly one** entry → monomorphize (reusing #52/WALL-F's existing
substitution + async + Send-gate machinery unchanged). The emitted wrapper
references the concrete type by its **owning crate's** public path
(`stripe::hyper::client::Client`). Therefore:
- the client-core bindings file gains a dependency on the facade crate's public
  path → its generated `Cargo.toml` must include `async-stripe` (WALL-B-flavored
  transitive-path handling, now cross-crate). (Open question G-Q2: derive the dep
  + version from the owning-crate record already in the invocation set.)

### 3.4 Soundness gates (must hold — guardian focus)
1. **Unique only.** 0 or >1 cross-crate impls → keep dropping (`ambiguous`). Over-drop is sound.
2. **Reachability in the owning crate.** The concrete `for` path must be a *public*
   re-exported path of its owning crate (consult that crate's REACHABLE_PATHS), else drop.
3. **Send proof still required.** The async `send` path keeps the existing receiver/param
   Send gate; a `!Send` concrete client → drop, no E0277.
4. **No cycle / no self-widening.** The global index is built once, read-only during binding.
5. **Feature determinism.** The concrete impl only exists under specific facade features
   (`default-tls`/`blocking`); the index reflects exactly the features the user selected
   in sky.toml. An impl absent under the chosen features is correctly absent.

### 3.4bis Added gates (guardian-required, were missing)
6. **Rendered concrete path is the OWNING crate's validated public re-export.** The
   emission renders a *stored string*, never a re-resolution of the foreign rustdoc id in
   the binding crate's namespace (the renderer's `reachable_local_path` misses cross-crate
   and falls to a bare last segment → E0412/E0433). Compute the path in the owning crate's
   pass via `external_type_public_path` (private-module fail-closed); no sound path → never
   record the entry.
7. **Send verdict is OWNING-crate-computed and frozen.** The async-Send proof
   (supertrait / explicit-impl / all-fields) runs for the concrete *in its owning crate* at
   collection; the async gate consults the stored `send_ok` bool, never the per-crate
   id-keyed Send sets (blind to the owning crate during the binding crate's pass). Unproven
   → not Send → over-drop the async method (no E0277 at `tokio::task::spawn`).

## 3.5 Guardian MUST-hold constraints (B1–B7) — APPROVE-WITH-CONSTRAINTS

The `ConcreteImpl` index entry is a **closed, fully-resolved** struct so cross-crate
illegal states (unrendered path / unproven Send / version skew) are unrepresentable at
emission (parse-don't-validate):

```
ConcreteImpl {
    trait_canonical_path:  String,   // B1 key — doc[paths][trait-id].path joined, resolved in trait's OWN crate
    reachable_public_path:  String,  // B2/gate6 — owning-crate external_type_public_path, fail-closed
    send_ok:               bool,     // B3/gate7 — owning-crate Send proof, frozen
    owning_crate:          String,   // B4 — dep name for A's generated Cargo.toml
    owning_crate_version:  String,   // B4 — dep version + skew check
    trait_crate_version:   String,   // B4 — refuse if A and B see different versions of the trait-defining crate
}
```

- **B1** — key strictly on the trait id's canonical `doc["paths"][id].path` (includes the
  defining crate name); NEVER last-segment, NEVER the per-crate `external_crates` numeric
  disambiguator (per-crate-local → breaks cross-crate equality).
- **B2** *(make-or-break)* — store + render `reachable_public_path`; do NOT call
  `rustdoc_type_to_rust_str`/`reachable_local_path` on the foreign `for` node during the
  binding crate's pass. No sound public path → entry never recorded (drop = sound).
- **B3** — store + consult frozen `send_ok`; a `!Send` concrete never reaches spawn.
- **B4** — A's generated `Cargo.toml` gains crate B (name+version from the invocation set);
  refuse resolution when the trait-defining crate resolves to different versions as seen
  from A vs B (path-equal but type-incompatible) → drop.
- **B5** — single invocation isolates per-crate rustdoc failure (failed crate contributes
  nothing, batch proceeds) AND keeps each crate's feature-resolved rustdoc distinct (NO
  feature union across crates — async-stripe runtime features are mutually exclusive).
- **B6** — the public-path/doc-hidden gate uses the *owning* crate's reachability snapshot
  captured during B's pass, not A's live thread-local.
- **B7** — fixture `91-ffi-cross-crate-impl` MUST pass under `SKY_DCE=0` AND a real
  `cargo build` (a green inspector without cargo is meaningless for this "type-checks-but-
  cargo-fails" class). Plus **B-cache**: each crate's bindings-cache key includes a hash of
  the ordered crate+version+features set, so changing the set invalidates every member.

## 4. Scope boundary (what WALL-G does NOT do)
WALL-G delivers cross-crate `C: ConcreteClient` resolution. It does **not** by
itself bind `send` end-to-end — `send`'s Self is the generic `CustomizableStripeRequest<T>`
(serde-T) which is **WALL-H**, and the resource builders that produce it live in
further sub-crates (**WALL-I**). WALL-G is the *gating* piece both depend on.

## 5. Verification plan
- **Fixture `91-ffi-cross-crate-impl`:** two local `file://` git path-crates — `wire-crate`
  (defines `trait Wire: Send + Sync + 'static` + a `fn op<C: Wire>(&self, c: &C)` on a concrete
  `Req`) and `client-crate` (the unique `impl Wire for RealClient` + `RealClient`).
  A Sky `Main.sky` that adds both, calls `Req.op` with a `RealClient`, asserts
  `[ALL OK]`. NEGATIVE: a second `impl Wire for Other` makes `op` drop again
  (ambiguous) — covered by the inspector unit test
  `wallg_xc_unique_only_when_exactly_one_impl` (registers 2 distinct impls → `None`),
  not a third fixture crate.
- **Guardian-final:** `SKY_DCE=0` build of the fixture + a real cargo build.
- **Real-crate proof (later, with WALL-H/I):** `send` against async-stripe rc.6.

## 6. Open questions for guardian
- **G-Q1** cross-crate cache invalidation (rebuild-all vs set-hash).
- **G-Q2** how the cross-crate wrapper's generated Cargo.toml gets the owning-crate dep+version.
- **G-Q3** is keying purely on the joined canonical-path string sufficient, or must we
  also disambiguate by the trait's `external_crates` disambiguator when two deps vendor
  same-named traits? (Proposed: canonical path already includes the defining crate name,
  so collisions require genuinely the same crate — sound. Confirm.)
- **G-Q4** any soundness hole in emitting a wrapper that crosses crate boundaries when the
  concrete type is `pub` but lives behind a `#[doc(hidden)]` module? (Proposed: gate on
  REACHABLE_PATHS of the owning crate, which already excludes doc-hidden.)
