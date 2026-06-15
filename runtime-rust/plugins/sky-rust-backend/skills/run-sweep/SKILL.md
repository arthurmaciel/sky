---
name: run-sweep
description: Run the Sky Rust-backend RUN sweep — build each runnable example on `--target rust` and actually RUN it (cli runs without panicking; server/live boots + serves HTTP via curl). Catches the runtime-regression class the build sweep misses (panics, dead servers). Use when the user asks to run the run sweep, smoke-test that the examples still run, or verify runtime behaviour after a runtime change. Siblings: sky-rust-backend:build-sweep (compiles), sky-rust-backend:web-sweep (browser round-trip), sky-rust-backend:perf-sweep (performance). Trigger: /sky-rust-backend:run-sweep.
---

# run-sweep

The **run** phase of Rust-backend verification. One **deterministic** script
builds each runnable example on `--target rust` and RUNS it — a cli must run
without panicking; a server/live must boot and serve HTTP (`curl GET / → 200`).
Catches the runtime-regression class a build sweep can't. For the browser
round-trip ("click is a no-op"), use **sky-rust-backend:web-sweep**. **Do NOT
re-decide the steps each time** — if a run reveals a better way, edit
`runtime-rust/scripts/run-sweep.sh`.

Runs apps but no perf timing → load-tolerant, **no close-the-apps reminder**.

## Workflow (every invocation)

1. **Run the script** (~25–40 min; background + wait):
   ```bash
   bash runtime-rust/scripts/run-sweep.sh
   ```
   Self-resolves repo + env, kills stray `sky lsp`/`sky doc`, then per example
   builds → runs → checks → reaps → cleans the build tree.

2. **Relay the verdict** — `N ran-OK · M failed · K skipped`, plus the
   `failures:` list (tagged `(build)` / `(panic)` / `(hang)` / `(noserve)`).
   Per-example logs under `~/.cache/sky/run-sweep/`.

3. **Improve the script if warranted** (real runtime regression to file, or a
   harness gap — new panic string, non-default port, shape mis-classification).

## What it does (per example)

- **Classify by shape** (grep): `tui`/`webview`/`fyne` → **SKIP** (need a
  TTY/window); else `cli`/`server`/`live`.
- **Build** (`sky build` + `cargo build`). Failure → `BUILD-FAIL`.
- **Run + smoke-check:** cli — 25 s timeout, FAIL on panic/hang; server/live —
  free `SKY_LIVE_PORT`/`PORT` + `SKY_CONSOLE_EMBED=off`, wait ≤15 s for
  `GET / → 200` (sniffing the "listening on :PORT" log), FAIL on panic/no-serve,
  then SIGTERM/SIGKILL.
- Reaps orphans and wipes `sky-out`/`.skycache`/`.skydeps` after.

## Example set

Curated runnable set (~24: cli/server/live). `RUST_RUN="a b c"` overrides.

## Baked-in gotchas

- PATH `/usr/local/go/bin` + `$HOME/.cargo/bin` + `sccache`;
  `CARGO_TARGET_DIR=$HOME/.cache/sky-rust-target`; `SKY_BIN=<repo>/sky-out/sky`;
  `SKY_CONSOLE_EMBED=off`. Never edit runtime files mid-run.

## Capture learnings (self-improving loop)

After this skill's work completes, record any **significant, verified,
generalizable** learning — a non-obvious pitfall, a deeper foundational insight,
or a secure/correct/sound optimization — to the **`## Agent learnings`** section
of `runtime-rust/CLAUDE.md`, so future agents improve. Obey that section's rules:
**only if secure, correct, and sound + verified**; **reconcile (update / dedupe /
prune), never blind-append**; **skip when nothing significant** — most runs add
nothing, and manufacturing an entry is worse than none.
