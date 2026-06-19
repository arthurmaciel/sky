// System helpers — some generic over E (when returning SkyTask).
use super::*;

// `std::env::set_var`/`remove_var` are documented as NOT thread-safe; under
// `Task.parallel` (Task-tier `System.setenv`/`unsetenv`/`loadEnv` compose with
// it) two threads mutating the environment is a data race / UB by the std
// contract. Serialise every mutation behind this process-global lock so a
// concurrent mutator can't race another. (Concurrent readers on another thread
// are still technically unsynchronised against this — but this removes the
// mutator↔mutator race, which is the one reachable purely from env-Task
// composition; Go's os.Setenv is likewise only mutex-guarded among Go callers.)
static ENV_MUTATION_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Set an environment variable under the process-global env-mutation lock.
fn locked_set_var(key: &str, val: &str) {
    let _guard = ENV_MUTATION_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    std::env::set_var(key, val);
}

/// Remove an environment variable under the process-global env-mutation lock.
fn locked_remove_var(key: &str) {
    let _guard = ENV_MUTATION_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    std::env::remove_var(key);
}

pub fn system_args<E: Send + 'static>(_: ()) -> SkyTask<E, Vec<String>> {
    Box::pin(async move { ok_res(std::env::args().skip(1).collect()) })
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
    Box::pin(async move {
        match std::process::Command::new(&cmd).args(&args).output() {
            Ok(out) => {
                // Go's CombinedOutput: stdout then stderr (callers usually `2>&1`).
                let mut combined = out.stdout;
                combined.extend_from_slice(&out.stderr);
                let text = String::from_utf8_lossy(&combined).into_owned();
                if out.status.success() {
                    ok_res(text)
                } else {
                    // Cap the captured output folded into the Err string: large /
                    // binary subprocess output bloats the error and may embed
                    // secrets the process printed. Truncate to a bounded prefix
                    // (on a char boundary) before prepending the status.
                    const MAX_ERR_OUTPUT: usize = 4096;
                    let snippet: String = if text.len() > MAX_ERR_OUTPUT {
                        let mut end = MAX_ERR_OUTPUT;
                        while end > 0 && !text.is_char_boundary(end) {
                            end -= 1;
                        }
                        format!("{}… (output truncated)", &text[..end])
                    } else {
                        text
                    };
                    SkyResult::Err(str_err(&format!("{}: {}", snippet, out.status)))
                }
            }
            Err(e) => SkyResult::Err(str_err(&format!("{}: {}", cmd, e))),
        }
    })
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
    Box::pin(async move {
        match std::env::var(&key) {
            Ok(v) => ok_res(v),
            Err(_) => {
                let msg = format!("environment variable {:?} is not set", key);
                SkyResult::Err(str_err(&msg))
            }
        }
    })
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
    Box::pin(async move {
        let r: Result<i64, String> = match std::env::var(&key) {
            Err(_) => Err(format!("environment variable {:?} is not set", key)),
            Ok(v) => v
                .trim()
                .parse::<i64>()
                .map_err(|_| format!("env {}: not an int: {}", key, v)),
        };
        match r {
            Ok(n) => ok_res(n),
            Err(m) => SkyResult::Err(str_err(&m)),
        }
    })
}

/// `System.getenvBool key : String -> Task Error Bool`. Matches Go's truthy/falsy
/// table: `true/yes/1/on/y/t` → true; `false/no/0/off/n/f`/empty → false; unset →
/// `Err` (NotFound); anything else → `Err` (not-a-bool).
pub fn system_getenv_bool<E: Send + From<String> + 'static>(key: String) -> SkyTask<E, bool> {
    Box::pin(async move {
        let r: Result<bool, String> = match std::env::var(&key) {
            Err(_) => Err(format!("environment variable {:?} is not set", key)),
            Ok(v) => match v.trim().to_lowercase().as_str() {
                "true" | "yes" | "1" | "on" | "y" | "t" => Ok(true),
                "false" | "no" | "0" | "off" | "n" | "f" | "" => Ok(false),
                _ => Err(format!("env {}: not a bool: {}", key, v)),
            },
        };
        match r {
            Ok(b) => ok_res(b),
            Err(m) => SkyResult::Err(str_err(&m)),
        }
    })
}

/// `System.getArg n : Int -> Task Error (Maybe String)`. Indexes the FULL arg
/// vector to match Go's `System_getArg` (`os.Args[n]` — index 0 is the program
/// name, UNLIKE `System.args` which skips it); out-of-range / negative →
/// `Ok Nothing`. Never `Err` (mirrors Go).
pub fn system_get_arg<E: Send + 'static>(n: i64) -> SkyTask<E, SkyMaybe<String>> {
    Box::pin(async move {
        let out = if n < 0 {
            SkyMaybe::Nothing
        } else {
            match std::env::args().nth(n as usize) {
                Some(a) => SkyMaybe::Just(a),
                None => SkyMaybe::Nothing,
            }
        };
        ok_res(out)
    })
}

pub fn system_setenv<E: Send + 'static>(key: String, val: String) -> SkyTask<E, ()> {
    Box::pin(async move {
        locked_set_var(&key, &val);
        ok_res(())
    })
}

pub fn system_unsetenv<E: Send + 'static>(key: String) -> SkyTask<E, ()> {
    Box::pin(async move {
        locked_remove_var(&key);
        ok_res(())
    })
}

/// `System.cwd : () -> Task Error String`.
pub fn system_cwd<E: Send + From<String> + 'static>(_: ()) -> SkyTask<E, String> {
    Box::pin(async move {
        match std::env::current_dir() {
            Ok(p) => ok_res(p.to_string_lossy().into_owned()),
            Err(e) => SkyResult::Err(str_err(&format!("{}", e))),
        }
    })
}

/// `System.getcwd : () -> Task Error String` — backward-compat alias for `cwd`.
/// Go: `func System_getcwd(unit any) any { return System_cwd(unit) }`.
pub fn system_getcwd<E: Send + From<String> + 'static>(unit: ()) -> SkyTask<E, String> {
    system_cwd(unit)
}

/// `System.loadEnv : () -> Task Error ()`. Parses a `.env` file in the CWD
/// (KEY=VALUE per line, `#` comments, optional surrounding quotes) and sets
/// each var WITHOUT overriding one already present in the process environment
/// (process env wins, matching Sky's precedence). A missing `.env` is a no-op
/// success.
pub fn system_load_env<E: Send + 'static>(_: ()) -> SkyTask<E, ()> {
    Box::pin(async move {
        if let Ok(contents) = std::fs::read_to_string(".env") {
            for line in contents.lines() {
                let line = line.trim();
                if line.is_empty() || line.starts_with('#') { continue; }
                if let Some((k, v)) = line.split_once('=') {
                    let k = k.trim();
                    let v = v.trim().trim_matches('"').trim_matches('\'');
                    if std::env::var(k).is_err() { locked_set_var(k, v); }
                }
            }
        }
        ok_res(())
    })
}
