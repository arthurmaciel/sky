---
name: prune-archaeology
description: Prune development-history "archaeology" from docs (.md) and code comments — chronology, commit/PR/version trails, phase/step/ledger bookkeeping, "was X now Y" narration — while PRESERVING design rationale. Trigger when asked to clean up docs/comments of dev-history cruft. Trigger: /sky-rust-backend:prune-archaeology.
---

# prune-archaeology

Remove **development archaeology** — text that records *how the code got here* —
while keeping every word that explains *what it does now and why it is shaped
that way*. Archaeology accretes in long-lived projects (sweep logs, commit
trails, phase/step plans, "fixed in vX", ledger numbers) and actively misleads a
reader who only needs the current truth.

## The one test

For each candidate line, ask: **"If I were reading this file for the FIRST time
to understand the current code, would this sentence help me — or only tell me
about the past?"**

- Helps understand current behaviour / why a non-obvious choice was made → **KEEP**.
- Only narrates history (when/who/what-changed/what-it-used-to-be) → **CUT**.

When unsure, KEEP. Over-pruning that deletes a load-bearing *why* is worse than
leaving one stale breadcrumb. This skill is conservative by design.

## Structure over prose (how to rewrite what you keep)

Cutting history is half the job; the other half is making what remains
*scannable*. When you compress or rewrite a kept passage, reach for structure:

| Prefer | Over |
|---|---|
| **Tables** (status, options, mappings, coverage) | paragraphs comparing things in prose |
| **Bullet points**, one idea each | multi-clause narrative sentences |
| **`[ ]` / `[x]` / `[D]` todo-lists** for roadmaps / open work | "we did X, then Y, now Z" prose |
| **ASCII schemas / pipeline diagrams** | describing data flow or layering in words |
| a stated **design decision + its why** | the chronology of how it was reached |

- **Succinctness is a value — but never at the cost of intelligibility.** Cut
  words, not understanding; keep every load-bearing *why*.
- **Favour systemic understanding over prosaic history.** The reader should grasp
  how the system fits together and why it's shaped this way — a diagram/table
  that conveys that is worth more than three tidy paragraphs of narration.
- Whenever you're about to write a paragraph that enumerates, compares, maps, or
  sequences, convert it to a table/list/diagram instead. Prose is the fallback.

## Whole-file scope when pruning `runtime-rust/README.md`

When the target is `runtime-rust/README.md`, the sweep is **the entire
regenerated region, every pass** — the `## Getting started` heading DOWNWARD —
not a passed-in snippet and not only the sections touched by recent work.
Archaeology accumulates *precisely* in the sections nobody edited this cycle, so
"recent work didn't touch it" is the reason to scrub a section, not a reason to
skip it.

- **Out of scope — NEVER touch (per `runtime-rust/CLAUDE.md`):**
  - **Everything ABOVE `## Getting started`** (title, intro, `## Contents`,
    `## Introduction`, `## Contract`, …) is the maintainer's hand-written
    content. Do not reword, reformat, or reflow any line above
    `## Getting started`.
  - **`<!-- AUTOGEN:<id> BEGIN -->` … `<!-- AUTOGEN:<id> END -->` fenced
    regions** are machine-owned (written only by
    `runtime-rust/scripts/readme-tables.py` from CI sweep results). Skip them
    entirely — read-only. In `README.md` these are `AUTOGEN:examples-table`,
    `AUTOGEN:perf-verdict`, and `AUTOGEN:static-table`.
- **Enumerate the in-scope sections first:** `rg -nE '^## ' runtime-rust/README.md`,
  then start at `## Getting started` and ignore everything above it. Walk the
  remaining list top to bottom and apply the one-test + structure-over-prose +
  no-stale-dates/SHAs/metrics discipline to EACH in-scope `##` section, leaving
  any AUTOGEN fenced block untouched.
- **Recurring high-drift sections — scrub these by name every pass:** in
  `runtime-rust/README.md`, `## Project status` and `## Known limitations`; in
  `docs/TECHNICAL-DETAILS.md` (where the deep internals now live),
  `## Architecture`, `## Verification state`, and
  `## Soundness, correctness and security`. These have repeatedly gone stale and
  been skipped; treat them as mandatory stops, not optional ones.
- A pass that left any in-scope `##` section unreviewed is incomplete.

## CUT — pure archaeology

- **Chronology**: "previously…", "originally…", "used to…", "as of <date>",
  "(2026-06-14)", "Reinforced YYYY-MM-DD".
- **Commit / PR / issue trails** used only as a timestamp: "fixed in `5ac3aeb1`",
  "closed by #123", "PR13", "landed in v0.16.29" — when the SHA/number adds
  nothing to understanding the current code. (KEEP an issue ref that is the
  canonical spec a reader must follow.)
- **Phase / step / sub-task bookkeeping**: "Phase 2: DONE", "Sub-A.8 T7",
  "Q3", "P0/P1/P4", "epic A/D", "Stage-4", "sub-project D", "tenet 3",
  "ledger #5" — internal plan coordinates that mean nothing to a new reader.
- **"Was X, now Y" narration** where only Y matters: "this returned `()` before;
  now returns `SkyTask`" → keep only the statement of current behaviour, unless
  the *contrast itself* is the warning (see KEEP).
- **Migration/TODO scaffolding that's done**: "migration target for…",
  "temporary bridge until…" once the bridge is permanent or removed.
- **Sweep/verification logs in prose**: "verified 2026-06-14: 32 examples PASS",
  "the older registry is stale" — status that was true at one instant.
- **Changelog-in-comments**: per-version "what changed" lists living inside a
  source comment or a design doc's body (a real CHANGELOG file is fine).

## KEEP — not archaeology

- **Design rationale / invariants**: *why* the code is shaped this way, what
  breaks if you change it. "Width keeps 100% because column-parent widths are
  definite AND it survives the `[width fill, centerX]` cascade." That a bug
  *class* exists is design context; the bug's *date* is not.
- **Counter-intuitive warnings**, even if phrased as a contrast: "must use
  `usesTaskParallel`, NOT `usesTaskRun` — the latter flips `mainIsTask` off and
  the entry drops the task." The contrast is the lesson, not chronology.
- **Parity contracts**: "mirrors Go's `smtp.SendMail` opportunistic STARTTLS" —
  a behavioural spec a maintainer must preserve.
- **Canonical external refs**: an RFC, an upstream doc, a ticket that IS the spec.
- **Roadmap / open-work items** in a living roadmap doc (these describe the
  future, not the past) — but collapse their *completed* history (drop the
  `[x]` items' commit trails, keep a one-line "done" or remove if self-evident
  from the code).

## Procedure

1. **Scope the sweep.** List the target files (one doc, or a code tree). For
   code, prefer one language/dir at a time so judgment stays consistent. When
   the target is `runtime-rust/README.md`, the scope is the regenerated region
   (`## Getting started` downward) — run `rg -nE '^## ' runtime-rust/README.md`
   and review every in-scope `##` section top to bottom (see "Whole-file scope"
   above for the maintainer-owned + AUTOGEN exclusions), with the named
   high-drift sections as mandatory stops. Never narrow to "the parts recent
   work touched".
2. **Read before cutting.** Never blanket-delete by regex — a `2026-` date can
   sit inside a load-bearing sentence. Edit line-by-line / comment-by-comment.
3. **Rewrite, don't just delete.** Often the fix is to *compress*: a 6-line
   "history of this function" comment becomes a 1-line statement of what it does
   and the single invariant that matters.
4. **Roadmap docs**: keep the open `[ ]`/`[D]` items and the current-state
   tables; strip the `[x]` items down to a terse "done" (or cut entirely when
   the code already says it), and delete dated "verified N examples" lines.
5. **Verify nothing breaks.** For code, a comment-only change still must compile
   (you may have removed a comment that was inside a string or doc-test). Run the
   build/test for the touched crate. For docs, re-read top-to-bottom: does it
   still stand alone as a description of the *current* system?
6. **Commit per coherent chunk** with a message like
   `docs: prune development-archaeology from <area> (no behavioural change)`.

## Anti-goals

- Do NOT delete design rationale, invariants, parity contracts, or safety
  comments to hit a "less text" target. Density of *why* should go UP, not down.
- Do NOT touch code logic — comments and docs only (unless a separate task).
- Do NOT remove a roadmap's open items or a real CHANGELOG file.

## Capture learnings (self-improving loop)

After this skill's work completes, record any **significant, verified,
generalizable** learning — a non-obvious pitfall, a deeper foundational insight,
or a secure/correct/sound optimization — to the **`## Agent learnings`** section
of `runtime-rust/CLAUDE.md`, so future agents improve. Obey that section's rules:
**only if secure, correct, and sound + verified**; **reconcile (update / dedupe /
prune), never blind-append**; **skip when nothing significant** — most runs add
nothing, and manufacturing an entry is worse than none.
