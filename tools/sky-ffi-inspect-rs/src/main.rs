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
use std::process::Command;
use syn::{Item, ItemFn, Type, Visibility};

// ── JSON output types (match Go inspector schema exactly) ──────────────

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct Param {
    name: String,
    #[serde(rename = "type")]
    ty: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    sky_type: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    rust_type: String,
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
    recv_rust_type: String,
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
    #[serde(skip_serializing_if = "String::is_empty")]
    version: String,
    functions: Vec<Function>,
    errors: Vec<String>,
}

// ── Entry point ────────────────────────────────────────────────────────

fn main() {
    let raw_args: Vec<String> = std::env::args().skip(1).collect();
    let mut features: Vec<String> = Vec::new();
    let mut crate_args: Vec<String> = Vec::new();

    let mut i = 0;
    while i < raw_args.len() {
        if raw_args[i] == "--features" {
            i += 1;
            if i < raw_args.len() {
                for feat in raw_args[i].split(',') {
                    let f = feat.trim().to_string();
                    if !f.is_empty() {
                        features.push(f);
                    }
                }
            }
        } else {
            crate_args.push(raw_args[i].clone());
        }
        i += 1;
    }

    if crate_args.is_empty() {
        eprintln!("Usage: sky-ffi-inspect-rs [--features f1,f2] <crate-name> [crate-name...]");
        std::process::exit(1);
    }

    let results: Vec<PkgInfo> = crate_args.iter().map(|name| inspect_crate(name, &features)).collect();

    let json = if crate_args.len() == 1 {
        serde_json::to_string_pretty(&results[0])
    } else {
        serde_json::to_string_pretty(&results)
    };

    match json {
        Ok(s) => println!("{}", s),
        Err(e) => {
            let err = PkgInfo {
                pkg: crate_args.join(" "),
                name: "error".into(),
                version: String::new(),
                functions: vec![],
                errors: vec![format!("JSON serialization failed: {}", e)],
            };
            println!("{}", serde_json::to_string_pretty(&err).unwrap());
        }
    }
}

// ── Crate inspection ────────────────────────────────────────────────────

fn inspect_crate(crate_name: &str, features: &[String]) -> PkgInfo {
    // Try workspace resolution first (fast path — already in this project)
    if let Some(pkg) = resolve_workspace_package(crate_name) {
        return parse_package(&pkg, crate_name);
    }

    // Fall back to external resolution (temp project + cargo fetch)
    match resolve_external_package(crate_name, features) {
        Some(pkg) => parse_package(&pkg, crate_name),
        None => pkg_error(
            crate_name,
            &format!(
                "crate '{}' not found in workspace and could not be resolved from registry. \
                 Try `cargo add {}` or check the crate name.",
                crate_name, crate_name
            ),
        ),
    }
}

/// Look up a crate by name in the current Cargo workspace.
fn resolve_workspace_package(crate_name: &str) -> Option<cargo_metadata::Package> {
    let metadata = MetadataCommand::new().exec().ok()?;
    metadata.packages.into_iter().find(|p| p.name == crate_name)
}

/// Resolve an external crate by creating a temporary Cargo project,
/// adding it as a dependency, fetching its source, and returning its metadata.
fn resolve_external_package(crate_name: &str, features: &[String]) -> Option<cargo_metadata::Package> {
    let tmp = tempfile::tempdir().ok()?;
    let dir = tmp.path();

    // Write a minimal Cargo.toml with the dependency.
    // Use `"*"` to support both 1.x and 0.x crates (chrono, etc.).
    let safe_name = crate_name.replace('-', "_");
    let dep_entry = if features.is_empty() {
        format!("{} = \"*\"", crate_name)
    } else {
        let feats = features.iter()
            .map(|f| format!("\"{}\"", f))
            .collect::<Vec<_>>()
            .join(", ");
        format!("{} = {{ version = \"*\", features = [{}] }}", crate_name, feats)
    };
    let toml_content = format!(
        r#"[package]
name = "_sky_ffi_resolver_{}"
version = "0.1.0"
edition = "2021"

[dependencies]
{}
"#,
        safe_name, dep_entry
    );
    let src_dir = dir.join("src");
    std::fs::create_dir_all(&src_dir).ok()?;
    std::fs::write(dir.join("Cargo.toml"), &toml_content).ok()?;
    std::fs::write(src_dir.join("lib.rs"), "// placeholder\n").ok()?;

    let manifest = dir.join("Cargo.toml");

    // Fetch dependencies: try offline first (cache hit), then online
    let manifest_str = manifest.to_str().unwrap();
    let (fetch_ok, fetch_err) = match Command::new("cargo")
        .args(["fetch", "--offline", "--manifest-path", manifest_str])
        .output()
    {
        Ok(o) if o.status.success() => (true, vec![]),
        _ => {
            // Fall back to online fetch
            match Command::new("cargo")
                .args(["fetch", "--manifest-path", manifest_str])
                .output()
            {
                Ok(o) if o.status.success() => (true, vec![]),
                Ok(o) => (false, o.stderr),
                Err(e) => (false, e.to_string().into_bytes()),
            }
        }
    };
    if !fetch_ok {
        let detail = String::from_utf8_lossy(&fetch_err);
        eprintln!("cargo fetch failed for '{}': {}", crate_name, detail);
        return None;
    }

    // Run cargo metadata to find the package's source location
    let metadata = MetadataCommand::new()
        .manifest_path(&manifest)
        .exec()
        .ok()?;

    metadata.packages.into_iter().find(|p| p.name == crate_name)
}

/// Parse a cargo_metadata::Package into PkgInfo (shared by workspace + external paths).
fn parse_package(pkg: &cargo_metadata::Package, crate_name: &str) -> PkgInfo {
    // Find the root source file (lib.rs or main.rs)
    let source_file = find_source_file(pkg);
    let source_path = match source_file {
        Some(p) => p,
        None => return pkg_error(crate_name, "no lib.rs or main.rs found"),
    };
    let src_dir = match source_path.parent() {
        Some(d) => d.to_path_buf(),
        None => {
            return pkg_error(crate_name, &format!("cannot determine parent directory of {}", source_path.display()));
        }
    };

    let mut functions: Vec<Function> = Vec::new();
    let mut type_aliases: HashMap<String, String> = HashMap::new();
    let mut errors: Vec<String> = Vec::new();
    let mut processed_mods: Vec<PathBuf> = Vec::new();

    // Parse root module and walk submodules recursively
    collect_from_file(&source_path, &src_dir, &mut functions, &mut type_aliases, &mut errors, &mut processed_mods);

    PkgInfo {
        pkg: pkg.name.clone(),
        name: pkg.name.clone(),
        version: pkg.version.to_string(),
        functions,
        errors,
    }
}

/// Parse a file, extract functions and type aliases, and recurse into submodules.
fn collect_from_file(
    path: &PathBuf,
    src_dir: &PathBuf,
    functions: &mut Vec<Function>,
    type_aliases: &mut HashMap<String, String>,
    errors: &mut Vec<String>,
    processed: &mut Vec<PathBuf>,
) {
    // Dedup: skip already-processed files
    if processed.contains(path) { return; }
    processed.push(path.clone());

    let source_text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) => {
            errors.push(format!("cannot read {}: {}", path.display(), e));
            return;
        }
    };

    let syntax = match syn::parse_file(&source_text) {
        Ok(s) => s,
        Err(e) => {
            errors.push(format!("parse error in {}: {}", path.display(), e));
            return;
        }
    };

    // First pass: collect type aliases
    for item in &syntax.items {
        if let Item::Type(ty) = item {
            if matches!(ty.vis, Visibility::Public(_)) {
                let name = ty.ident.to_string();
                let sky = type_to_sky(&ty.ty, type_aliases);
                type_aliases.insert(name, sky);
            }
        }
    }

    // Second pass: walk items
    for item in &syntax.items {
        match item {
            Item::Fn(f) => {
                if matches!(f.vis, Visibility::Public(_)) {
                    if let Some(func) = inspect_fn(f, type_aliases, None, false, false, false, errors) {
                        functions.push(func);
                    }
                }
            }
            Item::Impl(imp) => {
                let self_ty_str = type_to_sky(&imp.self_ty, type_aliases);
                for impl_item in &imp.items {
                    if let syn::ImplItem::Fn(method) = impl_item {
                        if matches!(method.vis, Visibility::Public(_)) {
                            let wrapped = ItemFn {
                                attrs: method.attrs.clone(),
                                vis: method.vis.clone(),
                                sig: method.sig.clone(),
                                block: Box::new(method.block.clone()),
                            };
                            if let Some(func) = inspect_fn(
                                &wrapped,
                                type_aliases,
                                Some(&self_ty_str),
                                false,
                                false,
                                false,
                                errors,
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
                    if let syn::Fields::Named(ref fields) = s.fields {
                        for field in &fields.named {
                            if matches!(field.vis, Visibility::Public(_)) {
                                let field_name = field.ident.as_ref().unwrap().to_string();
                                let field_ty = type_to_sky(&field.ty, type_aliases);
                                let field_rust = quote::quote! { #field.ty }.to_string();
                                let sn = struct_name.clone();

                                functions.push(Function {
                                    name: format!("{}_get_{}", sn, field_name),
                                    params: vec![Param {
                                        name: "self".into(),
                                        ty: sn.clone(),
                                        sky_type: type_str_to_sky(&sn, &type_aliases),
                                        rust_type: sn.clone(),
                                    }],
                                    results: vec![Param {
                                        name: String::new(),
                                        ty: field_ty.clone(),
                                        sky_type: field_ty.clone(),
                                        rust_type: field_rust.clone(),
                                    }],
                                    variadic: false,
                                    effect: "pure".into(),
                                    exported: true,
                                    recv_type: sn.clone(),
                                    recv_rust_type: sn.clone(),
                                    method_name: field_name.clone(),
                                    is_field: true,
                                    is_field_set: false,
                                    is_pkg_var: false,
                                });

                                functions.push(Function {
                                    name: format!("{}_set_{}", sn, field_name),
                                    params: vec![
                                        Param {
                                            name: "self".into(),
                                            ty: sn.clone(),
                                            sky_type: type_str_to_sky(&sn, &type_aliases),
                                            rust_type: sn.clone(),
                                        },
                                        Param {
                                            name: "value".into(),
                                            ty: field_ty.clone(),
                                            sky_type: field_ty.clone(),
                                            rust_type: field_rust.clone(),
                                        },
                                    ],
                                    results: vec![Param {
                                        name: String::new(),
                                        ty: String::new(),
                                        sky_type: String::new(),
                                        rust_type: String::new(),
                                    }],
                                    variadic: false,
                                    effect: "pure".into(),
                                    exported: true,
                                    recv_type: sn.clone(),
                                    recv_rust_type: sn,
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
            Item::Mod(m) => {
                // Recurse into `pub mod <name>;` or `pub mod <name> { ... }`
                if matches!(m.vis, Visibility::Public(_)) {
                    let mod_name = m.ident.to_string();
                    // Determine the module file path
                    let mod_path = if let Some((_, body)) = &m.content {
                        // Inline `pub mod name { ... }` — write body items to a temp file
                        let synthetic = path.parent().unwrap_or(path).join(format!("{}__inline", mod_name));
                        let body_items: Vec<String> = body.iter().map(|item| {
                            quote::quote! { #item }.to_string()
                        }).collect();
                        let content = body_items.join("\n");
                        if let Err(e) = std::fs::write(&synthetic, &content) {
                            errors.push(format!("cannot write inline mod '{}': {}", mod_name, e));
                            continue;
                        }
                        synthetic
                    } else {
                        // `pub mod name;` — resolve to name.rs or name/mod.rs
                        let candidate1 = src_dir.join(format!("{}.rs", mod_name));
                        let candidate2 = src_dir.join(&mod_name).join("mod.rs");
                        if candidate1.exists() { candidate1 }
                        else if candidate2.exists() { candidate2 }
                        else {
                            errors.push(format!("submodule '{}' not found at {:?} or {:?}", mod_name, candidate1, candidate2));
                            continue;
                        }
                    };
                    collect_from_file(&mod_path, src_dir, functions, type_aliases, errors, processed);
                }
            }
            Item::Use(u) => {
                // Handle `pub use <path>::*;` — resolve and recurse
                if matches!(u.vis, Visibility::Public(_)) {
                    if let syn::UseTree::Glob(_) = &u.tree {
                        // Extract the path: e.g. `pub use submod::*;`
                        let path_str = quote::quote! { #u }.to_string();
                        // path_str is like "pub use submod::*;" or "use submod::*;"
                        let cleaned = path_str.trim_start_matches("pub ")
                            .trim_start_matches("use ")
                            .trim_end_matches(";")
                            .trim_end_matches(" ::*")
                            .trim_end_matches("::*");
                        if !cleaned.is_empty() {
                            let candidate1 = src_dir.join(format!("{}.rs", cleaned));
                            let candidate2 = src_dir.join(cleaned).join("mod.rs");
                            if candidate1.exists() {
                                collect_from_file(&candidate1, src_dir, functions, type_aliases, errors, processed);
                            } else if candidate2.exists() {
                                collect_from_file(&candidate2, src_dir, functions, type_aliases, errors, processed);
                            }
                            // Silently skip unresolved glob re-exports (common for external crate re-exports)
                        }
                    }
                }
            }
            _ => {}
        }
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
    errors: &mut Vec<String>,
) -> Option<Function> {
    let sig = &item_fn.sig;
    let name = sig.ident.to_string();
    let mut params: Vec<Param> = Vec::new();
    let mut results: Vec<Param> = Vec::new();

    // Check for generics — report diagnostic instead of silent skip
    if !sig.generics.params.is_empty() {
        let param_list: Vec<String> = sig.generics.params.iter().map(|p| {
            let s = quote::quote! { #p }.to_string();
            s
        }).collect();
        errors.push(format!(
            "function '{}' has generic parameters [{}] — requires monomorphisation, skipping",
            name,
            param_list.join(", ")
        ));
        return None;
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
                    ty: fn_recv_type.clone(),
                    sky_type: type_str_to_sky(&fn_recv_type, type_aliases),
                    rust_type: fn_recv_type.clone(),
                });
            }
            syn::FnArg::Typed(pat_type) => {
                let name = pat_to_name(&pat_type.pat);
                let sky = type_to_sky(&pat_type.ty, type_aliases);
                let rust_ty = quote::quote! { #pat_type.ty }.to_string();
                params.push(Param {
                    name,
                    ty: sky.clone(),
                    sky_type: sky.clone(),
                    rust_type: rust_ty,
                });
                // Check for function pointers (effectful signal)
                if is_fn_ptr_type(&pat_type.ty) {
                    // Mark as effectful
                }
            }
        }
    }

    // Return type
    let mut ret_ty_str = String::new();
    match &sig.output {
        syn::ReturnType::Type(_, ret_ty) => {
            ret_ty_str = quote::quote! { #ret_ty }.to_string();
            let sky = type_to_sky(ret_ty, type_aliases);
            if ret_str_contains_result(&ret_ty_str) {
                results.push(Param {
                    name: String::new(),
                    ty: sky.clone(),
                    sky_type: sky,
                    rust_type: ret_ty_str.clone(),
                });
            } else if ret_ty_str == "()" || ret_ty_str.is_empty() {
                // void return — no results
            } else {
                results.push(Param {
                    name: String::new(),
                    ty: sky.clone(),
                    sky_type: sky,
                    rust_type: ret_ty_str.clone(),
                });
            }
        }
        syn::ReturnType::Default => {}
    }

    // Determine effect: async, Future-returning, Result-returning, fn-ptr params
    let effect = classify_effect(&sig.output, &params, sig.asyncness.is_some(), &ret_ty_str);

    let variadic = sig.variadic.is_some();

    Some(Function {
        name,
        params,
        results,
        variadic,
        effect,
        exported: matches!(item_fn.vis, Visibility::Public(_)),
        recv_type: fn_recv_type.clone(),
        recv_rust_type: fn_recv_type,
        method_name,
        is_field,
        is_field_set,
        is_pkg_var,
    })
}

// ── Effect classification ──────────────────────────────────────────────

fn classify_effect(
    ret_type: &syn::ReturnType,
    params: &[Param],
    is_async: bool,
    ret_ty_str: &str,
) -> String {
    // Async functions are always effectful (they return impl Future)
    if is_async {
        return "effectful".into();
    }

    // Future-returning functions (Pin<Box<dyn Future<...>>> or bare Future)
    if ret_ty_str.contains("Pin<") || ret_ty_str.contains("Future<") {
        return "effectful".into();
    }

    // Check return type for Result<T, E>
    let ret_str = match ret_type {
        syn::ReturnType::Type(_, ty) => quote::quote! { #ty }.to_string(),
        _ => String::new(),
    };

    if ret_str.starts_with("Result ") || ret_str.starts_with("Result<")
        || ret_str.contains("::Result ") || ret_str.contains("::Result<")
    {
        return "fallible".into();
    }

    // Check params for function pointers, impl Fn*, or channels
    for p in params {
        if p.ty.starts_with("fn(") || p.ty.starts_with("fn (")
            || p.ty.contains("impl Fn(") || p.ty.contains("impl FnOnce(") || p.ty.contains("impl FnMut(")
            || p.ty.contains("Receiver<") || p.ty.contains("Sender<") {
            return "effectful".into();
        }
    }

    "pure".into()
}

// ── Type mapping (Rust → Sky) ─────────────────────────────────────────

fn type_to_sky(ty: &Type, aliases: &HashMap<String, String>) -> String {
    // Handle arrays early: [T; N] → [T; N] string form, then sanitized by type_str_to_sky
    if let Type::Array(arr) = ty {
        let elem = type_to_sky(&arr.elem, aliases);
        let len = quote::quote! { #arr.len }.to_string();
        return format!("[{}; {}]", elem, len);
    }
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
    // Rust: Result<T, E> where T = ok, E = error.
    // Sky:  Result ErrorType OkType (error first, ok second).
    if let Some(inner) = try_extract(&s, "Result") {
        let parts: Vec<&str> = split_top_level(&inner, ',');
        let ok_ty = if parts.len() >= 1 { type_str_to_sky(parts[0], aliases) } else { "()".into() };
        let err_ty = if parts.len() >= 2 { type_str_to_sky(parts[1], aliases) } else { "String".into() };
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

    // Pin<Box<dyn Future<Output = T>>> → Task SkyError T
    // Also bare Future<Output = T> (async fn sugar)
    let is_future = s.contains("Pin<") || s.contains("Pin <") || s.contains("Future<");
    if is_future {
        // Try to extract the Output type from Future<Output = T>
        if let Some(out_start) = s.find("Output =") {
            let after = &s[out_start + 8..]; // skip "Output ="
            let trimmed = after.trim();
            // Find the end: the next '>' at depth 0, or end of string for Pin<>
            let mut depth = 0i32;
            let mut end = trimmed.len();
            for (i, c) in trimmed.char_indices() {
                match c {
                    '<' => depth += 1,
                    '>' if depth == 0 => { end = i; break; }
                    '>' => depth -= 1,
                    _ => {}
                }
            }
            let out_ty = trimmed[..end].trim();
            return format!("Task SkyError {}", type_str_to_sky(out_ty, aliases));
        }
        return "Task SkyError String".into();
    }

    // ── T3: sanitise unrepresentable Rust type syntax ─────────────────
    // If we reach here and the type still contains Rust-specific syntax
    // (tuples, arrays, impl Trait, Self, u128), map to safe Sky types.
    if s.contains('(') && !s.starts_with("Result ") && !s.starts_with("Maybe ") {
        return "String".to_string();  // bare tuple — opaque
    }
    if s.contains('[') && !s.starts_with("Task ") {
        let inner_trimmed = s.trim_start_matches('&').trim();
        if inner_trimmed.starts_with('[') {
            return "Bytes".to_string();  // array like [u8; 16] or &[u8; N]
        }
    }
    if s.starts_with("impl ") || s.starts_with("dyn ") {
        return "String".to_string();
    }
    let s_clean = s.trim_start_matches('&').trim();
    if s_clean == "u128" || s_clean == "i128" || s_clean == "Self" {
        return "String".to_string();
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

fn ret_str_contains_result(s: &str) -> bool {
    s.starts_with("Result ") || s.starts_with("Result<")
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
        || s.contains("impl Fn(") || s.contains("impl FnOnce(") || s.contains("impl FnMut(")
        || s.contains("Box<dyn Fn") || s.contains("Box<dyn FnOnce") || s.contains("Box<dyn FnMut")
        || s.contains("&dyn Fn") || s.contains("&dyn FnOnce") || s.contains("&dyn FnMut")
}

fn find_source_file(pkg: &cargo_metadata::Package) -> Option<PathBuf> {
    let root: PathBuf = pkg.manifest_path.parent()?.join("src").into();
    for name in &["lib.rs", "main.rs"] {
        let candidate = root.join(name);
        if candidate.exists() {
            return Some(candidate);
        }
    }
    None
}

fn pkg_error(crate_name: &str, msg: &str) -> PkgInfo {
    PkgInfo {
        pkg: crate_name.into(),
        name: crate_name.into(),
        version: String::new(),
        functions: vec![],
        errors: vec![msg.into()],
    }
}
