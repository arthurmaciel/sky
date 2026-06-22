# Sky→Rust auto-FFI: binding GENERIC foreign fns / structs / enums

**Task #20 design doc — scoping + minimum-viable first slice.**
Status: design only (no impl). Guardian design review pending.
Date: 2026-06-22. Branch: `feat/runtime-rust`.

---

## 0. TL;DR / recommendation

**Chosen strategy: (B) user-declared instantiations** via a new
`[rust.monomorphize]` section in `sky.toml`, threaded to the inspector
as a repeatable `--monomorphize 'IndexMap<String, i64>'` flag. The
inspector binds, for each declared instantiation, a distinct concrete
opaque Sky type (`IndexMap_String_i64`) with its inherent methods
monomorphised at that substitution.

**Why not (A) closure-over-own-API:** empirically dead for the target
crate class. `indexmap`'s public API is **0 concrete anchors** (probe
below) — every public fn is generic over `K,V,S`. (A) recovers nothing
for collection/builder crates, which are exactly the crates that hit
the wall. (See §2.)

**Minimum-viable first slice:** ONE declared instantiation of ONE
generic struct (`IndexMap<String, i64>`), emitting its inherent methods
whose signature generics (after `K→String, V→i64`) reduce to the
existing closed Sky type-set. Probe shows **55 of 93 inherent methods**
become clean under that substitution (`new`, `insert`, `len`,
`is_empty`, `clear`, `get_index`, `keys`, `values`, `pop`, `capacity`,
`truncate`, …). The existing borrow/array/result-borrow gates then trim
the borrowed-return subset; the scalar-in/scalar-out CRUD core lands.
This is real, decisive value and de-risks the whole spine (selection →
substitution → naming → DCE) on the smallest sound surface.

---

## 1. Current drop behaviour (cited)

`tools/sky-ffi-inspect-rs/src/main.rs` (3943 LoC). What is dropped vs
already-monomorphised:

### 1.1 Already monomorphised (the existing machinery)

- **`Vec<T>` / `Option<T>` / `Result<T,E>`** are *not* user-generics —
  they're built-in mappings to Sky `List` / `Maybe` / `Result`,
  resolved structurally in `rustdoc_type_to_sky` / `field_type_eligible`
  (`"Vec" | "Option"` arm at **L1184-1189**, recursing into the inner
  arg). These are NOT the gap.
- **`fn f<T: Bound>()`** — `resolve_generics` (**L3302-3341**) builds a
  per-fn substitution map: for each type param it gathers inline +
  `where_predicate` bounds (**L3313-3334**) and calls
  `resolve_param_bounds` (**L3251-3265**) → `bound_to_concrete`. If a
  single trait bound maps to a concrete Sky type (e.g. `T: Default` is a
  marker → skipped; a bound that names a concrete) the param substitutes;
  otherwise **the whole fn is dropped** (`None` at **L3337**). This is
  the **monomorphise-on-demand (Alt-1)** machinery, applied at
  **L1837** (`let subst_map = resolve_generics(fn_data)?;`), then
  `subst_generic_json` (**L3270-3294**) rewrites every
  `{"generic":"NAME"}` leaf to its concrete node. `impl Trait` args/rets
  resolve via `resolve_param_bounds` too (**L3280-3284**,
  `impl_traits_resolvable` **L3347-3358**).
  - **Verdict:** this only fires for a param resolvable to a SINGLE
    concrete via its bounds (degenerate, e.g. a sole-impl marker). For a
    *free* param like `T: FromStr` with many impls, or `K,V` with no
    bound that pins one type, it returns `None` → drop. So
    `fn parse<T: FromStr>()` drops; `IndexMap`'s `get<Q>` (Q: Borrow)
    drops.

### 1.2 Hard drops (the gap)

- **`enum E<T>` — generic enum:** `enum_walk` checks
  `generics.params` non-empty (**L1374-1384**) and bails with
  `record_tail_drop("generic_enum", …)`. Zero variant ctors / tag /
  extractors emitted. (`"generic_enum"` is in the drop-reason whitelist
  at **L262-263**.)
- **Generic struct fields:** the struct field-walk (**L744-916**) does
  NOT pre-check struct genericity. It builds the receiver path with
  `"args": null` (**L758-760**) — i.e. a *bare* `IndexMap` with no type
  args. Each field then runs `field_type_eligible` (**L1127-1217**).
  A field typed `{"generic":"V"}` falls through every arm to the final
  `Err("not_in_closed_set")` (**L1215-1216**) — generics aren't a
  closed-set member. And a field typed `IndexMap<K,V>` with non-empty
  args hits **L1194-1196** (`!args.is_empty() → not_in_closed_set`).
  In practice indexmap's structs have 4 struct_fields total (private/
  generic), so this surfaces nothing.
- **Generic struct methods:** an inherent method on `IndexMap` whose
  sig mentions `{"generic":"V"}` reaches `resolve_generics`, which has
  no binding for `V` (the type's param, not the fn's) → either the
  param isn't in the fn's `generics.params` so it stays a raw
  `{"generic":"V"}` leaf, then `rustdoc_type_to_sky` can't name it and
  the Haskell `fn_types_nameable` retain (**Ffi.hs L929**) drops it;
  OR the fn carries its own `Q`/`F` param that won't resolve → `None`
  drop. Net: **generic-struct methods produce nothing usable.**

**Can the existing machinery generalise?** Yes — `subst_generic_json`
is exactly the right primitive. It already rewrites `{"generic":"NAME"}`
→ concrete. Today the substitution map only ever comes from
*bound-resolution* (`resolve_generics`). The first slice **adds a
second source for that map: the user-declared instantiation
`{K: String_node, V: i64_node}`**, seeded BEFORE the per-fn bound pass.
The downstream `subst_generic_json` / `rustdoc_type_to_sky` / eligibility
pipeline is reused unchanged. That is the whole point of choosing this
spine: **minimal new machinery, maximal reuse.**

---

## 2. Instantiation-selection strategies (grounded)

Probe setup: `/tmp/gen-probe`, `indexmap = "2"` (resolved 2.14.0) +
`smallvec = "1"`, `cargo +nightly rustdoc --output-format json` (the
exact invocation the inspector uses, `main.rs` L389-414).

`indexmap.json` item-inner kinds: `function: 677, impl: 862,
struct: 33, enum: 3, trait: 4, variant: 6`. Functions split:
**free 39, method 638.**

### (A) Closure over the crate's own public API — REJECTED

Probe: scan every public fn signature for a `resolved_path` naming one
of indexmap's own 33 structs with **fully concrete** type-args (no
`{"generic"}` leaf anywhere inside).

> **Result: 0 concrete anchors.**

indexmap is generic over `K,V,S` end-to-end; nothing in its own API
pins a concrete `IndexMap<String, i64>`. (A) is automatic and bounded
but **recovers zero bindings for the exact crate class that needs it.**
It would help only crates that internally expose a concrete
instantiation of their own generic (rare; a config crate returning
`Settings<String>`). Not worth building first, possibly not at all.

- 32 of 33 indexmap structs are generic (only 1 non-generic). So the
  generic wall is near-total for this crate.

### (B) User-declared instantiations — CHOSEN

The Sky project states which instantiations it wants. This is the ONLY
strategy that unlocks indexmap. Probe: simulate `IndexMap<String,i64>`
by substituting `K→String, V→i64` and counting inherent methods whose
*remaining* sig-generics reduce to `{K, V, S, Self}` (S = the hasher
param pinned by the instantiation's decl; `Self` = receiver, already
handled by `subst_self`, `main.rs` L2208 / L1886-1908):

> **55 of 93 IndexMap inherent methods become clean.** Including:
> `new, with_capacity, insert, insert_full, len, is_empty, clear,
> capacity, get_index, keys, values, pop, truncate, reserve, reverse,
> sort_keys, split_off, swap_remove_index, shift_remove_index,
> first, last, hasher, …`

The remaining 38 are blocked by fn-introduced params the slice
conservatively drops: `Q: Borrow` (17 — `get`/`contains_key` lookup by
borrowed key), `F` (15 — closure args, e.g. `retain`/`sort_by`),
`R`/`P`/`I`/`B`/`S2` (range/predicate/iterator params). After the
existing C5 borrow gate trims borrowed returns (`iter`, `keys`,
`values`, `as_slice` return borrows → already dropped) and the entry
API (returns a generic `Entry<K,V>` — itself out-of-set), the landed
surface is the **owned scalar CRUD core**: `new`, `insert` (takes
`String,i64` → returns `Option<i64>` = Sky `Maybe Int`), `len`,
`is_empty`, `clear`, `capacity`, `get_index`, `pop`, `truncate`,
`reserve`, `swap_remove_index`, `shift_remove_index`. That is a usable
map for Sky code. **This is the grounding evidence for choosing (B).**

### (C) Common-bound generics at concrete impl'ing types — DEFERRED

`fn f<T: Display>` → bind once per crate type implementing `Display`.
Value is real for *free* generic fns, but the explosion is
combinatorial (N display-types × M fns) and the selection isn't
user-intent-driven — it guesses. Defer until (B) ships and we see
demand. Note the existing `resolve_generics` already half-does this for
**sole-impl** marker bounds; (C) is the multi-impl generalisation.

### (D) Hybrid — the actual shipping shape

(B) as the primary, **with the existing (Alt-1) bound-resolution kept**
for fn-level params that DO resolve to a single concrete. I.e. seed the
subst map from the user declaration for the *type's* params (`K,V`),
then let `resolve_generics` handle any *additional* fn params on top.
A method whose only extra param is resolvable stays; one with an
unresolvable extra (`Q`,`F`) drops — conservatively, no behaviour
change for those. This is what the first slice implements.

---

## 3. Minimum-viable FIRST SLICE (precise)

**Goal:** monomorphise a single user-declared concrete instantiation of
one generic struct end-to-end — fields + inherent methods at that
instantiation — proven by a fork-local `examples/rust/` fixture.

### 3.1 Inputs

`sky.toml`:

```toml
[rust.dependencies]
indexmap = "2"

[rust.monomorphize]
# crate = list of concrete instantiations to bind
indexmap = ["IndexMap<String, i64>"]
```

Threading:
1. `src/Sky/Sky/Toml.hs` — new section arm `"rust.monomorphize"` in
   `applyKeyValue` (sibling of `"rust.dependencies"` at L122-124),
   parsing `key = [ "Inst<…>", … ]` into a new
   `_rustMonomorphize :: [(String, [String])]` field on `SkyConfig`.
   **This is a sky.toml schema change — flag for the boundary review
   (§6).** It is additive and Rust-only-namespaced; Go backend ignores
   it.
2. `src/Sky/Build/Rust/Ffi.hs` `runRustInspectorWith` (L73-90) — append
   `--monomorphize <quoteShell inst>` per declared instantiation for
   the matching crate, alongside the existing `--features` construction
   (L78).
3. `tools/sky-ffi-inspect-rs/src/main.rs` `main` (L138-172) — parse a
   repeatable `--monomorphize` flag into
   `Vec<MonoRequest { type_name, args: Vec<ConcreteArg> }>` by a small
   hand parser for `Name<Arg, Arg>` where each Arg is in the closed Sky
   scalar/String/Vec/Option set (reject + warn otherwise — see §5).

### 3.2 What's emitted

For `IndexMap<String, i64>`:

- A distinct opaque Sky type **`IndexMap_String_i64`** (naming §4),
  whose Rust receiver type is the full `indexmap::IndexMap<String, i64>`
  (the inspector emits `_fnRecvRustType` = the concrete spelling, so
  `resolveRustType` / `absolutizeCrate` in Ffi.hs L780-883 produce a
  valid wrapper signature).
- For each inherent method clean under `{K→String, V→i64}` (per §2's
  55), a wrapper keyed `wrapperRefName` =
  `<method>_from_indexMap_String_i64` (the `_from_<recv>` disambig
  already exists, Ffi.hs L162-164). Body: `recv.method(args)`, reusing
  the existing instance-method codegen (Ffi.hs L726+), async/setter/
  borrow gates all unchanged.
- Struct fields: indexmap's IndexMap has no *public* concrete fields, so
  the slice's struct-field path is exercised by the fixture's **own**
  declared generic struct if needed; for indexmap specifically the
  value is the methods. (Field monomorphisation reuses the same
  `subst_generic_json` seed — no extra machinery.)

### 3.3 The fixture

`examples/rust/NN-ffi-generics/`:
- `sky.toml` with the `[rust.monomorphize]` block above.
- `src/Main.sky` that imports `Rust.Indexmap`, calls
  `IndexMap.new ()`, `insert`, `len`, `getIndex`, prints a result —
  proving build + run + a non-trivial value round-trips.
- Wired into the gated example set + an assertion in the sweep
  (mirroring the `43-ffi-dce` D4 runner pattern, task #17).

**Out of the first slice (deferred to follow-on slices):**
- Generic ENUMs (`generic_enum` drop stays) — second slice, same seed
  mechanism applied to `enum_walk` L1374.
- `smallvec` / array-const-generic params (`A: Array`, probe showed
  `SmallVec`'s sole param is `A: Array` → needs `SmallVec<[i64; N]>`
  const-generic instantiation, harder) — deferred.
- `Q: Borrow` lookup methods (`get`, `contains_key`) — needs a
  `&str`-key-from-Sky-String bridge; deferred (the existing borrow gate
  drops them safely meanwhile).
- Closure-param methods (`retain`, `sort_by`) — out of scope entirely
  (Sky closures across FFI is a separate epic).
- Strategy (A) and (C) — deferred / maybe-never.

---

## 4. Naming + collision

- **Opaque Sky name:** `<Type>_<Arg1>_<Arg2>` with each arg rendered to
  its Sky-type token and non-alphanumerics mangled to `_`:
  `IndexMap<String, i64>` → `IndexMap_String_i64`,
  `IndexMap<String, Widget>` → `IndexMap_String_Widget`. Nested args
  flatten left-to-right (`Vec<i64>` → `Vec_i64`). This is collision-free
  by construction: two different instantiations produce different token
  sequences; the same instantiation declared twice dedups (canonicalise
  the arg spelling first — strip whitespace, so `IndexMap<String,i64>`
  and `IndexMap<String, i64>` map to one name).
- **Method keying:** unchanged — `wrapperRefName` already appends
  `_from_<lowerFirst recvType>` (Ffi.hs L162-164). With the new recv
  type being `IndexMap_String_i64`, methods key as
  `insert_from_indexMap_String_i64` etc. Two instantiations' `insert`
  methods get distinct keys automatically. No collision with a
  same-named free fn (the `_from_` suffix disambiguates).
- **DCE interaction:** the S4 build-time tree-shake keys on
  `wrapperRefName fn` via BEGIN/END sentinels (Ffi.hs L1162-1190,
  L1220). Because each monomorphised method already has a unique
  `wrapperRefName`, the existing DCE drops an unreached
  `IndexMap_String_i64` wrapper exactly as it drops any other — no DCE
  change needed. `dedupByRustName` (Ffi.hs L1212) likewise keys off
  `wrapperRefName`, so the dedup is already instantiation-aware.
- **Receiver type cross-emit:** the inspector must emit the
  monomorphised receiver's `_fnRecvRustType` as the *concrete* Rust
  spelling (`indexmap::IndexMap<String, i64>`). Ffi.hs already passes
  generic recv rust-strings through `resolveRustType` /
  `absolutizeCrate` (L780-883, the existing `DateTime<Tz>` Display-bridge
  path at L665/L824 proves generics-in-recv already flow), so the
  wrapper sig `fn(arg0: indexmap::IndexMap<String,i64>, …)` emits valid.

---

## 5. Soundness / boundary risks (locked constraints)

The no-runtime-error law holds **automatically once an instantiation is
chosen** — the emitted body is concrete Rust, total by construction.
The risk surface is SELECTION + NAMING, enumerated:

1. **Instantiation references a type not in the closed set.** E.g.
   `IndexMap<String, SomePrivateType>`. The arg parser (§3.1.3) MUST
   validate every arg against the closed Sky scalar/String/Vec/Option/
   crate-local-Clone-struct set (reuse `field_type_eligible`'s logic).
   An out-of-set arg → **reject the whole instantiation with a clear
   stderr diagnostic, bind nothing for it.** Fail closed; never widen to
   `any`/`String`.
2. **A method introduces a fresh type param** (`Q`, `F`, …). Handled by
   the existing `resolve_generics` returning `None` → method dropped.
   Conservatively correct; no change.
3. **A method's sig still contains an unsubstituted `{"generic":"X"}`**
   after seeding (X not in the declared args and not a resolvable fn
   param). The post-substitution `rustdoc_type_to_sky` can't name it →
   `fn_types_nameable` retain (Ffi.hs L929) drops it. Floor holds.
4. **Trait-bound methods / trait impls** — OUT of this slice (that's
   task #21). Only *inherent* methods (`imp.trait == null`) are walked.
5. **The hasher param `S`.** `IndexMap<K,V,S=RandomState>` has a default
   `S`. The instantiation `IndexMap<String,i64>` resolves `S` to its
   default `RandomState`. The receiver Rust spelling must use the
   2-arg form `IndexMap<String,i64>` (default S) so methods like `new`
   (which require `S: Default + BuildHasher`) compile. The arg parser
   binds only the user-named args; defaulted params are left to Rust.
6. **Const generics** (`SmallVec<[T; N]>`) — rejected by the arg parser
   (not a named-type instantiation). Deferred.

**What stays conservatively dropped:** generic enums (next slice),
borrow-lookup methods, closure-param methods, const-generic
instantiations, trait-impl methods, any instantiation with an
out-of-set arg.

**Boundary verdict:**
- `tools/sky-ffi-inspect-rs` — in boundary (new flag + seed).
- `src/Sky/Build/Rust/Ffi.hs` — in boundary (thread flag).
- `src/Sky/Generate/Rust/*` — likely **no change** (naming + DCE reuse
  existing keying; confirm during impl).
- `runtime-rust/` — no change (concrete bodies need no runtime support).
- `src/Sky/Sky/Toml.hs` — **shared-compiler change** (new
  `[rust.monomorphize]` section + `SkyConfig` field). This is the one
  non-Rust-only edit. It is additive, Rust-namespaced, and ignored by
  the Go backend, so the parity risk is minimal — **but it must be
  called out in the guardian review and the docs/sky-toml.md +
  templates updated per the template-sync rule.**

---

## 6. Open questions for guardian review

1. **sky.toml vs Sky-annotation surface.** The doc proposes
   `[rust.monomorphize]`. Alternative: a Sky-side type annotation
   (`type alias IntMap = Rust.Indexmap.IndexMap String Int`) that the
   compiler harvests. The toml route is simpler to thread and matches
   the existing `[rust.dependencies]` precedent; the annotation route is
   more "Sky-native" but needs the canonicaliser to feed the inspector
   (heavier). **Recommendation: ship toml first; revisit annotation
   harvesting if users find toml awkward.**
2. **Arg-list TOML shape.** `indexmap = ["IndexMap<String, i64>"]`
   (array of full instantiation strings) vs a more structured table.
   Array-of-strings is the lightest parse and human-obvious;
   recommended.
3. **Confirm `src/Sky/Generate/Rust/*` truly needs no change** — the
   naming/DCE reuse argument (§4) is sound on inspection but must be
   verified empirically in the first impl PR.

---

## 7. Appendix — probe commands (reproducible)

```
cd /tmp && cargo new --lib gen-probe
# add indexmap="2", smallvec="1" to Cargo.toml
cd gen-probe
cargo +nightly rustdoc -p indexmap --lib -Zunstable-options --output-format json
# → target/doc/indexmap.json  (677 functions, 33 structs, 32 generic)
```

Key counts (indexmap 2.14.0):
- structs generic / non-generic: **32 / 1**
- concrete anchors of own structs in own public sigs (Strategy A): **0**
- IndexMap inherent methods total / clean under `K→String,V→i64`:
  **93 / 55**
- blocking fn-params on the other 38: `Q×17, F×15, R×5, S×4, …`
- smallvec sole param: `A: Array` (const-generic array shape → deferred)
