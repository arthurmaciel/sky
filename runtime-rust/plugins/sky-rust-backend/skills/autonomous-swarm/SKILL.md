---
name: autonomous-swarm
description: "Orchestrate an autonomous multi-agent team to deliver a large in-boundary Rust-backend task (port / migration / buildout) too big for one context: 1 asker + 3 reasoners that cross-critique and converge -> orchestrator synthesis -> de-risk the spine -> contracts skeleton -> parallel executors under a strict data-race protocol -> sequential shared-state stages -> adversarial review -> finalize. Use when the user asks to autonomously tackle a big build with a planning+executor sub-agent team, run a dynamic agent workflow, or 'swarm' a large task. Trigger: /sky-rust-backend:autonomous-swarm."
---

# autonomous-swarm

Drive a large, architecturally-uncertain, in-boundary task to completion with an
autonomous sub-agent team **when one context can't hold it**. The orchestrator
(you) plans with a brainstorming panel, de-risks the unknowns, fans work out to
executors under a hard anti-race contract, and verifies relentlessly. Distilled
from the real `examples/rust/skyshop-rs` port (a 1:1 port of an 8.2k-line app
binding 3 real async crates).

**Prime directive:** the orchestrator is the single source of truth and the only
message bus. Sub-agents never peer-chat and never share mutable build state;
every hand-off goes through you. You keep the conclusions, not the file dumps.

## When to use / not

| Use it | Don't |
|---|---|
| A task too big for one context (full port, broad migration, multi-crate buildout) where the **architecture isn't obvious** | A change you can hold in one head — just do it (or one `Agent`) |
| Independent work that genuinely parallelizes | Inherently sequential work with one coherent artifact (parallelism adds only race risk) |
| You can split it into disjoint files + stable contracts | You can't define disjoint ownership — keep it sequential |

This is the **opt-in heavy path**: it spawns many agents and burns real tokens.
Only run it when the user explicitly asks for an autonomous multi-agent buildout.

## Pipeline (run in order; each phase gates the next)

```
0 Frame + feasibility probe
1 Plan      : 1 asker -> 3 reasoners -> cross-critique round -> orchestrator synthesis (ONE spec)
2 De-risk   : prove the make-or-break spine with a minimal vertical slice
3 Skeleton  : establish shared CONTRACTS (types/APIs/signatures) + 1 green end-to-end path
4 Fan-out   : parallel executors author DISJOINT files; orchestrator integrates + builds
5 Sequential: stages that all mutate ONE shared resource run one-at-a-time
6 Review    : adversarial security/soundness pass; FILE (don't bury) every gap found
7 Finalize  : docs, status row, checkpoint commits, hygiene, honest results
```

### Phase 0 — Frame + feasibility probe (orchestrator, inline)
Before spending agents, probe the load-bearing unknowns yourself: toolchains,
network (can the crates be fetched), disk headroom (reclaim if tight; abort
spawns under ~5 GB free), the build symlink, mem-guard. A 2-minute probe stops
you planning against a wall.

### Phase 1 — Plan (superpowers:brainstorming, panel form)
- **1 asker** (run FIRST): the brainstorming questioner. Explores the target +
  the boundary, then writes a comprehensive, grouped, *cited* question list —
  including a §0 "blocking contradictions" group. It proposes NO answers.
- **3 reasoners** (run in parallel, INDEPENDENT): each answers every question +
  proposes a complete plan. Independence is the point — convergence across
  independent reasoners is your confidence signal; divergence flags the real
  decisions.
- **Cross-critique round** (orchestrator-mediated — there is no peer chat):
  `SendMessage` each reasoner the *other two* plans; ask "where do you disagree,
  and what is your reconciled position?" Collect. This is how a "discussing team"
  actually works here — you are the bus.
- **Synthesis** (orchestrator): merge the converged decisions + any user
  overrides into ONE authoritative spec (`runtime-rust/docs/superpowers/specs/`).
  Executors follow the synthesis, never the raw plans. Lock each decision with a
  one-line rationale.

### Phase 2 — De-risk the spine (the highest-value step)
Pick the single mechanism that, if it fails, makes the whole plan moot (the FFI
delivery path; the async bridge; a cross-cutting codegen assumption). Build the
**smallest vertical slice** that exercises it end-to-end to GREEN. Do this
yourself or one tightly-scoped executor. Its report becomes the **wrinkles
ledger** (see below). Never fan out before the spine is proven.

### Phase 3 — Contracts skeleton
One executor builds the green skeleton: the shared types/Model/Msg, the full
stub interfaces (canned returns, no heavy deps), one end-to-end path, and the
shared view/helper conventions. It returns the **contracts** every parallel
executor must follow. Parallel authoring is unsafe until contracts are frozen.

### Phase 4 — Parallel fan-out (the data-race protocol)
Fan out executors on **disjoint files**. Each brief MUST carry the protocol:

| Rule | Why |
|---|---|
| Write ONLY your assigned files (named explicitly) | no co-edit races |
| Do NOT edit shared files (entry/router, shared types, `sky.toml`, the wrapper repo) | orchestrator owns the integration seam |
| Do NOT run `sky build` / `cargo build` | shared `CARGO_TARGET_DIR` holds only the last build (clobber); `sky-out`/`.skycache` -> `resource busy` |
| Self-review against the frozen contracts; return source + unresolved names | orchestrator does the ONE integration build + reconciles |

The orchestrator then wires the shared seam and runs the single integration
build, absorbing the cross-file type errors. (Alternative: `isolation:
"worktree"` per agent — but worktrees still share `CARGO_TARGET_DIR`; giving each
its own target dir re-compiles every heavy dep per agent. Author-only +
serial-integrate is cheaper and was the proven choice.)

### Phase 5 — Sequential shared-state stages
Any set of stages that all mutate the SAME resource (one wrapper git repo + one
example build) is **sequential, not parallel** — concurrent commits + concurrent
builds race. Run them one at a time; each ends GREEN before the next starts.

### Phase 6 — Adversarial review (do NOT skip — this was the gap)
The build being green is necessary, not sufficient. Run an adversarial pass over
the security/soundness-sensitive surface (anything touching auth/secrets/payments,
TEA dispatch, `unsafe`, generated FFI, panic vectors). Use
`superpowers:requesting-code-review`, `/security-review`, or
`sky-rust-backend:quality-audit`. Every gap found is **filed** (a spec/issue +
the no-deferral rule), never silently worked around. Workarounds the executors
applied (e.g. a codegen default that needed an explicit signature) get an
explicit follow-up, not burial.

### Phase 7 — Finalize
Docs (`update-docs` / README + status row), checkpoint commits split by concern,
end-of-mission orphan + disk hygiene, and an **honest** results report — separate
what was build-proven, run-verified, shim-level-proven, and not-yet-proven.

## Carry-forward discipline (the connective tissue)

- **Wrinkles ledger.** Every executor returns the gotchas the next one needs
  (exact dep shapes, naming quirks, cache-busting steps, codegen surprises).
  Thread it into each subsequent brief. This is what stops N agents each
  re-discovering the same trap.
- **Green gate.** Never hand a broken tree to the next phase. Each stage ends
  with `sky build --target rust` + `cargo build` GREEN (run-verify where a test
  backend exists: emulator / mock / test mode).
- **Checkpoint commits** between stages, split by concern (general in-boundary
  fixes first for bisectability, then the artifact). Recoverable + reviewable.

## Superpowers integration (which skill, which phase)

| Phase | Superpowers skill |
|---|---|
| 1 Plan | `brainstorming` (asker + reasoners), `writing-plans` (synthesis) |
| 2-5 Build | `dispatching-parallel-agents`, `test-driven-development`, `systematic-debugging` |
| 6 Review | `requesting-code-review` / `receiving-code-review`, `/security-review` |
| 7 Finalize | `verification-before-completion`, `finishing-a-development-branch` |

## Tuning knobs

| Knob | Guidance |
|---|---|
| Reasoner count | 2 converged on a real port; **3 + a cross-critique round** catches more on genuinely hard architecture. Diminishing returns past 3. |
| Asker depth | Exhaustive + cited; the "blocking contradictions" group is the highest-value output. |
| Executor scope | Tight, single-concern; pass the env, the boundary, the no-panic rule, and the wrinkles ledger in EVERY brief. |
| Parallel width | Bounded by *disjoint-file availability*, not by ambition. If you can't name disjoint ownership, don't parallelize. |
| Verify bar | Build-green mandatory; run-verify against an emulator/mock/test-mode whenever one exists. |

## Pitfalls (observed)

- **Fanning out before the spine is proven** — the worst failure mode. De-risk first.
- **Parallel builds on the shared target** — silent clobber / `resource busy`. Author-only in parallel.
- **Treating the raw reasoner plans as the spec** — executors need ONE synthesized source of truth.
- **Skipping the final adversarial review** — green != secure/sound. Auth/payment/dispatch code earns a review.
- **Burying codegen/runtime gaps as workarounds** — violates no-deferral; file them.
- **Letting an executor edit shared files** — the routing/types/`sky.toml`/wrapper-repo seam is orchestrator-only.

## Non-negotiables

- **Boundary** in every brief: only `runtime-rust/`, `src/Sky/Generate/Rust/`,
  `src/Sky/Build/Rust/`, `tools/sky-ffi-inspect-rs/`, `examples/rust/`. Never the
  shared stdlib, the Go backend, or the author's `examples/`.
- **No-panic existential rule** restated in every executor brief; in-boundary
  fixes pass a HARD regression gate (the Std.Ui/Tui examples + `cargo test`)
  before acceptance.
- **Disk + orphan hygiene** per heavy stage and at end-of-mission; mem-guard
  alive; reclaim before spawning; abort spawns under ~5 GB free.

## Capture learnings (self-improving loop)

After this skill's work completes, record any **significant, verified,
generalizable** learning — a non-obvious pitfall, a deeper foundational insight,
or a secure/correct/sound optimization — to the **`## Agent learnings`** section
of `runtime-rust/CLAUDE.md`, so future agents improve. Obey that section's rules:
**only if secure, correct, and sound + verified**; **reconcile (update / dedupe /
prune), never blind-append**; **skip when nothing significant** — most runs add
nothing, and manufacturing an entry is worse than none.
