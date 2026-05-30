//! Sky.Core.String additions beyond what core.rs already provides.
//!
//! Sub-A.8 T6. Argument order matches the Go runtime's typed kernels
//! (runtime-go/rt/rt.go: String_replace / String_startsWith / etc.).

/// Sky `replace : String -> String -> String -> String`.
/// Replaces all occurrences of `old` with `new_` in `s`.
pub fn string_replace(old: String, new_: String, s: String) -> String {
    s.replace(&old, &new_)
}

/// Sky `startsWith : String -> String -> Bool`. `prefix` first, `s` second.
pub fn string_starts_with(prefix: String, s: String) -> bool {
    s.starts_with(&prefix)
}

/// Sky `endsWith : String -> String -> Bool`. `suffix` first, `s` second.
pub fn string_ends_with(suffix: String, s: String) -> bool {
    s.ends_with(&suffix)
}

/// Sky `repeat : Int -> String -> String`. Non-positive `n` returns "".
pub fn string_repeat(n: i64, s: String) -> String {
    if n <= 0 { String::new() } else { s.repeat(n as usize) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test] fn test_replace_simple() { assert_eq!(string_replace("foo".into(), "bar".into(), "foofoo".into()), "barbar"); }
    #[test] fn test_replace_no_match() { assert_eq!(string_replace("x".into(), "y".into(), "abc".into()), "abc"); }
    #[test] fn test_replace_empty_old() { assert_eq!(string_replace("".into(), "_".into(), "abc".into()), "_a_b_c_"); }

    #[test] fn test_starts_with_hit() { assert!(string_starts_with("he".into(), "hello".into())); }
    #[test] fn test_starts_with_miss() { assert!(!string_starts_with("xy".into(), "hello".into())); }
    #[test] fn test_starts_with_empty_prefix() { assert!(string_starts_with("".into(), "hello".into())); }

    #[test] fn test_ends_with_hit() { assert!(string_ends_with("lo".into(), "hello".into())); }
    #[test] fn test_ends_with_miss() { assert!(!string_ends_with("xy".into(), "hello".into())); }

    #[test] fn test_repeat_three() { assert_eq!(string_repeat(3, "ab".into()), "ababab"); }
    #[test] fn test_repeat_zero() { assert_eq!(string_repeat(0, "ab".into()), ""); }
    #[test] fn test_repeat_negative() { assert_eq!(string_repeat(-1, "ab".into()), ""); }
}
