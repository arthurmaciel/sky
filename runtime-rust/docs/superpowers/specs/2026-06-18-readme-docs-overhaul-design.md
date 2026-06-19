# README + documentation overhaul — design

**Date:** 2026-06-18 · **Branch:** `feat/runtime-rust` (fork-only) · **Status:** approved

## Goal

Make `runtime-rust/README.md` a **succinct, human-readable, browseable** document
(intro · usage · FFI usage · static compilation · the examples + static tables ·
glossary) and relocate everything else. Cut the docs/ archaeology, move the history
log under `docs/`, and surface machine-measured numbers as *provenanced* (timestamp
+ platform), not as opinion. Honours the priority order **security > correctness >
soundness > efficiency > completeness > readability** — this work is mostly a
**readability** win that must not regress the higher principles (no content with
forward/reference value is lost; it is relocated, not deleted).

Current README is **1228 lines**; target after the move is **~550 lines**
(aspirational — the achieved figure was 735 lines per `docs/PROGRESS.md`; the
~550 target was not fully met).

## Non-goals

- **Do NOT touch the README region ABOVE `## Getting started`** (title, intro,
  `## Contract`) — maintainer-owned per `runtime-rust/CLAUDE.md`. The intro is kept
  verbatim.
- **Do NOT rewrite technical content** — relocate it verbatim into
  `TECHNICAL-DETAILS.md`. The only prose edits are the specific readability fixes
  in §3 + a light skim-flow pass.
- **Do NOT change the CI workflow's pinned GHC** (`9.6.7` in `examples-sweep.yml`
  is correct for reproducible CI). Only the README *instructions* drop the hard pin.
- No new features; no codegen/runtime changes beyond the provenance capture in two
  sweep scripts + the generator.

## 1. Documentation file-structure changes

### 1a. Wipe (git rm), keep the directories

| Path | Action | Note |
|---|---|---|
| `docs/superpowers/plans/` (all 10) | `git rm` | shipped; history is in `PROGRESS.md` + git. Keep `plans/` dir via `.gitkeep`. |
| `docs/superpowers/specs/` (shipped) | `git rm` | KEEP the still-referenced ones: `2026-06-16-dbdec-subsystem.md`, **all** `2026-06-15-skyshop-rs-*` (memory references the glob), `2026-06-12-rust-multibackend-entry-model.md`, **and this overhaul's own spec**. Wipe the rest. Keep `specs/` dir. |
| `docs/rust-example-conquest-registry.md` | `git rm` | dated tracker; repoint the `rust-examples-baseline` memory note → `PROGRESS.md`/skydex. |
| `docs/escalated-decisions.md` | `git rm` | user classified as history. |
| `docs/upstream-pr-proposals.md` | `git rm` | parked; user classified as history. |
| `docs/adr/0001-sky-value-types-stay-transparent-aliases.md` | extract → `git rm` | **Lift the load-bearing decision** ("Sky value types stay transparent type aliases, not newtypes — why") into `CLAUDE.md` (`## Agent learnings` → Foundational understanding), then wipe the file. Keep `adr/` dir via `.gitkeep` for future ADRs. |

**Reference-survivor check (must pass after the wipe):** `rg` across `CLAUDE.md`,
`README.md`, the plugin skills, and the memory dir for any link to a wiped file →
zero dangling refs (each repointed or removed).

### 1b. Move the history log under docs/

- `runtime-rust/PROGRESS.md` → `runtime-rust/docs/PROGRESS.md` (`git mv`).
- Update every writer/reader of it:
  - `runtime-rust/CLAUDE.md` — the settled-rule block ("Log every step to
    `PROGRESS.md`" → `docs/PROGRESS.md`); the allowed-root-`.md` list drops
    `PROGRESS.md` → **only `CLAUDE.md` + `README.md`** at `runtime-rust/` root.
  - Plugin skills referencing `PROGRESS.md`: `update-docs`, `prune-archaeology`,
    `autonomous-swarm`, `push`, `sync-with-upstream`, `keep-go-parity`,
    `quality-audit` (grep the whole `plugins/sky-rust-backend/` tree + the mirrored
    `~/.claude/skills/sky-rust-backend/` if present).

### 1c. Create `runtime-rust/docs/TECHNICAL-DETAILS.md`

Absorbs the deep README sections **verbatim** (a header note: "Deep internals for
the Sky Rust backend. The user-facing intro/usage/tables live in
`../README.md`."). Sections moved (see §2). README links to it once.

## 2. README restructure (keep vs move)

### Stays in README (intro · usage · FFI usage · static · tables · glossary)

1. `## Contract` (untouched — above `## Getting started`)
2. `## Getting started` (+ all §3 readability fixes)
3. `## Project status` — badge + the new **provenance headline** + the three
   **legend tables** (Round-trip, Equiv-modes, Perf-columns) + the examples table +
   the perf verdict (provenanced) + `### Sweep summary (by equivalence mode)` (kept).
4. `## Static & cross compilation` — static **usage** + both static tables (the CI
   cross-OS `AUTOGEN:static-table` + the local size-benchmark table) + a **1-line
   allocator summary** that links to the moved 2×2 subsection in TECHNICAL-DETAILS.
5. **`## FFI usage`** (new top-level heading) — lift `### sky.toml Rust fields` +
   the "Reaching async / framework crates" wrapper note out of `## Architecture`.
6. `## Known limitations` (kept — user-facing).
7. `## Glossary` (kept).

### Moves to `TECHNICAL-DETAILS.md`

- `## Architecture` minus the FFI-usage bits — i.e. Rust-vs-Go divergent
  strategies, console serving, hub read kernels, telemetry spill, pub/sub broker,
  Sky.Live `LiveReq`, closure-Model serialization guard, multibackend entry,
  Std.Ui parity, `### Modification boundaries`, `### Cross-backend rules`.
- `## Verification state`
- `## Error type`
- `## Soundness, correctness and security`
- `## Build performance & DX`
- The allocator **2×2 deep-measurement** subsection (from Static & cross
  compilation) — the README keeps a 1-line summary + a link to it here.

## 3. README readability fixes (explicit)

1. **No hardcoded GHC.** In `## Getting started` replace pinned `9.6.7` / `9.6`
   install steps with "**GHC ≥ 9.6.7**" phrasing (let `ghcup`/`cabal` resolve).
   (CI's `examples-sweep.yml` pin stays.)
2. **Inline anchor links.** Each of the three "Now continue with **Clone,
   Fast-build env, and Build the compiler** below." lines (Linux/macOS/Windows)
   becomes three markdown links → `#clone-the-repo-all-oses` ·
   `#fast-build-env-all-oses` · `#build-the-sky-compiler-all-oses` (GitHub
   auto-anchors; verify the target headers' slugs).
3. **Consistency — macOS musl command inside the code block.** The macOS
   cross-compile/musl instruction currently sits as prose outside the fenced block;
   move the actual command **into** the `bash` code block for copy-paste, matching
   the Linux section.
4. **`Why:` blocks as topics.** The Fast-build-env `Why:` paragraph (and any other
   `Why:` prose) → line break after `Why:`, `-` bullet per reason, **a line break
   at every semicolon**. Reference target wording (the user's example):
   shared `CARGO_TARGET_DIR` reuse · sccache crate-object cache · `CARGO_INCREMENTAL=0`
   mandatory-with-sccache · adapt PATH on macOS/Windows · the three export lines are
   load-bearing — each its own bullet.
5. **Inline `·`-lists → tables.**
   - **Round-trip** ("`cli` = stdout · `server` = curl boot/serve · …") → 2-col
     table (Shape | How RUN is exercised).
   - **Perf columns** ("Thru (…↑) · RSS (…↓) · Cold · Bin … `—` = … `n/a` = …") →
     table (Column | Meaning | Better direction) + a note row for `—`/`n/a`.
   - **Equiv modes** ("stdout = … · body N = … · …") → table (Mode | Means),
     placed **before** the examples table (it is the table's legend).
6. **Provenance** (see §4) on the verdict + a new headline above the examples table.
7. **Skim-flow pass.** Light prose connective tissue + trimming so the kept
   sections read as a human document, not a machine dump (the "readability"
   principle) — without altering technical claims.

## 4. Provenance (machine-measured, not opinion)

A one-line banner, regenerated inside the fenced regions so it never goes stale:

> _Machine-measured · `<UTC stamp>` · `<runner> <os> (<arch>)` · `<sweep>` —
> regenerated by `readme-tables.py`, not hand-edited._

**Capture.** `examples-perf-sweep.sh` and `static-perf.sh` each write a sibling
`*.provenance` line next to their TSV: `stamp` (the existing run stamp) · `os`
(`${RUNNER_OS:-$(uname -s)}`) · `arch` (`$(uname -m)`) · `runner`
(`GitHub Actions` when `$GITHUB_ACTIONS == true`, else `$(hostname -s)` / `local`).

**Emit.** `readme-tables.py` reads the newest matching `*.provenance` and prepends
the banner inside `AUTOGEN:examples-table`, `AUTOGEN:perf-verdict`, and
`AUTOGEN:static-table`. Missing provenance → derive stamp from the TSV filename +
`runner = unknown`. Local runs honestly show the local host.

**Round-trip preserved.** The banner is part of the generated body, so
`readme-tables.py {examples,static} --check` still round-trips exactly.

## 5. Skill / governance updates

- **`update-docs` SKILL** — its section list (items 1–10) is rewritten to the new
  slim README structure; it gains **`TECHNICAL-DETAILS.md`** as a second maintained
  file (the moved sections regenerate there now, not in README); `PROGRESS.md`
  input path → `docs/PROGRESS.md`; the AUTOGEN-fence + sidecar rules carry forward.
- **`CLAUDE.md`** — settled-rule block updated for the `docs/PROGRESS.md` path, the
  2-file allowed-root list, the TECHNICAL-DETAILS.md split (README = slim
  user-facing; TECHNICAL-DETAILS = internals); ADR decision lifted into
  `## Agent learnings`.

## 6. Verification

- `readme-tables.py examples --check` AND `static --check` exit 0 (round-trip holds
  after the provenance banner + fence relocation).
- `rg` finds **zero** dangling refs to any wiped file across `CLAUDE.md`,
  `README.md`, `docs/`, the plugin skills, and the memory dir.
- `rg 'PROGRESS\.md'` shows every reference points at `docs/PROGRESS.md` (none at
  the old root path) — except historical mentions inside `docs/PROGRESS.md` itself.
- README ≤ ~600 lines; `TECHNICAL-DETAILS.md` contains every moved section (diff the
  moved headers: present in TECHNICAL-DETAILS, absent in README).
- All three new legend tables render as GitHub Markdown tables; the 3 anchor links
  resolve to existing header slugs.
- Markdown lint: no broken relative links (`README.md` → `docs/TECHNICAL-DETAILS.md`
  and `docs/PROGRESS.md`).
- Pre-final gate (security/correctness/soundness): the provenance capture adds no
  Sky-reachable path; the generator changes stay total (missing-file → fallback,
  no crash). Docs-only otherwise.

## 7. Out-of-scope follow-ups (noted, not done here)

- Auto-writing real per-row Build/Run/Equiv (the badge already carries live status).
- Any TECHNICAL-DETAILS.md content rewrite/pruning beyond relocation.
