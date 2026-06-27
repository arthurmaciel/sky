# WALL-F design — firebase CRUD binds shim-free (#81)

**Goal.** Make `create_user` / `get_user` / `get_users` / `list_users` /
`delete_user` / `update_user` on rs-firebase-admin-sdk 4.3.0 BIND shim-free, so a
Sky program can `App::emulated() → app.auth(url) → fauth.create_user(newUser)`.

**Status of the surrounding surface (measured 2026-06-26, post-WALL-E).** firebase
bound surface cargo-builds clean (0 errors, SKY_DCE=0). `App::emulated()` (ctor),
`App::auth()` (returns the CONCRETE `FirebaseAuth<ReqwestApiClient>`), and the
`NewUser`/`UserIdentifiers`/`UserUpdateBuilder` struct surface already bind. The
ONLY missing piece for end-to-end CRUD is the auth-service methods themselves.

## The exact shape (confirmed against the crate source)

```rust
// client/mod.rs
pub trait ApiHttpClient: Send + Sync + 'static { … }
impl ApiHttpClient for ReqwestApiClient { … }      // ← UNIQUE concrete impl

// auth/mod.rs
pub trait FirebaseAuthService<C: ApiHttpClient>: Send + Sync + 'static {
    fn get_client(&self) -> &C;                              // required
    fn get_auth_uri_builder(&self) -> &ApiUriBuilder;        // required
    fn create_user(&self, user: NewUser)
        -> impl Future<Output = Result<User, Report<ApiClientError>>> + Send { … }   // DEFAULT body
    fn get_user(&self, ids: UserIdentifiers)
        -> impl Future<Output = Result<Option<User>, Report<ApiClientError>>> + Send { … }  // DEFAULT
    fn get_users(…)  -> impl Future<… Result<Option<Vec<User>>, …>> + Send { … }     // DEFAULT
    fn list_users(…) -> impl Future<…> + Send { … }                                   // DEFAULT
    // …delete_user / update_user / etc., all DEFAULT bodies.
}
pub struct FirebaseAuth<ApiHttpClientT> { … }
impl<ApiHttpClientT> FirebaseAuthService<ApiHttpClientT> for FirebaseAuth<ApiHttpClientT>
    where ApiHttpClientT: ApiHttpClient { … }    // provides ONLY get_client/get_auth_uri_builder

// lib.rs — the entry the user actually holds:
impl App<EmulatorCredentials> { pub fn auth(&self, url: String) -> FirebaseAuth<ReqwestApiClient> { … } }
impl App<AccessTokenCredentials> { pub fn auth(&self) -> FirebaseAuth<ReqwestApiClient> { … } }
```

## Why each CRUD method currently DROPS

1. The impl `for FirebaseAuth<ApiHttpClientT>` has a free impl-generic Self var.
   `trait_self_concrete` (main.rs:1554 — `self_is_concrete_named || self_is_closed_monomorphic`)
   is FALSE → the drop at main.rs:1711 fires `trait-method-generic-self:
   non-concrete Self FirebaseAuth<ApiHttpClientT>` for every method walked under it.
2. SEPARATELY, `create_user`/`get_user`/… are **default trait methods** with bodies
   on the trait DEF. rustdoc lists them under the TRAIT item's `items`, NOT under
   the `impl … for FirebaseAuth` block's `items` (which lists only the two REQUIRED
   methods the impl overrides). So the inspector — which walks `impl_data["items"]`
   — never even SEES create_user/get_user for this Self. (Confirmed: the coverage
   report shows only get_client/get_auth_uri_builder on FirebaseAuth, never
   create_user.)

So binding CRUD needs BOTH (a) a concrete Self AND (b) default-method projection.

## Approach (two mechanisms, both fail-closed)

### (a) Unique-impl Self monomorphization — extends #52

`#52`/`monomorphize_concrete_impl_params` already substitutes a METHOD's generic
param `C: Trait` (single non-modellable crate-local trait, exactly ONE concrete
impl) to that concrete, via `single_concrete_impl_trait_key` +
`concrete_for_unique_impl` (keyed on `TRAIT_CONCRETE_IMPLS`). Extend that to the
IMPL-BLOCK's Self generic param:

- Detect Self = `Struct<P>` where `P` is an impl-generic param whose bound set is
  exactly one unique-impl crate-local trait (here `ApiHttpClientT: ApiHttpClient`,
  unique impl `ReqwestApiClient`).
- Substitute `P → ReqwestApiClient` everywhere it occurs (the Self type node + every
  method-sig position), yielding the concrete `FirebaseAuth<ReqwestApiClient>`.
- Set `trait_self_concrete = true` for the rewritten Self so the method flows the
  concrete-Self trait (UFCS) path. The UFCS qualifier becomes
  `<…::FirebaseAuth<…::ReqwestApiClient> as …::FirebaseAuthService<…::ReqwestApiClient>>::create_user`
  — the trait's own generic arg `C` is the SAME param, so it monomorphizes to the
  same concrete.
- FAIL-CLOSED: 0 or >1 `ApiHttpClient` impls → no substitution → keep the
  `trait-method-generic-self` drop (today's behaviour). Param bounded by a
  modellable/serde/external trait, or >1 bound → not our shape → drop.

### (b) Trait default-method projection onto a concrete impl — NOVEL

When an impl over a (now-concrete) Self provides FEWER methods than the trait
declares, the trait's DEFAULT (provided-body) methods are still callable on Self.
For a concrete-Self trait impl, enumerate the trait def's items, and for each
provided method NOT already in the impl's items, bind it as a concrete-Self trait
method with the impl's Self (substituted) + the trait's generic args (substituted)
applied to the method signature.

- Source of the trait def: `impl_data["trait"]` carries the trait's resolved id →
  `index[trait_id]` → its `items` (the trait's required + provided methods). A
  provided method is one whose function item `has_body == true` (rustdoc marks
  this) OR — robust fallback — any trait item not present in the impl's `items`
  set. Bind only PROVIDED ones (required-but-unprovided would be an abstract method
  with no body → not callable; but a concrete impl MUST provide all required ones,
  so "in trait, not in impl, has body" = a default the impl inherits).
- Substitute the trait's generic params (`C`) with the impl's trait-args
  (`ApiHttpClientT` → already mono'd to `ReqwestApiClient`) AND `Self` with the
  concrete Self, throughout the projected method sig.
- The async `-> impl Future<Output=T> + Send` (RPITIT) — **SUPERSEDED, see KEYSTONE
  correction below: RPITIT does NOT reuse the existing async bridge; it needs a
  dedicated `impl_future_output` detector, NOT the `async_trait_future_output`
  path.** `Report<ApiClientError>` in the Result error slot maps to
  SkyError via the existing Result-error normalization (#32/#34) — verify Report
  has a Display path; if it renders as an opaque type, treat the whole Result error
  as SkyError (its `.to_string()`).
- FAIL-CLOSED: a projected method whose sig has a non-nameable / non-bindable type
  drops via the existing `fn_types_nameable` / `type_to_typeref` gates. Never emit
  a wrapper that wouldn't compile.

## Soundness invariants (guardian must vet)

1. **Unique-impl substitution is sound** iff the trait has EXACTLY ONE concrete,
   nameable, non-generic impl (the existing `concrete_for_unique_impl` contract).
   `ReqwestApiClient` qualifies. 0/>1 → fail-closed drop.
2. **Default-method projection binds a method that genuinely exists on the concrete
   Self.** Rust's trait system guarantees `FirebaseAuth<ReqwestApiClient>` has
   `create_user` (the default body) because the impl satisfies the trait. So the
   UFCS call `<FirebaseAuth<ReqwestApiClient> as FirebaseAuthService<ReqwestApiClient>>::create_user(&recv, arg)`
   type-checks. This is the load-bearing claim — the wrapper must cargo-compile.
3. **No over-bind of an ABSTRACT (bodyless) trait method** — those aren't callable.
   Gate strictly on "has a provided body".
4. **No double-emit** — a method the impl OVERRIDES (present in impl items) must NOT
   also be projected from the trait def (dedupe by method name within the impl).
5. The `--all-features` rustdoc failure is ORTHOGONAL: firebase's only features are
   `default=["tokens"]` + `tokens` (no CRUD gating), and the inspector's
   default-features fallback already carries the trait + impl. So WALL-F needs no
   feature change. (The all-features failure is filed separately if it ever hides a
   surface; it does not here.)

## Guardian design-gate invariants (APPROVE-WITH-CONSTRAINTS, 2026-06-26)

The guardian APPROVED the two mechanisms as structurally sound + fail-closed, but
caught that one spec claim was FALSE and added 4 mandatory invariants. Fold ALL of
these in before/while implementing:

1. **[KEYSTONE — RPITIT async recognition]** The earlier claim "`-> impl Future +
   Send` reuses the existing async bridge" is WRONG. `async_trait_future_output`
   only matches `Pin<Box<dyn Future>>` (#[async_trait] desugar); an RPITIT
   `impl_trait` node has `is_async=false` and no `Pin<Box>`, so today it DROPS
   `impl-trait-output-not-resolvable`. Fail-closed (no unsound sync-over-async
   emit — the "Future returned unawaited" UB is precluded by the drop), BUT every
   firebase CRUD method drops → the wall delivers nothing. MUST add an
   `impl_future_output` detector: match an `impl_trait` bound list whose principal
   `trait_bound` resolves (by std-trait id, #25 class — reject crate-local
   `trait Future` at crate_id 0) to canonical `Future`, REQUIRE `+ Send` among the
   bounds (else drop `async-future-not-send`), extract `Output=T` via
   `constraint_equality_type`, and route through the SAME `de_async_clone` path
   (set `is_async=true`, output→unwrapped T) so the #44 async→Task machinery + Send
   gate fire identically.
2. **[A — where-bound satisfaction gate]** Project a default method ONLY if, after
   `{Self→concrete, C→concrete}` substitution, EVERY where-predicate is
   satisfied-by-construction (reuse the Send/unique-impl/supertrait proof sources)
   or rests on a still-free method tyvar (→ parametric stub). Any unprovable
   substituted bound → DROP `default-method-where-unsatisfied`. (has-body alone is
   necessary but NOT sufficient — a `fn x(&self) where C: Extra` with concrete
   `!Extra` would emit an uncallable UFCS wrapper = E0599/E0277.)
3. **[D — security: no secret in error string]** `Report<ApiClientError>` may embed
   a bearer token / id-token / API key. The error-slot bridge maps it to SkyError
   via #32/#34 (error slot ALWAYS normalizes to SkyError at codegen, regardless of
   source error type; Sky reads status from the Ok payload, Err is opaque). The
   boundary MUST NOT `Log.*` the raw `report.to_string()`/`{e:?}` and no raw error
   string lands in a structured log field. Fail-closed: error type un-nameable →
   whole method drops via `fn_types_nameable` (never a broken emit).
4. **[B — single-subst-map]** The impl-Self param substitution applies ONE subst map
   across Self-node + trait-args-node + every method-sig node in a SINGLE pass (the
   param is the same `{"generic":"ApiHttpClientT"}` in all three; never substitute
   them independently). Assert with a test: a method using `P` in Self + trait-arg +
   sig monomorphizes all identically.

Mandatory proof fixtures (guardian-required for the final code-gate): RPITIT default
method BINDS as a Task · `?Send` RPITIT default method DROPS · `where C: Extra`
(concrete `!Extra`) default method DROPS while no-extra sibling binds · a SECOND
`Client` impl makes the Self-mono AMBIGUOUS → DROP.

## Verification

- Minimal repro fixture `90-ffi-default-trait-method-mono`: a crate with
  `trait Svc<C: Client>: { fn raw(&self)->&C; fn op(&self, x: String) -> impl
  Future<Output=Result<String,MyErr>> + Send { default body } }`, a unique
  `impl Client for RealClient`, `struct Handle<C>`, `impl<C: Client> Svc<C> for
  Handle<C>`, and a ctor returning the concrete `Handle<RealClient>`. POSITIVE: the
  default `op` binds on `Handle<RealClient>` and runs. NEGATIVE: a SECOND
  `Client` impl in a sibling shape must make `op` DROP (ambiguous unique-impl).
- firebase live: `create_user`/`get_user` appear in the bound set; a Sky program
  `App::emulated() → auth(url) → create_user(NewUser::email_and_password …)` builds
  + (against the emulator, or at least cargo-compiles) under SKY_DCE=0.
- Full FFI fixture gate stays green (no regression).
- Inspector unit tests for the new projection + unique-impl-Self mono.

## Boundary

`tools/sky-ffi-inspect-rs/src/main.rs` (the inspector — Self mono + default-method
projection), possibly `src/Sky/Build/Rust/*.hs` if codegen needs the projected
UFCS qualifier shape (likely reused from the concrete-Self trait path). New fixture
under `runtime-rust/tests/sky/`. No Go, no `sky-stdlib`, no author `examples/`.
