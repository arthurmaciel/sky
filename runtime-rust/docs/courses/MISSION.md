# Mission

## Why these courses exist

The Sky → Rust backend is a fork-local effort (`feat/runtime-rust` on
`arthurmaciel/sky`) that transpiles Sky — an Elm-family pure-functional language —
to native Rust with automatic FFI. It is a substantial, novel compiler + runtime +
CI system. The goal of these two courses is to take a **newcomer** and make them a
**capable developer** of this backend: able to read the codegen, follow a Sky
program all the way down to Rust, and modify/extend the CI that guards it.

## The learner

A programmer who is new to *this* codebase (and possibly new to compilers and/or
CI), but comfortable reading code. They want depth, not hand-waving — every claim
grounded in a real source file they can open.

## Success looks like

After Course 1 ("The Sky → Rust Backend — from newcomer to developer") the reader
can:
- narrate the **history** of the backend in thematic phases (what was built, why);
- trace any Sky program **step-by-step** through parse → canonicalise → type-solve
  → Rust codegen → `cargo` binary, naming the functions and files involved;
- explain the common path and the corner cases for each program **shape** (CLI,
  HTTP server, Sky.Live, Sky.Tui, Sky.Webview), with two worked examples each.

After Course 2 ("GitHub CI — Sky → Rust backend as an example") the reader can:
- explain what CI is and why it exists, from zero;
- read and write GitHub Actions workflows from simple to complex;
- fully understand this repo's `examples-sweep.yml` (the cornerstone gate, the
  dispatch/schedule (non-gating) perf/static jobs, the CI→README automation), and **modify/improve
  it** safely.

## Grounding rule

Never trust parametric knowledge. Every lesson cites the actual source
(`src/Sky/Generate/Rust/…`, `runtime-rust/…`, `.github/workflows/…`). When the
code changes, the lesson must be re-grounded.

## Constraints

- Courses live under `runtime-rust/docs/courses/` (fork-only Rust-backend content
  stays under `runtime-rust/docs/`, per the project convention).
- Self-contained HTML/CSS/JS — no CDN — so they open offline in any browser.
- English.
