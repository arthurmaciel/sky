# SKY_CONSOLE_AUTH=token (token mode) — Rust backend port

**Goal:** Port `SKY_CONSOLE_AUTH=token` to the Rust Sky.Live runtime — an
HKDF-signed `__Host-sky_console` session cookie + a browser login form that
checks `SKY_CONSOLE_TOKEN` — so the dev console is reachable from a browser in
production, not Bearer-header-only.

**Scope:** Token mode ONLY. App mode (`SKY_CONSOLE_AUTH=app`, the row-poly
`consoleAuth` callback) stays fail-closed at its current 501 — it is
codegen-coupled (Go invokes the callback via reflection, which the Rust backend
forbids) and tracked as a separate follow-up. The `SKY_CONSOLE_EMBED_ORIGIN`
URL/JWT handshake (`SameSite=None` iframe embedding) is also out of scope.

**Architecture:** A new pure, live-gated runtime module
`runtime-rust/src/sky_runtime/live/console_auth.rs` holds the cookie crypto +
login handler + login page. The existing per-request gate (`console::gate_blocked`,
invoked from the outermost `observability::track` layer) gains a `token` branch
delegating to it. A new `POST /_sky/console/_login` route mints the cookie.

**Tech:** `hmac` 0.12 + `sha2` + `subtle` + `base64` (all existing deps). HKDF is
hand-rolled as two HMAC-SHA256 calls (no new crate — `console_auth` is
live-gated, and adding a crate to a gated module risks the
"compiles-under-`--features full`-but-fails-feature-minimal" pitfall). No
reflection, no `dyn Any`, no codegen change, no cabal rebuild.

---

## Principle posture (security first)

Token mode is the slice that **cannot violate a higher principle**: pure-runtime
and total (no soundness risk), no codegen ("type-checks ⇒ builds" holds with no
new surface), smallest attack surface, reusing primitives already audited in
this codebase (`subtle` ct-compare, `__Host-` cookie discipline from `csrf.rs`).
It does not *open* anything — production is already Bearer-gated today; this adds
a browser-usable login alternative and leaves app mode's secure fail-closed 501
intact.

## Non-goals

- App mode (`consoleAuth` callback) — separate codegen-coupled phase.
- Embed handshake (`SKY_CONSOLE_EMBED_ORIGIN`, `?token=<JWT>`, `SameSite=None`).
- Dev-open auto-token (`.sky/console-token`) — current Rust dev behaviour (open
  console in dev) is unchanged; this spec only implements the explicit `token`
  mode.
- Cross-backend cookie interop — the cookie is minted + verified by the same
  process; byte-identical-to-Go derivation is mirrored for quality, not required.

## Components — `runtime-rust/src/sky_runtime/live/console_auth.rs`

All functions total (no panic / unwrap on reachable input); locks via
`into_inner()`.

| Fn | Signature | Behaviour |
|---|---|---|
| `derive_signing_key` | `() -> &'static [u8;32]` | HKDF-SHA256(secret=`SKY_CONSOLE_TOKEN`, salt=build-commit (else exe path), info=`b"sky-console-cookie"`). PRK = HMAC(salt, secret); OKM = HMAC(PRK, info ‖ 0x01)[..32]. Cached in a `OnceLock`. |
| `sign_cookie` | `(key, subject: &str, ttl: Duration) -> String` | `b64url(subject) ‖ "." ‖ expUnix ‖ "." ‖ b64url(HMAC(key, "b64url(subject).expUnix"))`. |
| `verify_cookie` | `(key, value: &str) -> Option<String>` | split into 3; recompute HMAC over `subjectB64.exp`; `ct_eq` vs supplied sig; reject if `now >= exp`; decode subject. `None` on any failure. |
| `set_cookie_header` | `(subject: &str) -> String` | `__Host-sky_console=<signed>; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=14400`. |
| `login_page_html` | `() -> String` | Plain HTML, no JS, inline CSS, `<form method=POST action="/_sky/console/_login">` with a `token` password field (`autocomplete="off"`) + optional hidden `redirect`. |
| `handle_login` | `(headers, body: String) -> Response` | Parse `application/x-www-form-urlencoded`; `ct_eq(form.token, SKY_CONSOLE_TOKEN)`. Match → `set_cookie_header("token-auth")` + 303 to validated `redirect`. Mismatch/empty → 401 + `login_page_html`. Parse failure → 400. Audit `console.auth.{allowed,denied}`. |
| `token_gate` | `(headers, path: &str) -> Option<Response>` | `SKY_CONSOLE_TOKEN` empty → `Some(503)`. Valid cookie → `None`. `path == "/_sky/console/_login"` → `None` (let the route handle it). Else → `Some(401 + login_page_html)` (`Cache-Control: no-store`). |

Constants (Go-parity): cookie name `__Host-sky_console`; TTL `14400s` (4h);
subject for token auth `"token-auth"`.

## Gate dispatch — `console::gate_blocked`

Current signature `gate_blocked(headers) -> Option<Response>` becomes
`gate_blocked(headers, path: &str) -> Option<Response>`. There are **two**
callers, both holding the full request:
- `observability::track` (`observability.rs:88`) → passes `req.uri().path()`.
- `console_proxy::proxy_entry` (`console_proxy.rs:351`, the defense-in-depth
  gate) → passes `req.uri().path()`.

Both must be updated in the same change or the build breaks (the proxy caller is
easy to miss).

Branch order (unchanged except the new `token` arm):
1. `SKY_CONSOLE_AUTH=off` → `Some(404)`.
2. `=app` → `Some(501)` (unchanged — fail-closed).
3. `=token` → `console_auth::token_gate(headers, path)`.
4. dev (not production) → `None` (open, unchanged).
5. production + Bearer admin token path → unchanged (`SKY_ADMIN_TOKEN` /
   legacy aliases, `ct_eq`).

Note: in `token` mode the Bearer path is not consulted — token mode is the
explicit choice. A `=token` binary with `SKY_CONSOLE_TOKEN` unset returns 503
(never falls through to open).

## Route wiring — `live/mod.rs`

- Register `POST /_sky/console/_login` → an axum handler reading the `String`
  body → `console_auth::handle_login(headers, body)`. Mounted on the same router
  wrapped by `observability::track` + `csrf_middleware`.
- `track`'s gate (above) returns `None` for the `_login` path so the request
  reaches this handler; the handler does the real `ct_eq` check.
- Add `/_sky/console/_login` to `csrf::is_exempt_path` — it is a pre-session
  bootstrap POST (no `__sky_csrf` cookie exists yet); it is protected by the
  `ct_eq` token check + the `__Host-`+Secure response cookie, not double-submit.

## Security details

- **Constant-time** everywhere a secret is compared: the form token vs
  `SKY_CONSOLE_TOKEN`, and the cookie HMAC verify (`subtle::ct_eq`). Never `==`.
- `__Host-` prefix → browser enforces Secure + Path=/ + no Domain.
- HKDF salt = build-commit → signing key rotates each build → old cookies
  auto-invalidate across deploys.
- `redirect` form field MUST start with `/_sky/console` else default to
  `/_sky/console` → no open-redirect.
- Login page emits no JS (CSP-safe), `autocomplete="off"`.
- Fail-closed: `SKY_CONSOLE_TOKEN` unset under `=token` → 503, never open.
- Audit denials/grants to the telemetry ring (`console.auth.*`) for
  brute-force/probe visibility (Go-parity).

## Error handling

Every path returns a typed `Response`; no panic reachable from request input.
Form parse error → 400. Missing/garbage cookie → treated as absent → login form.
`OnceLock` key derivation cannot fail (HKDF over SHA-256 with a non-empty secret;
the 503-on-empty-token guard runs first).

## Testing

**Unit (`console_auth.rs` `#[cfg(test)]`):**
- `sign_cookie` → `verify_cookie` round-trip returns the subject.
- Tampered subject / exp / signature → `verify_cookie` = `None`.
- Expired cookie (`ttl` in the past) → `None`.
- `derive_signing_key` deterministic for fixed env (set `SKY_CONSOLE_TOKEN`).
- `handle_login`: correct token → 303 + `Set-Cookie`; wrong token → 401; bad
  form → 400.
- `redirect` open-redirect blocked (`https://evil` / `/other` → defaults to
  `/_sky/console`).

**Gate (`console.rs` `#[cfg(test)]`):**
- `=token` + no cookie + non-`_login` path → `Some(401)`.
- `=token` + valid cookie → `None`.
- `=token` + `_login` path → `None`.
- `=token` + `SKY_CONSOLE_TOKEN` unset → `Some(503)`.
- `=off` → 404; `=app` → 501 (regression: unchanged).

**Verification gate (a fix is done only past these):**
- `cargo build/test --features full` green.
- A feature-minimal **live** example builds on `--backend rust` (e.g.
  `09-live-counter`) — confirms `console_auth` compiles in a generated live
  project (no new dep, but proves the gating).
- Manual smoke: `SKY_CONSOLE_AUTH=token SKY_CONSOLE_TOKEN=<32+ bytes>
  ENV=production` on a live example — `curl` no-cookie GET `/_sky/console` → 401 +
  form; POST `/_sky/console/_login` `token=<secret>` → 303 + `Set-Cookie`;
  replay with the cookie → 200.

## File-touch summary

- **Create:** `runtime-rust/src/sky_runtime/live/console_auth.rs`.
- **Modify:** `runtime-rust/src/sky_runtime/live/mod.rs` (declare
  `pub mod console_auth;`; mount the `_login` route; pass `path` to
  `gate_blocked`), `console.rs` (`token` branch + 2-arg signature),
  `observability.rs` (pass `path` to `gate_blocked`), `console_proxy.rs` (pass
  `path` to its defense-in-depth `gate_blocked` call), `csrf.rs`
  (`is_exempt_path` += `/_sky/console/_login`).
- **No change:** Go backend, shared stdlib, codegen, `Cargo.toml` (no new dep).
