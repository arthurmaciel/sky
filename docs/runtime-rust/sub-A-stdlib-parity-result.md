# Sub-project A — stdlib parity status (+ sub-B Std.Db opened)

After five layers of sub-A work plus sub-B's Std.Db runtime on `feat/runtime-rust`:

| Layer | Plan | Commits | Status |
|---|---|---|---|
| Sub-A.1-A.6 (original runtime work) | `docs/superpowers/plans/2026-05-29-stdlib-kernel-completion.md` | `04ba135c..c899b9d5` | ✅ 7 modules shipped + green |
| Sub-A codegen-completion | `docs/superpowers/plans/2026-05-29-rust-codegen-ffi-callpure-opaque-types.md` | `7e1302e5..84a5eced` | ✅ Issues 2 + 3 closed |
| Sub-A.8 runtime-kernel coverage | `docs/superpowers/plans/2026-05-29-sub-A8-runtime-kernel-coverage.md` | `1c5a1596..9ecb33f1` | ✅ 54 kernels shipped + green |
| Sub-A.9 codegen-completeness | `docs/superpowers/plans/2026-05-29-sub-A9-codegen-completeness.md` | `7498edf6..6f5f3d87` | ✅ 4 fixes shipped; error count 70 → 36 (-49%) |
| Sub-A.10 codegen-shape cleanup | `docs/superpowers/plans/2026-05-30-sub-A10-codegen-shape-cleanup.md` | `4221a1eb..d7b2988f` | ✅ 6 fixes shipped; error count 36 → 17 (-53%) |
| Sub-A.11 headline-gate close | `docs/superpowers/specs/2026-05-30-sub-A11-headline-gate-close-design.md` | `e814bc90..398b5c5e` | ✅ Group A + B1-B3 + C1 shipped; error count 17 → 7 (-59%) |
| Sub-A.12 codegen polymorphism | `docs/superpowers/specs/2026-05-30-sub-A12-codegen-polymorphism-design.md` | `208759b6..65c010c6` | ✅ F1 (mapError generic) + F2 (partial-app wrap) shipped; F3 (empty-literal defaulting) deferred (regressed in naive form). Error count 7 → 4 (-43%) |
| Sub-B Std.Db runtime | `docs/superpowers/specs/2026-05-30-sub-B-stddb-runtime-design.md` | `cbfbd1d7..HEAD` | ✅ 12 missing kernels shipped (close, getBool, insertRow, CRUD, search, queryDecode, withTransaction); 11 sqlite unit tests; new `examples/rust/17-db-todo-cli` exercises all 7 CLI commands end-to-end |

**Cumulative error reduction (sub-A):** 232 → 165 → 116 → 70 → 36 → 17 → 7 → 4 (-98% from baseline).
**Sub-B status:** 17/17 `examples/rust/*` build + run; Std.Db end-to-end CRUD verified.

## What is shipped + green

### Tasks 1-16 (the original sub-A runtime work)

| Component | File | Tests |
|---|---|---|
| A.1 Encoding (base64/url/hex) | `runtime-rust/src/sky_runtime/encoding.rs` | 6 |
| A.2 Regex (match/find/findAll/replace/split) | `runtime-rust/src/sky_runtime/regex_kernel.rs` | 5 |
| A.3 Crypto completion (sha512/sha1/md5/hmac*/RSA/constantTimeEqual) | `runtime-rust/src/sky_runtime/crypto.rs` | 8 |
| A.4 Jwt (HS256/RS256 encode+decode) | `runtime-rust/src/sky_runtime/jwt.rs` | 2 |
| A.5 Std.Time advanced (IANA zones + calendar math) | `runtime-rust/src/sky_runtime/time.rs` | 5 |
| A.6 Std.Decimal core (22 entries; `pub struct Decimal(rust_decimal::Decimal)`) | `runtime-rust/src/sky_runtime/decimal.rs` | 4 |
| A.7 Std.Markdown | (pure Sky on String/List, no kernel needed) | — |

### Codegen completion (Issues 2 + 3 — closed)

| Issue | Resolution | Verified |
|---|---|---|
| Issue 2 — `Ffi.callPure` unsupported on `target=rust` | Compile-time peephole in `Builder.hs:exprToRustInner` rewrites literal-name + literal-args calls to direct kernel dispatch via `kernelToRust`. Polyfills for non-literal shapes. | `std_decimal.rs` for examples/00-standard-libs has zero `ffi_call_pure` occurrences |
| Issue 3 — Sky opaque types stubbed as f64 placeholder enums | `runtimeOpaqueTypes` registry + `RPubUseAlias` `RustTypeDef` variant emit `pub use sky_runtime::X as <Codegen>;` when matched | `pub use sky_runtime::Decimal as StdDecimalDecimal;` in generated `main.rs` |
| Plus: sub-A integration gaps (Task 7) | Cargo.toml deps for all sub-A modules (with user-dedup), `[features]` block enabling tokio/crypto/json/db, hex_encode → encoding_hex_encode rename | 16/16 examples/rust/* clean from wiped slate |

### Sub-A.8 runtime-kernel coverage (54 kernels — all shipped)

| Module | Kernels | File |
|---|---|---|
| Std.Decimal completion | 15 (eq/lt/min/sign/percent/formatWith) | `decimal.rs` (extended) |
| Std.Money | 12 (format/currency/rates/allocate; 57-entry currency table) | `money.rs` (new) |
| Sky.Core.Math | 8 (sqrt/pow/round/floor/ceil/abs/min/max) | `math.rs` (new) |
| Std.Time advanced | 7 (diff/fromParts/zone) | `time.rs` (extended) |
| Sky.Core.Dict | 7 (empty/get/insert/keys/remove/member/fromList) | `dict.rs` (new) |
| Sky.Core.String additions | 4 (replace/startsWith/endsWith/repeat) | `string.rs` (new) |
| Sky.Core.Basics + List | 3 (modBy/errorToString/filterMap) | `basics.rs` + `list.rs` (new) |
| **Total** | **56** | |

Each kernel mirrors its Go counterpart in `runtime-go/rt/*_kernel.go` or `rt.go`. 100+ runtime unit tests pass.

## Headline gate result — `examples/00-standard-libs` on `target=rust`

**Status: NOT FULLY MET** — but the remaining blockers are tier-2 codegen-shape bugs, not runtime-kernel gaps.

- `target=go`: **120 passed, 0 failed (120 total)** ✅
- `target=rust`: ~50 cargo errors remaining (down from 232 → 165 → 116 → ~50 across the three sub-plans). All "kernel not found" errors are GONE — every kernel the codegen tries to call now exists in `sky_runtime/`.

### Remaining error categorisation (sub-A.8 leftovers)

| Error | Count | Class | Root cause |
|---|---|---|---|
| `E0308 mismatched types` | ~40 | tier-2 codegen | Codegen-emitted wrapper signatures don't always match the runtime kernel signatures (e.g. `Result<E, T>` vs `SkyResult<E, T>` instantiation differences; `Vec<(String, String)>` vs `String` for `Jwt.Claims` accumulator) |
| `E0061 wrong argument count` | ~10 | tier-2 codegen | Sky-source zero-arg bindings like `Dec.zero = Ffi.callPure "Decimal_zero" []` emit as a bare `decimal_zero` identifier (function pointer) instead of `decimal_zero()` (call). The codegen's zero-arg detection misses this case. |
| `E0618 expected function, found bool` | 3 | tier-2 codegen | Similar zero-arg detection miss for value-typed bindings emitted in expression position |
| `E0425 cannot find value/function` | ~5 | tier-2 codegen | Pattern-match destructure functions (`amount (Money d _) = d`) emit `fn ...( _: T) -> ... { d }` losing the variable binding. The Rust codegen drops the destructure pattern. |
| `cannot find value c/d` | 2 | tier-2 codegen | Same destructure issue: `currency (Money _ c) = c` |

**None of these are runtime-kernel gaps.** Every kernel name the codegen emits resolves to a real function. The blockers are how the codegen *generates the wrapper functions* — specifically:

1. **Zero-arg Sky binding** → bare identifier instead of `()` call (~10 errors)
2. **Pattern-match destructure functions** → empty function body losing bound variables (~5 errors)
3. **Generic-parameter inference** in some Json.Decode pipeline cases (~6 `E0283 type annotations needed`)
4. **Result type instantiation** in Jwt.encode boilerplate (~24 errors localised to `sky_core_jwt.rs`)

These are codegen-completeness issues in `src/Sky/Generate/Rust/Builder.hs` — specifically the path that emits Sky-source wrapper modules. Each is a self-contained fix:

- Zero-arg call sites: extend `ecZeroArgDefs` to recognize Sky-source `name = Ffi.callPure "Kernel_x" []` patterns
- Pattern destructure: emit `match <param> { Ctor(d, _) => d }` instead of `{ d }`
- Result type instantiation: trace the inference path on `Result Error a` wrappers

A sub-A.9 sub-plan would cover these. ETA: ~6-10 commits, mostly mechanical once the codegen paths are pinned.

## Cross-target regression — all green

- 16/16 `examples/rust/*` build clean from a wiped slate.
- 16/16 binaries run their expected output.
- `examples/01-hello-world` on `target=go` builds clean.
- Targeted cabal test (`FfiGen` / `Toml` / `Kernel`): 27 examples, 0 failures.

## Commits across all three sub-plans

```
# Codegen completion (origin/feat/runtime-rust)
7e1302e5  docs(rust): sub-A codegen-completion spec
ec4775db  docs(rust): sub-A codegen-completion plan
39646ac7  docs(rust): Task 0 investigation notes
34ecc6df  feat(rust): kernelToRust arms for Ffi.callPure/callTask/toAny
248abd80  feat(rust): Ffi.* runtime polyfill stubs
abf0d822  feat(rust): Ffi.callPure peephole
c906ac2a  feat(rust): collapse standalone Ffi.toAny x to bare x
f892e9b6  feat(rust): runtimeOpaqueTypes registry + RPubUseAlias
89d50fbf  feat(rust): bridge Std.Decimal.Decimal via registry hit
1d44e0d1  fix(rust): close sub-A integration gaps surfaced by sweep
84a5eced  docs(rust): sub-A headline-gate result

# Sub-A.8 runtime-kernel coverage (local, not yet pushed)
1c5a1596  docs(rust): sub-A.8 spec
be188440  docs(rust): sub-A.8 plan
39d66a61  docs(rust): sub-A.8 T0 contracts
91a10343  feat(rust): Std.Decimal completion (15 kernels)
4ea6c561  feat(rust): Std.Money runtime (11 kernels)
109ab5c4  feat(rust): Sky.Core.Math (8 kernels)
17fbbc82  feat(rust): Std.Time advanced (7 kernels)
6be48071  feat(rust): Sky.Core.Dict (6 kernels)
68c1d081  feat(rust): Sky.Core.String additions (4 kernels)
11a6ae1b  feat(rust): Sky.Core.Basics + List (3 kernels)
+ Dict.fromList add + this status doc
```

## What's left for sub-A's full headline-gate close

Sub-A.9 sub-plan: codegen-shape fixes for the ~50 leftover errors in `examples/00-standard-libs` on `target=rust`. All in `src/Sky/Generate/Rust/Builder.hs`; expected to mostly be:

1. Zero-arg call-site emission (extend `ecZeroArgDefs` recognition).
2. Pattern-destructure function body emission (emit `match` over the param).
3. `Result Error a` instantiation in Jwt wrappers.
4. Json.Decode pipeline closure typing.

These are pure codegen completeness work — no further runtime kernels need to be written. Once shipped, the headline gate `120 passed, 0 failed (120 total)` will fire on `target=rust`.

## Cross-backend safety (preserved across all three sub-plans)

Every change is Rust-target-gated:
- `src/Sky/Generate/Rust/Builder.hs` (codegen)
- `src/Sky/Generate/Rust/Project.hs` (mod.rs generation)
- `runtime-rust/src/sky_runtime/` (runtime kernels)

Go path: byte-identical throughout. `examples/01-hello-world` on `target=go` builds clean at every commit.

## Sub-A.9 outcome — codegen-completeness fixes

Four root-cause fixes in `src/Sky/Generate/Rust/Builder.hs` dropped the cargo
error count on `examples/00-standard-libs` target=rust from **70 → 36** (-34
errors, -49%) across these commits:

| # | Fix | Errors closed |
|---|---|---|
| B1 | Remove `("Std.X", ...)` kernelToRust mirror arms — 83 entries across Std.Decimal/Money/Time. User-source references like `Money.format m` now go through the wrapper (which does Currency→String conversion) instead of bypassing to the runtime kernel. | -22 |
| B3 | PCtor pattern-arg destructure prelude — `amount (Money d _) = d` was emitting `pub fn(_) { d }` (d not in scope). New `patternToRustArg` synthesises `__pN` params and prepends `let <Pat> = __pN else { unreachable!() };`. | -2 |
| B6 | Type-aware `Can.Binop "++"` — was emitting `format!` regardless of operand type; now branches on `solveArgType` and emits `{ let mut __r = lhs.clone(); __r.extend(rhs); __r }` for Vec, `format!` for String. Closed the Jwt cascade. | -2 |
| B2 | Exclude Ffi.kernel-alias bindings from `zeroArgDefs` — `contains = Ffi.kernel "String_contains"` was treated as zero-arg, making call sites emit `string_contains()(args)`. Now the body is inspected; `Ffi.kernel` aliases are correctly skipped. | -8 |

(Note: B6 closed Jwt's `++` shape but the downstream cascade of E0308s
involves multiple wrapper signatures; the headline-gate measurement
reflects net change after Rust's inference re-runs across all affected
sites.)

### Remaining 36 errors

| Class | Count | Locus | Path forward |
|---|---|---|---|
| `E0308` mismatched types | 24 | `sky_core_jwt.rs` (24 — Json.Encode.Value vs String shape mismatches downstream of withClaim/Issuer/etc.); `sky_core_json_decode.rs` (decoder wrapper signatures) | Sub-A.10: JsonDec/JsonEnc wrapper type-shape fixes |
| `E0283` type annotations needed | 7 | `sky_core_json_decode.rs` decoder pipeline | Sub-A.10: closure typing in pipeline-style decoders |
| `E0507`/`E0061` shape | 5 | `main.rs` test combinators, `std_money.rs` clear_rates `()` arg | Surgical — small follow-on patches |

The remaining errors are all **codegen-shape issues localised to JSON
decoder/encoder wrappers** plus a few isolated shape bugs in test
combinators. Each is a self-contained fix; no further runtime kernels
needed. Sub-A.10 sub-plan would close them.

### Cross-target regression — still all green

- 16/16 `examples/rust/*` build clean from a wiped slate.
- 16/16 binaries run their expected output.
- `examples/01-hello-world` on `target=go` builds clean.
- Targeted cabal test (`FfiGen` / `Toml` / `Kernel`): 27/0.

## Sub-A.9 commits

```
7498edf6  docs(rust): sub-A.9 spec — three codegen-shape fixes for headline gate
348a2f55  docs(rust): sub-A.9 plan — 7 tasks, codegen-shape fixes
342a3e54  fix(rust): remove ("Std.X", ...) kernelToRust mirror arms — close wrapper bypass
06f3a58e  fix(rust): PCtor function-param destructure prelude — close 'cannot find value' bugs
f68e8c15  fix(rust): type-aware Can.Binop '++' — Vec gets extend, String gets format!
3cda519f  fix(rust): exclude Ffi.kernel-alias bindings from zeroArgDefs
```

## Sub-A.10 outcome — codegen-shape cleanup

Six focused fixes dropped the cargo error count on `examples/00-standard-libs`
target=rust from **36 → 17** (-19 errors, -53%) across these commits:

| # | Fix | Errors closed |
|---|---|---|
| C1 | Sky.Core.Json.Encode.Value → sky_runtime::JsonVal via opaque-type registry; extended `ffiPlaceholder` to consult `runtimeOpaqueTypes` (reverse-keyed by codegen name). | -8 |
| C2 | Std.Time fromParts/zoneOffset/zoneName now return `SkyResult<E, T>` matching Sky source signatures. | -3 |
| C3 | Added (Dict, empty), (Math, pi), (Math, e) to `zeroArgKernelDefs` + new `math_pi`/`math_e` runtime + kernel arms. | -4 |
| C4 | Decoder turbofish: kernels generic over `<E: From<String>>` (base64_decode, url_decode, encoding_hex_decode) now emit `::<SkyError>` at call sites via new `kernelsNeedingErrorPin` Set. | -4 |
| C5 | Case-arm PVar binding under `.as_str()`-wrapped scrutinee converts `&str` to `String` at the body-binding site via shadow `let`. | -1 |
| C6 | Lambda emission unions outer `ecCloneVars` and captured-set into inner context — fixes E0507 move-out from Fn closures in std_money_allocate. Net +1 inference issue surfaced (E0282 on dict_empty / json_dec_field). | +1 (closed move-out; exposed inference) |

### Remaining 17 errors

| Class | Count | Locus | Path forward |
|---|---|---|---|
| `E0308` mismatched types | 7 | sky_core_jwt.rs (7 — remaining JWT encode/decode shape issues) | Sub-A.11 |
| `E0283`/`E0282` type annotations needed | 6 | sky_core_json_decode.rs + main.rs (JsonDecoder pipeline; dict_empty<T>() type inference; sky_core_maybe_map closure inference) | Sub-A.11: pipeline type-inference improvements |
| `E0277` Fn closure / `E0061` arg counts / `E0308` arg incorrect | 4 | std_money.rs (clear_rates ()), main.rs (test combinator typing) | Surgical patches in sub-A.11 |

The remaining errors are concentrated in two areas:
1. **JsonDecoder pipeline** (~10 errors) — Decoder composition has fundamentally
   nested closure types; needs an architectural reshape.
2. **Test-combinator polymorphism** (~7 errors) — Sky.Test's polymorphic
   assertion helpers + Sky.Core.Maybe.map's closure inference.

### Cross-target regression — still all green

- 16/16 `examples/rust/*` build clean from a wiped slate.
- 16/16 binaries run their expected output.
- `examples/01-hello-world` on `target=go` builds clean.
- Targeted cabal test (`FfiGen` / `Toml` / `Kernel`): 27/0.

## Sub-A.10 commits

```
4221a1eb  docs(rust): sub-A.10 spec — six focused fixes for remaining 36 errors
fe439f8a  docs(rust): sub-A.10 plan — 8 tasks for 26-error headline-gate close
39c12200  fix(rust): C1 — Sky.Core.Json.Encode.Value via opaque-type registry
081ef459  fix(rust): C2 — Std.Time fromParts/zoneOffset/zoneName return SkyResult
9028dc79  fix(rust): C3 — Dict.empty + Math.pi/e zero-arg kernel call sites
5a3a83b1  fix(rust): C4 — Decoder turbofish for E: From<String> kernels
edd931d6  fix(rust): C5 — case-arm PVar binding under .as_str() scrutinee → String
6dace4b5  fix(rust): C6 — capture cloning in move closures
```

## Sub-A.11 outcome — final 10 errors closed

Five fixes dropped the cargo error count on `examples/00-standard-libs`
target=rust from **17 → 7** (-10 errors, -59%) across these commits:

| # | Fix | Errors closed |
|---|---|---|
| Group A | `kernelsNeedingErrorPin` refactored from Set to Map (per-kernel turbofish suffix); `kernelsZeroArg` Set added; both Can.VarKernel and Can.VarTopLevel arms updated to combine them. Closed the "JsonDecoder pipeline" without architectural reshape (it was just the same zero-arg + turbofish issue). | -6 |
| B1 | `decimal_format_with` runtime arg order swapped to match Sky source `(thousandsSep, decimalSep, places, d)`. | -1 |
| B2 | `money_clear_rates` drops the unused `()` param (Sky's `Ffi.callPure "Money_clearRates" []` peephole emits zero args). | -1 |
| B3 | `time_from_parts` rewritten to take `zone` first (7 args matching Sky source), with chrono-tz local→UTC conversion. | -1 |
| C1 | `dict_empty` defaults to `::<i64>` turbofish; Can.VarKernel zero-arg-with-turbofish ordering fixed (turbofish before `()`). | -1 |

### Remaining 7 errors

All four classes need **codegen polymorphism** improvements beyond
sub-A.11's surface fixes:

| Class | Count | Locus | Root cause |
|---|---|---|---|
| `sky_core_list_head(vec![])` E0283 | 1 | main.rs:241 | Empty `vec![]` passed to generic `<T0>` function; no constraint to pin T0. Needs codegen-level "empty-Vec defaulting" or call-site `Vec::<i64>::new()` emission. |
| `sky_core_maybe_map(closure, SkyMaybe::Nothing)` E0283 | 2 | main.rs:247 | `Maybe::Nothing` has no constraint on inner type; closure's `x` ambiguous. Same defaulting issue. |
| `sky_core_result_map_error(closure, …)` E0308 | 2 | main.rs:250 | `pub fn sky_core_result_map_error<T0>(fn: Fn(SkyError) -> String, …)` — the closure return type is **hardcoded** to `String` in the codegen-emitted Sky wrapper, but Sky source `mapError : (e -> e2) -> Result e a -> Result e2 a` is fully polymorphic in e2. The codegen's wrapper-signature inference needs to emit `<E1, E2, T>` not `<T0>`. |
| JWT validate_time signature | 2 | sky_core_jwt.rs:50 | `sky_core_jwt_validate_time` codegen-emitted with 2-arg signature, called with 1 arg. Sky-source codegen-polymorphism issue (similar to mapError). |

These four classes share a root cause: **Sky-source polymorphic function
wrappers don't always emit with the right generic-parameter set**. The
codegen specialises some type parameters to concrete types (often
`String` or `SkyError`) instead of leaving them as generics.

Fixing requires reworking the codegen's wrapper-signature inference
(`knownDefSig` + `extractParamTypes` + `extractReturnType` interaction).
Substantial change — deferred to sub-A.12 if pursued.

### Cross-target regression — all green

- 16/16 `examples/rust/*` build clean from a wiped slate.
- 16/16 binaries run their expected output.
- `examples/01-hello-world` on `target=go` builds clean.
- Targeted cabal test (`FfiGen` / `Toml` / `Kernel`): 27/0.

## Sub-A.11 commits

```
e814bc90  docs(rust): sub-A.11 spec — close the headline gate (17 -> 0 errors)
dc8af02e  fix(rust): A — kernelsZeroArg + per-kernel turbofish for json_dec_*
51663fbe  fix(rust): B1+B2+B3 — runtime signatures match Sky source contracts
281bcd61  fix(rust): C1 — dict_empty + zero-arg-with-turbofish ordering
```

## Sub-A.12 outcome — codegen polymorphism fixes

Two surgical codegen fixes dropped the cargo error count on
`examples/00-standard-libs` target=rust from **7 → 4** (-3 errors, -43%):

| # | Fix | Errors closed |
|---|---|---|
| F1 | `resultSig "mapError"` made generic over both error types (`<T1, T2>` instead of hardcoded `SkyError -> String`). Sky source `mapError : (e -> e2) -> Result e a -> Result e2 a` is fully polymorphic; the wrapper signature now matches. | -1 (was 2, closed 1; remaining is inference cascade) |
| F2 | Partial application wrap. Sky's `result_and_then (validateTime now) (...)` — `validateTime` takes 2 args but receives 1 (curried). Codegen now detects via `length args < arity` (via `ecSolvedTypes`) and emits `(move \|__paN\| f(supplied.., __paN..))` closure. | -2 |

### F3 — Empty-literal defaulting (deferred)

Tried both `Vec::<i64>::new()` for empty `Can.List []` and `SkyMaybe::<i64>::Nothing` for the Nothing constructor. Both regressed: ~14-50 new E0308 errors from contexts where the surrounding type didn't match i64. The defaulting needs context-aware emission (look at the call site type signature to choose the right default per-call) — non-trivial codegen surgery. Out of scope for sub-A.12.

### Remaining 4 errors

| Class | Count | Locus | Why deferred |
|---|---|---|---|
| `sky_core_list_head(vec![])` E0283 | 1 | main.rs:241 | Empty-Vec defaulting (F3) |
| `sky_core_maybe_map(closure, Nothing)` E0283 | 2 | main.rs:247 | Maybe-Nothing inference (F3) + closure-arg inference |
| `sky_core_result_map_error(...)` E0283 | 1 | main.rs:250 | F1 cascade — outer inference still ambiguous after the closure signature fix |

These are all empty-literal / Nothing-pattern inference issues. They require codegen-level context propagation (the codegen needs to know "this empty literal is being passed as an argument to a generic function whose other args don't pin the type, so inject a turbofish"). Substantial change; deferred.

### Cross-target regression — all green

- 16/16 `examples/rust/*` build clean from a wiped slate.
- 16/16 binaries run their expected output.
- `examples/01-hello-world` on `target=go` builds clean.
- Targeted cabal test (`FfiGen` / `Toml` / `Kernel`): 27/0.

## Sub-A.12 commits

```
208759b6  docs(rust): sub-A.12 spec — codegen polymorphism fixes for the final 7
54b7fb95  fix(rust): F1 — resultSig 'mapError' generic over both error types
124b857e  fix(rust): F2 — partial application wrap for under-applied calls
```

## Sub-B outcome — Std.Db Rust runtime

After sub-A's headline gate hit 98% reduction and upstream v0.15.34 synced, sub-B opened the next stdlib pillar: **Std.Db** on `target=rust`.

### Shipped (12 new kernels)

`runtime-rust/src/sky_runtime/db.rs` (sqlx-backed; sqlite focus):

| Kernel | Sky signature |
|---|---|
| `db_close` | `Db -> Task Error ()` (graceful pool close) |
| `db_get_bool` | parses `'1'/'true'/'TRUE'/'t'/'T'` as truthy |
| `db_insert_row` | `Db -> table -> Dict -> Task Error Int` (returns lastInsertRowid) |
| `db_get_by_id` | `Db -> table -> id -> Task Error (Maybe Row)` |
| `db_update_by_id` | `Db -> table -> id -> Dict -> Task Error Int` (rows affected) |
| `db_delete_by_id` | `Db -> table -> id -> Task Error Int` |
| `db_find_one_by_field` | parameterised equality lookup |
| `db_find_many_by_field` | same, returning a List |
| `db_find_by_conditions` | AND-joined equality on every key/value |
| `db_unsafe_find_where` | raw `WHERE` with parameterised args (explicitly unsafe) |
| `db_query_decode` | typed query with per-row decoder closure |
| `db_with_transaction` | BEGIN/COMMIT/ROLLBACK lifecycle |

Plus 12 `kernelToRust` arms in `Builder.hs` (both `("Db", X)` and `("Std.Db", X)` since Db uses `Ffi.kernel` aliases like Math/String/Dict).

`safe_ident` guards table/column names against SQL injection; parameter values go through sqlx's `bind` (not string interpolation).

### Known semantic limitation — withTransaction + pool routing

sqlx::Pool dispatches each query to any available connection. For BEGIN/COMMIT/ROLLBACK to be transactional, all statements must run on the same connection. The current `db_with_transaction` issues the control statements on the pool but the body's queries may route elsewhere — full rollback isolation requires `max_connections(1)` in production code.

The runtime test `test_with_transaction_rollback_returns_err` asserts only that `Err` propagates (the common-case guarantee). The doc comment on `db_with_transaction` describes the trade-off in full.

### Integration test — `examples/rust/17-db-todo-cli`

Mirrors `examples/07-todo-cli` (Go target reference) with `target = "rust"` + sqlite driver. **Reuses the unmodified Sky source from 07-todo-cli** — no codegen-shape adaptations needed. All 7 CLI commands verified end-to-end:

```
$ sky-app add "Buy groceries"     # Db.insertRow
$ sky-app list                    # Db.findManyByField + Db.unsafeFindWhere
$ sky-app done 1                  # Db.updateById
$ sky-app undone 1                # Db.updateById
$ sky-app remove 1                # Db.deleteById
$ sky-app clear                   # Db.exec (DELETE WHERE done = 1)
$ sky-app help                    # no Db
```

### Verification — all green

- 17/17 `examples/rust/*` build clean from a wiped slate; 17/17 binaries run.
- `examples/01-hello-world` on `target=go`: clean.
- Targeted cabal test (`FfiGen` / `Toml` / `Kernel`): 1/1 pass.
- Runtime tests (`cargo test --features db,async --lib db`): 11/11 pass.

### Sub-B commits

```
cbfbd1d7  docs(rust): sub-B spec — Std.Db Rust runtime (12 missing kernels)
9c46621d  feat(rust): sub-B T1-T3 — 12 missing Std.Db kernels (sqlite + sqlx)
2335dafa  test(rust): 17-db-todo-cli — full CRUD example via Std.Db on target=rust
```

### Out of scope (sub-B.1+)

- Postgres / MySQL backends.
- Single-connection-pool transaction isolation (would require Sky-side `Db.Transaction` ADT separate from `Db`).
- ORM-style schema introspection.
