#![allow(dead_code, unused_imports)]

use std::collections::HashMap;

// ── POSITIVE: admissible positions ─────────────────────────────────────────

/// T appears only as a by-value param → admissible.
pub fn put<T: serde::Serialize>(x: T) -> String {
    let s = serde_json::to_string(&x).unwrap_or_default();
    format!("{}", s.len())
}

/// T appears as by-value param AND owned return → admissible (both positions).
pub fn roundtrip<T: serde::Serialize + serde::de::DeserializeOwned>(x: T) -> T {
    let json = serde_json::to_string(&x).unwrap_or_default();
    serde_json::from_str(&json).unwrap_or_else(|_| serde_json::from_str("null").unwrap())
}

/// T appears only as owned return → admissible.
pub fn get_one<T: serde::de::DeserializeOwned>() -> T {
    serde_json::from_str("42").unwrap_or_else(|_| serde_json::from_str("null").unwrap())
}

// ── NEGATIVE C-G3: inadmissible positions — must be ABSENT from bindings ────

/// T as &T (borrow) → NOT admissible.
pub fn by_ref<T: serde::Serialize>(_x: &T) {}

/// T in a tuple → NOT admissible.
pub fn pair<T: serde::Serialize>(_x: (T, T)) {}

/// T as HashMap value → NOT admissible.
pub fn map_val<T: serde::Serialize>(_m: HashMap<String, T>) {}

// ── NEGATIVE C-G1: own look-alike Serialize — must NOT trigger reduction ────

/// Crate-local Serialize look-alike — must be dropped (C-G1).
pub trait Serialize {}

pub struct Wrapper;
impl Serialize for Wrapper {}

/// Uses OWN Serialize, not serde's → must NOT be reduced → drop.
pub fn own_serde<T: self::Serialize>(_x: T) {}
