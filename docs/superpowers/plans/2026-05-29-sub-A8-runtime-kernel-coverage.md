# Sub-A.8 — runtime-kernel coverage — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the 54 missing runtime kernels identified in `docs/superpowers/specs/2026-05-29-sub-A8-runtime-kernel-coverage-design.md`, closing the sub-A headline gate (`examples/00-standard-libs` on `target=rust` prints `120 passed, 0 failed`).

**Architecture:** Each kernel is a small `pub fn` in `runtime-rust/src/sky_runtime/<module>.rs`, mirroring the Go counterpart in `runtime-go/rt/<module>_kernel.go`. Files: extend `decimal.rs` + `time.rs` + `core.rs`; new files `money.rs`, `math.rs`, `dict.rs`, `string.rs`, `basics.rs`, `list.rs`. `Project.hs` + `Builder.hs` extended with module declarations + `kernelToRust` arms.

**Tech Stack:** Rust 1.x + `rust_decimal` + `chrono` + `chrono-tz` + `std::collections::HashMap`. No new external crates beyond what sub-A already added.

**Source spec:** `docs/superpowers/specs/2026-05-29-sub-A8-runtime-kernel-coverage-design.md`

---

## Preconditions

- Branch: `feat/runtime-rust` (HEAD `1c5a1596` after the spec commit).
- `mem-guard.sh` running.
- Clean working tree.
- `cabal build exe:sky` currently green; `sky-out/sky --version` prints `sky dev`.
- 16/16 `examples/rust/*` build clean.
- Targeted cabal test (`FfiGen` / `Toml` / `Kernel`): 27 pass / 0 fail.

## File Structure

| File | Status | Purpose |
|---|---|---|
| `runtime-rust/src/sky_runtime/decimal.rs` | extend | 15 comparison + sign + percent + format kernels |
| `runtime-rust/src/sky_runtime/money.rs` | **new** | 11 currency / format / rate / allocate kernels |
| `runtime-rust/src/sky_runtime/time.rs` | extend | 7 advanced diff/parts/zone kernels |
| `runtime-rust/src/sky_runtime/math.rs` | **new** | 8 numeric (sqrt/pow/round/floor/ceil/abs/min/max) |
| `runtime-rust/src/sky_runtime/dict.rs` | **new** | 6 dict primitives over `HashMap<String, T>` |
| `runtime-rust/src/sky_runtime/string.rs` | **new** | 4 String kernels (replace/startsWith/endsWith/repeat) |
| `runtime-rust/src/sky_runtime/basics.rs` | **new** | 2 helpers (modBy, errorToString) |
| `runtime-rust/src/sky_runtime/list.rs` | **new** | 1 helper (filterMap) |
| `runtime-rust/src/sky_runtime/mod.rs` | extend | declare the new modules |
| `src/Sky/Generate/Rust/Project.hs` | extend | `baseMods` + `baseUse` declarations |
| `src/Sky/Generate/Rust/Builder.hs` | extend | new `kernelToRust` arms |

---

## Task 0: Capture Go reference + Sky contracts for each kernel

**Files:**
- Read: `runtime-go/rt/decimal_kernel.go`, `runtime-go/rt/money_kernel.go`
- Read: `sky-stdlib/Std/Decimal.sky`, `sky-stdlib/Std/Money.sky`, `sky-stdlib/Std/Time.sky`, `sky-stdlib/Sky/Core/{Math,Dict,String,Basics,List}.sky`
- Write: `docs/runtime-rust/sub-A8-kernel-contracts.md` (one section per kernel: Sky signature + Go implementation snippet + Rust target signature)

- [ ] **Step 1: Sky-side contracts** — scan each `sky-stdlib/` file for every wrapper that calls `Ffi.callPure "<KernelName>" […]`, recording the Sky type signature.

- [ ] **Step 2: Go-side impls** — for each kernel name, find the `RegisterPure("<Name>", …)` block in `runtime-go/rt/<module>_kernel.go` and copy the body.

- [ ] **Step 3: Rust target signatures** — derive each Rust `pub fn` signature from the Sky type + the codegen's name-mangling (`Std.Decimal.eq` → `decimal_eq(a: Decimal, b: Decimal) -> bool` etc).

- [ ] **Step 4: Commit**

```bash
git add docs/runtime-rust/sub-A8-kernel-contracts.md
git commit -m "docs(rust): sub-A.8 Task 0 — Sky + Go contracts for every missing kernel"
```

---

## Task 1: Std.Decimal completion (15 kernels)

**Files:**
- Modify: `runtime-rust/src/sky_runtime/decimal.rs` (extend)
- Modify: `src/Sky/Generate/Rust/Builder.hs` (kernelToRust arms)

- [ ] **Step 1: Append the 15 kernels** to `decimal.rs`. Each is one-liner over `rust_decimal::Decimal`:

```rust
// === comparisons ===
pub fn decimal_eq(a: Decimal, b: Decimal) -> bool { a.0 == b.0 }
pub fn decimal_neq(a: Decimal, b: Decimal) -> bool { a.0 != b.0 }
pub fn decimal_lt(a: Decimal, b: Decimal) -> bool { a.0 < b.0 }
pub fn decimal_lte(a: Decimal, b: Decimal) -> bool { a.0 <= b.0 }
pub fn decimal_gt(a: Decimal, b: Decimal) -> bool { a.0 > b.0 }
pub fn decimal_gte(a: Decimal, b: Decimal) -> bool { a.0 >= b.0 }

// === min/max ===
pub fn decimal_min(a: Decimal, b: Decimal) -> Decimal { if a.0 <= b.0 { a } else { b } }
pub fn decimal_max(a: Decimal, b: Decimal) -> Decimal { if a.0 >= b.0 { a } else { b } }

// === sign predicates ===
pub fn decimal_is_zero(d: Decimal) -> bool { d.0.is_zero() }
pub fn decimal_is_positive(d: Decimal) -> bool { d.0 > RD::ZERO }
pub fn decimal_is_negative(d: Decimal) -> bool { d.0 < RD::ZERO }

// === percent ===
pub fn decimal_percent_of(pct: Decimal, of: Decimal) -> Decimal {
    Decimal(pct.0 * of.0 / RD::ONE_HUNDRED)
}
pub fn decimal_add_percent(pct: Decimal, base: Decimal) -> Decimal {
    Decimal(base.0 + (pct.0 * base.0 / RD::ONE_HUNDRED))
}
pub fn decimal_sub_percent(pct: Decimal, base: Decimal) -> Decimal {
    Decimal(base.0 - (pct.0 * base.0 / RD::ONE_HUNDRED))
}

// === format with — places + decimal sep + group sep ===
pub fn decimal_format_with(places: i64, dec_sep: String, group_sep: String, d: Decimal) -> String {
    let rounded = d.0.round_dp(places.max(0) as u32);
    let s = rounded.to_string();
    let (int_part, frac_part) = match s.find('.') {
        Some(i) => (&s[..i], &s[i+1..]),
        None    => (&s[..], ""),
    };
    // Group the integer part with group_sep every 3 digits from the right
    let neg = int_part.starts_with('-');
    let digits: &str = if neg { &int_part[1..] } else { int_part };
    let mut grouped = String::new();
    let chars: Vec<char> = digits.chars().rev().collect();
    for (i, c) in chars.iter().enumerate() {
        if i > 0 && i % 3 == 0 { grouped.push_str(&group_sep); }
        grouped.push(*c);
    }
    let grouped: String = grouped.chars().rev().collect();
    let sign = if neg { "-" } else { "" };
    if frac_part.is_empty() && places == 0 {
        format!("{}{}", sign, grouped)
    } else {
        format!("{}{}{}{}", sign, grouped, dec_sep, frac_part)
    }
}
```

- [ ] **Step 2: Add tests** at the bottom of the existing `#[cfg(test)] mod tests` block:

```rust
#[test]
fn test_decimal_comparisons() {
    let a = decimal_from_int(3);
    let b = decimal_from_int(5);
    assert!(decimal_lt(a.clone(), b.clone()));
    assert!(decimal_lte(a.clone(), b.clone()));
    assert!(!decimal_gt(a.clone(), b.clone()));
    assert!(!decimal_gte(a.clone(), b.clone()));
    assert!(decimal_eq(a.clone(), a.clone()));
    assert!(decimal_neq(a.clone(), b.clone()));
}

#[test]
fn test_decimal_min_max() {
    let a = decimal_from_int(3);
    let b = decimal_from_int(5);
    assert!(decimal_eq(decimal_min(a.clone(), b.clone()), a.clone()));
    assert!(decimal_eq(decimal_max(a.clone(), b.clone()), b.clone()));
}

#[test]
fn test_decimal_sign_predicates() {
    assert!(decimal_is_zero(decimal_zero()));
    assert!(!decimal_is_zero(decimal_from_int(1)));
    assert!(decimal_is_positive(decimal_from_int(1)));
    assert!(!decimal_is_positive(decimal_zero()));
    assert!(decimal_is_negative(decimal_from_int(-1)));
}

#[test]
fn test_decimal_percent() {
    let ten = decimal_from_int(10);
    let hundred = decimal_from_int(100);
    // 10% of 100 = 10
    assert!(decimal_eq(decimal_percent_of(ten.clone(), hundred.clone()), ten.clone()));
    // 100 + 10% = 110
    assert!(decimal_eq(decimal_add_percent(ten.clone(), hundred.clone()), decimal_from_int(110)));
    // 100 - 10% = 90
    assert!(decimal_eq(decimal_sub_percent(ten.clone(), hundred.clone()), decimal_from_int(90)));
}

#[test]
fn test_decimal_format_with() {
    let one_million_fifty = decimal_from_string("1050000.5".to_string());
    let v = match one_million_fifty {
        SkyResult::Ok(v) => v,
        SkyResult::Err(_) => panic!("parse failed"),
    };
    assert_eq!(decimal_format_with(2, ".".to_string(), ",".to_string(), v),
               "1,050,000.50");
}
```

(`decimal_from_string` returns `SkyResult` — needs unwrap. If `SkyResult` API differs, mirror the existing test in the same file.)

`RD::ONE_HUNDRED` needs to exist — if not, replace with `Decimal::from(100)`. Check `rust_decimal` docs.

- [ ] **Step 3: Run runtime tests**

```bash
cd runtime-rust && cargo test --lib decimal
```
Expected: all existing + 5 new tests pass.

- [ ] **Step 4: Add `kernelToRust` arms** in `Builder.hs` after the existing Decimal arms (find the block — search `("Decimal", "fromInt")`):

```haskell
    ("Decimal", "eq")              -> "decimal_eq"
    ("Decimal", "neq")             -> "decimal_neq"
    ("Decimal", "lt")              -> "decimal_lt"
    ("Decimal", "lte")             -> "decimal_lte"
    ("Decimal", "gt")              -> "decimal_gt"
    ("Decimal", "gte")             -> "decimal_gte"
    ("Decimal", "min")             -> "decimal_min"
    ("Decimal", "max")             -> "decimal_max"
    ("Decimal", "isZero")          -> "decimal_is_zero"
    ("Decimal", "isPositive")      -> "decimal_is_positive"
    ("Decimal", "isNegative")      -> "decimal_is_negative"
    ("Decimal", "percentOf")       -> "decimal_percent_of"
    ("Decimal", "addPercent")      -> "decimal_add_percent"
    ("Decimal", "subPercent")      -> "decimal_sub_percent"
    ("Decimal", "formatWith")      -> "decimal_format_with"
```

- [ ] **Step 5: Verify compiler builds**

```bash
cabal build exe:sky 2>&1 | tail -3
```

- [ ] **Step 6: Commit**

```bash
git add runtime-rust/src/sky_runtime/decimal.rs src/Sky/Generate/Rust/Builder.hs
git commit -m "feat(rust): Std.Decimal completion — eq/lt/min/sign/percent/format (15 kernels)"
```

---

## Task 2: Std.Money runtime (11 kernels)

**Files:**
- Create: `runtime-rust/src/sky_runtime/money.rs`
- Modify: `runtime-rust/src/sky_runtime/mod.rs` (declare)
- Modify: `src/Sky/Generate/Rust/Project.hs` (`baseMods` / `baseUse`)
- Modify: `src/Sky/Generate/Rust/Builder.hs` (arms)

This is the biggest task by LOC (~250). Implementation mirrors
`runtime-go/rt/money_kernel.go`.

- [ ] **Step 1: Read Go reference** (`runtime-go/rt/money_kernel.go`) and the Sky source (`sky-stdlib/Std/Money.sky`) — confirm signatures.

- [ ] **Step 2: Create `money.rs`** with:
  - `pub struct Money { amount: Decimal, currency: String }` (mirrors `StdMoneyMoney`).
  - ISO 4217 currency table (50+ entries — code/name/symbol/minor units). Pulled from Go's `lookupCurrency`. Implemented as a `static` `phf::Map` (use `phf` crate, add to Cargo.toml + runtime deps) OR a plain `match` expression (simpler — no new dep). Match is faster to bootstrap; use it.
  - `pub fn money_format(m: Money) -> String` — `"<symbol><amount with 2dp>"`.
  - `pub fn money_format_with_code(m: Money) -> String` — `"<amount> <code>"`.
  - `pub fn money_currency_name(code: String) -> String` — lookup or `""`.
  - `pub fn money_symbol(code: String) -> String` — lookup or `code`.
  - `pub fn money_minor_units(code: String) -> i64` — lookup or `2`.
  - `pub fn money_is_known_currency(code: String) -> bool` — table lookup.
  - Exchange-rate registry as a `Mutex<HashMap<(String, String), Decimal>>` (mirror Go's `setRate` / `getRate`).
  - `pub fn money_set_rate(from: String, to: String, rate: Decimal)` (store)
  - `pub fn money_get_rate(from: String, to: String) -> SkyMaybe<Decimal>` (lookup)
  - `pub fn money_has_rate(from: String, to: String) -> bool`
  - `pub fn money_clear_rates() -> ()` — flush the map.
  - `pub fn money_allocate(m: Money, ratios: Vec<i64>) -> Vec<Money>` — fair split with residue distributed early.

Full implementation in the implementation step. Each function mirrors Go's
`RegisterPure("Money_X", …)` entry. Allocate is the only non-trivial one:
sum ratios, multiply input by each / sum, round down, distribute residue
to first N bins until cents balance.

- [ ] **Step 3: Add `cfg(test)` block** with tests including the Money.allocate residue test from Go's `money_kernel_test.go`:

```rust
#[test]
fn test_money_allocate_three_ways() {
    let usd = Money { amount: Decimal(RD::from_str("100.00").unwrap()), currency: "USD".into() };
    let parts = money_allocate(usd, vec![1, 1, 1]);
    // 100/3 = 33.33 each + 0.01 residue to first
    let sum: rust_decimal::Decimal = parts.iter().map(|p| p.amount.0).sum();
    assert_eq!(sum.to_string(), "100.00");
    assert_eq!(parts[0].amount.0.to_string(), "33.34");
    assert_eq!(parts[1].amount.0.to_string(), "33.33");
    assert_eq!(parts[2].amount.0.to_string(), "33.33");
}
```

- [ ] **Step 4: Declare in source `mod.rs`**

```rust
pub mod money;
pub use money::*;
```

- [ ] **Step 5: Add to `Project.hs` `baseMods`/`baseUse`** — add `"pub mod money;"` and `"pub use money::*;"`.

- [ ] **Step 6: Add `kernelToRust` arms**

```haskell
    ("Money", "format")             -> "money_format"
    ("Money", "formatWithCode")     -> "money_format_with_code"
    ("Money", "currencyName")       -> "money_currency_name"
    ("Money", "symbol")             -> "money_symbol"
    ("Money", "minorUnits")         -> "money_minor_units"
    ("Money", "isKnownCurrency")    -> "money_is_known_currency"
    ("Money", "setRate")            -> "money_set_rate"
    ("Money", "getRate")            -> "money_get_rate"
    ("Money", "hasRate")            -> "money_has_rate"
    ("Money", "clearRates")         -> "money_clear_rates"
    ("Money", "allocate")           -> "money_allocate"
```

- [ ] **Step 7: Test + build**

```bash
cd runtime-rust && cargo test --lib money
cabal build exe:sky 2>&1 | tail -3
```

- [ ] **Step 8: Commit**

```bash
git add runtime-rust/src/sky_runtime/money.rs \
        runtime-rust/src/sky_runtime/mod.rs \
        src/Sky/Generate/Rust/Project.hs \
        src/Sky/Generate/Rust/Builder.hs
git commit -m "feat(rust): Std.Money runtime — format/currency-table/rates/allocate (11 kernels)"
```

---

## Task 3: Sky.Core.Math (8 kernels)

**Files:**
- Create: `runtime-rust/src/sky_runtime/math.rs`
- Modify: `runtime-rust/src/sky_runtime/mod.rs`
- Modify: `src/Sky/Generate/Rust/Project.hs`
- Modify: `src/Sky/Generate/Rust/Builder.hs`

- [ ] **Step 1: Write `math.rs`**

```rust
//! Math kernels — Sky.Core.Math.

pub fn math_sqrt(x: f64) -> f64 { x.sqrt() }
pub fn math_pow(base: f64, exp: f64) -> f64 { base.powf(exp) }
pub fn math_round(x: f64) -> f64 { x.round() }
pub fn math_floor(x: f64) -> f64 { x.floor() }
pub fn math_ceil(x: f64) -> f64 { x.ceil() }
pub fn math_abs(x: f64) -> f64 { x.abs() }
pub fn math_min(a: f64, b: f64) -> f64 { a.min(b) }
pub fn math_max(a: f64, b: f64) -> f64 { a.max(b) }

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn test_math_sqrt() { assert_eq!(math_sqrt(9.0), 3.0); }
    #[test] fn test_math_pow() { assert_eq!(math_pow(2.0, 10.0), 1024.0); }
    #[test] fn test_math_round() { assert_eq!(math_round(0.5), 1.0); assert_eq!(math_round(-0.5), -1.0); }
    #[test] fn test_math_abs() { assert_eq!(math_abs(-3.0), 3.0); }
    #[test] fn test_math_min_max() { assert_eq!(math_min(3.0, 5.0), 3.0); assert_eq!(math_max(3.0, 5.0), 5.0); }
}
```

- [ ] **Step 2: Declare in mod.rs + Project.hs + add kernelToRust arms.**

Arms:
```haskell
    ("Math", "sqrt")  -> "math_sqrt"
    ("Math", "pow")   -> "math_pow"
    ("Math", "round") -> "math_round"
    ("Math", "floor") -> "math_floor"
    ("Math", "ceil")  -> "math_ceil"
    ("Math", "abs")   -> "math_abs"
    ("Math", "min")   -> "math_min"
    ("Math", "max")   -> "math_max"
```

- [ ] **Step 3: Test + build + commit**

```bash
cd runtime-rust && cargo test --lib math
cabal build exe:sky 2>&1 | tail -3
git add runtime-rust/src/sky_runtime/{math.rs,mod.rs} src/Sky/Generate/Rust/{Project.hs,Builder.hs}
git commit -m "feat(rust): Sky.Core.Math kernels — sqrt/pow/round/floor/ceil/abs/min/max (8 kernels)"
```

---

## Task 4: Std.Time advanced (7 kernels)

**Files:**
- Modify: `runtime-rust/src/sky_runtime/time.rs` (extend)
- Modify: `src/Sky/Generate/Rust/Builder.hs`

- [ ] **Step 1: Append 7 kernels to `time.rs`** under the existing chrono-based section:

```rust
pub fn time_diff_seconds(later_ms: i64, earlier_ms: i64) -> i64 { (later_ms - earlier_ms) / 1_000 }
pub fn time_diff_minutes(later_ms: i64, earlier_ms: i64) -> i64 { (later_ms - earlier_ms) / 60_000 }
pub fn time_diff_hours(later_ms: i64, earlier_ms: i64) -> i64 { (later_ms - earlier_ms) / 3_600_000 }
pub fn time_diff_days(later_ms: i64, earlier_ms: i64) -> i64 { (later_ms - earlier_ms) / 86_400_000 }

pub fn time_from_parts(y: i64, m: i64, d: i64, h: i64, mi: i64, s: i64, ms: i64) -> i64 {
    use chrono::{NaiveDate, TimeZone, Utc};
    NaiveDate::from_ymd_opt(y as i32, m as u32, d as u32)
        .and_then(|d| d.and_hms_milli_opt(h as u32, mi as u32, s as u32, ms as u32))
        .map(|naive| Utc.from_utc_datetime(&naive).timestamp_millis())
        .unwrap_or(0)
}

pub fn time_zone_offset(zone_name: String, ms: i64) -> i64 {
    use chrono::{DateTime, TimeZone, Utc};
    use chrono_tz::Tz;
    let utc: DateTime<Utc> = match Utc.timestamp_millis_opt(ms).single() { Some(t) => t, None => return 0 };
    match zone_name.parse::<Tz>() {
        Ok(tz) => tz.from_utc_datetime(&utc.naive_utc()).offset().fix().local_minus_utc() as i64,
        Err(_) => 0,
    }
}

pub fn time_zone_name(zone_name: String, ms: i64) -> String {
    use chrono::{DateTime, TimeZone, Utc};
    use chrono_tz::Tz;
    let utc: DateTime<Utc> = match Utc.timestamp_millis_opt(ms).single() { Some(t) => t, None => return zone_name.clone() };
    match zone_name.parse::<Tz>() {
        Ok(tz) => tz.from_utc_datetime(&utc.naive_utc()).format("%Z").to_string(),
        Err(_) => zone_name,
    }
}
```

If `chrono::Offset::fix` / `local_minus_utc` aren't exact matches, replace with a working chrono API. Test will confirm.

- [ ] **Step 2: Tests**

```rust
#[test] fn test_time_diff_seconds() { assert_eq!(time_diff_seconds(5_500, 3_000), 2); }
#[test] fn test_time_diff_days() { assert_eq!(time_diff_days(86_400_000, 0), 1); }
#[test] fn test_time_from_parts_epoch() { assert_eq!(time_from_parts(1970, 1, 1, 0, 0, 0, 0), 0); }
#[test] fn test_time_zone_offset_utc() { assert_eq!(time_zone_offset("UTC".into(), 0), 0); }
#[test] fn test_time_zone_offset_ny() {
    // America/New_York is UTC-5 in winter (Jan 1)
    assert_eq!(time_zone_offset("America/New_York".into(), 0), -5 * 3600);
}
```

- [ ] **Step 3: kernelToRust arms**

```haskell
    ("Time", "diffSeconds")  -> "time_diff_seconds"
    ("Time", "diffMinutes")  -> "time_diff_minutes"
    ("Time", "diffHours")    -> "time_diff_hours"
    ("Time", "diffDays")     -> "time_diff_days"
    ("Time", "fromParts")    -> "time_from_parts"
    ("Time", "zoneOffset")   -> "time_zone_offset"
    ("Time", "zoneName")     -> "time_zone_name"
```

- [ ] **Step 4: Test + build + commit**

```bash
cd runtime-rust && cargo test --lib time
cabal build exe:sky 2>&1 | tail -3
git add runtime-rust/src/sky_runtime/time.rs src/Sky/Generate/Rust/Builder.hs
git commit -m "feat(rust): Std.Time advanced — diff/fromParts/zone kernels (7 kernels)"
```

---

## Task 5: Sky.Core.Dict (6 kernels)

**Files:**
- Create: `runtime-rust/src/sky_runtime/dict.rs`
- Modify: `runtime-rust/src/sky_runtime/mod.rs`, `Project.hs`, `Builder.hs`

- [ ] **Step 1: Write `dict.rs`**

```rust
//! Dict kernels over std::collections::HashMap<String, T>.
//! Sky's Dict is keyed on String per Limitation #5 — non-string keys
//! silently route through string formatting.

use super::SkyMaybe;
use std::collections::HashMap;

pub type SkyDict<T> = HashMap<String, T>;

pub fn dict_empty<T>() -> SkyDict<T> { HashMap::new() }

pub fn dict_insert<T: Clone>(k: String, v: T, d: SkyDict<T>) -> SkyDict<T> {
    let mut d = d;
    d.insert(k, v);
    d
}

pub fn dict_get<T: Clone>(k: String, d: SkyDict<T>) -> SkyMaybe<T> {
    match d.get(&k) {
        Some(v) => SkyMaybe::Just(v.clone()),
        None    => SkyMaybe::Nothing,
    }
}

pub fn dict_keys<T>(d: SkyDict<T>) -> Vec<String> {
    let mut keys: Vec<String> = d.into_keys().collect();
    keys.sort();
    keys
}

pub fn dict_remove<T: Clone>(k: String, d: SkyDict<T>) -> SkyDict<T> {
    let mut d = d;
    d.remove(&k);
    d
}

pub fn dict_member<T>(k: String, d: SkyDict<T>) -> bool {
    d.contains_key(&k)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_dict_insert_get() {
        let d: SkyDict<i64> = dict_empty();
        let d = dict_insert("a".into(), 1, d);
        match dict_get("a".into(), d) {
            SkyMaybe::Just(v) => assert_eq!(v, 1),
            SkyMaybe::Nothing => panic!("missing"),
        }
    }

    #[test]
    fn test_dict_keys_sorted() {
        let mut d = dict_empty();
        d = dict_insert("c".into(), 3, d);
        d = dict_insert("a".into(), 1, d);
        d = dict_insert("b".into(), 2, d);
        assert_eq!(dict_keys(d), vec!["a", "b", "c"]);
    }

    #[test]
    fn test_dict_remove_member() {
        let mut d = dict_empty();
        d = dict_insert("x".into(), 10, d);
        assert!(dict_member("x".into(), d.clone()));
        let d = dict_remove("x".into(), d);
        assert!(!dict_member("x".into(), d));
    }
}
```

- [ ] **Step 2: kernelToRust arms**

```haskell
    ("Dict", "empty")  -> "dict_empty"
    ("Dict", "insert") -> "dict_insert"
    ("Dict", "get")    -> "dict_get"
    ("Dict", "keys")   -> "dict_keys"
    ("Dict", "remove") -> "dict_remove"
    ("Dict", "member") -> "dict_member"
```

- [ ] **Step 3: Declare module in mod.rs + Project.hs + Test + Build + Commit**

```bash
cd runtime-rust && cargo test --lib dict
cabal build exe:sky 2>&1 | tail -3
git add runtime-rust/src/sky_runtime/{dict.rs,mod.rs} src/Sky/Generate/Rust/{Project.hs,Builder.hs}
git commit -m "feat(rust): Sky.Core.Dict kernels — HashMap-backed empty/get/insert/keys/remove/member (6 kernels)"
```

---

## Task 6: Sky.Core.String additions (4 kernels)

**Files:**
- Create: `runtime-rust/src/sky_runtime/string.rs`
- Modify: `runtime-rust/src/sky_runtime/mod.rs`, `Project.hs`, `Builder.hs`

- [ ] **Step 1: Write `string.rs`**

```rust
//! String kernels (Sky.Core.String additions beyond what core.rs already provides).

pub fn string_replace(from: String, to: String, s: String) -> String {
    s.replace(&from, &to)
}

pub fn string_starts_with(prefix: String, s: String) -> bool {
    s.starts_with(&prefix)
}

pub fn string_ends_with(suffix: String, s: String) -> bool {
    s.ends_with(&suffix)
}

pub fn string_repeat(n: i64, s: String) -> String {
    if n <= 0 { String::new() } else { s.repeat(n as usize) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test] fn test_string_replace() { assert_eq!(string_replace("foo".into(), "bar".into(), "foofoo".into()), "barbar"); }
    #[test] fn test_string_starts_with() { assert!(string_starts_with("he".into(), "hello".into())); }
    #[test] fn test_string_ends_with() { assert!(string_ends_with("lo".into(), "hello".into())); }
    #[test] fn test_string_repeat() { assert_eq!(string_repeat(3, "ab".into()), "ababab"); }
    #[test] fn test_string_repeat_zero() { assert_eq!(string_repeat(0, "ab".into()), ""); }
}
```

- [ ] **Step 2: kernelToRust arms**

```haskell
    ("String", "replace")    -> "string_replace"
    ("String", "startsWith") -> "string_starts_with"
    ("String", "endsWith")   -> "string_ends_with"
    ("String", "repeat")     -> "string_repeat"
```

- [ ] **Step 3: Declare + Test + Build + Commit**

```bash
cd runtime-rust && cargo test --lib string
cabal build exe:sky 2>&1 | tail -3
git add runtime-rust/src/sky_runtime/{string.rs,mod.rs} src/Sky/Generate/Rust/{Project.hs,Builder.hs}
git commit -m "feat(rust): Sky.Core.String additions — replace/startsWith/endsWith/repeat (4 kernels)"
```

---

## Task 7: Sky.Core.Basics + List (3 kernels)

**Files:**
- Create: `runtime-rust/src/sky_runtime/basics.rs`
- Create: `runtime-rust/src/sky_runtime/list.rs`
- Modify: `runtime-rust/src/sky_runtime/mod.rs`, `Project.hs`, `Builder.hs`

- [ ] **Step 1: Write `basics.rs`**

```rust
//! Basics kernels — overflow-safe mod + error formatting.

use super::SkyCoreErrorError;

pub fn basics_mod_by(divisor: i64, dividend: i64) -> i64 {
    if divisor == 0 { 0 } else {
        let r = dividend % divisor;
        // Sky's modBy returns a result with same sign as divisor (Elm semantics).
        if (r < 0) != (divisor < 0) && r != 0 { r + divisor } else { r }
    }
}

pub fn basics_error_to_string(e: SkyCoreErrorError) -> String {
    // Mirrors Sky.Core.Error.toString — pulls the message field.
    match e {
        SkyCoreErrorError::Error(_, info) => info.message,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test] fn test_mod_by_positive() { assert_eq!(basics_mod_by(3, 10), 1); }
    #[test] fn test_mod_by_negative_dividend() { assert_eq!(basics_mod_by(3, -1), 2); }
    #[test] fn test_mod_by_zero_divisor() { assert_eq!(basics_mod_by(0, 5), 0); }
}
```

Note: confirm `SkyCoreErrorError`'s field shape by reading the generated
type from a working build. If the field name is `_message` / different,
adjust the access.

- [ ] **Step 2: Write `list.rs`**

```rust
//! List kernels — additions beyond what core.rs already provides.

use super::SkyMaybe;

pub fn list_filter_map<A, B>(f: impl Fn(A) -> SkyMaybe<B>, xs: Vec<A>) -> Vec<B> {
    xs.into_iter().filter_map(|x| match f(x) {
        SkyMaybe::Just(v)  => Some(v),
        SkyMaybe::Nothing  => None,
    }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_filter_map_doubles_evens() {
        let xs = vec![1i64, 2, 3, 4];
        let result = list_filter_map(|x| {
            if x % 2 == 0 { SkyMaybe::Just(x * 2) } else { SkyMaybe::Nothing }
        }, xs);
        assert_eq!(result, vec![4i64, 8]);
    }
}
```

- [ ] **Step 3: kernelToRust arms**

```haskell
    ("Basics", "modBy")         -> "basics_mod_by"
    ("Basics", "errorToString") -> "basics_error_to_string"
    ("List",   "filterMap")     -> "list_filter_map"
```

- [ ] **Step 4: Declare modules in mod.rs + Project.hs + Test + Build + Commit**

```bash
cd runtime-rust && cargo test --lib
cabal build exe:sky 2>&1 | tail -3
git add runtime-rust/src/sky_runtime/{basics.rs,list.rs,mod.rs} src/Sky/Generate/Rust/{Project.hs,Builder.hs}
git commit -m "feat(rust): Sky.Core.Basics + List — modBy/errorToString/filterMap (3 kernels)"
```

---

## Task 8: Rebuild compiler + regression sweep

**Files:** None modified — verification only.

- [ ] **Step 1: Install fresh binary**

```bash
cabal install --overwrite-policy=always --installdir=./sky-out --install-method=copy exe:sky
cp -f dist-newstyle/build/x86_64-linux/ghc-9.6.7/sky-compiler-0.0.0/x/sky/build/sky/sky sky-out/sky
sky-out/sky --version  # sky dev
```

- [ ] **Step 2: 16-example Rust regression**

```bash
PASS=0; FAIL=0
for d in examples/rust/*/; do
    name=$(basename "$d")
    (cd "$d" && rm -rf sky-out .skycache .skydeps && ../../../sky-out/sky build src/Main.sky) >/dev/null 2>&1 \
        && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: $name"; }
done
echo "Build: $PASS pass / $FAIL fail"
```
Expected: 16/0.

- [ ] **Step 3: Run each binary**

```bash
for d in examples/rust/*/; do
    bin="$d/sky-out/Rust/target/debug/sky-app"
    [ -x "$bin" ] && timeout 10s "$bin" 2>&1 | head -1 | sed "s|^|$(basename $d): |"
done
```

- [ ] **Step 4: Go regression**

```bash
(cd examples/01-hello-world && rm -rf sky-out .skycache && ../../sky-out/sky build src/Main.sky 2>&1 | tail -3)
```

- [ ] **Step 5: Targeted cabal test**

```bash
cabal test --test-options='--match "FfiGen" --match "Toml" --match "Kernel"' 2>&1 | tail -5
```

Verification only — no commit.

---

## Task 9: Headline gate — `examples/00-standard-libs` on target=rust

**Files:**
- Modify (temporarily): `examples/00-standard-libs/sky.toml`
- Modify: `docs/runtime-rust/sub-A-stdlib-parity-result.md`

- [ ] **Step 1: target=rust build + run**

```bash
cp examples/00-standard-libs/sky.toml /tmp/sky.toml.bak
printf '\ntarget = "rust"\n' >> examples/00-standard-libs/sky.toml
cd examples/00-standard-libs && rm -rf sky-out .skycache
../../sky-out/sky run src/Main.sky 2>&1 | tee /tmp/sub-A-rust-result.txt | tail -10
cd ../..
```
Expected: `120 passed, 0 failed (120 total)`.

If anything fails: read the failure(s), determine if they're runtime
behavioural mismatches with Go (port them) OR codegen-shape issues
(document + propose follow-up).

- [ ] **Step 2: Restore sky.toml**

```bash
cp /tmp/sky.toml.bak examples/00-standard-libs/sky.toml
rm -rf examples/00-standard-libs/sky-out examples/00-standard-libs/.skycache
git diff --stat examples/00-standard-libs/sky.toml  # should be empty
```

- [ ] **Step 3: Update status doc**

Rewrite `docs/runtime-rust/sub-A-stdlib-parity-result.md`'s "Headline gate
result" section to record the 120/120 outcome (or a documented partial
result + remaining issues).

- [ ] **Step 4: Commit**

```bash
git add docs/runtime-rust/sub-A-stdlib-parity-result.md
git commit -m "docs(rust): sub-A headline gate met — 120/120 on target=rust"
```

---

## Task 10: Background hygiene + report

- [ ] **Step 1: Cleanup**

```bash
ps -u $USER -o pid,command | awk '/while pgrep|until ! pgrep/ && /\/bin\/zsh -c/ {print $1}' | xargs -n1 kill -9 2>/dev/null
ps -u $USER -o pid,ppid,command | awk '$3 == "sleep" && $2 != 1 {print $1}' | xargs -n1 kill -9 2>/dev/null
pkill -f "examples/.*/sky-out/app" 2>/dev/null
pgrep -f mem-guard.sh >/dev/null || (nohup ./scripts/mem-guard.sh > /tmp/mem-guard.out 2>&1 & disown)
```

- [ ] **Step 2: Report — count commits in this sub-plan + show headline-gate result**

```bash
git log --oneline 1c5a1596..HEAD
```

---

## Self-review (per writing-plans skill)

**Spec coverage:**
- Spec §4 (54 kernels) → Tasks 1-7 cover all 54 ✅
- Spec §5 (single-file module growth) → file table at top of plan ✅
- Spec §7 (verification: unit tests, regression sweep, headline gate, status doc) → Tasks 1-7 each have tests; Task 8 regression; Task 9 headline gate + doc ✅
- Spec §10 (cross-backend safety — only Rust files + Builder.hs/Project.hs arms) → file table enforces ✅

**Placeholder scan:**
- Task 2's `money_allocate` implementation is described but not fully written — flagged as the highest-complexity port; implementer reads Go's `RegisterPure("Money_allocate", …)` and the Go test, mirrors. Acceptable because the algorithm is non-trivial enough that pre-writing the Rust would diverge from Go's edge cases.
- Task 7's `SkyCoreErrorError` field name is flagged as needing verification — implementer reads the generated type from a working build.

**Type consistency:**
- `Decimal` is the runtime newtype `pub struct Decimal(rust_decimal::Decimal)` shipped in sub-A.6 — used consistently across decimal.rs and money.rs ✅
- `SkyMaybe<T>` / `SkyResult<E, T>` already exist in sub-A's runtime — used consistently ✅
- `RD::ZERO` / `RD::ONE_HUNDRED` assumes `use rust_decimal::Decimal as RD` is in scope — already in decimal.rs ✅

---

## Execution Handoff

Plan complete at `docs/superpowers/plans/2026-05-29-sub-A8-runtime-kernel-coverage.md`.

The user previously chose "Autonomous, no checkpoints" for the codegen-completion plan. Same shape applies — execute Tasks 0-10 end-to-end, stop only on hard blockers, report at the end.
