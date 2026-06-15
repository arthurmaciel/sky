# skyshop-rs

A Rust-FFI port of `examples/13-skyshop` (the Stripe-SDK-scale benchmark) onto
`sky build --target rust`. Same Sky.Live storefront — product catalogue,
cart, Stripe checkout, Firebase sign-in, admin CRUD — but every backend call
goes through a **real Rust crate** instead of Go FFI:

| Concern | 13-skyshop (Go) | skyshop-rs (Rust) |
|---|---|---|
| Document store | Firestore via Go SDK | `firestore` 0.49 |
| Payments | Stripe via Go SDK | `async-stripe` 1.0.0-rc.6 |
| Auth verification | Firebase Admin via Go SDK | `rs-firebase-admin-sdk` 4.3 |

## What it proves

`--target rust` can consume **three independent, real-world async Rust crates
at once** through the automatic FFI, with no user-written `unsafe`, no
hand-written bindings, and no `Task`-vs-`Result` mismatch — and the resulting
single binary boots clean against all three live test backends.

## Architecture

```
Sky source  ──FFI──▶  3 fork-local wrapper crates  ──▶  firestore / async-stripe / rs-firebase-admin-sdk
   │                  (sync Result surface)              (async, tokio)
   │                          ▲
   └── Std.Ui view            └── dedicated-thread async→sync bridge
```

### The three wrapper crates

Source: `wrappers/` in this example; consumed from a local `file://` git repo at
`~/.cache/sky/skyshop-rs-wrappers` (see *Local git-dep mechanism* below).

| Crate | Sky module | Wraps | Surface |
|---|---|---|---|
| `sky-firestore-shim` | `Rust.Sky_firestore_shim` | `firestore` 0.49 (+ `gcloud-sdk`) | `fs_get_doc` / `fs_set_doc` / `fs_delete_doc` / `fs_query` / `fs_query_where` / `fs_query_where_order` |
| `sky-stripe-shim` | `Rust.Sky_stripe_shim` | `async-stripe` 1.0.0-rc.6 (checkout + core) | `stripe_create_checkout_session` / `stripe_create_customer` / `stripe_retrieve_session` |
| `sky-firebase-auth-shim` | `Rust.Sky_firebase_auth_shim` | `rs-firebase-admin-sdk` 4.3 | `fb_verify_id_token` |

### FFI conventions (shared by all three)

- **Coarse `Dict String String` surface (D3).** Every fn is a TOTAL
  `fn(&str, …) -> Result<_, String>`. A single document maps to a flat
  `HashMap<String,String>` (Sky `Dict String String`); a query maps to
  `Vec<HashMap<String,String>>` (Sky `List (Dict String String)`). Numbers and
  bools are stringified at the boundary; the Sky side wraps/unwraps via
  `Lib.Db.intVal` / `getInt` / `boolVal` / `getBool`. This keeps the auto-FFI
  classification trivial (no generic/`any`-typed slots) at the cost of fidelity.
- **Total `Result` → sync Sky `Result` (D1).** Because every fn returns
  `Result<_, String>`, the auto-FFI classifies it `fallible` and binds it as a
  **synchronous** Sky `Result`, not a `Task`. The async runtime lives entirely
  inside each wrapper.
- **Status rides in the `Ok` payload, not the error.** The Sky FFI `Err`
  payload is opaque, so the app reads `Err _ ->` and discards it. Any status the
  app needs (`not_found` vs `ok`) is encoded under a `"_status"` key in the `Ok`
  map. Genuine backend failures still return `Err(String)` with the backend's
  `Display` embedded verbatim.

### Dedicated-thread async→sync bridge

The crates are async (tokio); the FFI surface is sync. Each public fn wraps its
future in a `block_on` helper that **spawns a fresh OS thread, builds a
`current_thread` tokio runtime on it, blocks the future, and `.join()`s** — the
same pattern as `runtime-rust/src/sky_runtime/task.rs::block_on`. A panic inside
the future surfaces as `Err(String)` (`.join()` error → string), never an abort
— honouring the Rust backend's no-runtime-panic invariant.

### Std.Ui view

The entire storefront renders through `Std.Ui` (typed no-CSS layout DSL) →
`Live.app`. No raw HTML, no CSS, no client-side JS authored in the view.

### Local `file://` git-dep mechanism

`sky.toml` declares the three crates under `["rust.dependencies"]` as
`{ git = "file:///home/arthur/.cache/sky/skyshop-rs-wrappers", branch = "master" }`.
`sky build --target rust` resolves them via Cargo's git checkout, runs the FFI
inspector against each, and emits the bindings. The path is a literal absolute
`file://` URL (no env expansion). The `wrappers/` directory in this example is
the source of truth; the cache repo is its committed mirror.

## Build & run

> Like the original (which needs real Firebase + Stripe credentials), skyshop-rs
> talks to a Firestore database and the Stripe API. Locally you point it at the
> **Firestore emulator** + **stripe-mock**. Skipping this is the cause of
> `[DB ERROR] Products.listProducts: ... fs_query_where products` — with no
> emulator running the firestore shim falls back to real GCP, finds no
> credentials, and errors.

### Prerequisites & references — install and use the test backends

| Backend | Install | Use · docs |
|---|---|---|
| **Firestore emulator** | Google Cloud SDK — <https://cloud.google.com/sdk/docs/install> — then `gcloud components install cloud-firestore-emulator` (needs a JRE) | `gcloud emulators firestore start` · emulator guide: <https://firebase.google.com/docs/firestore/security/test-rules-emulator> |
| **Stripe (mock)** | `go install github.com/stripe/stripe-mock@latest` · <https://github.com/stripe/stripe-mock> | point the shim at it with `STRIPE_API_BASE` · test cards & test-mode reference: <https://docs.stripe.com/terminal/references/testing> |
| **Firebase Auth emulator** *(optional — sign-in only)* | `firebase-tools` (npm) — **needs Node 18+** — <https://firebase.google.com/docs/emulator-suite> | `firebase emulators:start --only auth` — browsing + checkout work without it |

- `sky` built with the Rust backend (`feat/runtime-rust`); the wrapper git repo present at `~/.cache/sky/skyshop-rs-wrappers`.
- **Leave `ENV` / `SKY_ENV` unset** (or `dev` / `development` / `local`). The shims **refuse** the verification-skipping emulator paths in production (a deliberate security gate) — set `ENV=production` and you get the same `[DB ERROR]`.

### 1. Build

```bash
export PATH="$HOME/.cargo/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.ghcup/bin"
export CARGO_TARGET_DIR="$HOME/.cache/sky-rust-target" RUSTC_WRAPPER=sccache
cd examples/rust/skyshop-rs
sky build src/Main.sky --target rust
# → sky-out/Rust/target/debug/sky-app
```

### 2. Start the Firestore emulator and SEED the catalogue (required)

The catalogue is read from the `products` collection where `published == "true"`.
A committed seeder writes 5 sample products through the same `fs_set_doc` entry
the app uses (idempotent — safe to re-run):

```bash
gcloud emulators firestore start --host-port=127.0.0.1:8412 &   # wait for "Dev App Server is now running."
export FIRESTORE_EMULATOR_HOST=127.0.0.1:8412 FIRESTORE_PROJECT_ID=sky-skyshop-dev

( cd examples/rust/skyshop-rs/wrappers/sky-firestore-shim
  env -u ENV -u SKY_ENV cargo run --bin seed )                  # → [SEED] done: 5/5 products written
```

### 3. Start stripe-mock and run the app

```bash
~/go/bin/stripe-mock -http-port 12111 &                          # ~1s to start listening
export STRIPE_API_BASE=http://127.0.0.1:12111 STRIPE_API_KEY=sk_test_123

# (optional) sign-in support — needs Node 18+:
# firebase emulators:start --only auth --project sky-skyshop-dev &
# export FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099

pkill -9 -f sky-out/Rust/target/debug/sky-app 2>/dev/null        # kill any stale instance on :8000
env -u ENV -u SKY_ENV \
  FIRESTORE_EMULATOR_HOST=127.0.0.1:8412 FIRESTORE_PROJECT_ID=sky-skyshop-dev \
  STRIPE_API_BASE=http://127.0.0.1:12111 STRIPE_API_KEY=sk_test_123 \
  SKY_LIVE_PORT=8000 SKY_CONSOLE_EMBED=off \
  ./sky-out/Rust/target/debug/sky-app &

curl -s http://127.0.0.1:8000/ | grep -F "Aurora Desk Lamp"      # → the seeded catalogue
```

**Success signal:** the 5 products render and the app log shows **no `[DB ERROR]`**.
(The public catalogue path is silent on success by design; `[PRODUCTS] loaded N`
is the admin-only `Db.queryDocs` path.)

### One-command check

`./verify.sh` runs the whole flow above — preflight → emulator → seed →
stripe-mock → build → run → `GET /` → assert all 5 products render with zero
`[DB ERROR]` → tear everything down. Exits **0 on PASS**, **1 on FAIL**, **2 on
a missing prerequisite**:

```bash
cd examples/rust/skyshop-rs && ./verify.sh
# → RESULT: PASS — 5/5 products via the firestore emulator, 0 DB errors
```

### Troubleshooting

| Symptom | Cause → fix |
|---|---|
| `[DB ERROR] ... fs_query_where products` | emulator not running / `FIRESTORE_EMULATOR_HOST` unset → start the emulator + export the var (step 2). Or `ENV`/`SKY_ENV=production` → unset it (the dev-gate refuses the emulator path). |
| Blank catalogue, **no** `[DB ERROR]` | emulator up but not seeded → run the seeder (step 2). |
| `Address already in use` / stale catalogue served | a previous `sky-app` still holds `:8000` → `pkill -9 -f sky-out/Rust/target/debug/sky-app` (or a fresh `SKY_LIVE_PORT`). |
| Sign-in does nothing | the Firebase Auth emulator isn't running (needs Node 18+) — optional; browsing + checkout don't need it. |

### Backend env vars

| Var | Selects | Used by |
|---|---|---|
| `ENV` / `SKY_ENV` | unset / `dev` / `development` / `local` ⇒ emulator paths allowed; anything else ⇒ refused | all three shims (security gate) |
| `FIRESTORE_EMULATOR_HOST` | firestore emulator endpoint | `sky-firestore-shim` |
| `FIRESTORE_PROJECT_ID` / `GOOGLE_CLOUD_PROJECT` | firestore project | `sky-firestore-shim` |
| `STRIPE_API_BASE` | overrides the Stripe base URL (point at stripe-mock) | `sky-stripe-shim` |
| `STRIPE_API_KEY` | Stripe secret key | `sky-stripe-shim` |
| `FIREBASE_AUTH_EMULATOR_HOST` | selects emulator mode (alg=none token decode, no JWKS) | `sky-firebase-auth-shim` |

When `FIREBASE_AUTH_EMULATOR_HOST` is unset the auth shim runs in **live** mode:
ADC-backed `App::live()` + full RS256 + `aud`/`iss`/`exp` verification against
Google's certs.

## Divergences from 13-skyshop

The port stays behaviourally faithful where it can; the differences are forced
by the Rust-backend Std.Ui surface and the coarse FFI shape, not by choice.

| Area | 13-skyshop | skyshop-rs | Why |
|---|---|---|---|
| View / styling | `Std.Html` + `sky-tailwind` | `Std.Ui` (typed no-CSS DSL) | Rust backend's proven UI surface is Std.Ui; no raw-HTML class strings |
| Auth UI | Firebase client SDK injected as a `<script>`; OAuth buttons call `skySignIn('google')` in raw JS | provider buttons drive a `FirebaseAuth <devToken>` Msg; server verifies via the auth shim | Std.Ui has no script-injection primitive, so the OAuth client SDK can't be injected from the view |
| File / image upload | raw `<input type="file">` + `onImage` / `fileMaxWidth` | "Upload Image" button driving the existing `UploadImage` Msg (reads `model.editImageData`) | Std.Ui has no file-picker primitive in the proven set |
| Raw `<img>` / `<select>` | direct HTML primitives | placeholder elements / chips | no raw img/select primitives in the proven Std.Ui set |
| `init` request access | `Dict.get "cookies" req` | typed `req.cookies` (`Dict.get "sky_user" req.cookies`) | Rust runtime's typed `LiveReq` init shape |
| Toast notifications | `Notify` Msg + toast surface | dropped (model still carries `notification` fields) | trimmed from the ported Msg set |
| Product sort | `List.sortBy` | pure-Sky stable insertion sort keyed by effective price | `List.sortBy` not in the Rust-backend `Sky.Core.List` kernel surface |
| UUID source | `github.com/google/uuid` | `Sky.Core.Uuid` (`Uuid.v4 : String`, bare) | stdlib UUID, no Go dep |

## Verification

Each wrapper crate ships its own integration test against its real backend
(firestore emulator roundtrip; `stripe-mock` checkout/customer/session; firebase
auth emulator-token decode) — run per-crate with the matching emulator/mock up.
The combined binary boots clean with all three crates linked simultaneously and
serves the live firestore catalogue over `GET /`.
