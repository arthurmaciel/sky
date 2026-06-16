// Path kernel stubs — pure string manipulation, no filesystem I/O.
// All functions are total (never panic, no Task wrapper):
//   base, dir, ext : String -> String
//   isAbsolute     : String -> Bool
//
// Routing (Kernel.hs fallthrough — all map cleanly via toSnakeCase):
//   ("Path", "base")       / ("Sky.Core.Path", "base")       -> "path_base"
//   ("Path", "dir")        / ("Sky.Core.Path", "dir")        -> "path_dir"
//   ("Path", "ext")        / ("Sky.Core.Path", "ext")        -> "path_ext"
//   ("Path", "isAbsolute") / ("Sky.Core.Path", "isAbsolute") -> "path_is_absolute"

/// `Sky.Core.Path.base : String -> String`
/// Return the last element of the path (the file name including extension).
/// Mirrors Go's `filepath.Base`:
/// - empty string  → "."
/// - "/" or "C:\"  → "/" or "\" (root)
/// - otherwise     → the component after the last separator
///
/// Implemented via `std::path::Path::file_name`, falling back to the full
/// path string when the OS considers it a root (no file_name component).
pub fn path_base(path: String) -> String {
    let p = std::path::Path::new(&path);
    // file_name() returns None for paths that end in ".." or are root.
    // Mirrors Go: filepath.Base("") = ".", filepath.Base("/") = "/".
    if path.is_empty() {
        return ".".to_string();
    }
    match p.file_name() {
        Some(name) => name.to_string_lossy().into_owned(),
        // Root path ("/") or parent-component-only ("..") — return the path itself,
        // matching Go's behaviour for these edge cases.
        None => path,
    }
}

/// `Sky.Core.Path.dir : String -> String`
/// Return all but the last element of the path (the directory component).
/// Mirrors Go's `filepath.Dir`:
/// - empty string → "."
/// - "/" → "/"
/// - "foo" (no separator) → "."
/// - "/foo/bar" → "/foo"
pub fn path_dir(path: String) -> String {
    if path.is_empty() {
        return ".".to_string();
    }
    let p = std::path::Path::new(&path);
    match p.parent() {
        // parent() of "/" is Some("") on Unix; treat as root.
        Some(parent) => {
            let s = parent.to_string_lossy();
            if s.is_empty() {
                // Occurs when path is a bare filename ("foo") — Go returns ".".
                // Also occurs for "/" on some platforms.
                if path.starts_with('/') || path.starts_with('\\') {
                    // Root separator — return the root.
                    s.into_owned()
                } else {
                    ".".to_string()
                }
            } else {
                s.into_owned()
            }
        }
        // No parent means path was already the root.
        None => path,
    }
}

/// `Sky.Core.Path.ext : String -> String`
/// Return the file-name extension, including the leading dot.
/// Returns an empty string when the file has no extension.
/// Mirrors Go's `filepath.Ext` (which includes the dot, e.g. ".txt").
pub fn path_ext(path: String) -> String {
    let p = std::path::Path::new(&path);
    match p.extension() {
        Some(ext) => format!(".{}", ext.to_string_lossy()),
        None => String::new(),
    }
}

/// `Sky.Core.Path.isAbsolute : String -> Bool`
/// Returns `true` when `path` is an absolute path.
/// Mirrors Go's `filepath.IsAbs`.
pub fn path_is_absolute(path: String) -> bool {
    std::path::Path::new(&path).is_absolute()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base_empty() {
        assert_eq!(path_base(String::new()), ".");
    }

    #[test]
    fn base_filename() {
        assert_eq!(path_base("/foo/bar.txt".to_string()), "bar.txt");
    }

    #[test]
    fn base_no_dir() {
        assert_eq!(path_base("hello.sky".to_string()), "hello.sky");
    }

    #[test]
    fn dir_empty() {
        assert_eq!(path_dir(String::new()), ".");
    }

    #[test]
    fn dir_with_parent() {
        assert_eq!(path_dir("/foo/bar.txt".to_string()), "/foo");
    }

    #[test]
    fn dir_bare_name() {
        assert_eq!(path_dir("hello.sky".to_string()), ".");
    }

    #[test]
    fn ext_present() {
        assert_eq!(path_ext("/foo/bar.txt".to_string()), ".txt");
    }

    #[test]
    fn ext_absent() {
        assert_eq!(path_ext("/foo/bar".to_string()), "");
    }

    #[test]
    fn is_absolute_true() {
        assert!(path_is_absolute("/usr/bin".to_string()));
    }

    #[test]
    fn is_absolute_false() {
        assert!(!path_is_absolute("relative/path".to_string()));
    }
}
