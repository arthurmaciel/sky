# Rust↔Go Parity Roadmap — Sequencing & Tracking Plan

> **For agentic workers:** This is a **tracking/sequencing plan**, not a code-implementation plan. Each task below is a capability **slice** that gets its own brainstorm → spec → plan → implement cycle. Steps use checkbox (`- [ ]`) syntax for tracking. Use superpowers:subagent-driven-development or :executing-plans only *within* an individual slice's own code-level plan, not here.

**Goal:** Drive the Sky Rust backend to co-equal *capability* parity with the Go backend by executing capability slices S0–S8 in dependency order, each gated by the acceptance triple, then sustain parity via the Phase-2 upstream-mirror discipline.

**Architecture:** This plan is the execution index for the roadmap spec. It does not contain slice code — it sequences the slices, defines the per-slice acceptance gate (built once in S0+S1 and reused), and tracks status. Two reusable tools underpin every gate: the **pluggable-reference equivalence harness** (`scripts/rust-equiv.sh`, S0) and the **perf harness** (`scripts/rust-perf.sh`, S1).

**Tech Stack:** Haskell/cabal (codegen), Rust/cargo/clippy (runtime), Bash (harnesses), the Sky compiler (`sky build --target {go,rust}`), the superpowers brainstorming/writing-plans/executing skills.

---

## Source spec

`runtime-rust/docs/superpowers/specs/2026-06-09-rust-go-parity-roadmap-design.md`. Read it before starting any slice.

## Standing rules (every slice)

- **Fork-only.** Rust-backend code never enters `anzellai/sky`. Keep all Rust work behind `TargetRust ->` seams in `runtime-rust/` + `src/Sky/Generate/Rust/`; Go path stays byte-identical.
- **Docs under `runtime-rust/docs/`** (never repo-root `docs/`). No co-author lines in commits.
- **Each slice is its own cycle:** invoke `superpowers:brainstorming` → spec (committed under `runtime-rust/docs/superpowers/specs/`) → `superpowers:writing-plans` → execute. This tracking plan only sequences and gates them.
- **CLAUDE.md rules:** timeout-bound every build/test; disk-hygiene (prune worktrees/caches); no deferring known bugs.

## The acceptance gate (the "triple" — reused by every capability slice)

A slice is **DONE** only when, for the examples it *fully* unblocks:

1. **Example acceptance** — green on the sweep:
   `scripts/rust-sweep.sh | grep '<example>'` shows `builds` (not `sky-CRASH`/`cargo-fails`).
2. **Go-backend equivalence** — `SKY_REF_TARGET=go scripts/rust-equiv.sh <example>` prints `OK[<example>]` (the equivalence harness with its reference set to `--target go` instead of the Rust monolith).
3. **Perf gate** — `scripts/rust-perf.sh <example>` reports Rust within the envelope S1 established (the thresholds file `scripts/rust-perf.thresholds`).

Record the three results in the slice's status row before flipping it to DONE.

---

## Task S0: Floor stabilization

**Status:** SPECCED + PLANNED (executing). Spec + plan exist; tooling/clippy tasks in progress.

**Files:** see `runtime-rust/docs/superpowers/plans/2026-06-09-rust-backend-floor-stabilization.md`.

- [ ] **Step 1: Execute the floor plan** — run its tooling/clippy tasks (sweep, equivalence runner, clippy-green) per that plan. The crash fix + equivalence loop are the author's domain.
- [ ] **Step 2: Confirm the floor gate** — `scripts/verify-rust-target.sh` passes end-to-end (check → clippy exit 0 → test 202/0 → sweep) AND `scripts/rust-equiv.sh` reports all-OK on the empirically-confirmed equivalence set.
- [ ] **Step 3: Mark S0 DONE** in the tracking table below; the sweep + `rust-equiv.sh` are now the reusable gate tooling.

**Exit criteria:** measured green floor; `scripts/rust-sweep.sh` and `scripts/rust-equiv.sh` exist and pass on the in-scope set.

---

## Task S1: Performance-benchmark harness

**Status:** **DONE** (2026-06-11). The perf gate is callable for all three app
shapes (cli / server / live) with committed Rust-vs-Go thresholds, so S2–S8
inherit a working third gate-leg.

**Depends on:** S0 (needs a working `--target rust`).

- [x] **Step 1: Brainstorm the slice** — spec at `runtime-rust/docs/superpowers/specs/2026-06-11-s1-perf-harness-completion-design.md`.
- [x] **Step 2: Plan the slice** — `runtime-rust/docs/superpowers/plans/2026-06-11-s1-perf-harness-completion.md`.
- [x] **Step 3: Implement** — `scripts/rust-perf.sh` drives both backends across all three shapes with bound-port discovery; `scripts/rust-perf.thresholds` is committed (cli / server / live rows). Hardened: every `ab` probe is `timeout`-bounded (closed a real hang), env-overridable load knobs, CV clamp + directional rounding + zero-sample drop in the baseline, and a noise-tolerant gate (re-roll any fail, SKIP a missing Go reference).
- [x] **Step 4: Gate** — round-trip verified on `01-hello-world` (real run exit 0; an artificially inflated threshold trips exit 1). Live shape green on coldstart/binsize/throughput; Sky.Live binary now binds a port and serves (codegen Bug 1 fixed — see commit `b18d8a8a`).
- [x] **Step 5: Mark S1 DONE.**

**Exit criteria:** `scripts/rust-perf.sh` + committed thresholds; the perf gate is now callable by S2–S8. ✅

**Follow-up (not blocking):** the `live.rss_ratio_max` envelope was calibrated
under host memory pressure (swap), which inflates RSS-under-load. Re-baseline
the triplet on a quiet host (`scripts/rust-perf.sh --baseline`) and re-commit
`scripts/rust-perf.thresholds`. The deferred SSE leg (Bug 2: `sse-bench` needs a
session-cookie handshake) re-enables `live.patch_p95` / `live.event_throughput`
at the same time. Tracked for a scheduled quiet-host perf sweep.

---

## Task S2: Parametric-record generics (the linchpin)

**Status:** **DONE** (landed with the 2026-06-11 Std.Ui parity work). Parametric
record aliases lower with real generics (no `SkyValue` collapse); `Element msg` /
typed-attribute configs carry their types. Acceptance: the Std.Ui examples
19/26 build + render byte-identical on Rust (S3), which is impossible without
this. No separate fixture needed.

**Depends on:** S0.

- [ ] **Step 1: Brainstorm** — `superpowers:brainstorming`: "Design parametric-record-alias generics in the Rust codegen — the analogue of the Go backend's v0.15 type-directed lowering + generics on parametric record aliases (`Cfg_R[T]`), so `Element msg` / typed-attribute configs lower with real types instead of collapsing to `SkyValue`." Reference Go's `docs/v1-rfc/type-soundness-deep-analysis.md`.
- [ ] **Step 2: Plan** — `superpowers:writing-plans`.
- [ ] **Step 3: Implement** in `src/Sky/Generate/Rust/Builder/` behind `TargetRust` seams.
- [ ] **Step 4: Gate** — S2 has no example of its own; acceptance is that a parametric-record fixture (and S3's examples once S3 lands) lower without `SkyValue` collapse. Verify with `SKY_REF_TARGET=go scripts/rust-equiv.sh` on a focused fixture + the runtime test suite.
- [ ] **Step 5: Mark S2 DONE.**

**Exit criteria:** the codegen lowers parametric record aliases with generics; unblocks S3.

---

## Task S3: Std.Ui renderer on Rust

**Status:** **DONE** (2026-06-11 plan `…/plans/2026-06-11-stdui-rust-parity.md`).
T0–T5 corpus byte-identical vs Go; integration examples 19-skyforum + 26-ui-showcase
build + render byte-identical on Rust. Composites 37/38 remain deferred — they
need the Sky.Tui (S4) + Sky.Webview (S5) backends, not more Std.Ui work.
**Depends on:** S2.

- [ ] **Step 1: Brainstorm** — Std.Ui's ~25 polymorphic `Element msg` helpers → typed inline-styled HTML on Rust, reusing the Sky.Live renderer (`HtmlToVNode`/`renderVNode`).
- [ ] **Step 2–3: Plan + implement.**
- [ ] **Step 4: Gate (the triple) on examples** `19, 26, 37` (the Std.Ui examples it *fully* unblocks; `24`/`25` complete later with S4/S7):
  - `scripts/rust-sweep.sh` → `builds` for 19, 26, 37.
  - `SKY_REF_TARGET=go scripts/rust-equiv.sh {19,26,37}` → `OK`.
  - `scripts/rust-perf.sh {19,26,37}` → within envelope.
- [ ] **Step 5: Flip README "API surface vs Go" — Std.Ui row → covered. Mark S3 DONE.**

**Exit criteria:** Std.Ui examples green + equivalent + within perf; Tui/Webview unblocked.

---

## Task S4: Sky.Tui backend

**Status:** NOT STARTED. **Depends on:** S3.

- [ ] **Step 1: Brainstorm** — ANSI-cell renderer mirroring `runtime-go/rt` tui (logical-pixel canvas → cells, uniseg width, TTY teardown), reusing the S3 Std.Ui lowering.
- [ ] **Step 2–3: Plan + implement.**
- [ ] **Step 4: Gate (triple)** on `21, 22, 23`; `24` becomes green here (its S3 dep already met).
- [ ] **Step 5: Flip README Sky.Tui row. Mark S4 DONE.**

**Exit criteria:** Tui examples green + equivalent + within perf.

---

## Task S5: Sky.Webview backend

**Status:** NOT STARTED. **Depends on:** S3.

- [ ] **Step 1: Brainstorm** — `wry`/`tao` window + in-process `Bind`/`Eval` bridge (no HTTP/SSE), reusing the S3 renderer. Covers the Go-only `11-fyne` *capability* (desktop GUI).
- [ ] **Step 2–3: Plan + implement.**
- [ ] **Step 4: Gate (triple)** on `29`; `31`/`38` become green once both S4 and S5 are done.
- [ ] **Step 5: Flip README Sky.Webview row. Mark S5 DONE.**

**Exit criteria:** Webview examples green + equivalent + within perf; desktop-GUI capability met.

---

## Task S6: PubSub / Broker

**Status:** **DONE** (2026-06-12). In-process per-type broker (zero payload
erasure) shipped with full `Cmd.publish`/`publishNoEcho`,
`Sub.subscribeTopic`, `PubSub.publish`/`publishNoEcho` surface.

- [x] **Step 1: Brainstorm** — spec at `runtime-rust/docs/superpowers/specs/2026-06-11-s6-pubsub-broker-design.md`.
- [x] **Step 2–3: Plan + implement** — plan `…/plans/2026-06-11-s6-pubsub-broker.md`; per-type `Broker<T>` keyed by `TypeId` (the payload travels as its real Rust type `T`, never erased/downcast — categorically safer than Go's reflect registry, per the no-runtime-errors principle), `SkyCmd::Publish` + dispatch-time origin injection, `sub_subscribe_topic` + session-sid task-local + receiver-side SkipOrigin, Task-shaped `pubsub_publish` (Err Unavailable when no Live app), codegen kernel maps + analyzer flags. 164 runtime tests green.
- [x] **Step 4: Gate** — acceptance via the focused `examples/rust/33-live-pubsub` (String payload, avoids the unrelated `Db.getString`-on-`any` gap): builds on `--target rust`, runs, and **cross-session broadcast is proven end-to-end** (a watch-only session receives another session's broadcast over SSE). The canonical `27-multi-session-chat` is NOT the vehicle — it is blocked only by the unrelated `Db.getString`-on-`any`/Dict codegen gap (filed separately), independent of pub/sub.
- [x] **Step 5: Flip README PubSub row. Mark S6 DONE.**

**Exit criteria:** PubSub surface emits + runs; cross-session broadcast proven
end-to-end on Rust; broker has zero payload erasure. ✅

**Follow-ups filed (not blocking S6):** `Db.getString`/`getInt`/`getBool` on an
`any`/Dict row (blocks `27` + others, Phase-3 limitation #1); bare
`.lock().unwrap()` hardening in `live/mod.rs`. Also a Live-runtime fix landed
here as a dependency: subscriptions now materialise at session init (Go parity),
without which a watch-only session never subscribes.

---

## Task S7: Sky Console + observability federation

**Status:** NOT STARTED. **Depends on:** S3 + S6.

- [ ] **Step 1: Brainstorm** — the bundled console mini-app + `/_sky/observability/ingest` + `MountSubApp`/`PushExporter` on Rust.
- [ ] **Step 2–3: Plan + implement.**
- [ ] **Step 4: Gate (triple)** on `17, 34`; `25` becomes green here (its S3 dep already met).
- [ ] **Step 5: Flip README Console row. Mark S7 DONE.**

**Exit criteria:** Console examples green + equivalent + within perf.

---

## Task S8: Long-tail (06-json pipeline, Std.Cache, Process/Io)

**Status:** IN PROGRESS. **Depends on:** S0.

- **06-json pipeline: ✅ DONE** (2026-06-12). The architectural `Box<dyn FnOnce>`
  Clone/Send issue was already resolved by the uncurry refactor; the only gap was
  the missing multi-arg map decoders — added `json_dec_map2/3/4` (total, real
  error propagation, no erasure). 06-json builds on Rust AND is byte-identical to
  Go. This is S8's primary gate example.
- **Std.Cache: runtime DONE; blocked on 3 stdlib-lowering codegen gaps.** The
  runtime `cache.rs` (LRU+TTL, `K`-typed store + value-erased entries, correct by
  construction — see the `dyn Any` register) is complete + unit-tested, wired
  (`Project.hs` always-declares `cache`; `Types.hs` `CacheCfg` map + E-pins).
  Kernel names auto-map (`Cache_newRaw`→`cache_new_raw`). But compiling the
  `Std.Cache.sky` **stdlib module** to Rust hits 3 independent codegen gaps that
  each need their own fix:
  1. **Phantom opaque-type params** — `type Cache k v` → `enum { Cache(i64) }`
     leaves `k,v` unused → **E0392**; codegen must emit `PhantomData` for unused
     ADT type params.
  2. **`Eq`+`Hash` bound threading** — the generic stdlib wrappers bound `k` with
     `Clone+PartialEq+Debug+Send+Sync` but not `Eq+Hash` that
     `cache_get/put/remove` need → **E0277**; codegen must thread `Eq+Hash` onto a
     key type-var that flows into those kernels (a #52-Part-B-style conditional
     bound, but propagated through the whole stdlib call chain).
  3. **Anon-record return** — `statsRaw : Int -> Task Error { hits, misses,
     evictions }` lowers the anon record to `String` → **E0308**; codegen must
     lower an anonymous-record kernel return to a struct (or map it to
     `CacheStats`).
  Each is a substantial, independent codegen change — flagged for a dedicated
  cycle. Acceptance once fixed: a fork-local `examples/rust/` cache example
  (new/put/get/size/remove/stats), NOT the composite example 36.
- **Process.run / Io-beyond-Log: deferred — YAGNI.** `Io` kernels
  (`io_read_line`/`write_stdout`/`write_stderr`) already exist. `Process.run` has
  **no in-scope example** (not in the FP set), so it has no acceptance vehicle;
  add only when an in-scope example needs it.

- [ ] **Step 1: Brainstorm** — three independent fills: the JSON decode-pipeline `Box<dyn FnOnce>` Clone/Send architectural fix (`06`), an `any`-free `Std.Cache` (`36`'s cache need), and `Process.run`/`Io`-beyond-Log.
- [ ] **Step 2–3: Plan + implement** (may split into three sub-slices).
- [ ] **Step 4: Gate (triple)** on `06`; contributes to `36`.
- [ ] **Step 5: Flip README rows. Mark S8 DONE.**

**Exit criteria:** long-tail examples green + equivalent + within perf.

---

## Task FP: Declare first parity

**Status:** NOT STARTED. **Depends on:** S1–S8 DONE.

- [ ] **Step 1: Full sweep** — `scripts/rust-sweep.sh` shows every in-scope example (41 minus `02`/`11`) as `builds`, including the composites `24, 25, 31, 38`.
- [ ] **Step 2: Full equivalence** — `SKY_REF_TARGET=go scripts/rust-equiv.sh` reports `OK` across the in-scope set.
- [ ] **Step 3: README "API surface vs Go" table** has no *deferred/missing* rows for in-scope capabilities.
- [ ] **Step 4: Commit a "first parity reached" marker** (a dated note in the roadmap spec's status table).

**Exit criteria:** first capability parity reached; proceed to Phase 2.

---

## Task P2: Phase 2 — ongoing-parity discipline (recurring)

**Status:** NOT STARTED. **Depends on:** FP. This is a *recurring process*, not a one-shot.

Per upstream release:
- [ ] **Step 1: Read-only ingest** — `superpowers`-style: run the `/sync-upstream` skill (ff `main`, merge `anzellai/sky`, resolve the thin-seam conflicts, adapt Rust shared-type changes).
- [ ] **Step 2: Diff the capability delta** — list Go features/fixes/examples landed since last sync.
- [ ] **Step 3: Mirror each as a mini-slice** — brainstorm→spec→plan→implement, gated by the acceptance triple. Run the **full sweep** after the sync (the `sync-upstream-dce-exposes-rust-bugs` lesson: clean Haskell build ≠ Rust unaffected).
- [ ] **Step 4: Dual-backend CI gate** — wire `scripts/rust-sweep.sh` + `scripts/rust-equiv.sh` into CI so every in-scope example must stay green on both backends.
- [ ] **Step 5: Co-equal docs pass** — reposition `runtime-rust/CLAUDE.md` + `README.md` from "second-tier" to "co-equal in capabilities, fork-resident, upstream-mirroring"; stress the never-upstream constraint.

**Exit criteria (co-equal steady-state declared):** CI gate live + green; the mirror loop has run ≥1 full cycle; docs repositioned.

---

## Tracking table

| Slice | Depends | Spec | Plan | Example gate | Equiv gate | Perf gate | Status |
|---|---|---|---|---|---|---|---|
| S0 floor | — | ✅ | ✅ | — | — | — | **DONE** |
| S1 perf-harness | S0 | ✅ | ✅ | — | — | — | **DONE** |
| S2 generics | S0 | — | — | (via S3) | — | — | **DONE** (landed with the 2026-06-11 Std.Ui parity work — parametric-record generics lower without SkyValue collapse; 19/26 build) |
| S3 Std.Ui | S2 | ✅ 2026-06-11 | ✅ 2026-06-11 | 19,26 ✅ (37/38 → S5) | 19,26 byte-identical ✅ | — | **DONE** (T0–T5 + 19/26 byte-identical; composites 37/38 deferred to S4+S5) |
| S4 Sky.Tui | S3 | — | — | 21,22,23,24 | … | … | pending |
| S5 Sky.Webview | S3 | — | — | 29,31,38 | … | … | pending |
| S6 PubSub | S0 | ✅ | ✅ | 33,34 ✅; **27 now BUILDS+SERVES unedited** (#52+#56 closed the Db-row gap + Live-entry drop) | broadcast E2E ✅ | — | **DONE** |
| S7 Console | S3,S6 | — | — | 17,25,34 | … | … | pending |
| S8 long-tail | S0 | — | — | 06 ✅ build+equiv | 06 byte-identical ✅ | — | **IN PROGRESS** (06-json done; Std.Cache needs S6-style design; Process.run YAGNI/no in-scope example) |
| FP first parity | S1–S8 | — | — | all in-scope | all | all | pending |
| P2 mirror | FP | — | — | recurring | recurring | recurring | pending |

Fill the Spec/Plan columns with the file path as each slice is brainstormed/planned; flip Status to DONE only after all three gate columns pass.

---

## Self-Review (completed by author)

- **Spec coverage:** two-phase split → Tasks S0–S8 + FP (Phase 1) and P2 (Phase 2); acceptance triple → the shared gate section + each slice's Step 4; Go-backend-reference shift → `SKY_REF_TARGET=go`; perf harness/thresholds → S1; Go-only reframe → S5 (Webview = Fyne capability) + the FP in-scope definition; fork-only/seam/docs constraints → standing rules + P2 Step 5; dependency DAG → the depends column + per-slice "Depends on"; roadmap-as-index → the "each slice is its own cycle" rule + tracking table. All spec sections map to a task.
- **Placeholders:** the `—` cells and "pending"/"next" are *status markers* with a defined next action (brainstorm the slice), not requirement placeholders. No code steps are deferred — code-level detail intentionally lives in each slice's own future plan, per the approved design.
- **Consistency:** the gate tooling names (`scripts/rust-sweep.sh`, `scripts/rust-equiv.sh` with `SKY_REF_TARGET=go`, `scripts/rust-perf.sh` + `.thresholds`) are used identically across all slices; example→slice attributions match the spec's composite-examples note (24→S3+S4, 25→S3+S7, 31/38→S3+S4+S5).
