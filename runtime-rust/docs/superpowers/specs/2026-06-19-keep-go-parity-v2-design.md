# keep-go-parity v2 — design

**Date:** 2026-06-19 · **Branch:** `feat/runtime-rust` (fork-only) · **Status:** draft for review

## Goal

Turn the recurring **sync-upstream → reach Go parity → verify → push** loop into a
single **resumable** orchestration that chains modular skills, adds the one missing
skill (implementing newly-arrived Go functionality on the Rust side), and verifies
**change-scoped** locally while leaning on CI for the full matrix. Honours the
principle order **security > correctness > soundness > efficiency > completeness >
readability**; the thesis stays "mirror Go behaviour, with more security/
correctness/soundness."

## A. New skill — `sky-rust-backend:implement-parity-gap`

**When:** after a sync, `skydex parity --gaps` reports Go-only kernels/features the
Rust backend lacks (or an example fails because a kernel is unimplemented).

**Nature:** an **orchestration PATTERN**, not a deterministic runner — implementing
a parity gap is judgment-heavy creative engineering. The skill captures the
*discipline*, not a push-button. Per gap (batched by subsystem where possible):

1. **Locate the Go reference behaviour** — the Go runtime fn and/or the example
   that exercises it; that is the oracle to mirror.
2. **Implement (in-boundary):** a runtime fn in `runtime-rust/src/sky_runtime/` +
   routing in `Builder/Kernel.hs` (+ Cargo feature-gating if it needs a new dep —
   and NEVER a new external-crate dep in a shared/always-compiled module, per the
   CLAUDE.md learning) + a **pre-failing fixture** under `runtime-rust/tests/sky/`
   (the failing test is the discovery artefact).
3. **Verify (orchestrator only):** `cargo build/test --features full` + a
   **feature-minimal** build + `cabal build exe:sky` + build the fixture/example on
   `--backend rust`.
4. **Soundness floor:** no panic from well-typed Sky; degrade, never crash.

Multi-gap fan-out reuses `sky-rust-backend:autonomous-swarm` (agents author
**disjoint** files, never build; orchestrator does the single integration build).
**Boundary:** runtime + Rust codegen + `examples/rust/` fixtures only.

## B. `keep-go-parity` v2 — the chain (resumable, checkpoint-commit per phase)

| # | Phase | Skill / step |
|---|---|---|
| 0 | record **BASE = HEAD** (pre-run SHA) | for the change diff |
| 1 | sync + resolve conflicts | `sync-with-upstream` |
| 2 | re-index | `skydex update` |
| 3 | implement new functionality | `implement-parity-gap` (`skydex parity --gaps` → swarm) |
| 4 | re-index | `skydex update` |
| 5 | **scoped** build · run · equivalence · round-trip | `examples-sweep` (scoped — §C) |
| 6 | audit the diff | `quality-audit` + `principles-audit` (incremental) |
| 7 | docs | `update-docs` |
| 8 | push → CI full verification | `push` → CI: full 3-OS sweep + `examples-perf-sweep` + `static-perf` |

- **Checkpoint-commit per phase** so a long autonomous run is **resumable**; a
  mid-pipeline failure re-enters at the first incomplete phase (phase state recorded
  in a small run-state file or derived from the last commit).
- `skydex update` is **early** (2 + 4), never last — phases 3/5/6 consume the index.

## C. Change-scoped sweep — `lib/examples.sh changed_examples <base>`

One `git diff --name-only <BASE>..HEAD`, computed once, feeds **both** the scoped
sweep (phase 5) and the incremental audit (phase 6). Scope = **union** of:

| Diff touched | Adds to scope | Why |
|---|---|---|
| `examples/NN-*` | those example dirs (+ any **new** dir, always) | an example depends only on its own source — precise |
| `runtime-rust/src/**` (a kernel) | `skydex covers <kernel>` → consumer examples | a runtime change can regress any consumer |
| `src/Sky/Generate/Rust/**` (codegen) | broad — emission changes for everyone | no clean per-example map |
| — (always) | **representative-per-shape floor** (1× cli/server/live/tui/webview) | baseline coverage when the map is imprecise |

- The new `changed_examples <base>` helper lives in **`lib/examples.sh`** (the
  single source of truth for the example manifest); it emits an explicit example
  list passed to `examples-sweep` via its existing list-override env (no sweep
  rewrite).
- **Honest contract:** precise scoping is provably safe ONLY for example-source
  changes. For runtime/codegen changes the blast radius is broad, so the scoped
  **local** sweep is *fast pre-push feedback* — **CI's full 3-OS sweep on push is
  the real gate** (the "no local sweeps; CI verifies" rule). keep-go-parity does
  NOT gate on the scoped local run for runtime/codegen changes.

## Non-goals

- Not a push-button parity machine — `implement-parity-gap` is judgment-heavy.
- No new skills for steps already covered (`examples-sweep`/`-perf-sweep`,
  `quality-audit`, `principles-audit`, `update-docs`, `push`, `sync-with-upstream`).
  Only `implement-parity-gap` is new (+ the `changed_examples` helper + the
  keep-go-parity v2 chain edits).
- perf + static stay CI-side (dispatch/schedule jobs), not the local gate.

## Build order

1. `lib/examples.sh changed_examples <base>` helper (+ a tiny test).
2. `sky-rust-backend:implement-parity-gap` SKILL.md (via `writing-skills`: baseline →
   write → verify on a real `parity --gaps` gap).
3. `keep-go-parity` v2 — chain the phases + checkpoint/resume in `keep-go-parity.sh`
   and its SKILL.md.
