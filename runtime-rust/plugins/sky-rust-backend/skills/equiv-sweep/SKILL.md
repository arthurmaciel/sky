---
name: equiv-sweep
description: Run the Sky Go≡Rust EQUIVALENCE sweep — build each comparable example on BOTH backends (--target go AND --target rust), run both, and diff their stdout to catch SILENT divergence (a Rust example that builds and runs fine but prints different output than Go). The most direct proof the Rust backend matches Go. Use when the user asks to run the equiv sweep, check Go-vs-Rust output parity, or verify the backends still agree after a runtime/codegen change. Siblings: sky-rust-backend:build-sweep / run-sweep / web-sweep / perf-sweep. Trigger: /sky-rust-backend:equiv-sweep.
---

# equiv-sweep

The **equivalence** phase — Go≡Rust output parity. Where the other sweeps prove
the Rust side *builds* (build-sweep), *runs without panicking* (run-sweep), and
*round-trips in a browser* (web-sweep), this one proves it produces **the same
output as Go** for the same input. One **deterministic** script builds each
comparable example on both backends, runs both, and diffs stdout. **Do NOT
re-decide the steps** — if a run reveals a comparable example we're missing, or a
legitimately-divergent one to exclude, edit `runtime-rust/scripts/equiv-sweep.sh`.

Deterministic, no perf timing → load-tolerant, **no close-the-apps reminder**.

## Workflow (every invocation)

1. **Run the script** (~10–20 min; background + wait):
   ```bash
   bash runtime-rust/scripts/equiv-sweep.sh
   ```
   Self-resolves repo + env; per example builds Go → runs → builds Rust → runs →
   diffs → reaps → cleans.

2. **Relay the verdict** — `N match · M differ/fail · K skipped`, plus the
   `failures:` list (tagged `(go-build)` / `(rust-build)` / `(differ)`). A
   `(differ)` is a **real parity bug** — the first ~12 diff lines are inlined;
   full diff at `~/.cache/sky/equiv-sweep/<ex>.diff.txt` (with the captured
   `<ex>.go.txt` / `<ex>.rust.txt`).

3. **Improve the manifest/script if warranted** — a real divergence to file, OR a
   classification change in `equiv-classification.tsv` (a newly-comparable example
   to flip `in`, a now-divergent one to flip `out` with a reason).

## The classification manifest — and the coverage gate

The comparable set is **not hardcoded** — it's read from
`runtime-rust/scripts/equiv-classification.tsv`, the single source of truth that
classifies **every** example as `in` or `out`:

- **`in`** — stdout is deterministic AND backend-independent → a diff is a real
  bug. These are the examples the sweep diffs.
- **`out`** — a diff there would be a *legitimate* Go/Rust difference, with the
  reason recorded. Excluded categories: server / Sky.Live (no stdout; the console
  is **in-process on Go vs a cross-process child on Rust** by design),
  tui/webview/fyne (TTY/window), Time/Random/Uuid/Http/Dict-order/concurrent
  output, interactive stdin, and non-both-backend-buildable.

**Coverage gate (the forced-classification rule).** On a full run the sweep
checks every `examples/` dir against the manifest. **Any unclassified example
fails the sweep** — "Go parity maintained" cannot be claimed until it's
classified `in`/`out`. So when an example lands, classifying it in the manifest
is mandatory, not optional. (`sky-rust-backend:keep-go-parity` inherits this gate
by always running equiv-sweep.)

The diff strips blank lines only — **no aggressive normalisation** (that could
mask a real divergence). `RUST_EQUIV="01-hello-world test_pkg"` runs a subset
(and skips the coverage gate).

## Baked-in gotchas

- **`go` is required** — this sweep builds the Go backend too (the comparison side).
- PATH `/usr/local/go/bin` + `$HOME/.cargo/bin` + `sccache`;
  `CARGO_TARGET_DIR=$HOME/.cache/sky-rust-target`; `SKY_BIN=<repo>/sky-out/sky`.
- Each binary is run with `</dev/null` + a 25 s timeout so an unexpectedly
  interactive example can't hang the sweep.
- Supersedes the older `scripts/verify-cross-target.sh` (same idea, larger set +
  sweep hygiene). Never edit runtime files mid-run.

## Capture learnings (self-improving loop)

After this skill's work completes, record any **significant, verified,
generalizable** learning — a non-obvious pitfall, a deeper foundational insight,
or a secure/correct/sound optimization — to the **`## Agent learnings`** section
of `runtime-rust/CLAUDE.md`, so future agents improve. Obey that section's rules:
**only if secure, correct, and sound + verified**; **reconcile (update / dedupe /
prune), never blind-append**; **skip when nothing significant** — most runs add
nothing, and manufacturing an entry is worse than none.
