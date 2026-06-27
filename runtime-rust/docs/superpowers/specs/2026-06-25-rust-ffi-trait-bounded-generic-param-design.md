# Trait-bounded generic param → concrete-impl monomorphization (#52) — design

**Goal.** Bind a foreign fn/method with a generic param bounded by a NON-modellable trait —
`async fn send<C: StripeClient>(&self, client: &C)`, firestore `.fluent()` builders generic over a
client/transport trait. Empirical (skyshop-rs no-shim, 2026-06-23/25): after #44 (async) / #45
(generic-Self) / #46 (UFCS) / #47 (serde) / #51 (every-feature visibility via dep-table feature
injection — `--all-features` for an external `-p <dep>` is rejected by cargo), the stripe/firestore
operations are now VISIBLE but still drop `unmodellable-bound`/`generic-self` because the client
type-param `C` is generic over a trait the modellable/serde sets don't cover. This is the LAST
structural barrier before those crates bind shim-free.

**Status:** IMPLEMENTED — superseded by the shipped WALLs. #52's trait-bounded-param →
concrete-impl monomorphization landed across **WALL-G** (#84, cross-crate unique-impl mono),
**WALL-H** (#87, async generic-Self `send` conditional-Send), **WALL-I** (#88, customize-chain
provided-method projection), **WALL-J** (inherent `<Self as ForeignTrait>::Output` projection),
and **WALL-K** (cross-crate resolution for an EXTERNAL trait bound — the 3-crate triangle).
Proof: fixture 96 (the WALL-J∘WALL-K composition, the full real-stripe `send` shape). This doc
records the original architecture + the make-or-break questions; the as-built mechanism diverges
where noted below (most notably cross-DEPENDENCY-crate resolution, a declared v1 non-goal that
WALL-K shipped).

## The shape

```rust
// stripe
impl CreateCheckoutSession<'_> {
    pub async fn send<C: StripeClient>(&self, client: &C) -> Result<CheckoutSession, StripeError>;
}
pub struct Client { /* … */ }            // the ONE concrete impl
impl StripeClient for Client { /* … */ }
impl Client { pub fn new(secret: &str) -> Client; pub fn with_url(self, url: &str) -> Client; }
```
The shim bound this by hard-coding `C = stripe::Client`, constructing the client internally, and
`block_on`-ing `.send(&client)`. Auto-FFI must instead (a) PICK the concrete `C`, (b) bind the
concrete client as an opaque Sky value the user constructs + threads.

## The mechanism (two parts)

### Part A — concrete-impl resolution for the trait bound
For a generic param `C: SomeTrait` (SomeTrait not in the modellable/serde/Fn/Iterator sets):
- Scan the crate's rustdoc for CONCRETE (non-generic, no free tyvar) types `impl SomeTrait for T`.
  (**As built (WALL-K, #92):** widened beyond the entry crate — a global cross-crate impl index
  `GLOBAL_XC_IMPLS` also resolves a concrete impl living in a DEPENDENCY crate (the 3-crate
  triangle: method-crate / trait-crate=dep / impl-crate=another dep — stripe `send<C: StripeClient>`),
  gated by a std/core/alloc trait-exclusion so std conversion bounds like `T: Into<…>` / `T: From<X>`
  stay fail-closed-dropped by the WALL-E path.)
- **Exactly ONE** concrete impl `T` in scope → monomorphize `C = T` (render the call `…::send::<::crate::Client>(&self, client)` — `C` substituted by the concrete type).
- **Zero or >1** → DROP `trait-bounded-param-ambiguous` (sound over-drop; can't choose). A later
  opt-in hint (`sky.toml [rust.ffi.monomorphize] StripeClient = "stripe::Client"`) disambiguates the
  >1 case — NOT in v1.
- Blanket impls (`impl<T> SomeTrait for T`) don't count as "the concrete impl" (no specific T).

### Part B — the concrete type binds as an OPAQUE foreign value
`C = Client` is NOT serde/closed-set — it's an opaque resource. Bind it as an OPAQUE HANDLE:
- The Sky side constructs it via the type's bound constructor (`Client.new(secret)` → an opaque
  `Client` value) and threads it into the op (`CheckoutSession.create(params, client)`).
- The opaque value is a foreign struct passed by value / `&`. Auto-FFI already binds foreign structs
  as values; an opaque handle is the same minus field extractors (the user never inspects it, just
  passes it). Confirm the inspector emits a Sky type for an opaque foreign struct usable ONLY as an
  arg/return handle (no field access) — likely already true (a struct with no Sky-modellable fields
  binds as an opaque value today; verify).
- `&C` borrow at the call site: the Sky value owns the `Client`; the wrapper passes `&client` (by-ref
  of the owned opaque — the #28/#22 owned-then-borrow pattern).

## Composition (this is the LAST layer)
A real stripe op stacks: **#44** async (→ `Task`), **#45** generic-Self (the `CreateCheckoutSession<'_>`
receiver), **#47** serde params (the create-params struct), **#46** UFCS for any trait methods, **#52**
the `C: StripeClient` param. #52 is necessary-and-(with the others)-sufficient. After #52 a stripe
checkout op binds end-to-end: `Client.new` + `CheckoutSession.create(params_json, client)` → `Task`.

## Make-or-break questions (for the guardian, when run)
1. **Unique-concrete-impl resolution soundness.** Is "exactly one concrete impl in the entry crate's
   rustdoc → monomorphize" sound? Risks: (a) the concrete impl lives in a DEPENDENCY crate not in the
   entry rustdoc → not seen → drop (sound but misses it) — **as built (WALL-K) this is now RESOLVED:
   the `GLOBAL_XC_IMPLS` cross-crate index sees dependency-crate impls, std/core/alloc-trait-excluded**;
   (b) >1 client (async + blocking) → must drop
   ambiguous, never guess; (c) the chosen impl `T` is itself generic/unnameable → drop.
2. **Opaque-handle threading.** Does auto-FFI bind a foreign struct with NO Sky-modellable fields as an
   opaque value usable as arg/return? If not, that's a prerequisite sub-task (opaque-foreign-value
   support). Confirm the inspector's struct path + the runtime can carry an opaque `Box<dyn Any>`-free
   typed handle (the no-`dyn Any` thesis: carry it as its concrete Rust type via the monomorphised
   wrapper — the handle never crosses an untyped boundary).
3. **Send across the async await (#44 C1).** The threaded `&Client` must be `Send` for the multi-thread
   tokio Task. A non-Send client → drop `async-future-not-send` (the #44 gate already covers it once C
   is concrete).
4. **Constructor binding.** `Client::new(&str) -> Client` + builder `with_url(self) -> Client` must
   bind (they're concrete inherent methods — #21/#45 territory). Confirm the construct-then-thread
   chain is bindable.

## Proof bar (when implemented)
1. Hand-stub fixture: a crate with `trait Transport{}`, `struct Conn; impl Transport for Conn;
   impl Conn{fn new()->Conn}`, `async fn run<C:Transport>(&self, c:&C)->Result<i64,String>`, +
   a 2-impl NEGATIVE (`struct Conn2; impl Transport for Conn2` → ambiguous → both ops drop).
   Main.sky: `c = M.conn_new(); M.run(params, c)` → `Task` → asserts.
2. Inspector unit tests: 1-impl → monomorphize; 0/2-impl → drop ambiguous; blanket-impl → drop.
3. Real-crate (CI): re-add async-stripe-core (every-feature dep-table feature injection, #51) → confirm `CheckoutSession::send`
   / `Customer::create` now BIND (C=Client), the full checkout op reachable from Sky.

## Non-goals (v1)
The >1-impl disambiguation hint (sky.toml). Trait objects as the param (`&dyn Transport` —
trait-objects arc). Async streams.

(**Diverged from as-built:** "Cross-DEPENDENCY-crate concrete-impl resolution (only the entry
crate's rustdoc)" was listed here as a v1 non-goal, but WALL-K (#92) shipped exactly that — the
`GLOBAL_XC_IMPLS` cross-crate index, std/core/alloc-trait-excluded. It is no longer a non-goal.)
