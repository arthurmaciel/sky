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

pub fn log_info_with<E: Send + 'static>(msg: String, _attrs: Vec<String>) -> SkyTask<E, ()> {
    emit("info", &msg);
    Box::pin(async move { ok_res(()) })
}

pub fn log_error_with<E: Send + 'static>(msg: String, _attrs: Vec<String>) -> SkyTask<E, ()> {
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
pub fn log_debug_with<E: Send + 'static>(msg: String, _attrs: Vec<String>) -> SkyTask<E, ()> {
    emit("debug", &msg);
    Box::pin(async move { ok_res(()) })
}
pub fn log_warn_with<E: Send + 'static>(msg: String, _attrs: Vec<String>) -> SkyTask<E, ()> {
    emit("warn", &msg);
    Box::pin(async move { ok_res(()) })
}
