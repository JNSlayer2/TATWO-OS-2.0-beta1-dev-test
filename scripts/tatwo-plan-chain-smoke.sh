#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH_PATH="${TATWO_PLAN_CHAIN_SCRATCH_PATH:-/tmp/tatwo-g35-full}"
RECEIPT_DIR="${TATWO_PLAN_CHAIN_RECEIPT_DIR:-$ROOT_DIR/receipts/g35-s2-plan-chain}"
RUN_ID="${TATWO_PLAN_CHAIN_RUN_ID:-g35-s2-plan-$(date -u '+%Y%m%dT%H%M%SZ')}"
RAW_LOG="$RECEIPT_DIR/$RUN_ID.raw.log"
RECEIPT="$RECEIPT_DIR/$RUN_ID.json"
FILTER="TatwoUltraworkMacTests.ChatPlanArtifactBehaviorTests/testConfirmationRoutesSingleModelToGoalPipelineVisibly"

mkdir -p "$RECEIPT_DIR"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/tatwo-plan-chain-clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/tatwo-plan-chain-swiftpm-cache}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/tatwo-plan-chain-xdg-cache}"

set +e
swift test \
  --package-path "$ROOT_DIR" \
  --disable-sandbox \
  -Xswiftc -disable-sandbox \
  --scratch-path "$SCRATCH_PATH" \
  --disable-automatic-resolution \
  --skip-build \
  --filter "$FILTER" >"$RAW_LOG" 2>&1
status=$?
set -e

passed_line="$(
  grep -E "Test Case .*testConfirmationRoutesSingleModelToGoalPipelineVisibly.* passed" \
    "$RAW_LOG" | tail -1 || true
)"
if [[ "$status" -ne 0 || -z "$passed_line" ]]; then
  tail -80 "$RAW_LOG" >&2
  printf 'PLAN_CHAIN_SMOKE FAIL run_id=%s exit=%s\n' "$RUN_ID" "$status" >&2
  if [[ "$status" -ne 0 ]]; then
    exit "$status"
  fi
  exit 1
fi

git_head="$(git -C "$ROOT_DIR" rev-parse HEAD)"
raw_log_sha256="$(shasum -a 256 "$RAW_LOG" | awk '{print $1}')"
raw_log_relative="${RAW_LOG#"$ROOT_DIR"/}"
python3 - "$RECEIPT" "$RUN_ID" "$git_head" "$FILTER" "$raw_log_relative" \
  "$raw_log_sha256" "$passed_line" <<'PY'
import json
import pathlib
import sys

receipt, run_id, git_head, test_filter, raw_log, raw_hash, passed_line = sys.argv[1:]
payload = {
    "schema": "TatwoPlanChainSmokeReceiptV1",
    "run_id": run_id,
    "git_head": git_head,
    "surface": "staging-test-runtime",
    "chain": ["/plan", "confirm", "/goal", "visible-outcome"],
    "test_filter": test_filter,
    "raw_log": raw_log,
    "raw_log_sha256": raw_hash,
    "result": "PASS",
    "exit_code": 0,
    "result_line": passed_line.strip(),
}
pathlib.Path(receipt).write_text(
    json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

printf 'PLAN_CHAIN_SMOKE PASS run_id=%s exit=0 receipt=%s\n' \
  "$RUN_ID" "$RECEIPT"
printf '%s\n' "$passed_line"
