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
  2. Write a commit message that accurately describes what changed (follow the
     project's `<type>(<scope>): <summary>` convention, e.g.
     `fix(rust): …` / `feat(rust): …` / `refactor(rust): …`).
  3. Stage all relevant files (`git add`) — exclude build artefacts
     (`sky-out/`, `dist-newstyle/`, `.skycache/`, `target/`).
  4. Commit with the message. Append:
     ```
     Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
     ```

### Step 2 — Refresh `runtime-rust/README.md`

Read the current `runtime-rust/README.md` to understand its structure (do NOT
skip this — the file may have changed since the skill was written).

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

**Doc house style — structure over prose (load-bearing):**

| Prefer | Over |
|---|---|
| **Tables** (status, options, mappings, coverage) | paragraphs comparing things in prose |
| **Bullet points**, one idea each | multi-clause narrative sentences |
| **`[ ]` / `[x]` / `[D]` todo-lists** for roadmap/open work | prose "we did X, then Y, now Z" |
| **ASCII schemas / pipeline diagrams** | describing data flow or layering in words |
| a stated **design decision + its why** | the chronology of how it was reached |

- **Succinctness is a value — but never at the cost of intelligibility.** Cut
  words, not understanding. If a sentence of *why* is load-bearing, keep it.
- **Favour systemic understanding over prosaic history.** A reader should grasp
  how the system fits together and *why it's shaped this way* — not the sequence
  of commits that got here. Dates, SHAs, "previously/now" narration, phase/step
  bookkeeping → out (see the `prune-archaeology` skill).
- Reach for a diagram or table the moment you're about to write a paragraph that
  enumerates, compares, maps, or sequences. Prose is the fallback, not the default.

### Step 3 — Commit the README

```
git add runtime-rust/README.md
git commit -m "docs(rust): sync README — <one-line summary of what changed>

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

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
- Append the `Co-Authored-By` trailer to every commit.
