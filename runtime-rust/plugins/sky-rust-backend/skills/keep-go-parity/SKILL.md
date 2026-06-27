---
name: keep-go-parity
description: One command to ingest the latest upstream and re-prove the Rust backend stays at Go parity. Runs the resumable v2 chain (state-file driven): sky-rust-backend:sync-with-upstream (resolving merge conflicts autonomously, asking only on a real design decision) → skydex re-index → sky-rust-backend:implement-parity-gap for new Go functionality → re-index → a scoped BUILD·RUN·EQUIV sweep over the diff blast-radius → sky-rust-backend:quality-audit + sky-rust-backend:principles-audit of the diff → sky-rust-backend:update-docs → sky-rust-backend:push, where CI runs the full 3-OS examples-sweep + examples-perf-sweep. RED examples surfaced by the full sweep are root-caused + fixed in-boundary via the autonomous swarm afterward. The non-agent shortcut keep-go-parity.sh run instead force-runs the full examples-sweep and surfaces perf as a recommendation. Use when the user asks to keep Go parity, sync upstream and re-verify, or after an upstream release. Trigger: /sky-rust-backend:keep-go-parity.
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

## Workflow — the v2 chain (resumable via .skycache/keep-go-parity.state)

Resume is driven by the **run-state file**, NOT the last commit (phases 2/4/5
produce zero commits, and phase 6 produces none when the audit is clean). On entry: if a state file exists, resume at
`last_completed_phase + 1`; else `state-init` (records BASE = HEAD) and start at
phase 1. `keep-go-parity.sh --restart` forces a fresh run. After each phase
completes, `keep-go-parity.sh state-done <N>`.

| # | Phase | Skill / step | Commits? |
|---|---|---|---|
| 0 | `state-init` — record BASE = HEAD | `keep-go-parity.sh state-init` | no |
| 1 | sync + resolve conflicts | **sky-rust-backend:sync-with-upstream** | merge commit |
| 2 | re-index | `skydex update` | no |
| 3 | implement new functionality | **sky-rust-backend:implement-parity-gap** (`skydex parity --gaps` → swarm) | work commits |
| 4 | re-index | `skydex update` | no |
| 5 | **scoped** build·run·equivalence·round-trip | `keep-go-parity.sh scoped-sweep` (changed_examples → RUST_EXAMPLES) | no |
| 6 | audit the diff | **sky-rust-backend:quality-audit** + **sky-rust-backend:principles-audit** (incremental, since BASE) | fix commits |
| 7 | docs | **sky-rust-backend:update-docs** | docs commit |
| 8 | push → CI full verification | **sky-rust-backend:push** → CI: full 3-OS sweep + examples-perf-sweep + static-perf | — |

- Phase 3 escalates per implement-parity-gap's gate (subsystem-scale / no
  equivalence oracle → stop + signal the user).
- Phase 5 is **fast pre-push feedback**, scoped to the diff blast-radius since
  BASE. Honest contract: precise only for example-source changes; for
  runtime/codegen changes the scope widens broadly and **CI's full 3-OS sweep on
  push (phase 8) is the real gate** — keep-go-parity does NOT gate on the scoped
  local run for runtime/codegen changes.
- **Swarm-fix RED rows** (the swarm-fix step the frontmatter + Principles section
  reference). Any RED example surfaced by the full sweep — CI's 3-OS sweep at
  phase 8, or the scoped phase-5 run for example-source changes — is root-caused +
  fixed in-boundary via **sky-rust-backend:autonomous-swarm**, adhering to the
  Principles above, AFTER the full sweep (a complete RED list lets the swarm batch
  related fixes). NOT amber `go-ref-broken` (an upstream Go bug, not a Rust-side
  regression).
- `skydex update` is **early** (2 + 4), never last — phases 3/5/6 consume the index.
- Work commits stay separate from the state file (bisectability); the state file
  is bookkeeping, never bundled into a work commit.

> The always-run examples-sweep is also one command for non-agent use:
> `keep-go-parity.sh run` (after you've synced upstream yourself — forces past
> the night gate; perf stays surfaced as a recommendation).

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
- `PLAN_PERF` on `GO_BACKEND_CHANGED` (the planner's `plan`/`run` path) is a
  *candidate* — the Go backend changing doesn't always mean a perf delta. In the
  v2 agent chain perf is delegated to CI (phase 8), so this gating is
  informational only there; on the non-agent `run` path perf is surfaced as a
  recommendation, never auto-run (it needs apps closed).
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
