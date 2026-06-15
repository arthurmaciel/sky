use regex::Regex;
use std::sync::OnceLock;

pub struct SkyScan { pub imports: Vec<String>, pub kernels: Vec<String>, pub bindings: Vec<String> }

fn re_import() -> &'static Regex { static R: OnceLock<Regex> = OnceLock::new(); R.get_or_init(|| Regex::new(r"^import\s+([\w.]+)").unwrap()) }
fn re_kernel() -> &'static Regex { static R: OnceLock<Regex> = OnceLock::new(); R.get_or_init(|| Regex::new(r#"Ffi\.kernel\s+"([\w]+)""#).unwrap()) }
fn re_binding() -> &'static Regex { static R: OnceLock<Regex> = OnceLock::new(); R.get_or_init(|| Regex::new(r"^([a-z][\w]*)\s").unwrap()) }

pub fn scan_sky(src: &str) -> SkyScan {
    let mut imports = Vec::new(); let mut kernels = Vec::new(); let mut bindings = Vec::new();
    for line in src.lines() {
        if let Some(c) = re_import().captures(line) { imports.push(c[1].to_string()); }
        if let Some(c) = re_kernel().captures(line)  { kernels.push(c[1].to_string()); }
        if let Some(c) = re_binding().captures(line) { let b = c[1].to_string(); if !bindings.contains(&b) { bindings.push(b); } }
    }
    SkyScan { imports, kernels, bindings }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn scans_sky() {
        let src = "module Sky.Core.List exposing (..)\nimport Sky.Core.Maybe as M\nhead = Ffi.kernel \"List_head\"\nmap f xs = ...\n";
        let r = scan_sky(src);
        assert!(r.imports.contains(&"Sky.Core.Maybe".to_string()));
        assert!(r.kernels.contains(&"List_head".to_string()));
        assert!(r.bindings.contains(&"head".to_string()));
        assert!(r.bindings.contains(&"map".to_string()));
    }
}
