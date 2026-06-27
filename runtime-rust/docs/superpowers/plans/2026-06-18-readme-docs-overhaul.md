# README + Documentation Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `runtime-rust/README.md` a succinct, human-readable, browseable document (intro · usage · FFI usage · static · tables · glossary), relocate deep internals to `docs/TECHNICAL-DETAILS.md`, prune docs/ archaeology, move the history log under `docs/`, and provenance the machine-measured tables.

**Architecture:** Pure documentation + two small script edits + a generator extension. No Sky codegen/runtime changes. The fenced `AUTOGEN:*` regions stay machine-owned; a provenance banner is added inside them. The README region ABOVE `## Getting started` is maintainer-owned and is NEVER touched.

**Tech Stack:** Markdown, bash (sweep scripts), Python 3 (`readme-tables.py`), git.

**Approved spec:** `runtime-rust/docs/superpowers/specs/2026-06-18-readme-docs-overhaul-design.md`

---

## Environment (run once per shell)

```bash
cd /home/arthur/Documentos/comp/sky
export PATH="$HOME/.cargo/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.ghcup/bin"
```

All commits are docs/script-only and never push (the user pushes). Do NOT run the example sweep.

## Section disposition (the source of truth for Tasks 5–6)

README sections by current `##`/`###` heading and their fate:

| Heading | Fate |
|---|---|
| `## Contract` (+ `### Limitations to the contract`) | **KEEP, UNTOUCHED** (above `## Getting started` — maintainer-owned) |
| `## Getting started` (Linux/macOS/Windows/Clone/Fast-build/Build/Running/CLI reference) | **KEEP** + readability fixes (Task 7) |
| `## Project status` (Sweep summary, Examples) | **KEEP** + legend tables + provenance (Tasks 2, 7) |
| `## Architecture` heading + intro + `### Rust vs Go…` … `### Cross-backend rules` | **MOVE → TECHNICAL-DETAILS** |
| `### sky.toml Rust fields` (currently last child of `## Architecture`) | **LIFT → new `## FFI usage`** (Task 6) |
| `## Verification state` | **MOVE → TECHNICAL-DETAILS** |
| `## Error type` | **MOVE → TECHNICAL-DETAILS** |
| `## Soundness, correctness and security` (incl. `### Rust FFI`, `### Reach`, `### FFI codegen type-coercion rules`) | **MOVE → TECHNICAL-DETAILS** |
| `## Build performance & DX` | **MOVE → TECHNICAL-DETAILS** |
| `## Static & cross compilation` | **KEEP**; move only the allocator **2×2 measurement** subsection to TECHNICAL-DETAILS, leave a 1-line summary + link (Task 6) |
| `## Known limitations` | **KEEP** |
| `## Glossary` | **KEEP** |

Target README length: **~550 lines** (from 1228).

---

## Task 1: Provenance capture in the two sweep scripts

**Files:**
- Modify: `runtime-rust/scripts/examples-perf-sweep.sh` (near line 47, after `PERF_TSV=` is defined)
- Modify: `runtime-rust/scripts/static-perf.sh` (near line 79, after `TSV=` is defined)

- [ ] **Step 1: Add a provenance writer to `examples-perf-sweep.sh`**

After the line `PERF_TSV="$HIST/perf-$STAMP.tsv"` (line 47), insert:

```bash
# Provenance sidecar (read by readme-tables.py to stamp the README banner with
# WHERE + WHEN the numbers were measured). key=value, one per line.
PERF_PROVENANCE="$HIST/perf-$STAMP.provenance"
{
  echo "stamp=$STAMP"
  echo "os=${RUNNER_OS:-$(uname -s)}"
  echo "arch=$(uname -m)"
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then echo "runner=GitHub Actions"; else echo "runner=$(hostname -s 2>/dev/null || echo local)"; fi
} > "$PERF_PROVENANCE"
```

- [ ] **Step 2: Add the same writer to `static-perf.sh`**

After the line `LOG="$HIST/static-perf-$OS_LABEL-$STAMP.log"` (line 79), insert:

```bash
# Provenance sidecar (see examples-perf-sweep.sh). Per-OS, matching the TSV name.
PROVENANCE="$HIST/static-perf-$OS_LABEL-$STAMP.provenance"
{
  echo "stamp=$STAMP"
  echo "os=$OS_LABEL"
  echo "arch=$(uname -m)"
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then echo "runner=GitHub Actions"; else echo "runner=$(hostname -s 2>/dev/null || echo local)"; fi
} > "$PROVENANCE"
```

- [ ] **Step 3: Syntax-check both scripts**

Run: `bash -n runtime-rust/scripts/examples-perf-sweep.sh && bash -n runtime-rust/scripts/static-perf.sh && echo OK`
Expected: `OK`

- [ ] **Step 4: Smoke-test the provenance writer in isolation**

Run:
```bash
HIST=$(mktemp -d); STAMP=test; RUNNER_OS=Linux
PERF_PROVENANCE="$HIST/perf-$STAMP.provenance"
{ echo "stamp=$STAMP"; echo "os=${RUNNER_OS:-$(uname -s)}"; echo "arch=$(uname -m)"; echo "runner=$(hostname -s 2>/dev/null || echo local)"; } > "$PERF_PROVENANCE"
cat "$PERF_PROVENANCE"; rm -rf "$HIST"
```
Expected: four lines `stamp=test`, `os=Linux`, `arch=x86_64`, `runner=<host>`.

- [ ] **Step 5: Commit**

```bash
git add runtime-rust/scripts/examples-perf-sweep.sh runtime-rust/scripts/static-perf.sh
git commit -m "ci(rust): record a provenance sidecar (stamp/os/arch/runner) next to perf + static TSVs"
```

---

## Task 2: Provenance banner in `readme-tables.py` + reseed the fenced regions

**Files:**
- Modify: `runtime-rust/scripts/readme-tables.py`
- Modify: `runtime-rust/README.md` (regenerated AUTOGEN regions)

- [ ] **Step 1: Add a provenance reader + banner helper**

After the `newest(...)` function in `readme-tables.py`, add:

```python
def read_provenance(results_root: str, *patterns: str):
    """Newest matching *.provenance → dict (stamp/os/arch/runner), or {} if none."""
    f = newest(results_root, *patterns)
    if not f:
        return {}
    prov = {}
    with open(f, encoding="utf-8") as fh:
        for ln in fh:
            if "=" in ln:
                k, v = ln.rstrip("\n").split("=", 1)
                prov[k] = v
    return prov


def provenance_banner(results_root: str, sweep: str, tsv_for_fallback: str | None) -> str:
    """A one-line italic banner: WHERE + WHEN the numbers were machine-measured."""
    if sweep == "static-perf":
        prov = read_provenance(results_root, "**/static-perf-*-*.provenance", "static-perf-*-*.provenance")
    else:
        prov = read_provenance(results_root, "**/perf-*.provenance", "**/examples-perf-sweep/perf-*.provenance")
    stamp = prov.get("stamp")
    if not stamp and tsv_for_fallback:  # derive from the TSV filename: perf-<stamp>.tsv
        m = re.search(r"(\d{8}T\d{6}Z)", os.path.basename(tsv_for_fallback))
        stamp = m.group(1) if m else "unknown"
    runner = prov.get("runner", "local")
    osname = prov.get("os", "?")
    arch = prov.get("arch", "?")
    return (
        f"> _Machine-measured · {stamp or 'unknown'} · {runner} {osname} ({arch}) · "
        f"{sweep} — regenerated by `readme-tables.py`, not hand-edited._"
    )
```

- [ ] **Step 2: Emit the banner in the three renderers**

In `render_static_table`, change the `lines = [note, header]` initialization to prepend the banner + a blank line:
```python
    banner = provenance_banner(results_root, "static-perf", by_os.get("Linux"))
    lines = [note, banner, "", header]
```

In `render_examples_table`, change `lines = [note, header]` to:
```python
    banner = provenance_banner(results_root, "examples-perf-sweep",
                               newest(results_root, "**/perf-*.tsv", "**/examples-perf-sweep/perf-*.tsv"))
    lines = [note, banner, "", header]
```

In `render_perf_verdict`, change the opening `lines = [note, f"**Performance verdict** …", "",]` block so the banner sits between the note and the verdict intro:
```python
    banner = provenance_banner(results_root, "examples-perf-sweep",
                               newest(results_root, "**/perf-*.tsv", "**/examples-perf-sweep/perf-*.tsv"))
    lines = [
        note,
        banner,
        "",
        f"**Performance verdict** — Rust vs Go, geometric mean of the per-example "
        f"Rust/Go ratios (parity band {pct}):",
        "",
    ]
```

- [ ] **Step 3: Compile-check + reseed the README regions from the local cache**

Run:
```bash
python3 -m py_compile runtime-rust/scripts/readme-tables.py && echo "py OK"
python3 runtime-rust/scripts/readme-tables.py examples --results "$HOME/.cache/sky" --readme runtime-rust/README.md --write
python3 runtime-rust/scripts/readme-tables.py static   --results "$HOME/.cache/sky" --readme runtime-rust/README.md --write 2>&1 | tail -1
```
Expected: `py OK`; `examples-table + perf-verdict: wrote refreshed content…`; static prints either a write or `no static-perf TSV … leaving the table unchanged` (the local cache may lack a full static set — that is fine; CI fills it).

- [ ] **Step 4: Verify the banner is present and `--check` round-trips**

Run:
```bash
rg -n 'Machine-measured ·' runtime-rust/README.md
python3 runtime-rust/scripts/readme-tables.py examples --results "$HOME/.cache/sky" --check; echo "exit=$?"
rm -rf runtime-rust/scripts/__pycache__
```
Expected: at least 2 `Machine-measured ·` lines (examples-table + perf-verdict; static if it wrote); `examples-table + perf-verdict: in sync.` and `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add runtime-rust/scripts/readme-tables.py runtime-rust/README.md
git commit -m "docs(rust): provenance banner (stamp/platform) inside the AUTOGEN README tables"
```

---

## Task 3: Wipe docs/ history, lift ADR 0001 into CLAUDE.md, repoint refs

**Files:**
- Delete: `runtime-rust/docs/superpowers/plans/*.md` (all 10)
- Delete: most `runtime-rust/docs/superpowers/specs/*.md` (KEEP the 4 referenced sets + this overhaul's spec)
- Delete: `runtime-rust/docs/rust-example-conquest-registry.md`, `docs/escalated-decisions.md`, `docs/upstream-pr-proposals.md`, `docs/adr/0001-sky-value-types-stay-transparent-aliases.md`
- Create: `runtime-rust/docs/superpowers/plans/.gitkeep`, `runtime-rust/docs/adr/.gitkeep`
- Modify: `runtime-rust/CLAUDE.md` (add the ADR decision)
- Modify: the `rust-examples-baseline` memory note

- [ ] **Step 1: Capture the ADR decision text before deleting it**

Run: `cat runtime-rust/docs/adr/0001-sky-value-types-stay-transparent-aliases.md`
Read the "Context & decision" — the load-bearing point is *Sky value types (Int/Float/String/Bool/Decimal/Money/etc.) lower to transparent Rust type aliases, not newtypes, so they unify structurally across the FFI boundary and need no wrapper/unwrap*. You will paste a distilled version into CLAUDE.md in Step 4.

- [ ] **Step 2: Delete the plans + the three root history docs + the ADR**

```bash
cd runtime-rust/docs
git rm superpowers/plans/*.md
git rm rust-example-conquest-registry.md escalated-decisions.md upstream-pr-proposals.md
git rm adr/0001-sky-value-types-stay-transparent-aliases.md
cd /home/arthur/Documentos/comp/sky
```

- [ ] **Step 3: Delete the shipped specs, KEEPING the referenced ones**

```bash
cd runtime-rust/docs/superpowers/specs
# keep: dbdec-subsystem, all skyshop-rs-*, rust-multibackend-entry-model, the overhaul spec
for f in *.md; do
  case "$f" in
    2026-06-16-dbdec-subsystem.md|*skyshop-rs*|2026-06-12-rust-multibackend-entry-model.md|2026-06-18-readme-docs-overhaul-design.md) : ;;
    *) git rm "$f" ;;
  esac
done
cd /home/arthur/Documentos/comp/sky
echo "--- specs kept: ---"; ls runtime-rust/docs/superpowers/specs/
```
Expected kept list: `2026-06-12-rust-multibackend-entry-model.md`, `2026-06-15-skyshop-rs-codegen-gaps.md`, `2026-06-15-skyshop-rs-port-SYNTHESIS.md`, `2026-06-15-skyshop-rs-port-plan-A.md`, `2026-06-15-skyshop-rs-port-plan-B.md`, `2026-06-15-skyshop-rs-port-questions.md`, `2026-06-16-dbdec-subsystem.md`, `2026-06-18-readme-docs-overhaul-design.md`.

- [ ] **Step 4: Add `.gitkeep` to the emptied dirs + lift the ADR into CLAUDE.md**

```bash
touch runtime-rust/docs/superpowers/plans/.gitkeep runtime-rust/docs/adr/.gitkeep
```

In `runtime-rust/CLAUDE.md`, under `## Agent learnings` → `### Foundational understanding`, add as the first bullet:

```markdown
- **Sky value types lower to TRANSPARENT Rust type aliases, not newtypes**
  (Int/Float/String/Bool/Decimal/Money/…). They unify structurally across the FFI
  boundary, so generated code needs no wrap/unwrap and FFI args/returns match by
  shape. (Was ADR 0001 — accepted; folded here when docs/adr was pruned.)
```

Also in `runtime-rust/CLAUDE.md`, fix the line that reads `files — `docs/adr/`, escalated-decisions, etc. — are exempt; this rule is the` — change it to reference only the surviving exempt class:
```markdown
files — `docs/adr/` (kept for future ADRs), the surviving specs, etc. — are exempt; this rule is the
```

- [ ] **Step 5: Repoint the memory note that referenced the deleted registry**

In `/home/arthur/.claude/projects/-home-arthur-Documentos-comp-sky/memory/rust-examples-baseline.md`, replace the `runtime-rust/docs/rust-example-conquest-registry.md` reference with `runtime-rust/docs/PROGRESS.md` (history) + `skydex roles` (live example status).

- [ ] **Step 6: Verify no dangling refs to wiped files remain (outside this plan/spec)**

Run:
```bash
rg -rln 'rust-example-conquest-registry|escalated-decisions|upstream-pr-proposals|0001-sky-value-types|adr/0001' \
  runtime-rust/CLAUDE.md runtime-rust/README.md runtime-rust/plugins runtime-rust/docs/superpowers \
  /home/arthur/.claude/projects/-home-arthur-Documentos-comp-sky/memory \
  | rg -v 'docs/superpowers/(plans|specs)/2026-06-18' || echo "CLEAN"
```
Expected: `CLEAN` (the only matches allowed are inside this plan + the spec).

- [ ] **Step 7: Commit**

```bash
git add -A runtime-rust/docs runtime-rust/CLAUDE.md
git commit -m "docs(rust): prune docs/ archaeology (plans + shipped specs + registry + escalated/upstream-pr + ADR); lift ADR 0001 → CLAUDE.md"
```
(The memory file lives outside the repo — it is saved separately by the Write tool, not committed here.)

---

## Task 4: Move PROGRESS.md → docs/ and repoint every reference

**Files:**
- Move: `runtime-rust/PROGRESS.md` → `runtime-rust/docs/PROGRESS.md`
- Modify: `runtime-rust/CLAUDE.md`
- Modify: `runtime-rust/plugins/sky-rust-backend/skills/{update-docs,prune-archaeology,autonomous-swarm,push,sync-with-upstream,keep-go-parity,quality-audit}/SKILL.md` (only those that mention PROGRESS.md)

- [ ] **Step 1: git mv the file**

```bash
git mv runtime-rust/PROGRESS.md runtime-rust/docs/PROGRESS.md
```

- [ ] **Step 2: Find every reference to repoint**

Run: `rg -rln 'PROGRESS\.md' runtime-rust/CLAUDE.md runtime-rust/plugins`
Expected: a list including `runtime-rust/CLAUDE.md` and `update-docs/SKILL.md` (and any others).

- [ ] **Step 3: Repoint references — CLAUDE.md**

In `runtime-rust/CLAUDE.md`:
- Every textual path `PROGRESS.md` that means the file → `docs/PROGRESS.md`.
- The allowed-root-`.md` rule currently lists three files. Change it to two:
  ```markdown
  - Allowed `runtime-rust/` root `.md` files: **`CLAUDE.md`, `README.md`** —
    nothing else (`PROGRESS.md` now lives at `docs/PROGRESS.md`).
  ```
- The `## Settled rules` "Log every step to `PROGRESS.md`" bullet → `docs/PROGRESS.md`.

- [ ] **Step 4: Repoint references — each skill SKILL.md**

For every file from Step 2 under `plugins/`, replace `PROGRESS.md` → `docs/PROGRESS.md` (and `runtime-rust/PROGRESS.md` → `runtime-rust/docs/PROGRESS.md`). Also in `update-docs/SKILL.md` the "root-`.md` policy" paragraph that lists `CLAUDE.md`, `README.md`, and `PROGRESS.md` → drop PROGRESS.md from the *root* list and note it now lives at `docs/PROGRESS.md` as a history INPUT.

- [ ] **Step 5: Verify no stray root-path reference remains**

Run:
```bash
rg -rn 'runtime-rust/PROGRESS\.md|[^/]PROGRESS\.md' runtime-rust/CLAUDE.md runtime-rust/plugins \
  | rg -v 'docs/PROGRESS\.md' || echo "CLEAN"
```
Expected: `CLEAN` (every mention now carries the `docs/` prefix).

- [ ] **Step 6: Commit**

```bash
git add -A runtime-rust/CLAUDE.md runtime-rust/docs/PROGRESS.md runtime-rust/plugins
git commit -m "docs(rust): move PROGRESS.md → docs/PROGRESS.md; repoint CLAUDE.md + skills"
```

---

## Task 5: Create TECHNICAL-DETAILS.md and move the deep sections out of README

**Files:**
- Create: `runtime-rust/docs/TECHNICAL-DETAILS.md`
- Modify: `runtime-rust/README.md` (cut the moved sections)

This task only RELOCATES content verbatim. Cut each MOVE section (its heading line through the line immediately before the next KEPT heading) out of README and paste it under the same heading into TECHNICAL-DETAILS.md, in the order listed. Do NOT reword the moved content.

- [ ] **Step 1: Create the file with a header**

Create `runtime-rust/docs/TECHNICAL-DETAILS.md`:
```markdown
# Sky Rust backend — technical details

Deep internals for the Sky → Rust backend (`feat/runtime-rust`). The user-facing
intro, usage, FFI usage, static-compilation guide, and the examples/static tables
live in [`../README.md`](../README.md). History lives in [`PROGRESS.md`](PROGRESS.md).

---
```

- [ ] **Step 2: Move `## Architecture` (minus `### sky.toml Rust fields`)**

In README, cut from the `## Architecture` heading through the line BEFORE `### sky.toml Rust fields`. Append it verbatim to TECHNICAL-DETAILS.md. (The `### sky.toml Rust fields` subsection stays in README for now; Task 6 relocates it to `## FFI usage`.)

- [ ] **Step 3: Move `## Verification state`, `## Error type`, `## Soundness, correctness and security`, `## Build performance & DX`**

Cut each section (heading through the line before the next heading) from README and append verbatim to TECHNICAL-DETAILS.md, in this order. After this, in README the order around there is: `## Project status` … `### sky.toml Rust fields` (orphaned — Task 6 fixes) … `## Static & cross compilation`.

- [ ] **Step 4: Verify content conservation**

Run:
```bash
for h in "## Verification state" "## Error type" "## Soundness, correctness and security" "## Build performance & DX" "### Rust vs Go backend" "### Cross-backend rules"; do
  r=$(rg -c -F "$h" runtime-rust/README.md || echo 0); t=$(rg -c -F "$h" runtime-rust/docs/TECHNICAL-DETAILS.md || echo 0)
  echo "README=$r TECH=$t :: $h"
done
```
Expected: every line shows `README=0 TECH=1` (moved out of README, present in TECHNICAL-DETAILS).

- [ ] **Step 5: Commit**

```bash
git add runtime-rust/docs/TECHNICAL-DETAILS.md runtime-rust/README.md
git commit -m "docs(rust): move deep internals (Architecture/Verification/Error/Soundness/Build-perf) → docs/TECHNICAL-DETAILS.md"
```

---

## Task 6: README — new `## FFI usage`, allocator summary+link, TECHNICAL-DETAILS pointer

**Files:**
- Modify: `runtime-rust/README.md`
- Modify: `runtime-rust/docs/TECHNICAL-DETAILS.md` (receives the allocator 2×2)

- [ ] **Step 1: Promote `### sky.toml Rust fields` to `## FFI usage`**

In README, locate the orphaned `### sky.toml Rust fields` subsection (now sitting after Project status). Change its heading to `## FFI usage`, and move the whole section so it sits AFTER `## Static & cross compilation` and BEFORE `## Known limitations`. Add a one-sentence lead under the new `## FFI usage` heading:
```markdown
Rust FFI is fully automatic — point `sky.toml` at a crate and the compiler
generates the bindings (`rustdoc --output-format json`); no hand-written FFI.
```
Keep the existing `### sky.toml Rust fields` content as a `###` child of `## FFI usage`, and keep the "Reaching async / framework crates" wrapper note. In that note, change the phrase "see the FFI Reach section" → "see [FFI Reach in TECHNICAL-DETAILS](docs/TECHNICAL-DETAILS.md#reach-what-auto-ffi-cancant-cover)".

- [ ] **Step 2: Move the allocator 2×2 measurement to TECHNICAL-DETAILS, leave a summary**

In README's `## Static & cross compilation` → the allocator subsection, cut the **2×2 measurement table** + its surrounding measurement prose and append to TECHNICAL-DETAILS.md under a new heading `## Allocator 2×2 measurement (static builds)`. In README, replace the cut block with:
```markdown
mimalloc is the default allocator for `--static` (musl): it beats glibc ~1.7× and
is ~11× faster than musl's own malloc on high-volume small allocations. Full 2×2
linking×allocator measurement: [Allocator 2×2 in TECHNICAL-DETAILS](docs/TECHNICAL-DETAILS.md#allocator-22-measurement-static-builds).
```

- [ ] **Step 3: Add the single TECHNICAL-DETAILS pointer near the top of the kept README**

Immediately after the last paragraph of `## Project status` (before `## Static & cross compilation`), add:
```markdown
> **Deep internals** (architecture, soundness model, error type, verification,
> FFI coercion rules, build-perf) live in [`docs/TECHNICAL-DETAILS.md`](docs/TECHNICAL-DETAILS.md).
```

- [ ] **Step 4: Verify the new structure**

Run: `rg -n '^## ' runtime-rust/README.md`
Expected order: `## Contract`, `## Getting started`, `## Project status`, `## Static & cross compilation`, `## FFI usage`, `## Known limitations`, `## Glossary` (no `## Architecture`/`## Verification state`/`## Error type`/`## Soundness…`/`## Build performance & DX`).

- [ ] **Step 5: Commit**

```bash
git add runtime-rust/README.md runtime-rust/docs/TECHNICAL-DETAILS.md
git commit -m "docs(rust): new ## FFI usage section; allocator 2x2 → TECHNICAL-DETAILS with summary+link"
```

---

## Task 7: README readability fixes

**Files:**
- Modify: `runtime-rust/README.md`

- [ ] **Step 1: No hardcoded GHC version in Getting started**

In each of the Linux/macOS/Windows install blocks, replace any pinned `ghc 9.6.7` / `9.6` install line so it reads (keep it inside the code block):
```bash
ghcup install ghc 9.6.7   # or any GHC >= 9.6.7; cabal resolves the rest
```
And in prose, write "GHC **≥ 9.6.7**". Do NOT touch `.github/workflows/examples-sweep.yml` (its pin is intentional).

- [ ] **Step 2: Inline anchor links for the three "continue with" lines**

Replace each of the three lines `Now continue with **Clone, Fast-build env, and Build the compiler** below.` (Linux/macOS/Windows) with:
```markdown
Now continue with [Clone the repo](#clone-the-repo-all-oses), [Fast-build env](#fast-build-env-all-oses), and [Build the Sky compiler](#build-the-sky-compiler-all-oses).
```

- [ ] **Step 3: macOS musl command inside the code block**

In `### macOS`, find the musl cross-compile instruction currently in prose outside the fenced block. Move the actual command INTO the macOS `bash` code block (matching how Linux does it), e.g.:
```bash
# Cross-compile a static Linux binary from macOS (optional):
brew install FiloSottile/musl-cross/musl-cross
rustup target add x86_64-unknown-linux-musl
```
Leave only a short prose pointer outside the block, not the command itself.

- [ ] **Step 4: Rewrite the Fast-build `Why:` paragraph as bullets**

In `### Fast-build env (all OSes)`, replace the single-paragraph `Why:` block with:
```markdown
**Why:**

- The shared `CARGO_TARGET_DIR` compiles the heavy dependency tree (tokio / axum / serde / sqlx) once and reuses it across every example.
- `sccache` caches compiled crate objects across builds.
- `CARGO_INCREMENTAL=0` is mandatory with sccache — sccache silently skips caching when incremental builds are on.
- On macOS/Windows adapt the `PATH` to where your tools actually live (e.g. drop `/usr/local/go/bin` if Go isn't installed).
- The three `export` lines for the cargo/sccache env are the load-bearing ones.
```
(Rule applied: line break after `Why:`, one `-` bullet per reason, a break at every semicolon in the original.)

- [ ] **Step 5: Convert the Round-trip inline list to a table**

In `### Examples` intro prose, replace the inline `"Round-trip" = how RUN is exercised: cli = stdout · server = curl boot/serve · live = headless browser scenario · tui = pty smoke · webview = xvfb smoke.` with:
```markdown
**Round-trip** = how each shape's RUN is exercised:

| Shape | RUN is exercised by |
|---|---|
| `cli` | stdout comparison |
| `server` | curl boot / serve |
| `live` | headless-browser scenario |
| `tui` | pty smoke |
| `webview` | xvfb smoke |
```

- [ ] **Step 6: Convert the Perf-columns inline list to a table**

Replace the inline `Thru (…↑…) · RSS (…↓…) · Cold (…↓) · Bin (…↓). — = … ; n/a = …` prose with:
```markdown
The four **Perf** columns are Rust/Go ratios from the perf sweep:

| Column | Meaning | Better |
|---|---|:-:|
| **Thru** | request throughput | ↑ higher = Rust faster |
| **RSS** | resident memory | ↓ lower = Rust leaner |
| **Cold** | cold-start time (ms) | ↓ lower |
| **Bin** | binary size | ↓ lower |

`—` = the shape has no such measurement · `n/a` = measured but the probe couldn't compare.
```

- [ ] **Step 7: Convert the Equiv-modes list to a table placed BEFORE the examples table**

Move the `**Equiv modes:**` legend so it appears immediately BEFORE the `<!-- AUTOGEN:examples-table BEGIN -->` fence (it is the table's legend), as a table:
```markdown
**Equiv modes** (how Go≡Rust equivalence is proven per shape):

| Mode | Means |
|---|---|
| `stdout` | byte-identical stdout + exit code |
| `body N` | N GET-route response bodies byte-identical |
| `scenario` | same headless-browser round-trip passes on both backends |
| `pty` | both drive the Sky.Tui runtime, no panic |
| `serve` | both boot + serve (no comparable GET route) |
| `n/a` | no Go comparison possible |
```
Remove the old inline `**Equiv modes:** …` paragraph that followed the table.

- [ ] **Step 8: Light skim-flow pass**

Read the kept README top-to-bottom once. Trim any now-orphaned cross-references to moved sections, fix transitions, and tighten verbose prose — WITHOUT changing any technical claim, any AUTOGEN-fenced content, or anything above `## Getting started`.

- [ ] **Step 9: Verify AUTOGEN round-trip still holds + tables render**

Run:
```bash
python3 runtime-rust/scripts/readme-tables.py examples --results "$HOME/.cache/sky" --check; echo "exit=$?"
rg -c '^\| ' runtime-rust/README.md   # table rows present
rm -rf runtime-rust/scripts/__pycache__
```
Expected: `examples-table + perf-verdict: in sync.` `exit=0`; a nonzero table-row count.

- [ ] **Step 10: Commit**

```bash
git add runtime-rust/README.md
git commit -m "docs(rust): README readability — GHC>=9.6.7, anchor links, macOS musl in-block, Why bullets, legend tables"
```

---

## Task 8: Update the `update-docs` skill + CLAUDE.md settled rule for the new structure

**Files:**
- Modify: `runtime-rust/plugins/sky-rust-backend/skills/update-docs/SKILL.md`
- Modify: `runtime-rust/CLAUDE.md`

- [ ] **Step 1: Rewrite the `update-docs` section list to the slim README**

In `update-docs/SKILL.md`, replace the enumerated README section list (currently Architecture / Verification / etc.) with the new slim set: `## Contract` (untouched), `## Getting started`, `## Project status` (+ AUTOGEN regions), `## Static & cross compilation`, `## FFI usage`, `## Known limitations`, `## Glossary`. Add an explicit instruction:
```markdown
**Second maintained file — `docs/TECHNICAL-DETAILS.md`.** The deep sections
(Architecture, Verification state, Error type, Soundness, Build performance & DX,
FFI coercion rules, allocator 2×2) now live there, NOT in README. Reconcile both
files each run: README stays the slim user-facing snapshot; TECHNICAL-DETAILS.md
holds the internals. Read `docs/PROGRESS.md` (moved from the root) as the history
input.
```

- [ ] **Step 2: Update CLAUDE.md `### Domain docs` paragraph**

In `runtime-rust/CLAUDE.md`, the `### Domain docs` text says "only `CLAUDE.md` and `README.md` exist" and "fold the content into `README.md`". Update it to: the deep internals live in `docs/TECHNICAL-DETAILS.md`; the root holds `CLAUDE.md` + `README.md`; `docs/PROGRESS.md` is the history sink.

- [ ] **Step 3: Verify the skill no longer names moved sections as README-owned**

Run: `rg -n 'Architecture|Verification state|Soundness' runtime-rust/plugins/sky-rust-backend/skills/update-docs/SKILL.md`
Expected: any remaining mention is in the "now lives in TECHNICAL-DETAILS" context, not the README section list.

- [ ] **Step 4: Commit**

```bash
git add runtime-rust/plugins/sky-rust-backend/skills/update-docs/SKILL.md runtime-rust/CLAUDE.md
git commit -m "docs(rust): teach update-docs + CLAUDE.md the README/TECHNICAL-DETAILS split + docs/PROGRESS.md"
```

---

## Task 9: Final verification sweep

**Files:** none (read-only checks)

- [ ] **Step 1: AUTOGEN round-trip (both regions)**

```bash
python3 runtime-rust/scripts/readme-tables.py examples --results "$HOME/.cache/sky" --check; echo "examples exit=$?"
python3 runtime-rust/scripts/readme-tables.py static   --results "$HOME/.cache/sky" --check 2>&1 | tail -1
rm -rf runtime-rust/scripts/__pycache__
```
Expected: examples `exit=0`; static reports in-sync OR "no static-perf TSV" (local-cache dependent — not a failure).

- [ ] **Step 2: Zero dangling refs to wiped files**

```bash
rg -rln 'rust-example-conquest-registry|escalated-decisions|upstream-pr-proposals|0001-sky-value-types' \
  runtime-rust/CLAUDE.md runtime-rust/README.md runtime-rust/docs/TECHNICAL-DETAILS.md runtime-rust/plugins runtime-rust/docs/superpowers \
  | rg -v 'docs/superpowers/(plans|specs)/2026-06-18' || echo "CLEAN"
```
Expected: `CLEAN`.

- [ ] **Step 3: Every PROGRESS.md reference is the docs/ path**

```bash
rg -rn 'PROGRESS\.md' runtime-rust/CLAUDE.md runtime-rust/plugins | rg -v 'docs/PROGRESS\.md' || echo "CLEAN"
```
Expected: `CLEAN`.

- [ ] **Step 4: README halved + new structure**

```bash
wc -l runtime-rust/README.md
rg -n '^## ' runtime-rust/README.md
```
Expected: ≤ ~650 lines; section order Contract → Getting started → Project status → Static & cross compilation → FFI usage → Known limitations → Glossary.

- [ ] **Step 5: Anchor targets exist for the links**

```bash
for a in "Clone the repo" "Fast-build env" "Build the Sky compiler"; do
  rg -qF "### $a" runtime-rust/README.md && echo "OK: $a" || echo "MISSING: $a"
done
rg -qF '### Reach' runtime-rust/docs/TECHNICAL-DETAILS.md && echo "OK: Reach anchor" || echo "MISSING: Reach"
rg -qF '## Allocator 2×2 measurement' runtime-rust/docs/TECHNICAL-DETAILS.md && echo "OK: allocator anchor" || echo "MISSING: allocator"
```
Expected: all `OK:`.

- [ ] **Step 6: Relative links resolve**

```bash
rg -n 'docs/TECHNICAL-DETAILS\.md|docs/PROGRESS\.md' runtime-rust/README.md
test -f runtime-rust/docs/TECHNICAL-DETAILS.md && test -f runtime-rust/docs/PROGRESS.md && echo "targets exist"
```
Expected: links present; `targets exist`.

- [ ] **Step 7: Pre-final gate (docs/security/correctness/soundness)**

Confirm: nothing above `## Getting started` changed (`git diff main -- runtime-rust/README.md | rg -n '^@@' | head` — first hunk should be at/after the Getting-started region); no secret introduced; the generator changes remain total (missing provenance → fallback, no crash). If clean, the overhaul is complete; the user pushes.

---

## Self-review notes (author)

- **Spec coverage:** §1a→Task 3; §1b→Task 4; §1c→Tasks 5–6; §2→Tasks 5–7; §3→Task 7; §4→Tasks 1–2; §5→Task 8; §6→Task 9. All covered.
- **No push / no sweep:** every task is local; the user pushes (per session rules + the `sky-rust-backend:push` skill). CI fills real provenance on the next dispatch.
- **Round-trip guard:** the provenance banner is added to the generator (Task 2) BEFORE the README prose restructure (Tasks 5–7), so `--check` stays green throughout.
