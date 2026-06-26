#!/usr/bin/env bash
# Stage the committed transdep-crate/ as a git repo at the cache path the sky.toml
# file:// dep points at. `transdep86` is the sky-added dep; `equivalent` (no-
# separator) and `is-even` (HYPHEN package / `is_even` lib ident) are its real
# crates.io trait deps, reached only TRANSITIVELY — the WALL-B (#75) path.
# Run before `sky build --backend rust`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/86-ffi-transitive-dep-path-crate"
rm -rf "$dest"
mkdir -p "$dest"
cp -r "$here/transdep-crate/." "$dest/"
cd "$dest"
git init -q -b master
git add -A
git -c user.email=t@t -c user.name=t commit -q -m "86-ffi-transitive-dep-path fixture crate"
echo "staged transdep86 (transitive: equivalent, is-even) crate at $dest"
