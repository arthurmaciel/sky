use crate::model::Lang;
use crate::store::Store;
use anyhow::Result;
use tree_sitter::{Parser, Query, QueryCursor};

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
