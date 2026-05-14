//! Sky Runtime for Rust - Minimal Core
//!
//! This crate provides the core primitives that the Sky→Rust transpiler
//! generates code against.

// ============================================================================
// Core Types - Direct wrappers around std types with proper ordering
// ============================================================================

/// Sky Result - error-first type like Haskell
/// Corresponds to Rust's Result<Ok, Err> but with Sky's error-first ordering
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SkyResult<E, A>(Result<A, E>);

impl<E, A> SkyResult<E, A> {
    pub fn ok(v: A) -> Self { SkyResult(Ok(v)) }
    pub fn err(e: E) -> Self { SkyResult(Err(e)) }
    pub fn map<B, F>(self, f: F) -> SkyResult<E, B> where F: FnOnce(A) -> B {
        SkyResult(self.0.map(f))
    }
    pub fn and_then<B, F>(self, f: F) -> SkyResult<E, B> where F: FnOnce(A) -> SkyResult<E, B> {
        match self.0 { Ok(a) => f(a), Err(e) => SkyResult(Err(e)) }
    }
    pub fn with_default(self, def: A) -> A { self.0.unwrap_or(def) }
    pub fn is_ok(&self) -> bool { self.0.is_ok() }
    pub fn is_err(&self) -> bool { self.0.is_err() }
    pub fn unwrap(self) -> A where E: std::fmt::Debug { self.0.unwrap() }
}

pub fn ok<E, A>(v: A) -> SkyResult<E, A> { SkyResult::ok(v) }
pub fn err<E, A>(e: E) -> SkyResult<E, A> { SkyResult::err(e) }
pub fn map_result<A, B, E, F>(r: SkyResult<E, A>, f: F) -> SkyResult<E, B> where F: FnOnce(A) -> B { r.map(f) }
pub fn and_then_result<E, A, B, F>(r: SkyResult<E, A>, f: F) -> SkyResult<E, B> where F: FnOnce(A) -> SkyResult<E, B> { r.and_then(f) }

/// Sky Maybe - corresponds to Rust Option
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SkyMaybe<T>(Option<T>);

impl<T> SkyMaybe<T> {
    pub fn just(v: T) -> Self { SkyMaybe(Some(v)) }
    pub fn nothing() -> Self { SkyMaybe(None) }
    pub fn map<U, F>(self, f: F) -> SkyMaybe<U> where F: FnOnce(T) -> U { SkyMaybe(self.0.map(f)) }
    pub fn and_then<U, F>(self, f: F) -> SkyMaybe<U> where F: FnOnce(T) -> SkyMaybe<U> {
        match self.0 { Some(t) => f(t), None => SkyMaybe(None) }
    }
    pub fn with_default(self, def: T) -> T { self.0.unwrap_or(def) }
    pub fn is_just(&self) -> bool { self.0.is_some() }
    pub fn is_nothing(&self) -> bool { self.0.is_none() }
}

pub fn just<T>(v: T) -> SkyMaybe<T> { SkyMaybe::just(v) }
pub fn nothing<T>() -> SkyMaybe<T> { SkyMaybe::nothing() }
pub fn map_maybe<T, U, F>(m: SkyMaybe<T>, f: F) -> SkyMaybe<U> where F: FnOnce(T) -> U { m.map(f) }
pub fn and_then_maybe<T, U, F>(m: SkyMaybe<T>, f: F) -> SkyMaybe<U> where F: FnOnce(T) -> SkyMaybe<U> { m.and_then(f) }

// ============================================================================
// String type
// ============================================================================

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SkyString(String);

impl SkyString {
    pub fn new(s: &str) -> Self { SkyString(s.to_owned()) }
    pub fn from_string(s: String) -> Self { SkyString(s) }
    pub fn len(&self) -> usize { self.0.len() }
    pub fn is_empty(&self) -> bool { self.0.is_empty() }
    pub fn as_str(&self) -> &str { &self.0 }
    pub fn into_string(self) -> String { self.0 }
    pub fn append(&mut self, other: &SkyString) { self.0.push_str(&other.0); }
    pub fn concat(a: &SkyString, b: &SkyString) -> SkyString { SkyString(format!("{}{}", a.0, b.0)) }
    pub fn split(&self, delim: &str) -> Vec<SkyString> { self.0.split(delim).map(|s| SkyString(s.to_owned())).collect() }
    pub fn to_uppercase(&self) -> SkyString { SkyString(self.0.to_uppercase()) }
    pub fn to_lowercase(&self) -> SkyString { SkyString(self.0.to_lowercase()) }
    pub fn trim(&self) -> SkyString { SkyString(self.0.trim().to_owned()) }
    pub fn contains(&self, sub: &str) -> bool { self.0.contains(sub) }
    pub fn starts_with(&self, prefix: &str) -> bool { self.0.starts_with(prefix) }
    pub fn ends_with(&self, suffix: &str) -> bool { self.0.ends_with(suffix) }
}

impl Default for SkyString {
    fn default() -> Self { SkyString(String::new()) }
}

impl From<String> for SkyString {
    fn from(s: String) -> Self { SkyString(s) }
}

impl From<SkyString> for String {
    fn from(s: SkyString) -> Self { s.0 }
}

impl std::fmt::Display for SkyString {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { write!(f, "{}", self.0) }
}

// ============================================================================
// List type - simple vector for now
// ============================================================================

#[derive(Debug, Clone)]
pub struct SkyList<T>(Vec<T>);

impl<T> SkyList<T> {
    pub fn new() -> Self { SkyList(Vec::new()) }
    pub fn from_vec(v: Vec<T>) -> Self { SkyList(v) }
    pub fn len(&self) -> usize { self.0.len() }
    pub fn is_empty(&self) -> bool { self.0.is_empty() }
    pub fn get(&self, i: usize) -> Option<&T> { self.0.get(i) }
    pub fn head(&self) -> Option<&T> { self.0.first() }
    pub fn push(&mut self, t: T) { self.0.push(t); }
    pub fn to_vec(&self) -> Vec<T> where T: Clone { self.0.clone() }
}

impl<T> Default for SkyList<T> {
    fn default() -> Self { Self::new() }
}

pub fn list_map<T, U, F>(list: &[T], f: F) -> Vec<U> where F: Fn(&T) -> U {
    list.iter().map(f).collect()
}

pub fn list_filter<T: Clone, F>(list: &[T], f: F) -> Vec<T> where F: Fn(&T) -> bool {
    list.iter().filter(|t| f(*t)).cloned().collect()
}

pub fn list_fold<T, U, F>(list: &[T], init: U, f: F) -> U where F: Fn(U, &T) -> U {
    list.iter().fold(init, |acc, t| f(acc, t))
}

// ============================================================================
// Dict type - using BTreeMap
// ============================================================================

use std::collections::BTreeMap;

#[derive(Debug, Clone)]
pub struct SkyDict<K, V> { map: BTreeMap<K, V> }

impl<K: Ord + Clone, V: Clone> SkyDict<K, V> {
    pub fn new() -> Self { SkyDict { map: BTreeMap::new() } }
    pub fn insert(&mut self, k: K, v: V) -> Option<V> { self.map.insert(k, v) }
    pub fn get(&self, k: &K) -> Option<&V> { self.map.get(k) }
    pub fn contains(&self, k: &K) -> bool { self.map.contains_key(k) }
    pub fn remove(&mut self, k: &K) -> Option<V> { self.map.remove(k) }
    pub fn len(&self) -> usize { self.map.len() }
    pub fn is_empty(&self) -> bool { self.map.is_empty() }
    pub fn keys(&self) -> Vec<K> { 
        self.map.iter().map(|(k, _)| k.clone()).collect() 
    }
    pub fn values(&self) -> Vec<V> { 
        self.map.iter().map(|(_, v)| v.clone()).collect() 
    }
    pub fn to_list(&self) -> Vec<(K, V)> { 
        self.map.iter().map(|(k, v)| (k.clone(), v.clone())).collect() 
    }
}

impl<K: Ord + Clone, V: Clone> Default for SkyDict<K, V> {
    fn default() -> Self { Self::new() }
}

// ============================================================================
// Task type - async wrapper
// ============================================================================

pub type SkyTask<E, A> = std::pin::Pin<Box<dyn std::future::Future<Output = SkyResult<E, A>> + Send>>;

pub fn succeed<E: Send + 'static, A: Send + 'static>(a: A) -> SkyTask<E, A> {
    Box::pin(async move { SkyResult::ok(a) })
}

pub fn fail<E: Send + 'static, A: Send + 'static>(e: E) -> SkyTask<E, A> {
    Box::pin(async move { SkyResult::err(e) })
}

pub fn map_task<E, A, B, F>(t: SkyTask<E, A>, f: F) -> SkyTask<E, B>
where F: FnOnce(A) -> B + Send + 'static, A: Send + 'static, B: Send + 'static, E: Send + 'static {
    Box::pin(async move { t.await.map(f) })
}

pub fn and_then_task<E, A, B, F>(t: SkyTask<E, A>, f: F) -> SkyTask<E, B>
where F: FnOnce(A) -> SkyTask<E, B> + Send + 'static, A: Send + 'static, B: Send + 'static, E: Send + 'static {
    Box::pin(async move {
        match t.await {
            SkyResult(Ok(a)) => f(a).await,
            SkyResult(Err(e)) => SkyResult::err(e),
        }
    })
}

// ============================================================================
// Allocator placeholder
// ============================================================================

#[derive(Debug, Clone, Copy)]
pub struct SkyAllocator;

impl SkyAllocator {
    pub fn new() -> Self { SkyAllocator }
}

impl Default for SkyAllocator {
    fn default() -> Self { SkyAllocator }
}

// ============================================================================
// FFI helpers
// ============================================================================

pub fn to_owned_string(s: &SkyString) -> String { s.0.clone() }
pub fn from_owned_string(s: String) -> SkyString { SkyString(s) }
pub fn to_owned_list<T: Clone>(l: &SkyList<T>) -> Vec<T> { l.0.clone() }
pub fn from_owned_list<T>(v: Vec<T>) -> SkyList<T> { SkyList(v) }

// ============================================================================
// Basic operations
// ============================================================================

pub fn int_add(a: i64, b: i64) -> i64 { a + b }
pub fn int_sub(a: i64, b: i64) -> i64 { a - b }
pub fn int_mul(a: i64, b: i64) -> i64 { a * b }
pub fn int_div(a: i64, b: i64) -> i64 { a / b }
pub fn int_mod(a: i64, b: i64) -> i64 { a % b }
pub fn float_add(a: f64, b: f64) -> f64 { a + b }
pub fn float_sub(a: f64, b: f64) -> f64 { a - b }
pub fn float_mul(a: f64, b: f64) -> f64 { a * b }
pub fn float_div(a: f64, b: f64) -> f64 { a / b }
pub fn bool_and(a: bool, b: bool) -> bool { a && b }
pub fn bool_or(a: bool, b: bool) -> bool { a || b }
pub fn bool_not(a: bool) -> bool { !a }
pub fn eq<T: PartialEq>(a: &T, b: &T) -> bool { a == b }
pub fn neq<T: PartialEq>(a: &T, b: &T) -> bool { a != b }
pub fn lt<T: PartialOrd>(a: &T, b: &T) -> bool { a < b }
pub fn gt<T: PartialOrd>(a: &T, b: &T) -> bool { a > b }
pub fn identity<T>(x: T) -> T { x }
pub fn to_string<T: std::fmt::Debug>(v: &T) -> String { format!("{:?}", v) }

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    // ---------------------------------------------------------------------
    // SkyResult Tests
    // ---------------------------------------------------------------------
    #[test]
    fn result_ok() {
        let r: SkyResult<&str, i64> = ok(42);
        assert!(r.is_ok());
        assert_eq!(r.with_default(0), 42);
    }

    #[test]
    fn result_err() {
        let r: SkyResult<&str, i64> = err("error");
        assert!(r.is_err());
        assert_eq!(r.with_default(0), 0);
    }

    #[test]
    fn result_map_ok() {
        let r: SkyResult<&str, i64> = ok(5);
        let mapped = r.map(|x| x * 2);
        assert_eq!(mapped.with_default(0), 10);
    }

    #[test]
    fn result_map_err() {
        let r: SkyResult<&str, i64> = err("error");
        let mapped = r.map(|x: i64| x * 2);
        assert!(mapped.is_err());
    }

    #[test]
    fn result_and_then_ok_ok() {
        let r: SkyResult<&str, i64> = ok(5);
        let chained = r.and_then(|x| ok::<&str, i64>(x * 2));
        assert_eq!(chained.with_default(0), 10);
    }

    #[test]
    fn result_and_then_err() {
        let r: SkyResult<&str, i64> = err("e");
        let chained = r.and_then(|x: i64| ok::<&str, i64>(x * 2));
        assert!(chained.is_err());
    }

    // ---------------------------------------------------------------------
    // SkyMaybe Tests  
    // ---------------------------------------------------------------------
    #[test]
    fn maybe_just() {
        let m: SkyMaybe<i64> = just(42);
        assert!(m.is_just());
        assert_eq!(m.with_default(0), 42);
    }

    #[test]
    fn maybe_nothing() {
        let m: SkyMaybe<i64> = nothing();
        assert!(m.is_nothing());
        assert_eq!(m.with_default(99), 99);
    }

    #[test]
    fn maybe_map_just() {
        let m = just(5);
        let mapped = m.map(|x| x * 2);
        assert_eq!(mapped.with_default(0), 10);
    }

    #[test]
    fn maybe_and_then_just() {
        let m = just(5);
        let chained = m.and_then(|x| just(x * 2));
        assert_eq!(chained.with_default(0), 10);
    }

    // ---------------------------------------------------------------------
    // SkyString Tests
    // ---------------------------------------------------------------------
    #[test]
    fn string_new() {
        let s = SkyString::new("hello");
        assert_eq!(s.len(), 5);
        assert_eq!(s.as_str(), "hello");
    }

    #[test]
    fn string_concat() {
        let a = SkyString::new("hello");
        let b = SkyString::new(" world");
        let c = SkyString::concat(&a, &b);
        assert_eq!(c.as_str(), "hello world");
    }

    #[test]
    fn string_split() {
        let s = SkyString::new("a,b,c");
        let parts = s.split(",");
        assert_eq!(parts.len(), 3);
    }

    #[test]
    fn string_uppercase() {
        let s = SkyString::new("hello");
        assert_eq!(s.to_uppercase().as_str(), "HELLO");
    }

    // ---------------------------------------------------------------------
    // SkyList Tests
    // ---------------------------------------------------------------------
    #[test]
    fn list_new() {
        let list: SkyList<i64> = SkyList::new();
        assert!(list.is_empty());
    }

    #[test]
    fn list_from_vec() {
        let list = SkyList::from_vec(vec![1, 2, 3]);
        assert_eq!(list.len(), 3);
    }

    #[test]
    fn list_get() {
        let list = SkyList::from_vec(vec![10, 20, 30]);
        assert_eq!(list.get(1), Some(&20));
        assert_eq!(list.get(99), None);
    }

    #[test]
    fn list_head() {
        let list = SkyList::from_vec(vec![42, 99]);
        assert_eq!(list.head(), Some(&42));
    }

    #[test]
    fn list_push() {
        let mut list = SkyList::new();
        list.push(1);
        list.push(2);
        assert_eq!(list.len(), 2);
    }

    #[test]
    fn list_map_fn() {
        let list = vec![1, 2, 3];
        let result = list_map(&list, |x| x * 2);
        assert_eq!(result, vec![2, 4, 6]);
    }

    #[test]
    fn list_filter_fn() {
        let list = vec![1, 2, 3, 4];
        let result = list_filter(&list, |x| *x % 2 == 0);
        assert_eq!(result, vec![2, 4]);
    }

    #[test]
    fn list_fold_fn() {
        let list = vec![1, 2, 3, 4];
        let sum = list_fold(&list, 0, |acc, x| acc + x);
        assert_eq!(sum, 10);
    }

    // ---------------------------------------------------------------------
    // SkyDict Tests
    // ---------------------------------------------------------------------
    #[test]
    fn dict_new() {
        let dict: SkyDict<String, i64> = SkyDict::new();
        assert!(dict.is_empty());
    }

    #[test]
    fn dict_insert() {
        let mut dict: SkyDict<String, i64> = SkyDict::new();
        dict.insert("key".to_string(), 42);
        assert_eq!(dict.len(), 1);
    }

    #[test]
    fn dict_get() {
        let mut dict: SkyDict<String, i64> = SkyDict::new();
        dict.insert("a".to_string(), 1);
        assert_eq!(dict.get(&"a".to_string()), Some(&1));
        assert_eq!(dict.get(&"b".to_string()), None);
    }

    #[test]
    fn dict_contains() {
        let mut dict: SkyDict<String, i64> = SkyDict::new();
        dict.insert("present".to_string(), 1);
        assert!(dict.contains(&"present".to_string()));
        assert!(!dict.contains(&"missing".to_string()));
    }

    #[test]
    fn dict_remove() {
        let mut dict: SkyDict<String, i64> = SkyDict::new();
        dict.insert("a".to_string(), 1);
        let removed = dict.remove(&"a".to_string());
        assert_eq!(removed, Some(1));
        assert!(dict.is_empty());
    }

    #[test]
    fn dict_keys_values() {
        let mut dict: SkyDict<String, i64> = SkyDict::new();
        dict.insert("a".to_string(), 1);
        dict.insert("b".to_string(), 2);
        assert_eq!(dict.keys().len(), 2);
        assert_eq!(dict.values().len(), 2);
    }

    // ---------------------------------------------------------------------
    // SkyTask Tests (async)
    // ---------------------------------------------------------------------
    #[tokio::test]
    async fn task_succeed() {
        let task = succeed::<String, i64>(42);
        let result = task.await;
        assert!(result.is_ok());
        assert_eq!(result.with_default(0), 42);
    }

    #[tokio::test]
    async fn task_fail() {
        let task = fail::<String, i64>("error".to_string());
        let result = task.await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn task_map() {
        let task = succeed::<String, i64>(5);
        let mapped = map_task(task, |x| x * 2);
        let result = mapped.await;
        assert_eq!(result.with_default(0), 10);
    }

    #[tokio::test]
    async fn task_and_then() {
        let task = succeed::<String, i64>(5);
        let chained = and_then_task(task, |x| succeed::<String, i64>(x * 2));
        let result = chained.await;
        assert_eq!(result.with_default(0), 10);
    }

    // ---------------------------------------------------------------------
    // Basic Operations Tests
    // ---------------------------------------------------------------------
    #[test]
    fn ops_int_add() { assert_eq!(int_add(2, 3), 5); }
    #[test]
    fn ops_int_sub() { assert_eq!(int_sub(5, 3), 2); }
    #[test]
    fn ops_int_mul() { assert_eq!(int_mul(3, 4), 12); }
    #[test]
    fn ops_int_div() { assert_eq!(int_div(10, 2), 5); }
    #[test]
    fn ops_int_mod() { assert_eq!(int_mod(10, 3), 1); }
    #[test]
    fn ops_float_add() { assert_eq!(float_add(1.5, 2.5), 4.0); }
    #[test]
    fn ops_float_mul() { assert_eq!(float_mul(2.0, 3.0), 6.0); }
    #[test]
    fn ops_bool_and() { assert!(bool_and(true, true)); }
    #[test]
    fn ops_bool_or() { assert!(bool_or(false, true)); }
    #[test]
    fn ops_bool_not() { assert!(bool_not(false)); assert!(!bool_not(true)); }
    #[test]
    fn ops_eq_true() { assert!(eq(&1, &1)); }
    #[test]
    fn ops_neq_true() { assert!(neq(&1, &2)); }
    #[test]
    fn ops_lt_true() { assert!(lt(&1, &2)); }
    #[test]
    fn ops_gt_true() { assert!(gt(&2, &1)); }
    #[test]
    fn ops_identity() { assert_eq!(identity(42), 42); }
    #[test]
    fn ops_to_string() { assert_eq!(to_string(&42), "42"); }

    // ---------------------------------------------------------------------
    // FFI Helpers Tests
    // ---------------------------------------------------------------------
    #[test]
    fn ffi_to_owned_string() {
        let s = SkyString::new("test");
        let owned = to_owned_string(&s);
        assert_eq!(owned, "test");
    }

    #[test]
    fn ffi_from_owned_string() {
        let s = from_owned_string("test".to_string());
        assert_eq!(s.as_str(), "test");
    }

    #[test]
    fn ffi_to_owned_list() {
        let list = SkyList::from_vec(vec![1, 2, 3]);
        let vec = to_owned_list(&list);
        assert_eq!(vec, vec![1, 2, 3]);
    }

    #[test]
    fn ffi_from_owned_list() {
        let list = from_owned_list(vec![1, 2, 3]);
        assert_eq!(list.len(), 3);
    }

    // ---------------------------------------------------------------------
    // SkyAllocator Tests
    // ---------------------------------------------------------------------
    #[test]
    fn allocator_new() {
        let _ = SkyAllocator::new();
    }

    #[test]
    fn allocator_default() {
        let _ = SkyAllocator::default();
    }
}