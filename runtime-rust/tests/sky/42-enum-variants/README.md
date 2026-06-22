# 42-enum-variants — Sky→Rust auto-FFI ENUM-VARIANT binding (S3)

Rust-backend FFI test fixture (NOT an author example — lives under
`runtime-rust/tests/sky/` per the boundary rule). Builds on S1
(`40-field-getters`) + S2 (`41-field-setters`). Proves that a Sky program
CONSTRUCTS and DISCRIMINATES a foreign enum with **no hand-written wrapper**: the
inspector auto-emits enum-variant `Function`s and the Rust codegen synthesizes
three TOTAL accessor kinds. A foreign enum stays an OPAQUE handle
(`::enumtest::Shape`) — it is NEVER lowered to a generated Sky ADT (the runtime
can't cross that boundary).

## Accessor kinds (all total by construction)
- **Constructor** `<variant>_new_variant_from_<E>` — `() -> E` (unit), `F1 -> .. ->
  E` (tuple / struct, decl order). Emitted ONLY when the enum + variant are
  exhaustive-constructible AND every field is in the S1 closed set.
- **Tag** `tag_of_<E> : E -> String` — exhaustive `match e { E::A => "A", E::B(..)
  => "B", E::C{..} => "C", _ => "<unknown>" }`. The `_` wildcard appears IFF the
  enum is `#[non_exhaustive]` OR a variant was skipped (R3).
- **Extractor** `<v>_as_variant_from_<E> : E -> Maybe T` — single-field tuple /
  struct variant. `match e { E::V(x) => Just x, _ => Nothing }`, by-value receiver
  MOVES the owned field out (no clone, no E0509). Multi-field variants: SKIP.

## Layout
- `enumtest-crate/` — a tiny local Rust crate (source, committed):
  - `Shape { Unit, Tup(i64), Strukt{w}, Multi(i64,String), Tagged(NoClone) }` —
    witnesses unit + single-tuple + single-struct + multi-field (ctor + tag, NO
    extractor) + non-closed (`NoClone` → tag-only) variants.
  - `#[non_exhaustive] Mode { #[non_exhaustive] A, B(i64) }` — NO ctor for any
    variant; the tag carries a wildcard. `A` (non_exhaustive variant) can't even
    be NAMED in a match arm from outside the crate (E0603), so it routes through
    the wildcard → `"<unknown>"`; `B` tags as `"B"`.
  - `Wrapper<T>` — generic enum, SKIPPED entirely (R7).
  - `Never {}` — zero-variant enum, SKIPPED (R4).
  - `make_unit` / `make_mode_a` / `make_mode_b` — crate ctor fns (Sky can't
    construct a non_exhaustive enum, so these supply `Mode` values).
- `setup.sh` — git-inits `enumtest-crate/` into the cache path the `sky.toml`
  `file://` dep points at.
- `src/Main.sky` — constructs `Shape::Unit/Tup 5/Strukt 9/Multi`; reads each tag
  (asserts "Unit"/"Tup"/"Strukt"/"Multi"); extracts `Tup`'s payload (Just 5),
  `Strukt`'s (Just 9), a non-matching extract (Nothing); reads a `Mode` value's
  tag WITH the wildcard (B → "B", A → "<unknown>"); extracts `Mode::B` (Just 7).
  Every opaque enum value is read LINEARLY (Shape/Mode aren't `Clone`).

## Run
```sh
bash setup.sh
export SKY_FFI_INSPECTOR_RS=<repo>/.cache/sky-rust-target/release/sky-ffi-inspect-rs
sky build --backend rust src/Main.sky
"$CARGO_TARGET_DIR/debug/sky-app"
# → Shape tags: Unit/Tup/Strukt/Multi | Tup extract=Just 5 noMatch=Nothing \
#   Strukt extract=Just 9 | Mode tags: B/<unknown> (non_exhaustive, wildcard) \
#   B extract=Just 7  [ALL OK]
```

`SKY_FFI_INSPECTOR_RS` points the build at the freshly-built inspector so the S3
enum metadata is emitted (a stale embedded inspector emits only S1/S2). The
shared `CARGO_TARGET_DIR` puts the binary at `$CARGO_TARGET_DIR/debug/sky-app`.

## Constraints proven (S3 — E1–E7 / R1–R7)
- **R1** — variant visibility is `"default"` (inherited), NOT `"public"`; the
  gate is on the ENUM's visibility + doc-hidden, never `is_public()` on a variant
  (which would emit nothing). `Shape`/`Mode` (public enums) bind.
- **R2 / E2** — `#[non_exhaustive]` detected via the bare `"non_exhaustive"`
  `attrs` string (NOT doc-hidden). `Mode` (non_exhaustive enum) gets NO ctor for
  any variant. `Mode::A` (non_exhaustive variant) is excluded ENTIRELY (E0603
  forbids even naming it in a pattern) → wildcard-routed.
- **R3 / E1** — `tag_of_Shape` has NO wildcard (Shape fully known, exhaustive →
  clippy unreachable-pattern clean); `tag_of_Mode` HAS `_ => "<unknown>"`
  (non_exhaustive + skipped `A`). Both extractors carry the `_ => Nothing` arm.
- **R4** — `Never` (zero-variant) skipped, audit reason `empty_enum`.
- **R5** — arm syntax per kind: `E::Unit`, `E::Tup(..)`, `E::Strukt{..}` (uniform
  `(..)` would be E0769 on the struct variant).
- **R6 / E6** — extractor receiver BY VALUE moves the owned field out
  (`E::Tup(x) => Just(x)` / `E::Strukt{ w: x } => Just(x)`), no `.clone()`, no
  E0509. `Multi` (multi-field) + `Tagged` (non-closed `NoClone`) get NO extractor.
- **R7 / E7** — `Wrapper<T>` (generic enum) skipped, audit reason `generic_enum`.
- **E5** — three distinct non-colliding name kinds: `<v>_new_variant_from_<E>`,
  `tag_of_<E>` (already embeds `<E>` → no `_from_` suffix), `<v>_as_variant_from_<E>`.
- **E6** — all three accessor kinds are INFALLIBLE in the `.skyi`: ctor `() -> E`
  / `Int -> Shape`, tag `Shape -> String`, extractor `Shape -> Maybe Int` — NONE
  `Result`-wrapped.

## non_exhaustive detection (empirical JSON shape, rustdoc format v57)
A `#[non_exhaustive]` enum / variant carries the bare string `"non_exhaustive"`
in the item's `attrs` array (verified on both `Mode` and `Mode::A`):
```json
{ "name": "Mode", "visibility": "public", "attrs": ["non_exhaustive"], "inner": { "enum": … } }
{ "name": "A",    "visibility": "default", "attrs": ["non_exhaustive"], "inner": { "variant": { "kind": "plain" } } }
```
`doc(hidden)` does NOT appear here — it is a separate `doc_hidden()` check.
Detection failure ⇒ assume non_exhaustive (losing a ctor is safe; emitting one on
a real non_exhaustive enum is E0639 / cargo-fail).
