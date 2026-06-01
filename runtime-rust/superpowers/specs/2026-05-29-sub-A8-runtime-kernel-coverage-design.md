# Sub-A.8 — runtime-kernel coverage to close the headline gate — Design

**Date:** 2026-05-29
**Status:** Approved (brainstorming) — ready for implementation plan
**Scope:** Add the 54 missing runtime kernel implementations identified after the codegen-completion plan. Pure Rust port of the corresponding Go kernels in `runtime-go/rt/`.
**Branch:** `feat/runtime-rust`
**Builds on:** Codegen-completion plan (commits `7e1302e5..84a5eced`, all on `origin/feat/runtime-rust`).

---

## 1. Context

The codegen-completion plan closed the two infrastructure blockers (Issue 2:
`Ffi.callPure` peephole; Issue 3: opaque-type registry). Generated Rust for
`examples/00-standard-libs` on `target=rust` now correctly calls runtime
kernels by name — but ~54 of those kernel names don't exist in
`runtime-rust/src/sky_runtime/` because sub-A.1-A.6 only shipped the
modules listed in its original scope. The headline gate
(`120 passed, 0 failed` on target=rust) is blocked on filling the gap.

This sub-plan adds the missing kernels. Pure additive work, mostly
mechanical, all Rust-target-only. No further codegen / FFI / opaque-type
changes.

## 2. Goal

After this work:

1. Every kernel name the codegen emits for `examples/00-standard-libs` exists
   as a `pub fn` in `runtime-rust/src/sky_runtime/`.
2. `examples/00-standard-libs` on `target=rust` builds cleanly (cargo: 0
   errors) and runs to completion with the same test outcomes as `target=go`.
3. The headline gate `120 passed, 0 failed (120 total)` on `target=rust` is
   the contractual sub-A acceptance bar — must match `target=go` exactly.
4. 16/16 `examples/rust/*` continue to build and run.
5. Go path is byte-identical.

## 3. Non-goals (explicit)

- **No codegen changes** to `src/Sky/Generate/Rust/Builder.hs` beyond the
  `kernelToRust` arms for newly-implemented kernels. The peephole +
  registry stay as shipped.
- **No new sub-A modules** beyond the kernels listed below. Std.Random
  expansion, Std.Http user-facing kernels, Std.Crypto bcrypt etc. are
  separate.
- **No tier-2 fixes to codegen-emitted shape mismatches** unless they
  block the headline gate. Out-of-scope errors will be documented for a
  follow-on pass.
- **Go backend untouched.**

## 4. Verified gap (grounded in fresh build)

Captured 2026-05-29 from `cargo build` on the target=rust output of
`examples/00-standard-libs`:

| Module | Count | Missing kernels |
|---|---|---|
| Std.Decimal completion | 15 | `decimal_eq`, `decimal_neq`, `decimal_lt`, `decimal_lte`, `decimal_gt`, `decimal_gte`, `decimal_min`, `decimal_max`, `decimal_is_zero`, `decimal_is_positive`, `decimal_is_negative`, `decimal_percent_of`, `decimal_add_percent`, `decimal_sub_percent`, `decimal_format_with` |
| Std.Money | 11 | `money_format`, `money_format_with_code`, `money_currency_name`, `money_symbol`, `money_minor_units`, `money_is_known_currency`, `money_set_rate`, `money_get_rate`, `money_has_rate`, `money_clear_rates`, `money_allocate` |
| Sky.Core.Math | 8 | `math_sqrt`, `math_pow`, `math_round`, `math_floor`, `math_ceil`, `math_abs`, `math_min`, `math_max` |
| Std.Time advanced | 7 | `time_diff_seconds`, `time_diff_minutes`, `time_diff_hours`, `time_diff_days`, `time_from_parts`, `time_zone_offset`, `time_zone_name` |
| Sky.Core.Dict | 6 | `dict_empty`, `dict_get`, `dict_insert`, `dict_keys`, `dict_remove`, `dict_member` (and `dict_from_list` reported but no callsite — drop it) |
| Sky.Core.String | 4 | `string_replace`, `string_starts_with`, `string_ends_with`, `string_repeat` |
| Sky.Core.Basics | 2 | `basics_mod_by`, `basics_error_to_string` |
| Sky.Core.List | 1 | `list_filter_map` |
| **Total** | **54** | |

Plus tier-2: ~30 `E0308 mismatched types` errors that may surface as the
above are unblocked. These get addressed per kernel — when the wrapper's
signature in `std_decimal.rs` etc. doesn't line up with the runtime
function's signature, we adjust the runtime function's signature to match
(NOT the codegen).

## 5. Design — single-file module growth

Each kernel goes into the **existing** `runtime-rust/src/sky_runtime/*.rs`
file for its module:

- `decimal.rs` extends with the 15 missing decimal kernels.
- A new `money.rs` for Std.Money (no existing file; first sub-A.8 addition).
- `time.rs` extends with the 7 advanced calendar-math kernels.
- A new `math.rs` for Sky.Core.Math (no existing file).
- A new `dict.rs` for Sky.Core.Dict.
- `core.rs` (or a new `string.rs` if cleaner) extends with String kernels.
- `core.rs` extends with Basics + List kernels.

Each new file follows the established pattern from `encoding.rs` /
`regex_kernel.rs`: `pub fn <kernel_name>(<args>) -> <T> { … }` plus
`#[cfg(test)] mod tests { … }`.

`Project.hs`'s hardcoded `baseMods` / `baseUse` lists get the new files added.

### Sky-side type contracts (from `sky-stdlib/`)

Each kernel signature is dictated by the Sky stdlib's `Ffi.callPure "X" […]`
call shape. For instance:

```elm
-- Std.Decimal.eq : Decimal -> Decimal -> Bool
eq a b = Ffi.callPure "Decimal_eq" [ Ffi.toAny a, Ffi.toAny b ]
```

After the peephole, this emits:
```rust
pub fn std_decimal_eq(a: StdDecimalDecimal, b: StdDecimalDecimal) -> bool {
    decimal_eq(a, b)
}
```

Which requires the runtime to provide:
```rust
pub fn decimal_eq(a: Decimal, b: Decimal) -> bool { … }
```

(`StdDecimalDecimal` is now a `pub use` alias to `sky_runtime::Decimal`
via the registry, so `Decimal` and `StdDecimalDecimal` are the same type.)

This signature derivation is mechanical — same for all 54 kernels.

### Mirror semantics from Go

For each missing kernel, the Go side at `runtime-go/rt/<module>_kernel.go`
already implements the contract. The Rust port:

1. Reads the `RegisterPure("Decimal_eq", …)` (or equivalent) entry in Go.
2. Mirrors the same logic with `rust_decimal::Decimal` / `chrono::*` /
   `std::collections::HashMap` / etc.
3. Where the Go version uses reflection / `any` boxing, the Rust version
   uses concrete typed parameters (the peephole gave us static dispatch).

Example:
```go
// runtime-go/rt/decimal_kernel.go
RegisterPure("Decimal_lt", func(args []any) any {
    if len(args) < 2 { return false }
    return decimalUnbox(args[0]).LessThan(decimalUnbox(args[1]))
})
```

becomes:
```rust
// runtime-rust/src/sky_runtime/decimal.rs
pub fn decimal_lt(a: Decimal, b: Decimal) -> bool {
    a.0 < b.0
}
```

### Std.Money allocate — fair split

The single non-trivial port: `Money.allocate` distributes a money value
into N ratios with the cent-residue distributed to early bins (so the sum
of allocations equals the input exactly). Go uses `shopspring/decimal`'s
banker's-rounding-aware loop. Rust port uses `rust_decimal`'s `round_dp`
plus a residual-tracking loop. Behaviour MUST match Go bit-for-bit for the
headline-gate tests.

### Std.Time advanced kernels

The 7 missing time kernels (`time_diff_*`, `time_from_parts`,
`time_zone_offset`, `time_zone_name`) are mechanical chrono uses:
- `time_diff_days(a, b) -> i64` → `(a_ms - b_ms) / 86_400_000`
- `time_from_parts(year, month, day, hour, min, sec, ms) -> i64` →
  `NaiveDate::from_ymd_opt(...).and_hms_milli_opt(...)` → `.and_utc().timestamp_millis()`
- `time_zone_offset(zone_name, ms) -> i64` → load `chrono_tz::Tz`, get offset for instant

### Dict — `HashMap<String, T>` with String keys

Sky's `Dict` is keyed on `String` (the Limitation #5 from CLAUDE.md —
`Dict.toList` returns string keys). The Rust runtime can use
`std::collections::HashMap<String, T>` directly:

```rust
pub type SkyDict<T> = std::collections::HashMap<String, T>;

pub fn dict_empty<T>() -> SkyDict<T> { SkyDict::new() }
pub fn dict_insert<T: Clone>(k: String, v: T, d: SkyDict<T>) -> SkyDict<T> {
    let mut d = d; d.insert(k, v); d
}
pub fn dict_get<T: Clone>(k: String, d: SkyDict<T>) -> SkyMaybe<T> {
    match d.get(&k) { Some(v) => SkyMaybe::Just(v.clone()), None => SkyMaybe::Nothing }
}
```

The functional-purity preservation (`.clone()` + return-by-value) matches
the runtime contract Sky expects.

## 6. Soundness gate

Every change is additive Rust code inside `runtime-rust/src/sky_runtime/`
plus the matching `kernelToRust` arms in `Builder.hs`. Existing arms +
existing kernels are untouched. The peephole + opaque-type registry stay
exactly as shipped — this plan only adds new kernel entries.

Tier-2 codegen mismatches (the 30 `E0308 mismatched types` errors) get
addressed per case: if the runtime's signature can mirror what the codegen
expects, we adjust the runtime side. If a codegen-side fix is genuinely
needed, we surface it as a separate sub-plan rather than touching the
codegen during this run.

## 7. Verification

1. **Per-module unit tests.** Each new kernel gets at least one
   `#[test]` proving its behaviour matches the Sky contract documented in
   `sky-stdlib/Std/<Module>.sky`. Edge cases: division by zero
   (`Decimal_div` already shipped, but `Decimal_percent_of` checks too),
   `Money.allocate` residue distribution (table-driven test from the Go
   test).

2. **Cross-target regression.**
   - `examples/01-hello-world` on `target=go` builds clean.
   - `cabal test --test-options='--match "FfiGen" --match "Toml" --match "Kernel"'`: 27 pass / 0 fail.
   - 16/16 `examples/rust/*` build and run from a wiped slate.

3. **Headline gate** — `examples/00-standard-libs` on `target=rust`:
   - `cd examples/00-standard-libs && rm -rf sky-out .skycache`
   - temporarily set `target = "rust"` in `sky.toml`
   - `../../sky-out/sky run src/Main.sky` → must print
     `120 passed, 0 failed (120 total)` (matching target=go)
   - restore `sky.toml`

4. **Per-module unit-test sweep:** `cd runtime-rust && cargo test --lib`
   → all existing 50 tests + new tests pass.

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| `Money.allocate` doesn't bit-match Go's distribution → test failures | Table-driven test ported from Go's `money_kernel_test.go` runs against the Rust impl; iterate until identical |
| `chrono`-based time kernels diverge from Go's `time` package on edge cases (DST boundaries, leap seconds) | Same approach — port the Go test vectors as Rust unit tests; iterate until match |
| Tier-2 codegen mismatches turn out to need codegen fixes after all | Each surfaced mismatch decides: (a) runtime-side fix (preferred — keeps codegen frozen); (b) defer to a follow-on sub-plan with the specific case documented. Never silently mis-implement. |
| A new kernel collides with an existing user-FFI binding's name (like the hex_encode case Task 7 caught) | All new kernel names use the `<module>_<fn>` prefix convention; user-FFI bindings live in `<crate>_bindings::*` namespace — no collisions expected. Spot-check during the regression sweep. |
| `Sky.Core.List.filterMap` semantic mismatch with Sky-source `filterMap` (the only List kernel needed) | `filterMap` is `List.filter ∘ List.map` shape — Go runtime uses `List.foldr` accumulator. Mirror the Go shape; small risk surface. |
| Cold cargo builds get slow once 5+ new modules added | Module split keeps each file under ~200 LOC; incremental builds fast; cold build adds maybe 2-3 s per new file. |

## 9. Out of scope

- Std.Random advanced functions beyond what's already in `random.rs`.
- Std.Http user-facing kernels (sub-D).
- Sky.Live wire kernels (sub-E).
- Sky.Tui terminal handlers (sub-F).
- Std.Auth bcrypt / scrypt (sub-C).
- Any tier-2 codegen-shape fix that genuinely needs `Builder.hs` work —
  documented and deferred.

## 10. Cross-backend safety

Files touched:
- `runtime-rust/src/sky_runtime/decimal.rs` (extended)
- `runtime-rust/src/sky_runtime/time.rs` (extended)
- `runtime-rust/src/sky_runtime/money.rs` (new)
- `runtime-rust/src/sky_runtime/math.rs` (new)
- `runtime-rust/src/sky_runtime/dict.rs` (new)
- `runtime-rust/src/sky_runtime/string.rs` (new)
- `runtime-rust/src/sky_runtime/basics.rs` (new — `basics_mod_by` + `basics_error_to_string`)
- `runtime-rust/src/sky_runtime/list.rs` (new — `list_filter_map`)
- `runtime-rust/src/sky_runtime/mod.rs` (declarations)
- `src/Sky/Generate/Rust/Builder.hs` (new `kernelToRust` arms)
- `src/Sky/Generate/Rust/Project.hs` (mod.rs builder — new module declarations)

**Untouched:** every Go-target file (`src/Sky/Generate/Go/`, `runtime-go/`,
`.skycache/ffi/*.kernel.json` at root). Go path byte-identical.
