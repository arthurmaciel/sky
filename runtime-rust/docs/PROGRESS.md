# PROGRESS — Rust backend work log

This file is the **history / archaeology sink** for the `feat/runtime-rust` work.
It is the OPPOSITE of `README.md`:

- **`README.md`** = a *pristine current-state snapshot*. No history, dates, phases,
  tiers, SHAs, or changelog language. It is written ONLY by the
  `sky-rust-backend:update-docs` skill (which reads this file + `git log` + the
  actual source to mirror current status). Never edit `README.md` directly.
- **`PROGRESS.md`** (this file) = every step, with a timestamp, what was done, why,
  and the files touched. History lives here, not in `README.md`.
- **`CLAUDE.md`** = directives + *generalizable* learnings / pitfalls (also no
  history/dates).

**Convention:** newest entry at the TOP. Each entry: `## YYYY-MM-DD HH:MM — title`,
then a short what/why and an **Affected** list (files / commit).

---

## 2026-06-21 20:10 — Parity batch 20: factor reqwest-free `ssrf` module (generated ws/email get http_client; ws stays reqwest-free)

Closes #11 (generated Std.Email / Sky.Core.WebSocket-client projects failed
`could not find http_client in sky_runtime` — Project.hs gated the http_client
module on usesHttp only). Option B (guardian pre-write design sign-off): factor the
reqwest-free SSRF deny-private validators out of http_client.rs into a new
`ssrf.rs`, so a WebSocket-only binary validates URLs WITHOUT linking the reqwest
HTTP stack.

- New `runtime-rust/src/sky_runtime/ssrf.rs`: the 8 reqwest-free validators
  (ssrf_deny_private_enabled / is_private_ip / resolve_first_non_private_addr[_with_port]
  / check_host_not_private / ssrf_check_url / ssrf_pinned_ws_addr / ssrf_validate_url),
  byte-faithful move. The ONLY behavior change is `reqwest::Url::parse` → `url::Url::parse`
  at 2 sites — a SEMANTIC NO-OP: reqwest re-exports the `url` crate (`pub use url::Url;`,
  reqwest/src/lib.rs:280) and Cargo.lock has one `url` node (2.5.8) → same compiled
  parser. Added `url_parse_parity_with_reqwest_for_ssrf_extractions` (10 adversarial
  URLs: IDN/punycode, user:pass@, octal/hex IPv4-looking, ::ffff:127.0.0.1, [::1]:8443
  wss, trailing-dot) asserting identical scheme/host/port through both parsers.
- http_client.rs keeps the reqwest-coupled `ssrf_apply` + executor (import the 3 ssrf
  fns they use). ws_client.rs: `http_client::ssrf_*` → `ssrf::ssrf_*`. The 2 ws-only
  fns use `#[cfg_attr(not(feature="websocket_client"), allow(dead_code))]` (NOT `#[cfg]`)
  so generated ws projects — which include ssrf by MODULE without a websocket_client
  Cargo feature — keep them present.
- Codegen: crate-specs `url = "2"`; Project.hs `ssrfMod` (usesHttp||usesEmail||usesWsClient)
  + http_client module on usesHttp||usesEmail (http_stream + kernel-glob stay usesHttp);
  Emitter `url` dep (usesHttp||usesEmail||usesWsClient) + futures-util += usesEmail (email
  reuses http_client.rs's stream body reader). Standalone Cargo: `url` optional dep,
  http_client+=url, websocket_client http_client→url (reverts batch-19's ws→http_client).

Verified: generated 42-ws-client-onmessage GREEN with `url` and NO `reqwest`
(`cargo tree -i reqwest --features websocket_client` = no match); 20-email, 24-http-api,
26-stream-cli, 28-live-counter GREEN. Standalone: 16/16 subsets + bare clippy `-D` clean;
`--all-features` clean; 504/0 (+1 parse-parity; 19 SSRF tests relocated). Guardian
pre-write GO + post-write APPROVE (is_private_ip + resolve confirmed byte-identical by
diff). Pre-existing test-harness gap (tests/wasm_floor_scope.rs json under --all-targets
non-json subset) filed separately — not this diff.

**Affected:** `runtime-rust/src/sky_runtime/{ssrf.rs (new),http_client.rs,ws_client.rs,mod.rs}`, `runtime-rust/Cargo.toml`, `src/Sky/Generate/Rust/Project.hs`, `src/Sky/Generate/Rust/Builder/{Emitter.hs,crate-specs.toml}`.

---

## 2026-06-21 18:40 — Parity batch 19: standalone runtime feature self-containment (all subsets clippy-clean)

Enumerated `cargo check --no-default-features --features X` for every single feature:
~12 subsets failed E0433 `serde` (always-compiled `core.rs` derives serde unconditionally,
but serde was `optional`), plus `tui` (tokio), `live` (aes_gcm/sha2), `email`/`websocket_client`
(http_client module), and dead-code `ssrf_validate_url`/`now_secs` under narrow subsets.

Design A′ (guardian pre-write GO): make `serde` NON-optional in the standalone crate —
it is genuinely always needed by core.rs and is exactly how crate-specs.toml + generated
projects already declare it; the `optional` was a lie. One change fixes all serde subsets;
removed the now-invalid `"serde"` token from db/redis_store/live feature lists (reverts
batch-17's serde-in-db hack). Then: `tui += tokio`; `live += aes-gcm, sha2`;
`email`/`websocket_client += http_client`. Two source dead-code gates: `ssrf_validate_url`
→ `#[cfg_attr(not(feature="websocket_client"), allow(dead_code))]` (cfg_attr, NOT cfg —
generated projects include ws_client by module WITHOUT a websocket_client feature, so cfg
would remove the fn and E0425 the generated caller); `now_secs` → `#[cfg(feature="db")]`
(safe removal — its Sqlite/Postgres callers are co-gated on db).

Verified: all 15 single-feature subsets + bare `--no-default-features` clippy `-D warnings`
CLEAN (was ~14 failing); CI `--all-features` clean; 503/0; generated `28-live-counter`
(`sky build --backend rust`) compiles clean (now_secs cfg(db) + live-feature generated-safe).
Guardian post-write APPROVE. Disclosed PRE-EXISTING greenfield gap (Project.hs untouched,
NOT a regression): generated email/ws-client projects miss the http_client module
(`could not find http_client in sky_runtime`) — Project.hs gates it on usesHttp only; filed
as a follow-up (the generated mirror of the email/ws feature fix here).

**Affected:** `runtime-rust/Cargo.toml`, `runtime-rust/src/sky_runtime/{core.rs,http_client.rs,live/store.rs}`.

---

## 2026-06-21 17:55 — Parity batch 18: clear dead-code that fails `--features db` clippy `-D`

Batch 17 made `--features db` BUILD; under `clippy -D warnings` it still failed on 2
dead-code lints. Root cause: `html.rs`/`tea.rs` are compiled in narrow subsets while
their consumers are feature-gated.

- `html::is_void` — sole consumer `live/style_inject.rs` (live-only; webview enables
  live). Gated `#[cfg(feature = "live")]` — a non-live caller would now fail loud
  (E0425), the intended tightness. Generated Tui/Html-only projects compile html.rs
  without the live feature but also without style_inject → no caller, harmless.
- `tea::CliEvent::Key` — constructed only by the `tui` raw-key reader, but matched
  defensively in `cli_program` (tea.rs `Key(_,_) => continue`) in every tea build, so
  the variant must stay in the shared enum. `#[cfg_attr(not(feature="tui"), allow(dead_code))]`
  — honest "constructed-only-under-tui" (dead_code is a hygiene lint, not a denied risk lint).

Verified: `clippy --features db -D warnings` clean (was 2 errors); CI `--all-features`
clean; `--features live,crypto` keeps is_void live; 503/0. Guardian APPROVE (verified the
generated module-gating asymmetry harmless by construction). Broader narrow-subset
feature-self-containment (E0433 missing-crate edges under `json`/`tui`/`live` + `now_secs`/
`ssrf_validate_url` dead-code, none CI-reachable) filed as its own follow-up.

**Affected:** `runtime-rust/src/sky_runtime/html.rs`, `runtime-rust/src/sky_runtime/tea.rs`.

---

## 2026-06-21 17:30 — Parity batch 17: fix standalone `--features db` build (serde + auth-gate)

`cargo build --no-default-features --features db` failed with 9 × E0433: 4 × `serde`
(always-compiled `core.rs:120,157` derive `serde::Serialize/Deserialize` on
`SkyMaybe`/`SkyResult`) + 5 × `bcrypt` (auth.rs). Two root causes, two fixes — both
standalone-crate-only (generated projects carry serde unconditionally + crypto/json
always-default, so they were never affected).

- **serde:** `serde` is an optional dep → implicit `serde` feature; `db` had no edge
  pulling it, yet `core.rs` derives serde unconditionally. Added `serde` to the `db`
  feature (same precedent as the existing `sha2`-in-`db` entry). The derive pre-existed
  → no wire/format change, soundness-neutral.
- **bcrypt:** auth.rs's real dep surface is crypto(`bcrypt`) + db(`sqlx`/`Db`,
  register/login/setRole) + json(`jsonwebtoken`/`serde_json`) — ALL THREE. The old
  `mod.rs` gate `all(db, json)` omitted `crypto`, so `--features db` compiled auth and
  failed on unresolved `bcrypt`. Corrected to `all(crypto, db, json)`. (Mid-flight I
  first wrote `all(crypto, json)` — empirically caught it dropping `sqlx`/`Db`; auth
  DOES hit the DB. The full three-feature gate is the true surface.)

Verified: `--features db` green (was 9 errors); `--features crypto,db,json` compiles auth;
`--features full` green; `cargo clippy --all-targets --all-features -D warnings` green
(CI gate); `cargo test --features full` 503/0 + all integration suites. Guardian
pre-write GO + post-write APPROVE (correction disclosed). Side-finding filed as a
follow-up: `cargo clippy --features db` (narrow subset) orphans `html::is_void` +
`tea::Key` as dead code — pre-existing, NOT CI-reachable (CI = `--all-features`).

**Affected:** `runtime-rust/Cargo.toml` (db feature +serde), `runtime-rust/src/sky_runtime/mod.rs` (auth gate), `runtime-rust/Cargo.lock`.

---

## 2026-06-21 16:10 — Parity batch 16: classified, no-leak panic 500 body on both server surfaces

Batch 9 gave both Sky.Http.Server + Sky.Live a `CatchPanicLayer` with the DEFAULT static
"Service panicked" body + no structured log. Upgraded both to a custom responder that
classifies + logs the panic SERVER-SIDE (errId, via the batch-4 classifier) and returns a
500 whose body carries ONLY the 8-hex errId — NEVER the panic message (a panic message is
free-form and can carry secrets/PII/paths). core.rs: extracted the shared non-exiting
`classify_and_log_panic(payload) -> errId` (the hook now calls it then exits — behaviour-
identical) + `panic_500_body(payload) -> String` (the SINGLE source of the 500 body; only
the lowercase-hex errId is interpolated). Both layers pass an inline
`CatchPanicLayer::custom` closure calling `core::panic_500_body`.

DESIGN NOTE (caught by a real generated-project rebuild): the shared helper MUST live in
always-compiled `core`, NOT in `server.rs` — a Live-only generated project does NOT include
server.rs (it's gated on usesHttpServer, not usesLive), so a `server::*` reference E0433'd.
The runtime crate's own feature graph (live=[server]) masks this; only rebuilding a
Live-only project surfaces it.

Guardian-supervised (pre-write PASS w/ G1-G5; G3c — verified the exit-on-panic hook is
gated OFF for server/live mains (Emitter.hs:403), so the layer is reached not pre-empted).
Verified: clippy `-D warnings` clean; 503/0 incl. a no-leak test (panic with
`token=SECRET123 … /etc/secret`, assert the 500 body has `ref` but NOT the secret) + core
unit tests (8-hex errId, never panics over &str/String/non-string; kind mapping); Live-only
generated project (no server.rs) builds + serves 200; Sky.Http.Server project builds.
Closes task #4 — supersedes the batch-9 default-body floor.

**Affected:** `runtime-rust/src/sky_runtime/core.rs` (classify_and_log_panic +
panic_500_body + tests), `runtime-rust/src/sky_runtime/server.rs` + `live/mod.rs` (custom
responder closures), `runtime-rust/src/sky_runtime/live/observability.rs` (no-leak test).

## 2026-06-21 15:45 — Parity batch 15: Db.exec/execRaw return rows-affected Int (was unit)

stdlib `exec`/`execRaw : ... -> Task Error Int` (rows-affected, Go's res.RowsAffected())
but the Rust runtime returned `SkyTask<E,()>` and codegen mapped exec/execRaw → `"()"` —
a stdlib-signature/runtime divergence (`let n = Db.exec …` got unit where the type says
Int). Fixed end-to-end: db_exec/db_exec_raw/db_exec_params → `SkyTask<E,i64>` with
`ok_res(res.rows_affected() as i64)` (matches the existing insert/update/delete sites +
Go's int64() truncation); codegen exec/execRaw return-type → `i64` AND the two Emitter.hs
forwarding shims (`pub fn db_exec…-> SkyTask<()>` — a SECOND hardcoded site independent of
the ExprEmitter mapping) → `SkyTask<i64>`. Updated the internal `db_migrate_apply`
consumer (the `db_with_transaction::<E,()>` turbofish + outcome type + `Ok(())`→`Ok(_)` —
the load-bearing hard-break the guardian caught pre-write) and 5 test sites
(`Ok(())`→`Ok(1)` for inserts; the injection-safety test's `Ok(1)` now also witnesses the
bound INSERT ran exactly once, DROP didn't execute).

No valid Sky code regresses: stdlib already types exec as Int (Go returns Int), so every
call site treats it as Int; discard-via-`\_`/`let _` ignores an i64 exactly as `()`.
Guardian-supervised (pre-write PASS w/ the migrate-consumer + full-test-set fixes;
post-write APPROVE). Verified: clippy `-D warnings` clean; 501/0; fixture
67-db-sqlvalue-params extended with a `let widgetRows … String.fromInt widgetRows`
capture → `exec-rows-affected=1` (exercises the NEW i64 path no prior fixture did);
07-todo-cli (heavy Db.exec) no regression on `--backend rust`. Closes task #7.

**Affected:** `runtime-rust/src/sky_runtime/db.rs` (3 fns + migrate consumer + 5 tests),
`src/Sky/Generate/Rust/Builder/ExprEmitter.hs` (exec/execRaw return mapping),
`src/Sky/Generate/Rust/Builder/Emitter.hs` (2 forwarding shims),
`runtime-rust/tests/sky/67-db-sqlvalue-params/src/Main.sky` (exec Int capture).

## 2026-06-21 15:20 — Parity batch 14: sky_live_msg_total{name,outcome,noop} counter (completes the Msg-metrics surface)

The other half of Go's `msg_logging.go` (batch 13 did `sky_live_msg_seconds`). The
dispatch loop now increments `sky_live_msg_total{name,outcome,noop}`: `name` =
`telemetry::variant_name` (bounded variant); `outcome` = `"ok"` (the Rust update path
has no error channel — Go's `err==nil` conjunct is always true); `noop` = `cmd_is_none
&& e.model == next` computed AT the write-back where `e.model` still holds the OLD model
— a STRUCTURAL equality (no hash-collision false-noop, unlike Go's hash) with NO extra
clone. Required widening the Model bound with `+ PartialEq` across the same 5 sites as
batch-13's `Msg: Debug` (generated Models always derive PartialEq). All labels bounded
→ cardinality-safe. metric_inc emitted OUTSIDE the entry lock.

Guardian-supervised (pre-write PASS w/ mandatory metric_meta arm — landed; post-write
APPROVE). Verified: build + clippy `-D warnings` clean; 501/0; END-TO-END on
09-live-counter (--backend rust, auto-tick) → `sky_live_msg_total{name="Tick",
noop="false",outcome="ok"} 4` (Tick mutates the model → noop=false), alongside
batch-13's `sky_live_msg_seconds{name="Tick"}`. Closes task #8 — the Sky.Live
Msg-metrics surface is now at full Go parity.

**Affected:** `runtime-rust/src/sky_runtime/telemetry.rs` (metric_meta arm),
`runtime-rust/src/sky_runtime/live/mod.rs` (noop + counter inc + 5 Model PartialEq bounds).

## 2026-06-21 15:05 — Parity batch 13: sky_live_msg_seconds{name} Msg-latency histogram

Go's Sky.Live records `sky_live_msg_seconds{name}` — Msg-handling latency labeled by
the Msg variant name (msg_logging.go); Rust recorded nothing. Added a shared
`telemetry::variant_name<M: Debug>` that extracts ONLY the leading Rust-identifier
(the variant name) from `{:?}` via a capped writer — the BOUNDED label (finite variant
set), never a payload field (an attacker-controlled `SetName(String)` string can't reach
the label → no Prometheus cardinality memory-DoS). drive_session's dispatch loop times
`update(msg, model)` and observes `sky_live_msg_seconds{name=<variant>}` via the batch-7
registry. Required widening the internal `Msg` generic bound with `+ std::fmt::Debug`
across 4 sites (drive_session, serve_live, the GET page handler, live_app +
live_app_routed) — generated Msg enums always derive Debug, so it's a non-breaking
internal widening.

Guardian-supervised (pre-write PASS + post-write APPROVE; G1 leading-ident-only
extraction, G2 capped-writer prevents large transient alloc, G3 cardinality-boundary
unit test incl. the SetName-huge security case). Verified: clippy `-D warnings` clean;
501/0 incl. the new test; END-TO-END on 09-live-counter (auto-tick sub) on `--backend
rust` → `sky_live_msg_seconds_bucket{name="Tick",le="0.001"} 4` (bounded variant name
from a real generated Msg; generated Msg satisfied the Debug bound = no codegen-compat
regression).

FOLLOW-ON (task #8): `sky_live_msg_total{name,outcome,noop}` counter (Go's other
msg metric) — needs `Model: PartialEq` + the noop computation. `variant_name` is shared
so Tui/Webview dispatch can record the same metric later.

**Affected:** `runtime-rust/src/sky_runtime/telemetry.rs` (variant_name + metric_meta +
test), `runtime-rust/src/sky_runtime/live/mod.rs` (timed observe + 4 Debug bounds).

## 2026-06-21 14:45 — Parity batch 12: Db.queryDecode `List SqlValue` params (completes the SqlValue surface)

Extends batch 11 to the third param-taking Db kernel. `db_query_decode_params` is a
byte-for-byte mirror of `db_query_decode` except the bind loop uses the total
`bind_sql_param` (SqlParam) instead of `q.bind(String)`; same fetch_all_routed +
row_to_json + decoder loop. Codegen adds 2 Call arms (VarKernel+VarTopLevel) for the
4-arg `queryDecode` [conn, sql, params, decoder] guarded by the same
`isSqlValueListArg` — a `List String` keeps the existing `db_query_decode` path
(unchanged). Guardian-supervised (APPROVE — "a pure mechanical mirror of an
already-approved pattern; zero new safety properties"). Verified: cabal rebuilt; clippy
`-D warnings` clean; 500/0; the `67-db-sqlvalue-params` fixture (extended with an
`itemDecoder` + `Db.queryDecode … [Db.SqlInt 3] itemDecoder`) builds+runs on `--backend
rust` → adds `decode-query count=1 name=gadget` (SqlInt-param matched + decoded the
typed row) alongside the batch-11 lines. SqlValue param binding now covers exec +
query + queryDecode.

**Affected:** `runtime-rust/src/sky_runtime/db.rs` (db_query_decode_params),
`src/Sky/Generate/Rust/Builder/ExprEmitter.hs` (2 queryDecode arms),
`runtime-rust/tests/sky/67-db-sqlvalue-params/src/Main.sky` (queryDecode coverage).

## 2026-06-21 14:30 — Parity batch 11: Db.exec/Db.query `List SqlValue` mixed-type params

`Db.exec`/`Db.query` are `Db -> String -> List a -> Task ...`. The Rust runtime only
took `Vec<String>` params, so Go's v0.16.26 `List SqlValue` (mixed-type positional
params — String + Int + Bool + Float + Decimal + Time + Money + typed NULL in one
list, e.g. `INSERT … VALUES (?, ?, ?)` mixing String + Int + Bool) FAILED to compile
on Rust (a `List SqlValue` arg rendered as `Vec<StdDbSqlValue>` ≠ `Vec<String>`).
Closed across runtime + codegen:
- RUNTIME (db.rs): `db_exec_params` / `db_query_params` — mirror db_exec/db_query but
  bind each param via the EXISTING total `bind_sql_param` (the SqlParam→query binder
  already used by insertFields/updateFields) instead of `q.bind(String)`. Same
  exec_routed/fetch_all_routed (task-local tx-aware), same db_format_sql, same
  positional binding (never interpolated).
- CODEGEN (ExprEmitter.hs): `sqlValuesToVec` (reuses the exact StdDbSqlValue→SqlParam
  `sqlValueMatchArms`) + `isSqlValueListArg` (region-type detection: matches ONLY
  `List <SqlValue>`, suffix-tolerant for a qualified spelling) + 4 new Call arms
  (VarKernel+VarTopLevel × exec+query) routing to the params binders when the params
  arg's solved element type is SqlValue. A `List String` fails the guard → falls
  through to the existing db_exec/db_query (Vec<String>) UNCHANGED — zero regression;
  an unresolved region → String path (fail-safe: a genuine misroute is a loud cargo
  error, never a silent wrong binding).

Guardian-supervised (pre-write PASS + post-write APPROVE; suffix-match guardrail,
SqlParam-reuse soundness, no false-positive on String params). Verified: cabal rebuilt
+ symlinked; clippy `-D warnings` clean; 500/0 incl. a new runtime test (Text/Int/Bool/
Float/Null bind + SqlValue-param WHERE roundtrip); END-TO-END fixture
`runtime-rust/tests/sky/67-db-sqlvalue-params` exercises BOTH paths in one program and
builds+runs on `--backend rust` → `string-param-rows=1` (String path, no regression) +
`sqlvalue-query name=widget qty=7 count=1` (mixed-type inserts + SqlInt-param query).
The clean build is itself the routing proof (a misroute = cargo type-mismatch).

FOLLOW-UPS: task #7 — `Db.exec` returns () vs stdlib `Task Error Int` (rows-affected),
touches both db_exec + db_exec_params (pre-existing). queryDecode params + SqlValue
not yet wired (exec+query only this batch).

**Affected:** `runtime-rust/src/sky_runtime/db.rs` (db_exec_params/db_query_params +
test), `src/Sky/Generate/Rust/Builder/ExprEmitter.hs` (sqlValuesToVec +
isSqlValueListArg + 4 Call arms), `runtime-rust/tests/sky/67-db-sqlvalue-params/` (new
fixture).

## 2026-06-21 13:55 — Parity batch 10: Db.migrate `_sky_migrations` ledger (idempotent + drift-guarded)

Rust `db_migrate_apply` was NAIVE — it ran every migration's SQL unconditionally
and returned the names, with no ledger. Running `Db.migrate` twice re-ran all
migrations (CREATE TABLE → error / dup data) — a P0 correctness gap. Rewrote it to
Go's contract (`runtime-go/rt/db_auth.go` Db_migrateApply, library Task-return path):
a `_sky_migrations(name PRIMARY KEY, checksum, applied_at)` ledger; per migration a
sha256-hex checksum (cross-backend DB CONTRACT — byte-identical to Go's
`fmt.Sprintf("%x", sha256.Sum256(...))`, pinned by a unit test); already-applied +
matching checksum → SKIP (idempotent); already-applied + changed SQL → drift ERROR
(name only, never the SQL body/hash); pending → run SQL + ledger INSERT in ONE
transaction via the existing single-connection `db_with_transaction` (failure rolls
back only that migration; re-run resumes). Ledger INSERT uses bound params (no
interpolation); the migration SQL itself is run verbatim as trusted compile-time app
source (same trust model as Go). Single-deployer by design; `name PRIMARY KEY` is the
double-apply backstop.

`sha2` added to the runtime `db` feature (generated projects already pull it via the
always-on `crypto` default; this fixes the standalone build). `chrono` (unconditional)
supplies the RFC3339 `applied_at`.

Guardian-supervised (pre-write PASS + post-write APPROVE; G1 no-interpolation, G2
name-only error, G3 Fn-clone-captures, G4 checksum pin, G5 total non-test code, G6
feature wiring). Verified: clippy `-D warnings` clean; 499/0 incl. 2 new tests
(checksum pin + apply/idempotent/drift/resume against real in-memory sqlite);
07-todo-cli (Std.Db CLI) builds AND runs on `--backend rust` (add+list, exit 0).

FOLLOW-UPS: task #6 — `SKY_DB_OP=status/migrate` CLI exit-modes + pretty status
report (this batch is the library Task-return path only). task #5 — pre-existing
`--features db`-only standalone build breakage (serde/bcrypt E0433, orthogonal).
Deferred (non-blocking, low value): a `MigrationChecksum` newtype (single
producer/consumer today).

**Affected:** `runtime-rust/src/sky_runtime/db.rs` (migrate_checksum + db_migrate_apply
rewrite + 2 tests), `runtime-rust/Cargo.toml` (`db` feature += sha2).

## 2026-06-21 13:35 — Parity batch 9: per-request CatchPanic→500 on the Sky.Live router

`Sky.Http.Server` already wraps its router in `tower_http::CatchPanicLayer` (server.rs)
→ a panicking handler returns 500. `Sky.Live` did NOT: a panic in a Live handler
(page render / `/_sky/event` POST / SSE) unwound the tokio task and DROPPED the
connection with no response, while Go's per-request defer/recover returns 500
(rt.go:3463). Closed by inserting `.layer(CatchPanicLayer::new())` into the Live
layer stack, placed INNER of `observability::track` and OUTER of csrf + handlers
(runtime nesting `track(catch_panic(csrf(handler)))`) so the converted 500 returns
through track normally and is still counted + access-logged + histogrammed as status
500 — Go-parity (Go's recover is innermost; the outer mw observes the 500). Default
static "Service panicked" body (secret-free; symmetric with server.rs). The no-panic
thesis means well-typed Sky can't panic, so this is the defense-in-depth FLOOR, not the
foundation. Guardian-supervised (G1 csrf is pure validate-before/tail-call → unwind is
fail-safe; G2 default-layer floor; G3 follow-up filed). Verified: clippy `-D warnings`
clean; 497/0 incl. a new `#[tokio::test]` that oneshots a panicking route and asserts
500 AND `sky_live_requests_total{status="500"}` (the counted-as-500 parity claim);
live rebuild+boot of 09-live-counter → GET / =200, /_sky/metrics intact.

FOLLOW-UP (task #4, guardian G3): route BOTH catch-panic surfaces through
`core::classify_panic` for a structured Error log (errId + class) + stable non-leaking
body; until then the default static body is the leak-free floor.

**Affected:** `runtime-rust/src/sky_runtime/live/mod.rs` (CatchPanicLayer),
`runtime-rust/src/sky_runtime/live/observability.rs` (regression test),
`runtime-rust/Cargo.toml` (test-only `tower` dev-dep for `ServiceExt::oneshot`).

## 2026-06-21 13:10 — Parity batch 8: bounded `{method,status}` labels on sky_live_requests_total

`/_sky/metrics` exposed `sky_live_requests_total` as a single UNLABELED grand-total,
so an operator got no method/status breakdown (Go labels it `{method,route,status}`
in observability_middleware.go:172). The `track` middleware now writes a labeled
counter via the registry. SECURITY: kept Go's two BOUNDED labels — `method`
normalised to a CLOSED 9-method set (`normalize_method`, else `"other"`; closes the
arbitrary-extension-method-token cardinality-DoS) + full numeric `status` (bounded
by the HTTP spec, Go-exact for Grafana parity) — but DROPPED Go's `route` label,
which is raw-path-derived = attacker-controllable = unbounded against a never-evicting
registry (the histogram already dropped its label for the same reason). Removed the
hand-printed unlabeled line in `metrics()` (it would collide as a duplicate
#HELP/#TYPE block under the same name → scrape rejection) + the now-dead redundant
`REQUESTS` atomic; `metrics()` is now purely `write_prom()`. The counter fires only
inside the existing non-internal + non-sub-app guard (matches the histogram scope; no
/_sky/* inflation). Guardian-supervised (G1 closed-set+zero-alloc, G2 single-fire-in-
guard, G3 dead-static-removed) — pre-write PASS + post-write APPROVE. Verified: clippy
`-D warnings` clean; 496/0 incl. 2 new tests; live curl on 09-live-counter →
`{method="GET",status="200"} 2` + `{method="POST",status="403"} 1`, exactly one
#HELP/#TYPE, CSRF 403 intact.

**Affected:** `runtime-rust/src/sky_runtime/live/observability.rs` (labeled counter +
`normalize_method` + dead-static removal + tests), `runtime-rust/src/sky_runtime/telemetry.rs`
(metric_meta help string).

## 2026-06-21 14:25 — Parity batch 7: latency histograms (completes the /_sky/metrics P0)

Extends the batch-5 registry with a `Histogram` MetricValue variant (cumulative
buckets on Go's `BucketsLatency` boundaries 1ms…5s, sum, count) + `metric_observe`
+ the `_bucket{le=…}` / `+Inf` / `_sum` / `_count` exposition (Go's
writeHistogram). The track middleware now observes `sky_live_request_seconds` per
request — UNLABELED on purpose: labeling by the raw path would be the
unbounded-cardinality memory-DoS the batch-5 guardian flagged (the registry never
evicts; Go labels by a bounded route template the Rust middleware lacks here).

With this the `/_sky/metrics` P0 ("single unlabeled counter — no registry, no
labels, no histograms") is FULLY closed: counters + gauges + a latency histogram.

Verified live (28-live-counter, 6 requests): `# TYPE sky_live_request_seconds
histogram` with 8 cumulative `_bucket{le=…}` lines + `+Inf` (all 6, sub-ms) +
`_sum 0.002996` + `_count 6`. Full suite green; clippy `--all-features` clean.

Remaining metrics follow-up: `sky_live_msg_seconds` (Msg-dispatch histogram) +
per-status/route request labels (needs a bounded route-template source).

**Affected:** `runtime-rust/src/sky_runtime/telemetry.rs`,
`runtime-rust/src/sky_runtime/live/observability.rs`.

## 2026-06-21 14:05 — Parity batch 6: console Basic-auth + WWW-Authenticate challenge

The production console/metrics auth gate (`console.rs gate_blocked`) accepted
ONLY `Authorization: Bearer <tok>` and returned a bare 401, so a Prometheus
scraper configured with `basic_auth` (the documented Go path) was locked out
with no actionable challenge. Added a `header_authorizes` helper that ALSO
accepts `Basic base64(user:tok)` — any username, the password segment is
constant-time compared (subtle::ct_eq) against the admin token — and the 401 now
carries `WWW-Authenticate: Basic realm="sky-metrics"` (Go parity:
`hasAdminAuth` + `HandleMetrics`). Total (no unwrap/index): every fallible step
is Option/Result. Audit log reason generalised to `bad-or-missing-credentials`.

Verified live (28-live-counter, ENV=production + SKY_ADMIN_TOKEN): no-auth → 401
+ WWW-Authenticate; `Bearer <tok>` → 200; `Basic any:<tok>` → 200; wrong
password → 401. Full suite green; clippy `--all-features` clean.

Still deferred: `SKY_CONSOLE_AUTH=app` (row-poly consoleAuth callback, P1/L) —
returns 501; needs threading the Sky-side callback closure through the Live cfg
into the gate (a larger codegen+runtime change).

**Affected:** `runtime-rust/src/sky_runtime/live/console.rs`.

## 2026-06-21 13:40 — Parity batch 5: labeled metric registry + Prometheus exposition

Closes the core of the `/_sky/metrics` P0 ("single unlabeled counter — no
registry, no labels, no other series"). Added a labeled metric registry to
`telemetry.rs` — counters + gauges keyed by `(name, sorted-labels)` in a
`Mutex<BTreeMap>` (sorted → deterministic, grouped output) — with `metric_inc`,
`metric_add_gauge` (saturating, floored at 0), and a canonical Prometheus 0.0.4
`write_prom()` renderer (one `# HELP`/`# TYPE` per name, label-value escaping).

Wired: `sky_live_errors_total` (5xx, in `record_request`),
`sky_live_sse_connections_total` (SSE connect), and the
`sky_live_sessions_active` GAUGE — incremented on SSE connect and decremented via
a `SessionGauge` Drop guard carried in the response body stream, so it tracks
real connect/disconnect. `/_sky/metrics` now appends `write_prom()` after the
back-compat unlabeled `sky_live_requests_total` grand-total line (registry never
registers that name → no duplicate HELP/TYPE).

Verified live (28-live-counter): with an active SSE connection
`sky_live_sessions_active 1` + `sky_live_sse_connections_total 1`; after
disconnect the gauge drops to `0` (Drop guard) while the counter stays. Valid
0.0.4 exposition. Full suite green; clippy `--all-features` clean.

Follow-ups (filed): latency histograms `sky_live_request_seconds` /
`sky_live_msg_seconds` (P1/M — needs a Histogram type + BucketsLatency);
per-status/route labels on `sky_live_requests_total`; `sky_live_sse_drops_total`
is N/A on Rust today (the SSE channel BACKPRESSURES when full rather than
drop-oldest — a separate behavioral divergence, not a metrics gap).

**Affected:** `runtime-rust/src/sky_runtime/telemetry.rs`,
`runtime-rust/src/sky_runtime/live/observability.rs`,
`runtime-rust/src/sky_runtime/live/mod.rs`.

## 2026-06-21 13:10 — Parity batch 4: synchronous-panic gate (Go LogPanicAndExit parity)

Guardian-supervised (PASS, incl. the server-gating safety decision). A panic
escaping the synchronous Sky path (div-by-zero, index-OOB, overflow) dumped a raw
Rust backtrace instead of a classified Sky error. New
`core::install_panic_classifier()` installs a `panic::set_hook` that classifies
the message (DivisionByZero / IndexOutOfRange / ArithmeticOverflow / Unexpected),
logs it structurally with an 8-hex correlation id (honours `SKY_LOG_FORMAT=json`
via `telemetry::json_escape`), and `process::exit(1)` — total (no
unwrap/index/panic of its own).

Codegen (`Emitter.hs`) calls it as `fn main()`'s first statement, GATED:
`installPanicGate = not (usesHttpServer uk || usesLive uk)`. SAFETY: it is
installed only for synchronous shapes (Sky.Cli / Sky.Tui / Sky.Webview / batch),
NEVER for a server — the default `block_on` runs on a spawned thread, so a global
exit-on-panic hook would crash the WHOLE server on a single request-handler
panic. Mirrors Go, whose synchronous LogPanicAndExit is the non-server path
(servers recover-to-500 per request).

Verified: fixture `71-panic-classifier` (CLI div-by-zero) → classified
DivisionByZero + exit 1 in both plain and json; normal CLI (67) still exits 0;
server fixture (68) generated main.rs has install-count 0. Clippy
`--all-features` clean.

OPEN follow-up (filed): Sky.Live/Server synchronous-SETUP panic (before block_on)
+ per-request axum CatchPanic→500 — one tracked gap; the deliberate server
exclusion above is the reason. Diagnostic-quality only (process still exits
non-zero), not soundness.

**Affected:** `runtime-rust/src/sky_runtime/core.rs`,
`src/Sky/Generate/Rust/Builder/Emitter.hs`,
`runtime-rust/tests/sky/71-panic-classifier/`.

## 2026-06-21 12:30 — Parity batch 3 (P0): Std.Ui style-marker injection

Guardian-supervised (security model reviewed pre-write; `</style>`-breakout
regression required + delivered). The biggest UX P0 in the audit: the shared
`Std.Ui` emits `data-sky-{mq,pc,tr,anim}-*` marker attributes for
`Ui.breakpoint`/`Ui.mediaQuery`, `Background.hoverColor`/`Ui.onPseudo`,
`Transition.attribute`, `Animation.attribute`, but the Rust backend had **no
consumer** — so hover / breakpoint / media-query / transition / animation
rendered inert markers and produced **zero CSS** (all dead).

New `runtime-rust/src/sky_runtime/live/style_inject.rs` ports Go's
`applyStyleInjections` (live.go:872-1110): 4 passes turning markers into
sky-id-scoped `<style>` blocks (prepended child, or sibling-hoisted after a void
element, #409), with the 2 ident sanitisers (`sanitiseAnimationName`,
`skyIDToCSSIdent`) and the load-bearing `</style`/`</STYLE` close-tag strip on
every CSS fragment (the only XSS guard, since the `<style>` body is raw).

ORDERING (load-bearing): `apply_style_injections` is called immediately after
EVERY `assign_sky_ids` (mod.rs ×4 page/commit/cold-restore + webview.rs ×1), so
the render output AND the diff baseline are both injected → the diff never sees a
marker-vs-`<style>` asymmetry (no spurious whole-subtree replace). Idempotent
(markers stripped on first run) as belt-and-braces.

Verified: 6 unit tests (incl. `</style><script>` breakout neutralised, void
sibling-hoist, idempotency) + live fixture `70-style-injection` — `<style>`
blocks for hover/breakpoint/mediaQuery present, `:hover` auto-wrapped in
`@media (hover: hover)`, and an injected `</style><script>alert(1)</script>`
breakout count = 0 (stripped; the `<script>` survives only as inert text inside
the never-closed `<style>`, exactly Go). Full suite: 495 lib + all integration
green. Clippy `--all-features` clean.

**Affected:** `runtime-rust/src/sky_runtime/live/style_inject.rs` (new),
`runtime-rust/src/sky_runtime/html.rs` (pub `is_void`),
`runtime-rust/src/sky_runtime/live/mod.rs`,
`runtime-rust/src/sky_runtime/webview.rs`,
`runtime-rust/tests/sky/70-style-injection/`.

## 2026-06-21 11:40 — Parity batch 2: HTML render-path Go-parity (4 fixes)

Guardian-supervised (pre-write guardrails + verification). The shared
`render_into` (Sky.Live/Tui/Webview render path) diverged from Go's `renderVNode`
in four ways:

1. **`<select>` selected flip** (P1) — Rust stripped the select `value` but never
   flipped `selected` onto the matching `<option>`, so only the first option
   showed. Now threads the select value to option children and adds
   `selected="selected"` on value-match (copy-don't-mutate; the tree is the diff
   baseline). Verified: only `value="b"` gets selected.
2. **`<script>`/`<style>` verbatim text** (P1, XSS-sensitive) — Rust entity-escaped
   their text children, baking `&lt;`/`&#39;` into inline JS/CSS. Now emits HText
   verbatim ONLY under the literal `script`/`style` tag (Go's `rawBody`). SECURITY
   comment documents the boundary: Std.Ui never produces a script/style element
   (its styling is data-sky-* markers), so this is solely the Std.Html raw escape
   hatch; ordinary text still escapes. Verified: `if (1 < 2) { x = '&'; }` raw,
   `<b>raw</b>` in a div → `&lt;b&gt;raw&lt;/b&gt;`.
3. **onImage/onFile event marker** (P2) — Rust emitted `sky-sky-image`
   (double-prefix) so the client upload driver lookup missed. Now branches:
   `sky-`-prefixed meta-events → `data-sky-ev-<name>`, plain DOM events →
   `sky-<name>` (Go live.go:395-405). Fixed symmetrically in `html.rs` render AND
   `diff.rs diff_events` so render/diff agree.
4. **`Html.doctype`** (P3) — `!doctype-wrapper` was rejected by `is_safe_html_name`
   and dropped. Now emits a literal `<!DOCTYPE html>` then children, before the
   name gate (fixed literal → no injection vector).

Clippy `--all-features` clean. Fixture `69-html-render-parity`. Batch-1 CI: Rust
security-audit (clippy) green.

**Affected:** `runtime-rust/src/sky_runtime/html.rs`,
`runtime-rust/src/sky_runtime/live/diff.rs`,
`runtime-rust/tests/sky/69-html-render-parity/`.

## 2026-06-21 08:15 — Go→Rust parity audit (108 gaps) + first guardian-supervised fix batch

Ran a deep multi-agent behavioral parity audit of the Go backend vs the Rust
backend (10 domain auditors reading both runtimes + codegen, + 1 cross-cutting
critic). Result: **108 gaps** (10 real P0, 43 P1, 38 P2, 18 P3) catalogued in
`runtime-rust/docs/go-rust-parity-audit-2026-06-21.md` with how-Go-works /
how-Rust-works traces, both-backend locations, and a fill approach per gap.

Then implemented a first focused batch (security + correctness, in-boundary),
**plan and code both gated through the security-soundness-guardian** (pre-write
guardrails + post-write PASS review). All four runtime-verified:

1. **Random.float lo hi** (P0 correctness) — the kernel took `(_: ())` and
   returned `[0,1)` ignoring its bounds. Now `(lo, hi)` → uniform `[lo, hi)`
   (53-bit mantissa unit draw; degenerate `hi <= lo` clamps to `lo`). Codegen
   shim arity fixed too. Fixture `67-random-float-bounds`: 200 draws all in
   range, degenerate clamps to lo.
2. **Oversize body → 413** (P1 security) — `build_request` collapsed an oversize
   (and any read error) into an empty body via `unwrap_or_default()`, silently
   handing the handler `""`. Now returns `Result<_, u16>` → 413 (Content-Length
   pre-check + `to_bytes` cap enforcement for chunked). Fixture `68-server-413`.
3. **Security headers on Sky.Http.Server** (P1 security) — `setSecurityHeaders`
   parity (nosniff / referrer-policy / permissions-policy / x-frame-options or
   CSP frame-ancestors), applied in `to_axum_response` only when unset (handler
   override wins). Verified live on a GET response.
4. **SSE reconnect-resync frame** (P0 correctness) — `sse_handler` sent only
   hello+heartbeat; a store-restored / restarted session's DOM stayed frozen
   until the next user Msg. Now emits a full-body `event: patch` `{seq, body}`
   after hello (Go parity live.go:5498; client.js:1318 consumes it). Verified
   on the SSE stream.

To let the Sky.Http.Server path share the headers (the `live` module is DCE'd
out of server-only builds), `frame_ancestors` + `security_headers` were
relocated from `live/csrf.rs` to the always-compiled `telemetry` module and
re-exported from `csrf` (no behavior change).

Guardian rulings on the rest of the batch: item 4 (federation ingest auth)
already implemented and better-than-Go (dropped); item 5 (tenant-prefix SQL)
**blocked** on a missing prerequisite — Rust `Hub_currentIdentity` is a stub,
so a tenant gate would read empty claims and enforce nothing (security theater);
item 3b (mux-wide CSRF on Sky.Http.Server) **deferred** to a focused PR because
Go's default-on CSRF 403s API/curl POSTs and needs the `Server.csrfToken`
kernel + `withoutCsrf` + `SKY_CSRF` plumbing. Follow-up filed: security headers
skip the streaming-sentinel + WS-101 early-return paths (low risk, defense-in-
depth).

Clippy `--all-targets --all-features` clean (exit 0).

**Affected:** `src/Sky/Generate/Rust/Builder/Emitter.hs`,
`runtime-rust/src/sky_runtime/random.rs`,
`runtime-rust/src/sky_runtime/server.rs`,
`runtime-rust/src/sky_runtime/telemetry.rs`,
`runtime-rust/src/sky_runtime/live/csrf.rs`,
`runtime-rust/src/sky_runtime/live/mod.rs`,
`runtime-rust/tests/sky/67-random-float-bounds/`,
`runtime-rust/tests/sky/68-server-413/`,
`runtime-rust/docs/go-rust-parity-audit-2026-06-21.md`.

## 2026-06-20 19:00 — Sky.Tui whole-library correctness sweep (audit → 11 fix batches)

Drove the 22-finding `tui-correctness-audit` catalog to closure across 11
verified batches, all in `tui/layout.rs`. Each: `cargo test --features full tui`
green (52 unit tests); final consolidated pyte grid-verify on
`24-tui-kitchen-sink` confirms every fix renders + no regression.

| # | Fix | audit |
|---|---|---|
| 1 | NO_COLOR honoured; masked-input caret tracks st.cursor | #9, #11 |
| 2 | alignment centerX/Y, alignLeft/Right/Top/Bottom (was all no-op) | #3 |
| 3 | fixed-height boxes Ui.height px/vh/min/max (apply_self_height) | #1, #15 |
| 4 | bg-coloured gaps (vstack/hstack); transparent/alpha-0 bg (bg_of) | #5, #10 |
| 5 | Region heading bold; Font.overline (SGR 53) | #8, #19 |
| 6 | Ui.html raw text render; per-side borders (Border.widthEach) | #22, #6 |
| 7 | Font text-align center/right | #7 |
| 8 | nearby overlays above/below/onLeft/onRight/inFront/behind | #12, #16 |
| 9 | explicit grid tracks (Grid.columns/tracks px/fr/auto) + grid gap | #13, #21 |
| 10 | height-fill distribution in fixed-height columns | #2, #4 |
| 11 | Border.rounded corners (╭╮╰╯) | #18 |

**Dispositioned (correct as-is for a terminal, not a defect):**
- clip-to-fixed-dimension (#14) — already covered by apply_self_height (height
  clip) + set_width (width clip); the interactive scrollbar *indicator* /
  scroll-within-subregion is beyond the whole-screen scroll model (out of scope).
- Border.shadow/glow/inset-shadow (#18), Background.image/linearGradient (#20) —
  cannot render in cells; SILENTLY degraded on purpose (a stderr warn mid-TUI
  corrupts the live display, so silence is the correct terminal behaviour).

**Affected:** `runtime-rust/src/sky_runtime/tui/layout.rs`.

---

## 2026-06-20 17:30 — Sky.Tui kitchen-sink render fixes + whole-library correctness audit

Fixed 5 Sky.Tui render bugs in `tui/layout.rs` (correct Std.Ui layout, NOT
Go-mirror — several are wrong in Go too). Verified via the pyte styled-grid
capture (`equiv-render.sh tui 24-tui-kitchen-sink`). 52 tui unit tests green.

- **radio** — `checked` now detected for the `value=val-when-selected` idiom
  (checked = `checked` attr OR non-empty/non-`false` value) → selected draws `●`
  (was always `○`; onClick already fired — only the visual was dead).
- **slider** — track width follows `Ui.width` (was fixed 12) + thumb inset to
  `[1, width-2]` so the `├`/`┤` end-glyphs never overwrite it (the "ball vanishes
  at the extremes" bug).
- **multiline** — honours fixed `Ui.height (px)`: clip+scroll window around the
  cursor, else pad with track rows; no longer grows unbounded with lines.
- **input border** — bordered inputs draw a real `┌─┐` frame via a new shared
  `frame_rendered` helper (extracted from `apply_border`); was suppressed.
- **border style** — `Ui.style "border-style" "dashed"|"dotted"` now reaches the
  renderer (`AttrStyle` arm) → dashed `┄┆` / dotted `┈┊` (were all solid).

In flight: a read-only diagnostic swarm (`tui-correctness-audit` workflow, 10
parallel area audits — sizing / spacing / alignment / borders / text-wrap /
color-bg / inputs-focus / nearby-overlays / grid / scroll-clip / misc) building a
deduped bug catalog for the broader "fix the TUI library completely" goal; fixes
to follow sequentially (single-file `layout.rs` → no parallel fixers).

**Affected:** `runtime-rust/src/sky_runtime/tui/layout.rs`.

---

## 2026-06-20 16:00 — Codegen: generic self-recursive ADT boxing (E0072) FIXED; record-destructure lambda param confirmed

Confirmed two audit codegen items with real repro fixtures (TDD), fixed one,
scoped the other precisely.

**FIXED — generic self-recursive ADT (E0072).** `type Tree a = Leaf | Node a
(Tree a)` failed `cargo build` (recursive type, infinite size) because the box
predicate string-EQUAL-compared the self-edge field `MainTree<A>` to the bare
enum name `MainTree`. Fixed to HEAD-match (`== Name || (Name++"<") isPrefixOf`)
at all three consistent sites: `TypeEmitter.boxIfRecursive`, ExprEmitter
`ctorBoxedPositions` (construction `Box::new`), ExprEmitter pattern-deref
(`let v = *v`). Verified: `tests/sky/codegen-generic-recursive-adt` builds +
runs (prints 3); 19-skyforum unchanged. Commit 486002a9.

**FIXED — record-destructure lambda param.** `\{ x, y } -> x + y` emitted
`|_| (x + y)` — the `PRecord` pattern rendered as `_`, dropping the `x`/`y`
binders → `E0425`. Real "compiles-in-Sky, cargo-fails" bug, BOTH shapes:
standalone (`let f = \{x,y} -> …`) and HOF element (`List.map (\{x,y} -> …)`).
Fix: a `PRecord` lambda param now renders as a Rust STRUCT PATTERN
`Struct { x, y, .. }` (field-shorthand binds each field; `..` tolerates a
subset-record param; type args inferred) — NO struct-name annotation needed
because the pattern names the type. The struct name is recovered by FIELD-SET
match (`matchStructByFieldsE`, the same heuristic that types a PVar record
closure param), so it works WITHOUT the solver typing the pattern region.
One shared `recordParamOrPlain` helper, routed through all 5 lambda-emit sites
(ExprEmitter substVar `Lambda`/`goDef`/`LetRec`, `annotClosureParam`, the HOF
`annotPsIx`); PVar/PAnything/PTuple keep their unchanged fast path.
Verified: `tests/sky/codegen-record-destructure-param` builds + runs (prints
42, 22); 19-skyforum / 26-ui-showcase / 07-todo-cli (lambda-heavy) + the
generic-recursion fixture all unchanged; cabal spec suite green.

**Affected:** `src/Sky/Generate/Rust/Builder/TypeEmitter.hs`,
`src/Sky/Generate/Rust/Builder/ExprEmitter.hs`,
`runtime-rust/tests/sky/codegen-generic-recursive-adt/`,
`runtime-rust/tests/sky/codegen-record-destructure-param/`.

---

## 2026-06-20 15:00 — Security audit correctness/parity tail (in-boundary, runtime)

Per the broadened goal (fix ALL in-boundary audit items, not only the security
subset), closed the runtime-tractable correctness/Go-parity findings. `cargo
test --features full` green (+ new regressions).

- **path.rs** — rewrote base/dir/ext as faithful Go `path/filepath` ports (Unix)
  including a real `Clean`. Fixes trailing-slash (`Dir("/foo/")`=`/foo`),
  multi-separator (`Dir("a//b")`=`a`), and dotfile (`Ext(".bashrc")`=`.bashrc`)
  divergences from the old OS-tagged std::path impl. +7 parity tests.
- **html.rs** — `escape_attr` `"`→`&#34;` (was `&quot;`) for byte-parity with Go
  `html.EscapeString` (what the equiv tests compare).
- **money.rs** — `money_allocate` remainder via `to_i64()`, not
  `to_string().parse::<i64>()`: a scaled remainder rendered `"1.00"`, failed to
  parse, dropped the penny, mis-distributed (shares summed to 99.99). +regression.
- **string.rs** — `string_is_url` rejects embedded ASCII control bytes (regex host
  class missed them) — Go `url.Parse` parity on the XSS-link gate. +regression.
- **math.rs** — documented the deliberate CONTRACT for min/max NaN tie-break and
  floor/ceil/round saturating float→i64 casts (total; Go's int conversion on
  NaN/Inf is implementation-defined, not a parity target — pin the safe form).

**Re-verified already-fixed (stale deferrals, no action):** `log_*With` renders
attrs via `SkyStringify`; `string_length` is char-count; `bind_sql_param` is
`DbQuery`-aliased (driver-agnostic); `ws closeWithCode` total cast (this session).

**Remaining — CODEGEN-pipeline / diff-protocol items (need `cabal build exe:sky`
+ a Go-oracle fixture + careful cross-site work; a rushed fix would violate
soundness/correctness, so they get a proper focused pass each, NOT a quick
patch):**
- `Pattern.hs` — lambda/closure params that are PCons/PRecord/PCtor/PAlias render
  as `_`, dropping bound names (→ E0425 / wrong arm). Naive `rustSafeIdent` fix is
  unsafe (scope-set vs raw-name mismatch) — needs real pattern lowering.
- `TypeEmitter.hs` — `boxIfRecursive` matches self-type by rendered string, so a
  generic self-recursive enum (`type Tree a = Node (Tree a)` → `MainTree<A>`)
  isn't boxed → E0072. Fix: head-match (modName,typeName); must stay consistent
  with the `ecBoxedCtorFields` recorder.
- `route.rs`/codegen — match-route param-count vs ctor-arity indexing (soundness).
- `uuid_kernel`/Kernel.hs — `Pure.uuidV4/V7` Task-surface unsupported on
  target=rust (completeness; new Task-wrapping kernel wiring).
- `live/diff.rs` — top-level tag/kind mismatch emits no patch (Go emits a
  whole-subtree replace); needs the patch-protocol + a fixture to verify safely.

**Accepted-as-is (parity/by-design, documented):** `string_is_email` vs Go
net/mail + f64 Display vs Go %v (need a fixture corpus); tui non-TTY check (would
break the PTY sweep); `Console.hs` debug-path (brittle only to an anticipated
future --release). Out-of-boundary `app/Main.hs` (upstream PR submitted).

**Affected:** `runtime-rust/src/sky_runtime/path.rs`, `html.rs`, `money.rs`,
`string.rs`, `math.rs`.

---

## 2026-06-20 14:00 — Security audit LOW/bounded-tail hardenings (in-boundary)

Closed the in-boundary remainder of the 2026-06-19 security audit's bounded/low
tail (security = top value). `cargo test --features full`: 480 green (+1 new).
Out-of-boundary `app/Main.hs` shell-injection EXCLUDED per user (upstream PR
already submitted; does not affect the Rust backend).

**Code hardenings (no parity break):**
- **ws_client.rs** `web_socket_close_with_code` — `code as u16` silently
  truncated a Sky `Int` outside 0..=65535 onto a *different valid* close code.
  Now `u16::try_from(code).unwrap_or(1000)` (out-of-range → normal closure).
- **jwt.rs** — reject an EMPTY HS256 secret in encode + decode (zero-length HMAC
  key → trivially-forgeable token). Std.Auth enforces ≥32 upstream; this catches
  a direct misconfigured `Jwt.*` caller. +`test_hs256_empty_secret_rejected`.
- **random.rs** — module SECURITY-INVARIANT doc: `Random.*` is a non-CSPRNG
  (LCG, math/rand parity), MUST NEVER back a secret/token/sid/nonce; enumerates
  the canonical `OsRng` sites so a future change can't silently violate it.

**Documented-as-accepted (parity / key-compat-locked — changing them breaks
Go≡Rust interop = correctness regression, for no in-boundary security gain):**
- crypto.rs — md5/sha1 are collision-broken checksum/interop hashes only (not a
  security primitive); PBKDF2_ITERS=100_000 pinned for cross-backend key/hash
  interop (raising to OWASP ≈600k is a coordinated migration, not a Rust knob).
- uuid_kernel.rs — v7 is sortable/guessable by design, not a secret.

**Re-verified already-fixed (no action):** `basics_mod_by` (checked_rem → no
`i64::MIN % -1` panic; Go-shape remainder adjust), `cookie_value` (exact-key
split_once, not strip_prefix), console `ingest` (DefaultBodyLimit), server
status/maxMessage casts (clamp / try_from), `new_sid` (OsRng).

**Audit status:** zero open in-boundary attacker-reachable security defects.
Only out-of-boundary `app/Main.hs` remains (excluded). Non-security Go-parity
correctness gaps (math float→int saturation, path dir/ext, log `*With` attr
render, escape_attr `&quot;` vs `&#34;`) are tracked separately — they need a
Go-oracle fixture corpus, not a security fix.

**Affected:** `runtime-rust/src/sky_runtime/ws_client.rs`,
`runtime-rust/src/sky_runtime/jwt.rs`,
`runtime-rust/src/sky_runtime/random.rs`,
`runtime-rust/src/sky_runtime/crypto.rs`,
`runtime-rust/src/sky_runtime/uuid_kernel.rs`.

---

## 2026-06-20 13:00 — Security audit fixes, batch 4 (remaining actionable highs + console DiD)

Closed the last of the audit-actionable critical+high findings (the earlier
batches landed in 3b35ba52 / 7954f82d / 94756941). All in-bound, root-cause, no
deferral. `cargo test --features full` green (28 + 6 + others).

**What/why:**
- **email.rs** `send_ses` — SSRF: `cfg.region` is interpolated into the SES host
  (`email.{region}.amazonaws.com`) + the SigV4 credential scope. Validate
  `[a-z0-9-]` before use → a crafted region can no longer redirect the signed
  request to an arbitrary host.
- **html.rs** `render_into` — tag names, attribute keys, and event names are
  emitted UNESCAPED → injection/XSS via `Std.Html.node` / `attribute` / event
  handlers (the name is a Sky `String`, can be attacker-derived). New
  `is_safe_html_name` (`[A-Za-z0-9-_:.]` only); invalid name drops the
  element / attr / event marker rather than emitting it.
- **http_client.rs** `do_request` — unbounded `resp.text()` buffered the whole
  response body into a `String` → OOM DoS from an upstream-controlled body. New
  `read_body_capped` caps at 100 MiB (`SKY_HTTP_MAX_BODY_BYTES`): fail-fast on
  `Content-Length` over cap + incremental enforcement while streaming. Streaming
  consumers use `Http.Stream`.
- **server.rs** `ws_origin_matches` — CSWSH glob bypass: a `*` could span a URL
  delimiter (`/ @ ? #`) so the trusted literal suffix sat behind a path/userinfo
  segment (`https://evil.com/.example.com` matched `https://*.example.com`).
  Wildcard spans that precede a literal anchor are now host-only
  (`[A-Za-z0-9.:-]`); explicit allow-all `*` / trailing-`*` preserved.
  +regression assertions.
- **live/store.rs** — unbounded `mem_cache` on the sqlite/postgres/redis session
  stores: live handles were never evicted, so a cookie-less request flood grew
  RAM without bound (session-DoS). Cache is now `(handle, Instant)` (mirror
  MemoryStore), touched on `get`, idle-TTL-evicted in each `sweep` (+ a new redis
  sweep). Evicted-but-valid sessions re-hydrate Cold from the checkpoint.
- **console_proxy.rs** — added a defense-in-depth `console::gate_blocked` per
  request. The audit's "proxy missing per-request auth" was a FALSE POSITIVE:
  the outermost `observability::track` middleware already gates every
  `/_sky/console*` request (in-process AND proxied) through the same gate. The
  second call hardens the high-value surface against a future router change.

**Ledger reconciliation:** several deferred ⏸️ items proved already-shipped or
false-positives: CSRF middleware + security headers (csrf.rs — shipped),
`crypto.rs randomBytes` return type (already `Task Error String`), console
per-request auth (middleware-layer protection). Updated CODE-REVIEW.md.

**Still open (summarized to user, not fixed):** `app/Main.hs` shell-injection
via `[go.dependencies]` / verify `method` spliced into `sh -c` (OUT OF BOUNDARY —
shared CLI/Go-path; flag upstream); `SKY_CONSOLE_AUTH=app`/token cookie+login
flow (console.rs fails closed 501/Bearer-only — subsystem port); assorted MED
Go-parity correctness gaps needing fixture corpora (math float→int saturation,
path dir/ext, log `*With` attr rendering, ws close-code truncation, escape_attr
`&quot;` vs Go `&#34;`).

**Affected:** `runtime-rust/src/sky_runtime/email.rs`,
`runtime-rust/src/sky_runtime/html.rs`,
`runtime-rust/src/sky_runtime/http_client.rs`,
`runtime-rust/src/sky_runtime/server.rs`,
`runtime-rust/src/sky_runtime/live/store.rs`,
`runtime-rust/src/sky_runtime/live/console_proxy.rs`,
`runtime-rust/docs/CODE-REVIEW.md`.

---

## 2026-06-20 04:30 — Go≡Rust rendered-output equivalence tests (live HTML + Tui grid)

**What.** New `equiv-render.sh` + two normalisers under `scripts/lib/` add STRICT
render-equivalence for the two heavy UI shapes the examples-sweep's weak modes
(live=scenario-boot, tui=pty-no-crash) miss — the shapes where the textarea /
badge / grid / typography regressions slipped through.

- **live** (`equiv_normalize_html.py`): serve both backends, GET `/`, extract the
  `#sky-root` view, and byte-diff after canonicalising the LEGITIMATE
  implementation-detail differences (the backends are committed to BEHAVIOURAL,
  not byte, parity): sky-id separators (`#`/`.`↔`_`, same structural path), attr
  order (both sort for self-determinism; order is arbitrary), event wire-encoding
  (`sky-click="Dec"` vs `="click"+data-sky-on` → canonical event-type set), and
  pseudo/mq/anim/tr style-DELIVERY (Go scoped `<style>` child vs Rust
  `data-sky-*-rules` attrs → dropped). SVG chart coords are MASKED (the known Go
  `Math.min/max`/bar-height float→int truncation, upstream PR #136; un-mask when
  it syncs). **Verified: 26-ui-showcase normalises to a 0-line diff** (665 lines
  each) — structural parity. A future content/structure regression (e.g. the
  textarea-value bug) re-surfaces immediately.
- **tui** (`equiv_tui_grid.py`): capture the initial frame in a fixed 80×N pty,
  render through pyte to a STYLED cell grid (char + fg/bg/bold/italic/underline),
  diff. Catches layout (grid/border/wrap) AND styling (typography/input-bg).
  Verified it DETECTS the current 24-tui-kitchen-sink divergences (will collapse
  to ~0 after the Tui renderer-parity fixes land).

**Sequencing.** The normalisers are verified against real captures from both
backends (live → 0 diff; tui → detects divergences). The full build-harness
green-run + CI wiring is deferred until the in-flight Tui renderer fixes land
(so the tui test commits GREEN, not a known-red baseline) and to avoid racing the
shared `CARGO_TARGET_DIR` while the Tui implementer rebuilds.

**Affected.** `runtime-rust/scripts/equiv-render.sh`,
`runtime-rust/scripts/lib/equiv_normalize_html.py`,
`runtime-rust/scripts/lib/equiv_tui_grid.py` (all new).

---

## 2026-06-20 03:00 — Sky.Tui terminal corruption + blank-frame fixes (Go parity)

Two root causes behind "all TUI examples mess with the terminal (need `reset`)" +
"24-tui-kitchen-sink diverges a lot from Go":

1. **Terminal not restored on `System.exit` (corruption — the `reset` cause).** A
   Sky.Tui app quits via `Quit -> Cmd.perform (System.exit 0)`. Rust's
   `system_exit` was a bare `std::process::exit`, which **bypasses Drop** — so the
   `TuiGuard` destructor (cooked mode + show cursor + main screen + mouse off)
   never ran, leaving the TTY wedged. Go avoids this: `System_exit` calls
   `tuiTeardown()` BEFORE `os.Exit`. Mirrored it: a process-exit hook
   (`system.rs register_exit_hook`/`run_exit_hook`, a plain `fn()` so the
   always-compiled `system` module never references feature-gated `tui`/crossterm)
   that the Sky.Tui driver registers with an idempotent `tui_teardown`;
   `system_exit` runs it before `process::exit`. Verified in a pty: the quit now
   emits `MOUSE_OFF + SHOW_CURSOR + ALT_SCREEN_OFF` + disables raw mode.

2. **`term_size` rendered a 1×1 (blank) frame.** `crossterm::terminal::size()`
   returns `Ok((0,0))` on a pty with no winsize / a non-interactive pipe; the old
   `term_size` clamped that to `(1,1)` (`w.max(1)`), so the whole UI rendered into
   one cell. Go falls back to 80×24. Fixed: fall back to 80×24 when the size is
   `Err` OR 0 in either dimension. Verified via a sized (80×24) pty + a pyte
   render: the full kitchen-sink UI now renders.

**Residual (documented, not yet fixed).** With both fixes the UI renders fully,
but the INITIAL viewport still differs: Rust scrolls to the first focusable (the
section-5 input) on init, Go shows the top. Both run identical init code
(`focusIdx=0; ensureFocusVisible(...)`) and `ensure_focus_visible` is
byte-identical — so the divergence is upstream, in the focused element's computed
line / focus-collection. Needs a focus-model comparison; tracked for follow-up.

**Affected.** `runtime-rust/src/sky_runtime/system.rs` (exit hook + system_exit +
test), `runtime-rust/src/sky_runtime/tui/app.rs` (TuiGuard→exit-hook + tui_teardown
+ term_size fallback).

---

## 2026-06-20 01:30 — 26-ui-showcase Go≡Rust: textarea value→content (Rust fix); sparkline/heatmap = Go Math bug

**Investigation.** Diffed the rendered `/` HTML of 26-ui-showcase on both backends.
Three divergences, TWO distinct root causes:

1. **`Input.multiline` text dropped (RUST BUG — fixed here).** Rust rendered
   `<textarea … value="fill the column"></textarea>` — but `<textarea>` has no
   `value` attribute in HTML; the value must be the TEXT CONTENT, so the browser
   showed an empty box. Go strips `value` and splices it as content. Fixed
   `html.rs render_into`: strip `value` from `<textarea>`/`<select>` attrs and
   (textarea, no explicit children, non-empty) emit the escaped value as content —
   mirrors Go `live.go renderVNode`. Now Rust emits `>fill the column</textarea>`.

2. **sparkline + heatmap coordinates differ (GO CODEGEN BUG — Rust is correct).**
   Both use `Math.min`/`Math.max` (typed `a -> a -> a`, "any comparable type") to
   compute their value range over a `List Float`. The GO CODEGEN lowers these to
   the **Int-typed companion** `rt.Math_minT(rt.AsInt(lo), rt.AsInt(x))` (verified
   in generated `main.go` `Std_Ui_Chart_yRangeHelp`/`xRangeHelp`) — the `AsInt`
   coercion TRUNCATES the Floats, so the range of `[0.4 … 1.3]` collapses to
   `(0, 1)` and the sparkline path / heatmap cell scaling is wrong. (Note: the
   `any` runtime `Math_min`/`Math_max` ALSO compare via `AsInt` — a sibling latent
   bug — but the chart never reaches them; the codegen picks `Math_minT` directly.)
   Rust's `math_min`/`math_max` are generic `T: PartialOrd` (`a <= b`), correct on
   `f64`. Hand-computed range `(0.31, 1.39)` → first y `29.33`, last `2.67` = the
   RUST output; Go's `18.67 … −5.33` matches the truncated `(−0.1, 1.1)` range.
   NOT a Rust defect — the fix is in the Go backend (codegen must not select the
   Int companion for a Float `Math.min`/`Math.max`, AND the `any` runtime fns
   should compare via `skyLessThan`). Out of the Rust boundary; reported to the
   author for a Go-backend fix. A speculative runtime-only `Math_min`→`skyLessThan`
   patch was tried and REVERTED — it doesn't touch the chart's `Math_minT` path.

**Verified.** New `html.rs` unit tests (textarea value→content, escaping,
explicit-children-win, select strips value) pass; `cargo check --features full`
clean; 26-ui-showcase rebuilt on Rust now renders the textarea content.

**Affected.** `runtime-rust/src/sky_runtime/html.rs` (textarea/select value
handling + 2 regression tests).

**Follow-up — dev console badge byte-parity (RUST fix).** A 4th divergence found
while screenshotting: the floating "Console" dev badge differed visibly — Go
emits a blue monospace `#7eb6ff` link (`id=__sky-dev-console`, `target=_blank`,
`rel=noopener`, `title`, `right/bottom:12px`, `&#128269;` ENTITY); Rust emitted a
green sans-serif `#8ec8a8` link (`id=__sky-console-link`, `aria-label`,
`right/bottom:16px`, literal 🔍). Rewrote `dev_console_banner` (`live/mod.rs`) to
byte-match Go's `devBannerHTML` (dev_banner.go), honouring `SKY_CONSOLE_URL` with
attribute-escaping. Verified byte-identical to Go on the live page; 2 regression
tests (markup match + sub-app suppression).

**Visual confirmation (screenshots).** The heatmap renders as a single broken cell
on Go (truncated range) vs the full 24×7 grid on Rust — confirming Rust is the
correct backend for the chart math, and the Go `Math.min/max` truncation is a
genuine bug, not deliberate tuning.

---

## 2026-06-20 00:30 — Root-cause + mitigate 12-skyvote / 17-skymon CI Playwright timeout (suggestion #6)

**Root cause.** Both examples have CUSTOM browser scenarios in the shared
`scripts/verify-scenarios.mjs` that are NAVIGATION-HEAVY:
- `skyvote` — visits /about + /roadmap, signs up (DB write), submits an idea (DB
  write), upvotes (DB write), signs out: ~6 full `gotoAndSettle` navigations each
  with a settle wait, plus form fills.
- `skymon` — `gotoAndSettle` over 5 pages (`/`, `/status`, `/settings`, `/alerts`,
  `/auth`) with a 1s settle each.

On a shared CI runner under build+browser load, the cumulative Playwright
navigation + settle time exceeds the 30s `SCENARIO_TIMEOUT_MS` default. The time
is dominated by browser navigation + settle + runner load, NOT backend speed —
which is exactly why the GO reference times out IDENTICALLY (→ amber
`go-ref-broken`, already non-failing per the sweep's RED→AMBER downgrade). So this
is a harness/load issue, NOT a Rust-backend defect.

**Mitigation.** Raise `SKY_SCENARIO_TIMEOUT_MS` to 90000 (3×) in the examples-sweep
CI job env — the per-scenario ceiling is already env-overridable; the local
default stays 30s. Gives a slow-but-correct round-trip room to complete on a
loaded runner, which should turn 12/17 from amber → green. (Validated on the next
CI sweep per the no-local-sweeps policy; the navigation-heavy scenarios can't be
meaningfully reproduced on the slim local box.)

**Affected.** `.github/workflows/examples-sweep.yml` (`SKY_SCENARIO_TIMEOUT_MS`
job env).

---

## 2026-06-19 21:40 — Go≡Rust equivalence-fixture corpus (suggestion #8)

**What.** New `runtime-rust/scripts/equiv-corpus.sh` — a curated set of small,
pure-stdlib, deterministic-stdout fixtures under `runtime-rust/tests/sky/` that pin
SPECIFIC kernel/codegen behaviours the example sweep doesn't exercise (the "green
build ≠ correct" gap). Each is built on BOTH backends (`--backend go` FORCED — the
fixtures pin `backend = "rust"`), run in an isolated cwd, and its stdout compared
byte-for-byte after a light normalisation (blank lines + the RFC3339 log
timestamp, the only legitimately non-deterministic token). A fixture that doesn't
build on Go (needs a Rust-only FFI crate / a missing Go kernel) auto-SKIPs — the
corpus is deliberately pure-stdlib. Green baseline: `23-char`,
`53-cons-pattern-tuple`, `60-errortostring-string`, `63-int-overflow-wrap`,
`64-log-with-attrs`, `65-crypto-random-encoding` — 6 ok / 0 fail / 0 skip. Wired
into the examples-sweep CI as a gating ubuntu-only step.

**High value: it caught a verification-methodology bug.** The corpus exposed that
the fixtures' `sky.toml backend = "rust"` makes a bare `sky build`/`sky run`
produce the RUST binary — so the earlier "Go vs Rust" checks for #4/log/crypto
were actually RUST-vs-RUST. Forcing `--backend go` gives the TRUE Go≡Rust diff,
which now retroactively validates those three fixes against the real Go runtime
(all match, modulo the normalised timestamp).

**Found issues (surfaced BY the corpus, held out of the green baseline):**
- `49-bytes-core` — Rust E0282: `bytes_from_hex`/`bytes_from_base64` return
  `SkyResult<E,T>` and `E` is unconstrained at the `match` call site (the Err arm
  doesn't pin it). In-boundary Rust codegen gap (an E-pinning wrapper like
  `log_*_with` would fix it). Pre-existing (unrelated to this session's changes);
  tracked for a follow-up.
- `56-list-sort` — Go build fails: `List.sortWith`/`sortBy` has no `List_sortWith`
  kernel in the GO backend (`kernelToGo` default). Out of the Rust boundary
  (shared stdlib / Go codegen); can't be a Go≡Rust member until Go gains it.

**Affected.** `runtime-rust/scripts/equiv-corpus.sh` (new),
`.github/workflows/examples-sweep.yml` (gating ubuntu step).

---

## 2026-06-19 21:10 — Scheduled security re-audit CI workflow (suggestion #3)

**What.** New `.github/workflows/security-audit.yml` — a fork-local scheduled
re-audit so the no-panic / no-Any / constant-time-secret-compare invariants can't
silently rot between releases. Runs `runtime-rust/scripts/quality-audit.sh`
(clippy -D + tests HARD gate + the panic-vector / unsafe / dyn-Any / `#[allow]`
advisory harvest) plus a focused `rg` pass for the two highest-severity CLAUDE.md
learning classes: non-constant-time secret/token/MAC compares and panicking i64/
Decimal arithmetic.

**Triggers.** Weekly cron (Thu 05:23 UTC, offset from the Mon examples-sweep cron)
+ `workflow_dispatch` + push touching `runtime-rust/src/**` / Cargo / the audit
script. Forces `ref: feat/runtime-rust` on schedule (GitHub fires crons from the
default branch). **Gating:** fails ONLY on the hard gate (clippy -D OR a test
failure → quality-audit.sh exit 1); the grep/vector findings are advisory job-
summary triage, never a silent pass and never a veto. Uploads the full audit
report artifact.

**Verified.** YAML parses; the focused secret-compare + panic-arith grep patterns
run locally and surface triage candidates (mostly false positives — UI label
`== "password"`, f64 test asserts — confirming the advisory framing).

**Affected.** `.github/workflows/security-audit.yml` (new, fork-local).

---

## 2026-06-19 20:50 — Std.Db driver portability: postgres/mysql projects now cargo-build

**What.** A `[database] driver = "postgres"` (or `mysql`) Std.Db project failed
`cargo build` with two `sqlx::Sqlite`-rooted errors, because the postgres driver
feature does not enable sqlx's `sqlite` feature. Two independent causes, both fixed:

1. **`db.rs` `bind_sql_param`** hardcoded `sqlx::query::Query<'q, sqlx::Sqlite,
   sqlx::sqlite::SqliteArguments<'q>>` in its signature → E0433 on a postgres-only
   build. Re-typed on the existing driver-agnostic `DbQuery<'q>` alias (the
   configured backend's query type). Each bound value (String/i64/f64/bool/
   Vec<u8>/Option) impls `Encode + Type` for both Sqlite and Postgres, so the
   monomorphic per-build `q.bind(..)` resolves on either backend.
2. **`telemetry_spill.rs`** (the console spool — an inherently-SQLite local file,
   Go-parity `SKY_CONSOLE_DB_PATH`) is compiled on EVERY Std.Db build (`Project.hs`
   `dbMod`, gated on `usesDb`) and uses `sqlx::SqlitePool`. A postgres app didn't
   enable sqlx `sqlite` → E0432 (`SqlitePool`) + E0282 (`sqlx::query` type). Fixed
   in `Emitter.hs sqlxFeats`: add `sqlite` to the sqlx feature set whenever
   `usesDb`, in addition to the app's own driver. So a postgres app links
   `["postgres", "sqlite"]` (app DB + spool); a sqlite app stays `["sqlite"]` (no
   bloat — Set-deduped).

**Verified.** New compile-only fixture `tests/sky/66-db-postgres-compile`
(`driver = "postgres"`, exercises `Db.insertFields`/`SqlValue` → bind_sql_param):
`cargo build` succeeds, features `["runtime-tokio-rustls", "postgres", "sqlite"]`.
Not run (postgres needs a server; the gate is compile). Sqlite path unregressed:
`kernel-parity-probe-sqlfields` runs → `SQLFIELDS PROBE OK`, features `["…","sqlite"]`
only. Standalone runtime `cargo check --features full` clean.

**Affected.** `runtime-rust/src/sky_runtime/db.rs`,
`src/Sky/Generate/Rust/Builder/Emitter.hs`,
`runtime-rust/tests/sky/66-db-postgres-compile/` (new compile-only fixture).

---

## 2026-06-19 20:20 — Crypto.randomBytes/randomToken Go-parity encoding (hex String / base64url)

**What.** Two Go-parity correctness bugs in the entropy kernels:

- `Crypto.randomBytes : Int -> Task Error String` — Go returns the bytes as a
  lowercase HEX string (`hex.EncodeToString`), and the Sky signature is `String`,
  but the Rust runtime returned `Vec<i64>` (a byte list). A Sky call site treating
  the result as a String/Bytes mismatched at codegen. Now returns a hex `String`
  via a shared `hex_lower` helper (high-nibble-first, byte-order identical to Go).
- `Crypto.randomToken : Int -> Task Error String` — Go returns URL-safe base64 with
  NO padding (`base64.RawURLEncoding`), but the Rust runtime hex-encoded (wrong
  alphabet AND wrong length; the manual hex loop also had its nibbles reversed).
  Now `base64::URL_SAFE_NO_PAD.encode`.

Codegen kept in step: the hardcoded `crypto_random_bytes` FFI wrapper return type
(`Emitter.hs`) and the `taskExprInnerTypeCall` hint (`ExprEmitter.hs`) both moved
`Vec<i64>` → `String`.

**Verified (Go≡Rust).** New fixture `tests/sky/65-crypto-random-encoding`: both
backends print `bytesLen=16 tokLen=8` (randomBytes 8 → 16 hex chars; randomToken 6
→ 8 base64url chars — the lengths pin each encoding; pre-fix Rust gave a byte list
+ a 12-char hex token). `00-standard-libs` still `131 passed, 0 failed`. No example
uses `randomBytes` (so the wrapper type change has no call-site fallout);
`randomToken` is used display-only for errIds in 18/36.

**Affected.** `runtime-rust/src/sky_runtime/crypto.rs`,
`src/Sky/Generate/Rust/Builder/Emitter.hs`,
`src/Sky/Generate/Rust/Builder/ExprEmitter.hs`,
`runtime-rust/tests/sky/65-crypto-random-encoding/` (new fixture).

---

## 2026-06-19 19:45 — Stop example DBs leaking into the repo root (sweep + perf runner cwd isolation)

**What.** Example binaries that open a cwd-relative `./*.db` (Sky.Db / Sky.Live
sqlite store / a CLI todo DB) were writing it into the REPO ROOT, because the
sweep + perf runners invoke the binary with cwd = repo root. 21 stray files had
accumulated (`chat.db`, `composite-server.db`, `dbdec-probe.db`, `skychess.db`,
`skymon.db`, `skyvote.db`, `todos.db` × {.db, -shm, -wal}). They were already
gitignored (never committed) but cluttered the working tree.

**Fix — run every example binary from an ephemeral TMPDIR scratch cwd:**
- `lib/checks.sh`: `exercise_server`/`exercise_live` already isolated cwd; added
  the same isolation to `exercise_cli`, `exercise_tui`, `exercise_webview` (new
  shared `_abs_bin` helper absolutises the binary before the `cd`). So the
  examples-sweep RUN + cli-stdout EQUIV paths land DB state in TMPDIR, never root.
- `rust-perf.sh`: the 4 binary-launch sites (`probe_coldstart_cli` hyperfine,
  `probe_coldstart_server`, `start_server`, `probe_rss_cli` time -v) now launch
  via `( cd "$(perf_app_cwd)" && … )`. `perf_app_cwd` hands out fresh dirs under
  one per-run parent that `run_one`/`baseline` wipe via `perf_cwd_cleanup`.

**Verified.** Wiped the 21 root files. Ran `exercise_cli` from the repo root on
`17-db-todo-cli` and the `kernel-parity-probe-dbdec` probe (the latter opens a DB
at startup → previously wrote `dbdec-probe.db` to root): repo root stays clean,
exit 0. `bash -n` clean on both scripts; `examples_test.sh` 8/8 ok.

**Affected.** `runtime-rust/scripts/lib/checks.sh`,
`runtime-rust/scripts/rust-perf.sh`.

---

## 2026-06-19 19:10 — Std.Log.*With now flatten attrs onto the line (Go-parity), via SkyStringify bound

**What.** `Log.{info,error,warn,debug}With : String -> List a -> Task` previously
DROPPED the attrs slot in the Rust runtime (a TODO from when no element bound was
chosen) — the attrs never reached the log line. Now they are flattened onto the
message byte-for-byte like Go's `renderLogMsgWithAttrs`: `msg a1 a2 …`, each `ai`
rendered via the TOTAL Go-`%v` stringifier `SkyStringify`.

- **Runtime** (`log.rs`): new `render_with_attrs<A: SkyStringify>` helper; the
  four `log_*_with` fns bound `A: SkyStringify`, render before the future
  (`Send`-clean `String`, no `A: Send` needed), and pass the flattened line to
  `log_emit` — so the plain path sanitises attr values too (no newline injection
  via an attr) and the JSON path surfaces them inside `msg` exactly as Go does
  for the List call shape (Go's With variants pass `ctx=nil`).
- **Codegen** (`Emitter.hs`): the hardcoded FFI wrappers `log_info_with` /
  `log_error_with` now carry `<A: SkyStringify>` (was bare `<A>` → E0277 against
  the bounded runtime fn). `Display` was wrong — tuples + generated records don't
  impl `Display` (the original E0277 in routes_auth/routes_todos); `SkyStringify`
  is impl'd for String, tuples `(A,B)`/`(A,B,C)`, Vec, and every codegen ADT/
  record, so it is satisfiable at every concrete element type. Added the missing
  `log_debug_with` / `log_warn_with` wrappers so all four levels carry the same
  E-pinning + bound consistently.

**Verified (Go≡Rust).** New fixture `tests/sky/64-log-with-attrs`: Rust and Go
both emit `INFO flat ok 200` (flat `List String`) and
`INFO tuple {errId abc} {code 42}` (`List (String,String)`, Go's `%v` of a tuple
= `{k v}`) — byte-identical modulo timestamp. `17-db-todo-cli` (flat errorWith,
cli) builds+runs; `36-composite-server` (tuple errorWith + warnWith) builds clean
— no duplicate-definition collision from the new wrappers.

**Affected.** `runtime-rust/src/sky_runtime/log.rs`,
`src/Sky/Generate/Rust/Builder/Emitter.hs`,
`runtime-rust/tests/sky/64-log-with-attrs/` (new fixture).

---

## 2026-06-19 18:30 — Go-parity i64 wraparound: generated `[profile.dev] overflow-checks = false` (suggestion #4)

**What.** Generated project's `[profile.dev]` now emits `overflow-checks = false`
(`emitCargoToml`). Go's `int` is 64-bit two's-complement and WRAPS on overflow;
Rust debug builds default `overflow-checks = true` and PANIC on a bare
`+`/`-`/`*` overflow. A well-typed Sky program doing extreme i64 arithmetic could
therefore abort in a debug build — a no-panic-from-well-typed-Sky violation.
Disabling the debug overflow trap restores Go's wraparound and aligns dev with
release (release already defaults `overflow-checks=false`).

**Why this over per-op codegen wrapping.** Wrapping each emitted `+`/`-`/`*` in
`wrapping_*` would require discriminating Int vs Float at every arithmetic emit
site (high blast radius) for a debug-only, extreme-value bug. The profile flag is
one line, total, and the explicit `checked_*`/saturate kernel guards (Math.abs,
Basics.modBy, Std.Decimal, Auth.signToken, Cache.withTTL) are unaffected — they
call `.checked_*()` regardless of profile, so their intended total semantics hold.

**Verified.** New fixture `tests/sky/63-int-overflow-wrap` prints
`max+max=-2 max*2=-2` (i64::MAX wraps to -2, exactly like Go); pre-fix this aborts
with "attempt to add with overflow" in debug. `00-standard-libs` still `131
passed, 0 failed` (normal arithmetic unaffected). Generated `Cargo.toml`
`[profile.dev]` confirmed to carry the key.

**Affected.** `src/Sky/Generate/Rust/Builder/Emitter.hs` (emitCargoToml),
`runtime-rust/tests/sky/63-int-overflow-wrap/` (new regression fixture).

---

## 2026-06-18 — README + documentation overhaul (slim README + TECHNICAL-DETAILS + provenance)

**What.** Restructured the docs per the approved spec
(`docs/superpowers/specs/2026-06-18-readme-docs-overhaul-design.md`) + plan
(`docs/superpowers/plans/2026-06-18-readme-docs-overhaul.md`). 8 commits
(`c31786c0`..`55c4bf7d`).

- **Provenance.** `examples-perf-sweep.sh` + `static-perf.sh` now write a
  `*.provenance` sidecar (stamp/os/arch/runner); `readme-tables.py` emits a
  `> _Machine-measured · <stamp> · <runner> <os> (<arch>) · <sweep>_` banner inside
  AUTOGEN:examples-table / perf-verdict / static-table (falls back to the local
  platform for a local seed; CI provenance overrides).
- **Docs pruned.** Wiped 10 plans + 25 shipped specs + the conquest registry +
  escalated-decisions + upstream-pr-proposals; kept the 4 referenced spec sets +
  this overhaul's spec/plan. Lifted ADR 0001 (Sky container types stay transparent
  aliases, not newtypes) into CLAUDE.md `## Agent learnings`; `docs/adr/.gitkeep`.
- **PROGRESS moved.** `runtime-rust/PROGRESS.md` → `runtime-rust/docs/PROGRESS.md`;
  repointed CLAUDE.md + update-docs skill (root `.md` cap is now CLAUDE.md +
  README.md).
- **README halved.** 1228 → 735 lines. Deep internals (Architecture / Verification
  state / Error type / Soundness / Build-perf / allocator 2×2 / FFI coercion) moved
  verbatim to `docs/TECHNICAL-DETAILS.md`. README kept: Contract · Getting started ·
  Project status · Static & cross compilation · **new `## FFI usage`** (lifted
  sky.toml fields + wrapper note) · Known limitations · Glossary.
- **Readability.** GHC de-pinned (`>= 9.6.7`); cross-OS "continue with" anchor
  links; macOS musl command moved inside a code block; the Fast-build `Why:` block
  rewritten as bullets (line break per semicolon); Round-trip / Perf-columns /
  Equiv-modes inline lists converted to tables (Equiv legend now precedes the
  examples table).
- **Governance.** update-docs skill section list rewritten to the slim README +
  TECHNICAL-DETAILS as a second maintained file; CLAUDE.md `### Domain docs` +
  settled-rule reconciled.

**Affected.** `runtime-rust/scripts/{examples-perf-sweep,static-perf}.sh`,
`runtime-rust/scripts/readme-tables.py`, `runtime-rust/README.md`,
`runtime-rust/docs/TECHNICAL-DETAILS.md` (new), `runtime-rust/docs/PROGRESS.md`
(moved), `runtime-rust/docs/adr/.gitkeep`, `runtime-rust/CLAUDE.md`,
`runtime-rust/plugins/sky-rust-backend/skills/update-docs/SKILL.md`, + 39 pruned
docs files.

---

## 2026-06-18 — CI→README: live status badge (the snapshot-table honesty fix)

**What.** The auto-written examples table hardcodes Build/Run = ✅ (it is only
rewritten on a green sweep), so on a broken backend it would silently go stale and
mislead a reader into thinking the table is live. Fix: a **live `examples-sweep`
status badge** at the top of Project status — the only thing that is actually live
(any committed table is stale the instant after it is written). Green = latest
sweep on `feat/runtime-rust` HEAD passed; red = a check failed → the run's
job-summary BUILD·RUN·EQUIV table (rendered on every run, pass or fail) shows which
example broke. Re-labelled the headline + the examples-table intro as the
"last-green snapshot", pointing at the badge for live truth.

**Affected.** `runtime-rust/README.md` (Project-status badge + snapshot labelling).

---

## 2026-06-18 — CI→README automation, round 2: perf table + parity verdict auto-written

**What.** Extended the round-1 automation (below) to fully auto-write the
examples/perf table AND replace the hand-written perf headline bullets with a
machine-generated per-metric parity verdict. Decided with the user: **geometric
mean** of per-example Rust/Go ratios (Fleming-Wallace CACM 1986 / SPEC), **±10%**
parity band (absorbs shared-CI throughput noise), **per-metric** (4 lines, not one
blended — keeps the deterministic ~25× binsize win from drowning the noisy ~parity
throughput signal).

- **`readme-tables.py examples`** (new subcommand) — writes TWO fenced regions from
  the perf TSV: `AUTOGEN:examples-table` (joins the committed editorial sidecar
  `readme-examples.tsv` with the fresh perf ratios; Build/Run hardcode ✅ since the
  CI writer gates on a green sweep) and `AUTOGEN:perf-verdict` (per-metric 3-state
  verdict: Rust outperforms / at parity / underperforms Go, from the geomean vs the
  ±10% band). `--check` exits 3 on drift; `--band` overrides.
- **`readme-tables.py readme-examples.tsv`** (new sidecar) — the human-owned
  editorial columns (example, shape, round-trip, equiv-cell) extracted verbatim
  from the committed table. The ONLY place those columns are edited.
- **README** — wrapped the examples table in `AUTOGEN:examples-table`; replaced the
  three perf headline bullets with the `AUTOGEN:perf-verdict` fence (seeded with
  REAL generated content from the local perf cache: throughput 2.07×, RSS 0.21×,
  cold 0.63×, binsize 0.024× — all "outperforms" at ±10%). Verified the generator
  round-trips the examples table from the sidecar + perf TSV.
- **examples-sweep.yml `update-readme`** — now regenerates all THREE regions
  (`static` + `examples`); `needs: [examples-sweep, examples-perf-sweep,
  static-perf]` (examples-sweep = the green gate; the table hardcodes ✅ so it must
  only publish on a fully-green sweep); downloads all result artifacts (flat) so the
  generator finds both `static-perf-*.tsv` and `perf-*.tsv`.

**Why the green gate.** The examples table hardcodes Build/Run = ✅; gating
`update-readme` on a non-continue-on-error `examples-sweep` success means a RED
sweep skips the writer, so the README never shows a false all-green table.

**Affected.** `runtime-rust/scripts/readme-tables.py`,
`runtime-rust/scripts/readme-examples.tsv` (new), `runtime-rust/README.md`
(examples-table + perf-verdict fences), `.github/workflows/examples-sweep.yml`
(update-readme: 3 regions + green gate), `runtime-rust/CLAUDE.md`,
`runtime-rust/plugins/sky-rust-backend/skills/update-docs/SKILL.md`.

---

## 2026-06-18 — CI→README automation: AUTOGEN fences + generator + update-readme job + cron

**What.** Automated the README's machine-generated tables off the CI sweep data,
so they no longer rot between hand-runs of update-docs.

- **`runtime-rust/scripts/readme-tables.py`** (new) — the single writer of the
  README's fenced `AUTOGEN` regions. `static` subcommand regenerates the cross-OS
  static-build table from the three `static-perf-<OS>-*.tsv` artifacts (recursive
  glob under `--results`); `--write` splices it between the
  `<!-- AUTOGEN:static-table … -->` fences, `--check` exits 3 on drift. Self-emits
  its own "do-not-hand-edit" note as the first body line so the warning survives
  every regen. `headline-check` subcommand reports (job-summary markdown, always
  exit 0) whether the committed sweep headline / perf numbers have drifted — it
  does NOT write.
- **README** — wrapped the static cross-OS table in `AUTOGEN:static-table` fences.
  Verified the generator round-trips the committed table byte-identically from a
  reconstructed TSV set (faithful transform: K-sizes, Static/Dyn ratios incl. the
  macOS `*`, `dyn→static` perf cells, ✅/❌ build).
- **`.github/workflows/examples-sweep.yml`** —
  - `schedule:` weekly cron (`17 6 * * 1`); perf + static-perf `if:` now also fire
    on `schedule`; every checkout pins `ref: feat/runtime-rust` on schedule (GitHub
    runs cron only from the default branch's workflow copy).
  - per-push **README sync check** step (ubuntu, non-gating, always-exit-0) runs
    `headline-check` into the job summary so drift is visible on every push.
  - new **`update-readme`** job (`needs: static-perf`, `permissions: contents:
    write`, dispatch+schedule): downloads the `static-perf-*` artifacts, runs the
    generator `--write`, and on a real diff commits `… [skip ci]` + pushes to
    feat/runtime-rust. `[skip ci]` + the GITHUB_TOKEN no-recursion rule prevent a
    trigger loop; the `**.md` paths-ignore keeps the docs commit from re-running
    the sweep.

**Why static-only auto-write.** The static table is pure CI-only data (no host
makes it locally) with no adjacent volatile prose → safe to overwrite. The
examples/perf table is intentionally left hand-written (update-docs): its noisy
per-run perf numbers sit beside editorial perf headlines only update-docs can keep
consistent, so a blind auto-write would desync table ↔ prose (a correctness
regression). CI flags its drift instead of overwriting it.

**Affected.** `runtime-rust/scripts/readme-tables.py` (new),
`runtime-rust/README.md` (static-table fences), `.github/workflows/examples-sweep.yml`,
`runtime-rust/CLAUDE.md` (settled-rule: AUTOGEN fences),
`runtime-rust/plugins/sky-rust-backend/skills/update-docs/SKILL.md` (second boundary).

---

## 2026-06-18 — Rename: `--target`→`--backend` (backend); `--target`=cross triple

**Why.** The fork introduced `--target` + `CompileTarget` in the founding Rust
commit (`42e67992`); upstream (anzellai/sky) has no backend flag at all — verified
fork-only. So `--target` was overloaded onto two axes (backend vs OS/arch). Renamed
to match Rust conventions; nothing upstream to conflict with.

- **Backend selector:** `--target rust` → **`--backend rust`**; `[project] target`
  → `[project] backend`; Haskell `CompileTarget`→`Backend`, `Target{Go,Rust}`→
  `Backend{Go,Rust}`, `parseCompileTarget`/`parseTarget`→`parseBackend`.
- **Cross-compile:** `--platform <alias>` → **`--target <raw triple>`**;
  `[rust] target` now a raw triple; `SKY_RUST_TARGET` unchanged. **Aliases
  DROPPED** (`resolvePlatformAlias` deleted) — raw triples match `cargo --target`,
  are self-documenting, and cross-compilation already requires the triple.
- **Migration guard:** old `--target rust|go` now ERRORS with a hint (not silently
  stripped → default-Go build).
- **Scope (option 1):** all functional code (GHC gated the 12 `.hs` files), 69
  fixture `sky.toml`, CI scripts/workflows, plugin skills, `.sky` comments,
  `examples/rust/skyshop-rs`, current docs. Dated `superpowers/` archaeology left
  as-is.

**Verified.** `--backend rust` + `[project] backend=rust` build Rust; `--target
<triple>` cross-builds; old `--target rust` errors; `--static`/`--mimalloc`
compose. **Affected:** `app/Main.hs`, `src/Sky/Sky/Toml.hs`, +10 `.hs`, 69 toml,
scripts, skills, docs. Commit `b66c25ec`.

## 2026-06-18 — Opt-in full-static binaries + cross-compilation + release strip

**What.** Added an opt-in static-linking + cross-compile path to `--backend rust`,
plus release-binary stripping and a static-vs-dynamic size benchmark harness.

- **`strip`**: generated `[profile.release]` now sets `strip = true` (Go's
  `-ldflags=-s -w` equivalent) — release binaries ship without the symbol table.
  Dev profile keeps symbols.
- **Static linking** (`[rust] static = true` / `--static` / `SKY_RUST_STATIC=1`):
  Linux → `x86_64-unknown-linux-musl` (true static-pie) + `--features
  static_alloc`; Windows → `RUSTFLAGS=-C target-feature=+crt-static`; macOS →
  degrade to native dynamic + a warning showing the cross-compile recipe; webview
  apps → refused (link system WebKit). De-risked locally on a cli (01) and a
  DB+crypto example (18, sqlx/sqlite/ring) — both fully static.
- **mimalloc global allocator** (`[rust] allocator = "system" | "mimalloc"` /
  `--mimalloc` / `--system-alloc` / `SKY_RUST_ALLOC`, DECOUPLED from static):
  codegen always emits an *optional* `mimalloc` dep + a
  `#[cfg(feature="static_alloc")] #[global_allocator]` shim — inert unless the
  build enables `static_alloc`. AUTO default: mimalloc on musl/static, system
  (glibc ptmalloc2) on dynamic. Chosen over a bump/arena allocator (can't free
  per-object → unbounded RSS → OOM as a global allocator); no bump allocator
  anywhere. **Measured (alloc-stress 2×2, allocation-heavy Sky.Http.Server,
  ab -c50):**

  | variant | throughput | peak RSS |
  |---|--:|--:|
  | A dynamic + glibc malloc | 1457/s | 8.5 MB |
  | B dynamic + mimalloc | 2511/s (1.72× A) | 16.3 MB |
  | C static(musl) + mimalloc | 2149/s (1.48× A) | 14.7 MB |
  | D static(musl) + musl malloc | ~192/s (0.14× A) | 7.8 MB |

  Findings: mimalloc is **1.72×** glibc on dynamic; musl's own malloc is **~7×
  slower** than glibc (and ~11× slower than mimalloc), and it's NOT
  contention-driven (192/s at c=4 ≈ c=50) — musl malloc is just slow for
  high-volume small allocations. So `--static` keeps mimalloc default-on (a
  musl+system build is a ~11× cliff; allowed only with a loud warning for
  RSS-constrained deploys, where D's 7.8 MB is the draw). RSS-bounded under
  sustained churn (C growth 1.024×).
- **Cross-compilation** (`[rust] target` / `--platform <alias|triple>` /
  `SKY_RUST_TARGET`): orthogonal to `static`. Aliases `linux-musl`,
  `linux-musl-arm64`, `linux-gnu`, `linux-gnu-arm64` + raw-triple passthrough;
  `planRustBuild` resolves the triple, sets the `CARGO_TARGET_<T>_LINKER` musl
  cross-linker, detects a missing rustup target / musl C toolchain with
  actionable errors, and nests the binary path under the target subdir. Linux
  legs verified locally; macOS-host→Linux leg implemented, pending macOS
  verification.
- **CLI flags** `--static` / `--platform` are stripped from argv into env before
  the strict optparse parser, so they compose with the backend `--backend rust`
  without clashing.

**Affected.** `src/Sky/Sky/Toml.hs` (`_rustStatic`, `_rustTarget` + parsers),
`src/Sky/Generate/Rust/Builder/Emitter.hs` (strip, mimalloc dep/feature/shim),
`app/Main.hs` (`planRustBuild` + helpers, `preprocessRustBuildFlags`, build/run
wiring), `runtime-rust/scripts/static-bench.sh` (new size benchmark). Commits:
`55e22ad1` (strip), `bc97cfe7` (static+mimalloc), + cross-compile.

## 2026-06-17 18:30 — Modern wry/tao migration (de-risk the cross-OS webview spine)

Replaced the stale wry 0.24 / tao 0.16 webview stack (legacy `objc 0.2` → breaks
on Xcode 16; old `webview2-com-sys`/`windows` → breaks on Windows-2025; AND
unconditional Linux-only `EventLoopExtUnix` → wouldn't even compile on
macOS/Windows) with **wry 0.55 / tao 0.35 / raw-window-handle 0.6.2** — the modern
objc2 + current-windows-rs stack that builds on all three OSes. Resolved the triple
via `cargo add` iteration; built+verified on this Linux box (webkit2gtk-4.1 +
libsoup-3.0).

API migration in `webview.rs` `webview_app` (real `#[cfg(feature="webview")]` imp):
- `wry::webview::WebViewBuilder/WebView` → crate-root `wry::WebViewBuilder/WebView`.
- `WebViewBuilder::new(win)` (by-value) → `WebViewBuilder::new()` (no-arg) +
  `.with_html(html)` (now infallible) + `.with_ipc_handler` whose closure takes
  `wry::http::Request<String>` (was `(&Window, String)`) — body via `req.into_body()`.
- **Per-OS event loop:** `EventLoopBuilder::<UserEvent>::with_user_event()` then
  `#[cfg(target_os="linux")] builder.with_any_thread(true)` (the old
  `EventLoopExtUnix::new_any_thread()` is gone in tao 0.35; the builder ext is the
  replacement) — Linux runs off the OS main thread (tokio block_on); macOS/Windows
  build plainly on the main thread (required).
- **Per-OS webview build:** `#[cfg(not(linux))] builder.build(&win)` (raw-window-handle);
  `#[cfg(linux)] builder.build_gtk(...)`. Packs into `win.default_vbox()` (the
  `gtk::Box`) when present, falling back to `gtk_window()` — fixes the GTK
  "can only contain one widget" contract violation (a tao window is a single-child
  GtkBin already holding that box).
- Totality preserved: both build paths return `wry::Result<WebView>`; the `Err`
  arm returns `SkyResult::Err`. Zero unwrap/expect/panic.

`checkWebviewLibsRust` (app/Main.hs, Rust-path-only fn — Go path untouched): gated
the pkg-config probe to Linux (`System.Info.os /= "linux" → no-op`; macOS WKWebView
/ Windows WebView2 aren't pkg-config-discovered) and bumped the probed libs to
**webkit2gtk-4.1 + libsoup-3.0** with matching install hints.

Bumped both pins (`crate-specs.toml` + `runtime-rust/Cargo.toml`); the
`crate_specs_sync` drift test passes. Cargo.lock re-pinned (wry/tao tree).

Verified on Linux: `cargo build --features webview` clean; `examples/31-webview-
stopwatch-ui` + `examples/29-webview-threejs-spike` both BUILD + RUN under
`xvfb-run -a timeout 8` (exit 124 = window stayed open, NO panic, GTK
widget-conflict warning GONE post-vbox-fix). Drift test green.

**Affected:** `runtime-rust/src/sky_runtime/webview.rs`,
`src/Sky/Generate/Rust/Builder/crate-specs.toml`,
`src/Sky/Generate/Rust/Builder/Emitter.hs` (comment), `runtime-rust/Cargo.toml`,
`runtime-rust/Cargo.lock`, `app/Main.hs` (`checkWebviewLibsRust` only).

## 2026-06-17 18:00 — CI precision: webview deps + skyshop out-of-scope (the 4 pre-existing reds)

After the limitation fixes, CI's only reds were 4 PRE-EXISTING examples (not
regressions): 29/31-webview, 38-composite-ui-multibackend, skyshop-rs. Diagnosed
+ addressed both classes (user-approved):

- **Webview (29/31/38)** — NOT a codegen bug: `31-webview` builds clean LOCALLY
  (jammy/22.04 base, has webkit2gtk-4.0). The codegen pins wry 0.24 / tao 0.16
  which link **webkit2gtk-4.0** — present on 22.04, REMOVED on 24.04
  (`ubuntu-latest`). Fix: pin the Linux runner to **ubuntu-22.04** + install
  `libwebkit2gtk-4.0-dev libgtk-3-dev librsvg2-dev libsoup2.4-dev
  libjavascriptcoregtk-4.0-dev` (alongside xvfb). ubuntu conditions made
  version-agnostic (`startsWith(matrix.os,'ubuntu')`). No codegen/wry bump.
- **skyshop-rs** — its generated Rust FFI bindings are NOT committed
  (`.skycache/ffi/rust` gitignored), so a CI build would need `cargo +nightly
  rustdoc` over firestore/async-stripe WITH network — long/flaky, unfit for the
  per-commit gate. Marked **out-of-scope** in `lib/examples.sh is_out_of_scope`
  (explicit `*/skyshop-rs` guard, documented); verified locally via its verify.sh.

  NB: NO nightly toolchain on CI. The in-scope examples are the Sky author's
  upstream set (shared Sky code + Go-FFI ones that `is_out_of_scope` filters);
  none run `sky add`, so the FFI inspector's `cargo +nightly rustdoc` is never
  invoked. The only real FFI example (skyshop-rs) is out-of-scope, so nightly
  serves nothing (and inventing trivial FFI fixtures to justify it is pointless).

- **Affected:** `.github/workflows/examples-sweep.yml`, `runtime-rust/scripts/lib/examples.sh`.

## 2026-06-17 17:30 — errorToString regression follow-up: total field rendering (autoref)

CI run `27711298427` (the fix-sweep) surfaced `28-streaming-chat` as a NEW red on
all 3 OSes (the other 4 reds — 29/31-webview, 38-composite-ui, skyshop-rs — are
pre-existing). Root cause = the SkyStringify fix's regression class, broader than
the ui/html types: the generated `sky_show` recursed `field.sky_show()` into a
runtime type with no impl (`http_stream::ChunkEvent<E>` → E0599). Whack-a-mole.

Robust fix: make field rendering TOTAL BY CONSTRUCTION via dtolnay autoref-
specialization (`stringify.rs` `Wrap`/`ViaSkyStringify`/`ViaDebug`): a field
renders via `SkyStringify` if its type impls it, ELSE via `Debug` (every type
derives Debug → can never E0599). Codegen emits `(&Wrap(&field)).dispatch()` inline
+ adds `+ Debug` to the generated impl gens. The top-level
`basics_error_to_string<T: SkyStringify>` bound + ModuleEmitter propagation STAY
(a generic frame erases the autoref to Debug, which would re-quote String —
verified). The ui/element.rs + html.rs per-type impls stay (nicer than Debug).
Validated: 28-streaming-chat + 26-ui-showcase build; 00-standard-libs 131/131;
fixture 60 Go-identical; 34 stringify/basics unit tests. CLAUDE.md learning on the
recursing-trait pitfall already updated.

- **Affected:** `runtime-rust/src/sky_runtime/stringify.rs`, `src/Sky/Generate/Rust/Builder/Emitter.hs`.

## 2026-06-17 16:00 — Known-limitations triage + fix sweep (8 in-boundary fixes + 1 regression)

Triaged the README "Known limitations" list (4-investigator read-only swarm),
ranked most-feasible → least, then fixed every in-boundary REAL item top-down.
Each fix: pre-fix-failing fixture + independent pre-final gate + per-fixture
validation (NO local sweep — CI verifies). Commits (newest last):

- **List.sort/sortBy/sortWith** (`21a15560`) — were kernel-anchored HM sigs with
  no Rust kernel → `List.sortBy` type-checked then E0425. Added 3 runtime kernels
  (stable, total NaN→Equal) + Kernel.hs routes + element-typed comparator closure.
- **`any` record field** (`8599d376`) — a bare-wildcard `any` field emitted an
  undefined Rust `any` (E0412 cascade). Now fails LOUD at codegen
  (`error[Rust]: any-typed record field …`); declared-param `any` still generic.
  (README's promised diagnostic never existed.)
- **Ffi.callTask static** (`592d3b74`) — static-shape call hit a panic polyfill;
  added the peephole arm (resolves to the Task kernel) + honest dynamic-path msg.
- **Result Ok→i64** (`b8a2e574`) — unannotated `Ok v -> Ok v` defaulted the
  payload to i64 (E0308); recover E/A from a concrete enclosing return / callee
  param slot, strictly gated (Task excluded, call-arg vs body separated).
- **withTransaction isolation** (`4fb186b9`) — BEGIN/body/COMMIT ran on different
  pool connections → rollback silently failed on a multi-conn pool. Acquire one
  dedicated connection, route every body DB op through a tokio::task_local!.
- **errorToString String-quoting** (`a6712e6b`) — Debug quoted strings (`"hi"` vs
  Go's `hi`). New total `SkyStringify` trait (String unquoted, Go-%v scalars/Vec/
  map), narrowly-propagated bound, per-type codegen impls. `+regression fix`
  (`0abe2e60`): co-located SkyStringify impls for Std.Ui/Html runtime types
  (Color/Element/Attribute/Html/… — the generated sky_show recurses into fields;
  was E0599 on every Std.Ui project incl. 26-ui-showcase).
- **Task.retryWith** (`283cae5d`) — see the 15:00 entry (real retry loop).
- **non-Clone capture** (`15e6258f`) — a single-use bound SkyTask captured into a
  closure is now MOVED (not cloned → E0599); additive (Clone captures byte-
  identical); conservative provable-SkyTask predicate.
- **string_drop_right** (`d9ef16ed`) — total iterator form, clears the deny-level
  clippy slicing-may-panic (was a bounds-guaranteed false positive).

NO-FIX items (README to relabel via update-docs): Dict.union (STALE — already
implemented), Bytes non-ASCII (BY-DESIGN — Latin-1 lossless; real fix needs
out-of-boundary Bytes=Vec<u8>), un-nameable FFI drops (BY-DESIGN soundness
filter), rustdoc-nightly (EXTERNAL — rustdoc-JSON unstable upstream), WASM
(REQUIRES-REWRITE — Send-everywhere task model), Ffi.callTask dynamic tail
(BY-DESIGN no-reflection). Residuals: errorToString ADT %v (Go's flattened-struct
layout unreproducible by a Rust enum); retryWith bound-value task (one-shot —
inline-expression form retries).

- **Affected:** `runtime-rust/src/sky_runtime/{list,basics,stringify,task,db,string,ui/element,html}.rs`,
  `runtime-rust/src/sky_runtime/mod.rs`, `src/Sky/Generate/Rust/Project.hs`,
  `src/Sky/Generate/Rust/Builder/{Kernel,ExprEmitter,ModuleEmitter,Types,Emitter}.hs`,
  `runtime-rust/tests/sky/{56,57,58,59,60,61,62}-*`.

## 2026-06-17 15:00 — Task.retryWith: real retry loop (was run-once)

**Bug.** `task_retry_with` (runtime) was the identity function (dropped the
policy, ran the task once) and the codegen peephole DROPPED the policy arg. A
transient task that fails-then-succeeds wrongly returned the first `Err` — the
headline flaky-upstream-API use case was broken.

**Fix (codegen reshape + runtime rewrite — the SqlField/Money "destructure a
generated ADT in codegen" pattern).**
- **Runtime** `task.rs`: `task_retry_with` is now a real loop, faithful to
  `runtime-go/rt/task_retry.go`. New signature takes PRIMITIVE policy fields
  (`max_attempts`/`base_ms`/`jitter`/`kind`) + a `should_retry: Fn(&E)->bool` +
  a re-runnable `make_task: Fn()->SkyTask`. Loop: 1..=max_attempts, Ok→return,
  Err→(last attempt OR !should_retry)→return Err, else sleep
  `retry_compute_delay` (ported Go's computeDelay: linear/exponential ×2,
  30 s cap, jitter ∈[0.5,1.5) via the runtime's total `lcg_next` LCG, all
  saturating/total) and loop. Bounds are `Send`-only (SkyTask is Send, not
  Sync). 11 `#[cfg(test)]` unit tests (delay math + loop semantics).
- **Codegen** `ExprEmitter.hs` retryWith peephole: bind the policy to a temp,
  read its struct fields directly, lower its `shouldRetry` enum into a boxed
  `Arc<dyn Fn(&SkyError)->bool>` predicate (`RetryAlways`→`|_|true`,
  `RetryWhen f`→`move|e|f(e.clone())`), and wrap the task EXPRESSION in
  `move || <expr>` so each attempt rebuilds the future. `Kernel.hs`: added
  `("Sky.Core.Task","retryWith")` mapping + refreshed the stale "run-once"
  comments.

**Residual (scoped, documented).** A task passed as a bare LOCAL VARIABLE bound
to a built `SkyTask` value (`let work = … in retryWith p work`) is a one-shot
`Pin<Box<dyn Future>>` — not Clone/reproducible (issue #8). That shape forces
`max_attempts=1` (run-once, returns the real Ok/Err verbatim — no sentinel
observed) via a single-shot `Mutex<Option<SkyTask>>` `Fn`+`Send` shim. The
retry-enabled path is the INLINE EXPRESSION form (the headline use case). So a
bound-value task ignores the policy's attempt count; an inline-expression task
genuinely retries.

**Evidence.** New fixture `runtime-rust/tests/sky/61-retry-transient/` (file-
backed cross-attempt counter): pre-fix it returned Err on attempt 1 / ran the
task once (counter=1); post-fix the transient task succeeds on attempt 3, the
always-fail case runs exactly maxAttempts(4), the RetryWhen-False case stops at
1. Existing `25-retry` (bound-value) still green; spot-checks `14-task-demo`
(run) + `07-todo-cli` (build) green. Pre-existing unrelated clippy error at
`string.rs:145` (slicing-may-panic) noted, NOT touched.

**Affected.** `runtime-rust/src/sky_runtime/task.rs`,
`src/Sky/Generate/Rust/Builder/ExprEmitter.hs`,
`src/Sky/Generate/Rust/Builder/Kernel.hs`,
`runtime-rust/tests/sky/61-retry-transient/{sky.toml,src/Main.sky}`.

## 2026-06-17 14:30 — CI: per-OS BUILD·RUN·EQUIV table in the job summary

Added a `Job summary (sweep table)` step (`if: always()`) to the examples-sweep
job: it finds the newest `~/.cache/sky/examples-sweep/sweep-*.table`, prepends the
OS name + the `VERDICT:` line parsed from `run-*.log`, and appends it — fenced to
preserve the fixed-width alignment — to `$GITHUB_STEP_SUMMARY`. Because each matrix
job writes its own summary, the run page shows ONE table per OS (ubuntu/macos/
windows). This is the no-write-perms README mirror the user chose (option 2): the
sweep results are visible inline on every run with no commit and no `contents:
write`. README stays single-writer via `update-docs`. Verified the shell logic
locally against a real `.table` (renders heading + verdict + fenced table).

- **Affected:** `.github/workflows/examples-sweep.yml`.

---

## 2026-06-17 14:00 — CI: drop sccache (retired GHA cache API kills every build)

Second cross-OS run (`27700228755`, all 3 OSes) failed at the new "Pre-warm Rust
deps" step — but the real cause is the sweep-wide sccache wrapper, not pre-warm:

```
sccache: error: Server startup failed: cache storage failed to read:
  Unexpected (permanent) at read => Our services aren't available right now
  uri: …artifactcache.actions.githubusercontent.com/…/_apis/artifactcache/cache?…&version=sccache-v0.15.0
  response: status: 400 … service: ghac
```

sccache's `SCCACHE_GHA_ENABLED` backend uses GitHub's **v1 Actions-Cache API**,
which GitHub retired; sccache 0.15.0 still talks v1, so no action bump fixes it.
Because sccache was `RUSTC_WRAPPER`, it failed on the first `rustc -vV` — i.e. it
would have killed EVERY cargo build on all three OSes, not just pre-warm.

Fix: turn sccache OFF on CI, keep it the LOCAL dev fast path. Cross-run warmth on
CI comes from `actions/cache@v4` (v2 cache service, already caching
`CARGO_TARGET_DIR` + `~/.cargo/registry`).

- `lib/env.sh`: couple `CARGO_INCREMENTAL=0` to the sccache branch (it exists ONLY
  because sccache needs it) and add a `SKY_NO_SCCACHE` opt-out. When sccache is off,
  `CARGO_INCREMENTAL` is left at cargo's default so a persisted target dir does
  incremental rebuilds. Verified: local → `sccache` + `CARGO_INCREMENTAL=0`
  (unchanged); `SKY_NO_SCCACHE=1` → both unset.
- `examples-sweep.yml` (both jobs): drop `RUSTC_WRAPPER`/`SCCACHE_GHA_ENABLED`/
  `CARGO_INCREMENTAL` job env + the `mozilla-actions/sccache-action` step; set
  `SKY_NO_SCCACHE: '1'`; drop the `sccache --show-stats` line from pre-warm.

- **Affected:** `.github/workflows/examples-sweep.yml`, `runtime-rust/scripts/lib/env.sh`.

---

## 2026-06-17 13:00 — CI: fix the three env failures from the first cross-OS run

First `examples-sweep.yml` run (all 3 OSes) failed on CI-environment issues, NOT
Rust bugs — diagnosed per OS and fixed at the right layer:

- **macOS + Windows aborted at the `command -v go` / `curl` preflight.** Root cause:
  `lib/env.sh` *clobbered* `PATH` (no trailing `$PATH`), dropping GitHub's
  `setup-go` / `setup-node` and Windows Git-Bash tool dirs. Fix: append `:$PATH` so
  the runner-provided `go`/`node`/`curl` stay reachable. The trailing `$PATH` is now
  documented as LOAD-BEARING on CI.
- **Ubuntu reported 0 green · 42 red.** Two compounding causes: (1) `rg` is not
  preinstalled, so `is_out_of_scope` silently returned "in scope" for all → Go-FFI
  examples (02/03/05/08/11/13…) leaked into `build_set` and each fails `--target
  rust`; (2) a cold sccache made the first example cold-compile the whole Rust dep
  tree and blow past the 180 s ceiling → every build sky-failed. Fixes: a loud `rg`
  preflight in `examples-sweep.sh` (exit 2 if missing) + an "Install ripgrep" step
  per-OS in the workflow; `SKY_SWEEP_BUILD_TIMEOUT` / `_FFI` made configurable
  (raised to 900 / 2400 on CI) plus a "Pre-warm Rust deps" workflow step
  (`cargo build --features full` under the same shared `CARGO_TARGET_DIR` + sccache)
  so each example hits the cache instead of cold-building.

Active goal: make CI work fully and precisely (it will be the guide for future
development). Expect 1–2 more push→run cycles to flush hidden per-OS issues
(BSD `script`, Windows no-pty/no-chromium, macOS Playwright).

- **Affected:** `.github/workflows/examples-sweep.yml`, `runtime-rust/scripts/examples-sweep.sh`, `runtime-rust/scripts/lib/env.sh`.

---

## 2026-06-17 12:00 — README examples table: per-row build/run + 4 perf columns; CLI usage after Goal

Made the examples table complete + self-describing under Project status: per-row
**Build**/**Run** ✅ columns (checked each of the 37 sweep rows — all green, replacing
the blanket "all ✅") and four Rust/Go perf-ratio columns — **Thru ↑** (throughput) ·
**RSS ↓** · **Cold ↓** (cold-start) · **Bin ↓** (binary size) — from the perf TSV.
Moved `## CLI usage` to immediately after `## Goal`. Encoded this canonical table
format + section order into the `update-docs` skill so regenerations preserve it.

- **Affected:** `README.md`, `update-docs/SKILL.md`.

## 2026-06-17 11:45 — Source-of-truth policy: README only via update-docs; add PROGRESS.md

Established the policy that fixes the multiple-sources-of-truth drift: `README.md`
is refreshed ONLY through `sky-rust-backend:update-docs` (it reads this file +
`git log` + current source); advancing work logs here instead of editing the
README inline. Generalizable learnings/pitfalls still go to `CLAUDE.md`.

- **Affected:** new `runtime-rust/PROGRESS.md`; `CLAUDE.md` Settled rules (the
  policy) + root-`.md` allowlist now includes `PROGRESS.md`; `update-docs` SKILL.md
  (inputs = PROGRESS.md + git + source; README-only-via-this-skill enforcement).

## 2026-06-17 11:39 — README rewritten pristine; learnings → CLAUDE

Rewrote `README.md` as a current-state-only snapshot: full examples table
(build·run·equiv·round-trip·notes) under Project status, glossary moved to the end,
all history/dates/phases/tiers removed. Moved disk-hygiene + multibackend-entry
pitfalls + "run the full sweep" learning into `CLAUDE.md`.

- **Affected:** `README.md`, `CLAUDE.md`. Commit `eadcede7`.

## 2026-06-17 11:26 — T1 Go-codegen guard (00 builds on --backend go)

Gated the literal-lambda / call-arg emission on `all isEmittableGoType paramTys` /
`not (containsGenericTypeParam subbed)` so a callee-bound type var (`T1` from a
`func(T1) bool` retry predicate) is erased to `any` instead of leaking an undefined
identifier into emitted Go. Fork-local fix over the v0.16.29 regression; supersede
when upstream `feat/v0.17-fully-typed-codegen` tags.

- **Affected:** `src/Sky/Build/Compile.hs`. Commit `390909c7` (+ README/memory
  attribution correction `a2022d07`).

## 2026-06-17 11:10 — Deferred-effect model (#8): 00 + simple equiv-stdout, 37/37

Effect kernels (`log/io/file/crypto/random/system/time/trace/config_decode`) now
defer their I/O into the returned Task body (constructing a Task is pure). Codegen
runs a discarded Task-typed `let _ = <task>` via `task_run` across both
`exprToRustInner` and `substVar`'s `goDef` (the inlined-binding path `simple`
reaches), while a non-Task discard stays bind/drop (so `Sky/Test`'s discarded
List-of-Tasks stays silent, matching Go). Entry `block_on`s `sky_main` iff its body
tail is a Task. Regression fixture `54-discard-task-effect`. Full sweep 37 green.

- **Affected:** `runtime-rust/src/sky_runtime/{log,io,file,crypto,random,system,time,trace,config_decode}.rs`;
  `src/Sky/Generate/Rust/Builder/{ExprEmitter,Emitter,ModuleEmitter,Types}.hs`;
  `runtime-rust/tests/sky/54-discard-task-effect`. Commit `1ba0b764`.

## 2026-06-17 04:07 — fn-ptr-comparison lint on fn-variant enums

Enums with a fn-pointer variant (`ShouldRetry`'s `RetryWhen`, `SkyTestTest`'s
`Leaf`) keep `derive(PartialEq)` (holder structs need it) but `#[allow]` the
`unpredictable_function_pointer_comparisons` lint (the fn variant is matched, never
`==`-compared).

- **Affected:** `src/Sky/Generate/Rust/Builder/Emitter.hs`. Commit `fac670bd`.

## 2026-06-17 03:57 — Cross-platform CI + OS-aware checks.sh

New fork-local `.github/workflows/examples-sweep.yml` runs the sweep on
ubuntu/macos/windows (honest per-host scope; gates pushes on Go≡Rust parity).
`checks.sh` made OS-aware (`SKY_HOST_OS`, `EXERCISE_SKIP_RC`, guarded `reap`, BSD
`script`/xvfb branches). Existing `ci.yml` diagnosed not-broken (only a GHC version
staleness; fix proposed, not applied).

- **Affected:** `.github/workflows/examples-sweep.yml`,
  `runtime-rust/scripts/lib/checks.sh`, `runtime-rust/scripts/examples-sweep.sh`,
  skill docs. Commit `fbc19e83`.

## 2026-06-16 21:33 — Unified examples-sweep (build·run·equiv) + server body-equiv

Folded build-sweep + run-sweep + equiv-sweep into one `examples-sweep` (per-example
BUILD·RUN·EQUIV table, single SSOT `lib/checks.sh`). Server body-equiv byte-compares
each comparable GET route on both backends (sequential boot, port-sniff, dev-banner
off, skip Go-404, auth secret, ETXTBSY retry). Night gate + perf rename.

- **Affected:** `runtime-rust/scripts/{examples-sweep.sh,examples-perf-sweep.sh,lib/*,equiv-classification.tsv}`;
  Std.Log Go-format parity (`782397c2`) + E-pinning log wrappers (`3a9037ad`).
  Commits `22290857`, `6e8ef029`, `edd194dd`, `156bee99`, `57128081`, `100bae3a`.

## 2026-06-16 00:15 — Stdlib kernel parity: 44 kernels + Set + DbDec/Db

Implemented 44 Go-parity stdlib kernels (String/Path/Dict/File/Time/Random/Json),
the `Set` subsystem (BTreeSet-backed), and the `Std.Db.Decode` (DbDec) +
generated-ADT Db cluster (insertFields/updateFields/insertFieldsReturning,
DbDec.money via a shared `{run, fields}` Decoder). skydex parity tooling hardened.

- **Affected:** `runtime-rust/src/sky_runtime/*` (many), `src/Sky/Generate/Rust/Builder/*`,
  `tools/skydex/*`. Commits `083e0501`, `81f0166b`, `76989991`, `9e3c7dd9`,
  `b2fe42be`, `d669b11d` and siblings.

---

_Earlier history predating this log lives in `git log feat/runtime-rust`._
