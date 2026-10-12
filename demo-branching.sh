#!/usr/bin/env bash
# End-to-end Nessie git-features demo: branch, divergence, merge, tag, history.
# Prereqs: `docker compose up -d` already run; schema iceberg.demo.t with row (1,'hi') exists.

set -euo pipefail

NESSIE=http://localhost:19120/api/v2
TRINO="docker exec -i trino trino --execute"

section() { printf "\n\033[1;36m=== %s ===\033[0m\n" "$*"; }
api() { curl -sS "$@"; echo; }

section "1. Current state of main"
$TRINO "SELECT * FROM iceberg.demo.t;"

section "2. Get main's current commit hash"
MAIN_HASH=$(curl -sS "$NESSIE/trees/main" | python3 -c "import sys,json;print(json.load(sys.stdin)['reference']['hash'])")
echo "main @ $MAIN_HASH"

section "3. Create a 'dev' branch from main"
api -X POST "$NESSIE/trees?name=dev&type=BRANCH" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"BRANCH\",\"name\":\"main\",\"hash\":\"$MAIN_HASH\"}"

section "4. All refs"
api "$NESSIE/trees" | python3 -m json.tool

section "5. Trino: INSERT on dev (via iceberg_dev catalog)"
$TRINO "INSERT INTO iceberg_dev.demo.t VALUES (2, 'from-dev-branch'), (3, 'another');"

section "6. dev now has 3 rows; main is unchanged"
echo "-- dev --"
$TRINO "SELECT * FROM iceberg_dev.demo.t ORDER BY id;"
echo "-- main --"
$TRINO "SELECT * FROM iceberg.demo.t ORDER BY id;"

section "7. Merge dev -> main"
DEV_HASH=$(curl -sS "$NESSIE/trees/dev" | python3 -c "import sys,json;print(json.load(sys.stdin)['reference']['hash'])")
MAIN_HASH=$(curl -sS "$NESSIE/trees/main" | python3 -c "import sys,json;print(json.load(sys.stdin)['reference']['hash'])")
api -X POST "$NESSIE/trees/main@$MAIN_HASH/history/merge" \
  -H "Content-Type: application/json" \
  -d "{\"fromRefName\":\"dev\",\"fromHash\":\"$DEV_HASH\",\"defaultKeyMergeMode\":\"NORMAL\"}"

section "8. main after merge"
$TRINO "SELECT * FROM iceberg.demo.t ORDER BY id;"

section "9. Tag the current main as v1"
MAIN_HASH=$(curl -sS "$NESSIE/trees/main" | python3 -c "import sys,json;print(json.load(sys.stdin)['reference']['hash'])")
api -X POST "$NESSIE/trees?name=v1&type=TAG" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"BRANCH\",\"name\":\"main\",\"hash\":\"$MAIN_HASH\"}"

section "10. Commit history on main"
api "$NESSIE/trees/main/history" | python3 -m json.tool | head -40

section "11. Iceberg time travel: snapshot history of demo.t"
$TRINO "SELECT snapshot_id, committed_at, operation FROM iceberg.demo.\"t\$snapshots\" ORDER BY committed_at;"

section "12. Query the table AS OF the second-to-last snapshot"
PREV_SNAP=$($TRINO "SELECT snapshot_id FROM iceberg.demo.\"t\$snapshots\" ORDER BY committed_at DESC OFFSET 1 LIMIT 1;" | tr -d '"')
echo "previous snapshot: $PREV_SNAP"
$TRINO "SELECT * FROM iceberg.demo.t FOR VERSION AS OF $PREV_SNAP ORDER BY id;"

section "13. Clean up dev branch"
DEV_HASH=$(curl -sS "$NESSIE/trees/dev" | python3 -c "import sys,json;print(json.load(sys.stdin)['reference']['hash'])")
api -X DELETE "$NESSIE/trees/dev@$DEV_HASH"

section "Done."
echo "Try: curl -s $NESSIE/trees | python3 -m json.tool"
