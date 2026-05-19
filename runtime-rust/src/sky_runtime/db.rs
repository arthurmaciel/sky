// DB kernel functions — generic over E.
// Uses DbPool, DbRow, SKY_DB_URL from config.rs (generated at build time).
use super::*;
use sqlx::{Column, Row};
use std::collections::HashMap;

pub type Db = DbPool;

fn sky_err<E: From<String> + Send>(e: &sqlx::Error) -> E {
    str_err(&format!("{}", e))
}

fn build_sql(sql: &str, params: &[String]) -> String {
    let mut result = String::new();
    let mut remaining = sql;
    for p in params {
        if let Some(pos) = remaining.find('?') {
            result.push_str(&remaining[..pos]);
            result.push('\'');
            result.push_str(&p.replace('\'', "''"));
            result.push('\'');
            remaining = &remaining[pos + 1..];
        }
    }
    result.push_str(remaining);
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

pub fn db_connect<E: Send + From<String> + 'static>(_unit: ()) -> SkyTask<E, Db> {
    let url = SKY_DB_URL.to_string();
    Box::pin(async move {
        match DbPool::connect(&url).await {
            Ok(pool) => ok_res(pool),
            Err(e) => SkyResult::Err(sky_err(&e)),
        }
    })
}

pub fn db_open<E: Send + From<String> + 'static>(_unit: ()) -> SkyTask<E, Db> { db_connect(_unit) }

pub fn db_open_with_path<E: Send + From<String> + 'static>(path: String) -> SkyTask<E, Db> {
    Box::pin(async move { match DbPool::connect(&path).await {
        Ok(pool) => ok_res(pool),
        Err(e) => SkyResult::Err(sky_err(&e)),
    } })
}

pub fn db_exec_raw<E: Send + From<String> + 'static>(conn: Db, sql: String) -> SkyTask<E, ()> {
    Box::pin(async move {
        match sqlx::query(&sql).execute(&conn).await {
            Ok(_) => ok_res(()),
            Err(e) => SkyResult::Err(sky_err(&e)),
        }
    })
}

pub fn db_exec<E: Send + From<String> + 'static>(conn: Db, sql: String, params: Vec<String>) -> SkyTask<E, ()> {
    Box::pin(async move {
        let final_sql = build_sql(&sql, &params);
        match sqlx::query(&final_sql).execute(&conn).await {
            Ok(_) => ok_res(()),
            Err(e) => SkyResult::Err(sky_err(&e)),
        }
    })
}

pub fn db_query<E: Send + From<String> + 'static>(conn: Db, sql: String, params: Vec<String>) -> SkyTask<E, Vec<HashMap<String, String>>> {
    Box::pin(async move {
        let final_sql = build_sql(&sql, &params);
        match sqlx::query(&final_sql).fetch_all(&conn).await {
            Ok(rows) => {
                let result: Vec<HashMap<String, String>> = rows.iter().map(|r| row_to_map(r)).collect();
                ok_res(result)
            },
            Err(e) => SkyResult::Err(sky_err(&e)),
        }
    })
}

pub fn db_get_field(field: String, row: HashMap<String, String>) -> String {
    row.get(&field).cloned().unwrap_or_default()
}

pub fn db_get_field_or_null(field: String, row: HashMap<String, String>) -> SkyMaybe<String> {
    match row.get(&field) { Some(v) => SkyMaybe::Just(v.clone()), None => SkyMaybe::Nothing }
}
