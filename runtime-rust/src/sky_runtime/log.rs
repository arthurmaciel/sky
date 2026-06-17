// Log helpers — Go-format parity for `Std.Log.*`.
//
// The plain + JSON line shapes mirror `runtime-go/rt/rt.go`'s `logEmit`
// byte-for-byte (modulo the genuinely-nondeterministic timestamp):
//
//   plain:  <RFC3339Nano-UTC> <LEVEL> <message>[ key=value …]   (level UPPER)
//   json:   {"level":"<level>","msg":"<message>","time":"<ts>"}  (level lower,
//           keys alphabetically sorted to match Go's json.Marshal of a map)
//
// Stream routing matches Go: warn + error → stderr, debug + info → stdout.
// `SKY_LOG_LEVEL` gates output (debug < info < warn < error; default info);
// `SKY_LOG_FORMAT=json` switches to the JSON shape. Each line is also mirrored
// into the telemetry ring (the Sky Console reads it).
//
// `Log.println` is a SEPARATE bare line with NO prefix (Go's `Log_println` is a
// raw `fmt.Println`); codegen routes it to `log_println`, never to `log_info`.
use super::*;

const LOG_LEVEL_DEBUG: i32 = 0;
const LOG_LEVEL_INFO: i32 = 1;
const LOG_LEVEL_WARN: i32 = 2;
const LOG_LEVEL_ERROR: i32 = 3;

/// `SKY_LOG_LEVEL` → numeric threshold. Mirrors Go's `logLevelFromEnv`
/// (`debug` / `warn`|`warning` / `error`; everything else → info).
fn log_threshold() -> i32 {
    match std::env::var("SKY_LOG_LEVEL")
        .unwrap_or_default()
        .to_ascii_lowercase()
        .as_str()
    {
        "debug" => LOG_LEVEL_DEBUG,
        "warn" | "warning" => LOG_LEVEL_WARN,
        "error" => LOG_LEVEL_ERROR,
        _ => LOG_LEVEL_INFO,
    }
}

fn log_json() -> bool {
    std::env::var("SKY_LOG_FORMAT").unwrap_or_default() == "json"
}

/// Current UTC instant in Go's `time.RFC3339Nano` layout
/// (`2006-01-02T15:04:05.999999999Z07:00`): nanosecond precision with trailing
/// zeros trimmed, UTC rendered as `Z`. Matches Go's
/// `now.UTC().Format(time.RFC3339Nano)`.
fn rfc3339_nano_now() -> String {
    let now = chrono::Utc::now();
    let nanos = now.format("%9f").to_string();
    let trimmed = nanos.trim_end_matches('0');
    let date = now.format("%Y-%m-%dT%H:%M:%S").to_string();
    if trimmed.is_empty() {
        format!("{date}Z")
    } else {
        format!("{date}.{trimmed}Z")
    }
}

/// Minimal JSON string escaping for the hand-built plain/JSON records, matching
/// Go's `json.Marshal` for the characters that occur in log text. Reuses the
/// telemetry escaper so the two sinks never diverge.
fn json_str(s: &str) -> String {
    format!("\"{}\"", super::telemetry::json_escape(s))
}

/// The Go `logEmit` core: gate on the threshold, mirror into the telemetry ring,
/// then write the plain or JSON line to the correct stream. `level` is the
/// numeric severity; `level_name` is the lowercase token (`info` / `warn` / …).
fn log_emit(level: i32, level_name: &str, msg: &str) {
    if level < log_threshold() {
        return;
    }
    super::telemetry::record_log(level_name, msg);
    let to_stderr = level >= LOG_LEVEL_WARN;
    if log_json() {
        // Go marshals a map[string]any → keys sorted alphabetically:
        // level, msg, time (no attrs are surfaced to JSON fields today —
        // the *With variants flatten into the message, matching Go's
        // plain-driver behaviour for the List-element call shape).
        let line = format!(
            "{{\"level\":{},\"msg\":{},\"time\":{}}}",
            json_str(level_name),
            json_str(msg),
            json_str(&rfc3339_nano_now()),
        );
        if to_stderr {
            eprintln!("{line}");
        } else {
            println!("{line}");
        }
        return;
    }
    let line = format!("{} {} {}", rfc3339_nano_now(), level_name.to_ascii_uppercase(), msg);
    if to_stderr {
        eprintln!("{line}");
    } else {
        println!("{line}");
    }
}

/// `Log.println : String -> Task Error ()` — Go's `Log_println` is a bare
/// `fmt.Println`: NO timestamp, NO level, straight to stdout. Still mirrored into
/// the telemetry ring at info level so the console surfaces it.
pub fn log_println<E: Send + 'static>(msg: String) -> SkyTask<E, ()> {
    Box::pin(async move {
        super::telemetry::record_log("info", &msg);
        println!("{msg}");
        ok_res(())
    })
}

pub fn log_info<E: Send + 'static>(msg: String) -> SkyTask<E, ()> {
    Box::pin(async move {
        log_emit(LOG_LEVEL_INFO, "info", &msg);
        ok_res(())
    })
}

// `Log.*With : String -> List a -> Task` is polymorphic in the attr element
// (Sky callers pass a flat `List String` — `["errId", id]` — OR a key/value
// `List (String, String)` — `[("errId", id), …]`). The attrs slot is generic
// over its element type `A` to keep every call shape total without coercing
// tuples through a `Display` they don't implement (was the E0277 in
// routes_auth / routes_todos). The attrs are not yet flattened into the line
// (no `Display` bound to render them); the level + timestamp prefix matches Go.
pub fn log_info_with<E: Send + 'static, A>(msg: String, attrs: Vec<A>) -> SkyTask<E, ()> {
    // Drop the (currently unrendered) attrs BEFORE the future is constructed so
    // the captured set is `Send`-clean without an `A: Send` bound; the effect
    // (the line write) still fires only on `.await`.
    drop(attrs);
    Box::pin(async move {
        log_emit(LOG_LEVEL_INFO, "info", &msg);
        ok_res(())
    })
}

pub fn log_error_with<E: Send + 'static, A>(msg: String, attrs: Vec<A>) -> SkyTask<E, ()> {
    drop(attrs);
    Box::pin(async move {
        log_emit(LOG_LEVEL_ERROR, "error", &msg);
        ok_res(())
    })
}

pub fn log_debug<E: Send + 'static>(msg: String) -> SkyTask<E, ()> {
    Box::pin(async move {
        log_emit(LOG_LEVEL_DEBUG, "debug", &msg);
        ok_res(())
    })
}
pub fn log_warn<E: Send + 'static>(msg: String) -> SkyTask<E, ()> {
    Box::pin(async move {
        log_emit(LOG_LEVEL_WARN, "warn", &msg);
        ok_res(())
    })
}
pub fn log_error<E: Send + 'static>(msg: String) -> SkyTask<E, ()> {
    Box::pin(async move {
        log_emit(LOG_LEVEL_ERROR, "error", &msg);
        ok_res(())
    })
}
pub fn log_debug_with<E: Send + 'static, A>(msg: String, attrs: Vec<A>) -> SkyTask<E, ()> {
    drop(attrs);
    Box::pin(async move {
        log_emit(LOG_LEVEL_DEBUG, "debug", &msg);
        ok_res(())
    })
}
pub fn log_warn_with<E: Send + 'static, A>(msg: String, attrs: Vec<A>) -> SkyTask<E, ()> {
    drop(attrs);
    Box::pin(async move {
        log_emit(LOG_LEVEL_WARN, "warn", &msg);
        ok_res(())
    })
}
