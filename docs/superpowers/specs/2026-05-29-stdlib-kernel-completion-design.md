# Sky→Rust runtime: stdlib kernel completion (sub-project A) — Design

**Date:** 2026-05-29
**Status:** Approved (brainstorming) — ready for implementation plan
**Scope:** Rust-target only. Thin seam preserved.
**Branch:** `feat/runtime-rust`
**Builds on:** Alt-1 v1+v2 (commits up through `9de4bc0b`, all pushed to origin).

---

## 1. Context

The just-completed upstream sync (`v0.15.22 → v0.15.27`) made it possible to
honestly compare the two runtimes side by side:

| Runtime | Production LOC | Files |
|---|---|---|
| Sky→Go (`runtime-go/rt/`) | **35,190** | ~70 |
| Sky→Rust (`runtime-rust/src/sky_runtime/`) | **973** | 12 |

Disparity ~36×. The Rust runtime supports CLI/leaf apps (16 `examples/rust/` all
green, plus the few core Sky examples that target Rust), but is missing entire
subsystems the Go runtime ships: Sky.Live, Sky.Tui, Sky.Http.Server, Std.Ui,
Sky Console, Std.Trace/observability, full Std.Auth, Std.Decimal, Std.Money,
Std.PubSub, Sky.Core.Jwt, full Std.Time, full Crypto, Regex, Encoding,
Std.Markdown.

Closing this gap as one spec is impossible — the brainstorming flow decomposed
the work into six sub-projects ordered by prereq chain:

- **A — Stdlib kernel completion** *(this spec)*: Encoding, Regex, Crypto
  completion, Jwt, Std.Time advanced, Std.Decimal, Std.Markdown.
- B — Std.Db full CRUD + migrations.
- C — Std.Auth + Std.Money + Std.PubSub.
- D — Sky.Http.Server + middleware + sub-app + CSRF + cookies + static.
- E — Sky.Live (TEA + SSE + 4 session stores + topics + reconnect + URL routing).
- F — Sky.Tui + Std.Ui runtime + Sky Console + Std.Trace/observability.

Sub-project A is first because every later one requires a working stdlib
foundation: B needs the runtime patterns A establishes for fallible kernels;
C needs Crypto + Jwt; D needs Regex (for path matching); E/F need everything.
A also has the smallest blast radius and the cleanest verification (the existing
`examples/00-standard-libs` 120-assertion smoke test).

## 2. Goal

After A lands, **functional parity for the seven listed modules**: every Sky
stdlib `*.sky` test that passes on `target=go` passes on `target=rust`.

The headline gate: `examples/00-standard-libs` (120 assertions) builds and runs
on `target=rust` printing `120 assertions passed` — same output Go produces.

## 3. Non-goals (explicit — deferred to B–F)

- `Std.Db` full CRUD + migrations (B).
- `Std.Auth` full / `Std.Money` / `Std.PubSub` (C).
- `Sky.Http.Server` and middleware (D).
- `Sky.Live`, `Sky.Tui`, `Std.Ui` runtime, `Sky Console`, observability (E + F).
- Go-internal-test parity. Go-level test files (`runtime-go/rt/*_test.go`) are
  not re-implemented in Rust; we port the Sky-level test contracts instead.
- Cross-runtime perf parity. Functional behaviour matches; resource
  characteristics may differ.

## 4. Verified codebase state (grounding)

From reading the repo at HEAD `9de4bc0b`:

- **`Builder.hs` `kernelToRust`** — `src/Sky/Generate/Rust/Builder.hs:849`,
  `:1100`, `:1111`. The function maps a Sky-side kernel name
  (`"Encoding_base64Encode"`) to a Rust function path. New kernels are added by
  extending this dispatch.
- **Sky-side `.sky` files already expose the API.** `sky-stdlib/Sky/Core/Encoding.sky`
  declares `base64Encode : String -> String`, `base64Decode : String -> Result Error String`,
  `urlEncode`, `urlDecode`, `hexEncode`, `hexDecode` — all routed through
  `Ffi.kernel "Encoding_<fn>"`. The Sky source layer needs no changes; only
  the Rust runtime + `kernelToRust` dispatch.
- **Existing Rust kernel pattern** (`runtime-rust/src/sky_runtime/crypto.rs`):
  pure fns map directly (`crypto_sha256(s: String) -> String`); effectful fns
  return `SkyTask<E, T>` boxed-pinned; fallible fns return `SkyResult<E, T>`.
- **Existing Cargo deps** (`runtime-rust/Cargo.toml`): `sha2 = "0.10"`,
  `regex = "1"` already present (regex unused in runtime today; available).
- **Sky-level stdlib tests** present at HEAD:
  `tests/Core/CoreTest.sky`, `tests/Auth/AuthTest.sky`, `tests/Db/DbTest.sky`,
  `tests/Lang/PatternTest.sky`, `tests/Live/*.sky`, `tests/Server/HttpServerTest.sky`.
  `CoreTest.sky` is the consolidated stdlib semantics test.
- **Headline smoke target** (`examples/00-standard-libs/src/Main.sky`) imports
  `Sky.Core.Crypto`, `Sky.Core.Jwt`, `Sky.Core.Encoding`, the JSON modules, etc.
  When this builds and runs on `target=rust` with the same final output as Go,
  A is functionally complete.

## 5. Design — seven sub-modules

Each adds one Rust runtime file + one `kernelToRust` dispatch group. All
TargetRust-gated; the Go path is byte-identical.

### A.1 — Encoding (`Sky.Core.Encoding`)

**File:** `runtime-rust/src/sky_runtime/encoding.rs`
**New Cargo deps:** `base64 = "0.22"`, `hex = "0.4"`, `percent-encoding = "2"`.

| Sky kernel | Rust signature |
|---|---|
| `Encoding_base64Encode` | `pub fn base64_encode(s: String) -> String` (`base64::engine::general_purpose::STANDARD.encode`) |
| `Encoding_base64Decode` | `pub fn base64_decode<E: From<String>>(s: String) -> SkyResult<E, String>` |
| `Encoding_urlEncode` | `pub fn url_encode(s: String) -> String` (`percent_encoding::utf8_percent_encode` with `NON_ALPHANUMERIC`) |
| `Encoding_urlDecode` | `pub fn url_decode<E: From<String>>(s: String) -> SkyResult<E, String>` |
| `Encoding_hexEncode` | `pub fn hex_encode(s: String) -> String` |
| `Encoding_hexDecode` | `pub fn hex_decode<E: From<String>>(s: String) -> SkyResult<E, String>` |

Estimated 50 LOC + 6 unit tests + 1 Sky test (already exists or extended).

### A.2 — Regex (`Sky.Core.Regex`)

**File:** `runtime-rust/src/sky_runtime/regex_kernel.rs`
**New Cargo deps:** none (`regex = "1"` already in `Cargo.toml`).

| Sky kernel | Rust signature |
|---|---|
| `Regex_match` | `pub fn regex_match(pattern: String, s: String) -> bool` |
| `Regex_find` | `pub fn regex_find(pattern: String, s: String) -> SkyMaybe<String>` |
| `Regex_findAll` | `pub fn regex_find_all(pattern: String, s: String) -> Vec<String>` |
| `Regex_replace` | `pub fn regex_replace(pattern: String, replacement: String, s: String) -> String` |
| `Regex_split` | `pub fn regex_split(pattern: String, s: String) -> Vec<String>` |

Invalid regex returns `SkyMaybe::Nothing` / empty / unchanged — matches Go runtime semantics (which logs and returns identity rather than panicking). Compile failures are NEVER allowed to panic.

Estimated 100 LOC + 5 unit tests + Sky test in `tests/Core/CoreTest.sky` (existing assertions).

### A.3 — Crypto completion (`Sky.Core.Crypto`)

**File:** `runtime-rust/src/sky_runtime/crypto.rs` (extending the existing file).
**New Cargo deps:** `sha1 = "0.10"`, `md-5 = "0.10"`, `hmac = "0.12"`, `rsa = "0.9"` (with `pkcs1` + `sha2` features).

| Sky kernel | Rust signature | Notes |
|---|---|---|
| `Crypto_sha512` | `pub fn crypto_sha512(s: String) -> String` | hex-encoded digest |
| `Crypto_sha1` | `pub fn crypto_sha1(s: String) -> String` | hex-encoded |
| `Crypto_md5` | `pub fn crypto_md5(s: String) -> String` | hex-encoded |
| `Crypto_hmacSha256` | `pub fn crypto_hmac_sha256(key: String, s: String) -> String` | hex-encoded |
| `Crypto_hmacSha512` | `pub fn crypto_hmac_sha512(key: String, s: String) -> String` | hex-encoded |
| `Crypto_rsaSha256Sign` | `pub fn crypto_rsa_sha256_sign<E: From<String>>(key_pem: String, s: String) -> SkyResult<E, String>` | PKCS#1 v1.5 sig, hex-encoded |
| `Crypto_rsaSha256Verify` | `pub fn crypto_rsa_sha256_verify(key_pem: String, s: String, sig_hex: String) -> bool` | identical to Go semantics |
| `Crypto_constantTimeEqual` | `pub fn crypto_constant_time_equal(a: String, b: String) -> bool` | `subtle` crate or hand-rolled |

Estimated 150 LOC + 8 unit tests with vectors known good on Go.

### A.4 — Jwt (`Sky.Core.Jwt`)

**File:** `runtime-rust/src/sky_runtime/jwt.rs`
**New Cargo deps:** `jsonwebtoken = "9"` (handles HS256 + RS256 + claims; matches the Go impl's behaviour set).

| Sky kernel | Rust signature |
|---|---|
| `Jwt_encodeHs256` | `pub fn jwt_encode_hs256<E: From<String>>(secret: String, claims_json: String) -> SkyResult<E, String>` |
| `Jwt_encodeRs256` | `pub fn jwt_encode_rs256<E: From<String>>(key_pem: String, claims_json: String) -> SkyResult<E, String>` |
| `Jwt_decodeHs256` | `pub fn jwt_decode_hs256<E: From<String>>(secret: String, token: String) -> SkyResult<E, String>` (returns claims as JSON string) |
| `Jwt_decodeRs256` | `pub fn jwt_decode_rs256<E: From<String>>(key_pem: String, token: String) -> SkyResult<E, String>` |

`exp`/`nbf` validation, audience checks, issuer checks: identical to Go.
`claims` builder lives at the Sky stdlib level (already exists), so this layer
only needs encode/decode kernels.

Estimated 200 LOC + 6 unit tests with golden tokens from the Go test suite.

### A.5 — Std.Time advanced (`Std.Time`)

**File:** `runtime-rust/src/sky_runtime/time.rs` (extending the existing file).
**New Cargo deps:** `chrono-tz = "0.10"` (IANA zone DB), `chrono` already implicit.

Surface (32 entries — match Go's `time_zones.go` exactly):

- **IANA zones:** `Time_zoneFromName : String -> Maybe TimeZone`, plus
  conversions `Time_inZone : TimeZone -> Instant -> ZonedTime`.
- **Calendar math:** `addMonths`, `addYears` (month-end CLAMPED — same as Go).
- **Calendar parts:** `dayOfWeek` (ISO Mon=1..Sun=7), `weekOfYear` (ISO 8601),
  `dayOfYear`.
- **Truncation:** `startOfDay`, `startOfWeek`, `startOfMonth`, `startOfYear`.
- **Differences:** `diffDays`, `diffHours`, `diffMinutes`, `diffSeconds`.
- **Formatters:** `formatISO8601`, `formatRFC3339`, `formatHTTP`, plus custom
  pattern formatting passing through `chrono`'s `format` (semantics matching Go's
  patterns).

Estimated 400 LOC + 12 unit tests + Sky tests covering DST transitions, leap
years, month-end clamping.

### A.6 — Std.Decimal (`Std.Decimal`)

**File:** `runtime-rust/src/sky_runtime/decimal.rs`
**New Cargo deps:** `rust_decimal = "1"` (with `serde` feature for JSON
interop).

42 entries from `Std.Decimal` — full arithmetic (`add`, `sub`, `mul`, `div`,
`mod`), comparison, rounding (banker's by default), `percent` helpers (`percentOf`,
`addPercent`, `subPercent`), `allocate` (fair-split summing to total), parse
from string, format with N decimal places. Internal representation:
`rust_decimal::Decimal` (96-bit mantissa + scale; matches the precision of the
Go `shopspring/decimal` library Sky uses today).

Estimated 300 LOC + 14 unit tests + Sky tests with known monetary edge cases.

### A.7 — Std.Markdown (`Std.Markdown`)

**File:** `runtime-rust/src/sky_runtime/markdown.rs`
**New Cargo deps:** `pulldown-cmark = "0.12"`.

| Sky kernel | Rust signature |
|---|---|
| `Markdown_render` | `pub fn markdown_render(src: String) -> String` (returns Std.Ui `Element` as a JSON-encoded tree the Sky side decodes — matches Go's emit shape) |

The Element JSON shape matches Go's exactly; Std.Ui's renderer doesn't care
which runtime produced the tree.

Estimated 300 LOC + 6 unit tests (heading levels, paragraphs, lists, links,
code, inline emphasis).

## 6. Architecture (matches the established pattern)

- **One file per module** in `runtime-rust/src/sky_runtime/` (`encoding.rs`,
  `regex_kernel.rs`, `crypto.rs` (extend), `jwt.rs`, `time.rs` (extend),
  `decimal.rs`, `markdown.rs`). Each `pub use`-exported via `mod.rs`.
- **`kernelToRust` dispatch** in `src/Sky/Generate/Rust/Builder.hs` gains one
  arm per kernel. Pattern (per existing arms):
  ```haskell
  kernelToRust "Sky.Core.Encoding" "base64Encode" = Just ("sky_runtime", "base64_encode")
  ```
- **TargetRust-gated.** No code path under `TargetGo` is altered. The Go runtime
  is byte-identical post-this-spec.
- **Sky side unchanged.** The `.sky` files in `sky-stdlib/Sky/Core/` and
  `sky-stdlib/Std/` already declare the surface via `Ffi.kernel "<Name>"`.
- **Effect tier.** Per CLAUDE.md's Task-everywhere rule: pure helpers return
  bare values; fallible-pure helpers return `SkyResult`; nothing in A.1–A.7 is
  effectful enough to need `SkyTask` (no I/O — they're all
  pure computation over data passed in).

### Soundness gate / invariants

1. **No panics from well-typed Sky.** Invalid regex, malformed base64/hex,
   bad JWT signature, RSA key parse failure → `SkyResult::Err` with a clear
   message. Never `unwrap()` / `expect()` in kernel hot paths.
2. **Byte-identical Go behaviour where defined.** Where the Sky stdlib
   contract pins exact output (e.g. SHA-256 hex digest), Rust matches Go.
3. **Cross-backend rule 5 preserved.** Zero changes to `FfiGen.hs`,
   `Compile.hs`, `runtime-go/`, `src/Sky/Generate/Go/`, or
   `.skycache/ffi/*.kernel.json` at root.

## 7. Verification

1. **Per-kernel Rust unit tests** (`#[test]` in each kernel file): golden
   vectors that match the Go runtime's test output. Run via
   `cd runtime-rust && cargo test`.

2. **Per-module Sky-level tests:**
   `sky test --target rust tests/Core/CoreTest.sky` (which already exercises
   String, List, Dict, Maybe, Result, Math, Regex, Crypto, Jwt, Encoding,
   JSON, Time) must report the **same assertion count and identical pass/fail
   per assertion** as `target=go`.
   Same command on `tests/Auth/AuthTest.sky` and `tests/Db/DbTest.sky` is
   informational only (Auth full + Db full land in B/C).

3. **Headline gate — `examples/00-standard-libs`:**
   ```bash
   cd examples/00-standard-libs
   rm -rf sky-out .skycache
   echo 'target = "rust"' >> sky.toml
   ../../sky-out/sky run src/Main.sky
   ```
   Expected final line: `120 assertions passed` (same as Go).
   The example is the single best parity proof — it exercises every kernel
   A.1–A.7 transitively via the Sky stdlib.

4. **Cross-target regression:** the 16 `examples/rust/*` (FFI examples) and
   the existing core Sky→Rust examples (`01-hello-world`,
   `04-local-pkg`, `07-todo-cli`, `14-task-demo`) continue passing.

5. **Cross-backend safety check:** `cabal test --test-options='--match "FfiGen"
   --match "Toml" --match "Kernel"'` continues passing — 27 specs, zero
   failures. (Targeted because the full suite hangs in this environment.)

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| `jsonwebtoken` and Go's JWT differ in subtle ways (e.g. nbf grace period, audience array vs string) | Verify with golden tokens generated by Go; align if needed via small wrapper layer |
| `rust_decimal` precision differs from `shopspring/decimal` at extreme magnitudes | The Sky tests fix the contract; if a test fails, document the boundary as a Sky-level non-goal |
| `chrono-tz` zone database lags upstream IANA releases | Use a recent crate version; document the cutoff |
| `pulldown-cmark` and Go's markdown emitter produce different Element trees for the same input | Align via test vectors from Go's runtime; small adapter if needed |
| RSA dep weight (`rsa` crate pulls many deps) | Acceptable — RSA is part of the contract; alternative is `ring` (lighter but more opinionated API) |
| Tests reveal a Go-runtime behaviour we don't want to replicate (legacy quirks) | Per CLAUDE.md "Go is production / highest-priority backend" — match Go and document any divergence as a Rust-side non-goal |
| New kernels accidentally exposed on `TargetGo` path (cross-backend break) | All `kernelToRust` arms are inside `TargetRust ->` dispatch path; reviewed before commit |

## 9. Cross-backend safety

All changes live in:
- `runtime-rust/src/sky_runtime/` (new files + extensions; Rust-only).
- `runtime-rust/Cargo.toml` (new deps; Rust-only).
- `src/Sky/Generate/Rust/Builder.hs` (Rust-only post-thin-seam).

Untouched: `src/Sky/Build/FfiGen.hs`, `src/Sky/Build/Compile.hs`,
`src/Sky/Build/Rust/Ffi.hs`, `runtime-go/`, `src/Sky/Generate/Go/`,
`app/Main.hs`, the Sky-side `.sky` source for any module. Go backend
byte-identical; Rust FFI layer (v1+v2 inspector) untouched.

## 10. Out of scope / follow-on specs

After A ships, the planned sequence (each its own brainstorm → spec → plan):

- **B** — `Std.Db` full CRUD: `insertRow`, `getById`, `updateById`, `deleteById`,
  `findOneByField`, `findManyByField`, `findByConditions`, `queryDecode`,
  `withTransaction`, `migrate` (versioned forward-only with `_sky_migrations`
  table + checksum guard, matching Go).
- **C** — `Std.Auth` full + `Std.Money` + `Std.PubSub`.
- **D** — `Sky.Http.Server` + middleware + sub-app + CSRF + cookies + static.
- **E** — `Sky.Live` + 4 session stores + SSE + topics + reconnect + URL routing.
- **F** — `Sky.Tui` + `Std.Ui` HTML renderer + `Sky Console` + observability +
  `Std.Trace` + OTLP export.

A passing `examples/00-standard-libs` on `target=rust` is the gate that
unblocks moving from "CLI/leaf apps work" to "data-layer + auth apps work" in B–C.
