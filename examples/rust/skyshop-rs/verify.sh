#!/usr/bin/env bash
# Runnable end-to-end check for examples/rust/skyshop-rs against the Firestore
# emulator + stripe-mock. Exits 0 on PASS, 1 on FAIL, 2 on missing prereqs.
#
# Prereqs (see README "Prerequisites & references"):
#   - gcloud + `gcloud components install cloud-firestore-emulator` (a JRE)
#   - stripe-mock at ~/go/bin/stripe-mock  (go install github.com/stripe/stripe-mock@latest)
#   - the sky compiler built on feat/runtime-rust
#   - the wrapper repo at ~/.cache/sky/skyshop-rs-wrappers
# Leave ENV / SKY_ENV unset — the shims refuse the emulator path in production
# (a deliberate security gate); this script unsets them.
set +e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"          # examples/rust/skyshop-rs
REPO="$(cd "$HERE/../../.." && pwd)"                          # repo root
WR="${SKYSHOP_WRAPPERS:-$HOME/.cache/sky/skyshop-rs-wrappers}"
export PATH="$HOME/.cargo/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.ghcup/bin"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/sky-rust-target}"
export RUSTC_WRAPPER="${RUSTC_WRAPPER:-sccache}"
SKY_BIN="${SKY_BIN:-$REPO/sky-out/sky}"
STRIPE_MOCK="${STRIPE_MOCK:-$HOME/go/bin/stripe-mock}"
PORT="${SKY_LIVE_PORT:-8000}"
LOG="$(mktemp -d)"
unset ENV SKY_ENV

fail() { echo "verify: $*" >&2; }
cleanup() {
  pkill -9 -f 'sky-out/Rust/target/debug/sky-app' 2>/dev/null
  pkill -9 -f 'stripe-mock' 2>/dev/null
  pkill -9 -f 'cloud-firestore-emulator' 2>/dev/null
  pkill -9 -f 'emulators firestore' 2>/dev/null
}
trap cleanup EXIT

# --- preflight ---
command -v gcloud >/dev/null || { fail "gcloud not found (install Google Cloud SDK + cloud-firestore-emulator)"; exit 2; }
[ -x "$STRIPE_MOCK" ]        || { fail "stripe-mock not at $STRIPE_MOCK (go install github.com/stripe/stripe-mock@latest)"; exit 2; }
[ -x "$SKY_BIN" ]           || { fail "sky compiler not at $SKY_BIN"; exit 2; }
[ -d "$WR/sky-firestore-shim" ] || { fail "wrapper repo not at $WR"; exit 2; }

echo "== 0. kill stale instances =="; cleanup; sleep 2

echo "== 1. firestore emulator =="
gcloud emulators firestore start --host-port=127.0.0.1:8412 > "$LOG/emu.log" 2>&1 &
for i in $(seq 1 90); do grep -qiE "running|Dev App Server" "$LOG/emu.log" && break; sleep 1; done
export FIRESTORE_EMULATOR_HOST=127.0.0.1:8412 FIRESTORE_PROJECT_ID=sky-skyshop-dev
grep -qiE "running|Dev App Server" "$LOG/emu.log" || { fail "emulator did not start"; tail "$LOG/emu.log"; exit 1; }

echo "== 2. seed (ENV unset) =="
( cd "$WR/sky-firestore-shim" && env -u ENV -u SKY_ENV \
    FIRESTORE_EMULATOR_HOST=127.0.0.1:8412 FIRESTORE_PROJECT_ID=sky-skyshop-dev \
    cargo run --quiet --bin seed ) > "$LOG/seed.log" 2>&1
tail -1 "$LOG/seed.log"
grep -q "5/5 products written" "$LOG/seed.log" || { fail "seed failed"; cat "$LOG/seed.log"; exit 1; }

echo "== 3. stripe-mock =="
"$STRIPE_MOCK" -http-port 12111 > "$LOG/stripe.log" 2>&1 &
export STRIPE_API_BASE=http://127.0.0.1:12111 STRIPE_API_KEY=sk_test_123
for i in $(seq 1 15); do curl -s -o /dev/null --max-time 2 http://127.0.0.1:12111/v1/customers && break; sleep 1; done

echo "== 4. build =="
( cd "$HERE" && "$SKY_BIN" build src/Main.sky --backend rust ) > "$LOG/build.log" 2>&1
grep -q "Build complete" "$LOG/build.log" || { fail "build failed"; tail "$LOG/build.log"; exit 1; }

echo "== 5. run app (ENV unset) =="
( cd "$HERE" && env -u ENV -u SKY_ENV \
    FIRESTORE_EMULATOR_HOST=127.0.0.1:8412 FIRESTORE_PROJECT_ID=sky-skyshop-dev \
    STRIPE_API_BASE=http://127.0.0.1:12111 STRIPE_API_KEY=sk_test_123 \
    SKY_LIVE_PORT="$PORT" SKY_CONSOLE_EMBED=off \
    ./sky-out/Rust/target/debug/sky-app ) > "$LOG/app.log" 2>&1 &
for i in $(seq 1 30); do grep -qi listening "$LOG/app.log" && break; sleep 1; done

echo "== 6. verify GET / =="
BODY=$(curl -s --max-time 15 "http://127.0.0.1:$PORT/")
HITS=0
for p in "Aurora Desk Lamp" "Meridian Wireless Headphones" "Cedar A5 Notebook" "Tidal Insulated Bottle" "Summit 28L Backpack"; do
  if printf '%s' "$BODY" | grep -qF "$p"; then HITS=$((HITS+1)); else fail "product missing: $p"; fi
done
DBERR=$(grep -c '\[DB ERROR\]' "$LOG/app.log")
echo "products rendered: $HITS/5 | [DB ERROR] lines: $DBERR | body bytes: ${#BODY}"

if [ "$HITS" -eq 5 ] && [ "$DBERR" -eq 0 ]; then
  echo "RESULT: PASS — 5/5 products via the firestore emulator, 0 DB errors"; exit 0
else
  echo "RESULT: FAIL — products=$HITS/5 dberr=$DBERR (see $LOG/app.log)"; exit 1
fi
