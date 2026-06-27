# skyshop-rs port plan — Reasoner B

> **SUPERSEDED — non-authoritative.** This reasoner plan was folded into
> `2026-06-15-skyshop-rs-port-SYNTHESIS.md` (locked decisions D1–D6). Two of
> plan-B's headline choices were overridden by the shipped port: D5 mandates a
> **Std.Ui rewrite**, so plan-B's `Std.Html`+sky-tailwind "14/19 files
> byte-for-byte" view-parity claim does NOT hold; and D4 ships the wrapper deps
> as `RustGitDep` `file://` (no `RustPathDep` — `Sky/Toml/Rust.hs` has no path
> variant), so plan-B's `RustPathDep`-primary recommendation did not ship. Kept
> for grep; act on SYNTHESIS, not this plan.

A faithful 1:1 port of `examples/13-skyshop` (Sky.Live e-commerce, ~9.6k lines /
19 `.sky` files) to the Sky→Rust backend (`sky build --target rust`), with Rust
crates (`firestore` 0.49, `async-stripe` 1.0.0-rc.6, hand-rolled Firebase JWKS)
replacing the Go-FFI deps. New fork-local example: `examples/rust/skyshop-rs/`.

**Modification boundary (never cross):** only `runtime-rust/`,
`src/Sky/Generate/Rust/`, `src/Sky/Build/Rust/`, `src/Sky/Sky/Toml/Rust.hs`,
`tools/sky-ffi-inspect-rs/`, `examples/rust/`. Never edit `examples/13-skyshop`,
`sky-stdlib/`, or the Go backend. No panic vector. No `Box<dyn Any>`. Build-green
mandatory; run-verify via Firestore emulator + Stripe test mode is now possible.

The single load-bearing finding of this investigation, which makes the whole port
**near-verbatim** rather than a structural rewrite:

> The original consumes EVERY external call **synchronously** as a bare
> `Result Error a` (`case Firestore.queryDocuments q ctx of Err e -> …`). The Rust
> FFI inspector binds a wrapper `fn(args) -> Result<T, String>` that is *not*
> classified `effectful` as a **synchronous** Sky `args -> Result Error T` — NOT a
> `Task`. So if our wrapper crates expose blocking-but-total sync functions, the
> Sky call sites in `Lib/Db.sky`, `Lib/Stripe.sky`, `Lib/Auth.sky` keep their
> `case`-on-`Result` shape unchanged, and **nothing in `Page/*` / `update` /
> `init` is re-threaded for `Task`/`Cmd.perform`.** The blocking happens *inside*
> the wrapper (a worker-thread + own runtime — §Decision 1), invisible to Sky.

---

## Decisions (one per blocker)

### Decision 0 — scope/fidelity bar (resolves Q0.5, Q1.6)

**"Faithful 1:1" = structurally faithful + build-green + run-verifiable against the
emulators, NOT byte-identical Firestore/Stripe wire behaviour.** Concretely the
bar is:

1. `sky build src/Main.sky --target rust` exit 0 **and** `cd sky-out/rust && cargo
   build` exit 0 (the hard gate).
2. Creds-less boot reachable: binary starts, `curl localhost:<port>/` → 200, no
   `panic`/abort in stderr (the original logs a Firestore error and renders an
   empty product grid; our wrapper must reproduce this — a lazy client that never
   constructs until first query, returning `Err` cleanly, never panicking).
3. Run-verified happy path against **Firestore emulator** (`gcloud emulators
   firestore start`, `FIRESTORE_EMULATOR_HOST` env) + **Stripe test mode**
   (`sk_test_…`, test card `4242 4242 4242 4242`): seed a product, browse, add to
   cart, checkout (test-mode Checkout Session), return-URL verify.
4. Auth run-verified against the emulator's token path (Decision 3) — or, if the
   emulator's RS256 path is impractical in CI, a documented emulator-mode stub.

Every Sky module is ported with the **same control flow** (same `case`/`if`,
same Msg dispatch, same error-banner UX). Divergences are enumerated below and are
limited to: (a) `init req` Dict→record (Decision 2), (b) the three FFI surface
modules' import + call shape (`Lib/Db`, `Lib/Stripe`, `Lib/Auth`), (c) UUID
generation, (d) dropping dead Go imports in `Lib/Notify`. Everything else ports
verbatim.

### Decision 1 — async→sync bridge: dedicated worker-thread + own current-thread runtime (resolves Q2.2, Q5.5, Q13.1 — THE central risk)

Both `firestore` and `async-stripe` are async. The Sky.Live app already runs
inside an axum/tokio multi-thread runtime. Calling `Runtime::block_on` or
`Handle::block_on` from within that ambient runtime **panics** ("Cannot start a
runtime from within a runtime") — an instant violation of the no-panic
existential. `block_in_place` only works on a multi-thread runtime and still
needs the ambient `Handle`; it is fragile when the same wrapper must also run
under Sky.Cli (no ambient runtime at all). Reject both.

**Chosen mechanism — a per-wrapper-crate "blocking bridge":** the wrapper crate
spawns ONE dedicated OS thread at first use, owning its own
`tokio::runtime::Builder::new_current_thread().enable_all().build()` runtime. The
public sync FFI functions send a request enum over a `std::sync::mpsc::Sender` and
**block on `std::sync::mpsc::Receiver::recv()`** for the reply. The worker thread
`rt.block_on(async { … })`s each request on its *own* runtime.

Why this is panic-free in every context:

- The **caller** (axum worker thread, or Sky.Cli main thread) only does a
  std blocking channel `recv()` — never a tokio `block_on`. A std blocking call on
  an axum worker thread parks that worker; it does not nest runtimes. (It does hold
  the worker for the call's duration — acceptable: the original Go code is equally
  synchronous and blocks the request goroutine.)
- The **worker thread's** `block_on` runs on a runtime with NO ambient runtime on
  that thread, so the nested-runtime panic is structurally impossible.
- Works identically under Sky.Cli (no ambient runtime) — the bridge is
  self-contained.

Container for the bridge without `Box<dyn Any>` and without a `static mut`:
`once_cell::sync::Lazy<BlockingBridge>` (or `std::sync::OnceLock`). The bridge
holds the typed `Sender<FsRequest>` (a concrete enum, not `dyn Any`). This is
inside the **wrapper crate**, not in generated code or `sky_runtime`, so it does
not touch the no-`Any` audit of the Sky backend at all — but we hold the wrapper
to the same bar anyway (no `unwrap`/`expect`/`panic`; channel send/recv errors map
to `Err(String)`).

A lighter alternative — `futures::executor::block_on` on a current-thread future —
is rejected because `firestore`/`async-stripe` internally spawn tokio tasks
(reqwest/tonic require a tokio reactor), which a bare `futures` executor doesn't
provide → I/O hangs. The worker thread owning a real tokio runtime is the correct
floor.

**Lazy client construction:** the worker thread constructs `FirestoreDb` /
`stripe::Client` lazily on first request and caches it in a worker-local
`Option<…>`. A creds-less boot never constructs the client (no query fires until
a page needs data; the home page's `Products.listProducts` does fire on `init`,
but the wrapper returns `Err("firestore: not configured")` which `queryWhereOrLog`
already logs-and-returns-`[]`, exactly mirroring the Go original).

### Decision 2 — `init req` Dict→typed `LiveReq` (resolves Q5.4, Q10.2, Q13.8)

The Go `init` reads `req` as a Dict: `Dict.get "cookies" req` then `Dict.get
"sky_user" cookies`. On Rust, `init`'s param 0 is the typed `LiveReq` record
(`path`/`query`/`method`/`params`/`headers`/`cookies`) and `req` is a record, not a
Dict — `Dict.get "cookies" req` will not type-check (README "Sky.Live `init`
request — typed-record `LiveReq`"; codegen pins param 0 to `LiveReq` because the
body uses it — `collectLiveReqInitFns`).

**Exact rewrite (the ONLY structural divergence in `Main.sky`):**

```elm
-- ORIGINAL (Go, Dict req)
init : a -> ( Model, Cmd Msg )
init req =
    let _ = Db.initDb ()
        products = Products.listProducts
        cookies =
            case Dict.get "cookies" req of
                Just c -> c
                Nothing -> Dict.empty
        userUid =
            case Dict.get "sky_user" cookies of
                Just uid -> uid
                Nothing -> ""
        ...

-- PORT (Rust, typed LiveReq) — same logic, one line changes
init : LiveReq -> ( Model, Cmd Msg )
init req =
    let _ = Db.initDb ()
        products = Products.listProducts
        userUid =
            case Dict.get "sky_user" req.cookies of   -- req.cookies : Dict String String
                Just uid -> uid
                Nothing -> ""
        ...
```

`req.cookies` is the typed field; the intermediate `cookies` binding + its
`case` collapse into the direct field read. **This is the only `init` divergence,
and the only place `req` is touched** (grep confirms `Dict.get "cookies" req`
appears once). The `LiveReq` type is in scope via the live prelude; `31-live-req`
proves the shape on Rust. The first-render user pre-load behaves identically (no
extra round-trip). `getSessionUser userUid` then does a blocking Firestore read in
`init` — safe under Decision 1 (the bridge works in `init`'s synchronous body
exactly as in `update`).

This rewrite is small enough that the port can carry a `// PORT-DIVERGENCE:` code
comment naming it; nothing else in `Main.sky` changes.

### Decision 3 — Firebase auth / OAuth (resolves Q5.1, Q5.2, Q5.3, Q13.6)

Three pieces in the original auth flow:

1. **Client-side** (`Lib/OAuth.firebaseAuthScript`): a raw `<script>` injecting the
   Firebase JS SDK, `signInWithPopup`, posting the ID token via
   `window.__sky_send('FirebaseAuth', [token])`. **Ports byte-for-byte, NO Rust
   change.** The Rust Live renderer injects raw `<script>` identically
   (`__skyReviveScripts`, README), reuses the Go client JS (so `window.__sky_send`
   exists), and the `FirebaseAuth String` Msg round-trips through the same
   custom-event path. Verify in the web-sweep, but expect zero edits.
2. **Server-side token verification** (`Lib/Auth.verifyToken`): the original calls
   the Go Firebase Admin SDK (`FirebaseAuth.clientVerifyIDToken`). No mature Rust
   Firebase Admin SDK exists. **Chosen: a third fork-local wrapper crate
   `firebase-auth-shim` that verifies the Google-signed RS256 ID token via JWKS** —
   `jsonwebtoken` + `reqwest` (or `gcp_auth`/`firebase-verifyid` if it builds
   clean): fetch + cache Google's certs from
   `https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com`
   (or the JWK form), select the key by the token's `kid`, verify RS256, check
   `alg=RS256`, `exp`, `aud == GOOGLE_CLOUD_PROJECT`, `iss ==
   https://securetoken.google.com/<project>`, return the decoded UID + claims
   (email, name) as a flat JSON string. The wrapper is **sync** (worker-thread
   bridge, Decision 1) so `verifyToken`'s `case getAuthClient () of …`/`case
   FirebaseAuth.clientVerifyIDToken … of …` shape ports near-verbatim.

   *Why a wrapper crate, not Sky's `Sky.Core.Jwt` (README: RS256 shipped on
   Rust)?* `Sky.Core.Jwt.decode` verifies a token against a key the caller
   supplies, but the JWKS fetch + `kid` selection + cert-cache + claim policy is
   meaningful logic that's cleaner in one Rust function than threaded through
   Sky's `Http.*` + `Jwt` + a hand-rolled cache. Either is defensible; the wrapper
   is chosen for fidelity to the original's "one `verifyToken` call" shape and to
   keep the no-panic JWKS-cache logic in audited Rust. **Fallback B (documented):**
   if `firebase-auth-shim` proves heavy to build, swap to `Sky.Core.Jwt` RS256 +
   a `Http.get` of the JWKS in `Lib/Auth.sky` (more Sky lines, no extra crate).
3. **Emulator-mode run-verify:** the Firebase Auth emulator issues unsigned/loosely
   signed tokens; production JWKS verification rejects them. So `firebase-auth-shim`
   honours a `FIREBASE_AUTH_EMULATOR_HOST` env: when set, it verifies against the
   emulator's `/securetoken.googleapis.com` JWKS (or, if that path is impractical
   in CI, decodes-without-signature-check and logs a `[AUTH] emulator mode` warn —
   a clearly-gated test-only path, never reachable in production because the env is
   unset there). This keeps the auth path **run-verifiable** end-to-end while
   staying production-safe.

Admin gating (`isAdmin` = `Db.getBool "is_admin"`, `adminEmails` from
`ADMIN_EMAILS`) is pure Sky over the verified user doc — ports unchanged.
`findOrCreateUser`'s merge-upsert relies on Firestore `mergeAll` — covered by the
firestore wrapper's `set_merge` (Decision 6 / Q2.6).

### Decision 4 — view layer, i18n, admin (resolves Q1.2, Q1.3, Q9.x, Q7.x, Q8.x)

**View stack confirmed: `Std.Html` + `Std.Html.Attributes` + `Std.Html.Events` +
`Std.Css` + the `Tailwind`/`Tailwind.Responsive` Sky package — NOT Std.Ui.**

- **`sky-tailwind` is pure Sky, zero-runtime** (verified via its README: "type-safe,
  composable, zero-runtime", "all CSS baked into the binary at compile time"). `tw
  [...]` and helpers (`bgBlue600`, `hover`, `textSm`, …) return `(String, String)`
  class-attribute tuples — no Go-FFI, no kernel. It rides under `--target rust`
  **unchanged**: `[dependencies]` Sky packages resolve via `SkyDeps.installDeps`
  (git clone into `.skydeps/`, backend-agnostic — `Sky.Build.SkyDeps`), and the
  Rust path consumes the cloned `.sky` source exactly like the Go path. So
  `Ui/Layout.sky` (1217 lines) + every `Page/*` view port **verbatim**.
  - *Module-name note:* the package's modules are `SkyTailwind*` but the example
    imports `import Tailwind` / `import Tailwind.Responsive` — that mapping is the
    package's own module aliasing already resolved by `SkyDeps` (Go path uses the
    same import lines today), so it is backend-neutral. No port change.
- **Render parity:** README's Std.Ui parity section establishes that Std.Ui is
  *itself* a Sky ADT serialised by `html.rs::render_html` — i.e. the underlying
  `Std.Html` serializer is the byte-identical path, and Std.Ui only rides on top.
  The primitives `Ui/Layout.sky`/`Page/*` use — `Html.node`/`div`/`span`/`a`/`img`
  /`form`/`input`/`select`/`button`/`text`, `Attr.class`/`href`/`type`/`value`
  /`id`/`name`/`placeholder`/`src`/`alt`, `Events.onClick`/`onInput`/`onSubmit`,
  `Css.*` — all flow through that serializer. **Risk flagged (Q9.1):** a specific
  `Std.Html`/`Std.Css` primitive used by the layout that the Rust serializer
  doesn't yet emit would render wrong (build still green). Mitigation: the
  build-staging step (Decision/Build §) renders `Html.toString (view emptyModel)`
  Go-vs-Rust and byte-diffs the static shell BEFORE wiring data — any gap surfaces
  there, in-boundary to fix in `html.rs`/codegen.
- **Wire events (Q9.3):** `onClick`/`onSubmit`/`onInput`/radio/select decode
  identically (typed `decode_form` peephole on Rust). The auth `__sky_send('Fire
  baseAuth', [token])` custom Msg is supported because the Rust backend reuses the
  Go client JS (which implements `__sky_send(MsgName, [args])`). Verify in web-sweep.
- **`<head>`/`<script>` injection (Q9.4):** the original inlines the global
  `<style>` + Firebase `<script>` via `Ui/Layout.sky` (NOT `Std.Live.Head`). The
  Rust renderer's head/script path matches (same serializer + `__skyReviveScripts`).
  No `Std.Live.Head` involved → no divergence.

**i18n (`Lib/Translation.sky`, 781 lines, EN/中文):** pure `case`-on-string-key,
zero FFI, zero Std.Ui (verified: imports only `Sky.Core.Prelude`). **Ports
byte-for-byte.** Chinese string literals are UTF-8 source literals → emit verbatim
as Rust `&str` (the README "Bytes non-ASCII text" limitation is about the `Bytes`
Latin-1 *encoding* convention, NOT plain `String` literals — confirmed non-issue;
the `String` kernels are byte-identical and `examples/00-standard-libs` is
131/131). `Model.lang` + `SetLang String` Msg never touch FFI.

**Admin (`Page/Admin.sky`, 819 lines):** pure view + Msg dispatch over the
Firestore wrapper; **ports verbatim.** It builds regardless of auth being
real/emulator (it's view code). Reachable in a run-verify by seeding an
`is_admin=true` user in the emulator. Image upload (`UploadImage` /
`UpdateImageData` / `addProductImage`) is a base64 string field written to the
`product_images` collection via the same Firestore wrapper — no Std.Ui file-upload
primitive, no new FFI. Large base64 images need `[live] maxBodyBytes` raised in
`sky.toml` (carry it from any value the original implies; default 5 MiB may be
tight for images — set e.g. `maxBodyBytes = 10485760`). Order-state transitions
(`UpdateOrderState`, `allCartStates`) are pure Firestore writes — verbatim.

---

## Sky-module port map (file-by-file)

Legend: **1:1** verbatim · **rewrite** FFI surface changes · **approx** logic
preserved, mechanism adapted · **stub** build-green placeholder first.

| File | Disposition | Reason / exact divergence |
|---|---|---|
| `src/State.sky` (177) | **1:1** | Pure types/Msg/constants. Only `Prelude`/`Maybe`/`Dict`. Zero FFI. |
| `src/Lib/Translation.sky` (781) | **1:1** | Pure `case`-on-string, EN/中文. Chinese literals emit verbatim as UTF-8 `&str`. |
| `src/Lib/Money.sky` (72) | **1:1** | Pure arithmetic/formatting (confirm no FFI; same as Translation class). |
| `src/Lib/Cart.sky` (523) | **rewrite (import only)** | All I/O goes through `Lib/Db` + `Uuid.newString` → only change is the `Uuid` import (same as Products, see below); the body's `case`-on-`Result` shape is untouched because `Lib/Db` stays sync. `getOrderWithItems` tuple return ports as-is. |
| `src/Lib/Products.sky` (252) | **rewrite (import only)** | Same as Cart: logic 1:1, only `import Github.Com.Google.Uuid as Uuid` → `import Rust.Uuid as Uuid` (or `Sky.Core.Uuid`). Call sites `Uuid.newString ()` unchanged if the wrapper/kernel matches the `() -> Result Error String` shape; else `Sky.Core.Uuid.v4` (bare). |
| `src/Lib/Db.sky` (545) | **rewrite (FFI surface)** | Replace `import Cloud.Google.Com.Go.Firestore`, `import Context`, `import Fmt` with `import Rust.FirestoreShim as Fs`. Collapse the ~15 fine-grained `Firestore.*` calls onto the **coarse** wrapper (Decision 6 / §FFI). `ctx`/`Context.background ()`/`js "nil"` vanish (wrapper owns context). `wrapDbError`'s `String.contains` heuristics stay — wrapper preserves the gRPC error text (Decision 7). `snapshotToDict`/`mapToStringDict`/`anyToString`(`Fmt.sprint`) replaced by the wrapper returning pre-flattened `Dict String String` rows (Decision 5). `intVal`/`boolVal`/`floatVal`/`getField`/`getInt`/`getBool` are **pure Sky — 1:1**. |
| `src/Lib/Stripe.sky` (569) | **rewrite (FFI surface)** | Replace the ~30 fine-grained `Stripe.*`/`Session.*`/`Customer.*` builder calls with **3 coarse** wrapper calls: `stripeCreateCheckout`, `stripeGetOrCreateCustomer`, `stripeVerifySession` (Decision §Stripe). `apiKey == "" → Err invalidInput` early-out preserved. The `PaymentStatus`/`CheckoutInfo` record types + the field extraction logic stay; only the source of the data changes (wrapper JSON → flat `Dict`, then build the record). `deductStock`/`deductItemStock` are pure `Lib/Db` calls → **1:1**. |
| `src/Lib/Auth.sky` (225) | **rewrite (FFI surface)** | Replace `Firebase.*`/`FirebaseAuth.*`/`Option.*`/`Context`/`Fmt` with `import Rust.FirebaseAuthShim as Fb`. `getAuthClient`/`verifyToken` collapse onto a single sync `Fb.verifyIdToken token -> Result Error (Dict String String)` (uid+email+name+claims flattened). `findOrCreateUser` (the merge-upsert + read-back) is pure `Lib/Db` → **1:1**. `js "nil"` vanishes. `adminEmails`/`isAdmin`/`getSessionUser`/`signOut` pure → **1:1**. |
| `src/Lib/OAuth.sky` (90) | **1:1** | `firebaseAuthScript` is a raw `<script>` string + env reads; `handleAuthCallback = Auth.verifyToken`. No Go-FFI in the body (the Go-package comments are just comments). Ports verbatim; the client JS rides the shared Go client. |
| `src/Lib/Notify.sky` (101) | **rewrite (drop dead imports)** | `import Net.Http`, `import Strings`, `import Io` are **DEAD** (`sendEmailNotification` only `println`s "Would send email" + writes a `sent` flag via `Lib/Db`). A dead `[go.dependencies]` import would trigger the E1001 Go-FFI refusal on `--target rust`, so **drop the three Go imports** and the unused `Uuid` Go import → `Sky.Core.Uuid`/`Rust.Uuid`. Body logic 1:1. (Optional fidelity+: wire `Std.Email` under dry-run — but the original is a stub, so dropping is the faithful move.) |
| `src/Main.sky` (1202) | **approx (init only)** | `init req` Dict→`req.cookies` typed read (Decision 2) — the ONLY structural change. `update`/all `handle*`/`refresh*`/`view`/`subscriptions`/`guard`/`routes` port **1:1** (every FFI call stays sync `Result`). `Time.every … Tick` subscriptions work on Rust (Sub driver). |
| `src/Ui/Layout.sky` (1217) | **1:1** | `Std.Html`+`Tailwind` pure Sky. Verbatim. |
| `src/Page/Home.sky` (396) | **1:1** | View + Msg only. |
| `src/Page/Product.sky` (337) | **1:1** | View + Msg only. |
| `src/Page/CartPage.sky` (302) | **1:1** | View + Msg only. |
| `src/Page/Orders.sky` (379) | **1:1** | View + Msg only. |
| `src/Page/AuthPage.sky` (90) | **1:1** | View + Msg only. |
| `src/Page/Admin.sky` (819) | **1:1** | View + Msg only. |
| `src/Page/Static.sky` (123) | **1:1** | View only. |

**Net divergence surface:** `init` (1 line) + the three FFI-surface modules'
import lines and coarse-call substitutions + `Notify` dead-import drop + Uuid
import. 7 of 19 files touched (Db, Stripe, Auth, Notify, Main, Products, Cart);
**12 of 19 ported byte-for-byte.**

---

## Wrapper crates & FFI (resolves Q0.1–0.3, Q2.1, Q2.4–2.11, Q3.x, Q4.x, Q6.x)

### Crate layout & sky.toml referencing (resolves Q0.1, Q0.2, Q2.1, Q3.2, Q13.2)

- `[rust.shims]` **does not exist** and is NOT introduced — the brief is stale on
  that point (README: "There is no `[rust.shims]` section"). Wrapper crates are
  ordinary `["rust.dependencies"]`.
- `RustDepSpec` has only `RustVersion` + `RustGitDep` — **no local-path variant**.
  **Resolution (in-doctrine, zero compiler change): publish each wrapper crate to a
  git repo and reference it via `RustGitDep`.** The FFI inspector already supports
  git crates (`Sky.Build.Rust.Ffi.runRustInspectorGit`, inspector binary flag
  `--git URL [--rev|--branch|--tag]`), slug =
  `slugify(_pkgName)`, artifacts at `.skycache/ffi/rust/<slug>.{kernel.json,skyi,
  _bindings.rs}` (Q3.3). This is buildable **today**.

  ```toml
  ["rust.dependencies"]
  firestore-shim     = { git = "https://github.com/<org>/skyshop-rs-shims", rev = "…" }
  stripe-shim        = { git = "https://github.com/<org>/skyshop-rs-shims", rev = "…" }
  firebase-auth-shim = { git = "https://github.com/<org>/skyshop-rs-shims", rev = "…" }
  ```

- **Recommended in-boundary enhancement (small, optional): add `RustPathDep`** to
  `Sky.Sky.Toml.Rust` (`path = "…"` constructor) + `emitDepLine` (`{ path = "…" }`)
  + a `inspectPathCrate` analog in `Sky.Build.Rust.Ffi` (mirror `runRustInspectorGit`,
  `--manifest-path`). This lets the wrapper crates live **inside**
  `examples/rust/skyshop-rs/` (e.g. `firestore-shim/`, `stripe-shim/`,
  `firebase-auth-shim/` sibling dirs) and be referenced by relative path — far
  better DX for a fork-local example than a separate git repo, and it stays inside
  the modification boundary (`src/Sky/Sky/Toml/Rust.hs` + `src/Sky/Generate/Rust/`
  + `src/Sky/Build/Rust/Ffi.hs` are all in-scope). **This is the only compiler
  change the port should make; it is the minimal one (Q12.5).** Path-dep is the
  primary plan; git-dep is the fallback if path-dep slips.

### Wrapper granularity — COARSE (resolves Q2.9, Q2.10)

`async-stripe`/`firestore` builders are generic + async + lifetime-bound — the
auto-FFI inspector binds only peripheral surface (README: "FFI framework crates …
binds only peripheral surface"). The fine-grained `*ParamsSet*` builder chains are
**not** auto-bindable. So mirror the original's fine surface is impossible →
**collapse to a few coarse, owned-signature functions** that DO auto-FFI cleanly
(plain `fn(primitive/owned) -> Result<owned, String>`). The coarse set maps onto
`Lib/Db.sky`'s 7 exported ops and `Lib/Stripe.sky`'s 3 real operations, keeping
`Page/*` unchanged.

**firestore-shim public surface (sync, worker-thread bridge):**

```rust
pub fn firestore_get(collection: &str, id: &str) -> Result<Option<String>, String>;
//   → Sky: getDoc — Result Error (Maybe <flat-row-JSON or Dict>)
pub fn firestore_query(collection: &str) -> Result<Vec<HashMap<String,String>>, String>;
pub fn firestore_query_where(collection: &str, field: &str, op: &str, value: &str,
                             value_kind: &str) -> Result<Vec<HashMap<String,String>>, String>;
pub fn firestore_query_where_order(collection: &str, field: &str, op: &str, value: &str,
                                   value_kind: &str, order_field: &str, dir: &str)
                                   -> Result<Vec<HashMap<String,String>>, String>;
pub fn firestore_set_merge(collection: &str, id: &str, fields_json: &str) -> Result<(), String>;
pub fn firestore_delete(collection: &str, id: &str) -> Result<(), String>;
```

- **`Vec<HashMap<String,String>>` → Sky `List (Dict String String)`** must be a
  supported FFI return coercion (Q3.4). If the coercion table does NOT cover nested
  `HashMap` element returns, that is a small in-boundary codegen add
  (`src/Sky/Build/Rust/Ffi.hs` coercion) — flagged in the risk register; the
  fallback is the wrapper returns a JSON `String` and `Lib/Db` decodes it (but see
  the JSON-pipeline wall below — so prefer the flat-Dict coercion).
- **Flat-`Dict` return avoids the JSON-pipeline decoder wall (Q2.5, Q13.3).** The
  wrapper flattens every Firestore field to `String` (int `5`→`"5"`, bool→`"true"`/
  `"false"` to match `Db.getBool`'s `val == "1" || "true"` and `Db.getInt`'s parse
  — Q4.4), injects `"id"` = doc ref id (Q4.5), and returns `HashMap<String,String>`
  — so **no `Sky.Core.Json.Decode.Pipeline` is used anywhere** (the README/CLAUDE
  `Box<dyn FnOnce>` pipeline wall is dodged entirely). This is the same shape
  `snapshotToDict` produced in the original, so `Db.getField`/`getInt`/`getBool`
  parse identically.
- **Heterogeneous query values (Q4.3):** the app uses `published == True` (Bool)
  and `order_id == "x"` (String). The coarse signature takes `value: &str` +
  `value_kind: &str` ("bool"/"string"/"int") so the wrapper builds the correctly
  typed Firestore filter. `Lib/Db.queryWhere` passes the kind based on the literal
  (a tiny adaptation — e.g. `queryWhere "products" "published" "==" "true"` with an
  implicit "bool" kind for known boolean fields). **Fidelity note (Q4.6):** the Go
  original stores everything as Firestore *strings* and then queries `published ==
  True` (Bool) — a latent type mismatch. The port writes typed values (bool/int)
  on `set_merge` so `published == bool true` queries actually match — a **correct**
  divergence from the Go app's latent bug, documented in the risk register
  (faithful-to-intent, not faithful-to-bug; acceptable because run-verify needs the
  query to actually return rows).
- **`set_merge` (Q2.6):** maps to `firestore` 0.49 `db.fluent().update().in_col()
  .document_id().object(&map).execute()` (merge semantics preserve unset fields —
  `findOrCreateUser` relies on this for phone/address). Takes a JSON object string;
  the wrapper deserializes to a `HashMap<String, serde_json::Value>`, infers
  bool/int/string per value, writes typed.
- **Iterators fully materialized (Q2.11):** `firestore_query*` `stream_query()
  .collect().await` into an owned `Vec` inside the bridge — no lazy iterator
  crosses the FFI line. Same for Stripe customer listing.
- **Client cache (Q2.7):** `FirestoreDb` built once lazily in the worker thread,
  cached worker-local (`Option<FirestoreDb>`), no `Box<dyn Any>` global. Reads
  `GOOGLE_CLOUD_PROJECT` (+ ADC/`GOOGLE_APPLICATION_CREDENTIALS` natively;
  `FIRESTORE_EMULATOR_HOST` for emulator). `.env` is loaded by the Sky.Live runtime
  before `init`, so the lazy first-use construction sees the vars (Q11.2).
- **Collections (Q4.1):** `products`, `users`, `orders`/`carts`, `cart_items`/
  `order_items`, `notifications`, `product_images`. The wrapper is **generic** —
  one `HashMap<String,String>` document shape, no per-collection serde structs
  (avoids N structs; the flat-string flattening already handles the `serde_json::
  Value` → string conversion).
- **Query ops (Q4.2):** only `==` is used (grep-confirmed) + `order_by` asc/desc.
  The wrapper supports `==` + order; other operators are out of surface.

**stripe-shim public surface (sync, worker-thread bridge):**

```rust
pub fn stripe_get_or_create_customer(name: &str, email: &str) -> Result<String, String>;
//   → customer id
pub fn stripe_create_checkout(line_items_json: &str, customer_id: &str,
                              success_url: &str, cancel_url: &str) -> Result<String, String>;
//   → JSON {"id":…, "url":…}  → Sky CheckoutInfo
pub fn stripe_verify_session(session_id: &str) -> Result<String, String>;
//   → flat JSON of the 10 PaymentStatus fields
```

- **Client (Q2.8):** `stripe::Client::new(secret)` built once lazily, cached;
  reads `STRIPE_API_KEY`. `apiKey == "" → Err invalidInput` early-out stays in
  `Lib/Stripe` (and the wrapper itself short-circuits `Err("stripe: not
  configured")` when the key is empty so a creds-less boot is panic-safe — Q6.5).
- **Checkout (Q6.1):** `async-stripe` 1.0 `CheckoutSession::create` with
  `CreateCheckoutSession { mode: Payment, success_url, cancel_url, customer,
  line_items: [price_data{product_data{name}, unit_amount, currency}],
  shipping_address_collection, phone_number_collection }`. The wrapper owns the
  builder; Sky passes a JSON `line_items` array built from the cart `Dict` rows
  (title/price/qty/currency) — so `Lib/Stripe.buildLineItem` becomes a small
  Sky function emitting one JSON object per item instead of the Go builder chain.
- **Customer get-or-create (Q6.2):** `Customer::list` filtered by email (materialize
  to `Vec`, take first) else `Customer::create`. Returns the id.
- **Verify (Q6.3):** `CheckoutSession::retrieve(id)`, read `status`,
  `payment_status`, `customer_details`{name,email,phone},
  `collected_information.shipping_details`{name, address line1/line2/city/country/
  postal_code} → flat JSON → Sky builds the `PaymentStatus` record. The
  `status=="complete" && payment_status=="paid"` check stays in Sky.
- **No webhook (Q6.4):** the success flow is return-URL polling
  (`/order/:id/success` → `verifyPayment`); grep confirms no webhook route. The
  port builds **no** webhook endpoint. `STRIPE_WEBHOOK_SECRET` is dropped from
  `.env.example`.
- **Error mapping (Q2.4, Q7-style):** the wrappers preserve the upstream error
  text (gRPC `PermissionDenied`/`NotFound`/`Unavailable`, Stripe API messages) in
  the `Err(String)` so `wrapDbError`'s `String.contains` heuristics still classify
  correctly. Where the Rust crate's error text differs from Go's, the wrapper
  prefixes a stable token (e.g. `"PermissionDenied: …"`) so the heuristics match.

**firebase-auth-shim public surface:** `firebase_verify_id_token(token: &str) ->
Result<String, String>` → flat JSON `{uid, email, name}` (Decision 3).

### Effect classification (resolves Q2.3, Q3.5, Q3.6)

The inspector classifies a wrapper `fn -> Result<T, String>` as **fallible-pure**
(it can't see the internal `block_on`), so the binding is a **synchronous** Sky
`args -> Result Error T`, NOT a `Task`. This is **exactly** what the original
`Lib/Db.sky`/`Lib/Stripe.sky` call sites need (`case Firestore.queryDocuments q ctx
of …` is synchronous `Result` consumption). The wrapper being internally blocking
is invisible and correct. `ctx`/`Context.background ()`/`js "nil"` have no Rust
meaning and vanish (the wrapper owns context internally; the Rust codegen has no
`js` builtin — grep shows `js "nil"` used only twice, both inside replaced FFI
modules). **This reconciliation is the lynchpin of the 1:1 claim.**

### Module naming (resolves Q3.1)

`Sky.Build.Rust.Ffi.rustModuleName` maps a crate to `Rust.<Pascal>` (e.g. `uuid`
→ `Rust.Uuid`). So `firestore-shim` → `import Rust.FirestoreShim as Fs` (confirm
the exact Pascalisation of a hyphenated crate name via the inspector run; likely
`Rust.FirestoreShim`). The ported import lines:

```elm
import Rust.FirestoreShim as Fs        -- in Lib/Db.sky
import Rust.StripeShim as St           -- in Lib/Stripe.sky
import Rust.FirebaseAuthShim as Fb     -- in Lib/Auth.sky
import Rust.Uuid as Uuid               -- in Products/Cart/Notify (or Sky.Core.Uuid)
```

---

## Session store / env / config (resolves Q10.x, Q11.x)

- **`[live] store = "sqlite"` + `storePath` + `static`** all supported on Rust
  (README: memory/sqlite/postgres/redis stores; `27-live-static`/`32-live-sessions`
  prove static + sqlite-session restart-survival). The sqlite session store pulls
  sqlx via the `db` feature (Cargo wiring from `[live] store`) — this is the **only**
  sqlite use (Firestore replaces `Std.Db` for app data), and it enables the `db`/
  sqlx feature correctly on its own. TTL `SKY_LIVE_TTL=86400` honoured (Q10.3).
- **Env (Q11.1):** `System.getenv`/`getenvOr` work on Rust (MEMORY: the bare-String
  return bug is fixed; `usesTaskParallel` entry invariant). The app reads
  `GOOGLE_CLOUD_PROJECT`, `GOOGLE_APPLICATION_CREDENTIALS`, `STRIPE_API_KEY`,
  `DOMAIN`, `SKY_LIVE_PORT`, `ADMIN_EMAILS`, `ENV`, `FIREBASE_API_KEY`,
  `AUTH_DOMAIN`. The wrappers read GCP/Stripe creds from the **same** env vars
  (firestore crate reads ADC/`GOOGLE_APPLICATION_CREDENTIALS` natively;
  `FIRESTORE_EMULATOR_HOST`/`FIREBASE_AUTH_EMULATOR_HOST` for emulator runs).
- **`.env.example` (Q11.3):** ship a port-local one — drop `STRIPE_WEBHOOK_SECRET`
  + `SMTP_*`/`NOTIFY_TO` (Notify is a stub), add `FIRESTORE_EMULATOR_HOST` /
  `FIREBASE_AUTH_EMULATOR_HOST` comments for the run-verify path.
- **`e2e.json`/static (Q1.7):** carry an analogous `e2e.json` (`GET /` → 200, no
  `panic:`) + the `static/` favicon set; `[live] static` works on Rust.

---

## Build & run-verify strategy (resolves Q12.x)

**Disk/build hygiene (Q12.4, CLAUDE.md):** export the shared
`CARGO_TARGET_DIR=$HOME/.cache/sky-rust-target` + `RUSTC_WRAPPER=sccache` +
self-contained PATH every shell; symlink `sky-out/sky` to the dist-newstyle binary
(never `cabal install --copy`). The firestore(tonic/gRPC/prost/TLS) +
async-stripe(reqwest) + tokio tree is **heavy** — but it shares the target with the
sweep's `sky-app` package; first build is slow, sccache amortizes. If it poisons
the leaf-sweep cache, give skyshop-rs its **own** target dir for its sweep runs
(documented escape hatch). Generated `[profile.dev]` already drops debuginfo.

**Staging order (Q12.1, Q12.2 — stub-first, green at each step):**

1. **Pure skeleton, stubbed FFI.** Port `State`, `Translation`, `Money`,
   `Ui/Layout`, all `Page/*`, `Cart`, `Products`, `Notify` (dead imports dropped),
   `Main` (with the `init req.cookies` rewrite). Provide **stub** `firestore-shim`/
   `stripe-shim`/`firebase-auth-shim` crates: real signatures, bodies return
   `Err("not configured")` / `Ok(None)` / empty `Vec`. **Goal: the full ~9.6k-line
   app `sky build --target rust` + `cargo build` green with NO live deps.** This
   de-risks the entire Sky-compile surface (typed-record codegen, Tailwind render,
   `init` rewrite, coarse-FFI coercion) from the async crate-integration surface.
   - Static-shell byte-diff gate: render `Html.toString (view emptyModel)` Go-vs-
     Rust; any `Std.Html`/`Tailwind` render gap surfaces here (in-boundary fix in
     `html.rs`/codegen).
2. **Wire firestore-shim** (worker-thread bridge + `firestore` 0.49). Run-verify
   against the Firestore emulator: seed products, browse, cart.
3. **Wire stripe-shim** (`async-stripe` 1.0). Run-verify checkout + return-URL
   verify against Stripe test mode (test card `4242…`).
4. **Wire firebase-auth-shim** (JWKS RS256 + emulator mode). Run-verify sign-in.

**Acceptance (Q12.3, Q1.6):** `sky build … --target rust` exit 0 + `cargo build`
exit 0 (hard gate) + creds-less boot `curl / → 200` no-panic + emulator/test-mode
happy-path run-verify per stage. The creds-less boot is reachable because the
wrappers are lazy (no client constructed until first query; the home page's query
returns `Err`→`[]` cleanly).

**Inspector prerequisites (Q12.6):** the inspector needs `cargo +nightly rustdoc`
and must inspect each **wrapper** crate (whose public API is the ~10 coarse `fn`s).
rustdoc-JSON runs on the wrapper's own surface; it does NOT need to document the
heavy transitive deps (firestore/async-stripe) — only build them. The wrapper's
**coarse owned signatures** are precisely what auto-FFIs clean, sidestepping the
framework-crate non-bindability. Building the wrapper's deps once is the cost;
sccache amortizes.

**Equiv-sweep classification (Q0.4):** skyshop-rs has no Go counterpart to diff
(the Go `13-skyshop` is `out` / Go-FFI). Classify skyshop-rs as **`out`** in
`equiv-classification.tsv` (no Go≡Rust stdout diff) — its verification is the
build + emulator run-verify, not stdout-parity. Confirm the classification-coverage
gate in `equiv-sweep.sh` accepts an `out` entry. Nothing re-introduces a
`[go.dependencies]` table (Q0.4) — the port has none.

---

## Risk register

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| R1 | `block_on`-in-async panic | **Critical** | Worker-thread + own current-thread runtime + std mpsc (Decision 1). Caller never `block_on`s; worker thread has no ambient runtime. Panic structurally impossible. Hold wrapper to no-`unwrap`/`expect`/`panic`. |
| R2 | `Vec<HashMap<String,String>>` return coercion unsupported | High | If the FFI coercion table doesn't cover nested-HashMap returns → small in-boundary add to `src/Sky/Build/Rust/Ffi.hs`. Fallback: wrapper returns JSON `String`, `Lib/Db` decodes — but that risks the pipeline wall, so prefer the coercion add. |
| R3 | JSON-pipeline decoder `Box<dyn FnOnce>` wall | Med | **Dodged by design:** wrapper returns pre-flattened `Dict String String`, never JSON-pipeline-decoded. No `Decode.Pipeline` anywhere. |
| R4 | `async-stripe` 1.0.0-rc.6 API churn / builder gaps (shipping_address_collection, collected_information) | Med | RC; pin exact rev. Wrapper isolates the churn (3 coarse fns). If a field is missing in rc.6, surface it as empty in the flat JSON (graceful) and document. |
| R5 | firestore 0.49 (tonic/prost/TLS) version conflict with axum/sqlx rustls in the `sky-app` graph | Med | Wrapper is a separate crate (own Cargo.toml) → its deps don't directly unify with `sky-app`'s unless co-compiled. If duplicate-version errors appear, align rustls/tokio versions via the wrapper's Cargo + `[rust] sqlx_tls = "rustls"`. |
| R6 | No turnkey Rust Firebase Admin SDK | Med | Hand-rolled JWKS RS256 (`firebase-auth-shim`) + emulator mode (Decision 3). Fallback B: `Sky.Core.Jwt` RS256 + `Http.get` JWKS in Sky. |
| R7 | Tailwind package portability under `--target rust` | Low | **Resolved:** pure Sky, zero-runtime, `(String,String)` tuples; `[dependencies]` resolves via `SkyDeps` (backend-agnostic). Verify by a build, not by trust. |
| R8 | `init req` typed-LiveReq compile mismatch | Low | **Resolved:** `req.cookies` typed-field rewrite (Decision 2), proven by `31-live-req`. One line. |
| R9 | Std.Html/Tailwind render parity (unrendered primitive → visually broken, build green) | Med | Static-shell `Html.toString` Go-vs-Rust byte-diff gate in build-stage 1, BEFORE data wiring. Any gap is in-boundary (`html.rs`/codegen). Web-sweep in-scope for "done". |
| R10 | Effect/Task vs bare-Result mismatch forcing a structural rewrite | **Resolved** | The wrapper binds **fallible-pure sync** `Result`, NOT `Task` — call sites unchanged. The whole 1:1 claim rests on this (Q2.3/Q3.5 reconciliation). |
| R11 | Path-dep (`RustPathDep`) compiler add slips | Low | Fallback: publish wrappers to a git repo, reference via `RustGitDep` (works today, zero compiler change). |
| R12 | Firestore typed-write divergence from Go's all-string-store latent bug | Low | Documented: port writes typed bool/int so `published == True` queries match (faithful-to-intent). Acceptable + necessary for run-verify. |
| R13 | maxBodyBytes too small for base64 image upload | Low | Set `[live] maxBodyBytes = 10485760` in port `sky.toml`. |

---

## Summary

- **The port is near-verbatim, not a rewrite.** 12/19 `.sky` files port
  byte-for-byte; only `Lib/Db`, `Lib/Stripe`, `Lib/Auth` (FFI surface), `Lib/Notify`
  (drop 3 dead Go imports), `Main.init` (1-line Dict→`req.cookies`), and
  `Lib/Products` + `Lib/Cart` (Uuid import only) change.
- **Lynchpin:** the wrapper crates expose **synchronous, fallible-pure**
  `fn -> Result<T,String>` (the inspector binds them as Sky `Result`, NOT `Task`),
  so every `case`-on-`Result` call site across `update`/`init`/`Page/*` is
  UNCHANGED — no `Task`/`Cmd.perform` re-threading.
- **The block_on-in-async panic** (the one critical risk) is solved by a
  worker-thread owning its own current-thread tokio runtime + std mpsc bridge;
  the caller only does a blocking channel `recv()`, so no runtime nests — panic-free
  under Sky.Live AND Sky.Cli.
- **`init req`** rewrites to read the typed `LiveReq.cookies` field (the only
  structural divergence); proven by `31-live-req`.
- **Auth** = a third hand-rolled `firebase-auth-shim` (JWKS RS256 + emulator mode);
  client-side Firebase JS + `__sky_send('FirebaseAuth',[token])` rides the shared
  Go client JS unchanged.
- **View + i18n + admin** port verbatim: `Std.Html`+`Tailwind` is pure zero-runtime
  Sky resolved by `SkyDeps`; `Translation.sky` (EN/中文) emits Chinese literals
  fine; `Admin.sky` is pure view.
- **FFI surface is COARSE** (~6 firestore + 3 stripe + 1 auth fns) returning flat
  `Dict String String`/owned JSON — auto-FFI-clean, dodges the JSON-pipeline wall,
  iterators fully materialized.
- **Wrapper referencing:** primary = add a small in-boundary `RustPathDep`
  (`path=`) so wrappers live inside `examples/rust/skyshop-rs/`; fallback = git-dep
  (works today, zero compiler change). The ONLY compiler change the port needs.
- **Build staging:** stub-FFI-first → full app green with no live deps → wire
  firestore → stripe → auth, run-verifying each stage on the emulators.

Plan written to:
`runtime-rust/docs/superpowers/specs/2026-06-15-skyshop-rs-port-plan-B.md`
