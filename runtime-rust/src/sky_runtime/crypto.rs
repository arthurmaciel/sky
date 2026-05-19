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
