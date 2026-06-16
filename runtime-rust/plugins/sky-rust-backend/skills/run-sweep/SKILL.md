---
name: run-sweep
description: Run the Sky Rust-backend RUN sweep — build each in-scope example on `--target rust` and actually RUN it HEADLESSLY, dispatching per shape: cli runs without panicking; server/live boots + serves HTTP (and live/web examples drive a real browser ROUND-TRIP via web-verify.mjs — the "click is a no-op" gate, formerly the separate web sweep); tui runs under a pty; webview runs under xvfb. Catches the runtime-regression class the build sweep misses (panics, dead servers, dead clicks). Use when the user asks to run the run sweep, smoke-test that the examples still run, browser-verify the Sky.Live examples, or verify runtime behaviour after a runtime change. Siblings: sky-rust-backend:build-sweep (compiles), sky-rust-backend:perf-sweep (performance). Trigger: /sky-rust-backend:run-sweep.
---

# run-sweep

The **run** phase of Rust-backend verification. One **deterministic** script
builds each in-scope example on `--target rust` and RUNS it HEADLESSLY,
dispatching per shape — a cli must run without panicking; a server/live must boot
and serve HTTP; a **live/web** example additionally drives a real browser
round-trip (the "click is a no-op" gate — this **absorbed the old web sweep**);
a tui runs under a pty; a webview runs under xvfb. Catches the runtime-regression
class a build sweep can't. **Do NOT re-decide the steps each time** — if a run
reveals a better way, edit `runtime-rust/scripts/run-sweep.sh` (or the browser
driver `runtime-rust/scripts/web-verify.mjs`).

Runs apps but no perf timing → load-tolerant, **no close-the-apps reminder**.

## Workflow (every invocation)

1. **Run the script** (~25–40 min; background + wait):
   ```bash
   bash runtime-rust/scripts/run-sweep.sh
   ```
   Self-resolves repo + env, kills stray `sky lsp`/`sky doc`, then per example
   builds → runs → checks → reaps → cleans the build tree.

2. **Relay the verdict** — `N ran-OK · M failed · K skipped`, plus the
   `failures:` list (tagged `(build)` / `(panic)` / `(hang)` / `(noserve)` /
   `(web)` / `(notty)`). Per-example logs under `~/.cache/sky/run-sweep/`.

3. **Improve the script if warranted** (real runtime regression to file, or a
   harness gap — new panic string, non-default port, shape mis-classification).

## What it does (per example)

- **Classify by shape** (`example_shape`): `cli` / `server` / `live` / `tui` /
  `webview` / `fyne`.
- **Build** (`sky build` + `cargo build`). Failure → `BUILD-FAIL`.
- **Run + smoke-check, per shape:**
  - `cli` — 25 s timeout, FAIL on panic/hang.
  - `server` — free `SKY_LIVE_PORT`/`PORT` + `SKY_CONSOLE_EMBED=off`, wait ≤15 s
    for `GET / → 200` (sniffing the "listening on :PORT" log), FAIL on
    panic/no-serve, then SIGTERM/SIGKILL.
  - `live` — if web-drivable, the full **browser round-trip** via
    `web-verify.mjs` (scenario derived from the example name → falls back to
    `smoke`), FAIL on dead click / console error / panic; else treated as
    `server`. Degrades to the curl boot check if the browser stack
    (node/chromium/playwright) is absent.
  - `tui` — **pty smoke** via `script -qec "timeout 8 <bin>" /dev/null` (allocates
    a real terminal so the TUI doesn't bail "not a tty"); PASS on clean start/exit,
    FAIL on panic / "not a tty".
  - `webview` — **xvfb smoke** via `xvfb-run -a timeout 8 <bin>`; PASS on
    no-crash. **xvfb-run missing → SKIP** (`install xvfb to run headless`), NOT a
    failure.
  - `fyne` — won't occur (Go-FFI excluded); SKIP if it does.
- Reaps orphans and wipes `sky-out`/`.skycache`/`.skydeps` after.

## Example set

`run_set` (derived in `lib/examples.sh`): every example dir minus Go-FFI; nothing
excluded by shape. `RUST_RUN="a b c"` overrides.

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
