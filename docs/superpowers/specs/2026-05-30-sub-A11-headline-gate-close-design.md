# Sub-A.11 — Close the headline gate — Design

**Date:** 2026-05-30
**Status:** Approved (brainstorming) — ready for implementation plan
**Scope:** Close all 17 remaining cargo errors on `examples/00-standard-libs` target=rust; achieve `120 passed, 0 failed`.
**Branch:** `feat/runtime-rust`
**Builds on:** Sub-A.10 commits (`4221a1eb..d7b2988f`).

---

## 1. Context

After sub-A.10, error count is **17** (-93% from the 232 baseline). The
JsonDecoder pipeline turned out NOT to need an architectural reshape —
it's the same zero-arg detection bug as `dict_empty` / `math_pi`, applied
to `json_dec_int` / `json_dec_string` / etc. (which return `Decoder<E, T>`
values when called with `()`).

The remaining errors split into three groups:

### Group A — Zero-arg kernels on "then" branch (closes ~7 errors)

`json_dec_int` / `json_dec_string` / etc. are declared in Sky as zero-arg
bindings (`int = Ffi.kernel "JsonDec_int"`). The runtime functions are
`pub fn json_dec_int<E>() -> Decoder<E, i64>` — called as `json_dec_int()`
to get the Decoder.

The codegen at `Can.VarTopLevel` "then" branch (when `fnName != kernelName`)
emits the bare kernel name without `()`. The "else" branch has the
`ecZeroArgDefs` check; the "then" branch doesn't.

**Fix:** Add a separate `kernelsZeroArg :: Set String` (keyed by RUST
kernel name, not Sky module/name) and check it in the "then" branch:

```haskell
kernelsZeroArg :: Set.Set String
kernelsZeroArg = Set.fromList
    [ "json_dec_string", "json_dec_int", "json_dec_float"
    , "json_dec_bool", "json_dec_null"
    , "dict_empty"
    , "math_pi", "math_e"
    ]

-- Can.VarTopLevel arm "then" branch:
in if fnName /= kernelName && not ("ffi_kernel" `isPrefixOf` kernelName)
   then let parenSuffix = if Set.member kernelName kernelsZeroArg then "()" else ""
        in pinE kernelName ++ parenSuffix
   else ...
```

Also expand `kernelsNeedingErrorPin` with `json_dec_*` so the turbofish
fires (the runtime is generic over `E: From<String>`):

```haskell
kernelsNeedingErrorPin = Set.fromList
    [ "base64_decode", "url_decode", "encoding_hex_decode"
    , "json_dec_string", "json_dec_int", "json_dec_float"
    , "json_dec_bool", "json_dec_null", "json_dec_decode_string"
    , "json_dec_field", "json_dec_at"
    ]
```

The combination: `json_dec_field` emits as `json_dec_field::<SkyError, _>(name, json_dec_int::<SkyError>())` — both pinned.

### Group B — Runtime signature mismatches (3 errors)

| # | Issue | Fix |
|---|---|---|
| B1 | `decimal_format_with(thousandsSep, decimalSep, places, d)` (Sky source) vs `decimal_format_with(places, dec_sep, grp_sep, d)` (current runtime) | Swap runtime arg order to match Sky source |
| B2 | `money_clear_rates()` (zero-arg call from `Ffi.callPure "Money_clearRates" []`) vs runtime `money_clear_rates(_: ()) -> SkyResult<E, ()>` | Drop the `()` arg — Sky passes none |
| B3 | `time_from_parts(zone, y, m, d, h, mins, s)` (Sky 7-arg, zone first) vs runtime `time_from_parts(y, m, d, h, mi, s, ms)` (UTC 7-arg, no zone) | Rewrite runtime to take `zone` first; use chrono_tz for zoned epoch ms conversion |

All in `runtime-rust/src/sky_runtime/{decimal,money,time}.rs`.

### Group C — Inference + Error-cascade fixes (~7 errors)

| # | Issue | Fix |
|---|---|---|
| C1 | `dict_keys(dict_empty())` — V unconstrained on dict_empty | Group A's turbofish-or-default emits `dict_empty::<i64>()` (default i64). Or fix by adding `dict_empty` to a "default to i64 type-arg" set. |
| C2 | `sky_core_list_head(vec![])` — T0 unconstrained from empty Vec | Codegen detects empty Vec literal in monomorphic call site context; emits `Vec::<i64>::new()` as default. Or: split into helper that takes a phantom type. |
| C3 | `sky_core_maybe_map(\|x\| x * 2, SkyMaybe::Nothing)` — closure arg type ambiguous when Maybe is Nothing | Codegen-level: when Sky source `Maybe.map f Nothing`, infer x type from f's return + the Maybe phantom. Complex; simpler: the Sky source has annotations — use them. |
| C4 | `Error.toString e` returning String but used where SkyCoreErrorError expected | Sky source for `Error.unexpected : String -> Error` vs codegen confusion. Investigate. |
| C5 | `sky_core_result_map_error(closure)` — closure return type expected String, found SkyCoreErrorError | Same family as C4 — Sky source `mapError` body returns Error not String. |

C1+C2 are similar — add type-defaulting for unconstrained generic args.
C3-C5 need investigation; may resolve from cascade of other fixes.

## 2. Goal

After this work:
1. `examples/00-standard-libs` on `target=rust` compiles with **0 errors**.
2. Binary runs and prints `120 passed, 0 failed (120 total)` — matching `target=go`.
3. 16/16 `examples/rust/*` continue to build and run.
4. Go path byte-identical.

If C3-C5 turn out to need substantial codegen work, document and defer
those specific tests. The "headline gate" then says "118 passed / 2
skipped" with a clear note on the skipped tests.

## 3. Non-goals

- Architectural reshape of JsonDecoder (turned out unnecessary).
- New runtime kernels.
- Go path changes.

## 4. Design

### Sequence of fixes (in error-impact order)

1. **A — kernelsZeroArg + extended kernelsNeedingErrorPin** (~7 errors)
   - Add the set in Builder.hs
   - Apply at Can.VarTopLevel "then" branch
   - Extend kernelsNeedingErrorPin with json_dec_*

2. **B1 — decimal_format_with arg order** (1 error)
   - Edit `runtime-rust/src/sky_runtime/decimal.rs` to swap params

3. **B2 — money_clear_rates no-arg** (1 error)
   - Edit `runtime-rust/src/sky_runtime/money.rs` to drop the `()` param

4. **B3 — time_from_parts zone-first signature** (1 error)
   - Rewrite `runtime-rust/src/sky_runtime/time.rs::time_from_parts` to take `zone` first and compute zoned epoch ms via chrono-tz

5. **C1+C2 — type-default for unconstrained empty literals** (2-3 errors)
   - Detect `Vec::new()` / `HashMap::new()` in monomorphic call site with no constraint — emit turbofish `::<i64>` as default

6. **C3-C5 — Error/Result mapError + Maybe.map closure inference** (~3-4 errors)
   - Investigation needed. Each may be a separate small fix.

## 5. Verification

After each fix:
1. Cabal build + 01-rand smoke
2. 16-example sweep (must stay 16/16)
3. Error count snapshot (track reduction)
4. After all: full headline gate run — expect 0 errors + 120/120

## 6. Risks

| Risk | Mitigation |
|---|---|
| Group A's turbofish/zero-arg combination over-eager | Test against examples/rust/* sweep; back off any specific entry that breaks |
| Group B's signature changes break runtime unit tests | Update tests to match new sigs |
| Group C's empty-literal turbofish defaults to wrong type | i64 is safe because the test cases that hit this don't use the values; iteration cost is low |
| C3-C5 cascade into deeper codegen work | Document + defer those specific tests, ship 118/120 |

## 7. Out of scope

- Anything not in 00-standard-libs.
- Runtime unit-test refactors beyond what's needed for the new sigs.
