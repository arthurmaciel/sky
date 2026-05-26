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
| `tools/sky-ffi-inspect-rs/` | Rust crate inspector (rustdoc JSON backend) |

**Files outside these directories** (`src/Sky/Build/*.hs`, `app/Main.hs`,
`src/Sky/Sky/Toml.hs`, `src/Sky/Canonicalise/*.hs`, etc.) may only be touched
if the changes do not affect the Go backend. Every change to shared compiler
infrastructure must be gated behind `TargetRust ->` branches so the Go backend
is byte-identical.

---

## Cross-backend rules (load-bearing — never violate)

Go is the **production / highest-priority backend**. Rust is second-tier.
These rules are non-negotiable for every contributor (human or AI):

1. **Go FFI artifacts stay at the root of `.skycache/ffi/`.**
   `.skycache/ffi/<slug>.kernel.json` and `.skycache/ffi/<slug>.skyi` are
   Go-target files. They are never moved into a subdirectory.

2. **Each non-Go backend gets its own subdirectory.** Rust artifacts live at
   `.skycache/ffi/rust/<slug>.kernel.json`. Future WASM → `.skycache/ffi/wasm/`.
   Pattern: *Go = root, everything else = named subdir.*

3. **`loadAndSeedFfiRegistry` reads target-appropriate paths.** For `target = "go"`
   (the default), the registry reads `.skycache/ffi/*.kernel.json`. For
   `target = "rust"`, it reads `.skycache/ffi/rust/*.kernel.json`.

4. **Never touch Go-generated files.** When working on the Rust backend, do not
   change a single byte of `runtime-go/`, `.skycache/ffi/<slug>.{kernel.json,skyi}`
   at the root, or `src/Sky/Generate/Go/`.

5. **Never change shared compiler code in ways that could break Go compilation
   in any fork.** New Rust functionality always goes behind explicit `TargetRust ->`
   branches. Merging target-specific logic into a unified path requires a separate,
   explicit decision — the default is **keep the branches separate**.

6. **`sky add <pkg>` routing rules:**
   - URL (`https://…`, `git@host:…`): Go → `[go.dependencies]`; Rust → `[rust.dependencies]` as `{ git = "<url>" }`.
   - Bare name: Go → `go get`; Rust → crates.io via `cargo fetch`.

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
```

There is no `[rust.shims]` section — Rust FFI is fully automatic via
`rustdoc --output-format json`. No hand-written Rust glue files are required,
even for crates that use proc macros or derive macros.

---

## Verification state (branch `feat/runtime-rust`)

### Core Sky examples (compiled with `--target rust`)

| Example | Status | Notes |
|---|---|---|
| 01-hello-world | ✅ builds + runs | |
| 04-local-pkg | ✅ builds + runs | multi-module |
| 07-todo-cli | ✅ builds + runs | SQLite CRUD via sqlx |
| 14-task-demo | ✅ builds + runs | Task combinators |

### Rust FFI examples (`examples/rust/`)

All 13 build and run from a clean slate (`rm -rf sky-out .skycache && sky add … && sky run`).

| Example | Crate | Status | What it shows |
|---|---|---|---|
| 01-rand | `rand` | ✅ builds + runs | `Rand.random_bool 0.5` → Heads/Tails |
| 02-num-cpus | `num_cpus` | ✅ builds + runs | `NumCpus.get ()` → CPU count |
| 03-chrono | `chrono` | ✅ builds + runs | `Utc::now` + Display → current UTC timestamp |
| 04-uuid | `uuid` (feat v4) | ✅ builds + runs | `Uuid::new_v4` + Display → UUID string |
| 05-roman | `roman` | ✅ builds + runs | free fns `to`/`from` → `MMXXIV` |
| 06-lipsum | `lipsum` | ✅ builds + runs | `lipsum n` → lorem ipsum text |
| 07-deunicode | `deunicode` | ✅ builds + runs | `deunicode s` → ASCII transliteration |
| 08-semver | `semver` | ✅ builds + runs | `Version::parse` + Display → re-rendered version |
| 09-bytesize | `bytesize` | ✅ builds + runs | `ByteSize::mb` + Display → `1.4 GiB` |
| 10-titlecase | `titlecase` | ✅ builds + runs | `titlecase s` → Title Cased string |
| 11-fastrand | `fastrand` | ✅ builds + runs | `fastrand::bool` → coin flip |
| 12-ulid | `ulid` | ✅ builds + runs | `Ulid::new` + Display → ULID string |
| 13-petname | `petname` | ✅ builds + runs | `petname n sep` → friendly random name |

These span the common shapes auto-FFI must handle: free functions, static
methods (`Type::fn`), instance methods (`arg0.method`), `Display`/`FromStr`
bridges, `Option`/`Result` returns, and primitive ⇄ opaque round-tripping.

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

---

## Rust FFI

`sky add <crate> --target rust` invokes `sky-ffi-inspect-rs`, which:

1. Creates a temporary Cargo project with the crate as a dependency.
2. Runs `cargo +nightly rustdoc --package <crate> --lib --output-format json`.
   This executes **after** proc macro expansion, so derive-generated impls
   (clap `Parser`, serde `Serialize`, etc.) are fully visible.
3. Parses the JSON output to extract public functions, impl block methods,
   and trait impls — including those generated by macros.
4. **Facade detection:** if the crate is a thin re-export (`pub use underlying::*`)
   with zero functions, the inspector follows the glob to the underlying crate
   and re-runs rustdoc on it automatically (e.g. `clap` → `clap_builder`).
5. Maps Rust types → Sky types (`Vec→List`, `Option→Maybe`, `HashMap→Dict`,
   `Result→Result E A`, `SkyResult<E,A>→Result E A`).
6. Emits JSON matching the `PkgInfo` schema consumed by `FfiGen.hs`.
7. Writes `.skycache/ffi/rust/<slug>.kernel.json`, `.skycache/ffi/rust/<slug>.skyi`,
   and `.skycache/ffi/rust/<slug>_bindings.rs` (all three Rust artifacts share
   the `.skycache/ffi/rust/` subdirectory).

Generated bindings use `import Rust.<Name> as Name` in Sky source. Method
bindings are disambiguated by receiver: `Utc::now` → `now_from_utc`,
`DateTime::to_string` → `to_string_from_dateTime`.

### Opaque-type qualification

Every crate-local opaque type is emitted **fully-qualified by its public
re-export path** (`chrono::NaiveDate`, `chrono::format::Parsed`), keyed on the
rustdoc item id. This is unambiguous — it avoids glob-import name clashes (e.g.
a crate with two `Error` types in different submodules) — so the wrappers need
only a single root `use <crate>::*;`.

### Nameability filter — bindings that can't compile are dropped, not emitted

The inspector skips any function it cannot turn into a sound monomorphic
wrapper, so the generated `_bindings.rs` always compiles:

| Dropped | Why |
|---|---|
| Generic functions (`fn f<T>`) and impl-level generics (`DateTime<Tz>`) | no concrete type at the FFI boundary |
| Lifetime-parameterised types (`Item<'a>`, `&'a str`) | borrow scope can't be expressed in an owned wrapper |
| Borrowed results (`&mut Builder`, nested `(.., &[u8;8])`) | tie to a lifetime the wrapper can't supply |
| Fixed-size arrays / slices (`[u8;16]`, `&[u8]`) | Sky's `Vec<u8>` doesn't coerce to them |
| `unsafe fn` | auto-exposing e.g. `new_unchecked` would bypass invariants |
| Private crate types & external/std types (`Duration`, `RangeInclusive`) | no nameable public path |

Plain `&str`/`&String` results are kept (copied to an owned `String`). Crate-local
**non-generic type aliases** are resolved to their underlying type first
(`uuid::Bytes = [u8; 16]`), so the array filter sees the real shape.

### Deduplication

Bindings are deduped once in `generateBindings` (Rust path) so the `.rs`, `.skyi`,
and `.kernel.json` agree. A real `to_string`/`from_string` method colliding with
the synthetic Display/FromStr bridge (e.g. `ulid::Ulid`) collapses to one entry.

### Inspector binary resolution (priority order)

| Priority | Source |
|---|---|
| 1 | `$SKY_FFI_INSPECTOR_RS` env var |
| 2 | `./bin/sky-ffi-inspect-rs` (walking up ancestors) |
| 3 | Binary embedded in the `sky` binary (materialised on first use at `~/.cache/sky/tools/sky-ffi-inspect-rs/`) |

The embedded path bundles the pre-built release binary via Template Haskell.
Source files in `tools/sky-ffi-inspect-rs/` are registered as TH dependencies;
editing them triggers a rebuild of both the inspector and the `sky` binary.

### Feature flags

```bash
sky add uuid --features v4 --target rust
```

Recorded in `sky.toml` as `uuid = { version = "1", features = ["v4"] }` and
passed through to `Cargo.toml` by `emitCargoToml`.

### Display/FromStr bridge

For opaque types that implement `Display`/`FromStr`, the inspector auto-generates
synthetic `to_string`/`from_string` bindings so Sky code can convert to/from
`String` without any manual glue.

---

## FFI codegen type-coercion rules

`FfiGen.hs` (`emitRustFnSimple`) uses these rules when emitting wrapper bodies.

**Parameter type (`resolveRustType`).** A param's wrapper type is the *Sky-mapped*
type for known Sky types, so the wrapper takes the owned value the call site
passes. The inspector's raw Rust type is used only for opaque types (and is
fully-qualified):

| Sky param type | Wrapper param type |
|---|---|
| `String` | `String` (borrowed internally via `&argN`) |
| `Int` / `Float` / `Bool` / `Bytes` | `i64` / `f64` / `bool` / `Vec<u8>` |
| `List a` / `Maybe a` / `Dict String v` | `Vec<…>` / `SkyMaybe<…>` / `HashMap<…>` |
| opaque type | the fully-qualified raw type (`chrono::NaiveDate`) |

**Parameter coercion (`argCall`):**

| Declared wrapper type | Raw Rust fn param type | Emitted arg |
|---|---|---|
| `String` | `&str` | `&argN` |
| `i64` / `f64` | narrower numeric (`u32`, `usize`, `f32`, …) | `argN as <rawType>` |
| anything | same / absent | `argN` |

**Return type + coercion (`translateRustRet`).** The declared return type and the
lifting expression are derived from the *raw Rust return type* (the source of
truth — the Sky type collapses opaque types to `String`):

| Raw Rust return | Declared wrapper return | Lift |
|---|---|---|
| `Option<T>` | `SkyMaybe<T'>` | `match … { Some(v) => SkyMaybe::Just(co v), None => SkyMaybe::Nothing }` |
| `Vec<T>` | `Vec<T'>` | per-element `.map` only when `T` needs coercion |
| `iN` / `uN` | `i64` | `(e) as i64` |
| `f32` / `f64` | `f64` | `(e) as f64` |
| `bool` / `String` | `bool` / `String` | identity |
| `&str` / `&String` | `String` | `e.to_string()` |
| `()` / none | `()` | identity (the call still executes) |
| opaque `T` | `T` (qualified) | identity — no `.into()` |

Effect drives the wrapper body: `pure` → `ok_res(lift(call))`; `fallible` →
`match call { Ok(v) => ok_res(lift(v)), Err(e) => SkyResult::Err(str_err(…)) }`
(the Ok type is extracted from `Result<T, E>` before lifting); `effectful` →
the same inside `Box::pin(async move { … .await })`. `.into()` and
`.try_into().unwrap()` are never emitted.

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

# Add a crate dependency (fully automatic — no shims needed)
sky add uuid --target rust
sky add rand --features="small_rng" --target rust
sky add clap --features="derive" --target rust   # proc macros fully visible

# Regenerate all Rust FFI bindings (after rm -rf .skycache)
sky install
```

---

## Known limitations

| Limitation | Description | Workaround |
|---|---|---|
| Partial application of kernels | `let f = Task.map myFn` emits an under-applied call | Wrap in explicit closure: `\t -> Task.map myFn t` |
| JSON pipeline decoder | `Box<dyn FnOnce>` chain from `json_dec_p_required` + `json_dec_succeed` can't satisfy `Clone+Send` | Architecture-level fix needed |
| Polymorphic ADT returns | Functions returning `Result`/`Maybe` with unresolved type vars may default to `()` | Annotate return type explicitly |
| Flat main.rs | All Sky modules compile into a single `main.rs`; no `mod` declarations | Planned |
| `sky install` git deps | git-source Rust deps may need manual `sky add` after `rm -rf .skycache` | Run `sky add <crate> --target rust` for each git dep |
| `Db.migrateApply` | No transaction wrapping or rollback | Planned |
| `rustdoc` requires nightly | Inspector runs `cargo +nightly rustdoc`; nightly toolchain must be installed | `rustup install nightly` |
| Un-nameable bindings dropped | Functions taking/returning generics, slices/arrays, borrows, std types, or unsafe fns are skipped (see nameability filter) | Use a wrapper crate exposing owned/primitive signatures, or a crate whose API is self-typed |

---

## Remaining work

### Short-term
- **Slice / byte-array params** — coerce Sky `Bytes` (`Vec<u8>`) to `&[u8]` /
  `[u8; N]` params (currently dropped) so hashing/encoding crates bind.
- **Enum-argument constructors** — many crate fns take a crate enum (e.g.
  `base32::encode(Alphabet, …)`); expose enum variants so Sky can pass them.
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
