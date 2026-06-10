//! Sky.Core.Math kernels.
//!
//! Sub-A.8 T3. Signatures from src/Sky/Type/Constrain/Expression.hs:
//!   abs    : Int -> Int                  (integer abs)
//!   min    : a -> a -> a                 (polymorphic; monomorphised at call site)
//!   max    : a -> a -> a
//!   sqrt   : Float -> Float
//!   pow    : Float -> Float -> Float
//!   floor  : Float -> Int                (note: returns Int, truncates)
//!   ceil   : Float -> Int
//!   round  : Float -> Int

pub fn math_pi() -> f64 { std::f64::consts::PI }
pub fn math_e()  -> f64 { std::f64::consts::E }

pub fn math_abs(x: i64) -> i64 { x.abs() }

pub fn math_min<T: PartialOrd>(a: T, b: T) -> T { if a <= b { a } else { b } }
pub fn math_max<T: PartialOrd>(a: T, b: T) -> T { if a >= b { a } else { b } }

pub fn math_sqrt(x: f64) -> f64 { x.sqrt() }
pub fn math_pow(base: f64, exp: f64) -> f64 { base.powf(exp) }

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
}
