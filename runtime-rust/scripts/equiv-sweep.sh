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

# ── Env (shared SINGLE SOURCE OF TRUTH under lib/) ──────────────────────────
# `go` IS required — this sweep builds the Go backend too (the comparison side).
# The comparable set is the equiv-classification.tsv manifest (see below) — its
# own single source of truth, distinct from lib/examples.sh's build/run/web sets.
source "$(dirname "$0")/lib/env.sh"
if [ -z "$REPO" ] || [ ! -d "$REPO/examples" ]; then
  echo "ERROR: can't locate the Sky repo. cd into it, or set SKY_REPO=/path/to/sky." >&2; exit 2
fi
cd "$REPO"
export SKY_CONSOLE_EMBED=off            # CLI examples don't mount a console; keep it off regardless
[ -x "$SKY_BIN" ] || { echo "ERROR: sky binary not at $SKY_BIN — build it (cabal build exe:sky)." >&2; exit 2; }
command -v go >/dev/null 2>&1 || { echo "ERROR: go required (this sweep builds the Go backend too)." >&2; exit 2; }

HIST="$HOME/.cache/sky/equiv-sweep"; mkdir -p "$HIST"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$HIST/equiv-$STAMP.log"
say() { echo "$@" | tee -a "$LOG"; }
say "=== Sky Go≡Rust EQUIVALENCE sweep @ $STAMP (repo: $REPO) ==="

reap() { for p in sky-app app sky-console; do pkill -x "$p" 2>/dev/null; done
         pkill -f "examples/.*/sky-out/" 2>/dev/null; }
ps -u "$USER" -o pid,args 2>/dev/null | awk '/\/sky (lsp|doc)/{print $1}' | xargs -r kill 2>/dev/null
reap

# ── Comparable set — from the classification manifest (single source of truth) ─
# equiv-classification.tsv lists EVERY example as `in` (deterministic +
# backend-independent stdout → a diff is a real bug) or `out` (a diff there would
# be a legitimate Go/Rust difference). The `in` rows are this sweep's set.
MANIFEST="$REPO/runtime-rust/scripts/equiv-classification.tsv"
[ -f "$MANIFEST" ] || { echo "ERROR: classification manifest missing: $MANIFEST" >&2; exit 2; }

# CLASSIFICATION-COVERAGE GATE: every examples/ dir on disk MUST be classified.
# An unclassified example means the parity claim is incomplete → FAIL (this is
# the forced-classification rule: "Go parity maintained" requires full coverage).
classified_all="$(awk '!/^#/ && NF>=2 {print $1}' "$MANIFEST" | sort -u)"
on_disk="$(find examples -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -u)"
UNCLASSIFIED="$(comm -13 <(echo "$classified_all") <(echo "$on_disk") | tr '\n' ' ' | sed 's/ *$//')"

# The `in` set (manifest order). RUST_EQUIV="a b c" overrides for a quick subset.
IN_SET="$(awk '!/^#/ && $2=="in" {print $1}' "$MANIFEST" | tr '\n' ' ' | sed 's/ *$//')"
if [ -n "${RUST_EQUIV:-}" ]; then read -r -a EXAMPLES <<< "$RUST_EQUIV"; else read -r -a EXAMPLES <<< "$IN_SET"; fi

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

# ── Classification-coverage gate (full runs only) ──
# "Go parity maintained" requires EVERY example classified in/out. An unclassified
# example on disk is a gate failure — classify it in equiv-classification.tsv.
COVERAGE_FAIL=0
if [ -z "${RUST_EQUIV:-}" ] && [ -n "$UNCLASSIFIED" ]; then
  COVERAGE_FAIL=1
  say "  UNCLASSIFIED (parity claim INCOMPLETE — classify in/out in equiv-classification.tsv):"
  say "    $UNCLASSIFIED"
fi
say "  per-example: $HIST/<ex>.{go,rust}.txt · <ex>.diff.txt · build logs"
if [ "$FAIL" -eq 0 ] && [ "$COVERAGE_FAIL" -eq 0 ]; then
  [ -z "${RUST_EQUIV:-}" ] && say "  ✓ all examples classified; in-scope set matches Go"
  exit 0
fi
exit 1
