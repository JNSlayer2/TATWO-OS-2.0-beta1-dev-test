#!/usr/bin/env bash
# Live skillet-lane must not activate or overwrite skills unless explicitly opted in.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYNC="$ROOT/scripts/tatwo-device-sync.sh"

grep -q 'SKILLET_APPLY="${TATWO_SKILLET_APPLY:-0}"' "$SYNC"
grep -q 'SKILLET_LANE_PUBLISH="${TATWO_SKILLET_LANE_PUBLISH:-0}"' "$SYNC"
grep -q 'quarantine_skillet_lane_request' "$SYNC"
grep -q 'file_skillet_lane_proposal' "$SYNC"
grep -q 'TATWO_SKILLET_APPLY=0（不覆蓋本機 skill、不灌進 OS）' "$SYNC"
grep -q 'TATWO_SKILLET_LANE_PUBLISH=0（不整包外送本機 skill）' "$SYNC"

# Test mode still defaults to the old activate path so existing fixtures keep working.
grep -q 'TATWO_TEST_MODE:-0}" = "1"' "$SYNC"

echo "skillet-lane-no-overwrite=passed"
