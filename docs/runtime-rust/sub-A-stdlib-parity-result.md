# Sub-project A — stdlib kernel completion: status

After Tasks 1-16 of the original sub-A plan plus the 10-task codegen-completion
plan (`docs/superpowers/plans/2026-05-29-rust-codegen-ffi-callpure-opaque-types.md`),
the **infrastructure** for sub-A is in place: the Rust codegen can express any
`Ffi.callPure` to a runtime kernel, opaque Sky types can be bridged to runtime
newtypes via the `runtimeOpaqueTypes` registry, and the 7 new runtime kernel
modules (Encoding / Regex / Crypto-completion / Jwt / Std.Time advanced /
Std.Decimal / Std.Money) all compile + their runtime unit tests pass.

The **headline gate** (Sky.Test 120 assertions on `target=rust` for
`examples/00-standard-libs`) is NOT yet met. Issues 2 and 3 (the codegen-
integration blockers) are both closed — the remaining work is broader runtime-
kernel coverage that sub-A's original scope underestimated.

## What is shipped + green

### Tasks 1-16 (the original sub-A runtime work)

| Component | File | Tests passing | `kernelToRust` arms |
|---|---|---|---|
| A.1 Encoding (base64/url/hex) | `runtime-rust/src/sky_runtime/encoding.rs` | 6 | ✅ Builder.hs |
| A.2 Regex (match/find/findAll/replace/split) | `runtime-rust/src/sky_runtime/regex_kernel.rs` | 5 | ✅ Builder.hs |
| A.3 Crypto completion (sha512/sha1/md5/hmac*/RSA/constantTimeEqual) | `runtime-rust/src/sky_runtime/crypto.rs` | 8 | ✅ Builder.hs |
| A.4 Jwt (HS256/RS256 encode+decode) | `runtime-rust/src/sky_runtime/jwt.rs` | 2 | (Sky-source on Crypto) |
| A.5 Std.Time advanced (IANA zones + calendar math, 24 fns) | `runtime-rust/src/sky_runtime/time.rs` | 5 | ✅ Builder.hs |
| A.6 Std.Decimal core (22 entries; `pub struct Decimal(rust_decimal::Decimal)`) | `runtime-rust/src/sky_runtime/decimal.rs` | 4 | ✅ Builder.hs |
| A.7 Std.Markdown | (pure Sky on String/List, no kernel needed) | — | — |

### Codegen completion (this plan — Tasks 0-9, 10 commits)

| Issue | Resolution | Verified by |
|---|---|---|
| **Issue 2** — `Ffi.callPure` unsupported on `target=rust` | Compile-time peephole in `Builder.hs:exprToRustInner` recognises `Can.Call (Can.VarKernel "Ffi" "callPure") [Can.Str name, Can.List args]` and emits direct kernel calls via `kernelToRust`. Non-peephole shapes route to `ffi_call_pure_polyfill` (actionable panic). `Ffi.toAny` collapses to identity inside peephole; standalone `Ffi.toAny x` also collapses. `Ffi.callTask` deferred to sub-project D. | Generated `std_decimal.rs` for examples/00-standard-libs has **zero** `ffi_call_pure` occurrences; every wrapper routes through `decimal_*` directly. |
| **Issue 3** — `Std.Decimal.Decimal` stubbed as `pub enum StdDecimalDecimal { Decimal__Internal(f64) }` | `runtimeOpaqueTypes :: Map (String, String) String` registry hooks `unionToRustTypeDef` — on hit, emits `pub use sky_runtime::Decimal as StdDecimalDecimal;` via new `RPubUseAlias` `RustTypeDef` variant. | Generated `main.rs` for examples/00-standard-libs contains `pub use sky_runtime::Decimal as StdDecimalDecimal;`. Cargo error count dropped 232 → 165 → 116 across Task 4 → Task 6 → Task 7. |
| **Sub-A integration gaps surfaced by Task 7** | (a) `emitCargoToml` now declares all sub-A crate deps with user-dedup; (b) `[features]` section with `default = ["tokio","crypto","json","db"]` so the runtime's `#[cfg(feature=…)]` gates fire in generated projects; (c) `hex_encode`/`hex_decode` runtime kernels renamed to `encoding_hex_encode`/`encoding_hex_decode` to avoid collision with user-FFI `hex_bindings` (examples/rust/16-hex). | 16/16 `examples/rust/*` build clean + run; targeted cabal test: 27/0 fail; Go regression (`examples/01-hello-world`) clean. |

## Headline gate result — `examples/00-standard-libs` on `target=rust`

**Status: BLOCKED on runtime-kernel coverage gap, NOT on Issues 2 or 3.**

- `target=go`: 120 passed, 0 failed (120 total).
- `target=rust`: cargo errors out with 116 errors (down from 232 pre-plan).

The error categorisation (full breakdown captured at Task 8) shows the
remaining 116 errors fall into one bucket: **`cannot find function`** for
kernel names not implemented in `sky_runtime/`. The codegen emits the
direct calls correctly (Issue 2 closed), the opaque type resolves correctly
(Issue 3 closed), but the runtime is missing kernels for:

| Module | Missing runtime kernels (sample, not exhaustive) |
|---|---|
| Sky.Core.String | `string_replace`, `string_starts_with`, `string_ends_with`, `string_repeat` |
| Sky.Core.Dict | `dict_empty`, `dict_insert`, `dict_get`, `dict_keys`, `dict_remove`, `dict_member`, `dict_from_list` |
| Sky.Core.Math | `math_sqrt`, `math_round`, `math_pow`, `math_min`, `math_max`, `math_floor`, `math_ceil`, `math_abs` |
| Sky.Core.Basics | `basics_mod_by`, `basics_error_to_string` |
| Sky.Core.List | `list_filter_map` |
| Std.Decimal | `decimal_eq`, `decimal_neq`, `decimal_lt`/`lte`/`gt`/`gte`, `decimal_min`/`max`, `decimal_is_zero`/`positive`/`negative`, `decimal_percent_of`, `decimal_add_percent`, `decimal_sub_percent`, `decimal_format_with` |
| Std.Money | every kernel — module never had a runtime implementation, only `kernelToRust` arms |
| Std.Time | `time_diff_seconds`/`minutes`/`hours`/`days`, `time_from_parts`, `time_zone_offset`, `time_zone_name` |

Plus a tier-2 layer of issues that surface once these are unblocked:
- 22 `E0308 mismatched types` errors — type-coercion shape mismatches between codegen-emitted signatures and runtime functions
- 6 `E0283 type annotations needed` — generic-inference issues at call sites
- 3 `E0618 expected function, found bool` — value-vs-function-call shape errors in codegen
- 2 `E0061 wrong arg count`

## What this means for sub-A

**Sub-A's contract** (per the original spec and CLAUDE.md) was "make
`examples/00-standard-libs` print `120 passed, 0 failed (120 total)` on
`target=rust`." That contract is NOT met today.

**Sub-A's tasks 1-16** shipped the 7 modules listed in §"Tasks 1-16" — the
"surface" sub-A targeted. But the headline gate also exercises Std.Money,
Dict, Math, String (some entries), Sky.Core.Basics, and List — none of which
were in Tasks 1-16. Those modules need their own runtime kernels.

**The codegen-completion plan** (this work) closes the two integration
blockers that made Tasks 1-16's work invisible to user code on `target=rust`.
With that done, the gap is now **only** missing runtime-kernel implementations
— no further codegen / FFI / opaque-type work is needed.

## Recommended next steps

The cleanest sequel is a new **sub-A.8 sub-plan**: "runtime-kernel coverage
to close the headline gate." It would:

1. Implement the missing runtime kernels above (~~70-80 functions across 7
   modules), mirroring the Go runtime's behaviour
2. Fix the tier-2 codegen shape mismatches as they surface
3. Land in 6-10 commits, broadly mechanical (most are direct ports of the Go
   `rt/*_kernel.go` files into Rust)
4. Re-run the headline gate and document the passing 120/120 result

That sub-plan can run any time — there's no blocking dependency on B-F.

## Commits this session

Codegen-completion plan (10 commits on `feat/runtime-rust`):

```
39646ac7  docs(rust): Task 0 — investigation notes for codegen-completion plan
34ecc6df  feat(rust): kernelToRust arms for Ffi.callPure/callTask/toAny -> polyfills
248abd80  feat(rust): Ffi.* runtime polyfill stubs (callPure / callTask / toAny)
abf0d822  feat(rust): Ffi.callPure peephole — direct kernel call from literal name+args
c906ac2a  feat(rust): collapse standalone Ffi.toAny x to bare x in Rust codegen
f892e9b6  feat(rust): runtimeOpaqueTypes registry + RPubUseAlias type-def variant
89d50fbf  feat(rust): bridge Std.Decimal.Decimal to sky_runtime::Decimal via registry hit
1d44e0d1  fix(rust): close sub-A integration gaps surfaced by regression sweep
```

Plus the spec, plan, and this status doc (3 docs commits).

## Cross-backend safety

Every change is Rust-target-gated or Rust-target-infra-only:
- `src/Sky/Generate/Rust/Builder.hs` (codegen)
- `src/Sky/Generate/Rust/Project.hs` (mod.rs generation)
- `runtime-rust/src/sky_runtime/` (runtime kernels)

Go path: byte-identical. `examples/01-hello-world` builds clean on `target=go`
both before and after this work. Targeted cabal-test sweep
(`--match "FfiGen" --match "Toml" --match "Kernel"`): 27 examples, 0 failures.
