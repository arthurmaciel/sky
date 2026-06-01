# Sub-C — Std.Auth Rust runtime — Design

**Date:** 2026-05-31
**Status:** Approved — ready for plan
**Scope:** Complete `Std.Auth` runtime kernels in Rust. 9 missing kernels (6 pure + 3 DB-touching) + integration example.
**Branch:** `feat/runtime-rust`
**Builds on:** Sub-B/B.1 (Std.Db sqlite+mysql+postgres), Sub-A.4 (jwt module already shipped).

---

## 1. Context

After sub-B/B.1, `Std.Db` is fully portable across three backends. Authentication is the next stdlib pillar — needed for any non-trivial app. The Sky-side surface (`sky-stdlib/Std/Auth.sky`) declares 9 kernels:

| Kernel | Sky signature | Effect tier |
|---|---|---|
| `hashPassword` | `String -> Result Error String` | pure (bcrypt) |
| `hashPasswordCost` | `String -> Int -> Result Error String` | pure (bcrypt) |
| `verifyPassword` | `String -> String -> Result Error Bool` | pure (bcrypt) |
| `passwordStrength` | `String -> Result Error String` | pure (validation rules) |
| `signToken` | `String -> a -> Int -> Result Error String` | pure (JWT HS256) |
| `verifyToken` | `String -> String -> Result Error a` | pure (JWT HS256) |
| `register` | `Db -> String -> String -> Task Error Int` | DB (creates user) |
| `login` | `Db -> String -> String -> Task Error Int` | DB (authenticates) |
| `setRole` | `Db -> Int -> String -> Task Error ()` | DB (updates role) |

Backed by `bcrypt` (new crate dep) + `jsonwebtoken` (already in sub-A.4) + `sqlx` (sub-B).

## 2. Goal

After this work:

1. All 9 Auth kernels implemented in `runtime-rust/src/sky_runtime/auth.rs` (new file).
2. Each kernel has at least one unit test (bcrypt round-trips, JWT round-trips, register+login flow).
3. `kernelToRust` arms wired (bare `("Auth", X)` and qualified `("Std.Auth", X)` — Ffi.kernel aliases like Math/String/Dict).
4. New `examples/rust/18-auth-signup` exercises register → login → JWT issue end-to-end on `target=rust`.
5. 17/17 + 1 = 18/18 `examples/rust/*` build clean.
6. Go path byte-identical.

## 3. Design

### Crypto kernels (6 pure)

`bcrypt` crate (~3M downloads/month, pure-Rust). Default cost 12 to match Go runtime; configurable via `hashPasswordCost`.

```rust
pub fn auth_hash_password<E: From<String>>(pw: String) -> SkyResult<E, String> {
    auth_hash_password_cost(pw, 12)
}

pub fn auth_hash_password_cost<E: From<String>>(pw: String, cost: i64) -> SkyResult<E, String> {
    if pw.len() < 8 { return SkyResult::Err("password must be ≥8 characters".to_string().into()); }
    if pw.len() > 72 { return SkyResult::Err("password longer than 72 bytes (bcrypt limit)".to_string().into()); }
    match bcrypt::hash(&pw, cost.max(4).min(31) as u32) {
        Ok(h) => SkyResult::Ok(h),
        Err(e) => SkyResult::Err(format!("bcrypt: {}", e).into()),
    }
}

pub fn auth_verify_password<E: From<String>>(pw: String, hash: String) -> SkyResult<E, bool> {
    match bcrypt::verify(&pw, &hash) {
        Ok(b) => SkyResult::Ok(b),
        Err(e) => SkyResult::Err(format!("bcrypt verify: {}", e).into()),
    }
}

pub fn auth_password_strength<E: From<String>>(pw: String) -> SkyResult<E, String> {
    // Mirrors Go's contract: <8 chars or >72 bytes or no letter/digit → Err
    // Otherwise returns a strength rating: "weak"/"medium"/"strong"
    ...
}
```

JWT kernels reuse `jsonwebtoken` (already shipped). `signToken` builds an HS256-signed token with the given claims map + `exp` claim from the `expirySeconds` arg; `verifyToken` parses + validates expiry.

The `claims : a` parameter type is polymorphic in Sky source. Runtime accepts `HashMap<String, String>` for the simple case (matches the Go reference's runtime behaviour).

### DB-touching kernels (3 Task)

All three follow the same shape as sub-B's Db kernels: take a `Db` (sqlx Pool), return `SkyTask<E, T>`. Schema lazy-created on first use:

```sql
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,   -- sqlite; mysql/postgres equiv via db_format_sql awareness
    email TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    role TEXT DEFAULT 'user',
    created_at INTEGER NOT NULL
);
```

For multi-backend support, the `id INTEGER PRIMARY KEY AUTOINCREMENT` syntax differs across drivers. Sub-C ships with sqlite-native syntax; mysql/postgres require manual schema adjustment by users (documented limitation — sub-C.1 follow-on could add per-driver `auto_id_column` mirroring Go's `autoIdColumn(driver)`).

```rust
pub fn auth_register<E: Send + From<String> + 'static>(
    conn: Db, email: String, password: String,
) -> SkyTask<E, i64> {
    Box::pin(async move {
        // 1. Ensure schema exists
        // 2. Validate password (≥8 chars)
        // 3. Hash password (bcrypt default cost)
        // 4. INSERT INTO users (email, password_hash, role, created_at) VALUES (?, ?, 'user', ?)
        //    — propagates UNIQUE constraint violation as "email already registered" error
        // 5. Return new user id via db_last_insert_id
        ...
    })
}

pub fn auth_login<E: Send + From<String> + 'static>(
    conn: Db, email: String, password: String,
) -> SkyTask<E, i64> {
    Box::pin(async move {
        // 1. SELECT id, password_hash FROM users WHERE email = ?
        // 2. bcrypt::verify(password, hash)
        // 3. Return user id on success, "invalid credentials" Err on failure
        //    (don't leak whether the email exists)
        ...
    })
}

pub fn auth_set_role<E: Send + From<String> + 'static>(
    conn: Db, user_id: i64, role: String,
) -> SkyTask<E, ()> {
    Box::pin(async move {
        // UPDATE users SET role = ? WHERE id = ?
        ...
    })
}
```

### Cargo.toml updates

`emitCargoToml` adds:
- `bcrypt = "0.17"` (latest stable; pure-Rust)

`jsonwebtoken` already included (sub-A.4). `sqlx` already configured per-driver (sub-B.1).

## 4. Verification

1. **Per-kernel unit tests** (sqlite in-memory for DB ones):
   - bcrypt: hash → verify round-trip; verify rejects wrong password; cost-12 vs cost-10
   - passwordStrength: rejects <8 chars; rejects all-letters/all-digits; accepts mixed
   - JWT: sign → verify round-trip with multiple claim types; expired token rejected
   - register: creates user; duplicate email → Err
   - login: correct credentials → Ok user_id; wrong password → Err; non-existent email → Err
   - setRole: updates role; returns Ok ()

2. **Integration example** — `examples/rust/18-auth-signup`:
   - `sky-app register alice@example.com hunter2` → prints user id
   - `sky-app login alice@example.com hunter2` → prints user id + JWT
   - `sky-app login alice@example.com wrong` → Err
   - `sky-app set-role <id> admin` → Ok

3. **Regression** — 17/17 existing examples/rust/* + new 18 = 18/18.

## 5. Risks

| Risk | Mitigation |
|---|---|
| bcrypt cost too high → tests slow | Use cost 10 in tests (default 12 in production); bcrypt cost is exponential |
| sqlite-specific `AUTOINCREMENT` schema breaks mysql/postgres | Documented limitation; sub-C.1 to extend with `db_auto_id_column` helper in `config.rs` |
| `signToken` claim type polymorphism (`a` in Sky source) | Accept `HashMap<String, String>` at runtime; Sky-side users wrap typed records into string maps |
| JWT secret must be ≥32 bytes (Sky security gate) | Validate at sign/verify entry; matches Go runtime's contract |
| `register` UNIQUE constraint error message must not leak DB internals | Catch sqlx UniqueViolation, return "email already registered" generically |

## 6. Out of scope (sub-C.1+)

- Multi-backend schema for `users` table (sub-C.1: `db_auto_id_column` helper in generated `config.rs`).
- OAuth / SSO / password reset flows (sub-C.2).
- Session token rotation, refresh tokens (sub-C.3).
- bcrypt cost calibration helper (sub-C.4).
- `Std.Auth.Middleware` — HTTP middleware integration (sub-D dependency).
