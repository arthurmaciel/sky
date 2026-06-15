---
name: informative-naming
description: Audit Rust-backend code (and its Haskell codegen) for names that under-inform — unjustified abbreviations (dep/res/val for dependency/result/value), structural names that describe the shape instead of the meaning (depLine vs cargoDependencyLine), opaque wrappers that say less than what they wrap (ok_res vs SkyResult::Ok). Favours names that tell a first-time reader WHAT a thing is and WHAT it's for. Called by sky-rust-backend:quality-audit (readability is a first-class principle). Trigger: /sky-rust-backend:informative-naming.
---

# informative-naming

Code is read far more than it is written. A name is the cheapest documentation
there is — and the most expensive when it lies or hides. This skill hunts names
that **under-inform** and converges them on the clearest form. It is a
first-class lens of `sky-rust-backend:quality-audit`, ranked with security,
correctness, soundness, consistency, and efficiency.

**Scope — the whole Rust backend, both languages:**

| Surface | Paths |
|---|---|
| Rust runtime crate | `runtime-rust/src/**` (+ generated-code shapes it emits) |
| Haskell Rust-codegen | `src/Sky/Generate/Rust/**`, `src/Sky/Build/Rust/**`, `src/Sky/Sky/Toml/Rust.hs` |

**Timing.** Apply **opportunistically** on touched/added symbols every commit
(via `update-docs` / `quality-audit`). A **full-codebase naming refactor pass**
is planned once the Rust backend stabilizes — run it then over the whole tree,
one module at a time, with the developer signing off the conventions.

## The test

For each name ask: **"Reading this for the first time, does the name tell me what
the thing IS and what it's FOR — or do I have to read the body to find out?"**

If you must read the body, the name under-informs. Prefer the name that wouldn't
have needed the lookup.

## What to flag

| Smell | Example (worse → better) | Why |
|---|---|---|
| **Unjustified abbreviation** | `depLine` → `cargoDependencyLine`; `valOf` → `valueOf`; `res` → `result` | `dep`/`val`/`res` save 4 chars and cost a mental expansion every read. Expand unless the short form is *universally* read at a glance. |
| **Structural, not semantic** | `depLine` (it's a "line") → `cargoDependencyLine` (a Cargo dependency); `…Info` when a precise noun exists | name the *thing in the domain*, not the text shape it happens to take |
| **Obscuring wrapper** | `ok_res(x)` → `SkyResult::Ok(x)` | a one-line helper whose name says LESS than the expression it wraps is a readability regression — drop it for the self-documenting form |
| **One concept, two names** | `find_x` + `lookup_x` for the same op | pick the clearest single name and converge (Gortex `find_clones`) |
| **Misleading / ambiguous** | `data`, `tmp`, `handle` with no qualifier; a name whose type/effect isn't evident at the call site | qualify it so the call site reads true |

## Abbreviations that ARE fine

Universally-read-at-a-glance, in context: `id`, `url`, `http`, `db`, `cfg`,
`ctx`, `fn`, `impl`, `ok`/`err` (as `Result` variants), `lhs`/`rhs`, `i`/`j` for
loop indices, established crate/protocol names. The bar: a domain reader expands
it instantly and the full word adds nothing. `dep`, `res`, `val`, `spec`, `pkg`
usually fail this — the full word is short and clearer.

## Procedure

1. **Find candidates** — `search_symbols` for short/abbreviated identifiers,
   `find_clones` for parallel-but-differently-named helpers, grep for thin
   wrapper bodies (`fn foo(x) { Bar::Variant(x) }`). Size each with `find_usages`.
2. **Propose the clearer name** — unabbreviated, domain-semantic, true at the
   call site. When a wrapper only obscures, propose inlining it.
3. **Rename** — mechanical and compile-checked (`rename_symbol` / a guarded
   find-replace). The compiler is the safety net; verify the build after.
4. **Sign-off** — like every quality-audit finding, the convention is the
   developer's: walk material renames one-by-one (a rename touches many sites).

## When readability conflicts with another principle — ASK

Readability is first-class but not supreme. If the clearer name would hurt
**security / correctness / soundness / consistency / efficiency**, do NOT trade
silently — surface it and ask. Real conflicts:

- A wrapper that looks redundant but earns its name (genuine type-inference
  relief a bare variant can't get; a non-trivial body) — keep it, and make the
  name describe what it does.
- A rename that breaks an upstream/Go-shared seam or a serialized name (wire
  format, serde field, DB column) — those names are contracts, not style.
- A longer name that pushes a hot, dense expression past readability — weigh it.

Default outside those: favour the clearer name.

## Capture learnings (self-improving loop)

After this skill's work completes, record any **significant, verified,
generalizable** learning — a non-obvious pitfall, a deeper foundational insight,
or a secure/correct/sound optimization — to the **`## Agent learnings`** section
of `runtime-rust/CLAUDE.md`, so future agents improve. Obey that section's rules:
**only if secure, correct, and sound + verified**; **reconcile (update / dedupe /
prune), never blind-append**; **skip when nothing significant** — most runs add
nothing, and manufacturing an entry is worse than none.
