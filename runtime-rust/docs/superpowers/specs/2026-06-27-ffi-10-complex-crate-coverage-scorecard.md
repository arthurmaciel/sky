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

### GENUINELY shim-free — main functionality works (verified, real values), 5
| crate | main functionality proven | fixture |
|---|---|---|
| semver | `parse "1.2.3"` + major/minor/patch + `VersionReq` match | 107 |
| url | `Url::parse` + `scheme`/`host_str` (scheme=="https") | 108 |
| chrono | `NaiveDate` calendar-date construction (y/m/d) | 108 |
| time | `OffsetDateTime::from_unix_timestamp` | 108 |
| hex | `encode [104,105] == "6869"` | 109 |

### Main functionality BLOCKED by codegen/inspector gaps (NOT shim-free yet)
| crate | main fn | blocked by |
|---|---|---|
| serde_json | `from_str` (parse) | #105 (`core::str::traits::FromStr` private path) + serde-deserialize-arg codegen bug (`as_i64` wrapper does `from_str::<Value>(&value)`) |
| rusqlite | `Connection` (open/insert/query) | #107 — `Connection` is `!Send`/RefCell → can't be a Sky value |
| bytes | construct from data | #107 — `From<&'static str>` impl picked (E0597) |
| regex | `Regex::new` | #106 — inspector auto-enables nightly `pattern` feature → E0554 on stable |
| csv | record reading | generic `Reader<R>` over the IO source — no clean bound path |
| toml | parse / `Value` | private internal types (`SerBuffer`) on the usable path |

**The honest state:** auto-FFI binds a large SURFACE for ≥10 complex crates, but the
WORKING main functionality is **5 / 10**. Reaching 10 GENUINE requires fixing the
gaps (#105, the serde-arg bug, #106, #107) — each unblocks a crate's core API. That
is the real path; it is delicate inspector/codegen work, multi-session. A
trivial-accessor call (`version_number()`, `default()`) is NOT a valid proof and
must never be counted.

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
