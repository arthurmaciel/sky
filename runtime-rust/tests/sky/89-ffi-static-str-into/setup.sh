#!/usr/bin/env bash
# Stage static-str-crate/ as a git repo at the cache path sky.toml points at.
# Run before `sky build --backend rust`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/89-ffi-static-str-into-crate"
rm -rf "$dest"
mkdir -p "$dest"
cp -r "$here/static-str-crate/." "$dest/"
cd "$dest"
git init -q -b master
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "89-ffi-static-str-into fixture crate"
echo "staged static-str-crate at $dest"
