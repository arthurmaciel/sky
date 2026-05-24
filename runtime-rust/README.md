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

## Cross-backend rules (load-bearing — do not violate)

The Sky compiler supports multiple backends (today: Go and Rust;
future: WASM, embedded). Go is the **production / highest-priority
backend**. Rust and any future addition are second-tier. The
following rules are non-negotiable and apply to every contributor
(human or AI):

1. **Go FFI artifacts stay at the root of `.skycache/ffi/`.** Files
   like `.skycache/ffi/<slug>.kernel.json` and
   `.skycache/ffi/<slug>.skyi` are Go-target artifacts and must
   continue to live at this exact path. They are **not** moved into
   a `.skycache/ffi/go/` subdirectory. Existing Go projects (in this
   repo, in forks, and in the wild) depend on this layout — do not
   break them.

2. **Each non-Go backend gets its own subdirectory.** Rust artifacts
   live at `.skycache/ffi/rust/<slug>.kernel.json`. A future WASM
   backend would use `.skycache/ffi/wasm/`. The pattern: *Go = root,
   everything else = named subdir.*

3. **`loadAndSeedFfiRegistry` reads target-appropriate paths.** For a
   project with `target = "go"` (the default), the registry reads
   `.skycache/ffi/*.kernel.json` (root). For `target = "rust"`, the
   registry reads `.skycache/ffi/rust/*.kernel.json`. Loading **only**
   the active target's catalogue keeps imports unambiguous and avoids
   silent slug collisions across ecosystems.

4. **Never touch Go-generated files.** When adding or modifying
   anything related to the Rust backend, do not change a single byte
   of `.skycache/go/`, `.skycache/ffi/<slug>.{kernel.json,skyi}` at
   the root, `runtime-go/`, or the Go-codegen path in
   `src/Sky/Generate/Go/`. Rust work goes in `src/Sky/Generate/Rust/`,
   `runtime-rust/`, `tools/sky-ffi-inspect-rs/`, and (carefully)
   target-gated branches of shared files like
   `src/Sky/Build/Compile.hs`.

5. **Never change shared compiler code in ways that could break Go
   compilation in any fork.** Shared modules
   (`src/Sky/Build/Compile.hs`, `src/Sky/Build/FfiGen.hs`,
   `src/Sky/Build/FfiRegistry.hs`, `src/Sky/Canonicalise/*`,
   `app/Main.hs`, etc.) must keep their existing `TargetGo` behavior
   bit-identical. New Rust functionality goes behind explicit
   `TargetRust ->` branches. Refactors that merge target-specific
   logic into a unified path require a separate, explicit decision —
   default is: **keep the branches separate**.

6. **`sky add <pkg>` parsing rules:**
   - When `<pkg>` looks like a URL (`scheme://...` — `https://`,
     `http://`, `git://`, `ssh://`, plus `git@host:owner/repo`):
     - **For `--target rust`:** record as a git dependency in
       `[rust.dependencies]`, written as
       `<crate-name> = { git = "<url>" }`. The `<crate-name>` is
       discovered by cloning the repo into a tempdir and reading
       `Cargo.toml`'s `[package].name`. Optional `rev`/`branch`/`tag`
       qualifiers come from CLI flags
       (`--rev`, `--branch`, `--tag`) — none means "default branch".
     - **For `--target go`:** existing behavior, unchanged.
   - When `<pkg>` is a bare name (no `://` and no `git@…:` prefix):
     - **For `--target rust`:** assume crates.io. Run the inspector
       (which uses `cargo fetch` against the bare crate name) and on
       success write `<pkg> = "<resolved-version>"` into
       `[rust.dependencies]`.
     - **For `--target go`:** existing behavior — assume Go module
       path, run `go get`.
   - **No silent defaulting** to one or the other. Print exactly one
     line each: which source was assumed and which version pinned.

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

## Completed audits

| Audit | Scope | Status |
|---|---|---|
| S1–S6 (2026-05-22) | Calling convention, missing kernels, panic paths, dead code, task routing, return inference | ✅ Resolved |
| R1–R5 re-audit | Simplified fixes, new regressions | ✅ Resolved |
| N1–N3 re-re-audit | `task_fail` overpin, `sky_main` return, Skolem fallback | ✅ Resolved |
| P1–P4 post-merge | Target dispatch (P1), Unicode strings (P2), polymorphic returns (P3), FFI stubs (P4) | ✅ Resolved (P1, P2 verified; P3 fixed via SkyError concretization; P4 emitter fixed + Step A binary embed lands Q2) |
| Q1–Q3 + Steps 4-5 (2026-05-23) | Polymorphic returns, inspector cold-build, Sky.Core.List Prelude routing, Copy-type clone elision, property tests | ✅ Resolved — see *Verification snapshot* below |
| R1–R3 (2026-05-23 evening) | FFI naming convention (`Rust.*` prefix), method receiver calls, CLI hint | ✅ Resolved — imports use `Rust.Uuid`, methods call `arg0.fnName()`, CLI prints correct Rust.Uuid syntax |
| T1–T6 (2026-05-23 night) | `.skyi` catalogue non-functional, body type-mismatch, opaque types, duplicate names, CLI template leak | ✅ Resolved — see *T-priorities* below |
| U1 (asymmetric layout) | Go/Rust slug collision at `.skycache/ffi/` root | ✅ Resolved — see *Verification snapshot* |
| Step 0 (PkgSpec parsing) | `sky add` URL vs bare-name detection, `--rev`/`--branch`/`--tag` flags, inline table TOML emission | ✅ Resolved — see *Verification snapshot* |

### Verification snapshot (2026-05-23 evening)

End-to-end verified by running the smoke tests against fresh `sky-out/sky` (built from HEAD `dd79d333`):

| Item | Expected | Actual | Status |
|---|---|---|---|
| Q1 reproducer `mkOk x = Ok x` | builds clean | emits `pub fn main_mk_ok(x: i64) -> SkyResult<SkyError, i64>`; builds clean | ✅ |
| Q2 `time sky add uuid --target rust` | <30 s | **24.6 s** (was >10 min); 48 functions discovered | ✅ |
| Q3 `List.foldl` via Prelude (no explicit `import Sky.Core.List`) | builds clean | builds clean | ✅ |
| Step 4 Copy-type `.clone()` elision | `n * n` for `n: i64` | `task_succeed((n * n))` in `examples/simple` | ✅ |
| Step 5 property tests | `cargo test` green | 11 test results pass; 0 failures | ✅ |
| All 6 examples | clean rebuild + cargo build | all green | ✅ |
| Step A inspector embed | binary in `~/.cache/sky/tools/sky-ffi-inspect-rs/sky-ffi-inspect-rs`; no `target/` rebuild on cache hit | binary present, 3 MB, materialised on first call | ✅ |

**Caveats found during verification (now logged as R-priorities below):**
- R1: collisions between `Uuid` (Rust crate) and `Sky.Core.Uuid` (stdlib) — no syntactic distinction.
- R2: generated FFI bindings call `uuid::hyphenated` (free fn) where the real API is `uuid::Uuid::hyphenated` (method) — won't link against the real crate.
- R3: `sky add` CLI prints `"import uuid as Uuid"` (invalid syntax — module names must capitalise).
- Three obsolete cache dirs at `~/.cache/sky/tools/sky-ffi-inspect-rs-{05e3b…,1e24…,c313…}` linger from pre-Step-A builds; `cleanupOldCaches` should have removed them but didn't. Minor.

### Verification snapshot (2026-05-23 final — T/U priorities + Step 0)

End-to-end verified against HEAD (post-fix):

| Item | Expected | Actual | Status |
|---|---|---|---|
| U1: Go artifacts at `.skycache/ffi/` root | unchanged byte-for-byte | `generateBindings TargetGo` writes to `.skycache/ffi/` (root) — bit-identical | ✅ |
| U1: Rust artifacts in subdir | `.skycache/ffi/rust/{slug}.{kernel.json,skyi}` | `generateBindings TargetRust` writes to `.skycache/ffi/rust/` | ✅ |
| U1: `loadRegistry TargetGo` | reads `.skycache/ffi/*.kernel.json` (root) | unchanged behavior | ✅ |
| U1: `loadRegistry TargetRust` | reads `.skycache/ffi/rust/*.kernel.json` | subdir-scoped, legacy warning on stale flat files | ✅ |
| U1: dual-target slug safety | Go+Rust same project: both `.kernel.json` files coexist | Go at `.skycache/ffi/uuid.kernel.json`, Rust at `.skycache/ffi/rust/uuid.kernel.json` | ✅ |
| T6: CLI hint `-- slug` leak | `sky add uuid --target rust` prints `... .skycache/ffi/rust/uuid.skyi` | slug is computed from `_pkgName info` | ✅ |
| T7: Rust `.skyi` format | `module Rust.Uuid exposing (..)` with function signatures | `emitSkyi TargetRust` emits proper Sky-style module | ✅ |
| T3: Rust type sanitization | tuples→`String`, arrays→`Bytes`, `impl Trait`/`Self`→`String` | `type_str_to_sky` sanitizes before Path-types fallback | ⚠️ source-correct, deployment-pending — see [V2](#v2--inspector-source-edits-never-reach-the-bundled-binary-high) |
| T5: const-generic array | `syn::Type::Array` handled before string fallback | `type_to_sky` has early `Type::Array` case | ⚠️ source-correct, deployment-pending — see [V2](#v2--inspector-source-edits-never-reach-the-bundled-binary-high) |
| Step 0: `sky add uuid --target rust` | persists `uuid = "version"` in `[rust.dependencies]` | `appendRustDependency` writes correct TOML | ✅ |
| Step 0: `sky add URL --target rust --rev X` | persists inline table in `[rust.dependencies]` | `appendRustGitDep` writes `crate = { git = "...", rev = "X" }` | ✅ |
| Step 0: `emitCargoToml` git deps | `uuid = { git = "https://...", rev = "..." }` | `RustGitDep` emits inline table | ✅ |

## T-priorities (2026-05-23 night) — ✅ ALL RESOLVED (archival)

> **Audience: AI fix-up agent.** This section is **historical** —
> all T-priorities and U1 have been resolved. T1a/T1b (persist dep +
> mod-include) were already done by R-priorities; T2 (ok_res wrap)
> and T4 (name disambiguation) were completed alongside R2a. The
> remaining items — U1 (asymmetric layout), T3 (type sanitization),
> T5 (const-generic array), T6 (CLI text), T7 (`.skyi` format), and
> Step 0 (PkgSpec parsing) — have been implemented and verified
> (see *T/U-priorities* section below for the implementation plan).
> New work belongs in *Next steps* below.

### Reproducer (fails today against HEAD `9c0c54a8`)

```bash
rm -rf /tmp/sky-t && mkdir -p /tmp/sky-t/src
printf '[project]\nname = "t"\ntarget = "rust"\n' > /tmp/sky-t/sky.toml
cd /tmp/sky-t

# 1. Add the crate.  Inspector resolves, bindings + kernel.json get written.
<SKY> add uuid --target rust

# 2. Inspect sky.toml — empty, no [rust.dependencies] table appeared.
cat sky.toml
# Output:
#   [project]
#   name = "t"
#   target = "rust"
# Expected: a [rust.dependencies] table with `uuid = "<resolved>"`.

# 3. Try to use it from Sky source.
cat > src/Main.sky <<'EOF'
module Main exposing (main)
import Sky.Core.Prelude exposing (..)
import Rust.Uuid as U
import Std.Log exposing (println)
main =
    let _ = U.is_nil in
    println "ok"
EOF

# 4. Build.  Canonicalisation succeeds (the .kernel.json has the entry).
#    Codegen succeeds.  cargo build then fails with E0425:
#       cannot find value `uuid_is_nil` in this scope
# Root cause: sky-out/Rust/src/uuid_bindings.rs was never created
# (sky.toml has no [rust.dependencies]), and even if it had been copied,
# main.rs has no `mod uuid_bindings;` declaration to bring it in.
<SKY> build src/Main.sky --target rust 2>&1 | tail -5
ls sky-out/Rust/src/   # → no uuid_bindings.rs
```

### Findings

#### T1a. `sky add ... --target rust` doesn't persist the dependency *(CRITICAL — single biggest blocker)*

**Reproduce:** see the reproducer above. After `sky add uuid --target
rust`, `sky.toml` is unchanged.

**Root cause.** `app/Main.hs:1615-1617`:
```haskell
case target of
    TargetGo    -> appendGoDependency pkg
    TargetRust  -> return ()              -- ← no-op!
```

Plus the inspector-call path at `Main.hs:1600-1601`:
```haskell
TargetGo -> ...  -- writes go.mod, runs `go get`
TargetRust ->
    return ()                              -- ← no-op!
```

The Go branch has a working flow:
1. Read existing `sky.toml`.
2. Add or update the `[go.dependencies]` table with the new pkg.
3. Write back.

There's nothing equivalent for Rust. The `_rustDeps` field (`Toml._rustDeps`)
exists in the config schema (`src/Sky/Sky/Toml.hs`) and is read by
`src/Sky/Build/Compile.hs:1455` (`ffiSlugs`) and `:1503` (the dep loop
that does the copy), but nothing ever WRITES to it.

**Fix — package-spec parsing per the Cross-backend rules (§rule 6).**
`sky add <pkg> --target rust` must distinguish:

- **Bare name** (e.g. `uuid`, `serde_json`, `chrono`): assume
  crates.io. Run the existing inspector path (which `cargo fetch`es
  against the bare name); on success, write
  `<pkg> = "<resolved-version>"` to `[rust.dependencies]`.
- **URL** (e.g. `https://github.com/uuid-rs/uuid`,
  `git@github.com:uuid-rs/uuid.git`): assume git source. Clone the
  repo into a tempdir; read `Cargo.toml`'s `[package].name` to learn
  the crate name; record as
  `<crate-name> = { git = "<url>" }`. Optional CLI flags
  `--rev <sha>` / `--branch <name>` / `--tag <name>` add corresponding
  fields. Pass the cloned tree to the inspector for binding
  generation (skip the crates.io fetch).

Detection logic:

```haskell
data PkgSpec = CratesIo String        -- bare name → crates.io
             | GitDep String String   -- (resolved crate name, URL)
                                      -- with optional rev/branch/tag in a record

parsePkgSpec :: String -> PkgSpec
parsePkgSpec pkg
    | "https://" `isPrefixOf` pkg = GitDep (probeCrateName pkg) pkg
    | "http://"  `isPrefixOf` pkg = GitDep (probeCrateName pkg) pkg
    | "git://"   `isPrefixOf` pkg = GitDep (probeCrateName pkg) pkg
    | "ssh://"   `isPrefixOf` pkg = GitDep (probeCrateName pkg) pkg
    | "git@"     `isPrefixOf` pkg
        && (':' `elem` pkg)         = GitDep (probeCrateName pkg) pkg
    | otherwise                     = CratesIo pkg
```

Add `appendRustDependency` in `app/Main.hs`:

```haskell
appendRustDependency :: PkgSpec -> IO ()
appendRustDependency (CratesIo name) = do
    version <- resolveCratesIoVersion name   -- from inspector PkgInfo
    appendTomlDep "rust.dependencies" name (TomlString version)

appendRustDependency (GitDep crateName url) = do
    let body = TomlInlineTable [("git", TomlString url)]
    appendTomlDep "rust.dependencies" crateName body
```

Wire it up:

```haskell
-- Main.hs around line 1615:
case target of
    TargetGo    -> appendGoDependency pkg
    TargetRust  -> appendRustDependency (parsePkgSpec pkg)
```

Cargo.toml emission (`RustBuilder.emitCargoToml`) must accept both
shapes:
```toml
[dependencies]
uuid = "1.10.0"
uuid_rs = { git = "https://github.com/uuid-rs/uuid" }
```

The first is already supported; the second needs the inline-table
case added when the parsed `_rustDeps` entry carries a git URL.

**Acceptance.** After `sky add uuid --target rust`:
```toml
[project]
name = "t"
target = "rust"

[rust.dependencies]
uuid = "1.10.0"
```

After `sky add https://github.com/uuid-rs/uuid --target rust`:
```toml
[project]
name = "t"
target = "rust"

[rust.dependencies]
uuid = { git = "https://github.com/uuid-rs/uuid" }
```

(And the resulting `sky-out/Rust/Cargo.toml` carries the same shapes.)

**Acceptance (legacy, retained):** After `sky add uuid --target rust`,
`cat sky.toml` shows:
```toml
[project]
name = "t"
target = "rust"

[rust.dependencies]
uuid = "1.10.0"
```

#### T1b. Codegen doesn't emit `mod <slug>_bindings;` declarations *(CRITICAL — pairs with T1a)*

Even with T1a landed, the binding `.rs` would be copied (`Compile.hs:1508-1515`)
but `main.rs` doesn't declare the module.

**Root cause.** Look at the Rust-target Compile.hs branch:
```haskell
-- Compile.hs:1495 (the writeFile mainRustPath rustCode)
writeFile mainRustPath rustCode   -- ← rustCode comes from generateRust
                                  --   and contains no `mod uuid_bindings;`
```

`generateRust` (which calls into `RustBuilder`) doesn't know about
FFI binding modules. It needs to be threaded the list of FFI deps so
it can emit:
```rust
mod uuid_bindings;
use uuid_bindings::*;
```

at the top of `main.rs`, alongside the existing
`mod sky_runtime; use sky_runtime::*;` block.

**Fix.** Two parts:

1. Pass `ffiSlugs` (already computed in `Compile.hs:1453-1455`) through
   to `RustBuilder.emitRust` / `generateRust`.
2. In `RustBuilder.emitRust`, prepend `mod <slug>_bindings; use
   <slug>_bindings::*;` for each slug to the generated `main.rs`
   contents.

**Acceptance.** After T1a + T1b:
- `sky add uuid --target rust && sky build src/Main.sky --target rust`
  on the reproducer above builds AND runs (printing "ok") with no
  cargo errors.
- `grep "mod uuid_bindings" sky-out/Rust/src/main.rs` returns a hit.
- `ls sky-out/Rust/src/` includes `uuid_bindings.rs`.

#### T2. Wrapper bodies don't wrap their return values in `SkyResult` *(HIGH)*

(Same diagnosis as the earlier T2 — still valid.) Pure-effect
wrappers in `.skycache/rust/uuid_bindings.rs`:

```rust
pub fn uuid_is_nil(arg0: uuid::Uuid) -> SkyResult<SkyError, bool> {
    arg0.is_nil()                  // returns bool, signature expects SkyResult<…, bool>
}
```

E0308 the moment T1a+T1b unblock the call site.

**Fix in `src/Sky/Build/FfiGen.hs:emitRustFnSimple`:**

```haskell
body = let call = ...   -- existing callExpr from R2a
       in case _fnEffect fn of
            "effectful" ->
                "Box::pin(async move { ok_res(" ++ call ++ ".await) })"
            "fallible" ->
                "match " ++ call ++ " { Ok(v) => ok_res(v), Err(e) => SkyResult::Err(str_err(&format!(\"{:?}\", e))) }"
            _ ->  -- pure
                "ok_res(" ++ call ++ ")"
```

#### T3. Rust type syntax leaks into `.kernel.json`'s `skyType` field *(HIGH)*

`/tmp/sky-r/.skycache/ffi/uuid.kernel.json` contains:
```
{"name": "as_fields", "arity": 1, "skyType": "Uuid -> Result Error (u32,u16,u16,&[u8 ; 8])"}
{"name": "as_u128",   "arity": 1, "skyType": "Uuid -> Result Error u128"}
{"name": "as_bytes",  "arity": 1, "skyType": "Uuid -> Result Error ([u8 ; 16])"}
{"name": "now",       "arity": 1, "skyType": "impl ClockSequence -> Result Error Self"}
```

Sky's type-string parser (`FfiTy.ftyToAnnotation`) chokes on:
- Bare Rust tuples `(u32,u16,u16,&[u8 ; 8])` — Sky doesn't have
  fixed-size tuples in type strings.
- Rust array syntax `[u8 ; 16]` — Sky doesn't have fixed-size arrays.
- Reference types `&[u8]` — Sky has no `&` in types.
- Unsized primitives `u128` — Sky's `Int` is 64-bit.
- Trait-object `impl ClockSequence` — Sky has no traits.
- Method-receiver `Self` — fine in trait context, but not as a Sky type.

When `loadAndSeedFfiRegistry` decodes these `skyType` strings, the
ones that fail to parse get `_ffn_skyType = Nothing` and fall back
to "no Sky type known" (per `Compile.hs:347-354` comments). That's
*tolerable* — the canonicaliser still registers the function with
no specific type — but means the user's call site is polymorphic-any
on the Sky side.

**Fix tier 1 (immediate):** in the inspector's `type_to_sky` (or in
FfiGen's post-processing), replace unrepresentable Rust syntax with
`String` (lossy but parseable). Concretely add to
`tools/sky-ffi-inspect-rs/src/main.rs`:

```rust
fn rust_type_to_sky_safe(s: &str) -> String {
    // After existing type_to_sky returns, sanitise:
    if s.contains('(') && !s.starts_with("Result ") && !s.starts_with("Maybe ") {
        return "String".to_string();  // bare tuple — opaque
    }
    if s.contains('[') { return "Bytes".to_string(); }
    if s.starts_with("impl ") || s.starts_with("&") { return "String".to_string(); }
    if s == "u128" || s == "Self" { return "String".to_string(); }
    s.to_string()
}
```

Call it as the last step in `type_to_sky`.

**Fix tier 2 (proper):** map opaque Rust types to a dedicated
Sky-side newtype `RustOpaque <crate-path>`. Defer.

#### T4. Duplicate FFI function names from cross-type method overloads *(HIGH)*

Look at `.kernel.json` — `as_uuid` appears 4× (Hyphenated, Braced,
Simple, Urn), `from_uuid` similar. `loadAndSeedFfiRegistry` builds a
map keyed by `(kernelName, funcName)` — duplicate keys silently
collapse (last writer wins). The wrapper `.rs` file has 4×
`pub fn uuid_as_uuid(...)` definitions which would fail E0428.

**Fix.** Disambiguate by receiver type at emission time. In both
`emitRustFnSimple` (for the `.rs`) and `emitKernelJson` (for the
`.kernel.json`'s `functions` array), suffix the function name with
the lower-snake-cased receiver type when `_fnRecvType` is non-empty:

```haskell
disambiguatedName fn =
    let base = lowerFirst (_fnName fn)
    in if null (_fnRecvType fn)
       then base
       else base ++ "_from_" ++ toSnakeCase (_fnRecvType fn)
```

Yields `as_uuid_from_hyphenated`, `as_uuid_from_braced`, etc. Same
name in the `.kernel.json` so the canonicaliser sees no duplicates
either.

#### T5. Const-generic array length parse failure *(MEDIUM)*

`.kernel.json` has `"name": "encode_buffer", "skyType": "() -> Result Error LENGTH]"`
— the `[` was dropped during the inspector's `type_to_sky` walk over
`syn::Type::Array`'s const-generic length expression.

**Fix in `tools/sky-ffi-inspect-rs/src/main.rs:type_to_sky`:**
add a proper case for `syn::Type::Array`:
```rust
syn::Type::Array(arr) => {
    let elem = type_to_sky(&arr.elem, aliases);
    let len = quote::quote! { #arr.len }.to_string();
    format!("[{}; {}]", elem, len)
}
```
Then T3's tier-1 sanitisation maps the well-formed `[u8; ENCODE_LENGTH]`
to `Bytes`.

#### T6. CLI hint `-- slug` template leak *(LOW, cosmetic)*

`app/Main.hs:1627`:
```haskell
"Then call any of the " ++ show (length names) ++ " functions"
++ " (see .skycache/ffi/ -- slug " ++ pkg ++ ".skyi for signatures)."
```

`" -- slug "` is literal text where a slug substitution was intended.
Drop the `-- slug` and use the slug variable in scope. Two-char fix.

#### T7. `.skyi` files are Go-shaped (used by LSP only) *(LOW)*

`.skycache/ffi/<slug>.skyi` written by the Rust path uses `package <name>`
instead of `module Rust.<Name> exposing (...)`, and emits function
signatures as line comments. **The canonicaliser ignores this file**
(it uses `.kernel.json`), so this doesn't break builds — but the
LSP indexer (`src/Sky/Lsp/Index.hs:744-757`) reads `.skyi` for hover
info and falls back gracefully when parsing fails. Affects IDE
ergonomics only.

**Fix.** Update `emitSkyi` in `src/Sky/Build/FfiGen.hs` to take
`CompileTarget` and emit:
```
module Rust.Uuid exposing (..)

is_nil : Uuid -> Result Error Bool
hyphenated : Uuid -> Result Error Hyphenated
...
```

Land after T1a+T1b+T2+T3+T4 — this is purely an IDE quality-of-life
fix.

#### U1. Slug collision between Go and Rust `sky add`s *(HIGH — same-project hazard, especially during target migration)*

`src/Sky/Build/FfiGen.hs:slugify` produces the same slug for any pkg
with the same last-path-segment / crate name:

```haskell
slugify = map (\c -> if c `elem` ("./" :: String) then '_' else c)
```

So `sky add github.com/google/uuid` (Go) and `sky add uuid --target rust`
both produce slug `uuid` and both write to:
- `.skycache/ffi/uuid.kernel.json`
- `.skycache/ffi/uuid.skyi`

The second `sky add` silently clobbers the first's `.kernel.json`.
The previously-active target's `import` lookups break with no
warning. Common-case trigger: a user converts a Go project to Rust by
changing `target = "go"` to `target = "rust"` in `sky.toml` and
re-adding deps; old Go bindings sit in `.skycache/ffi/` and either
linger as stale entries or get overwritten by the new Rust adds.

**Fix — asymmetric layout per the Cross-backend rules (§rule 1+2).**
Go is the production backend and keeps the canonical
`.skycache/ffi/<slug>.{kernel.json,skyi}` paths. Rust (and any future
non-Go backend) lives in a named subdirectory:

```
.skycache/
  ffi/
    uuid.kernel.json         ← Go (Github.Com.Google.Uuid)  [unchanged]
    uuid.skyi
    rust/
      uuid.kernel.json       ← Rust.Uuid                    [new]
      uuid.skyi
    wasm/                    ← future, by convention
```

**This is asymmetric on purpose.** Existing Go projects in this repo,
in forks, and in the wild already write to `.skycache/ffi/<slug>.…`
and would break under a symmetric layout. Per Cross-backend rule 4
(*Never touch Go-generated files*), the Go path is bit-identical;
only the new Rust path picks the subdir.

**Code changes.**

1. **`src/Sky/Build/FfiGen.hs:generateBindings`** —
   `TargetGo` continues to write to `.skycache/ffi/<slug>.…` (no
   change). `TargetRust` writes to `.skycache/ffi/rust/<slug>.…`:
   ```haskell
   generateBindings TargetGo pkg = do
       createDirectoryIfMissing True ".skycache/ffi"     -- unchanged
       createDirectoryIfMissing True ".skycache/go"      -- unchanged
       let slug = slugify (_pkgName pkg)
           skyiFile = ".skycache/ffi" </> (slug ++ ".skyi")
           jsonFile = ".skycache/ffi" </> (slug ++ ".kernel.json")
       ...                                                -- existing flow

   generateBindings TargetRust pkg = do
       createDirectoryIfMissing True ".skycache/ffi/rust"
       createDirectoryIfMissing True ".skycache/rust"
       let slug = slugify (_pkgName pkg)
           skyiFile = ".skycache/ffi/rust" </> (slug ++ ".skyi")
           jsonFile = ".skycache/ffi/rust" </> (slug ++ ".kernel.json")
       ...
   ```

2. **`src/Sky/Build/FfiRegistry.hs:loadRegistry`** — take a
   `CompileTarget` argument; read only the active target's path:
   ```haskell
   loadRegistry :: CompileTarget -> IO FfiRegistry
   loadRegistry TargetGo = loadFromDir ".skycache/ffi"          -- glob *.kernel.json
   loadRegistry TargetRust = loadFromDir ".skycache/ffi/rust"   -- glob *.kernel.json
   ```
   `loadFromDir` is the existing glob+decode body, just parameterised
   on a path. The `TargetGo` path is **bit-identical** to today's
   behavior (Cross-backend rule 5).

3. **`src/Sky/Build/Compile.hs:loadAndSeedFfiRegistry`** — take a
   `CompileTarget` and pass it through. Single call site at
   `Compile.hs:465` is inside `continueCompile` where
   `Toml._target config` is already available. The Go default
   continues to read the root `.skycache/ffi/`; Rust reads the new
   subdir.

**Migration / backward-compat (Rust-side only — Go path untouched).**

When `loadRegistry TargetRust` runs and finds `.skycache/ffi/rust/`
empty BUT spots stale flat `Rust_*` kernel.json files at the root
(from pre-fix Rust-target adds), print a one-line warning:
*"legacy Rust FFI cache layout detected at .skycache/ffi/<slug>.kernel.json;
re-run `sky install` or `sky add <pkg> --target rust` to migrate"*
and treat the cache as empty. Do **not** touch those legacy files —
the user can `git clean` them or just re-add. Auto-migration is
explicitly out of scope to avoid touching anything that might be Go
output sharing the same dir.

**Less-invasive alternative (NOT recommended).** Filename prefix —
`.skycache/ffi/rust_uuid.kernel.json` (Go stays as `.skycache/ffi/uuid.kernel.json`).
Avoids the new subdir but mixes targets in one listing, making the
"glob only Rust entries" check brittle. Subdir is cleaner per the
Cross-backend rules.

**Acceptance for U1.**
- Running `sky add github.com/google/uuid` (Go target) followed by
  changing `sky.toml` to `target = "rust"` and running
  `sky add uuid --target rust` in the same project: **both bindings
  preserved on disk**. `ls .skycache/ffi/uuid.kernel.json
  .skycache/ffi/rust/uuid.kernel.json` shows both files.
- For a `target = "rust"` build, `loadAndSeedFfiRegistry` reads only
  `.skycache/ffi/rust/*.kernel.json`. The legacy root `.skycache/ffi/uuid.kernel.json`
  (Go) is ignored — Sky imports of `Github.Com.Google.Uuid` are
  unresolvable, which is correct (you're building for Rust).
- For a `target = "go"` build, `loadAndSeedFfiRegistry` reads only
  `.skycache/ffi/*.kernel.json` at the root (same as today). The
  `.skycache/ffi/rust/` subdir is ignored. **Identical behavior to
  the pre-fix Go path.**
- A regression test that compares the Go-side `.kernel.json` byte-by-byte
  to a fixture from before the U1 fix lands proves rule 4 (do not
  touch Go-generated files).

### Priorities (in order)

| Rank | Issue | Effort | Why |
|---|---|---|---|
| 0 | **`PkgSpec`** parsing (Step 0 — bare name vs URL for `sky add`) | <1 day | Cross-backend rule 6 prerequisite for T1a. Tiny but blocks Step 1. |
| 1 | **T1a** + **T1b** (persist Rust dep + mod-include in main.rs) | 2-3 days | Single biggest unblocker. Without this, **no Rust FFI binding is callable from Sky source**. Mirror `appendGoDependency`; coordination across `app/Main.hs` + `Compile.hs` + `RustBuilder.emitRust`. |
| 2 | **U1** (asymmetric layout: Go at root, Rust at `.skycache/ffi/rust/`) | 1 day | Affects any project that touches both Go and Rust FFI, including target migrations. Cross-backend rule 1 + 4. Land alongside T1a/b. Includes a regression test that diffs the Go-side `.kernel.json` byte-for-byte against a pre-fix fixture (rule 5). |
| 3 | **T2** (wrapper body `ok_res` wrap) | <1 day | Once T1a+T1b unblock, T2 fires on every call. Trivial change. |
| 4 | **T4** (duplicate function names) | <1 day | Without dedup, the `uuid` binding's wrapper `.rs` has 12+ duplicate definitions (E0428). Share helper with T2 in `emitRustFnSimple`. |
| 5 | **T3** (Rust type syntax in `skyType`) | 1-2 days | Cosmetic until T1a-T4 land. Tier-1 fix (sanitise to `String`/`Bytes`) is small. |
| 6 | **T5** (const-generic array parse fix in inspector) | <1 day | Tiny inspector change. |
| 7 | **T6** (`-- slug` CLI text) | <1 hour | Two-character fix. |
| 8 | **T7** (`.skyi` Sky-style emission for LSP) | 1 day | Pure IDE quality-of-life. Defer until everything else lands. |

### Implementation plan

Each step ends with `cargo check` + `cargo clippy --all-targets -- -D
warnings` clean on the runtime, `cabal build exe:sky` clean, all 6
existing examples + Q-reproducers + T-reproducer building + running
clean.

#### Step 1 — T1a + T1b — persist Rust dep + `mod`-include in main.rs (PRIORITY 1)

1.1. **`app/Main.hs`: add `appendRustDependency`.** Mirror
`appendGoDependency` (around line 624). Write into a
`[rust.dependencies]` table in `sky.toml`. The version string comes
from the inspector's resolved Cargo.lock (the Rust inspector should
already capture this — verify, add if not).

1.2. **`app/Main.hs:1617`: wire it up.** Replace
`TargetRust -> return ()` with
`TargetRust -> appendRustDependency pkg (inspectorVersion info)`.

1.3. **`src/Sky/Sky/Toml.hs`: verify `[rust.dependencies]` parser.**
The `_rustDeps` field is read elsewhere; confirm the TOML parser
accepts adding entries to this table. Add a smoke test for the parser
round-trip.

1.4. **`src/Sky/Generate/Rust/Builder.hs:emitRust` (or wherever
`main.rs` content is assembled):** prepend
`mod <slug>_bindings; use <slug>_bindings::*;` for each `ffiSlug`. The
slugs are already passed through from `Compile.hs:1469`'s
`generateRust ... ffiSlugs ...` call; thread them into `emitRust` and
into the main.rs preamble assembly.

1.5. **Regression test.** Use the T-reproducer above as a new cabal
spec or `examples/26-rust-ffi/`.

#### Step 2 — U1 — asymmetric layout: Go stays at root, Rust moves to `.skycache/ffi/rust/`

> **Rule reminder:** Cross-backend rule 1 (Go at root) + rule 4
> (never touch Go-generated files). The `TargetGo` paths in this
> step are intentionally unchanged.

2.1. **`src/Sky/Build/FfiGen.hs:generateBindings`:**
- `TargetGo` branch — **do not touch.** Still writes
  `.skycache/ffi/<slug>.{kernel.json,skyi}` and
  `.skycache/go/<slug>_bindings.go`. Bit-identical output.
- `TargetRust` branch — change to write
  `.skycache/ffi/rust/<slug>.{kernel.json,skyi}` (plus
  `.skycache/rust/<slug>_bindings.rs` as today).
- Update `createDirectoryIfMissing True ".skycache/ffi/rust"` in the
  Rust branch.

2.2. **`src/Sky/Build/FfiRegistry.hs:loadRegistry`:** take
`CompileTarget`, glob the target-appropriate path:
- `TargetGo`: `.skycache/ffi/*.kernel.json` (root — unchanged
  behavior).
- `TargetRust`: `.skycache/ffi/rust/*.kernel.json`.

The internal `loadFromDir`/decode logic is shared between both targets;
only the path differs. Do not introduce target-specific schema
divergence — the `.kernel.json` shape stays the same.

2.3. **Rust-side legacy warning.** When `loadRegistry TargetRust`
finds `.skycache/ffi/rust/` empty/missing but spots a `Rust_*`
prefixed `kernel.json` at `.skycache/ffi/` (root), print:
*"legacy Rust FFI cache layout detected at .skycache/ffi/<slug>.kernel.json;
re-run `sky install` or re-add the dep — file ignored"* and continue.
**Do not auto-move** the file (root files may be Go's — never assume).
The user can `git clean` or re-add. No equivalent warning on the Go
path; Go's behavior is unchanged.

2.4. **`Compile.hs:328-344` (`loadAndSeedFfiRegistry`):** take
`CompileTarget`, pass to `loadRegistry`. Default callers (e.g.
`Compile.hs:2311`) preserve `TargetGo` semantics. The single
in-`continueCompile` call site (`Compile.hs:465`) has `Toml._target
config` in scope.

2.5. **Cross-backend rule 5 regression test.** Add a Cabal spec that
generates the Go-target FFI artefacts for a known fixture
(`github.com/google/uuid` or similar) twice — once on `main` and once
after the U1 patch — and diffs the resulting
`.skycache/ffi/uuid.kernel.json` byte-for-byte. **Identical** is the
acceptance criterion. Wire into CI so any future change that touches
the Go path's FFI artefacts trips immediately.

#### Step 0 — `sky add` package-spec parsing (URL vs crate name)

Land **before or alongside** Step 1 (T1a) — Step 1's
`appendRustDependency` calls into the parsed spec.

0.1. **`app/Main.hs`: add `PkgSpec` + `parsePkgSpec`** per the sketch
in §Findings T1a. Place near `appendGoDependency` for visibility.

0.2. **URL detection.** A pkg argument is a URL iff it matches:
- `https?://...`
- `git://...`
- `ssh://...`
- `git@<host>:<owner>/<repo>` (note the `:` after host, not `/`)

Anything else is a bare name (crates.io for `--target rust`, Go module
path for `--target go`).

0.3. **Optional CLI flags for git deps.** Accept `--rev <sha>`,
`--branch <name>`, `--tag <name>`. Emit at most one into the
inline-table; reject combinations (`--rev` + `--branch` → error).

0.4. **Crate-name resolution for git URLs.** Clone into a tempdir
(reuse `EmbeddedInspectorRust`'s tempdir infra if convenient), read
`Cargo.toml`'s `[package].name`. Pass the cloned tree to the
inspector via a new `--source <path>` flag (or by setting `CARGO_HOME`
appropriately) instead of letting the inspector run `cargo fetch`
against crates.io. The resulting `PkgInfo` is identical in shape.

0.5. **Go-target safety.** Cross-backend rule 5: do **not** touch the
`TargetGo` branch of `sky add`. URL detection is target-blind only
to the extent that the same regex parses both forms — but the
**handler** for each target is still `case target of` separated, and
the Go branch invokes the existing `go get` path (URL or not). No
shared dependency on `parsePkgSpec`'s `GitDep` constructor outside
the Rust branch.

0.6. **`src/Sky/Sky/Toml.hs`:** verify `_rustDeps` can carry
`{ git = "<url>" }` inline-table values, not just string versions.
Existing parsing reads strings (e.g. `uuid = "1.10"`); extend the
decoder to accept inline tables and represent them as
`(String, RustDepSpec)` where `RustDepSpec = Version String | Git
{...}`. Update `RustBuilder.emitCargoToml` to handle both shapes.

0.7. **`RustBuilder.emitCargoToml`:** for each `_rustDeps` entry,
emit either `<name> = "<version>"` or `<name> = { git = "<url>", ... }`
based on the parsed spec. Path-deps (`path = "..."`) defer to a
follow-up.

#### Step 3 — T2 — wrap pure/fallible bodies in `ok_res`

`src/Sky/Build/FfiGen.hs:emitRustFnSimple` body builder, per the
sketch in §Findings T2.

#### Step 4 — T4 — disambiguate function names by receiver type

`src/Sky/Build/FfiGen.hs:emitRustFnSimple` and `emitKernelJson`.
Compute `disambiguatedName fn = base ++ "_from_" ++ toSnakeCase recv`
when receiver is non-empty.

#### Step 5 — T3 — sanitise unrepresentable Rust types

`tools/sky-ffi-inspect-rs/src/main.rs`: add `rust_type_to_sky_safe`
post-processing. See §Findings T3 sketch.

#### Step 6 — T5 — const-generic array fix in inspector

`tools/sky-ffi-inspect-rs/src/main.rs:type_to_sky`: add the
`syn::Type::Array` case.

#### Step 7 — T6 — fix CLI `-- slug` text

`app/Main.hs:1627`: replace `" -- slug "` with `slug` substitution.

#### Step 8 — T7 — emit proper Sky-shape `.skyi`

`src/Sky/Build/FfiGen.hs:emitSkyi`: take target, emit
`module Rust.<Name> exposing (..)` with real signature declarations.

### Verification

```bash
# Runtime sanity (no regressions)
(cd runtime-rust && cargo check && cargo clippy --all-targets -- -D warnings && cargo test)

# Compiler sanity
cabal build exe:sky
cabal test

# All 6 examples + Q-reproducers still green
for ex in 01-hello-world 04-local-pkg 07-todo-cli 14-task-demo simple test_pkg; do
    (cd examples/$ex && rm -rf sky-out .skycache .skydeps \
     && ../../sky-out/sky build src/Main.sky --target rust \
     && cargo build --manifest-path sky-out/Rust/Cargo.toml) || echo "FAIL: $ex"
done

# T-reproducer acceptance — the whole point of T1a+T1b
rm -rf /tmp/sky-t && mkdir -p /tmp/sky-t/src
printf '[project]\nname = "t"\ntarget = "rust"\n' > /tmp/sky-t/sky.toml
cd /tmp/sky-t
/home/arthur/Documentos/comp/sky/sky-out/sky add uuid --target rust

# T1a: sky.toml now has [rust.dependencies]
grep -q '^\[rust.dependencies\]' sky.toml && echo "✅ T1a: sky.toml has [rust.dependencies]" \
                                          || echo "FAIL: T1a — sky.toml unchanged"

# U1: target-scoped subdir
test -f .skycache/ffi/rust/uuid.kernel.json && echo "✅ U1: target-scoped path" \
                                            || echo "FAIL: U1 — flat .skycache/ffi/ layout"

cat > src/Main.sky <<'EOF'
module Main exposing (main)
import Sky.Core.Prelude exposing (..)
import Rust.Uuid as U
import Std.Log exposing (println)
main =
    let _ = U.is_nil in
    println "ok"
EOF
/home/arthur/Documentos/comp/sky/sky-out/sky build src/Main.sky --target rust

# T1b: main.rs declares the binding module
grep -q "mod uuid_bindings" sky-out/Rust/src/main.rs && echo "✅ T1b: mod uuid_bindings injected" \
                                                     || echo "FAIL: T1b — main.rs missing mod"

# End-to-end
./sky-out/Rust/target/debug/sky-app | grep -q "^ok$" && echo "✅ T-priorities verified end-to-end"

# U1: dual-target slug-collision regression (Go stays at root; Rust goes to subdir)
cd /tmp && rm -rf /tmp/sky-u1 && mkdir -p /tmp/sky-u1/src
printf '[project]\nname = "u1"\ntarget = "go"\n' > /tmp/sky-u1/sky.toml
cd /tmp/sky-u1
/home/arthur/Documentos/comp/sky/sky-out/sky add github.com/google/uuid
# Now switch to Rust target and re-add as a Rust crate.
sed -i 's/target = "go"/target = "rust"/' sky.toml
/home/arthur/Documentos/comp/sky/sky-out/sky add uuid --target rust
test -f .skycache/ffi/uuid.kernel.json      && echo "✅ U1: Go binding preserved at root"   || echo "FAIL: U1 — Go kernel.json missing or moved"
test -f .skycache/ffi/rust/uuid.kernel.json && echo "✅ U1: Rust binding in subdir"        || echo "FAIL: U1 — Rust kernel.json missing"

# PkgSpec — URL form for Rust git dep
cd /tmp && rm -rf /tmp/sky-step0 && mkdir -p /tmp/sky-step0/src
printf '[project]\nname = "s0"\ntarget = "rust"\n' > /tmp/sky-step0/sky.toml
cd /tmp/sky-step0
/home/arthur/Documentos/comp/sky/sky-out/sky add https://github.com/uuid-rs/uuid --target rust
grep -qE '^\s*uuid\s*=\s*\{\s*git\s*=' sky.toml \
    && echo "✅ Step 0: git dep emitted as inline table" \
    || echo "FAIL: Step 0 — git URL not recorded as { git = … }"

# Cross-backend rule 5 regression: Go kernel.json must be byte-identical pre/post-fix.
# (See Step 2.5; harness should diff against a fixture checked into tests/fixtures/.)
```

### What's sure vs unsure

**Sure (HIGH, verified by `cargo build` + reading source):**
- T1a: `sky add ... --target rust` doesn't touch `sky.toml`. Verified
  by `cat sky.toml` post-add.
- T1b: `main.rs` has no `mod uuid_bindings;` and `sky-out/Rust/src/`
  has no `uuid_bindings.rs`. Verified.
- T2-T6: all directly readable in source or reproducer artifacts.
- U1: `slugify` definition + identical `_pkgName` field for both
  ecosystems. Code trace confirmed.

**Reasonably sure (MEDIUM):**
- T7's "LSP-only" claim — `src/Sky/Lsp/Index.hs:744-757` reads `.skyi`;
  no other reader found by `grep -rnE '\.skyi'`. But there might be a
  reader I missed.

**Out of scope for T+U-priorities:**
- Sky.Live / Sky.Tui / Std.Auth ports — Phase 3/4 of the strategic plan.
- Cross-target dual-builds (compiling the same Sky source for both Go
  and Rust). U1 unblocks the FFI cache; the rest of the build pipeline
  has its own assumptions.
- WASM target — Phase 5.

## V-priorities (2026-05-24) — bugs revealed by end-to-end verification of commit `997b29b1`

> **Audience: AI fix-up agent.** After the T/U + Step 0 commit landed,
> an end-to-end run against a freshly-rebuilt `sky-out/sky` exposed
> three real bugs the agent's source-only review missed, plus one
> build-pipeline fragility that hid one of them. **All four must be
> fixed before any further "Rust FFI works" claim.**
>
> Cross-backend rules (top of this file, §"Cross-backend rules") apply
> in full. In particular: V4 enforces rule 5 (Go-side byte-identity)
> with a checked-in fixture; rules 1–4 still hold byte-for-byte on
> `.skycache/ffi/` root.

### V1. `sky add <URL> --target rust` silently swallows the dep (CRITICAL)

**Reproducer (fails today against HEAD `997b29b1`):**

```bash
rm -rf /tmp/v1 && mkdir /tmp/v1 && cd /tmp/v1
<SKY> init t && cd t
<SKY> add https://github.com/uuid-rs/uuid --target rust
# Output:
#   Adding https://github.com/uuid-rs/uuid...
#   sky: sky.toml: withFile: resource busy (file is locked)
grep rust sky.toml          # ← nothing was written
```

**Root cause — lazy `readFile` + `--target` short-circuit.** In
`app/Main.hs:763-770`:

```haskell
config <- if hasToml
    then Toml.parseSkyToml <$> readFile "sky.toml"   -- lazy IO
    else return Toml.defaultConfig
let target = case mTarget of
    Just t  -> parseTarget t                         -- _target field
                                                     -- NEVER accessed
                                                     -- → thunk held
    Nothing -> Toml._target config
```

When `--target rust` is passed, `Toml._target config` is never
evaluated. The lazy thunk holding `sky.toml`'s read handle stays
live. `appendRustGitDep` then opens `sky.toml` for write → OS lock
conflict → `"resource busy (file is locked)"`. The dep is silently
dropped.

The bare-name path (`sky add uuid --target rust`) accidentally
sidesteps this because the intervening inspector subprocess
(~600 ms) gives GHC time to GC the thunk; the URL branch returns
synchronously so the thunk is still live when the write fires.

**Fix — strict read.**

```haskell
config <- if hasToml
    then do
        content <- readFile "sky.toml"
        length content `seq` return (Toml.parseSkyToml content)
        -- or with base >= 4.15: readFile' "sky.toml"
        -- or: BS.readFile "sky.toml" >>= …
    else return Toml.defaultConfig
```

The pattern matches existing `appendRustGitDep` / `appendRustDependency`
which already use `length content `seq` return ()` for the same
reason.

**Acceptance.** The reproducer above must end with the line
`grep -E '^\s*"?uuid"?\s*=' sky.toml` printing the git-dep line and
zero `withFile: resource busy` output.

### V2. Inspector source edits never reach the bundled binary (HIGH)

The agent's T3 (type sanitisation) and T5 (const-generic array)
patches to `tools/sky-ffi-inspect-rs/src/main.rs` are correctly
implemented — but **they never reach end-users**. Real `sky add uuid
--target rust` against HEAD produces a `kernel.json` where **27 of 48
functions** still carry leaky Rust syntax:

```
$ python3 -c "
import json
d = json.load(open('.skycache/ffi/rust/uuid.kernel.json'))
bad = [f['name'] for f in d['functions']
       if any(x in f.get('skyType','')
              for x in ['Self','u128','i128','impl ','LENGTH'])]
print('Functions with leaky Rust syntax:', len(bad), '/', len(d['functions']))
"
Functions with leaky Rust syntax: 27 / 48
```

Categories of leakage (current output):

| Pattern | Count | Examples |
|---|---|---|
| `Self`            | 9 | `from_uuid : Uuid -> Result Error Self` |
| `u128`            | 2 | `as_u128 : Uuid -> Result Error u128` |
| `impl <Trait>`    | 2 | `now : impl ClockSequence -> Result Error Self` |
| `(T, U, …)` tuple | 6 | `to_gregorian : Timestamp -> Result Error (u64,u16)` |
| `[u8; N]` array   | 8 | `as_bytes : Uuid -> Result Error ([u8 ; 16])` |
| `LENGTH]` parse   | 1 | `encode_buffer : () -> Result Error LENGTH]` |

**Root cause — TH embeds a pre-built binary, never auto-rebuilds.**
`src/Sky/Build/EmbeddedInspectorRust.hs:47-65`:

```haskell
if binExists                 -- target/release/sky-ffi-inspect-rs exists?
    then [| [("sky-ffi-inspect-rs", $(return bsExp))] |]
                              -- ↑ embed the PRE-BUILT binary
    else EmbedDir.embedDirFiltered "tools/sky-ffi-inspect-rs" ["target"]
                              -- ↑ embed SOURCE (registered as deps via qAddDependentFile)
```

The first branch fires whenever the agent has previously run
`cargo build --release` in `tools/sky-ffi-inspect-rs/`. After that,
**no edit to the source tree ever invalidates the TH splice** —
`qAddDependentFile` is called on the binary, not the sources, so
later `src/main.rs` changes don't even recompile the
`EmbeddedInspectorRust` Haskell module. The agent's T3/T5 fixes sit
in the source tree, are not in the pre-built binary, and the sky
binary embeds the stale pre-built binary.

This is the root cause of why T3/T5 read "✅" in the verification
snapshot at the code level but fail in practice.

**Fix — two-line guard in the TH splice.**

```haskell
embeddedInspectorRustBytes = $(do
    let binaryPath = "tools/sky-ffi-inspect-rs/target/release/sky-ffi-inspect-rs"
    binExists <- runIO $ doesFileExist binaryPath
    -- NEW: if any src/*.rs is newer than the pre-built binary,
    -- fall through to the source-tree embed so qAddDependentFile
    -- registers the .rs files as TH dependencies.
    binFresh <- if binExists
        then runIO $ do
            binMtime <- getModificationTime binaryPath
            srcs <- listDirectoryRecursive "tools/sky-ffi-inspect-rs/src"
            mtimes <- mapM getModificationTime srcs
            return (all (<= binMtime) mtimes)
        else return False
    if binFresh
        then do
            qAddDependentFile binaryPath
            ...embedFile...
        else do
            -- source-tree path; qAddDependentFile fires per file
            EmbedDir.embedDirFiltered "tools/sky-ffi-inspect-rs" ["target"]
    )
```

Side benefit: contributors who edit the inspector no longer have to
remember to wipe `target/` first. Release-tarball builds that ship a
pre-built binary still work — the binary's mtime is post-source by
construction.

**Acceptance.**

```bash
# 1. Touch the inspector source, rebuild sky
touch tools/sky-ffi-inspect-rs/src/main.rs
cabal install --overwrite-policy=always --installdir=./sky-out \
    --install-method=copy exe:sky
# `Sky.Build.EmbeddedInspectorRust` must recompile — visible in
# the cabal output.

# 2. End-to-end verify leaky-syntax count is 0
rm -rf /tmp/v2 && mkdir /tmp/v2 && cd /tmp/v2
<SKY> init t && cd t && echo 'target = "rust"' >> sky.toml
<SKY> add uuid
python3 -c "
import json
d = json.load(open('.skycache/ffi/rust/uuid.kernel.json'))
bad = [f['name'] for f in d['functions']
       if any(x in f.get('skyType','')
              for x in ['Self','u128','i128','impl ','LENGTH'])]
assert len(bad) == 0, f'still leaky: {bad}'
print('V2 passes — 0 leaky signatures across', len(d['functions']), 'fns')
"
```

### V3. `cabal install` fails cryptically when `target/release/` is absent (MEDIUM)

**Reproducer.**

```bash
rm -rf tools/sky-ffi-inspect-rs/target
cabal install --overwrite-policy=always --installdir=./sky-out \
    --install-method=copy exe:sky
# Result:
#   src/Sky/Build/EmbeddedInspectorRust.hs:47:30: error: [GHC-87897]
#     • Exception when trying to run compile-time code:
#         tools/sky-ffi-inspect-rs:
#         getDirectoryContents:openDirStream: does not exist
```

`cabal build` succeeds (uses the in-tree files); `cabal install`
fails because its sdist phase strips files not declared in
`extra-source-files`. The Rust inspector's source tree is not
declared:

```
sky-compiler.cabal:43-45  (Go inspector — listed)
    tools/sky-ffi-inspect/main.go
    tools/sky-ffi-inspect/go.mod
    tools/sky-ffi-inspect/go.sum
    -- ↓ Rust inspector NOT listed — invisible to sdist
```

**Fix.** Extend `extra-source-files`:

```
    tools/sky-ffi-inspect-rs/Cargo.toml
    tools/sky-ffi-inspect-rs/Cargo.lock
    tools/sky-ffi-inspect-rs/src/main.rs
    tools/sky-ffi-inspect-rs/src/*.rs
```

(Listing `Cargo.lock` is required — `cargo build` needs it for
reproducible inspector builds in the user's `~/.cache/sky/`.)

**Acceptance.** The V3 reproducer above must succeed end-to-end after
the change.

### V4. No regression test for Go-side `.kernel.json` byte-identity (MEDIUM)

The Cross-backend rules header (top of this file) declares:

> **Rule 5.** Never change shared compiler code in ways that could
> break Go compilation in any fork.

There is currently **no test** asserting that `generateBindings
TargetGo` produces bit-identical `.kernel.json` output to a known
baseline. A future agent that "tidies" `FfiGen.hs` — or that fixes
a Rust-side issue by editing a shared helper — could silently change
the Go-side shape and break every downstream user.

**Fix.**

1. Add a checked-in fixture
   `test/fixtures/go-kernel-json/uuid.golden.json` capturing the
   current output of `<SKY> add uuid --target go` for the
   `github.com/google/uuid` package.
2. Add a Cabal-test spec
   `test/Sky/Build/FfiGenGoKernelJsonSpec.hs` that loads a fixed
   `PkgInfo`, calls `FfiGen.generateBindings TargetGo`, reads the
   resulting `.skycache/ffi/uuid.kernel.json`, and `assertEqual`s the
   bytes against the fixture.
3. Wire into `cabal test`'s default sweep.

**Acceptance.** `cabal test FfiGenGoKernelJsonSpec` passes today;
fails loudly the moment anyone changes Go-side `.kernel.json` shape.

### Suggested commit order

| Step | Commit message |
|---|---|
| V1 | `fix(rust): force strict sky.toml read in addHandler — file-handle leak blocked URL git-dep persist` |
| V2 | `fix(rust): refresh inspector embed when source > binary mtime — T3/T5 sanitisation now reaches the bundled binary` |
| V3 | `fix(rust): include sky-ffi-inspect-rs in extra-source-files — fix cabal install without pre-built target/` |
| V4 | `test(rust): pin Go .kernel.json byte-shape — Cross-backend rule 5 enforcement` |
| Cleanup | `docs(rust): mark T3/T5/V1-V4 ✅ in verification snapshot; archive V-priorities` |

After all five commits, drop the ⚠️ marks on T3/T5 in the verification
snapshot (return them to ✅) and re-archive this V-priorities section.

### Out of scope for V-priorities

- Phase 1 onwards of the strategic roadmap (Sky.Live / Sky.Tui /
  Std.Auth ports / WASM). Re-plan once V1–V4 are closed.
- Changes to Go-side codegen, `runtime-go/`, or `src/Sky/Generate/Go/`
  — Cross-backend rule 4.
- Refactors that merge `TargetGo`/`TargetRust` code paths into a single
  branch — Cross-backend rule 5 keeps them separate by default.

## R-priorities (2026-05-23 evening) — ✅ ALL FIXED (archival)

R1–R3 and the auxiliary cleanup are resolved in commits `3f5f2d84`,
`6b17992f`, `5dc5b58d`:

| Issue | What | Fix |
|---|---|---|
| **R1** | No way to disambiguate Rust-FFI imports from stdlib | `pkgToModuleName` now takes `CompileTarget`; Rust crates get `Rust.` prefix (`uuid`→`Rust.Uuid`). Go crates keep the existing dotted-path logic. |
| **R2a** | FFI binding bodies emit free-function calls for methods | `emitRustFnSimple` branches on `_fnRecvType`: instance methods emit `arg0.fnName(rest)`, static/associated fns emit `Type::fnName(args)`, free fns emit `crate::fnName(args)`. |
| **R2b** | Opaque types default to `String` in FFI wrappers | `resolveRustType` helper maps known opaque types to their crate paths via per-crate table (uuid: `Uuid`→`uuid::Uuid`, `Hyphenated`→`uuid::fmt::Hyphenated`, etc.). Also `use <crate>::*;` injected at top of bindings file. |
| **R3** | CLI hint after `sky add` shows broken Sky syntax | Hint now shows `import Rust.Uuid as Uuid`, prints function count, points to `.skycache/ffi/` for signatures. |
| **Cleanup** | Old hash-suffixed cache dirs not removed | Fixed `cleanupOldCaches` to look in `~/.cache/sky/tools/` and use `doesDirectoryExist`. Removes 3 old dirs (~600 MB). |

### Findings

#### R1. No syntactic marker distinguishes Rust-FFI imports from stdlib *(HIGH)*

**Current naming, by `pkgToModuleName` in `src/Sky/Build/FfiGen.hs`:**

| Source | `sky add` input | Sky-side import name |
|---|---|---|
| Core stdlib | (built-in) | `Sky.Core.<X>` |
| Sky stdlib | (built-in) | `Std.<X>` |
| Go FFI | `github.com/google/uuid` | `Github.Com.Google.Uuid` |
| Go FFI | `net/http` | `Net.Http` |
| **Rust FFI** | `uuid` | `Uuid` *(single segment, just capitalised)* |
| **Rust FFI** | `serde_json` | `SerdeJson` |
| User module | n/a | whatever they declared in `module Foo exposing …` |

The first four are unambiguous: Sky.Core.* / Std.* / multi-segment-dotted
is the lexical fingerprint. **Rust-FFI single-segment names collide
with stdlib single-segment names** (`Std.Db` → exposed as `Db`,
`Sky.Core.Uuid` → exposed as `Uuid`, etc.) AND with any user-defined
`src/Uuid.sky` module.

The canonicaliser resolves these by precedence (user > stdlib > FFI,
broadly), but the resolution is invisible at the import line —
a contributor reading Sky source can't tell whether `Uuid.v4 ()` calls
into `Sky.Core.Uuid` or a `uuid` Rust crate without checking the
filesystem.

**Recommended fix.** Prefix Rust-FFI Sky modules with `Rust.` (mirrors
the Go path's de-facto dotted-path convention):

- `sky add uuid --target rust` → Sky module `Rust.Uuid`.
- `sky add serde_json --target rust` → Sky module `Rust.SerdeJson`.
- `sky add chrono --target rust` → Sky module `Rust.Chrono`.

Then the import shape directly tells you the source:

```elm
import Sky.Core.Uuid as Uuid     -- stdlib
import Rust.Uuid as RUuid         -- Rust crate
import Github.Com.Google.Uuid as GUuid  -- Go crate
```

**Implementation.** `src/Sky/Build/FfiGen.hs:pkgToModuleName` already
takes the package path. Add the target as a second argument:

```haskell
pkgToModuleName :: CompileTarget -> String -> String
pkgToModuleName TargetRust path =
    let cap = capitaliseFirst (camelHyphen path)
    in "Rust." ++ cap
pkgToModuleName TargetGo path = ...   -- existing dotted-path logic
```

Update both call sites:
- `FfiGen.hs:generateBindings` (Step 1 in this section's plan).
- `app/Main.hs:1622-1624` (CLI hint — see R3 below).

Update the `_pkgFns` → Sky-module-name flow in `generateBindings` so
the `.skyi` file's `module ` declaration matches. The kernel-name
side already uses `"Rust_"` prefix (per `kernelNameFromPkg`) so
codegen already routes correctly.

**Acceptance.** `sky add uuid --target rust` produces a `.skyi` that
begins with `module Rust.Uuid` (not `module Uuid`). Sky source that
does `import Rust.Uuid as U` resolves to the crate; `import Uuid` /
`import Sky.Core.Uuid` resolves to the stdlib. No silent shadowing.

**Migration.** Existing `.skycache/ffi/*.skyi` files that say
`module Uuid` get re-generated next `sky install`/`sky add` invocation
— there's no migration cost for in-progress projects (the cache is
ephemeral). If shipped projects exist, document the rename in a
changelog entry.

#### R2. FFI binding bodies discard the method receiver *(HIGH)*

**Reproduce.** `cat /tmp/sky-r-ffi/.skycache/rust/uuid_bindings.rs`
shows:

```rust
// [pure] Rust_Uuid_hyphenated
pub fn uuid_hyphenated(arg0: String) -> SkyResult<SkyError, String> {
    uuid::hyphenated(arg0)         // ❌ no such free function in uuid crate
}
```

The `uuid` crate exports `uuid::Uuid::hyphenated(&self) -> Hyphenated`
— a method on the `Uuid` type. The inspector correctly captured this
(its JSON includes `recv_type: "Uuid"`), but `emitRustFnSimple` in
`src/Sky/Build/FfiGen.hs` ignores `_fnRecvType` and emits a flat
`crate::fnName(...)` call.

**Root cause.** `FfiGen.hs:emitRustFnSimple` lines (look for `let
crateImport = pkgToCrateImport (_pkgPath pkg)` and the body
construction below it). The body builder is currently:

```haskell
body = case _fnEffect fn of
    "effectful" -> "Box::pin(async move { match " ++ crateImport ++ "::" ++ fnName ++ "(" ++ argRefs ++ ") ... })"
    "fallible"  -> "match " ++ crateImport ++ "::" ++ fnName ++ "(" ++ argRefs ++ ") ... "
    _           -> crateImport ++ "::" ++ fnName ++ "(" ++ argRefs ++ ")"
```

It needs to branch on `_fnRecvType`:

```haskell
let callExpr = case _fnRecvType fn of
        "" -> -- free function: crate::fn(args)
            crateImport ++ "::" ++ fnName ++ "(" ++ argRefs ++ ")"
        recv ->
            -- method: arg0.fnName(rest_args) — arg0 IS the receiver.
            -- The first param's type is `recv` (or `&recv` / `&mut recv`).
            -- argRefs without the receiver:
            let restArgs = intercalate ", " ["arg" ++ show j | j <- [1..length params - 1]]
            in "arg0." ++ fnName ++ "(" ++ restArgs ++ ")"
    body = case _fnEffect fn of
        "effectful" -> "Box::pin(async move { match " ++ callExpr ++ ".await { ... } })"
        "fallible"  -> "match " ++ callExpr ++ " { ... }"
        _           -> callExpr
```

**Receiver-type coercion.** `arg0`'s declared type comes from
`paramTypes[0]`. If the receiver in Rust is `&Uuid` and the inspector
emits `Uuid` as the param Sky-type, the wrapper has `arg0: Uuid`
(or whatever skyTypeToRust maps `Uuid` to — currently `String`
because opaque types fall through to the catch-all).

So R2 has **two layers**:

R2a. **Branch on `_fnRecvType` to emit method calls vs free functions.**
Land first — this is the immediately-broken path.

R2b. **Map opaque crate types to real Rust types (`uuid::Uuid`),
not `String`.** `skyTypeToRust` currently has a catch-all
`_ -> "String"`. Add a runtime table or per-pkg type registry that
maps `Uuid` → `uuid::Uuid`. The inspector already knows the Rust-side
type (it tracked it as `recv_type` for methods); persist that
information through to FfiGen.

**Acceptance for R2.** `cat .skycache/rust/uuid_bindings.rs` shows
generated bodies matching:
```rust
pub fn uuid_hyphenated(arg0: uuid::Uuid) -> SkyResult<SkyError, uuid::fmt::Hyphenated> {
    SkyResult::Ok(arg0.hyphenated())
}
```
*and* a Sky test program calling `Rust.Uuid.hyphenated` (post-R1)
builds + runs without `cargo build` errors.

**Out of scope for R2 (defer):** the *constructor* problem. The
inspector lists `uuid::Uuid::parse_str`, `uuid::Uuid::new_v4` etc.
as methods too — `parse_str` has `recv_type: ""` (static fn, no
receiver) and IS a free function on the type
`uuid::Uuid::parse_str(...)`. After R2a fires, distinguish
"static method on a type" from "instance method on a value":
- Static (`recv_type == "" && method_name != ""`): emit
  `<Crate>::<Type>::<fn>(args)`.
- Instance (`recv_type != ""`): emit `arg0.<fn>(rest)`.
- Free function (`method_name == ""`): emit `crate::<fn>(args)`.

The inspector already has all three pieces of info in its JSON
output. Just need FfiGen to consume them.

#### R3. CLI hint after `sky add ... --target rust` is broken Sky syntax *(LOW)*

**Reproduce.** `app/Main.hs:1620-1625`:

```haskell
let outputMsg = case target of
        TargetGo ->
            "Call from Sky via: Ffi.callPure \"<name>\" [args]  (or callTask for effectful)"
        TargetRust ->
            "Import in your Sky module, e.g.: import uuid as Uuid; Uuid.v4 (). Wrapper at .skycache/rust/*_bindings.rs"
putStrLn outputMsg
```

Two bugs in the Rust branch:

- `import uuid as Uuid` — lowercase `uuid` is invalid Sky (parse
  error: module names start uppercase).
- `Uuid.v4 ()` — assumes a function named `v4` exists, which is true
  for the stdlib `Sky.Core.Uuid` but **not** for the Rust crate `uuid`
  (whose exported constructors look more like `parse_str`,
  `new_v4` etc. via `Uuid::` methods — which R2 needs to expose
  correctly anyway).

**Fix.** Update the message to:

1. Use the correct Sky module name post-R1: `import Rust.Uuid as Uuid`.
2. Drop the hardcoded `v4 ()` example — instead, point at the
   discovered functions:
   ```haskell
   TargetRust ->
       "Import in your Sky module, e.g.:\n  import "
         ++ skyModuleName ++ " as " ++ shortAlias ++ "\n"
         ++ "Then call any of the " ++ show (length names) ++ " functions"
         ++ " (see .skycache/ffi/" ++ slug ++ ".skyi for signatures)."
   ```
3. Use `skyModuleName` from the post-R1 `pkgToModuleName TargetRust`.

**Acceptance for R3.** `sky add uuid --target rust` prints
exactly *"import Rust.Uuid as Uuid"* (capitalised, correct prefix).

### Priorities (in order)

| Rank | Issue | Effort | Why |
|---|---|---|---|
| 1 | **R2** (binding bodies discard receiver) | 2-3 days | Without this, **no Rust crate FFI actually works** — every method call generates undefined-symbol errors. Blocks every other FFI use. |
| 2 | **R1** (Rust.* prefix for FFI imports) | 1-2 days | Eliminates the silent shadowing risk between stdlib and FFI crates. Smaller scope than R2 but the convention change should land while the Sky/.skyi cache is still empty in most projects. |
| 3 | **R3** (CLI hint correctness) | <1 day | Cosmetic but actively misleads users on first contact with the feature. Land alongside R1 since the fix uses R1's new module name. |
| 4 | `cleanupOldCaches` actually removing hash-suffixed dirs from prior cold-build era | <1 day | Frees ~600 MB on every dev machine that has rebuilt the inspector since 2026-05-19. Currently the cleanup runs but doesn't match these dirs. |

### Implementation plan

Each step ends with: `cargo check` + `cargo clippy --all-targets -- -D
warnings` clean on the runtime, `cabal build exe:sky` clean on the
compiler, all six existing examples + Q1/Q2/Q3 reproducers + the new
R1/R2/R3 reproducer building clean.

#### Step 1 — R2a: branch on receiver type in `emitRustFnSimple`

`src/Sky/Build/FfiGen.hs:emitRustFnSimple`. Read `_fnRecvType fn`. When
non-empty, emit `arg0.<fnName>(rest)` for the call expression instead
of `<crate>::<fnName>(args)`. Reuse the existing `argRefs` machinery
but skip index 0 when there's a receiver.

Add a unit test (Haskell-side `cabal test` or a regression Sky file):
import a method-heavy crate, build it, assert no `error[E0425]` /
`error[E0061]` from cargo.

#### Step 2 — R2b: thread the Rust-side type info through to FfiGen

Currently `_fnParamSkyTypes` and `_fnResultSkyTypes` give Sky-language
types only (Int, Float, …, String catch-all). Add a parallel
`_fnParamRustTypes` / `_fnResultRustTypes` field carrying the actual
Rust type string (e.g. `&Uuid`, `Option<u8>`, `Vec<u8>`).

Inspector side (`tools/sky-ffi-inspect-rs/src/main.rs`): preserve the
original `quote!{ #ty }.to_string()` alongside the `type_to_sky`
mapping. Emit both in JSON.

FfiGen side: prefer the Rust-type string over `skyTypeToRust` when
emitting wrapper params. Keep the Sky-type for the `.skyi` (Sky-side
type checking still wants Sky types).

This is the larger half of R2; if Step 2 proves too invasive, an
acceptable smaller path is to emit `uuid::Uuid` directly for any param
whose Sky-type is the *crate's own opaque type* — detectable by
crate-name match.

#### Step 3 — R1: rename Sky-side modules to `Rust.*`

`src/Sky/Build/FfiGen.hs`:

3.1. Change `pkgToModuleName` to take `CompileTarget`:
```haskell
pkgToModuleName :: CompileTarget -> String -> String
pkgToModuleName TargetRust path = "Rust." ++ rustCrateToCamel path
pkgToModuleName TargetGo path = goPkgToDotted path   -- existing
```

3.2. Update all call sites: `generateBindings`, `kernelNameFromPkg`,
`emitSkyi` (the `.skyi` file's `module ` declaration must match).

3.3. Update `kernelToRust` in `src/Sky/Generate/Rust/Builder.hs` so
that `("Rust.Uuid", "hyphenated") -> "rust_uuid_hyphenated"` routes
to the wrapper module's snake_case name.

3.4. Add a regression test that uses the explicit prefix:
`import Rust.Uuid as U` and calls into the bound crate.

#### Step 4 — R3: fix the CLI hint

`app/Main.hs:1620-1625`. Compute `skyModuleName` from R1's
`pkgToModuleName TargetRust pkg`. Print it verbatim:

```haskell
let alias = lastDottedSegment skyModuleName   -- "Uuid" from "Rust.Uuid"
putStrLn $ "Generated " ++ show (length names) ++ " bindings."
putStrLn $ "Import in your Sky module: import " ++ skyModuleName ++ " as " ++ alias
putStrLn $ "Function signatures: .skycache/ffi/" ++ slug ++ ".skyi"
```

Also update the matching `TargetGo` hint to recommend
`import Github.Com.Google.Uuid as Uuid` syntax (the current message
suggests `Ffi.callPure` which is the *old* pre-Layer-3 path and
should probably go away too — separate cleanup).

#### Step 5 — cleanup obsolete inspector caches

`src/Sky/Build/EmbeddedInspectorRust.hs:cleanupOldCaches`. The
function exists but doesn't remove the hash-suffixed dirs from before
Step A. Verify by listing
`~/.cache/sky/tools/sky-ffi-inspect-rs-*` (with the dash-hash) and
deleting any that match. Idempotent.

### Verification

```bash
# Runtime sanity
(cd runtime-rust && cargo check && cargo clippy --all-targets -- -D warnings && cargo test)

# Compiler sanity
cabal build exe:sky
cabal test

# All examples + Q-reproducers still green
for ex in 01-hello-world 04-local-pkg 07-todo-cli 14-task-demo simple test_pkg; do
    (cd examples/$ex && rm -rf sky-out .skycache .skydeps \
     && ../../sky-out/sky build src/Main.sky --target rust \
     && cargo build --manifest-path sky-out/Rust/Cargo.toml) || echo "FAIL: $ex"
done
for q in q1 q2 q3; do
    (cd /tmp/sky-$q && rm -rf sky-out .skycache \
     && /home/arthur/Documentos/comp/sky/sky-out/sky build src/Main.sky --target rust \
     && cargo build --manifest-path sky-out/Rust/Cargo.toml) || echo "FAIL: $q"
done

# R1+R2+R3 acceptance
cd /tmp/sky-r-ffi && rm -rf sky-out .skycache
/home/arthur/Documentos/comp/sky/sky-out/sky add uuid --target rust 2>&1 | grep -F "import Rust.Uuid as Uuid"
# Source uses the explicit prefix:
cat > src/Main.sky <<'EOF'
module Main exposing (main)
import Rust.Uuid as U
import Std.Log exposing (println)
main =
    case U.parseStr "550e8400-e29b-41d4-a716-446655440000" of
        Ok _  -> println "parsed"
        Err _ -> println "fail"
EOF
/home/arthur/Documentos/comp/sky/sky-out/sky build src/Main.sky --target rust \
    && cargo build --manifest-path sky-out/Rust/Cargo.toml \
    && ./sky-out/Rust/target/debug/sky-app | grep -q "^parsed$" \
    && echo "✅ R1+R2+R3 verified"
```

### What's sure vs unsure

**Sure (HIGH, verified by `cargo build`):**
- R2 (binding bodies discard receiver) — reproducer at `/tmp/sky-r-ffi`
  produces E0425 `cannot find function uuid_hyphenated` because the
  generated `uuid::hyphenated(arg0)` is bogus.
- R3 (CLI hint syntax) — direct read of `app/Main.hs:1620-1625`.

**Reasonably sure (MEDIUM):**
- R1 (Rust prefix) — the convention choice is opinionated; reasonable
  alternatives exist (explicit-alias-only, target-aware resolution
  from sky.toml). Recommended path is `Rust.*` prefix because it
  matches Sky's existing pattern of using module-name shape to signal
  origin (Sky.Core.*, Std.*, Github.Com.*).

**Out of scope (tracked but not blocking R1-R3):**
- Static methods vs instance methods vs free functions disambiguation
  in `emitRustFnSimple` (R2's "Out of scope" subitem above).
- `Std.Auth` / `Std.Db` CRUD / Sky.Live ports — Phase 3 and 4 of the
  strategic plan.

## Next steps

### Immediate (V-priorities)

- **Land V1–V4** in the order documented in *V-priorities (2026-05-24)*
  below.  Required before any further "Rust FFI works" claim — V2 in
  particular is load-bearing for T3/T5/T6/T7's deployed state.
- **Add Go-side byte-identity regression test** (V4) — keeps the
  Go-side `.kernel.json` shape pinned against
  `test/fixtures/go-kernel-json/*.golden.json`.  Cross-backend rule 5
  is currently aspirational; V4 makes it machine-checked.

### Short-term

- <s>Upgrade `emitRustFile` type mapping.</s> ✅ The inspector now populates `skyType` per param and result. Types `Int`, `Float`, `Bool`, `String`, `List`, `Maybe`, `Result`, `Dict` map correctly. Opaque types (struct names, enums) still fall back to `String` — a Rust-crate-type mapping table is the remaining gap.
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

## Q-priorities (2026-05-23) — ✅ RESOLVED (archival)

> **Audience: AI fix-up agent.** This section is **historical** —
> Q1–Q3 and Step 4–5 have all landed and been verified end-to-end
> (see *Verification snapshot* in the *Completed audits* section
> above). It's kept here as the reference for *why* the code looks
> the way it does and *which* commits implemented each fix
> (`9bde0c52`, `7b1d9ac4`, `cc9192e6`, `2f38f944`, `0094e2f4`,
> `dd79d333`). New work belongs in *R-priorities* above.
>
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

