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
    let body = format!(
        "# HELP sky_live_requests_total Total HTTP requests served by the Sky.Live app.\n\
         # TYPE sky_live_requests_total counter\n\
         sky_live_requests_total {n}\n"
    );
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "text/plain; version=0.0.4")],
        body,
    )
}

/// axum middleware: increment the request counter for every served request, then
/// pass through. Excludes nothing — `/_sky/metrics` self-counts, matching Go's
/// access-log middleware which wraps the whole mux.
pub async fn track(req: axum::extract::Request, next: axum::middleware::Next) -> axum::response::Response {
    REQUESTS.fetch_add(1, Ordering::Relaxed);
    let resp = next.run(req).await;
    // Feed the Sky Console telemetry (request count + 5xx error count).
    super::super::telemetry::record_request(resp.status().as_u16());
    resp
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
