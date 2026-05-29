//! Std.Decimal kernels. Mirrors the Go runtime's `decimal_kernel.go` (built
//! on shopspring/decimal); we use `rust_decimal::Decimal` which has compatible
//! precision (96-bit mantissa + scale).

use super::SkyResult;
use rust_decimal::{Decimal as RD, prelude::FromPrimitive};

/// Opaque Sky `Decimal` — newtype around rust_decimal::Decimal.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub struct Decimal(pub RD);

use std::str::FromStr;
use rust_decimal::prelude::ToPrimitive;
use rust_decimal::RoundingStrategy;

// Constructors

pub fn decimal_from_string<E: From<String>>(s: String) -> SkyResult<E, Decimal> {
    match RD::from_str(&s) {
        Ok(d) => SkyResult::Ok(Decimal(d)),
        Err(e) => SkyResult::Err(format!("Std.Decimal: parse: {}", e).into()),
    }
}
pub fn decimal_from_int(n: i64) -> Decimal { Decimal(RD::from(n)) }
pub fn decimal_from_float(f: f64) -> Decimal {
    Decimal(RD::from_f64(f).unwrap_or(RD::ZERO))
}
pub fn decimal_from_minor(units: i64, scale: i64) -> Decimal {
    let scale = scale.max(0) as u32;
    Decimal(RD::new(units, scale))
}
pub fn decimal_zero() -> Decimal { Decimal(RD::ZERO) }
pub fn decimal_one() -> Decimal { Decimal(RD::ONE) }
pub fn decimal_one_hundred() -> Decimal { Decimal(RD::from(100)) }

// Conversions

pub fn decimal_to_string(d: Decimal) -> String { d.0.normalize().to_string() }
pub fn decimal_to_string_fixed(places: i64, d: Decimal) -> String {
    let p = places.max(0) as u32;
    let r = d.0.round_dp_with_strategy(p, RoundingStrategy::MidpointNearestEven);
    format!("{:.*}", p as usize, r)
}
pub fn decimal_to_float(d: Decimal) -> f64 { d.0.to_f64().unwrap_or(0.0) }
pub fn decimal_to_int(d: Decimal) -> i64 {
    d.0.trunc().to_i64().unwrap_or(0)
}
pub fn decimal_to_minor(scale: i64, d: Decimal) -> i64 {
    let p = scale.max(0) as u32;
    let scaled = d.0 * RD::from(10_i64.pow(p));
    scaled.trunc().to_i64().unwrap_or(0)
}

// Arithmetic

pub fn decimal_add(a: Decimal, b: Decimal) -> Decimal { Decimal(a.0 + b.0) }
pub fn decimal_sub(a: Decimal, b: Decimal) -> Decimal { Decimal(a.0 - b.0) }
pub fn decimal_mul(a: Decimal, b: Decimal) -> Decimal { Decimal(a.0 * b.0) }
pub fn decimal_div<E: From<String>>(a: Decimal, b: Decimal) -> SkyResult<E, Decimal> {
    if b.0.is_zero() {
        return SkyResult::Err("Std.Decimal: divide by zero".to_string().into());
    }
    SkyResult::Ok(Decimal(a.0 / b.0))
}
pub fn decimal_mod<E: From<String>>(a: Decimal, b: Decimal) -> SkyResult<E, Decimal> {
    if b.0.is_zero() {
        return SkyResult::Err("Std.Decimal: mod by zero".to_string().into());
    }
    SkyResult::Ok(Decimal(a.0 % b.0))
}
pub fn decimal_neg(d: Decimal) -> Decimal { Decimal(-d.0) }
pub fn decimal_abs(d: Decimal) -> Decimal { Decimal(d.0.abs()) }

// Rounding / truncation

pub fn decimal_round(places: i64, d: Decimal) -> Decimal {
    let p = places.max(0) as u32;
    Decimal(d.0.round_dp_with_strategy(p, RoundingStrategy::MidpointNearestEven))
}
pub fn decimal_round_half_up(places: i64, d: Decimal) -> Decimal {
    let p = places.max(0) as u32;
    Decimal(d.0.round_dp_with_strategy(p, RoundingStrategy::MidpointAwayFromZero))
}
pub fn decimal_truncate(places: i64, d: Decimal) -> Decimal {
    let p = places.max(0) as u32;
    Decimal(d.0.round_dp_with_strategy(p, RoundingStrategy::ToZero))
}
pub fn decimal_floor(d: Decimal) -> Decimal { Decimal(d.0.floor()) }
pub fn decimal_ceil(d: Decimal) -> Decimal { Decimal(d.0.ceil()) }

// Comparison

pub fn decimal_compare(a: Decimal, b: Decimal) -> i64 {
    use std::cmp::Ordering;
    match a.0.cmp(&b.0) {
        Ordering::Less => -1, Ordering::Equal => 0, Ordering::Greater => 1,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::str::FromStr;

    fn d(s: &str) -> Decimal { Decimal(RD::from_str(s).unwrap()) }

    #[test]
    fn test_from_string() {
        let r: SkyResult<String, Decimal> = decimal_from_string("12.345".to_string());
        assert!(matches!(r, SkyResult::Ok(_)));
        let r2: SkyResult<String, Decimal> = decimal_from_string("not a number".to_string());
        assert!(matches!(r2, SkyResult::Err(_)));
    }

    #[test]
    fn test_arith() {
        assert_eq!(decimal_to_string(decimal_add(d("1.5"), d("2.25"))), "3.75");
        assert_eq!(decimal_to_string(decimal_sub(d("5"), d("2.5"))), "2.5");
        assert_eq!(decimal_to_string(decimal_mul(d("1.5"), d("4"))), "6");
        let div: SkyResult<String, Decimal> = decimal_div(d("10"), d("4"));
        assert_eq!(decimal_to_string(match div { SkyResult::Ok(v) => v, _ => panic!() }), "2.5");
        let div_zero: SkyResult<String, Decimal> = decimal_div(d("1"), d("0"));
        assert!(matches!(div_zero, SkyResult::Err(_)));
    }

    #[test]
    fn test_round_banker() {
        // Banker's rounding: ties go to even
        assert_eq!(decimal_to_string(decimal_round(0, d("0.5"))), "0");
        assert_eq!(decimal_to_string(decimal_round(0, d("1.5"))), "2");
        assert_eq!(decimal_to_string(decimal_round(0, d("2.5"))), "2");
        assert_eq!(decimal_to_string(decimal_round(0, d("3.5"))), "4");
    }

    #[test]
    fn test_compare() {
        assert_eq!(decimal_compare(d("1"), d("2")), -1);
        assert_eq!(decimal_compare(d("2"), d("2")), 0);
        assert_eq!(decimal_compare(d("3"), d("2")), 1);
    }
}
