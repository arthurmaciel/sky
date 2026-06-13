#!/usr/bin/env bash
# Sky Rust-backend RUN sweep — build each runnable example on --target rust and
# RUN it, checking it actually works (cli: runs without a panic; server/live:
# boots + serves HTTP). Catches the runtime-regression class the build sweep
# misses (panics, dead servers, "the click is a no-op"). Build + perf are
# separate skills (/rust-build-sweep, /rust-perf-sweep).
#
# This script IS the procedure (the /rust-run-sweep skill). Do not re-decide the
# steps ad-hoc; if a run reveals a better way (a new gotcha, a port quirk,
# another shape), IMPROVE THIS SCRIPT so the next run inherits the fix.
#
# Exit: 0 = every example RUN-OK · 1 = a run/build failure · 2 = setup error.
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
export PATH="$HOME/.ghcup/bin:$HOME/.cargo/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/sky-rust-target}"  # shared; run right after build
command -v sccache >/dev/null 2>&1 && export RUSTC_WRAPPER="${RUSTC_WRAPPER:-sccache}"
export SKY_BIN="$REPO/sky-out/sky"
[ -x "$SKY_BIN" ] || { echo "ERROR: sky binary not at $SKY_BIN — build it (cabal build exe:sky)." >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl required for server/live checks." >&2; exit 2; }
# Don't spawn the console child while smoke-running (not what a run sweep checks).
export SKY_CONSOLE_EMBED=off
mkdir -p "$CARGO_TARGET_DIR"

HIST="$HOME/.cache/sky/rust-run-sweep"; mkdir -p "$HIST"
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

# ── Runnable set (cli one-shot / server / live). EXCLUDED: tui/webview/fyne ──
# (need a TTY/window), console/multi-tier (25/34 special spawn), Go-FFI 02.
# Same curated set as /rust-perf-sweep, for consistency.
#   RUST_RUN="a b c"  → explicit override.
RUN_FULL=(
  00-standard-libs 01-hello-world 04-local-pkg 06-json 07-todo-cli 14-task-demo
  20-cli-counter 35-composite-generics simple test_pkg
  15-http-server 30-sse-server-demo 32-sse-relay 33-websocket-echo
  09-live-counter 10-live-component 12-skyvote 16-skychess 17-skymon
  18-job-queue 19-skyforum 26-ui-showcase 27-multi-session-chat 28-streaming-chat
)
if [ -n "${RUST_RUN:-}" ]; then read -r -a EXAMPLES <<< "$RUST_RUN"; else EXAMPLES=("${RUN_FULL[@]}"); fi

shape_of() { # $1 = example dir
  local s="$1/src"
  if   grep -rqE "Std\.Tui|Tui\.app"        "$s" 2>/dev/null; then echo tui
  elif grep -rqE "Std\.Webview|Webview\.app" "$s" 2>/dev/null; then echo webview
  elif grep -rqE "Fyne"                      "$s" 2>/dev/null; then echo fyne
  elif grep -rqE "Std\.Live|Live\.app"       "$s" 2>/dev/null; then echo live
  elif grep -rqE "Server\.listen|Sky\.Http\.Server" "$s" 2>/dev/null; then echo server
  else echo cli; fi
}

PASS=0; FAIL=0; SKIP=0; FAILED=""
for ex in "${EXAMPLES[@]}"; do
  d="examples/$ex"; [ -f "$d/src/Main.sky" ] || { say "  SKIP   $ex (absent)"; SKIP=$((SKIP+1)); continue; }
  shape="$(shape_of "$d")"
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
      lp="$(grep -oiE "listening on[^0-9]*([0-9]+)" "$rl" | grep -oE "[0-9]+" | tail -1)"
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
