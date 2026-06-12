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

// ── Deterministic seeded PRNG (splitmix64) — byte-for-byte parity with Go's
//    seedStep / Random_seededInt/Float/Choice (runtime-go/rt/rt.go). Pure. ──

fn seed_step(z_in: i64) -> i64 {
    let mut z = (z_in as u64).wrapping_add(0x9E3779B97F4A7C15);
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
    z = z ^ (z >> 31);
    z as i64
}

/// `Random.seededIntRaw : Int -> Int -> Int -> (Int, Int)` → (value, newSeed).
pub fn random_seeded_int(s: i64, lo: i64, hi: i64) -> (i64, i64) {
    let next = seed_step(s);
    if hi <= lo { return (lo, next); }
    let width = (hi - lo + 1) as u64;
    let v = lo + ((next as u64 >> 33) % width) as i64;
    (if v < lo { lo } else { v }, next)
}

/// `Random.seededFloatRaw : Int -> (Float, Int)` → (value in [0,1), newSeed).
pub fn random_seeded_float(s: i64) -> (f64, i64) {
    let next = seed_step(s);
    let f = (next as u64 >> 11) as f64 / (1u64 << 53) as f64;
    (f, next)
}

/// `Random.seededChoiceRaw : Int -> List a -> (Maybe a, Int)`.
pub fn random_seeded_choice<T: Clone>(s: i64, items: Vec<T>) -> (SkyMaybe<T>, i64) {
    let next = seed_step(s);
    if items.is_empty() { return (SkyMaybe::Nothing, next); }
    let idx = (next as u64 >> 33) as usize % items.len();
    match items.get(idx) {
        Some(x) => (SkyMaybe::Just(x.clone()), next),
        None => (SkyMaybe::Nothing, next), // unreachable (idx < len), but total
    }
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
