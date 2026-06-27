#!/usr/bin/env python3
"""Claude Code PreToolUse guard — block risk-lint patterns BEFORE they're written.

Wired as a `PreToolUse` hook on `Write|Edit|MultiEdit` (see `.claude/settings.json`).
A FAST textual pre-check on content about to be written into `runtime-rust/src/**.rs`
(non-test). It exists because security-fix code itself once shipped an
`indexing_slicing` panic vector — every agent must bear the clippy risk rules while
writing, enforced at the tool level, not just as a principle.

NOT a clippy replacement (it can't compile). The COMPLETE check is the crate-level
deny (`Cargo.toml [lints.clippy]` + `src/lib.rs` cfg_attr) plus the CI
`security-audit` gate (`cargo clippy --all-targets --all-features -D warnings`).
This hook is the immediate first line so a bad pattern never reaches disk.

Hardened after an adversarial review (see PROGRESS): comments + string literals are
stripped before scanning (no false-positive on `r#"…unwrap()…"#"` / doc examples,
and the indexing scan sees across line breaks); the indexing scan is O(n) (no
ReDoS → no silent fail-open on long template lines); UFCS / `_unchecked` / `_err`
panic forms are covered; the only test exemption is a literal `#[cfg(test)]` /
`#[test]` attribute in the chunk (a bare `assert!` no longer disarms the guard).

Decision: print a PreToolUse JSON `deny` to BLOCK; exit 0 (no output) to ALLOW.
Fail open ONLY on unparseable input (never wedge the agent) — but the logic is
bounded so it cannot hang into a timeout-driven open.
"""
import json
import os
import re
import sys

# Bound the work so a multi-MB / long-lined Write can never hang into a hook
# timeout (which would fail open — a silent bypass). Past the cap we still run the
# cheap fixed-substring panic checks but skip the char-scan.
MAX_SCAN = 400_000
LOOKBACK = 256  # cap the indexing look-behind so it stays O(n)

KEYWORDS = {
    "let", "mut", "ref", "move", "return", "in", "while", "if", "match", "for",
    "where", "as", "dyn", "impl", "else", "fn", "type", "struct", "enum", "loop",
}

# Panic-vector method/macro forms. Method + UFCS (`.`/`::`) where relevant.
PANIC_PATTERNS = [
    (re.compile(r"\.unwrap\s*\(\s*\)|::unwrap\s*\("), "unwrap() → return Result/Task, or .unwrap_or_else(|e| e.into_inner()) on a lock"),
    (re.compile(r"(?:\.|::)expect\s*\("), "expect(...) → return Result/Task with a real error"),
    (re.compile(r"(?:\.|::)unwrap_err\s*\("), "unwrap_err() panics on Ok → match/return"),
    (re.compile(r"(?:\.|::)expect_err\s*\("), "expect_err(...) panics on Ok → match/return"),
    (re.compile(r"unwrap_unchecked\s*\("), "unwrap_unchecked() is UB on None/Err → forbidden"),
    (re.compile(r"get_unchecked(?:_mut)?\s*\("), "get_unchecked() is UB on OOB → use .get()"),
    (re.compile(r"(?:^|[^\w!])panic\s*!\s*\("), "panic! → return an Err / total fallback"),
    (re.compile(r"(?:^|[^\w])unreachable\s*!\s*\("), "unreachable! → handle the case totally"),
    (re.compile(r"(?:^|[^\w])todo\s*!\s*\("), "todo! → finish it (no panic stub in runtime code)"),
    (re.compile(r"(?:^|[^\w])unimplemented\s*!\s*\("), "unimplemented! → implement or return Err"),
]


def strip_comments_and_strings(code: str) -> str:
    """Replace the bytes of //-line comments, /*…*/ block comments, string
    literals (normal, raw `r#"…"#`), and char/byte-char literals (`'x'`, `b'x'`,
    `'\\''`, `'"'`) with spaces, preserving length + newlines. So a `.unwrap()`
    inside a doc example or an embedded HTML/SQL template never triggers, a `'"'`
    char literal can't open a phantom string that blanks following real code, and
    the indexing scan only sees real code. Lifetimes (`'a`, `'static`, `'_`) are
    left intact — they carry no quotes that could confuse the scan."""
    out = list(code)
    n = len(code)
    i = 0
    while i < n:
        c = code[i]
        nxt = code[i + 1] if i + 1 < n else ""
        if c == "/" and nxt == "/":
            while i < n and code[i] != "\n":
                out[i] = " "
                i += 1
            continue
        if c == "/" and nxt == "*":
            out[i] = out[i + 1] = " "
            i += 2
            while i < n and not (code[i] == "*" and i + 1 < n and code[i + 1] == "/"):
                if code[i] != "\n":
                    out[i] = " "
                i += 1
            if i < n:
                out[i] = " "
                if i + 1 < n:
                    out[i + 1] = " "
                i += 2
            continue
        if c == "r" and (nxt == '"' or nxt == "#"):
            # raw string: r followed by k '#' then '"', terminated by '"' + k '#'
            j = i + 1
            hashes = 0
            while j < n and code[j] == "#":
                hashes += 1
                j += 1
            if j < n and code[j] == '"':
                close = '"' + ("#" * hashes)
                k = j + 1
                end = code.find(close, k)
                end = n if end == -1 else end + len(close)
                for p in range(i, min(end, n)):
                    if code[p] != "\n":
                        out[p] = " "
                i = end
                continue
        if c == "'":
            # Char/byte-char literal vs lifetime. A char literal is
            # ' <char|escape> '; a lifetime ('a, 'static, '_) has no closing quote
            # after its first char. Blanking the literal stops a `'"'` inner quote
            # from opening phantom string mode (which would blank real code after).
            if nxt == "\\":
                # escaped char literal: '\n' '\'' '\\' '\u{..}'
                out[i] = " "
                if i + 1 < n:
                    out[i + 1] = " "  # backslash
                i += 2
                if i < n:
                    if code[i] != "\n":
                        out[i] = " "  # the escaped char (n, t, ', \\, u, …)
                    i += 1
                while i < n and code[i] != "'":
                    if code[i] != "\n":
                        out[i] = " "
                    i += 1
                if i < n:
                    out[i] = " "  # closing '
                    i += 1
                continue
            if i + 2 < n and code[i + 2] == "'":
                # non-escaped single char: ' X '
                out[i] = out[i + 1] = out[i + 2] = " "
                i += 3
                continue
            # otherwise a lifetime — leave intact
            i += 1
            continue
        if c == '"':
            out[i] = " "
            i += 1
            while i < n and code[i] != '"':
                if code[i] == "\\" and i + 1 < n:
                    out[i] = " "
                    out[i + 1] = " "
                    i += 2
                    continue
                if code[i] != "\n":
                    out[i] = " "
                i += 1
            if i < n:
                out[i] = " "
                i += 1
            continue
        i += 1
    return "".join(out)


def has_subscript_indexing(code: str) -> bool:
    """O(n) scan for an indexing expression `<ident|)|]> [ … ]`. Skips slice
    patterns (`[` after a keyword / `=>` / `{` / `(` / `,` / `|`) and macros
    (`name![`), array literals/types (`[` not preceded by an indexable token).
    Look-behind is capped so it stays linear even on adversarial input."""
    n = len(code)
    for i, ch in enumerate(code):
        if ch != "[":
            continue
        # walk back over whitespace (incl. newlines — catches rustfmt line splits)
        j = i - 1
        steps = 0
        while j >= 0 and code[j] in " \t\r\n" and steps < LOOKBACK:
            j -= 1
            steps += 1
        if j < 0:
            continue
        prev = code[j]
        if prev == "!":
            continue  # macro invocation `name![ … ]`
        if prev == ")" or prev == "]":
            return True  # `f()[i]` / `a[i][j]` — chained subscript
        if prev.isalnum() or prev == "_":
            # the indexable token is an identifier — reject only if it's a keyword
            k = j
            steps = 0
            while k >= 0 and (code[k].isalnum() or code[k] == "_") and steps < LOOKBACK:
                k -= 1
                steps += 1
            word = code[k + 1 : j + 1]
            if word not in KEYWORDS:
                return True
    return False


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)  # unparseable → fail open (never wedge the agent)

    ti = data.get("tool_input", {}) or {}
    fp = ti.get("file_path", "") or ""
    if not fp.endswith(".rs"):
        sys.exit(0)
    real = os.path.realpath(fp)
    norm = real.replace(os.sep, "/")
    # Scope: the runtime Rust SOURCE crate only. Exempt integration + in-crate
    # test files by path (their panics/indexing are legitimate).
    if "/runtime-rust/src/" not in norm:
        sys.exit(0)
    if "/tests/" in norm or norm.endswith("/tests.rs") or norm.endswith("_test.rs"):
        sys.exit(0)

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

    # Strip comments + string/char literals ONCE up front so every subsequent
    # check sees real code only. The test exemption MUST run on the stripped text:
    # a `#[test]` / `#[cfg(test)]` mentioned inside a comment or a string literal
    # must NOT disarm the guard (it would be a one-comment bypass).
    stripped = strip_comments_and_strings(content)

    # Test exemption: ONLY a literal test attribute in real code (a bare `assert!`
    # no longer disarms the guard — that was a one-token bypass). An edit that adds
    # raw runtime code never carries these, so it stays guarded.
    if re.search(r"#\[\s*test\s*\]|#\[\s*cfg\(\s*test\s*\)\s*\]", stripped):
        sys.exit(0)

    violations = []
    # The cheap fixed-pattern panic checks run over the FULL stripped content
    # (linear, no ReDoS); only the O(n) indexing char-scan is capped at MAX_SCAN so
    # a multi-MB / long-lined Write stays bounded (matches the module docstring).
    for pat, msg in PANIC_PATTERNS:
        if pat.search(stripped):
            violations.append(msg)
    scan = stripped if len(stripped) <= MAX_SCAN else stripped[:MAX_SCAN]
    if has_subscript_indexing(scan):
        violations.append("`x[i]` / `x[a..b]` indexing may panic → use .get()/.get_mut() or a slice pattern `[x]`")

    if not violations:
        sys.exit(0)

    seen = list(dict.fromkeys(violations))
    reason = (
        "BLOCKED by rust-risk-precheck — clippy risk-lint pattern(s) denied in "
        "runtime-rust/src non-test code (no-runtime-panic thesis). Refactor BEFORE "
        "writing:\n- " + "\n- ".join(seen) + "\n"
        "Genuine test code must carry #[cfg(test)] / #[test]; a sanctioned "
        "INFALLIBLE site needs a justified #[allow] (runtime-rust/CLAUDE.md "
        "## Settled rules). The crate clippy deny + CI gate are the complete check."
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
