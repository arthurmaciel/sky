#!/usr/bin/env bash
# Negative-path fixture for the Go-package -> Rust FFI divergence
# (disposition DOCUMENT_BLOCKED). Proves that a [go.dependencies] build under
# --target rust REFUSES CLEANLY: exit != 0, an E1001 / "Undefined name"
# refusal in the output, NO sky-out/Rust/src/main.rs produced, and NO Rust
# panic marker. A clean compile-time refusal is the strongest failure mode —
# not a panic, not a late cargo error, not a silent success.
#
# Spec: runtime-rust/docs/superpowers/specs/2026-06-15-go-package-rust-ffi-design.md
set -u
cd "$(dirname "$0")"

fail=0
note() { echo "  - $1"; }

# Clean slate so the assertion on "no main.rs emitted" is meaningful.
rm -rf sky-out .skycache .skydeps

out=$(timeout 120 ../../../sky-out/sky build --target rust src/Main.sky 2>&1)
code=$?

echo "=== sky build --target rust (exit $code) ==="
echo "$out"
echo "==========================================="

# ASSERT 1 — exit non-zero (the build must fail, not succeed).
if [ "$code" -eq 0 ]; then
    note "FAIL: expected non-zero exit, got 0 (build did not refuse)"
    fail=1
else
    note "ok: build exited non-zero ($code)"
fi

# ASSERT 2 — the refusal is the expected clean naming error.
if echo "$out" | grep -qE 'E1001|Undefined name'; then
    note "ok: output carries the E1001 / 'Undefined name' refusal"
else
    note "FAIL: refusal message (E1001 / 'Undefined name') not found in output"
    fail=1
fi

# ASSERT 3 — no Rust source was emitted (refusal happened before codegen).
if [ -f sky-out/Rust/src/main.rs ]; then
    note "FAIL: sky-out/Rust/src/main.rs was produced — codegen ran despite refusal"
    fail=1
else
    note "ok: no sky-out/Rust/src/main.rs produced"
fi

# ASSERT 4 — no Rust panic leaked (must be a clean refusal, not an abort).
if echo "$out" | grep -qE 'panicked at|RUST_BACKTRACE'; then
    note "FAIL: output contains a Rust panic marker"
    fail=1
else
    note "ok: no Rust panic marker in output"
fi

# Clean up generated artifacts regardless of outcome.
rm -rf sky-out .skycache .skydeps

if [ "$fail" -ne 0 ]; then
    echo "FAIL: go-dep-refusal — clean refusal NOT proven"
    exit 1
fi
echo "PASS: go-dep-refusal — [go.dependencies] under --target rust refuses cleanly"
exit 0
