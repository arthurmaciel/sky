use crate::model::Lang;
use crate::store::Store;
use anyhow::Result;
use regex::Regex;
use std::sync::OnceLock;
use tree_sitter::{Parser, Query, QueryCursor};

fn re_go_register() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        // Matches: RegisterPure("Mod_fn", ...) or RegisterTask("Mod_fn", ...)
        // Captures the string literal name (group 1).
        // tree-sitter misses these because the func arg is anonymous.
        Regex::new(r#"Register\w*\(\s*"([A-Za-z][A-Za-z0-9]*_[A-Za-z][A-Za-z0-9]*)""#).unwrap()
    })
}

/// Go kernels registered via string literals: `RegisterPure("Mod_fn", ...)`,
/// `RegisterTask("Mod_fn", ...)`, etc.  tree-sitter misses these (the closure
/// passed as the second arg is anonymous, so the `function_declaration` name
/// capture never fires for them).  Line-scan them separately and return the
/// registered kernel names so callers can union them into `go_fns`.
pub fn go_registered_kernels(src: &str) -> Vec<String> {
    re_go_register()
        .captures_iter(src)
        .map(|c| c[1].to_string())
        .collect()
}

fn lang_grammar(path: &str, lang: Lang) -> Option<(tree_sitter::Language, &'static str)> {
    // (grammar, query) — query captures @def (a defined symbol) and @imp (an import target)
    match lang {
        Lang::Rust => Some((tree_sitter_rust::language(),
            "(function_item name:(identifier)@def) \
             (struct_item name:(type_identifier)@def) \
             (use_declaration argument:(_)@imp)")),
        Lang::Go => Some((tree_sitter_go::language(),
            "(function_declaration name:(identifier)@def) \
             (method_declaration name:(field_identifier)@def) \
             (import_spec path:(interpreted_string_literal)@imp)")),
        // ALL of JS/TS/MJS/TSX land here (lang_of maps js/mjs/ts/tsx -> Ts). Pick the
        // grammar variant by extension so plain JS + JSX + ESM all parse:
        //   .tsx/.jsx/.js/.mjs -> tsx grammar (superset, most permissive)
        //   .ts/.mts           -> typescript grammar
        // Same ESM import query + a const/let/var-arrow def capture for JS modules.
        Lang::Ts => {
            let tsx = path.ends_with(".tsx") || path.ends_with(".jsx")
                   || path.ends_with(".js")  || path.ends_with(".mjs");
            let g = if tsx { tree_sitter_typescript::language_tsx() }
                    else   { tree_sitter_typescript::language_typescript() };
            Some((g, "(function_declaration name:(identifier)@def) \
                      (lexical_declaration (variable_declarator name:(identifier)@def value:(arrow_function))) \
                      (import_statement source:(string)@imp)"))
        }
        _ => None,
    }
}

pub fn extract(store: &Store, path: &str, lang: Lang, src: &str) -> Result<()> {
    let Some((grammar, query_src)) = lang_grammar(path, lang) else { return Ok(()) };
    let mut parser = Parser::new();
    parser.set_language(&grammar)?;
    let Some(tree) = parser.parse(src, None) else { return Ok(()) };   // tree lives only in this scope
    let query = Query::new(&grammar, query_src)?;
    let def_idx = query.capture_index_for_name("def");
    let imp_idx = query.capture_index_for_name("imp");
    let mut cur = QueryCursor::new();
    for m in cur.matches(&query, tree.root_node(), src.as_bytes()) {
        for cap in m.captures {
            let text = &src[cap.node.byte_range()];
            let line = cap.node.start_position().row as i64 + 1;
            if Some(cap.index) == def_idx {
                store.put_symbol(path, text, "def", line)?;
            } else if Some(cap.index) == imp_idx {
                let target = text.trim_matches(|c| c == '"' || c == '\'');
                store.put_edge(path, target, "import")?;
            }
        }
    }
    Ok(())   // `tree` dropped here, before the next file — the bounded-memory invariant
}

/// Returns just the @def capture texts for the given source + language.
/// Reuses the query; no store interaction. Used by the index pipeline for parity reconcile.
pub fn treesitter_defs(src: &str, lang: Lang) -> Vec<String> {
    // Use a dummy path to select grammar variant (Go/Rust don't need path, Ts does)
    let path = match lang {
        Lang::Go => "x.go",
        Lang::Rust => "x.rs",
        Lang::Ts => "x.ts",
        _ => return Vec::new(),
    };
    let Some((grammar, query_src)) = lang_grammar(path, lang) else { return Vec::new() };
    let mut parser = Parser::new();
    if parser.set_language(&grammar).is_err() { return Vec::new(); }
    let Some(tree) = parser.parse(src, None) else { return Vec::new() };
    let Ok(query) = Query::new(&grammar, query_src) else { return Vec::new() };
    let def_idx = query.capture_index_for_name("def");
    let mut cur = QueryCursor::new();
    let mut defs = Vec::new();
    for m in cur.matches(&query, tree.root_node(), src.as_bytes()) {
        for cap in m.captures {
            if Some(cap.index) == def_idx {
                defs.push(src[cap.node.byte_range()].to_string());
            }
        }
    }
    defs
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::Store; use crate::model::Lang;

    // ── Finding #1 regression: go_registered_kernels ────────────────────────
    #[test]
    fn go_registered_kernels_captures_string_registered_names() {
        // Mirrors the real pattern in runtime-go/rt/decimal_kernel.go etc.:
        //   RegisterPure("Decimal_add", func(args []any) any { ... })
        // tree-sitter sees the anonymous func, never "Decimal_add".
        let src = "func x(){}\n\tRegisterPure(\"Decimal_add\", func(a []any) any { nil })\n";
        let names = go_registered_kernels(src);
        assert_eq!(names, vec!["Decimal_add"]);
    }

    #[test]
    fn go_registered_kernels_captures_multiple() {
        let src = "\tRegisterPure(\"Money_add\", func(a []any) any { nil })\n\
                   \tRegisterPure(\"Bytes_empty\", func(a []any) any { nil })\n\
                   // not a kernel: RegisterReadinessProbe(\"db\", ...)\n\
                   \tRegisterTask(\"Cache_get\", func(a []any) any { nil })\n";
        let mut names = go_registered_kernels(src);
        names.sort();
        assert_eq!(names, vec!["Bytes_empty", "Cache_get", "Money_add"]);
    }

    #[test]
    fn go_registered_kernels_ignores_non_kernel_patterns() {
        // RegisterReadinessProbe("db", ...) — "db" has no underscore, must not match
        let src = "RegisterReadinessProbe(\"db\", probe)\n\
                   RegisterReadinessProbe(\"sessions\", probe)\n";
        let names = go_registered_kernels(src);
        assert!(names.is_empty(), "Expected empty, got: {names:?}");
    }

    // ─────────────────────────────────────────────────────────────────────────
    #[test]
    fn extracts_rust_fn_and_use() {
        let s = Store::open(":memory:").unwrap();
        let src = "use crate::model::Lang;\npub fn list_head(xs: Vec<i64>) -> i64 { 0 }\n";
        extract(&s, "a.rs", Lang::Rust, src).unwrap();
        assert_eq!(s.symbols_named("list_head").unwrap().len(), 1);
        // a `use` edge was recorded
        assert!(s.count("edges").unwrap() >= 1);
    }
    #[test]
    fn extracts_js_import_and_arrow() {
        // JS/MJS go through the tsx grammar variant; ESM import + arrow-const def.
        let s = Store::open(":memory:").unwrap();
        let src = "import { foo } from './bar.mjs';\nexport const handler = (x) => x + 1;\n";
        extract(&s, "x.mjs", Lang::Ts, src).unwrap();
        assert_eq!(s.symbols_named("handler").unwrap().len(), 1);
        assert!(s.count("edges").unwrap() >= 1);
    }
}
