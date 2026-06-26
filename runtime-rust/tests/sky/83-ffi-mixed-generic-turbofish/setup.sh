#!/usr/bin/env bash
# Stage the committed mixed-generic-crate/ source as a git repo at the cache path
# the sky.toml file:// dep points at. Run before `sky build --backend rust`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/83-ffi-mixed-generic-turbofish-crate"
rm -rf "$dest"
mkdir -p "$dest"
cp -r "$here/mixed-generic-crate/." "$dest/"
cd "$dest"
git init -q -b master
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "83-ffi-mixed-generic-turbofish fixture crate"
echo "staged mixedgenericcrate83 crate at $dest"
