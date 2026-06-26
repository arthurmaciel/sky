#!/usr/bin/env bash
# Stage nested-glob-crate/ as a git repo at the cache path sky.toml points at.
# Run before `sky build --backend rust`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/75-ffi-nested-glob-asref-crate"
rm -rf "$dest"
mkdir -p "$dest"
cp -r "$here/nested-glob-crate/." "$dest/"
cd "$dest"
git init -q -b master
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "75-ffi-nested-glob-asref fixture crate"
echo "staged nested-glob-crate at $dest"
