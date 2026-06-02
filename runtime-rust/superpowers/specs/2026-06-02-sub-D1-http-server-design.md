# Sub-D.1 — Sky.Http.Server on the Rust runtime (design)

**Goal:** implement `Sky.Http.Server` on `target=rust` using axum/hyper
internally (Alt-3: Sky-native module over a best-in-class crate, NOT verbatim
FFI). This unlocks web apps on the Rust backend and is the dependency for
**Sub-E (Sky.Live)**, **WebSocket** (v0.15.46), and the **HTTP types** item.

Status: **designed + scoped** (2026-06-02). Implementation pending.

---

## API surface (`sky-stdlib/Sky/Http/Server.sky`, ~25 kernels)

| Group | Kernels | Sky type |
|---|---|---|
| Routing | `Server_get/post/put/delete/any` | `String -> (Request -> Task Error Response) -> Route` |
| | `Server_api` | `String -> (Request -> Task Error Response) -> Route` ("METHOD /path") |
| | `Server_static` | `String -> String -> Route` (urlPrefix, dir) |
| | `Server_listen` | `Int -> List Route -> Task Error ()` |
| Response build | `Server_text/json/html` | `String -> Response` |
| | `Server_withStatus` | `Int -> Response -> Response` |
| | `Server_redirect` | `String -> Int -> Response` |
| | `Server_withHeader` | `String -> String -> Response -> Response` |
| | `Server_cookie` / `Server_withCookie` | build/attach a `Cookie` |
| Request access | `Server_param/queryParam/header` | `String -> Request -> Maybe String` (or String) |
| | `Server_getCookie` | `String -> Request -> Maybe String` |

**Records** (need the kernel-record-return bridge — see Csv):
- `Request = { method, path, body : String, headers/params/query/cookies : Dict String String, remoteAddr : String }`
- `Response = { status : Int, body : String, headers : Dict String String, contentType : String }`

**Opaque ADTs** (`type X = X_OPAQUE`): `Route`, `Server`, `Cookie`.

## Go reference model (`runtime-go/rt/rt.go`)

- `Server_get(path, handler)` → `SkyRoute{Method, Path, Handler}` (Handler is the
  Sky closure, stored as `any`). `Server_static` → `SkyRoute{StaticDir: dir}`.
- `Server_listen(port, routes)` → `http.ServeMux`; per route a `HandleFunc` that
  (1) builds `SkyRequest` from the `*http.Request` (method/path/headers/cookies/
  body/form/query), (2) `SkyCall(handler, skyReq)` → Task, (3) `anyTaskInvoke`
  runs it → Result, (4) writes status/body/content-type/headers. Static routes →
  `http.StripPrefix + http.FileServer`. Panic-recover per handler → 500.
- `Server_text/json/html` → `SkyResponse{Status:200, Body, ContentType}`.

## Rust design

### Types — via the runtimeOpaqueTypes bridge (already built for Csv)
Add to `runtimeOpaqueTypes`:
- `(Sky.Http.Server, Request)` → `sky_runtime::ServerRequest`
- `(Sky.Http.Server, Response)` → `sky_runtime::ServerResponse`
- `(Sky.Http.Server, Route)` → `sky_runtime::ServerRoute`
- `(Sky.Http.Server, Cookie)` → `sky_runtime::ServerCookie`

`aliasToRustTypeDef` already emits `RPubUseAlias` for registered *record* aliases
(Request/Response); `unionToRustTypeDef` already does for registered *unions*
(Route/Cookie). The runtime structs must match field names/types exactly:
```rust
pub struct ServerRequest { pub method: String, pub path: String, pub body: String,
    pub headers: HashMap<String,String>, pub params: HashMap<String,String>,
    pub query: HashMap<String,String>, pub cookies: HashMap<String,String>,
    pub remoteAddr: String }
pub struct ServerResponse { pub status: i64, pub body: String,
    pub headers: HashMap<String,String>, pub contentType: String }
```
NOTE: field is `remoteAddr`/`contentType` (camelCase — Sky field names lower onto
the struct verbatim; confirm the codegen's field-access casing).

### Handler model — the crux
`get : String -> (Request -> Task Error Response) -> Route`. The handler lowers
to a Rust closure `impl Fn(ServerRequest) -> SkyTask<E, ServerResponse>`. Routes
go in a `Vec<ServerRoute>` (heterogeneous closures) → box it:
```rust
type Handler = Arc<dyn Fn(ServerRequest) -> SkyTask<SkyError, ServerResponse> + Send + Sync>;
pub struct ServerRoute { method: String, path: String, handler: Option<Handler>, static_dir: Option<String> }
pub fn server_get<H>(path: String, h: H) -> ServerRoute
  where H: Fn(ServerRequest) -> SkyTask<SkyError, ServerResponse> + Send + Sync + 'static
{ ServerRoute { method: "GET".into(), path, handler: Some(Arc::new(h)), static_dir: None } }
```
Constraints: the handler must be `Send + Sync + 'static` (axum). Sky `move`
closures are Send/'static when captures are; Sync needs captured values Sync
(top-level DB handles etc. are). **Risk to validate early.** Note `SkyTask`'s
`E` is pinned to `SkyError` here (can't be generic in the boxed type) — fine,
Cardinal Rule 1.

### listen — axum router + adapter + serve
```rust
pub fn server_listen<E: From<String> + Send + 'static>(port: i64, routes: Vec<ServerRoute>) -> SkyTask<E, ()> {
    Box::pin(async move {
        let mut app = axum::Router::new();
        for r in routes {
            if let Some(dir) = r.static_dir { app = app.nest_service(&strip(r.path), ServeDir::new(dir)); continue; }
            let h = r.handler.unwrap();
            let method_router = match r.method.as_str() { "GET" => get(adapter(h)), "POST" => post(adapter(h)), ... };
            app = app.route(&axum_path(&r.path), method_router);
        }
        let listener = tokio::net::TcpListener::bind(("0.0.0.0", port as u16)).await?;
        axum::serve(listener, app).await?;  // blocks
        ok_res(())
    })
}
```
The `adapter(h)` builds a `ServerRequest` from axum extractors (Method, Uri,
HeaderMap, the matched Path params, query, cookies, body String), calls
`h(req)` → `SkyTask` → `.await` → `ServerResponse`, converts to an axum
`Response` (status + body + content-type + headers). Panic-recover via
`tower::catch_panic` or a per-handler guard → 500.

Path syntax: Sky `:param` → axum `{param}` (axum 0.7+). `param`/`queryParam` read
from the populated `params`/`query` HashMaps in ServerRequest.

### Pure helpers (easy, no async)
`server_text/json/html` → `ServerResponse`. `server_with_status/with_header/
redirect/cookie/with_cookie` → construct/decorate. `server_param/query_param/
header/get_cookie` → `SkyMaybe<String>` from the request HashMaps.

### Crates
`axum = "0.7"`, `tower-http = { version="0.6", features=["fs"] }` (ServeDir),
`tower = "0.5"` (catch_panic), tokio (have, needs `net`). Gate behind a `server`
feature in the runtime crate; conditional inclusion in the generated project via
a new `usesHttpServer` flag (like `usesUuid`).

---

## Implementation plan (steps)

1. **Types + bridge.** Runtime structs (ServerRequest/Response/Route/Cookie) +
   4 runtimeOpaqueTypes entries. Verify field-access casing (camelCase). Confirm
   a trivial `\req -> Task.succeed (text "hi")` handler *compiles* (closure type).
2. **Pure helpers.** text/json/html/withStatus/withHeader/redirect/cookie/
   withCookie + param/queryParam/header/getCookie. Easy; unit-test.
3. **Route constructors.** server_get/post/put/delete/any/api + static. Boxed
   Arc handler. Confirm a `List Route` builds.
4. **listen + adapter.** axum Router, method routing, the request-build →
   handler-await → response-convert adapter, TcpListener serve. The hard part —
   validate Send+Sync+'static on the boxed handler first.
5. **static** via ServeDir; **panic-recover** → 500.
6. **Example + test.** `examples/rust/NN-http-server` (GET / → text, GET
   /users/:id → param echo); a smoke test that boots on an ephemeral port and
   curls it (or a tower oneshot in-process test in the runtime crate, which
   avoids a real socket — preferred for CI determinism).
7. **Conditional wiring.** `usesHttpServer` flag → mod + axum deps only when
   Sky.Http.Server is used.

## Risks
- **Send + Sync + 'static** on Sky closures captured into axum. Validate at step
  1 with the simplest handler. If Sync fails, may need the handler to own
  Arc-wrapped captures, or run handlers on a `spawn_blocking`/single-thread.
- **SkyTask one-shot** is fine here (each request awaits a fresh handler call;
  no re-run needed — unlike retryWith).
- **listen blocks** the Task — matches Go (Server_listen never returns). The
  `main` boundary runs it via Task.run.
- **Sky.Live (Sub-E)** reuses this server + SSE; design the adapter so SSE
  streaming (`Sky.Core.Http.Stream`) can hook in later.
