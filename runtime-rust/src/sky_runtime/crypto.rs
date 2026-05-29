// Crypto kernel stubs — generic over E where needed.
use super::*;
use std::future::ready;

pub fn crypto_random_bytes<E: Send + 'static>(n: i64) -> SkyTask<E, Vec<i64>> {
    super::random::lcg_init();
    let mut out = Vec::with_capacity(n as usize);
    for _ in 0..n { out.push(super::random::lcg_next() as i64); }
    Box::pin(ready(ok_res(out)))
}

pub fn crypto_random_token<E: Send + 'static>(n: i64) -> SkyTask<E, String> {
    super::random::lcg_init();
    let hex = "0123456789abcdef";
    let mut out = String::with_capacity((n * 2) as usize);
    for _ in 0..n {
        let b = super::random::lcg_next();
        out.push(hex.as_bytes()[(b & 0x0f) as usize] as char);
        out.push(hex.as_bytes()[((b >> 4) & 0x0f) as usize] as char);
    }
    Box::pin(ready(ok_res(out)))
}

pub fn crypto_sha256(s: String) -> String {
    use sha2::{Sha256, Digest};
    let mut h = Sha256::new();
    h.update(s.as_bytes());
    let result = h.finalize();
    result.iter().map(|b| format!("{:02x}", b)).collect::<Vec<_>>().join("")
}

/// Sky `sha512 : String -> String` — hex-encoded SHA-512 digest.
pub fn crypto_sha512(s: String) -> String {
    use sha2::{Sha512, Digest};
    let mut h = Sha512::new();
    h.update(s.as_bytes());
    let result = h.finalize();
    result.iter().map(|b| format!("{:02x}", b)).collect()
}

/// Sky `sha1 : String -> String` — hex-encoded SHA-1 digest.
pub fn crypto_sha1(s: String) -> String {
    use sha1::{Sha1, Digest};
    let mut h = Sha1::new();
    h.update(s.as_bytes());
    h.finalize().iter().map(|b| format!("{:02x}", b)).collect()
}

/// Sky `md5 : String -> String` — hex-encoded MD5 digest.
pub fn crypto_md5(s: String) -> String {
    use md5::{Md5, Digest};
    let mut h = Md5::new();
    h.update(s.as_bytes());
    h.finalize().iter().map(|b| format!("{:02x}", b)).collect()
}

/// Sky `hmacSha256 : String -> String -> String` (key, message → hex tag).
pub fn crypto_hmac_sha256(key: String, msg: String) -> String {
    use hmac::{Hmac, Mac};
    use sha2::Sha256;
    type HmacSha256 = Hmac<Sha256>;
    let mut mac = HmacSha256::new_from_slice(key.as_bytes())
        .expect("Hmac<Sha256> accepts any key length");
    mac.update(msg.as_bytes());
    mac.finalize().into_bytes().iter().map(|b| format!("{:02x}", b)).collect()
}

/// Sky `hmacSha512 : String -> String -> String`.
pub fn crypto_hmac_sha512(key: String, msg: String) -> String {
    use hmac::{Hmac, Mac};
    use sha2::Sha512;
    type HmacSha512 = Hmac<Sha512>;
    let mut mac = HmacSha512::new_from_slice(key.as_bytes())
        .expect("Hmac<Sha512> accepts any key length");
    mac.update(msg.as_bytes());
    mac.finalize().into_bytes().iter().map(|b| format!("{:02x}", b)).collect()
}

/// Sky `rsaSha256Sign : String -> String -> Result Error String`
/// Sign `msg` with the PKCS#1 v1.5 SHA-256 RSA scheme using `key_pem`
/// (RSA PRIVATE KEY block). Returns hex-encoded signature on success.
#[cfg(feature = "crypto")]
pub fn crypto_rsa_sha256_sign<E: From<String>>(key_pem: String, msg: String) -> SkyResult<E, String> {
    use rsa::{pkcs1::DecodeRsaPrivateKey, pkcs1v15::SigningKey, signature::{Signer, SignatureEncoding}};
    use sha2::Sha256;

    let priv_key = match rsa::RsaPrivateKey::from_pkcs1_pem(&key_pem) {
        Ok(k) => k,
        Err(e) => return SkyResult::Err(format!("rsaSign: parse: {}", e).into()),
    };
    let signing_key = SigningKey::<Sha256>::new(priv_key);
    let signature = signing_key.sign(msg.as_bytes());
    let hex_sig: String = signature.to_bytes().iter().map(|b| format!("{:02x}", b)).collect();
    SkyResult::Ok(hex_sig)
}

/// Sky `rsaSha256Verify : String -> String -> String -> Bool`
/// (key_pem, msg, hex_signature). Returns `false` on any failure — never panics.
#[cfg(feature = "crypto")]
pub fn crypto_rsa_sha256_verify(key_pem: String, msg: String, sig_hex: String) -> bool {
    use rsa::{pkcs1::DecodeRsaPrivateKey, pkcs1v15::{Signature, VerifyingKey}, signature::Verifier};
    use sha2::Sha256;

    let priv_key = match rsa::RsaPrivateKey::from_pkcs1_pem(&key_pem) {
        Ok(k) => k,
        Err(_) => return false,
    };
    let verifying_key: VerifyingKey<Sha256> = VerifyingKey::<Sha256>::new(priv_key.to_public_key());
    let sig_bytes = match hex::decode(&sig_hex) {
        Ok(b) => b,
        Err(_) => return false,
    };
    let signature = match Signature::try_from(sig_bytes.as_slice()) {
        Ok(s) => s,
        Err(_) => return false,
    };
    verifying_key.verify(msg.as_bytes(), &signature).is_ok()
}

/// Sky `constantTimeEqual : String -> String -> Bool` — timing-safe byte compare.
pub fn crypto_constant_time_equal(a: String, b: String) -> bool {
    use subtle::ConstantTimeEq;
    let ab = a.as_bytes();
    let bb = b.as_bytes();
    if ab.len() != bb.len() {
        return false;
    }
    bool::from(ab.ct_eq(bb))
}

#[cfg(test)]
mod tests_more_hashes {
    use super::*;

    const EMPTY_SHA256: &str = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    const EMPTY_SHA512: &str = "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e";
    const EMPTY_SHA1:   &str = "da39a3ee5e6b4b0d3255bfef95601890afd80709";
    const EMPTY_MD5:    &str = "d41d8cd98f00b204e9800998ecf8427e";
    const ABC_SHA256:   &str = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    #[test]
    fn test_sha256_empty_and_abc() {
        assert_eq!(crypto_sha256(String::new()), EMPTY_SHA256);
        assert_eq!(crypto_sha256("abc".to_string()), ABC_SHA256);
    }

    #[test]
    fn test_sha512_empty() {
        assert_eq!(crypto_sha512(String::new()), EMPTY_SHA512);
    }

    #[test]
    fn test_sha1_empty() {
        assert_eq!(crypto_sha1(String::new()), EMPTY_SHA1);
    }

    #[test]
    fn test_md5_empty() {
        assert_eq!(crypto_md5(String::new()), EMPTY_MD5);
    }

    // RFC 4231 test case 1: key = 0x0b*20, data = "Hi There"
    const HMAC_SHA256_RFC1: &str = "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7";
    const HMAC_SHA512_RFC1: &str = "87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cdedaa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854";

    #[test]
    fn test_hmac_sha256_rfc4231() {
        let key: String = (0..20).map(|_| '\u{000b}').collect();
        assert_eq!(crypto_hmac_sha256(key.clone(), "Hi There".to_string()), HMAC_SHA256_RFC1);
        assert_eq!(crypto_hmac_sha512(key, "Hi There".to_string()), HMAC_SHA512_RFC1);
    }

    const RSA_PRIV_PEM: &str = "-----BEGIN RSA PRIVATE KEY-----
MIIBOgIBAAJBAK1QGnsdSyVv+JT4WDnGIIr3QA75yZTiTsgxkiXH9sjXrPHT1hXn
2tKCv9MkR8MD1Ndh6jo7inBZUK0YG7H6Jx0CAwEAAQJAX9bpHeXAFW7K5w5CM4il
nFNIAEAPQh63dCs9Z1kh1kPNGKQYujFQ9KgNuw1keQDKhkzd5jCauNJ6Db/xDpdL
PQIhANidlZLm430yH5JrNG9hZpFIM80tUn+cf7J5F4KLIF2zAiEAzNL87wCFzVrt
xE9IhVClKFPemDjO9Mre3Db/V53uH+8CIQC2/BfYatcNcYQeKhW3aS492CJ6Vqj0
R/3PhF+J1YFX5QIgG9S7a5pNlAa78gW32+2GU4F56IMnk9mRCKksbvJVrd8CIFuA
y7anow7/QOtvB1/UdyrxegB+sHZoBWA9+SsMl2zn
-----END RSA PRIVATE KEY-----";

    #[test]
    fn test_rsa_sign_verify_roundtrip() {
        let msg = "hello, sky".to_string();
        let sig: SkyResult<String, String> = crypto_rsa_sha256_sign(
            RSA_PRIV_PEM.to_string(), msg.clone());
        let sig_hex = match sig {
            SkyResult::Ok(s) => s,
            SkyResult::Err(e) => panic!("sign failed: {}", e),
        };
        assert!(crypto_rsa_sha256_verify(
            RSA_PRIV_PEM.to_string(), msg, sig_hex));
    }

    #[test]
    fn test_rsa_verify_wrong_sig() {
        assert!(!crypto_rsa_sha256_verify(
            RSA_PRIV_PEM.to_string(),
            "hello".to_string(),
            "deadbeef".to_string()));
    }

    #[test]
    fn test_constant_time_equal() {
        assert!(crypto_constant_time_equal("abc".to_string(), "abc".to_string()));
        assert!(!crypto_constant_time_equal("abc".to_string(), "abd".to_string()));
        assert!(!crypto_constant_time_equal("abc".to_string(), "ab".to_string()));
    }
}
