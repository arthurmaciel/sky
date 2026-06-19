pub mod sky;
pub mod treesitter;

pub use treesitter::go_registered_kernels;
pub use treesitter::treesitter_defs;

use crate::model::Lang;
use crate::store::Store;
use anyhow::Result;
use regex::Regex;
use std::sync::OnceLock;

fn re_hs_import() -> &'static Regex { static R: OnceLock<Regex> = OnceLock::new(); R.get_or_init(|| Regex::new(r"^import\s+(?:qualified\s+)?([\w.]+)").unwrap()) }
fn re_sh_source() -> &'static Regex { static R: OnceLock<Regex> = OnceLock::new(); R.get_or_init(|| Regex::new(r"^\s*(?:source|\.)\s+(\S+)").unwrap()) }

/// Extract symbols + import edges for one file's contents. Bounded: caller passes
/// the already-read `src`; tree-sitter trees are created + dropped inside.
pub fn extract_file(store: &Store, path: &str, lang: Lang, src: &str) -> Result<()> {
    match lang {
        Lang::Sky => {
            let r = sky::scan_sky(src);
            for i in r.imports { store.put_edge(path, &i, "import")?; }
            for (b, line) in r.bindings { store.put_symbol(path, &b, "binding", line, 0)?; }
            // kernels handled by parity.rs over the whole repo
        }
        Lang::Haskell => {
            for line in src.lines() {
                if let Some(c) = re_hs_import().captures(line) { store.put_edge(path, &c[1], "import")?; }
            }
            // Haskell top-level symbols are not needed for v1 relations.
        }
        Lang::Bash => {
            for line in src.lines() {
                if let Some(c) = re_sh_source().captures(line) { store.put_edge(path, &c[1], "import")?; }
            }
        }
        Lang::Go => {
            treesitter::extract(store, path, lang, src)?;
            // Also capture kernels registered via string literals, e.g.
            //   RegisterPure("Decimal_add", func(args []any) any { ... })
            // tree-sitter only sees the anonymous closure, never the name.
            // Store with the real line number so loc lookups find them.
            for (name, line) in treesitter::go_registered_kernels(src) {
                store.put_symbol(path, &name, "def", line, 0)?;
            }
        }
        Lang::Rust | Lang::Ts => treesitter::extract(store, path, lang, src)?,
        Lang::Other => {}
    }
    Ok(())
}
