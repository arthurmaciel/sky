use anyhow::Result;
use rusqlite::Connection;

pub struct Store { pub conn: Connection }

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS files   (path TEXT PRIMARY KEY, lang TEXT, role TEXT, size INTEGER, sha TEXT);
CREATE TABLE IF NOT EXISTS symbols (file TEXT, name TEXT, kind TEXT, line INTEGER);
CREATE TABLE IF NOT EXISTS edges   (src TEXT, dst TEXT, kind TEXT);
CREATE TABLE IF NOT EXISTS kernels (name TEXT PRIMARY KEY, sky_decl INTEGER, hs_route TEXT, go_impl INTEGER, rust_impl INTEGER, parity TEXT);
CREATE TABLE IF NOT EXISTS meta    (k TEXT PRIMARY KEY, v TEXT);
CREATE INDEX IF NOT EXISTS i_sym_name ON symbols(name);
CREATE INDEX IF NOT EXISTS i_edge_src ON edges(src);
CREATE INDEX IF NOT EXISTS i_edge_dst ON edges(dst);
";

impl Store {
    pub fn open(path: &str) -> Result<Self> {
        let conn = Connection::open(path)?;
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")?;
        conn.execute_batch(SCHEMA)?;
        Ok(Store { conn })
    }
    pub fn begin(&self) -> Result<()> { self.conn.execute_batch("BEGIN;")?; Ok(()) }
    pub fn commit(&self) -> Result<()> { self.conn.execute_batch("COMMIT;")?; Ok(()) }
    pub fn put_file(&self, path:&str, lang:&str, role:&str, size:i64, sha:&str) -> Result<()> {
        self.conn.execute("INSERT OR REPLACE INTO files VALUES (?,?,?,?,?)", rusqlite::params![path,lang,role,size,sha])?; Ok(())
    }
    pub fn put_symbol(&self, file:&str, name:&str, kind:&str, line:i64) -> Result<()> {
        self.conn.execute("INSERT INTO symbols VALUES (?,?,?,?)", rusqlite::params![file,name,kind,line])?; Ok(())
    }
    pub fn put_edge(&self, src:&str, dst:&str, kind:&str) -> Result<()> {
        self.conn.execute("INSERT INTO edges VALUES (?,?,?)", rusqlite::params![src,dst,kind])?; Ok(())
    }
    pub fn drop_file(&self, path:&str) -> Result<()> {
        self.conn.execute("DELETE FROM files WHERE path=?", [path])?;
        self.conn.execute("DELETE FROM symbols WHERE file=?", [path])?;
        self.conn.execute("DELETE FROM edges WHERE src=?", [path])?;
        Ok(())
    }
    pub fn set_meta(&self, k:&str, v:&str) -> Result<()> {
        self.conn.execute("INSERT OR REPLACE INTO meta VALUES (?,?)", [k,v])?; Ok(())
    }
    pub fn get_meta(&self, k:&str) -> Result<Option<String>> {
        Ok(self.conn.query_row("SELECT v FROM meta WHERE k=?", [k], |r| r.get(0)).ok())
    }
    pub fn count(&self, table:&str) -> Result<i64> {
        Ok(self.conn.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))?)
    }
    pub fn symbols_named(&self, name:&str) -> Result<Vec<(String,i64)>> {
        let mut st = self.conn.prepare("SELECT file,line FROM symbols WHERE name=? ORDER BY file")?;
        let rows = st.query_map([name], |r| Ok((r.get(0)?, r.get(1)?)))?;
        Ok(rows.collect::<std::result::Result<_,_>>()?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn roundtrip() {
        let s = Store::open(":memory:").unwrap();
        s.put_file("a.rs", "rs", "runtime-rust", 10, "deadbeef").unwrap();
        s.put_symbol("a.rs", "list_head", "fn", 5).unwrap();
        s.put_edge("a.rs", "b.rs", "import").unwrap();
        assert_eq!(s.count("files").unwrap(), 1);
        assert_eq!(s.count("symbols").unwrap(), 1);
        assert_eq!(s.count("edges").unwrap(), 1);
        let fns = s.symbols_named("list_head").unwrap();
        assert_eq!(fns, vec![("a.rs".to_string(), 5)]);
    }
}
