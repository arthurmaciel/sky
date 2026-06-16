# shellcheck shell=bash
# runtime-rust/scripts/lib/examples.sh — SINGLE SOURCE OF TRUTH for the example
# manifest. SOURCE this (never execute it).
#
# DERIVED, NOT HARDCODED. There are no static example arrays here: every set is
# computed at call time from the example dirs on disk + their Sky source. When
# sync-with-upstream lands new examples they are picked up automatically — the
# ONLY thing that excludes an example is Go-FFI (a `[go.dependencies]` section in
# its sky.toml), because the Rust backend does not bind Go packages. Everything
# else is IN SCOPE: a greenfield example that has never built on Rust SURFACES as
# a real failure rather than being silently filtered out (user decision).
#
# Provides (all FUNCTIONS — call them, don't read arrays):
#   all_examples            → every candidate example dir, one per line (no trailing /).
#   is_out_of_scope <dir>   → exit 0 IFF Go-FFI (sky.toml has [go.dependencies]).
#   is_web_example  <dir>   → exit 0 IFF Sky.Live / Sky.Http.Server (browser-drivable).
#   example_shape   <dir>   → tui|webview|fyne|server|live|cli
#   build_set               → all_examples − Go-FFI (the BUILD sweep set).
#   run_set                 → == build_set (tui/webview now RUN headless; nothing
#                             excluded by shape).
#   perf_set                → == build_set (same set; perf picks sensible metrics
#                             per shape, no throughput for tui/webview/cli).

# ── all_examples: every candidate dir on disk, trailing slash stripped ───────
# examples/[0-9]*/  (numbered)  + examples/simple/ + examples/test_pkg/ +
# examples/rust/*/  (fork-local real Sky projects). One per line. Only dirs that
# actually carry a src/Main.sky entry point are emitted.
all_examples() {
  local d
  for d in examples/[0-9]*/ examples/simple/ examples/test_pkg/ examples/rust/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    [ -f "$d/src/Main.sky" ] || continue
    printf '%s\n' "$d"
  done
}

# ── is_out_of_scope <dir>: the ONLY exclusion is Go-FFI ──────────────────────
# Return 0 (exclude) IFF the example's sky.toml declares a Go-package dependency
# section. Matches both bare `[go.dependencies]` and quoted `["go.dependencies"]`.
# Nothing else is excluded — greenfield gaps are real failures, not exclusions.
is_out_of_scope() {
  local toml="$1/sky.toml"
  [ -f "$toml" ] || return 1
  rg -q '^\["?go\.dependencies' "$toml" 2>/dev/null
}

# ── is_web_example <dir>: Sky.Live OR Sky.Http.Server (browser-drivable) ─────
# NB: ripgrep recurses by default — do NOT pass `-r` (that is rg's --replace, not
# recurse). Comment-stripped (via _shape_match) so prose doesn't false-positive.
is_web_example() {
  _shape_match "$1/src" 'Std\.Live|Live\.app|Server\.listen|Sky\.Http\.Server'
}

# ── example_shape <dir>: tui|webview|fyne|server|live|cli ────────────────────
# Order matters: a Live app may also import Server, so Tui/Webview/Fyne/Live are
# tested before the Server/cli fallthrough. This is the ONE place the shape grep
# lives. (rg recurses by default; `-r` is --replace, never use it here.)
#
# `_shape_match <src-dir> <regex>` strips Sky line comments (`--…`) from every
# matching line before re-testing, so a doc comment like "calls Webview.app
# instead of Tui.app" doesn't misclassify a webview app as tui
# (31-webview-stopwatch-ui hit exactly this — its header comment names Tui.app).
# Matches the real `import <Mod>` / `<Mod>.app` / `<Backend>.listen` code, not prose.
_shape_match() { # $1=src dir  $2=regex
  rg --no-filename -e "$2" "$1" 2>/dev/null | sed 's/--.*$//' | rg -q -e "$2" 2>/dev/null
}
example_shape() {
  local s="$1/src"
  if   _shape_match "$s" 'Std\.Tui|Tui\.app';               then echo tui
  elif _shape_match "$s" 'Std\.Webview|Webview\.app';        then echo webview
  elif _shape_match "$s" 'Fyne';                             then echo fyne
  elif _shape_match "$s" 'Std\.Live|Live\.app';              then echo live
  elif _shape_match "$s" 'Server\.listen|Sky\.Http\.Server'; then echo server
  else echo cli; fi
}

# ── build_set: all_examples minus Go-FFI ─────────────────────────────────────
build_set() {
  local d
  while IFS= read -r d; do
    is_out_of_scope "$d" && continue
    printf '%s\n' "$d"
  done < <(all_examples)
}

# ── run_set / perf_set: identical to build_set ───────────────────────────────
# No shape exclusion — tui (pty) / webview (xvfb) / live (browser round-trip) all
# RUN headless now. perf_set is the same set; perf-sweep chooses sensible metrics
# per shape (throughput only for server/live).
run_set()  { build_set; }
perf_set() { build_set; }
