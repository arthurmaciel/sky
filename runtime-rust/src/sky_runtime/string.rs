//! Sky.Core.String kernel — the single home for the String runtime surface.
//!
//! Argument order matches the Go runtime's typed kernels
//! (runtime-go/rt/rt.go: String_replace / String_startsWith / etc.).

use super::SkyMaybe;

// ── Core String kernels (relocated from core.rs so the String surface has one home) ──

pub fn string_from_int(i: i64) -> String { format!("{}", i) }
pub fn string_join(sep: String, strs: Vec<String>) -> String { strs.join(&sep) }
pub fn string_append(a: String, b: String) -> String { a + &b }
pub fn string_length(s: String) -> i64 { s.len() as i64 }
pub fn string_is_empty(s: String) -> bool { s.is_empty() }
pub fn string_reverse(s: String) -> String { s.chars().rev().collect() }
pub fn string_to_upper(s: String) -> String { s.to_uppercase() }
pub fn string_to_lower(s: String) -> String { s.to_lowercase() }
pub fn string_trim(s: String) -> String { s.trim().to_string() }
// Sky `contains : String -> String -> Bool  -- contains sub str` (str contains
// sub). Args arrive as (sub, str), so test the SECOND against the first.
pub fn string_contains(sub: String, s: String) -> bool { s.contains(&sub) }
pub fn string_to_int(s: String) -> SkyMaybe<i64> {
    match s.parse::<i64>() { Ok(v) => SkyMaybe::Just(v), Err(_) => SkyMaybe::Nothing }
}
/// `String.toFloat : String -> Maybe Float`. Mirrors string_to_int.
pub fn string_to_float(s: String) -> SkyMaybe<f64> {
    match s.parse::<f64>() { Ok(v) => SkyMaybe::Just(v), Err(_) => SkyMaybe::Nothing }
}
/// `String.fromChar : Char -> String`.
pub fn string_from_char(c: char) -> String { c.to_string() }
/// `String.slice : Int -> Int -> String -> String`. Char(rune)-indexed with
/// negative-index-from-end + clamping — parity with Go's `String_sliceT`.
pub fn string_slice(start: i64, end: i64, s: String) -> String {
    let runes: Vec<char> = s.chars().collect();
    let total = runes.len() as i64;
    let mut start = if start < 0 { start + total } else { start };
    let mut end = if end < 0 { end + total } else { end };
    if start < 0 { start = 0; }
    if end > total { end = total; }
    if start > end { return String::new(); }
    // start/end are clamped to [0, total] with start <= end, so the slice is
    // valid; `.get` keeps it total regardless.
    runes
        .get(start as usize..end as usize)
        .map(|r| r.iter().collect())
        .unwrap_or_default()
}
/// `Sky.Core.String.left n s` — the first `n` characters (clamped; negative → "").
pub fn string_left(n: i64, s: String) -> String {
    if n <= 0 {
        return String::new();
    }
    s.chars().take(n as usize).collect()
}
/// `Sky.Core.String.right n s` — the last `n` characters (clamped).
pub fn string_right(n: i64, s: String) -> String {
    if n <= 0 {
        return String::new();
    }
    let runes: Vec<char> = s.chars().collect();
    let start = runes.len().saturating_sub(n as usize);
    runes.get(start..).map(|r| r.iter().collect()).unwrap_or_default()
}
pub fn string_from_float(f: f64) -> String { format!("{}", f) }
pub fn string_split(sep: String, s: String) -> Vec<String> { s.split(&sep).map(|x| x.to_string()).collect() }
// Sky.Core.String.lines / .words — split on line breaks / runs of whitespace.
pub fn string_lines(s: String) -> Vec<String> { s.lines().map(|x| x.to_string()).collect() }
pub fn string_words(s: String) -> Vec<String> { s.split_whitespace().map(|x| x.to_string()).collect() }

// ── String kernels with Go-typed argument order ──

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
