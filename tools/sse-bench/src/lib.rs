//! sse-bench core: latency summary + the per-session SSE round-trip runner.

use futures_util::StreamExt;
use std::time::Instant;

/// Round-trip latency summary for an sse-bench run.
#[derive(Debug, Clone, PartialEq)]
pub struct Summary {
    pub patch_p50: f64,
    pub patch_p95: f64,
    pub patch_p99: f64,
    pub events_per_sec: f64,
}

impl Summary {
    /// Build a summary from per-event round-trip latencies (ms) and the wall
    /// time (s) the run took. Nearest-rank percentiles; empty → all zero.
    pub fn from_latencies_ms(latencies_ms: &[f64], wall_secs: f64) -> Summary {
        if latencies_ms.is_empty() {
            return Summary { patch_p50: 0.0, patch_p95: 0.0, patch_p99: 0.0, events_per_sec: 0.0 };
        }
        let mut v = latencies_ms.to_vec();
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let pct = |p: f64| -> f64 {
            // nearest-rank: rank = ceil(p/100 * N), 1-indexed
            let rank = ((p / 100.0) * v.len() as f64).ceil().max(1.0) as usize;
            v[rank.min(v.len()) - 1]
        };
        let eps = if wall_secs > 0.0 { v.len() as f64 / wall_secs } else { 0.0 };
        Summary { patch_p50: pct(50.0), patch_p95: pct(95.0), patch_p99: pct(99.0), events_per_sec: eps }
    }

    /// Emit the run as a single-line JSON object (the harness contract).
    pub fn to_json(&self) -> String {
        serde_json::json!({
            "patch_p50": self.patch_p50,
            "patch_p95": self.patch_p95,
            "patch_p99": self.patch_p99,
            "events_per_sec": self.events_per_sec,
        }).to_string()
    }
}

/// One session: open the SSE stream, then fire `events` POSTs sequentially,
/// timing each from send to the next SSE patch frame. Returns latencies (ms).
/// Per-session sequential firing makes event→patch correlation unambiguous.
pub async fn run_session(base: &str, events: usize) -> Result<Vec<f64>, String> {
    let client = reqwest::Client::new();
    let sse = client.get(format!("{base}/_sky/sse"))
        .send().await.map_err(|e| format!("sse connect: {e}"))?;
    let mut stream = sse.bytes_stream();

    // Drain the initial `hello` frame so the first measured event isn't skewed.
    let _ = next_frame(&mut stream).await;

    let mut lat = Vec::with_capacity(events);
    for _ in 0..events {
        let t0 = Instant::now();
        client.post(format!("{base}/_sky/event"))
            .header("content-type", "application/json")
            .body("{\"id\":\"bench\",\"event\":\"click\",\"args\":[]}")
            .send().await.map_err(|e| format!("post: {e}"))?;
        next_frame(&mut stream).await.ok_or_else(|| "sse closed".to_string())?;
        lat.push(t0.elapsed().as_secs_f64() * 1000.0);
    }
    Ok(lat)
}

/// Read bytes until one complete SSE frame (terminated by a blank line) arrives.
async fn next_frame<S>(stream: &mut S) -> Option<String>
where S: futures_util::Stream<Item = reqwest::Result<bytes::Bytes>> + Unpin {
    let mut buf = String::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.ok()?;
        buf.push_str(&String::from_utf8_lossy(&chunk));
        if buf.contains("\n\n") { return Some(buf); }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percentiles_on_known_sample() {
        let xs: Vec<f64> = (1..=100).map(|n| n as f64).collect();
        let s = Summary::from_latencies_ms(&xs, 1.0); // 100 events in 1 s
        assert_eq!(s.patch_p50, 50.0);
        assert_eq!(s.patch_p95, 95.0);
        assert_eq!(s.patch_p99, 99.0);
        assert_eq!(s.events_per_sec, 100.0);
    }

    #[test]
    fn percentiles_empty_is_zero() {
        let s = Summary::from_latencies_ms(&[], 1.0);
        assert_eq!(s, Summary { patch_p50: 0.0, patch_p95: 0.0, patch_p99: 0.0, events_per_sec: 0.0 });
    }
}
