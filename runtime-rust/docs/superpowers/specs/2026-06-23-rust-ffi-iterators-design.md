# Iterators auto-FFI (v1: IntoIterator/Iterator param) — design

**Goal.** Bind a Rust FFI fn that takes an iterator parameter — `impl IntoIterator<Item=T>`,
`impl Iterator<Item=T>`, or a generic `<I: IntoIterator<Item=T>>` / `<I: Iterator<Item=T>>`
— so a Sky `List T` passes across the boundary. Zero hand stubs; sound by construction;
misuse → coverage drop (never a cargo-fail).

**Source of truth for the arc scope:** `runtime-rust/docs/analysis/2026-06-22-universal-ffi-arc-feasibility.md`
§iterators (in-param SOUND for v1; `impl Iterator` RETURN is undecidable-finite → DROP).

## The insight — iterators reduce to a `Vec<T>` param (no new TypeRef)

A Sky `List T` already lowers to Rust `Vec<T>` (`TypeRenderer.hs:156`). A `Vec<T>` IS
`IntoIterator<Item=T>`, so a wrapper that takes `Vec<ItemT>` and passes it to a host param
bounded `impl IntoIterator<Item=T>` type-checks with no extra machinery. Therefore v1 does
NOT add a `TRIterator` TypeRef variant — it converts an iterator-bound param into a plain
`Vec<ItemT>` arg (`TRCtor "Vec" [itemTR]`), the exact shape the codegen + the closure epic's
List arg-lowering already handle. **The whole epic is inspector-side.**

### Two iterator kinds, one call adaptation

| Host param bound | Pass at the call site | Why |
|---|---|---|
| `IntoIterator<Item=T>` | `arg0` (the `Vec` directly) | `Vec<T>: IntoIterator<Item=T>` |
| `Iterator<Item=T>` | `arg0.into_iter()` | `Vec` is not itself an `Iterator`; `.into_iter()` makes one |

This is the only per-kind branch (mirrors the closure epic's by-ref owned-clone bridge).
The inspector records the kind so the wrapper emits the right call form. Both are total —
no panic, no `.unwrap()`.

## What the inspector does (the change)

Today: a CONCRETE-position `impl IntoIterator<Item=X>` is already resolved to `Vec<X>` by
`bound_to_concrete` (`main.rs:6711–6826`, tested `test_into_iterator_u8`/`test_bound_to_concrete_v2`).
A GENERIC-param bound `<I: IntoIterator<Item=T>>` DROPS at `classify_param_bound`
(`main.rs:7111–7148`) as `UnmodellableBound("IntoIterator")`. The closure epic added a
sibling seam (`closure_bound_of` + `classify_closure_param` + `closure_companion_satisfiable`,
`main.rs:7676–7831`) that recognizes a specific trait bound on a USED generic param and
classifies it specially.

The change, modelled exactly on the closure seam:
1. **`iterator_bound_of(bounds) -> Option<(IterKind, &Node)>`** — detect a single
   `IntoIterator`/`Iterator` trait bound on a used param, with only *satisfiable companions*
   (reuse `closure_companion_satisfiable`: `Sized` + lifetime/outlives ONLY — everything else
   → `None` → safe `UnmodellableBound` drop, no under-bind).
2. **`classify_iterator_param(bound, …) -> Result<(IterKind, TypeRef), GenericDrop>`** — read
   the `Item=T` associated-type binding (reuse the existing `Item`-extraction in
   `bound_to_concrete`), resolve `T` through the SAME closed-set `type_to_typeref` resolver the
   closure path uses, and return `(kind, item_typeref)`. The emitted argType is
   `{ctor:"Vec", args:[<item>]}` — NOT a new shape. Record the kind so the call form is chosen.
3. **Wire into `try_parametric_stub`** (where `closure_bound_of` is consulted): an
   iterator-bound param is EXCLUDED from the wrapper's tyvar/`<…>` list (like a closure param)
   — the wrapper takes the concrete `Vec<ItemT>` directly; the `I` tyvar and its `IntoIterator`
   bound vanish. The item's OWN type params (the `T` in `Item=T`) flow as normal tyvars.
4. **Call form** — emit a marker so the Haskell `renderCall` passes `arg0` for `IntoIterator`
   and `arg0.into_iter()` for `Iterator`. Simplest: encode it the same way the closure byRef
   bridge is encoded (a per-arg flag in the `Call`/argType the renderer consults). If
   representing `Iterator`-kind cleanly needs a tiny Haskell touch (a `Bool`/enum on the arg),
   that is in-boundary (`FfiCall.hs`) and additive.

## Soundness (the existential rule: a well-typed Sky program never cargo-fails / never panics)

- **Finite + total.** A Sky `List` is a finite `Vec`; iteration cannot hang. The wrapper adds
  no `.unwrap()`/index/`panic!`. `arg0.into_iter()` is infallible.
- **Bound satisfied by construction.** `Vec<T>: IntoIterator<Item=T>` (std impl) and
  `Vec<T>::into_iter(): Iterator<Item=T>`. The host call type-checks for every concrete T the
  closed-set resolver admits — and every closed-set type is a real Sky type.
- **Companion gate reused.** Only `Sized`+lifetime companions are admitted; `I: IntoIterator + Send`
  etc. → drop (no under-bind → no E0277), exactly the closure-epic fix.
- **Item-unmodellable drop.** If `Item=T` resolves to a non-closed/non-Sky type → drop
  `iterator-item-unmodellable` (coverage report), never a half-bound emission.
- **RETURN position is OUT of v1.** A fn returning `impl Iterator<Item=T>` (or `Iterator`-typed
  return) → drop `iterator-return-undecidable` with a coverage reason. Rationale (feasibility
  doc): rustdoc carries no finiteness metadata; eager `.collect()` on an unbounded iterator
  hangs. v2 may add a per-fn allowlist or a bounded `.take(N)` cap. Not inferred in v1.

## Coverage drop taxonomy (new tags, flow through `emit_generic_coverage`)

`iterator-item-unmodellable` · `iterator-return-undecidable` · `iterator-nonrust-abi`
(host ABI ≠ Rust, mirrors `closure-nonrust-abi`) · `iterator-companion-unsatisfiable`.

## Proof bar

1. **Hand-stub fixture `runtime-rust/tests/sky/50-ffi-iterators/`** — a dependency-free crate
   with: `sum_all<I: IntoIterator<Item=i64>>(xs: I) -> i64`, `count<I: Iterator<Item=i64>>(it: I) -> i64`
   (exercises the `.into_iter()` kind), and a NEGATIVE row (a return-`impl Iterator` fn that must
   DROP, not bind). kernel.json + Main.sky asserting the sums; wired into `ffi-fixtures-test.sh`.
2. **Inspector unit tests** over rustdoc-JSON snippets: `iterator_bound_of` detects both kinds +
   rejects an unsatisfiable companion; `classify_iterator_param` emits `{ctor:Vec,args:[item]}` +
   the right kind; a return-position iterator records `iterator-return-undecidable`.
3. Real-crate generalization is CI-weight (shared with the closures real-crate proof).

## Non-goals (v1)
- Returning iterators. Lazy/streaming iteration. `DoubleEndedIterator`/`ExactSizeIterator`
  specialization. Custom user iterator adapters. Borrowing iterators (`Iterator<Item=&T>` — if
  it arises, route through the closure epic's owned-clone reasoning or drop `iterator-item-borrow`).

## Status
GUARDIAN-CLEARED — APPROVE-WITH-CONSTRAINTS (2026-06-23). The implementation MUST honor the
constraint checklist below (the guardian's soundness contract); the diff gets a separate
guardian-final with the 6 fixtures as the non-vacuous proof bar.

### Guardian constraint checklist (the soundness contract — implement in this order)

- **[C-R] BLOCKING, ships FIRST.** Return-position is NOT drop-complete today: a concrete-return
  `fn f() -> impl IntoIterator<Item=X>` ALREADY binds (`bound_to_concrete` is position-agnostic,
  resolves the return to `Vec<X>`), emitting `-> Vec<X>` over an `impl IntoIterator` body →
  latent E0308 cargo-fail (or, if it collected, the undecidable-finiteness hang). Fix: make
  `IntoIterator`/`Iterator` resolution **position-aware** in `bound_to_concrete`/`resolve_param_bounds`
  — admit in PARAM position only; in `output`/return position return `None` → drop the whole fn,
  tag `iterator-return-undecidable`. Add the failing negative test (binds today = the discovery
  artifact).
- **C1.** Shared iterator tyvar across two params (`zip(a: I, b: I)`) — the name-keyed consume
  must route BOTH arg slots through `classify_iterator_param` (mirror the closure `closure_name`
  filter), both emit `Vec<ItemT>`. Fixture.
- **C2.** A consumed iterator tyvar reused in the RETURN (`-> I`, `-> I::Item`) must DROP
  (automatic via the free-var / qualified-path drop in `type_to_typeref` — assert it).
- **C3.** The `Item=T` type MUST resolve through the param-idx-aware `type_to_typeref`, NEVER
  `concrete_for_inner_type` (the latter doesn't see stub params and mis-handles `{generic:T}`).
  A non-closed/nested-closure/nested-iterator Item → `Err(NotBindable)` → drop.
- **C4.** `iterator_bound_of` admits only a BARE by-value `{generic:I}` param; a `&mut I` /
  borrowed-ref iterator param must NOT match the consume filter → falls to `type_to_typeref` →
  drop. Do NOT add a borrowed-ref-unwrapping branch. Fixture.
- **C5.** v1 admits NO iterator companion beyond `Sized`+lifetime (reuse
  `closure_companion_satisfiable`). `ExactSizeIterator`/`DoubleEndedIterator` deferred (per-kind
  adapter proof is the under-bind trap — record as non-goal with reason). `where I::Item: Ord`
  → `NonGenericPredicate` drop (assert). Over-drop is acceptable; under-drop is forbidden.
- **C6.** The `Iterator`-vs-`IntoIterator` call-form marker (`arg0.into_iter()` vs `arg0`) is an
  UNAVOIDABLE additive Haskell touch in `FfiCall.hs` (an arg-kind flag on the `Call`/argType),
  **default = `IntoIterator`/`arg0`** so an un-tagged arg renders exactly as today; never read by
  the Go pipeline (Go-byte-identity).
- **C7.** Call form is total (no `.unwrap()`/index/`panic!`); no `catch_unwind` needed (no Sky
  closure body crosses — iterating a materialized `Vec` is total). If a future version maps a Sky
  closure inside the wrapper it re-enters the closure epic's `catch_unwind` constraint (out of v1).
- **C8.** `iterator-nonrust-abi` drop mirrors `host_abi_is_rust` (parity).
- **Recognize BOTH** `IntoIterator` AND `Iterator` trait names (the concrete `bound_to_concrete`
  path only knows `IntoIterator`; the bare-`Iterator` generic param is net-new coverage).

### Required proof additions (beyond `sum_all`/`count`/one return row)
1. return-position `impl IntoIterator<Item=i64>` MUST drop [C-R] · 2. shared tyvar `zip(a:I,b:I)`
both emit Vec [C1] · 3. `-> I` / `-> I::Item` MUST drop [C2] · 4. `where I::Item: Ord` MUST drop
[C5] · 5. `&mut I` param MUST drop [C4] · 6. `Item=T` (stub param) binds to `TRParam`, param-aware
[C3].
