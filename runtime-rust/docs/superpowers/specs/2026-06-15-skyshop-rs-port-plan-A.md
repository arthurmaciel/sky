# skyshop-rs port — buildable plan (Planner-Reasoner-A)

> **SUPERSEDED — non-authoritative.** This reasoner plan was folded into
> `2026-06-15-skyshop-rs-port-SYNTHESIS.md`, which holds the locked decisions
> (D1–D6) the shipped port follows. Notably, plan-A's central compiler change —
> adding a `RustPathDep` constructor + emitting `path = …` — did **NOT** ship:
> per the user's D4 override the delivery uses `RustGitDep` with a `file://` URL
> (`Sky/Toml/Rust.hs` still has only `RustVersion` + `RustGitDep`, no path
> variant). The shipped port also has **3** wrapper crates
> (`sky-firestore-shim` / `sky-stripe-shim` / `sky-firebase-auth-shim`), not the
> 2 named below. Kept for grep; act on SYNTHESIS, not this plan.

Target: a NEW fork-local example `examples/rust/skyshop-rs/`, a faithful port of
`examples/13-skyshop` (8,200-line Sky.Live e-commerce app) onto the Sky→Rust
backend (`sky build --target rust`), replacing the Go-FFI deps with two
fork-local **wrapper crates** over `firestore` 0.49 + `async-stripe` 1.0.0-rc.6,
plus a Sky-side Firebase ID-token verifier.

This plan answers every question in
`2026-06-15-skyshop-rs-port-questions.md`, leads on the four blocker decisions,
and gives a file-by-file port order an executor can act on.

The single most load-bearing discovery, which collapses most of the perceived
risk: **`Lib/Db.sky` / `Lib/Stripe.sky` / `Lib/Auth.sky` consume their FFI as
bare, synchronous `Result Error a`, never `Task`.** The Rust FFI inspector
already classifies a synchronous `fn(...) -> Result<String, String>` as
`fallible` → it binds as a bare `Result Error String`
(`tools/sky-ffi-inspect-rs/src/main.rs:1407 classify_effect`: not-async +
`Result` ⇒ `"fallible"`; `Sky/Build/Rust/Ffi.hs:668` emits a plain `match`, not
`Box::pin(async)`). So if the wrapper crates expose **synchronous** functions
that hide the async runtime internally, the Sky call sites port **near-verbatim**
and no `Task`/`Cmd.perform` rewrite is needed (resolves §2.3, §3.5, §13.10).

---

## Part 1 — Decisions (one per blocker)

### D0.5 — Fidelity bar: build-green + run-verified-structural, not byte-identical

The user now supplies run-verification means (Firestore emulator + Stripe test
mode), so the bar rises above build-only but stays below "byte-identical to the
Go app". Acceptance:

1. `sky build src/Main.sky --target rust` exit 0 **and** `cd sky-out/Rust &&
   cargo build` exit 0 (the hard gate).
2. Creds-less boot smoke: binary boots, `curl localhost:<port>/` → 200, no
   `panic`/`UNIQUE`/Rust-backtrace in stderr. The Home page renders with empty
   products when Firestore is unconfigured (the wrapper short-circuits — D-bridge
   below), exactly as the Go app logs-an-error-and-shows-empty.
3. Emulator run-verify (documented runbook, not a CI gate): with
   `FIRESTORE_EMULATOR_HOST=localhost:8080` + the Auth-emulator bypass + a Stripe
   `sk_test_…` key, the product-list / cart / checkout-create paths execute
   against the emulator + Stripe test API.

"1:1" means **structural fidelity**: same modules, same Model/Msg/Page/view, same
collections, same translation table, same routes. Three places legitimately
diverge from the Go source (each justified in-line below): the `init` cookie read
(typed `LiveReq`), the auth verify path (Sky-native JWKS instead of the Go
Firebase Admin SDK), and the `js "nil"` literals (vanish — the wrapper owns
context). These are *the boundary doing its job*, not gaps.

### D0.2 / D2.1 / D13.2 — Wrapper delivery: ADD a `RustPathDep` variant (in-boundary)

**Chosen: add a `RustPathDep` constructor to `src/Sky/Sky/Toml/Rust.hs` and emit
`path = "…"` in `emitCargoToml`.** This is the gating decision; the alternatives
lose:

- *git dep* (`RustGitDep`, exists today): forces publishing the two wrapper
  crates to a public git repo before the example can build — a release/hosting
  dependency outside the repo, un-self-contained, and the inspector would
  re-clone on every cache miss. Rejected.
- *vendoring / `[patch]`*: no Toml surface for it; would need codegen for a
  `[patch.crates-io]` table — strictly more compiler work than a `path` field,
  and semantically wrong (these aren't patches of a published crate). Rejected.
- *`[rust.shims]`*: **does not exist and is not being built** — the brief's
  references are stale (README: "There is no `[rust.shims]` section"). Confirmed
  §0.1. Not an option.

A `path` dep is the canonical Cargo mechanism for a fork-local crate, is fully
inside the modification boundary (`src/Sky/Sky/Toml/Rust.hs` is explicitly
allowed; `emitCargoToml` lives in `src/Sky/Generate/Rust/Builder/Emitter.hs`,
also allowed), and keeps the example self-contained — the wrapper crates sit
beside `sky.toml` and the generated `Cargo.toml` points at them by relative path.

**Exact Toml shape** (`examples/rust/skyshop-rs/sky.toml`):

```toml
["rust.dependencies"]
sky-firestore-shim = { path = "firestore-shim" }
sky-stripe-shim    = { path = "stripe-shim" }
```

**Exact code change** — `Sky.Sky.Toml.Rust`:

```haskell
data RustDepSpec = RustVersion { _rvVersion :: String, _rvFeatures :: [String] }
                 | RustGitDep  { _gitUrl :: String, _gitRev, _gitBranch, _gitTag :: Maybe String }
                 | RustPathDep { _pathDir :: String, _pathFeatures :: [String] }   -- NEW
    deriving (Show, Eq)
```

`parseInlineTable` gains a `lookup "path" kv` branch *before* the git/version
branches (path is most-specific): `Just dir -> RustPathDep dir features`.

**Exact emitted `Cargo.toml` line** — `emitCargoToml` `emitDepLine`
(`Emitter.hs:812`):

```haskell
emitDepLine name (Toml.RustPathDep dir feats) =
    if null feats
        then name ++ " = { path = " ++ show dir ++ " }"
        else name ++ " = { path = " ++ show dir ++ ", features = [" ++ intercalate ", " (map show feats) ++ "] }"
```

→ generated `sky-out/Rust/Cargo.toml`:

```toml
sky-firestore-shim = { path = "firestore-shim" }
sky-stripe-shim = { path = "stripe-shim" }
```

**Path-resolution detail (must verify in execution):** `emitCargoToml` runs the
path string verbatim; the generated `Cargo.toml` lives at
`examples/rust/skyshop-rs/sky-out/Rust/Cargo.toml`, so a bare relative `path =
"firestore-shim"` resolves against `sky-out/Rust/`, NOT the example root. Two
clean options — pick **(a)** for self-containment:
(a) emit the path **relative to `sky-out/Rust/`**, i.e. the executor writes
`sky.toml` with `path = "../../firestore-shim"` (two levels up from
`sky-out/Rust/` back to the example dir). The Toml value is passed through
verbatim, so this needs zero codegen logic — just the right string in `sky.toml`.
(b) have `Project.hs` rewrite a path dep to an absolute path at emit time
(more robust to `sky-out` depth, slightly more code). Plan adopts **(a)** and
documents the `../../` convention in the example README; **(b)** is the
fallback if `sky-out` nesting changes.

### D0.3 / D3.1 / D3.3 — Inspector path, slug, module name for a path/wrapper crate

`runRustInspectorWith` (`Ffi.hs`) already takes a `pkgPath` and an optional git
spec; for a **path** dep the executor adds a `runRustInspectorPath crateName dir`
front-door that passes the local directory as `pkgPath` (rustdoc runs against the
on-disk crate — no clone). Cache + naming follow the existing rules:

- artifacts at `.skycache/ffi/rust/<fileSlug>.{kernel.json,skyi,_bindings.rs}`
  where `fileSlug` = the dep name with `./` → `_` (`Project.hs:199`). For
  `sky-firestore-shim` the slug is `sky-firestore-shim` (no `.`/`/`), file
  `sky-firestore-shim_bindings.rs`.
- `_bindings.rs` copied to `sky-out/Rust/src/<modSlug>_bindings.rs`, `modSlug`
  = non-alphanumerics → `_` → `sky_firestore_shim_bindings.rs` (`Project.hs:201`).
- Sky module name = `rustModuleName` = `"Rust." ++ capitalise(alnum-cleaned)` →
  **`Rust.Sky_firestore_shim`** and **`Rust.Sky_stripe_shim`**. (Confirmed
  `Ffi.hs rustModuleName`: every non-alnum → `_`, capitalise first.)

Re-inspection trigger: the FFI registry is regenerated on `sky install` / when
`.skycache/ffi/rust/<slug>.*` is absent. There is **no source-fingerprint
auto-invalidation for a path crate today** — so the executor's loop must
`rm -rf .skycache/ffi/rust` whenever a wrapper's signature surface changes
(documented in the runbook; matches the wiped-slate sweep idiom). A future
nicety (out of scope for this port) is a path-crate mtime fingerprint.

### D2.2 — The async→sync bridge: a dedicated-thread runtime, reused from `task.rs`

This is the central technical risk (§13.1). The constraint: both crates are
async; the generated Sky.Live app already runs inside the axum/hyper tokio
runtime, and `Runtime::block_on` **inside** a runtime panics
("Cannot start a runtime from within a runtime") — a no-panic-existential
violation.

**Chosen bridge: a dedicated OS thread that owns its own current-thread tokio
`Runtime`, fed by a channel.** This is *exactly the pattern the Rust runtime
already uses* — `sky_runtime/task.rs::block_on` does
`std::thread::spawn(move || rt.block_on(future)).join()` (`task.rs:7-11`): a fresh
`Runtime` on a fresh thread, never the ambient one. The wrapper crates mirror it,
with the runtime + client built **once** (lazily, `OnceLock`) and a long-lived
worker thread so we don't pay thread+runtime spawn per call.

Concrete shape (per wrapper crate, no `Any`, no `unwrap` on a Sky path):

```rust
use std::sync::OnceLock;
use tokio::runtime::Runtime;

// One dedicated multi-thread runtime, off the axum runtime. Built once.
fn rt() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        // build() can only fail on OS resource exhaustion; degrade, never panic.
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2).enable_all().build()
            .expect("dedicated firestore runtime")   // see safety note
    })
}

// Each public fn runs its async body on rt() via a fresh thread that block_on's,
// so we NEVER block_on inside the caller's (axum) runtime:
fn block<F, T>(fut: F) -> Result<T, String>
where F: std::future::Future<Output = Result<T, String>> + Send + 'static, T: Send + 'static {
    let h = rt().handle().clone();
    std::thread::spawn(move || h.block_on(fut))
        .join()
        .map_err(|_| "firestore worker thread panicked".to_string())?
}
```

`std::thread::spawn(... h.block_on ...)` runs `block_on` on a **non-runtime
worker thread** even though the *runtime itself* is the dedicated one, so it is
panic-free under Sky.Live (ambient axum runtime present) AND under Sky.Cli (no
ambient runtime) — the thread boundary is what makes it safe in both. The
`.join()` converts any internal panic in the async body into an `Err(String)`
(caught at the thread boundary), so a panic in `firestore`/`tonic` surfaces as a
Sky `Err`, never aborts the process. (Resolves §2.2, §13.1.)

**Why not the simpler `send_blocking`?** `async-stripe` 1.0-rc *does* expose
`send_blocking` (research-confirmed), but its docs warn it must not be called
from inside a tokio runtime — same hazard. So the stripe-shim ALSO routes through
the dedicated-thread `block()` helper for uniformity and safety (it calls the
async `.send(&client)` form inside `block()`), rather than relying on
`send_blocking`'s own internal runtime which would collide with axum. One bridge,
both crates.

**Safety of the one `.expect` on `Runtime::build()`:** this matches the existing
ledger posture — `task.rs::block_on` already `match`es the `Runtime::new()`
result and degrades; the wrapper SHOULD do the same (`get_or_init` can't return a
`Result`, so use a `OnceLock<Option<Runtime>>` and have `block()` return
`Err("runtime unavailable")` when `None`). That keeps the wrapper inside the
no-panic rule with **zero** `expect` on a Sky-reachable path. (The snippet above
shows `.expect` for brevity; the executor uses the `Option` form — noted as a
SKY-RUST-AUDIT decision point.)

### D-bridge — creds-less / dry-run short-circuit (no panic on unconfigured boot)

To satisfy the creds-less smoke (D0.5 #2) and §6.5/§12.3: each wrapper checks its
config **before** touching the network and returns a clean `Err`/empty:

- firestore-shim: `FirestoreDb` construction is lazy in a `OnceLock`. If
  `GOOGLE_CLOUD_PROJECT` is unset AND `FIRESTORE_EMULATOR_HOST` is unset, the
  constructor still runs but `firestore::FirestoreDb::new` will error → the
  wrapper returns `Err("firestore unavailable: …")`, which `Lib/Db.sky`'s
  `wrapDbError` already maps and `queryWhereOrLog` swallows to `[]` (empty
  products). No panic, Home renders empty — Go-parity behaviour.
- stripe-shim: preserves the original `apiKey == "" → Err invalidInput` early-out
  in Sky (`createCheckoutSession` keeps its guard); additionally the wrapper
  itself returns `Err("stripe key empty")` if handed an empty key, so a creds-less
  boot that somehow reaches checkout can't `block_on` a doomed request and hang.

This makes the credential-free happy path real (§1.6) and the smoke test
trustworthy.

---

## Part 2 — Wrapper-crate API tables

Both wrappers expose ONLY plain auto-FFI-bindable signatures: arguments and
returns in `{String, i64, bool, Vec<…>, HashMap<String,String>, Result<_, String>,
Option<_>}`. Per the coercion table (README "FFI codegen type-coercion rules"):
`Result<Option<String>,String>` → `Result Error (Maybe String)`;
`Result<Vec<HashMap<String,String>>,String>` → `Result Error (List (Dict String
String))`; `String→String`, `i64→Int`, `bool→Bool`. **Every row is `fallible`
(sync `Result`) → binds as a bare Sky `Result`, consumed synchronously — exactly
matching the Go `Lib/Db.sky` shape.** (Confirms §3.4 incl. the
`Vec<HashMap<String,String>>` return coercion, which `translateRustRet`'s
`Vec<T>` per-element rule supports.)

**Marshalling decision (resolves §2.5, §13.3):** the wrappers return
**pre-flattened `HashMap<String,String>` rows**, NOT JSON strings. This dodges the
known-broken `Sky.Core.Json.Decode.Pipeline` (`Box<dyn FnOnce>`) wall entirely —
the Sky side never JSON-decodes a row; it reads `Dict String String` via the
existing `Db.getField`/`getInt`/`getBool`, byte-for-byte as the Go app does. The
wrapper does the `serde_json::Value` → flat-String conversion internally
(§4.4 stringification: int `5`→`"5"`, bool→`"true"`/`"false"`, matching
`Fmt.sprint`'s `%v` so `Db.getBool`'s `"1"||"true"` and `Db.getInt`'s parse stay
correct).

### `sky-firestore-shim` (over `firestore` 0.49)

`Lib/Db.sky` needs exactly 6 ops + accessors. Coarse surface (§2.10 — collapse,
keep `Page/*` unchanged):

| Wrapper fn (sync, in `block()`) | Sky-bound type | Underlying `firestore` 0.49 call |
|---|---|---|
| `firestore_get(collection: String, id: String) -> Result<Option<HashMap<String,String>>, String>` | `getDoc` → `Result Error (Maybe (Dict String String))` | `db.fluent().select().by_id_in(&c).obj::<serde_json::Value>().one(&id).await?` → flatten + inject `_firestore_id`→`"id"` |
| `firestore_set(collection, id, fields: HashMap<String,String>) -> Result<(), String>` | `setDoc` → `Result Error ()` | `db.fluent().update().in_col(&c).document_id(&id).object(&doc).execute::<Value>()` (no `.fields()` ⇒ merge-all upsert) — §2.6 satisfied: whole-object upsert preserves unspecified server fields |
| `firestore_query(collection) -> Result<Vec<HashMap<String,String>>, String>` | `queryDocs` → `Result Error (List (Dict String String))` | `select().from(&c).obj::<Value>().stream_query_with_errors().await?` → `try_collect` → flatten each |
| `firestore_query_where(collection, field, op, value: String, is_bool: bool) -> Result<Vec<HashMap<String,String>>, String>` | `queryWhere` → `Result Error (List (Dict String String))` | `.filter(\|q\| q.field(&field).eq(v))` where `v = FirestoreValue::from(bool_or_string)` (§4.3) |
| `firestore_query_where_order(collection, field, op, value, is_bool, order_field, dir) -> Result<Vec<…>, String>` | `queryWhereOrder` | as above + `.order_by([(&order_field, Ascending\|Descending)])` |
| `firestore_delete(collection, id) -> Result<(), String>` | `deleteDoc` → `Result Error ()` | `db.fluent().delete().from(&c).document_id(&id).execute().await?` |

Notes:
- **id injection (§4.5):** deserialize each doc to `serde_json::Value`; the
  firestore-rs deserializer injects `_firestore_id`; the wrapper re-keys it to
  `"id"` in the flat map (research §7). Every Sky `Dict.get "id" row` then works.
- **query value typing (§4.3):** the Sky surface only ever uses `op == "=="` and
  passes either a `String` or a `Bool`. The wrapper takes the value as `String`
  plus an `is_bool: bool` discriminator and builds
  `FirestoreValue::from(true/false)` vs `FirestoreValue::from(string)`. The ported
  `Lib/Db.sky` `queryWhere`/`queryWhereOrder` gain a tiny shim that derives
  `is_bool` from the Sky call site — see Part 3 (the only `Lib/Db.sky` body edit).
  Other operators are absent in the app (grep: only `"=="`), so the wrapper only
  implements equality + order (§4.2).
- **error text (§2.4):** `firestore::FirestoreError` Display embeds the tonic
  status name verbatim (`PermissionDenied`, `NotFound`, `Unavailable` —
  research §8), so `Lib/Db.sky::wrapDbError`'s `String.contains` heuristics
  classify correctly **unchanged**. The wrapper returns `format!("{e}")`.
- **client cache (§2.7):** `OnceLock<Option<FirestoreDb>>`, built once on first
  call (lazy, after `.env` is loaded — §11.2), `FirestoreDb` is `Arc`-cheap to
  reuse. No `Box<dyn Any>` global. Emulator honoured via `FIRESTORE_EMULATOR_HOST`
  with no code change (research B.1).
- **no iterator crosses FFI (§2.11):** every query `try_collect`s to an owned
  `Vec` inside `block()` before returning. Confirmed.

### `sky-stripe-shim` (over `async-stripe` 1.0.0-rc.6)

`Lib/Stripe.sky` needs 3 coarse ops (§2.9 — collapse the ~30 fine-grained Go
builder setters; `async-stripe`'s builders are not auto-bindable, and a coarse
surface is far less work AND keeps the Stripe logic faithful):

| Wrapper fn | Sky-bound type | Underlying `async-stripe` 1.0-rc call |
|---|---|---|
| `stripe_get_or_create_customer(secret: String, name: String, email: String) -> Result<String, String>` | `Result Error String` (customer id) | `ListCustomer::new().email(&email).send(&client)` → reuse `.data[0].id` else `CreateCustomer::new().email().name().send(&client)` |
| `stripe_create_checkout(secret, customer_id, success_url, cancel_url, line_items_json: String) -> Result<HashMap<String,String>, String>` | `Result Error (Dict String String)` with keys `id`,`url` | build `CreateCheckoutSession::new().mode(Payment).success_url().cancel_url().customer().line_items(vec).shipping_address_collection().phone_number_collection().send(&client)`; return `{id, url}` |
| `stripe_verify_session(secret, session_id) -> Result<HashMap<String,String>, String>` | `Result Error (Dict String String)` 10 keys | `RetrieveCheckoutSession::new(id).send(&client)`; extract status/payment_status/customer_details + `collected_information.shipping_details.address` |

Notes:
- **line items (§6.1):** the ONE place a small JSON crosses the boundary — the
  Sky side builds a tiny JSON array `[{title,unit_amount,currency,quantity}, …]`
  using `Sky.Core.Json.Encode` (the *encoder*, which works on Rust — only the
  *pipeline decoder* is broken). The wrapper `serde_json::from_str`s it (a flat
  array of 4-field objects, trivially `Deserialize` — not the pipeline pattern)
  and maps to `CreateCheckoutSessionLineItems` with nested `PriceData`/
  `ProductData` (research §2 field shapes). This is the minimal-friction way to
  pass N variable line items through one coarse call.
- **verify fields (§6.3):** `status == Some(Complete)` + `payment_status == Paid`;
  customer_details name/email/phone; shipping from
  `session.collected_information.shipping_details.address` (research §4 confirmed
  the exact path — NOT a top-level `shipping_details`). The wrapper returns all 10
  `PaymentStatus` fields as a flat `HashMap`; the ported `Lib/Stripe.sky`
  reconstructs the `PaymentStatus` record from `Dict.get`s (small rewrite of
  `verifyStripeSession` — see Part 3).
- **client/key (§2.8):** `Client::new(secret)` per call is cheap (or cache by
  secret in a `OnceLock`); preserves the empty-key early-out (D-bridge).
- **customer iterator (§2.11):** `ListCustomer.send` returns an owned
  `List<Customer>`; the wrapper reads `.data.into_iter().next()` — no lazy
  iterator crosses FFI.
- **error text:** `stripe::StripeError` Display is stable; wrapper returns
  `e.to_string()`, mapped by `Error.network` in Sky as today.
- **TLS coexistence (§13.4/§13.5):** firestore's tonic stack and async-stripe both
  on rustls; the wrapper crates' `Cargo.toml` pin async-stripe
  `features=["blocking","rustls-tls-webpki","rustls-ring"]` and let firestore pull
  its rustls default, on a single `ring` crypto provider, to avoid a duplicate
  `CryptoProvider`. tokio 1.x is shared with axum/sqlx (research §7/§9). The
  generated `sky-app` graph adds tonic/prost/gcloud-sdk + the stripe crates —
  heavy but a single unified rustls graph.

### Crate layout (§2.1)

```
examples/rust/skyshop-rs/
  sky.toml
  firestore-shim/        Cargo.toml + src/lib.rs   (the sync wrapper)
  stripe-shim/           Cargo.toml + src/lib.rs
  src/                   the ported Sky (mirrors examples/13-skyshop/src/)
  static/                carried verbatim (favicons)
  .env.example           adapted (Part 5)
  e2e.json               carried (GET / → 200, no panic)
  README.md              runbook + the ../../ path-dep convention
```

Both wrapper crates are tiny (`src/lib.rs` only), self-contained, referenced by
the `../../firestore-shim` relative path (D0.2 detail a).

---

## Part 3 — Sky-module port order (file-by-file)

Order is staged so the tree compiles green at each checkpoint (Part 4).

| File | Disposition | Reason |
|---|---|---|
| `src/State.sky` | **verbatim** | pure types (Model/Msg/Page), zero FFI, zero Std.Ui (§1.1) |
| `src/Lib/Translation.sky` | **verbatim** | 781 lines pure `case` on string keys, EN/中文. Chinese literals are UTF-8 string literals — emit fine on Rust (the README "Bytes non-ASCII" caveat is about `Bytes` *encoding* round-trips, NOT string literals — §7.1 resolved). Confirmed no `Std.*` the Rust backend lacks |
| `src/Lib/Money.sky` | **verbatim** | pure arithmetic, no FFI (§1.2) |
| `src/Lib/Cart.sky` | **near-verbatim — swap one import** | pure logic over `Db.*` bare-`Result` ops, BUT it imports `Github.Com.Google.Uuid` (a Go-FFI dep that trips the Rust Go-FFI refusal). Swap `import Github.Com.Google.Uuid as Uuid` → `import Sky.Core.Uuid as Uuid` (stdlib, on Rust) and adjust the call shape (`Uuid.v4`/`Pure.uuidV4 ()` per Limitation #7). Otherwise unchanged once Db ports |
| `src/Lib/Products.sky` | **verbatim** | pure over `Db.queryWhere*OrLog`; unchanged |
| `src/Page/*` (7 files) | **verbatim** | pure view + Msg dispatch over `Std.Html`+Tailwind; no FFI (§8, §1.1) |
| `src/Ui/Layout.sky` | **verbatim** except the Firebase script string (still pure — it's a literal) | `Std.Html`/Tailwind render byte-identically on Rust's Live VNode path (Std.Ui-parity proven; raw `Std.Html` is the same `html.rs render_html`). The `raw (OAuth.firebaseAuthScript ())` injection (`Layout.sky:615`) works — Rust reuses the Go client JS incl. `__sky_send` and `__skyReviveScripts` (§5.3, §9.3, §9.4 — README: "reuses the Go client JS") |
| `src/Lib/Db.sky` | **rewrite FFI surface only** | swap `import Cloud.Google.Com.Go.Firestore` → `import Rust.Sky_firestore_shim as FS`; drop `ctx`/`Context.background`/`js "nil"`/`mergeAll`/`getFirestoreClient`/`snapshotToDict`/iterator plumbing (the wrapper owns all of it); the 6 exported ops become thin calls to `FS.firestore_*`. `wrapDbError`, `getField/getInt/getBool`, `intVal/boolVal/floatVal`, the `*OrLog` helpers — **kept verbatim** (they operate on `Dict String String` which the wrapper still returns). Net: ~545 → ~120 lines, same exported surface, so every caller (`Cart`, `Products`, `Stripe`, `Auth`, `Page/*`) is unchanged. The ONE body subtlety: `queryWhere`/`queryWhereOrder` derive the `is_bool` arg — the Go app calls `queryWhere "published" "==" True` (Bool) and `queryWhere "order_id" "==" orderId` (String). In the Go source the polymorphic `value` is the divergence point; in the port the two arities are split: keep `queryWhere : String→String→String→String→Result …` for the String values, add `queryWhereBool` for the `published == True` site (one call site, in `Products.sky`). This is a minimal, typed divergence forced by Rust's monomorphic FFI (§4.3) |
| `src/Lib/Stripe.sky` | **rewrite FFI surface** | swap the 3 Go Stripe imports → `import Rust.Sky_stripe_shim as SS`. `createCheckoutSession`: keep the empty-key guard + `getOrCreateCustomer` + `domainUrl` logic; replace the ~30 builder-setter `Result.andThen` chain with: build line-items JSON via `Json.Encode`, call `SS.stripe_create_checkout`, read `Dict.get "id"/"url"`. `verifyStripeSession`: replace the fine-grained getters with one `SS.stripe_verify_session` + `Dict.get`s reconstructing the `PaymentStatus` record. `deductStock`/`buildLineItem` logic kept (pure). `getOrCreateCustomer` collapses to one `SS.stripe_get_or_create_customer` call. Same exported surface (`createCheckoutSession`, `verifyPayment`, `deductStock`, `CheckoutInfo`) |
| `src/Lib/Auth.sky` | **rewrite verify path** (Sky-native JWKS) | no Rust Firebase Admin SDK (§5.1). Choice **(b) — pure-Sky verify**: drop the Firebase/Option/Context imports; `verifyToken idToken` becomes: (1) if `FIREBASE_AUTH_EMULATOR_HOST` set → decode payload WITHOUT signature (emulator tokens are `alg=none`, research B.2) and read `aud`/`sub`/`email`; (2) else fetch Google X.509 certs via `Http.get` (the securetoken endpoint), pick the `kid`, `Jwt.decode (Jwt.rs256 pem) now token` (Sky.Core.Jwt RS256 takes a **PEM public key** — confirmed `Jwt.sky:38,50,168`), then assert `aud == projectId`, `iss == https://securetoken.google.com/<projectId>`, `sub` non-empty. `findOrCreateUser`/`getSessionUser`/`isAdmin`/`adminEmails`/`getUserById` — **kept verbatim** (they call `Db.setDoc`/`getDoc`, the merge-upsert preserved by the wrapper's whole-object `update` — §2.6). This is the one structurally-different module, justified by the absent Admin SDK; it's *more* faithful than a stub because it really verifies |
| `src/Lib/Notify.sky` | **drop dead Go imports** | `Net.Http`/`Strings`/`Io`/`Github.Com.Google.Uuid` are dead (the email path is a `println` stub — §1.5). Replace `Uuid.newString` with `Sky.Core.Uuid.v4` (stdlib, on Rust). Drop the 3 Go stdlib imports entirely (they'd trip the Go-FFI refusal). Keep the Firestore-write of the `notifications` doc (via the ported `Db.setDoc`) and the `println`. No new FFI |
| `src/Lib/OAuth.sky` | **verbatim** | `firebaseAuthScript` is a pure string (client-side JS), `handleAuthCallback` just calls `Auth.verifyToken`. No server FFI |
| `src/Main.sky` | **near-verbatim, one `init` edit** | the `init req` cookie read (`Dict.get "cookies" req`) does NOT type-check on Rust's typed `LiveReq` (§5.4/§13.8). Rewrite the cookie read to `req.cookies` (typed field) + `Dict.get "sky_user" req.cookies`. `init`'s signature changes `a -> …` to take `LiveReq` (the Rust backend pins param 0 to `LiveReq` for a req-reading init — README "Sky.Live init request"). Everything else (routes, update, view dispatch, the FirebaseAuth Msg handler calling `OAuth.handleAuthCallback`) is unchanged. This is a justified, minimal divergence — the typed req is *stronger* than the Go Dict |

**Why `Page/*` and the view layer port verbatim (§9.1/§1.4):** skyshop uses
`Std.Html`+Tailwind, not `Std.Ui` — which *helps*: raw `Std.Html` goes through the
same shared `html.rs render_html` serializer that the Std.Ui-parity corpus
proves byte-identical, and Tailwind classes are plain string attribute values
(pure Sky, no kernel). The Tailwind package portability (§1.3/§9.2/§13.7) — see
Risk R4.

---

## Part 4 — Build & run-verify strategy

### Staging (each checkpoint = `sky build --target rust && cargo build` exit 0)

The order de-risks the async bridge from the Sky-compile problem (§12.1/§12.2):

- **Stage 0 — compiler change.** Add `RustPathDep` to `Toml/Rust.hs` + the
  `emitDepLine` arm + the `parseInlineTable` path branch + `runRustInspectorPath`
  in `Ffi.hs`. `cabal build exe:sky`; symlink `sky-out/sky`. Prove with a
  throwaway 1-fn path-crate that `sky add`/build wires a path dep + binds it.
- **Stage 1 — STUB wrappers + full Sky port.** Both `firestore-shim`/`stripe-shim`
  ship signature-real, body-stub (`Ok(empty)` / `Err("not configured")`) — NO
  async deps yet. Port all 19 Sky modules (Part 3). **Checkpoint proves:** the
  8,200-line Sky port compiles end-to-end, the FFI binds (module names, coercions,
  bare-`Result` consumption), `init`/`Layout`/routing/views all type-check, with
  zero heavy crates. This is the big de-risk: the Sky-compile problem is solved
  before the async problem exists.
- **Stage 2 — real firestore-shim.** Wire `firestore` 0.49 + the dedicated-thread
  `block()` bridge + flatten/id-inject. **Checkpoint proves:** the tonic/gcloud
  graph compiles in `sky-app`, TLS unifies, the bridge type-checks. Run-verify
  against the **Firestore emulator** (below).
- **Stage 3 — real stripe-shim.** Wire `async-stripe` 1.0-rc + line-item JSON +
  verify extraction. **Checkpoint proves:** stripe crates + firestore coexist
  (one rustls graph). Run-verify against **Stripe test mode**.
- **Stage 4 — Sky-native auth.** Wire the JWKS/Jwt verify path. **Checkpoint:**
  full build green + the auth-emulator bypass branch.

### Run-verification (the new means)

- **Creds-less smoke** (every stage ≥1): boot the binary with NO env; `curl /` →
  200; Home shows empty products (D-bridge); grep stderr for `panic`/backtrace.
- **Firestore emulator** (Stage 2+): `gcloud emulators firestore start
  --host-port=localhost:8080`; run with `FIRESTORE_EMULATOR_HOST=localhost:8080`
  `GOOGLE_CLOUD_PROJECT=skyshop` (no creds needed — emulator bypasses auth,
  research B.1). Seed a `products` doc; verify Home lists it, AddToCart writes a
  `carts`/`cart_items` doc, admin product CRUD round-trips.
- **Stripe test mode** (Stage 3+): `STRIPE_API_KEY=sk_test_…`; drive
  StartCheckout → assert a `cs_test_…` session id + a checkout URL come back;
  optionally complete with card `4242 4242 4242 4242` and hit
  `/order/:id/success` → `verifyPayment` retrieves `status=complete,
  payment_status=paid`. No emulator — real test API (research B.3,
  https://docs.stripe.com/testing).
- **Auth emulator** (Stage 4): `firebase emulators:start --only auth` +
  `FIREBASE_AUTH_EMULATOR_HOST=localhost:9099`; the `alg=none` bypass branch
  verifies the token and `findOrCreateUser` writes the `users` doc to the
  Firestore emulator. Admin gating via `ADMIN_EMAILS`.

### Disk/build hygiene (§12.4)

The tonic+prost+gcloud-sdk+async-stripe+tokio tree is large. skyshop-rs uses its
**OWN** `CARGO_TARGET_DIR` (e.g. `~/.cache/sky-rust-target-skyshop`) so it does
not poison the shared leaf-example sweep cache. Export sccache. `rm -rf
sky-out/Rust/target` after build per the sweep idiom. Classified `out` in
`equiv-classification.tsv` (no Go counterpart to diff — §0.4); add the
classification row so the coverage gate passes; the example is NOT added to the
default `rust-sweep.sh` set (heavy deps + live creds) — it gets a dedicated
opt-in runner note.

### Minimum compiler/runtime changes (§12.5) — all in-boundary

1. `src/Sky/Sky/Toml/Rust.hs`: `RustPathDep` variant + parse branch (allowed).
2. `src/Sky/Generate/Rust/Builder/Emitter.hs`: `emitDepLine` `RustPathDep` arm
   (allowed).
3. `src/Sky/Build/Rust/Ffi.hs`: `runRustInspectorPath` front-door (allowed).
4. (maybe) `src/Sky/Generate/Rust/Project.hs`: nothing required if the `../../`
   path convention (D0.2-a) is used; only touched if D0.2-b absolute-path
   rewrite is needed (allowed).

NO change to `runtime-rust/src/` is required — the bridge lives in the wrapper
crates (under `examples/rust/`, allowed), reusing the *pattern* from `task.rs`,
not editing it. NO new return-coercion shape is needed (`Vec<HashMap<String,
String>>` already covered, §3.4). NO Go-backend / shared-stdlib / upstream-example
edits (§0.4 honoured).

### Inspector prerequisite (§12.6)

`cargo +nightly rustdoc` runs against the **wrapper** crate. rustdoc-JSON needs
the wrapper's deps *resolved* (cargo metadata) but does NOT compile firestore/
async-stripe to machine code for doc extraction of the wrapper's own surface —
the wrapper's public fns are plain `fn(String,…)->Result<…,String>`, so the
inspected surface is tiny and clean. (If rustdoc on the heavy transitive graph is
slow, the wrapper can `#![doc]`-scope to its own items; the inspector only reads
the wrapper crate's public items anyway.)

---

## Part 5 — Env / config / session store (answers §10, §11)

- **`[live] store="sqlite"` + `storePath` + `static`** all work on Rust (README:
  sqlite session store shipped; `27-live-static`/`32-live-sessions`). The sqlite
  *session store* pulls the same sqlx/`db` feature wiring (§10.1) — fine; it's the
  ONLY sqlite use now (Std.Db-Firestore is replaced by the wrapper). `static` dir
  served (§1.7) — carry `static/` + `e2e.json` verbatim.
- **`System.getenv`/`getenvOr`** work on Rust (MEMORY: getenv-returns-bare-String
  fixed). `.env` is loaded by the Sky.Live runtime before `init` (§11.2), so the
  lazily-built wrapper clients see the vars on first call.
- **Credential env vars (§11.1):** `firestore` 0.49 reads ADC /
  `GOOGLE_APPLICATION_CREDENTIALS` / `GOOGLE_CLOUD_PROJECT` natively (research
  A/B) — same vars the Go app used. `async-stripe` reads `STRIPE_API_KEY` (threaded
  to `Client::new` by the wrapper). Emulator: `FIRESTORE_EMULATOR_HOST`,
  `FIREBASE_AUTH_EMULATOR_HOST`.
- **Ported `.env.example` (§11.3):** keep `ENV`, `DOMAIN`, `SKY_LIVE_PORT`,
  `STRIPE_API_KEY`, `ADMIN_EMAILS`, `GOOGLE_CLOUD_PROJECT`,
  `GOOGLE_APPLICATION_CREDENTIALS`, `FIREBASE_API_KEY`, `AUTH_DOMAIN`,
  `SKY_LIVE_*` session vars; ADD `FIRESTORE_EMULATOR_HOST`,
  `FIREBASE_AUTH_EMULATOR_HOST`; DROP `STRIPE_WEBHOOK_SECRET` (no webhook — §6.4,
  the success-URL `verifyPayment` polling is the whole flow) and the `SMTP_*`/
  `NOTIFY_TO` block (Notify email is a stub — §1.5). Session TTL `SKY_LIVE_TTL`
  honoured (§10.3).
- **Admin panel (§8):** builds (pure view + Msg). Image upload (§8.2) is a base64
  string field written to Firestore `product_images` via the wrapper — no new FFI;
  ensure `[live] maxBodyBytes` raised for large base64 images. Order-state
  transitions are plain Firestore writes (§8.3).

---

## Part 6 — Risk register

| # | Risk | Likelihood | Mitigation |
|---|---|---|---|
| R1 | `block_on`-in-axum panic (§13.1) | **was high → now low** | Dedicated-thread runtime via the `task.rs` pattern; `.join()` converts internal panics to `Err`. Proven-safe shape already in the runtime |
| R2 | path-dep unsupported (§13.2) | medium → resolved by Stage 0 | `RustPathDep` is a ~10-line in-boundary add; gated as the FIRST stage with a throwaway proof crate before the big port |
| R3 | JSON pipeline decoder wall (§13.3) | **eliminated** | Wrappers return flat `HashMap<String,String>` rows — Sky never runs the pipeline decoder. The one JSON crossing (stripe line-items) uses the *encoder* (works) + `serde_json::from_str` on a flat shape (no pipeline) |
| R4 | Tailwind package portability (§13.7) | medium | The package is fetched under `[dependencies]` (a *Sky* package). VERIFY at Stage 1 it's pure Sky (no Go-FFI/kernel) by inspecting `.skydeps` after fetch. If it carries a kernel the Rust backend lacks, the fix is in-boundary (surface the kernel) OR a thin Rust-target stdlib override at `runtime-rust/sky-stdlib-overrides/`. The view is raw-`Std.Html` underneath, so worst case the Tailwind helpers are reimplemented as pure string builders (they emit class strings) |
| R5 | async-stripe 1.0-rc churn / feature-name drift (§13.4) | medium | Research flagged the README's `runtime-tokio-*` feature names are STALE; use `blocking`+`rustls-tls-webpki`+`rustls-ring`. Pin all `async-stripe-*` crates to the SAME rc.6. Verify the `StripeError` variant names at wire-up (Display is stable regardless) |
| R6 | firestore tonic/rustls vs axum/sqlx version clash (§13.5) | medium | Single rustls graph, one `ring` crypto provider; if a duplicate `CryptoProvider` surfaces, call `CryptoProvider::install_default()` once at boot (in the wrapper's lazy init). tokio 1.x shared. Stage 2 checkpoint catches a clash early |
| R7 | Firebase verify has no turnkey Rust crate (§13.6) | low | Resolved by the Sky-native path: `Http.get` JWKS + `Jwt.decode` RS256 (PEM) + manual `aud`/`iss`/`sub` checks; emulator `alg=none` bypass. More faithful than a stub; uses only shipped Rust stdlib surface |
| R8 | `init` typed-LiveReq mismatch (§13.8) | resolved | Rewrite cookie read to `req.cookies`; documented divergence, stronger than Go's Dict |
| R9 | Std.Html/Tailwind render parity not in build-green (§13.9) | low | Covered by the run-verify web check (boot + curl + a headless click on AddToCart). Std.Html shares the proven `render_html` serializer |
| R10 | rustdoc on heavy transitive graph slow/flaky (§12.6) | low | Inspector reads only the wrapper's tiny public surface; scope docs to the wrapper's own items if needed |

---

## Appendix — questions explicitly resolved

§0.1 stale `[rust.shims]` (yes); §0.2 add `RustPathDep`; §0.3 slug/cache path;
§0.4 boundary honoured, classify `out`; §0.5 build-green + run-verified-structural.
§1.1–1.7 disposition table (Part 3) + static/e2e carried. §2.1–2.11 wrapper layout,
dedicated-thread bridge, flat-Dict marshalling, merge-via-whole-object-update,
error-text preserved, OnceLock client, no iterator crosses FFI. §3.1–3.6 module
`Rust.Sky_firestore_shim`/`Rust.Sky_stripe_shim`, path dep, slug, bare-`Result`
coercion, `fallible` classification, `ctx`/`js "nil"` vanish (`js` has no Rust
codegen meaning — the wrapper owns context). §4.1–4.6 collections, `==`+order only,
String+is_bool value typing, `%v`-matching stringification, id-injection,
write-as-strings (Go-parity fidelity). §5.1–5.5 Sky-native JWKS verify, emulator
bypass, typed-`LiveReq` cookie, blocking read in init safe via the thread bridge.
§6.1–6.6 coarse checkout/verify/customer, collected_information shipping path,
NO webhook, empty-key dry-run, deductStock/notify via same wrapper. §7.1–7.2 i18n
verbatim, Chinese literals fine, no FFI. §8.1–8.3 admin builds, base64 image →
Firestore, maxBodyBytes. §9.1–9.4 Std.Html shared serializer, Tailwind risk R4,
`__sky_send` + script injection reused from Go client JS. §10.1–10.3 sqlite store
+ static + TTL on Rust. §11.1–11.3 env vars + `.env` timing + adapted example.
§12.1–12.6 staging, stub-first, done-criteria, own target dir, minimal in-boundary
compiler changes, inspector prereq. §13.1–13.10 risk register (Part 6).
