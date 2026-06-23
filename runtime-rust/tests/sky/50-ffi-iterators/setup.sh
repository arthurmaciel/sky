#!/usr/bin/env bash
# Iterators-FFI hand-stub setup (epic #30). Two jobs, both BEFORE
# `sky build --backend rust`:
#   1. Stage the committed iter-crate/ as a git repo at the cache path the
#      sky.toml file:// dep points at (so Cargo can resolve + compile it).
#   2. Stage the CHECKED-IN iterator kernel.json + (empty) bindings into
#      .skycache/ffi/rust/ so the build reads them as-is and NO inspector runs
#      (the inspector's emission of this exact shape is proven by the Rust unit
#      tests; this fixture proves the end-to-end build+run).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

# 1. local crate → git repo at the file:// dep path
dest="$HOME/.cache/sky/50-ffi-iterators-crate"
rm -rf "$dest"
mkdir -p "$dest"
cp -r "$here/iter-crate/." "$dest/"
cd "$dest"
git init -q -b master
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "iter fixture crate"
echo "staged iter crate at $dest"

# 2. checked-in FFI stub → cache (no inspector)
cd "$here"
mkdir -p .skycache/ffi/rust
cp "$here/ffi-stub/iter.kernel.json"  .skycache/ffi/rust/iter.kernel.json
cp "$here/ffi-stub/iter_bindings.rs"  .skycache/ffi/rust/iter_bindings.rs
echo "staged iter FFI stub into .skycache/ffi/rust/"
