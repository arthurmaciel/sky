#!/usr/bin/env bash
# Stage the committed opaque-crate/ source as a git repo at the cache path the
# sky.toml file:// dep points at. Run before `sky build --backend rust`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/74-ffi-opaque-client-crate"
rm -rf "$dest"
mkdir -p "$dest"
cp -r "$here/opaque-crate/." "$dest/"
cd "$dest"
git init -q -b master
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "74-ffi-opaque-client fixture crate"
echo "staged opaqueffi74 crate at $dest"
