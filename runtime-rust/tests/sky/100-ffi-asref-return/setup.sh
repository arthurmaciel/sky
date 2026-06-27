#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/100-ffi-asref-return-crate"
rm -rf "$dest"; mkdir -p "$dest"; cp -r "$here/asrefret-crate/." "$dest/"
cd "$dest"; git init -q -b master; git add -A
git -c user.email=t@t -c user.name=t commit -q -m "100 fixture"
echo "staged at $dest"
