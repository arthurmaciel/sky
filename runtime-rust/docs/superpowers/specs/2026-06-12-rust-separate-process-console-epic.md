# Rust separate-process console — epic design

## Goal

Bring the Rust backend to true Go parity on the console: the bundled console
(`sky-bundled/console/src/`, a 10-module `Sky.Live` + `Std.Ui` app) **compiles +
runs on `--target rust`** and is **spawned as a child process**, reverse-proxied
at `/_sky/console/*` by the parent app — replacing the in-process hand-written
plain-HTML shell (`live/console.rs`). This gains the architectural advantages of
Go's design: the console is itself a Sky app (dogfooding, full framework reuse),
fault isolation (a console bug can't crash the user's app), and a path to
multi-service hub federation.

This is an **epic** spanning multiple sub-projects, each with its own plan →
implement cycle. This doc is the decomposition + architecture + sequencing; each
sub-project gets a focused spec/plan when it starts.

## Spike findings (2026-06-12)

Building `sky-bundled/console` on `--target rust` lowers cleanly but yields **128
cargo errors / 7 classes**, reducing to three root causes:

1. **The `Hub` kernel module is missing on Rust (14 fns)** — `hub_read_{logs,
   errors,traces,metrics,overview,service_stats}`, `hub_read_filtered_*`,
   `hub_list_services`, `hub_current_identity`. The console's data layer reads
   from the hub. The biggest piece.
2. **"Record of N callbacks" codegen pattern unsupported** — `StateStore` /
   `HubStore` are records of ~11 `Arc<dyn Fn>` fields. Codegen mis-handles them:
   field-accessor methods not generated (`E0599`), closures capture by ref not
   `move` with per-field pre-cloned captures (`E0597`/`E0277` `'static`), a
   `PartialEq` derive lands on an `Fn`-field struct (`E0369`), `curry9`/`curry10`
   constructor helpers not emitted.
3. **Stdlib mapping gaps** — `string_left` (String.left), `json_dec_p_custom`
   (JsonDec.Pipeline.custom), `time_format_i_s_o8601` (a name-mangling bug:
   `formatISO8601` → `i_s_o8601`), `list_length`, `system_getenv_or`.

## The data model (resolved by the spike)

Go's embedded per-app console reads the **SQLite spill** (`SKY_CONSOLE_DB_PATH`;
SkyDeploy injects `/data/console.db`). So the Rust console's `Hub` read kernels
and the #69 write side are ONE data layer:

```
parent app runtime ──dual-write──> SQLite (SKY_CONSOLE_DB_PATH, WAL) <──read── console child (Hub_read*)
        │                                                                          ▲
        └────────────────── spawn + reverse-proxy /_sky/console/* ─────────────────┘
```

- **Write (parent):** runtime dual-writes telemetry to the SQLite file (#69 / D).
- **Read (console child):** `Hub_read*` kernels `SELECT … ORDER BY ts DESC LIMIT`
  from the same file (WAL → concurrent reader). `Hub_currentIdentity` reads the
  session identity (already shipped in Go v0.16.5; Rust scope TBD per sub-project).
- The central `console-serve` hub (OTLP receivers, multi-tenant aggregation) is a
  LATER, separate concern — the embedded console reads the local spill file.

## Decomposition (dependency-ordered)

| # | Sub-project | Root cause / scope | Depends on |
|---|---|---|---|
| **S0** | **Stdlib + codegen gaps** | spike #3 (stdlib maps + the `formatISO8601` mangling bug) + spike #2 (callback-record pattern: accessors, move-closures, no-PartialEq-on-Fn-struct, curry9/10). Pure in-boundary codegen; independently useful to ANY app. | — |
| **S1** | **`Hub` kernel module (read side)** | spike #1: the 14 `hub_*` kernels, reading the SQLite spill. Runtime (`live/hub.rs`, feature `db`) + codegen kernel maps + analyzer flags. | S0, D |
| **D** | **SQLite spill (#69)** | runtime dual-write + retention (write-only, Go runtime parity). The file S1 reads. | — (write side independent) |
| **A** | **Pre-built console child + reverse-proxy** | **Build the console binary at the user's `sky build` time** (shared cache, built once per sky version — NEVER at runtime), spawn it as a child, reverse-proxy `/_sky/console/*`, set the child's env (`SKY_LIVE_PORT`, `SKY_CONSOLE_HUB_DB` = parent's `SKY_CONSOLE_DB_PATH`, `SKY_LIVE_BASE_PATH=/_sky/console`), `SKY_LIVE_BASE_PATH` awareness, child lifecycle (kill on parent shutdown). Keep in-process `console.rs` as the no-spawn fallback. | S0+S1+D (a console to mount) |
| **C** | **Observability federation (PushExporter)** | sub-apps batch + push telemetry to the parent ingest (token gate done, #71). | A |
| **E** | **HubExporter (#70)** | remote OTLP push + spool (file/memory). | C |

**Verification of the whole epic:** unmodified `sky-bundled/console` builds + runs
on `--target rust`; the parent auto-mounts it at `/_sky/console`; the dashboard
renders live + history from the spill. Each sub-project re-runs the console build
spike to track the error count down.

## Sequencing + first sub-project

Build order: **S0 → (D ∥ S1) → A → C → E**. S0 is foundational (the console
can't compile without it) and pure in-boundary codegen, so it is the **first
sub-project**. It also drives the 128-error count down and re-reveals the true
remaining Hub surface for S1.

**S0 scope (first plan):**
- **Stdlib maps (mechanical):** add/fix the Rust kernel mappings for `String.left`
  → `string_left`, `JsonDec.Pipeline.custom` → `json_dec_p_custom`, `List.length`
  → `list_length`, `System.getenvOr` → `system_getenv_or`; **fix the
  `formatISO8601` → `i_s_o8601` name-mangling bug** (an acronym-splitting defect
  in the snake_case mangler — affects any `…ISO…`/`…URL…`-style name).
- **Callback-record codegen (the pattern):** for a record whose fields are
  function types lowered to `Arc<dyn Fn>`: (a) generate the field-access as a
  field read (not a method) OR generate accessor methods; (b) emit each field's
  closure as `move` with the captured outer vars pre-cloned per field
  (`{ let p = parent.clone(); Arc::new(move |…| …) }`); (c) suppress the
  `PartialEq`/`Debug` derive on a struct carrying `Fn` fields; (d) emit
  `curry9`/`curry10` (extend the curry-helper generator's arity range).

## Invariants (whole epic)

No Go change; no `Any` (the callback-record uses concrete `Arc<dyn Fn(Args) ->
SkyTask<T>>`, not `dyn Any`); no panic vectors (sqlx/proxy errors → structured
warn + graceful fallback, never `?`-into-500); feature-gated (`db` for spill/hub,
the in-process `console.rs` stays as the fallback until A lands); each sub-project
independently shippable + green on the example sweep.

## Progress (2026-06-13)

The closure-Model design decision (A+B) was approved by the user: a fn-field
struct derives only `Clone` + a generated `Default` (`disconnected_fnN` error
closures); a serde Model with such a field `#[serde(skip)]`s it + drops
Debug/PartialEq; persisting a closure-Model will be a compile error (B, not yet
emitted). Investigation #76 (does Go error on closure-Model + persistent store?)
deferred to post-parity.

**S0 DONE: console build errors 128 → 12** (commits 116970b3 … 35b1dcca). The
12 remaining are EXACTLY the S1 `hub_*` kernels (all `E0425` cannot-find-fn);
every codegen/stdlib/inference gap is closed.
- ✅ Stdlib kernels: `String.left/right`, `System.getenv/getenvOr`, `List.length`,
  `Time.formatISO8601` (+ Kernel.hs map fixing the `ISO`→`i_s_o8601` mangle),
  `JsonDec.Pipeline.custom`; `curry9/10`.
- ✅ Callback-record codegen (A1–A4): fn-field struct derive-Clone-only + Default
  via `disconnected_fnN`; serde-skip on Model fields; `(rec.field)(args)` call
  parens; move-closures with per-field capture clones (`closureCaptures`).
- ✅ `sky_list_cons` Clone-bound drop (move-only `Cmd.batch`).
- ✅ **Closure-param + ++-concat inference tail** (commit 35b1dcca, 24→12) — five
  app-agnostic fixes: `solveArgType` If/Case arms (Vec-preferring branch type) so
  `++` over `if c then [x] else []` keeps Vec-concat (E0308); `sky_core_list_*`
  added to the HOF element-forcing list so an ambiguous-field closure resolves to
  the list's element type not the field-set guess (E0308); `inferRecordClosureParam`
  wired as `annotClosureParam`'s fallback for let-bound stored-then-called closures
  (E0282); `listElemRustType` Call arm (peel a fn-returned `List e`); `inferParamRustType`
  `==`/`/=` arm (scalar param takes the compared field's type) (E0282).
- ⏳ **B compile-guard** (closure-Model + persistent store → compile_error!) not
  yet emitted — folded into S1/A (it only matters once the console actually
  persists; the console's session store is `memory`, so it is not blocking).

**S1 DONE: bundled console 12 → 0 errors — builds + boots + serves on
`--target rust`** (commits 19e8c9bb … 57768c24; plan
`runtime-rust/docs/superpowers/plans/2026-06-13-s1-hub-kernel-read-side.md`).
- ✅ `runtime-rust/src/sky_runtime/live/hub.rs` (`#[cfg(feature="db")]`) — all 12
  `hub_*` kernels, each **generic over the return type** `A: DeserializeOwned`
  (the `State*` records are project-generated; the call sites infer `A` from the
  concrete `StateStore` fields — no turbofish, no `Any`). Reads the SQLite spill
  read-only via sqlx; builds a `serde_json::Value` matching the record's camelCase
  serde shape; `from_value::<A>`. Full Go-parity row→record mapping (attrs→reqId,
  durationMs from RFC3339 start/end, error grouping, 60 s/30-bucket ServiceStat
  aggregation w/ p95+classifyStatus). Missing/unreadable DB → empty result + warn,
  never a panic/error (Go `getHubStore()==nil` parity). **15 unit tests green;
  clippy clean; no `unwrap`/indexing in any Sky-reachable path.**
- ✅ Codegen: no Kernel.hs map needed (the `Ffi.kernel "Hub_readOverview"` alias
  default-mangles to `hub_read_overview`). The only wiring is Walker flagging
  `usesDb=True` on a `"Hub_"`-prefixed kernel-name string → generated Cargo.toml
  gains the `db` feature → the kernels compile in.
- ✅ Acceptance: console binary boots, serves on its port, renders `Sky Console` /
  `Overview`. Full data render needs D (#69) to populate the spill.

**D DONE: telemetry SQLite spill (#69)** (commit 3f85c1f6). The parent dual-writes
every log + span to `SKY_CONSOLE_DB_PATH`; the console reads it via the S1 hub
kernels — read↔write loop closed.
- ✅ `runtime-rust/src/sky_runtime/telemetry_spill.rs` (`#[cfg(feature="db")]`):
  `enable_from_env` (WAL + busy_timeout + the **hub schema** S1 reads), a batcher
  task draining a bounded (1024) mpsc channel, an hourly 24 h TTL pruner.
  `offer_log/offer_span` are non-blocking `try_send`s (drop on full — never block/
  panic the hot path). `write_entry` maps to the hub schema (service_name from
  `SKY_SERVICE_NAME`, RFC3339 time, span durationMs, ok→attrs.status).
- ✅ `telemetry.rs` `record_log`/`record_span` call a cfg-dispatched spill hook —
  a no-op stub when `db` is off, so the always-compiled sink stays tokio/sqlx-free.
  Boot wires `enable_from_env().await` in the Live entry (db-gated).
- ✅ **WAL gotcha resolved:** the spill is WAL (concurrent parent-writer + console-
  reader without livelock); S1 `open_spill` switched `mode=ro`→`mode=rw` because a
  ro connection can't attach the -wal/-shm and never sees un-checkpointed frames.
  The console only SELECTs, so rw grants no real write.
- ✅ Deterministic test: `write_entry_maps_to_hub_schema` (also asserts S1
  `hub_list_services` reads the same file — the contract). 251/251 lib tests green.

**A architecture DECIDED (user, 2026-06-13): pre-built separate process + proxy.**
The console binary is compiled at the user's `sky build` time (a sibling/cached
binary, built once per sky version); at runtime the parent `exec`s it and reverse-
proxies `/_sky/console/*` — **never a runtime build**. Rationale (full version in
`runtime-rust/README.md` §"Rust vs Go — divergent strategies"): Go dropped its
v0.15.x subprocess console *only* because the child did a **runtime `go build`**
(OOM'd 1 GB VMs); a pre-built Rust binary doesn't incur that, so the rationale
doesn't transfer. Go's chosen in-process path is the *hard* one on Rust (two Sky
programs → generated-type collisions, no reflection to shortcut), so pre-built-
subprocess is the Rust optimum. **This corrects the epic's original "true Go
parity" framing — it is NOT current Go parity, but is the right Rust design.**

**Next: A** then **C** (federation) + **E** (#70 HubExporter). B compile-guard
still folded in (console store=memory).

## EPIC COMPLETE (2026-06-13)

All stages shipped on `feat/runtime-rust`:

- **S0/S1/D** — console builds 128→0; 12 `hub_*` read kernels; telemetry SQLite spill.
- **A** — pre-built console child + reverse-proxy. The bundled `Sky.Live` console
  is built once per sky version at the user's `sky build` time
  (`Sky.Build.Rust.Console`, fingerprint-validated cache — sound in the dev-only
  reality where `SKY_VERSION` is always `"dev"`), spawned + reverse-proxied at
  `/_sky/console/*` (strip convention), child reaped with the parent
  (`PR_SET_PDEATHSIG` + signal-exit). **Verified in real chromium**: dev console
  banner present, console connects (SSE), full dashboard renders. Plus the
  `--target rust` ignores-`[go.dependencies]` fix (no `go` toolchain needed) and
  reqwest-as-a-Std.Live dep.
- **C (#75)** — `push_exporter.rs`: `SKY_PARENT_URL`-gated federation push to the
  parent ingest.
- **E (#70)** — `hub_exporter.rs`: `SKY_CONSOLE_HUB`-gated OTLP/JSON push +
  bearer + bounded retry spool.

Divergences from Go logged in `runtime-rust/README.md` §"Rust vs Go". The whole
observability export surface is env-gated + inert by default, no panic vectors.

## Risks

- **S1 (Hub kernel) size** — 14 fns + the SQLite read schema + `Hub_currentIdentity`
  identity plumbing. Re-spike after S0 to size precisely.
- **A (mount/proxy)** — child-process lifecycle + reverse-proxy is new runtime
  infra; the `SKY_LIVE_BASE_PATH` sub-app awareness must match Go so the console's
  own assets/SSE resolve under the proxied prefix.
- The in-process `console.rs` is NOT deleted until A proves the child console
  serves — it remains the no-`db`/no-spawn fallback.
