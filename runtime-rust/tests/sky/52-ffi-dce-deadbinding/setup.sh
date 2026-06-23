#!/usr/bin/env bash
# Stage the committed dcetest-crate/ source as a git repo at the cache path
# the sky.toml file:// dep points at. Run before `sky build --backend rust`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/52-ffi-dce-deadbinding-crate"
rm -rf "$dest"
mkdir -p "$dest"
cp -r "$here/dcetest-crate/." "$dest/"
cd "$dest"
git init -q -b master
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "dcetest fixture crate (52 dead-binding)"
echo "staged dcetest crate at $dest"
