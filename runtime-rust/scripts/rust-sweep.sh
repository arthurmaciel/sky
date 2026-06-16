#!/usr/bin/env bash
# All-example --target rust sweep. Bins every examples/[0-9]* (+ simple,
# test_pkg) by how far the Rust backend gets. Build-level only; run-level
# equivalence lives in runtime-rust/scripts/rust-equiv.sh.
#
# Env + example manifest are the shared SINGLE SOURCE OF TRUTH under lib/.
set -uo pipefail
source "$(dirname "$0")/lib/env.sh"
source "$(dirname "$0")/lib/examples.sh"
cd "$REPO"
SKY="$SKY_BIN"
[ -x "$SKY" ] || { echo "ERROR: sky binary not at $SKY (build: cabal install … exe:sky)"; exit 1; }

printf "%-26s %s\n" "EXAMPLE" "RESULT"
printf "%-26s %s\n" "-------" "------"
for d in $(ls -d "${BUILD_GLOB[@]}" 2>/dev/null); do
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
