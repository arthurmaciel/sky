#!/usr/bin/env bash
# Sky Rust-backend RUN sweep — build each in-scope example on --target rust and
# RUN it headlessly, checking it actually works. DERIVED set (run_set from
# lib/examples.sh): every example minus Go-FFI; NOTHING excluded by shape. The
# run dispatches per shape so tui / webview / live all run with no human at a
# terminal:
#   cli      → run under `timeout`; FAIL on panic / non-zero / hang.
#   server   → boot, `curl GET / → 200`, kill.
#   live     → boot; if web-drivable, drive the browser ROUND-TRIP via
#              web-verify.mjs (the "click is a no-op" gate); else treat as server.
#   tui      → PTY smoke via `script` (allocates a real pty so the TUI sees a
#              terminal); PASS if it starts + exits without panic.
#   webview  → XVFB smoke (`xvfb-run`); PASS on no-crash. xvfb-run MISSING → SKIP
#              with a note (it's a separately-installed env dep, NOT a failure).
#   fyne     → won't occur (Go-FFI excluded); if it does, SKIP with a note.
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
# Server/live examples that use Std.Auth refuse to boot without a >=32-byte secret
# (CORRECT production behaviour — see 36-composite-server's startup gate). Provide a
# test secret so those apps boot; honoured only if the caller hasn't set their own.
export SKY_AUTH_TOKEN_SECRET="${SKY_AUTH_TOKEN_SECRET:-sky-run-sweep-test-secret-0123456789-abcdef}"

# ── Browser-round-trip driver (for web/live examples) ───────────────────────
# node lives under nvm; chromium is the system binary. Prepend node's bin so the
# driver resolves. If any of these are absent, the live-web path degrades to a
# curl boot check (logged), so the sweep still works without a browser stack.
NODE_BIN="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -1)"
export PATH="${NODE_BIN:+$NODE_BIN:}$PATH"
export SKY_CHROMIUM="${SKY_CHROMIUM:-/usr/bin/chromium}"
DRIVER="$REPO/runtime-rust/scripts/web-verify.mjs"
SCENARIOS="$REPO/scripts/verify-scenarios.mjs"
WEB_OK=1
command -v node >/dev/null 2>&1 || WEB_OK=0
[ -x "$SKY_CHROMIUM" ]                 || WEB_OK=0
[ -f "$DRIVER" ]                       || WEB_OK=0
[ -d "$REPO/node_modules/playwright" ] || WEB_OK=0

HIST="$HOME/.cache/sky/run-sweep"; mkdir -p "$HIST"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$HIST/run-$STAMP.log"
say() { echo "$@" | tee -a "$LOG"; }
say "=== Sky Rust RUN sweep @ $STAMP (repo: $REPO) ==="
[ "$WEB_OK" = 1 ] || say "  NOTE: browser stack incomplete (node/chromium/playwright/web-verify) — live/web examples fall back to a curl boot check."

reap() { for p in sky-app app sky-console; do pkill -x "$p" 2>/dev/null; done
         pkill -f "examples/.*/sky-out/" 2>/dev/null; pkill -f web-verify.mjs 2>/dev/null
         pkill -x Xvfb 2>/dev/null; }
ps -u "$USER" -o pid,args 2>/dev/null | awk '/\/sky (lsp|doc)/{print $1}' | xargs -r kill 2>/dev/null
reap; sync; sleep 1

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()' 2>/dev/null || echo 8743; }
PANIC_RE="panicked|CompilerBug|RUST_BACKTRACE|index out of bounds|unwrap\(\) on|called .Result::unwrap"
# A server is "serving" if it returns ANY real HTTP status (curl's %{http_code} in
# 100-599). 000 = connection refused / timeout = NOT serving. This accepts an API
# server with no `GET /` route (404 on / still proves the listener + router are up)
# — requiring exactly 200 false-failed such apps (e.g. 36-composite-server).
http_responds() { case "$1" in [1-5][0-9][0-9]) return 0;; *) return 1;; esac; }

# Resolve a browser scenario for an example. The repo's verify-scenarios.mjs keys
# follow the example name with the leading NN- prefix stripped (09-live-counter →
# live-counter). If that key isn't a defined scenario, fall back to `smoke`.
scenario_for() {
  local ex="$1" key
  key="$(echo "$ex" | sed -E 's/^[0-9]+-//')"
  if [ -f "$SCENARIOS" ] && rg -q "async '?${key}'?\(" "$SCENARIOS" 2>/dev/null; then
    echo "$key"
  else
    echo smoke
  fi
}

# ── Runnable set: run_set (derived; Go-FFI absent, no shape exclusion). ──────
#   RUST_RUN="00-standard-libs 09-live-counter"  → explicit override (names or dirs).
EXAMPLES=()
if [ -n "${RUST_RUN:-}" ]; then
  read -r -a EXAMPLES <<< "$RUST_RUN"
else
  while IFS= read -r d; do EXAMPLES+=("$(basename "$d")"); done < <(run_set)
fi

PASS=0; FAIL=0; SKIP=0; FAILED=""
for ex in "${EXAMPLES[@]}"; do
  ex="${ex#examples/}"; ex="${ex%/}"
  d="examples/$ex"; [ -f "$d/src/Main.sky" ] || { say "  SKIP   $ex (absent)"; SKIP=$((SKIP+1)); continue; }
  shape="$(example_shape "$d")"

  # webview needs xvfb; if it's missing, SKIP cleanly (separately-installed dep).
  if [ "$shape" = webview ] && ! command -v xvfb-run >/dev/null 2>&1; then
    say "  SKIP   $ex (webview: SKIP (install xvfb to run headless))"; SKIP=$((SKIP+1)); continue
  fi
  if [ "$shape" = fyne ]; then
    say "  SKIP   $ex (fyne: Go-FFI shape — not a Rust-backend target)"; SKIP=$((SKIP+1)); continue
  fi

  # Build (run right after, while the shared target binary is this example's).
  ( cd "$d" && rm -rf sky-out .skycache .skydeps && timeout 240 "$SKY_BIN" build src/Main.sky --target rust ) \
    >"$HIST/$ex.build.log" 2>&1
  if [ "$(cd "$d" && timeout 600 cargo build --manifest-path sky-out/Rust/Cargo.toml -q >>"$HIST/$ex.build.log" 2>&1; echo $?)" != 0 ]; then
    say "  BUILD-FAIL $ex ($shape)"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(build)"; ( cd "$d" && rm -rf sky-out .skycache .skydeps ); continue
  fi
  bin="$CARGO_TARGET_DIR/debug/sky-app"; [ -x "$bin" ] || bin="$d/sky-out/Rust/target/debug/sky-app"
  [ -x "$bin" ] || { say "  BUILD-FAIL $ex (no binary)"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(nobin)"; continue; }

  rl="$HIST/$ex.run.log"
  case "$shape" in
    cli)
      timeout 25 "$bin" >"$rl" 2>&1; rc=$?
      if   [ "$rc" = 124 ]; then say "  RUN-FAIL  $ex (cli timed out — hang)"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(hang)"
      elif grep -qiE "$PANIC_RE" "$rl"; then say "  RUN-FAIL  $ex (cli panicked)"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(panic)"
      else say "  RUN-OK    $ex (cli, exit $rc)"; PASS=$((PASS+1)); fi
      ;;

    tui)
      # PTY smoke: `script` allocates a real pty so the TUI sees a terminal (a TUI
      # that checks isatty would otherwise bail "not a tty"). PASS if it starts +
      # exits within the window without a panic. timeout's exit 124 (we cut it off)
      # is EXPECTED for a TUI that waits for input — not a failure.
      script -qec "timeout 8 '$bin'" /dev/null >"$rl" 2>&1; rc=$?
      if   grep -qiE "$PANIC_RE" "$rl"; then say "  RUN-FAIL  $ex (tui panicked)"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(panic)"
      elif grep -qiE "not a tty|inappropriate ioctl|TERM environment" "$rl"; then say "  RUN-FAIL  $ex (tui: no terminal allocated)"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(notty)"
      else say "  RUN-OK    $ex (tui pty smoke, exit $rc)"; PASS=$((PASS+1)); fi
      ;;

    webview)
      # XVFB smoke: a headless X server so the webview window can open. PASS on
      # no-crash within the window.
      xvfb-run -a timeout 8 "$bin" >"$rl" 2>&1; rc=$?
      if   grep -qiE "$PANIC_RE" "$rl"; then say "  RUN-FAIL  $ex (webview panicked)"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(panic)"
      else say "  RUN-OK    $ex (webview xvfb smoke, exit $rc)"; PASS=$((PASS+1)); fi
      ;;

    live|server)
      port="$(free_port)"
      # A web-drivable live example gets the FULL browser round-trip; a headless
      # HTTP server (or live with the browser stack absent) gets the curl boot check.
      if [ "$shape" = live ] && [ "$WEB_OK" = 1 ] && is_web_example "$d"; then
        scen="$(scenario_for "$ex")"
        if node "$DRIVER" "$ex" "$port" "$scen" "$bin" >"$rl" 2>&1; then
          say "  RUN-OK    $ex (live browser round-trip, scenario $scen)"; PASS=$((PASS+1))
        else
          say "  RUN-FAIL  $ex (live browser: $(grep -m1 '^FAIL' "$rl" | sed 's/^FAIL [^ ]* — //'))"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(web)"
        fi
      else
        SKY_LIVE_PORT="$port" PORT="$port" "$bin" >"$rl" 2>&1 &
        pid=$!
        ok=""; for i in $(seq 1 30); do
          kill -0 "$pid" 2>/dev/null || break
          code="$(curl -s -o /dev/null -m 1 -w '%{http_code}' "http://127.0.0.1:$port/" 2>/dev/null || true)"
          http_responds "$code" && { ok=1; break; }
          # some servers bind a port from their source, not SKY_LIVE_PORT — sniff
          # the log. Take the LAST ":port" on the listening line so "0.0.0.0:8000"
          # yields 8000, not the leading 0.
          lp="$(grep -iE "listening on" "$rl" | grep -oE ":[0-9]+" | tail -1 | tr -d ':')"
          if [ -n "$lp" ] && [ "$lp" != "$port" ]; then
            code2="$(curl -s -o /dev/null -m 1 -w '%{http_code}' "http://127.0.0.1:$lp/" 2>/dev/null || true)"
            http_responds "$code2" && { ok=1; port="$lp"; break; }
          fi
          sleep 0.5
        done
        kill -TERM "$pid" 2>/dev/null; sleep 0.5; kill -KILL "$pid" 2>/dev/null
        if   grep -qiE "$PANIC_RE" "$rl"; then say "  RUN-FAIL  $ex ($shape panicked)"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(panic)"
        elif [ -n "$ok" ]; then say "  RUN-OK    $ex ($shape serves :$port)"; PASS=$((PASS+1))
        else say "  RUN-FAIL  $ex ($shape didn't serve)"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(noserve)"; fi
      fi
      ;;
  esac
  reap
  ( cd "$d" && rm -rf sky-out .skycache .skydeps )
done

reap
say ""; say "=== RUN SWEEP: $PASS ran-OK · $FAIL failed · $SKIP skipped ==="
[ -n "$FAILED" ] && say "  failures:$FAILED"
say "  per-example logs: $HIST/<ex>.{build,run}.log"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
