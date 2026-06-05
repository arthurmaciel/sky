//! Sky.Core.Http.Stream — incremental HTTP response bodies (client side).
//!
//! Mirror of `runtime-go/rt/http_stream.go`. Reads an outbound HTTP response
//! body chunk-by-chunk via reqwest's `bytes_stream()` instead of buffering the
//! whole body (`Http.get`).
//!
//! Surface ported on the Rust backend:
//!
//!   * `open : HttpRequest -> Task Error StreamId`  — fire the request, resolve
//!     once the response headers arrive; register the byte stream under an id.
//!   * `forEachChunk : StreamId -> (String -> Task Error ()) -> Task Error ()`
//!     — synchronous drain (the relay shape — usable inside a plain
//!     Sky.Http.Server handler, no TEA loop required).
//!   * `close : StreamId -> Task Error ()` — drop the stream / release the conn.
//!
//! The Sub-tier `chunks` (dispatching ChunkEvent Msgs into a TEA update loop)
//! is intentionally NOT ported here — its only consumer is Sky.Live, which is a
//! deferred arc on the Rust backend. `open`/`forEachChunk`/`close` cover the
//! self-contained relay use case end-to-end.
//!
//! `StreamId` stays a generated Sky enum (`StreamId Int`); these kernels only
//! ever deal with the raw `i64` (the stdlib wraps/unwraps at the boundary).

use super::*;
use futures_util::StreamExt;
use std::collections::HashMap;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Mutex, OnceLock};

// The open response is parked here between `open` and `forEachChunk`/`close`.
// Storing the `reqwest::Response` (rather than its byte stream) avoids naming
// `bytes::Bytes` — `forEachChunk` calls `.bytes_stream()` and the chunk type is
// inferred, so no extra `bytes` dependency is needed.
fn client_streams() -> &'static Mutex<HashMap<i64, reqwest::Response>> {
    static R: OnceLock<Mutex<HashMap<i64, reqwest::Response>>> = OnceLock::new();
    R.get_or_init(|| Mutex::new(HashMap::new()))
}

// Monotonic, never-zero stream ids — a zero-valued StreamId (uninitialised
// model field) must never resolve to a real stream.
static NEXT_ID: AtomicI64 = AtomicI64::new(1);
fn next_stream_id() -> i64 {
    loop {
        let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
        if id != 0 {
            return id;
        }
    }
}

/// Sky.Core.Http.Stream.open : HttpRequest -> Task Error Int
/// (the Sky wrapper re-wraps the Int in `StreamId`.)
///
/// No whole-request timeout — streams may run for minutes (LLM completions);
/// a 30s connect timeout bounds the header stage only.
pub fn http_stream_open<E: From<String> + Send + 'static>(req: HttpRequest) -> SkyTask<E, i64> {
    Box::pin(async move {
        let client = match reqwest::Client::builder()
            .connect_timeout(std::time::Duration::from_secs(30))
            .redirect(if req.followRedirects {
                reqwest::redirect::Policy::limited(req.maxRedirects.max(0) as usize)
            } else {
                reqwest::redirect::Policy::none()
            })
            .build()
        {
            Ok(c) => c,
            Err(e) => return SkyResult::Err(format!("http.stream.open: client: {}", e).into()),
        };
        let method = reqwest::Method::from_bytes(req.method.to_uppercase().as_bytes())
            .unwrap_or(reqwest::Method::GET);
        let mut rb = client.request(method, &req.url);
        for (k, v) in &req.headers {
            rb = rb.header(k.as_str(), v.as_str());
        }
        if !req.body.is_empty() {
            rb = rb.body(req.body.clone());
        }
        let resp = match rb.send().await {
            Ok(r) => r,
            Err(e) => {
                return SkyResult::Err(
                    format!("http.stream.open: request to {} failed: {}", req.url, e).into(),
                )
            }
        };
        // HTTP error statuses (4xx/5xx) still surface as a stream — the body may
        // carry the error payload the caller wants to read. Mirrors Http.get
        // returning Ok with a 4xx status.
        let id = next_stream_id();
        client_streams().lock().unwrap().insert(id, resp);
        SkyResult::Ok(id)
    })
}

/// Sky.Core.Http.Stream.forEachChunk : Int -> (String -> Task Error ()) -> Task Error ()
///
/// Drains the stream synchronously from the calling task, invoking `body chunk`
/// per chunk. Bridges the client consumer to a server producer
/// (`Server.Stream.emit`) inside one Sky.Http.Server handler — the relay shape.
///
/// Semantics (parity with the Go runtime):
///   * clean EOF              → Ok ()
///   * upstream read error     → Err e
///   * `body chunk` returns Err → abort, close, Err e (fail-fast)
///   * the handle is always removed (connection released) on exit.
///
/// Backpressure: `body` runs synchronously per chunk; if it blocks on a slow
/// downstream (`Server.Stream.emit` to a bounded channel) the upstream read
/// naturally throttles.
pub fn http_stream_for_each_chunk<E, F>(id: i64, body: F) -> SkyTask<E, ()>
where
    E: From<String> + Send + 'static,
    F: Fn(String) -> SkyTask<E, ()> + Send + 'static,
{
    Box::pin(async move {
        // Take ownership of the response — forEachChunk consumes it. An unknown /
        // already-drained id is a no-op (matches close's idempotent contract).
        let resp = match client_streams().lock().unwrap().remove(&id) {
            Some(r) => r,
            None => return SkyResult::Ok(()),
        };
        let mut stream = resp.bytes_stream();
        loop {
            match stream.next().await {
                Some(Ok(bytes)) => {
                    let chunk = String::from_utf8_lossy(&bytes).into_owned();
                    match body(chunk).await {
                        SkyResult::Ok(()) => {}
                        SkyResult::Err(e) => break SkyResult::Err(e),
                    }
                }
                Some(Err(e)) => break SkyResult::Err(format!("http.stream read: {}", e).into()),
                None => break SkyResult::Ok(()),
            }
        }
        // `stream` (and the response) drops here → connection released.
    })
}

/// Sky.Core.Http.Stream.close : Int -> Task Error ()
/// Idempotent — closing an unknown / already-closed id is a no-op.
pub fn http_stream_close<E: From<String> + Send + 'static>(id: i64) -> SkyTask<E, ()> {
    Box::pin(async move {
        client_streams().lock().unwrap().remove(&id);
        SkyResult::Ok(())
    })
}
