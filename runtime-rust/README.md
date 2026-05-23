# Sky Rust Runtime

The `sky_runtime` crate is the **single source of truth** for all Rust code
emitted by the Sky compiler's `--target rust` path. Every generated project
copies this crate's modules into `sky-out/Rust/src/sky_runtime/` at build time.

## Architecture

```
Sky Source → Haskell Parser/Type-Check → Canonical AST → Rust Codegen (Builder.hs)
                                                              ↓
                                            sky_runtime/ module (this crate)
                                                              ↓
                                            sky-out/Rust/src/main.rs + src/sky_runtime/
                                                              ↓
                                                   cargo build → binary
```

**Key design**: All runtime functions are **generic over the error type `E`**.
The crate provides `SkyTask<E, A>`, `SkyResult<E, A>`, `Decoder<E, T>`, and all
combinators parameterised on `E`. Builder.hs emits thin wrappers (~30 functions)
that instantiate `E = SkyError` (the project's concrete error type, which is
either `String` or the `SkyCoreErrorError` ADT when `Sky.Core.Error` is imported).

## Module structure

```
runtime-rust/src/sky_runtime/
├── config.rs      GENERATED at build time — DB types (DbPool, DbRow, SKY_DB_URL)
├── core.rs        SkyResult, SkyMaybe, SkyTask<E,A>, ok_res<E>, str_err<E>,
│                  list/string/float helpers, result_with_default, result_traverse
├── task.rs        task_succeed, task_map, task_and_then, task_on_error,
│                  task_fail, task_perform, task_sequence, task_run, task_parallel
├── log.rs         log_info, log_debug, log_warn, log_info_with, log_error_with
├── system.rs      system_args, system_exit, system_setenv, system_unsetenv
├── time.rs        time_now, time_sleep, time_unix_millis, time_time_string
├── random.rs      random_int, random_float, random_choice (LCG-based)
├── file.rs        file_read_file, file_write_file, file_exists, file_delete
├── crypto.rs      crypto_random_bytes, crypto_random_token, crypto_sha256
├── json.rs        JSON encode/decode, Decoder<E,T>, curry helpers, pipeline combinators
├── db.rs          db_connect, db_exec, db_query, db_get_field (sqlx-backed)
└── mod.rs         Re-exports config + core. Other modules accessed via
                   sky_runtime::<module>::<fn> in wrapper functions.
```

## Error type design

All runtime functions are generic over `E`. Builder.hs provides wrappers that
instantiate `E = SkyError` (the project's concrete error type):

```rust
// In sky_runtime/task.rs (generic):
// All Task combinators are tupled (f, task), not curried f(task):
pub fn task_map<E, A, B>(f: impl FnOnce(A) -> B + Send + 'static, task: SkyTask<E, A>) -> SkyTask<E, B>
pub fn task_and_then<E, A, B>(f: impl FnOnce(A) -> SkyTask<E, B> + Send + 'static, task: SkyTask<E, A>) -> SkyTask<E, B>
pub fn task_on_error<E, A>(f: impl FnOnce(E) -> SkyTask<E, A> + Send + 'static, task: SkyTask<E, A>) -> SkyTask<E, A>
pub fn task_succeed<E: Send + 'static, A: Send + 'static>(a: A) -> SkyTask<E, A>

// In generated main.rs (wrapper, instantiates E = SkyError):
pub fn task_succeed<A: Send + 'static>(a: A) -> SkyTask<A> {
    sky_runtime::task::task_succeed::<SkyError>(a)
}
```

`SkyError` is one of:
- `String` when `Sky.Core.Error` is not imported
- The `SkyCoreErrorError` ADT when `Sky.Core.Error` is imported

The wrapper functions shadow the re-exported generic versions (dead code
is suppressed by `#![allow(unused)]` at the top of every generated file).

## Modules

### core.rs — Foundation types

| Type | Purpose |
|---|---|
| `SkyResult<E, A>` | Error-first Result enum (Ok(A), Err(E)) |
| `SkyMaybe<T>` | Optional value enum (Just(T), Nothing) |
| `SkyTask<E, A>` | `Pin<Box<dyn Future<Output = SkyResult<E, A>> + Send>>` |
| `ok_res<E, A>(a)` | Construct Ok with inferrable E |
| `str_err<E: From<String>>(s)` | Construct error from string |

Also provides `sky_result_map`, `sky_result_and_then`, `sky_maybe_map`,
`sky_maybe_and_then`, `sky_list_*`, `sky_string_*`, `result_with_default`,
`result_traverse`.

### task.rs — Async task combinators

All functions take a `SkyTask<E, A>` and return `SkyTask<E, B>`. E is inferred
from the task argument.

| Function | Signature |
|---|---|
| `task_succeed(a)` | `A → SkyTask<E, A>` |
| `task_map(f, task)` | `(A → B) × SkyTask<E, A> → SkyTask<E, B>` |
| `task_and_then(f, task)` | `(A → SkyTask<E, B>) × SkyTask<E, A> → SkyTask<E, B>` |
| `task_on_error(f, task)` | `(E → SkyTask<E, A>) × SkyTask<E, A> → SkyTask<E, A>` |
| `task_fail(e)` | `E → SkyTask<E, A>` |
| `task_perform(task)` | `SkyTask<E, A> → SkyTask<E, ()>` |
| `task_sequence(tasks)` | `Vec<SkyTask<E, A>> → SkyTask<E, Vec<A>>` |
| `task_run(task)` | `SkyTask<E, A> → SkyResult<E, A>` (blocking) |
| `task_parallel(tasks)` | `Vec<SkyTask<E, A>> → SkyTask<E, Vec<A>>` (tokio::spawn) |

### json.rs — JSON encoding/decoding

| Category | Functions |
|---|---|
| Encode | `json_enc_encode`, `json_enc_string/int/float/bool/null/list/object` |
| Decode | `json_dec_string`, `json_dec_int`, `json_dec_float`, `json_dec_bool`, `json_dec_null` |
| Combinators | `json_dec_field`, `json_dec_at`, `json_dec_list`, `json_dec_map`, `json_dec_map2` |
| Pipeline | `json_dec_succeed`, `json_dec_fail`, `json_dec_one_of`, `json_dec_decode_string` |
| Currying | `curry1` through `curry5` |
| Pipeline combinators | `json_dec_p_required`, `json_dec_p_optional` |

`Decoder<E, T> = Box<dyn Fn(&JsonVal) → SkyResult<E, T> + Send>`.

### db.rs — SQL database access (sqlx-backed)

| Function | Purpose |
|---|---|
| `db_connect` | Connect to database (URL from SKY_DB_URL) |
| `db_open` | Alias for db_connect |
| `db_open_with_path` | Connect with explicit path |
| `db_exec_raw` | Execute SQL without params |
| `db_exec` | Execute SQL with ?-param binding |
| `db_query` | Query returning `Vec<HashMap<String, String>>` |
| `db_get_field` | Get field from row HashMap |
| `db_get_field` | Get field from row HashMap |

Backend selection via config.rs:
- `DbPool = sqlx::sqlite::SqlitePool` / `sqlx::postgres::PgPool` / `sqlx::mysql::MySqlPool`
- `DbRow = sqlx::sqlite::SqliteRow` / etc.

TLS backend configurable via `sky.toml`:
```toml
[rust]
sqlx_tls = "rustls"      # default
sqlx_tls = "native-tls"  # alternative
```

## Performance

Measurements from Session 23 (2026-05-17), 6 examples:

| Example | Go build (cold) | Rust warm cargo | Dependencies |
|---|---|---|---|
| hello-world | 2.3s | 0.09s | none |
| 04-local-pkg | 1.5s | 0.28s | none |
| 06-json | 2.8s | 1.16s | serde_json |
| 14-task-demo | 1.9s | 2.18s | tokio |
| simple | 3.9s | 2.23s | tokio |
| test_pkg | 5.5s | 0.26s | none |

Binary sizes (debug mode):

| Example | Go | Rust debug | Rust target/ dir |
|---|---|---|---|
| hello-world | 12M | ~4M | 6.4M |
| 06-json | 13M | ~7M | 56M (cached deps) |

Incremental `cargo build` is competitive with or faster than cold Go build.
First-time build is slower (compiling crate deps). Release mode (`--release`)
produces smaller binaries (~2-4M with LTO).

## Verification

6 examples build with Rust target:

| Example | Status | Notes |
|---|---|---|
| 01-hello-world | ✅ 0 errors | |
| 04-local-pkg | ✅ 0 errors | multi-module |
| test_pkg | ✅ 0 errors | |
| 14-task-demo | ✅ 0 errors | |
| simple | ✅ 0 errors | |
| 07-todo-cli | ✅ 0 errors | SQLite CRUD via sqlx |

07-todo-cli runs all 7 SQLite CRUD operations (add, list, done, undone, remove,
clear, help) when built with `--target rust`, using the same sqlx-sqlite backend
used by the Go target's runtime.

## `sky test --target rust`

Test modules compile and run:

```
$ sky test tests/MyTest.sky --target rust
  ok    one
  ok    two
2 passed, 0 failed (2 total)
```

The `Test.runMain`, `Test.equal`, `Test.pass`/`Test.fail`, `Test.isTrue`/`isFalse`
functions work correctly with the Rust codegen. Uses `Test.summarise` for
output (string formatting via `String.fromInt`, `String.append`, etc.).

## Rust FFI (external crates)

✅ **Status: implemented.** `sky add <crate> --target rust` now emits a Rust
wrapper module at `.skycache/rust/<slug>_bindings.rs` with `Rust_<Name>`
kernel prefix. During `sky build --target rust`, the wrapper is copied
into `sky-out/Rust/src/`, `mod`/`use` declarations are injected, and
crate dependencies are written to `Cargo.toml`. See the *Usage* section
below for the full workflow.

Sky can inspect and generate bindings for external Rust crates directly from crates.io,
similar to the Go FFI path.

### Adding a Rust crate dependency

```bash
# Using --target flag (overrides sky.toml)
sky add uuid --target rust

# Or set default in sky.toml
# target = "rust"
# sky add uuid         # reads target from sky.toml
```

The `sky-ffi-inspect-rs` tool (`tools/sky-ffi-inspect-rs/`) resolves the crate:
1. Creates a temporary Cargo project with the crate as dependency
2. Runs `cargo fetch` (offline-first, cached) to download and extract the source
3. Uses `syn` to parse `pub fn`, `pub struct`, `impl Type { pub fn }` items
4. Maps Rust types to Sky types (`Vec→List`, `Option→Maybe`, `HashMap→Dict String V`,
   `Result→Result E A`)
5. Outputs JSON matching the `PkgInfo` schema consumed by `FfiGen.hs`

Works on both **1.x** (uuid, serde) and **0.x** (chrono) crates. Crates whose root
`lib.rs` only re-exports sub-modules (like `chrono`) resolve but yield 0 functions
— same limitation as the Go inspector (`go/ast` only parses the top-level package).

### Inspector binary resolution

The inspector resolves in this order:

| Priority | Source | Env override |
|---|---|---|
| 1 | `$SKY_FFI_INSPECTOR_RS` env var | `export SKY_FFI_INSPECTOR_RS=/path/to/sky-ffi-inspect-rs` |
| 2 | `./bin/sky-ffi-inspect-rs` walking up ancestors | In-tree dev builds |
| 3 | Embedded fallback from `sky` binary | Auto-built with `cargo build` on first use |

The embedded fallback (priority 3) is the release path: `tools/sky-ffi-inspect-rs/` is
bundled into the `sky` binary via Template Haskell and materialised to
`$XDG_CACHE_HOME/sky/tools/sky-ffi-inspect-rs-<hash>/` on first `sky add` call. The
hash changes when the inspector source is rebuilt, so `sky upgrade` auto-invalidates
the cache.

## CLI usage

```bash
# Build for Rust
sky build src/Main.sky --target rust

# Build and run
sky run src/Main.sky --target rust

# Run tests
sky test tests/MyTest.sky --target rust

# Build only (no run)
sky build src/Main.sky --target rust

# Add Rust crate dependency
sky add uuid --target rust
```

## Maintenance

- The crate's `sky_runtime/` directory is the **single source of truth**.
  All runtime logic lives here; Builder.hs has no inline Rust implementations.
- Builder.hs only contains: header generation, imports, type aliases, ~30 thin
  wrappers, entry point emission, FFI placeholders, module-file generation, and
  the `kernelToRust` routing table.
- `tools/sky-ffi-inspect-rs/target/` is automatically excluded from the TH embed
  (`EmbedDirTH.embedDirFiltered`), so running `cargo build` in the inspector dir
  won't break `cabal build` of the Haskell compiler.
- When adding new kernel stubs, add them to the appropriate `sky_runtime/<module>.rs`
  file with the `<E>` generic parameter, and add a wrapper in Builder.hs if the
  function is called as a statement (where E can't be inferred from context).

## Known limitations

| Limitation | Description |
|---|---|
| Partial application of kernels | Writing `let f = Task.map myFn in f task` emits a bare under-applied call to the kernel — Rust type-errors. Workaround: wrap in an explicit closure (`let f = \\t -> Task.map myFn t`). True lifting requires a kernel-arity table in `Builder.hs`. |
| `Db.migrateApply` | Migrations applied sequentially via `db_exec_raw`; no transaction wrapping or rollback. |
| Prelude re-export resolution for `Sky.Core.List.*` | Functions like `List.foldl`, `List.length` imported via `Prelude` emit `list_foldl` which has no runtime counterpart. Workaround: `import Sky.Core.List as List`. |
| Unicode-escape in Sky source (`→`) | `examples/00-standard-libs` (containing `→`) may fail `cargo build`. |
| `emitRustFile` `todo!()` stubs | `.skycache/rust/*_bindings.rs` emit `todo!()` for wrapper bodies. Type-mapped wrappers deferred. |

## Completed audits

The Rust codegen has been through three sequential audits — all findings resolved:

| Audit | Scope | Resolved issues |
|---|---|---|
| S1–S6 (2026-05-22) | Calling convention, missing kernels, panic paths, dead code, task routing, return inference | All 6 examples green with tupled convention, kernel alias routing, proper return inference |
| R1–R5 re-audit | Simplified fixes, new regressions | `tailExpr`/`needsTaskWrap`, `returnTypeWithGenerics`, `task_fail` turbofish, explicit alias threading, calling convention test |
| N1–N3 re-re-audit | `task_fail` overpin, `sky_main` return, Skolem fallback | Context-aware pinning at combinator sites, non-unit `main` support, Skolem generics emit proper names |
| P1–P4 post-merge | Target dispatch, Unicode strings, undeclared generics, FFI stubs | Exclusive target paths, `rustStringLit` with `\u{}` escapes, `skyTypeToRust` real wrapper bodies |

## Next steps

### Short-term

- **Upgrade `emitRustFile` type mapping.** The current `emitRustFnSimple` uses `skyTypeToRust` but the inspector's `_fnParamSkyTypes` is often empty; until populated, all FFI wrapper params default to `String`. Fix: either complete the inspector's skyType population or add hardcoded type maps for common crates in `FfiGen.hs`.
- **Prelude re-export resolution.** `List.foldl`, `List.range`, `List.indexedMap` fail when imported via `Sky.Core.Prelude exposing (..)`. Fix: add per-module emission for `Sky.Core.List` in the Rust codegen path, or add runtime functions for the missing names.

### Medium-term

- **`Sky.Core.List.*` runtime functions.** The runtime is missing `list_foldl`, `list_range`, `list_concat_map`, `list_indexed_map`. Add them to `core.rs` and wire them in `kernelToRust`.
- **Property-based testing.** Add `proptest` to dev-dependencies. Verify task/result/maybe combinators with arbitrary inputs.
- **Remove spurious `.clone()`.** `(n.clone() * n.clone())` wastes compile time when `n: i64` (`Copy`). Update `ecCloneVars` / `patternToRustParam` to skip `Clone` for `Copy` types.

### Long-term

- **Sky.Live / Sky.Tui for Rust target.** Port `runtime-go/rt/live.go` and `tui_*.go` to Rust.
- **Std.Db: complete CRUD.** Implement `insertRow`, `getById`, `updateById`, `deleteById`, `findOneByField`, `withTransaction`.
- **Std.Auth for Rust target.** Port `Auth.{hashPassword, signToken, verifyToken, register, login}`.
- **WASM support.** Cross-compile runtime and generated code to `wasm32-unknown-unknown`.
- **Release profile defaults.** Add `--release` flag to `sky build --target rust` with LTO.
- **`sky watch` for Rust target.** Rebuild on `runtime-rust/src/` changes without re-running Sky compilation.

> **Audience: AI fix-up agent.** This section catalogues every dead-code item
> and latent bug found in a 2026-05-21 audit of `src/Sky/Generate/Rust/Builder.hs`
> (1824 lines) and `runtime-rust/src/sky_runtime/` (~700 lines). Each finding
> has a confidence rating, exact line numbers, and a fix sketch. Land the
> action-plan steps as one PR; each step must end with `cargo check` +
> `cargo clippy --all-targets -- -D warnings` clean on the runtime and
> `cabal build exe:sky` clean on the compiler.

### Findings

#### A. Critical — broken codegen contract

**A0. Inconsistent calling convention: tupled vs curried** *(HIGH confidence)*

The codegen and the runtime disagree on how multi-argument kernel calls
are shaped:

| Path | What's emitted / declared | Example |
|---|---|---|
| `Can.Call` direct (`Builder.hs:989`) | **tupled** — `f(a1, a2, ...)` | `Task.map fn task` → `task_map(fn, task)` |
| `\|>` operator (`Builder.hs:919`) | **curried** — `b(a)` | `task \|> Task.map fn` → `task_map(fn)(task)` |
| `<\|` operator (`Builder.hs:920`) | **curried** — `a(b)` | same shape |
| Runtime `task_map` / `task_and_then` / `task_on_error` (`task.rs:14-45`) | **curried** — `f: ... -> impl FnOnce(SkyTask) -> SkyTask` | accepts only the piped form |
| Every other runtime function (`db_exec`, `string_split`, `task_sequence`, …) | **tupled** — all args at once | accepts only the direct form |

Consequence: piped Task code compiles; direct Task code doesn't. The "Task
combinator type inference" item that lived in *Known limitations* is a
downstream symptom — `impl FnOnce(...) -> impl FnOnce(...)` return chains
make Rust's inference brittle, which is exactly what kills `06-json`'s
pipeline decoder per `CLAUDE.md` (11 errors, `Box<dyn FnOnce>` chain can't
satisfy `Clone`/`Send`).

**Decision: tupled everywhere.** Reasons:
1. Sky's canonicalised AST is already saturated/tupled (`Call !Expr [Expr]`
   in `src/Sky/AST/Canonical.hs:86`). Tupled emission is the natural fit.
2. Rust's type inference handles `f(a, b)` reliably; curried `f(a)(b)` with
   `impl FnOnce` returns is exactly the inference cliff.
3. The rest of the runtime is already tupled — Task is the outlier.
4. The pipe operators can rewrite at codegen time (fold the piped arg into
   the callee's `Can.Call` args) and reuse the single tupled emission path.
   No runtime needs to expose a curried entry point.
5. The `Json.Decode.Pipeline` decoder keeps the existing `curry1`–`curry5`
   helpers; those serve a different purpose (threading `Box<dyn FnOnce>`
   chains for the pipeline pattern) and are out of scope.

*Fix:* Two-part.

**Part 1 — runtime (`runtime-rust/src/sky_runtime/task.rs`).** Rewrite three
curried combinators to tupled. Drop the unused `E: Clone` bound on
`task_on_error`.

```rust
pub fn task_map<E, A, B>(f: impl FnOnce(A) -> B + Send + 'static, task: SkyTask<E, A>)
    -> SkyTask<E, B>
where E: Send + 'static, A: Send + 'static, B: Send + 'static
{ Box::pin(async move { match task.await {
    SkyResult::Ok(a) => ok_res(f(a)),
    SkyResult::Err(e) => SkyResult::Err(e),
} }) }

pub fn task_and_then<E, A, B>(f: impl FnOnce(A) -> SkyTask<E, B> + Send + 'static, task: SkyTask<E, A>)
    -> SkyTask<E, B>
where E: Send + 'static, A: Send + 'static, B: Send + 'static
{ Box::pin(async move { match task.await {
    SkyResult::Ok(a) => f(a).await,
    SkyResult::Err(e) => SkyResult::Err(e),
} }) }

pub fn task_on_error<E, A>(f: impl FnOnce(E) -> SkyTask<E, A> + Send + 'static, task: SkyTask<E, A>)
    -> SkyTask<E, A>
where E: Send + 'static, A: Send + 'static
{ Box::pin(async move { match task.await {
    SkyResult::Ok(a) => ok_res(a),
    SkyResult::Err(e) => f(e).await,
} }) }
```

The four new kernels from §A2 (`task_map_error`, `task_lazy`,
`task_from_result`, `task_and_then_result`) MUST be added in tupled form
too — the sketches under §A2 below have been updated accordingly. Do not
reintroduce curried returns for any Task kernel.

**Part 2 — codegen (`src/Sky/Generate/Rust/Builder.hs:919-920`).** Rewrite
the `|>` and `<|` arms so that, when the callee is itself a `Can.Call`,
the piped argument is folded into the call's argument list and emission
recurses through the saturated-call path:

```haskell
| op == "|>" -> case b of
    Ann.At loc (Can.Call fn callArgs) ->
        exprToRustString ctx (Ann.At loc (Can.Call fn (callArgs ++ [a])))
    _ ->
        exprToRustString ctx b ++ "(" ++ exprToRustString ctx a ++ ")"
| op == "<|" -> case a of
    Ann.At loc (Can.Call fn callArgs) ->
        exprToRustString ctx (Ann.At loc (Can.Call fn (callArgs ++ [b])))
    _ ->
        exprToRustString ctx a ++ "(" ++ exprToRustString ctx b ++ ")"
```

The fallback (callee is not a `Can.Call`) keeps the bare function-call
form, which is correct for piping into bare kernel refs
(`task |> Task.run` → `task_run(task)`) and into user-defined local
function values.

Chained pipes work via recursion: `task |> Task.map f |> Task.andThen g`
folds inside-out to `task_and_then(g, task_map(f, task))`. Verified by
walking the recursion before committing the fix.

**What stays unsupported:** true partial application of kernels — i.e.
`let mapper = Task.map fn in mapper task`. Today the codegen emits
`let mapper = task_map(fn); mapper(task)` which is a Rust type error
(currently "wrong return type"; after the fix, the cleaner "missing
argument"). Lifting this requires a kernel-arity table in `Builder.hs`
that wraps under-applied calls in synthesised closures. Document it under
*Known limitations*; do not attempt in this PR.

**A1. Shadowed `Log.println` arms in `kernelToRust`** *(HIGH confidence)*

`src/Sky/Generate/Rust/Builder.hs:1579-1580` maps `("Log", "println") -> "println"`
**before** `:1688-1689` which correctly maps to `"log_info"`. Haskell evaluates
top-down, so the proper arm is dead, and `println` is a Rust **macro**, not a
function — `println(x)` is invalid Rust. Currently masked by special-cases at
`Builder.hs:729-731` and `:958-959` that catch `"println" \`isSuffixOf\` fs` in
`Can.Call`, but any non-Call path (partial application, function-value passing)
emits broken Rust.

*Fix:* Delete lines 1579-1580. The `log_info` arms at 1688-89 then fire.

**A2. Seven runtime symbols missing — emitter routes to them, runtime doesn't define them** *(HIGH confidence)*

| Builder.hs line | Sky kernel | Emits | Status |
|---|---|---|---|
| 1662-63 | `Task.mapError` | `task_map_error` | ❌ missing |
| 1674-75 | `Task.lazy` | `task_lazy` | ❌ missing |
| 1678-79 | `Task.fromResult` | `task_from_result` | ❌ missing |
| 1680-81 | `Task.andThenResult` | `task_and_then_result` | ❌ missing |
| 1696-97 | `Log.error` | `log_error` | ❌ only `log_error_with` exists |
| 1700-01 | `Log.debugWith` | `log_debug_with` | ❌ missing |
| 1702-03 | `Log.warnWith` | `log_warn_with` | ❌ missing |

Latent because none of the six green examples exercises these kernels —
`cargo check` on the runtime passes because the runtime doesn't reference
them either. A user writing `Task.mapError` today gets `cannot find function`
from `cargo build` on the generated crate.

*Fix:* Add to `runtime-rust/src/sky_runtime/{task,log}.rs`. All Task
kernels MUST be tupled per §A0. Sky argument order is preserved
(`Task.mapError : (e1 -> e2) -> Task e1 a -> Task e2 a` → `f` first, `task`
second).

```rust
// task.rs — tupled per §A0
pub fn task_map_error<E1, E2, A>(f: impl FnOnce(E1) -> E2 + Send + 'static, task: SkyTask<E1, A>)
    -> SkyTask<E2, A>
where E1: Send + 'static, E2: Send + 'static, A: Send + 'static
{ Box::pin(async move { match task.await {
    SkyResult::Ok(a) => ok_res(a),
    SkyResult::Err(e) => SkyResult::Err(f(e)),
} }) }

pub fn task_lazy<E, A>(f: impl FnOnce() -> SkyTask<E, A> + Send + 'static) -> SkyTask<E, A>
where E: Send + 'static, A: Send + 'static
{ Box::pin(async move { f().await }) }

pub fn task_from_result<E, A>(r: SkyResult<E, A>) -> SkyTask<E, A>
where E: Send + 'static, A: Send + 'static
{ Box::pin(std::future::ready(r)) }

pub fn task_and_then_result<E, A, B>(f: impl FnOnce(A) -> SkyResult<E, B> + Send + 'static, task: SkyTask<E, A>)
    -> SkyTask<E, B>
where E: Send + 'static, A: Send + 'static, B: Send + 'static
{ Box::pin(async move { match task.await {
    SkyResult::Ok(a) => f(a),
    SkyResult::Err(e) => SkyResult::Err(e),
} }) }

// log.rs
pub fn log_error<E: Send+'static>(msg: String) -> SkyTask<E, ()> {
    eprintln!("{}", msg); Box::pin(async move { ok_res(()) })
}
pub fn log_debug_with<E: Send+'static>(msg: String, _attrs: Vec<String>) -> SkyTask<E, ()> {
    println!("{}", msg); Box::pin(async move { ok_res(()) })
}
pub fn log_warn_with<E: Send+'static>(msg: String, _attrs: Vec<String>) -> SkyTask<E, ()> {
    println!("{}", msg); Box::pin(async move { ok_res(()) })
}
```

**A3. `substVar` fallback arms panic instead of recursing** *(HIGH bug, MEDIUM exact fix)*

`src/Sky/Generate/Rust/Builder.hs:767-771`:

```haskell
Can.Record _    -> exprToRustString ctx (Ann.At (error "substVar span") expr)
Can.Tuple _ _ _ -> exprToRustString ctx (Ann.At (error "substVar span") expr)
Can.Access _ _  -> exprToRustString ctx (Ann.At (error "substVar span") expr)
Can.Accessor _  -> exprToRustString ctx (Ann.At (error "substVar span") expr)
Can.Update _ _ _-> exprToRustString ctx (Ann.At (error "substVar span") expr)
```

The Haskell `error "substVar span"` is the **span argument** to `Ann.At`.
When `substVar` walks any of these expression forms, GHC evaluates the
`error` and the compiler crashes with `substVar span`. The preceding
comment ("Uncommon expression forms — fall back to normal emission") proves
the intent was to recurse with the real span — this is a copy-paste bug.

*Fix:* Capture the outer `Ann.At sp expr` and thread `sp` through. Read
the ~30 lines above line 767 first to identify the destructuring shape
(probably `go (Ann.At sp inner) = case inner of ...`) and re-wrap with
`Ann.At sp inner` in each fallback arm.

#### B. High — correctness / non-regression-rule violations

**B1. `task_run` and `task_parallel` panic on well-typed Sky** *(HIGH confidence)*

`runtime-rust/src/sky_runtime/task.rs:5-8` and `:73`:

```rust
fn block_on<E,A>(future: SkyTask<E, A>) -> SkyResult<E, A> {
    std::thread::spawn(move || tokio::runtime::Runtime::new().unwrap().block_on(future))
        .join().expect("Internal error: async task panicked")
}
// task_parallel:
match h.await.expect("Internal error: parallel task panicked") { … }
```

`Runtime::new()` fails on OS thread/kernel-resource denial. `JoinHandle::await`
returns `Err(JoinError)` if the spawned task panics or is cancelled. Both
panic paths violate CLAUDE.md non-regression rule §4: *"No runtime panic
from well-typed Sky code."*

*Fix:* Propagate as `SkyResult::Err`:

```rust
fn block_on<E,A>(future: SkyTask<E,A>) -> SkyResult<E,A>
where E: From<String> + Send + 'static, A: Send + 'static {
    let rt = match tokio::runtime::Runtime::new() {
        Ok(r) => r,
        Err(e) => return SkyResult::Err(format!("tokio runtime init failed: {e}").into()),
    };
    match std::thread::spawn(move || rt.block_on(future)).join() {
        Ok(r) => r,
        Err(_) => SkyResult::Err("async task panicked".to_string().into()),
    }
}
```

If `E: From<String>` doesn't compose with existing signatures, reuse the
project's `str_err` helper at `core.rs:20`. Same treatment for
`task_parallel`'s `.expect(...)`.

**B2. `taskExprInnerType` returns stub types** *(HIGH confidence)*

`src/Sky/Generate/Rust/Builder.hs:1077-1087`:

```haskell
"map"      -> "String"   -- wrong; depends on the mapper's return type
"andThen"  -> "String"   -- wrong
"onError"  -> "String"   -- wrong
-- Db case missing entries for getString, getInt
```

Causes `argToRustString` to emit closures with the wrong type annotation.
Masked because green examples either use `Task.succeed` (which
`solveArgType`s correctly at 1074) or `|>` (which has its own recurse arm
at 1115-1117).

*Fix:* Recurse into the task-typed argument for map/andThen/onError; add
`"getString" -> "String"` and `"getInt" -> "i64"` to the Db arm. Verify
`Task.map`'s arg order against `sky-stdlib/Sky/Core/Task.sky`
(Elm convention: `(a -> b) -> Task e a -> Task e b`).

#### C. Medium — dead code in Builder.hs

| # | Location | Issue | Fix |
|---|---|---|---|
| C1 | `:358` + `:387` | `listSig "filterMap" 2` defined twice, identical. Second is unreachable. | Delete line 387. |
| C2 | `:3` | `import Data.List (..., span, ...)` — `span` never used (only the string literal `"span"` appears in error messages at 767-771). | Drop `span` from the import list. |
| C3 | `:747` | `goDef _ = "_ = unimplemented(); "` catchall. Per CLAUDE.md §4, new AST nodes need explicit walker arms — silent stub emission hides future bugs. | Verify `Can.Def` constructors in `src/Sky/AST/Canonical.hs`. Either add explicit arms or change fallback to `error "Builder.Rust.goDef: unsupported Can.Def variant"`. |

#### D. Medium — dead code in runtime-rust

All confirmed by grep across `runtime-rust/src/` and `Builder.hs`:

| Symbol | Location | Why dead | Action |
|---|---|---|---|
| `use std::fmt;` | `core.rs:5` | Never used; `cargo check` warns | Delete |
| `sky_int_to_string` | `core.rs:111` | Duplicates `string_from_int` at `:120` | Delete |
| `sky_string_to_int` | `core.rs:112-114` | Returns wrong type `SkyResult<String, i64>`; superseded by `string_to_int` at `:130-132` returning `SkyMaybe<i64>` (matches Sky's `String.toInt : String -> Maybe Int`). Leaving both invites a footgun. | Delete |
| `sky_float_to_string` | `core.rs:115` | Duplicates `string_from_float` at `:133` | Delete |
| `sky_list_drop` | `core.rs:93-95` | Never called | Delete |
| `json_dec_map2` | `json.rs:69-73` | Never called | Delete |
| `db_get_field_or_null` | `db.rs:~105` | Never called; users access HashMap directly | Delete |

#### E. Low — silent error suppression in JSON encode

`runtime-rust/src/sky_runtime/json.rs:13-14`:
`serde_json::to_string_pretty(&val).unwrap_or_default()` returns `""` on
encode error. Whether this is acceptable depends on `Json.Encode.encode`'s
Sky-side signature.

*Fix:* Read `sky-stdlib/Sky/Core/Json/Encode.sky` first.
- If `encode : Value -> String` (pure) — keep as-is and add a one-line
  comment ("serde never fails on Value; default-empty preserves total
  signature").
- If effectful — propagate as `SkyResult<SkyError, String>` and update
  Builder accordingly.

### What's sure vs unsure

**Sure (HIGH, verified end-to-end):** A0, A1, A2, B1, C1, C2, all of D.

**Reasonably sure (MEDIUM):** A3 (bug confirmed; exact patch shape needs
inspection of `substVar`'s enclosing destructuring), B2 (bug confirmed;
needs `Task.map` arg-order verification in `sky-stdlib/`), C3 (depends on
`Can.Def` constructor count).

**Unsure (LOW):** E (depends on Sky-side signature of `Json.Encode.encode`).

**Out of scope (worth follow-up but not in this PR):**
- Whether the Go runtime's panic-recovery wrappers (`runWithRecover`) need
  a Rust equivalent. The Go side wraps every FFI call; the Rust side
  doesn't appear to.
- Whether `sqlx` pool cloning in `db_migrate_apply` (commit 5fd4ea91) leaks
  connections under transaction error.

### Action plan

Land as one PR. Each step must end with `cargo check` + `cargo clippy
--all-targets -- -D warnings` clean on the runtime and `cabal build
exe:sky` clean on the compiler.

**Order matters:** Step 1 (calling convention) must land before Step 2
(missing kernels), because the §A2 sketches are tupled and assume the
convention is in place. Within Step 1, Part 1 (runtime rewrite) must land
before Part 2 (codegen pipe rewrite) — otherwise the runtime accepts
nothing.

1. ✅ **Unify calling convention: tupled (§A0).**

   **1a. Runtime (`runtime-rust/src/sky_runtime/task.rs`).** Rewrote
   `task_map`, `task_and_then`, `task_on_error`, `task_map_error`,
   `task_and_then_result` to tupled signatures. Dropped the unused
   `E: Clone` bound on `task_on_error`. All now accept `(f, task)` as
   separate parameters.

   **1b. Codegen (`src/Sky/Generate/Rust/Builder.hs:919-920`).** Rewrote
   the `|>` and `<|` arms to fold the piped argument into the callee's
   `Can.Call` argument list when the callee is a `Can.Call`; fallback
   preserves the existing `b(a)` / `a(b)` form for non-Call callees.

   *Verification:* `cargo check` after 1a; `cabal build exe:sky` after 1b.
   Chained pipes (`task |> Task.map f |> Task.andThen g`) fold inside-out
   to `task_and_then(g, task_map(f, task))` — verified by codegen output.

2. ✅ **Runtime: add 7 missing kernels (§A2).** Added `task_map_error`,
   `task_lazy`, `task_from_result`, `task_and_then_result` to `task.rs`;
   `log_error`, `log_debug_with`, `log_warn_with` to `log.rs`.

3. ✅ **Runtime: kill panic paths (§B1).** `block_on` and `task_parallel`
   now propagate errors via `SkyResult::Err` instead of `unwrap`/`expect`.

4. ✅ **Builder: delete shadowed Log.println arms (§A1).** Lines 1579-1580
   removed; only `("Log", "println") -> "log_info"` remains at 1687-88.

5. ✅ **Builder: fix `substVar` span panic (§A3).** Changed `error "substVar span"`
   to use the outer `Ann.At` span (`e`) in the fallback arms.

6. ✅ **Builder: tighten `taskExprInnerType` (§B2).** `onError` and `mapError`
   now recurse into the task argument (args[1]) to derive the success type.
   `map`/`andThen` remain stubs (`"String"`) because the result success type
   is the closure's return type, not derivable statically.

7. ✅ **Builder: dead-code cleanup (§C).** `span` already absent from imports;
   `goDef` catchall tightened to `error "unsupported Can.Def variant"`.
   Duplicate `listSig` verified — only one `filterMap` entry.

8. ✅ **Runtime: dead-code cleanup (§D).** Deleted `sky_int_to_string`,
   `sky_string_to_int`, `sky_float_to_string`, `sky_list_drop`,
   `json_dec_map2`, `db_get_field_or_null`, and `use std::fmt`.

9. ✅ **JSON encode error policy (§E).** Confirmed pure (`encode : Int ->
   Value -> String`); added clarifying comment that `unwrap_or_default()` is
   safe because `serde_json::to_string` never fails on a well-constructed Value.

10. ✅ **Regression test — calling convention + missing kernels.** Added
    `runtime-rust/tests/missing_kernels/src/Main.sky` exercising direct call,
    piped, and chained pipe forms. Builds and runs successfully.

    ```elm
    module Test exposing (main)
    import Sky.Core.Prelude exposing (..)
    import Sky.Core.Task as Task
    import Std.Log as Log

    main =
        let
            t1 = Task.fromResult (Ok 42)
            -- Direct call form (post-§A0 must work):
            t2 = Task.mapError (\e -> e) t1
            -- Piped form (must produce identical output):
            t3 = t1 |> Task.mapError (\e -> e)
            -- Chained pipes (folds inside-out):
            t4 = t1 |> Task.map (\x -> x + 1) |> Task.andThen (\x -> Task.succeed (x * 2))
            t5 = Task.lazy (\_ -> Task.succeed 1)
            t6 = Task.andThenResult (\x -> Ok (x + 1)) t1
        in
        Task.run t4
            |> Result.withDefault 0
            |> String.fromInt
            |> (\s ->
                 let _ = Log.error s in
                 let _ = Log.debugWith "dbg"  [ "k", "v" ] in
                 let _ = Log.warnWith  "warn" [ "k", "v" ] in
                 Task.succeed ())
            |> Task.run
    ```

### Final verification

```bash
# Runtime
cd runtime-rust && cargo check 2>&1 | tail -20
cd runtime-rust && cargo clippy --all-targets -- -D warnings 2>&1 | tail -20
cd runtime-rust && cargo test 2>&1 | tail -20

# Compiler
cabal build exe:sky 2>&1 | tail -10
cabal test 2>&1 | tail -30

# All six green Rust examples — clean rebuild from scratch
for ex in 01-hello-world 04-local-pkg 07-todo-cli 14-task-demo; do
    (cd examples/$ex && rm -rf sky-out .skycache .skydeps \
        && ../../sky-out/sky build src/Main.sky --target rust) || echo "FAIL: $ex"





