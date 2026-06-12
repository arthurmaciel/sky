//! Sky Console — the operator dashboard mounted at `/_sky/console`, plus the
//! observability federation receiver. Mirrors Go's `console*.go` in-RAM tier:
//! a plain-HTML shell that polls JSON `/_sky/console/api/*` endpoints backed by
//! the `telemetry` ring buffers, and a `/_sky/observability/ingest` POST that
//! folds a sub-app's batched logs into the same rings.
//!
//! Unlike Go (which spawns the console as a child Sky.Live process and reverse-
//! proxies it), the Rust console is served in-process directly off the Live
//! router — no extra process, same data. No panic vectors.

use crate::sky_runtime::telemetry;
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;

const fn json_ct() -> (header::HeaderName, &'static str) {
    (header::CONTENT_TYPE, "application/json")
}

/// `GET /_sky/console` — the plain-HTML dashboard shell (no framework, no CSS
/// deps). Polls the api endpoints below.
pub async fn console_html() -> impl IntoResponse {
    let body = r#"<!doctype html><html><head><meta charset="utf-8">
<title>Sky Console</title>
<style>
 body{font-family:ui-monospace,monospace;background:#12141c;color:#dfe3ee;margin:0;padding:16px}
 h1{font-size:16px;color:#8ec8a8} .tab{cursor:pointer;padding:4px 10px;margin-right:6px;border:1px solid #2a2f40;border-radius:4px;display:inline-block}
 .tab.on{background:#2a2f40} pre{background:#0c0e14;padding:10px;border-radius:4px;overflow:auto;max-height:70vh}
 .err{color:#e88} .lvl{color:#7a86a8}
</style></head><body>
<h1>Sky Console</h1>
<div id="ov"></div>
<div><span class="tab on" data-t="logs">Logs</span><span class="tab" data-t="errors">Errors</span></div>
<pre id="out">loading…</pre>
<script>
 let tab="logs";
 async function j(u){try{const r=await fetch(u);return await r.json()}catch(e){return null}}
 async function ov(){const o=await j("/_sky/console/api/overview");if(o)document.getElementById("ov").textContent=
   "requests="+o.requests+"  errors="+o.errors;}
 function fmt(es){return (es||[]).map(e=>{const d=new Date(e.ts).toISOString().slice(11,19);
   return "<span class='lvl'>"+d+" "+e.level+"</span> "+(e.level=="error"?"<span class='err'>":"")+
   e.message.replace(/&/g,"&amp;").replace(/</g,"&lt;")+(e.level=="error"?"</span>":"");}).join("\n");}
 async function refresh(){const es=await j("/_sky/console/api/"+tab);
   document.getElementById("out").innerHTML=fmt(es);ov();}
 document.querySelectorAll(".tab").forEach(t=>t.onclick=()=>{
   document.querySelectorAll(".tab").forEach(x=>x.classList.remove("on"));t.classList.add("on");
   tab=t.dataset.t;refresh();});
 refresh();setInterval(refresh,2000);
</script></body></html>"#;
    (StatusCode::OK, [(header::CONTENT_TYPE, "text/html; charset=utf-8")], body)
}

/// `GET /_sky/console/api/overview` — request + error counters.
pub async fn api_overview() -> impl IntoResponse {
    let body = format!(
        r#"{{"requests":{},"errors":{}}}"#,
        telemetry::requests_total(),
        telemetry::errors_total()
    );
    (StatusCode::OK, [json_ct()], body)
}

/// `GET /_sky/console/api/logs` — recent log ring (most recent 200).
pub async fn api_logs() -> impl IntoResponse {
    (StatusCode::OK, [json_ct()], telemetry::entries_json(&telemetry::recent_logs(200)))
}

/// `GET /_sky/console/api/errors` — recent error ring.
pub async fn api_errors() -> impl IntoResponse {
    (StatusCode::OK, [json_ct()], telemetry::entries_json(&telemetry::recent_errors(200)))
}

/// `GET /_sky/console/api/traces` — recent completed `Std.Trace.span`s.
pub async fn api_traces() -> impl IntoResponse {
    (StatusCode::OK, [json_ct()], telemetry::spans_json(200))
}

/// `GET /_sky/console/api/metrics-summary` — the parsed counter snapshot the
/// dashboard renders (mirror of Go's parsed Prometheus summary).
pub async fn api_metrics_summary() -> impl IntoResponse {
    let body = format!(
        r#"{{"sky_live_requests_total":{},"sky_live_errors_total":{}}}"#,
        telemetry::requests_total(),
        telemetry::errors_total()
    );
    (StatusCode::OK, [json_ct()], body)
}

/// Production auth gate for the console + metrics surface (Go's
/// `productionFromEnv` + `SKY_CONSOLE_AUTH`). Returns `Some(response)` when the
/// request must be REFUSED. `SKY_CONSOLE_AUTH=off` → 404 (surface declared absent).
/// In production (ENV/SKY_ENV non-dev) a `Bearer` admin token is required
/// (`SKY_ADMIN_TOKEN`, legacy `SKY_CONSOLE_TOKEN`) — 401 otherwise. Dev mode (the
/// default) is open and returns `None`.
pub fn gate_blocked(headers: &axum::http::HeaderMap) -> Option<axum::response::Response> {
    if std::env::var("SKY_CONSOLE_AUTH").map(|v| v == "off").unwrap_or(false) {
        return Some((StatusCode::NOT_FOUND, "console disabled").into_response());
    }
    if !telemetry::production_from_env() {
        return None;
    }
    let want = std::env::var("SKY_ADMIN_TOKEN")
        .ok()
        .or_else(|| std::env::var("SKY_CONSOLE_TOKEN").ok());
    let authed = match (want, headers.get(header::AUTHORIZATION)) {
        (Some(tok), Some(h)) if !tok.is_empty() => {
            h.to_str().map(|h| h == format!("Bearer {tok}")).unwrap_or(false)
        }
        _ => false,
    };
    if authed {
        None
    } else {
        Some(
            (StatusCode::UNAUTHORIZED, "console requires a Bearer admin token in production")
                .into_response(),
        )
    }
}

/// `POST /_sky/observability/ingest` — federation receiver. Accepts a JSON array
/// of `{ "level": "...", "message": "..." }` (a sub-app's batched logs) and folds
/// them into the local rings. Malformed bodies are accepted as 204 (drop) rather
/// than erroring — telemetry must never break the caller.
pub async fn ingest(body: String) -> impl IntoResponse {
    if let Ok(serde_json::Value::Array(items)) = serde_json::from_str::<serde_json::Value>(&body) {
        for it in items {
            let level = it.get("level").and_then(|v| v.as_str()).unwrap_or("info");
            let message = it.get("message").and_then(|v| v.as_str()).unwrap_or("");
            if !message.is_empty() {
                telemetry::record_log(level, message);
            }
        }
    }
    StatusCode::NO_CONTENT
}
