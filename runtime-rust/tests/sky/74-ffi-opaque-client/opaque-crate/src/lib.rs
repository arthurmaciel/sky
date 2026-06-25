//! 74-ffi-opaque-client: opaque-handle threading + concrete-impl monomorphization
//! fixture for Sky #52.
//!
//! NOT an author example — a Rust-backend FFI test fixture. Lives under
//! runtime-rust/tests/sky/ per the boundary rule (examples/ is the author's).
//!
//! Mirrors the firestore / stripe shape: a realistic async-generic op
//! (`Req::send<C: Transport>`) over an OPAQUE, NOT-Clone client handle (`Db`).
//!
//! POSITIVE rows (must BIND end-to-end):
//!   1. `Db::new(&str) -> Db`             — opaque ctor; returns the handle by value
//!   2. `Req::new() -> Req`               — builder seed
//!   3. `Req::with_field(self, &str) -> Req` — by-value builder step
//!   4. `Req::send<C: Transport>(&self, client: &C) -> Result<String, String>`
//!                                         — async generic op; C monomorphizes to Db
//!                                           (the ONE same-crate non-generic impl),
//!                                           Db threads by-value, Transport: Send so
//!                                           the Send-proof admits it.
//!
//! NEGATIVE rows (must DROP — coverage-dropped, never cargo-fail):
//!   * `send` with TWO `impl Transport` types (Db + Db2) → ambiguous concrete →
//!     `trait-bounded-param-ambiguous` drop. (We add Db2 below so the live row
//!     for `send` over an AMBIGUOUS bound is impossible to monomorphize — see
//!     the assertion: send must STILL bind because the unique-impl rule keys on
//!     the BOUND TRAIT; here Transport has 2 impls → send DROPS. To keep `send`
//!     bindable for the positive proof we give it the SINGLE-IMPL trait `Wire`
//!     and reserve `Transport` for the ambiguous negative.)
//!   * `recv<C: Held>(&self, c: &C)` over `NotSend` (Rc-bearing, single impl) →
//!     async future not Send → `async-future-not-send` drop.

use std::rc::Rc;

/// (1) OPAQUE handle, NOT Clone (holds a resource). The Sky binding must be an
/// opaque value threaded by-value; `Db::new` returns it.
pub struct Db {
    _conn: String,
}

impl Db {
    /// Opaque constructor — returns the handle by value (Step 1 sub-proof).
    pub fn new(url: &str) -> Db {
        Db { _conn: url.into() }
    }
}

/// The single-impl bound trait used by the POSITIVE `send`. `Send + Sync` so the
/// Send-proof (Step 3) admits a threaded opaque bounded by it.
pub trait Wire: Send + Sync {}
impl Wire for Db {}

/// A SECOND bound trait with TWO concrete impls — drives the ambiguous negative.
pub trait Transport: Send + Sync {}
impl Transport for Db {}
/// Second impl of `Transport` → makes any `<C: Transport>` op AMBIGUOUS → DROP.
pub struct Db2;
impl Transport for Db2 {}

/// (2)/(3) Builder. `with_field` is a by-value builder step (`self -> Req`).
pub struct Req {
    field: String,
}

impl Req {
    pub fn new() -> Req {
        Req { field: String::new() }
    }

    pub fn with_field(mut self, v: &str) -> Req {
        self.field = v.into();
        self
    }

    /// (4) The POSITIVE async generic op. `C: Wire` has EXACTLY ONE same-crate
    /// non-generic impl (`Db`) → monomorphize `C = Db`. `Wire: Send` → the
    /// threaded `&Db` passes the Send-proof. Output `Result<String, String>`.
    pub async fn send<C: Wire>(&self, _client: &C) -> Result<String, String> {
        tokio::time::sleep(std::time::Duration::ZERO).await;
        Ok(format!("sent {} via db", self.field))
    }

    /// NEGATIVE (ambiguous): `C: Transport` has TWO impls (Db, Db2) → the
    /// concrete-impl resolver finds >1 → `trait-bounded-param-ambiguous` DROP.
    pub async fn send_ambiguous<C: Transport>(&self, _client: &C) -> Result<String, String> {
        tokio::time::sleep(std::time::Duration::ZERO).await;
        Ok(format!("sent {} ambiguously", self.field))
    }
}

impl Default for Req {
    fn default() -> Self {
        Req::new()
    }
}

/// NEGATIVE (!Send): a Held trait with a SINGLE impl over an `Rc`-bearing type.
/// `NotSend` is `!Send` (Rc), so even though `Held` has exactly one impl and the
/// concrete-impl resolver would pick `C = NotSend`, the async future is not Send
/// → `async-future-not-send` DROP. (`Held` is NOT `Send`, and `NotSend` is not
/// provably-Send, so the conservative Send-proof refuses it.)
pub trait Held {}
pub struct NotSend {
    _p: Rc<u8>,
}
impl Held for NotSend {}

/// A free constructor for NotSend so its single Held impl is reachable. The op
/// below must DROP.
pub fn not_send_new() -> NotSend {
    NotSend { _p: Rc::new(0) }
}

impl Req {
    /// NEGATIVE (!Send): single-impl bound `Held` over `NotSend` (Rc) → async
    /// future not Send → DROP.
    pub async fn recv<C: Held>(&self, _c: &C) -> Result<String, String> {
        tokio::time::sleep(std::time::Duration::ZERO).await;
        Ok("recv".to_string())
    }
}
