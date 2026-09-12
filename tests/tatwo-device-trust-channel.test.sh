#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$ROOT/scripts/tatwo-device-sync.sh"
CLI="${TATWO_SKILLET_CLI:-$ROOT/.build/out/Products/Debug/tatwo-ultrawork}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tatwo-device-trust-channel.XXXXXX")"
REMOTE="$TEST_ROOT/channel.git"
SEED="$TEST_ROOT/seed"
MINI_HOME="$TEST_ROOT/home-mini"
BOOK_HOME="$TEST_ROOT/home-book"
MINI_APP_SUPPORT="$TEST_ROOT/app-mini"
BOOK_APP_SUPPORT="$TEST_ROOT/app-book"
MINI_CHANNEL="$TEST_ROOT/channel-mini"
BOOK_CHANNEL="$TEST_ROOT/channel-book"
LAST_OUTPUT=""
LAST_STATUS=0

cleanup() {
  if [ "${TATWO_KEEP_TEST_ROOT:-0}" = "1" ]; then
    printf 'tatwo_test_root_preserved=%s\n' "$TEST_ROOT" >&2
    return
  fi
  [ ! -d "$TEST_ROOT" ] || rm -r "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  if [ -n "$LAST_OUTPUT" ]; then
    printf '%s\n' '--- command output ---' "$LAST_OUTPUT" '--- end command output ---' >&2
  fi
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

capture() {
  if LAST_OUTPUT="$("$@" 2>&1)"; then
    LAST_STATUS=0
  else
    LAST_STATUS=$?
  fi
}

expect_success() {
  local label="$1"
  shift
  capture "$@"
  [ "$LAST_STATUS" -eq 0 ] \
    || fail "$label (expected success, status=$LAST_STATUS)"
  pass "$label"
}

expect_failure() {
  local label="$1"
  shift
  capture "$@"
  [ "$LAST_STATUS" -ne 0 ] \
    || fail "$label (expected failure)"
  pass "$label"
}

run_sync() {
  local device="$1" home="$2" app_support="$3" channel="$4"
  local trust_cli="$CLI" trust_sha="" trust_cdhash=""
  local signer_pin="$app_support/device-trust/signer-pin.json"
  shift 4
  mkdir -p "$home" "$app_support"
  if [ -f "$signer_pin" ]; then
    trust_cli="$(plutil -extract signerPath raw "$signer_pin")"
    trust_sha="$(plutil -extract sha256 raw "$signer_pin")"
    trust_cdhash="$(plutil -extract codeDirectoryHash raw "$signer_pin")"
  fi
  env \
    HOME="$home" \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_AUTHOR_NAME="Tatwo Device Trust Test" \
    GIT_AUTHOR_EMAIL="device-trust-test@example.invalid" \
    GIT_COMMITTER_NAME="Tatwo Device Trust Test" \
    GIT_COMMITTER_EMAIL="device-trust-test@example.invalid" \
    TATWO_APP_SUPPORT="$app_support" \
    TATWO_REMOTE_APP_SUPPORT="$app_support" \
    TATWO_DEVICE_NAME="$device" \
    TATWO_PRIMARY_SSH_HOST="offline-primary.example.invalid" \
    TATWO_SYNC_REPO="$SEED" \
    TATWO_RELEASE_BRANCH="main" \
    TATWO_CHANNEL_REMOTE="$REMOTE" \
    TATWO_CHANNEL_DIR="$channel" \
    TATWO_OS_ROOT="$TEST_ROOT/os" \
    TATWO_SYNC_CATALOG="$ROOT/config/tatwo-sync-catalog-v1.json" \
    TATWO_HOT_SYNC_STAGING="$app_support/hot-sync-staging" \
    TATWO_HOT_SYNC_MIRROR="$app_support/hot-sync-mirror" \
    TATWO_SKILLET_STORE="$app_support/skillet" \
    TATWO_SKILLS_RUNTIME_ROOT="$app_support/skills-runtime" \
    TATWO_SKILLET_CLI="$CLI" \
    TATWO_DEVICE_TRUST_CLI="$trust_cli" \
    TATWO_DEVICE_TRUST_CLI_SHA256="$trust_sha" \
    TATWO_DEVICE_TRUST_CLI_CDHASH="$trust_cdhash" \
    TATWO_DEVICE_TRUST_TEST_PYTHON="${SYNC_TEST_DEVICE_TRUST_TEST_PYTHON:-python3}" \
    TATWO_DEVICE_TRUST_TEST_KEY_ROOT="${SYNC_TEST_DEVICE_TRUST_TEST_KEY_ROOT:-$app_support/device-trust-test-keys}" \
    TMPDIR="${SYNC_TEST_TMPDIR:-${TMPDIR:-/tmp}}" \
    TATWO_TEST_MODE=1 \
    bash "$SYNC" "$@"
}

install_test_signer_pin() {
  local app_support="$1"
  local signer_root="$app_support/device-trust/signer"
  local signer="$signer_root/tatwo-device-trust-signer-v1"
  local pin="$app_support/device-trust/signer-pin.json"
  local sha cdhash
  mkdir -p "$signer_root"
  cp "$CLI" "$signer"
  chmod 500 "$signer"
  sha="$(shasum -a 256 "$signer" | awk '{print $1}')"
  if /usr/bin/codesign --verify --strict "$signer" >/dev/null 2>&1; then
    cdhash="$(
      /usr/bin/codesign -dv --verbose=4 "$signer" 2>&1 \
        | awk -F= '/^CDHash=/ {print tolower($2); exit}'
    )"
  else
    cdhash="test-sha256-$sha"
  fi
  cat >"$pin" <<EOF
{
  "schema": "TatwoDeviceTrustSignerPinV1",
  "signerPath": "$signer",
  "sha256": "$sha",
  "codeDirectoryHash": "$cdhash",
  "sourceMode": "test-fixture"
}
EOF
  chmod 600 "$pin"
}

[ -x "$CLI" ] || fail "Tatwo CLI is unavailable: $CLI"
bash -n "$SYNC" || fail "device sync script syntax is invalid"

git init --bare -q "$REMOTE"
git init -q -b main "$SEED"
git -C "$SEED" config user.name "Tatwo Device Trust Test"
git -C "$SEED" config user.email "device-trust-test@example.invalid"
printf '%s\n' "device trust channel seed" >"$SEED/README.md"
git -C "$SEED" add README.md
git -C "$SEED" commit -q -m "seed"
git -C "$SEED" remote add origin "$REMOTE"
git -C "$SEED" push -q origin main
git --git-dir="$REMOTE" symbolic-ref HEAD refs/heads/main
mkdir -p "$TEST_ROOT/os"
printf '%s\n' '# os' >"$TEST_ROOT/os/os.md"
printf '%s\n' '# issue' >"$TEST_ROOT/os/issue.md"
printf '%s\n' '# todo' >"$TEST_ROOT/os/TODO.md"

UNSAFE_KEY_ROOT="/tmp/tatwo2-fixture/.tatwo-device-trust-test-key-root-$$"
SYNC_TEST_TMPDIR="/"
SYNC_TEST_DEVICE_TRUST_TEST_KEY_ROOT="$UNSAFE_KEY_ROOT"
expect_failure \
  "TMPDIR cannot widen device-trust test storage authorization" \
  run_sync unsafe "$TEST_ROOT/home-unsafe" "$TEST_ROOT/app-unsafe" \
    "$TEST_ROOT/channel-unsafe" \
    register --role secondary --name unsafe --host unsafe.invalid
[ ! -e "$UNSAFE_KEY_ROOT" ] \
  || fail "unauthorized device-trust test key root was created"
unset SYNC_TEST_TMPDIR
unset SYNC_TEST_DEVICE_TRUST_TEST_KEY_ROOT
pass "device-trust test storage remains confined to known temporary roots"

UNSIGNED_TRUST_CLI="$TEST_ROOT/unsigned-device-trust-cli"
cat >"$UNSIGNED_TRUST_CLI" <<EOF
#!/usr/bin/env bash
exec "$CLI" "\$@"
EOF
chmod +x "$UNSIGNED_TRUST_CLI"
SYNC_TEST_DEVICE_TRUST_CLI="$UNSIGNED_TRUST_CLI"
SYNC_TEST_DEVICE_TRUST_TEST_PYTHON=/bin/true
expect_failure \
  "/bin/true cannot authorize the device-trust test lane" \
  run_sync nonfunctional-python "$TEST_ROOT/home-nonfunctional-python" \
    "$TEST_ROOT/app-nonfunctional-python" \
    "$TEST_ROOT/channel-nonfunctional-python" \
    register --role secondary --name nonfunctional-python \
      --host nonfunctional-python.invalid
[ ! -e "$TEST_ROOT/app-nonfunctional-python/device-trust/identity.json" ] \
  || fail "nonfunctional test Python created a device identity"
unset SYNC_TEST_DEVICE_TRUST_CLI
unset SYNC_TEST_DEVICE_TRUST_TEST_PYTHON
pass "device sync requires a functional Python interpreter for test trust"

TOKEN_ECHO_TEST_PYTHON="$TEST_ROOT/token-echo-test-python"
cat >"$TOKEN_ECHO_TEST_PYTHON" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'tatwo-device-trust-test-python-ok'
exit 0
EOF
chmod +x "$TOKEN_ECHO_TEST_PYTHON"
SYNC_TEST_DEVICE_TRUST_CLI="$UNSIGNED_TRUST_CLI"
SYNC_TEST_DEVICE_TRUST_TEST_PYTHON="$TOKEN_ECHO_TEST_PYTHON"
expect_failure \
  "fixed-token echo script cannot authorize the device-trust test lane" \
  run_sync token-echo-python "$TEST_ROOT/home-token-echo-python" \
    "$TEST_ROOT/app-token-echo-python" \
    "$TEST_ROOT/channel-token-echo-python" \
    register --role secondary --name token-echo-python \
      --host token-echo-python.invalid
[ ! -e "$TEST_ROOT/app-token-echo-python/device-trust/identity.json" ] \
  || fail "fixed-token echo script created a device identity"
unset SYNC_TEST_DEVICE_TRUST_CLI
unset SYNC_TEST_DEVICE_TRUST_TEST_PYTHON
pass "device sync test trust requires a challenge-bound Python response"

expect_success \
  "mini registers generation-one Ed25519 identity" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  register --role secondary --name mini --host mini.invalid
expect_success \
  "book registers generation-one Ed25519 identity" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  register --role secondary --name book --host book.invalid
expect_success \
  "mini bootstraps primary authority" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  set-primary --name mini
expect_success \
  "mini transfers primary authority to book" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  set-primary --name book --expected-epoch 1

expect_success \
  "book explicitly pins mini before rotation" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action version-pull
pre_rotation_request_id="$(
  printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1
)"
[ -n "$pre_rotation_request_id" ] || fail "pre-rotation request id is missing"
old_pin="$TEST_ROOT/mini-generation-one.json"
cp "$BOOK_APP_SUPPORT/device-trust/peers/mini.json" "$old_pin"
old_key_id="$(plutil -extract keyID raw "$old_pin")"
[ "$(plutil -extract keyGeneration raw "$old_pin")" = "1" ] \
  || fail "book did not pin mini generation one"
pass "peer pin captures mini generation one before rotation"

expect_success \
  "mini publishes an old-key-authorized rotation receipt" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  trust-rotate --rotated-at "2026-07-25T21:00:00Z"
printf '%s\n' "$LAST_OUTPUT" | grep -q 'DEVICE_TRUST_KEY_GENERATION=2' \
  || fail "rotation did not advance to generation two"
rotation_receipt="$MINI_CHANNEL/device-trust/rotations/mini/2.json"
[ -f "$rotation_receipt" ] || fail "rotation receipt was not published"
new_key_id="$(plutil -extract keyID raw "$MINI_CHANNEL/devices/mini.json")"
[ "$new_key_id" != "$old_key_id" ] \
  || fail "rotation reused the previous key id"
pass "rotation changes key id and advances exactly one generation"

expect_success \
  "book verifies rotation and refreshes its mini pin before publishing" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action version-pull
rotated_request_id="$(
  printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1
)"
[ -n "$rotated_request_id" ] || fail "post-rotation request id is missing"
book_mini_pin="$BOOK_APP_SUPPORT/device-trust/peers/mini.json"
[ "$(plutil -extract keyGeneration raw "$book_mini_pin")" = "2" ] \
  || fail "verified rotation did not update the peer pin"
[ "$(plutil -extract keyID raw "$book_mini_pin")" = "$new_key_id" ] \
  || fail "updated peer pin does not match the rotated registry"
acceptance="$BOOK_APP_SUPPORT/device-trust/accepted-rotations/mini/2.json"
[ -f "$acceptance" ] || fail "rotation acceptance receipt is missing"
[ "$(plutil -extract rotationReceiptDigest raw "$acceptance")" \
  = "$(shasum -a 256 "$BOOK_CHANNEL/device-trust/rotations/mini/2.json" | awk '{print $1}')" ] \
  || fail "rotation acceptance receipt does not bind the published receipt"
pass "verified consecutive rotation updates the peer pin with a local receipt"

expect_failure \
  "an already-consumed rotation receipt cannot be replayed against generation two" \
  env \
    TATWO_TEST_MODE=1 \
    TATWO_DEVICE_TRUST_TEST_KEY_ROOT="$BOOK_APP_SUPPORT/device-trust-test-keys" \
    "$CLI" device-trust verify-rotation \
      --old-registry "$book_mini_pin" \
      --receipt "$BOOK_CHANNEL/device-trust/rotations/mini/2.json" \
      --json

expect_success \
  "mini processes requests using its rotated signing identity" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
expect_success \
  "book refreshes the channel containing the rotated ACK" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" role-status

mini_device_id="$(plutil -extract deviceID raw "$BOOK_CHANNEL/devices/mini.json")"
book_device_id="$(plutil -extract deviceID raw "$MINI_CHANNEL/devices/book.json")"
ack="$BOOK_CHANNEL/acks/$rotated_request_id.json"
ack_signature="$BOOK_CHANNEL/signatures/acks/$rotated_request_id.json"
request="$MINI_CHANNEL/requests/mini/$rotated_request_id.json"
request_signature="$MINI_CHANNEL/signatures/requests/mini/$rotated_request_id.json"
[ -f "$ack" ] && [ -f "$ack_signature" ] \
  || fail "rotated ACK or signature sidecar is missing"

expect_success \
  "book verifies a real ACK signed by mini generation two" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  trust-verify-artifact \
    --device mini \
    --device-id "$mini_device_id" \
    --purpose sync-ack \
    --input "$ack" \
    --signature "$ack_signature"

install_test_signer_pin "$BOOK_APP_SUPPORT"
book_signer_pin="$BOOK_APP_SUPPORT/device-trust/signer-pin.json"
book_signer="$BOOK_APP_SUPPORT/device-trust/signer/tatwo-device-trust-signer-v1"
book_signer_pin_backup="$TEST_ROOT/book-signer-pin.valid.json"
book_signer_backup="$TEST_ROOT/book-signer.valid"
cp -p "$book_signer_pin" "$book_signer_pin_backup"
cp -p "$book_signer" "$book_signer_backup"
expect_success \
  "authoritative signer pin accepts its exact SHA-256 and cdhash" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  trust-verify-artifact \
    --device mini \
    --device-id "$mini_device_id" \
    --purpose sync-ack \
    --input "$ack" \
    --signature "$ack_signature"

out_of_tree_signer="$TEST_ROOT/out-of-tree-device-trust-signer"
cp -p "$book_signer" "$out_of_tree_signer"
out_of_tree_sha="$(shasum -a 256 "$out_of_tree_signer" | awk '{print $1}')"
if /usr/bin/codesign --verify --strict "$out_of_tree_signer" >/dev/null 2>&1; then
  out_of_tree_cdhash="$(
    /usr/bin/codesign -dv --verbose=4 "$out_of_tree_signer" 2>&1 \
      | awk -F= '/^CDHash=/ {print tolower($2); exit}'
  )"
else
  out_of_tree_cdhash="test-sha256-$out_of_tree_sha"
fi
plutil -replace signerPath -string "$out_of_tree_signer" "$book_signer_pin"
plutil -replace sha256 -string "$out_of_tree_sha" "$book_signer_pin"
plutil -replace codeDirectoryHash -string "$out_of_tree_cdhash" "$book_signer_pin"
expect_failure \
  "signer pin cannot redirect trust execution outside the canonical anchor" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  trust-verify-artifact \
    --device mini \
    --device-id "$mini_device_id" \
    --purpose sync-ack \
    --input "$ack" \
    --signature "$ack_signature"
cp -p "$book_signer_pin_backup" "$book_signer_pin"
pass "sync independently pins signerPath to the canonical immutable anchor"

plutil -replace sha256 -string \
  "0000000000000000000000000000000000000000000000000000000000000000" \
  "$book_signer_pin"
expect_failure \
  "tampered authoritative signer SHA-256 fails closed" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  trust-verify-artifact \
    --device mini \
    --device-id "$mini_device_id" \
    --purpose sync-ack \
    --input "$ack" \
    --signature "$ack_signature"
cp -p "$book_signer_pin_backup" "$book_signer_pin"

plutil -replace codeDirectoryHash -string \
  "test-sha256-0000000000000000000000000000000000000000000000000000000000000000" \
  "$book_signer_pin"
expect_failure \
  "tampered authoritative signer cdhash fails closed" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  trust-verify-artifact \
    --device mini \
    --device-id "$mini_device_id" \
    --purpose sync-ack \
    --input "$ack" \
    --signature "$ack_signature"
cp -p "$book_signer_pin_backup" "$book_signer_pin"

chmod 700 "$book_signer"
printf '%s\n' '# signer-byte-tamper' >>"$book_signer"
chmod 500 "$book_signer"
expect_failure \
  "signer bytes changed after pinning fail closed" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  trust-verify-artifact \
    --device mini \
    --device-id "$mini_device_id" \
    --purpose sync-ack \
    --input "$ack" \
    --signature "$ack_signature"
chmod 700 "$book_signer"
cp -p "$book_signer_backup" "$book_signer"
chmod 500 "$book_signer"
expect_success \
  "restored signer and pin return the trust route to service" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  trust-verify-artifact \
    --device mini \
    --device-id "$mini_device_id" \
    --purpose sync-ack \
    --input "$ack" \
    --signature "$ack_signature"

tampered_ack="$BOOK_CHANNEL/acks/$rotated_request_id.tampered.json"
cp "$ack" "$tampered_ack"
plutil -replace message -string "tampered after signing" "$tampered_ack"
expect_failure \
  "ACK bytes changed after signing fail closed" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  trust-verify-artifact \
    --device mini \
    --device-id "$mini_device_id" \
    --purpose sync-ack \
    --input "$tampered_ack" \
    --signature "$ack_signature"
mv "$tampered_ack" "$TEST_ROOT/tampered-ack-evidence.json"
pass "tampered ACK is rejected by the real Ed25519 verifier"

expect_failure \
  "missing ACK signature sidecar fails closed" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  trust-verify-artifact \
    --device mini \
    --device-id "$mini_device_id" \
    --purpose sync-ack \
    --input "$ack" \
    --signature "$BOOK_CHANNEL/signatures/acks/missing.json"

tampered_request="$MINI_CHANNEL/requests/mini/$rotated_request_id.tampered.json"
cp "$request" "$tampered_request"
plutil -replace action -string system-pull "$tampered_request"
expect_failure \
  "request bytes changed after signing fail closed" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  trust-verify-artifact \
    --device book \
    --device-id "$book_device_id" \
    --purpose sync-request \
    --input "$tampered_request" \
    --signature "$request_signature"
mv "$tampered_request" "$TEST_ROOT/tampered-request-evidence.json"
pass "tampered request is rejected by the real Ed25519 verifier"

OBSERVER_APP_SUPPORT="$TEST_ROOT/app-observer"
expect_failure \
  "an unknown observer without a peer pin cannot trust a valid signature" \
  run_sync observer "$TEST_ROOT/home-observer" "$OBSERVER_APP_SUPPORT" \
  "$BOOK_CHANNEL" \
  trust-verify-artifact \
    --device mini \
    --device-id "$mini_device_id" \
    --purpose sync-ack \
    --input "$ack" \
    --signature "$ack_signature"

REVOKED_CHANNEL="$TEST_ROOT/channel-revoked"
cp -R "$BOOK_CHANNEL" "$REVOKED_CHANNEL"
plutil -replace keyStatus -string revoked "$REVOKED_CHANNEL/devices/mini.json"
expect_failure \
  "a revoked registry identity cannot verify an otherwise valid ACK" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$REVOKED_CHANNEL" \
  trust-verify-artifact \
    --device mini \
    --device-id "$mini_device_id" \
    --purpose sync-ack \
    --input "$REVOKED_CHANNEL/acks/$rotated_request_id.json" \
    --signature "$REVOKED_CHANNEL/signatures/acks/$rotated_request_id.json"

STALE_CHANNEL="$TEST_ROOT/channel-stale-generation"
cp -R "$BOOK_CHANNEL" "$STALE_CHANNEL"
plutil -replace keyGeneration -integer 3 "$STALE_CHANNEL/devices/mini.json"
expect_failure \
  "a generation jump without a valid consecutive rotation receipt fails closed" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$STALE_CHANNEL" \
  trust-verify-artifact \
    --device mini \
    --device-id "$mini_device_id" \
    --purpose sync-ack \
    --input "$STALE_CHANNEL/acks/$rotated_request_id.json" \
    --signature "$STALE_CHANNEL/signatures/acks/$rotated_request_id.json"

printf '%s\n' "tatwo_device_trust_channel_test=passed"
