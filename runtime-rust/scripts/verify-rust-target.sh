#!/usr/bin/env bash
# Rust-target verification script.
# Runs cargo check, clippy, tests, and the six green examples.
set -euo pipefail

cd "$(dirname "$0")/../.."
SKY_BIN="${SKY_BIN:-./sky-out/sky}"
# Absolutize: later steps `cd` into per-example dirs (subshells), where a relative
# `./sky-out/sky` no longer resolves. We are at the repo root here.
case "$SKY_BIN" in
    /*) ;;
    *)  SKY_BIN="$PWD/${SKY_BIN#./}" ;;
esac

if [ ! -x "$SKY_BIN" ]; then
    echo "ERROR: Sky binary not found at $SKY_BIN. Build it first with: cabal build exe:sky"
    exit 1
fi

# Bound long cargo runs per the project timeout-gate rule (non-negotiable #3) so a
# wedged child (hung linker, stalled crate fetch, deadlocked test) can't hang the
# verify forever. Degrade gracefully where `timeout` is unavailable (e.g. macOS
# without coreutils) — empty expands to nothing, leaving the bare cargo call.
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT="timeout 1800"
else
    TIMEOUT=""
fi

echo "=== 1. Cargo check ==="
(cd runtime-rust && $TIMEOUT cargo check --all-features 2>&1 | tail -3)

echo ""
echo "=== 2. Cargo clippy (-D warnings) ==="
# Real exit must propagate — do NOT pipe to tail (that masks the failure).
(cd runtime-rust && $TIMEOUT cargo clippy --all-targets --all-features -- -D warnings) \
    || { echo "  ❌ clippy failed"; exit 1; }

echo ""
echo "=== 3. Cargo test ==="
# Capture full output so compiler/test diagnostics survive a failure; only grep a
# copy for the summary line. A test-COMPILE failure emits no "test result:" line,
# so grepping the live pipe would discard every diagnostic and false-fail blank.
test_out=$( (cd runtime-rust && $TIMEOUT cargo test --all-features 2>&1) ) \
    || { echo "$test_out"; echo "  ❌ cargo test failed"; exit 1; }
echo "$test_out" | grep -E "^test result" || true

echo ""
echo "=== 4. Six green examples ==="
FAIL=0
for ex in 01-hello-world 04-local-pkg 14-task-demo simple 07-todo-cli test_pkg; do
    if (cd "examples/$ex" && rm -rf sky-out .skycache .skydeps \
        && $TIMEOUT "$SKY_BIN" build src/Main.sky --backend rust \
        && $TIMEOUT cargo build --manifest-path sky-out/rust/Cargo.toml -q 2>&1); then
        echo "  ✅ $ex"
    else
        echo "  ❌ $ex"
        FAIL=1
    fi
done

echo ""
echo "=== 5. No Go artifacts after --backend rust ==="
GO_ARTIFACT=0
for ex in 01-hello-world; do
    for f in main.go go.mod go.sum rt; do
        if [ -e "examples/$ex/sky-out/$f" ]; then
            echo "  ❌ $ex has Go artifact sky-out/$f"
            GO_ARTIFACT=1
        fi
    done
done
if [ "$GO_ARTIFACT" = 0 ]; then
    echo "  ✅ No Go artifacts detected"
else
    FAIL=1
fi

echo ""
echo "=== 6. All-example --backend rust sweep (BUILD only) ==="
# examples-sweep.sh bins every in-scope example (build_set) + prints a PASS/FAIL
# verdict; a non-zero exit means in-scope failures (we surface, don't abort).
# BUILD_ONLY keeps this verify fast + go-free; FORCE bypasses the night gate (this
# verify is run on demand, not on a schedule).
SKY_SWEEP_BUILD_ONLY=1 SKY_SWEEP_FORCE=1 runtime-rust/scripts/examples-sweep.sh \
  || echo "  ⚠ sweep shows in-scope failures — see the table path above"

echo ""
if [ "$FAIL" != 0 ]; then
    echo "=== Checks FAILED — see ❌ rows above ==="
    exit 1
fi
echo "=== All checks passed ==="
