# Sub-A.10 — Codegen-shape cleanup to close the headline gate — Design

**Date:** 2026-05-30
**Status:** Approved (brainstorming) — ready for implementation plan
**Scope:** Six focused fixes targeting the remaining 36 cargo errors after sub-A.9.
**Branch:** `feat/runtime-rust`
**Builds on:** Sub-A.9 commits (`7498edf6..6f5f3d87`).

---

## 1. Context

After sub-A.9 closed the four high-impact codegen-shape bugs (B1 / B2 / B3 / B6),
`examples/00-standard-libs` on `target=rust` compiles down to **36 cargo
errors** (from 232 → 165 → 116 → 70 → 36 across four sub-plans). All remaining
errors are codegen-shape issues in narrow, well-understood paths — no further
runtime kernels needed.

This sub-plan addresses each remaining error class with a focused fix.

## 2. Goal

After this work:

1. `examples/00-standard-libs` on `target=rust` builds cleanly (cargo: 0 errors).
2. The binary runs and prints `120 passed, 0 failed (120 total)` — matching `target=go`.
3. 16/16 `examples/rust/*` continue to build and run.
4. Go path byte-identical.

If any subset doesn't close cleanly (e.g. the JsonDecoder pipeline turns out
to need an architectural redesign), document the boundary and defer to a
sub-A.11.

## 3. Verified error catalogue (post-sub-A.9)

| # | Class | Count | Root cause | Fix locus |
|---|---|---|---|---|
| C1 | `Sky.Core.Json.Encode.Value` aliases to `String` in placeholders | ~24 (Jwt cascade) | `ffiPlaceholder` synthesises `type SkyCoreJsonEncodeValue = String;` for any referenced-but-undefined type. The kernel returns `JsonVal`; mismatched call sites cascade. | `Builder.hs:ffiPlaceholder` + `runtimeOpaqueTypes` |
| C2 | `Std.Time` wrappers return `SkyResult<E, T>` but runtime returns bare `i64`/`String` | 3 | Runtime `time_from_parts/zone_offset/zone_name` return bare values; the Sky source signatures say `Result Error Int`. | `runtime-rust/src/sky_runtime/time.rs` — wrap returns in `SkyResult::Ok(...)` |
| C3 | `dict_empty` passed without `()` in user code | 5 (main.rs) | `Dict.empty` is `Ffi.kernel "Dict_empty"` — zero-arg. The Stage-4 alias path adds it as a zero-arg kernel ref. But `ecZeroArgDefs` lookup misses it because the kernel-side `("Dict", "empty")` isn't pre-registered. | Add to `zeroArgKernelDefs` in `Builder.hs` |
| C4 | `_: From<String>` ambiguity on `base64_decode` / `url_decode` / `encoding_hex_decode` | 4 (main.rs) | Runtime signatures `pub fn base64_decode<E: From<String>>(...)` are generic over E. Call sites don't have a constrained ok-slot to pin E. | Two options: monomorphise to `SkyError` in runtime, OR add turbofish at call sites. Spec prefers (a) — single arm change per kernel. |
| C5 | `CurrencyRaw(&str)` vs `String` in std_money | 1 | Codegen emits `StdMoneyCurrency::CurrencyRaw(other)` where `other: &str`; constructor takes `String`. | Codegen wildcard-pattern case-arm bug. Convert: `other => StdMoneyCurrency::CurrencyRaw(other.to_string())`. |
| C6 | `m.clone()` move out of `Fn` closure | 1 (std_money) | `std_money_allocate` body's nested `move \|d\| ... std_money_currency(m)` consumes `m` — but the closure is captured `Fn`, can't move. | Add another `.clone()` in the inner closure body. Codegen needs to detect this in the wrapper emit path. |
| C7 | JsonDecoder pipeline closure typing (E0283 + E0308) | ~10 | `Decoder<a>` codegen vs `Box<dyn Fn(&JsonVal) -> SkyResult<E, T>>` runtime. Decoder composition (`field "x" int`, `succeed f |= …`) produces nested types Rust can't infer. | Significant architectural reshape. **Defer to sub-A.11.** |

## 4. Design

### C1 — JsonEnc.Value → JsonVal via opaque-type registry

The infrastructure for runtime-backed opaque types already exists
(`runtimeOpaqueTypes` registry from sub-A's codegen-completion plan; entry for
`Std.Decimal.Decimal`). The hook fires inside `unionToRustTypeDef` — but
`Sky.Core.Json.Encode.Value` isn't a union (no `type Value = ...` declaration
in Sky source), so the union path never sees it. Instead, `ffiPlaceholder`
synthesises a `String` alias for any referenced-but-undefined type.

**Fix:** Extend `ffiPlaceholder` to consult `runtimeOpaqueTypes` (reverse-keyed
by the codegen name) and emit `pub use <rustPath> as <name>;` when matched.
Add the `JsonEnc.Value` entry to the registry.

```haskell
-- Builder.hs
runtimeOpaqueTypes :: Map.Map (String, String) String
runtimeOpaqueTypes = Map.fromList
    [ (("Std.Decimal", "Decimal"), "sky_runtime::Decimal")
    , (("Sky.Core.Json.Encode", "Value"), "sky_runtime::JsonVal")   -- new
    ]

ffiPlaceholder :: String -> String
ffiPlaceholder name =
    let reverseOpaque = Map.fromList
            [ (toCamelCase (modPrefix ++ "_" ++ ty), path)
            | ((mod, ty), path) <- Map.toList runtimeOpaqueTypes
            , let modPrefix = map (\c -> if c == '.' then '_' else c) mod
            ]
    in case Map.lookup name reverseOpaque of
        Just path -> "pub use " ++ path ++ " as " ++ name ++ ";"
        Nothing   -> "type " ++ name ++ " = String;"
```

### C2 — Std.Time return-type wrapping

Sky source:
```elm
fromParts : String -> Int -> Int -> Int -> Int -> Int -> Int -> Result Error Int
zoneOffset : String -> Int -> Result Error Int
zoneName : String -> Int -> Result Error String
```

Current runtime returns bare `i64` / `String`. Wrappers expect `SkyResult`.
Two fixes possible:
- (a) Wrap runtime returns in `SkyResult::Ok(...)` — never error.
- (b) Make runtime functions take an `E: From<String>` and return `SkyResult<E, T>` for forward error reporting (e.g. unknown timezone).

(b) is more faithful to Sky's Result type. Implementation:
```rust
pub fn time_zone_offset<E: From<String>>(zone_name: String, ms: i64) -> SkyResult<E, i64> {
    // ... existing logic ...
    match zone_name.parse::<Tz>() {
        Ok(tz) => SkyResult::Ok(tz.from_utc_datetime(&utc.naive_utc()).offset().fix().local_minus_utc() as i64),
        Err(_) => SkyResult::Err(format!("unknown timezone: {}", zone_name).into()),
    }
}
```

### C3 — Dict.empty zero-arg call

`Dict.empty` in Sky source: `Ffi.kernel "Dict_empty"`. After Stage 4, call
sites become `Can.VarKernel "Dict" "empty"`. The codegen checks
`Set.member ("Dict", "empty") ecZeroArgDefs`. Need to add this entry to
`zeroArgKernelDefs` since `Dict.empty` is a true zero-arg kernel.

```haskell
zeroArgKernelDefs :: Set.Set (String, String)
zeroArgKernelDefs = Set.fromList
    [ ("JsonDec", "string")
    , ...
    , ("Dict", "empty")        -- new
    , ("Math", "pi")           -- new (also zero-arg per Math.sky)
    , ("Math", "e")            -- new
    ]
```

### C4 — `From<String>` ambiguity on decoders

Sky source returns `Result Error a`. Runtime uses `SkyResult<E, T>` generic.
Call sites like `base64_decode(encoded)` can't infer E because the match
arms operate on the result without naming the type.

Two fixes:
- (a) Monomorphise runtime to `SkyResult<SkyError, T>` (simpler; loses
  flexibility for runtime tests that use `SkyResult<String, T>`)
- (b) Have call-site codegen emit a turbofish `base64_decode::<SkyError>(...)`.

(a) is the simplest. The runtime crate's tests use `SkyResult<String, T>` —
that's OK because in those tests `String: From<String>` (identity); we can
keep the generic param with a default. Or simpler: just narrow to concrete
`SkyError` (the codegen always uses `SkyError`):

```rust
// Before:
pub fn base64_decode<E: From<String>>(s: String) -> SkyResult<E, String> { ... }
// After:
pub fn base64_decode(s: String) -> SkyResult<SkyError, String> { ... }
```

But runtime tests check `SkyResult<String, T>`. Use `From<String>` generic
parameter — but add a default? Rust's `default type` parameters work in trait
bounds. Or: keep generic, but have codegen pin E via turbofish.

Hybrid: keep generic, generate turbofish in codegen where needed. Mirrors
what the Go path does (it inserts type coercion at boundaries).

**Easier short-term:** Add E=SkyError default via making the runtime function
non-generic. The runtime tests can be adapted to use SkyError, since the
runtime crate now has SkyError defined globally.

Spec: monomorphise `base64_decode`, `url_decode`, `encoding_hex_decode` to
non-generic `SkyResult<SkyError, T>`. Update tests.

### C5 — CurrencyRaw &str

Sky source:
```elm
fromCode code =
    case code of
        "USD" -> USD
        ...
        other -> CurrencyRaw other  -- 'other' is a bound variable from the case
```

Codegen emits:
```rust
match code { ..., other => StdMoneyCurrency::CurrencyRaw(other) }
```

The wildcard binding `other` is `&str` (Rust slice from the match scrutinee).
Constructor expects `String`. Fix: codegen should detect string match patterns
with bound variables and emit `.to_string()` conversion. Or simpler — in the
specific case-arm emission for `PVar` with non-literal pattern.

This requires looking at the case-emit codegen. The fix is narrow.

### C6 — `m.clone()` move out of Fn closure

`std_money_allocate` (codegen-emitted Sky wrapper):
```rust
sky_core_list_consume({ let m = m.clone(); move |d| {
    StdMoneyMoney::Money(d, std_money_currency(m))  // moves m
}}, decimals)
```

The closure captures `m` by move, but `Fn` requires no moves. Either:
- Make closure `FnOnce` (changes call signature elsewhere — risky)
- Re-clone m inside the closure body: `... std_money_currency(m.clone())`

Codegen fix: detect when a Sky lambda captures a non-Copy variable used in
position that needs the value (not a reference). Already partially handled
by `ecCloneVars`. The bug: nested Sky lambdas (or closure created in expr
position) don't get the inner-clone.

Likely fix in `Can.Lambda` arm of `exprToRustInner`: ensure captured non-Copy
vars used in the body get `.clone()` at each use site within the closure.

## 5. Soundness gate

Each fix is additive or surgical:
- C1: new entry + hook in placeholder; no existing emission changes.
- C2: runtime function signatures change to return SkyResult; the wrappers' expectations match.
- C3: adding entries to a Set; no existing behaviour changes.
- C4: removing generic param; runtime tests adapt to concrete type.
- C5: codegen detects a specific case-arm shape; non-matching arms unchanged.
- C6: codegen emits an extra `.clone()` inside specific lambda contexts.

## 6. Verification

1. Build the compiler after each commit.
2. Run 16/16 `examples/rust/*` regression after each commit.
3. Run `examples/00-standard-libs` on target=rust after each commit; track error count.
4. Final: confirm `120 passed, 0 failed (120 total)` on target=rust.
5. Go regression: `examples/01-hello-world` clean.
6. Targeted cabal test: `--match "FfiGen" --match "Toml" --match "Kernel"` → 27 / 0.

## 7. Risks

| Risk | Mitigation |
|---|---|
| C7 (JsonDecoder pipeline) turns out to block more than the listed errors | Audit after C1-C6 land; if `json` test suite still fails, sub-A.11 |
| C2's E generic on runtime breaks existing runtime tests | Update test calls to use `SkyResult<SkyError, T>` or compatible alias |
| C4's monomorphisation loses test flexibility | Acceptable — runtime tests don't need multiple E types in practice |
| C6 might recurse in lambda nesting | Test against examples/rust/* sweep; existing examples all build, regressions surface immediately |

## 8. Out of scope (sub-A.11+)

- JsonDecoder pipeline closure typing (C7).
- Sky.Test polymorphic assertion inference (the `multiple impls satisfying _: Mul<i32>` errors might be pre-existing).
- General Sky-source generic-parameter inference improvements.
- Optimising codegen output for warnings (47 currently — non-blocking).
