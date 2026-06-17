# shellcheck shell=bash
# runtime-rust/scripts/lib/checks.sh — SINGLE SOURCE OF TRUTH for the per-shape
# "exercise an already-built binary" logic. SOURCE this (never execute it):
#   source "$(dirname "$0")/lib/checks.sh"
#
# WHY THIS FILE EXISTS. examples-sweep drives a built binary per shape TWICE —
#   • RUN   — exercise the RUST binary, assert it works headless.
#   • EQUIV — exercise BOTH the Go and the Rust binary, assert EQUIVALENCE
#     (byte-diff stdout for cli; byte-diff comparable GET-route bodies for server;
#     both pass the same browser scenario for live; both no-crash for tui).
# The exercise logic (boot a server + poll, drive a pty, run an xvfb smoke, drive
# the browser round-trip, body-compare two servers) is identical regardless of
# WHICH backend produced the binary. Extracting it here means RUN and EQUIV share
# ONE definition of "did this binary work?" — they can't drift, a fix lands once.
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
# Suppress the dev-mode floating console link too: Go injects a `__sky-dev-console`
# <a> into every page, Rust does not — that dev chrome would spuriously DIFFER the
# body-equiv comparison of the APP's own HTML. Off on both → fair comparison.
export SKY_DEV_BANNER="${SKY_DEV_BANNER:-off}"
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

# ── Host OS detection (shared) ───────────────────────────────────────────────
# Some exercise shapes (pty for tui, headless display for webview) are inherently
# host-specific. `SKY_HOST_OS` is computed ONCE here and consumed by the OS-aware
# branches below so the SAME checks.sh drives Linux / macOS / Windows-Git-Bash.
#   linux   → GNU coreutils: `script -qec`, `xvfb-run`, `pkill -x` — TODAY'S code.
#   macos   → BSD `script -q /dev/null cmd`, a real display (no xvfb), `pkill`.
#   windows → Git Bash / MSYS: no pty (`script`), no `xvfb-run`, no `pkill -x`.
# IMPORTANT: on Linux this resolves to `linux` so every OS-branch falls through to
# the byte-identical pre-existing code path — Linux behaviour is unchanged.
case "${OSTYPE:-}" in
  linux*)            SKY_HOST_OS=linux   ;;
  darwin*)           SKY_HOST_OS=macos   ;;
  msys*|cygwin*|win*) SKY_HOST_OS=windows ;;
  *)
    # $OSTYPE is a bash builtin; fall back to `uname` if it was unset/odd.
    case "$(uname -s 2>/dev/null)" in
      Linux)                       SKY_HOST_OS=linux   ;;
      Darwin)                      SKY_HOST_OS=macos   ;;
      MINGW*|MSYS*|CYGWIN*|Windows_NT) SKY_HOST_OS=windows ;;
      *)                           SKY_HOST_OS=linux   ;;  # safe default: today's path
    esac
    ;;
esac
export SKY_HOST_OS

# ── EXERCISE_SKIP_RC: the rc an exercise_* returns when this HOST can't run the
# shape at all (no pty / no display) — distinct from 0 (pass) and 1 (fail) so the
# caller can record SKIP, never a false pass and never a red fail. 125 is unused
# by the binaries we run (timeout uses 124/125-on-bad-invoke is avoided; we only
# emit it ourselves). The sweep's run_for/equiv_for SHOULD map this rc to a `skip`
# cell — see the note in examples-sweep.sh. Callers that don't yet branch on it
# treat it as a non-zero (fail-safe: a SKIP shown as a fail is loud, not silent).
EXERCISE_SKIP_RC=125

# ── night_guard <sweep-name>: defer the heavy sweeps to the night window ─────
# These sweeps build + run the whole example set (cargo + Go + browser) — heavy
# enough to wedge this slim shared box during the day. Gate them to a low-load
# window 22:00–08:00 America/Sao_Paulo (the user's TZ). Outside the window AND
# SKY_SWEEP_FORCE unset → print a deferral message and exit 2 (the CALLER inherits
# this exit because night_guard runs in the caller's shell, not a subshell). Inside
# the window OR SKY_SWEEP_FORCE=1 → return 0 and the sweep proceeds.
night_guard() {
  local sweep="${1:-sweep}" hour
  [ -n "${SKY_SWEEP_FORCE:-}" ] && return 0
  hour="$(TZ=America/Sao_Paulo date +%H 2>/dev/null)"
  hour="$((10#${hour:-12}))"   # strip a leading 0 so 08 isn't read as octal
  if [ "$hour" -ge 22 ] || [ "$hour" -lt 8 ]; then return 0; fi
  echo "deferred: $sweep runs 22:00–08:00 America/Sao_Paulo (slim machine); set SKY_SWEEP_FORCE=1 to override" >&2
  exit 2
}

# ── http_responds <code>: any real HTTP status (100-599) = serving ──────────
# 000 = connection refused / timeout = NOT serving. Accepts an API server with
# no `GET /` route (404 on / still proves the listener + router are up) — needing
# exactly 200 false-failed such apps (e.g. 36-composite-server).
http_responds() { case "$1" in [1-5][0-9][0-9]) return 0;; *) return 1;; esac; }

# ── free_port: an ephemeral free TCP port (fallback 8743) ───────────────────
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()' 2>/dev/null || echo 8743; }

# ── reap: kill stray app / console / driver / Xvfb processes between examples ─
# `pkill` is absent on Windows Git Bash (no procps). Guard the whole body on its
# presence so a reap on Windows is a clean no-op rather than a "command not found"
# per call. On Linux/macOS `pkill` is present → byte-identical behaviour.
reap() {
  command -v pkill >/dev/null 2>&1 || return 0
  for p in sky-app app sky-console; do pkill -x "$p" 2>/dev/null; done
  pkill -f "examples/.*/sky-out/" 2>/dev/null; pkill -f web-verify.mjs 2>/dev/null
  pkill -x Xvfb 2>/dev/null
}

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
  local bin="$1" log="$2" tmo="${3:-25}" rc tries=0
  # A freshly-built/copied binary can be ETXTBSY (the builder's write fd not yet
  # released) → exec fails 126 "Text file busy" (locale-dependent text), which
  # would be captured as the program's "output" and false-DIFFER against the
  # other backend. Retry briefly until it's executable.
  while :; do
    timeout "$tmo" "$bin" >"$log" 2>&1 </dev/null; rc=$?
    { [ "$rc" = 126 ] || grep -qiE 'text file busy|texto ocupada|ETXTBSY' "$log" 2>/dev/null; } || break
    tries=$((tries+1)); [ "$tries" -ge 10 ] && break; sync; sleep 0.4
  done
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
# exists" — and in examples-sweep's EQUIV the Go boot and the Rust boot would
# collide on the same file. A unique cwd makes both repeat-runs and Go-vs-Rust
# boots independent.
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
# DRAIN the caller's stdin. examples-sweep reads the example list into an array
# first (not a live pipe), so the loop can't be ended early; sealing stdin here is
# the belt-and-braces second line of defence regardless of how the caller loops.
# OS-AWARE: `script` allocates the pty, but its CLI differs by platform —
#   linux (util-linux): script -qec "CMD" /dev/null   ← command via -c
#   macos (BSD):        script -q  /dev/null CMD ARGS  ← command as trailing argv
# Windows Git Bash ships NO `script`, but it DOES ship `winpty` (the pre-ConPTY
# pty shim bundled with Git for Windows) — that gives the Tui app a real pty so
# its isatty() check passes. We use it instead of SKIPping. The Linux branch is
# the default and is byte-identical to the pre-existing line.
exercise_tui() {
  local bin="$1" log="$2"
  case "$SKY_HOST_OS" in
    macos)
      # BSD script: command + args follow the typescript file (/dev/null here).
      if command -v script >/dev/null 2>&1; then
        script -q /dev/null timeout 8 "$bin" >"$log" 2>&1 </dev/null
      else
        printf 'SKIP (macos: no `script` for pty)\n' >"$log"; return "$EXERCISE_SKIP_RC"
      fi
      ;;
    windows)
      # `winpty` (bundled with Git for Windows) allocates a pty for the Tui app.
      # timeout -k 5 escalates to SIGKILL for a tui that ignores SIGTERM.
      if command -v winpty >/dev/null 2>&1; then
        timeout -k 5 8 winpty "$bin" >"$log" 2>&1 </dev/null
      else
        printf 'SKIP (windows: winpty not found)\n' >"$log"; return "$EXERCISE_SKIP_RC"
      fi
      ;;
    *)
      # linux (and any util-linux host) — unchanged.
      script -qec "timeout 8 '$bin'" /dev/null >"$log" 2>&1 </dev/null
      ;;
  esac
  if   grep -qiE "$PANIC_RE" "$log"; then return 1
  elif grep -qiE "not a tty|inappropriate ioctl|TERM environment" "$log"; then return 1
  fi
  return 0
}

# exercise_webview <bin> <logfile>
# OS-AWARE headless smoke of a webview window. PASS on no-crash within the window.
#   linux   → xvfb-run -a (headless X server); SKIP if xvfb-run absent (env dep,
#             not a failure) — preserves the pre-existing contract where run_for
#             SKIPs when xvfb-run is missing.
#   macos   → a real display is present (WKWebView); run directly. If headless
#             (no $DISPLAY-equivalent / CI without a session) the window may not
#             open — we still gate purely on no-panic, same as Linux.
#   windows → no xvfb (X11) is needed: the windows-latest runner has an
#             interactive desktop session + the WebView2 runtime preinstalled, so
#             a wry/WebView2 app constructs its window. Run directly (like macOS),
#             with `-k` so a GUI .exe that ignores SIGTERM is SIGKILL'd. Gate on
#             no-panic. (Was a conservative hard-SKIP; the session + WebView2 make
#             a real run possible — confirmed by CI.)
# Returns EXERCISE_SKIP_RC when the host genuinely can't run it (so the caller can
# record SKIP). The Linux xvfb path is byte-identical to before.
exercise_webview() {
  local bin="$1" log="$2"
  case "$SKY_HOST_OS" in
    macos)
      timeout 8 "$bin" >"$log" 2>&1 </dev/null
      ;;
    windows)
      # GUI .exe may ignore SIGTERM → `-k 5` escalates to SIGKILL 5s later.
      timeout -k 5 8 "$bin" >"$log" 2>&1 </dev/null
      ;;
    *)
      # linux — unchanged; caller still owns the xvfb-run-absent SKIP, but guard
      # here too so a direct call degrades to SKIP instead of "command not found".
      if ! command -v xvfb-run >/dev/null 2>&1; then
        printf 'SKIP (linux: xvfb-run not installed)\n' >"$log"; return "$EXERCISE_SKIP_RC"
      fi
      xvfb-run -a timeout 8 "$bin" >"$log" 2>&1 </dev/null
      ;;
  esac
  grep -qiE "$PANIC_RE" "$log" && return 1
  return 0
}

# ── _boot_server_at <bin> <port> <run_dir> <log> → echoes the PID it spawned ─
# Boot a server binary in an ISOLATED cwd (so cwd-relative DB/session files of the
# Go boot and the Rust boot never collide), waiting ≤15 s for ANY HTTP status on
# <port>. Echoes the PID on stdout if it came up serving; empty + non-zero if not.
# Caller is responsible for killing the PID and removing run_dir. Mirrors
# exercise_server's boot logic but keeps the process alive for body comparison.
# Boot a server binary; on success echo "PID:PORT" where PORT is the port it
# ACTUALLY bound (a raw Sky.Http.Server `Server.listen N` hardcodes its port and
# ignores the SKY_LIVE_PORT/PORT override, so we sniff the real port from the
# "listening on …:N" log line, mirroring run-sweep's exercise_server). Empty echo
# + non-zero on failure.
_boot_server_at() {
  local bin="$1" port="$2" run_dir="$3" log="$4" abin pid i code lp
  abin="$(cd "$(dirname "$bin")" 2>/dev/null && pwd)/$(basename "$bin")"
  ( cd "$run_dir" && exec env SKY_LIVE_PORT="$port" PORT="$port" "$abin" ) >"$log" 2>&1 </dev/null &
  pid=$!
  for i in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || { echo ""; return 1; }
    code="$(curl -s -o /dev/null -m 1 -w '%{http_code}' "http://127.0.0.1:$port/" 2>/dev/null || true)"
    http_responds "$code" && { echo "$pid:$port"; return 0; }
    # Sniff the actually-bound port (hardcoded `Server.listen N` ignores the env).
    lp="$(grep -iE "listening on" "$log" 2>/dev/null | grep -oE ':[0-9]+' | tail -1 | tr -d ':')"
    if [ -n "$lp" ] && [ "$lp" != "$port" ]; then
      code="$(curl -s -o /dev/null -m 1 -w '%{http_code}' "http://127.0.0.1:$lp/" 2>/dev/null || true)"
      http_responds "$code" && { echo "$pid:$lp"; return 0; }
    fi
    sleep 0.5
  done
  echo ""; return 1
}

# ── exercise_server_equiv <go_bin> <rust_bin> <example_dir> <port_base> <log> ─
# SERVER body-equivalence: boot Go and Rust on separate ports (isolated cwds) and
# byte-compare the response bodies of each comparable GET route. PRINTS a result
# token to stdout:
#   equiv-body N   ≥1 comparable route compared, ALL byte-identical (N = count).
#   equiv-serve    0 comparable routes but BOTH booted + served (honest floor).
#   DIFFER         a route's body differs Go-vs-Rust (route + diff noted in log).
#   go-ref-broken  the Go reference did not boot+serve (upstream Go bug, AMBER).
#   rust-broken    the Rust binary did not boot+serve.
# Comparable routes: literal GET routes (`Server.get "/lit"`), MINUS param routes
# (contain `:`), MINUS streaming (basename in events/stream/sse/relay/upstream OR
# curl doesn't return within 2 s), MINUS WebSocket (basename `ws` or path has `ws`).
# `/` is always included. For each route, Go is curled TWICE — if its own body is
# non-deterministic (run-to-run differ) the route is SKIPPED (no false DIFFER).
exercise_server_equiv() {
  local go_bin="$1" rust_bin="$2" dir="$3" log="$4"
  local gport rport grun rrun gpid rpid route routes=() comparable=() n=0 verdict=""
  gport="$(free_port)"; rport="$(free_port)"
  [ "$gport" = "$rport" ] && rport=$((rport + 1))
  grun="$(mktemp -d "${TMPDIR:-/tmp}/sky-eqv-go.XXXXXX")"
  rrun="$(mktemp -d "${TMPDIR:-/tmp}/sky-eqv-rs.XXXXXX")"
  : >"$log"

  # 1) Discover literal GET routes from the Sky source (route LITERALS only).
  routes=()
  while IFS= read -r route; do [ -n "$route" ] && routes+=("$route"); done < <(
    rg --no-filename -No 'Server\.get[[:space:]]+"([^"]*)"' -r '$1' "$dir"/src 2>/dev/null | sort -u)
  # Always include `/`.
  case " ${routes[*]} " in *" / "*) ;; *) routes=("/" "${routes[@]}");; esac

  # 2) Filter to COMPARABLE routes (drop param/streaming/ws).
  for route in "${routes[@]}"; do
    case "$route" in
      *:*) continue ;;                              # param route — needs a value
      */ws|*ws/*|*/ws/*) continue ;;               # websocket path
    esac
    case "$(basename "$route")" in
      ws|events|stream|sse|relay|upstream) continue ;;  # streaming/ws by name
    esac
    comparable+=("$route")
  done

  # 3) Boot Go, capture each comparable route's body (skip nondeterministic /
  #    streaming), then KILL Go BEFORE booting Rust. Sequential boot means an
  #    example that hardcodes `Server.listen N` on BOTH backends can't collide
  #    on that port — only one server is ever up at a time.
  local gboot gpid gp route
  gboot="$(_boot_server_at "$go_bin" "$gport" "$grun" "$log.go")"
  gpid="${gboot%%:*}"; gp="${gboot##*:}"
  if [ -z "$gpid" ]; then
    grep -qiE "$PANIC_RE" "$log.go" 2>/dev/null
    rm -rf "$grun" "$rrun"; cat "$log.go" >>"$log" 2>/dev/null
    echo "go-ref-broken"; return 0
  fi
  local -A gobody=()
  for route in "${comparable[@]}"; do
    local g1 g2 t0 t1 gcode
    # Skip routes the app does not actually serve (Go 404) — `/` is always probed
    # but an API-only server has no root route; comparing default 404 error pages
    # is not app-equivalence.
    gcode="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$gp$route" 2>/dev/null || true)"
    [ "$gcode" = 404 ] && { printf 'SKIP (Go 404 — route not served) %s\n' "$route" >>"$log"; continue; }
    # Time the first Go fetch: a route that doesn't return within ~2 s is an
    # undetected stream (the -m 2 curl timed out) → skip rather than DIFFER.
    t0="$(date +%s%N)"
    g1="$(curl -s -m 2 "http://127.0.0.1:$gp$route" 2>/dev/null)" || { printf 'SKIP (no-response) %s\n' "$route" >>"$log"; continue; }
    t1="$(date +%s%N)"
    if [ "$(( (t1 - t0) / 1000000 ))" -ge 1900 ]; then printf 'SKIP (slow/streaming) %s\n' "$route" >>"$log"; continue; fi
    g2="$(curl -s -m 2 "http://127.0.0.1:$gp$route" 2>/dev/null)"
    if [ "$g1" != "$g2" ]; then printf 'SKIP (nondeterministic) %s\n' "$route" >>"$log"; continue; fi
    gobody["$route"]="$g1"
  done
  kill -TERM "$gpid" 2>/dev/null; sleep 0.3; kill -KILL "$gpid" 2>/dev/null

  # 4) Boot Rust, byte-compare each captured route.
  local rboot rpid rp
  rboot="$(_boot_server_at "$rust_bin" "$rport" "$rrun" "$log.rs")"
  rpid="${rboot%%:*}"; rp="${rboot##*:}"
  if [ -z "$rpid" ]; then
    rm -rf "$grun" "$rrun"; cat "$log.rs" >>"$log" 2>/dev/null
    echo "rust-broken"; return 0
  fi
  for route in "${!gobody[@]}"; do
    local r1
    r1="$(curl -s -m 2 "http://127.0.0.1:$rp$route" 2>/dev/null)"
    if [ "${gobody[$route]}" = "$r1" ]; then
      n=$((n + 1)); printf 'MATCH %s\n' "$route" >>"$log"
    else
      printf 'DIFFER %s\n  go:   %s\n  rust: %s\n' "$route" "${gobody[$route]:0:200}" "${r1:0:200}" >>"$log"
      verdict="DIFFER"
    fi
  done
  kill -TERM "$rpid" 2>/dev/null; sleep 0.3; kill -KILL "$rpid" 2>/dev/null
  rm -rf "$grun" "$rrun"

  if [ -n "$verdict" ]; then echo "DIFFER"; return 0; fi
  if [ "$n" -ge 1 ]; then echo "equiv-body $n"; return 0; fi
  echo "equiv-serve"; return 0   # 0 comparable routes — both booted (floor)
}
