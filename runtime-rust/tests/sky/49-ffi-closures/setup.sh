#!/usr/bin/env bash
# Wall #2 hand-stub setup. Two jobs, both BEFORE `sky build --backend rust`:
#   1. Stage the committed clo-crate/ as a git repo at the cache path the
#      sky.toml file:// dep points at (so Cargo can resolve + compile it).
#   2. Stage the CHECKED-IN closure kernel.json + (empty) bindings into
#      .skycache/ffi/rust/ so the build reads them as-is and NO inspector runs
#      (the inspector is Wall #3; Wall #2 is provable with a hand stub).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

# 1. local crate → git repo at the file:// dep path
dest="$HOME/.cache/sky/49-ffi-closures-crate"
rm -rf "$dest"
mkdir -p "$dest"
cp -r "$here/clo-crate/." "$dest/"
cd "$dest"
git init -q -b master
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "clo fixture crate"
echo "staged clo crate at $dest"

# 2. checked-in FFI stub → cache (no inspector)
cd "$here"
mkdir -p .skycache/ffi/rust
cp "$here/ffi-stub/clo.kernel.json"   .skycache/ffi/rust/clo.kernel.json
cp "$here/ffi-stub/clo_bindings.rs"   .skycache/ffi/rust/clo_bindings.rs
echo "staged clo FFI stub into .skycache/ffi/rust/"
