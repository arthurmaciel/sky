# Syncing with upstream anzellai/sky

`origin` = `arthurmaciel/sky` (our fork; publish/backup for `feat/runtime-rust`).
`upstream` = `anzellai/sky` (fetch-only). `main` is a **pristine mirror** of
`upstream/main` — never commit Rust work to it.

## Per-release sync

```bash
git fetch upstream --tags
git checkout main && git merge --ff-only upstream/main   # pristine fast-forward
git checkout feat/runtime-rust && git merge main
```

After the thin-seam refactor, expect at most these trivial conflicts:

- `sky-compiler.cabal` — both sides add `build-depends`. Resolve by **keeping
  both** dependency lists (union).
- `src/Sky/Build/Compile.hs` — a small target-dispatch hunk where our
  `case Toml._target of { TargetRust -> Rust.Project.generateRustProject … }`
  meets upstream's edits to the Go-codegen block. Re-apply our dispatch arm
  around upstream's updated Go block. (This one cannot be fully eliminated;
  it is shrunk to the dispatch wrapper, not the full body.)

Then rebuild + verify:

```bash
cabal install --overwrite-policy=always --installdir=./sky-out --install-method=copy exe:sky
# run the Rust example sweep (Verification protocol block b of
# docs/superpowers/plans/2026-05-26-upstream-sync-thin-seam.md)
```
