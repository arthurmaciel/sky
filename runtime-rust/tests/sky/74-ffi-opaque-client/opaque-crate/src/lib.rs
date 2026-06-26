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

// ── DEFECT-1: async SELF-RECEIVER Send hole ─────────────────────────────────
// The async wrapper captures the receiver BY-MOVE into `async move { arg0.m()
// .await }`, so an async instance method on a `Clone + !Send` (Rc-backed)
// receiver yields a non-Send future → E0277 at `tokio::task::spawn`. The param-
// Send gate explicitly SKIPPED `self` (WRONG — it IS captured), so pre-fix such a
// method BOUND and cargo-failed. Post-fix the receiver Send-proof drops it.

/// A `Clone + !Send` opaque (Rc-backed). NOT in any Send-proof source → the async
/// receiver gate refuses it.
#[derive(Clone)]
pub struct RcClient {
    _shared: Rc<u8>,
}

impl RcClient {
    /// Opaque ctor — returns the !Send handle by value.
    pub fn new() -> RcClient {
        RcClient { _shared: Rc::new(0) }
    }

    /// NEGATIVE (DEFECT-1): async instance method on a !Send receiver, NO non-self
    /// params. The receiver is captured by-move into the spawned future → !Send →
    /// E0277. The param gate can't catch it (no non-self params); the RECEIVER
    /// gate must → DROP (`async-future-not-send`). Output `Result<i64, String>`.
    pub async fn ping(&self) -> Result<i64, String> {
        tokio::time::sleep(std::time::Duration::ZERO).await;
        Ok(7)
    }
}

impl Default for RcClient {
    fn default() -> Self {
        RcClient::new()
    }
}

/// A PROVABLY-Send opaque (all fields Send: a single `pub u64`). The async
/// receiver gate ADMITS it (all-fields-Send source) → the async method below still
/// binds (no over-drop). The field is `pub` so rustdoc does not strip it — the
/// all-fields-Send proof refuses a struct with stripped (private) fields.
pub struct SendClient {
    pub seed: u64,
}

impl SendClient {
    pub fn new(seed: u64) -> SendClient {
        SendClient { seed }
    }

    /// POSITIVE (DEFECT-1 control): async instance method on a Send receiver →
    /// still binds. Output `Result<i64, String>`.
    pub async fn pong(&self) -> Result<i64, String> {
        tokio::time::sleep(std::time::Duration::ZERO).await;
        Ok(self.seed as i64 + 1)
    }
}

impl Default for SendClient {
    fn default() -> Self {
        SendClient::new(0)
    }
}

// ── DEFECT-3: sync concrete-impl-mono'd opaque param (`&C` → `&Db`) ─────────
// A SYNC method bounded by a single-impl trait `Wire` (`impl Wire for Db`)
// monomorphizes to `C = Db`. The raw Rust param type is `&Db` (borrowed), but
// the Sky surface is the OWNED `Db`. Pre-fix the codegen keeps `&Db` in the
// wrapper sig → Sky passes owned `Db` → E0308. Post-fix: owned param + reborrow.

impl Req {
    /// POSITIVE (DEFECT-3): sync generic method; `C: Wire` has ONE impl (Db) →
    /// monomorphize C = Db. Returns `"tag <field>"`. Pure/fallible return.
    pub fn tag<C: Wire>(&self, _client: &C) -> String {
        format!("tag {}", self.field)
    }
}
