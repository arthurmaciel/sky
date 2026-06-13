//! In-process telemetry sink — the data the Sky Console renders.
//!
//! Always compiled (so `Std.Log.*` can feed it regardless of features); the
//! Sky.Live `console` module exposes it over HTTP. Bounded ring buffers (logs +
//! errors) plus monotonic request/error counters. Mirrors the in-RAM tier of
//! Go's console (`runtime-go/rt/console*.go`), minus the SQLite spill.
//!
//! No panic vectors: a poisoned lock recovers via `into_inner()` (the data is
//! plain records — a panic mid-push can't corrupt invariants); all reads/writes
//! are bounded.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

const LOG_CAP: usize = 1000;
const ERR_CAP: usize = 200;
const SPAN_CAP: usize = 500;

/// One captured log line.
#[derive(Clone)]
pub struct LogEntry {
    pub ts_ms: u64,
    pub level: String,
    pub message: String,
}

/// One completed trace span (Std.Trace.span).
#[derive(Clone)]
pub struct SpanEntry {
    pub ts_ms: u64,
    pub name: String,
    pub dur_us: u64,
    pub ok: bool,
}

static LOGS: Mutex<VecDeque<LogEntry>> = Mutex::new(VecDeque::new());
static ERRORS: Mutex<VecDeque<LogEntry>> = Mutex::new(VecDeque::new());
static SPANS: Mutex<VecDeque<SpanEntry>> = Mutex::new(VecDeque::new());
static REQUESTS_TOTAL: AtomicU64 = AtomicU64::new(0);
static ERRORS_TOTAL: AtomicU64 = AtomicU64::new(0);

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn push_bounded<T>(ring: &Mutex<VecDeque<T>>, cap: usize, e: T) {
    let mut g = ring.lock().unwrap_or_else(|p| p.into_inner());
    if g.len() >= cap {
        g.pop_front();
    }
    g.push_back(e);
}

/// Forward a record to the SQLite spill (#69 / epic D) when enabled. A no-op
/// stub keeps this always-compiled sink tokio/sqlx-free when `db` is off.
#[cfg(feature = "db")]
#[inline]
fn spill_log(ts_ms: u64, level: &str, message: &str) {
    crate::sky_runtime::telemetry_spill::offer_log(ts_ms, level, message);
}
#[cfg(not(feature = "db"))]
#[inline]
fn spill_log(_ts_ms: u64, _level: &str, _message: &str) {}

#[cfg(feature = "db")]
#[inline]
fn spill_span(ts_ms: u64, name: &str, dur_us: u64, ok: bool) {
    crate::sky_runtime::telemetry_spill::offer_span(ts_ms, name, dur_us, ok);
}
#[cfg(not(feature = "db"))]
#[inline]
fn spill_span(_ts_ms: u64, _name: &str, _dur_us: u64, _ok: bool) {}

/// Forward a record to the remote exporters — federation push to the parent
/// ingest (epic C) and the remote hub OTLP push (epic E). `live`-gated; a no-op
/// stub keeps the always-compiled sink reqwest/tokio-free for non-live programs.
/// Each exporter is independently env-gated and a non-blocking drop-on-full
/// offer, so this never blocks or panics the caller.
#[cfg(feature = "live")]
#[inline]
fn export_log(ts_ms: u64, level: &str, message: &str) {
    crate::sky_runtime::live::push_exporter::offer_log(ts_ms, level, message);
    crate::sky_runtime::live::hub_exporter::offer_log(ts_ms, level, message);
}
#[cfg(not(feature = "live"))]
#[inline]
fn export_log(_ts_ms: u64, _level: &str, _message: &str) {}

#[cfg(feature = "live")]
#[inline]
fn export_span(ts_ms: u64, name: &str, dur_us: u64, ok: bool) {
    crate::sky_runtime::live::push_exporter::offer_span(ts_ms, name, dur_us, ok);
    crate::sky_runtime::live::hub_exporter::offer_span(ts_ms, name, dur_us, ok);
}
#[cfg(not(feature = "live"))]
#[inline]
fn export_span(_ts_ms: u64, _name: &str, _dur_us: u64, _ok: bool) {}
// NOTE: hub_exporter (epic E) is wired above; its module lands with E.

/// Record a completed trace span (called from `Std.Trace.span`).
pub fn record_span(name: &str, dur_us: u64, ok: bool) {
    let ts = now_ms();
    push_bounded(
        &SPANS,
        SPAN_CAP,
        SpanEntry { ts_ms: ts, name: name.to_string(), dur_us, ok },
    );
    spill_span(ts, name, dur_us, ok);
    export_span(ts, name, dur_us, ok);
}

/// Most-recent `limit` spans as a JSON array.
pub fn spans_json(limit: usize) -> String {
    let g = SPANS.lock().unwrap_or_else(|p| p.into_inner());
    let n = g.len();
    let items: Vec<String> = g
        .iter()
        .skip(n.saturating_sub(limit))
        .map(|s| {
            format!(
                r#"{{"ts":{},"name":"{}","durUs":{},"ok":{}}}"#,
                s.ts_ms,
                json_escape(&s.name),
                s.dur_us,
                s.ok
            )
        })
        .collect();
    format!("[{}]", items.join(","))
}

/// Production gate (Go's `productionFromEnv`): `ENV` then `SKY_ENV`; unset OR a
/// dev marker (`dev`/`development`/`local`) → dev (false); anything else → true.
pub fn production_from_env() -> bool {
    let mut e = std::env::var("ENV").unwrap_or_default().to_ascii_lowercase();
    if e.is_empty() {
        e = std::env::var("SKY_ENV").unwrap_or_default().to_ascii_lowercase();
    }
    if e.is_empty() {
        return false;
    }
    !matches!(e.as_str(), "dev" | "development" | "local")
}

/// Record a structured log line (called from `Std.Log.*`). Errors also land in
/// the error ring + bump the error counter.
pub fn record_log(level: &str, message: &str) {
    let ts = now_ms();
    let e = LogEntry { ts_ms: ts, level: level.to_string(), message: message.to_string() };
    if level.eq_ignore_ascii_case("error") {
        ERRORS_TOTAL.fetch_add(1, Ordering::Relaxed);
        push_bounded(&ERRORS, ERR_CAP, e.clone());
    }
    push_bounded(&LOGS, LOG_CAP, e);
    spill_log(ts, level, message);
    export_log(ts, level, message);
}

/// Record one served HTTP request (called from the Live counter middleware).
pub fn record_request(status: u16) {
    REQUESTS_TOTAL.fetch_add(1, Ordering::Relaxed);
    if status >= 500 {
        ERRORS_TOTAL.fetch_add(1, Ordering::Relaxed);
    }
}

pub fn requests_total() -> u64 {
    REQUESTS_TOTAL.load(Ordering::Relaxed)
}
pub fn errors_total() -> u64 {
    ERRORS_TOTAL.load(Ordering::Relaxed)
}

/// Most-recent `limit` log entries, oldest→newest.
pub fn recent_logs(limit: usize) -> Vec<LogEntry> {
    let g = LOGS.lock().unwrap_or_else(|p| p.into_inner());
    let n = g.len();
    g.iter().skip(n.saturating_sub(limit)).cloned().collect()
}

/// Most-recent `limit` error entries, oldest→newest.
pub fn recent_errors(limit: usize) -> Vec<LogEntry> {
    let g = ERRORS.lock().unwrap_or_else(|p| p.into_inner());
    let n = g.len();
    g.iter().skip(n.saturating_sub(limit)).cloned().collect()
}

/// Minimal JSON string escaping for hand-built console payloads (avoids coupling
/// the always-compiled sink to serde).
pub fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

/// Render a log-entry slice as a JSON array.
pub fn entries_json(entries: &[LogEntry]) -> String {
    let items: Vec<String> = entries
        .iter()
        .map(|e| {
            format!(
                r#"{{"ts":{},"level":"{}","message":"{}"}}"#,
                e.ts_ms,
                json_escape(&e.level),
                json_escape(&e.message)
            )
        })
        .collect();
    format!("[{}]", items.join(","))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_and_read_logs() {
        record_log("info", "hello");
        record_log("error", "boom \"x\"");
        let logs = recent_logs(10);
        assert!(logs.iter().any(|e| e.message == "hello"));
        let errs = recent_errors(10);
        assert!(errs.iter().any(|e| e.level == "error"));
        // error escaping is JSON-safe.
        assert!(entries_json(&errs).contains("boom \\\"x\\\""));
    }

    #[test]
    fn request_counters_move() {
        let before = requests_total();
        record_request(200);
        record_request(500);
        assert!(requests_total() >= before + 2);
    }

    #[test]
    fn spans_recorded_as_json() {
        record_span("db.query", 1234, true);
        record_span("http.get", 50, false);
        let j = spans_json(10);
        assert!(j.contains(r#""name":"db.query""#), "{j}");
        assert!(j.contains(r#""durUs":1234"#), "{j}");
        assert!(j.contains(r#""ok":false"#), "{j}");
    }
}
