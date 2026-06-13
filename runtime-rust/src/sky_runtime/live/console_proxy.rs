//! Pre-built console child + reverse-proxy (epic A).
//!
//! Replaces the in-process `console.rs` plain-HTML shell with the **real bundled
//! Sky.Live console**, spawned as a child process and reverse-proxied at
//! `/_sky/console/*`. The console binary is **pre-built at the user's `sky build`
//! time** (epic A1) into a shared cache — at runtime this module only `exec`s it,
//! never builds. See `runtime-rust/README.md` §"Rust vs Go — divergent strategies"
//! for why Rust takes the separate-process path Go abandoned (Go's subprocess
//! OOM was a *runtime* `go build`, which a pre-built binary doesn't incur).
//!
//! This module (Task 1): gate + spawn + lifecycle. The reverse-proxy handler and
//! the Live-boot wiring land in Tasks 2–3.
//!
//! No panic vectors: a missing binary / spawn failure / disabled gate returns
//! `None` so the caller falls back to the in-process console; no `unwrap`.

use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};
use tokio::process::{Child, Command};

/// Override for the pre-built console binary path. When unset, the cache path
/// (`~/.cache/sky/rust-console/<sky-version>/sky-console`, written by A1) is used.
const CONSOLE_BIN_ENV: &str = "SKY_CONSOLE_BIN";

/// The mount prefix. The parent proxies everything under this path to the child
/// and STRIPS the prefix before forwarding (the strip convention — see the
/// module doc): the child's router stays root-relative, identical to a
/// standalone Live app. The child only learns the prefix via `SKY_LIVE_BASE_PATH`
/// (so its rendered `/_sky/event` / `/_sky/sse` URLs come back prefixed and we
/// strip them again on the way in).
const CONSOLE_BASE: &str = "/_sky/console";

/// Request-body buffer cap for the proxy (16 MiB). Event POST bodies are far
/// smaller (`SKY_LIVE_MAX_BODY_BYTES` defaults to 5 MiB); this is the hard
/// ceiling above which we 502 rather than buffer unboundedly. Responses are
/// STREAMED, never buffered, so SSE is unaffected by this cap.
const MAX_PROXY_BODY: usize = 16 * 1024 * 1024;

/// Readiness-wait ceiling after spawn before we declare the child live (else we
/// fall back to the in-process console). Bounded so a wedged child can't hang
/// boot.
const READY_TIMEOUT: Duration = Duration::from_secs(8);

/// The spawned console child, tracked so the parent can kill it on shutdown
/// (Go's `ShutdownSubApps` equivalent — Go deleted it when it went in-process;
/// the separate-process Rust path needs it back to avoid an orphan child).
static CHILD: Mutex<Option<Child>> = Mutex::new(None);

/// Resolve the pre-built console binary path: `SKY_CONSOLE_BIN`, else the
/// version-keyed cache path A1 populates. `None` when neither exists (→ the
/// caller falls back to the in-process console; first build before A1 lands, or
/// a build env where the console couldn't be pre-built).
pub fn console_bin_path() -> Option<std::path::PathBuf> {
    if let Ok(p) = std::env::var(CONSOLE_BIN_ENV) {
        if !p.is_empty() {
            let pb = std::path::PathBuf::from(p);
            return if pb.is_file() { Some(pb) } else { None };
        }
    }
    let ver = env!("CARGO_PKG_VERSION");
    let home = std::env::var("HOME").ok()?;
    let pb = std::path::Path::new(&home)
        .join(".cache/sky/rust-console")
        .join(ver)
        .join("sky-console");
    if pb.is_file() {
        Some(pb)
    } else {
        None
    }
}

/// Boot-time decision: should the console child be spawned + mounted at all?
/// Mirrors Go `MountEmbeddedConsole`'s skip conditions (console.go:257).
/// `false` → the caller skips the proxy (and may mount the in-process console or
/// nothing, per its own gate).
pub fn gate_allows() -> bool {
    // Sub-app context: the parent owns its own console; a nested app must not
    // recursively mount one.
    if std::env::var("SKY_LIVE_BASE_PATH").map(|v| !v.is_empty()).unwrap_or(false) {
        return false;
    }
    // Explicit opt-outs.
    if matches!(
        std::env::var("SKY_CONSOLE_EMBED").as_deref(),
        Ok("off") | Ok("0") | Ok("false")
    ) {
        return false;
    }
    if std::env::var("SKY_CONSOLE_AUTH").map(|v| v == "off").unwrap_or(false) {
        return false;
    }
    // Production without an admin token → no silent open-to-the-world mount.
    if super::super::telemetry::production_from_env()
        && std::env::var("SKY_ADMIN_TOKEN").map(|v| v.is_empty()).unwrap_or(true)
        && std::env::var("SKY_CONSOLE_TOKEN").map(|v| v.is_empty()).unwrap_or(true)
    {
        return false;
    }
    true
}

/// Spawn the pre-built console child on `child_port`, pointing it at the spill
/// (`hub_db`, the parent's `SKY_CONSOLE_DB_PATH`). Returns `Some(())` on a
/// successful spawn (the `Child` is tracked in `CHILD`); `None` when the binary
/// is absent or the spawn fails — the caller falls back to the in-process
/// console. `kill_on_drop` + `shutdown_console` ensure no orphan.
pub fn spawn_console(child_port: u16, hub_db: &str) -> Option<()> {
    let bin = console_bin_path()?;
    let mut cmd = Command::new(&bin);
    cmd.env("SKY_LIVE_PORT", child_port.to_string())
        .env("SKY_LIVE_BASE_PATH", "/_sky/console")
        // The console reads its data plane from SKY_CONSOLE_HUB_DB (→ hubStore);
        // wire it to the parent's spill so D→S1→A is one loop.
        .env("SKY_CONSOLE_HUB_DB", hub_db)
        // Belt-and-braces: suppress the child's own console auto-mount + banner.
        .env("SKY_CONSOLE_EMBED", "off")
        .kill_on_drop(true);
    if hub_db.is_empty() {
        cmd.env_remove("SKY_CONSOLE_HUB_DB");
    }
    match cmd.spawn() {
        Ok(child) => {
            if let Ok(mut g) = CHILD.lock() {
                *g = Some(child);
            }
            eprintln!("[sky.console] spawned console child on :{child_port} (bin {})", bin.display());
            Some(())
        }
        Err(e) => {
            eprintln!("[sky.console] spawn failed ({e}); falling back to in-process console");
            None
        }
    }
}

/// Kill the tracked console child (parent shutdown). Idempotent; never panics.
pub fn shutdown_console() {
    if let Ok(mut g) = CHILD.lock() {
        if let Some(child) = g.as_mut() {
            let _ = child.start_kill();
        }
        *g = None;
    }
}

/// Install a best-effort signal handler that kills the console child on
/// SIGINT/SIGTERM, so the child dies with the parent even though the Live server
/// has no graceful-shutdown hook of its own. Spawned once at mount time.
pub fn install_shutdown_hook() {
    tokio::spawn(async {
        #[cfg(unix)]
        {
            use tokio::signal::unix::{signal, SignalKind};
            let mut term = match signal(SignalKind::terminate()) {
                Ok(s) => s,
                Err(_) => return,
            };
            let mut intr = match signal(SignalKind::interrupt()) {
                Ok(s) => s,
                Err(_) => return,
            };
            tokio::select! {
                _ = term.recv() => {}
                _ = intr.recv() => {}
            }
            shutdown_console();
        }
        #[cfg(not(unix))]
        {
            let _ = tokio::signal::ctrl_c().await;
            shutdown_console();
        }
    });
}

// ─── Reverse proxy (Task 2) ─────────────────────────────────────────────────

/// Shared proxy state, initialised once when the proxy mounts: the upstream
/// origin (`http://127.0.0.1:<child_port>`) and a connection-pooling client.
struct ProxyState {
    client: reqwest::Client,
    upstream: String,
}

static PROXY: OnceLock<ProxyState> = OnceLock::new();

/// RFC 7230 §6.1 hop-by-hop headers (plus `host`, which reqwest derives from the
/// upstream URL, and `content-length`, which we drop because every proxied
/// response is re-encoded as a stream). Never forwarded in either direction.
fn is_hop_by_hop(name: &axum::http::HeaderName) -> bool {
    matches!(
        name.as_str(),
        "connection"
            | "keep-alive"
            | "proxy-authenticate"
            | "proxy-authorization"
            | "te"
            | "trailer"
            | "transfer-encoding"
            | "upgrade"
            | "host"
            | "content-length"
    )
}

/// Build a small status-only error response without panicking.
fn error_response(status: axum::http::StatusCode, msg: &str) -> axum::response::Response {
    use axum::response::IntoResponse;
    (status, msg.to_string()).into_response()
}

/// Forward one request to `upstream`, STRIPPING the `/_sky/console` prefix from
/// the path (strip convention). Response body is streamed, so SSE
/// (`/_sky/console/_sky/sse`) passes through without buffering. No panic
/// vectors: every fallible step degrades to a 502/503, never `unwrap`.
///
/// Factored to take `client` + `upstream` explicitly (rather than reading the
/// `PROXY` static) so it is unit-testable against a throwaway upstream without
/// touching global state.
async fn forward(
    client: &reqwest::Client,
    upstream: &str,
    req: axum::extract::Request,
) -> axum::response::Response {
    // Strip the mount prefix: `/_sky/console` → `/`, `/_sky/console/x` → `/x`.
    let path = req.uri().path();
    let rest = path.strip_prefix(CONSOLE_BASE).unwrap_or(path);
    let rest = if rest.is_empty() { "/" } else { rest };
    let query = req
        .uri()
        .query()
        .map(|q| format!("?{q}"))
        .unwrap_or_default();
    let url = format!("{upstream}{rest}{query}");

    let method = req.method().clone();
    let headers = req.headers().clone();
    let body_bytes = match axum::body::to_bytes(req.into_body(), MAX_PROXY_BODY).await {
        Ok(b) => b,
        Err(_) => {
            return error_response(
                axum::http::StatusCode::BAD_GATEWAY,
                "console proxy: request body read failed",
            )
        }
    };

    let mut rb = client.request(method, &url);
    for (name, value) in headers.iter() {
        if is_hop_by_hop(name) {
            continue;
        }
        rb = rb.header(name, value);
    }
    let upstream_resp = match rb.body(body_bytes.to_vec()).send().await {
        Ok(r) => r,
        Err(_) => {
            return error_response(
                axum::http::StatusCode::BAD_GATEWAY,
                "console proxy: upstream unreachable",
            )
        }
    };

    let status = upstream_resp.status();
    let resp_headers = upstream_resp.headers().clone();
    let stream = upstream_resp.bytes_stream();
    let body = axum::body::Body::from_stream(stream);

    let mut builder = axum::response::Response::builder().status(status);
    for (name, value) in resp_headers.iter() {
        if is_hop_by_hop(name) {
            continue;
        }
        builder = builder.header(name, value);
    }
    match builder.body(body) {
        Ok(r) => r,
        Err(_) => error_response(
            axum::http::StatusCode::BAD_GATEWAY,
            "console proxy: malformed upstream response",
        ),
    }
}

/// axum route handler: forward via the mounted `PROXY` state. 503 if the proxy
/// somehow isn't initialised (can't happen once mounted, but degrade rather
/// than panic).
async fn proxy_entry(req: axum::extract::Request) -> axum::response::Response {
    match PROXY.get() {
        Some(state) => forward(&state.client, &state.upstream, req).await,
        None => error_response(
            axum::http::StatusCode::SERVICE_UNAVAILABLE,
            "console proxy not initialised",
        ),
    }
}

/// Poll the child's TCP port until it accepts a connection or `timeout` elapses.
/// `true` = ready. Bounded so a child that never binds can't wedge boot.
async fn wait_ready(port: u16, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        if tokio::net::TcpStream::connect(("127.0.0.1", port)).await.is_ok() {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// Grab a free ephemeral loopback port by binding `:0` and reading the assigned
/// port. `None` if the OS won't hand one out. (Small TOCTOU window between drop
/// and the child's bind — same approach Go uses for sub-app ports.)
fn pick_free_port() -> Option<u16> {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").ok()?;
    let port = listener.local_addr().ok()?.port();
    drop(listener);
    Some(port)
}

/// Gate → pick port → spawn the pre-built console child → wait for readiness →
/// init the proxy state + shutdown hook. Returns `true` when the reverse proxy
/// is live (the caller mounts `proxy_routes` instead of the in-process console);
/// `false` on gate-closed / binary-absent / spawn-fail / readiness-timeout
/// (caller mounts the in-process console fallback — no side effects left behind).
///
/// Reads the parent's `SKY_CONSOLE_DB_PATH` (the telemetry spill D writes) and
/// wires it to the child's `SKY_CONSOLE_HUB_DB` so the dashboard renders what
/// the parent recorded. Decided BEFORE the router is built so both the proxy and
/// the in-process fallback sit under the same observability middleware.
pub async fn ensure_console_proxy() -> bool {
    if !gate_allows() {
        return false;
    }
    // Fast path for the common case (binary not pre-built yet): skip the
    // port-pick + spawn entirely and let the in-process console serve.
    if console_bin_path().is_none() {
        return false;
    }
    let hub_db = std::env::var("SKY_CONSOLE_DB_PATH").unwrap_or_default();
    let port = match pick_free_port() {
        Some(p) => p,
        None => return false,
    };
    if spawn_console(port, &hub_db).is_none() {
        // Binary absent (A1 hasn't run / different sky version) or spawn error.
        return false;
    }
    if !wait_ready(port, READY_TIMEOUT).await {
        eprintln!("[sky.console] child not ready within {READY_TIMEOUT:?}; falling back to in-process console");
        shutdown_console();
        return false;
    }
    if PROXY
        .set(ProxyState {
            client: reqwest::Client::new(),
            upstream: format!("http://127.0.0.1:{port}"),
        })
        .is_err()
    {
        // Already initialised once (shouldn't happen — one Live server per process).
        eprintln!("[sky.console] proxy already initialised; keeping the first mount");
    }
    install_shutdown_hook();
    eprintln!("[sky.console] reverse-proxy ready at {CONSOLE_BASE}/* → 127.0.0.1:{port}");
    true
}

/// Add the reverse-proxy routes (`/_sky/console` + `/_sky/console/*rest`) to a
/// router. Generic over the app state `S` because `proxy_entry` is state-free —
/// so this composes into the main `Router<LiveState<…>>` before `with_state`,
/// keeping the proxy under the same `track` middleware as every other route.
/// Call only when `ensure_console_proxy().await` returned `true`.
pub fn proxy_routes<S>(router: axum::Router<S>) -> axum::Router<S>
where
    S: Clone + Send + Sync + 'static,
{
    use axum::routing::any;
    router
        .route(CONSOLE_BASE, any(proxy_entry))
        .route(&format!("{CONSOLE_BASE}/*rest"), any(proxy_entry))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gate_skips_in_subapp_context() {
        std::env::set_var("SKY_LIVE_BASE_PATH", "/billing");
        assert!(!gate_allows());
        std::env::remove_var("SKY_LIVE_BASE_PATH");
    }

    #[test]
    fn gate_skips_on_explicit_off() {
        std::env::set_var("SKY_CONSOLE_EMBED", "off");
        assert!(!gate_allows());
        std::env::remove_var("SKY_CONSOLE_EMBED");
    }

    #[test]
    fn bin_path_none_when_absent() {
        std::env::set_var(CONSOLE_BIN_ENV, "/nonexistent/sky-console-xyz");
        assert!(console_bin_path().is_none());
        std::env::remove_var(CONSOLE_BIN_ENV);
    }

    #[test]
    fn spawn_returns_none_without_binary() {
        // No binary at the override path → None (caller falls back), no panic.
        std::env::set_var(CONSOLE_BIN_ENV, "/nonexistent/sky-console-xyz");
        assert!(spawn_console(9931, "").is_none());
        std::env::remove_var(CONSOLE_BIN_ENV);
    }

    #[test]
    fn shutdown_is_idempotent_noop_when_empty() {
        shutdown_console();
        shutdown_console();
    }

    #[test]
    fn pick_free_port_returns_a_port() {
        let p = pick_free_port();
        assert!(p.is_some());
        assert!(p.unwrap_or(0) > 0);
    }

    #[test]
    fn hop_by_hop_filters_connection_not_content_type() {
        use axum::http::header::{CONNECTION, CONTENT_TYPE};
        assert!(is_hop_by_hop(&CONNECTION));
        assert!(!is_hop_by_hop(&CONTENT_TYPE));
    }

    // Spin a throwaway upstream that echoes "METHOD PATH BODY", forward a
    // parent-shaped request through `forward`, and assert the /_sky/console
    // prefix is stripped while method + body + query round-trip.
    #[tokio::test]
    async fn forward_strips_prefix_and_round_trips() {
        use axum::{routing::any, Router};

        async fn echo(req: axum::extract::Request) -> String {
            let method = req.method().clone();
            let uri = req.uri().clone();
            let body = axum::body::to_bytes(req.into_body(), 1 << 20)
                .await
                .unwrap_or_default();
            format!(
                "{method} {}{} {}",
                uri.path(),
                uri.query().map(|q| format!("?{q}")).unwrap_or_default(),
                String::from_utf8_lossy(&body)
            )
        }

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind upstream");
        let port = listener.local_addr().expect("addr").port();
        let app = Router::new().fallback(any(echo));
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        // The parent receives POST /_sky/console/_sky/event?x=1 with body "hi".
        let req = axum::http::Request::builder()
            .method("POST")
            .uri("/_sky/console/_sky/event?x=1")
            .body(axum::body::Body::from("hi"))
            .expect("build req");

        let client = reqwest::Client::new();
        let upstream = format!("http://127.0.0.1:{port}");
        let resp = forward(&client, &upstream, req).await;
        assert_eq!(resp.status(), axum::http::StatusCode::OK);

        let bytes = axum::body::to_bytes(resp.into_body(), 1 << 20)
            .await
            .expect("read resp body");
        let text = String::from_utf8_lossy(&bytes);
        // Prefix stripped → child sees /_sky/event; method, query, body preserved.
        assert_eq!(text, "POST /_sky/event?x=1 hi", "got: {text}");
    }

    // The bare mount path `/_sky/console` (no trailing slash) maps to the
    // child's root `/`.
    #[tokio::test]
    async fn forward_bare_base_maps_to_root() {
        use axum::{routing::any, Router};

        async fn echo_path(req: axum::extract::Request) -> String {
            req.uri().path().to_string()
        }

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind upstream");
        let port = listener.local_addr().expect("addr").port();
        let app = Router::new().fallback(any(echo_path));
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        let req = axum::http::Request::builder()
            .method("GET")
            .uri("/_sky/console")
            .body(axum::body::Body::empty())
            .expect("build req");

        let client = reqwest::Client::new();
        let upstream = format!("http://127.0.0.1:{port}");
        let resp = forward(&client, &upstream, req).await;
        let bytes = axum::body::to_bytes(resp.into_body(), 1 << 20)
            .await
            .expect("read resp body");
        assert_eq!(String::from_utf8_lossy(&bytes), "/");
    }
}
