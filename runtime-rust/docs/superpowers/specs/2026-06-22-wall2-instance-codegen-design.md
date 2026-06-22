# Wall #2 — demand-driven per-instance Rust FFI codegen (design)

Status: DESIGNED (brainstorm-approved 2026-06-22). Part of the demand-driven generic
Sky→Rust FFI epic (task #20). Gated on Wall #1 (parametric foreign `TType` in
`FfiTypeResolve`) being committed. Wall #3 (inspector emits parametric stubs + real
bound metadata) follows; this slice's enforcement just starts receiving real input.

## Purpose
Let codegen synthesize a concrete Rust FFI wrapper per *actually-used* generic
instantiation, driven by the monomorphiser's inferred type-args — the demand-driven
engine, proven in isolation with a hand-written parametric stub. Zero user config;
sound by construction; misuse caught as a first-class Sky compile error.

## Scope (decided Q1 — independently verifiable)
Wall #2 is provable on its own, WITHOUT the inspector yet emitting stubs:
- A checked-in **hand-written parametric stub** (`.skyi` + `kernel.json`) over a tiny
  local crate declares a generic FFI type + methods (Sky parametric sig + a parametric
  **Rust template** + bound metadata).
- A Sky program uses it at concrete types; the monomorphiser's `CallInstance` reaches
  codegen, which synthesizes the concrete wrapper; it builds + runs.
- The **inspector is NOT touched** in this slice (that is Wall #3). Keeps this
  shared-compiler change bisectable.

## Architecture / data flow
```
HM solve → Mono.reachableInstances → globalReachableSet : Set CallInstance
                                          (ALREADY EXISTS; carries [type-args] +,
                                           via CallInstanceRecord, the call-site Region)
                                              │  ← Wall #2 threads the FFI-callee subset
                                              ▼
Compile.hs ──(reached : Set Dce.Ref  +  FFI CallInstances)──► generateRustProject
                                              │
                      ┌───────────────────────┴────────────────────────┐
                      ▼                                                ▼
        BINDABILITY CHECK (per instance)                  PER-INSTANCE SYNTHESIS
        • every type-arg ∈ closed set                     parametric Rust template
        • every type-param's bounds satisfied             + σ[K→i64, V→String] → wrapper
          by its concrete arg (static table)              named via mangleInstance
        violation → first-class Sky Diagnostic                       │
        (region + code + message + hint), NOT a drop                 ▼
                                                          <crate>_instances.rs
                                                          (whole, UNFILTERED —
                                                           reached-by-construction)
```

## Components
1. **Instance threading** (`src/Sky/Build/Compile.hs`, shared/epic). Pass the FFI-callee
   subset of `globalReachableSet` (the `CallInstance`s whose callee resolves to a Rust
   FFI binding) into `generateRustProject`, alongside the existing `reached : Set
   Dce.Ref`. Reuses the already-computed set — no new tracking.
2. **Bindability check** (new, monomorphise→codegen boundary). Per instance:
   - (a) **closed-set check**: every type-arg is Sky-mappable (primitive / `String` /
     `Vec<T>` / `Option<T>` recursive / derived-`Clone` opaque).
   - (b) **trait-bound check**: every type-param's declared bounds (metadata) are
     satisfied by its concrete arg, via a **static `closed-set × {Hash, Eq, Ord, Clone,
     Default}` table** (`i64/String/bool/char: Hash+Eq+Ord`; `f64/f32: NOT Hash/Eq`;
     `Vec<T>: Hash iff T`; opaque: only the traits it derives — extend the existing
     `Clone` derive-scan to `Hash`/`Eq`/`Ord`/`Default`).
   - Violation → a first-class **Sky Diagnostic** (see Error handling), NEVER a silent
     drop (a drop → missing symbol → cargo-fail → breaks the type-checks⇒builds floor).
3. **Per-instance synthesis** (`src/Sky/Build/Rust/Ffi.hs` + `src/Sky/Generate/Rust/
   Project.hs`, Rust boundary). From the stub's **parametric Rust template** + the
   instance's concrete type-args, substitute (`K → i64`) and emit
   `::crate::Type::<args>::method(...)`. Name via the existing `mangleInstance`
   (`IndexMap_String_i64_insert`) — one SSOT so the monomorphiser's mangled call-site
   name and the emitted wrapper name agree by construction (the S4 `wrapperRefName`
   discipline).
4. **Output** (`src/Sky/Generate/Rust/Project.hs`). Write `<crate>_instances.rs`
   (included whole, UNFILTERED). The S4 sentinel filter on `_bindings.rs` is untouched
   and never learns about instances — a per-instance wrapper is reached-by-construction
   (it exists ONLY because a `CallInstance` for it exists, i.e. the Sky code used it), so
   the file already contains exactly the used set; nothing to tree-shake.

## Trait-bound check — in Wall #2, not deferred (revised Q4)
The check lands HERE, not in Wall #3, because: it is the soundness linchpin (synthesis
must be bound-safe from its first commit); it is independently verifiable now (a
hand-stub declares bounds, so satisfying + violating instantiations are both testable);
and deferring creates a cross-slice "Wall #3 must remember to add it" gate — a latent
footgun. Wall #3 then only *populates* bound metadata from real crates; the format, the
static table, and the enforcement already exist + are proven.

## Error handling — first-class Sky diagnostics (hard requirement)
The bindability check emits a `Sky.Reporting.Diagnostic`, never a codegen string. The
machinery already exists and is reused verbatim:
- **Region:** `CallInstanceRecord._ci_region :: A.Region` ("where the reference
  appears") gives the exact call-site file:line:col. The pipeline already keys instances
  by `(file, region)`.
- **Renderer:** `src/Sky/Reporting/{Diagnostic,Render}.hs` produce the caret-underlined
  source snippet + error code + hint that EVERY native Sky error uses;
  `src/Sky/Reporting/Lsp.hs` routes the same diagnostic to the editor as a squiggle.
- **A new error code** in Sky's scheme (e.g. `E2401` "FFI generic instantiation not
  bindable"), a human message, and a fix **hint**. Example render:
  ```
  -- IndexMap KEY MUST BE HASHABLE ----------------------- src/Cache.sky:42:18
  42|     cache = IndexMap.insert key value emptyCache
                  ^^^^^^^^^^^^^^^
  This IndexMap uses Float as its key type, but a key must be hashable
  (Hash + Eq). Float is not hashable in Rust.
  Hint: use Int, String, or another hashable type as the key.        [E2401]
  ```
- By construction there is NO codegen path that emits an unsound wrapper → no cargo-fail
  and no runtime panic reachable. The soundness floor and the DX floor hold together.
- **Culprit precision (honest scope):** `_ci_region` points at the call site that *uses*
  the bad instantiation (same quality bar as native Sky type errors). Tracing to the
  absolute root — the literal that *first forced* the offending type-arg — needs extra
  solver provenance; filed as a later DX enhancement, NOT a Wall #2 blocker.

## Testing — the hand-stub fixture
A tiny local crate behind a checked-in parametric `kernel.json` (no inspector), plus a
Sky program:
- **Unconstrained generic** `Box1 a` (`make : a -> Box1 a`, `get : Box1 a -> a`):
  instantiate at `Box1 Int` and `Box1 String`; build + run; read the values back.
- **Bounded generic** (a type with a `Hash`-like bound declared in the stub metadata):
  a SATISFYING instantiation (`Int`/`String`) builds + runs; a VIOLATING instantiation
  (`Float`) asserts a **Sky-level error** (the `E2401` diagnostic), NOT a cargo-fail.
- **Closed-set negative:** an instantiation with an out-of-closed-set type-arg asserts a
  Sky error.
- **Unit assertions** for the bindability check (closed-set + the static trait table) and
  for the `mangleInstance`-named wrapper appearing in `_instances.rs`.
- Wire into `runtime-rust/scripts/ffi-fixtures-test.sh`.
- **Guardian design review** on the shared-compiler seam (the `Compile.hs` threading +
  the diagnostic construction) and **guardian-final** before commit, per the S1–S4
  cadence.

## Boundary
- **Shared / epic (authorized):** `src/Sky/Build/Compile.hs` (instance threading), the
  bindability check + its diagnostic construction (touches `Sky.Reporting`). Additive;
  the Go path is unaffected (Go never produces a generic FFI `CallInstance` — its
  inspector drops generics).
- **Rust boundary:** `src/Sky/Build/Rust/Ffi.hs` + `src/Sky/Generate/Rust/Project.hs`
  (synthesis + `_instances.rs`), `runtime-rust/tests/sky/` (fixture), `runtime-rust/
  scripts/` (sweep wiring).

## Decisions log (brainstorm 2026-06-22)
- **Q1** scope → independently verifiable, hand-stub, inspector untouched.
- **Q2** generation locus → **codegen-synthesis** (not inspector re-invocation); stub
  carries a parametric Rust template.
- **Q3** integration → separate **unfiltered `_instances.rs`** (reached-by-construction);
  `mangleInstance` naming SSOT; S4 filter untouched.
- **Q4** bindability check → at the monomorphise→codegen boundary, Sky-level error;
  **both** closed-set AND trait-bound checks land in Wall #2 (revised — not deferred).
- **DX** → first-class `Sky.Reporting.Diagnostic` (region + code + message + hint + LSP),
  not a codegen string.

## Dependencies
- **Blocked on:** Wall #1 committed (parametric foreign `TType`).
- **Unblocks / precedes:** Wall #3 (inspector emits parametric stubs + real bound
  metadata) — the enforcement built here then receives real input.
