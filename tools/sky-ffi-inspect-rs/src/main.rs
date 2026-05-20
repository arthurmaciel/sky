//! sky-ffi-inspect-rs — Rust crate inspector for Sky FFI bindings.
//!
//! Mirrors `tools/sky-ffi-inspect/main.go` exactly:
//! - Uses `syn` to parse crate source (like Go uses `go/ast`)
//! - Outputs JSON matching the `PkgInfo` schema that FfiGen.hs consumes
//! - No type-checking or compilation — pure syntax-level inspection
//!
//! Usage:
//!   sky-ffi-inspect-rs uuid                  # single crate → single JSON object
//!   sky-ffi-inspect-rs uuid chrono uuid      # multi → JSON array

use cargo_metadata::MetadataCommand;
use serde::Serialize;
use std::collections::HashMap;
use std::path::PathBuf;
use syn::{Item, ItemFn, ItemImpl, ItemStruct, Signature, Type, Visibility};

// ── JSON output types (match Go inspector schema exactly) ──────────────

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct Param {
    name: String,
    #[serde(rename = "type")]
    ty: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    sky_type: String,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct Function {
    name: String,
    params: Vec<Param>,
    results: Vec<Param>,
    variadic: bool,
    effect: String,
    exported: bool,
    #[serde(skip_serializing_if = "String::is_empty")]
    recv_type: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    method_name: String,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    is_field: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    is_field_set: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    is_pkg_var: bool,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct PkgInfo {
    pkg: String,
    name: String,
    functions: Vec<Function>,
    errors: Vec<String>,
}

// ── Entry point ────────────────────────────────────────────────────────

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        eprintln!("Usage: sky-ffi-inspect-rs <crate-name> [crate-name...]");
        std::process::exit(1);
    }

    let results: Vec<PkgInfo> = args.iter().map(|name| inspect_crate(name)).collect();

    let json = if args.len() == 1 {
        serde_json::to_string_pretty(&results[0])
    } else {
        serde_json::to_string_pretty(&results)
    };

    match json {
        Ok(s) => println!("{}", s),
        Err(e) => {
            let err = PkgInfo {
                pkg: args.join(" "),
                name: "error".into(),
                functions: vec![],
                errors: vec![format!("JSON serialization failed: {}", e)],
            };
            println!("{}", serde_json::to_string_pretty(&err).unwrap());
        }
    }
}

// ── Crate inspection ────────────────────────────────────────────────────

fn inspect_crate(crate_name: &str) -> PkgInfo {
    let metadata = match MetadataCommand::new().exec() {
        Ok(m) => m,
        Err(e) => return pkg_error(crate_name, &format!("cargo metadata failed: {}", e)),
    };

    // Find the package by name
    let pkg = match metadata.packages.iter().find(|p| p.name == crate_name) {
        Some(p) => p,
        None => return pkg_error(crate_name, &format!("package '{}' not found in workspace. Try `cargo download` first.", crate_name)),
    };

    // Find the source file (lib.rs or main.rs)
    let source_file = find_source_file(pkg);
    let source_path = match source_file {
        Some(p) => p,
        None => return pkg_error(crate_name, "no lib.rs or main.rs found"),
    };

    let source_text = match std::fs::read_to_string(&source_path) {
        Ok(t) => t,
        Err(e) => return pkg_error(crate_name, &format!("cannot read {}: {}", source_path.display(), e)),
    };

    let syntax = match syn::parse_file(&source_text) {
        Ok(s) => s,
        Err(e) => return pkg_error(crate_name, &format!("parse error: {}", e)),
    };

    let mut functions: Vec<Function> = Vec::new();
    let mut type_aliases: HashMap<String, String> = HashMap::new();
    let mut errors: Vec<String> = Vec::new();

    // First pass: collect type aliases (for named-of-basic unwrapping)
    for item in &syntax.items {
        if let Item::Type(ty) = item {
            if matches!(ty.vis, Visibility::Public(_)) {
                let name = ty.ident.to_string();
                let sky = type_to_sky(&ty.ty, &type_aliases);
                type_aliases.insert(name, sky);
            }
        }
    }

    // Second pass: walk items
    for item in &syntax.items {
        match item {
            Item::Fn(f) => {
                if let Some(func) = inspect_fn(f, &type_aliases, None, false, false, false) {
                    functions.push(func);
                }
            }
            Item::Impl(imp) => {
                let self_ty_str = type_to_sky(&imp.self_ty, &type_aliases);
                for impl_item in &imp.items {
                    if let syn::ImplItem::Fn(method) = impl_item {
                        if matches!(method.vis, Visibility::Public(_)) {
                            // Wrap ImplItemFn as ItemFn for inspection
                    let wrapped = ItemFn {
                        attrs: method.attrs.clone(),
                        vis: method.vis.clone(),
                        sig: method.sig.clone(),
                        block: Box::new(method.block.clone()),
                    };
                    if let Some(func) = inspect_fn(
                                &wrapped,
                                &type_aliases,
                                Some(&self_ty_str),
                                false,
                                false,
                                false,
                            ) {
                                functions.push(func);
                            }
                        }
                    }
                }
            }
            Item::Struct(s) => {
                if matches!(s.vis, Visibility::Public(_)) {
                    let struct_name = s.ident.to_string();
                            // Emit field getters/setters for each named field
                    if let syn::Fields::Named(ref fields) = s.fields {
                        for field in &fields.named {
                            if matches!(field.vis, Visibility::Public(_)) {
                                let field_name = field.ident.as_ref().unwrap().to_string();
                                let field_ty = type_to_sky(&field.ty, &type_aliases);
                                let sn = struct_name.clone();

                                // Getter
                                functions.push(Function {
                                    name: format!("{}_get_{}", sn, field_name),
                                    params: vec![Param {
                                        name: "self".into(),
                                        ty: sn.clone(),
                                        sky_type: String::new(),
                                    }],
                                    results: vec![Param {
                                        name: String::new(),
                                        ty: field_ty.clone(),
                                        sky_type: String::new(),
                                    }],
                                    variadic: false,
                                    effect: "pure".into(),
                                    exported: true,
                                    recv_type: sn.clone(),
                                    method_name: field_name.clone(),
                                    is_field: true,
                                    is_field_set: false,
                                    is_pkg_var: false,
                                });

                                // Setter
                                functions.push(Function {
                                    name: format!("{}_set_{}", sn, field_name),
                                    params: vec![
                                        Param {
                                            name: "self".into(),
                                            ty: sn.clone(),
                                            sky_type: String::new(),
                                        },
                                        Param {
                                            name: "value".into(),
                                            ty: field_ty.clone(),
                                            sky_type: String::new(),
                                        },
                                    ],
                                    results: vec![Param {
                                        name: String::new(),
                                        ty: String::new(),
                                        sky_type: String::new(),
                                    }],
                                    variadic: false,
                                    effect: "pure".into(),
                                    exported: true,
                                    recv_type: sn,
                                    method_name: field_name,
                                    is_field: false,
                                    is_field_set: true,
                                    is_pkg_var: false,
                                });
                            }
                        }
                    }
                }
            }
            _ => {}
        }
    }

    PkgInfo {
        pkg: pkg.name.clone(),
        name: pkg.name.clone(),
        functions,
        errors,
    }
}

// ── Function inspection ────────────────────────────────────────────────

fn inspect_fn(
    item_fn: &ItemFn,
    type_aliases: &HashMap<String, String>,
    recv_type: Option<&str>,
    is_field: bool,
    is_field_set: bool,
    is_pkg_var: bool,
) -> Option<Function> {
    let sig = &item_fn.sig;
    let name = sig.ident.to_string();
    let mut params: Vec<Param> = Vec::new();
    let mut results: Vec<Param> = Vec::new();
    let mut has_generics = false;

    // Check for generics — skip if any
    if !sig.generics.params.is_empty() {
        return None; // generic functions require monomorphisation
    }

    // Extract receiver for methods
    let method_name = if recv_type.is_some() {
        name.clone()
    } else {
        String::new()
    };
    let fn_recv_type = recv_type.unwrap_or("").to_string();

    // Params
    for input in &sig.inputs {
        match input {
            syn::FnArg::Receiver(recv) => {
                let ty = if recv.reference.is_some() {
                    format!("&{}", fn_recv_type)
                } else {
                    fn_recv_type.clone()
                };
                params.push(Param {
                    name: "self".into(),
                    ty,
                    sky_type: String::new(),
                });
            }
            syn::FnArg::Typed(pat_type) => {
                let name = pat_to_name(&pat_type.pat);
                let ty = type_to_sky(&pat_type.ty, type_aliases);
                params.push(Param {
                    name,
                    ty: ty.clone(),
                    sky_type: String::new(),
                });
                // Check for function pointers (effectful signal)
                if is_fn_ptr_type(&pat_type.ty) {
                    // Mark as effectful
                }
            }
        }
    }

    // Return type
    match &sig.output {
        syn::ReturnType::Type(_, ret_ty) => {
            let ret_str = quote::quote! { #ret_ty }.to_string();
            let sky = type_to_sky(ret_ty, type_aliases);
            if ret_str.starts_with("Result ") || ret_str.starts_with("Result<") {
                results.push(Param {
                    name: String::new(),
                    ty: sky,
                    sky_type: String::new(),
                });
            } else if ret_str == "()" || ret_str.is_empty() {
                // void return — no results
            } else {
                results.push(Param {
                    name: String::new(),
                    ty: sky,
                    sky_type: String::new(),
                });
            }
        }
        syn::ReturnType::Default => {}
    }

    // If the function returns Result<T, E>, mark as fallible
    let effect = classify_effect(&sig.output, &params);

    let variadic = sig.variadic.is_some();

    Some(Function {
        name,
        params,
        results,
        variadic,
        effect,
        exported: matches!(item_fn.vis, Visibility::Public(_)),
        recv_type: fn_recv_type,
        method_name,
        is_field,
        is_field_set,
        is_pkg_var,
    })
}

// ── Effect classification ──────────────────────────────────────────────

fn classify_effect(ret_type: &syn::ReturnType, params: &[Param]) -> String {
    // Check return type for Result<T, E>
    let ret_str = match ret_type {
        syn::ReturnType::Type(_, ty) => quote::quote! { #ty }.to_string(),
        _ => String::new(),
    };

    if ret_str.starts_with("Result ") || ret_str.starts_with("Result<") {
        return "fallible".into();
    }

    // Check params for function pointers or channels
    for p in params {
        if p.ty.starts_with("fn(") || p.ty.contains("Receiver<") || p.ty.contains("Sender<") {
            return "effectful".into();
        }
    }

    "pure".into()
}

// ── Type mapping (Rust → Sky) ─────────────────────────────────────────

fn type_to_sky(ty: &Type, aliases: &HashMap<String, String>) -> String {
    let type_str = quote::quote! { #ty }.to_string();
    type_str_to_sky(&type_str, aliases)
}

fn type_str_to_sky(type_str: &str, aliases: &HashMap<String, String>) -> String {
    // Normalize: remove spaces after & and < >, collapse & str → &str
    let s = type_str.trim()
        .replace("& ", "&")
        .replace("< ", "<")
        .replace(" >", ">")
        .replace(" ,", ",")
        .replace(", ", ",");

    // Check type aliases first
    if let Some(sky) = aliases.get(&s) {
        return sky.clone();
    }

    // Strip module path prefix and leading &/mut for pattern matching
    // This helps match std::collections::HashMap<...> → HashMap<...>
    let s_stripped = strip_prefixes(&s);

    // Also check stripped version against aliases
    if let Some(sky) = aliases.get(&s_stripped) {
        return sky.clone();
    }

    // Match against known Rust types (check normalized first, then stripped)
    let s_norm = if s == "str" || s == "&str" || s == "&'str" { "String".into() }
                 else if s == "String" || s == "std::string::String" { "String".into() }
                 else if matches_int(&s) { "Int".into() }
                 else if matches_float(&s) { "Float".into() }
                 else if s == "bool" || s == "Bool" { "Bool".into() }
                 else if s == "()" || s.is_empty() { "()".into() }
                 else { String::new() };
    if !s_norm.is_empty() { return s_norm; }

    // Helper: extract generic from a base-name-matched string
    // e.g. "std::collections::HashMap<String,String>" matches HashMap
    fn try_extract<'a>(s: &'a str, base: &str) -> Option<String> {
        let base_angle = format!("{}<", base);
        let base_angle2 = format!("{} <", base);
        // Look for "base<" anywhere in the string
        if let Some(pos) = s.find(&base_angle) {
            let rest = &s[pos + base_angle.len()..];
            let mut depth = 0;
            for (i, c) in rest.char_indices() {
                match c {
                    '<' => depth += 1,
                    '>' if depth == 0 => return Some(rest[..i].trim().to_string()),
                    '>' => depth -= 1,
                    _ => {}
                }
            }
        }
        if let Some(pos) = s.find(&base_angle2) {
            let rest = &s[pos + base_angle2.len()..];
            let mut depth = 0;
            for (i, c) in rest.char_indices() {
                match c {
                    '<' => depth += 1,
                    '>' if depth == 0 => return Some(rest[..i].trim().to_string()),
                    '>' => depth -= 1,
                    _ => {}
                }
            }
        }
        None
    }

    // Vec<T> → List T
    if let Some(inner) = try_extract(&s, "Vec") {
        return format!("List {}", type_str_to_sky(&inner, aliases));
    }

    // Option<T> → Maybe T
    if let Some(inner) = try_extract(&s, "Option") {
        return format!("Maybe {}", type_str_to_sky(&inner, aliases));
    }

    // Result<T, E> → Result SkyE SkyT
    if let Some(inner) = try_extract(&s, "Result") {
        let parts: Vec<&str> = split_top_level(&inner, ',');
        let ok_ty = if parts.len() >= 1 { type_str_to_sky(parts.get(1).unwrap_or(&"()"), aliases) } else { "()".into() };
        let err_ty = if parts.len() >= 2 { type_str_to_sky(parts.get(0).unwrap_or(&"String"), aliases) } else { "String".into() };
        return format!("Result {} {}", err_ty, ok_ty);
    }

    // HashMap<K,V> → Dict String V
    if let Some(inner) = try_extract(&s, "HashMap") {
        let parts: Vec<&str> = split_top_level(&inner, ',');
        let val_ty = if parts.len() >= 2 { type_str_to_sky(parts[1], aliases) } else { "String".into() };
        return format!("Dict String {}", val_ty);
    }

    // BTreeMap<K,V> → Dict String V
    if let Some(inner) = try_extract(&s, "BTreeMap") {
        let parts: Vec<&str> = split_top_level(&inner, ',');
        let val_ty = if parts.len() >= 2 { type_str_to_sky(parts[1], aliases) } else { "String".into() };
        return format!("Dict String {}", val_ty);
    }

    // &[u8] → Bytes
    if s == "&[u8]" || s == "& [u8]" || s.starts_with("& [u8") || s.starts_with("&[u8") {
        return "Bytes".into();
    }

    // &T → T (strip references) — only if no generic pattern matched above
    if s.starts_with("&") && s.len() > 1 {
        let inner = s[1..].trim();
        if inner.starts_with("'") {
            if let Some(rest) = inner.split_once(' ') {
                return type_str_to_sky(rest.1, aliases);
            }
            return type_str_to_sky(inner, aliases);
        }
        if inner.starts_with("mut ") {
            return type_str_to_sky(&inner[4..], aliases);
        }
        return type_str_to_sky(inner, aliases);
    }

    // Box<T> → T (transparent)
    if let Some(inner) = try_extract(&s, "Box") {
        return type_str_to_sky(&inner, aliases);
    }

    // Pin<Box<dyn Future<...>>> → String (opaque)
    if s.contains("Pin<") || s.contains("Pin <") {
        return "String".into();
    }

    // Path types: module::Type or just Type
    let clean = if let Some((_, last)) = s.rsplit_once("::") {
        last
    } else {
        &s
    };

    // Remove generic params for the name
    let base = clean.split('<').next().unwrap_or(clean).trim().to_string();

    // Capitalize first letter for Sky conventions
    if base.starts_with(char::is_uppercase) {
        base
    } else {
        match base.as_str() {
            "string" => "String".into(),
            "i64" | "i32" | "i16" | "i8" | "isize" | "u64" | "u32" | "u16" | "u8" | "usize" | "int" => "Int".into(),
            "f64" | "f32" | "float" => "Float".into(),
            "bool" => "Bool".into(),
            _ => base,
        }
    }
}

fn strip_prefixes(s: &str) -> String {
    let mut r = s.to_string();
    // Strip & and &mut 
    while r.starts_with("&") {
        r = r[1..].trim().to_string();
    }
    if r.starts_with("mut ") {
        r = r[4..].to_string();
    }
    // Strip lifetime: &'a Type → Type
    if r.starts_with("'") {
        if let Some(rest) = r.split_once(' ') {
            r = rest.1.to_string();
        }
    }
    // Strip module path: module::Type → Type
    if let Some((_, last)) = r.rsplit_once("::") {
        r = last.to_string();
    }
    r
}

fn matches_int(s: &str) -> bool {
    matches!(s, "i64" | "i32" | "i16" | "i8" | "isize" | "u64" | "u32" | "u16" | "u8" | "usize" | "Int" | "Int64" | "Int32")
}

fn matches_float(s: &str) -> bool {
    matches!(s, "f64" | "f32" | "Float")
}

// ── Helpers ────────────────────────────────────────────────────────────

fn extract_generic<'a>(s: &'a str, prefix: &str) -> Option<String> {
    if let Some(inner) = s.strip_prefix(prefix) {
        // Find matching closing >
        let mut depth = 0;
        for (i, c) in inner.char_indices() {
            match c {
                '<' => depth += 1,
                '>' if depth == 0 => {
                    return Some(inner[..i].trim().to_string());
                }
                '>' => depth -= 1,
                _ => {}
            }
        }
    }
    None
}

/// Split a type string at the top level (respecting nested <>)
fn split_top_level(s: &str, sep: char) -> Vec<&str> {
    let mut result = Vec::new();
    let mut depth = 0;
    let mut start = 0;
    for (i, c) in s.char_indices() {
        match c {
            '<' => depth += 1,
            '>' => depth -= 1,
            _ if depth == 0 && c == sep => {
                result.push(s[start..i].trim());
                start = i + 1;
            }
            _ => {}
        }
    }
    if start < s.len() {
        result.push(s[start..].trim());
    }
    result
}

fn pat_to_name(pat: &syn::Pat) -> String {
    if let syn::Pat::Ident(ident) = pat {
        ident.ident.to_string()
    } else {
        "_".into()
    }
}

fn is_fn_ptr_type(ty: &Type) -> bool {
    let s = quote::quote! { #ty }.to_string();
    s.starts_with("fn(") || s.starts_with("fn (")
}

fn find_source_file(pkg: &cargo_metadata::Package) -> Option<PathBuf> {
    // Try lib.rs first, then main.rs
    let lib = pkg.manifest_path.parent()?.join("src").join("lib.rs");
    let lib_path: PathBuf = lib.into();
    if lib_path.exists() {
        return Some(lib_path);
    }
    let main = pkg.manifest_path.parent()?.join("src").join("main.rs");
    let main_path: PathBuf = main.into();
    if main_path.exists() {
        return Some(main_path);
    }
    None
}

fn pkg_error(crate_name: &str, msg: &str) -> PkgInfo {
    PkgInfo {
        pkg: crate_name.into(),
        name: crate_name.into(),
        functions: vec![],
        errors: vec![msg.into()],
    }
}
