---
name: keep-go-parity
description: One command to ingest the latest upstream and re-prove the Rust backend stays at Go parity. Runs sky-rust-backend:sync-with-upstream (resolving merge conflicts autonomously, asking only on a real design decision), then sky-rust-backend:examples-sweep always (ONE sweep that builds, runs, AND asserts Go≡Rust equivalence per example — BUILD·RUN·EQUIV table), plus sky-rust-backend:examples-perf-sweep when any new example or a Go-backend perf change lands. RED examples are root-caused + fixed in-boundary via the autonomous swarm after the full sweep. Use when the user asks to keep Go parity, sync upstream and re-verify, or after an upstream release. Trigger: /sky-rust-backend:keep-go-parity.
---

# keep-go-parity

Ingest the latest `anzellai/sky` upstream into `feat/runtime-rust` **and** prove
the Rust backend still matches Go — in one orchestrated pass. It chains the
sibling skills; a deterministic planner (`keep-go-parity.sh`) decides which
sweeps the merge actually warrants so nothing runs needlessly and nothing
needed is skipped.

## Principles

Strict order from `README.md` (top): **security > correctness > soundness >
efficiency > completeness > readability** (a lower never overrides a higher).
Parity work serves correctness/soundness above all; the swarm-fix step below
adheres to them.

## Workflow (execute in order)

1. **Snapshot BEFORE the sync** (records `examples/` + HEAD sha):
   ```bash
   bash runtime-rust/scripts/keep-go-parity.sh snapshot
   ```

2. **Sync upstream** — invoke **sky-rust-backend:sync-with-upstream**.
   - Resolve the two expected thin-seam conflicts (`sky-compiler.cabal`,
     `src/Sky/Build/Compile.hs`) **autonomously** per that skill's runbook, plus
     any mechanical Rust-side shared-type adaptation the build pinpoints.
   - **Ask the user only when a real design decision emerges** — an unexpected
     conflict surface (e.g. `FfiGen.hs`/`Toml.hs`), an upstream shared-type
     reshape with more than one defensible Rust adaptation, or anything that
     would change Go behaviour. Otherwise proceed without stopping.
   - The sync's **pre-final code gate** (Step 7b — security/correctness/
     soundness, `## Pre-final code gate` in `runtime-rust/CLAUDE.md`) MUST pass
     before its merge commit; a resolution that violates one of the three is
     reverted + logged in `runtime-rust/README.md` + signalled, not committed.
   - Do not push. The merge commit is the durable artifact.

3. **Plan the sweeps** (diffs against the snapshot):
   ```bash
   bash runtime-rust/scripts/keep-go-parity.sh plan
   ```
   Read the `PLAN_*` lines: `PLAN_EXAMPLES` is always 1; `PLAN_PERF` is 1 when any
   new example landed OR the Go backend changed. No classification gate — the
   equiv mode is DERIVED from `example_shape`, so a new example auto-classifies.

4. **Run the sweeps per the plan** (BOTH are night-gated 22:00–08:00
   America/Sao_Paulo; during the day prefix `SKY_SWEEP_FORCE=1`):
   - **Always:** **sky-rust-backend:examples-sweep** — ONE sweep that, per
     example, **BUILDS** (`--backend rust` + cargo), **RUNS** it headless per shape
     (cli no-panic / server+live boot+serve / live browser round-trip /
     tui pty / webview xvfb), AND asserts **Go≡Rust EQUIVALENCE** per the DERIVED
     equiv mode (stdout-diff cli / body-diff server / both-pass-scenario live /
     both-no-crash tui). Emits a BUILD·RUN·EQUIV table. There is NO separate
     build / run / equiv / web sweep — they are all this one sweep.
   - **New web/live example?** examples-sweep covers it automatically — RUN drives
     the browser round-trip and EQUIV runs the SAME scenario against both backends
     (scenario derived from the example name → falls back to `smoke`). Author a
     richer scenario in `scripts/verify-scenarios.mjs` if the smoke fallback is too
     thin.
   - **If `PLAN_PERF=1`:** **sky-rust-backend:examples-perf-sweep** — needs the
     user to close apps first, so follow that skill's close-the-apps reminder and
     wait for go-ahead. When `PLAN_PERF` fired only on `GO_BACKEND_CHANGED`,
     confirm the change is genuinely perf-relevant (read the changelog) before
     spending the hour.

5. **Autonomous swarm-fix of RED examples (AFTER the full sweep).** Any **RED**
   row in examples-sweep — a Rust-side **build / run / equiv** failure
   (`sky-fail` / `cargo-fail` / `panic` / `hang` / `noserve` / `notty` /
   `DIFFER`) — is **root-caused and fixed in-boundary via the autonomous swarm**
   (**sky-rust-backend:autonomous-swarm**), adhering to the README principles,
   **after** the full sweep finishes (not mid-sweep — a complete RED list lets the
   swarm batch related fixes). **AMBER `go-ref-broken` is NOT swarmed** — it is an
   upstream Go bug, not a Rust failure; report it, don't fix it here. The fix lands
   in-boundary (`runtime-rust/`, `src/Sky/Generate/Rust/`, …), passes the pre-final
   code gate, and a regression fixture that fails pre-fix is added (green build ≠
   correct). Re-run examples-sweep to confirm the row flips green.

6. **Kernel-parity backlog (skydex)** — examples-sweep verifies *runtime* parity;
   skydex surfaces *structural* parity: kernels upstream now has on the **Go** side
   that the **Rust** backend doesn't implement yet (which no example may exercise).
   The index is fresh — the sync's Step 9 ran `skydex update`:
   ```bash
   ( cd tools/skydex && cargo build --release >/dev/null )   # once, if not built
   tools/skydex/target/release/skydex parity --gaps | grep '^go-only'
   ```
   Each `go-only` row carries its `route=…`/`go=…` locations. A tracked
   **backlog, NOT a hard gate** — but any `go-only` kernel **this sync newly
   introduced** must be reported so it enters the pipeline (no-deferral). Use
   skydex, not Gortex (it OOMs this repo).

7. **Report the consolidated parity verdict** — upstream version + merge commit;
   then examples-sweep `N green · M red · K skipped · amber=A` with the equiv-mode
   breakdown (`stdout=… body=… scenario=… serve=… pty=… n/a=…`), the RED list +
   swarm-fix outcome, perf summary (if run), and the **kernel-parity backlog**
   from step 6. **"✓ GO PARITY MAINTAINED" only when examples-sweep is green (no
   RED row; amber go-ref-broken is acceptable)** — the skydex backlog is reported
   but does NOT gate the verdict. Otherwise "✗ GO PARITY NOT MAINTAINED".

> The always-run examples-sweep is also one command for non-agent use:
> `keep-go-parity.sh run` (forces past the night gate; perf stays surfaced).

## Why a planner, not one mega-script

`sync` needs conflict judgement and `perf` needs an interactive close-apps
reminder — neither belongs in a non-interactive script. So `keep-go-parity.sh`
is primarily a **planner** (snapshot + post-merge delta detection), and this
skill orchestrates the interactive pieces. The planner is fast and testable; the
sweeps keep their own skill semantics.

**Non-agent shortcut.** `keep-go-parity.sh run` (after you've synced upstream
yourself) prints the plan AND auto-runs examples-sweep (build + run + equiv;
forces past the night gate); perf is surfaced as a recommendation, not run (it
needs apps closed). The agent flow above is richer (drives the sync + perf with
their reminders, and the swarm-fix step); `run` is for a user without an agent.

## Baked-in gotchas

- Run from the Sky repo on `feat/runtime-rust` with a clean tree (sync-with-
  upstream enforces this).
- BOTH sweeps are night-gated (22:00–08:00 America/Sao_Paulo); `SKY_SWEEP_FORCE=1`
  overrides. The `run` subcommand forces past it automatically.
- The planner classifies a new example as web/live by grepping its `src/` for
  `Std.Live`/`Live.app`/`Server.listen`/`Sky.Http.Server`.
- `PLAN_PERF` on `GO_BACKEND_CHANGED` is a *candidate* — the Go backend changing
  doesn't always mean a perf delta; the agent confirms before running perf.
- The full chain can run >1 h (examples-sweep ~30–40 min + optional perf ~1 h).
  Run each sweep in the background and wait.

## Capture learnings (self-improving loop)

After this skill's work completes, record any **significant, verified,
generalizable** learning — a non-obvious pitfall, a deeper foundational insight,
or a secure/correct/sound optimization — to the **`## Agent learnings`** section
of `runtime-rust/CLAUDE.md`, so future agents improve. Obey that section's rules:
**only if secure, correct, and sound + verified**; **reconcile (update / dedupe /
prune), never blind-append**; **skip when nothing significant** — most runs add
nothing, and manufacturing an entry is worse than none.
