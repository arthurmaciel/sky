# Sub-A.12 — Codegen polymorphism fixes — Design

**Date:** 2026-05-30
**Status:** Approved — ready for plan
**Scope:** Three focused codegen fixes targeting the final 7 cargo errors on `examples/00-standard-libs` target=rust.
**Branch:** `feat/runtime-rust`
**Builds on:** Sub-A.11 (`e814bc90..398b5c5e`).

---

## 1. Context

After sub-A.11, error count is **7** on `examples/00-standard-libs` target=rust (-97% from the 232 baseline). All four error classes share a root cause: the codegen emits Sky-source wrapper signatures with type parameters over-specialised to concrete types (`String`, `SkyError`, etc.) instead of leaving them generic.

## 2. Verified errors → fixes

| # | Cargo error | Root cause | Fix |
|---|---|---|---|
| F1 | `sky_core_result_map_error(closure, …)` E0308: closure expected `String`, found `SkyCoreErrorError` (2 errors) | `resultSig "mapError"` hardcodes `Fn(SkyError) -> String` instead of generic `Fn(T1) -> T2`. Sky source `mapError : (e -> e2) -> Result e a -> Result e2 a` is fully polymorphic. | Edit `resultSig "mapError"` in Builder.hs to use generic T-vars: `["impl Fn(T1) -> T2 + Clone", "SkyResult<T1, T0>"]` returning `"SkyResult<T2, T0>"`. |
| F2 | `sky_core_jwt_validate_time(now)` E0061: takes 2 args but 1 supplied (2 errors) | Sky source `result_and_then (validateTime now) (...)` is partial application — `validateTime now` returns `String -> Result Error String`. Codegen emits literal `sky_core_jwt_validate_time(now)` instead of wrapping in a closure. | Detect partial application at the `Can.Call` arm: when `length args < arity`, emit `\|<fresh>\| f(args..., <fresh>)` closure. |
| F3 | `sky_core_list_head(vec![])` E0283 + `sky_core_maybe_map(closure, SkyMaybe::Nothing)` E0283 (3 errors) | Empty `Vec::new()` and `SkyMaybe::Nothing` literals passed to generic functions; no context to pin generic type params. | Codegen-level type-default for empty literals: detect `vec![]` / `SkyMaybe::Nothing` in unconstrained call positions and emit `Vec::<i64>::new()` / `SkyMaybe::<i64>::Nothing`. |

## 3. Goal

After this work:
1. `examples/00-standard-libs` on `target=rust` compiles with **0 errors**.
2. Binary runs and prints **`120 passed, 0 failed (120 total)`** — matching `target=go`.
3. 16/16 `examples/rust/*` still build and run.
4. Go path byte-identical.

If F2 (partial application) or F3 (empty-literal defaulting) turns out to need substantial codegen surgery beyond a focused fix, defer and document.

## 4. Design — surgical changes

### F1 — `resultSig "mapError"` generic

Single-line change in `Builder.hs`:

```haskell
-- before:
resultSig "mapError" 2 = Just (["impl Fn(SkyError) -> String + Clone", "SkyResult<SkyError, T0>"], "SkyResult<String, T0>")
-- after:
resultSig "mapError" 2 = Just (["impl Fn(T1) -> T2 + Clone", "SkyResult<T1, T0>"], "SkyResult<T2, T0>")
```

`sigTVars` (line 558) already infers T-vars from the signature strings and adds matching `T1: Clone, T2: Clone` bounds. Should Just Work.

### F2 — Partial application wrap

At the `Can.Call fn args` arm of `exprToRustInner`, check if the callee is a known function with a fixed arity > `length args`. If so, emit:

```rust
{ let __pa1 = ...args[0]...; ... let __paN = ...args[N-1]...;
  move |__r1, __r2, ...| f(__pa1, ..., __paN, __r1, __r2, ...) }
```

Detection: look up the callee's arity in `ecCtorArity` or `ecSolvedTypes`. When the call is partial (e.g. `(validateTime now)` is `Can.Call _ [now]` but validateTime takes 2 args), wrap the residual args in a `move` closure.

The simplest fix targets the specific pattern: `Can.Call f [arg]` where `f` resolves to a 2-arg function. Generalise from there if other shapes surface.

### F3 — Empty literal defaulting

Two cases:
- `Can.List []` → currently emits `"vec![]"`. Change to emit `"Vec::<i64>::new()"` (or detect from context).
- `Can.VarCtor _ _ "Maybe" "Nothing" _` → currently emits `"SkyMaybe::Nothing"`. Change to `"SkyMaybe::<i64>::Nothing"` when unconstrained.

The "unconstrained" detection is tricky — pragmatic default is to ALWAYS emit the turbofish on empty/Nothing literals. The Rust compiler tolerates unnecessary turbofish (it just gets the same i64 inference). For real value-typed cases, Rust's inference picks up the contextual type and the i64 default is overridden (NO it's not — turbofish is final).

Hmm. Better: only emit the turbofish when codegen detects an empty-literal in a generic-function-arg position where no other arg can pin the type.

Simplest implementation: at the `Can.List []` emission site, look at the call context (via `ecPipeInnerType` or a similar new mechanism). If empty + no context → `Vec::<i64>::new()`; if context provides a type → use that.

If context propagation is hard, fallback: ONLY in the specific `List.head []` / `Maybe.map _ Nothing` call sites (small whitelist of known-problem callees) inject the default.

## 5. Risks

| Risk | Mitigation |
|---|---|
| F1's generic change breaks existing mapError uses elsewhere in the corpus | 16-example sweep + cabal test after the change |
| F2's partial-application wrap needs the callee's arity reliably | Use `ecCtorArity` + `ecSolvedTypes` lookup; conservative: only wrap when arity is provably ≥ args+1 |
| F3's defaulting interferes with real polymorphic uses | Scope to empty-only literals; rust's `Vec::<i64>::new()` is functionally identical to `vec![]` of i64 — only affects unconstrained inference |

## 6. Verification

Per fix: build + 01-rand smoke + 00-standard-libs error count snapshot.
Final: 16-example sweep + Go regression + cabal test + headline gate.

## 7. Out of scope

- Anything outside `examples/00-standard-libs`.
- General codegen-polymorphism refactor of `knownDefSig`'s entire design (sub-B+ if needed).
