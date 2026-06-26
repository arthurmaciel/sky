/// TWO-level private-module type — WALL 1 target.
/// Reachable: crate root → inner (private) → deep (private) → Sup
pub struct Sup {
    pub y: i64,
}

impl Sup {
    pub fn new(y: i64) -> Sup {
        Sup { y }
    }

    pub fn get_y(&self) -> i64 {
        self.y
    }

    /// WALL 2 — POSITIVE-INHERENT (the A-path / resolve_generics route):
    /// S resolves to String via bound_to_concrete(AsRef<str>) → Some(String).
    /// Must BIND as `op_from_sup(&Sup, String) -> Result<String, SkyError>`.
    pub fn op<S: AsRef<str> + Send>(&self, k: S) -> String {
        format!("{}{}", self.y, k.as_ref())
    }
}

/// WALL 2 — POSITIVE-TRAIT (the firestore B-path / try_parametric_stub route):
/// A TRAIT over a concrete Self — mirrors `FirestoreGetByIdSupport`.
/// Must BIND as `op_trait_from_doc(&Doc, String) -> Result<String, SkyError>`.
pub trait Op {
    fn op_trait<S: AsRef<str> + Send>(&self, k: S) -> String;
}

pub struct Doc {
    pub y: i64,
}

impl Doc {
    pub fn new(y: i64) -> Doc {
        Doc { y }
    }
}

impl Op for Doc {
    fn op_trait<S: AsRef<str> + Send>(&self, k: S) -> String {
        format!("{}{}", self.y, k.as_ref())
    }
}

/// NEGATIVE (C1): pub(crate) visibility — NOT publicly reachable from outside
/// the crate. Must NOT appear in REACHABLE_PATHS. If the inspector registers it,
/// the generated wrapper will try to use the crate-private path → E0603 on
/// cargo build, proving the C1 violation.
pub(crate) struct Hidden {
    pub h: i64,
}

#[allow(dead_code)]
impl Hidden {
    pub(crate) fn new(h: i64) -> Hidden {
        Hidden { h }
    }
}

/// NEGATIVE-multibound: S: AsRef<str> + serde::Serialize.
/// resolve_param_bounds returns None (Serialize not in bound_to_concrete) → DROP.
/// Body must compile: serde::Serialize is a dep; body uses k.as_ref() (only
/// AsRef<str> is unambiguous here since there's only one AsRef target).
pub struct SupNeg {
    pub z: i64,
}

impl SupNeg {
    pub fn new(z: i64) -> SupNeg {
        SupNeg { z }
    }

    pub fn op_neg<S: AsRef<str> + serde::Serialize>(&self, k: S) -> String {
        format!("{}{}", self.z, k.as_ref())
    }
}

/// NEGATIVE-ambiguous: S: AsRef<str> + AsRef<[u8]>.
/// Two conflicting concretes (String vs Vec<u8>) → resolve_param_bounds=None → DROP.
/// Body uses `<S as AsRef<str>>::as_ref(&k)` to avoid ambiguous `.as_ref()`.
pub struct SupAmbig {
    pub w: i64,
}

impl SupAmbig {
    pub fn new(w: i64) -> SupAmbig {
        SupAmbig { w }
    }

    pub fn op_ambig<S: AsRef<str> + AsRef<[u8]>>(&self, k: S) -> String {
        format!("{}{}", self.w, <S as AsRef<str>>::as_ref(&k))
    }
}
