# Bytes non-ASCII text — design + disposition

**divergenceId:** `bytes-nonascii-text`
**Disposition:** **IMPLEMENT** (triage said DOCUMENT_BLOCKED — overturned by empirical build).

## Problem

`Sky.Core.Bytes` (`type alias Bytes = String`) exposes five `Ffi.kernel`
aliases — `toString`, `toHex`, `fromHex`, `toBase64`, `fromBase64`. The triage
framed this as "only non-ASCII *text* diverges; the real fix is a nominal
`Bytes` type in the forbidden shared stdlib → DOCUMENT_BLOCKED".

That premise is **false**. The five kernels have **no entry in
`Builder/Kernel.hs`** and **no `bytes_*` function in the Rust runtime**. A Sky
program that calls any of them does not "diverge" — it **fails to compile** on
`--target rust`, and the def-side emits a `panic!` polyfill.

### Proven (minimal program, `Bytes.toHex (Bytes.fromString (Crypto.hmacSha256 …))`)

| Sky surface | Generated Rust | Result |
|---|---|---|
| `Bytes.toHex b` (call site) | `bytes_to_hex(…)` | **E0425 cannot find function** — undefined |
| `toHex = Ffi.kernel "Bytes_toHex"` (def site) | `pub fn sky_core_bytes_to_hex() -> fn(..)->String { ffi_kernel_polyfill("Bytes_toHex") }` | `panic!` polyfill — principle violation even if linked |
| `Bytes.length b` | `sky_core_bytes_length(b)` → `string_length(b)` → `s.len()` | compiles, **but byte-count wrong for non-ASCII** (UTF-8 len of Latin-1 storage double-counts high bytes) |
| `Bytes.fromString`, `isEmpty`, `append`, `slice` | pure-Sky, delegate to `string_*` | compile + correct |

Routing trace for `toHex`: `VarTopLevel "Sky.Core.Bytes" "toHex"` → `fnName == kernelName == sky_core_bytes_to_hex` → consults `ecKernelAliases` → `splitKernelName "Bytes_toHex"` = `("Bytes","toHex")` → `kernelToRust "Bytes" "toHex"` → **no match** → default `toSnakeCase "Bytes_toHex"` = `bytes_to_hex` (undefined).

## Answered questions

**Q1 — DOCUMENT-blocked, or in-boundary root-cause fix?**
In-boundary. The Rust backend owns the byte↔String convention end-to-end
(`encoding.rs` `sky_bytes`/`bytes_to_sky`). Adding `("Bytes", …)` mappings in
`Kernel.hs` + `bytes_*` functions in the runtime is entirely within
`runtime-rust/` + `src/Sky/Generate/Rust/`. No shared-stdlib edit. The nominal
`Bytes` type is a *red herring* — the alias compiles fine; the kernels are just
unimplemented.

**Q2 — crypto-UTF-8 vs encoding-Latin-1 internal split; which is canonical?**
**Latin-1 is canonical.** `encoding.rs` already uses it; it is the only
convention under which the raw-byte pipeline is lossless (a Rust `String` cannot
store arbitrary bytes ≥ 0x80 as single bytes under UTF-8). The split is
*currently harmless*: `crypto.rs` `sha256`/`hmacSha256` return **hex (ASCII)**
output (matching Go — `hex.EncodeToString`), and AEAD returns **base64 (ASCII)**;
crypto never hands raw non-ASCII bytes to the encoding layer. So unifying is NOT
a prerequisite to characterize the Go divergence. The new `bytes_*` functions
MUST use the Latin-1 `sky_bytes`/`bytes_to_sky` helpers to stay lossless and
self-consistent with `encoding.rs`.

**Q3 — does it fail to compile rather than silently diverge?**
**Yes — proven (E0425).** Real disposition is implement-the-kernels, not
document-only.

**Q4 — does the divergence extend into `Bytes.length`/`slice`?**
`length` → `string_length` → `s.len()` is **wrong** for non-ASCII (counts UTF-8
storage bytes of the Latin-1 string, i.e. double-counts high bytes). `slice` →
`string_slice` works on `chars()`, which for one-char-per-byte Latin-1 IS
byte-indexing → already correct. Fix `length` with a dedicated `bytes_length`
= `s.chars().count()` (the Latin-1 byte count). In scope; in-boundary.

**Q5 — minimal in-boundary regression fixture?**
New `runtime-rust/tests/sky/<n>-bytes-core/` (distinct from the FFI
`48-bytes-collision` / `09-bytesize` tests). It must (a) round-trip ASCII +
binary through hex/base64 and assert exact Go-matching encoded strings, and
(b) pin the non-ASCII contract (Latin-1 byte count + lossless round-trip).

**Q6 — chosen user-visible contract.**
Option (ii): **lossless round-trip within Rust via Latin-1**, byte-identical to
Go on ASCII / hex / binary, differing from Go only when a `Bytes` value holds
literal non-ASCII *text bytes* AND the encoded string is compared against a
Go-/externally-computed value. This maximises security (lossless crypto/binary
pipeline) and correctness (round-trip soundness) over the lowest-priority
behavioral Go-parity on an input shape (`Bytes` carrying UTF-8 *text* rather
than raw bytes) that the byte-buffer contract discourages anyway.

## Disposition rationale

Triage's blocker (shared-stdlib nominal type) does not apply: the alias is fine,
the kernels are simply missing. The fix is mechanical, in-boundary, verifiable,
and removes a `panic!` polyfill + a non-compiling call. Implementing it is
strictly better than documenting a "design-gated" non-issue.

## Principle check

- **Security:** Latin-1 keeps the crypto/AEAD/file-binary byte pipeline
  lossless — no silent byte corruption. ✅
- **Correctness/soundness:** removes E0425 (non-compiling) AND the
  `ffi_kernel_polyfill` `panic!` def. Total `Result`/`Maybe` for the fallible
  decoders (`fromHex`/`fromBase64`/`toString`) — no `unwrap`/`panic`/`Any`. ✅
- **No forbidden edits:** only `src/Sky/Generate/Rust/Builder/Kernel.hs` +
  `runtime-rust/src/sky_runtime/`. No shared stdlib, no Go, no `examples/`. ✅
- **Verifiable here:** new `runtime-rust/tests/sky/` fixture builds + runs +
  asserts Go-matching output for ASCII/hex/binary and pins the non-ASCII
  contract. ✅

## Root-cause change

1. **`Builder/Kernel.hs`** — add both bare + `Sky.Core.`-qualified mappings:
   `("Bytes","toHex") -> "bytes_to_hex"`, `toString -> "bytes_to_string"`,
   `fromHex -> "bytes_from_hex"`, `toBase64 -> "bytes_to_base64"`,
   `fromBase64 -> "bytes_from_base64"`, `length -> "bytes_length"`
   (override the `string_length` delegation so non-ASCII byte count is correct).
   Pin error-generic kernels in `kernelsNeedingErrorPin`/`Types.hs` if the
   `Maybe`-returning decoders need a turbofish (mirror `encoding_hex_decode`).
2. **`runtime-rust/src/sky_runtime/encoding.rs`** (or a new `bytes.rs` re-exported
   from `mod.rs`) — implement `bytes_to_hex` = `hex::encode(sky_bytes(&b))`,
   `bytes_from_hex` → `SkyMaybe` (Nothing on odd-len/non-hex),
   `bytes_to_base64` = `B64.encode(sky_bytes(&b))`, `bytes_from_base64` →
   `SkyMaybe`, `bytes_to_string` → `SkyMaybe<String>` (Nothing if the Latin-1
   bytes aren't valid UTF-8 — `String::from_utf8(sky_bytes(&b)).ok()`),
   `bytes_length` = `b.chars().count() as i64`. All reuse `sky_bytes`/
   `bytes_to_sky`; no panics; `Maybe`/`Result` for fallible paths.
   Ensure the module is unconditional (not feature-gated) so generated
   non-`encoding` projects still link.

## Verification plan

- `cargo test -p sky-runtime` unit tests on `bytes_*` (ASCII round-trip exact;
  `0x9E`-style binary lossless; non-ASCII byte-count = char-count, not `s.len()`).
- New `runtime-rust/tests/sky/<n>-bytes-core/` Sky fixture: builds on
  `--target rust`, runs, asserts hex/base64 of an ASCII + a binary payload
  match the Go reference strings, and that `Bytes.length` of a non-ASCII buffer
  equals the byte count.
- README divergence row flips `[ ]` → `[x]` with the Latin-1 lossless rationale.
