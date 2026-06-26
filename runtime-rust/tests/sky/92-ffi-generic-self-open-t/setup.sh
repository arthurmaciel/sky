#!/usr/bin/env bash
# Stage req-crate + client-crate as sibling git repos (req first — client git-deps on it).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
stage() {
    local src="$here/$1" dest="$2"
    rm -rf "$dest"; mkdir -p "$dest"; cp -r "$src/." "$dest/"
    cd "$dest"; git init -q -b master; git add -A
    git -c user.email=t@t -c user.name=t commit -q -m "92-ffi-generic-self-open-t fixture: $1"
    echo "staged $1 at $dest"
}
stage req-crate    "$HOME/.cache/sky/92-ffi-generic-self-open-t-req"
stage client-crate "$HOME/.cache/sky/92-ffi-generic-self-open-t-client"
