# Go-package → Rust FFI — design / disposition

**Divergence:** A Sky program declaring `[go.dependencies]` (gorilla/mux,
stripe-go, `net/http`, `log/slog`, …) and calling those packages cannot run on
`--target rust`. Go-package FFI links a Go runtime; the Rust backend has none.

**Disposition: DOCUMENT_BLOCKED** — out-of-scope by design. The only "fix"
(behavioral parity) needs a Go runtime / sidecar, which contradicts the reason
this backend exists. The in-boundary obligation is a *clean refusal* + a
*locked-down negative-path test*, both already met (refusal) or addable here
(test).

---

## Answered questions

### Q1 — Is the disposition DOCUMENT, and is there ANY in-boundary alternative (Go sidecar + IPC)?

DOCUMENT (blocked). No viable in-boundary alternative:

| Alternative | Verdict |
|---|---|
| Link a Go runtime into the Rust binary | Contradicts the no-Go-runtime premise — the backend exists to NOT need one. |
| Spawn a Go sidecar process + IPC-marshal each FFI call | Still needs a Go toolchain/runtime at build+run. Marshalling re-introduces the reflect/`any` risk surface the no-`Box<dyn Any>` rule forbids, and an IPC failure is a *runtime error* → breaks static totality (the existential guarantee). Net: trades the backend's entire reason-for-being for partial parity on a feature that has a first-class Rust substitute (`[rust.dependencies]` crate FFI). |

The Rust backend's answer to "I need a library" is **crate FFI**
(`[rust.dependencies]`, rustdoc-JSON inspector → `.skycache/ffi/rust/*.kernel.json`),
not Go-package FFI. That path already binds `url` / `csv` / `regex` / `bytes`
etc. (README "FFI builder/handle class" row, shipped).

### Q2 — Does the call site fail CLEAN, or silently miscompile / panic late?

**CLEAN.** Verified empirically on `examples/05-mux-server`
(`import Github.Com.Gorilla.Mux as Mux` → `Mux.routerHandleFunc …`):

```
$ sky build --target rust src/Main.sky
-- NAMING ERROR ─────────── src/Main.sky:33:13 [E1001]
   Undefined name: Mux.routerHandleFunc
   Module `Mux` is imported but does not export `routerHandleFunc`.
exit 1   ·   no sky-out/Rust/src/main.rs emitted
```

Mechanism: `regenMissingBindings TargetRust` short-circuits (`app/Main.hs:1045`,
no Go inspector run) and `loadRegistry TargetRust` reads only
`.skycache/ffi/rust` (`FfiRegistry.hs:106`). The Go module's kernel is never
registered, so `loadAndSeedFfiRegistry` seeds no `Mux` entry, and the
canonicaliser rejects the qualified name at **E1001** — *before* any Rust
codegen. No dangling reference, no late `error[E0xxx]` from `cargo`, no panic,
no silent success. The no-runtime-error / no-panic principle holds: this is a
compile-time refusal, the strongest possible failure mode.

### Q3 — Minimal in-boundary improvement to make the refusal first-class?

The current E1001 is clean but **imprecise**: it says "module imported but does
not export X", implying the package exists and merely lacks the symbol — when
the truth is "Go-package FFI is unsupported on the Rust backend; use a Rust
crate". The architecturally-correct improvement is to detect a non-empty
`[go.dependencies]` table at `sky build --target rust` time and emit:

> `Go-package FFI is not supported on the Rust backend; use a Rust crate via [rust.dependencies] (sky add <crate> --target rust).`

**This is OUT of the Rust boundary.** The detection site is where `_goDeps` is
read and `regenMissingBindings TargetRust` short-circuits — `app/Main.hs` (and
the equivalent Compile.hs seam). The in-boundary set is `runtime-rust/`,
`src/Sky/Generate/Rust/`, `src/Sky/Build/Rust/`, `tools/sky-ffi-inspect-rs/`.
`app/Main.hs` is shared CLI plumbing, not Rust-backend-private.

Per "NEVER implement a violation; if the only correct fix is out-of-boundary,
the disposition is DOCUMENT" — we **do not** add the early warning. The existing
E1001 already names the exact symbol + `file:line` and is a non-panic, actionable
refusal. The diagnostic imprecision is recorded as a known wart, owned by the
shared CLI seam, not silently fixed across the boundary.

### Q4 / Q6 — Is the divergence observable today, and what is the verifiable artifact?

Observable today: **yes** — `05-mux-server`, `02-go-stdlib`, `03-tea-external`,
`08-notes-app`, `13-skyshop`, `16-skychess`, `17-skymon` all carry
`[go.dependencies]`. It is NOT purely theoretical.

Verifiable artifact (in-boundary, addable in `runtime-rust/tests/`): a negative-
path fixture asserting that a `[go.dependencies]` build under `--target rust`
**fails at canonicalise with E1001 / "Undefined name", exit ≠ 0, and emits no
`main.rs`** — i.e. clean refusal, not panic, not silent success. No such
negative-path harness exists in `runtime-rust/tests/` today (`missing_kernels/`
is the nearest shape but tests kernel resolution, not Go-dep refusal). The
`rust-codegen/run.sh` harness only checks *positive* builds. This fixture is the
DOCUMENT disposition's "never ship what you can't verify" artifact.

### Q5 — Equiv-sweep classification: excluded, and where is it recorded?

**Already handled correctly.** Every Go-FFI example is classified `out` in the
SSOT manifest `runtime-rust/scripts/equiv-classification.tsv` with an explicit
reason, e.g.:

```
02-go-stdlib   out  Go-FFI only — does not build on --target rust (nothing to compare)
05-mux-server  out  server + does not build on --target rust
13-skyshop     out  Sky.Live — no stdout; does not build on --target rust
```

A future `sync-with-upstream` cannot silently re-add one and report a false
parity failure: `equiv-sweep.sh` has a **classification-coverage gate** — any
`examples/` dir on disk absent from the manifest makes the sweep FAIL
("unclassified → parity claim INCOMPLETE"). New Go-FFI examples must be
explicitly classified `out`, exactly as `35-composite-generics` was reclassified
out for non-determinism. No action needed for Q5.

---

## Principle check

| Principle | Status |
|---|---|
| security | n/a — no surface added |
| correctness / no-runtime-error | **HELD** — refusal is at canonicalise (E1001), exit 1, no `main.rs`. No panic, no late cargo error, no silent miscompile. Verified on `05-mux-server`. |
| soundness / no `Box<dyn Any>` | **HELD** — a Go-sidecar IPC path would reintroduce `any` marshalling; rejected. |
| efficiency | n/a |
| Go-parity | impossible without a Go runtime — accepted as out-of-scope, not silently traded. |
| no out-of-boundary edits | **HELD** — the nicer diagnostic would touch `app/Main.hs` (shared CLI), so it is documented-not-implemented. Only `runtime-rust/` artifacts change. |
| verifiable | **HELD** — negative-path fixture under `runtime-rust/tests/` proves clean refusal. |

---

## Executor work (no commits)

1. Spec (this file) — done.
2. README divergence row — reclassify from bare "out of scope" to **documented
   + clean-refusal-verified**, citing E1001 at canonicalise, the
   `equiv-classification.tsv` gate, and the `[rust.dependencies]` substitute.
   Note the diagnostic-imprecision wart is owned by the shared CLI seam
   (`app/Main.hs`), out of the Rust boundary.
3. Negative-path fixture under `runtime-rust/tests/` — a minimal project with a
   `[go.dependencies]` entry + a qualified call to it, built under
   `--target rust`, asserting **exit ≠ 0**, **stderr/stdout contains the E1001 /
   "Undefined name" refusal**, and **no `sky-out/Rust/src/main.rs`** produced.
   Must NOT panic and must NOT succeed silently.
