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

async fn build_request(req: axum::extract::Request) -> ServerRequest {
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
    let body = axum::body::to_bytes(body, MAX_BODY).await
        .map(|b| String::from_utf8_lossy(&b).into_owned())
        .unwrap_or_default();
    ServerRequest { method, path, body, headers, params, query, cookies, remoteAddr: String::new() }
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
            let sky_req = build_request(req).await;
            match h(sky_req).await {
                Ok(resp) => to_axum_response(resp),
                Err(_) => (axum::http::StatusCode::INTERNAL_SERVER_ERROR, "Internal Server Error").into_response(),
            }
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
