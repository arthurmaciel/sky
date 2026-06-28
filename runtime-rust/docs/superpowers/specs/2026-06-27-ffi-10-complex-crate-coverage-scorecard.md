# Sky→Rust auto-FFI — complex-crate coverage scorecard (2026-06-27)

> Evidence for the standing goal: **full automatic FFI for ≥10 complex crates,
> shim-free** (direct `sky add` of a crates.io crate — NO wrapper crate). Measured
> with `runtime-rust/scripts/ffi_audit.py` (the inspector's rustdoc-classification:
> how many constructable bindings it emits per crate). Verdict = constructable
> surface (`free`+`ctor`): `rich` ≥10 · `usable` 3-9 · `thin` 1-2.

## Result — 12 measured, 10 `rich` + 1 `usable` + 1 `thin`

| crate | class | kept | free | ctor | accs | verdict | version |
|---|---|---:|---:|---:|---:|---|---|
| chrono | leaf | 484 | 213 | 43 | 228 | **rich** | 0.4.45 |
| semver | leaf | 56 | 24 | 8 | 24 | **rich** | 1.0.28 |
| url | leaf | 82 | 23 | 4 | 55 | **rich** | 2.5.8 |
| uuid | leaf | 131 | 41 | 38 | 52 | **rich** | 1.23.4 |
| indexmap | generic | 11 | 7 | 0 | 4 | usable | 2.14.0 |
| itertools | generic | 14 | 2 | 0 | 12 | thin | 0.15.0 |
| csv | serde | 134 | 50 | 11 | 73 | **rich** | 1.4.0 |
| serde_json | serde | 139 | 72 | 6 | 61 | **rich** | 1.0.150 |
| toml | serde | 67 | 35 | 3 | 29 | **rich** | 1.1.2 |
| redis | client | 1007 | 529 | 43 | 435 | **rich** | 1.2.1 |
| reqwest | client | 193 | 48 | 25 | 120 | **rich** | 0.13.4 |
| rusqlite | client | 137 | 59 | 12 | 66 | **rich** | 0.40.0 |

Plus **firestore 0.49** — a genuinely hard async/builder SDK historically reachable
only via a wrapper shim — now binds DIRECTLY after the wall campaign (#44–#98, #68)
+ Part B (#100): `SKY_DCE=0` full-surface residual is down to **10** (from 124),
and it is already USABLE via the owned CRUD path under default DCE (fixture 104).

## CRITICAL CAVEAT — classification ≠ working main functionality

The `rich`/`usable` verdict above is **rustdoc CLASSIFICATION** (how many wrappers
the inspector emits). It is NOT proof the crate is usable. Verifying each crate's
**MAIN functionality** end-to-end (real `sky add` + a program calling the crate's
core API with real values + cargo-clean build + correct output) tells a very
different, honest story:

### GENUINELY shim-free — main functionality works (verified, real values), 9
| crate | main functionality proven | fixture |
|---|---|---|
| semver | `parse "1.2.3"` + major/minor/patch + `VersionReq` match | 107 |
| url | `Url::parse` + `scheme`/`host_str` (scheme=="https") | 108 |
| chrono | `NaiveDate` calendar-date construction (y/m/d) | 108 |
| time | `OffsetDateTime::from_unix_timestamp` | 108 |
| hex | `encode [104,105] == "6869"` | 109 |
| serde_json | `from_str "42"` (parse) + `as_i64` read (==42) | 111 |
| regex | `Regex::new "^[0-9]+$"` + `is_match` (digits=T, "12a45"=F) | 112 |
| bytes | `Bytes::copy_from_slice [104,105]` + `len==2` + `get_u8==104` | 113 |
| jiff | `civil::date 2024 3 15` + `year`==2024 + `to_string`=="2024-03-15" | 114 |

**serde_json was UNBLOCKED by fixing two ROOT-CAUSE gaps** (not by routing around
them): #105 (inspector now emits the public `core::str::FromStr` path, not the
private `core::str::traits::FromStr` — unblocks `from_str`/parse for EVERY FromStr
type) + the serde-receiver over-deserialize (FfiInstance `serdeArgIdxs` excludes
the receiver; `Value::as_i64(&self)` no longer mis-emits a `from_str::<Value>(&value)`
prelude — unblocks EVERY serde-Value-receiver accessor: as_str/as_bool/as_f64/get/…).
Guardian-approved; serde fixtures 73/79/81 regression-clean.

**regex was UNBLOCKED by fixing the #106 ROOT-CAUSE gap** (not routed around): the
inspector ran `cargo +nightly rustdoc`, so it auto-enabled regex's NIGHTLY-ONLY
`pattern` feature (`#![cfg_attr(feature="pattern", feature(pattern))]`); Part B then
propagated it into the PORTABLE kernel.json + generated Cargo.toml → E0554 on every
stable consumer. Fix: the inspector now VERIFIES the auto-injected feature set
against a PINNED-STABLE toolchain (`RUSTUP_TOOLCHAIN=stable`, `RUSTC`/`RUSTC_WRAPPER`/
`RUSTC_BOOTSTRAP` removed) before propagating — builds-on-stable ⇒ builds-on-nightly,
so it can only ever be more conservative. A nightly-gated set drops to default
features (re-running rustdoc there so bindings ↔ features stay consistent) and the
downgrade is surfaced to the user (Ffi.hs forwards inspector `[sky-ffi]` diagnostics
on success). Guardian-approved (2-round); user-explicit sky.toml features kept
verbatim; fixtures 112 + 112b (the nightly-ambient lock: `RUSTUP_TOOLCHAIN=nightly`
forced → `pattern` still dropped).

**bytes needed NO code change** — its main fn works under DEFAULT DCE. `copy_from_slice`
(List Int → Bytes) is the real owned constructor; `len`/`get_u8` read it. The prior
"blocked by `From<&'static str>` (E0597)" was a SKY_DCE=0 FULL-SURFACE artifact (the
`&str` From dedups away under default DCE; the broken full-surface binding is
tree-shaken when unused). Honest lesson: a SKY_DCE=0 residual ≠ a default-DCE main-fn
blocker — always probe the main fn under default DCE before declaring a crate blocked.

**jiff (9th) was UNBLOCKED by the #109 ROOT-CAUSE fix** (general): the inspector dropped
the SUBMODULE from a free-fn CALL path → emitted `::jiff::date` for `::jiff::civil::date`
→ E0425. Fix: route free-fn call paths through `REACHABLE_PATHS` (the public-path,
re-export-aware #57 machinery — NOT `doc["paths"]` which can be private → the #105 trap),
via a new `Function.call_path` (crate segment stripped) threaded inspector→FfiGen→Ffi.hs.
Fail-closed to `::crate::name` (status quo) when the public path is unprovable; crate-root
free fns byte-identical. Guardian 2-round APPROVE (design + final). General: unblocks any
crate with free fns in submodules. Fixture 114.

### The 10th — root-cause path IDENTIFIED (distinct inspector/codegen fix)
| crate | main fn | root cause (filed) |
|---|---|---|
| toml | parse → `Value` | #110 — `from_str` return-type dedup picks the `String`-returning variant, shadowing `Value::from_str` → no bound parse-to-Value path. #48-class (overload dedup by return type). |
| base64 | `encode`/`decode` | DEGENERATE: the FFI wrapper `base64_encode` collides with Sky's OWN `Std.Encoding.base64Encode` runtime kernel → E0659 ambiguous. base64 duplicates stdlib — a poor demonstrator; skip. |
| rusqlite | `Connection` | `Connection` is `!Send`/RefCell → can't be a Sky value. Likely FUNDAMENTAL (needs a wrapper) — don't count; pick another 10th. |
| csv | record reading | generic `Reader<R>` over the IO source — no clean bound path. |

**The honest state:** auto-FFI binds a large SURFACE for ≥10 complex crates, and the
WORKING main functionality is now **9 / 10**. The 10th is best reached via the toml
`from_str` return-type-dedup fix (#110, general — disambiguate overloaded statics by
return type). It is a fresh inspector+codegen cycle warranting its own guardian review —
delicate, root-cause work, NOT trivial-accessor gaming. A trivial-accessor call
(`version_number()`, `default()`) is NOT a valid proof.

## What remains
- Fix #105/#106/#107 + the serde-deserialize-arg bug → re-verify serde_json /
  bytes / regex / rusqlite (where !Send permits) main functionality.
- Per-crate end-to-end build belongs on CI / a healthy box for the heavy SDKs
  (redis/reqwest) — local dev box is memory-constrained (≈300 MB free).

## Reproduce

```
export SKY_FFI_INSPECTOR_RS=<release inspector>
python3 runtime-rust/scripts/ffi_audit.py run --crates "serde_json,csv,toml,itertools,indexmap,url,uuid,semver,chrono,rusqlite,redis,reqwest"
python3 runtime-rust/scripts/ffi_audit.py summary
```
