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
| Type mapping | ✅ Basic types (String, Int, Float, Bool, List, Maybe, Result) |
| Union/ADT handling | ✅ Pattern matching → match expressions |
| Type aliases (non-record) | ✅ Emitted as `type X = ...` |
| Record aliases | ✅ Emitted as `struct X { ... }` |
| Record literals | ✅ Named struct syntax via field-set lookup |
| Multi-module projects | ✅ All dep modules included in output |
| Cons pattern | ✅ Valid Rust slice pattern `[head, tail @ ..]` |
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

## Known Issues (Next Steps)

1. **Untyped function parameters** - Parameters lack type annotations (`fn foo(x)` instead of `fn foo(x: String)`). Need to thread `solvedTypes` through expression emitter
2. **Constructor placeholder** - `Can.VarCtor{}` emits `"Ctor"` instead of actual ADT constructor name
3. **Type information for record field access** - Destructured patterns lack proper field name resolution for nested access

## Next Steps

### Priority 1: Basic Completeness
1. Thread type information from `solvedTypes` through expression emission for typed parameters
2. Proper ADT constructor name emission (replace `"Ctor"` placeholder)
3. Rust-native pattern matching for ADTs (use fully qualified `Enum::Variant` syntax)

### Priority 2: Type System
4. Proper generic type parameter handling in struct/enum definitions
5. Record field access with proper scope (destructured pattern bindings)
6. Full ADT handling with type-safe constructors

### Priority 3: FFI
7. Rust crate FFI (direct calls to Rust libs)
8. WASM target support

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