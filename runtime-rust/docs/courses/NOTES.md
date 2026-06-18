# Teaching notes / working state

## Build status (lessons authored)

Course 1 — Sky → Rust Backend
- [x] 00 Landing + roadmap (`course-1-sky-to-rust/index.html`)
- [x] 01 The big picture: the five-stage pipeline (`01-the-big-picture.html`)
- [x] 02 History of the backend (phases 1–11) (`02-history.html`)
- [x] 03 Front end: parse → canonicalise → type-solve (`03-the-front-end.html`)
- [x] 04 Codegen anatomy: the Builder/ modules (`04-codegen-anatomy.html`)
- [x] 05 Kernel routing (Kernel.hs) (`05-kernel-routing.html`)
- [x] 06 Worked shape: CLI ×2 (`06-worked-cli.html`) — REAL output from 01-hello-world + 20-cli-counter builds
- [ ] 07 Worked shape: HTTP server ×2  ← NEXT — build 15-http-server + 30-sse-server-demo (heavier: axum/tokio)
- [ ] 08 Worked shape: Sky.Live ×2
- [ ] 09 Worked shape: Sky.Tui ×2
- [ ] 10 Worked shape: Sky.Webview ×2
- [ ] 11 FFI: auto-binding real Rust crates + the wrapper-crate pattern
- [ ] 12 Soundness: "no panic from well-typed Sky" + the corner cases

Course 2 — GitHub CI  ✅ COMPLETE (7/7)
- [x] 00 Landing + roadmap (`course-2-github-ci/index.html`)
- [x] 01 What is CI? (from zero)
- [x] 02 Your first workflow (`02-your-first-workflow.html`)
- [x] 03 Matrices, caching, artifacts (`03-matrices-caching-artifacts.html`)
- [x] 04 Anatomy of examples-sweep.yml — the gating job (`04-the-gating-sweep.html`)
- [x] 05 Dispatch-only jobs: perf + static-perf (`05-dispatch-only-jobs.html`)
- [x] 06 The CI→README automation (`06-ci-to-readme.html`)
- [x] 07 Modify it safely (`07-modify-it-safely.html`)

Reference docs
- [x] Glossary (`reference/glossary.html`)
- [ ] Cheat-sheet: the Builder/ module map
- [ ] Cheat-sheet: GitHub Actions syntax

## Grounding sources used
- Compiler pipeline research (Explore agent, 2026-06-18): entry `generateRust` →
  `src/Sky/Generate/Rust/Project.hs:generateRustProject`; Builder modules
  (Kernel/ExprEmitter/ModuleEmitter/Emitter/TypeRenderer/Types/Walker/Naming/
  Pattern/SigRegistry/TypeEmitter). Front end: `Sky.Parse.Module.parseModule`,
  `Sky.Canonicalise.Module.canonicaliseWithDeps`, `Sky.Type.Solve` (SolvedTypes).
- History research (Explore agent, 2026-06-18): `runtime-rust/docs/PROGRESS.md`
  grouped into 11 phases.
- CI: `.github/workflows/examples-sweep.yml` + `runtime-rust/scripts/` (known from
  the docs-overhaul work).

## Preferences observed
- User wants DEPTH + source citations, "two examples of every shape", reasons for
  every change, common + corner cases.
- Beautiful, self-contained HTML with graphics/animations/schemas/summaries.
- Honesty about what is and isn't built yet (the roadmap marks TODO lessons).

## Open question for the user
- Directory: chose `runtime-rust/docs/courses/` (convention). User typed
  `docs/courses/` — offered to relocate if they prefer repo-root.
