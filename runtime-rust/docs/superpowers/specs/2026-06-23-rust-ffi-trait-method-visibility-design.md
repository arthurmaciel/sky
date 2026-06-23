# Ungate trait-impl methods on real crates (#31) — delivers #21 end-to-end

**Problem (guardian-found, #21 final).** #21's UFCS trait-method binding is sound but INERT on real
crates. A pre-existing visibility gate — `is_public` (`tools/sky-ffi-inspect-rs/src/main.rs:1391`,
from `751dade5`, predates #21) — requires the method item's `visibility == "public"` and drops it at
~`main.rs:962` otherwise. **Trait-impl method items carry `visibility: "default"`** (a trait method
inherits the trait's visibility; it is never written `pub` in the impl), so EVERY trait method drops
before any #21 code runs. The hand-stub `51-ffi-trait-methods` fixture is the only exerciser today.

## The fix — visibility for a trait-impl method defers to trait+Self reachability

The method-level `visibility` field is the WRONG gate for a trait-impl method: it is structurally
always `"default"` even when the method is fully callable. The CORRECT callability test for
`<::crate::Type as ::crate::Trait>::method(...)` is: **the trait is public+reachable AND the Self type
is public+reachable** — exactly what #21's `build_trait_ctx` / `reachable_local_path` already compute
(a private/unreachable trait or Self already drops `trait-method-trait-unreachable` /
`trait-method-generic-self`). So:

- **Trait impl:** SKIP the method-level `is_public` check; rely on the trait-reachable + Self-reachable
  gates (already enforced) + the existing per-signature `fn_types_nameable` reachability (a method
  whose arg/return references a private type still drops → no E0603). The method's own `"default"`
  visibility is ignored — it carries no callability information for a trait method.
- **Inherent impl:** UNCHANGED. An inherent-impl method without `pub` is genuinely private; its
  `"default"` visibility correctly drops it. The relaxation is scoped to `trait_name.is_some()` only.

## Folded-in: the latent parametric-Self non-generic E0599 (guardian follow-up #1)

A NON-generic trait method on a concrete-but-parametric Self (`impl Area for Holder<i64>`, method
`area(&self)`) routes through `parse_fn_item` (`main.rs:998`), not the parametric-stub path, so the
`self_is_concrete_named` angle-bracket-args gate (which lives on the parametric path) does NOT apply.
It would emit a `traitQualifier=None` Function → `::tm::Holder::area(&arg0)` (method-call form) →
**E0599** (a trait method isn't callable as an inherent method, and `Holder` is missing its `<i64>`).
The `eb1a9d10` comment claiming it "drops via the nameability filter (free tyvar)" is FALSE —
`Holder<i64>` has no free tyvar and is nameable. Doubly unreachable today (gated by `is_public` +
absent from the hand stub) but BECOMES REACHABLE once the visibility gate is relaxed. **Fix:** in the
non-generic `parse_fn_item` trait-method path (the line-982 block), apply the SAME concrete-Self gate
— a trait method whose Self carries angle-bracket args OR free type-vars → DROP
`trait-method-generic-self`. v1 binds only a bare non-generic named Self via UFCS, on BOTH the generic
and non-generic paths. (Parametric-Self trait methods are a later epic.)

## Soundness (adversarial — this is the first time real trait bindings flow end-to-end)

- **What the relaxation surfaces.** Only methods of a public+reachable trait on a public+reachable
  concrete bare-named Self, whose entire signature is nameable+reachable. Each such method's UFCS call
  `<Type as Trait>::method` compiles because the impl provably exists in the crate's rustdoc and both
  qualifier paths are reachable.
- **What stays dropped (no new cargo-fail surface).** A method whose signature references a private
  type (`fn_types_nameable` drop); a method on a parametric/generic Self (concrete-Self gate, now on
  both paths); a generic method whose bound is unresolvable (Q2-A backstop); an assoc-type not bound
  by the impl; a non-Rust-ABI host; a `&mut Formatter` (`fmt`) method.
- **Over-drop remains acceptable; under-bind remains forbidden.** The change only ADMITS trait-impl
  methods that already pass every OTHER reachability/modellability gate — it does not weaken any of
  those gates. It cannot admit a method those gates would reject.
- **Inherent-method behavior is byte-identical** (the relaxation is `trait_name.is_some()`-scoped).

## Adversarial cases the proof MUST cover
1. A public trait + public type, public-callable method → now BINDS (was dropped). [the delivery]
2. A method of a public trait whose signature references a PRIVATE type → still DROPS (nameability).
3. An impl of a PRIVATE trait for a public type → DROPS (trait-unreachable).
4. A trait method on a parametric Self `Holder<i64>` (non-generic method) → DROPS (the folded E0599
   fix), not an E0599 emission.
5. An inherent-impl private (`"default"`, no `pub`) method → STILL DROPS (relaxation not applied).
6. Display/FromStr still bridge-only (no `fmt` surfacing through the relaxed gate).

## Proof bar (the real-inspector path — this is what makes #21 non-inert)
- **Promote `51-ffi-trait-methods` (or a new `51b`) to a REAL-inspector fixture**: run the actual
  `sky add`/inspector (`cargo +nightly rustdoc` JSON) against the `tm` crate so the trait methods are
  emitted BY THE INSPECTOR (not the hand stub), and the UFCS wrappers compile + run `[ALL OK]`. This
  is the end-to-end proof the hand stub can't give. The full real-crate build is CI-weight; locally,
  assert the gate via inspector UNIT tests over rustdoc-JSON snippets (a `"default"`-visibility
  trait-impl method on a public trait+type now passes the gate; cases 2-5 drop), and ONE real-inspector
  fixture build if disk allows.
- Inspector unit tests for all 6 adversarial cases.

## Non-goals
- Parametric-Self trait methods (`Holder<i64>::area`) — dropped in v1, a later epic.
- `pub(crate)`/`pub(super)` restricted visibility nuance — treat non-`public` non-trait-impl as private
  (current behavior); a trait-impl method of a `pub` trait is callable regardless.
- Default trait method bodies the impl doesn't override.

## Status
GUARDIAN-CLEARED — APPROVE-WITH-CONSTRAINTS (2026-06-23). C-1 + C-4 are BLOCKING. The guardian found
the spec's claim "a private trait already drops `trait-method-trait-unreachable`" is FALSE — that tag
does not exist, and `build_trait_ctx` returning `None` is forwarded as `trait_qualifier=None` →
inherent-call form on a trait method → E0599/E0603. The relaxation MUST add the missing drop.

### Guardian constraint checklist (implementation contract)
1. **[C-1 BLOCKING] `build_trait_ctx == None` for a concrete trait method MUST become a new
   `TraitMethodDropTag::TraitUnreachable` drop on BOTH routing arms** (the parametric-stub path AND the
   non-generic `parse_fn_item` path). NEVER emit `trait_qualifier=None` for a concrete trait method.
   Implement via the `BoundSource::{Inherent, TraitImpl{trait_id}}` enum so "a trait method with no
   qualifier" is unrepresentable (the `None`-means-drop vs `None`-means-emit-bare ambiguity is the
   root cause). This is the `pub(crate)` trait hazard: a `pub(crate)` trait on a public Self →
   trait id absent from `REACHABLE_PATHS` → `build_trait_ctx None` → today emits inherent form → E0603.
2. **[C-3] Fold the non-generic concrete-Self gate.** The `parse_fn_item` non-generic trait-method path
   (~982-998) gets the SAME `self_is_concrete_named` gate (angle-bracket-args + free-tyvar) as the
   parametric path → `Holder<i64>::area` drops `trait-method-generic-self`, never an E0599 inherent emit.
   Cover both `&self` and `self`-by-value.
3. **[Relaxation] Skip the method-level `is_public` check ONLY for `trait_name.is_some()`** (a trait
   impl); inherent-impl methods unchanged (byte-identical, including a genuinely-private `"default"`
   method still dropping). Rely on: trait-reachable (C-1 drop), Self-reachable (`REACHABLE_PATHS`,
   public-modules-only — a `pub(crate)` Self renders bare → `fn_types_nameable` drop), per-signature
   `fn_types_nameable` (private type in sig → drop). These gates fire INDEPENDENTLY of `is_public`
   (guardian-confirmed for 6 of 7 reasons; the 7th is C-1).
4. **[C-4 BLOCKING] Real-inspector proof fixture (`51b` or promote `51`).** Run the ACTUAL inspector
   (`cargo +nightly rustdoc` JSON) against the `tm` crate so trait methods are emitted BY THE INSPECTOR,
   UFCS wrappers compile+run `[ALL OK]`. MUST include a `pub(crate) trait` row asserting ZERO binding +
   the `TraitUnreachable` drop (the hand stub can't exercise it). Full real-crate build is CI-weight;
   locally assert via inspector unit tests + ONE fixture build if disk allows.
5. **[C-7] Inherent byte-identity** — golden-JSON diff on `48-ffi-generics`; the relaxation must not
   change any inherent-method or non-trait emission.
6. **Adversarial unit tests (all 6 spec cases + the guardian's):** public-trait/public-type method
   BINDS (the delivery) · private-type-in-sig DROPS (nameability) · `pub(crate)` TRAIT DROPS
   (TraitUnreachable, C-1) · `pub(crate)` SELF DROPS (nameability) · parametric Self `Holder<i64>`
   non-generic DROPS (C-3) · inherent private `"default"` DROPS (relaxation not applied) · blanket
   `impl<T> Foo for T` DROPS (concrete-Self) · Display still bridge-only.

### Guardian rewrite-opportunities folded in
- `build_trait_ctx`'s `Option<TraitCtx>` where `None` means "drop" but the caller emits-bare is the
  root smell → replace with `Result<_, GenericDrop>` / the `BoundSource` enum so the illegal state is
  unrepresentable. Fix the now-false `build_trait_ctx` doc-comment once C-1 lands.
