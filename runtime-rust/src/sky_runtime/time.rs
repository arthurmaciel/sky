// Time kernel stubs — generic over E.
use super::*;
use std::future::ready;

pub fn time_now<E: Send + 'static>(_: ()) -> SkyTask<E, i64> {
    let ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    Box::pin(ready(ok_res(ms)))
}

pub fn time_sleep<E: Send + 'static>(ms: i64) -> SkyTask<E, ()> {
    Box::pin(async move {
        tokio::time::sleep(std::time::Duration::from_millis(ms as u64)).await;
        ok_res(())
    })
}

pub fn time_unix_millis<E: Send + 'static>(_: ()) -> SkyTask<E, i64> { time_now(()) }
pub fn time_time_string(ms: i64) -> String { format!("timestamp:{}", ms) }
