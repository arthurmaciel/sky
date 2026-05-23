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
| **`sky add <crate> --target rust` times out (>10 min)** | The embedded inspector hash invalidates on **any** edit to `tools/sky-ffi-inspect-rs/src/main.rs`, forcing a cold `cargo build` of the inspector (55 transitive deps) on the next `sky add`. 3-7 min build + 30-90 s inspector run-time = typically exceeds command timeouts. The 0-byte `.skycache/rust/<crate>_bindings.rs` left behind is the harness killing the process mid-build, not an orchestration bug. See *Q-priorities → Q2*. |
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
| P1–P4 post-merge | Target dispatch (P1), Unicode strings (P2), polymorphic returns (P3), FFI stubs (P4) | ⚠️ **Partial** — P1 ✅, P2 ✅, P3 **renamed-not-fixed**, P4 **emitter-fixed-but-blocked-by-inspector-cold-build** |
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
> was rewritten with real type mapping, but **`sky add <crate>
> --target rust` times out before any binding can be written** — root
> cause is the inspector cold-build, not the orchestration logic (see
> Q2 below). This section catalogues exactly what's broken, with
> concrete reproducers, and prescribes the next fix sequence.
>
> **Diagnosis correction (2026-05-23 evening):** an earlier version of
> Q2 below described a "broken orchestration" bug. That diagnosis was
> wrong. The 0-byte `uuid_bindings.rs` is what gets written when the
> harness kills `sky add` mid-process during the inspector's cold
> cargo build (3-7 min for ~55 transitive deps). The fix is a
> caching-strategy change in `EmbeddedInspectorRust.hs`, not in the
> FFI orchestration code. The Q2 section has been rewritten to
> reflect this.

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

# Q2: `sky add <crate> --target rust` times out (>10 min) on first call
# after any `sky` rebuild
mkdir -p /tmp/sky-q2 && cd /tmp/sky-q2
printf '[project]\nname = "q2"\ntarget = "rust"\n' > sky.toml
rm -rf .skycache
time <SKY> add uuid --target rust         # → killed by harness after 10 min
wc -c .skycache/rust/uuid_bindings.rs     # → 0 bytes (process killed mid-build)
ls .skycache/ffi/                         # → empty (inspector never returned)
ls ~/.cache/sky/tools/                    # → look for new inspector-rs-<hash>
                                          #   dir with ~190 MB target/ — cold
                                          #   cargo build in progress when killed
# Expected after Q2 lands:
#   time sky add uuid --target rust completes in <30 s.
#   .skycache/rust/uuid_bindings.rs is non-empty (header + wrappers).
#   .skycache/ffi/uuid.{skyi,kernel.json} both exist.
#   ~/.cache/sky/tools/sky-ffi-inspect-rs-<hash>/sky-ffi-inspect-rs
#   exists as a single ~10-20 MB binary, no target/ dir.
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

#### Q2. `sky add <crate> --target rust` times out on first call after `sky` rebuild *(HIGH)*

**Reproduce:**
```bash
cd /tmp/sky-q2 && rm -rf .skycache
time <SKY> add uuid --target rust   # ⏱ exceeds 10 min; killed by harness
ls -la .skycache/rust/               # uuid_bindings.rs is 0 bytes
ls -la .skycache/ffi/                # empty
```

**Root cause: cold cargo build of the embedded inspector source.**

The chain (all evidence gathered 2026-05-23):

1. `EmbeddedInspectorRust.inspectorRustHash` (`EmbeddedInspectorRust.hs:48-57`)
   computes a SHA-256 of every byte in the TH-embedded
   `tools/sky-ffi-inspect-rs/` source tree. Any edit to the inspector
   source — including formatting-only or comment-only changes —
   invalidates this hash.
2. The Sky binary at `sky-out/sky` was rebuilt at 02:44 today; the
   inspector source was last touched 19:17 yesterday. So this `sky`
   binary carries a new hash.
3. `ensureInspectorRust` looks for
   `~/.cache/sky/tools/sky-ffi-inspect-rs-<hash>/target/debug/sky-ffi-inspect-rs`
   — doesn't exist (cache miss).
4. Falls into `buildInspectorRust`, which `cargo build`s the inspector
   tree cold.
5. The inspector pulls **55 transitive crates** (per its `Cargo.lock`):
   `syn` (full + extra-traits features), `cargo_metadata`,
   `serde_json`, `quote`, `proc-macro2`, `tempfile`. Cold cargo build:
   **3-7 minutes warm registry, 5-10 minutes cold**.
6. Once built, the inspector itself adds another **30-90 s** running
   `cargo fetch` then `cargo metadata` in a tempdir for `uuid`.

**Total: 4-9 minutes before any binding file is written.** When the
harness's command timeout fires (defaults often 10 min, sometimes
less), the inspector's cargo-build child process is killed mid-build,
leaving the 0-byte `uuid_bindings.rs` that
`createDirectoryIfMissing`/`writeFile` set up before the inspector
ever returned.

**Evidence in the filesystem.** Three cache dirs at
`~/.cache/sky/tools/sky-ffi-inspect-rs-{05e3b0621ff0,1e2441b58668,c313e5d5381a}`
(May 19, 21, 22) accumulated in three days, each ~192 MB of `target/`
artifacts. Every minor inspector-source edit creates a new cache dir
and forces a fresh cold build.

**Earlier-misdiagnosed alternatives** (the previous version of this
section listed both; both are wrong — keeping for reference):
- ❌ "The inspector silently failed and returned empty PkgInfo." The
  inspector never returns at all; it's killed mid-build.
- ❌ "`generateBindings` was never called." Wrong — `generateBindings`
  isn't reached because the inspector never completes. The 0-byte
  file is artifact of the directory setup, not a partial write.

**Proper fix — embed the compiled binary, not the source.**

Mirror what the Go inspector path does (`EmbeddedInspector.hs`):
ship the inspector as a pre-built executable bundled into the `sky`
binary, materialise it on first call, and skip cargo build entirely.

```haskell
-- src/Sky/Build/EmbeddedInspectorRust.hs

embeddedInspectorRustBinary :: ByteString
embeddedInspectorRustBinary =
    $(embedFile "tools/sky-ffi-inspect-rs/target/release/sky-ffi-inspect-rs")

ensureInspectorRust :: IO (Either String FilePath)
ensureInspectorRust = do
    cache <- getXdgDirectory XdgCache "sky"
    let dir = cache </> "tools" </> ("sky-ffi-inspect-rs-" ++ inspectorRustHash)
        bin = dir </> "sky-ffi-inspect-rs"
    exists <- doesFileExist bin
    unless exists $ do
        createDirectoryIfMissing True dir
        BS.writeFile bin embeddedInspectorRustBinary
        perms <- getPermissions bin
        setPermissions bin (setOwnerExecutable True perms)
    return (Right bin)
```

Cabal-side requirements:
- Either a `Setup.hs` `preBuild` hook or a `build-tool-depends`
  declaration that runs `cargo build --release` in
  `tools/sky-ffi-inspect-rs/` before TH evaluation, so the binary
  exists when `embedFile` opens it.
- The hash function can now be the inspector binary's SHA-256
  (cheap, stable on identical source).
- `sky` binary grows by ~10-20 MB (release-mode inspector binary).
  Acceptable — `sky` is already ~40 MB.

**Smaller alternatives, in order of preference:**

- **Option B: stabler hashing.** Hash only `tools/sky-ffi-inspect-rs/src/`
  (skip `Cargo.lock`/`Cargo.toml` whitespace). Cuts cache misses on
  inspector formatting changes. Doesn't help when actual code changes
  — still pays the cold build.
- **Option C: persistent daemon.** Spawn the inspector once per Sky
  session, send pkg queries via a Unix socket. Amortises
  `cargo metadata` across multiple `sky add` calls. Complexity
  cost; defer past Q2.

**Acceptance** for Q2:
- `time <SKY> add uuid --target rust` on a freshly-rebuilt sky binary
  completes in **<30 s wall-clock**.
- `~/.cache/sky/tools/sky-ffi-inspect-rs-<hash>/sky-ffi-inspect-rs`
  materialises instantly; no `target/` dir.
- `.skycache/rust/uuid_bindings.rs` is non-empty (the header + ≥1
  wrapper fn for a function the inspector discovers).
- `.skycache/ffi/uuid.skyi` and `.skycache/ffi/uuid.kernel.json` exist.
- A Sky program calling `Uuid.newV4 ()` then builds and runs,
  printing a real UUID.

**Out of scope for Q2 (defer to follow-ups):**
- *Whether the inspector finds any uuid functions at all.* If `lib.rs`
  re-exports submodules and the inspector reads only top-level
  `lib.rs`, the binding file ends up with the header only and 0
  wrappers. This is the "submodule traversal" task tracked separately
  (see commit `2c480e15` which claimed to fix it; verify after Q2
  lands). Different bug; doesn't block Q2's acceptance — the timeout
  is what's blocking everyone today.

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
| 2 | **Q2** (inspector cold-build) | 2-3 days | The README and CLI advertise `sky add <crate> --target rust` as working. Right now the first call after any `sky` rebuild times out at 4-9 min for a cold cargo build of the embedded inspector tree. Fix: embed the compiled inspector binary, not source. |
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

#### Step 2 — Q2 (inspector cold-build elimination)

The diagnostic-output / orchestration-fix steps that used to live
here have been deleted — they were chasing the wrong root cause. The
real fix is a caching-strategy change in `EmbeddedInspectorRust.hs`.

2.1. **Switch from embed-source to embed-binary.** Edit
`src/Sky/Build/EmbeddedInspectorRust.hs`. Replace the
`embedDirFiltered` source-tree embed with `embedFile` on the built
binary at `tools/sky-ffi-inspect-rs/target/release/sky-ffi-inspect-rs`.
Replace `buildInspectorRust`'s `cargo build` with a single
`BS.writeFile bin embeddedInspectorRustBinary + setOwnerExecutable`.
See the code sketch in §Findings Q2.

2.2. **Wire `cargo build --release` into the Cabal build.** Choose one:
- **Setup.hs hook.** Add a `Setup.hs` with `userHooks { preBuild =
  buildRustInspector ... }` that runs `cargo build --release
  --manifest-path tools/sky-ffi-inspect-rs/Cargo.toml` before any
  Haskell module is compiled (so TH's `embedFile` finds the binary).
- **`build-tool-depends`.** Declare a synthetic `build-tool-depends:
  sky-ffi-inspect-rs:sky-ffi-inspect-rs` in `sky-compiler.cabal` and
  rely on Cabal to invoke it. Simpler but less control.

Choose Setup.hs if cross-platform binary embedding becomes needed
later (`#ifdef`s for host triple).

2.3. **Update the inspector-hash.** With the binary embedded, the
"hash" can simply be the SHA-256 of the embedded binary bytes (not
the source tree). Or keep the source-tree hash but drop the cargo
build branch entirely — the cache miss now just means "materialise
binary to disk", which is cheap.

2.4. **Delete the cold-build path.** `buildInspectorRust`'s
`readCreateProcessWithExitCode (proc "cargo" ["build", ...])` block
becomes dead. Remove it. Verify
`grep -nE 'cargo build|readCreateProcessWithExitCode' src/Sky/Build/EmbeddedInspectorRust.hs`
returns zero hits.

2.5. **Clean up the old caches.** Add a one-time migration in
`ensureInspectorRust`: on cache-dir-write success, scan
`~/.cache/sky/tools/sky-ffi-inspect-rs-*` for dirs containing a
`target/` subdir, and delete them. This reclaims the ~192 MB × N
accumulated from prior cold builds. Idempotent and safe.

2.6. **End-to-end test.** Add `examples/26-rust-ffi/` (or next free
slot) with:
- Sky source importing `uuid` and printing `Uuid.newV4 ()`.
- `sky.toml` declaring `target = "rust"` and the `[rust.dependencies]`
  uuid entry.
- A bash test script that runs `time sky add uuid --target rust` and
  asserts the wall-clock is **<30 s** AND
  `.skycache/rust/uuid_bindings.rs` is non-empty AND the eventual
  binary prints a UUID matching `^[0-9a-f]{8}-...`.

**Deferred to Q2.7 (separate follow-up, not blocking Q2 acceptance):**
inspector submodule traversal. Once Q2.1-2.6 land, run the inspector
directly:
```bash
~/.cache/sky/tools/sky-ffi-inspect-rs-<hash>/sky-ffi-inspect-rs uuid 2>&1 | head -30
```
If it returns 0 functions, the "submodule traversal" claim from
commit `2c480e15` isn't actually wired up — implement it by
recursively parsing `pub mod <name>;` files. This is a separate bug
class (correctness of the parser) from Q2 (latency of the build).

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

