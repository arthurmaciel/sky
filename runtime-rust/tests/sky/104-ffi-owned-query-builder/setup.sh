#!/usr/bin/env bash
# Stage the committed ownedquery104crate/ source as a git repo at the cache path
# the sky.toml file:// dep points at. Run before `sky build --backend rust`.
# Fresh crate name (ownedquery104crate) per the stale-git-dep-cache lesson.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/104-ffi-owned-query-builder-crate"
rm -rf "$dest"
mkdir -p "$dest"
cp -r "$here/ownedquery104crate/." "$dest/"
cd "$dest"
git init -q -b master
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "104-ffi-owned-query-builder fixture crate"
echo "staged ownedquery104crate at $dest"
