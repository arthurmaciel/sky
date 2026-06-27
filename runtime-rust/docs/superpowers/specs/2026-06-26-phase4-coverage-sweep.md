# Phase 4 (#71) — auto-FFI coverage sweep on diverse complex crates

**Status:** MEASURING. Goal: measure live auto-FFI coverage across 5+ diverse complex crates
+ 2 GUI frameworks, identify the dominant UNBOUND classes, implement the gap fixes that are
genuine mechanism gaps (not sound fail-closed drops). Begun after the stripe arc shipped
(walls G–K + B8 + feature-visibility; the real `CreateCustomer::send` mechanism is proven
end-to-end on fixtures 94/95/96).

## Discipline
Re-measure the LIVE drop histogram on each real crate before scoping (the histogram drifts;
never trust a stale framing). Distinguish a SOUND drop (correct fail-closed behaviour — binding
it would be wrong) from an ACTIONABLE mechanism gap. Heavy crates (winit/wgpu/full SDKs) are
disk/CI-bounded on the slim box; gate every audit on free disk.

## Batch 1 — data/network crates (2026-06-26, inspector at WALL-K HEAD)

| crate | bound / total | dominant drops |
|---|---|---|
| `url` | 19 / 151 | trait-method-trait-unreachable 60, not-bindable 36, trait-method-generic-self 18, blanket-impl-only-var 14 |
| `redis` | 480 / 6014 | **unmodellable-bound 2188**, trait-method-trait-unreachable 1113, trait-bounded-param-ambiguous 847, not-bindable 883, generic-self 300 |
| `reqwest` | 39 / 295 | trait-method-trait-unreachable 130, unmodellable-bound 49, not-bindable 47 |

### Finding 1 — the data-crate drops are predominantly SOUND, not mechanism gaps
- **std-blanket conversion/borrow methods** dominate `trait-method-trait-unreachable`:
  reqwest's bucket is `from`×48, `try_from`×44, `try_into`×40, `into`×40, `borrow`/`borrow_mut`×40.
  These are UFCS-unreachable by design (#46) — a `<X as From<Y>>::from` FFI wrapper is meaningless
  + name-colliding. Correct fail-closed drops.
- **multi-impl domain-trait generics** dominate `unmodellable-bound` / `trait-bounded-param-ambiguous`:
  redis's are `ToSingleRedisArg`×1112, `ToRedisArgs`×696, `FromRedisValue`×97 — redis's core
  serialization traits, each impl'd by dozens of types. A `T: ToRedisArgs` param has NO unique
  concrete to monomorphize to → genuinely ambiguous → correct fail-closed drop (WALL-G/K resolve a
  UNIQUE cross-crate impl; a multi-impl domain trait is out of scope by construction, and binding
  one arbitrary concrete would be wrong).

CONCLUSION: the auto-FFI mechanism (walls G–K) is MATURE for the data-crate shape. Coverage there
is bounded by sound drops, not missing capability. Binding more would require a different surface
(e.g. per-concrete-type monomorphic wrappers for the common `ToRedisArgs` impls — a coverage/
ergonomics expansion, not a soundness wall), tracked separately if demand warrants.

### Finding 2 — feature-selection degradation (the one general ACTIONABLE lever)
`url` + `reqwest` all-features doc build FAILED → fell back to DEFAULT features (low coverage).
Root: the #89 `choose_visibility_features` injects ALL features when the crate has no `full`
feature; a crate with MUTUALLY-EXCLUSIVE features (reqwest: `native-tls` ⊕ `rustls` ⊕ … TLS
backends; url: nightly-only `debugger_visualizer`) then fails rustdoc and degrades to default.
A crate WITH `full` (async-stripe-core) is unaffected (the author curated `full` to be
compatible). IMPACT: modest (the core API is usually in `default`; reqwest's Client/get/post bind
on default — 39 incl. core), and a robust fix needs compatible-subset detection (cargo declares no
exclusivity). Filed as a deliberate-design follow-up, NOT a fragile name-heuristic in the
soundness-sensitive inspector. Lower priority than the GUI dimension.

## Batch 2 — GUI frameworks (NEW dimensions — where real mechanism gaps are likely)
`egui` (immediate-mode, closure/`&mut Ui`-heavy → stresses the #28 closure seam) + `iced`
(Elm-arch trait-`Application` + generics + async). These exercise FFI dimensions the data crates
don't. Measuring (disk-gated).

| crate | bound / total | dominant drops |
|---|---|---|
| `egui` | 419 / 3533 | trait-method-trait-unreachable 1735, **not-bindable 841**, blanket-impl-only-var 320, generic-self 134, unmodellable-bound 36, trait-object-unsupported 11 |

`egui` all-features also failed → default (Finding 2 again). The closure-heavy hypothesis did NOT
surface a large closure bucket — the #28 seam handles the common `Fn*` param. egui's
`not-bindable ×841` breaks down as: **`borrowed_ref` 370** (`&mut Ui` / `&Response` — egui's
immediate-mode signature everywhere; a mutable/non-string foreign borrow is NOT expressible in
Sky's owned-value FFI → sound), `raw_pointer` 160 (sound), `undeclared type-var` 142 (free
Self/tyvar non-self position → sound/niche), `impl_trait` 71 (opaque → mostly sound), `lifetime
type-arg` 60 (sound), external-type-no-path 24 (niche nameability), **numeric-param-coercion 3**
(#82), dyn_trait 1, const-generic 1.

## CONCLUSION — the auto-FFI mechanism is MATURE; coverage is SOUND-bounded
Across 4 diverse crates (3 data + 1 closure-heavy GUI), the unbound surface is dominated by
**correct fail-closed drops**, not missing capability:
- std-blanket UFCS-unreachable methods (`from`/`into`/`try_from`/`borrow*`) — the single largest
  bucket everywhere (#46 already binds the meaningful external/std-trait methods; these residuals
  are genuinely unbindable).
- multi-impl domain-trait generics (`ToRedisArgs`/`FromRedisValue`/…) — no unique concrete to
  monomorphize → binding one would be wrong.
- non-owned / non-value borrows (`&mut Ui`, raw pointers, lifetime-parametric types) — outside the
  owned-value FFI model by construction.
- free type-vars / blanket-impl-only vars — out of scope (parametric-Self epic, sound over-drop).

The shipped mechanism (walls 1–K + closures #28 + iterators #30 + serde #47 + the stripe send
chain G–L) covers the tractable surface. The **actionable** residuals are incremental, not
soundness walls:
1. **#82 numeric param-width coercion** (usize/u32/f32) — the param-side sibling of the shipped
   #16 return coercion; appears in egui (3) + firebase. CLEAN + general + sound → IMPLEMENT.
2. Feature-selection robustness (Finding 2) — modest, heuristic; deliberate-design follow-up.
3. External-type-path nameability (~24 in egui) — niche.
4. `&mut ForeignType` closures / dyn-trait objects (#33) — fundamentally hard / ≈0-demand.

Phase-4's first implement target is #82.
