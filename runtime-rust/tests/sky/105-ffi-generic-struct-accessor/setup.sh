#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/105-ffi-generic-struct-accessor-crate"
rm -rf "$dest"; mkdir -p "$dest"
cp -r "$here/genaccessor105crate/." "$dest/"
cd "$dest"; git init -q -b master; git add -A
git -c user.email=t@t -c user.name=t commit -q -m "105 fixture crate"
echo "staged genaccessor105crate at $dest"
