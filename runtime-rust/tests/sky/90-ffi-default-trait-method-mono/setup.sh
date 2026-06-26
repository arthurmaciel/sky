#!/usr/bin/env bash
# Stage default-trait-crate/ as a git repo at the cache path sky.toml points at.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/90-ffi-default-trait-method-mono-crate"
rm -rf "$dest"; mkdir -p "$dest"
cp -r "$here/default-trait-crate/." "$dest/"
cd "$dest"
git init -q -b master
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "90-ffi-default-trait-method-mono fixture crate"
echo "staged default-trait-crate at $dest"
