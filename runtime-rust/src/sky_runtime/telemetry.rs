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

/// One captured log line.
#[derive(Clone)]
pub struct LogEntry {
    pub ts_ms: u64,
    pub level: String,
    pub message: String,
}

static LOGS: Mutex<VecDeque<LogEntry>> = Mutex::new(VecDeque::new());
static ERRORS: Mutex<VecDeque<LogEntry>> = Mutex::new(VecDeque::new());
static REQUESTS_TOTAL: AtomicU64 = AtomicU64::new(0);
static ERRORS_TOTAL: AtomicU64 = AtomicU64::new(0);

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn push_bounded(ring: &Mutex<VecDeque<LogEntry>>, cap: usize, e: LogEntry) {
    let mut g = ring.lock().unwrap_or_else(|p| p.into_inner());
    if g.len() >= cap {
        g.pop_front();
    }
    g.push_back(e);
}

/// Record a structured log line (called from `Std.Log.*`). Errors also land in
/// the error ring + bump the error counter.
pub fn record_log(level: &str, message: &str) {
    let e = LogEntry { ts_ms: now_ms(), level: level.to_string(), message: message.to_string() };
    if level.eq_ignore_ascii_case("error") {
        ERRORS_TOTAL.fetch_add(1, Ordering::Relaxed);
        push_bounded(&ERRORS, ERR_CAP, e.clone());
    }
    push_bounded(&LOGS, LOG_CAP, e);
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
}
