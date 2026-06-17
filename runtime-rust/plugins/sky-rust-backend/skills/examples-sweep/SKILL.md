---
name: examples-sweep
description: Run the Sky Rust-backend EXAMPLES sweep — the cornerstone correctness gate. ONE deterministic pass that BUILDS each in-scope example on `--target rust`, RUNS it headless per shape, AND asserts the Rust output matches the Go reference per the example's equiv mode, emitting a per-example BUILD·RUN·EQUIV table. Replaces the old build-sweep + run-sweep (folded into one). Use when the user asks to run the examples sweep, verify the examples still build + run on `--target rust`, check Go≡Rust parity, or after a codegen/runtime change. Siblings: sky-rust-backend:examples-perf-sweep (performance). Night-gated 22:00–08:00 America/Sao_Paulo. Trigger: /sky-rust-backend:examples-sweep.
---

# examples-sweep

The **cornerstone** of the Rust-backend dev cycle: one deterministic script —
`runtime-rust/scripts/examples-sweep.sh` — that for every in-scope example
(`build_set` from `lib/examples.sh`: every candidate dir minus Go-FFI) does
**three** things and emits **one** table row:

| Column | What | Cells |
|---|---|---|
| **BUILD** | `sky build --target rust` + `cargo build` | `ok` · `sky-fail` · `cargo-fail` |
| **RUN** | run the Rust binary headless, per `example_shape` (via `exercise_*` in `lib/checks.sh`) | `ok` · `panic` · `hang` · `noserve` · `notty` · `skip` |
| **EQUIV** | build the Go reference + compare to Rust per the DERIVED equiv mode | `equiv-stdout` · `equiv-body N` · `equiv-serve` · `equiv-scenario` · `equiv-pty` · `n/a` · `DIFFER` · `go-ref-broken` |

A green Rust build is necessary but **NOT sufficient** — RUN catches the
runtime-regression class (panic / dead server / dead click), EQUIV asserts the
Rust output **matches Go**. **Do NOT re-decide the steps** — if a run reveals a
better way, edit `examples-sweep.sh`, `lib/checks.sh`, or the overrides manifest.

This folds the former **build-sweep** (build + equiv) and **run-sweep**
(run + browser round-trip) into a single pass. The shared per-shape "did the
binary work?" logic stays the SINGLE SOURCE OF TRUTH in `lib/checks.sh`.

## Principles

Strict order from `README.md` (top): **security > correctness > soundness >
efficiency > completeness > readability** (a lower never overrides a higher).
This harness serves **correctness** — it must never label `equiv` what is only
"both boot", and never hide a real divergence. A `DIFFER` is reported precisely,
not papered over.

## Verdict

- **GREEN row** = BUILD `ok` AND RUN ∈ {`ok`, `skip`} AND EQUIV ∈ {`equiv-*`,
  `n/a`, `go-ref-broken`}.
- **RED row** = any `sky-fail` / `cargo-fail` / `panic` / `hang` / `noserve` /
  `notty` / `DIFFER`.
- **AMBER** = `go-ref-broken` — the Go reference itself fails to build/run (an
  **upstream Go bug**, NOT a Rust-backend failure; discriminated from `DIFFER`
  explicitly). Does NOT make the row red.
- **VERDICT PASS** iff no RED row.

The summary line reports `N green · M red · K skipped · amber go-ref-broken=A` +
an equiv-mode breakdown (`stdout=… body=… scenario=… serve=… pty=… n/a=…
go-ref-broken=…`). A HIST scoreboard (`~/.cache/sky/examples-sweep/`) keeps one
line per run.

## EQUIV modes — DERIVED from shape, overrides on top

The equiv mode is **derived** from `example_shape` by `equiv_mode`
(`lib/examples.sh`), so an author-added example **auto-classifies with no manual
step** — same non-hardcoded discipline as `build_set`:

| Shape | Derived mode | How EQUIV is proven (scoreboard cell) |
|---|---|---|
| cli | `stdout` | run BOTH backends, byte-diff normalized stdout → `equiv-stdout` (**strongest**). Determinism auto-probe: Go run twice; non-stable stdout → `n/a`, never DIFFER. |
| server | `body` | byte-compare each comparable no-param GET-route body Go-vs-Rust → `equiv-body N`; 0 comparable routes → `equiv-serve` (both boot). Per-route Go determinism probe gates dynamic routes. |
| live | `scenario` | run the SAME web-verify scenario against BOTH binaries → `equiv-scenario` (**APP behaviour**, NOT a DOM diff — robust to the by-design console in-process(Go) vs cross-process(Rust)). |
| tui | `pty` | both drive the runtime under a pty without panic → `equiv-pty` (**NOT** cell-identical). |
| webview / fyne / Go-FFI | `none` | no Go comparison possible → `n/a`. |

`equiv-classification.tsv` is **OVERRIDES-ONLY** (a small file of exceptions +
reasons), not a full classification. A line wins over the derived mode — used for
a non-deterministic cli, a known divergence parked as a finding, or a Rust-FFI
app with no Go reference. A brand-new example never needs a line.

**Honesty bins.** The scoreboard NEVER over-reads "equiv": `equiv-stdout` is
byte-identical; `equiv-body N` is N route bodies identical; `equiv-scenario` is
"both pass the scenario"; `equiv-serve` is "both boot"; `equiv-pty` is "both
no-crash"; `n/a` is incomparable.

## Night gate

This heavy sweep (build + run + Go reference + browser over 37 examples) is gated
to **22:00–08:00 America/Sao_Paulo** (slim shared box). Outside the window AND
`SKY_SWEEP_FORCE` unset → prints `deferred: examples-sweep runs 22:00–08:00 …`
and exits 2. Inside the window OR `SKY_SWEEP_FORCE=1` → proceeds. Same gate on
the sibling `examples-perf-sweep`. (`night_guard` lives in `lib/checks.sh`.)

## Flags

| Flag | Effect |
|---|---|
| `SKY_SWEEP_BUILD_ONLY=1` | BUILD column only (fast go-free compile check; RUN + EQUIV = `—`). No `go` needed. |
| `SKY_SWEEP_NO_EQUIV=1` | BUILD + RUN; EQUIV skipped (`—`). |
| `SKY_SWEEP_FORCE=1` | override the night gate. |
| `RUST_EXAMPLES="01-… 19-…"` | subset override (paths or basenames). |

## Preflight

Aborts (exit 2) if free disk < 5G or `mem-guard.sh` is not running — both have
corrupted builds on this box. Fix the cause (free space / start mem-guard), don't
bypass.

## Workflow (every invocation)

1. **Run** (~30–40 min; background + wait). It's night-gated — during the day use
   `SKY_SWEEP_FORCE=1`:
   ```bash
   SKY_SWEEP_FORCE=1 bash runtime-rust/scripts/examples-sweep.sh
   ```
   Self-resolves repo + env, kills stray `sky lsp`/`sky doc` (they hold
   `.skycache` locks), runs the sweep, prints the table + summary + scoreboard
   path.

2. **Relay the table + verdict** — quote the rendered BUILD·RUN·EQUIV table, the
   `N green · M red · K skipped · amber=A` summary, and the equiv-mode breakdown.

3. **Triage RED rows.**
   - A real `DIFFER` is a REAL Go≡Rust divergence to **root-cause + fix
     in-boundary**, not to paper over.
   - A `panic`/`hang`/`noserve`/`*-fail` is a real Rust regression to fix.
   - If a RED is a harness artefact (e.g. a body-equiv false-DIFFER from
     undetected route dynamism), fix the determinism gate in `lib/checks.sh`.
   - `go-ref-broken` is AMBER — report it as an upstream Go bug, do NOT treat as
     a Rust failure.

## Shared `lib/checks.sh`

The per-shape exercise logic (`exercise_cli` / `exercise_server` /
`exercise_live` / `exercise_tui` / `exercise_webview` / `exercise_server_equiv`
+ `http_responds` / `free_port` / `scenario_for` / `reap` / `night_guard` /
`$PANIC_RE` / browser-stack probe) is the SINGLE SOURCE OF TRUTH. RUN exercises
the Rust binary; EQUIV exercises BOTH backends' binaries and compares. One
definition of "did the binary work?", no drift.

## Baked-in gotchas

- PATH `$HOME/.cargo/bin:/usr/local/go/bin:…`;
  `CARGO_TARGET_DIR=$HOME/.cache/sky-rust-target`; `sccache`;
  `CARGO_INCREMENTAL=0`; `SKY_BIN=<repo>/sky-out/sky`.
- `go` is required by default (the EQUIV comparison side); `SKY_SWEEP_BUILD_ONLY=1`
  or `SKY_SWEEP_NO_EQUIV=1` drop it.
- Go-FFI examples are ABSENT from `build_set` (don't build on `--target rust`).
- Never edit runtime files while this runs (concurrent copy → false E0433).

## Capture learnings (self-improving loop)

After this skill's work completes, record any **significant, verified,
generalizable** learning to the **`## Agent learnings`** section of
`runtime-rust/CLAUDE.md`. Obey that section's rules: **only if secure, correct,
and sound + verified**; **reconcile (update / dedupe / prune), never
blind-append**; **skip when nothing significant** — most runs add nothing.
