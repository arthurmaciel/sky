// Sky Runtime — DB kernel functions
// Uses types from config.rs (generated at Sky build time):
//   - SkyError, str_err (from config)
//   - DbPool (type alias, e.g. sqlx::sqlite::SqlitePool)
//   - DbRow (type alias)
//   - SKY_DB_URL (const &str)

use std::collections::HashMap;

pub type Db = DbPool;

fn sky_err(e: &sqlx::Error) -> SkyError {
    let msg = format!("{}", e);
    let kind = match e {
        sqlx::Error::Database(db) => {
            let code = db.code().map(|c| c.to_string()).unwrap_or_default();
            if code == "2067" || code == "1555" || code == "23505" || code == "1062" || msg.contains("UNIQUE constraint") {
                "Conflict"
            } else { "Unexpected" }
        }
        _ => "Unexpected",
    };
    str_err(&format!("[{}] {}", kind, msg))
}

fn build_sql(sql: &str, params: &[String]) -> String {
    let mut result = String::new();
    let mut param_idx = 0;
    let mut chars = sql.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '?' && param_idx < params.len() {
            let val = &params[param_idx];
            let escaped = if val.parse::<i64>().is_ok() || val.parse::<f64>().is_ok() {
                val.clone()
            } else {
                format!("'{}'", val.replace('\'', "''"))
            };
            result.push_str(&escaped);
            param_idx += 1;
        } else {
            result.push(c);
        }
    }
    result
}

fn row_to_map(row: &DbRow) -> HashMap<String, String> {
    let mut map = HashMap::new();
    let cols = row.columns();
    for i in 0..cols.len() {
        let name = cols[i].name().to_string();
        let value: String = match row.try_get::<Option<String>, _>(i) {
            Ok(Some(v)) => v,
            Ok(None) => String::new(),
            _ => match row.try_get::<Option<i64>, _>(i) {
                Ok(Some(v)) => v.to_string(),
                _ => match row.try_get::<Option<f64>, _>(i) {
                    Ok(Some(v)) => v.to_string(),
                    _ => String::new(),
                }
            }
        };
        map.insert(name, value);
    }
    map
}

pub fn db_connect(_unit: ()) -> SkyTask<()> {
    let url = SKY_DB_URL.to_string();
    Box::pin(async move {
        match DbPool::connect(&url).await {
            Ok(pool) => ok_res(pool),
            Err(e) => SkyResult::Err(str_err(&format!("{}", e))),
        }
    })
}

pub fn db_open(_unit: ()) -> SkyTask<()> { db_connect(()) }

pub fn db_open_with_path(path: String) -> SkyTask<()> {
    Box::pin(async move { match DbPool::connect(&path).await {
        Ok(pool) => ok_res(pool),
        Err(e) => SkyResult::Err(str_err(&format!("{}", e))),
    } })
}

pub fn db_exec_raw(conn: Db, sql: String) -> SkyTask<()> {
    Box::pin(async move {
        match sqlx::query(&sql).execute(&conn).await {
            Ok(_) => ok_res(()),
            Err(e) => SkyResult::Err(str_err(&format!("{}", e))),
        }
    })
}

pub fn db_exec(conn: Db, sql: String, params: Vec<String>) -> SkyTask<()> {
    Box::pin(async move {
        let final_sql = build_sql(&sql, &params);
        match sqlx::query(&final_sql).execute(&conn).await {
            Ok(_) => ok_res(()),
            Err(e) => SkyResult::Err(str_err(&format!("{}", e))),
        }
    })
}

pub fn db_query(conn: Db, sql: String, params: Vec<String>) -> SkyTask<Vec<HashMap<String, String>>> {
    Box::pin(async move {
        let final_sql = build_sql(&sql, &params);
        match sqlx::query(&final_sql).fetch_all(&conn).await {
            Ok(rows) => {
                let result: Vec<HashMap<String, String>> = rows.iter().map(|r| row_to_map(r)).collect();
                ok_res(result)
            }
            Err(e) => SkyResult::Err(str_err(&format!("{}", e))),
        }
    })
}

pub fn db_get_field(field: String, row: HashMap<String, String>) -> String {
    row.get(&field).cloned().unwrap_or_default()
}

pub fn db_get_field_or_null(field: String, row: HashMap<String, String>) -> SkyMaybe<String> {
    match row.get(&field) { Some(v) => SkyMaybe::Just(v.clone()), None => SkyMaybe::Nothing }
}
