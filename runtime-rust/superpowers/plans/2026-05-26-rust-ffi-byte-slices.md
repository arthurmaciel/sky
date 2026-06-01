# Rust FFI Byte Slice/Array Params & Results — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Sky bind Rust functions that take or return a read-only byte sequence (`&[u8]`, `Vec<u8>`, `[u8; N]`, `&[u8; N]`), represented Sky-side as `List Int`, so hashing/encoding crates work end-to-end.

**Architecture:** Three small coercion helpers live in `sky_runtime/core.rs`; the rustdoc-JSON inspector stops dropping byte-sequence functions and maps them to `List Int`; `FfiGen.hs` (Rust emit path only) emits thin coercion calls and, for fixed-array params, a body prelude that converts `List Int → [u8; N]` and returns `Err` on length mismatch (never panics).

**Tech Stack:** Rust (inspector + runtime crate, `cargo`/`proptest`), Haskell/GHC (`FfiGen.hs`, `cabal`), Sky example programs.

**Spec:** `docs/superpowers/specs/2026-05-26-rust-ffi-byte-slices-design.md`

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `runtime-rust/src/sky_runtime/core.rs` | Runtime primitives | **Modify** — add `to_u8_vec`, `from_u8_slice`, `to_u8_array` |
| `runtime-rust/tests/proptest.rs` | Runtime property tests | **Modify** — add byte-helper proptests |
| `tools/sky-ffi-inspect-rs/src/main.rs` | rustdoc-JSON inspector | **Modify** — `is_byte_seq`, relax 2 filters, array→`List Int` mapping, unit test |
| `src/Sky/Build/FfiGen.hs` | Rust FFI wrapper codegen (TargetRust path) | **Modify** — `byteSeqKind`, `argCall`, `translateRustRet`, body-prelude |
| `examples/rust/14-crc32fast/{sky.toml,src/Main.sky}` | Slice-param demo | **Create** |
| `examples/rust/15-uuid-bytes/{sky.toml,src/Main.sky}` | Fixed-array param + byte result demo | **Create** |

**Build/verify loop reminder:** inspector (Rust) edits require a `cabal build exe:sky` so Template Haskell re-embeds the inspector, then `cabal install … exe:sky` to refresh `sky-out/sky`, then `rm -rf ~/.cache/sky/tools/sky-ffi-inspect-rs` so the new inspector materialises. This plan does that **once** in Task 4 (after Tasks 1-3 land the code).

---

## Task 1: Runtime byte-coercion helpers

**Files:**
- Modify: `runtime-rust/src/sky_runtime/core.rs` (add three `pub fn` near `str_err`, after line ~20)
- Test: `runtime-rust/tests/proptest.rs` (append a `proptest!` block)

- [ ] **Step 1: Write the failing proptests**

Append to `runtime-rust/tests/proptest.rs` (the file already has `use sky_runtime_rust::*;` and `use proptest::prelude::*;` at the top):

```rust
// ═══════════════════════════════════════════════════════════════════
// Byte-sequence FFI coercion helpers
// ═══════════════════════════════════════════════════════════════════

proptest! {
    // to_u8_vec then widen back is identity on in-range bytes.
    #[test]
    fn byte_vec_roundtrip(xs in proptest::collection::vec(0u8..=255, 0..64)) {
        let as_i64: Vec<i64> = xs.iter().map(|&b| b as i64).collect();
        prop_assert_eq!(to_u8_vec(&as_i64), xs.clone());
        prop_assert_eq!(from_u8_slice(&xs), as_i64);
    }

    // to_u8_array succeeds iff the input length matches N; never panics.
    #[test]
    fn to_u8_array_len_checked(xs in proptest::collection::vec(0i64..256, 0..40)) {
        let r: SkyResult<String, [u8; 16]> = to_u8_array(&xs);
        if xs.len() == 16 {
            prop_assert!(r.is_ok());
        } else {
            prop_assert!(r.is_err());
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd runtime-rust && cargo test --test proptest byte_vec_roundtrip to_u8_array_len_checked 2>&1 | tail -20`
Expected: compile error — `cannot find function 'to_u8_vec'` (and `from_u8_slice`, `to_u8_array`) in scope.

- [ ] **Step 3: Implement the three helpers**

In `runtime-rust/src/sky_runtime/core.rs`, immediately after the `str_err` function (around line 20), add:

```rust
// ===========================================
// Byte-sequence FFI coercion (Sky List Int <-> Rust bytes)
// ===========================================

/// Sky `List Int` (Vec<i64>) -> owned bytes. Each element is narrowed `as u8`,
/// mirroring the numeric param narrowing the FFI codegen already emits.
/// Used for `&[u8]` and `Vec<u8>` parameters.
pub fn to_u8_vec(xs: &[i64]) -> Vec<u8> {
    xs.iter().map(|&x| x as u8).collect()
}

/// Owned/borrowed bytes -> Sky `List Int` (Vec<i64>). Used for byte results.
pub fn from_u8_slice(bs: &[u8]) -> Vec<i64> {
    bs.iter().map(|&b| b as i64).collect()
}

/// Sky `List Int` -> `[u8; N]`. A length mismatch returns `Err` and never
/// panics (honours "no runtime panic from well-typed Sky code"). Used for
/// `[u8; N]` / `&[u8; N]` parameters; the generated wrapper instantiates
/// `E = SkyError` and the concrete `N`.
pub fn to_u8_array<E: From<String>, const N: usize>(xs: &[i64]) -> SkyResult<E, [u8; N]> {
    if xs.len() != N {
        return SkyResult::Err(format!("expected {} bytes, got {}", N, xs.len()).into());
    }
    let mut a = [0u8; N];
    for (i, &x) in xs.iter().enumerate() {
        a[i] = x as u8;
    }
    ok_res(a)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd runtime-rust && cargo test --test proptest byte_vec_roundtrip to_u8_array_len_checked 2>&1 | tail -8`
Expected: `test result: ok. 2 passed`.

- [ ] **Step 5: Commit**

```bash
git add runtime-rust/src/sky_runtime/core.rs runtime-rust/tests/proptest.rs
git commit -m "feat(rust): byte-coercion runtime helpers (to_u8_vec, from_u8_slice, to_u8_array)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: Inspector — detect byte sequences, relax filters, map to List Int

**Files:**
- Modify: `tools/sky-ffi-inspect-rs/src/main.rs` (helper + 2 filters + array mapping + unit test)

- [ ] **Step 1: Write the failing unit test**

In `tools/sky-ffi-inspect-rs/src/main.rs`, inside the existing `#[cfg(test)] mod tests { … }` block (near the end of the file), add:

```rust
#[test]
fn test_is_byte_seq() {
    assert!(is_byte_seq("&[u8]"));
    assert!(is_byte_seq("Vec<u8>"));
    assert!(is_byte_seq("[u8; 16]"));
    assert!(is_byte_seq("&[u8; 32]"));
    // Not byte sequences:
    assert!(!is_byte_seq("&mut [u8]"));
    assert!(!is_byte_seq("&[u16]"));
    assert!(!is_byte_seq("[f64; 3]"));
    assert!(!is_byte_seq("Vec<i64>"));
    assert!(!is_byte_seq("&str"));
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd tools/sky-ffi-inspect-rs && cargo test test_is_byte_seq 2>&1 | tail -10`
Expected: compile error — `cannot find function 'is_byte_seq' in this scope`.

- [ ] **Step 3: Add the `is_byte_seq` helper**

In `tools/sky-ffi-inspect-rs/src/main.rs`, add this free function next to the other type helpers (e.g. just above `fn has_lifetime`):

```rust
/// True for a read-only byte sequence: `&[u8]`, `Vec<u8>`, `[u8; N]`, or
/// `&[u8; N]` (N = literal digits). Excludes `&mut [u8]` and non-u8 elements.
fn is_byte_seq(rt: &str) -> bool {
    let t = rt.trim();
    if t == "Vec<u8>" || t == "&[u8]" {
        return true;
    }
    // [u8; N] or &[u8; N] (the leading & has no `mut`, since &mut is excluded)
    let body = t.strip_prefix('&').unwrap_or(t).trim();
    if let Some(rest) = body.strip_prefix("[u8;") {
        if let Some(inner) = rest.strip_suffix(']') {
            let n = inner.trim();
            return !n.is_empty() && n.chars().all(|c| c.is_ascii_digit());
        }
    }
    false
}
```

- [ ] **Step 4: Run the unit test to verify it passes**

Run: `cd tools/sky-ffi-inspect-rs && cargo test test_is_byte_seq 2>&1 | tail -6`
Expected: `test result: ok. 1 passed`.

- [ ] **Step 5: Relax the array/slice filter**

In `parse_fn_item`, find the existing block:

```rust
    let has_array_or_slice = params
        .iter()
        .chain(results.iter())
        .any(|p| p.rust_type.contains('['));
    if has_array_or_slice {
        return None;
    }
```

Replace it with (drop only NON-byte arrays/slices):

```rust
    let has_bad_array_or_slice = params
        .iter()
        .chain(results.iter())
        .any(|p| p.rust_type.contains('[') && !is_byte_seq(&p.rust_type));
    if has_bad_array_or_slice {
        return None;
    }
```

- [ ] **Step 6: Relax the borrowed-result filter**

In `parse_fn_item`, find:

```rust
    let result_borrows = results.iter().any(|p| {
        let rt = p.rust_type.trim();
        rt.contains('&') && rt != "&str" && rt != "&String"
    });
    if result_borrows {
        return None;
    }
```

Replace the closure body to also exempt byte sequences:

```rust
    let result_borrows = results.iter().any(|p| {
        let rt = p.rust_type.trim();
        rt.contains('&') && rt != "&str" && rt != "&String" && !is_byte_seq(rt)
    });
    if result_borrows {
        return None;
    }
```

- [ ] **Step 7: Map byte arrays to `List Int`**

In `rustdoc_type_to_sky`, find the array branch:

```rust
    if let Some(arr) = val.get("array") {
        let inner = rustdoc_type_to_sky(inner_type(arr), aliases);
        // [u8; N] → Bytes, other fixed arrays → List T
        return if inner == "Int" {
            "Bytes".to_string()
        } else {
            format!("List {}", inner)
        };
    }
```

Replace with (no `"Bytes"` special-case — byte arrays become `List Int` like slices):

```rust
    if let Some(arr) = val.get("array") {
        let inner = rustdoc_type_to_sky(inner_type(arr), aliases);
        // Fixed arrays surface as `List T`; `[u8; N]` -> `List Int`, matching
        // slices and Vec<u8>. The real Rust shape is preserved in rust_type.
        return format!("List {}", inner);
    }
```

- [ ] **Step 8: Run the inspector test suite + eyeball a byte crate**

Run: `cd tools/sky-ffi-inspect-rs && cargo build --release 2>&1 | tail -2 && cargo test 2>&1 | tail -6`
Expected: build OK; all tests pass.

Run: `./target/release/sky-ffi-inspect-rs crc32fast 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print([(f['name'], [p.get('rustType') for p in f['params']]) for f in d['functions'] if f['name'] in ('hash','update')])"`
Expected: `hash` now appears with a `&[u8]` param (it was previously dropped): `[('hash', ['&[u8]']), ('update', ['&[u8]'])]` (or similar — `update` is a `Hasher` method).

- [ ] **Step 9: Commit**

```bash
git add tools/sky-ffi-inspect-rs/src/main.rs
git commit -m "feat(rust): inspector keeps byte-sequence FFI fns, maps them to List Int

is_byte_seq() recognizes &[u8] / Vec<u8> / [u8;N] / &[u8;N]; the array/slice and
borrowed-result drop-filters now exempt byte sequences; byte arrays map to
List Int (real shape kept in rust_type).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: FfiGen — byte coercion in params, results, and fixed-array prelude

**Files:**
- Modify: `src/Sky/Build/FfiGen.hs` (TargetRust emit path: `byteSeqKind` helper, `argCall`, `translateRustRet`, body emission in `emitRustFnSimple`)

This task has no standalone unit test (codegen is verified by the integration examples in Tasks 4-5). Implement, then it is built and exercised in Task 4.

- [ ] **Step 1: Ensure `isDigit` is imported**

At the top of `src/Sky/Build/FfiGen.hs`, the import is:

```haskell
import Data.Char (isAlphaNum, isLower, isUpper, toUpper, toLower)
```

Change it to add `isDigit`:

```haskell
import Data.Char (isAlphaNum, isDigit, isLower, isUpper, toUpper, toLower)
```

- [ ] **Step 2: Add the `byteSeqKind` classifier**

In `src/Sky/Build/FfiGen.hs`, add near `translateRustRet` (it uses `trimStr`, already defined in this module):

```haskell
-- | Classification of a read-only byte-sequence Rust type.
data ByteKind = BSlice | BVec | BArr Int | BRefArr Int

-- | Classify a raw Rust type as a byte sequence (mirrors the inspector's
-- is_byte_seq). N is parsed from `[u8; N]` / `&[u8; N]`.
byteSeqKind :: String -> Maybe ByteKind
byteSeqKind raw =
    case trimStr raw of
        "&[u8]"   -> Just BSlice
        "Vec<u8>" -> Just BVec
        s -> case arrN "&[u8; " s of
               Just n  -> Just (BRefArr n)
               Nothing -> BArr <$> arrN "[u8; " s
  where
    arrN pfx s = do
        rest <- stripPrefix pfx s
        case span (/= ']') rest of
            (digits, "]") | not (null digits) && all isDigit digits -> Just (read digits)
            _ -> Nothing
```

- [ ] **Step 3: Handle byte params in `argCall`**

In `emitRustFnSimple`, find the current `argCall`:

```haskell
            argCall j =
                let rawTy  = if j < nRawRustParam then rawRustParamTypes !! j else ""
                    declTy = paramTypes !! j
                    base   = arg j
                in if declTy == "String"
                   then "&" ++ base          -- Sky String → &str
                   else if null rawTy || rawTy == declTy
                   then base                 -- same type, pass through
                   else if isNumericRust rawTy && (declTy == "i64" || declTy == "f64")
                   then base ++ " as " ++ rawTy   -- narrowing cast (e.g. i64 → u32)
                   else base                 -- opaque: pass through unchanged
```

Replace it with (byte cases first; fixed-array args reference the prelude local `bN`):

```haskell
            argCall j =
                let rawTy  = if j < nRawRustParam then rawRustParamTypes !! j else ""
                    declTy = paramTypes !! j
                    base   = arg j
                in case byteSeqKind rawTy of
                    Just BSlice      -> "&to_u8_vec(&" ++ base ++ ")"
                    Just BVec        -> "to_u8_vec(&" ++ base ++ ")"
                    Just (BArr _)    -> "b" ++ show j        -- prelude local (owned)
                    Just (BRefArr _) -> "&b" ++ show j       -- prelude local (by ref)
                    Nothing ->
                        if declTy == "String"
                        then "&" ++ base          -- Sky String → &str
                        else if null rawTy || rawTy == declTy
                        then base                 -- same type, pass through
                        else if isNumericRust rawTy && (declTy == "i64" || declTy == "f64")
                        then base ++ " as " ++ rawTy   -- narrowing cast (e.g. i64 → u32)
                        else base                 -- opaque: pass through unchanged
```

- [ ] **Step 4: Handle byte results in `translateRustRet`**

In `translateRustRet`, find the opening:

```haskell
translateRustRet raw0 =
    let raw = trimStr raw0 in
    if raw == "" || raw == "()" then ("()", id)
    else case stripGeneric1 "Option" raw of
```

Insert a byte-sequence branch between the unit check and the `Option` case:

```haskell
translateRustRet raw0 =
    let raw = trimStr raw0 in
    if raw == "" || raw == "()" then ("()", id)
    else case byteSeqKind raw of
      Just bk ->
        ( "Vec<i64>"
        , \e -> case bk of
            BVec      -> "from_u8_slice(&" ++ e ++ ")"
            BArr _    -> "from_u8_slice(&" ++ e ++ ")"
            BSlice    -> "from_u8_slice(" ++ e ++ ")"
            BRefArr _ -> "from_u8_slice(" ++ e ++ ")" )
      Nothing -> case stripGeneric1 "Option" raw of
```

(The rest of the `Option`/`Vec`/numeric/opaque cases stay exactly as they are — only the `case stripGeneric1 "Option" raw of` line is now reached via the `Nothing ->` arm. Keep the existing body verbatim under that arm.)

- [ ] **Step 5: Emit the fixed-array body prelude**

In `emitRustFnSimple`, find the final emission block:

```haskell
        in if isDegenerateMethod || ((isInstance || isStaticFn) && hasGenericRecvParam)
           then []
           else [ "// [" ++ _fnEffect fn ++ "] " ++ wrapper
                , "pub fn " ++ rustName ++ "(" ++ paramDecl ++ ") -> " ++ retType ++ " {"
                , "    " ++ body
                , "}"
                ]
```

Replace it with (inserting the per-fixed-array-param `let` prelude before the body):

```haskell
            -- Fixed-array byte params (`[u8; N]` / `&[u8; N]`) need a fallible
            -- conversion from Sky `List Int`; bind each to a local `bN` and
            -- early-return Err on a length mismatch (no panic).
            arrPrelude =
                [ "let b" ++ show j ++ ": [u8; " ++ show n ++ "] = "
                  ++ "match to_u8_array::<SkyError, " ++ show n
                  ++ ">(&arg" ++ show j ++ ") { SkyResult::Ok(a) => a, "
                  ++ "SkyResult::Err(e) => return SkyResult::Err(e), };"
                | j <- [0 .. nParams - 1]
                , let rawTy = if j < nRawRustParam then rawRustParamTypes !! j else ""
                , n <- case byteSeqKind rawTy of
                         Just (BArr m)    -> [m]
                         Just (BRefArr m) -> [m]
                         _                -> []
                ]
        in if isDegenerateMethod || ((isInstance || isStaticFn) && hasGenericRecvParam)
           then []
           else [ "// [" ++ _fnEffect fn ++ "] " ++ wrapper
                , "pub fn " ++ rustName ++ "(" ++ paramDecl ++ ") -> " ++ retType ++ " {"
                ]
                ++ map ("    " ++) arrPrelude
                ++ [ "    " ++ body
                   , "}"
                   ]
```

- [ ] **Step 6: Compile the Haskell to verify it type-checks**

Run: `cabal build exe:sky 2>&1 | grep -iE "error:|rror:" | head` (expect no output — only the build proceeds)
Expected: no `error:` lines. (Warnings about pre-existing defaulting are fine.)

- [ ] **Step 7: Commit**

```bash
git add src/Sky/Build/FfiGen.hs
git commit -m "feat(rust): FfiGen byte coercion — List Int <-> &[u8]/Vec<u8>/[u8;N]

argCall emits to_u8_vec for slice/vec params; fixed-array params get a body
prelude binding via to_u8_array (Err on length mismatch); translateRustRet
maps byte-sequence results back to List Int via from_u8_slice.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: Rebuild toolchain + slice-param example (14-crc32fast)

**Files:**
- Create: `examples/rust/14-crc32fast/sky.toml`
- Create: `examples/rust/14-crc32fast/src/Main.sky`

- [ ] **Step 1: Rebuild the inspector binary, recompile + install the compiler**

The inspector source changed (Task 2), so Template Haskell must re-embed it.

```bash
cd /home/arthur/Documentos/comp/sky
(cd tools/sky-ffi-inspect-rs && cargo build --release 2>&1 | tail -1)
touch tools/sky-ffi-inspect-rs/target/release/sky-ffi-inspect-rs
cabal install --overwrite-policy=always --installdir=./sky-out --install-method=copy exe:sky 2>&1 | tail -1
rm -rf ~/.cache/sky/tools/sky-ffi-inspect-rs
./sky-out/sky --version
```
Expected: prints `sky dev`.

- [ ] **Step 2: Create the example project files**

`examples/rust/14-crc32fast/sky.toml`:

```toml
[project]
name = "14-crc32fast"
version = "0.1.0"
entry = "src/Main.sky"
target = "rust"

["rust.dependencies"]
crc32fast = "1"
```

`examples/rust/14-crc32fast/src/Main.sky`:

```elm
module Main exposing (main)

-- CRC32 over a byte slice via the `crc32fast` crate — fully automatic FFI.
-- `crc32fast::hash` takes `&[u8]`; Sky passes a `List Int` (auto-coerced).
--
-- Run:  sky run src/Main.sky --target rust

import Sky.Core.Prelude exposing (..)
import Std.Log exposing (println)
import Rust.Crc32fast as Crc32fast

main =
    case Crc32fast.hash [104, 105] of
        Ok checksum ->
            println ("CRC32 of \"hi\" = " ++ String.fromInt checksum)
        Err _ ->
            println "hash failed"
```

- [ ] **Step 3: Generate bindings and confirm the `hash` binding exists**

```bash
cd examples/rust/14-crc32fast
rm -rf sky-out .skycache .skydeps
../../../sky-out/sky add crc32fast --target rust 2>&1 | grep -i generated
grep -E "^hash " .skycache/ffi/rust/crc32fast.skyi
```
Expected: a "Generated … bindings" line, and `hash : List Int -> Result Error Int`.
(If the binding name differs, use the exact name from the `.skyi` in Step 2's Main.sky and regenerate.)

- [ ] **Step 4: Build and run — verify the slice param works**

Run: `cd examples/rust/14-crc32fast && ../../../sky-out/sky run src/Main.sky 2>&1 | tail -2`
Expected: `Build complete, running...` then a line `CRC32 of "hi" = <number>` (a non-error integer; crc32fast hashing succeeded over the coerced bytes).

- [ ] **Step 5: Commit**

```bash
cd /home/arthur/Documentos/comp/sky
git add examples/rust/14-crc32fast/sky.toml examples/rust/14-crc32fast/src/Main.sky
git commit -m "test(rust): 14-crc32fast example — &[u8] slice param via List Int

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: Fixed-array param + byte-array result example (15-uuid-bytes)

**Files:**
- Create: `examples/rust/15-uuid-bytes/sky.toml`
- Create: `examples/rust/15-uuid-bytes/src/Main.sky`

- [ ] **Step 1: Create the example project files**

`examples/rust/15-uuid-bytes/sky.toml`:

```toml
[project]
name = "15-uuid-bytes"
version = "0.1.0"
entry = "src/Main.sky"
target = "rust"

["rust.dependencies"]
uuid = "1"
```

`examples/rust/15-uuid-bytes/src/Main.sky`:

```elm
module Main exposing (main)

-- UUID byte round-trip via the `uuid` crate — fully automatic FFI.
-- `Uuid::from_bytes` takes `[u8; 16]` (fixed array, length-checked → Err);
-- `Uuid::as_bytes` returns `&[u8; 16]`. Both cross as Sky `List Int`.
--
-- Run:  sky run src/Main.sky --target rust

import Sky.Core.Prelude exposing (..)
import Std.Log exposing (println)
import Rust.Uuid as Uuid

main =
    case Uuid.from_bytes_from_uuid [0, 17, 34, 51, 68, 85, 102, 119, 136, 153, 170, 187, 204, 221, 238, 255] of
        Ok u ->
            case Uuid.as_bytes_from_uuid u of
                Ok bytes ->
                    case bytes of
                        first :: _ ->
                            println ("UUID byte round-trip OK, first byte = " ++ String.fromInt first)
                        [] ->
                            println "UUID byte round-trip OK (empty)"
                Err _ ->
                    println "as_bytes failed"
        Err _ ->
            println "from_bytes failed"
```

- [ ] **Step 2: Generate bindings and confirm the exact binding names**

```bash
cd examples/rust/15-uuid-bytes
rm -rf sky-out .skycache .skydeps
../../../sky-out/sky add uuid --target rust 2>&1 | grep -i generated
grep -E "from_bytes_from_uuid|as_bytes_from_uuid" .skycache/ffi/rust/uuid.skyi
```
Expected: `from_bytes_from_uuid : List Int -> Result Error Uuid` and `as_bytes_from_uuid : Uuid -> Result Error (List Int)`.
(If names differ — e.g. a different receiver suffix — update Main.sky in Step 1 to match the `.skyi` and regenerate. The `_from_uuid` suffix comes from the `Uuid` receiver type.)

- [ ] **Step 3: Verify the generated wrapper has the fixed-array prelude**

Run: `grep -A3 "fn uuid_from_bytes_from_uuid" sky-out/Rust/src/uuid_bindings.rs`
Expected: a `let b0: [u8; 16] = match to_u8_array::<SkyError, 16>(&arg0) { … };` prelude line, then `ok_res(... Uuid::from_bytes(b0))`.

- [ ] **Step 4: Build and run — verify fixed-array param + byte result**

Run: `cd examples/rust/15-uuid-bytes && ../../../sky-out/sky run src/Main.sky 2>&1 | tail -2`
Expected: `Build complete, running...` then `UUID byte round-trip OK, first byte = 0`.

(If Sky list cons-patterns aren't supported on the Rust target, the build will error at the `first :: _` pattern; in that case replace the inner `case bytes of …` with `println "UUID byte round-trip OK"` and re-run. This is the only fallback needed.)

- [ ] **Step 5: Commit**

```bash
cd /home/arthur/Documentos/comp/sky
git add examples/rust/15-uuid-bytes/sky.toml examples/rust/15-uuid-bytes/src/Main.sky
git commit -m "test(rust): 15-uuid-bytes example — [u8;16] param + &[u8;16] result via List Int

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 6: Regression sweep

**Files:** none (verification only)

- [ ] **Step 1: Rebuild all 13 existing Rust FFI examples from a clean slate**

```bash
cd /home/arthur/Documentos/comp/sky/examples/rust
SKY_BIN=$(pwd)/../../sky-out/sky
run_ex() { d=$1; crate=$2; feat=$3
  cd /home/arthur/Documentos/comp/sky/examples/rust/$d
  rm -rf sky-out .skycache .skydeps
  if [ -n "$feat" ]; then $SKY_BIN add "$crate" --target rust --features "$feat" >/dev/null 2>&1; else $SKY_BIN add "$crate" --target rust >/dev/null 2>&1; fi
  out=$(timeout 250 $SKY_BIN run src/Main.sky 2>&1)
  if echo "$out" | grep -q "Build complete, running"; then echo "[$d] OK -> $(echo "$out" | tail -1)"
  else echo "[$d] FAIL: $(echo "$out" | grep -E 'error\[E[0-9]+\]|could not compile' | head -1)"; fi
}
run_ex 01-rand rand;          run_ex 02-num-cpus num_cpus;  run_ex 03-chrono chrono
run_ex 04-uuid uuid v4;       run_ex 05-roman roman;        run_ex 06-lipsum lipsum
run_ex 07-deunicode deunicode;run_ex 08-semver semver;      run_ex 09-bytesize bytesize
run_ex 10-titlecase titlecase;run_ex 11-fastrand fastrand;  run_ex 12-ulid ulid
run_ex 13-petname petname
```
Expected: every line prints `[NN-name] OK -> <output>` (no FAIL).

- [ ] **Step 2: Confirm the Go backend is untouched**

Run: `cd /home/arthur/Documentos/comp/sky/examples/01-hello-world && rm -rf sky-out .skycache .skydeps && ../../sky-out/sky build src/Main.sky 2>&1 | tail -1`
Expected: `Build complete: sky-out/app`.

- [ ] **Step 3: Run the full runtime-rust test suite once more**

Run: `cd /home/arthur/Documentos/comp/sky/runtime-rust && cargo test 2>&1 | tail -5`
Expected: all tests pass (including the new byte-helper proptests).

- [ ] **Step 4: No commit needed** (verification only). If any example regressed, fix the root cause before considering the feature complete.

---

## Done criteria

- `to_u8_vec` / `from_u8_slice` / `to_u8_array` exist with passing proptests.
- The inspector keeps byte-sequence functions and maps them to `List Int`.
- `FfiGen` emits coercion for byte params (slice/vec/fixed-array) and byte results.
- `14-crc32fast` and `15-uuid-bytes` build and run with the expected output.
- All 13 prior Rust examples still pass; Go `01-hello-world` still builds.
