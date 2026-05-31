# Sub-B — Std.Db Rust runtime — Design

**Date:** 2026-05-30
**Status:** Approved — ready for plan
**Scope:** Complete `Std.Db` runtime kernels in Rust, mirroring `runtime-go/rt/db_auth.go`. 12 missing kernels + arms + integration example.
**Branch:** `feat/runtime-rust`
**Builds on:** Sub-A (all 12 layers), upstream v0.15.34 (synced this session).

---

## 1. Context

Sub-A established the codegen + runtime infrastructure for stdlib parity on `target=rust`. The next stdlib pillar is **Std.Db** — the SQL database surface. Current state in `runtime-rust/src/sky_runtime/db.rs`:

- ✅ Connection lifecycle: `db_connect`, `db_open`, `db_open_with_path`
- ✅ Raw SQL: `db_exec_raw`, `db_exec`, `db_query`
- ✅ Row access: `db_get_field`, `db_get_string`, `db_get_int`
- ✅ Migrations: `db_migrate_apply`

Missing 12 kernels (Sky.Db Layer 3 surface):

| # | Kernel | Sky signature |
|---|---|---|
| 1 | `Db_close` | `Db -> Task Error ()` |
| 2 | `Db_getBool` | `String -> Dict String String -> Bool` |
| 3 | `Db_insertRow` | `Db -> String -> Dict String String -> Task Error Int` |
| 4 | `Db_getById` | `Db -> String -> Int -> Task Error (Maybe (Dict String String))` |
| 5 | `Db_updateById` | `Db -> String -> Int -> Dict String String -> Task Error Int` |
| 6 | `Db_deleteById` | `Db -> String -> Int -> Task Error Int` |
| 7 | `Db_findOneByField` | `Db -> String -> String -> String -> Task Error (Maybe (Dict String String))` |
| 8 | `Db_findManyByField` | `Db -> String -> String -> String -> Task Error (List (Dict String String))` |
| 9 | `Db_findByConditions` | `Db -> String -> List (String, String) -> Task Error (List (Dict String String))` |
| 10 | `Db_unsafeFindWhere` | `Db -> String -> String -> List String -> Task Error (List (Dict String String))` |
| 11 | `Db_queryDecode` | `Db -> String -> List String -> (Dict String String -> Result Error a) -> Task Error (List a)` |
| 12 | `Db_withTransaction` | `Db -> (Db -> Task Error a) -> Task Error a` |

Backed by `sqlx` (already in runtime deps) — same library the existing kernels use.

## 2. Goal

After this work:

1. All 12 missing Db kernels implemented in `runtime-rust/src/sky_runtime/db.rs`.
2. Each kernel has a unit test (sqlite in-memory or temp file).
3. All `kernelToRust` arms wired in `Builder.hs` (both bare `("Db", X)` and qualified `("Std.Db", X)` forms — Db is `Ffi.kernel`-aliased, like Math/String/Dict).
4. New integration example `examples/rust/17-db-todo-cli` mirroring `examples/07-todo-cli` on target=rust.
5. 16/16 + 1 new = 17/17 `examples/rust/*` build clean.
6. Go path byte-identical.

## 3. Non-goals

- Multi-database support (postgres / mysql) — sqlite only for sub-B. Sub-B.1 if needed.
- Connection pooling tuning — sqlx defaults are fine.
- Schema introspection / ORM features — Sky doesn't expose those.
- Std.Auth or Sky.Live integration — sub-C / sub-E.

## 4. Design

### Kernel implementations

Each kernel follows the existing pattern in `db.rs`:
- Generic over `E: Send + From<String> + 'static`
- Returns `SkyTask<E, T>` (boxed `Pin<Box<dyn Future>>`)
- Uses the existing `build_sql` helper for parameter interpolation
- Uses `row_to_map` for `DbRow → HashMap<String, String>` conversion

**Lifecycle kernels:**
```rust
pub fn db_close<E: Send + From<String> + 'static>(_db: Db) -> SkyTask<E, ()> {
    // sqlx::SqlitePool drops on its own; explicit close is a no-op
    // (or db.close().await for cleanup).
    Box::pin(async { SkyResult::Ok(()) })
}
```

**CRUD primitives** (insertRow / getById / updateById / deleteById):
Mirror the Go implementations in `db_auth.go`. Use sqlx parameter binding for safety (not string interpolation — those go via `build_sql` only for the dynamic-table-name case).

**Search kernels** (findOneByField / findManyByField / findByConditions):
Build the SQL with safe parameterisation. Return `Vec<HashMap>` for many, `Option<HashMap>` for one (wrapped in SkyMaybe).

**queryDecode**: takes a Rust closure `Fn(HashMap<String, String>) -> SkyResult<E, A>`. Map over the query result.

**withTransaction**: opens a transaction, runs the closure with the transaction as a `Db`, commits on Ok, rolls back on Err.

### Row scalar access — `db_get_bool`

```rust
pub fn db_get_bool(field: String, row: HashMap<String, String>) -> bool {
    matches!(row.get(&field).map(|s| s.as_str()), Some("1" | "true" | "TRUE" | "t" | "T"))
}
```

Mirrors Go's `Db_getBool` parsing convention.

### Integration example — `examples/rust/17-db-todo-cli`

Mirror `examples/07-todo-cli` (Go-target reference): 7 ops (add/list/done/undone/remove/clear/help) over sqlite. Single `Main.sky` file. `sky.toml` declares `target = "rust"` + `[db] driver = "sqlite"`.

Runs `sky run` → `cargo build` → CLI accepts the same 7 commands as the Go version.

## 5. Verification

1. **Per-kernel runtime tests**: in-memory sqlite (`":memory:"`), each kernel has a test for happy path + error case.
2. **Integration example**: `examples/rust/17-db-todo-cli` exercises insert/list/update/delete/transaction.
3. **Cross-target regression**: existing 16 `examples/rust/*` + Go `examples/01-hello-world` stay green.
4. **Cabal test**: targeted `FfiGen/Toml/Kernel` pass.
5. **examples/07-todo-cli on target=rust**: if it compiles end-to-end, sub-B is contractually done.

## 6. Risks

| Risk | Mitigation |
|---|---|
| sqlx async closure interaction with `withTransaction`'s `Fn(Db) -> SkyTask<E, A>` callback | Use the existing closure-passing pattern (already proven in tests) |
| Migration kernel signature mismatch with codegen-emitted call site | Verify against the Sky wrapper — migrate_apply already exists, expand if needed |
| Postgres/MySQL examples might surface — out of scope but if regression hits, document and defer | Restrict scope to sqlite via `sky.toml` driver field |
| sqlite-specific SQL syntax in tests vs portable SQL | Tests use vanilla SQL only |

## 7. Out of scope (sub-B.1 / sub-C)

- Postgres + MySQL backends (sub-B.1).
- `Std.Auth` (sub-C).
- Sky.Live session-store backed by Db (sub-E).
