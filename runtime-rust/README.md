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

## Known Issues (Root Causes)

### Critical: Task Error Type Inconsistency (blocks todo-cli)

**Symptom**: 107 E0308 (mismatched types) in todo-cli. All from `Task_onError`, `Task_andThen`, etc. where the caller's error type doesn't match the function's error type.

**Root cause**: The Task runtime stubs use `String` as the Task's error type (`SkyTask<String, A>`), but:
- Typed Error module functions have return type `SkyTask<Sky_Core_Error_Error, A>` (because `typeToRustString` maps `Sky.Core.Error.Error` to `Sky_Core_Error_Error`)
- `Task_onError`'s generic error param `E` must unify BOTH the callback's and the task's error type
- When `Task_onError(reportError)` is called: `reportError` takes `Sky_Core_Error_Error` but the stub Tasks use `String`

**Fix required**: Use a SINGLE unified error type for ALL Task operations. Either:
- (a) Make ALL Tasks use `Sky_Core_Error_Error` as the error type (requires defining it even when Error module isn't imported)
- (b) Make ALL Tasks use `String` and make `typeToRustString` map ALL error types to `String`
- (c) Define `SkyError` as a configurable type alias

### `String ++ &str` Edge Cases

The `format!` fix handles `String + String`, but `String + &str` (through the `+` operator for non-`++` binops) can still fail when both operands are owned `String`s. The _ operator table needs `Add<&str>` considerations.

### Non-CamelCase Naming

Module-prefixed names like `Sky_Core_Error_ErrorKind` generate Rust warnings. Fix would require CamelCase conversion (`SkyCoreErrorErrorKind`).

## Next Steps

### Priority 1: Fix Task Error Type Unification
1. Define `type SkyError = String;` and use `SkyTask<SkyError, A>` in ALL stubs and type mappings
2. In `typeToRustString`, map `Task [e, a]` to `SkyTask<SkyError, ` ++ typeToRustString a ++ ">"`
3. Change stub System/Log/Db functions to use `SkyTask<SkyError, A>` instead of `SkyTask<String, A>`
4. Test with todo-cli - should eliminate ~100 E0308 errors

### Priority 2: Thread solvedTypes for Def Param Types
5. Pass `solvedTypes` through for `Def` function PARAM types (not just return types)
6. Detect list/function usage and emit proper trait bounds
7. Remove `knownDefSig` hardcoding once generic type threading works

### Priority 3: Production Readiness
8. CamelCase type names (cosmetic warnings)
9. Separate module files (`mod` declarations instead of flat file)
10. Benchmark Task_parallel vs Go goroutines

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
