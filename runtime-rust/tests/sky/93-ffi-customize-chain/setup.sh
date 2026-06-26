#!/usr/bin/env bash
# Stage thing-crate as a git repo at the cache path sky.toml points at.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/93-ffi-customize-chain-thing"
rm -rf "$dest"; mkdir -p "$dest"; cp -r "$here/thing-crate/." "$dest/"
cd "$dest"; git init -q -b master; git add -A
git -c user.email=t@t -c user.name=t commit -q -m "93-ffi-customize-chain fixture: thing-crate"
echo "staged thing-crate at $dest"
