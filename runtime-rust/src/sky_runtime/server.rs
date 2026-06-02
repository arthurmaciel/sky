//! Sky.Http.Server runtime (Sub-D.1) — axum/hyper under a Sky-native surface.
//!
//! STEP 1 (this file currently): the type bridge + route construction + the
//! crux validation that a Sky handler closure boxes cleanly. `server_listen` is
//! a stub here; step 4 wires the axum Router + request adapter + serve loop.
//!
//! Records map to these structs via runtimeOpaqueTypes (like Csv's CsvDoc), so
//! the generated `SkyHttpServerRequest`/`Response` are `pub use` aliases and Sky
//! field access resolves onto the pub fields. `Route`/`Cookie` are opaque Sky
//! ADTs mapped the same way.

use super::*;
use std::collections::HashMap;
use std::sync::Arc;
use std::pin::Pin;
use std::future::{Future, ready};

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

// ─── listen (STEP 1 STUB — step 4 replaces with axum serve) ───────────────

/// Server.listen : Int -> List Route -> Task Error ()
/// STEP 1 STUB: the type pipeline (routes built, handler closures erased, Task
/// shape) is validated, but serving is not yet wired — that's step 4 (axum
/// Router + request adapter + serve loop). Prints a loud notice so it can't be
/// mistaken for a running server, then resolves Ok so Task chains don't break.
pub fn server_listen<E: Send + 'static>(port: i64, routes: Vec<ServerRoute>) -> SkyTask<E, ()> {
    eprintln!(
        "[sky.http.server] target=rust: serving not yet implemented (Sub-D.1 step 4). \
         Configured {} route(s) for port {} — NOT listening.",
        routes.len(), port
    );
    Box::pin(ready(ok_res(())))
}

#[cfg(test)]
mod tests {
    use super::*;

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
