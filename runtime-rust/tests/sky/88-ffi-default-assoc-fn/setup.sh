#!/usr/bin/env bash
# Stage default-crate/ as a git repo at the cache path sky.toml points at.
# Run before `sky build --backend rust`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/88-ffi-default-assoc-fn-crate"
rm -rf "$dest"
mkdir -p "$dest"
cp -r "$here/default-crate/." "$dest/"
cd "$dest"
git init -q -b master
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "88-ffi-default-assoc-fn fixture crate"
echo "staged default-crate at $dest"
