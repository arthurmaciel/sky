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

// ── DEFECT-2: serde-bound generic RETURN on a METHOD + a STATIC fn ──────────
// `Doc::get<T: DeserializeOwned>(&self) -> T` (firestore `DocumentReference::get`
// shape) and `Doc::load<T: DeserializeOwned>() -> T` (static). The serde-Value
// reduction turbofish `::<serde_json::Value>` was emitted ONLY in the free-fn
// branch → the method + static call sites had an unconstrained `T` → E0283
// (type-checks in `sky build`, fails `cargo`). Both must BIND and return a
// Value-as-JSON-String after the turbofish reaches those two branches.

#[derive(Clone)]
pub struct Doc;

impl Doc {
    pub fn new() -> Doc {
        Doc
    }

    /// Serde-bound generic RETURN on an instance METHOD.
    pub fn get<T: serde::de::DeserializeOwned>(&self) -> T {
        serde_json::from_str("42").unwrap_or_else(|_| serde_json::from_str("null").unwrap())
    }

    /// Serde-bound generic RETURN on a STATIC (associated) fn.
    pub fn load<T: serde::de::DeserializeOwned>() -> T {
        serde_json::from_str("\"loaded\"").unwrap_or_else(|_| serde_json::from_str("null").unwrap())
    }
}

impl Default for Doc {
    fn default() -> Self {
        Doc::new()
    }
}
