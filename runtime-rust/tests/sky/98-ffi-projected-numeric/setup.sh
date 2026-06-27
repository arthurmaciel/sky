#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/98-ffi-projected-numeric-crate"
rm -rf "$dest"; mkdir -p "$dest"; cp -r "$here/widenproj-crate/." "$dest/"
cd "$dest"; git init -q -b master; git add -A
git -c user.email=t@t -c user.name=t commit -q -m "98-ffi-projected-numeric fixture: widenproj-crate"
echo "staged widenproj-crate at $dest"
