---
name: quality-audit
description: Deep Rust soundness / security / efficiency audit of the runtime-rust crate (or a generated example crate) — beyond the per-commit clippy gate. Surfaces every panic vector (unwrap/expect/panic!/unreachable!/todo!), unsafe block, dyn Any / downcast / transmute, lossy cast, and undocumented #[allow], then guides root-cause fix vs. rigorous conscious acceptance (documented + registered). Use when the user asks to audit/harden the Rust runtime, check for panic vectors / unsafe / Any / footguns / unsound or inefficient code, or do a soundness/security pass. Trigger: /sky-rust-backend:quality-audit.
---

# quality-audit

The deep soundness/quality pass over the Rust runtime — the **periodic** audit
that goes beyond the per-commit clippy gate (`scripts/verify-rust-target.sh`).
The standard is `runtime-rust/CLAUDE.md` **"NO RUNTIME ERRORS — existential"**: a
well-typed Sky program must not be able to reach a panic, an `unwrap`/`expect`
abort, an unchecked downcast, an OOB index, or any abort in the generated Rust or
the Sky-reachable runtime. The register of *deliberately accepted* exceptions is
the README **"Soundness attention points"** section — every accepted vector must
be there. The script harvests the facts; **you** make the fix-vs-accept calls.

## Workflow (every invocation)

1. **Run the script** (~5–10 min — clippy ×2 + tests; background + wait):
   ```bash
   bash runtime-rust/scripts/quality-audit.sh            # default: runtime-rust/
   bash runtime-rust/scripts/quality-audit.sh examples/07-todo-cli/sky-out/Rust   # generated code
   ```
   It runs the hard gate (`clippy -D warnings` + `cargo test`), a curated
   restriction/pedantic lint pass (advisory), and grep sweeps for vectors /
   `unsafe` / `dyn Any` / undocumented `#[allow]`. Logs under
   `~/.cache/sky/quality-audit/`.

2. **The hard gate must be PASS.** `clippy -D warnings` (which already *denies*
   `unwrap_used`/`expect_used`) + tests green is non-negotiable — fix before
   anything else.

3. **Triage the advisory findings (the judgement half):**
   - **VECTORS** — for each `unwrap/expect/panic!/unreachable!/todo!` outside a
     `#[cfg(test)]` region: either it's a **real vector → fix at root** (total
     form: `if let`/`match`/`.get()` + a structured-error fallback, never a
     cover-up), or it's **genuinely infallible → consciously accept**: add a
     `// INFALLIBLE:` (or `// SAFETY:`) rationale + the narrowest `#[allow(...)]`
     + a row in the README register. No silent acceptance.
   - **NO-ANY** — each `dyn Any`/`downcast`/`type_id` must be
     **provably-correct-by-construction** (keyed so the one cast can't fail), per
     the runtime-rust/CLAUDE.md no-`interface{}` rule. Anything payload-dependent
     is a defect; reach for per-type monomorphisation (e.g. `TypeId`-keyed
     brokers) instead.
   - **UNSAFE** — every block needs an adjacent `// SAFETY:` doc
     (`undocumented_unsafe_blocks` in the strict pass).
   - **ALLOW** — every `#[allow]` without a justifying comment must get one or be
     removed; reconcile the accepted set against the README register (flag drift
     both ways — a new allow not registered, or a register row no longer in code).
   - **STRICT LINTS** — triage the top lints: fix the cheap soundness ones (lossy
     cast → checked conversion, indexing → `.get()`, `float_cmp` → epsilon),
     accept+document the rest. Efficiency: clones in hot paths, needless
     allocations, reflect-like patterns.
   - **Logic / footguns** — review by reading the flagged regions; lean on Gortex
     (`search_ast` detectors, `find_clones`, `analyze hotspots|dead_code`) for
     structural smells when available.

4. **Report** — hard-gate verdict; then a **must-fix list** (real vectors / unsound
   Any / undocumented unsafe / footguns) and the **consciously-accepted register**
   (each with its one-line justification), reconciled with the README. Apply
   root-cause fixes per the no-deferral rule; a documented workaround is a
   temporary bridge, not a resolution.

5. **If the accepted-exception set changed, update the README "Soundness
   attention points"** in the same pass — the register must always match the code.

## Scope + gotchas

- Default target is the **runtime-rust crate** (the persistent, reused surface);
  pass a generated example's `sky-out/Rust` to audit emitted code too.
- This is orthogonal to `sky-rust-backend:keep-go-parity` (that proves Go≡Rust
  behaviour; this proves the Rust is *sound* regardless of Go) — not wired into it.
- Env baked in: PATH (`ghcup`/`cargo`), `CARGO_TARGET_DIR=$HOME/.cache/sky-rust-target`,
  `sccache`. `--all-features` for runtime-rust (matches the CI gate). Never edit
  runtime files mid-audit.
- The advisory findings never flip the script's exit code (they need judgement);
  only the hard gate + tests do.
