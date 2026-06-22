# 40-field-getters — Sky→Rust auto-FFI struct field GETTERS (S1)

Rust-backend FFI test fixture (NOT an author example — lives under
`runtime-rust/tests/sky/` per the boundary rule). Proves that a Sky program
reads a foreign struct's public fields with **no hand-written wrapper**: the
inspector auto-emits field-getter `Function`s and the Rust codegen synthesizes
total `recv.field` / `recv.field.clone()` accessors.

## Layout
- `fieldtest-crate/` — a tiny local Rust crate (source, committed). `Point`
  (i64 + String fields), `Counter` (a `pub id` field AND an `id()` method —
  C2 coexistence), `Rec` (`good` i32 eligible, `wide` u64 dropped by C1,
  `secret` `#[doc(hidden)]` dropped by C3).
- `setup.sh` — git-inits `fieldtest-crate/` into the cache path the `sky.toml`
  `file://` dep points at (Cargo can't resolve a bare path dep through
  `["rust.dependencies]` — only crates.io version or git).
- `src/Main.sky` — constructs each struct, reads fields + calls the method,
  asserts the values.

## Run
```sh
bash setup.sh
sky build --backend rust src/Main.sky
./sky-out/rust/target/debug/sky-app
# → Point.n=7 Point.label=hello Counter.id(field)=5 Counter.id()(method)=50 \
#   Holder.good_inner.tag=42  [ALL OK]
```

If `cargo` fails compiling the transitive `time` crate with
`unresolved import time_macros::timestamp` (a broken `time 0.3.50` /
`time-macros 0.2.29` crates.io pairing — unrelated to this fixture), pin the
working pair before re-building:
```sh
cargo update -p time --precise 0.3.47 --manifest-path sky-out/rust/Cargo.toml
```

## Constraints proven (S1 C1–C6)
- C1 — `Rec.wide : u64` is dropped (value-non-preserving into Sky `Int`).
- C2 — `Counter.id` field (`id_field_from_counter`) and `Counter::id()` method
  (`id_from_counter`) bind to distinct names and coexist.
- C3 — `Rec.secret` (`#[doc(hidden)]`) never surfaces a getter.
- C4 — the getter reads the field by value (`recv.field` / `.clone()`); no
  partial move out of the receiver.
- C5 — only the closed eligible type set surfaces (Copy / String / Vec / Option
  / Clone-deriving opaque). A non-`Clone` opaque field is dropped.
- C6 — field getters are INFALLIBLE: `n_field_from_point : Point -> Int`
  (bare, NOT `Result Error Int`).
