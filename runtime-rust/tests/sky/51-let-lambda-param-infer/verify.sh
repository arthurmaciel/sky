#!/usr/bin/env bash
# Regression for a Rust-backend codegen E0282 ("type annotations needed").
#
# A `let`-bound multi-param closure whose params are provably concrete from the
# solved HM types — but which the body-driven kernel-flow / record heuristics
# don't cover (the params flow only into `String.trim` / `++`, neither in the
# narrow kernelArgRustType allowlist) — was emitted with NO param annotations
# (`move |buildOutput, runOutput| { … }`). When the closure is stored and called
# later inside a Task chain, Rust has no call-site to infer the params from at
# the definition → E0282. Same for the `\buildOut -> combine buildOut …` lambda
# passed to `task_and_then`.
#
# The fix reads the solver's per-region types (globalRegionTypes) at the param's
# USE sites and annotates with the concrete type (`String` here). A successful
# `cargo build` (driven by `sky build`) is the primary gate; the greps pin the
# exact emitted shapes so a regression in either direction is caught.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$HERE/sky-out/Rust/src/main.rs"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$GEN" ] || fail "generated Rust not found at $GEN (build: sky build src/Main.sky --backend rust)"

# The let-bound `combine` closure params are annotated String (was bare → E0282).
grep -qE 'combine = move \|buildOutput: String, runOutput: String\|' "$GEN" \
    || fail "let-bound 'combine' closure params not annotated String (region-type inference regressed?)"

# The `\buildOut -> …` lambda passed into task_and_then is annotated String too.
grep -qE 'move \|buildOut: String\|' "$GEN" \
    || fail "task_and_then closure param 'buildOut' not annotated String (region-type inference regressed?)"

# No un-annotated bare 'buildOutput,' param survived (the E0282 shape).
grep -qE 'move \|buildOutput, runOutput\|' "$GEN" \
    && fail "REGRESSION: bare un-annotated 'move |buildOutput, runOutput|' (E0282 shape) re-emitted"

echo "PASS — let-bound + task-chain closure params annotated from solver region types (no E0282)."
