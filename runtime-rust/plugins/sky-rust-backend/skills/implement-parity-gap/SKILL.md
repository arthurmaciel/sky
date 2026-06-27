---
name: implement-parity-gap
description: Use after an upstream sync when skydex parity --gaps reports go-only kernels/features the Rust backend lacks, or when an example fails because a kernel is unimplemented. Use when closing the Go→Rust parity gap for newly-arrived functionality. Trigger: /sky-rust-backend:implement-parity-gap.
---

# implement-parity-gap

## Overview

Close a Go→Rust parity gap — a kernel/feature Go has that the Rust backend
doesn't yet mirror — by **autonomously implementing the mechanical ones** and
**escalating the rest**. Implementing a parity gap is judgment-heavy creative
engineering, so this skill captures the *discipline*, not a push-button.

**Thesis:** the Rust backend MIRRORS Go's behaviour, with MORE security/
correctness/soundness. Principle order (a lower never overrides a higher):
**security > correctness > soundness > efficiency > completeness > readability.**

**The one load-bearing rule:** a green build proves *it compiles*; only a
**Go≡Rust equivalence fixture** proves *it mirrors Go*. The build gate is
**necessary but NOT sufficient** for parity. "It compiles and the output looks
right" is not parity — *the same input run through both backends, diffed* is.

## When to use / not

- **Use:** after a sync when `skydex parity --gaps` shows `go-only` rows; when an
  example fails because a kernel is unimplemented; when closing newly-arrived Go
  functionality on the Rust side.
- **Don't:** for a Rust-only bug with no Go counterpart (just fix it); for a gap
  the user already scoped as a standalone subsystem project (that's its own plan).

## The autonomy decision (read this first, every gap)

Autonomous-by-default, **gated on a Go≡Rust equivalence fixture**, with explicit
escalation. Triage every gap against this table BEFORE writing code:

| | Autonomous — close it | Escalate to the user |
|---|---|---|
| **Shape** | a **mechanical** gap: a new **pure stdlib kernel** (String/List/Dict/Math/…) with a clear Go oracle and deterministic I/O | anything in the right column |
| **Gate** | a Go≡Rust **equivalence fixture** auto-establishes AND passes **non-vacuously** | — |
| **Trigger** | — | the build fails after a bounded fix attempt; OR an equivalence fixture **can't be auto-established** or only passes **vacuously** (no real oracle, or non-deterministic output — clocks / entropy / map-ordering); OR the gap is **subsystem-scale** (new runtime module, new external dep, codegen-shape change, framework/effect/platform surface) |

- **Vacuous pass = escalate, not done.** A fixture that "passes" because both
  sides emit nothing, or because the Rust side returns `Err`/stub while Go does
  real work, has proven NOTHING. Routing a kernel so `skydex parity --gaps` stops
  listing it is **gaming the metric**, not closing the gap — the row going quiet
  is not a DONE criterion.
- **Escalation is explicit, never silent.** On a trigger: STOP, record the gap
  (a one-paragraph spec + a no-deferral entry per `runtime-rust/CLAUDE.md`),
  signal the user. Never bury a subsystem-scale gap as a half-finished stub and
  never mark an unmirrored kernel "done".

## The per-gap loop (mechanical gaps; batch by subsystem)

1. **Locate the Go reference behaviour** — the Go runtime fn (`runtime-go/rt/…`)
   and/or the example that exercises it, and its kernel route in Go's
   `Kernel.hs`. That Go behaviour is the **oracle** you must mirror — read its
   signature (arity, param types, return type) before writing a line of Rust.
2. **Implement in-boundary:**
   - a runtime fn in `runtime-rust/src/sky_runtime/` (total — no panic from
     well-typed Sky; degrade, never crash),
   - routing in `src/Sky/Generate/Rust/Builder/Kernel.hs` (and, for a kernel
     that needs inline type-conversion wrapping, the parallel `Can.VarTopLevel`
     arm in the Rust ExprEmitter — a name route alone compiles but can emit the
     wrong call shape; see the ExprEmitter `VarTopLevel`/`VarKernel` note in
     `runtime-rust/CLAUDE.md` `## Agent learnings`),
   - Cargo feature-gating IF it needs a new dep — and **NEVER add a new
     external-crate dep to a shared/always-compiled module** (it passes
     `--features full` but breaks feature-minimal projects with E0433; use a
     std-only path or a gated module — see the CLAUDE.md learning),
   - a **pre-failing fixture** under `runtime-rust/tests/sky/` (the failing test
     is the discovery artefact).
3. **Establish the Go≡Rust equivalence fixture** — run the SAME Sky input through
   **both** backends and **diff the outputs**:
   `sky build src/Main.sky` (Go) vs `sky build --backend rust` (Rust), run each,
   compare normalized stdout/body. This — not the unit test, not the build — is
   what proves parity. If you cannot establish a non-vacuous diff (no Go oracle
   to run, or non-deterministic output), that is an **escalation trigger**, not a
   pass.
4. **Verify (orchestrator only — never the fan-out agents):**
   `cargo build/test --features full` + a **feature-minimal** example build
   (e.g. `sky build --backend rust src/Main.sky` on a CLI/no-Db example, to
   exercise the non-`full` code path and catch a dep that only resolves under
   `--features full`) + `cabal build exe:sky` + build the fixture on
   `--backend rust` + **run the equivalence fixture and confirm the diff is
   clean.**
5. **Soundness floor:** a well-typed Sky program must not panic through this
   kernel; on a real error return `Err`, don't crash.

## Multi-gap fan-out

For several mechanical gaps at once, reuse **`sky-rust-backend:autonomous-swarm`**:
fan-out agents author **DISJOINT files, never build**; the **orchestrator** does
the single integration build, the unit tests, AND the equivalence run. Batch
related kernels (one subsystem) per swarm so a break is bisectable.

**Boundary (every gap):** runtime (`runtime-rust/`) + Rust codegen
(`src/Sky/Generate/Rust/`, `src/Sky/Build/Rust/`) + `runtime-rust/tests/sky/`
fixtures only (parity-gap fixtures go here; `examples/rust/` is for real,
complete Sky projects only). NEVER the shared stdlib (`sky-stdlib/`), the Go
backend, or the author's `examples/`.

## Common mistakes

| Mistake | Why it's wrong |
|---|---|
| Marking a kernel DONE on a green build (no equivalence run) | a green build proves it compiles, not that it mirrors Go. Run both backends, diff. |
| Treating "`skydex parity --gaps` no longer lists it" as DONE | a route silences the row even when behaviour isn't mirrored — that's gaming the metric. |
| Counting a vacuous equivalence pass | both-emit-nothing, or Rust-`Err` vs Go-does-work, proves nothing → escalate. |
| Stubbing a subsystem-scale gap autonomously + calling it closed | new platform/dep/module surface must ESCALATE; a stub is not parity. |
| Adding a new crate dep to a shared/always-compiled module | passes `--features full`, breaks feature-minimal builds (E0433). std-only or gated module. |
| Skipping the pre-failing fixture | the failing test is the discovery artefact; without it you can't prove the gap was real or that you closed it. |
| Letting fan-out agents build | shared `CARGO_TARGET_DIR`/`.skycache` → clobber / `resource busy`. Authors author; the orchestrator builds + runs equivalence once. |

## Capture learnings (self-improving loop)

After this skill's work completes, record any **significant, verified,
generalizable** learning — a non-obvious pitfall, a deeper foundational insight,
or a secure/correct/sound optimization — to the **`## Agent learnings`** section
of `runtime-rust/CLAUDE.md`, so future agents improve. Obey that section's rules:
**only if secure, correct, and sound + verified**; **reconcile (update / dedupe /
prune), never blind-append**; **skip when nothing significant** — most runs add
nothing, and manufacturing an entry is worse than none.
