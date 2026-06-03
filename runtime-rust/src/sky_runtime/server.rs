//! Sky.Http.Server runtime (Sub-D.1) — axum/hyper under a Sky-native surface.
//!
//! Handlers are Sky closures `Fn(Request) -> Task Error Response`. server_get
//! ERASES the project-defined error type E into a non-generic ServerRoute
//! (awaiting the task, mapping Err -> 500) so routes are uniform yet handlers
//! stay Send+Sync+'static for axum. server_listen builds an axum Router and
//! serves via tokio.
//!
//! Records map to these structs via runtimeOpaqueTypes (like Csv's CsvDoc), so
//! the generated `SkyHttpServerRequest`/`Response` are `pub use` aliases and Sky
//! field access resolves onto the pub fields. `Route`/`Cookie` are opaque Sky
//! ADTs mapped the same way.

use super::*;
use std::collections::HashMap;
use std::sync::Arc;
use std::pin::Pin;
use std::future::Future;

/// Sky.Http.Server.Request — field names/types match the Sky record alias.
#[derive(Clone, Debug)]
pub struct ServerRequest {
    pub method: String,
    pub path: String,
    pub body: String,
    pub headers: HashMap<String, String>,
    pub params: HashMap<String, String>,
    pub query: HashMap<String, String>,
    pub cookies: HashMap<String, String>,
    pub remoteAddr: String,
}

/// Sky.Http.Server.Response.
#[derive(Clone, Debug)]
pub struct ServerResponse {
    pub status: i64,
    pub body: String,
    pub headers: HashMap<String, String>,
    pub contentType: String,
}

/// Sky.Http.Server.Cookie (opaque) — safe defaults applied at attach time.
#[derive(Clone, Debug)]
pub struct ServerCookie {
    pub name: String,
    pub value: String,
}

/// A handler erased of its Sky error type `E`: it awaits the Sky task and maps
/// the result to either the response (Ok) or a 500 marker (Err). Erasing E here
/// keeps `ServerRoute` non-generic so it bridges to the non-generic Sky `Route`.
type ErasedHandler =
    Arc<dyn Fn(ServerRequest) -> Pin<Box<dyn Future<Output = Result<ServerResponse, String>> + Send>> + Send + Sync>;

/// Sky.Http.Server.Route (opaque). Non-generic — see ErasedHandler.
#[derive(Clone)]
pub struct ServerRoute {
    pub method: String,
    pub path: String,
    pub handler: Option<ErasedHandler>,
    pub static_dir: Option<String>,
}

// ─── handler erasure ──────────────────────────────────────────────────────

fn erase<E, H>(h: H) -> ErasedHandler
where
    E: Send + 'static,
    H: Fn(ServerRequest) -> SkyTask<E, ServerResponse> + Send + Sync + 'static,
{
    Arc::new(move |req: ServerRequest| {
        let task = h(req);
        Box::pin(async move {
            match task.await {
                SkyResult::Ok(resp) => Ok(resp),
                // The error detail is dropped at the boundary (-> 500). Handlers
                // wanting a typed error response should return an Ok response with
                // Server.withStatus instead; Err is for unexpected failures.
                SkyResult::Err(_) => Err("handler returned Err".to_string()),
            }
        }) as Pin<Box<dyn Future<Output = Result<ServerResponse, String>> + Send>>
    })
}

fn route<E, H>(method: &str, path: String, h: H) -> ServerRoute
where
    E: Send + 'static,
    H: Fn(ServerRequest) -> SkyTask<E, ServerResponse> + Send + Sync + 'static,
{
    ServerRoute { method: method.to_string(), path, handler: Some(erase(h)), static_dir: None }
}

// ─── routing kernels ──────────────────────────────────────────────────────

pub fn server_get<E, H>(path: String, h: H) -> ServerRoute
where E: Send + 'static, H: Fn(ServerRequest) -> SkyTask<E, ServerResponse> + Send + Sync + 'static
{ route("GET", path, h) }

pub fn server_post<E, H>(path: String, h: H) -> ServerRoute
where E: Send + 'static, H: Fn(ServerRequest) -> SkyTask<E, ServerResponse> + Send + Sync + 'static
{ route("POST", path, h) }

pub fn server_put<E, H>(path: String, h: H) -> ServerRoute
where E: Send + 'static, H: Fn(ServerRequest) -> SkyTask<E, ServerResponse> + Send + Sync + 'static
{ route("PUT", path, h) }

pub fn server_delete<E, H>(path: String, h: H) -> ServerRoute
where E: Send + 'static, H: Fn(ServerRequest) -> SkyTask<E, ServerResponse> + Send + Sync + 'static
{ route("DELETE", path, h) }

pub fn server_any<E, H>(path: String, h: H) -> ServerRoute
where E: Send + 'static, H: Fn(ServerRequest) -> SkyTask<E, ServerResponse> + Send + Sync + 'static
{ route("ANY", path, h) }

/// Server.static : String -> String -> Route  (urlPrefix, dir)
pub fn server_static(path: String, dir: String) -> ServerRoute {
    ServerRoute { method: "GET".to_string(), path, handler: None, static_dir: Some(dir) }
}

// ─── response builders (pure) ─────────────────────────────────────────────

fn resp(status: i64, body: String, ct: &str) -> ServerResponse {
    ServerResponse { status, body, headers: HashMap::new(), contentType: ct.to_string() }
}

pub fn server_text(body: String) -> ServerResponse { resp(200, body, "text/plain") }
pub fn server_json(body: String) -> ServerResponse { resp(200, body, "application/json") }
pub fn server_html(body: String) -> ServerResponse { resp(200, body, "text/html") }

pub fn server_with_status(status: i64, mut r: ServerResponse) -> ServerResponse { r.status = status; r }
pub fn server_with_header(k: String, v: String, mut r: ServerResponse) -> ServerResponse { r.headers.insert(k, v); r }
pub fn server_redirect(location: String, status: i64) -> ServerResponse {
    let mut r = resp(status, String::new(), "text/plain");
    r.headers.insert("Location".to_string(), location);
    r
}

// ─── request accessors (pure) ─────────────────────────────────────────────

pub fn server_param(name: String, req: ServerRequest) -> SkyMaybe<String> {
    match req.params.get(&name) { Some(v) => SkyMaybe::Just(v.clone()), None => SkyMaybe::Nothing }
}
pub fn server_query_param(name: String, req: ServerRequest) -> SkyMaybe<String> {
    match req.query.get(&name) { Some(v) => SkyMaybe::Just(v.clone()), None => SkyMaybe::Nothing }
}
pub fn server_header(name: String, req: ServerRequest) -> SkyMaybe<String> {
    match req.headers.get(&name) { Some(v) => SkyMaybe::Just(v.clone()), None => SkyMaybe::Nothing }
}
pub fn server_get_cookie(name: String, req: ServerRequest) -> SkyMaybe<String> {
    match req.cookies.get(&name) { Some(v) => SkyMaybe::Just(v.clone()), None => SkyMaybe::Nothing }
}

// ─── cookies ──────────────────────────────────────────────────────────────

pub fn server_cookie(name: String, value: String) -> ServerCookie { ServerCookie { name, value } }
pub fn server_with_cookie(c: ServerCookie, mut r: ServerResponse) -> ServerResponse {
    // Minimal Set-Cookie with safe defaults; full attributes land with step 4.
    let v = format!("{}={}; HttpOnly; Path=/; SameSite=Lax", c.name, c.value);
    r.headers.insert("Set-Cookie".to_string(), v);
    r
}

// ─── listen + axum adapter (step 4) ───────────────────────────────────────

const MAX_BODY: usize = 32 * 1024 * 1024; // 32 MiB

fn parse_query(q: Option<&str>) -> HashMap<String, String> {
    let mut out = HashMap::new();
    if let Some(q) = q {
        for pair in q.split('&') {
            if pair.is_empty() { continue; }
            let mut it = pair.splitn(2, '=');
            let k = it.next().unwrap_or("");
            let v = it.next().unwrap_or("");
            out.insert(urldecode(k), urldecode(v));
        }
    }
    out
}

fn urldecode(s: &str) -> String {
    // form-style: '+' -> space, %XX -> byte. Best-effort.
    let s = s.replace('+', " ");
    let mut out = Vec::new();
    let b = s.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(byte) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(byte); i += 3; continue;
            }
        }
        out.push(b[i]); i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn parse_cookies(header: &str, out: &mut HashMap<String, String>) {
    for c in header.split(';') {
        let c = c.trim();
        if let Some((k, v)) = c.split_once('=') {
            out.insert(k.trim().to_string(), v.trim().to_string());
        }
    }
}

async fn build_request(req: axum::extract::Request) -> (ServerRequest, Option<axum::extract::ws::WebSocketUpgrade>) {
    use axum::extract::{RawPathParams, FromRequestParts};
    let method = req.method().as_str().to_string();
    let uri = req.uri().clone();
    let path = uri.path().to_string();
    let query = parse_query(uri.query());
    let mut headers = HashMap::new();
    let mut cookies = HashMap::new();
    for (k, v) in req.headers() {
        if let Ok(s) = v.to_str() {
            if k.as_str().eq_ignore_ascii_case("cookie") { parse_cookies(s, &mut cookies); }
            headers.insert(k.as_str().to_string(), s.to_string());
        }
    }
    let (mut parts, body) = req.into_parts();
    let params = match RawPathParams::from_request_parts(&mut parts, &()).await {
        Ok(rpp) => rpp.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
        Err(_) => HashMap::new(),
    };
    // Sub-D.2: extract the WebSocket upgrader if this is an upgrade request
    // (succeeds only when the Connection/Upgrade/Sec-WebSocket-* headers are
    // present). Stashed via task-local so server_web_socket_upgrade can reach it.
    let upgrader = axum::extract::ws::WebSocketUpgrade::from_request_parts(&mut parts, &())
        .await.ok();
    let body = axum::body::to_bytes(body, MAX_BODY).await
        .map(|b| String::from_utf8_lossy(&b).into_owned())
        .unwrap_or_default();
    (ServerRequest { method, path, body, headers, params, query, cookies, remoteAddr: String::new() }, upgrader)
}

fn to_axum_response(r: ServerResponse) -> axum::response::Response {
    use axum::response::IntoResponse;
    let status = axum::http::StatusCode::from_u16(r.status as u16)
        .unwrap_or(axum::http::StatusCode::INTERNAL_SERVER_ERROR);
    let mut builder = axum::http::Response::builder().status(status);
    if !r.contentType.is_empty() {
        builder = builder.header("content-type", r.contentType.clone());
    }
    for (k, v) in &r.headers {
        builder = builder.header(k.as_str(), v.as_str());
    }
    match builder.body(axum::body::Body::from(r.body)) {
        Ok(resp) => resp,
        Err(_) => axum::http::StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

fn method_router(method: &str, h: ErasedHandler) -> axum::routing::MethodRouter {
    use axum::routing::{get, post, put, delete, any};
    use axum::response::IntoResponse;
    let svc = move |req: axum::extract::Request| {
        let h = h.clone();
        async move {
            let (sky_req, upgrader) = build_request(req).await;
            // Run the handler with the WS upgrader + a response slot in scope.
            // If the handler called server_web_socket_upgrade, it stashed the
            // real 101 response in WS_RESPONSE — prefer it over the sentinel.
            WS_UPGRADER.scope(std::cell::Cell::new(upgrader), async move {
                WS_RESPONSE.scope(std::cell::Cell::new(None), async move {
                    let result = h(sky_req).await;
                    if let Some(ws_resp) = WS_RESPONSE.with(|c| c.take()) {
                        return ws_resp;
                    }
                    match result {
                        Ok(resp) => to_axum_response(resp),
                        Err(_) => (axum::http::StatusCode::INTERNAL_SERVER_ERROR, "Internal Server Error").into_response(),
                    }
                }).await
            }).await
        }
    };
    match method.to_uppercase().as_str() {
        "GET" => get(svc),
        "POST" => post(svc),
        "PUT" => put(svc),
        "DELETE" => delete(svc),
        _ => any(svc),
    }
}

fn strip_trailing_slash(p: &str) -> String {
    if p.len() > 1 && p.ends_with('/') { p[..p.len() - 1].to_string() } else { p.to_string() }
}

/// Server.listen : Int -> List Route -> Task Error ()  — serves via axum/tokio.
pub fn server_listen<E: From<String> + Send + 'static>(port: i64, routes: Vec<ServerRoute>) -> SkyTask<E, ()> {
    Box::pin(async move {
        let mut app: axum::Router = axum::Router::new();
        for r in routes {
            if let Some(dir) = r.static_dir {
                app = app.nest_service(&strip_trailing_slash(&r.path), tower_http::services::ServeDir::new(dir));
                continue;
            }
            if let Some(h) = r.handler {
                app = app.route(&r.path, method_router(&r.method, h));
            }
        }
        // Sky doctrine: a panicking handler returns 500, never crashes the
        // process (mirrors the Go runtime's per-handler recover()).
        let app = app.layer(tower_http::catch_panic::CatchPanicLayer::new());
        let addr = format!("0.0.0.0:{}", port);
        let listener = match tokio::net::TcpListener::bind(&addr).await {
            Ok(l) => l,
            Err(e) => return SkyResult::Err(format!("Server.listen: bind {}: {}", addr, e).into()),
        };
        eprintln!("[sky.http.server] listening on http://{}", addr);
        match axum::serve(listener, app).await {
            Ok(()) => ok_res(()),
            Err(e) => SkyResult::Err(format!("Server.listen: serve: {}", e).into()),
        }
    })
}

// ─── Sub-D.2: Sky.Http.Server.WebSocket ───────────────────────────────────
//
// Bridged types (runtimeOpaqueTypes): WebSocketServer -> WsHandle (the opaque
// per-peer handle the stdlib pattern-matches as `WebSocketServer raw`);
// WebSocketServerCfg -> WsServerCfg (fn-pointer callbacks so the stdlib's
// `defaultCfg |> withOnX` record updates compile — see the design doc on why
// non-capturing handlers are the first-cut limit).

use std::sync::{Mutex, OnceLock};
use std::sync::atomic::{AtomicI64, Ordering};

/// Sky.Http.Server.WebSocket.WebSocketServer — opaque per-peer handle. The
/// variant name matches the Sky constructor so `case sock of WebSocketServer
/// raw` lowers onto it.
#[derive(Clone, Copy, Debug)]
pub enum WsHandle {
    WebSocketServer(i64),
}

/// Sky.Http.Server.WebSocket.WebSocketServerCfg — fn-pointer callbacks (cannot
/// capture; capturing handlers need Arc<dyn Fn> erasure, a follow-up).
///
/// Generic over the error type E because the project's concrete error
/// (SkyCoreErrorError) is unnameable from the runtime crate. The Sky-side
/// bridge pins `E = SkyError` (and drops the phantom `msg`) via a generic type
/// alias — see aliasToRustTypeDef. fn pointers don't store E, so WsServerCfg<E>
/// is Send/Copy-of-fields regardless of E.
#[allow(non_snake_case)]
#[derive(Clone)]
pub struct WsServerCfg<E> {
    // Uncurried fn-pointer fields, matching how the codegen lowers multi-arg
    // lambda VALUES (`\sock msg ->` → `|sock, msg|`). NOTE: this does not yet
    // compile end-to-end — the codegen renders function TYPES curried
    // (`A -> B -> C` → fn(A)->fn(B)->C), so `withOnMessage`'s callback param
    // (curried) disagrees with both these fields and the uncurried lambda
    // values. The fix is a general codegen change: render TLambda arrow-chains
    // uncurried. See the Sub-D.2 design doc. Until then, server WebSocket is a
    // compiling runtime foundation only.
    pub onConnect: fn(WsHandle) -> SkyTask<E, ()>,
    pub onMessage: fn(WsHandle, String) -> SkyTask<E, ()>,
    pub onClose: fn(WsHandle) -> SkyTask<E, ()>,
    pub onError: fn(WsHandle, E) -> SkyTask<E, ()>,
    pub maxMessageBytes: i64,
    pub originPatterns: Vec<String>,
}

enum WsOut { Text(String), Binary(Vec<u8>), Close }

fn ws_registry() -> &'static Mutex<HashMap<i64, tokio::sync::mpsc::UnboundedSender<WsOut>>> {
    static R: OnceLock<Mutex<HashMap<i64, tokio::sync::mpsc::UnboundedSender<WsOut>>>> = OnceLock::new();
    R.get_or_init(|| Mutex::new(HashMap::new()))
}

static WS_NEXT_ID: AtomicI64 = AtomicI64::new(1);

tokio::task_local! {
    // The axum upgrader for the in-flight request (Some only on a WS upgrade).
    static WS_UPGRADER: std::cell::Cell<Option<axum::extract::ws::WebSocketUpgrade>>;
    // The 101 response server_web_socket_upgrade produced (preferred by method_router).
    static WS_RESPONSE: std::cell::Cell<Option<axum::response::Response>>;
}

async fn ws_loop<E: From<String> + Send + 'static>(mut socket: axum::extract::ws::WebSocket, cfg: WsServerCfg<E>, id: i64) {
    use axum::extract::ws::Message;
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<WsOut>();
    ws_registry().lock().unwrap().insert(id, tx);
    let _ = (cfg.onConnect)(WsHandle::WebSocketServer(id)).await;
    loop {
        tokio::select! {
            incoming = socket.recv() => match incoming {
                Some(Ok(Message::Text(t))) => { let _ = (cfg.onMessage)(WsHandle::WebSocketServer(id), t).await; }
                Some(Ok(Message::Binary(b))) => {
                    let s = bytes_to_sky(&b);
                    let _ = (cfg.onMessage)(WsHandle::WebSocketServer(id), s).await;
                }
                Some(Ok(Message::Close(_))) | None => break,
                Some(Ok(_)) => {} // Ping/Pong auto-handled by axum
                Some(Err(e)) => {
                    let _ = (cfg.onError)(WsHandle::WebSocketServer(id), format!("ws read error: {}", e).into()).await;
                    break;
                }
            },
            outgoing = rx.recv() => match outgoing {
                Some(WsOut::Text(s)) => { if socket.send(Message::Text(s)).await.is_err() { break; } }
                Some(WsOut::Binary(b)) => { if socket.send(Message::Binary(b)).await.is_err() { break; } }
                Some(WsOut::Close) => { let _ = socket.send(Message::Close(None)).await; break; }
                None => break,
            },
        }
    }
    let _ = (cfg.onClose)(WsHandle::WebSocketServer(id)).await;
    ws_registry().lock().unwrap().remove(&id);
}

fn ws_production() -> bool {
    let v = std::env::var("ENV").or_else(|_| std::env::var("SKY_ENV")).unwrap_or_default();
    !matches!(v.as_str(), "" | "dev" | "development" | "local")
}

fn ws_resp(status: i64, body: &str) -> ServerResponse {
    ServerResponse { status, body: body.to_string(), headers: HashMap::new(), contentType: "text/plain".to_string() }
}

/// ServerWebSocket_upgrade : Request -> WebSocketServerCfg -> Task Error Response
pub fn server_web_socket_upgrade<E: From<String> + Send + 'static>(_req: ServerRequest, cfg: WsServerCfg<E>) -> SkyTask<E, ServerResponse> {
    Box::pin(async move {
        if ws_production() && cfg.originPatterns.is_empty() {
            return ok_res(ws_resp(403, "websocket: origin allowlist required in production"));
        }
        let upgrader = WS_UPGRADER.try_with(|c| c.take()).ok().flatten();
        match upgrader {
            Some(up) => {
                let id = WS_NEXT_ID.fetch_add(1, Ordering::Relaxed);
                let resp = up.on_upgrade(move |socket| ws_loop(socket, cfg, id));
                let _ = WS_RESPONSE.try_with(|c| c.set(Some(resp)));
                // Sentinel — method_router returns WS_RESPONSE instead of this.
                ok_res(ServerResponse { status: 101, body: String::new(), headers: HashMap::new(), contentType: String::new() })
            }
            None => ok_res(ws_resp(400, "websocket: expected an Upgrade request")),
        }
    })
}

fn ws_send_raw(id: i64, out: WsOut) -> bool {
    match ws_registry().lock().unwrap().get(&id) {
        Some(tx) => tx.send(out).is_ok(),
        None => false,
    }
}

/// ServerWebSocket_sendToClient : Int -> String -> Task Error ()
pub fn server_web_socket_send_to_client<E: From<String> + Send + 'static>(id: i64, msg: String) -> SkyTask<E, ()> {
    Box::pin(async move {
        if ws_send_raw(id, WsOut::Text(msg)) { ok_res(()) }
        else { SkyResult::Err(format!("ws: no client {}", id).into()) }
    })
}

/// ServerWebSocket_sendBinaryToClient : Int -> String -> Task Error ()
pub fn server_web_socket_send_binary_to_client<E: From<String> + Send + 'static>(id: i64, msg: String) -> SkyTask<E, ()> {
    Box::pin(async move {
        if ws_send_raw(id, WsOut::Binary(sky_bytes(&msg))) { ok_res(()) }
        else { SkyResult::Err(format!("ws: no client {}", id).into()) }
    })
}

/// ServerWebSocket_broadcast : List Int -> String -> Task Error ()
pub fn server_web_socket_broadcast<E: From<String> + Send + 'static>(ids: Vec<i64>, msg: String) -> SkyTask<E, ()> {
    Box::pin(async move {
        let mut any_ok = false;
        {
            let reg = ws_registry().lock().unwrap();
            for id in &ids {
                if let Some(tx) = reg.get(id) {
                    if tx.send(WsOut::Text(msg.clone())).is_ok() { any_ok = true; }
                }
            }
        }
        if ids.is_empty() || any_ok { ok_res(()) }
        else { SkyResult::Err("ws broadcast: every send failed".to_string().into()) }
    })
}

/// ServerWebSocket_closeClient : Int -> Task Error () (idempotent)
pub fn server_web_socket_close_client<E: From<String> + Send + 'static>(id: i64) -> SkyTask<E, ()> {
    Box::pin(async move { let _ = ws_send_raw(id, WsOut::Close); ok_res(()) })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::future::ready;

    #[test]
    fn build_routes_and_response() {
        // Validate the crux: a Sky-shaped handler closure boxes into a Route.
        let r: ServerRoute = server_get::<String, _>("/".to_string(), |_req: ServerRequest| {
            Box::pin(ready(ok_res::<String, _>(server_text("hi".to_string())))) as SkyTask<String, ServerResponse>
        });
        assert_eq!(r.method, "GET");
        assert!(r.handler.is_some());
        let resp = server_with_status(404, server_text("nope".to_string()));
        assert_eq!(resp.status, 404);
    }
}
