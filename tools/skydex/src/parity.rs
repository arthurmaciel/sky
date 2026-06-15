use regex::Regex;
use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;

pub struct Kernel { pub name: String, pub rust_fn: String, pub go_impl: bool, pub rust_impl: bool, pub parity: String }

/// The Rust Builder Kernel.hs routing shape: `("Mod","fn") -> "rust_fn"`.
fn re_route_rust() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r#"\(\s*"(\w+)"\s*,\s*"(\w+)"\s*\)\s*->\s*"(\w+)""#).unwrap())
}

/// The Go Kernel.hs routing shape: `(("Mod","fn"), KernelInfo "rt.Mod_fn" arity ...)`.
/// A kernel present here but absent from the Rust file is exactly the go-only gap
/// class (e.g. `Dict.union`).
fn re_route_go() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r#"\(\(\s*"(\w+)"\s*,\s*"(\w+)"\s*\)\s*,\s*KernelInfo"#).unwrap())
}

/// Conventional Rust kernel-fn name for a `Mod.fn` kernel: snake_case the dotted
/// name (`Dict.union` -> `dict_union`). Mirrors the Rust Builder Kernel.hs naming
/// so a Go-only route reconciles as a real gap (absent from rust_fns).
fn conventional_rust_fn(kernel: &str) -> String {
    let mut out = String::with_capacity(kernel.len() + 4);
    for ch in kernel.chars() {
        if ch == '.' {
            out.push('_');
        } else if ch.is_ascii_uppercase() {
            if !out.is_empty() && !out.ends_with('_') {
                out.push('_');
            }
            out.push(ch.to_ascii_lowercase());
        } else {
            out.push(ch);
        }
    }
    out
}

/// rust_fn -> "Mod.fn", unioning BOTH Kernel.hs shapes:
///   - Rust Builder Kernel.hs `("Mod","fn") -> "rust_fn"` (explicit rust_fn).
///   - Go Kernel.hs `(("Mod","fn"), KernelInfo ...)` — for kernels the Rust file
///     does NOT name, synthesise the conventional rust_fn so `reconcile` finds it
///     absent from rust_fns = the go-only gap row.
///
/// When both files name the same `Mod.fn`, the Rust explicit rust_fn wins.
pub fn parse_routes(hs: &str) -> HashMap<String, String> {
    let mut m: HashMap<String, String> = HashMap::new();
    // Pass 1: Rust explicit routes (authoritative rust_fn names).
    let mut rust_kernels: HashSet<String> = HashSet::new();
    for c in re_route_rust().captures_iter(hs) {
        let kernel = format!("{}.{}", &c[1], &c[2]);
        rust_kernels.insert(kernel.clone());
        m.insert(c[3].to_string(), kernel);
    }
    // Pass 2: Go KernelInfo routes — only the ones the Rust file didn't name.
    for c in re_route_go().captures_iter(hs) {
        let kernel = format!("{}.{}", &c[1], &c[2]);
        if rust_kernels.contains(&kernel) {
            continue;
        }
        m.entry(conventional_rust_fn(&kernel)).or_insert(kernel);
    }
    m
}

/// Go impl name convention: `Mod_fn` (PascalCase module). Derive from "Mod.fn".
fn go_name(kernel: &str) -> String { kernel.replace('.', "_") }

pub fn reconcile(routes: &HashMap<String,String>, go_fns: &HashSet<String>, rust_fns: &HashSet<String>) -> Vec<Kernel> {
    routes.iter().map(|(rust_fn, kernel)| {
        let go = go_fns.contains(&go_name(kernel));
        let rust = rust_fns.contains(rust_fn);
        let parity = match (go, rust) {
            (true, true)  => "ok",
            (true, false) => "go-only",   // the gap class that bit us (e.g. Dict.union)
            (false, true) => "rust-only",
            (false, false)=> "orphan-route",
        }.to_string();
        Kernel { name: kernel.clone(), rust_fn: rust_fn.clone(), go_impl: go, rust_impl: rust, parity }
    }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_kernel_routes() {
        let hs = r#"  ("List", "head") -> "list_head"
  ("List", "drop") -> "list_drop""#;
        let routes = parse_routes(hs);
        assert_eq!(routes.get("list_head"), Some(&"List.head".to_string()));
        assert_eq!(routes.get("list_drop"), Some(&"List.drop".to_string()));
    }
    #[test]
    fn parses_go_kernelinfo_shape() {
        // The Go Kernel.hs uses `(("Mod","fn"), KernelInfo ...)`, not `-> "..."`.
        let hs = r#"
    , (("Dict", "union"),         KernelInfo "rt.Dict_union" 2 False)
    , (("List", "head"),          KernelInfo "rt.List_headAny" 1 False)
"#;
        let routes = parse_routes(hs);
        // Go-only kernels are keyed by the conventional snake-case rust_fn.
        assert_eq!(routes.get("dict_union"), Some(&"Dict.union".to_string()));
        assert_eq!(routes.get("list_head"), Some(&"List.head".to_string()));
    }

    #[test]
    fn rust_explicit_wins_over_go_synth() {
        // Both files name List.head; the Rust explicit rust_fn must win and there
        // must be no duplicate kernel keyed by the synthesised name.
        let hs = r#"
    ("List", "head") -> "list_head_real"
    , (("List", "head"), KernelInfo "rt.List_headAny" 1 False)
"#;
        let routes = parse_routes(hs);
        assert_eq!(routes.get("list_head_real"), Some(&"List.head".to_string()));
        // No second List.head row keyed by the conventional name.
        assert_eq!(routes.get("list_head"), None);
    }

    #[test]
    fn flags_missing_rust_impl() {
        // go has List_head + Dict_union; rust has only list_head
        let go: std::collections::HashSet<String> = ["List_head","Dict_union"].iter().map(|s|s.to_string()).collect();
        let rust: std::collections::HashSet<String> = ["list_head"].iter().map(|s|s.to_string()).collect();
        let mut routes = std::collections::HashMap::new();
        routes.insert("list_head".to_string(), "List.head".to_string());
        routes.insert("dict_union".to_string(), "Dict.union".to_string());
        let kernels = reconcile(&routes, &go, &rust);
        let dict = kernels.iter().find(|k| k.name=="Dict.union").unwrap();
        assert_eq!(dict.parity, "go-only"); // routed, Go impl present, Rust impl missing
        let head = kernels.iter().find(|k| k.name=="List.head").unwrap();
        assert_eq!(head.parity, "ok");
    }
}
