//! Encoding kernels for Sky.Core.Encoding — base64 / url-percent / hex
//! All fns mirror the Go runtime's `stdlib_extra.go` Encoding kernel behaviour
//! and the Sky-side signatures declared in `sky-stdlib/Sky/Core/Encoding.sky`.

use super::SkyResult;

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use percent_encoding::{utf8_percent_encode, percent_decode_str, NON_ALPHANUMERIC};

// ── Bytes-on-Rust convention (sub-D) ──────────────────────────────────────
//
// Sky models raw bytes as `String` (`type alias Bytes = String`), relying on
// Go strings being arbitrary byte sequences. A Rust `String` must be valid
// UTF-8, so raw bytes (HMAC digests, hexDecode output) can't be stored as their
// literal bytes. We use a LATIN-1 convention: a "bytes" String holds one char
// per byte (codepoints U+0000..U+00FF, always valid UTF-8). The hex/base64
// kernels read input char-as-byte and emit decoded bytes byte-as-char, so the
// byte pipeline is lossless and self-consistent — `base64(hexDecode(hmac))`
// (the JWT signature path) now produces the correct bytes.
//
// Divergence from the Go backend: for NON-ASCII *text*, char-as-byte differs
// from UTF-8 bytes (e.g. 'é' -> 0xE9 here vs 0xC3 0xA9 on Go). Encode/decode
// still round-trip within the Rust backend; only the encoded string compared
// against an externally-/Go-computed value diverges. ASCII is identical to Go.

/// Interpret a (Latin-1) Sky byte-string as raw bytes: one char -> one byte.
/// Shared with other byte-handling kernels (compression, …).
pub(crate) fn sky_bytes(s: &str) -> Vec<u8> {
    s.chars().map(|c| c as u8).collect()
}

/// Wrap raw bytes as a (Latin-1) Sky byte-string: one byte -> one char.
pub(crate) fn bytes_to_sky(bytes: &[u8]) -> String {
    bytes.iter().map(|&b| b as char).collect()
}

/// Decode an application/x-www-form-urlencoded component: `+` -> space, `%XX` ->
/// byte (best-effort). Shared by the HTTP server's query parser and the HTTP
/// client's parseQuery so they stay consistent.
//
// NOT cfg-gated: generated projects compile the runtime WITHOUT cargo features
// (their server.rs is always included), so a `#[cfg(feature=…)]` gate would drop
// this from generated server builds and break them. In the standalone crate it
// only looks dead under a feature subset, hence `allow(dead_code)`.
#[allow(dead_code)]
pub(crate) fn form_url_decode(s: &str) -> String {
    let s = s.replace('+', " ");
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while let Some(&c) = b.get(i) {
        if c == b'%' {
            // `s.get(range)` is total — None when out of bounds OR not on a char
            // boundary; falls through to copying the literal '%'.
            if let Some(byte) = s.get(i + 1..i + 3).and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(byte);
                i += 3;
                continue;
            }
        }
        out.push(c);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Sky `base64Encode : String -> String`
pub fn base64_encode(s: String) -> String {
    B64.encode(sky_bytes(&s))
}

/// Sky `base64Decode : String -> Result Error String`
pub fn base64_decode<E: From<String>>(s: String) -> SkyResult<E, String> {
    match B64.decode(s.as_bytes()) {
        Ok(bytes) => SkyResult::Ok(bytes_to_sky(&bytes)),
        Err(e) => SkyResult::Err(format!("base64: {}", e).into()),
    }
}

/// Sky `urlEncode : String -> String` — Go url.QueryEscape semantics: space
/// becomes `+` (not %20), other non-alphanumerics percent-encoded.
pub fn url_encode(s: String) -> String {
    // NON_ALPHANUMERIC encodes space as %20; QueryEscape uses '+'. Encode '+'
    // itself as %2B first so the swap is unambiguous on decode.
    utf8_percent_encode(&s, NON_ALPHANUMERIC).to_string().replace("%20", "+")
}

/// Sky `urlDecode : String -> Result Error String` — QueryUnescape: `+` -> space,
/// then percent-decode (so a literal `%2B` round-trips back to `+`).
pub fn url_decode<E: From<String>>(s: String) -> SkyResult<E, String> {
    let spaced = s.replace('+', " ");
    match percent_decode_str(&spaced).decode_utf8() {
        Ok(cow) => SkyResult::Ok(cow.into_owned()),
        Err(e) => SkyResult::Err(format!("urlDecode: {}", e).into()),
    }
}

/// Sky `hexEncode : String -> String`
pub fn encoding_hex_encode(s: String) -> String {
    hex::encode(sky_bytes(&s))
}

/// Sky `hexDecode : String -> Result Error String` — decoded bytes are returned
/// as a Latin-1 byte-string (never errors on non-UTF-8 — that's the whole point
/// of the bytes convention; the JWT signature path depends on it).
pub fn encoding_hex_decode<E: From<String>>(s: String) -> SkyResult<E, String> {
    match hex::decode(&s) {
        Ok(bytes) => SkyResult::Ok(bytes_to_sky(&bytes)),
        Err(e) => SkyResult::Err(format!("hexDecode: {}", e).into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_base64_roundtrip() {
        let encoded = base64_encode("Hello, Sky!".to_string());
        assert_eq!(encoded, "SGVsbG8sIFNreSE=");
        let decoded: SkyResult<String, String> = base64_decode(encoded);
        assert!(matches!(decoded, SkyResult::Ok(ref s) if s == "Hello, Sky!"));
    }

    #[test]
    fn test_base64_decode_invalid() {
        let bad: SkyResult<String, String> = base64_decode("not-valid-base64!@#".to_string());
        assert!(matches!(bad, SkyResult::Err(_)));
    }

    #[test]
    fn test_url_roundtrip() {
        let encoded = url_encode("hello world/foo?bar=baz&q=á".to_string());
        assert!(encoded.contains('+'));    // space -> '+' (Go QueryEscape)
        assert!(!encoded.contains("%20"));
        assert!(encoded.contains("%2F")); // slash
        let decoded: SkyResult<String, String> = url_decode(encoded);
        assert!(matches!(decoded, SkyResult::Ok(ref s) if s == "hello world/foo?bar=baz&q=á"));
    }

    #[test]
    fn test_url_decode_invalid() {
        let bad: SkyResult<String, String> = url_decode("bad-utf8-%C0".to_string());
        assert!(matches!(bad, SkyResult::Err(_)));
    }

    #[test]
    fn test_hex_roundtrip() {
        let encoded = encoding_hex_encode("Hi!".to_string());
        assert_eq!(encoded, "486921");
        let decoded: SkyResult<String, String> = encoding_hex_decode(encoded);
        assert!(matches!(decoded, SkyResult::Ok(ref s) if s == "Hi!"));
    }

    #[test]
    fn test_encoding_hex_decode_invalid() {
        let bad: SkyResult<String, String> = encoding_hex_decode("zz".to_string());
        assert!(matches!(bad, SkyResult::Err(_)));
        let odd: SkyResult<String, String> = encoding_hex_decode("a".to_string());
        assert!(matches!(odd, SkyResult::Err(_)));
    }
}
