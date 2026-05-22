// Log helpers — generic over E.
use super::*;

pub fn log_info<E: Send + 'static>(msg: String) -> SkyTask<E, ()> {
    println!("{}", msg);
    Box::pin(async move { ok_res(()) })
}

pub fn log_info_with<E: Send + 'static>(msg: String, _attrs: Vec<String>) -> SkyTask<E, ()> {
    println!("{}", msg);
    Box::pin(async move { ok_res(()) })
}

pub fn log_error_with<E: Send + 'static>(msg: String, _attrs: Vec<String>) -> SkyTask<E, ()> {
    eprintln!("{}", msg);
    Box::pin(async move { ok_res(()) })
}

pub fn log_debug<E: Send + 'static>(msg: String) -> SkyTask<E, ()> { log_info(msg) }
pub fn log_warn<E: Send + 'static>(msg: String) -> SkyTask<E, ()> { log_info(msg) }
pub fn log_error<E: Send + 'static>(msg: String) -> SkyTask<E, ()> {
    eprintln!("{}", msg);
    Box::pin(async move { ok_res(()) })
}
pub fn log_debug_with<E: Send + 'static>(msg: String, _attrs: Vec<String>) -> SkyTask<E, ()> {
    println!("{}", msg);
    Box::pin(async move { ok_res(()) })
}
pub fn log_warn_with<E: Send + 'static>(msg: String, _attrs: Vec<String>) -> SkyTask<E, ()> {
    println!("{}", msg);
    Box::pin(async move { ok_res(()) })
}
