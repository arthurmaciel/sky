# Rust FFI typed-surface parity with Go (task #14) — plan

Status: SCOPED (slice 1 starting). Guardian design review: pending (pre-write).
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
- **S3 — enum-variant binding** (construct + match foreign enums).
- **S4 — FFI-surface DCE / tree-shake** (reachability filter so binding a huge crate
  emits only reached symbols). Highest blast radius — last.

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

## Invariants (apply to every slice)
- **No-runtime-panic thesis holds.** Every generated accessor is total by
  construction (projection / `.clone()` — never index/unwrap/move-out-of-borrow).
- **Visibility honored.** Only `pub` fields/variants/methods ever surface.
- **Go backend untouched.** Shared `FfiGen` Go-glue + `runtime-go` are out of
  boundary; only the Rust inspector + `Rust/Ffi.hs` + Rust codegen change.
- **Coverage measured, not assumed.** `sky-rust-backend:ffi-audit` before/after to
  quantify the surface delta; the inspector `--audit` drop-report tracks what's still
  dropped.
