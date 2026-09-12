#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${TATWO_SWIFTPM_SCRATCH_PATH:-$ROOT/.build/out}"
TMP_ROOT="${TATWO_TEST_TMP_ROOT:-${TMPDIR:-/tmp}/tatwo-skillet}"

run() {
  local label="$1"
  shift
  printf '%s\n' "==> $label"
  "$@"
}

mkdir -p "$TMP_ROOT"

run "build governed Skillet CLI" \
  swift build \
    --package-path "$ROOT" \
    --scratch-path "$SCRATCH" \
    --jobs 1 \
    --product tatwo-ultrawork

BIN_PATH="$(
  swift build \
    --package-path "$ROOT" \
    --scratch-path "$SCRATCH" \
    --show-bin-path
)"
CLI="$BIN_PATH/tatwo-ultrawork"
[ -x "$CLI" ] || {
  printf '%s\n' "Skillet CLI is unavailable after build: $CLI" >&2
  exit 1
}

export TATWO_SKILLET_CLI="$CLI"
export TATWO_SWIFTPM_SCRATCH_PATH="$SCRATCH"
export TATWO_TEST_TMP_ROOT="$TMP_ROOT"

run "P2 transport unit suite" \
  swift test \
    --package-path "$ROOT" \
    --scratch-path "$SCRATCH" \
    --jobs 1 \
    --filter TatwoSkilletBundleTransportTests
run "P2 repository merge and runtime-closure contract" \
  bash "$ROOT/tests/tatwo-skillet-cli-merge.test.sh"
run "P2 conflicted merge resolution and negative gates" \
  bash "$ROOT/tests/tatwo-skillet-cli-merge-resolve.test.sh"
run "P0 consumer projection and legacy-receipt refusal" \
  bash "$ROOT/tests/tatwo-skills-consumer-projection.test.sh"
run "P0/P1 transactional Hot Sync, progress, rollback and stale CLI refusal" \
  bash "$ROOT/tests/tatwo-device-sync-flexprimary.test.sh"
run "P0 signed helper ACK and consumer attestation" \
  bash "$ROOT/tests/tatwo-sync-helper-ack.test.sh"
run "P0 device trust channel" \
  bash "$ROOT/tests/tatwo-device-trust-channel.test.sh"
run "P0 device enrollment channel" \
  bash "$ROOT/tests/tatwo-device-enroll-channel.test.sh"
run "P0 durable sync catalog" \
  node "$ROOT/tests/tatwo-sync-catalog.test.mjs"
run "P2 canonical Skillet refresh" \
  node "$ROOT/tests/tatwo-skillet-refresh.test.mjs"

printf '%s\n' "tatwo_p0p2_acceptance=passed"
