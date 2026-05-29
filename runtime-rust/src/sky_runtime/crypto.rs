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
}
