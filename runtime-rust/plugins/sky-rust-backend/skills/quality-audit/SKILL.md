---
name: quality-audit
description: Deep Rust soundness / security / efficiency audit of the runtime-rust crate (or a generated example crate), beyond the per-commit clippy gate. Surfaces every panic vector, unsafe block, dyn Any / downcast, lossy cast, and undocumented #[allow]; then walks the MATERIAL findings with the developer one-by-one (why + pros/cons), forcing an attributed, dated decision — agree (consciously accept) or disagree (brainstorm a fix now, or defer for investigation) — recorded in the README "Soundness, correctness and security problems" ledger. Use when the user asks to audit/harden the Rust runtime, check for panic vectors / unsafe / Any / footguns / unsound or inefficient code, or do a soundness/security pass. Trigger: /sky-rust-backend:quality-audit.
---

# quality-audit

The deep, **interactive, sign-off-driven** soundness/quality pass over the Rust
runtime — beyond the per-commit clippy gate (`scripts/verify-rust-target.sh`).
The standard is `runtime-rust/CLAUDE.md` **"NO RUNTIME ERRORS — existential"**.
Every *material* finding ends in an **attributed, dated developer decision** in
the README **"Soundness, correctness and security problems"** ledger — nothing is
left in limbo, nothing rubber-stamped. The script harvests facts; the developer
decides; you record.

## Workflow (every invocation)

1. **Run the harvester** (~5–10 min — clippy ×2 + tests; background + wait):
   ```bash
   bash runtime-rust/scripts/quality-audit.sh            # default: runtime-rust/
   bash runtime-rust/scripts/quality-audit.sh examples/07-todo-cli/sky-out/Rust   # generated code
   ```
   Hard gate (`clippy -D warnings` + `cargo test`) + advisory (curated
   restriction/pedantic lints, panic-vector sweep, `unsafe`/SAFETY, `dyn Any`,
   undocumented `#[allow]`). Logs under `~/.cache/sky/quality-audit/`.

2. **Hard gate must be PASS** (`clippy -D warnings` already *denies*
   `unwrap_used`/`expect_used`; + tests). Fix any gate/material defect at root
   first — the no-deferral rule applies; "defer" is never a way to duck a clear fix.

3. **Assemble the MATERIAL problem list** — and ONLY that. Material = real
   non-test panic vectors · undocumented `unsafe` · unsound/payload-dependent
   `dyn Any` · undocumented `#[allow]` · security/correctness defects · material
   efficiency (hot-path clones/allocs) · logic/footguns found by review (lean on
   Gortex `search_ast` / `find_clones` / `analyze hotspots`). The **1000s of
   cosmetic lints are NOT material** — fix the cheap ones, document the rest
   inline at the call site; never drag the developer through them.

4. **Reconcile against the ledger** (idempotency) — read the README
   "Soundness, correctness and security problems". **Drop** problems already
   recorded with a current decision that still matches the code. **Keep** NEW
   problems and previously-**Deferred** ones (deferred always resurface).

5. **Walk the developer through each remaining problem, one at a time:**
   present **location · why it's a problem · pros & cons (accept-as-is vs fix) ·
   your recommendation**, then ask **agree or disagree?**
   - **Agree (accept)** → it's irreducible / the cost-and-risk of fixing exceeds
     that of accepting. Record `Accepted · <dev> · <date>` + the why in the
     ledger, AND add the inline `// INFALLIBLE:` / `// reason` + the narrowest
     `#[allow(...)]` at the site.
   - **Disagree** → ask which: **brainstorm a fix now** (invoke
     **superpowers:brainstorming** → plan → implement → delete the ledger row once
     fixed), OR **defer** → record `Deferred · <dev> · <date>` + the why under
     "Deferred for investigation".
   - `<dev>` = `git config user.name` (fallback `$USER`); `<date>` = today (UTC).

6. **Record every decision in the README ledger in the same pass** — it is the
   durable, attributed record *and* the idempotency key the next audit reconciles
   against. Then report: hard-gate verdict, the decisions taken (accepted /
   fixed / deferred, each attributed), and the cosmetic-lint count handled in bulk.

## Scope + gotchas

- Default target is the **runtime-rust crate** (the persistent, reused surface);
  pass a generated example's `sky-out/Rust` to audit emitted code too.
- **Interactive** — step 5 asks the developer per material problem; don't
  self-approve acceptances. Orthogonal to `sky-rust-backend:keep-go-parity`
  (that proves Go≡Rust *behaviour*; this proves the Rust is *sound*) — not wired
  into it.
- Env baked in: PATH (`ghcup`/`cargo`), `CARGO_TARGET_DIR=$HOME/.cache/sky-rust-target`,
  `sccache`; `--all-features` for runtime-rust (matches the CI gate). Never edit
  runtime files mid-audit.
- Advisory findings never flip the script's exit code (they need judgement);
  only the hard gate + tests do.
