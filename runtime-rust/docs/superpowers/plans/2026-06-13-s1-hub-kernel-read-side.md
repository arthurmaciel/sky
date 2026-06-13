# S1 — Hub kernel module (read side) on Rust — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans (inline)
> or subagent-driven-development. Steps use `- [ ]` checkboxes. Build env every
> task: `export PATH="$HOME/.ghcup/bin:$HOME/.cargo/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin"`;
> `export CARGO_TARGET_DIR=$HOME/.cache/sky-rust-target RUSTC_WRAPPER=sccache`.
> Runtime (`runtime-rust/src`) edits need NO cabal rebuild; codegen
> (`src/Sky/Generate/**`) edits DO (`cabal build exe:sky`; `sky-out/sky` is a
> symlink — never `--install-method=copy`). Test runtime edits with
> `cargo build --features full`.

**Goal:** Implement the 12 `hub_*` read kernels in the Rust runtime so the bundled
console compiles (closes the remaining 12 `E0425`) and renders telemetry history
read from the SQLite spill — true Go parity with `runtime-go/rt/hub/bridge.go`.

**Architecture:** Each kernel is **generic over its return type** `A:
DeserializeOwned` (the console's `State*_R` records are project-generated, so the
runtime crate cannot name them — it builds a `serde_json::Value` matching the
record's serde shape and `from_value::<A>`s it; the call sites infer `A` from the
concretely-typed `StateStore` fields, no turbofish needed). Filter args are
generic `F: Serialize` (serialize → read `query`/`showInfo`/… fields). Reads run
against the SQLite spill via `sqlx` under the existing `db` feature; a missing /
unreadable DB returns `Ok([])` / an empty record (never an error, never a panic —
mirrors Go's `getHubStore() == nil → Ok` path). No `Any`, no `unwrap`/`expect`/
indexing in any Sky-reachable path.

**Tech stack:** `sqlx` (sqlite, already a `db`-feature dep), `serde_json`,
`serde`. New file `runtime-rust/src/sky_runtime/live/hub.rs` (feature `db`).

---

## The data contract (reverse-engineered from Go — READ-ONLY ground truth)

### SQLite schema (the D↔S1 contract — `runtime-go/rt/hub/store.go:50` + `telemetry/persist.go:53`)

```sql
telemetry_log    (id, service_name, time TEXT, level, message, trace_id, span_id, attrs TEXT-json)
telemetry_metric (id, service_name, time TEXT, name, type, value REAL, attrs TEXT-json)
telemetry_span   (id, service_name, time TEXT, name, trace_id, span_id, parent_id,
                  start_time TEXT, end_time TEXT, attrs TEXT-json)
```
`time`/`start_time`/`end_time` are RFC3339 strings. `attrs` is a JSON object of
string→string. Indexes on `(service_name, time DESC)`. D (#69) writes this; S1
reads it. If D hasn't run, S1 still works against any file with this schema (and
returns empty against a fresh/missing file).

### The 12 kernel signatures (exact — from `sky-bundled/console/sky-out/Rust/src/hub_store.rs`)

`SkyTask<T>` is the default-`Error` alias (`SkyTask<Error, T>`). `E: From<String>`.

| Kernel | Signature |
|---|---|
| `hub_read_overview` | `<A>(db_path: String) -> SkyTask<E, A>` |
| `hub_read_logs` | `<A,F>(db_path: String, filter: F) -> SkyTask<E, A>` |
| `hub_read_metrics` | `<A>(db_path: String) -> SkyTask<E, A>` |
| `hub_read_traces` | `<A>(db_path: String) -> SkyTask<E, A>` |
| `hub_read_errors` | `<A>(db_path: String) -> SkyTask<E, A>` |
| `hub_list_services` | `(db_path: String) -> SkyTask<E, Vec<String>>` (non-generic — `Vec<String>` known) |
| `hub_read_service_stats` | `<A>(db_path: String) -> SkyTask<E, A>` |
| `hub_read_filtered_logs` | `<A,F>(db_path: String, service: String, filter: F) -> SkyTask<E, A>` |
| `hub_read_filtered_metrics` | `<A>(db_path: String, service: String) -> SkyTask<E, A>` |
| `hub_read_filtered_traces` | `<A>(db_path: String, service: String) -> SkyTask<E, A>` |
| `hub_read_filtered_errors` | `<A>(db_path: String, service: String) -> SkyTask<E, A>` |
| `hub_current_identity` | `<A>(db_path: String) -> SkyTask<E, A>` |

`A` is always inferred from the `StateStore`/`Cmd.perform` call-site type; the
list-returning ones infer `A = Vec<State…>`. Implementation builds a
`serde_json::Value::Array` (or object) and `from_value::<A>`.

### Target serde shapes (camelCase keys, verbatim — generated structs derive serde)

```
Overview    {skyVersion, commit, builtAt, uptimeSeconds:int, requestsTotal:int,
             errorRate5xx:f64, bufferLogUsed:int, bufferTraceUsed:int, productionMode:bool}
LogEntry    {time, level, message, subapp, reqId, sessionId, userLabel, route,
             status:f64, latencyMs:f64}
MetricRow   {name, typ, labels, value:f64, sum:f64, count:f64}
TraceRow    {traceId, spanId, parentId, name, kind, startTime, durationMs:f64, status}
ErrorRow    {count:int, message}
ServiceStat {name, status, reqsPerSec:f64, p95Ms:f64, errorRate:f64,
             sparkRps:[f64], sparkP95:[f64]}
Identity    {subject, email, claims: map<string,string>}
LogFilter   {query, session, showDebug:bool, showInfo:bool, showWarn:bool, showError:bool}
```

### Row → record mapping (from `runtime-go/rt/hub/bridge.go`)

- **logs** (`toHubLogRow`, bridge.go:186): `time`=RFC3339(row.time), `level`,
  `message`, `subapp`=service_name; `reqId`=attrs["req_id"], `sessionId`=
  attrs["session_id"], `userLabel`=attrs["user_label"], `route`=attrs["route"];
  `status`/`latencyMs`=0. Filter (`QueryLogsJSON`:111): store-side `level` =
  `pickSingleLevel` (exactly-one-toggled else ""), `Limit 200`; client-side drop
  rows where `query` (lower-substring of message|service) doesn't match or
  `session` != attrs["session_id"].
- **metrics** (`QueryMetricsJSON`:206): `name`, `typ`=type, `value`; `labels`=
  `k=v, k=v` joined from attrs; `sum`/`count`=0. `Limit 200`.
- **traces** (`QuerySpansJSON`:238): `traceId`/`spanId`/`parentId`/`name`;
  `kind`=service_name; `startTime`=RFC3339; `durationMs`=(end-start)/ms when both
  non-zero else 0; `status`=attrs["status"]. `Limit 100`.
- **errors** (`QueryErrorsJSON`:275): `QueryLogs(level=error, Limit 500)`, group
  count by message → `[{count, message}]`.
- **services** (`Services`:676): `SELECT service_name FROM each-table UNION ORDER BY`.
- **serviceStats** (`ServiceStatsJSON`:343 + `aggregateServiceStat`:372): per
  service, 60 s window, 30 buckets. `reqsPerSec`=logCount/windowSec; `errorRate`=
  errorLogs/totalLogs; `p95Ms`=95th-percentile of latency_ms/duration_ms attrs;
  `status`=classifyStatus(errorRate) ("ok"<1%, "warn"1-5%, "err">5%); sparkRps/
  sparkP95=per-bucket series oldest→newest.
- **overview** (`Hub_readOverview`:220): default record (skyVersion="hub", rest
  zero/false) with `bufferLogUsed`=logCount, `bufferTraceUsed`=spanCount,
  `requestsTotal`=logs+metrics+spans (`Counts()`).
- **identity** (`Hub_currentIdentity`:172): reads session identity; for the
  spill-only console, return empty Identity {subject:"", email:"", claims:{}} —
  identity plumbing is A-territory. Graceful default, never error.
- **filtered_\***: same as the un-filtered, with `service_name = service` added to
  the WHERE (empty service → no filter, falls back to un-filtered).

---

## File structure

- **Create** `runtime-rust/src/sky_runtime/live/hub.rs` (feature `db`) — the 12
  kernels + a private `open_spill(db_path) -> Option<SqlitePool>` helper + the
  row→Value mappers + the ServiceStat aggregation. Returns `Ok(empty)` when the
  pool can't open (missing file / bad path) — no panic, no error surfaced.
- **Modify** `runtime-rust/src/sky_runtime/live/mod.rs` — `#[cfg(feature="db")]
  pub mod hub;` + re-export the 12 fns so codegen's bare `hub_read_*(…)` resolves.
- **Modify** `src/Sky/Generate/Rust/Builder/Kernel.hs` — map `("Hub","readLogs")
  -> "hub_read_logs"` … for all 12 (the `Ffi.kernel "Hub_readLogs"` aliases in
  HubStore.sky lower to these names).
- **Modify** the Rust analyzer (whichever module sets `usesLive`/feature flags) —
  ensure a program referencing any `Hub_*` kernel enables the `db` feature in the
  generated `Cargo.toml` (the hub kernels need sqlx).
- **Verify**: re-spike `sky-bundled/console` → 0 errors; full `rust-sweep.sh`
  27/27 in-scope green (the new `pub mod hub` is feature-gated so non-db examples
  are unaffected).

---

## Tasks

### Task 1: `open_spill` + `hub_list_services` (the simplest end-to-end kernel)

**Files:** Create `runtime-rust/src/sky_runtime/live/hub.rs`; modify
`runtime-rust/src/sky_runtime/live/mod.rs`.

- [ ] Write `open_spill(db_path: &str) -> Option<Pool<Sqlite>>` — `if db_path
  empty → None`; connect read-only WAL via `SqlitePoolOptions` + a `block_on`/
  `await` shape matching the existing `db.rs` connect; any error → `None` (log a
  structured `warn`). No `unwrap`.
- [ ] Write `hub_list_services<E: Send + From<String> + 'static>(db_path: String)
  -> SkyTask<E, Vec<String>>`: open; `SELECT service_name FROM telemetry_log
  UNION SELECT … metric UNION … span ORDER BY service_name`; collect non-empty;
  `None` pool → `ok_res(vec![])`.
- [ ] Register `#[cfg(feature="db")] pub mod hub; #[cfg(feature="db")] pub use
  hub::*;` in `live/mod.rs`.
- [ ] `cargo build --features full` — clean. Add a unit test against a temp DB
  with two services → `["a","b"]`; empty/missing path → `[]`.
- [ ] Commit.

### Task 2: `hub_read_logs` + `hub_read_filtered_logs` (filter handling + attrs)

**Files:** `hub.rs`.

- [ ] `#[derive(Deserialize, Default)] struct HubLogFilter { query, session,
  showDebug, showInfo, showWarn, showError }`. `pick_single_level(&f) -> Option
  <&str>`. `to_log_value(row, attrs) -> serde_json::Value` per the mapping above.
- [ ] `hub_read_logs<A,F>(db_path, filter)`: `serde_json::to_value(filter)` →
  `from_value::<HubLogFilter>` (Default on error); query logs (level filter,
  limit 200); client-side query/session drop; build `Value::Array`;
  `from_value::<A>`. `None` pool → `from_value::<A>(json!([]))`.
- [ ] `hub_read_filtered_logs<A,F>(db_path, service, filter)`: same + `service_name
  = service` WHERE when service non-empty.
- [ ] `cargo build --features full`; unit test: 3 rows, one error level, filter
  showError → 1 row, attrs→reqId mapped.
- [ ] Commit.

### Task 3: `hub_read_metrics` / `_traces` / `_errors` + filtered variants

**Files:** `hub.rs`.

- [ ] `to_metric_value` (labels join, sum/count 0), `to_trace_value` (durationMs
  from start/end, kind=service, status from attrs), errors grouping (level=error,
  limit 500, count by message). Each with its filtered (service WHERE) variant.
- [ ] `cargo build --features full`; unit tests for durationMs + error grouping +
  labels join.
- [ ] Commit.

### Task 4: `hub_read_overview` + `hub_read_service_stats` + `hub_current_identity`

**Files:** `hub.rs`.

- [ ] `hub_read_overview`: `Counts()` (3 `SELECT COUNT(*)`), build the Overview
  Value (skyVersion="hub", bufferLogUsed=logs, bufferTraceUsed=spans,
  requestsTotal=sum). Missing pool → empty Overview Value.
- [ ] `hub_read_service_stats`: port `aggregateServiceStat` — 60 s window, 30
  buckets, reqsPerSec, errorRate, p95 (`percentile`), classifyStatus, sparkRps/
  P95. Pure helpers (`bucket_index`, `percentile`, `classify_status`,
  `parse_float_attr`) with total forms (no indexing — use `.get`).
- [ ] `hub_current_identity`: empty Identity Value (subject/email "", claims {}).
- [ ] `cargo build --features full`; unit tests for percentile + classifyStatus +
  bucketing + overview counts.
- [ ] Commit.

### Task 5: Codegen kernel maps + analyzer db-feature flag

**Files:** `src/Sky/Generate/Rust/Builder/Kernel.hs`; the Rust analyzer module.

- [ ] Add the 12 `("Hub","readX") -> "hub_read_x"` (and `list_services`,
  `current_identity`) entries to `kernelToRust`. Confirm the `Ffi.kernel
  "Hub_readLogs"` alias path resolves (HubStore.sky bindings are VarTopLevel
  aliases — same mechanism as other `Ffi.kernel` stdlib bindings).
- [ ] Make a program referencing any `Hub_*` kernel set the `db` feature in the
  generated `Cargo.toml` (find the existing `usesDb`/feature analyzer; add a
  `usesHub` signal OR fold Hub into `usesDb`).
- [ ] `cabal build exe:sky`.
- [ ] Re-spike `sky-bundled/console` → **0 errors**, `cargo build` of the console
  succeeds. Run it against a temp spill DB; confirm Overview/Logs render rows.
- [ ] Commit.

### Task 6: Sweep + acceptance + docs

- [ ] `scripts/rust-sweep.sh` — 27/27 in-scope green (hub.rs is `db`-gated; the
  `db`-feature examples 07/12/17/18 must stay green).
- [ ] Fork-local proof: `examples/rust/` console-read smoke (a tiny app that calls
  one hub kernel against a fixture DB) OR rely on the console spike as the
  acceptance artifact (document which).
- [ ] Update the epic spec: S1 DONE, console errors 12→0. Update README verified
  examples. Update memory `rust-console-epic-s0-progress` → add S1 DONE.
- [ ] Commit.

---

## Invariants / risks

- **No panic vectors:** every SQL error / pool-open failure / JSON-decode failure
  degrades to empty-result + structured warn — NEVER `?`-into-panic, never
  `unwrap`. A publisher/consumer schema mismatch can't arise (the kernel owns
  both the Value shape and the SELECT).
- **No `Any`:** `A` and `F` are concrete generic params resolved at each call
  site by inference; the only dynamism is `serde_json::Value`, which is
  provably-shaped by the mapper.
- **Feature-gated:** all of `hub.rs` is `#[cfg(feature="db")]`; non-db programs
  never compile it, so the runtime stays tokio-light for CLI/Tui.
- **D dependency:** S1 reads what D (#69) writes. S1 ships independently — it
  reads any file with the `telemetry_*` schema and returns empty against a fresh
  one. Full end-to-end (live data in the console) needs D + A.
- **B compile-guard** stays deferred (console store=memory; not blocking).
