use crate::*;

pub fn greet(name: String) -> SkyResult<SkyError, String> {
    ok_res(format!("Hello, {}!", name))
}
