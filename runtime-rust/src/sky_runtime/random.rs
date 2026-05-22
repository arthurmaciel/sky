// Random kernel stubs — generic over E.
use super::*;
use std::future::ready;
use std::sync::atomic::{AtomicU64, Ordering};

static LCG_STATE: AtomicU64 = AtomicU64::new(0);

pub(crate) fn lcg_init() {
    LCG_STATE.compare_exchange(0, std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos() as u64,
        Ordering::Relaxed, Ordering::Relaxed).ok();
}

pub(crate) fn lcg_next() -> u64 {
    let state = LCG_STATE.load(Ordering::Relaxed);
    let next = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    LCG_STATE.store(next, Ordering::Relaxed);
    next
}

pub fn random_int<E: Send + 'static>(lo: i64, hi: i64) -> SkyTask<E, i64> {
    lcg_init();
    let range = (hi - lo).abs() + 1;
    let v = lo + (lcg_next() as i64 % range);
    Box::pin(ready(ok_res(v)))
}

pub fn random_float<E: Send + 'static>(_: ()) -> SkyTask<E, f64> {
    lcg_init();
    let v = (lcg_next() >> 11) as f64 * (1.0 / 9007199254740992.0);
    Box::pin(ready(ok_res(v)))
}

pub fn random_choice<E: Send + From<String> + 'static>(items: Vec<String>) -> SkyTask<E, String> {
    lcg_init();
    if items.is_empty() { return Box::pin(ready(SkyResult::Err(str_err("Random.choice: empty list")))); }
    let idx = lcg_next() as usize % items.len();
    Box::pin(ready(ok_res(items.get(idx).cloned().unwrap_or_default())))
}
