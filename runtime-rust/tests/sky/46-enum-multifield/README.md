# 46-enum-multifield — Sky→Rust auto-FFI MULTI-FIELD enum extractors (task #18)

Rust-backend FFI test fixture (NOT an author example — lives under
`runtime-rust/tests/sky/` per the boundary rule). Completes S3: `42-enum-variants`
emitted a payload extractor ONLY for a variant with EXACTLY ONE closed-set field
(`match e { E::V(x) => Just x, _ => Nothing }`); multi-field variants (`V(A,B)`,
`V{a,b}`) were tag-only — no payload access.

Sky has no clean FFI tuple, so the sound shape is a PER-FIELD extractor: one
`<v>[_<idx-or-name>]_as_variant : E -> Maybe T` per variant field whose type is in
the S1 closed set. The extractor binds ALL fields of the matched variant by
position/name (by-value receiver → moves the chosen owned field out, siblings
drop — total, no clone, no E0509) and returns the i-th.

## Extractor shapes proven here
- **Tuple multi-field** `Pair(i64, String)` →
  `pair_0_as_variant_from_geo : Geo -> Maybe Int`,
  `pair_1_as_variant_from_geo : Geo -> Maybe String`.
  Body: `match e { Geo::Pair(f0, _) => Just(f0), _ => Nothing }` (and `f1` for [1]).
- **Struct multi-field** `Rect { w: i64, h: i64 }` →
  `rect_w_as_variant_from_geo : Geo -> Maybe Int`,
  `rect_h_as_variant_from_geo : Geo -> Maybe Int`.
  Body: `match e { Geo::Rect { w, .. } => Just(w), _ => Nothing }`.
- **Mixed eligible/ineligible** `Mix(i64, NoClone)` → `mix_0_as_variant_from_geo`
  ONLY. `NoClone` is non-`Clone`/non-closed → field 1 gets no extractor, but its
  sibling field 0 (`i64`) still does.
- **Non-match** — a `Rect` value through `pair_0_as_variant` → `Nothing` (the
  `_ => Nothing` wildcard arm; `>1` variant so the wildcard is present, R3).

## Single-field unchanged
The single-field name (`<v>_as_variant_from_<E>`, no `_<idx-or-name>` infix) is
preserved (`42-enum-variants` still passes with identical names) — single-field is
just the 1-field case of the general per-field emit.

## Layout
- `enumtest-crate/` — a tiny local Rust crate (source, committed). Package
  `multifield`; `Geo { Pair(i64,String), Rect{w,h}, Mix(i64,NoClone), Empty }` +
  `make_mix` (Sky can't construct `Mix`).
- `src/Main.sky` — extracts each field of `Pair`/`Rect`, field 0 of `Mix`, and a
  non-matching read → `Nothing`; prints `[ALL OK]`.
- `setup.sh` — git-inits the crate to the `file://` cache path the `sky.toml` dep
  points at. Run before `sky build --backend rust`.

## Run
```bash
bash setup.sh
sky build --backend rust src/Main.sky && ./sky-out/rust/target/*/sky-app
```
Or via the gate: `runtime-rust/scripts/ffi-fixtures-test.sh 46-enum-multifield`.
