//! sky-firebase-auth-shim — REAL `rs-firebase-admin-sdk` 4.3-backed surface for
//! the skyshop-rs Sky→Rust port (Stage 4).
//!
//! This is the FULL FFI surface the app's `Lib/Auth.sky` needs. The single
//! public fn is a TOTAL `fn(..) -> Result<_, String>` the Sky auto-FFI binds as
//! a synchronous Sky `Result` (D1), with the D3 flat shape:
//!
//!   * verified identity → `Result<HashMap<String,String>, String>`
//!     (Sky: `Result String (Dict String String)`)
//!
//! ERROR-SLOT WRINKLE (Stage-0): the Sky side reads its status from the *Ok*
//! Dict, not the `Err` slot (`Err _ ->` discards the payload). On success the
//! Ok payload carries `"_status" = "ok"` plus `uid` / `email` / `name` (the keys
//! `Lib/Auth.sky` reads via `Db.getField`). Verification failures still go
//! through `Err(String)` — `verifyToken` maps any `Err` to a typed
//! `permissionDenied` — but the meaningful contract is the flat Ok row.
//!
//! BACKEND: `rs-firebase-admin-sdk` 4.3 (`tokens` feature → jsonwebtoken +
//! jsonwebtoken-jwks-cache). Two verifier paths:
//!
//!   * EMULATOR (`FIREBASE_AUTH_EMULATOR_HOST` set) — `App::emulated()` +
//!     `app.id_token_verifier()` returns `EmulatorValidator`, which base64-
//!     decodes the JWT claims WITHOUT signature/aud/iss/exp checks (emulator
//!     tokens are `alg=none`, so JWKS verification is intentionally skipped).
//!   * LIVE (env unset) — `App::live().await` (Application Default Credentials)
//!     + `app.id_token_verifier()?` returns `LiveValidator`, which performs full
//!     RS256 verification against Google's `securetoken` JWKS plus `aud`/`iss`/
//!     `exp` checks for the resolved project id.
//!
//! Both paths funnel through the same `TokenValidator::validate(token).await`
//! call returning `HashMap<String, serde_json::Value>` of JWT claims; the shim
//! flattens the claims it needs (`sub`→`uid`, `email`, `name`, plus a few common
//! Firebase claims) to `String`.
//!
//! All `&str` params (Sky passes `&arg`); owned internally.
//!
//! ASYNC BRIDGE: the SDK is async (reqwest/tokio under the hood). The op builds a
//! future and drives it to completion on a dedicated current-thread tokio runtime
//! that lives on a spawned OS thread — the same pattern as the Stage-2 firestore
//! / Stage-3 stripe shims and `runtime-rust/src/sky_runtime/task.rs::block_on`.
//! `.join()` converts any internal panic into an `Err(String)` so NO panic
//! escapes the FFI boundary.
//!
//! NO panic / NO unwrap reachable: every `.await?` / decode / claim lookup maps
//! to `Err(String)` or a missing-claim empty string.

use std::collections::HashMap;
use std::future::Future;

use rs_firebase_admin_sdk::{App, jwt::TokenValidator};
use serde_json::Value;

/// Drive an async future to completion on a dedicated current-thread tokio
/// runtime, off the calling thread. A panic inside the future (or runtime) is
/// caught by `.join()` and mapped to `Err(String)` — nothing escapes.
///
/// Pattern mirrors the Stage-2/3 shims and
/// `runtime-rust/src/sky_runtime/task.rs::block_on`.
fn block_on<T, F>(fut: F) -> Result<T, String>
where
    T: Send + 'static,
    F: Future<Output = Result<T, String>> + Send + 'static,
{
    let join = std::thread::spawn(move || {
        let rt = match tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        {
            Ok(r) => r,
            Err(e) => return Err(format!("tokio runtime init failed: {e}")),
        };
        rt.block_on(fut)
    })
    .join();

    match join {
        Ok(r) => r,
        Err(_) => Err("firebase auth shim: async task panicked".to_string()),
    }
}

/// Coerce a claim `Value` to a flat `String`. Strings pass through unquoted;
/// everything else (number / bool) renders via its JSON form so the flat-row
/// contract never carries surrounding quotes for the common string claims.
fn claim_str(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

/// Pull `key` out of the claims map as a flat `String`, or empty if absent.
fn get_claim(claims: &HashMap<String, Value>, key: &str) -> String {
    claims.get(key).map(claim_str).unwrap_or_default()
}

/// Run the appropriate verifier (emulator vs live) for `token` and return the
/// raw claim map. Emulator mode is selected when `FIREBASE_AUTH_EMULATOR_HOST`
/// is set — emulator tokens are `alg=none`, so the emulator validator decodes
/// claims without JWKS signature checks. Live mode performs full RS256 + aud/iss
/// /exp verification against Google's certs.
async fn validate_claims(token: String) -> Result<HashMap<String, Value>, String> {
    if std::env::var("FIREBASE_AUTH_EMULATOR_HOST").is_ok() {
        // Emulator: synchronous App construction, infallible verifier.
        let app = App::emulated();
        let verifier = app.id_token_verifier();
        verifier
            .validate(&token)
            .await
            .map_err(|e| format!("firebase auth: emulator token verification failed: {e:?}"))
    } else {
        // Live: ADC-backed App, JWKS-backed verifier (both fallible).
        let app = App::live()
            .await
            .map_err(|e| format!("firebase auth: live app init failed: {e:?}"))?;
        let verifier = app
            .id_token_verifier()
            .map_err(|e| format!("firebase auth: live verifier init failed: {e:?}"))?;
        verifier
            .validate(&token)
            .await
            .map_err(|e| format!("firebase auth: token verification failed: {e:?}"))
    }
}

/// `fb_verify_id_token(id_token) -> Result<HashMap<String,String>, String>`
/// Sky: `Result String (Dict String String)`. Verifies a Firebase ID token
/// (signature + `exp`/`iss`/`aud` in live mode; claim decode in emulator mode)
/// and returns the verified identity as a flat row: `_status` / `uid` / `email`
/// / `name` (+ common Firebase claims the app may read). An empty token is a
/// verification failure (`Err`) — preserving the Stage-1 stub convention.
pub fn fb_verify_id_token(id_token: &str) -> Result<HashMap<String, String>, String> {
    if id_token.is_empty() {
        return Err("firebase auth: empty id token".to_string());
    }
    let token = id_token.to_string();

    block_on(async move {
        let claims = validate_claims(token).await?;

        // `sub` is the Firebase uid (emulator's `localId` lands here too).
        let uid = get_claim(&claims, "sub");
        if uid.is_empty() {
            return Err("firebase auth: token missing 'sub' (uid) claim".to_string());
        }

        let mut m = HashMap::new();
        m.insert("_status".to_string(), "ok".to_string());
        m.insert("uid".to_string(), uid);
        m.insert("email".to_string(), get_claim(&claims, "email"));
        // Firebase ID tokens carry the display name as `name`.
        m.insert("name".to_string(), get_claim(&claims, "name"));

        // Surface a few additional standard Firebase claims when present so the
        // Sky side can read them via `Db.getField` without re-verifying. Absent
        // claims are simply omitted (empty-string semantics on the read side).
        for key in ["email_verified", "picture", "auth_time", "phone_number"] {
            if let Some(v) = claims.get(key) {
                let s = claim_str(v);
                if !s.is_empty() {
                    m.insert(key.to_string(), s);
                }
            }
        }

        Ok(m)
    })
}

#[cfg(test)]
mod emulator_test {
    use super::*;

    /// End-to-end against a running Firebase Auth emulator:
    ///   1. mint a user via the emulator REST signUp endpoint (returns idToken),
    ///   2. prove `fb_verify_id_token(idToken)` decodes the right uid/email.
    /// Skipped (passes vacuously) when `FIREBASE_AUTH_EMULATOR_HOST` is unset so
    /// `cargo test` stays green in CI without an emulator.
    #[test]
    fn verify_emulator_token_roundtrip() {
        let Ok(host) = std::env::var("FIREBASE_AUTH_EMULATOR_HOST") else {
            eprintln!("FIREBASE_AUTH_EMULATOR_HOST unset — skipping emulator roundtrip");
            return;
        };

        // Mint a token from the emulator (signUp). Done on its own runtime so
        // this stays independent of the shim's bridge.
        let email = format!("stage4-{}@example.com", std::process::id());
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("rt");
        let id_token: String = rt.block_on(async {
            let url = format!(
                "http://{host}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-api-key"
            );
            let body = serde_json::json!({
                "email": email,
                "password": "hunter2hunter2",
                "returnSecureToken": true,
            });
            let resp: Value = reqwest::Client::new()
                .post(&url)
                .json(&body)
                .send()
                .await
                .expect("signUp send")
                .json()
                .await
                .expect("signUp json");
            resp.get("idToken")
                .and_then(Value::as_str)
                .expect("idToken in signUp response")
                .to_string()
        });

        let row = fb_verify_id_token(&id_token).expect("verify ok");
        assert_eq!(row.get("_status").map(String::as_str), Some("ok"));
        assert_eq!(row.get("email").map(String::as_str), Some(email.as_str()));
        assert!(
            row.get("uid").map(|s| !s.is_empty()).unwrap_or(false),
            "uid must be a non-empty sub claim, got {:?}",
            row.get("uid")
        );

        // Empty token must still be Err (stub convention preserved).
        assert!(fb_verify_id_token("").is_err());
    }
}
