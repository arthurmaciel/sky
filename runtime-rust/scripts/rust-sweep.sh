#!/usr/bin/env bash
# All-example --target rust BUILD sweep. Bins every in-scope example (build_set
# from lib/examples.sh — every candidate dir minus Go-FFI) by how far the Rust
# backend gets. Build-level only; run-level equivalence lives in equiv-sweep.sh.
#
# DERIVED set: a Go-FFI example is simply ABSENT (no "out-of-scope" tag). Every
# example present here is in scope, so any non-`builds` result is a REAL failure
# (greenfield gaps surface as failures — user decision).
#
# Env + example manifest are the shared SINGLE SOURCE OF TRUTH under lib/.
set -uo pipefail
source "$(dirname "$0")/lib/env.sh"
source "$(dirname "$0")/lib/examples.sh"
cd "$REPO"
SKY="$SKY_BIN"
[ -x "$SKY" ] || { echo "ERROR: sky binary not at $SKY (build: cabal build exe:sky)"; exit 1; }

printf "%-30s %s\n" "EXAMPLE" "RESULT"
printf "%-30s %s\n" "-------" "------"
while IFS= read -r d; do
  n=$(basename "$d")
  [ -f "${d}/src/Main.sky" ] || continue
  ( cd "$d" && rm -rf sky-out .skycache .skydeps )
  if ! ( cd "$d" && timeout 180 "$SKY" build src/Main.sky --target rust >/tmp/sweep-$n.sky.log 2>&1 ); then
    if rg -qE "Non-exhaustive|CallStack \(from HasCallStack\)|Prelude\.[a-z]+: |internal error" /tmp/sweep-$n.sky.log 2>/dev/null; then
      r="sky-CRASH"
    else
      r="sky-build-fails"
    fi
  elif ( cd "$d" && timeout 600 cargo build --manifest-path sky-out/Rust/Cargo.toml -q >/tmp/sweep-$n.cargo.log 2>&1 ); then
    r="builds"
  else
    r="cargo-fails"
  fi
  printf "%-30s %s\n" "$n" "$r"
  # Reclaim disk immediately — 40+ cargo target/ dirs (~1.5 GB each) otherwise
  # fill the filesystem mid-sweep (the result is already recorded above).
  ( cd "$d" && rm -rf sky-out .skycache .skydeps )
done < <(build_set)
