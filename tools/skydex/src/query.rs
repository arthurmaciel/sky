use crate::store::Store;
use crate::{coverage, extract, model, parity, pipeline, walk};
use anyhow::Result;
use std::collections::HashSet;

pub fn cmd_parity(db: &str, gaps: bool) -> Result<()> {
    let s = Store::open(db)?;
    let sql = if gaps {
        "SELECT name,parity,go_impl,rust_impl FROM kernels WHERE parity!='ok' ORDER BY parity,name"
    } else {
        "SELECT name,parity,go_impl,rust_impl FROM kernels ORDER BY parity,name"
    };
    let mut st = s.conn.prepare(sql)?;
    let rows = st.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, i64>(2)?,
            r.get::<_, i64>(3)?,
        ))
    })?;
    for row in rows {
        let (n, p, g, ru) = row?;
        println!("{p:<12} {n:<28} go={g} rust={ru}");
    }
    Ok(())
}

pub fn cmd_deps(db: &str, module: &str) -> Result<()> {
    let s = Store::open(db)?;
    let mut st = s.conn.prepare(
        "SELECT DISTINCT dst FROM edges WHERE src LIKE ?1 AND kind='import' ORDER BY dst",
    )?;
    let rows = st.query_map([format!("%{module}%")], |r| r.get::<_, String>(0))?;
    for r in rows {
        println!("{}", r?);
    }
    Ok(())
}

pub fn cmd_roles(db: &str) -> Result<()> {
    let s = Store::open(db)?;
    let mut st = s
        .conn
        .prepare("SELECT role,COUNT(*) FROM files GROUP BY role ORDER BY 2 DESC")?;
    let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?;
    for r in rows {
        let (role, n) = r?;
        println!("{role:<14} {n}");
    }
    Ok(())
}

pub fn cmd_pipeline(db: &str) -> Result<()> {
    let s = Store::open(db)?;
    let mut st = s.conn.prepare(
        "SELECT dst,COUNT(*) FROM edges WHERE kind='in-stage' GROUP BY dst ORDER BY 2 DESC",
    )?;
    let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?;
    for r in rows {
        let (st_, n) = r?;
        println!("{st_:<14} {n} modules");
    }
    Ok(())
}

pub fn cmd_covers(db: &str, kernel: &str) -> Result<()> {
    let s = Store::open(db)?;
    let mut st = s
        .conn
        .prepare("SELECT src FROM edges WHERE kind='covers' AND dst LIKE ?1 ORDER BY src")?;
    let rows = st.query_map([format!("%{kernel}%")], |r| r.get::<_, String>(0))?;
    for r in rows {
        println!("{}", r?);
    }
    Ok(())
}

pub fn cmd_wakeup(db: &str) -> Result<()> {
    let s = Store::open(db)?;
    println!("# skydex digest");
    println!("files: {}", s.count("files")?);
    println!(
        "symbols: {}, edges: {}, kernels: {}",
        s.count("symbols")?,
        s.count("edges")?,
        s.count("kernels")?
    );
    let gaps: i64 =
        s.conn
            .query_row("SELECT COUNT(*) FROM kernels WHERE parity!='ok'", [], |r| {
                r.get(0)
            })?;
    println!("parity gaps: {gaps}  (run `skydex parity --gaps`)");
    cmd_roles(db)
}

pub fn cmd_update(repo: &str, db: &str) -> Result<()> {
    let s = Store::open(db)?;
    let Some(since) = s.get_meta("last_sha")? else {
        drop(s);
        return crate::cmd_index_pub(repo, db);
    };
    let (ups, dels) = walk::changed(repo, &since)?;
    s.begin()?;
    for d in &dels {
        s.drop_file(d)?;
    }
    for f in &ups {
        s.drop_file(&f.path)?;
        let p = std::path::Path::new(repo).join(&f.path);
        let Ok(md) = std::fs::metadata(&p) else {
            continue;
        };
        if md.len() > walk::MAX_FILE_BYTES {
            continue;
        }
        let Ok(src) = std::fs::read_to_string(&p) else {
            continue;
        };
        s.put_file(&f.path, f.lang.as_str(), f.role.as_str(), src.len() as i64, "")?;
        extract::extract_file(&s, &f.path, f.lang, &src)?;
        pipeline::record_stage(&s, &f.path)?;
        if f.role == model::Role::Fixture || f.role == model::Role::Example {
            coverage::record_coverage(&s, &f.path, &src)?;
        }
    }
    // Re-reconcile parity over the whole repo's Go/Rust fns + every Kernel.hs.
    reconcile_from_store(&s, repo)?;
    s.set_meta("last_sha", &walk::head_sha(repo)?)?;
    s.commit()?;
    eprintln!(
        "skydex: updated {} files (+{} -{})",
        ups.len() + dels.len(),
        ups.len(),
        dels.len()
    );
    Ok(())
}

/// Re-derive the kernels table from what is already indexed: Go/Rust `def`
/// symbols come from the `symbols` table; the Kernel.hs route source is read off
/// disk for every indexed file whose path ends in `Kernel.hs` (robust to either
/// the Go or Rust Kernel.hs path moving — no hardcoded paths).
fn reconcile_from_store(s: &Store, repo: &str) -> Result<()> {
    let mut go: HashSet<String> = HashSet::new();
    let mut rust: HashSet<String> = HashSet::new();
    {
        let mut st = s.conn.prepare(
            "SELECT s.name,f.lang FROM symbols s JOIN files f ON s.file=f.path WHERE s.kind='def'",
        )?;
        for row in st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? {
            let (name, lang) = row?;
            if lang == "go" {
                go.insert(name);
            } else if lang == "rs" {
                rust.insert(name);
            }
        }
    }
    // Every indexed Kernel.hs, read off disk under the per-file size cap.
    let mut hs = String::new();
    {
        let mut st = s
            .conn
            .prepare("SELECT path FROM files WHERE path LIKE '%Kernel.hs'")?;
        let paths: Vec<String> = st
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<std::result::Result<_, _>>()?;
        for kp in paths {
            let full = std::path::Path::new(repo).join(&kp);
            if let Ok(md) = std::fs::metadata(&full) {
                if md.len() > walk::MAX_FILE_BYTES {
                    continue;
                }
            }
            if let Ok(t) = std::fs::read_to_string(&full) {
                hs.push_str(&t);
                hs.push('\n');
            }
        }
    }
    let routes = parity::parse_routes(&hs);
    s.conn.execute("DELETE FROM kernels", [])?;
    for k in parity::reconcile(&routes, &go, &rust) {
        s.conn.execute(
            "INSERT OR REPLACE INTO kernels VALUES (?,?,?,?,?,?)",
            rusqlite::params![k.name, 1, k.rust_fn, k.go_impl as i64, k.rust_impl as i64, k.parity],
        )?;
    }
    Ok(())
}
