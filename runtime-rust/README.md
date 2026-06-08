# Sky Rust Runtime

The `sky_runtime` crate is the **single source of truth** for all Rust code
emitted by the Sky compiler's `--target rust` path. Every generated project
copies this crate's modules into `sky-out/Rust/src/sky_runtime/` at build time.

---

## Architecture

```
Sky Source → Haskell Parser → Type-Check → Canonical AST → Rust Codegen (Builder.hs)
                                                                    ↓
                                            sky_runtime/ modules (this directory)
                                                                    ↓
                                          sky-out/Rust/src/main.rs + sky_runtime/
                                                                    ↓
                                                       cargo build → binary
```

All runtime logic lives in `sky_runtime/`; `Builder.hs` emits only thin wrappers
that instantiate `E = SkyError` for the generated project. No inline Rust
implementation strings in the Haskell codegen.

---

## Safety audit — zero `Any`, zero `unsafe` (maintained invariant)

The Rust backend uses Rust's static type system end-to-end. As of the v0.16.1
sync, an audit across the whole backend (5.4k lines of `sky_runtime/`, the
codegen in `src/Sky/Generate/Rust/*`, the Rust FFI generator in
`src/Sky/Build/Rust/*`, AND the generated output — `main.rs` + `*_bindings.rs` +
the copied runtime) found:

- **No `Any`-type erasure.** Zero `dyn Any` / `Box<dyn Any>` / `Arc<dyn Any>` /
  `downcast` / `type_id` / `std::any::*`. Sky's `any` is NEVER lowered to
  `Box<dyn Any>` (that would re-implement Go's `interface{}` and is the bug
  class this backend exists to avoid). The codegen emits none of these either.
- **No `unsafe`.** Zero `unsafe` blocks/fns, `transmute`, raw pointers
  (`*const`/`*mut`), `from_raw`/`into_raw`, or `static mut`. 100% safe Rust,
  including the FFI path (Sky→Rust FFI calls are safe Rust-crate calls, not
  `extern "C"`, so no `unsafe` is needed). The single textual `unsafe` match is
  the word inside a test's error string for the `unsafeFindWhere` stdlib fn —
  not a Rust `unsafe`.

How heterogeneity is handled WITHOUT `Any` (so future work preserves this):

| Need | Technique (not `Any`) |
|---|---|
| HTTP/WS handlers of project-defined error `E` | erase E into a non-generic route by awaiting the task + mapping `Err -> 500/marker` (`server_get<E,H>`), handlers stay `Send + Sync + 'static` closures |
| `Cmd msg` / `Sub msg` carrying varied payloads | generic over the concrete `M`; the intermediate `a` in `Cmd.perform` is erased *inside* a boxed `Future<Output = M>` — `M` stays concrete |
| Custom event sources (WS `onMessage`) | `SkySub::Source(Box<dyn FnOnce(emit) -> JoinHandle>)` — a boxed closure over a concrete `M`, not `dyn Any` |
| Records the runtime must name (Request/Response/Csv/HttpResponse/WebSocketMessage/CloseCode/…) | `runtimeOpaqueTypes` bridge to concrete runtime structs/enums (`pub use … as …`), not erased values |
| Polymorphic value storage (e.g. `Std.Cache k v`) | refused — would need `Box<dyn Any>`; flagged as blocked rather than erased (see Known limitations) |

**Audit method (repeatable):**
```bash
grep -rEn "dyn Any|std::any|downcast|type_id" runtime-rust/src/ src/Sky/Generate/Rust/ src/Sky/Build/Rust/
grep -rEn "\bunsafe\b|transmute|from_raw|into_raw|static mut|\*const |\*mut " runtime-rust/src/
```
Both must stay empty. Re-run after any runtime change; a hit is a regression to
fix at the design level (bridge / generic / ADT), never to paper over with `Any`
or `unsafe`.

---

## API surface vs the Go backend (`target=rust` coverage, v0.16.1)

The Go backend is the reference (full surface — 54 kernel modules). Rust
coverage, by confidence:

**✅ Covered & verified** (standard-libs 131/131 + the 28 `examples/rust/*` +
the HTTP/WS/Cli regression tests):
- Pure stdlib: Basics, String, List, Dict, Set, Maybe, Result, Char, Math, Path,
  Regex, Bytes (Latin-1), Encoding, Json (Encode/Decode/Pipeline), Jwt, Decimal,
  Money.
- Effects: Task, Time, Random, File, System (incl. env), Crypto, Compression,
  Csv, Uuid, Log, Db (sqlite/mysql/postgres), Auth.
- Network: Sky.Core.Http (client), Sky.Http.Server, Sky.Core.WebSocket (client —
  all four events), Sky.Http.Server.WebSocket.
- `Sky.Http.Middleware` (withCors / withLogging / withBasicAuth / withRateLimit) +
  `Sky.Http.RateLimit` (allow). server.rs `middleware_with_*` return
  `impl Fn(ServerRequest) -> SkyTask<E, Response>` that chain generically;
  `rate_limit_allow` token bucket; per-IP fixed window via the populated
  `remoteAddr` (axum `ConnectInfo` + `X-Forwarded-For`/`X-Real-IP`). Verified
  end-to-end on `--target rust` (CORS `*`, basic-auth 401→200, rate-limit) — the
  composition `Server.get "/" (h |> Mw.withCors […] |> Mw.withLogging)`
  type-checks now that upstream v0.16.3 exposed the `Handler` alias (#464) and
  fixed the typed-`SkyTask` middleware handler path (#468).
- Runtime/TEA: Cmd, Sub, Sky.Cli (line-oriented TEA backend).
- `Std.Config` (TOML/YAML/JSON decoders). Reuses the JSON Decoder over a
  serde_json::Value — TOML/YAML parse into the same Value (`toml` / `serde_yaml`)
  then the shared decoder runs (config_decode.rs). Full combinator set
  (string/int/float/bool/field/at/list/map/andThen/succeed/fail/nullable) +
  decodeToml/decodeYaml/decodeJson + loadFromFile. Verified end-to-end on
  `--target rust`: a 3-field record decoded from TOML + JSON via field/andThen/map.
  The `andThen` decoder-first codegen swap also fixed Json.Decode's `andThen`
  record-decode path.
- `Std.Trace` (span / event / attr). `span name task` runs + returns the wrapped
  task's result unchanged plus a span; output is opt-in via `SKY_TRACE` (off →
  zero noise) so spans never change behaviour. `event` marks a point, `attr`
  annotates with `sky.trace.`-namespaced keys (trace.rs).
- `Std.Email` (Resend / SendGrid / SES). `email_send` over reqwest with a
  dry-run short-circuit (`SKY_EMAIL_DRY_RUN`) and per-provider endpoint
  overrides; SES uses an in-module SigV4 (hmac + sha2). EmailMessage /
  Attachment / SesConfig / SmtpConfig + the EmailProvider ADT bridge to runtime
  types (email.rs) so the stdlib `defaultMessage` / `with*` builders and
  `Resend "k"` / `Ses cfg` lower directly. SMTP returns an explicit
  not-yet-ported `Err` (needs a transport crate). Verified end-to-end on
  `--target rust` (all four provider variants under dry-run).
- `Sky.Http.Server.Stream` (server-side SSE / chunked) — `stream` / `emit` /
  `finish` / `withContentType`. The handler is stashed via a body sentinel
  (`__sky_stream:<token>`) the ServerResponse bridge carries; `to_axum_response`
  detects it and serves a `Body::from_stream` over a bounded mpsc channel
  (`emit` = bounded send → backpressure). StreamWriter is bridged. Verified
  e2e: chunks flush ~200ms apart, not buffered (server_stream.rs,
  `examples/rust/21-sse-server`).
- `Sky.Core.Http.Stream` (client-side) — `open` / `chunks` / `forEachChunk` /
  `close`. `open` parks the reqwest response; `forEachChunk` drains
  `bytes_stream()` synchronously (the relay shape — usable in a plain
  Sky.Http.Server handler, no TEA loop). The **Sub-tier `chunks`** dispatches
  `ChunkEvent` Msgs into a `Cli.program` TEA update loop: `sub_subscribe_stream`
  returns a `SkySub::Source` that spawns ONE detached drain per id (dedup-guarded
  so the SubManager's per-update abort-respawn only hits a dummy handle — same
  shape as the WebSocket client's `onMessage`). `ChunkEvent` is bridged to a
  generic `sky_runtime::ChunkEvent<SkyError>` (the first bridged *instantiated*
  generic union — `unionToRustTypeDef` emits a `pub type` alias rather than
  `pub use` when the registry path carries `<…>`). Verified e2e via the relay
  (http_stream.rs, `examples/rust/22-sse-relay`) AND the Sub path
  (`examples/rust/26-stream-cli`: `chunks=0→6` renders prove incremental,
  non-buffered dispatch through the update loop).
- Ffi (Rust-crate auto-FFI).

**⏳ Missing — bounded & additive** (no architectural blocker; the natural next
targets):
- PubSub (`Cmd.publish` / `publishNoEcho`, `Sub.subscribeTopic`) — couples to
  Sky.Live's broker.
- `Io` (writeStdout/readLine beyond Log), `Process.run`, `Debug`, `Fmt` — small;
  partially present, not example-verified on rust.

**🚧 In progress — Sky.Live (P0 + P1 landed):**
- **P0 — bridge + static render.** `Std.Html`'s `Html`/`Attribute`/`Event` ADTs
  bridge to runtime-generic `sky_runtime::Html<M>` etc. (the `{M}` generic-alias
  codegen case — `StdHtmlHtml<msg> = sky_runtime::Html<msg>`). `assign_sky_ids`
  (stable per-element ids) + `render_html` (escaping + void + `data-sky-on`
  marker) + a full page wrap. Gate: `examples/rust/27-live-static` —
  `Live.renderStatic view 7` prints byte-correct full HTML (live/html.rs,
  live/mod.rs).
- **P1 — live TEA over HTTP+SSE.** `Live.app { init, update, view, subscriptions }`
  serves an axum router: GET renders the full page with the verbatim-ported Go
  browser client (live/client.js) + a `sky_sid` cookie, opens a per-session TEA
  driver, and serves `/_sky/sse` (hello + 15s heartbeat) + `POST /_sky/event`.
  The driver diffs view-over-view (live/diff.rs — `Patch` in Go's wire schema,
  text/attr/inner-html-replace; keyed reorder is P6) and pushes `event: patches`
  frames (`{globalSeq, patches:[{id,text|html|attrs|remove}]}`) over SSE.
  Handler resolution by sky-id (live/dispatch.rs); in-memory session store
  (live/session.rs). Gate: `examples/rust/28-live-counter` — clicking `+`/`-`
  increments the rendered span live over SSE (verified end-to-end).
- **Ahead (P2–P6):** `OnForm`/form-decode, URL routing (`routes`/`notFound`),
  Cmd/Sub depth, session-store backends (sqlite/redis/postgres/firestore) + TTL,
  keyed/faithful VNode diff, per-GET session reuse.

**🟡 Deferred — large arcs:**
- **Sky.Tui** — `Std.Ui` → ANSI renderer (~2k lines); TEA core already done, the
  renderer is the open decision (Sky-side vs runtime port).
- **Sky.Webview** — desktop (macOS-only even on Go).
- **`Std.Ui` rendering** (the `Element` layout engine) + `Lazy` — prerequisite
  for Live / Tui / Webview.

**⛔ Blocked by the no-`any` principle:** `Std.Cache` (polymorphic value storage
would require `Box<dyn Any>`).

**N/A** (compiler CLI / server-internal, not an app-runtime API): `Doc` (the
`sky doc` subcommand), `Context`.

> A definitive per-kernel parity sweep would run the full 32-example Go suite on
> `target=rust`; the table above is at the module-surface level, anchored to what
> the existing rust tests actually exercise.

---

## Modification boundaries

**When working on the Rust backend, only modify files in:**

| Directory / file | Purpose |
|---|---|
| `runtime-rust/` | Rust runtime crate (`sky_runtime` modules, property tests) |
| `src/Sky/Generate/Rust/Builder.hs` | Rust codegen — expression / type / pattern lowering |
| `src/Sky/Generate/Rust/Project.hs` | Rust-target project orchestration — emits `main.rs` + `Cargo.toml`, copies the runtime + FFI bindings |
| `src/Sky/Build/Rust/Ffi.hs` | Rust FFI — inspector invocation, `.skyi` / `.kernel.json` / `_bindings.rs` emission, type coercion |
| `src/Sky/Sky/Toml/Rust.hs` | Rust dependency-spec parsing (`RustDepSpec`) |
| `tools/sky-ffi-inspect-rs/` | Rust crate inspector (rustdoc JSON backend) |

These Rust-only modules carry **all** the backend's logic. Shared compiler files
(`src/Sky/Build/Compile.hs`, `FfiGen.hs`, `app/Main.hs`, `src/Sky/Sky/Toml.hs`)
keep only a minimal **dispatch seam** — a
`case Toml._target of { TargetRust -> …; TargetGo -> … }` that calls into the
modules above. Dependencies are one-way (shared → Rust-only, never the reverse),
so the Go path stays byte-identical and upstream merges stay small. Any change to
a shared file must be gated behind a `TargetRust ->` branch. See
`docs/runtime-rust/syncing-upstream.md` for the upstream-tracking workflow.

---

## Cross-backend rules (load-bearing — never violate)

Go is the **production / highest-priority backend**. Rust is second-tier.
These rules are non-negotiable for every contributor (human or AI):

1. **Go FFI artifacts stay at the root of `.skycache/ffi/`.**
   `.skycache/ffi/<slug>.kernel.json` and `.skycache/ffi/<slug>.skyi` are
   Go-target files. They are never moved into a subdirectory.

2. **Each non-Go backend gets its own subdirectory.** Rust artifacts live at
   `.skycache/ffi/rust/<slug>.kernel.json`. Future WASM → `.skycache/ffi/wasm/`.
   Pattern: *Go = root, everything else = named subdir.*

3. **`loadAndSeedFfiRegistry` reads target-appropriate paths.** For `target = "go"`
   (the default), the registry reads `.skycache/ffi/*.kernel.json`. For
   `target = "rust"`, it reads `.skycache/ffi/rust/*.kernel.json`.

4. **Never touch Go-generated files.** When working on the Rust backend, do not
   change a single byte of `runtime-go/`, `.skycache/ffi/<slug>.{kernel.json,skyi}`
   at the root, or `src/Sky/Generate/Go/`.

5. **Never change shared compiler code in ways that could break Go compilation
   in any fork.** New Rust functionality always goes behind explicit `TargetRust ->`
   branches. Merging target-specific logic into a unified path requires a separate,
   explicit decision — the default is **keep the branches separate**.

6. **`sky add <pkg>` routing rules:**
   - URL (`https://…`, `git@host:…`): Go → `[go.dependencies]`; Rust → `[rust.dependencies]` as `{ git = "<url>" }`.
   - Bare name: Go → `go get`; Rust → crates.io via `cargo fetch`.

---

## sky.toml Rust fields

```toml
[project]
target = "rust"                    # default is "go"; overridden by --target flag

["rust.dependencies"]
uuid    = "1.16.0"                 # crates.io — simple version string
serde   = { version = "1", features = ["derive"] }  # with features
mylib   = { git = "https://github.com/org/mylib", rev = "abc123" }  # git dep

[rust]
sqlx_tls = "rustls"               # default; alt: "native-tls"
```

There is no `[rust.shims]` section — Rust FFI is fully automatic via
`rustdoc --output-format json`. No hand-written Rust glue files are required,
even for crates that use proc macros or derive macros.

---

## Verification state (branch `feat/runtime-rust`)

### `examples/rust/` — 28/28 build + run from a wiped slate

| Example | Crate / surface | Status | What it shows |
|---|---|---|---|
| 01-rand | `rand` | ✅ builds + runs | `Rand.random_bool 0.5` → Heads/Tails |
| 02-num-cpus | `num_cpus` | ✅ builds + runs | `NumCpus.get ()` → CPU count |
| 03-chrono | `chrono` | ✅ builds + runs | `Utc::now` + Display → current UTC timestamp |
| 04-uuid | `uuid` (feat v4) | ✅ builds + runs | `Uuid::new_v4` + Display → UUID string |
| 05-roman | `roman` | ✅ builds + runs | free fns `to`/`from` → `MMXXIV` |
| 06-lipsum | `lipsum` | ✅ builds + runs | `lipsum n` → lorem ipsum text |
| 07-deunicode | `deunicode` | ✅ builds + runs | `deunicode s` → ASCII transliteration |
| 08-semver | `semver` | ✅ builds + runs | `Version::parse` + Display → re-rendered version |
| 09-bytesize | `bytesize` | ✅ builds + runs | `ByteSize::mb` + Display → `1.4 GiB` |
| 10-titlecase | `titlecase` | ✅ builds + runs | `titlecase s` → Title Cased string |
| 11-fastrand | `fastrand` | ✅ builds + runs | `fastrand::bool` → coin flip |
| 12-ulid | `ulid` | ✅ builds + runs | `Ulid::new` + Display → ULID string |
| 13-petname | `petname` | ✅ builds + runs | `petname n sep` → friendly random name |
| 14-crc32fast | `crc32fast` | ✅ builds + runs | `hash : List Int -> …` (`&[u8]` slice param) → CRC32 |
| 15-uuid-bytes | `uuid` | ✅ builds + runs | `from_bytes` `[u8;16]` param + `as_bytes` `&[u8;16]` result, via `List Int` |
| 16-hex | `hex` | ✅ builds + runs | `encode`/`decode` — generic `<T: AsRef<[u8]>>` monomorphised to `List Int` (Alt-1 proof) |
| 17-db-todo-cli | `Std.Db` | ✅ builds + runs | Full CRUD via sqlx (insert/get/update/delete/find/transaction) — reuses unmodified `examples/07-todo-cli` Sky source. Builds clean on sqlite **+ mysql + postgres** (cross-backend per `sky.toml`). |
| 18-auth-signup | `Std.Auth` | ✅ builds + runs | `register` + `setRole` via bcrypt + sqlx; duplicate-email surfaces the right error. Backend-portable schema (`db_auto_id_column` per driver) — builds clean on sqlite + mysql + postgres. |
| 19-config | `Std.Config` | ✅ builds + runs | Decodes a 5-field record from TOML, YAML, JSON (string sources) + `loadFromFile` config.toml. Exercises `field`/`andThen`/`map`/`list`/`nullable`. Regression for the decoder-first `andThen` swap + the composed-Task `block_on` entry fix. |
| 20-email | `Std.Email` | ✅ builds + runs | `defaultMessage` + `with*` builder chain (incl. `withAttachment`) and all four provider variants (`Resend`/`SendGrid`/`Ses`/`Smtp`) sent under `SKY_EMAIL_DRY_RUN`. Regression for the `++`-on-bridged-List-field and the anon-record-param field-typing codegen fixes. |
| 21-sse-server | `Sky.Http.Server.Stream` | ✅ builds + runs | `/events` SSE endpoint — `stream`/`emit`/`finish` flush five `tick` events ~200ms apart then `done` (curl `--no-buffer` confirms progressive delivery, not buffered). |
| 22-sse-relay | `Sky.Core.Http.Stream` + `Sky.Http.Server.Stream` | ✅ builds + runs | `/relay` proxies `/upstream` chunk-for-chunk via `Http.Stream.open` + `forEachChunk` re-emitting through `Server.Stream.emit`, inside a plain handler goroutine (no TEA loop). The per-token relay shape; exercises the `impl Fn` capturing-closure param fix. |
| 23-char | `Sky.Core.Char` | ✅ builds + runs | All 8 Char kernels — `isAlpha`/`isDigit`/`isLower`/`isUpper`, `toLower`/`toUpper` (single-rune String), and v0.16.7 #419 `toCode`/`fromCode` with out-of-range → U+FFFD. Mirrors Go's `unicode.*`. |
| 24-http-api | `Sky.Http.Server` (`api` + `Handler` + Middleware) | ✅ builds (curl-verified) | v0.16.x #393(d) surface — `Server.api "GET /api/ping"` route, the relocated `Handler` type alias, and `Mw.withLogging`. `curl` confirms `GET /` (HTML) + `GET /api/ping` → `{"ok":true,"msg":"pong"}` 200, middleware access-logged. |
| 25-retry | `Sky.Core.Task` (`retryWith` + `RetryPolicy`) | ✅ builds + runs | `defaultRetryPolicy |> withMaxAttempts |> withBaseMs` then `Task.retryWith policy work` → 42. Confirms the RetryPolicy<e> codegen fix at runtime; `retryWith` is run-once on Rust (SkyTask is one-shot — codegen drops the policy arg). |
| 26-stream-cli | `Sky.Core.Http.Stream` Sub-tier (`chunks`) | ✅ builds (e2e-verified) | A `Cli.program` TEA app streaming an HTTP body into its update loop as `ChunkEvent` Msgs. `chunks=0→6` view renders prove incremental, non-buffered dispatch (vs 22-relay's synchronous `forEachChunk`). Exercises `sub_subscribe_stream` (detached dedup-guarded drain) + the bridged generic `ChunkEvent<SkyError>` enum. Run against `21-sse-server`. |
| 27-live-static | `Std.Live` (P0) + `Std.Html` | ✅ builds + runs | `Live.renderStatic view 7` prints byte-correct full HTML through the bridged `Html<M>` family. Gate for the `{M}` generic-alias bridge (`StdHtmlHtml<msg> = sky_runtime::Html<msg>`), `assign_sky_ids`, and `render_html` (escaping + void + `data-sky-on`). |
| 28-live-counter | `Std.Live` (P1) — `Live.app` over axum + SSE | ✅ builds (e2e-verified) | The TEA-over-HTTP loop: GET renders the counter (sky-ids + `data-sky-on=click` + `sky_sid` cookie + embedded ported client JS); `/_sky/sse` streams `hello` then, after `POST /_sky/event {handlerId}`, an `event: patches` frame `{globalSeq, patches:[{id,text}]}` — the span increments live. Exercises `live_app`, the `Live.app{…}` record-splice peephole, per-session driver, diff, and `HandlerIndex`. |

### `examples/00-standard-libs` on `target=rust`

- `target=go`: 131 / 131 assertions pass (the suite grew past the historical 120).
- `target=rust`: **131 / 131 assertions pass — full parity with Go.** sub-A.13 +
  sub-D closed every class: empty-literal type resolution, generic-ADT + parametric
  record codegen, AEAD crypto, `task_retry_with`, the RetryPolicy phantom, stdlib
  parity (range/contains/url/Decimal), and the Bytes-on-Rust representation (the
  Latin-1 byte convention in the Encoding kernels — see "Known limitations" — which
  closed the last 4 `Sky.Core.Jwt` HS256 assertions). See
  `docs/runtime-rust/sub-A-stdlib-parity-result.md` for the timeline.

### `Sky.Http.Server` on `target=rust` (Sub-D.1)

- `tests/rust-codegen/http-server-test.sh` builds a Sky.Http.Server app on
  `target=rust`, starts it, and asserts every route over real HTTP: `GET /`,
  `GET /greet/:name` (path param → JSON), `POST /echo` (request body),
  static file serving (`/assets/*`), a 404, and the `content-type` header.
  Serves via the axum/tokio runtime (`server.rs`).

These span the common shapes auto-FFI must handle: free functions, static
methods (`Type::fn`), instance methods (`arg0.method`), `Display`/`FromStr`
bridges, `Option`/`Result` returns, byte sequences (`&[u8]`/`[u8; N]` ⇄
`List Int`), generic functions whose bound maps to a Sky type (Alt-1
monomorphisation-on-demand), non-byte slices/arrays whose element is
Sky-coercible (Alt-1 v2), and primitive ⇄ opaque round-tripping.

---

## Module structure

```
runtime-rust/src/sky_runtime/
├── config.rs         GENERATED at build time per sky.toml driver — DbPool/DbRow/SKY_DB_URL +
│                     driver-aware helpers (db_last_insert_id, db_format_sql,
│                     db_auto_id_column) for cross-backend Db + Auth schema
├── core.rs           SkyResult<E,A>, SkyMaybe<T>, SkyTask<E,A>, ok_res, str_err,
│                     list/string/float helpers, result_with_default, result_traverse,
│                     byte FFI coercion: to_u8_vec / from_u8_slice / to_u8_array
├── task.rs           task_succeed, task_map, task_and_then, task_on_error,
│                     task_fail, task_perform, task_sequence, task_run, task_parallel
├── log.rs            log_info, log_debug, log_warn, log_error, *_with variants
├── system.rs         system_args, system_exit, system_setenv, system_unsetenv
├── time.rs           time_now/sleep/unix_millis/time_string + Std.Time advanced
│                     (IANA zones, calendar math, diff*, fromParts, zoneOffset/Name)
├── random.rs         random_int, random_float (LCG, seeded from system entropy)
├── file.rs           file_read_file, file_write_file, file_exists, file_delete
├── crypto.rs         crypto_random_bytes/_token + sha2 / sha1 / md5 / hmac / RSA / constantTimeEqual
├── jwt.rs            HS256 / RS256 encode + decode (jsonwebtoken crate)
├── json.rs           JSON encode/decode, Decoder<E,T>, curry1–5, pipeline combinators
├── encoding.rs       base64, url-percent, hex (encoding_hex_encode/_decode — prefixed to
│                     avoid collision with user-FFI hex crate bindings)
├── regex_kernel.rs   match, find, findAll, replace, split (regex crate)
├── decimal.rs        Std.Decimal — pub struct Decimal(rust_decimal::Decimal) newtype +
│                     full arithmetic, comparisons, percent, formatWith
├── money.rs          Std.Money — 57-currency ISO table, format/symbol/rates/allocate
├── math.rs           sqrt/pow/round/floor/ceil/abs + polymorphic min/max + pi/e
├── dict.rs           HashMap<String,T>-backed empty/get/insert/keys/remove/member/fromList
├── string.rs         replace/startsWith/endsWith/repeat (additions beyond core.rs)
├── basics.rs         modBy (Elm positive-modulo) + errorToString (Debug-stringify)
├── list.rs           filterMap (over SkyMaybe)
├── db.rs             Std.Db — full CRUD over sqlx (insertRow/getById/updateById/deleteById/
│                     findOneByField/findManyByField/findByConditions/unsafeFindWhere/
│                     queryDecode/withTransaction/close + raw exec/query/migrate).
│                     Cross-backend: sqlite / mysql / postgres via config.rs helpers.
├── auth.rs           Std.Auth — bcrypt hash/verify/strength + jsonwebtoken HS256
│                     sign/verify + register/login/setRole over sqlx. Schema is
│                     backend-portable via db_auto_id_column() in config.rs.
├── ffi_polyfills.rs  Ffi.callPure / callTask / toAny runtime polyfills (panic-with-message
│                     for non-peephole-resolvable shapes; identity for toAny)
├── live/             Sky.Live (P0+P1) — feature-gated `live`; copied as a subdir
│   ├── html.rs       Html<M>/Attribute<M>/Event<M> enums (bridge target) + assign_sky_ids + render_html
│   ├── diff.rs       Patch (Go wire schema) + minimal text/attr/inner-html diff
│   ├── dispatch.rs   HandlerIndex<M> + resolve(sky-id, event, args) / resolve_form
│   ├── session.rs    LiveSession<Model,Msg> + in-memory MemStore<T>
│   ├── sse.rs        SsePatch / SseTx / channel / frame (text/event-stream framing)
│   ├── client.js     browser client, ported verbatim from Go's live.go (include_str!'d)
│   └── mod.rs        live_render_static (P0) + live_app (P1: axum + per-session TEA driver) + render_page_full
└── mod.rs            re-exports config + core; other modules via sky_runtime::<mod>::<fn>
```

The mod list in this file is the source of truth for standalone-crate testing. In a
generated project, `Project.hs` writes a parallel `mod.rs` that mirrors this list
(modulo the `cfg(feature)` gating).

---

## Error type

All runtime functions are generic over `E`. `Builder.hs` emits thin wrappers
that instantiate `E = SkyError` for the generated project:

```rust
// sky_runtime/task.rs (generic):
pub fn task_map<E, A, B>(f: impl FnOnce(A) -> B + Send + 'static,
                         task: SkyTask<E, A>) -> SkyTask<E, B>

// generated main.rs (wrapper, E = SkyError fixed):
pub fn task_map<A, B>(f: impl FnOnce(A) -> B + Send + 'static,
                      task: SkyTask<A>) -> SkyTask<B> {
    sky_runtime::task::task_map::<SkyError, _, _>(f, task)
}
```

---

## Rust FFI

`sky add <crate> --target rust` invokes `sky-ffi-inspect-rs`, which:

1. Creates a temporary Cargo project with the crate as a dependency.
2. Runs `cargo +nightly rustdoc --package <crate> --lib --output-format json`.
   This executes **after** proc macro expansion, so derive-generated impls
   (clap `Parser`, serde `Serialize`, etc.) are fully visible.
3. Parses the JSON output to extract public functions, impl block methods,
   and trait impls — including those generated by macros.
4. **Facade detection:** if the crate is a thin re-export (`pub use underlying::*`)
   with zero functions, the inspector follows the glob to the underlying crate
   and re-runs rustdoc on it automatically (e.g. `clap` → `clap_builder`).
5. Maps Rust types → Sky types (`Vec→List`, `Option→Maybe`, `HashMap→Dict`,
   `Result→Result E A`, `SkyResult<E,A>→Result E A`).
6. Emits JSON matching the `PkgInfo` schema (defined in `FfiGen.hs`, parsed by `Sky.Build.Rust.Ffi`).
7. Writes `.skycache/ffi/rust/<slug>.kernel.json`, `.skycache/ffi/rust/<slug>.skyi`,
   and `.skycache/ffi/rust/<slug>_bindings.rs` (all three Rust artifacts share
   the `.skycache/ffi/rust/` subdirectory).

Generated bindings use `import Rust.<Name> as Name` in Sky source. Method
bindings are disambiguated by receiver: `Utc::now` → `now_from_utc`,
`DateTime::to_string` → `to_string_from_dateTime`.

### Opaque-type qualification

Every crate-local opaque type is emitted **fully-qualified by its public
re-export path** (`chrono::NaiveDate`, `chrono::format::Parsed`), keyed on the
rustdoc item id. This is unambiguous — it avoids glob-import name clashes (e.g.
a crate with two `Error` types in different submodules) — so the wrappers need
only a single root `use <crate>::*;`.

### Nameability filter — bindings that can't compile are dropped, not emitted

The inspector skips any function it cannot turn into a sound monomorphic
wrapper, so the generated `_bindings.rs` always compiles:

| Dropped | Why |
|---|---|
| Generic functions (`fn f<T>`) and impl-level generics (`DateTime<Tz>`) | no concrete type at the FFI boundary |
| Lifetime-parameterised types (`Item<'a>`, `&'a str`) | borrow scope can't be expressed in an owned wrapper |
| Borrowed results (`&mut Builder`, nested `(.., &[u8;8])`) | tie to a lifetime the wrapper can't supply |
| Non-byte arrays / slices (`[f64; 3]`, `&[String]`) | element coercion not implemented |
| `unsafe fn` | auto-exposing e.g. `new_unchecked` would bypass invariants |
| Private crate types & external/std types (`Duration`, `RangeInclusive`) | no nameable public path |

Plain `&str`/`&String` results are kept (copied to an owned `String`). **Byte
sequences** (`&[u8]`, `Vec<u8>`, `[u8; N]`, `&[u8; N]`) are kept and bridged to
Sky `List Int` (see the coercion rules below). Crate-local **non-generic type
aliases** are resolved to their underlying type first (`uuid::Bytes = [u8; 16]`)
so the byte/array detection sees the real shape.

### Deduplication

Bindings are deduped once in `generateBindings` (Rust path) so the `.rs`, `.skyi`,
and `.kernel.json` agree. A real `to_string`/`from_string` method colliding with
the synthetic Display/FromStr bridge (e.g. `ulid::Ulid`) collapses to one entry.

### Inspector binary resolution (priority order)

| Priority | Source |
|---|---|
| 1 | `$SKY_FFI_INSPECTOR_RS` env var |
| 2 | `./bin/sky-ffi-inspect-rs` (walking up ancestors) |
| 3 | Binary embedded in the `sky` binary (materialised on first use at `~/.cache/sky/tools/sky-ffi-inspect-rs/`) |

The embedded path bundles the pre-built release binary via Template Haskell.
Source files in `tools/sky-ffi-inspect-rs/` are registered as TH dependencies;
editing them triggers a rebuild of both the inspector and the `sky` binary.

### Feature flags

```bash
sky add uuid --features v4 --target rust
```

Recorded in `sky.toml` as `uuid = { version = "1", features = ["v4"] }` and
passed through to `Cargo.toml` by `emitCargoToml`.

### Display/FromStr bridge

For opaque types that implement `Display`/`FromStr`, the inspector auto-generates
synthetic `to_string`/`from_string` bindings so Sky code can convert to/from
`String` without any manual glue.

---

## FFI reach: what auto-FFI can and cannot cover

**The boundary is type-theoretic, not a maturity gap.** Verbatim automatic FFI
to *arbitrary* Rust crates — especially frameworks — is impossible in principle.
Only `rustc` can resolve Rust's:

- **generics** — monomorphized: a generic `fn f<T>` has *no callable symbol*
  until concrete `T`s are chosen (an unbounded space). The inspector drops every
  generic fn wholesale (`tools/sky-ffi-inspect-rs/src/main.rs:594`).
- **traits** — open: to *supply* an `impl Trait` argument you must synthesise a
  conforming type; to *consume* trait-generic APIs you must reproduce trait
  resolution.
- **lifetimes** — aliasing constraints with no analogue in a GC language
  (dropped at `main.rs:678`).

A rustdoc-metadata binding generator is strictly weaker than the compiler, so
"bind any crate's full API automatically" is unreachable for the
generic/trait/lifetime-heavy long tail.

**Two universes:**

| Universe | Examples | Auto-FFI |
|---|---|---|
| Leaf / data-shaped | hashing, encoding, parsing, math, time, regex, codecs, many client SDKs | Works; genuinely universal over this class |
| Framework / DSL / async | axum, bevy, diesel, tokio | Core is generic + trait + `Stream`; auto-binds almost nothing usable |

Even some "leaf" crates are partly generic — `hex::encode<T: AsRef<[u8]>>` drops,
leaving only 1 bound fn — which is exactly why the widening work below matters.

**Three directions (decide on evidence — see the `/ffi-audit` skill):**

- **Alt 1 — widen the leaf universe (zero per-crate glue).** Stop dropping
  generics wholesale: emit a monomorphic wrapper for each concrete instantiation
  the Sky program actually uses (Sky's HM solver already knows the types at the
  call site, exactly as rustc monomorphises). Plus std-type mapping,
  builder / `&mut self`→take-return, full non-byte slice/array + iterator→`Vec`
  coercion. Captures most leaf libraries *fully*. Does **not** reach axum.
- **Alt 2 — compiler-generated idiomatic Rust glue.** For frameworks, emit *real*
  crate-idiomatic Rust (real `Router`/`get`/`serve`/`Sse`), wiring Sky-compiled
  closures as `impl Handler` and Sky channels as `Stream`s; `rustc` does the
  trait/lifetime solving. Generated, not hand-written (no *manual* shims) — but
  needs a usage model per framework shape. The only route to verbatim-ish axum + SSE.
- **Alt 3 — Sky-native modules over best-in-class crates (the Sky.Live model).**
  Don't expose axum at all; build `Sky.Http.Server` / `Sky.Live` on the Rust
  runtime *using* axum/hyper internally, exposing the Sky-idiomatic surface that
  already exists on the Go backend. First-party runtime Rust (like today's
  `sky_runtime/*.rs`), not per-crate shims — the standard way languages ship
  frameworks.

**Recommended mission framing:** automatic FFI across Rust's leaf-library
universe (Alt 1) **+** Sky-native modules over its best frameworks (Alt 3).
"Verbatim FFI to any framework" is a deliberate non-goal; Alt 2 is reserved for
if that ever becomes a hard requirement.

**Case study — axum 0.8.8.** The inspector kept 56 functions, *all peripheral*
(Redirect / KeepAlive / Event constructors, ~20 error `body_text`,
`MatchedPath::as_str`); the entire router / handler / extractor / `Sse` core
dropped (generic + trait + `Stream`). You cannot register a route or build an
SSE response through raw auto-FFI — which is the proof, not a bug.

**Measuring it.** The `/ffi-audit` skill
(`~/.claude/skills/ffi-audit/ffi_audit.py`) runs the inspector across a
~50-crate sample and ranks each crate by its **constructable surface**
(`free + ctor` — functions that let Sky obtain or call something standalone, vs.
accessors on values it can't construct). Tiers: `rich` ≥10 · `usable` 3–9 ·
`thin` 1–2 · `peripheral` 0 (accessors only, e.g. axum) · `empty`. A precise
drop-reason histogram (generic / lifetime / trait) would need an inspector
`--audit` mode tagging each `return None` site.

### Measured coverage (50-crate sample, default features)

| Tier (free+ctor) | n | Examples |
|---|---|---|
| **rich** (≥10) | 13 | chrono 50, uuid 39, actix-web 34, redis 28+, time 27, bevy_ecs 26, reqwest 23+, ron 18, num-bigint 17, rusqlite 14+, ureq 14+, semver/clap 11 |
| **usable** (3–9) | 9 | **hex** (Alt-1), blake3, csv, base64, serde_json, tungstenite, url, serde_yaml, **ndarray** (Alt-1 v2) |
| **thin** (1–2) | 13 | base32, bytesize, crc32fast, arrayvec, toml, regex, nalgebra, sqlx, **axum**, humantime, itoa, ryu, unicode-segmentation |
| **peripheral** (0 ctor, accessors only) | 8 | percent-encoding, **indexmap, smallvec, itertools, ordered-float, bitflags**, quick-xml, tracing |
| **empty** (0 kept) | 7 | **sha2, md-5** (RustCrypto `Digest` is all-trait), byteorder, num, **diesel, tokio, tower** |

**Headline finding — the dominant blocker is wholesale generic + trait drop.**
The crates that bind well are *self-typed* (chrono, uuid, semver); the ones that
bind nothing are *trait-fronted or generic*. `sha2`/`md-5` bind **zero** because
`Sha256::new()` lives on the `Digest` trait; generic containers
(`indexmap`/`smallvec`/`itertools`) are peripheral because their value is `<K,V>`
/ `<[T; N]>`. **This is exactly the Alt-1 recovery set** — monomorphise-on-demand
at the concrete types a Sky program uses would light up the entire hashing +
generic-container + `hex::encode<AsRef<[u8]>>` class (the bulk of the bottom two
tiers).

A `rich` **framework** (actix-web/bevy_ecs/clap) is the trap in this metric: the
bound constructors are secondary config/error/builder types — the *core*
abstraction (routing/handler/`Sse`, ECS queries, the derive arg-parser) is
generic + trait + macro and still drops. So frameworks stay **Alt-3** (Sky-native
modules over the crate), never verbatim FFI — as the axum case study above shows.

*Caveat:* this pass used **default features only** — `tokio` (no features),
`diesel` (needs a backend), `sqlx` (needs runtime+driver) undercount. Rerun with
features to raise them:
`/ffi-audit run --features "tokio=full;diesel=sqlite" --force`.

**Alt-1 v1 update (shipped).** Inspector now monomorphises generic fns whose
bound maps to a Sky type — `AsRef<[u8]>`/`Into<Vec<u8>>`/`IntoIterator<Item=u8>`
→ `List Int`; `AsRef<str>`/`Into<String>`/`Display`/`ToString` → `String`. Same
for `impl Trait` args (resolvable bounds get substituted; unresolvable ones drop,
soundness-gated). Empirical delta on the 50-crate sample after a forced re-run:
**hex peripheral → usable** (`encode`/`encode_upper`/`decode` now bind — the
prediction in the headline below). Other generic-fronted crates with unmapped
bounds (RustCrypto `Digest`, generic containers' element-type `T`, custom
`Integer`/`Float`/`Element` traits) still drop — they need cross-crate trait
resolution and a broader v2 table, not just v1's `AsRef`/`Into`/`Display` family.
End-to-end proof: `examples/rust/16-hex/`.

**Alt-1 v2 update (shipped — paired).** Inspector now (a) resolves `AsRef<X>` /
`Borrow<X>` / `Into<X>` / `IntoIterator<Item=X>` for any X the table can map
(recursive `concrete_for_inner_type` helper), with new entries for
`AsRef<Path>`/`<OsStr>`, `Into<PathBuf>`/`<OsString>` → `String`; numeric
`Into<i64/i32/u32/u64/usize/isize>` → `Int`; `Into<f64/f32>` → `Float`;
`num_traits::Integer` → `Int`; `num_traits::Float` → `Float`. (b) Lifts the
unconditional non-byte slice/array drop: `&[T]` / `Vec<T>` / `[T; N]` /
`&[T; N]` survive whenever T is Sky-coercible. The FFI codegen generalised
`ByteKind` → `SeqKind {shape, elem}` and a new generic runtime
`to_array<E, T: Clone, const N>` mirrors `to_u8_array`'s never-panic discipline.
Empirical delta on the 50-crate sample after a forced re-run: **ndarray thin →
usable** (+4 free fns from generic-bound recovery); plus material function-count
gains in already-rich crates (`reqwest` +50, `redis` +24 — recursive composition
catching wider generic surface). Known v2 gap: `PathBuf`/`Path`/`OsStr`/`OsString`
results remain opaque — `concrete_for_inner_type` only fires inside *bound*
resolution, not for general return types, so path crates like `path-clean`
(whose primary `clean` returns `PathBuf`) still drop. Real v3 follow-up. The
cross-crate `Digest` and generic-container classes remain out of scope (still
need their own subsystems).

**Soundness gate (added after `09-bytesize` regression).** v2's initial
`Into<X>`/`From<X>`/`AsRef<X>`/`Borrow<X>` arms recursed via
`concrete_for_inner_type` for the inner X, which collapses every integer
primitive to `i64`. That makes `Into<u32>` substitute T = i64 — but
`i64: Into<u32>` isn't implemented, so the emitted wrappers don't compile
(`u64: From<i64>` E0277). After this surfaced on the bytesize example during
an upstream sync, the arms were restricted: primitive-numeric `Into`/`From`
only resolve at identity (`Into<i64>` → i64, `Into<f64>` → f64);
`AsRef<primitive>` only resolves at `AsRef<str>` → `String`. Other primitive
targets drop (restoring v1 behaviour for those bounds). Non-primitive targets
(`str`/`Path`/`OsStr`/`String`/`PathBuf`/`Vec<u8>`/slices) keep the v2
recursive resolution. This is the reason bytesize's earlier "rich" recovery
reverted to its v1 `thin` verdict — the lost bindings were unsound and
wouldn't have compiled in real use.

*Note on e2e examples:* `examples/rust/17-paths` and `18-shell-join` from the
v2 plan were not added — `path-clean::clean` returns `PathBuf` (gap (i) above)
and `shellwords::join` is absent from the 1.x rustdoc. The empirical 50-crate
audit re-run is the verification.

### Theoretical reach (with full engineering)

A more fundamental question than "what does v2 cover": **even with every
foreseeable engineering investment short of changing Rust itself — cross-crate
trait resolution, generic-container instantiation, builder/`&mut self`→take-return,
iterator materialisation, async-as-Task adapters, closures via Sky lambdas
compiled to Rust `Fn`s — how much of Rust code is still impossible to FFI?**

Five tiers, with sharply different reasons:

**Tier 1 — Fully auto-bindable** (~50–60% of crates.io): data / leaf libraries
(parsers, codecs, hashing, math, time, regex, most client SDKs). Reachable
with v1 + v2 + the deferred sub-features (cross-crate `Digest` family, generic
containers, full numeric coverage, builder transform, iterator → `Vec`).

**Tier 2 — Bindable only via *per-shape* generated glue** (~25–35%): framework /
DSL / async crates (`axum`, `bevy`, `diesel`, `tokio`, `actix-web`, `sqlx`).
The TYPES are visible in rustdoc; what's missing is the **idiomatic usage shape**
— routing/handlers/extractors, ECS queries, query builders. Each framework's
"how to use it" is encoded *outside* its types. Generated idiomatic-Rust glue
can express it (rustc solves the rest), but that's *adapter-per-crate-family*,
not "automatic." This is the Alt-1 ↔ Alt-2 boundary.

**Tier 3 — Bindable but lossy** (~5–10%): semantics necessarily change.
- `Iterator<Item = &T>` borrowed-view iterators (`Lines<'a>`, `&str::split`) →
  materialise to `Vec<T>`, eliminating laziness and breaking streaming/huge inputs.
- `&mut self` builder chains → take-and-return-owned, doubling allocation traffic.
- Trait objects in return position (`Box<dyn Trait>`) — concrete type hidden by
  design; only the bound's methods are callable.
- Type-state APIs (`Builder<NotConfigured>` → `Builder<Configured>`) → each
  state gets separate bindings; infinite-state encoding (type-level numerics)
  can't be fully enumerated.

**Tier 4 — Fundamentally impossible** (~5–10% of *function surface*, ~1–3% of
*crates* end-to-end): things Rust expresses that no FFI wrapper can express
without changing Rust's type system or Sky's runtime model.

| Pattern | Why impossible |
|---|---|
| `Pin<P>` in user-facing positions (`Stream::poll_next(self: Pin<&mut Self>)`) | Sky's GC moves values; can't construct `Pin<&mut T>` from Sky memory and honour the no-move invariant. Internal pinning (Sky's async runtime pins a Box and never exposes it) works for *implementing* runtimes, not for *exposing* implementor APIs. |
| Raw pointers (`*const T` / `*mut T`) | Pointer arithmetic semantics; no analogue in Sky's GC value model. |
| `MaybeUninit<T>` | Uninitialised memory APIs; Sky values are always initialised. |
| `unsafe fn` / `unsafe impl` | "Type system can't verify safety; caller must." Sky callers can't reason about Rust unsafe contracts; binding requires manual per-fn safety review. |
| HRTBs (`for<'a> F: Fn(&'a T) -> &'a U`) | Universally-quantified lifetime types don't exist in HM; concrete `Fn(T) -> U` closures work, HRTBs don't. |
| GATs with lifetime-bearing assoc types (`trait Lender { type Lend<'a>; }`) | The assoc type itself is a lifetime function; can't be inverted to an owned Sky type. |
| Type-level computation outputs that depend on unsolved generics (`fn foo<T>() -> [u8; T::N]`) | Array size *computed by trait resolution*; resolvable for concrete T, not for an unbound generic position. |
| Compile-time macro DSLs validated against external state (`sqlx::query!("SELECT …")`, `askama` templates) | The `!` macro processes a string literal at compile time, validates against the database schema, emits typed code. Expansion result depends on inputs the inspector can't see. |

**Tier 5 — Outside FFI's natural scope**: custom allocators, panic handlers,
no-std targets, inline assembly. These ARE the runtime; even Rust-to-Rust
interop with them is constrained.

#### Realistic numbers

| Category | Fraction of crates.io |
|---|---|
| Fully auto-bindable (Tier 1, given the deferred sub-features) | ~50–60% |
| Bindable via generated glue (Tier 2) | ~25–35% |
| Bindable with semantic loss (Tier 3) | ~5–10% |
| Some functions impossible, rest workable (Tier 4 mixed) | ~5–10% |
| **Effectively unbindable end-to-end (mostly Tier 4 + 5)** | **~1–3%** |

**The hard ceiling is ~95–97% of crates having at least their core API
exposable** even under perfect engineering. The unbindable residue is
overwhelmingly low-level async runtime *internals*, raw-pointer/`MaybeUninit`
foundational crates (`libc`, allocators, atomics), macro-DSLs with compile-time
external validation, and `Pin`-exposing implementor traits. Application code
almost never needs these — they're runtime/foundation Sky would reimplement
internally anyway.

#### Strategic implication

The "impossibility ceiling" matters less than the **per-crate cost curve**.
Automatic FFI is genuinely universal over the Tier 1 universe; Tier 2 is where
engineering cost explodes (each framework needs a *usage model*, and there are
dozens of shapes). **The realistic Sky-Rust mission stays: automatic Tier 1 +
Sky-native modules over Tier 2 frameworks** — not because Tier 2 is impossible
but because per-framework automatic glue costs more than just *being* `Sky.Live`
(built on hyper/axum internally, exposing a Sky-native surface). The
fundamentally-impossible 3–5% is runtime/foundation code, not application code.

---

## FFI codegen type-coercion rules

`Sky.Build.Rust.Ffi` (`emitRustFnSimple`) uses these rules when emitting wrapper bodies.

**Parameter type (`resolveRustType`).** A param's wrapper type is the *Sky-mapped*
type for known Sky types, so the wrapper takes the owned value the call site
passes. The inspector's raw Rust type is used only for opaque types (and is
fully-qualified):

| Sky param type | Wrapper param type |
|---|---|
| `String` | `String` (borrowed internally via `&argN`) |
| `Int` / `Float` / `Bool` / `Bytes` | `i64` / `f64` / `bool` / `Vec<u8>` |
| `List a` / `Maybe a` / `Dict String v` | `Vec<…>` / `SkyMaybe<…>` / `HashMap<…>` |
| opaque type | the fully-qualified raw type (`chrono::NaiveDate`) |

**Parameter coercion (`argCall`).** Byte-sequence params take a Sky `List Int`
(`Vec<i64>`) and coerce to the raw Rust shape:

| Declared wrapper type | Raw Rust fn param type | Emitted arg |
|---|---|---|
| `String` | `&str` | `&argN` |
| `i64` / `f64` | narrower numeric (`u32`, `usize`, `f32`, …) | `argN as <rawType>` |
| `Vec<i64>` | `&[u8]` | `&to_u8_vec(&argN)` |
| `Vec<i64>` | `Vec<u8>` | `to_u8_vec(&argN)` |
| `Vec<i64>` | `[u8; N]` / `&[u8; N]` | body-prelude local `bN` / `&bN` (see below) |
| anything | same / absent | `argN` |

A `[u8; N]` / `&[u8; N]` param adds a prelude line to the wrapper body:
`let bN: [u8; N] = match to_u8_array::<SkyError, N>(&argN) { Ok(a) => a, Err(e) => return Err(e) };`
— a length mismatch returns `Err`, never panics.

**Return type + coercion (`translateRustRet`).** The declared return type and the
lifting expression are derived from the *raw Rust return type* (the source of
truth — the Sky type collapses opaque types to `String`):

| Raw Rust return | Declared wrapper return | Lift |
|---|---|---|
| `&[u8]` / `Vec<u8>` / `[u8; N]` / `&[u8; N]` | `Vec<i64>` (Sky `List Int`) | `from_u8_slice(&e)` (or `from_u8_slice(e)` for refs) |
| `Option<T>` | `SkyMaybe<T'>` | `match … { Some(v) => SkyMaybe::Just(co v), None => SkyMaybe::Nothing }` |
| `Vec<T>` | `Vec<T'>` | per-element `.map` only when `T` needs coercion |
| `iN` / `uN` | `i64` | `(e) as i64` |
| `f32` / `f64` | `f64` | `(e) as f64` |
| `bool` / `String` | `bool` / `String` | identity |
| `&str` / `&String` | `String` | `e.to_string()` |
| `()` / none | `()` | identity (the call still executes) |
| opaque `T` | `T` (qualified) | identity — no `.into()` |

Effect drives the wrapper body: `pure` → `ok_res(lift(call))`; `fallible` →
`match call { Ok(v) => ok_res(lift(v)), Err(e) => SkyResult::Err(str_err(…)) }`
(the Ok type is extracted from `Result<T, E>` before lifting); `effectful` →
the same inside `Box::pin(async move { … .await })`. `.into()` and
`.try_into().unwrap()` are never emitted.

---

## CLI usage

```bash
# Build for Rust target
sky build src/Main.sky --target rust

# Build and run
sky run src/Main.sky --target rust

# Type-check (runs full emit + cargo build)
sky check src/Main.sky --target rust

# Run tests
sky test tests/MyTest.sky --target rust

# Add a crate dependency (fully automatic — no shims needed)
sky add uuid --target rust
sky add rand --features="small_rng" --target rust
sky add clap --features="derive" --target rust   # proc macros fully visible

# Regenerate all Rust FFI bindings (after rm -rf .skycache)
sky install
```

---

## Disk hygiene

Cargo builds accumulate fast. A full Rust-example sweep can produce 20+ GB of `target/` dirs across the examples. Locations and their sizes after typical sessions:

| Path | Typical size | What | Regen cost |
|---|---|---|---|
| `runtime-rust/target/` | up to ~4 GB | runtime crate's own `cargo build`/`test --features full` outputs | ~2-3 min `cargo test --features full --lib` |
| `runtime-rust/tests/**/sky-out/Rust/target/` | varies | per-test-fixture cargo targets | per-fixture, usually <1 min |
| `tools/sky-ffi-inspect-rs/target/` | ~600 MB | inspector cargo target (only when iterating on inspector source) | ~30 s |
| `examples/rust/*/sky-out/Rust/target/` | 1-2 GB each | per-example cargo targets — 26 examples → up to 52 GB if all built without cleanup | ~30-60 s per example |
| `~/.cache/sky/tools/sky-ffi-inspect-rs/` | ~500 MB | TH-materialized inspector source + its built target binary | ~30 s on next `sky add --target rust` |
| `dist-newstyle/` (cabal output) | ~200 MB | Sky compiler build artifacts | ~3-5 min full rebuild |

**Per-example sweep idiom** (already used in scripts and `runtime-rust/superpowers/plans/`):

```bash
for d in examples/rust/*/; do
    (cd "$d" && rm -rf sky-out .skycache .skydeps
        && /home/arthur/Documentos/comp/sky/sky-out/sky build src/Main.sky
        && rm -rf "$d/sky-out/Rust/target")
done
```

The `rm -rf .../sky-out/Rust/target` immediately after each build is what keeps the loop from filling the disk. Without it, the 18-example sweep needs ~36 GB headroom; with it, ~2-3 GB peak.

**Manual reclaim** when disk is tight:

```bash
rm -rf runtime-rust/target                              # ~4 GB
rm -rf tools/sky-ffi-inspect-rs/target                  # ~600 MB
rm -rf ~/.cache/sky                                     # ~500 MB
find examples/rust -type d -name target -exec rm -rf {} + 2>/dev/null   # whatever's there
```

`~/.cargo/registry/` and `~/.cargo/git/` are global Cargo state shared across all your Rust projects — leave them alone unless you genuinely need the GB-scale reclaim. They auto-prune on Cargo's schedule and rebuilding them is slow (re-downloads crate metadata).

CLAUDE.md non-negotiable §6 (added upstream v0.15.54) codifies disk hygiene as a contributor rule; the table above is the Rust-specific extension.

---

## Known limitations

| Limitation | Description | Workaround |
|---|---|---|
| Empty-literal type resolution | ✅ fixed by sub-A.13 (call-site param-type propagation in `emitDefaultCall`). Residual edge: an empty list passed to a known-generic stdlib fn whose only type-pinning argument is a *closure with a body-determined param type* (e.g. `List.map (\s -> String.length s) []` in a discarded position) defaults the element to `i64` instead of inferring from the closure body. Not hit by the test suite; the closure-exclusion is what makes `map (\x -> x*2) Nothing` resolve. | Annotate the source, or bind the list to a typed `let`. |
| `any` in record fields on `target=rust` | The Rust codegen refuses to emit `Box<dyn Any>` for an `any`-typed Sky record field (load-bearing architectural principle — see the section above). Build fails with a structured `error[Rust]: any-typed record field on \`--target rust\`` diagnostic. | Encode the heterogeneous field as an ADT upstream (the path PR #119 took for `RetryPolicy`), or — defence-in-depth — ship a Rust-target override at `runtime-rust/sky-stdlib-overrides/<Module>.sky` with an HM-pure shape. |
| `Task.retryWith` is run-once on `target=rust` | ✅ resolved (v0.16.10 sync). Upstream's `retryWith : RetryPolicy e -> Task e a -> Task e a` is task-shaped, and Rust's `SkyTask = Pin<Box<dyn Future>>` is one-shot (not `Clone`), so a true retry loop would need a fresh Future per attempt. The codegen ships **run-once** semantics: `emitDefaultCall` drops the policy arg and threads the task through (`task_retry_with(task)`). The policy still type-checks + constructs (the RetryPolicy<e> codegen fix), the task runs once, the value flows back. Confirmed by `examples/rust/25-retry`. A real multi-attempt loop is a future arc needing a thunk-shaped `retryWith` (`() -> Task e a`) upstream, or a cloneable SkyTask. | For multi-attempt retry today, drive the loop in Sky (recurse on the `Result`). |
| `Result.mapError` inference cascade | After F1's polymorphic signature fix the closure infers; outer call-site inference can still ambiguate the SkyResult<E,T> ok-slot. | Wrap in a typed `let` to pin E1/E2 at the call site. |
| `withTransaction` rollback isolation | `db_with_transaction` uses sqlx's pool API; BEGIN/COMMIT/ROLLBACK run on the pool but body queries may route to other pool connections. Real rollback isolation requires single-connection pools. | Configure `sqlx::Pool::max_connections(1)` in production code that needs guaranteed rollback. Documented inline in `db.rs`. |
| `Db.insertRow` on postgres | Returns 0 (no auto last-insert-id in postgres). | Use `INSERT … RETURNING id` + `Db.queryDecode` to fetch the new id explicitly. Documented in generated `config.rs` for postgres. |
| JSON pipeline decoder | `Box<dyn FnOnce>` chain in pipeline combinators may not satisfy `Clone+Send` in some shapes. | Use raw `JsonDec.decodeString` + `JsonDec.field` directly, not the pipeline `|=` style, when this surfaces. |
| Flat main.rs | All Sky modules compile into a single `main.rs`; no `pub mod <X>;` declarations. | Planned cleanup; doesn't affect correctness. |
| `sky install` git deps — virtual-workspace roots | When a git source's root `Cargo.toml` is workspace-only (no `[package]` section), the package-name probe falls back to the URL basename and can land on the wrong dep key. | Add the crate with an explicit URL pointing at the right workspace member, or open the repo and verify the directory matches the package name. |
| `rustdoc` requires nightly | Inspector runs `cargo +nightly rustdoc`. | `rustup install nightly`. |
| Un-nameable bindings dropped | Functions taking/returning generics, NON-byte slices/arrays, borrows, std types, or unsafe fns are skipped (byte sequences are kept). | Use a wrapper crate exposing owned/primitive signatures, or pick a crate whose API is self-typed. |
| Bytes-on-Rust (`Sky.Core.Bytes = String`) — non-ASCII text base64/hex | Sky models bytes as `String`; a Rust `String` must be valid UTF-8. The Encoding kernels use a **Latin-1 byte convention** (one char per byte) so raw bytes round-trip losslessly — `hexDecode`/`base64Decode` emit byte-as-char, `hexEncode`/`base64Encode` read char-as-byte. This fixes the byte pipeline (incl. `Sky.Core.Jwt` HS256). **Tradeoff:** for NON-ASCII *text*, char-as-byte ≠ UTF-8 bytes, so a base64/hex string of non-ASCII text compared against a Go-/externally-computed value diverges (ASCII is byte-identical; encode/decode still round-trip within Rust). A true `Vec<u8>` Bytes type is unreachable — the Encoding fns are typed `String`, not `Bytes`. | For Go-identical non-ASCII text encoding, pre-`String.toBytes` then encode, or compare decoded values rather than encoded strings. |
| `Task.retryWith` run-once | The policy's retry loop is not executed on `target=rust` — the task runs exactly once (one-shot `Future` + no reflection over the generated `RetryPolicy` struct). Correct for deterministic tasks; a transient-failure task is not retried. | Faithful retry needs a thunk-shaped `retryWith` or policy-field-passing codegen. |

---

## Remaining work

### Architectural principle (load-bearing for every future arc)

**The Rust backend uses Rust's static type system. Sky's `any` is never lowered to `Box<dyn Any>` / `Arc<dyn Any>` on `target=rust`.** Doing so re-implements Go's `interface{}` in Rust syntax and defeats the entire reason to have a Rust backend (static dispatch, no runtime type erasure, cargo catches shape mismatches at compile time). The codegen refuses `any` in record-field positions with an actionable diagnostic; any Sky stdlib surface upstream ships with such a field needs either an upstream ADT redesign (preferred) or a Rust-target stdlib override at `runtime-rust/sky-stdlib-overrides/<Module>.sky` (defence-in-depth fallback).

### Active — sub-D arc (v0.15.51 sync + Rust adaptations)

The original sub-D arc against v0.15.44 (WIP sister branch `feat/runtime-rust-subd-v0.15.44`) is retired. Its core blocker was upstream's `RetryPolicy.shouldRetry : any` field; that surface was redesigned upstream as `type ShouldRetry e = RetryAlways | RetryWhen (e -> Bool)` and merged at `anzellai/sky` PR #119 (v0.15.50). The Sky.Core.Task override the WIP branch shipped is no longer needed — upstream now declares the ADT directly. The override **infrastructure** is retained on the new branch as forward defence for any future `any`-in-record-field surface upstream may introduce.

| Sub-step | Status | What it ships |
|---|---|---|
| Sub-D step 1 — override loader + `any`-rejection diagnostic | ✅ shipped & validated on the retired sister branch; carrying forward to the v0.15.51 restart | TH-embedded `runtime-rust/sky-stdlib-overrides/<Module>.sky` overlay, target-gated; `error[Rust]: any-typed record field on --target rust` diagnostic with actionable note pointing at the override mechanism |
| Sub-D step 4 — generic-ADT codegen fixes (E0428/E0412/E0107/E0599/E0091) | ✅ **shipped** (`fdb8393d`). `REnumDef` gained a generics slot (computed from `_u_vars`); `collectUndefinedTypes` compares/emits the base type name so `ShouldRetry<e>` no longer triggers a colliding `type … = String` placeholder. Record-alias side: `aliasToRustTypeDef` emits struct generics from the alias `_vars`, `typeToRustString` carries `TAlias` args, `collectTVars`/`hasTypeVars` recurse into them, and the synthesized record constructor declares the vars + returns the generic struct. Type vars kept verbatim (lowercase) — correctness, not the cosmetic `e`→`E` rename. Verified: `examples/rust` 18/18 build (17 & 18 restored); `tests/rust-codegen/generic-adt.sky` builds + runs. |
| Sub-D Tasks 6-14 — runtime kernels + AEAD + Bytes + HTTP types | ✅ **shipped** (standard-libs 131/131 on target=rust). AEAD kernels (aes-gcm / chacha20poly1305 / PBKDF2), `task_retry_with` (run-once), `Task.perform`→`task_run`, Decimal.fromMinor + stdlib parity (range/contains/url), case-scrutinee clone analysis, and the **Bytes-on-Rust Latin-1 byte convention** (closes Sky.Core.Jwt HS256). HTTP types: the Sky.Http.Server runtime now lands on Rust (sub-D.1 below). |

### Lessons retained from the WIP sister branch (now retired)

These knowledge bits cost real iteration to discover; capturing them here so a fresh branch doesn't re-pay the lesson cost:

| Lesson | Concrete artifact |
|---|---|
| `cabal install`'s sdist phase silently drops directories not in `extra-source-files`, even when `cabal build` from a working tree was happy. | `sky-compiler.cabal` listing of `runtime-rust/sky-stdlib-overrides/Sky/Core/*.sky` (mirror of the existing `sky-stdlib/...` pattern — same Issue #58 class as the original `runtime-go/rt/jobs/` drop). |
| TH `qAddDependentFile` doesn't fire for files added under an empty directory after the first TH run — cabal's mtime tracking misses them. | `embedDirRecursiveIfExists` in `src/Sky/Build/EmbedDirTH.hs` + the `re-embed marker:` bump-line convention in `EmbeddedRuntime.hs` to force a re-splice when on-disk content changes. |
| Sky's `any` type variable is HM-pure at the type-checker level (each occurrence gets a fresh fresh-flex var, see `src/Sky/Type/Instantiate.hs:33-66`). But usage patterns that store heterogeneous values in a single record field rely on `interface{}` runtime polymorphism — codegen targets without that escape hatch must reject. | The `rejectAnyInRecordFields` pass in `Sky.Generate.Rust.Project` runs before `buildProgram`, walks every record alias in the module's lowered AST, emits the diagnostic on offence. |
| Rust's `SkyTask<E, A> = Pin<Box<dyn Future<Output = SkyResult<E, A>> + Send + 'static>>` is one-shot (not `Clone`). Any retry-loop kernel needs a task **producer** (`() -> Task e a`) not a task. | The v0.15.44 override's `retryWith : RetryPolicy e -> (() -> Task e a) -> Task e a` shape. Upstream sync work needs to confirm whether v0.15.51's `retryWith` is now thunk-shaped or still task-shaped; if still task-shaped, the codegen needs to wrap the Task arg in a thunk at the `retryWith` call site, OR we need to lift the constraint via a `Clone`-bearing SkyTask redesign. |
| Upstream PRs are outward-facing — opening a follow-up PR to fix comments on a freshly-merged PR is bad collaboration optics. | Branch + diff is staged on `origin` then handed to the user; user opens upstream PR after manual review. (Encoded in the `upstream-pr-autonomy` memory.) |

### Standing Rust codegen gaps — ✅ closed by sub-D step 4 (`fdb8393d`)

The generic-ADT lowering bugs below are fixed. Kept here for grep:

| Bug (now fixed) | Symptom | Fix |
|---|---|---|
| ~~`REnumDef` carries no generic-params slot~~ | `pub enum X { ... }` for `type X a = ...` | generics slot from `_u_vars` → `pub enum X<a> { ... }` |
| ~~Type var undeclared in the enum body~~ | `cannot find type e` (E0412/E0091) | the `<a>` declaration now scopes the body var |
| ~~Legacy `pub type X = String` fires alongside the enum~~ | `E0428: name defined multiple times` | `collectUndefinedTypes` matches on the base name, so `X<a>` isn't seen as undefined |
| ~~Ctor use-site resolves through the legacy alias~~ | `String::RetryAlways` (E0599) | falls out from removing the colliding alias |
| ~~Parametric record alias ignores its type vars~~ | `RetryPolicy e` struct/ctor/fns missing `<e>` | `aliasToRustTypeDef` + `synCtor` + `TAlias` in `typeToRustString`/`collectTVars`/`hasTypeVars` |

Type vars are kept verbatim (lowercase `e`) — Rust accepts lowercase generic
params (a style lint, not an error), matching the existing function emission.
The cosmetic `e`→`E` rename was deliberately *not* done (no correctness gain).

### New scope from v0.15.45-51 — audited 2026-06-02

Upstream shipped a substantial stdlib expansion (each module exists in
`sky-stdlib/`). **Audit method:** grep each module's `Ffi.kernel "X"` deps,
cross-reference `kernelToRust` + `runtime-rust`, then build a user on
`target=rust`. **Key finding:** the codegen already emits a snake_case name for
any unmapped kernel (`Csv_parse` → `csv_parse`), so Sky→Rust *compiles*; the gap
is purely the **runtime implementation + Cargo deps** (a clean `E0425: cannot
find function` at cargo-link until implemented). No codegen changes needed.

| Surface | Status on `target=rust` | Shape / sizing |
|---|---|---|
| **Symmetric crypto** (AES-GCM / ChaCha20) | ✅ shipped | `crypto.rs` AEAD kernels + aes-gcm/chacha20poly1305/pbkdf2 |
| **`Sky.Core.Bytes`** | ✅ shipped | Latin-1 byte convention in the Encoding kernels |
| **Task.retryWith** | ✅ shipped (run-once) | `task_retry_with` + policy-arg drop |
| **v0.15.51 RetryPolicy builders** | ✅ shipped | constructor error-pins; exercised by standard-libs |
| **Std.Compression** (gzip/zstd) | ✅ **shipped** | `compression.rs`, flate2 + zstd, over the bytes convention |
| **Std.Csv** | ✅ **shipped** | `csv.rs` + the **kernel-record-return bridge**: the `Csv` record maps to a runtime `CsvDoc` via runtimeOpaqueTypes (`StdCsvCsv` is a `pub use` alias), so kernels return/take it directly. Also fixed a clone-prelude bug for case-pattern vars. `csv` crate. |
| **Sky.Core.Uuid** (String surface) | ✅ **shipped** | `uuid_kernel.rs` (v4/v7/parse), conditionally included (usesUuid) so it doesn't clash with FFI-uuid projects. `Sky.Core.Pure`'s Task-typed `uuidV*Kernel` remains unsupported (dual-typed kernel). |
| **Std.Cache** (LRU + TTL) | ⛔ blocked by the no-`any` principle | `type Cache k v` is polymorphic over the value; `Cache_put : Int -> k -> v -> Task Error ()` stores arbitrary `v` in a global registry → requires `Box<dyn Any>` type erasure, which the Rust backend forbids. Feasible only via per-`(k,v)` monomorphized cache instances (major redesign), not the global-registry shape. |
| **Std.Config** (TOML/YAML/JSON decoders) | ⏳ missing runtime | 16 kernels (decoders + combinators). toml/serde_yaml/serde_json. ⚠️ name the module `config_decode.rs` (the DB `config.rs` clashes). Polymorphic decoder values may hit the same record/`any` issues as Csv/Cache. |
| **Std.Email** (Resend/SES/SMTP) | ⏳ missing runtime | 1 kernel (`email_send`) but provider-shaped — network + integration tests. sub-project-sized |
| **WebSocket SERVER** (v0.15.46) | ✅ **shipped (non-capturing handlers)** — Sub-D.2 | 5 `ServerWebSocket_*` kernels on axum `ws`: upgrade via tokio task-local, per-peer mpsc registry, `ws_loop`, send/broadcast/close, production origin gate. Cfg callbacks are fn pointers, so handlers can't capture app state yet (chat-style broadcast-to-stored-list needs `Arc<dyn Fn>` erasure — follow-up). Echo verified end-to-end (`tests/rust-codegen/websocket-test.sh`). |
| **WebSocket CLIENT** (v0.15.46) | ⏳ pending | `Sky.Core.WebSocket` — Sub-tier (onMessage subscriptions) ties into Sky.Live's Sub system, not yet on Rust. |
| **HTTP types** (typed `HttpResponse`) | ⏳ unblocked (Sub-D.1 shipped) | the Sky.Http.Server runtime now exists on Rust; typed-response surface can build on `ServerResponse` |
| **v0.15.47 kernel registry + narrowers / v0.15.48 naming** | ⏳ needs investigation | per-kernel; not surfaced by standard-libs (131/131 already green) |

**Status (2026-06-02):** **Compression, Csv, and Sky.Core.Uuid (String) are
shipped.** The Csv work added a reusable **kernel-record-return bridge**
(runtimeOpaqueTypes mapping for record aliases) that also unblocks future
record-returning kernels (e.g. parts of Config). **Cache** is blocked by the
no-`any` principle (polymorphic value storage). Remaining: **Std.Config**
(decoders; reuse the record bridge + dodge the `config.rs` name clash),
**Std.Email** (provider/network), and the Sub-D.1-gated **WebSocket** + **HTTP
types**.

### Short-term (orthogonal to sub-D)

- ~~**Sub-A.13**~~ — ✅ shipped. Empty-literal type resolution for `[]` /
  `Nothing` / `Err`-`Ok`. Done via **call-site parameter-type propagation**
  (in `emitDefaultCall`), not the region-type lookup the original plan assumed
  — `Solve._stRegions` turned out to carry unresolved type vars at exactly
  these nodes (user empties also get degenerate `(1,1)` regions), so the plan's
  premise was false. Per empty-collection call arg: concrete param → turbofish;
  var shared with a non-closure sibling → bare (Rust infers); unpinned var on a
  known-generic sig → `i64` filler (safe, the collection is empty); inferred/
  unknown sig → bare. This resolves the prior Sub-A.12 "F3" deferral (the naive
  monomorphic default regressed function-call args like `db_query []`). The 4
  empty-literal `E0283` errors in `examples/00-standard-libs` are fixed with
  zero regressions across the 22 `examples/rust/*` + 3 `tests/rust-codegen/`
  repros. NOTE: standard-libs still can't reach 120/120 on `target=rust` — it's
  now blocked by the **sub-D** generic-ADT codegen bugs + missing crypto/retry
  kernels (~46 errors), not by empty-literals.
  Plan (premise superseded): `runtime-rust/superpowers/plans/2026-05-31-sub-A.13-type-default-propagation.md`.
- **`Db.withTransaction` single-connection variant** — runtime helper that
  takes a reserved `PoolConnection` so rollback isolation is guaranteed
  without requiring user-side pool configuration.
- **`basename` → Cargo `[package].name` for git deps where the URL probe
  fails on virtual workspaces** — the discovery helper currently bails when
  the root `Cargo.toml` has no `[package]` section (workspace-only roots).
  Walk the first workspace member to recover.
- **Non-byte slices/arrays** in FFI — `&[String]`, `[f64; 3]` still drop;
  per-element coercion would extend Alt-1 v2 to wider crate surface.

### Medium-term
- **Sub-D.1 — Sky.Http.Server on Rust runtime (axum/hyper)** — ✅ **shipped**
  (`0161a5ca` foundation, `67771f8d` serve loop). Request/Response/Route/Cookie
  reuse the Csv kernel-record-return bridge; handlers are boxed Sky closures
  (`server_get<E,H>` erases the project error type into a non-generic
  `ServerRoute`); `server_listen` builds an axum `Router` and serves via tokio.
  Path params (`RawPathParams`), query (form-decoded), headers, cookies, and
  body all adapted into `ServerRequest`; static dirs via tower-http `ServeDir`;
  panic→500 via tower-http `CatchPanicLayer`. Deps (axum 0.7 + tower-http +
  tokio `net`) and `main` block-on are gated on `usesHttpServer`. The crux risk
  (closure `Send+Sync+'static` for axum) was validated at step 1.
  Verified end-to-end (`tests/rust-codegen/http-server-test.sh`): GET +
  path-param, POST body, static, 404, content-type. Spec:
  `runtime-rust/superpowers/specs/2026-06-02-sub-D1-http-server-design.md`.
  Unblocks Sub-E + the WebSocket + HTTP-types items.
- **Sub-E — Sky.Live** session stores + SSE on Rust runtime (sub-D.1 dependency).
- **Sub-F — Sky.Tui** terminal backend on Rust runtime.
- **Enum-argument constructors** for FFI — many crate fns take a crate enum
  (e.g. `base32::encode(Alphabet, …)`); expose variants so Sky can pass them.
- **`&mut [u8]` fill params** — in/out byte buffers (e.g. `fastrand::fill`)
  are still dropped; add write-back coercion.

### Long-term
- **WASM target** — cross-compile runtime and generated code to
  `wasm32-unknown-unknown` (also needs sub-C onwards to be portable).
- **`sky watch` for Rust** — rebuild on `runtime-rust/src/` changes.
- **Separate module files** — emit `pub mod <name>;` declarations instead of
  flattening all Sky modules into `main.rs`.

### Recently shipped (this branch, since the v0.15.27 upstream sync)
- ✅ **Sub-A.9 → A.12** — headline-gate reduction 232 → 4 cargo errors on
  `examples/00-standard-libs` (-98% from baseline).
- ✅ **Sub-B** — full `Std.Db` runtime (12 kernels + `examples/rust/17-db-todo-cli`).
- ✅ **Sub-B.1** — Std.Db cross-backend (sqlite + mysql + postgres) via per-driver
  helpers in generated `config.rs`. Driver-aware `db_last_insert_id` +
  `db_format_sql` rewrite SQL placeholders for postgres.
- ✅ **Sub-C** — `Std.Auth` runtime: 9 kernels (6 pure crypto + 3 Task DB),
  `examples/rust/18-auth-signup`. bcrypt + jsonwebtoken; sqlx-backed register /
  login / setRole.
- ✅ **Sub-C.1** — `Std.Auth` users-table schema portable across sqlite + mysql +
  postgres via `db_auto_id_column()` in generated `config.rs`.
- ✅ **`sky install` git deps** — `regenMissingRustBindings` now resolves
  `RustGitDep` via the inspector's new `--git URL [--rev|--branch|--tag]`
  selectors. `sky add <git-url> --target rust` works end-to-end.
- ✅ **Git-dep package-name discovery** — `sky add <git-url> --target rust` clones
  the source, parses `[package].name` from `Cargo.toml`, and uses the discovered
  name for the sky.toml entry + artifact filenames. Falls back to the URL
  basename heuristic on failure.

### Upstream contributions during this arc

- ✅ **`anzellai/sky` PR #119** (merged at v0.15.50) — `ShouldRetry e` ADT replaces `RetryPolicy.shouldRetry : any`. The Rust-target Sky.Core.Task override that surfaced this is no longer needed; upstream's stdlib ships exactly the ADT shape the override declared. Go-side win: `callShouldRetry` becomes a constructor-tag switch instead of a reflect-backed callable detection; the `Task_retryAlways` kernel registry entry deletes (retryAlways becomes pure Sky).
- ⏳ **`anzellai/sky` PR #120** (open) — comment trim follow-up to #119; Sky stdlib + Go runtime references stop speculating about non-Go targets, refocused on the v0.15.x type-directed-lowering refactor's "drop `any` wherever a real ADT or parametric type expresses the same intent" framing.
