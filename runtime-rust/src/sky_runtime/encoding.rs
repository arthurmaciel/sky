//! Encoding kernels for Sky.Core.Encoding — base64 / url-percent / hex
//! All fns mirror the Go runtime's `stdlib_extra.go` Encoding kernel behaviour
//! and the Sky-side signatures declared in `sky-stdlib/Sky/Core/Encoding.sky`.

use super::{SkyMaybe, SkyResult};

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use percent_encoding::{utf8_percent_encode, percent_decode_str, NON_ALPHANUMERIC};

// ── Bytes-on-Rust convention ──────────────────────────────────────────────
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
    // A percent-escape is "%XX": a '%' marker followed by two hex digits, e.g.
    // "%20" → 0x20 (space). RFC 3986 §2.1.
    const PCT: u8 = b'%';
    const HEX: u32 = 16;
    const HEX_DIGITS: usize = 2;
    const ESCAPE_LEN: usize = 1 + HEX_DIGITS; // '%' + two hex digits

    let s = s.replace('+', " ");
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while let Some(&c) = b.get(i) {
        if c == PCT {
            // The two hex digits sit at [i+1, i+1+HEX_DIGITS). `str::get(range)`
            // is total — None when out of bounds OR not on a char boundary (e.g.
            // a stray '%' before a multi-byte char) — so we fall through and copy
            // the literal '%' rather than panicking.
            let hex = s.get(i + 1..i + 1 + HEX_DIGITS);
            if let Some(byte) = hex.and_then(|h| u8::from_str_radix(h, HEX).ok()) {
                out.push(byte);
                i += ESCAPE_LEN;
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

// ── Sky.Core.Bytes kernels ────────────────────────────────────────────────
//
// `Sky.Core.Bytes` models raw bytes as `String` (`type alias Bytes = String`).
// These kernels back the five `Ffi.kernel` aliases (`toHex`/`fromHex`/
// `toBase64`/`fromBase64`/`toString`) plus a `length` override. They reuse the
// Latin-1 `sky_bytes`/`bytes_to_sky` convention above so the byte pipeline is
// lossless and self-consistent with the rest of `encoding.rs` (a Rust `String`
// can't store arbitrary high bytes under UTF-8). Semantics mirror the Go runtime
// `Bytes_*` helpers in `runtime-go/rt/crypto_aead.go`.
//
// The fallible decoders return `SkyMaybe<String>` (Sky `Maybe Bytes` /
// `Maybe String`) — total matching only, never `unwrap`/`panic`. The unused
// generic `E` on the decoders mirrors the error-pin turbofish shape the codegen
// emits for sibling kernels (e.g. `encoding_hex_decode::<Error>`), so a call
// site that pins the error type still type-checks; `Maybe` carries no error so
// `E` is phantom.

/// Sky `Bytes.toHex : Bytes -> String` — lowercase hex of the Latin-1 bytes.
pub fn bytes_to_hex(b: String) -> String {
    hex::encode(sky_bytes(&b))
}

/// Sky `Bytes.toBase64 : Bytes -> String` — standard base64 of the Latin-1 bytes.
pub fn bytes_to_base64(b: String) -> String {
    B64.encode(sky_bytes(&b))
}

/// Sky `Bytes.fromHex : String -> Maybe Bytes` — Nothing on odd length or any
/// non-hex digit; otherwise Just the decoded bytes as a Latin-1 byte-string.
pub fn bytes_from_hex<E>(s: String) -> SkyMaybe<String> {
    if s.len() % 2 != 0 {
        return SkyMaybe::Nothing;
    }
    match hex::decode(&s) {
        Ok(bytes) => SkyMaybe::Just(bytes_to_sky(&bytes)),
        Err(_) => SkyMaybe::Nothing,
    }
}

/// Sky `Bytes.fromBase64 : String -> Maybe Bytes` — Nothing on any decode error;
/// otherwise Just the decoded bytes as a Latin-1 byte-string.
pub fn bytes_from_base64<E>(s: String) -> SkyMaybe<String> {
    match B64.decode(s.as_bytes()) {
        Ok(bytes) => SkyMaybe::Just(bytes_to_sky(&bytes)),
        Err(_) => SkyMaybe::Nothing,
    }
}

/// Sky `Bytes.toString : Bytes -> Maybe String` — Nothing when the Latin-1 bytes
/// are not valid UTF-8; otherwise Just the decoded text.
pub fn bytes_to_string(b: String) -> SkyMaybe<String> {
    match String::from_utf8(sky_bytes(&b)) {
        Ok(text) => SkyMaybe::Just(text),
        Err(_) => SkyMaybe::Nothing,
    }
}

/// Sky `Bytes.length : Bytes -> Int` — the Latin-1 BYTE count (one char per
/// byte), NOT `String::len()` (which counts UTF-8 storage bytes and so double-
/// counts every high byte ≥ 0x80). Overrides the `string_length` delegation.
pub fn bytes_length(b: String) -> i64 {
    b.chars().count() as i64
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

    // ── Sky.Core.Bytes kernels ────────────────────────────────────────────

    #[test]
    fn test_bytes_to_hex_ascii_exact() {
        // ASCII round-trip is byte-identical to Go (hex.EncodeToString).
        assert_eq!(bytes_to_hex("Hi!".to_string()), "486921");
    }

    #[test]
    fn test_bytes_to_base64_ascii_exact() {
        assert_eq!(bytes_to_base64("Hi!".to_string()), "SGkh");
    }

    #[test]
    fn test_bytes_from_hex_roundtrip_ascii() {
        let b = bytes_from_hex::<String>("486921".to_string());
        match b {
            SkyMaybe::Just(s) => assert_eq!(s, "Hi!"),
            SkyMaybe::Nothing => panic!("expected Just"),
        }
    }

    #[test]
    fn test_bytes_from_hex_odd_length_nothing() {
        let b = bytes_from_hex::<String>("abc".to_string());
        assert!(matches!(b, SkyMaybe::Nothing));
    }

    #[test]
    fn test_bytes_from_hex_non_hex_nothing() {
        let b = bytes_from_hex::<String>("zz".to_string());
        assert!(matches!(b, SkyMaybe::Nothing));
    }

    #[test]
    fn test_binary_payload_lossless_roundtrip() {
        // A binary buffer (0x9e 0xfe — both high bytes, not valid UTF-8 text)
        // built via fromHex must round-trip losslessly through toHex / toBase64.
        let buf = match bytes_from_hex::<String>("9efe".to_string()) {
            SkyMaybe::Just(s) => s,
            SkyMaybe::Nothing => panic!("expected Just for valid hex"),
        };
        // Latin-1: two chars, two bytes — toHex recovers the exact input.
        assert_eq!(bytes_to_hex(buf.clone()), "9efe");
        // base64 of the same two raw bytes; fromBase64 recovers losslessly.
        let b64 = bytes_to_base64(buf.clone());
        assert_eq!(b64, "nv4=");
        match bytes_from_base64::<String>(b64) {
            SkyMaybe::Just(s) => assert_eq!(bytes_to_hex(s), "9efe"),
            SkyMaybe::Nothing => panic!("expected Just"),
        }
    }

    #[test]
    fn test_bytes_from_base64_invalid_nothing() {
        let b = bytes_from_base64::<String>("not valid base64!@#".to_string());
        assert!(matches!(b, SkyMaybe::Nothing));
    }

    #[test]
    fn test_bytes_to_string_ascii_just() {
        match bytes_to_string("Hi!".to_string()) {
            SkyMaybe::Just(s) => assert_eq!(s, "Hi!"),
            SkyMaybe::Nothing => panic!("expected Just"),
        }
    }

    #[test]
    fn test_bytes_to_string_invalid_utf8_nothing() {
        // 0x9e alone is not a valid UTF-8 sequence -> Nothing.
        let buf = match bytes_from_hex::<String>("9e".to_string()) {
            SkyMaybe::Just(s) => s,
            SkyMaybe::Nothing => panic!("expected Just"),
        };
        assert!(matches!(bytes_to_string(buf), SkyMaybe::Nothing));
    }

    #[test]
    fn test_bytes_length_is_byte_count_not_str_len() {
        // A non-ASCII buffer: two high bytes (0xc3 0xa9 = UTF-8 'é').
        // Stored Latin-1 it is two chars; bytes_length must report 2 (byte
        // count), NOT the underlying `String::len()` which would be 4 (each
        // char ≥ 0x80 takes two UTF-8 storage bytes).
        let buf = match bytes_from_hex::<String>("c3a9".to_string()) {
            SkyMaybe::Just(s) => s,
            SkyMaybe::Nothing => panic!("expected Just"),
        };
        assert_eq!(buf.len(), 4); // underlying UTF-8 storage of Latin-1 chars
        assert_eq!(bytes_length(buf), 2); // true byte count
    }
}
