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

exit "$fail"
