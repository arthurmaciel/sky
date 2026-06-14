---
name: perf-sweep
description: Run the Sky Rust-backend PERF sweep — Rust-vs-Go cold-start / RSS / binary-size / throughput over the perf-runnable example set, plus a regression report vs the previous perf run. Use when the user asks to run the perf sweep, check for perf regressions/improvements vs the last run, or measure Rust-vs-Go performance after runtime/codegen changes. Siblings: sky-rust-backend:build-sweep (compiles), sky-rust-backend:run-sweep (runtime), sky-rust-backend:web-sweep (browser). Trigger: /sky-rust-backend:perf-sweep.
---

# perf-sweep

The **perf** phase of Rust-backend verification. One **deterministic** script
runs the Rust-vs-Go perf harness over the perf-runnable set and reports
improvement/regression vs the previous run. The env gotchas are baked in — **do
NOT re-decide the steps**. The only judgement call is afterward: did this run
reveal a way to improve the script? If yes, edit
`runtime-rust/scripts/perf-sweep.sh`.

## Workflow (every invocation)

1. **Remind the user to close other apps FIRST.** Perf metrics (RSS, cold-start,
   throughput) are machine-load-sensitive — a background browser skews them and
   produces false regressions. Say:
   > "Before I run the perf sweep: please close all other applications —
   > **especially any browsers** — so the measurements aren't skewed. Tell me
   > when ready."
   **Wait for the user's go-ahead.** Do not run until they confirm.

2. **Run the script** (~1 h; background + wait):
   ```bash
   bash runtime-rust/scripts/perf-sweep.sh
   ```
   Self-resolves repo + env, pre-flight-reaps stray `hyperfine`/`ab`/`sse-bench`/
   `sky-app`, runs the harness per example, persists numbers to
   `~/.cache/sky/rust-perf-sweep/`, prints a report.

3. **Relay the report** — quote the per-metric PASS/FAIL against the committed
   thresholds, the `--- IMPROVEMENTS --- / --- REGRESSIONS ---` section, and the
   `PERF SUMMARY:` line (vs the previous run).

4. **Improve the script if warranted** (new gotcha / parse miss / flake /
   missing shape).

## What it does

- `SKY_CONSOLE_EMBED=off scripts/rust-perf.sh` over the both-backend
  perf-runnable set (~24 cli/server/live). Excluded: tui/webview/fyne
  (need TTY/window), console/multi-tier 25/34, Go-FFI-02. `rust-perf.sh`
  self-skips (exit 3) anything a backend can't build; each call is
  `timeout`-bounded + orphan-reaped.
- **Core-feature metrics (not just `GET /`).** `ab GET /` measures the cold
  landing page, NOT the example's core feature (ex27 proved this — GET / was
  LobbyPage, never the broadcast). The live shape now also reports `live_warm`
  (warm render: GET / WITH a session cookie — realistic steady state, not
  cookie-less session bootstrap) and `live_event` (event round-trip: POST
  `/_sky/event` with a real state-changing handler parsed from the page —
  decode → resolve-by-sky-id → update → VDOM diff → patch). `throughput` (cold
  GET /) is kept as a SECONDARY signal. SSE/WS/broadcast drivers extend this for
  the streaming/websocket/pub-sub shapes. New core metrics are informational
  until `--baseline` commits their threshold envelopes.
- **Regression report** — diffs this run's per-(example, metric) Rust values vs
  the previous `~/.cache/sky/rust-perf-sweep/perf-*.tsv`: lower-is-better for
  rss/coldstart/binsize, higher for throughput. Flags verdict-flip-to-FAIL or
  >10% regressions; calls out >5% improvements.

## Baked-in gotchas / knobs

- PATH `/usr/local/go/bin` — **`go` is required** (the harness builds Go too);
  `$HOME/.cargo/bin` + `sccache`; `SKY_BIN=<repo>/sky-out/sky`;
  `CARGO_TARGET_DIR=$HOME/.cache/sky-rust-target`; `SKY_CONSOLE_EMBED=off`.
- `RUST_PERF_QUICK=1` → 3-shape representative; `RUST_PERF="a b c"` override.
- First run records the baseline; the regression report appears from the 2nd run.
- If `scripts/rust-perf.thresholds` are stale after legitimate runtime growth,
  surface a deliberate `scripts/rust-perf.sh --baseline` refresh — don't
  auto-refresh.
