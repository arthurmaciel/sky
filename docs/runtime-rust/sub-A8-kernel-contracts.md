# Sub-A.8 — kernel contracts (Sky + Go reference for the 54 missing kernels)

Source for the implementation plan
`docs/superpowers/plans/2026-05-29-sub-A8-runtime-kernel-coverage.md`. Each
kernel's Sky signature, Go reference, and Rust target signature.

## Key insight from investigation

Sky has two `Ffi` dispatch paths that the codegen-completion plan unified:

1. **`Ffi.callPure "Name" [args]`** — used by `Std.Decimal` / `Std.Money` /
   `Std.Time` wrappers. The Rust codegen peephole rewrites these to
   direct kernel calls at compile time.
2. **`Ffi.kernel "Name"`** — used by `Sky.Core.Math` / `Sky.Core.String` /
   `Sky.Core.Basics` / `Sky.Core.Dict` (via Canonicalise/Module.hs's
   kernel registry) wrappers. The Sky compiler's Stage-4 alias mechanism
   resolves these to direct kernel calls during canonicalisation.

**Both paths bottom out at `kernelToRust mod name`.** So the runtime
side is identical regardless of which dispatch the Sky source uses — what
matters is that `<rustFnName>` exists in `sky_runtime/`.

## Std.Decimal completion (15 kernels)

Sky source: `sky-stdlib/Std/Decimal.sky`. All entries dispatch via
`Ffi.callPure "Decimal_<name>" […]` and need the matching Rust kernel.

| Sky entry | Sky signature | Rust target |
|---|---|---|
| `eq a b` | `Decimal -> Decimal -> Bool` | `pub fn decimal_eq(a: Decimal, b: Decimal) -> bool` |
| `neq a b` | `Decimal -> Decimal -> Bool` | `pub fn decimal_neq(a: Decimal, b: Decimal) -> bool` |
| `lt a b` | `Decimal -> Decimal -> Bool` | `pub fn decimal_lt(a: Decimal, b: Decimal) -> bool` |
| `lte a b` | `Decimal -> Decimal -> Bool` | `pub fn decimal_lte(a: Decimal, b: Decimal) -> bool` |
| `gt a b` | `Decimal -> Decimal -> Bool` | `pub fn decimal_gt(a: Decimal, b: Decimal) -> bool` |
| `gte a b` | `Decimal -> Decimal -> Bool` | `pub fn decimal_gte(a: Decimal, b: Decimal) -> bool` |
| `min a b` | `Decimal -> Decimal -> Decimal` | `pub fn decimal_min(a: Decimal, b: Decimal) -> Decimal` |
| `max a b` | `Decimal -> Decimal -> Decimal` | `pub fn decimal_max(a: Decimal, b: Decimal) -> Decimal` |
| `isZero d` | `Decimal -> Bool` | `pub fn decimal_is_zero(d: Decimal) -> bool` |
| `isPositive d` | `Decimal -> Bool` | `pub fn decimal_is_positive(d: Decimal) -> bool` |
| `isNegative d` | `Decimal -> Bool` | `pub fn decimal_is_negative(d: Decimal) -> bool` |
| `percentOf pct of_` | `Decimal -> Decimal -> Decimal` | `pub fn decimal_percent_of(pct: Decimal, of_: Decimal) -> Decimal` |
| `addPercent pct base` | `Decimal -> Decimal -> Decimal` | `pub fn decimal_add_percent(pct: Decimal, base: Decimal) -> Decimal` |
| `subPercent pct base` | `Decimal -> Decimal -> Decimal` | `pub fn decimal_sub_percent(pct: Decimal, base: Decimal) -> Decimal` |
| `formatWith places dec grp d` | `Int -> String -> String -> Decimal -> String` | `pub fn decimal_format_with(places: i64, dec: String, grp: String, d: Decimal) -> String` |

Go reference (e.g.): `RegisterPure("Decimal_lt", … decimalUnbox(args[0]).LessThan(decimalUnbox(args[1])))`. The Rust impl is `a.0 < b.0` since `Decimal` is `pub struct Decimal(rust_decimal::Decimal)`.

## Std.Money (11 kernels)

Sky source: `sky-stdlib/Std/Money.sky`. The `Money` Sky type carries a
`Decimal` amount + a typed `Currency` ADT; runtime works in ISO codes
(strings) and `Decimal`s.

| Sky entry | Sky signature (at the Ffi boundary) | Rust target |
|---|---|---|
| `currencyName c` | `String -> String` | `pub fn money_currency_name(code: String) -> String` |
| `symbol c` | `String -> String` | `pub fn money_symbol(code: String) -> String` |
| `minorUnits c` | `String -> Int` | `pub fn money_minor_units(code: String) -> i64` |
| `isKnownCode code` | `String -> Bool` | `pub fn money_is_known_currency(code: String) -> bool` |
| `format m` | `String -> Decimal -> String` (code + amount) | `pub fn money_format(code: String, amount: Decimal) -> String` |
| `formatWithCode m` | `String -> Decimal -> String` | `pub fn money_format_with_code(code: String, amount: Decimal) -> String` |
| `setRate from to rate` | `String -> String -> Decimal -> ()` | `pub fn money_set_rate(from: String, to: String, rate: Decimal) -> ()` |
| `getRate from to` | `String -> String -> Maybe Decimal` | `pub fn money_get_rate(from: String, to: String) -> SkyMaybe<Decimal>` |
| `hasRate from to` | `String -> String -> Bool` | `pub fn money_has_rate(from: String, to: String) -> bool` |
| `clearRates _` | `() -> ()` | `pub fn money_clear_rates(_: ()) -> ()` |
| `allocate places parts amount` | `Int -> Int -> Decimal -> List Decimal` | `pub fn money_allocate(places: i64, parts: i64, amount: Decimal) -> Vec<Decimal>` |

### Currency table (from `runtime-go/rt/money_kernel.go`)

57 entries spanning major fiat (USD, EUR, GBP, JPY, …), Latin America,
Asia, Middle East, Africa, EU members, BTC. Rust port: same data as a
`match code { … }` (simpler than bringing in `phf`). Fallback: `(2, code, code)`.

### `money_allocate` algorithm

```go
totalMinor := amount.Shift(places).Truncate(0)
base := totalMinor.Div(parts).Truncate(0)
remainder := totalMinor.Sub(base.Mul(parts))
// First `remainder` slots get base+1, rest get base.
// Shift back to major units.
```

Rust port mirrors using `rust_decimal::Decimal::round_dp` / arithmetic on
`Decimal` values directly.

### `money_format` semantics

Go: `"-" + info.Symbol + Abs(d).StringFixed(info.Minor)` for negative,
`info.Symbol + d.StringFixed(info.Minor)` for positive. Rust port mirrors.

### `money_format_with_code`

Go: `d.StringFixed(info.Minor) + " " + code`. Rust port mirrors.

## Sky.Core.Math (8 kernels)

Sky source: `sky-stdlib/Sky/Core/Math.sky`. All `Ffi.kernel "Math_<name>"` —
direct kernel binding.

| Sky entry | Sky signature | Rust target |
|---|---|---|
| `sqrt` | `Float -> Float` | `pub fn math_sqrt(x: f64) -> f64` |
| `pow` | `Float -> Float -> Float` | `pub fn math_pow(b: f64, e: f64) -> f64` |
| `round` | `Float -> Int` (or Float per Sky src) | `pub fn math_round(x: f64) -> f64` |
| `floor` | `Float -> Int` (or Float) | `pub fn math_floor(x: f64) -> f64` |
| `ceil` | `Float -> Int` (or Float) | `pub fn math_ceil(x: f64) -> f64` |
| `abs` | `Int -> Int` | `pub fn math_abs(x: i64) -> i64` |
| `min` | `a -> a -> a` (polymorphic) | (specialised per call site — see note) |
| `max` | `a -> a -> a` (polymorphic) | (specialised per call site — see note) |

Note: `Math.min/max` are polymorphic in Sky. The codegen produces
monomorphised call sites — `math_min` may be called with concrete i64 or
f64. For sub-A.8 keep it simple: implement `math_min(a: i64, b: i64) -> i64`
and `math_max(a: i64, b: i64) -> i64`. If the headline gate hits a
floating-point call site, add a second monomorphic version. Defer
generics until needed.

## Std.Time advanced (7 kernels)

Sky source: `sky-stdlib/Std/Time.sky`. Mix of `Ffi.callPure`.

| Sky entry | Sky signature | Rust target |
|---|---|---|
| `diffSeconds later earlier` | `Int -> Int -> Int` | `pub fn time_diff_seconds(later_ms: i64, earlier_ms: i64) -> i64` |
| `diffMinutes …` | same | `pub fn time_diff_minutes(later_ms: i64, earlier_ms: i64) -> i64` |
| `diffHours …` | same | `pub fn time_diff_hours(later_ms: i64, earlier_ms: i64) -> i64` |
| `diffDays …` | same | `pub fn time_diff_days(later_ms: i64, earlier_ms: i64) -> i64` |
| `fromParts y mo d h mi s ms` | `Int×7 -> Int` (epoch ms) | `pub fn time_from_parts(y: i64, m: i64, d: i64, h: i64, mi: i64, s: i64, ms: i64) -> i64` |
| `zoneOffset zone ms` | `String -> Int -> Int` | `pub fn time_zone_offset(zone: String, ms: i64) -> i64` |
| `zoneName zone ms` | `String -> Int -> String` | `pub fn time_zone_name(zone: String, ms: i64) -> String` |

`chrono` + `chrono-tz` already in deps from sub-A.5. Implementations:
- `time_diff_*`: integer arithmetic on the ms difference.
- `time_from_parts`: `NaiveDate::from_ymd_opt(...).and_then(and_hms_milli_opt(...))` → `.and_utc().timestamp_millis()`.
- `time_zone_offset`: parse `Tz`, get UTC-offset in seconds.
- `time_zone_name`: parse `Tz`, get abbreviation via `.format("%Z")`.

## Sky.Core.Dict (6 kernels)

Type signatures (from `src/Sky/Type/Constrain/Expression.hs`):

| Sky entry | Sky signature | Rust target |
|---|---|---|
| `Dict.empty` | `Dict k v` | `pub fn dict_empty<V>() -> HashMap<String, V>` |
| `Dict.insert` | `k -> v -> Dict k v -> Dict k v` | `pub fn dict_insert<V: Clone>(k: String, v: V, d: HashMap<String, V>) -> HashMap<String, V>` |
| `Dict.get` | `k -> Dict k v -> Maybe v` | `pub fn dict_get<V: Clone>(k: String, d: HashMap<String, V>) -> SkyMaybe<V>` |
| `Dict.remove` | `k -> Dict k v -> Dict k v` | `pub fn dict_remove<V: Clone>(k: String, d: HashMap<String, V>) -> HashMap<String, V>` |
| `Dict.keys` | `Dict k v -> List k` | `pub fn dict_keys<V>(d: HashMap<String, V>) -> Vec<String>` |
| `Dict.member` | `k -> Dict k v -> Bool` | `pub fn dict_member<V>(k: String, d: HashMap<String, V>) -> bool` |

Per CLAUDE.md Limitation #5: Sky's Dict is keyed on `String` at runtime;
Sky type-system claims `k v` but the Go runtime coerces via reflection
to `String`. Rust port specializes to `String`-keyed (no polymorphism on
the key) — matches the runtime contract.

`dict_keys` returns sorted keys (matches Go's deterministic-iteration
convention for the `_fieldIndex`-style test cases).

## Sky.Core.String additions (4 kernels)

Sky source: `sky-stdlib/Sky/Core/String.sky`.

| Sky entry | Sky signature | Rust target |
|---|---|---|
| `replace old new s` | `String -> String -> String -> String` | `pub fn string_replace(old: String, new_: String, s: String) -> String` |
| `startsWith prefix s` | `String -> String -> Bool` | `pub fn string_starts_with(prefix: String, s: String) -> bool` |
| `endsWith suffix s` | `String -> String -> Bool` | `pub fn string_ends_with(suffix: String, s: String) -> bool` |
| `repeat n s` | `Int -> String -> String` | `pub fn string_repeat(n: i64, s: String) -> String` |

Note arg order for `string_replace`: Sky source is `replace old new s` but
the codegen-emitted call passes args in that order, so the Rust function
parameter order must match the Sky-source declaration order.

## Sky.Core.Basics (2 kernels)

| Sky entry | Sky signature | Rust target |
|---|---|---|
| `modBy divisor x` | `Int -> Int -> Int` | `pub fn basics_mod_by(divisor: i64, x: i64) -> i64` |
| `errorToString e` | `Error -> String` | `pub fn basics_error_to_string(e: SkyCoreErrorError) -> String` |

`Basics.modBy` semantics: Elm-style "remainder with same sign as divisor."
`basics_error_to_string` calls `.message` on the Error's info field.

## Sky.Core.List addition (1 kernel)

| Sky entry | Sky signature | Rust target |
|---|---|---|
| `filterMap f xs` | `(a -> Maybe b) -> List a -> List b` | `pub fn list_filter_map<A, B>(f: impl Fn(A) -> SkyMaybe<B>, xs: Vec<A>) -> Vec<B>` |

Standard filter-map idiom over `SkyMaybe<B>`.

## kernelToRust arms summary

All arms get added to `src/Sky/Generate/Rust/Builder.hs`:

```haskell
-- Std.Decimal completion (T1)
("Decimal", "eq")              -> "decimal_eq"
... (15 entries — see plan T1)

-- Std.Money (T2)
("Money", "format")            -> "money_format"
... (11 entries — see plan T2)

-- Sky.Core.Math (T3)
("Math", "sqrt")               -> "math_sqrt"
... (8 entries — see plan T3)

-- Std.Time advanced (T4)
("Time", "diffSeconds")        -> "time_diff_seconds"
... (7 entries — see plan T4)

-- Sky.Core.Dict (T5)
("Dict", "empty")              -> "dict_empty"
... (6 entries — see plan T5)

-- Sky.Core.String additions (T6)
("String", "replace")          -> "string_replace"
... (4 entries — see plan T6)

-- Sky.Core.Basics + List (T7)
("Basics", "modBy")            -> "basics_mod_by"
("Basics", "errorToString")    -> "basics_error_to_string"
("List",   "filterMap")        -> "list_filter_map"
```

Plus the same `("Sky.Core.X", …)` mirror arms where the codegen emits the
fully-qualified Sky module name (sub-A's existing pattern).
