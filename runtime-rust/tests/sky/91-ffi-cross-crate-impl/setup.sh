#!/usr/bin/env bash
# Stage the two sibling crates as git repos at the cache paths sky.toml points at.
# wire-crate (defines `Wire` + `Req::op<C: Wire>`, no impl) and client-crate (the
# unique cross-crate `impl Wire for RealClient`). client-crate depends on wire-crate,
# so wire-crate must be staged FIRST (client-crate's Cargo.toml git-deps on it).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

stage() { # <src-subdir> <dest-cache-dir>
    local src="$here/$1" dest="$2"
    rm -rf "$dest"; mkdir -p "$dest"
    cp -r "$src/." "$dest/"
    cd "$dest"
    git init -q -b master
    git add -A
    git -c user.email=t@t -c user.name=t commit -q -m "91-ffi-cross-crate-impl fixture: $1"
    echo "staged $1 at $dest"
}

stage wire-crate   "$HOME/.cache/sky/91-ffi-cross-crate-impl-wire"
stage client-crate "$HOME/.cache/sky/91-ffi-cross-crate-impl-client"
