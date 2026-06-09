# Rust-backend floor stabilization — design

**Date:** 2026-06-09
**Branch:** `feat/runtime-rust`
**Status:** approved design, ready for implementation plan

## Purpose

The first slice of the larger "run all `examples/` on the Rust backend" arc.
Today the Sky compiler **crashes on `--target rust`** for even
`01-hello-world` — a non-exhaustive `case` in `ModuleEmitter.hs`, part of an
in-flight refactor that splits the monolithic `src/Sky/Generate/Rust/Builder.hs`
(4,312 lines) into a `Builder/` package (~5,812 lines across 10 modules) and
additionally changes output from a flat `main.rs` to **per-module files**
(`main.rs` + `sky_core_string.rs` + …).

This slice **stabilizes that refactor** and restores a measured green floor.
It does *not* add new language/runtime capability (parametric-record generics,
Std.Ui, Tui, Webview, PubSub, Console) — those are later slices that all depend
on this floor existing first.

## Goal (definition of done)

1. **Crash gone** — the `ModuleEmitter` non-exhaustive `case` is fixed.
2. **Equivalence** — the new `Builder/` emitter is proven equivalent to the
   known-good monolith on every example the monolith supports.
3. **Clippy green** — `clippy -D warnings` on the runtime crate passes
   (root-cause fixes, no blanket `#[allow]`).
4. **Measurement** — an all-41 `--target rust` sweep harness exists, categorizes
   every example, and is wired into `verify-rust-target.sh` + CI.

## Background facts (verified)

- HEAD (`4349a191`) **still is the monolith**: the `Builder/` split, the gutting
  of `Builder.hs` (to a 27-line shim), and the `sky-compiler.cabal` edits that
  wire in the `Builder/` modules are all **uncommitted** (untracked dir +
  modified-but-uncommitted files). So `git show HEAD:…Builder.hs` is the working
  4,312-line monolith containing `exprToRustInner` (at :2265).
- HEAD also carries the **current runtime crate** (this session's Candidate A/B
  commits). So a clean worktree at HEAD = **monolith emitter + current runtime**.
- The clippy gate is **already red** independent of the refactor: ~47 lints from
  the clippy-1.92 bump in runtime files the refactor never touched
  (`decimal.rs` clone-on-Copy ×12, `time.rs` `////` doc-comments ×12,
  `math.rs` PI-approx ×3, `char_kernel.rs`, `auth.rs`, `basics.rs`, …).
- `verify-rust-target.sh` gates only **6 examples** and currently aborts at the
  clippy step (`set -e`), so the example builds never run.

## The equivalence relation

"Strict equivalence to the monolith" cannot mean byte-identical output: the WIP
**intends** to emit per-module files where the monolith emits one flat `main.rs`.
So equivalence is defined as a relation blind to the intended restructuring and
strict on everything else. For every example in the equivalence set, the WIP must
satisfy **all three** parts:

1. **Behavioral equivalence — the objective hard gate.** Generate with both
   emitters; `cargo build` both; `cargo run` both under a per-example **input
   battery** (not a single happy-path run); require **byte-identical exit code +
   stdout/stderr** after canonicalizing known-volatile output (see below).
   `00-standard-libs` (131 assertions) and `07-todo-cli` (full CRUD) make this a
   hard runtime check.
2. **Structural equivalence — strict review.** `rustfmt` both; concatenate the
   WIP's emitted modules; strip the `pub mod` / `use` split-plumbing; item-level
   diff against the monolith's `main.rs`. **Every residual difference must be
   explainable by the intended flat→split restructuring** (path qualifications,
   module declarations). Anything else is a regression. (This is a review gate,
   not a byte-zero auto-gate, because a flat→split refactor legitimately
   re-qualifies paths — pretending otherwise would be dishonest.)
3. **Clippy parity.** The WIP's generated Rust passes `clippy -D warnings`
   wherever the monolith's did.

"Stricter" lives in requiring all three simultaneously, and in the behavioral
gate using input batteries rather than one run.

## Scope — the example partition

Determined **empirically** by building each `examples/[0-9]*` (+ `simple` /
`test_pkg`) with the reference monolith binary, not from this estimate.

- **Equivalence set** (held to all three relation parts) = examples the HEAD
  monolith builds + runs today. Estimated: `00, 01, 04, 05, 07, 09, 10, 14, 15,
  18, 20, 28, 30, 32, 33, simple, test_pkg` (CLI / Http.Server / Stream / WS /
  Sky.Live-without-Std.Ui). Confirmed at harness-build time.
- **Out of scope** (sweep-recorded only, no monolith reference, belong to later
  slices): `Std.Ui` (19, 24, 25, 26, 37), `Tui` (21–23), `Webview` (29),
  multi-backend composites (31, 38), `Fyne` (11, Go-only), `Go-stdlib` (02,
  Go-only), `JSON-pipeline` (06), `PubSub`/`Cache` composites (27, 34, 36).
- **Uncertain — assigned by the empirical pass** (`03, 12, 13, 16, 17, 35`):
  TEA-external, skyvote, skyshop, skychess, skymon, composite-generics. Each
  joins the equivalence set if the monolith builds + runs it, else the
  out-of-scope set. The empirical pass is authoritative and assigns **every** one
  of the 41; the two lists above are estimates, not the final partition.

## Workstreams

### W1 — Refactor equivalence (core)

Drive the WIP `Builder/` emitter to satisfy the three-part relation on the
equivalence set.

- **W1.0 — crash fix.** Diff `sky-wip`'s `ModuleEmitter.exprToRustInner` against
  the monolith's `exprToRustInner` (`git show HEAD:…Builder.hs`); restore the
  dropped/mis-guarded arm or lost catch-all. Regression guard: the crashing
  example must now generate + build.
- **W1.1…n — fix-forward.** For each divergence the harness bins as a failure,
  take a targeted function-level diff against the monolith, locate the
  regression, fix it in the `Builder/` source, rebuild `sky-wip`, re-run the
  harness for that example. Repeat until the set is fully green.

### W2 — Clippy floor (orthogonal)

Unbreak `clippy -D warnings` on the runtime crate — the ~47 pre-existing
clippy-1.92 lints. **Root-cause fixes only** (the discipline from this session:
remove genuinely-unused code, fix the actual issue; `#[allow]` only when the lint
is a false positive against a hard requirement, with a comment). After each fix,
re-run `cargo test --all-features` (must stay 202/0 — fixes must not change
behavior). Runs independently of W1.

### W3 — All-41 sweep harness (scoreboard)

A script that attempts every example on `--target rust` and bins each into:
`equivalent` · `builds+runs` · `builds-only` · `cargo-build-fails` ·
`sky-build-crashes` · `out-of-scope`. Converts the Part-2 estimates into measured
truth; becomes the gate every later slice depends on. Wired into
`verify-rust-target.sh` (augmenting the 6-example step) with CI parity.

## Harness design (units)

Three independently-testable units.

- **Unit 1 — `sky-ref` (reference binary).** `git worktree` at HEAD +
  `cabal build exe:sky`. Monolith emitter + current runtime crate, isolating the
  emitter as the only variable. Worktree per `using-git-worktrees`; removed after
  per the CLAUDE.md disk-hygiene rule (~1.5 GB `.skycache`/`sky-out` each).
- **Unit 2 — `sky-wip` (working binary).** `cabal build exe:sky` in the main
  tree (the `Builder/` split). Rebuilt after each fix.
- **Unit 3 — differential runner.** Per equivalence-set example: generate with
  both → structural normalize + diff → `cargo build` both → `cargo run` both
  under the input battery → canonicalize volatile output → byte-compare →
  clippy parity → bin + report. Includes the **volatile-output canonicalizer**
  (seed `Random`, pin the clock where examples allow, mask uuids/timestamps/
  row-ids before comparison).

## Sequence

1. **W1.0** crash fix — the gate; unblocks all generation.
2. **W3** sweep harness — built next, so we have the scoreboard to measure W1 and
   to discover the true equivalence set empirically.
3. **W1.1…n** equivalence loop — drive the set to full three-part equivalence.
4. **W2** clippy — independent; slotted last so it doesn't interleave with
   codegen debugging.

## Edge cases

- **WIP builds but monolith doesn't** → bonus, recorded, never a failure (outside
  the equivalence set).
- **Neither builds** → out-of-scope, sweep-recorded for a later slice.
- **Non-deterministic output** → pinned/masked by the Unit-3 canonicalizer; a
  flaky behavioral diff is a canonicalizer bug, not an equivalence failure.
- **A clippy fix that changes runtime behavior** → caught by re-running
  `cargo test --all-features` after each W2 fix.

## Done-criteria (how we know the floor is green)

- **W1:** every equivalence-set example passes all three relation parts; the
  crash example has a build regression guard.
- **W2:** `cargo clippy --all-targets --all-features -- -D warnings` exits 0
  **and** `cargo test --all-features` still 202/0.
- **W3:** the sweep emits the scoreboard and is wired into
  `verify-rust-target.sh` + CI.
- **Floor green:** `verify-rust-target.sh` passes end-to-end (check → clippy →
  test → sweep) **and** the equivalence harness reports full equivalence on the
  set.

## Persistence

- W3 sweep is **permanent** — the scoreboard every later slice gates on.
- The Unit-3 equivalence harness **persists** as the regression guard for future
  codegen refactors — closing exactly the gap that let this WIP crash slip in.

## Explicitly out of scope (later slices)

Parametric-record generics, the Std.Ui layout engine on Rust, the Sky.Tui and
Sky.Webview backends, the PubSub/Broker, the Console + observability federation,
the JSON decode-pipeline fix, and `Std.Cache`. Each is its own spec → plan →
implementation cycle, gated on this floor.

## Constraints (from CLAUDE.md / cross-backend rules)

- Never change shared compiler code in a way that could break the Go backend; new
  Rust work stays behind `TargetRust ->` branches. The fixes here are confined to
  `src/Sky/Generate/Rust/Builder/` and `runtime-rust/`.
- Bound every long-running build/test under `timeout`.
- Clean up worktrees + Go/cargo caches after the sweep (disk hygiene).
- Commit messages carry no co-author line (project rule).
