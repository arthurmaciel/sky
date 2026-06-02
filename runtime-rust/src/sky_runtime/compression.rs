//! Std.Compression — gzip (flate2) + zstd over the Sky bytes convention.
//!
//! All entries are `String -> Task Error String`. Input/output are Sky
//! "bytes" — `String`s under the Latin-1 byte convention (one char per byte,
//! see encoding.rs) — so compressed payloads (binary, non-UTF-8) round-trip
//! through `String` losslessly. Compression is sync CPU work wrapped in a
//! ready Future to satisfy the `Task` shape.

use super::*;
use super::encoding::{sky_bytes, bytes_to_sky};
use std::future::ready;
use std::io::{Read, Write};

fn gzip_bytes(data: &[u8]) -> Vec<u8> {
    use flate2::{write::GzEncoder, Compression};
    let mut e = GzEncoder::new(Vec::new(), Compression::default());
    let _ = e.write_all(data);
    e.finish().unwrap_or_default()
}

fn gunzip_bytes(data: &[u8]) -> Result<Vec<u8>, String> {
    use flate2::read::GzDecoder;
    let mut d = GzDecoder::new(data);
    let mut out = Vec::new();
    d.read_to_end(&mut out).map_err(|e| e.to_string())?;
    Ok(out)
}

/// Compression.gzip : String -> Task Error String
pub fn compression_gzip<E: Send + 'static>(s: String) -> SkyTask<E, String> {
    let out = bytes_to_sky(&gzip_bytes(&sky_bytes(&s)));
    Box::pin(ready(ok_res(out)))
}

/// Compression.gunzip : String -> Task Error String
pub fn compression_gunzip<E: From<String> + Send + 'static>(s: String) -> SkyTask<E, String> {
    let r = match gunzip_bytes(&sky_bytes(&s)) {
        Ok(b) => ok_res(bytes_to_sky(&b)),
        Err(e) => SkyResult::Err(format!("Compression.gunzip: {}", e).into()),
    };
    Box::pin(ready(r))
}

/// Compression.zstdCompress : String -> Task Error String
pub fn compression_zstd_compress<E: Send + 'static>(s: String) -> SkyTask<E, String> {
    let out = zstd::encode_all(&sky_bytes(&s)[..], 0).unwrap_or_default();
    Box::pin(ready(ok_res(bytes_to_sky(&out))))
}

/// Compression.zstdDecompress : String -> Task Error String
pub fn compression_zstd_decompress<E: From<String> + Send + 'static>(s: String) -> SkyTask<E, String> {
    let r = match zstd::decode_all(&sky_bytes(&s)[..]) {
        Ok(b) => ok_res(bytes_to_sky(&b)),
        Err(e) => SkyResult::Err(format!("Compression.zstdDecompress: {}", e).into()),
    };
    Box::pin(ready(r))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sky_runtime::task::task_run;

    #[test]
    fn gzip_roundtrip() {
        let orig = "hello, sky - gzip round-trip with some length to compress".to_string();
        let z: SkyResult<String, String> = task_run(compression_gzip(orig.clone()));
        let comp = match z { SkyResult::Ok(c) => c, _ => panic!("gzip failed") };
        let back: SkyResult<String, String> = task_run(compression_gunzip(comp));
        assert!(matches!(back, SkyResult::Ok(ref s) if *s == orig));
    }

    #[test]
    fn zstd_roundtrip() {
        let orig = "zstd payload zstd payload zstd payload".to_string();
        let z: SkyResult<String, String> = task_run(compression_zstd_compress(orig.clone()));
        let comp = match z { SkyResult::Ok(c) => c, _ => panic!("zstd failed") };
        let back: SkyResult<String, String> = task_run(compression_zstd_decompress(comp));
        assert!(matches!(back, SkyResult::Ok(ref s) if *s == orig));
    }

    #[test]
    fn gunzip_rejects_garbage() {
        let bad: SkyResult<String, String> = task_run(compression_gunzip("not a gzip stream".to_string()));
        assert!(matches!(bad, SkyResult::Err(_)));
    }
}
