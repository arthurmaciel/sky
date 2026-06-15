# Sky Rust Runtime

The `sky_runtime` crate is the **single source of truth** for all Rust code
emitted by the Sky compiler's `--target rust` path. Every generated project
copies this crate's modules into `sky-out/Rust/src/sky_runtime/` at build time.

---

## Goal

> The Rust backend reaches full behavioral parity with the Go reference.
> **Priority order, applied to every choice: security → correctness → soundness
> → efficiency.** Hard rules: no panic vector, no runtime error from well-typed
> Sky, no `Any` in generated code, no change to Sky/Go source or the upstream
> examples, root-cause fixes only (no symptom masking), no deferral. Anything
> conflicting with the four principles is escalated, not silently traded away.

The chosen *mechanisms* (where Rust implements something differently from Go to
hold those guarantees) are in **Rust vs Go backend — divergent implementation
strategies**.

---

## Project status — single source of truth

The authoritative status of every Rust-backend surface. Detailed sections below
expand each area; this table is the canonical overview and must not contradict
them.

- **Status:** ✅ done & verified · 🟡 intentional divergence (by design) · ⛔ blocked (can't fix in-boundary) · 🔜 future (actionable epic, deferred) · 🚫 out of scope (intentional non-goal — will not be done)
- **Go parity:** ✅ matches · ➕ exceeds Go's guarantee · ⚠️ partial · ❌ diverges

### Codegen & language

| Status | Feature | Description | Go parity | Future work |
|---|---|---|---|---|
| ✅ | Type-directed lowering + Go generics on record aliases | HM types propagated to the Rust IR; `Cfg_R[T]` per-instance generics | ✅ | -- |
| ✅ | Same-module polymorphic re-instantiation + wildcard-`any` gate | per-call-site alpha-rename; soundness gate on `any` | ✅ | -- |
| ✅ | Auto-TCO | tail self-calls → `loop { … continue }`, constant stack | ✅ | -- |
| ✅ | Task-valued `if`/`case` branches at `main` | lowered as the Task they already are (no `task_succeed` double-wrap) | ✅ | -- |
| ✅ | Multibackend program-entry model | any backend driver future IS the entry; init-shape per call site | ✅ | -- |
| ⛔ | composite `Basics.toString` (record/ADT) | scalars match Go; a composite is a clean compile-time E0277 (never a panic) | ❌ — Go `%v` renders an ADT as `{tag payload}`, a leak of Go's flattened single-struct layout no Rust sum type can reproduce without fabricating memory | Blocked: a `SkyShow` bound threaded through every generic signature (codegen-wide epic) + a parity oracle (no upstream example exercises it) |

### FFI reach

| Status | Feature | Description | Go parity | Future work |
|---|---|---|---|---|
| ✅ | Leaf/data-crate auto-FFI + Alt-1 monomorphisation | rustdoc-JSON inspector → typed bindings; generic bounds → Sky types | ✅ | -- |
| ✅ | FFI `Option<T>` param coercion | `SkyMaybe<T>` → `Option<&str>` / `<u16>` / `<&T>` | ✅ | -- |
| ✅ | FFI crate-name collisions (absolute `::<crate>` paths) | csv/time/log/json/config/email/html crate deps unblocked | ✅ | -- |
| ✅ | FFI builtin-name collision (`bytes::Bytes`) | crate-prefix → Sky `BytesBytes` resolves to the crate type | ✅ | -- |
| ✅ | FFI glob-re-export qualification | regex's `RegexBuilder` (private `builders::string`) recovered | ✅ | -- |
| ✅ | FFI submodule name disambiguation | `regex::Regex` vs `regex::bytes::Regex` → both `Regex`/`BytesRegex` usable | ✅ | -- |
| ✅ | FFI Sized gate (unsized receivers) | drop instance methods on DSTs (`bytes::buf::UninitSlice`) | ✅ | -- |
| ✅ | FFI owned-threading builder setters | `&mut self → &mut Self`/`()` exposed as `fn(recv, args) → recv` | ✅ | -- |
| ✅ | FFI lifetime-elided copies | `&'a str` / `&'a [u8]` / `&'a OsStr` / `&'a Path` kept as owned | ✅ | -- |
| 🚫 | FFI non-byte slice element coercion (tail) | borrowed/nested/tuple elements | N/A — measured 1/2552 functions across 50 crates | Out of scope: the clean drop IS the correct boundary, not a gap to close |
| 🔜 | FFI framework crates (axum/diesel/bevy/tokio) | generic + trait + lifetime-bound core; auto-FFI binds only peripheral surface | ⚠️ partial | Future: generated idiomatic glue / Sky-native modules (the Sky.Live model) — deliberate |
| 🚫 | Go-package → Rust FFI | gorilla/mux, stripe-go, … | ❌ — no Rust equivalent (Go-only ecosystem) | Out of scope — Rust FFI targets **Rust crates** (`[rust.dependencies]`, e.g. `sky add url`), not Go packages |

### Stdlib runtime

| Status | Feature | Description | Go parity | Future work |
|---|---|---|---|---|
| ✅ | Sky.Core kernels (String/List/Dict/Set/Maybe/Result/Math/Char/Regex/Time/…) | pure + fallible-pure surface | ✅ | -- |
| ✅ | Crypto / Jwt / Encoding / Bytes kernels | incl. `Bytes` `toHex`/`toString`/`fromHex`/`toBase64`/`fromBase64`/`length` routing (removed a `panic!` polyfill) | ✅ | -- |
| ✅ | Std.Db (sqlx — sqlite / postgres / mysql) | CRUD, migrations, typed `SqlValue` params, decoders; `withTransaction` (same tx-handle gap as Go), `insertRow` via `RETURNING` | ✅ | -- |
| ✅ | Std.Auth / Email / Config / Csv / Compression / Cache | bcrypt+JWT, providers, TOML/YAML/JSON, RFC 4180, gzip/zstd, LRU+TTL | ✅ | -- |
| 🔜 | `Process.run` / `Io` beyond `Log` | subprocess + raw stdin/stdout kernels | ⚠️ not yet example-verified on Rust | Future: bounded + additive, no architectural blocker |
| 🟡 | `Task.retryWith` | runs the task once | ⚠️ — Go re-calls a thunk; Rust `SkyTask` is a one-shot `Future`. Run-once is observably correct for Ok-first / last-Err / `RetryWhen`-False | Blocked (by design): a faithful retry needs a thunk-shaped `retryWith` in the shared stdlib (forbidden); workaround: recurse on the `Result` in Sky |
| ⛔ | `errorToString` String path | retains `Debug` (the only total universal stringifier) | ❌ — Go returns a `string` verbatim (`hi`); Rust `Debug` quotes it (`"hi"`) | Blocked: the `Display` re-bind fails on the generic `Sky.Test.debugShow : a -> String` caller (E0277) — same `SkyShow`-bound epic + no oracle for assertion messages |
| ⛔ | `Bytes` non-ASCII text | Latin-1 byte convention (one char per byte) | ⚠️ — ASCII / hex / binary byte-identical to Go; non-ASCII *text* diverges from Go-computed encoded strings | Blocked: needs a nominal `Bytes` type in the **shared** stdlib (forbidden to edit) |
| 🟡 | `Ffi.callTask` dynamic dispatch | static-shape calls are peephole-resolved | ❌ — the dynamic path is unsupported | Blocked (by design): a no-reflection guard preserving no-`Any` / no-runtime-error |

### App frameworks & compile targets

| Status | Feature | Description | Go parity | Future work |
|---|---|---|---|---|
| ✅ | Sky.Live | SSE/TEA, faithful VNode diff, typed forms, URL routing, typed `LiveReq` init, async `Cmd`, status banner | ✅ — axum + hyper internally; reuses the Go client JS | -- |
| ✅ | Sky.Tui | ANSI-cell renderer over the shared `Element`; ~95% of Std.Ui | ✅ | -- |
| ✅ | Sky.Webview | native desktop window (macOS); shares the Sky.Live renderer | ✅ | -- |
| ✅ | Sky.Cli | one-shot / cron tool; `System.args`, no UI loop, `readPassword` | ✅ | -- |
| ✅ | Sky.Http.Server | headless JSON/HTTP API — routes + middleware (CORS / logging / basic-auth / rate-limit), cookies, extractors | ✅ | -- |
| ✅ | Sky.Http.Server.Stream | server-side streaming responses (SSE / chunked / LLM-token relay) | ✅ | -- |
| ✅ | Sky.Http.Server.WebSocket (+ `Sky.Core.WebSocket` client) | bidirectional sockets on `nhooyr.io/websocket`; broadcast / per-client send | ✅ | -- |
| ✅ | Sky.Live session stores — memory / sqlite / redis / postgres | `SessionStore` trait; cookie reuse + restart survival | ✅ | -- |
| ✅ | Sky.Live session store — firestore | parity-by-absence | ✅ — Go's runtime has no firestore arm either (unknown kind → memory); Rust matches | -- |
| 🔜 | WASM target (`wasm32-unknown-unknown`) | — | N/A | Future: a tokio/threads-free runtime rewrite (epic) |

### Observability

| Status | Feature | Description | Go parity | Future work |
|---|---|---|---|---|
| ✅ | Sky Console (separate process) + `/_sky/metrics`/`healthz`/`buildinfo` | observability endpoints; embedded console mini-app | ✅ | -- |
| ✅ | PubSub `Broker<T>` (zero payload erasure) | per-type, `TypeId`-keyed; payload travels as its real type | ➕ — avoids Go's reflection + `any` | -- |
| ✅ | Telemetry spill (SQLite) | one schema end-to-end; WAL reader | ✅ | -- |

### Soundness & principles

| Status | Feature | Description | Go parity | Future work |
|---|---|---|---|---|
| ✅ | No `Box<dyn Any>` in generated code | dynamism monomorphised away (per-type brokers, typed `LiveReq`) | ➕ — Go uses `reflect` | -- |
| ✅ | No runtime panic from well-typed Sky | statically total; fallible cases are `Result`/`Task` | ➕ — Go recovers a handler panic → 500; Rust designs the panic out | -- |
| ✅ | `unsafe` blocks | exactly one (`PR_SET_PDEATHSIG` `pre_exec`, `cfg(linux)`, documented) | ➕ | -- |

---

## Understanding the project

### Glossary

**Sky language**

| Term | Meaning |
|---|---|
| **Sky** | Elm-family functional language compiling to typed Go (reference) and Rust (this backend), via a Haskell compiler (GHC 9.6) |
| **Sky source** | `.sky` files |
| **stdlib** | `Sky.Core` (pure + kernels), `Std` (effects), `Sky.Http` (server) — shared across both backends |
| **kernel function** | a built-in runtime primitive dispatched by name; surfaced in Sky as `Ffi.kernel "Name"` |
| **TEA** | The Elm Architecture — `init` / `update` / `view` / `subscriptions` |
| **Sky.Live / Sky.Tui / Sky.Webview / Sky.Cli** | the app backends: web (HTTP+SSE), terminal (ANSI cells), desktop (system webview), one-shot/loop CLI |

**Compiler pipeline** (`src/Sky/`)

| Stage | Where |
|---|---|
| **Parse** | lexer + layout filter + parser — `Parse/` |
| **Canonicalise** | name resolution, import validation — `Canonicalise/` |
| **Type check** | HM inference + exhaustiveness — `Type/` |
| **Lower** | canonical AST → IR — `Build/Compile.hs` |
| **Generate** | IR → target language — `Generate/{Go,Rust}/` |
| **TargetGo / TargetRust** | the compile-target selector (`--target rust`); shared code branches on it at a minimal seam |

**Rust codegen — Haskell side** (`src/Sky/Generate/Rust/`, `src/Sky/Build/Rust/`)

| Term | Meaning |
|---|---|
| **Builder.hs / Emitter.hs / ModuleEmitter / ExprEmitter / TypeEmitter** | the Rust code generators (expr / type / pattern / module / `Cargo.toml` emission) |
| **Walker.hs** | the kernel-usage analyzer — walks the program and produces `UsedKernels` (the `usesX` flags) |
| **`usesX` flags** | `usesLive` / `usesTui` / `usesWebview` / `usesBackendApp` / `usesTaskRun` / `usesTaskParallel` / `usesDb` / `usesHttp` / `usesHttpServer` / `usesWsClient` / `usesEmail` / `usesTea` / `usesHtml` — gate which runtime modules + crates are emitted |
| **`mainIsTask`** | entry-mode flag — when true the entry `block_on`s `sky_main()`; a kernel that internally task-runs must NOT set `usesTaskRun` (it flips this off and drops a Task-chain main) |
| **peephole** | a call-site pattern rewrite in codegen (e.g. `Ev.onSubmit` → typed `decode_form`, `App {…} |> Task.run` → drop the `Task.run`) |
| **monomorphise** | resolve Sky's `any`/generics to a concrete Rust type at the call site, instead of erasing to `Box<dyn Any>` |
| **DCE** | whole-program dead-code elimination — dep modules prune to the reachable-from-`main` set |
| **runtimeOpaqueTypes** | Sky types the runtime must name (Request/Response/LiveReq/Csv…) bridged to concrete Rust structs/enums |
| **CrateSpecs / `crate-specs.toml`** | single source of truth for generated-project crate versions/features; `cargoDependencyFor name` emits a dependency line from it |

**Rust runtime crate** (`runtime-rust/src/sky_runtime/`)

| Type / fn | Meaning |
|---|---|
| **`sky_runtime`** | the runtime crate copied into every generated project |
| **`SkyResult` / `SkyMaybe`** | Rust forms of `Result Error a` / `Maybe a` |
| **`SkyString` / `SkyList` / `SkyDict`** | Sky string / list (`Vec`) / dict (`HashMap`) |
| **`SkyTask` / `SkyCmd` / `SkySub`** | async task (`Pin<Box<dyn Future>>`) / TEA command / TEA subscription |
| **`SkyError`** | the project error type the generated wrappers fix `E` to (`String`) |
| **`SkyRow`** | trait a `Db.get*` row is decoded through (no `Any`) |
| **`SubManager` / `spawn_subs`** | the two Sub drivers (Cli/Tui loop · Sky.Live) — both spawn `SkySub::Source` subscriptions and abort+respawn per model update |
| **`Broker<T>`** | per-payload-type pub/sub broker keyed by `TypeId` — the payload travels as its real `T`, never downcast |
| **`SessionStore`** | the Sky.Live session-store trait — `Memory` / `Sqlite` / `Postgres` / `Redis` impls |
| **`LiveReq`** | the typed `init` request record (`path`/`query`/`method`/`params`/`headers`/`cookies`) |

**FFI** (`src/Sky/Build/Rust/Ffi.hs`, `tools/sky-ffi-inspect-rs/`)

| Term | Meaning |
|---|---|
| **FFI binding** | generated Rust wrapping an external crate function |
| **FFI inspector** | `sky-ffi-inspect-rs` — scans a crate's public API via `cargo +nightly rustdoc --output-format json` |
| **FFI registry** | cached inspection results at `.skycache/ffi/rust/` |
| **nameability filter** | drops un-bindable items (generics, borrows, non-byte slices, `unsafe fn`, std/private types) so `_bindings.rs` always compiles |
| **Alt-1** | the widening that monomorphises generic fns whose bound maps to a Sky type (`AsRef<[u8]>` → `List Int`, `Display` → `String`) |
| **opaque type** | an FFI type emitted by its fully-qualified path (`chrono::NaiveDate`), passed through without inspection |

**Build artifacts + conventions**

| Term | Meaning |
|---|---|
| **`sky-out/` · `sky-out/Rust/`** | compiler output · Rust codegen output (capital `R` by convention) |
| **`.skycache/` · `.skycache/ffi/rust/`** | build cache (source hashes, lowered IR) · Rust FFI registry |
| **`SKY-RUST-AUDIT:` marker** | an in-code attributed decision marker (ACCEPTED / DEFERRED) mirroring the README decision ledger |
| **no-`Any` invariant** | generated code + Sky-reachable runtime paths use the static type system end-to-end; the one `unsafe` is the console orphan-guard — see the safety-invariant section |

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

## Safety invariant — zero `Any`, one documented `unsafe`

The Rust backend uses Rust's static type system end-to-end. Sky's `any` is
**never** lowered to `Box<dyn Any>` — that would re-implement Go's `interface{}`,
the exact bug class this backend exists to avoid. The generated code and the
Sky-reachable runtime paths use no `transmute`, no raw pointers; the Sky→Rust FFI
path is safe Rust-crate calls.

The **only** `unsafe` block in the crate is the console child's
`PR_SET_PDEATHSIG` orphan-guard (`live/console_proxy.rs`): a `pre_exec` closure
that calls `prctl` (async-signal-safe) between fork and exec. It is not on any
Sky value path, is `#[cfg(target_os = "linux")]`-gated, documented with a
`// SAFETY:` rationale, and best-effort (failure is non-fatal). It is recorded in
the decision ledger.

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
# dyn Any: only the correct-by-construction broker/cache containers (ledger #4).
grep -rEn "dyn Any|std::any|downcast|type_id" runtime-rust/src/ src/Sky/Generate/Rust/ src/Sky/Build/Rust/
# unsafe: only the cfg(linux) PR_SET_PDEATHSIG pre_exec (ledger #5); transmute/raw-ptr must stay empty.
grep -rEn "\bunsafe\b|transmute|from_raw|into_raw|static mut|\*const |\*mut " runtime-rust/src/
```

---

## Rust vs Go backend — divergent implementation strategies

Where the Rust backend deliberately implements something **differently** from Go,
log it here with the **why**. The Go backend is the reference, but parity is about
*observable behaviour*, not internal mechanism — and Rust's no-`Any` /
no-panic-vectors constraints (plus the absence of reflection) sometimes make a
different mechanism the *correct* one, not a shortcut.

> **MUST DO before scoping any "Go-parity" work:** re-verify what Go *currently*
> does (read `runtime-go/rt/` + `docs/` + the latest refactor commit). Go evolves;
> a stale parity premise wastes work.

### Console serving — pre-built separate process vs in-process inline

- **Go (current, v0.16.0+):** in-process. `MountEmbeddedConsole` links the bundled
  console (translated to Go) into the user's binary; one process, no fork.
- **Go (v0.15.x, abandoned):** subprocess — reverse-proxied to a `sky console`
  child that **`go build`-compiled the console at runtime on first launch**. That
  recursive build peaked at several hundred MB and **OOM'd e2-micro (1 GB) VMs**,
  which is why Go abandoned it.
- **Rust (chosen):** **pre-built** separate process + reverse-proxy. The console
  binary is compiled at the user's `sky build` time (a sibling binary); at runtime
  the parent just `exec`s it and proxies `/_sky/console/*` — **no runtime build, no
  toolchain on the VM**, ~5 MB RSS.
- **Why diverge from current Go:** the *only* reason Go dropped subprocess was the
  **runtime build** — which a pre-built Rust binary doesn't incur, so the OOM
  rationale doesn't transfer. Meanwhile Go's chosen path (in-process) is the *hard*
  one on Rust: two Sky programs in one crate collide on every generated type
  (`StateModel`/`StateMsg`/…), needing codegen type-namespacing/module-isolation —
  a major undertaking Rust has no reflection to shortcut. Separate binaries have
  zero type collision and full fault isolation. So pre-built-subprocess is the
  pragmatic Rust optimum: it sidesteps Go's abandonment reason *and* Rust's
  hard-path. Spec: `docs/superpowers/specs/2026-06-12-rust-separate-process-console-epic.md`.
- **Proxy convention — STRIP (vs Go pass-through+child-trim).** The browser
  reaches the console child only through the parent proxy (the child binds
  `127.0.0.1`), so the parent **strips** `/_sky/console` before forwarding and the
  Rust child's router stays byte-identical to a standalone Live app — no per-route
  basePath-trimming. `SKY_LIVE_BASE_PATH` affects rendered **output** URLs only
  (via `<meta sky-base>`/`__SKY_BASE`, which `client.js` prefixes onto
  `/_sky/event` + `/_sky/sse`), never routing. Go uses pass-through + `trimBasePathPrefix`
  because its in-process sub-app shares the parent mux. The session cookie is
  de-collided per sub-app — a base-derived **distinct name** (`sky_sid__sky_console`)
  + base-scoped `Path` — so the proxied child can't clobber the parent's
  `sky_sid` (Go gives each sub-app a distinct `cookieName` for the same reason).
- **Child lifecycle — signal-exit + `PR_SET_PDEATHSIG`.** The parent traps
  SIGTERM/SIGINT, reaps the child, then exits `128+signum` (trapping alone would
  make the parent unkillable-by-SIGTERM since the trap suppresses the default
  disposition). On Linux the child additionally gets `PR_SET_PDEATHSIG=SIGTERM`
  (via `pre_exec` + `libc`) so it dies even when the parent is SIGKILL'd / OOM'd —
  a path no signal handler can catch.
- **reqwest is a Std.Live dependency.** Because the live runtime's reverse-proxy
  forwards via reqwest, codegen declares reqwest for **every** Live app
  (`usesHttp || usesEmail || usesLive`), not just `Http.*`/`Email` users.
- **Console pre-build is fingerprint-validated, not version-keyed.** The Rust
  backend is dev-only (the runtime is sourced from disk, never embedded), so
  `SKY_VERSION` is always `"dev"` — a version-only console cache would never
  invalidate. So `Sky.Build.Rust.Console` validates the cache by a content
  fingerprint (sha256 of the console source + the runtime `.rs`), rebuilding on
  any change. Debug profile (fast dev iteration); `--release` is reserved for an
  eventual shipping path. Go pre-generates its console as committed Go compiled
  in-process — no per-build console build at all.
- **`--target rust` ignores `[go.dependencies]`.** Go FFI bindings are inert on
  the Rust backend (it can't link Go), so `regenMissingBindings` short-circuits
  on the Rust target — a pure-Rust build needs no `go` toolchain even for a
  project that declares Go deps.
- **Observability export is OTLP/JSON, env-gated, inert by default.** Federation
  push (`SKY_PARENT_URL` → parent ingest) and the remote HubExporter
  (`SKY_CONSOLE_HUB` → `/v1/{logs,traces}` OTLP/**JSON** + bearer + bounded retry
  spool) mirror Go's `observability_push.go` / `exporter.go`. Go's
  HubExporter also uses OTLP's JSON encoding, so no protobuf dep. File-spool
  restart-durability is a noted parity extension (in-memory retry spool covers
  the transient-outage case).
- **Console telemetry data flow — push-to-local-collector (vs Go in-process
  read).** Go compiles the console INTO the user binary, so it reads the app's
  in-RAM telemetry directly (same process); the SQLite spill is only optional
  history beyond the in-RAM caps. Rust's console is a SEPARATE process and can't
  read the app's in-RAM rings, so the data path is the industrial push-to-
  collector model applied locally:
    - the app auto-instruments each HTTP request into its in-RAM rings (a span +
      an access log — `observability::track`, Go-parity automatic telemetry);
    - a **lean** app (no sqlx) **pushes** that telemetry to the console child —
      the *local collector* — via the exporter (`push_exporter::enable_to_console`);
      the child (which owns sqlx + the store) ingests → writes its SQLite store
      → reads it back through the hub read kernels → serves the UI;
    - a **db** app instead writes the spill directly and the child only reads it
      (no push — `parent_spill_active()` selects the path).
  This keeps EVERY Live app lean (no SQLite embedded just to get a console) while
  giving a durable, query-able console — the local analog of "app → OTLP →
  collector → console". A sub-app (the console child, `SKY_LIVE_BASE_PATH` set)
  does NOT self-instrument: the console shows the PARENT's telemetry, not its own
  page renders. The Overview's per-service charts are a live 60 s window (they
  read "Waiting for samples…" when the app is idle — correct, same as Go); Logs
  and Traces are historical.

### Hub read kernels (console data plane) — generic-over-return-type vs `any` + Coerce

- **Go:** `Hub_read*` return `any` (a JSON-ish map); `rt.Coerce[State_*_R]` narrows
  to the typed record at the call site (reflect-backed).
- **Rust:** each `hub_read_*<A: DeserializeOwned>(…) -> SkyTask<E, A>` is **generic
  over its return type**; it builds a `serde_json::Value` matching the record's
  camelCase serde shape and `from_value::<A>`s it. The project-generated `State*`
  records are named only at the **call site**, where `A` is inferred from the
  concrete `StateStore` field types — no turbofish, no `Any`, no downcast.
- **Why:** no-`Any` is existential for the Rust backend. The dynamism Go erases
  with reflect is instead monomorphised away: the value travels as its real type
  `A`, the one `serde` decode is provably-shaped because the kernel owns both the
  SELECT and the `Value`. (`live/hub.rs`.)

### Telemetry spill schema — one schema end-to-end vs Go's two

- **Go:** the per-app spill (`telemetry/persist.go`, `SKY_CONSOLE_DB_PATH`) uses a
  `namespace/created_at` schema; the hub (`hub/store.go`, `SKY_CONSOLE_HUB_DB`)
  uses a richer `service_name/time/trace_id/…` schema.
- **Rust:** the embedded console uses **one** schema end-to-end — the hub
  (`hub/store.go`) one — for both the writer (`telemetry_spill.rs`) and the
  reader (`live/hub.rs`).
- **Why:** the spill is an internal writer↔reader contract (not a byte-compatible
  Go artifact). One schema means writer and reader share a single source of truth;
  the hub schema is the richer one the console records actually need.

### Telemetry spill journal mode — WAL + `mode=rw` reader (not `mode=ro`)

- **Rust:** the spill is WAL (concurrent parent-writer + console-reader without
  livelock), and the console reader opens `mode=rw`, **not** `mode=ro`.
- **Why:** a `mode=ro` SQLite connection can't attach the `-wal`/`-shm` shared
  memory, so it never sees frames the writer committed but hasn't checkpointed — it
  silently reads stale/empty data. A `mode=rw` reader participates in WAL and sees
  all committed writes; the console only ever `SELECT`s, so rw grants no real write.

### Pub/Sub broker — per-type `Broker<T>` keyed by `TypeId` vs reflection + `any`

- **Go:** a single broker passes payloads as `any`, type-asserted on receive.
- **Rust:** one `Broker<T>` per payload type, keyed by `TypeId`. The payload travels
  as its real `T` and is **never downcast**; a publisher/subscriber type mismatch
  can't construct.
- **Why:** mirroring Go's reflect/`any` risk surface would be a defect, not parity.
  The dynamism is monomorphised away. (`live/pubsub.rs`.)

### Sky.Live `init` request — typed-record `LiveReq` vs heterogeneous `Dict`

- **Go:** `req` is a heterogeneous `Dict`/`any` map.
- **Rust:** a typed-record `LiveReq` (the kernel type stays free so it's Go-safe on
  the shared seam).
- **Why:** a typed record keeps the no-`Any` invariant on the request path; the free
  kernel type avoids clashing with Go's Dict-shaped req. (`live/req.rs`.)

### Closure-holding Model serialization — compile-error guard vs runtime skip

- **Go:** reflection serializes a session Model, skipping func fields at runtime.
- **Rust:** a Model field that is a callback-record (fn fields lowered to
  `Arc<dyn Fn>`) derives `Clone` + a generated `Default` (disconnected error
  closures) and `#[serde(skip)]`s the field; persisting such a Model to a real
  store is designed to be a **compile error** (the unsound combo can't ship).
- **Why:** "if it compiles, it works" — an un-restorable closure can't silently
  round-trip through a session store; the type system rejects it instead of a
  runtime surprise.

---

## Multibackend program-entry model (#24)

A `main` may pick its UI backend at runtime and run it, sharing one
`init`/`update`/`subscriptions` across backends — e.g.
`examples/24-tui-kitchen-sink`:

```elm
main =
    case List.head argsList of
        Just "live" -> Live.app { …, view = viewLive, routes, notFound } |> Task.run
        _           -> Tui.app  { …, view, onKey } |> Task.run
```

The codegen treats *any* backend driver future as the program entry, uniformly.
Three rules (see `docs/superpowers/specs/2026-06-12-rust-multibackend-entry-model.md`):

1. **`Task.run` on a backend-entry app-future is dropped.** `Live.app {…}` /
   `Tui.app {…}` / `Tui.program {…}` / `Webview.app {…}` each lower to a
   `SkyTask<()>` driver future. `App {…} |> Task.run` (or `Task.run (App {…})`)
   drops the `Task.run` *anywhere* — top-level OR inside a `case` arm — so the
   future is returned as a `SkyTask` (the entry `block_on`s it / a dispatching
   `case` unifies as `SkyTask<()>`), never executed inline via `task_run`.
2. **`mainIsTask` derives from `usesBackendApp`** (`usesLive || usesTui ||
   usesWebview`), not `usesLive` alone — so a pure-Tui / pure-Webview `App {…} |>
   Task.run` main returns `SkyTask` and is `block_on`'d.
3. **`init`'s param is derived from its Sky type, adapted per call site.** Only
   a *req-reading* init (`init req = … req.path …`, detected by
   `collectLiveReqInitFns`: param 0 binds a var used in the body) pins param 0
   to `sky_runtime::LiveReq`. A *non-req* init (`init _`) keeps its natural
   param (`()` / a free generic) and is adapted at the `Live.app` call site via
   `move |_r: LiveReq| init(())` — so the SAME init can also feed `Tui.app`
   (bound `Fn(())`). No global pin; no Tui-side change; every Live example's
   `init` body is byte-identical so the rendered HTML is unchanged.

### Pitfalls (do not re-derive)

- **`Task.run` is an `Ffi.kernel` alias, so it arrives as `VarTopLevel
  "Sky.Core.Task" "run"` — NOT `VarKernel "Task" "run"`.** Same for
  `Webview.app` / any `sky-stdlib` binding defined as `name = Ffi.kernel "…"`
  (vs the *pure* kernels `Live.app` / `Tui.app` / `Cli.program`, which DO arrive
  as `VarKernel`). A peephole that only matches `VarKernel` silently misses the
  alias. Match both (see `isTaskRunRef`).
- **Force a non-req Live init's param 0 to `()` — do NOT trust the natural
  render.** A `Live.app` init's param 0 is the request slot; an ignored slot is
  written `init _` with annotation `()` / `{}` / a free `a`. The natural render
  of those is inconsistent and sometimes WRONG: a free `a` renders generic, and
  an empty-record `{}` annotation resolves to the *model struct* (an existing
  open-record-param quirk — `26-ui-showcase`'s `init : {} -> (Model, Cmd Msg)`
  rendered `main_init(_: MainModel)`). The `Live.app` wrapper `move |_r| init(())`
  then mismatches (E0308 expected `MainModel`, found `()`). So force param 0 to a
  concrete type uniformly: `LiveReq` for a req-reader, else `()`. The wrapper's
  `init(())` always type-checks and Tui passes the `Fn(())` init directly. This
  surfaced ONLY in the full `rust-sweep.sh` (a 14-example targeted regression
  missed `26`) — run the full sweep, not a hand-picked subset.
- **`Cli.program` is intentionally EXCLUDED from the backend-entry set.** It
  still runs inline via `task_run` (not in `usesBackendApp`), so its `Task.run`
  is kept. Adding it would require flipping its `mainIsTask` too — out of scope
  until a `Cli.program` example needs it.
- **Build/verify gotcha:** with the shared `CARGO_TARGET_DIR`, every example is
  cargo package `sky-app`, so the target dir holds only the *last-built*
  binary — rebuild the specific example immediately before running it. And a
  background `cabal install` that hasn't finished copying leaves a STALE
  `sky-out/sky`; confirm the binary mtime before building an example against it
  (a "fix didn't take effect" symptom is almost always this).

---

## Std.Ui parity (byte-identical render)

`Std.Ui` is pure Sky source that builds a `Std.Html` ADT, serialised by
`html.rs` `render_html` — so parity is a **codegen-lowering + serializer**
problem, not a renderer port. Verified by `scripts/ui-parity.sh`: each corpus
fixture runs `main = Io.writeStdout (Html.toString (Ui.layout [] view))` and the
stdout is byte-diffed Go-vs-Rust (Go is the golden). All corpus cases are
byte-identical:

| Covers | Primitives |
|---|---|
| text | `layout` + `text` |
| layout | `row`/`column`/`spacing`/`padding`/`align` |
| styling | `Background`/`Border`/`Font` |
| sized | `button`/`link`/`image` (static) |
| advanced | nearby overlays / aspect-ratio / grid |
| semantic | `Region` tag + aria mapping |

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
| `src/Sky/Generate/Rust/Builder.hs` + `Builder/` | Rust codegen — `Emitter` / `ExprEmitter` / `TypeEmitter` / `Pattern` / `Kernel` / `ModuleEmitter` / `Walker` / `Naming` / `CrateSpecs` (`crate-specs.toml`) |
| `src/Sky/Generate/Rust/Project.hs` | project orchestration — `main.rs` + `Cargo.toml`, copies runtime + FFI bindings |
| `src/Sky/Build/Rust/Ffi.hs` | Rust FFI — inspector, `.skyi` / `.kernel.json` / `_bindings.rs`, coercion |
| `src/Sky/Build/Rust/Console.hs` | separate-process console pre-build (fingerprint-validated) |
| `src/Sky/Sky/Toml/Rust.hs` | Rust dependency-spec parsing (`["rust.dependencies"]`) |
| `tools/sky-ffi-inspect-rs/` | Rust crate inspector (rustdoc JSON) |

Shared compiler files keep only a minimal `case Toml._target of { TargetRust ->
…; TargetGo -> … }` dispatch seam. Dependencies are one-way (shared → Rust-only),
so the Go path stays byte-identical and upstream merges stay small. See
`docs/runtime-rust/syncing-upstream.md`.

**One shared file carries Rust-only inspector fields: `src/Sky/Build/FfiGen.hs`.**
The inspector-JSON decode type `FnInfo` (and its single Aeson `FromJSON`) lives
there and is used by both backends, so a Rust-only field can only be *decoded*
there — it cannot move to a Rust-only module. Precedent: `_fnRecvRustType`,
`_fnRustParamTypes`, `_fnRustResultTypes` are all Rust-only fields already on
`FnInfo`; `_fnSelfReturning` (builder-setter tag) follows them. **Go-neutral by
construction**: every such field defaults (`""` / `False`), the Go inspector
never emits it, and no `src/Sky/Generate/Go/` code reads it → Go output
byte-identical. Adding a Rust-only `FnInfo` field is the one sanctioned
shared-file touch; new *behaviour* still goes behind `TargetRust ->` seams.

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

### `runtime-rust/tests/sky/` — FFI + framework examples (build + run from a wiped slate)

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
| 25-retry | `Sky.Core.Task` | `retryWith` + `RetryPolicy` (run-once on Rust by design — see `docs/superpowers/specs/2026-06-15-task-retrywith-runs-once-design.md`) |
| 26-stream-cli | `Sky.Core.Http.Stream` Sub-tier | `chunks` → `ChunkEvent` Msgs into a `Cli.program` update loop |
| 27-live-static | Sky.Live | `Live.renderStatic` byte-correct full HTML |
| 28-live-counter | Sky.Live | TEA-over-SSE; span increments live |
| 29-live-form | Sky.Live | typed form submit |
| 30-live-routing | Sky.Live | URL routing → injected `model.page` |
| 31-live-req | Sky.Live | typed `LiveReq` to `init` |
| 31-system-env-chain | `Sky.Core.System` | getenv/setenv chain — `usesTaskParallel` entry invariant |
| 32-live-sessions | Sky.Live | `[live] store="sqlite"` — cookie reuse + restart survival |
| 33-live-pubsub | PubSub | cross-session broadcast over SSE via the per-type `Broker<T>` |
| 34-live-pubsub-dict | PubSub | Dict-payload broadcast |
| 35-live-db-startup | `Std.Db` + Live | schema init at startup |
| 37-cache-cli | `Std.Cache` | per-handle TypeId/K-keyed store (the no-`any` cache) |
| 38-tui-ui | Sky.Tui | `Std.Ui` `Element` walked to ANSI cells |
| 39-webview | Sky.Webview | cross-platform stub floor + codegen |
| 40-live-ui | Sky.Live + Std.Ui | full Ui render through the Live VNode path |
| 41-tui-input | Sky.Tui | key/focus input model |
| 42-ws-client-onmessage | `Sky.Core.WebSocket` | client `onMessage` Sub-tier |
| 43-ws-server-capturing | `Sky.Http.Server.WebSocket` | capturing (inline-lambda) handler |
| 44-curried-return | codegen | uncurried lambda-bodied function-valued returns |
| 45-url-option-setters | FFI reach | `Option<&str>` param coercion — `set_fragment (Just "section")` |
| 46-csv-builder | FFI reach | `csv` crate name-collision fixed + in-place `push_field` setter chain |
| 47-regex-builder | FFI reach | recovered `RegexBuilder` setters; **both** `Regex` (String) and `BytesRegex` (`List Int`) variants usable |
| 48-bytes-collision | FFI reach | `bytes::Bytes` builtin-collision fixed (`BytesBytes`); unsized `UninitSlice` methods gated out |
| 49-bytes-core | `Sky.Core.Bytes` | `toHex`/`toString`/`fromHex`/`toBase64`/`fromBase64`/`length` route to `encoding.rs` (no panic) |

The faithful view-diff and the postgres/redis stores are covered by runtime unit
tests, not separate examples; generated postgres + redis live apps are
cargo-build-verified.

**Codegen test set** (`runtime-rust/tests/rust-codegen/run.sh`): per-case
`.sky` builds that must compile + print `ok:` — incl. `task-branch.sky`
(Task-valued `if`/`case` branch at `main`). **Runtime crate**: 378 tests pass
(`cargo test --features full`), incl. soundness suites (`core_soundness`,
`kernel_soundness`, `dict_determinism`) asserting no-panic + sorted-iteration
invariants under proptest.

### `examples/00-standard-libs`

- `target=go`: 131/131 assertions. `target=rust`: **131/131 — full parity.**

### `Sky.Http.Server` / `Sky.Live` regression tests

- `runtime-rust/tests/rust-codegen/http-server-test.sh` asserts every route over real HTTP
  (GET, path param → JSON, POST body, static, 404, content-type).
- `cargo test --features full` — diff, dispatch, form, store (memory/sqlite +
  env-gated pg/redis restart-survival), and the pub/sub broker (fan-out, echo,
  SkipOrigin, per-type isolation), among the 378 runtime tests.

### PubSub / Broker — zero payload erasure

`Cmd.publish` / `Cmd.publishNoEcho`, `Sub.subscribeTopic`, and the Task-shaped
`PubSub.publish` / `PubSub.publishNoEcho` run on Rust via an in-process broker in
`live/pubsub.rs`. The broker is **per-payload-type** (`Broker<T>` keyed by
`TypeId`): the payload travels as its real Rust type `T` end-to-end and is never
erased or downcast — a statically-typed broker, not Go's reflect registry. Echo
is default; `publishNoEcho` suppresses the origin receiver-side; the publishing
session's sid is injected at dispatch time. Cross-session broadcast is proven
end-to-end by `runtime-rust/tests/sky/33-live-pubsub` (`verify.sh` — a watch-only session
receives another session's broadcast over SSE). Subscriptions materialise at
session init (Go parity), so a watch-only session is subscribed from load.
`27-multi-session-chat` stays blocked only on the unrelated `Db.getString`-on-
`any`/Dict-row codegen gap, not on pub/sub.

### Rust-vs-Go perf gate (`scripts/rust-perf.sh`)

The perf harness benchmarks both backends of any example across all three
app shapes — **cli**, **server**, **live** — on cold-start, throughput (`ab`),
peak RSS under load, and binary size, gating the Rust/Go ratio against the
committed envelope in `scripts/rust-perf.thresholds`. It discovers the bound
port from the spawned process (no env dictation), `timeout`-bounds every probe,
and tolerates measurement noise (re-roll on fail; SKIP a missing reference).

```bash
scripts/rust-perf.sh 01-hello-world        # gate one example (shape auto-detected)
scripts/rust-perf.sh --baseline            # re-derive thresholds over the triplet
```

Committed envelope (`scripts/rust-perf.thresholds`, Rust as a fraction of Go;
lower is better except throughput): binary size **≤ 2%**, RSS **≤ 15–19%** by
shape, CLI cold-start **≤ 20%**, throughput **≥ 88%**. The `live.rss` envelope +
the SSE patch-latency leg are pending a re-baseline on a quiet (non-swapping) host.

### Top-level `examples/[0-9]*` on `--target rust`

Build-level via `scripts/rust-sweep.sh` (32/32 in-scope examples build) — covering
CLI, FFI, `Std.Db`/`Auth`/`Config`, Sky.Http.Server, Sky.Live, Sky.Tui,
Sky.Webview, and the multibackend entry model (`24-tui-kitchen-sink`).

**Out of scope** (`OUT_OF_SCOPE` in `rust-sweep.sh`): `02 03 05 06 08 11 13 25 27
29 34 36 37 38`:

- Go-package→Rust-native FFI (`02, 03, 05, 08, 13`): import gorilla/mux,
  stripe-go, google/uuid, godotenv — refused clean at canonicalise (Rust FFI
  targets Rust crates; see the **Project status** table, 🚫 Go-package row).
- `11` Fyne GUI; `06` JSON-pipeline decoder (the `Box<dyn FnOnce>` chain).
- `27` multi-session-chat — blocked on the `Db.getString`-on-`any`/Dict-row
  codegen gap, not on pub/sub.
- composite multi-app `34, 36, 37, 38` — need anon-struct field-method access,
  not yet emitted; `25/29` are console/spike shapes covered by the dedicated
  `runtime-rust/tests/sky/` fixtures.

---

## Soundness, correctness and security problems

A living, **attributed decision ledger**. Every soundness / correctness /
security finding surfaced by `sky-rust-backend:quality-audit` is recorded here
with a dated developer decision — *agreed* (consciously accepted) or *disagreed*
(fixed now, or deferred for investigation). Nothing stays in limbo; nothing is
buried in code. When a problem is eliminated, its row is deleted.

**How a decision is recorded.** For each material finding the audit presents the
*why* + *pros/cons* and asks the developer to agree or disagree:

- **Agreed** → `Accepted · <developer> · <date>` + the why (it's irreducible, or
  the cost/risk of fixing outweighs the cost/risk of accepting).
- **Disagreed** → a fix is brainstormed + implemented now (then the row is
  deleted), **or** `Deferred · <developer> · <date>` for investigation —
  resurfaced on every subsequent audit, never silently dropped.

Only *material* findings (real non-test panic vectors, undocumented `unsafe`,
unsound `dyn Any`, undocumented `#[allow]`, security/correctness/efficiency
defects) get a ledger row. Cosmetic lints are triaged in bulk and documented
inline at the call site.

**Code-level mirror.** Every ledger row is mirrored by an inline
`// SKY-RUST-AUDIT:ACCEPTED|DEFERRED (<dev>, <date>) — <why> [ledger #N]` marker at
the exact site, so a decision is visible while *reading the code* and the next
audit reconciles against it. `grep -rn 'SKY-RUST-AUDIT' runtime-rust/src` lists
every settled decision; `…:ACCEPTED` the accepted compromises; `…:DEFERRED` the
known-issues backlog.

### Decision ledger

| # | Problem (location) | Disposition | Developer · Date | Marker | Why |
|---|---|---|---|---|---|
| 1 | `crypto.rs` HMAC `expect_used` (×2) | Accepted | baseline · panic-hardening pass | `crypto.rs:66,82` | `Hmac::new_from_slice` is infallible; the pure Sky kernel has no `Result` channel; a fallback MAC would be a silently-wrong hash (security defect) — detail below |
| 2 | `email.rs` `hmac_bytes` `expect_used` | Accepted | baseline · panic-hardening pass | `email.rs:321` | same — a fallback MAC is a wrong SES signature |
| 3 | `ffi_polyfills.rs` `panic` (×2) | Accepted | baseline · panic-hardening pass | `ffi_polyfills.rs:26,42` | statically dead for valid Sky; the unconstrained generic `T` return has no total value to synthesise |
| 4 | `dyn Any` sites (pubsub broker, cache store/value) | Accepted | task #44 · 2026-06-12 | `pubsub.rs:85` · `cache.rs:57,70` | each `TypeId`-/`K`-keyed, correct-by-construction; the payload travels as its real type and is never erased — detail below |
| 5 | `unsafe` `pre_exec` (`PR_SET_PDEATHSIG`) | Accepted | Arthur Maciel | `live/console_proxy.rs:155` | `cfg(linux)` orphan-guard; the closure only calls `prctl` (async-signal-safe) between fork and exec, off any Sky value path; failure non-fatal. No safe stdlib API delivers a parent-death signal — detail below |

### Deferred for investigation

_None._

### Detail — accepted `#[allow]` / panic vectors

The clippy gate denies the panic-prone lint family on **non-test library code**:

- `unwrap_used` / `expect_used` — `Cargo.toml [lints.clippy]` + `clippy.toml`
  (`allow-*-in-tests`).
- `indexing_slicing` / `panic` / `unreachable` — `src/lib.rs`
  `#![cfg_attr(not(test), deny(…))]` (test code, incl. the separate `tests/`
  crates, is exempt by construction).

The **only** `#[allow]`d exceptions are 5 irreducible sites:

| Site | Allow | Why unreachable | Why no total alternative |
|---|---|---|---|
| `crypto.rs` `crypto_hmac_sha256` | `expect_used` | `Hmac::new_from_slice` never returns `Err` (HMAC accepts any key length) | pure Sky kernel `hmacSha256 : String -> String -> String` — no `Result` channel without breaking Go parity; no infallible HMAC constructor; a fallback MAC would be a silently-wrong hash (security defect) |
| `crypto.rs` `crypto_hmac_sha512` | `expect_used` | same | same |
| `email.rs` `hmac_bytes` | `expect_used` | same | internal SES-signing helper returning `Vec<u8>`; a fallback MAC would be a wrong signature |
| `ffi_polyfills.rs` `ffi_call_pure_polyfill` | `panic` | statically dead for valid Sky (the codegen peephole resolves the static-dispatch shape); this is the dynamic-dispatch fallback | returns an unconstrained generic `T` — no total value can be synthesised |
| `ffi_polyfills.rs` `ffi_call_task_polyfill` | `panic` | statically dead for valid Sky (the codegen peephole resolves the static-dispatch shape); this is the dynamic-dispatch fallback — same boundary as `ffi_call_pure_polyfill` | returns an unconstrained generic `T` — no total value can be synthesised |

**The one `unsafe` block** (`live/console_proxy.rs`, ledger #5) is the
`#[cfg(target_os = "linux")]` `Command::pre_exec` that calls
`prctl(PR_SET_PDEATHSIG, SIGTERM)` so the proxied console child dies when the
parent is SIGKILL'd / OOM'd (a path no signal handler can catch). The closure
runs in the forked child before exec, calls only an async-signal-safe libc fn (no
alloc, no locks, no Rust-runtime re-entry), and its failure is best-effort
hardening — no Sky value flows through it. No safe std API exposes a
parent-death signal, so the `unsafe` is irreducible.

Everything else in the crate is panic-vector-free: lock-family unwraps use
`unwrap_or_else(|e| e.into_inner())` (poison-tolerant — a panicking session
can't cascade-abort the others); AES/ChaCha propagate `new_from_slice` errors
into their existing `SkyResult` channel; the cookie-sid lookup degrades an
impossible `None` to a fresh session; the SSE response builder falls back to a
500 rather than `unwrap`; every slice/array access uses `.get(...)` /
iterators / a checked total form rather than `[i]`.

### `dyn Any` register

A full sweep of `src/sky_runtime/**` found the `dyn Any` sites below. There are
**no reducible** ones — each is irreducible-by-design (forced by a Sky kernel
signature that erases a type the runtime must round-trip), and each downcast is
correct by construction:

| Site | Shape | Verdict |
|---|---|---|
| `live/pubsub.rs` broker registry | `Box<dyn Any + Send + Sync>` → `Arc<Broker<T>>`, keyed by `TypeId` | **irreducible-by-design** — only an `Arc<Broker<T>>` is ever stored under `TypeId::of::<T>()`; never payload-dependent. The payload travels as its real `T`, never erased — only the broker *container* is. The single `downcast_ref` is `TypeId`-gated; its structurally-impossible `None` degrades gracefully (logs + fresh broker, never panics). |
| `cache.rs` per-handle store | `Box<dyn Any + Send>` → `Vec<CacheEntry<K>>` | **irreducible-by-design** — the Sky `Cache_size`/`Cache_clear` kernels carry no `V`, so the per-handle store can't be fully `(K,V)`-typed. Downcast by `K` (every op on a handle uses the same `K`, per Sky's `Cache k v`) — can't fail; mismatch → no-op. Keys matched by `PartialEq` (linear), avoiding any `Eq`/`Hash` bound-threading. |
| `cache.rs` cache value | `Box<dyn Any + Send>` (one per entry) → `V` | **irreducible-by-design** — `Cache_remove` carries no `V`, so values are erased and downcast to `V` only on `get` (where the kernel return makes `V` available). Per-handle `V`-consistency makes the cast total; on the impossible miss it returns `Nothing`, never panics. Strictly safer than Go's reflect cache (the cast cannot fail). |

The codegen itself emits **no** `dyn Any` — all Sky dynamism (`any` payloads,
`Db.get*` rows, FFI) is monomorphised to concrete types or routed through a
trait (`SkyRow`), per the no-erasure rule. If a future feature introduces a new
`dyn Any`, add a row here with its reduction verdict.

Worth noting (not a ledger row): `html.rs` `OnRaw(String, Arc<dyn Any + Send +
Sync>)` is an opaque event payload **only ever passed through**, never
`downcast` in Rust — no cast, no failure mode.

> **⏳ Future review (after the backend stabilises).** Re-examine every entry for
> reducibility. In particular `#4` (`dyn Any`): if the codegen ever monomorphises
> the pub/sub payload type or the cache K/V into generated code, the registries
> could drop `Any` entirely.

### Panic-vector gate coverage

`indexing_slicing` / `panic` / `unreachable` are gated on non-test library code;
the only `#[allow]`d sites are the 2 `ffi_polyfills` panics (above). All non-test
slice/array indexing uses total `.get(...)` / iterator forms. `unwrap`/`expect`
are gated separately via `Cargo.toml [lints.clippy]`.

---

## Module structure

```
runtime-rust/src/sky_runtime/
├── config.rs         GENERATED per sky.toml driver — DbPool/DbRow/SKY_DB_URL + driver helpers
├── core.rs           SkyResult/SkyMaybe/SkyTask, list/string/float helpers, byte FFI coercion
├── task.rs           succeed/map/and_then/on_error/fail/perform/sequence/run/parallel
├── tea.rs            shared TEA loop (SubManager/spawn_subs) for the Cli/Tui drivers
├── log.rs · system.rs · time.rs · random.rs · file.rs · io.rs
├── crypto.rs         random_bytes/token + sha/hmac/RSA/AEAD (aes-gcm, chacha20, pbkdf2)
├── jwt.rs · json.rs · encoding.rs · regex_kernel.rs
├── decimal.rs · money.rs · math.rs · dict.rs · string.rs · basics.rs · list.rs · char_kernel.rs
├── db.rs             Std.Db CRUD over sqlx (sqlite/mysql/postgres)
├── auth.rs           Std.Auth — bcrypt + jsonwebtoken + sqlx
├── compression.rs · csv.rs · uuid_kernel.rs · config_decode.rs · email.rs · trace.rs
├── http_client.rs · http_stream.rs   Sky.Core.Http client + Sub-tier/relay stream
├── server.rs · server_stream.rs      Sky.Http.Server routes + server-side SSE/chunked
├── ws_client.rs      Sky.Core.WebSocket client
├── webview.rs        Sky.Webview stub floor (+ feature-staged wry/tao window)
├── ffi_polyfills.rs  Ffi.callPure/callTask/toAny polyfills (statically-dead dynamic fallback)
├── cache.rs          Std.Cache — per-handle TypeId/K-keyed store (the dyn Any ledger #4 site)
├── telemetry.rs · telemetry_spill.rs  in-RAM rings + WAL spill (console data plane)
├── html.rs           Html/Attribute/Event<M> + assign_sky_ids (keyed) + render_html (shared)
├── ui/               Std.Ui Element bridge (element.rs) — shared layout type
├── tui/              Sky.Tui (feature `tui`): app/cell/diff/focus/key/layout — Element → cells
├── live/             Sky.Live (feature `live`)
│   ├── diff.rs       Patch (Go wire schema) + faithful diff (keyed sky-id, events, mixed-text)
│   ├── dispatch.rs   HandlerIndex<M> + resolve(sky-id, event, args) / resolve_form
│   ├── form.rs       decode_form::<T> / decode_form_or_warn
│   ├── route.rs      Route<Page> + match_routes / match_params (Go matchRoute parity)
│   ├── req.rs        LiveReq + builder (canonical headers, cookie parse)
│   ├── store.rs      SessionStore trait + Memory / Sqlite / Postgres / Redis + choose_store
│   ├── sse.rs        SsePatch / channel / frame (text/event-stream)
│   ├── pubsub.rs     per-payload-type Broker<T> keyed by TypeId (no erasure)
│   ├── hub.rs        hub read kernels — generic-over-return-type StateStore decode
│   ├── console.rs · console_proxy.rs   separate-process console + reverse-proxy + orphan-guard
│   ├── observability.rs · push_exporter.rs · hub_exporter.rs   auto-instrument + OTLP/JSON push
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
(soundness-gated: primitive-numeric `Into`/`From` resolve at identity only);
**builder setters** — `&mut self -> &mut Self` and in-place `&mut self -> ()`
methods are exposed as owned-threading wrappers (`fn(recv, args) -> recv`),
recovering the *configuration* surface of builder-pattern crates (csv
`ReaderBuilder` +12, `WriterBuilder` +10, url `set_path`/`set_query`/…); a
by-value `-> Self` (e.g. `Bytes::split_off`, returns a new value) is left on the
normal path; **lifetime-elided copies** — `&'a str`/`&'a [u8]`/`&'a OsStr`/
`&'a Path` are kept as owned copies (the lifetime token is an elision artifact);
**`Option<T>` params** — `SkyMaybe<T>` bridges to `Option<&str>` (`.as_deref()`),
`Option<u16>` (`.map(|x| x as N)`), `Option<&T>` (`.as_ref()`), else identity
(unlocked the whole `url` crate's `set_*` surface); **absolute `::<crate>`
paths** — every extern-crate reference is emitted `::csv::…` (no `use crate::*`
glob shadowing) so a crate named like an unsuffixed kernel module (`csv`/`time`/
`log`/`json`/`config`/`email`/`html`) no longer collides (`csv`: 116 errors → 0);
**`Maybe<opaque>` params** — the owned inner type comes from the `Option<&T>`
override (`SkyMaybe<::crate::T>`, not the lossy `SkyMaybe<String>`);
**glob-re-export qualification** — types defined in a private submodule and
glob-re-exported at the crate root (regex's `RegexBuilder` in private
`builders::string`) are recorded at the usable public path (regex: 3 → 104 fns,
+48 setters); **submodule name disambiguation** — same-named types in different
submodules get distinct Sky names from their qualified path (`regex::Regex` →
`Regex`, `regex::bytes::Regex` → `BytesRegex`) so neither variant is dedup-dropped;
**builtin name disambiguation** — a crate root type whose bare name equals
a Sky builtin (`bytes::Bytes` vs the builtin `Bytes` → `Vec<u8>`) is crate-prefixed
(`BytesBytes`) so it resolves to the crate type, not the builtin; **Sized gate**
— an instance method whose receiver type is never produced by value anywhere
(`bytes::buf::UninitSlice`, a DST) is dropped (its by-value `arg0` can't compile),
excluding static methods / `to_string` bridges / self-returning setters.

Drop-reason measurement: the inspector's **`--audit`** flag tags every
tail-filter `return None` (lifetime / result_borrow / array_slice) with reason +
constructable-or-not + offending type, then prints a per-crate histogram to
stderr (diagnostic only; bindings JSON unchanged). It measured element coercion
at 1/2552 functions (closed as a sound floor) and redirected effort to the
builder/handle class.

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

## Disk hygiene

Cargo `target/` dirs accumulate fast — a full example sweep can exceed 20 GB.
The sweep idiom deletes each example's target right after building:

```bash
for d in runtime-rust/tests/sky/*/; do
    (cd "$d" && rm -rf sky-out .skycache .skydeps \
        && /home/arthur/Documentos/comp/sky/sky-out/sky build src/Main.sky \
        && rm -rf sky-out/Rust/target)
done
```

Manual reclaim: `rm -rf runtime-rust/target tools/sky-ffi-inspect-rs/target
~/.cache/sky` and `find runtime-rust/tests/sky -type d -name target -exec rm -rf {} +`.
Leave `~/.cargo/registry` and `~/.cargo/git` alone (global, slow to rebuild).

---

## Known limitations

| Limitation | Description | Workaround |
|---|---|---|
| `any` in record fields | Codegen refuses `Box<dyn Any>` — structured `error[Rust]: any-typed record field` diagnostic | Encode as an ADT upstream, or ship a Rust-target override at `runtime-rust/sky-stdlib-overrides/<Module>.sky` |
| `Task.retryWith` run-once | Rust `SkyTask` is a one-shot `Future` (not `Clone`, consumed on await) **by design** — the totality floor; Go's re-runnable `func() any` thunk is what the loop re-calls. The faithful fix needs a thunk-shaped `retryWith` in the shared stdlib (forbidden) and is unverifiable in pure Sky; run-once is observably correct for Ok-first / last-Err / `RetryWhen` short-circuit | Drive the retry loop in Sky (recurse on the `Result`) |
| `withTransaction` rollback isolation | sqlx pool may route body queries to other connections | `sqlx::Pool::max_connections(1)` for guaranteed rollback |
| Bytes non-ASCII *text* base64/hex | Lossless on ASCII / hex / binary (byte-identical to Go); differs from Go only when a `Bytes` value holds literal non-ASCII *text bytes* compared against a Go-/externally-computed encoded string — a shape the byte-buffer contract discourages | Compare decoded values rather than encoded strings |
| `rustdoc` needs nightly | Inspector runs `cargo +nightly rustdoc` | `rustup install nightly` |
| Un-nameable bindings dropped | Generics, borrowed-view returns, lifetime-bound handles, std types, unsafe fns skipped (builder setters / `Option<T>` params / glob re-exports are recovered) | Use a wrapper crate with owned/primitive signatures |

Open work is tracked in the **Project status — single source of truth** table at
the top of this file.
