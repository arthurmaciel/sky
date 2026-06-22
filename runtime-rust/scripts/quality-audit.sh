#!/usr/bin/env bash
# Sky Rust-runtime QUALITY / SOUNDNESS audit — the deterministic harvester behind
# sky-rust-backend:quality-audit. Goes BEYOND the per-commit clippy gate
# (runtime-rust/scripts/verify-rust-target.sh) to surface, for human/agent triage, every:
#   • panic vector (unwrap/expect/panic!/unreachable!/todo!/unimplemented!)
#   • unsafe block (+ whether it carries a // SAFETY: doc)
#   • `dyn Any` / downcast / transmute / std::any site (the no-Any policy)
#   • lossy/footgun cast, indexing, float-cmp, … (curated clippy restriction set)
#   • `#[allow(...)]` exception WITHOUT a justifying comment (conscious-acceptance rule)
# plus the hard gate (clippy -D warnings) + tests. It REPORTS; the agent decides
# fix-vs-consciously-accept. Improve THIS SCRIPT after a run, never improvise.
#
# Usage:  quality-audit.sh [crate-dir]      # default: runtime-rust/
#         quality-audit.sh examples/07-todo-cli/sky-out/rust   # audit generated code
#
# Exit: 0 = hard gate (clippy -D + tests) green · 1 = gate failed · 2 = setup error.
# (The advisory findings never flip the exit — they're for triage, not a CI veto.)
set -uo pipefail

# ── Env (shared SINGLE SOURCE OF TRUTH under lib/) ──────────────────────────
source "$(dirname "$0")/lib/env.sh"
[ -n "$REPO" ] && cd "$REPO" || { echo "ERROR: run from the Sky repo (or set SKY_REPO)." >&2; exit 2; }
command -v cargo >/dev/null 2>&1 || { echo "ERROR: cargo not on PATH." >&2; exit 2; }

CRATE="${1:-runtime-rust}"
[ -f "$CRATE/Cargo.toml" ] || { echo "ERROR: no Cargo.toml at $CRATE" >&2; exit 2; }
SRC="$CRATE/src"
# runtime-rust lints all features (matches the CI gate); a generated example crate
# usually has none, so don't force --all-features there.
FEATURES="--all-features"; [ "$CRATE" = "runtime-rust" ] || FEATURES=""

HIST="$HOME/.cache/sky/quality-audit"; mkdir -p "$HIST"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
say() { echo "$@" | tee -a "$HIST/audit-$STAMP.log"; }
say "=== Sky Rust QUALITY/SOUNDNESS audit @ $STAMP (crate: $CRATE) ==="

# Non-test source files only (the Sky-reachable surface; tests legitimately panic).
mapfile -t SRC_FILES < <(find "$SRC" -name '*.rs' 2>/dev/null | sort)
if [ "${#SRC_FILES[@]}" -eq 0 ]; then
  # No .rs files: passing zero file args to grep would make it read STDIN and
  # hang. Use /dev/null as a sentinel so every `grep "${SRC_FILES[@]}"` is a
  # well-defined no-match instead.
  SRC_FILES=(/dev/null)
fi
# A heuristic "is this line inside a #[cfg(test)] / #[test] region" is unreliable
# in grep; instead we lean on clippy.toml (allow-*-in-tests) for the gate, and
# report raw counts here for the agent to eyeball against test modules.

count() { grep -rInE "$1" "${SRC_FILES[@]}" 2>/dev/null; }
n() { count "$1" | wc -l | tr -d ' '; }

# ── 1. Hard gate — clippy -D warnings (includes the denied unwrap/expect) ─────
say ""; say ">>> [GATE] cargo clippy --all-targets $FEATURES -- -D warnings"
GATE=0
( cd "$CRATE" && cargo clippy --all-targets $FEATURES -- -D warnings ) >"$HIST/clippy-gate.log" 2>&1 || GATE=1
if [ "$GATE" = 0 ]; then say "  ✓ clippy gate clean"; else say "  ✗ clippy gate FAILED — see $HIST/clippy-gate.log"; tail -20 "$HIST/clippy-gate.log" | sed 's/^/    /' | tee -a "$HIST/audit-$STAMP.log"; fi

# ── 1b. Feature-matrix leg — per-subset LIB clippy (runtime-rust only) ────────
# The --all-features gate above proves the union compiles, but NOT that each narrow
# `--features X` subset does. This is the self-containment property that GENERATED
# projects rely on: the copied runtime SOURCE (the lib) must compile under whatever
# feature set the app enables. So the matrix lints the LIBRARY per subset.
#
# Scope is `--lib`, deliberately NOT `--all-targets`: the runtime crate's OWN tests
# legitimately reference feature-gated modules (e.g. a json kernel test) and are only
# ever run under --all-features — gating every such test per-subset is churn for a
# niche `cargo test --features X` scenario, NOT the generated-project property. (The
# #12 fix gated the one wasm-floor test that broke a dev's narrow `cargo test`; that
# is hygiene, not a CI gate.) Feature names are DERIVED from Cargo.toml [features]
# (minus default/full) so the matrix never drifts.
if [ "$CRATE" = "runtime-rust" ]; then
  mapfile -t FEATS < <(awk '
    /^\[features\]/ {inf=1; next}
    /^\[/           {inf=0}
    inf && /=/ {
      key=$0; sub(/[ \t]*=.*/, "", key); gsub(/[ \t]/, "", key)
      if (key != "" && key !~ /^#/ && key != "default" && key != "full") print key
    }' "$CRATE/Cargo.toml")
  say ""; say ">>> [GATE] feature matrix — cargo clippy --lib --no-default-features --features <X> -- -D warnings (${#FEATS[@]} features + bare)"
  for f in "" "${FEATS[@]}"; do
    if [ -z "$f" ]; then sel=(--no-default-features); lbl="<bare>"; slug="bare"
    else sel=(--no-default-features --features "$f"); lbl="$f"; slug="$f"; fi
    if ( cd "$CRATE" && cargo clippy --lib "${sel[@]}" -- -D warnings ) >"$HIST/clippy-matrix-$slug.log" 2>&1; then
      say "  ✓ $lbl"
    else
      GATE=1
      say "  ✗ $lbl FAILED — see $HIST/clippy-matrix-$slug.log"
      tail -12 "$HIST/clippy-matrix-$slug.log" | sed 's/^/      /' | tee -a "$HIST/audit-$STAMP.log"
    fi
  done
fi

# ── 2. Advisory — curated soundness/footgun lints as WARNINGS (triage) ───────
say ""; say ">>> [LINTS] curated restriction/pedantic pass (advisory)"
STRICT=( -W clippy::pedantic
  -W clippy::panic -W clippy::indexing_slicing -W clippy::unreachable
  -W clippy::todo -W clippy::unimplemented -W clippy::panic_in_result_fn
  -W clippy::unwrap_in_result -W clippy::mem_forget -W clippy::exit
  -W clippy::cast_possible_truncation -W clippy::cast_possible_wrap
  -W clippy::cast_sign_loss -W clippy::cast_precision_loss
  -W clippy::float_cmp -W clippy::lossy_float_literal
  -W clippy::undocumented_unsafe_blocks -W clippy::missing_safety_doc
  -W clippy::string_slice -W clippy::integer_division )
( cd "$CRATE" && cargo clippy --all-targets $FEATURES -- "${STRICT[@]}" ) >"$HIST/clippy-strict.log" 2>&1 || true
# `grep -c` prints 0 AND exits 1 on no-match; the old `|| echo 0` then appended a
# SECOND "0", yielding a two-line value that broke the numeric `say` below. Take
# the count unconditionally (grep always prints a count) and default empty→0.
STRICT_N="$(grep -cE '^warning' "$HIST/clippy-strict.log" 2>/dev/null)"
STRICT_N="${STRICT_N:-0}"
say "  $STRICT_N advisory warnings (full log: $HIST/clippy-strict.log). Top lints:"
grep -oE 'clippy::[a-z_]+' "$HIST/clippy-strict.log" 2>/dev/null | sort | uniq -c | sort -rn | head -12 | sed 's/^/    /' | tee -a "$HIST/audit-$STAMP.log"

# ── 3. Panic-vector sweep (raw counts over non-test src) ─────────────────────
say ""; say ">>> [VECTORS] panic / abort surface in src/ (verify each is test-only or accepted)"
say "  .unwrap(            : $(n '\.unwrap\(')"
say "  .expect(            : $(n '\.expect\(')"
say "  panic!              : $(n '\bpanic!')"
say "  unreachable!        : $(n '\bunreachable!')"
say "  todo! / unimplemented!: $(n '\b(todo!|unimplemented!)')"
say "  .downcast / transmute: $(n '\.downcast|transmute')"
say "  unsafe              : $(n 'unsafe\s*(\{|fn|impl|trait)')"
say "  dyn Any / std::any  : $(n 'dyn Any|std::any|type_id')"

# ── 4. unsafe blocks must be // SAFETY-documented ────────────────────────────
say ""; say ">>> [UNSAFE] blocks + SAFETY docs"
UNSAFE_SITES="$(count 'unsafe\s*(\{|fn|impl|trait)' || true)"
if [ -z "$UNSAFE_SITES" ]; then say "  ✓ no unsafe in src/"; else
  printf '%s\n' "$UNSAFE_SITES" | sed 's/^/    /' | tee -a "$HIST/audit-$STAMP.log"
  say "  → each MUST have an adjacent // SAFETY: justification (clippy::undocumented_unsafe_blocks above)."
fi

# ── 5. dyn Any sites (no-Any policy: each must be provably-correct-by-construction) ─
say ""; say ">>> [NO-ANY] dyn Any / downcast / type_id sites"
ANY_SITES="$(count 'dyn Any|std::any|\.downcast|type_id' || true)"
if [ -z "$ANY_SITES" ]; then say "  ✓ none"; else
  printf '%s\n' "$ANY_SITES" | sed 's/^/    /' | tee -a "$HIST/audit-$STAMP.log"
  say "  → cross-check each against README 'Soundness attention points' (keyed/provably-correct only)."
fi

# ── 6. #[allow(...)] exceptions WITHOUT a justifying comment ──────────────────
say ""; say ">>> [ALLOW] conscious-acceptance audit — every #[allow] needs a // reason"
UNJUSTIFIED=""
for f in "${SRC_FILES[@]}"; do
  while IFS=: read -r ln _; do
    [ -z "$ln" ] && continue
    prev="$(sed -n "$((ln-1))p" "$f")"
    # accepted if the line above is a justification comment (// …) or an attribute continuation
    echo "$prev" | grep -qE '^\s*(//|#\[)' || UNJUSTIFIED="$UNJUSTIFIED$f:$ln\n"
  done < <(grep -nE '^\s*#\[allow\(' "$f" 2>/dev/null | cut -d: -f1 | sed 's/$/:/')
done
if [ -z "$UNJUSTIFIED" ]; then say "  ✓ every #[allow] has an adjacent comment/attr"; else
  say "  ✗ #[allow] without a justifying comment on the line above (document or remove):"
  # `printf '%b'` interprets the accumulated `\n` separators WITHOUT treating a
  # path containing `%`/`\` as a format directive (the old `printf "$UNJUSTIFIED"`
  # was a format-string bug).
  printf '%b' "$UNJUSTIFIED" | sed '/^$/d;s/^/    /' | tee -a "$HIST/audit-$STAMP.log"
fi

# ── 6b. Settled-decision markers (code-level ledger; reconcile new findings against these) ─
say ""; say ">>> [SETTLED] SKY-RUST-AUDIT decision markers in src/ (already signed off — skip on reconcile)"
ACC_N="$(count 'SKY-RUST-AUDIT:ACCEPTED' | wc -l | tr -d ' ')"
DEF_N="$(count 'SKY-RUST-AUDIT:DEFERRED' | wc -l | tr -d ' ')"
say "  ACCEPTED: $ACC_N · DEFERRED (known issues awaiting a fix): $DEF_N"
DEF_SITES="$(count 'SKY-RUST-AUDIT:DEFERRED' || true)"
[ -n "$DEF_SITES" ] && { say "  deferred backlog:"; printf '%s\n' "$DEF_SITES" | sed 's/^/    /' | tee -a "$HIST/audit-$STAMP.log"; }
say "  (grep -rn SKY-RUST-AUDIT for all · …:ACCEPTED accepted compromises · …:DEFERRED known issues)"

# ── 6c. Security grep — timing-oracle + injection sinks (advisory) ───────────
# Versioned here (not re-improvised per run). Patterns the 2026-06-20 security
# audit found load-bearing: non-constant-time secret compares (must route via
# `subtle::ct_eq`) and untrusted values reaching SQL/shell/host sinks.
say ""; say ">>> [SECGREP] timing-oracle + injection-sink scan (advisory)"
if command -v rg >/dev/null 2>&1; then
  say "  -- secret/token/mac compared with ==/!= (use subtle::ct_eq) --"
  rg -n --no-heading -g '*.rs' -i \
    '(token|secret|password|passwd|signature|\bsig\b|cookie|\bmac\b|hmac|bearer)[^\n]*(==|!=)|(==|!=)[^\n]*(token|secret|password|passwd|signature|\bsig\b|cookie|\bmac\b|hmac|bearer)' \
    "$SRC" 2>/dev/null | rg -v '//|test|ct_eq|constant_time|subtle' | head -20 | sed 's/^/    /' | tee -a "$HIST/audit-$STAMP.log" || say "    (none)"
  say "  -- raw SQL via format!/push_str (prefer bound params) --"
  rg -n --no-heading -g '*.rs' '(format!|push_str|write!)[^\n]*(SELECT|INSERT|UPDATE|DELETE|WHERE)' "$SRC" 2>/dev/null | rg -v '//|test' | head -15 | sed 's/^/    /' | tee -a "$HIST/audit-$STAMP.log" || say "    (none)"
  say "  -- new outbound reqwest::Client::builder (must thread http_client::ssrf_apply) --"
  rg -n --no-heading -g '*.rs' 'reqwest::Client(::builder)?\(' "$SRC" 2>/dev/null | rg -v '//|test|ssrf_apply' | head -15 | sed 's/^/    /' | tee -a "$HIST/audit-$STAMP.log" || say "    (none)"
else
  say "  (rg not on PATH — skipped)"
fi

# ── 6d. CVE / supply-chain (advisory; deterministic, ~free) ──────────────────
# cargo-audit = RustSec CVE/unmaintained/unsound advisories against Cargo.lock;
# cargo-deny = license/bans/duplicate-source policy. Both guarded — skip with a
# note if absent (install: cargo install cargo-audit cargo-deny). Advisory only:
# they never flip the hard gate (CVEs are triaged, not auto-blocking).
say ""; say ">>> [SUPPLY] cargo-audit + cargo-deny (advisory)"
if command -v cargo-audit >/dev/null 2>&1; then
  ( cd "$CRATE" && cargo audit ) >"$HIST/cargo-audit.log" 2>&1 || true
  VULN_N="$(grep -cE '^Crate:' "$HIST/cargo-audit.log" 2>/dev/null || echo 0)"
  say "  cargo-audit: $(grep -E 'vulnerabilit|warning:.*allowed' "$HIST/cargo-audit.log" | tail -2 | tr '\n' ' ')"
  grep -E '^(Crate|Title|ID):' "$HIST/cargo-audit.log" 2>/dev/null | head -24 | sed 's/^/    /' | tee -a "$HIST/audit-$STAMP.log"
else
  say "  cargo-audit absent — skipped (cargo install cargo-audit)"
fi
if command -v cargo-deny >/dev/null 2>&1; then
  ( cd "$CRATE" && cargo deny check advisories bans sources ) >"$HIST/cargo-deny.log" 2>&1 || true
  say "  cargo-deny: $(grep -cE '^error' "$HIST/cargo-deny.log" 2>/dev/null || echo 0) errors · $(grep -cE '^warning' "$HIST/cargo-deny.log" 2>/dev/null || echo 0) warnings (see $HIST/cargo-deny.log)"
else
  say "  cargo-deny absent — skipped (cargo install cargo-deny)"
fi

# ── 7. Tests (behaviour gate) ────────────────────────────────────────────────
say ""; say ">>> [TEST] cargo test --all-targets $FEATURES"
TEST=0
( cd "$CRATE" && cargo test $FEATURES ) >"$HIST/test.log" 2>&1 || TEST=1
grep -E '^test result|error\[' "$HIST/test.log" | head -20 | sed 's/^/    /' | tee -a "$HIST/audit-$STAMP.log"
[ "$TEST" = 0 ] && say "  ✓ tests green" || say "  ✗ tests FAILED — see $HIST/test.log"

# ── Verdict ──────────────────────────────────────────────────────────────────
say ""; say "=== QUALITY AUDIT verdict ==="
say "  hard gate (clippy -D + tests): $([ "$GATE" = 0 ] && [ "$TEST" = 0 ] && echo PASS || echo FAIL)"
say "  advisory: $STRICT_N strict-lint warnings · review VECTORS / NO-ANY / ALLOW sections above"
say "  logs: $HIST/ (clippy-gate · clippy-strict · test)"
[ "$GATE" = 0 ] && [ "$TEST" = 0 ] && exit 0 || exit 1
