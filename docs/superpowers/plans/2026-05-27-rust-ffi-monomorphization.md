# Rust FFI — generic-function monomorphization-on-demand (Alt-1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop dropping generic functions/methods in the Rust FFI inspector; instead, when every generic parameter's trait bound maps to a Sky-representable concrete type, substitute that type and emit a normal monomorphic binding.

**Architecture:** All changes are inside the inspector `tools/sky-ffi-inspect-rs/src/main.rs`. We add a `bound → concrete-type-JSON` table (`bound_to_concrete`), per-parameter bound resolution (`resolve_param_bounds`, `resolve_generics`), and a JSON tree rewriter (`subst_generic_json`) that replaces `{generic:"T"}` and resolvable `impl Trait` nodes with concrete `Vec<u8>`/`String` nodes *before* the existing type mappers run. The unconditional generic-drop at `main.rs:594` is replaced by `let subst_map = resolve_generics(fn_data)?;` (still drops when unresolvable). All existing downstream filters (lifetime, borrowed-result, array/slice, nameability) run unchanged on the substituted concretes — the soundness interlock. FfiGen/Builder/Go are untouched: the emitted binding looks fully monomorphic, the generated Rust call (`hex::encode(coerced)`) is normal, and rustc infers the type parameter.

**Tech Stack:** Rust (the inspector crate, `serde_json`), the Sky compiler (Haskell, rebuilt to re-embed the inspector via Template Haskell), Sky example (`.sky`), the `/ffi-audit` Python skill for coverage measurement.

**Spec:** `docs/superpowers/specs/2026-05-27-rust-ffi-monomorphization-design.md`

**Deviation from spec note:** §5.1 of the spec described *borrowed* canonical concretes (`&[u8]`/`&str`). This plan uses *owned* concretes (`Vec<u8>`/`String`) instead — simpler JSON nodes (no `borrowed_ref` format-key drift), equally valid type substitutions for every bound, and the same Sky types and FfiGen coercion. No observable difference.

---

## File map

| File | Responsibility | Change |
|---|---|---|
| `tools/sky-ffi-inspect-rs/src/main.rs` | the inspector — all logic + unit tests | Modify |
| `examples/rust/16-hex/sky.toml` | example project config | Create |
| `examples/rust/16-hex/src/Main.sky` | end-to-end proof (encode + decode round-trip) | Create |
| `runtime-rust/README.md` | "Measured coverage" table — hex verdict shift | Modify (Task 10) |

All new Rust helpers live in `main.rs` at module scope (above the `#[cfg(test)] mod tests` block at line ~1518). Unit tests go inside that existing `mod tests`.

---

## Task 1: Concrete-node builders + `bound_to_concrete`

**Files:**
- Modify: `tools/sky-ffi-inspect-rs/src/main.rs` (add functions near `subst_self`, ~line 795; tests in `mod tests`)

- [ ] **Step 1: Write the failing tests** (add inside `mod tests`, after `test_is_byte_seq`)

```rust
    fn trait_bound(path: &str, args: Vec<serde_json::Value>) -> serde_json::Value {
        let type_args: Vec<_> = args.into_iter().map(|t| serde_json::json!({ "type": t })).collect();
        serde_json::json!({ "trait_bound": { "trait": {
            "path": path, "name": path, "id": 0,
            "args": { "angle_bracketed": { "args": type_args, "constraints": [] } }
        }, "modifier": "none" } })
    }

    #[test]
    fn test_bound_to_concrete() {
        // AsRef<[u8]> / Borrow<[u8]>  -> Vec<u8> (List Int)
        let asref_u8 = trait_bound("AsRef", vec![serde_json::json!({ "slice": { "primitive": "u8" } })]);
        assert_eq!(bound_to_concrete(&asref_u8), Some(vec_u8_node()));
        // AsRef<str> / Borrow<str>    -> String
        assert_eq!(bound_to_concrete(&trait_bound("AsRef", vec![prim("str")])), Some(string_node()));
        // Display / ToString (no arg) -> String
        assert_eq!(bound_to_concrete(&trait_bound("Display", vec![])), Some(string_node()));
        assert_eq!(bound_to_concrete(&trait_bound("ToString", vec![])), Some(string_node()));
        // Into<Vec<u8>> -> Vec<u8> ; Into<String> -> String
        assert_eq!(bound_to_concrete(&trait_bound("Into", vec![path_with_args("Vec", vec![prim("u8")])])), Some(vec_u8_node()));
        assert_eq!(bound_to_concrete(&trait_bound("Into", vec![path("String")])), Some(string_node()));
        // Unknown / unsupported -> None
        assert_eq!(bound_to_concrete(&trait_bound("FromStr", vec![])), None);
        assert_eq!(bound_to_concrete(&trait_bound("AsRef", vec![prim("u16")])), None);
    }
```

- [ ] **Step 2: Run to verify it fails to compile** (functions undefined)

Run: `cd tools/sky-ffi-inspect-rs && cargo test test_bound_to_concrete`
Expected: FAIL — `cannot find function bound_to_concrete` / `vec_u8_node` / `string_node`.

- [ ] **Step 3: Implement the builders + table** (module scope, before `mod tests`)

```rust
// ── Monomorphisation-on-demand (Alt-1) ─────────────────────────────────
// A generic param bound maps to a concrete, Sky-representable type that we
// substitute into the signature so the inspector can emit a normal binding.
// We use OWNED concretes (Vec<u8>/String): valid for every bound below
// (Vec<u8>: AsRef<[u8]>+Into<Vec<u8>>+IntoIterator<Item=u8>; String:
// AsRef<str>+Into<String>+Display+ToString), and the exact raw shapes FfiGen
// already coerces from Sky List Int / String.

fn vec_u8_node() -> serde_json::Value {
    serde_json::json!({ "resolved_path": { "name": "Vec", "path": "Vec", "id": 0,
        "args": { "angle_bracketed": { "args": [{ "type": { "primitive": "u8" } }], "constraints": [] } } } })
}

fn string_node() -> serde_json::Value {
    serde_json::json!({ "resolved_path": { "name": "String", "path": "String", "id": 0, "args": null } })
}

/// True if a rustdoc type node is the `u8` slice `[u8]`.
fn node_is_u8_slice(t: &serde_json::Value) -> bool {
    t.get("slice").and_then(|s| s.get("primitive")).and_then(|p| p.as_str()) == Some("u8")
}
/// True if a rustdoc type node is the primitive `str` (possibly borrowed).
fn node_is_str(t: &serde_json::Value) -> bool {
    if t.get("primitive").and_then(|p| p.as_str()) == Some("str") { return true; }
    let inner = t.get("borrowed_ref").and_then(|b| b.get("type").or_else(|| b.get("type_")));
    inner.map(node_is_str).unwrap_or(false)
}
/// True if a rustdoc type node is `Vec<u8>`.
fn node_is_vec_u8(t: &serde_json::Value) -> bool {
    let rp = match t.get("resolved_path") { Some(r) => r, None => return false };
    let name = rp.get("name").or_else(|| rp.get("path")).and_then(|n| n.as_str()).unwrap_or("");
    if name.rsplit("::").next().unwrap_or(name) != "Vec" { return false; }
    rp.get("args").and_then(|a| a.get("angle_bracketed")).and_then(|ab| ab.get("args"))
        .and_then(|v| v.as_array()).and_then(|a| a.first())
        .and_then(|a| a.get("type"))
        .map(|t| t.get("primitive").and_then(|p| p.as_str()) == Some("u8"))
        .unwrap_or(false)
}
/// True if a rustdoc type node is `String`.
fn node_is_string(t: &serde_json::Value) -> bool {
    let rp = match t.get("resolved_path") { Some(r) => r, None => return false };
    let name = rp.get("name").or_else(|| rp.get("path")).and_then(|n| n.as_str()).unwrap_or("");
    name.rsplit("::").next().unwrap_or(name) == "String"
}

/// Map a single trait bound to the concrete type-JSON node to substitute, or
/// `None` if the bound is not in the v1 table.
fn bound_to_concrete(bound: &serde_json::Value) -> Option<serde_json::Value> {
    let tr = bound.get("trait_bound")?.get("trait")?;
    let path = tr.get("path").or_else(|| tr.get("name")).and_then(|p| p.as_str())?;
    let name = path.rsplit("::").next().unwrap_or(path);
    let args: Vec<&serde_json::Value> = tr.get("args")
        .and_then(|a| a.get("angle_bracketed")).and_then(|ab| ab.get("args"))
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().filter_map(|a| a.get("type")).collect())
        .unwrap_or_default();
    match name {
        "Display" | "ToString" => Some(string_node()),
        "AsRef" | "Borrow" => {
            let arg = args.first()?;
            if node_is_u8_slice(arg) { Some(vec_u8_node()) }
            else if node_is_str(arg) { Some(string_node()) }
            else { None }
        }
        "Into" => {
            let arg = args.first()?;
            if node_is_vec_u8(arg) { Some(vec_u8_node()) }
            else if node_is_string(arg) { Some(string_node()) }
            else { None }
        }
        _ => None,
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd tools/sky-ffi-inspect-rs && cargo test test_bound_to_concrete`
Expected: PASS (`test tests::test_bound_to_concrete ... ok`).

- [ ] **Step 5: Commit**

```bash
git add tools/sky-ffi-inspect-rs/src/main.rs
git commit -m "feat(rust): inspector bound_to_concrete table + concrete-node builders (Alt-1 step 1)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: Marker-bound classification + `resolve_param_bounds`

**Files:**
- Modify: `tools/sky-ffi-inspect-rs/src/main.rs` (add functions after `bound_to_concrete`; tests in `mod tests`)

- [ ] **Step 1: Write the failing test**

```rust
    #[test]
    fn test_resolve_param_bounds() {
        let asref_u8 = trait_bound("AsRef", vec![serde_json::json!({ "slice": { "primitive": "u8" } })]);
        let clone = trait_bound("Clone", vec![]);
        let send = trait_bound("Send", vec![]);
        let foo = trait_bound("SomeWeirdTrait", vec![]);
        let asref_str = trait_bound("AsRef", vec![prim("str")]);

        // shape bound alone -> resolves
        assert_eq!(resolve_param_bounds(&[asref_u8.clone()]), Some(vec_u8_node()));
        // shape + marker bounds -> markers ignored, resolves
        assert_eq!(resolve_param_bounds(&[asref_u8.clone(), clone.clone(), send]), Some(vec_u8_node()));
        // only markers -> can't pin a type -> None
        assert_eq!(resolve_param_bounds(&[clone]), None);
        // an unknown non-marker bound -> None (unsound to guess)
        assert_eq!(resolve_param_bounds(&[asref_u8.clone(), foo]), None);
        // two conflicting shape bounds -> None
        assert_eq!(resolve_param_bounds(&[asref_u8, asref_str]), None);
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd tools/sky-ffi-inspect-rs && cargo test test_resolve_param_bounds`
Expected: FAIL — `cannot find function resolve_param_bounds`.

- [ ] **Step 3: Implement** (after `bound_to_concrete`)

```rust
/// Auto/marker traits that don't constrain the Sky-facing type — ignored when
/// resolving a param's bounds.
const MARKER_TRAITS: &[&str] = &[
    "Sized", "Send", "Sync", "Copy", "Clone", "Debug", "Default", "Unpin",
    "RefUnwindSafe", "UnwindSafe", "Eq", "PartialEq", "Hash", "Ord", "PartialOrd",
];

/// A bound that contributes no type information: a marker/auto trait, or a
/// lifetime/outlives bound (no `trait_bound` key).
fn is_marker_bound(bound: &serde_json::Value) -> bool {
    let tr = match bound.get("trait_bound").and_then(|tb| tb.get("trait")) {
        Some(t) => t,
        None => return true, // outlives/lifetime bound -> ignore
    };
    let path = tr.get("path").or_else(|| tr.get("name")).and_then(|p| p.as_str()).unwrap_or("");
    let name = path.rsplit("::").next().unwrap_or(path);
    MARKER_TRAITS.contains(&name)
}

/// Resolve a parameter's full bound list to a single concrete node, or `None`
/// (drop) if: only markers (no type pinned), an unmappable non-marker bound, or
/// two disagreeing shape bounds.
fn resolve_param_bounds(bounds: &[serde_json::Value]) -> Option<serde_json::Value> {
    let mut concrete: Option<serde_json::Value> = None;
    for b in bounds {
        if is_marker_bound(b) { continue; }
        match bound_to_concrete(b) {
            Some(c) => match &concrete {
                Some(prev) if *prev != c => return None, // conflict
                Some(_) => {}
                None => concrete = Some(c),
            },
            None => return None, // non-marker bound we can't map
        }
    }
    concrete
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd tools/sky-ffi-inspect-rs && cargo test test_resolve_param_bounds`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/sky-ffi-inspect-rs/src/main.rs
git commit -m "feat(rust): inspector marker-bound classification + resolve_param_bounds (Alt-1 step 2)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: `subst_generic_json` (JSON tree rewriter)

**Files:**
- Modify: `tools/sky-ffi-inspect-rs/src/main.rs` (add function; tests in `mod tests`)

- [ ] **Step 1: Write the failing test**

```rust
    #[test]
    fn test_subst_generic_json() {
        let mut map = std::collections::HashMap::new();
        map.insert("T".to_string(), vec_u8_node());
        // bare {generic:"T"} -> Vec<u8>
        assert_eq!(subst_generic_json(&serde_json::json!({ "generic": "T" }), &map), vec_u8_node());
        // nested Option<T> -> Option<Vec<u8>>: the T node deep inside is replaced
        let opt_t = path_with_args("Option", vec![serde_json::json!({ "generic": "T" })]);
        let got = subst_generic_json(&opt_t, &map);
        assert_eq!(sky(&got), "Maybe (List Int)");
        // an unrelated generic "U" not in map is left intact
        assert_eq!(subst_generic_json(&serde_json::json!({ "generic": "U" }), &map),
                   serde_json::json!({ "generic": "U" }));
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd tools/sky-ffi-inspect-rs && cargo test test_subst_generic_json`
Expected: FAIL — `cannot find function subst_generic_json`.

- [ ] **Step 3: Implement** (after `resolve_param_bounds`)

```rust
/// Recursively replace every `{"generic":"NAME"}` node whose NAME is in `map`
/// with the mapped concrete type node. Other nodes pass through unchanged.
/// (`impl Trait` nodes are handled separately in Task 6.)
fn subst_generic_json(
    val: &serde_json::Value,
    map: &std::collections::HashMap<String, serde_json::Value>,
) -> serde_json::Value {
    if let Some(g) = val.get("generic").and_then(|g| g.as_str()) {
        if let Some(concrete) = map.get(g) {
            return concrete.clone();
        }
    }
    match val {
        serde_json::Value::Object(obj) => serde_json::Value::Object(
            obj.iter().map(|(k, v)| (k.clone(), subst_generic_json(v, map))).collect(),
        ),
        serde_json::Value::Array(arr) => serde_json::Value::Array(
            arr.iter().map(|v| subst_generic_json(v, map)).collect(),
        ),
        other => other.clone(),
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd tools/sky-ffi-inspect-rs && cargo test test_subst_generic_json`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/sky-ffi-inspect-rs/src/main.rs
git commit -m "feat(rust): inspector subst_generic_json tree rewriter (Alt-1 step 3)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: `resolve_generics` (per-function map; const/where/output handling)

**Files:**
- Modify: `tools/sky-ffi-inspect-rs/src/main.rs` (add function; tests in `mod tests`)

- [ ] **Step 1: Write the failing test**

```rust
    fn type_param(name: &str, bounds: Vec<serde_json::Value>) -> serde_json::Value {
        serde_json::json!({ "name": name, "kind": { "type": { "bounds": bounds, "default": null, "is_synthetic": false } } })
    }
    fn fn_with_generics(params: Vec<serde_json::Value>, wheres: Vec<serde_json::Value>) -> serde_json::Value {
        serde_json::json!({ "generics": { "params": params, "where_predicates": wheres } })
    }

    #[test]
    fn test_resolve_generics() {
        let asref_u8 = trait_bound("AsRef", vec![serde_json::json!({ "slice": { "primitive": "u8" } })]);
        let display = trait_bound("Display", vec![]);

        // no generics -> empty map (Some)
        assert_eq!(resolve_generics(&fn_with_generics(vec![], vec![])), Some(std::collections::HashMap::new()));

        // <T: AsRef<[u8]>> -> {T: Vec<u8>}
        let r = resolve_generics(&fn_with_generics(vec![type_param("T", vec![asref_u8.clone()])], vec![])).unwrap();
        assert_eq!(r.get("T"), Some(&vec_u8_node()));

        // two params both resolve
        let r2 = resolve_generics(&fn_with_generics(
            vec![type_param("T", vec![asref_u8.clone()]), type_param("U", vec![display])], vec![])).unwrap();
        assert_eq!(r2.get("T"), Some(&vec_u8_node()));
        assert_eq!(r2.get("U"), Some(&string_node()));

        // unresolvable bound -> None (drop whole fn)
        assert_eq!(resolve_generics(&fn_with_generics(vec![type_param("T", vec![trait_bound("FromStr", vec![])])], vec![])), None);

        // const generic present -> None
        let const_p = serde_json::json!({ "name": "N", "kind": { "const": { "type": { "primitive": "usize" } } } });
        assert_eq!(resolve_generics(&fn_with_generics(vec![const_p], vec![])), None);

        // bound supplied via where-predicate instead of inline
        let wp = serde_json::json!({ "bound_predicate": { "type": { "generic": "T" }, "bounds": [asref_u8] } });
        let r3 = resolve_generics(&fn_with_generics(vec![type_param("T", vec![])], vec![wp])).unwrap();
        assert_eq!(r3.get("T"), Some(&vec_u8_node()));
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd tools/sky-ffi-inspect-rs && cargo test test_resolve_generics`
Expected: FAIL — `cannot find function resolve_generics`.

- [ ] **Step 3: Implement** (after `subst_generic_json`)

```rust
/// Build the substitution map for a function's generic params, or `None` if the
/// function should be dropped (a `const` generic, or any type param whose bounds
/// don't resolve). Lifetime params are ignored. A type param that appears only in
/// return position with an unmappable bound (e.g. `T: FromStr`) yields `None`,
/// which is the correct drop. Bounds are gathered from both inline param bounds
/// and `where_predicates`.
fn resolve_generics(
    fn_data: &serde_json::Value,
) -> Option<std::collections::HashMap<String, serde_json::Value>> {
    let params = match fn_data["generics"]["params"].as_array() {
        Some(p) => p,
        None => return Some(std::collections::HashMap::new()),
    };

    // where-clause bounds, keyed by generic name
    let mut where_bounds: std::collections::HashMap<String, Vec<serde_json::Value>> =
        std::collections::HashMap::new();
    if let Some(wps) = fn_data["generics"]["where_predicates"].as_array() {
        for wp in wps {
            if let Some(bp) = wp.get("bound_predicate") {
                if let Some(g) = bp.get("type").and_then(|t| t.get("generic")).and_then(|g| g.as_str()) {
                    if let Some(bs) = bp.get("bounds").and_then(|b| b.as_array()) {
                        where_bounds.entry(g.to_string()).or_default().extend(bs.iter().cloned());
                    }
                }
            }
        }
    }

    let mut map = std::collections::HashMap::new();
    for p in params {
        let kind = &p["kind"];
        if kind.get("const").is_some() { return None; }   // const generic -> drop
        if kind.get("lifetime").is_some() { continue; }   // lifetime param -> ignore
        let name = p.get("name").and_then(|n| n.as_str()).unwrap_or("");
        let mut bounds: Vec<serde_json::Value> = kind.get("type")
            .and_then(|t| t.get("bounds")).and_then(|b| b.as_array())
            .cloned().unwrap_or_default();
        if let Some(extra) = where_bounds.get(name) { bounds.extend(extra.iter().cloned()); }
        match resolve_param_bounds(&bounds) {
            Some(concrete) => { map.insert(name.to_string(), concrete); }
            None => return None, // unresolvable type param -> drop whole fn
        }
    }
    Some(map)
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd tools/sky-ffi-inspect-rs && cargo test test_resolve_generics`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/sky-ffi-inspect-rs/src/main.rs
git commit -m "feat(rust): inspector resolve_generics (const/where/unresolvable drop) (Alt-1 step 4)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: Wire monomorphization into `parse_fn_item`

**Files:**
- Modify: `tools/sky-ffi-inspect-rs/src/main.rs` (replace the generic-drop at ~594; substitute in the input loop ~628 and the output block ~650; tests in `mod tests`)

- [ ] **Step 1: Write the failing integration test** (drives the real `parse_fn_item`)

```rust
    // Build a function item shaped like rustdoc's: encode<T: AsRef<[u8]>>(data: T) -> String
    fn encode_fn_data() -> serde_json::Value {
        let asref_u8 = trait_bound("AsRef", vec![serde_json::json!({ "slice": { "primitive": "u8" } })]);
        serde_json::json!({
            "header": { "is_async": false, "is_unsafe": false },
            "generics": { "params": [ type_param("T", vec![asref_u8]) ], "where_predicates": [] },
            "sig": { "inputs": [ ["data", { "generic": "T" }] ], "output": prim("str") }
        })
    }

    #[test]
    fn test_parse_fn_item_monomorphises() {
        let f = parse_fn_item("encode", &encode_fn_data(), &HashMap::new(), None)
            .expect("encode<T:AsRef<[u8]>> should now bind, not drop");
        assert_eq!(f.name, "encode");
        assert_eq!(f.params.len(), 1);
        assert_eq!(f.params[0].sky_type, "List Int");   // T -> Vec<u8> -> List Int
        assert_eq!(f.params[0].rust_type, "Vec<u8>");
        assert_eq!(f.results[0].sky_type, "String");    // -> str -> String
    }

    #[test]
    fn test_parse_fn_item_drops_unresolvable_generic() {
        // parse<T: FromStr>() -> T  must still drop
        let fd = serde_json::json!({
            "header": { "is_async": false, "is_unsafe": false },
            "generics": { "params": [ type_param("T", vec![trait_bound("FromStr", vec![])]) ], "where_predicates": [] },
            "sig": { "inputs": [], "output": { "generic": "T" } }
        });
        assert!(parse_fn_item("parse", &fd, &HashMap::new(), None).is_none());
    }

    #[test]
    fn test_parse_fn_item_nongeneric_unchanged() {
        // fn len(s: &str) -> u64  : no generics, behaves exactly as before
        let fd = serde_json::json!({
            "header": { "is_async": false, "is_unsafe": false },
            "generics": { "params": [], "where_predicates": [] },
            "sig": { "inputs": [ ["s", borrowed(prim("str"))] ], "output": prim("u64") }
        });
        let f = parse_fn_item("len", &fd, &HashMap::new(), None).unwrap();
        assert_eq!(f.params[0].sky_type, "String");
        assert_eq!(f.results[0].sky_type, "Int");
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd tools/sky-ffi-inspect-rs && cargo test test_parse_fn_item`
Expected: FAIL — `test_parse_fn_item_monomorphises` returns `None` (still dropped by the old `:594` block).

- [ ] **Step 3a: Replace the generic-drop block** at `main.rs:592-597`

Replace this:
```rust
    // Skip generic functions — type parameters can't be resolved without
    // a concrete call site.  This matches the previous syn-based behaviour.
    if let Some(params) = fn_data["generics"]["params"].as_array() {
        if !params.is_empty() {
            return None;
        }
    }
```
with this:
```rust
    // Monomorphise-on-demand (Alt-1): resolve each generic param's bound to a
    // concrete Sky-representable type. `None` => unresolvable => drop the fn,
    // exactly as the old wholesale skip did, but now only when we genuinely
    // cannot pick a sound concrete type.
    let subst_map = resolve_generics(fn_data)?;
```

- [ ] **Step 3b: Substitute in the ordinary-parameter loop** (the `for input in inputs` loop, ~628). Change the type-JSON source from a borrow of `input[1]` to the substituted owned value:

Replace:
```rust
        let type_json = &input[1];
        let sky = rustdoc_type_to_sky(type_json, aliases);
        let rust = rustdoc_type_to_rust_str(type_json);
```
with:
```rust
        let type_json = subst_generic_json(&input[1], &subst_map);
        let sky = rustdoc_type_to_sky(&type_json, aliases);
        let rust = rustdoc_type_to_rust_str(&type_json);
```

- [ ] **Step 3c: Substitute in the return block** (the `if !output.is_null()` block, ~650).

Replace:
```rust
    if !output.is_null() {
        let sky = rustdoc_type_to_sky(output, aliases);
        let rust = rustdoc_type_to_rust_str(output);
```
with:
```rust
    if !output.is_null() {
        let out_json = subst_generic_json(output, &subst_map);
        let sky = rustdoc_type_to_sky(&out_json, aliases);
        let rust = rustdoc_type_to_rust_str(&out_json);
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd tools/sky-ffi-inspect-rs && cargo test test_parse_fn_item`
Expected: PASS (all three: monomorphises, drops-unresolvable, nongeneric-unchanged).

- [ ] **Step 5: Commit**

```bash
git add tools/sky-ffi-inspect-rs/src/main.rs
git commit -m "feat(rust): wire monomorphisation into parse_fn_item (Alt-1 step 5)

Replace the wholesale generic-drop with resolve_generics + subst_generic_json:
generic fns whose bounds map to a Sky type now emit a monomorphic binding;
unresolvable ones still drop. Non-generic fns are byte-identical.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 6: `impl Trait` argument resolution

**Files:**
- Modify: `tools/sky-ffi-inspect-rs/src/main.rs` (extend `subst_generic_json`; add a guard + wire it; tests)

- [ ] **Step 1: Write the failing test**

```rust
    #[test]
    fn test_impl_trait_arg() {
        // fn write_all(data: impl AsRef<[u8]>) -> ()  : impl-Trait arg -> List Int
        let asref_u8 = trait_bound("AsRef", vec![serde_json::json!({ "slice": { "primitive": "u8" } })]);
        let fd = serde_json::json!({
            "header": { "is_async": false, "is_unsafe": false },
            "generics": { "params": [], "where_predicates": [] },
            "sig": { "inputs": [ ["data", { "impl_trait": [asref_u8] }] ], "output": null }
        });
        let f = parse_fn_item("write_all", &fd, &HashMap::new(), None).unwrap();
        assert_eq!(f.params[0].sky_type, "List Int");
        assert_eq!(f.params[0].rust_type, "Vec<u8>");

        // impl Trait with an unmappable bound -> drop
        let fd2 = serde_json::json!({
            "header": { "is_async": false, "is_unsafe": false },
            "generics": { "params": [], "where_predicates": [] },
            "sig": { "inputs": [ ["x", { "impl_trait": [trait_bound("FromStr", vec![])] }] ], "output": null }
        });
        assert!(parse_fn_item("f", &fd2, &HashMap::new(), None).is_none());
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd tools/sky-ffi-inspect-rs && cargo test test_impl_trait_arg`
Expected: FAIL — `impl_trait` arg currently maps to `"String"` (line ~1168), so `sky_type` is `"String"`, not `"List Int"`; and the unmappable case is not dropped.

- [ ] **Step 3a: Extend `subst_generic_json`** to also replace resolvable `impl_trait` nodes. Replace the whole function body's leading check with:

```rust
fn subst_generic_json(
    val: &serde_json::Value,
    map: &std::collections::HashMap<String, serde_json::Value>,
) -> serde_json::Value {
    if let Some(g) = val.get("generic").and_then(|g| g.as_str()) {
        if let Some(concrete) = map.get(g) {
            return concrete.clone();
        }
    }
    // impl Trait: replace with the concrete the bounds resolve to (if any).
    if let Some(bounds) = val.get("impl_trait").and_then(|b| b.as_array()) {
        if let Some(concrete) = resolve_param_bounds(bounds) {
            return concrete;
        }
    }
    match val {
        serde_json::Value::Object(obj) => serde_json::Value::Object(
            obj.iter().map(|(k, v)| (k.clone(), subst_generic_json(v, map))).collect(),
        ),
        serde_json::Value::Array(arr) => serde_json::Value::Array(
            arr.iter().map(|v| subst_generic_json(v, map)).collect(),
        ),
        other => other.clone(),
    }
}
```

- [ ] **Step 3b: Add an `impl Trait` resolvability guard** (after `resolve_generics`)

```rust
/// True if every `impl Trait` node anywhere in `val` resolves to a concrete
/// type. An UNresolvable `impl Trait` arg would otherwise fall through to the
/// `"String"` fallback in `rustdoc_type_to_sky`, which is unsound — so the
/// caller drops the function instead.
fn impl_traits_resolvable(val: &serde_json::Value) -> bool {
    if let Some(bounds) = val.get("impl_trait").and_then(|b| b.as_array()) {
        if resolve_param_bounds(bounds).is_none() {
            return false;
        }
    }
    match val {
        serde_json::Value::Object(obj) => obj.values().all(impl_traits_resolvable),
        serde_json::Value::Array(arr) => arr.iter().all(impl_traits_resolvable),
        _ => true,
    }
}
```

- [ ] **Step 3c: Wire the guard into `parse_fn_item`** — add immediately after the `let subst_map = resolve_generics(fn_data)?;` line from Task 5:

```rust
    // Drop if any `impl Trait` arg/return can't be soundly monomorphised.
    if !sig["inputs"].as_array().map(|ins| ins.iter().all(impl_traits_resolvable)).unwrap_or(true)
        || !impl_traits_resolvable(output)
    {
        return None;
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd tools/sky-ffi-inspect-rs && cargo test test_impl_trait_arg && cargo test`
Expected: PASS — the impl-Trait test passes and **all** unit tests stay green.

- [ ] **Step 5: Commit**

```bash
git add tools/sky-ffi-inspect-rs/src/main.rs
git commit -m "feat(rust): inspector resolves impl-Trait args; drops unresolvable ones (Alt-1 step 6)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 7: `IntoIterator<Item = u8>` bound

**Files:**
- Modify: `tools/sky-ffi-inspect-rs/src/main.rs` (extend `bound_to_concrete`; test)

- [ ] **Step 1: Write the failing test**

```rust
    #[test]
    fn test_into_iterator_u8() {
        // IntoIterator<Item = u8>  -> Vec<u8> (List Int). Item is an associated-type
        // constraint, carried in args.angle_bracketed.constraints, not in args.
        let b = serde_json::json!({ "trait_bound": { "trait": {
            "path": "IntoIterator", "name": "IntoIterator", "id": 0,
            "args": { "angle_bracketed": { "args": [], "constraints": [
                { "name": "Item", "binding": { "equality": { "type": { "primitive": "u8" } } } }
            ] } }
        }, "modifier": "none" } });
        assert_eq!(bound_to_concrete(&b), Some(vec_u8_node()));
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd tools/sky-ffi-inspect-rs && cargo test test_into_iterator_u8`
Expected: FAIL — `IntoIterator` is not in the `match` and falls to `None`.

- [ ] **Step 3: Implement** — add an arm to `bound_to_concrete`'s `match name { … }` (before the final `_ => None`):

```rust
        "IntoIterator" => {
            // Item is an associated-type constraint: args.angle_bracketed.constraints[]
            // with name "Item" and an equality binding to the element type.
            let item_is_u8 = tr.get("args")
                .and_then(|a| a.get("angle_bracketed"))
                .and_then(|ab| ab.get("constraints"))
                .and_then(|c| c.as_array())
                .map(|cs| cs.iter().any(|c| {
                    c.get("name").and_then(|n| n.as_str()) == Some("Item")
                        && c.get("binding").and_then(|b| b.get("equality")).and_then(|e| e.get("type"))
                            .map(node_is_u8_primitive).unwrap_or(false)
                }))
                .unwrap_or(false);
            if item_is_u8 { Some(vec_u8_node()) } else { None }
        }
```

And add the small helper near the other `node_is_*` functions:

```rust
fn node_is_u8_primitive(t: &serde_json::Value) -> bool {
    t.get("primitive").and_then(|p| p.as_str()) == Some("u8")
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd tools/sky-ffi-inspect-rs && cargo test`
Expected: PASS — `test_into_iterator_u8` passes; all other tests still green.

- [ ] **Step 5: Commit**

```bash
git add tools/sky-ffi-inspect-rs/src/main.rs
git commit -m "feat(rust): inspector IntoIterator<Item=u8> -> List Int bound (Alt-1 step 7)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 8: Full inspector test run + rebuild `sky` + clear cache

**Files:** none modified (build/verify only)

- [ ] **Step 1: Full inspector unit-test sweep**

Run: `cd tools/sky-ffi-inspect-rs && cargo test`
Expected: `test result: ok.` with the new tests plus the pre-existing ones (primitives, byte_seq, etc.) all passing, 0 failures.

- [ ] **Step 2: Build the inspector release binary** (the one Template Haskell embeds)

Run: `cd tools/sky-ffi-inspect-rs && cargo build --release && cd ../..`
Expected: `Finished \`release\` profile`.

- [ ] **Step 3: Clear the stale embedded-inspector cache + force TH re-embed**

```bash
cd /home/arthur/Documentos/comp/sky
rm -rf ~/.cache/sky/tools/sky-ffi-inspect-rs
touch tools/sky-ffi-inspect-rs/src/main.rs
```
Expected: no output (the cache dir is removed; the touch updates mtime so the TH dependency re-fires).

- [ ] **Step 4: Reinstall the `sky` compiler binary**

Run: `cabal install --overwrite-policy=always --installdir=./sky-out --install-method=copy exe:sky`
Then: `sky-out/sky --version`
Expected: prints `sky dev` (not a server start).

- [ ] **Step 5: Smoke-test the inspector on hex directly**

Run: `tools/sky-ffi-inspect-rs/target/release/sky-ffi-inspect-rs hex | python3 -c "import json,sys; d=json.load(sys.stdin); fns=[f['name'] for f in d['functions']]; print('hex fns:', sorted(set(fns))); assert 'encode' in fns and 'decode' in fns, 'encode/decode should now bind'; print('OK')"`
Expected: `hex fns: [...'decode'...'encode'...]` then `OK` (encode/decode now present — previously absent).

No commit (build artefacts only).

---

## Task 9: End-to-end example `examples/rust/16-hex`

**Files:**
- Create: `examples/rust/16-hex/sky.toml`
- Create: `examples/rust/16-hex/src/Main.sky`

- [ ] **Step 1: Create `examples/rust/16-hex/sky.toml`**

```toml
[project]
name = "hex-ffi"
target = "rust"

["rust.dependencies"]
hex = "0.4"
```

- [ ] **Step 2: Create `examples/rust/16-hex/src/Main.sky`**

```elm
module Main exposing (main)

import Sky.Core.Prelude exposing (..)
import Std.Log exposing (println)
import Rust.Hex as Hex


main =
    let
        -- encode bytes "Hi!" -> "486921"   (encode<T: AsRef<[u8]>> monomorphised to List Int)
        encoded =
            Hex.encode [ 72, 105, 33 ]

        -- decode the ASCII bytes of "486921" -> [72,105,33]
        --   (decode<T: AsRef<[u8]>> -> Result Error (List Int))
        decoded =
            Hex.decode [ 52, 56, 54, 57, 50, 49 ]
    in
    case decoded of
        Ok bytes ->
            if encoded == "486921" && bytes == [ 72, 105, 33 ] then
                println "OK -> 16-hex: encode + decode via monomorphised hex FFI"

            else
                println ("FAIL -> encoded=" ++ encoded)

        Err e ->
            println ("FAIL -> decode error: " ++ errorToString e)
```

- [ ] **Step 3: Build + run from a clean slate**

```bash
cd /home/arthur/Documentos/comp/sky/examples/rust/16-hex
rm -rf sky-out .skycache
../../../sky-out/sky run src/Main.sky
```
Expected: build succeeds and the program prints:
```
OK -> 16-hex: encode + decode via monomorphised hex FFI
```
(If it prints a `FAIL` line, the monomorphisation produced a wrong type — debug `parse_fn_item` before continuing. If `Rust.Hex` is "module not found", the inspector cache wasn't cleared — redo Task 8 Step 3-4.)

- [ ] **Step 4: Confirm the generated binding is monomorphic**

Run: `grep -nE "pub fn (encode|decode)" examples/rust/16-hex/.skycache/ffi/rust/hex_bindings.rs | head`
Expected: wrappers with concrete `Vec<u8>` params (no `<T>` generics), e.g. `pub fn encode(...) -> ...`.

- [ ] **Step 5: Commit**

```bash
cd /home/arthur/Documentos/comp/sky
git add examples/rust/16-hex/sky.toml examples/rust/16-hex/src/Main.sky
git commit -m "test(rust): 16-hex example — generic hex::encode/decode via Alt-1 monomorphisation

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 10: Coverage-delta measurement + README "Measured coverage" update

**Files:**
- Modify: `runtime-rust/README.md` ("Measured coverage" table)

- [ ] **Step 1: Re-run the audit on the affected leaf crates (force, since cached)**

```bash
cd /home/arthur/Documentos/comp/sky
python3 ~/.claude/skills/ffi-audit/ffi_audit.py run --crates hex,base32,percent-encoding,unicode-segmentation --force --timeout 200
python3 ~/.claude/skills/ffi-audit/ffi_audit.py summary 2>&1 | grep -E "hex|base32|percent|unicode|verdict totals"
```
Expected: `hex` moves from `peripheral` to `usable` (its `free` count rises as `encode`/`encode_upper`/`decode` now bind). Record the new verdict totals.

- [ ] **Step 2: Update the README "Measured coverage" table**

In `runtime-rust/README.md`, under "### Measured coverage (50-crate sample, default features)", move `hex` out of the `peripheral` row into `usable`, and adjust the tier counts to match the Step-1 numbers (e.g. `peripheral` 9→8, `usable` 7→8 — use the ACTUAL counts from the summary, do not guess). Add one sentence noting Alt-1 generic-fn instantiation shipped and which crates moved.

- [ ] **Step 3: Verify the README still parses as a whole** (sanity — no broken table)

Run: `grep -nE "^\| \*\*(rich|usable|thin|peripheral|empty)" runtime-rust/README.md`
Expected: the five tier rows print with their updated counts.

- [ ] **Step 4: Commit**

```bash
git add runtime-rust/README.md
git commit -m "docs(rust): record Alt-1 coverage delta — hex peripheral->usable

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Self-review

**1. Spec coverage:**
- §5.1 bound table (AsRef/Borrow/Into/Display/ToString + IntoIterator<u8>) → Tasks 1, 7. ✓
- §5.2 resolution algorithm (params + where, const drop, output-only drop) → Task 4. ✓
- §5.3 `subst_generic_json` + impl-Trait → Tasks 3, 6. ✓
- §5.4 soundness gate (drop on unresolvable; downstream filters run on concretes) → Task 5 (the `?` drop) + the substitution feeding existing filters. ✓
- §6 worked hex example → Tasks 5 (unit) + 9 (e2e). ✓
- §7 testing (unit fragments, 16-hex, audit delta) → Tasks 1–7 (units), 9 (e2e), 10 (audit). ✓
- §8 rebuild/cache-clear risk → Task 8. ✓
- §9 cross-backend safety (inspector-only, no FfiGen/Go) → no task touches FfiGen/Builder/Compile/Go; verified by file map. ✓
- §10 non-goals (no cross-crate, no containers, no per-call-site, no numeric/Path) → not implemented; IntoIterator scoped to `Item=u8` only. ✓

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code; every command has an expected result. Task 10 Step 2 intentionally says "use the ACTUAL counts" rather than guessing numbers — that is a correctness instruction, not a placeholder.

**3. Type/name consistency:** `bound_to_concrete`, `vec_u8_node`, `string_node`, `node_is_u8_slice`/`node_is_str`/`node_is_vec_u8`/`node_is_string`/`node_is_u8_primitive`, `MARKER_TRAITS`, `is_marker_bound`, `resolve_param_bounds`, `subst_generic_json`, `resolve_generics`, `impl_traits_resolvable` — all referenced consistently across Tasks 1–7. Test helpers `trait_bound`/`type_param`/`fn_with_generics` are defined before first use (Tasks 1/4). The `prim`/`path`/`path_with_args`/`borrowed`/`sky` helpers already exist in the inspector's `mod tests`.

---

## Notes for the implementer

- **Run the inspector unit-test loop with `cd tools/sky-ffi-inspect-rs && cargo test`** — it's a standalone crate; you do NOT need to rebuild `sky` between unit tasks. The `sky` rebuild (Task 8) is only needed for the e2e example.
- **`mem-guard.sh` is macOS-only and dies on this Linux host** — it does not run here; the Linux OOM-killer is the backstop. Heavy compiles are not part of this plan (the inspector + hex are light), so this is informational.
- **Cross-backend rule:** do not touch `src/Sky/Build/`, `src/Sky/Generate/`, `app/Main.hs`, `runtime-go/`, or any Go path. If a change seems to require it, stop — the design says it shouldn't.
