//! Regex kernels for Sky.Core.Regex. Invalid patterns NEVER panic — they
//! return identity / false / empty / Nothing per the Sky stdlib contract.

use super::SkyMaybe;
use regex::Regex;

/// Sky `match : String -> String -> Bool`. Pattern first, then haystack.
pub fn regex_match(pattern: String, s: String) -> bool {
    match Regex::new(&pattern) {
        Ok(re) => re.is_match(&s),
        Err(_) => false,
    }
}

/// Sky `find : String -> String -> Maybe String`
pub fn regex_find(pattern: String, s: String) -> SkyMaybe<String> {
    match Regex::new(&pattern) {
        Ok(re) => match re.find(&s) {
            Some(m) => SkyMaybe::Just(m.as_str().to_string()),
            None => SkyMaybe::Nothing,
        },
        Err(_) => SkyMaybe::Nothing,
    }
}

/// Sky `findAll : String -> String -> List String`
pub fn regex_find_all(pattern: String, s: String) -> Vec<String> {
    match Regex::new(&pattern) {
        Ok(re) => re.find_iter(&s).map(|m| m.as_str().to_string()).collect(),
        Err(_) => Vec::new(),
    }
}

/// Sky `replace : String -> String -> String -> String` (pattern, replacement, input).
pub fn regex_replace(pattern: String, replacement: String, s: String) -> String {
    match Regex::new(&pattern) {
        Ok(re) => re.replace_all(&s, replacement.as_str()).to_string(),
        Err(_) => s,
    }
}

/// Sky `split : String -> String -> List String`
pub fn regex_split(pattern: String, s: String) -> Vec<String> {
    match Regex::new(&pattern) {
        Ok(re) => re.split(&s).map(|x| x.to_string()).collect(),
        Err(_) => vec![s],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_match() {
        assert!(regex_match(r"^\d+$".to_string(), "12345".to_string()));
        assert!(!regex_match(r"^\d+$".to_string(), "abc".to_string()));
        // Invalid pattern -> false (never panic)
        assert!(!regex_match(r"[unclosed".to_string(), "anything".to_string()));
    }

    #[test]
    fn test_find() {
        let m = regex_find(r"\d+".to_string(), "foo 42 bar".to_string());
        assert!(matches!(m, SkyMaybe::Just(ref s) if s == "42"));
        let none = regex_find(r"\d+".to_string(), "no digits here".to_string());
        assert!(matches!(none, SkyMaybe::Nothing));
        // Invalid pattern -> Nothing
        let bad = regex_find(r"[unclosed".to_string(), "x".to_string());
        assert!(matches!(bad, SkyMaybe::Nothing));
    }

    #[test]
    fn test_find_all() {
        let all = regex_find_all(r"\d+".to_string(), "1 and 22 and 333".to_string());
        assert_eq!(all, vec!["1".to_string(), "22".to_string(), "333".to_string()]);
        // Invalid pattern -> empty
        let bad = regex_find_all(r"[unclosed".to_string(), "1 2 3".to_string());
        assert!(bad.is_empty());
    }

    #[test]
    fn test_replace() {
        let r = regex_replace(r"\d+".to_string(), "N".to_string(), "a1b2c3".to_string());
        assert_eq!(r, "aNbNcN");
        // Invalid pattern -> identity (input unchanged)
        let bad = regex_replace(r"[unclosed".to_string(), "X".to_string(), "abc".to_string());
        assert_eq!(bad, "abc");
    }

    #[test]
    fn test_split() {
        let parts = regex_split(r",\s*".to_string(), "a, b,c,  d".to_string());
        assert_eq!(parts, vec!["a", "b", "c", "d"]);
        // Invalid pattern -> single-element list with the original string
        let bad = regex_split(r"[unclosed".to_string(), "abc".to_string());
        assert_eq!(bad, vec!["abc".to_string()]);
    }
}
