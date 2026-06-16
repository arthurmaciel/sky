// Log helpers — generic over E. Each line is mirrored into the telemetry ring
// (the Sky Console reads it) in addition to stdout/stderr.
use super::*;

fn emit(level: &str, msg: &str) {
    super::telemetry::record_log(level, msg);
    if level == "error" {
        eprintln!("{msg}");
    } else {
        println!("{msg}");
    }
}

pub fn log_info<E: Send + 'static>(msg: String) -> SkyTask<E, ()> {
    emit("info", &msg);
    Box::pin(async move { ok_res(()) })
}

// `Log.*With : String -> List a -> Task` is polymorphic in the attr element
// (Sky callers pass a flat `List String` — `["errId", id]` — OR a key/value
// `List (String, String)` — `[("errId", id), …]`). The runtime only records
// the message, so the attrs slot is generic over its element type `A`; this
// keeps every call shape total without coercing tuples through a `Display` they
// don't implement (was the E0277 in routes_auth / routes_todos).
pub fn log_info_with<E: Send + 'static, A>(msg: String, _attrs: Vec<A>) -> SkyTask<E, ()> {
    emit("info", &msg);
    Box::pin(async move { ok_res(()) })
}

pub fn log_error_with<E: Send + 'static, A>(msg: String, _attrs: Vec<A>) -> SkyTask<E, ()> {
    emit("error", &msg);
    Box::pin(async move { ok_res(()) })
}

pub fn log_debug<E: Send + 'static>(msg: String) -> SkyTask<E, ()> {
    emit("debug", &msg);
    Box::pin(async move { ok_res(()) })
}
pub fn log_warn<E: Send + 'static>(msg: String) -> SkyTask<E, ()> {
    emit("warn", &msg);
    Box::pin(async move { ok_res(()) })
}
pub fn log_error<E: Send + 'static>(msg: String) -> SkyTask<E, ()> {
    emit("error", &msg);
    Box::pin(async move { ok_res(()) })
}
pub fn log_debug_with<E: Send + 'static, A>(msg: String, _attrs: Vec<A>) -> SkyTask<E, ()> {
    emit("debug", &msg);
    Box::pin(async move { ok_res(()) })
}
pub fn log_warn_with<E: Send + 'static, A>(msg: String, _attrs: Vec<A>) -> SkyTask<E, ()> {
    emit("warn", &msg);
    Box::pin(async move { ok_res(()) })
}
