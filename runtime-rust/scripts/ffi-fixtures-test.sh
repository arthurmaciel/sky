#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Sky→Rust AUTO-FFI fixture gate — the CI enforcement the examples-sweep can't do.
#
# The auto-binding fixtures under `runtime-rust/tests/sky/4{0..4}-*` each wire a
# LOCAL Rust crate via a `file://` git dep in their `sky.toml` and stage that
# crate (git-init) through a per-fixture `setup.sh` BEFORE the first build. The
# examples-sweep walks ONLY `examples/` and never runs a `setup.sh`, so these
# fixtures are unguarded — exactly the guardian's M1 finding (the 43-ffi-dce S4
# DCE regression most acutely). This runner closes that gap:
#
#   For each 4{0..4}-* fixture:  run setup.sh · sky build --backend rust · run the
#                                binary · assert it prints `[ALL OK]`.
#
#   PLUS the 43-ffi-dce S4 guarantees (the core of M1):
#     (a) used-only — the default (DCE-on) build emits EXACTLY the wrappers it
#         calls (one: `used_one`), via the `// SKY-FFI-WRAPPER BEGIN <ref>`
#         sentinel count in the generated `dcetest_bindings.rs`.
#     (d) D4 equivalence — a `SKY_DCE=0` rebuild emits the FULL wrapper set
#         (count > 1, == the discovered full set) AND runs byte-identically.
#     (R-4) staleness — appending a call to a previously-unused fn makes that
#         fn's wrapper REAPPEAR (no stale-cache E0425); Main.sky is restored after.
#
# PORTABILITY. The committed `sky.toml`s hardcode `file:///home/arthur/.cache/…`
# (the author's $HOME). `setup.sh` correctly stages under the REAL $HOME, so on
# any host where $HOME != /home/arthur the committed URL is wrong. This runner
# never edits a committed fixture: it copies each fixture to a TMPDIR workdir and
# rewrites that copy's `file://` URL to the actually-staged path. The committed
# tree stays pristine; the build happens against the rewritten copy.
#
# Usage:  ffi-fixtures-test.sh                  # all five fixtures + the S4 suite
#         ffi-fixtures-test.sh 43-ffi-dce       # a subset (S4 runs iff 43 is in it)
# Exit:   0 = every fixture [ALL OK] AND every S4 assertion passed
#         1 = a build/run/[ALL OK]/S4 failure
#         2 = setup error (no sky binary, bad repo, …)
#
# CI WIRING (out of this script's edit boundary — left as a documented TODO for
# the maintainer): add, to the `examples-sweep` job of
# `.github/workflows/examples-sweep.yml`, a ubuntu-only GATING step AFTER the
# "Go≡Rust equivalence corpus" step (these fixtures need the same nightly Rust +
# fresh `sky` the sweep job already provisions):
#
#     - name: Sky→Rust auto-FFI fixtures (+ 43-ffi-dce S4 DCE)
#       if: matrix.os == 'ubuntu-latest'
#       shell: bash
#       run: bash runtime-rust/scripts/ffi-fixtures-test.sh
#
# It exits non-zero on any failure, so it fails the job exactly like a RED sweep
# row. (The fixtures' FFI introspection runs `cargo +nightly rustdoc`; the sweep
# job currently installs only stable Rust — the maintainer must also add
# `rustup toolchain install nightly` to that job, or the inspector will fall back
# and the binding generation will fail. Noted because it is a real prerequisite.)
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=lib/env.sh
source "$_dir/lib/env.sh"      # PATH / CARGO_TARGET_DIR / sccache / REPO / SKY_BIN
# shellcheck source=lib/checks.sh
source "$_dir/lib/checks.sh"   # resolve_bin · exercise_cli · PANIC_RE
[ -n "${REPO:-}" ] && cd "$REPO" || { echo "ERROR: run from the Sky repo (set SKY_REPO)." >&2; exit 2; }
SKY="${SKY_BIN:-$REPO/sky-out/sky}"
[ -x "$SKY" ] || { echo "ERROR: sky binary not found at $SKY (build it + symlink)." >&2; exit 2; }

# ── Inspector freshness guard. These fixtures exercise the auto-FFI accessor
# generation (getters/setters/enums/DCE), which depends on the Rust FFI
# inspector. `sky` embeds the inspector at TH-compile time; a LOCAL incremental
# build can carry a STALE embedded inspector (the embed tracks the prebuilt
# binary, not main.rs — see EmbeddedInspectorRust.hs), so a dev who edited the
# inspector but didn't fully rebuild gets spurious failures. CI is immune (a
# clean checkout has no prebuilt binary → it embeds + builds the current source).
# To make this gate deterministic EVERYWHERE, bind the fixtures to a freshly
# built source inspector unless the caller already pinned one — this matches what
# a clean `sky` build embeds, so the result tracks CI exactly.
if [ -z "${SKY_FFI_INSPECTOR_RS:-}" ]; then
  if cargo build --release --manifest-path "$REPO/tools/sky-ffi-inspect-rs/Cargo.toml" >/tmp/ffi-inspector-build.log 2>&1; then
    # env.sh exports CARGO_TARGET_DIR (shared cache), so the release binary lands
    # under $CARGO_TARGET_DIR/release/, NOT the crate-local tools/.../target/. A
    # stale crate-local copy (from an earlier non-shared build) would otherwise
    # be picked verbatim and SILENTLY shadow the just-built source — exactly the
    # staleness this guard exists to prevent. Prefer the actual output dir, fall
    # back to the crate-local default only when no override is set.
    _insp=""
    for _cand in \
        "${CARGO_TARGET_DIR:-}/release/sky-ffi-inspect-rs" \
        "$REPO/tools/sky-ffi-inspect-rs/target/release/sky-ffi-inspect-rs"; do
      [ -n "$_cand" ] && [ -x "$_cand" ] && { _insp="$_cand"; break; }
    done
    if [ -n "$_insp" ]; then
      export SKY_FFI_INSPECTOR_RS="$_insp"
      echo "  (using freshly built inspector: $_insp)"
    else
      echo "  WARNING: built the inspector but found no binary (checked CARGO_TARGET_DIR + crate-local); falling back to sky's embedded inspector — may be stale." >&2
    fi
  else
    echo "  WARNING: could not build the source inspector (see /tmp/ffi-inspector-build.log); falling back to sky's embedded inspector — may be stale on an incremental local build." >&2
  fi
fi

FIXROOT="runtime-rust/tests/sky"
BUILD_TMO="${SKY_FFI_FIXTURE_BUILD_TIMEOUT:-900}"   # cold cargo + nightly rustdoc introspection
RUN_TMO=25

# The full fixture set (numbered order). Default when no args given.
#
# Two fixture flavours coexist (auto-detected by the presence of `setup.sh`):
#   • LOCAL-crate fixtures (40-46) wire a `file://` git dep + a `setup.sh` that
#     stages the crate under $HOME; stage_workdir rewrites the URL per host.
#   • CRATES.IO-dep fixtures (47-borrowed-returns) declare ordinary
#     `["rust.dependencies] url = "2"` deps and need NO setup.sh — the sources
#     are copied verbatim and cargo fetches the crate from crates.io.
ALL_FIXTURES=(40-field-getters 41-field-setters 42-enum-variants 43-ffi-dce 44-wide-int 45-async-ffi 46-enum-multifield 47-borrowed-returns 48-ffi-generics 49-ffi-closures 50-ffi-iterators 51-ffi-trait-methods 51b-ffi-trait-methods-realcrate 52-ffi-dce-deadbinding 61-ffi-result-string-err 72-ffi-async 73-ffi-serde 74-ffi-opaque-client 75-ffi-nested-glob-asref 76-ffi-borrowed-ref 78-ffi-async-opaque-ctor 79-ffi-serde-trait 80-ffi-result-alias 81-ffi-serde-ref 82-ffi-async-trait 83-ffi-mixed-generic-turbofish 84-ffi-owned-string-ctor 85-ffi-vec-struct-field 86-ffi-transitive-dep-path 87-ffi-private-module-path 88-ffi-default-assoc-fn 89-ffi-static-str-into 90-ffi-default-trait-method-mono 91-ffi-cross-crate-impl 92-ffi-generic-self-open-t 93-ffi-customize-chain 94-ffi-inherent-self-output 95-ffi-inherent-self-output-async 96-ffi-external-trait-xcrate 97-ffi-numeric-param-coerce 98-ffi-projected-numeric 99-ffi-nested-numeric-drop 100-ffi-asref-return 101-task-rethunk 102-task-rethunk-free-tvar 103-task-rethunk-discard 104-ffi-owned-query-builder 105-ffi-generic-struct-accessor 106-ffi-feature-propagation 107-ffi-shimfree-semver)

# ── stage_workdir <fixture-dir> → echoes a TMPDIR build copy with a portable
# `file://` URL. Runs the fixture's setup.sh (stages the crate under the real
# $HOME), copies the fixture sources to a temp workdir, and rewrites the copy's
# sky.toml `file://…/<name>-crate` URL to the actually-staged $HOME path. Never
# touches the committed fixture. Echoes the workdir path on success; non-zero on
# failure. ───────────────────────────────────────────────────────────────────
# ── stage_workdir_cratesio <fixture-dir> → echoes a TMPDIR build copy for a
# CRATES.IO-dep fixture (no local crate, no setup.sh, no URL rewrite). Copies
# src/ + sky.toml verbatim; cargo resolves the deps from crates.io at build
# time. Keeps the committed tree pristine, like the local-crate path. ──────────
stage_workdir_cratesio() {
  local src="$1" base; base="$(basename "$src")"
  local wd; wd="$(mktemp -d "${TMPDIR:-/tmp}/ffi-fixture-$base.XXXXXX")" || return 1
  mkdir -p "$wd/src"
  cp -r "$src/src/." "$wd/src/" 2>/dev/null || true
  cp "$src/sky.toml" "$wd/sky.toml" || { rm -rf "$wd"; return 1; }
  printf '%s\n' "$wd"
}

stage_workdir() {
  local src="$1" base; base="$(basename "$src")"
  # CRATES.IO-dep fixtures have no setup.sh — copy sources verbatim.
  [ -f "$src/setup.sh" ] || { stage_workdir_cratesio "$src"; return $?; }

  # 1. Stage the crate (git-init under the REAL $HOME). setup.sh is `set -e`.
  bash "$src/setup.sh" >/tmp/ffi-fixture-"$base".setup.log 2>&1 || {
    echo "setup.sh failed (see /tmp/ffi-fixture-$base.setup.log)" >&2; return 1; }

  # 2. The dest setup.sh staged to (it echoes `staged … at <dest>`; derive
  #    independently too so we never depend on the echo format).
  local staged="$HOME/.cache/sky/$base-crate"
  [ -d "$staged/.git" ] || { echo "expected staged crate at $staged (setup.sh contract)" >&2; return 1; }

  # 3. A clean per-run workdir copy of the fixture SOURCES (not sky-out/.skycache).
  local wd; wd="$(mktemp -d "${TMPDIR:-/tmp}/ffi-fixture-$base.XXXXXX")" || return 1
  # Copy src/ + sky.toml; deliberately skip generated dirs + the crate source
  # (the crate is consumed from the git dep, not the copy).
  mkdir -p "$wd/src"
  cp -r "$src/src/." "$wd/src/" 2>/dev/null || true
  cp "$src/sky.toml" "$wd/sky.toml" || { rm -rf "$wd"; return 1; }

  # 4. Rewrite the `file://` URL to the actually-staged path. The committed URL
  #    is `file:///home/arthur/.cache/sky/<base>-crate`; replace the whole
  #    file://… token (any author $HOME) with the real staged path. Matches by
  #    the stable `<base>-crate` suffix so it is host-$HOME-agnostic.
  local newurl="file://$staged"
  # Escape sed replacement metachars (/ & \) in the path.
  local esc; esc="$(printf '%s' "$newurl" | sed -e 's/[\/&]/\\&/g')"
  sed -i -E "s|file://[^\"]*/$base-crate|$esc|g" "$wd/sky.toml" || { rm -rf "$wd"; return 1; }

  printf '%s\n' "$wd"
}

# ── build_fixture <workdir> → builds with --backend rust (DCE default). Honours
# SKY_DCE from the environment so callers can force a full emit. Echoes the
# resolved binary path on success; non-zero (with the build log on stderr hint)
# on failure. ─────────────────────────────────────────────────────────────────
build_fixture() {
  local wd="$1" base; base="$(basename "$wd" | sed 's/\..*//')"
  local logp="/tmp/ffi-fixture-$base.build.log"
  ( cd "$wd" && rm -rf sky-out .skycache .skydeps ) >/dev/null 2>&1
  ( cd "$wd" && timeout "$BUILD_TMO" "$SKY" build --backend rust src/Main.sky ) >"$logp" 2>&1 || {
    echo "  build log: $logp" >&2; return 1; }
  local b; b="$(resolve_bin "$wd")" || { echo "  (no binary; build log: $logp)" >&2; return 1; }
  printf '%s\n' "$b"
}

# ── bindings_file <workdir> → the generated FFI bindings .rs for the fixture's
# single dep (e.g. sky-out/rust/src/dcetest_bindings.rs). Derives the slug from
# the dep NAME in sky.toml (`<dep> = { git = … }` under ["rust.dependencies]),
# matching codegen's `<depToIdent dep>_bindings.rs`. ─────────────────────────
bindings_file() {
  local wd="$1" dep
  # First key inside the ["rust.dependencies] table (single dep per fixture).
  dep="$(awk '
    /^\["?rust\.dependencies"?\]/ {inrd=1; next}
    /^\[/ {inrd=0}
    inrd && /=/ { gsub(/[[:space:]]/,"",$0); split($0,a,"="); print a[1]; exit }
  ' "$wd/sky.toml")"
  [ -n "$dep" ] || return 1
  # depToIdent: non-alphanumerics → '_'  (Project.hs).
  local slug; slug="$(printf '%s' "$dep" | sed 's/[^A-Za-z0-9]/_/g')"
  printf '%s\n' "$wd/sky-out/rust/src/${slug}_bindings.rs"
}

# ── wrapper sentinel counting (Sky.Build.Rust.Ffi.wrapperSentinelPrefix) ──────
SENTINEL='SKY-FFI-WRAPPER BEGIN'
count_wrappers()  { rg -c "$SENTINEL" "$1" 2>/dev/null || echo 0; }              # total
list_wrappers()   { rg -o "$SENTINEL .*" "$1" 2>/dev/null | sort; }             # names
has_wrapper()     { rg -q "$SENTINEL $2\$" "$1" 2>/dev/null; }                   # exact ref

pass=0; fail=0; rows=()
_ok()   { rows+=("ok    $1"); pass=$((pass+1)); }
_fail() { rows+=("FAIL  $1"); fail=$((fail+1)); }

# ─────────────────────────────────────────────────────────────────────────────
# Per-fixture: build + run + assert [ALL OK].
# ─────────────────────────────────────────────────────────────────────────────
run_basic() {
  local base="$1"
  local src="$FIXROOT/$base"
  [ -f "$src/src/Main.sky" ] || { _fail "$base (no such fixture)"; return; }

  local wd; wd="$(stage_workdir "$src")" || { _fail "$base (stage failed)"; return; }
  local bin; bin="$(build_fixture "$wd")" || { _fail "$base (build failed)"; rm -rf "$wd"; return; }

  local outp="/tmp/ffi-fixture-$base.out"
  if ! exercise_cli "$bin" "$outp" "$RUN_TMO"; then
    _fail "$base (run panicked/hung)"; rm -rf "$wd" "$(dirname "$bin")/${base}"* 2>/dev/null; return
  fi
  if rg -q '\[ALL OK\]' "$outp"; then
    _ok "$base  ($(tr -d '\n' <"$outp" | sed 's/  */ /g'))"
  else
    _fail "$base (no [ALL OK] — got: $(tr -d '\n' <"$outp"))"
  fi
  ( cd "$wd" && rm -rf sky-out/rust/target ) >/dev/null 2>&1   # disk hygiene
  rm -rf "$wd"
}

# ── run_transitive_dep  (WALL-B #75 — 86-ffi-transitive-dep-path). Like
# run_basic (build + run + assert `[ALL OK]`), PLUS the WALL-B regression: the
# generated Cargo.toml MUST list each TRANSITIVE crate with its CANONICAL
# crates.io package KEY and an EXACT pinned version sourced from the inspector's
# `cargo metadata` — specifically the HYPHEN-named `is-even = "=1.0.0"` (NOT a
# `_`→`-` guess of `is_even`, NOT a `"*"` version) and the no-separator
# `equivalent = "=1.0.2"`. This is the decisive proof the dep NAME+VERSION come
# from the resolved metadata, not a path-segment string transform. ──────────────
run_transitive_dep() {
  local base="86-ffi-transitive-dep-path"
  local src="$FIXROOT/$base"
  [ -f "$src/src/Main.sky" ] || { _fail "$base (no such fixture)"; return; }

  local wd; wd="$(stage_workdir "$src")" || { _fail "$base (stage failed)"; return; }
  local bin; bin="$(build_fixture "$wd")" || { _fail "$base (build failed)"; rm -rf "$wd"; return; }

  local cargo="$wd/sky-out/rust/Cargo.toml"
  # HYPHEN key + EXACT version (the WALL-B decisive assertion).
  if ! rg -qx 'is-even = "=1\.0\.0"' "$cargo"; then
    _fail "$base (Cargo.toml missing canonical hyphen dep 'is-even = \"=1.0.0\"' — got: $(rg -n '^is.even' "$cargo" | tr '\n' ' '))"
    rm -rf "$wd"; return
  fi
  # The underscore-guess form MUST NOT appear (proves no `_`→`-` string transform
  # and no `"*"` version slipped through).
  if rg -q '^is_even ' "$cargo" || rg -q '= "\*"' "$cargo"; then
    _fail "$base (Cargo.toml has an underscore-key or \"*\"-version transitive dep — WALL-B regression)"
    rm -rf "$wd"; return
  fi
  # No-separator transitive crate, exact version.
  if ! rg -qx 'equivalent = "=1\.0\.2"' "$cargo"; then
    _fail "$base (Cargo.toml missing 'equivalent = \"=1.0.2\"' — got: $(rg -n '^equivalent' "$cargo" | tr '\n' ' '))"
    rm -rf "$wd"; return
  fi

  local outp="/tmp/ffi-fixture-$base.out"
  if ! exercise_cli "$bin" "$outp" "$RUN_TMO"; then
    _fail "$base (run panicked/hung)"; rm -rf "$wd"; return
  fi
  if rg -q '\[ALL OK\]' "$outp"; then
    _ok "$base  (hyphen is-even=\"=1.0.0\" + equivalent=\"=1.0.2\" + [ALL OK])"
  else
    _fail "$base (no [ALL OK] — got: $(tr -d '\n' <"$outp"))"
  fi
  ( cd "$wd" && rm -rf sky-out/rust/target ) >/dev/null 2>&1
  rm -rf "$wd"
}

# ── run_handstub <fixture>  (Wall #2 — 48-ffi-generics). A HAND-STUB fixture:
# a CHECKED-IN parametric kernel.json (the `generic` blocks) + an (empty)
# bindings .rs under `ffi-stub/`, NO inspector. Differs from run_basic in three
# ways: (1) it stages the committed `ffi-stub/*.{kernel.json,rs}` into the
# workdir's `.skycache/ffi/rust/` AFTER the build's own wipe so the build reads
# the hand stub (no inspector regenerates it); (2) it asserts `[ALL OK]` on the
# POSITIVE program AND the per-wrapper tree-shake (only reached wrappers in
# `sky_ffi_generics.rs`); (3) it drives the NEGATIVE matrix — Float-on-Hash,
# out-of-closed-set, unmodellable-bound — each must produce the Sky `E4400`
# diagnostic, NOT a cargo failure. ───────────────────────────────────────────
run_handstub() {
  local base="48-ffi-generics"
  local src="$FIXROOT/$base"
  [ -f "$src/src/Main.sky" ] || { _fail "$base (no such fixture)"; return; }
  [ -d "$src/ffi-stub" ]     || { _fail "$base (no ffi-stub/ dir)"; return; }

  # Stage the local crate (git-init under $HOME) via setup.sh.
  bash "$src/setup.sh" >/tmp/ffi-fixture-"$base".setup.log 2>&1 || {
    _fail "$base (setup.sh failed — see /tmp/ffi-fixture-$base.setup.log)"; return; }
  local staged="$HOME/.cache/sky/$base-crate"
  [ -d "$staged/.git" ] || { _fail "$base (expected staged crate at $staged)"; return; }

  local wd; wd="$(mktemp -d "${TMPDIR:-/tmp}/ffi-fixture-$base.XXXXXX")" || { _fail "$base (mktemp)"; return; }
  mkdir -p "$wd/src" "$wd/ffi-stub"
  cp -r "$src/src/." "$wd/src/" 2>/dev/null || true
  cp -r "$src/ffi-stub/." "$wd/ffi-stub/" 2>/dev/null || true
  cp "$src/sky.toml" "$wd/sky.toml" || { rm -rf "$wd"; _fail "$base (cp sky.toml)"; return; }
  local newurl="file://$staged" esc
  esc="$(printf '%s' "$newurl" | sed -e 's/[\/&]/\\&/g')"
  sed -i -E "s|file://[^\"]*/$base-crate|$esc|g" "$wd/sky.toml"

  # stage_stub: re-place the hand stub into .skycache (the build wipes it).
  _stage_stub() { mkdir -p "$wd/.skycache/ffi/rust"; cp "$wd"/ffi-stub/*.kernel.json "$wd"/ffi-stub/*_bindings.rs "$wd/.skycache/ffi/rust/" 2>/dev/null; }

  # _build <main-src>: wipe generated dirs, RE-stage the stub, build. Echoes the
  # build log path; returns the build's exit code.
  _build() {
    ( cd "$wd" && rm -rf sky-out .skycache .skydeps ) >/dev/null 2>&1
    _stage_stub
    local logp="/tmp/ffi-fixture-$base.build.log"
    ( cd "$wd" && timeout "$BUILD_TMO" "$SKY" build --backend rust src/Main.sky ) >"$logp" 2>&1
    local rc=$?; printf '%s\n' "$logp"; return $rc
  }

  # ── POSITIVE: default program builds, runs [ALL OK], tree-shake = 4 wrappers.
  local logp; logp="$(_build)"; local rc=$?
  if [ $rc -ne 0 ]; then _fail "$base (positive build failed — $logp)"; rm -rf "$wd"; return; fi
  local gen="$wd/sky-out/rust/src/sky_ffi_generics.rs"
  local nwrap; nwrap="$(rg -c "$SENTINEL" "$gen" 2>/dev/null || echo 0)"
  if [ "$nwrap" != "4" ]; then _fail "$base (expected 4 reached wrappers, got $nwrap)"; rm -rf "$wd"; return; fi
  if rg -q 'tagged_make' "$gen" 2>/dev/null; then _fail "$base (unreached taggedMake leaked into generics)"; rm -rf "$wd"; return; fi
  local bin; bin="$(resolve_bin "$wd")" || { _fail "$base (no binary)"; rm -rf "$wd"; return; }
  local outp="/tmp/ffi-fixture-$base.out"
  exercise_cli "$bin" "$outp" "$RUN_TMO" || { _fail "$base (run panicked/hung)"; rm -rf "$wd"; return; }
  rg -q '\[ALL OK\]' "$outp" || { _fail "$base (no [ALL OK] — got: $(tr -d '\n' <"$outp"))"; rm -rf "$wd"; return; }

  # ── NEGATIVE matrix. Each must yield the Sky E4400 diagnostic, NOT a cargo
  # error. We swap Main.sky in the workdir, rebuild, and assert E4400 + absence
  # of a cargo 'error[E0' line in the build log.
  _neg() {
    local label="$1" body="$2"
    printf '%s\n' "$body" > "$wd/src/Main.sky"
    local lp; lp="$(_build)"; local brc=$?
    if [ $brc -eq 0 ]; then _fail "$base/$label (expected build FAIL, got success)"; return 1; fi
    if ! rg -q 'E4400' "$lp"; then _fail "$base/$label (no E4400 Sky diagnostic — $lp)"; return 1; fi
    if rg -q 'error\[E0' "$lp"; then _fail "$base/$label (got a cargo error, not a Sky diagnostic — $lp)"; return 1; fi
    return 0
  }

  local hdr='module Main exposing (main)
import Sky.Core.Prelude exposing (..)
import Sky.Core.Task as Task
import Sky.Core.Result as Result
import Rust.Box1 as Box1
import Std.Log exposing (println)
'
  _neg "float-on-hash" "$hdr
main : Task Error ()
main =
    let c = Result.withDefault 0 (Box1.keyedMake 3.14 |> Result.andThen Box1.keyedCount)
    in println (String.fromInt c)" || { rm -rf "$wd"; return; }

  _neg "out-of-closed-set" "$hdr
main : Task Error ()
main =
    let _ = Box1.make (1, 2)
    in println \"x\"" || { rm -rf "$wd"; return; }

  _neg "unmodellable-bound" "$hdr
main : Task Error ()
main =
    let _ = Box1.taggedMake 5
    in println \"x\"" || { rm -rf "$wd"; return; }

  _ok "$base  (positive [ALL OK] + tree-shake=4 + 3 E4400 negatives)"
  ( cd "$wd" && rm -rf sky-out/rust/target ) >/dev/null 2>&1
  rm -rf "$wd"
}

# ── run_handstub_basic <fixture>  (Wall #2 — 49-ffi-closures epic #28, plus
# 50-ffi-iterators epic #30). A HAND-STUB fixture: a CHECKED-IN kernel.json
# (closure `argType` blocks for 49; iterator `Vec<Item>` argTypes + `iterAdapters`
# for 50) + an (empty) bindings .rs under `ffi-stub/`, NO inspector.
# Like run_handstub it must re-stage the committed `ffi-stub/*.{kernel.json,rs}`
# into the workdir's `.skycache/ffi/rust/` AFTER the build's own wipe so the
# build reads the hand stub (no inspector regenerates it). Unlike run_handstub
# (48-ffi-generics) there is no NEGATIVE E4400 matrix and no tree-shake count to
# assert here — the proof is the POSITIVE end-to-end: a Sky lambda lowers to a
# Rust closure FFI arg (by-value Fn `mapEach`, by-ref Fn `keep`) and the program
# prints `[ALL OK]`. ──────────────────────────────────────────────────────────
run_handstub_basic() {
  local base="$1"
  local src="$FIXROOT/$base"
  [ -f "$src/src/Main.sky" ] || { _fail "$base (no such fixture)"; return; }
  [ -d "$src/ffi-stub" ]     || { _fail "$base (no ffi-stub/ dir)"; return; }

  # Stage the local crate (git-init under $HOME) via setup.sh.
  bash "$src/setup.sh" >/tmp/ffi-fixture-"$base".setup.log 2>&1 || {
    _fail "$base (setup.sh failed — see /tmp/ffi-fixture-$base.setup.log)"; return; }
  local staged="$HOME/.cache/sky/$base-crate"
  [ -d "$staged/.git" ] || { _fail "$base (expected staged crate at $staged)"; return; }

  local wd; wd="$(mktemp -d "${TMPDIR:-/tmp}/ffi-fixture-$base.XXXXXX")" || { _fail "$base (mktemp)"; return; }
  mkdir -p "$wd/src" "$wd/ffi-stub"
  cp -r "$src/src/." "$wd/src/" 2>/dev/null || true
  cp -r "$src/ffi-stub/." "$wd/ffi-stub/" 2>/dev/null || true
  cp "$src/sky.toml" "$wd/sky.toml" || { rm -rf "$wd"; _fail "$base (cp sky.toml)"; return; }
  local newurl="file://$staged" esc
  esc="$(printf '%s' "$newurl" | sed -e 's/[\/&]/\\&/g')"
  sed -i -E "s|file://[^\"]*/$base-crate|$esc|g" "$wd/sky.toml"

  # Re-place the hand stub into .skycache AFTER the build wipes generated dirs.
  ( cd "$wd" && rm -rf sky-out .skycache .skydeps ) >/dev/null 2>&1
  mkdir -p "$wd/.skycache/ffi/rust"
  cp "$wd"/ffi-stub/*.kernel.json "$wd"/ffi-stub/*_bindings.rs "$wd/.skycache/ffi/rust/" 2>/dev/null

  local logp="/tmp/ffi-fixture-$base.build.log"
  ( cd "$wd" && timeout "$BUILD_TMO" "$SKY" build --backend rust src/Main.sky ) >"$logp" 2>&1 || {
    _fail "$base (build failed — $logp)"; rm -rf "$wd"; return; }
  local bin; bin="$(resolve_bin "$wd")" || { _fail "$base (no binary; build log: $logp)"; rm -rf "$wd"; return; }

  local outp="/tmp/ffi-fixture-$base.out"
  exercise_cli "$bin" "$outp" "$RUN_TMO" || { _fail "$base (run panicked/hung)"; rm -rf "$wd"; return; }
  if rg -q '\[ALL OK\]' "$outp"; then
    _ok "$base  ($(tr -d '\n' <"$outp" | sed 's/  */ /g'))"
  else
    _fail "$base (no [ALL OK] — got: $(tr -d '\n' <"$outp"))"
  fi
  ( cd "$wd" && rm -rf sky-out/rust/target ) >/dev/null 2>&1
  rm -rf "$wd"
}

# ─────────────────────────────────────────────────────────────────────────────
# 43-ffi-dce S4 suite — used-only (a) · D4 equivalence (d) · staleness (R-4).
# Self-contained: stages its OWN workdir (so the Main.sky patch never touches the
# committed fixture), runs all three assertions, restores nothing in the repo.
# ─────────────────────────────────────────────────────────────────────────────
run_s4_dce() {
  local base=43-ffi-dce
  local src="$FIXROOT/$base"
  [ -f "$src/src/Main.sky" ] || { _fail "$base-S4 (no such fixture)"; return; }

  local wd; wd="$(stage_workdir "$src")" || { _fail "$base-S4 (stage failed)"; return; }
  local binds; binds="$(bindings_file "$wd")" || { _fail "$base-S4 (cannot derive bindings path)"; rm -rf "$wd"; return; }

  # ── (a) used-only: default (DCE-on) build emits exactly `used_one`. ────────
  local defbin; defbin="$(build_fixture "$wd")" || { _fail "$base-S4 (default build failed)"; rm -rf "$wd"; return; }
  [ -f "$binds" ] || { _fail "$base-S4 (bindings not at $binds)"; rm -rf "$wd"; return; }
  local def_n; def_n="$(count_wrappers "$binds")"
  local def_out="/tmp/ffi-fixture-$base-S4.def.out"
  exercise_cli "$defbin" "$def_out" "$RUN_TMO" || { _fail "$base-S4 (default run panicked/hung)"; rm -rf "$wd"; return; }
  if [ "$def_n" = "1" ] && has_wrapper "$binds" "used_one"; then
    _ok "$base-S4(a) used-only: 1 wrapper survives (used_one)"
  else
    _fail "$base-S4(a) used-only: expected exactly 1 wrapper (used_one), got $def_n: $(list_wrappers "$binds" | tr '\n' ' ')"
    rm -rf "$wd"; return
  fi

  # ── (d) D4 equivalence: SKY_DCE=0 emits the FULL set AND runs identically. ──
  ( cd "$wd" && rm -rf sky-out .skycache .skydeps ) >/dev/null 2>&1
  local full_log="/tmp/ffi-fixture-$base-S4.full.build.log"
  ( cd "$wd" && SKY_DCE=0 timeout "$BUILD_TMO" "$SKY" build --backend rust src/Main.sky ) >"$full_log" 2>&1 || {
    _fail "$base-S4(d) SKY_DCE=0 build failed (see $full_log)"; rm -rf "$wd"; return; }
  local full_bin; full_bin="$(resolve_bin "$wd")" || { _fail "$base-S4(d) no full-emit binary"; rm -rf "$wd"; return; }
  local full_n; full_n="$(count_wrappers "$binds")"
  local full_out="/tmp/ffi-fixture-$base-S4.full.out"
  exercise_cli "$full_bin" "$full_out" "$RUN_TMO" || { _fail "$base-S4(d) full-emit run panicked/hung"; rm -rf "$wd"; return; }

  # full_n must exceed the DCE-on count AND include `used_one` (the full set is
  # discovered, not hardcoded — the inspector's surface may grow).
  if [ "$full_n" -gt "$def_n" ] && has_wrapper "$binds" "used_one" && has_wrapper "$binds" "unused_1"; then
    if diff <(grep -v '^[[:space:]]*$' "$def_out") <(grep -v '^[[:space:]]*$' "$full_out") >/tmp/ffi-fixture-$base-S4.d4.diff 2>&1; then
      _ok "$base-S4(d) D4: full emit = $full_n wrappers (DCE-on was $def_n) · output byte-identical"
    else
      _fail "$base-S4(d) D4: full-emit output DIFFERS from DCE-on (/tmp/ffi-fixture-$base-S4.d4.diff)"; rm -rf "$wd"; return
    fi
  else
    _fail "$base-S4(d) full emit not a superset: full=$full_n def=$def_n ($(list_wrappers "$binds" | tr '\n' ' '))"
    rm -rf "$wd"; return
  fi

  # ── (R-4) staleness: add an unused_3 call → its wrapper REAPPEARS. ─────────
  # Patch the WORKDIR Main.sky only (committed fixture untouched). Inject a use
  # of a currently-unused fn into the Ok arm via a let-binding.
  ( cd "$wd" && rm -rf sky-out .skycache .skydeps ) >/dev/null 2>&1
  local main="$wd/src/Main.sky"
  # Insert `let _stale = D.unused_3 n in` ahead of the existing `println` in the
  # Ok arm. Robust to whitespace: match the `Ok n ->` arm head.
  python3 - "$main" <<'PY' || { _fail "$base-S4(R-4) patch failed"; rm -rf "$wd"; return; }
import sys, re
p = sys.argv[1]
s = open(p).read()
# The committed Ok arm is:  "        Ok n ->\n            println"
pat = re.compile(r"(\n[ \t]*Ok n ->\n)([ \t]*)println", re.M)
inj = r"\1\2let\n\2    _stale =\n\2        D.unused_3 n\n\2in\n\2println"
s2, n = pat.subn(inj, s, count=1)
if n != 1:
    sys.exit(1)
open(p, "w").write(s2)
PY

  local stale_bin; stale_bin="$(build_fixture "$wd")" || { _fail "$base-S4(R-4) rebuild-with-unused_3 failed (build log printed)"; rm -rf "$wd"; return; }
  if has_wrapper "$binds" "unused_3"; then
    # Confirm it ran clean too (no stale E0425 leaked into a runtime fault).
    local stale_out="/tmp/ffi-fixture-$base-S4.stale.out"
    if exercise_cli "$stale_bin" "$stale_out" "$RUN_TMO"; then
      _ok "$base-S4(R-4) staleness: adding D.unused_3 call → its wrapper reappears, builds+runs clean"
    else
      _fail "$base-S4(R-4) staleness: wrapper reappeared but run panicked/hung"
    fi
  else
    _fail "$base-S4(R-4) staleness: D.unused_3 called but wrapper did NOT reappear (stale-cache regression): $(list_wrappers "$binds" | tr '\n' ' ')"
  fi

  ( cd "$wd" && rm -rf sky-out/rust/target ) >/dev/null 2>&1
  rm -rf "$wd"   # workdir is a copy → committed Main.sky never modified
}

# ─────────────────────────────────────────────────────────────────────────────
# 52-ffi-dce-deadbinding — #29: the ENTRY module's DEAD top-level bindings are
# DCE-filtered before Rust emission, mirroring the Go path's `generateDecls`
# (`reachableTopLevel`/`keepName`). Pre-fix the Rust backend emitted EVERY
# entry-module binding; a dead body calling an FFI wrapper that the S4
# tree-shake pruned → cargo E0425. This suite asserts the three #29 invariants
# on the DCE-ON build of the generated `main.rs` + bindings:
#   (1) the DEAD binding `deadSquare` (→ `dead_square`) is DROPPED from main.rs.
#   (2) its tree-shaken FFI wrapper `unused_3` is ABSENT from the bindings (the
#       very wrapper whose absence used to E0425 the emitted dead body).
#   (3) NO over-prune: the TRANSITIVELY-reached helper `livePrefix`
#       (→ `live_prefix`, reached only via `liveLabel`, never directly by main)
#       IS still emitted, AND the program runs `[ALL OK]`.
# Self-contained: stages its OWN workdir (committed fixture untouched).
# ─────────────────────────────────────────────────────────────────────────────
run_deadbinding_dce() {
  local base=52-ffi-dce-deadbinding
  local src="$FIXROOT/$base"
  [ -f "$src/src/Main.sky" ] || { _fail "$base-DCE (no such fixture)"; return; }

  local wd; wd="$(stage_workdir "$src")" || { _fail "$base-DCE (stage failed)"; return; }
  local binds; binds="$(bindings_file "$wd")" || { _fail "$base-DCE (cannot derive bindings path)"; rm -rf "$wd"; return; }

  # DCE-on build (default). Must succeed — pre-fix this build E0425'd.
  local bin; bin="$(build_fixture "$wd")" || { _fail "$base-DCE (build failed — entry-module dead binding not filtered? E0425)"; rm -rf "$wd"; return; }
  local mainrs="$wd/sky-out/rust/src/main.rs"
  [ -f "$mainrs" ] || { _fail "$base-DCE (no main.rs at $mainrs)"; rm -rf "$wd"; return; }

  # (1) dead binding dropped from main.rs.
  if rg -q 'dead_square' "$mainrs"; then
    _fail "$base-DCE(1): dead binding deadSquare LEAKED into main.rs (entry-module DCE not applied)"; rm -rf "$wd"; return
  fi
  # (2) its tree-shaken wrapper absent from bindings.
  if [ -f "$binds" ] && rg -q 'unused_3' "$binds"; then
    _fail "$base-DCE(2): tree-shaken wrapper unused_3 unexpectedly present in bindings"; rm -rf "$wd"; return
  fi
  # (3) no over-prune: transitively-reached helper kept.
  if ! rg -q 'live_prefix' "$mainrs"; then
    _fail "$base-DCE(3): OVER-PRUNE — transitively-reached livePrefix dropped from main.rs"; rm -rf "$wd"; return
  fi
  # (3 cont) runs [ALL OK].
  local outp="/tmp/ffi-fixture-$base-DCE.out"
  exercise_cli "$bin" "$outp" "$RUN_TMO" || { _fail "$base-DCE (run panicked/hung)"; rm -rf "$wd"; return; }
  if rg -q '\[ALL OK\]' "$outp"; then
    _ok "$base-DCE: dead deadSquare dropped · unused_3 tree-shaken · livePrefix kept (no over-prune) · [ALL OK]"
  else
    _fail "$base-DCE (no [ALL OK] — got: $(tr -d '\n' <"$outp"))"
  fi
  ( cd "$wd" && rm -rf sky-out/rust/target ) >/dev/null 2>&1
  rm -rf "$wd"
}

# ─────────────────────────────────────────────────────────────────────────────
# 73-ffi-serde — #47(a): serde-bound generic methods.
# POSITIVE: put / roundtrip / get_one bound; [ALL OK] emitted.
# NEGATIVE (P3 assertions from the spec):
#   C-G3: by_ref / pair / map_val ABSENT from bindings (inadmissible positions).
#   C-G1: own_serde ABSENT (crate-local Serialize, not serde's).
# ─────────────────────────────────────────────────────────────────────────────
run_serde() {
  local base=73-ffi-serde
  local src="$FIXROOT/$base"
  [ -f "$src/src/Main.sky" ] || { _fail "$base (no such fixture)"; return; }

  local wd; wd="$(stage_workdir "$src")" || { _fail "$base (stage failed)"; return; }
  local binds; binds="$(bindings_file "$wd")" || { _fail "$base (cannot derive bindings path)"; rm -rf "$wd"; return; }
  local bin;  bin="$(build_fixture "$wd")"  || { _fail "$base (build failed)"; rm -rf "$wd"; return; }

  # C-G3 + C-G1: inadmissible fns must be ABSENT from the bindings.
  for banned in by_ref pair map_val own_serde; do
    if [ -f "$binds" ] && rg -q "SKY-FFI-WRAPPER BEGIN $banned" "$binds"; then
      _fail "$base: inadmissible fn '$banned' leaked into bindings (C-G3/C-G1 violated)"; rm -rf "$wd"; return
    fi
  done

  # [ALL OK] output.
  local outp="/tmp/ffi-fixture-$base.out"
  exercise_cli "$bin" "$outp" "$RUN_TMO" || { _fail "$base (run panicked/hung)"; rm -rf "$wd"; return; }
  if rg -q '\[ALL OK\]' "$outp"; then
    _ok "$base  (put·roundtrip·get_one bound · by_ref/pair/map_val/own_serde absent · [ALL OK])"
  else
    _fail "$base (no [ALL OK] — got: $(tr -d '\n' <"$outp"))"
  fi
  ( cd "$wd" && rm -rf sky-out/rust/target ) >/dev/null 2>&1
  rm -rf "$wd"
}

# ─────────────────────────────────────────────────────────────────────────────
# 81-ffi-serde-ref — WALL 3a-&I (#65): extend the serde-mono to admit a `&T`
# SERIALIZE (input) param via owned-clone-at-boundary (the firestore
# `create_obj<T: Serialize>(&self, obj: &T)` shape).
# POSITIVE: create_obj (the `&T` serde INPUT) + put_obj (owned control) BIND;
#           the generated wrapper passes `&sv_1` (ref to the owned Value local).
# NEGATIVE: bad_mutref (`&mut T` → stays inadmissible) + bad_local (sibling
#           crate-local unmodellable bound) ABSENT from the bindings.
# Asserts [ALL OK] on the round-trip program.
# ─────────────────────────────────────────────────────────────────────────────
run_serde_ref() {
  local base=81-ffi-serde-ref
  local src="$FIXROOT/$base"
  [ -f "$src/src/Main.sky" ] || { _fail "$base (no such fixture)"; return; }

  local wd; wd="$(stage_workdir "$src")" || { _fail "$base (stage failed)"; return; }
  local binds; binds="$(bindings_file "$wd")" || { _fail "$base (cannot derive bindings path)"; rm -rf "$wd"; return; }
  local bin;  bin="$(build_fixture "$wd")"  || { _fail "$base (build failed)"; rm -rf "$wd"; return; }

  # NEGATIVE: &mut T + crate-local-bound fns must be ABSENT from the bindings.
  for banned in bad_mutref bad_local; do
    if [ -f "$binds" ] && rg -q "SKY-FFI-WRAPPER BEGIN $banned" "$binds"; then
      _fail "$base: inadmissible fn '$banned' leaked into bindings (&mut / non-serde-only)"; rm -rf "$wd"; return
    fi
  done

  # POSITIVE: create_obj (the `&T` serde INPUT) must BIND in the generic wrappers
  # AND pass a REFERENCE (`&sv_`) to the owned deserialised Value local — the
  # make-or-break codegen. The generic wrappers live in sky_ffi_generics.rs.
  local gen="$wd/sky-out/rust/src/sky_ffi_generics.rs"
  if ! rg -q 'SKY-FFI-WRAPPER BEGIN create_obj_from_db' "$gen" 2>/dev/null; then
    _fail "$base: create_obj_from_db did NOT bind (the &T serde INPUT must be admitted)"; rm -rf "$wd"; return
  fi
  if ! rg -q 'create_obj::<serde_json::Value>\(&arg0, &sv_' "$gen" 2>/dev/null; then
    _fail "$base: create_obj call site does NOT pass &sv_ (ref to owned Value) — unsound/absent codegen"; rm -rf "$wd"; return
  fi

  # [ALL OK] output.
  local outp="/tmp/ffi-fixture-$base.out"
  exercise_cli "$bin" "$outp" "$RUN_TMO" || { _fail "$base (run panicked/hung)"; rm -rf "$wd"; return; }
  if rg -q '\[ALL OK\]' "$outp"; then
    _ok "$base  (create_obj &T-serde-input binds + passes &sv_ · put_obj owned ctrl · bad_mutref/bad_local absent · [ALL OK])"
  else
    _fail "$base (no [ALL OK] — got: $(tr -d '\n' <"$outp"))"
  fi
  ( cd "$wd" && rm -rf sky-out/rust/target ) >/dev/null 2>&1
  rm -rf "$wd"
}


# ─────────────────────────────────────────────────────────────────────────────
# 83-ffi-mixed-generic-turbofish — WALL 4 stretch (#72): a method with N generics
# each reduced by a DIFFERENT mechanism (T serde→Value, S AsRef→String). The
# method-level turbofish must name a concrete PER generic in declaration order
# (`::<serde_json::Value, String>`), not just the serde one. Pre-#72: a single
# `::<serde_json::Value>` → E0107.
# POSITIVE: get_obj (2-gen async) + pick (3-gen async) + get_obj_sync (2-gen sync
#           concrete-Self trait) all BIND and emit the FULL ordered turbofish.
# Asserts [ALL OK] on the round-trip program.
# ─────────────────────────────────────────────────────────────────────────────
run_mixed_turbofish() {
  local base=83-ffi-mixed-generic-turbofish
  local src="$FIXROOT/$base"
  [ -f "$src/src/Main.sky" ] || { _fail "$base (no such fixture)"; return; }

  local wd; wd="$(stage_workdir "$src")" || { _fail "$base (stage failed)"; return; }
  local bin;  bin="$(build_fixture "$wd")"  || { _fail "$base (build failed — E0107 turbofish-arity?)"; rm -rf "$wd"; return; }

  # POSITIVE: the method-level turbofish must name a concrete PER generic in
  # declaration order — the make-or-break #72 codegen. The generic wrappers live
  # in sky_ffi_generics.rs.
  local gen="$wd/sky-out/rust/src/sky_ffi_generics.rs"
  # get_obj<T: DeserializeOwned, S: AsRef<str>> → ::<serde_json::Value, String>
  if ! rg -q 'get_obj::<serde_json::Value, String>' "$gen" 2>/dev/null; then
    _fail "$base: get_obj turbofish does NOT name both concretes (::<serde_json::Value, String>) — E0107 gap"; rm -rf "$wd"; return
  fi
  # pick<A: Serialize, B: AsRef<str>, C: DeserializeOwned> → 3 concretes in order
  if ! rg -q 'pick::<serde_json::Value, String, serde_json::Value>' "$gen" 2>/dev/null; then
    _fail "$base: pick (3-generic) turbofish does NOT name all three concretes in order"; rm -rf "$wd"; return
  fi
  # get_obj_sync (sync concrete-Self trait) → ::<serde_json::Value, String>
  if ! rg -q 'get_obj_sync::<serde_json::Value, String>' "$gen" 2>/dev/null; then
    _fail "$base: get_obj_sync (sync) turbofish does NOT name both concretes"; rm -rf "$wd"; return
  fi

  # [ALL OK] output.
  local outp="/tmp/ffi-fixture-$base.out"
  exercise_cli "$bin" "$outp" "$RUN_TMO" || { _fail "$base (run panicked/hung)"; rm -rf "$wd"; return; }
  if rg -q '\[ALL OK\]' "$outp"; then
    _ok "$base  (get_obj ::<Value,String> · pick ::<Value,String,Value> · get_obj_sync ::<Value,String> · cargo-clean no E0107 · [ALL OK])"
  else
    _fail "$base (no [ALL OK] — got: $(tr -d '\n' <"$outp"))"
  fi
  ( cd "$wd" && rm -rf sky-out/rust/target ) >/dev/null 2>&1
  rm -rf "$wd"
}


# ─────────────────────────────────────────────────────────────────────────────
# 89-ffi-static-str-into — WALL-E (#78): a method param bounded by
# `Into<&'static str>` is UNSATISFIABLE from a runtime-owned Sky `String` (a
# String can LEND a borrow but never BECOME a `&'static str`). The inspector
# must FAIL-CLOSED DROP it (no wrapper). Pre-WALL-E it mono'd `P → String` and
# emitted `arg0.build(&arg1)` → `E0277: &'static str: From<&String>` (the exact
# firebase `ApiUriBuilder::build<PathT: Into<&'static str>>` shape).
# Built under FORCED SKY_DCE=0 so the no-E0277 + drop is proven over the FULL
# bound surface (not just the DCE-reachable subset).
# NEGATIVE: `build_from_router` must NOT appear (fail-closed drop).
# POSITIVE: `tag_from_router` (AsRef<str>→String #58) + `label_from_router`
#   (Into<String> OWNED target — the discriminator: owned-Into stays sound) +
#   `new_from_router` (owned-String ctor #67) bind, and the program runs [ALL OK].
# ─────────────────────────────────────────────────────────────────────────────
run_static_str_into() {
  local base=89-ffi-static-str-into
  local src="$FIXROOT/$base"
  [ -f "$src/src/Main.sky" ] || { _fail "$base (no such fixture)"; return; }

  local wd; wd="$(stage_workdir "$src")" || { _fail "$base (stage failed)"; return; }
  local binds; binds="$(bindings_file "$wd")" || { _fail "$base (cannot derive bindings path)"; rm -rf "$wd"; return; }
  # FORCE a full emit so EVERY bound wrapper must cargo-compile — the WALL-E
  # E0277 lives on `build`, which DCE would tree-shake away (Main can't call a
  # dropped fn), masking the regression. SKY_DCE=0 keeps the full surface.
  local bin; bin="$(SKY_DCE=0 build_fixture "$wd")" || { _fail "$base (build failed — E0277 &'static str: From<&String> not dropped?)"; rm -rf "$wd"; return; }

  # NEGATIVE: the `Into<&'static str>` method must be fail-closed dropped.
  if rg -q 'SKY-FFI-WRAPPER BEGIN build_from_router' "$binds" 2>/dev/null; then
    _fail "$base: build (Into<&'static str>) wrapper leaked into bindings (WALL-E over-admit → E0277)"; rm -rf "$wd"; return
  fi
  if rg -q '\.build\(&arg' "$binds" 2>/dev/null; then
    _fail "$base: an `arg0.build(&arg1)` call (the WALL-E bug) is present in bindings"; rm -rf "$wd"; return
  fi
  # POSITIVE controls must keep binding (no over-drop).
  for w in new_from_router tag_from_router label_from_router; do
    if ! rg -q "SKY-FFI-WRAPPER BEGIN $w" "$binds" 2>/dev/null; then
      _fail "$base: control wrapper '$w' missing — WALL-E over-dropped a sound bind"; rm -rf "$wd"; return
    fi
  done

  # [ALL OK] output (build was already cargo-clean to reach here).
  local outp="/tmp/ffi-fixture-$base.out"
  exercise_cli "$bin" "$outp" "$RUN_TMO" || { _fail "$base (run panicked/hung)"; rm -rf "$wd"; return; }
  if rg -q '\[ALL OK\]' "$outp"; then
    _ok "$base  (build Into<&'static str> DROPPED · tag AsRef<str> + label Into<String> bind · cargo-clean no E0277 · [ALL OK])"
  else
    _fail "$base (no [ALL OK] — got: $(tr -d '\n' <"$outp"))"
  fi
  ( cd "$wd" && rm -rf sky-out/rust/target ) >/dev/null 2>&1
  rm -rf "$wd"
}


# ─────────────────────────────────────────────────────────────────────────────
# 90-ffi-default-trait-method-mono — WALL-F (#81): a trait with DEFAULT-body RPITIT
# async methods, impl'd for a generic Self `Handle<C>` whose `C` is bounded by the
# UNIQUE-impl trait `Client`, plus an inherent ctor returning the concrete
# `Handle<RealClient>`. WALL-F (a) monomorphizes the Self via the unique impl, (b)
# projects the trait's default methods (which live on the trait DEF, never under
# the impl), recognises the RPITIT `-> impl Future + Send`, proves the receiver
# Send via the `: Send` supertrait, exempts the `Result` error slot.
# Built under FORCED SKY_DCE=0 so the projected wrapper must cargo-compile.
# POSITIVE: `op_from_handle` (DEFAULT + RPITIT) binds + runs ("real:hi").
# NEGATIVE: op_nosend (?Send) · op_extra (where C: Extra) · op_count (usize param)
#   must ALL be absent (fail-closed).
# ─────────────────────────────────────────────────────────────────────────────
run_default_trait_mono() {
  local base=90-ffi-default-trait-method-mono
  local src="$FIXROOT/$base"
  [ -f "$src/src/Main.sky" ] || { _fail "$base (no such fixture)"; return; }

  local wd; wd="$(stage_workdir "$src")" || { _fail "$base (stage failed)"; return; }
  local gen; gen="$wd/sky-out/rust/src/sky_ffi_generics.rs"
  local bin; bin="$(SKY_DCE=0 build_fixture "$wd")" || { _fail "$base (build failed — projected RPITIT wrapper cargo-fail?)"; rm -rf "$wd"; return; }

  # POSITIVE: the projected default RPITIT method binds (UFCS generic wrapper).
  if ! rg -q 'fn default_trait_crate_op_from_handle' "$gen" 2>/dev/null; then
    _fail "$base: projected default method 'op' did NOT bind (WALL-F (b) projection broken)"; rm -rf "$wd"; return
  fi
  # NEGATIVE: the three fail-closed default methods must be ABSENT everywhere.
  for banned in op_nosend op_extra op_count; do
    if rg -q "$banned" "$wd"/sky-out/rust/src/*.rs 2>/dev/null; then
      _fail "$base: fail-closed default method '$banned' leaked into bindings"; rm -rf "$wd"; return
    fi
  done

  local outp="/tmp/ffi-fixture-$base.out"
  exercise_cli "$bin" "$outp" "$RUN_TMO" || { _fail "$base (run panicked/hung)"; rm -rf "$wd"; return; }
  if rg -q '\[ALL OK\]' "$outp"; then
    _ok "$base  (default RPITIT 'op' projected+bound+ran 'real:hi' · op_nosend/op_extra/op_count fail-closed · cargo-clean · [ALL OK])"
  else
    _fail "$base (no [ALL OK] — got: $(tr -d '\n' <"$outp"))"
  fi
  ( cd "$wd" && rm -rf sky-out/rust/target ) >/dev/null 2>&1
  rm -rf "$wd"
}


# ─────────────────────────────────────────────────────────────────────────────
# 85-ffi-vec-struct-field — WALL-A (#74): a foreign struct with a
# `Vec<StructType>` field. The field SETTER's param type must be the REAL
# `Vec<Inner>` (Inner a bound Clone-opaque), NEVER the bug's `Vec<String>` —
# which E0308s at cargo build. Pre-#74: `resolveRustType` short-circuited a
# `List <opaque>` field through `skyTypeToRust` → `Vec<String>`.
# POSITIVE 1: items (Vec<Inner>) getter+setter bind with `Vec<::…::Inner>`.
# POSITIVE 2: tags (Vec<String>) getter+setter still work (no-regress).
# NEGATIVE:   Bag.bad (Vec<NonClone>, NonClone not Clone) → no accessor.
# Asserts: build is cargo-CLEAN (no E0308), the items setter is typed
# `Vec<::…::Inner>` and NOT `Vec<String>`, and the program prints [ALL OK].
# ─────────────────────────────────────────────────────────────────────────────
run_vec_struct_field() {
  local base=85-ffi-vec-struct-field
  local src="$FIXROOT/$base"
  [ -f "$src/src/Main.sky" ] || { _fail "$base (no such fixture)"; return; }

  local wd; wd="$(stage_workdir "$src")" || { _fail "$base (stage failed)"; return; }
  local binds; binds="$(bindings_file "$wd")" || { _fail "$base (cannot derive bindings path)"; rm -rf "$wd"; return; }
  local bin;  bin="$(build_fixture "$wd")"  || { _fail "$base (build failed — E0308 Vec<String> vs Vec<Inner>?)"; rm -rf "$wd"; return; }

  # CRITICAL INVARIANT: the items setter must be the REAL Vec<Inner> type, and a
  # `Vec<String>` setter for items must NEVER appear (the WALL-A bug). The items
  # setter wrapper line carries `arg0: Vec<::vecstructfield::Inner>`.
  if ! rg -q 'fn vecstructfield_items_set_field_from_outer\(arg0: Vec<::vecstructfield::Inner>' "$binds" 2>/dev/null; then
    _fail "$base: items setter is NOT typed Vec<::vecstructfield::Inner> (WALL-A type-collapse not fixed)"; rm -rf "$wd"; return
  fi
  if rg -q 'fn vecstructfield_items_set_field_from_outer\(arg0: Vec<String>' "$binds" 2>/dev/null; then
    _fail "$base: items setter emitted Vec<String> for a Vec<Inner> field (the WALL-A bug)"; rm -rf "$wd"; return
  fi
  # NEGATIVE: Bag.bad (Vec<NonClone>) must have NO accessor at all.
  for banned in bad_field bad_set_field; do
    if rg -q "SKY-FFI-WRAPPER BEGIN $banned" "$binds" 2>/dev/null; then
      _fail "$base: Vec<NonClone> field accessor '$banned' leaked into bindings (not fail-closed)"; rm -rf "$wd"; return
    fi
  done

  # [ALL OK] output (build was already cargo-clean to reach here).
  local outp="/tmp/ffi-fixture-$base.out"
  exercise_cli "$bin" "$outp" "$RUN_TMO" || { _fail "$base (run panicked/hung)"; rm -rf "$wd"; return; }
  if rg -q '\[ALL OK\]' "$outp"; then
    _ok "$base  (items setter Vec<Inner> not Vec<String> · tags Vec<String> no-regress · Bag.bad Vec<NonClone> absent · cargo-clean · [ALL OK])"
  else
    _fail "$base (no [ALL OK] — got: $(tr -d '\n' <"$outp"))"
  fi
  ( cd "$wd" && rm -rf sky-out/rust/target ) >/dev/null 2>&1
  rm -rf "$wd"
}


# ─────────────────────────────────────────────────────────────────────────────
# 91-ffi-cross-crate-impl — WALL-G (#84): CROSS-CRATE unique-impl monomorphization.
# TWO sibling git crates: wire-crate defines `trait Wire` + `Req::op<C: Wire>` with
# NO impl; client-crate holds the unique `impl Wire for RealClient`. WALL-G builds a
# process-global, canonical-path-keyed concrete-impl index spanning BOTH (one
# inspector invocation via the `--manifest` Haskell single-call), resolves `op`'s
# `C: Wire` to the cross-crate `client_crate::RealClient`, and emits a wrapper that
# references it by the FROZEN owning-crate public path. This is the stripe
# `send<C: StripeClient>` shape (send in client-core, impl in the facade).
# Built under FORCED SKY_DCE=0 so the cross-crate wrapper MUST cargo-compile.
# POSITIVE: `op_from_req` binds (param `&client_crate::RealClient`) + runs "real:hi".
# Custom two-crate staging (the shared stage_workdir assumes a single `$base-crate`).
# ─────────────────────────────────────────────────────────────────────────────
run_cross_crate_impl() {
  local base=91-ffi-cross-crate-impl
  local src="$FIXROOT/$base"
  [ -f "$src/src/Main.sky" ] || { _fail "$base (no such fixture)"; return; }
  [ -f "$src/setup.sh" ]     || { _fail "$base (no setup.sh)"; return; }

  # 1. Stage BOTH crates (wire at …-wire, client at …-client).
  bash "$src/setup.sh" >/tmp/ffi-fixture-"$base".setup.log 2>&1 || {
    _fail "$base (setup.sh failed — see /tmp/ffi-fixture-$base.setup.log)"; return; }
  local wireDir="$HOME/.cache/sky/$base-wire" cliDir="$HOME/.cache/sky/$base-client"
  [ -d "$wireDir/.git" ] && [ -d "$cliDir/.git" ] || {
    _fail "$base (expected staged crates at $wireDir + $cliDir)"; return; }

  # 2. Clean workdir copy of sources + sky.toml; rewrite BOTH file:// URLs to the
  #    actually-staged paths (host-$HOME-agnostic, matched by the stable suffix).
  local wd; wd="$(mktemp -d "${TMPDIR:-/tmp}/ffi-fixture-$base.XXXXXX")" || { _fail "$base (mktemp)"; return; }
  mkdir -p "$wd/src"
  cp -r "$src/src/." "$wd/src/" 2>/dev/null || true
  cp "$src/sky.toml" "$wd/sky.toml" || { _fail "$base (cp sky.toml)"; rm -rf "$wd"; return; }
  local escW escC
  escW="$(printf 'file://%s' "$wireDir" | sed -e 's/[\/&]/\\&/g')"
  escC="$(printf 'file://%s' "$cliDir"  | sed -e 's/[\/&]/\\&/g')"
  sed -i -E "s|file://[^\"]*/$base-wire|$escW|g;   s|file://[^\"]*/$base-client|$escC|g" "$wd/sky.toml" \
    || { _fail "$base (sed sky.toml)"; rm -rf "$wd"; return; }

  # 3. Build under forced SKY_DCE=0 (the cross-crate wrapper must cargo-compile even
  #    in full-surface emit — the type-checks-but-cargo-fails class this gate exists for).
  local bin; bin="$(SKY_DCE=0 build_fixture "$wd")" || {
    _fail "$base (build failed — cross-crate op_from_req cargo-fail? E0412/E0433/E0277)"; rm -rf "$wd"; return; }

  # 4. POSITIVE: the cross-crate method binds, typed against the sibling concrete.
  local binds="$wd/sky-out/rust/src/wire_crate_bindings.rs"
  if ! rg -q 'fn wire_crate_op_from_req' "$binds" 2>/dev/null; then
    _fail "$base: cross-crate method 'op' did NOT bind (WALL-G global index broken)"; rm -rf "$wd"; return
  fi
  if ! rg -q 'client_crate::RealClient' "$binds" 2>/dev/null; then
    _fail "$base: op wrapper does not reference the frozen cross-crate path client_crate::RealClient (B2)"; rm -rf "$wd"; return
  fi

  local outp="/tmp/ffi-fixture-$base.out"
  exercise_cli "$bin" "$outp" "$RUN_TMO" || { _fail "$base (run panicked/hung)"; rm -rf "$wd"; return; }
  if rg -q '\[ALL OK\]' "$outp"; then
    _ok "$base  (cross-crate op<C: Wire> → client_crate::RealClient bound+ran 'real:hi' · SKY_DCE=0 cargo-clean · [ALL OK])"
  else
    _fail "$base (no [ALL OK] — got: $(tr -d '\n' <"$outp"))"
  fi
  ( cd "$wd" && rm -rf sky-out/rust/target ) >/dev/null 2>&1
  rm -rf "$wd"
}


# ─────────────────────────────────────────────────────────────────────────────
# 92-ffi-generic-self-open-t — WALL-H (#87): async generic-Self open-T `send`. req-crate
# defines generic `impl<T: Decode> Customizable<T>` with async `send<C: Wire>` (assoc-type
# Err) + sync `send_blocking`; client-crate holds the unique `impl Wire for RealClient`
# (WALL-G resolves C) + concrete `Resp: Decode` (T resolves to it). WALL-H binds the async
# `send`: the moved receiver `Customizable<Resp>` is proven Send STRUCTURALLY (base
# Send-when-args-Send + Resp frozen-Send) and the `Resp` Ok output via the frozen-Send
# OPAQUE set. Built under FORCED SKY_DCE=0. Two-crate staging (like 91).
# POSITIVE: send_from_customizable binds (Task Error Resp) + runs "decoded:hi".
# ─────────────────────────────────────────────────────────────────────────────
run_generic_self_open_t() {
  local base=92-ffi-generic-self-open-t
  local src="$FIXROOT/$base"
  [ -f "$src/src/Main.sky" ] || { _fail "$base (no such fixture)"; return; }
  [ -f "$src/setup.sh" ]     || { _fail "$base (no setup.sh)"; return; }

  bash "$src/setup.sh" >/tmp/ffi-fixture-"$base".setup.log 2>&1 || {
    _fail "$base (setup.sh failed — see /tmp/ffi-fixture-$base.setup.log)"; return; }
  local reqDir="$HOME/.cache/sky/$base-req" cliDir="$HOME/.cache/sky/$base-client"
  [ -d "$reqDir/.git" ] && [ -d "$cliDir/.git" ] || {
    _fail "$base (expected staged crates at $reqDir + $cliDir)"; return; }

  local wd; wd="$(mktemp -d "${TMPDIR:-/tmp}/ffi-fixture-$base.XXXXXX")" || { _fail "$base (mktemp)"; return; }
  mkdir -p "$wd/src"
  cp -r "$src/src/." "$wd/src/" 2>/dev/null || true
  cp "$src/sky.toml" "$wd/sky.toml" || { _fail "$base (cp sky.toml)"; rm -rf "$wd"; return; }
  local escR escC
  escR="$(printf 'file://%s' "$reqDir" | sed -e 's/[\/&]/\\&/g')"
  escC="$(printf 'file://%s' "$cliDir" | sed -e 's/[\/&]/\\&/g')"
  sed -i -E "s|file://[^\"]*/$base-req|$escR|g;   s|file://[^\"]*/$base-client|$escC|g" "$wd/sky.toml" \
    || { _fail "$base (sed sky.toml)"; rm -rf "$wd"; return; }

  local bin; bin="$(SKY_DCE=0 build_fixture "$wd")" || {
    _fail "$base (build failed — async generic-Self send cargo-fail? E0277 non-Send future?)"; rm -rf "$wd"; return; }

  local binds="$wd/sky-out/rust/src/req_crate_bindings.rs"
  if ! rg -q 'fn req_crate_send_from_customizable' "$binds" 2>/dev/null; then
    _fail "$base: async 'send' did NOT bind (WALL-H structural Send proof broken)"; rm -rf "$wd"; return
  fi

  local outp="/tmp/ffi-fixture-$base.out"
  exercise_cli "$bin" "$outp" "$RUN_TMO" || { _fail "$base (run panicked/hung)"; rm -rf "$wd"; return; }
  if rg -q '\[ALL OK\]' "$outp"; then
    _ok "$base  (async generic-Self send<C> on Customizable<Resp> bound+ran 'decoded:hi' · SKY_DCE=0 cargo-clean · [ALL OK])"
  else
    _fail "$base (no [ALL OK] — got: $(tr -d '\n' <"$outp"))"
  fi
  ( cd "$wd" && rm -rf sky-out/rust/target ) >/dev/null 2>&1
  rm -rf "$wd"
}


# ─────────────────────────────────────────────────────────────────────────────
# 93-ffi-customize-chain — WALL-I (#88): the stripe `.customize()` PRODUCER chain
# that makes WALL-H's `send` USABLE. Single thing-crate: resource `CreateThing`,
# its `WireReq` impl (`type Output = Resp`) + the PROVIDED `customize()` returning
# `Customizable<Self::Output>`, the response `Resp`, the client `LocalClient`, and
# `Customizable<T>` + async `send`. WALL-I projects `customize` onto the concrete
# `CreateThing` (resolves `Self::Output → Resp`), yielding `Customizable<Resp>`;
# the consistency fix renders that crate-local opaque generic struct BARE on the
# RETURN path so it unifies with `send`'s bare-opaque RECEIVER. Built under FORCED
# SKY_DCE=0. POSITIVE: new→customize→send chain runs "decoded:seed".
# ─────────────────────────────────────────────────────────────────────────────
run_customize_chain() {
  local base=93-ffi-customize-chain
  local src="$FIXROOT/$base"
  [ -f "$src/src/Main.sky" ] || { _fail "$base (no such fixture)"; return; }
  [ -f "$src/setup.sh" ]     || { _fail "$base (no setup.sh)"; return; }

  bash "$src/setup.sh" >/tmp/ffi-fixture-"$base".setup.log 2>&1 || {
    _fail "$base (setup.sh failed — see /tmp/ffi-fixture-$base.setup.log)"; return; }
  local thingDir="$HOME/.cache/sky/$base-thing"
  [ -d "$thingDir/.git" ] || {
    _fail "$base (expected staged crate at $thingDir)"; return; }

  local wd; wd="$(mktemp -d "${TMPDIR:-/tmp}/ffi-fixture-$base.XXXXXX")" || { _fail "$base (mktemp)"; return; }
  mkdir -p "$wd/src"
  cp -r "$src/src/." "$wd/src/" 2>/dev/null || true
  cp "$src/sky.toml" "$wd/sky.toml" || { _fail "$base (cp sky.toml)"; rm -rf "$wd"; return; }
  local escT
  escT="$(printf 'file://%s' "$thingDir" | sed -e 's/[\/&]/\\&/g')"
  sed -i -E "s|file://[^\"]*/$base-thing|$escT|g" "$wd/sky.toml" \
    || { _fail "$base (sed sky.toml)"; rm -rf "$wd"; return; }

  # Built under forced SKY_DCE=0: the producer chain must cargo-compile even in
  # full-surface emit. The consistency fix is exactly what keeps `customize`'s
  # return (`Customizable Resp` pre-fix) unifying with `send`'s receiver.
  local bin; bin="$(SKY_DCE=0 build_fixture "$wd")" || {
    _fail "$base (build failed — customize/send Sky-type mismatch? Customizable Resp vs Customizable)"; rm -rf "$wd"; return; }

  # POSITIVE: customize binds (projected provided-method → the GENERICS file, since
  # it is a projected trait-default wrapper) AND send binds on the same receiver
  # (an inherent method → the bindings file).
  local gen="$wd/sky-out/rust/src/sky_ffi_generics.rs"
  local binds="$wd/sky-out/rust/src/thing_crate_bindings.rs"
  if ! rg -q 'fn thing_crate_customize' "$gen" 2>/dev/null; then
    _fail "$base: provided-method 'customize' did NOT project onto CreateThing (WALL-I projection broken)"; rm -rf "$wd"; return
  fi
  if ! rg -q 'fn thing_crate_send_from_customizable' "$binds" 2>/dev/null; then
    _fail "$base: async 'send' did NOT bind on the customized request (WALL-H)"; rm -rf "$wd"; return
  fi

  local outp="/tmp/ffi-fixture-$base.out"
  exercise_cli "$bin" "$outp" "$RUN_TMO" || { _fail "$base (run panicked/hung)"; rm -rf "$wd"; return; }
  if rg -q '\[ALL OK\]' "$outp"; then
    _ok "$base  (CreateThing.customize→Customizable<Resp>→send chain bound+ran 'decoded:seed' · SKY_DCE=0 cargo-clean · [ALL OK])"
  else
    _fail "$base (no [ALL OK] — got: $(tr -d '\n' <"$outp"))"
  fi
  ( cd "$wd" && rm -rf sky-out/rust/target ) >/dev/null 2>&1
  rm -rf "$wd"
}


# ─────────────────────────────────────────────────────────────────────────────
# 94-ffi-inherent-self-output — WALL-J Stage 1 (#91): inherent-method
# `<Self as ForeignTrait>::Output` return projection (sync, non-generic, one crate).
# `Thing::out(&self) -> <Self as LocalTrait>::Output` must resolve to `Payload` via
# the SIBLING `impl LocalTrait for Thing { type Output = Payload }` — pre-fix it
# rendered the bare assoc name `Output` (a bogus Sky type). Built under FORCED
# SKY_DCE=0. POSITIVE: new→out→shown runs "out:seed".
# ─────────────────────────────────────────────────────────────────────────────
run_inherent_self_output() {
  local base=94-ffi-inherent-self-output
  local src="$FIXROOT/$base"
  [ -f "$src/src/Main.sky" ] || { _fail "$base (no such fixture)"; return; }
  [ -f "$src/setup.sh" ]     || { _fail "$base (no setup.sh)"; return; }

  bash "$src/setup.sh" >/tmp/ffi-fixture-"$base".setup.log 2>&1 || {
    _fail "$base (setup.sh failed — see /tmp/ffi-fixture-$base.setup.log)"; return; }
  local crateDir="$HOME/.cache/sky/$base-crate"
  [ -d "$crateDir/.git" ] || { _fail "$base (expected staged crate at $crateDir)"; return; }

  local wd; wd="$(mktemp -d "${TMPDIR:-/tmp}/ffi-fixture-$base.XXXXXX")" || { _fail "$base (mktemp)"; return; }
  mkdir -p "$wd/src"
  cp -r "$src/src/." "$wd/src/" 2>/dev/null || true
  cp "$src/sky.toml" "$wd/sky.toml" || { _fail "$base (cp sky.toml)"; rm -rf "$wd"; return; }
  local escC
  escC="$(printf 'file://%s' "$crateDir" | sed -e 's/[\/&]/\\&/g')"
  sed -i -E "s|file://[^\"]*/$base-crate|$escC|g" "$wd/sky.toml" \
    || { _fail "$base (sed sky.toml)"; rm -rf "$wd"; return; }

  local bin; bin="$(SKY_DCE=0 build_fixture "$wd")" || {
    _fail "$base (build failed — Self::Output projection unresolved? bogus 'Output' type / E0412)"; rm -rf "$wd"; return; }

  # POSITIVE: `out` must bind returning Payload (NOT the bogus assoc name `Output`).
  local skyi="$wd/.skycache/ffi/rust/selfout-crate.skyi"
  if ! rg -q 'out_from_thing : Thing -> Result Error Payload' "$skyi" 2>/dev/null; then
    _fail "$base: out did NOT resolve <Self as LocalTrait>::Output to Payload (WALL-J broken) — got: $(rg 'out_from_thing' "$skyi" 2>/dev/null)"; rm -rf "$wd"; return
  fi

  local outp="/tmp/ffi-fixture-$base.out"
  exercise_cli "$bin" "$outp" "$RUN_TMO" || { _fail "$base (run panicked/hung)"; rm -rf "$wd"; return; }
  if rg -q '\[ALL OK\]' "$outp"; then
    _ok "$base  (inherent Thing.out -> <Self as LocalTrait>::Output resolved to Payload via sibling impl · SKY_DCE=0 cargo-clean · [ALL OK])"
  else
    _fail "$base (no [ALL OK] — got: $(tr -d '\n' <"$outp"))"
  fi
  ( cd "$wd" && rm -rf sky-out/rust/target ) >/dev/null 2>&1
  rm -rf "$wd"
}


# ─────────────────────────────────────────────────────────────────────────────
# 95-ffi-inherent-self-output-async — WALL-J Stage 2+3 (#91): the REAL async-stripe
# `send` shape in one crate. Inherent `async fn send<C: LocalClient>(&self, c: &C) ->
# Result<<Self as Req>::Output, C::Err>` + `impl Req for CreateReq { type Output =
# Resp }` + a unique `impl LocalClient for RealClient`. Validates the full
# composition: WALL-J Self::Output (Ok) + de-async + #52 C-mono + C::Err→SkyError +
# &self async-Send. SKY_DCE=0. POSITIVE: send runs "sent:seed".
# ─────────────────────────────────────────────────────────────────────────────
run_inherent_self_output_async() {
  local base=95-ffi-inherent-self-output-async
  local src="$FIXROOT/$base"
  [ -f "$src/src/Main.sky" ] || { _fail "$base (no such fixture)"; return; }
  [ -f "$src/setup.sh" ]     || { _fail "$base (no setup.sh)"; return; }

  bash "$src/setup.sh" >/tmp/ffi-fixture-"$base".setup.log 2>&1 || {
    _fail "$base (setup.sh failed — see /tmp/ffi-fixture-$base.setup.log)"; return; }
  local crateDir="$HOME/.cache/sky/$base-crate"
  [ -d "$crateDir/.git" ] || { _fail "$base (expected staged crate at $crateDir)"; return; }

  local wd; wd="$(mktemp -d "${TMPDIR:-/tmp}/ffi-fixture-$base.XXXXXX")" || { _fail "$base (mktemp)"; return; }
  mkdir -p "$wd/src"
  cp -r "$src/src/." "$wd/src/" 2>/dev/null || true
  cp "$src/sky.toml" "$wd/sky.toml" || { _fail "$base (cp sky.toml)"; rm -rf "$wd"; return; }
  local escC
  escC="$(printf 'file://%s' "$crateDir" | sed -e 's/[\/&]/\\&/g')"
  sed -i -E "s|file://[^\"]*/$base-crate|$escC|g" "$wd/sky.toml" \
    || { _fail "$base (sed sky.toml)"; rm -rf "$wd"; return; }

  local bin; bin="$(SKY_DCE=0 build_fixture "$wd")" || {
    _fail "$base (build failed — async Self::Output send compose cargo-fail?)"; rm -rf "$wd"; return; }

  # POSITIVE: the real-stripe-shaped send binds with the Ok = Resp (Self::Output
  # resolved) and the cross-bound C mono'd to RealClient.
  local skyi="$wd/.skycache/ffi/rust/sendreq-crate.skyi"
  if ! rg -q 'send_from_createReq : CreateReq -> RealClient -> Task Error Resp' "$skyi" 2>/dev/null; then
    _fail "$base: async send did NOT bind as CreateReq -> RealClient -> Task Error Resp (WALL-J+#52 compose broken) — got: $(rg 'send_from_createReq' "$skyi" 2>/dev/null)"; rm -rf "$wd"; return
  fi

  local outp="/tmp/ffi-fixture-$base.out"
  exercise_cli "$bin" "$outp" "$RUN_TMO" || { _fail "$base (run panicked/hung)"; rm -rf "$wd"; return; }
  if rg -q '\[ALL OK\]' "$outp"; then
    _ok "$base  (inherent async send<C> -> Result<<Self as Req>::Output, C::Err> bound+ran 'sent:seed' · SKY_DCE=0 cargo-clean · [ALL OK])"
  else
    _fail "$base (no [ALL OK] — got: $(tr -d '\n' <"$outp"))"
  fi
  ( cd "$wd" && rm -rf sky-out/rust/target ) >/dev/null 2>&1
  rm -rf "$wd"
}


# ─────────────────────────────────────────────────────────────────────────────
# 96-ffi-external-trait-xcrate — WALL-K (#92): cross-crate resolution for an EXTERNAL
# trait bound (the 3-crate triangle). `Trip::go<T: Walker>(&self, w: &T)` where Walker is
# in crate B (walk-trait, EXTERNAL to method crate A) and its UNIQUE impl `Boots` is in
# crate C (walk-impl). WALL-G keyed cross-crate resolution by crate-LOCAL trait only;
# WALL-K routes an EXTERNAL trait bound's canon (canon_path_of_id over trait-kind
# doc[paths]) to the global XC index. The exact real-stripe `send<C: StripeClient>` shape.
# SKY_DCE=0. POSITIVE: go resolves T→Boots cross-crate + runs "trip:x:boots".
# ─────────────────────────────────────────────────────────────────────────────
run_external_trait_xcrate() {
  local base=96-ffi-external-trait-xcrate
  local src="$FIXROOT/$base"
  [ -f "$src/src/Main.sky" ] || { _fail "$base (no such fixture)"; return; }
  [ -f "$src/setup.sh" ]     || { _fail "$base (no setup.sh)"; return; }

  bash "$src/setup.sh" >/tmp/ffi-fixture-"$base".setup.log 2>&1 || {
    _fail "$base (setup.sh failed — see /tmp/ffi-fixture-$base.setup.log)"; return; }
  local mDir="$HOME/.cache/sky/$base-method" iDir="$HOME/.cache/sky/$base-impl" tDir="$HOME/.cache/sky/$base-trait"
  [ -d "$mDir/.git" ] && [ -d "$iDir/.git" ] && [ -d "$tDir/.git" ] || {
    _fail "$base (expected staged crates at $mDir + $iDir + $tDir)"; return; }

  local wd; wd="$(mktemp -d "${TMPDIR:-/tmp}/ffi-fixture-$base.XXXXXX")" || { _fail "$base (mktemp)"; return; }
  mkdir -p "$wd/src"
  cp -r "$src/src/." "$wd/src/" 2>/dev/null || true
  cp "$src/sky.toml" "$wd/sky.toml" || { _fail "$base (cp sky.toml)"; rm -rf "$wd"; return; }
  local escM escI escT
  escM="$(printf 'file://%s' "$mDir" | sed -e 's/[\/&]/\\&/g')"
  escI="$(printf 'file://%s' "$iDir" | sed -e 's/[\/&]/\\&/g')"
  escT="$(printf 'file://%s' "$tDir" | sed -e 's/[\/&]/\\&/g')"
  sed -i -E "s|file://[^\"]*/$base-method|$escM|g; s|file://[^\"]*/$base-impl|$escI|g; s|file://[^\"]*/$base-trait|$escT|g" "$wd/sky.toml" \
    || { _fail "$base (sed sky.toml)"; rm -rf "$wd"; return; }

  local bin; bin="$(SKY_DCE=0 build_fixture "$wd")" || {
    _fail "$base (build failed — external-trait C unresolved? unmodellable-bound / cargo-fail)"; rm -rf "$wd"; return; }

  local skyi="$wd/.skycache/ffi/rust/walk-method.skyi"
  if ! rg -q 'go_from_trip : Trip -> Boots -> Task Error String' "$skyi" 2>/dev/null; then
    _fail "$base: go<T: Walker> did NOT resolve T→Boots cross-crate (WALL-K broken) — got: $(rg 'go_from_trip' "$skyi" 2>/dev/null)"; rm -rf "$wd"; return
  fi
  # [WALL-J∘WALL-K compose] go2 = the EXACT real-stripe send shape: `<Self as Req>::Output`
  # (WALL-J sibling-assoc over the EXTERNAL Req trait, impl crate-local) + cross-crate
  # `T: Walker` (WALL-K) + `T::Err`, async. Proves the full composition the real
  # `CreateCustomer::send<C: StripeClient>(&self) -> Result<<Self as StripeRequest>::Output, C::Err>` needs.
  if ! rg -q 'go2_from_trip : Trip -> Boots -> Task Error Outcome' "$skyi" 2>/dev/null; then
    _fail "$base: go2 (Self::Output ∘ cross-crate-T compose) did NOT bind — got: $(rg 'go2_from_trip' "$skyi" 2>/dev/null)"; rm -rf "$wd"; return
  fi

  local outp="/tmp/ffi-fixture-$base.out"
  exercise_cli "$bin" "$outp" "$RUN_TMO" || { _fail "$base (run panicked/hung)"; rm -rf "$wd"; return; }
  if rg -q '\[ALL OK\]' "$outp"; then
    _ok "$base  (external-trait T: Walker → cross-crate Boots; go2 composes <Self as Req>::Output + cross-crate-C + C::Err = the real-stripe send shape · SKY_DCE=0 cargo-clean · [ALL OK])"
  else
    _fail "$base (no [ALL OK] — got: $(tr -d '\n' <"$outp"))"
  fi
  ( cd "$wd" && rm -rf sky-out/rust/target ) >/dev/null 2>&1
  rm -rf "$wd"
}


# ─────────────────────────────────────────────────────────────────────────────
# 97-ffi-numeric-param-coerce — #82: SATURATING numeric param-width coercion on the
# regular inherent path. Sky Int(i64)/Float(f64) → foreign usize/u32/f32 params,
# clamped into the target range (NEVER silent `as` wraparound). argCall→numSaturate.
# POSITIVE: widen(5,3,2.0)=20; echo_u32(5_000_000_000) SATURATES to 4294967295.
# ─────────────────────────────────────────────────────────────────────────────
run_numeric_param_coerce() {
  local base=97-ffi-numeric-param-coerce
  local src="$FIXROOT/$base"
  [ -f "$src/src/Main.sky" ] || { _fail "$base (no such fixture)"; return; }
  [ -f "$src/setup.sh" ]     || { _fail "$base (no setup.sh)"; return; }
  bash "$src/setup.sh" >/tmp/ffi-fixture-"$base".setup.log 2>&1 || {
    _fail "$base (setup.sh failed)"; return; }
  local crateDir="$HOME/.cache/sky/$base-crate"
  [ -d "$crateDir/.git" ] || { _fail "$base (expected staged crate at $crateDir)"; return; }
  local wd; wd="$(mktemp -d "${TMPDIR:-/tmp}/ffi-fixture-$base.XXXXXX")" || { _fail "$base (mktemp)"; return; }
  mkdir -p "$wd/src"; cp -r "$src/src/." "$wd/src/" 2>/dev/null || true
  cp "$src/sky.toml" "$wd/sky.toml" || { _fail "$base (cp sky.toml)"; rm -rf "$wd"; return; }
  local escC; escC="$(printf 'file://%s' "$crateDir" | sed -e 's/[\/&]/\\&/g')"
  sed -i -E "s|file://[^\"]*/$base-crate|$escC|g" "$wd/sky.toml" || { _fail "$base (sed)"; rm -rf "$wd"; return; }
  local bin; bin="$(SKY_DCE=0 build_fixture "$wd")" || { _fail "$base (build failed — numeric param coerce cargo-fail?)"; rm -rf "$wd"; return; }
  local skyi="$wd/.skycache/ffi/rust/numparam-crate.skyi"
  if ! rg -q 'widen_from_calc : Calc -> Int -> Int -> Float -> Result Error Int' "$skyi" 2>/dev/null; then
    _fail "$base: widen(usize,u32,f32) did NOT bind (#82 param coerce broken)"; rm -rf "$wd"; return
  fi
  local outp="/tmp/ffi-fixture-$base.out"
  exercise_cli "$bin" "$outp" "$RUN_TMO" || { _fail "$base (run panicked/hung)"; rm -rf "$wd"; return; }
  if rg -q '\[ALL OK\]' "$outp"; then
    _ok "$base  (usize/u32/f32 params SATURATING-coerce; echo_u32 5e9 clamps to u32::MAX not wrap · SKY_DCE=0 cargo-clean · [ALL OK])"
  else
    _fail "$base (no [ALL OK] — got: $(tr -d '\n' <"$outp"))"
  fi
  ( cd "$wd" && rm -rf sky-out/rust/target ) >/dev/null 2>&1
  rm -rf "$wd"
}


# ─────────────────────────────────────────────────────────────────────────────
# 104-ffi-owned-query-builder — WALL 6 (#68): the firestore OWNED query path.
# POSITIVE: the owned params-builder chain (QueryParams::new |> with_*) feeding an
#   #[async_trait] query method returning an OWNED Vec BINDS + runs ([ALL OK]).
# NEGATIVE: the borrowing fluent entry (Db::fluent -> QueryBuilder<'_>) DROPS
#   fail-closed (reason=lifetime) — ABSENT from the .skyi; crate still compiles.
# Locks the SOUND circumvention of the borrowed-builder limitation (guardian
# WALL-6 ruling 2026-06-27): bind the owned API the fluent layer is sugar over,
# NOT the borrow (whose foreign covariance is unverifiable at codegen).
# ─────────────────────────────────────────────────────────────────────────────
run_owned_query_builder() {
  local base=104-ffi-owned-query-builder
  local src="$FIXROOT/$base"
  [ -f "$src/src/Main.sky" ] || { _fail "$base (no such fixture)"; return; }

  local wd; wd="$(stage_workdir "$src")" || { _fail "$base (stage failed)"; return; }
  local bin; bin="$(build_fixture "$wd")" || { _fail "$base (build failed)"; rm -rf "$wd"; return; }
  local skyi="$wd/.skycache/ffi/rust/ownedquery104crate.skyi"

  # NEGATIVE (WALL 6): the borrowing fluent entry AND every QueryBuilder<'a> method
  # must be ABSENT (lifetime fail-closed drop). The inherent `Db::fluent` binds as
  # `fluent_from_db` under the `_from_<recv>` UFCS naming (NOT bare `fluent` — cf the
  # `with_limit_from_queryParams` positive below), and the builder methods as
  # `limit_from_queryBuilder`/`run_from_queryBuilder`; a leak also surfaces the type
  # `QueryBuilder` in a signature. So the net matches the crate-source identifiers
  # `fluent` / `QueryBuilder` (case-insensitive), which appear in ANY binding of the
  # borrowing path however it is named. The .skyi has no comments (just `module …`
  # + `name : sig` lines) and the owned positives (new_from_*/with_*_from_queryParams/
  # run_query + Db/Collection/QueryParams) contain neither substring, so this trips
  # only on a real leak. (A bare `^fluent ` would vacuously miss `fluent_from_db`.)
  if [ -f "$skyi" ] && rg -qi 'fluent|querybuilder' "$skyi"; then
    _fail "$base: borrowing fluent/QueryBuilder leaked into bindings (lifetime drop violated): $(rg -i 'fluent|querybuilder' "$skyi" | tr '\n' ';')"; rm -rf "$wd"; return
  fi
  # POSITIVE: the owned query path must BIND (async-trait method + owned builder).
  if ! rg -q 'run_query : Db -> QueryParams -> Task Error \(List String\)' "$skyi" 2>/dev/null; then
    _fail "$base: owned run_query did NOT bind (got: $(rg 'run_query' "$skyi" 2>/dev/null))"; rm -rf "$wd"; return
  fi
  if ! rg -q 'with_limit_from_queryParams : QueryParams -> Int -> Result Error QueryParams' "$skyi" 2>/dev/null; then
    _fail "$base: owned with_limit builder did NOT bind"; rm -rf "$wd"; return
  fi

  local outp="/tmp/ffi-fixture-$base.out"
  exercise_cli "$bin" "$outp" "$RUN_TMO" || { _fail "$base (run panicked/hung)"; rm -rf "$wd"; return; }
  if rg -q '\[ALL OK\]' "$outp"; then
    _ok "$base  (owned QueryParams builder chain + async-trait run_query bind+run · borrowing fluent dropped · [ALL OK])"
  else
    _fail "$base (no [ALL OK] — got: $(tr -d '\n' <"$outp"))"
  fi
  ( cd "$wd" && rm -rf sky-out/rust/target ) >/dev/null 2>&1
  rm -rf "$wd"
}


# ─────────────────────────────────────────────────────────────────────────────
# selfref-builder-proof — WALL 6 (#68): MIRI soundness proof of the self-referential
# borrowing-builder bundle mechanism (guardian-gated; NOT wired into codegen). Run
# ON DEMAND (`ffi-fixtures-test.sh selfref-builder-proof`); NOT in ALL_FIXTURES, so
# the default sweep is unaffected and machines without nightly+miri are unburdened.
# Guarded: skip-with-note if `cargo +nightly miri` is unavailable. Asserts the proof
# is UB-free under BOTH Stacked AND Tree Borrows (the documented soundness claim) —
# keeps the unsafe mechanism's invariants from rotting.
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# 105-ffi-generic-struct-accessor — #73 Part A (E0107). A field accessor for a
# GENERIC struct emits the bare struct name for its receiver (`Gen` not `Gen<T>`)
# → E0107 (firestore FirestoreWithMetadata<T>, SKY_DCE=0). The inspector now
# fail-closed DROPS field accessors for any struct with a type/const generic param.
# POSITIVE: non-generic Plain accessors + ctor bind, [ALL OK].
# NEGATIVE: generic Gen's field accessors (val_field/tag_field) ABSENT.
# ─────────────────────────────────────────────────────────────────────────────
run_generic_struct_accessor() {
  local base=105-ffi-generic-struct-accessor
  local src="$FIXROOT/$base"
  [ -f "$src/src/Main.sky" ] || { _fail "$base (no such fixture)"; return; }
  local wd; wd="$(stage_workdir "$src")" || { _fail "$base (stage failed)"; return; }
  local bin; bin="$(build_fixture "$wd")" || { _fail "$base (build failed)"; rm -rf "$wd"; return; }
  local skyi="$wd/.skycache/ffi/rust/genaccessor105crate.skyi"
  # NEGATIVE: generic struct field accessors must be ABSENT (E0107 drop).
  if [ -f "$skyi" ] && rg -q 'val_field_from_gen|tag_field_from_gen' "$skyi"; then
    _fail "$base: generic-struct field accessor leaked (E0107 gate): $(rg 'val_field_from_gen|tag_field_from_gen' "$skyi" | tr '\n' ';')"; rm -rf "$wd"; return
  fi
  # POSITIVE: non-generic struct accessor must BIND.
  if ! rg -q 'x_field_from_plain : Plain -> Int' "$skyi" 2>/dev/null; then
    _fail "$base: non-generic Plain accessor did NOT bind (over-drop)"; rm -rf "$wd"; return
  fi
  local outp="/tmp/ffi-fixture-$base.out"
  exercise_cli "$bin" "$outp" "$RUN_TMO" || { _fail "$base (run panicked/hung)"; rm -rf "$wd"; return; }
  if rg -q '\[ALL OK\]' "$outp"; then
    _ok "$base  (generic-struct field accessors dropped (E0107) · non-generic bind · [ALL OK])"
  else
    _fail "$base (no [ALL OK] — got: $(tr -d '\n' <"$outp"))"
  fi
  ( cd "$wd" && rm -rf sky-out/rust/target ) >/dev/null 2>&1
  rm -rf "$wd"
}


# 106-ffi-feature-propagation — #100 Part B. `featgate106crate` gates `extra_value`
# behind the `extra` Cargo feature. The inspector auto-discovers `extra` (#89: no
# `full` feature ⇒ enable all) + binds it; Part B then PROPAGATES `extra` into the
# generated project's `[dependencies]` line (a GIT dep — exercises the RustGitDep
# merge path) so the auto-bound wrapper actually compiles + runs.
# POSITIVE: generated Cargo.toml git dep carries `features = ["extra"]`; both
# base_value + extra_value bind; [ALL OK] (gated extra_value runs → 42).
# Without Part B the dep line stays bare → extra_value is E0425 cargo-fail.
# ─────────────────────────────────────────────────────────────────────────────
run_feature_propagation() {
  local base=106-ffi-feature-propagation
  local src="$FIXROOT/$base"
  [ -f "$src/src/Main.sky" ] || { _fail "$base (no such fixture)"; return; }
  local wd; wd="$(stage_workdir "$src")" || { _fail "$base (stage failed)"; return; }
  local bin; bin="$(build_fixture "$wd")" || { _fail "$base (build failed)"; rm -rf "$wd"; return; }
  local cargo="$wd/sky-out/rust/Cargo.toml"
  local skyi="$wd/.skycache/ffi/rust/featgate106crate.skyi"
  # POSITIVE: the inspector-discovered `extra` feature must be propagated onto the
  # git dep line (the heart of Part B). A bare line = the bug this fixture guards.
  if ! rg -q '^featgate106crate = .*features = \[.*"extra".*\]' "$cargo" 2>/dev/null; then
    _fail "$base: 'extra' feature NOT propagated to git dep line (got: $(rg '^featgate106crate' "$cargo" 2>/dev/null))"; rm -rf "$wd"; return
  fi
  # POSITIVE: the feature-gated binding must be present in the .skyi.
  if ! rg -q 'extra_value : Int -> Result Error Int' "$skyi" 2>/dev/null; then
    _fail "$base: feature-gated extra_value did NOT bind"; rm -rf "$wd"; return
  fi
  local outp="/tmp/ffi-fixture-$base.out"
  exercise_cli "$bin" "$outp" "$RUN_TMO" || { _fail "$base (run panicked/hung)"; rm -rf "$wd"; return; }
  if rg -q '\[ALL OK\]' "$outp"; then
    _ok "$base  (inspector feature 'extra' propagated to git dep · gated extra_value bind+run=42 · [ALL OK])"
  else
    _fail "$base (no [ALL OK] — got: $(tr -d '\n' <"$outp"))"
  fi
  ( cd "$wd" && rm -rf sky-out/rust/target ) >/dev/null 2>&1
  rm -rf "$wd"
}


run_selfref_miri_proof() {
  local base=selfref-builder-proof
  # Sibling of $FIXROOT (a standalone proof crate, not a sky fixture).
  local dir="$FIXROOT/../$base"
  [ -f "$dir/src/lib.rs" ] || { _fail "$base (no such proof crate at $dir)"; return; }
  if ! cargo +nightly miri --version >/dev/null 2>&1; then
    _ok "$base  (SKIPPED — nightly miri unavailable: rustup +nightly component add miri)"
    return
  fi
  local mt="${CARGO_TARGET_DIR:-$HOME/.cache/sky-rust-target}/miri-selfref"
  local sb=/tmp/ffi-$base-sb.log tb=/tmp/ffi-$base-tb.log
  ( cd "$dir" && env -u RUSTC_WRAPPER CARGO_TARGET_DIR="$mt" MIRIFLAGS="" \
      cargo +nightly miri test ) >"$sb" 2>&1
  local rc_sb=$?
  ( cd "$dir" && env -u RUSTC_WRAPPER CARGO_TARGET_DIR="$mt" MIRIFLAGS="-Zmiri-tree-borrows" \
      cargo +nightly miri test ) >"$tb" 2>&1
  local rc_tb=$?
  if [ $rc_sb -eq 0 ] && [ $rc_tb -eq 0 ]; then
    _ok "$base  (self-ref bundle UB-free under Stacked + Tree Borrows · 3/3 each)"
  else
    _fail "$base (MIRI UB — SB rc=$rc_sb TB rc=$rc_tb; see $sb / $tb)"
  fi
}


# ── Drive ────────────────────────────────────────────────────────────────────
FIXTURES=("$@"); [ ${#FIXTURES[@]} -gt 0 ] || FIXTURES=("${ALL_FIXTURES[@]}")

echo "── Sky→Rust auto-FFI fixture gate ──"
for n in "${FIXTURES[@]}"; do
  case "$n" in
    48-ffi-generics)          run_handstub ;;
    49-ffi-closures)          run_handstub_basic "$n" ;;
    50-ffi-iterators)         run_handstub_basic "$n" ;;
    51-ffi-trait-methods)     run_handstub_basic "$n" ;;
    52-ffi-dce-deadbinding)   run_deadbinding_dce ;;
    61-ffi-result-string-err) run_handstub_basic "$n" ;;
    73-ffi-serde)             run_serde ;;
    81-ffi-serde-ref)         run_serde_ref ;;
    83-ffi-mixed-generic-turbofish) run_mixed_turbofish ;;
    85-ffi-vec-struct-field)  run_vec_struct_field ;;
    86-ffi-transitive-dep-path) run_transitive_dep ;;
    89-ffi-static-str-into)   run_static_str_into ;;
    90-ffi-default-trait-method-mono) run_default_trait_mono ;;
    91-ffi-cross-crate-impl)  run_cross_crate_impl ;;
    92-ffi-generic-self-open-t) run_generic_self_open_t ;;
    93-ffi-customize-chain)   run_customize_chain ;;
    94-ffi-inherent-self-output) run_inherent_self_output ;;
    95-ffi-inherent-self-output-async) run_inherent_self_output_async ;;
    96-ffi-external-trait-xcrate) run_external_trait_xcrate ;;
    97-ffi-numeric-param-coerce) run_numeric_param_coerce ;;
    104-ffi-owned-query-builder) run_owned_query_builder ;;
    105-ffi-generic-struct-accessor) run_generic_struct_accessor ;;
    106-ffi-feature-propagation) run_feature_propagation ;;
    selfref-builder-proof)    run_selfref_miri_proof ;;
    *)                        run_basic "$n" ;;
  esac
done
# S4 DCE suite runs iff 43-ffi-dce is in the requested set.
for n in "${FIXTURES[@]}"; do
  if [ "$n" = "43-ffi-dce" ]; then run_s4_dce; break; fi
done

printf '%s\n' "${rows[@]}"
echo "── ${pass} ok · ${fail} fail ──"
[ "$fail" -eq 0 ]
