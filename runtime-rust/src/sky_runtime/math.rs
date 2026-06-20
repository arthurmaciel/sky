//! Sky.Core.Math kernels.
//!
//! Signatures from src/Sky/Type/Constrain/Expression.hs:
//!   abs    : Int -> Int                  (integer abs)
//!   min    : a -> a -> a                 (polymorphic; monomorphised at call site)
//!   max    : a -> a -> a
//!   sqrt   : Float -> Float
//!   pow    : Float -> Float -> Float
//!   floor  : Float -> Int                (note: returns Int, truncates)
//!   ceil   : Float -> Int
//!   round  : Float -> Int

pub fn math_pi()    -> f64 { std::f64::consts::PI }
pub fn math_e()     -> f64 { std::f64::consts::E }
/// Golden ratio φ = (1 + √5) / 2 ≈ 1.6180339887…
/// (std::f64::consts::PHI is nightly-only; use the literal for stable Rust.)
pub fn math_phi()   -> f64 { 1.618_033_988_749_895_f64 }
/// √2 ≈ 1.4142135623…
pub fn math_sqrt2() -> f64 { std::f64::consts::SQRT_2 }
/// Positive infinity (IEEE 754).
pub fn math_inf()   -> f64 { f64::INFINITY }
/// Not-a-number (IEEE 754). Note: NaN ≠ NaN by IEEE 754.
pub fn math_nan()   -> f64 { f64::NAN }

/// Saturates `i64::MIN` to `i64::MAX` (no-panic rule: `-i64::MIN` is not representable).
pub fn math_abs(x: i64) -> i64 { x.checked_abs().unwrap_or(i64::MAX) }

// CONTRACT (documented deliberately — audit 2026-06-19): `min`/`max` use a real
// `PartialOrd` compare. For floats this tracks the TYPED Go path (`Math_minT`),
// NOT Go's polymorphic any-path (which routes floats through `AsInt` and compares
// truncated ints) — the typed compare is the correct one. NaN tie-break is fixed
// and total: `min(NaN, x)` / `max(NaN, x)` return the SECOND argument (`<=`/`>=`
// is false for any NaN), never panic.
pub fn math_min<T: PartialOrd>(a: T, b: T) -> T { if a <= b { a } else { b } }
pub fn math_max<T: PartialOrd>(a: T, b: T) -> T { if a >= b { a } else { b } }

pub fn math_sqrt(x: f64) -> f64 { x.sqrt() }
pub fn math_pow(base: f64, exp: f64) -> f64 { base.powf(exp) }

// CONTRACT (documented deliberately — audit 2026-06-19): the `as i64` float→int
// casts SATURATE by Rust's definition — NaN → 0, +∞ → i64::MAX, −∞ → i64::MIN,
// out-of-range finite → the nearest bound. This is TOTAL (never panics/UB) and is
// the deliberate contract; Go's `int64(math.Floor(x))` on the same extreme inputs
// is implementation-defined (not a well-defined parity target), so we pin the
// safe saturating behaviour rather than chase undefined Go output.
pub fn math_floor(x: f64) -> i64 { x.floor() as i64 }
pub fn math_ceil(x: f64) -> i64 { x.ceil() as i64 }

/// Sky `round : Float -> Int` — half-away-from-zero (Go's `math.Round` semantics
/// match this). Rust's `f64::round` also goes half-away-from-zero, so we just cast.
pub fn math_round(x: f64) -> i64 { x.round() as i64 }
pub fn math_trunc(x: f64) -> i64 { x.trunc() as i64 }

// Exponential / logarithmic (Sky.Core.Math: exp, exp2, log [natural], log2, log10).
pub fn math_exp(x: f64) -> f64 { x.exp() }
pub fn math_exp2(x: f64) -> f64 { x.exp2() }
pub fn math_log(x: f64) -> f64 { x.ln() }
pub fn math_log2(x: f64) -> f64 { x.log2() }
pub fn math_log10(x: f64) -> f64 { x.log10() }
pub fn math_cbrt(x: f64) -> f64 { x.cbrt() }
pub fn math_hypot(a: f64, b: f64) -> f64 { a.hypot(b) }

// Trigonometric.
pub fn math_sin(x: f64) -> f64 { x.sin() }
pub fn math_cos(x: f64) -> f64 { x.cos() }
pub fn math_tan(x: f64) -> f64 { x.tan() }
pub fn math_asin(x: f64) -> f64 { x.asin() }
pub fn math_acos(x: f64) -> f64 { x.acos() }
pub fn math_atan(x: f64) -> f64 { x.atan() }
pub fn math_atan2(y: f64, x: f64) -> f64 { y.atan2(x) }

// Hyperbolic.
pub fn math_sinh(x: f64) -> f64 { x.sinh() }
pub fn math_cosh(x: f64) -> f64 { x.cosh() }
pub fn math_tanh(x: f64) -> f64 { x.tanh() }
pub fn math_asinh(x: f64) -> f64 { x.asinh() }
pub fn math_acosh(x: f64) -> f64 { x.acosh() }
pub fn math_atanh(x: f64) -> f64 { x.atanh() }

// Modulo + remainder (parity with Go's math.Mod / math.Remainder).
/// Float modulo — result has the sign of x (the dividend).
/// Equivalent to Go's `math.Mod(x, y)` and C's `fmod(x, y)`.
/// Rust's `x % y` is identical to C fmod for f64.
pub fn math_mod(x: f64, y: f64) -> f64 { x % y }
/// IEEE 754 balanced remainder — equivalent to Go's `math.Remainder(x, y)`.
/// The result satisfies `x = n*y + remainder` where `n` is the nearest integer
/// to `x/y` (rounded half-to-even), so `|remainder| <= |y|/2`.
pub fn math_remainder(x: f64, y: f64) -> f64 {
    // IEEE 754 remainder: x - round(x/y)*y  where round is half-to-even.
    x - (x / y).round_ties_even() * y
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test] fn test_math_abs_positive() { assert_eq!(math_abs(5), 5); }
    #[test] fn test_math_abs_negative() { assert_eq!(math_abs(-5), 5); }
    #[test] fn test_math_abs_zero() { assert_eq!(math_abs(0), 0); }

    #[test]
    fn test_math_min_max_i64() {
        assert_eq!(math_min::<i64>(3, 5), 3);
        assert_eq!(math_max::<i64>(3, 5), 5);
        assert_eq!(math_min::<i64>(-2, -5), -5);
    }

    #[test]
    fn test_math_min_max_f64() {
        assert_eq!(math_min::<f64>(3.5, 2.25), 2.25);
        assert_eq!(math_max::<f64>(3.5, 2.25), 3.5);
    }

    #[test] fn test_math_sqrt() { assert_eq!(math_sqrt(9.0), 3.0); }
    #[test] fn test_math_pow() { assert_eq!(math_pow(2.0, 10.0), 1024.0); }

    #[test]
    fn test_math_floor_ceil_round() {
        assert_eq!(math_floor(3.7), 3);
        assert_eq!(math_floor(-3.2), -4);
        assert_eq!(math_ceil(3.2), 4);
        assert_eq!(math_ceil(-3.7), -3);
        assert_eq!(math_round(3.5), 4);
        assert_eq!(math_round(-3.5), -4);  // half-away-from-zero
        assert_eq!(math_round(2.4), 2);
    }

    // ── go-parity regression tests (2026-06-15) ──────────────────────

    #[test]
    fn test_math_phi() {
        // Go: math.Phi = 1.618033988749895
        let phi = math_phi();
        assert!((phi - 1.618_033_988_749_895_f64).abs() < 1e-14);
    }

    #[test]
    fn test_math_sqrt2() {
        let s = math_sqrt2();
        assert!((s - std::f64::consts::SQRT_2).abs() < 1e-15);
    }

    #[test]
    fn test_math_inf() {
        assert!(math_inf().is_infinite() && math_inf() > 0.0);
    }

    #[test]
    fn test_math_nan() {
        let n = math_nan();
        assert!(n.is_nan());
        // IEEE 754: NaN != NaN
        #[allow(clippy::eq_op)]
        { assert!(n != n); }
    }

    #[test]
    fn test_math_mod() {
        // Go: math.Mod(5.5, 2.0) = 1.5  (sign of dividend)
        assert_eq!(math_mod(5.5, 2.0), 1.5);
        assert_eq!(math_mod(-5.5, 2.0), -1.5);  // sign of dividend
        assert_eq!(math_mod(5.5, -2.0), 1.5);
    }

    #[test]
    fn test_math_remainder() {
        // Go: math.Remainder(5.5, 2.0) = -0.5  (IEEE 754 balanced)
        let r = math_remainder(5.5, 2.0);
        assert!((r - (-0.5_f64)).abs() < 1e-14, "expected -0.5, got {r}");
        // round_ties_even: x/y = 2.75 → nearest even integer = 2, so 5.5 - 2*2.0 = 1.5
        let r2 = math_remainder(5.5, 4.0);
        assert!((r2 - 1.5_f64).abs() < 1e-14, "expected 1.5, got {r2}");
    }
}
