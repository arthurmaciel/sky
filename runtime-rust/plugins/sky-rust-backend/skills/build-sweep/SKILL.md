---
name: build-sweep
description: Run the Sky Rust-backend BUILD + Go≡Rust EQUIVALENCE sweep — `sky build --target rust` + `cargo build` over the largest example set, AND assert the Rust output matches Go per each example's equiv mode (stdout-diff cli / both-pass-scenario live / both-serve server / both-no-crash tui). Folds in the old equiv-sweep. Use when the user asks to run the build sweep, check that the examples still build on `--target rust`, verify Go≡Rust parity, or after a codegen/runtime change. Sibling phases: sky-rust-backend:run-sweep (runtime + live/web browser round-trip), sky-rust-backend:perf-sweep (performance). Trigger: /sky-rust-backend:build-sweep.
---

# build-sweep

The **build + equivalence** phase of Rust-backend verification (run / perf are
sibling skills). One **deterministic** script — `runtime-rust/scripts/build-sweep.sh`
— bins the largest in-scope set (`build_set` from `lib/examples.sh`: every
candidate example minus Go-FFI) by how the Rust backend builds AND how it matches
Go. A green Rust build is necessary but NOT sufficient — the cornerstone gate is
that the Rust output is **equivalent to Go**. **Do NOT re-decide the steps each
time** — the only judgement call is afterward: if a run reveals a better way, edit
`runtime-rust/scripts/build-sweep.sh`, `lib/checks.sh`, or the equiv manifest.

Build-level + equivalence, no perf timing → load-tolerant, **no close-the-apps
reminder**.

## Workflow (every invocation)

1. **Run the script** (~20–35 min; background + wait). `go` is required (the
   comparison side):
   ```bash
   bash runtime-rust/scripts/build-sweep.sh
   ```
   It self-resolves repo + env, kills stray `sky lsp`/`sky doc` (they hold
   `.skycache` locks → the misleading `resource busy` class), runs the sweep,
   prints the verdict + per-mode equiv counts + scoreboard path.

2. **Relay the verdict** — `PASS` (all in-scope examples build AND match Go per
   their mode) or `FAIL` with the failures. The verdict line reports the equiv
   strength per mode (`stdout=N scenario=N serve=N pty=N · build-only=N`).

3. **Improve if warranted** — a real `DIFFER` is a REAL Go≡Rust divergence to
   file (NOT to paper over); if it's a harness artefact (an un-normalized
   timestamp/id/port leaking into a stdout diff) fix the normalization in
   `lib/checks.sh`/the `norm` helper. Classification drift → fix the manifest.

## The equiv MODE manifest

`build_set` per example, by mode from `runtime-rust/scripts/equiv-classification.tsv`
(the equiv-mode SSOT, keyed by build_set basename). Each mode names exactly what
is proven:

| Mode | Shape | How | Scoreboard bin (what's proven) |
|---|---|---|---|
| `stdout` | cli | build Go + Rust, run BOTH (`exercise_cli`), DIFF normalized stdout | `equiv-stdout` — **byte-identical** (strongest) |
| `scenario` | live | run the SAME web-verify browser scenario against BOTH binaries | `equiv-scenario` — both pass the scenario (**APP-behaviour** parity; NOT a raw-DOM diff — robust to the by-design console in-process(Go) vs cross-process(Rust)) |
| `serve` | server | `exercise_server` BOTH | `equiv-serve` — both **boot + serve** HTTP (NOT response-body identical) |
| `pty` | tui | `exercise_tui` BOTH | `equiv-pty` — both **drive the TUI runtime without panic** (NOT cell-identical rendering) |
| `none` | webview / Go-FFI / no-entry / non-deterministic cli | Rust build only | `builds` — genuinely incomparable |

**Honesty bins.** The scoreboard NEVER over-reads "equiv": `equiv-stdout` is
byte-identical; `equiv-scenario` is "both pass the scenario"; `equiv-serve` is
"both boot"; `equiv-pty` is "both no-crash"; `builds` is build-only. Verdict
FAILS on any `DIFFER` (one backend differs/fails where the other passes),
`EQUIV-FAIL` (a scenario both backends fail), `*-fails` / `sky-CRASH`, or
`UNCLASSIFIED`.

## The shared `lib/checks.sh`

The per-shape "exercise a binary" logic (`exercise_cli` / `exercise_server` /
`exercise_live` / `exercise_tui` / `exercise_webview` + `http_responds` /
`free_port` / `scenario_for` / `reap` / `$PANIC_RE` / browser-stack probe) lives
in `lib/checks.sh` — the SAME definitions run-sweep uses. build-sweep runs them
against BOTH backends' binaries and compares; run-sweep runs them against the
Rust binary only. One definition of "did the binary work?", no drift.

## Coverage gate (forced classification)

Every `examples/` top-level dir AND every `build_set` member MUST have a mode in
the manifest. An unclassified example FAILS the verdict — "Go parity maintained"
cannot be claimed until it's classified. When an example lands, classify it with
its natural mode (derive from `example_shape`) + a reason.

## SKY_SWEEP_NO_EQUIV — the fast build-only hatch

`SKY_SWEEP_NO_EQUIV=1 bash runtime-rust/scripts/build-sweep.sh` skips the Go
build + equivalence entirely (every example bins `builds` / `*-fails`), needs no
`go`, and behaves like the pre-equiv build-only sweep. Use it for a fast
compile-only check; the default (equivalence on) is the real parity gate.

## Baked-in gotchas

- PATH: `$HOME/.cargo/bin:/usr/local/go/bin:…`;
  `CARGO_TARGET_DIR=$HOME/.cache/sky-rust-target`; `sccache`; `SKY_BIN=<repo>/sky-out/sky`.
- `go` IS required by default (the equivalence comparison side); set
  `SKY_SWEEP_NO_EQUIV=1` to drop it.
- Go-FFI examples are ABSENT from `build_set` and classified `none` in the
  manifest (they don't build on `--target rust` — nothing to compare).
- Never edit runtime files while this runs (concurrent copy → false E0433).

## Capture learnings (self-improving loop)

After this skill's work completes, record any **significant, verified,
generalizable** learning — a non-obvious pitfall, a deeper foundational insight,
or a secure/correct/sound optimization — to the **`## Agent learnings`** section
of `runtime-rust/CLAUDE.md`, so future agents improve. Obey that section's rules:
**only if secure, correct, and sound + verified**; **reconcile (update / dedupe /
prune), never blind-append**; **skip when nothing significant** — most runs add
nothing, and manufacturing an entry is worse than none.
