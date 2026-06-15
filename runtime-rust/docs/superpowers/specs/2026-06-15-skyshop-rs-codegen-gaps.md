# skyshop-rs port — filed codegen / runtime / stdlib gaps

Gaps surfaced while porting `examples/13-skyshop` to the Rust backend. Per the
no-deferral rule these are FILED here (not buried as silent workarounds). Each
has a repro + proposed in-boundary fix + current disposition.

## Status legend
`OPEN` actionable in-boundary · `OPEN-UPSTREAM` needs a shared-stdlib change (out of boundary) · `FIXED` landed

---

## G1 — Unconstrained `Result` Ok-payload defaults to `i64` (codegen) — OPEN

**Symptom.** A function returning `Result Error a` with no explicit Sky signature
and passthrough arms (`Ok v -> Ok v` / `Err e -> Err e`) miscompiles on
`--target rust`: the Ok arm's payload type is left unconstrained and the Rust
codegen defaults it to `i64`, mismatching the Err arm (E0308). Go infers these
fine. Worked around in the port by adding explicit Sky signatures to ~11
Cart/Products helpers.

**Repro shape.**
```elm
-- no signature → Ok payload defaults to i64 in Rust, breaks
saveThing thing =
    case validate thing of
        Ok v  -> Ok v          -- v's type unconstrained at this region
        Err e -> Err e
```

**Proposed fix (in-boundary).** In the Rust lowerer, when a `Result`/`Task` Ok
payload region is unconstrained, resolve it from the *expected return type* at
the call/return site (the same mechanism `taskExprInnerType` already uses for
`Task`), rather than defaulting to `i64`. Scope: `src/Sky/Generate/Rust/Builder/`
(ExprEmitter return-type inference). Add a regression example exercising the
unannotated-passthrough shape.

## G2 — `Dict.union` not in the Rust runtime — OPEN

**Symptom.** `Dict.union` lowers to `dict_union`, which does not exist in
`runtime-rust/src/sky_runtime/dict.rs` → `E0425`. Worked around in
`Lib/Auth.findOrCreateUser`.

**Proposed fix (in-boundary).** Add `pub fn dict_union(a, b)` to
`runtime-rust/src/sky_runtime/dict.rs` with Sky's left-biased union semantics
(keys in `a` win), matching the Go runtime + `Sky.Core.Dict.union`. Pure
runtime change (no cabal rebuild). Add a `dict_determinism`-style unit test.

## G3 — `List.sortBy` absent from `Sky.Core.List` — OPEN-UPSTREAM

**Symptom.** `List.sortBy` is not implemented in the shared stdlib
`sky-stdlib/Sky/Core/List` (only a stale comment); any use fails. Worked around
with a pure-Sky insertion sort in `Lib/Products.sortProducts`.

**Disposition.** The fix belongs in the **shared stdlib** (`sky-stdlib/`), which
is OUT of the Rust-backend boundary (editing it would affect the Go backend
too). Filed here for visibility; the actual fix is an upstream stdlib addition
(`sortBy`/`sortWith`) that the Rust backend would then get a kernel for. Do NOT
patch it in-boundary. Raise with the stdlib owner.

---

## Cross-reference
Discovered during the [[skyshop-rs-port]] work; see
`runtime-rust/docs/superpowers/specs/2026-06-15-skyshop-rs-port-SYNTHESIS.md`.
The two HIGH codegen regressions in the event-handler Arc change (anon non-event
field over-wrap; capturing-lambda event-arg under-wrap) are tracked + fixed
separately (they violate the "type-checks ⇒ builds" floor) — see the Phase-6
review remediation commit.
