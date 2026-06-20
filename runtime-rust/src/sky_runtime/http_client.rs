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
use std::net::{IpAddr, SocketAddr, ToSocketAddrs};

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
// SSRF guard helpers
// ---------------------------------------------------------------------------

/// Returns `true` when `SKY_HTTP_DENY_PRIVATE` is set to a truthy value
/// (`1`, `on`, `true`, case-insensitive).
fn ssrf_deny_private_enabled() -> bool {
    match std::env::var("SKY_HTTP_DENY_PRIVATE") {
        Ok(v) => matches!(v.to_ascii_lowercase().trim(), "1" | "on" | "true"),
        Err(_) => false,
    }
}

/// Returns `true` when the address belongs to a range that must be blocked
/// under `SKY_HTTP_DENY_PRIVATE`:
///
/// - loopback        (127.0.0.0/8, ::1)
/// - RFC-1918        (10/8, 172.16/12, 192.168/16)
/// - link-local      (169.254/16, fe80::/10)
/// - unique-local    (fc00::/7 — fc00:: and fd00::)
/// - unspecified     (0.0.0.0, ::)
/// - v4-mapped IPv6  (::ffff:0:0/96) whose embedded v4 is in the above ranges
fn is_private_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            v4.is_loopback()
                || v4.is_private()
                || v4.is_link_local()
                || v4.is_unspecified()
        }
        IpAddr::V6(v6) => {
            if v6.is_loopback() || v6.is_unspecified() {
                return true;
            }
            // Link-local: fe80::/10
            let seg = v6.segments();
            if (seg[0] & 0xffc0) == 0xfe80 {
                return true;
            }
            // Unique-local: fc00::/7 (covers fc00:: and fd00::)
            if (seg[0] & 0xfe00) == 0xfc00 {
                return true;
            }
            // v4-mapped: ::ffff:0:0/96
            if let Some(v4) = v6.to_ipv4_mapped() {
                return is_private_ip(IpAddr::V4(v4));
            }
            // v4-compatible (deprecated): ::a.b.c.d, e.g. ::10.0.0.1 still routes to
            // the embedded private IPv4 — to_ipv4() covers both compat + mapped.
            #[allow(deprecated)]
            if let Some(v4) = v6.to_ipv4() {
                return is_private_ip(IpAddr::V4(v4));
            }
            false
        }
    }
}

/// Resolves `host` (plain hostname or IP literal), checks that none of its
/// addresses is in a disallowed private range, and returns the first non-private
/// `SocketAddr` (port 0) so the caller can **pin** reqwest's DNS resolver to
/// that exact address via `ClientBuilder::resolve_to_addrs`.
///
/// This closes the TOCTOU / DNS-rebinding window: the IP that passed the check
/// is the IP reqwest connects to — a rebind happening between the check and the
/// TCP connect has no effect because reqwest's per-client DNS override wins.
///
/// Returns `Ok(SocketAddr)` if allowed (with the vetted address), or
/// `Err(message)` if blocked or if the host could not be resolved.
///
/// Uses port 0 for the `ToSocketAddrs` resolution; the port is not significant
/// for the DNS lookup but is required by the API.  Callers must override the
/// port in `resolve_to_addrs` if needed — reqwest's `resolve_to_addrs` only
/// overrides the host→IP mapping; it uses the URL's port for the actual
/// connection, so port 0 here is safe.
fn resolve_first_non_private_addr(host: &str) -> Result<SocketAddr, String> {
    // Try parsing as an IP literal first (avoids a DNS round-trip for bare IPs).
    if let Ok(ip) = host.parse::<IpAddr>() {
        if is_private_ip(ip) {
            return Err(format!(
                "http: blocked: private/loopback host {} (SKY_HTTP_DENY_PRIVATE)",
                ip
            ));
        }
        return Ok(SocketAddr::new(ip, 0));
    }

    // Hostname → DNS resolve via std (synchronous; called before the async send).
    let addr_iter = match (host, 0u16).to_socket_addrs() {
        Ok(it) => it,
        Err(e) => {
            return Err(format!(
                "http: blocked: could not resolve host {:?}: {} (SKY_HTTP_DENY_PRIVATE)",
                host, e
            ));
        }
    };

    let mut first_ok: Option<SocketAddr> = None;
    for sock_addr in addr_iter {
        let ip = sock_addr.ip();
        if is_private_ip(ip) {
            return Err(format!(
                "http: blocked: private/loopback host {:?} resolved to {} (SKY_HTTP_DENY_PRIVATE)",
                host, ip
            ));
        }
        if first_ok.is_none() {
            first_ok = Some(sock_addr);
        }
    }

    first_ok.ok_or_else(|| {
        format!(
            "http: blocked: host {:?} resolved to no addresses (SKY_HTTP_DENY_PRIVATE)",
            host
        )
    })
}

/// Validates a URL's host against the SSRF deny-private policy without
/// returning the resolved address.  Used in the redirect policy callback
/// where we only have a URL and cannot rebuild the client.
///
/// Returns `Ok(())` if allowed, `Err(message)` if blocked.
fn check_host_not_private(host: &str) -> Result<(), String> {
    resolve_first_non_private_addr(host).map(|_| ())
}

/// Validates a URL string under the SSRF deny-private policy.
/// Rejects non-http/https schemes and private-range hosts.
///
/// Returns `Ok(())` if the request is allowed, `Err(message)` if blocked.
fn ssrf_check_url(url: &str) -> Result<(), String> {
    let parsed = match reqwest::Url::parse(url) {
        Ok(u) => u,
        Err(e) => {
            return Err(format!(
                "http: blocked: invalid URL {:?}: {} (SKY_HTTP_DENY_PRIVATE)",
                url, e
            ));
        }
    };

    // Only http / https are permitted when the deny guard is on.
    let scheme = parsed.scheme();
    if scheme != "http" && scheme != "https" {
        return Err(format!(
            "http: blocked: scheme {:?} is not http/https (SKY_HTTP_DENY_PRIVATE)",
            scheme
        ));
    }

    // Extract and check the host.
    let host = match parsed.host_str() {
        Some(h) => h,
        None => {
            return Err(
                "http: blocked: URL has no host (SKY_HTTP_DENY_PRIVATE)".to_string()
            );
        }
    };

    check_host_not_private(host)
}

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

/// Validate a single URL against the deny-private guard (no client build) — for
/// surfaces (WebSocket) that connect outside reqwest. No-op when the guard is off.
pub(crate) fn ssrf_validate_url(url: &str) -> Result<(), String> {
    if ssrf_deny_private_enabled() {
        ssrf_check_url(url)
    } else {
        Ok(())
    }
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

/// Read a response body into a `String` with a hard byte cap. Fails fast on a
/// declared `Content-Length` over the cap, then enforces the cap incrementally
/// while streaming (a lying / chunked response can't bypass the limit). UTF-8
/// lossy (matches `Http.Stream`'s chunk decode; Go reads bytes→string too).
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

    // -----------------------------------------------------------------------
    // SSRF guard unit tests (no network — purely local logic)
    // -----------------------------------------------------------------------

    #[test]
    fn is_private_ip_loopback_v4() {
        assert!(is_private_ip("127.0.0.1".parse().unwrap()));
        assert!(is_private_ip("127.255.255.255".parse().unwrap()));
    }

    #[test]
    fn is_private_ip_rfc1918() {
        assert!(is_private_ip("10.0.0.1".parse().unwrap()));
        assert!(is_private_ip("172.16.0.1".parse().unwrap()));
        assert!(is_private_ip("172.31.255.255".parse().unwrap()));
        assert!(is_private_ip("192.168.1.1".parse().unwrap()));
    }

    #[test]
    fn is_private_ip_link_local_v4() {
        assert!(is_private_ip("169.254.0.1".parse().unwrap()));
        assert!(is_private_ip("169.254.169.254".parse().unwrap())); // AWS IMDS
    }

    #[test]
    fn is_private_ip_unspecified_v4() {
        assert!(is_private_ip("0.0.0.0".parse().unwrap()));
    }

    #[test]
    fn is_private_ip_loopback_v6() {
        assert!(is_private_ip("::1".parse().unwrap()));
    }

    #[test]
    fn is_private_ip_link_local_v6() {
        assert!(is_private_ip("fe80::1".parse().unwrap()));
        assert!(is_private_ip("fe80::dead:beef".parse().unwrap()));
    }

    #[test]
    fn is_private_ip_ula_v6() {
        assert!(is_private_ip("fc00::1".parse().unwrap()));
        assert!(is_private_ip("fd00::1".parse().unwrap()));
        assert!(is_private_ip("fdff:ffff:ffff::1".parse().unwrap()));
    }

    #[test]
    fn is_private_ip_v4mapped_private() {
        // ::ffff:192.168.1.1 — v4-mapped RFC-1918
        assert!(is_private_ip("::ffff:192.168.1.1".parse().unwrap()));
        // ::ffff:127.0.0.1 — v4-mapped loopback
        assert!(is_private_ip("::ffff:127.0.0.1".parse().unwrap()));
    }

    #[test]
    fn is_private_ip_public_is_allowed() {
        assert!(!is_private_ip("1.1.1.1".parse().unwrap()));
        assert!(!is_private_ip("8.8.8.8".parse().unwrap()));
        assert!(!is_private_ip("2606:4700:4700::1111".parse().unwrap())); // Cloudflare v6
    }

    #[test]
    fn ssrf_check_url_rejects_non_http_scheme() {
        let err = ssrf_check_url("ftp://example.com/file").unwrap_err();
        assert!(err.contains("scheme"), "expected scheme rejection, got: {err}");
        let err2 = ssrf_check_url("file:///etc/passwd").unwrap_err();
        assert!(err2.contains("scheme") || err2.contains("invalid"), "got: {err2}");
    }

    #[test]
    fn ssrf_check_url_rejects_private_ip_literal() {
        let err = ssrf_check_url("http://192.168.1.1/secret").unwrap_err();
        assert!(err.contains("blocked"), "expected blocked, got: {err}");
    }

    #[test]
    fn ssrf_check_url_rejects_loopback_ip_literal() {
        let err = ssrf_check_url("http://127.0.0.1:8080/admin").unwrap_err();
        assert!(err.contains("blocked"), "expected blocked, got: {err}");
    }

    #[test]
    fn ssrf_check_url_rejects_aws_imds() {
        let err = ssrf_check_url("http://169.254.169.254/latest/meta-data/").unwrap_err();
        assert!(err.contains("blocked"), "expected blocked, got: {err}");
    }

    #[test]
    fn ssrf_check_url_rejects_invalid_url() {
        let err = ssrf_check_url("not a url at all").unwrap_err();
        assert!(!err.is_empty());
    }

    #[test]
    fn ssrf_check_url_allows_public_ip() {
        // 1.1.1.1 is public — should pass (no DNS needed for IP literals)
        assert!(ssrf_check_url("https://1.1.1.1/").is_ok());
    }

    // -----------------------------------------------------------------------
    // resolve_first_non_private_addr — pin-address path
    // -----------------------------------------------------------------------

    #[test]
    fn resolve_non_private_returns_socket_addr_for_public_ip_literal() {
        let sa = resolve_first_non_private_addr("1.1.1.1").unwrap();
        assert_eq!(sa.ip(), "1.1.1.1".parse::<IpAddr>().unwrap());
        // Port is 0 — reqwest uses the URL's port; we just need the IP.
        assert_eq!(sa.port(), 0);
    }

    #[test]
    fn resolve_non_private_rejects_private_ip_literal() {
        let err = resolve_first_non_private_addr("192.168.1.1").unwrap_err();
        assert!(err.contains("blocked"), "expected blocked, got: {err}");
    }

    #[test]
    fn resolve_non_private_rejects_loopback_ip_literal() {
        let err = resolve_first_non_private_addr("127.0.0.1").unwrap_err();
        assert!(err.contains("blocked"), "expected blocked, got: {err}");
    }

    #[test]
    fn resolve_non_private_rejects_v4mapped_loopback() {
        let err = resolve_first_non_private_addr("::ffff:127.0.0.1").unwrap_err();
        assert!(err.contains("blocked"), "expected blocked, got: {err}");
    }
}
