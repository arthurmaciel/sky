# Rust-backend Floor Stabilization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stabilize the in-flight `Builder/` codegen split so `--target rust` works again, prove the new emitter equivalent to the known-good monolith on every example the monolith supports, unbreak the clippy gate, and add an all-example sweep scoreboard.

**Architecture:** Build a reference compiler (`sky-ref`) from a git worktree at HEAD — which is *still* the monolith because the split is uncommitted — paired with the current runtime crate, isolating the emitter as the only variable. A differential harness checks the WIP emitter against `sky-ref` on a three-part equivalence relation (behavioral byte-identical run output = hard gate; rustfmt'd structural diff = explained-only review; clippy parity). A separate sweep script bins all examples. Clippy debt is fixed at root cause.

**Tech Stack:** Haskell (GHC 9.4, `cabal`), Rust (`cargo`, `rustfmt`, `clippy`), Bash, the Sky compiler (`sky build --target rust`).

---

## Spec

Design: `runtime-rust/docs/superpowers/specs/2026-06-09-rust-backend-floor-stabilization-design.md`. Read it before starting.

## Preconditions (read once)

- Work on branch `feat/runtime-rust`. Never run `sky build` from the repo root (overwrites `sky-out/sky`); always `cd examples/<ex>` first.
- **Keep `runtime-rust/` clean (committed) during the equivalence loop.** Both `sky-ref` and `sky-wip` copy the runtime crate into the generated project; if the working-tree runtime differs from HEAD's, the runtime — not the emitter — becomes a variable. Commit or stash runtime edits before running `rust-equiv.sh`.
- Bound every build/test with `timeout` (CLAUDE.md rule 3).
- Commits carry **no co-author line** (project rule).
- All new docs go under `runtime-rust/docs/`, never repo-root `docs/`.
- Disk hygiene: remove the reference worktree + run `go clean`/cargo prune at the end (CLAUDE.md rule 6).

## File Structure

| File | Create/Modify | Responsibility |
|---|---|---|
| `scripts/rust-sweep.sh` | Create | W3 — bin every example by how far `--target rust` gets (build-level scoreboard). |
| `scripts/rust-equiv.sh` | Create | Unit-3 — differential equivalence check for one example (structural + behavioral). |
| `scripts/equiv-battery/07-todo-cli.sh` | Create | Per-example input battery + volatile-field canonicalizer (template for others). |
| `src/Sky/Generate/Rust/Builder/ModuleEmitter.hs` | Modify | W1.0 crash fix + equivalence-loop fixes. |
| `src/Sky/Generate/Rust/Builder/*.hs` | Modify (as surfaced) | Equivalence-loop fixes the harness pins to a specific emitter module. |
| `scripts/verify-rust-target.sh` | Modify | Stop masking clippy failure; wire in the sweep. |
| `runtime-rust/src/sky_runtime/{decimal,time,math,char_kernel,auth,basics,live/*}.rs` | Modify | W2 — root-cause clippy fixes. |

---

## Task 1: Reference binary (`sky-ref`) in a worktree

**Files:**
- Create: `.equiv/sky-ref/` (git worktree, gitignored — see Step 4)

- [ ] **Step 1: Confirm HEAD is still the monolith**

Run: `git show HEAD:src/Sky/Generate/Rust/Builder.hs | grep -c "exprToRustInner ctx e = case e of"`
Expected: `1` (HEAD's Builder.hs is the 4,312-line monolith; the split is uncommitted).

- [ ] **Step 2: Create the reference worktree at HEAD**

```bash
git worktree add --detach .equiv/sky-ref HEAD
```
Expected: `Preparing worktree (detached HEAD <sha>)`.

- [ ] **Step 3: Build the reference compiler**

```bash
( cd .equiv/sky-ref && timeout 1800 cabal install --overwrite-policy=always \
    --installdir=./sky-out --install-method=copy exe:sky )
```
Expected: build succeeds; `.equiv/sky-ref/sky-out/sky --version` prints `sky dev` (not a server).

- [ ] **Step 4: Ignore the worktree dir**

Add `/.equiv/` to `.gitignore` if not present:
```bash
grep -qxF '/.equiv/' .gitignore || echo '/.equiv/' >> .gitignore
```

- [ ] **Step 5: Smoke-test the reference on hello-world**

```bash
( cd examples/01-hello-world && rm -rf sky-out .skycache .skydeps \
  && ../../.equiv/sky-ref/sky-out/sky build src/Main.sky --target rust \
  && cargo build --manifest-path sky-out/Rust/Cargo.toml -q \
  && ./sky-out/Rust/target/debug/* )
```
Expected: prints `Hello from Sky!` — confirms `sky-ref` is the known-good reference.

- [ ] **Step 6: Commit the gitignore change**

```bash
git add .gitignore
git commit -m "chore(rust): gitignore the equivalence-harness worktree dir"
```

---

## Task 2: Build the WIP compiler and capture the crash

**Files:**
- Modify: none (diagnostic only)

- [ ] **Step 1: Build the WIP compiler (the Builder/ split)**

```bash
timeout 1800 cabal install --overwrite-policy=always --installdir=./sky-out --install-method=copy exe:sky
```
Expected: Haskell build succeeds (the split compiles; the bug is a runtime non-exhaustive `case`, not a compile error).

- [ ] **Step 2: Reproduce the crash and capture it**

```bash
( cd examples/01-hello-world && rm -rf sky-out .skycache .skydeps \
  && ../../sky-out/sky build src/Main.sky --target rust ) 2>&1 | tee /tmp/wip-crash.log
```
Expected: FAIL with `ModuleEmitter.hs:(1442,…)-(1702,…): Non-exhaustive patterns in case`.

- [ ] **Step 3: Record the failing input**

The crash is in `exprToRustInner :: EmitCtx -> Can.Expr_ -> String`. Note that generation got as far as writing `sky_core_string.rs`, so the unhandled expression is in a stdlib module's lowering. No commit (diagnostic).

---

## Task 3: W1.0 — fix the `ModuleEmitter` non-exhaustive crash

**Files:**
- Modify: `src/Sky/Generate/Rust/Builder/ModuleEmitter.hs` (the `exprToRustInner` case, ~lines 1442–1702)
- Reference: `git show HEAD:src/Sky/Generate/Rust/Builder.hs` (`exprToRustInner` at :2265)

- [ ] **Step 1: Extract both versions of `exprToRustInner` for diffing**

```bash
# Monolith (known-good) version:
git show HEAD:src/Sky/Generate/Rust/Builder.hs \
  | awk '/^exprToRustInner ::/{p=1} p{print} /^$/{if(p&&++blank>1 && started)exit} /case e of/{started=1}' \
  > /tmp/ref-expr.hs
# Pragmatic fallback if the awk window is wrong — pull a generous range and trim by eye:
git show HEAD:src/Sky/Generate/Rust/Builder.hs | sed -n '2265,2900p' > /tmp/ref-expr.hs
sed -n '1441,1702p' src/Sky/Generate/Rust/Builder/ModuleEmitter.hs > /tmp/wip-expr.hs
```

- [ ] **Step 2: Diff the constructor arms each version handles**

```bash
# List the top-level Can.* arms each function matches, in order:
grep -oE 'Can\.[A-Z][A-Za-z]+' /tmp/ref-expr.hs | sort -u > /tmp/ref-arms.txt
grep -oE 'Can\.[A-Z][A-Za-z]+' /tmp/wip-expr.hs | sort -u > /tmp/wip-arms.txt
diff /tmp/ref-arms.txt /tmp/wip-arms.txt
```
Expected: the diff (or a closer read of guard ordering / a missing final catch-all `_ ->`) reveals the arm dropped or mis-guarded during the split. Common culprits: a lost trailing `_ -> …` catch-all, or a guarded `Can.Call …` arm whose guards no longer cover all paths so it falls through with no successor.

- [ ] **Step 3: Restore the missing/mis-guarded arm**

Copy the missing arm (or the final catch-all) verbatim from `/tmp/ref-expr.hs` into the WIP `exprToRustInner` at the correct position (guard order matters — literals/specific guards before the catch-all). Adapt only the names that the split renamed (verify against `Builder/Types.hs` / `Builder/Kernel.hs` exports). Do NOT silence the crash with a blanket `_ -> ""` — that would emit wrong Rust; restore the *real* arm the monolith had.

- [ ] **Step 4: Rebuild the WIP compiler**

```bash
timeout 1800 cabal install --overwrite-policy=always --installdir=./sky-out --install-method=copy exe:sky
```
Expected: builds.

- [ ] **Step 5: Verify hello-world now generates, builds, and runs**

```bash
( cd examples/01-hello-world && rm -rf sky-out .skycache .skydeps \
  && ../../sky-out/sky build src/Main.sky --target rust \
  && cargo build --manifest-path sky-out/Rust/Cargo.toml -q \
  && ./sky-out/Rust/target/debug/* )
```
Expected: `Hello from Sky!`. If a *different* non-exhaustive crash now appears (a second dropped arm), repeat Steps 2–4 until hello-world is clean.

- [ ] **Step 6: Commit**

```bash
git add src/Sky/Generate/Rust/Builder/ModuleEmitter.hs
git commit -m "fix(rust): restore exprToRustInner arm dropped in the Builder/ split

The flat-to-package split lost <arm/catch-all>, so exprToRustInner was
non-exhaustive and crashed on the first <constructor> expression. Restored
verbatim from the HEAD monolith. 01-hello-world generates + builds + runs."
```

---

## Task 4: W3 — write the sweep scoreboard

**Files:**
- Create: `scripts/rust-sweep.sh`

- [ ] **Step 1: Write the sweep script**

Create `scripts/rust-sweep.sh`:
```bash
#!/usr/bin/env bash
# All-example --target rust sweep. Bins every examples/[0-9]* (+ simple,
# test_pkg) by how far the Rust backend gets. Build-level only; run-level
# equivalence lives in scripts/rust-equiv.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
SKY="${SKY_BIN:-$PWD/sky-out/sky}"
[ -x "$SKY" ] || { echo "ERROR: sky binary not at $SKY (build: cabal install … exe:sky)"; exit 1; }

# Examples with no Rust monolith reference — recorded, not equivalence-checked.
OUT_OF_SCOPE=" 02 06 11 19 21 22 23 24 25 26 27 29 31 34 36 37 38 "

printf "%-26s %s\n" "EXAMPLE" "RESULT"
printf "%-26s %s\n" "-------" "------"
for d in $(ls -d examples/[0-9]*/ examples/simple/ examples/test_pkg/ 2>/dev/null); do
  n=$(basename "$d")
  [ -f "${d}src/Main.sky" ] || continue
  num=$(echo "$n" | grep -oE '^[0-9]+' || true)
  ( cd "$d" && rm -rf sky-out .skycache .skydeps )
  if ! ( cd "$d" && timeout 180 "$SKY" build src/Main.sky --target rust >/tmp/sweep-$n.sky.log 2>&1 ); then
    if grep -qE "Non-exhaustive|CallStack \(from HasCallStack\)|Prelude\.[a-z]+: |internal error" /tmp/sweep-$n.sky.log; then
      r="sky-CRASH"
    else
      r="sky-build-fails"
    fi
  elif ( cd "$d" && timeout 600 cargo build --manifest-path sky-out/Rust/Cargo.toml -q >/tmp/sweep-$n.cargo.log 2>&1 ); then
    r="builds"
  else
    r="cargo-fails"
  fi
  case "$OUT_OF_SCOPE" in *" $num "*) r="$r (out-of-scope)";; esac
  printf "%-26s %s\n" "$n" "$r"
done
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/rust-sweep.sh`

- [ ] **Step 3: Run the sweep to produce the baseline scoreboard**

Run: `timeout 3000 scripts/rust-sweep.sh | tee /tmp/rust-sweep-baseline.txt`
Expected: a table. `01-hello-world` shows `builds`; the out-of-scope examples show their category tagged `(out-of-scope)`; any remaining `sky-CRASH` rows are the next W1 crash fixes.

- [ ] **Step 4: Commit the script**

```bash
git add scripts/rust-sweep.sh
git commit -m "feat(rust): all-example --target rust sweep scoreboard"
```

---

## Task 5: Wire the sweep into the gate and stop masking clippy

**Files:**
- Modify: `scripts/verify-rust-target.sh`

- [ ] **Step 1: Find the clippy step that swallows failure**

The current clippy step is `(cd runtime-rust && cargo clippy … 2>&1 | tail -3)` — the `| tail -3` lets the pipeline's exit be `tail`'s, so under `set -e` it can fail to abort yet still hide the error count.

- [ ] **Step 2: Replace the clippy step so its real exit propagates and the output is visible**

In `scripts/verify-rust-target.sh`, change the clippy block to:
```bash
echo "=== 2. Cargo clippy (-D warnings) ==="
( cd runtime-rust && cargo clippy --all-targets --all-features -- -D warnings ) \
    || { echo "CLIPPY FAILED"; exit 1; }
```

- [ ] **Step 3: Append a sweep step after the six-example step**

Add before the final "All checks passed":
```bash
echo ""
echo "=== 6. All-example --target rust sweep ==="
scripts/rust-sweep.sh | tee /tmp/rust-sweep.txt
if grep -qE "sky-CRASH|cargo-fails" /tmp/rust-sweep.txt | grep -v "out-of-scope"; then
    echo "Sweep shows in-scope failures — see /tmp/rust-sweep.txt"
fi
```
(Note: the sweep is informational here — it never *fails* the gate on out-of-scope examples. In-scope regressions are caught by `rust-equiv.sh`, Task 7.)

- [ ] **Step 4: Commit**

```bash
git add scripts/verify-rust-target.sh
git commit -m "fix(rust): verify gate surfaces real clippy exit + runs the sweep"
```

---

## Task 6: Unit-3 — the differential equivalence runner

**Files:**
- Create: `scripts/rust-equiv.sh`
- Create: `scripts/equiv-battery/07-todo-cli.sh` (template battery)

- [ ] **Step 1: Write the equivalence runner**

Create `scripts/rust-equiv.sh`:
```bash
#!/usr/bin/env bash
# Differential equivalence for ONE example: generate with the reference
# monolith (sky-ref) and the WIP emitter (sky-wip), then check the three-part
# relation. Exit 0 = equivalent; 1 = regression; 3 = out-of-scope (ref can't
# build it either).
set -uo pipefail
cd "$(dirname "$0")/.."
EX="$1"
REF="${SKY_REF:-$PWD/.equiv/sky-ref/sky-out/sky}"
WIP="${SKY_WIP:-$PWD/sky-out/sky}"
D="examples/$EX"
[ -f "$D/src/Main.sky" ] || { echo "no such example: $EX"; exit 2; }

gen() { # $1=binary $2=outdir
  ( cd "$D" && rm -rf sky-out .skycache .skydeps && timeout 180 "$1" build src/Main.sky --target rust ) \
      >/tmp/equiv-$EX.gen.log 2>&1 || return 1
  rm -rf "$2"; cp -r "$D/sky-out/Rust" "$2"
}
REFD=/tmp/equiv-$EX-ref ; WIPD=/tmp/equiv-$EX-wip
gen "$REF" "$REFD" || { echo "OUT-OF-SCOPE[$EX]: ref cannot generate it"; exit 3; }
gen "$WIP" "$WIPD" || { echo "FAIL[$EX]: WIP failed to generate (ref succeeded)"; exit 1; }

# (1) Structural review aid: concat WIP modules, rustfmt both, strip split-plumbing, diff.
norm() { find "$1/src" -name '*.rs' | sort | xargs cat \
    | rustfmt --emit stdout 2>/dev/null \
    | grep -vE '^\s*(pub )?mod [a-z_]+;|^\s*use (crate|super)::' ; }
diff <(norm "$REFD") <(norm "$WIPD") > /tmp/equiv-$EX.struct.diff || true
[ -s /tmp/equiv-$EX.struct.diff ] && \
    echo "STRUCT[$EX]: review /tmp/equiv-$EX.struct.diff — every line must be split-plumbing/path-qualification only"

# (2) Behavioral hard gate: build both, run both under the battery, byte-compare.
cargo build --manifest-path "$REFD/Cargo.toml" -q || { echo "OUT-OF-SCOPE[$EX]: ref cargo-build failed"; exit 3; }
cargo build --manifest-path "$WIPD/Cargo.toml" -q || { echo "FAIL[$EX]: WIP cargo-build failed"; exit 1; }
battery="scripts/equiv-battery/$EX.sh"
run() { if [ -x "$battery" ]; then "$battery" "$1"; else timeout 30 "$1" </dev/null 2>&1 || true; fi ; }
REFBIN=$(find "$REFD/target/debug" -maxdepth 1 -type f -executable | head -1)
WIPBIN=$(find "$WIPD/target/debug" -maxdepth 1 -type f -executable | head -1)
if diff <(run "$REFBIN") <(run "$WIPBIN") > /tmp/equiv-$EX.behav.diff; then
  echo "OK[$EX]: behavioral byte-identical${struct_note:-}"
  exit 0
else
  echo "FAIL[$EX]: behavioral diff → /tmp/equiv-$EX.behav.diff"; exit 1
fi
```

- [ ] **Step 2: Write the template input battery (todo-cli)**

Create `scripts/equiv-battery/07-todo-cli.sh` — drives a fixed CRUD sequence and masks volatile row-ids/timestamps so two runs are comparable:
```bash
#!/usr/bin/env bash
# Input battery for 07-todo-cli. $1 = path to the built binary.
# Runs a deterministic command sequence; masks volatile ids/timestamps.
set -u
BIN="$1"
tmp=$(mktemp -d)
db="$tmp/todos.db"
out() { TODO_DB="$db" timeout 20 "$BIN" "$@" </dev/null 2>&1; }
{
  out add "buy milk"
  out add "write spec"
  out list
  out done 1
  out list
  out remove 2
  out list
  out clear
} | sed -E 's/\b[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9:.]+/<ts>/g; s/\bid=[0-9]+/id=<n>/g'
rm -rf "$tmp"
```
(Adapt the flags/env to the example's real CLI — read `examples/07-todo-cli/src/Main.sky` for the exact command names and DB-path mechanism. The mask line strips timestamps and numeric ids; extend it if the example prints other volatile values like uuids.)

- [ ] **Step 3: Make them executable**

Run: `chmod +x scripts/rust-equiv.sh scripts/equiv-battery/07-todo-cli.sh`

- [ ] **Step 4: Smoke-test the runner on hello-world (no battery needed)**

Run: `scripts/rust-equiv.sh 01-hello-world`
Expected: `OK[01-hello-world]: behavioral byte-identical` (no STRUCT line, or a STRUCT line containing only `mod`/`use` plumbing).

- [ ] **Step 5: Commit**

```bash
git add scripts/rust-equiv.sh scripts/equiv-battery/07-todo-cli.sh
git commit -m "feat(rust): differential equivalence runner + todo-cli input battery"
```

---

## Task 7: W1 — establish the equivalence set and run the fix-forward loop

**Files:**
- Modify: `src/Sky/Generate/Rust/Builder/*.hs` (as the harness pins each regression)

- [ ] **Step 1: Discover the equivalence set empirically with `sky-ref`**

```bash
for ex in 00-standard-libs 01-hello-world 03-tea-external 04-local-pkg 05-mux-server \
          07-todo-cli 09-live-counter 10-live-component 12-skyvote 13-skyshop \
          14-task-demo 15-http-server 16-skychess 17-skymon 18-job-queue 20-cli-counter \
          28-streaming-chat 30-sse-server-demo 32-sse-relay 33-websocket-echo \
          35-composite-generics simple test_pkg; do
  ( cd examples/$ex && rm -rf sky-out .skycache .skydeps \
    && ../../.equiv/sky-ref/sky-out/sky build src/Main.sky --target rust >/dev/null 2>&1 \
    && cargo build --manifest-path sky-out/Rust/Cargo.toml -q >/dev/null 2>&1 ) \
    && echo "IN-SET  $ex" || echo "out     $ex"
done | tee /tmp/equiv-set.txt
```
Expected: the `IN-SET` rows are the authoritative equivalence set (the spec's estimate, minus any the ref can't actually build). Everything else is out-of-scope for this floor.

- [ ] **Step 2: Run the equivalence harness across the set**

```bash
while read tag ex; do [ "$tag" = "IN-SET" ] || continue
  scripts/rust-equiv.sh "$ex"
done < /tmp/equiv-set.txt | tee /tmp/equiv-run.txt
```
Expected: a mix of `OK[...]`, `FAIL[...]`, and `STRUCT[...]` lines.

- [ ] **Step 3: Fix-forward each `FAIL` (repeat until all `OK`)**

For each `FAIL[<ex>]`:
1. Read `/tmp/equiv-<ex>.gen.log` (generation/crash), `/tmp/equiv-<ex>.behav.diff` (behavioral), or the cargo log to see the symptom.
2. Identify the emitter function involved (the generated Rust line that differs points back to a `Builder/` emitter arm). Diff that function against the monolith:
   `git show HEAD:src/Sky/Generate/Rust/Builder.hs | grep -n '<funcName>'` then compare to the `Builder/*.hs` copy.
3. Restore the monolith's behavior in the `Builder/` module (root-cause; never paper over with a string hack).
4. Rebuild: `timeout 1800 cabal install --overwrite-policy=always --installdir=./sky-out --install-method=copy exe:sky`.
5. Re-run just that example: `scripts/rust-equiv.sh <ex>` → must print `OK[<ex>]`.
6. Commit per fix:
   ```bash
   git add src/Sky/Generate/Rust/Builder/<module>.hs
   git commit -m "fix(rust): <ex> equivalence — <what the split regressed>"
   ```

- [ ] **Step 4: Resolve every `STRUCT` diff**

For each `STRUCT[<ex>]`, open `/tmp/equiv-<ex>.struct.diff` and confirm **every** line is explainable by the flat→split restructuring (added `mod`/`use`, path qualification like `string_append` → `crate::sky_core_string::string_append`). Any diff line that changes an item body, signature, or literal is a regression → fix-forward as in Step 3. Behavioral `OK` + structural-explained-only = equivalent.

- [ ] **Step 5: Final harness pass — all green**

Run: `while read tag ex; do [ "$tag" = "IN-SET" ] && scripts/rust-equiv.sh "$ex"; done < /tmp/equiv-set.txt`
Expected: every in-set example prints `OK[...]`; no `FAIL`; every `STRUCT` line reviewed-and-explained. (No commit — verification.)

---

## Task 8: W2 — make `clippy -D warnings` green at root cause

**Files:**
- Modify: `runtime-rust/src/sky_runtime/{decimal,time,math,char_kernel,auth,basics}.rs`, `runtime-rust/src/sky_runtime/live/{mod,dispatch}.rs`, and any others clippy names.

- [ ] **Step 1: Get the full, current lint list grouped by file+lint**

```bash
( cd runtime-rust && cargo clippy --all-targets --all-features -- -D warnings 2>&1 ) \
  | grep -E "^(error|warning):|-->" | tee /tmp/clippy.txt
```
Expected: ~47 errors. Known categories: `clone-on-Copy` (`decimal.rs` ×12, `time.rs` `DateTime`), `////` doc-comments (`time.rs` ×9), `f64::consts::PI` approximation (`math.rs` ×3), `RangeInclusive::contains` manual impls, `redundant closure`, `very complex type`, `too many arguments`, `match → matches!`, `manual ok`.

- [ ] **Step 2: Fix the `clone-on-Copy` lints (decimal.rs, time.rs)**

`Decimal` and `DateTime<Tz>` are `Copy`; `.clone()` on them is redundant. Remove the `.clone()` calls clippy flags (the value is `Copy`, so removal is behavior-preserving). Example shape:
```rust
// before:  let d2 = d.clone();
// after:   let d2 = d;
```
Run after: `( cd runtime-rust && cargo clippy --all-features -- -D warnings 2>&1 | grep -c "clone.*Copy" )` → `0`.

- [ ] **Step 3: Fix the `////` doc-comment lints (time.rs)**

Lines beginning `////` are section dividers clippy reads as malformed doc-comments. Change `////…` rulers to `// …` (a normal comment), or to a real `///` doc line where it documents the next item. Pick per line by reading context.

- [ ] **Step 4: Fix the PI-approximation lints (math.rs)**

Replace literal `3.14159…` with `std::f64::consts::PI` (and `E`, etc.). The runtime already exposes `math_pi()` returning `std::f64::consts::PI` — make the flagged sites use the constant, not a literal.

- [ ] **Step 5: Fix the remaining structural lints**

Work down `/tmp/clippy.txt`: `manual RangeInclusive::contains` → `(lo..=hi).contains(&x)`; `redundant closure` → pass the function directly; `match → matches!` → `matches!(…)`; `manual ok` → `.ok()`; `very complex type` → a `type` alias; `too many arguments` → leave only if it's a generated-signature constraint, else a small struct. Each is a local, behavior-preserving rewrite.

- [ ] **Step 6: Verify clippy is green**

Run: `( cd runtime-rust && cargo clippy --all-targets --all-features -- -D warnings )`
Expected: exit 0, no output.

- [ ] **Step 7: Verify the fixes didn't change runtime behavior**

Run: `( cd runtime-rust && timeout 600 cargo test --all-features 2>&1 | grep "^test result" )`
Expected: still `202 passed; 0 failed` across the suites.

- [ ] **Step 8: Commit**

```bash
git add runtime-rust/src/sky_runtime
git commit -m "fix(rust): clippy -D warnings green at root cause

Clear the ~47 clippy-1.92 lints (clone-on-Copy in decimal/time, ////
doc-rulers in time, PI literals in math, manual range/closure/matches
rewrites). Behavior-preserving — cargo test --all-features still 202/0."
```

---

## Task 9: Final gate + cleanup

**Files:**
- Modify: none

- [ ] **Step 1: Run the full verification gate end-to-end**

Run: `timeout 3600 scripts/verify-rust-target.sh`
Expected: passes — cargo check, clippy (exit 0), `cargo test` (202/0), the six examples build, and the sweep prints the scoreboard with no in-scope `sky-CRASH`/`cargo-fails`.

- [ ] **Step 2: Run the equivalence harness one final time**

Run: `while read tag ex; do [ "$tag" = "IN-SET" ] && scripts/rust-equiv.sh "$ex"; done < /tmp/equiv-set.txt`
Expected: every in-set example `OK`.

- [ ] **Step 3: Remove the reference worktree and reclaim disk**

```bash
git worktree remove --force .equiv/sky-ref
git worktree prune
go clean -cache 2>/dev/null || true
df -h / | tail -1
```
Expected: worktree gone; free space recovered.

- [ ] **Step 4: Clean up background/orphan processes (CLAUDE.md rule 2)**

```bash
ps -u "$USER" -o pid,command | awk '/examples\/.*sky-out/ {print $1}' | xargs -r -n1 kill -9 2>/dev/null || true
```

- [ ] **Step 5: Final status commit (if any tracked cleanup remains)**

```bash
git status --short
# commit only intended changes; the floor is green when verify-rust-target.sh
# passes end-to-end AND the equivalence harness reports all-OK on the set.
```

---

## Self-Review (completed by author)

- **Spec coverage:** W1.0 crash fix → Task 3; W1 equivalence loop → Tasks 1, 2, 6, 7; equivalence relation (behavioral/structural/clippy-parity) → Task 6 runner + Task 7 review; W2 clippy → Task 8; W3 sweep → Tasks 4–5; reference-via-worktree → Task 1; empirical equivalence set → Task 7 Step 1; volatile-output canonicalizer → Task 6 battery; cleanup/disk hygiene → Task 9. All spec sections map to a task.
- **Placeholders:** none — the crash fix and equivalence loop are intentionally procedural (the specific dropped arm / regressions are discovered at execution by diffing against the monolith), with exact commands and concrete acceptance tests, which is the correct shape for stabilizing an undiagnosed refactor. Tooling tasks carry full runnable code.
- **Type/name consistency:** `sky-ref`/`sky-wip` binaries, `scripts/rust-sweep.sh`, `scripts/rust-equiv.sh`, `scripts/equiv-battery/<ex>.sh`, and the `IN-SET`/`out` set tags are used consistently across tasks.
