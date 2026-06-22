# Wall #2 — demand-driven generic Rust FFI codegen (design, (A)-model)

Status: DESIGNED (brainstorm-approved 2026-06-22; REVISED to the (A)-model after the
first implementation attempt hit an architecture wall — see "Why (A)"). Part of the
demand-driven generic Sky→Rust FFI epic (task #20). Gated on Wall #1 (parametric foreign
`TType` in `FfiTypeResolve`, committed 235d9032). Wall #3 (inspector emits parametric
stubs + bound metadata) follows; this slice's machinery just starts receiving real input.

## Purpose
Let a generic Rust FFI function bind and run at any sound instantiation the Sky program
uses — driven by the monomorphiser's inferred type-args — with zero user config, sound by
construction, and any misuse caught as a first-class Sky compile error. Proven in
isolation with a hand-written parametric stub.

## Why (A) — the model, and why the original spec was wrong
The first implementation found that the original spec (per-instance `mangleInstance`
wrappers in an `_instances.rs`, call sites rewritten to the mangled name) was designed
against the **Go** backend's model. Go emits N monomorphic instances and rewrites each
call site (`specialiseFuncDecl` + a CSI call-site-rewrite seam). **The Rust backend has no
such seam:** a Rust FFI call resolves through `kernelToRust` to the *base* name
(`rust_box1_make`), identically for every instantiation, and Rust monomorphises via
**rustc's own generics + type inference**. A `mangleInstance`-named wrapper would be dead
code — no call site references it.

**(A)-model:** emit ONE **generic** wrapper per generic FFI fn, under the base name, and
let **rustc** monomorphise the unchanged call sites:
```rust
pub fn rust_box1_make<T: ::std::hash::Hash + ::std::cmp::Eq>(arg0: T)
    -> SkyResult<SkyError, ::box1::Box1<T>>
{ ok_res(::box1::Box1::<T>::make(arg0)) }
```
The call site stays `rust_box1_make(arg)`; rustc infers `T` and specializes. This is
smaller, in-architecture, and collapses most of the original spec's complexity (no
`_instances.rs`, no `mangleInstance`, no per-instance wrappers, no reached-by-construction).

## Scope (Q1 — independently verifiable)
Provable WITHOUT the inspector emitting stubs: a checked-in **hand-written parametric
stub** (`kernel.json` with a `"generic"` block) over a tiny local crate; a Sky program
uses it at concrete types; build + run. Inspector untouched (that is Wall #3).

## Architecture / data flow
```
HM solve → Mono.reachableInstances → globalReachableSet : Set CallInstance
                                       (ALREADY computed; carries [type-args] + _ci_region)
                                              │  ← Wall #2 threads the FFI-generic subset
                                              ▼               (ONLY to feed the check)
Compile.hs ──(reached : Set Dce.Ref  +  FFI-generic CallInstances)──► generateRustProject
                          │                                                │
                          ▼                                                ▼
            BINDABILITY CHECK (per instance)                  GENERIC-WRAPPER SYNTHESIS
            • every type-arg ∈ closed set                     one generic wrapper per
            • every type-param's bounds satisfied             generic FFI fn (base name,
              by its concrete arg (static table)              <T: bounds>, body calls
            violation → first-class Sky Diagnostic            ::crate::T::<T>::method);
            (E4400, region from _ci_region, hint)             rustc monomorphises call sites
                                                                          │
            PARAMETRIC-FOREIGN TYPE RENDERING                             ▼
            Box1 [Int] → ::box1::Box1<i64>                    <crate>_generics.rs
            (TypeRenderer; recursive; Wall #1 crateHome)      (sentinel-wrapped, run through
                          (used by both the wrapper sig        the SAME S4 tree-shake filter,
                           and every call-site value type)     kept iff base name reached)
```

## Components
1. **Instance threading** (`src/Sky/Build/Compile.hs`, shared/epic). Thread the
   FFI-generic subset of the already-computed `globalReachableSet` into
   `generateRustProject` (alongside `reached : Set Dce.Ref`). **Repurposed:** consumed
   ONLY by the bindability check — NOT for naming or wrapper emission (rustc handles
   instantiation). An instance is "FFI-generic" iff its callee resolves to an FFI binding
   that carries a `"generic"` block.
2. **Bindability check** (new; monomorphise→codegen boundary). Per FFI-generic instance:
   (a) every type-arg ∈ closed set (primitive / `String` / `Vec<T>` / `Option<T>`
   recursive / derived-`Clone` opaque); (b) every type-param's declared bounds (metadata)
   satisfied by its concrete arg via the static `closed-set × {Hash,Eq,Ord,Clone,Default}`
   table. Violation → a first-class **Sky `Diagnostic`** (never a drop). **ALREADY BUILT
   + compiling** (`FfiInstance.hs`).
3. **Parametric-foreign type rendering** (NEW; `src/Sky/Generate/Rust/...TypeRenderer`).
   Render a parametric foreign `TType <crateHome> Name [args]` to `::crate::Name<rust-args>`
   — recursively (`Box1 (List Int)` → `::box1::Box1<Vec<i64>>`), using Wall #1's
   `crateHome` for the path. Used by BOTH the generic-wrapper signature AND every call-site
   value of a parametric foreign type (so the concrete value flows, no boxing — Q2).
4. **Generic-wrapper synthesis** (`src/Sky/Build/Rust/Ffi.hs` / `FfiInstance.hs` +
   `src/Sky/Generate/Rust/Project.hs`). At BUILD time, from each `"generic"` block's Rust
   template: emit one generic wrapper under the base `kernelToRust` name, with `<T: …>`
   bounds rendered from metadata (`Hash → ::std::hash::Hash`, `Eq → ::std::cmp::Eq`,
   `Ord → ::std::cmp::Ord`, `Clone → ::core::clone::Clone`, `Default → ::core::default::
   Default`), body substituting `{T}`/`{argJ}`. The bounds are load-bearing (the body
   needs them to compile) and satisfied-by-construction (the check already gated). **The
   synthesis primitive ALREADY BUILT** (`FfiInstance.hs synthesiseWrapper`) — to be
   adapted from per-instance to one-generic-wrapper.
5. **Output** (`Project.hs`). Write a separate **`<crate>_generics.rs`** (build-synthesized),
   each wrapper sentinel-wrapped, run through the SAME S4 `writeFilteredBindings`
   tree-shake (kept iff its base `FfiRef` is reached). `_bindings.rs` (pre-generated
   non-generic surface) is untouched.
6. **kernel.json `"generic"` format** (`src/Sky/Build/FfiRegistry.hs`). **ALREADY BUILT**:
   optional `"generic": { "params": [...], "bounds": {param:[traits]}, "rustTemplate": "..." }`
   on a function, decoded via `.:?` (default `Nothing` → byte-identical for every existing
   kernel.json, Go and Rust).

## Already built in the first attempt (compiles clean; architecture-independent)
- `FfiRegistry.hs` — the `"generic"` kernel.json format (+49).
- `Diagnostic.hs` — `E4400` "FFI generic instantiation not bindable", `CatCodegen` (+18).
- `FfiInstance.hs` (~430 ln, pure) — closed-set check, the static trait table, the
  per-instance bindability check emitting `Diagnostic`s, and a synthesis primitive.
These survive the (A) pivot. The synthesis primitive is re-pointed from per-instance to
one-generic-wrapper; threading + type-rendering + the fixture are the remaining work.

## Error handling — first-class Sky diagnostics (unchanged, hard requirement)
The bindability check emits a `Sky.Reporting.Diagnostic`, never a codegen string: region
from `CallInstanceRecord._ci_region` (exact call-site file:line:col), code `E4400`, human
message, fix hint — routed through `Sky/Reporting/{Diagnostic,Render}.hs` (the renderer
every native Sky error uses; same caret-snippet + LSP squiggle). Example:
```
-- IndexMap KEY MUST BE HASHABLE ----------------------- src/Cache.sky:42:18
42|     cache = IndexMap.insert key value emptyCache
                ^^^^^^^^^^^^^^^
This IndexMap uses Float as its key type, but a key must be hashable
(Hash + Eq). Float is not hashable in Rust.
Hint: use Int, String, or another hashable type as the key.          [E4400]
```
By construction no codegen path emits an unsound wrapper → no cargo-fail, no runtime panic.
Culprit precision: `_ci_region` points at the call site using the bad instantiation (same
bar as native Sky type errors); root-cause tracing to the forcing literal is a later DX
enhancement, not a blocker.

## Testing — the hand-stub fixture (`runtime-rust/tests/sky/48-ffi-generics/`)
Checked-in parametric stub, NO inspector. A tiny local crate + `kernel.json` with `"generic"`
blocks:
- **Unconstrained generic** `Box1<T>` (`make : a -> Box1 a`, `get : Box1 a -> a`):
  instantiate `Box1 Int` and `Box1 String`; build + run; read values back (proves type
  rendering + generic wrapper + rustc monomorphisation end-to-end).
- **Bounded generic** (a type with a `Hash` bound in the stub metadata): a SATISFYING
  instantiation (`Int`/`String`) builds + runs; a VIOLATING instantiation (`Float`)
  asserts the `E4400` **Sky diagnostic** (region + hint), NOT a cargo-fail.
- **Closed-set negative:** an out-of-closed-set type-arg asserts a Sky error.
- **Tree-shake check:** with two generic fns where the program calls one, assert only that
  one's wrapper appears in `_generics.rs`.
- Unit specs (targeted `--match`) for the bindability check + the type renderer. Wire into
  `runtime-rust/scripts/ffi-fixtures-test.sh`.
- **Light local verify only** (this box is disk-constrained): `cabal build exe:sky` +
  targeted specs + ONE fixture build. Full 410-spec suite runs on CI post-push.
- Guardian design review on the shared seam + guardian-final before commit.

## Go-byte-identical (shared-code gate)
Every new path gates on an FFI binding carrying a `"generic"` block. Go's inspector drops
generics at the producer, so no Go kernel.json carries one → `_ffn_generic = Nothing` for
all Go → the threading, the check, the synthesis, and `_generics.rs` are all dead for Go.
The `FfiRegistry` decode is additive (`.:?`). Go `.skyi`/kernel.json/codegen byte-identical.

## Boundary
- **Shared / epic (authorized):** `Compile.hs` (instance threading), the bindability check
  + its `Diagnostic` (`Sky.Reporting`). Additive; Go unaffected.
- **Rust boundary:** the Rust `TypeRenderer` (parametric-foreign rendering),
  `Ffi.hs`/`FfiInstance.hs`/`Project.hs` (synthesis + `_generics.rs`), the fixture, the
  sweep wiring. Do NOT touch the Go inspector, `src/Sky/Generate/Go/`, `runtime-go/`,
  `sky-stdlib/`, author `examples/`. `FfiTypeResolve` (Wall #1) stays as-is.

## Decisions log (brainstorm 2026-06-22)
- **Q1** scope → independently verifiable, hand-stub, inspector untouched.
- **(A)-model** (post-attempt revision) → one GENERIC wrapper per generic FFI fn, rustc
  monomorphises; drop `_instances.rs`/`mangleInstance`/per-instance wrappers; instance
  threading feeds ONLY the bindability check.
- **Q2** boundary value → concrete by-value via parametric-foreign type rendering, no
  boxing (upholds the no-`dyn Any` thesis).
- **Q3** location/bounds → separate build-synthesized `_generics.rs`, sentinel-filtered by
  base name; bounds rendered onto `<T: …>` from metadata (load-bearing for the body,
  satisfied-by-construction).
- **Bindability check** lands in Wall #2 (closed-set AND trait-bound), not deferred.
- **DX** → first-class `Sky.Reporting.Diagnostic` (region + `E4400` + hint + LSP).

## Dependencies
- **Blocked on:** Wall #1 (committed 235d9032).
- **Precedes:** Wall #3 (inspector emits parametric stubs + bound metadata) — the
  machinery built here then receives real crate input.
