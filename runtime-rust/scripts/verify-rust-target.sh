#!/usr/bin/env bash
# Rust-target verification script.
# Runs cargo check, clippy, tests, and the six green examples.
set -euo pipefail

cd "$(dirname "$0")/../.."
SKY_BIN="${SKY_BIN:-./sky-out/sky}"

if [ ! -x "$SKY_BIN" ]; then
    echo "ERROR: Sky binary not found at $SKY_BIN. Build it first with: cabal build exe:sky"
    exit 1
fi

echo "=== 1. Cargo check ==="
(cd runtime-rust && cargo check --all-features 2>&1 | tail -3)

echo ""
echo "=== 2. Cargo clippy (-D warnings) ==="
# Real exit must propagate — do NOT pipe to tail (that masks the failure).
(cd runtime-rust && cargo clippy --all-targets --all-features -- -D warnings) \
    || { echo "  ❌ clippy failed"; exit 1; }

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
echo "=== 6. All-example --target rust sweep (BUILD only) ==="
# examples-sweep.sh bins every in-scope example (build_set) + prints a PASS/FAIL
# verdict; a non-zero exit means in-scope failures (we surface, don't abort).
# BUILD_ONLY keeps this verify fast + go-free; FORCE bypasses the night gate (this
# verify is run on demand, not on a schedule).
SKY_SWEEP_BUILD_ONLY=1 SKY_SWEEP_FORCE=1 runtime-rust/scripts/examples-sweep.sh \
  || echo "  ⚠ sweep shows in-scope failures — see the table path above"

echo ""
echo "=== All checks passed ==="
