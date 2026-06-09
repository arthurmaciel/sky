//! Sky.Core.Char kernels — single-code-point helpers.
//!
//! A Sky `Char` lowers to a Rust `char` (one Unicode scalar value), so these
//! kernels take/return `char` directly — no `any` boxing. Mirrors the Go
//! runtime's `Char_*` functions (`runtime-go/rt/rt.go`):
//!
//! * `isAlpha` ← `unicode.IsLetter`  (Rust `char::is_alphabetic`)
//! * `isDigit` ← `unicode.IsDigit`   (Rust `char::is_numeric` — closest std
//!   match for the Nd category; diverges only on superscript/No code points,
//!   which no stdlib caller exercises)
//! * `toLower`/`toUpper` return a single-rune **String** (the kernel registry
//!   shape is `Char -> String`), matching Go's `string(unicode.ToLower(r))`.
//! * `fromCode` out of the valid scalar range (negative, > 0x10FFFF, or a
//!   surrogate D800–DFFF that `char` cannot hold) yields the Unicode
//!   replacement character `'\u{FFFD}'` — same contract as Go.

pub fn char_is_alpha(c: char) -> bool { c.is_alphabetic() }
pub fn char_is_digit(c: char) -> bool { c.is_numeric() }
pub fn char_is_lower(c: char) -> bool { c.is_lowercase() }
pub fn char_is_upper(c: char) -> bool { c.is_uppercase() }

pub fn char_to_lower(c: char) -> String { c.to_lowercase().to_string() }
pub fn char_to_upper(c: char) -> String { c.to_uppercase().to_string() }

/// `toCode 'A' -> 65` — the Unicode code point as an integer.
pub fn char_to_code(c: char) -> i64 { c as u32 as i64 }

/// `fromCode 65 -> 'A'`. Out-of-range / surrogate -> U+FFFD (matches Go).
pub fn char_from_code(n: i64) -> char {
    if !(0..=0x10FFFF).contains(&n) {
        return '\u{FFFD}';
    }
    char::from_u32(n as u32).unwrap_or('\u{FFFD}')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn predicates() {
        assert!(char_is_alpha('A'));
        assert!(!char_is_alpha('1'));
        assert!(char_is_digit('7'));
        assert!(!char_is_digit('A'));
        assert!(char_is_lower('a'));
        assert!(!char_is_lower('A'));
        assert!(char_is_upper('Z'));
        assert!(!char_is_upper('z'));
    }

    #[test]
    fn case_conversion_returns_string() {
        assert_eq!(char_to_lower('A'), "a");
        assert_eq!(char_to_upper('a'), "A");
    }

    #[test]
    fn code_roundtrip() {
        assert_eq!(char_to_code('A'), 65);
        assert_eq!(char_from_code(65), 'A');
        assert_eq!(char_from_code(0x1F600), '\u{1F600}'); // 😀
    }

    #[test]
    fn from_code_out_of_range_is_replacement() {
        assert_eq!(char_from_code(-1), '\u{FFFD}');
        assert_eq!(char_from_code(0x110000), '\u{FFFD}');
        assert_eq!(char_from_code(0xD800), '\u{FFFD}'); // lone surrogate
    }
}
