#!/usr/bin/env bash
# Stage owned-string-crate/ as a git repo at the cache path sky.toml points at.
# Run before `sky build --backend rust`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/84-ffi-owned-string-ctor-crate"
rm -rf "$dest"
mkdir -p "$dest"
cp -r "$here/owned-string-crate/." "$dest/"
cd "$dest"
git init -q -b master
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "84-ffi-owned-string-ctor fixture crate"
echo "staged owned-string-ctor-crate at $dest"
