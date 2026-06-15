use crate::store::Store;
use anyhow::Result;

// Minimal stubs for Task 8 (filled in Task 10). `cmd_roles` is implemented now
// because the `index_e2e` test invokes the `roles` subcommand.

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

pub fn cmd_parity(_db: &str, _gaps: bool) -> Result<()> {
    Ok(())
}
pub fn cmd_deps(_db: &str, _module: &str) -> Result<()> {
    Ok(())
}
pub fn cmd_pipeline(_db: &str) -> Result<()> {
    Ok(())
}
pub fn cmd_covers(_db: &str, _kernel: &str) -> Result<()> {
    Ok(())
}
pub fn cmd_wakeup(_db: &str) -> Result<()> {
    Ok(())
}
pub fn cmd_update(_repo: &str, _db: &str) -> Result<()> {
    Ok(())
}
