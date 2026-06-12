//! Sky.Core.Dict kernels backed by `std::collections::HashMap<K, V>`.
//!
//! Generic over the KEY type so a `Dict Int v` (chess board keyed by square
//! index, histogram counts, …) maps to `HashMap<i64, V>` and a `Dict String v`
//! to `HashMap<String, V>`. Keys are `Ord` for the deterministic sorted
//! iteration Sky guarantees; `Hash + Eq` for the map ops. Codegen emits the
//! key type from the `Dict k v` annotation (TypeRenderer renders `HashMap<k,v>`;
//! empty-dict turbofish pins both K and V from the expected type). The
//! `SkyDict<T>` alias stays for the String-keyed runtime structs (db rows).

use super::SkyMaybe;
use std::collections::HashMap;
use std::hash::Hash;

pub type SkyDict<T> = HashMap<String, T>;

/// `Dict.empty : Dict k v`.
pub fn dict_empty<K, V>() -> HashMap<K, V> { HashMap::new() }

/// `Dict.insert : k -> v -> Dict k v -> Dict k v`.
/// Functional update — the input dict is consumed and the modified copy returned.
pub fn dict_insert<K: Hash + Eq, V>(k: K, v: V, d: HashMap<K, V>) -> HashMap<K, V> {
    let mut d = d;
    d.insert(k, v);
    d
}

/// `Dict.get : k -> Dict k v -> Maybe v`.
pub fn dict_get<K: Hash + Eq, V: Clone>(k: K, d: HashMap<K, V>) -> SkyMaybe<V> {
    match d.get(&k) {
        Some(v) => SkyMaybe::Just(v.clone()),
        None    => SkyMaybe::Nothing,
    }
}

/// `Dict.keys : Dict k v -> List k`. Returns keys in sorted order so
/// iteration is deterministic (matches Sky's _fieldIndex emission contract).
pub fn dict_keys<K: Ord, V>(d: HashMap<K, V>) -> Vec<K> {
    let mut keys: Vec<K> = d.into_keys().collect();
    keys.sort();
    keys
}

/// `Dict.values : Dict k v -> List v`. Key-sorted for determinism, matching
/// `dict_keys` (Sky Dicts iterate in sorted-key order).
pub fn dict_values<K: Ord, V: Clone>(d: HashMap<K, V>) -> Vec<V> {
    let mut pairs: Vec<(K, V)> = d.into_iter().collect();
    pairs.sort_by(|a, b| a.0.cmp(&b.0));
    pairs.into_iter().map(|(_, v)| v).collect()
}

/// `Dict.toList : Dict k v -> List (k, v)`. Key-sorted for determinism,
/// matching `dict_keys` / `dict_values` (Sky Dicts iterate in sorted-key order).
pub fn dict_to_list<K: Ord, V: Clone>(d: HashMap<K, V>) -> Vec<(K, V)> {
    let mut pairs: Vec<(K, V)> = d.into_iter().collect();
    pairs.sort_by(|a, b| a.0.cmp(&b.0));
    pairs
}

/// `Dict.remove : k -> Dict k v -> Dict k v`.
pub fn dict_remove<K: Hash + Eq, V>(k: K, d: HashMap<K, V>) -> HashMap<K, V> {
    let mut d = d;
    d.remove(&k);
    d
}

/// `Dict.member : k -> Dict k v -> Bool`.
pub fn dict_member<K: Hash + Eq, V>(k: K, d: HashMap<K, V>) -> bool {
    d.contains_key(&k)
}

/// `Dict.fromList : List (k, v) -> Dict k v`.
pub fn dict_from_list<K: Hash + Eq, V>(pairs: Vec<(K, V)>) -> HashMap<K, V> {
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
        let mut d: SkyDict<i64> = dict_empty();
        d = dict_insert("c".into(), 3, d);
        d = dict_insert("a".into(), 1, d);
        d = dict_insert("b".into(), 2, d);
        assert_eq!(dict_keys(d), vec!["a".to_string(), "b".into(), "c".into()]);
    }

    #[test]
    fn test_dict_remove_and_member() {
        let mut d: SkyDict<i64> = dict_empty();
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
