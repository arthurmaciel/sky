//! Closures-FFI hand-stub crate (epic #28). Dependency-free. Exercises every
//! v1 closure shape: by-value Fn, multi-arg comparator, by-ref predicate
//! (owned-clone bridge), fallible return, FnMut slot, FnOnce slot, and the
//! drop shapes (Fn(&mut), -> &U). All bodies call the closure so the bounds
//! are load-bearing.

/// by-value `Fn(A)->B`, multi-call (maps every element).
pub fn map_each<A, B, F: Fn(A) -> B>(xs: Vec<A>, f: F) -> Vec<B> {
    xs.into_iter().map(f).collect()
}

/// by-ref predicate `Fn(&A)->bool`, multi-call → owned-clone bridge.
pub fn keep<A: Clone, F: Fn(&A) -> bool>(xs: Vec<A>, pred: F) -> Vec<A> {
    xs.into_iter().filter(|a| pred(a)).collect()
}

/// by-ref predicate `Fn(&A)->bool` WITHOUT an `A: Clone` host bound — filter
/// only BORROWS each element, so Rust does not require `A: Clone` here. The
/// owned-clone bridge in the generated wrapper still needs `A: Clone` to clone
/// the `&A` borrow to owned, so the wrapper must FORCE it (guardian-final #28).
pub fn keep_unbounded<A, F: Fn(&A) -> bool>(xs: Vec<A>, pred: F) -> Vec<A> {
    xs.into_iter().filter(|a| pred(a)).collect()
}

/// multi-arg comparator `Fn(&A,&A)->i64`.
pub fn count_lt<A: Clone, F: Fn(&A, &A) -> i64>(xs: Vec<A>, cmp: F) -> i64 {
    let mut n = 0i64;
    for i in 0..xs.len() {
        for j in (i + 1)..xs.len() {
            if cmp(&xs[i], &xs[j]) < 0 { n += 1; }
        }
    }
    n
}

/// FnMut slot (mutation across calls); a stateless Sky `Fn` satisfies it.
pub fn for_each_count<A, F: FnMut(A)>(xs: Vec<A>, mut f: F) -> i64 {
    let n = xs.len() as i64;
    for x in xs { f(x); }
    n
}

/// FnOnce slot, single-call — a non-`Clone` capture is sound here.
pub fn run_once<T, F: FnOnce() -> T>(f: F) -> T {
    f()
}
