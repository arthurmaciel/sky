# Rust FFI — generic-function monomorphization-on-demand (Alt-1) — Design

**Date:** 2026-05-27
**Status:** Approved (brainstorming) — ready for implementation plan
**Scope:** `tools/sky-ffi-inspect-rs/` only (Rust-only FFI infra). Zero Go-backend impact.
**Branch:** `feat/runtime-rust`

---

## 1. Problem

The Rust FFI inspector drops **every** generic function wholesale:

```rust
// tools/sky-ffi-inspect-rs/src/main.rs:594
if let Some(params) = fn_data["generics"]["params"].as_array() {
    if !params.is_empty() { return None; }
}
```

The `/ffi-audit` 50-crate sweep showed this is the dominant coverage blocker:
crates that bind well are *self-typed* (chrono, uuid, semver); crates that bind
little are *generic-fronted*. The canonical case — `hex::encode<T: AsRef<[u8]>>`
— drops, leaving `hex` with 1 bound function (`peripheral`). The same
`AsRef<…>` / `Into<…>` / `Display` pattern sinks most of the `thin`/`peripheral`
tier.

This was selected as **Alt-1** in `runtime-rust/README.md` → "FFI reach":
*monomorphise-on-demand at the concrete types a Sky program uses.*

## 2. Goal

When **every** generic parameter of a function (free or impl-method) has a bound
that maps to a Sky-representable concrete type, **instantiate** the function at
that type and emit a normal monomorphic binding. Otherwise, drop as today.

The inspector may only ever **add** compilable bindings — never break the
"`_bindings.rs` always compiles" invariant, and never change a crate that works
today.

## 3. Non-goals (explicit)

- **No cross-crate trait resolution.** The `sha2`/`md-5` `Digest` case needs
  resolving an *external* blanket impl (`impl<D> Digest for D` in the `digest`
  crate) — confirmed absent from the target crate's rustdoc JSON. Out of scope;
  `sha2` stays at 0 here (and is already covered by Sky's runtime `Crypto.sha256`).
- **No generic containers** (`IndexMap<K,V>`, `SmallVec<[T;N]>`) — redundant with
  Sky's own `List`/`Dict`; murky element-type semantics.
- **No per-call-site monomorphization.** One *canonical* instantiation per
  function, chosen from its bound — not a distinct wrapper per Sky usage. A leaf
  function is essentially never called at more than one Sky-representable type,
  so per-call-site (which would require threading HM call-site types into the Sky
  compiler and break the thin seam) buys ~nothing here.
- **No numeric (`Into<i64>`) or `AsRef<Path>` bounds in v1**, no `const` generics.
  Deferred to a later pass.
- **Go backend untouched.** The inspector is Rust-only infrastructure; no
  `TargetGo` path is involved (Cross-backend rule 5 preserved).

## 4. Verified rustdoc-JSON shapes (grounded, not assumed)

From real `cargo +nightly rustdoc --output-format json` on `hex` 0.4 and `sha2`
0.10:

- A generic param carries its bound inline:
  ```json
  {"name":"T","kind":{"type":{"bounds":[
     {"trait_bound":{"trait":{"path":"AsRef","args":{"angle_bracketed":{"args":[
        {"type":{"slice":{"primitive":"u8"}}}]}}},"modifier":"none"}}]}}}
  ```
- A parameter referencing the generic is `{"generic":"T"}`.
- Bounds may instead live in `fn.generics.where_predicates` (`bound_predicate`).
- `impl Trait` arguments appear as an `impl_trait` type node carrying the same
  `bounds` array (today they fall through `rustdoc_type_to_sky` as non-nameable).
- Marker/auto bounds (`Sized`, `Send`, `Sync`, `Copy`, `Clone`, `Debug`) and
  lifetime bounds appear in the same `bounds` array alongside the shape bound.

## 5. Design

### 5.1 The bound → concrete table (`bound_to_concrete`)

Maps a *shape* bound to the concrete type-JSON node to substitute. v1 set:

| Bound (trait path + arg) | Substituted concrete (rustdoc node) | Sky type |
|---|---|---|
| `AsRef<[u8]>` · `Borrow<[u8]>` | `&[u8]` (`borrowed_ref → slice → u8`) | `List Int` |
| `Into<Vec<u8>>` · `IntoIterator<Item=u8>` | `Vec<u8>` | `List Int` |
| `AsRef<str>` · `Borrow<str>` | `&str` (`borrowed_ref → primitive str`) | `String` |
| `Into<String>` · `ToString` · `Display` | `String` | `String` |

**Canonical-form rule (decided):** for `AsRef<X>`/`Borrow<X>` pick the **borrowed**
form (`&[u8]`, `&str`); for `Into<X>` pick the **owned** target (`Vec<u8>`,
`String`); for `Display`/`ToString` pick `String`. Borrowed is correct for
`AsRef` because the generated wrapper takes an owned Sky value and borrows it —
identical to how `String`/`Bytes` params already work.

**Why this needs no FfiGen change:** the substituted concretes are *exactly* the
raw Rust shapes FfiGen already coerces (per `runtime-rust/README.md` coercion
tables): `&[u8]`/`Vec<u8>` ← Sky `List Int` via `&to_u8_vec(&argN)`/`to_u8_vec`;
`&str` ← Sky `String` via `&argN`; `String` ← Sky `String`. The inspector hands
FfiGen a binding that looks fully monomorphic; FfiGen is unchanged.

### 5.2 Resolution algorithm (in `parse_fn_item`)

Replace the unconditional drop at `:594` with:

1. Collect every type generic param name and its bounds, from
   `generics.params[].kind.type.bounds` **and** `where_predicates`.
2. For each param, strip marker/auto/lifetime bounds; from the remaining *shape*
   bounds resolve via `bound_to_concrete`:
   - exactly one resolvable shape bound → record `name → concrete-JSON`;
   - zero resolvable, or two shape bounds that disagree → **unresolvable**.
3. If **any** type generic param is unresolvable, **or** the function has a
   `const` generic param, or a generic appears only in return position with no
   bound that pins a concrete (e.g. `fn parse<T: FromStr>() -> T`) → `return None`
   (drop, as today).
4. Otherwise build a substitution map and apply `subst_generic_json` to every
   parameter and the return type JSON **before** the existing
   `rustdoc_type_to_sky` / `rustdoc_type_to_rust_str` calls.
5. Continue through the **existing** downstream filters unchanged (lifetime,
   borrowed-result, array/slice with byte exemption, nameability). They run on
   the substituted concrete types — the safety interlock (§5.4).

### 5.3 `subst_generic_json` + `impl Trait` args

- **`subst_generic_json(type_json, map)`** — generalises the existing `subst_self`
  to walk a type-JSON tree and replace any `{"generic":"T"}` node (including
  nested under `Option<…>`, `Vec<…>`, tuples) with the mapped concrete node.
- **`impl Trait` arguments** — when a parameter's type is an `impl_trait` node,
  resolve its `bounds` through `bound_to_concrete` and replace the whole node with
  the concrete (same table). If unresolvable → drop the function.

### 5.4 Soundness gate (load-bearing invariant)

Emit only when **every** generic param resolves to a concrete type the existing
pipeline accepts; otherwise drop. The substituted concretes are deliberately the
ones the downstream filters already pass (`&[u8]` byte-exempt, `&str`, `String`,
`Vec<u8>`). Consequences:

- No silent wrong instantiation — an unmappable bound drops, never guesses.
- A crate that compiles today cannot regress — the change is purely additive.
- `_bindings.rs` always compiles.

## 6. Worked example — `hex`

```
rustdoc:  pub fn encode<T: AsRef<[u8]>>(data: T) -> String
          param "data" = {generic:"T"},  T.bounds = [AsRef<[u8]>]

resolve:  T → &[u8]   (List Int)
subst:    param "data" = &[u8]
emit:     encode : List Int -> String     (.kernel.json / .skyi / _bindings.rs)

FfiGen:   wrapper takes Sky List Int, calls hex::encode(&to_u8_vec(&arg0))  [existing coercion]
Sky:      Hex.encode [72,73]  ==>  "4849"
```

`decode<T: AsRef<[u8]>>(data: T) -> Result<Vec<u8>, FromHexError>` likewise →
`decode : List Int -> Result Error (List Int)` (Vec<u8> result already byte-mapped).
`encode_to_slice`/`decode_to_slice` (which take `&mut [u8]` out-params) remain
dropped — out of scope.

## 7. Testing & verification

1. **Inspector unit tests** (Rust `#[cfg(test)]` in `main.rs`, feeding synthetic
   rustdoc-JSON fragments to `parse_fn_item`):
   - `encode<T:AsRef<[u8]>>(T)->String` → emits `encode(List Int) -> String`.
   - `<T:Display>(T)->String` → param becomes `String`.
   - `<T:AsRef<str>>` → param becomes `String` (via `&str`).
   - `<T:SomeUnknownTrait>` → dropped (returns `None`).
   - `<T:AsRef<[u8]>, U:Display>(T,U)` → both substituted.
   - `<const N: usize>` present → dropped.
   - output-only `<T:FromStr>()->T` → dropped.
   - `impl AsRef<[u8]>` arg → substituted to `&[u8]`.
2. **End-to-end example** `examples/rust/16-hex` — `sky add hex --target rust`,
   `Main.sky` round-trips `Hex.encode`/`Hex.decode`, **builds and runs** (prints
   the hex string and the decoded bytes). Proves the full inspector → FfiGen →
   cargo path.
3. **Coverage-delta measurement** — re-run `/ffi-audit` (`--force` on the affected
   crates) and record the verdict shifts (headline: `hex` `peripheral → usable`;
   plus any `thin → usable` movers). The audit is the regression gauge; the README
   "Measured coverage" table is updated with the new numbers.

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| `where_predicate` bound shapes vary across rustdoc format versions | Handle both inline + where-clause; unit-test fragments; unrecognised shape → drop (safe) |
| A substituted concrete trips a downstream filter unexpectedly | The filters run *after* substitution by design — anything they reject still drops, never emits broken Rust |
| Multi-bound params (`T: AsRef<[u8]> + Send`) | Strip marker/auto bounds before resolving; a single shape bound remains |
| Two real shape bounds (`T: AsRef<[u8]> + AsRef<str>`) | Treated as conflict → drop (rare; safe) |
| Embedded-inspector staleness after the edit | Rebuild the `sky` binary + clear `~/.cache/sky/tools/sky-ffi-inspect-rs` (standard inspector-edit step) |

## 9. Cross-backend safety

All changes are confined to `tools/sky-ffi-inspect-rs/` (an allowed Rust-only
infra dir). No `src/Sky/Generate/Go/`, `runtime-go/`, `FfiGen.hs`, `Builder.hs`,
or `Compile.hs` edits. The Go backend is byte-identical. FfiGen is unchanged
because the inspector emits already-monomorphic bindings using shapes FfiGen
already coerces.

## 10. Out of scope / follow-on specs

- Cross-crate trait resolution (real `Digest`/`Read`/`Write` recovery).
- Numeric (`Into<i64>`), `AsRef<Path>`, `IntoIterator<Item=T>` for arbitrary `T`.
- Generic containers.
- `&mut [u8]` out-param buffers (`encode_to_slice`).
- Per-call-site monomorphization in the Sky compiler.
