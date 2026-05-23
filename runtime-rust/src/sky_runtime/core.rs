#![allow(clippy::ptr_arg)]
// Sky Runtime — Core types (always included)
// Generic over E (error type).  Builder.hs emits `use sky_runtime::*;`
// and thin wrappers that instantiate E = SkyError.

use std::pin::Pin;
use std::future::Future;

// ===========================================
// Task type (generic over error type E)
// ===========================================
pub type SkyTask<E, A> = Pin<Box<dyn Future<Output = SkyResult<E, A>> + Send + 'static>>;

/// Construct Ok with generic error type.  Use `ok_res::<SkyError>` to
/// instantiate with the project's concrete error type.
pub fn ok_res<E, A>(a: A) -> SkyResult<E, A> { SkyResult::Ok(a) }

/// Construct an error value from a string.  Requires `E: From<String>`.
/// When E = SkyCoreErrorError, the generated code provides the impl.
pub fn str_err<E: From<String>>(s: &str) -> E { s.to_string().into() }

// ===========================================
// Maybe
// ===========================================
#[derive(Clone, Debug, PartialEq)]
pub enum SkyMaybe<T> {
    Nothing,
    Just(T),
}

impl<T> SkyMaybe<T> {
    pub fn with_default(self, def: T) -> T {
        match self { SkyMaybe::Just(v) => v, SkyMaybe::Nothing => def }
    }
    pub fn is_just(&self) -> bool { matches!(self, SkyMaybe::Just(_)) }
    pub fn is_nothing(&self) -> bool { matches!(self, SkyMaybe::Nothing) }
}

pub fn sky_maybe_map<T, U>(m: SkyMaybe<T>, f: impl FnOnce(T) -> U) -> SkyMaybe<U> {
    match m { SkyMaybe::Just(v) => SkyMaybe::Just(f(v)), SkyMaybe::Nothing => SkyMaybe::Nothing }
}

pub fn sky_maybe_and_then<T, U>(m: SkyMaybe<T>, f: impl FnOnce(T) -> SkyMaybe<U>) -> SkyMaybe<U> {
    match m { SkyMaybe::Just(v) => f(v), SkyMaybe::Nothing => SkyMaybe::Nothing }
}

// ===========================================
// Result (generic over error type E)
// ===========================================
#[derive(Clone, Debug, PartialEq)]
pub enum SkyResult<E, A> {
    Ok(A),
    Err(E),
}

impl<E, A> SkyResult<E, A> {
    pub fn is_ok(&self) -> bool { matches!(self, SkyResult::Ok(_)) }
    pub fn is_err(&self) -> bool { matches!(self, SkyResult::Err(_)) }
    pub fn with_default(self, def: A) -> A {
        match self { SkyResult::Ok(v) => v, SkyResult::Err(_) => def }
    }
}

pub fn sky_result_map<E, A, B>(r: SkyResult<E, A>, f: impl FnOnce(A) -> B) -> SkyResult<E, B> {
    match r { SkyResult::Ok(v) => SkyResult::Ok(f(v)), SkyResult::Err(e) => SkyResult::Err(e) }
}

pub fn sky_result_and_then<E, A, B>(r: SkyResult<E, A>, f: impl FnOnce(A) -> SkyResult<E, B>) -> SkyResult<E, B> {
    match r { SkyResult::Ok(v) => f(v), SkyResult::Err(e) => SkyResult::Err(e) }
}

// ===========================================
// List helpers
// ===========================================
pub fn sky_list_is_empty<T>(v: &Vec<T>) -> bool { v.is_empty() }

pub fn sky_list_head<T: Clone>(v: &Vec<T>) -> SkyMaybe<T> {
    v.first().map(|x| SkyMaybe::Just(x.clone())).unwrap_or(SkyMaybe::Nothing)
}

pub fn sky_list_map<T: Clone, U>(f: impl Fn(T) -> U, v: &Vec<T>) -> Vec<U> {
    v.iter().map(|x| f(x.clone())).collect()
}

pub fn sky_list_filter<T: Clone>(f: impl Fn(&T) -> bool, v: &Vec<T>) -> Vec<T> {
    v.iter().filter(|x| f(*x)).cloned().collect()
}

pub fn sky_list_fold<T: Clone, B>(f: impl Fn(B, T) -> B, init: B, v: &Vec<T>) -> B {
    v.iter().fold(init, |acc, x| f(acc, x.clone()))
}

pub fn sky_list_cons<T: Clone>(x: T, xs: Vec<T>) -> Vec<T> {
    std::iter::once(x).chain(xs).collect()
}

// ===========================================
// String helpers
// ===========================================
pub fn sky_string_append(a: String, b: String) -> String { a + &b }
pub fn sky_string_len(s: &str) -> usize { s.len() }
pub fn sky_string_is_empty(s: &str) -> bool { s.is_empty() }

// ===========================================
// Int / Float helpers
// Misc helpers
// ===========================================
pub fn string_from_int(i: i64) -> String { format!("{}", i) }
pub fn string_join(sep: String, strs: Vec<String>) -> String { strs.join(&sep) }
pub fn string_append(a: String, b: String) -> String { a + &b }
pub fn string_length(s: String) -> i64 { s.len() as i64 }
pub fn string_is_empty(s: String) -> bool { s.is_empty() }
pub fn string_reverse(s: String) -> String { s.chars().rev().collect() }
pub fn string_to_upper(s: String) -> String { s.to_uppercase() }
pub fn string_to_lower(s: String) -> String { s.to_lowercase() }
pub fn string_trim(s: String) -> String { s.trim().to_string() }
pub fn string_contains(haystack: String, needle: String) -> bool { haystack.contains(&needle) }
pub fn string_to_int(s: String) -> SkyMaybe<i64> {
    match s.parse::<i64>() { Ok(v) => SkyMaybe::Just(v), Err(_) => SkyMaybe::Nothing }
}
pub fn string_from_float(f: f64) -> String { format!("{}", f) }
pub fn string_split(sep: String, s: String) -> Vec<String> { s.split(&sep).map(|x| x.to_string()).collect() }

// List operations (Q3)
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
pub fn list_range(lo: i64, hi: i64) -> Vec<i64> { (lo..hi).collect() }
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

pub fn result_with_default<E, A>(def: A, r: SkyResult<E, A>) -> A {
    match r { SkyResult::Ok(v) => v, SkyResult::Err(_) => def }
}

pub fn result_traverse<T0: Clone, T1: Clone, E>(f: impl Fn(T0) -> SkyResult<E, T1> + Clone, items: Vec<T0>) -> SkyResult<E, Vec<T1>> {
    let mut out = Vec::with_capacity(items.len());
    for item in items { match f(item) { SkyResult::Ok(v) => out.push(v), SkyResult::Err(e) => return SkyResult::Err(e) } }
    SkyResult::Ok(out)
}
