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

/// `Sky.Core.File.mkdirAll : String -> Task Error ()` — create the directory
/// and every missing parent (mkdir -p). Already-exists is `Ok` (matching
/// `std::fs::create_dir_all`); a real I/O failure is `Err`.
pub fn file_mkdir_all<E: Send + From<String> + 'static>(path: String) -> SkyTask<E, ()> {
    match std::fs::create_dir_all(&path) {
        Ok(_) => Box::pin(ready(ok_res(()))),
        Err(e) => Box::pin(ready(SkyResult::Err(str_err(&format!("{}", e))))),
    }
}

// ─── Read variants ─────────────────────────────────────────────────────────

/// `Sky.Core.File.readFileLimit : String -> Int -> Task Error String`
/// Read at most `limit` bytes. Returns `Err` when the file is larger than
/// `limit` (to avoid OOM on unbounded inputs) or when the content is not
/// valid UTF-8 (use `readFileBytes` for binary data in that case).
/// A non-positive limit falls back to the same 10 MiB default Go uses.
pub fn file_read_file_limit<E: Send + From<String> + 'static>(
    path: String,
    limit: i64,
) -> SkyTask<E, String> {
    use std::io::Read as _;
    let cap: u64 = if limit > 0 { limit as u64 } else { 10 * 1024 * 1024 };
    let result: Result<String, String> = (|| {
        let f = std::fs::File::open(&path)
            .map_err(|e| format!("{}", e))?;
        let meta = f.metadata().map_err(|e| format!("{}", e))?;
        if meta.len() > cap {
            return Err(format!(
                "file exceeds {}-byte limit (actual: {})",
                cap,
                meta.len()
            ));
        }
        let mut buf = String::new();
        f.take(cap).read_to_string(&mut buf).map_err(|e| format!("{}", e))?;
        Ok(buf)
    })();
    match result {
        Ok(s) => Box::pin(ready(ok_res(s))),
        Err(e) => Box::pin(ready(SkyResult::Err(str_err(&e)))),
    }
}

/// `Sky.Core.File.readFileBytes : String -> Task Error (List Int)`
/// Read the file as raw bytes, returned as `Vec<i64>` (Sky `List Int`,
/// values 0..=255). Uses the same 10 MiB default cap as Go. For text
/// content with guaranteed UTF-8, prefer `readFile` / `readFileLimit`.
pub fn file_read_file_bytes<E: Send + From<String> + 'static>(path: String) -> SkyTask<E, Vec<i64>> {
    use std::io::Read as _;
    const DEFAULT_CAP: u64 = 10 * 1024 * 1024;
    let result: Result<Vec<i64>, String> = (|| {
        let f = std::fs::File::open(&path)
            .map_err(|e| format!("{}", e))?;
        let mut buf = Vec::new();
        f.take(DEFAULT_CAP).read_to_end(&mut buf).map_err(|e| format!("{}", e))?;
        Ok(from_u8_slice(&buf))
    })();
    match result {
        Ok(v) => Box::pin(ready(ok_res(v))),
        Err(e) => Box::pin(ready(SkyResult::Err(str_err(&e)))),
    }
}

// ─── Write variants ────────────────────────────────────────────────────────

/// `Sky.Core.File.append : String -> String -> Task Error ()`
/// Append `content` to the end of the file at `path`, creating it if absent.
/// Mirrors Go's `os.OpenFile(…, O_APPEND|O_CREATE|O_WRONLY, 0644)`.
pub fn file_append<E: Send + From<String> + 'static>(path: String, content: String) -> SkyTask<E, ()> {
    use std::io::Write as _;
    let result = (|| {
        let mut f = std::fs::OpenOptions::new()
            .append(true)
            .create(true)
            .open(&path)
            .map_err(|e| format!("{}", e))?;
        f.write_all(content.as_bytes()).map_err(|e| format!("{}", e))
    })();
    match result {
        Ok(_) => Box::pin(ready(ok_res(()))),
        Err(e) => Box::pin(ready(SkyResult::Err(str_err(&e)))),
    }
}

// ─── Removal ───────────────────────────────────────────────────────────────

/// `Sky.Core.File.remove : String -> Task Error ()`
/// Remove the file at `path`. Returns `Err` on any I/O failure (including
/// "not found"). Mirrors Go's `os.Remove`.
pub fn file_remove<E: Send + From<String> + 'static>(path: String) -> SkyTask<E, ()> {
    match std::fs::remove_file(&path) {
        Ok(_) => Box::pin(ready(ok_res(()))),
        Err(e) => Box::pin(ready(SkyResult::Err(str_err(&format!("{}", e))))),
    }
}

// ─── Directory queries ─────────────────────────────────────────────────────

/// `Sky.Core.File.readDir : String -> Task Error (List String)`
/// Return the names (not full paths) of all entries in the directory at
/// `path`, in filesystem order. Mirrors Go's `os.ReadDir` → `e.Name()`.
pub fn file_read_dir<E: Send + From<String> + 'static>(path: String) -> SkyTask<E, Vec<String>> {
    let result = std::fs::read_dir(&path).map(|rd| {
        let mut names: Vec<String> = Vec::new();
        for entry in rd.flatten() {
            names.push(entry.file_name().to_string_lossy().into_owned());
        }
        names
    });
    match result {
        Ok(names) => Box::pin(ready(ok_res(names))),
        Err(e) => Box::pin(ready(SkyResult::Err(str_err(&format!("{}", e))))),
    }
}

/// `Sky.Core.File.isDir : String -> Task Error Bool`
/// Returns `Ok(true)` when `path` exists and is a directory, `Ok(false)` when
/// it exists and is not a directory, and `Ok(false)` (not `Err`) when the path
/// does not exist — matching Go's shape (`os.Stat` error → `false`).
pub fn file_is_dir<E: Send + 'static>(path: String) -> SkyTask<E, bool> {
    let is_dir = std::fs::metadata(&path)
        .map(|m| m.is_dir())
        .unwrap_or(false);
    Box::pin(ready(ok_res(is_dir)))
}

// ─── Temp paths ────────────────────────────────────────────────────────────

/// `Sky.Core.File.tempFile : String -> Task Error String`
/// Create a uniquely-named empty file in the system temp directory, using
/// `prefix` as the filename prefix. Returns the absolute path.
/// The caller is responsible for removing the file when done.
///
/// Implementation: retry loop with a monotonic-time + process-ID suffix until
/// exclusive creation succeeds (`O_CREAT|O_EXCL` semantics via
/// `OpenOptions::create_new`). No `tempfile` crate needed (pure `std`).
pub fn file_temp_file<E: Send + From<String> + 'static>(prefix: String) -> SkyTask<E, String> {
    let result = make_temp_path(&prefix, false);
    match result {
        Ok(p) => Box::pin(ready(ok_res(p))),
        Err(e) => Box::pin(ready(SkyResult::Err(str_err(&e)))),
    }
}

/// `Sky.Core.File.tempDir : String -> Task Error String`
/// Create a uniquely-named directory in the system temp directory, using
/// `prefix` as the directory name prefix. Returns the absolute path.
/// The caller is responsible for removing the directory when done.
pub fn file_temp_dir<E: Send + From<String> + 'static>(prefix: String) -> SkyTask<E, String> {
    let result = make_temp_path(&prefix, true);
    match result {
        Ok(p) => Box::pin(ready(ok_res(p))),
        Err(e) => Box::pin(ready(SkyResult::Err(str_err(&e)))),
    }
}

/// Shared helper: create a uniquely-named file (`is_dir=false`) or directory
/// (`is_dir=true`) in the system temp directory, returning its absolute path.
///
/// Uses a monotonic-time nanos + process-ID suffix and retries up to 32 times
/// to get an exclusive slot (the same approach libc tempfile() uses).  No
/// external crate needed.
fn make_temp_path(prefix: &str, is_dir: bool) -> Result<String, String> {
    use std::time::{SystemTime, UNIX_EPOCH};
    let base = std::env::temp_dir();
    let pid = std::process::id();
    // Retry loop: collision is extremely rare but theoretically possible.
    for attempt in 0u32..32 {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or(attempt);
        let name = format!("{}{}{:08x}{:04x}", prefix, pid, nanos, attempt);
        let path = base.join(&name);
        if is_dir {
            match std::fs::create_dir(&path) {
                Ok(_) => return Ok(path.to_string_lossy().into_owned()),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(format!("{}", e)),
            }
        } else {
            match std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&path)
            {
                Ok(_) => return Ok(path.to_string_lossy().into_owned()),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(format!("{}", e)),
            }
        }
    }
    Err("could not create a unique temporary path after 32 attempts".to_string())
}

// ─── Copy / rename ─────────────────────────────────────────────────────────

/// `Sky.Core.File.copy : String -> String -> Task Error ()`
/// Copy the file at `src` to `dst`, creating or overwriting `dst`.
/// Mirrors Go's `io.Copy(out, in)` pattern.
pub fn file_copy<E: Send + From<String> + 'static>(src: String, dst: String) -> SkyTask<E, ()> {
    let result = std::fs::copy(&src, &dst)
        .map(|_| ())
        .map_err(|e| format!("{}", e));
    match result {
        Ok(_) => Box::pin(ready(ok_res(()))),
        Err(e) => Box::pin(ready(SkyResult::Err(str_err(&e)))),
    }
}

/// `Sky.Core.File.rename : String -> String -> Task Error ()`
/// Rename (move) the file or directory at `src` to `dst`.
/// Mirrors Go's `os.Rename`.
pub fn file_rename<E: Send + From<String> + 'static>(src: String, dst: String) -> SkyTask<E, ()> {
    match std::fs::rename(&src, &dst) {
        Ok(_) => Box::pin(ready(ok_res(()))),
        Err(e) => Box::pin(ready(SkyResult::Err(str_err(&format!("{}", e))))),
    }
}
