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

**Builds (12 in-scope):** `00, 01, 04, 07, 09, 14, 15, 20, 30, 32, simple, test_pkg`
— doubled from the gated-6 this session via codegen fixes (let-wrap, task_fail
turbofish, Live entry-main, Live init generics, canDefBody) + runtime kernels
(server_redirect, time_every, debug_to_string).

**In-scope crashes: none** (canDefBody cleared them).

## Failing in-scope examples (12) — by root-cause class

| # | Example | Class | Root-cause diagnosis | Status |
|---|---|---|---|---|
| 10 | live-component | serde (E0277) | `collectLiveSerdeTypes` model-detection fails on **multi-module** apps (Main + Counter component); `MainModel` not stamped with serde derive. `view : Model -> Html Msg` is a clean VarTopLevel, so the failure is the cross-module solved-type lookup, not the field shape. | **REGISTER** — needs robust multi-module model-type detection. |
| 12 | skyvote | E0308 ×142 + serde | mass type-mismatch (likely one systematic lowering bug emitting a wrong type pervasively) + serde. The E0308 volume must be root-caused first (one fix likely clears most). | **REGISTER** — diagnose the mass-E0308 source. |
| 08 | notes-app | E0308 ×111 + E0425 ×21 | mass type-mismatch + 21 missing functions/kernels. | **REGISTER** — split: enumerate the missing kernels; root-cause the mass E0308. |
| 18 | job-queue | E0282 ×8 + E0277 ×6 | type-inference (annotation-needed) + serde. | needs diagnosis |
| 28 | streaming-chat | E0277 ×4 + E0599 ×2 | serde + a missing method (E0599). | needs diagnosis |
| 33 | websocket-echo | E0308 ×4 (stored-effectful-callback) | NOT a simple mismatch. `paramTypeToRust`'s Task-result gate (TypeEmitter.hs:132) renders effectful callbacks as `impl Fn` (for kernel-HOF flow, e.g. ex-32 `forEachChunk`), but the stdlib `withOnX` setters STORE the effectful callback into a `fn`-pointer record field (`WsServerCfg.onConnect: fn(...)`, runtime server.rs:399). `impl Fn` ≠ `fn` ptr. Naive global flip regresses ex-32. | **REGISTER** — needs unified `Arc<dyn Fn + Send + Sync>` representation for STORED function values (record fields + ADT variants) + `Arc::new` wrap at construction sites. Cross-cutting codegen change. |
| 16 | skychess | parse: `found '.'` / `found keyword move` | codegen emits malformed Rust (a closure/method-chain shape). | needs diagnosis |
| 17 | skymon | parse: unclosed/mismatched `}` delimiter | codegen brace imbalance — verify it's not a let-wrap interaction (matrix passed, but check). | **TRY NEXT** (brace bug) |
| 35 | composite-generics | parse: `expected identifier, found '('` | malformed Rust from a generics/composite shape. | needs diagnosis |
| 03 | tea-external | unknown (sweep log empty) | needs re-diagnosis (rebuild + capture). | needs diagnosis |
| 05 | mux-server | unknown (sweep log empty) | needs re-diagnosis. | needs diagnosis |
| 13 | skyshop | unknown (sweep log empty) | needs re-diagnosis (large FFI example). | needs diagnosis |

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
5. **type-inference (E0282) / missing method (E0599)** — `18, 28`.
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
