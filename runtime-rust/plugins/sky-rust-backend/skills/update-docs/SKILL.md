---
name: update-docs
description: "Commit pending Rust-backend code changes, then refresh runtime-rust/README.md to reflect current status and commit it. Use when the user asks to update the Rust docs / sync the README / commit pending work in the Sky compiler repo (feat/runtime-rust branch). Trigger: /sky-rust-backend:update-docs."
---

# update-docs

Commit all pending work in the Sky compiler repo (`feat/runtime-rust` branch),
then refresh `runtime-rust/README.md` to reflect current state.

**This skill is the SOLE writer of `runtime-rust/README.md`** (settled rule in
`runtime-rust/CLAUDE.md`). No other workflow edits the README — advancing work logs
to `runtime-rust/docs/PROGRESS.md` instead. The README is a *pristine current-state
snapshot*: **NO history, dates, phases, tiers, SHAs, PR/issue numbers, or
changelog language** — only what the backend IS right now. Regenerate each section
from current truth, reading three inputs: **`docs/PROGRESS.md`** (the dated step log),
**`git log`**, and **the actual current source**. History belongs in docs/PROGRESS.md;
generalizable learnings/pitfalls in `CLAUDE.md`'s `## Agent learnings` — never in
the README. (Typically run as a background session when called.)

## Steps (execute in order, no exceptions)

### Step 1 — Commit pending code changes

Run `git status --short` to see what's dirty.

- **If nothing is dirty:** skip to Step 2.
- **If there are changes:**
  1. Read every modified/untracked file that's not gitignored.
  2. If the changes added/renamed code symbols, run
     **`sky-rust-backend:informative-naming`** over them first — fix
     under-informing names before they land (cheaper now than after).
  3. **Pre-final code gate (security · correctness · soundness — above all).**
     Before staging, ensure the pending code has passed the **`## Pre-final code
     gate`** in `runtime-rust/CLAUDE.md` — an independent, adversarial
     security/correctness/soundness inspection that OUTRANKS every other
     principle. If the authoring step didn't run it, run it now (don't commit
     ungated code). Clean → continue. A principle hurt → rethink + reimplement;
     re-review. No adequate in-boundary fix → REVERT, LOG it in
     `runtime-rust/docs/PROGRESS.md`, and SIGNAL the user — never commit a violation.
     (The README-is-pristine rule supersedes the CLAUDE.md gate's older "LOG in
     `README.md`" wording — history/attempts go to `docs/PROGRESS.md`, not the README.)
  4. Write a commit message that accurately describes what changed (follow the
     project's `<type>(<scope>): <summary>` convention, e.g.
     `fix(rust): …` / `feat(rust): …` / `refactor(rust): …`).
  5. Stage all relevant files (`git add`) — exclude build artefacts
     (`sky-out/`, `dist-newstyle/`, `.skycache/`, `target/`).
  6. Commit. (No `Co-Authored-By` trailer — the repo convention forbids it.)

### Step 2 — Consolidate root docs, then refresh `runtime-rust/README.md`

**HARD BOUNDARY — only edit `README.md` from `## Getting started` DOWNWARD.** Everything
ABOVE the `## Getting started` heading (the title, the CAUTION block, `## Contents`,
`## Introduction` incl. `### Development support`) is the maintainer's hand-written
content — NEVER touch it (do not reword, reformat, or
reflow a single line above `## Getting started`). This skill regenerates ONLY the
sections from `## Getting started` to the end. Before writing, find the `## Getting started`
line and treat every line before it as read-only.

**SECOND BOUNDARY — machine-owned `AUTOGEN` fences are read-only here too.** Any
`<!-- AUTOGEN:<id> BEGIN -->` … `<!-- AUTOGEN:<id> END -->` block is written ONLY
by `runtime-rust/scripts/readme-tables.py` from the CI sweep result files (the CI
`update-readme` job auto-commits them). NEVER hand-edit content between those fences
— regenerate instead: `python3 runtime-rust/scripts/readme-tables.py static` and
`… examples`. Three regions: `AUTOGEN:static-table` (cross-OS static build),
`AUTOGEN:examples-table` (the per-example BUILD·RUN·EQUIV+perf table), and
`AUTOGEN:perf-verdict` (the per-metric geomean parity verdict). You own the PROSE
around each fence (the intro paragraph, the `Equiv modes` legend, the closing
latency note) AND the editorial **sidecar** `runtime-rust/scripts/readme-examples.tsv`
— edit that sidecar (not the table) when an example is added / renamed / its shape /
round-trip / equiv-note changes, then regenerate. The generator owns the table DATA
+ verdict inside the fences. The per-push `headline-check` flags the editorial sweep
headline (`N green · M red`, not fenced) — reconcile that sentence here.

**Enforce the root-`.md` policy first.** At `runtime-rust/` root, ONLY
`CLAUDE.md` and `README.md` may exist. `docs/PROGRESS.md` is the
history/archaeology sink — an INPUT to this skill, never folded INTO the README
(its dated entries stay there; the README distils current state, not history). If
any OTHER root `.md` is present (a `*_LEDGER.md`, `CONTEXT.md`, an `UPSTREAM-*.md`,
a stray notes file), **fold its still-relevant *current-state* content into the
right `README.md` section**, move any **history** into `docs/PROGRESS.md`, move any
**learning/pitfall** into `CLAUDE.md`, and **`git rm` the file** in the same
commit. Never create a new standalone root `.md`. (`docs/` subdir files are
exempt.)

Read the current `runtime-rust/README.md` to understand its structure (do NOT
skip this — the file may have changed since the skill was written).

**WHOLE-FILE COVERAGE IS MANDATORY — this is the #1 failure mode of this skill.**
Drift accumulates exactly in the sections recent work *didn't* touch, so a
"reconcile only what I just changed" pass is the bug. Every run:

1. Enumerate **EVERY** top-level `##` section in the current README:
   `grep -nE '^## ' runtime-rust/README.md`.
2. Reconcile **EACH ONE** against the codebase + `git log` this run, **top to
   bottom**. A section MUST NOT be skipped, left in its prior state, or assumed
   current because the latest work didn't touch it. The default for every
   section is "re-verify from current state and rewrite", not "leave as-is".
3. The reconcile-don't-append rules and the stale-detection checklist below
   apply to **ALL** sections — not just divergences/limitations/roadmap.

**High-drift sections that have gone stale and MUST be rebuilt from current
state every run** (verified stale in practice — do not trust their prose):

- `## Project status` — the `N green · M red` headline drifts as examples land/break (the badge is live, but the editorial count + sweep-summary table age); re-derive from the latest scoreboard.
- `## Known limitations` — fixed limitations linger as open; re-audit against the current runtime + codegen and delete what's resolved.
- `docs/TECHNICAL-DETAILS.md` → `## Soundness, correctness and security` — fixed problems linger as open; re-audit and delete what's resolved (this file is reconciled alongside README every run).

**Run `sky-rust-backend:prune-archaeology` over the README** as you rewrite — it
owns the cut-history + structure-over-prose discipline (tables / bullets /
`[ ]`-todo-lists / ASCII schemas over narration; dates, SHAs, phase-bookkeeping
out; design rationale kept). This skill sets WHAT the README must contain; that
skill sets HOW each section is written.

**PRUNING DISCIPLINE — reconcile, do NOT append.** This is the whole point of
the skill. Each run makes the README a faithful snapshot of CURRENT state — it
is not a changelog. The drift comes from ADDING new wins while leaving stale
content (resolved limitations still listed open, shipped `[ ]` items, dead
metrics, superseded design notes, sections that contradict each other). Hold
these rules over EVERY section:

| Rule | Do |
|---|---|
| **Reconcile, don't append** | For each section, diff its existing claims against current reality (repo + `git log`) and **DELETE** anything no longer true before writing. Never bolt a new paragraph onto stale text. |
| **Checklists are the highest drift risk** | Walk EVERY `[ ]` row in divergences / limitations / roadmap. Verify each against `git log` + the codebase. Flip to `[x]` when shipped; **DELETE** the row when it no longer describes a real gap. A `[ ]` that's actually done is a bug. |
| **No "latest achievements" dump** | FORBIDDEN: appending a "what's new" / "recent work" / changelog blob. History lives in git. If a section reads like a list of recent commits, that's a smell — **rewrite it as the steady-state description**. |
| **Contradiction sweep** | After rewriting, grep across sections for claims that disagree (a limitation marked fixed in one place but open in another, a metric stated two ways, an example ✅ here and ❌ there). Resolve every conflict to the one true value. |

**Stale-detection checklist — run before committing. Each "yes" = fix it:**

- [ ] **Coverage gate:** was EVERY `##` section from the `grep -nE '^## '` enumeration reviewed + reconciled this run? Any section still in its prior state by default? → go back and reconcile it; do not commit until all are covered. A section whose claims you cannot verify must have its unverifiable claims **deleted** (per the no-stale-numbers rule), not left as-is.
- [ ] Any `[ ]` checklist row that is actually done? → flip to `[x]` or delete.
- [ ] Any limitation/known-issue row describing a bug that's since fixed? → delete it.
- [ ] Any metric / number (binary size, error count, line count, example count) NOT re-verified this run? → delete it (don't carry stale numbers).
- [ ] Any "currently / for now / WIP / TODO(date) / temporary" note whose condition is resolved? → delete it.
- [ ] Any example marked ✅ that no longer exists, or ❌ that now passes? → correct the mark.
- [ ] Any section that contradicts another? → reconcile to the true value.

Then update it to reflect **today's actual state**. README is now a SLIM
user-facing document; the deep internals live in `docs/TECHNICAL-DETAILS.md` (see
"Second maintained file" below). The maintainer-owned region ABOVE `## Getting started`
(`## Contents`, `## Introduction` incl. `### Development support`) is read-only.
From `## Getting started` DOWNWARD the README must contain ONLY these `##` sections,
in this order (rewrite each from current truth):

1. **`## Getting started`** — the 3-OS install (Linux/macOS/Windows) + Clone +
   Fast-build env + Build the Sky compiler + Running the examples + `### FFI usage`
   (auto-FFI lead + `#### sky.toml Rust fields` + the "Reaching async / framework
   crates" wrapper-crate note) + `### CLI reference` + `### Rust-backend environment
   variables`. Keep GHC de-pinned (`GHC >= 9.6.7`), the cross-OS "continue with"
   anchor links, the macOS musl command inside a code block, the `Why:` bullet block.
2. **`## Project status`** — the live sweep **badge** + the `N green · M red`
   headline + the `### Sweep summary (by equivalence mode)` table + the `### Examples`
   table. The examples table, the perf verdict, and the cross-OS static table are
   **`AUTOGEN`-fenced** (see the Second Boundary) — do NOT hand-write them; their
   editorial columns come from `runtime-rust/scripts/readme-examples.tsv`.
   Build/Run are a hardcoded ✅ snapshot (the CI writer only runs on a green sweep);
   the live per-example pass/fail is the badge's run summary.
3. **`## Static and cross compilation`** — static usage + the static-build matrix +
   the `AUTOGEN:static-table` + the local size-benchmark table + the 1-line
   allocator summary that links to the 2×2 in TECHNICAL-DETAILS, then `### Static
   compilation` + `### Cross compilation`.
4. **`## Known limitations`** — table with Description and Workaround columns.
5. **`## Learning materials`** — learning resources + the `### Glossary` term table.

**Second maintained file — `docs/TECHNICAL-DETAILS.md`.** The deep sections
(`## Architecture` incl. modification boundaries + cross-backend rules + FFI
coercion rules, `## Verification state`, `## Error type`, `## Soundness,
correctness and security`, `## Build performance & DX`, `## Allocator 2×2
measurement`) live THERE, not in README. Reconcile BOTH files each run: README
stays the slim user-facing snapshot; TECHNICAL-DETAILS holds the internals. Read
`docs/PROGRESS.md` (moved from the root) as the history input. Sources for the
Project-status data: `~/.cache/sky/examples-sweep/sweep-*.table` (build/run/equiv)
+ `~/.cache/sky/examples-perf-sweep/perf-*.tsv` (perf ratios) + `docs/PROGRESS.md`
+ `git log`.

(No "Module structure" section and no "Safety invariant" section — neither is
mandated nor produced; do not re-add them.)

**Accuracy rules for the README rewrite:**
- Only mark an example ✅ if you have evidence it builds *and runs* (from git log,
  earlier in this session, or by actually building it now).
- Do not copy stale numbers (binary sizes, line counts, etc.) — omit any metric
  you cannot verify.
- Do not include session notes, V/X/T priority backlogs, or numbered bug lists
  — those belong in commits, not the README.

Write each section per the **`sky-rust-backend:prune-archaeology`** house style
(tables / bullets / `[ ]`-todo-lists / schemas over prose; structure over
narration; succinct but always intelligible).

### Step 3 — Commit the README

```
git add runtime-rust/README.md
git commit -m "docs(rust): sync README — <one-line summary of what changed>"
```
(No `Co-Authored-By` trailer — the repo convention forbids it.)

### Step 4 — Report

Print a short summary:
```
update-docs complete
  code commit : <sha> <message>   (or "nothing to commit")
  readme commit: <sha> sync README — …
  branch: feat/runtime-rust
```

## Constraints

- Never commit `sky-out/`, `dist-newstyle/`, `.skycache/`, `target/`, `*.o`,
  `*.hi` build artefacts.
- Never commit the `sky` binary itself (it lives in `sky-out/sky`).
- Never alter Go backend files. If `git diff` shows changes in
  `src/Sky/Generate/Go/`, `runtime-go/`, or `.skycache/ffi/*.kernel.json` (root),
  stop and warn the user before committing anything.
- Commit message body must describe *what* changed and *why* — not just "updated files".
- Never append a `Co-Authored-By` trailer — the repo convention forbids it.

## Capture learnings (self-improving loop)

After this skill's work completes, record any **significant, verified,
generalizable** learning — a non-obvious pitfall, a deeper foundational insight,
or a secure/correct/sound optimization — to the **`## Agent learnings`** section
of `runtime-rust/CLAUDE.md`, so future agents improve. Obey that section's rules:
**only if secure, correct, and sound + verified**; **reconcile (update / dedupe /
prune), never blind-append**; **skip when nothing significant** — most runs add
nothing, and manufacturing an entry is worse than none.
