//! Wall #2 hand-stub crate for the demand-driven generic Sky→Rust FFI epic.
//! Tiny, dependency-free; exercises (a) an UNCONSTRAINED generic, (b) a
//! HASH-BOUNDED generic, (c) an unmodellable-bound (Serialize) generic.

use std::collections::HashSet;

/// (a) Unconstrained generic container — `make : a -> Box1 a`, `get : Box1 a -> a`.
#[derive(Clone, Debug)]
pub struct Box1<T> {
    value: T,
}

impl<T> Box1<T> {
    pub fn make(value: T) -> Box1<T> {
        Box1 { value }
    }
    pub fn get(b: Box1<T>) -> T {
        b.value
    }
}

/// (b) HASH-bounded generic — `make` inserts the value into a HashSet, so the
/// body genuinely requires `T: Hash + Eq` (the bound is load-bearing, not
/// decorative; the recorded stub bounds MUST be this full union — F1).
#[derive(Clone, Debug)]
pub struct Keyed<T: std::hash::Hash + Eq + Clone> {
    seen: HashSet<T>,
    last: T,
}

impl<T: std::hash::Hash + Eq + Clone> Keyed<T> {
    pub fn make(value: T) -> Keyed<T> {
        let mut seen = HashSet::new();
        seen.insert(value.clone());
        Keyed { seen, last: value }
    }
    pub fn count(k: Keyed<T>) -> i64 {
        k.seen.len() as i64
    }
    pub fn last(k: Keyed<T>) -> T {
        k.last
    }
}

/// (c) An unmodellable-bound generic — its stub declares a crate-specific
/// `Serialize` bound the backend's {Hash,Eq,Ord,Clone,Default} table cannot
/// model. (No real Serialize impl needed: the binding is REJECTED at Sky
/// codegen before any cargo build, so this body is never monomorphised.)
#[derive(Clone, Debug)]
pub struct Tagged<T> {
    value: T,
}

impl<T> Tagged<T> {
    pub fn make(value: T) -> Tagged<T> {
        Tagged { value }
    }
}
