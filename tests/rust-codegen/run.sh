#!/usr/bin/env bash
# Sub-A.13 regression sweep. Each file is a self-contained Main module under
# `target=rust`. We expect ALL three to compile clean once the fix lands.
# Before the fix: 4 cargo errors across the 3 files (1+2+1).
set -u
cd "$(dirname "$0")"
fail=0
for f in empty-list-head.sky maybe-map-nothing.sky result-err.sky generic-adt.sky crypto-aead.sky bytes-jwt.sky compression.sky csv.sky; do
    cp "$f" Main.sky
    rm -rf sky-out .skycache .skydeps
    out=$(../../sky-out/sky build Main.sky 2>&1)
    errs=$(echo "$out" | grep -cE "^error\[E0")
    if [ "$errs" -ne 0 ]; then
        echo "FAIL $f: $errs cargo error(s)"
        echo "$out" | grep -E "^error\[E0" | head -3
        fail=1
    else
        # Build succeeded — also run to confirm "ok: ..." prints.
        if [ -x sky-out/Rust/target/debug/sky-app ]; then
            run_out=$(./sky-out/Rust/target/debug/sky-app)
            case "$run_out" in
                ok:*) echo "PASS $f: $run_out" ;;
                *) echo "FAIL $f: unexpected runtime output: $run_out"; fail=1 ;;
            esac
        else
            echo "FAIL $f: no binary produced"
            fail=1
        fi
    fi
    rm -f Main.sky
    rm -rf sky-out/Rust/target sky-out .skycache .skydeps
done
exit $fail
