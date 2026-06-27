#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/99-ffi-nested-numeric-drop-crate"
rm -rf "$dest"; mkdir -p "$dest"; cp -r "$here/nestednum-crate/." "$dest/"
cd "$dest"; git init -q -b master; git add -A
git -c user.email=t@t -c user.name=t commit -q -m "99 fixture: nestednum-crate"
echo "staged nestednum-crate at $dest"
