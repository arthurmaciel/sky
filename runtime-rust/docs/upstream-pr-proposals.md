# Upstream PR proposals (DRAFT — for review, NOT pushed)

Two Go-target codegen fixes. Root cause + repro + **suggested code** below.
Awaiting approval before any implementation lands or is pushed.

---

## PR 1 — `fix(go): lambda param with an out-of-scope type var emits `undefined: T1``

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

**Suggested fix.** Memoise top-level (non-function, zero-parameter) value bindings
to run-once with a package-level `sync.Once`:
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
