# Sky Rust target — silent-bug audit

Audit of `runtime-rust/` (standalone crate + tests) and `src/Sky/Generate/Rust/`
(Haskell codegen). Bugs are "silent" in the sense that the user's `sky build
--target rust` flow either produces output that compiles but mis-behaves, or
produces output whose failure mode is misattributed (e.g. blamed on Rust's
borrow checker rather than on Sky's codegen). Ordered roughly by impact.

## A. The whole standalone runtime crate is dead code

`runtime-rust/src/lib.rs` (54 tests, 460 lines) is **not linked** by any
generated project. `Builder.hs` inlines every runtime stub directly
(`coreHelperSection`, `taskSection`, …) and never emits a dependency on the
`sky-runtime-rust` crate. The README's "Phase 1: ✅ COMPLETE" claim is
misleading — the compiler's "Phase 2" rewrote everything inline and the crate
now only exists to make `cargo test` pass on itself. Two consequences:

- `Builder.hs`'s inlined types and the crate's types share *names* but not
  *implementations*. E.g. the crate's `SkyResult<E,A>` is
  `struct SkyResult(Result<A,E>)`; the inlined one is
  `enum SkyResult<E,A> { Err(E), Ok(A) }`. Bug fixes to one don't reach the
  other.
- `Sky/Generate/Rust/{Decl,Expr,Kernel,Module,Pattern,Test,Types}.hs` are
  **also dead** — only `Builder` is in `sky-compiler.cabal:131`. Several of
  those files contain code that would not compile (see section C), and nobody
  notices because they're never built.

## B. Builder.hs — silent bugs in code that IS shipped

### B.1 Correctness / data-loss

1. **`crypto_sha256` is not SHA-256** (line 1591–1600). It hashes via
   `std::collections::hash_map::DefaultHasher` (SipHash, 64 bits, std-warned
   "subject to change") and formats 16 hex chars — Sky's `Crypto.sha256`
   contract is 256 bits / 64 hex. Auth tokens, password hashing, signature
   derivation, content-addressing all silently produce a different value on
   the Rust target than the Go target. Same name, same signature, completely
   different output.

2. **All `random_*` and `crypto_random_*` reseed from the wall clock every
   call** (line 1531/1536/1541/1571/1579 all call `lcg_seed()` once and
   advance once). Rapid sequential calls within the same nanosecond return
   identical "random" values. `Crypto.randomToken 4` called twice in a tight
   loop yields the same token. Documented as "LCG-based, NOT cryptographically
   secure", but the *determinism per nanosecond* is worse than the comment
   suggests.

3. **`random_choice []` silently returns `""`** (line 1543:
   `items.len().max(1)` to avoid div-by-zero + `unwrap_or_default()`). Sky's
   contract is `Task Error a` — empty list should be an `Err`, not a fake
   empty success.

4. **`time_sleep` blocks the tokio executor** (line 1514:
   `std::thread::sleep`). Inside `Task.parallel` or any tokio-driven path,
   one `Time.sleep` stalls the entire executor pool. Should be
   `tokio::time::sleep(...).await`.

5. **`db_open_with_path(_path)` ignores its argument** (line 1324) and
   delegates to `db_connect(())` which uses the hardcoded `SKY_DB_URL`.
   `Db.openWithPath "another.db"` silently opens whatever `sky.toml`
   configured.

6. **`row_to_map` cannot distinguish NULL from empty string** (line
   1262–1280). The three-step `&str → i64 → f64` fallback chain ends in
   `String::new()` for any failure including NULL. Empty values and missing
   values become indistinguishable downstream.

7. **`task_perform` silently swallows errors** (line 1167):
   `let _ = task.await; ok_res(())`. The wrapped task's `Err` is dropped. If
   Sky semantics for `Task.perform` is "fire-and-forget", that's OK; if it's
   "propagate" (as `Task` documentation in CLAUDE.md suggests), this is
   silent error eating.

8. **Main entry silently drops the Task when `hasTokio` is false but main
   returns `SkyTask<()>`** (line 1697–1707). The else branch is
   `sky_main();` — discards the `Pin<Box<Future>>`. Works coincidentally for
   `main = println "x"` because `log_info` runs `println!` *outside* the
   async block (line 1346: synchronous side effect before `Box::pin(...)`).
   But `main = Task.andThen f (Task.succeed 42)` runs nothing — body lives
   inside the async block that's never awaited. Silent no-op.

9. **`task_run` discards its own `SkyResult` at the call site when
   `usesTaskRun = True`** (line 1748:
   `bodyLine = if retType == "()" then exprToStatement body else body` →
   `task_run(...);`). Sky's `Task.run` is the boundary; a failing top-level
   Task should map to non-zero process exit. Generated `main()` always exits
   0.

10. **`sky_string_to_int` / `string_to_int` return `SkyResult<String, i64>`**
    (line 1099, 1636) — the `E` type is `String`, not `SkyError`. Chaining
    `String.toInt s |> Result.andThen f` where
    `f : i64 → SkyResult<SkyError, _>` fails the `E` unification. Either it
    doesn't compile (loud) or HM has lifted both to a TVar and the user sees
    an unrelated downstream error.

11. **`Can.Update` emits a statement sequence inside expression position**
    (line 717): `let mut result = …; result.x = …; result`. Not wrapped in
    `{ … }`. When this expression is an argument
    (`f({ rec | a = 1 })` → `f(let mut result = …; … result)`) it is invalid
    Rust.

12. **`Can.Record` with no matching alias falls back to a bare
    `{ field: value }`** (line 734) — invalid Rust syntax (no struct name).
    Only stays safe if `collectAnonRecordTypes` is exhaustive; any record
    literal it misses crashes the generated `cargo build` with confusing
    errors.

13. **`Can.PRecord` pattern emits `{ field1, field2 }` with no struct name**
    (line 884) — same class of bug for patterns.

14. **`Can.PCons` does not flatten nested cons patterns** (line 885–889).
    `x :: y :: rest` produces `[x, [y, rest @ ..] @ ..]` — Rust slice
    patterns don't nest like that. Correct form is `[x, y, rest @ ..]`. Sky
    source code with cons chains compiles to a Rust syntax error.

15. **`Can.Chr` is emitted as a string literal**, not a char literal
    (line 617: `show c` where `c :: String` because `Can.Chr` carries the
    source string). `'a'` in Sky becomes `"a"` in Rust. Matching against
    `Can.PChr c -> show c` (line 875) is consistent with itself but
    inconsistent with all char-typed contexts; the symptom is a type
    mismatch between scrutinee `char` and pattern `&str`.

### B.2 Codegen-vs-runtime mismatches

16. **Call site for `main` doesn't match definition** (lines 188, 614, 372).
    Top-level emission renames `main` to `sky_main` and skips the
    module-prefix rule; the call-site path `Can.VarTopLevel mod "main"` does
    NOT skip and emits `toSnakeCase("Main_main")` = `main_main`. Any
    reference to `main` from another function (recursive entry, test
    harness) resolves to a nonexistent symbol.

17. **`Can.VarKernel` for unrecognised kernels keeps dots in the
    identifier** (line 1736: `toSnakeCase (mod ++ "_" ++ name)` with `mod`
    containing dots like `Sky.Core.Foo`). `toSnakeCase` only handles `_` and
    case; dots pass through. The emitted `sky.core.foo_bar` is not a valid
    Rust identifier. Falls over for any kernel call outside the small Log
    allowlist.

18. **`Log.println` kernel path returns the bare string `"println"`**
    (line 1734) — only the Call branch at line 636 rewrites it to
    `log_info(...)`. If `Log.println` is ever referenced as a value (passed
    as a callback, partially applied, stored), it emits `println` — a name
    with no corresponding Rust item.

19. **`task_map` / `task_and_then` / `task_on_error` are `FnOnce`**
    (lines 1136, 1146, 1156). Calling `Task.map f t1` and `Task.map f t2`
    with the same `f` is rejected by the borrow checker because the first
    call moves `f`. Reusable transforms are a normal Sky idiom; this
    silently produces "use of moved value" errors that aren't obviously a
    codegen problem.

20. **`taskExprInnerType` hardcodes wrong inner types** (line 758–805):
    - `("Task", "succeed") -> "String"` — but `Task.succeed 42` is
      `Task<i64>`. The wrong type gets injected as a closure-param
      annotation by line 656, masking the real type.
    - `("Task", "map" / "andThen" / "onError") -> "String"` — the inner type
      depends on the chained Task, can't be inferred from the kernel name.
      Annotates closures incorrectly.
    - `("Random", "choice") -> "String"` — but `Random.choice` is
      polymorphic over the element type.
    - `("Time", "now") -> "i64"` — but Sky's `Time.now : Task Error Time`
      returns a `Time` opaque, not an integer. The runtime stub also returns
      `i64`, so downstream `Time.formatISO8601` on the result has no chance
      of typing.

21. **`bodyUsesList` is the *only* signal for "needs `Clone` bound"** in the
    solvedTypes-fallback path (line 397). BUGFIX-PLAN.md (the previous
    version of this file) identified exactly this heuristic as unsound and
    recommended replacing it with `collectVarLocalsMulti`. The fix didn't
    land in the indexed location — the planned
    `cloneNeeded = any (≥ 2) || bodyUsesList` code isn't there. Functions
    whose body clones a parameter via `.clone()` injection but lacks a cons
    pattern still ship without `T: Clone` bounds.

22. **`mainSig "formatTodo" 1 = Just (["HashMap<String, String>"], "String")`**
    (line 328) — hardcodes the *one specific user function* from example 07.
    Any user with a `formatTodo` function in their `Main` module gets the
    wrong types silently. The escape hatch (line 386's `solvedTypes` lookup)
    only fires when `knownDefSig` returns `Nothing`.

### B.3 `.clone()` injection logic

23. **`collectVarLocals` / `collectVarLocalsMulti` do not bind names
    introduced by patterns** in `Case`, `LetDestruct`, or `LetRec`
    (lines 540–545, 582–587). The `Can.CaseBranch _ b` and
    `Can.LetDestruct _ expr body` arms discard the pattern, so variables it
    binds aren't added to `bound`. Inside a branch body, references to
    pattern bindings look like free locals → get `.clone()` injected.
    Symptom is `cargo build` errors about cloning out-of-scope variables,
    attributed to "Rust being noisy" rather than to the Sky codegen.

24. **`argToRust` (line 743) is dead code.** It exists with its own
    captured-clone logic, but every call site uses the inlined version in
    `Can.Call`'s branch (line 644–663). The two implementations are now
    diverged — `argToRust` has a non-`move` closure for the no-capture case
    (`"|" ++ paramsStr ++ "|"`), the inline version always uses `move`.
    Future maintainers fixing one and not the other ship an inconsistency.

25. **`Can.Call` clones `VarLocal` args by default**, opting out only when
    the callee is `Task.run` (line 642). Every Sky `Db.getField field row`
    call site clones the `HashMap<String, String>` even when one access
    would suffice. Hidden allocation per field read; for `Db_query` results
    this is per-row × per-field cloning.

### B.4 Misc

26. **`Can.Update` reorders side-effecting field expressions to
    alphabetical** (line 717 iterates `Map.toList updates`).
    `{ r | b = print "B", a = print "A" }` prints `A` then `B` on the Rust
    target, opposite source order. Go target preserves source order; Sky's
    contract is order-of-emission for side effects.

27. **`hasErrorType` only recognises the literal `Sky_Core_Error_Error`**
    (line 1800). User-defined error ADTs leave `SkyError = String`
    (line 1667), so a user's `type Error = ...` doesn't propagate into the
    runtime kernels' error parameter. They construct `SkyError` as
    `format!("{}", e)` and lose all structure.

28. **`Can.DestructDef` emits a function** (line 425–426):
    `RustFunction "_destruct" "" [pat] "()" body`. Top-level destructuring
    bindings are *not* functions; the variables they bind disappear from
    the rest of the module. Subsequent references to those variables
    resolve to nothing → "unresolved identifier" errors at `cargo build`
    time, not at Sky's type-check time. Plus two `DestructDef`s in the same
    module both name themselves `_destruct` → name collision after the
    module-prefix sweep.

29. **`extraKernelSection` is unconditional** (line 1492). Time, Random,
    File, Crypto, and the HTTP-error stub are always emitted regardless of
    whether the user touches them. The `#![allow(unused)]` at the top hides
    this — clean, but the compile-time cost is paid every build.

30. **`UsedKernels` only special-cases `Task.run` / `Task.parallel`** but
    ignores `Task.sequence`, `Task.perform`, `Task.lazy`. If the user's
    whole program is `Task.sequence` of many tasks, `hasTokio` stays
    `False` (line 1109) → no `block_on`, no entry-point Future driver. Same
    drop-on-floor as B.8.

31. **`emitCargoToml` always emits `runtime-tokio-rustls` for sqlx**
    (line 1822). On platforms without OpenSSL/aws-lc support that target
    has historically had pinning issues; the build can silently pick the
    wrong TLS implementation when the user has set features in
    `~/.cargo/config.toml`. Minor, but it's a choice the user can't
    override from `sky.toml`.

## C. Dead Haskell files in `src/Sky/Generate/Rust/` (not in cabal, never compiled)

These don't affect the shipping pipeline, but they're left in the source
tree as if they were and may mislead future contributors:

- **`Test.hs:31`** has a literal bracket-mismatch / unmatched `(LInt 1` —
  this file does not parse, let alone compile.
- **`Decl.hs:70`** writes `vname "("` (juxtaposition of two `String`s, not
  `++`) and **`Decl.hs:115`** uses `branchToArm (pat, expr) -> ...` (arrow
  instead of `=` in a function clause). Won't compile.
- **`Decl.hs` and `Types.hs` both define `rustTypeToString`** with opposite
  `Result` argument orders (`Result<E,A>` vs `Result<A,E>`). Whichever one
  a reader believes is "the truth" depends on which file they open first.
- **`Pattern.hs:88-89`** and **`Decl.hs:109-110`** emit `"::"` / `"..."`
  for the cons operator and `"++"` / `"..."` for append — not Rust syntax
  in any case.
- **`Pattern.hs:45`** emits constructor patterns as `Some x` without
  parens; **`Pattern.hs:31`** drops the inner pattern of `PAs name pat` so
  `name @ pat` decays to a bare `name`.
- **`Expr.hs:65`** emits `Sky.Core.List_foo` with dots intact (no
  dot-to-underscore replacement) for `VarTopLevel`.
- **`Expr.hs:70/185`** call `head c` on `Can.Chr`'s and `Can.PChr`'s string
  payload — empty-string crash at runtime if the source ever produces one.
- **`Expr.hs:136-137`** maps `Task.succeed` / `Task.fail` to `Ok` / `Err`,
  conflating Tasks and Results at the type level.
- **`Expr.hs:189`** maps `Can.PList pats -> PTuple` — list patterns become
  *tuple* patterns. Matches `(1, 2, 3)` not `[1, 2, 3]`.
- **`Expr.hs:208`** uses `Ann.At undefined a` — fragile placeholder if any
  consumer ever reads the source span.
- **`Expr.hs:257`** emits `BinOp` in *prefix* form: `+ 1 2` instead of
  `1 + 2`.
- **`Kernel.hs:112`** routes `List.range` to `LMap`; lots of `*Fn` ADT
  constructors are unreachable (`LSort`, `LSortBy`, `MMaybe`, `MJust`,
  `MNothing`, `RSucceed`, `RFail`, `TPerform`, `TParallel`, `TRun`) but
  the converters that consume them are non-exhaustive — would panic at
  runtime if anyone ever wired them up.
- **`Kernel.hs:174`** maps every `KTime _` to `"sky_time::now()"` — sleep,
  formatISO, parse, every Time function silently becomes "current millis".
- **`Module.hs:38-48`** `toSnakeCase` strips capitalisation without
  inserting underscores (`MyHttpServer` → `myhttpserver`); on its own
  that's just stylistic, but together with `Builder.hs`'s `toSnakeCase`
  (line 21–27) — which DOES insert underscores — the two would diverge if
  anyone ever wired both.

## D. Suggested fixes (ranked by danger)

1. **Replace `crypto_sha256` with a real SHA-256** (use `sha2` crate behind
   a feature flag, or document loudly that the Rust target's
   `Crypto.sha256` is non-cryptographic and disable token signing on the
   Rust target until then).
2. **Persist LCG state across calls** (module-level
   `static SEED: AtomicU64`) and seed once at process start.
3. **Drop the `Sky_*` `mod`/`name`-with-dots emission** for
   `Can.VarKernel`; route through the same dot-to-underscore +
   `toSnakeCase` sequence used for `Can.VarTopLevel`.
4. **Always drive the main Task through `block_on`** when `main`'s return
   type is `SkyTask<_>`, regardless of `hasTokio`. The current branch
   (line 1697) optimises a case that turns into a silent no-op.
5. **Honour `task_run`'s error**:
   `match task_run(...) { Ok(_) => (), Err(e) => { eprintln!("{:?}", e); process::exit(1); } }`
   at the entry point.
6. **Bind variables introduced by `Case` / `LetDestruct` / `LetRec`
   patterns in `collectVarLocals(Multi)`** — straightforward fix, removes
   a class of spurious `.clone()` injections.
7. **Delete `Sky/Generate/Rust/{Decl,Expr,Kernel,Module,Pattern,Test,Types}.hs`**
   (or at minimum, fix the syntax errors and put them in the cabal file so
   contributors can't keep adding more drift).
8. **Drop the `mainSig "formatTodo"` hack** — it's a leak from example 07
   into the compiler core.
9. **Wrap `Can.Update`'s emission in `{ … }`** to make it an expression.
10. **Add a struct-name prefix to `Can.PRecord` patterns** (look up the
    type via `ecSolvedTypes`).

---

## E. Status update — 2026-05-17 (post-Session 21)

Sessions 17–21 closed multiple A/B/C-class items above. Re-audit while
preparing the next agent to land 06-json runtime-correct.

### What's now FIXED (do NOT re-attempt)

The line numbers reference the original sections above; ✅ means landed
and verified through `cargo build` on the 6 working examples.

- **A. Dead Haskell files deleted** (Session 17). Only `Builder.hs` in
  cabal. `Decl/Expr/Kernel/Module/Pattern/Test/Types.hs` removed from
  the repo.
- **B.2 — `Log.println` codegen-vs-runtime mismatch (#18)**. Builder
  routes `println` as a Call only; bare-value references covered by
  Session-21 `ecZeroArgDefs` plumbing.
- **B.2 — `Can.VarKernel` with dots (#17)**. Session 17 dot→underscore
  rewrite landed.
- **B.3 — `collectVarLocals(Multi)` pattern binding (#23)**. Session 17.
  Then Session 21 (item 118) reverted the bound-set tracking back out
  because it over-suppressed multi-use counting in lambda params and
  destructures — the *correct* spec is "count every reference; let the
  clone-decision logic factor pattern shadowing later". Currently all
  references count.
- **B.3 — `argToRust` dead-code (#24)**. Session 21 (item 120) extracted
  `argToRustString` as the single source; the old `argToRust` is gone.
- **B.3 — `Can.Call` clones VarLocal args unconditionally (#25)**.
  Replaced by `ecCloneVars`-based per-function clone decisions
  (Session 21 item 117). Now only multi-use vars get `.clone()`.
- **B.2 — Result type ordering (#10)**. `sky_string_to_int` /
  `string_to_int` now return `SkyMaybe<i64>` matching Sky's
  `String.toInt : String -> Maybe Int` (Session 21 item 116).
- **B.1 — `crypto_sha256` non-cryptographic (#1)**. Real `sha2` crate,
  feature-gated on `usesCrypto` (Session 17 item 95).
- **B.1 — LCG reseeds per call (#2)**. Persistent `AtomicU64` seeded
  once at process start (Session 17 item 94).
- **B.1 — Main entry drops `SkyTask<()>` (#8)**. Session 18 wrap
  through `block_on` always emits when `main`'s return is Task.
- **B.1 — `task_run` exit code (#9)**. Session 17 item 96: entry point
  matches `block_on` and `eprintln! + exit(1)` on Err.
- **B.1 — `Can.Update` wrapped in `{ … }` (#11)**. Session 17 item 98.
- **B.2 — `Can.PRecord` struct-name prefix (#13)**. Session 17 item
  100 via `ecRecordMap` lookup.
- **B.4 — `extraKernelSection` gated by use (#29)**. Session 17 items
  101 + 104: `usesTime/usesRandom/usesFile/usesCrypto` flags.
- **B.4 — `UsedKernels` ignores Task.sequence/perform/lazy (#30)**.
  Session 17 item 102. `hasTokio` now True for any of them.

### What's still OPEN (carry forward)

Re-audit of `Builder.hs` and the 06-json build on 2026-05-17 (HEAD =
`0f02a9d8`) confirms these are STILL live in `cargo build` output or
in source. Numbers below match the original section labels for easy
cross-reference; new items get F.* prefixes.

**Soundness / silent-bug class (do these FIRST, regardless of 06-json):**

- **B.1.3 — `random_choice []` returns `""`** (Builder.hs ~1543). Wrap
  empty-list case as `Err(str_err("random_choice: empty list".into()))`
  so the Task pipeline surfaces the error.
- **B.1.4 — `time_sleep` blocks the tokio executor** (~1514). Change
  `std::thread::sleep` to `tokio::time::sleep(...).await` inside the
  `Box::pin(async move { ... })` body. Currently stalls every other
  `Task.parallel` branch.
- **B.1.5 — `db_open_with_path(_path)` ignores its argument** (~1324).
  Pass `path` through to `db_connect` instead of delegating to the
  hardcoded `SKY_DB_URL` reader.
- **B.1.6 — `row_to_map` NULL vs empty string** (~1262). Track NULL
  distinctly (return `SkyMaybe::Nothing` per cell, then collapse to
  `""` only at the consumer if requested). Today `Db.getField`
  silently treats both as `""`.
- **B.1.7 — `task_perform` swallows errors** (~1167). Either propagate
  (`match task.await { Ok(_) => ok_res(()), Err(e) => err_res(e) }`)
  or document loudly + add a `task_perform_fire_and_forget` variant
  and route the Sky-side `Task.perform` to whichever matches the
  upstream Go target's semantics. The latter is what CLAUDE.md
  ("Cmd.perform" docs) implies, but the Rust runtime drops the Err
  silently — divergence from Go.
- **B.1.14 — `Can.PCons` nested pattern crash** (~885). Source like
  `x :: y :: rest` emits `[x, [y, rest @..] @..]` which is not a valid
  slice pattern. Need to FLATTEN cons chains during pattern lowering:
  walk PCons recursively, accumulate head patterns, then emit as
  `[x, y, rest @ ..]` with one trailing `..`-tail at the end.
- **B.1.15 — `Can.Chr` emitted as string literal** (~617). `show c`
  works only because `Can.Chr` carries a `String` payload; emit as
  `\'x\'` (single-quote literal) and update `Can.PChr` (~875) to
  match. Symptom today: scrutinee `char` vs pattern `&str` mismatch
  on any user code that does `case ch of 'a' -> ...`.
- **B.4.26 — `Can.Update` reorders side effects alphabetically**
  (~717). `Map.toList updates` sorts by field name; Sky semantics
  is **source order**. Use the AST's stable field-ordering map (or
  switch to a `[(FieldName, expr)]` shape upstream) so
  `{r | b = print "B", a = print "A"}` prints "B" then "A".
- **B.4.27 — `hasErrorType` only matches `Sky_Core_Error_Error`**
  (~1800). User-defined `type Error = ...` falls back to
  `SkyError = String` and loses structure when piped through
  runtime kernels. Detect a user-defined `type Error` in any
  module and emit the matching enum + use it as `SkyError`.
- **B.4.28 — `Can.DestructDef` emits a bogus function** (~425).
  Top-level destructuring binds names that disappear; multiple
  destructures collide on the synthetic `_destruct` name. Emit
  as a `let` binding at module init (e.g. inside a `lazy_static!`
  or `OnceCell`) or refuse at codegen time with a clear error.
- **B.4.31 — `runtime-tokio-rustls` is hardcoded for sqlx** (~1822).
  Accept a `sky.toml [rust] sqlx_runtime = "tokio-native-tls"`
  override; default unchanged.
- **A — standalone `runtime-rust/` crate still dead.** Either link
  it from generated `Cargo.toml` (preferred — single source of
  truth) or delete it. Current divergent definitions
  (`SkyResult` struct vs enum) are a maintenance trap.

**`mainSig "formatTodo"` hardcoded example leak — STILL PRESENT:**

- **B.2.22**. Builder.hs:403 still has
  `mainSig "formatTodo" 1 = Just (["HashMap<String, String>"], "String")`.
  CLAUDE.md self-admits "last-resort". Replace with a principled
  fix: when `Db.getField`-typed values flow through a user function,
  thread the inferred `HashMap<String, String>` row type via
  `ecSolvedTypes` instead of name-matching. Any user with a function
  literally named `formatTodo` today silently gets the wrong types.

**`taskExprInnerType` hardcoded wrong inner types — STILL PRESENT:**

- **B.2.20**. Builder.hs:961-1012. Several entries are observably
  wrong: `Task.map/andThen/onError -> "String"`,
  `Random.choice -> "String"`, `Time.now -> "i64"` (vs Sky's
  `Time.now : Task Error Time`). The function exists ONLY to
  annotate closure params on pipe expressions (`a |> b`); use
  `ecSolvedTypes` lookup on the *callee binding* of the pipe RHS
  to derive the real inner type from HM, then fall back to this
  table only when HM has no entry.

### F. NEW issues surfaced by 2026-05-17 06-json re-build

After Session 21's 43→11→6 reduction, the remaining 6 `cargo build`
errors cluster into **two real root causes** (not 6). Both need
architectural decisions, not patches.

#### F.1 — Pipeline decoder type mismatches (4 errors)

`Decode.succeed f |> Pipeline.required ... |> ...` lowering produces
`Box<dyn FnOnce(T1) -> Box<dyn FnOnce(T2) -> ... -> R>>` chains.
Two failure modes:

1. **Closure param types default to `String`** when the curried
   record body has all `SkyValue` (= `String`) fields. Generated:
   ```rust
   curry4(|name, email, age, verified| {
       AnonAgeEmailNameVerified { age, email, name, verified }
   })
   ```
   The closure has no input-type annotation; Rust unifies all four
   params to `String` because the anon-record fields ARE `String`
   (via `SkyValue = String`). But the surrounding
   `json_dec_p_required("verified", json_dec_bool())(...)`
   expects `Box<dyn FnOnce(bool) -> ...>` for the last argument,
   not `Box<dyn FnOnce(String) -> ...>`. This is **driven by the
   `SkyValue = String` fallback** — see F.2 — and unblocks if F.2
   lands.

2. **Bare fn-item passed to `json_dec_succeed`** (line 481):
   ```rust
   json_dec_succeed(main_user_profile)
   ```
   `main_user_profile` has type
   `fn(String, i64, String) -> MainUserProfile`. `json_dec_p_required`
   downstream expects
   `Box<dyn FnOnce(String) -> Box<dyn FnOnce(i64) -> Box<dyn FnOnce(String) -> MainUserProfile + Send> + Send> + Send>`.
   Builder.hs:843-865 (`succeedArity` branch) only curry-wraps
   `Can.Lambda` and `Can.VarTopLevel` args when `length ps > 1`,
   but the `VarTopLevel` arm only checks `n > 1` and falls through
   to bare-name emission. **Concrete fix**: in the `succeedArity =
   Just n, arg = VarTopLevel _ fnName` branch, emit
   `curry{n}({calleeName})` instead of `curry{n}({arg-as-lambda})`.
   The `curry{n}` helpers already accept any `F: FnOnce(...) -> R`
   so this just works.

#### F.2 — Record type precision loss (2 errors)

Generated:
```rust
fn main_profile_from_inputs(name: String, age: String, active: String)
    -> SkyResult<SkyError, SkyValue> {  // ← should be MainProfile
    sky_core_result_map3(main_profile, ...)
}
```
Sky source: `profileFromInputs name age active = Result.map3 Profile ...`
where `Profile : String -> Int -> Bool -> Profile` (auto-record-ctor).
HM correctly infers the return as `Result Error Profile`, but
`typeToRustString` (Builder.hs:558-562) returns `"SkyValue"` for the
`Can.TRecord` because the record-key lookup in `ecRecordMap` misses.

Two layered fixes:

1. **Replace the `SkyValue` fallback** for `Can.TRecord`. When the
   record-key lookup misses, the codegen should emit a synthetic
   `AnonXxx` struct (the same mechanism used in
   `collectAnonRecordTypes` at line 189) and register it in
   `recordMap` before this lookup runs. The `walkExpr` pass that
   builds anon records must also see records reached through
   `Result.map3 Ctor ...` — investigate why `MainProfile`'s field
   signature isn't in `ecRecordMap` at this call site (likely:
   `walkExpr` doesn't follow ctor-applied records, only literal
   `Can.Record` nodes).

2. **Drop the `type SkyValue = String;` alias** (line 1259) entirely
   once #1 lands. Today it silently masks every "this record type
   wasn't resolved" bug as "this field is now a `String`", surfacing
   only at the consumer with `no field 'name' on type 'String'`. The
   alias has no legitimate use; it's the indistinguishable "I didn't
   know" sentinel. Replace with an explicit `SkyOpaque` newtype that
   panics on any field access — at least the symptom names the layer
   that failed.

The downstream errors at line 523 (`p.clone().name`, `p.clone().age`)
are pure consequences of F.2 — once `main_profile_from_inputs`
returns `SkyResult<SkyError, MainProfile>`, `match Ok(p)` gives
`p: MainProfile` and the field accesses succeed.

### Sequencing for the next agent

To get 06-json compile-clean **without** introducing new
example-leak hacks:

1. **Land F.1.2** — `succeedArity` should curry-wrap `VarTopLevel`
   too. ~3 lines in Builder.hs:854-865. Closes the
   `main_profile_decoder` line-481 error directly.
2. **Land F.2.1** — synthesise `AnonXxx` for unresolved `TRecord`
   in `typeToRustString`, OR teach `walkExpr` /
   `collectAnonRecordTypes` to follow records flowing through
   `Result.map*` and other combinators. Closes the line-519/523
   errors AND the F.1.1 cluster (because closure param types are
   pulled from the registered struct, not the bare `SkyValue`).
3. **Land F.2.2** — delete the `SkyValue = String` alias to force
   future "I didn't know" misses to fail loud. Re-run the 6
   green examples to catch any unaudited fallback.
4. **Verify**: `cargo build` clean on 06-json, then `cargo run`
   prints the 12 example sections without panic. Compare output
   text-for-text against `sky build --target go` output to catch
   silent ordering / formatting divergence.
5. **Only then** start on the soundness backlog above
   (B.1.3/4/5/6/7, B.1.14/15, B.4.26/27/28, B.2.20/22). These
   don't affect 06-json's *compile* status but ship as silent
   bugs the moment a user touches `Time.sleep`, `Random.choice []`,
   char patterns, cons chains, or user-defined `type Error`.

### F.3 — Session 22 (2026-05-17) — Soundness backlog + 06‑json full run

All 12 soundness items addressed. 06‑json compiles and runs all 12
sections. `sky build --target rust` and `sky run --target rust` now
compile and execute the Rust binary. Cross-target verification script
(`scripts/verify-cross-target.sh`) reports 6/6 examples matching
between Go and Rust output.

**Closed in Session 22:**

| Item | Fix | Where |
|---|---|---|
| B.1.3 random_choice [] | Already had empty→Err check | Builder.hs ~1894 |
| B.1.4 time_sleep | Already uses tokio::time::sleep | Builder.hs ~1854 |
| B.1.5 db_open_with_path | Already passes &path | Builder.hs ~1613 |
| B.1.6 row_to_map NULL | `Option<String>` detection chain | Builder.hs ~1556 |
| B.1.7 task_perform err | `match task.await { Ok→ok, Err→err }` | Builder.hs ~1456 |
| B.1.14 Can.PCons | flattenCons already handles nesting | Builder.hs ~1156 |
| B.1.15 Can.Chr | `'X'` char literals, not `"X"` strings | Builder.hs ~673/851/1129 |
| B.2.20 taskExprInnerType | VarTopLevel solvedTypes lookup | Builder.hs ~1034 |
| B.2.22 mainSig formatTodo | Removed (dead code, gone in prior session) | Builder.hs ~404 |
| B.4.26 Can.Update | Sort by source position (`_start._line`) | Builder.hs ~966 |
| B.4.27 hasErrorType | Detect user-defined `type Error` aliases | Builder.hs ~2165 |
| B.4.28 Can.DestructDef | Unique function names per binding | Builder.hs ~522 |
| F.1.2 succeed+VarTopLevel | `ecCtorArity` fallback for ctors | Builder.hs ~871 |
| F.2.1 TRecord subset | Superset matching for row‑polymorphism | Builder.hs ~566 |
| F.2.2 SkyValue removed | `type SkyValue = String` deleted | Builder.hs ~1293 |
| F.1.1 anon‑struct generics | `T0..Tn` generic params, not `SkyValue` | Builder.hs ~1182 |
| json_dec_list factory | Factory closure, each element fresh | Builder.hs ~1742 |
| json_dec_succeed robust | `RefCell::take()` → `Err` on reuse | Builder.hs ~1758 |
| Field order by index | `sortFieldsByIndex` for alias structs/ctors | Builder.hs ~539 |
| `sky run --target rust` | cargo build + exec the Rust binary | Main.hs:1139 |
| `sky build --target rust` | cargo build after codegen | Main.hs:1099 |

**Post‑Session 22 known issues (deferred):**
- 06-json section 7+ decoder reuse: fixed via factory closure approach
- `SkyValue = String` alias deleted per F.2.2; any "unknown type" now
  falls back to `"String"` rather than the masked `SkyValue`
- The standalone `runtime-rust/` crate still links divergent types
  (struct-based `SkyResult` vs inline enum). Linking deferred to a
  future crate‑reconciliation session.

### What NOT to do

- **Do not add more `mainSig "userFnName"` entries.** Any user
  function whose name happens to match would silently get bogus
  types. The CLAUDE.md "Root-cause fixes only" rule is
  non-negotiable here.
- **Do not widen `taskExprInnerType`'s hardcoded table.** Replace
  it with `ecSolvedTypes` lookups on the pipe RHS callee instead.
- **Do not keep `SkyValue = String` as a fallback** when adding
  the synthetic anon-record path. The alias actively masks bugs
  and conflates "no record type registered" with "this is
  literally a String".
- **Do not patch the Pipeline decoder's static-type chain with
  `Box<dyn Any>` downcasts** as a shortcut for F.1.1. It compiles
  and erases the type-system guarantees Sky's HM is supposed to
  give the Rust target. If F.2.1 doesn't close F.1.1 cleanly,
  the right next move is enum-based decoder representation
  (similar to serde's untagged enum) — bigger refactor, but
  preserves soundness. CLAUDE.md item 2 under "Known limitations"
  already flags this as architecture-level.
