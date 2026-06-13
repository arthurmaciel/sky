#!/usr/bin/env bash
# Sky Rust-backend BUILD sweep — `sky build --target rust` + `cargo build` over
# the largest example set, reporting in-scope failures. Run + perf are separate
# skills (/run-sweep, /perf-sweep).
#
# This script IS the procedure (the /build-sweep skill). Wraps the repo's
# scripts/rust-sweep.sh (which already bins the largest set: examples/[0-9]* +
# simple + test_pkg) with the env gotchas + a clean failure report. If a run
# reveals a better way, IMPROVE THIS SCRIPT (or scripts/rust-sweep.sh).
#
# Exit: 0 = all in-scope build · 1 = in-scope build failure · 2 = setup error.
set -uo pipefail

# ── Resolve the repo ───────────────────────────────────────────────────────
REPO="${SKY_REPO:-}"
[ -z "$REPO" ] && [ -f "$PWD/scripts/rust-sweep.sh" ] && REPO="$PWD"
[ -z "$REPO" ] && [ -f "$HOME/Documentos/comp/sky/scripts/rust-sweep.sh" ] && REPO="$HOME/Documentos/comp/sky"
if [ -z "$REPO" ] || [ ! -f "$REPO/scripts/rust-sweep.sh" ]; then
  echo "ERROR: can't locate the Sky repo. cd into it, or set SKY_REPO=/path/to/sky." >&2; exit 2
fi
cd "$REPO"

# ── Env (the gotchas, baked in) ────────────────────────────────────────────
export PATH="$HOME/.ghcup/bin:$HOME/.cargo/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/sky-rust-target}"
command -v sccache >/dev/null 2>&1 && export RUSTC_WRAPPER="${RUSTC_WRAPPER:-sccache}"
export SKY_BIN="$REPO/sky-out/sky"
[ -x "$SKY_BIN" ] || { echo "ERROR: sky binary not at $SKY_BIN — build it (cabal build exe:sky)." >&2; exit 2; }
# Skip the per-example console pre-build (it's not what a build sweep checks).
export SKY_CONSOLE_PREBUILD=off
mkdir -p "$CARGO_TARGET_DIR"

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
say ""; say ">>> BUILD SWEEP  (SKY_CONSOLE_PREBUILD=off; scripts/rust-sweep.sh)"
bash scripts/rust-sweep.sh > "$LOG" 2>&1
BUILT="$(grep -c 'builds' "$LOG" 2>/dev/null || echo 0)"
# In-scope failures = a result line that is NOT 'builds' and NOT '(out-of-scope)'.
IN_SCOPE_FAILS="$(grep -vE 'out-of-scope|builds$|^EXAMPLE|^---' "$LOG" 2>/dev/null | grep -E 'fails|CRASH' || true)"
say "  examples building: $BUILT   (full scoreboard: $LOG)"
if [ -n "$IN_SCOPE_FAILS" ]; then
  say "  IN-SCOPE FAILURES:"; printf '%s\n' "$IN_SCOPE_FAILS" | sed 's/^/    /' | tee -a "$HIST/run-$STAMP.log"
  say ""; say "=== VERDICT: FAIL (in-scope build failures above) ==="
  exit 1
fi
say "  all in-scope examples build ✓"
say ""; say "=== VERDICT: PASS · scoreboard=$LOG ==="
exit 0
