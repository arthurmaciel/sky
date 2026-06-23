#!/usr/bin/env bash
# #32 hand-stub setup (mirrors 49-ffi-closures). Two jobs, both BEFORE
# `sky build --backend rust`:
#   1. Stage the committed clo-crate/ as a git repo at the cache path the
#      sky.toml file:// dep points at (so Cargo can resolve + compile it).
#   2. Stage the CHECKED-IN closure kernel.json (which advertises mapEach as
#      `Result String (List b)` — the #32 case) + (empty) bindings into
#      .skycache/ffi/rust/ so the build reads them as-is and NO inspector runs.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

dest="$HOME/.cache/sky/61-ffi-result-string-err-crate"
rm -rf "$dest"
mkdir -p "$dest"
cp -r "$here/clo-crate/." "$dest/"
cd "$dest"
git init -q -b master
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "clo fixture crate"
echo "staged clo crate at $dest"

cd "$here"
mkdir -p .skycache/ffi/rust
cp "$here/ffi-stub/clo.kernel.json"   .skycache/ffi/rust/clo.kernel.json
cp "$here/ffi-stub/clo_bindings.rs"   .skycache/ffi/rust/clo_bindings.rs
echo "staged clo FFI stub into .skycache/ffi/rust/"
