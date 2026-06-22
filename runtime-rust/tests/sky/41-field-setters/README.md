# 41-field-setters — Sky→Rust auto-FFI struct field SETTERS (S2)

Rust-backend FFI test fixture (NOT an author example — lives under
`runtime-rust/tests/sky/` per the boundary rule). Builds on S1
(`40-field-getters`). Proves that a Sky program WRITES a foreign struct's public
fields with **no hand-written wrapper**: the inspector auto-emits field-SETTER
`Function`s and the Rust codegen synthesizes a total immutable-update accessor
`{ let mut r = recv; r.field = value; r }` that returns a NEW receiver.

## Layout
- `fieldtest-crate/` — a tiny local Rust crate (source, committed). `Box3`
  (`w` i64 + `label` String fields), `Item` (a `pub id` field AND an `id()`
  method — the C2 four-way coexistence: getter + setter + method), `Rec`
  (`good` i32 eligible, `glyph` char eligible (S2 char↔Char), `wide` u64 dropped
  by C1, `secret` `#[doc(hidden)]` dropped by C3), `Holder`/`Inner`/`NoClone`
  (C5 opaque-Clone proof).
- `setup.sh` — git-inits `fieldtest-crate/` into the cache path the `sky.toml`
  `file://` dep points at (Cargo can't resolve a bare path dep through
  `["rust.dependencies]` — only crates.io version or git).
- `src/Main.sky` — constructs a `Box3`, SETS `w` then `label` (each producing a
  new copy), reads the fields back, asserts the new values AND that they changed
  from construction, then exercises the `Item` four-way C2 (getter sees 5,
  setter writes 8, method reads the new value ×10 = 80).

## Run
```sh
bash setup.sh
SKY_FFI_INSPECTOR_RS=<repo>/tools/sky-ffi-inspect-rs/target/release/sky-ffi-inspect-rs \
  sky build --backend rust src/Main.sky
./sky-out/rust/target/debug/sky-app
# → Box3.w 7->99 Box3.label hello->world (w preserved=99) \
#   Item.id field 5->8 method(*10)=80  [ALL OK]
```

`SKY_FFI_INSPECTOR_RS` points the build at the freshly-built inspector so the
S2 setter metadata is emitted (the binary embedded in a stale `sky` would only
emit S1 getters). The shared `CARGO_TARGET_DIR` puts the binary at
`$CARGO_TARGET_DIR/debug/sky-app`, not `./sky-out/...`.

## Constraints proven (S2 — inherits S1 C1–C6 gates for the field type)
- C1 — `Rec.wide : u64` gets NO setter (value-non-preserving into Sky `Int`;
  the field is dropped for BOTH accessors).
- C2 — FOUR distinct non-colliding names on `Item.id`: getter
  `id_field_from_item`, setter `id_set_field_from_item`, method `id_from_item`,
  plus the field projection itself. No `E0428` / silent drop.
- C3 — `Rec.secret` (`#[doc(hidden)]`) never surfaces a setter (or getter).
- C5 — only the closed eligible type set surfaces (Copy / String / Vec / Option
  / Clone-deriving opaque / char). A non-`Clone` opaque field type is dropped.
  A setter is emitted ONLY in lockstep with a getter — a field with no getter
  never gets a setter.
- C6 — field setters are INFALLIBLE: `w_set_field_from_box3 : Int -> Box3 -> Box3`
  (bare, NOT `Result Error Box3`). Param order `FieldTy -> Recv -> Recv` mirrors
  Go's `setField(value, recv) -> recv`.

## char→Char (S2 decision: DONE)
`char` is now eligible: the inspector's `type_str_to_sky` maps `char -> Char`,
`skyTypeToRust` maps `Char -> char`, and the Rust TypeRenderer already lowered
Sky `Char -> char` (`char_kernel` round-trips it). So `Rec.glyph : char` gets
both a getter (`glyph_field_from_rec : Rec -> Char`) and a setter
(`glyph_set_field_from_rec : Char -> Rec -> Rec`) with no `any` boxing.
