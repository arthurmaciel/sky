//! Sky.Core.WebSocket — outbound WebSocket client (tokio-tungstenite).
//!
//! Task-tier: connect/connectWith/send/sendBinary/close/closeWithCode via a
//! per-socket registry (a write-command mpsc + a frames broadcast). Receive:
//! `Sub_subscribeWebSocket` builds a SkySub::Source that drains the frames
//! broadcast and emits messages into the TEA loop — completing `onMessage`.
//!
//! WebSocketMessage/CloseCode are bridged to runtime enums so the runtime can
//! construct frames/codes for the user's toMsg. All four event kinds
//! (onOpen/onMessage/onClose/onError) are wired: the codegen's kind-literal
//! peephole routes each to its own typed kernel below, so the heterogeneous
//! toMsg shapes never share one bounded fn (no stdlib override needed).

use super::*;
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::sync::atomic::{AtomicI64, Ordering};
use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::tungstenite::Message;

/// Sky.Core.WebSocket.WebSocketMessage — bridged so the runtime can build frames.
/// Variant names match the Sky constructors (Text / Binary).
#[derive(Clone, Debug, PartialEq)]
pub enum WsClientMessage {
    Text(String),
    Binary(String),
}

/// Sky.Core.WebSocket.CloseCode — bridged so the runtime can build close codes
/// for onClose's toMsg. Variant names match the Sky constructors.
#[allow(non_snake_case)]
#[derive(Clone, Debug, PartialEq)]
pub enum WsCloseCode {
    Normal,
    GoingAway,
    UnsupportedData,
    InternalError,
    Custom(i64),
}

fn ws_close_code(code: i64) -> WsCloseCode {
    match code {
        1000 => WsCloseCode::Normal,
        1001 => WsCloseCode::GoingAway,
        1003 => WsCloseCode::UnsupportedData,
        1011 => WsCloseCode::InternalError,
        n => WsCloseCode::Custom(n),
    }
}

/// Internal per-socket event broadcast to onMessage/onClose/onError subs.
#[derive(Clone, Debug)]
enum WsEvent {
    Message(WsClientMessage),
    Closed(i64),
    Error(String),
}

/// Sky.Core.WebSocket.WebSocketCfg — built in Sky (defaultCfg + with*).
#[allow(non_snake_case)]
#[derive(Clone, Debug)]
pub struct WsClientCfg {
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub timeout: i64,
    pub pingInterval: i64,
}

enum WsCmd {
    Text(String),
    Binary(Vec<u8>),
    Close,
    CloseWithCode(u16, String),
}

struct ClientEntry {
    cmd_tx: tokio::sync::mpsc::UnboundedSender<WsCmd>,
    frames_tx: tokio::sync::broadcast::Sender<WsEvent>,
}

fn registry() -> &'static Mutex<HashMap<i64, ClientEntry>> {
    static R: OnceLock<Mutex<HashMap<i64, ClientEntry>>> = OnceLock::new();
    R.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Remove a socket from the registry and drop its subscribe-once markers so the
/// associated tasks wind down and the maps don't grow across reconnects.
fn deregister(id: i64) {
    registry().lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
    ws_subscribed().lock().unwrap_or_else(|e| e.into_inner()).retain(|&(sid, _)| sid != id);
}

static WS_CLIENT_NEXT_ID: AtomicI64 = AtomicI64::new(1);

async fn do_connect<E: From<String> + Send + 'static>(
    url: String,
    headers: Vec<(String, String)>,
    timeout_ms: i64,
    ping_interval_ms: i64,
) -> SkyResult<E, i64> {
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;
    use tokio_tungstenite::tungstenite::http::{HeaderName, HeaderValue};
    // Build the handshake request so custom headers (e.g. Authorization) from
    // connectWith's cfg.headers are sent.
    let mut req = match url.as_str().into_client_request() {
        Ok(r) => r,
        Err(e) => return SkyResult::Err(format!("WebSocket.connect {}: bad url: {}", url, e).into()),
    };
    for (k, v) in &headers {
        if let (Ok(name), Ok(val)) = (k.parse::<HeaderName>(), HeaderValue::from_str(v)) {
            req.headers_mut().insert(name, val);
        }
    }
    let connect_fut = tokio_tungstenite::connect_async(req);
    let (stream, _resp) = if timeout_ms > 0 {
        match tokio::time::timeout(std::time::Duration::from_millis(timeout_ms as u64), connect_fut).await {
            Ok(Ok(ok)) => ok,
            Ok(Err(e)) => return SkyResult::Err(format!("WebSocket.connect {}: {}", url, e).into()),
            Err(_) => return SkyResult::Err(format!("WebSocket.connect {}: handshake timed out after {}ms", url, timeout_ms).into()),
        }
    } else {
        match connect_fut.await {
            Ok(ok) => ok,
            Err(e) => return SkyResult::Err(format!("WebSocket.connect {}: {}", url, e).into()),
        }
    };
    let id = WS_CLIENT_NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let (mut write, mut read) = stream.split();
    let (cmd_tx, mut cmd_rx) = tokio::sync::mpsc::unbounded_channel::<WsCmd>();
    let (frames_tx, _) = tokio::sync::broadcast::channel::<WsEvent>(64);

    // Writer task: drain outbound commands → ws frames. When pingInterval > 0,
    // also send a periodic Ping so idle connections survive proxy/server idle
    // timeouts (tungstenite auto-pongs inbound pings on the read side).
    tokio::spawn(async move {
        // `interval` ticks immediately on the first poll; skip that first tick so
        // we ping after the interval, not at t=0.
        let mut ping_iv = if ping_interval_ms > 0 {
            let mut iv = tokio::time::interval(std::time::Duration::from_millis(ping_interval_ms as u64));
            iv.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            Some(iv)
        } else {
            None
        };
        let mut first_tick = true;
        loop {
            let cmd = match &mut ping_iv {
                Some(iv) => tokio::select! {
                    _ = iv.tick() => {
                        if first_tick { first_tick = false; continue; }
                        if write.send(Message::Ping(Vec::new())).await.is_err() { break; }
                        continue;
                    }
                    c = cmd_rx.recv() => c,
                },
                None => cmd_rx.recv().await,
            };
            let cmd = match cmd { Some(c) => c, None => break };
            let msg = match cmd {
                WsCmd::Text(s) => Message::Text(s),
                WsCmd::Binary(b) => Message::Binary(b),
                WsCmd::Close => {
                    let _ = write.send(Message::Close(None)).await;
                    break;
                }
                WsCmd::CloseWithCode(code, reason) => {
                    let frame = tokio_tungstenite::tungstenite::protocol::CloseFrame {
                        code: code.into(),
                        reason: reason.into(),
                    };
                    let _ = write.send(Message::Close(Some(frame))).await;
                    break;
                }
            };
            if write.send(msg).await.is_err() {
                break;
            }
        }
    });

    // Reader task: ws frames → frames broadcast (subscriptions drain it). On
    // close/error it deregisters the socket so the writer + subscription tasks
    // wind down (dropping the last frames_tx makes their recv() error) — no leak
    // on server-initiated close / reconnect.
    let frames = frames_tx.clone();
    tokio::spawn(async move {
        while let Some(item) = read.next().await {
            match item {
                Ok(Message::Text(t)) => { let _ = frames.send(WsEvent::Message(WsClientMessage::Text(t))); }
                Ok(Message::Binary(b)) => { let _ = frames.send(WsEvent::Message(WsClientMessage::Binary(bytes_to_sky(&b)))); }
                Ok(Message::Close(cf)) => {
                    let code = cf.map(|f| u16::from(f.code) as i64).unwrap_or(1000);
                    let _ = frames.send(WsEvent::Closed(code));
                    break;
                }
                Err(e) => { let _ = frames.send(WsEvent::Error(format!("ws read error: {}", e))); break; }
                _ => {} // Ping/Pong handled by tungstenite
            }
        }
        deregister(id);
    });

    registry().lock().unwrap_or_else(|e| e.into_inner()).insert(id, ClientEntry { cmd_tx, frames_tx });
    ok_res(id)
}

/// WebSocket.connect : String -> Task Error Int (raw id; Sky wraps in WebSocket)
pub fn web_socket_connect<E: From<String> + Send + 'static>(url: String) -> SkyTask<E, i64> {
    Box::pin(do_connect(url, Vec::new(), 30000, 0))
}

/// WebSocket.connectWith : WebSocketCfg -> Task Error Int. Applies the cfg's
/// custom headers, handshake timeout, and pingInterval (when > 0, the client
/// sends a periodic Ping frame to keep the connection alive through idle proxies;
/// tungstenite auto-pongs inbound pings on the read side).
pub fn web_socket_connect_with<E: From<String> + Send + 'static>(cfg: WsClientCfg) -> SkyTask<E, i64> {
    Box::pin(do_connect(cfg.url, cfg.headers, cfg.timeout, cfg.pingInterval))
}

fn send_cmd(id: i64, cmd: WsCmd) -> bool {
    match registry().lock().unwrap_or_else(|e| e.into_inner()).get(&id) {
        Some(e) => e.cmd_tx.send(cmd).is_ok(),
        None => false,
    }
}

/// WebSocket.send : Int -> String -> Task Error ()
pub fn web_socket_send<E: From<String> + Send + 'static>(id: i64, msg: String) -> SkyTask<E, ()> {
    Box::pin(async move {
        if send_cmd(id, WsCmd::Text(msg)) { ok_res(()) }
        else { SkyResult::Err(format!("WebSocket.send: no socket {}", id).into()) }
    })
}

/// WebSocket.sendBinary : Int -> String -> Task Error ()
pub fn web_socket_send_binary<E: From<String> + Send + 'static>(id: i64, msg: String) -> SkyTask<E, ()> {
    Box::pin(async move {
        if send_cmd(id, WsCmd::Binary(sky_bytes(&msg))) { ok_res(()) }
        else { SkyResult::Err(format!("WebSocket.sendBinary: no socket {}", id).into()) }
    })
}

/// WebSocket.close : Int -> Task Error () (idempotent)
pub fn web_socket_close<E: From<String> + Send + 'static>(id: i64) -> SkyTask<E, ()> {
    Box::pin(async move {
        let _ = send_cmd(id, WsCmd::Close);
        deregister(id);
        ok_res(())
    })
}

/// WebSocket.closeWithCode : Int -> String -> Int -> Task Error ()
pub fn web_socket_close_with_code<E: From<String> + Send + 'static>(code: i64, reason: String, id: i64) -> SkyTask<E, ()> {
    Box::pin(async move {
        let _ = send_cmd(id, WsCmd::CloseWithCode(code as u16, reason));
        deregister(id);
        ok_res(())
    })
}

// The four onX wrappers all call subscribeWebSocketRaw with a compile-time
// literal kind; the Builder peephole routes each to its own typed kernel below
// (so the heterogeneous toMsg shapes never share one bounded fn — no stdlib
// override needed). Each subscribes to the per-socket WsEvent broadcast and
// filters the events it cares about.

fn subscribe_events(socket_id: i64) -> Option<tokio::sync::broadcast::Receiver<WsEvent>> {
    registry().lock().unwrap_or_else(|e| e.into_inner()).get(&socket_id).map(|e| e.frames_tx.subscribe())
}

// WS subscriptions are set up ONCE per (socket, kind): the SubManager aborts +
// respawns every sub on each update, but a broadcast has no replay, so a
// re-spawned receiver would miss frames sent during the gap. So the real
// listener is spawned DETACHED (not the handle the SubManager tracks) the first
// time, and re-subscribes are no-ops — matching Go's "subsequent re-subscriptions
// are no-ops". The emit callback funnels into the loop channel, stable for the
// program's lifetime.
fn ws_subscribed() -> &'static Mutex<std::collections::HashSet<(i64, &'static str)>> {
    static S: OnceLock<Mutex<std::collections::HashSet<(i64, &'static str)>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(std::collections::HashSet::new()))
}
fn ws_mark_subscribed(socket_id: i64, kind: &'static str) -> bool {
    ws_subscribed().lock().unwrap_or_else(|e| e.into_inner()).insert((socket_id, kind))
}

/// onMessage : (WebSocketMessage -> msg) -> Sub msg
pub fn sub_subscribe_ws_message<M, F>(socket_id: i64, to_msg: F) -> SkySub<M>
where M: Send + 'static, F: Fn(WsClientMessage) -> M + Send + Sync + 'static {
    SkySub::Source(Box::new(move |emit| {
        if ws_mark_subscribed(socket_id, "message") {
            tokio::spawn(async move {
                let mut rx = match subscribe_events(socket_id) { Some(rx) => rx, None => return };
                loop {
                    match rx.recv().await {
                        Ok(WsEvent::Message(m)) => emit(to_msg(m)),
                        Ok(_) => {}
                        // A momentarily-slow consumer that lags past the buffer gets
                        // a Lagged error — skip the gap and keep the subscription
                        // alive (do NOT treat it as terminal). Closed channel ends it.
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                    }
                }
            });
        }
        tokio::spawn(async {}) // dummy handle for the SubManager to abort harmlessly
    }))
}

/// onOpen : msg -> Sub msg — dispatch `msg` once when connected.
pub fn sub_subscribe_ws_open<M>(socket_id: i64, msg: M) -> SkySub<M>
where M: Send + 'static {
    SkySub::Source(Box::new(move |emit| {
        if ws_mark_subscribed(socket_id, "open") && registry().lock().unwrap_or_else(|e| e.into_inner()).contains_key(&socket_id) {
            emit(msg);
        }
        tokio::spawn(async {})
    }))
}

/// onClose : (CloseCode -> msg) -> Sub msg
pub fn sub_subscribe_ws_close<M, F>(socket_id: i64, to_msg: F) -> SkySub<M>
where M: Send + 'static, F: Fn(WsCloseCode) -> M + Send + Sync + 'static {
    SkySub::Source(Box::new(move |emit| {
        if ws_mark_subscribed(socket_id, "close") {
            tokio::spawn(async move {
                let mut rx = match subscribe_events(socket_id) { Some(rx) => rx, None => return };
                loop {
                    match rx.recv().await {
                        Ok(WsEvent::Closed(code)) => { emit(to_msg(ws_close_code(code))); break; }
                        Ok(_) => {}
                        // Transient lag: skip the gap, keep waiting for the close event.
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                    }
                }
            });
        }
        tokio::spawn(async {})
    }))
}

/// onError : (Error -> msg) -> Sub msg. E is the project error (From<String>).
pub fn sub_subscribe_ws_error<E, M, F>(socket_id: i64, to_msg: F) -> SkySub<M>
where E: From<String> + Send + 'static, M: Send + 'static, F: Fn(E) -> M + Send + Sync + 'static {
    SkySub::Source(Box::new(move |emit| {
        if ws_mark_subscribed(socket_id, "error") {
            tokio::spawn(async move {
                let mut rx = match subscribe_events(socket_id) { Some(rx) => rx, None => return };
                loop {
                    match rx.recv().await {
                        Ok(WsEvent::Error(s)) => { emit(to_msg(s.into())); break; }
                        Ok(_) => {}
                        // Transient lag: skip the gap, keep waiting for the error event.
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                    }
                }
            });
        }
        tokio::spawn(async {})
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn close_code_mapping() {
        assert_eq!(ws_close_code(1000), WsCloseCode::Normal);
        assert_eq!(ws_close_code(1001), WsCloseCode::GoingAway);
        assert_eq!(ws_close_code(1003), WsCloseCode::UnsupportedData);
        assert_eq!(ws_close_code(1011), WsCloseCode::InternalError);
        assert_eq!(ws_close_code(4000), WsCloseCode::Custom(4000));
    }
}
