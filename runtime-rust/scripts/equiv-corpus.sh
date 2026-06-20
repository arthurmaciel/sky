#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Go≡Rust EQUIVALENCE CORPUS — deterministic-stdout regression fixtures.
#
# The examples-sweep proves Go≡Rust on the author's `examples/`; this runner is
# its focused complement: a CURATED set of small, PURE-STDLIB, deterministic-
# stdout fixtures under `runtime-rust/tests/sky/` that pin SPECIFIC kernel /
# codegen behaviours the example set doesn't exercise (the "green build ≠ correct"
# gap — e.g. i64 overflow wrap, Log.*With attr flattening, crypto encoding,
# cons-pattern tuples). Each fixture is built on BOTH backends, run, and its
# stdout compared byte-for-byte after a light normalisation (blank lines + the
# RFC3339 log timestamp, the only legitimately non-deterministic token).
#
# A fixture that does NOT build on one backend (e.g. it needs a Rust-only FFI
# crate) is SKIPPED, not failed — the corpus is deliberately pure-stdlib, so a
# build skip means "not a corpus member", never a regression. The gate is: every
# fixture that builds on BOTH backends must produce identical normalised stdout.
#
# Usage:  equiv-corpus.sh                 # run the whole curated corpus
#         equiv-corpus.sh 63-int-overflow-wrap 65-crypto-random-encoding   # a subset
# Exit:   0 = every both-built fixture matched · 1 = a DIFFER · 2 = setup error.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=lib/env.sh
source "$_dir/lib/env.sh"
# shellcheck source=lib/checks.sh
source "$_dir/lib/checks.sh"   # exercise_cli (isolated cwd) + PANIC_RE
[ -n "${REPO:-}" ] && cd "$REPO" || { echo "ERROR: run from the Sky repo (set SKY_REPO)." >&2; exit 2; }
SKY="${SKY_BIN:-$REPO/sky-out/sky}"
[ -x "$SKY" ] || { echo "ERROR: sky binary not found at $SKY (build it + symlink)." >&2; exit 2; }

FIXROOT="runtime-rust/tests/sky"

# ── The curated corpus — pure-stdlib, deterministic-after-normalisation, cli ──
# Add a fixture here ONLY when its stdout is identical on both backends modulo the
# normalised tokens below. A Rust-codegen-regression fixture qualifies iff it is
# also valid Go (most are — the codegen difference is internal, the output isn't).
CORPUS_DEFAULT=(
  23-char                       # Sky.Core.Char kernel surface
  53-cons-pattern-tuple         # cons-pattern destructuring of tuple elements
  60-errortostring-string       # Basics.errorToString on a String (SkyStringify)
  63-int-overflow-wrap          # i64 Go-parity wraparound (overflow-checks=false)
  64-log-with-attrs             # Std.Log.*With attr flattening (SkyStringify bound)
  65-crypto-random-encoding     # randomBytes hex / randomToken base64url lengths
)
# Known-excluded (surfaced BY this corpus — the runner skips/fails them, so they
# are held out of the green baseline until fixed; pass them as args to re-probe):
#   49-bytes-core   — Rust E0282: `bytes_from_hex`/`bytes_from_base64` return
#                     `SkyResult<E,T>` and `E` is unconstrained at the `match`
#                     call site (the Err arm doesn't pin it). In-boundary Rust
#                     codegen gap (an E-pinning wrapper, like log_*_with, would
#                     fix it). Pre-existing; tracked for a follow-up.
#   56-list-sort    — Go build fails: `List.sortWith`/`sortBy` has no `List_sortWith`
#                     kernel in the GO backend (`kernelToGo` default). Out of the
#                     Rust boundary (shared stdlib / Go codegen); cannot be a
#                     Go≡Rust corpus member until Go gains the kernel.

# Normalise stdout for the diff: drop blank lines + replace the RFC3339(Nano) UTC
# log timestamp with a fixed placeholder (the ONLY non-deterministic token a
# deterministic corpus fixture may legitimately print, via Log.*). Anything else
# differing is a real divergence.
norm() {
  sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z/<TS>/g' "$1" \
    | grep -v '^[[:space:]]*$'
}

# Build one backend for a fixture; echo the resulting binary path, or "" on fail.
# $1=fixture-dir $2=go|rust
build_one() {
  local d="$1" t="$2" logp="/tmp/equiv-corpus-$(basename "$d")-$2.build.log"
  ( cd "$d" && rm -rf sky-out .skycache .skydeps ) >/dev/null 2>&1
  if [ "$t" = go ]; then
    # Force --backend go: the corpus fixtures pin `backend = "rust"` in sky.toml
    # (they're Rust-backend regression fixtures), so a bare `sky build` would
    # produce the RUST binary and the "go" reference would actually be Rust.
    ( cd "$d" && timeout 300 "$SKY" build --backend go src/Main.sky ) >"$logp" 2>&1 || return 1
    [ -x "$d/sky-out/app" ] || return 1
    # Copy the Go binary OUT before the rust build's `rm -rf sky-out` wipes it
    # (both backends share $d/sky-out). Stable per-fixture path under TMPDIR.
    local dst="${TMPDIR:-/tmp}/equiv-corpus-$(basename "$d").gobin"
    cp -f "$d/sky-out/app" "$dst" || return 1
    printf '%s\n' "$dst"
  else
    ( cd "$d" && timeout 600 "$SKY" build --backend rust src/Main.sky ) >"$logp" 2>&1 || return 1
    local b; b="$(resolve_bin "$d")" || return 1
    printf '%s\n' "$b"
  fi
}

# ── Drive the corpus ─────────────────────────────────────────────────────────
FIXTURES=("$@"); [ ${#FIXTURES[@]} -gt 0 ] || FIXTURES=("${CORPUS_DEFAULT[@]}")
pass=0; fail=0; skip=0; rows=()
for n in "${FIXTURES[@]}"; do
  d="$FIXROOT/$n"
  if [ ! -f "$d/src/Main.sky" ]; then rows+=("SKIP  $n  (no such fixture)"); skip=$((skip+1)); continue; fi

  gobin="$(build_one "$d" go)"   || { rows+=("SKIP  $n  (go build failed — not a pure-stdlib corpus member)"); skip=$((skip+1)); continue; }
  rustbin="$(build_one "$d" rust)" || { rows+=("FAIL  $n  (rust build failed)"); fail=$((fail+1)); continue; }

  gol="/tmp/equiv-corpus-$n.go.out"; rsl="/tmp/equiv-corpus-$n.rust.out"
  exercise_cli "$gobin"   "$gol" 25 || { rows+=("FAIL  $n  (go run panicked/hung)"); fail=$((fail+1)); continue; }
  exercise_cli "$rustbin" "$rsl" 25 || { rows+=("FAIL  $n  (rust run panicked/hung)"); fail=$((fail+1)); continue; }

  if diff <(norm "$gol") <(norm "$rsl") >"/tmp/equiv-corpus-$n.diff" 2>&1; then
    rows+=("ok    $n"); pass=$((pass+1))
  else
    rows+=("FAIL  $n  (stdout DIFFER — /tmp/equiv-corpus-$n.diff)"); fail=$((fail+1))
  fi
  ( cd "$d" && rm -rf sky-out/rust/target ) >/dev/null 2>&1   # disk hygiene
done

echo "── Go≡Rust equivalence corpus ──"
printf '%s\n' "${rows[@]}"
echo "── ${pass} ok · ${fail} fail · ${skip} skip ──"
[ "$fail" -eq 0 ]
