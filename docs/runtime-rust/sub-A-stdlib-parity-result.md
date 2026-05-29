# Sub-project A — stdlib kernel completion: status

After Tasks 1-16 of `docs/superpowers/plans/2026-05-29-stdlib-kernel-completion.md`,
the runtime kernels for Encoding / Regex / Crypto-completion / Jwt / Std.Time
advanced / Std.Decimal are all implemented and unit-tested. 50 runtime lib tests
pass (with `--features crypto,json`). `cabal build exe:sky` succeeds.

## What is shipped + green

| Component | File | Tests passing | `kernelToRust` arms |
|---|---|---|---|
| A.1 Encoding (base64/url/hex) | `runtime-rust/src/sky_runtime/encoding.rs` | 6 | ✅ Builder.hs |
| A.2 Regex (match/find/findAll/replace/split) | `runtime-rust/src/sky_runtime/regex_kernel.rs` | 5 | ✅ Builder.hs |
| A.3 Crypto completion (sha512/sha1/md5/hmac*/RSA/constantTimeEqual) | `runtime-rust/src/sky_runtime/crypto.rs` (extended) | 8 | ✅ Builder.hs |
| A.4 Jwt (HS256/RS256 encode+decode) | `runtime-rust/src/sky_runtime/jwt.rs` | 2 | n/a — Jwt.sky is pure-Sky on Crypto |
| A.5 Std.Time advanced (IANA zones + calendar math, 24 fns) | `runtime-rust/src/sky_runtime/time.rs` (extended) | 5 | ✅ Builder.hs |
| A.6 Std.Decimal (~22 entries; rust_decimal newtype) | `runtime-rust/src/sky_runtime/decimal.rs` | 4 | ✅ Builder.hs |
| A.7 Std.Markdown | n/a — pure Sky on String/List primitives, no kernel needed | — | — |

All 18 commits land on `feat/runtime-rust`. The Sky compiler rebuilds cleanly
(`cabal install ... exe:sky` → `sky dev`).

## Integration gap discovered at the headline gate (Task 17)

Attempting `examples/00-standard-libs` on `target=rust` revealed that the Sky
compiler emits TWO different kernel-dispatch codepaths:

1. **Direct emit** — for `Sky.Core.*` modules (List, String, Crypto, Encoding,
   Regex, …). The codegen looks up `kernelToRust mod name` and emits a bare
   call like `list_map_consume(f, xs)`. This relies on
   `use crate::sky_runtime::*;` bringing the function into scope. **This is
   the path my Tasks 2/4/8 wire — and it works for the Sky.Core.* kernels.**

2. **Dynamic dispatch via `ffi_call_pure`** — for `Std.*` modules (Decimal,
   Time, Money, …). The codegen emits per-Sky-module Rust files like
   `std_decimal.rs` whose wrapper bodies call
   `ffi_call_pure("Decimal_fromInt".to_string(), vec![n])` — they do NOT call
   my runtime kernels directly. **`kernelToRust` arms have no effect on this
   path.** The actual `Std.Decimal`/`Std.Time` calls in user code wind up
   needing a runtime registry that maps kernel-name strings to function
   pointers.

The `Sky.Core.*` work (Encoding / Regex / Crypto / Jwt) is fully functional
end-to-end as soon as a Sky program uses those modules. The `Std.*` work
(Time / Decimal) is correct in isolation but **does not yet flow to user code
through the Std.* dispatch path** — a follow-on task must register the kernels
with whatever registry `ffi_call_pure` consults at runtime (most likely a
matching update to the codegen's `std_<module>.rs` emission OR a runtime-side
dispatch table).

## Next bite (for when picking sub-project A back up)

Investigate `ffi_call_pure` in the Sky compiler:

```bash
grep -nR "ffi_call_pure" src/Sky/
grep -nR "ffi_call_pure" runtime-rust/src/
```

The two likely fixes:

- **Change the codegen** for `Std.*` modules to use direct kernel calls (same
  as `Sky.Core.*`), routing through the existing `kernelToRust` arms. Or:
- **Add a kernel registry** in `runtime-rust/src/sky_runtime/` that
  `ffi_call_pure` consults, registering each kernel by its Sky-side name
  string. Cheapest if the codegen for `Std.*` is intentionally dynamic.

Once one of those is in place, the `kernelToRust` arms for Std.Time and
Std.Decimal (already committed in Tasks 12, 14) take effect for user code,
the headline gate `examples/00-standard-libs` runs, and the relevant suites
(Crypto, Jwt, Encoding, Std.Time, Std.Decimal, Std.Money) should pass on
`target=rust`.

## Commits this session (18 total on `feat/runtime-rust`)

```
04ba135c  feat(rust): sky_runtime encoding kernels (sub-A.1) — base64/url/hex
7356f6cc  feat(rust): Builder kernelToRust arms for Encoding (sub-A.1)
8f21fb78  feat(rust): sky_runtime regex kernels (sub-A.2)
fb9c6862  feat(rust): Builder kernelToRust arms for Regex (sub-A.2)
38565027  feat(rust): sky_runtime sha512/sha1/md5 (sub-A.3 part 1)
66bec951  feat(rust): sky_runtime hmacSha256/hmacSha512 (sub-A.3 part 2)
b7b5e8a9  feat(rust): sky_runtime RSA-SHA256 sign/verify + constantTimeEqual (sub-A.3 part 3)
0a6472cf  feat(rust): Builder kernelToRust arms for Crypto completion (sub-A.3)
5d3f70c7  feat(rust): sky_runtime jwt HS256/RS256 encode+decode (sub-A.4)
033b9e4e  feat(rust): sky_runtime Std.Time advanced — IANA zones + calendar math (sub-A.5)
f94e1465  feat(rust): Builder kernelToRust arms for Std.Time advanced (sub-A.5)
8f28d6c4  feat(rust): sky_runtime Std.Decimal — full arithmetic + banker's rounding (sub-A.6)
c17960bd  feat(rust): Builder kernelToRust arms for Std.Decimal (sub-A.6)
```

(Plus the spec, plan, and this status doc.)
