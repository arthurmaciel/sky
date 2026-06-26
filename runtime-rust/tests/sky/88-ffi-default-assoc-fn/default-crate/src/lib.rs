// 88-ffi-default-assoc-fn: WALL-D proof fixture.
//
// A trait ASSOCIATED FUNCTION with no `self` receiver — the canonical case is
// `Default::default()`. The bindings.rs codegen path historically rendered the
// callee as a FREE function `::default_crate::default()` (no such free fn → E0425
// `cannot find function default`) instead of the UFCS form
// `<Cfg as ::core::default::Default>::default()`.
//
// This mirrors the firebase `UserIdentifiers: Default` shape: a `#[derive(Default)]`
// struct whose `Default::default()` binding must render as UFCS, not a free fn.

/// A `#[derive(Default)]` struct. The derived `Default::default()` is a trait
/// associated function with NO `self` receiver → must render UFCS at the binding.
#[derive(Default)]
pub struct Cfg {
    pub n: i64,
}

impl Cfg {
    /// Inherent control: a no-self associated fn that is NOT a trait method.
    /// Renders as the inherent static-fn form `Cfg::new()` — already correct.
    pub fn new() -> Cfg {
        Cfg { n: 0 }
    }

    /// Read the field via an instance method (control receiver path).
    pub fn read_n(&self) -> i64 {
        self.n
    }
}
