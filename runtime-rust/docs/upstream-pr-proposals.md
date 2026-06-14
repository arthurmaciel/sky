# Upstream PR proposals (DRAFT — for review, NOT pushed)

Two Go-target codegen fixes. Root cause + repro + **suggested code** below.
Awaiting approval before any implementation lands or is pushed.

---

## PR 1 — `fix(go): lambda param with an out-of-scope type var emits `undefined: T1``

> **STATUS: IMPLEMENTED + VERIFIED locally (commit `5ac3aeb1`), NOT pushed.**
> Fix landed at `typedLambdaParam` (`src/Sky/Build/Compile.hs`) per the suggested
> approach below. Verified: `00-standard-libs` go-builds; 07/09/12/16/19/26/27
> (lambda/HOF/Live-heavy) still go-build (no regression); cabal test no failures.
> Ready to cherry-pick into a clean Go-target PR on your approval.

**Severity:** build-breaking. `examples/00-standard-libs` (the stdlib smoke test)
fails `go build`.

**Reproduce**
```
$ cd examples/00-standard-libs && sky build src/Main.sky
Sky lowering succeeded
Running go build...
./main.go:1143: undefined: T1
```

**Trigger:** any `Sky.Core.Task` retry predicate, e.g. (in `taskRetrySuite`):
```elm
retryOn     (\_ -> False) (linearBackoff 5 1)
withRetryOn (\_ -> True)  defaultRetryPolicy
```

**Root cause.** `ShouldRetry e = RetryAlways | RetryWhen (e -> Bool)` makes `e`
**phantom** in `RetryPolicy e`. `retryOn` is generic:
```go
func Sky_Core_Task_retryOn[T1 any](predicate func(T1) bool, policy Sky_Core_Task_RetryPolicy_R[T1]) …
```
At a call site inside a **non-generic** function (`taskRetrySuite`), the predicate
lambda `\_ -> False` is coerced to the callee's parameter type `func(T1) bool`,
and `T1` is emitted verbatim:
```go
// main.go:1143 — inside the non-generic taskRetrySuite()
policy := Sky_Core_Task_retryOn(func(_ T1) bool { return false }, Sky_Core_Task_linearBackoff(5, 1))
//                                       ^^ T1 is not a generic param of taskRetrySuite → undefined
```
The codegen already erases out-of-scope type vars to `any` for **return** types
(`substituteOnly`, `src/Sky/Build/Compile.hs:~9438`, via
`eraseTypeParamsExceptScope enclosingTypeParamInScope`). The **call-argument
lambda-parameter** path doesn't apply that same erasure.

**Suggested fix.** In the call-argument lambda coercion (where a `Can.Lambda`
argument's parameter types are taken from the callee signature — the
`coerceCallArgsAt` / `lowerTypedLambda` param-type construction in
`src/Sky/Build/Compile.hs`), run each rendered param type through the existing
out-of-scope eraser before emission:
```haskell
-- each lambda-arg param type, before building the GoParam:
let pty' = if any (not . enclosingTypeParamInScope) (tvarsInGoTypeStr pty)
              then eraseTypeParamsExceptScope enclosingTypeParamInScope pty  -- T1 → any
              else pty
```
Equivalently, a guard that bails such a lambda to the generic path (which already
emits `func(_ any) bool`). The helpers (`enclosingTypeParamInScope`,
`tvarsInGoTypeStr`, `eraseTypeParamsExceptScope`) already exist and are used for
the return-type case — this reuses them for the parameter-type case.

**Test plan.** `00-standard-libs` `go build` + run green; a focused cabal spec
(`retryOn (\_ -> False) p` lowers the predicate as `func(_ any) bool`); full
`cabal test` + the example sweep stay green (the change only affects lambdas whose
param type is an unbound tyvar — currently the broken cases — and leaves
properly-bound generic lambdas untouched).

---

## PR 2 — `feat(go): run-once semantics for top-level effectful value bindings`

> **STATUS: IMPLEMENTED + VERIFIED locally (render-time form), NOT pushed.**
> Lands at `renderFuncDecl` (`src/Sky/Generate/Go/Builder.hs`) + a tiny
> `rt.OnceValue` wrapper (`runtime-go/rt/once.go`). Verified (clean rebuilds):
> `27-multi-session-chat` memoises exactly `dbConn` + `initSchema` (the intended
> targets) — `GET / → 200`, `chat.db` table created once, no panic;
> `07-todo-cli` memoises **nothing** (`Task.run` correctly stays a plain func,
> `showUsage` not memoised) and CRUD works; `00-standard-libs` memoises only the
> pure `taskRetrySuite` (harmless — see below) and all 131 assertions pass.
> The earlier "over-fire" concerns are resolved: the `func(`/`SkyTask`-return
> exclusions are reliable (07 proves both are excluded). **One genuine design
> decision is flagged below — surface to the maintainer before merge.**
>
> **Why render-time turned out fine.** The original lesson (below) feared the
> exclusions were unreliable and the nested-closure case unsafe. Empirically:
> (a) the `func(`/`SkyTask` ret-string exclusions DO fire correctly per call
> site (07's `Task.run`/`showUsage` stay un-memoised); (b) the lone residual
> false-positive — `taskRetrySuite` in 00, whose `AnyTaskRun` lives in nested
> test closures — is **provably harmless**: Sky value-construction is pure, so
> caching the built `Sky_Test_Test` value is observationally identical (the
> deferred closures still run their effects when invoked). The **AST-level form
> remains the recommended shape for the actual merge** (it avoids even the
> cosmetic over-memoisation of pure-value CAFs); the render-time form shipped
> here is the verification vehicle that proves the run-once semantics + perf win
> are correct.

**Severity:** performance. A Sky.Live app re-runs schema/connection setup on
every request.

**Symptom.** A top-level value binding whose body runs an effect re-runs that
effect on **every reference**:
```elm
dbConn     = case Task.run (Db.connect ()) of Ok c -> c | Err e -> …
initSchema = let _ = Task.run (Db.execRaw dbConn "CREATE TABLE IF NOT EXISTS …") in ()

init req = let _ = initSchema in ( … )   -- runs per new Sky.Live session
```
`init` runs per cookie-less request, so `CREATE TABLE IF NOT EXISTS` (and a
`Db.connect`) execute on **every request** to a Sky.Live app — measurable
per-request overhead on the hot path.

**Root cause.** A top-level non-function value binding (a CAF) lowers to a nullary
function re-evaluated at each reference:
```go
func dbConn() *rt.SkyDb { … Db_connect … }
func initSchema() struct{} { … Db_execRaw("CREATE TABLE …") … return struct{}{} }
```
The intuitive Elm/Haskell-family reading of a top-level `dbConn = …` is a single
value, not a per-reference re-computation.

**Render-time form shipped here (history kept for the maintainer).** An initial
naive gate that string-scanned the rendered body for `AnyTaskRun` with NO return
exclusions over-fired — it memoised `Sky_Core_Task_run` (fn-returning) and
`showUsage` (`SkyTask`-returning). Adding two ret-string exclusions
(`not ("func(" isInfixOf ret)`, `not ("SkyTask" isInfixOf ret)`) fixed both
(verified per the STATUS block). The only residual is `taskRetrySuite` (whose
`AnyTaskRun` is in nested test closures) — harmless because Sky value
construction is pure. The cleaner **AST-level** variant below avoids even that
cosmetic over-memoisation by gating on the CAF's *own tail expression* (mirroring
the Rust backend's `maybeMemoiseNullary`); it is the recommended final shape and
the maintainer may prefer to merge that form instead of the render-time one.

**Exact implementation spec (corrected — AST-level).**
- **Site:** the top-level `Can.Def` → `GoFuncDecl` lowering in
  `src/Sky/Build/Compile.hs` (~line 4586, where `name`/`params`/`body` are in
  scope). Gate on the **Can AST**, not rendered strings: nullary
  (`null params`), `name` not `main`/`init`, the binding's solved return type is
  a concrete value (NOT a function type and NOT `Task …`), and the body's
  **own tail expression** runs a Task (a direct `Task.run`/effect at the CAF's
  top level — NOT inside a nested lambda/closure). This is exactly the Rust
  `maybeMemoiseNullary` predicate, ported to the Go canonical AST. Then emit a
  memoised var instead of a plain func:
  ```go
  var <name> = sync.OnceValue(func() <RetType> { <body> })   // Go 1.21+
  ```
  Call sites already emit `<name>()`, which still calls the `func() RetType` —
  no call-site change. (Pre-1.21 fallback: package `var <name>__once sync.Once`
  + `var <name>__val RetType` + an accessor, below.)
- **Import:** the generated `main.go` must `import "sync"` when any CAF is
  memoised — wire it into the import-set computation (the same place that decides
  `"sync"` vs other std imports), gated on "≥1 memoised CAF emitted".
- **Unit return:** `initSchema : ()` lowers to `struct{}` — emit
  `sync.OnceValue(func() struct{} { <body>; return struct{}{} })`.
- **Scope gate:** effect-running CAFs only (mirrors the Rust backend's shipped
  `maybeMemoiseNullary`, gated on `task_run` in the body) — confirm whether to
  widen to all value CAFs.
- **Verify:** 00-standard-libs tests pass; 07-todo-cli CRUD + 27-multi-session-chat
  run correctly (the CAF runs once); a non-CAF example unaffected; full Go sweep.

**Fallback / package-`sync.Once` form** (if Go < 1.21):
```go
// emitted for a memoised top-level value binding `name = <body> : T`
var name__once sync.Once
var name__val  T
func name() T {
    name__once.Do(func() { name__val = func() T { return <body> }() })
    return name__val
}
```
In the Go codegen's top-level-Def emission (`mkDef`), when a binding has zero
parameters and a concrete return type, emit the `sync.Once` form instead of the
plain `func name() T { return <body> }`.

**Design decision to confirm (for the maintainer).**
- **Scope.** Memoise *all* top-level value bindings, or only effect-running ones
  (body contains `Task.run` / `AnyTaskRun`)? The conservative choice is
  effect-running only — pure constants are cheap to recompute and memoising them
  only adds a `sync.Once` per reference. The broad choice is simpler and matches
  CAF semantics uniformly.
- **Observable change.** Run-once is a behaviour change for a *non-idempotent*
  effectful CAF (e.g. a top-level `x = Task.run (appendFile …)` referenced
  twice would run once instead of twice). For the idempotent setup it targets
  (`connect`, `CREATE TABLE IF NOT EXISTS`) it is observably equivalent and the
  evident intent. Worth a deliberate call before merge.

**Test plan.** A Sky.Live example's per-request cost (`init`-path) drops; a cabal
spec asserting a top-level `x = Task.run effect` referenced twice runs the effect
once; verify no example relies on per-reference re-execution of a top-level CAF;
full sweep green.

---

### Status
Proposals only — not implemented, not committed to any shared codegen, not pushed.
On approval I'll implement, run the full `cabal test` + example sweep, and prepare
the PRs.
