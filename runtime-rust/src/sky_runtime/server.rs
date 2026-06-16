//! Sky.Http.Server runtime — axum/hyper under a Sky-native surface.
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
// camelCase is required: Sky field access (`req.remoteAddr`) resolves onto
// these pub fields, so they must mirror the Sky record's names verbatim.
#[allow(non_snake_case)]
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
// camelCase is required: Sky field access (`resp.contentType`) resolves onto
// these pub fields, so they must mirror the Sky record's names verbatim.
#[allow(non_snake_case)]
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

/// The Sky `Handler` type (`Request -> Task Error Response`) reified as a
/// shareable, error-typed closure. The Rust codegen renders the `Handler` type
/// alias (and any `Request -> Task Error Response` arrow — e.g. the `h :
/// Handler` param of a middleware-wrapping closure `guarded h = …`) as exactly
/// this `Arc<dyn Fn>`, because a real route handler CAPTURES app state
/// (`handleRegister cfg db`) and a capturing closure cannot coerce to a bare
/// `fn` pointer.
pub type ServerHandler<E> =
    Arc<dyn Fn(ServerRequest) -> SkyTask<E, ServerResponse> + Send + Sync>;

/// Accept a route / middleware handler as EITHER a bare closure / fn item OR an
/// already-boxed `ServerHandler<E>` (the Arc the `Handler` alias renders as),
/// converging both to `ServerHandler<E>`. The two impls below can never overlap:
/// `Arc<dyn Fn>` does NOT itself implement `Fn`, so a value is covered by at most
/// one impl. This is what lets `server_get(path, my_fn)` (15-http-server, a bare
/// fn item) AND `wrap(guarded(handleDelete cfg db))` (36-composite-server, a
/// captured Arc handler threaded through middleware) both register without any
/// call-site wrapping in the generated code — the conversion is total and
/// allocation-free on the Arc path (it returns the Arc as-is).
pub trait IntoServerHandler<E> {
    fn into_server_handler(self) -> ServerHandler<E>;
}

impl<E, F> IntoServerHandler<E> for F
where
    F: Fn(ServerRequest) -> SkyTask<E, ServerResponse> + Send + Sync + 'static,
{
    fn into_server_handler(self) -> ServerHandler<E> { Arc::new(self) }
}

impl<E> IntoServerHandler<E> for ServerHandler<E> {
    fn into_server_handler(self) -> ServerHandler<E> { self }
}

// The codegen Arc-wraps a partial-applied route handler at its construction site
// (`Arc::new(move |req| handle_register(cfg, db, req))`), yielding an
// `Arc<{concrete closure}>` — distinct from both the blanket `F: Fn` impl (an
// `Arc` is not itself `Fn`) and the `Arc<dyn Fn>` (`ServerHandler<E>`) impl above
// (`dyn Fn` is `!Sized`, so it can't match this `Sized` `F`). Unsize it to
// `Arc<dyn Fn>` here so that form registers directly with `server_get` /
// `server_api`. The three impls cover pairwise-disjoint types.
impl<E, F> IntoServerHandler<E> for Arc<F>
where
    F: Fn(ServerRequest) -> SkyTask<E, ServerResponse> + Send + Sync + 'static,
{
    fn into_server_handler(self) -> ServerHandler<E> { self }
}

/// Sky.Http.Server.Route (opaque). Non-generic — see ErasedHandler.
#[derive(Clone)]
pub struct ServerRoute {
    pub method: String,
    pub path: String,
    pub handler: Option<ErasedHandler>,
    pub static_dir: Option<String>,
}

// ─── handler erasure ──────────────────────────────────────────────────────

fn erase<E>(h: ServerHandler<E>) -> ErasedHandler
where
    E: Send + 'static,
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
    H: IntoServerHandler<E>,
{
    ServerRoute { method: method.to_string(), path, handler: Some(erase(h.into_server_handler())), static_dir: None }
}

// ─── routing kernels ──────────────────────────────────────────────────────

pub fn server_get<E, H>(path: String, h: H) -> ServerRoute
where E: Send + 'static, H: IntoServerHandler<E>
{ route("GET", path, h) }

pub fn server_post<E, H>(path: String, h: H) -> ServerRoute
where E: Send + 'static, H: IntoServerHandler<E>
{ route("POST", path, h) }

pub fn server_put<E, H>(path: String, h: H) -> ServerRoute
where E: Send + 'static, H: IntoServerHandler<E>
{ route("PUT", path, h) }

pub fn server_delete<E, H>(path: String, h: H) -> ServerRoute
where E: Send + 'static, H: IntoServerHandler<E>
{ route("DELETE", path, h) }

pub fn server_any<E, H>(path: String, h: H) -> ServerRoute
where E: Send + 'static, H: IntoServerHandler<E>
{ route("ANY", path, h) }

/// Server.api : String -> (Request -> Task Error Response) -> Route
///
/// `spec` is "METHOD /path" (e.g. "POST /v1/generate"); an omitted method
/// matches any verb. Mirrors Go's `Server_api`. The CSRF-exemption Go performs
/// (`WithoutCsrf`) is a browser-session / double-submit concern from Sky.Live
/// with no analogue on the Rust HTTP server, so it has no effect here.
pub fn server_api<E, H>(spec: String, h: H) -> ServerRoute
where E: Send + 'static, H: IntoServerHandler<E>
{
    let (method, path) = match spec.find(' ') {
        Some(idx) if idx > 0 =>
            (spec[..idx].trim().to_uppercase(), spec[idx + 1..].trim().to_string()),
        _ => ("ANY".to_string(), spec.trim().to_string()),
    };
    route(&method, path, h)
}

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
/// Sky `redirect : String -> Response` — a 302 to `location`. Matches the Sky
/// kernel's one-arg contract and Go's `Server_redirectT` (status is hardcoded,
/// not a parameter; use `withStatus` to override).
pub fn server_redirect(location: String) -> ServerResponse {
    let mut r = resp(302, String::new(), "text/plain");
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

const DEFAULT_MAX_BODY: usize = 32 * 1024 * 1024; // 32 MiB

/// Request-body cap. Overridable via SKY_LIVE_MAX_BODY_BYTES (same env var as the
/// Go runtime's `[live] maxBodyBytes`); falls back to 32 MiB.
fn max_body() -> usize {
    std::env::var("SKY_LIVE_MAX_BODY_BYTES")
        .ok()
        .and_then(|v| v.trim().parse::<usize>().ok())
        .filter(|&n| n > 0)
        .unwrap_or(DEFAULT_MAX_BODY)
}

fn parse_query(q: Option<&str>) -> HashMap<String, String> {
    let mut out = HashMap::new();
    if let Some(q) = q {
        for pair in q.split('&') {
            if pair.is_empty() { continue; }
            let mut it = pair.splitn(2, '=');
            let k = it.next().unwrap_or("");
            let v = it.next().unwrap_or("");
            // Repeated keys keep the FIRST value — consistent with
            // http_client::http_parse_query and the Go runtime's parseQuery.
            out.entry(urldecode(k)).or_insert_with(|| urldecode(v));
        }
    }
    out
}

fn urldecode(s: &str) -> String { form_url_decode(s) }

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
    // Peer address from the connect-info extension (see server_listen). A
    // proxy's X-Forwarded-For / X-Real-IP wins when present (the real client).
    let remote_addr = headers.iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("x-forwarded-for"))
        .map(|(_, v)| v.split(',').next().unwrap_or("").trim().to_string())
        .filter(|s| !s.is_empty())
        .or_else(|| headers.iter().find(|(k, _)| k.eq_ignore_ascii_case("x-real-ip")).map(|(_, v)| v.clone()))
        .or_else(|| parts.extensions.get::<axum::extract::ConnectInfo<std::net::SocketAddr>>().map(|ci| ci.0.ip().to_string()))
        .unwrap_or_default();
    // Extract the WebSocket upgrader if this is an upgrade request
    // (succeeds only when the Connection/Upgrade/Sec-WebSocket-* headers are
    // present). Stashed via task-local so server_web_socket_upgrade can reach it.
    let upgrader = axum::extract::ws::WebSocketUpgrade::from_request_parts(&mut parts, &())
        .await.ok();
    let body = axum::body::to_bytes(body, max_body()).await
        .map(|b| String::from_utf8_lossy(&b).into_owned())
        .unwrap_or_default();
    (ServerRequest { method, path, body, headers, params, query, cookies, remoteAddr: remote_addr }, upgrader)
}

fn to_axum_response(r: ServerResponse) -> axum::response::Response {
    use axum::response::IntoResponse;
    // Sky.Http.Server.Stream: a streaming response carries a sentinel body the
    // handler stashed via ServerStream.stream. Detect it + serve the chunked
    // body before the buffered path runs.
    if let Some(streamed) = serve_streaming_sentinel(&r) {
        return streamed;
    }
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
        // with_connect_info so each request carries the peer SocketAddr —
        // populates ServerRequest.remoteAddr (also used by per-IP rate limiting).
        let svc = app.into_make_service_with_connect_info::<std::net::SocketAddr>();
        match axum::serve(listener, svc).await {
            Ok(()) => ok_res(()),
            Err(e) => SkyResult::Err(format!("Server.listen: serve: {}", e).into()),
        }
    })
}

// ─── Sky.Http.Server.WebSocket ────────────────────────────────────────────
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
    // Stored effectful callbacks. These are `Arc<dyn Fn + Send + Sync>`, NOT
    // bare `fn` pointers: a real handler captures app state (the SSE-relay shape
    // proves capturing closures are first-class — see ex-32), and a captured
    // closure is not a `fn` pointer. The codegen renders function-typed record
    // fields as `Arc<dyn Fn(..) -> .. + Send + Sync>` and wraps the assigned
    // value in `Arc::new(..)` at every record literal / field-update site, so
    // the `withOnX` setters (param `impl Fn`) and `defaultCfg` (lambda literals)
    // both store cleanly. Arc is Clone, so the `#[derive(Clone)]` above holds.
    pub onConnect: Arc<dyn Fn(WsHandle) -> SkyTask<E, ()> + Send + Sync>,
    pub onMessage: Arc<dyn Fn(WsHandle, String) -> SkyTask<E, ()> + Send + Sync>,
    pub onClose: Arc<dyn Fn(WsHandle) -> SkyTask<E, ()> + Send + Sync>,
    pub onError: Arc<dyn Fn(WsHandle, E) -> SkyTask<E, ()> + Send + Sync>,
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
    ws_registry().lock().unwrap_or_else(|e| e.into_inner()).insert(id, tx);
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
    ws_registry().lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
}

fn ws_production() -> bool {
    let v = std::env::var("ENV").or_else(|_| std::env::var("SKY_ENV")).unwrap_or_default();
    !matches!(v.as_str(), "" | "dev" | "development" | "local")
}

fn ws_resp(status: i64, body: &str) -> ServerResponse {
    ServerResponse { status, body: body.to_string(), headers: HashMap::new(), contentType: "text/plain".to_string() }
}

/// Glob match with `*` wildcards (e.g. "https://*.example.com"). `*` matches any
/// run of characters; all other chars are literal. Used for WS origin allowlists.
fn ws_origin_matches(pattern: &str, origin: &str) -> bool {
    let parts: Vec<&str> = pattern.split('*').collect();
    if parts.len() == 1 {
        return pattern == origin; // no wildcard → exact
    }
    let mut rest = origin;
    // First segment must be a prefix (unless pattern starts with '*').
    if let Some(first) = parts.first() {
        if !rest.starts_with(first) { return false; }
        rest = rest.get(first.len()..).unwrap_or("");
    }
    // Middle segments must appear in order. (parts.len() >= 2 here — the
    // len == 1 case returned early — so the slice is total.)
    for seg in parts.get(1..parts.len() - 1).unwrap_or(&[]) {
        if seg.is_empty() { continue; }
        match rest.find(seg) {
            Some(i) => rest = rest.get(i + seg.len()..).unwrap_or(""),
            None => return false,
        }
    }
    // Last segment must be a suffix (unless pattern ends with '*').
    rest.ends_with(parts.last().copied().unwrap_or(""))
}

/// ServerWebSocket_upgrade : Request -> WebSocketServerCfg -> Task Error Response
pub fn server_web_socket_upgrade<E: From<String> + Send + 'static>(req: ServerRequest, cfg: WsServerCfg<E>) -> SkyTask<E, ServerResponse> {
    Box::pin(async move {
        // Origin allowlist. Production with no patterns → reject (matches Go). With
        // patterns set (any mode), the request's Origin must match one of them.
        if ws_production() && cfg.originPatterns.is_empty() {
            return ok_res(ws_resp(403, "websocket: origin allowlist required in production"));
        }
        if !cfg.originPatterns.is_empty() {
            let origin = req.headers.iter()
                .find(|(k, _)| k.eq_ignore_ascii_case("origin"))
                .map(|(_, v)| v.as_str())
                .unwrap_or("");
            if !cfg.originPatterns.iter().any(|p| ws_origin_matches(p, origin)) {
                return ok_res(ws_resp(403, "websocket: origin not allowed"));
            }
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
    match ws_registry().lock().unwrap_or_else(|e| e.into_inner()).get(&id) {
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
            let reg = ws_registry().lock().unwrap_or_else(|e| e.into_inner());
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

// ─── Sky.Http.Middleware + Sky.Http.RateLimit ─────────────────────────────
//
// A Handler is `Fn(ServerRequest) -> SkyTask<E, ServerResponse>`. Each `with*`
// wraps a handler and returns a new one; they chain generically (each output is
// the next's input H), so no concrete `Handler` type is named.

fn header_ci<'a>(headers: &'a HashMap<String, String>, name: &str) -> Option<&'a str> {
    headers.iter().find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
}

fn plain_resp(status: i64, body: &str, extra: &[(&str, &str)]) -> ServerResponse {
    let mut headers = HashMap::new();
    for (k, v) in extra { headers.insert(k.to_string(), v.to_string()); }
    ServerResponse { status, body: body.to_string(), headers, contentType: "text/plain".to_string() }
}

/// Middleware.withCors : List String -> Handler -> Handler. Echoes an allowed
/// Origin (or `*`), answers preflight OPTIONS with 204, and tags responses.
pub fn middleware_with_cors<E, H>(origins: Vec<String>, h: H) -> ServerHandler<E>
where
    E: Send + 'static,
    H: IntoServerHandler<E>,
{
    let h = h.into_server_handler();
    Arc::new(move |req: ServerRequest| {
        let req_origin = header_ci(&req.headers, "origin").unwrap_or("").to_string();
        let allow = if origins.iter().any(|o| o == "*") {
            Some("*".to_string())
        } else if origins.iter().any(|o| o == &req_origin) && !req_origin.is_empty() {
            Some(req_origin)
        } else {
            None
        };
        if req.method.eq_ignore_ascii_case("OPTIONS") {
            let mut resp = plain_resp(204, "", &[
                ("access-control-allow-methods", "GET, POST, PUT, DELETE, OPTIONS"),
                ("access-control-allow-headers", "Content-Type, Authorization"),
            ]);
            if let Some(a) = allow { resp.headers.insert("access-control-allow-origin".to_string(), a); }
            return Box::pin(async move { ok_res(resp) });
        }
        let task = h(req);
        Box::pin(async move {
            match task.await {
                SkyResult::Ok(mut resp) => {
                    if let Some(a) = allow { resp.headers.insert("access-control-allow-origin".to_string(), a); }
                    ok_res(resp)
                }
                other => other,
            }
        })
    })
}

/// Middleware.withLogging : Handler -> Handler. Logs `method path status Nms`.
pub fn middleware_with_logging<E, H>(h: H) -> ServerHandler<E>
where
    E: Send + 'static,
    H: IntoServerHandler<E>,
{
    let h = h.into_server_handler();
    Arc::new(move |req: ServerRequest| {
        let method = req.method.clone();
        let path = req.path.clone();
        let start = std::time::Instant::now();
        let task = h(req);
        Box::pin(async move {
            let result = task.await;
            let status = match &result { SkyResult::Ok(r) => r.status, SkyResult::Err(_) => 500 };
            eprintln!("[sky.http] {} {} {} {}ms", method, path, status, start.elapsed().as_millis());
            result
        })
    })
}

/// Middleware.withBasicAuth : String -> String -> Handler -> Handler. Requires
/// HTTP Basic auth; constant-time credential comparison; 401 otherwise.
pub fn middleware_with_basic_auth<E, H>(user: String, pass: String, h: H) -> ServerHandler<E>
where
    E: Send + 'static,
    H: IntoServerHandler<E>,
{
    let h = h.into_server_handler();
    Arc::new(move |req: ServerRequest| {
        use subtle::ConstantTimeEq;
        let expected = format!("Basic {}", base64_encode(format!("{}:{}", user, pass)));
        let got = header_ci(&req.headers, "authorization").unwrap_or("");
        let ok: bool = got.as_bytes().ct_eq(expected.as_bytes()).into();
        if ok {
            h(req)
        } else {
            Box::pin(async move {
                ok_res(plain_resp(401, "Unauthorized", &[("www-authenticate", "Basic realm=\"Sky\"")]))
            })
        }
    })
}

/// Middleware.withRateLimit : String -> Int -> Int -> Handler -> Handler.
/// Per-(key, client-IP) fixed window; 429 when exceeded.
pub fn middleware_with_rate_limit<E, H>(key: String, limit: i64, window_secs: i64, h: H) -> ServerHandler<E>
where
    E: Send + 'static,
    H: IntoServerHandler<E>,
{
    let h = h.into_server_handler();
    Arc::new(move |req: ServerRequest| {
        if fixed_window_allow(&key, &req.remoteAddr, limit, window_secs) {
            h(req)
        } else {
            Box::pin(async move { ok_res(plain_resp(429, "Too Many Requests", &[])) })
        }
    })
}

fn unix_secs_f64() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

struct WindowEntry { start: f64, count: i64 }

fn fixed_window_allow(key: &str, client: &str, limit: i64, window_secs: i64) -> bool {
    static W: OnceLock<Mutex<HashMap<(String, String), WindowEntry>>> = OnceLock::new();
    let now = unix_secs_f64();
    let mut m = W.get_or_init(|| Mutex::new(HashMap::new())).lock().unwrap_or_else(|e| e.into_inner());
    let e = m.entry((key.to_string(), client.to_string())).or_insert(WindowEntry { start: now, count: 0 });
    if now - e.start >= window_secs.max(1) as f64 { e.start = now; e.count = 0; }
    if e.count < limit.max(0) { e.count += 1; true } else { false }
}

struct Bucket { tokens: f64, last: f64 }

/// RateLimit.allow : String -> String -> Int -> Int -> Bool — token bucket per
/// (name, key); capacity tokens, refilled `refill_per_sec`. True if a token was
/// consumed.
pub fn rate_limit_allow(name: String, key: String, capacity: i64, refill_per_sec: i64) -> bool {
    static B: OnceLock<Mutex<HashMap<(String, String), Bucket>>> = OnceLock::new();
    let cap = capacity.max(0) as f64;
    let now = unix_secs_f64();
    let mut m = B.get_or_init(|| Mutex::new(HashMap::new())).lock().unwrap_or_else(|e| e.into_inner());
    let b = m.entry((name, key)).or_insert(Bucket { tokens: cap, last: now });
    b.tokens = (b.tokens + (now - b.last) * refill_per_sec.max(0) as f64).min(cap);
    b.last = now;
    if b.tokens >= 1.0 { b.tokens -= 1.0; true } else { false }
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

    #[test]
    fn origin_glob_matching() {
        assert!(ws_origin_matches("https://app.example.com", "https://app.example.com"));
        assert!(!ws_origin_matches("https://app.example.com", "https://evil.com"));
        assert!(ws_origin_matches("https://*.example.com", "https://app.example.com"));
        assert!(ws_origin_matches("https://*.example.com", "https://a.b.example.com"));
        assert!(!ws_origin_matches("https://*.example.com", "https://example.com"));
        assert!(!ws_origin_matches("https://*.example.com", "http://app.example.com"));
        assert!(ws_origin_matches("*", "anything://x"));
        assert!(ws_origin_matches("*.local", "x.local"));
        assert!(!ws_origin_matches("*.local", "x.remote"));
    }

    #[test]
    fn query_and_cookies() {
        let q = parse_query(Some("a=1&b=two%20words&a=ignored&flag"));
        assert_eq!(q.get("a").map(String::as_str), Some("1")); // first value wins
        assert_eq!(q.get("b").map(String::as_str), Some("two words"));
        assert_eq!(q.get("flag").map(String::as_str), Some(""));
        assert!(parse_query(None).is_empty());

        let mut c = std::collections::HashMap::new();
        parse_cookies("sid=abc; theme=dark", &mut c);
        assert_eq!(c.get("sid").map(String::as_str), Some("abc"));
        assert_eq!(c.get("theme").map(String::as_str), Some("dark"));
    }

    #[test]
    fn max_body_env_override() {
        std::env::remove_var("SKY_LIVE_MAX_BODY_BYTES");
        assert_eq!(max_body(), DEFAULT_MAX_BODY);
        std::env::set_var("SKY_LIVE_MAX_BODY_BYTES", "1024");
        assert_eq!(max_body(), 1024);
        std::env::set_var("SKY_LIVE_MAX_BODY_BYTES", "0"); // invalid → default
        assert_eq!(max_body(), DEFAULT_MAX_BODY);
        std::env::remove_var("SKY_LIVE_MAX_BODY_BYTES");
    }
}
