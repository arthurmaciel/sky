//! Sky.Core.List kernel — the single home for the List runtime surface.

use super::SkyMaybe;

/// `Sky.Core.List.length` — element count (kernel-routed call sites; the pure-Sky
/// `sky_core_list_length` is the recursive stdlib form).
pub fn list_length<T>(xs: Vec<T>) -> i64 {
    xs.len() as i64
}

/// `Sky.Core.List.head : List a -> Maybe a` — the first element, or `Nothing`
/// on the empty list. Total (no indexing panic).
pub fn list_head<T>(xs: Vec<T>) -> SkyMaybe<T> {
    match xs.into_iter().next() {
        Some(x) => SkyMaybe::Just(x),
        None => SkyMaybe::Nothing,
    }
}

/// `Sky.Core.List.drop : Int -> List a -> List a` — drops the first `n`
/// elements. `n <= 0` keeps the whole list; `n >= len` yields `[]`. Total.
pub fn list_drop<T>(n: i64, xs: Vec<T>) -> Vec<T> {
    if n <= 0 {
        xs
    } else {
        xs.into_iter().skip(n as usize).collect()
    }
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
// No `T: Clone` bound — `once(x).chain(xs)` only MOVES, so cons works for
// move-only element types too (e.g. `Cmd.batch [SkyCmd, …]`; SkyCmd isn't Clone).
pub fn sky_list_cons<T>(x: T, xs: Vec<T>) -> Vec<T> {
    std::iter::once(x).chain(xs).collect()
}

pub fn list_foldl<T0, T1>(f: impl Fn(T0, T1) -> T1 + Clone, init: T1, list: Vec<T0>) -> T1 {
    let mut acc = init;
    for item in list { acc = f(item, acc); }
    acc
}
pub fn list_foldr<T0, T1>(f: impl Fn(T0, T1) -> T1 + Clone, init: T1, list: Vec<T0>) -> T1 {
    let mut acc = init;
    // `into_iter().rev()` yields OWNED items, so no clone (and no `T0: Clone`
    // bound) is needed — matching `sky_list_cons`'s move-only-friendly shape.
    for item in list.into_iter().rev() { acc = f(item, acc); }
    acc
}
// Sky `List.range` is INCLUSIVE: range 1 3 = [1, 2, 3].
pub fn list_range(lo: i64, hi: i64) -> Vec<i64> {
    if hi < lo { return Vec::new(); }
    // Bound the allocation: lo/hi are caller-controlled; an absurd span (e.g.
    // 0..i64::MAX) would OOM. Cap at 10M elements (any real list is far smaller).
    let n = (hi as i128) - (lo as i128) + 1;
    if n > 10_000_000 { return Vec::new(); }
    (lo..=hi).collect()
}
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

// ── Sorting (mirrors Go's List_sort / List_sortBy; sortWith added for Rust) ──
//
// All three are STABLE (Rust's `Vec::sort_by` / `sort_by_key` are stable, matching
// Go's `sort.SliceStable`). None can panic on well-typed input: ordering is total
// (`total_cmp` via `cmp_total`), so a NaN key never trips the `Ord` contract the
// way a naive `partial_cmp().unwrap()` would.

/// Total ordering for any `PartialOrd` element. `partial_cmp` only returns `None`
/// for incomparable values (e.g. floating-point NaN); we map that to `Equal` so the
/// sort comparator stays a valid total order and never panics. For Sky's
/// `comparable` (Int / Float / Char / String / and tuples/lists thereof) the only
/// `None` case is NaN, which Sky code can't construct from a literal anyway.
fn cmp_total<T: PartialOrd>(a: &T, b: &T) -> std::cmp::Ordering {
    a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal)
}

/// `Sky.Core.List.sort : List comparable -> List comparable` — stable ascending
/// sort by the element's natural order. Total (no panic on NaN).
pub fn list_sort<T: PartialOrd>(list: Vec<T>) -> Vec<T> {
    let mut result = list;
    result.sort_by(cmp_total);
    result
}

/// `Sky.Core.List.sortBy : (a -> comparable) -> List a -> List a` — stable sort by
/// the `keyFn elem` projection. Decorate-sort-undecorate: `keyFn` is applied
/// exactly once per element (no repeated key recomputation during comparison).
/// `A: Clone` because the Sky closure ABI takes its element by value — same bound
/// `list_filter` already carries for its predicate.
pub fn list_sort_by<A: Clone, B: PartialOrd>(key_fn: impl Fn(A) -> B, list: Vec<A>) -> Vec<A> {
    // Decorate: compute each key once, pairing it with its element. The key fn
    // consumes its argument (owned ABI), so clone the element for the key call
    // and keep the original to emit after the sort.
    let mut decorated: Vec<(B, A)> =
        list.into_iter().map(|x| (key_fn(x.clone()), x)).collect();
    // Stable sort on the key only (so equal keys preserve input order).
    decorated.sort_by(|a, b| cmp_total(&a.0, &b.0));
    // Undecorate.
    decorated.into_iter().map(|(_, x)| x).collect()
}

/// `Sky.Core.List.sortWith : (a -> a -> Int) -> List a -> List a` — stable sort by
/// a user comparator returning a Sky `Int` (negative → first arg orders before the
/// second, zero → equal, positive → after; matching `Basics.compare`'s -1/0/+1).
/// The comparator takes its two elements by value (the Sky closure ABI), so `a`
/// must be `Clone`. The `Int` → `Ordering` map is total — every `i64` lands in
/// exactly one of Less / Equal / Greater.
pub fn list_sort_with<A: Clone>(cmp: impl Fn(A, A) -> i64, list: Vec<A>) -> Vec<A> {
    let mut result = list;
    result.sort_by(|a, b| {
        let ord = cmp(a.clone(), b.clone());
        ord.cmp(&0)
    });
    result
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

    #[test]
    fn test_sort_ints() {
        assert_eq!(list_sort(vec![3i64, 1, 2]), vec![1i64, 2, 3]);
        assert_eq!(list_sort(Vec::<i64>::new()), Vec::<i64>::new());
    }

    #[test]
    fn test_sort_strings() {
        assert_eq!(
            list_sort(vec!["banana".to_string(), "apple".into(), "cherry".into()]),
            vec!["apple".to_string(), "banana".into(), "cherry".into()]
        );
    }

    #[test]
    fn test_sort_floats_with_nan_no_panic() {
        // NaN must not panic the comparator (total order falls back to Equal).
        let r = list_sort(vec![3.0f64, f64::NAN, 1.0]);
        assert_eq!(r.len(), 3);
    }

    #[test]
    fn test_sort_by_key_applied_once_and_stable() {
        // sortBy String.length — stable: equal-length keep input order.
        let r = list_sort_by(|s: String| s.len() as i64, vec![
            "ccc".to_string(), "a".into(), "bb".into(), "dd".into(),
        ]);
        assert_eq!(r, vec!["a".to_string(), "bb".into(), "dd".into(), "ccc".into()]);
    }

    #[test]
    fn test_sort_with_reverse() {
        // Comparator b - a → descending.
        let r = list_sort_with(|a: i64, b: i64| b - a, vec![1i64, 3, 2]);
        assert_eq!(r, vec![3i64, 2, 1]);
    }

    #[test]
    fn test_sort_with_stable_on_equal() {
        // All-equal comparator preserves input order (stable).
        let r = list_sort_with(|_a: i64, _b: i64| 0, vec![3i64, 1, 2]);
        assert_eq!(r, vec![3i64, 1, 2]);
    }
}
