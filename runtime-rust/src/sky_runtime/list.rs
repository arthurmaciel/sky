//! Sky.Core.List kernel — the single home for the List runtime surface.

use super::SkyMaybe;

/// `Sky.Core.List.length` — element count (kernel-routed call sites; the pure-Sky
/// `sky_core_list_length` is the recursive stdlib form).
pub fn list_length<T>(xs: Vec<T>) -> i64 {
    xs.len() as i64
}

/// Sky `filterMap : (a -> Maybe b) -> List a -> List b`.
/// Applies `f` to each element; keeps only `Just` results.
pub fn list_filter_map<A, B>(f: impl Fn(A) -> SkyMaybe<B>, xs: Vec<A>) -> Vec<B> {
    xs.into_iter()
        .filter_map(|x| match f(x) {
            SkyMaybe::Just(v)  => Some(v),
            SkyMaybe::Nothing  => None,
        })
        .collect()
}

// ── Core List kernels (relocated from core.rs so the List surface has one home) ──

/// Sky `::` cons — emitted by codegen for the cons operator.
pub fn sky_list_cons<T: Clone>(x: T, xs: Vec<T>) -> Vec<T> {
    std::iter::once(x).chain(xs).collect()
}

pub fn list_foldl<T0, T1>(f: impl Fn(T0, T1) -> T1 + Clone, init: T1, list: Vec<T0>) -> T1 {
    let mut acc = init;
    for item in list { acc = f(item, acc); }
    acc
}
pub fn list_foldr<T0: Clone, T1>(f: impl Fn(T0, T1) -> T1 + Clone, init: T1, list: Vec<T0>) -> T1 {
    let mut acc = init;
    for item in list.into_iter().rev() { acc = f(item.clone(), acc); }
    acc
}
// Sky `List.range` is INCLUSIVE: range 1 3 = [1, 2, 3].
pub fn list_range(lo: i64, hi: i64) -> Vec<i64> { (lo..=hi).collect() }
pub fn list_indexed_map<T0, T1>(f: impl Fn(i64, T0) -> T1 + Clone, list: Vec<T0>) -> Vec<T1> {
    list.into_iter().enumerate().map(|(i, x)| f(i as i64, x)).collect()
}
pub fn list_concat_map<T0, T1>(f: impl Fn(T0) -> Vec<T1> + Clone, list: Vec<T0>) -> Vec<T1> {
    list.into_iter().flat_map(f).collect()
}
pub fn list_zip<T0, T1>(a: Vec<T0>, b: Vec<T1>) -> Vec<(T0, T1)> {
    a.into_iter().zip(b).collect()
}
pub fn list_filter<T0: Clone>(f: impl Fn(T0) -> bool + Clone, list: Vec<T0>) -> Vec<T0> {
    list.into_iter().filter(|x| f(x.clone())).collect()
}
pub fn list_member<T0: PartialEq>(x: T0, list: Vec<T0>) -> bool {
    list.contains(&x)
}
pub fn list_any<T0>(f: impl Fn(T0) -> bool + Clone, list: Vec<T0>) -> bool {
    list.into_iter().any(f)
}
pub fn list_all<T0>(f: impl Fn(T0) -> bool + Clone, list: Vec<T0>) -> bool {
    list.into_iter().all(f)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_filter_map_doubles_evens() {
        let xs: Vec<i64> = vec![1, 2, 3, 4];
        let result = list_filter_map(
            |x| if x % 2 == 0 { SkyMaybe::Just(x * 2) } else { SkyMaybe::Nothing },
            xs,
        );
        assert_eq!(result, vec![4i64, 8]);
    }

    #[test]
    fn test_filter_map_all_nothing() {
        let xs: Vec<i64> = vec![1, 2, 3];
        let result = list_filter_map(|_: i64| SkyMaybe::<i64>::Nothing, xs);
        assert!(result.is_empty());
    }

    #[test]
    fn test_filter_map_all_just() {
        let xs: Vec<i64> = vec![1, 2, 3];
        let result = list_filter_map(|x| SkyMaybe::Just(x + 10), xs);
        assert_eq!(result, vec![11i64, 12, 13]);
    }

    #[test]
    fn test_filter_map_empty() {
        let xs: Vec<i64> = vec![];
        let result = list_filter_map(SkyMaybe::Just, xs);
        assert!(result.is_empty());
    }
}
