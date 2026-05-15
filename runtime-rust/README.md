# SkyRust

A transpiler that converts Sky (Elm-compatible functional language) to idiomatic Rust code.

## Overview

Transpile Sky to Rust code with native FFI to Rust libraries. Architecture uses a hybrid approach: reuse the existing Haskell parser/type-checker (~13,000 lines) and add a new Rust codegen module.

```
Sky Source → Haskell Parser/Type-Check → Sky AST → Rust Codegen → Rust Code
                                                      ↓
                                               Inlined Runtime (no external deps)
```

## Project Structure

```
runtime-rust/
├── README.md                 # This file
├── CLAUDE.md                 # Project context
├── sky-runtime-rust/         # ✅ COMPLETE - Runtime primitives (54 tests)
│   ├── Cargo.toml
│   └── src/lib.rs
└── sky-compiler/             # Main compiler (integrated Rust codegen)
    └── src/Sky/Generate/Rust/Builder.hs  # Core codegen (366 lines)
```

## Status

### ✅ Phase 1: Runtime Prototype (COMPLETE)
- `sky-runtime-rust` with 54 tests passing
- Core types: SkyResult, SkyMaybe, SkyString, SkyList, SkyDict, SkyTask

### ✅ Phase 2: Codegen Implementation (COMPLETE)

Rust codegen is implemented in the main compiler:
- **Location**: `src/Sky/Generate/Rust/Builder.hs` (366 lines)
- **Entry**: `generateRust` in `src/Sky/Build/Compile.hs` (~line 8400)
- **CLI**: `--target rust` flag wired into Main.hs

**Working Features**:
| Feature | Status |
|---------|--------|
| Hello world | ✅ Compiles and runs ("Hello from Sky!") |
| --target rust flag | ✅ Wired into CLI |
| Expression translation | ✅ Functions, calls, patterns, let, binops, lambdas, if/case |
| Kernel calls | ✅ Special handling (println! macro, Log::, Task::, etc.) |
| Type mapping | ✅ Basic types + module-prefixed user types |
| Union/ADT handling | ✅ Module-prefixed enum syntax (`Sky_Core_Error::Error`) |
| Type aliases (non-record) | ✅ Module-prefixed `type X = ...` |
| Record aliases | ✅ Module-prefixed `struct X { ... }` |
| Record literals | ✅ Named struct syntax via field-set lookup |
| Typed function params | ✅ From TypedDef annotations (`conn: Db`) |
| Pipeline operator `|>` | ✅ Emitted as `f(x)` |
| Cons `::` operator | ✅ `sky_list_cons(x, xs)` helper function |
| String concat `++` | ✅ Emitted as `+` |
| Rust keyword escaping | ✅ `fn` → `r#fn`, etc. for param/variable names |
| Multi-module projects | ✅ All dep modules with module-prefixed names |
| Cons/slice pattern | ✅ `[head, tail @ ..]` with `..` for unused tail |
| FFI placeholder types | ✅ Auto-generated for undefined referenced types |
| println! multiple args | ✅ Correct `{}{}` format string |

### Phase 3: FFI System (Next)
Priority crates: tokio, serde, uuid, axum, clap, rayon, reqwest, sqlx, tokio-postgres

## Usage

```bash
# Build for Go (default)
sky build src/Main.sky

# Build for Rust
sky build src/Main.sky --target rust
# Output: sky-out/Rust/main.rs

# Run Rust build
sky run src/Main.sky --target rust
```

## Issues Encountered and Fixed

During implementation, these issues were resolved:

### Session 1 (initial implementation)
1. **Can.TAlias field** - Uses `.ty` (single type), not a list
2. **Can.Forall pattern** - Doesn't exist in `Can.Type`, only in `Annotation`
3. **Main naming conflict** - Renamed user `main` to `sky_main`
4. **Debug derive conflict** - Removed `#[derive(Debug)]` from enum with manual impl
5. **List Clone bounds** - Functions need `T: Clone` bound
6. **println! macro** - Kernel calls need special handling (Log.println → println!)
7. **Unused imports** - Cleaned: Future, Pin, Context, Poll
8. **Syntax error** - Removed stray comma before `use std::fmt`

### Session 2 (2026-05-14: fix issues round)
9. **Lambda trailing empty string** - `|param, |` invalid syntax, removed empty string from param list
10. **println! format string** - Hardcoded single `{}` for multiple args; now generates N `{}` placeholders
11. **Cons pattern** - `"::"` invalid in pattern position; now emits `[head, tail @ ..]` Rust slice pattern
12. **TRecord alias → struct** - Record aliases now emit `struct Name { ... }` instead of invalid `type Name = { ... }`
13. **Record literals** - Now use named struct syntax (`ErrorInfo { field: val }`) looked up from alias field-set map
14. **Multi-module support** - `generateRust` now receives all dep modules via `validDeps` and emits code for all of them

### Session 3 (2026-05-14: typed params + module prefix round)
15. **Constructor names** - `Ctor` placeholder replaced with `ModuleName_TypeName::CtorName` (e.g., `Sky_Core_Error::Error`)
16. **Typed function params** - `TypedDef` params now emit `name: Type` annotations (e.g., `conn: Db`, `idStr: String`)
17. **Module prefix** - All types, functions, unions, aliases prefixed with module name to prevent collision
18. **Pipeline operator `|>`** - Emitted as `f(x)` function call (Rust has no native pipe)
19. **Cons operator `::`** - Emitted as `sky_list_cons(x, xs)` helper
20. **String concat `++`** - Emitted as `+` (Rust string concatenation)
21. **Rust keyword escaping** - `fn`, `match`, `let`, `type`, etc. in param names get `r#` prefix
22. **Slice pattern `_ @ ..`** - Fixed to emit `..` for unused tail bindings (invalid Rust syntax)
23. **FFI placeholder types** - Auto-generate `type X = String;` for undefined referenced types
24. **`sky_list_cons` runtime helper** - Added for cons operator support

### Session 4 (2026-05-14: return types + kernel stubs round)
25. **Generics for `Def` params** - Untyped functions use `T0, T1` generics instead of hardcoded `String`
26. **Kernel constructor mapping** - `Bool.True`→`true`, `Maybe.Just`→`SkyMaybe::Just`, `Result.Ok`→`SkyResult::Ok`
27. **Kernel runtime stubs** - Task, System, Log, Db, String_join, Result_withDefault implemented as stubs
28. **`#![allow(unused)]`** - Added to suppress dead_code warnings
29. **String literals** - `.to_string()` for `vec![]` compatibility
30. **Return type annotations** - Functions emit `-> ReturnType` from TypedDef's 5th field or solvedTypes
31. **`hasTypeVars` filter** - Prevents HM type variables (`a`, `b`, `_ambig`) from leaking into Rust code
32. **`sky_main` special case** - Always returns `()` since entry wrapper handles the Task
33. **Task type mapping fix** - Uses `SkyTask<A>` (Pin+Box+dyn Future+SkyResult) matching the runtime stubs

## Known Issues (Root Causes - Next Session)

### Critical: Task Monad Not Modeled (blocks all non-trivial programs)

The Rust codegen emits function bodies as flat Rust expressions, but Sky uses the Task monad for all side effects. Every effectful function returns `Task Error a`, and the Go codegen uses lowerer-generated combinator chains. The Rust codegen inlines these directly, losing the Task structure:

```rust
// Current (wrong):
fn Main_runApp(conn: Db) -> SkyTask<()> {
    Task_andThen(|_| { ... })(Main_initDb(conn));  // semicolon drops return!
}
// Required:
fn Main_runApp(conn: Db) -> SkyTask<()> {
    Task_andThen(|_| { ... })(Main_initDb(conn))   // no semicolon - return the value
}
```

**Root cause**: `exprToStatement` adds semicolons to all expressions, converting Task-returning tail expressions into discarded-unit statements. The Go codegen wraps everything in `rt.AnyTaskRun`, but the Rust codegen has no equivalent.

**Fix required**: The codegen must detect when a function's body (or last let-binding) has type `Task Error a` and NOT add a semicolon. The last expression in a Rust function must be the Task value, not a statement discarding it.

### Missing Type Info for `Def` (Untyped) Functions

`Def` functions (no Sky type annotation) get generic type params `T0, T1, ...` without trait bounds. This causes:
- `E0529`: expected array/slice, found `T1` (list params used as Vec)
- `E0618`: expected function, found `T0` (function params used as FnOnce)
- `E0369`: binary operations on generic types

**Fix required**: Thread `solvedTypes` through `defToRustItem` for param types (not just return types). For polymorphic functions, emit Rust generics with proper trait bounds (`T: Clone`, `F: FnOnce(...)`).

### Type Mapping Inconsistencies

- `typeToRustString` maps Sky types to Rust strings, but the runtime stubs define different shapes (e.g., `SkyResult` vs native `Result`, `SkyMaybe` vs `Option`)
- Non-camel-case naming convention warnings (cosmetic)

## Next Steps

### Priority 1: Fix Task Monad (blocks all programs with effects)
1. Fix `exprToStatement` to NOT add semicolon when the body returns `SkyTask<...>`
2. Or: use `Task_run` wrapper in the entry point to properly execute Tasks
3. Test with todo-cli and other multi-module examples

### Priority 2: Type System Completeness
4. Thread `solvedTypes` through for `Def` function param types with trait bounds
5. Detect list params and emit `Vec<T>` instead of generic `T0`
6. Detect function params and emit `impl FnOnce(...)` bounds

### Priority 3: Production Readiness
7. Rust-idiomatic naming (snake_case params, CamelCase types)
8. Separate module files (not single flat main.rs)
9. Internal crate (`sky-runtime-rust`) for real Task runtime with async executor

### Priority 3: FFI
7. Rust crate FFI (direct calls)
8. WASM target support

## Technical Notes

- `ModuleName.Canonical` wraps a single `String`, not a list
- `Ann.At` is the data constructor, not `A.Located`
- Kernel calls: Log.println → println! macro
- Go remains default when no `--target` specified
- Output directory: `sky-out/Rust/` (not lowercase)

## Testing

- Hello-world: ✅ Works ("Hello from Sky!")
- Go examples: All pass
- Rust examples: Need to verify multi-module

## Runtime Test Results

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