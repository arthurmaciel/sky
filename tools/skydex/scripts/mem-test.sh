#!/usr/bin/env bash
# Index the FULL Sky repo under a hard virtual-memory cap. Proves skydex is bounded.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
BIN="$(dirname "$0")/../target/release/skydex"
DB="$(mktemp -u).db"
CAP_KB="${SKYDEX_MEM_CAP_KB:-400000}"   # 400 MB ceiling
echo "indexing $REPO under ulimit -v ${CAP_KB}KB"
( ulimit -v "$CAP_KB"; "$BIN" index --repo "$REPO" --db "$DB" )
echo "OK — indexed under cap"; "$BIN" wakeup --db "$DB"; rm -f "$DB" "$DB"-wal "$DB"-shm
