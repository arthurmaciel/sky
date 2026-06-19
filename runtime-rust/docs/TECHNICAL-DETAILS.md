# Sky Rust backend — technical details

Deep internals for the Sky → Rust backend (`feat/runtime-rust`). The user-facing
intro, usage, FFI usage, static-compilation guide, and the examples/static tables
live in [`../README.md`](../README.md). History lives in [`PROGRESS.md`](PROGRESS.md).

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

The `sky_runtime` crate is the **single source of truth** for all Rust code
emitted by the Sky compiler's `--backend rust` path. Every generated project
copies this crate's modules into `sky-out/Rust/src/sky_runtime/` at build time.

---

### Rust vs Go backend — divergent implementation strategies

Where the Rust backend deliberately implements something **differently** from Go,
the **why** is recorded here. The Go backend is the reference, but parity is about
*observable behaviour*, not internal mechanism — and Rust's no-`Any` /
no-panic-vector constraints (plus the absence of reflection) sometimes make a
different mechanism the *correct* one, not a shortcut.

> **Before scoping any "Go-parity" work, re-verify what Go *currently* does**
> (read `runtime-go/rt/` + `docs/` + the latest refactor commit). Go evolves; a
> stale parity premise wastes work.

### Console serving — pre-built separate process

The console runs as a **pre-built** separate process behind a reverse-proxy. The
console binary is compiled at the user's `sky build` time (a sibling binary); at
runtime the parent `exec`s it and proxies `/_sky/console/*` — no runtime build, no
toolchain on the VM, ~5 MB RSS. Go runs its console **in-process** (links the
bundled console into the user's binary). Two Sky programs in one Rust crate would
collide on every generated type (`StateModel`/`StateMsg`/…), needing codegen
type-namespacing Rust has no reflection to shortcut; separate binaries have zero
type collision and full fault isolation.

- **Proxy convention — STRIP.** The browser reaches the console child only through
  the parent proxy (the child binds `127.0.0.1`), so the parent **strips**
  `/_sky/console` before forwarding and the child's router stays byte-identical to
  a standalone Live app. `SKY_LIVE_BASE_PATH` affects rendered **output** URLs only
  (via `<meta sky-base>`/`__SKY_BASE`, which `client.js` prefixes onto
  `/_sky/event` + `/_sky/sse`), never routing. The session cookie is de-collided
  per sub-app — a base-derived **distinct name** (`sky_sid__sky_console`) +
  base-scoped `Path` — so the proxied child can't clobber the parent's `sky_sid`.
- **Child lifecycle.** The parent traps SIGTERM/SIGINT, reaps the child, then exits
  `128+signum` (trapping alone would make the parent unkillable-by-SIGTERM). On
  Linux the child additionally gets `PR_SET_PDEATHSIG=SIGTERM` (via `pre_exec` +
  `libc`) so it dies even when the parent is SIGKILL'd / OOM'd.
- **reqwest is a Std.Live dependency.** The live runtime's reverse-proxy forwards
  via reqwest, so codegen declares reqwest for **every** Live app (`usesHttp ||
  usesEmail || needsLive`).
- **Console pre-build is fingerprint-validated.** The Rust backend is dev-only (the
  runtime is sourced from disk, never embedded), so `SKY_VERSION` is always
  `"dev"` and a version-only cache would never invalidate. `Sky.Build.Rust.Console`
  validates the cache by a content fingerprint (sha256 of the console source + the
  runtime `.rs`), rebuilding on any change.
- **`--backend rust` ignores `[go.dependencies]`.** Go FFI bindings are inert on the
  Rust backend (it can't link Go), so `regenMissingBindings` short-circuits — a
  pure-Rust build needs no `go` toolchain even when the project declares Go deps.
- **Observability export is OTLP/JSON, env-gated, inert by default.** Federation
  push (`SKY_PARENT_URL` → parent ingest) and the remote HubExporter
  (`SKY_CONSOLE_HUB` → `/v1/{logs,traces}` OTLP/**JSON** + bearer + bounded retry
  spool) mirror Go's behaviour; OTLP's JSON encoding means no protobuf dep.
- **Console telemetry data flow — push-to-local-collector.** Rust's console is a
  SEPARATE process and can't read the app's in-RAM rings, so the data path is the
  industrial push-to-collector model applied locally: the app auto-instruments each
  HTTP request into its in-RAM rings (a span + an access log via
  `observability::track`); a **lean** app (no sqlx) **pushes** that telemetry to the
  console child — the *local collector* — which ingests, writes its SQLite store,
  reads it back through the hub read kernels, and serves the UI; a **db** app instead
  writes the spill directly and the child only reads it (`parent_spill_active()`
  selects the path). Every Live app stays lean (no SQLite embedded just to get a
  console). The console shows the PARENT's telemetry; a sub-app does not
  self-instrument.

### Hub read kernels (console data plane) — generic-over-return-type

Each `hub_read_*<A: DeserializeOwned>(…) -> SkyTask<E, A>` is **generic over its
return type**: it builds a `serde_json::Value` matching the record's camelCase
serde shape and `from_value::<A>`s it. The project-generated `State*` records are
named only at the **call site**, where `A` is inferred from the concrete
`StateStore` field types — no turbofish, no `Any`, no downcast. (Go's `Hub_read*`
return `any` narrowed by `rt.Coerce` reflectively.) The value travels as its real
type `A`; the one `serde` decode is provably-shaped because the kernel owns both
the SELECT and the `Value`. (`live/hub.rs`.)

### Telemetry spill — one schema end-to-end · WAL + `mode=rw` reader

The embedded console uses **one** schema end-to-end (the hub
`service_name/time/trace_id/…` schema) for both the writer
(`telemetry_spill.rs`) and the reader (`live/hub.rs`). Go uses two (a leaner
per-app spill plus the hub schema); the Rust spill is an internal writer↔reader
contract, so a single source of truth is the richer one the console records need.
The spill is WAL (concurrent parent-writer + console-reader without livelock), and
the console reader opens `mode=rw`, not `mode=ro`: a `mode=ro` connection can't
attach `-wal`/`-shm` shared memory and silently reads stale/empty data; `mode=rw`
participates in WAL and sees all committed writes (the console only ever `SELECT`s).

### Pub/Sub broker — per-type `Broker<T>` keyed by `TypeId`

One `Broker<T>` per payload type, keyed by `TypeId`. The payload travels as its
real `T` and is **never downcast**; a publisher/subscriber type mismatch can't
construct. (Go passes payloads as `any`, type-asserted on receive.) Mirroring Go's
reflect/`any` risk surface would be a defect, not parity. (`live/pubsub.rs`.)

### Sky.Live `init` request — typed-record `LiveReq`

`req` is a typed-record `LiveReq` (`path`/`query`/`method`/`params`/`headers`/
`cookies`); the kernel type stays free so it's Go-safe on the shared seam. Go uses
a heterogeneous `Dict`/`any` map. A typed record keeps the no-`Any` invariant on
the request path. (`live/req.rs`.)

### Closure-holding Model serialization — compile-error guard

A Model field that is a callback-record (fn fields lowered to `Arc<dyn Fn>`)
derives `Clone` + a generated `Default` (disconnected error closures) and
`#[serde(skip)]`s the field; persisting such a Model to a real store is designed to
be a **compile error**. (Go reflectively serializes a session Model, skipping func
fields at runtime.) An un-restorable closure can't silently round-trip through a
session store; the type system rejects it instead of a runtime surprise.


### Multibackend program-entry model

A `main` may pick its UI backend at runtime and run it, sharing one
`init`/`update`/`subscriptions` across backends:

```elm
main =
    case List.head argsList of
        Just "live" -> Live.app { …, view = viewLive, routes, notFound } |> Task.run
        _           -> Tui.app  { …, view, onKey } |> Task.run
```

The codegen treats *any* backend driver future as the program entry, uniformly.
Three rules:

1. **`Task.run` on a backend-entry app-future is dropped.** `Live.app {…}` /
   `Tui.app {…}` / `Tui.program {…}` / `Webview.app {…}` each lower to a
   `SkyTask<()>` driver future. `App {…} |> Task.run` (or `Task.run (App {…})`)
   drops the `Task.run` *anywhere* — top-level OR inside a `case` arm — so the
   future is returned as a `SkyTask` (the entry `block_on`s it / a dispatching
   `case` unifies as `SkyTask<()>`), never executed inline via `task_run`.
2. **`mainIsTask` derives from `usesBackendApp`** (`usesLive || usesTui ||
   usesWebview`), not `usesLive` alone — so a pure-Tui / pure-Webview `App {…} |>
   Task.run` main returns `SkyTask` and is `block_on`'d.
3. **`init`'s param is derived from its Sky type, adapted per call site.** Only a
   *req-reading* init (`init req = … req.path …`, detected by
   `collectLiveReqInitFns`: param 0 binds a var used in the body) pins param 0 to
   `sky_runtime::LiveReq`. A *non-req* init (`init _`) is forced to `()` and adapted
   at the `Live.app` call site via `move |_r: LiveReq| init(())` — so the SAME init
   can also feed `Tui.app` (bound `Fn(())`). No global pin; no Tui-side change;
   every Live example's `init` body is byte-identical so the rendered HTML is
   unchanged.

`Cli.program` is intentionally excluded from the backend-entry set: it runs inline
via `task_run` (not in `usesBackendApp`), so its `Task.run` is kept.


### Std.Ui parity (byte-identical render)

`Std.Ui` is pure Sky source that builds a `Std.Html` ADT, serialised by `html.rs`
`render_html` — so parity is a **codegen-lowering + serializer** problem, not a
renderer port. Each corpus fixture runs `main = Io.writeStdout (Html.toString
(Ui.layout [] view))` and the stdout is byte-diffed Go-vs-Rust (Go is the golden).
All corpus cases are byte-identical:

| Covers | Primitives |
|---|---|
| text | `layout` + `text` |
| layout | `row`/`column`/`spacing`/`padding`/`align` |
| styling | `Background`/`Border`/`Font` |
| sized | `button`/`link`/`image` (static) |
| advanced | nearby overlays · aspect-ratio · grid |
| semantic | `Region` tag + aria mapping |

The load-bearing mechanisms (all Rust-target only, Go untouched):

- **`any`-carrier resolution** — Std.Ui's wildcard `any` slots (and a user
  `view : Model -> any`) resolve to the concrete `Html<msg>` / `Attribute<msg>`
  carrier; no `dyn Any`.
- **Whole-program DCE** — dep modules prune to the reachable-from-`main` set, so a
  one-line render emits 60 Std.Ui fns not 205.
- **Injective fn-name mangling** — `Std.Ui.borderRounded` vs `Std.Ui.Border.rounded`
  don't collide under `toSnakeCase`.
- **Serializer alignment** — `render_html` sorts attrs, renders `BoolAttr` as
  `k="true"`, and self-closes void elements with ` />`, matching Go `renderVNode`.
- **`onSubmit` form-event peephole** — `Ui.onSubmit DoSignIn` inlines to a typed
  `decode_form::<T>` dispatch.

Event *dispatch* (onPress/onSubmit) and the style-injection features (pseudo-class
/ media-query / transition / animation) render through Sky.Live's VNode path,
covered by the integration apps rather than the static corpus.

### Modification boundaries

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

Shared compiler files keep only a minimal `case Toml._target of { TargetRust -> …;
TargetGo -> … }` dispatch seam. Dependencies are one-way (shared → Rust-only), so
the Go path stays byte-identical and upstream merges stay small.

**One shared file carries Rust-only inspector fields: `src/Sky/Build/FfiGen.hs`.**
The inspector-JSON decode type `FnInfo` (and its single Aeson `FromJSON`) lives
there and is used by both backends, so a Rust-only field can only be *decoded*
there. Every such field defaults (`""` / `False`), the Go inspector never emits it,
and no `src/Sky/Generate/Go/` code reads it → Go output byte-identical. Adding a
Rust-only `FnInfo` field is the one sanctioned shared-file touch; new *behaviour*
still goes behind `TargetRust ->` seams.


### Cross-backend rules (load-bearing)

Go is the **production backend**; Rust is second-tier.

1. **Go FFI artifacts stay at the root of `.skycache/ffi/`** —
   `<slug>.{kernel.json,skyi}`.
2. **Each non-Go backend gets its own subdir** — Rust at `.skycache/ffi/rust/`.
3. **`loadAndSeedFfiRegistry` reads target-appropriate paths** — go = root, rust =
   `rust/` subdir.
4. **Never touch Go-generated files** — `runtime-go/`, root `.skycache/ffi/*`,
   `src/Sky/Generate/Go/`.
5. **Never change shared compiler code in a way that could break Go** — new Rust
   functionality goes behind explicit `TargetRust ->` branches.
6. **`sky add` routing:** URL → `[rust.dependencies]` as `{ git = … }`; bare name →
   crates.io via `cargo fetch`.

**T1 guard.** The Go reference for `00-standard-libs` builds via a fork-local guard
in `src/Sky/Build/Compile.hs`: the synced tag carries an `undefined: T1` Go-codegen
regression (a callee-bound type var leaking into emitted Go); the guard erases the
unbound token to `any`. Without it `00`'s Go reference is broken (an upstream bug),
never a Rust failure. Reconcile the surgical guard against the upstream typed-codegen
rewrite when that lands.



## Verification state

### `runtime-rust/tests/sky/` — FFI + framework fixtures

The FFI / framework fixture set is 50+ Sky projects under
`runtime-rust/tests/sky/`, each building + running from a wiped slate. They cover:

- **Leaf FFI crates** (rand, num_cpus, chrono, uuid, roman, semver, bytesize, …) —
  free fns, static/instance methods, Display/FromStr, Option/Result, byte ⇄ `List
  Int`, generic-bound monomorphisation.
- **FFI reach** — `Option<&str>` param coercion, csv/regex/bytes name-collision
  handling, recovered builder setters, unsized-receiver gating.
- **Stdlib runtime** — `Std.Db` CRUD (sqlite/mysql/postgres), `Std.Auth`,
  `Std.Config`, `Std.Email`, `Std.Cache`, `Sky.Core.Char`/`Bytes`/`Task`, the
  streaming/relay surfaces.
- **App frameworks** — Sky.Live (static render, TEA-over-SSE, typed forms, URL
  routing, typed `LiveReq`, sessions, PubSub), Sky.Tui (Element → cells, key/focus
  input), Sky.Webview, Sky.Http.Server + WebSocket.
- **Codegen shapes** — Task-valued `if`/`case` branches at `main`, discard-Task
  effect ordering, curried function-valued returns, event-handler `Arc` capture,
  `List.sort`/`sortBy`/`sortWith`, bare-`any` record-field codegen rejection,
  static `Ffi.callTask` resolution, unannotated `Result` Ok-payload recovery,
  `errorToString` String/record parity, `Task.retryWith` transient-retry, and
  single-use non-`Clone` `SkyTask` capture-move.

`examples/rust/skyshop-rs` is the one real end-to-end Rust-FFI app (a 1:1 port of
`examples/13-skyshop` binding `firestore` 0.49 + `async-stripe` 1.0-rc.6 +
`rs-firebase-admin-sdk` 4.3 via fork-local wrapper crates; `verify.sh` is its
committed one-command check).

### Runtime unit tests

`cargo test --features full` passes, including the soundness suites
(`core_soundness`, `kernel_soundness`, `dict_determinism`) that assert no-panic +
sorted-iteration invariants under proptest, the Sky.Live diff/dispatch/form/store
tests (memory/sqlite + env-gated pg/redis restart-survival), and the pub/sub broker
fan-out / echo / SkipOrigin / per-type-isolation tests. The faithful view-diff and
the postgres/redis stores are covered here; generated postgres + redis live apps
are cargo-build-verified.

The per-example Go≡Rust parity table is the **Project status** sweep above.


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

The effect model: every effect kernel defers its I/O into the returned Task body,
so constructing a Task is pure and the side effect fires only on `.await`. Codegen
`task_run`s (block_on) a discarded Task-typed `let _ = <task>` in program order; a
non-Task discard (`_ = List.map …`, `_ = someVar`) keeps bind/drop. So a built-but-
discarded `List (Task ())` never runs — matching Go's deferred-Task semantics.

---

## Soundness, correctness and security

Every accepted compromise is recorded here with its rationale, and mirrored at the
exact site by an inline `// SKY-RUST-AUDIT:ACCEPTED — <why>` marker. The codegen
itself emits **no** `dyn Any`; all accepted sites are irreducible-by-design.
`grep -rn 'SKY-RUST-AUDIT' runtime-rust/src` lists every settled decision.

### Accepted compromises

| Problem (location) | Disposition | Why |
|---|---|---|
| `crypto.rs` HMAC `expect_used` (`crypto_hmac_sha256` / `crypto_hmac_sha512`) | Accepted | `Hmac::new_from_slice` is infallible (accepts any key length); the pure Sky kernel `hmacSha256 : String -> String -> String` has no `Result` channel, and a fallback MAC would be a silently-wrong hash (security defect) |
| `email.rs` `hmac_bytes` `expect_used` | Accepted | same — a fallback MAC is a wrong SES signature |
| `ffi_polyfills.rs` `panic` (×2: `ffi_call_pure_polyfill` / `ffi_call_task_polyfill`) | Accepted | statically dead for valid Sky (the codegen peephole resolves the static-dispatch shape); the dynamic fallback returns an unconstrained generic `T` with no total value to synthesise |
| `dyn Any` sites (pubsub broker, cache store/value) | Accepted | each `TypeId`-/`K`-keyed and correct-by-construction; the payload travels as its real type and is never erased — see the register below |
| `unsafe` `pre_exec` (`PR_SET_PDEATHSIG`, `live/console_proxy.rs`) | Accepted | `cfg(linux)` orphan-guard; the closure only calls `prctl` (async-signal-safe) between fork and exec, off any Sky value path; failure non-fatal. No safe stdlib API delivers a parent-death signal |

The clippy gate denies the panic-prone lint family (`unwrap_used` / `expect_used`
via `Cargo.toml [lints.clippy]` + `clippy.toml`; `indexing_slicing` / `panic` /
`unreachable` via `src/lib.rs` `#![cfg_attr(not(test), deny(…))]`). The
`#[allow]`d exceptions are exactly the irreducible sites above. Everything else is
panic-vector-free: lock-family unwraps use `unwrap_or_else(|e| e.into_inner())`
(poison-tolerant); AES/ChaCha propagate `new_from_slice` errors into their
`SkyResult` channel; the cookie-sid lookup degrades an impossible `None` to a fresh
session; the SSE response builder falls back to a 500 rather than `unwrap`; every
slice/array access uses `.get(...)` / iterators / a checked total form rather than
`[i]`.

### `dyn Any` register

Each `dyn Any` site is irreducible-by-design (forced by a Sky kernel signature that
erases a type the runtime must round-trip), and each downcast is correct by
construction:

| Site | Shape | Verdict |
|---|---|---|
| `live/pubsub.rs` broker registry | `Box<dyn Any + Send + Sync>` → `Arc<Broker<T>>`, keyed by `TypeId` | only an `Arc<Broker<T>>` is ever stored under `TypeId::of::<T>()`; the payload travels as its real `T`, never erased — only the broker *container* is. The single `downcast_ref` is `TypeId`-gated; its structurally-impossible `None` degrades gracefully (logs + fresh broker) |
| `cache.rs` per-handle store | `Box<dyn Any + Send>` → `Vec<CacheEntry<K>>` | the Sky `Cache_size`/`Cache_clear` kernels carry no `V`, so the per-handle store can't be fully `(K,V)`-typed. Downcast by `K` (every op on a handle uses the same `K`, per Sky's `Cache k v`) can't fail; mismatch → no-op. Keys matched by `PartialEq` (linear) |
| `cache.rs` cache value | `Box<dyn Any + Send>` (one per entry) → `V` | `Cache_remove` carries no `V`, so values are erased and downcast to `V` only on `get` (where the kernel return makes `V` available). Per-handle `V`-consistency makes the cast total; on the impossible miss it returns `Nothing` |

`html.rs` `OnRaw(String, Arc<dyn Any + Send + Sync>)` is an opaque event payload
**only ever passed through**, never `downcast` in Rust — no cast, no failure mode.


### Rust FFI

`sky add <crate> --backend rust` invokes `sky-ffi-inspect-rs`, which runs
`cargo +nightly rustdoc --output-format json` (so derive/proc-macro impls are
visible), maps Rust types → Sky types (`Vec→List`, `Option→Maybe`, `HashMap→Dict`,
`Result→Result E A`), and writes
`.skycache/ffi/rust/<slug>.{kernel.json,skyi,_bindings.rs}`.

- **Opaque types** are emitted fully-qualified by public re-export path
  (`chrono::NaiveDate`), so wrappers need only one root `use <crate>::*;`.
- **Nameability filter:** generic fns, lifetime-parameterised types, borrowed
  results, non-byte slices/arrays, `unsafe fn`, and private/std types are dropped so
  `_bindings.rs` always compiles. Byte sequences (`&[u8]`, `[u8; N]`, …) are kept
  and bridged to `List Int`.
- **Display/FromStr bridge:** opaque types implementing them get synthetic
  `to_string`/`from_string` bindings.
- **Method bindings disambiguate by receiver:** `Utc::now` → `now_from_utc`.
- **Inspector resolution:** `$SKY_FFI_INSPECTOR_RS` → `./bin/sky-ffi-inspect-rs`
  (ancestors) → TH-embedded binary at `~/.cache/sky/tools/`.

### Reach (what auto-FFI can/can't cover)

The boundary is type-theoretic, not a maturity gap: only `rustc` resolves Rust's
generics (monomorphised — no callable symbol until concrete), traits (open), and
lifetimes. So **leaf/data crates** (hashing, codecs, parsing, math, time, regex,
many client SDKs) auto-bind well; **frameworks** (axum, bevy, diesel, tokio) are
generic+trait+`Stream` at the core and auto-bind almost nothing usable. The
Sky-Rust strategy is **automatic FFI over the leaf universe + Sky-native modules
over frameworks** (the `Sky.Live` / `Sky.Http.Server` model — built on axum/hyper
internally, exposing a Sky-idiomatic surface). "Verbatim FFI to any framework" is a
deliberate non-goal.

The widenings that extend leaf-crate reach:

- **Generic-bound monomorphisation** — monomorphises generic fns whose bound maps to
  a Sky type (`AsRef<[u8]>`/`Into<Vec<u8>>` → `List Int`; `AsRef<str>`/`Display` →
  `String`); a recursive extension resolves nested `AsRef`/`Into`/`IntoIterator`
  inner types (soundness-gated: primitive-numeric `Into`/`From` resolve at identity
  only).
- **Builder setters** — `&mut self -> &mut Self` and in-place `&mut self -> ()`
  methods are exposed as owned-threading wrappers (`fn(recv, args) -> recv`),
  recovering the *configuration* surface of builder-pattern crates; a by-value
  `-> Self` is left on the normal path.
- **Lifetime-elided copies** — `&'a str`/`&'a [u8]`/`&'a OsStr`/`&'a Path` are kept
  as owned copies (the lifetime token is an elision artifact).
- **`Option<T>` params** — `SkyMaybe<T>` bridges to `Option<&str>` (`.as_deref()`),
  `Option<u16>` (`.map`), `Option<&T>` (`.as_ref()`), else identity.
- **Absolute `::<crate>` paths** — every extern-crate reference is emitted
  `::csv::…` (no `use crate::*` glob shadowing) so a crate named like an unsuffixed
  kernel module (`csv`/`time`/`log`/`json`/`config`/`email`/`html`) no longer
  collides.
- **Glob-re-export qualification** — types defined in a private submodule and
  glob-re-exported at the crate root (regex's `RegexBuilder` in private
  `builders::string`) are recorded at the usable public path.
- **Submodule name disambiguation** — same-named types in different submodules get
  distinct Sky names (`regex::Regex` → `Regex`, `regex::bytes::Regex` →
  `BytesRegex`).
- **Builtin name disambiguation** — a crate root type whose bare name equals a Sky
  builtin (`bytes::Bytes`) is crate-prefixed (`BytesBytes`).
- **Sized gate** — an instance method whose receiver type is never produced by value
  anywhere (a DST like `bytes::buf::UninitSlice`) is dropped.

Measure constructable surface per crate with the `sky-rust-backend:ffi-audit` skill.
The inspector's `--audit` flag tags every tail-filter drop with reason +
constructable-or-not for diagnostics.


### FFI codegen type-coercion rules

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

## Build performance & DX

Sky→Rust compiles the generated project with `cargo`, so the first build of an app
with heavy deps (tokio / axum / sqlx / a framework FFI crate) is a real Rust
compile. These strategies cut the *second* build to seconds — they change the build
*mechanism*, never the output:

| Strategy | What it buys |
|---|---|
| **sccache** (`RUSTC_WRAPPER=sccache`) | a shared compilation cache — each crate object is cached across projects + rebuilds, so the heavy dep tree compiles once machine-wide |
| **Shared `CARGO_TARGET_DIR`** | one target dir for every example → tokio/serde/sqlx/axum built once and reused, not recompiled per app |
| **Lean dev profile** | the generated `Cargo.toml [profile.dev]` already sets `debug = 0` + `incremental = true` (via `emitCargoToml`) |
| **Cached FFI bindings** | `.skycache/ffi/rust/*.{skyi,kernel.json,_bindings.rs}` are generated once; only `sky add` / `sky install` (or a wiped `.skycache`) re-runs the nightly-rustdoc inspector |
| **Compiler dev loop** | only codegen (`.hs`) edits need a `cabal build`; edits under `runtime-rust/src/` are copied into the generated project at `sky build` time → rebuild only the example |

Standalone runtime compile-check (fastest gate for `.rs` edits): `cargo check
--manifest-path runtime-rust/Cargo.toml --features full` (~1.2 s warm); `cargo build
--manifest-path runtime-rust/Cargo.toml --features full` (~2.4 s warm) when link
errors matter. `sky check` always runs the **Go** pipeline; it does not validate the
Rust codegen path — use `sky build --backend rust` for that.

The canonical inner loop (Sky source or runtime `.rs` change, no `.hs` edit): `sky
run --backend rust src/Main.sky` rebuilds + runs — ~0.3 s warm, ~1-2 s on first
change. A runtime-only `.rs` edit is re-copied into the generated project on the next
`sky run` (no wipe needed). Detailed env setup and the disk-hygiene recipe live in
`runtime-rust/CLAUDE.md`.

**Readable output.** The generated `sky-out/Rust/src/*.rs` is run through `rustfmt`
(per-file, `--edition 2021`, best-effort) before the `cargo build` — so the emitted
Rust reads like hand-written code when inspected. `SKY_RUST_FMT=0` skips it.

---


## Allocator 2×2 measurement (static builds)

**Measured** (alloc-stress fixture: allocation-heavy `Sky.Http.Server`, `ab -c50`;
2×2 linking × allocator):

| variant | throughput | peak RSS |
|---|--:|--:|
| A dynamic + glibc malloc | 1457/s | 8.5 MB |
| B dynamic + mimalloc | 2511/s (**1.72× A**) | 16.3 MB |
| C static(musl) + mimalloc | 2149/s (**1.48× A**) | 14.7 MB |
| D static(musl) + musl malloc | ~192/s (**0.14× A**) | 7.8 MB |

mimalloc is **1.72×** glibc on dynamic; **musl's own malloc is ~7× slower** than
glibc (~11× vs mimalloc) and it's **not** contention-driven (≈same at `-c4` and
`-c50` — musl malloc is just slow for high-volume small allocations). So
`--static` keeps mimalloc **default-on**; `--system-alloc` is an opt-out only for
RSS-constrained deploys (D is the leanest at 7.8 MB) and emits a loud cliff
warning. RSS stays bounded under sustained churn (C growth 1.024×).
