//! Sky.Core.List additions beyond what core.rs already provides.
//!
//! Sub-A.8 T7.

use super::SkyMaybe;

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
        let result = list_filter_map(|x| SkyMaybe::Just(x), xs);
        assert!(result.is_empty());
    }
}
