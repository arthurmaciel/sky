# shellcheck shell=bash
# runtime-rust/scripts/lib/examples.sh — SINGLE SOURCE OF TRUTH for the example
# manifest. SOURCE this (never execute it).
#
# DERIVED, NOT HARDCODED. There are no static example arrays here: every set is
# computed at call time from the example dirs on disk + their Sky source. When
# sync-with-upstream lands new examples they are picked up automatically — the
# ONLY thing that excludes an example is Go-FFI, because the Rust backend does not
# bind Go packages. Everything else is IN SCOPE: a greenfield example that has
# never built on Rust SURFACES as a real failure rather than being silently
# filtered out (user decision).
#
# THE GO-FFI SIGNAL IS THE IMPORT, NOT `[go.dependencies]`. A `[go.dependencies]`
# section over-excludes: examples whose go-deps are STDLIB-TRANSITIVE from a Sky
# stdlib module (07-todo-cli pulls os/log/slog via Std.Db/Std.Log; 16-skychess /
# 17-skymon pull crypto/sha256 via Sky.Core.Crypto; 02-go-stdlib pulls
# net/http+time+crypto/sha256 via Sky.Core.Http/Time/Crypto) BUILD FINE on Rust —
# `--target rust` ignores `[go.dependencies]` entirely. The real Go-FFI tell is a
# Sky `import` of a Go-PACKAGE module — one that resolves to neither a Sky stdlib
# module nor a local project `.sky` file (`Github.Com.…`, `Net.Http`, `Fyne.…`).
#
# Provides (all FUNCTIONS — call them, don't read arrays):
#   all_examples            → every candidate example dir, one per line (no trailing /).
#   is_out_of_scope <dir>   → exit 0 IFF Go-FFI (imports an unresolvable Go-pkg module).
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

# ── is_out_of_scope <dir>: the ONLY exclusion is Go-FFI (IMPORT signal) ──────
# Return 0 (exclude) IFF the example imports a Go-PACKAGE module: a Sky `import`
# whose module name resolves to NEITHER a Sky stdlib module NOR a local project
# `.sky` file. `[go.dependencies]` in sky.toml is NOT consulted — it over-excludes
# (stdlib-transitive deps like os/crypto/sha256 carry a [go.dependencies] but
# build fine on Rust). The recursive `.sky` walk is load-bearing: 08-notes-app /
# 13-skyshop hide their `Github.Com.…`/`Net.Http`/`Fyne.…` imports inside Lib.*
# submodules, not Main.sky.
#
# Module-name resolution (every `import X` / `import X as Y` / `import X exposing
# (..)` — rg captures the dotted name only):
#   • prefix Sky. / Std.                  → Sky stdlib       → IN scope
#   • prefix Rust.                         → Rust-FFI wrapper crate (from
#       [rust.dependencies], e.g. `Rust.Sky_firestore_shim`) → IN scope. This is
#       the WHOLE POINT of the Rust backend — never a Go package; keeps
#       examples/rust/skyshop-rs in scope.
#   • dotted name suffix-matches a sky-stdlib/**/<X>.sky      → IN scope
#       (bare/partial stdlib imports: `import System` → Sky.Core.System,
#        `import Server` → Sky.Http.Server, `import Head` → Std.Live.Head)
#   • dotted name resolves to a `.sky` anywhere under the project → IN (local mod)
#   • otherwise (`Github.Com.Google.Uuid`, `Net.Http`, `Fyne.…`) → Go-FFI → OUT
#
# rg flag care: `--no-filename`/`-I` suppresses filenames (`-h` is rg's --help,
# NOT no-filename). `-N`/`--no-line-number` + `-o`/`--only-matching` + `-r`/
# `--replace` capture just the module name. rg recurses by default; we drive the
# file list via `find … -exec rg … +` so the walk covers every `.sky` under src/.
is_out_of_scope() {
  local dir="$1" m rel
  while read -r m; do
    [ -z "$m" ] && continue
    case "$m" in Sky.*|Std.*|Rust.*) continue ;; esac # Sky stdlib / Rust-FFI wrapper → in scope
    rel="${m//.//}"
    # Sky stdlib imported by a bare/partial name (suffix-match in sky-stdlib).
    if find sky-stdlib -type f -path "*/${rel}.sky" 2>/dev/null | grep -q .; then continue; fi
    # Local module → a `.sky` for it exists somewhere under the project.
    if find "$dir" -type f -path "*/${rel}.sky" 2>/dev/null | grep -q .; then continue; fi
    return 0                                          # unresolvable → Go-package → OUT
  done < <(find "$dir/src" -type f -name '*.sky' -exec \
             rg --no-filename -No '^[[:space:]]*import[[:space:]]+([A-Za-z0-9_.]+)' -r '$1' {} + 2>/dev/null)
  return 1                                            # every import resolved → in scope
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

# ── build_set: all_examples minus Go-FFI (unresolvable-import examples) ──────
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
