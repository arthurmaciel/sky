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
