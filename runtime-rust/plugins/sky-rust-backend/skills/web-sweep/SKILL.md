---
name: web-sweep
description: Run the Sky Rust-backend WEB sweep — build each live/web example on `--target rust` and drive it through a REAL headless browser (system chromium), replaying the repo's maintained per-example scenario and hard-failing the "click is a no-op" class (a scenario click that never POSTs /_sky/event). Use when the user asks to run the web sweep, browser-verify the Sky.Live examples, or check that interactive UI still round-trips after a runtime/codegen change. Siblings: sky-rust-backend:build-sweep, sky-rust-backend:run-sweep (curl boot), sky-rust-backend:perf-sweep. Trigger: /sky-rust-backend:web-sweep.
---

# web-sweep

The **web** (browser round-trip) phase — the depth **sky-rust-backend:run-sweep**
skips (that one is a `curl GET / → 200` boot check). One **deterministic** script
builds each live/web example on `--target rust`, launches a real headless
browser, replays the repo's maintained scenario, and **hard-fails the "click is
a no-op" class** (a click that never POSTs `/_sky/event`). **Do NOT re-decide the
steps** — if a run reveals a better way, edit `runtime-rust/scripts/web-sweep.sh`
(or `web-verify.mjs`).

Boots servers + a browser but no perf timing → load-tolerant, **no
close-the-apps reminder**.

## Workflow (every invocation)

1. **Run the script** (~25–40 min; background + wait):
   ```bash
   bash runtime-rust/scripts/web-sweep.sh
   ```
   Self-resolves repo + env (node under `~/.nvm`, system chromium); per example
   builds → spawns the Rust binary → drives the browser scenario → reaps →
   cleans.

2. **Relay the verdict** — `N pass · M fail · K skipped`, plus the `failures:`
   list (tagged `(build)` / `(web)`). A `(web)` reason is quoted from the driver
   (`server failed to listen` / `console errors:…` / `ZERO sky-event attributes`
   / `server panics:…`). Per-example logs under `~/.cache/sky/web-sweep/`;
   screenshots under `.skycache/verify-rust/<ex>/`.

3. **Improve the script if warranted** (real interactive regression, or a
   harness gap — a new scenario, a chromium-launch quirk, a flake).

## What it does (per example)

- **Build** on `--target rust`. Failure → `BUILD-FAIL`.
- **Drive** via `runtime-rust/scripts/web-verify.mjs` (fork-local — the shared
  `scripts/verify-live-app.mjs` is a Go-backend script, left untouched): spawns
  the **Rust** binary on a free port, launches **system chromium**
  (`--no-sandbox`, no bundled Playwright browser here), loads
  (`domcontentloaded`, never `networkidle` — SSE never goes idle), imports the
  repo's `scripts/verify-scenarios.mjs` and runs the named scenario.
- **PASS** = listened + scenario ran + ≥1 `/_sky/event` round-trip where the
  scenario asserts one + interactive HTML carries `sky-*` attrs + no real console
  error + no Rust panic in the server log.

## Example set

Live/web examples with a maintained scenario in `scripts/verify-scenarios.mjs`
that ALSO build on `--target rust`: `09-live-counter · 10-live-component ·
12-skyvote · 16-skychess · 17-skymon · 18-job-queue · 19-skyforum`. Same scenario
keys the Go-backend `verify-all-web.sh` drives — backend-identical wire protocol.
`RUST_WEB="09-live-counter:live-counter 12-skyvote:skyvote"` overrides.

## Baked-in gotchas

- node from newest `~/.nvm/versions/node/*/bin`; `SKY_CHROMIUM=/usr/bin/chromium`.
- **System chromium + `--no-sandbox`** (no bundled Playwright browser).
- `waitUntil:'domcontentloaded'`, never `networkidle` (SSE hangs it).
- `CARGO_TARGET_DIR=$HOME/.cache/sky-rust-target`; `SKY_CONSOLE_EMBED=off`. Never
  edit runtime files mid-run.

## Capture learnings (self-improving loop)

After this skill's work completes, record any **significant, verified,
generalizable** learning — a non-obvious pitfall, a deeper foundational insight,
or a secure/correct/sound optimization — to the **`## Agent learnings`** section
of `runtime-rust/CLAUDE.md`, so future agents improve. Obey that section's rules:
**only if secure, correct, and sound + verified**; **reconcile (update / dedupe /
prune), never blind-append**; **skip when nothing significant** — most runs add
nothing, and manufacturing an entry is worse than none.
