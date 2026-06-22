//! Minimal local crate exercising Sky→Rust ASYNC FFI (task #15 probe).
//!
//! NOT an author example — a Rust-backend FFI test fixture. Lives under
//! runtime-rust/tests/sky/ per the boundary rule (examples/ is the author's).
//!
//! `delay_echo` is a REAL `async fn` backed by `tokio::time::sleep` (needs the
//! reactor). The inspector classifies `async fn -> Result<T, String>` as
//! `effect="effectful"` → the binding generator emits a `SkyTask<SkyError, T>`
//! wrapper that `.await`s this future. The probe asks: does Sky's Task runtime
//! actually drive that future end-to-end (reactor present, returns 2*x)?
//!
//! Total / no-panic: `ms.max(0)` floors the duration; the body never panics.

/// Sleep `ms` milliseconds (needs the tokio time driver), then return `x * 2`.
/// `Ok` always — the `Result` slot makes the inspector mark it fallible+async,
/// which is the common real-world shape (async fn returning Result).
pub async fn delay_echo(x: i64, ms: i64) -> Result<i64, String> {
    tokio::time::sleep(std::time::Duration::from_millis(ms.max(0) as u64)).await;
    Ok(x.saturating_mul(2))
}
