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
# `--backend rust` ignores `[go.dependencies]` entirely. The real Go-FFI tell is a
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
# ── _build_stdlib_index: ONE-TIME in-memory index of sky-stdlib module paths ──
# is_out_of_scope is called once per example and, pre-index, ran a FULL
# `find sky-stdlib` tree walk PER import just to suffix-match a bare/partial
# stdlib name. sky-stdlib does not change during a sweep, so the walk is done
# ONCE here: every `/`-delimited suffix of each module path (minus `.sky`) is
# recorded as a key, reproducing the old `-path "*/<rel>.sky"` glob as an O(1)
# associative-array lookup. `declare -gA` (no `=()`) leaves an already-built
# index intact across a re-source; the BUILT flag is the real idempotency guard.
declare -gA _SKY_STDLIB_INDEX
_build_stdlib_index() {
  [ -n "${_SKY_STDLIB_INDEX_BUILT:-}" ] && return 0
  local f rest
  while IFS= read -r f; do
    rest="${f%.sky}"
    while :; do
      _SKY_STDLIB_INDEX["$rest"]=1
      case "$rest" in
        */*) rest="${rest#*/}" ;;
        *)   break ;;
      esac
    done
  done < <(find sky-stdlib -type f -name '*.sky' 2>/dev/null)
  _SKY_STDLIB_INDEX_BUILT=1
}

is_out_of_scope() {
  local dir="$1" m rel localpaths localdone=""
  # Explicit out-of-scope: skyshop-rs is the heavyweight real-world FFI proof
  # (firestore + async-stripe via fork-local wrapper crates). Its generated Rust
  # FFI bindings are NOT committed (`.skycache/ffi/rust` is gitignored), so a CI
  # build must run `cargo +nightly rustdoc` over those crates WITH network — a
  # long, flaky introspection unsuited to the per-commit gate. It is verified
  # locally via `examples/rust/skyshop-rs/verify.sh` instead.
  case "$dir" in */skyshop-rs) return 0 ;; esac
  _build_stdlib_index
  while read -r m; do
    [ -z "$m" ] && continue
    case "$m" in Sky.*|Std.*|Rust.*) continue ;; esac # Sky stdlib / Rust-FFI wrapper → in scope
    rel="${m//.//}"
    # Sky stdlib imported by a bare/partial name (in-memory suffix index).
    [ -n "${_SKY_STDLIB_INDEX[$rel]:-}" ] && continue
    # Local module → a `.sky` for it exists somewhere under the project. The dir
    # walk is done at most ONCE per example, lazily on the first unresolved
    # import (all-stdlib examples never pay for it). `rel` is `[A-Za-z0-9_/]`
    # only (dots → slashes, no glob metachars), so the case-glob is a safe
    # equivalent of the old `-path "*/<rel>.sky"`.
    if [ -z "$localdone" ]; then
      localpaths=$'\n'"$(find "$dir" -type f -name '*.sky' 2>/dev/null)"$'\n'
      localdone=1
    fi
    case "$localpaths" in *"/${rel}.sky"$'\n'*) continue ;; esac
    return 0                                          # unresolvable → Go-package → OUT
  done < <(find "$dir/src" -type f -name '*.sky' -exec \
             rg --no-filename -No '^[[:space:]]*import[[:space:]]+([A-Za-z0-9_.]+)' -r '$1' {} + 2>/dev/null)
  return 1                                            # every import resolved → in scope
}

# ── is_live_network_cli <name>: a cli whose RUN makes a LIVE EXTERNAL call ───
# A cli that issues a real HTTP request to a third-party host (not localhost) has
# a non-deterministic, network-dependent RUN that can HANG on a CI runner with
# flaky egress (Windows especially). A hang there is a host/network artifact, NOT
# a Rust defect (the same binary runs fine where egress is healthy), so its
# RUN-hang degrades to SKIP (green-neutral) instead of a flaky red. EXPLICIT,
# documented set — not a heuristic — so it can never silently mask a real hang in
# a non-network example. 02-go-stdlib (a Go-stdlib-FFI demo) GETs a live URL and
# is already pinned `n/a` for equiv as "non-deterministic / live HTTP".
is_live_network_cli() {
  case "$1" in
    02-go-stdlib) return 0 ;;
  esac
  return 1
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
  # Memoized: build_set is deterministic from disk within a process, and a single
  # changed_examples call fans out into it up to three times (broad branch +
  # representative_floor + _intersect_build_set); run_set/perf_set add more.
  # Compute once, replay the cached lines on every later call in the same process.
  if [ -n "${_SKY_BUILD_SET+x}" ]; then printf '%s' "$_SKY_BUILD_SET"; return 0; fi
  local d out=""
  while IFS= read -r d; do
    is_out_of_scope "$d" && continue
    out+="$d"$'\n'
  done < <(all_examples)
  _SKY_BUILD_SET="$out"
  printf '%s' "$out"
}

# ── run_set / perf_set: identical to build_set ───────────────────────────────
# No shape exclusion — tui (pty) / webview (xvfb) / live (browser round-trip) all
# RUN headless now. perf_set is the same set; examples-perf-sweep chooses sensible
# metrics per shape (throughput only for server/live).
run_set()  { build_set; }
perf_set() { build_set; }

# ── changed_examples <base> — scope a local sweep to a diff's blast radius ────
# Per the keep-go-parity v2 spec (§C): partition `git diff <base>..HEAD` into the
# example dirs worth sweeping LOCALLY. Precise only for example-source changes;
# runtime/codegen changes widen broadly (CI's full 3-OS sweep is the real gate).
# All pieces are DERIVED from disk + skydex — no hardcoded example lists.

# representative_floor: one in-scope example per shape (cli/server/live/tui/
# webview) — the baseline coverage when the change→example map is imprecise.
# Deterministic: the first in-scope example of each shape in build_set order.
representative_floor() {
  local d shape
  declare -A seen
  while IFS= read -r d; do
    shape="$(example_shape "$d")"
    case "$shape" in
      cli|server|live|tui|webview) ;;
      *) continue ;;                  # fyne is Go-FFI (not in build_set anyway)
    esac
    [ -n "${seen[$shape]:-}" ] && continue
    seen[$shape]=1
    printf '%s\n' "$d"
  done < <(build_set)
}

# _paths_to_example_dirs: PURE. Reads repo-relative changed paths (one per line)
# on stdin; emits the example dir for each `examples/<name>/...` path (the precise
# case — an example depends only on its own source). New example dirs surface here
# automatically (their source shows in the diff). Non-example paths are ignored.
_paths_to_example_dirs() {
  local p name
  while IFS= read -r p; do
    case "$p" in
      examples/*/*)
        name="${p#examples/}"; name="${name%%/*}"
        [ -d "examples/$name" ] && printf 'examples/%s\n' "$name"
        ;;
    esac
  done
}

# _runtime_token <rs-path>: derive a `skydex covers` module token from a runtime
# file name. Heuristic, best-effort: capitalize the basename and drop a trailing
# `_<suffix>` (string.rs → String, server_stream.rs → Server, db.rs → Db). The
# covers LIKE-match is forgiving; a token matching no module yields no rows and
# the representative floor still covers that change.
_runtime_token() {
  local base
  base="$(basename "$1" .rs)"
  base="${base%%_*}"
  printf '%s%s\n' "$(printf '%s' "${base:0:1}" | tr '[:lower:]' '[:upper:]')" "${base:1}"
}

# _runtime_paths_to_covered_examples: PURE-ish (reads skydex, no mutation). For
# each changed runtime-rust/src/**.rs path, ask skydex which examples `cover`
# (import) the derived module, mapping .sky consumers back to example dirs.
# GUARDED: if skydex isn't built or the index db is absent, emit nothing — the
# broad floor (and CI) still cover the change. Best-effort enrichment, never a
# hard dependency.
_runtime_paths_to_covered_examples() {
  local p tok line name
  local sky="$REPO/tools/skydex/target/release/skydex"
  local db="$REPO/.skydex/index.db"
  [ -x "$sky" ] && [ -f "$db" ] || return 0
  while IFS= read -r p; do
    case "$p" in runtime-rust/src/*) ;; *) continue ;; esac
    [ "${p%.rs}" != "$p" ] || continue          # only .rs files
    tok="$(_runtime_token "$p")"
    [ -n "$tok" ] || continue
    while IFS= read -r line; do
      case "$line" in
        examples/*/*)
          name="${line#examples/}"; name="${name%%/*}"
          [ -d "examples/$name" ] && printf 'examples/%s\n' "$name"
          ;;
      esac
    done < <("$sky" covers "$tok" --db "$db" 2>/dev/null)
  done
}

# _intersect_build_set: keep only dirs present in build_set (drops Go-FFI /
# non-buildable / bogus). Reads candidate dirs on stdin.
_intersect_build_set() {
  local d
  declare -A inscope
  while IFS= read -r d; do [ -n "$d" ] && inscope[$d]=1; done < <(build_set)
  while IFS= read -r d; do
    [ -n "${inscope[$d]:-}" ] && printf '%s\n' "$d"
  done
}

# changed_examples <base>: the scoped local-sweep list. ONE `git diff` feeds the
# whole partition (the caller passes the same <base> to the incremental audit).
# Union of: example-source dirs (precise) + skydex-covered consumers of changed
# runtime kernels (best-effort) + the representative floor — intersected with
# build_set, deduped. Codegen changes have no clean per-example map, so they
# WIDEN to the full build_set ("broad"). Emits dir paths, one per line, for
# RUST_EXAMPLES. Honest contract: precise only for example-source changes; for
# runtime/codegen changes this is fast pre-push feedback, NOT the gate — CI's
# full 3-OS sweep is.
changed_examples() {
  local base="${1:?changed_examples: <base> required}" diff
  diff="$(git diff --name-only "$base"..HEAD 2>/dev/null)"
  # Codegen touch → broad: the whole in-scope set (supersets every other source).
  if printf '%s\n' "$diff" | grep -qE '^src/Sky/(Generate|Build)/Rust/'; then
    build_set | sort -u
    return 0
  fi
  {
    printf '%s\n' "$diff" | _paths_to_example_dirs
    printf '%s\n' "$diff" | _runtime_paths_to_covered_examples
    representative_floor
  } | sort -u | _intersect_build_set | sort -u
}

# ── equiv_mode <dir>: DERIVE the Go≡Rust equivalence mode from the shape ─────
# The equivalence mode says HOW examples-sweep proves the Rust output matches Go.
# It is DERIVED from example_shape so an author-added example auto-classifies with
# NO manual step — the same non-hardcoded discipline as build_set:
#   Go-FFI / out-of-scope → none (does not build on --backend rust → nothing to compare)
#   cli      → stdout   (run BOTH backends, byte-diff normalized stdout)
#   server   → body     (compare no-param GET-route response bodies; see exercise_server_equiv)
#   live     → scenario (run the SAME web-verify scenario against BOTH binaries)
#   tui      → pty      (both drive the runtime without panic — NOT cell-identical)
#   webview  → none     (opens a window — no comparable output)
#   fyne     → none     (Go-FFI GUI — does not build on --backend rust)
#
# Then an OVERRIDE from equiv-classification.tsv wins if the example is listed
# there (the .tsv is overrides-on-top-of-derived, NOT a full classification — a
# small file of exceptions + reasons, e.g. a non-deterministic cli downgraded to
# `none`). The override's mode is taken verbatim; derivation guarantees coverage,
# so a brand-new example never needs a .tsv line at all.
equiv_mode() {
  local dir="$1" base over
  base="$(basename "$dir")"
  # OVERRIDE (column 2 of the .tsv, keyed by basename) takes precedence.
  if [ -f "$EQUIV_TSV" ]; then
    over="$(awk -v k="$base" '!/^#/ && $1==k {print $2; exit}' "$EQUIV_TSV" 2>/dev/null)"
    [ -n "$over" ] && { printf '%s\n' "$over"; return 0; }
  fi
  # DERIVE from shape.
  if is_out_of_scope "$dir"; then printf 'none\n'; return 0; fi
  case "$(example_shape "$dir")" in
    cli)     printf 'stdout\n'   ;;
    server)  printf 'body\n'     ;;
    live)    printf 'scenario\n' ;;
    tui)     printf 'pty\n'      ;;
    webview) printf 'none\n'     ;;
    fyne)    printf 'none\n'     ;;
    *)       printf 'none\n'     ;;
  esac
}

# equiv_override_reason <dir> → the .tsv reason column for an overridden example
# (empty when the example is not overridden). Used for the NOTE column.
equiv_override_reason() {
  local base; base="$(basename "$1")"
  [ -f "$EQUIV_TSV" ] || return 0
  awk -v k="$base" '!/^#/ && $1==k {$1="";$2="";sub(/^[[:space:]]+/,"");print;exit}' "$EQUIV_TSV" 2>/dev/null
}

# The overrides file (overrides-on-top-of-derived). Resolved relative to REPO so
# every caller agrees. env.sh sets REPO before this file is sourced.
EQUIV_TSV="${EQUIV_TSV:-$REPO/runtime-rust/scripts/equiv-classification.tsv}"
