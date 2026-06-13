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

4. **Reconcile against settled decisions** (idempotency, code-level + ledger) —
   a finding is already settled if its site carries a `SKY-RUST-AUDIT:` marker (see
   the convention below) OR it has a matching row in the README ledger. **Drop**
   settled findings whose decision still matches the code; **keep** NEW ones and
   any `SKY-RUST-AUDIT:DEFERRED` (deferred always resurface). The inline marker is the
   primary key — a human or the next audit sees the decision *at the code*.

5. **Walk the developer through each remaining problem, one at a time:**
   present **location · why it's a problem · pros & cons (accept-as-is vs fix) ·
   your recommendation**, then ask **agree or disagree?** Record the decision
   BOTH inline (greppable marker at the site) AND in the README ledger:
   - **Agree (accept)** → irreducible / cost-and-risk of fixing exceeds that of
     accepting. Add `// SKY-RUST-AUDIT:ACCEPTED (<dev>, <date>) — <why> [ledger #N]` at
     the site (+ the narrowest `#[allow(...)]` if a lint applies); add the ledger row.
   - **Disagree** → ask which: **brainstorm a fix now** (invoke
     **superpowers:brainstorming** → plan → implement; when fixed the marker +
     ledger row are *deleted* — the code changed), OR **defer** → add
     `// SKY-RUST-AUDIT:DEFERRED (<dev>, <date>) — <why> [ledger #N]` at the site and a
     row under "Deferred for investigation".
   - `<dev>` = `git config user.name` (fallback `$USER`); `<date>` = today (UTC).

6. **Mirror every decision in the README ledger in the same pass.** The inline
   markers are the code-level truth; the ledger is the central index. Report:
   hard-gate verdict, decisions taken (accepted / fixed / deferred, each
   attributed), and the cosmetic-lint count handled in bulk.

### Marker convention (terminology)

"Agreed/disagreed" is the *act*; the inline tag records the *outcome*, so it's
greppable as a state:

| Tag | Means | Disposition |
|---|---|---|
| `SKY-RUST-AUDIT:ACCEPTED (<dev>, <date>) — <why> [ledger #N]` | developer **agreed** it's an acceptable / irreducible compromise | a known, signed-off limitation |
| `SKY-RUST-AUDIT:DEFERRED (<dev>, <date>) — <why> [ledger #N]` | developer **disagreed** but deferred a fix for investigation | a known issue awaiting a fix |

`grep -rn 'SKY-RUST-AUDIT'` → every settled decision · `…:ACCEPTED` → accepted
compromises · `…:DEFERRED` → the known-issues backlog. Fixed problems carry **no**
marker (the code changed); cosmetic lints get a plain `// reason`, not a marker.

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
