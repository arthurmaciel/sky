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
ALL_FIXTURES=(40-field-getters 41-field-setters 42-enum-variants 43-ffi-dce 44-wide-int 45-async-ffi 46-enum-multifield 47-borrowed-returns 48-ffi-generics 49-ffi-closures 50-ffi-iterators 51-ffi-trait-methods 51b-ffi-trait-methods-realcrate 52-ffi-dce-deadbinding 61-ffi-result-string-err 72-ffi-async 73-ffi-serde 74-ffi-opaque-client 75-ffi-nested-glob-asref)

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
