//! 78-ffi-async-opaque-ctor: async constructor returning an opaque handle.
//!
//! Mirrors the `FirestoreDb::new(project)` / `firestore::FirestoreDb` shape:
//! an async free function returns an OPAQUE, NOT-Clone handle by value.  Sky
//! task #61 extends the async output-Send gate to admit opaque types that are
//! provably `Send` (via explicit `impl Send`, all-fields-Send, or Send-supertrait
//! impls).
//!
//! NOT an author example — a Rust-backend FFI test fixture.  Lives under
//! `runtime-rust/tests/sky/` per the boundary rule (examples/ is the author's).
//!
//! POSITIVE (must BIND end-to-end):
//!   Client::new("proj") → async fn, returns `Result<Client, String>`
//!     Client is NOT Clone, IS Send (explicit `unsafe impl Send` + all-fields-Send
//!     proof: single `String` field).  Pre-#61 the output-Send gate dropped it
//!     because `is_async_send_output("Client")` returns false; post-#61 the gate
//!     consults PROVABLY_SEND_RECV_NAMES which includes "Client" → BIND.
//!   Client::ping(&self) → async instance method; receiver is Send-proven → BIND.
//!
//! NEGATIVE (must DROP — absent from bindings, never cargo-fail):
//!   RcClient::new() → async fn returns `Result<RcClient, String>`;
//!     RcClient is NOT Send (holds Rc) → PROVABLY_SEND_RECV_NAMES absent → DROP.
//!   RcClient::poke(&self) → async method on !Send receiver → DROP.

use std::rc::Rc;

/// POSITIVE: the Send-proven opaque handle.
///
/// Holds a single `String` field (all-fields-Send, plus explicit `unsafe impl
/// Send` redundancy for clarity).  NOT Clone: the Sky binding must receive it
/// by value (the opaque-return shape).
pub struct Client {
    project: String,
}

// Explicit Send impl — populates EXPLICIT_SEND_TYPE_IDS → PROVABLY_SEND_RECV_NAMES.
unsafe impl Send for Client {}

impl Client {
    /// POSITIVE: async constructor — returns the opaque handle by value.
    ///
    /// Sig: `async fn new(project: &str) -> Result<Client, String>`
    /// Pre-#61: output-Send gate drops `Client` → absent.
    /// Post-#61: `Client` in PROVABLY_SEND_RECV_NAMES → BIND.
    pub async fn new(project: &str) -> Result<Client, String> {
        Ok(Client {
            project: project.to_string(),
        })
    }

    /// POSITIVE: async instance method on a Send-proven receiver.
    ///
    /// Returns `Result<i64, String>` (inner type `i64` is trivially Send).
    /// Demonstrates the constructed handle can be used after async-opaque-ctor bind.
    pub async fn ping(&self) -> Result<i64, String> {
        // Simulate a tiny async operation without a tokio dep.
        // Returns the project-name length as a sentinel value.
        Ok(self.project.len() as i64)
    }
}

/// NEGATIVE: the !Send opaque handle (Rc-bearing).
///
/// NOT Send because `Rc` is `!Send`.  Must be ABSENT from PROVABLY_SEND_RECV_NAMES.
/// Its async ctor must DROP (output-Send gate refuses it even after #61 because
/// the set is conservative — unprovable types never enter it).
#[allow(dead_code)]
pub struct RcClient {
    _shared: Rc<u8>,
    project: String,
}

impl RcClient {
    /// NEGATIVE: async ctor returning !Send opaque → DROP.
    /// Pre-#61 AND post-#61: RcClient is not in PROVABLY_SEND_RECV_NAMES → DROP.
    #[allow(dead_code)]
    pub async fn new(project: &str) -> Result<RcClient, String> {
        Ok(RcClient {
            _shared: Rc::new(0),
            project: project.to_string(),
        })
    }

    /// NEGATIVE: async instance method on !Send receiver → DROP.
    #[allow(dead_code)]
    pub async fn poke(&self) -> Result<i64, String> {
        Ok(1)
    }
}
