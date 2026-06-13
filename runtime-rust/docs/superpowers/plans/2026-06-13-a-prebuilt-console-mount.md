# A — Pre-built console child + reverse-proxy — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans (inline)
> or subagent-driven-development. Build env each task:
> `export PATH="$HOME/.ghcup/bin:$HOME/.cargo/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin"`;
> `export CARGO_TARGET_DIR=$HOME/.cache/sky-rust-target RUSTC_WRAPPER=sccache`.
> `sky-out/sky` is a SYMLINK (cabal build refreshes it; NEVER --install-method=copy).
> Runtime (`runtime-rust/src`) edits need no cabal rebuild; codegen
> (`src/Sky/**.hs`, `app/Main.hs`) edits DO. Test runtime with `cargo build --features full`.

**Goal:** A Sky.Live / Sky.Http.Server app on `--target rust` auto-mounts the
**bundled console** (the real `Sky.Live` dashboard, now compiling thanks to S0/S1)
at `/_sky/console/*` by spawning a **pre-built** console child binary and reverse-
proxying to it — replacing the in-process `console.rs` plain-HTML shell.

**Architecture (DECIDED — user 2026-06-13):** pre-built separate process + proxy.
The console binary is compiled at the user's `sky build` time (shared cache, once
per sky version — NEVER a runtime build, which is the only reason Go dropped
subprocess). Rationale: `runtime-rust/README.md` §"Rust vs Go — divergent
strategies". At runtime the parent `exec`s the cached binary and proxies. Keep
`console.rs` as the no-spawn fallback.

```
sky build (user app, Live)                         runtime (parent app)
  ├─ build user app (cargo)                           ├─ MountEmbeddedConsole-equiv:
  └─ A1: if Live && console binary not cached for      │   spawn $CACHE/sky-console
      this sky version → generate console Rust          │     env: SKY_LIVE_PORT=<child>,
      project (embedded sky-bundled/console) +          │          SKY_CONSOLE_HUB_DB=<parent SKY_CONSOLE_DB_PATH>,
      cargo build → $CACHE/<sky-ver>/sky-console        │          SKY_LIVE_BASE_PATH=/_sky/console
                                                         │   reverse-proxy /_sky/console/* → 127.0.0.1:<child>
                                                         └─ child reads spill via S1 hub kernels (D wrote it)
```

## Contracts / facts (gathered)

- **Cargo build site:** `app/Main.hs:1703-1704` runs `cargo build --manifest-path
  <rustDir>/Cargo.toml` after `generateRustProject` (Project.hs). A1 hooks here.
- **Console source:** `sky-bundled/console/` (TH-embedded). Builds clean on
  `--target rust` today (S0/S1). `[live] port = 8025`, session store = memory.
- **Console reads:** `SKY_CONSOLE_HUB_DB` (→ `hubStore`); else `SKY_PARENT_URL` (→
  `httpStore`); else standalone mock. So set the child's `SKY_CONSOLE_HUB_DB`.
- **Spill path:** D writes `SKY_CONSOLE_DB_PATH` (parent). A wires child
  `SKY_CONSOLE_HUB_DB` = that path. WAL + child reads `mode=rw` (S1 open_spill).
- **Parent mount point:** `live/mod.rs` builds the axum router (~line 800-825);
  `console.rs` currently mounts `/_sky/console*` in-process. Replace with proxy.
- **Production gate / env:** mirror Go `MountEmbeddedConsole` (console.go:257):
  skip when `SKY_LIVE_BASE_PATH` set (sub-app), `SKY_CONSOLE_EMBED=off`,
  `SKY_CONSOLE_AUTH=off`, or production-without-`SKY_ADMIN_TOKEN`.
- **Lifecycle:** kill the child on parent shutdown (Go dropped `ShutdownSubApps`
  because it went in-process; Rust needs it back — track the child PID, kill on
  SIGTERM/drop).

## File structure

- **New** `runtime-rust/src/sky_runtime/live/console_proxy.rs` (feature `live`):
  child spawn + lifecycle (PID tracking, kill-on-shutdown) + an axum reverse-proxy
  handler for `/_sky/console/*` → `http://127.0.0.1:<child_port>`. Uses `reqwest`
  (already a `live` dep) to forward; streams the body; copies status + headers.
- **Modify** `runtime-rust/src/sky_runtime/live/mod.rs`: at boot, after
  `enable_from_env().await` (D), call `console_proxy::maybe_spawn_and_mount(&mut
  router)` — spawn the cached console binary (when present + gate passes) and mount
  the proxy; else fall through to the existing in-process `console.rs` mount.
- **Modify** `runtime-rust/src/sky_runtime/live/console.rs`: keep as the fallback
  (no-spawn / binary-absent path). Document the precedence.
- **Modify** `app/Main.hs` (~1704) + a new `src/Sky/Build/Rust/Console.hs`:
  A1 — after the user app builds, if it's a Live program and
  `$CACHE/<sky-ver>/sky-console` is absent, generate the console Rust project from
  the embedded console source + `cargo build` it into the cache. Skip on cache hit.
- **Cache path:** `~/.cache/sky/rust-console/<sky-version>/sky-console`
  (override `SKY_CONSOLE_BIN`). Version-keyed so a sky upgrade rebuilds once.

## Tasks

### Task 1: console_proxy.rs — spawn + lifecycle (no proxy yet)

**Files:** create `live/console_proxy.rs`; modify `live/mod.rs`.

- [ ] `spawn_console(child_port: u16, hub_db: &str) -> Option<Child>`: resolve the
  binary (`SKY_CONSOLE_BIN` env, else `~/.cache/sky/rust-console/<ver>/sky-console`);
  `None` if absent (→ fallback). `Command::new(bin).env("SKY_LIVE_PORT", …)
  .env("SKY_CONSOLE_HUB_DB", hub_db).env("SKY_LIVE_BASE_PATH", "/_sky/console")
  .spawn()`. Track the `Child` in a `static Mutex<Option<Child>>`.
- [ ] `shutdown_console()`: kill the tracked child; wire to the parent's
  SIGTERM/drop path (mirror the existing graceful-shutdown hook if any).
- [ ] `gate_allows() -> bool`: mirror Go `MountEmbeddedConsole` skip conditions.
- [ ] `cargo build --features full`; unit test: gate logic (env permutations).
- [ ] Commit.

### Task 2 PREREQUISITE (discovered 2026-06-13): wire `SKY_LIVE_BASE_PATH` through the Rust Live server

The proxy pass-through only works if the spawned child prefixes its own URLs under
`/_sky/console`. The Rust Live server HAS page-level base support
(`render_page_full(base)` → `<meta sky-base>` + `window.__SKY_BASE`, `live/mod.rs:113`)
but does NOT currently read `SKY_LIVE_BASE_PATH` into `base` — it's passed `""`
everywhere. So before/with Task 2:
- Read `SKY_LIVE_BASE_PATH` at Live boot; thread it into `render_page_full`'s `base`
  so the child's inlined JS prefixes `/_sky/event` / `/_sky/sse` with the base.
- Decide the proxy convention: pass-through (`/_sky/console/X` → child `/_sky/console/X`,
  child serves under the prefix) vs strip (`→ child /X`, child serves at root +
  base only for generated links). Go uses base-for-links + the child served behind
  the proxy at the base path. Match whichever the Rust child's router actually does;
  verify `/_sky/console/_event` + `/_sky/console/_sse` round-trip.
- This is the intricate piece — do it deliberately, with an e2e (page load + an
  event POST + an SSE patch all through the proxy), not by guesswork.

### Task 2: console_proxy.rs — reverse-proxy handler

**Files:** `live/console_proxy.rs`; `live/mod.rs`.

- [ ] An axum fallback handler for `/_sky/console` + `/_sky/console/*path`: forward
  the request to `http://127.0.0.1:<child_port>/_sky/console/<path>` via `reqwest`
  (method, headers minus hop-by-hop, body), return the child's status + headers +
  streamed body. SSE (`/_sky/console/_sse`) must stream (no buffering).
- [ ] Health: a bounded readiness wait after spawn (poll the child port, ~8 s
  cap) before declaring the proxy live; on timeout, fall back to in-process.
- [ ] `maybe_spawn_and_mount(router) -> router`: gate → spawn → readiness → mount
  proxy routes; else return router unchanged (caller mounts in-process console).
- [ ] `cargo build --features full`; unit test: proxy forwards a stubbed upstream
  (spin a tiny axum echo on a port, assert status/body round-trip).
- [ ] Commit.

### Task 3: wire into Live boot + precedence over console.rs

**Files:** `live/mod.rs`.

- [ ] After `enable_from_env().await`, build the proxy mount via
  `maybe_spawn_and_mount`; only mount the in-process `console.rs` routes when the
  proxy didn't take. Keep the production/auth gate single-sourced.
- [ ] `cargo build --features full`; full lib suite green; clippy clean.
- [ ] Commit.

### Task 4 (A1): build the console at sky-build-time into the shared cache

**Files:** `app/Main.hs` (~1704), new `src/Sky/Build/Rust/Console.hs`.

- [ ] After the user-app `cargo build` succeeds AND the program is a Live/Http
  app: compute `cacheBin = ~/.cache/sky/rust-console/<sky-ver>/sky-console`. If it
  exists, skip. Else: materialise the embedded `sky-bundled/console` source to a
  temp dir, run the Sky→Rust pipeline (`generateRustProject`) on it, `cargo build`
  into the cache (shared `CARGO_TARGET_DIR`), copy the binary to `cacheBin`.
- [ ] Guard: only build once (lock file / atomic rename). Never at runtime. Log
  `[sky] building bundled console (first build for sky <ver>)…` once.
- [ ] `cabal build exe:sky`; build `examples/09-live-counter --target rust` →
  cache populated; second build → cache hit (no rebuild).
- [ ] Commit.

### Task 5: end-to-end acceptance + sweep + docs

- [ ] E2E: build + run a Live app with `SKY_CONSOLE_DB_PATH=/tmp/c.db`; hit it to
  generate telemetry; `curl /_sky/console` → 200, `<title>Sky Console</title>`,
  `X-Sky-Console-Mode` (or equiv) shows proxy; the Logs tab renders the spill rows
  (D→S1→A full loop). Bounded; kill the child + parent after.
- [ ] `scripts/rust-sweep.sh` 27/27 in-scope green (the console build is gated to
  Live programs; non-Live unaffected).
- [ ] Update epic spec (A DONE), README verified-examples, memory.
- [ ] Commit.

## Invariants / risks

- **No runtime build** — A1 builds at `sky build` time only; runtime is bare
  `exec`. The cache is version-keyed so an upgrade rebuilds once.
- **Fallback preserved** — binary absent / spawn fails / readiness times out →
  in-process `console.rs` still serves. No regression for apps that can't spawn.
- **No panic vectors** — spawn/proxy errors degrade to fallback + structured warn.
- **Lifecycle** — the child MUST die with the parent (track PID, kill on
  shutdown/drop) — Go's `ShutdownSubApps` equivalent, which Go deleted when it went
  in-process. Avoid the process-tree leak Go's `0d738a1c` once fixed.
- **A1 build cost** — first Live build per sky version pays the console build
  (~30-60 s once); cache hit after. Acceptable (build-time, not runtime).
- **SSE** — `/_sky/console/_sse` must stream through the proxy (no buffering), or
  the console's live updates stall.
