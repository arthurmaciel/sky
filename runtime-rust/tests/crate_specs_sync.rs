//! Drift guard for the crate-version single source of truth.
//!
//! `src/Sky/Generate/Rust/Builder/crate-specs.toml` is authoritative for the
//! crate versions the Rust codegen emits into a GENERATED project. This crate's
//! own `Cargo.toml` is a separate file cargo needs to build the runtime — but it
//! MUST pin the same versions (a generated project copies this runtime's source,
//! so it has to compile against the versions this crate was tested with).
//!
//! This test asserts every crate in crate-specs.toml appears in
//! runtime-rust/Cargo.toml at the same version. Bump a version in ONE place and
//! this fails until the other is updated.

use std::collections::BTreeMap;
use std::path::PathBuf;

/// Extract the `version` from a Cargo dependency value: `"0.4"` or
/// `{ version = "0.4", ... }`. Returns the bare version string.
fn version_of(value: &str) -> Option<String> {
    let v = value.trim();
    if let Some(rest) = v.strip_prefix('{') {
        // inline table — find `version = "X"`
        let key = "version";
        let idx = rest.find(key)?;
        let after = &rest[idx + key.len()..];
        let after = after.trim_start().strip_prefix('=')?.trim_start();
        let after = after.strip_prefix('"')?;
        let end = after.find('"')?;
        Some(after[..end].to_string())
    } else if let Some(rest) = v.strip_prefix('"') {
        let end = rest.find('"')?;
        Some(rest[..end].to_string())
    } else {
        None
    }
}

/// Parse `name = <value>` dependency lines into name → version. `only_section`
/// limits parsing to lines under `[dependencies]` / `[target...dependencies]`
/// (so `[features]` etc. are skipped) when `true`.
fn parse_deps(text: &str, only_dep_sections: bool) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    let mut in_deps = !only_dep_sections;
    for raw in text.lines() {
        let line = raw.trim();
        if line.starts_with('#') || line.is_empty() {
            continue;
        }
        if line.starts_with('[') {
            in_deps = line.contains("dependencies");
            continue;
        }
        if !in_deps {
            continue;
        }
        if let Some((name, value)) = line.split_once('=') {
            let name = name.trim();
            // a bare `name = "x"` whose name has no spaces/quotes is a crate dep
            if name.is_empty() || name.contains(' ') || name.contains('"') {
                continue;
            }
            if let Some(ver) = version_of(value) {
                out.entry(name.to_string()).or_insert(ver);
            }
        }
    }
    out
}

#[test]
fn crate_specs_match_runtime_cargo_toml() {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let specs_path = manifest.join("../src/Sky/Generate/Rust/Builder/crate-specs.toml");
    let cargo_path = manifest.join("Cargo.toml");

    let specs_txt = std::fs::read_to_string(&specs_path)
        .unwrap_or_else(|e| panic!("read {:?}: {}", specs_path, e));
    let cargo_txt = std::fs::read_to_string(&cargo_path)
        .unwrap_or_else(|e| panic!("read {:?}: {}", cargo_path, e));

    let specs = parse_deps(&specs_txt, false); // crate-specs.toml has no sections
    let cargo = parse_deps(&cargo_txt, true); // only the [dependencies] tables

    let mut problems = Vec::new();
    for (name, spec_ver) in &specs {
        match cargo.get(name) {
            None => problems.push(format!(
                "{name}: in crate-specs.toml ({spec_ver}) but not in runtime-rust/Cargo.toml"
            )),
            Some(cargo_ver) if cargo_ver != spec_ver => {
                problems.push(format!(
                    "{name}: crate-specs.toml = {spec_ver}, Cargo.toml = {cargo_ver}"
                ));
            }
            Some(_) => {}
        }
    }
    assert!(
        problems.is_empty(),
        "crate-version drift between crate-specs.toml and runtime-rust/Cargo.toml:\n  {}",
        problems.join("\n  ")
    );
}
