# SkyRust: Sky to Rust Transpiler

## Project Overview

**Mission**: Create a transpiler that converts Sky (Elm-compatible functional language) to Rust, leveraging Rust's type system for seamless FFI with Rust libraries.

**Vision**: A better syntax for Rust - users write in Sky/Elm's clean functional style while having direct access to the Rust ecosystem.

---

## Constraints & Priorities

| Priority | Constraint | Implication |
|----------|------------|--------------|
| 1 | **All Rust targets** | Desktop, WASM, CLI, embedded - runtime must be modular |
| 2 | **FFI mandatory** | First-class Rust library integration from day 1 |
| 3 | **Throughput-focused** | Performance is primary - bump arena allocation |
| 4 | **Tests from Sky** | Existing Sky tests translate to Rust tests |
| 5 | **WASM first** | WebAssembly target before embedded |

---

## Architecture

### Hybrid Approach: Haskell Frontend + Rust Codegen

```
Sky Source → [Haskell] Parse + Type-Check → AST → [Rust] Codegen → Rust Code → Compile
                                                    (new)                         ↓
                                                              Rust libs (direct calls)
```

**Key Principles**:
- **Reuse existing parser, type checker, canonicaliser** from Sky compiler (Haskell)
- New Rust-specific codegen module (not Go backend clone)
- Design codegen for Rust idioms from start
- Runtime as separate crate (`runtime-rust`)
- **Rust-native FFI**: Generated Rust code calls Rust libraries directly — no Go runtime

**Why Hybrid?**:
- Reuses proven HM type system (~5,500 lines of battle-tested type checking)
- Avoids reimplementing 13,000+ lines of parser/canonicaliser/type-checker
- Single Haskell → Rust boundary (codegen only) — simpler than full rewrite
- Timeline: 4 months to codegen, 1 year to production

---

## Type Mapping

### Native Rust Types (Direct Mapping)

| Sky Type | Rust Type | Notes |
|----------|-----------|-------|
| `Int` | `i64` | Elm convention |
| `Float` | `f64` | |
| `Bool` | `bool` | |
| `Char` | `char` | |
| `()` | `()` | Unit type |
| `Result e a` | `Result<A, E>` | **Native!** |
| `Maybe a` | `Option<A>` | **Native!** |

### Container Types

| Sky Type | Rust Type | Implementation |
|----------|-----------|-----------------|
| `List a` | `Vec<A>` | Arena-allocated in Sky context |
| `Dict k v` | `BTreeMap<K, V>` | Default; `HashMap` opt-in |
| `Set a` | `BTreeSet<A>` | |
| `Task e a` | `impl Future<Output = Result<A, E>>` | Async Rust |
| `Cmd msg` | `Vec<CmdPrimitive>` | TEA command pattern |
| `Sub msg` | `Vec<SubPrimitive>` | TEA subscription pattern |

### Algebraic Data Types

**Sum Types (ADTs)**:
```elm
-- Sky
type Maybe a = Nothing | Just a
type Tree a = Leaf a | Branch (Tree a) (Tree a)
```

```rust
// Rust - direct enum
#[derive(Debug, Clone)]
enum Maybe<A> {
    Nothing,
    Just(A),
}

#[derive(Debug, Clone)]
enum Tree<A> {
    Leaf(A),
    Branch(Box<Tree<A>>, Box<Tree<A>>),
}
```

**Record Types**:
```elm
-- Sky
type alias User = { name: String, age: Int, email: String }
```

```rust
// Rust - direct struct
#[derive(Debug, Clone)]
struct User {
    name: String,
    age: i64,
    email: String,
}
```

**Type Aliases**:
```elm
-- Sky
type alias Age = Int
type alias Name = String
```

```rust
// Rust - type alias
type Age = i64;
type Name = String;
```

### Tuples

| Sky | Rust |
|-----|------|
| `(a, b)` | `(A, B)` |
| `(a, b, c)` | `(A, B, C)` |
| 4+ tuples | `([T; N])` or custom tuple struct |

---

## Garbage Collection

### Strategy: Bump Arena with FFI Boundary

```
┌─────────────────────────────────────────────────────┐
│                    Sky Code                         │
│   Allocations via Bump Arena (bumpalo)              │
│   - List, Dict, custom ADTs                         │
│   - Fast, sequential allocation                     │
│   - Bulk deallocation                              │
└──────────────────────┬──────────────────────────────┘
                       │ Conversion at FFI boundary
                       ▼
┌─────────────────────────────────────────────────────┐
│              Rust / FFI Boundary                   │
│   - Explicit owned types (String, Vec, etc)        │
│   - No arena dependency                            │
│   - Safe Rust types                                │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│              Native Rust Libraries                  │
│   Standard Rust - no GC involvement                 │
└─────────────────────────────────────────────────────┘
```

### Memory Model

```rust
// User-facing API
fn main() {
    let arena = Bump::new();
    
    // Sky function - uses arena internally
    let result = sky_module::user_function(&arena, arg);
    
    // result is owned String - can use with native Rust
    println!("Result: {}", result);
    
    // Arena freed at scope end - all Sky allocations cleaned
}
```

### Why Bump Arena?

| Factor | Rationale |
|--------|------------|
| **Performance** | O(1) allocation, cache-friendly sequential access |
| **Throughput** | Matches functional programming allocation patterns |
| **Simplicity** | No runtime GC, predictable behavior |
| **FFI boundary** | Clean separation between Sky and Rust memory |
| **Prior art** | elm-syntax-to-rust uses this successfully |

---

## FFI System

### Architecture

FFI is **first-class** - Rust libraries usable directly from Sky code.

### Integration Pattern

```toml
# project sky.toml
[dependencies]
stripe = "cargo"      # Cargo package
serde = "cargo"       # Serialization
tokio = "cargo"       # Async runtime
```

```elm
-- Sky code
import Stripe as Stripe
import Serde as Serde

checkout : CheckoutParams -> Task Error String
checkout params =
    Stripe.newCheckoutSession params
        |> Task.andThen .url
```

Transpiles to:

```rust
// Generated Rust
async fn checkout(params: CheckoutSessionParams) -> Result<String, Error> {
    stripe::new_checkout_session(params)
        .await
        .map(|session| session.url)
}
```

### Binding Generation Pipeline

```
1. Read Cargo.toml dependencies
2. Extract Rust crate metadata (rustdoc/AST)
3. Generate Sky module signatures
4. Transpile with proper type conversions
5. Emit Rust with C-compatible FFI if needed
```

**Mirrors**: Go's `sky add` + `sky-ffi-inspect` pipeline

### Phase 3 Priority Test Crates

These crates will be the first integration targets for FFI testing:

| Crate | Use Case | Priority |
|-------|----------|----------|
| **tokio** | Async runtime | Critical - must support `Task e a` → async |
| **serde** | Serialization (JSON, TOML, etc.) | High - core data handling |
| **uuid** | UUID generation (https://github.com/uuid-rs/uuid) | Medium - tests ADT/struct FFI |
| **axum** | HTTP server (https://github.com/tokio-rs/axum) | High - real-world web framework |
| **clap** | CLI argument parsing | Medium - CLI apps |
| **rayon** | Parallel iterators | Medium - concurrent processing |
| **reqwest** | HTTP client | Medium - network requests |
| **sqlx** | SQL database queries | Medium - database integration |
| **tokio-postgres** | PostgreSQL async driver | Medium - production DB |

### Type Conversion

| Rust Type | Sky Type | Conversion |
|-----------|----------|------------|
| `String` | `String` | Direct |
| `i64` | `Int` | Direct |
| `f64` | `Float` | Direct |
| `bool` | `Bool` | Direct |
| `Vec<T>` | `List a` | Via `sky_runtime::to_list()` |
| `Result<T, E>` | `Result e a` | Direct (native!) |
| `Option<T>` | `Maybe a` | Direct (native!) |
| Custom structs | Records | Direct mapping |
| Custom enums | ADTs | Direct mapping |

---

## Implementation Phases

### Phase 1: Foundation (Months 1-2) - ✅ COMPLETE (Runtime)

**Goal**: Basic transpiler works end-to-end

| Week | Milestone | Status | Deliverable |
|------|-----------|--------|-------------|
| 1-2 | Project setup | ✅ DONE | Repo structure, runtime crate |
| 3-4 | Runtime implementation | ✅ DONE | All core types (Result, Maybe, String, List, Dict, Task) |
| 5-6 | Testing | ✅ DONE | 54 tests passing |
| 7-8 | (Compiler implementation) | PENDING | Rust codegen module in Sky compiler |
| 9 | End-to-end test | PENDING | Parse → type → emit → compile |

**Verification (Completed)**:
- ✅ `cargo build` - compiles
- ✅ `cargo test` - 54 tests pass
- ✅ Runtime types verified: Result, Maybe, String, List, Dict, Task, Basic ops

### Phase 2: Type System (Months 2-4) - IN PROGRESS

**Goal**: Full type system transpilation

| Week | Milestone | Status | Deliverable |
|------|-----------|--------|-------------|
| 10-11 | Codegen module structure | ✅ DONE | Types.hs, Expr.hs, Pattern.hs, Decl.hs, Kernel.hs, Module.hs, Builder.hs |
| 12-13 | ADT → enum | PENDING | Sum types transpile to Rust enums |
| 14-15 | Record → struct | PENDING | Records transpile to Rust structs |
| 16-17 | Pattern matching | PENDING | `case` → `match` expressions |
| 18 | Generics | PENDING | Type parameters via Rust generics |
| 19 | Exhaustiveness | PENDING | Reuse Sky's checker for errors |

**Verification**: Complex Sky code (e.g., Skyvote, Skyshop modules) transpiles correctly

### Phase 3: FFI System (Months 4-6)

**Goal**: Call Rust libraries from Sky

| Week | Milestone | Deliverable |
|------|-----------|-------------|
| 19-20 | Cargo parsing | Read Cargo.toml dependencies |
| 21-22 | Function extraction | Parse Rust signatures from crates |
| 23-24 | Binding generation | Sky module from Rust crate |
| 25 | Type converter | FFI boundary type conversion |
| 26 | Error handling | Propagate Rust errors to Sky |

**Verification**: `import external_crate` works for popular Rust crates

### Phase 4: Effects & WASM (Months 6-9)

**Goal**: Full TEA and web target

| Week | Milestone | Deliverable |
|------|-----------|-------------|
| 27-28 | Task → async | `Task e a` → `impl Future` |
| 29-30 | Cmd/Sub system | TEA commands and subscriptions |
| 31-32 | WASM target | `cargo build --target wasm32-unknown-unknown` |
| 33-34 | Web integration | JS interop, DOM access |
| 35-36 | Example app | Full Sky.Live app on WASM |

**Verification**: Sky example app runs in browser via WASM

### Phase 5: Polish & Release (Months 9-12)

**Goal**: Production-ready v1.0

| Week | Milestone | Deliverable |
|------|-----------|-------------|
| 37-38 | CLI tool | `sky rust` subcommand |
| 39-40 | Testing | Translate Sky test suite to Rust |
| 41-42 | Documentation | User guide, API docs |
| 43-44 | Performance | Benchmark and optimize |
| 45-48 | Release | v1.0 tag |

**Verification**: All tests pass, performance meets targets

---

## Project Structure

```
sky/
├── SKYRUST-PLAN.md           # This file
├── README.md                 # Project overview
├── CLAUDE.md                 # Project context
├── LICENSE                   # Apache 2.0 (matching Sky)
│
├── src/Sky/
│   ├── Parse/            # Parser (~2,685 lines)
│   ├── Canonicalise/     # Name resolution (~2,758 lines)
│   ├── Type/             # HM type checker (~5,503 lines)
│   └── Generate/
│       ├── Go/           # Go codegen (reference)
│       └── Rust/         # ✅ NEW: Rust codegen module (~1,350 lines)
│                               ├── Types.hs       - Type mapping
│                               ├── Expr.hs        - Expression transpilation
│                               ├── Pattern.hs     - Pattern matching
│                               ├── Decl.hs        - Declaration transpilation
│                               ├── Kernel.hs      - Runtime function calls
│                               ├── Module.hs      - Module organization
│                               └── Builder.hs     - Orchestration
│
├── runtime-rust/         # ✅ COMPLETE - Rust runtime crate
│   ├── Cargo.toml
│   └── src/
│       └── lib.rs            # Single-file runtime (~500 lines, 54 tests)
│
├── ffi-rust/             # FFI binding generator (Phase 3)
│   └── src/
│
├── tests/                    # Transpiled test suite
│   └── basics/
│
└── examples/                 # Example transpiled apps
    └── hello-world/
```

---

## Key Components

### 1. Rust Codegen (`src/Sky/Generate/Rust/`)

**Responsibilities**:
- Convert Sky AST to Rust source code
- Type mapping (Sky → Rust)
- Pattern matching translation
- Lambda/closure handling

**Key Modules**:
```
Rust/
├── Types.hs          -- Type to Rust type conversion
├── Expr.hs          -- Expression transpilation
├── Pattern.hs       -- Pattern matching to match
├── Decl.hs          -- Declaration transpilation
├── Runtime.hs       -- Runtime function calls
├── Ffi.hs           -- FFI integration
└── Module.hs        -- Module emit and organization
```

### 2. Runtime Crate (`runtime-rust`)

**Purpose**: Provide Sky primitives in Rust

**Features**:
- Arena allocator (`bumpalo`)
- String implementation
- List/Dict/Set helpers
- Task/Future adapters
- FFI conversion utilities

### 3. FFI Generator (`ffi-rust`)

**Purpose**: Generate Sky bindings for Rust crates

**Approach**:
- Parse Cargo.toml
- Analyze crate with rustdoc/AST
- Emit Sky module signatures
- Generate Rust thunks if needed

---

## Testing Strategy

### Test Translation Pipeline

```
Sky Tests (existing) → Transpile → Rust Tests → Compare
```

### Test Categories

| Category | Source | Validation |
|----------|--------|------------|
| Unit tests | `test/Sky/*Spec.hs` | Transpile, run with Rust |
| Runtime tests | `runtime-go/rt/*_test.go` | Port to Rust, verify same behavior |
| Examples | `examples/*/` | Transpile, run, compare output |
| FFI tests | New | Test Rust crate calls |

### Test Migration

```haskell
-- Haskell test (Sky)
it "map adds one" $
    map (\x -> x + 1) [1,2,3] `shouldBe` [2,3,4]
```

```rust
// Transpiled Rust test
#[test]
fn test_map_adds_one() {
    let result: Vec<i64> = list_map(&arena, &|x| x + 1, &[1, 2, 3]);
    assert_eq!(result, vec![2, 3, 4]);
}
```

---

## Performance Targets

| Metric | Target |
|--------|--------|
| Transpilation speed | < 2x Go backend |
| Runtime performance | Match native Rust |
| Binary size | < 1.5x equivalent Rust |
| WASM size | < 500KB baseline |

---

## Open Questions

These need team discussion before Phase 1:

1. **Compiler location**: Fork Sky compiler or add as submodule?

2. **Runtime versioning**: Match Sky runtime version or independent?

3. **Naming convention**: `SkyRust` vs `sky-rust` vs `skyrust`?

4. **Minimum Rust version**: 1.70+? 1.75+?

5. **Feature flags**: Which runtime features optional?

---

## Risks & Mitigations

| Risk | Mitigation |
|------|-------------|
| Type system mismatch | Extensive testing, type-level guarantees |
| FFI complexity | Start simple, expand gradually |
| Performance issues | Benchmark early, optimize hot paths |
| Scope creep | Strict phase gates, clear milestones |
| Team expertise | Document heavily, pair programming |

---

## Success Criteria

### Phase 1 Success
- [ ] Basic Sky code transpiles to valid Rust
- [ ] Primitives work correctly
- [ ] Functions compile and run
- [ ] Rust binary executes

### Phase 2 Success
- [ ] All ADTs transpile to enums
- [ ] Records map to structs
- [ ] Pattern matching complete
- [ ] Complex examples work

### Phase 3 Success
- [ ] Can import Cargo crates
- [ ] Function calls work across FFI
- [ ] Error handling integrates
- [ ] Real-world crate integration

### Phase 4 Success
- [ ] WASM target builds
- [ ] Browser execution works
- [ ] TEA pattern functional
- [ ] Full app on web

### Phase 5 Success
- [ ] CLI complete
- [ ] All tests pass
- [ ] Performance targets met
- [ ] v1.0 released

---

## Test Results (Phase 1 Runtime)

### Summary
- **Total Tests**: 54
- **Passing**: 54 (100%)
- **Failed**: 0
- **Coverage**: All core runtime types and operations

### Test Categories

| Category | Count | Status |
|----------|-------|--------|
| SkyResult | 6 | ✅ |
| SkyMaybe | 4 | ✅ |
| SkyString | 4 | ✅ |
| SkyList | 8 | ✅ |
| SkyDict | 7 | ✅ |
| SkyTask | 4 | ✅ |
| Basic Ops | 14 | ✅ |
| FFI Helpers | 4 | ✅ |
| Allocator | 2 | ✅ |

### Key Test Patterns

```rust
// Result tests
let ok_r: SkyResult<&str, i64> = ok(42);
assert!(ok_r.is_ok());

// Maybe tests  
let m = just(5).and_then(|x| just(x * 2));
assert_eq!(m.with_default(0), 10);

// Task tests (async)
let task = succeed::<String, i64>(5);
let mapped = map_task(task, |x| x * 2);
let result = mapped.await;
assert_eq!(result.with_default(0), 10);
```

### Testing Dependencies
- `tokio` with `test-util` and `macros` features for async tests
- Standard `assert!` and `assert_eq!` macros

---

## Runtime Implementation Details

### Single-File Architecture
The runtime is implemented as a single `lib.rs` (~500 lines) containing:
- Core type wrappers with proper ordering (SkyResult, SkyMaybe, etc.)
- Collection types (SkyList, SkyDict)
- Async task support (SkyTask)
- FFI boundary conversion helpers
- Basic operations (arithmetic, comparison, identity)

### Type Design Decisions

**SkyResult<E, A>**
- Wraps Rust's `Result<A, E>` to maintain Sky's error-first ordering
- Implements: `ok()`, `err()`, `map()`, `and_then()`, `with_default()`, `is_ok()`, `is_err()`, `unwrap()`
- Supports: `Clone`, `Copy`, `PartialEq`, `Eq`, `Hash`, `Debug`

**SkyMaybe<T>**
- Direct wrapper around `Option<T>`
- Implements: `just()`, `nothing()`, `map()`, `and_then()`, `with_default()`
- Native Rust interop - `Option<T>` converts directly

**SkyDict<K, V>**
- Uses `BTreeMap<K, V>` for ordered key storage
- Requires: `K: Ord + Clone`, `V: Clone`
- Implements: `insert()`, `get()`, `contains()`, `remove()`, `keys()`, `values()`, `to_list()`

**SkyTask<E, A>**
- Type alias: `Pin<Box<dyn Future<Output = SkyResult<E, A>> + Send>`
- Enables direct use with Rust async/await
- Requires: `E: Send + 'static`, `A: Send + 'static`

---

## References

| Project | Relevance |
|---------|-----------|
| [elm-syntax-to-rust](https://github.com/lue-bird/elm-syntax-to-rust) | Direct prior art |
| [bumpalo](https://docs.rs/bumpalo/latest/bumpalo/) | Arena allocator |
| [zerogc](https://docs.rs/zerogc/latest/zerogc/) | Alternative GC |
| Sky compiler (`perf/v0.13`) | Type system reference |
| [hs-bindgen](https://github.com/yvan-sraka/hs-bindgen) | FFI patterns |

---

*Plan created: 2026-05-14*
*Updated: 2026-05-14*
*Version: 1.1*
