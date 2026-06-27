#!/usr/bin/env bash
# Stage selfout-crate as a git repo at the cache path sky.toml points at.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/94-ffi-inherent-self-output-crate"
rm -rf "$dest"; mkdir -p "$dest"; cp -r "$here/selfout-crate/." "$dest/"
cd "$dest"; git init -q -b master; git add -A
git -c user.email=t@t -c user.name=t commit -q -m "94-ffi-inherent-self-output fixture: selfout-crate"
echo "staged selfout-crate at $dest"
