#!/usr/bin/env bash
# Cross-target output verification script.
# Builds each example with both --target go and --target rust,
# runs both, and diffs their textual stdout output to catch
# silent divergence between backends.
set -euo pipefail

cd "$(dirname "$0")/.."
SKY_BIN="${SKY_BIN:-./sky-out/sky}"
SKY_BIN_ABS="$(cd "$(dirname "$SKY_BIN")" && pwd)/$(basename "$SKY_BIN")"

if [ ! -x "$SKY_BIN" ]; then
    echo "ERROR: Sky binary not found at $SKY_BIN. Build it first with: cabal install"
    exit 1
fi

EXAMPLES=(01-hello-world 04-local-pkg 06-json 14-task-demo simple test_pkg)
# 07-todo-cli is skipped because it's interactive (CLI stdin)
# cross-target-07 would need expect/pty machinery
FAILED=0
PASSED=0
SKIPPED=0

for ex in "${EXAMPLES[@]}"; do
    echo -n "=== $ex ... "

    # Build and run Go target (from example dir so sky build finds the entry)
    (cd "examples/$ex" && rm -rf sky-out .skycache && \
     "$SKY_BIN_ABS" build src/Main.sky --target go >/dev/null 2>&1)
    if [ ! -x "examples/$ex/sky-out/app" ]; then
        echo "GO BUILD FAILED"
        FAILED=$((FAILED+1))
        continue
    fi
    "examples/$ex/sky-out/app" >/tmp/verify-go-"$ex".txt 2>/dev/null || true

    # Build and run Rust target
    (cd "examples/$ex" && rm -rf sky-out/Rust .skycache && \
     "$SKY_BIN_ABS" build src/Main.sky --target rust >/dev/null 2>&1)
    if [ ! -d "examples/$ex/sky-out/Rust" ]; then
        echo "RUST BUILD FAILED"
        FAILED=$((FAILED+1))
        continue
    fi
    (cd "examples/$ex/sky-out/Rust" && cargo run 2>/dev/null) >/tmp/verify-rust-"$ex".txt || true

    # Diff outputs (skip empty lines, limit to 50 lines)
    if diff <(grep -v "^$" /tmp/verify-go-"$ex".txt | head -50) \
            <(grep -v "^$" /tmp/verify-rust-"$ex".txt | head -50) >/tmp/verify-diff-"$ex".txt 2>&1; then
        echo "OK"
        PASSED=$((PASSED+1))
    else
        echo "DIFFERS:"
        cat /tmp/verify-diff-"$ex".txt
        FAILED=$((FAILED+1))
    fi
done

echo ""
echo "--- Summary ---"
echo "Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
