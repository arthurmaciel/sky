#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/106-ffi-feature-propagation-crate"
rm -rf "$dest"; mkdir -p "$dest"
cp -r "$here/featgate106crate/." "$dest/"
cd "$dest"; git init -q -b master; git add -A
git -c user.email=t@t -c user.name=t commit -q -m "106 fixture crate"
echo "staged featgate106crate at $dest"
