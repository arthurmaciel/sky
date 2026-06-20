#!/usr/bin/env python3
"""Claude Code PreToolUse guard — block risk-lint patterns BEFORE they're written.

Wired as a `PreToolUse` hook on `Write|Edit|MultiEdit` (see `.claude/settings.json`).
It is a FAST TEXTUAL pre-check on the content about to be written into
`runtime-rust/src/**.rs` (non-test). It exists because security-fix code itself
once shipped an `indexing_slicing` panic vector — every agent must now bear the
clippy risk rules while writing, enforced at the tool level, not just as a
principle.

This is NOT a replacement for clippy (it can't compile): the COMPLETE check is
the crate-level deny (`Cargo.toml [lints.clippy]` + `src/lib.rs` cfg_attr) plus
the CI `security-audit` gate (`cargo clippy --all-targets --all-features -D
warnings`). This hook is the immediate first line so a bad pattern never reaches
disk.

Decision protocol (Claude Code): print a PreToolUse JSON `deny` with a reason to
BLOCK; exit 0 (no output) to ALLOW. Never block on its own error — fail open.
"""
import json
import re
import sys


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)  # fail open — never wedge the agent on a parse hiccup

    ti = data.get("tool_input", {}) or {}
    fp = ti.get("file_path", "") or ""

    # Scope: only the runtime Rust SOURCE crate (the Sky-reachable surface).
    # Integration tests (`runtime-rust/tests/`) and everything else are exempt.
    if "runtime-rust/src/" not in fp or not fp.endswith(".rs"):
        sys.exit(0)

    # Gather the text being written: Write→content, Edit→new_string,
    # MultiEdit→edits[].new_string.
    chunks = []
    if ti.get("content"):
        chunks.append(ti["content"])
    if ti.get("new_string"):
        chunks.append(ti["new_string"])
    for e in ti.get("edits", []) or []:
        if e.get("new_string"):
            chunks.append(e["new_string"])
    content = "\n".join(chunks)
    if not content.strip():
        sys.exit(0)

    # Test-code heuristic: the crate's deny is `not(test)`, so test code may panic
    # / index freely. If the written chunk is clearly test code, exempt it.
    if re.search(r"#\[test\]|#\[cfg\(test\)\]|\bmod tests\b|assert(_eq|_ne)?!\s*\(", content):
        sys.exit(0)

    violations = []

    # (1) Unambiguous panic tokens — zero false positives.
    for pat, msg in [
        (r"\.unwrap\(\)", ".unwrap() → return Result/Task, or .unwrap_or_else(|e| e.into_inner()) on a lock"),
        (r"\.expect\s*\(", ".expect(...) → return Result/Task with a real error"),
        (r"(?:^|[^\w!])panic!\s*\(", "panic! → return an Err / total fallback"),
        (r"(?:^|[^\w])unreachable!\s*\(", "unreachable! → handle the case totally"),
        (r"(?:^|[^\w])todo!\s*\(", "todo! → finish it (no panic stub in runtime code)"),
        (r"(?:^|[^\w])unimplemented!\s*\(", "unimplemented! → implement or return Err"),
    ]:
        if re.search(pat, content, re.M):
            violations.append(msg)

    # (2) Indexing / slicing — clippy::indexing_slicing bans ALL `x[i]`/`x[a..b]`.
    # A SUBSCRIPT is `<ident|)|]> [ … ]`. We flag those, but skip:
    #   - macros `vec![…]` (a `!` sits between the name and `[`, so no ident-`[`),
    #   - array literals/types `[T; N]` / `[1, 2]` (no ident immediately before `[`),
    #   - slice PATTERNS `let [x] = …` / `=> [x]` (the token before `[` is a Rust
    #     keyword, or `[` follows `=>`/`{`/`(`/`,` — not an indexable expression).
    # This catches `let c = b[0]` (subscript on the RHS) while passing `let [x] = b`.
    KW = {"let", "mut", "ref", "move", "return", "in", "while", "if", "match",
          "for", "where", "as", "dyn", "impl", "else", "fn", "type", "struct", "enum"}
    for ln in content.splitlines():
        s = ln.lstrip()
        if s.startswith("//") or s.startswith("*") or s.startswith("#["):
            continue
        hit = False
        for m in re.finditer(r"([A-Za-z_]\w*|\)|\])\s*\[[^\]]", ln):
            if m.group(1) not in KW:
                hit = True
                break
        if hit:
            violations.append("`x[i]` / `x[a..b]` indexing may panic → use .get()/.get_mut() or a slice pattern `[x]`")
            break

    if not violations:
        sys.exit(0)

    seen = list(dict.fromkeys(violations))
    reason = (
        "BLOCKED by rust-risk-precheck — this content has clippy risk-lint "
        "pattern(s) denied in runtime-rust/src non-test code (the no-runtime-panic "
        "thesis). Refactor BEFORE writing:\n- " + "\n- ".join(seen) + "\n"
        "If this is genuinely test code it must sit behind #[cfg(test)] / carry an "
        "assert!; a sanctioned INFALLIBLE site needs a justified #[allow] (see "
        "runtime-rust/CLAUDE.md ## Settled rules)."
    )
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


main()
