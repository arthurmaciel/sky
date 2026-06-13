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
| **A** | **Sub-app mount + reverse-proxy** | `rt.MountSubApp` parity: spawn the console child binary, reverse-proxy `/_sky/console/*`, `SKY_LIVE_BASE_PATH` awareness, child lifecycle. | S0+S1+D (a console to mount) |
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

**S0 driven: console build errors 128 → 24** (commits 116970b3 … 6eccfa24):
- ✅ Stdlib kernels: `String.left/right`, `System.getenv/getenvOr`, `List.length`,
  `Time.formatISO8601` (+ Kernel.hs map fixing the `ISO`→`i_s_o8601` mangle),
  `JsonDec.Pipeline.custom`; `curry9/10`.
- ✅ Callback-record codegen (A1–A4): fn-field struct derive-Clone-only + Default
  via `disconnected_fnN`; serde-skip on Model fields; `(rec.field)(args)` call
  parens; move-closures with per-field capture clones (`closureCaptures`).
- ✅ `sky_list_cons` Clone-bound drop (move-only `Cmd.batch`).
- ⏳ **Remaining S0 (~12): a diverse app-specific tail** — E0282 inference
  turbofishes (traces_tab/view span rows), E0308 (`++` list-concat emitting
  `format!`/`String` where `Vec` expected; a wrong metric/servicestat decoder),
  residual E0277. Each needs individual diagnosis.
- ⏳ **B compile-guard** (closure-Model + persistent store → compile_error!) not
  yet emitted.

**Next:** finish the S0 tail, then **S1** (the 12 `hub_*` kernels — the remaining
12 E0425 — reading the SQLite spill).

## Risks

- **S1 (Hub kernel) size** — 14 fns + the SQLite read schema + `Hub_currentIdentity`
  identity plumbing. Re-spike after S0 to size precisely.
- **A (mount/proxy)** — child-process lifecycle + reverse-proxy is new runtime
  infra; the `SKY_LIVE_BASE_PATH` sub-app awareness must match Go so the console's
  own assets/SSE resolve under the proxied prefix.
- The in-process `console.rs` is NOT deleted until A proves the child console
  serves — it remains the no-`db`/no-spawn fallback.
