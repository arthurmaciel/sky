// A mock Sky.Live endpoint: GET /_sky/sse streams frames; each POST /_sky/event
// triggers one patch frame. Exercises run_session without a real Sky app.
use axum::{routing::{get, post}, Router, response::IntoResponse, http::header};
use std::sync::Arc;
use tokio::sync::broadcast;

async fn spawn_mock() -> (String, tokio::task::JoinHandle<()>) {
    let (tx, _rx) = broadcast::channel::<()>(1024);
    let tx = Arc::new(tx);
    let tx_sse = tx.clone();
    let app = Router::new()
        .route("/_sky/sse", get(move || {
            let mut rx = tx_sse.subscribe();
            async move {
                let stream = async_stream::stream! {
                    yield Ok::<_, std::convert::Infallible>(axum::body::Bytes::from("event: hello\ndata: {}\n\n"));
                    while rx.recv().await.is_ok() {
                        yield Ok(axum::body::Bytes::from("event: patch\ndata: []\n\n"));
                    }
                };
                ([(header::CONTENT_TYPE, "text/event-stream")], axum::body::Body::from_stream(stream))
            }
        }))
        .route("/_sky/event", post(move || { let tx = tx.clone(); async move { let _ = tx.send(()); "ok".into_response() } }));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let h = tokio::spawn(async move { axum::serve(listener, app).await.unwrap(); });
    (format!("http://{addr}"), h)
}

#[tokio::test]
async fn run_session_measures_roundtrips() {
    let (base, _h) = spawn_mock().await;
    let lat = sse_bench::run_session(&base, 20).await.expect("session ok");
    assert_eq!(lat.len(), 20, "one latency per event");
    assert!(lat.iter().all(|&x| x >= 0.0 && x < 5000.0), "latencies sane: {lat:?}");
}
