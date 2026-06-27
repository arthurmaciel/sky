# WALL 3a (#59) — serde Serialize/Deserialize composes with the generic-Self trait-method path

**Status: IMPLEMENTED (#59).** Plan was guardian-reviewed
APPROVE-PLAN-WITH-CONSTRAINTS (2026-06-25); the codegen route below has since
landed — `TRSerdeValue`/`TRSerdeValueRef` live in the `TypeRef` ADT
(`FfiCall.hs`), the inspector serde arms (`bounds_are_all_serde_or_marker`,
`fn_serde_param_all_admissible`, `is_serde_trait_bound`) gate the parametric
path in `main.rs`, and fixtures `79-ffi-serde-trait` + `81-ffi-serde-ref`
exercise it. The body reads as a forward-looking plan (design intent + blocking
constraints); treat it as the rationale record, not pending work.

> **Line numbers are STALE.** Every `main.rs:NNNN` / `Ffi.hs:NNNN` /
> `FfiCall.hs:NNNN` cite below was accurate as of 2026-06-25 against the
> pre-#59 tree; the files have grown by hundreds of lines since (main.rs is now
> ~16k lines). Navigate by the named symbol (`serde_reducible_method`,
> `resolve_param_bounds`, `bound_to_concrete`, `renderCall`, `renderTypeRef`,
> `TRSerdeValue`, …), not by the raw line number — `rg` the symbol to find its
> current location.

## Problem
firestore `get_obj`/`query_obj` drop `unmodellable-bound(Deserialize)`,
`create_obj`/`update_obj` drop `unmodellable-bound(Serialize)` (27+5). #47 already
reduces serde `T → serde_json::Value → JSON String`, but its gate is INHERENT-ONLY
(`serde_reducible_method = is_inherent_impl && method_all_serde_reducible`,
main.rs:1099-1101; `take_parametric … && !serde_reducible_method`, 1151-1154). A
concrete-Self serde TRAIT method (firestore's shape) routes to the parametric stub,
whose param resolver (`resolve_param_bounds`→`bound_to_concrete`, main.rs:5294) has
NO serde arm → `UnmodellableBound` drop (5704-5707). Same routing class #58 fixed
for `AsRef`.

## Design
Extend the **#58 per-param mono pre-pass** (main.rs:6593-6620) with a serde
fallback: when `resolve_param_bounds` returns `None`, if
`bounds_are_all_serde_or_marker(bounds)` (5075, canonical-path, crate-local-safe)
AND `fn_serde_param_all_admissible(fn_data, tv)` (5189, position census) → insert
`serde_json_value_node()` into `mono_map` and REMOVE tv from `tyvars`/`order`
(mirror 6617-6620). Mirrors the existing #47 inherent arm (8022-8030) on the
parametric path. A fully-reduced serde trait method → empty `params` +
`mono_resolved=true` → routes through the WALL2-mono TRAIT branch (7486,
`is_wall2_mono`, keeps `generic` for UFCS).

**Make-or-break = the CODEGEN half.** The serde-Value boundary coercion
(`from_str::<serde_json::Value>`→`sv_j`; `to_string(&..)` return-wrap;
`::<serde_json::Value>` turbofish) lives ONLY in `emitRustFnSimple`
(Ffi.hs:881,898,1007-1008,1336). The UFCS/parametric emitter `renderCall`
(FfiCall.hs:320) has NO serde-Value `TypeRef` node (160-164), NO turbofish on the
UFCS branch (346-348: `<Self as Trait>::method` — turbofish-free by design), NO
prelude/return-wrap. Substituting raw `serde_json::Value` there → E0282/E0283
(un-inferrable T, no turbofish) + E0308 (Value vs Sky String). The #55 DEFECT-2
hole, reopened on the trait branch.

**Preferred codegen route (also retires a stringly-typed smell):** introduce a
`TRSerdeValue` constructor in the `TypeRef` ADT (FfiCall.hs:160) that
`renderTypeRef` (514-523) renders as `serde_json::Value` and the wrapper-body
emitter pattern-matches to inject the from_str prelude + `to_string` return-wrap;
emit a method-level turbofish `<Self as Trait>::method::<serde_json::Value>(..)` on
the UFCS branch (attaches after `::method`, NOT on the Self type — `<Self::<V> as
…>` is E0107). This replaces the current 3-site stringly compare
(`"serde_json::Value"`/`"n"` in Ffi.hs:881,898 + the `{"__sky_serde_value":true}`
sentinel main.rs:5024) with one typed node.

## BLOCKING constraints (implementer + guardian-final)
1. **[MAKE-OR-BREAK] UFCS callee emits a method-level `::<serde_json::Value>`
   turbofish** when return or any arg is serde-Value. After `::method`, not on
   Self. (#55 DEFECT-2 mirrored onto the trait branch — absent today, 346-348.)
2. **[MAKE-OR-BREAK] Serde-Value boundary coercion wired on the parametric/UFCS
   codegen path** (from_str prelude + `sv_j` arg ref + `to_string` return-wrap).
   Fail-closed: if it can't be emitted on this path, DROP — never emit raw
   `serde_json::Value` (E0308). Prefer the `TRSerdeValue` typed-node route.
3. **Census on the trait sig BEFORE substitution; inadmissible → DROP.** Reuse
   `fn_serde_param_all_admissible` (5189) as the #58 pre-pass does (6604).
   `&T`/`&mut T`/tuple/map-value → drop. `subst_generic_json` is position-blind
   (7940) — the census is the ONLY gate.
4. **Recognition by resolved canonical path, never last-segment.** Use
   `bounds_are_all_serde_or_marker`→`is_serde_trait_bound` (5050, rejects
   crate_id 0 look-alike, 5060-5065). Regression: crate-local `trait Serialize`
   on a concrete-Self method still DROPS.
5. **Per-param independence + sibling-bound drop.** `T: Serialize +
   SomeUnmodellable` → not all-serde → param stays in tyvars → BoundCrossImpl/
   classify DROPS the method (never reduce serde half + silently drop the other).
   `<T: Serialize, U: DeserializeOwned>` → reduce BOTH to Value independently.
6. **Mono'd serde param REMOVED from `tyvars` AND `order`** (mirror 6617-6620) so
   it emits no `::<T>` parametric slot (type_args 6701) and never hits the
   BoundCrossImpl backstop (6665-6675).
7. **DeserializeOwned soundness.** `Value: Serialize + DeserializeOwned`, and
   `DeserializeOwned ⟹ Deserialize<'de> ∀'de`, so Value satisfies both bound
   shapes (5036-5044) — sound by subtyping, do NOT over-gate `Deserialize<'de>`.
   Borrowed `'de` in a separate param is dropped by the census (C3) independently.
   Fixtures: positive `get_obj<T: Send+Sync+DeserializeOwned>(&self,..) ->
   Result<T,E>` (binds→String); negative `bad<'de,T: Deserialize<'de>>(&self, raw:
   &'de [u8]) -> T` (borrowed param → DROP).
8. **No-panic/totality** on the new path (`.get()`/`if let`/`match`; emitted
   `from_str`→`SkyResult::Err`, output `to_string` via `unwrap_or_default`, never
   `.unwrap()`).
9. **async composition (the ACTUAL firestore shape).** `get_obj`/`create_obj` are
   `async fn`. Compose with #44 async→Task + #54 self-receiver Send gate
   (`serde_json::Value: Send+Sync` ✓). Add an ASYNC positive fixture — a sync-only
   fixture hides the async interaction (#44-final lesson).

## Proof bar
Fixture (extend a 7x dir or new): a dep-on-serde crate with a concrete `Db` +
`trait Repo { async fn get_obj<T: DeserializeOwned+Send+Sync>(&self) ->
Result<T,String>; async fn put_obj<T: Serialize+Send>(&self, v: T) ->
Result<(),String>; }` + `impl Repo for Db`. Sky passes/receives JSON strings.
Negatives: `&T` param, `T: Serialize + CrateLocalTrait`, borrowed `Deserialize<'de>`
→ all DROP. Guardian-final with SKY_DCE=0 + real cargo build.
