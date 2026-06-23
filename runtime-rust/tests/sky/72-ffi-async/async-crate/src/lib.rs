//! 72-ffi-async: comprehensive async FFI fixture for Sky #44.
//!
//! NOT an author example — a Rust-backend FFI test fixture. Lives under
//! runtime-rust/tests/sky/ per the boundary rule (examples/ is the author's).
//!
//! Exercises FOUR async binding shapes + ONE negative (must DROP):
//!   1. `ping()  -> String`          — infallible async, bare T
//!   2. `add(i64,i64) -> i64`        — infallible async, bare T
//!   3. `try_div(i64,i64) -> Result<i64,String>` — fallible async (flatten E→SkyError)
//!   4. `boom()  -> i64`             — infallible async that PANICS (→ Err via JoinError)
//!   5. `non_send() -> NonSendAux`   — NEGATIVE: Output not Sky-bindable → DROP
//!
//! All real fns are total / no naked panics in non-test paths (boom is intentional).

/// (1) Infallible async — bare String output.
/// The Sky binding must be: `ping : Task Error String`
pub async fn ping() -> String {
    tokio::time::sleep(std::time::Duration::from_millis(1)).await;
    "pong".to_string()
}

/// (2) Infallible async — bare i64 output, two args.
/// The Sky binding must be: `add : Int -> Int -> Task Error Int`
pub async fn add(a: i64, b: i64) -> i64 {
    tokio::time::sleep(std::time::Duration::ZERO).await;
    a.saturating_add(b)
}

/// (3) Fallible async — Result<i64, String>; E must flatten to SkyError.
/// The Sky binding must be: `try_div : Int -> Int -> Task Error Int`
pub async fn try_div(a: i64, b: i64) -> Result<i64, String> {
    tokio::time::sleep(std::time::Duration::ZERO).await;
    if b == 0 {
        Err("division by zero".to_string())
    } else {
        Ok(a.saturating_div(b))
    }
}

/// (4) Infallible async that panics at runtime.
/// The codegen's JoinError/catch_unwind path must convert this to Err.
/// The Sky binding must be: `boom : Task Error Int`
pub async fn boom() -> i64 {
    tokio::time::sleep(std::time::Duration::ZERO).await;
    panic!("boom: intentional panic for C5 test")
}

/// (5) NEGATIVE: a non-bindable Output type (non-Sky-coercible struct).
/// The inspector must DROP this with a reason rather than emitting a binding.
/// Rust's auto-FFI rejects types it can't map to a Sky type.
pub struct NonSendAux {
    pub raw: *mut u8, // raw pointer → not Send → or simply unrecognizable struct
}

// NonSendAux is explicitly NOT Send (raw pointer makes it !Send automatically).
// The async fn returning it is:
pub async fn non_send() -> NonSendAux {
    NonSendAux { raw: std::ptr::null_mut() }
}
