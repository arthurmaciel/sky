#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.cache/sky/95-ffi-inherent-self-output-async-crate"
rm -rf "$dest"; mkdir -p "$dest"; cp -r "$here/sendreq-crate/." "$dest/"
cd "$dest"; git init -q -b master; git add -A
git -c user.email=t@t -c user.name=t commit -q -m "95-ffi-inherent-self-output-async fixture: sendreq-crate"
echo "staged sendreq-crate at $dest"
