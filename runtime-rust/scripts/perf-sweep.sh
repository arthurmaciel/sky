#!/usr/bin/env bash
# Sky Rust-backend PERF sweep — Rust-vs-Go perf over the perf-runnable example
# set + a regression report vs the previous run. Build + run sweeps are separate
# skills (/build-sweep, /run-sweep).
#
# This script IS the procedure (the /perf-sweep skill). Do not re-decide
# the steps ad-hoc; if a run reveals a better way (a new gotcha, a parse miss, a
# flaky step, another example shape), IMPROVE THIS SCRIPT so the next run
# inherits the fix.
#
# Exit: 0 always (perf is informational; regressions are reported, not fatal);
#       2 = setup error.
set -uo pipefail

# ── Resolve the repo ───────────────────────────────────────────────────────
REPO="${SKY_REPO:-}"
[ -z "$REPO" ] && [ -f "$PWD/scripts/rust-perf.sh" ] && REPO="$PWD"
[ -z "$REPO" ] && [ -f "$HOME/Documentos/comp/sky/scripts/rust-perf.sh" ] && REPO="$HOME/Documentos/comp/sky"
if [ -z "$REPO" ] || [ ! -f "$REPO/scripts/rust-perf.sh" ]; then
  echo "ERROR: can't locate the Sky repo. cd into it, or set SKY_REPO=/path/to/sky." >&2; exit 2
fi
cd "$REPO"

# ── Env (the gotchas, baked in) ────────────────────────────────────────────
export PATH="$HOME/.ghcup/bin:$HOME/.cargo/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/sky-rust-target}"
command -v sccache >/dev/null 2>&1 && export RUSTC_WRAPPER="${RUSTC_WRAPPER:-sccache}"
export SKY_BIN="$REPO/sky-out/sky"
[ -x "$SKY_BIN" ] || { echo "ERROR: sky binary not at $SKY_BIN — build it (cabal build exe:sky)." >&2; exit 2; }
command -v go        >/dev/null 2>&1 || echo "WARN: 'go' not on PATH — the perf harness builds the Go backend; ratios may skip." >&2
command -v ab        >/dev/null 2>&1 || echo "WARN: 'ab' (apache-bench) missing — server/live throughput will skip." >&2
command -v hyperfine >/dev/null 2>&1 || echo "WARN: 'hyperfine' missing — cli cold-start will read 0." >&2
command -v python3   >/dev/null 2>&1 || { echo "ERROR: python3 required for the regression diff." >&2; exit 2; }
mkdir -p "$CARGO_TARGET_DIR"

HIST="$HOME/.cache/sky/perf-sweep"; mkdir -p "$HIST"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PERF_TSV="$HIST/perf-$STAMP.tsv"
LOG="$HIST/run-$STAMP.log"
say() { echo "$@" | tee -a "$LOG"; }
say "=== Sky Rust PERF sweep @ $STAMP (repo: $REPO) ==="

# ── Pre-flight hygiene: orphans skew perf + leak the process table ──────────
reap() { for p in hyperfine ab sse-bench sky-app app sky-console; do pkill -x "$p" 2>/dev/null; done
         pkill -f "examples/.*/sky-out/" 2>/dev/null; }
reap; sync; sleep 1

# ── Perf set (isolate app perf — no console spawn) ──────────────────────────
# Every both-backend perf-RUNNABLE example. EXCLUDED: tui/webview/fyne (need a
# TTY/window → hyperfine would hang), console/multi-tier (25/34 special spawn),
# Go-FFI-only 02. rust-perf.sh self-skips (exit 3) anything a backend can't
# build; each call is timeout-bounded + orphan-reaped.
#   RUST_PERF_QUICK=1        → 3-shape representative (fast).
#   RUST_PERF="a b c"        → explicit override.
PERF_FULL=(
  00-standard-libs 01-hello-world 04-local-pkg 06-json 07-todo-cli 14-task-demo
  20-cli-counter 35-composite-generics simple test_pkg
  15-http-server 30-sse-server-demo 32-sse-relay 33-websocket-echo
  09-live-counter 10-live-component 12-skyvote 16-skychess 17-skymon
  18-job-queue 19-skyforum 26-ui-showcase 27-multi-session-chat 28-streaming-chat
)
PERF_QUICK=(14-task-demo 15-http-server 09-live-counter)
if [ -n "${RUST_PERF:-}" ]; then read -r -a EXAMPLES <<< "$RUST_PERF"
elif [ -n "${RUST_PERF_QUICK:-}" ]; then EXAMPLES=("${PERF_QUICK[@]}")
else EXAMPLES=("${PERF_FULL[@]}"); fi

say ""; say ">>> PERF SWEEP  (SKY_CONSOLE_EMBED=off; ${#EXAMPLES[@]} examples)"
: > "$PERF_TSV"; SKIPPED=""
for ex in "${EXAMPLES[@]}"; do
  [ -f "examples/$ex/src/Main.sky" ] || { SKIPPED="$SKIPPED $ex(absent)"; continue; }
  say "  -- $ex --"
  OUT="$(SKY_CONSOLE_EMBED=off timeout --kill-after=30 600 bash scripts/rust-perf.sh "$ex" 2>&1)"; rc=$?
  reap
  printf '%s\n' "$OUT" >> "$LOG"
  N="$(printf '%s\n' "$OUT" | grep -E '^[[:space:]]+(rss|coldstart|binsize|throughput)[[:space:]]' | tee -a "$LOG" | \
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
    for ln in open(p):
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
  rm -rf "examples/$ex/sky-out" "examples/$ex/.skycache" "examples/$ex/.skydeps" 2>/dev/null
done
command -v go >/dev/null 2>&1 && go clean -cache >/dev/null 2>&1 || true
say ""; say "=== DONE: perf=$PERF_TSV · log=$LOG ==="
exit 0
