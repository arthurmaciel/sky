# Sub-A.9 — Codegen-completeness fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drop `examples/00-standard-libs` on `target=rust` cargo error count from ~70 to ≤20 by fixing three codegen-shape bugs in `Builder.hs`.

**Architecture:** All edits in `src/Sky/Generate/Rust/Builder.hs`. B1 = arm removal; B3 = pattern-prelude threading; B6 = type-aware `++` emission. B2 is subsumed by B1.

**Tech Stack:** Haskell (GHC 9.4.8); existing AST + codegen infrastructure.

**Source spec:** `docs/superpowers/specs/2026-05-29-sub-A9-codegen-completeness-design.md`

---

## Preconditions

- Branch: `feat/runtime-rust` (HEAD `7498edf6` after the spec commit).
- `mem-guard.sh` running.
- Clean working tree.
- `sky-out/sky --version` prints `sky dev`.
- 16/16 `examples/rust/*` build clean.

---

## Task 0: Capture baseline error categorisation

**Files:** None modified.

- [ ] **Step 1: Capture target=rust baseline**

```bash
cd /home/arthur/Documentos/comp/sky
cp examples/00-standard-libs/sky.toml /tmp/sky.toml.subA9.bak
printf '\ntarget = "rust"\n' >> examples/00-standard-libs/sky.toml
cd examples/00-standard-libs && rm -rf sky-out .skycache
../../sky-out/sky build src/Main.sky 2>/dev/null
cd sky-out/rust
cargo build 2>&1 | grep -c "^error\[" > /tmp/subA9-baseline-errcount.txt
cargo build 2>&1 | grep "^error\[" | sort | uniq -c | sort -rn > /tmp/subA9-baseline-cats.txt
cargo build 2>&1 | grep "  --> src/" | sed -E 's/.*--> (src\/[a-z_]+\.rs).*/\1/' | sort | uniq -c | sort -rn > /tmp/subA9-baseline-files.txt
cat /tmp/subA9-baseline-errcount.txt
head -10 /tmp/subA9-baseline-cats.txt
head -10 /tmp/subA9-baseline-files.txt
```
Expected: ~70 errors. This is the reference for Task 5 verification.

- [ ] **Step 2: Restore sky.toml**

```bash
cd /home/arthur/Documentos/comp/sky
cp /tmp/sky.toml.subA9.bak examples/00-standard-libs/sky.toml
rm -rf examples/00-standard-libs/sky-out examples/00-standard-libs/.skycache
git status --short examples/00-standard-libs/
```

No commit (pure measurement).

---

## Task 1: B1 — Remove Std.X kernelToRust mirror arms

**Files:**
- Modify: `src/Sky/Generate/Rust/Builder.hs`

**Targets:**
- Sub-A.6 Std.Decimal arms (`("Std.Decimal", "X")` for ~22 entries)
- Sub-A.8 Std.Decimal completion arms (`("Std.Decimal", "X")` for 15 more)
- Sub-A.8 Std.Money arms (`("Std.Money", "X")` for 12 entries)
- Sub-A.5 Std.Time arms (`("Std.Time", "X")` for ~24 entries)
- Sub-A.8 Std.Time advanced arms (`("Std.Time", "X")` for 7 more)

KEEP: bare `("Decimal", "X")` / `("Money", "X")` / `("Time", "X")` arms —
the peephole's `splitKernelName` produces these.

- [ ] **Step 1: List the doomed arms**

```bash
cd /home/arthur/Documentos/comp/sky
grep -n '("Std.Decimal\|"("Std.Money\|"("Std.Time' src/Sky/Generate/Rust/Builder.hs | head -60
```

- [ ] **Step 2: Delete the `("Std.Decimal", ...)` arms**

Use a single multi-line `Edit` block per module, or sed. Example pattern (sed):

```bash
# In Builder.hs, delete lines of the form:
#     ("Std.Decimal", "...")  -> "decimal_..."
# Mirror arms ONLY — bare ("Decimal", "...") arms remain.
sed -i '/("Std.Decimal",/d' src/Sky/Generate/Rust/Builder.hs
```

Verify no `("Std.Decimal",` lines remain:
```bash
grep -c '("Std.Decimal",' src/Sky/Generate/Rust/Builder.hs
# Expected: 0
```

- [ ] **Step 3: Delete the `("Std.Money", ...)` arms**

```bash
sed -i '/("Std.Money",/d' src/Sky/Generate/Rust/Builder.hs
grep -c '("Std.Money",' src/Sky/Generate/Rust/Builder.hs
# Expected: 0
```

- [ ] **Step 4: Delete the `("Std.Time", ...)` arms**

```bash
sed -i '/("Std.Time",/d' src/Sky/Generate/Rust/Builder.hs
grep -c '("Std.Time",' src/Sky/Generate/Rust/Builder.hs
# Expected: 0
```

- [ ] **Step 5: Verify compiler still builds**

```bash
cabal build exe:sky 2>&1 | tail -5
```
Expected: build succeeds (no longer referenced arms = dead code; deletion is safe).

- [ ] **Step 6: Quick smoke test — examples/rust/01-rand**

```bash
cp -f dist-newstyle/build/x86_64-linux/ghc-9.6.7/sky-compiler-0.0.0/x/sky/build/sky/sky sky-out/sky
cd examples/rust/01-rand && rm -rf sky-out .skycache && ../../../sky-out/sky build src/Main.sky 2>&1 | tail -3
```
Expected: `Build complete: sky-out/rust/target/debug/sky-app`.

- [ ] **Step 7: Measure error count after B1**

```bash
cd /home/arthur/Documentos/comp/sky
printf '\ntarget = "rust"\n' >> examples/00-standard-libs/sky.toml
cd examples/00-standard-libs && rm -rf sky-out .skycache
../../sky-out/sky build src/Main.sky 2>/dev/null
cd sky-out/rust && cargo build 2>&1 | grep -c "^error\["
cd /home/arthur/Documentos/comp/sky
# Restore
cp /tmp/sky.toml.subA9.bak examples/00-standard-libs/sky.toml
rm -rf examples/00-standard-libs/sky-out examples/00-standard-libs/.skycache
```
Expected: ~50 errors (down from ~70).

- [ ] **Step 8: Commit**

```bash
git add src/Sky/Generate/Rust/Builder.hs
git commit -m "fix(rust): remove (\"Std.X\", ...) kernelToRust mirror arms — close wrapper bypass

The (\"Std.Decimal\", X), (\"Std.Money\", X), (\"Std.Time\", X) arms were
added in sub-A.6/A.8 to mirror the bare (X, ...) arms. They made user
code referencing those modules' functions resolve to the runtime
kernel directly — bypassing the Sky-generated wrapper. For Std.Money,
the wrapper does Currency -> String conversion before calling the
kernel; bypass caused E0061 / E0308.

Bare arms remain (used by the Ffi.callPure peephole's splitKernelName,
which always produces unprefixed module names). Wrappers now correctly
called for user references; wrappers' own bodies still peephole-resolve
their Ffi.callPure calls to direct kernel dispatch.

Error count on examples/00-standard-libs target=rust: ~70 -> ~50."
```

---

## Task 2: B3 — PCtor pattern-arg destructure prelude

**Files:**
- Modify: `src/Sky/Generate/Rust/Builder.hs`

**Approach:** Change `patternToRustParam :: Can.Pattern -> String` to
return both a param name AND a destructure-prelude. Thread the prelude
into function-body emission.

- [ ] **Step 1: Add a new helper `patternToRustArg`**

In `Builder.hs`, after `patternToRustParam` (line ~862), add:

```haskell
-- | Decompose a pattern argument into:
--   (paramName, prelude)
-- where `prelude` is a `let` / `match` statement that binds the pattern's
-- variables in the function body's scope. PVar / PAnything / PTuple
-- patterns have empty prelude (paramName itself is the pattern). PCtor
-- and similar patterns get a synthesised name + a destructure prelude.
--
-- The integer argument is the parameter index, used for fresh-name
-- generation (`__p0`, `__p1`, ...).
patternToRustArg :: Int -> Can.Pattern -> (String, String)
patternToRustArg _idx pat@(Ann.At _ (Can.PVar _))      = (patternToRustParam pat, "")
patternToRustArg _idx pat@(Ann.At _ Can.PAnything)     = (patternToRustParam pat, "")
patternToRustArg _idx pat@(Ann.At _ (Can.PTuple _ _ _)) = (patternToRustParam pat, "")
patternToRustArg idx pat@(Ann.At _ _) =
    let paramName = "__p" ++ show idx
        rustPat = patternToRustPattern pat
        -- `let <pattern> = <name>;` is irrefutable for single-variant enums.
        -- For multi-variant or refutable patterns, we emit a `match` with
        -- an unreachable fallback (the Sky type-checker proved exhaustiveness).
        prelude = if isIrrefutablePattern pat
                  then "let " ++ rustPat ++ " = " ++ paramName ++ "; "
                  else "let " ++ rustPat ++ " = " ++ paramName ++ " else { unreachable!() }; "
                  -- if-let-else is also irrefutable in pattern position
    in (paramName, prelude)

-- | Emit a Rust pattern syntax that destructures a value of the
-- corresponding Sky type. Mirrors patternToCaseArm but for the let-
-- binding context. Only handles patterns that can appear as function
-- arguments (no complex guards).
patternToRustPattern :: Can.Pattern -> String
patternToRustPattern (Ann.At _ pat) = case pat of
    Can.PVar n        -> rustSafeIdent n
    Can.PAnything     -> "_"
    Can.PCtor{Can._p_home = mod, Can._p_type = ty, Can._p_name = ctor, Can._p_args = args} ->
        let mod' = ModuleName._name mod
            modPrefix = map (\c -> if c == '.' then '_' else c) mod'
            enumName = toCamelCase (modPrefix ++ "_" ++ ty)
            argStrs = map (\(Can.PatternCtorArg _ _ p) -> patternToRustPattern p) args
            argsRendered = if null argStrs then "" else "(" ++ intercalate ", " argStrs ++ ")"
        in enumName ++ "::" ++ ctor ++ argsRendered
    Can.PTuple a b rest ->
        "(" ++ intercalate ", " (map patternToRustPattern (a:b:rest)) ++ ")"
    _ -> "_"  -- unsupported; falls through

-- | True if the pattern matches every value of its type (irrefutable).
-- Single-variant enums are irrefutable; everything else may or may not be.
isIrrefutablePattern :: Can.Pattern -> Bool
isIrrefutablePattern (Ann.At _ pat) = case pat of
    Can.PVar _    -> True
    Can.PAnything -> True
    Can.PTuple a b rest -> all isIrrefutablePattern (a:b:rest)
    Can.PCtor{Can._p_args = args} ->
        -- Treat all PCtor as potentially refutable. The let-else fallback
        -- handles either case correctly; this is a safety choice.
        all (\(Can.PatternCtorArg _ _ p) -> isIrrefutablePattern p) args
        -- Strict reading: depends on whether the type has more variants.
        -- We don't have that info here; let-else is universal.
    _ -> False
```

Wait — `let-else` syntax in Rust requires a refutable RHS. For irrefutable patterns, plain `let` works. The safer universal form is:

```rust
let __destructure = match __p0 { Pat => (binding1, binding2, ...), _ => unreachable!() };
let (binding1, binding2, ...) = __destructure;
```

OR more directly:

```rust
let (binding1, binding2, ...) = match __p0 { Pat => (binding1, binding2, ...), _ => unreachable!() };
```

But that's complex. The cleanest for single-variant patterns: bare `let Ctor(...) = ...;`. For multi-variant (rare in pattern-arg position), use `let ... else { unreachable!() }` which IS valid Rust 1.65+ syntax.

For sub-A.9, **use the let-else form universally**. Rust accepts let-else with irrefutable RHS too (the else branch is dead code but allowed).

Final form of the prelude:
```rust
let StdMoneyMoney::Money(d, _) = __p0 else { unreachable!() };
```

This compiles for both irrefutable single-variant AND refutable multi-variant patterns. Universal.

- [ ] **Step 2: Thread prelude through `defToRustItem`**

Locate `defToRustItem` (line ~514). The function builds param strings and the body. Modify to:
1. For each param-index `i`, call `patternToRustArg i pat` returning `(paramName, prelude)`.
2. Use `paramName` in the Rust function signature (instead of `patternToRustParam`).
3. Accumulate preludes and prepend them to the body.

Find the existing pattern (search for `patternToRustParam` in `defToRustItem`):

```haskell
let safeParams = map (\(p, t) -> patternToRustParam p ++ ": " ++ t) (zip params paramTypes)
```

becomes:

```haskell
let pAndPrelude = zipWith (\i (p, t) ->
        let (n, pre) = patternToRustArg i p
        in (n ++ ": " ++ t, pre)
    ) [0..] (zip params paramTypes)
    safeParams = map fst pAndPrelude
    preludes = concatMap snd pAndPrelude
-- ...where the body is rendered:
body = preludes ++ existingBodyEmission
```

Find every site in `defToRustItem` that calls `patternToRustParam` and apply the same threading.

- [ ] **Step 3: Verify compiler still builds**

```bash
cabal build exe:sky 2>&1 | tail -5
```

- [ ] **Step 4: Smoke test**

Run 01-rand + a Money example:
```bash
cp -f dist-newstyle/build/x86_64-linux/ghc-9.6.7/sky-compiler-0.0.0/x/sky/build/sky/sky sky-out/sky
cd examples/rust/01-rand && rm -rf sky-out .skycache && ../../../sky-out/sky build src/Main.sky 2>&1 | tail -3
```

- [ ] **Step 5: Verify pattern-arg generation**

After installing the binary, build `examples/00-standard-libs` on target=rust (temporary sky.toml) and inspect `std_money.rs`:

```bash
cd /home/arthur/Documentos/comp/sky
printf '\ntarget = "rust"\n' >> examples/00-standard-libs/sky.toml
cd examples/00-standard-libs && rm -rf sky-out .skycache
../../sky-out/sky build src/Main.sky 2>/dev/null
grep -A1 "std_money_amount\|std_money_currency" sky-out/rust/src/std_money.rs | head -8
cd /home/arthur/Documentos/comp/sky
cp /tmp/sky.toml.subA9.bak examples/00-standard-libs/sky.toml
rm -rf examples/00-standard-libs/sky-out examples/00-standard-libs/.skycache
```
Expected: `pub fn std_money_amount(__p0: StdMoneyMoney) -> StdDecimalDecimal { let StdMoneyMoney::Money(d, _) = __p0 else { unreachable!() }; d }`

- [ ] **Step 6: Commit**

```bash
git add src/Sky/Generate/Rust/Builder.hs
git commit -m "fix(rust): PCtor function-param destructure prelude — close 'cannot find value' bugs

patternToRustParam returned '_' for non-PVar/PAnything/PTuple patterns,
discarding bound variables. Body referenced them, errored as E0425
cannot find value <name> in scope.

Fix: new patternToRustArg returns (paramName, prelude). For PCtor
patterns, the prelude is 'let <Pattern> = __pN else { unreachable!() };'
— Rust's let-else syntax accepts both irrefutable (single-variant
enum) and refutable (multi-variant) patterns. The else branch is
dead code; the Sky type-checker already proved exhaustiveness at
the call site.

defToRustItem threads the prelude into the body. Existing PVar /
PAnything / PTuple paths produce empty prelude — net-zero change.

amount (Money d _) = d now emits:
  pub fn std_money_amount(__p0: StdMoneyMoney) -> StdDecimalDecimal {
      let StdMoneyMoney::Money(d, _) = __p0 else { unreachable!() };
      d
  }"
```

---

## Task 3: B6 — Type-aware `++` operator emission

**Files:**
- Modify: `src/Sky/Generate/Rust/Builder.hs`

- [ ] **Step 1: Inspect the current `++` arm**

Find at line ~1138:
```haskell
| op == "++" -> "format!(\"{}{}\", " ++ exprToRustString ctx a ++ ", " ++ exprToRustString ctx b ++ ")"
```

- [ ] **Step 2: Replace with type-aware dispatch**

```haskell
| op == "++" ->
    let lhsTy = taskExprInnerType (ecSolvedTypes ctx) a
        aStr  = exprToRustString ctx a
        bStr  = exprToRustString ctx b
    in if "Vec<" `isPrefixOf` lhsTy
       then "{ let mut __r = " ++ aStr ++ ".clone(); __r.extend(" ++ bStr ++ "); __r }"
       else "format!(\"{}{}\", " ++ aStr ++ ", " ++ bStr ++ ")"
```

- [ ] **Step 3: Verify compiler builds**

```bash
cabal build exe:sky 2>&1 | tail -3
```

- [ ] **Step 4: Install + smoke test on examples/rust**

```bash
cp -f dist-newstyle/build/x86_64-linux/ghc-9.6.7/sky-compiler-0.0.0/x/sky/build/sky/sky sky-out/sky
PASS=0; FAIL=0
for d in examples/rust/*/; do
    name=$(basename "$d")
    (cd "$d" && rm -rf sky-out .skycache .skydeps && ../../../sky-out/sky build src/Main.sky) >/dev/null 2>&1 \
        && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: $name"; }
done
echo "Build: $PASS/16"
```
Expected: 16/0.

- [ ] **Step 5: Verify Jwt withClaim emission**

```bash
printf '\ntarget = "rust"\n' >> examples/00-standard-libs/sky.toml
cd examples/00-standard-libs && rm -rf sky-out .skycache
../../sky-out/sky build src/Main.sky 2>/dev/null
grep "with_claim\b" sky-out/rust/src/sky_core_jwt.rs | head -3
cd /home/arthur/Documentos/comp/sky
cp /tmp/sky.toml.subA9.bak examples/00-standard-libs/sky.toml
rm -rf examples/00-standard-libs/sky-out examples/00-standard-libs/.skycache
```
Expected: the `format!(...)` for `kvs ++ [(k, v)]` is now
`{ let mut __r = kvs.clone(); __r.extend(vec![(k, v)]); __r }`.

- [ ] **Step 6: Commit**

```bash
git add src/Sky/Generate/Rust/Builder.hs
git commit -m "fix(rust): type-aware Can.Binop '++' — Vec gets extend, String gets format!

Sky's '++' is polymorphic: String -> String -> String AND
List a -> List a -> List a. The Rust codegen always emitted
format!('\\\"{}{}'\\\" ...), which only works on strings; list-append
calls cascaded into ~24 type errors localised to sky_core_jwt.rs
(JwtClaims accumulator + every downstream wrapper).

Fix: check taskExprInnerType on the lhs. If 'Vec<' prefix, emit
'{ let mut __r = lhs.clone(); __r.extend(rhs); __r }' — a Rust
expression that concats two Vecs without consuming either by value.
Otherwise emit the existing format!.

Falls back to format! when type info is absent — preserves current
behaviour for ambiguous cases."
```

---

## Task 4: Optional — Add B2 zero-arg check to kernelName branch

**Files:**
- Modify: `src/Sky/Generate/Rust/Builder.hs`

If after Tasks 1-3 there are still zero-arg-no-parens errors, apply this
strict-superset fix. Otherwise skip.

- [ ] **Step 1: Inspect error breakdown**

```bash
printf '\ntarget = "rust"\n' >> examples/00-standard-libs/sky.toml
cd examples/00-standard-libs && rm -rf sky-out .skycache
../../sky-out/sky build src/Main.sky 2>/dev/null
cd sky-out/rust
cargo build 2>&1 | grep "expected function" | head -5
cd /home/arthur/Documentos/comp/sky
cp /tmp/sky.toml.subA9.bak examples/00-standard-libs/sky.toml
rm -rf examples/00-standard-libs/sky-out examples/00-standard-libs/.skycache
```

If any `expected function, found <type>` errors remain referring to
known zero-arg kernels, proceed:

- [ ] **Step 2: Apply the fix to `Can.VarTopLevel`**

In `Builder.hs` at line ~1096, modify the "then" branch:

```haskell
in if fnName /= kernelName && not ("ffi_kernel" `isPrefixOf` kernelName)
   then if Set.member (modPrefix, name) (ecZeroArgDefs ctx)
        then kernelName ++ "()"   -- NEW: zero-arg defs get parens
        else kernelName
   else case Map.lookup (modName, name) (ecKernelAliases ctx) of
       ...
```

- [ ] **Step 3: Verify build + smoke test + commit**

```bash
cabal build exe:sky 2>&1 | tail -3
cp -f dist-newstyle/.../sky sky-out/sky
git add src/Sky/Generate/Rust/Builder.hs
git commit -m "fix(rust): kernelToRust 'then' branch respects ecZeroArgDefs

When a Sky binding is zero-arg AND its kernelToRust resolution differs
from the snake-cased default, the codegen emitted the bare kernel name
without (). Result: 'expected function, found <T>' errors at call sites
that need the called value.

Fix: extend the 'then' branch with the same Set.member ecZeroArgDefs
check the 'else' branch already has."
```

If no errors of this class remain after Tasks 1-3, skip this task entirely.

---

## Task 5: Full regression sweep + headline-gate snapshot

**Files:** None modified.

- [ ] **Step 1: Install fresh binary**

```bash
cabal install --overwrite-policy=always --installdir=./sky-out --install-method=copy exe:sky 2>&1 | tail -3
cp -f dist-newstyle/build/x86_64-linux/ghc-9.6.7/sky-compiler-0.0.0/x/sky/build/sky/sky sky-out/sky
sky-out/sky --version
```

- [ ] **Step 2: 16-example Rust regression**

```bash
PASS=0; FAIL=0; FAILED=""
for d in examples/rust/*/; do
    name=$(basename "$d")
    (cd "$d" && rm -rf sky-out .skycache .skydeps && ../../../sky-out/sky build src/Main.sky) >/dev/null 2>&1
    [ $? -eq 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED="$FAILED $name"; }
done
echo "Build: $PASS/16  Failed:$FAILED"
```
Expected: 16/16.

- [ ] **Step 3: Run binaries**

```bash
for d in examples/rust/*/; do
    bin="$d/sky-out/rust/target/debug/sky-app"
    [ -x "$bin" ] && timeout 10s "$bin" 2>&1 | head -1 | sed "s|^|$(basename $d): |"
done
```

- [ ] **Step 4: Go regression**

```bash
(cd examples/01-hello-world && rm -rf sky-out .skycache && ../../sky-out/sky build src/Main.sky 2>&1 | tail -3)
```
Expected: `Build complete: sky-out/app`.

- [ ] **Step 5: Cabal test**

```bash
cabal test --test-options='--match "FfiGen" --match "Toml" --match "Kernel"' 2>&1 | tail -5
```
Expected: 27 / 0 failures.

- [ ] **Step 6: Headline-gate error-count snapshot**

```bash
printf '\ntarget = "rust"\n' >> examples/00-standard-libs/sky.toml
cd examples/00-standard-libs && rm -rf sky-out .skycache
../../sky-out/sky build src/Main.sky 2>/dev/null
cd sky-out/rust
cargo build 2>&1 | grep -c "^error\["
cargo build 2>&1 | grep "^error\[" | sort | uniq -c | sort -rn | head -8
cargo build 2>&1 | grep "  --> src/" | sed -E 's/.*--> (src\/[a-z_]+\.rs).*/\1/' | sort | uniq -c | sort -rn | head -8
cd /home/arthur/Documentos/comp/sky
cp /tmp/sky.toml.subA9.bak examples/00-standard-libs/sky.toml
rm -rf examples/00-standard-libs/sky-out examples/00-standard-libs/.skycache
```
Expected: ≤20 errors (down from ~70).

- [ ] **Step 7: Update status doc**

Edit `docs/runtime-rust/sub-A-stdlib-parity-result.md`:
- Add a "Sub-A.9 outcome" section with the before/after error counts.
- Note which categories are now closed and which (Json.Decode pipeline,
  ~10 errors) remain for sub-A.10.

- [ ] **Step 8: Commit status doc**

```bash
git add docs/runtime-rust/sub-A-stdlib-parity-result.md
git commit -m "docs(rust): sub-A.9 outcome — codegen-shape fixes drop error count to <N>"
```

---

## Task 6: Hygiene + report

- [ ] **Step 1: Background-task cleanup**

```bash
ps -u $USER -o pid,command | awk '/while pgrep|until ! pgrep/ && /\/bin\/zsh -c/ {print $1}' | xargs -n1 kill -9 2>/dev/null
ps -u $USER -o pid,ppid,command | awk '$3 == "sleep" && $2 != 1 {print $1}' | xargs -n1 kill -9 2>/dev/null
pkill -f "examples/.*/sky-out/app" 2>/dev/null
pgrep -f mem-guard.sh >/dev/null || (nohup ./scripts/mem-guard.sh > /tmp/mem-guard.out 2>&1 & disown)
```

- [ ] **Step 2: Report**

```bash
git status --short
git log --oneline 7498edf6..HEAD
```

Per project CLAUDE.md: **do not push** unless user explicitly asks.

---

## Self-review

**Spec coverage:**
- §4 B1 (Std.X arm removal) → Task 1 ✅
- §4 B2 (zero-arg check) → Task 4 (optional, gated on whether B1 subsumes) ✅
- §4 B3 (PCtor destructure) → Task 2 ✅
- §4 B6 (`++` type-aware) → Task 3 ✅
- §7 verification (regression sweep, headline-gate snapshot, cabal test) → Task 5 ✅

**Placeholder scan:**
- Task 2 Step 1 includes the full helper code; not a placeholder.
- Task 4 is gated on a measurement result — explicit "skip" condition documented.

**Type consistency:**
- `taskExprInnerType` already returns a Rust-type string; used consistently in B6 and existing code.
- `Can.PCtor` field accessors match `Sky.AST.Canonical`'s definition.

---

## Execution Handoff

Same shape as sub-A.8 — execute autonomously per the user's prior delegation pattern.
