# shellcheck shell=bash
# runtime-rust/scripts/lib/checks.sh — SINGLE SOURCE OF TRUTH for the per-shape
# "exercise an already-built binary" logic. SOURCE this (never execute it):
#   source "$(dirname "$0")/lib/checks.sh"
#
# WHY THIS FILE EXISTS. Two sweeps need to drive a built binary per shape:
#   • run-sweep  — exercise the RUST binary, assert it works headless.
#   • build-sweep — exercise BOTH the Go and the Rust binary, assert EQUIVALENCE
#     (same stdout for cli; both pass the same browser scenario for live; both
#     boot for server; both no-crash for tui/webview).
# The exercise logic (boot a server + poll, drive a pty, run an xvfb smoke, drive
# the browser round-trip) is identical regardless of WHICH backend produced the
# binary. Extracting it here means run-sweep and build-sweep share ONE definition
# of "did this binary work?" — they can't drift, and a harness fix lands once.
#
# CONTRACT. Every `exercise_*` takes an already-built, executable binary path and
# a logfile path, runs the binary, writes its stdout+stderr to the logfile, and
# returns 0=pass / 1=fail. They never build, never diff — the caller owns that.
#
# Depends on lib/env.sh being sourced first (CARGO_TARGET_DIR, SKY_BIN, PATH) —
# the sweep runners source env.sh, then examples.sh, then this. It is idempotent
# and side-effect-light at source time (only exports + a browser-stack probe).

# ── Shared exercise env (both sweeps inherit it from here) ──────────────────
# Don't spawn the console child while smoke-running (not what these checks
# assert; an in-process Go console vs a cross-process Rust console child would
# otherwise be a spurious divergence — the equiv modes assert APP behaviour).
export SKY_CONSOLE_EMBED="${SKY_CONSOLE_EMBED:-off}"
# Server/live examples that use Std.Auth refuse to boot without a >=32-byte
# secret (CORRECT production behaviour — see 36-composite-server's startup gate).
# Provide a test secret so those apps boot on BOTH backends; honoured only if the
# caller hasn't set their own.
export SKY_AUTH_TOKEN_SECRET="${SKY_AUTH_TOKEN_SECRET:-sky-run-sweep-test-secret-0123456789-abcdef}"

# ── Panic detection (shared) ────────────────────────────────────────────────
# A Rust panic / abort string in a binary's output = a soundness failure (the
# whole reason the Rust backend exists). Go panics surface the same way, so the
# pattern catches both backends' aborts.
PANIC_RE="panicked|CompilerBug|RUST_BACKTRACE|index out of bounds|unwrap\(\) on|called .Result::unwrap|goroutine [0-9]+ \[|runtime error:"

# ── http_responds <code>: any real HTTP status (100-599) = serving ──────────
# 000 = connection refused / timeout = NOT serving. Accepts an API server with
# no `GET /` route (404 on / still proves the listener + router are up) — needing
# exactly 200 false-failed such apps (e.g. 36-composite-server).
http_responds() { case "$1" in [1-5][0-9][0-9]) return 0;; *) return 1;; esac; }

# ── free_port: an ephemeral free TCP port (fallback 8743) ───────────────────
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()' 2>/dev/null || echo 8743; }

# ── reap: kill stray app / console / driver / Xvfb processes between examples ─
reap() { for p in sky-app app sky-console; do pkill -x "$p" 2>/dev/null; done
         pkill -f "examples/.*/sky-out/" 2>/dev/null; pkill -f web-verify.mjs 2>/dev/null
         pkill -x Xvfb 2>/dev/null; }

# ── Browser-round-trip stack probe (shared) ─────────────────────────────────
# node lives under nvm; chromium is the system binary. Prepend node's bin so the
# driver resolves. If any piece is absent, WEB_OK=0 and exercise_live degrades to
# a server boot check (logged by the caller), so the sweeps still work browser-less.
NODE_BIN="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -1)"
export PATH="${NODE_BIN:+$NODE_BIN:}$PATH"
export SKY_CHROMIUM="${SKY_CHROMIUM:-/usr/bin/chromium}"
DRIVER="${DRIVER:-$REPO/runtime-rust/scripts/web-verify.mjs}"
SCENARIOS="${SCENARIOS:-$REPO/scripts/verify-scenarios.mjs}"
WEB_OK=1
command -v node >/dev/null 2>&1          || WEB_OK=0
[ -x "$SKY_CHROMIUM" ]                    || WEB_OK=0
[ -f "$DRIVER" ]                          || WEB_OK=0
[ -d "$REPO/node_modules/playwright" ]    || WEB_OK=0

# ── scenario_for <example-name>: the browser scenario key for an example ────
# verify-scenarios.mjs keys follow the example name with the leading NN- prefix
# stripped (09-live-counter → live-counter). If that key isn't defined, fall back
# to `smoke`.
scenario_for() {
  local ex="$1" key
  key="$(echo "$ex" | sed -E 's/^[0-9]+-//')"
  if [ -f "$SCENARIOS" ] && rg -q "async '?${key}'?\(" "$SCENARIOS" 2>/dev/null; then
    echo "$key"
  else
    echo smoke
  fi
}

# ── resolve_bin <example-dir>: the freshest Rust binary just built for it ────
# The shared CARGO_TARGET_DIR/debug/ holds the LAST-built binary. Most examples'
# generated package is named `sky-app`, but an examples/rust/* project's package
# is named after its dir (skyshop-rs → binary `skyshop-rs`). So: prefer the
# per-example package binary if the project pins a name, then sky-app in the
# shared target, then the newest executable in the shared target, then the
# per-example target. Echoes the resolved path (may be empty if none found).
resolve_bin() {
  local d="$1" name b
  name="$(rg -No '^name\s*=\s*"([^"]+)"' -r '$1' "$d/sky.toml" 2>/dev/null | head -1)"
  for b in \
    "$CARGO_TARGET_DIR/debug/$name" \
    "$CARGO_TARGET_DIR/debug/sky-app" \
    "$d/sky-out/Rust/target/debug/$name" \
    "$d/sky-out/Rust/target/debug/sky-app"; do
    [ -n "$b" ] && [ -x "$b" ] && [ ! -d "$b" ] && { echo "$b"; return 0; }
  done
  # Last resort: newest executable file in either target/debug.
  b="$(find "$CARGO_TARGET_DIR/debug" "$d/sky-out/Rust/target/debug" -maxdepth 1 -type f -executable 2>/dev/null \
        | xargs -r ls -t 2>/dev/null | head -1)"
  [ -n "$b" ] && { echo "$b"; return 0; }
  return 1
}

# ── browser_drivable <example-dir>: can web-verify.mjs locate this example? ──
# The driver hardcodes cwd = repoRoot/examples/<name>, so it only works for a
# TOP-LEVEL examples/<name> dir. An examples/rust/<name> live app builds + serves
# but the driver can't find its dir → drive it as a server boot check instead.
browser_drivable() { case "$1" in examples/rust/*) return 1;; *) return 0;; esac; }

# ════════════════════════════════════════════════════════════════════════════
# exercise_* — drive an already-built binary per shape. 0=pass / 1=fail.
# Each writes the binary's stdout+stderr to <logfile>.
# ════════════════════════════════════════════════════════════════════════════

# exercise_cli <bin> <logfile> [timeout]
# Run under a timeout. FAIL on panic OR hang (timeout's 124). A non-zero exit
# that isn't 124 is NOT a failure by itself (a cli may exit non-zero by design,
# e.g. System.exit n) — the gate is panic/hang. Stdout+stderr → logfile.
exercise_cli() {
  local bin="$1" log="$2" tmo="${3:-25}" rc
  timeout "$tmo" "$bin" >"$log" 2>&1 </dev/null; rc=$?
  if   [ "$rc" = 124 ]; then return 1
  elif grep -qiE "$PANIC_RE" "$log"; then return 1
  fi
  return 0
}

# exercise_server <bin> <port> <logfile>
# Boot with SKY_LIVE_PORT/PORT, wait (≤15 s) for ANY HTTP status via
# http_responds (sniffing a "listening on :PORT" log if it bound a different
# port), then SIGTERM/SIGKILL. FAIL on panic OR never-served. Server
# stdout+stderr → logfile.
#
# ISOLATED CWD: the binary runs in a fresh ephemeral dir so any cwd-relative
# state (a `./*.db` sqlite file, a session store) is born clean each invocation.
# Without this, a server example that migrates a schema on boot (36-composite-
# server writes ./composite-server.db) fails its SECOND boot with "table already
# exists" — and in build-sweep the Go boot and the Rust boot would collide on the
# same file. A unique cwd makes both repeat-runs and Go-vs-Rust boots independent.
exercise_server() {
  local bin="$1" port="$2" log="$3" pid i code lp code2 ok="" run_dir abin
  abin="$(cd "$(dirname "$bin")" && pwd)/$(basename "$bin")"   # absolutise before we cd away
  run_dir="$(mktemp -d "${TMPDIR:-/tmp}/sky-serve.XXXXXX")"
  # </dev/null seals stdin so the server can't drain a caller's example pipe.
  ( cd "$run_dir" && exec env SKY_LIVE_PORT="$port" PORT="$port" "$abin" ) >"$log" 2>&1 </dev/null &
  pid=$!
  for i in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || break
    code="$(curl -s -o /dev/null -m 1 -w '%{http_code}' "http://127.0.0.1:$port/" 2>/dev/null || true)"
    http_responds "$code" && { ok=1; break; }
    # Some servers bind a port from their source, not SKY_LIVE_PORT — sniff the
    # log. Take the LAST ":port" on the listening line so "0.0.0.0:8000" yields
    # 8000, not the leading 0.
    lp="$(grep -iE "listening on" "$log" | grep -oE ":[0-9]+" | tail -1 | tr -d ':')"
    if [ -n "$lp" ] && [ "$lp" != "$port" ]; then
      code2="$(curl -s -o /dev/null -m 1 -w '%{http_code}' "http://127.0.0.1:$lp/" 2>/dev/null || true)"
      http_responds "$code2" && { ok=1; break; }
    fi
    sleep 0.5
  done
  kill -TERM "$pid" 2>/dev/null; sleep 0.5; kill -KILL "$pid" 2>/dev/null
  rm -rf "$run_dir" 2>/dev/null
  if grep -qiE "$PANIC_RE" "$log"; then return 1; fi
  [ -n "$ok" ] && return 0 || return 1
}

# exercise_live <bin> <example-name> <port> <scenario> <logfile>
# Drive the browser ROUND-TRIP via web-verify.mjs (the "click is a no-op" gate);
# pass iff the driver exits 0. When the browser stack is absent (WEB_OK=0), fall
# back to exercise_server (boot check) so the sweep still works browser-less.
# Driver stdout+stderr → logfile.
exercise_live() {
  local bin="$1" ex="$2" port="$3" scen="$4" log="$5" abin
  # web-verify.mjs spawns the binary with cwd = the example dir, so a RELATIVE
  # path (e.g. Go's `examples/09-live-counter/sky-out/app`) would resolve against
  # that cwd and ENOENT. Absolutise it first.
  abin="$bin"; case "$bin" in /*) ;; *) abin="$(cd "$(dirname "$bin")" 2>/dev/null && pwd)/$(basename "$bin")";; esac
  if [ "$WEB_OK" = 1 ]; then
    node "$DRIVER" "$ex" "$port" "$scen" "$abin" >"$log" 2>&1
    return $?
  fi
  exercise_server "$abin" "$port" "$log"
}

# exercise_tui <bin> <logfile>
# PTY smoke: `script` allocates a real pty so the TUI sees a terminal (a TUI that
# checks isatty would bail "not a tty" otherwise). PASS if it starts + exits
# within the window without a panic AND without a "no terminal" complaint.
# timeout's exit 124 (we cut it off) is EXPECTED for a TUI waiting on input.
# STDIN SEALED (`</dev/null`): `script` reads from stdin — without this it would
# DRAIN the caller's stdin, which in build-sweep is the `< <(build_set)` example
# pipe, silently ending the loop after the first tui example. (run-sweep reads
# into an array first so it never hit this; build-sweep loops the pipe directly.)
exercise_tui() {
  local bin="$1" log="$2"
  script -qec "timeout 8 '$bin'" /dev/null >"$log" 2>&1 </dev/null
  if   grep -qiE "$PANIC_RE" "$log"; then return 1
  elif grep -qiE "not a tty|inappropriate ioctl|TERM environment" "$log"; then return 1
  fi
  return 0
}

# exercise_webview <bin> <logfile>
# XVFB smoke: a headless X server so the webview window can open. PASS on
# no-crash within the window. (Caller is responsible for SKIPping when xvfb-run
# is absent — it's a separately-installed env dep, not a failure.)
exercise_webview() {
  local bin="$1" log="$2"
  xvfb-run -a timeout 8 "$bin" >"$log" 2>&1 </dev/null
  grep -qiE "$PANIC_RE" "$log" && return 1
  return 0
}
