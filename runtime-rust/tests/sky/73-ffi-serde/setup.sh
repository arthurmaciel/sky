#!/usr/bin/env bash
# Stage the committed serde-fixture/ source as a git repo at the cache path the
# sky.toml file:// dep points at. Run before `sky build --backend rust`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/73-ffi-serde-crate"
rm -rf "$dest"
mkdir -p "$dest"
cp -r "$here/serde-fixture/." "$dest/"
cd "$dest"
git init -q -b master
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "73-ffi-serde fixture crate"
echo "staged serde-fixture crate at $dest"
