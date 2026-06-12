//! Std.Cache — a bounded LRU cache with optional TTL + running stats.
//!
//! Handle-based: `cache_new_raw` returns an `i64` handle; the other kernels take
//! it. The Sky kernel signatures don't all carry the value type — `removeRaw :
//! Int -> k`, `sizeRaw : Int`, `clearRaw : Int` have no `v` — so a fully
//! `(K, V)`-typed store can't serve them. Instead each handle holds a
//! `K`-typed store (`KeyStore<K>`) whose entries hold a value-erased
//! `Box<dyn Any + Send>`, downcast to `V` only on `get` (where the Sky
//! `getRaw : Int -> k -> Task Error (Maybe v)` return makes `V` available).
//!
//! Both casts are **correct by construction**: every access to a given handle
//! uses the same `(K, V)`, enforced by Sky's opaque `Cache k v` type, so neither
//! the `KeyStore<K>` downcast nor the value `V` downcast can ever fail. A
//! mismatch / missing handle degrades to a miss / no-op — never a panic. This is
//! the same sanctioned-seam discipline as the S6 pub/sub broker registry, and is
//! strictly safer than the Go backend's reflect-based cache (the cast cannot
//! fail). Recorded in the README "Soundness attention points" `dyn Any` register.

use super::*;
use std::any::Any;
use std::collections::HashMap;
use std::hash::Hash;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

/// Mirrors Sky's `CacheCfg` record (field names match so the codegen maps
/// `Std.Cache.CacheCfg` → this struct, EmailMessage-style).
#[allow(non_snake_case)]
#[derive(Clone)]
pub struct CacheCfg {
    pub maxEntries: i64,
    pub ttlMs: i64,
    pub maxBytes: i64,
}

/// Mirrors Sky's `stats` return record `{ hits, misses, evictions }`.
#[allow(non_snake_case)]
#[derive(Clone)]
pub struct CacheStats {
    pub hits: i64,
    pub misses: i64,
    pub evictions: i64,
}

struct EntryErased {
    value: Box<dyn Any + Send>, // the cache value `V`, downcast on get
    expires_at: Option<Instant>,
    last_seq: u64, // for LRU eviction
}

struct KeyStore<K> {
    map: HashMap<K, EntryErased>,
}

struct Slot {
    cfg: CacheCfg,
    hits: i64,
    misses: i64,
    evictions: i64,
    entries: i64, // tracked here so sizeRaw needs neither K nor V
    seq: u64,     // monotonic access counter
    store: Option<Box<dyn Any + Send>>, // KeyStore<K>, created lazily on first K-bearing op
}

#[allow(clippy::type_complexity)]
fn registry() -> &'static Mutex<(i64, HashMap<i64, Slot>)> {
    static R: OnceLock<Mutex<(i64, HashMap<i64, Slot>)>> = OnceLock::new();
    R.get_or_init(|| Mutex::new((0, HashMap::new())))
}

fn with_reg<R>(f: impl FnOnce(&mut i64, &mut HashMap<i64, Slot>) -> R) -> R {
    let mut g = registry().lock().unwrap_or_else(|e| e.into_inner());
    let (next, slots) = &mut *g;
    f(next, slots)
}

/// `Cache.newRaw : CacheCfg -> Task Error Int` — allocate a cache, return its handle.
pub fn cache_new_raw<E: Send + From<String> + 'static>(cfg: CacheCfg) -> SkyTask<E, i64> {
    Box::pin(async move {
        let h = with_reg(|next, slots| {
            *next += 1;
            let h = *next;
            slots.insert(
                h,
                Slot { cfg, hits: 0, misses: 0, evictions: 0, entries: 0, seq: 0, store: None },
            );
            h
        });
        ok_res(h)
    })
}

/// `Cache.putRaw : Int -> k -> v -> Task Error ()`.
pub fn cache_put<E, K, V>(handle: i64, key: K, value: V) -> SkyTask<E, ()>
where
    E: Send + From<String> + 'static,
    K: Eq + Hash + Clone + Send + 'static,
    V: Send + 'static,
{
    Box::pin(async move {
        with_reg(|_, slots| {
            let slot = match slots.get_mut(&handle) {
                Some(s) => s,
                None => return,
            };
            slot.seq += 1;
            let seq = slot.seq;
            let max = slot.cfg.maxEntries;
            let ttl = slot.cfg.ttlMs;
            let expires_at = if ttl > 0 {
                Some(Instant::now() + Duration::from_millis(ttl as u64))
            } else {
                None
            };
            let (added, evicted) = {
                let store = slot
                    .store
                    .get_or_insert_with(|| Box::new(KeyStore::<K> { map: HashMap::new() }));
                match store.downcast_mut::<KeyStore<K>>() {
                    // Impossible per Sky's per-handle (K,V) consistency; no-op, never panic.
                    None => (0i64, 0i64),
                    Some(ks) => {
                        let entry = EntryErased { value: Box::new(value), expires_at, last_seq: seq };
                        let added = i64::from(ks.map.insert(key, entry).is_none());
                        let mut evicted = 0i64;
                        if max > 0 && ks.map.len() as i64 > max {
                            if let Some(lru) =
                                ks.map.iter().min_by_key(|(_, e)| e.last_seq).map(|(k, _)| k.clone())
                            {
                                ks.map.remove(&lru);
                                evicted = 1;
                            }
                        }
                        (added, evicted)
                    }
                }
            };
            slot.entries += added - evicted;
            slot.evictions += evicted;
        });
        ok_res(())
    })
}

/// `Cache.getRaw : Int -> k -> Task Error (Maybe v)`.
pub fn cache_get<E, K, V>(handle: i64, key: K) -> SkyTask<E, SkyMaybe<V>>
where
    E: Send + From<String> + 'static,
    K: Eq + Hash + Send + 'static,
    V: Clone + Send + 'static,
{
    Box::pin(async move {
        let out = with_reg(|_, slots| {
            let slot = match slots.get_mut(&handle) {
                Some(s) => s,
                None => return SkyMaybe::Nothing,
            };
            slot.seq += 1;
            let seq = slot.seq;
            let now = Instant::now();
            enum Outcome<V> {
                Hit(V),
                Expired,
                Miss,
            }
            let outcome = match slot.store.as_mut().and_then(|s| s.downcast_mut::<KeyStore<K>>()) {
                None => Outcome::Miss,
                Some(ks) => match ks.map.get(&key) {
                    None => Outcome::Miss,
                    Some(entry) => {
                        if entry.expires_at.is_some_and(|x| now >= x) {
                            ks.map.remove(&key);
                            Outcome::Expired
                        } else {
                            // value downcast — V is correct by construction (handle's V)
                            let v = entry.value.downcast_ref::<V>().cloned();
                            if let Some(e) = ks.map.get_mut(&key) {
                                e.last_seq = seq; // LRU touch
                            }
                            match v {
                                Some(v) => Outcome::Hit(v),
                                None => Outcome::Miss, // impossible; total fallback
                            }
                        }
                    }
                },
            };
            match outcome {
                Outcome::Hit(v) => {
                    slot.hits += 1;
                    SkyMaybe::Just(v)
                }
                Outcome::Expired => {
                    slot.misses += 1;
                    slot.entries -= 1;
                    SkyMaybe::Nothing
                }
                Outcome::Miss => {
                    slot.misses += 1;
                    SkyMaybe::Nothing
                }
            }
        });
        ok_res(out)
    })
}

/// `Cache.removeRaw : Int -> k -> Task Error ()`. No `v` in the signature — the
/// `K`-typed store + erased values is exactly what lets this work.
pub fn cache_remove<E, K>(handle: i64, key: K) -> SkyTask<E, ()>
where
    E: Send + From<String> + 'static,
    K: Eq + Hash + Send + 'static,
{
    Box::pin(async move {
        with_reg(|_, slots| {
            if let Some(slot) = slots.get_mut(&handle) {
                let removed = slot
                    .store
                    .as_mut()
                    .and_then(|s| s.downcast_mut::<KeyStore<K>>())
                    .is_some_and(|ks| ks.map.remove(&key).is_some());
                if removed {
                    slot.entries -= 1;
                }
            }
        });
        ok_res(())
    })
}

/// `Cache.clearRaw : Int -> Task Error ()`.
pub fn cache_clear<E: Send + From<String> + 'static>(handle: i64) -> SkyTask<E, ()> {
    Box::pin(async move {
        with_reg(|_, slots| {
            if let Some(slot) = slots.get_mut(&handle) {
                slot.store = None;
                slot.entries = 0;
            }
        });
        ok_res(())
    })
}

/// `Cache.sizeRaw : Int -> Task Error Int`.
pub fn cache_size<E: Send + From<String> + 'static>(handle: i64) -> SkyTask<E, i64> {
    Box::pin(async move {
        let n = with_reg(|_, slots| slots.get(&handle).map(|s| s.entries).unwrap_or(0));
        ok_res(n)
    })
}

/// `Cache.statsRaw : Int -> Task Error { hits, misses, evictions }`.
pub fn cache_stats<E: Send + From<String> + 'static>(handle: i64) -> SkyTask<E, CacheStats> {
    Box::pin(async move {
        let s = with_reg(|_, slots| {
            slots.get(&handle).map_or(
                CacheStats { hits: 0, misses: 0, evictions: 0 },
                |s| CacheStats { hits: s.hits, misses: s.misses, evictions: s.evictions },
            )
        });
        ok_res(s)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run<T: Send + 'static>(t: SkyTask<SkyError, T>) -> T {
        match crate::sky_runtime::task::block_on(t) {
            SkyResult::Ok(v) => v,
            SkyResult::Err(_) => panic!("cache task failed"),
        }
    }

    #[test]
    fn put_get_size_remove_stats() {
        let h = run(cache_new_raw::<SkyError>(CacheCfg { maxEntries: 8, ttlMs: 0, maxBytes: 0 }));
        run(cache_put::<SkyError, String, String>(h, "a".into(), "1".into()));
        run(cache_put::<SkyError, String, String>(h, "b".into(), "2".into()));
        assert_eq!(run(cache_size::<SkyError>(h)), 2);
        assert_eq!(run(cache_get::<SkyError, String, String>(h, "a".into())), SkyMaybe::Just("1".into()));
        assert_eq!(run(cache_get::<SkyError, String, String>(h, "z".into())), SkyMaybe::Nothing);
        run(cache_remove::<SkyError, String>(h, "a".into()));
        assert_eq!(run(cache_get::<SkyError, String, String>(h, "a".into())), SkyMaybe::Nothing);
        assert_eq!(run(cache_size::<SkyError>(h)), 1);
        let st = run(cache_stats::<SkyError>(h));
        assert_eq!(st.hits, 1); // the "a" hit
        assert_eq!(st.misses, 2); // "z" + "a"-after-remove
    }

    #[test]
    fn lru_eviction_over_capacity() {
        let h = run(cache_new_raw::<SkyError>(CacheCfg { maxEntries: 2, ttlMs: 0, maxBytes: 0 }));
        run(cache_put::<SkyError, String, i64>(h, "a".into(), 1));
        run(cache_put::<SkyError, String, i64>(h, "b".into(), 2));
        let _ = run(cache_get::<SkyError, String, i64>(h, "a".into())); // touch a (b now LRU)
        run(cache_put::<SkyError, String, i64>(h, "c".into(), 3)); // evicts b
        assert_eq!(run(cache_size::<SkyError>(h)), 2);
        assert_eq!(run(cache_get::<SkyError, String, i64>(h, "b".into())), SkyMaybe::Nothing);
        assert_eq!(run(cache_get::<SkyError, String, i64>(h, "a".into())), SkyMaybe::Just(1));
        assert_eq!(run(cache_stats::<SkyError>(h)).evictions, 1);
    }
}
