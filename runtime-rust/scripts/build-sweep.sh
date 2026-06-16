#!/usr/bin/env bash
# Sky Rust-backend BUILD sweep — `sky build --target rust` + `cargo build` over
# the largest in-scope example set, reporting in-scope failures. Run + perf are
# separate skills (/run-sweep, /perf-sweep).
#
# This script IS the procedure (the sky-rust-backend:build-sweep skill). It bins
# every in-scope example (build_set from lib/examples.sh — every candidate dir
# minus Go-FFI) by how far the Rust backend gets, then reports any non-`builds`
# result as a REAL failure. Build-level only; run-level equivalence lives in
# equiv-sweep.sh. If a run reveals a better way, IMPROVE THIS SCRIPT.
#
# DERIVED set: a Go-FFI example (one that imports an unresolvable Go-package
# module) is simply ABSENT from build_set — no "out-of-scope" tag. Every example
# present here is in scope, so any non-`builds` result is a real failure
# (greenfield gaps surface as failures — user decision).
#
# Env + example manifest are the shared SINGLE SOURCE OF TRUTH under lib/.
#
# Exit: 0 = all in-scope build · 1 = in-scope build failure · 2 = setup error.
set -uo pipefail

# ── Env + example manifest (shared SINGLE SOURCE OF TRUTH under lib/) ────────
source "$(dirname "$0")/lib/env.sh"
source "$(dirname "$0")/lib/examples.sh"
if [ -z "$REPO" ] || [ ! -f "$REPO/runtime-rust/scripts/build-sweep.sh" ]; then
  echo "ERROR: can't locate the Sky repo. cd into it, or set SKY_REPO=/path/to/sky." >&2; exit 2
fi
cd "$REPO"
[ -x "$SKY_BIN" ] || { echo "ERROR: sky binary not at $SKY_BIN — build it (cabal build exe:sky)." >&2; exit 2; }
# Skip the per-example console pre-build (it's not what a build sweep checks).
export SKY_CONSOLE_PREBUILD=off

HIST="$HOME/.cache/sky/build-sweep"; mkdir -p "$HIST"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$HIST/sweep-$STAMP.log"     # the scoreboard (EXAMPLE / RESULT table)
say() { echo "$@" | tee -a "$HIST/run-$STAMP.log"; }
say "=== Sky Rust BUILD sweep @ $STAMP (repo: $REPO) ==="

# ── Hygiene: stray `sky lsp` / `sky doc --serve` can hold .skycache locks ───
# (Misleading `.skycache/go/_bindings.go: resource busy` class — see memory.)
ps -u "$USER" -o pid,args 2>/dev/null | awk '/\/sky (lsp|doc)/{print $1}' | xargs -r kill 2>/dev/null
for p in sky-app app sky-console; do pkill -x "$p" 2>/dev/null; done
sync

# ── Scoreboard: build_set, binned by how far the Rust backend gets ──────────
say ""; say ">>> BUILD SWEEP  (SKY_CONSOLE_PREBUILD=off; build_set from lib/examples.sh)"
{
  printf "%-30s %s\n" "EXAMPLE" "RESULT"
  printf "%-30s %s\n" "-------" "------"
  while IFS= read -r d; do
    n=$(basename "$d")
    [ -f "${d}/src/Main.sky" ] || continue
    ( cd "$d" && rm -rf sky-out .skycache .skydeps )
    if ! ( cd "$d" && timeout 180 "$SKY_BIN" build src/Main.sky --target rust >/tmp/sweep-$n.sky.log 2>&1 ); then
      if rg -qE "Non-exhaustive|CallStack \(from HasCallStack\)|Prelude\.[a-z]+: |internal error" /tmp/sweep-$n.sky.log 2>/dev/null; then
        r="sky-CRASH"
      else
        r="sky-build-fails"
      fi
    elif ( cd "$d" && timeout 600 cargo build --manifest-path sky-out/Rust/Cargo.toml -q >/tmp/sweep-$n.cargo.log 2>&1 ); then
      r="builds"
    else
      r="cargo-fails"
    fi
    printf "%-30s %s\n" "$n" "$r"
    # Reclaim disk immediately — 40+ cargo target/ dirs (~1.5 GB each) otherwise
    # fill the filesystem mid-sweep (the result is already recorded above).
    ( cd "$d" && rm -rf sky-out .skycache .skydeps )
  done < <(build_set)
} > "$LOG" 2>&1

# ── Verdict ─────────────────────────────────────────────────────────────────
BUILT="$(grep -cE 'builds$' "$LOG" 2>/dev/null || echo 0)"
# Every example in the scoreboard is in scope (Go-FFI is absent, not tagged). So
# an in-scope failure is simply any result line ending in fails/CRASH.
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
