#!/usr/bin/env bash
# Wall #2 hand-stub setup (#21 trait methods). Two jobs, both BEFORE
# `sky build --backend rust`:
#   1. Stage the committed tm-crate/ as a git repo at the cache path the
#      sky.toml file:// dep points at (so Cargo can resolve + compile it).
#   2. Stage the CHECKED-IN trait-method kernel.json + bindings into
#      .skycache/ffi/rust/ so the build reads them as-is and NO inspector runs
#      (the inspector binding is proven by the sky-ffi-inspect-rs unit tests;
#      Wall #2 is the codegen+runtime proof).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

# 1. local crate → git repo at the file:// dep path
dest="$HOME/.cache/sky/51-ffi-trait-methods-crate"
rm -rf "$dest"
mkdir -p "$dest"
cp -r "$here/tm-crate/." "$dest/"
cd "$dest"
git init -q -b master
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "tm fixture crate"
echo "staged tm crate at $dest"

# 2. checked-in FFI stub → cache (no inspector)
cd "$here"
mkdir -p .skycache/ffi/rust
cp "$here/ffi-stub/tm.kernel.json"   .skycache/ffi/rust/tm.kernel.json
cp "$here/ffi-stub/tm_bindings.rs"   .skycache/ffi/rust/tm_bindings.rs
echo "staged tm FFI stub into .skycache/ffi/rust/"
