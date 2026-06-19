//! Sky.Http.Server.Stream — server-side streaming HTTP responses (chunked / SSE).
//!
//! Mirror of `runtime-go/rt/server_stream.go`. Where http_stream.rs reads an
//! upstream body chunk-by-chunk, this writes a response body chunk-by-chunk to
//! the client over a long-lived connection.
//!
//! Integration with the axum server (server.rs):
//!
//!   1. `stream ct handler` stashes the (E-erased) handler closure in a global
//!      registry under a fresh token and returns a normal `ServerResponse`
//!      whose body is the sentinel `__sky_stream:<token>`. This survives the
//!      ServerResponse bridge (which has no handler field).
//!
//!   2. `to_axum_response` (server.rs) calls `serve_streaming_sentinel`. On a
//!      sentinel hit it: pops the handler, opens a bounded mpsc channel,
//!      registers the sender under a stream id, spawns the handler driving a
//!      `StreamWriter(id)`, and returns an axum response whose body streams the
//!      channel (`Body::from_stream`). Headers + status are committed when this
//!      response is returned — before the first chunk — exactly as SSE requires.
//!
//!   3. `emit chunk writer` resolves the id → sender and `send(chunk).await`s
//!      (bounded → backpressure). `finish writer` drops the sender (ends the
//!      stream). `withContentType` is a no-op once the head is committed (which
//!      it always is by the time the handler runs — set the type via `stream`).
//!
//! `StreamWriter` is bridged (runtimeOpaqueTypes) so the runtime can construct
//! it and the stdlib's `case writer of StreamWriter raw` lowers onto it.

use super::*;
use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

/// Sky.Http.Server.Stream.StreamWriter — opaque writer handle. The variant name
/// matches the Sky constructor so `case w of StreamWriter raw` lowers onto it.
#[derive(Clone, Copy, Debug)]
pub enum StreamWriter {
    StreamWriter(i64),
}

/// Handler with its Sky error type E erased: the effect IS the emits, the
/// SkyResult is discarded (parity with the Go dispatcher's `_ = task.await`).
type ErasedStreamHandler =
    Arc<dyn Fn(StreamWriter) -> Pin<Box<dyn Future<Output = ()> + Send>> + Send + Sync>;

fn pending_handlers() -> &'static Mutex<HashMap<i64, ErasedStreamHandler>> {
    static R: OnceLock<Mutex<HashMap<i64, ErasedStreamHandler>>> = OnceLock::new();
    R.get_or_init(|| Mutex::new(HashMap::new()))
}

fn stream_senders() -> &'static Mutex<HashMap<i64, tokio::sync::mpsc::Sender<String>>> {
    static R: OnceLock<Mutex<HashMap<i64, tokio::sync::mpsc::Sender<String>>>> = OnceLock::new();
    R.get_or_init(|| Mutex::new(HashMap::new()))
}

static NEXT_TOKEN: AtomicI64 = AtomicI64::new(1);
static NEXT_STREAM_ID: AtomicI64 = AtomicI64::new(1);

const SENTINEL_PREFIX: &str = "__sky_stream:";

/// Per-process random nonce woven into the streaming sentinel. The sentinel is
/// matched on the BODY of any response, so without an unguessable component an
/// app (or a relayed upstream) whose body begins `__sky_stream:<digits>` could be
/// misread as a streaming sentinel and divert control flow. The nonce is drawn
/// once from the OS CSPRNG (uuid v4 → getrandom) so body-controlled content can
/// neither forge nor collide with a real sentinel. Sentinel shape:
/// `__sky_stream:<nonce>:<token>`.
fn sentinel_nonce() -> &'static str {
    static N: OnceLock<String> = OnceLock::new();
    N.get_or_init(|| uuid::Uuid::new_v4().simple().to_string())
}
// Bounded channel — matches the Go runtime's streamChanBuffer (16). emit's
// `send().await` blocks when full → backpressure to the producer/relay.
const STREAM_CHAN_BUFFER: usize = 16;

/// Sky.Http.Server.Stream.stream
///   : String -> (StreamWriter -> Task Error ()) -> Task Error Response
pub fn server_stream_stream<E, H>(content_type: String, handler: H) -> SkyTask<E, ServerResponse>
where
    E: Send + 'static,
    H: Fn(StreamWriter) -> SkyTask<E, ()> + Send + Sync + 'static,
{
    // Erase E: the registry can't name the project's error type. The handler's
    // returned task is driven to completion; its result is dropped.
    let erased: ErasedStreamHandler = Arc::new(move |w: StreamWriter| {
        let task = handler(w);
        Box::pin(async move {
            let _ = task.await;
        }) as Pin<Box<dyn Future<Output = ()> + Send>>
    });
    let ct = if content_type.is_empty() {
        "application/octet-stream".to_string()
    } else {
        content_type
    };
    let token = NEXT_TOKEN.fetch_add(1, Ordering::Relaxed);
    pending_handlers().lock().unwrap_or_else(|e| e.into_inner()).insert(token, erased);
    Box::pin(async move {
        SkyResult::Ok(ServerResponse {
            status: 200,
            body: format!("{}{}:{}", SENTINEL_PREFIX, sentinel_nonce(), token),
            headers: HashMap::new(),
            contentType: ct,
        })
    })
}

/// Sky.Http.Server.Stream.emit : String -> Int -> Task Error ()
/// (the stdlib unwraps StreamWriter → Int.) Sends the chunk + flushes
/// (the channel feeds an unbuffered axum body). emit-after-finish is a no-op.
pub fn server_stream_emit<E: From<String> + Send + 'static>(
    chunk: String,
    id: i64,
) -> SkyTask<E, ()> {
    Box::pin(async move {
        let sender = stream_senders().lock().unwrap_or_else(|e| e.into_inner()).get(&id).cloned();
        match sender {
            Some(tx) => match tx.send(chunk).await {
                Ok(()) => SkyResult::Ok(()),
                // Receiver dropped — client disconnected. Surface as an error so
                // a relay's forEachChunk fail-fast stops pulling the upstream.
                Err(_) => SkyResult::Err("server.stream emit: client disconnected".to_string().into()),
            },
            None => SkyResult::Ok(()),
        }
    })
}

/// Sky.Http.Server.Stream.finish : Int -> Task Error ()
/// Idempotent — drops the sender (ends the body stream). Implicit at handler
/// return; explicit when the handler wants to release the connection early.
pub fn server_stream_finish<E: From<String> + Send + 'static>(id: i64) -> SkyTask<E, ()> {
    Box::pin(async move {
        stream_senders().lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
        SkyResult::Ok(())
    })
}

/// Sky.Http.Server.Stream.withContentType : String -> Int -> Task Error ()
/// Best-effort: the head is already committed by the time the handler runs in
/// this model (axum sends headers when the streaming Response is returned), so
/// this is a no-op. Set the Content-Type via the `stream` argument instead.
pub fn server_stream_with_content_type<E: From<String> + Send + 'static>(
    _ct: String,
    _id: i64,
) -> SkyTask<E, ()> {
    Box::pin(async move { SkyResult::Ok(()) })
}

/// Called from server.rs `to_axum_response`. If `r.body` carries the streaming
/// sentinel, set up the channel + spawn the handler and return the streaming
/// axum response; otherwise None (the caller falls back to the buffered path).
pub fn serve_streaming_sentinel(r: &ServerResponse) -> Option<axum::response::Response> {
    // Sentinel shape: `__sky_stream:<nonce>:<token>`. The per-process nonce must
    // match exactly, so application/relayed body content can neither forge nor
    // collide with a real pending stream. A non-match falls through to buffered.
    let rest = r.body.strip_prefix(SENTINEL_PREFIX)?;
    let token_str = rest.strip_prefix(sentinel_nonce())?.strip_prefix(':')?;
    let token: i64 = token_str.parse().ok()?;
    let handler = pending_handlers().lock().unwrap_or_else(|e| e.into_inner()).remove(&token)?;

    let (tx, rx) = tokio::sync::mpsc::channel::<String>(STREAM_CHAN_BUFFER);
    let id = loop {
        let n = NEXT_STREAM_ID.fetch_add(1, Ordering::Relaxed);
        if n != 0 {
            break n;
        }
    };
    stream_senders().lock().unwrap_or_else(|e| e.into_inner()).insert(id, tx);

    // Drive the handler in its own task; on completion drop the sender so the
    // body stream terminates even if the handler forgot to call `finish`.
    tokio::spawn(async move {
        handler(StreamWriter::StreamWriter(id)).await;
        stream_senders().lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
    });

    // Receiver → byte stream. unfold yields each chunk; None ends the body when
    // every sender has dropped (finish / handler exit).
    let body_stream = futures_util::stream::unfold(rx, |mut rx| async move {
        rx.recv()
            .await
            .map(|chunk| (Ok::<String, std::io::Error>(chunk), rx))
    });

    let status = axum::http::StatusCode::from_u16(r.status as u16)
        .unwrap_or(axum::http::StatusCode::OK);
    let mut builder = axum::http::Response::builder().status(status);
    if !r.contentType.is_empty() {
        builder = builder.header("content-type", r.contentType.clone());
    }
    // Disable proxy buffering for SSE — same hint the Sky.Live SSE path sends.
    builder = builder.header("x-accel-buffering", "no");
    builder = builder.header("cache-control", "no-cache");
    for (k, v) in &r.headers {
        builder = builder.header(k.as_str(), v.as_str());
    }
    builder.body(axum::body::Body::from_stream(body_stream)).ok()
}
