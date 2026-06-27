//! JWT kernels for Sky.Core.Jwt — HS256 / RS256 encode + decode.

use super::SkyResult;

use jsonwebtoken::{decode, encode, Algorithm, DecodingKey, EncodingKey, Header, Validation};
use serde_json::Value as JsonValue;

/// Sky `Jwt_encodeHs256 : String -> String -> Result Error String`
pub fn jwt_encode_hs256<E: From<String>>(secret: String, claims_json: String) -> SkyResult<E, String> {
    // An EMPTY HMAC key is never a legitimate signing secret — the token it mints
    // is forgeable by anyone (HMAC-SHA256 with a zero-length key). Reject it
    // rather than emit a trivially-forgeable token. (Std.Auth enforces a 32-byte
    // floor upstream; this catches a direct misconfigured Jwt.* caller.)
    if secret.is_empty() {
        return SkyResult::Err("jwt-encode: HS256 secret must not be empty".to_string().into());
    }
    let claims: JsonValue = match serde_json::from_str(&claims_json) {
        Ok(v) => v,
        Err(e) => return SkyResult::Err(format!("jwt-encode: bad claims json: {}", e).into()),
    };
    let header = Header::new(Algorithm::HS256);
    let key = EncodingKey::from_secret(secret.as_bytes());
    match encode(&header, &claims, &key) {
        Ok(t) => SkyResult::Ok(t),
        Err(e) => SkyResult::Err(format!("jwt-encode: {}", e).into()),
    }
}

/// Sky `Jwt_decodeHs256 : String -> String -> Result Error String`
pub fn jwt_decode_hs256<E: From<String>>(secret: String, token: String) -> SkyResult<E, String> {
    // Reject verification under an empty HMAC key — see jwt_encode_hs256. A token
    // "verified" with a zero-length key carries no authenticity guarantee.
    if secret.is_empty() {
        return SkyResult::Err("jwt-decode: HS256 secret must not be empty".to_string().into());
    }
    let key = DecodingKey::from_secret(secret.as_bytes());
    let mut validation = Validation::new(Algorithm::HS256);
    validation.validate_exp = true;
    validation.validate_nbf = true;
    // These are GENERIC decoders with no expected-audience argument, so a specific
    // `aud` cannot be enforced here. jsonwebtoken's default `validate_aud = true`
    // would then REJECT any token that merely CARRIES an `aud` claim (error
    // InvalidAudience) — breaking the documented audience feature + Go parity.
    // Disable aud validation; audience-scoped checks belong to a future
    // expected-audience decoder variant.
    validation.validate_aud = false;
    // Keep `exp` required (jsonwebtoken's default) so an omitted-exp token is
    // rejected rather than treated as non-expiring — matches Go's exp/nbf check
    // and aligns with auth.rs's verify path (which never clears required claims).
    match decode::<JsonValue>(&token, &key, &validation) {
        Ok(data) => match serde_json::to_string(&data.claims) {
            Ok(s) => SkyResult::Ok(s),
            Err(e) => SkyResult::Err(format!("jwt-decode: re-encode claims: {}", e).into()),
        },
        Err(e) => SkyResult::Err(format!("jwt-decode: {}", e).into()),
    }
}

/// Sky `Jwt_encodeRs256 : String -> String -> Result Error String`
pub fn jwt_encode_rs256<E: From<String>>(key_pem: String, claims_json: String) -> SkyResult<E, String> {
    let claims: JsonValue = match serde_json::from_str(&claims_json) {
        Ok(v) => v,
        Err(e) => return SkyResult::Err(format!("jwt-encode-rs: bad claims: {}", e).into()),
    };
    let header = Header::new(Algorithm::RS256);
    let key = match EncodingKey::from_rsa_pem(key_pem.as_bytes()) {
        Ok(k) => k,
        // Suppress the parse-error detail to avoid leaking structural hints
        // about the key material (e.g. PEM framing, DER structure).
        Err(_) => return SkyResult::Err("jwt-encode-rs: invalid RSA key".to_string().into()),
    };
    match encode(&header, &claims, &key) {
        Ok(t) => SkyResult::Ok(t),
        Err(e) => SkyResult::Err(format!("jwt-encode-rs: {}", e).into()),
    }
}

/// Sky `Jwt_decodeRs256 : String -> String -> Result Error String`
pub fn jwt_decode_rs256<E: From<String>>(key_pem: String, token: String) -> SkyResult<E, String> {
    let key = match DecodingKey::from_rsa_pem(key_pem.as_bytes()) {
        Ok(k) => k,
        // Suppress the parse-error detail to avoid leaking structural hints
        // about the key material (e.g. PEM framing, DER structure).
        Err(_) => return SkyResult::Err("jwt-decode-rs: invalid RSA key".to_string().into()),
    };
    let mut validation = Validation::new(Algorithm::RS256);
    validation.validate_exp = true;
    validation.validate_nbf = true;
    // These are GENERIC decoders with no expected-audience argument, so a specific
    // `aud` cannot be enforced here. jsonwebtoken's default `validate_aud = true`
    // would then REJECT any token that merely CARRIES an `aud` claim (error
    // InvalidAudience) — breaking the documented audience feature + Go parity.
    // Disable aud validation; audience-scoped checks belong to a future
    // expected-audience decoder variant.
    validation.validate_aud = false;
    // Keep `exp` required (jsonwebtoken's default) so an omitted-exp token is
    // rejected rather than treated as non-expiring — matches Go's exp/nbf check
    // and aligns with auth.rs's verify path (which never clears required claims).
    match decode::<JsonValue>(&token, &key, &validation) {
        Ok(data) => match serde_json::to_string(&data.claims) {
            Ok(s) => SkyResult::Ok(s),
            Err(e) => SkyResult::Err(format!("jwt-decode-rs: re-encode: {}", e).into()),
        },
        Err(e) => SkyResult::Err(format!("jwt-decode-rs: {}", e).into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hs256_roundtrip() {
        let secret = "my-secret".to_string();
        let claims = r#"{"sub":"alice","exp":9999999999}"#.to_string();
        let token: SkyResult<String, String> = jwt_encode_hs256(secret.clone(), claims.clone());
        let token = match token { SkyResult::Ok(t) => t, SkyResult::Err(e) => panic!("encode: {}", e) };
        let decoded: SkyResult<String, String> = jwt_decode_hs256(secret, token);
        let decoded = match decoded { SkyResult::Ok(s) => s, SkyResult::Err(e) => panic!("decode: {}", e) };
        assert!(decoded.contains("alice"));
    }

    #[test]
    fn test_hs256_wrong_secret_fails() {
        let token: SkyResult<String, String> = jwt_encode_hs256("right".to_string(),
            r#"{"sub":"x","exp":9999999999}"#.to_string());
        let token = match token {
            SkyResult::Ok(t) => t, SkyResult::Err(e) => panic!("encode: {}", e),
        };
        let bad: SkyResult<String, String> = jwt_decode_hs256("wrong".to_string(), token);
        assert!(matches!(bad, SkyResult::Err(_)));
    }

    #[test]
    fn test_hs256_empty_secret_rejected() {
        // Empty HMAC secret → forgeable token; both encode and verify must refuse.
        let enc: SkyResult<String, String> =
            jwt_encode_hs256(String::new(), r#"{"sub":"x","exp":9999999999}"#.to_string());
        assert!(matches!(enc, SkyResult::Err(_)));
        let dec: SkyResult<String, String> =
            jwt_decode_hs256(String::new(), "a.b.c".to_string());
        assert!(matches!(dec, SkyResult::Err(_)));
    }
}
