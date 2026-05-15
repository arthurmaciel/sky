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
| Hello world | ✅ Compiles and runs |
| --target rust flag | ✅ Wired into CLI |
| Expression translation | ✅ Functions, calls, patterns, let, binops |
| Kernel calls | ✅ Special handling (println! macro) |
| Type mapping | ✅ Basic types (String, Int, Float, Bool) |
| Union/ADT handling | ✅ Pattern matching → match expressions |

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

1. **Can.TAlias field** - Uses `.ty` (single type), not a list
2. **Can.Forall pattern** - Doesn't exist in `Can.Type`, only in `Annotation`
3. **Main naming conflict** - Renamed user `main` to `sky_main`
4. **Debug derive conflict** - Removed `#[derive(Debug)]` from enum with manual impl
5. **List Clone bounds** - Functions need `T: Clone` bound
6. **println! macro** - Kernel calls need special handling (Log.println → println!)
7. **Unused imports** - Cleaned: Future, Pin, Context, Poll
8. **Syntax error** - Removed stray comma before `use std::fmt`

## Known Issues (Next Steps)

1. **TRecord → Rust struct** - Anonymous structs invalid, need named struct emission
2. **Cons pattern** - "::" not valid Rust identifier in pattern position
3. **Multi-module projects** - `todo-cli` only generates Go, not Rust

## Next Steps

### Priority 1: Basic Completeness
1. Fix TRecord → struct emission (anonymous → named)
2. Fix Cons pattern ("::" → valid identifier)
3. Fix multi-module Rust output

### Priority 2: Type System
4. Proper generic type parameter handling
5. Record type → Rust struct syntax
6. Full ADT handling with generic parameters

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