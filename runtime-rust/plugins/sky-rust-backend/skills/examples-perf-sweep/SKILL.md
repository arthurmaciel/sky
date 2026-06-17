---
name: examples-perf-sweep
description: Run the Sky Rust-backend EXAMPLES-PERF sweep — Rust-vs-Go cold-start / RSS / binary-size / throughput over the perf-runnable example set, plus a regression report vs the previous perf run. Use when the user asks to run the perf sweep, check for perf regressions/improvements vs the last run, or measure Rust-vs-Go performance after runtime/codegen changes. Sibling: sky-rust-backend:examples-sweep (build + run + Go≡Rust equivalence). Night-gated 22:00–08:00 America/Sao_Paulo. Trigger: /sky-rust-backend:examples-perf-sweep.
---

# examples-perf-sweep

The **perf** phase of Rust-backend verification (build + run + equiv are the
sibling `examples-sweep` skill). One **deterministic** script —
`runtime-rust/scripts/examples-perf-sweep.sh` — runs the Rust-vs-Go perf harness
over the perf-runnable set and reports improvement/regression vs the previous
run. The env gotchas are baked in — **do NOT re-decide the steps**. The only
judgement call is afterward: did this run reveal a way to improve the script? If
yes, edit `runtime-rust/scripts/examples-perf-sweep.sh`.

## Principles

Strict order from `README.md` (top): **security > correctness > soundness >
efficiency > completeness > readability**. Perf serves **efficiency** — never at
the cost of a higher principle. A perf "win" that broke correctness or soundness
is not a win.

## Night gate

This heavy sweep is gated to **22:00–08:00 America/Sao_Paulo** (slim shared box),
same as `examples-sweep`. Outside the window AND `SKY_SWEEP_FORCE` unset → prints
`deferred: examples-perf-sweep runs 22:00–08:00 …` and exits 2. Inside the window
OR `SKY_SWEEP_FORCE=1` → proceeds. (`night_guard` lives in `lib/checks.sh`.)

## Workflow (every invocation)

1. **Remind the user to close other apps FIRST.** Perf metrics (RSS, cold-start,
   throughput) are machine-load-sensitive — a background browser skews them and
   produces false regressions. Say:
   > "Before I run the perf sweep: please close all other applications —
   > **especially any browsers** — so the measurements aren't skewed. Tell me
   > when ready."
   **Wait for the user's go-ahead.** Do not run until they confirm.

2. **Run the script** (~1 h; background + wait). It's night-gated — during the
   day use `SKY_SWEEP_FORCE=1`:
   ```bash
   SKY_SWEEP_FORCE=1 bash runtime-rust/scripts/examples-perf-sweep.sh
   ```
   Self-resolves repo + env, pre-flight-reaps stray `hyperfine`/`ab`/`sse-bench`/
   `sky-app`, runs the harness per example, persists numbers to
   `~/.cache/sky/examples-perf-sweep/`, prints a report.

3. **Relay the report** — quote the per-metric PASS/FAIL against the committed
   thresholds, the `--- IMPROVEMENTS --- / --- REGRESSIONS ---` section, and the
   `PERF SUMMARY:` line (vs the previous run).

4. **Improve the script if warranted** (new gotcha / parse miss / flake /
   missing shape).

## What it does

- `SKY_CONSOLE_EMBED=off runtime-rust/scripts/rust-perf.sh` over the both-backend
  perf-runnable set (`perf_set` from `lib/examples.sh` = build_set; cli/server/
  live). tui/webview/fyne get build + cold-start only (no throughput metric;
  hyperfine would hang on an input/window-waiting binary). `rust-perf.sh`
  self-skips (exit 3) anything a backend can't build; each call is
  `timeout`-bounded + orphan-reaped.
- **Core-feature metrics (not just `GET /`).** `ab GET /` measures the cold
  landing page, NOT the example's core feature (ex27 proved this — GET / was
  LobbyPage, never the broadcast). Per-shape core drivers run:
  - **live** → `live_warm` (warm render: GET / WITH a session cookie) +
    `live_event` (POST `/_sky/event` with a real state-changing handler) +
    `broadcast` (pub/sub apps: N subscribers + publisher, count fan-out frames).
  - **server** → `sse_eps` (text/event-stream apps) + `ws_eps` (WebSocket apps).
  `throughput` (cold GET /) is kept as a SECONDARY signal. Port discovery trusts
  the app's own `listening on :PORT` log.
- **Regression report** — diffs this run's per-(example, metric) Rust values vs
  the previous `~/.cache/sky/examples-perf-sweep/perf-*.tsv`: lower-is-better for
  rss/coldstart/binsize, higher for throughput. Flags verdict-flip-to-FAIL or
  >10% regressions; calls out >5% improvements.

## Baked-in gotchas / knobs

- PATH `/usr/local/go/bin` — **`go` is required** (the harness builds Go too);
  `$HOME/.cargo/bin` + `sccache`; `SKY_BIN=<repo>/sky-out/sky`;
  `CARGO_TARGET_DIR=$HOME/.cache/sky-rust-target`; `SKY_CONSOLE_EMBED=off`.
- **Night-gated** (22:00–08:00 BRT; `SKY_SWEEP_FORCE=1` overrides).
- `RUST_PERF_QUICK=1` → 3-shape representative; `RUST_PERF="a b c"` override.
- First run records the baseline; the regression report appears from the 2nd run.
- If `runtime-rust/scripts/rust-perf.thresholds` are stale after legitimate
  runtime growth, surface a deliberate `runtime-rust/scripts/rust-perf.sh
  --baseline` refresh — don't auto-refresh.
- `rust-perf.sh` is this skill's helper (unchanged by the rename).

## Capture learnings (self-improving loop)

After this skill's work completes, record any **significant, verified,
generalizable** learning to the **`## Agent learnings`** section of
`runtime-rust/CLAUDE.md`. Obey that section's rules: **only if secure, correct,
and sound + verified**; **reconcile (update / dedupe / prune), never
blind-append**; **skip when nothing significant** — most runs add nothing.
