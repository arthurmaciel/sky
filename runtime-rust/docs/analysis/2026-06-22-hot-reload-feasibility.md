# Hot-Reload / Hot-Patching Feasibility — Rust Backend

> **Status: analysis only — HOLD, not implemented.**
> Neither part A nor part B has any implementation. The question is parked
> with a clear re-open checklist at the bottom of this document.

---

## Scope

Two related questions were analysed:

| Label | Question |
|-------|----------|
| **A** | Is general Rust hot-patching feasible for `sky watch --backend rust`? |
| **B** | Is a narrower Std.Ui-only hot-reload feasible — reloading only the `view` without a full rebuild+restart? |

Both questions are **independent of the Go backend**: Go's `sky watch` also
does rebuild+restart; neither backend has hot-reload. Question B is therefore
not a [Go-parity gap](../go-rust-parity-audit-2026-06-21.md).

---

## A. General Rust hot-patching — REJECTED

### What was considered

- **dylib hot-reload** via [`hot-lib-reloader-rs`](https://github.com/rksm/hot-lib-reloader): calls `dlopen` + symbol transmute at reload.
- **JIT patching** via Dioxus `subsecond`: alpha, arch-specific (x86_64 only at time of writing).

### Blocking constraints

| Constraint | Detail |
|------------|--------|
| No-runtime-panic thesis | An `unsafe` `dlopen`/symbol-transmute seam is not total-by-construction. A stale or mismatched symbol is a load-time abort or UB — not a `Result`. The backend's design goal is that well-typed Sky code cannot panic. |
| Model type-identity across a reload | A reloaded dylib is a separate compilation unit. Passing `&Model` across the boundary is `repr(Rust)`/ABI-unstable. The fields and derives the developer is actively editing are exactly what causes layout divergence → UB on the most common dev-loop mutation. |
| Static-binary / WASM / embedded targets | `dlopen` is unavailable on WASM. A dylib view-crate is incompatible with the musl static-binary preference shared by the Rust backend. |
| `subsecond` maturity | Alpha + architecture-specific at the time of this analysis. Insufficient stability for a production toolchain path. |

**Verdict: rejected. Do not pursue.**

---

## B. Std.Ui-only view hot-reload — HOLD

### The question

When only `view`-related Sky source files change, can `sky watch --backend rust`:
1. recompile/reload only the view logic, and
2. push the new render through the existing SSE patch channel,
without a full `cargo build` + process restart?

### Current architecture (the crux)

`view : Model -> Element/Html` lowers to a **native, statically-linked,
monomorphic Rust function**
(`src/Sky/Generate/Rust/Builder/ModuleEmitter.hs:586`).

The live runtime holds it as a monomorphic `Arc<FView>` with bound
`FView: Fn(Model)->Html<Msg>`
(`runtime-rust/src/sky_runtime/live/mod.rs:134,374,533,548`;
wrapped at `mod.rs:1043` (and `:1101`) as `Arc::new(view)`).

The **output** of `view` — the `Html<Msg>` / `Element<Msg>` tree — IS pure
data:

- `Html<M>` enum: `runtime-rust/src/sky_runtime/html.rs:7`
- `Element<M>` enum: `runtime-rust/src/sky_runtime/ui/element.rs:147`

The **SSE diff+patch path already exists**:
`runtime-rust/src/sky_runtime/live/diff.rs:45` produces `Vec<Patch>`,
and `mod.rs:650-652` serialises and sends them over SSE.

The missing piece is getting *new view behaviour* into the running process
without a restart. The `Html`/`Element` tree is data, but the Rust function
that produces it is compiled code — every `case`/`let`/call/`List.map` lambda
is native machine code statically linked into the binary.

### The four options

| Option | Approach | Verdict |
|--------|----------|---------|
| **(a) Full rebuild+restart** | Today's baseline. `sky watch` runs codegen → `cargo build` → SIGTERM → respawn (`src/Sky/Cli/Watch.hs:271-294`). | Sound, total, no unsafe. [`[live] store=sqlite`](../../README.md) already preserves Model across restart — the main user-visible pain is already mitigated. |
| **(b) Rust dylib hot-patch** | Extract the view into a dylib; hot-reload on change. | **Reject** — all §A constraints apply identically. |
| **(c) Pure-data view layer** | Represent view as a data tree (not compiled code) interpretable at runtime without recompile. | **Impossible** as stated. Sky `view` is arbitrary code — lambdas, pattern matching, `List.map`, conditionals. A full data representation would require a complete Sky expression interpreter in the runtime, which is a Sky compiler backend embedded in `sky_runtime`. |
| **(d) Element-AST interpreter (dev-only, narrow subset)** | A dev-only `SKY_DEV_VIEW_INTERP=1`-gated interpreter over a statically-constrained Std.Ui subset. When a view-only change is detected, the runtime re-evaluates the serialised `Element` tree expression (not arbitrary Sky code) and pushes the diff via SSE. Anything outside the supported subset silently falls back to full rebuild. | The **only technically feasible route** — but a large dev-only subsystem. See constraints below. |

### Option (d) constraints

Even in the narrowest form, this requires:

- A Sky source analyser that can determine "this change affects only the
  narrow static subset" — i.e. no new lambdas, no new `Cmd.perform`, no model
  field access outside a simple projection — and triggers a fallback otherwise.
- A serde bridge between the live in-memory `Model` (typed Rust struct) and
  the interpreter's view of it (untyped Sky expression). This is non-trivial:
  `Model` is a generated Rust struct with `serde::Serialize` / `Deserialize`
  bounds (`live/mod.rs:1028` (and `:1076`)), so JSON round-trip is available, but the
  interpreter must reconstruct a Sky value from that JSON to evaluate the view.
- Zero `unsafe`. The interpreter must return `Result`; any miss triggers the
  rebuild fallback. The compiled path must be touched nowhere.
- The subsystem is effectively a fraction of a compiler backend, scoped to the
  Std.Ui primitive set. Non-trivial maintenance surface.

### Cost-benefit at current baseline

| Factor | Assessment |
|--------|------------|
| Full rebuild time | ~1.9 s `cargo build` + relink on a warm incremental cache |
| Model loss on restart | Already solved: `[live] store=sqlite` round-trips Model via serde across restarts |
| Go-parity gap | None — Go `sky watch` is also rebuild+restart |
| Implementation cost of (d) | High (new subsystem, serde bridge, subset analyser, fallback path) |
| Benefit ceiling | Saves ~1.9 s on view-only changes in dev mode only |

**Net: benefit is bounded; cost is high. HOLD.**

---

## How to re-open this

Re-open option (d) when **at least two** of these conditions are true:

1. **Rebuild time has grown.** If incremental `cargo build` for a typical Sky
   Live app exceeds ~5 s on a warm cache, the benefit ceiling rises enough to
   justify the subsystem.
2. **Model serde bridge already exists for another reason.** If `Model` is
   already serialised to a neutral format (e.g. for devtools, time-travel
   debugging, or a Rust-side snapshot feature), the bridge cost drops to near
   zero.
3. **A narrow static Std.Ui subset can be identified cleanly.** If it turns out
   that >80% of real-world view functions are pure `Ui.*` calls with no
   `List.map` lambdas or Msg-constructing closures, the subset is large enough
   to be worth defining.
4. **A prior-art interpreter already exists** (e.g. from the Sky expression
   evaluator used in `sky doc` or a future REPL). Reusing it avoids building
   from scratch.

**First concrete step if re-opened:** scope only the serde bridge
(`Model → sky_value::Value`) as a standalone experiment, measure JSON
round-trip latency on a realistic model, and check whether the AST subset
problem is tractable before writing any interpreter code.

**Do not pursue option (b) under any circumstance** — the §A safety
constraints are architectural, not maturity-related.

---

## Related files

| File | Relevance |
|------|-----------|
| `runtime-rust/src/sky_runtime/live/mod.rs` | `live_app`, `drive_session`, `FView` bound, `Arc::new(view)` |
| `runtime-rust/src/sky_runtime/live/diff.rs` | SSE patch generation (`diff`) |
| `runtime-rust/src/sky_runtime/html.rs` | `Html<M>` data enum |
| `runtime-rust/src/sky_runtime/ui/element.rs` | `Element<M>` data enum |
| `src/Sky/Generate/Rust/Builder/ModuleEmitter.hs` | View fn codegen (monomorphic Rust fn emission) |
| `src/Sky/Cli/Watch.hs` | `sky watch` rebuild+restart loop (lines 271–294) |
| `runtime-rust/docs/go-rust-parity-audit-2026-06-21.md` | Go-parity gap inventory (hot-reload is NOT listed — it is not a gap) |
