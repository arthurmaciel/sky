//! Sky Runtime for Rust — single source of truth for Sky→Rust codegen.
//!
//! The `sky_runtime` module is copied into generated projects at build time.
//! Builder.hs emits `mod sky_runtime; use sky_runtime::*;` instead of
//! duplicating these definitions inline.
//!
//! This `lib.rs` is for standalone testing (`cargo test`).

pub mod sky_runtime;
pub use sky_runtime::*;

// ============================================================================
// Tests (re-exported for `cargo test` coverage)
// ============================================================================
#[cfg(test)]
mod tests {
    use super::*;

    // SkyResult tests
    #[test]
    fn result_ok() {
        let r: SkyResult<&str, i64> = SkyResult::Ok(42);
        assert!(r.is_ok());
        assert_eq!(r.with_default(0), 42);
    }

    #[test]
    fn result_err() {
        let r: SkyResult<&str, i64> = SkyResult::Err("error");
        assert!(r.is_err());
        assert_eq!(r.with_default(0), 0);
    }

    #[test]
    fn result_map_ok() {
        let r: SkyResult<&str, i64> = SkyResult::Ok(5);
        let mapped = sky_result_map(r, |x| x * 2);
        assert_eq!(mapped.with_default(0), 10);
    }

    #[test]
    fn result_map_err() {
        let r: SkyResult<&str, i64> = SkyResult::Err("error");
        let mapped: SkyResult<&str, i64> = sky_result_map(r, |x| x * 2);
        assert!(mapped.is_err());
    }

    #[test]
    fn result_and_then_ok() {
        let r: SkyResult<&str, i64> = SkyResult::Ok(5);
        let chained = sky_result_and_then(r, |x| SkyResult::Ok(x * 2));
        assert_eq!(chained.with_default(0), 10);
    }

    #[test]
    fn result_and_then_err() {
        let r: SkyResult<&str, i64> = SkyResult::Err("e");
        let chained = sky_result_and_then(r, |x: i64| SkyResult::Ok(x * 2));
        assert!(chained.is_err());
    }

    // SkyMaybe tests
    #[test]
    fn maybe_just() {
        let m: SkyMaybe<i64> = SkyMaybe::Just(42);
        assert!(m.is_just());
        assert_eq!(m.with_default(0), 42);
    }

    #[test]
    fn maybe_nothing() {
        let m: SkyMaybe<i64> = SkyMaybe::Nothing;
        assert!(m.is_nothing());
        assert_eq!(m.with_default(99), 99);
    }

    #[test]
    fn maybe_map_just() {
        let m: SkyMaybe<i64> = SkyMaybe::Just(5);
        let mapped = sky_maybe_map(m, |x| x * 2);
        assert_eq!(mapped.with_default(0), 10);
    }

    #[test]
    fn maybe_and_then_just() {
        let m: SkyMaybe<i64> = SkyMaybe::Just(5);
        let chained = sky_maybe_and_then(m, |x| SkyMaybe::Just(x * 2));
        assert_eq!(chained.with_default(0), 10);
    }

    // List tests
    #[test]
    fn list_is_empty() {
        assert!(sky_list_is_empty(&Vec::<i64>::new()));
        assert!(!sky_list_is_empty(&vec![1]));
    }

    #[test]
    fn list_head() {
        assert_eq!(sky_list_head(&vec![1, 2, 3]).with_default(0), 1);
        assert!(matches!(sky_list_head::<i64>(&vec![]), SkyMaybe::Nothing));
    }

    #[test]
    fn list_map() {
        assert_eq!(sky_list_map(|x| x * 2, &vec![1, 2, 3]), vec![2, 4, 6]);
    }

    #[test]
    fn list_filter() {
        assert_eq!(sky_list_filter(|x| *x % 2 == 0, &vec![1, 2, 3, 4]), vec![2, 4]);
    }

    #[test]
    fn list_fold() {
        assert_eq!(sky_list_fold(|acc, x| acc + x, 0, &vec![1, 2, 3]), 6);
    }

    // String tests
    #[test]
    fn string_ops() {
        assert_eq!(sky_string_append("a".into(), "b".into()), "ab");
        assert_eq!(sky_string_length("hello".into()), 5);
        assert!(sky_string_is_empty("".into()));
    }

    #[test]
    fn string_to_int_ok() {
        assert_eq!(string_to_int("42".into()), SkyMaybe::Just(42));
    }

    #[test]
    fn string_to_int_fail() {
        assert_eq!(string_to_int("abc".into()), SkyMaybe::Nothing);
    }

    // Result helpers
    #[test]
    fn result_with_default_ok() {
        let r: SkyResult<&str, i64> = SkyResult::Ok(42);
        assert_eq!(result_with_default(0)(r), 42);
    }

    #[test]
    fn result_traverse_ok() {
        let items = vec![1, 2, 3];
        let r = result_traverse(|x: i64| -> SkyResult<Error, i64> { SkyResult::Ok(x * 2) }, items);
        assert_eq!(r.with_default(vec![]), vec![2, 4, 6]);
    }

    // Task tests (basic, no tokio needed)
    #[tokio::test]
    async fn task_succeed_await() {
        let t = task_succeed(42);
        let r = t.await;
        assert_eq!(r.with_default(0), 42);
    }

    #[tokio::test]
    async fn task_sequence_ok() {
        let tasks = vec![task_succeed(1), task_succeed(2)];
        let r = task_sequence(tasks).await;
        assert_eq!(r.with_default(vec![]), vec![1, 2]);
    }
}
