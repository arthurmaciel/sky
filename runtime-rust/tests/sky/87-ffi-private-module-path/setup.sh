#!/usr/bin/env bash
# Stage the committed private-mod-crate/ source as a git repo at the cache path
# the sky.toml file:// dep points at. Run before `sky build --backend rust`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/87-ffi-private-module-path-crate"
rm -rf "$dest"
mkdir -p "$dest"
cp -r "$here/private-mod-crate/." "$dest/"
cd "$dest"
git init -q -b master
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "87-ffi-private-module-path fixture crate"
echo "staged privmodffi87 crate at $dest"
