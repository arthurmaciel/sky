# Rust FFI — byte slice / array parameters & results

**Date:** 2026-05-26
**Branch:** `feat/runtime-rust`
**Status:** design approved, pending spec review

## Problem

The automatic Rust FFI (rustdoc-JSON inspector → `FfiGen.hs` → wrapper crate)
currently **drops** any function whose parameter or result is an array or slice
(`p.rust_type.contains('[')`). That removes the entire byte-oriented surface of
hashing and encoding crates — `crc32fast::hash(&[u8]) -> u32`,
`sha2`/`Hasher::update(&[u8])`, `hex::encode(&[u8])`, `uuid::Uuid::from_bytes([u8; 16])`,
`uuid::Uuid::as_bytes() -> &[u8; 16]`, etc. — even though the data they move is
just bytes, which Sky already represents.

## Goal

Let Sky bind functions that take or return a **read-only byte sequence**, so
hashing/encoding crates work end-to-end. Specifically the rust shapes:

- `&[u8]` (slice)
- `Vec<u8>` (owned vector)
- `[u8; N]` (owned fixed array)
- `&[u8; N]` (borrowed fixed array)

in both parameter and result position.

## Key decisions

| Decision | Choice | Rationale |
|---|---|---|
| Sky-side representation | `List Int` (`Vec<i64>`) | No new type / type-checker work; matches the existing `File.readFileBytes : String -> Task Error (List Int)`, so its output pipes straight into a hash/encode binding. There is no surface `Bytes` type today. |
| Direction | Params **and** results | Symmetric; lets byte data round-trip (`uuid::as_bytes`, digest outputs). |
| `[u8; N]` length mismatch | Return `Err`, never panic | Project non-negotiable: "no runtime panic from well-typed Sky code." |
| Where coercion lives | Three helpers in `sky_runtime/core.rs`; wrappers stay thin | Matches the runtime-rust principle "runtime logic lives in `sky_runtime`, `Builder.hs`/`FfiGen.hs` emit thin wrappers." |
| Element conversion | `as u8` (narrow) / `as i64` (widen) | Mirrors the existing numeric param narrowing the codegen already emits (`arg0 as u32`). |

### Out of scope (YAGNI)

- `&mut [u8]` in/out fill params (e.g. `fastrand::fill`) — write-back semantics
  are harder; keep dropping.
- Non-byte slices/arrays (`&[String]`, `[f64; 3]`) — need per-element coercion;
  separate effort. Keep dropping.
- Explicit-lifetime byte refs (`&'a [u8]`) — already dropped by the lifetime
  filter; only elided `&[u8]` (the common case) is handled.
- A first-class Sky `Bytes` type.

## Design

### 1. Inspector — `tools/sky-ffi-inspect-rs/src/main.rs`

**`is_byte_seq(rt: &str) -> bool`** — true for exactly `Vec<u8>`, `&[u8]`,
`[u8; N]`, `&[u8; N]` (N = literal digits; tolerate surrounding whitespace).
False for `&mut [u8]` and any non-`u8` element type.

Weave it into the three existing drop-filters in `parse_fn_item` so a function
is no longer dropped *solely* for a byte sequence:

- **array/slice filter** (currently drops any `contains('[')`): drop only when a
  param/result has an array/slice that is **not** a byte sequence. `&[String]`,
  `[f64; 3]` still drop; `&[u8]`, `[u8; 16]` now pass.
- **borrowed-result filter** (`result_borrows`): exempt byte-sequence results
  (`&[u8]`, `&[u8; N]`) alongside the existing `&str`/`&String`.
- **lifetime filter**: unchanged (elided byte refs carry no `'`).

**Sky type mapping → `List Int` for every byte sequence.** Change the array
branch in `rustdoc_type_to_sky` so a `u8`-element array (`[u8; N]`) maps to
`List Int` instead of the internal `"Bytes"` name; slices and `Vec<u8>` already
map to `List Int`. The `rustType` field keeps the real shape (`&[u8]`,
`[u8; 16]`, …) for `FfiGen` to drive coercion. Result: the `.skyi` always
declares `List Int`, a real surface type.

### 2. Runtime helpers — `runtime-rust/src/sky_runtime/core.rs`

Additive; re-exported via `mod.rs` (core is already re-exported).

```rust
/// Sky List Int -> owned bytes (narrowing `as u8`). For &[u8] / Vec<u8> params.
pub fn to_u8_vec(xs: &[i64]) -> Vec<u8> {
    xs.iter().map(|&x| x as u8).collect()
}

/// Owned/borrowed bytes -> Sky List Int. For byte results.
pub fn from_u8_slice(bs: &[u8]) -> Vec<i64> {
    bs.iter().map(|&b| b as i64).collect()
}

/// Sky List Int -> [u8; N]; length mismatch returns Err (never panics).
/// For [u8; N] / &[u8; N] params.
pub fn to_u8_array<E: From<String>, const N: usize>(xs: &[i64]) -> SkyResult<E, [u8; N]> {
    if xs.len() != N {
        return SkyResult::Err(format!("expected {} bytes, got {}", N, xs.len()).into());
    }
    let mut a = [0u8; N];
    for (i, &x) in xs.iter().enumerate() { a[i] = x as u8; }
    ok_res(a)
}
```

`to_u8_array` is generic over `E` and `const N`; the wrapper instantiates
`E = SkyError` and the concrete `N` (same pattern as `task_map::<SkyError, _, _>`).

### 3. Codegen — `src/Sky/Build/FfiGen.hs` (TargetRust path only)

Shared classifier `byteSeqKind :: String -> Maybe ByteSeqKind` with variants
`Slice` (`&[u8]`), `OwnedVec` (`Vec<u8>`), `OwnedArr Int` (`[u8; N]`),
`RefArr Int` (`&[u8; N]`); `N` parsed from the type string.

**Parameters (`argCall`).** Wrapper param type is `Vec<i64>` (sky `List Int`).
New cases, checked before the String/numeric cases:

| Raw param type | Emitted arg |
|---|---|
| `&[u8]` | `&sky_runtime::core::to_u8_vec(&argN)` (temp `Vec<u8>` lives for the call; `&Vec<u8>` derefs to `&[u8]`) |
| `Vec<u8>` | `sky_runtime::core::to_u8_vec(&argN)` |
| `[u8; N]` | refers to body-prelude local `bN` |
| `&[u8; N]` | refers to body-prelude local `&bN` |

**Fixed-array params force a body prelude.** When a function has any
`[u8; N]`/`&[u8; N]` param, `emitRustFnSimple` prepends `let` bindings and the
body stays a valid block returning the wrapper type:

```rust
pub fn somecrate_from_bytes(arg0: Vec<i64>) -> SkyResult<SkyError, somecrate::Uuid> {
    let b0: [u8; 16] = match sky_runtime::core::to_u8_array::<SkyError, 16>(&arg0) {
        SkyResult::Ok(a) => a,
        SkyResult::Err(e) => return SkyResult::Err(e),
    };
    ok_res(somecrate::Uuid::from_bytes(b0))
}
```

This is the one structural addition: an optional list of prelude `let` lines
prepended to the body; the call uses `bN`/`&bN` for fixed-array args. Slice /
`Vec<u8>` params and all results need no prelude.

**Results (`translateRustRet`).** A byte-sequence branch *before* the generic
`&`/`Vec`/opaque handling: declared inner type is `Vec<i64>`; lift is
`sky_runtime::core::from_u8_slice(&e)` for owned `[u8; N]`/`Vec<u8>`, or
`from_u8_slice(e)` for `&[u8]`/`&[u8; N]` (they deref to `&[u8]`). So
`uuid.as_bytes() -> &[u8; 16]` yields `List Int`.

### 4. Examples

- **`examples/rust/14-crc32fast`** — slice param + primitive result:
  `Crc32fast.hash [104, 105, …]` → `Result Error Int`.
- **`examples/rust/15-uuid-bytes`** — fixed-array param + byte-array result
  round-trip: `Uuid.from_bytes_from_uuid <16 ints>` → `Uuid`, then
  `Uuid.as_bytes_from_uuid u` → `List Int`. Exercises the `to_u8_array` Ok path
  and `from_u8_slice` on a `&[u8; 16]` result.

Binding names confirmed against the generated `.skyi` during implementation (as
for 04–13). If `uuid`'s byte methods don't surface cleanly, fall back to a
second slice-based crate (`hex` or `sha2`) for the second example.

## Testing

- **runtime-rust proptests** (cargo): `from_u8_slice(&to_u8_vec(xs))` preserves
  in-range `[0,255]` values; `to_u8_array::<_, N>` returns `Ok` iff `len == N`,
  `Err` otherwise, never panics.
- **Integration:** new examples build + run from a clean slate
  (`rm -rf sky-out .skycache .skydeps && sky add … && sky run`).
- **Regression:** all 13 existing `examples/rust/*` still build + run; Go
  `examples/01-hello-world` still builds (shared-file guard).

## Boundaries / cross-backend rules

- Changes confined to `tools/sky-ffi-inspect-rs/`,
  `runtime-rust/src/sky_runtime/core.rs` (additive), and the `TargetRust` emit
  path in `src/Sky/Build/FfiGen.hs`.
- No `TargetGo` bytes change; no `runtime-go/`, `src/Sky/Generate/Go/`, or root
  `.skycache/ffi/*` touched.
- Each inspector edit needs a `cabal build` so Template Haskell re-embeds the
  inspector, then `cabal install` to refresh `sky-out/sky` (same loop as the
  prior FFI work).
