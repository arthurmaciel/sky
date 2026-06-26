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
