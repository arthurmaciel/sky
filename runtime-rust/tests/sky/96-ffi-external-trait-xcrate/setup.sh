#!/usr/bin/env bash
# Stage all three crates (trait/impl/method) as git repos at the cache paths sky.toml + the
# per-crate Cargo.toml git deps point at.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
stage() {
  local sub="$1" dest="$HOME/.cache/sky/96-ffi-external-trait-xcrate-$2"
  rm -rf "$dest"; mkdir -p "$dest"; cp -r "$here/$sub/." "$dest/"
  cd "$dest"; git init -q -b master; git add -A
  git -c user.email=t@t -c user.name=t commit -q -m "96-ffi-external-trait-xcrate fixture: $sub"
}
stage walk-trait trait
stage walk-impl impl
stage walk-method method
echo "staged walk-trait/impl/method"
