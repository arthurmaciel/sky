//! Remote hub OTLP push — HubExporter (epic E, #70).
//!
//! When `SKY_CONSOLE_HUB` is set, this background exporter batches logs + spans
//! and pushes them as OTLP/JSON to a remote `sky console-serve` hub
//! (`/v1/logs`, `/v1/traces`), bearer-authenticated via `SKY_CONSOLE_HUB_TOKEN`,
//! with a durable spool (memory / file) + retry so a transient hub outage never
//! drops telemetry. Mirrors Go's `exporter.go` + `exporter_spool.go`.
//!
//! Go parity: OTLP supports a JSON encoding over HTTP (Content-Type
//! application/json) — Go's HubExporter uses exactly that, so the Rust exporter
//! needs no protobuf dep.
//!
//! `live`-gated. Best-effort, no panic vectors: bounded queue (drop on full),
//! push failures fall back to the spool + retry, never block/panic the caller.

#![allow(dead_code)] // surface fleshed out across the E sub-tasks

use std::sync::OnceLock;
use tokio::sync::mpsc;

/// One telemetry record queued for the exporter.
pub(crate) enum Entry {
    Log { ts_ms: u64, level: String, message: String },
    Span { ts_ms: u64, name: String, dur_us: u64, ok: bool },
}

static SENDER: OnceLock<mpsc::Sender<Entry>> = OnceLock::new();

/// Env var that turns the hub exporter on.
const HUB_ENV: &str = "SKY_CONSOLE_HUB";

/// Enable the remote-hub OTLP exporter from env. No-op unless `SKY_CONSOLE_HUB`
/// is set. Idempotent; call once at Live boot. (Batcher + spool + retry wiring
/// lands in the E sub-tasks; this gate keeps it inert until then.)
pub async fn enable_from_env() {
    let _hub = match std::env::var(HUB_ENV) {
        Ok(h) if !h.is_empty() => h,
        _ => return,
    };
    // Full pipeline (OTLP/JSON batcher + memory/file spool + retry) wired below
    // in epic E; until then the gate is a no-op so SKY_CONSOLE_HUB doesn't
    // silently appear to work.
}

/// Non-blocking offer of a log. No-op when the exporter is disabled or the queue
/// is full (drop — never block/panic the caller).
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

/// Register the exporter's sender (used by `enable_from_env`). Exposed so the
/// batcher wiring lands incrementally in the E sub-tasks.
pub(crate) fn install_sender(tx: mpsc::Sender<Entry>) -> bool {
    SENDER.set(tx).is_ok()
}

pub(crate) fn is_enabled() -> bool {
    SENDER.get().is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offer_without_enable_is_noop() {
        offer_log(0, "info", "ignored");
        offer_span(0, "noop", 0, true);
    }
}
