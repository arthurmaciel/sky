#!/usr/bin/env bash
# Stage the committed async-opaque-ctor-crate/ source as a git repo at the cache
# path the sky.toml file:// dep points at. Run before `sky build --backend rust`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/78-ffi-async-opaque-ctor-crate"
rm -rf "$dest"
mkdir -p "$dest"
cp -r "$here/async-opaque-ctor-crate/." "$dest/"
cd "$dest"
git init -q -b master
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "78-ffi-async-opaque-ctor fixture crate"
echo "staged asyncopaquector78 crate at $dest"
