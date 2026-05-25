# Sky Rust Runtime

The `sky_runtime` crate is the **single source of truth** for all Rust code
emitted by the Sky compiler's `--target rust` path. Every generated project
copies this crate's modules into `sky-out/Rust/src/sky_runtime/` at build time.

---

## Architecture

```
Sky Source → Haskell Parser → Type-Check → Canonical AST → Rust Codegen (Builder.hs)
                                                                    ↓
                                            sky_runtime/ modules (this directory)
                                                                    ↓
                                          sky-out/Rust/src/main.rs + sky_runtime/
                                                                    ↓
                                                       cargo build → binary
```

All runtime logic lives in `sky_runtime/`; `Builder.hs` emits only thin wrappers
that instantiate `E = SkyError` for the generated project. No inline Rust
implementation strings in the Haskell codegen.

---

## Modification boundaries

**When working on the Rust backend, only modify files in:**

| Directory | Purpose |
|---|---|
| `runtime-rust/` | Rust runtime crate (`sky_runtime` modules, property tests) |
| `src/Sky/Generate/Rust/` | Rust codegen — `Builder.hs` only |
| `tools/sky-ffi-inspect-rs/` | Rust crate inspector (crate introspection via `syn`) |

**Files outside these directories** (`src/Sky/Build/*.hs`, `app/Main.hs`,
`src/Sky/Sky/Toml.hs`, `src/Sky/Canonicalise/*.hs`, etc.) may only be touched
with **explicit permission**. Every change to shared compiler infrastructure must
be gated behind `TargetRust ->` branches so the Go backend is byte-identical.

---

## Cross-backend rules (load-bearing — never violate)

Go is the **production / highest-priority backend**. Rust is second-tier.
These rules are non-negotiable for every contributor (human or AI):

1. **Go FFI artifacts stay at the root of `.skycache/ffi/`.**
   `.skycache/ffi/<slug>.kernel.json` and `.skycache/ffi/<slug>.skyi` are
   Go-target files. They are never moved into a subdirectory. Existing Go
   projects in this repo, in forks, and in the wild depend on this layout.

2. **Each non-Go backend gets its own subdirectory.** Rust artifacts live at
   `.skycache/ffi/rust/<slug>.kernel.json`. Future WASM → `.skycache/ffi/wasm/`.
   Pattern: *Go = root, everything else = named subdir.*

3. **`loadAndSeedFfiRegistry` reads target-appropriate paths.** For `target = "go"`
   (the default), the registry reads `.skycache/ffi/*.kernel.json`. For
   `target = "rust"`, it reads `.skycache/ffi/rust/*.kernel.json`. Loading only
   the active target's catalogue keeps imports unambiguous.

4. **Never touch Go-generated files.** When working on the Rust backend, do not
   change a single byte of `runtime-go/`, `.skycache/ffi/<slug>.{kernel.json,skyi}`
   at the root, or `src/Sky/Generate/Go/`. Rust work goes in `src/Sky/Generate/Rust/`,
   `runtime-rust/`, `tools/sky-ffi-inspect-rs/`, and (carefully) target-gated
   branches of shared files.

5. **Never change shared compiler code in ways that could break Go compilation
   in any fork.** `src/Sky/Build/Compile.hs`, `src/Sky/Build/FfiGen.hs`,
   `app/Main.hs`, `src/Sky/Canonicalise/*`, etc. must keep their existing
   `TargetGo` behavior bit-identical. New Rust functionality always goes behind
   explicit `TargetRust ->` branches. Merging target-specific logic into a
   unified path requires a separate, explicit decision — the default is
   **keep the branches separate**.

6. **`sky add <pkg>` routing rules:**
   - URL (`https://…`, `git@host:…`): Go → `[go.dependencies]` (unchanged);
     Rust → `[rust.dependencies]` as `{ git = "<url>" }`.
   - Bare name: Go → `go get`; Rust → crates.io via `cargo fetch`.
   - No silent defaulting: print exactly what was assumed and what version was
     pinned.

---

## sky.toml Rust fields

```toml
[project]
target = "rust"                    # default is "go"; overridden by --target flag

["rust.dependencies"]
uuid    = "1.16.0"                 # crates.io — simple version string
serde   = { version = "1", features = ["derive"] }  # with features
mylib   = { git = "https://github.com/org/mylib", rev = "abc123" }  # git dep

[rust]
sqlx_tls = "rustls"               # default; alt: "native-tls"

[rust.shims]
"Greet" = "ffi/greet.rs"          # hand-written Rust glue for macro-generated crates
```

---

## Verification state (branch `feat/runtime-rust`)

### Core Sky examples (compile with `--target rust`)

| Example | Status | Notes |
|---|---|---|
| 01-hello-world | ✅ builds + runs | |
| 04-local-pkg | ✅ builds + runs | multi-module |
| 07-todo-cli | ✅ builds + runs | SQLite CRUD via sqlx |
| 14-task-demo | ✅ builds + runs | Task combinators |
| simple | ✅ builds + runs | task_sequence + task_parallel |
| test_pkg | ✅ builds + runs | Result/Maybe combinators |

### Rust FFI examples (`examples/rust/`)

| Example | Crate | Description |
|---|---|---|
| 01-rand | `rand` | `Rand.random_bool 0.5` → prints Heads/Tails |
| 02-num-cpus | `num_cpus` | `NumCpus.get ()` → prints CPU count |
| 03-shim-hello | `[rust.shims]` | `greet "World"` via hand-written shim → `Hello, World!` |

All three examples build and run clean from a wiped `.skycache`.

---

## Module structure

```
runtime-rust/src/sky_runtime/
├── config.rs      GENERATED at build time — DbPool, DbRow, SKY_DB_URL
├── core.rs        SkyResult<E,A>, SkyMaybe<T>, SkyTask<E,A>, ok_res, str_err,
│                  list/string/float helpers, result_with_default, result_traverse
├── task.rs        task_succeed, task_map, task_and_then, task_on_error,
│                  task_fail, task_perform, task_sequence, task_run, task_parallel
├── log.rs         log_info, log_debug, log_warn, log_error, *_with variants
├── system.rs      system_args, system_exit, system_setenv, system_unsetenv
├── time.rs        time_now, time_sleep, time_unix_millis, time_time_string
├── random.rs      random_int, random_float (LCG, seeded from system entropy)
├── file.rs        file_read_file, file_write_file, file_exists, file_delete
├── crypto.rs      crypto_random_bytes, crypto_random_token, crypto_sha256 (sha2 crate)
├── json.rs        JSON encode/decode, Decoder<E,T>, curry1–5, pipeline combinators
├── db.rs          db_connect, db_exec, db_query, db_get_field (sqlx-backed)
└── mod.rs         re-exports config + core; other modules via sky_runtime::<mod>::<fn>
```

---

## Error type

All runtime functions are generic over `E`. `Builder.hs` emits thin wrappers
that instantiate `E = SkyError` for the generated project:

```rust
// sky_runtime/task.rs (generic):
pub fn task_map<E, A, B>(f: impl FnOnce(A) -> B + Send + 'static,
                         task: SkyTask<E, A>) -> SkyTask<E, B>

// generated main.rs (wrapper, E = SkyError fixed):
pub fn task_map<A, B>(f: impl FnOnce(A) -> B + Send + 'static,
                      task: SkyTask<A>) -> SkyTask<B> {
    sky_runtime::task::task_map::<SkyError, _, _>(f, task)
}
```

`SkyError` is:
- `String` when `Sky.Core.Error` is not imported
- The `SkyCoreErrorError` ADT when `Sky.Core.Error` is imported

---

## Rust FFI

`sky add <crate> --target rust` invokes `sky-ffi-inspect-rs`, which:

1. Creates a temporary Cargo project with the crate as a dependency
2. Runs `cargo fetch` (cached) to download the source
3. Uses `syn` to parse `pub fn`, `pub struct`, `impl Type { pub fn }` items
4. Maps Rust types → Sky types (`Vec→List`, `Option→Maybe`, `HashMap→Dict`, `Result→Result E A`, `SkyResult<E,A>→Result E A`)
5. Emits JSON matching the `PkgInfo` schema consumed by `FfiGen.hs`
6. Writes `.skycache/ffi/rust/<slug>.kernel.json` + `.skycache/ffi/rust/<slug>.skyi`
7. Writes `.skycache/rust/<slug>_bindings.rs` (the wrapper module)

Generated bindings use `import Rust.<Name> as Name` in Sky source.

### Shims — escape hatch for macro-generated crates

Crates whose public API comes from derive macros (clap, serde-derive, etc.) export
zero functions from `syn`'s perspective. Use `[rust.shims]` instead:

```toml
[rust.shims]
"Greet" = "ffi/greet.rs"
```

The shim file is hand-written Rust that exposes a Sky-FFI-compatible interface
(`SkyResult<SkyError, T>` returns, `String`/`i64`/`bool` params). During
`sky build`, the compiler:

1. Runs the inspector in `--shim` mode on the file
2. Generates `.skycache/ffi/rust/<slug>.kernel.json` and `.skyi`
3. Writes a re-export stub at `.skycache/rust/<slug>_bindings.rs`
4. Copies the shim source to `sky-out/Rust/src/shims/<name>.rs`
5. Injects `pub mod shims;` into `main.rs`

See `examples/rust/03-shim-hello/` for a complete working example.

### Feature flags

```bash
sky add uuid --features v4 --target rust
```

Recorded in `sky.toml` as `uuid = { version = "1", features = ["v4"] }` and
passed through to `Cargo.toml` by `emitCargoToml`.

### Display/FromStr bridge

For opaque types that implement `Display`/`FromStr`, the inspector auto-generates
synthetic `to_string`/`from_string` bindings so Sky code can convert to/from `String`
without hand-written shims.

### Inspector binary resolution (priority order)

| Priority | Source |
|---|---|
| 1 | `$SKY_FFI_INSPECTOR_RS` env var |
| 2 | `./bin/sky-ffi-inspect-rs` (walking up ancestors) |
| 3 | Binary embedded in the `sky` binary (default, materialised on first use) |

The embedded path bundles the pre-built release binary via Template Haskell into
`~/.cache/sky/tools/sky-ffi-inspect-rs/` on first `sky add --target rust`. Source
files are registered as TH dependencies; editing them recompiles both the inspector
and the sky binary automatically.

---

## FFI codegen type-coercion rules

`FfiGen.hs` (`emitRustFnSimple`) uses these rules when emitting wrapper bodies.
Knowing them is essential when debugging generated bindings.

**Parameter coercion (`argCall`):**

| Declared wrapper type | Raw Rust fn param type | Emitted arg expression |
|---|---|---|
| `i64` / `f64` (Sky Int/Float) | same type | `argN` (pass through) |
| `i64` / `f64` | narrower numeric (`u32`, `usize`, `f32`, …) | `argN as <rawType>` |
| `String` | `&str` or absent | `&argN` |
| anything | same type or absent | `argN` (pass through) |
| opaque type | opaque type | `argN` (pass through) |

**Return coercion (`coerceRet`):**

| Declared wrapper return | Raw Rust fn return | Emitted conversion |
|---|---|---|
| same type or absent | same type | no conversion |
| any | starts with `&` (reference) | `.to_owned()` |
| `i64` / `f64` | numeric type | `as i64` / `as f64` |
| fallback | differs | `.into()` (requires `From` impl — cargo catches missing impl) |

`.try_into().unwrap()` is **never** emitted (removed in B2 — was causing E0277
compile errors on reference-returning methods and runtime panics on numeric overflow).

---

## CLI usage

```bash
# Build for Rust target
sky build src/Main.sky --target rust

# Build and run
sky run src/Main.sky --target rust

# Type-check (runs full emit + cargo build)
sky check src/Main.sky --target rust

# Run tests
sky test tests/MyTest.sky --target rust

# Add a crate dependency
sky add uuid --target rust
sky add rand --features="small_rng" --target rust

# Regenerate all Rust FFI bindings (after rm -rf .skycache)
sky install
```

---

## Known limitations

| Limitation | Description | Workaround |
|---|---|---|
| Macro-generated APIs | `sky add clap` reports 0 functions — derive macros are invisible to `syn` | `[rust.shims]` in `sky.toml` |
| Partial application of kernels | `let f = Task.map myFn` emits an under-applied call | Wrap in explicit closure: `\t -> Task.map myFn t` |
| JSON pipeline decoder | `Box<dyn FnOnce>` chain from `json_dec_p_required` + `json_dec_succeed` can't satisfy `Clone+Send` | Architecture-level fix needed |
| Polymorphic ADT returns | Functions returning `Result`/`Maybe` with unresolved type vars may default to `()` | Annotate return type explicitly |
| Flat main.rs | All Sky modules compile into a single `main.rs`; no `mod` declarations | Planned |
| `sky install` git deps | git-source Rust deps may need manual `sky add` after `rm -rf .skycache` | Run `sky add <crate> --target rust` for each git dep |
| `Db.migrateApply` | No transaction wrapping or rollback | Planned |

---

## Remaining work

### Short-term
- **JSON pipeline decoder** — restructure `Decoder<E, T>` to avoid `FnOnce` trait-bound
  mismatch in pipeline combinators (`06-json` example).
- **Separate module files** — emit `pub mod <name>;` declarations instead of flattening
  all Sky modules into `main.rs`.
- **`sky install` git deps** — ensure `regenMissingRustBindings` handles `RustGit` specs.

### Medium-term
- **Stdlib completeness** — add `list_foldl`, `list_range`, `list_indexed_map`,
  `list_concat_map`, `list_zip`, `list_any`, `list_all` to `sky_runtime/core.rs`
  and wire `kernelToRust` arms in `Builder.hs`.
- **Eliminate spurious `.clone()` on Copy types** — add `ecCopyVars` tracking for
  `Int`, `Float`, `Bool`, `Char`.
- **`Db.migrateApply`** — transaction wrapping and rollback.
- **Expand proptest coverage** — currently 11 assertions; target: every runtime
  combinator has at least one property test.

### Long-term
- **Sky.Live / Sky.Tui** — port `runtime-go/rt/live.go` and `tui_*.go` to Rust.
- **Std.Auth** — `hashPassword`, `signToken`, `verifyToken`, `register`, `login`.
- **Std.Db complete CRUD** — `insertRow`, `getById`, `updateById`, `deleteById`,
  `findOneByField`, `withTransaction`.
- **WASM target** — cross-compile runtime and generated code to `wasm32-unknown-unknown`.
- **`sky watch` for Rust** — rebuild on `runtime-rust/src/` changes.
