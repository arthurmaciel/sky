// System helpers — some generic over E (when returning SkyTask).
use super::*;

use std::future::ready;

pub fn system_args<E: Send + 'static>(_: ()) -> SkyTask<E, Vec<String>> {
    Box::pin(ready(ok_res(std::env::args().skip(1).collect())))
}
pub fn system_exit(code: i64) -> ! { std::process::exit(code as i32) }

/// `Sky.Core.System.getenv key : String -> Task Error String` — the env var as a
/// Task, or `Err` when unset. Returning a `SkyTask` (not a bare `String`) is
/// required for parity: `getenv` is Task-typed in the stdlib, so a bare `String`
/// fails to type-check in any `Task.andThen`/`Task.run` position. Returning `Err`
/// on unset (rather than `Ok("")`) mirrors Go's `System_getenv` ErrNotFound
/// short-circuit so a chained Task fails identically on both backends. The
/// string-based error follows `system_cwd`'s convention — the generic `E` bound
/// can only build `From<String>`, so the kind is coarser than Go's typed
/// NotFound (shared limitation with `system_cwd`). NOTE: `getenvOr` stays a bare
/// `String` (the default plugs the missing case at the call site).
pub fn system_getenv<E: Send + From<String> + 'static>(key: String) -> SkyTask<E, String> {
    match std::env::var(&key) {
        Ok(v) => Box::pin(ready(ok_res(v))),
        Err(_) => {
            let msg = format!("environment variable {:?} is not set", key);
            Box::pin(ready(SkyResult::Err(str_err(&msg))))
        }
    }
}
/// `Sky.Core.System.getenvOr key default` — the env var, or `default` when unset.
pub fn system_getenv_or(key: String, default: String) -> String {
    std::env::var(&key).unwrap_or(default)
}

pub fn system_setenv<E: Send + 'static>(key: String, val: String) -> SkyTask<E, ()> {
    std::env::set_var(&key, &val);
    Box::pin(async move { ok_res(()) })
}

pub fn system_unsetenv<E: Send + 'static>(key: String) -> SkyTask<E, ()> {
    std::env::remove_var(&key);
    Box::pin(async move { ok_res(()) })
}

/// `System.cwd : () -> Task Error String`.
pub fn system_cwd<E: Send + From<String> + 'static>(_: ()) -> SkyTask<E, String> {
    match std::env::current_dir() {
        Ok(p) => Box::pin(ready(ok_res(p.to_string_lossy().into_owned()))),
        Err(e) => Box::pin(ready(SkyResult::Err(str_err(&format!("{}", e))))),
    }
}

/// `System.loadEnv : () -> Task Error ()`. Parses a `.env` file in the CWD
/// (KEY=VALUE per line, `#` comments, optional surrounding quotes) and sets
/// each var WITHOUT overriding one already present in the process environment
/// (process env wins, matching Sky's precedence). A missing `.env` is a no-op
/// success.
pub fn system_load_env<E: Send + 'static>(_: ()) -> SkyTask<E, ()> {
    if let Ok(contents) = std::fs::read_to_string(".env") {
        for line in contents.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') { continue; }
            if let Some((k, v)) = line.split_once('=') {
                let k = k.trim();
                let v = v.trim().trim_matches('"').trim_matches('\'');
                if std::env::var(k).is_err() { std::env::set_var(k, v); }
            }
        }
    }
    Box::pin(async move { ok_res(()) })
}
