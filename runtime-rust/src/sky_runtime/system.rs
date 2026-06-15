// System helpers — some generic over E (when returning SkyTask).
use super::*;

use std::future::ready;

pub fn system_args<E: Send + 'static>(_: ()) -> SkyTask<E, Vec<String>> {
    Box::pin(ready(ok_res(std::env::args().skip(1).collect())))
}

/// `Sky.Core.Process.run : String -> List String -> Task Error String` — run a
/// subprocess, returning its combined stdout+stderr. Mirrors Go's `Process_run`
/// (`exec.Command` + `CombinedOutput`): a non-zero exit or a spawn failure is
/// `Err` carrying the captured output + the error; a clean exit is `Ok(output)`.
/// Total — every failure maps to `Err`, never a panic.
///
/// SECURITY: `Process.run` is an intentional Sky stdlib effect (Task-tier,
/// parity with the Go backend) — no more permissive than Go's. Sandboxing
/// untrusted Sky source (e.g. blocking the `Process.` module) is the calling
/// application's responsibility, exactly as on Go.
pub fn process_run<E: Send + From<String> + 'static>(
    cmd: String,
    args: Vec<String>,
) -> SkyTask<E, String> {
    match std::process::Command::new(&cmd).args(&args).output() {
        Ok(out) => {
            // Go's CombinedOutput: stdout then stderr (callers usually `2>&1`).
            let mut combined = out.stdout;
            combined.extend_from_slice(&out.stderr);
            let text = String::from_utf8_lossy(&combined).into_owned();
            if out.status.success() {
                Box::pin(ready(ok_res(text)))
            } else {
                Box::pin(ready(SkyResult::Err(str_err(&format!("{}: {}", text, out.status)))))
            }
        }
        Err(e) => Box::pin(ready(SkyResult::Err(str_err(&format!("{}: {}", cmd, e))))),
    }
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

/// `System.getenvInt key : String -> Task Error Int`. Unset → `Err` (Go's
/// ErrNotFound); set-but-not-an-int → `Err` (Go's ErrFfi). The string-based error
/// follows the generic-`E` convention (coarser than Go's typed kinds; shared with
/// `getenv`/`cwd`).
pub fn system_getenv_int<E: Send + From<String> + 'static>(key: String) -> SkyTask<E, i64> {
    let r: Result<i64, String> = match std::env::var(&key) {
        Err(_) => Err(format!("environment variable {:?} is not set", key)),
        Ok(v) => v
            .trim()
            .parse::<i64>()
            .map_err(|_| format!("env {}: not an int: {}", key, v)),
    };
    match r {
        Ok(n) => Box::pin(ready(ok_res(n))),
        Err(m) => Box::pin(ready(SkyResult::Err(str_err(&m)))),
    }
}

/// `System.getenvBool key : String -> Task Error Bool`. Matches Go's truthy/falsy
/// table: `true/yes/1/on/y/t` → true; `false/no/0/off/n/f`/empty → false; unset →
/// `Err` (NotFound); anything else → `Err` (not-a-bool).
pub fn system_getenv_bool<E: Send + From<String> + 'static>(key: String) -> SkyTask<E, bool> {
    let r: Result<bool, String> = match std::env::var(&key) {
        Err(_) => Err(format!("environment variable {:?} is not set", key)),
        Ok(v) => match v.trim().to_lowercase().as_str() {
            "true" | "yes" | "1" | "on" | "y" | "t" => Ok(true),
            "false" | "no" | "0" | "off" | "n" | "f" | "" => Ok(false),
            _ => Err(format!("env {}: not a bool: {}", key, v)),
        },
    };
    match r {
        Ok(b) => Box::pin(ready(ok_res(b))),
        Err(m) => Box::pin(ready(SkyResult::Err(str_err(&m)))),
    }
}

/// `System.getArg n : Int -> Task Error (Maybe String)`. Indexes the FULL arg
/// vector to match Go's `System_getArg` (`os.Args[n]` — index 0 is the program
/// name, UNLIKE `System.args` which skips it); out-of-range / negative →
/// `Ok Nothing`. Never `Err` (mirrors Go).
pub fn system_get_arg<E: Send + 'static>(n: i64) -> SkyTask<E, SkyMaybe<String>> {
    let out = if n < 0 {
        SkyMaybe::Nothing
    } else {
        match std::env::args().nth(n as usize) {
            Some(a) => SkyMaybe::Just(a),
            None => SkyMaybe::Nothing,
        }
    };
    Box::pin(ready(ok_res(out)))
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
