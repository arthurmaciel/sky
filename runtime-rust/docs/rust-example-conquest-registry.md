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
   (E0308 ×100+). Fix: `scopeCtxToModule` layers each module's own
   `_stPerModuleEnv[M]` over the flat map in `buildProgram` so dep-module
   signatures resolve authoritatively. Same family as the serde 1a fix.
   NOTE: `08`/`17` ALSO carry Go-FFI deps (class 3 below), so the E0308 fix
   advances but may not fully clear them; `12` is pure-Sky so it's the
   keystone verifier.
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

## Next actions (tractable-first)

- **TRY:** `33-websocket-echo` (4 E0308), `17-skymon` (brace bug — confirm not
  let-wrap), then the E0425 missing-kernel enumeration for `08`.
- **PLAN:** the serde multi-module model-detection (class 1) and the mass-E0308
  root cause (class 2) — these are the defying ones; design before coding.
- **RE-DIAGNOSE:** `03, 05, 13` (capture fresh errors).
