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
| `--target rust` flag | ✅ Wired into CLI |
| Cargo.toml generation | ✅ Auto-generated with tokio dependency |
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

### Phase 3: FFI System (Next)
Priority crates: tokio, serde, uuid, axum, clap, rayon, reqwest, sqlx, tokio-postgres

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

### Session 8 (Def param types from solvedTypes, final fixes)
57. **`extractParamTypes`** - Extract Def param types from HM-inferred types  
    (replaces `bodyUsesList` heuristic for functions with resolved types)
58. **Def params from solvedTypes** - `getArg: List String -> String` now  
    properly types `argList: Vec<String>` instead of `SkyValue`
59. **`branchToRustString` zero-arg call** - `case arm => showUsage` now emits  
    `Main_showUsage()` instead of just `Main_showUsage`
60. **`Db_query` stub** - Returns `SkyTask<Vec<String>>` instead of  
    `SkyTask<Vec<Vec<String>>>` (matches row access pattern)
61. **`noCloneFn` filter** - Skips `.clone()` for `Task_run` (avoids non-Clone  
    `Pin<Box<dyn Future>>`); `isEmpty` now gets `.clone()` for ownership

## Known Issues (Root Causes)

### Remaining: 2 errors in todo-cli
- **1 E0282**: `Task_map(move |rows| { ... rows.clone() ... })` — the first  
  use `isEmpty(rows.clone())` produces `Vec<T0>` where `T0` can't be inferred  
  through the `move` boundary. Fix: pass `&rows` instead of `rows.clone()`.
- **1 E0382**: `todoTitle` used twice inside a `move` closure — the pre-clone  
  at the closure start is consumed by `vec![..., todoTitle]`; the second use  
  `println!(todoTitle)` can't access it. Fix: per-use `.clone()`.

### Root cause
Both stem from the same pattern: a `move` closure body uses a variable ≥ 2  
times. The first use moves it, the second fails. Fix requires body-rewriting  
to inject `.clone()` at each `VarLocal` occurrence inside `move` closures.

## Next Steps

### Priority 1: Per-use clone inside `move` closures
Walk the closure body AST and inject `.clone()` before each `VarLocal` use  
when the variable is used ≥ 2 times inside the same closure.

### Priority 2: Production Readiness
2. CamelCase type names (eliminate cosmetic warnings)
3. Separate module files (`mod` declarations instead of flat file)
4. Benchmark Task_parallel vs Go goroutines

## Technical Notes

- `ModuleName.Canonical` wraps a single `String`, not a list (`ModuleName._name` field)
- `Ann.At` is the data constructor for located AST nodes (not `A.Located`)
- Kernel calls: `Log.println` → `println!`, other kernels use `module_name` convention
- Go remains the default target when no `--target` is specified
- Rust output directory: `sky-out/Rust/` (with `src/main.rs` + `Cargo.toml`)
- Compile with: `cd sky-out/Rust && cargo run` (requires Rust edition 2021)
- The Go and Rust codegen paths share the same frontend (parse, canonicalise, type-check)

## Testing

- **Hello-world**: ✅ Compiles and runs ("Hello from Sky!")
- **Go target (default)**: ✅ All examples pass
- **todo-cli Rust**: ❌ 107 E0308 errors (Task error type unification needed)

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
