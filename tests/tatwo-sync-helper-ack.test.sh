#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/scripts/tatwo-sync-helper.sh"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/tatwo-sync-helper-ack.XXXXXX")"
APP_SUPPORT="$FIXTURE/app"
BIN="$FIXTURE/bin"
INTENT_ID="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
REQUEST_ID="20260723T120000Z-TESTACK1"
SOURCE_DEVICE_ID="primary-device-id"
TARGET_DEVICE_ID="macbook-device-id"
CATALOG_REVISION="2026-07-23.2"
SOURCE_DIGEST="0123456789abcdef0123456789abcdef01234567"
LEDGER_SEQUENCE=12

cleanup() {
  if [ "${TATWO_KEEP_TEST_ROOT:-0}" = "1" ]; then
    printf 'tatwo_test_root_preserved=%s\n' "$FIXTURE" >&2
    return
  fi
  [ ! -e "$FIXTURE" ] || rm -r "$FIXTURE"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

mkdir -p "$BIN" "$APP_SUPPORT/device-sync-outbox/pending"
cp "$HELPER" "$BIN/tatwo-sync-helper.sh"
cat >"$BIN/tatwo-device-sync.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  role-status)
    printf '%s\n' \
      "device=mini role=${MOCK_ROLE:-primary} primary=mini epoch=${MOCK_EPOCH:-3} changedAt=2026-07-23T12:00:00Z"
    ;;
  sync-request)
    if [ "${MOCK_SYNC_REQUEST_FAIL:-0}" = "1" ]; then
      printf 'SYNC_SOURCE_REFRESH_ATTEMPT_ID=%s\n' \
        "${MOCK_SOURCE_REFRESH_ATTEMPT_ID:-missing-attempt}"
      printf '%s\n' "canonical source refresh failed before publication"
      exit 70
    fi
    if [ "${5:-}" = "system-pull" ]; then
      printf 'SYNC_SOURCE_REFRESH_ATTEMPT_ID=%s\n' \
        "${MOCK_SOURCE_REFRESH_ATTEMPT_ID:-$MOCK_REQUEST_ID}"
    fi
    printf '%s\n' "sync request published"
    printf 'SYNC_REQUEST_ID=%s\n' "$MOCK_REQUEST_ID"
    printf 'SYNC_AUTHORITY_EPOCH=%s\n' "${MOCK_EPOCH:-3}"
    printf 'SYNC_LEDGER_SEQUENCE=%s\n' "$MOCK_LEDGER_SEQUENCE"
    printf 'SYNC_AUTHORITY_PRIMARY=mini\n'
    printf 'SYNC_SOURCE_DEVICE_ID=%s\n' "$MOCK_SOURCE_DEVICE_ID"
    printf 'SYNC_TARGET_DEVICE_ID=%s\n' "$MOCK_TARGET_DEVICE_ID"
    printf 'SYNC_CATALOG_REVISION=%s\n' "$MOCK_CATALOG_REVISION"
    ;;
  sync-poll)
    printf '%s\n' "secondary poll noop"
    ;;
  trust-verify-artifact)
    device=""
    device_id=""
    purpose=""
    input=""
    signature=""
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --device) device="${2:-}"; shift 2;;
        --device-id) device_id="${2:-}"; shift 2;;
        --purpose) purpose="${2:-}"; shift 2;;
        --input) input="${2:-}"; shift 2;;
        --signature) signature="${2:-}"; shift 2;;
        *) exit 64;;
      esac
    done
    [ -f "$input" ] && [ -f "$signature" ] || exit 65
    input_digest="$(shasum -a 256 "$input" | awk '{print $1}')"
    [ "$(plutil -extract device raw "$signature" 2>/dev/null || true)" = "$device" ] \
      && [ "$(plutil -extract deviceID raw "$signature" 2>/dev/null || true)" = "$device_id" ] \
      && [ "$(plutil -extract purpose raw "$signature" 2>/dev/null || true)" = "$purpose" ] \
      && [ "$(plutil -extract digest raw "$signature" 2>/dev/null || true)" = "$input_digest" ] \
      || exit 65
    printf '%s\n' "mock device trust signature verified"
    ;;
  *)
    printf 'unexpected command: %s\n' "${1:-missing}" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$BIN/tatwo-sync-helper.sh" "$BIN/tatwo-device-sync.sh"

cat >"$APP_SUPPORT/device-sync-outbox/pending/$INTENT_ID.json" <<EOF
{
  "target": "macbook",
  "action": "version-pull",
  "requestedAt": "2026-07-23T12:00:00Z"
}
EOF

run_helper() {
  run_helper_at "$APP_SUPPORT" "$REQUEST_ID" "$LEDGER_SEQUENCE"
}

run_helper_at() {
  local app_support="$1"
  local request_id="$2"
  local ledger_sequence="$3"
  env \
    TATWO_APP_SUPPORT="$app_support" \
    TATWO_DEVICE_NAME="mini" \
    TATWO_DEVICE_ROLE="primary" \
    TATWO_AUTO_VERSION=0 \
    TATWO_SYNC_HELPER_ONCE=1 \
    TATWO_SYNC_CATALOG="$ROOT/config/tatwo-sync-catalog-v1.json" \
    MOCK_REQUEST_ID="$request_id" \
    MOCK_LEDGER_SEQUENCE="$ledger_sequence" \
    MOCK_SOURCE_DEVICE_ID="$SOURCE_DEVICE_ID" \
    MOCK_TARGET_DEVICE_ID="$TARGET_DEVICE_ID" \
    MOCK_CATALOG_REVISION="$CATALOG_REVISION" \
    MOCK_SYNC_REQUEST_FAIL="${MOCK_SYNC_REQUEST_FAIL:-0}" \
    MOCK_SOURCE_REFRESH_ATTEMPT_ID="${MOCK_SOURCE_REFRESH_ATTEMPT_ID:-}" \
    bash "$BIN/tatwo-sync-helper.sh"
}

sign_fixture_artifact() {
  local app_support="$1"
  local device="$2"
  local device_id="$3"
  local purpose="$4"
  local input="$5"
  local signature_relative="$6"
  local signature="$app_support/device-sync-channel/$signature_relative"
  local digest
  digest="$(shasum -a 256 "$input" | awk '{print $1}')"
  mkdir -p "$(dirname "$signature")"
  cat >"$signature" <<EOF
{
  "device": "$device",
  "deviceID": "$device_id",
  "purpose": "$purpose",
  "digest": "$digest"
}
EOF
}

sign_ack_at() {
  local app_support="$1"
  local request_id="$2"
  sign_fixture_artifact \
    "$app_support" "macbook" "$TARGET_DEVICE_ID" "sync-ack" \
    "$app_support/device-sync-channel/acks/$request_id.json" \
    "signatures/acks/$request_id.json"
}

sign_attestation_at() {
  local app_support="$1"
  local request_id="$2"
  sign_fixture_artifact \
    "$app_support" "macbook" "$TARGET_DEVICE_ID" "target-attestation" \
    "$app_support/device-sync-channel/attestations/macbook/$request_id.json" \
    "signatures/attestations/macbook/$request_id.json"
}

run_helper

RECEIPT="$APP_SUPPORT/device-sync-outbox/receipts/$INTENT_ID.json"
[ -f "$RECEIPT" ] || fail "helper writes an outbox receipt"
[ "$(plutil -extract result raw "$RECEIPT")" = "pending" ] \
  || fail "request publication is pending, not success"
[ "$(plutil -extract phase raw "$RECEIPT")" = "delivered" ] \
  || fail "request publication is delivered"
[ "$(plutil -extract requestID raw "$RECEIPT")" = "$REQUEST_ID" ] \
  || fail "receipt stores the stable request id"
[ "$(plutil -extract authorityEpoch raw "$RECEIPT")" = "3" ] \
  || fail "receipt stores the request authority epoch"
[ "$(plutil -extract ledgerSequence raw "$RECEIPT")" = "$LEDGER_SEQUENCE" ] \
  || fail "receipt stores the monotonic request ledger sequence"
[ "$(plutil -extract sourceDeviceID raw "$RECEIPT")" = "$SOURCE_DEVICE_ID" ] \
  || fail "receipt stores the request source device id"
[ "$(plutil -extract targetDeviceID raw "$RECEIPT")" = "$TARGET_DEVICE_ID" ] \
  || fail "receipt stores the expected target device id"
[ "$(plutil -extract catalogRevision raw "$RECEIPT")" = "$CATALOG_REVISION" ] \
  || fail "receipt stores the catalog revision"
pass "published request remains delivered until target ACK"

BOTH_INTENT_ID="FFFFFFFF-1111-2222-3333-444444444444"
cat >"$APP_SUPPORT/device-sync-outbox/pending/$BOTH_INTENT_ID.json" <<EOF
{
  "target": "macbook",
  "action": "both",
  "requestedAt": "2026-07-23T12:00:01Z"
}
EOF
run_helper
BOTH_RECEIPT="$APP_SUPPORT/device-sync-outbox/receipts/$BOTH_INTENT_ID.json"
[ -f "$BOTH_RECEIPT" ] || fail "combined action rejection receipt is missing"
[ "$(plutil -extract result raw "$BOTH_RECEIPT")" = "failure" ] \
  || fail "combined action was not rejected before request publication"
[ "$(plutil -extract phase raw "$BOTH_RECEIPT")" = "failed" ] \
  || fail "combined action rejection is not terminal and explicit"
[ -z "$(plutil -extract requestID raw "$BOTH_RECEIPT" 2>/dev/null || true)" ] \
  || fail "combined action unexpectedly published a sync request"
plutil -extract message raw "$BOTH_RECEIPT" 2>/dev/null \
  | grep -Eq 'separate|分開|不支援|unsupported' \
  || fail "combined action rejection does not explain the separate-request contract"
pass "combined action fails at entry instead of entering a non-converging workflow"

FAILED_REFRESH_APP_SUPPORT="$FIXTURE/app-failed-source-refresh"
FAILED_REFRESH_INTENT="22222222-1111-2222-3333-444444444444"
FAILED_REFRESH_ATTEMPT="20260726T020000Z-I3HELPER"
mkdir -p "$FAILED_REFRESH_APP_SUPPORT/device-sync-outbox/pending"
cat >"$FAILED_REFRESH_APP_SUPPORT/device-sync-outbox/pending/$FAILED_REFRESH_INTENT.json" <<EOF
{
  "target": "macbook",
  "action": "system-pull",
  "requestedAt": "2026-07-26T02:00:00Z"
}
EOF
MOCK_SYNC_REQUEST_FAIL=1
MOCK_SOURCE_REFRESH_ATTEMPT_ID="$FAILED_REFRESH_ATTEMPT"
run_helper_at "$FAILED_REFRESH_APP_SUPPORT" "unused-request" 15
unset MOCK_SYNC_REQUEST_FAIL MOCK_SOURCE_REFRESH_ATTEMPT_ID
FAILED_REFRESH_RECEIPT="$FAILED_REFRESH_APP_SUPPORT/device-sync-outbox/receipts/$FAILED_REFRESH_INTENT.json"
[ -f "$FAILED_REFRESH_RECEIPT" ] \
  || fail "failed source refresh does not leave a durable outbox receipt"
[ "$(plutil -extract phase raw "$FAILED_REFRESH_RECEIPT")" = "failed" ] \
  && [ "$(plutil -extract result raw "$FAILED_REFRESH_RECEIPT")" = "failure" ] \
  || fail "failed source refresh receipt is not explicitly terminal"
[ "$(plutil -extract sourceRefreshAttemptID raw "$FAILED_REFRESH_RECEIPT")" \
    = "$FAILED_REFRESH_ATTEMPT" ] \
  || fail "failed source refresh lost its exact attempt binding"
[ -z "$(plutil -extract requestID raw "$FAILED_REFRESH_RECEIPT" 2>/dev/null || true)" ] \
  || fail "failed source refresh fabricated a request ID"
[ ! -d "$FAILED_REFRESH_APP_SUPPORT/device-sync-channel/requests" ] \
  && [ ! -d "$FAILED_REFRESH_APP_SUPPORT/device-sync-channel/payloads" ] \
  || fail "failed source refresh created request or payload artifacts"
pass "failed source refresh keeps its attempt ID without request payload activation or convergence"

ACK="$APP_SUPPORT/device-sync-channel/acks/$REQUEST_ID.json"
REQUEST="$APP_SUPPORT/device-sync-channel/requests/macbook/$REQUEST_ID.json"
mkdir -p "$(dirname "$ACK")" "$(dirname "$REQUEST")"
cat >"$REQUEST" <<EOF
{
  "requestID": "$REQUEST_ID",
  "target": "macbook",
  "action": "version-pull",
  "authorityEpoch": 3,
  "ledgerSequence": $LEDGER_SEQUENCE,
  "authorityPrimary": "mini",
  "sourceDeviceID": "$SOURCE_DEVICE_ID",
  "targetDeviceID": "$TARGET_DEVICE_ID",
  "catalogRevision": "$CATALOG_REVISION",
  "sourceDigest": "$SOURCE_DIGEST"
}
EOF
cat >"$ACK" <<EOF
{
  "target": "wrong-device",
  "action": "version-pull",
  "requestedAt": "2026-07-23T12:00:00Z",
  "result": "converged",
  "completedAt": "2026-07-23T12:00:05Z",
  "message": "version digest verified",
  "phase": "converged",
  "requestID": "$REQUEST_ID",
  "authorityEpoch": 3,
  "ledgerSequence": $LEDGER_SEQUENCE,
  "authorityPrimary": "mini",
  "sourceDeviceID": "$SOURCE_DEVICE_ID",
  "targetDeviceID": "$TARGET_DEVICE_ID",
  "catalogRevision": "$CATALOG_REVISION",
  "signaturePurpose": "sync-ack",
  "signaturePath": "signatures/acks/$REQUEST_ID.json",
  "digestAlgorithm": "git-object-id",
  "sourceDigest": "$SOURCE_DIGEST",
  "appliedDigest": "$SOURCE_DIGEST",
  "requiredItemIDs": ["app.version"],
  "items": [
    {
      "id": "app.version",
      "displayName": "Tatwo App / source version",
      "phase": "verified",
      "digestAlgorithm": "git-object-id",
      "sourceDigest": "$SOURCE_DIGEST",
      "appliedDigest": "$SOURCE_DIGEST",
      "message": "verified"
    }
  ]
}
EOF
sign_ack_at "$APP_SUPPORT" "$REQUEST_ID"

run_helper
[ "$(plutil -extract phase raw "$RECEIPT")" = "delivered" ] \
  || fail "mismatched target ACK must not replace delivered receipt"
pass "mismatched target ACK is rejected"

plutil -replace target -string "macbook" "$ACK"
plutil -replace authorityEpoch -integer 2 "$ACK"
sign_ack_at "$APP_SUPPORT" "$REQUEST_ID"
run_helper
[ "$(plutil -extract phase raw "$RECEIPT")" = "delivered" ] \
  || fail "stale authority epoch ACK must not replace delivered receipt"
pass "stale authority epoch ACK is rejected"

plutil -replace authorityEpoch -integer 3 "$ACK"
plutil -replace sourceDeviceID -string "forged-primary" "$ACK"
sign_ack_at "$APP_SUPPORT" "$REQUEST_ID"
run_helper
[ "$(plutil -extract phase raw "$RECEIPT")" = "delivered" ] \
  || fail "forged source device ACK must not replace delivered receipt"
pass "forged source device ACK is rejected"

plutil -replace sourceDeviceID -string "$SOURCE_DEVICE_ID" "$ACK"
plutil -replace targetDeviceID -string "forged-target" "$ACK"
sign_ack_at "$APP_SUPPORT" "$REQUEST_ID"
run_helper
[ "$(plutil -extract phase raw "$RECEIPT")" = "delivered" ] \
  || fail "forged target device ACK must not replace delivered receipt"
pass "forged target device ACK is rejected"

plutil -replace targetDeviceID -string "$TARGET_DEVICE_ID" "$ACK"
plutil -replace action -string "db-pull" "$ACK"
sign_ack_at "$APP_SUPPORT" "$REQUEST_ID"
run_helper
[ "$(plutil -extract phase raw "$RECEIPT")" = "delivered" ] \
  || fail "forged action ACK must not replace delivered receipt"
pass "forged action ACK is rejected"

plutil -replace action -string "version-pull" "$ACK"
plutil -replace catalogRevision -string "stale-catalog" "$ACK"
sign_ack_at "$APP_SUPPORT" "$REQUEST_ID"
run_helper
[ "$(plutil -extract phase raw "$RECEIPT")" = "delivered" ] \
  || fail "wrong catalog revision ACK must not replace delivered receipt"
pass "wrong catalog revision ACK is rejected"

plutil -replace catalogRevision -string "$CATALOG_REVISION" "$ACK"
plutil -replace sourceDigest -string "" "$ACK"
sign_ack_at "$APP_SUPPORT" "$REQUEST_ID"
run_helper
[ "$(plutil -extract phase raw "$RECEIPT")" = "delivered" ] \
  || fail "converged ACK without source digest must not replace delivered receipt"
pass "converged ACK without digest evidence is rejected"

plutil -replace sourceDigest -string "$SOURCE_DIGEST" "$ACK"
sign_ack_at "$APP_SUPPORT" "$REQUEST_ID"
ACK_SIGNATURE="$APP_SUPPORT/device-sync-channel/signatures/acks/$REQUEST_ID.json"
mv "$ACK_SIGNATURE" "$ACK_SIGNATURE.missing"
run_helper
[ "$(plutil -extract phase raw "$RECEIPT")" = "delivered" ] \
  || fail "converged ACK without signature sidecar must not replace delivered receipt"
mv "$ACK_SIGNATURE.missing" "$ACK_SIGNATURE"
pass "missing ACK signature sidecar is rejected"

plutil -replace digest -string \
  "0000000000000000000000000000000000000000000000000000000000000000" \
  "$ACK_SIGNATURE"
run_helper
[ "$(plutil -extract phase raw "$RECEIPT")" = "delivered" ] \
  || fail "converged ACK with tampered signature sidecar must not replace delivered receipt"
pass "tampered ACK signature sidecar is rejected"

sign_ack_at "$APP_SUPPORT" "$REQUEST_ID"
run_helper
[ "$(plutil -extract result raw "$RECEIPT")" = "converged" ] \
  || fail "target ACK replaces pending result"
[ "$(plutil -extract phase raw "$RECEIPT")" = "converged" ] \
  || fail "target ACK exposes converged phase"
[ "$(plutil -extract items.0.appliedDigest raw "$RECEIPT")" = "$SOURCE_DIGEST" ] \
  || fail "target ACK preserves item digest evidence"
pass "outbox receipt converges only after target digest ACK"

UPDATE_APP_SUPPORT="$FIXTURE/app-progress-update"
UPDATE_INTENT="22222222-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
UPDATE_REQUEST_ID="20260723T120100Z-TESTACK2"
UPDATE_LEDGER_SEQUENCE=13
UPDATE_RECEIPT="$UPDATE_APP_SUPPORT/device-sync-outbox/receipts/$UPDATE_INTENT.json"
UPDATE_ACK="$UPDATE_APP_SUPPORT/device-sync-channel/acks/$UPDATE_REQUEST_ID.json"
UPDATE_REQUEST="$UPDATE_APP_SUPPORT/device-sync-channel/requests/macbook/$UPDATE_REQUEST_ID.json"
mkdir -p "$UPDATE_APP_SUPPORT/device-sync-outbox/pending"
cat >"$UPDATE_APP_SUPPORT/device-sync-outbox/pending/$UPDATE_INTENT.json" <<EOF
{
  "target": "macbook",
  "action": "version-pull",
  "requestedAt": "2026-07-23T12:01:00Z"
}
EOF
run_helper_at "$UPDATE_APP_SUPPORT" "$UPDATE_REQUEST_ID" "$UPDATE_LEDGER_SEQUENCE"
mkdir -p "$(dirname "$UPDATE_ACK")" "$(dirname "$UPDATE_REQUEST")"
cat >"$UPDATE_REQUEST" <<EOF
{
  "requestID": "$UPDATE_REQUEST_ID",
  "target": "macbook",
  "action": "version-pull",
  "authorityEpoch": 3,
  "ledgerSequence": $UPDATE_LEDGER_SEQUENCE,
  "authorityPrimary": "mini",
  "sourceDeviceID": "$SOURCE_DEVICE_ID",
  "targetDeviceID": "$TARGET_DEVICE_ID",
  "catalogRevision": "$CATALOG_REVISION",
  "sourceDigest": "$SOURCE_DIGEST"
}
EOF
cat >"$UPDATE_ACK" <<EOF
{
  "target": "macbook",
  "action": "version-pull",
  "requestedAt": "2026-07-23T12:01:00Z",
  "result": "partial",
  "completedAt": "2026-07-23T12:01:05Z",
  "message": "target is validating the staged revision",
  "phase": "validating",
  "requestID": "$UPDATE_REQUEST_ID",
  "authorityEpoch": 3,
  "ledgerSequence": $UPDATE_LEDGER_SEQUENCE,
  "authorityPrimary": "mini",
  "sourceDeviceID": "$SOURCE_DEVICE_ID",
  "targetDeviceID": "$TARGET_DEVICE_ID",
  "catalogRevision": "$CATALOG_REVISION",
  "signaturePurpose": "sync-ack",
  "signaturePath": "signatures/acks/$UPDATE_REQUEST_ID.json",
  "digestAlgorithm": "git-object-id",
  "sourceDigest": "$SOURCE_DIGEST",
  "appliedDigest": "",
  "requiredItemIDs": ["app.version"],
  "items": [],
  "progress": {
    "completedBytes": 60,
    "totalBytes": 100,
    "completedItems": 0,
    "totalItems": 1,
    "completedRepositories": 0,
    "totalRepositories": 0,
    "elapsedMilliseconds": 5000,
    "throughputBytesPerSecond": 12.0,
    "currentItem": "validating source revision"
  }
}
EOF
sign_ack_at "$UPDATE_APP_SUPPORT" "$UPDATE_REQUEST_ID"
run_helper_at "$UPDATE_APP_SUPPORT" "$UPDATE_REQUEST_ID" "$UPDATE_LEDGER_SEQUENCE"
[ "$(plutil -extract phase raw "$UPDATE_RECEIPT")" = "validating" ] \
  || fail "partial target ACK must advance delivered receipt to validating"
[ "$(plutil -extract progress.completedBytes raw "$UPDATE_RECEIPT")" = "60" ] \
  || fail "validating receipt must retain measured byte progress"

plutil -replace phase -string "transferring" "$UPDATE_ACK"
plutil -replace progress.completedBytes -integer 40 "$UPDATE_ACK"
plutil -replace progress.elapsedMilliseconds -integer 6000 "$UPDATE_ACK"
sign_ack_at "$UPDATE_APP_SUPPORT" "$UPDATE_REQUEST_ID"
run_helper_at "$UPDATE_APP_SUPPORT" "$UPDATE_REQUEST_ID" "$UPDATE_LEDGER_SEQUENCE"
[ "$(plutil -extract phase raw "$UPDATE_RECEIPT")" = "validating" ] \
  || fail "regressive phase must not replace a newer validating receipt"
[ "$(plutil -extract progress.completedBytes raw "$UPDATE_RECEIPT")" = "60" ] \
  || fail "regressive measured counters must not replace current progress"
pass "helper rejects phase and measured-counter regression"

plutil -replace result -string "converged" "$UPDATE_ACK"
plutil -replace phase -string "converged" "$UPDATE_ACK"
plutil -replace completedAt -string "2026-07-23T12:01:10Z" "$UPDATE_ACK"
plutil -replace message -string "target verified and activated the bound revision" "$UPDATE_ACK"
plutil -replace digestAlgorithm -string "git-object-id" "$UPDATE_ACK"
plutil -replace sourceDigest -string "$SOURCE_DIGEST" "$UPDATE_ACK"
plutil -replace appliedDigest -string "$SOURCE_DIGEST" "$UPDATE_ACK"
plutil -replace progress.completedBytes -integer 100 "$UPDATE_ACK"
plutil -replace progress.completedItems -integer 1 "$UPDATE_ACK"
plutil -replace progress.elapsedMilliseconds -integer 10000 "$UPDATE_ACK"
plutil -replace progress.throughputBytesPerSecond -float 10.0 "$UPDATE_ACK"
plutil -replace progress.currentItem -string "active revision readback" "$UPDATE_ACK"
plutil -replace items -json "[{\"id\":\"app.version\",\"displayName\":\"Tatwo App / source version\",\"phase\":\"verified\",\"digestAlgorithm\":\"git-object-id\",\"sourceDigest\":\"$SOURCE_DIGEST\",\"appliedDigest\":\"$SOURCE_DIGEST\",\"message\":\"verified\"}]" "$UPDATE_ACK"
sign_ack_at "$UPDATE_APP_SUPPORT" "$UPDATE_REQUEST_ID"
run_helper_at "$UPDATE_APP_SUPPORT" "$UPDATE_REQUEST_ID" "$UPDATE_LEDGER_SEQUENCE"
[ "$(plutil -extract phase raw "$UPDATE_RECEIPT")" = "converged" ] \
  || fail "later converged ACK must replace an earlier validating receipt"
[ "$(plutil -extract appliedDigest raw "$UPDATE_RECEIPT")" = "$SOURCE_DIGEST" ] \
  || fail "converged update must retain final digest evidence"
[ "$(plutil -extract progress.completedBytes raw "$UPDATE_RECEIPT")" = "100" ] \
  || fail "converged receipt must expose complete measured progress"
pass "validating partial ACK can advance to a later converged ACK"

SYSTEM_APP_SUPPORT="$FIXTURE/app-system-forgery"
SYSTEM_INTENT="33333333-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
SYSTEM_REQUEST_ID="20260723T120200Z-TESTACK3"
SYSTEM_LEDGER_SEQUENCE=14
SYSTEM_RECEIPT="$SYSTEM_APP_SUPPORT/device-sync-outbox/receipts/$SYSTEM_INTENT.json"
SYSTEM_PAYLOAD_ROOT="$SYSTEM_APP_SUPPORT/device-sync-channel/payloads/$SYSTEM_REQUEST_ID"
SYSTEM_MANIFEST="$SYSTEM_PAYLOAD_ROOT/manifest.json"
SYSTEM_REQUEST="$SYSTEM_APP_SUPPORT/device-sync-channel/requests/macbook/$SYSTEM_REQUEST_ID.json"
SYSTEM_ACK="$SYSTEM_APP_SUPPORT/device-sync-channel/acks/$SYSTEM_REQUEST_ID.json"
SYSTEM_ATTESTATION_RELATIVE="attestations/macbook/$SYSTEM_REQUEST_ID.json"
SYSTEM_ATTESTATION="$SYSTEM_APP_SUPPORT/device-sync-channel/$SYSTEM_ATTESTATION_RELATIVE"
SYSTEM_CONSUMER_READBACK_RELATIVE="consumer-readbacks/macbook/$SYSTEM_REQUEST_ID.json"
SYSTEM_CONSUMER_READBACK="$SYSTEM_APP_SUPPORT/device-sync-channel/$SYSTEM_CONSUMER_READBACK_RELATIVE"
SYSTEM_ITEM_DIGEST_1="$(printf 'constitution' | shasum -a 256 | awk '{print $1}')"
SYSTEM_ITEM_DIGEST_2="$(printf 'issue' | shasum -a 256 | awk '{print $1}')"
SYSTEM_ITEM_DIGEST_3="$(printf 'todo' | shasum -a 256 | awk '{print $1}')"
SKILLET_CONTENT_DIGEST="$(printf 'skill-content' | shasum -a 256 | awk '{print $1}')"
SKILLET_REVISION_ID="rev-$SKILLET_CONTENT_DIGEST"
SKILLET_BUNDLE_DIGEST="$(printf 'skill-bundle' | shasum -a 256 | awk '{print $1}')"
FORGED_SYSTEM_ITEM_DIGEST="$(printf 'forged-issue' | shasum -a 256 | awk '{print $1}')"
FORGED_SKILLET_BUNDLE_DIGEST="$(printf 'forged-bundle' | shasum -a 256 | awk '{print $1}')"
SYSTEM_SKILLET_ROOT="$SYSTEM_PAYLOAD_ROOT/items/skills.skillet"
SYSTEM_SKILLET_SET="$SYSTEM_SKILLET_ROOT/set.json"
SYSTEM_SKILLET_BUNDLE="$SYSTEM_SKILLET_ROOT/repositories/alpha-skill/bundle"
SYSTEM_SKILLET_BINDING="$SYSTEM_SKILLET_ROOT/repositories/alpha-skill/authority-binding.json"
mkdir -p "$SYSTEM_APP_SUPPORT/device-sync-outbox/pending"
cat >"$SYSTEM_APP_SUPPORT/device-sync-outbox/pending/$SYSTEM_INTENT.json" <<EOF
{
  "target": "macbook",
  "action": "system-pull",
  "requestedAt": "2026-07-23T12:02:00Z"
}
EOF
run_helper_at "$SYSTEM_APP_SUPPORT" "$SYSTEM_REQUEST_ID" "$SYSTEM_LEDGER_SEQUENCE"
mkdir -p \
  "$(dirname "$SYSTEM_REQUEST")" \
  "$(dirname "$SYSTEM_ACK")" \
  "$SYSTEM_SKILLET_BUNDLE"
printf '%s\n' \
  "---" \
  "name: alpha-skill" \
  "description: Signed helper ACK native skill fixture" \
  "---" \
  "# alpha-skill" \
  >"$SYSTEM_SKILLET_BUNDLE/SKILL.md"
cat >"$SYSTEM_SKILLET_BINDING" <<EOF
{
  "repositoryID": "alpha-skill",
  "exportedRevisionID": "$SKILLET_REVISION_ID",
  "bundleDigest": "$SKILLET_BUNDLE_DIGEST",
  "requestID": "$SYSTEM_REQUEST_ID",
  "sourceDeviceID": "$SOURCE_DEVICE_ID",
  "targetDeviceID": "$TARGET_DEVICE_ID",
  "authorityEpoch": 3,
  "ledgerSequence": $SYSTEM_LEDGER_SEQUENCE,
  "catalogRevision": "$CATALOG_REVISION"
}
EOF
cat >"$SYSTEM_SKILLET_SET" <<EOF
{
  "schemaVersion": 1,
  "requestID": "$SYSTEM_REQUEST_ID",
  "sourceDeviceID": "$SOURCE_DEVICE_ID",
  "targetDeviceID": "$TARGET_DEVICE_ID",
  "authorityEpoch": 3,
  "ledgerSequence": $SYSTEM_LEDGER_SEQUENCE,
  "catalogRevision": "$CATALOG_REVISION",
  "repositories": [
    {
      "repositoryID": "alpha-skill",
      "revisionID": "$SKILLET_REVISION_ID",
      "contentDigest": "$SKILLET_CONTENT_DIGEST",
      "bundleDigest": "$SKILLET_BUNDLE_DIGEST",
      "bundleRelativePath": "repositories/alpha-skill/bundle",
      "bindingRelativePath": "repositories/alpha-skill/authority-binding.json"
    }
  ]
}
EOF
SYSTEM_ITEM_DIGEST_4="$(shasum -a 256 "$SYSTEM_SKILLET_SET" | awk '{print $1}')"
cat >"$SYSTEM_MANIFEST" <<EOF
{
  "requestID": "$SYSTEM_REQUEST_ID",
  "sourceDeviceID": "$SOURCE_DEVICE_ID",
  "targetDeviceID": "$TARGET_DEVICE_ID",
  "authorityPrimary": "mini",
  "authorityEpoch": 3,
  "ledgerSequence": $SYSTEM_LEDGER_SEQUENCE,
  "catalogRevision": "$CATALOG_REVISION",
  "items": [
    {"id": "os.constitution", "sourceDigest": "$SYSTEM_ITEM_DIGEST_1"},
    {"id": "os.issue", "sourceDigest": "$SYSTEM_ITEM_DIGEST_2"},
    {"id": "os.todo", "sourceDigest": "$SYSTEM_ITEM_DIGEST_3"},
    {
      "id": "skills.skillet",
      "sourceDigest": "$SYSTEM_ITEM_DIGEST_4",
      "payloadRelativePath": "items/skills.skillet/set.json",
      "repositoryCount": 1
    }
  ]
}
EOF
SYSTEM_MANIFEST_DIGEST="$(shasum -a 256 "$SYSTEM_MANIFEST" | awk '{print $1}')"
cat >"$SYSTEM_REQUEST" <<EOF
{
  "requestID": "$SYSTEM_REQUEST_ID",
  "target": "macbook",
  "action": "system-pull",
  "authorityEpoch": 3,
  "ledgerSequence": $SYSTEM_LEDGER_SEQUENCE,
  "authorityPrimary": "mini",
  "sourceDeviceID": "$SOURCE_DEVICE_ID",
  "targetDeviceID": "$TARGET_DEVICE_ID",
  "catalogRevision": "$CATALOG_REVISION",
  "sourceDigest": "$SYSTEM_MANIFEST_DIGEST",
  "manifestPath": "payloads/$SYSTEM_REQUEST_ID/manifest.json",
  "manifestDigest": "$SYSTEM_MANIFEST_DIGEST"
}
EOF
cat >"$SYSTEM_ACK" <<EOF
{
  "target": "macbook",
  "action": "system-pull",
  "requestedAt": "2026-07-23T12:02:00Z",
  "result": "converged",
  "completedAt": "2026-07-23T12:02:05Z",
  "message": "forged item digest",
  "phase": "converged",
  "requestID": "$SYSTEM_REQUEST_ID",
  "authorityEpoch": 3,
  "ledgerSequence": $SYSTEM_LEDGER_SEQUENCE,
  "authorityPrimary": "mini",
  "sourceDeviceID": "$SOURCE_DEVICE_ID",
  "targetDeviceID": "$TARGET_DEVICE_ID",
  "catalogRevision": "$CATALOG_REVISION",
  "signaturePurpose": "sync-ack",
  "signaturePath": "signatures/acks/$SYSTEM_REQUEST_ID.json",
  "digestAlgorithm": "sha256",
  "sourceDigest": "$SYSTEM_MANIFEST_DIGEST",
  "appliedDigest": "$SYSTEM_MANIFEST_DIGEST",
  "requiredItemIDs": ["os.constitution", "os.issue", "os.todo", "skills.skillet"],
  "items": [
    {"id": "os.constitution", "displayName": "os.md", "phase": "verified", "digestAlgorithm": "sha256", "sourceDigest": "$SYSTEM_ITEM_DIGEST_1", "appliedDigest": "$SYSTEM_ITEM_DIGEST_1", "message": "verified"},
    {"id": "os.issue", "displayName": "issue.md", "phase": "verified", "digestAlgorithm": "sha256", "sourceDigest": "$FORGED_SYSTEM_ITEM_DIGEST", "appliedDigest": "$FORGED_SYSTEM_ITEM_DIGEST", "message": "forged"},
    {"id": "os.todo", "displayName": "TODO.md", "phase": "verified", "digestAlgorithm": "sha256", "sourceDigest": "$SYSTEM_ITEM_DIGEST_3", "appliedDigest": "$SYSTEM_ITEM_DIGEST_3", "message": "verified"},
    {
      "id": "skills.skillet",
      "displayName": "Skillet private repositories",
      "phase": "verified",
      "digestAlgorithm": "sha256",
      "sourceDigest": "$SYSTEM_ITEM_DIGEST_4",
      "appliedDigest": "$SYSTEM_ITEM_DIGEST_4",
      "message": "verified",
      "repositoryCount": 1,
      "repositories": [
        {
          "repositoryID": "alpha-skill",
          "revisionID": "$SKILLET_REVISION_ID",
          "contentDigest": "$SKILLET_CONTENT_DIGEST",
          "bundleDigest": "$SKILLET_BUNDLE_DIGEST",
          "requestID": "$SYSTEM_REQUEST_ID",
          "sourceDeviceID": "$SOURCE_DEVICE_ID",
          "targetDeviceID": "$TARGET_DEVICE_ID",
          "authorityEpoch": 3,
          "ledgerSequence": $SYSTEM_LEDGER_SEQUENCE,
          "catalogRevision": "$CATALOG_REVISION",
          "phase": "verified"
        }
      ]
    }
  ]
}
EOF
sign_ack_at "$SYSTEM_APP_SUPPORT" "$SYSTEM_REQUEST_ID"
run_helper_at "$SYSTEM_APP_SUPPORT" "$SYSTEM_REQUEST_ID" "$SYSTEM_LEDGER_SEQUENCE"
[ "$(plutil -extract phase raw "$SYSTEM_RECEIPT")" = "delivered" ] \
  || fail "forged system item digest must not replace the delivered receipt"
pass "primary helper rejects forged system item digest evidence"

plutil -replace items.1.sourceDigest -string "$SYSTEM_ITEM_DIGEST_2" "$SYSTEM_ACK"
plutil -replace items.1.appliedDigest -string "$SYSTEM_ITEM_DIGEST_2" "$SYSTEM_ACK"
plutil -replace items.3.repositories.0.bundleDigest \
  -string "$FORGED_SKILLET_BUNDLE_DIGEST" "$SYSTEM_ACK"
sign_ack_at "$SYSTEM_APP_SUPPORT" "$SYSTEM_REQUEST_ID"
run_helper_at "$SYSTEM_APP_SUPPORT" "$SYSTEM_REQUEST_ID" "$SYSTEM_LEDGER_SEQUENCE"
[ "$(plutil -extract phase raw "$SYSTEM_RECEIPT")" = "delivered" ] \
  || fail "forged Skillet bundle digest must not replace the delivered receipt"
pass "primary helper rejects forged Skillet bundle digest evidence"

plutil -replace items.3.repositories.0.bundleDigest \
  -string "$SKILLET_BUNDLE_DIGEST" "$SYSTEM_ACK"
plutil -replace items.3.repositories.0.requestID -string "forged-request" "$SYSTEM_ACK"
sign_ack_at "$SYSTEM_APP_SUPPORT" "$SYSTEM_REQUEST_ID"
run_helper_at "$SYSTEM_APP_SUPPORT" "$SYSTEM_REQUEST_ID" "$SYSTEM_LEDGER_SEQUENCE"
[ "$(plutil -extract phase raw "$SYSTEM_RECEIPT")" = "delivered" ] \
  || fail "forged Skillet request binding must not replace the delivered receipt"
pass "primary helper rejects forged Skillet request binding"

plutil -replace items.3.repositories.0.requestID -string "$SYSTEM_REQUEST_ID" "$SYSTEM_ACK"
plutil -replace items.3.repositories.0.authorityEpoch -integer 2 "$SYSTEM_ACK"
sign_ack_at "$SYSTEM_APP_SUPPORT" "$SYSTEM_REQUEST_ID"
run_helper_at "$SYSTEM_APP_SUPPORT" "$SYSTEM_REQUEST_ID" "$SYSTEM_LEDGER_SEQUENCE"
[ "$(plutil -extract phase raw "$SYSTEM_RECEIPT")" = "delivered" ] \
  || fail "forged Skillet epoch binding must not replace the delivered receipt"
pass "primary helper rejects forged Skillet epoch binding"

plutil -replace items.3.repositories.0.authorityEpoch -integer 3 "$SYSTEM_ACK"
plutil -replace items.3.repositories.0.catalogRevision -string "stale-catalog" "$SYSTEM_ACK"
sign_ack_at "$SYSTEM_APP_SUPPORT" "$SYSTEM_REQUEST_ID"
run_helper_at "$SYSTEM_APP_SUPPORT" "$SYSTEM_REQUEST_ID" "$SYSTEM_LEDGER_SEQUENCE"
[ "$(plutil -extract phase raw "$SYSTEM_RECEIPT")" = "delivered" ] \
  || fail "forged Skillet catalog binding must not replace the delivered receipt"
pass "primary helper rejects forged Skillet catalog binding"

plutil -replace items.3.repositories.0.catalogRevision -string "$CATALOG_REVISION" "$SYSTEM_ACK"
sign_ack_at "$SYSTEM_APP_SUPPORT" "$SYSTEM_REQUEST_ID"
run_helper_at "$SYSTEM_APP_SUPPORT" "$SYSTEM_REQUEST_ID" "$SYSTEM_LEDGER_SEQUENCE"
[ "$(plutil -extract phase raw "$SYSTEM_RECEIPT")" = "delivered" ] \
  || fail "channel-only system ACK must not replace the delivered receipt"
pass "primary helper distinguishes channel claim from target-local system attestation"

mkdir -p "$(dirname "$SYSTEM_ATTESTATION")" "$(dirname "$SYSTEM_CONSUMER_READBACK")"
cat >"$SYSTEM_CONSUMER_READBACK" <<EOF
{
  "schema": "TatwoTargetConsumerReadbackSetV1",
  "requestID": "$SYSTEM_REQUEST_ID",
  "target": "macbook",
  "targetDeviceID": "$TARGET_DEVICE_ID",
  "sourceDeviceID": "$SOURCE_DEVICE_ID",
  "authorityPrimary": "mini",
  "authorityEpoch": 3,
  "ledgerSequence": $SYSTEM_LEDGER_SEQUENCE,
  "catalogRevision": "$CATALOG_REVISION",
  "manifestDigest": "$SYSTEM_MANIFEST_DIGEST",
  "requiredConsumerIDs": [
    "work-os.bootstrap",
    "tatwo-app.shared-runtime",
    "skillet.runtime-loader",
    "codex.native-skills",
    "claude.native-skills"
  ],
  "readbackCount": 9,
  "readbacks": [
    {
      "schema": "TatwoTargetConsumerReadbackV1",
      "requestID": "$SYSTEM_REQUEST_ID",
      "targetDeviceID": "$TARGET_DEVICE_ID",
      "authorityPrimary": "mini",
      "authorityEpoch": 3,
      "ledgerSequence": $SYSTEM_LEDGER_SEQUENCE,
      "catalogRevision": "$CATALOG_REVISION",
      "consumerID": "work-os.bootstrap",
      "consumerKind": "work-os-bootstrap",
      "sourceItemID": "os.constitution",
      "expectedDigest": "$SYSTEM_ITEM_DIGEST_1",
      "loadedDigest": "$SYSTEM_ITEM_DIGEST_1",
      "loadedRevision": "sha256-$SYSTEM_ITEM_DIGEST_1",
      "loadedPath": "os/os.md",
      "runtimeRef": "TatwoWorkOSBootstrap",
      "observedAt": "2026-07-23T12:02:04Z",
      "status": "loaded"
    },
    {
      "schema": "TatwoTargetConsumerReadbackV1",
      "requestID": "$SYSTEM_REQUEST_ID",
      "targetDeviceID": "$TARGET_DEVICE_ID",
      "authorityPrimary": "mini",
      "authorityEpoch": 3,
      "ledgerSequence": $SYSTEM_LEDGER_SEQUENCE,
      "catalogRevision": "$CATALOG_REVISION",
      "consumerID": "work-os.bootstrap",
      "consumerKind": "work-os-bootstrap",
      "sourceItemID": "os.issue",
      "expectedDigest": "$SYSTEM_ITEM_DIGEST_2",
      "loadedDigest": "$SYSTEM_ITEM_DIGEST_2",
      "loadedRevision": "sha256-$SYSTEM_ITEM_DIGEST_2",
      "loadedPath": "os/issue.md",
      "runtimeRef": "TatwoWorkOSBootstrap",
      "observedAt": "2026-07-23T12:02:04Z",
      "status": "loaded"
    },
    {
      "schema": "TatwoTargetConsumerReadbackV1",
      "requestID": "$SYSTEM_REQUEST_ID",
      "targetDeviceID": "$TARGET_DEVICE_ID",
      "authorityPrimary": "mini",
      "authorityEpoch": 3,
      "ledgerSequence": $SYSTEM_LEDGER_SEQUENCE,
      "catalogRevision": "$CATALOG_REVISION",
      "consumerID": "work-os.bootstrap",
      "consumerKind": "work-os-bootstrap",
      "sourceItemID": "os.todo",
      "expectedDigest": "$SYSTEM_ITEM_DIGEST_3",
      "loadedDigest": "$SYSTEM_ITEM_DIGEST_3",
      "loadedRevision": "sha256-$SYSTEM_ITEM_DIGEST_3",
      "loadedPath": "os/TODO.md",
      "runtimeRef": "TatwoWorkOSBootstrap",
      "observedAt": "2026-07-23T12:02:04Z",
      "status": "loaded"
    },
    {
      "schema": "TatwoTargetConsumerReadbackV1",
      "requestID": "$SYSTEM_REQUEST_ID",
      "targetDeviceID": "$TARGET_DEVICE_ID",
      "authorityPrimary": "mini",
      "authorityEpoch": 3,
      "ledgerSequence": $SYSTEM_LEDGER_SEQUENCE,
      "catalogRevision": "$CATALOG_REVISION",
      "consumerID": "tatwo-app.shared-runtime",
      "consumerKind": "tatwo-app-shared-loader",
      "sourceItemID": "os.constitution",
      "expectedDigest": "$SYSTEM_ITEM_DIGEST_1",
      "loadedDigest": "$SYSTEM_ITEM_DIGEST_1",
      "loadedRevision": "sha256-$SYSTEM_ITEM_DIGEST_1",
      "loadedPath": "os/os.md",
      "runtimeRef": "TatwoUltraworkCore",
      "observedAt": "2026-07-23T12:02:04Z",
      "status": "loaded"
    },
    {
      "schema": "TatwoTargetConsumerReadbackV1",
      "requestID": "$SYSTEM_REQUEST_ID",
      "targetDeviceID": "$TARGET_DEVICE_ID",
      "authorityPrimary": "mini",
      "authorityEpoch": 3,
      "ledgerSequence": $SYSTEM_LEDGER_SEQUENCE,
      "catalogRevision": "$CATALOG_REVISION",
      "consumerID": "tatwo-app.shared-runtime",
      "consumerKind": "tatwo-app-shared-loader",
      "sourceItemID": "os.issue",
      "expectedDigest": "$SYSTEM_ITEM_DIGEST_2",
      "loadedDigest": "$SYSTEM_ITEM_DIGEST_2",
      "loadedRevision": "sha256-$SYSTEM_ITEM_DIGEST_2",
      "loadedPath": "os/issue.md",
      "runtimeRef": "TatwoUltraworkCore",
      "observedAt": "2026-07-23T12:02:04Z",
      "status": "loaded"
    },
    {
      "schema": "TatwoTargetConsumerReadbackV1",
      "requestID": "$SYSTEM_REQUEST_ID",
      "targetDeviceID": "$TARGET_DEVICE_ID",
      "authorityPrimary": "mini",
      "authorityEpoch": 3,
      "ledgerSequence": $SYSTEM_LEDGER_SEQUENCE,
      "catalogRevision": "$CATALOG_REVISION",
      "consumerID": "tatwo-app.shared-runtime",
      "consumerKind": "tatwo-app-shared-loader",
      "sourceItemID": "os.todo",
      "expectedDigest": "$SYSTEM_ITEM_DIGEST_3",
      "loadedDigest": "$SYSTEM_ITEM_DIGEST_3",
      "loadedRevision": "sha256-$SYSTEM_ITEM_DIGEST_3",
      "loadedPath": "os/TODO.md",
      "runtimeRef": "TatwoUltraworkCore",
      "observedAt": "2026-07-23T12:02:04Z",
      "status": "loaded"
    },
    {
      "schema": "TatwoTargetConsumerReadbackV1",
      "requestID": "$SYSTEM_REQUEST_ID",
      "targetDeviceID": "$TARGET_DEVICE_ID",
      "authorityPrimary": "mini",
      "authorityEpoch": 3,
      "ledgerSequence": $SYSTEM_LEDGER_SEQUENCE,
      "catalogRevision": "$CATALOG_REVISION",
      "consumerID": "skillet.runtime-loader",
      "consumerKind": "active-skill-runtime-loader",
      "sourceItemID": "skills.skillet",
      "expectedDigest": "$SKILLET_CONTENT_DIGEST",
      "loadedDigest": "$SKILLET_CONTENT_DIGEST",
      "loadedRevision": "$SKILLET_REVISION_ID",
      "loadedPath": "skillet/alpha-skill",
      "runtimeRef": "TatwoSkilletBundleTransport.verifyAuthorityBoundSetIsActive",
      "observedAt": "2026-07-23T12:02:04Z",
      "status": "loaded"
    },
    {
      "schema": "TatwoTargetConsumerReadbackV1",
      "requestID": "$SYSTEM_REQUEST_ID",
      "targetDeviceID": "$TARGET_DEVICE_ID",
      "authorityPrimary": "mini",
      "authorityEpoch": 3,
      "ledgerSequence": $SYSTEM_LEDGER_SEQUENCE,
      "catalogRevision": "$CATALOG_REVISION",
      "consumerID": "codex.native-skills",
      "consumerKind": "codex-native-skills-loader",
      "sourceItemID": "skills.skillet",
      "expectedDigest": "$SKILLET_CONTENT_DIGEST",
      "loadedDigest": "$SKILLET_CONTENT_DIGEST",
      "loadedRevision": "$SKILLET_REVISION_ID",
      "loadedPath": ".codex/skills/alpha-skill",
      "runtimeRef": "TatwoTargetConsumerReadbackProbe.probeNativeSkillsConsumers",
      "observedAt": "2026-07-23T12:02:04Z",
      "status": "loaded"
    },
    {
      "schema": "TatwoTargetConsumerReadbackV1",
      "requestID": "$SYSTEM_REQUEST_ID",
      "targetDeviceID": "$TARGET_DEVICE_ID",
      "authorityPrimary": "mini",
      "authorityEpoch": 3,
      "ledgerSequence": $SYSTEM_LEDGER_SEQUENCE,
      "catalogRevision": "$CATALOG_REVISION",
      "consumerID": "claude.native-skills",
      "consumerKind": "claude-native-skills-loader",
      "sourceItemID": "skills.skillet",
      "expectedDigest": "$SKILLET_CONTENT_DIGEST",
      "loadedDigest": "$SKILLET_CONTENT_DIGEST",
      "loadedRevision": "$SKILLET_REVISION_ID",
      "loadedPath": ".claude/skills/alpha-skill",
      "runtimeRef": "TatwoTargetConsumerReadbackProbe.probeNativeSkillsConsumers",
      "observedAt": "2026-07-23T12:02:04Z",
      "status": "loaded"
    }
  ],
  "observedAt": "2026-07-23T12:02:04Z",
  "status": "passed"
}
EOF
SYSTEM_CONSUMER_READBACK_DIGEST="$(
  shasum -a 256 "$SYSTEM_CONSUMER_READBACK" | awk '{print $1}'
)"
cat >"$SYSTEM_ATTESTATION" <<EOF
{
  "schema": "TatwoTargetLocalSystemAttestationV2",
  "kind": "target-local-consumer-readback-attested",
  "requestID": "$SYSTEM_REQUEST_ID",
  "target": "macbook",
  "authorityEpoch": 3,
  "ledgerSequence": $SYSTEM_LEDGER_SEQUENCE,
  "authorityPrimary": "mini",
  "sourceDeviceID": "$SOURCE_DEVICE_ID",
  "targetDeviceID": "$TARGET_DEVICE_ID",
  "catalogRevision": "$CATALOG_REVISION",
  "transactionPhase": "committed",
  "transactionJournalDigest": "$(printf 'journal' | shasum -a 256 | awk '{print $1}')",
  "manifestDigest": "$SYSTEM_MANIFEST_DIGEST",
  "skilletActiveSetReceiptDigest": "$(printf 'skillet-receipt' | shasum -a 256 | awk '{print $1}')",
  "consumerReadbackKind": "actual-consumer-readback-set",
  "consumerReadbackPath": "$SYSTEM_CONSUMER_READBACK_RELATIVE",
  "consumerReadbackDigest": "$SYSTEM_CONSUMER_READBACK_DIGEST",
  "consumerReadbackCount": 9,
  "signaturePurpose": "target-attestation",
  "signaturePath": "signatures/attestations/macbook/$SYSTEM_REQUEST_ID.json",
  "attestedAt": "2026-07-23T12:02:05Z"
}
EOF
sign_attestation_at "$SYSTEM_APP_SUPPORT" "$SYSTEM_REQUEST_ID"
SYSTEM_ATTESTATION_DIGEST="$(shasum -a 256 "$SYSTEM_ATTESTATION" | awk '{print $1}')"
plutil -insert attestationKind -string "target-local-consumer-readback-attested" "$SYSTEM_ACK"
plutil -insert targetAttestationPath -string "$SYSTEM_ATTESTATION_RELATIVE" "$SYSTEM_ACK"
plutil -insert targetAttestationDigest -string "$SYSTEM_ATTESTATION_DIGEST" "$SYSTEM_ACK"
plutil -insert consumerReadbackKind -string "actual-consumer-readback-set" "$SYSTEM_ACK"
plutil -insert consumerReadbackPath -string "$SYSTEM_CONSUMER_READBACK_RELATIVE" "$SYSTEM_ACK"
plutil -insert consumerReadbackDigest -string "$SYSTEM_CONSUMER_READBACK_DIGEST" "$SYSTEM_ACK"
plutil -insert consumerReadbackCount -integer 9 "$SYSTEM_ACK"
plutil -insert targetAttestationSignaturePath \
  -string "signatures/attestations/macbook/$SYSTEM_REQUEST_ID.json" "$SYSTEM_ACK"
sign_ack_at "$SYSTEM_APP_SUPPORT" "$SYSTEM_REQUEST_ID"

SYSTEM_ATTESTATION_SIGNATURE="$SYSTEM_APP_SUPPORT/device-sync-channel/signatures/attestations/macbook/$SYSTEM_REQUEST_ID.json"
mv "$SYSTEM_ATTESTATION_SIGNATURE" "$SYSTEM_ATTESTATION_SIGNATURE.missing"
run_helper_at "$SYSTEM_APP_SUPPORT" "$SYSTEM_REQUEST_ID" "$SYSTEM_LEDGER_SEQUENCE"
[ "$(plutil -extract phase raw "$SYSTEM_RECEIPT")" = "delivered" ] \
  || fail "system ACK without attestation signature sidecar must remain delivered"
mv "$SYSTEM_ATTESTATION_SIGNATURE.missing" "$SYSTEM_ATTESTATION_SIGNATURE"
pass "missing target attestation signature sidecar is rejected"

plutil -replace digest -string \
  "0000000000000000000000000000000000000000000000000000000000000000" \
  "$SYSTEM_ATTESTATION_SIGNATURE"
run_helper_at "$SYSTEM_APP_SUPPORT" "$SYSTEM_REQUEST_ID" "$SYSTEM_LEDGER_SEQUENCE"
[ "$(plutil -extract phase raw "$SYSTEM_RECEIPT")" = "delivered" ] \
  || fail "system ACK with tampered attestation signature must remain delivered"
pass "tampered target attestation signature sidecar is rejected"

sign_attestation_at "$SYSTEM_APP_SUPPORT" "$SYSTEM_REQUEST_ID"
run_helper_at "$SYSTEM_APP_SUPPORT" "$SYSTEM_REQUEST_ID" "$SYSTEM_LEDGER_SEQUENCE"
[ "$(plutil -extract phase raw "$SYSTEM_RECEIPT")" = "converged" ] \
  || fail "valid five-consumer system ACK must replace the delivered receipt"
[ "$(plutil -extract items.3.repositoryCount raw "$SYSTEM_RECEIPT")" = "1" ] \
  || fail "valid Skillet ACK must preserve repository receipt evidence"
pass "primary helper converges only after all catalog and Skillet bindings match"

THIRD_APP_SUPPORT="$FIXTURE/app-fallback"
THIRD_INTENT="11111111-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
mkdir -p "$THIRD_APP_SUPPORT/device-sync-outbox/pending"
cat >"$THIRD_APP_SUPPORT/device-sync-outbox/pending/$THIRD_INTENT.json" <<EOF
{
  "target": "macbook",
  "action": "version-pull",
  "requestedAt": "2026-07-23T12:00:00Z"
}
EOF

mkdir -p "$FIXTURE/plutil-failure-bin"
cat >"$FIXTURE/plutil-failure-bin/plutil" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -insert|-replace)
    exit 1
    ;;
  *)
    exec /usr/bin/plutil "$@"
    ;;
esac
EOF
chmod +x "$FIXTURE/plutil-failure-bin/plutil"

env \
  PATH="$FIXTURE/plutil-failure-bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  TATWO_APP_SUPPORT="$THIRD_APP_SUPPORT" \
  TATWO_DEVICE_NAME="mini" \
  TATWO_DEVICE_ROLE="primary" \
  TATWO_AUTO_VERSION=0 \
  TATWO_SYNC_HELPER_ONCE=1 \
  MOCK_REQUEST_ID="$REQUEST_ID" \
  MOCK_LEDGER_SEQUENCE="$LEDGER_SEQUENCE" \
  MOCK_SOURCE_DEVICE_ID="$SOURCE_DEVICE_ID" \
  MOCK_TARGET_DEVICE_ID="$TARGET_DEVICE_ID" \
  MOCK_CATALOG_REVISION="$CATALOG_REVISION" \
  bash "$BIN/tatwo-sync-helper.sh"

FALLBACK_RECEIPT="$THIRD_APP_SUPPORT/device-sync-outbox/receipts/$THIRD_INTENT.json"
[ -f "$FALLBACK_RECEIPT" ] || fail "fallback path writes a receipt"
grep -Eq '"target"[[:space:]]*:[[:space:]]*"macbook"' "$FALLBACK_RECEIPT" \
  || fail "fallback receipt preserves target"
grep -Eq '"action"[[:space:]]*:[[:space:]]*"version-pull"' "$FALLBACK_RECEIPT" \
  || fail "fallback receipt preserves action"
grep -Eq '"requestedAt"[[:space:]]*:[[:space:]]*"2026-07-23T12:00:00Z"' "$FALLBACK_RECEIPT" \
  || fail "fallback receipt preserves requestedAt"
pass "fallback receipt remains decodable by the App"

SECOND_APP_SUPPORT="$FIXTURE/app-secondary"
SECOND_INTENT="FFFFFFFF-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
mkdir -p "$SECOND_APP_SUPPORT/device-sync-outbox/pending"
cat >"$SECOND_APP_SUPPORT/device-sync-outbox/pending/$SECOND_INTENT.json" <<EOF
{
  "target": "macbook",
  "action": "version-pull",
  "requestedAt": "2026-07-23T12:00:00Z"
}
EOF

env \
  TATWO_APP_SUPPORT="$SECOND_APP_SUPPORT" \
  TATWO_DEVICE_NAME="mini" \
  TATWO_DEVICE_ROLE="primary" \
  TATWO_AUTO_VERSION=0 \
  TATWO_SYNC_HELPER_ONCE=1 \
  MOCK_ROLE=secondary \
  MOCK_REQUEST_ID="$REQUEST_ID" \
  MOCK_LEDGER_SEQUENCE="$LEDGER_SEQUENCE" \
  MOCK_SOURCE_DEVICE_ID="$SOURCE_DEVICE_ID" \
  MOCK_TARGET_DEVICE_ID="$TARGET_DEVICE_ID" \
  MOCK_CATALOG_REVISION="$CATALOG_REVISION" \
  bash "$BIN/tatwo-sync-helper.sh"

[ -f "$SECOND_APP_SUPPORT/device-sync-outbox/pending/$SECOND_INTENT.json" ] \
  || fail "dynamic secondary must not consume primary outbox despite static primary environment"
[ ! -e "$SECOND_APP_SUPPORT/device-sync-outbox/receipts/$SECOND_INTENT.json" ] \
  || fail "dynamic secondary must not produce a primary outbox receipt"
pass "dynamic role truth overrides stale static primary environment"

printf '%s\n' "tatwo_sync_helper_ack_test=passed"
