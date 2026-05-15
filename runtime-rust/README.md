# SkyRust

A transpiler that converts Sky (Elm-compatible functional language) to Rust.

## Overview

This project implements a new Rust backend for the Sky compiler, allowing Sky code to transpile to idiomatic Rust code. The transpiler leverages Rust's powerful type system for seamless FFI with Rust libraries.

**Architecture**: Hybrid — reuses Sky's Haskell parser/type-checker and adds a new Rust codegen module. Generated Rust code calls Rust libraries directly (Rust-native FFI).

## Project Structure

```
skyrust/
├── SKYRUST-PLAN.md           # Detailed project plan
├── README.md                 # This file
├── CLAUDE.md                 # Project context
│
├── sky-runtime-rust/         # ✅ COMPLETE - Rust runtime (54 tests)
│   ├── Cargo.toml
│   └── src/lib.rs
│
├── sky-compiler/             # Sky compiler (copied from sky-anzel)
│   └── src/Sky/Generate/Rust/  # ✅ COMPLETE - Rust codegen module
│       ├── Types.hs          # Type mapping
│       ├── Expr.hs           # Expression transpilation
│       ├── Pattern.hs        # Pattern matching
│       ├── Decl.hs           # Declaration transpilation
│       ├── Kernel.hs         # Runtime function calls
│       ├── Module.hs         # Module organization
│       └── Builder.hs        # Orchestration
│
├── sky-ffi-rust/             # FFI binding generator (Phase 3)
│   └── src/
│
└── examples/                 # Example transpiled apps
    └── hello-world/
```

## Current Status

### Phase 1: ✅ COMPLETE
- Runtime crate: 54 tests passing
- Core types implemented

### Phase 2: ✅ COMPLETE - Rust codegen wired and working
- Rust codegen module: `src/Sky/Generate/Rust/Builder.hs`
- `--target rust` flag added to build/run/watch commands
- Output to `sky-out/Rust/main.rs`
- Full expression support:
  - Function definitions (Def, TypedDef, DestructDef)
  - Kernel calls (Db::, Task::, Log::, System::, etc.)
  - Pattern matching with `match` expressions
  - Pipeline operators (`|>` → `|>`)
  - Let bindings (Let, LetRec, LetDestruct)
  - Binary operators (+, -, ==, ++, etc.)
  - If expressions, lambdas, tuples, lists, records
  - Union types → Rust enums
  - Type aliases

### Phase 3: FFI System (Next)
- tokio, serde, uuid, axum, clap, rayon, reqwest, sqlx, tokio-postgres

## Usage

```bash
# Build for Go (default)
sky build src/Main.sky

# Build for Rust
sky build src/Main.sky --target rust
# Output: sky-out/Rust/main.rs

# Run Rust build
sky run src/Main.sky --target rust

# Watch mode with Rust target
sky watch src/Main.sky --target rust
```

## Generated Output Example

Input (Sky):
```elm
main = println "Hello from Sky!"
```

Output (Rust):
```rust
fn main() -> () {
    Log::println("Hello from Sky!")
}

fn main() {
    main_();
}
```

More complex example (todo-cli, 63 lines):
```rust
fn runCommand(conn, cmd, cmdArg) -> () {
    match cmd { 
        "add" => if (cmdArg == "") { ... } else { Main_addTodo(...) },
        "list" => Main_listTodos(conn), 
        ...
    }
}
```

## Building

```bash
# Build runtime
cd sky-runtime-rust
cargo build

# Check (faster)
cargo check
```

## Testing

```bash
# Run runtime tests
cd sky-runtime-rust
cargo test
```

### Test Results (Phase 1 - Runtime)

- **Total Tests**: 54
- **Passing**: 54 (100%)
- **Failed**: 0

Test coverage includes:
- SkyResult (6 tests): ok, err, map, and_then, with_default, is_ok/is_err
- SkyMaybe (4 tests): just, nothing, map, and_then, with_default
- SkyString (4 tests): from_str, is_empty, len, concat
- SkyList (8 tests): from_vec, push, head, tail, map, filter, fold, reverse
- SkyDict (7 tests): new, insert, get, contains_key, remove, keys, values
- SkyTask (4 tests): succeed, fail, map, and_then (async)
- Basic Ops (14 tests): int_add, int_sub, int_mul, int_div, float_ops, bool_ops, eq, lt, gt, identity, to_string
- FFI Helpers (4 tests): to_owned_string, from_owned_string, to_owned_list, from_owned_list
- Allocator (2 tests): allocate, alloc_string

## Implementation Notes

### Type Design Decisions

**SkyResult<E, A>**
- Wraps Rust's `Result<A, E>` - error-first ordering matches Sky
- Methods: `ok()`, `err()`, `map()`, `and_then()`, `with_default()`, `is_ok()`, `is_err()`, `unwrap()`
- Bounds: `Clone`, `Copy`, `PartialEq`, `Eq`, `Hash`, `Debug`

**SkyMaybe<T>**
- Direct wrapper around `Option<T>`
- Methods: `just()`, `nothing()`, `map()`, `and_then()`, `with_default()`
- Native Rust interop - `Option<T>` converts directly

**SkyDict<K, V>**
- Uses `BTreeMap<K, V>` for ordered key storage
- Bounds: `K: Ord + Clone, V: Clone`

**SkyTask<E, A>**
- Type alias: `Pin<Box<dyn Future<Output = SkyResult<E, A>> + Send>>`
- Requires: `E: Send + 'static`, `A: Send + 'static`

### FFI Patterns

The FFI boundary uses explicit owned/arena conversion:
- `to_owned_string(&String) -> SkyString` - converts &str to owned SkyString
- `from_owned_string(SkyString) -> String` - converts owned to String
- `to_owned_list(&[T]) -> SkyList<T>` - converts slice to owned list
- `from_owned_list(SkyList<T>) -> Vec<T>` - converts owned to Vec

## Phase 3 Priority Test Crates

These crates will be the first integration targets for FFI testing:

| Crate | Use Case |
|-------|----------|
| **tokio** | Async runtime |
| **serde** | Serialization |
| **uuid** | UUID generation |
| **axum** | HTTP server |
| **clap** | CLI argument parsing |
| **rayon** | Parallel iterators |
| **reqwest** | HTTP client |
| **sqlx** | SQL database queries |
| **tokio-postgres** | PostgreSQL async driver |

## References

- [SKYRUST-PLAN.md](./SKYRUST-PLAN.md) - Detailed project plan
- [elm-syntax-to-rust](https://github.com/lue-bird/elm-syntax-to-rust) - Prior art
- Sky compiler (perf/v0.13 branch) - Type system reference

## License

Apache 2.0 (same as Sky compiler)