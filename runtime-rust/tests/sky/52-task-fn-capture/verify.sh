#!/usr/bin/env bash
# Regression for a Rust-backend codegen E0599 (".clone() on a non-Clone capture").
#
# A function like `withThing : String -> (String -> Task Error a) -> Task Error a`
# captures non-`Clone` values into the closures it builds for Task.andThen /
# Task.onError:
#   * `action`  — an `impl Fn(String) -> SkyTask<a>` HOF parameter (non-`Clone`)
#   * `cleanup` — a `let`-bound `SkyTask` (`Pin<Box<dyn Future>>`, non-`Clone`)
#                 captured by BOTH sibling closures (success + error arms).
#
# The capture-prelude unconditionally emitted `let v = v.clone();` for every
# captured local -> E0599 (`Pin<Box<dyn Future>>: Clone` is unsatisfied; an
# `impl Fn` param is non-`Clone` too).
#
# The fix Arc-wraps non-`Clone` captures at their binding site (the `impl Fn`
# param at function entry; the SkyTask `let` binding), so `Arc::clone` is what
# the prelude calls — sound for BOTH the single-consumer (action threaded
# through nesting) and the multi-sibling-consumer (cleanup in 2 arms) cases.
#
# A successful `cargo build` (driven by `sky build`) AND a clean run are the
# gates. The greps pin the Arc-wrap shape so a regression is caught.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$HERE/sky-out/Rust/src/main.rs"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$GEN" ] || fail "generated Rust not found at $GEN (build: sky build src/Main.sky --backend rust)"

# The `action` impl-Fn param is Arc-wrapped at function entry.
grep -qE 'let action = std::sync::Arc::new\(action\)' "$GEN" \
    || fail "impl-Fn param 'action' not Arc-wrapped (non-Clone capture fix regressed?)"

# The `cleanup` SkyTask let-binding is Arc-wrapped.
grep -qE 'cleanup = std::sync::Arc::new\(' "$GEN" \
    || fail "SkyTask 'cleanup' let-binding not Arc-wrapped (non-Clone capture fix regressed?)"

# Build + run into a PROJECT-LOCAL target so a shared CARGO_TARGET_DIR (set by
# the sweep — every example is package `sky-app`, so the shared dir holds only
# the LAST build) can't hand us a sibling example's binary. Unset it for our own
# cargo invocation so the binary lands deterministically under sky-out/Rust/target.
BIN="$HERE/sky-out/Rust/target/debug/sky-app"
( cd "$HERE/sky-out/Rust" && env -u CARGO_TARGET_DIR cargo build -q ) \
    || fail "cargo build failed"
[ -f "$BIN" ] || fail "binary not found at $BIN after build"

# Sanity: the run binary exists and prints the expected line.
OUT="$("$BIN" 2>&1)" || fail "binary exited non-zero: $OUT"
echo "$OUT" | grep -q "used thing-demo" \
    || fail "expected 'used thing-demo' in output, got: $OUT"

echo "PASS — non-Clone (impl Fn + SkyTask) captures Arc-wrapped; builds + runs (no E0599)."
