# skyshop-rs port — filed codegen / runtime / stdlib gaps

Gaps surfaced while porting `examples/13-skyshop` to the Rust backend. Per the
no-deferral rule these are FILED here (not buried as silent workarounds). Each
has a repro + proposed in-boundary fix + current disposition.

## Status legend
`OPEN` actionable in-boundary · `OPEN-UPSTREAM` needs a shared-stdlib change (out of boundary) · `FIXED` landed

---

## G1 — Unconstrained `Result` Ok-payload defaults to `i64` (codegen) — FIXED

**Fixed** in commit `b8a2e574` (`fix(rust): recover Result Ok/Err payload from
enclosing return instead of i64 default (spec G1)`). Regression fixture:
`runtime-rust/tests/sky/59-result-passthrough-nosig`.

**Symptom (resolved).** A function returning `Result Error a` with no explicit Sky
signature and passthrough arms (`Ok v -> Ok v` / `Err e -> Err e`) used to
miscompile on `--target rust`: the Ok arm's payload type was left unconstrained
and the Rust codegen defaulted it to `i64`, mismatching the Err arm (E0308). Go
infers these fine. The port worked around it at the time by adding explicit Sky
signatures to ~11 Cart/Products helpers; those annotations are no longer required.

**Repro shape.**
```elm
-- no signature → Ok payload defaults to i64 in Rust, breaks
saveThing thing =
    case validate thing of
        Ok v  -> Ok v          -- v's type unconstrained at this region
        Err e -> Err e
```

**Fix landed (in-boundary).** The Rust lowerer now recovers an unconstrained
`Result`/`Task` Ok/Err payload from the *enclosing return type* via
`ecEnclosingRet` (`src/Sky/Generate/Rust/Builder/Types.hs:583`, consumed in the
ExprEmitter ctor arm) rather than defaulting to `i64`. Regression fixture
`runtime-rust/tests/sky/59-result-passthrough-nosig` exercises the
unannotated-passthrough shape.

## G2 — `Dict.union` not in the Rust runtime — FIXED

**Symptom (resolved).** `Dict.union` lowers to `dict_union`, which used to be
absent from `runtime-rust/src/sky_runtime/dict.rs` → `E0425`. Worked around at
the time in `Lib/Auth.findOrCreateUser`.

**Fix landed (in-boundary).** `pub fn dict_union<K, V>(a, b)` now lives at
`runtime-rust/src/sky_runtime/dict.rs:90` with Sky's left-biased union semantics
(keys in `a` win), matching the Go runtime + `Sky.Core.Dict.union`. Pure runtime
change (no cabal rebuild). Unit test `test_dict_union_left_biased` at
`dict.rs:197`.

## G3 — `List.sortBy` absent from `Sky.Core.List` — OPEN-UPSTREAM

**Symptom.** `List.sortBy` (and `sort`/`sortWith`) is not surfaced by the shared
stdlib `sky-stdlib/Sky/Core/List` (only a stale comment), so a call site can't
resolve the name. The port used a pure-Sky insertion sort in
`Lib/Products.sortProducts`.

**Disposition.** The Rust backend is already READY for these: Kernel.hs routes
`List.sortBy`/`sort`/`sortWith` to `list_sort_by`/`list_sort`/`list_sort_with`
(`src/Sky/Generate/Rust/Builder/Kernel.hs:71-76`), and the runtime fns exist +
are tested (`runtime-rust/src/sky_runtime/list.rs:124,135,154`). The ONLY missing
piece is the shared-stdlib *exposing surface* (`sky-stdlib/`), which is OUT of the
Rust-backend boundary (editing it would affect the Go backend too). Filed here for
visibility; do NOT patch the stdlib in-boundary — raise the `sortBy`/`sortWith`
stdlib addition with the stdlib owner. Once exposed, the Rust kernel already
binds it with no further codegen change.

---

## Cross-reference
Discovered during the [[skyshop-rs-port]] work; see
`runtime-rust/docs/superpowers/specs/2026-06-15-skyshop-rs-port-SYNTHESIS.md`.
The two HIGH codegen regressions in the event-handler Arc change (anon non-event
field over-wrap; capturing-lambda event-arg under-wrap) are tracked + fixed
separately (they violate the "type-checks ⇒ builds" floor) — see the Phase-6
review remediation commit.
