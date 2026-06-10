# Rust-backend examples/ conquest registry

**Date:** 2026-06-09 · **Branch:** `feat/runtime-rust` (fork-only)

Root-cause triage of the `examples/[0-9]*` set on `--target rust`. **Important
framing:** only the gated-6 (`01/04/07/14/simple/test_pkg`) ever built on Rust;
every failing example here is **greenfield (never worked), not a regression**.
`examples/rust/` is a separate FFI set. This registry is the conquest map.

**Discipline (per user, 2026-06-09):** ALWAYS fix root cause, NEVER symptom-only.
If an example is *defying* (deep / cross-cutting / risky to fix blind), REGISTER
it here with its diagnosis and a proposed approach, and move on — so we plan a
proper fix rather than force a band-aid.

## Accurate scoreboard (disk-safe sweep)

**Builds (17 in-scope):** `00, 01, 04, 07, 09, 10, 12, 14, 15, 18, 20, 28, 30,
32, 33, simple, test_pkg` — up from 12 at session start. CONQUERED this session:
`10-live-component` (serde multi-module + DestructDef), `28-streaming-chat`
(SkyMaybe serde + branch-aware clone), `12-skyvote` (168 errors → 0, via the
full TEA-Msg keystone chain — see class 1 below), `18-job-queue` (24 → 0 — see
below), and `33-websocket-echo` (Arc<dyn Fn> stored-callback repr — see below).

**In-scope failing (7):** `03, 05, 13` (Go-package→Rust-native FFI subsystem —
major, multi-session), `08, 16, 17` (multi-class codegen — missing kernels +
mass E0308), `35` (additive missing kernels + Dict-key E0308). Clean full sweep
`2026-06-10`: ZERO regressions; every previously-building example still builds
(32-sse-relay's impl-Fn forEachChunk path intact).

### 33-websocket-echo — CONQUERED (Arc<dyn Fn> stored-callback repr)

The 4× E0308 were the `withOnX` setters storing an `impl Fn` callback into
`WsServerCfg`'s `fn`-pointer fields. A STORED callback may capture app state
(ex-32's SSE-relay forEachChunk handler captures `writer` — capturing closures
are first-class), and a captured closure is NOT a `fn` pointer. Sound repr =
`Arc<dyn Fn(..) -> .. + Send + Sync>` for a stored function VALUE, vs `impl Fn`
for a PASSED param. Fix (all gated — function-typed record fields are the only
affected shape; no building example has one but the WS cfg):
1. `TypeEmitter.fieldTypeToRust` — function-typed record field → `std::sync::Arc
   <dyn Fn(..) -> .. + Send + Sync>` (struct defs + synCtor ctor params).
2. `ExprEmitter.wrapStoredFn` — function-typed field VALUE (lambda, or
   region-type TLambda) wrapped in `std::sync::Arc::new(..)` at record-literal +
   field-update sites.
3. `ModuleEmitter.synCtor` — ctor params via fieldTypeToRust so `Struct {
   onConnect: onConnect }` assigns Arc-param into Arc-field.
4. `Emitter.collectUndefinedTypes` — skip `::`-qualified paths so `std::sync::Arc
   <..>` doesn't synthesise an invalid `type std::sync::Arc = String;` placeholder.
5. Runtime `WsServerCfg<E>` fields fn-ptr → Arc<dyn Fn + Send + Sync>; consume
   sites unchanged; Arc is Clone so #[derive(Clone)] holds. The
   currying-foundation-only comment was STALE (output already uncurried) — removed.

**In-scope crashes: none.**

### 18-job-queue — CONQUERED (24→0)

Builds-correction note: the older scoreboard claimed `18` was a different class
"NOT helped" by the keystone; in fact a chain of closure-flow + Task-return
fixes drove it to zero. Each fix regression-gated against all building examples:
1. seeded `Random` kernels (`seededInt`/`Float`/`Choice`, splitmix64 = Go) +
   partial-ctor application (24→13).
2. body-driven closure-param inference (`inferParamRustType`: `direct` /
   `genDirect` / `vecElem` element-region / `userClosure` recursion via
   `ecClosureDefs`) — untyped local-closure params (E0282 cluster).
3. record-closure param inference (`closureParamFields` + superset struct match)
   for `Cmd.perform`-style HOF args (13→10→8).
4. escaping multi-arg closures emit `move` + captured-var clones; `ecClosureDefs`
   threaded through BOTH Def and TypedDef branches (8→7).
5. `kernelArgRustType` table (db_exec/db_query/db_exec_raw, log_*_with
   Vec<String>) + Int→String db-param `format!` coercion + serde open-record
   resolution (7→2).
6. **`taskFailPin` enclosing-return-elem fallback** (`ecReturnElem`) — the final
   E0308. `sleepThenFail : Task Error a` stays inferred-polymorphic, but the call
   site resolves `a=String` onto the rendered `SkyTask<String>` sig. The body's
   `task_fail` turbofish had no concrete `ecExpectedType` at the andThen-closure
   tail → defaulted `::<_, i64>`. Now seeds the enclosing fn's `SkyTask<T>`
   element (`taskElemOf`) as last-resort pin: below a concrete expected type,
   above the i64 default (2→0).

### 12-skyvote — CONQUERED (the keystone proof, 168→0)

Driven to zero through a chain of regression-gated fixes, each verified against
all building examples:
1. multi-module signature scoping (`ecModuleEnv`/`lookupOwnSig`) — dep-module
   sigs (Lib.Db) resolved authoritatively (168→81).
2. body-driven param monomorphization (`inferParamRustType`) — `List a`→
   `Vec<String>`, `row`→`HashMap` from kernel flow (81→24/23).
3. row-poly param resolution (`resolveOpenRecordParam`) — TEA `model` params →
   concrete struct by field-name superset.
4. **TEA-Msg keystone** (`detectAppMsg`/`detectAppModel` + `teaReturnSubst`) —
   substitute the app's CONCRETE Msg/Model into TEA returns (`(Model, Cmd msg)`/
   `Html msg`) that collapsed to `()`. CONCRETE (no uninferrable generics — the
   blanket-generic version regressed 4 examples and was reverted). Precise to
   the exact TEA shapes + msg/model slots (an over-broad version corrupted
   stdlib generics → reverted that too).
5. record-update param inference (`inferRecordParamFromUpdate`) — bare-TVar
   `model` params resolved from `{ model | … }` update fields (handleSignOut).
6. auth turbofish (`auth_hash_password`/etc → `::<SkyError>`), f64 literal
   coercion (`Css.pct 100` → `100_f64` via `kernelArgRustType` + `calleeName`).

This keystone is the capability the TEA-heavy examples need; it specifically
conquered 12. `18-job-queue` is NOT helped (its blockers are untyped
local-closure params (E0282) + serde + arg-count, a different class).

## Failing in-scope examples (12) — by root-cause class

| # | Example | Class | Root-cause diagnosis | Status |
|---|---|---|---|---|
| 10 | live-component | serde (E0277) | `collectLiveSerdeTypes` model-detection fails on **multi-module** apps (Main + Counter component); `MainModel` not stamped with serde derive. `view : Model -> Html Msg` is a clean VarTopLevel, so the failure is the cross-module solved-type lookup, not the field shape. | **REGISTER** — needs robust multi-module model-type detection. |
| 12 | skyvote | E0308 ×142 + serde | mass type-mismatch (likely one systematic lowering bug emitting a wrong type pervasively) + serde. The E0308 volume must be root-caused first (one fix likely clears most). | **REGISTER** — diagnose the mass-E0308 source. |
| 08 | notes-app | **47** (E0308 ×18, E0425 ×21, E0061 ×3, E0412 ×3, E0433 ×2) | **Re-triaged 2026-06-10** (new binary; was 111+21). Missing kernels: `server_form_value` ×10, `server_method` ×5, `uuid_new_string`, `string_left`, + 4 `html_*_` helpers (trailing-`_` naming-rewrite artifact). After additive kernels, ~26 E0308/E0061 type-mismatches remain (deeper). | **REGISTER** — add `server_form_value`/`server_method` runtime kernels (additive); then root-cause the residual E0308. |
| ~~18~~ | ~~job-queue~~ | ~~E0282 ×8 + E0277 ×6~~ | closure-flow inference + serde + Task-return-elem turbofish. | **CONQUERED** 24→0 (see above) |
| 28 | streaming-chat | E0277 ×4 + E0599 ×2 | serde + a missing method (E0599). | needs diagnosis |
| ~~33~~ | ~~websocket-echo~~ | ~~E0308 ×4 (stored-effectful-callback)~~ | **CONQUERED 2026-06-10** (see above) — Arc<dyn Fn> stored-callback repr. Original diagnosis kept for the record: All 4 identical: `with_on_X(cb: impl Fn(..) -> SkyTask<()>)` stores `cb` into `WsServerCfg.onConnect: fn(WsHandle) -> SkyTask<E,()>` (runtime server.rs:399). `impl Fn` ≠ `fn` ptr. **Currying is NOT the issue** — output is already uncurried; the server.rs:393-398 comment is STALE. Runtime only CONSUMES the fields (`(cfg.onConnect)(h).await`), so `Arc<dyn Fn>` is drop-in callable. **Blocker:** `typeToRustString` renders `TLambda` context-free as `fn(..)` (TypeRenderer.hs:216) — distinguishing a STORED field (→`Arc<dyn Fn + Send + Sync>` + `Arc::new` wrap at literals/updates/setter) from a PASSED param (→`impl Fn`, e.g. ex-32 `forEachChunk`) needs field-context threaded through the renderer, OR a uniform function-value repr (Sub-D.2 design doc). **Regression surface is small** — verified building examples pass functions as separate `live_app_routed` args, none store functions in record fields. | **REGISTER** — thread stored-vs-passed context into the function-type renderer; runtime struct fields → Arc<dyn Fn>; codegen wraps Arc::new at construction. |
| 16 | skychess | **77 + 6 codegen-CRASH** (E0308 ×58, E0412 ×13, E0282 ×6; malformed-Rust "found keyword `move`") | **Re-triaged 2026-06-10** (reaches cargo, not a Sky parse fail). 6 sites emit invalid Rust (a closure/`move` shape). Multi-class: mass E0308 + missing types + codegen-crash. | **REGISTER** — root-cause the 6 malformed-emission sites first, then the E0308 cluster. |
| 17 | skymon | **110** (E0061, E0277, E0308, E0412, E0507, E0631) | **Re-triaged 2026-06-10** (reaches cargo; the old "brace bug" diagnosis is STALE). High volume across 6 error classes incl. E0631 (closure-sig) + E0507 (move-out-of-borrow). Likely one or two systematic lowering bugs. | **REGISTER** — bucket the 110 by class; find the systematic source (cf. 12-skyvote's single-bug cascade). |
| 35 | composite-generics | **36** (E0425 ×11, E0308 ×14, E0061 ×6, E0412 ×3, E0609, E0631) | **Re-triaged 2026-06-10** (old "parse error" STALE). Two clean sub-classes: (a) ~13 ADDITIVE missing kernels — `dict_to_list`, `math_sin/cos/log`, `string_lines`, `io_read_line`, `system_cwd`, `system_load_env`, type `SkyCoreJsonEncodeValue` (genuinely missing); `uuid_v4`/`uuid_v7` EXIST in uuid_kernel.rs but aren't reachable (re-export / feature-gate visibility — runtime compiled WITHOUT features). (b) Dict typed-key E0308: `HashMap<String,_>` vs `HashMap<i64,_>` (limitation #5 inline-only key inference). | **REGISTER** — add missing kernels + fix uuid re-export (additive); then the Dict-key inference class. |
| 03 | tea-external | Go-package FFI (`.skycache/go/_bindings.go`) | **Re-triaged 2026-06-10** — imports a Go package; needs the Go-package→Rust-native FFI subsystem. (Earlier "resource busy" was a transient parallel-sweep file lock, not the real failure.) | **REGISTER** — Go-FFI subsystem (major). |
| 05 | mux-server | Go-package FFI | **Re-triaged 2026-06-10** — same Go-FFI subsystem class as 03/13. | **REGISTER** — Go-FFI subsystem (major). |
| 13 | skyshop | Go-package FFI (76k-symbol Stripe SDK) | **Re-triaged 2026-06-10** — the Go-FFI benchmark example; same subsystem, largest scale. | **REGISTER** — Go-FFI subsystem (major). |

## Root-cause classes (leverage order)

1. **serde-derive on Live models (E0277)** — splits into TWO sub-classes:
   - **1a. multi-module model-detection collision** — `10` (+ `17`). Root cause
     FOUND + FIXED: `Walker.collectLiveSerdeTypes` looked up `view`/`init` by
     BARE name in the flat `_stEnv`, which collides across modules. A component
     module (Counter) that also defines `view`/`init` shadowed Main's, so the
     model resolved to Counter's `view : (Msg -> parentMsg) -> Counter -> ...`
     (param 0 is a function, not the model) → empty closure → MainModel never
     got serde. Fix: module-scoped lookup via `_stPerModuleEnv` keyed by the
     `VarTopLevel` home module (Walker/ModuleEmitter/Project threaded).
   - **1b. single-module closure-miss** — `18, 28` (both single-module Main.sky,
     so NOT the collision). Model IS detected; some type in its transitive
     closure either can't derive serde (function-typed field / opaque) or the
     BFS misses it. *Distinct diagnosis pending — regenerate + inspect which
     struct lacks the derive.*
2. **mass E0308 type-mismatch** — `12` (146), `08` (111), `17` (97). ROOT CAUSE
   FOUND + FIXED (keystone): multi-module FUNCTION-SIGNATURE type resolution.
   `defToRustItem` looked up each function's param/return types by BARE name in
   the flat `ecSolvedTypes` (`_stEnv`); a DEP module's function (e.g.
   `Lib.Db.exec : String -> List String -> Task Error ()`, unannotated) missed
   the lookup → fell back to body-analysis defaults (`args: String`, return
   `()`) instead of `Vec<String>` / `SkyTask`. Every call site then mismatched
   (E0308 ×100+). Fix: a NEW `ecModuleEnv` ctx field carries the current
   module's `_stPerModuleEnv[M]`; `lookupOwnSig` consults it FIRST (then flat)
   for the DEFINED function's own param/return types ONLY. (v1 layered the
   module env over `ecSolvedTypes` WHOLESALE and regressed 00-standard-libs:
   it shadowed cross-module CALLS to same-named functions — `Std.Money.
   fromString`/2 hiding `Std.Decimal.fromString`/1 → wrong currying. The
   surgical version scopes only the signature, leaving body call-resolution
   on the flat map.) Result: 12 went 168→81 (returns + concrete-param sigs
   fixed; residual 66 E0308 are the polymorphic-param gap below).
   NOTE: `08`/`17` ALSO carry Go-FFI deps (class 3 below), so the E0308 fix
   advances but may not fully clear them; `12` is pure-Sky so it's the
   keystone verifier.
   POLYMORPHIC-PARAM MONOMORPHIZATION (defying, blocks 12 fully): the stdlib
   DB kernels are polymorphic (`Db.exec : … List a …`, `Db.getField : String
   -> row -> String`), so user wrappers (`Lib.Db.exec/query/getField`,
   unannotated) inherit TVAR params. The concrete-only param gate rejects them
   → body-analysis `String`, but the runtime kernels demand `Vec<String>` /
   `HashMap`. Needs body-driven param monomorphization (infer the param's
   concrete type from the kernel it flows into) — symmetric to the existing
   `taskExprInnerType` return inference.
3. **missing kernels (E0425)** — `08` (21), `10` (1). Per-kernel runtime adds
   (the `time_every`/`debug_to_string` pattern). Tractable, enumerable.
4. **parse / malformed Rust** — `16, 17, 35`. Codegen emitting invalid syntax;
   each a distinct emitter bug. `17` (brace imbalance) checked first.
5. **untyped local-closure params (E0282)** — `18` (8, dominant). A let-bound
   lambda `let insertRow = |db, ts| { db_exec(db.clone(), …) }` emits with
   UNANNOTATED params; Rust can't infer `db`/`ts` (used via `.clone()` before
   any type-determining call, inside a generic context) → E0282. FIX: annotate
   closure params from inferred types — `db` flows into `db_exec` arg 0
   (`Db`), `ts` into the SQL-params `Vec<String>` element (`String`). Reuse the
   `inferParamRustType` body-scan (add `db_exec`/`db_query` arg0=`Db` to
   `kernelArgRustType`, and a "Vec<String> element → String" case), rendering
   `|db: Db, ts: String|`. ATTEMPTED + REVERTED (2026-06-10): annotating
   closure params from `ecRegionTypes` does NOT work — the solver records types
   for EXPRESSION regions, not PATTERN (param) regions, so the lookup always
   misses (closures stayed bare, no regression but no effect). The working
   approach must be body-driven: `db` flows into `db_exec` arg0 (add
   `db_exec`/`db_query` arg0→`Db` to `kernelArgRustType`, reuse
   `inferParamRustType`), but `ts` is a Vec ELEMENT (`vec![…, ts]` → `db_exec`
   arg2 `Vec<String>`), NOT a direct call arg — so `inferParamRustType` needs a
   new "param is an element of a Vec-typed kernel arg → element type" case.
   That's the focused-session shape. UPDATE (2026-06-10): the body-driven
   approach is now IMPLEMENTED + regression-free (gated across all 15 builds).
   `annotClosureParam` runs `inferParamRustType` on the closure body and
   annotates each PVar param. inferParamRustType now resolves: (a) DIRECT
   kernel arg (`db`→`db_exec` arg0=`Db`); (b) Vec ELEMENT of a kernel arg
   (`ts`→`db_exec` arg2 `Vec<String>` element=`String`; `errId`→`log_*_with`
   arg1 element); (c) DIRECT arg of a GENERATED stdlib fn via `emittedCalleeName`
   + `genFnArgType` (`e`→`sky_core_error_to_string`=`SkyError`). `18` went
   24→10 (E0282 8→4). REMAINING (the deep last mile): the surviving 4 E0282 are
   USER-CLOSURE-FLOW (`writeAll`'s `db`→the let-bound `insertRow` closure;
   `report`'s `e`→`logAndFail`) — needs a closure-signature pre-pass (collect
   each let-bound closure's inferred param types in definition order, thread a
   `name→[type]` map into ctx, resolve a param flowing into a local closure via
   that map). Plus 18's serde (2 E0277 — likely cascades once E0282 clears and
   model-detection sees concrete view/init types) + 3 E0308 (two are
   `expected String found i64`: Int VALUES — `snapshot.ok` etc — passed in
   `Db.exec … [ok, failed, total, ts]` where the runtime `db_exec` wants
   `Vec<String>`; needs an Int→String coercion at db-param-vec elements,
   reusable + analogous to the f64 coercion, e.g. emit `string_from_int(ok)`
   when a non-String value lands in a `Vec<String>` kernel arg). 18's full
   conquest is a 12-scale interlinked chain (closure-sig pre-pass → E0282
   clears → serde model-detection succeeds → Int→String db-param coercion →
   builds). UPDATE (2026-06-10): driven 24→8, all regression-gated. The
   closure inference now also resolves: `db_exec_raw` arg0=`Db` (clears
   writeAll/readAll's db); USER-CLOSURE-FLOW recursion (`ecClosureDefs` +
   `collectClosureDefs`: a param flowing into a local closure recursively
   infers the target closure's param, cycle-broken via `Map.delete`); and
   db-param-list Int→String via uniform `format!("{}", x)` (heterogeneous
   lists — a List element's region carries the UNIFIED type, so per-type wrap
   mis-fires; Display-based format! is identity for String + decimal for Int).
   REMAINING 8 (the deep cascade — each fix exposes the next, like 12):
   E0373 (a let-bound closure that escapes into a Task pipeline — readAll
   capturing `selectRecent` — needs `move`, with clone-interaction for
   multi-use captures); `report`'s `e` (closure-flow not yet resolved — flows
   into logAndFail but through deeper nesting); serde (2 — should cascade once
   E0282 fully clears); 2 E0308. UPDATE2 (2026-06-10): driven 24→7, all
   regression-gated (wide gate: all 11 builds green). Added: ESCAPING-CLOSURE
   `move` — let-bound closures (defToRustString multi-arg) now emit as `move`
   with capture-clones, mirroring argToRustString's proven pattern (a closure
   captured into a Task pipeline, e.g. `readAll` capturing `selectRecent`, must
   OWN its captures → E0373 otherwise); and `ecClosureDefs` is now set in the
   TypedDef branch too (annotated fns like `withErrorReporting` were missed),
   resolving `report`'s `e` via the closure-flow. REMAINING 7 (cascade keeps
   revealing layers, exactly like 12): 1 E0282 = a RECORD closure param
   (`move |j| { if j.id == jid … }` — needs single-field-access→struct
   resolution, but ecRecordMap keys on the FULL field-set so a 1-field access
   can't match; same limitation as resolveOpenRecordParam); 1 E0271 (a Task
   associated-type mismatch newly exposed by report's e resolving); serde (2,
   cascades once E0282 clears); 2 E0308. UPDATE3 (2026-06-10): driven 24→2
   (ONE real error from building), every step regression-gated. Cleared this
   stretch: E0271 + monomorphic-String E0308 via `taskFailPin` (task_fail's
   success-type turbofish from the expected return type — generic→infer,
   monomorphic→concrete, else i64); `ts` E0308 via element-region inference (a
   db-param list element's type is its OWN region type, not the kernel's
   Vec<String> — db params get `format!`'d); `j` E0282 via HOF-closure
   record-param annotation (`inferRecordClosureParam` resolves a closure record
   param to its struct by field-access usage); db-param Int→String via uniform
   `format!`; serde 2×E0277 via OPEN-RECORD-MODEL resolution (`serdeMatchStruct`
   — an unannotated `view model = …` yields an open record, not a named type,
   so the BFS never stamped MainModel). FINAL BLOCKER (the last error): a
   `Task Error a` LET-POLYMORPHIC phantom return (`sleepThenFail` → `SkyTask<
   i64>` while all callers pin a=String via `Cmd.perform task JobDone`). Sound
   fix = PER-CALL-SITE MONOMORPHIZATION; the generic-return alternative
   (`SkyTask<A>`) regresses the phantom-DISCARD case (E0283), proven twice this
   session. 18 is 1 error from building, isolated to that capability. `18` is a
   multi-fix conquest like `12` was: also
   needs serde model-detection (E0277 — its `MainModel` isn't stamped; likely
   the E0282 leaves `view`/`init` types polymorphic so detection fails),
   arg-count (E0061), and missing kernels (E0425). Tackle as one focused,
   sweep-gated pass using the methodology proven on `12`. (`28`'s E0599 was
   already fixed via branch-aware clone counting — `28` builds.)
6. **Go-FFI on the Rust target (DEFYING — needs Rust-native FFI)** — `03, 05,
   13` (fail early: `.skycache/go/_bindings.go: resource busy` in the FFI gen,
   no Rust emitted) + `08, 16, 17` (emit Rust, but Go-package calls become
   E0425 missing-fns / E0308 / parse junk). These import Go packages
   (`github.com/google/uuid`, `gorilla/mux`, firestore/firebase, …). The Rust
   backend has no bindings for arbitrary Go packages — `examples/rust/` is its
   separate Rust-native FFI set. Conquering these needs the Rust-native FFI
   capability (a roadmap slice), not a codegen patch. The file-lock in `03/05/
   13` is a secondary bug (Rust path mis-reuses the Go FFI pipeline + double-
   opens `_bindings.go`); worth a defensive fix so they emit a clean
   "FFI-unsupported" instead of a lock crash, but the real unblock is native FFI.

7. **codegen emits invalid type-alias LHS** — `35` (`type (String, i64) =
   String;` — an `RAliasDef` whose NAME is a tuple type). A tuple/composite
   type-alias is emitted with the tuple as the alias identifier. Tractable
   emitter fix (suppress / mangle the alias when its key is a structural type).

## Session outcome (2026-06-10)

CONQUERED this session (now build clean on `--target rust`):
`10-live-component` (multi-module Sky.Live + component) and
`28-streaming-chat` (Sky.Live SSE). Plus broad advances: `12-skyvote`
168→75 errors. Scoreboard: gated-6 → 15 building (in-scope 13). NO
regressions (two self-introduced regressions — unconditional-serde-dep and
signature-scoping shadowing — caught by baseline re-verification and fixed).

Root-cause fixes landed (codegen in the Builder blob; runtime committed):
`//`→`/`, +6 stdlib kernels, serde multi-module scoped lookup, DestructDef
tuple-let, multi-module signature scoping (`ecModuleEnv`/`lookupOwnSig`),
tuple-type placeholder guard, SkyMaybe/SkyResult serde + unconditional dep,
branch-aware clone counting.

## Remaining defying classes — implementation plans

Each remaining failure is a designed capability, not a quick patch:

1. **Polymorphic-param monomorphization** — IMPLEMENTED (regression-free).
   `inferParamRustType` (ExprEmitter.hs) scans the body for the first
   `Can.Call` where a TVar param is a direct arg and reads the callee kernel's
   concrete Rust type at that position (`kernelArgRustType`: db_exec/db_query
   arg2→`Vec<String>`, dict_get/member/remove arg1 + dict_keys/values arg0→
   `HashMap<String,String>`). Wired into defToRustItem's body-analysis
   fallback per-param; inferred params drop out of the generics list. Also
   fixed `db_open` (runtime took `()`, ignoring `Db.open`'s `(driver,path)`)
   in BOTH the runtime (db.rs) AND its codegen forwarding wrapper (Emitter.hs)
   — they must move arity together. Result: `12-skyvote` 75→23. Verified no
   regression across 00/04/07/10/28/30/32.
   12's RESIDUAL 23 (diverse tail, each a distinct root cause):
   - **row-polymorphic model params** — PARTIALLY IMPLEMENTED (regression-free).
     `resolveOpenRecordParam` (ModuleEmitter.hs) matches an open record's field
     NAMES against the recordMap (fewest-extras superset) and emits the bare
     concrete struct, bypassing the spurious field-TVar that `Nothing` injects
     (`currentUser : Maybe a`). Wired into BOTH the concrete-gate and the
     body-analysis renderP. Result: 5/6 of 12's auth handlers now resolve
     `model: StateModel` correctly. NOT yet resolved: `handleSignOut`
     (`let _ = println … in (…)` wrapper appears to defeat lookupOwnSig →
     model stays String). KEY FINDING: 12's error count stayed 23 because the
     errors CASCADE — fixing the param layer exposes the next interdependent
     layer (handler bodies, call sites). 12 is a deeply-interdependent
     multi-fix conquest: it needs the WHOLE chain before any single fix moves
     the count. Do it as one focused, sweep-gated pass.
   - **KEYSTONE: TEA msg-polymorphism via Rust generics** (THE root of 12's
     cascade — found by tracing the post-row-poly errors). With `model:
     StateModel` now correct, the 5 fixed handlers fail `expected (), found
     (StateModel, SkyCmd<_>)`: their RETURN type emits `()`. Cause — a handler
     returns `(Model, Cmd msg)` where `msg` is a FREE TVar (`Cmd.none : Cmd
     msg` never pins it), so return-inference (defToRustItem ~line 178) hits
     `hasTypeVars` and falls through to `()`. The polymorphic-`Html msg` view
     return (`ui_components_empty_state`→`()`) and the handler-call mismatches
     in main.rs are the SAME bug. FIX (deep, cross-cutting): emit TEA functions
     GENERIC over their free msg TVar — add the return/param TVars to the
     function's generic list and render the return type with the TVar
     preserved (`fn handle_sign_in<M: Clone>(model: StateModel) -> (StateModel,
     SkyCmd<M>)`); callers (`main_update`) instantiate `M = StateMsg`. This is
     the keystone capability for ALL TEA-heavy examples (12, 18, the
     component/composite set) — nearly every handler/view/update is
     msg-polymorphic. High blast radius (touches core sig + generics
     emission); needs a dedicated session with the full sweep as the gate.
     ATTEMPTED + REVERTED (2026-06-10): the naive version — when return-
     inference gives `()` but the solved return has free TVars, render the
     return preserving the TVar and declare it generic — REGRESSED. 12 went
     23→68 and 00-standard-libs broke. Lessons for the redesign: (a) blanket
     genericization over-fires (stdlib/helper fns whose `()` return is
     legitimate or whose TVar is phantom got spuriously generic); (b) a fn
     made `<msg>`-generic becomes uninferrable at call sites that don't pin
     msg (E0283), so the generic must be introduced ONLY when EVERY call site
     can infer it — i.e. this needs call-graph awareness or monomorphisation
     at the `Live.app` boundary (pin msg = the app's concrete Msg), NOT a
     blanket per-fn generic. The Go backend sidesteps via `any`; the Rust
     port likely needs to thread the concrete app-Msg type down from
     `live_app_routed`'s known `Model`/`Msg` into these fns.
     Remaining 12 tail AFTER this: f64-literal coercion (`Css.pct 100` →
     `100.0`), E0283 turbofish on `auth_hash_password`/nested `std_html_div`,
     and the `handleSignOut` let-wrapper lookupOwnSig miss.
   - **view-returns-`()`** (~2: `expected Html<Msg>, found ()`) — return
     inference defaulting a view branch to unit.
   - **f64 numeric literals** (~2) — Int literal where f64 expected.
   - **E0283 inference ambiguity** (~3) — `auth_hash_password` / nested
     `std_html_div` need turbofish/annotation.

2. **Go-FFI → Rust-native FFI** (blocks `03/05/08/13/16/17`). Major roadmap
   slice: generate Rust bindings for imported Go packages, or a Sky-side
   capability map. Secondary: fix the Rust path's `_bindings.go` double-open
   lock so `03/05/13` emit a clean "FFI unsupported" diagnostic instead of a
   `resource busy` crash.

3. **Stored-effectful-callback representation** (blocks `33`). Unified
   `Arc<dyn Fn + Send + Sync>` for STORED function values (record fields + ADT
   variants) with `Arc::new` wrap at construction; relax `paramTypeToRust`'s
   Task-gate for stored (vs kernel-passed) callbacks.

4. **Local-closure param annotation** (blocks `18`). Let-bound lambdas emit
   `|db, ts| …` with no param types → E0282. Annotate from `_stRegions`
   (per-region solved types) at the lambda's param patterns.

5. **Composite-generics tail** (`35`) — deep; re-triage after class 1.
