use crate::model::{lang_of, role_of, Lang, Role};
use anyhow::Result;
use std::process::Command;

pub const MAX_FILE_BYTES: u64 = 2 * 1024 * 1024; // 2 MB cap (anti-OOM)

pub struct Tracked { pub path: String, pub lang: Lang, pub role: Role }

pub fn parse_tracked(ls_output: &str) -> Vec<Tracked> {
    ls_output.lines().filter(|l| !l.is_empty())
        .map(|p| Tracked { path: p.to_string(), lang: lang_of(p), role: role_of(p) })
        .collect()
}

/// All git-tracked files in `repo` (respects .gitignore — generated dirs excluded).
pub fn tracked(repo: &str) -> Result<Vec<Tracked>> {
    let out = Command::new("git").arg("-C").arg(repo).args(["ls-files"]).output()?;
    Ok(parse_tracked(&String::from_utf8_lossy(&out.stdout)))
}

/// Changed/added + deleted paths between `since` sha and HEAD (for incremental update).
pub fn changed(repo: &str, since: &str) -> Result<(Vec<Tracked>, Vec<String>)> {
    let out = Command::new("git").arg("-C").arg(repo)
        .args(["diff", "--name-status", &format!("{since}..HEAD")]).output()?;
    let text = String::from_utf8_lossy(&out.stdout);
    let mut upserts = Vec::new();
    let mut deletes = Vec::new();
    for line in text.lines() {
        let mut it = line.split('\t');
        let (status, path) = (it.next().unwrap_or(""), it.next().unwrap_or(""));
        if path.is_empty() { continue; }
        if status.starts_with('D') { deletes.push(path.to_string()); }
        else { upserts.push(Tracked { path: path.to_string(), lang: lang_of(path), role: role_of(path) }); }
    }
    Ok((upserts, deletes))
}

pub fn head_sha(repo: &str) -> Result<String> {
    let out = Command::new("git").arg("-C").arg(repo).args(["rev-parse","HEAD"]).output()?;
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_ls_files_output() {
        let out = "src/Sky/Parse/Lexer.hs\nruntime-rust/src/sky_runtime/list.rs\nsky-stdlib/Sky/Core/List.sky\n";
        let v = parse_tracked(out);
        assert_eq!(v.len(), 3);
        assert_eq!(v[0].path, "src/Sky/Parse/Lexer.hs");
        assert_eq!(v[1].lang, crate::model::Lang::Rust);
        assert_eq!(v[2].role, crate::model::Role::StdlibSky);
    }
}
