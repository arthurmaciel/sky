#!/usr/bin/env bash
# Sky Go≡Rust EQUIVALENCE sweep — build each comparable example on BOTH backends
# (--target go AND --target rust), run both, and diff their stdout. Catches the
# *silent divergence* class the other sweeps miss: a Rust example that builds and
# runs fine but prints DIFFERENT output than Go. This is the most direct evidence
# that the Rust backend matches Go — the whole point of the branch.
#
# Supersedes scripts/verify-cross-target.sh (same idea, larger curated set, the
# sweep env + hygiene, and a documented exclusion rationale).
#
# This script IS the procedure (the sky-rust-backend:equiv-sweep skill). If a run
# reveals a comparable example we're missing — or a legitimately-divergent one we
# must exclude — IMPROVE THIS SCRIPT so the next run inherits the fix.
#
# Exit: 0 = every example matches · 1 = a divergence/build failure · 2 = setup error.
set -uo pipefail

# ── Resolve the repo ───────────────────────────────────────────────────────
REPO="${SKY_REPO:-}"
[ -z "$REPO" ] && [ -f "$PWD/scripts/rust-sweep.sh" ] && REPO="$PWD"
[ -z "$REPO" ] && [ -f "$HOME/Documentos/comp/sky/scripts/rust-sweep.sh" ] && REPO="$HOME/Documentos/comp/sky"
if [ -z "$REPO" ] || [ ! -d "$REPO/examples" ]; then
  echo "ERROR: can't locate the Sky repo. cd into it, or set SKY_REPO=/path/to/sky." >&2; exit 2
fi
cd "$REPO"

# ── Env (the gotchas, baked in) ────────────────────────────────────────────
# `go` IS required — this sweep builds the Go backend too (the comparison side).
export PATH="$HOME/.ghcup/bin:$HOME/.cargo/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/sky-rust-target}"  # shared; Rust run is right after its build
command -v sccache >/dev/null 2>&1 && export RUSTC_WRAPPER="${RUSTC_WRAPPER:-sccache}"
export SKY_BIN="$REPO/sky-out/sky"
export SKY_CONSOLE_EMBED=off            # CLI examples don't mount a console; keep it off regardless
[ -x "$SKY_BIN" ] || { echo "ERROR: sky binary not at $SKY_BIN — build it (cabal build exe:sky)." >&2; exit 2; }
command -v go >/dev/null 2>&1 || { echo "ERROR: go required (this sweep builds the Go backend too)." >&2; exit 2; }
mkdir -p "$CARGO_TARGET_DIR"

HIST="$HOME/.cache/sky/equiv-sweep"; mkdir -p "$HIST"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$HIST/equiv-$STAMP.log"
say() { echo "$@" | tee -a "$LOG"; }
say "=== Sky Go≡Rust EQUIVALENCE sweep @ $STAMP (repo: $REPO) ==="

reap() { for p in sky-app app sky-console; do pkill -x "$p" 2>/dev/null; done
         pkill -f "examples/.*/sky-out/" 2>/dev/null; }
ps -u "$USER" -o pid,args 2>/dev/null | awk '/\/sky (lsp|doc)/{print $1}' | xargs -r kill 2>/dev/null
reap

# ── Comparable set ─────────────────────────────────────────────────────────
# Largest set whose stdout is DETERMINISTIC and BACKEND-INDEPENDENT, so a diff
# means a real bug — never a legitimate Go/Rust difference. To stay comparable an
# example must be: a CLI one-shot · non-interactive (no stdin) · build on BOTH
# backends · print nothing that legitimately differs between backends.
#
# EXCLUDED (would be FALSE NEGATIVES — legitimate divergence, not bugs):
#   • server / Sky.Live          — no deterministic stdout to diff; and Live's
#                                  console is IN-PROCESS on Go vs a CROSS-PROCESS
#                                  child on Rust, so even side output diverges by
#                                  design. (08,09,10,12,15,16,17,18,19,25,26,27,
#                                  28,30,32,33,34,39)
#   • tui / webview / fyne        — render to a TTY/window, no comparable stdout.
#                                  (11,21,22,23,24,29,31,38)
#   • non-deterministic output    — anything printing Time/Random/Uuid/Http/PID/
#                                  duration/hash-of-random, or Dict/Set iteration
#                                  order, or concurrent-interleaved prints.
#   • interactive stdin           — 07-todo-cli (reads commands), 20-cli-counter.
#   • not both-backend-buildable  — 02 (Go-FFI), 03,05,13,36,37 (rust build fails).
#   RUST_EQUIV="01-hello-world test_pkg"  → explicit override.
EQUIV_FULL=(
  00-standard-libs        # 120 stdlib assertions — pass/fail lines, backend-independent
  01-hello-world
  04-local-pkg            # multi-module
  06-json                 # encode/decode; object key order is _fieldIndex-stable on both
  14-task-demo            # sequential Task andThen/fail/run
  35-composite-generics
  simple                  # task_sequence/parallel — results collected then printed in order
  test_pkg                # Result/Maybe combinators
)
if [ -n "${RUST_EQUIV:-}" ]; then read -r -a EXAMPLES <<< "$RUST_EQUIV"; else EXAMPLES=("${EQUIV_FULL[@]}"); fi

# Strip blank lines only (cosmetic) — NOT aggressive normalisation, which could
# mask a real divergence. A surviving diff is a genuine output mismatch.
norm() { grep -v '^[[:space:]]*$' "$1" 2>/dev/null | head -200; }

PASS=0; FAIL=0; SKIP=0; FAILED=""
for ex in "${EXAMPLES[@]}"; do
  d="examples/$ex"; [ -f "$d/src/Main.sky" ] || { say "  SKIP   $ex (absent)"; SKIP=$((SKIP+1)); continue; }
  go_out="$HIST/$ex.go.txt"; rs_out="$HIST/$ex.rust.txt"

  # ── Go side: build (default target) + run ──
  ( cd "$d" && rm -rf sky-out .skycache .skydeps && timeout 300 "$SKY_BIN" build src/Main.sky ) >"$HIST/$ex.go.build.log" 2>&1
  if [ ! -x "$d/sky-out/app" ]; then
    say "  GO-BUILD-FAIL $ex"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(go-build)"; ( cd "$d" && rm -rf sky-out .skycache .skydeps ); continue
  fi
  ( cd "$d" && timeout 25 ./sky-out/app </dev/null ) >"$go_out" 2>/dev/null

  # ── Rust side: build (--target rust) + cargo + run (right after, shared target binary) ──
  ( cd "$d" && rm -rf sky-out .skycache .skydeps && timeout 300 "$SKY_BIN" build src/Main.sky --target rust ) >"$HIST/$ex.rust.build.log" 2>&1
  if [ "$(cd "$d" && timeout 900 cargo build --manifest-path sky-out/Rust/Cargo.toml -q >>"$HIST/$ex.rust.build.log" 2>&1; echo $?)" != 0 ]; then
    say "  RUST-BUILD-FAIL $ex"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(rust-build)"; ( cd "$d" && rm -rf sky-out .skycache .skydeps ); continue
  fi
  bin="$CARGO_TARGET_DIR/debug/sky-app"; [ -x "$bin" ] || bin="$d/sky-out/Rust/target/debug/sky-app"
  ( cd "$d" && timeout 25 "$bin" </dev/null ) >"$rs_out" 2>/dev/null

  # ── Diff stdout ──
  if diff <(norm "$go_out") <(norm "$rs_out") >"$HIST/$ex.diff.txt" 2>&1; then
    say "  MATCH  $ex"; PASS=$((PASS+1))
  else
    say "  DIFFER $ex  (diff: $HIST/$ex.diff.txt)"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(differ)"
    sed -n '1,12p' "$HIST/$ex.diff.txt" | sed 's/^/      /' | tee -a "$LOG"
  fi
  reap
  ( cd "$d" && rm -rf sky-out .skycache .skydeps )
done

reap
say ""; say "=== EQUIV SWEEP: $PASS match · $FAIL differ/fail · $SKIP skipped ==="
[ -n "$FAILED" ] && say "  failures:$FAILED"
say "  per-example: $HIST/<ex>.{go,rust}.txt · <ex>.diff.txt · build logs"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
