//! F1 regression: the verification-SKIPPING emulator path must be refused when
//! ENV/SKY_ENV marks production, even if FIREBASE_AUTH_EMULATOR_HOST is set.
//! Emulator-free — the refusal is an early return before any network.
use sky_firebase_auth_shim::fb_verify_id_token;

#[test]
fn emulator_refused_in_production() {
    std::env::set_var("FIREBASE_AUTH_EMULATOR_HOST", "127.0.0.1:9099");
    std::env::set_var("ENV", "production");
    let r = fb_verify_id_token("forged.unsigned.token");
    std::env::remove_var("ENV");
    std::env::remove_var("FIREBASE_AUTH_EMULATOR_HOST");
    assert!(r.is_err(), "expected refusal, got {r:?}");
    assert!(r.unwrap_err().contains("refused outside dev"));
}
