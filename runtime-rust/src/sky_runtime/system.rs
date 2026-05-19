// System helpers — some generic over E (when returning SkyTask).
use super::*;

use std::future::ready;

pub fn system_args<E: Send + 'static>(_: ()) -> SkyTask<E, Vec<String>> {
    Box::pin(ready(ok_res(std::env::args().skip(1).collect())))
}
pub fn system_exit(code: i64) -> ! { std::process::exit(code as i32) }

pub fn system_setenv<E: Send + 'static>(key: String, val: String) -> SkyTask<E, ()> {
    std::env::set_var(&key, &val);
    Box::pin(async move { ok_res(()) })
}

pub fn system_unsetenv<E: Send + 'static>(key: String) -> SkyTask<E, ()> {
    std::env::remove_var(&key);
    Box::pin(async move { ok_res(()) })
}
