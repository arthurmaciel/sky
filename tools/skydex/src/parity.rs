use regex::Regex;
use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;

pub struct Kernel { pub name: String, pub rust_fn: String, pub go_impl: bool, pub rust_impl: bool, pub parity: String }

fn re_route() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r#"\(\s*"(\w+)"\s*,\s*"(\w+)"\s*\)\s*->\s*"(\w+)""#).unwrap())
}

/// rust_fn -> "Mod.fn", from Kernel.hs routing rows `("Mod","fn") -> "mod_fn"`.
pub fn parse_routes(hs: &str) -> HashMap<String, String> {
    let mut m = HashMap::new();
    for c in re_route().captures_iter(hs) {
        m.insert(c[3].to_string(), format!("{}.{}", &c[1], &c[2]));
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
