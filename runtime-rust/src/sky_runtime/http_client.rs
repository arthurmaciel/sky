//! Sky.Core.Http — outbound HTTP client (reqwest under a Sky-native surface).
//!
//! HttpResponse/HttpRequest map to the Sky record aliases via runtimeOpaqueTypes
//! (like Csv's CsvDoc), so `resp.status` / `.body` / `.headers` resolve onto
//! these pub fields and the Sky-built `defaultRequest` record constructs this
//! struct directly. Field names match the Sky records verbatim (camelCase
//! `followRedirects` / `maxRedirects` — hence the non_snake_case allow).

use super::*;
use std::collections::HashMap;

/// Sky.Core.Http.HttpResponse — field names/types match the Sky record alias.
#[derive(Clone, Debug)]
pub struct HttpResponse {
    pub status: i64,
    pub body: String,
    pub headers: HashMap<String, String>,
}

/// Sky.Core.Http.HttpRequest — built in Sky (defaultRequest + with* updates),
/// so every field is pub for external struct-literal construction.
#[allow(non_snake_case)]
#[derive(Clone, Debug)]
pub struct HttpRequest {
    pub method: String,
    pub url: String,
    pub body: String,
    pub headers: Vec<(String, String)>,
    pub timeout: i64,
    pub followRedirects: bool,
    pub maxRedirects: i64,
}

async fn do_request<E: From<String> + Send + 'static>(req: HttpRequest) -> SkyResult<E, HttpResponse> {
    let mut builder = reqwest::Client::builder();
    builder = if req.followRedirects {
        builder.redirect(reqwest::redirect::Policy::limited(req.maxRedirects.max(0) as usize))
    } else {
        builder.redirect(reqwest::redirect::Policy::none())
    };
    if req.timeout > 0 {
        builder = builder.timeout(std::time::Duration::from_millis(req.timeout as u64));
    }
    let client = match builder.build() {
        Ok(c) => c,
        Err(e) => return SkyResult::Err(format!("http: client build failed: {}", e).into()),
    };
    let method = reqwest::Method::from_bytes(req.method.to_uppercase().as_bytes())
        .unwrap_or(reqwest::Method::GET);
    let mut rb = client.request(method, &req.url);
    for (k, v) in &req.headers {
        rb = rb.header(k.as_str(), v.as_str());
    }
    if !req.body.is_empty() {
        rb = rb.body(req.body.clone());
    }
    let resp = match rb.send().await {
        Ok(r) => r,
        Err(e) => return SkyResult::Err(format!("http: request to {} failed: {}", req.url, e).into()),
    };
    let status = resp.status().as_u16() as i64;
    let mut headers = HashMap::new();
    for (k, v) in resp.headers() {
        if let Ok(s) = v.to_str() {
            headers.insert(k.as_str().to_string(), s.to_string());
        }
    }
    let body = match resp.text().await {
        Ok(b) => b,
        Err(e) => return SkyResult::Err(format!("http: reading body failed: {}", e).into()),
    };
    ok_res(HttpResponse { status, body, headers })
}

/// Http.get : String -> Task Error HttpResponse
pub fn http_get<E: From<String> + Send + 'static>(url: String) -> SkyTask<E, HttpResponse> {
    Box::pin(do_request(HttpRequest {
        method: "GET".to_string(), url, body: String::new(), headers: Vec::new(),
        timeout: 30000, followRedirects: true, maxRedirects: 10,
    }))
}

/// Http.post : String -> String -> Task Error HttpResponse
pub fn http_post<E: From<String> + Send + 'static>(url: String, body: String) -> SkyTask<E, HttpResponse> {
    Box::pin(do_request(HttpRequest {
        method: "POST".to_string(), url, body, headers: Vec::new(),
        timeout: 30000, followRedirects: true, maxRedirects: 10,
    }))
}

/// Http.request : HttpRequest -> Task Error HttpResponse
pub fn http_request<E: From<String> + Send + 'static>(req: HttpRequest) -> SkyTask<E, HttpResponse> {
    Box::pin(do_request(req))
}

/// Http.parseQuery : String -> Dict String String (pure; first value wins).
pub fn http_parse_query(raw: String) -> HashMap<String, String> {
    fn dec(s: &str) -> String {
        let s = s.replace('+', " ");
        let b = s.as_bytes();
        let mut out = Vec::new();
        let mut i = 0;
        while i < b.len() {
            if b[i] == b'%' && i + 2 < b.len() {
                if let Ok(byte) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                    out.push(byte); i += 3; continue;
                }
            }
            out.push(b[i]); i += 1;
        }
        String::from_utf8_lossy(&out).into_owned()
    }
    let mut out = HashMap::new();
    for pair in raw.trim_start_matches('?').split('&') {
        if pair.is_empty() { continue; }
        let mut it = pair.splitn(2, '=');
        let k = dec(it.next().unwrap_or(""));
        let v = dec(it.next().unwrap_or(""));
        out.entry(k).or_insert(v); // repeated keys keep the first value
    }
    out
}
