//! sky-firestore-shim — STUB surface for the skyshop-rs Sky→Rust port (Stage 1).
//!
//! This is the FULL FFI surface the app's `Lib/Db.sky` needs, with STUB bodies
//! returning canned data and ZERO heavy deps (no `firestore`, no `tokio`). Each
//! public fn is a TOTAL `fn(..) -> Result<_, String>` the Sky auto-FFI binds as
//! a synchronous Sky `Result` (D1), with the D3 flat shape:
//!
//!   * single doc  → `Result<HashMap<String,String>, String>`  (Sky: `Result String (Dict String String)`)
//!   * query rows  → `Result<Vec<HashMap<String,String>>, String>` (Sky: `Result String (List (Dict String String))`)
//!
//! ERROR-SLOT WRINKLE: the Sky side discards the `Err` payload (`Err _ ->`).
//! "Document not found" is therefore signalled IN the Ok payload via a
//! `"_status"` key (`"ok"` | `"not_found"`), NOT in the error string. Real
//! errors (Stage 2 firestore failures) still go through `Err(String)` and the
//! firestore `Display` is embedded verbatim so `wrapDbError` keeps matching.
//!
//! All `&str` params (Sky passes `&arg`); owned internally.

use std::collections::HashMap;

/// Build a canned product row. Stage 2 replaces this with a real Firestore read.
fn canned_product(id: &str, title: &str, category: &str, price: i64, stock: i64) -> HashMap<String, String> {
    let mut m = HashMap::new();
    m.insert("_status".to_string(), "ok".to_string());
    m.insert("id".to_string(), id.to_string());
    m.insert("title".to_string(), title.to_string());
    m.insert("summary".to_string(), format!("A faithful stub summary for {title}."));
    m.insert("category".to_string(), category.to_string());
    m.insert("price_amount".to_string(), price.to_string());
    m.insert("price_currency".to_string(), "GBP".to_string());
    m.insert("price_discount".to_string(), "0".to_string());
    m.insert("price_tax".to_string(), "0".to_string());
    m.insert("stock".to_string(), stock.to_string());
    m.insert("published".to_string(), "true".to_string());
    m
}

fn canned_products() -> Vec<HashMap<String, String>> {
    vec![
        canned_product("p1", "Leather Wallet", "Wallet And Small Items", 4500, 12),
        canned_product("p2", "Canvas Tote Bag", "Bags", 2900, 30),
        canned_product("p3", "Silk Scarf", "Fashion", 6200, 0),
        canned_product("p4", "Steel Watch", "Jewellery And Watches", 18900, 5),
        canned_product("p5", "Kids Beanie", "Kids", 1500, 40),
        canned_product("p6", "Designer Sunglasses", "Luxury Brands", 22000, 8),
    ]
}

/// `not_found`-tagged empty row — the Ok payload carries the absence flag so
/// the Sky side never has to read the (unusable) `Err` slot for "no such doc".
fn not_found_row() -> HashMap<String, String> {
    let mut m = HashMap::new();
    m.insert("_status".to_string(), "not_found".to_string());
    m
}

/// `fs_get_doc(collection, id) -> Result<HashMap<String,String>, String>`
/// Sky: `Result String (Dict String String)`.
/// Canned: a product for the `products` collection (matching id), an ok row
/// echoing the id for other collections, `not_found` when nothing matches.
pub fn fs_get_doc(collection: &str, id: &str) -> Result<HashMap<String, String>, String> {
    if collection == "products" {
        if let Some(row) = canned_products()
            .into_iter()
            .find(|r| r.get("id").map(|v| v.as_str()) == Some(id))
        {
            return Ok(row);
        }
        return Ok(not_found_row());
    }
    // Other collections (users / carts / orders / cart_items / ...) — stub
    // returns a minimal ok row echoing the id so getOrCreate-style flows work.
    let mut m = HashMap::new();
    m.insert("_status".to_string(), "ok".to_string());
    m.insert("id".to_string(), id.to_string());
    Ok(m)
}

/// `fs_set_doc(collection, id, fields_json) -> Result<String, String>`
/// Sky: `Result String String`. Returns the doc id on success.
/// `fields_json` is a flat `{"k":"v",...}` object (D3).
pub fn fs_set_doc(collection: &str, id: &str, fields_json: &str) -> Result<String, String> {
    let _collection = collection.to_string();
    let _fields: HashMap<String, String> =
        serde_json::from_str(fields_json).map_err(|e| format!("bad fields_json: {e}"))?;
    // Stub: pretend the write succeeded; echo the id.
    Ok(id.to_string())
}

/// `fs_delete_doc(collection, id) -> Result<String, String>`
/// Sky: `Result String String`. Returns the deleted id.
pub fn fs_delete_doc(collection: &str, id: &str) -> Result<String, String> {
    let _collection = collection.to_string();
    Ok(id.to_string())
}

/// `fs_query(collection) -> Result<Vec<HashMap<String,String>>, String>`
/// Sky: `Result String (List (Dict String String))`.
pub fn fs_query(collection: &str) -> Result<Vec<HashMap<String, String>>, String> {
    if collection == "products" {
        return Ok(canned_products());
    }
    Ok(Vec::new())
}

/// `fs_query_where(collection, field, op, value) -> Result<Vec<HashMap<String,String>>, String>`
/// Sky: `Result String (List (Dict String String))`. Stub filters the canned
/// product set by exact-match on the named field when collection == products;
/// the `published` field always passes (canned set is all-published).
pub fn fs_query_where(
    collection: &str,
    field: &str,
    op: &str,
    value: &str,
) -> Result<Vec<HashMap<String, String>>, String> {
    let _op = op.to_string();
    if collection == "products" {
        let rows: Vec<HashMap<String, String>> = canned_products()
            .into_iter()
            .filter(|r| match field {
                "published" => true,
                other => r.get(other).map(|v| v.as_str()) == Some(value),
            })
            .collect();
        return Ok(rows);
    }
    Ok(Vec::new())
}

/// `fs_query_where_order(collection, field, op, value, order_field, dir) -> Result<Vec<HashMap<String,String>>, String>`
/// Sky: `Result String (List (Dict String String))`. Stub = fs_query_where +
/// a stable order on `order_field` (numeric-aware) respecting `dir`.
pub fn fs_query_where_order(
    collection: &str,
    field: &str,
    op: &str,
    value: &str,
    order_field: &str,
    dir: &str,
) -> Result<Vec<HashMap<String, String>>, String> {
    let mut rows = fs_query_where(collection, field, op, value)?;
    let of = order_field.to_string();
    rows.sort_by(|a, b| {
        let av = a.get(&of).cloned().unwrap_or_default();
        let bv = b.get(&of).cloned().unwrap_or_default();
        match (av.parse::<i64>(), bv.parse::<i64>()) {
            (Ok(ai), Ok(bi)) => ai.cmp(&bi),
            _ => av.cmp(&bv),
        }
    });
    if dir == "desc" {
        rows.reverse();
    }
    Ok(rows)
}
