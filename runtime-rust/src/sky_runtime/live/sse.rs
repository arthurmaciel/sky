use tokio::sync::mpsc;

/// One framed SSE message body (already serialized patch-envelope JSON).
#[derive(Clone, Debug)]
pub struct SsePatch(pub String);

pub type SseTx = mpsc::Sender<SsePatch>;
pub type SseRx = mpsc::Receiver<SsePatch>;

/// Bounded buffer (Go default 16); drops oldest under backpressure are surfaced
/// by the caller. hello/heartbeat framing is done in mod.rs when wiring axum.
pub fn channel() -> (SseTx, SseRx) {
    mpsc::channel(16)
}

/// SSE event framing: `event: <name>\ndata: <payload>\n\n`.
pub fn frame(event: &str, data: &str) -> String {
    format!("event: {event}\ndata: {data}\n\n")
}

// ─── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_formats_correctly() {
        let s = frame("hello", r#"{"seq":0}"#);
        assert_eq!(s, "event: hello\ndata: {\"seq\":0}\n\n");
    }

    #[test]
    fn channel_returns_bounded_pair() {
        let (tx, _rx) = channel();
        // capacity is 16; can send without await from sync context via try_send
        assert!(tx.try_send(SsePatch("test".into())).is_ok());
    }
}
