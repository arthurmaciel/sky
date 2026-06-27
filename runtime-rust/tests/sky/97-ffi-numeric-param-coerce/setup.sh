#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/97-ffi-numeric-param-coerce-crate"
rm -rf "$dest"; mkdir -p "$dest"; cp -r "$here/numparam-crate/." "$dest/"
cd "$dest"; git init -q -b master; git add -A
git -c user.email=t@t -c user.name=t commit -q -m "97-ffi-numeric-param-coerce fixture: numparam-crate"
echo "staged numparam-crate at $dest"
