#!/usr/bin/env bash
# Sky Rust-backend RUN sweep — build each in-scope example on --target rust and
# RUN it headlessly, checking it actually works. DERIVED set (run_set from
# lib/examples.sh): every example minus Go-FFI; NOTHING excluded by shape. The
# run dispatches per shape so tui / webview / live all run with no human at a
# terminal:
#   cli      → run under `timeout`; FAIL on panic / hang.
#   server   → boot, `GET / → any HTTP status`, kill.
#   live     → boot; if web-drivable, drive the browser ROUND-TRIP via
#              web-verify.mjs (the "click is a no-op" gate); else treat as server.
#   tui      → PTY smoke via `script` (allocates a real pty so the TUI sees a
#              terminal); PASS if it starts + exits without panic.
#   webview  → XVFB smoke (`xvfb-run`); PASS on no-crash. xvfb-run MISSING → SKIP
#              with a note (it's a separately-installed env dep, NOT a failure).
#   fyne     → won't occur (Go-FFI excluded); if it does, SKIP with a note.
#
# The per-shape "exercise a binary" logic lives in lib/checks.sh — the SHARED
# SINGLE SOURCE OF TRUTH this sweep and build-sweep (equivalence) both consume.
# This script owns the BUILD + dispatch; checks.sh owns "did the binary work?".
#
# This script IS the procedure (the /run-sweep skill). Do not re-decide the
# steps ad-hoc; if a run reveals a better way (a new gotcha, a port quirk,
# another shape), IMPROVE checks.sh (the exercise) or THIS SCRIPT (the dispatch).
#
# Exit: 0 = every example RUN-OK · 1 = a run/build failure · 2 = setup error.
set -uo pipefail

# ── Env + manifest + shared checks (SINGLE SOURCE OF TRUTH under lib/) ───────
source "$(dirname "$0")/lib/env.sh"
source "$(dirname "$0")/lib/examples.sh"
source "$(dirname "$0")/lib/checks.sh"
if [ -z "$REPO" ] || [ ! -d "$REPO/examples" ]; then
  echo "ERROR: can't locate the Sky repo. cd into it, or set SKY_REPO=/path/to/sky." >&2; exit 2
fi
cd "$REPO"
[ -x "$SKY_BIN" ] || { echo "ERROR: sky binary not at $SKY_BIN — build it (cabal build exe:sky)." >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl required for server/live checks." >&2; exit 2; }

HIST="$HOME/.cache/sky/run-sweep"; mkdir -p "$HIST"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$HIST/run-$STAMP.log"
say() { echo "$@" | tee -a "$LOG"; }
say "=== Sky Rust RUN sweep @ $STAMP (repo: $REPO) ==="
[ "$WEB_OK" = 1 ] || say "  NOTE: browser stack incomplete (node/chromium/playwright/web-verify) — live/web examples fall back to a server boot check."

ps -u "$USER" -o pid,args 2>/dev/null | awk '/\/sky (lsp|doc)/{print $1}' | xargs -r kill 2>/dev/null
reap; sync; sleep 1

# ── Runnable set: run_set (derived; Go-FFI absent, no shape exclusion). ──────
#   RUST_RUN="00-standard-libs 09-live-counter"  → explicit override (paths or names).
EXAMPLES=()
if [ -n "${RUST_RUN:-}" ]; then
  read -r -a EXAMPLES <<< "$RUST_RUN"
else
  while IFS= read -r d; do EXAMPLES+=("$d"); done < <(run_set)
fi

PASS=0; FAIL=0; SKIP=0; FAILED=""
for entry in "${EXAMPLES[@]}"; do
  # run_set emits real dirs (examples/… or examples/rust/…). A RUST_RUN override
  # may pass a bare name; resolve it to the real dir.
  if [ -d "$entry" ]; then d="${entry%/}"; else d="examples/${entry#examples/}"; d="${d%/}"; fi
  ex="$(basename "$d")"
  [ -f "$d/src/Main.sky" ] || { say "  SKIP   $ex (absent: $d)"; SKIP=$((SKIP+1)); continue; }
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
  bin="$(resolve_bin "$d")"
  [ -n "$bin" ] && [ -x "$bin" ] || { say "  BUILD-FAIL $ex (no binary)"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(nobin)"; continue; }

  rl="$HIST/$ex.run.log"
  case "$shape" in
    cli)
      if exercise_cli "$bin" "$rl"; then say "  RUN-OK    $ex (cli)"; PASS=$((PASS+1))
      elif grep -qiE "$PANIC_RE" "$rl"; then say "  RUN-FAIL  $ex (cli panicked)"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(panic)"
      else say "  RUN-FAIL  $ex (cli timed out — hang)"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(hang)"; fi
      ;;

    tui)
      if exercise_tui "$bin" "$rl"; then say "  RUN-OK    $ex (tui pty smoke)"; PASS=$((PASS+1))
      elif grep -qiE "not a tty|inappropriate ioctl|TERM environment" "$rl"; then say "  RUN-FAIL  $ex (tui: no terminal allocated)"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(notty)"
      else say "  RUN-FAIL  $ex (tui panicked)"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(panic)"; fi
      ;;

    webview)
      if exercise_webview "$bin" "$rl"; then say "  RUN-OK    $ex (webview xvfb smoke)"; PASS=$((PASS+1))
      else say "  RUN-FAIL  $ex (webview panicked)"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(panic)"; fi
      ;;

    live|server)
      port="$(free_port)"
      # A web-drivable live example gets the FULL browser round-trip; a headless
      # HTTP server (or a live app the driver can't locate, e.g. examples/rust/*,
      # or the browser stack absent) gets the boot check.
      if [ "$shape" = live ] && is_web_example "$d" && browser_drivable "$d"; then
        scen="$(scenario_for "$ex")"
        if exercise_live "$bin" "$ex" "$port" "$scen" "$rl"; then
          say "  RUN-OK    $ex (live browser round-trip, scenario $scen)"; PASS=$((PASS+1))
        else
          say "  RUN-FAIL  $ex (live browser: $(grep -m1 '^FAIL' "$rl" | sed 's/^FAIL [^ ]* — //'))"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(web)"
        fi
      else
        if exercise_server "$bin" "$port" "$rl"; then say "  RUN-OK    $ex ($shape serves :$port)"; PASS=$((PASS+1))
        elif grep -qiE "$PANIC_RE" "$rl"; then say "  RUN-FAIL  $ex ($shape panicked)"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(panic)"
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
