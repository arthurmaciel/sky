//! `SkyStringify` — the total Sky value stringifier.
//!
//! Backs `Basics.errorToString` (and `Sky.Test.debugShow`, which is just
//! `errorToString v`). Go's `Basics_errorToString` returns a `String`
//! verbatim, an `error`'s `.Error()` message, and `fmt.Sprintf("%v", v)`
//! for everything else. The Rust backend mirrors `%v` EXACTLY but TOTALLY:
//! every type reachable from a generic `errorToString` call implements this
//! trait (runtime primitives below; every codegen-emitted record/ADT gets a
//! `SkyStringify` impl from `src/Sky/Generate/Rust/Builder/Emitter.hs`).
//!
//! Why a trait, not `Debug`: `Debug` QUOTES a `String` (`"hi"`), diverging
//! from Go's unquoted `hi`. A `Display` re-bind is not total (no codegen type
//! emits `Display`). `SkyStringify` is the total, Go-faithful middle path.
//!
//! Totality contract: `sky_show` NEVER panics — no `unwrap`/`expect`/indexing.
//! A type with no meaningful `%v` analogue (function-typed fields) renders a
//! best-effort placeholder rather than failing.
//!
//! Go `%v` reference (verified against the Go toolchain):
//! - `"hi"` -> `hi`            (string: unquoted)
//! - `42` / `true` / `42.5`    -> Display
//! - `[]int{1,2,3}`            -> `[1 2 3]`   (space-separated, NOT comma)
//! - `[][]int{{1,2},{3,4}}`    -> `[[1 2] [3 4]]`
//! - `T2{1,"a"}` (Sky tuple)   -> `{1 a}`     (space-separated, no field names)
//! - `R{1,"x"}` (Sky record)   -> `{1 x}`     (fields in _fieldIndex order)
//! - `map[string]int{...}`     -> `map[a:1 b:2]` (keys SORTED, space-separated)

use std::collections::HashMap;
use crate::sky_runtime::core::{SkyMaybe, SkyResult};

/// Total Sky stringifier. One method, infallible, never panics.
pub trait SkyStringify {
    /// Render `self` byte-identically to Go's `Basics_errorToString` / `%v`.
    fn sky_show(&self) -> String;
}

// ─── Scalars ────────────────────────────────────────────────────────────────

impl SkyStringify for String {
    // Go: a String returns verbatim (UNQUOTED). This is the primary fix.
    fn sky_show(&self) -> String { self.clone() }
}

impl SkyStringify for str {
    fn sky_show(&self) -> String { self.to_string() }
}

impl SkyStringify for i64 {
    fn sky_show(&self) -> String { self.to_string() }
}

impl SkyStringify for f64 {
    // Go's `%v` on a float uses the shortest round-trippable form; Rust's
    // `f64::to_string` matches for the values Sky produces (42.5 -> "42.5",
    // 1.0 -> "1"). Go prints `1` for a whole float too.
    fn sky_show(&self) -> String {
        // Go renders a whole-valued float64 without a trailing `.0` under `%v`
        // (e.g. `fmt.Sprintf("%v", 1.0)` is `1`). Rust's `to_string` gives `1`
        // for `1.0f64` as well, so a plain `to_string` matches.
        self.to_string()
    }
}

impl SkyStringify for bool {
    fn sky_show(&self) -> String { self.to_string() }
}

impl SkyStringify for () {
    // Sky `()` is Go's empty struct; `%v` renders `{}`. Rare in errorToString,
    // kept total for completeness.
    fn sky_show(&self) -> String { "{}".to_string() }
}

// ─── References / boxes (delegate) ───────────────────────────────────────────

impl<T: SkyStringify + ?Sized> SkyStringify for &T {
    fn sky_show(&self) -> String { (**self).sky_show() }
}

impl<T: SkyStringify + ?Sized> SkyStringify for Box<T> {
    fn sky_show(&self) -> String { (**self).sky_show() }
}

// ─── Lists ───────────────────────────────────────────────────────────────────

impl<T: SkyStringify> SkyStringify for Vec<T> {
    // Go slice `%v`: `[a b c]` — space-separated, square brackets, empty -> `[]`.
    fn sky_show(&self) -> String {
        let parts: Vec<String> = self.iter().map(|x| x.sky_show()).collect();
        format!("[{}]", parts.join(" "))
    }
}

impl<T: SkyStringify> SkyStringify for [T] {
    fn sky_show(&self) -> String {
        let parts: Vec<String> = self.iter().map(|x| x.sky_show()).collect();
        format!("[{}]", parts.join(" "))
    }
}

// ─── Maps ────────────────────────────────────────────────────────────────────

impl<K: SkyStringify + Ord, V: SkyStringify> SkyStringify for HashMap<K, V> {
    // Go map `%v`: `map[k1:v1 k2:v2]` with keys SORTED, space-separated.
    fn sky_show(&self) -> String {
        let mut entries: Vec<(&K, &V)> = self.iter().collect();
        entries.sort_by(|a, b| a.0.cmp(b.0));
        let parts: Vec<String> = entries
            .iter()
            .map(|(k, v)| format!("{}:{}", k.sky_show(), v.sky_show()))
            .collect();
        format!("map[{}]", parts.join(" "))
    }
}

// ─── Tuples (Sky tuples render like Go's T2/T3 structs: `{a b ...}`) ─────────

impl<A: SkyStringify, B: SkyStringify> SkyStringify for (A, B) {
    fn sky_show(&self) -> String {
        format!("{{{} {}}}", self.0.sky_show(), self.1.sky_show())
    }
}

impl<A: SkyStringify, B: SkyStringify, C: SkyStringify> SkyStringify for (A, B, C) {
    fn sky_show(&self) -> String {
        format!("{{{} {} {}}}", self.0.sky_show(), self.1.sky_show(), self.2.sky_show())
    }
}

impl<A, B, C, D> SkyStringify for (A, B, C, D)
where A: SkyStringify, B: SkyStringify, C: SkyStringify, D: SkyStringify {
    fn sky_show(&self) -> String {
        format!("{{{} {} {} {}}}",
            self.0.sky_show(), self.1.sky_show(), self.2.sky_show(), self.3.sky_show())
    }
}

// ─── Sky core ADTs ───────────────────────────────────────────────────────────

impl<T: SkyStringify> SkyStringify for SkyMaybe<T> {
    // Go renders a Sky `Maybe` (a flattened-struct ADT) with a leaked layout
    // (`{tag payload}` + zero-init inactive fields) that a Rust enum cannot
    // reproduce. Best-effort, total, and human-useful: `Just <v>` / `Nothing`.
    // Documented residual: NOT byte-identical to Go's ADT `%v` (see module doc).
    fn sky_show(&self) -> String {
        match self {
            SkyMaybe::Just(v) => format!("Just {}", v.sky_show()),
            SkyMaybe::Nothing => "Nothing".to_string(),
        }
    }
}

impl<E: SkyStringify, A: SkyStringify> SkyStringify for SkyResult<E, A> {
    // Best-effort (same ADT-layout residual as SkyMaybe): `Ok <a>` / `Err <e>`.
    fn sky_show(&self) -> String {
        match self {
            SkyResult::Ok(a) => format!("Ok {}", a.sky_show()),
            SkyResult::Err(e) => format!("Err {}", e.sky_show()),
        }
    }
}

// ─── Runtime opaque value types that flow into errorToString/debugShow ───────
// These are real runtime types (not codegen-emitted), so their SkyStringify
// impls live HERE. A generated ADT can carry them as a payload (e.g.
// `Money(Decimal, …)`, `Claims(Vec<(String, JsonVal)>)`); the codegen's enum
// `sky_show` calls `.sky_show()` on the payload, so the type must impl it.

impl SkyStringify for crate::sky_runtime::decimal::Decimal {
    // Reuse the canonical Decimal renderer (normalized, no trailing zeros) —
    // matches `Decimal.toString`. Total (no panic).
    fn sky_show(&self) -> String {
        crate::sky_runtime::decimal::decimal_to_string(self.clone())
    }
}

// `serde_json` is only in the dependency tree under the `json` feature; gate the
// impl so a project that doesn't enable `json` still compiles (the unconditional
// form was an E0433 `unresolved crate serde_json` on default features).
#[cfg(feature = "json")]
impl SkyStringify for serde_json::Value {
    // Best-effort, total: the compact JSON text. Not Go's flattened-struct `%v`
    // layout (a JSON value has no Go-struct analogue), but human-useful and never
    // panics. `to_string` on serde_json::Value is infallible.
    fn sky_show(&self) -> String { self.to_string() }
}

// NB: `SkyError` is `type SkyError = String` (see config.rs), so it stringifies
// through the `String` impl above — rendering its message verbatim, exactly
// like Go's `error.Error()` branch in `Basics_errorToString`. No separate impl
// is needed (and a separate one would conflict with the `String` impl).

#[cfg(test)]
mod tests {
    use super::*;

    #[test] fn string_unquoted() { assert_eq!("hi".to_string().sky_show(), "hi"); }
    #[test] fn str_unquoted() { assert_eq!("hi".sky_show(), "hi"); }
    #[test] fn empty_string() { assert_eq!(String::new().sky_show(), ""); }
    #[test] fn int_plain() { assert_eq!(42i64.sky_show(), "42"); }
    #[test] fn bool_plain() { assert_eq!(true.sky_show(), "true"); }
    #[test] fn float_plain() { assert_eq!(42.5f64.sky_show(), "42.5"); }
    #[test] fn float_whole() { assert_eq!(1.0f64.sky_show(), "1"); }

    #[test] fn vec_int_space_separated() { assert_eq!(vec![1i64, 2, 3].sky_show(), "[1 2 3]"); }
    #[test] fn vec_string_unquoted() {
        assert_eq!(vec!["a".to_string(), "b".to_string()].sky_show(), "[a b]");
    }
    #[test] fn vec_empty() { let v: Vec<i64> = vec![]; assert_eq!(v.sky_show(), "[]"); }
    #[test] fn vec_nested() {
        assert_eq!(vec![vec![1i64, 2], vec![3, 4]].sky_show(), "[[1 2] [3 4]]");
    }

    #[test] fn tuple2() { assert_eq!((1i64, "a".to_string()).sky_show(), "{1 a}"); }
    #[test] fn tuple3() { assert_eq!((1i64, "a".to_string(), true).sky_show(), "{1 a true}"); }

    #[test] fn map_sorted() {
        let mut m: HashMap<String, i64> = HashMap::new();
        m.insert("b".to_string(), 2);
        m.insert("a".to_string(), 1);
        m.insert("c".to_string(), 3);
        assert_eq!(m.sky_show(), "map[a:1 b:2 c:3]");
    }

    #[test] fn maybe_just() { assert_eq!(SkyMaybe::Just(5i64).sky_show(), "Just 5"); }
    #[test] fn maybe_nothing() {
        let n: SkyMaybe<i64> = SkyMaybe::Nothing;
        assert_eq!(n.sky_show(), "Nothing");
    }
    #[test] fn result_ok() {
        let r: SkyResult<String, i64> = SkyResult::Ok(7);
        assert_eq!(r.sky_show(), "Ok 7");
    }
    #[test] fn result_err() {
        let r: SkyResult<String, i64> = SkyResult::Err("boom".to_string());
        assert_eq!(r.sky_show(), "Err boom");
    }
}
