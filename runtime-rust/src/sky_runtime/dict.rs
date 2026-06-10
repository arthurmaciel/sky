//! Sky.Core.Dict kernels backed by `std::collections::HashMap<String, T>`.
//!
//! Per CLAUDE.md Limitation #5, Sky's Dict is *runtime-keyed by String*
//! even when the type system says `Dict k v` for arbitrary `k`. The Go
//! runtime coerces keys to String via `fmt.Sprintf("%v", k)`. The Rust
//! port specializes to `String`-keyed (codegen will only emit calls with
//! String args anyway). This matches the runtime contract.

use super::SkyMaybe;
use std::collections::HashMap;

pub type SkyDict<T> = HashMap<String, T>;

/// `Dict.empty : Dict k v`.
pub fn dict_empty<T>() -> SkyDict<T> { HashMap::new() }

/// `Dict.insert : k -> v -> Dict k v -> Dict k v`.
/// Functional update — the input dict is consumed and the modified copy returned.
pub fn dict_insert<T: Clone>(k: String, v: T, d: SkyDict<T>) -> SkyDict<T> {
    let mut d = d;
    d.insert(k, v);
    d
}

/// `Dict.get : k -> Dict k v -> Maybe v`.
pub fn dict_get<T: Clone>(k: String, d: SkyDict<T>) -> SkyMaybe<T> {
    match d.get(&k) {
        Some(v) => SkyMaybe::Just(v.clone()),
        None    => SkyMaybe::Nothing,
    }
}

/// `Dict.keys : Dict k v -> List k`. Returns keys in sorted order so
/// iteration is deterministic (matches Sky's _fieldIndex emission contract).
pub fn dict_keys<T>(d: SkyDict<T>) -> Vec<String> {
    let mut keys: Vec<String> = d.into_keys().collect();
    keys.sort();
    keys
}

/// `Dict.values : Dict k v -> List v`. Key-sorted for determinism, matching
/// `dict_keys` (Sky Dicts iterate in sorted-key order).
pub fn dict_values<T: Clone>(d: SkyDict<T>) -> Vec<T> {
    let mut pairs: Vec<(String, T)> = d.into_iter().collect();
    pairs.sort_by(|a, b| a.0.cmp(&b.0));
    pairs.into_iter().map(|(_, v)| v).collect()
}

/// `Dict.remove : k -> Dict k v -> Dict k v`.
pub fn dict_remove<T: Clone>(k: String, d: SkyDict<T>) -> SkyDict<T> {
    let mut d = d;
    d.remove(&k);
    d
}

/// `Dict.member : k -> Dict k v -> Bool`.
pub fn dict_member<T>(k: String, d: SkyDict<T>) -> bool {
    d.contains_key(&k)
}

/// `Dict.fromList : List (k, v) -> Dict k v`. String keys per Limitation #5.
pub fn dict_from_list<T>(pairs: Vec<(String, T)>) -> SkyDict<T> {
    pairs.into_iter().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_dict_insert_get_roundtrip() {
        let d: SkyDict<i64> = dict_empty();
        let d = dict_insert("a".into(), 1, d);
        let d = dict_insert("b".into(), 2, d);
        match dict_get("a".into(), d.clone()) {
            SkyMaybe::Just(v) => assert_eq!(v, 1),
            SkyMaybe::Nothing => panic!("missing"),
        }
        match dict_get("b".into(), d.clone()) {
            SkyMaybe::Just(v) => assert_eq!(v, 2),
            SkyMaybe::Nothing => panic!("missing"),
        }
        match dict_get("missing".into(), d) {
            SkyMaybe::Just(_) => panic!("should be Nothing"),
            SkyMaybe::Nothing => (),
        }
    }

    #[test]
    fn test_dict_keys_sorted() {
        let mut d = dict_empty();
        d = dict_insert("c".into(), 3, d);
        d = dict_insert("a".into(), 1, d);
        d = dict_insert("b".into(), 2, d);
        assert_eq!(dict_keys(d), vec!["a".to_string(), "b".into(), "c".into()]);
    }

    #[test]
    fn test_dict_remove_and_member() {
        let mut d = dict_empty();
        d = dict_insert("x".into(), 10, d);
        assert!(dict_member("x".into(), d.clone()));
        let d = dict_remove("x".into(), d);
        assert!(!dict_member("x".into(), d));
    }

    #[test]
    fn test_dict_empty_keys() {
        let d: SkyDict<i64> = dict_empty();
        assert!(dict_keys(d).is_empty());
    }
}
