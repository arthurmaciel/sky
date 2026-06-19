# keep-go-parity v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the sync→parity→verify→push loop into one resumable orchestration that scopes local verification to the change blast-radius, adds the missing `implement-parity-gap` skill, and chains the existing modular skills — leaning on CI for the full matrix.

**Architecture:** Three independent deliverables, built in order: (1) a `changed_examples <base>` helper in the example-manifest lib that partitions a git diff into the example dirs worth sweeping locally; (2) a new `implement-parity-gap` skill (autonomous-by-default, gated on a Go≡Rust equivalence fixture, with explicit escalation); (3) keep-go-parity v2 — an 8-phase chain whose resume frontier lives in a gitignored run-state file, with a `scoped-sweep` subcommand wiring the helper into the existing `examples-sweep`.

**Tech Stack:** Bash (sweep scripts + `scripts/lib/*.sh` single-source-of-truth manifest), Markdown skills (`plugins/sky-rust-backend/skills/`), skydex (Rust code indexer), the existing `examples-sweep.sh` (`RUST_EXAMPLES` subset override).

**Spec:** `runtime-rust/docs/superpowers/specs/2026-06-19-keep-go-parity-v2-design.md`

---

## Background the engineer needs (read before starting)

- **The manifest is DERIVED, never hardcoded.** `runtime-rust/scripts/lib/examples.sh` is *sourced* (never executed). It exposes shell **functions** computed from the example dirs on disk: `all_examples`, `build_set` (all_examples minus Go-FFI), `example_shape <dir>` (`cli|server|live|tui|webview|fyne`), `is_out_of_scope <dir>`, `equiv_mode <dir>`. `build_set` is the in-scope set — anything not in it can't build on `--backend rust`.
- **`env.sh` sets `REPO`** (repo root) and `SKY_BIN`, and is sourced before `examples.sh`. All `$REPO/...` paths depend on it. Callers `cd "$REPO"` themselves.
- **`examples-sweep.sh` accepts a subset override:** `RUST_EXAMPLES="01-hello-world examples/19-skyforum"` (space-separated, dir paths OR basenames) runs only those examples. This is the wiring point for the scoped sweep — no sweep rewrite needed.
- **skydex** (`tools/skydex/target/release/skydex`, db `.skydex/index.db`): `skydex covers <token>` prints the `.sky` files that import a stdlib module whose dotted name *contains* `<token>` (SQL `LIKE %token%`, substring). `skydex parity --gaps` lists `go-only` rows (Go kernel present, Rust absent). skydex replaces Gortex here (Gortex OOMs this repo).
- **`.skycache/keep-go-parity.state` is gitignored** (verified: `git check-ignore` passes) — the correct home for resume state.
- **Boundary (every change here is in it):** `runtime-rust/`, `src/Sky/Generate/Rust/`, `src/Sky/Build/Rust/`, `tools/skydex/`. Never the shared stdlib, the Go backend, or the author's `examples/`.
- **Build/run env for any local sweep:** `source runtime-rust/scripts/lib/env.sh` handles PATH + `CARGO_TARGET_DIR` + sccache. Don't re-export by hand.
- **macOS+Linux portability:** no in-place `sed -i` (BSD vs GNU differ) — rewrite files via `awk` + temp-file + `mv`.

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `runtime-rust/scripts/lib/examples.sh` | manifest SSOT; gains `changed_examples` + 4 helper fns | Modify |
| `runtime-rust/scripts/lib/examples_test.sh` | plain-bash unit test for the new helpers | Create |
| `runtime-rust/plugins/sky-rust-backend/skills/implement-parity-gap/SKILL.md` | the new parity-gap skill | Create (via writing-skills) |
| `runtime-rust/scripts/keep-go-parity.sh` | planner gains run-state machinery + `scoped-sweep` subcommand | Modify |
| `runtime-rust/plugins/sky-rust-backend/skills/keep-go-parity/SKILL.md` | the 8-phase v2 chain + resume narrative | Modify |

---

## Task 1: `changed_examples <base>` helper + unit test

**Files:**
- Modify: `runtime-rust/scripts/lib/examples.sh` (append new functions after `perf_set`, near line 156)
- Create: `runtime-rust/scripts/lib/examples_test.sh`

The helper partitions `git diff --name-only <base>..HEAD` into the example dirs worth a local sweep, per the spec §C table: example-source changes → those dirs (precise); runtime-kernel changes → skydex `covers` consumers (best-effort); codegen changes → the full build_set (broad); ALWAYS the representative-per-shape floor. The result is intersected with `build_set` and fed to `examples-sweep` via `RUST_EXAMPLES`.

We build it bottom-up: the pure, unit-testable pieces first, then the orchestrator.

- [ ] **Step 1: Write the failing test (harness + first assertion)**

Create `runtime-rust/scripts/lib/examples_test.sh`:

```bash
#!/usr/bin/env bash
# Unit test for the changed_examples helper family in lib/examples.sh.
# Plain bash (the repo has no bats). Sources the lib the same way the sweeps do.
# Run: bash runtime-rust/scripts/lib/examples_test.sh   → exits 0 all-green, 1 on any fail.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/env.sh"; cd "$REPO"
# shellcheck source=/dev/null
source "$HERE/examples.sh"

fail=0
assert_eq() { # $1=got $2=want $3=label
  if [ "$1" = "$2" ]; then echo "ok   : $3"
  else echo "FAIL : $3"; echo "       want: [$2]"; echo "       got : [$1]"; fail=1; fi
}
assert_contains() { # $1=haystack(newlines) $2=needle $3=label
  if printf '%s\n' "$1" | grep -qxF "$2"; then echo "ok   : $3"
  else echo "FAIL : $3 (missing '$2')"; echo "       in: [$1]"; fail=1; fi
}

# --- representative_floor: one in-scope example per shape, all in build_set ---
FLOOR="$(representative_floor)"
INSCOPE="$(build_set)"
floor_ok=1
while IFS= read -r d; do
  [ -z "$d" ] && continue
  printf '%s\n' "$INSCOPE" | grep -qxF "$d" || floor_ok=0
done <<< "$FLOOR"
assert_eq "$floor_ok" "1" "representative_floor: every emitted dir is in build_set"
# shapes must be unique (at most one per shape)
SHAPES="$(while IFS= read -r d; do [ -n "$d" ] && example_shape "$d"; done <<< "$FLOOR" | sort)"
assert_eq "$SHAPES" "$(printf '%s\n' "$SHAPES" | sort -u)" "representative_floor: one example per shape (no dup shapes)"

exit "$fail"
```

- [ ] **Step 2: Run the test — verify it fails (function undefined)**

Run: `bash runtime-rust/scripts/lib/examples_test.sh`
Expected: nonzero exit with `representative_floor: command not found` (the function doesn't exist yet).

- [ ] **Step 3: Implement `representative_floor`**

Append to `runtime-rust/scripts/lib/examples.sh` (after `perf_set`, before the `equiv_mode` block at line ~158):

```bash
# ── changed_examples <base> — scope a local sweep to a diff's blast radius ────
# Per the keep-go-parity v2 spec (§C): partition `git diff <base>..HEAD` into the
# example dirs worth sweeping LOCALLY. Precise only for example-source changes;
# runtime/codegen changes widen broadly (CI's full 3-OS sweep is the real gate).
# All pieces are DERIVED from disk + skydex — no hardcoded example lists.

# representative_floor: one in-scope example per shape (cli/server/live/tui/
# webview) — the baseline coverage when the change→example map is imprecise.
# Deterministic: the first in-scope example of each shape in build_set order.
representative_floor() {
  local d shape
  declare -A seen
  while IFS= read -r d; do
    shape="$(example_shape "$d")"
    case "$shape" in
      cli|server|live|tui|webview) ;;
      *) continue ;;                  # fyne is Go-FFI (not in build_set anyway)
    esac
    [ -n "${seen[$shape]:-}" ] && continue
    seen[$shape]=1
    printf '%s\n' "$d"
  done < <(build_set)
}
```

- [ ] **Step 4: Run the test — verify it passes**

Run: `bash runtime-rust/scripts/lib/examples_test.sh`
Expected: both `representative_floor` assertions `ok`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add runtime-rust/scripts/lib/examples.sh runtime-rust/scripts/lib/examples_test.sh
git commit -m "feat(rust): representative_floor + scoped-sweep test harness in examples.sh lib"
```

- [ ] **Step 6: Write failing tests for the path-partition + intersect pure fns**

Add to `examples_test.sh` before the final `exit "$fail"`:

```bash
# --- _paths_to_example_dirs: example-source paths → their example dirs ---
SOME_EX="$(all_examples | head -1)"            # a real in-scope-or-not example dir on disk
SOME_NAME="$(basename "$SOME_EX")"
PATHS="$(printf '%s\n' "$SOME_EX/src/Main.sky" "runtime-rust/src/x.rs" "README.md")"
GOT="$(printf '%s\n' "$PATHS" | _paths_to_example_dirs)"
assert_eq "$GOT" "examples/$SOME_NAME" "_paths_to_example_dirs: maps example src path to its dir, ignores non-example paths"

# --- _intersect_build_set: keep only in-scope dirs ---
FIRST_INSCOPE="$(build_set | head -1)"
GOT="$(printf '%s\n' "$FIRST_INSCOPE" "examples/does-not-exist-zzz" | _intersect_build_set)"
assert_eq "$GOT" "$FIRST_INSCOPE" "_intersect_build_set: drops out-of-scope/bogus dirs"

# --- _runtime_token: rs basename → covers token ---
assert_eq "$(_runtime_token runtime-rust/src/sky_runtime/string.rs)" "String" "_runtime_token: string.rs → String"
assert_eq "$(_runtime_token runtime-rust/src/sky_runtime/server_stream.rs)" "Server" "_runtime_token: server_stream.rs → Server (drops _suffix)"
```

Run: `bash runtime-rust/scripts/lib/examples_test.sh`
Expected: FAIL — the three new helpers are undefined.

- [ ] **Step 7: Implement the pure helpers**

Append to `examples.sh` directly after `representative_floor`:

```bash
# _paths_to_example_dirs: PURE. Reads repo-relative changed paths (one per line)
# on stdin; emits the example dir for each `examples/<name>/...` path (the precise
# case — an example depends only on its own source). New example dirs surface here
# automatically (their source shows in the diff). Non-example paths are ignored.
_paths_to_example_dirs() {
  local p name
  while IFS= read -r p; do
    case "$p" in
      examples/*/*)
        name="${p#examples/}"; name="${name%%/*}"
        [ -d "examples/$name" ] && printf 'examples/%s\n' "$name"
        ;;
    esac
  done
}

# _runtime_token <rs-path>: derive a `skydex covers` module token from a runtime
# file name. Heuristic, best-effort: capitalize the basename and drop a trailing
# `_<suffix>` (string.rs → String, server_stream.rs → Server, db.rs → Db). The
# covers LIKE-match is forgiving; a token matching no module yields no rows and
# the representative floor still covers that change.
_runtime_token() {
  local base
  base="$(basename "$1" .rs)"
  base="${base%%_*}"
  printf '%s%s\n' "$(printf '%s' "${base:0:1}" | tr '[:lower:]' '[:upper:]')" "${base:1}"
}

# _runtime_paths_to_covered_examples: PURE-ish (reads skydex, no mutation). For
# each changed runtime-rust/src/**.rs path, ask skydex which examples `cover`
# (import) the derived module, mapping .sky consumers back to example dirs.
# GUARDED: if skydex isn't built or the index db is absent, emit nothing — the
# broad floor (and CI) still cover the change. Best-effort enrichment, never a
# hard dependency.
_runtime_paths_to_covered_examples() {
  local p tok line name
  local sky="$REPO/tools/skydex/target/release/skydex"
  local db="$REPO/.skydex/index.db"
  [ -x "$sky" ] && [ -f "$db" ] || return 0
  while IFS= read -r p; do
    case "$p" in runtime-rust/src/*) ;; *) continue ;; esac
    [ "${p%.rs}" != "$p" ] || continue          # only .rs files
    tok="$(_runtime_token "$p")"
    [ -n "$tok" ] || continue
    while IFS= read -r line; do
      case "$line" in
        examples/*/*)
          name="${line#examples/}"; name="${name%%/*}"
          [ -d "examples/$name" ] && printf 'examples/%s\n' "$name"
          ;;
      esac
    done < <("$sky" covers "$tok" --db "$db" 2>/dev/null)
  done
}

# _intersect_build_set: keep only dirs present in build_set (drops Go-FFI /
# non-buildable / bogus). Reads candidate dirs on stdin.
_intersect_build_set() {
  local d
  declare -A inscope
  while IFS= read -r d; do [ -n "$d" ] && inscope[$d]=1; done < <(build_set)
  while IFS= read -r d; do
    [ -n "${inscope[$d]:-}" ] && printf '%s\n' "$d"
  done
}
```

- [ ] **Step 8: Run the test — verify it passes**

Run: `bash runtime-rust/scripts/lib/examples_test.sh`
Expected: all assertions `ok`, exit 0.

- [ ] **Step 9: Commit**

```bash
git add runtime-rust/scripts/lib/examples.sh runtime-rust/scripts/lib/examples_test.sh
git commit -m "feat(rust): pure path-partition helpers for changed_examples"
```

- [ ] **Step 10: Write the failing test for `changed_examples`**

Add to `examples_test.sh` before `exit "$fail"`:

```bash
# --- changed_examples: empty diff (base = HEAD) → exactly the floor ---
GOT="$(changed_examples HEAD | sort -u)"
WANT="$(representative_floor | _intersect_build_set | sort -u)"
assert_eq "$GOT" "$WANT" "changed_examples HEAD (empty diff): equals the in-scope floor"

# --- changed_examples always includes the floor (superset of floor) ---
floor_ok=1
while IFS= read -r d; do
  [ -z "$d" ] && continue
  printf '%s\n' "$GOT" | grep -qxF "$d" || floor_ok=0
done < <(representative_floor | _intersect_build_set)
assert_eq "$floor_ok" "1" "changed_examples: result always includes the representative floor"
```

Run: `bash runtime-rust/scripts/lib/examples_test.sh`
Expected: FAIL — `changed_examples: command not found`.

- [ ] **Step 11: Implement `changed_examples`**

Append to `examples.sh` after `_intersect_build_set`:

```bash
# changed_examples <base>: the scoped local-sweep list. ONE `git diff` feeds the
# whole partition (the caller passes the same <base> to the incremental audit).
# Union of: example-source dirs (precise) + skydex-covered consumers of changed
# runtime kernels (best-effort) + the representative floor — intersected with
# build_set, deduped. Codegen changes have no clean per-example map, so they
# WIDEN to the full build_set ("broad"). Emits dir paths, one per line, for
# RUST_EXAMPLES. Honest contract: precise only for example-source changes; for
# runtime/codegen changes this is fast pre-push feedback, NOT the gate — CI's
# full 3-OS sweep is.
changed_examples() {
  local base="${1:?changed_examples: <base> required}" diff
  diff="$(git diff --name-only "$base"..HEAD 2>/dev/null)"
  # Codegen touch → broad: the whole in-scope set (supersets every other source).
  if printf '%s\n' "$diff" | grep -qE '^src/Sky/(Generate|Build)/Rust/'; then
    build_set | sort -u
    return 0
  fi
  {
    printf '%s\n' "$diff" | _paths_to_example_dirs
    printf '%s\n' "$diff" | _runtime_paths_to_covered_examples
    representative_floor
  } | sort -u | _intersect_build_set | sort -u
}
```

- [ ] **Step 12: Run the test — verify it passes**

Run: `bash runtime-rust/scripts/lib/examples_test.sh`
Expected: all assertions `ok`, exit 0.

- [ ] **Step 13: Smoke-check against a real diff + lint**

Run:
```bash
bash -n runtime-rust/scripts/lib/examples.sh && echo "syntax ok"
( source runtime-rust/scripts/lib/env.sh && cd "$REPO" && source runtime-rust/scripts/lib/examples.sh \
  && echo "--- changed_examples HEAD~5 ---" && changed_examples HEAD~5 )
```
Expected: `syntax ok`, then a deduped list of in-scope example dirs (at least the floor). No errors.

- [ ] **Step 14: Commit**

```bash
git add runtime-rust/scripts/lib/examples.sh runtime-rust/scripts/lib/examples_test.sh
git commit -m "feat(rust): changed_examples <base> — diff-scoped sweep list (spec §C)"
```

---

## Task 2: `implement-parity-gap` skill (via writing-skills)

**Files:**
- Create: `runtime-rust/plugins/sky-rust-backend/skills/implement-parity-gap/SKILL.md`

This is a **skill artifact**, authored under the discipline of `superpowers:writing-skills` (RED → GREEN → REFACTOR: baseline a subagent's behavior WITHOUT the skill, write the skill to fix what they got wrong, re-test). Do not hand-write it and skip the baseline — the baseline is what proves the skill teaches the right thing.

The content requirements come from spec §A. The skill is an **orchestration pattern** (judgment-heavy), **autonomous-by-default**, **gated on a Go≡Rust equivalence fixture**, with **explicit escalation**.

- [ ] **Step 1: Invoke writing-skills and run the RED baseline**

Invoke `superpowers:writing-skills`. Per its Iron Law, first run a baseline: dispatch a subagent the task *"A sync just landed; `skydex parity --gaps` shows `go-only` for `List.intersperse` (a pure list kernel) and for a new `Sky.Webview` tray-icon surface. Close these parity gaps on the Rust backend."* — WITHOUT the skill. Record verbatim what it does wrong. Expected failure modes to capture (the rationalizations the skill must counter):
  - treats a green `cargo build --features full` as proof of parity (no equivalence check);
  - attempts the subsystem-scale webview surface autonomously instead of escalating;
  - skips the pre-failing fixture;
  - adds an external crate to a shared/always-compiled module.

- [ ] **Step 2: Write `SKILL.md` addressing those failures**

Create `runtime-rust/plugins/sky-rust-backend/skills/implement-parity-gap/SKILL.md`. Frontmatter `description` MUST be **triggering-conditions only** (no workflow summary — per writing-skills CSO):

```markdown
---
name: implement-parity-gap
description: Use after an upstream sync when skydex parity --gaps reports go-only kernels/features the Rust backend lacks, or when an example fails because a kernel is unimplemented. Use when closing the Go→Rust parity gap for newly-arrived functionality. Trigger: /sky-rust-backend:implement-parity-gap.
---
```

Body MUST contain, drawn from spec §A:

1. **Overview** — implementing a parity gap is judgment-heavy creative engineering; this skill captures the *discipline*, not a push-button. The thesis: mirror Go behaviour, with more security/correctness/soundness. Principle order: security > correctness > soundness > efficiency > completeness > readability.

2. **The autonomy decision (the load-bearing table)** — autonomous-by-default, equivalence-fixture-gated, with escalation. Reproduce the spec's table:

   | | Autonomous (close it) | Escalate to the user |
   |---|---|---|
   | Shape | mechanical gap: a new **pure stdlib kernel** with a clear Go oracle + deterministic I/O | anything below |
   | Gate | a **Go≡Rust equivalence fixture** auto-establishes AND passes non-vacuously | — |
   | Trigger | — | build fails after a bounded attempt; OR equivalence fixture can't be auto-established / only passes **vacuously** (no real oracle, or non-deterministic output — clocks/entropy/ordering); OR the gap is **subsystem-scale** (new runtime module, new dep, codegen-shape change, framework/effect surface) |

3. **Equivalence-fixture-as-gate** (the core teaching) — a green build proves *it compiles*; the equivalence fixture proves *it mirrors Go*. The build gate is **necessary but NOT sufficient** for parity. A fixture that passes because both sides emit nothing is **vacuous → escalate, don't mark done**.

4. **The per-gap loop** (batched by subsystem where possible):
   1. Locate the Go reference behaviour (the Go runtime fn and/or the example that exercises it) — the oracle to mirror.
   2. Implement in-boundary: runtime fn in `runtime-rust/src/sky_runtime/` + routing in `Builder/Kernel.hs` (+ Cargo feature-gating if a new dep is needed — and **NEVER a new external-crate dep in a shared/always-compiled module**, per the CLAUDE.md learning) + a **pre-failing fixture** under `runtime-rust/tests/sky/` (the failing test is the discovery artefact).
   3. Verify (orchestrator only): `cargo build/test --features full` + a **feature-minimal** build + `cabal build exe:sky` + build the fixture/example on `--backend rust` + **run the equivalence fixture (Go output vs Rust output, diffed)**.
   4. Soundness floor: no panic from well-typed Sky; degrade, never crash.

5. **Escalation is explicit, not silent** — on a trigger, STOP, record the gap (one-paragraph spec + the no-deferral entry), signal the user; never bury a subsystem-scale gap as a half-fix or mark an unmirrored kernel done.

6. **Multi-gap fan-out** reuses `sky-rust-backend:autonomous-swarm` (agents author **disjoint** files, never build; orchestrator does the single integration build + the equivalence run). **Boundary:** runtime + Rust codegen + `examples/rust/` fixtures only.

7. **Common mistakes** table — at minimum: "marking a kernel done on a green build (no equivalence run)"; "vacuous equivalence fixture counted as a pass"; "attempting a subsystem-scale gap autonomously"; "new crate dep in a shared module breaks feature-minimal builds (E0433)"; "skipping the pre-failing fixture".

8. **Capture-learnings** footer — the standard self-improving-loop paragraph used by the sibling skills (`## Agent learnings` in `runtime-rust/CLAUDE.md`).

- [ ] **Step 3: Run the GREEN test — re-dispatch the baseline scenario WITH the skill**

Dispatch a fresh subagent the same task from Step 1, this time with the skill available. Verify it now: (a) closes `List.intersperse` autonomously WITH an equivalence fixture, and (b) ESCALATES the webview tray-icon surface as subsystem-scale rather than attempting it. If it still rationalizes past either gate, REFACTOR the skill (add the explicit counter) and re-test until both hold.

- [ ] **Step 4: Verify the skill is well-formed**

Run:
```bash
test -f runtime-rust/plugins/sky-rust-backend/skills/implement-parity-gap/SKILL.md && echo "exists"
head -5 runtime-rust/plugins/sky-rust-backend/skills/implement-parity-gap/SKILL.md   # frontmatter present, description = triggers only
```
Expected: file exists; frontmatter `name: implement-parity-gap` + a triggering-conditions `description` with no workflow summary.

- [ ] **Step 5: Commit**

```bash
git add runtime-rust/plugins/sky-rust-backend/skills/implement-parity-gap/SKILL.md
git commit -m "feat(rust): implement-parity-gap skill — equivalence-gated autonomous parity-gap closure"
```

---

## Task 3: keep-go-parity v2 — run-state resume + scoped-sweep wiring

**Files:**
- Modify: `runtime-rust/scripts/keep-go-parity.sh` (add state machinery + `scoped-sweep` + `state-*` subcommands; keep `snapshot`/`plan`/`run`)
- Modify: `runtime-rust/plugins/sky-rust-backend/skills/keep-go-parity/SKILL.md` (the 8-phase v2 chain + resume narrative)

The script stays a **planner** (the chain's sync needs conflict judgement and perf needs an interactive reminder — neither belongs in a non-interactive script). v2 adds: (a) a gitignored run-state file as the resume frontier, and (b) a `scoped-sweep` subcommand that turns `changed_examples <BASE>` into a `RUST_EXAMPLES`-scoped `examples-sweep` run.

- [ ] **Step 1: Write the failing test for the state machinery**

Append a self-test block to `keep-go-parity.sh` reachable via a hidden `selftest` subcommand (so it ships with the script and runs in CI-free isolation). First add the test invocation to a new test file `runtime-rust/scripts/lib/keep_go_parity_test.sh`:

```bash
#!/usr/bin/env bash
# Unit test for keep-go-parity.sh run-state machinery. Plain bash.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
KGP="$HERE/../keep-go-parity.sh"
fail=0
assert_eq() { if [ "$1" = "$2" ]; then echo "ok   : $3"; else echo "FAIL : $3 want[$2] got[$1]"; fail=1; fi; }

# Drive the script's state subcommands against a throwaway state file.
export SKY_KGP_STATE="$(mktemp -u)/state"        # script honours this override
bash "$KGP" state-init   >/dev/null
assert_eq "$(bash "$KGP" state-get last_completed_phase)" "0" "state-init sets last_completed_phase=0"
BASE="$(bash "$KGP" state-get BASE)"
assert_eq "$([ -n "$BASE" ] && echo nonempty)" "nonempty" "state-init records BASE"
bash "$KGP" state-done 3 >/dev/null
assert_eq "$(bash "$KGP" state-get last_completed_phase)" "3" "state-done 3 advances frontier"
assert_eq "$(bash "$KGP" state-get phase_3)" "ok" "state-done 3 marks phase_3=ok"
assert_eq "$(bash "$KGP" state-get BASE)" "$BASE" "state-done preserves BASE"
bash "$KGP" --restart    >/dev/null
assert_eq "$([ -f "$SKY_KGP_STATE" ] && echo present || echo gone)" "gone" "--restart clears the state file"
rm -rf "$(dirname "$SKY_KGP_STATE")"
exit "$fail"
```

Run: `bash runtime-rust/scripts/lib/keep_go_parity_test.sh`
Expected: FAIL — `state-init` etc. are unknown subcommands (script prints usage, exit 2).

- [ ] **Step 2: Implement the state machinery in `keep-go-parity.sh`**

Insert after the `STATE=...` / `SHA_F` / `LIST_F` block (around line 37), the run-state functions:

```bash
# ── Run-state file — the resume frontier for the v2 chain (spec §B) ──────────
# Gitignored, in-repo. NOT commit-derived: several phases (skydex update, scoped
# sweep, a clean audit) produce zero commits, so a commit-derived frontier would
# mis-locate. BASE is the phase-0 pre-run HEAD, fixed for the whole run.
STATE_FILE="${SKY_KGP_STATE:-$REPO/.skycache/keep-go-parity.state}"

state_init() {
  mkdir -p "$(dirname "$STATE_FILE")"
  printf 'BASE=%s\nlast_completed_phase=0\n' "$(git rev-parse HEAD)" > "$STATE_FILE"
}
state_get() {  # state_get <key> → value (empty if absent)
  [ -f "$STATE_FILE" ] || return 0
  sed -n "s/^$1=//p" "$STATE_FILE" | tail -1
}
state_set() {  # state_set <key> <value> — portable (no in-place sed)
  local k="$1" v="$2" tmp
  [ -f "$STATE_FILE" ] || state_init
  tmp="$(mktemp)"
  awk -v k="$k" -v v="$v" '
    $0 ~ "^"k"=" { print k"="v; done=1; next } { print }
    END { if (!done) print k"="v }' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}
state_done() { state_set last_completed_phase "$1"; state_set "phase_$1" ok; }   # phase N complete
state_clear() { rm -f "$STATE_FILE"; }
```

Then add the subcommands to the `case "$cmd"` block (before the `*)` default):

```bash
  state-init)  state_init; echo "keep-go-parity: state @ $STATE_FILE (BASE=$(state_get BASE))" ;;
  state-get)   state_get "${2:?state-get <key>}" ;;
  state-done)  state_done "${2:?state-done <phase-number>}"; echo "phase ${2} done (frontier=$(state_get last_completed_phase))" ;;
  state-show)  [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo "(no run-state — fresh run)" ;;
  --restart)   state_clear; echo "keep-go-parity: run-state cleared — next run starts at phase 0" ;;
```

- [ ] **Step 3: Run the test — verify it passes**

Run: `bash runtime-rust/scripts/lib/keep_go_parity_test.sh`
Expected: all `ok`, exit 0.

- [ ] **Step 4: Commit**

```bash
git add runtime-rust/scripts/keep-go-parity.sh runtime-rust/scripts/lib/keep_go_parity_test.sh
git commit -m "feat(rust): keep-go-parity run-state file (resume frontier, spec §B)"
```

- [ ] **Step 5: Write the failing test for `scoped-sweep` dry-run**

`scoped-sweep` computes `changed_examples "$BASE"` (BASE from the state file) and runs `examples-sweep` with `RUST_EXAMPLES` set to that list. Add a `--dry-run` that prints the list + the command WITHOUT running the sweep (so it's testable without a 30-min sweep).

Add to `keep_go_parity_test.sh` before `exit "$fail"`:

```bash
# scoped-sweep --dry-run prints a RUST_EXAMPLES list derived from BASE, no sweep run.
export SKY_KGP_STATE="$(mktemp -u)/state2"
bash "$KGP" state-init >/dev/null
OUT="$(bash "$KGP" scoped-sweep --dry-run 2>&1)"
assert_eq "$(printf '%s\n' "$OUT" | grep -c 'RUST_EXAMPLES=')" "1" "scoped-sweep --dry-run emits a RUST_EXAMPLES= line"
assert_eq "$(printf '%s\n' "$OUT" | grep -c 'examples-sweep.sh')" "1" "scoped-sweep --dry-run names the sweep it WOULD run"
rm -rf "$(dirname "$SKY_KGP_STATE")"
```

Run: `bash runtime-rust/scripts/lib/keep_go_parity_test.sh`
Expected: FAIL — `scoped-sweep` is an unknown subcommand.

- [ ] **Step 6: Implement `scoped-sweep`**

Add to the `case "$cmd"` block:

```bash
  scoped-sweep)
    # Phase-5 helper: scope examples-sweep to the change blast-radius since BASE.
    # changed_examples lives in lib/examples.sh (already sourced). RUST_EXAMPLES
    # is examples-sweep's subset override. --dry-run prints the plan only.
    base="$(state_get BASE)"
    [ -n "$base" ] || { echo "ERROR: no BASE in run-state — run 'keep-go-parity.sh state-init' first." >&2; exit 3; }
    mapfile -t SCOPED < <(changed_examples "$base")
    list="${SCOPED[*]}"
    echo "scoped-sweep: ${#SCOPED[@]} example(s) since $base"
    echo "RUST_EXAMPLES=$list"
    if [ "${2:-}" = "--dry-run" ]; then
      echo "would run: SKY_SWEEP_FORCE=1 RUST_EXAMPLES='$list' bash $SCRIPTS/examples-sweep.sh"
      exit 0
    fi
    if command -v timeout >/dev/null 2>&1; then
      SKY_SWEEP_FORCE=1 RUST_EXAMPLES="$list" timeout 7200 bash "$SCRIPTS/examples-sweep.sh"; exit $?
    else
      SKY_SWEEP_FORCE=1 RUST_EXAMPLES="$list" bash "$SCRIPTS/examples-sweep.sh"; exit $?
    fi
    ;;
```

Note: `$SCRIPTS` is defined at line 97 (`SCRIPTS="$REPO/runtime-rust/scripts"`) — move that definition ABOVE the `case` if it isn't already (it is, at line 97, before the case at 100 — confirm during edit; if the case starts before `SCRIPTS=`, hoist it).

- [ ] **Step 7: Run the test + a real dry-run**

Run:
```bash
bash runtime-rust/scripts/lib/keep_go_parity_test.sh
bash -n runtime-rust/scripts/keep-go-parity.sh && echo "syntax ok"
( cd "$PWD" && bash runtime-rust/scripts/keep-go-parity.sh state-init >/dev/null \
  && bash runtime-rust/scripts/keep-go-parity.sh scoped-sweep --dry-run )
```
Expected: test all `ok`; `syntax ok`; the dry-run prints a `RUST_EXAMPLES=` list (≥ the floor) and the `would run:` line. Then `git checkout -- .skycache 2>/dev/null; rm -f .skycache/keep-go-parity.state` cleanup (it's gitignored).

- [ ] **Step 8: Commit**

```bash
git add runtime-rust/scripts/keep-go-parity.sh runtime-rust/scripts/lib/keep_go_parity_test.sh
git commit -m "feat(rust): keep-go-parity scoped-sweep — changed_examples → RUST_EXAMPLES"
```

- [ ] **Step 9: Rewrite the keep-go-parity SKILL.md to the 8-phase v2 chain**

Modify `runtime-rust/plugins/sky-rust-backend/skills/keep-go-parity/SKILL.md`. Replace the `## Workflow (execute in order)` section with the 8-phase chain from spec §B, keeping the existing Principles / planner-rationale / gotchas / capture-learnings sections. The new workflow table + narrative:

```markdown
## Workflow — the v2 chain (resumable via .skycache/keep-go-parity.state)

Resume is driven by the **run-state file**, NOT the last commit (phases 2/4/5/6
produce zero commits). On entry: if a state file exists, resume at
`last_completed_phase + 1`; else `state-init` (records BASE = HEAD) and start at
phase 1. `keep-go-parity.sh --restart` forces a fresh run. After each phase
completes, `keep-go-parity.sh state-done <N>`.

| # | Phase | Skill / step | Commits? |
|---|---|---|---|
| 0 | `state-init` — record BASE = HEAD | `keep-go-parity.sh state-init` | no |
| 1 | sync + resolve conflicts | **sky-rust-backend:sync-with-upstream** | merge commit |
| 2 | re-index | `skydex update` | no |
| 3 | implement new functionality | **sky-rust-backend:implement-parity-gap** (`skydex parity --gaps` → swarm) | work commits |
| 4 | re-index | `skydex update` | no |
| 5 | **scoped** build·run·equivalence·round-trip | `keep-go-parity.sh scoped-sweep` (changed_examples → RUST_EXAMPLES) | no |
| 6 | audit the diff | **sky-rust-backend:quality-audit** + **sky-rust-backend:principles-audit** (incremental, since BASE) | fix commits |
| 7 | docs | **sky-rust-backend:update-docs** | docs commit |
| 8 | push → CI full verification | **sky-rust-backend:push** → CI: full 3-OS sweep + examples-perf-sweep + static-perf | — |

- Phase 3 escalates per implement-parity-gap's gate (subsystem-scale / no
  equivalence oracle → stop + signal the user).
- Phase 5 is **fast pre-push feedback**, scoped to the diff blast-radius since
  BASE. Honest contract: precise only for example-source changes; for
  runtime/codegen changes the scope widens broadly and **CI's full 3-OS sweep on
  push (phase 8) is the real gate** — keep-go-parity does NOT gate on the scoped
  local run for runtime/codegen changes.
- `skydex update` is **early** (2 + 4), never last — phases 3/5/6 consume the index.
- Work commits stay separate from the state file (bisectability); the state file
  is bookkeeping, never bundled into a work commit.
```

- [ ] **Step 10: Verify the SKILL.md edits + cross-reference integrity**

Run:
```bash
grep -q 'scoped-sweep' runtime-rust/plugins/sky-rust-backend/skills/keep-go-parity/SKILL.md && echo "chain wired"
grep -q 'implement-parity-gap' runtime-rust/plugins/sky-rust-backend/skills/keep-go-parity/SKILL.md && echo "new skill referenced"
grep -q 'keep-go-parity.state' runtime-rust/plugins/sky-rust-backend/skills/keep-go-parity/SKILL.md && echo "resume documented"
```
Expected: all three echo.

- [ ] **Step 11: Commit**

```bash
git add runtime-rust/plugins/sky-rust-backend/skills/keep-go-parity/SKILL.md
git commit -m "docs(rust): keep-go-parity v2 — 8-phase chain, scoped sweep, state-file resume"
```

---

## Final verification (all tasks)

- [ ] **Both unit-test suites green:**
```bash
bash runtime-rust/scripts/lib/examples_test.sh
bash runtime-rust/scripts/lib/keep_go_parity_test.sh
```
Expected: both exit 0, all `ok`.

- [ ] **All touched scripts lint clean:**
```bash
bash -n runtime-rust/scripts/lib/examples.sh
bash -n runtime-rust/scripts/keep-go-parity.sh
echo "syntax ok"
```

- [ ] **The three deliverables exist:** `changed_examples` in `examples.sh`; `implement-parity-gap/SKILL.md`; `scoped-sweep` + `state-*` in `keep-go-parity.sh` and the v2 chain in the keep-go-parity SKILL.md.

- [ ] **No state file leaked into git** (it's gitignored, but confirm): `git status --porcelain | grep -c keep-go-parity.state` → `0`.

- [ ] **Spec coverage:** §A → Task 2 (autonomy table, equivalence gate, escalation); §B → Task 3 (8-phase chain, state-file resume, skydex-early); §C → Task 1 (changed_examples partition, RUST_EXAMPLES wiring, honest contract). No push (phase 8 is the user's call / CI).

---

## Notes for the executor

- **Do NOT run a full `examples-sweep`** during this work — the tests use `--dry-run` and empty/synthetic diffs precisely to avoid the 30-min sweep. The real sweep is phase 5/8 of the chain itself, run later.
- **macOS portability:** `state_get` uses `sed -n s///p` (read-only, portable); `state_set` uses `awk` + temp + `mv` (never `sed -i`). `mapfile`/`declare -A` require bash ≥4 — the repo's sweeps already rely on both, so this matches the established baseline.
- **skydex may be unbuilt locally** — `_runtime_paths_to_covered_examples` is guarded to emit nothing in that case, and the tests don't depend on it. That's intentional (best-effort enrichment).
- This plan ships **local-only**: commits land on `feat/runtime-rust`; pushing is the chain's phase 8 / the user's explicit call.
