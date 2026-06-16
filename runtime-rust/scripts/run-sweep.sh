#!/usr/bin/env bash
# Sky Rust-backend RUN sweep — build each runnable example on --target rust and
# RUN it, checking it actually works (cli: runs without a panic; server/live:
# boots + serves HTTP). Catches the runtime-regression class the build sweep
# misses (panics, dead servers, "the click is a no-op"). Build + perf are
# separate skills (/build-sweep, /perf-sweep).
#
# This script IS the procedure (the /run-sweep skill). Do not re-decide the
# steps ad-hoc; if a run reveals a better way (a new gotcha, a port quirk,
# another shape), IMPROVE THIS SCRIPT so the next run inherits the fix.
#
# Exit: 0 = every example RUN-OK · 1 = a run/build failure · 2 = setup error.
set -uo pipefail

# ── Env + manifest (shared SINGLE SOURCE OF TRUTH under lib/) ───────────────
source "$(dirname "$0")/lib/env.sh"
source "$(dirname "$0")/lib/examples.sh"
if [ -z "$REPO" ] || [ ! -d "$REPO/examples" ]; then
  echo "ERROR: can't locate the Sky repo. cd into it, or set SKY_REPO=/path/to/sky." >&2; exit 2
fi
cd "$REPO"
[ -x "$SKY_BIN" ] || { echo "ERROR: sky binary not at $SKY_BIN — build it (cabal build exe:sky)." >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl required for server/live checks." >&2; exit 2; }
# Don't spawn the console child while smoke-running (not what a run sweep checks).
export SKY_CONSOLE_EMBED=off

HIST="$HOME/.cache/sky/run-sweep"; mkdir -p "$HIST"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$HIST/run-$STAMP.log"
say() { echo "$@" | tee -a "$LOG"; }
say "=== Sky Rust RUN sweep @ $STAMP (repo: $REPO) ==="

reap() { for p in sky-app app sky-console; do pkill -x "$p" 2>/dev/null; done
         pkill -f "examples/.*/sky-out/" 2>/dev/null; }
ps -u "$USER" -o pid,args 2>/dev/null | awk '/\/sky (lsp|doc)/{print $1}' | xargs -r kill 2>/dev/null
reap; sync; sleep 1

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()' 2>/dev/null || echo 8743; }
PANIC_RE="panicked|CompilerBug|RUST_BACKTRACE|index out of bounds|unwrap\(\) on|called .Result::unwrap"

# ── Runnable set (RUN_SET, from lib/examples.sh). EXCLUDED at run time:
# tui/webview/fyne (need a TTY/window), console/multi-tier (25/34 special spawn),
# Go-FFI 02. Same curated set as /perf-sweep, for consistency.
#   RUST_RUN="a b c"  → explicit override.
if [ -n "${RUST_RUN:-}" ]; then read -r -a EXAMPLES <<< "$RUST_RUN"; else EXAMPLES=("${RUN_SET[@]}"); fi

PASS=0; FAIL=0; SKIP=0; FAILED=""
for ex in "${EXAMPLES[@]}"; do
  d="examples/$ex"; [ -f "$d/src/Main.sky" ] || { say "  SKIP   $ex (absent)"; SKIP=$((SKIP+1)); continue; }
  shape="$(example_shape "$d")"
  case "$shape" in tui|webview|fyne) say "  SKIP   $ex ($shape — needs TTY/window)"; SKIP=$((SKIP+1)); continue;; esac

  # Build (run right after, while the shared target binary is this example's).
  ( cd "$d" && rm -rf sky-out .skycache .skydeps && timeout 240 "$SKY_BIN" build src/Main.sky --target rust ) \
    >"$HIST/$ex.build.log" 2>&1
  if [ "$(cd "$d" && timeout 600 cargo build --manifest-path sky-out/Rust/Cargo.toml -q >>"$HIST/$ex.build.log" 2>&1; echo $?)" != 0 ]; then
    say "  BUILD-FAIL $ex"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(build)"; ( cd "$d" && rm -rf sky-out .skycache .skydeps ); continue
  fi
  bin="$CARGO_TARGET_DIR/debug/sky-app"; [ -x "$bin" ] || bin="$d/sky-out/Rust/target/debug/sky-app"
  [ -x "$bin" ] || { say "  BUILD-FAIL $ex (no binary)"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(nobin)"; continue; }

  rl="$HIST/$ex.run.log"
  if [ "$shape" = cli ]; then
    timeout 25 "$bin" >"$rl" 2>&1; rc=$?
    if   [ "$rc" = 124 ]; then say "  RUN-FAIL  $ex (cli timed out — hang)"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(hang)"
    elif grep -qiE "$PANIC_RE" "$rl"; then say "  RUN-FAIL  $ex (cli panicked)"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(panic)"
    else say "  RUN-OK    $ex (cli, exit $rc)"; PASS=$((PASS+1)); fi
  else
    port="$(free_port)"
    SKY_LIVE_PORT="$port" PORT="$port" "$bin" >"$rl" 2>&1 &
    pid=$!
    ok=""; for i in $(seq 1 30); do
      kill -0 "$pid" 2>/dev/null || break
      code="$(curl -s -o /dev/null -m 1 -w '%{http_code}' "http://127.0.0.1:$port/" 2>/dev/null || true)"
      [ "$code" = 200 ] && { ok=1; break; }
      # some servers bind a port from their source, not SKY_LIVE_PORT — sniff the log.
      # Take the LAST ":port" on the listening line: a "listening on
      # http://0.0.0.0:8000" log must yield 8000, not the leading 0 of 0.0.0.0
      # (the old "[^0-9]*([0-9]+)" captured that 0 → curl :0 → false noserve).
      lp="$(grep -iE "listening on" "$rl" | grep -oE ":[0-9]+" | tail -1 | tr -d ':')"
      if [ -n "$lp" ] && [ "$lp" != "$port" ]; then
        curl -s -o /dev/null -m 1 -w '%{http_code}' "http://127.0.0.1:$lp/" 2>/dev/null | grep -q 200 && { ok=1; port="$lp"; break; }
      fi
      sleep 0.5
    done
    body="$(curl -s -m 2 "http://127.0.0.1:$port/" 2>/dev/null | head -c 64)"
    kill -TERM "$pid" 2>/dev/null; sleep 0.5; kill -KILL "$pid" 2>/dev/null
    if   grep -qiE "$PANIC_RE" "$rl"; then say "  RUN-FAIL  $ex ($shape panicked)"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(panic)"
    elif [ -n "$ok" ] && [ -n "$body" ]; then say "  RUN-OK    $ex ($shape serves :$port)"; PASS=$((PASS+1))
    else say "  RUN-FAIL  $ex ($shape didn't serve)"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(noserve)"; fi
  fi
  reap
  ( cd "$d" && rm -rf sky-out .skycache .skydeps )
done

reap
say ""; say "=== RUN SWEEP: $PASS ran-OK · $FAIL failed · $SKIP skipped ==="
[ -n "$FAILED" ] && say "  failures:$FAILED"
say "  per-example logs: $HIST/<ex>.{build,run}.log"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
