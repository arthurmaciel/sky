// Stub — filled in Task 6.
use crate::model::Lang;
use crate::store::Store;
use anyhow::Result;

pub fn extract(_store: &Store, _path: &str, _lang: Lang, _src: &str) -> Result<()> {
    Ok(())
}

/// Returns just the @def capture texts for the given source + language.
/// Reuses the Task-6 query; no store interaction. Added here for Task 8 usage.
pub fn treesitter_defs(_src: &str, _lang: Lang) -> Vec<String> {
    Vec::new()
}
