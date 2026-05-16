# Plan: Fix Rust codegen errors blocking example 07 (todo CLI)

## Context

Sky's Rust backend (`src/Sky/Generate/Rust/Builder.hs`, ~1051 lines) emits a Cargo project from canonicalised Sky AST when `--target rust` is passed. Example 07 (todo CLI: SQLite-backed `add/list/done/undone/remove/clear` with the canonical Task-everywhere effect-boundary pattern) is the next target after the `09-live-counter`-class examples — it exercises a wider stdlib surface (Maybe, List recursion, Db FFI, Task chains with multi-use captures).

Fresh baseline after `cabal install` of the current source (HEAD `48971d5` + unstaged Builder.hs work on `ecCloneVars`/`hasCloneBound`):

```
cd examples/07-todo-cli && rm -rf sky-out .skycache .skydeps
sky-out/sky build src/Main.sky --target rust   # OK
cd sky-out/Rust && cargo build                 # 24 errors
```

All 24 errors collapse into **two root-cause categories**. The intervening commits (`80b0f4c`, `48971d5`) and unstaged closure-clone work already fixed five other classes that were live yesterday (Pin<Box> Clone on `Task_run` arg, zero-arg `match` arm fn-pointer, `Main_getArg` param falling back to `SkyValue`, multi-use `idStr/todoTitle` move-after-capture, `Db_getField` row-type mismatch). Don't re-fix those; do verify they stay green after the new patches.

## Root Cause 1 — Unsound `hasCloneBound = needsClone` heuristic strips Clone bound from generic stdlib functions (22 of 24 errors)

The unstaged change in `src/Sky/Generate/Rust/Builder.hs:232,239,241` replaced the always-on `T: Clone` with:

```haskell
needsClone = bodyUsesList body          -- True only if body has a cons/list pattern
hasCloneBound = needsClone
genList = map (\tv -> tv ++ (if hasCloneBound then ": Clone" else "") ++ extraBound tv) tvars
```

Intent: stop adding spurious `Clone` to inspect-only helpers (`isEmpty`/`length`/`isNothing`). Effect: many stdlib functions whose body **does** invoke `.clone()` on type-var-bound parameter values lost their bound and stopped compiling:

| Function | Body shape that needs the bound | Example error |
|---|---|---|
| `Sky_Core_Maybe_map` / `andThen` / `andMap` | `match m { Just(x) => fn(x.clone()) ... }` | `clone` not found for `T0` (line 388) |
| `Sky_Core_Maybe_map2`..`map5` | `fn(a.clone(), b.clone(), ...)` | `clone` not found for `T0..T4` (lines 394–404) |
| `Sky_Core_List_indexedMap` (line 334) | `indexedMapHelp(fn.clone(), 0, list.clone())` — body does NOT have a cons pattern (delegates), but call-site `.clone()` injection at codegen needs `T0: Clone` | `Vec<T0>` clone bound unsatisfied (335) |
| `Sky_Core_List_reverse` (line 355) | `reverseHelp(list.clone(), vec![])` — same shape | `Vec<T0>` clone bound unsatisfied (356) |
| `sky_list_cons` callers via `cons_no_clone` path (line 352) | `sky_list_cons(x, list)` is fine, but bound on outer fn was stripped | `T0: Clone` not satisfied at 353 |

The heuristic is fundamentally wrong: it scans for **list patterns in the source body**, but the question we actually need to answer is "does the **emitted Rust body** invoke `.clone()` on a value of one of the type-var slots?". The codegen itself injects clones (in `Can.Call` arg lowering, in cons-pattern bind unpacking, in `let x = x.clone()` capture preludes), so the source-AST view has no idea.

### Fix 1A — Replace the heuristic with a body-usage scan

In `defToRustItem` (Builder.hs line 233-243), after computing `paramStrs` and `tvars`, compute Clone need from actual parameter usage in the body:

```haskell
-- A type var T_i needs Clone iff its associated parameter is referenced
-- ≥ 2 times in the body (each non-final use becomes .clone() at emit).
-- Also true if the param appears as a bound in a cons-pattern bind
-- (cons unpacking always emits .clone()/.to_vec()).
let paramNames = [ n | p <- params, n <- patBindingVars p ]
    counts      = collectVarLocalsMulti body
    cloneNeeded = any (\n -> Map.findWithDefault 0 n counts >= 2) paramNames
                  || bodyUsesList body  -- existing cons-pattern signal
    hasCloneBound = cloneNeeded
```

Conservative but correct: any parameter referenced ≥ 2 times will trigger ≥ 1 `.clone()` in the emitted Rust, so its type var must be `Clone`. The `bodyUsesList` term keeps cons-pattern unpacks covered (where the binding extracts a `&T` ref and we emit `.clone()`/`.to_vec()`).

### Fix 1B — Pessimistic fallback (simpler, accept a few spurious bounds)

If 1A is too tight, the safest revert is to always emit `Clone` for any type var — that's what HEAD-1 did, with no compile errors. Accept the small DX regression of `: Clone` on `isEmpty<T0: Clone>`. The cost is zero (Clone is a marker; it doesn't run code; Rust's monomorphisation drops unused bounds).

**Recommendation: ship 1A.** It's ~6 lines, doesn't regress the original "Clone everywhere" goal of the unstaged change, and matches the actual codegen contract.

### Critical files

- `src/Sky/Generate/Rust/Builder.hs:228-243` — `defToRustItem` Def branch (emit-time Clone bound decision)
- `src/Sky/Generate/Rust/Builder.hs:484-516` — `Can.Call` arg lowering (the actual `.clone()` injection site)
- `src/Sky/Generate/Rust/Builder.hs:117-127` — reuse `patBindingVars` (already exists)
- `src/Sky/Generate/Rust/Builder.hs:147-186` — `collectVarLocalsMulti` (already exists, used by `LetDestruct`)

## Root Cause 2 — Closure parameter type can't be inferred at higher-order kernel call sites (1 error E0282)

`src/main.rs:281`:

```rust
Task_map(move |rows| {
    if Sky_Core_List_isEmpty(rows.clone()) { ... }
    else { let lines = Sky_Core_List_map(Main_formatTodo, rows.clone()); ... }
})(Db_query(conn.clone(), "...", vec![]))
```

`Task_map<F, A, B>(f: F)` is fully generic. The closure's `rows` would have type `A` of `Task_map`, which is determined by `Db_query`'s return `SkyTask<Vec<HashMap<String, String>>>` (or `SkyTask<Vec<String>>` with the current stub). But `Sky_Core_List_isEmpty<T0>(rows: Vec<T0>)` is itself generic in `T0` — Rust's type-inference can't pin `rows` and gives up with E0282.

This is structural: every `Task.map` / `Task.andThen` / `Task.onError` / `Cmd.perform` lambda emitted today is at risk of the same failure as soon as the body uses a generic helper on the captured value.

### Fix 2 — Inject explicit closure-parameter type from solvedTypes

Two places need changing in `src/Sky/Generate/Rust/Builder.hs`:

1. **`Can.Call` arg lowering** (line 502-514) — the existing branch that recognises a `Can.Lambda` argument:
    ```haskell
    Ann.At _ (Can.Lambda ps body) ->
        ... clones, captured, ...
        in if null captured
           then "move |" ++ psStr ++ "| { ... }"
           else "{ " ++ clones ++ "move |" ++ psStr ++ "| { ... } }"
    ```

   Replace `psStr` (untyped) with a typed-param renderer that consults solvedTypes. The lambda's parameter binding name (e.g. `rows`) is a `Can.PVar` we can look up — but solvedTypes is keyed by **top-level decl** name, not local binders, so we have to derive the type from the *enclosing* call.

2. **The actual derivation** — for the closure passed to a known higher-order kernel (`Task.map`, `Task.andThen`, `Task.onError`, `Cmd.perform`, `Result.map`, `Maybe.map`, `List.map`, `List.filter`, `List.foldl/r`, etc.) the closure's expected param type is fully determined by the *other* arguments to the call:

    | Kernel | Lambda position | Lambda param type |
    |---|---|---|
    | `Task.map f t` | f | inner of `t : SkyTask<A>` → `A` |
    | `Task.andThen f t` | f | inner of `t : SkyTask<A>` → `A` |
    | `Task.onError f t` | f | `SkyError` |
    | `Cmd.perform f t` | f | inner of `t : SkyTask<A>` → `A` |
    | `Result.{map,andThen,withDefault} f r` | f | inner-Ok of `r : SkyResult<A,E>` → `A` |
    | `Maybe.{map,andThen,withDefault} f m` | f | inner of `m : SkyMaybe<A>` → `A` |
    | `List.{map,filter,find,any,all,foldl/r} f xs` | f | element of `xs : Vec<T>` → `T` |

    Since we already do this kind of lookup for `knownDefSig` (Builder.hs line 130-194), add a sibling helper `knownLambdaArgType :: ModuleName -> String -> Int -> EmitCtx -> [Can.Expr] -> Maybe String` that, given the kernel callee + arg index of the closure + the *other* args, derives the lambda's expected Rust type by inspecting the other arg's `solvedTypes` lookup.

    ```haskell
    -- Sketch
    closureParamType ctx callee otherArgs = case callee of
        VarKernel mod "map" | mod is Task ->
            inferTaskInner ctx (head otherArgs)  -- Task<A> -> A
        VarKernel mod "andThen" | mod is Task -> ...
        ...
    ```

    Then in `Can.Call` arg lowering, when a Lambda arg is detected, call this helper. If it returns `Just t`, emit `move |rows: t| { ... }`; otherwise fall back to the current untyped form.

3. **No type system change needed in HM** — solvedTypes already contains the call-site monomorphisation. The codegen just hasn't been threading it into closure emission.

### Critical files

- `src/Sky/Generate/Rust/Builder.hs:492-517` — `Can.Call` branch where Lambda args are emitted
- `src/Sky/Generate/Rust/Builder.hs:130-194` — `knownDefSig` table (extend with sibling `knownHofClosureParam`)
- `src/Sky/Generate/Rust/Builder.hs:310-339` — `typeToRustString` (reuse for the type-string emission)

## Optional Root Cause 3 (runtime correctness, currently NOT a compile error) — Db stubs misrepresent SQL row shape

`src/main.rs:198-199`:
```rust
pub fn Db_query(_conn: Db, _sql: String, _params: Vec<String>) -> SkyTask<Vec<Vec<String>>>
pub fn Db_getField(_field: String, _row: String) -> String { String::new() }
```

Sky's kernel says (`src/Sky/Type/Constrain/Expression.hs:2143-2159`): `Db.query` returns `Task Error (List (Dict String String))` and `Db.getField : String -> Dict String String -> String`. The current Rust stubs use `Vec<Vec<String>>` for the result list element and `String` for the row, which compile only because:
- `Main_formatTodo(row: SkyValue)` falls back to `SkyValue = String` (the universal alias),
- `Db_getField` accepts `String`,
- the List_map call `Sky_Core_List_map(Main_formatTodo, rows.clone())` infers `T0 = Vec<String>` — wrong shape, but type-checks.

At runtime, every `getField` returns `String::new()` so even if `cargo run ./app list` succeeds, the printed rows would all be empty. **This is invisible today because the stub bodies always return `Ok(vec![])`** — the list is always empty and `formatTodo` is never called.

If the goal is just "compile cleanly" then skip this section. If the goal is "compile + run the todo flow against a real SQLite DB", the fix is:

1. Add `use std::collections::HashMap;` to the runtime preamble (Builder.hs `emitRust` runtime block, around line 880).
2. Change Db stubs (Builder.hs line 893-899):
    ```rust
    pub fn Db_query(_conn: Db, _sql: String, _params: Vec<String>)
        -> SkyTask<Vec<HashMap<String, String>>> { Box::pin(ready(SkyResult::Ok(vec![]))) }
    pub fn Db_getField(_field: String, _row: HashMap<String, String>) -> String {
        _row.get(&_field).cloned().unwrap_or_default()
    }
    ```
3. Update `typeToRustString` (Builder.hs line 310-339) to map `Can.TType _ "Dict" [k, v]` → `HashMap<{k}, {v}>` (currently falls through to `SkyValue`).
4. Wire actual SQLite — adopt `rusqlite` as a Cargo dep, replace stub bodies with `Connection::open` / `prepare` / `query_map` calls. This is a multi-day effort and unrelated to the codegen errors; defer until the codegen surface is stable.

**Defer 3.4** for this fix scope; do 3.1-3.3 only if you want runtime correctness for `./app list` to print real rows.

## Verification

After both fixes land:

```bash
# 1. Rebuild compiler (mem-guard must be running per CLAUDE.md non-negotiable)
pgrep -f mem-guard.sh >/dev/null || (nohup ./scripts/mem-guard.sh > /tmp/mem-guard.out 2>&1 & disown)
cabal install --overwrite-policy=always --installdir=./sky-out --install-method=copy exe:sky

# 2. Clean rebuild + cargo build of example 07
cd examples/07-todo-cli && rm -rf sky-out .skycache .skydeps
../../sky-out/sky build src/Main.sky --target rust
cd sky-out/Rust && cargo build       # expect 0 errors

# 3. Smoke-test runtime path
cargo run -- help                    # prints usage from showUsage
cargo run -- list                    # prints "No todos yet..." (empty rows)

# 4. Regress-check the other examples that compiled to Rust before
for d in examples/01-hello-world examples/14-task-demo examples/04-local-pkg; do
    cd "/home/arthur/Documentos/comp/sky/$d"
    rm -rf sky-out .skycache .skydeps
    /home/arthur/Documentos/comp/sky/sky-out/sky build src/Main.sky --target rust
    cd sky-out/Rust && cargo build
    cd /home/arthur/Documentos/comp/sky
done
```

Acceptance: `cargo build` exits 0 for example 07; `cargo run -- help` prints the usage block; the three regression examples still compile.

If Fix 3 is also applied: `./app list` (with a fresh empty `todos.db`) prints "No todos yet..."; `./app add "buy milk"` then `./app list` prints `1. [ ] buy milk`. Without Fix 3.4 (real rusqlite), persistence is no-op — that's expected and out of this plan's scope.
