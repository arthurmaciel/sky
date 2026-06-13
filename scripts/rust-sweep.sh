#!/usr/bin/env bash
# All-example --target rust sweep. Bins every examples/[0-9]* (+ simple,
# test_pkg) by how far the Rust backend gets. Build-level only; run-level
# equivalence lives in scripts/rust-equiv.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
SKY="${SKY_BIN:-$PWD/sky-out/sky}"
[ -x "$SKY" ] || { echo "ERROR: sky binary not at $SKY (build: cabal install … exe:sky)"; exit 1; }

# Shared cargo target dir + sccache (mandatory, per user 2026-06-10): every
# example is cargo package "sky-app", so a shared CARGO_TARGET_DIR *outside*
# each sky-out/ lets the heavy deps (axum/tokio/serde/…) compile ONCE and
# persist across the per-example `rm -rf sky-out`. sccache (RUSTC_WRAPPER)
# additionally caches each rustc invocation by content hash, so even sky-app
# recompiles hit cache. The sweep is sequential, so no target-dir lock
# contention. Override CARGO_TARGET_DIR to relocate the cache.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/sky-rust-target}"
command -v sccache >/dev/null 2>&1 && export RUSTC_WRAPPER="${RUSTC_WRAPPER:-sccache}"
mkdir -p "$CARGO_TARGET_DIR"

# Out-of-scope on the Rust backend, recorded but not a build target:
#  - no Rust monolith reference: 02 06 11 19 25 26 27 29 31 34 36 37 38
#  - Go-package→Rust-native FFI examples (per user 2026-06-10, NOT a goal —
#    they import Go packages like gorilla/mux, stripe-go, google/uuid,
#    godotenv): 03 05 08 13
# 19-skyforum + 26-ui-showcase now build on Rust (Std.Ui parity work) — in scope.
# 24-tui-kitchen-sink (multibackend Live+Tui main) builds via the #24 entry-model
# refactor — in scope. 21/22/23 (pure-Tui) un-gated by the same refactor (their
# `Tui.app |> Task.run` main now block_on's) — in scope.
OUT_OF_SCOPE=" 02 03 05 06 08 11 13 25 27 29 31 34 36 37 38 "

printf "%-26s %s\n" "EXAMPLE" "RESULT"
printf "%-26s %s\n" "-------" "------"
for d in $(ls -d examples/[0-9]*/ examples/simple/ examples/test_pkg/ 2>/dev/null); do
  n=$(basename "$d")
  [ -f "${d}src/Main.sky" ] || continue
  num=$(echo "$n" | grep -oE '^[0-9]+' || true)
  ( cd "$d" && rm -rf sky-out .skycache .skydeps )
  if ! ( cd "$d" && timeout 180 "$SKY" build src/Main.sky --target rust >/tmp/sweep-$n.sky.log 2>&1 ); then
    if grep -qE "Non-exhaustive|CallStack \(from HasCallStack\)|Prelude\.[a-z]+: |internal error" /tmp/sweep-$n.sky.log; then
      r="sky-CRASH"
    else
      r="sky-build-fails"
    fi
  elif ( cd "$d" && timeout 600 cargo build --manifest-path sky-out/Rust/Cargo.toml -q >/tmp/sweep-$n.cargo.log 2>&1 ); then
    r="builds"
  else
    r="cargo-fails"
  fi
  case "$OUT_OF_SCOPE" in *" $num "*) r="$r (out-of-scope)";; esac
  printf "%-26s %s\n" "$n" "$r"
  # Reclaim disk immediately — 41× cargo target/ dirs (~1.5 GB each) otherwise
  # fill the filesystem mid-sweep (the result is already recorded above).
  ( cd "$d" && rm -rf sky-out .skycache .skydeps )
done
