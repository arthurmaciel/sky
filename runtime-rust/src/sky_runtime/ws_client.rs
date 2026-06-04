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
    frames_tx: tokio::sync::broadcast::Sender<WsClientMessage>,
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
    let (frames_tx, _) = tokio::sync::broadcast::channel::<WsClientMessage>(64);

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
                Ok(Message::Text(t)) => { let _ = frames.send(WsClientMessage::Text(t)); }
                Ok(Message::Binary(b)) => { let _ = frames.send(WsClientMessage::Binary(bytes_to_sky(&b))); }
                Ok(Message::Close(_)) | Err(_) => break,
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

/// onMessage's Sub: drains the socket's frame broadcast and emits toMsg(frame).
/// The codegen routes `subscribeWebSocketRaw raw "message" toMsg` here (the kind
/// is a compile-time literal — see the Builder peephole).
pub fn sub_subscribe_ws_message<M, F>(socket_id: i64, to_msg: F) -> SkySub<M>
where
    M: Send + 'static,
    F: Fn(WsClientMessage) -> M + Send + Sync + 'static,
{
    SkySub::Source(Box::new(move |emit| {
        tokio::spawn(async move {
            let mut rx = match registry().lock().unwrap().get(&socket_id) {
                Some(e) => e.frames_tx.subscribe(),
                None => return,
            };
            while let Ok(frame) = rx.recv().await {
                emit(to_msg(frame));
            }
        })
    }))
}

/// onOpen / onClose / onError: their toMsg shapes (bare msg, CloseCode->msg,
/// Error->msg) differ from onMessage and can't share one bounded kernel, so they
/// route here (toMsg unbounded, ignored) and currently produce no subscription.
/// Wiring them needs a rust-target stdlib override splitting the single
/// `subscribeWebSocketRaw` into typed kernels — a follow-up. onMessage (the
/// receive path) works today.
pub fn sub_subscribe_ws_unsupported<T, M>(_socket_id: i64, _to_msg: T) -> SkySub<M> {
    SkySub::None
}
