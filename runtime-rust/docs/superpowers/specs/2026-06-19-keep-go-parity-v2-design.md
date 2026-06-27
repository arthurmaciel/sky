# keep-go-parity v2 — design

**Date:** 2026-06-19 · **Branch:** `feat/runtime-rust` (fork-only) · **Status:** implemented (skill `runtime-rust/plugins/sky-rust-backend/skills/implement-parity-gap`; `changed_examples <base>` in `runtime-rust/scripts/lib/examples.sh`; state-file resume in `runtime-rust/scripts/keep-go-parity.sh`)

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

### Autonomy model — autonomous-by-default, equivalence-fixture-gated, with escalation

The skill closes mechanical gaps **autonomously**; it escalates the rest. The
gate that makes autonomy safe is a **Go≡Rust equivalence fixture** — a build-green
binary is *necessary but not sufficient* for parity. A new kernel that compiles
but returns the wrong bytes is a silent parity regression; only an equivalence
fixture that runs the Go reference and the Rust output on the same input and
diffs them proves the mirror.

| | Autonomous (close it) | Escalate to the user |
|---|---|---|
| **Shape** | a mechanical gap: a new **pure stdlib kernel** (String/List/Dict/Math/etc.) with a clear Go oracle and a deterministic I/O | anything below |
| **Gate** | a **Go≡Rust equivalence fixture** can be auto-established AND passes non-vacuously | — |
| **Trigger** | — | build fails after a bounded fix attempt; OR an equivalence fixture **can't be auto-established** or only passes **vacuously** (no real oracle / non-deterministic output — clocks, entropy, ordering); OR the gap is **subsystem-scale** (new runtime module, new dep, codegen-shape change, framework/effect surface) |

- **Equivalence-fixture-as-gate** is the load-bearing rule the skill teaches: the
  build gate proves *it compiles*, the equivalence gate proves *it mirrors Go*.
  A fixture that passes because both sides emit nothing (vacuous) is a failed gate
  → escalate.
- **Escalation is explicit, not silent.** On a trigger, the skill stops, records
  the gap (a one-paragraph spec + the no-deferral entry), and signals the user —
  it never buries a subsystem-scale gap as a half-fix or marks an unmirrored
  kernel done.

## B. `keep-go-parity` v2 — the chain (resumable via a run-state file)

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

- **Resume is driven by a gitignored run-state file**, NOT by the last commit.
  Several phases produce **zero commits** — `skydex update` (2, 4), the scoped
  sweep (5), a clean audit (6) — so a commit-derived resume would mis-locate the
  frontier and re-run or skip phases. The state file is the single source of
  truth for "where are we".
  - Path: `.skycache/keep-go-parity.state` (gitignored — the cache dir already is).
  - Contents: `BASE=<sha>` (the phase-0 pre-run HEAD, fixed for the whole run) +
    `last_completed_phase=N` + a per-phase status line (`ok` / `failed` / `skipped`).
  - A mid-pipeline failure re-enters at `last_completed_phase + 1`; a fresh run
    (no state file, or `--restart`) starts at phase 0 and records a new `BASE`.
- **Work commits stay separate** from the state file — implement (3) and docs (7)
  commit real changes for **bisectability**; the state file is bookkeeping, never
  bundled into a work commit.
- `skydex update` is **early** (2 + 4), never last — phases 3/5/6 consume the index.

## C. Change-scoped sweep — `lib/examples.sh changed_examples <base>`

One `git diff --name-only <BASE>..HEAD`, computed once, feeds **both** the scoped
sweep (phase 5) and the incremental audit (phase 6). Scope = **union** of:

| Diff touched | Adds to scope | Why |
|---|---|---|
| `examples/NN-*` | those example dirs (+ any **new** dir, always) | an example depends only on its own source — precise |
| `runtime-rust/src/**` (a kernel) | `skydex covers <kernel>` → consumer examples | a runtime change can regress any consumer |
| `src/Sky/Generate/Rust/**` or `src/Sky/Build/Rust/**` (codegen) | broad — emission changes for everyone | no clean per-example map |
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
3. `keep-go-parity` v2 — chain the phases + `.skycache/keep-go-parity.state`
   resume (read/write/`--restart`) in `keep-go-parity.sh` and its SKILL.md.
