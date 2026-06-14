//! Sky.Core.Basics kernels: modBy + errorToString.
//!
//! Sub-A.8 T7. Mirrors Go's runtime-go/rt/rt.go (Basics_modByT, etc.).

/// Sky `modBy : Int -> Int -> Int`. Divisor-first convention (Elm/pipeline order).
/// Positive-result modulo: if the raw `%` result is negative, add `divisor`.
/// Divisor of 0 returns 0 (matches Go's `Basics_modByT`).
pub fn basics_mod_by(divisor: i64, n: i64) -> i64 {
    if divisor == 0 { return 0; }
    let r = n % divisor;
    if (r < 0 && divisor > 0) || (r > 0 && divisor < 0) { r + divisor }
    else { r }
}

/// Sky `fst : (a, b) -> a` / `snd : (a, b) -> b`. Pure in stdlib, but the
/// Prelude re-export lowers as a `VarKernel "Basics" "fst"`, so the Rust
/// backend routes it to a runtime kernel. Tuples lower to Rust tuples.
pub fn basics_fst<A, B>(t: (A, B)) -> A { t.0 }
pub fn basics_snd<A, B>(t: (A, B)) -> B { t.1 }

/// Sky `identity : a -> a` and `always : a -> b -> a`. Pure in the stdlib
/// (`identity x = x`, `always x _ = x`) but the Prelude re-export lowers each as
/// a `VarKernel "Basics" …`, so the Rust backend routes them to runtime kernels
/// (same convention as `fst`/`snd`). `always` is the tupled 2-arg form the
/// codegen emits; partial application (`always 0`) is wrapped into a closure by
/// the codegen, so the plain `(A, B) -> A` shape here is correct.
pub fn basics_identity<A>(x: A) -> A { x }
pub fn basics_always<A, B>(x: A, _y: B) -> A { x }

/// Sky `errorToString : a -> String` — universal Sky stringifier.
/// Used by Sky.Test.debugShow and friends to render any Sky value into
/// a diagnostic string. Backed by Rust's `Debug` since every codegen-emitted
/// type derives `Debug` (matches Go's `fmt.Sprintf("%v", v)` semantics).
pub fn basics_error_to_string<T: std::fmt::Debug>(v: T) -> String {
    format!("{:?}", v)
}

/// Sky `Debug.toString` — the `{{expr}}` string-interpolation stringifier.
/// Display-based, NOT Debug: a `String` interpolates as itself (no surrounding
/// quotes) and scalars format like Go's `%v`. Mirrors Go's `Debug_toString`
/// (`String → s`, else `Sprintf("%v", …)`).
pub fn debug_to_string<T: std::fmt::Display>(v: T) -> String {
    format!("{}", v)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test] fn test_mod_by_positive_divisor() { assert_eq!(basics_mod_by(3, 10), 1); }
    #[test] fn test_mod_by_zero_divisor() { assert_eq!(basics_mod_by(0, 5), 0); }
    #[test] fn test_mod_by_negative_dividend_positive_divisor() {
        // -1 % 3 = -1 in Rust; Sky/Elm wants 2 (same sign as divisor)
        assert_eq!(basics_mod_by(3, -1), 2);
        assert_eq!(basics_mod_by(3, -4), 2);
    }
    #[test] fn test_mod_by_exact() { assert_eq!(basics_mod_by(5, 10), 0); }

    #[test] fn test_error_to_string_i64() { assert_eq!(basics_error_to_string(42i64), "42"); }
    #[test] fn test_error_to_string_string() { assert_eq!(basics_error_to_string("hi".to_string()), "\"hi\""); }
    #[test] fn test_error_to_string_vec() { assert_eq!(basics_error_to_string(vec![1, 2, 3]), "[1, 2, 3]"); }

    // Regression: identity/always were missing from the runtime (emitted as
    // `basics_identity`/`basics_always` calls but undefined → E0425).
    #[test] fn test_identity() { assert_eq!(basics_identity(7i64), 7); }
    #[test] fn test_always_returns_first() { assert_eq!(basics_always(7i64, "discarded"), 7); }
}
