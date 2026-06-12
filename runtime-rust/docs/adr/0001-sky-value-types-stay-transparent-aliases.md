# Sky value types stay transparent aliases, not newtypes

**Status:** accepted

## Context & decision

Sky's `Dict K V` lowers to Rust `HashMap<K, V>`; the runtime keeps a transparent
alias `pub type SkyDict<T> = HashMap<String, T>` for its own readability. During
#52 the question arose (user): should Sky value types (`SkyDict`, and by
extension `SkyString`/`SkyList`) become `#[repr(transparent)]` **newtypes** —
distinct types with their own identity, trait impls, and methods — instead of
transparent aliases?

**Decision: keep them as transparent aliases.** The wholesale newtype is
declined as YAGNI / over-engineering for the current codebase.

## Why (the trade-off)

Measured blast radius of a `SkyDict` newtype:

- The Rust codegen emits **raw `HashMap<K, V>`** for `Dict` (`TypeRenderer.hs`
  `Can.TType _ "Dict" [k,v]`) and **never references `SkyDict`** — the alias is
  purely runtime-internal. A newtype forces a codegen emission change *plus* a
  new 2-param type threaded through generated code.
- **143 `HashMap` mentions across 15 runtime files.** Only some are Sky `Dict`s;
  the rest are internal runtime maps (session stores, caches, header maps). A
  newtype conversion must hand-distinguish Dict-HashMaps from internal-HashMaps
  at every site — error-prone, no mechanical guarantee.
- All 9 `dict_*` kernels + `db_query` + `LiveReq` fields + the `SkyRow` impl +
  every FFI boundary would change signatures.

Against that cost, the benefit is **type-distinction safety + a home for
Sky-specific trait impls** — neither of which is load-bearing here: the codegen
generates all the call sites (so human type-confusion isn't a risk), `SkyRow`
(#52) impls cleanly on the alias with no coherence conflict, and the project's
actual thesis — *concrete types, no `dyn Any`, no type erasure, no runtime
errors* — is **already fully satisfied** by `HashMap` (a concrete type). There
is no motivating defect.

## Revisit triggers

Promote to a `#[repr(transparent)]` newtype (as its own swept change, never
bundled) if any of these materialise:

1. A real trait-coherence conflict needs a distinct type to impl a trait two
   different ways for "a Sky Dict" vs "some other `HashMap`".
2. A type-confusion bug actually ships because an internal `HashMap` was passed
   where a Sky `Dict` was expected (or vice versa).
3. Sky `Dict` needs invariants/encapsulation the raw `HashMap` API can't enforce.

Until one of those is true, the alias is the correct, lower-risk choice.
