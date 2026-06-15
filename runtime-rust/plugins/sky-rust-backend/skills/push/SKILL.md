---
name: push
description: "Push the current branch to the user's fork (origin) — NEVER to the upstream repo (anzellai/sky). Refuses any target named upstream, missing, or matching the upstream URL. Use when the user asks to push the Rust-backend branch / push to origin / publish work on the Sky compiler repo (feat/runtime-rust). Trigger: /sky-rust-backend:push."
---

# push

Push the **current branch** to the user's fork (`origin` →
`arthurmaciel/sky`). The whole point is the **hard upstream guard**: this
NEVER pushes to the upstream repo (`anzellai/sky`). One **deterministic**
script wraps the guards + push — **do NOT re-decide the steps each time**; the
only judgement call is afterward: if a run reveals a better way, edit
`runtime-rust/scripts/push.sh`.

## Workflow (every invocation)

1. **Dry-run first if unsure** — runs all guards + `git push --dry-run` (safe,
   pushes nothing):
   ```bash
   bash runtime-rust/scripts/push.sh --dry-run
   ```

2. **Push** to the fork (origin):
   ```bash
   bash runtime-rust/scripts/push.sh
   ```
   The script self-resolves the repo root, runs the upstream guards, prints the
   summary (remote / url / branch / commits-ahead), and pushes the current
   branch to `origin`.

3. **Relay the verdict** — `pushed <branch> → origin` on success, or the
   `REFUSING: …` line + non-zero exit on any guard failure.

4. **Improve the script if warranted** (new guard case, summary tweak) — fix it
   in `runtime-rust/scripts/push.sh`, never improvise.

## Safety — the upstream guard

The script **REFUSES** (non-zero exit, `REFUSING: …` to stderr) if ANY of:

- the target remote name is `upstream`;
- the target remote does not exist;
- the target remote's URL matches the upstream repo `anzellai/sky`
  (case-insensitive — covers `github.com:anzellai/sky`,
  `github.com/anzellai/sky`, `.git` suffix).

The user's fork `arthurmaciel/sky` is the **only** acceptable target.

## What it does

- Targets remote `origin` by default (optional first arg names another remote —
  still fully guarded).
- Pushes the current branch only (`git branch --show-current`).
- Only on the `main` branch: cancels in-progress CI runs before pushing
  (root `CLAUDE.md` "Workflow rules" hygiene). Skipped on feature branches.
- `--dry-run` (or `DRY_RUN=1`) runs the guards + `git push --dry-run` — safe to
  test, pushes nothing.

## Constraints

- **Never pushes to upstream** (`anzellai/sky`) — guarded three ways.
- **Never force-pushes.**
- Pushes the **current branch only** — no branch argument.
- Non-interactive; exits 0 on success, non-zero on any guard failure or push error.
