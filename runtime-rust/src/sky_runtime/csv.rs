//! Std.Csv — CSV parse / encode via the `csv` crate (v0.15.47).
//!
//! The Sky `Csv` record (`{ header : List String, rows : List (List String) }`)
//! is mapped to `CsvDoc` below via the runtimeOpaqueTypes registry, so the
//! generated `StdCsvCsv` is a `pub use` alias of this struct. That lets the
//! kernels return/take the record DIRECTLY (no kernel can name a generated
//! per-project struct), and Sky field access (`doc.header`) + the synthesized
//! record constructor resolve straight onto these `pub` fields.

use super::*;
use std::future::ready;

/// Runtime representation of the Sky `Std.Csv.Csv` record. Field names + types
/// must match the Sky alias exactly (List String -> Vec<String>, etc.).
#[derive(Clone, Debug, PartialEq)]
pub struct CsvDoc {
    pub header: Vec<String>,
    pub rows: Vec<Vec<String>>,
}

fn first_byte(delim: &str) -> u8 {
    delim.as_bytes().first().copied().unwrap_or(b',')
}

fn parse_delim<E: From<String>>(text: &str, delim: u8) -> SkyResult<E, CsvDoc> {
    let mut rdr = ::csv::ReaderBuilder::new()
        .delimiter(delim)
        .has_headers(true)
        .flexible(true)
        .from_reader(text.as_bytes());
    let header: Vec<String> = match rdr.headers() {
        Ok(h) => h.iter().map(|s| s.to_string()).collect(),
        Err(e) => return SkyResult::Err(format!("Csv.parse: {}", e).into()),
    };
    let mut rows = Vec::new();
    for rec in rdr.records() {
        match rec {
            Ok(r) => rows.push(r.iter().map(|s| s.to_string()).collect()),
            Err(e) => return SkyResult::Err(format!("Csv.parse: {}", e).into()),
        }
    }
    SkyResult::Ok(CsvDoc { header, rows })
}

fn encode_delim(doc: &CsvDoc, delim: u8) -> String {
    let mut wtr = ::csv::WriterBuilder::new().delimiter(delim).from_writer(vec![]);
    let _ = wtr.write_record(&doc.header);
    for row in &doc.rows {
        let _ = wtr.write_record(row);
    }
    let bytes = wtr.into_inner().unwrap_or_default();
    String::from_utf8_lossy(&bytes).into_owned()
}

/// Csv.parse : String -> Result Error Csv
pub fn csv_parse<E: From<String>>(text: String) -> SkyResult<E, CsvDoc> {
    parse_delim(&text, b',')
}

/// Csv.parseWithDelimiter : String -> String -> Result Error Csv
pub fn csv_parse_with_delimiter<E: From<String>>(delim: String, text: String) -> SkyResult<E, CsvDoc> {
    parse_delim(&text, first_byte(&delim))
}

/// Csv.encode : Csv -> String
pub fn csv_encode(doc: CsvDoc) -> String {
    encode_delim(&doc, b',')
}

/// Csv.encodeWithDelimiter : String -> Csv -> String
pub fn csv_encode_with_delimiter(delim: String, doc: CsvDoc) -> String {
    encode_delim(&doc, first_byte(&delim))
}

/// Csv.parseStreamFromFile : String -> Task Error (List (List String))
/// Returns every row (including the header).
pub fn csv_parse_stream_from_file<E: From<String> + Send + 'static>(path: String) -> SkyTask<E, Vec<Vec<String>>> {
    let result = (|| -> Result<Vec<Vec<String>>, String> {
        let content = std::fs::read_to_string(&path).map_err(|e| e.to_string())?;
        let mut rdr = ::csv::ReaderBuilder::new()
            .has_headers(false)
            .flexible(true)
            .from_reader(content.as_bytes());
        let mut out = Vec::new();
        for rec in rdr.records() {
            let r = rec.map_err(|e| e.to_string())?;
            out.push(r.iter().map(|s| s.to_string()).collect());
        }
        Ok(out)
    })();
    Box::pin(ready(match result {
        Ok(v) => ok_res(v),
        Err(e) => SkyResult::Err(format!("Csv.parseStreamFromFile: {}", e).into()),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_then_encode_roundtrip() {
        let doc: SkyResult<String, CsvDoc> = csv_parse("a,b\n1,2\n3,4".to_string());
        let d = match doc { SkyResult::Ok(d) => d, _ => panic!("parse failed") };
        assert_eq!(d.header, vec!["a", "b"]);
        assert_eq!(d.rows, vec![vec!["1", "2"], vec!["3", "4"]]);
        let out = csv_encode(d);
        assert_eq!(out, "a,b\n1,2\n3,4\n");
    }

    #[test]
    fn quoting() {
        let doc = CsvDoc { header: vec!["x".into()], rows: vec![vec!["a,b".into()]] };
        assert_eq!(csv_encode(doc), "x\n\"a,b\"\n");
    }
}
