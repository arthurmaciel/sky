#!/usr/bin/env bash
# Stage borrowed-ref-crate/ as a git repo at the cache path sky.toml points at.
# Run before `sky build --backend rust`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/76-ffi-borrowed-ref-crate"
rm -rf "$dest"
mkdir -p "$dest"
cp -r "$here/borrowed-ref-crate/." "$dest/"
cd "$dest"
git init -q -b master
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "76-ffi-borrowed-ref fixture crate"
echo "staged borrowed-ref-crate at $dest"
