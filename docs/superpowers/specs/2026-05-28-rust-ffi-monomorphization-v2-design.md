# Rust FFI — monomorphization-on-demand v2 (paired) — Design

**Date:** 2026-05-28
**Status:** Approved (brainstorming) — ready for implementation plan
**Scope:** Rust-target only. Thin seam preserved.
**Branch:** `feat/runtime-rust`
**Builds on:** Alt-1 v1 spec `docs/superpowers/specs/2026-05-27-rust-ffi-monomorphization-design.md` (commits `71853189..6085db43`, all pushed to origin).

---

## 1. Problem

Alt-1 v1 shipped bound-directed monomorphization for **byte and string** generic
surfaces: `AsRef/Borrow<[u8]>` / `Into<Vec<u8>>` / `IntoIterator<Item=u8>` →
`Vec<u8>` (Sky `List Int`), and `AsRef/Borrow<str>` / `Into<String>` /
`Display` / `ToString` → `String`. The `/ffi-audit` 50-crate sweep showed
**exactly one tier flip** afterwards: `hex` `peripheral → usable`. Most other
generic-fronted crates still drop, for two reasons:

1. **The v1 bound table is too narrow.** Crates like `itoa`/`ryu` use
   `num_traits::Integer`/`Float`; many builders use `Into<u32>`/`Into<u64>`;
   `walkdir`-shaped APIs use `AsRef<Path>`. None match the v1 table.
2. **The unconditional non-byte slice/array drop** at
   `tools/sky-ffi-inspect-rs/src/main.rs:707` discards every function whose
   `rust_type` contains `[` unless it's a byte sequence. So `&[String]`,
   `[f64; 3]`, `&[T]` for any non-`u8` `T` are all dropped — even when the
   element type is trivially Sky-representable.

Additionally, v1's `bound_to_concrete` matched inner types **literally**
(`AsRef<[u8]>`, `AsRef<str>`), missing compositions like
`IntoIterator<Item=impl AsRef<str>>` that *would* resolve if the table were
recursive.

## 2. Goal

Broaden Alt-1's recovered surface by:

- **Extending the bound table** with the next high-value entries (paths, numeric
  `Into`, `num_traits::Integer`/`Float`).
- **Making the table recursive** so `AsRef<X>` / `Into<X>` / `IntoIterator<Item=X>`
  resolve any inner `X` the table can map — composition unlocked without
  combinatorial table growth.
- **Lifting the non-byte slice/array drop** when the element type is
  Sky-coercible, with the minimum FfiGen + runtime generalization needed to
  emit correct param/result coercion for the new shapes.

The soundness invariant is preserved unchanged: the inspector may only ever
**add** compilable bindings. Anything unresolvable still drops. `_bindings.rs`
always compiles.

## 3. Non-goals (explicit)

Carried over from v1 and **restated** so this spec is self-contained:

- **No cross-crate trait resolution.** `sha2`/`md-5` (`Digest` trait + blanket
  impl in the `digest` crate) stay at 0 — that's the deferred sub-feature
  requiring a partial trait-solver over multi-crate rustdoc.
- **No generic-type/container instantiation.** `IndexMap<K, V>`,
  `SmallVec<[T; N]>`, `ArrayVec<T, N>`: the type itself is generic; that's
  type-level monomorphization, a distinct subsystem.
- **No `&mut [T]` out-param write-back.** Buffer-fill APIs (e.g.
  `fastrand::fill`) remain dropped.
- **No per-call-site monomorphization.** One canonical instantiation per fn.
- **No `TryInto` / fallible bounds.** Caller-side fallibility needs return-type
  surgery; out of v2 scope.
- **Go backend untouched.** Cross-backend rule 5 preserved.

## 4. Verified rustdoc / codegen / runtime shapes (grounded)

From the v1 implementation work and re-verified in this session:

- **Filter to lift (`main.rs:708-713`):**
  ```rust
  let has_bad_array_or_slice = params.iter().chain(results.iter())
      .any(|p| p.rust_type.contains('[') && !is_byte_seq(&p.rust_type));
  if has_bad_array_or_slice { return None; }
  ```
- **Borrowed-result filter (`main.rs:698`):** exempts `&str`, `&String`, and
  byte sequences. Will be generalized.
- **FFI codegen lives in `src/Sky/Build/Rust/Ffi.hs`** (post-thin-seam refactor —
  Rust-only; `FfiGen.hs` upstream-shared is not touched). Key surface:
  ```haskell
  data ByteKind = BSlice | BVec | BArr Int | BRefArr Int
  byteSeqKind :: String -> Maybe ByteKind   -- pattern-match on rust_type string
  -- argCall emit arms (line ~440) and translateRustRet emit arms (line ~271)
  -- branch on Just BSlice/BVec/BArr/BRefArr.
  ```
- **Runtime byte helpers (`runtime-rust/src/sky_runtime/core.rs`):**
  ```rust
  pub fn to_u8_vec(xs: &[i64]) -> Vec<u8>                                    // line 29
  pub fn from_u8_slice(bs: &[u8]) -> Vec<i64>                                // line 34
  pub fn to_u8_array<E: From<String>, const N: usize>(xs: &[i64])
      -> SkyResult<E, [u8; N]>                                                // line 42
  ```
- **Sky's runtime representation of `List T` is `Vec<T>`** with the Sky-native
  element type (`List Int`/`Float`/`Bool` → `Vec<i64>`/`Vec<f64>`/`Vec<bool>`;
  `List String` → `Vec<String>`; `List <opaque>` → `Vec<opaque>`). Consequence:
  for non-byte slice/array shapes, **no inter-type element conversion is
  needed** — the param is already `Vec<T>` matching the Rust shape modulo
  borrow form. Only the borrow/array adaptation needs emitting.

## 5. Design — four parts

All changes are inside three Rust-only allowed dirs. Shared upstream-merge files
(`FfiGen.hs`, `Compile.hs`, `Builder.hs`, Go) are untouched.

### 5.1 — Part A: bound table (recursive + new entries)

Refactor `bound_to_concrete` to delegate inner-type resolution to a new helper:

```rust
/// Map an INNER TYPE NODE (the X in AsRef<X> / Into<X> / IntoIterator<Item=X>)
/// to its canonical Sky-coercible concrete type-JSON, or None if X isn't
/// representable in Sky. Recursive: handles primitives, paths, slices,
/// nested generics.
fn concrete_for_inner_type(t: &serde_json::Value) -> Option<serde_json::Value>;
```

Then `bound_to_concrete`'s arms become:

| Bound | Resolution |
|---|---|
| `AsRef<X>` / `Borrow<X>` | `concrete_for_inner_type(X)` |
| `Into<X>` / `From<X>` | `concrete_for_inner_type(X)` |
| `IntoIterator` with `Item = X` constraint | wrap result as `Vec<X'>` where `X' = concrete_for_inner_type(X)` |
| `Display` / `ToString` (no inner) | `string_node()` |
| `num_traits::Integer` / `num::Integer` (last segment "Integer") | `i64_node()` |
| `num_traits::Float` (last segment "Float") | `f64_node()` |
| (else) | `None` |

`concrete_for_inner_type` recognizes:

| Inner T (rustdoc node shape) | concrete | Sky |
|---|---|---|
| `{primitive:"u8"}` | `u8` (path or primitive node) | `Int` |
| `{slice:{primitive:"u8"}}` (`[u8]`) | `Vec<u8>` | `List Int` |
| `{primitive:"str"}` | `&str` or `String` (pick String for owned) | `String` |
| `{borrowed_ref:{type:{primitive:"str"}}}` (`&str`) | `String` | `String` |
| `{resolved_path: name "String"}` | `String` | `String` |
| `{resolved_path: name "Vec", args:[u8]}` | `Vec<u8>` | `List Int` |
| `{resolved_path: name "PathBuf"}` | `String` | `String` (Linux pragma) |
| `{resolved_path: name "Path"}` (or `&Path`) | `String` | `String` |
| `{resolved_path: name "OsStr"/"OsString"}` (or `&OsStr`) | `String` | `String` |
| `{primitive:"i32"/"i64"/"u32"/"u64"/"usize"/"isize"}` | the integer | `Int` |
| `{primitive:"f32"/"f64"}` | the float | `Float` |
| anything else | `None` |

**Canonical-form rule:** owned concretes (matches v1; reuses `vec_u8_node()`,
`string_node()`; adds `i64_node()`, `f64_node()`, `usize_node()` etc.).

**Precision-loss disclosure:** `Into<u64>` / `num_traits::Integer` substitute
`i64`; FfiGen's existing numeric `as i64` coercion narrows on the wrapper side.
For values in `0..=i64::MAX` this is exact; values `> i64::MAX` truncate. This
follows the existing project convention (the README's `coerceArg` table treats
`u64` params via `as i64`). Documented; not a new soundness risk.

**Windows-path caveat:** mapping `AsRef<Path>` → `String` assumes UTF-8 paths.
On Windows, non-UTF-8 paths exist; Sky's stdlib already treats paths as
`String`, so this is consistent. Documented.

### 5.2 — Part B: filter lift

Generalize the byte-seq exemption to a coercible-seq exemption:

```rust
/// Is `rt` a sequence shape whose element is Sky-coercible?
/// Matches: &[T] / Vec<T> / [T; N] / &[T; N]  where T is a known Sky-coercible
/// element (primitive numeric/bool/char, str, String, or an opaque path the
/// existing nameability filter would accept).
fn is_coercible_seq(rt: &str) -> bool;
```

Implementation: parse the bracket structure (existing helpers + a small new
parser; mirrors `is_byte_seq`), extract the element rust-string, classify it
via a `seq_elem_kind(elem: &str) -> Option<SeqElemKind>` returning either
`U8` (byte-seq, fast path) or `General` (any other Sky-coercible element).
If the parse yields `None`, the filter still drops.

Apply the lift to both filter sites:
- `:708-713` (non-byte slice/array drop) — gate by `is_coercible_seq` instead
  of `is_byte_seq`.
- `:698` (borrowed-result drop) — also gate `&[T]` results by
  `is_coercible_seq` (currently exempts only `&str`/`&String`/byte-seq).

### 5.3 — Part C: `ByteKind` → `SeqKind` (small Haskell refactor)

`src/Sky/Build/Rust/Ffi.hs`:

```haskell
-- Before (byte-only enum):
data ByteKind = BSlice | BVec | BArr Int | BRefArr Int

-- After:
data SeqShape = Slice | Owned | Arr Int | RefArr Int
  deriving (Show, Eq)

data SeqElem  = ElemU8                          -- existing: List Int ↔ Vec<u8>/&[u8]/[u8;N]
              | ElemGeneral String String       -- (elem rust_type, elem sky_type)
  deriving (Show, Eq)

data SeqKind  = SeqKind SeqShape SeqElem
  deriving (Show, Eq)

-- Renamed: byteSeqKind -> seqKind. Recognises BOTH byte and non-byte coercible
-- sequences; element classification mirrors the inspector's seq_elem_kind.
seqKind :: String -> Maybe SeqKind
```

**Param-coerce emit (`argCall`) — generalized arms:**

| `SeqKind` | emit |
|---|---|
| `SeqKind Slice ElemU8` (`&[u8]`) | `&to_u8_vec(&argN)` (existing) |
| `SeqKind Owned ElemU8` (`Vec<u8>`) | `to_u8_vec(&argN)` (existing) |
| `SeqKind (Arr n) ElemU8` (`[u8; N]`) | prelude + `to_u8_array::<SkyError, n>(&argN)` (existing) |
| `SeqKind (RefArr n) ElemU8` (`&[u8; N]`) | prelude + `&to_u8_array::<SkyError, n>(&argN)` (existing) |
| `SeqKind Slice (ElemGeneral t _)` (`&[T]`) | `argN.as_slice()` (Sky `List T` is `Vec<T>`; deref to `&[T]`) |
| `SeqKind Owned (ElemGeneral _ _)` (`Vec<T>`) | `argN` (identity) |
| `SeqKind (Arr n) (ElemGeneral t _)` (`[T; N]`) | prelude `let bN: [T; n] = match to_array::<SkyError, t, n>(&argN) { Ok(a) => a, Err(e) => return Err(e) }; bN` |
| `SeqKind (RefArr n) (ElemGeneral t _)` (`&[T; N]`) | same prelude + `&bN` |

**Result-coerce emit (`translateRustRet`) — generalized arms:**

| `SeqKind` | emit |
|---|---|
| `ElemU8` (any shape) | `from_u8_slice(...)` (existing) |
| `Slice (ElemGeneral _ _)` (`&[T]` result) | `e.to_vec()` |
| `Owned (ElemGeneral _ _)` (`Vec<T>` result) | identity |
| `Arr n / RefArr n (ElemGeneral _ _)` (`[T; N]`/`&[T; N]` result) | `e.to_vec()` |

Backward-compat invariant: the existing 14 byte-shape examples + 16-hex emit
**byte-identical** wrapper code, because `seqKind` returns `Just (SeqKind _
ElemU8)` for byte sequences and the `ElemU8` emit arms reuse the existing
helpers verbatim. The refactor is purely structural for the byte path.

### 5.4 — Part D: one new runtime helper

`runtime-rust/src/sky_runtime/core.rs`:

```rust
/// Sky `List T` (Rust `&[T]`) -> fixed-size `[T; N]` with length check.
/// Mirrors `to_u8_array`'s contract: never panics; returns `SkyResult::Err`
/// with a clear message on length mismatch.
pub fn to_array<E: From<String>, T: Clone, const N: usize>(xs: &[T])
    -> SkyResult<E, [T; N]>
{
    if xs.len() != N {
        return SkyResult::Err(E::from(format!(
            "expected array of length {}, got {}", N, xs.len()
        )));
    }
    let v: Vec<T> = xs.to_vec();
    match v.try_into() {
        Ok(a) => SkyResult::Ok(a),
        Err(_) => SkyResult::Err(E::from(
            "array length conversion failed".into())),
    }
}
```

`to_u8_array` is **kept as-is** (backward-compat; smaller blast radius; the
byte helper's specialised body is fine). A potential follow-up cleanup could
route it through `to_array::<…, u8, N>` and delete the bespoke version.

## 6. Soundness gate (load-bearing — unchanged from v1)

Emit only when every layer resolves; otherwise drop. Specifically:

- The recursive `concrete_for_inner_type` returns `None` for any non-mappable
  inner type → propagates → the bound's resolution fails → the function drops.
- `is_coercible_seq` returns `false` for `&[T]` / `[T; N]` whose element isn't
  recognized → the existing filter drops the function.
- `seqKind` (FfiGen) returns `Nothing` for unknown shapes → fall through to
  existing non-byte handling (which is identity for `Vec<T>` and would error
  out elsewhere if shape isn't actually emittable; but the inspector won't have
  let the binding through in that case).

The audit's `thin`/`peripheral` crates can only move up. The byte-shape
behaviour from v1 is byte-identical (same emit code path). Go path untouched.

## 7. Testing & verification

1. **Inspector unit tests** (`tools/sky-ffi-inspect-rs/src/main.rs` `mod tests`):
   - `concrete_for_inner_type` on every shape in the §5.1 table.
   - `bound_to_concrete` for the new arms: `AsRef<Path>`, `Into<u64>`,
     `num_traits::Integer`, `num_traits::Float`.
   - Recursive composition: `AsRef<Vec<u8>>` → `Vec<u8>`;
     `IntoIterator<Item = impl AsRef<str>>` → `Vec<String>`.
   - `is_coercible_seq` on `&[String]`, `[f64; 3]`, `&[i32; 4]` (true);
     `&[SomeOpaque]` (true iff nameable); `&mut [u8]` (false, not coercible
     by us);
   - `parse_fn_item` integration: `fn join(xs: &[String]) -> String` survives;
     `fn fill(buf: &mut [u8])` still drops; `fn pos(v: [f64; 3]) -> f64`
     survives.
2. **Rust-FFI codegen unit tests** (`src/Sky/Build/Rust/Ffi.hs`): if there is a
   test module, add cases for `SeqKind` classification + emit arms. Otherwise
   the e2e examples cover this.
3. **Runtime proptest** (`runtime-rust/tests/proptest.rs`): add
   `to_array_len_checked` paralleling the existing `to_u8_array_len_checked`
   — exact length succeeds; off-by-one fails with `Err`.
4. **End-to-end examples** (both):
   - `examples/rust/17-paths` — a crate using `AsRef<Path>` (candidates:
     `path-clean`, `pathdiff`, `dunce`). `Main.sky` calls one path-normalising
     fn, prints the result.
   - `examples/rust/18-num-format` — `itoa::Buffer::format` (Integer trait)
     and/or `ryu::Buffer::format` (Float trait). Proves the num_traits arms +
     value-into-buffer pattern.
5. **`/ffi-audit` delta** — re-run on the leaf/generic candidates plus the
   new path crates. Headline expected flips:
   - `itoa` thin → usable (`num_traits::Integer` recognised);
   - `ryu` thin → usable (`num_traits::Float`);
   - `bytesize` thin → usable (numeric `Into`);
   - `percent-encoding` peripheral → thin/usable (recursive `AsRef`);
   - plus any thin-tier crate gaining ctors that crosses the `usable`
     threshold via path/numeric recovery.
   Update the README "Measured coverage" table with the actual numbers.

## 8. Worked examples

**hex (still works, byte path unchanged):**
```
encode<T: AsRef<[u8]>>  -> T resolves via concrete_for_inner_type([u8]) -> Vec<u8>
                          -> Sky List Int (byte-shape; ElemU8 emit; existing helpers)
```

**`fn join(parts: &[impl AsRef<str>]) -> String` (v2 unlock):**
```
parts: &[T]                            -- T impl-Trait inside slice
T:    impl AsRef<str>                  -- impl_trait bound resolves T -> String
=> substituted type: &[String]
filter:  is_coercible_seq("&[String]") -> true  (String element is Sky String)
seqKind: Just (SeqKind Slice (ElemGeneral "String" "String"))
binding: join : List String -> String
emit:    join(arg0.as_slice())         -- &[String] from Sky List String
```

**`fn normalize<P: AsRef<Path>>(p: P) -> PathBuf` (path crate, v2 unlock):**
```
P resolves via AsRef<Path> -> String   (concrete_for_inner_type recognises Path)
PathBuf result -> concrete_for_inner_type(PathBuf) -> String -- via Owned String
binding: normalize : String -> String
```

**`fn fmt_int<I: num_traits::Integer>(i: I) -> String` (v2 unlock):**
```
I resolves via num_traits::Integer -> i64
binding: fmt_int : Int -> String
```

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Numeric precision loss (u64 -> i64 narrowing) | Documented; matches existing project convention; values within i64 range are exact |
| `AsRef<Path>` semantic mismatch on Windows | Linux pragma documented; Sky's stdlib already treats paths as String |
| `seqKind`'s element parser misclassifies a complex type string (e.g. nested generics like `&[Vec<String>]`) | The parser only needs to extract the element token; nested-generic elements that don't match a Sky-coercible primitive/path → `None` → drop (safe) |
| `to_array<E, T: Clone, N>` panicking on type errors | Body uses `try_into` with explicit `Err` return; no `.unwrap()`; mirrors `to_u8_array` discipline |
| Backward compat of byte-shape emit | `seqKind` returns `Just (SeqKind _ ElemU8)` for byte sequences; emit arms invoke the existing `to_u8_*` helpers verbatim; byte path is byte-identical (verified by the 15 existing examples still passing) |
| Inspector cache staleness | Standard inspector-edit step: rebuild release + clear `~/.cache/sky/tools/sky-ffi-inspect-rs` + `cabal install` |

## 10. Cross-backend safety

All changes are confined to Rust-only allowed dirs:

- `tools/sky-ffi-inspect-rs/` (inspector — bound table + filter lift).
- `src/Sky/Build/Rust/Ffi.hs` (Rust FFI codegen — `SeqKind` refactor; this
  module is Rust-only, created by the thin-seam refactor for exactly this
  purpose).
- `runtime-rust/src/sky_runtime/core.rs` (one new runtime helper).

No `src/Sky/Build/FfiGen.hs`, no `Compile.hs`, no `Builder.hs`, no
`runtime-go/`, no `src/Sky/Generate/Go/`, no `.skycache/ffi/*.kernel.json` at
root. The Go backend is byte-identical. Thin seam (upstream-merge surface)
preserved.

## 11. Out of scope / follow-on specs

- **Cross-crate trait resolution** (recovers `Digest` / `Read` / `Write`;
  large research subsystem, recommended next big bet).
- **Generic-type/container instantiation** (`IndexMap<K, V>` etc.).
- **`&mut [T]` out-param write-back coercion.**
- **`TryInto` / fallible bound resolution.**
- **Per-call-site monomorphization** (Sky compiler-side; not needed for leaf libs).
- **`to_u8_array` cleanup** (route through `to_array::<…, u8, N>` and delete).
