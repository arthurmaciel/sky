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

## 8. SHIPPED — the Sky-type-rendering consistency fix → fixture 93 end-to-end GREEN

The §7 "remaining gap" is CLOSED. `sky_of_typeref`'s `TypeRef::Ctor` arm now renders a
crate-local OPAQUE generic struct BARE (drops its type args) when the head's last segment is
NOT a known Sky container — matching `resolve_path_to_sky`'s `_`-arm receiver convention. New
helper `is_sky_container_head` (a superset of every with-args arm of `resolve_path_to_sky`:
Vec/Option/Result/SkyResult/SkyTask/Pin/Future/Box/Arc/Rc/Mutex/RwLock/Cell/RefCell/
HashMap/BTreeMap/IndexMap/AHashMap/HashSet/BTreeSet/VecDeque/Cow) guards the known
containers so they keep their type application.

Result: `customize : CreateThing -> Result Error Customizable` (bare) now unifies with
`send_from_customizable : Customizable -> LocalClient -> Task Error Resp` (bare receiver).
Fixture 93 builds+runs `chain=decoded:seed [ALL OK]` under SKY_DCE=0; gate-wired
(`run_customize_chain`, `93-ffi-customize-chain` in ALL_FIXTURES). Full FFI gate **39 ok · 0
fail**; 209 inspector unit tests pass. Guardian-final: APPROVED (CLEAN) — fail-safe by
construction (over-collapse only ever newly-unifies; any genuine downstream mismatch surfaces
as a loud cargo/HM error, never silent-wrong); two non-blocking rewrite-opportunities filed:

1. **Cross-path container-head divergence (pre-existing, out of scope).** `sky_of_typeref`
   renders a container's head literally (`Vec t`, `HashMap k v`) while `resolve_path_to_sky`
   remaps (`List t`, `Dict String v`). Parametric↔parametric agree; a parametric value meeting
   a NON-generic inherent receiver of a container type could mismatch (loud). Separate ticket.
2. **Unify the two head derivations** through one `sky_head_from_ctor_name` helper so submodule
   same-last-segment opaque structs agree by construction (today they'd mismatch loudly — an
   under-fix, not a soundness hole). Separate ticket.

### Still open for the stripe arc (the real-crate proof)

The customize-chain MECHANISM + rendering are proven on the synthetic fixture. The real
async-stripe resource crate still needs its per-resource Cargo feature resolved so
`Create*` builders + `customize` are visible in rustdoc (§2's KEY SCOPING FINDING — the
default surface omits them). Re-measure with the resource feature on, then the real-crate proof.

## 9. Real-crate re-measurement (2026-06-26) — the synthetic framing was WRONG; two real walls

Re-measured `async-stripe-core@1.0.0-rc.6` against the ACTUAL source. Two findings correct the
spec's `.customize()`-chain framing:

### 9.1 The real user chain is `.send()` DIRECT, not `.customize().send()`

`send`/`send_blocking` are **inherent async methods on each request builder** (not on
`CustomizableStripeRequest<T>`):

```rust
impl CreateCustomer {
    pub async fn send<C: StripeClient>(&self, client: &C)
        -> Result<<Self as StripeRequest>::Output, C::Err> { self.customize().send(client).await }
}
impl StripeRequest for CreateCustomer { type Output = stripe_shared::Customer; /* … */ }
```

So the user writes `CreateCustomer::new(id).send(&client).await` → `Customer`. `.customize()`
is an INTERNAL hop, never in the user path. The synthetic fixture 93 proved the customize-chain
mechanism (still valuable — some APIs expose `.customize()`), but the PRIMARY stripe path is the
inherent `send` returning `<Self as StripeRequest>::Output`.

### 9.2 WALL — feature visibility (SHIPPED #89) — `--all-features` is rejected for external deps

`cargo rustdoc -p <external-dep> --all-features` → `error: cannot specify features for packages
outside of workspace`. So the inspector's default path silently degraded EVERY external-crate
audit to DEFAULT features — hiding every feature-gated API (firebase #81 worked around this; it
was the stripe gating issue too). FIX: enumerate the crate's own features via `cargo metadata`
and inject the chosen set through the DEP TABLE (cargo accepts that), preferring `full`
(+`deserialize`/`serialize`). New `enumerate_crate_features` + `choose_visibility_features` in
the inspector; `run_rustdoc` rewrites the probe manifest with the injected set and never passes
`--all-features`. Fail-soft: empty enumeration / mutually-exclusive subset → default build.
RESULT: default `--audit async-stripe-core@1.0.0-rc.6` jumped **92 → 20,358 symbols (3534
bound)** — the whole resource API is now visible with no explicit `--features`. General win for
every feature-gated external crate.

### 9.3 WALL-J (the binding half, TO SCOPE) — inherent-method `<Self as ForeignTrait>::Output`

With the surface visible, `send` drops `not-bindable — undeclared type-var Self`: its return
`Result<<Self as StripeRequest>::Output, C::Err>` carries a `{generic:"Self"}` node, but for an
INHERENT method on `impl CreateCustomer`, `Self` IS the concrete `CreateCustomer`. Binding the
real `send` needs:
1. **Resolve `Self` → the inherent impl's concrete self type** before the type-var collection
   gate (`main.rs` ~7954) drops it. We KNOW it (`self_rust`/`for_val`).
2. **Resolve `<CreateCustomer as StripeRequest>::Output`** via the SIBLING `impl StripeRequest
   for CreateCustomer { type Output = stripe_shared::Customer }` — a DIFFERENT impl block than the
   inherent one being walked. This extends WALL-I's `subst_assoc_json` + `impl_assoc_bindings` to
   look up the assoc binding from a sibling trait-impl keyed by (trait, concrete-Self).
3. **Cross-crate `C: StripeClient`** (WALL-G) — the `StripeClient` impl lives in the facade
   `async-stripe` (`impl StripeClient for stripe::hyper::client::Client`), a DIFFERENT crate.
   Needs the `--manifest` multi-crate run with the facade so WALL-G resolves `C`.
4. **`&self` borrowed receiver + async Send** — #22 owned-copy + WALL-H structural Send on the
   owned `CreateCustomer` (a `#[derive(Clone)]` builder; fields owned → Send).
5. **Return `Customer`** is in `async-stripe-shared` (cross-crate) — big serde struct; binds as a
   JSON String surface (the FFI Result-Ok payload). B8 security still applies (Err → generic msg
   + correlation id).

WALL-J needs a guardian DESIGN before implementation (new sibling-impl assoc resolution +
multi-crate client manifest). It is the genuine terminal stripe wall; multi-session.

## 10. WALL-J guardian DESIGN verdict (2026-06-26): APPROVE-WITH-CONSTRAINTS (B1–B8)

The approach (Self-subst → sibling-trait-impl assoc resolution → cross-crate `C: StripeClient`
via WALL-G `--manifest` → receiver Send → JSON-String return) is the correct terminal wall.
**Composition-safety CONFIRMED SOUND in code:** if the facade is absent from the manifest, `C`
stays a tyvar → `classify_param_bound` returns `Err(UnmodellableBound("StripeClient"))`
(`main.rs:7109`) propagated by `?` (`8191`) → the whole method DROPS. No path emits an
unresolved `<C: StripeClient>`. Every partial failure is fail-closed.

### Constraints (each: property protected → fail-closed condition)
- **B1** — do NOT apply a whole-sig `contains_qualified_path` drop on the inherent path; it would
  wrongly kill `send` on its OWN legit error-slot `<C as StripeClient>::Err` (normalized to
  SkyError at codegen, `7461-7481`). Rely on `type_to_typeref`'s per-position `?` (Ok payload
  `7475`; surviving qualified_path → Err `7550`) + error-slot swallow (`7477`).
- **B2 (soundness hole)** — `subst_assoc_json` (`7298`) keys ONLY on projection NAME (`7303`),
  trait-BLIND. Safe in the trait-impl caller, UNSOUND inherent (a same-named `<Self as
  OtherTrait>::Output` in a payload would mis-resolve). Match the sibling impl by **(trait
  resolved-id, for-type resolved-id)**; require the single foreign-trait payload projection ==
  the matched trait.
- **B3** — gate Self-subst on `collect_generic_names(for_val).is_empty()` (≡ concrete named self,
  `8712`); whole-sig subst on a generic `impl<T> Foo<T>` reinjects unbound `T`. The `8047`
  undeclared-tyvar gate is the backstop.
- **B4** — sibling candidate must be CONCRETE (exclude free-tyvar `for` = blanket impl) AND
  UNIQUE (count==1). Cross-crate sibling → `impl_assoc_bindings` (`8656`) reads THIS crate's
  index → empty → drop. Orphan rule guarantees the real sibling is crate-local.
- **B5** — keep the inherent empty-bound exemption as-is (Q2-A backstop `8200` is
  `trait_ctx.is_some()`-gated). Don't let an inherent foreign-trait-bound tyvar emit bare.
  Negative test: facade absent → `send` dropped.
- **B6 (arch)** — `parse_generic_method_fn`/`try_parametric_stub` lack `for_val`+`index` on the
  inherent path (recv is a rendered STRING). Compute the sibling match + `impl_assoc_bindings` at
  the `route_concrete_method` call site (`1731`, for_val/index/impl_data in scope), mirror
  `TraitCtx.assoc_bindings` (`8588`), pass via a new optional `InherentSelfCtx`. `None` ctx MUST
  be byte-identical to today.
- **B7** — receiver-Send is the `collect_provably_send_recv_names` SYNTHETIC/ALL_FIELDS source
  (`4335`→`4416`), NOT `is_generic_instantiation_send` (`CreateCustomer` has no `<>`). Sound
  fail-closed (Rc-bearing recv → no synthetic Send → drop); verify rustdoc emits a synthetic
  `impl Send` empirically + add an Rc-recv negative fixture.
- **B8 (BLOCKING SECURITY)** — the design assumed "Err → fixed msg + correlation id, server-log
  only" already holds. **It does NOT.** `sky_error_from_foreign` (`runtime-rust/src/sky_runtime/
  core.rs:44`) = `format!("{e:?}").into()` → the RAW foreign Debug becomes the Sky-visible Error
  message. WALL-J is the FIRST wall routing a real network/auth client error (reqwest/hyper
  transport — can echo URL/headers/bearer) through it. The correlation-id machinery (`core.rs:387`)
  is wired ONLY to the panic hook. MUST implement: server-log the Debug under a fresh corr-id,
  return a fixed generic msg + id to Sky. **Subsumes task #83.** (Ok-JSON path does NOT leak the
  API key — `Customer` is the response, the key lives in `&C` — but surfaces PII as plain JSON.)

### Decomposition (ship RED single-crate first, mirror fixture 93)
- **Stage 0 (BLOCKING, do FIRST):** B8 — fix `sky_error_from_foreign` to redact (corr-id +
  server-log). In-boundary `runtime-rust/`; its own guardian-final.
- **Stage 1:** single-crate, sync, non-generic — inherent `fn out(&self) -> <Self as
  LocalTrait>::Output` + `impl LocalTrait for Thing { type Output = Payload }`. Isolates
  Self-subst + sibling-assoc + (trait-id, self-id) match (B2/B3/B4/B6).
- **Stage 2:** + async + `Result<_, ConcreteErr>` — exercises the Send gate (`8244`) + B1 error-slot.
- **Stage 3:** + `<C: LocalClient>` single in-crate impl → then cross-crate via `--manifest`.
- **Stage 4:** real async-stripe behind features (fixtures 89/93 visibility). **Reorder so the
  error-slot (B1) lands BEFORE the cross-crate-`C` work.**

Full memo: guardian memory `rust-ffi-wall-j-inherent-self-output-gate`.

## 11. WALL-J implementation log

### Stage 0 (B8) — SHIPPED (commit a39dc413)
`sky_error_from_foreign` redacts: server-log raw Debug under a corr-id, return only
`external operation failed (ref <8-hex>)`. Guardian-final CLEAN. See PROGRESS 2026-06-26 20:00.

### Stage 1 — sibling-impl `<Self as Trait>::Output` resolution — SHIPPED
Fixture `94-ffi-inherent-self-output` (single crate, sync, non-generic): inherent
`Thing::out(&self) -> <Self as LocalTrait>::Output` + sibling `impl LocalTrait for
Thing { type Output = Payload }`. PRE-fix it rendered the bare assoc name `Output`
(bogus); now `out_from_thing : Thing -> Result Error Payload`, runs `out:seed [ALL OK]`.

Mechanism (inspector): new `resolve_self_assoc_projections` (B3-gated to a concrete
`for_val`) + `subst_self_projections` (trait-AWARE, Self-SCOPED — B2) + `sibling_impl_assoc`
(matches by (trait-id, self-id), concrete + unique — B4; cross-crate sibling → empty
bindings → fail-closed) + `resolved_path_type_id`. Wired at the impl-walk call site
AFTER de-async and BEFORE `method_is_generic_bearing` (B6) — the single seam that
removes the now-concrete `Self` from the used-tyvar set for BOTH the `parse_fn_item`
(non-generic) and the parametric paths, closing the `undeclared type-var Self` drop.
4 unit tests (resolve / generic-self-rejected / missing-sibling / wrong-trait). The
`None`-context path is byte-identical to pre-WALL-J.

### Stage 2+3 — async + `Result<_, C::Err>` + generic `<C: Client>` — SHIPPED (zero extra code)
`95-ffi-inherent-self-output-async` mirrors the real stripe `send` shape in one crate:
inherent `async fn send<C: LocalClient>(&self, c: &C) -> Result<<Self as Req>::Output,
C::Err>` + `impl Req for CreateReq { type Output = Resp }` + a unique `impl LocalClient
for RealClient`. **The SAME Stage-1 resolver composes with no extra inspector code** —
`send_from_createReq : CreateReq -> RealClient -> Task Error Resp` binds + runs
`sent:seed [ALL OK]` under SKY_DCE=0: WALL-J resolves `<Self as Req>::Output`→Resp, #52
mono's `C`→RealClient, `C::Err`→SkyError, de-async→Task, `&self`→owned-copy+Send. This
is the EXACT real-stripe `send` shape; only the cross-crate `C` (the facade's
`impl StripeClient for hyper::Client`) separates it from real stripe — Stage 4, via
`--manifest` + the shipped WALL-G.

Guardian-final on Stages 1-3: APPROVED CLEAN, all B1-B8 honored. Added a 64-deep
recursion bound to `subst_self_projections` (guardian rewrite-opp #1 — defense-in-depth
vs a rustc-impossible self-cyclic assoc; fail-closed on exceed).

### Stage 4 — real async-stripe via multi-crate `--manifest` (NEXT)
The cross-crate `C: StripeClient` resolves via WALL-G from a `--manifest` run including
the facade `async-stripe`. The mechanism is fully proven on 94/95; Stage 4 is the
real-crate manifest assembly + measurement.
