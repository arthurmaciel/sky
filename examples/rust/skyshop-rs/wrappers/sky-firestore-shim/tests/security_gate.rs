//! F1 regression: the unauthenticated emulator path must be refused when
//! ENV/SKY_ENV marks production, even if FIRESTORE_EMULATOR_HOST is set.
use sky_firestore_shim::fs_query;

#[test]
fn emulator_refused_in_production() {
    std::env::set_var("FIRESTORE_EMULATOR_HOST", "127.0.0.1:8412");
    std::env::set_var("ENV", "production");
    let r = fs_query("products");
    std::env::remove_var("ENV");
    std::env::remove_var("FIRESTORE_EMULATOR_HOST");
    assert!(r.is_err(), "expected refusal, got {r:?}");
    assert!(r.unwrap_err().contains("refused outside dev"));
}
