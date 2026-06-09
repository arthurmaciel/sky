# S1 — Rust-vs-Go performance-benchmark harness — design

**Date:** 2026-06-09
**Branch:** `feat/runtime-rust` (fork `arthurmaciel/sky` only)
**Roadmap slice:** S1 (gates every later capability slice S2–S8)
**Status:** approved design, ready for an implementation plan

## Purpose

Build the performance-benchmark harness that proves the Sky **Rust backend is
co-equal to the Go backend in measured performance**, and that gates every later
capability slice. Given an example, it release-builds it on both backends,
measures the metrics for its app shape, and pass/fails the Rust numbers against a
Go-relative, variance-padded envelope.

Parent roadmap:
`runtime-rust/docs/superpowers/specs/2026-06-09-rust-go-parity-roadmap-design.md`.

## Decisions locked in brainstorming

- **Hard, noise-robust gate.** Perf is a real pass/fail (a slice isn't DONE until
  its example is within envelope), made robust with warmup + median-of-N +
  variance-sized envelopes + a borderline re-run.
- **Deep Live.** The Sky.Live shape is benchmarked to its real signal — the
  `POST /_sky/event` → SSE-patch round-trip latency + sustained event throughput
  — via a custom client, not just cold-start/RSS.
- **Approach B — bash orchestrator + a focused Rust SSE-bench client.** Reuse
  battle-tested tools (`hyperfine`, `ab`) where they exist; build only the
  missing piece (SSE round-trip under load).

## Environment (probed 2026-06-09)

- Present: `ab` (ApacheBench), `/usr/bin/time`. `cargo` available.
- **Absent: `hyperfine`, `oha`, `wrk`, `vegeta`, `perf`, `valgrind`.** The
  harness installs `hyperfine` via `cargo install hyperfine` (cheap; the repo is
  already Rust-tooled) for CLI cold-start; everything else uses present tools or
  the bundled `sse-bench`.

## Units

1. **`scripts/rust-perf.sh` — orchestrator.** `rust-perf.sh <example>
   [--shape auto|cli|server|live]`. Release-builds the example on `--target go`
   and `--target rust`, detects the shape, runs the per-shape probes against both
   binaries, loads thresholds, computes pass/fail, prints the Rust-vs-Go table,
   writes the JSON artifact, exits non-zero on a gate failure. `--baseline`
   (re)generates the thresholds file.
2. **`tools/sse-bench/` — standalone Rust cargo bin** (kept off the runtime
   crate's feature graph). `sse-bench --url <base> --events N --concurrency C` →
   JSON `{patch_p50, patch_p95, patch_p99, events_per_sec}`. Opens `/_sky/sse`,
   fires `POST /_sky/event`, correlates each event to its returned patch frame
   for round-trip latency.
3. **`scripts/rust-perf.thresholds` — envelope file.** Plain `shape.metric =
   value` lines (e.g. `cli.cold_start_ratio_max = 1.2`,
   `server.throughput_ratio_min = 0.8`, `live.patch_p95_ratio_max = 1.5`).
   Generated from the baseline pass, committed, read by the gate.
4. **Per-shape probe functions** (inside the orchestrator): cold-start
   (hyperfine for CLI; spawn→ready timer for server/live), throughput (`ab`),
   RSS (`/usr/bin/time -v` → `/proc/<pid>/status` `VmHWM` fallback), binary size
   (`stat -c%s`), Live round-trip (`sse-bench`).

## Data flow

```
example
  → build(go, release) + build(rust, release)
  → shape detect (Std.Live→live | Server.listen→server | else cli; --shape overrides)
  → probes(go) + probes(rust)
  → metric pair → ratio vs thresholds (directional)
  → { human table, JSON artifact, exit code }
```

## Metrics per shape

| Shape | Metrics | Measurement |
|---|---|---|
| CLI | cold-start, peak RSS, binary size | hyperfine `--warmup 3 --runs 20` (run→exit) median; `/usr/bin/time -v` Max RSS; `stat` |
| Http.Server | cold-start, throughput, peak RSS, binary size | spawn→ready timer; `ab`; `/proc` RSS under load; `stat` |
| Sky.Live | cold-start, initial-render throughput, patch-latency p50/p95/p99, event-throughput, peak RSS, binary size | spawn→ready timer; `ab` on `GET /`; `sse-bench`; `/proc` RSS under sse-bench load; `stat` |

**Cold-start differs by shape.** CLI binaries run to exit → hyperfine. Server/Live
binaries never exit → cold-start = time from `exec` to first `200` response: a
spawn→poll-`GET /`-every-5ms-until-200 timer, kill, repeat 20×, median.

**Load constants (fixed, documented):** `ab -n 10000 -c 50`;
`sse-bench --events 2000 --concurrency 16`; a free ephemeral port per run;
identical requests to both backends.

## Fairness rules (load-bearing)

- **Both binaries are release/optimized builds** (`cargo build --release` for
  Rust; Go default). Never benchmark debug-Rust.
- Same machine, back-to-back; warmup iterations discarded.
- Server/Live: server must signal **ready** (poll until 200) before load starts;
  cleanly torn down after — **no orphan servers**.
- Identical inputs/requests to both backends.

## Noise-robustness + threshold engine

**Robustness:** warmup discarded; **median** (not mean) across N; Live uses
`sse-bench` percentiles; **borderline re-run** (a result within ±5% of its
threshold is re-run once, better-of-two taken); an **advisory** environment guard
warns on high load-average / battery.

**Threshold derivation (S1 baseline pass):** run the harness M=5× on the
representative example per shape — CLI `01-hello-world`, Server `15-http-server`,
Live `09-live-counter` — on both backends. For each `shape.metric`: compute the
Rust/Go ratio and its coefficient of variation (CV); set the envelope = observed
ratio padded by the noise margin (`threshold_max = observed_ratio × (1 + 2·CV)`,
rounded). Commit the file.

**Gate semantics (directional, per metric):**
- *Lower-is-better* (cold-start, RSS, binary size, patch-latency): pass iff
  `rust/go ≤ threshold_max`.
- *Higher-is-better* (throughput, event-throughput): pass iff
  `rust/go ≥ threshold_min`.
- A slice's example passes iff **every** metric for its shape passes (after the
  borderline re-run); the orchestrator exits non-zero on any fail.

**Regeneration policy:** a slice that legitimately improves perf regenerates
(tightens) the thresholds in the same commit; a regression past envelope fails
the gate → fix it, or loosen only with a recorded justification in the commit
message. **Never loosen silently.**

## Output contract

- **Human table** — per shape × metric: `Go | Rust | ratio | threshold | PASS/FAIL`.
- **Machine artifact** — `/tmp/rust-perf-<example>.json`.
- **Exit code** — `0` all-pass; non-zero gate-fail (failing metrics named).
- **`--baseline`** regenerates `scripts/rust-perf.thresholds`.

## Gate invocation by later slices

A capability slice runs `scripts/rust-perf.sh <example>` per unblocked example;
**exit 0 required** — exactly the reference already written into the roadmap
tracking plan. No new contract for later slices to learn.

## Testing the harness itself

- **`sse-bench`** — unit tests for the event→patch correlation/latency math;
  one integration test against a known-good Sky.Live binary.
- **Orchestrator** — a self-test on `01-hello-world` (emits a table, exit 0) and
  a **negative test** (a threshold set impossibly tight → assert non-zero exit),
  proving the gate actually gates.

## Done-criteria (S1)

- `scripts/rust-perf.sh` + `tools/sse-bench/` + committed
  `scripts/rust-perf.thresholds` exist.
- The harness runs green on the 3 representative examples (the baseline).
- The Rust-vs-Go table is produced; the JSON artifact is written.
- The exit-code gate is verified by the negative test.

## Out of scope

- CI wiring (P2's dual-backend gate).
- WASM perf.
- Benchmarking examples that don't build yet (each later slice benchmarks its
  own as it lands).

## Constraints (carried)

- Fork-only; tooling lives under the fork. Release-only builds.
- Timeout-bound every load phase; kill every spawned server before exit (CLAUDE.md
  rule 2 — no orphans).
- Docs under `runtime-rust/docs/`; commits carry no co-author line.
