# Bumping editions across the Sky Rust stack

> **Status:** runbook (not yet executed). Written 2026-06-27; simplified the same
> day after the oracle pivot (below).
> **Scope:** moving the Rust stack to **Rust edition 2024** uniformly.
> **Precondition that makes this cheap:** `runtime-rust` has **no external
> consumers**, so breaking changes are free *now*. This window closes the moment
> anything ships against it.

## Pivot that simplified this runbook (2026-06-27)

The fork's **Haskell→Rust backend is abandoned**; `runtime-rust` is **canonical
and ours**, and the Sky Rust compiler (`sky-rust`) is the sole Rust toolchain.
Correctness is now **behavioural parity with anzellai's mainline (Haskell frontend
+ Go backend/runtime)**, not byte-identity with any Haskell-emitted Rust.

Two consequences for *this* runbook:
- **No cross-repo coordination.** The emitted-project edition is now **purely
  ours** (chosen by the `sky-rust` Rust backend). There is no Haskell Rust emitter
  to bump and no golden to regenerate from upstream. The whole change lives inside
  **our** two projects: `sky-rust` and `runtime-rust`.
- **The emitted-Rust check is a self-owned snapshot**, not an upstream byte-diff —
  so an edition change just means refreshing that snapshot via `insta` review.

What did **not** change: see the coupling below — it is intrinsic to
copy-vendoring and survives the pivot.

## The one coupling that remains: copy-vendoring

There are three independent "edition" knobs — do not conflate them:

1. **Language edition** (`Cargo.toml … edition`) — language semantics for a crate's
   source.
2. **rustfmt style edition** (`rustfmt.toml … style_edition`) — formatting only;
   cosmetic, safe to bump anywhere independently.
3. **The emitted Sky project's edition** — the edition `sky-rust` writes into each
   generated project's `Cargo.toml`.

`runtime-rust` is **vendored by copy** (`mod sky_runtime;`) into each generated
project, so **its source is recompiled under the *generated project's* edition**,
not under `runtime-rust`'s own crate edition. Therefore the runtime's *effective*
edition is whatever the emitted project uses: if the runtime source uses an
edition-2024-only construct while emitted projects are still 2021, it compiles in
`runtime-rust`'s own tests but **breaks every generated program**.

Rule: **the runtime source and the emitted-project edition must agree.** Bump the
runtime to be valid under the emitted edition *before* (or together with) bumping
the emitted edition.

## What we are NOT doing

- **Not** switching from copy-vendoring to a crate dependency (that's a separate
  decision driven by the static-binary/offline story, tracked in
  `repo-layout-and-mirroring.md`).
- **Not** adopting edition-2024-only features gratuitously; the bump is for
  defaults + future-proofing.

## Files touched (all in our two projects)

| Project | File(s) | Change |
|---|---|---|
| `runtime-rust` | `Cargo.toml` (`edition`), `rustfmt.toml` (`style_edition`) | → `2024` / `2024` |
| `sky-rust` | the Rust backend's emitted-`Cargo.toml` template (the `edition = "2021"` literal it writes / the `CARGO_TOML` fixture it embeds) | emit `edition = "2024"` |
| `sky-rust` | `tests/` emission snapshot/fixture | refresh via `insta` review |

Toolchain floor: edition 2024 needs Rust ≥ 1.85. Confirm CI images + contributors.

## Sequencing

> **Timing caveat:** if `sky-rust`'s error-code phases (E/F) are still in flight
> against the current emission fixture, finish them first — don't churn the
> fixture mid-stream. Best bundled with the monorepo reorg (see
> `repo-layout-and-mirroring.md`).

1. **Make `runtime-rust` source 2024-clean.** Flush edition-2024 breakages while it
   can still be checked against 2021 (e.g. `cargo fix --edition` on a scratch
   branch); ensure it compiles cleanly under **both** 2021 and 2024 during the
   transition (it's still recompiled under the emitted 2021 edition until step 3).
2. **Bump `runtime-rust`:** `Cargo.toml edition = "2024"`, `rustfmt.toml
   style_edition = "2024"`. Verify: `cargo fmt --all --check`, `cargo build`,
   `cargo test`, `cargo clippy --all-targets -- -D warnings`, and `cargo +nightly
   miri test` if it has any `unsafe`. Commit.
3. **Bump the emitted edition in `sky-rust`:** change the Rust backend to write
   `edition = "2024"` into generated `Cargo.toml`; update the embedded fixture;
   refresh the emission snapshot (`cargo insta review`). `edition` lives in
   `Cargo.toml`, not `main.rs`, so the emitted `main.rs` should be unchanged —
   investigate if it moves.
4. **Re-green `sky-rust`:** `cargo build && cargo test` (incl. the `SKY_E2E`
   build+run of an emitted project — it now builds under edition 2024 against the
   2024-clean vendored runtime and must still print the expected output);
   `cargo clippy --all-targets -- -D warnings`; `cargo fmt --all --check`. Commit.

## Verification gate

- `runtime-rust`: build + test + clippy(`-D warnings`) + fmt(`--check`) + miri (if any unsafe) green at edition 2024.
- `sky-rust`: full workspace build + test + clippy + fmt green; the emission snapshot reviewed/accepted; `SKY_E2E` build+run of an emitted project green under edition 2024; **behavioural parity** with the Go reference unchanged.
- Grep both projects for `edition = "2021"` / `style_edition`; only intentional cases remain.

## Rollback

Each step is its own commit in its own project and is independently revertable.
Steps 1–2 (runtime 2024-clean + its own edition) are safe to keep regardless,
since 2024-clean source is also valid 2021 source. Step 3 (emitted edition +
snapshot) reverts by restoring the `edition = "2021"` literal + the prior
snapshot.

## One-line summary

Post-pivot the edition bump is a **two-project, in-house change** (`runtime-rust`
+ `sky-rust`) with no upstream coordination; the only intrinsic coupling is that
copy-vendoring recompiles the runtime under the emitted edition, so make the
runtime valid under the new edition first, then bump the emitted edition and
refresh the self-owned snapshot. Formatting edition is uncoupled and movable
anytime.
