---
name: build-sweep
description: Run the Sky Rust-backend BUILD sweep — `sky build --target rust` + `cargo build` over the largest example set, reporting any in-scope build failures. Use when the user asks to run the build sweep, check that the examples still build on `--target rust`, or after a codegen/runtime change that could break builds. Sibling phases: sky-rust-backend:run-sweep (runtime — also drives the live/web browser round-trip), sky-rust-backend:perf-sweep (performance). Trigger: /sky-rust-backend:build-sweep.
---

# build-sweep

The **build** phase of Rust-backend verification (run / web / perf are sibling
skills). One **deterministic** script wraps the repo's `runtime-rust/scripts/rust-sweep.sh`
(largest set: `examples/[0-9]*` + `simple` + `test_pkg`) with the env gotchas
and a clean in-scope-failure report. **Do NOT re-decide the steps each time** —
the only judgement call is afterward: if a run reveals a better way, edit
`runtime-rust/scripts/build-sweep.sh` (or `runtime-rust/scripts/rust-sweep.sh`).

Build-level only and machine-load-insensitive → **no close-the-apps reminder**.

## Workflow (every invocation)

1. **Run the script** (~10–15 min; run in the background and wait):
   ```bash
   bash runtime-rust/scripts/build-sweep.sh
   ```
   It self-resolves repo + env, kills stray `sky lsp`/`sky doc` (they hold
   `.skycache` locks → the misleading `resource busy` class), runs the sweep,
   prints the verdict + scoreboard path.

2. **Relay the verdict** — `PASS` (all in-scope examples build) or `FAIL` with
   the in-scope failures. Full scoreboard at the printed `scoreboard=` path.

3. **Improve the script if warranted** (new gotcha / real build regression /
   classification drift) — fix it in the script, never improvise.

## What it does

- `SKY_CONSOLE_PREBUILD=off runtime-rust/scripts/rust-sweep.sh` — every `examples/[0-9]*` +
  `simple` + `test_pkg` gets `sky build --target rust` then `cargo build`; binned
  `builds` / `sky-build-fails` / `cargo-fails` / `sky-CRASH`, `(out-of-scope)`
  appended for documented exclusions.
- The verdict counts **in-scope** failures only (a fail line NOT tagged
  `(out-of-scope)`).

## Baked-in gotchas

- PATH: `$HOME/.ghcup/bin:$HOME/.cargo/bin:/usr/local/go/bin:…`;
  `CARGO_TARGET_DIR=$HOME/.cache/sky-rust-target`; `sccache`; `SKY_BIN=<repo>/sky-out/sky`.
- `--target rust` ignores `[go.dependencies]`, so `go` is NOT required.
- Never edit runtime files while this runs (concurrent copy → false E0433).

## Capture learnings (self-improving loop)

After this skill's work completes, record any **significant, verified,
generalizable** learning — a non-obvious pitfall, a deeper foundational insight,
or a secure/correct/sound optimization — to the **`## Agent learnings`** section
of `runtime-rust/CLAUDE.md`, so future agents improve. Obey that section's rules:
**only if secure, correct, and sound + verified**; **reconcile (update / dedupe /
prune), never blind-append**; **skip when nothing significant** — most runs add
nothing, and manufacturing an entry is worse than none.
