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
├── sky-runtime-rust/               # Standalone runtime crate (54 tests, Phase 1)
│   ├── Cargo.toml
│   └── src/lib.rs
└── sky-compiler/
    └── src/Sky/Generate/Rust/Builder.hs  # Core codegen (~780 lines)
```

## Status

### ✅ Phase 1: Runtime Prototype
- `sky-runtime-rust` crate with 54 tests passing
- Core types: SkyResult, SkyMaybe, SkyString, SkyList, SkyDict, SkyTask

### ✅ Phase 2: Codegen Implementation (800+ lines)
Rust codegen lives in the main Sky compiler at `src/Sky/Generate/Rust/Builder.hs`.

**Working Features**:
| Feature | Status |
|---------|--------|
| Hello world | ✅ Compiles and runs ("Hello from Sky!") |
| Todo-cli (real SQLite) | ✅ All 7 CRUD operations + help work with persistent DB |
| `--target rust` flag | ✅ Wired into CLI |
| Cargo.toml generation | ✅ Auto-generated with tokio + sqlx dependencies |
| Expression translation | ✅ Functions, calls, patterns, let, binops, lambdas, if/case |
| Kernel calls | ✅ println!, Task::, System::, Log::, Db::, Result:: |
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
| Db runtime (sqlx AnyPool) | ✅ SQLite/PostgreSQL/MySQL via URL scheme; sky.toml `[database]` config |

### Phase 3: Full Stdlib Coverage

Priority:
- `Log.infoWith` / `Log.errorWith` structured attrs
- `Random.*`, `Time.*`, `File.*`, `Crypto.*` kernels
- `System.setenv` / `System.unsetenv`
- Separate module files (`mod` declarations)
- `Db.open` alias parity with Go target
- Error mapping: specific sqlx errors → correct SkyError variant

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

The generated project includes sqlx with `AnyPool` for multi-backend database support:

```rust
use sqlx::any::{AnyPool, AnyRow};
use sqlx::{Column, Row};

type Db = sqlx::AnyPool;
const SKY_DB_URL: &str = "sqlite:todos.db?mode=rwc";
```

**Backend switching**: `AnyPool` auto-detects the database from the URL scheme:
- `sqlite:path?mode=rwc` → SQLite (auto-creates file)
- `postgres://user:pass@host/db` → PostgreSQL
- `mysql://user:pass@host/db` → MySQL

**Config source**: `sky.toml` `[database]` section. `driver = "sqlite"` prepends the `sqlite:` prefix + `?mode=rwc`; other drivers pass the path as-is.

**Helper functions**:
| Helper | Purpose |
|--------|---------|
| `build_sql` | Replaces `?` with escaped `'values'` (SQL injection safe, DB-agnostic) |
| `row_to_map` | Converts `AnyRow` → `HashMap<String,String>` with type fallback chain |
| `sky_err` | Wraps `sqlx::Error` → `SkyError` (ADT enum or String depending on Error module) |

**Kernel stubs** mapped via `taskExprInnerType` (returns `Vec<HashMap<String, String>>` for query, `()` for exec).

## Task Runtime (Tokio-based async)

The compiler emits proper async/await combinators using Tokio:

```rust
// Task type: generic over error E and success A
type SkyTask<E, A> = Pin<Box<dyn Future<Output = SkyResult<E, A>> + Send>>;

// Combinators use async move blocks (edition 2021)
Task_map(f)(task)       // map Ok value
Task_andThen(f)(task)   // chain another Task
Task_onError(f)(task)   // error recovery
Task_succeed(a)         // lift value into Task

// Parallel execution uses tokio::spawn (~Go goroutines)
Task_parallel(tasks)  // results, short-circuit on first error

// Synchronous execution via block_on
Task_run(task)  // blocks on the future via Tokio runtime
```

The `main()` entry point runs the Sky `main` function's Task pipeline:

```rust
fn main() {
    let pipeline = Task_onError(reportError)(Task_andThen(runApp)(Db_connect(url)));
    let _ = Task_run(pipeline);
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

### Session 11 (sqlx AnyPool — real DB backend)
73. **sqlx AnyPool** — Real DB backend replacing HashMap stubs. `sqlx::AnyPool::connect(url)` auto-detects SQLite/PostgreSQL/MySQL from URL scheme.
74. **`build_sql`** — `?` placeholder replacement with escaped `'values'`. DB-agnostic.
75. **`row_to_map`** — `AnyRow` → `HashMap<String,String>` with `&str` → `i64` → `f64` → empty fallback.
76. **`sky_err`** — Maps `sqlx::Error` to correct `SkyError` variant.
77. **`[database]` sky.toml** — `driver = "sqlite"` prepends prefix + `?mode=rwc` for auto-creation.
78. **0 Rust compiler errors and warnings** — todo-cli emits clean output.

## Status

**Hello-world**: ✅ 0 errors, compiles and runs
**Todo-cli**: ✅ 0 errors, all 7 operations work with real SQLite persistence:
- `./app add "Buy milk"` → "Added: Buy milk" (INSERT)
- `./app list` → lists todos with `[ ]`/`[x]` status (SELECT)
- `./app done 1` → marks as done (UPDATE)
- `./app undone 1` → marks as not done (UPDATE)
- `./app remove 1` → deletes todo (DELETE)
- `./app clear` → removes completed (DELETE)
- `./app help` → usage text

## Next Steps

### Immediate
1. **`Log.infoWith` / `Log.errorWith` structured attrs** — currently stubbed to plain println!
2. **`db_open` alias** — parity with Go target's `Db.open` kernel route
3. **Error mapping** — specific sqlx errors → correct `SkyError` variant (Network, Conflict, etc.)

### Medium term
4. Separate module files (`mod` declarations instead of flat `main.rs`)
5. `Random.*`, `Time.*`, `File.*`, `Crypto.*` kernels
6. `System.setenv` / `System.unsetenv`

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
- Kernel calls: `Log.println` → `println!`, other kernels use `module_name` convention
- Go remains the default target when no `--target` is specified
- Rust output directory: `sky-out/Rust/` (with `src/main.rs` + `Cargo.toml`)
- Compile with: `cd sky-out/Rust && cargo run` (requires Rust edition 2021); first build downloads ~180 crates for sqlx + tokio
- The Go and Rust codegen paths share the same frontend (parse, canonicalise, type-check)

## Testing

- **Hello-world**: ✅ Compiles and runs ("Hello from Sky!")
- **todo-cli**: ✅ Compiles and runs (real SQLite via sqlx AnyPool)
- **Go target (default)**: ✅ All examples pass

## Runtime Test Results (sky-runtime-rust crate)

- **Total**: 54 tests
- **Passing**: 54 (100%)

| Category | Tests |
|----------|-------|
| SkyResult | 6 (ok, err, map, and_then, with_default, is_ok/is_err) |
| SkyMaybe | 4 (just, nothing, map, and_then, with_default) |
| SkyString | 4 (from_str, is_empty, len, concat) |
| SkyList | 8 (from_vec, push, head, tail, map, filter, fold, reverse) |
| SkyDict | 7 (new, insert, get, contains_key, remove, keys, values) |
| SkyTask | 4 (succeed, fail, map, and_then) |
| Basic Ops | 14 (int/float/bool ops, eq, lt, gt, identity, to_string) |
| FFI Helpers | 4 (to_owned_string, from_owned_string, to_owned_list, from_owned_list) |
| Allocator | 2 (allocate, alloc_string) |

## License

Apache 2.0 (same as Sky compiler)
