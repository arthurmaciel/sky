# Found Errors — Rust backend (for future correction)

Running log of defects discovered while exercising real Sky projects against
the **Rust backend** (`sky build/run --backend rust`). Each entry is a concrete
repro the Go backend accepts but the Rust path does not (or a toolchain wart on
the Rust path). The guiding invariant:

> **The Rust backend must compile every Sky program the Go backend accepts.**
> If well-typed Sky (`sky check` clean) builds on Go but fails on Rust, that is
> a Rust-backend bug, not a user bug.

Status legend: `OPEN` (needs fix) · `WORKED-AROUND` (user-side patch exists,
codegen still wrong) · `FIXED` (closed upstream).

---

## E-001 — `Task` reuse / generic `Task` result fails to compile on Rust

- **Discovered:** 2026-06-27
- **Compiler:** `sky v0.16.29`
- **Backend:** `--backend rust` (Go backend builds the same source cleanly)
- **Severity:** High — a natural, idiomatic Task pattern that is valid on Go
  silently breaks on Rust.
- **Status:** `FIXED` (#96, branch feat/runtime-rust). Both codegen gaps closed
  in `src/Sky/Generate/Rust/Builder/ExprEmitter.hs`; the original generic,
  Task-reusing `withTempDir` now builds + runs on `--backend rust`. Verified via
  `/tmp/e001` (generic) + `/tmp/e001b` (non-generic isolation of gap 1).
- **Found in:** `sky-playground` — `src/Runner.sky`, `withTempDir`.

### Fix (#96)

1. **Multi-use SkyTask → re-thunk.** A `let`-bound `SkyTask`
   (`Pin<Box<dyn Future>>`, move-only) used ≥2 times where not every use is a
   discard now lowers to a `Fn() -> SkyTask` closure that REBUILDS the future on
   demand; every read site calls it (`cleanup()`). This matches Go's
   re-runnable-thunk Task semantics (each reference re-runs the effect → a value
   used in two mutually-exclusive branches runs at most once). New `ecThunkVars`
   set + `varLocalRead` helper; new `Can.Let` arm placed after the existing
   single-use-move and Arc-all-discard arms (guardian C1: gated on
   `not (allUsesDiscarded …)` to stay disjoint).
2. **Generic closure param annotation.** A closure param whose solver region
   type is a bare type-variable resolving to the enclosing fn's sole Rust generic
   is now annotated (`move |result: A|`) — closing the E0282. Sound because Sky
   does not generalise local `let` bindings, so a one-generic fn body has exactly
   one logical type variable. The generic already carries
   `Clone+PartialEq+Debug+Send+Sync+'static` at the fn header, so `result.clone()`
   was already valid; only the annotation was missing.

### Symptom

`sky build --backend rust` aborts in the generated `src/runner.rs` with up to
three errors:

```
error[E0599]: the method `clone` exists for struct
  `Pin<Box<dyn Future<Output = SkyResult<SkyCoreErrorError, String>> + Send>>`,
  but its trait bounds were not satisfied
   --> src/runner.rs:70:59
    |   let cleanup = cleanup.clone();
    = note: `Box<dyn Future<...> + Send>: Clone` is not satisfied

error[E0282]: type annotations needed
   --> src/runner.rs:71:43
    |   move |result| { ... let result = result.clone(); ... }
    |         ^^^^^^  type must be known at this point
```

### Minimal repro (well-typed Sky; `sky check` is clean; Go builds it)

```elm
-- Two independent triggers, both in this one function:
--   (a) a single `Task` value is BOUND ONCE and REUSED in two branches, and
--   (b) the function is GENERIC over the action's result type `a`, and that
--       generic result is captured inside a nested cleanup closure.
withTempDir : String -> (String -> Task Error a) -> Task Error a
withTempDir prefix action =
    let
        runWithTempDir token =
            let
                dir = "tmp/" ++ prefix ++ "-" ++ token
                src = dir ++ "/src"
                -- (a) shared Task binding, used twice below
                cleanup =
                    Process.run "rm" [ "-rf", dir ]
                        |> Task.onError (\_ -> Task.succeed "")
            in
                File.mkdirAll src
                    |> Task.andThen (\_ -> action dir)
                    -- (b) generic `result : a` captured inside `\_ -> result`
                    |> Task.andThen (\result -> cleanup |> Task.map (\_ -> result))
                    |> Task.onError (\err -> cleanup |> Task.andThen (\_ -> Task.fail err))
    in
        Crypto.randomToken 4 |> Task.andThen runWithTempDir
```

### Root cause (two distinct codegen gaps)

1. **`Task` is lowered to a one-shot, non-`Clone` future.** On the Go backend a
   `Task` is a re-runnable lazy thunk, so binding it once and referencing it in
   two branches is fine. On Rust a `SkyTask` lowers to
   `Pin<Box<dyn Future + Send>>`, which is **move-only / not `Clone`**. When a
   single Task binding is used in more than one place, codegen emits
   `binding.clone()` — which cannot compile. Codegen must either (i) detect
   multi-use of a Task binding and re-thunk it (emit a fresh future per use,
   e.g. lower the binding to an `impl Fn() -> SkyTask` / closure that rebuilds
   it), or (ii) reject it at lowering with a clear diagnostic instead of
   emitting `.clone()`.

2. **A generic result captured in a nested closure is emitted without a type
   and with `.clone()`.** The `\result -> ... (\_ -> result)` shape, with
   `result : a` (a function type parameter), generates
   `move |result| { let result = result.clone(); ... }` with no annotation,
   producing `E0282`. Codegen should thread the monomorphised concrete type
   into the closure parameter (annotate it) and avoid the spurious `.clone()`
   of a moved value, OR require `a: Clone + 'static` consistently and annotate.

### User-side workaround (what unblocked the project)

- Replace the shared `cleanup` binding with a **function** so each call site
  builds a fresh future:
  ```elm
  removeDir : String -> Task Error String
  removeDir dir =
      Process.run "rm" [ "-rf", dir ] |> Task.onError (\_ -> Task.succeed "")
  ```
  and call `removeDir dir` in each branch.
- **Specialise the generic** away when possible — `withTempDir` was only ever
  used with `Task Error String`, so changing the signature to
  `String -> (String -> Task Error String) -> Task Error String` removed the
  generic the Rust codegen couldn't monomorphise.

Both are workarounds. The backend should accept the original generic, Task-reusing
form unchanged.

### Suggested fix

- Make Task lowering robust to multi-use bindings (re-thunk on each use) — this
  is the higher-value fix; "bind a Task, use it twice" is common and idiomatic.
- Propagate monomorphised types into generated closure parameters; stop emitting
  `.clone()` on move-only future/result values.
- Add a Go≡Rust parity regression test built from the minimal repro above.

---

## E-002 — Bundled console pre-build invokes deprecated `--target rust`

- **Discovered:** 2026-06-27
- **Compiler:** `sky v0.16.29`
- **Severity:** Low — non-fatal; the app builds and runs, console falls back to
  in-process.
- **Status:** `FIXED` (already closed in source by commit `243465ff`,
  `src/Sky/Build/Rust/Console.hs:196` — the console pre-build self-invocation now
  shells out with `--backend rust`, not the deprecated `--target rust`). The
  user's tested `sky` binary predated that commit; a rebuild
  (`cabal build exe:sky` + re-symlink `sky-out/sky`) clears it.
- **Found in:** `sky build/run --backend rust` on `sky-playground`.

### Symptom

During a successful `--backend rust` build, the dev-console pre-build step fails:

```
[sky] pre-building the bundled console for sky dev ...
[sky.console] console pre-build failed; the in-process console will serve.
error: `--target rust` is no longer valid — the codegen backend is now
       `--backend rust`. `--target` selects a cross-compile TRIPLE
       (e.g. --target x86_64-unknown-linux-musl).
```

The app binary itself builds fine (`Build complete: sky-out/rust/target/debug/sky-app`),
boots, and serves (`[sky.live] listening on ...`). Only the **bundled console
pre-build** is affected, and it degrades gracefully to the in-process console.

### Root cause

The console pre-build path inside the `sky` toolchain still shells out with the
**old `--target rust` flag**, which the CLI now rejects in favour of
`--backend rust` (`--target` was repurposed to mean a cross-compile triple).
The internal invocation was not migrated when the flag was renamed.

### Suggested fix

- Update the console pre-build invocation to use `--backend rust` (drop/repoint
  `--target`). Grep the toolchain for residual `--target rust` / `--target go`
  internal invocations and migrate them all.
- Optionally suppress the scary `error:` line when the fallback succeeds, or
  downgrade it to a warning, so it doesn't read as a build failure.
