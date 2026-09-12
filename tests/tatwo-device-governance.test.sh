#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$ROOT/scripts/tatwo-device-sync.sh"
CLI="${TATWO_SKILLET_CLI:-$ROOT/.build/out/Products/Debug/tatwo-ultrawork}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tatwo-device-governance.XXXXXX")"
NATIVE_TEMP_ROOT="$(getconf DARWIN_USER_TEMP_DIR)"
TRUST_TEST_ROOT="$(mktemp -d "${NATIVE_TEMP_ROOT%/}/tatwo-device-governance-keys.XXXXXX")"
REMOTE="$TEST_ROOT/channel.git"
SEED_REPO="$TEST_ROOT/seed"
LAST_OUTPUT=""
LAST_STATUS=0

cleanup() {
  if [ "${TATWO_KEEP_TEST_ROOT:-0}" = "1" ]; then
    printf 'tatwo_test_root_preserved=%s\n' "$TEST_ROOT" >&2
    printf 'tatwo_trust_test_root_preserved=%s\n' "$TRUST_TEST_ROOT" >&2
    return
  fi
  [ ! -e "$TEST_ROOT" ] || rm -r "$TEST_ROOT"
  [ ! -e "$TRUST_TEST_ROOT" ] || rm -r "$TRUST_TEST_ROOT"
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
  [ "$LAST_STATUS" -eq 0 ] || fail "$label (expected success, status=$LAST_STATUS)"
  pass "$label"
}

expect_failure() {
  local label="$1"
  shift
  capture "$@"
  [ "$LAST_STATUS" -ne 0 ] || fail "$label (expected failure)"
  pass "$label"
}

run_sync() {
  local device="$1"
  shift
  local home="$TEST_ROOT/home-$device"
  local app_support="$TEST_ROOT/app-$device"
  local channel="$TEST_ROOT/channel-$device"
  mkdir -p "$home" "$app_support"
  env \
    HOME="$home" \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_AUTHOR_NAME="Tatwo Device Governance Test" \
    GIT_AUTHOR_EMAIL="device-governance@example.invalid" \
    GIT_COMMITTER_NAME="Tatwo Device Governance Test" \
    GIT_COMMITTER_EMAIL="device-governance@example.invalid" \
    TATWO_APP_SUPPORT="$app_support" \
    TATWO_DEVICE_NAME="$device" \
    TATWO_PRIMARY_SSH_HOST="$device.invalid" \
    TATWO_SYNC_REPO="$SEED_REPO" \
    TATWO_RELEASE_BRANCH="main" \
    TATWO_CHANNEL_REMOTE="$REMOTE" \
    TATWO_CHANNEL_DIR="$channel" \
    TATWO_SYNC_CATALOG="$ROOT/config/tatwo-sync-catalog-v1.json" \
    TATWO_SKILLET_CLI="$CLI" \
    TATWO_DEVICE_TRUST_CLI="$CLI" \
    TATWO_DEVICE_TRUST_TEST_KEY_ROOT="$TRUST_TEST_ROOT/$device" \
    TATWO_CHANNEL_LOCK_TIMEOUT_SECONDS="${SYNC_TEST_LOCK_TIMEOUT:-30}" \
    TATWO_TEST_MODE=1 \
    TATWO_TEST_CHANNEL_LOCK_HOLD_SECONDS="${SYNC_TEST_LOCK_HOLD:-0}" \
    bash "$SYNC" "$@"
}

[ -x "$CLI" ] || fail "Tatwo CLI is unavailable: $CLI"
bash -n "$SYNC" || fail "device sync script syntax is invalid"

git init --bare -q "$REMOTE"
git init -q -b main "$SEED_REPO"
git -C "$SEED_REPO" config user.name "Tatwo Device Governance Test"
git -C "$SEED_REPO" config user.email "device-governance@example.invalid"
printf '%s\n' "device governance fixture" >"$SEED_REPO/README.md"
git -C "$SEED_REPO" add README.md
git -C "$SEED_REPO" commit -q -m "seed"
git -C "$SEED_REPO" remote add origin "$REMOTE"
git -C "$SEED_REPO" push -q origin main
git --git-dir="$REMOTE" symbolic-ref HEAD refs/heads/main

expect_success \
  "devices-list succeeds before the registry directory exists" \
  run_sync observer devices-list
grep -Fq "尚無登記設備" <<<"$LAST_OUTPUT" \
  || fail "devices-list omitted the empty-registry message"
pass "devices-list reports an absent registry without failing"

mkdir -p "$TEST_ROOT/channel-observer/devices"
expect_success \
  "devices-list succeeds when the registry directory is empty" \
  run_sync observer devices-list
grep -Fq "尚無登記設備" <<<"$LAST_OUTPUT" \
  || fail "devices-list omitted the empty-directory message"
pass "devices-list reports an empty registry directory without failing"

expect_success \
  "bootstrap registry accepts mini before authority exists" \
  run_sync mini register --role secondary --name mini --host mini.invalid
expect_success \
  "bootstrap registry accepts book before authority exists" \
  run_sync book register --role secondary --name book --host book.invalid
expect_success \
  "registered mini bootstraps authority" \
  run_sync mini set-primary --name mini

expect_success \
  "devices-list succeeds when registered devices exist" \
  run_sync mini devices-list
grep -Fq "mini • primary" <<<"$LAST_OUTPUT" \
  || fail "devices-list omitted the current primary"
grep -Fq "book • secondary" <<<"$LAST_OUTPUT" \
  || fail "devices-list omitted a registered secondary"
pass "devices-list reports registered primary and secondary devices"

expect_failure \
  "non-primary cannot create a pairing seed" \
  run_sync book pairing-create

expect_success \
  "current primary creates an authority-bound pairing seed" \
  run_sync mini pairing-create
STALE_SEED="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^PAIRING_SEED=//p' | tail -1)"
[ -n "$STALE_SEED" ] || fail "pairing-create did not return a seed"
PAIRING_FILE="$TEST_ROOT/channel-mini/pairing/$STALE_SEED.json"
[ "$(plutil -extract createdBy raw "$PAIRING_FILE")" = "mini" ] \
  || fail "pairing seed does not name its creator"
[ "$(plutil -extract authorityPrimary raw "$PAIRING_FILE")" = "mini" ] \
  || fail "pairing seed is not bound to the current primary"
[ "$(plutil -extract authorityEpoch raw "$PAIRING_FILE")" = "1" ] \
  || fail "pairing seed is not bound to authority epoch 1"
pass "pairing seed records authority primary and epoch"

expect_success \
  "current primary transfers authority to registered book" \
  run_sync mini set-primary --name book --expected-epoch 1

expect_failure \
  "pairing seed from an old authority epoch is rejected" \
  run_sync third register --role secondary --name third --host third.invalid \
    --pairing-seed "$STALE_SEED"
[ ! -f "$TEST_ROOT/channel-third/devices/third.json" ] \
  || fail "stale pairing seed registered a device"

expect_failure \
  "secondary cannot claim primary role through registration" \
  run_sync mini register --role primary --name mini --host mini.invalid

expect_failure \
  "authority cannot transfer to an unregistered alias" \
  run_sync book set-primary --name ghost --expected-epoch 2

expect_success \
  "new current primary creates a fresh pairing seed" \
  run_sync book pairing-create
FRESH_SEED="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^PAIRING_SEED=//p' | tail -1)"
[ -n "$FRESH_SEED" ] || fail "fresh pairing seed is missing"

MINI_DEVICE_ID_BEFORE="$(plutil -extract deviceId raw "$TEST_ROOT/channel-book/devices/mini.json")"
expect_failure \
  "pairing cannot overwrite an enrolled device alias" \
  run_sync third register --role secondary --name mini --host third.invalid \
    --pairing-seed "$FRESH_SEED"
MINI_DEVICE_ID_AFTER="$(plutil -extract deviceId raw "$TEST_ROOT/channel-third/devices/mini.json")"
[ "$MINI_DEVICE_ID_AFTER" = "$MINI_DEVICE_ID_BEFORE" ] \
  || fail "failed alias overwrite changed the enrolled device identity"
[ -z "$(plutil -extract consumedAt raw "$TEST_ROOT/channel-third/pairing/$FRESH_SEED.json")" ] \
  || fail "failed alias overwrite consumed the pairing seed"
pass "failed alias overwrite preserves registry and pairing token"

expect_success \
  "fresh authority-bound seed enrolls a new secondary" \
  run_sync third register --role secondary --name third --host third.invalid \
    --pairing-seed "$FRESH_SEED"
[ -n "$(plutil -extract consumedAt raw "$TEST_ROOT/channel-third/pairing/$FRESH_SEED.json")" ] \
  || fail "successful registration did not consume the pairing seed"

expect_failure \
  "consumed pairing seed cannot be reused" \
  run_sync fourth register --role secondary --name fourth --host fourth.invalid \
    --pairing-seed "$FRESH_SEED"

expect_success \
  "current primary creates a seed for duplicate-identity rejection" \
  run_sync book pairing-create
DUPLICATE_SEED="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^PAIRING_SEED=//p' | tail -1)"
[ -n "$DUPLICATE_SEED" ] || fail "duplicate-identity seed is missing"
expect_failure \
  "one device identity cannot register under a second alias" \
  run_sync third register --role secondary --name third-alias --host third.invalid \
    --pairing-seed "$DUPLICATE_SEED"
[ -z "$(plutil -extract consumedAt raw "$TEST_ROOT/channel-third/pairing/$DUPLICATE_SEED.json")" ] \
  || fail "duplicate-identity rejection consumed the pairing seed"

expect_success \
  "authority can transfer to the newly enrolled device" \
  run_sync book set-primary --name third --expected-epoch 2

SYNC_TEST_LOCK_HOLD=2 run_sync third role-status \
  >"$TEST_ROOT/lock-holder.log" 2>&1 &
LOCK_HOLDER_PID=$!
lock_wait_attempt=0
while [ ! -d "$TEST_ROOT/app-third/device-sync-state/channel-operation.lock" ]; do
  lock_wait_attempt=$((lock_wait_attempt + 1))
  [ "$lock_wait_attempt" -lt 100 ] \
    || { kill "$LOCK_HOLDER_PID" 2>/dev/null || true; fail "channel lock holder did not acquire the lock"; }
  sleep 0.02
done
SYNC_TEST_LOCK_TIMEOUT=0
expect_failure \
  "a second local channel writer fails closed while the channel lock is held" \
  run_sync third pairing-create
unset SYNC_TEST_LOCK_TIMEOUT
wait "$LOCK_HOLDER_PID" || fail "channel lock holder failed"
unset SYNC_TEST_LOCK_HOLD
pass "local channel operations are serialized across processes"

printf '%s\n' "tatwo_device_governance_test=passed"
