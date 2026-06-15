//! sky-firebase-auth-shim — STUB surface for the skyshop-rs Sky→Rust port (Stage 1).
//!
//! Full FFI surface the app's `Lib/Auth.sky` needs, canned body, ZERO heavy
//! deps. TOTAL `fn(..) -> Result<_, String>` binding as a sync Sky `Result`
//! (D1), flat D3 shape. All `&str` params.
//!
//! Stage 4 swaps this for the real `rs-firebase-admin-sdk` D2-bridge, emulator
//! aware via `FIREBASE_AUTH_EMULATOR_HOST`.

use std::collections::HashMap;

/// `fb_verify_id_token(id_token) -> Result<HashMap<String,String>, String>`
/// Sky: `Result String (Dict String String)`. Returns the verified identity as
/// a flat row: `uid` / `email` / `name`. The stub derives a deterministic
/// identity from the token text so different sign-ins produce different users,
/// and treats an empty token as a verification failure (Err).
pub fn fb_verify_id_token(id_token: &str) -> Result<HashMap<String, String>, String> {
    if id_token.is_empty() {
        return Err("firebase auth: empty id token".to_string());
    }
    // Deterministic stub identity keyed off the token so the flow is stable.
    let uid = format!("uid_stub_{}", short_hash(id_token));
    let mut m = HashMap::new();
    m.insert("_status".to_string(), "ok".to_string());
    m.insert("uid".to_string(), uid.clone());
    m.insert("email".to_string(), format!("{uid}@example.com"));
    m.insert("name".to_string(), "Test User".to_string());
    Ok(m)
}

/// Tiny non-cryptographic hash for a stable stub uid. (FNV-1a, total.)
fn short_hash(s: &str) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in s.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{:x}", h & 0xffffffff)
}
