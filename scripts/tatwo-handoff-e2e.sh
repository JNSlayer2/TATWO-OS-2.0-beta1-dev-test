#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="${TATWO_HANDOFF_CLI:-$ROOT/.build/debug/tatwo-ultrawork}"

usage() {
  cat <<'EOF'
Usage:
  scripts/tatwo-handoff-e2e.sh --selftest
  scripts/tatwo-handoff-e2e.sh --print-remote-plan

The remote plan is printed only. This script never executes ssh or scp.
EOF
}

require_cli() {
  if [[ ! -x "$CLI" ]]; then
    printf 'ERROR: CLI binary not found: %s\n' "$CLI" >&2
    printf 'Build it first or set TATWO_HANDOFF_CLI=/absolute/path/to/tatwo-ultrawork\n' >&2
    exit 2
  fi
}

run_for() {
  local app_support="$1"
  shift
  TATWO_TEST_MODE=1 \
  TATWO_DEVICE_TRUST_TEST_KEY_ROOT="$app_support/test-keys" \
  TATWO_ULTRAWORK_APP_SUPPORT="$app_support" \
    "$CLI" "$@" --json
}

selftest() {
  require_cli
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/tatwo-handoff-e2e.XXXXXX")"
  ORIGIN="$WORK/origin"
  RECEIVER="$WORK/receiver"
  ORIGIN_STORE="$ORIGIN/device-trust/pin-store"
  RECEIVER_STORE="$RECEIVER/device-trust/pin-store"
  SNAPSHOT="$WORK/source-snapshot"
  mkdir -p "$ORIGIN/test-keys" "$RECEIVER/test-keys" "$SNAPSHOT"
  git -C "$ROOT" archive HEAD | tar -x -C "$SNAPSHOT"

  cleanup() {
    if command -v trash >/dev/null 2>&1; then
      trash "$WORK" >/dev/null 2>&1 || true
    else
      printf 'SELFTEST workspace preserved (trash unavailable): %s\n' "$WORK"
    fi
  }
  trap cleanup EXIT

  printf '== trust bootstrap (isolated test-mode file stores) ==\n'
  run_for "$ORIGIN" device-trust init --device-id origin-selftest --store-root "$ORIGIN_STORE"
  run_for "$ORIGIN" device-trust export-identity --device-id origin-selftest \
    --output "$ORIGIN/device-trust/identity.json"
  run_for "$RECEIVER" device-trust init --device-id receiver-selftest \
    --store-root "$RECEIVER_STORE"
  run_for "$RECEIVER" device-trust export-identity --device-id receiver-selftest \
    --output "$RECEIVER/device-trust/identity.json"

  origin_fingerprint="$(shasum -a 256 "$ORIGIN/device-trust/identity.json" | awk '{print $1}')"
  receiver_fingerprint="$(shasum -a 256 "$RECEIVER/device-trust/identity.json" | awk '{print $1}')"
  run_for "$ORIGIN" device-trust pin-import "$RECEIVER/device-trust/identity.json" \
    --fingerprint "$receiver_fingerprint" --device-id origin-selftest \
    --store-root "$ORIGIN_STORE"
  run_for "$RECEIVER" device-trust pin-import "$ORIGIN/device-trust/identity.json" \
    --fingerprint "$origin_fingerprint" --device-id receiver-selftest \
    --store-root "$RECEIVER_STORE"

  goal_hash="$(printf 'u3-selftest-goal' | shasum -a 256 | awk '{print $1}')"
  plan_hash="$(printf 'u3-selftest-plan' | shasum -a 256 | awk '{print $1}')"
  design_hash="$(git -C "$ROOT" show HEAD:docs/protocol/CROSS_DEVICE_TASK_HANDOFF_DESIGN.md | shasum -a 256 | awk '{print $1}')"
  commit="$(git -C "$ROOT" rev-parse HEAD)"
  tree="$(git -C "$ROOT" rev-parse 'HEAD^{tree}')"
  pack="$WORK/handoff-pack.json"
  assessment="$WORK/handoff-assessment.json"
  capabilities="$WORK/receiver-capabilities.json"

  cat >"$capabilities" <<EOF
{
  "schema": "TatwoHandoffReceiverCapabilitiesV1",
  "deviceID": "receiver-selftest",
  "projectCommit": "$commit",
  "projectTreeHash": "$tree",
  "reachableCommits": [],
  "reachableTreeHashes": [],
  "supportedPackSchemas": ["TatwoCrossDeviceHandoffPackV1"],
  "swiftToolchainFingerprint": null,
  "runnerAvailability": {},
  "permittedLanes": [],
  "canRefetchFreshData": false,
  "localWorktreeDirty": false
}
EOF

  printf '== negative: dirty worktree cannot create pack ==\n'
  DIRTY_SNAPSHOT="$WORK/dirty-source-snapshot"
  cp -R "$SNAPSHOT" "$DIRTY_SNAPSHOT"
  printf '\nselftest dirty marker\n' >>"$DIRTY_SNAPSHOT/README.md"
  set +e
  dirty_output="$(
    cd "$DIRTY_SNAPSHOT"
    export GIT_DIR="$ROOT/.git" GIT_WORK_TREE="$DIRTY_SNAPSHOT" GIT_OPTIONAL_LOCKS=0
    run_for "$ORIGIN" cross-device-handoff pack-create --out "$WORK/dirty-pack.json" \
      --goal-hash "$goal_hash" --plan-hash "$plan_hash" \
      --logical-job u3-dirty-selftest --receiver-device receiver-selftest \
      --files "docs/protocol/CROSS_DEVICE_TASK_HANDOFF_DESIGN.md:$design_hash" 2>&1
  )"
  dirty_status=$?
  set -e
  printf '%s\n' "$dirty_output"
  [[ $dirty_status -ne 0 ]]
  grep -q 'refuses a dirty worktree' <<<"$dirty_output"

  printf '== 1. pack-create ==\n'
  (
    cd "$SNAPSHOT"
    export GIT_DIR="$ROOT/.git" GIT_WORK_TREE="$SNAPSHOT" GIT_OPTIONAL_LOCKS=0
    run_for "$ORIGIN" cross-device-handoff pack-create --out "$pack" \
      --goal-hash "$goal_hash" --plan-hash "$plan_hash" \
      --logical-job u3-selftest --receiver-device receiver-selftest \
      --files "docs/protocol/CROSS_DEVICE_TASK_HANDOFF_DESIGN.md:$design_hash"
  )

  printf '== 2. pack-verify ==\n'
  run_for "$RECEIVER" cross-device-handoff pack-verify --in "$pack" \
    --expect-producer origin-selftest --expect-receiver receiver-selftest

  printf '== 3. assess ==\n'
  run_for "$RECEIVER" cross-device-handoff assess --in "$pack" \
    --capabilities "$capabilities" --out "$assessment"
  grep -q '"decision" : "accept"' "$assessment"

  printf '== 4. assessment-verify ==\n'
  run_for "$ORIGIN" cross-device-handoff assessment-verify --in "$assessment" --pack "$pack"

  printf '== three-state: degraded assessment remains signed ==\n'
  degraded_pack="$WORK/degraded-pack.json"
  degraded_capabilities="$WORK/degraded-capabilities.json"
  degraded_assessment="$WORK/degraded-assessment.json"
  (
    cd "$SNAPSHOT"
    export GIT_DIR="$ROOT/.git" GIT_WORK_TREE="$SNAPSHOT" GIT_OPTIONAL_LOCKS=0
    run_for "$ORIGIN" cross-device-handoff pack-create --out "$degraded_pack" \
      --goal-hash "$goal_hash" --plan-hash "$plan_hash" \
      --logical-job u3-degraded-selftest --receiver-device receiver-selftest \
      --files "docs/protocol/CROSS_DEVICE_TASK_HANDOFF_DESIGN.md:$design_hash" \
      --toolchain-fingerprint swift-origin
  )
  python3 - "$capabilities" "$degraded_capabilities" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
value["swiftToolchainFingerprint"] = "swift-receiver"
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True)
PY
  run_for "$RECEIVER" cross-device-handoff assess --in "$degraded_pack" \
    --capabilities "$degraded_capabilities" --out "$degraded_assessment"
  grep -q '"decision" : "degraded"' "$degraded_assessment"
  run_for "$ORIGIN" cross-device-handoff assessment-verify \
    --in "$degraded_assessment" --pack "$degraded_pack"

  printf '== three-state: reject assessment remains signed ==\n'
  reject_capabilities="$WORK/reject-capabilities.json"
  reject_assessment="$WORK/reject-assessment.json"
  python3 - "$capabilities" "$reject_capabilities" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
value["projectCommit"] = "unreachable-commit"
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True)
PY
  run_for "$RECEIVER" cross-device-handoff assess --in "$pack" \
    --capabilities "$reject_capabilities" --out "$reject_assessment"
  grep -q '"decision" : "reject"' "$reject_assessment"
  run_for "$ORIGIN" cross-device-handoff assessment-verify \
    --in "$reject_assessment" --pack "$pack"

  printf '== compatibility: legacy handoff pack remains available ==\n'
  legacy_output="$(
    "$CLI" handoff pack --mode XL --scenario code \
      --objective 'U3 legacy handoff regression' --json
  )"
  printf '%s\n' "$legacy_output"
  grep -q '"command" : "handoff pack"' <<<"$legacy_output"

  printf '== boundary: no lease-transfer subcommand exists ==\n'
  set +e
  lease_output="$("$CLI" cross-device-handoff lease-transfer --json 2>&1)"
  lease_status=$?
  set -e
  printf '%s\n' "$lease_output"
  [[ $lease_status -ne 0 ]]
  grep -q 'Unknown cross-device-handoff subcommand: lease-transfer' <<<"$lease_output"

  printf '== negative: independently expired signed pack ==\n'
  stale_pack="$WORK/stale-pack.json"
  stale_created_at="$(date -u -v-2H '+%Y-%m-%dT%H:%M:%SZ')"
  (
    cd "$SNAPSHOT"
    export GIT_DIR="$ROOT/.git" GIT_WORK_TREE="$SNAPSHOT" GIT_OPTIONAL_LOCKS=0
    run_for "$ORIGIN" cross-device-handoff pack-create --out "$stale_pack" \
      --goal-hash "$goal_hash" --plan-hash "$plan_hash" \
      --logical-job u3-stale-selftest --receiver-device receiver-selftest \
      --files "docs/protocol/CROSS_DEVICE_TASK_HANDOFF_DESIGN.md:$design_hash" \
      --created-at "$stale_created_at" --freshness-seconds 60
  )
  set +e
  stale_output="$(
    run_for "$RECEIVER" cross-device-handoff pack-verify --in "$stale_pack" \
      --expect-producer origin-selftest --expect-receiver receiver-selftest 2>&1
  )"
  stale_status=$?
  set -e
  printf '%s\n' "$stale_output"
  [[ $stale_status -ne 0 ]]
  grep -q '"freshness_expired"' <<<"$stale_output"

  printf '== negative: wrong producer expectation ==\n'
  set +e
  wrong_producer="$(
    run_for "$RECEIVER" cross-device-handoff pack-verify --in "$pack" \
      --expect-producer not-origin --expect-receiver receiver-selftest 2>&1
  )"
  wrong_producer_status=$?
  set -e
  printf '%s\n' "$wrong_producer"
  [[ $wrong_producer_status -ne 0 ]]
  grep -q '"producer_mismatch"' <<<"$wrong_producer"

  printf '== negative: wrong receiver expectation ==\n'
  set +e
  wrong_receiver="$(
    run_for "$RECEIVER" cross-device-handoff pack-verify --in "$pack" \
      --expect-producer origin-selftest --expect-receiver not-receiver 2>&1
  )"
  wrong_receiver_status=$?
  set -e
  printf '%s\n' "$wrong_receiver"
  [[ $wrong_receiver_status -ne 0 ]]
  grep -q '"receiver_mismatch"' <<<"$wrong_receiver"

  printf '== negative: tampered signed pack ==\n'
  tampered_pack="$WORK/tampered-pack.json"
  python3 - "$pack" "$tampered_pack" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
value["goal"]["description"] = "tampered after signing"
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True)
PY
  set +e
  tampered_output="$(
    run_for "$RECEIVER" cross-device-handoff pack-verify --in "$tampered_pack" \
      --expect-producer origin-selftest --expect-receiver receiver-selftest 2>&1
  )"
  tampered_status=$?
  set -e
  printf '%s\n' "$tampered_output"
  [[ $tampered_status -ne 0 ]]
  grep -Eq '"digest_mismatch"|"signature_rejected"' <<<"$tampered_output"

  printf '== negative: assessment packDigest transplant ==\n'
  second_pack="$WORK/second-pack.json"
  (
    cd "$SNAPSHOT"
    export GIT_DIR="$ROOT/.git" GIT_WORK_TREE="$SNAPSHOT" GIT_OPTIONAL_LOCKS=0
    run_for "$ORIGIN" cross-device-handoff pack-create --out "$second_pack" \
      --goal-hash "$goal_hash" --plan-hash "$plan_hash" \
      --logical-job u3-second-selftest --receiver-device receiver-selftest \
      --files "docs/protocol/CROSS_DEVICE_TASK_HANDOFF_DESIGN.md:$design_hash"
  )
  set +e
  transplant_output="$(
    run_for "$ORIGIN" cross-device-handoff assessment-verify --in "$assessment" \
      --pack "$second_pack" 2>&1
  )"
  transplant_status=$?
  set -e
  printf '%s\n' "$transplant_output"
  [[ $transplant_status -ne 0 ]]
  grep -q '"packDigestBound" : false' <<<"$transplant_output"

  printf '== negative: tampered signed assessment ==\n'
  tampered_assessment="$WORK/tampered-assessment.json"
  python3 - "$assessment" "$tampered_assessment" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
value["decision"] = "reject"
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True)
PY
  set +e
  tampered_assessment_output="$(
    run_for "$ORIGIN" cross-device-handoff assessment-verify \
      --in "$tampered_assessment" --pack "$pack" 2>&1
  )"
  tampered_assessment_status=$?
  set -e
  printf '%s\n' "$tampered_assessment_output"
  [[ $tampered_assessment_status -ne 0 ]]
  grep -q '"signatureVerified" : false' <<<"$tampered_assessment_output"

  printf '== negative: receiver cannot impersonate origin pack producer ==\n'
  receiver_pack="$WORK/receiver-produced-pack.json"
  receiver_assessment="$WORK/receiver-produced-assessment.json"
  (
    cd "$SNAPSHOT"
    export GIT_DIR="$ROOT/.git" GIT_WORK_TREE="$SNAPSHOT" GIT_OPTIONAL_LOCKS=0
    run_for "$RECEIVER" cross-device-handoff pack-create --out "$receiver_pack" \
      --goal-hash "$goal_hash" --plan-hash "$plan_hash" \
      --logical-job u3-impersonation-selftest --receiver-device receiver-selftest \
      --files "docs/protocol/CROSS_DEVICE_TASK_HANDOFF_DESIGN.md:$design_hash"
  )
  run_for "$RECEIVER" cross-device-handoff assess --in "$receiver_pack" \
    --capabilities "$capabilities" --out "$receiver_assessment"
  set +e
  impersonation_output="$(
    run_for "$ORIGIN" cross-device-handoff assessment-verify --in "$receiver_assessment" \
      --pack "$receiver_pack" 2>&1
  )"
  impersonation_status=$?
  set -e
  printf '%s\n' "$impersonation_output"
  [[ $impersonation_status -ne 0 ]]
  grep -q '"packVerified" : false' <<<"$impersonation_output"

  printf '== negative: unpinned rogue producer ==\n'
  ROGUE="$WORK/rogue"
  ROGUE_STORE="$ROGUE/device-trust/pin-store"
  mkdir -p "$ROGUE/test-keys"
  run_for "$ROGUE" device-trust init --device-id rogue-selftest --store-root "$ROGUE_STORE"
  run_for "$ROGUE" device-trust export-identity --device-id rogue-selftest \
    --output "$ROGUE/device-trust/identity.json"
  rogue_pack="$WORK/rogue-pack.json"
  (
    cd "$SNAPSHOT"
    export GIT_DIR="$ROOT/.git" GIT_WORK_TREE="$SNAPSHOT" GIT_OPTIONAL_LOCKS=0
    run_for "$ROGUE" cross-device-handoff pack-create --out "$rogue_pack" \
      --goal-hash "$goal_hash" --plan-hash "$plan_hash" \
      --logical-job u3-rogue-selftest --receiver-device receiver-selftest \
      --files "docs/protocol/CROSS_DEVICE_TASK_HANDOFF_DESIGN.md:$design_hash"
  )
  set +e
  rogue_output="$(
    run_for "$RECEIVER" cross-device-handoff pack-verify --in "$rogue_pack" \
      --expect-producer rogue-selftest --expect-receiver receiver-selftest 2>&1
  )"
  rogue_status=$?
  set -e
  printf '%s\n' "$rogue_output"
  [[ $rogue_status -ne 0 ]]
  grep -q '"signature_rejected"' <<<"$rogue_output"

  printf 'SELFTEST PASS\n'
}

print_remote_plan() {
  cat <<'EOF'
# CROSS-DEVICE HANDOFF PLAN (MANUAL ONLY; NOTHING BELOW IS EXECUTED)
# Replace placeholders, confirm both device pins out-of-band, and run each line
# manually on the named host. This plan stops before durable lease transfer.

# 0. On both hosts: build/select the same tatwo-ultrawork source candidate.
export TATWO_CLI=/path/to/tatwo-ultrawork

# 1. ORIGIN: create a signed pack using its existing local trust.
cd /path/to/tatwo-ultrawork-repo
$TATWO_CLI cross-device-handoff pack-create \
  --out /tmp/handoff-pack.json \
  --goal-hash <64-hex-goal-sha256> \
  --plan-hash <64-hex-plan-sha256> \
  --logical-job <logical-job-id> \
  --receiver-device <receiver-device-id> \
  --files 'relative/path:<sha256>,relative/path2:<sha256>'

# 2. ORIGIN -> RECEIVER: manually copy the immutable pack.
scp /tmp/handoff-pack.json <receiver-host>:/tmp/handoff-pack.json

# 3. RECEIVER: verify first, then assess with a locally prepared declaration.
ssh <receiver-host> 'cd /path/to/tatwo-ultrawork-repo && \
  /path/to/tatwo-ultrawork cross-device-handoff pack-verify \
  --in /tmp/handoff-pack.json \
  --expect-producer <origin-device-id> \
  --expect-receiver <receiver-device-id>'
ssh <receiver-host> 'cd /path/to/tatwo-ultrawork-repo && \
  /path/to/tatwo-ultrawork cross-device-handoff assess \
  --in /tmp/handoff-pack.json \
  --capabilities /path/to/receiver-capabilities.json \
  --out /tmp/handoff-assessment.json'

# 4. RECEIVER -> ORIGIN: manually return the signed assessment.
scp <receiver-host>:/tmp/handoff-assessment.json /tmp/handoff-assessment.json

# 5. ORIGIN: verify signature, freshness, reporter, attempt identity, and packDigest.
$TATWO_CLI cross-device-handoff assessment-verify \
  --in /tmp/handoff-assessment.json \
  --pack /tmp/handoff-pack.json

# STOP. No lease-transfer command exists. Durable origin authority may change
# only through the separately approved human gate and fenced production path.
EOF
}

case "${1:-}" in
  --selftest) selftest ;;
  --print-remote-plan) print_remote_plan ;;
  *) usage; exit 2 ;;
esac
