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

## What this establishes vs what remains

- **Establishes:** the auto-FFI machinery emits a rich constructable binding surface
  for ≥10 complex crates shim-free — real client SDKs (redis/reqwest/rusqlite),
  data formats (serde_json/csv/toml), and widely-used libs (chrono/url/uuid/semver).
  A `drop` in any of these is fail-closed (never a cargo-fail), per the inspector's
  gates.
- **Remains (verification):** the scorecard is rustdoc *classification*; the gold
  standard is a real `sky add` + `sky build` that is **cargo-clean** end-to-end.
  firestore showed classification can hide residual cargo-fails (its 10). The
  end-to-end cargo-clean sweep across this basket should run on **CI / a healthy
  box** — the local dev box is memory-constrained (≈300 MB free after a 12-crate
  rustdoc pass), so heavy multi-crate cargo builds are unreliable locally
  ("no local sweeps; CI verifies"). Tracked as a task.

## Reproduce

```
export SKY_FFI_INSPECTOR_RS=<release inspector>
python3 runtime-rust/scripts/ffi_audit.py run --crates "serde_json,csv,toml,itertools,indexmap,url,uuid,semver,chrono,rusqlite,redis,reqwest"
python3 runtime-rust/scripts/ffi_audit.py summary
```
