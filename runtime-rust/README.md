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

All runtime logic lives in `sky_runtime/`; `Builder.hs` emits thin wrappers that
instantiate `E = SkyError` for the generated project. No inline Rust
implementation strings in the Haskell codegen.

---

## Safety invariant — zero `Any`, zero `unsafe`

The Rust backend uses Rust's static type system end-to-end. Sky's `any` is
**never** lowered to `Box<dyn Any>` — that would re-implement Go's `interface{}`,
the exact bug class this backend exists to avoid. There is no `unsafe`, no
`transmute`, no raw pointers; the Sky→Rust FFI path is safe Rust-crate calls.

Heterogeneity is handled with generics + ADTs + concrete runtime bridges, not
erasure:

| Need | Technique (not `Any`) |
|---|---|
| HTTP/WS handlers of project error `E` | erase `E` by awaiting the task + mapping `Err -> 500` (`server_get<E,H>`); handlers stay `Send + Sync + 'static` |
| `Cmd msg` / `Sub msg` payloads | generic over concrete `M`; the intermediate `a` is erased *inside* a boxed `Future<Output = M>` |
| Records the runtime must name (Request/Response/Csv/LiveReq/…) | `runtimeOpaqueTypes` bridge to concrete structs/enums (`pub use … as …`) |
| Polymorphic value storage (`Std.Cache k v`) | refused — would need `Box<dyn Any>`; flagged as blocked, not erased |

Audit (must stay empty; a hit is a design-level regression, never papered over):

```bash
grep -rEn "dyn Any|std::any|downcast|type_id" runtime-rust/src/ src/Sky/Generate/Rust/ src/Sky/Build/Rust/
grep -rEn "\bunsafe\b|transmute|from_raw|into_raw|static mut|\*const |\*mut " runtime-rust/src/
```

---

## API surface vs the Go backend

Go is the reference (full surface). Rust coverage by confidence:

**✅ Covered & verified** (standard-libs 131/131 + the 32 `examples/rust/*` + the
HTTP/WS/Cli regression tests):

- Pure stdlib: Basics, String, List, Dict, Set, Maybe, Result, Char, Math, Path,
  Regex, Bytes (Latin-1), Encoding, Json (Encode/Decode/Pipeline), Jwt, Decimal,
  Money.
- Effects: Task, Time, Random, File, System, Crypto, Compression, Csv, Uuid, Log,
  Db (sqlite/mysql/postgres), Auth, Trace, Email (Resend/SendGrid/SES).
- Network: Sky.Core.Http (client), Sky.Http.Server, Sky.Core.WebSocket (client),
  Sky.Http.Server.WebSocket, Sky.Http.Server.Stream + Sky.Core.Http.Stream (SSE /
  chunked, both relay and Sub-tier).
- `Sky.Http.Middleware` (cors/logging/basicAuth/rateLimit) + `Sky.Http.RateLimit`.
- `Std.Config` (TOML/YAML/JSON decoders over a shared serde_json::Value).
- Runtime/TEA: Cmd, Sub, Sky.Cli.
- **Sky.Live (P0–P6)** — see the dedicated section below.
- Ffi (Rust-crate auto-FFI).

**⏳ Missing — bounded & additive** (no architectural blocker):

- PubSub (`Cmd.publish` / `Sub.subscribeTopic`) — couples to Sky.Live's broker.
- `Process.run`, `Io` beyond Log — small, not example-verified on rust.

**✅ `Std.Ui` (HTML render path) — byte-identical to Go.** The typed no-CSS
layout DSL (`layout`/`row`/`column`/`el`, `Background`/`Border`/`Font`/`Region`/
`Input` sub-modules, nearby overlays, aspect-ratio, grid) renders byte-for-byte
against Go's `renderVNode`, verified by the `scripts/ui-parity.sh` render-diff
harness (corpus `tests/ui-parity/` T0–T5, 6/6). The two integration apps
`26-ui-showcase` (every primitive) and `19-skyforum` (forms + `onSubmit`) build
clean on `--target rust`. See "Std.Ui parity" below.

**🟡 Deferred — large arcs:** Sky.Tui, Sky.Webview (the `Std.Ui` *render* path is
done; these need the terminal/native-window backends + the layout engine for
non-HTML targets).

**⛔ Blocked by no-`any`:** `Std.Cache` (polymorphic value storage).

**N/A** (compiler CLI, not an app-runtime API): `Doc`, `Context`.

---

## Sky.Live on Rust (P0–P6 shipped)

TEA-over-HTTP+SSE on an axum router, no `any`/static dispatch. Same
`init`/`update`/`view`/`subscriptions` shape as the Go backend; the Go browser
client (`live/client.js`) and wire/patch schema are reused verbatim.

| Phase | What it ships | Gate |
|---|---|---|
| **P0** static render | `Html`/`Attribute`/`Event` ADTs bridge to runtime-generic `sky_runtime::Html<M>` (the `{M}` generic-alias codegen case); `assign_sky_ids` + `render_html` + page wrap | `27-live-static` |
| **P1** live TEA | `Live.app` axum router: per-session TEA driver, `/_sky/sse` (hello + 15s heartbeat), `POST /_sky/event`, view-over-view diff → patch frames | `28-live-counter` |
| **P2** typed forms | `Ev.onSubmit Ctor` → `Event::OnForm` + `decode_form::<T>`; the form-target record gains `#[derive(Deserialize)]`; malformed form → no Msg, no panic | `29-live-form` |
| **P3** URL routing | `routes`/`notFound`; `Live.route` → `Route<Page>`; the `Live.app` peephole detects the model's `page` field + emits a codegen page-setter (reflection-equivalent of Go's `RecordUpdate`) | `30-live-routing` |
| **P4** typed request | `init req` receives `sky_runtime::LiveReq { path, query, method; params, headers, cookies }`; a Rust-only pre-pass types the init param (no shared-type change → Go-safe) | `31-live-req` |
| **P5** session stores | `SessionStore` async trait + `MemoryStore` (idle-TTL) + `SqliteStore` (mem-cache + serde-JSON checkpoint); cookie reuse + write-through; Cold-hit hydration after restart; model serde is a compile-time requirement | `32-live-sessions` |
| **P6** faithful diff | keyed sky-id (`:{key}` from `sky-key` / form `name`, sanitised), event-handler diff (`sky-<event>` + `data-sky-hid`), mixed-child text → parent html-replace; matches Go `diffNodes` exactly | `live::diff` + `live::html` tests |
| **P5 follow-on** stores | `PostgresStore` (cfg `db`, PgPool) + `RedisStore` (cfg `redis_store`, native TTL) on the same trait; `choose_store` selects `[live] store` with memory fallback | runtime tests (pg/redis gated on `SKY_TEST_*_URL`) |

**Ahead:** firestore backend (same trait), Cmd/Sub depth, req query-string
parsing, lambda-`init`, the store's pub/sub `Broker`.

---

## Std.Ui parity (byte-identical render)

`Std.Ui` is pure Sky source that builds a `Std.Html` ADT, serialised by
`html.rs` `render_html` — so parity is a **codegen-lowering + serializer**
problem, not a renderer port. Verified by `scripts/ui-parity.sh`: each corpus
fixture runs `main = Io.writeStdout (Html.toString (Ui.layout [] view))` and the
stdout is byte-diffed Go-vs-Rust (Go is the golden).

| Tier | Covers | Status |
|---|---|---|
| T0 text | `layout` + `text` | ✅ byte-identical |
| T1 layout | `row`/`column`/`spacing`/`padding`/`align` | ✅ |
| T2 styling | `Background`/`Border`/`Font` | ✅ |
| T3 sized | `button`/`link`/`image` (static) | ✅ |
| T4 advanced | nearby overlays / aspect-ratio / grid | ✅ |
| T5 semantic | `Region` tag + aria mapping | ✅ |

The load-bearing fixes (all Rust-target only, Go untouched):

- **`any`-carrier resolution** — Std.Ui's wildcard `any` slots (and a user
  `view : Model -> any`) resolve to the concrete `Html<msg>` / `Attribute<msg>`
  carrier; no `dyn Any`.
- **Whole-program DCE** — dep modules prune to the reachable-from-`main` set
  (mirrors Go's `generateDeclsForDep`), so a one-line render emits 60 Std.Ui fns
  not 205, and unreachable-helper bugs don't block the build.
- **Injective fn-name mangling** — `Std.Ui.borderRounded` vs
  `Std.Ui.Border.rounded` no longer collide under `toSnakeCase`.
- **Serializer alignment** — `render_html` sorts attrs, renders `BoolAttr` as
  `k="true"`, and self-closes void elements with ` />`, matching Go
  `renderVNode`.
- **`onSubmit` form-event peephole** — `Ui.onSubmit DoSignIn` inlines to a typed
  `decode_form::<T>` dispatch (Go's static-render of events isn't the path).

Event *dispatch* (onPress/onSubmit) and the style-injection features
(pseudo-class / media-query / transition / animation) render through Sky.Live's
VNode path, covered by the integration apps `26-ui-showcase` + `19-skyforum`
rather than the static corpus.

---

## Modification boundaries

Only modify these when working on the Rust backend:

| Directory / file | Purpose |
|---|---|
| `runtime-rust/` | runtime crate (`sky_runtime` modules, tests) |
| `src/Sky/Generate/Rust/Builder.hs` | Rust codegen — expression / type / pattern lowering |
| `src/Sky/Generate/Rust/Project.hs` | project orchestration — `main.rs` + `Cargo.toml`, copies runtime + FFI bindings |
| `src/Sky/Build/Rust/Ffi.hs` | Rust FFI — inspector, `.skyi` / `.kernel.json` / `_bindings.rs`, coercion |
| `src/Sky/Sky/Toml/Rust.hs` | Rust dependency-spec parsing |
| `tools/sky-ffi-inspect-rs/` | Rust crate inspector (rustdoc JSON) |

Shared compiler files keep only a minimal `case Toml._target of { TargetRust ->
…; TargetGo -> … }` dispatch seam. Dependencies are one-way (shared → Rust-only),
so the Go path stays byte-identical and upstream merges stay small. See
`docs/runtime-rust/syncing-upstream.md`.

---

## Cross-backend rules (load-bearing)

Go is the **production backend**; Rust is second-tier.

1. **Go FFI artifacts stay at the root of `.skycache/ffi/`** —
   `<slug>.{kernel.json,skyi}`.
2. **Each non-Go backend gets its own subdir** — Rust at `.skycache/ffi/rust/`.
3. **`loadAndSeedFfiRegistry` reads target-appropriate paths** — go = root,
   rust = `rust/` subdir.
4. **Never touch Go-generated files** — `runtime-go/`, root `.skycache/ffi/*`,
   `src/Sky/Generate/Go/`.
5. **Never change shared compiler code in a way that could break Go** — new Rust
   functionality goes behind explicit `TargetRust ->` branches.
6. **`sky add` routing:** URL → `[rust.dependencies]` as `{ git = … }`; bare name
   → crates.io via `cargo fetch`.

---

## sky.toml Rust fields

```toml
[project]
target = "rust"                   # default "go"; overridden by --target

["rust.dependencies"]
uuid  = "1.16.0"                  # crates.io — version string
serde = { version = "1", features = ["derive"] }
mylib = { git = "https://github.com/org/mylib", rev = "abc123" }

[rust]
sqlx_tls = "rustls"              # default; alt: "native-tls"

[live]                            # Sky.Live apps
store     = "memory"             # memory | sqlite | postgres | redis
storePath = "sessions.db"        # file path / postgres:// URL / redis:// URL
```

Rust FFI is fully automatic (`rustdoc --output-format json`) — no hand-written
glue, even for proc-macro/derive crates. There is no `[rust.shims]` section.

The codegen wires Cargo features from `[live] store`: `sqlite`/`postgres` enable
`db` (sqlx, both drivers — store.rs compiles `SqliteStore` + `PostgresStore`
together); `redis` enables a `redis_store` feature + the redis crate; `memory`
pulls neither. A non-live `Std.Db` app keeps its single driver.

---

## Verification state (branch `feat/runtime-rust`)

### `examples/rust/` — 32/32 build + run from a wiped slate

| Example | Surface | What it shows |
|---|---|---|
| 01–16 | leaf FFI crates | rand, num_cpus, chrono, uuid, roman, lipsum, deunicode, semver, bytesize, titlecase, fastrand, ulid, petname, crc32fast, uuid-bytes, hex — free fns, static/instance methods, Display/FromStr, Option/Result, byte ⇄ `List Int`, generic-bound monomorphisation (Alt-1) |
| 17-db-todo-cli | `Std.Db` | full CRUD via sqlx; sqlite + mysql + postgres |
| 18-auth-signup | `Std.Auth` | bcrypt + jsonwebtoken + sqlx; backend-portable schema |
| 19-config | `Std.Config` | TOML/YAML/JSON record decode + `loadFromFile` |
| 20-email | `Std.Email` | `defaultMessage` + `with*` builders; all four providers under dry-run |
| 21-sse-server | `Sky.Http.Server.Stream` | `stream`/`emit`/`finish` — progressive SSE, not buffered |
| 22-sse-relay | `Sky.Core.Http.Stream` | `open` + `forEachChunk` re-emitting chunk-for-chunk in a plain handler |
| 23-char | `Sky.Core.Char` | all 8 Char kernels + `toCode`/`fromCode` (U+FFFD on out-of-range) |
| 24-http-api | `Sky.Http.Server` | `Server.api` route + `Handler` alias + `Mw.withLogging` |
| 25-retry | `Sky.Core.Task` | `retryWith` + `RetryPolicy` (run-once on Rust — see limitations) |
| 26-stream-cli | `Sky.Core.Http.Stream` Sub-tier | `chunks` → `ChunkEvent` Msgs into a `Cli.program` update loop |
| 27-live-static | Sky.Live P0 | `Live.renderStatic` byte-correct full HTML |
| 28-live-counter | Sky.Live P1 | TEA-over-SSE; span increments live |
| 29-live-form | Sky.Live P2 | typed form submit |
| 30-live-routing | Sky.Live P3 | URL routing → injected `model.page` |
| 31-live-req | Sky.Live P4 | typed `LiveReq` to `init` |
| 32-live-sessions | Sky.Live P5 | `[live] store="sqlite"` — cookie reuse + restart survival |

P6 (faithful diff) and the postgres/redis stores are covered by runtime unit
tests, not separate examples; generated postgres + redis live apps are
cargo-build-verified.

### `examples/00-standard-libs`

- `target=go`: 131/131 assertions. `target=rust`: **131/131 — full parity.**

### `Sky.Http.Server` / `Sky.Live` regression tests

- `tests/rust-codegen/http-server-test.sh` asserts every route over real HTTP
  (GET, path param → JSON, POST body, static, 404, content-type).
- `cargo test --features "live db redis_store"` — 154 runtime tests incl. diff,
  dispatch, form, store (memory/sqlite + env-gated pg/redis restart-survival).

### Rust-vs-Go perf gate (`scripts/rust-perf.sh`)

The S1 perf harness benchmarks both backends of any example across all three
app shapes — **cli**, **server**, **live** — on cold-start, throughput (`ab`),
peak RSS under load, and binary size, gating the Rust/Go ratio against the
committed envelope in `scripts/rust-perf.thresholds`. It discovers the bound
port from the spawned process (no env dictation), `timeout`-bounds every probe,
and tolerates measurement noise (re-roll on fail; SKIP a missing reference).

```bash
scripts/rust-perf.sh 01-hello-world        # gate one example (shape auto-detected)
scripts/rust-perf.sh --baseline            # re-derive thresholds over the triplet
```

Representative envelope (Rust as a fraction of Go; lower is better except
throughput): binary size **~1–2%**, RSS **~15–19%**, CLI cold-start **~16%**.
The Sky.Live entry binds a port and serves on Rust as of codegen fix
`b18d8a8a`. The `live.rss` envelope + the SSE patch-latency leg are pending a
re-baseline on a quiet (non-swapping) host.

### Top-level `examples/[0-9]*` on `--target rust`

Conquest of the main example set (tracked in
`docs/rust-example-conquest-registry.md`). Build-level via `scripts/rust-sweep.sh`.

**22 in-scope build:** `00, 01, 04, 07, 09, 10, 12, 14, 15, 16, 17, 18, 19, 20,
26, 28, 30, 32, 33, 35, simple, test_pkg` — up from a 6-example baseline.
`19-skyforum` and `26-ui-showcase` joined via the Std.Ui parity work. Driven by
general, regression-gated codegen wins: TEA-Msg monomorphisation, multi-module
serde, body-driven param inference, `Arc<dyn Fn>` stored callbacks, cross-module
ADT-name resolution, whole-program DCE (matching Go's dep-decl prune), injective
fn-name mangling, the Std.Ui `any`-carrier resolution, `solveArgType` list/call
type resolution, `indexedMap` index-param typing, and the `onSubmit` form-event
peephole.

**Out of scope (per user):** Go-package→Rust-native FFI examples `03, 05, 08, 13`
(import gorilla/mux, stripe-go, google/uuid, godotenv) are not a goal. The
composite multi-app examples `37, 38` surface non-Std.Ui feature gaps (Live
pub/sub kernels — `Cmd.publish`/`Sub.subscribeTopic` — not yet emitted, plus
anon-struct field-method access) and remain out of scope pending that work.

---

## Module structure

```
runtime-rust/src/sky_runtime/
├── config.rs         GENERATED per sky.toml driver — DbPool/DbRow/SKY_DB_URL + driver helpers
├── core.rs           SkyResult/SkyMaybe/SkyTask, list/string/float helpers, byte FFI coercion
├── task.rs           succeed/map/and_then/on_error/fail/perform/sequence/run/parallel
├── log.rs · system.rs · time.rs · random.rs · file.rs
├── crypto.rs         random_bytes/token + sha/hmac/RSA/AEAD (aes-gcm, chacha20, pbkdf2)
├── jwt.rs · json.rs · encoding.rs · regex_kernel.rs
├── decimal.rs · money.rs · math.rs · dict.rs · string.rs · basics.rs · list.rs
├── db.rs             Std.Db CRUD over sqlx (sqlite/mysql/postgres)
├── auth.rs           Std.Auth — bcrypt + jsonwebtoken + sqlx
├── compression.rs · csv.rs · uuid_kernel.rs · config_decode.rs · email.rs · trace.rs
├── ffi_polyfills.rs  Ffi.callPure/callTask/toAny polyfills
├── live/             Sky.Live (feature `live`)
│   ├── html.rs       Html/Attribute/Event<M> + assign_sky_ids (keyed) + render_html
│   ├── diff.rs       Patch (Go wire schema) + faithful diff (keyed sky-id, events, mixed-text)
│   ├── dispatch.rs   HandlerIndex<M> + resolve(sky-id, event, args) / resolve_form
│   ├── form.rs       decode_form::<T> / decode_form_or_warn
│   ├── route.rs      Route<Page> + match_routes / match_params (Go matchRoute parity)
│   ├── req.rs        LiveReq + builder (canonical headers, cookie parse)
│   ├── store.rs      SessionStore trait + Memory / Sqlite / Postgres / Redis + choose_store
│   ├── sse.rs        SsePatch / channel / frame (text/event-stream)
│   ├── client.js     browser client, ported verbatim from Go (include_str!'d)
│   └── mod.rs        live_render_static + live_app / live_app_routed + per-session driver
└── mod.rs            re-exports
```

This mod list is the source of truth for standalone-crate testing; `Project.hs`
writes a parallel `mod.rs` for the generated project (with `cfg(feature)` gating).

---

## Error type

All runtime functions are generic over `E`; `Builder.hs` emits thin wrappers that
fix `E = SkyError`:

```rust
// sky_runtime/task.rs (generic):
pub fn task_map<E, A, B>(f: impl FnOnce(A) -> B + Send + 'static, t: SkyTask<E, A>) -> SkyTask<E, B>
// generated main.rs (wrapper):
pub fn task_map<A, B>(f: impl FnOnce(A) -> B + Send + 'static, t: SkyTask<A>) -> SkyTask<B> {
    sky_runtime::task::task_map::<SkyError, _, _>(f, t)
}
```

---

## Rust FFI

`sky add <crate> --target rust` invokes `sky-ffi-inspect-rs`, which runs
`cargo +nightly rustdoc --output-format json` (so derive/proc-macro impls are
visible), maps Rust types → Sky types (`Vec→List`, `Option→Maybe`, `HashMap→Dict`,
`Result→Result E A`), and writes `.skycache/ffi/rust/<slug>.{kernel.json,skyi,_bindings.rs}`.

- **Opaque types** are emitted fully-qualified by public re-export path
  (`chrono::NaiveDate`), so wrappers need only one root `use <crate>::*;`.
- **Nameability filter:** generic fns, lifetime-parameterised types, borrowed
  results, non-byte slices/arrays, `unsafe fn`, and private/std types are dropped
  so `_bindings.rs` always compiles. Byte sequences (`&[u8]`, `[u8; N]`, …) are
  kept and bridged to `List Int`.
- **Display/FromStr bridge:** opaque types implementing them get synthetic
  `to_string`/`from_string` bindings.
- **Inspector resolution:** `$SKY_FFI_INSPECTOR_RS` → `./bin/sky-ffi-inspect-rs`
  (ancestors) → TH-embedded binary at `~/.cache/sky/tools/`.

Method bindings disambiguate by receiver: `Utc::now` → `now_from_utc`.

### Reach (what auto-FFI can/can't cover)

The boundary is type-theoretic, not a maturity gap: only `rustc` resolves Rust's
generics (monomorphised — no callable symbol until concrete), traits (open), and
lifetimes. So **leaf/data crates** (hashing, codecs, parsing, math, time, regex,
many client SDKs) auto-bind well; **frameworks** (axum, bevy, diesel, tokio) are
generic+trait+`Stream` at the core and auto-bind almost nothing usable.

The Sky-Rust strategy: **automatic FFI over the leaf universe + Sky-native
modules over frameworks** (the `Sky.Live` / `Sky.Http.Server` model — built on
axum/hyper internally, exposing a Sky-idiomatic surface). "Verbatim FFI to any
framework" is a deliberate non-goal. Measure constructable surface per crate with
the `/ffi-audit` skill (`~/.claude/skills/ffi-audit/ffi_audit.py`).

Shipped widenings: **Alt-1** monomorphises generic fns whose bound maps to a Sky
type (`AsRef<[u8]>`/`Into<Vec<u8>>` → `List Int`; `AsRef<str>`/`Display` →
`String`); **Alt-1 v2** resolves recursive `AsRef`/`Into`/`IntoIterator` inner
types + lifts the non-byte slice/array drop when the element is Sky-coercible
(soundness-gated: primitive-numeric `Into`/`From` resolve at identity only).

---

## FFI codegen type-coercion rules

`Sky.Build.Rust.Ffi` (`emitRustFnSimple`).

**Param type (`resolveRustType`).** Sky-mapped for known types; raw qualified type
for opaque:

| Sky param type | Wrapper param type |
|---|---|
| `String` | `String` (borrowed `&argN` internally) |
| `Int` / `Float` / `Bool` / `Bytes` | `i64` / `f64` / `bool` / `Vec<u8>` |
| `List a` / `Maybe a` / `Dict String v` | `Vec<…>` / `SkyMaybe<…>` / `HashMap<…>` |
| opaque | fully-qualified raw type |

**Param coercion (`argCall`).**

| Wrapper type | Raw param | Emitted arg |
|---|---|---|
| `String` | `&str` | `&argN` |
| `i64`/`f64` | narrower numeric | `argN as <raw>` |
| `Vec<i64>` | `&[u8]` / `Vec<u8>` | `&to_u8_vec(&argN)` / `to_u8_vec(&argN)` |
| `Vec<i64>` | `[u8; N]` / `&[u8; N]` | prelude `let bN = to_u8_array::<_,N>(…)?;` then `bN`/`&bN` |
| anything | same/absent | `argN` |

`[u8; N]` length mismatch returns `Err`, never panics.

**Return coercion (`translateRustRet`)** — driven by the raw Rust return:

| Raw return | Wrapper return | Lift |
|---|---|---|
| `&[u8]` / `Vec<u8>` / `[u8; N]` | `Vec<i64>` | `from_u8_slice(…)` |
| `Option<T>` | `SkyMaybe<T'>` | `Some→Just`, `None→Nothing` |
| `Vec<T>` | `Vec<T'>` | per-element map only if `T` needs coercion |
| `iN`/`uN` / `f32`/`f64` | `i64` / `f64` | `as i64` / `as f64` |
| `&str`/`&String` | `String` | `.to_string()` |
| opaque `T` | `T` (qualified) | identity |

Effect drives the body: `pure` → `ok_res(lift(call))`; `fallible` → `match` on
`Result`; `effectful` → the same inside `Box::pin(async move { … })`.

---

## CLI usage

```bash
sky build src/Main.sky --target rust
sky run   src/Main.sky --target rust
sky check src/Main.sky --target rust    # full emit + cargo build
sky test  tests/MyTest.sky --target rust
sky add uuid --features="v4" --target rust   # fully automatic, no shims
sky install                                  # regen FFI after rm -rf .skycache
```

---

## Fast dev iteration (MANDATORY for this branch)

Minutes-long compiler rebuilds + example sweeps kill the dev cycle. These are
required for all dev-loop work on `feat/runtime-rust` (release/CI still use the
default `-O1` + a real `cabal install`):

**Haskell compiler side**
- **`cabal.project.local` with `optimization: 0` + `profiling: False`** (gitignored,
  local-only). `-O0` cut a full 89-module rebuild from minutes to **~180s**, and a
  one-module incremental link to **~32s**. Never commit this file — it would slow
  the shipped binary.
- **Don't wipe `dist-newstyle/`** between iterations — incremental compilation is
  the whole point.
- **Skip `cabal install`**: symlink the binary once —
  `ln -sf "$(cabal list-bin exe:sky)" sky-out/sky` — so `cabal build` updates the
  target in place and `sky-out/sky` always points at the freshly built binary. No
  per-iteration copy.

**Rust / example side**
- **Shared `CARGO_TARGET_DIR` + sccache** (see the
  `[[rust-shared-cargo-target-sccache]]` memory): every example is package
  `sky-app`, so a shared target outside each `sky-out/` compiles the heavy deps
  (axum/tokio/serde/sqlx) once; sccache caches each `rustc` call by content hash.
  ```sh
  export CARGO_TARGET_DIR="$HOME/.cache/sky-rust-target"
  export RUSTC_WRAPPER=sccache
  ```
- **Generated `Cargo.toml` `[profile.dev]`** drops debuginfo (`debug = 0`) and keeps
  `incremental = true` — the heaviest part of per-example dev linking. Emitted
  automatically by `emitCargoToml`.
- **Sweep with one build per example**:
  `SKY_BIN=$(cabal list-bin exe:sky) ./scripts/rust-sweep.sh` (the script also
  exports the shared target + sccache). A full ~40-example sweep dropped from
  ~1000s+ to **~570s**, and faster on warm sccache.

Re-export `CARGO_TARGET_DIR`/`RUSTC_WRAPPER` in every shell that builds — shell
state does not persist between tool calls.

---

## Disk hygiene

Cargo `target/` dirs accumulate fast — a full example sweep can exceed 20 GB.
The sweep idiom deletes each example's target right after building:

```bash
for d in examples/rust/*/; do
    (cd "$d" && rm -rf sky-out .skycache .skydeps \
        && /home/arthur/Documentos/comp/sky/sky-out/sky build src/Main.sky \
        && rm -rf sky-out/Rust/target)
done
```

Manual reclaim: `rm -rf runtime-rust/target tools/sky-ffi-inspect-rs/target
~/.cache/sky` and `find examples/rust -type d -name target -exec rm -rf {} +`.
Leave `~/.cargo/registry` and `~/.cargo/git` alone (global, slow to rebuild).

---

## Known limitations

| Limitation | Description | Workaround |
|---|---|---|
| `any` in record fields | Codegen refuses `Box<dyn Any>` — structured `error[Rust]: any-typed record field` diagnostic | Encode as an ADT upstream, or ship a Rust-target override at `runtime-rust/sky-stdlib-overrides/<Module>.sky` |
| `Task.retryWith` run-once | `SkyTask` is a one-shot `Future` (not `Clone`); codegen drops the policy arg and runs the task once | Drive the retry loop in Sky (recurse on the `Result`) |
| `withTransaction` rollback isolation | sqlx pool may route body queries to other connections | `sqlx::Pool::max_connections(1)` for guaranteed rollback |
| `Db.insertRow` on postgres | Returns 0 (no auto last-insert-id) | `INSERT … RETURNING id` + `Db.queryDecode` |
| JSON pipeline decoder | `Box<dyn FnOnce>` chain may not satisfy `Clone+Send` in some shapes | Use `JsonDec.field` directly, not the pipeline `|=` style |
| Flat `main.rs` | All Sky modules compile into one file; no `pub mod` | Planned cleanup; doesn't affect correctness |
| Bytes non-ASCII text base64/hex | `Sky.Core.Bytes = String` uses a Latin-1 byte convention so raw bytes round-trip; non-ASCII *text* diverges from Go-computed encoded strings (ASCII is byte-identical) | Compare decoded values, or `String.toBytes` first |
| `rustdoc` needs nightly | Inspector runs `cargo +nightly rustdoc` | `rustup install nightly` |
| Un-nameable bindings dropped | Generics, non-byte slices/arrays, borrows, std types, unsafe fns skipped | Use a wrapper crate with owned/primitive signatures |

---

## Remaining work

**Short-term**
- Single-connection `Db.withTransaction` variant (guaranteed rollback isolation).
- Non-byte slice/array FFI (`&[String]`, `[f64; 3]`) — per-element coercion.
- Enum-argument constructors for FFI (pass crate enum variants from Sky).

**Medium-term**
- Sky.Live: firestore store, Cmd/Sub depth, pub/sub `Broker`, req query parsing.
- `Sky.Core.WebSocket` client Sub-tier (onMessage subscriptions).
- WebSocket-server capturing handlers (`Arc<dyn Fn>` instead of fn pointers).

**Long-term**
- WASM target (`wasm32-unknown-unknown`).
- `sky watch` for Rust; separate module files (`pub mod` instead of flat `main.rs`).
- Sky.Tui / Sky.Webview (need the `Std.Ui` layout engine first).
