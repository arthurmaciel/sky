# S1 — Rust-vs-Go perf-harness completion — design

**Date:** 2026-06-11
**Branch:** `feat/runtime-rust` (fork `arthurmaciel/sky` only)
**Roadmap slice:** S1 (perf-benchmark harness) — gates every later slice (S2–S8).
**Status:** approved design, ready for an implementation plan.

## Purpose

Close roadmap slice **S1** so the **perf-gate leg** of the per-slice acceptance
triple is callable for *every* app shape (CLI / Http.Server / Sky.Live), with
committed Rust-vs-Go baselines. S1 is the gate every later slice (S2–S8)
inherits; until its server + live envelopes exist and are committed, no slice
can formally pass its third gate.

This is a **finish-the-last-mile** slice, not a from-scratch build: the harness
already exists and works for the CLI shape. The design scopes only the remaining
delta.

## Current state (what already exists)

`scripts/rust-perf.sh` (tracked, ~10 KB) already implements:

- **Shape auto-detect** — `detect_shape`: `Std.Live`/`Live.app` → `live`,
  `Server.listen`/`Sky.Http.Server` → `server`, else `cli`.
- **Per-metric probes** — cold-start (`hyperfine` for CLI; exec→first-200 loop
  for server/live), throughput (`ab`), RSS (`/usr/bin/time -v` for CLI;
  `/proc/<pid>/VmHWM` under load for server/live), binary size (`stat`), and
  Live SSE patch-p95 + event-throughput via the custom `tools/sse-bench` driver
  (tracked source + built binary).
- **Threshold gating** — `gate_metric` compares the Rust/Go ratio against
  `scripts/rust-perf.thresholds`, with a *borderline re-run* (re-measure
  near-threshold metrics once before failing) and higher-is-better handling for
  throughput metrics.
- **`--baseline`** — derives thresholds over a representative triplet
  (`01-hello-world:cli`, `15-http-server:server`, `09-live-counter:live`),
  CV-padding each ratio.
- **Bounded readiness** — `wait_ready` polls `curl` up to `READY_TIMEOUT_S`
  (default 10 s) with a 0.1 s sleep; a server that never answers fails fast
  instead of busy-spinning.

Tooling present on the host: `hyperfine`, `ab` (apachebench), `ss`, `lsof`,
`/usr/bin/time`. `oha`/`wrk` are absent and **not needed** — `ab` is the chosen
load generator.

**The CLI shape is fully working**; its envelope is already measured and present
in `scripts/rust-perf.thresholds`:

```
cli.rss_ratio_max       = 0.14
cli.coldstart_ratio_max = 0.19
cli.binsize_ratio_max   = 0.01
```

## The two gaps

1. **The server shape can't be benchmarked.** `start_server` picks a free port
   and passes it via `SKY_LIVE_PORT`/`PORT`, then `wait_ready` polls that port.
   Sky.Live honors `SKY_LIVE_PORT` (so `live` works), but
   `Sky.Http.Server.listen 8000` ignores the env and binds its hard-coded port —
   so the probe polls the wrong port and times out. The `server.*` envelope is
   therefore never captured.
2. **`scripts/rust-perf.thresholds` is CLI-only and untracked.** It has only the
   three `cli.*` rows and is not committed, so there is no `server.*` / `live.*`
   envelope and nothing for a fresh checkout to gate against.

## Design

### Decision: port discovery (harness-only, no runtime change)

The harness learns the server's port by **discovering the actually-bound port**
after spawn, rather than dictating it via env. Chosen over a runtime
`Server.listen` PORT override (which would edit the *shared* runtime/codegen and
risk the Go-byte-identical / never-alter-Go constraint) and over per-example
bench fixtures (extra parallel artifacts that drift from the real examples).
Discovery is **fork-safe** (zero Go/runtime change), **universal** (works
whether or not the app honors an env port), and robust to apps that bind a
fixed port.

### Component: `discover_port` (new, in `scripts/rust-perf.sh`)

Replaces the "trust the env port" assumption in `start_server` /
`probe_coldstart_server`:

- Still pass `SKY_LIVE_PORT="$port" PORT="$port"` on spawn, so apps that *do*
  honor it (Sky.Live) bind a free port and avoid collisions across runs.
- After spawn, resolve the listener from the PID:
  `ss -ltnp 2>/dev/null` filtered to `pid=<pid>` (fallback `lsof -nP -p <pid> -iTCP -sTCP:LISTEN`).
- **Disambiguation:** a process may bind more than one port (a Sky.Live app's
  console sub-app, a metrics endpoint). Collect all listening ports for the PID
  (and its direct children, since the console mounts as a spawned child), then
  pick the one whose `curl -s http://127.0.0.1:<p>/` returns an HTTP response —
  that is the main application listener. If several answer, prefer the env port
  when it is among them, else the lowest.
- Feed the discovered port into `wait_ready`, `ab`, and `sse-bench`.
- **Bounded:** discovery runs inside the existing `READY_TIMEOUT_S` budget; if
  no bound port answers before the deadline, the probe fails fast (exit code 3,
  "a backend can't run it") rather than hanging.

`start_server` returns `"pid discovered_port"` exactly as today, so the
downstream probes (`probe_throughput`, `probe_rss_server`, `probe_live_sse`) are
unchanged.

### Component: baseline capture + commit

Once the server shape resolves, run `scripts/rust-perf.sh --baseline`. It
populates `server.*` and `live.*` rows alongside `cli.*`:

- `server.{coldstart,throughput,rss,binsize}_ratio_*`
- `live.{coldstart,throughput,rss,binsize,patch_p95,event_throughput}_ratio_*`

`_ratio_max` for lower-is-better metrics (coldstart, rss, binsize, patch_p95),
`_ratio_min` for higher-is-better metrics (throughput, event_throughput).

**Threshold policy — descriptive, not prescriptive.** The baseline measures the
*actual* Rust/Go ratio per metric, CV-pads it (the existing `--baseline`
logic), and commits that as the envelope. The gate therefore catches
**regressions from measured parity**, not adherence to a guessed target. This
matches the roadmap's "data-driven from first baselines" intent and the existing
`cli.*` rows.

Then **commit `scripts/rust-perf.thresholds`** (move it from untracked to
tracked) so a fresh checkout — and CI — has the envelope.

### Acceptance-gate integration

`scripts/rust-perf.sh <example>` is the perf leg of the acceptance triple. After
this slice:

- S3's fully-unblocked examples (`19`, `26`) can run all three legs (sweep
  `builds` ✅, `rust-equiv.sh` / `ui-parity.sh` equivalence ✅, `rust-perf.sh`
  within envelope — to be run).
- S1's row in the roadmap tracking table
  (`…/plans/2026-06-09-rust-go-parity-roadmap-tracking.md`) flips to **DONE**,
  and the README notes the perf gate is callable for all three shapes.

## Out of scope

- Any change to `Server.listen` or the shared runtime/codegen (the never-alter-Go
  / shared-seam constraint).
- Installing `oha`/`wrk` (`ab` is the load generator).
- CI wiring of the perf gate (that is Phase-2 / FP work, not S1).
- Re-deriving or tightening the existing `cli.*` envelope.

## Testing

- **Server shape no longer times out:** `rust-perf.sh --shape server 15-http-server`
  produces a full metric table (coldstart, throughput, rss, binsize) for both
  backends and exits 0.
- **Port discovery is correct:** a unit-style check asserts the discovered port
  equals the server's actual `ss` listener for a known example (a Live app whose
  console sub-app binds a second port must still resolve to the main listener).
- **Live shape unchanged:** `rust-perf.sh --shape live 09-live-counter` still
  produces patch-p95 + event-throughput via `sse-bench`.
- **Baseline + gate round-trip:** after `--baseline`, a fresh `rust-perf.sh`
  run on the triplet passes against the committed thresholds (exit 0); an
  artificially inflated metric trips the gate (exit 1).
- All server/live probes stay inside `READY_TIMEOUT_S`; no busy-spin, no orphan
  server process (every probe `kill -9`s its spawned PID).

## Done-criteria

- `scripts/rust-perf.sh` benchmarks all three shapes (cli/server/live) with
  port discovery; the server shape no longer times out.
- `scripts/rust-perf.thresholds` is committed with `cli.*`, `server.*`, and
  `live.*` rows.
- The roadmap tracking table marks S1 DONE; the README states the perf gate is
  callable for every shape.
