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
| **Polymorphic non-`Task` return types fail to build** | Functions like `mkOk x = Ok x` (`a -> Result e a`) emit `pub fn main_mk_ok(x: i64) {` — no return type → defaults to `()` — but the body produces `SkyResult`. Failure: E0282 + E0308. The "P3 fix" reverted to this behaviour from a worse one (undeclared `__Te_inst15`). See *Q-priorities → Q1* below. |
| **`sky add <crate> --target rust` produces empty bindings** | `sky add uuid --target rust` writes a **0-byte** `.skycache/rust/uuid_bindings.rs` and doesn't write `.skycache/ffi/<crate>.skyi` / `.kernel.json`. End-to-end FFI is unusable even though the binding *emitter* (`emitRustFnSimple`) was updated. See *Q-priorities → Q2*. |
| Partial application of kernels | Writing `let f = Task.map myFn in f task` emits a bare under-applied call to the kernel — Rust type-errors. Workaround: wrap in an explicit closure (`let f = \\t -> Task.map myFn t`). True lifting requires a kernel-arity table in `Builder.hs`. |
| `Db.migrateApply` | Migrations applied sequentially via `db_exec_raw`; no transaction wrapping or rollback. |
| Prelude re-export resolution for `Sky.Core.List.*` | Functions like `List.foldl`, `List.length` imported via `Prelude` emit `list_foldl` which has no runtime counterpart. Workaround: `import Sky.Core.List as List`. |
| Spurious `.clone()` on `Copy` types | `(n.clone() * n.clone())` for `n: i64` — wastes compile time but doesn't cause failure. |

## Completed audits

The Rust codegen has been through four sequential audits.

| Audit | Scope | Status |
|---|---|---|
| S1–S6 (2026-05-22) | Calling convention, missing kernels, panic paths, dead code, task routing, return inference | ✅ Resolved |
| R1–R5 re-audit | Simplified fixes, new regressions | ✅ Resolved |
| N1–N3 re-re-audit | `task_fail` overpin, `sky_main` return, Skolem fallback | ✅ Resolved |
| P1–P4 post-merge | Target dispatch (P1), Unicode strings (P2), polymorphic returns (P3), FFI stubs (P4) | ⚠️ **Partial** — P1 ✅, P2 ✅, P3 **renamed-not-fixed**, P4 **emitter-fixed-orchestration-broken** |
| Q1–Q3 (2026-05-23) | Below | 🚧 Open |

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


---

## Q-priorities (2026-05-23) — re-audit after the P1–P4 fixes claimed to land

> **Audience: AI fix-up agent.** This section is the result of an
> end-to-end verification of the P1–P4 fixes that `2faef85f "fix(rust):
> P1-P4 post-merge audit fixes"` claimed to deliver. P1 and P2 verified
> green. P3's "fix" only renamed the failure mode — polymorphic
> non-Task returns now emit no return type and default to `()`, which
> still doesn't compile. P4's binding *emitter* (`emitRustFnSimple`)
> was rewritten with real type mapping, but the orchestration that
> drives `sky add <crate> --target rust` writes a **0-byte** binding
> file. This section catalogues exactly what's broken, with concrete
> reproducers, and prescribes the next fix sequence.

### Reproducers (all fail today against `2faef85f` / `addd340f`)

Use `<SKY> = /home/arthur/Documentos/comp/sky/sky-out/sky`.

```bash
# Q1: polymorphic non-Task return type (regression of P3)
mkdir -p /tmp/sky-q1/src && cat > /tmp/sky-q1/src/Main.sky <<'EOF'
module Main exposing (main)
import Sky.Core.Prelude exposing (..)
import Std.Log exposing (println)
mkOk x = Ok x
main =
    case mkOk 42 of
        Ok n  -> println (String.fromInt n)
        Err _ -> println "err"
EOF
printf '[project]\nname = "q1"\ntarget = "rust"\n' > /tmp/sky-q1/sky.toml
(cd /tmp/sky-q1 && rm -rf sky-out .skycache && <SKY> build src/Main.sky --target rust)
# Generated:
#     pub fn main_mk_ok(x: i64) {                    // ← no return type → ()
#         SkyResult::Ok(x);                          // ← E0282, then E0308 at caller
#     }
# Expected: `pub fn main_mk_ok<T_e>(x: i64) -> SkyResult<T_e, i64>`.
# OR: `pub fn main_mk_ok(x: i64) -> SkyResult<SkyError, i64>` (concrete).

# Q2: `sky add <crate> --target rust` end-to-end produces nothing usable
mkdir -p /tmp/sky-q2 && cd /tmp/sky-q2
printf '[project]\nname = "q2"\ntarget = "rust"\n' > sky.toml
rm -rf .skycache
<SKY> add uuid --target rust
wc -c .skycache/rust/uuid_bindings.rs   # → 0 bytes
ls .skycache/ffi/                       # → empty (no .skyi, no .kernel.json)
# Expected after sky add:
#   .skycache/rust/uuid_bindings.rs   ≥ 7 lines (header + per-fn wrappers)
#   .skycache/ffi/uuid.skyi           Sky-side type signatures
#   .skycache/ffi/uuid.kernel.json    kernel routing entries
# All three are required for `sky build --target rust` on a file that
# imports the crate to type-check and link.
```

### Findings

#### Q1. Polymorphic non-Task returns still don't compile *(HIGH)*

**Root cause.** `src/Sky/Generate/Rust/Builder.hs:537-561`. When the
solved return type has TVars and `knownDefSig` has no entry, the patch
in `2faef85f` falls through to:

```haskell
-- Return type has TVars: use body inference
let bodyInner = taskExprInnerType (ecSolvedTypes ctx) body
in if null bodyInner
   then case knownDefSig modPrefix name n of   -- duplicate lookup
       Just (_, knownRetType2) -> knownRetType2
       Nothing -> "()"                          -- ← silent default
   else "SkyTask<" ++ bodyInner ++ ">"
```

For `mkOk x = Ok x`:
- `bodyInner = taskExprInnerType ...` — the body `Ok x` is not a Task
  expression, so this returns `""` (empty).
- `knownDefSig` has no entry for the user-defined `mkOk`.
- Falls through to `Nothing -> "()"`.
- Function signature emits `pub fn main_mk_ok(x: i64) {` (no `->`
  clause, so Rust infers `()`).
- Body emits `SkyResult::Ok(x);` → mismatch with the inferred `()`
  return type → E0282 + E0308.

The previous attempt at this fix (`__Te_inst15` undeclared generics)
was at least pointing at the right shape — it just didn't thread the
new generics into the function's `<…>` parameter list. The current
"fix" *deleted* that effort and reverted to a silent `()` default,
which is strictly worse: the failure surfaces at the call site instead
of in the signature, making it harder to diagnose.

**Proper fix.** Two paths, in increasing order of investment:

**Q1a. (Stop-gap, ~1 day.)** When `bodyInner` is empty and the body's
top expression is a known ADT constructor (`Can.VarCtor _ _ "Result" _ _`,
`Can.VarCtor _ _ "Maybe" _ _`, `Can.VarCtor _ _ "List" _ _`), emit a
concrete-error fallback: pin the error type to `SkyError`. For `Result`:

```haskell
Nothing ->
    case body of
        Ann.At _ (Can.Call (Ann.At _ (Can.VarCtor _ _ _ "Ok" _)) [arg]) ->
            let okType = solveArgType (ecSolvedTypes ctx) arg
            in "SkyResult<SkyError, " ++ okType ++ ">"
        Ann.At _ (Can.Call (Ann.At _ (Can.VarCtor _ _ _ "Err" _)) [arg]) ->
            let errType = solveArgType (ecSolvedTypes ctx) arg
            in "SkyResult<" ++ errType ++ ", String>"
        ...
        _ -> "()"
```

Covers the common case (`mkOk`, `mkErr`, `mkJust`, `mkNothing` etc.).
Doesn't help truly-polymorphic helpers but unblocks the failing
reproducer.

**Q1b. (Proper, ~3-5 days.)** Reinstate `returnTypeWithGenerics` (the
helper still exists at `Builder.hs:587-611`) AND thread its
`newGens` return value into the function's generic-parameter list.
The previous attempt landed step 1 but stopped before step 2; complete
the work:

1. Change `genVars` from a pre-rendered `String` (e.g. `"<T0: Clone>"`)
   to a `[(String, String)]` list of `(name, bounds)`. Search for every
   `RustFunction rustName genVars …` use site and adapt.
2. In `defToRustItem`, capture `newGens` from `returnTypeWithGenerics`
   and merge into the param-derived `genVars` list (use `Data.List.nub`).
3. Render the combined list once at the bottom of `defToRustItem`.
4. Default bounds on emitted-from-return generics: `Clone + PartialEq +
   std::fmt::Debug` (matches the existing per-generic bound style).

**Acceptance** for Q1: the Q1 reproducer above (`mkOk`) builds clean
and runs.

#### Q2. `sky add <crate> --target rust` orchestration is broken *(HIGH)*

**Reproduce:** `cd /tmp/sky-q2 && <SKY> add uuid --target rust`. Result:
`.skycache/rust/uuid_bindings.rs` is **0 bytes**; `.skycache/ffi/`
is empty.

**Two possible roots** (the agent must diagnose which):

1. **The inspector silently failed.** `sky-ffi-inspect-rs` returned a
   `PkgInfo` with `errors` set but `runInspectorForTarget` discarded
   the error and produced an empty result. `generateBindings TargetRust`
   then ran on an empty `_pkgFns`, emitting only the header — which
   *should* be ~7 lines, **not** 0 bytes.

2. **`generateBindings` was never called.** The 0-byte file was created
   by `createDirectoryIfMissing`/`writeFile` racing or by some other
   path. The empty `.skycache/ffi/` (no .skyi, no .kernel.json) is
   evidence that the second and third `writeFile` calls in
   `FfiGen.hs:305-318` didn't execute — but the first one (rsFile)
   somehow produced a 0-byte file.

**Diagnosis steps.** Run with verbose output and inspect each stage:

```bash
cd /tmp/sky-q2 && rm -rf .skycache
RUST_LOG=trace <SKY> add uuid --target rust 2>&1 | tee /tmp/skyadd.log
# Look for:
#   - "Inspecting with sky-ffi-inspect-rs..." (Main.hs:1604 area)
#   - inspector exit code / stderr
#   - "Generated N bindings in .skycache/" (Main.hs:1613 area)
#   - any unhandled exception trace
```

If the inspector fails: check `EmbeddedInspectorRust.ensureInspectorRust`
— the embedded `tools/sky-ffi-inspect-rs/` may not be rebuilding the
cached binary correctly. Verify
`~/.cache/sky/tools/sky-ffi-inspect-rs-<hash>/target/debug/sky-ffi-inspect-rs`
exists and runs.

If the inspector returns 0 functions: that's the previously-documented
"only top-level lib.rs parsed" limitation. The agent's claim of
"submodule traversal" (commit `2c480e15`) needs verification — `uuid`
crate likely re-exports from `src/uuid.rs`, `src/v4.rs`, etc.

**Proper fix.** Both pieces:

**Q2a.** Capture and surface inspector errors. In `app/Main.hs:1605-1610`
(the `Add` case path):

```haskell
r <- FfiGen.runInspectorForTarget target pkg
case r of
    Left err -> do
        putStrLn $ "   " ++ inspName ++ " warning: " ++ err
        return (Right ())
    Right info | not (null (_pkgErrors info)) -> do
        putStrLn $ "   " ++ inspName ++ " errors:"
        mapM_ (\e -> putStrLn $ "      " ++ e) (_pkgErrors info)
        when (null (_pkgFns info)) $
            putStrLn "   No public functions found; no bindings emitted."
        names <- FfiGen.generateBindings target info
        ...
    Right info -> ...
```

When `_pkgFns` is empty, `emitRustFile` still produces a header. If
the current code is producing 0 bytes, something is short-circuiting
before `writeFile`. Add a `putStrLn $ "Writing " ++ rsFile ++ " (" ++
show (length rendered) ++ " bytes)"` in `generateBindings` to find
out where bytes vanish.

**Q2b.** Strengthen the inspector. `tools/sky-ffi-inspect-rs/src/main.rs`
should follow `pub mod <name>;` declarations recursively. Today the
inspector reads only `src/lib.rs` (or `src/main.rs`). For a crate
with `pub use crate::v4::*;` in `lib.rs`, recurse into `src/v4.rs`.
Mirror the pattern from the Go inspector
(`tools/sky-ffi-inspect/main.go`).

**Acceptance** for Q2: `sky add uuid --target rust` produces
`.skycache/rust/uuid_bindings.rs` with ≥ 1 working wrapper fn (e.g.
`Uuid::new_v4`) AND `.skycache/ffi/uuid.skyi` AND
`.skycache/ffi/uuid.kernel.json`. A Sky program calling `Uuid.newV4 ()`
then builds and runs, printing a real UUID.

#### Q3. Sky.Core.List Prelude exposure — runtime symbols missing *(MEDIUM)*

**Status.** Already a documented limitation; not introduced by recent
work. Promoted to Q-priorities now that Q1 and Q2 are the only larger
blockers.

**Root cause.** `Sky.Core.Prelude exposing (..)` exposes `List.foldl`
/ `List.range` / `List.indexedMap` etc., but the per-module Sky.Core.List
file isn't emitted for the Rust target when the user *only* imports
Prelude. The codegen routes `Can.VarTopLevel "List" "foldl"` through
`kernelToRust "List" "foldl"` → falls through to snake-case `list_foldl`
→ undefined symbol at link time.

**Proper fix.** Two parts:

**Q3a.** Add missing runtime functions in
`runtime-rust/src/sky_runtime/core.rs` (or a new `list.rs`):
- `list_foldl<T0, T1>(f, init, list)`
- `list_foldr<T0, T1>(f, init, list)`
- `list_range(lo, hi) -> Vec<i64>`
- `list_indexed_map<T0, T1>(f, list)`
- `list_concat_map<T0, T1>(f, list)`
- `list_zip<T0, T1>(a, b)`
- `list_filter<T0>(pred, list)`
- `list_member<T0: PartialEq>(x, list)`
- `list_any<T0>(pred, list)`
- `list_all<T0>(pred, list)`

Use the existing `sky_list_*` and runtime fallback patterns as the
template (see `Builder.hs:1481-1483` `list_map_consume`).

**Q3b.** Add `kernelToRust` arms for each `("List", X)` and
`("Sky.Core.List", X)` mapping. The pattern is identical to the
Task/Result/Maybe arms already present.

**Acceptance** for Q3: build a Sky file using `List.foldl`,
`List.range`, `List.indexedMap` via only `Sky.Core.Prelude` import.
Builds and runs.

### Priorities (in order)

| Rank | Issue | Effort | Why this order |
|---|---|---|---|
| 1 | **Q1** (polymorphic returns) | 1-5 days (Q1a stop-gap → Q1b proper) | Affects any Sky code that returns `Result`/`Maybe`/custom ADT polymorphically. Most common user-written pattern. |
| 2 | **Q2** (FFI orchestration) | 2-4 days | The README and CLI advertise `sky add <crate> --target rust` as working. Right now it isn't. Until Q2 lands, the Rust target's differentiator (crate ecosystem access) is theatre. |
| 3 | **Q3** (Sky.Core.List Prelude exposure) | 1-2 days | Affects all users who imported `Sky.Core.Prelude exposing (..)` and used `List.foldl` (the canonical idiom). |
| 4 | Spurious `.clone()` on `Copy` types | 1 day | Quality-of-life; doesn't break builds, but bloats every generated function. Land after Q1-Q3. |
| 5 | Property-based tests + `cargo audit` in CI | 2-3 days | Guards against regressions when Q1-Q4 land. |

### Implementation plan

Land each priority as its own commit referencing the section below.
Each commit must end with: `cargo check`, `cargo clippy --all-targets
-- -D warnings` on `runtime-rust/`, `cabal build exe:sky`, all six
existing examples building clean, AND the corresponding Q-reproducer
above building clean.

#### Step 1 — Q1a (stop-gap for polymorphic returns)

1.1. In `src/Sky/Generate/Rust/Builder.hs:defToRustItem`, add a
constructor-shape check before the `Nothing -> "()"` fallback. Match
on the body's outermost `Can.Call (Can.VarCtor _ home typeName ctorName _) args`
and use `solveArgType` on `args` to derive the inner type. Use Sky
`SkyError` for any unresolved polymorphic error/value position.

1.2. Add the sketch (per §Findings Q1a) covering `Result` (Ok/Err),
`Maybe` (Just/Nothing), and bare `Can.VarLocal name` (look up the
local's solved type and emit it).

1.3. Verify the Q1 reproducer builds.

1.4. **Regression test.** Add `runtime-rust/tests/missing_kernels/Q1.sky`
exercising `mkOk x = Ok x`, `mkErr s = Err s`, `mkJust y = Just y`,
`mkNothing _ = Nothing`. Drive from the existing test harness.

#### Step 2 — Q2 (FFI orchestration)

2.1. **Add diagnostic output.** In `src/Sky/Build/FfiGen.hs:generateBindings
TargetRust`, log the size of each written file:
```haskell
let rsContent = emitRustFile kname pkg
putStrLn $ "   Writing " ++ rsFile ++ " (" ++ show (length rsContent) ++ " bytes, " ++ show (length (_pkgFns pkg)) ++ " fns)"
writeFile rsFile rsContent
```
Do the same for skyiFile and jsonFile. Rerun the Q2 reproducer to
diagnose where the 0-byte output is coming from.

2.2. **Fix the actual silent failure.** Once 2.1 reveals the root
cause, fix it. Likely candidates:
- Inspector returns `Left` and Main.hs writes 0 bytes anyway via a
  prior `createDirectoryIfMissing` race.
- `emitRustFile` returns `""` when `_pkgFns` is empty — verify by
  reading the function (it should at minimum emit the 7-line header).
- The `sky add` command silently uses a wrong target somewhere.

2.3. **Inspector submodule traversal verify-or-implement.** Run the
inspector directly:
```bash
~/.cache/sky/tools/sky-ffi-inspect-rs-*/target/debug/sky-ffi-inspect-rs uuid 2>&1 | head -30
```
If it returns 0 functions, the "submodule traversal" claim from
commit `2c480e15` isn't actually wired up. Implement it by recursively
parsing `pub mod <name>;` files (see §Findings Q2b).

2.4. **End-to-end test.** Add `examples/26-rust-ffi/` (or next free
slot) with:
- Sky source importing `uuid` and printing `Uuid.newV4 ()`.
- `sky.toml` declaring `target = "rust"` and the `[rust.dependencies]`
  uuid entry.
- A bash script that runs `sky add uuid --target rust && sky build
  --target rust && ./sky-out/Rust/target/debug/sky-app` and checks the
  output matches the UUID regex.

#### Step 3 — Q3 (Sky.Core.List runtime functions)

3.1. Implement the 10 missing list functions in
`runtime-rust/src/sky_runtime/core.rs` (or extract to a new `list.rs`
if the file is growing too large).

3.2. Wire `kernelToRust` arms in
`src/Sky/Generate/Rust/Builder.hs:kernelToRust`. Pattern:
```haskell
("List", "foldl") -> "list_foldl"
("Sky.Core.List", "foldl") -> "list_foldl"
-- repeat for foldr, range, indexedMap, concatMap, zip, filter,
-- member, any, all
```

3.3. **Regression test.** Add a Sky test exercising each function via
Prelude exposure (NO `import Sky.Core.List` line).

#### Step 4 — Spurious `.clone()` removal (optional, post-Q1-Q3)

4.1. Add an `ecCopyVars :: Set String` field to `EmitCtx`. Populate
during `defToRustItem` from `params` whose Sky type maps to a Rust
`Copy` type (`Int`, `Float`, `Bool`, `Char`).

4.2. In `patternToRustParam` / `argToRustString`, skip `.clone()` when
the local is in `ecCopyVars`.

4.3. Verify by reading the generated `n * n` for the Q1 reproducer —
should be `(n * n)` not `(n.clone() * n.clone())`.

### Verification

Final acceptance — run all of these after Steps 1-3 land:

```bash
# Runtime sanity
(cd runtime-rust && cargo check && \
 cargo clippy --all-targets -- -D warnings && \
 cargo test)

# Compiler sanity
cabal build exe:sky
cabal test

# The six existing green examples must remain green
for ex in 01-hello-world 04-local-pkg 07-todo-cli 14-task-demo simple test_pkg; do
    (cd examples/$ex && rm -rf sky-out .skycache .skydeps \
     && ../../sky-out/sky build src/Main.sky --target rust \
     && cargo build --manifest-path sky-out/Rust/Cargo.toml) || echo "FAIL: $ex"
done

# Q1, Q2, Q3 reproducers
for q in q1 q2 q3; do
    (cd /tmp/sky-$q && rm -rf sky-out .skycache \
     && /home/arthur/Documentos/comp/sky/sky-out/sky build src/Main.sky --target rust \
     && cargo build --manifest-path sky-out/Rust/Cargo.toml) || echo "FAIL: $q"
done

# Sanity: no Go artifacts polluting Rust builds
for ex in 01-hello-world; do
    for f in main.go go.mod go.sum rt; do
        [ ! -e examples/$ex/sky-out/$f ] || echo "FAIL: Go artifact $f in $ex"
    done
done

# Sanity: P3-renamed-not-fixed has been fixed
grep -nE '\-> "\(\)"' src/Sky/Generate/Rust/Builder.hs | \
    grep -iE 'polymorphic|TVar|tvars' && \
    echo "WARNING: silent () fallback for polymorphic returns may still exist"
```

### What's sure vs unsure

**Sure (HIGH, verified by `cargo build` + reading source):**
- Q1: polymorphic Result/Maybe/ADT returns emit no return type. Repro: `/tmp/sky-q1/src/Main.sky` (mkOk).
- Q2: `sky add uuid --target rust` produces 0-byte `uuid_bindings.rs`. Repro: `/tmp/sky-q2`.

**Reasonably sure (MEDIUM):**
- Q3: Sky.Core.List Prelude routing. Documented prior; not re-verified
  in this audit but the codepath in `Builder.hs:kernelToRust` plainly
  lacks the arms.

**Unsure (LOW):**
- Whether the inspector submodule traversal (claimed in `2c480e15`)
  actually works for crates with simple `pub use` re-exports. Step 2.3
  is the verification.

### Out of scope (tracked but not in this PR)

- **Sky.Live / Sky.Tui ports** to the Rust runtime. Significant work
  (~4-8 weeks); land after Q1-Q3.
- **Std.Auth + complete Std.Db CRUD** for Rust target. Mirror Go
  runtime's surface; ~2-3 weeks each.
- **WASM target.** Cross-compile runtime and generated code to
  `wasm32-unknown-unknown`. Requires runtime feature gating to strip
  `tokio` / `sqlx` from WASM builds.
- **Documentation reorg.** Move per-audit sections out of this README
  into `docs/rust/audit-log.md`; keep README as a steady-state user
  doc with links into the audit archive.

