# Trait methods on concrete foreign types (auto-FFI #21) — design

**Goal.** Bind a method that comes from a `impl SomeTrait for ConcreteType { … }` block
(generic OR non-generic), so Sky code can call it. Today non-generic trait methods already
bind via `parse_fn_item`; GENERIC trait methods drop (the parametric-stub path is gated to
INHERENT impls at `main.rs:923-926` with the reason "a trait impl's method bounds can come
from the trait — out of scope"). Display/FromStr are already bridged specially — do NOT regress
them.

> **Note (line anchors are stale).** Every `main.rs:NNN` / `:NNNN` reference
> below is as-of-2026-06-23 and no longer points at the cited code —
> `tools/sky-ffi-inspect-rs/src/main.rs` has since grown past 16k lines and this
> design has shipped. Locate the code by the named symbols
> (`try_parametric_stub`, `parse_fn_item`, `is_inherent_impl` /
> `trait_self_concrete`, `self_sky.is_empty()`, `full_union_bounds`,
> `self_public_path`), not the line numbers.

## Scope (v1)

> **SUPERSEDED — see Status Q2.** The "bound resolves … method-local" framing
> below is the naive design the guardian ruling overturned: a bound restated
> bare on the impl can have its definition on the TRAIT, so resolution must also
> union the trait-def method's bounds (Q2-A). Shipped code does this via
> `full_union_bounds` + `trait_def_generics`.

**In:** a method on `impl Trait for ConcreteType` (concrete `Self`, not a blanket/generic impl),
generic or not, whose every method-level generic bound resolves to the existing
modellable proof (closed-set / `{Hash,Eq,Ord,Clone,Default}`), and whose arg/return/assoc types
resolve through the existing `type_to_typeref`/`bound_to_concrete`. Receivers `&self` / `&mut self`
/ `self`-by-value already handled by `parse_fn_item` (`main.rs:2171-2189`) — reuse.

**Out (drop with a coverage reason, never a cargo-fail):**
- Blanket/generic impls (`impl<T> Trait for T`, `impl Trait for Vec<T>` where the Self type is
  itself generic) → `trait-method-generic-self`.
- A method generic whose bound is trait-level / cross-impl and NOT repeated on the method
  signature, i.e. unresolvable from the impl+method rustdoc → `trait-method-bound-cross-impl`.
- An associated type in the method sig that the impl does not bind concretely →
  `trait-method-assoc-unresolved`.
- A super-trait / where-clause on the TRAIT the impl can't satisfy locally → same drop class.
- Closures/iterators in a trait-method arg — already routed through the #28/#30 seams; if those
  don't bind, the existing drop applies.

## The call form — UFCS (the one real codegen decision)

A trait method must be called so the trait is unambiguously in scope and no `use` is needed.
Emit **fully-qualified UFCS**: `<::crate::ConcreteType as ::crate::path::Trait>::method(recv, args…)`.
This:
- never needs a `use Trait;` (the kernel.json/codegen can't easily inject imports),
- can never be ambiguous with an inherent method of the same name,
- works for every receiver kind (`recv` is the first arg in UFCS).

The inspector already emits a `Call` with `kind` ∈ {`CallMethod`, `CallFunction`} (`FfiCall.hs`).
A trait method is emitted as a `CallFunction` whose `path` is the UFCS qualified form and whose
first arg is the receiver. If representing the `<Self as Trait>` qualifier needs a small additive
field on the `Call` (e.g. `traitQualifier : Option (selfPath, traitPath)`), that is in-boundary
(`FfiCall.hs`) and additive — default `None` renders exactly as today (Go-byte-identical; Go's
pipeline never reads it).

## What the inspector changes (`tools/sky-ffi-inspect-rs`)

1. **Lift the inherent-only gate** (`main.rs:923-926`): attempt the parametric-stub path for a
   trait impl too, BUT only when `Self` is concrete (a named type, not a type-var) — else drop
   `trait-method-generic-self`.
2. **Bound resolution stays method-local + impl-local.** *(SUPERSEDED — see Status Q2.
   This step is factually wrong: rustdoc does NOT inline trait-def bounds onto the impl-method
   sig, so method-local resolution is unsound. Shipped behaviour adds the trait-def bound union,
   Q2-A — `full_union_bounds` + `trait_def_generics`.)* Collect the method's own generics +
   where-clauses (rustdoc inlines a method's where-clauses on the method sig) + the impl block's
   concrete trait type-args (`impl From<i64> for Foo` → the trait param resolves to `i64`). Run the
   SAME modellable/closed-set gate the inherent path uses. A method type-param used but with no
   resolvable bound in this scope → drop `trait-method-bound-cross-impl` (conservative; no
   under-bind). This is the precise lifting of the old "out of scope" punt — it becomes a per-method
   resolvable/drop decision, not a blanket skip.
3. **Associated-type resolution (concrete-only).** If the method sig references `Self::Assoc`
   (or the trait's assoc type), resolve it via the impl's `type Assoc = Concrete;` binding (rustdoc
   carries the impl's assoc-type items). Resolvable + closed → use the concrete TypeRef; else drop
   `trait-method-assoc-unresolved`. No projection inference — direct lookup only.
4. **Emit the UFCS qualifier** (selfPath + traitPath, both fully-qualified `::crate::…`) so the
   codegen renders `<Self as Trait>::method(...)`.
5. **Do NOT touch the Display/FromStr bridge path** (`main.rs:888-894,1140`) — those stay as the
   special synthetic bridges; a generic trait method binding is additive alongside them.
6. **Coverage tags** flow through `emit_generic_coverage`: `trait-method-generic-self`,
   `trait-method-bound-cross-impl`, `trait-method-assoc-unresolved`, `trait-method-nonrust-abi`.

## Soundness (the existential rule)

- **The UFCS call always compiles IF the impl exists** — and the inspector only emits it for an impl
  it actually read from the crate's rustdoc, so the impl provably exists. No invented call.
- **Every bound is resolved to a positive modellable proof before emit** (the same gate that makes
  the inherent generic path sound). An unresolvable bound → drop, never a `<T: ???>` emit → no
  E0277. Over-drop is acceptable; under-bind is forbidden.
- **Concrete `Self` only** → the wrapper's receiver type is a concrete `::crate::Type`, never a
  type-var the monomorphiser can't pin. (Reuses the closed-set receiver handling.)
- **Assoc types resolved by direct impl-binding lookup**, never inferred → no phantom type.
- **Receivers** reuse the proven `parse_fn_item` self-handling; `&mut self` is as sound as it is for
  an inherent `&mut self` method (the runtime owns the value across the call).
- **No new panic surface.** A trait method that takes a closure re-enters the #28 `catch_unwind`
  boundary; otherwise the wrapper is the same total shape as an inherent-method wrapper.

## Proof bar

1. **Hand-stub fixture `runtime-rust/tests/sky/51-ffi-trait-methods/`** — a dep-free crate with:
   - a NON-generic trait method (`trait Area { fn area(&self) -> f64; } impl Area for Circle`),
   - a GENERIC trait method (`trait Scale { fn scaled<T: Into<f64>>(&self, k: T) -> f64; }` or a
     simpler `fn repeat(&self, n: i64) -> String` on a custom trait — pick a method-local-bound shape
     that exercises the lifted gate),
   - an associated-type method that RESOLVES (`impl Iterator`-free; e.g. `trait Pair { type A; fn first(&self) -> Self::A; }`
     with `type A = i64;`),
   - NEGATIVE rows that must DROP: a blanket `impl<T> Trait for T`, and a method with a cross-impl
     unresolved bound.
   - kernel.json + Main.sky asserting the concrete results; UFCS call form in the emitted wrapper.
2. **Inspector unit tests** over rustdoc-JSON snippets: trait-impl method now binds (was dropped);
   blanket impl drops; cross-impl-bound method drops; assoc-type resolves via impl binding; the
   emitted `Call` carries the UFCS qualifier.
3. Real-crate generalization is CI-weight (shared tail).

## Non-goals (v1)
- Blanket/generic-Self impls. Trait objects (`dyn Trait` — that's the trait-objects arc item).
- Default trait method bodies the impl does NOT override (rustdoc may or may not surface them;
  bind only impl-present methods). Super-trait method inheritance beyond what the impl surfaces.
- Operator traits as operators (bind `Add::add` as a normal method if it meets the gate, but do not
  synthesise Sky operator sugar). Const-generic method params.

## Status
GUARDIAN-CLEARED — APPROVE-WITH-CONSTRAINTS (2026-06-23). **Q2 ruling overrides the spec body:**
method-local bound resolution is UNSOUND. rustdoc does NOT inline trait-def bounds onto impl-method
sigs — an impl may restate `fn scaled<T>` bare while the bound `T: Into<f64>` lives on the trait
DEFINITION. The inspector at the impl site sees empty bounds and cannot distinguish "genuinely
unbounded free tyvar" from "bound lives on the trait def"; emitting `<T>` then → E0277 at the host
call. Implement **Q2-A** (resolve the trait def by id, union its method generics' bounds/where-preds
into the modellable gate) — the only path that BINDS the common bound-on-trait-def shape, and it
composes with #25's id-based path resolution.

### Guardian constraint checklist (the soundness contract — implement in this order)

1. **[Q2 — THE gate] Resolve trait-definition bounds (Q2-A).** When the impl is a trait impl, look
   up the trait item by `impl.trait.id` in the rustdoc index, find the method by name in the trait's
   `items`, and UNION the trait-def method's `generics` (param bounds + `where_predicates`) into the
   bound set BEFORE the existing modellable/closed-set gate. Then a bare-restated `<T>` whose bound
   is `Into<f64>` on the trait resolves (sound emit) or drops (sound over-drop). **NEVER emit a `<T>`
   with empty resolved bounds for a trait impl** — if the trait def can't be resolved or the unioned
   bound is unresolvable, drop `trait-method-bound-cross-impl`. (Q2-B floor — drop ALL empty-bound
   trait-impl method generics — is the fallback ONLY if trait-def lookup proves intractable; it
   over-drops the common case.)
2. **Trait-def bounds mentioning `Self::Assoc`/`Self`/a non-closed-set trait → drop** (route through
   the same `resolve_param_bounds` closed-set gate; over-drop is correct, never mis-resolve).
3. **[C-Q1a / #25] Build the UFCS trait qualifier from the trait's rustdoc `id` → resolved PUBLIC
   path, NEVER the last-segment/display string** (`main.rs:917` reads `t.name`/`t.path` — the
   last-segment hazard #25 tracks). A trait whose canonical path is private/unreachable → drop
   `trait-method-trait-unreachable`. This closes the call-path half of #25; reuse/extend the existing
   type-path qualification (`main.rs:1176-1181`).
4. **[C-Q1b] Method-level generics monomorphised away (no method turbofish), OR a new UFCS render
   arm** — do NOT reuse `_call_assocOnType` turbofish placement (it sits on the TYPE path,
   `Type::<T>::method`, wrong for method-level type-args which go `<Type as Trait>::method::<G>`).
5. **[C-Q1c] Self path = concrete reachable `::crate::Type`** via the existing qualification; never
   bare `Self`.
6. **[Q3] Assoc type absent from the IMPL's bindings → drop `trait-method-assoc-unresolved`.** Verify
   direct lookup returns `None` for defaulted-on-trait assoc types (don't silently pick a trait
   default → E0220/phantom).
7. **[C-Q4] `&mut self` trait method threads the receiver by `RefMut` in the UFCS first-arg slot**
   (reuse `renderBy (_recv_by r)`); a UFCS call passing the receiver by value when the method wants
   `&mut self` is E0308. Parity with inherent `&mut self` (no new aliasing surface).
8. **[C-Q5] Display/FromStr non-regression** — a Display impl → exactly ONE binding (the existing
   `to_string` bridge), ZERO `fmt` UFCS emission (`fmt` takes `&mut Formatter`, unnameable →
   arg-gate drops it; assert it in the fixture).
9. **[C-Q6] New `Call` field skip-serializes when `None`; golden-JSON diff on `48-ffi-generics`
   proves byte-identity** for non-trait methods.
10. **[ABI] Non-Rust-ABI host trait method → drop `trait-method-nonrust-abi`** (wire through
    `host_abi_is_rust`).
11. **[Concrete-Self gate] Drop `trait-method-generic-self` when the impl `for` type is a type-var or
    carries free type-vars** (`impl<T> Trait for T`, `impl Trait for Vec<T>`). `self_sky.is_empty()`
    (`main.rs:909`) is NOT sufficient — `Vec<T>` renders non-empty. Add an explicit "Self is a
    concrete named type with NO free type-vars" check.
12. **[Regression fixture — the one that sinks the naive design]** `51-ffi-trait-methods` MUST include
    a generic trait method whose bound is declared ONLY on the trait def and restated BARE in the impl
    (`trait Scale { fn scaled<T: Into<f64>>(…); } impl Scale for Circle { fn scaled<T>(…) }`). Under
    Q2-A it BINDS; the spec-as-written would CARGO-FAIL. Without this row a green sweep hides the hole.

### Guardian rewrite-opportunities folded in
- The UFCS qualifier (constraint 3) is built id-first → closes the call-path half of **#25**; the
  broader #25 (last-segment in modellability checks at `:3580/:3671/:3812`) may close in the same pass
  or stay a follow-up.
- Consider a `BoundSource::{Inherent, TraitImpl(trait_id)}` enum threaded into `resolve_generics` so
  the empty-bounds branch is total-by-construction (Inherent → free tyvar OK; TraitImpl → resolve via
  trait def or drop) — makes constraint 1 a type-level invariant, not a remembered rule.
