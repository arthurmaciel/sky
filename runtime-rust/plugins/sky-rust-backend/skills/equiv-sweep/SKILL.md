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

3. **Improve the script if warranted** — a real divergence to file, OR a set
   adjustment (a newly-comparable example to add, or a now-divergent one to
   exclude with a documented reason).

## The comparable set — and why "no false negatives" is curated, not normalised

A diff only means a bug if the output is **deterministic and
backend-independent**. The set is every CLI one-shot that qualifies; the rest are
**excluded by design** (a diff there would be a legitimate Go/Rust difference,
not a regression):

| Excluded | Why it would false-negative |
|---|---|
| server / Sky.Live | no deterministic stdout; and the console is **in-process on Go vs a cross-process child on Rust**, so side output diverges by design |
| tui / webview / fyne | render to a TTY/window — no comparable stdout |
| Time / Random / Uuid / Http / Dict-order / concurrent-interleaved output | output legitimately varies run-to-run and backend-to-backend |
| interactive stdin (07-todo-cli, 20-cli-counter) | would hang / isn't a one-shot |
| not both-backend-buildable (02 Go-FFI; 03,05,13,36,37) | nothing to compare |

Included (8): `00-standard-libs · 01-hello-world · 04-local-pkg · 06-json ·
14-task-demo · 35-composite-generics · simple · test_pkg`. The diff strips blank
lines only — **no aggressive normalisation** (that could mask a real divergence).
`RUST_EQUIV="01-hello-world test_pkg"` overrides.

## Baked-in gotchas

- **`go` is required** — this sweep builds the Go backend too (the comparison side).
- PATH `/usr/local/go/bin` + `$HOME/.cargo/bin` + `sccache`;
  `CARGO_TARGET_DIR=$HOME/.cache/sky-rust-target`; `SKY_BIN=<repo>/sky-out/sky`.
- Each binary is run with `</dev/null` + a 25 s timeout so an unexpectedly
  interactive example can't hang the sweep.
- Supersedes the older `scripts/verify-cross-target.sh` (same idea, larger set +
  sweep hygiene). Never edit runtime files mid-run.
