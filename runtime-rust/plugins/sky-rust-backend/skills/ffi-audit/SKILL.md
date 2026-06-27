---
name: ffi-audit
description: "Measure Sky->Rust auto-FFI coverage by running the sky-ffi-inspect-rs inspector across a ~50-crate sample and summarizing what binds (kept functions split into free / constructor-like / accessor-only, with a usability verdict per crate). Resumable, supports partial summaries. Use when the user asks to measure/quantify how many real-world Rust crates the automatic FFI can actually use. Trigger: /sky-rust-backend:ffi-audit."
---

# ffi-audit

Quantify how far Sky's automatic Rust FFI actually reaches across real-world
crates. Runs the embedded inspector on a representative ~50-crate sample and
summarizes the *shape* of what survives the nameability filter — which is what
tells you whether a crate is usable, not the raw kept count.

The runner is committed alongside this skill: `ffi_audit.py` (same folder). Do
NOT regenerate it — call it.

## Why "shape", not "% kept"

The inspector emits only the **kept** (auto-bindable) functions; it does not say
why the rest dropped. But the shape of what survives already decides usability:
axum keeps **56** functions yet is unusable, because all 56 are error/accessor
methods — there's no `Router`/handler/`Sse` to construct. So the runner splits
kept functions into:

- **free** — standalone functions (no receiver)
- **ctor** — constructor-like (`new`, `from_*`, `parse`, `with_*`, `build`, …) — *produces* a value
- **accessor** — methods on a value you must already hold

A crate with real `free`+`ctor` surface is auto-usable; one with only
`accessor`s (axum) is **peripheral** — bindable but not buildable.

> A precise *drop-reason* histogram (generic / lifetime / trait / non-nameable)
> would need an inspector `--audit` mode that tags each `return None` site in
> `tools/sky-ffi-inspect-rs/src/main.rs`. That's the natural next enhancement;
> this skill measures the surviving shape, which is the decision-relevant signal.

## Preconditions

- Run from the Sky repo (`/home/arthur/Documentos/comp/sky`) so the script finds
  `tools/sky-ffi-inspect-rs/target/release/sky-ffi-inspect-rs`. Otherwise it
  falls back to `~/.cache/sky/tools/sky-ffi-inspect-rs/` or `$SKY_FFI_INSPECTOR_RS`.
- **Nightly toolchain** installed (`rustup toolchain list | grep nightly`) — the
  inspector runs `cargo +nightly rustdoc`.
- **mem-guard MUST be running** — a full sweep compiles heavy crates
  (`bevy_ecs`, `diesel`, `tokio`, `nalgebra`, `actix-web`, `sqlx`, `reqwest`)
  under rustdoc. Per the project CLAUDE.md:
  ```bash
  pgrep -f mem-guard.sh >/dev/null || (nohup ./scripts/mem-guard.sh > /tmp/mem-guard.out 2>&1 & disown)
  ```
  The script prints a warning if mem-guard is absent.

## Commands

```bash
cd /home/arthur/Documentos/comp/sky
py=runtime-rust/scripts/ffi_audit.py

python3 "$py" list                       # show the ~50-crate sample by class
python3 "$py" run                        # full sweep (resumable; ~1-3h cold)
python3 "$py" run --crates hex,semver    # just these (fast smoke test)
python3 "$py" run --timeout 600          # raise per-crate timeout for heavy crates
python3 "$py" run --features "tokio=full;diesel=sqlite" --force   # feature-gated crates
python3 "$py" summary                    # summarize whatever has completed (partial OK)
python3 "$py" summary --md               # Markdown table (for pasting into a report)
```

- **Resumable:** each crate's result is cached under
  `~/.cache/sky/ffi-audit/results/`; a re-run skips already-completed crates.
  Use `--force` to recompute one.
- **Long runs:** prefer running the sweep in the background (Bash
  `run_in_background: true` or the Monitor tool) and poll with `summary` — do not
  block a turn on a multi-hour compile. Summarize partial results as they land.

## Interpreting / reporting

The verdict ranks by **constructable surface** (`free + ctor`): `rich` ≥10 ·
`usable` 3–9 · `thin` 1–2 · `peripheral` 0 (accessors only, e.g. axum) ·
`empty` / `FAILED` (no or failed bindings). Verdicts are recomputed from cached
counts at summary time, so tweaking the heuristic needs no re-run. NB: a `rich`
*framework* (actix-web/bevy_ecs/clap) still isn't usable — its bound constructors
are peripheral config/error types, not the generic/macro core; judge frameworks
by hand.

Map the rollup to the strategic alternatives:
- many `rich`/`usable` crates (strong `free` + `ctor` surface) -> confirms the **Alt 1** universe is real & worth widening (monomorphize-on-demand, std-type mapping, slice/iterator coercion).
- `framework` crates landing `peripheral`/`empty` (accessor-only or no constructable surface) -> confirms frameworks need **Alt 2** (generated idiomatic glue) or **Alt 3** (Sky-native modules over the crate, the Sky.Live model).

When asked to record findings, log a dated report under
`runtime-rust/docs/PROGRESS.md`, then run the user's usual
**sky-rust-backend:update-docs** — it regenerates the `### FFI usage` section of
`runtime-rust/README.md` (from `## Getting started` downward) from current truth.
Never hand-edit that section directly.

## Hygiene

A full sweep spawns many `cargo`/`rustdoc`/inspector subprocesses. Before
declaring done, sweep orphans per the project CLAUDE.md (stray `cargo`,
`rustdoc`, `sky-ffi-inspect-rs`, poll loops) and confirm mem-guard is still alive.

## Capture learnings (self-improving loop)

After this skill's work completes, record any **significant, verified,
generalizable** learning — a non-obvious pitfall, a deeper foundational insight,
or a secure/correct/sound optimization — to the **`## Agent learnings`** section
of `runtime-rust/CLAUDE.md`, so future agents improve. Obey that section's rules:
**only if secure, correct, and sound + verified**; **reconcile (update / dedupe /
prune), never blind-append**; **skip when nothing significant** — most runs add
nothing, and manufacturing an entry is worse than none.
