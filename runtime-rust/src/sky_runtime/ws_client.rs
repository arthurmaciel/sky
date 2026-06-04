//! Sky.Core.WebSocket — outbound WebSocket client (tokio-tungstenite).
//!
//! Task-tier: connect/connectWith/send/sendBinary/close/closeWithCode via a
//! per-socket registry (a write-command mpsc + a frames broadcast). Receive:
//! `Sub_subscribeWebSocket` builds a SkySub::Source that drains the frames
//! broadcast and emits messages into the TEA loop — completing `onMessage`.
//!
//! WebSocketMessage is bridged to WsClientMessage so the runtime can construct
//! frames to hand to the user's toMsg. onOpen/onClose/onError (heterogeneous
//! bare/typed toMsg through the single `any` subscribeWebSocketRaw) need a
//! rust-target stdlib override to split into typed kernels — a follow-up; only
//! kind = "message" is wired here.

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

static WS_CLIENT_NEXT_ID: AtomicI64 = AtomicI64::new(1);

async fn do_connect<E: From<String> + Send + 'static>(url: String) -> SkyResult<E, i64> {
    let (stream, _resp) = match tokio_tungstenite::connect_async(&url).await {
        Ok(ok) => ok,
        Err(e) => return SkyResult::Err(format!("WebSocket.connect {}: {}", url, e).into()),
    };
    let id = WS_CLIENT_NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let (mut write, mut read) = stream.split();
    let (cmd_tx, mut cmd_rx) = tokio::sync::mpsc::unbounded_channel::<WsCmd>();
    let (frames_tx, _) = tokio::sync::broadcast::channel::<WsEvent>(64);

    // Writer task: drain outbound commands → ws frames.
    tokio::spawn(async move {
        while let Some(cmd) = cmd_rx.recv().await {
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

    // Reader task: ws frames → frames broadcast (subscriptions drain it).
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
    });

    registry().lock().unwrap().insert(id, ClientEntry { cmd_tx, frames_tx });
    ok_res(id)
}

/// WebSocket.connect : String -> Task Error Int (raw id; Sky wraps in WebSocket)
pub fn web_socket_connect<E: From<String> + Send + 'static>(url: String) -> SkyTask<E, i64> {
    Box::pin(do_connect(url))
}

/// WebSocket.connectWith : WebSocketCfg -> Task Error Int
pub fn web_socket_connect_with<E: From<String> + Send + 'static>(cfg: WsClientCfg) -> SkyTask<E, i64> {
    Box::pin(do_connect(cfg.url))
}

fn send_cmd(id: i64, cmd: WsCmd) -> bool {
    match registry().lock().unwrap().get(&id) {
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
        registry().lock().unwrap().remove(&id);
        ok_res(())
    })
}

/// WebSocket.closeWithCode : Int -> String -> Int -> Task Error ()
pub fn web_socket_close_with_code<E: From<String> + Send + 'static>(code: i64, reason: String, id: i64) -> SkyTask<E, ()> {
    Box::pin(async move {
        let _ = send_cmd(id, WsCmd::CloseWithCode(code as u16, reason));
        registry().lock().unwrap().remove(&id);
        ok_res(())
    })
}

// The four onX wrappers all call subscribeWebSocketRaw with a compile-time
// literal kind; the Builder peephole routes each to its own typed kernel below
// (so the heterogeneous toMsg shapes never share one bounded fn — no stdlib
// override needed). Each subscribes to the per-socket WsEvent broadcast and
// filters the events it cares about.

fn subscribe_events(socket_id: i64) -> Option<tokio::sync::broadcast::Receiver<WsEvent>> {
    registry().lock().unwrap().get(&socket_id).map(|e| e.frames_tx.subscribe())
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
    ws_subscribed().lock().unwrap().insert((socket_id, kind))
}

/// onMessage : (WebSocketMessage -> msg) -> Sub msg
pub fn sub_subscribe_ws_message<M, F>(socket_id: i64, to_msg: F) -> SkySub<M>
where M: Send + 'static, F: Fn(WsClientMessage) -> M + Send + Sync + 'static {
    SkySub::Source(Box::new(move |emit| {
        if ws_mark_subscribed(socket_id, "message") {
            tokio::spawn(async move {
                let mut rx = match subscribe_events(socket_id) { Some(rx) => rx, None => return };
                while let Ok(ev) = rx.recv().await {
                    if let WsEvent::Message(m) = ev { emit(to_msg(m)); }
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
        if ws_mark_subscribed(socket_id, "open") && registry().lock().unwrap().contains_key(&socket_id) {
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
                while let Ok(ev) = rx.recv().await {
                    if let WsEvent::Closed(code) = ev { emit(to_msg(ws_close_code(code))); break; }
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
                while let Ok(ev) = rx.recv().await {
                    if let WsEvent::Error(s) = ev { emit(to_msg(s.into())); break; }
                }
            });
        }
        tokio::spawn(async {})
    }))
}
