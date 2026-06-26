#!/usr/bin/env bash
# Stage the committed serde-ref-crate/ source as a git repo at the cache path
# the sky.toml file:// dep points at. Run before `sky build --backend rust`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/81-ffi-serde-ref-crate"
rm -rf "$dest"
mkdir -p "$dest"
cp -r "$here/serde-ref-crate/." "$dest/"
cd "$dest"
git init -q -b master
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "81-ffi-serde-ref fixture crate"
echo "staged serderefcrate81 crate at $dest"
