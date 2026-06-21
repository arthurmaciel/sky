//! Sky.Core.Http — outbound HTTP client (reqwest under a Sky-native surface).
//!
//! HttpResponse/HttpRequest map to the Sky record aliases via runtimeOpaqueTypes
//! (like Csv's CsvDoc), so `resp.status` / `.body` / `.headers` resolve onto
//! these pub fields and the Sky-built `defaultRequest` record constructs this
//! struct directly. Field names match the Sky records verbatim (camelCase
//! `followRedirects` / `maxRedirects` — hence the non_snake_case allow).
//!
//! ## SSRF protection (opt-in)
//!
//! Set `SKY_HTTP_DENY_PRIVATE=1` (or `on` / `true`) to block requests whose
//! resolved host is loopback, RFC-1918 private, link-local, unique-local (ULA),
//! unspecified, or v4-mapped-private. This guard is OFF by default so that
//! development against `localhost` keeps working unchanged.
//!
//! When ON the check runs in three layers:
//! 1. **Pre-send resolve + pin (DNS-rebinding defence)**: parse the URL;
//!    DNS-resolve the host; reject if any resolved IP is private; then
//!    **pin** the client to the first vetted non-private `SocketAddr` via
//!    `ClientBuilder::resolve_to_addrs(host, &[vetted_addr])`.  This closes
//!    the TOCTOU window: reqwest connects to the exact IP that passed the
//!    check — a rebind returning a private address at connect time cannot
//!    bypass the guard.
//! 2. **Each redirect (URL-level re-check)**: a custom
//!    `reqwest::redirect::Policy` repeats the scheme + private-IP check on
//!    every `Location` target before following it, preventing open-redirect
//!    chains that bypass the pre-send check.
//!
//! ### Redirect-pin limitation
//! Full per-redirect IP pinning (resolving + pinning the *new* host on each
//! hop) is not expressible with reqwest's current `redirect::Policy` API: the
//! callback receives only the redirect URL, not a `ClientBuilder`, so we
//! cannot rebuild and re-pin the client mid-chain.  The URL-level re-check
//! (layer 2) is therefore the floor for redirect hops: it catches IP literals
//! and known-private hostnames but cannot prevent a mid-chain rebind on a
//! freshly registered hostname.  In practice redirect chains to attacker-
//! controlled domains are blocked by the scheme + private-IP URL check; a
//! full per-hop pin would require a reqwest API extension or a custom
//! `hyper` connector.

use super::*;
use std::collections::HashMap;
use std::net::SocketAddr;
// SSRF deny-private helpers live in the reqwest-free `ssrf` module (so the
// WebSocket client can validate URLs without linking reqwest). The reqwest-
// coupled `ssrf_apply` + the request executor below import the three they use.
use crate::sky_runtime::ssrf::{ssrf_check_url, ssrf_deny_private_enabled, resolve_first_non_private_addr};

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

// ---------------------------------------------------------------------------
// SSRF guard — reqwest client integration
// ---------------------------------------------------------------------------
// The reqwest-free validators (ssrf_check_url / resolve_first_non_private_addr /
// is_private_ip / ssrf_validate_url / ssrf_pinned_ws_addr / …) live in `ssrf.rs`.
// What remains here is reqwest-coupled: `ssrf_apply` (a reqwest::ClientBuilder)
// and the request executor.

/// Apply the SSRF deny-private guard to a `reqwest::ClientBuilder` for `url`.
/// When `SKY_HTTP_DENY_PRIVATE` is set, validates the URL scheme + host, resolves
/// to a vetted non-private `SocketAddr`, pins DNS to it (defeats DNS-rebinding),
/// and installs a per-redirect-hop re-check. SHARED by every outbound request
/// surface — the regular Http client, `Http.Stream.open`, the WebSocket client,
/// the Email SES path — so the guard can NEVER be missing from a request path
/// (the bug class this closes: a new path that built its own client without the
/// check). When the guard is off, installs the caller's plain redirect policy.
pub(crate) fn ssrf_apply(
    mut builder: reqwest::ClientBuilder,
    url: &str,
    follow_redirects: bool,
    max_redirects: i64,
) -> Result<reqwest::ClientBuilder, String> {
    let deny = ssrf_deny_private_enabled();
    if deny {
        let parsed = reqwest::Url::parse(url).map_err(|e| {
            format!("http: blocked: invalid URL {:?}: {} (SKY_HTTP_DENY_PRIVATE)", url, e)
        })?;
        let scheme = parsed.scheme();
        if scheme != "http" && scheme != "https" && scheme != "ws" && scheme != "wss" {
            return Err(format!(
                "http: blocked: scheme {:?} is not http/https/ws/wss (SKY_HTTP_DENY_PRIVATE)",
                scheme
            ));
        }
        let host = parsed
            .host_str()
            .ok_or_else(|| "http: blocked: URL has no host (SKY_HTTP_DENY_PRIVATE)".to_string())?
            .to_owned();
        let addr = resolve_first_non_private_addr(&host)?;
        builder = builder.resolve_to_addrs(host.as_str(), &[addr]);
    }
    builder = if follow_redirects {
        if deny {
            let max = max_redirects.max(0) as usize;
            builder.redirect(reqwest::redirect::Policy::custom(move |attempt| {
                if attempt.previous().len() >= max {
                    return attempt.error(format!("http: too many redirects (max {})", max));
                }
                if let Err(msg) = ssrf_check_url(attempt.url().as_str()) {
                    return attempt.error(msg);
                }
                attempt.follow()
            }))
        } else {
            builder.redirect(reqwest::redirect::Policy::limited(max_redirects.max(0) as usize))
        }
    } else {
        builder.redirect(reqwest::redirect::Policy::none())
    };
    Ok(builder)
}

// ---------------------------------------------------------------------------
// Core request executor
// ---------------------------------------------------------------------------

async fn do_request<E: From<String> + Send + 'static>(req: HttpRequest) -> SkyResult<E, HttpResponse> {
    let deny_private = ssrf_deny_private_enabled();

    // Pre-send SSRF check + DNS-rebinding pin (when guard is enabled).
    //
    // We resolve the host once here, verify it is non-private, and then
    // instruct reqwest to connect to that exact `SocketAddr` via
    // `resolve_to_addrs`.  Because reqwest's DNS override is applied at
    // client-build time and wins over any subsequent OS-level DNS lookup,
    // a rebind that returns a private address at TCP-connect time has no
    // effect — the connection goes to the vetted IP regardless.
    let pinned_host_addr: Option<(String, SocketAddr)> = if deny_private {
        // Validate URL structure and scheme first.
        let parsed = match reqwest::Url::parse(&req.url) {
            Ok(u) => u,
            Err(e) => {
                return SkyResult::Err(
                    format!(
                        "http: blocked: invalid URL {:?}: {} (SKY_HTTP_DENY_PRIVATE)",
                        req.url, e
                    )
                    .into(),
                );
            }
        };
        let scheme = parsed.scheme();
        if scheme != "http" && scheme != "https" {
            return SkyResult::Err(
                format!(
                    "http: blocked: scheme {:?} is not http/https (SKY_HTTP_DENY_PRIVATE)",
                    scheme
                )
                .into(),
            );
        }
        let host = match parsed.host_str() {
            Some(h) => h.to_owned(),
            None => {
                return SkyResult::Err(
                    "http: blocked: URL has no host (SKY_HTTP_DENY_PRIVATE)".to_string().into(),
                );
            }
        };
        // Resolve + validate; get back the vetted SocketAddr for pinning.
        match resolve_first_non_private_addr(&host) {
            Ok(addr) => Some((host, addr)),
            Err(msg) => return SkyResult::Err(msg.into()),
        }
    } else {
        None
    };

    let mut builder = reqwest::Client::builder();

    // Pin DNS to the vetted address so reqwest cannot re-resolve to a
    // different (potentially private) IP at connect time.
    if let Some((ref host, vetted_addr)) = pinned_host_addr {
        builder = builder.resolve_to_addrs(host.as_str(), &[vetted_addr]);
    }

    builder = if req.followRedirects {
        if deny_private {
            // Redirect policy that re-applies the SSRF check on every hop.
            let max = req.maxRedirects.max(0) as usize;
            builder.redirect(reqwest::redirect::Policy::custom(move |attempt| {
                if attempt.previous().len() >= max {
                    return attempt.error(format!(
                        "http: too many redirects (max {})",
                        max
                    ));
                }
                // Check the redirect target URL.
                let next_url = attempt.url().as_str();
                if let Err(msg) = ssrf_check_url(next_url) {
                    return attempt.error(msg);
                }
                attempt.follow()
            }))
        } else {
            builder.redirect(reqwest::redirect::Policy::limited(req.maxRedirects.max(0) as usize))
        }
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
    let body = match read_body_capped::<E>(resp).await {
        SkyResult::Ok(b) => b,
        SkyResult::Err(e) => return SkyResult::Err(e),
    };
    ok_res(HttpResponse { status, body, headers })
}

/// Default cap on a buffered HTTP response body (`Http.get`/`post`/`request`):
/// 100 MiB. `Http.*` returns the body as a single `String`, so an unbounded
/// read of an attacker- or upstream-controlled response is a memory-exhaustion
/// (OOM) vector. Override via `SKY_HTTP_MAX_BODY_BYTES` (streaming consumers that
/// need unbounded bodies use `Sky.Core.Http.Stream` instead).
const HTTP_BODY_CAP_DEFAULT: usize = 100 * 1024 * 1024;

fn http_body_cap() -> usize {
    std::env::var("SKY_HTTP_MAX_BODY_BYTES")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .filter(|&n| n > 0)
        .unwrap_or(HTTP_BODY_CAP_DEFAULT)
}

/// Read a response body into a `String` with a hard byte cap. The
/// `Content-Length` pre-check only fast-fails the declared-length case — note
/// reqwest's `gzip` feature transparently decompresses and STRIPS
/// `Content-Length`, so for a gzip'd (e.g. compression-bomb) response
/// `content_length()` is `None` and this pre-check is skipped. The load-bearing
/// guard is the INCREMENTAL cap in the stream loop below, which bounds the
/// decompressed body to `cap` regardless of encoding or a lying/chunked length —
/// a bomb is capped at `cap` resident bytes, never unbounded. UTF-8 lossy
/// (matches `Http.Stream`'s chunk decode; Go reads bytes→string too).
async fn read_body_capped<E: From<String> + Send + 'static>(
    resp: reqwest::Response,
) -> SkyResult<E, String> {
    use futures_util::StreamExt;
    let cap = http_body_cap();
    if let Some(len) = resp.content_length() {
        if len as usize > cap {
            return SkyResult::Err(
                format!(
                    "http: response body too large ({} > {} bytes; raise SKY_HTTP_MAX_BODY_BYTES or use Http.Stream)",
                    len, cap
                )
                .into(),
            );
        }
    }
    let mut buf: Vec<u8> = Vec::new();
    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let bytes = match chunk {
            Ok(b) => b,
            Err(e) => return SkyResult::Err(format!("http: reading body failed: {}", e).into()),
        };
        if buf.len().saturating_add(bytes.len()) > cap {
            return SkyResult::Err(
                format!(
                    "http: response body too large (> {} bytes; raise SKY_HTTP_MAX_BODY_BYTES or use Http.Stream)",
                    cap
                )
                .into(),
            );
        }
        buf.extend_from_slice(&bytes);
    }
    SkyResult::Ok(String::from_utf8_lossy(&buf).into_owned())
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
    let mut out = HashMap::new();
    for pair in raw.trim_start_matches('?').split('&') {
        if pair.is_empty() { continue; }
        let mut it = pair.splitn(2, '=');
        let k = form_url_decode(it.next().unwrap_or(""));
        let v = form_url_decode(it.next().unwrap_or(""));
        out.entry(k).or_insert(v); // repeated keys keep the first value
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_query_decode_and_first_wins() {
        let q = http_parse_query("a=1&b=two%20words&a=ignored&c".to_string());
        assert_eq!(q.get("a").map(String::as_str), Some("1")); // first value wins
        assert_eq!(q.get("b").map(String::as_str), Some("two words"));
        assert_eq!(q.get("c").map(String::as_str), Some(""));
        // Leading '?' tolerated; empty pairs skipped.
        let q2 = http_parse_query("?x=9&".to_string());
        assert_eq!(q2.get("x").map(String::as_str), Some("9"));
        assert_eq!(q2.len(), 1);
    }
    // SSRF guard unit tests moved to `ssrf.rs` alongside the validators.
}
