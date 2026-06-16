# shellcheck shell=bash
# runtime-rust/scripts/lib/examples.sh — SINGLE SOURCE OF TRUTH for the in-scope
# example manifest. SOURCE this (never execute it).
#
# Every sweep's example set + the example-shape classifier live ONLY here. When
# sync-with-upstream lands new examples — or we add fork-local fixtures as
# Go-parity tests — update ONLY this file; all sweeps follow (CLAUDE.md directive).
#
# Provides:
#   BUILD_GLOB       — the dirs the all-example BUILD sweep globs (build-level binning).
#   OUT_OF_SCOPE     — number/name exclusion list for the build sweep (recorded, not a target).
#   RUN_SET          — runnable cli/server/live examples (run-sweep).
#   PERF_SET         — perf-runnable examples; defaults to RUN_SET so they can't drift.
#   WEB_SET          — "example scenario" pairs the web-sweep drives (live/web).
#   example_shape <dir>  → tui|webview|fyne|server|live|cli
#   is_web_example <dir> → exit 0 if Sky.Live / Sky.Http.Server, else 1

# ── BUILD sweep: the largest set (build-level binning, in/out recorded) ──────
# Glob dirs the all-example build sweep walks. Each must carry src/Main.sky.
BUILD_GLOB=( examples/[0-9]*/ examples/simple/ examples/test_pkg/ )

# Out-of-scope on the Rust backend, recorded but NOT a build target. The numbers
# are matched against each example's leading digits. Reasons (preserved verbatim
# from rust-sweep.sh):
#  - no Rust monolith reference:                02 06 11 19 25 26 27 29 34 36 37 38
#  - Go-package→Rust-native FFI examples (per user 2026-06-10, NOT a goal — they
#    import Go packages like gorilla/mux, stripe-go, google/uuid, godotenv): 03 05 08 13
# 19-skyforum + 26-ui-showcase now build on Rust (Std.Ui parity work) — in scope.
# 24-tui-kitchen-sink (multibackend Live+Tui main) builds via the #24 entry-model
# refactor — in scope. 21/22/23 (pure-Tui) un-gated by the same refactor (their
# `Tui.app |> Task.run` main now block_on's). 31-webview-stopwatch-ui builds via
# the Webview view:any carrier fix (stub backend) — in scope.
OUT_OF_SCOPE=" 02 03 05 06 08 11 13 25 27 29 34 36 37 38 "

# ── RUN sweep: runnable set (cli one-shot / server / live) ───────────────────
# EXCLUDED by shape at run time: tui/webview/fyne (need a TTY/window),
# console/multi-tier (25/34 special spawn), Go-FFI 02.
RUN_SET=(
  00-standard-libs 01-hello-world 04-local-pkg 06-json 07-todo-cli 14-task-demo
  20-cli-counter 35-composite-generics simple test_pkg
  15-http-server 30-sse-server-demo 32-sse-relay 33-websocket-echo
  09-live-counter 10-live-component 12-skyvote 16-skychess 17-skymon
  18-job-queue 19-skyforum 26-ui-showcase 27-multi-session-chat 28-streaming-chat
)

# ── PERF sweep: defaults to RUN_SET so the two can't drift ───────────────────
# Override here (a separate array) if the perf set ever needs to diverge from the
# run set; until then they're the same curated both-backend-runnable examples.
PERF_SET=( "${RUN_SET[@]}" )

# ── WEB sweep: "example scenario" pairs (live/web round-trip) ────────────────
# Web RULE: an example is web-drivable iff it is a Sky.Live / Sky.Http.Server app
# (is_web_example below) AND has a maintained round-trip scenario in
# scripts/verify-scenarios.mjs. The scenario key matches the Go-backend
# verify-all-web.sh. One pair per line: "<example-dir> <scenario>".
WEB_SET=(
  "09-live-counter live-counter"
  "10-live-component live-component"
  "12-skyvote skyvote"
  "16-skychess skychess"
  "17-skymon skymon"
  "18-job-queue job-queue"
  "19-skyforum skyforum"
)

# ── Classifier: example shape from its Sky source ────────────────────────────
# $1 = example dir (e.g. examples/09-live-counter). Order matters: a Live app may
# also import Server, so Live/Tui/Webview/Fyne are tested before the Server/cli
# fallthrough. This is the ONE place the shape grep lives.
example_shape() {
  local s="$1/src"
  if   grep -rqE "Std\.Tui|Tui\.app"                 "$s" 2>/dev/null; then echo tui
  elif grep -rqE "Std\.Webview|Webview\.app"          "$s" 2>/dev/null; then echo webview
  elif grep -rqE "Fyne"                               "$s" 2>/dev/null; then echo fyne
  elif grep -rqE "Std\.Live|Live\.app"                "$s" 2>/dev/null; then echo live
  elif grep -rqE "Server\.listen|Sky\.Http\.Server"   "$s" 2>/dev/null; then echo server
  else echo cli; fi
}

# is_web_example <dir> — predicate (exit status) for the web RULE above:
# a Sky.Live OR Sky.Http.Server app. Used by keep-go-parity to flag NEW web examples.
is_web_example() {
  grep -rqE "Std\.Live|Live\.app|Server\.listen|Sky\.Http\.Server" "$1/src" 2>/dev/null
}
