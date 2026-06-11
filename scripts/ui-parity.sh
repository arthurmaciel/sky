#!/usr/bin/env bash
# Render-diff harness: build each corpus fixture on Go AND Rust, byte-diff stdout.
# Go is the reference (golden). Usage:
#   scripts/ui-parity.sh                 # diff every fixture against committed goldens
#   scripts/ui-parity.sh --update-golden # (re)capture Go output as the golden
#   scripts/ui-parity.sh T2-font-size    # one fixture
set -uo pipefail
cd "$(dirname "$0")/.."
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/sky-rust-target}"
export RUSTC_WRAPPER="${RUSTC_WRAPPER:-sccache}"
SKY="${SKY_BIN:-$PWD/sky-out/sky}"
H="tests/ui-parity/harness"; CORPUS="tests/ui-parity/corpus"; GOLD="tests/ui-parity/golden"
mkdir -p "$GOLD"
UPDATE=0; FILTER=""
for a in "$@"; do case "$a" in --update-golden) UPDATE=1;; *) FILTER="$a";; esac; done

build_run() { # $1=go|rust -> stdout (or empty on failure); writes nothing else
  ( cd "$H" && rm -rf sky-out .skycache .skydeps ) >/dev/null 2>&1
  if [ "$1" = go ]; then
    ( cd "$H" && timeout 300 "$SKY" build src/Main.sky ) >/tmp/uip-build.log 2>&1 || return 1
    ( cd "$H" && ./sky-out/app ) 2>/dev/null
  else
    ( cd "$H" && timeout 300 "$SKY" build src/Main.sky --target rust ) >/tmp/uip-build.log 2>&1 || return 1
    ( cd "$H" && cargo build --release --manifest-path sky-out/Rust/Cargo.toml ) >/tmp/uip-cargo.log 2>&1 || return 1
    find "$H/sky-out/Rust/target/release" -maxdepth 1 -type f -executable | head -1 | xargs -r -I{} {} 2>/dev/null
  fi
}

pass=0; fail=0; failed=()
for f in "$CORPUS"/*.sky; do
  name=$(basename "$f" .sky); [ -n "$FILTER" ] && [ "$name" != "$FILTER" ] && continue
  cp "$f" "$H/src/Main.sky"
  if [ "$UPDATE" = 1 ]; then
    go_out=$(build_run go) || { echo "GOLDEN-FAIL(go) $name (see /tmp/uip-build.log)"; fail=$((fail+1)); continue; }
    printf '%s' "$go_out" > "$GOLD/$name.html"; echo "golden $name"; continue
  fi
  [ -f "$GOLD/$name.html" ] || { echo "NO-GOLDEN $name (run --update-golden)"; fail=$((fail+1)); failed+=("$name"); continue; }
  rust_out=$(build_run rust) || { echo "RUST-BUILD-FAIL $name (see /tmp/uip-build.log /tmp/uip-cargo.log)"; fail=$((fail+1)); failed+=("$name"); continue; }
  if [ "$rust_out" = "$(cat "$GOLD/$name.html")" ]; then echo "PASS $name"; pass=$((pass+1));
  else echo "DIFF $name:"; diff <(cat "$GOLD/$name.html") <(printf '%s' "$rust_out") | head -20; fail=$((fail+1)); failed+=("$name"); fi
done
echo "---- ui-parity: $pass pass / $fail fail ----"
[ ${#failed[@]} -gt 0 ] && echo "failed: ${failed[*]}"
[ "$fail" -eq 0 ]
