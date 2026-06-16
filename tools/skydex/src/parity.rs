use regex::Regex;
use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;

pub struct Kernel {
    pub name: String,
    pub rust_fn: String,
    pub go_impl: bool,
    pub rust_impl: bool,
    pub parity: String,
    /// "path:line" of the routing row in Kernel.hs (if known).
    pub hs_route_loc: Option<String>,
}

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

/// Route info for a single kernel: the rust_fn alias and optional source location.
#[derive(Debug, Clone)]
pub struct RouteInfo {
    pub kernel_name: String,
    /// `"path:line"` of the routing row in Kernel.hs (empty string = unknown).
    pub hs_loc: String,
}

/// rust_fn -> RouteInfo, unioning BOTH Kernel.hs shapes.
/// `hs_src_pairs` is a slice of `(file_path, source_text)` pairs so we can
/// track per-file line numbers accurately.
pub fn parse_routes_with_locs(hs_src_pairs: &[(&str, &str)]) -> HashMap<String, RouteInfo> {
    let mut m: HashMap<String, RouteInfo> = HashMap::new();
    let mut rust_kernels: HashSet<String> = HashSet::new();

    // Pass 1: Rust explicit routes (authoritative rust_fn names).
    for (file, src) in hs_src_pairs {
        for (lineno, line) in src.lines().enumerate() {
            if let Some(c) = re_route_rust().captures(line) {
                let kernel = format!("{}.{}", &c[1], &c[2]);
                rust_kernels.insert(kernel.clone());
                let loc = format!("{}:{}", file, lineno + 1);
                m.insert(c[3].to_string(), RouteInfo { kernel_name: kernel, hs_loc: loc });
            }
        }
    }
    // Pass 2: Go KernelInfo routes — only the ones the Rust file didn't name.
    for (file, src) in hs_src_pairs {
        for (lineno, line) in src.lines().enumerate() {
            if let Some(c) = re_route_go().captures(line) {
                let kernel = format!("{}.{}", &c[1], &c[2]);
                if rust_kernels.contains(&kernel) {
                    continue;
                }
                let loc = format!("{}:{}", file, lineno + 1);
                m.entry(conventional_rust_fn(&kernel)).or_insert(RouteInfo { kernel_name: kernel, hs_loc: loc });
            }
        }
    }
    m
}

/// Backward-compat wrapper used by tests that pass a single concatenated string
/// with no file-path info. Produces the same map shape as v1 (HashMap<String,String>)
/// for the existing test helpers; the new call sites use `parse_routes_with_locs`.
#[allow(dead_code)]
pub fn parse_routes(hs: &str) -> HashMap<String, String> {
    let pairs = vec![("Kernel.hs", hs)];
    parse_routes_with_locs(&pairs)
        .into_iter()
        .map(|(rust_fn, ri)| (rust_fn, ri.kernel_name))
        .collect()
}

/// Go impl name convention: `Mod_fn` (PascalCase module). Derive from "Mod.fn".
fn go_name(kernel: &str) -> String { kernel.replace('.', "_") }

pub fn reconcile_with_locs(
    routes: &HashMap<String, RouteInfo>,
    go_fns: &HashSet<String>,
    rust_fns: &HashSet<String>,
) -> Vec<Kernel> {
    routes.iter().map(|(rust_fn, ri)| {
        let go = go_fns.contains(&go_name(&ri.kernel_name));
        let rust = rust_fns.contains(rust_fn);
        let parity = match (go, rust) {
            (true, true)  => "ok",
            (true, false) => "go-only",
            (false, true) => "rust-only",
            (false, false)=> "orphan-route",
        }.to_string();
        let hs_route_loc = if ri.hs_loc.is_empty() { None } else { Some(ri.hs_loc.clone()) };
        Kernel { name: ri.kernel_name.clone(), rust_fn: rust_fn.clone(), go_impl: go, rust_impl: rust, parity, hs_route_loc }
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
        // Build routes via parse_routes_with_locs (the only non-dead path).
        let hs = r#"  ("List", "head") -> "list_head"
  ("Dict", "union") -> "dict_union""#;
        let pairs = vec![("Kernel.hs", hs)];
        let routes = parse_routes_with_locs(&pairs);
        let kernels = reconcile_with_locs(&routes, &go, &rust);
        let dict = kernels.iter().find(|k| k.name=="Dict.union").unwrap();
        assert_eq!(dict.parity, "go-only"); // routed, Go impl present, Rust impl missing
        let head = kernels.iter().find(|k| k.name=="List.head").unwrap();
        assert_eq!(head.parity, "ok");
    }

    #[test]
    fn parse_routes_with_locs_captures_line_numbers() {
        let hs = r#"  ("List", "head") -> "list_head"
  ("Dict", "union") -> "dict_union""#;
        let pairs = vec![("src/Sky/Generate/Rust/Kernel.hs", hs)];
        let routes = parse_routes_with_locs(&pairs);
        let ri = routes.get("list_head").unwrap();
        assert_eq!(ri.kernel_name, "List.head");
        assert!(ri.hs_loc.contains("Kernel.hs:1"), "expected line 1, got: {}", ri.hs_loc);
        let ri2 = routes.get("dict_union").unwrap();
        assert!(ri2.hs_loc.contains("Kernel.hs:2"), "expected line 2, got: {}", ri2.hs_loc);
    }
}
