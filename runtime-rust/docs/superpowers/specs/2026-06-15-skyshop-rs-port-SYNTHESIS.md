# skyshop-rs — synthesis spec + execution plan (authoritative)

Supersedes the two reasoner plans (`-plan-A.md`, `-plan-B.md`) where they conflict.
Built from their **converged** decisions + the user's 3 binding overrides.

## Goal
`examples/rust/skyshop-rs/` — a faithful 1:1 port of `examples/13-skyshop`
(Sky.Live e-commerce app) to the **Sky→Rust backend** (`sky build --target rust`),
using **Rust crates** in place of the Go-FFI packages the original uses.

## Locked decisions

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | **Near-verbatim Sky port, no `Task` re-threading.** Original consumes FFI as bare sync `Result Error a`; a wrapper `fn(..) -> Result<String,String>` is classified `fallible` → binds as a **sync Sky `Result`**, not `Task`. So `Lib/*` + `Page/*` call sites are unchanged. | Both reasoners converged. Kills the biggest structural risk. |
| D2 | **Async→sync bridge = dedicated-thread tokio runtime** inside each wrapper fn (`std::thread::spawn(move ‖ rt.block_on(fut)).join()`), mirroring `sky_runtime/task.rs::block_on`. NEVER `block_on` on the ambient axum runtime. `.join()` maps an internal panic → `Err`. | No-panic existential rule; works under Sky.Live + Sky.Cli. |
| D3 | **Coarse FFI surface returning flat `Dict String String`** (Rust `HashMap<String,String>`) / `Vec<HashMap<..>>`, not nested JSON. | Dodges the broken JSON-pipeline `Box<dyn FnOnce>` decoder; keeps `Db.getField/getInt/getBool` + `wrapDbError` string-matching working unchanged; auto-FFI-bindable. |
| D4 | **Wrapper delivery = `RustGitDep` with a local `file://` URL** (user override of the reasoners' `RustPathDep` compiler edit). Confirmed: `emitDepLine` renders `git=`, FFI inspector supports `--git`. **No compiler change.** | User directive. Stays fully in `examples/rust/` boundary. |
| D5 | **View layer = Std.Ui** (user override — NOT Std.Html + sky-tailwind). Re-implement skyshop's layout/design with the typed Std.Ui DSL. | User directive ("better to use Std.Ui"). Drops the sky-tailwind portability risk; Std.Ui is first-class on the Rust backend (shared `Element`). |
| D6 | **Auth = `rs-firebase-admin-sdk` crate** (user override of hand-rolled JWKS) via a `firebase-auth-shim` wrapper. | User directive. A real Rust Firebase Admin SDK exists. |
| D7 | **`init req` → typed `LiveReq`**: `Dict.get "cookies" req` → `req.cookies`. One-line divergence in `Main.sky`/`State.sky`. | Rust backend gives a typed `LiveReq`; only structural divergence. |
| D8 | **Drop dead Go-FFI imports.** `Lib/Cart.sky`+`Lib/Notify.sky` import `Github.Com.Google.Uuid` → swap to `Sky.Core.Uuid`. `Lib/Notify`'s `Net.Http`/`Strings`/`Io` are dead (sender only `println`s) → drop to avoid the Go-FFI E1001 refusal. | `--target rust` ignores `[go.dependencies]` but Go-FFI *imports* still refuse. |

## Wrapper crates (3) — local git repo `$WRAPREPO`

Live as a standalone git repo (cargo `file://` git source needs a real repo).
`$WRAPREPO = $HOME/.cache/sky/skyshop-rs-wrappers` (git-inited; one workspace,
three member crates). Sources ALSO committed under
`examples/rust/skyshop-rs/wrappers/` (tracked, self-contained); the shipped
example materialises `$WRAPREPO` via `verify.sh` (the planned standalone
`prepare-wrappers.sh` was not added). `sky.toml`
`["rust.dependencies"]` references each via `{ git = "file://$WRAPREPO", branch = "master" }`
(the shipped branch is `master`, not `main`).

| Crate | Over | Sky-needed ops (from `Lib/Db.sky`,`Lib/Stripe.sky`,`Lib/Auth.sky`) |
|-------|------|--------------------------------------------------------------------|
| `sky-firestore-shim` | `firestore` 0.49 | `fs_get_doc(coll,id)`, `fs_set_doc(coll,id,fields)`, `fs_delete_doc(coll,id)`, `fs_query(coll)`, `fs_query_where(coll,field,op,value)`, `fs_query_where_order(coll,field,op,value,orderField,dir)` — all `-> Result<…, String>`, rows as `HashMap<String,String>` / `Vec<HashMap<..>>` |
| `sky-stripe-shim` | `async-stripe` 1.0-rc.6 | `stripe_create_checkout_session(…) -> Result<String,String>` (returns URL/id), `stripe_create_customer(email, name) -> Result<String,String>`, `stripe_retrieve_session(id) -> Result<HashMap<String,String>,String>` |
| `sky-firebase-auth-shim` | `rs-firebase-admin-sdk` | `fb_verify_id_token(token) -> Result<HashMap<String,String>,String>` (uid/email/claims), emulator-aware (`FIREBASE_AUTH_EMULATOR_HOST`) |

Each wrapper: every public fn is the D2 bridge + D3 flat shape + total error mapping
(`Result<_, String>`, the firestore/stripe error `Display` embedded verbatim so
`wrapDbError`'s `contains "PermissionDenied"` etc. still works).

## Execution stages (each ends GREEN: `sky build --target rust && cargo build`)

- **Stage 0 — spine proof (de-risk).** Minimal `sky-firestore-shim` (1–2 fns that
  compile against `firestore` 0.49 via the D2 bridge) as `$WRAPREPO` git repo +
  a 5-line `examples/rust/skyshop-rs/src/Main.sky` that imports the wrapper module
  and calls it. Prove: `file://` git dep → emitted Cargo.toml → FFI inspector binds
  the fn as a sync Sky `Result` → `cargo build` green. **Report the exact working
  recipe** (import module name, sky.toml shape, inspector invocation).
- **Stage 1 — full Sky port on STUB wrappers (parallelizable).** Port every `.sky`
  module (State, Lib/{Money,Products,Cart,Db,Stripe,Auth,OAuth,Translation}, Main)
  + the **Std.Ui** view rewrite (Layout + all Pages). Wrappers are STUBS returning
  canned `Ok`/`Dict`. Goal: whole app builds + boots on `--target rust` with zero
  live deps. (Drop dead Notify per D8.)
- **Stage 2 — real `sky-firestore-shim`** (swap stub → real; run-verify on
  `gcloud emulators firestore start` / `FIRESTORE_EMULATOR_HOST`).
- **Stage 3 — real `sky-stripe-shim`** (Stripe test mode; test cards
  https://docs.stripe.com/terminal/references/testing).
- **Stage 4 — real `sky-firebase-auth-shim`** (`rs-firebase-admin-sdk`; Auth
  emulator).
- **Stage 5 — run-verify** the full flow (browse → cart → checkout(test) →
  order persisted in emulator) + README + a fork-local status row.

## Verification bar
Build-green every stage (mandatory) + run-verify Stages 2–5 against the Firestore
emulator and Stripe test mode (user-provided means). `examples/rust/skyshop-rs`
classifies `out` for equiv-sweep (no Go counterpart to diff).

## Boundary
Only edit `runtime-rust/`, `src/Sky/Generate/Rust/`, `src/Sky/Build/Rust/`,
`tools/sky-ffi-inspect-rs/`, `examples/rust/`. Never `examples/13-skyshop`,
`sky-stdlib/`, or the Go backend.
