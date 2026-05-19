// File kernel stubs — generic over E.
use super::*;
use std::future::ready;

pub fn file_read_file<E: Send + From<String> + 'static>(path: String) -> SkyTask<E, String> {
    match std::fs::read_to_string(&path) {
        Ok(s) => Box::pin(ready(ok_res(s))),
        Err(e) => Box::pin(ready(SkyResult::Err(str_err(&format!("{}", e))))),
    }
}

pub fn file_write_file<E: Send + From<String> + 'static>(path: String, content: String) -> SkyTask<E, ()> {
    match std::fs::write(&path, &content) {
        Ok(_) => Box::pin(ready(ok_res(()))),
        Err(e) => Box::pin(ready(SkyResult::Err(str_err(&format!("{}", e))))),
    }
}

pub fn file_exists<E: Send + 'static>(path: String) -> SkyTask<E, bool> {
    Box::pin(ready(ok_res(std::path::Path::new(&path).exists())))
}

pub fn file_delete<E: Send + From<String> + 'static>(path: String) -> SkyTask<E, ()> {
    match std::fs::remove_file(&path) {
        Ok(_) => Box::pin(ready(ok_res(()))),
        Err(e) => Box::pin(ready(SkyResult::Err(str_err(&format!("{}", e))))),
    }
}
