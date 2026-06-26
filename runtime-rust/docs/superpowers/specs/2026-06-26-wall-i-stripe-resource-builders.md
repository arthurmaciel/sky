# WALL-I — stripe resource builders + `.customize()` → usable concrete-T `send`

**Status:** SCOPING (measured) — the terminal stripe wall that makes WALL-H's `send` USABLE.
**Epic:** stripe (#70), task #88. Coupled with WALL-H (#87) — WALL-H alone is inert; WALL-I
supplies the concrete `CustomizableStripeRequest<ConcreteResp>` (guardian WALL-H §0 finding).

## 1. Goal

End-to-end "create a Stripe customer from Sky, shim-free":
`CreateCustomer::new(...).customize().send(&client).await` → a usable response. WALL-H ships
the `send` Send-proof for a concrete-T `Customizable<Resp>`; WALL-I must surface the *producer*
chain that yields that concrete-T value.

## 2. Live measurement (2026-06-26, `async-stripe-core@1.0.0-rc.6`, default features)

`--audit async-stripe-core` → bound **17/92** · 75 unbindable. The bound surface is
RESPONSE-type field accessors (`Balance`/`CustomerSession`/`Token` getters/setters,
`TokenId::as_str`, …). **The `Create*` request builders and `.customize()` are NOT in the
default-feature view** (no `customize`/`Create*`/`send` symbols in the crate's default rustdoc).
Drops are dominated by std auto-methods (`borrow`/`into`/`from`/`try_into` — UFCS-unreachable)
+ a couple `undeclared type-var Self` (`begin`/`from_value`, paginator/deser glue).

**KEY SCOPING FINDING:** the per-resource request builders (`CreateCustomer` etc.) are
**feature-gated** in the async-stripe product crates — the default surface omits them. So WALL-I
is gated FIRST on resolving stripe's per-resource Cargo feature flags (which feature exposes
`CreateCustomer` + the `StripeRequest` impl), then on the binding chain.

## 3. The WALL-I obstacles (to confirm once features are resolved)

1. **Feature-flag surfacing.** Identify the feature(s) that expose the request builders
   (`async-stripe-core` resource features). The inspector defaults to all-features but
   async-stripe's features may be mutually-exclusive (the runtime-client features were), so a
   curated feature set per probe is likely needed. Re-measure WITH the resource feature on.
2. **`.customize()` is a PROVIDED trait method** on `StripeRequest` (id 321, returns
   `CustomizableStripeRequest<Self::Output>`). For a concrete resource `X: StripeRequest`,
   `customize` should project onto `X` via WALL-F's `project_trait_default_methods` (already
   shipped) — CONFIRM it fires for a concrete (non-mono'd) resource Self, and that `Self::Output`
   resolves to the concrete response type (so `send`'s T is concrete → WALL-H binds it).
3. **Resource builder ctor + fields.** `CreateCustomer::new(...)` + its `with_*` setters
   (builder pattern). Likely the #67 owned-String-ctor + field-setter machinery already covers
   these; CONFIRM via the re-measure.
4. **`Self::Output` assoc-type resolution.** `customize` returns `CustomizableStripeRequest<
   Self::Output>`; binding it needs `Self::Output` (the resource's associated response type)
   resolved to the concrete `Customer`/`Charge`/… so WALL-H's concrete-T `send` applies.

## 4. Next steps (the disciplined order)

1. Resolve the feature flag → re-measure a resource crate WITH builders visible → real drop
   histogram for `CreateCustomer`/`customize`/`send`.
2. Build a synthetic fixture extending `92` with a provided-trait-method `.customize()` producer
   (a `Req: WireReq` whose `customize()` returns `Customizable<Resp>`), to test whether WALL-F
   projection + WALL-H send compose into the full `new().customize().send()` chain WITHOUT real
   stripe — decoupling the mechanism proof from the feature archaeology.
3. Then the real-crate proof once features + builders are visible.

## 5. What WALL-H already gives WALL-I

The hard async-Send mechanics are DONE: WALL-G (cross-crate unique-impl mono) + WALL-H
(structural conditional-Send for a generic-instantiation receiver/output). Once `customize()`
yields a concrete `Customizable<ConcreteResp>` and `Customizable` is Send-when-args-Send (it is —
the stripe struct is PhantomData/owned-field), `send` binds by the shipped WALL-H path. WALL-I
is therefore mostly PRODUCER plumbing (features + provided-method projection + Output resolution),
not new Send/async mechanics.

## 6. Refinement (2026-06-26, customize-chain construction attempt) — it is NOT "mostly plumbing"

Attempted to add the `customize()` producer to fixture 92's req-crate. Construction revealed
WALL-I's customize-chain is a DISTINCT REGIME, not plumbing over the shipped mechanics:

1. **Orphan rule.** `customize` is a PROVIDED method on `WireReq` (the `StripeRequest` analog).
   To exercise projection it needs `impl WireReq for CreateThing { type Output = … }`. Both
   `WireReq` and `CreateThing` are req-crate-local, so the impl MUST live in req-crate — its
   `Output` therefore can't be the cross-crate `Resp` (client-crate) without a 3rd crate or
   moving `Resp`. The real stripe shape sidesteps this (resource + its `StripeRequest` impl +
   the response type co-locate in one product crate), so the synthetic must mirror that:
   `Decode`-type + resource + `WireReq` impl all in ONE crate.
2. **Multi-impl-Decode breaks the shipped T-mono.** Fixture 92's `send` GREEN relies on `Decode`
   being UNIQUE-impl (T mono's to `Resp` via WALL-G). A second `Decode` type (the resource's
   `Output`) makes Decode multi-impl → T no longer mono's. So `Customizable<ConcreteResp>` in the
   chain arises NOT from T-mono but from `customize()` returning `Customizable<Self::Output>`
   with `Self::Output` resolved to a concrete — a NEW mechanism (concrete-instantiation-via-
   associated-type-return), distinct from the unique-impl-decode T-mono WALL-H shipped.
3. **Therefore:** WALL-I needs its OWN fixture (`93-ffi-customize-chain`, single-crate resource +
   WireReq-impl + Output co-located) and a NEW mechanism: (a) project a PROVIDED trait method
   (`customize`) onto a concrete resource Self (WALL-F's `project_trait_default_methods` may
   fire — CONFIRM), (b) resolve `Self::Output` to the concrete response type, (c) recognise the
   returned concrete `Customizable<ConcreteResp>` and bind `send` on it (WALL-H's Send-proof
   applies to the concrete instantiation, but the instantiation must be SEEN — it comes from the
   assoc-type return, not a T-mono). This corrects §5's "mostly plumbing" — the Send/async
   mechanics are reused, but the PRODUCER recognition (provided-method + assoc-type-return) is new.

**Next-session order:** build `93-ffi-customize-chain` (single-crate) RED → confirm whether
`customize` projects + `Self::Output` resolves today (probe) → implement the gap → GREEN under
SKY_DCE=0 → then the feature-gated real-stripe resource crate.

## 7. SHIPPED — the customize-chain MECHANISM (provided-method projection + Self::Output)

Fixture `93-ffi-customize-chain` (single thing-crate). Implemented + verified at the inspector
level the producer mechanism:
1. **Concrete-Self provided-method projection.** Relaxed the WALL-F projection gate
   (`main.rs` ~1691) from `self_mono_subst.is_some()` to ALSO project onto an already-CONCRETE
   trait impl (`impl WireReq for CreateThing`). Bounded: `project_trait_default_methods` is
   fail-closed to crate-local trait DEFS (a std trait's def isn't in `index`).
2. **`Self::Output` resolution** via `subst_assoc_json` + `impl_assoc_bindings` (`type Output
   = Resp`), so `customize(self) -> Customizable<Self::Output>` → `Customizable<Resp>`.
3. **Trivially-true Self-bound strip** (`where Self: Sized` → `where CreateThing: Sized`, a
   non-generic predicate the bound resolver rejected).

Result: the full chain BINDS at the skyi level —
`customize : CreateThing -> Result Error (Customizable Resp)`; full FFI gate **38 ok · 0 fail**
(no regression); 209 unit tests.

### Remaining gap (one separable Sky-type-rendering consistency)

`customize`'s return renders `Customizable<Resp>` PARAMETRICALLY (`Customizable Resp`, the
parametric-stub return path keeps the arg), but `send`'s RECEIVER renders the SAME type as the
bare opaque `Customizable` (#45 generic-Self-mono `self_sky`). Sky HM can't unify them →
`Variable 'cust' type mismatch`. Fix: render a crate-local generic-struct INSTANTIATION
consistently across return + receiver. `resolve_path_to_sky`'s `_` arm already renders it BARE
(drops args); the parametric-stub return path does not. Contained codegen fix (next session).
Fixture 93 committed but NOT gate-wired (RED on this consistency until the fix lands).
