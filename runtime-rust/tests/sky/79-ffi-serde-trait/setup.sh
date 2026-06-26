#!/usr/bin/env bash
# Stage the committed serde-trait-crate/ source as a git repo at the cache path
# the sky.toml file:// dep points at. Run before `sky build --backend rust`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/79-ffi-serde-trait-crate"
rm -rf "$dest"
mkdir -p "$dest"
cp -r "$here/serde-trait-crate/." "$dest/"
cd "$dest"
git init -q -b master
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "79-ffi-serde-trait fixture crate"
echo "staged serdetraitcrate79 crate at $dest"
