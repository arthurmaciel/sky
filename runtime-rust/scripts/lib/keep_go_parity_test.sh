#!/usr/bin/env bash
# Unit test for keep-go-parity.sh run-state machinery. Plain bash.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
KGP="$HERE/../keep-go-parity.sh"
fail=0
assert_eq() { if [ "$1" = "$2" ]; then echo "ok   : $3"; else echo "FAIL : $3 want[$2] got[$1]"; fail=1; fi; }

# Drive the script's state subcommands against a throwaway state file.
export SKY_KGP_STATE="$(mktemp -d)/state"        # script honours this override
bash "$KGP" state-init   >/dev/null
assert_eq "$(bash "$KGP" state-get last_completed_phase)" "0" "state-init sets last_completed_phase=0"
BASE="$(bash "$KGP" state-get BASE)"
assert_eq "$([ -n "$BASE" ] && echo nonempty)" "nonempty" "state-init records BASE"
bash "$KGP" state-done 3 >/dev/null
assert_eq "$(bash "$KGP" state-get last_completed_phase)" "3" "state-done 3 advances frontier"
assert_eq "$(bash "$KGP" state-get phase_3)" "ok" "state-done 3 marks phase_3=ok"
assert_eq "$(bash "$KGP" state-get BASE)" "$BASE" "state-done preserves BASE"
bash "$KGP" --restart    >/dev/null
assert_eq "$([ -f "$SKY_KGP_STATE" ] && echo present || echo gone)" "gone" "--restart clears the state file"
rm -rf "$(dirname "$SKY_KGP_STATE")"

# scoped-sweep --dry-run prints a RUST_EXAMPLES list derived from BASE, no sweep run.
export SKY_KGP_STATE="$(mktemp -d)/state2"
bash "$KGP" state-init >/dev/null
OUT="$(bash "$KGP" scoped-sweep --dry-run 2>&1)"
assert_eq "$(printf '%s\n' "$OUT" | grep -c 'RUST_EXAMPLES=')" "1" "scoped-sweep --dry-run emits a RUST_EXAMPLES= line"
assert_eq "$(printf '%s\n' "$OUT" | grep -c 'examples-sweep.sh')" "1" "scoped-sweep --dry-run names the sweep it WOULD run"
rm -rf "$(dirname "$SKY_KGP_STATE")"

exit "$fail"
