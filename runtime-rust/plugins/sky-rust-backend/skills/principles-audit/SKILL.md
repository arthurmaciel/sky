---
name: principles-audit
description: Use when you want a recurring, whole-codebase audit against security/correctness/soundness principles — sweeping every in-scope file before a release, after a large change, or on a schedule — tracked in a living per-file ledger, and when found problems must be fixed AND build-verified, not just listed.
---

# principles-audit

## Overview

A swarm-driven, **incremental** audit of a whole codebase against the project's
principle order — **security > correctness > soundness > efficiency >
completeness > readability** — recorded in a persistent per-file ledger
(`<docs>/CODE-REVIEW.md`). Built to run *often*: each pass re-audits only what
changed since that file's last audit, so the ledger never goes stale and no human
has to keep up.

**Core principle:** a finding isn't *resolved* until it is **fixed and the
integration build is green**, OR explicitly **deferred with a reason + date**.
"Authored a fix" ≠ "fixed".

## When to use / not

- **Use:** before a release; after a large change / merge / upstream sync; on a
  cadence; when you want one durable place that answers "is every file sound, and
  what's outstanding?"
- **Don't:** for a single file or PR (just review it inline); for mechanical
  lint-able rules (automate those).

## The ledger — `<docs>/CODE-REVIEW.md`

One row per in-scope file, grouped by component, **leaf-first** within each
(foundational/depended-upon files first; aggregators/`mod.rs`/facades last).

| File | Purpose | Risk | Last audited | Findings | Suggested fix | Fix |
|---|---|---|:-:|---|---|:-:|

- **Last audited** `YYYY-MM-DD` — staleness signal; empty = never audited. A
  non-empty date *is* the "agent reviewed it" mark (no separate checkbox).
- **Findings** — concrete issues, fn/line cited; `—` when genuinely clean.
- **Fix** — `✅`(fixed+built) · `⏸️`(deferred, +reason) · `➖`(no-defect) ·
  `❌`(attempted, won't verify), each with a date.

There is **no "human review" column** — a recurring autonomous audit makes it rot.

## The loop

1. **Re-index + scope the delta.** `skydex update --repo .`; compute which
   in-scope files changed since their row's **Last audited** (git diff) — only
   those (plus never-audited rows) need work this pass. First run = all files.
2. **Inventory (new/empty rows only).** A swarm skims each file → `Purpose` +
   `Risk`; insert leaf-first into its component section. Update the scope inventory.
3. **Review.** A swarm reads each in-scope-delta file **line-by-line** against the
   six principles; fills `Findings` + `Suggested fix`; stamps **Last audited**.
   `—` (clean) is a valid, valuable result — never pad.
4. **Fix — under the anti-race protocol.** Fixer agents author **DISJOINT files
   only, never build, never touch the ledger or shared seams**. The **orchestrator
   runs the per-component integration build + tests**, marks `Fix` only on green,
   reverts/defers anything that breaks it, and **commits per component**. (This is
   `sky-rust-backend:autonomous-swarm`'s protocol — reuse it.)

A small helper parses each swarm's `{file, …}` JSON and writes the cells (don't
re-improvise the table edit each run).

## Verification gates (a fix is ✅ only past these)

| Component | Gate (what it proves) |
|---|---|
| Rust runtime | `cargo build/test --features full` (compiles + unit-total) **AND** a feature-MINIMAL example build (catches `--features full`-only resolution) |
| Haskell codegen | `cabal build exe:sky` + build ≥1 example per shape on `--backend rust` (codegen emits compiling Rust) |
| Rust tools | `cargo build` per crate |
| Scripts | `bash -n` / `py_compile` / `node --check` + a functional smoke |
| Docs/prose | claims re-checked against the code they describe |

Build green = it compiles. Behavioural Go≡Rust parity is the CI sweep's job — say
which gate proved what; don't overclaim.

## Common mistakes

- **Letting fixer agents build.** They share one `CARGO_TARGET_DIR`/`.skycache` —
  parallel builds clobber + `resource busy`. Authors author; the orchestrator
  builds once per component.
- **Trusting a `--features full` green.** A fix that adds a crate dep to a
  shared/always-compiled module passes `--features full` but breaks a
  feature-minimal project (E0433). Always build a minimal example too.
- **Marking ✅ on "authored".** Only after the integration build is green.
- **Re-auditing everything every run.** Use **Last audited** + git diff; that's
  what makes it cheap enough to run often.
- **Padding `—` rows with invented findings.** Clean is a result.
- **One giant fix-swarm, one giant build.** Batch by component; build + commit
  per batch so a break is bisectable and progress is durable.

## Reference

Reuses `sky-rust-backend:autonomous-swarm` (anti-race protocol) and the project
boundary + build env in `runtime-rust/CLAUDE.md`. The deliverable lives at
`runtime-rust/docs/CODE-REVIEW.md`.
