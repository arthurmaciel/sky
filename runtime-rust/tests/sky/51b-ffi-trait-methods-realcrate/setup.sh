#!/usr/bin/env bash
# #31 / C-4 REAL-INSPECTOR setup. ONE job, BEFORE `sky build --backend rust`:
# stage the committed tm-crate/ as a git repo at the cache path the sky.toml
# file:// dep points at (so Cargo can resolve + compile it). Deliberately stages
# NO kernel.json/bindings — the REAL inspector (`cargo +nightly rustdoc`) runs at
# build time and emits the trait-method bindings. This is the end-to-end proof
# the #21/#31 inspector binding (and the C-1 pub(crate)-trait drop) actually
# works on a real crate, which the hand stub (51-ffi-trait-methods) cannot give.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

dest="$HOME/.cache/sky/51b-ffi-trait-methods-realcrate-crate"
rm -rf "$dest"
mkdir -p "$dest"
cp -r "$here/tm-crate/." "$dest/"
cd "$dest"
git init -q -b master
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "tm real-inspector fixture crate"
echo "staged tm crate at $dest"
