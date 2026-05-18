# SkyRust

A transpiler that converts Sky (Elm-compatible functional language) to idiomatic Rust code.

## Overview

Transpile Sky to Rust code that compiles with `cargo` and uses Tokio for async Task execution.

```
Sky Source → Haskell Parser/Type-Check → Sky AST → Rust Codegen → Rust Code (sky-out/Rust/)
                                                                              ↓
                                                                  Cargo.toml + src/main.rs
                                                                              ↓
                                                                   cargo build / cargo run
```

**Architecture**: Reuse Sky's Haskell parser/type-checker and add a Rust codegen module. The generated project uses `cargo` with `tokio` for the async runtime. `Go` remains the default target; pass `--target rust` for Rust output.

## Project Structure

```
runtime-rust/
├── README.md                       # This file
├── CLAUDE.md                       # Project context (for AI tooling)
├── sky-runtime-rust/               # Standalone crate (54 tests, NOT linked by generated code)
│   ├── Cargo.toml
│   └── src/lib.rs
└── sky-compiler/
    └── src/Sky/Generate/Rust/Builder.hs  # Core codegen (~1830 lines) — the only compiled module
```

Note: `Sky/Generate/Rust/{Decl,Expr,Kernel,Module,Pattern,Test,Types}.hs` were deleted (7 files, 1192 lines of never-compiled dead code).

## Status

### ✅ Phase 1: Runtime Prototype (standalone crate, not linked by generated code)
- `sky-runtime-rust` crate with 54 tests passing (not used by codegen — runtime is inlined)
- Core types: SkyResult, SkyMaybe, SkyString, SkyList, SkyDict, SkyTask

### ✅ Phase 2: Codegen Implementation (1830+ lines in Builder.hs)
Rust codegen lives in the main Sky compiler at `src/Sky/Generate/Rust/Builder.hs`.

**Working Features**:
| Feature | Status |
|---------|--------|
| Hello world | ✅ Compiles and runs ("Hello from Sky!") |
| Todo-cli (real SQLite) | ✅ All 7 CRUD operations + help work with persistent DB |
| `--target rust` flag | ✅ Wired into CLI |
| Cargo.toml generation | ✅ Auto-generated with tokio + sqlx dependencies |
| Expression translation | ✅ Functions, calls, patterns, let, binops, lambdas, if/case |
| Kernel calls | ✅ log_info (println → log_info), Task, System, Log, Db, Result, Time, Random, File, Crypto |
| Type mapping | ✅ Basic types + module-prefixed user types |
| Union/ADT handling | ✅ Module-prefixed enum (`Sky_Core_Error::Error`) |
| ADT constructor field types | ✅ Uses actual types from Can.Ctor (not `()`) |
| Typed function params | ✅ From TypedDef annotations (`e: Sky_Core_Error_Error`) |
| Return type annotations | ✅ `-> RetType` from TypedDef / solvedTypes |
| Pipeline `\|>` | ✅ Emitted as `f(x)` |
| Cons `::` operator | ✅ `sky_list_cons(x, xs)` helper |
| String concat `++` | ✅ Uses `format!()` for String/String compatibility |
| Rust keyword escaping | ✅ `fn` → `r#fn`, etc. |
| Multi-module projects | ✅ All dep modules with module-prefixed names |
| Cons/slice pattern | ✅ `[head, tail @ ..]` with `..` for unused tail |
| FFI placeholder types | ✅ Auto-generated for undefined referenced types |
| List/maybe/error sigs | ✅ knownDefSig covers List, Maybe, Error modules |
| `as_slice()` for Vec | ✅ Match scrutinee wrapped for slice pattern support |
| Thunk auto-invoke | ✅ `(|| { expr })()` for `let _ = Task.run` discard |
| Db runtime (sqlx backend-specific) | ✅ SqlitePool/PgPool/MySqlPool via sky.toml `[database]` driver; only one backend compiled |
| Conditional compilation | ✅ Only tokio/sqlx/serde_json deps when actually used |
| ok_res type-inference helper | ✅ Closes E0282 class — no turbofish at any call site |
| Anonymous record structs | ✅ Synthetic `__anon__` structs for inline records without type alias |
| Structured log attrs | ✅ `fmt_attrs` formats `[k,v,k,v,…]` as ` key=value` |
| Extra kernel stubs | ✅ Time, Random (LCG), File, Crypto (sha256/random), Http (error stub) |
| `#[derive(Clone, Debug)]` | ✅ All generated enums and structs |

### Phase 3: Remaining Issues

Known limitations:
- Anonymous records lose type precision (SkyValue/String fields only)
- JSON decoder lifetimes (06-json): ∼139 errors from Fn/FnOnce mismatches
- Def return type inference: simple/test_pkg examples have wrong return type
- Separate module files (`mod` declarations instead of flat `main.rs`)
- `System.setenv` / `System.unsetenv`

## Usage

```bash
# Build for Go (default)
sky build src/Main.sky

# Build for Rust
sky build src/Main.sky --target rust

# Compile and run the Rust output
cd sky-out/Rust
cargo run

# The output is a Cargo project:
#   sky-out/Rust/
#     Cargo.toml
#     src/
#       main.rs
```

## sqlx Database Runtime

The generated project includes sqlx with a backend-sepcific pool type determined by `sky.toml [database] driver`:

```rust
use sqlx::sqlite::{SqlitePool as DbPool, SqliteRow as DbRow};
use sqlx::{Column, Row};

type Db = DbPool;
const SKY_DB_URL: &str = "sqlite:todos.db?mode=rwc";
```

**Backend switching** (compile-time, via Cargo feature):
- `driver = "sqlite"` → `SqlitePool`, `SqliteRow` (feature `sqlite`)
- `driver = "postgres"` → `PgPool`, `PgRow` (feature `postgres`)
- `driver = "mysql"` → `MySqlPool`, `MySqlRow` (feature `mysql`)

Only the selected backend's driver is compiled. No `AnyPool`, no `install_default_drivers()`.

**Config source**: `sky.toml` `[database]` section. `driver = "sqlite"` prepends `sqlite:` prefix + `?mode=rwc`; other drivers pass the path as-is.

**Helper functions**:
| Helper | Purpose |
|--------|---------|
| `build_sql` | Replaces `?` with escaped `'values'` (DB-agnostic) |
| `row_to_map` | Converts `DbRow` → `HashMap<String,String>` with type fallback chain |
| `sky_err` | Maps `sqlx::Error` → correct `SkyError` variant (Network/Io/Conflict/Timeout/Unavailable/Unexpected) |

## Task Runtime (Tokio-based async)

The compiler emits proper async/await combinators using Tokio:

```rust
// Task type: SkyError fixed (no generic E parameter)
type SkyTask<A> = Pin<Box<dyn Future<Output = SkyResult<SkyError, A>> + Send + 'static>>;

// Combinators use async move blocks (edition 2021)
task_map(f)(task)       // map Ok value
task_and_then(f)(task)  // chain another Task
task_on_error(f)(task)  // error recovery
task_succeed(a)         // lift value into Task
task_fail(e)            // lift error into Task

// Parallel execution uses tokio::spawn (~Go goroutines)
task_parallel(tasks)  // results, short-circuit on first error

// Synchronous execution via block_on
task_run(task)  // blocks on the future via Tokio runtime
```

The `main()` entry point runs the Sky `main` function's Task pipeline:

```rust
fn main() {
    let _ = block_on(sky_main());  // sky_main returns SkyTask<()>
}
```

## Issues Encountered and Fixed

### Session 1 (initial implementation)
1. **Can.TAlias field** - Uses `.ty` (single type), not a list
2. **Can.Forall pattern** - Doesn't exist in `Can.Type`, only in `Annotation`
3. **Main naming conflict** - Renamed user `main` to `sky_main`
4. **Debug derive conflict** - Removed `#[derive(Debug)]` from enum with manual impl
5. **List Clone bounds** - Functions need `T: Clone` bound
6. **println! macro** - Kernel calls need special handling (Log.println → println!)
7. **Unused imports** - Cleaned: Future, Pin, Context, Poll
8. **Syntax error** - Removed stray comma before `use std::fmt`

### Session 2 (fix issues round)
9.  **Lambda trailing empty string** - `|param, |` invalid syntax
10. **println! format string** - N `{}` for N args
11. **Cons pattern** - `"::"` invalid in pattern position → Rust slice pattern
12. **TRecord alias → struct** - `struct Name { ... }` instead of invalid `type Name = { ... }`
13. **Record literals** - Named struct syntax via field-set lookup
14. **Multi-module support** - `generateRust` receives all dep modules

### Session 3 (typed params + module prefix)
15. **Constructor names** - `Ctor` → `ModuleName_TypeName::CtorName`
16. **Typed function params** - `TypedDef` params emit `name: Type`
17. **Module prefix** - All types, functions, unions, aliases prefixed
18. **Pipeline operator `|>`** - Emitted as `f(x)` function call
19. **Cons operator `::`** - Emitted as `sky_list_cons(x, xs)`
20. **String concat `++`** - Emitted as `+`
21. **Rust keyword escaping** - `fn` → `r#fn`, etc.
22. **Slice pattern `_ @ ..`** - Fixed to emit `..` for unused tail
23. **FFI placeholder types** - Auto-generate `type X = String;`
24. **`sky_list_cons` runtime helper** - Added for cons operator

### Session 4 (return types + kernel stubs)
25. **Generics for `Def` params** - `T0, T1` instead of hardcoded `String`
26. **Kernel constructor mapping** - `Bool.True`→`true`, `Maybe.Just`→`SkyMaybe::Just`
27. **Kernel runtime stubs** - Task, System, Log, Db, String_join, Result_withDefault
28. **`#![allow(unused)]`** - Suppress dead_code warnings
29. **String literals** - `.to_string()` for `vec![]` compatibility
30. **Return type annotations** - `-> ReturnType` from TypedDef / solvedTypes
31. **`hasTypeVars` filter** - Prevents HM type variables leaking
32. **`sky_main` special case** - Always returns `()`
33. **Task type mapping fix** - Uses `SkyTask<E, A>` (generic error type)

### Session 5 (async runtime + known sigs + ctor types)
34. **Tokio runtime** - `Runtime::block_on` instead of custom spin-loop executor
35. **`Cargo.toml` generation** - tokio dependency, edition 2021
36. **Proper async combinators** - `async move` blocks for Task_map, Task_andThen, Task_onError
37. **`Task_parallel`** - Uses `tokio::spawn` for true concurrent execution
38. **`knownDefSig`** - Module-aware signatures for List, Maybe, Error modules (40+ functions)
39. **`as_slice()` wrapper** - Match scrutinee wrapped for Vec slice pattern support
40. **Thunk auto-invoke** - `(|| { expr })()` for `let _ = Task.run` discard pattern
41. **ADT ctor field types** - Uses actual types from `Can.Ctor` instead of `()` placeholders
42. **`format!` for `++`** - Fixes `String + String` compilation error

### Session 6 (Task error type unification)
43. **`SkyTask<A>` simplified** - Removed generic `E` parameter; `SkyError` hardcoded
44. **Conditional `SkyError`** - Points to `Sky_Core_Error_Error` when Error module present, `String` fallback
45. **`Task_onError`** - Uses concrete `SkyError` instead of generic `E`, ending type mismatch
46. **All stubs unified** - `System_args`, `Log_info`, `Db_connect` etc. now return `SkyTask<A>` (no `String` error parameter)
47. **`typeToRustString`** - Maps `Sky.Core.Error.Error` to `SkyError`; `Task e a` to `SkyTask<A>`
48. **`#[derive(Clone)]`** - Added to all generated enums and structs for ownership compatibility

### Session 7 (closure ownership — E0382/E0505/E0373 -95%)
49. **`LetDestruct` wildcard thunks** - `\_ -> body` treated as thunk (auto-invoked)  
    fixing `Pin<Box<dyn Future>>::clone` panic
50. **`collectVarLocalsMulti`** - Count-based variable tracking; only clone vars  
    used ≥ 2 times, avoiding non-Clone types like `Pin<Box<dyn Future>>`
51. **`defToRustString` clone injection** - Zero-arg Def wraps expression in  
    `{ let x = x.clone(); expr }` when `x` is used ≥ 2 times
52. **`collectVarLocals` walks defBody** - Fix: `Can.Let` now traverses both the  
    definition expression AND the continuation body
53. **`Can.Call` VarLocal clone** - Every function-call argument gets `.clone()`  
    except `Task_run` (avoids non-Clone Pipeline type)
54. **`IsWildcard` helper** - Correctly detects `PAnything` for thunk detection
55. **`branchToRustString`** - Injects `.clone()`/`.to_vec()` for cons/slice  
    pattern bindings (owned values from &T references)
56. **`scanTVars`** - Robust type variable scanner replacing ad-hoc extraction

### Session 8 (Def param types from solvedTypes, ecCloneVars)
57. **`extractParamTypes`** - Extract Def param types from HM-inferred types  
58. **Def params from solvedTypes** - `getArg: List String -> String` types  
    `argList: Vec<String>` instead of `SkyValue`
59. **`branchToRustString` zero-arg call** - `case arm => showUsage()`  
60. **`Db_query` stub** - Returns `SkyTask<Vec<String>>`
61. **`ecCloneVars`** - Per-use `.clone()` for multi-use vars inside `move`  
    closures (fixes `todoTitle` E0382, `e` use-after-move)
62. **Always `: Clone`** - Reverts faulty heuristic; all type vars get Clone  
    (pattern variables like `x` in `Just(x) => x.clone()` need it)

### Session 9 (zero errors — closure annotation, HashMap stubs, runtime)
63. **`ecPipeInnerType`** - EmitCtx field set by `|>` handler with the inner  
    type of the piped Task expression (fixes E0282)
64. **Lambda param type annotation** - `move |rows: Vec<String>| { ... }`  
65. **`taskExprInnerType`** - Helper mapping kernel calls to Task inner type  
66. **`typeToRustString Dict`** - Maps `Dict K V` → `HashMap<K, V>`  
67. **Db stubs** - `HashMap<String,String>` for rows, proper getField  
68. **`block_on` threading** - `std::thread::spawn` to avoid nested Runtime  
69. **`System_args` skip(1)** - Excludes binary path (matches Go behaviour)  
70. **`mainSig formatTodo`** - Explicit sig for `HashMap<String,String>` row

### Session 10 (zero warnings — `pub` types, `#[allow]` attributes)
71. **`#![allow(non_snake_case, non_camel_case_types)]`** - Suppresses Rust  
    naming convention warnings for module-prefixed Sky names
72. **`pub` on generated types** - All enums, structs, and aliases now emit  
    `pub enum` / `pub struct` / `pub type` (fixes "more private than item")

### Session 11 (sqlx backend-specific — AnyPool removed)
73. **Backend-specific sqlx** — `SqlitePool`/`PgPool`/`MySqlPool` directly, no `AnyPool`. Only one backend compiled.
74. **`build_sql`** — `?` placeholder replacement with escaped `'values'`. DB-agnostic.
75. **`row_to_map`** — `DbRow` → `HashMap<String,String>` with `&str` → `i64` → `f64` → empty fallback.
76. **`sky_err`** — Maps `sqlx::Error` to correct `SkyError` variant (Network/Io/Conflict/Timeout/Unavailable/Unexpected).
77. **`[database]` sky.toml** — `driver = "sqlite"` selects backend feature + prepends `sqlite:` prefix.

### Session 12 (conditional compilation — UsedKernels analyzer)
78. **`UsedKernels`** — `analyzeKernelUsage` walks all expressions collecting kernel usage (Db, Task.run, Task.parallel, Json).
79. **Conditional Cargo.toml** — tokio only when Task/Db used; sqlx only when Db used; serde_json only when Json.* used.
80. **Conditional runtime stubs** — Db/JSON/task_parallel sections emitted only when used.
81. **Hello-world: 0 external deps** — 0.33s build, no tokio/sqlx/serde_json.

### Session 13 (log attrs, extra kernels, else-if, Result ordering)
82. **`fmt_attrs`** — Formats `[k,v,k,v,…]` pairs as ` key=value` for structured logging.
83. **Extra kernel stubs** — Time, Random (LCG), File, Crypto, Http (all std-only except Http error stub).
84. **`else if` syntax** — `Can.If` emits `else if cond { }` not `else cond { }`.
85. **`SkyResult<E, A>` ordering** — Error-first, matching `Result e a` order (was swapped).

### Session 14 (println→log_info, ok_res, Debug derive, E0282 class closed)
86. **Println→log_info** — No more `println!` macro + ad-hoc Task wrapper. Routes through `log_info()` which returns `SkyTask<()>`.
87. **main return type conditional** — `SkyTask<()>` when no `Task.run` is used, `()` otherwise.
88. **`ok_res` helper** — `fn ok_res<A>(a: A) -> SkyResult<SkyError, A>`. Every runtime stub construction site uses it. E0282 class closed permanently.
89. **`#[derive(Clone, Debug)]`** — All generated enums and structs.

### Session 15 (anonymous record structs)
90. **`collectAnonRecordTypes`** — Walks all expressions finding inline records without type aliases.
91. **`__anon__` structs** — Synthetic `RStructDef` entries with `SkyValue`-typed fields. Record literals get `.to_string()` wrapping.

### Session 16 (backend-specific sqlx — AnyPool eliminated)
92. **`dbPoolType`/`dbRowType`** — Maps sky.toml driver to concrete sqlx types (SqlitePool/SqliteRow, etc.).
93. **No AnyPool** — No `install_default_drivers()`, no `any` feature flag. Only the selected backend compiled.

### Session 17 — Dead file deletion + batch bugfix from audit
94. **Dead files deleted** — 7 files (Decl, Expr, Kernel, Module, Pattern, Test, Types), 1192 lines removed from repo. Never compiled.
95. **LCG persistence** — `static AtomicU64` seeded once, not per-call. Eliminates duplicate "random" values.
96. **Real SHA-256** — `sha2` crate (gated on `usesCrypto`). Was `DefaultHasher` (64-bit SipHash, wrong).
97. **`task_run` error honoured** — `match block_on(...)` with `eprintln!` + `exit(1)` on error.
98. **`collectVarLocals` binds pattern vars** — Case/LetDestruct/LetRec register pattern-bound variables.
99. **`Can.Update` wrapped in `{ … }`** — valid in argument position.
100. **`Can.VarKernel` dot→underscore** — valid Rust identifier for all kernel names.
101. **`Can.PRecord` struct-name prefix** — `{ field }` → `StructName { field }` via record map.
102. **`extraKernelSection` gated** — Time/Random/File/Crypto only when touched.
103. **`sha2` dep** — only when `Crypto.*` imported.
104. **Dead `argToRust` removed** — diverged duplicate of inline closure logic.

### Session 18 — Def return type inference + System.setenv/unsetenv
105. **Def return type via body inference** — when `hasTypeVars ret` (polymorphic), fall back to `taskExprInnerType(body)`. `main_expensive_task` → `SkyTask<i64>`.
106. **`System.setenv`/`System.unsetenv`** — `std::env::set_var`/`remove_var` stubs. Analyzer sets `usesTaskRun` for System.*.
107. **`taskExprInnerType` System entries** — `setenv`/`unsetenv` return `"()"`.

### Session 19 — Inline-let optimization (Vec<SkyTask>.clone() fix)
108. **`substVar` walker** — Substitutes `VarLocal name` with inline `vec![...]` throughout expression tree.
109. **Inline-let in `Can.Let`** — When a let-bound variable is a `List` used ≥ 2 times, inline `vec![]` at each use site. Avoids `::clone()` on non-Clone elements.
110. **`simple` 0 errors** — Was blocked by `Vec<SkyTask>.clone()` (`Pin<Box<dyn Future>>` not Clone).

### Session 20 — 06-json: 138→43 errors, test_pkg 0 errors
111. **`resultSig`** — map, andThen, mapError, withDefault, map2-5, andMap, combine, traverse for Result module.
112. **Decoder `'static` bounds** — Added to json_dec_field, at, list, map, map2, succeed, fail.
113. **Synthetic record ctors** — Record aliases without matching Def get auto-generated constructor functions.
114. **Zero-arg VarTopLevel in println** — Added `()` for function references passed as values.

## Status

## Status

**Working**: 0 errors, 0 warnings:
- **01-hello-world**: 0 external deps, 0.4s build
- **04-local-pkg**: 0 external deps, 0.4s build (multi-module)
- **07-todo-cli**: tokio + sqlx-sqlite only, all CRUD operations work
- **14-task-demo**: tokio only, Task combinators + error messages
- **simple**: tokio only, task_sequence + task_parallel

**Known issues**:
- **06-json**: 43 errors (Fn/FnOnce/Send/Sync in Decoder<T> closures)
- **test_pkg**: 0 errors (resolved)
- `Success: Hello, Sky! Task is the effect boundary.`
- `Fail error: Unexpected: intentional`

## FFI Design Possibilities

The Rust target ships kernel-triggered external crates today (tokio, sqlx,
serde_json, sha2 — gated by `UsedKernels` flags in `Builder.hs`). There is
**no user-FFI path yet**: `sky.toml` has `[go.dependencies]` but no
`[rust.dependencies]`, and no Rust analogue of `tools/sky-ffi-inspect/`
exists. This section evaluates three architecturally distinct ways to ship
user-declared Rust crate bindings against the same criteria Sky's Go FFI
already meets: **security**, **soundness**, **efficiency**.

The Go FFI pipeline is the reference baseline (`sky add github.com/some/pkg`
→ inspector extracts types → compiler emits typed `.skyi` + wrapped Go
bindings → DCE prunes unused → user code calls them as if they were Sky
kernels; every wrapped call returns `Result Error T`; panics → `Err`;
nil-receivers → `Err`). Each option below differs in **what fills the
inspector role** and **what trust model wraps each symbol**.

### Option A — `rustdoc-JSON` inspector + generated wrapper crate

Direct mirror of the Go pipeline. Spawns `cargo doc --output-format=json`
per declared dep, parses [rustdoc-types](https://docs.rs/rustdoc-types)
to extract fn sigs / struct fields / impl methods / generics, emits a
`<crate>_bindings.rs` wrapper module exposing `sky_<crate>_<fn>`-shaped
functions returning `SkyResult<SkyError, T>`. Every wrapper wraps the
real call in `std::panic::catch_unwind`; opaque types stored as `Arc<T>`.

- **Security**: ambient — same as the host process. A hostile dep can
  call `unsafe`, read files, leak addresses. `catch_unwind` is the
  only enforced floor. No capability boundary.
- **Soundness**: strong on type-shape (rustdoc-JSON is rustc's own
  output); weak on lifetimes (cloned-by-default, same as Go's
  pointer handling). Drift is detected loud at next `sky install`.
- **Efficiency**: per-call `catch_unwind` (~3 ns) + 1 SkyResult
  alloc; binary size ≈ 50-200 bytes per wrapped symbol after Sky's
  DCE prunes unreached refs. `cargo doc` is heavy cold (30-60 s on
  Stripe-scale); a `.skycache/rustdoc/<crate>-<version>.json` cache
  brings warm regen to ~1 s.
- **Risks**: rustdoc-JSON is nightly-only today (RFC 2963; stable
  targeted late 2026). Mitigation: pin a nightly rustc for the
  inspector, or fall back to `syn`-based source parsing.
- **Fit**: shippable in the 1-year window (~6-8 weeks for inspector
  + ~3 weeks for wrapper-crate emitter + ~2 weeks for sky.toml
  schema + lockfile). Works with arbitrary crates. Maps 1:1 to the
  Go target's mental model and reuses every Sky-side FFI piece
  already written (`Dce.reachableWholeProgram`,
  `Env.ffiKernelTypeRef`, `loadAndSeedFfiRegistry`).

### Option B — Procedural macros + traits, zero-cost dispatch

Define `SkyExportable` / `SkyImportable` traits in a published
`sky-ffi` crate. Crate authors (or Sky-community wrapper-crate
maintainers) apply `#[sky_export(module = "image", effect = "task")]`
to functions they want exposed. The proc macro emits both a typed Rust
shim AND a `target/sky-meta/<crate>.json` manifest. Sky's compiler reads
the manifest instead of running rustdoc.

- **Security**: ambient (same as A) unless paired with a sandbox.
  Macro can enforce `Result<T, E: Into<SkyError>>` → no implicit
  error stringification. Capability annotations possible
  (`reads = ["filesystem"]`).
- **Soundness**: **strongest of the three**. The conversion code
  lives in the Rust source where rustc enforces it. No JSON-schema
  drift, no rustdoc-version skew. Lifetime-aware (macro sees
  `&self`, `&'a Foo`, `&mut T` directly).
- **Efficiency**: **zero-cost in the common case**. Shim is
  `#[inline]`-eligible. No `.into()` chain through generic
  adapters. Cargo-speed build (no rustdoc invocation).
  Per-symbol binary cost lower than A.
- **Risks**: requires upstream cooperation OR Sky-community
  wrapper crates (`image-sky`, `tokio-sky`, etc.). Niche crates
  without a `*-sky` wrapper force users back to writing Rust —
  violates "users never write FFI". Needs the stable `sky-ffi`
  crate published BEFORE wrappers can target it (~3-month
  sub-project before viable).
- **Fit**: not day-1. Right call as a layered v2 for hot kernels
  (crypto, image, ML) where catch_unwind cost shows up in
  benchmarks.

### Option C — WASM Component Model + WIT-driven bindings

Use [WIT (WebAssembly Interface Types)](https://component-model.bytecodealliance.org/design/wit.html)
as the IDL. Each FFI crate compiled to a WASM component via `cargo
component build`. Sky's compiler reads the `.wit` file to derive
`.skyi`. On native targets, wasmtime instantiates components and
Sky-host calls cross the canonical ABI. On the WASM target,
component composition links wasm-to-wasm at build time (zero VM
overhead).

- **Security**: **strongest by a wide margin**. Components run in
  a WASM sandbox; no syscalls except those granted via WASI
  capabilities. Memory isolation by construction (canonical ABI
  copies, not pointers). Supply-chain risk minimised; untrusted
  plugins loadable at runtime with explicit capability lists.
  Aligns with Sky's broader capability-first design.
- **Soundness**: WIT is the single source of truth — both Sky and
  the Rust component read it. Drift is impossible by construction.
  WIT's type system (records, variants, lists, results, options,
  **resources**) maps directly onto Sky's HM. Resource types
  model opaque handles cleanly — better fit for Sky's opaque-type
  conventions than rustdoc's `pub struct + impl` shape.
- **Efficiency**: **WASM target zero-cost** (component
  composition at link time; per-call ~3-5 ns). **Native target
  real overhead** (wasmtime VM ~5-10 ms startup, ~30-100 ns
  per-call + canonical-ABI serialise). Acceptable for app code;
  problematic for hot kernels (mitigation: hot kernels stay
  native, only user-FFI goes through components).
- **Risks**: not all Rust crates compile to WASM components
  (libc, raw sockets outside WASI preview2, platform-specific
  code excluded). Tooling immaturity (`cargo component`, WIT
  stabilising through 2026). Component-aware ecosystem is tiny
  today.
- **Fit**: best long-term security + WASM story; aligns with
  stated WASM priority. **Not day-1 viable** — ecosystem + tooling
  is a year-plus journey on its own.

### Comparison

| Criterion | A (rustdoc) | B (proc-macro) | C (WASM components) |
|---|---|---|---|
| Security blast radius | Native process | Native process | **Sandboxed (WASI)** |
| Memory isolation | No | No | **Yes** |
| Type-drift detection | Re-derive at install | rustc at macro site | WIT single source |
| Lifetime/borrow fidelity | Lost (clone) | **Preserved** | N/A (ABI copies) |
| Per-call cost (native) | catch_unwind (~3 ns) | **Inlined, ~0 ns** | wasmtime (~30-100 ns) |
| Per-call cost (WASM) | identical to native | identical to native | **wasm call (~5 ns)** |
| Build-time cost | cargo doc per crate | proc-macro expansion | cargo component per crate |
| Works with arbitrary crates | **Yes** (modulo nightly) | No (needs wrappers) | Partial (non-WASM excluded) |
| 1-year shippable | **Yes** (~3 months) | Partial (sky-ffi + wrappers) | No (ecosystem) |
| Aligns with Go FFI mental model | **Direct mirror** | Different idiom | Different idiom |

### Recommended sequencing

**Ship A as v1 in the 1-year window. Plan C as v2. Hold B for
performance-critical hot paths only.**

1. A is the only day-1 option meeting "Rust-native FFI mandatory
   from day 1" + "works with arbitrary crates" + 1-year timeline.
   Reuses every Sky-side FFI piece already written for Go.
2. C is the right long-term security model and aligns with the
   WASM-first stack. Design the WIT-equivalent of `Result Error T`
   in parallel with shipping A, so when component tooling stabilises
   the migration path is "wrap each existing native dep in a
   component" rather than "redesign the FFI surface". The two
   coexist: native deps through A, sandboxed deps (plugins,
   untrusted code) through C.
3. B's zero-cost story is real but its ecosystem story isn't.
   Reserve it for a small set of Sky-maintained `sky-ffi-<X>`
   wrappers around perf-critical kernels (crypto, image, ML)
   where catch_unwind cost shows up in benchmarks. Don't bet
   the FFI surface on it.

Critical files for the v1 (Option A) implementation:

| Path | Change |
|---|---|
| `tools/sky-ffi-inspect-rs/` | NEW — rustdoc-JSON inspector (mirror of `tools/sky-ffi-inspect/main.go` shape) |
| `src/Sky/Build/FfiGenRust.hs` | NEW — mirror of `FfiGen.hs`; reuses `classifyEffect`, kernel-registry, DCE |
| `src/Sky/Build/Compile.hs` | Dispatch `loadAndSeedFfiRegistry` to FfiGenRust when `--target rust` |
| `src/Sky/Generate/Rust/Builder.hs` | Merge user `[rust.dependencies]` into emitted Cargo.toml; skip-emit symbols defined in `<crate>_bindings.rs` |
| `runtime-rust/src/lib.rs` | DELETE or formalise as single source of truth (currently divergent — see BUGFIX-PLAN.md §A) |
| `sky.toml` schema | NEW `[rust.dependencies]` table; new `sky-rust.lock` for content-hash pinning |

Verification: smoke test (`sky init` → declare `image = "0.24"` →
build clean), soundness regression (6 currently-green examples stay
green; 06-json reaches 12/12), DCE check (Stripe-sized crate using
3 symbols emits ~3 wrappers), cross-target parity (diff stdout vs
`--target go`), WASM build (`cargo build --target wasm32-wasi`),
BUGFIX-PLAN F-section closure + B.1.3/4/5/6/7 + B.1.14/15.

## Next Steps

### Known limitations (no fix planned short-term)
1. Anonymous records lose type precision (SkyValue/String only)
2. JSON decoder lifetimes (06-json): ∼139 `Fn`/`FnOnce`/lifetime errors in `Decoder<T>`
3. Def return type inference (simple/test_pkg): Task-returning Def functions with wrong ret type
4. Separate module files (`mod` declarations instead of flat `main.rs`)
5. `System.setenv` / `System.unsetenv`

### Longer term
- Sky.Http.Server (axum backend)
- Sky.Live (server-driven UI)
- Benchmark `task_parallel` vs Go goroutines

## Technical Notes

- **Rust naming convention** (non-negotiable): All generated Rust code MUST follow
  [Rust API naming guidelines](https://rust-lang.github.io/api-guidelines/naming.html).
  Types use `CamelCase` (`SkyCoreErrorError`), functions use `snake_case` (`task_map`).
  The `toCamelCase`/`toSnakeCase` helpers in Builder.hs enforce this. Sky source
  variable names (`todoTitle`) retain their CamelCase form under `#![allow(non_snake_case)]`.
- `ModuleName.Canonical` wraps a single `String`, not a list (`ModuleName._name` field)
- `Ann.At` is the data constructor for located AST nodes (not `A.Located`)
- Kernel calls: `Log.println` → `log_info` (routes through Task-returning runtime stub), other kernels use `module_name` convention
- Go remains the default target when no `--target` is specified
- Rust output directory: `sky-out/Rust/` (with `src/main.rs` + `Cargo.toml`)
- Compile with: `cd sky-out/Rust && cargo run` (requires Rust edition 2021); first build downloads ~180 crates for sqlx + tokio
- The Go and Rust codegen paths share the same frontend (parse, canonicalise, type-check)

## Testing

## License

Apache 2.0 (same as Sky compiler)
