# WALL-H — Generic-Self serde-T `send` on `CustomizableStripeRequest<T>`

**Status:** DESIGN — guardian APPROVE-WITH-CONSTRAINTS (B1–B11 in §7). **Route A** chosen.
WALL-G (#84) shipped — this is unblocked.

## 0. Guardian outcome (resolves §5 + adds §7 constraints)

- **Q-H1 → Route A** (T-open generic wrapper, `miniserde::Deserialize` bound preserved).
  Route C (reduce `T → miniserde::json::Value`) is **REJECTED**: `.customize()` returns
  `CustomizableStripeRequest<Self::Output>` with `Output` fixed per resource — no producer
  ever yields `CustomizableStripeRequest<Value>`, so the reduced wrapper would accept
  nothing. **CRITICAL FINDING: WALL-H alone delivers a SOUND-but-INERT `send`** — an open
  `miniserde::Deserialize`-bounded `T` is unconstructible/undecodable/unprintable on the Sky
  side (same class as the "FFI Result error slot is unusable" precedent), so the binding
  type-checks + cargo-builds but its Ok value is unconsumable **until WALL-I** supplies a
  concrete `CustomizableStripeRequest<ConcreteResp>` AND makes the Ok a Sky-usable type
  (recommended: WALL-I output-serializes the concrete response to a JSON `String`). ⇒
  **WALL-H and WALL-I are ONE coupled arc; ship WALL-H's mechanism, realize usability in WALL-I.**
- **Q-H2 → trait-identity keying** (canonical-path allowlist `SERDE_TRAIT_PATHS`,
  `main.rs:6109`). Adding `"miniserde::de::Deserialize"` is one line — BUT necessary-not-
  sufficient: the existing reduce `method_all_serde_reducible` (`main.rs:8750`) covers only
  METHOD-declared serde params and `return false`s for impl/struct-declared (line 8789).
  WALL-H's `T` is **impl-declared** → the impl-declared-T-open threading (§3.2) is genuinely
  NEW code; the allowlist only makes the bound recognized, not threaded.
- **Verified vs spec:** impl 332 is INHERENT (not a trait impl); items `[330,331]` exactly;
  `T: miniserde::Deserialize` is impl-declared, the only method generic is `C`. `SkyTask` is
  `Pin<Box<dyn Future + Send + 'static>>` → the 330 async path needs `T: Send + 'static`.

**Original draft below.**

**Status (draft):** DRAFT (pre-guardian)
**Epic:** stripe (#70) auto-FFI — the stripe *operation* terminal step. Binds
`send`/`send_blocking` on the generic-Self `CustomizableStripeRequest<T>`.
**Date:** 2026-06-26
**Author:** runtime-rust agent (measurement-grounded)
**Blocked on:** **WALL-G (#84)** landing first — see §6.

---

## 1. The problem, measured (rustdoc JSON evidence)

Source: `~/.cache/sky-rust-target/doc/stripe_client_core.json` (lib
`stripe_client_core` = crate `async-stripe-client-core` 1.0.0-rc.6,
`format_version` 57, crate root id 413).

The terminal stripe operation is `req.send(&client)`. WALL-G resolves the
cross-crate `C: StripeClient` concrete; WALL-H is what's left: the **Self** is
generic and the **return** is async+fallible over the generic response type.

### 1.1 `send` (id 330) — async, generic-Self, generic-C, generic-T return

Exact rustdoc `function` node (id 330, on impl block 332):

```jsonc
"sig": {
  "inputs": [
    ["self",   { "generic": "Self" }],                          // self BY VALUE (CustomizableStripeRequest<T>)
    ["client", { "borrowed_ref": { "is_mutable": false,
                                   "type": { "generic": "C" } } }]   // client: &C
  ],
  "output": {                                                    // Result<T, <C as StripeClient>::Err>
    "resolved_path": { "path": "Result", "id": 58, "args": { "angle_bracketed": { "args": [
      { "type": { "generic": "T" } },                           // Ok = T  (the serde response type)
      { "type": { "qualified_path": {                           // Err = <C as trait#128>::Err
          "name": "Err", "self_type": { "generic": "C" },
          "trait": { "id": 128 } } } }                          // 128 = stripe_client_core::stripe_request::StripeClient
    ] } } }
  }
},
"generics": { "params": [
    { "name": "C", "kind": { "type": { "bounds": [
        { "trait_bound": { "trait": { "path": "StripeClient", "id": 128 } } } ] } } } ],
  "where_predicates": [] },
"header": { "is_const": false, "is_unsafe": false, "is_async": true, "abi": "Rust" }
```

Read-off:
- **`self` is by-value** and typed `Self` = `CustomizableStripeRequest<T>` (the impl's Self).
- **`client: &C`**, `C: StripeClient` (trait id 128, canonical path
  `stripe_client_core::stripe_request::StripeClient`). ← **WALL-G's job**.
- **Return** `Result<T, <C as StripeClient>::Err>`. `T` is the serde response type
  (Ok payload); `Err` is the trait associated type `StripeClient::Err` (assoc-type
  id 311 on trait 128). After WALL-G fixes `C` to the unique concrete async
  `stripe::hyper::client::Client`, `<C as StripeClient>::Err` resolves to that
  client's concrete error type.
- **`is_async: true`** → desugars to `impl Future<Output = Result<T, …>>`. ←
  **#64 / WALL-4 async-desugar recognizer's job**.

### 1.2 `send_blocking` (id 331) — sync, on the SAME impl block 332

Identical shape except `is_async: false`, and the bound/Err trait is
`StripeBlockingClient` (id 125, canonical
`stripe_client_core::stripe_request::StripeBlockingClient`):

```jsonc
"output": { "resolved_path": { "path": "Result", "id": 58, "args": { "angle_bracketed": { "args": [
    { "type": { "generic": "T" } },
    { "type": { "qualified_path": { "name": "Err", "self_type": { "generic": "C" }, "trait": { "id": 125 } } } }
] } } } },
"generics": { "params": [ { "name": "C", "kind": { "type": { "bounds": [
    { "trait_bound": { "trait": { "path": "StripeBlockingClient", "id": 125 } } } ] } } } ] },
"header": { "is_async": false }
```

→ binds as a **sync** Sky `Result` (no `Cmd.perform` re-threading) — matches the
"wrapper `fn -> Result` = sync Sky Result, not Task" learning. WALL-G picks the
unique blocking concrete (`stripe::hyper::blocking::Client`).

### 1.3 `stream` (126) / `get_all` (123) are NOT on this impl — scope correction

Live measurement contradicts the campaign one-liner that lumped all four onto
`CustomizableStripeRequest<T>`. `stream` (126) and `get_all` (123) live on
**`impl<T> ListPaginator<T>`** (impl block id 129), with a heavier
`where T: Sync + Send + 'static + PaginableList` predicate and a
`futures_util::Stream<Item = Result<…>> + Unpin` (126) / `Vec<…>` (123) return.
Only **`send` (330) + `send_blocking` (331)** are the two items of impl block 332
(`items: [330, 331]`). **WALL-H scope = 330 + 331 only.** `stream`/`get_all` are a
separate later wall (different Self type, different bound set, `impl Stream`
return) — note, do not design here.

### 1.4 The Self `T` bound — `miniserde::Deserialize`, NOT serde `DeserializeOwned`

Two-level bound on `T`:
- **struct def** (id 322, canonical
  `stripe_client_core::stripe_request::CustomizableStripeRequest`): `T` is
  **unbounded** (`"bounds": []`).
- **impl block 332** (the one carrying `send`/`send_blocking`): adds
  `T: miniserde::Deserialize` —

```jsonc
// impl 332, generics.params[0]:
{ "name": "T", "kind": { "type": { "bounds": [
    { "trait_bound": { "trait": { "path": "miniserde::Deserialize", "id": 333 } } } ] } } }
// paths[333] = miniserde::de::Deserialize  (kind: trait)
```

- **method level** (330/331): the only method generic is `C`; `where_predicates: []`.

**This is the pivotal fact for the wrapper shape.** The existing serde-bound-T
machinery (#59/#65, WALL 3a/3c) is built around `serde::de::DeserializeOwned`. The
stripe response bound is **`miniserde::de::Deserialize`** — a *different trait from
a different crate*. So the WALL 3a/3c "keep T a Sky-side serde type-param" path
does **not** apply verbatim; it must either (a) be generalized to recognize
`miniserde::Deserialize` as an additional "decode-from-wire" bound, or (b) the
wrapper monomorphizes `T` to a concrete stripe response type per resource (which
is WALL-I territory — the resource builders carry the concrete `Output` type).

### 1.5 What PRODUCES a `CustomizableStripeRequest<T>` — `customize()` (scopes WALL-I)

Two `customize` methods return it:
- **id 321** — a **provided method on the `StripeRequest` trait** (trait def id
  323, canonical `stripe_client_core::stripe_request::StripeRequest`; trait items
  `[318, 319, 321]`). Signature: `fn customize(self) -> CustomizableStripeRequest<Self::Output>`
  where `Self::Output` is the trait's associated type (id 323 self-ref). So **every
  resource request type that impls `StripeRequest`** can be `.customize()`d into a
  `CustomizableStripeRequest<TheResponse>`.
- **id 382** — an **inherent method on `RequestBuilder`** (impl block 383,
  `for_: RequestBuilder` id 320, no trait): `fn customize(self) -> CustomizableStripeRequest<T>`.

→ `CustomizableStripeRequest<T>` is obtained by `.customize()` on a per-resource
`StripeRequest` value (or on a `RequestBuilder`). Those resource request *builders*
(and their `Output` serde types) live in the **per-resource sub-crates** (e.g.
`async-stripe-core`, `async-stripe-checkout`, …) — that is **WALL-I**. WALL-H
assumes a `CustomizableStripeRequest<T>` is in hand and binds `send` on it; it does
**not** design how the builder is reached. Noted for WALL-I, not designed here.

---

## 2. How WALL-H composes with the existing machinery

WALL-H is the *convergence point* of three already-built (or in-flight) pieces. It
adds the generic-Self handling and orchestrates the rest:

| Piece | Owns | What WALL-H reuses |
|---|---|---|
| **WALL-G (#84)** | cross-crate unique-impl concrete mono | resolves `C: StripeClient` → unique async `stripe::hyper::client::Client`; `C: StripeBlockingClient` → unique `stripe::hyper::blocking::Client`. Provides the frozen `ConcreteImpl{reachable_public_path, send_ok, owning_crate(+version)}`. **Hard dependency.** |
| **serde-bound-T (#59/#65, WALL 3a/3c)** | keep a deserialize-bounded `T` as a Sky-side serde type-param in the wrapper sig | the *pattern* of leaving a wire-decode-bounded `T` open in the wrapper. **Caveat (§1.4): the stripe bound is `miniserde::Deserialize`, not serde `DeserializeOwned`** — the recognizer set must be widened, OR T is concretized by WALL-I. Flag for design decision §3.3. |
| **async-desugar recognizer (#64, WALL-4)** | turn `is_async: true` rustdoc fns into `impl Future<Output=…>` + bind as a Sky `Task` with the dedicated-thread sync bridge / Send-gate | recognizes 330's `is_async:true`; emits the async wrapper. 331 (`is_async:false`) takes the **sync** path → binds as a Sky `Result`. |

The novel WALL-H content is **generic-Self mono**: WALL-F handles generic-Self only
when the Self type-param resolves to a *unique concrete*; here Self's `T` is an
**open serde/miniserde param**, NOT a unique concrete. WALL-H must either thread
`T` through the wrapper as an open (bound-preserving) generic, or accept a
concrete `T` supplied by the call site / WALL-I. That choice is §3.

---

## 3. Design sketch — the wrapper shape

### 3.1 The shape WALL-H emits (target, T-open variant)

After WALL-G freezes the concrete client, the natural wrapper for `send` (330) is:

```rust
// async variant — desugared, Task-bound by WALL-4
pub async fn customizable_stripe_request_send<T>(
    req: CustomizableStripeRequest<T>,
    client: &stripe::hyper::client::Client,        // WALL-G frozen reachable_public_path
) -> SkyResult<SkyError, T>                          // Ok=T; Err normalized to SkyError (§3.4)
where
    T: miniserde::Deserialize + Send + 'static,     // §1.4 bound + WALL-4 async-Send gate
{
    // delegate to the real method; map the concrete Err → SkyError
    req.send(client).await.map_err(stripe_err_to_sky)
}
```

```rust
// blocking variant — sync, binds as a plain Sky Result (no Task)
pub fn customizable_stripe_request_send_blocking<T>(
    req: CustomizableStripeRequest<T>,
    client: &stripe::hyper::blocking::Client,
) -> SkyResult<SkyError, T>
where
    T: miniserde::Deserialize,
{
    req.send_blocking(client).map_err(stripe_err_to_sky)
}
```

Self is taken **by value** (matches `["self", {"generic":"Self"}]`). `client` is
`&Concrete` (the `&C` → frozen concrete). The two trait-Err assoc types
(`<C as StripeClient#128>::Err` / `<C as StripeBlockingClient#125>::Err`) resolve
to the concrete client's error once `C` is fixed by WALL-G, and are then normalized
(§3.4).

### 3.2 Generic-Self threading — the WALL-H core

`CustomizableStripeRequest<T>` reaches the wrapper as a parameter, so the impl
block's `T: miniserde::Deserialize` must appear as a **wrapper-level generic with
its bound preserved**. This is the genuinely new bit vs WALL-F: WALL-F's
generic-Self path collapses Self to a unique concrete; here Self stays generic in
`T` and the *bound travels with it*. Concretely the codegen must:
1. read impl block 332's `generics.params` → discover `T: miniserde::Deserialize`;
2. render the wrapper's own `<T>` + `where T: miniserde::Deserialize` (+ async-Send
   additions on the 330 path);
3. render the `req: CustomizableStripeRequest<T>` param with the **same** `T` ident.

### 3.3 The `miniserde::Deserialize`-vs-`DeserializeOwned` decision (open — §5 Q-H1)

Two routes; pick one in guardian review:
- **Route A (T-open, generalize the recognizer).** Add `miniserde::de::Deserialize`
  (path id 333, canonical `miniserde::de::Deserialize`) to WALL 3a/3c's
  "wire-decode bound ⇒ keep T as a Sky serde type-param" allowlist. The Sky side
  then sees a generic `send : CustomizableStripeRequest a -> Client -> Task Error a`.
  **Risk:** is a Sky-side value of an open `miniserde::Deserialize`-bounded `T`
  ever *constructed*? It only ever comes back from `send` and is consumed by a Sky
  decoder/printer — so an open `T` may be unusable on the Sky side (cf. the
  "FFI `Result<_,String>` error slot is unusable" learning). Needs a usability
  probe.
- **Route B (T-concrete via WALL-I).** WALL-I's resource builders carry the
  concrete `Output` serde type; the `CustomizableStripeRequest<ConcreteResp>` that
  flows into `send` already has `T = ConcreteResp`. The wrapper is then
  monomorphic per resource (`…_send_charge`, `…_send_customer`, …). **This is
  almost certainly the shippable route** — it makes the Ok payload a concrete,
  Sky-nameable, decodable type. But it couples WALL-H tightly to WALL-I and is only
  realizable once WALL-I lands. **Recommendation: design WALL-H to emit the T-open
  wrapper (Route A) as the *mechanism*, and let WALL-I's concrete
  `CustomizableStripeRequest<ConcreteResp>` instantiate it at the call site** — the
  open wrapper monomorphizes naturally when applied to a concrete-T value, so one
  emission covers both.

### 3.4 Err normalization

`<C as StripeClient>::Err` / `<C as StripeBlockingClient>::Err` are concrete foreign
error types once WALL-G fixes `C`. Per the "FFI `Result` error slot" learning +
#32 (`Result String a` → `SkyError` normalization), the wrapper maps the concrete
Err → `SkyError` (`stripe_err_to_sky`). Any status the Sky side must inspect goes
in the **Ok** payload, never the Err slot — but here `send`'s Ok is the response
`T`, so a structured stripe API error must surface as a `SkyError` carrying a
message (no secret in the string — §4).

---

## 4. Soundness gates to flag for guardian review

1. **Inherit ALL of WALL-G's gates** — the concrete `C` and its `reachable_public_path`,
   frozen `send_ok`, owning-crate dep+version, and feature-determinism are WALL-G's
   `ConcreteImpl`. WALL-H must consume that frozen struct, never re-resolve the
   foreign client id in client-core's namespace (B2/gate6 of WALL-G).
2. **Async-Send gate on the 330 path (tighter predicate).** Per the
   `Clone ≠ Send` learning: the async wrapper's `T` AND the concrete client must be
   `Send + 'static` for `tokio::task::spawn`. Use `is_async_send_output` (closed
   set), NOT the sync `is_sky_coercible_elem`. A `!Send` `T` ⇒ over-drop the async
   `send` (no E0277 at spawn). The blocking 331 path has no Send requirement.
3. **`miniserde::Deserialize` bound is preserved verbatim, never dropped.** Emitting
   the wrapper `<T>` without `where T: miniserde::Deserialize` ⇒ E0277 at the
   `req.send` call inside the wrapper (`T` not Deserialize) — a type-checks-but-
   cargo-fails hole. The bound is read from impl block 332's generics and rendered.
4. **`miniserde` must be a generated-Cargo.toml dep when the bound is rendered.**
   If Route A renders a `T: miniserde::Deserialize` wrapper, `miniserde` (a
   transitive dep of async-stripe-client-core) must be a *direct* dep of the
   bindings crate, else E0433 `unresolved crate miniserde` (the "new external-crate
   dep in a shared module" class). Derive name+version from the invocation set
   (mirror WALL-G B4).
5. **Self-by-value move soundness.** `self` is consumed by value; the wrapper takes
   `req` by value and moves it into `req.send(client)`. No aliasing/borrow issue,
   but confirm codegen never emits a `&req` here (the receiver is owned, not `&self`).
6. **Err carries no secret.** `stripe_err_to_sky` must not embed the API key / bearer
   / request body in the `SkyError` message (security > correctness). Stripe error
   bodies can echo request params — sanitize.
7. **No panic in the bridge.** The async→sync dedicated-thread bridge (WALL-4) maps
   a foreign panic → `Err`, never `process::exit` in a panic hook (the
   catch_unwind-defeat learning).
8. **Scope gate.** WALL-H binds ONLY items `[330, 331]` of impl 332. It must NOT
   accidentally also bind `stream`/`get_all` (different Self `ListPaginator<T>`,
   impl 129, heavier bounds) — those drop until their own wall.

---

## 5. Open questions for guardian

- **Q-H1 (make-or-break)** — Route A (T-open, widen the wire-decode-bound allowlist
  to `miniserde::Deserialize`) vs Route B (T-concrete via WALL-I). Recommendation
  §3.3: emit the T-open wrapper; let WALL-I's concrete-T value instantiate it. Is a
  Sky value of an open `miniserde::Deserialize`-bounded `T` *usable* (constructible /
  decodable / printable) on the Sky side, or is it inert until concretized? Needs a
  usability probe (cf. unusable-Err-slot precedent).
- **Q-H2** — does the existing #59/#65 serde-T machinery key on the *trait identity*
  `serde::de::DeserializeOwned`, or on a structural "has a deserialize bound" test?
  If the former, adding `miniserde::de::Deserialize` (path id 333) is a one-line
  allowlist extension; if the latter, confirm miniserde's bound is recognized as-is.
- **Q-H3** — `miniserde` direct-dep injection: same derive-from-invocation-set
  mechanism as WALL-G B4, or a separate transitive-dep surfacing pass? Confirm the
  version pin matches what async-stripe-client-core resolves (skew → drop).
- **Q-H4** — the `Err` assoc type is `<C as StripeClient>::Err`; after WALL-G fixes
  `C` to the concrete client, does the inspector resolve the *concrete* Err type, or
  does the wrapper stay generic over `<C>::Err`? If concrete, `stripe_err_to_sky`
  needs a per-error-type `From` impl; if generic, a blanket `impl<E: Display> From<E>`.
- **Q-H5** — `customize` (id 321) is a *provided trait method* on `StripeRequest`
  (323). For WALL-I: is binding a provided trait method (vs an inherent method)
  already supported by the inspector, or is that a fourth obstacle? (Note for WALL-I,
  not WALL-H.)

---

## 6. Dependency note — WALL-H is BLOCKED on WALL-G (#84)

WALL-H **cannot land before WALL-G (#84)**. `send`'s `client: &C` with
`C: StripeClient` is exactly the cross-crate unique-impl concrete that WALL-G
resolves; WALL-H consumes WALL-G's frozen `ConcreteImpl`
(`reachable_public_path` = `stripe::hyper::client::Client`, frozen `send_ok`,
`owning_crate` + version) to render the `client: &Concrete` param and the
generated-Cargo.toml facade dep. Until WALL-G is in, the `C` param is
`trait-bounded-param-ambiguous` and `send` drops — there is nothing for WALL-H to
bind. WALL-H also depends on the #64/WALL-4 async-desugar recognizer (already in)
for the 330 async path, and interacts with the #59/#65 serde-bound-T machinery
(§2, §3.3). Sequence: **WALL-G (#84) → WALL-H → WALL-I (resource builders /
`customize`)**.

### Verification plan (when unblocked)
- **Fixture (synthetic, no network):** mirror impl 332's shape — a `Resp` struct +
  `impl<T: SomeDeserialize> Customizable<T> { async fn send<C: Wire>(self, c:&C)
  -> Result<T, C::Err>; fn send_blocking<C: BlockingWire>(self,c:&C)
  -> Result<T,C::Err>; }` across the WALL-G two-crate fixture, then a Sky `Main.sky`
  that `.customize().send(client)` and asserts `[ALL OK]`. Build under `SKY_DCE=0`
  + a real `cargo build` (the "type-checks-but-cargo-fails" class demands a real
  link, per WALL-G B7).
- **Real-crate proof:** `send` against async-stripe rc.6 once WALL-G + WALL-I land
  (needs a concrete resource builder to produce the `CustomizableStripeRequest<T>`).

---

## 7. Guardian MUST-hold constraints (B1–B11)

- **B1** — add `"miniserde::de::Deserialize"` to `SERDE_TRAIT_PATHS` (keep the crate-local
  veto). Implement impl-declared-T-open threading SEPARATELY — `method_all_serde_reducible`
  (main.rs:8789) does NOT cover impl-declared params.
- **B2** — discriminate by the bound trait's NATURE, not position: `C: StripeClient`
  (unique-impl trait) → WALL-G mono; `T: miniserde::Deserialize` (open decode bound) →
  thread OPEN. `T` must NEVER reach the unique-impl resolver (`Deserialize` has 0/many impls
  → would ambiguous-drop `send`).
- **B3** — extend the async output-Send gate to ADMIT an open generic the wrapper declares
  `+ Send + 'static`; render `where T: miniserde::Deserialize + Send + 'static` on the 330
  path (without it: non-Send spawn future E0277 + `req.send` E0277).
- **B4** *(deferred hole — hard WALL-I precondition)* — WALL-I MUST prove the concrete
  response `Send + 'static` AND `CustomizableStripeRequest<ConcreteT>: Send` before binding
  the resource→send chain; over-drop if unprovable (else Sky type-checks, cargo fails).
- **B5** *(fixture fidelity)* — the synthetic fixture's Self struct must be
  CONDITIONALLY-Send-on-T (`PhantomData<T>` + Send fields); an unconditionally-Send model is
  a FALSE GREEN on the spawn's `Customizable<T>: Send` obligation.
- **B6** — WALL-G's concrete client Sky surface must be the OWNED `Client` via the
  `isOwnRefTy` case-(A) path (Ffi.hs:794); the fixture must combine async-send + owned
  cross-crate client (a combination no shipped fixture yet exercises).
- **B7** — `miniserde` becomes a DIRECT generated-Cargo.toml `[dependencies]` (else E0433),
  version from the invocation set; DROP on version skew vs what async-stripe-client-core
  resolves (path-equal but type-incompatible → E0277).
- **B8** *(SECURITY — top priority)* — `sky_error_from_foreign`: (i) the concrete Err must
  impl Debug or over-drop (#83); (ii) the user-facing `SkyError` message MUST NOT embed the
  raw foreign Debug (stripe error bodies echo bearer/API-key/request body) — emit a fixed
  generic message + correlation id, detail server-side-log only. Fold into #83's scope.
- **B9** — bind ONLY items [330,331]; gate the open-Self threading to INHERENT impl + a
  Deserialize-only-bounded Self so it can't widen to `ListPaginator<T>` (impl 129).
- **B10** — `send_blocking` (331, sync) binds as a plain Sky `Result`: apply B1/B2/B7/B8
  identically, SKIP the async-Send admission (B3) + the spawn.
- **B11** — fixture green under `SKY_DCE=0` + REAL cargo; document it does NOT retire
  B4/B5's residual nor the `.customize()` producer (Q-H5 → WALL-I).

## 8. Implementation sequencing (post-guardian)

WALL-H's mechanism is independently testable (synthetic conditionally-Send fixture with a
concrete-T ctor), but its STRIPE value is inert until WALL-I. Recommended order:
1. **B1** allowlist + **impl-declared-T-open threading** (the new core) + **B3** async-Send
   admission for a wrapper-declared open `Send` generic + **B9** scope gate.
2. Synthetic fixture `92-ffi-generic-self-open-t` (two-crate, conditionally-Send Self,
   external decode-bound trait, assoc-type Err, concrete-T ctor) → GREEN under SKY_DCE=0.
3. **B7** miniserde direct-dep + **B8** Err sanitization (with #83).
4. WALL-I (resource builders / `.customize()` provided-trait-method) realizes usability —
   makes the Ok a concrete JSON `String`; only then is `send` end-to-end useful on real stripe.
