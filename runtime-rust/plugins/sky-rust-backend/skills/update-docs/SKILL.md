---
name: update-docs
description: "Commit pending Rust-backend code changes, then refresh runtime-rust/README.md to reflect current status and commit it. Use when the user asks to update the Rust docs / sync the README / commit pending work in the Sky compiler repo (feat/runtime-rust branch). Trigger: /sky-rust-backend:update-docs."
---

# update-docs

Commit all pending work in the Sky compiler repo (`feat/runtime-rust` branch),
then refresh `runtime-rust/README.md` to reflect current state.

## Steps (execute in order, no exceptions)

### Step 1 — Commit pending code changes

Run `git status --short` to see what's dirty.

- **If nothing is dirty:** skip to Step 2.
- **If there are changes:**
  1. Read every modified/untracked file that's not gitignored.
  2. If the changes added/renamed code symbols, run
     **`sky-rust-backend:informative-naming`** over them first — fix
     under-informing names before they land (cheaper now than after).
  3. Write a commit message that accurately describes what changed (follow the
     project's `<type>(<scope>): <summary>` convention, e.g.
     `fix(rust): …` / `feat(rust): …` / `refactor(rust): …`).
  4. Stage all relevant files (`git add`) — exclude build artefacts
     (`sky-out/`, `dist-newstyle/`, `.skycache/`, `target/`).
  5. Commit. (No `Co-Authored-By` trailer — the repo convention forbids it.)

### Step 2 — Consolidate root docs, then refresh `runtime-rust/README.md`

**Enforce the root-`.md` policy first.** At `runtime-rust/` root, ONLY
`CLAUDE.md` and `README.md` may exist. If any other root `.md` is present (a
`*_LEDGER.md`, `CONTEXT.md`, an `UPSTREAM-*.md`, a stray notes file), **fold its
still-relevant content into the right `README.md` section** (decisions →
soundness/decision ledger; glossary → Understanding-the-project; TODOs/plans →
roadmap + divergences checklist) and **`git rm` the file** in the same commit.
Never create a new standalone root `.md`. (`docs/` subdir files are exempt.)

Read the current `runtime-rust/README.md` to understand its structure (do NOT
skip this — the file may have changed since the skill was written).

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

- [ ] Any `[ ]` checklist row that is actually done? → flip to `[x]` or delete.
- [ ] Any limitation/known-issue row describing a bug that's since fixed? → delete it.
- [ ] Any metric / number (binary size, error count, line count, example count) NOT re-verified this run? → delete it (don't carry stale numbers).
- [ ] Any "currently / for now / WIP / TODO(date) / temporary" note whose condition is resolved? → delete it.
- [ ] Any example marked ✅ that no longer exists, or ❌ that now passes? → correct the mark.
- [ ] Any section that contradicts another? → reconcile to the true value.

Then update it to reflect **today's actual state**. The README must contain these
sections (rewrite each from scratch based on what you observe in the repo):

1. **Architecture** — pipeline diagram (Sky → Haskell → AST → Rust codegen → binary).
2. **Modification boundaries** — which directories are in-scope without permission.
3. **Cross-backend rules** — the 6 load-bearing rules (Go = production, never
   break Go, Go FFI at `.skycache/ffi/` root, Rust in `.skycache/ffi/rust/`, etc.).
4. **`sky.toml` Rust fields** — all active sections: `[project]`, `["rust.dependencies"]`,
   `[rust]`, `[rust.shims]` with annotated examples.
5. **Verification state** — list every example that builds and runs. Check
   `runtime-rust/tests/sky/` and any Sky examples tested with `--target rust`. Mark each
   ✅ or ❌ with one-line notes. Read `git log --oneline -10` to catch recent additions.
6. **Module structure** — `runtime-rust/src/sky_runtime/` file map.
7. **FFI codegen coercion rules** — `argCall` and `coerceRet` tables (from
   `src/Sky/Build/FfiGen.hs emitRustFnSimple`).
8. **CLI usage** — `sky build/run/check/test/add` with `--target rust`.
9. **Known limitations** — table with Description and Workaround columns.
10. **Remaining work** — Short / Medium / Long term.

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
