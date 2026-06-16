#!/usr/bin/env bash
# Sky Rust-backend BUILD sweep — `sky build --target rust` + `cargo build` over
# the largest example set, reporting in-scope failures. Run + perf are separate
# skills (/run-sweep, /perf-sweep).
#
# This script IS the procedure (the /build-sweep skill). Wraps the repo's
# runtime-rust/scripts/rust-sweep.sh (which already bins the largest set: examples/[0-9]* +
# simple + test_pkg) with the env gotchas + a clean failure report. If a run
# reveals a better way, IMPROVE THIS SCRIPT (or runtime-rust/scripts/rust-sweep.sh).
#
# Exit: 0 = all in-scope build · 1 = in-scope build failure · 2 = setup error.
set -uo pipefail

# ── Env (shared SINGLE SOURCE OF TRUTH under lib/) ──────────────────────────
source "$(dirname "$0")/lib/env.sh"
if [ -z "$REPO" ] || [ ! -f "$REPO/runtime-rust/scripts/rust-sweep.sh" ]; then
  echo "ERROR: can't locate the Sky repo. cd into it, or set SKY_REPO=/path/to/sky." >&2; exit 2
fi
cd "$REPO"
[ -x "$SKY_BIN" ] || { echo "ERROR: sky binary not at $SKY_BIN — build it (cabal build exe:sky)." >&2; exit 2; }
# Skip the per-example console pre-build (it's not what a build sweep checks).
export SKY_CONSOLE_PREBUILD=off

HIST="$HOME/.cache/sky/build-sweep"; mkdir -p "$HIST"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$HIST/sweep-$STAMP.log"
say() { echo "$@" | tee -a "$HIST/run-$STAMP.log"; }
say "=== Sky Rust BUILD sweep @ $STAMP (repo: $REPO) ==="

# ── Hygiene: stray `sky lsp` / `sky doc --serve` can hold .skycache locks ───
# (Misleading `.skycache/go/_bindings.go: resource busy` class — see memory.)
ps -u "$USER" -o pid,args 2>/dev/null | awk '/\/sky (lsp|doc)/{print $1}' | xargs -r kill 2>/dev/null
for p in sky-app app sky-console; do pkill -x "$p" 2>/dev/null; done
sync

# ── Run the sweep ──────────────────────────────────────────────────────────
say ""; say ">>> BUILD SWEEP  (SKY_CONSOLE_PREBUILD=off; runtime-rust/scripts/rust-sweep.sh)"
bash runtime-rust/scripts/rust-sweep.sh > "$LOG" 2>&1
BUILT="$(grep -cE 'builds$' "$LOG" 2>/dev/null || echo 0)"
# DERIVED set: every example in the scoreboard is in scope (Go-FFI is absent, not
# tagged). So an in-scope failure is simply any result line ending in fails/CRASH.
IN_SCOPE_FAILS="$(grep -vE '^EXAMPLE|^---' "$LOG" 2>/dev/null | grep -E 'fails$|CRASH$' || true)"
say "  examples building: $BUILT   (full scoreboard: $LOG)"
if [ -n "$IN_SCOPE_FAILS" ]; then
  say "  IN-SCOPE FAILURES:"; printf '%s\n' "$IN_SCOPE_FAILS" | sed 's/^/    /' | tee -a "$HIST/run-$STAMP.log"
  say ""; say "=== VERDICT: FAIL (in-scope build failures above) ==="
  exit 1
fi
say "  all in-scope examples build ✓"
say ""; say "=== VERDICT: PASS · scoreboard=$LOG ==="
exit 0
