---
name: keep-go-parity
description: One command to ingest the latest upstream and re-prove the Rust backend stays at Go parity. Runs sky-rust-backend:sync-with-upstream (resolving merge conflicts autonomously, asking only on a real design decision), then the build + run sweeps always, plus the web sweep when new web/live examples land and the perf sweep when any new example or a Go-backend perf change lands. Use when the user asks to keep Go parity, sync upstream and re-verify, or after an upstream release. Trigger: /sky-rust-backend:keep-go-parity.
---

# keep-go-parity

Ingest the latest `anzellai/sky` upstream into `feat/runtime-rust` **and** prove
the Rust backend still matches Go — in one orchestrated pass. It chains the
sibling skills; a deterministic planner (`keep-go-parity.sh`) decides which
sweeps the merge actually warrants so nothing runs needlessly and nothing
needed is skipped.

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
   - Do not push. The merge commit is the durable artifact.

3. **Plan the sweeps** (diffs against the snapshot):
   ```bash
   bash runtime-rust/scripts/keep-go-parity.sh plan
   ```
   Read the `PLAN_*` lines: `PLAN_BUILD`/`PLAN_RUN`/`PLAN_EQUIV` are always 1;
   `PLAN_WEB` is 1 when a new web/live example landed; `PLAN_PERF` is 1 when any
   new example landed OR the Go backend changed. **`UNCLASSIFIED_EXAMPLES`** must
   read `none` — any listed example is a hard blocker (see step 4's gate).

4. **Run the sweeps per the plan:**
   - **Always:** **sky-rust-backend:build-sweep** → (only if build passed)
     **sky-rust-backend:run-sweep** → **sky-rust-backend:equiv-sweep**. A build
     failure is a parity break — stop; don't run later phases on a broken build.
   - **equiv-sweep is the Go≡Rust output-parity gate AND the classification gate.**
     It runs every example classified `in` (deterministic output) and **fails if
     any example on disk is unclassified** in `equiv-classification.tsv`. So if
     the merge added an example, classify it `in`/`out` (with a reason) FIRST —
     "Go parity maintained" cannot be claimed while anything is unclassified.
   - **If `PLAN_WEB=1`:** **sky-rust-backend:web-sweep**. (New web/live examples
     have no `verify-scenarios.mjs` scenario yet — the web sweep regression-guards
     the existing live set; author a scenario for the new example for true
     round-trip coverage.)
   - **If `PLAN_PERF=1`:** **sky-rust-backend:perf-sweep** — needs the user to
     close apps first, so follow that skill's close-the-apps reminder and wait for
     go-ahead. When `PLAN_PERF` fired only on `GO_BACKEND_CHANGED`, confirm the
     change is genuinely perf-relevant (read the changelog) before spending the hour.

5. **Report the consolidated parity verdict** — upstream version + merge commit;
   then per phase: build PASS/FAIL, run `N ran-OK · M failed`, equiv `N match · M
   differ` + classification coverage, web `N pass · M fail` (if run), perf summary
   (if run). **"✓ GO PARITY MAINTAINED" only when build+run+equiv(+web if run) are
   green AND every example is classified.** Otherwise "✗ GO PARITY NOT MAINTAINED".

> The whole always-run chain (build → run → equiv [→ web]) is also one command
> for non-agent use: `keep-go-parity.sh run` (perf stays surfaced, not run).

## Why a planner, not one mega-script

`sync` needs conflict judgement and `perf` needs an interactive close-apps
reminder — neither belongs in a non-interactive script. So `keep-go-parity.sh`
is primarily a **planner** (snapshot + post-merge delta detection), and this
skill orchestrates the interactive pieces. The planner is fast and testable; the
sweeps keep their own skill semantics.

**Non-agent shortcut.** `keep-go-parity.sh run` (after you've synced upstream
yourself) prints the plan AND auto-runs the warranted load-tolerant sweeps
(build → run → web-if-warranted); perf is surfaced as a recommendation, not run
(it needs apps closed). The agent flow above is richer (drives the sync + perf
with their reminders); `run` is for a user without an agent.

## Baked-in gotchas

- Run from the Sky repo on `feat/runtime-rust` with a clean tree (sync-with-
  upstream enforces this).
- The planner classifies a new example as web/live by grepping its `src/` for
  `Std.Live`/`Live.app`/`Server.listen`/`Sky.Http.Server`.
- `PLAN_PERF` on `GO_BACKEND_CHANGED` is a *candidate* — the Go backend changing
  doesn't always mean a perf delta; the agent confirms before running perf.
- The full chain can run >1 h (build ~15 min + run ~40 min + optional web/perf).
  Run each sweep in the background and wait.
