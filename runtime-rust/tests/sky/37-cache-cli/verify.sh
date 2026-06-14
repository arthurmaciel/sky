#!/usr/bin/env bash
# S8 acceptance — Std.Cache on the Rust backend. Builds the CLI and checks its
# output (new / put / get / size / stats over a Cache String String). Byte-
# equivalent to the Go backend.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${CARGO_TARGET_DIR:-}" ] && [ -x "$CARGO_TARGET_DIR/debug/sky-app" ]; then
    BIN="$CARGO_TARGET_DIR/debug/sky-app"
else
    BIN="$HERE/sky-out/Rust/target/debug/sky-app"
fi
fail() { echo "FAIL: $1"; exit 1; }
[ -x "$BIN" ] || fail "binary not found at $BIN (build: sky build src/Main.sky --target rust)"

OUT="$("$BIN" 2>&1)"
echo "$OUT"
EXPECTED="get name -> Alice
size -> 1
hits=1 misses=0"
[ "$OUT" = "$EXPECTED" ] || fail "output mismatch — got:
$OUT"
echo
echo "PASS — Std.Cache new/put/get/size/stats correct on Rust (≡ Go)."
