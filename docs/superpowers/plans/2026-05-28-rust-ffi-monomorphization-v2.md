# Rust FFI — monomorphization-on-demand v2 (paired) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Broaden Alt-1 beyond byte/string by (a) making the bound table recursive + adding Path/OsStr/numeric-Into/`num_traits::Integer`/`Float` entries, and (b) lifting the unconditional non-byte slice/array drop with the minimum FfiGen + runtime generalization needed.

**Architecture:** Three Rust-only modules behind the thin seam. Inspector (`tools/sky-ffi-inspect-rs/src/main.rs`) gets a recursive `concrete_for_inner_type` helper, new bound arms, and a generalized `is_coercible_seq` filter. The Rust FFI codegen (`src/Sky/Build/Rust/Ffi.hs`) refactors `ByteKind` → `SeqKind { shape, elem }` where `ElemU8` keeps the existing byte-identical path and `ElemGeneral` adds new emit arms. The runtime (`runtime-rust/src/sky_runtime/core.rs`) gains one new generic helper `to_array<E, T: Clone, const N>` mirroring `to_u8_array`'s never-panic discipline. Upstream-shared files (`FfiGen.hs`, `Compile.hs`, Go) are not touched.

**Tech Stack:** Rust (inspector + runtime), Haskell (Sky FFI codegen), `serde_json`, the bundled `sky` compiler, `proptest`, the `/ffi-audit` Python skill.

**Spec:** `docs/superpowers/specs/2026-05-28-rust-ffi-monomorphization-v2-design.md`
**Builds on:** Alt-1 v1 (already shipped — commits `71853189..6085db43`).

---

## File map

| File | Role | Change |
|---|---|---|
| `tools/sky-ffi-inspect-rs/src/main.rs` | inspector + its `mod tests` | recursive bound table, new entries, `parse_seq`/`is_coercible_seq`, filter lift |
| `src/Sky/Build/Rust/Ffi.hs` | Rust FFI codegen (Rust-only since thin-seam refactor) | `ByteKind` → `SeqKind`, generalized `seqKind`, new `ElemGeneral` emit arms |
| `runtime-rust/src/sky_runtime/core.rs` | Sky Rust runtime helpers | one new `to_array<E, T: Clone, const N>` |
| `runtime-rust/tests/proptest.rs` | runtime property tests | `to_array_len_checked` |
| `examples/rust/17-paths/sky.toml` + `src/Main.sky` | e2e proof — `AsRef<Path>` recovery | create |
| `examples/rust/18-shell-join/sky.toml` + `src/Main.sky` | e2e proof — recursive `IntoIterator<Item=impl AsRef<str>>` | create |
| `runtime-rust/README.md` | "Measured coverage" row updates after the audit delta | modify |

**Untouched:** `src/Sky/Build/FfiGen.hs`, `Compile.hs`, `Builder.hs`, `runtime-go/`, `src/Sky/Generate/Go/`, `.skycache/ffi/*.kernel.json` at root.

---

## Task 1: v2 concrete-node builders (inspector)

**Files:** Modify `tools/sky-ffi-inspect-rs/src/main.rs` (add functions near v1's `vec_u8_node` / `string_node`; tests in `mod tests`).

- [ ] **Step 1: Write the failing tests** (add inside `mod tests`, after `test_bound_to_concrete`):

```rust
    #[test]
    fn test_v2_concrete_node_builders() {
        // The new owned-concrete nodes for v2 entries:
        assert_eq!(sky(&i64_node()), "Int");
        assert_eq!(sky(&f64_node()), "Float");
        assert_eq!(sky(&usize_node()), "Int");

        // Owned String concretes for path/osstr-derived bounds; these are the
        // same `string_node()` from v1 — verify they still map cleanly.
        assert_eq!(sky(&string_node()), "String");
    }
```

- [ ] **Step 2: Run to verify it fails to compile:** `cd tools/sky-ffi-inspect-rs && cargo test test_v2_concrete_node_builders`
Expected: FAIL — `cannot find function i64_node` / `f64_node` / `usize_node`.

- [ ] **Step 3: Implement** — add near the existing v1 `vec_u8_node` / `string_node` builders:

```rust
fn i64_node() -> serde_json::Value {
    serde_json::json!({ "primitive": "i64" })
}
fn f64_node() -> serde_json::Value {
    serde_json::json!({ "primitive": "f64" })
}
fn usize_node() -> serde_json::Value {
    serde_json::json!({ "primitive": "usize" })
}
```

- [ ] **Step 4: Run to verify it passes:** `cd tools/sky-ffi-inspect-rs && cargo test`
Expected: all v1 tests still pass + the new one. 16 tests pass.

- [ ] **Step 5: Commit:**
```bash
git add tools/sky-ffi-inspect-rs/src/main.rs
git commit -m "feat(rust): inspector v2 concrete-node builders (i64/f64/usize) (v2 step 1)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: `concrete_for_inner_type` recursive helper (inspector)

**Files:** Modify `tools/sky-ffi-inspect-rs/src/main.rs` (add helper just before `bound_to_concrete`; tests in `mod tests`).

- [ ] **Step 1: Write the failing tests** (in `mod tests`, after Task 1's test):

```rust
    fn primitive(name: &str) -> serde_json::Value {
        serde_json::json!({ "primitive": name })
    }

    #[test]
    fn test_concrete_for_inner_type() {
        // The slice [u8] becomes Vec<u8> (List Int)
        let u8_slice = serde_json::json!({ "slice": { "primitive": "u8" } });
        assert_eq!(concrete_for_inner_type(&u8_slice), Some(vec_u8_node()));

        // The str primitive becomes String
        assert_eq!(concrete_for_inner_type(&primitive("str")), Some(string_node()));

        // A borrowed &str becomes String too
        let str_ref = serde_json::json!({ "borrowed_ref": { "lifetime": null, "is_mutable": false, "type": { "primitive": "str" } } });
        assert_eq!(concrete_for_inner_type(&str_ref), Some(string_node()));

        // resolved_path "String" / "PathBuf" / "OsString" / "Path" / "OsStr" all become String
        for name in ["String", "PathBuf", "OsString", "Path", "OsStr"] {
            let node = serde_json::json!({ "resolved_path": { "name": name, "path": name, "id": 0, "args": null } });
            assert_eq!(concrete_for_inner_type(&node), Some(string_node()),
                "expected {} -> String", name);
        }

        // Numeric primitives -> their owned concrete
        for name in ["i8", "i16", "i32", "i64", "isize", "u8", "u16", "u32", "u64", "usize"] {
            let r = concrete_for_inner_type(&primitive(name)).expect(&format!("missing: {}", name));
            assert_eq!(sky(&r), "Int", "bad sky for {}", name);
        }
        for name in ["f32", "f64"] {
            let r = concrete_for_inner_type(&primitive(name)).expect(&format!("missing: {}", name));
            assert_eq!(sky(&r), "Float", "bad sky for {}", name);
        }

        // Vec<u8> resolves to Vec<u8>
        let vec_u8 = path_with_args("Vec", vec![primitive("u8")]);
        assert_eq!(concrete_for_inner_type(&vec_u8), Some(vec_u8_node()));

        // Unknown -> None
        let unknown = serde_json::json!({ "resolved_path": { "name": "SomeWeirdType", "path": "SomeWeirdType", "id": 0, "args": null } });
        assert_eq!(concrete_for_inner_type(&unknown), None);
    }
```

- [ ] **Step 2: Run to verify it fails:** `cd tools/sky-ffi-inspect-rs && cargo test test_concrete_for_inner_type`
Expected: FAIL — `cannot find function concrete_for_inner_type`.

- [ ] **Step 3: Implement** — add just above `bound_to_concrete`:

```rust
/// Map an INNER TYPE NODE (the X in AsRef<X> / Into<X> / IntoIterator<Item=X>)
/// to its canonical Sky-coercible concrete type-JSON node, or None if X isn't
/// representable in Sky. Recursive: handles primitives, paths, slices.
fn concrete_for_inner_type(t: &serde_json::Value) -> Option<serde_json::Value> {
    // primitive: u8 slice element, str, integers, floats, bool, char
    if let Some(p) = t.get("primitive").and_then(|p| p.as_str()) {
        return match p {
            "str" => Some(string_node()),
            "u8" => Some(serde_json::json!({ "primitive": "u8" })),
            "i8" | "i16" | "i32" | "i64" | "isize"
            | "u16" | "u32" | "u64" | "usize" => Some(i64_node()),
            "f32" | "f64" => Some(f64_node()),
            "bool" => Some(serde_json::json!({ "primitive": "bool" })),
            "char" => Some(serde_json::json!({ "primitive": "char" })),
            _ => None,
        };
    }
    // slice: [u8] -> Vec<u8>; [other] -> recurse element (Vec<T'>)
    if let Some(inner) = t.get("slice") {
        let elem = concrete_for_inner_type(inner)?;
        // Build Vec<elem'> as a resolved_path node.
        return Some(serde_json::json!({
            "resolved_path": { "name": "Vec", "path": "Vec", "id": 0,
                "args": { "angle_bracketed": { "args": [{ "type": elem }], "constraints": [] } } }
        }));
    }
    // borrowed_ref: see through to the inner type (then resolve it)
    if let Some(br) = t.get("borrowed_ref") {
        let inner = br.get("type").or_else(|| br.get("type_"))?;
        return concrete_for_inner_type(inner);
    }
    // resolved_path: known std/prelude types map to Sky concretes
    if let Some(rp) = t.get("resolved_path") {
        let name = rp.get("name").or_else(|| rp.get("path")).and_then(|n| n.as_str()).unwrap_or("");
        let leaf = name.rsplit("::").next().unwrap_or(name);
        return match leaf {
            "String" | "OsString" | "PathBuf"
            | "Path" | "OsStr" => Some(string_node()),
            "Vec" => {
                // Vec<X>: recurse on element; produce Vec<X'> if X resolves.
                let inner = rp.get("args").and_then(|a| a.get("angle_bracketed"))
                    .and_then(|ab| ab.get("args")).and_then(|v| v.as_array())
                    .and_then(|a| a.first()).and_then(|a| a.get("type"))?;
                let elem = concrete_for_inner_type(inner)?;
                Some(serde_json::json!({
                    "resolved_path": { "name": "Vec", "path": "Vec", "id": 0,
                        "args": { "angle_bracketed": { "args": [{ "type": elem }], "constraints": [] } } }
                }))
            }
            _ => None,
        };
    }
    None
}
```

- [ ] **Step 4: Run to verify it passes:** `cd tools/sky-ffi-inspect-rs && cargo test`
Expected: 17 tests pass (the new one + 16 pre-existing).

- [ ] **Step 5: Commit:**
```bash
git add tools/sky-ffi-inspect-rs/src/main.rs
git commit -m "feat(rust): inspector concrete_for_inner_type recursive helper (v2 step 2)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: Refactor `bound_to_concrete` to use the helper + add num_traits + path arms

**Files:** Modify `tools/sky-ffi-inspect-rs/src/main.rs` — REPLACE the existing `bound_to_concrete` whole-function with the recursive version; tests in `mod tests`.

- [ ] **Step 1: Write the failing tests** for the new v2 arms and recursive composition (in `mod tests`):

```rust
    #[test]
    fn test_bound_to_concrete_v2() {
        // Path / OsStr / PathBuf / OsString -> String  (Linux pragma)
        let asref_path = trait_bound("AsRef", vec![serde_json::json!({ "resolved_path": { "name": "Path", "path": "Path", "id": 0, "args": null } })]);
        assert_eq!(bound_to_concrete(&asref_path), Some(string_node()));
        let asref_osstr = trait_bound("AsRef", vec![serde_json::json!({ "resolved_path": { "name": "OsStr", "path": "OsStr", "id": 0, "args": null } })]);
        assert_eq!(bound_to_concrete(&asref_osstr), Some(string_node()));
        let into_pb = trait_bound("Into", vec![serde_json::json!({ "resolved_path": { "name": "PathBuf", "path": "PathBuf", "id": 0, "args": null } })]);
        assert_eq!(bound_to_concrete(&into_pb), Some(string_node()));

        // Numeric Into family -> Int / Float
        for name in ["i32", "i64", "u32", "u64", "usize", "isize"] {
            let b = trait_bound("Into", vec![primitive(name)]);
            assert_eq!(sky(&bound_to_concrete(&b).unwrap()), "Int", "Into<{}>", name);
        }
        for name in ["f32", "f64"] {
            let b = trait_bound("Into", vec![primitive(name)]);
            assert_eq!(sky(&bound_to_concrete(&b).unwrap()), "Float", "Into<{}>", name);
        }

        // num_traits::Integer / Float (qualified path) -> Int / Float
        let int_b = serde_json::json!({ "trait_bound": { "trait": {
            "path": "num_traits::Integer", "name": "Integer", "id": 0,
            "args": { "angle_bracketed": { "args": [], "constraints": [] } }
        }, "modifier": "none" } });
        assert_eq!(sky(&bound_to_concrete(&int_b).unwrap()), "Int");

        let float_b = serde_json::json!({ "trait_bound": { "trait": {
            "path": "num_traits::Float", "name": "Float", "id": 0,
            "args": { "angle_bracketed": { "args": [], "constraints": [] } }
        }, "modifier": "none" } });
        assert_eq!(sky(&bound_to_concrete(&float_b).unwrap()), "Float");

        // Recursive composition: IntoIterator<Item = X> where X resolves
        // Here X is &str -> String, so we expect Vec<String>.
        let str_ref = serde_json::json!({ "borrowed_ref": { "lifetime": null, "is_mutable": false, "type": primitive("str") } });
        let into_iter_str = serde_json::json!({ "trait_bound": { "trait": {
            "path": "IntoIterator", "name": "IntoIterator", "id": 0,
            "args": { "angle_bracketed": { "args": [], "constraints": [
                { "name": "Item", "binding": { "equality": { "type": str_ref } } }
            ] } }
        }, "modifier": "none" } });
        let got = bound_to_concrete(&into_iter_str).expect("IntoIterator<Item=&str>");
        assert_eq!(sky(&got), "List String");

        // v1 paths still work (regression):
        let asref_u8 = trait_bound("AsRef", vec![serde_json::json!({ "slice": { "primitive": "u8" } })]);
        assert_eq!(bound_to_concrete(&asref_u8), Some(vec_u8_node()));
        assert_eq!(bound_to_concrete(&trait_bound("Display", vec![])), Some(string_node()));
    }
```

- [ ] **Step 2: Run to verify it fails:** `cd tools/sky-ffi-inspect-rs && cargo test test_bound_to_concrete_v2`
Expected: FAIL — current `bound_to_concrete` has no Path / numeric-Into / num_traits arms; the IntoIterator arm is only `Item=u8`.

- [ ] **Step 3: REPLACE the existing `bound_to_concrete` function whole** with the recursive version:

```rust
/// Map a single trait bound to the concrete type-JSON node to substitute, or
/// `None` if the bound is not recognised. The arms delegate inner-type
/// resolution to `concrete_for_inner_type`, which makes the table recursive:
/// `AsRef<X>` works for any X the helper can resolve, etc.
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
        // No-inner bounds with a known concrete:
        "Display" | "ToString" => Some(string_node()),
        "Integer" => Some(i64_node()),   // matches num_traits::Integer (last segment)
        "Float"   => Some(f64_node()),   // matches num_traits::Float
        // Single-inner bounds — recurse on the inner arg:
        "AsRef" | "Borrow" | "Into" | "From" => {
            let arg = args.first()?;
            concrete_for_inner_type(arg)
        }
        // IntoIterator<Item=X>: Item is an assoc-type CONSTRAINT, not a type arg.
        "IntoIterator" => {
            let item = tr.get("args")
                .and_then(|a| a.get("angle_bracketed"))
                .and_then(|ab| ab.get("constraints"))
                .and_then(|c| c.as_array())
                .and_then(|cs| cs.iter().find(|c|
                    c.get("name").and_then(|n| n.as_str()) == Some("Item")))
                .and_then(|c| c.get("binding"))
                .and_then(|b| b.get("equality"))
                .and_then(|e| e.get("type"))?;
            let elem = concrete_for_inner_type(item)?;
            Some(serde_json::json!({
                "resolved_path": { "name": "Vec", "path": "Vec", "id": 0,
                    "args": { "angle_bracketed": { "args": [{ "type": elem }], "constraints": [] } } }
            }))
        }
        _ => None,
    }
}
```

Also REMOVE the now-redundant `node_is_*` helpers that were used by the old flat-match implementation (`node_is_u8_slice`, `node_is_str`, `node_is_vec_u8`, `node_is_string`, `node_is_u8_primitive`) — `concrete_for_inner_type` subsumes them. If any other code site references them, leave them. Otherwise delete.

- [ ] **Step 4: Run to verify it passes:** `cd tools/sky-ffi-inspect-rs && cargo test`
Expected: 18 tests pass — the new v2 test + all 17 from previous tasks. The v1 `test_bound_to_concrete` regression test inside the v2 test still passes.

- [ ] **Step 5: Commit:**
```bash
git add tools/sky-ffi-inspect-rs/src/main.rs
git commit -m "feat(rust): inspector bound_to_concrete recursive + v2 entries (v2 step 3)

Refactor to delegate inner-type resolution to concrete_for_inner_type so the
table composes (e.g. IntoIterator<Item=impl AsRef<str>> -> List String). Add
arms for AsRef/Borrow/Into<Path/OsStr/PathBuf/OsString> -> String, Into<iN/uN>
-> Int, Into<fN> -> Float, num_traits::Integer -> Int, num_traits::Float ->
Float. The byte/string v1 arms keep working unchanged.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: `parse_seq` + `is_coercible_seq` (inspector)

**Files:** Modify `tools/sky-ffi-inspect-rs/src/main.rs` (add helpers near the existing `is_byte_seq`; tests in `mod tests`).

- [ ] **Step 1: Write the failing tests** (in `mod tests`):

```rust
    #[test]
    fn test_is_coercible_seq() {
        // Byte sequences still recognised (regression w.r.t. v1's is_byte_seq):
        assert!(is_coercible_seq("&[u8]"));
        assert!(is_coercible_seq("Vec<u8>"));
        assert!(is_coercible_seq("[u8; 16]"));
        assert!(is_coercible_seq("&[u8; 32]"));

        // Non-byte coercible elements now accepted:
        assert!(is_coercible_seq("&[String]"));
        assert!(is_coercible_seq("Vec<String>"));
        assert!(is_coercible_seq("[f64; 3]"));
        assert!(is_coercible_seq("&[i32; 4]"));
        assert!(is_coercible_seq("&[i64]"));
        assert!(is_coercible_seq("Vec<bool>"));

        // Not coercible:
        assert!(!is_coercible_seq("&mut [u8]"));            // mutable ref excluded
        assert!(!is_coercible_seq("&[Vec<String>]"));       // nested generic elem (conservative drop)
        assert!(!is_coercible_seq("&[&str]"));              // borrowed elem (lifetime concerns)
        assert!(!is_coercible_seq("[u8; abc]"));            // non-digit N
        assert!(!is_coercible_seq("&str"));                 // not a sequence
        assert!(!is_coercible_seq(""));
    }
```

- [ ] **Step 2: Run to verify it fails:** `cd tools/sky-ffi-inspect-rs && cargo test test_is_coercible_seq`
Expected: FAIL — `cannot find function is_coercible_seq`.

- [ ] **Step 3: Implement** — add near the existing `is_byte_seq`:

```rust
/// True if a rust-type token is a single recognised Sky-coercible element:
/// a primitive (numeric/bool/char/str), `String`, or an opaque path-like
/// identifier (no `<`, `&`, `[`, ` `). Nested generics and borrows are
/// conservatively rejected for v2 (drops are safe; v3 may relax).
fn is_sky_coercible_elem(s: &str) -> bool {
    let s = s.trim();
    if s.is_empty() { return false; }
    // Reject borrow / mutability / nesting markers.
    if s.starts_with('&') || s.contains(' ') || s.contains('<') || s.contains('[') || s.contains(',') {
        return false;
    }
    // Primitives:
    matches!(s,
        "u8" | "u16" | "u32" | "u64" | "usize"
      | "i8" | "i16" | "i32" | "i64" | "isize"
      | "f32" | "f64" | "bool" | "char" | "str"
      | "String" | "OsString" | "PathBuf"
    ) || s.chars().next().map(|c| c.is_ascii_alphabetic() || c == '_').unwrap_or(false)
}

/// True if `rt` is a sequence shape whose element is Sky-coercible:
/// `&[T]` / `Vec<T>` / `[T; N]` / `&[T; N]` where T passes `is_sky_coercible_elem`.
fn is_coercible_seq(rt: &str) -> bool {
    let t = rt.trim();
    if t.is_empty() { return false; }
    // Exclude &mut [T] explicitly.
    if t.starts_with("&mut ") { return false; }
    let (is_ref, body) = if let Some(b) = t.strip_prefix('&') { (true, b.trim()) } else { (false, t) };

    // Vec<T> (no leading &)
    if !is_ref {
        if let Some(rest) = body.strip_prefix("Vec<") {
            if let Some(elem) = rest.strip_suffix('>') {
                return is_sky_coercible_elem(elem.trim());
            }
        }
    }

    // [T] (slice, only valid behind &) or [T; N] (array)
    if let Some(inner) = body.strip_prefix('[').and_then(|s| s.strip_suffix(']')) {
        if let Some((elem, n_str)) = inner.split_once(';') {
            let n_str = n_str.trim();
            if !n_str.is_empty() && n_str.chars().all(|c| c.is_ascii_digit()) {
                return is_sky_coercible_elem(elem.trim());
            }
            return false;
        }
        // Pure [T] without ; is only valid as &[T]
        return is_ref && is_sky_coercible_elem(inner.trim());
    }
    false
}
```

- [ ] **Step 4: Run to verify it passes:** `cd tools/sky-ffi-inspect-rs && cargo test`
Expected: 19 tests pass.

- [ ] **Step 5: Commit:**
```bash
git add tools/sky-ffi-inspect-rs/src/main.rs
git commit -m "feat(rust): inspector is_coercible_seq (v2 step 4)

Generalises is_byte_seq's classification to any sequence whose element is a
recognised Sky-coercible primitive/path. Conservative on nested generics,
borrowed elements, and &mut [T] — those still drop downstream.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: Apply the filter lift in `parse_fn_item`

**Files:** Modify `tools/sky-ffi-inspect-rs/src/main.rs` (two filter sites in `parse_fn_item`; integration tests in `mod tests`).

- [ ] **Step 1: Write the failing integration tests** (in `mod tests`):

```rust
    #[test]
    fn test_parse_fn_item_v2_slice_array() {
        // fn join(parts: &[String]) -> String  : non-byte slice param survives
        let fd = serde_json::json!({
            "header": { "is_async": false, "is_unsafe": false },
            "generics": { "params": [], "where_predicates": [] },
            "sig": { "inputs": [
                ["parts", { "borrowed_ref": { "lifetime": null, "is_mutable": false, "type": { "slice": { "resolved_path": { "name": "String", "path": "String", "id": 0, "args": null } } } } }]
            ], "output": { "resolved_path": { "name": "String", "path": "String", "id": 0, "args": null } } }
        });
        let f = parse_fn_item("join", &fd, &HashMap::new(), None)
            .expect("&[String] param should survive the v2 filter");
        assert_eq!(f.params[0].sky_type, "List String");
        assert_eq!(f.params[0].rust_type, "&[String]");

        // fn point(p: [f64; 3]) -> f64  : fixed-size non-byte array survives
        let fd2 = serde_json::json!({
            "header": { "is_async": false, "is_unsafe": false },
            "generics": { "params": [], "where_predicates": [] },
            "sig": { "inputs": [
                ["p", { "array": { "type": { "primitive": "f64" }, "len": "3" } }]
            ], "output": { "primitive": "f64" } }
        });
        let f2 = parse_fn_item("point", &fd2, &HashMap::new(), None)
            .expect("[f64; 3] param should survive the v2 filter");
        assert_eq!(f2.params[0].sky_type, "List Float");
        assert_eq!(f2.params[0].rust_type, "[f64; 3]");

        // fn fill(buf: &mut [u8])  : &mut [u8] still drops (not in is_coercible_seq)
        let fd3 = serde_json::json!({
            "header": { "is_async": false, "is_unsafe": false },
            "generics": { "params": [], "where_predicates": [] },
            "sig": { "inputs": [
                ["buf", { "borrowed_ref": { "lifetime": null, "is_mutable": true, "type": { "slice": { "primitive": "u8" } } } }]
            ], "output": null }
        });
        assert!(parse_fn_item("fill", &fd3, &HashMap::new(), None).is_none());

        // Byte path regression: fn h(b: &[u8]) -> Vec<u8>  byte-identical to v1
        let fd4 = serde_json::json!({
            "header": { "is_async": false, "is_unsafe": false },
            "generics": { "params": [], "where_predicates": [] },
            "sig": { "inputs": [
                ["b", { "borrowed_ref": { "lifetime": null, "is_mutable": false, "type": { "slice": { "primitive": "u8" } } } }]
            ], "output": path_with_args("Vec", vec![primitive("u8")]) }
        });
        let f4 = parse_fn_item("h", &fd4, &HashMap::new(), None).unwrap();
        assert_eq!(f4.params[0].sky_type, "List Int");
        assert_eq!(f4.params[0].rust_type, "&[u8]");
        assert_eq!(f4.results[0].sky_type, "List Int");
    }
```

- [ ] **Step 2: Run to verify it fails:** `cd tools/sky-ffi-inspect-rs && cargo test test_parse_fn_item_v2_slice_array`
Expected: FAIL — the `&[String]` and `[f64; 3]` cases both return `None` (the v1 filter at `:707` drops anything with `[` that isn't a byte sequence).

- [ ] **Step 3a: Edit the borrowed-result filter** (around `main.rs:696-702`).

Replace this exact block:
```rust
    let result_borrows = results.iter().any(|p| {
        let rt = p.rust_type.trim();
        rt.contains('&') && rt != "&str" && rt != "&String" && !is_byte_seq(rt)
    });
```
with:
```rust
    let result_borrows = results.iter().any(|p| {
        let rt = p.rust_type.trim();
        rt.contains('&') && rt != "&str" && rt != "&String" && !is_coercible_seq(rt)
    });
```

- [ ] **Step 3b: Edit the array/slice drop filter** (around `main.rs:708-713`).

Replace this exact block:
```rust
    let has_bad_array_or_slice = params
        .iter()
        .chain(results.iter())
        .any(|p| p.rust_type.contains('[') && !is_byte_seq(&p.rust_type));
```
with:
```rust
    let has_bad_array_or_slice = params
        .iter()
        .chain(results.iter())
        .any(|p| p.rust_type.contains('[') && !is_coercible_seq(&p.rust_type));
```

- [ ] **Step 4: Run to verify it passes:** `cd tools/sky-ffi-inspect-rs && cargo test`
Expected: 20 tests pass (the new one + 19 prior). Critically, **all 19 prior tests still pass** — the byte-shape behaviour is byte-identical because `is_coercible_seq` accepts everything `is_byte_seq` did.

- [ ] **Step 5: Commit:**
```bash
git add tools/sky-ffi-inspect-rs/src/main.rs
git commit -m "feat(rust): inspector lifts non-byte slice/array drop (v2 step 5)

Both filter sites (borrowed-result at :698 and array/slice at :708) now gate by
is_coercible_seq instead of is_byte_seq, letting non-byte coercible-element
sequences (&[String], [f64;3], Vec<bool>...) survive. Byte path byte-identical.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 6: `ByteKind` → `SeqKind` refactor (Haskell, byte-identical)

**Files:** Modify `src/Sky/Build/Rust/Ffi.hs` — replace the `ByteKind` data type + `byteSeqKind` parser + the three emit sites (`translateRustRet`, `argCall`, `arrPrelude`) so they branch through `SeqKind` while emitting the same byte code.

**Tests:** No Haskell unit tests added in this step (the cabal test infra doesn't currently have a Sky.Build.Rust.Ffi spec, and adding one is out of scope for v2). Verification is by **cabal build** + **smoke-running an existing byte example** end-to-end to confirm byte-identical behaviour.

- [ ] **Step 1: REPLACE the `data ByteKind` declaration** (search for `data ByteKind = BSlice | BVec | BArr Int | BRefArr Int`) with:

```haskell
-- | Shape of a slice/array Rust type.
data SeqShape = Slice | Owned | Arr Int | RefArr Int
  deriving (Show, Eq)

-- | Element kind. ElemU8 is the byte-sequence fast path (List Int via
-- to_u8_vec / from_u8_slice / to_u8_array — the existing v1 helpers).
-- ElemGeneral carries the (rust_type, sky_type) of a non-byte coercible
-- element (e.g. ("String","String"), ("f64","Float")).
data SeqElem = ElemU8
             | ElemGeneral String String   -- (elem rust_type, elem sky_type)
  deriving (Show, Eq)

data SeqKind = SeqKind SeqShape SeqElem
  deriving (Show, Eq)
```

- [ ] **Step 2: REPLACE `byteSeqKind` with `seqKind`** (search for `byteSeqKind :: String -> Maybe ByteKind`). New body:

```haskell
-- | Classify a raw Rust type as a Sky-coercible sequence (mirrors the
-- inspector's is_coercible_seq). Returns the shape and element kind.
-- N is parsed from `[T; N]` / `&[T; N]`. Excludes &mut [T] and non-coercible
-- elements (nested generics, borrowed elements).
seqKind :: String -> Maybe SeqKind
seqKind raw =
    let s = trimStr raw in
    if "&mut " `isPrefixOf` s then Nothing
    else case s of
        "&[u8]"   -> Just (SeqKind Slice ElemU8)
        "Vec<u8>" -> Just (SeqKind Owned ElemU8)
        _ -> case stripPrefix "&[u8; " s of
               Just rest | Just n <- digitsBeforeClose rest ->
                 Just (SeqKind (RefArr n) ElemU8)
               _ -> case stripPrefix "[u8; " s of
                 Just rest | Just n <- digitsBeforeClose rest ->
                   Just (SeqKind (Arr n) ElemU8)
                 _ -> seqGeneral s
  where
    -- digits up to the matching ']'
    digitsBeforeClose rest =
        case span (/= ']') rest of
            (digits, "]") | not (null digits) && all isDigit digits -> Just (read digits)
            _ -> Nothing

    -- Non-byte coercible sequences. Element classification mirrors the
    -- inspector's is_sky_coercible_elem.
    seqGeneral s =
        let try shape e = if isCoercibleElem e
                          then Just (SeqKind shape (ElemGeneral e (skyOfElem e)))
                          else Nothing
        in case stripPrefix "Vec<" s of
             Just rest | Just e <- stripSuffix ">" rest -> try Owned (trimStr e)
             _ -> case stripPrefix "&[" s of
               Just rest | Just inner <- stripSuffix "]" rest ->
                 case break (== ';') inner of
                   (e, ';':n) -> case reads (trimStr n) :: [(Int,String)] of
                                   [(k, "")] -> try (RefArr k) (trimStr e)
                                   _ -> Nothing
                   (e, "")    -> try Slice (trimStr e)
                   _ -> Nothing
               _ -> case stripPrefix "[" s of
                 Just rest | Just inner <- stripSuffix "]" rest ->
                   case break (== ';') inner of
                     (e, ';':n) -> case reads (trimStr n) :: [(Int,String)] of
                                     [(k, "")] -> try (Arr k) (trimStr e)
                                     _ -> Nothing
                     _ -> Nothing
                 _ -> Nothing

    isCoercibleElem e =
        let t = trimStr e in
        not (null t)
        && not ('&' `elem` t || ' ' `elem` t || '<' `elem` t
                || '[' `elem` t || ',' `elem` t)
        && (t `elem` knownPrim
            || (not (null t)
                && (isAlpha (head t) || head t == '_')))
      where
        knownPrim = ["u8","u16","u32","u64","usize"
                    ,"i8","i16","i32","i64","isize"
                    ,"f32","f64","bool","char","str"
                    ,"String","OsString","PathBuf"]

    -- Map a coercible element rust string to its Sky type string.
    skyOfElem e
        | e `elem` intLike   = "Int"
        | e `elem` floatLike = "Float"
        | e == "bool"        = "Bool"
        | e == "char"        = "Char"
        | e == "str" || e == "String" || e == "OsString" || e == "PathBuf" = "String"
        | otherwise          = e   -- opaque path; surfaces as-is (existing nameability filter validates)
      where
        intLike   = ["u8","u16","u32","u64","usize"
                    ,"i8","i16","i32","i64","isize"]
        floatLike = ["f32","f64"]

    stripSuffix suf xs =
        let n = length xs - length suf in
        if n >= 0 && drop n xs == suf
        then Just (take n xs)
        else Nothing
```

If `stripSuffix` already exists in scope (from `Data.List`), drop the local definition. (Modern `Data.List.stripSuffix` is fine to use directly.)

- [ ] **Step 3: Update `translateRustRet`** — find the `case byteSeqKind raw of Just bk -> ...` arm and REPLACE it with:

```haskell
    else case seqKind raw of
      Just (SeqKind shape ElemU8) ->
        -- BYTE PATH (byte-identical to v1)
        ( "Vec<i64>"
        , \e -> case shape of
            Owned    -> "from_u8_slice(&" ++ e ++ ")"
            Arr _    -> "from_u8_slice(&" ++ e ++ ")"
            Slice    -> "from_u8_slice(" ++ e ++ ")"
            RefArr _ -> "from_u8_slice(" ++ e ++ ")" )
      Just (SeqKind _ (ElemGeneral _ _)) ->
        -- Reserved for Task 7; until then keep dropping by returning identity
        -- that the downstream pipeline rejects. We make this branch
        -- unreachable in this commit by predicating seqGeneral on whether the
        -- caller currently emits non-byte (which it doesn't until Task 7's
        -- inspector lift propagates here). To keep this commit byte-identical
        -- we pattern-match defensively; the inspector won't deliver this case
        -- yet because the byte path is the only one in use post-Task-5 inside
        -- this Haskell file alone (Task 5 was inspector-side filter lift).
        ("()", \_ -> "()")
      Nothing -> case stripGeneric1 "Option" raw of
        ...
```

Important: Task 5 already lifted the inspector filter so non-byte sequences CAN now reach this codegen. Task 6's job is **structural refactor only** — keeping byte-identical behaviour. Until Task 7 lands the proper `ElemGeneral` emit arms, the inspector's lifted shapes would NOT be exercised by any current example (the byte examples 14/15/16 still use byte sequences, which hit `ElemU8`). The defensive `("()", \_ -> "()")` placeholder ensures the file compiles; Task 7 replaces it.

(If your linter dislikes a placeholder, instead INVERT the order: do Task 7 first then Task 6. The plan keeps the order above so the byte-identical refactor lands as one reviewable commit, but the implementer may merge Tasks 6+7 into one if preferred.)

- [ ] **Step 4: Update `argCall`'s byte-seq arms** — find the `case byteSeqKind rawTy of Just BSlice -> ...` block in `argCall` and REPLACE it with:

```haskell
                in case seqKind rawTy of
                    Just (SeqKind Slice    ElemU8) -> "&to_u8_vec(&" ++ base ++ ")"
                    Just (SeqKind Owned    ElemU8) -> "to_u8_vec(&" ++ base ++ ")"
                    Just (SeqKind (Arr _)    ElemU8) -> "b" ++ show j
                    Just (SeqKind (RefArr _) ElemU8) -> "&b" ++ show j
                    Just (SeqKind _ (ElemGeneral _ _)) ->
                        -- Reserved for Task 7; current commits never trigger this.
                        base
                    Nothing ->
                        if declTy == "String"
                        then "&" ++ base
                        else if null rawTy || rawTy == declTy
                        then base
                        else if isNumericRust rawTy && (declTy == "i64" || declTy == "f64")
                        then base ++ " as " ++ rawTy
                        else base
```

- [ ] **Step 5: Update `arrPrelude`** — find the `case byteSeqKind rawTy of Just (BArr m) -> [m]; Just (BRefArr m) -> [m]; _ -> []` and REPLACE with:

```haskell
                , n <- case seqKind rawTy of
                         Just (SeqKind (Arr m)    ElemU8) -> [m]
                         Just (SeqKind (RefArr m) ElemU8) -> [m]
                         _                                -> []
```

(`arrPrelude`'s body itself stays unchanged for `ElemU8` — it already emits `to_u8_array::<SkyError, n>(&arg…)`. Task 7 extends it for `ElemGeneral`.)

- [ ] **Step 6: Run cabal build:** `cd /home/arthur/Documentos/comp/sky && cabal build exe:sky 2>&1 | tail -6`
Expected: `Finished` or no errors. The byte path is byte-identical at this point.

- [ ] **Step 7: Smoke-test byte-identical behaviour end-to-end** by re-running `examples/rust/16-hex`:

```bash
cd /home/arthur/Documentos/comp/sky
cabal install --overwrite-policy=always --installdir=./sky-out --install-method=copy exe:sky 2>&1 | tail -3
cd examples/rust/16-hex && rm -rf sky-out .skycache
../../../sky-out/sky run src/Main.sky 2>&1 | tail -3
```

Expected: `OK -> 16-hex: encode + decode via monomorphised hex FFI` (same as v1).

- [ ] **Step 8: Commit:**
```bash
cd /home/arthur/Documentos/comp/sky
git add src/Sky/Build/Rust/Ffi.hs
git commit -m "refactor(rust): ByteKind -> SeqKind in Sky.Build.Rust.Ffi (v2 step 6)

Pure structural refactor: data SeqShape = Slice|Owned|Arr|RefArr;
data SeqElem = ElemU8 | ElemGeneral String String; seqKind classifies both
byte and general sequences. ElemU8 arms emit identical byte code (verified by
re-running 16-hex green). ElemGeneral arms are placeholders extended in step 7.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 7: Add `ElemGeneral` emit arms (Haskell)

**Files:** Modify `src/Sky/Build/Rust/Ffi.hs` — replace the Task-6 placeholders in `translateRustRet`, `argCall`, `arrPrelude` with proper `ElemGeneral` codegen.

- [ ] **Step 1: Update `translateRustRet`'s `ElemGeneral` arm.** Find the `Just (SeqKind _ (ElemGeneral _ _)) -> ("()", \_ -> "()")` placeholder and REPLACE with:

```haskell
      Just (SeqKind shape (ElemGeneral _elemRust _elemSky)) ->
        -- General element coercion. Sky `List T` is `Vec<T>` in the runtime,
        -- so Vec<T> result is identity; &[T] / [T;N] / &[T;N] all clone to
        -- owned Vec<T> via .to_vec() (T: Clone required and assumed for
        -- coercible elems).
        ( "Vec<" ++ _elemRust ++ ">"
        , \e -> case shape of
            Owned    -> e                       -- Vec<T> identity
            Slice    -> e ++ ".to_vec()"
            Arr _    -> e ++ ".to_vec()"
            RefArr _ -> e ++ ".to_vec()" )
```

- [ ] **Step 2: Update `argCall`'s `ElemGeneral` arm.** Find the `Just (SeqKind _ (ElemGeneral _ _)) -> base` placeholder and REPLACE with:

```haskell
                    Just (SeqKind Slice    (ElemGeneral _ _)) -> base ++ ".as_slice()"
                    Just (SeqKind Owned    (ElemGeneral _ _)) -> base    -- Vec<T> identity
                    Just (SeqKind (Arr _)    (ElemGeneral _ _)) -> "b" ++ show j   -- prelude local
                    Just (SeqKind (RefArr _) (ElemGeneral _ _)) -> "&b" ++ show j  -- prelude local (by ref)
```

(The single placeholder line is replaced by these four shape-specific arms.)

- [ ] **Step 3: Extend `arrPrelude`** to emit the `to_array<…>` prelude for `ElemGeneral` arrays. Find the existing prelude generator (search for `arrPrelude = [ "let b" ++ show j ++ ": [u8; " ++ show n ++ "] = " ++ ...`) and REPLACE the list-comprehension with:

```haskell
            arrPrelude =
                [ case se of
                    ElemU8 ->
                      "let b" ++ show j ++ ": [u8; " ++ show n ++ "] = "
                      ++ "match to_u8_array::<SkyError, " ++ show n
                      ++ ">(&arg" ++ show j ++ ") { SkyResult::Ok(a) => a, "
                      ++ "SkyResult::Err(e) => return SkyResult::Err(e), };"
                    ElemGeneral elemRust _ ->
                      "let b" ++ show j ++ ": [" ++ elemRust ++ "; " ++ show n ++ "] = "
                      ++ "match to_array::<SkyError, " ++ elemRust ++ ", " ++ show n
                      ++ ">(&arg" ++ show j ++ ") { SkyResult::Ok(a) => a, "
                      ++ "SkyResult::Err(e) => return SkyResult::Err(e), };"
                | j <- [0 .. nParams - 1]
                , let rawTy = if j < nRawRustParam then rawRustParamTypes !! j else ""
                , (n, se) <- case seqKind rawTy of
                         Just (SeqKind (Arr m)    e) -> [(m, e)]
                         Just (SeqKind (RefArr m) e) -> [(m, e)]
                         _                           -> []
                ]
```

- [ ] **Step 4: Run cabal build:** `cd /home/arthur/Documentos/comp/sky && cabal build exe:sky 2>&1 | tail -3`
Expected: `Finished` or no errors.

- [ ] **Step 5: Commit:**
```bash
cd /home/arthur/Documentos/comp/sky
git add src/Sky/Build/Rust/Ffi.hs
git commit -m "feat(rust): ElemGeneral emit arms in Sky.Build.Rust.Ffi (v2 step 7)

translateRustRet: &[T]/[T;N]/&[T;N] -> Vec<T> via e.to_vec(); Vec<T> identity.
argCall: &[T] -> base.as_slice(); Vec<T> identity; [T;N]/&[T;N] -> bN prelude
local (owned or by-ref). arrPrelude: emits to_array::<SkyError, T, N>(&argN)
for ElemGeneral arrays (paralleling the existing to_u8_array byte version).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 8: `to_array<E, T: Clone, const N>` runtime helper

**Files:** Modify `runtime-rust/src/sky_runtime/core.rs` (add helper near `to_u8_array`); modify `runtime-rust/tests/proptest.rs` (add property test).

- [ ] **Step 1: Write the failing proptest** — append to `runtime-rust/tests/proptest.rs`:

```rust
proptest! {
    /// `to_array` succeeds exactly when input length matches N, never panics.
    #[test]
    fn to_array_len_checked(xs in prop::collection::vec(any::<i64>(), 0..16usize)) {
        const N: usize = 8;
        let result: SkyResult<SkyError, [i64; N]> = sky_runtime::to_array::<SkyError, i64, N>(&xs);
        if xs.len() == N {
            prop_assert!(matches!(result, SkyResult::Ok(_)));
            if let SkyResult::Ok(arr) = result {
                for i in 0..N {
                    prop_assert_eq!(arr[i], xs[i]);
                }
            }
        } else {
            prop_assert!(matches!(result, SkyResult::Err(_)));
        }
    }
}
```

If the existing proptest file uses a different shape for the `proptest!` block, follow that local convention.

- [ ] **Step 2: Run to verify it fails to compile:** `cd runtime-rust && cargo test --test proptest to_array_len_checked 2>&1 | tail -5`
Expected: FAIL — `cannot find function to_array in module sky_runtime`.

- [ ] **Step 3: Implement** — add to `runtime-rust/src/sky_runtime/core.rs` just AFTER `to_u8_array`:

```rust
/// Sky `List T` -> fixed-size `[T; N]` with length check (generic over T).
/// Mirrors `to_u8_array`'s never-panic discipline: returns `SkyResult::Err`
/// with a clear message on length mismatch. T: Clone is sufficient — the
/// elements are cloned out into the array.
pub fn to_array<E: From<String>, T: Clone, const N: usize>(xs: &[T]) -> SkyResult<E, [T; N]> {
    if xs.len() != N {
        return SkyResult::Err(format!("expected array of length {}, got {}", N, xs.len()).into());
    }
    let v: Vec<T> = xs.to_vec();
    match v.try_into() {
        Ok(a) => ok_res(a),
        Err(_) => SkyResult::Err("array length conversion failed".to_string().into()),
    }
}
```

- [ ] **Step 4: Run to verify it passes:** `cd /home/arthur/Documentos/comp/sky/runtime-rust && cargo test --test proptest to_array_len_checked 2>&1 | tail -5`
Expected: `test result: ok. 1 passed`.

- [ ] **Step 5: Commit:**
```bash
cd /home/arthur/Documentos/comp/sky
git add runtime-rust/src/sky_runtime/core.rs runtime-rust/tests/proptest.rs
git commit -m "feat(rust): runtime to_array<E, T: Clone, const N> + proptest (v2 step 8)

Generic version of to_u8_array, used by Sky.Build.Rust.Ffi's ElemGeneral
arrPrelude. Never panics — length mismatch returns SkyResult::Err. The byte
version to_u8_array stays for backward compat.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 9: Full test sweep + rebuild `sky` + clear cache

**Files:** none modified (build/verify only).

- [ ] **Step 1: Inspector full unit-test sweep**

Run: `cd tools/sky-ffi-inspect-rs && cargo test`
Expected: 20 tests pass (v1's 15 + v2's 5 new), 0 failures.

- [ ] **Step 2: Runtime full test sweep**

Run: `cd /home/arthur/Documentos/comp/sky/runtime-rust && cargo test 2>&1 | tail -3`
Expected: 0 failures (existing proptest crate tests + new `to_array_len_checked`).

- [ ] **Step 3: Build the inspector release binary** (the one TH embeds)

Run: `cd tools/sky-ffi-inspect-rs && cargo build --release 2>&1 | tail -2`
Expected: `Finished \`release\` profile`.

- [ ] **Step 4: Clear stale cache + touch for TH re-fire**

```bash
cd /home/arthur/Documentos/comp/sky
rm -rf ~/.cache/sky/tools/sky-ffi-inspect-rs
touch tools/sky-ffi-inspect-rs/src/main.rs
```

- [ ] **Step 5: Reinstall the `sky` compiler** (Haskell compile ~3-5 min)

Run: `cabal install --overwrite-policy=always --installdir=./sky-out --install-method=copy exe:sky 2>&1 | tail -5`
Then: `sky-out/sky --version`
Expected: prints `sky dev`.

- [ ] **Step 6: Smoke the inspector on a v2 candidate crate** — `path-clean` and `shellwords`:

```bash
cd /home/arthur/Documentos/comp/sky
tools/sky-ffi-inspect-rs/target/release/sky-ffi-inspect-rs path-clean 2>/dev/null > /tmp/pathclean-ffi.json
tools/sky-ffi-inspect-rs/target/release/sky-ffi-inspect-rs shellwords 2>/dev/null > /tmp/shellwords-ffi.json
python3 <<'PY'
import json
for name in ["pathclean", "shellwords"]:
    d = json.load(open(f"/tmp/{name}-ffi.json"))
    fns = sorted({f["name"] for f in d["functions"]})
    print(f"{name}: kept {len(fns)} -> {fns[:8]}")
PY
```
Expected: Each prints some bound functions; at minimum `path-clean` shows its main `clean` fn and `shellwords` shows `join`/`split`. (If the inspector emits zero for a candidate crate, swap that crate at Task 10/11 for a sibling — `dunce`/`pathdiff` for paths, `shell-words` (with hyphen) for shellwords.)

No commit (build/verify only).

---

## Task 10: End-to-end example `examples/rust/17-paths`

**Files:** Create `examples/rust/17-paths/sky.toml` and `examples/rust/17-paths/src/Main.sky`.

**Crate choice guidance:** the canonical pick is `path-clean` (small; `clean(path: impl AsRef<Path>) -> PathBuf`). If after Task 9 the inspector shows zero useful functions bound, fall back to `pathdiff` or `dunce`. The example uses the auto-generated `to_string_from_pathbuf` Display bridge to compare the returned `PathBuf` to an expected string.

- [ ] **Step 1: Create `examples/rust/17-paths/sky.toml`**

```toml
[project]
name = "paths-ffi"
version = "0.1.0"
entry = "src/Main.sky"
target = "rust"

["rust.dependencies"]
path-clean = "1.0"
```

- [ ] **Step 2: Create `examples/rust/17-paths/src/Main.sky`**

```elm
module Main exposing (main)

import Sky.Core.Prelude exposing (..)
import Std.Log exposing (println)
import Rust.PathClean as PathClean


main =
    let
        -- clean<P: AsRef<Path>>(P) -> PathBuf
        -- v2 substitutes P = String; PathBuf result -> opaque PathBuf with
        -- auto-generated to_string_from_pathbuf Display bridge.
        cleaned_pb =
            PathClean.clean "foo/./bar/../baz"

        cleaned =
            PathClean.to_string_from_pathbuf cleaned_pb
    in
    case cleaned == "foo/baz" of
        True ->
            println "OK -> 17-paths: AsRef<Path> bound via Alt-1 v2 monomorphisation"

        False ->
            println ("FAIL -> got " ++ cleaned)
```

- [ ] **Step 3: Build + run from a clean slate**

```bash
cd /home/arthur/Documentos/comp/sky/examples/rust/17-paths
rm -rf sky-out .skycache
../../../sky-out/sky run src/Main.sky 2>&1 | tail -5
```
Expected last line: `OK -> 17-paths: AsRef<Path> bound via Alt-1 v2 monomorphisation`.

Troubleshooting:
- `module not found Rust.PathClean`: cache wasn't cleared in Task 9 — repeat Step 4 of Task 9.
- `to_string_from_pathbuf not defined`: the auto Display bridge wasn't synthesised (PathBuf may not impl Display in `path-clean`'s rustdoc view — use the workaround `PathClean.clean_string` if available, or pick a sibling crate).
- `FAIL -> got ...`: the binding works but `path-clean` normalised differently — adjust the expected `"foo/baz"` to whatever the crate actually produces, log it, and re-run. The point is *that the binding compiles and runs*, not the exact normalisation rule.

- [ ] **Step 4: Confirm the binding is monomorphic** (no `<P>` generics):

```bash
cd /home/arthur/Documentos/comp/sky/examples/rust/17-paths
grep -nE "pub fn .*clean" .skycache/ffi/rust/path_clean_bindings.rs | head
```
Expected: a wrapper with a concrete `String` param (no `<P>` generics).

- [ ] **Step 5: Commit:**
```bash
cd /home/arthur/Documentos/comp/sky
git add examples/rust/17-paths/sky.toml examples/rust/17-paths/src/Main.sky
git commit -m "test(rust): 17-paths example — AsRef<Path> via Alt-1 v2 monomorphisation

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 11: End-to-end example `examples/rust/18-shell-join`

**Files:** Create `examples/rust/18-shell-join/sky.toml` and `examples/rust/18-shell-join/src/Main.sky`.

**Crate choice guidance:** `shellwords` exposes `pub fn join<I: IntoIterator<Item = impl AsRef<str>>>(words: I) -> String`. This is the textbook v2 unlock: recursive `IntoIterator<Item=impl AsRef<str>>` resolves to `Vec<String>` via the new recursive table, AND the non-byte slice/array filter must already allow `&[String]`-style usage downstream. If `shellwords` (with hyphen) doesn't have this exact signature on its current crates.io version, switch to `shell-words` (different crate; `pub fn join<I, S>(words: I) -> String where I: IntoIterator<Item=S>, S: AsRef<str>`) — confirmed during Task 9's smoke.

- [ ] **Step 1: Create `examples/rust/18-shell-join/sky.toml`**

```toml
[project]
name = "shell-join-ffi"
version = "0.1.0"
entry = "src/Main.sky"
target = "rust"

["rust.dependencies"]
shellwords = "1"
```

If Task 9 found `shell-words` is the right one instead, swap the dep line to `shell-words = "1"` and the Sky import to `Rust.ShellWords` accordingly.

- [ ] **Step 2: Create `examples/rust/18-shell-join/src/Main.sky`**

```elm
module Main exposing (main)

import Sky.Core.Prelude exposing (..)
import Std.Log exposing (println)
import Rust.Shellwords as Shellwords


main =
    let
        -- join<I: IntoIterator<Item=impl AsRef<str>>>(I) -> String
        -- v2 recursively resolves:
        --   impl AsRef<str> -> String, then IntoIterator<Item=String> -> Vec<String>.
        -- Final binding: join : List String -> String.
        joined =
            Shellwords.join [ "echo", "hello", "world" ]
    in
    case joined == "echo hello world" of
        True ->
            println "OK -> 18-shell-join: recursive IntoIterator<Item=impl AsRef<str>> via Alt-1 v2"

        False ->
            println ("FAIL -> got " ++ joined)
```

Adjust the import (`Rust.ShellWords` if the dep is `shell-words`) and expected output if the crate quotes differently — the goal is to prove the binding works, not assert an exact format string.

- [ ] **Step 3: Build + run from a clean slate**

```bash
cd /home/arthur/Documentos/comp/sky/examples/rust/18-shell-join
rm -rf sky-out .skycache
../../../sky-out/sky run src/Main.sky 2>&1 | tail -5
```
Expected last line: `OK -> 18-shell-join: recursive IntoIterator<Item=impl AsRef<str>> via Alt-1 v2`.

- [ ] **Step 4: Confirm the binding is monomorphic + uses `Vec<String>`:**

```bash
cd /home/arthur/Documentos/comp/sky/examples/rust/18-shell-join
grep -nE "pub fn .*join" .skycache/ffi/rust/shellwords_bindings.rs | head
```
Expected: a wrapper with a concrete `Vec<String>` param (no `<I>`/`<S>` generics).

- [ ] **Step 5: Commit:**
```bash
cd /home/arthur/Documentos/comp/sky
git add examples/rust/18-shell-join/sky.toml examples/rust/18-shell-join/src/Main.sky
git commit -m "test(rust): 18-shell-join example — recursive IntoIterator<Item=impl AsRef<str>> via Alt-1 v2

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 12: `/ffi-audit` coverage delta + README "Measured coverage" update

**Files:** Modify `runtime-rust/README.md` ("Measured coverage" table + Alt-1 v1 paragraph extended for v2).

- [ ] **Step 1: Force-rerun the audit on candidates likely to flip**

```bash
cd /home/arthur/Documentos/comp/sky
python3 ~/.claude/skills/ffi-audit/ffi_audit.py run --force --timeout 240 --crates \
  itoa,ryu,bytesize,percent-encoding,arrayvec,nalgebra,ndarray,smallvec,itertools,ordered-float,bitflags,humantime,toml,quick-xml,csv,serde_json,serde_yaml,redis,reqwest,rusqlite,tungstenite,ureq,crc32fast \
  > /tmp/v2-audit-delta.log 2>&1 &
disown
```

Wait for completion (run in background; harness will notify). Then:

```bash
python3 ~/.claude/skills/ffi-audit/ffi_audit.py summary 2>&1 | tail -15
```

Record the verdict-tier counts (the line `verdict totals : empty=… peripheral=… rich=… thin=… usable=…`) and any per-crate moves.

- [ ] **Step 2: Update the "Measured coverage" table** in `runtime-rust/README.md`. The table is around line 346. Adjust the per-tier counts (`rich N`, `usable N`, `thin N`, `peripheral N`, `empty N`) to the actual numbers from Step 1; move any crate names between rows accordingly. Bold any new arrival via v2.

- [ ] **Step 3: Extend the Alt-1 v1 paragraph** (around line 373) to record v2. After the existing "Alt-1 v1 update (shipped)" paragraph, append:

```markdown

**Alt-1 v2 update (shipped — paired).** Inspector now (a) resolves `AsRef<X>` /
`Borrow<X>` / `Into<X>` / `IntoIterator<Item=X>` for any X the table can map
(recursive), with new entries for `AsRef<Path>`/`<OsStr>`, `Into<PathBuf>` /
`<OsString>` → `String`; numeric `Into<i64/i32/u32/u64/usize/isize>` → `Int`;
`Into<f64/f32>` → `Float`; `num_traits::Integer` → `Int`; `num_traits::Float`
→ `Float`. (b) Lifts the unconditional non-byte slice/array drop: `&[T]` /
`Vec<T>` / `[T; N]` / `&[T; N]` survive whenever T is Sky-coercible; the FFI
codegen generalised `ByteKind` → `SeqKind {shape, elem}` and a new generic
runtime `to_array<E, T: Clone, const N>` mirrors `to_u8_array`'s never-panic
discipline. End-to-end proofs: `examples/rust/17-paths/` (AsRef<Path>) and
`examples/rust/18-shell-join/` (recursive `IntoIterator<Item=impl AsRef<str>>`).
The cross-crate `Digest` and generic-container classes remain out of scope.
```

- [ ] **Step 4: Update the "common shapes" sentence** below the FFI examples table (around line 134). Find the sentence beginning `These span the common shapes auto-FFI must handle:` and add `non-byte slices/arrays whose element is Sky-coercible (Alt-1 v2)` to the list.

- [ ] **Step 5: Commit:**
```bash
cd /home/arthur/Documentos/comp/sky
git add runtime-rust/README.md
git commit -m "docs(rust): record Alt-1 v2 coverage delta + non-byte slice/array recovery

Update Measured-coverage tier counts to reflect post-v2 audit (expected flips:
itoa, ryu, bytesize, percent-encoding into higher tiers as numeric/path/
recursive bounds resolve). Add Alt-1 v2 paragraph documenting recursive table
+ Path/OsStr/numeric/num_traits entries, the non-byte slice/array filter lift,
the ByteKind -> SeqKind refactor, the new to_array runtime helper, and the
two e2e examples 17-paths + 18-shell-join. Cross-crate Digest + generic
containers remain non-goals.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Self-review

**1. Spec coverage:**
- §5.1 Part A (recursive table + new entries) → Tasks 1, 2, 3 ✓
- §5.2 Part B (filter lift) → Tasks 4, 5 ✓
- §5.3 Part C (`ByteKind`→`SeqKind` refactor + emit arms) → Tasks 6, 7 ✓
- §5.4 Part D (one new `to_array` runtime helper) → Task 8 ✓
- §6 soundness gate → preserved in every task (drop-on-unresolvable behaviour kept; byte path byte-identical verified by re-running 16-hex in Task 6 Step 7) ✓
- §7 testing & verification — unit tests in Tasks 1-5, proptest in Task 8, e2e in Tasks 10+11, audit delta + README in Task 12 ✓
- §8 worked examples — hex (regression in Task 5), `&[String]`+`[f64;3]` (Task 5), Path (Task 10), recursive IntoIterator (Task 11) ✓
- §9 risks — numeric narrowing (FfiGen `as` cast existing), Windows path pragma (documented in spec carries through), nested-generic conservative drop (Task 4 `is_sky_coercible_elem`), backward compat (Task 6 Step 7 re-runs 16-hex), inspector cache staleness (Task 9 Steps 3-5) ✓
- §10 cross-backend safety — file map at top + Tasks 6-7 confined to `Sky.Build.Rust.Ffi` (Rust-only post-thin-seam); no FfiGen.hs/Compile.hs/Go file in any task ✓
- §11 out of scope — restated at the bottom of Task 12's commit message; not implemented in any task ✓

**2. Placeholder scan:**
- Tasks 10 + 11 give specific crate candidates (`path-clean`, `shellwords` / `shell-words`) plus fallbacks; the crate is named, the signatures are precise. Not a placeholder.
- Task 6's `ElemGeneral -> ("()", \_ -> "()")` placeholder is documented as deliberately transient (extended in Task 7) and the merge order is noted. Not a vague placeholder — exact code shown.
- No "TBD" / "TODO" / "add appropriate error handling" anywhere.

**3. Type/name consistency** (cross-task):
- `concrete_for_inner_type` referenced by `bound_to_concrete` (Tasks 2 → 3) — same name, same signature.
- `is_coercible_seq` defined Task 4, used Task 5 — same name.
- `is_sky_coercible_elem` defined Task 4 (Rust) and Task 6 (Haskell `isCoercibleElem` / `knownPrim` list) — element sets match: `u8..i64..f64..String..PathBuf..OsString` consistent.
- `SeqKind` / `SeqShape` / `SeqElem` / `seqKind` — defined Task 6, used Tasks 6+7 — same names.
- `to_array` defined Task 8, used Task 7's `arrPrelude` (`to_array::<SkyError, T, N>`) — same name + arg shape.
- `i64_node` / `f64_node` / `usize_node` / `vec_u8_node` / `string_node` consistent across Tasks 1-3.

---

## Notes for the implementer

- **Inspector unit tests** are the fastest TDD loop: `cd tools/sky-ffi-inspect-rs && cargo test` ≈ <1s.
- **`cabal install`** in Task 9 is the slow step (~3-5 minutes). Use the time to draft the example `Main.sky` files for Tasks 10+11.
- **`mem-guard.sh` is macOS-only and broken on this Linux host** — ignore any reference. The Linux OOM-killer is the backstop; nothing in this plan compiles anything heavy enough to risk OOM (the heaviest is `cabal install`, well-bounded).
- **Cross-backend rule:** every change in this plan is inside `tools/sky-ffi-inspect-rs/` (Rust-only), `src/Sky/Build/Rust/Ffi.hs` (Rust-only post-thin-seam refactor), `runtime-rust/` (Rust-only), or `examples/rust/` (Rust-only). If a step seems to require editing `FfiGen.hs`, `Compile.hs`, `Builder.hs`, or any Go file — stop, the design says it shouldn't.
- **If Task 6's `ElemGeneral` placeholder bothers your linter** or feels brittle, merge Tasks 6 + 7 into a single commit ("ByteKind→SeqKind + ElemGeneral emit arms") — same end state, one commit instead of two.
- **Task 10's `path-clean` and Task 11's `shellwords`** are first-choice candidates; their actual current signatures govern whether the examples need tweaks. Task 9's smoke step prints what binds — use that to verify before writing the `Main.sky`.
