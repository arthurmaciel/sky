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
