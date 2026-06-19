#!/usr/bin/env bash
# Regression for two codegen bugs in the event-handler Arc change (e72bd036).
# Both made valid Sky that type-checks cleanly FAIL `cargo build` on the Rust
# backend. This verify.sh asserts the FIXED codegen shapes in the generated
# Rust (a successful `cargo build` of this fixture is the primary gate; these
# greps pin the exact shapes so a regression in either direction is caught even
# if some unrelated change happens to keep the build green).
#
# B#1 — a non-event `String -> Int` field on an ANONYMOUS record, assigned a
#   bare fn ITEM, must NOT be `Arc::new`-wrapped (its slot is a bare `fn`
#   generic, not `Arc<dyn Fn>`). Pre-fix it emitted `Arc::new(main_length_score)`.
# B#2 — a CAPTURING lambda passed DIRECTLY to `onInput` MUST be `Arc::new`-wrapped
#   (its slot is `Arc<dyn Fn(String) -> Msg + Send + Sync>`). Pre-fix it emitted
#   a bare closure → `E0308 expected Arc<..>, found closure`.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$HERE/sky-out/rust/src/main.rs"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$GEN" ] || fail "generated Rust not found at $GEN (build: sky build src/Main.sky --backend rust)"

# B#1: the anon `scorer` field is the bare fn item, with NO Arc::new around it.
grep -qE 'scorer: main_length_score\b' "$GEN" \
    || fail "B#1: expected bare 'scorer: main_length_score' (no Arc::new) — anon non-event field over-wrapped?"
grep -qE 'scorer: std::sync::Arc::new\(main_length_score\)' "$GEN" \
    && fail "B#1 REGRESSION: anon non-event 'String -> Int' field wrapped in Arc::new(main_length_score)"

# B#2: the onInput capturing lambda is Arc::new-wrapped (capture-cloned closure).
grep -qE 'std_html_events_on_input\(std::sync::Arc::new\(\{ let model = model.clone\(\); move \|s\|' "$GEN" \
    || fail "B#2: expected onInput capturing lambda wrapped in Arc::new(move closure) — closure not Arc-wrapped?"

echo "PASS — B#1 (anon non-event field NOT Arc-wrapped) + B#2 (onInput capturing lambda IS Arc-wrapped) on Rust."
