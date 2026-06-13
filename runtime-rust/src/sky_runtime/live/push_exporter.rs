//! Observability federation — child→parent telemetry push (epic C).
//!
//! When a Rust Live app runs as a sub-app under a parent (`SKY_PARENT_URL` set),
//! this background exporter batches its logs + spans and POSTs them every
//! `SKY_OBSERVABILITY_PUSH_INTERVAL_MS` (default 2000) to the parent's
//! `/_sky/observability/ingest` — the symmetric counterpart to the receiver in
//! `live/console.rs`. Mirrors Go's `observability_push.go` (PushExporter).
//!
//! `live`-gated (uses reqwest). Best-effort end to end: a bounded queue drops on
//! overflow, POST failures warn + drop. The observability path must never block
//! or panic the request path. No `unwrap`/`expect`/indexing in any reachable
//! path.

use std::sync::OnceLock;
use std::time::Duration;
use tokio::sync::mpsc;

/// Parent base URL — presence of this var means "I'm a sub-app, push upward".
const PARENT_ENV: &str = "SKY_PARENT_URL";
/// Flush cadence (ms).
const INTERVAL_ENV: &str = "SKY_OBSERVABILITY_PUSH_INTERVAL_MS";
/// Bounded queue depth override.
const BUFFER_ENV: &str = "SKY_OBSERVABILITY_BUFFER";
/// Shared secret the parent's ingest gate checks (`X-Sky-Ingest-Token`).
const TOKEN_ENV: &str = "SKY_INGEST_TOKEN";

const DEFAULT_QUEUE_CAP: usize = 1024;
const DEFAULT_INTERVAL_MS: u64 = 2000;
/// Floor on the flush interval so a typo can't spin a hot loop.
const MIN_INTERVAL_MS: u64 = 100;

/// One telemetry record queued for the exporter.
enum Entry {
    Log { ts_ms: u64, level: String, message: String },
    Span { ts_ms: u64, name: String, dur_us: u64, ok: bool },
}

static SENDER: OnceLock<mpsc::Sender<Entry>> = OnceLock::new();

/// Enable the push exporter from env. No-op unless `SKY_PARENT_URL` is set
/// (i.e. this process runs as a sub-app). Idempotent. Call once at Live boot.
pub async fn enable_from_env() {
    let parent = match std::env::var(PARENT_ENV) {
        Ok(p) if !p.is_empty() => p,
        _ => return,
    };
    if SENDER.get().is_some() {
        return;
    }
    let interval_ms = std::env::var(INTERVAL_ENV)
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(DEFAULT_INTERVAL_MS)
        .max(MIN_INTERVAL_MS);
    let cap = std::env::var(BUFFER_ENV)
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .filter(|&c| c > 0)
        .unwrap_or(DEFAULT_QUEUE_CAP);
    let token = std::env::var(TOKEN_ENV).ok().filter(|t| !t.is_empty());
    let ingest_url = format!("{}/_sky/observability/ingest", parent.trim_end_matches('/'));

    let (tx, rx) = mpsc::channel::<Entry>(cap);
    if SENDER.set(tx).is_err() {
        return; // lost an enable race
    }
    eprintln!("[sky.push] federation push → {ingest_url} every {interval_ms}ms");
    tokio::spawn(batcher(rx, ingest_url, token, interval_ms));
}

/// Accumulate entries and flush a batch on each tick. Channel close drains a
/// final batch then exits.
async fn batcher(
    mut rx: mpsc::Receiver<Entry>,
    ingest_url: String,
    token: Option<String>,
    interval_ms: u64,
) {
    let client = reqwest::Client::new();
    let mut buf: Vec<Entry> = Vec::new();
    let mut tick = tokio::time::interval(Duration::from_millis(interval_ms));
    // The first tick fires immediately; skip it so we don't flush an empty batch.
    tick.tick().await;
    loop {
        tokio::select! {
            maybe = rx.recv() => match maybe {
                Some(e) => buf.push(e),
                None => {
                    if !buf.is_empty() {
                        flush(&client, &ingest_url, token.as_deref(), &buf).await;
                    }
                    break;
                }
            },
            _ = tick.tick() => {
                if !buf.is_empty() {
                    flush(&client, &ingest_url, token.as_deref(), &buf).await;
                    buf.clear();
                }
            }
        }
    }
}

/// Build the `{ "logs": [...], "spans": [...] }` payload the receiver accepts.
/// serde_json (a `live` dep) keeps the escaping correct.
fn build_payload(buf: &[Entry]) -> String {
    let mut logs = Vec::new();
    let mut spans = Vec::new();
    for e in buf {
        match e {
            Entry::Log { ts_ms, level, message } => logs.push(serde_json::json!({
                "ts": ts_ms, "level": level, "message": message,
            })),
            Entry::Span { ts_ms, name, dur_us, ok } => spans.push(serde_json::json!({
                "ts": ts_ms, "name": name, "durUs": dur_us, "ok": ok,
            })),
        }
    }
    serde_json::json!({ "logs": logs, "spans": spans }).to_string()
}

/// POST one batch to the parent ingest. Failures warn + drop (best-effort).
async fn flush(client: &reqwest::Client, ingest_url: &str, token: Option<&str>, buf: &[Entry]) {
    let body = build_payload(buf);
    let mut req = client
        .post(ingest_url)
        .header("content-type", "application/json")
        .body(body);
    if let Some(t) = token {
        req = req.header("x-sky-ingest-token", t);
    }
    if let Err(e) = req.send().await {
        eprintln!("[sky.push] flush to {ingest_url}: {e}");
    }
}

/// Non-blocking offer of a log. No-op when disabled or the queue is full.
pub fn offer_log(ts_ms: u64, level: &str, message: &str) {
    if let Some(tx) = SENDER.get() {
        let _ = tx.try_send(Entry::Log {
            ts_ms,
            level: level.to_string(),
            message: message.to_string(),
        });
    }
}

/// Non-blocking offer of a span.
pub fn offer_span(ts_ms: u64, name: &str, dur_us: u64, ok: bool) {
    if let Some(tx) = SENDER.get() {
        let _ = tx.try_send(Entry::Span {
            ts_ms,
            name: name.to_string(),
            dur_us,
            ok,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offer_without_enable_is_noop() {
        offer_log(0, "info", "ignored");
        offer_span(0, "noop", 0, true);
    }

    #[test]
    fn payload_shape_logs_and_spans() {
        let buf = vec![
            Entry::Log { ts_ms: 1700, level: "error".into(), message: "boom \"x\"".into() },
            Entry::Span { ts_ms: 1700, name: "db.query".into(), dur_us: 5000, ok: true },
        ];
        let body = build_payload(&buf);
        let v: serde_json::Value = serde_json::from_str(&body).expect("valid json");
        assert_eq!(v["logs"][0]["level"], "error");
        assert_eq!(v["logs"][0]["message"], "boom \"x\"");
        assert_eq!(v["spans"][0]["name"], "db.query");
        assert_eq!(v["spans"][0]["ok"], true);
        assert_eq!(v["spans"][0]["durUs"], 5000);
    }
}
