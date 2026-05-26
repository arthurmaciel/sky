//! Property-based tests for the Sky Rust runtime.

use proptest::prelude::*;
use sky_runtime_rust::*;

// ═══════════════════════════════════════════════════════════════════
// Core types — direct from the runtime
// ═══════════════════════════════════════════════════════════════════

proptest! {
    #[test]
    fn result_with_default_ok(def: i64, x: i64) {
        let r: SkyResult<&str, i64> = SkyResult::Ok(x);
        prop_assert_eq!(result_with_default(def, r), x);
    }

    #[test]
    fn result_with_default_err(def: i64, s: String) {
        let r: SkyResult<String, i64> = SkyResult::Err(s);
        prop_assert_eq!(result_with_default(def, r), def);
    }

    #[test]
    fn result_map_id(x: i64) {
        let r: SkyResult<&str, i64> = SkyResult::Ok(x);
        let mapped = sky_result_map(r, |v| v);
        prop_assert_eq!(mapped, SkyResult::Ok(x));
    }

    #[test]
    fn maybe_map_id(x: i64) {
        let m: SkyMaybe<i64> = SkyMaybe::Just(x);
        let mapped = sky_maybe_map(m, |v| v);
        prop_assert_eq!(mapped, SkyMaybe::Just(x));
    }
}

// ═══════════════════════════════════════════════════════════════════
// String operations
// ═══════════════════════════════════════════════════════════════════

proptest! {
    #[test]
    fn string_length_appends(a: String, b: String) {
        let ab = string_append(a.clone(), b.clone());
        prop_assert_eq!(string_length(ab), string_length(a) + string_length(b));
    }

    #[test]
    fn string_reverse_involution(s: String) {
        let rev = string_reverse(s.clone());
        prop_assert_eq!(string_reverse(rev), s);
    }

    #[test]
    fn string_trim_noop_on_plain(s: String) {
        let plain: String = s.chars().filter(|c| !c.is_whitespace()).collect();
        let trimmed = string_trim(plain.clone());
        prop_assert_eq!(trimmed, plain);
    }

    #[test]
    fn string_to_int_roundtrip(n: i64) {
        let s = string_from_int(n);
        let parsed = string_to_int(s);
        prop_assert_eq!(parsed, SkyMaybe::Just(n));
    }
}

// ═══════════════════════════════════════════════════════════════════
// Task combinators (require tokio feature)
// ═══════════════════════════════════════════════════════════════════

#[cfg(feature = "tokio")]
mod task_tests {
    use sky_runtime_rust::*;

    fn run<A: Send + 'static>(task: SkyTask<SkyError, A>) -> SkyResult<SkyError, A> {
        task_run(task)
    }

    fn mk_task<A: Send + 'static>(a: A) -> SkyTask<SkyError, A> {
        sky_runtime::task::task_succeed::<SkyError, A>(a)
    }

    #[test]
    fn task_succeed_ok() {
        assert_eq!(run(mk_task(42)), SkyResult::Ok(42));
    }

    #[test]
    fn task_map_ok() {
        let f = |x: i64| x + 1;
        assert_eq!(run(task_map(f, mk_task(41))), SkyResult::Ok(42));
    }

    #[test]
    fn task_and_then_ok() {
        let f = |x: i64| mk_task(x * 2);
        assert_eq!(run(task_and_then(f, mk_task(21))), SkyResult::Ok(42));
    }

    #[test]
    fn task_fail_is_err() {
        let err: SkyError = str_err("boom");
        let t: SkyTask<SkyError, i64> = sky_runtime::task::task_fail::<SkyError, i64>(err);
        assert!(run(t).is_err());
    }
}

// ═══════════════════════════════════════════════════════════════════
// JSON encode/decode (require json feature)
// ═══════════════════════════════════════════════════════════════════

#[cfg(feature = "json")]
mod json_tests {
    use sky_runtime_rust::*;

    #[test]
    fn json_int_roundtrip() {
        let json = sky_runtime::json::json_enc_int(42);
        let encoded = sky_runtime::json::json_enc_encode(0, json);
        let decoder: Decoder<SkyError, i64> = sky_runtime::json::json_dec_int();
        let decoded = sky_runtime::json::json_dec_decode_string(decoder, encoded);
        assert_eq!(decoded, SkyResult::Ok(42));
    }

    #[test]
    fn json_string_roundtrip() {
        let json = sky_runtime::json::json_enc_string("hello".to_string());
        let encoded = sky_runtime::json::json_enc_encode(0, json);
        let decoder: Decoder<SkyError, String> = sky_runtime::json::json_dec_string();
        let decoded = sky_runtime::json::json_dec_decode_string(decoder, encoded);
        assert_eq!(decoded, SkyResult::Ok("hello".to_string()));
    }

    #[test]
    fn json_bool_roundtrip() {
        let json = sky_runtime::json::json_enc_bool(true);
        let encoded = sky_runtime::json::json_enc_encode(0, json);
        let decoder: Decoder<SkyError, bool> = sky_runtime::json::json_dec_bool();
        let decoded = sky_runtime::json::json_dec_decode_string(decoder, encoded);
        assert_eq!(decoded, SkyResult::Ok(true));
    }
}

// ═══════════════════════════════════════════════════════════════════
// Standalone tests (not property-based, but useful signals)
// ═══════════════════════════════════════════════════════════════════

#[test]
fn string_is_empty_true() {
    assert!(string_is_empty("".to_string()));
}

#[test]
fn string_to_int_fails_on_bad_input() {
    assert_eq!(string_to_int("not a number".to_string()), SkyMaybe::Nothing);
}

#[test]
fn string_to_lower_upper_consistent() {
    let s = "Hello World".to_string();
    let upper = string_to_upper(s.clone());
    let lower_upper = string_to_lower(upper);
    let lower = string_to_lower(s);
    assert_eq!(lower_upper, lower);
}

// ═══════════════════════════════════════════════════════════════════
// Byte-sequence FFI coercion helpers
// ═══════════════════════════════════════════════════════════════════

proptest! {
    // to_u8_vec then widen back is identity on in-range bytes.
    #[test]
    fn byte_vec_roundtrip(xs in proptest::collection::vec(0u8..=255, 0..64)) {
        let as_i64: Vec<i64> = xs.iter().map(|&b| b as i64).collect();
        prop_assert_eq!(to_u8_vec(&as_i64), xs.clone());
        prop_assert_eq!(from_u8_slice(&xs), as_i64);
    }

    // to_u8_array succeeds iff the input length matches N; never panics.
    #[test]
    fn to_u8_array_len_checked(xs in proptest::collection::vec(0i64..256, 0..40)) {
        let r: SkyResult<String, [u8; 16]> = to_u8_array(&xs);
        if xs.len() == 16 {
            prop_assert!(r.is_ok());
        } else {
            prop_assert!(r.is_err());
        }
    }
}
