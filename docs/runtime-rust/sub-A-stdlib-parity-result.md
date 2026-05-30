# Sub-project A — stdlib parity status

After three layers of work on `feat/runtime-rust`:

| Layer | Plan | Commits | Status |
|---|---|---|---|
| Sub-A.1-A.6 (original runtime work) | `docs/superpowers/plans/2026-05-29-stdlib-kernel-completion.md` | `04ba135c..c899b9d5` | ✅ 7 modules shipped + green |
| Sub-A codegen-completion | `docs/superpowers/plans/2026-05-29-rust-codegen-ffi-callpure-opaque-types.md` | `7e1302e5..84a5eced` | ✅ Issues 2 + 3 closed |
| Sub-A.8 runtime-kernel coverage | `docs/superpowers/plans/2026-05-29-sub-A8-runtime-kernel-coverage.md` | `1c5a1596..HEAD` | ✅ 54 kernels shipped + green; headline gate partially-met (error count 116 → ~50) |

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
