#!/usr/bin/env bash
# Sky Rust-backend EXAMPLES-PERF sweep — Rust-vs-Go perf over the perf-runnable
# example set + a regression report vs the previous run. Build + run + equiv are
# the sibling sky-rust-backend:examples-sweep skill.
#
# This script IS the procedure (the sky-rust-backend:examples-perf-sweep skill).
# Do not re-decide the steps ad-hoc; if a run reveals a better way (a new gotcha,
# a parse miss, a flaky step, another example shape), IMPROVE THIS SCRIPT so the
# next run inherits the fix.
#
# PRINCIPLES (README.md top, strict order): security > correctness > soundness >
# efficiency > completeness > readability. Perf serves EFFICIENCY — never at the
# cost of a higher principle; a perf "win" that broke correctness is not a win.
#
# NIGHT GATE: like examples-sweep, this heavy sweep is gated to 22:00–08:00
# America/Sao_Paulo (slim shared box). SKY_SWEEP_FORCE=1 overrides.
#
# Exit: 0 always (perf is informational; regressions are reported, not fatal);
#       2 = setup error / deferred by the night gate.
set -uo pipefail

# ── Env + manifest + shared checks (shared SINGLE SOURCE OF TRUTH under lib/) ─
# checks.sh provides night_guard; sourced BEFORE this script's own purpose-built
# reap() (which also kills hyperfine/ab/sse-bench) so the perf reap wins.
source "$(dirname "$0")/lib/env.sh"
source "$(dirname "$0")/lib/examples.sh"
source "$(dirname "$0")/lib/checks.sh"

# ── Night gate (22:00–08:00 America/Sao_Paulo; SKY_SWEEP_FORCE=1 overrides) ──
night_guard "examples-perf-sweep"
# rust-perf.sh's per-metric harness only knows cli/server/live; a tui/webview
# binary waits for input/a window, so hyperfine cold-start would hang on it and
# there's no throughput metric. We therefore measure build + cold-start ONLY for
# those shapes (skip the throughput harness) — see the shape switch below.
if [ -z "$REPO" ] || [ ! -f "$REPO/runtime-rust/scripts/rust-perf.sh" ]; then
  echo "ERROR: can't locate the Sky repo. cd into it, or set SKY_REPO=/path/to/sky." >&2; exit 2
fi
cd "$REPO"
[ -x "$SKY_BIN" ] || { echo "ERROR: sky binary not at $SKY_BIN — build it (cabal build exe:sky)." >&2; exit 2; }
command -v go        >/dev/null 2>&1 || echo "WARN: 'go' not on PATH — the perf harness builds the Go backend; ratios may skip." >&2
command -v ab        >/dev/null 2>&1 || echo "WARN: 'ab' (apache-bench) missing — server/live throughput will skip." >&2
command -v hyperfine >/dev/null 2>&1 || echo "WARN: 'hyperfine' missing — cli cold-start will read 0." >&2
command -v python3   >/dev/null 2>&1 || { echo "ERROR: python3 required for the regression diff." >&2; exit 2; }

HIST="$HOME/.cache/sky/examples-perf-sweep"; mkdir -p "$HIST"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PERF_TSV="$HIST/perf-$STAMP.tsv"
LOG="$HIST/run-$STAMP.log"
# Provenance sidecar (read by readme-tables.py to stamp the README banner with
# WHERE + WHEN the numbers were measured). key=value, one per line.
PERF_PROVENANCE="$HIST/perf-$STAMP.provenance"
{
  echo "stamp=$STAMP"
  echo "os=${RUNNER_OS:-$(uname -s)}"
  echo "arch=$(uname -m)"
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then echo "runner=GitHub Actions"; else echo "runner=$(hostname -s 2>/dev/null || echo local)"; fi
} > "$PERF_PROVENANCE"
say() { echo "$@" | tee -a "$LOG"; }
say "=== Sky Rust PERF sweep @ $STAMP (repo: $REPO) ==="

# ── Pre-flight hygiene: orphans skew perf + leak the process table ──────────
# Drop bare `app` from the -x list: it could match an unrelated user process
# literally named `app`. The Go output binary (named `app`) is reaped by the
# path-scoped `pkill -f examples/.*/sky-out/` line below instead.
reap() { for p in hyperfine ab sse-bench sky-app sky-console; do pkill -x "$p" 2>/dev/null; done
         pkill -f "examples/.*/sky-out/" 2>/dev/null; }
reap; sync; sleep 1

# ── Perf set (isolate app perf — no console spawn) ──────────────────────────
# DERIVED perf_set (lib/examples.sh) = every example minus Go-FFI; nothing
# excluded by shape. throughput (ab/sse) only makes sense for server/live; cli
# gets cold-start/RSS/binsize; tui/webview get build + cold-start only (the
# shape switch below skips the throughput harness so hyperfine can't hang on an
# input/window-waiting binary). rust-perf.sh self-skips (exit 3) anything a
# backend can't build; each call is timeout-bounded + orphan-reaped.
#   RUST_PERF_QUICK=1        → 3-shape representative (fast).
#   RUST_PERF="a b c"        → explicit override.
PERF_QUICK=(14-task-demo 15-http-server 09-live-counter)
if [ -n "${RUST_PERF:-}" ]; then read -r -a EXAMPLES <<< "$RUST_PERF"
elif [ -n "${RUST_PERF_QUICK:-}" ]; then EXAMPLES=("${PERF_QUICK[@]}")
else EXAMPLES=(); while IFS= read -r d; do EXAMPLES+=("$(basename "$d")"); done < <(perf_set); fi

say ""; say ">>> PERF SWEEP  (SKY_CONSOLE_EMBED=off; ${#EXAMPLES[@]} examples)"
: > "$PERF_TSV"; SKIPPED=""
for ex in "${EXAMPLES[@]}"; do
  ex="${ex#examples/}"; ex="${ex%/}"
  [ -f "examples/$ex/src/Main.sky" ] || { SKIPPED="$SKIPPED $ex(absent)"; continue; }
  shape="$(example_shape "examples/$ex")"
  # tui/webview/fyne: no throughput metric, and hyperfine cold-start would hang on
  # an input/window-waiting binary. Skip the throughput harness (build is already
  # exercised by examples-sweep's BUILD + RUN pty/xvfb smoke).
  case "$shape" in
    tui|webview|fyne) say "  -- $ex ($shape: build/cold-start only — no throughput metric; skipped) --"; SKIPPED="$SKIPPED $ex($shape)"; continue;;
  esac
  say "  -- $ex --"
  OUT="$(SKY_CONSOLE_EMBED=off timeout --kill-after=30 600 bash runtime-rust/scripts/rust-perf.sh "$ex" 2>&1)"; rc=$?
  reap
  printf '%s\n' "$OUT" >> "$LOG"
  # Preserve the per-example build logs — rust-perf.sh writes FIXED /tmp names
  # that the next example overwrites, so without this a build failure is not
  # diagnosable from the uploaded artifact. Copy them under $HIST/<ex>.*.
  for bl in perf-build-go perf-build-rust-gen perf-build-rust; do
    [ -f "/tmp/$bl.log" ] && cp -f "/tmp/$bl.log" "$HIST/$ex.$bl.log" 2>/dev/null
  done
  N="$(printf '%s\n' "$OUT" | grep -E '^[[:space:]]+(rss|coldstart|binsize|throughput|live_warm|live_event|sse_eps|ws_eps|broadcast)[[:space:]]' | tee -a "$LOG" | \
    awk -v ex="$ex" '{
      metric=$1; go=""; rust=""; ratio=""; thr=""; verdict=$NF
      for (i=1;i<=NF;i++){
        if ($i ~ /^go=/)      {sub(/go=/,"",$i);    go=$i}
        else if ($i ~ /^rust=/)  {sub(/rust=/,"",$i);  rust=$i}
        else if ($i ~ /^ratio=/) {sub(/ratio=/,"",$i); ratio=$i}
        else if ($i ~ /^thr=/)   {sub(/thr=/,"",$i);   thr=$i}
      }
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", ex, metric, go, rust, ratio, thr, verdict
    }' | tee -a "$PERF_TSV" | wc -l)"
  if [ "${N:-0}" -eq 0 ]; then
    reason="no metrics"; [ "$rc" = 124 ] && reason="TIMEOUT"
    printf '%s\n' "$OUT" | grep -qi "go build failed"   && reason="go-build-fail (skip)"
    printf '%s\n' "$OUT" | grep -qi "rust build failed" && reason="RUST-BUILD-FAIL"
    say "     ($ex: $reason)"; SKIPPED="$SKIPPED $ex"
  fi
done
[ -n "$SKIPPED" ] && say "  skipped/no-data:$SKIPPED"
say "  perf metrics saved → $PERF_TSV"

# ── Regression report vs the previous run ──────────────────────────────────
PREV="$(ls -1t "$HIST"/perf-*.tsv 2>/dev/null | grep -vF "$PERF_TSV" | head -1)"
say ""; say ">>> REGRESSION REPORT  (this run vs previous)"
if [ -z "$PREV" ]; then
  say "  (no previous perf run — recorded as baseline; diffs appear from the next run)"
else
  say "  previous: $(basename "$PREV")"
  python3 - "$PREV" "$PERF_TSV" <<'PY' | tee -a "$LOG"
import sys
def load(p):
    d={}
    with open(p) as fh:
        for ln in fh:
            f=ln.rstrip("\n").split("\t")
            if len(f)>=7: d[(f[0],f[1])]=dict(go=f[2],rust=f[3],ratio=f[4],thr=f[5],verdict=f[6])
    return d
def num(x):
    try: return float(x)
    except: return None
prev=load(sys.argv[1]); cur=load(sys.argv[2])
better=[]; worse=[]; same=[]
for k in sorted(cur):
    ex,metric=k; c=cur[k]; p=prev.get(k)
    if not p:
        same.append(f"  + {ex}/{metric}: new (rust={c['rust']} ratio={c['ratio']} {c['verdict']})"); continue
    cr,pr=num(c["rust"]),num(p["rust"]); hib=(metric=="throughput")
    if cr is None or pr is None or pr==0:
        same.append(f"  = {ex}/{metric}: {p['verdict']}->{c['verdict']} (rust {p['rust']}->{c['rust']})"); continue
    d=(cr-pr)/pr*100.0
    improved=(d>0) if hib else (d<0)
    line=f"{ex}/{metric}: rust {p['rust']}->{c['rust']} ({d:+.1f}%) ratio {p['ratio']}->{c['ratio']} verdict {p['verdict']}->{c['verdict']}"
    if (c['verdict']=='FAIL' and p['verdict']!='FAIL') or (not improved and abs(d)>10): worse.append("  ! "+line)
    elif improved and abs(d)>5: better.append("  ^ "+line)
    else: same.append("  = "+line)
for l in same: print(l)
if better:
    print("  --- IMPROVEMENTS (>5%) ---");  [print(l) for l in better]
if worse:
    print("  --- REGRESSIONS (verdict->FAIL or >10%) ---"); [print(l) for l in worse]
print("  PERF SUMMARY:", "REGRESSIONS FOUND" if worse else ("improvements only" if better else "no significant change"))
PY
fi

# ── Disk hygiene + done ────────────────────────────────────────────────────
for ex in "${EXAMPLES[@]}"; do
  ex="${ex#examples/}"; ex="${ex%/}"
  case "$ex" in ""|*/*|..) continue;; esac
  rm -rf "examples/$ex/sky-out" "examples/$ex/.skycache" "examples/$ex/.skydeps" 2>/dev/null
done
command -v go >/dev/null 2>&1 && go clean -cache >/dev/null 2>&1 || true
say ""; say "=== DONE: perf=$PERF_TSV · log=$LOG ==="
exit 0
