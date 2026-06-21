//! Sky.Live observability endpoints — the operator surface mounted on every
//! Live app, mirroring Go's `runtime-go/rt/observability.go`:
//!
//! - `GET /_sky/healthz`  — liveness probe, always `{"status":"ok"}`.
//! - `GET /_sky/readyz`   — readiness probe, `{"status":"ready"}` (200) or
//!   `{"status":"draining"}` (503) once shutdown is signalled.
//! - `GET /_sky/buildinfo`— commit / builtAt / skyVersion JSON.
//! - `GET /_sky/metrics`  — Prometheus text: `sky_live_requests_total`.
//!
//! Requests are counted by the `track` middleware layer. No panic vectors: every
//! handler returns a static or counter-derived body; nothing can fail.
//!
//! Out of scope here (staged for the console mini-app port): `/_sky/console/*`
//! (the Std.Ui dashboard), `/_sky/observability/ingest` (sub-app federation), and
//! the in-RAM log/span ring buffers the console renders.

use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

/// Process-global request counter, surfaced by `/_sky/metrics`.
static REQUESTS: AtomicU64 = AtomicU64::new(0);

/// Readiness flag. Starts ready; a graceful-shutdown signal flips it so
/// `/_sky/readyz` reports `draining` and load balancers stop routing new traffic
/// while in-flight requests finish (Go parity: `readinessReady`).
static READY: AtomicBool = AtomicBool::new(true);

/// Flip readiness to draining (call from a shutdown handler). Idempotent.
pub fn mark_draining() {
    READY.store(false, Ordering::SeqCst);
}

const JSON: (header::HeaderName, &str) = (header::CONTENT_TYPE, "application/json");

/// `GET /_sky/healthz` — liveness. Always OK while the process is up.
pub async fn healthz() -> impl IntoResponse {
    (StatusCode::OK, [JSON], r#"{"status":"ok"}"#)
}

/// `GET /_sky/readyz` — readiness. 200 `ready`, or 503 `draining` once shutdown
/// is signalled.
pub async fn readyz() -> impl IntoResponse {
    if READY.load(Ordering::SeqCst) {
        (StatusCode::OK, [JSON], r#"{"status":"ready"}"#)
    } else {
        (StatusCode::SERVICE_UNAVAILABLE, [JSON], r#"{"status":"draining"}"#)
    }
}

/// `GET /_sky/buildinfo` — build provenance. Values come from compile-time env
/// (`SKY_BUILD_COMMIT` / `SKY_BUILD_AT` / `SKY_VERSION`), defaulting to `dev`.
pub async fn buildinfo() -> impl IntoResponse {
    let commit = option_env!("SKY_BUILD_COMMIT").unwrap_or("dev");
    let built_at = option_env!("SKY_BUILD_AT").unwrap_or("unknown");
    let version = option_env!("SKY_VERSION").unwrap_or("dev");
    let body = format!(
        r#"{{"commit":"{commit}","builtAt":"{built_at}","skyVersion":"{version}"}}"#
    );
    (StatusCode::OK, [JSON], body)
}

/// `GET /_sky/metrics` — Prometheus text exposition of the request counter.
pub async fn metrics() -> impl IntoResponse {
    let n = REQUESTS.load(Ordering::Relaxed);
    let mut body = format!(
        "# HELP sky_live_requests_total Total HTTP requests served by the Sky.Live app.\n\
         # TYPE sky_live_requests_total counter\n\
         sky_live_requests_total {n}\n"
    );
    // Append the labeled registry — active sessions, SSE connections, 5xx errors
    // — so /_sky/metrics is a real Prometheus exposition, not a single counter
    // (Go parity with prometheus.go's full WriteProm). `sky_live_requests_total`
    // stays the unlabeled grand-total line above; the registry never registers
    // that name, so there's no duplicate HELP/TYPE.
    body.push_str(&crate::sky_runtime::telemetry::write_prom());
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "text/plain; version=0.0.4")],
        body,
    )
}

/// axum middleware: per-request observability (Go parity — its access-log +
/// OTel-span middleware wraps the whole mux). Counts every request, and for
/// user-facing requests auto-records a span + an access log so the console has
/// data without the app calling `Std.Trace`/`Std.Log` itself.
pub async fn track(req: axum::extract::Request, next: axum::middleware::Next) -> axum::response::Response {
    REQUESTS.fetch_add(1, Ordering::Relaxed);
    // Gate the console + metrics surface (off / production-auth) before serving.
    let path = req.uri().path().to_string();
    let method = req.method().as_str().to_string();
    if path == "/_sky/metrics" || path.starts_with("/_sky/console") {
        if let Some(blocked) = super::console::gate_blocked(req.headers()) {
            super::super::telemetry::record_request(blocked.status().as_u16());
            return blocked;
        }
    }
    let start = std::time::Instant::now();
    let resp = next.run(req).await;
    let status = resp.status().as_u16();
    // Feed the Sky Console telemetry (request count + 5xx error count).
    super::super::telemetry::record_request(status);
    // Auto request span + access log — but NOT for the internal observability
    // surface (SSE long-poll → multi-minute span; console proxy / metrics /
    // health → console's own polling noise) and NOT for a sub-app. A sub-app
    // (`SKY_LIVE_BASE_PATH` set — e.g. the console child collector) must not
    // self-instrument into the store it serves; it shows the PARENT's pushed
    // telemetry, not its own page renders.
    if !is_internal_path(&path) && !is_sub_app() {
        let dur_us = start.elapsed().as_micros().min(u64::MAX as u128) as u64;
        // Request-latency histogram (Go parity: Observe sky_live_request_seconds).
        // UNLABELED on purpose — labeling by the raw path would be an unbounded-
        // cardinality memory-DoS (the registry never evicts); Go labels by a
        // bounded route template, which the Rust middleware doesn't have here.
        super::super::telemetry::metric_observe(
            "sky_live_request_seconds",
            &[],
            dur_us as f64 / 1_000_000.0,
        );
        let ok = status < 500;
        // Bound + sanitise the (attacker-controllable) raw path before it enters
        // the in-RAM log ring / OTLP push: cap the length and strip control bytes
        // so a `/<huge-or-control-char path>` can't inject ANSI/control sequences
        // into the operator console or amplify per-entry memory.
        let safe_path = sanitise_path(&path);
        super::super::telemetry::record_span(&format!("{method} {safe_path}"), dur_us, ok);
        let level = if status >= 500 { "error" } else { "info" };
        super::super::telemetry::record_log(
            level,
            &format!("{method} {safe_path} -> {status} ({}ms)", dur_us / 1000),
        );
    }
    resp
}

/// Cap the request path to a sane length and strip control characters before it
/// is recorded into the telemetry rings / federation push. Mirrors the Sky.Tui
/// `sanitiseRune` discipline — the path is user-supplied and otherwise
/// unbounded, a low-grade log-injection / memory-amplification vector.
fn sanitise_path(path: &str) -> String {
    const MAX_PATH_BYTES: usize = 256;
    let mut out = String::with_capacity(path.len().min(MAX_PATH_BYTES));
    for ch in path.chars() {
        // Drop ASCII/Unicode control chars (incl. ESC for ANSI, NUL, newlines).
        if ch.is_control() {
            continue;
        }
        if out.len() + ch.len_utf8() > MAX_PATH_BYTES {
            out.push('…');
            break;
        }
        out.push(ch);
    }
    out
}

/// Internal observability/transport paths that must NOT be auto-instrumented:
/// the SSE long-poll (a multi-minute span), the console reverse-proxy + its
/// events (the console's own traffic), and the health/metrics/build/ingest
/// endpoints (operator polling noise).
/// True when this process runs as a sub-app (mounted behind a parent's proxy,
/// `SKY_LIVE_BASE_PATH` non-empty) — e.g. the bundled console child.
fn is_sub_app() -> bool {
    std::env::var("SKY_LIVE_BASE_PATH").map(|v| !v.is_empty()).unwrap_or(false)
}

fn is_internal_path(path: &str) -> bool {
    path == "/_sky/sse"
        || path == "/_sky/event"
        || path == "/_sky/metrics"
        || path == "/_sky/healthz"
        || path == "/_sky/readyz"
        || path == "/_sky/buildinfo"
        || path == "/_sky/observability/ingest"
        || path.starts_with("/_sky/console")
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::to_bytes;
    use axum::response::IntoResponse;

    async fn body_string(r: axum::response::Response) -> String {
        let bytes = to_bytes(r.into_body(), 64 * 1024).await.unwrap_or_default();
        String::from_utf8_lossy(&bytes).into_owned()
    }

    #[test]
    fn internal_paths_are_not_auto_instrumented() {
        // SSE long-poll, event transport, console proxy, ops endpoints → skipped.
        assert!(super::is_internal_path("/_sky/sse"));
        assert!(super::is_internal_path("/_sky/event"));
        assert!(super::is_internal_path("/_sky/console"));
        assert!(super::is_internal_path("/_sky/console/_sky/sse"));
        assert!(super::is_internal_path("/_sky/healthz"));
        // User-facing routes → instrumented.
        assert!(!super::is_internal_path("/"));
        assert!(!super::is_internal_path("/api/users"));
        assert!(!super::is_internal_path("/dashboard"));
    }

    #[tokio::test]
    async fn healthz_ok() {
        let r = healthz().await.into_response();
        assert_eq!(r.status(), StatusCode::OK);
        assert_eq!(body_string(r).await, r#"{"status":"ok"}"#);
    }

    #[tokio::test]
    async fn buildinfo_is_json_with_fields() {
        let r = buildinfo().await.into_response();
        assert_eq!(r.status(), StatusCode::OK);
        let b = body_string(r).await;
        assert!(b.contains("\"commit\""), "{b}");
        assert!(b.contains("\"skyVersion\""), "{b}");
    }

    #[tokio::test]
    async fn metrics_exposes_counter() {
        let r = metrics().await.into_response();
        assert_eq!(r.status(), StatusCode::OK);
        assert!(body_string(r).await.contains("sky_live_requests_total"));
    }

    #[tokio::test]
    async fn readyz_flips_to_draining() {
        // Default ready.
        let r = readyz().await.into_response();
        assert_eq!(r.status(), StatusCode::OK);
        mark_draining();
        let r2 = readyz().await.into_response();
        assert_eq!(r2.status(), StatusCode::SERVICE_UNAVAILABLE);
        assert!(body_string(r2).await.contains("draining"));
        // Restore for any other test ordering (process-global flag).
        READY.store(true, Ordering::SeqCst);
    }
}
