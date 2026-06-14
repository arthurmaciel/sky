# Upstream PR proposals (DRAFT — for review, NOT pushed)

Two fixes for the **Go backend** (the upstream reference), surfaced by the Rust
parity work. Both are upstream/shared-compiler changes, so per the fork's
boundary rules they are proposed here for approval — **not committed, not
pushed**. On approval I'll implement + verify (full `cabal test` + example
sweep) and prepare the actual PR.

---

## PR 1 — `fix(go): unbound lambda-param type var emits undefined `T1``

**Severity:** build-breaking regression (~v0.16.29). Blocks `00-standard-libs`,
the stdlib smoke test.

**Symptom**
```
$ cd examples/00-standard-libs && sky build src/Main.sky
./main.go:1143: undefined: T1
```

**Reproduce:** any use of the retry surface's predicate, e.g.
```elm
retryOn (\_ -> False) (linearBackoff 5 1)
withRetryOn (\_ -> True) (defaultRetryPolicy)
```
`00-standard-libs` exercises this in `taskRetrySuite`.

**Root cause.** `Sky.Core.Task` defines
```elm
type ShouldRetry e = RetryAlways | RetryWhen (e -> Bool)
type alias RetryPolicy e = { …, shouldRetry : ShouldRetry e }
```
`e` is **phantom** in `RetryPolicy e` / `ShouldRetry e` (it only appears inside
the `e -> Bool` predicate). When `retryOn (\_ -> False) …` is lowered, the
predicate lambda's parameter type is that phantom `e`. The Go codegen renders it
as a generic type-param name:
```go
// inside taskRetrySuite() — a NON-generic function
policy := Sky_Core_Task_retryOn(func(_ T1) bool { return false }, Sky_Core_Task_linearBackoff(5, 1))
```
`T1` is only ever a generic parameter of *other* functions (`Sky_Core_List_map_[T1 any, …]`);
here it is unbound, so `go build` rejects it. The lambda-param renderer must fall
back to `any` (interface{}) when the type var is not a generic parameter in the
enclosing scope — exactly what `eraseTypeParams` already does for dropped call-arg
instances elsewhere in the Go codegen.

**Proposed fix.** In the Go closure/lambda parameter-type emission, render a type
variable that is not a bound generic parameter of the enclosing function as `any`
instead of the bare `T<n>`. (Pinpointed site in `src/Sky/Generate/Go/` lambda
emission; the same unbound-tyvar→`any` rule already exists for call args.)

**Test plan.** `00-standard-libs` Go-builds + runs green; add a focused cabal spec
(`retryOn (\_ -> False) policy` lowers the predicate as `func(_ any) bool`); full
`cabal test` + example sweep stay green.

**Cross-backend note.** The Rust backend renders this same predicate param as a
generic `T0` that *is* bound (or `any`), so it never hit this; the bug is
Go-codegen-specific.

---

## PR 2 — `feat(codegen): run-once semantics for top-level effectful CAFs`

**Severity:** performance / correctness-of-intent. Surfaced as the ex27
throughput regression.

**Symptom.** A top-level value binding whose body runs an effect re-runs that
effect on **every reference**:
```elm
dbConn = case Task.run (Db.connect ()) of Ok c -> c | Err e -> …
initSchema = let _ = Task.run (Db.execRaw dbConn "CREATE TABLE IF NOT EXISTS …") in ()

init req = let _ = initSchema in ( … )   -- runs CREATE TABLE on EVERY session init
```
For a Sky.Live app, `init` runs per cookie-less request, so `CREATE TABLE IF NOT
EXISTS` (+ a `Db.connect`) executes on **every request**.

**Evidence (Rust backend, measured).** ex27-multi-session-chat cookie-less
throughput was **900 req/s (0.71× Go)** — the per-request DDL dominated. Lowering
the CAF to run-once (a function-local `OnceLock`) raised it to **5714 req/s (5.0×
Go)**. Both backends re-run the CAF per reference; Go's cost is merely lower
(lazy `sql.Open`).

**Root cause.** Top-level non-function value bindings (CAFs) lower to per-call
functions on both backends (`func dbConn()`, `func initSchema()`), re-evaluated at
each reference, instead of being evaluated once. The intuitive Elm/Haskell-family
reading of a top-level `dbConn = …` is "the connection" — a single value.

**Proposed fix.** Memoise top-level (non-function) value bindings to run-once,
the conventional CAF semantics. The Rust backend already ships this, gated to
*Task-executing* nullary CAFs via `OnceLock` (fork commit `61d5fa11`,
`maybeMemoiseNullary`). Propose Go adopt the same — a package-level `sync.Once`
(or lazy `var`) per top-level value binding.

**Design decision to confirm.** Run-once is a behavior change for *genuinely*
effectful CAFs (run once vs per-reference). For the idempotent ops it targets
(connect, `CREATE TABLE IF NOT EXISTS`) it is observably equivalent and clearly
the intent. Open question for the maintainer: gate to Task-executing CAFs only
(the conservative Rust choice), or apply to all top-level value bindings? And
should the two backends stay in lockstep (so parity holds), or is the Rust
run-once + Go per-reference divergence acceptable in the interim?

**Test plan.** ex27 throughput (both backends); a spec asserting a top-level
`x = Task.run effect` referenced twice runs the effect once; verify no example
relies on per-reference re-execution of a top-level CAF; full sweep green.

---

### Status

Proposals only. Awaiting maintainer (Arthur) approval before implementing /
opening the PRs upstream. Neither is committed or pushed.
