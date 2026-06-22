#!/usr/bin/env bash
# Stage the committed wideint-crate/ source as a git repo at the cache path the
# sky.toml file:// dep points at. Run before `sky build --backend rust`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/44-wide-int-crate"
rm -rf "$dest"
mkdir -p "$dest"
cp -r "$here/wideint-crate/." "$dest/"
cd "$dest"
git init -q -b master
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "wideint fixture crate"
echo "staged wideint crate at $dest"
