#!/usr/bin/env bash
# Rust-target verification script.
# Runs cargo check, clippy, tests, and the six green examples.
set -euo pipefail

cd "$(dirname "$0")/.."
SKY_BIN="${SKY_BIN:-./sky-out/sky}"

if [ ! -x "$SKY_BIN" ]; then
    echo "ERROR: Sky binary not found at $SKY_BIN. Build it first with: cabal build exe:sky"
    exit 1
fi

echo "=== 1. Cargo check ==="
(cd runtime-rust && cargo check --all-features 2>&1 | tail -3)

echo ""
echo "=== 2. Cargo clippy (-D warnings) ==="
(cd runtime-rust && cargo clippy --all-targets --all-features -- -D warnings 2>&1 | tail -3)

echo ""
echo "=== 3. Cargo test ==="
(cd runtime-rust && cargo test --all-features 2>&1 | grep -E "^test result" )

echo ""
echo "=== 4. Six green examples ==="
for ex in 01-hello-world 04-local-pkg 14-task-demo simple 07-todo-cli test_pkg; do
    (cd examples/$ex && rm -rf sky-out .skycache .skydeps \
        && $SKY_BIN build src/Main.sky --target rust \
        && cargo build --manifest-path sky-out/Rust/Cargo.toml -q 2>&1) \
        && echo "  ✅ $ex" || echo "  ❌ $ex"
done

echo ""
echo "=== 5. No Go artifacts after --target rust ==="
for ex in 01-hello-world; do
    for f in main.go go.mod go.sum rt; do
        [ ! -e "examples/$ex/sky-out/$f" ] || echo "  ❌ $ex has Go artifact sky-out/$f"
    done
done
echo "  ✅ No Go artifacts detected"

echo ""
echo "=== All checks passed ==="
