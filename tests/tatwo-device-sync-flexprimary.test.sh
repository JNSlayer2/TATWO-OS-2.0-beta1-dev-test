#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$ROOT/scripts/tatwo-device-sync.sh"
SKILLS_PROJECTION_HELPER="$ROOT/scripts/tatwo-skills-consumer-projection.py"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tatwo-device-sync-flexprimary.XXXXXX")"
REMOTE="$TEST_ROOT/channel.git"
SEED="$TEST_ROOT/seed"
MINI_HOME="$TEST_ROOT/home-mini"
BOOK_HOME="$TEST_ROOT/home-book"
MINI_APP_SUPPORT="$TEST_ROOT/app-support-mini"
BOOK_APP_SUPPORT="$TEST_ROOT/app-support-book"
MINI_CHANNEL="$TEST_ROOT/channel-mini"
BOOK_CHANNEL="$TEST_ROOT/channel-book"
SKILLET_CLI="${TATWO_SKILLET_CLI:-}"
SWIFTPM_SCRATCH_PATH="${TATWO_SWIFTPM_SCRATCH_PATH:-$ROOT/.build}"
LAST_OUTPUT=""
LAST_STATUS=0

cleanup() {
  if [ "${TATWO_KEEP_TEST_ROOT:-0}" = "1" ]; then
    printf 'tatwo_test_root_preserved=%s\n' "$TEST_ROOT" >&2
    return
  fi
  if [ -d "$TEST_ROOT" ]; then
    rm -r "$TEST_ROOT"
  fi
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  if [ -n "$LAST_OUTPUT" ]; then
    printf '%s\n' '--- command output ---' >&2
    printf '%s\n' "$LAST_OUTPUT" >&2
    printf '%s\n' '--- end command output ---' >&2
  fi
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

normalize_path() {
  python3 - "$1" <<'PY'
import os
import sys

print(os.path.normpath(sys.argv[1]))
PY
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

assert_output() {
  local label="$1"
  local pattern="$2"
  printf '%s\n' "$LAST_OUTPUT" | grep -Eq "$pattern" \
    || fail "$label (missing pattern: $pattern)"
  pass "$label"
}

assert_no_terminal_ack() {
  local ack="$1" label="$2" phase
  [ -f "$ack" ] || return 0
  phase="$(plutil -extract phase raw "$ack" 2>/dev/null || true)"
  case "$phase" in
    accepted|transferring|merging|validating|activating|verified) return 0;;
    converged|failed|diverged)
      fail "$label (unexpected terminal phase=$phase)"
      ;;
    *)
      fail "$label (unreadable phase=${phase:-missing})"
      ;;
  esac
}

assert_channel_clean() {
  local channel="$1" label="$2" dirty
  dirty="$(git -C "$channel" status --porcelain=v1 --untracked-files=all)"
  [ -z "$dirty" ] || {
    LAST_OUTPUT="$dirty"
    fail "$label"
  }
  pass "$label"
}

assert_source_provenance_equal() {
  local label="$1" left="$2" right="$3" key left_value right_value
  for key in \
    sourceMode \
    inventoryDigest \
    fallbackAuthorizationID \
    fallbackAuthorizationPath \
    fallbackAuthorizationDigest
  do
    left_value="$(plutil -extract "$key" raw "$left" 2>/dev/null || true)"
    right_value="$(plutil -extract "$key" raw "$right" 2>/dev/null || true)"
    [ "$left_value" = "$right_value" ] || {
      LAST_OUTPUT="$key: $left_value != $right_value"
      fail "$label"
    }
  done
  pass "$label"
}

commit_channel_paths() {
  local channel="$1" message="$2"
  shift 2
  git -C "$channel" add "$@"
  git -C "$channel" \
    -c user.name="Tatwo Device Sync Test" \
    -c user.email="device-sync-test@example.invalid" \
    commit -q -m "$message"
  git -C "$channel" push -q origin device-sync-channel
}

channel_commit_count() {
  git --git-dir="$REMOTE" rev-list --count refs/heads/device-sync-channel
}

sign_test_artifact() {
  local app_support="$1" purpose="$2" input="$3" signature="$4"
  env \
    TATWO_TEST_MODE=1 \
    TATWO_DEVICE_TRUST_TEST_KEY_ROOT="$app_support/device-trust-test-keys" \
    "$SKILLET_CLI" device-trust sign \
      --purpose "$purpose" \
      --registry "$app_support/device-trust/identity.json" \
      --input "$input" \
      --signature-out "$signature" \
      --json >/dev/null
}

bootstrap_skills_consumer_projection() {
  local home="$1" app_support="$2" source_root="$3"
  local consumer_root="$app_support/skills-consumer"
  local receipt="$app_support/device-sync-state/skills-consumer-projection-receipts/bootstrap.json"
  mkdir -p "$home/.codex" "$home/.claude" "$(dirname "$receipt")"
  python3 "$SKILLS_PROJECTION_HELPER" bootstrap \
    --source-root "$source_root" \
    --consumer-root "$consumer_root" \
    --codex-skills-link "$home/.codex/skills" \
    --claude-skills-link "$home/.claude/skills" \
    --receipt "$receipt" >/dev/null
}

run_sync() {
  local device="$1"
  local home="$2"
  local app_support="$3"
  local channel_dir="$4"
  local -a runtime_root_env=("TATWO_TEST_LEGACY_RUNTIME_ROOT_OMITTED=1")
  local -a skills_projection_env=(
    "TATWO_SKILLS_CONSUMER_ROOT=${SYNC_TEST_SKILLS_CONSUMER_ROOT:-$app_support/skills-consumer}"
    "TATWO_CODEX_SKILLS_LINK=${SYNC_TEST_CODEX_SKILLS_LINK:-$home/.codex/skills}"
    "TATWO_CLAUDE_SKILLS_LINK=${SYNC_TEST_CLAUDE_SKILLS_LINK:-$home/.claude/skills}"
    "TATWO_SKILLS_CONSUMER_PROJECTION_SCRIPT=${SYNC_TEST_SKILLS_CONSUMER_PROJECTION_SCRIPT:-$SKILLS_PROJECTION_HELPER}"
  )
  shift 4

  mkdir -p "$home" "$app_support"
  if [ "${SYNC_TEST_OMIT_SKILLET_RUNTIME_ROOT:-0}" != "1" ]; then
    runtime_root_env=(
      "TATWO_SKILLS_RUNTIME_ROOT=${SYNC_TEST_SKILLET_RUNTIME_ROOT:-$app_support/skills-runtime}"
    )
  fi
  if [ "${SYNC_TEST_OMIT_SKILLS_CONSUMER_ENROLLMENT:-0}" = "1" ]; then
    skills_projection_env=(
      "TATWO_TEST_LEGACY_SKILLS_CONSUMER_ENROLLMENT_OMITTED=1"
    )
  fi
  env \
    HOME="$home" \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_AUTHOR_NAME="Tatwo Device Sync Test" \
    GIT_AUTHOR_EMAIL="device-sync-test@example.invalid" \
    GIT_COMMITTER_NAME="Tatwo Device Sync Test" \
    GIT_COMMITTER_EMAIL="device-sync-test@example.invalid" \
    TATWO_APP_SUPPORT="$app_support" \
    TATWO_REMOTE_APP_SUPPORT="$app_support" \
    TATWO_DEVICE_NAME="$device" \
    TATWO_PRIMARY_SSH_HOST="offline-primary.example.invalid" \
    TATWO_SYNC_REPO="$SEED" \
    TATWO_RELEASE_BRANCH="main" \
    TATWO_CHANNEL_REMOTE="${SYNC_TEST_CHANNEL_REMOTE:-$REMOTE}" \
    TATWO_CHANNEL_DIR="$channel_dir" \
    TATWO_OS_ROOT="$TEST_ROOT/os-canonical" \
    TATWO_SYNC_CATALOG="$ROOT/config/tatwo-sync-catalog-v1.json" \
    TATWO_HOT_SYNC_STAGING="${SYNC_TEST_HOT_SYNC_STAGING:-$app_support/hot-sync-staging}" \
    TATWO_HOT_SYNC_MIRROR="${SYNC_TEST_HOT_SYNC_MIRROR:-$app_support/hot-sync-mirror}" \
    TATWO_SKILLET_STORE="${SYNC_TEST_SKILLET_STORE:-$app_support/skillet}" \
    "${runtime_root_env[@]}" \
    "${skills_projection_env[@]}" \
    TATWO_SKILLET_AUTO_REFRESH="${SYNC_TEST_SKILLET_AUTO_REFRESH:-0}" \
    TATWO_SKILLET_SOURCE_ROOT="${SYNC_TEST_SKILLET_SOURCE_ROOT:-$TEST_ROOT/skills}" \
    TATWO_SKILLET_SOURCE_FALLBACK_ROOT="${SYNC_TEST_SKILLET_SOURCE_FALLBACK_ROOT:-$app_support/skills-runtime}" \
    TATWO_SKILLET_SOURCE_REGISTRY="${SYNC_TEST_SKILLET_SOURCE_REGISTRY:-$ROOT/config/tatwo-skillet-source-registry-v1.json}" \
    TATWO_SKILLET_REFRESH_SCRIPT="${SYNC_TEST_SKILLET_REFRESH_SCRIPT:-$ROOT/scripts/tatwo-skillet-refresh.mjs}" \
    TATWO_PYTHON3="${SYNC_TEST_PYTHON3:-python3}" \
    TATWO_DEVICE_TRUST_TEST_PYTHON="${SYNC_TEST_DEVICE_TRUST_TEST_PYTHON:-python3}" \
    TATWO_SKILLET_CLI="${SYNC_TEST_SKILLET_CLI:-$SKILLET_CLI}" \
    TATWO_DEVICE_TRUST_CLI="${SYNC_TEST_DEVICE_TRUST_CLI:-$SKILLET_CLI}" \
    TATWO_DEVICE_TRUST_TEST_KEY_ROOT="$app_support/device-trust-test-keys" \
    TATWO_TEST_MODE="${SYNC_TEST_MODE:-1}" \
    TATWO_TEST_BEFORE_ACTIVATE_HOOK="${SYNC_TEST_BEFORE_ACTIVATE_HOOK:-}" \
    TATWO_TEST_AFTER_ACTIVATE_HOOK="${SYNC_TEST_AFTER_ACTIVATE_HOOK:-}" \
    TATWO_TEST_BEFORE_SKILLET_ACTIVATE_HOOK="${SYNC_TEST_BEFORE_SKILLET_ACTIVATE_HOOK:-}" \
    TATWO_TEST_AFTER_SKILLET_ACTIVATE_HOOK="${SYNC_TEST_AFTER_SKILLET_ACTIVATE_HOOK:-}" \
    TATWO_TEST_CRASH_AFTER_OS_ACTIVATE="${SYNC_TEST_CRASH_AFTER_OS_ACTIVATE:-0}" \
    TATWO_TEST_CRASH_BEFORE_OLD_MIRROR_MOVE="${SYNC_TEST_CRASH_BEFORE_OLD_MIRROR_MOVE:-0}" \
    TATWO_TEST_CRASH_AFTER_SYSTEM_COMMIT="${SYNC_TEST_CRASH_AFTER_SYSTEM_COMMIT:-0}" \
    TATWO_TEST_CRASH_DURING_ROLLBACK_AFTER_OS="${SYNC_TEST_CRASH_DURING_ROLLBACK_AFTER_OS:-0}" \
    TATWO_TEST_CRASH_DURING_TRANSACTION_PREPARE="${SYNC_TEST_CRASH_DURING_TRANSACTION_PREPARE:-0}" \
    TATWO_TEST_CRASH_AFTER_TRANSACTION_STAGE_CREATE="${SYNC_TEST_CRASH_AFTER_TRANSACTION_STAGE_CREATE:-0}" \
    TATWO_TEST_FAIL_TARGET_ATTESTATION="${SYNC_TEST_FAIL_TARGET_ATTESTATION:-0}" \
    TATWO_TEST_PARTIAL_TARGET_ATTESTATION_WRITE="${SYNC_TEST_PARTIAL_TARGET_ATTESTATION_WRITE:-0}" \
    TATWO_TEST_FAIL_CONSUMER_READBACK="${SYNC_TEST_FAIL_CONSUMER_READBACK:-0}" \
    TATWO_TEST_PARTIAL_CONSUMER_READBACK_WRITE="${SYNC_TEST_PARTIAL_CONSUMER_READBACK_WRITE:-0}" \
    TATWO_TEST_FAIL_SKILLS_CONSUMER_PROJECTION="${SYNC_TEST_FAIL_SKILLS_CONSUMER_PROJECTION:-0}" \
    TATWO_TEST_SHA256_FAIL_PATH="${SYNC_TEST_SHA256_FAIL_PATH:-}" \
    TATWO_TEST_FAIL_PHASE_UPDATE="${SYNC_TEST_FAIL_PHASE_UPDATE:-}" \
    TATWO_TEST_CRASH_AFTER_PROGRESS_PHASE="${SYNC_TEST_CRASH_AFTER_PROGRESS_PHASE:-}" \
    TATWO_TEST_AVAILABLE_BYTES_OVERRIDE="${SYNC_TEST_AVAILABLE_BYTES_OVERRIDE:-}" \
    TATWO_SYNC_RETENTION_MAX_ENTRIES="${SYNC_TEST_RETENTION_MAX_ENTRIES:-128}" \
    TATWO_SYNC_RETENTION_MAX_BYTES="${SYNC_TEST_RETENTION_MAX_BYTES:-2147483648}" \
    TATWO_CHANNEL_LOCK_TIMEOUT_SECONDS="${SYNC_TEST_CHANNEL_LOCK_TIMEOUT_SECONDS:-120}" \
    TATWO_CHANNEL_LOCK_OWNER_GRACE_SECONDS="${SYNC_TEST_CHANNEL_LOCK_OWNER_GRACE_SECONDS:-5}" \
    TATWO_TEST_CHANNEL_LOCK_OWNER_DELAY_SECONDS="${SYNC_TEST_CHANNEL_LOCK_OWNER_DELAY_SECONDS:-0}" \
    TATWO_TEST_CHANNEL_LOCK_HOLD_SECONDS="${SYNC_TEST_CHANNEL_LOCK_HOLD_SECONDS:-0}" \
    bash "$SYNC" "$@"
}

run_sync_without_channel_remote() {
  local device="$1"
  local home="$2"
  local app_support="$3"
  local channel_dir="$4"
  shift 4

  mkdir -p "$home" "$app_support"
  env \
    HOME="$home" \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_AUTHOR_NAME="Tatwo Device Sync Test" \
    GIT_AUTHOR_EMAIL="device-sync-test@example.invalid" \
    GIT_COMMITTER_NAME="Tatwo Device Sync Test" \
    GIT_COMMITTER_EMAIL="device-sync-test@example.invalid" \
    TATWO_APP_SUPPORT="$app_support" \
    TATWO_REMOTE_APP_SUPPORT="$app_support" \
    TATWO_DEVICE_NAME="$device" \
    TATWO_PRIMARY_SSH_HOST="offline-primary.example.invalid" \
    TATWO_SYNC_REPO="$SEED" \
    TATWO_RELEASE_BRANCH="main" \
    TATWO_CHANNEL_DIR="$channel_dir" \
    TATWO_OS_ROOT="$TEST_ROOT/os-canonical" \
    TATWO_SYNC_CATALOG="$ROOT/config/tatwo-sync-catalog-v1.json" \
    TATWO_SKILLET_STORE="$app_support/skillet" \
    TATWO_SKILLS_RUNTIME_ROOT="$app_support/skills-runtime" \
    TATWO_SKILLS_CONSUMER_ROOT="$app_support/skills-consumer" \
    TATWO_CODEX_SKILLS_LINK="$home/.codex/skills" \
    TATWO_CLAUDE_SKILLS_LINK="$home/.claude/skills" \
    TATWO_SKILLS_CONSUMER_PROJECTION_SCRIPT="$SKILLS_PROJECTION_HELPER" \
    TATWO_SKILLET_AUTO_REFRESH=0 \
    TATWO_SKILLET_SOURCE_ROOT="$TEST_ROOT/skills" \
    TATWO_SKILLET_SOURCE_REGISTRY="$ROOT/config/tatwo-skillet-source-registry-v1.json" \
    TATWO_SKILLET_REFRESH_SCRIPT="$ROOT/scripts/tatwo-skillet-refresh.mjs" \
    TATWO_SKILLET_CLI="${SYNC_TEST_SKILLET_CLI:-$SKILLET_CLI}" \
    TATWO_DEVICE_TRUST_CLI="${SYNC_TEST_DEVICE_TRUST_CLI:-$SKILLET_CLI}" \
    TATWO_DEVICE_TRUST_TEST_KEY_ROOT="$app_support/device-trust-test-keys" \
    TATWO_TEST_MODE=1 \
    bash "$SYNC" "$@"
}

run_sync_with_repo() {
  local device="$1"
  local home="$2"
  local app_support="$3"
  local channel_dir="$4"
  local sync_repo="$5"
  shift 5

  mkdir -p "$home" "$app_support"
  env \
    HOME="$home" \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_AUTHOR_NAME="Tatwo Device Sync Test" \
    GIT_AUTHOR_EMAIL="device-sync-test@example.invalid" \
    GIT_COMMITTER_NAME="Tatwo Device Sync Test" \
    GIT_COMMITTER_EMAIL="device-sync-test@example.invalid" \
    TATWO_APP_SUPPORT="$app_support" \
    TATWO_REMOTE_APP_SUPPORT="$app_support" \
    TATWO_DEVICE_NAME="$device" \
    TATWO_PRIMARY_SSH_HOST="offline-primary.example.invalid" \
    TATWO_SYNC_REPO="$sync_repo" \
    TATWO_RELEASE_BRANCH="main" \
    TATWO_CHANNEL_REMOTE="$REMOTE" \
    TATWO_CHANNEL_DIR="$channel_dir" \
    TATWO_OS_ROOT="$TEST_ROOT/os-canonical" \
    TATWO_SYNC_CATALOG="$ROOT/config/tatwo-sync-catalog-v1.json" \
    TATWO_SKILLET_STORE="$app_support/skillet" \
    TATWO_SKILLS_RUNTIME_ROOT="$app_support/skills-runtime" \
    TATWO_SKILLS_CONSUMER_ROOT="$app_support/skills-consumer" \
    TATWO_CODEX_SKILLS_LINK="$home/.codex/skills" \
    TATWO_CLAUDE_SKILLS_LINK="$home/.claude/skills" \
    TATWO_SKILLS_CONSUMER_PROJECTION_SCRIPT="$SKILLS_PROJECTION_HELPER" \
    TATWO_SKILLET_AUTO_REFRESH="${SYNC_TEST_SKILLET_AUTO_REFRESH:-0}" \
    TATWO_SKILLET_SOURCE_ROOT="${SYNC_TEST_SKILLET_SOURCE_ROOT:-$TEST_ROOT/skills}" \
    TATWO_SKILLET_SOURCE_FALLBACK_ROOT="${SYNC_TEST_SKILLET_SOURCE_FALLBACK_ROOT:-$app_support/skills-runtime}" \
    TATWO_SKILLET_SOURCE_REGISTRY="${SYNC_TEST_SKILLET_SOURCE_REGISTRY:-$ROOT/config/tatwo-skillet-source-registry-v1.json}" \
    TATWO_SKILLET_REFRESH_SCRIPT="${SYNC_TEST_SKILLET_REFRESH_SCRIPT:-$ROOT/scripts/tatwo-skillet-refresh.mjs}" \
    TATWO_SKILLET_CLI="${SYNC_TEST_SKILLET_CLI:-$SKILLET_CLI}" \
    TATWO_DEVICE_TRUST_CLI="${SYNC_TEST_DEVICE_TRUST_CLI:-$SKILLET_CLI}" \
    TATWO_DEVICE_TRUST_TEST_KEY_ROOT="$app_support/device-trust-test-keys" \
    TATWO_TEST_MODE="${SYNC_TEST_MODE:-1}" \
    TATWO_TEST_BEFORE_ACTIVATE_HOOK="${SYNC_TEST_BEFORE_ACTIVATE_HOOK:-}" \
    TATWO_TEST_AFTER_ACTIVATE_HOOK="${SYNC_TEST_AFTER_ACTIVATE_HOOK:-}" \
    TATWO_TEST_BEFORE_SKILLET_ACTIVATE_HOOK="${SYNC_TEST_BEFORE_SKILLET_ACTIVATE_HOOK:-}" \
    TATWO_TEST_AFTER_SKILLET_ACTIVATE_HOOK="${SYNC_TEST_AFTER_SKILLET_ACTIVATE_HOOK:-}" \
    TATWO_TEST_CRASH_AFTER_OS_ACTIVATE="${SYNC_TEST_CRASH_AFTER_OS_ACTIVATE:-0}" \
    TATWO_TEST_CRASH_AFTER_SYSTEM_COMMIT="${SYNC_TEST_CRASH_AFTER_SYSTEM_COMMIT:-0}" \
    TATWO_TEST_CRASH_DURING_ROLLBACK_AFTER_OS="${SYNC_TEST_CRASH_DURING_ROLLBACK_AFTER_OS:-0}" \
    TATWO_TEST_CRASH_DURING_TRANSACTION_PREPARE="${SYNC_TEST_CRASH_DURING_TRANSACTION_PREPARE:-0}" \
    bash "$SYNC" "$@"
}

if [ -z "$SKILLET_CLI" ]; then
  SWIFTPM_MAXIMUM_CONCURRENT_OPERATIONS=2 \
    swift build \
      --package-path "$ROOT" \
      --scratch-path "$SWIFTPM_SCRATCH_PATH" \
      --product tatwo-ultrawork \
      --jobs 2 >/dev/null
  SKILLET_CLI="$(
    swift build \
      --package-path "$ROOT" \
      --scratch-path "$SWIFTPM_SCRATCH_PATH" \
      --show-bin-path
  )/tatwo-ultrawork"
fi
[ -x "$SKILLET_CLI" ] || fail "Skillet CLI is unavailable: $SKILLET_CLI"
# Match the header block by structure, not by a fixed line count: a leading
# blank line or extra preamble must not flip this assertion (os.md §9.8 —
# truncated input must never decide pass/fail).
sed -n '1,/^$/p' "$SYNC" | grep -Eq '背景自動|LaunchAgent|helper' \
  || fail "device sync header still describes the runtime as manual-only"
if head -n 4 "$SYNC" | grep -q '非背景自動'; then
  fail "device sync header contradicts the installed background helper"
fi
pass "device sync header reflects foreground and background execution"

git init --bare -q "$REMOTE"
git init -q -b main "$SEED"
git -C "$SEED" config user.name "Tatwo Device Sync Test"
git -C "$SEED" config user.email "device-sync-test@example.invalid"
printf '%s\n' "offline channel seed" > "$SEED/README.md"
git -C "$SEED" add README.md
git -C "$SEED" commit -q -m "seed offline channel remote"
git -C "$SEED" remote add origin "$REMOTE"
git -C "$SEED" push -q origin main
git --git-dir="$REMOTE" symbolic-ref HEAD refs/heads/main
mkdir -p "$TEST_ROOT/os-canonical"
printf '%s\n' "# Work OS issue fixture" "queue and digest closure" \
  >"$TEST_ROOT/os-canonical/issue.md"
printf '%s\n' "# Work OS constitution fixture" "authority and governance" \
  >"$TEST_ROOT/os-canonical/os.md"
printf '%s\n' "# Work OS todo fixture" "implementation backlog" \
  >"$TEST_ROOT/os-canonical/TODO.md"
mkdir -p "$TEST_ROOT/skills/刺青網頁" "$TEST_ROOT/skills/beta-skill"
printf '%s\n' "---" "name: alpha-skill" \
  "description: Aggregate sync fixture alpha" \
  "---" "alpha private skill" \
  >"$TEST_ROOT/skills/刺青網頁/SKILL.md"
printf '%s\n' "---" "name: beta-skill" \
  "description: Aggregate sync fixture beta" \
  "---" "beta private skill" \
  >"$TEST_ROOT/skills/beta-skill/SKILL.md"
mkdir -p "$TEST_ROOT/skills/beta-skill/runtime/backups"
printf '%s\n' "backups/" >"$TEST_ROOT/skills/beta-skill/.gitignore"
printf '%s\n' "transport must preserve ignored source payloads" \
  >"$TEST_ROOT/skills/beta-skill/runtime/backups/preserved.txt"
bootstrap_skills_consumer_projection \
  "$MINI_HOME" "$MINI_APP_SUPPORT" "$TEST_ROOT/skills"
bootstrap_skills_consumer_projection \
  "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$TEST_ROOT/skills"
"$SKILLET_CLI" skillet snapshot \
  --store "$BOOK_APP_SUPPORT/skillet" \
  --repository alpha-skill \
  --display-name "Alpha Skill" \
  --summary "Aggregate sync fixture alpha" \
  --source "$TEST_ROOT/skills/刺青網頁" \
  --channel staging \
  --json >/dev/null
"$SKILLET_CLI" skillet snapshot \
  --store "$BOOK_APP_SUPPORT/skillet" \
  --repository beta-skill \
  --display-name "Beta Skill" \
  --summary "Aggregate sync fixture beta" \
  --source "$TEST_ROOT/skills/beta-skill" \
  --channel staging \
  --json >/dev/null

expect_failure \
  "hot-sync channel requires an explicit private remote" \
  run_sync_without_channel_remote mini "$MINI_HOME" "$MINI_APP_SUPPORT" \
  "$TEST_ROOT/channel-without-explicit-remote" role-status
assert_output "missing private channel remote fails closed" \
  'TATWO_CHANNEL_REMOTE|private|私人|熱同步'

expect_failure \
  "ambiguous broadcast requests fail closed instead of sharing one ACK slot" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-request --target all-secondaries --action system-pull
assert_output "broadcast route explains per-device requests" \
  'all-secondaries|逐台|per-device|每台'

expect_success \
  "register mini in the offline channel" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  register --role secondary --name mini --host mini.invalid

expect_success \
  "register book in the offline channel" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  register --role secondary --name book --host book.invalid

expect_success \
  "set-primary bootstraps mini as epoch 1" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  set-primary --name mini

primary_file="$MINI_CHANNEL/primary.json"
[ -f "$primary_file" ] || fail "set-primary did not create primary.json"
grep -Eq '"name"[[:space:]]*:[[:space:]]*"mini"' "$primary_file" \
  || fail "primary.json does not name mini"
grep -Eq '"epoch"[[:space:]]*:[[:space:]]*1([,[:space:]]|$)' "$primary_file" \
  || fail "primary.json does not store numeric epoch 1"
grep -Eq '"changedAt"[[:space:]]*:[[:space:]]*"[^"]+"' "$primary_file" \
  || fail "primary.json does not store changedAt"
pass "primary.json stores name, numeric epoch, and changedAt"

expect_success \
  "role-status reports mini as primary" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" role-status
assert_output "mini role-status includes its device" '(^|[[:space:]])device=mini([[:space:]]|$)'
assert_output "mini role-status includes primary role" '(^|[[:space:]])role=primary([[:space:]]|$)'
assert_output "mini role-status includes current primary" '(^|[[:space:]])primary=mini([[:space:]]|$)'
assert_output "mini role-status includes epoch 1" '(^|[[:space:]])epoch=1([[:space:]]|$)'

WRONG_CHANNEL_REMOTE="$TEST_ROOT/wrong-channel.git"
git init --bare -q "$WRONG_CHANNEL_REMOTE"
channel_head_before_origin_rebind="$(git -C "$MINI_CHANNEL" rev-parse HEAD)"
git -C "$MINI_CHANNEL" remote set-url origin "$WRONG_CHANNEL_REMOTE"
expect_success \
  "existing channel checkout safely rebinds to the configured private hot remote" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" role-status
[ "$(git -C "$MINI_CHANNEL" remote get-url origin)" = "$REMOTE" ] \
  || fail "existing channel checkout retained a stale origin"
[ "$(git -C "$MINI_CHANNEL" rev-parse HEAD)" = "$channel_head_before_origin_rebind" ] \
  || fail "channel origin rebind rewrote the local checkout"
origin_rebind_receipt="$(
  find "$MINI_APP_SUPPORT/device-sync-state/channel-origin-rebind" \
    -mindepth 2 -maxdepth 2 -type f -name receipt.json -print -quit 2>/dev/null
)"
[ -n "$origin_rebind_receipt" ] \
  || fail "channel origin rebind produced no durable receipt"
[ "$(plutil -extract schema raw "$origin_rebind_receipt")" = "TatwoChannelOriginRebindReceiptV1" ] \
  && [ "$(plutil -extract outcome raw "$origin_rebind_receipt")" = "rebound" ] \
  && [ "$(plutil -extract oldRemote raw "$origin_rebind_receipt")" = "$WRONG_CHANNEL_REMOTE" ] \
  && [ "$(plutil -extract newRemote raw "$origin_rebind_receipt")" = "$REMOTE" ] \
  || fail "channel origin rebind receipt lost the old/new remote binding"
origin_rebind_bundle="$(dirname "$origin_rebind_receipt")/channel-before-rebind.bundle"
[ -f "$origin_rebind_bundle" ] \
  && git bundle verify "$origin_rebind_bundle" >/dev/null 2>&1 \
  || fail "channel origin rebind did not preserve a valid rollback bundle"
pass "existing channel origin drift is rebound with rollback evidence"

lock_first_log="$TEST_ROOT/channel-lock-first.log"
SYNC_TEST_CHANNEL_LOCK_OWNER_DELAY_SECONDS=1 \
SYNC_TEST_CHANNEL_LOCK_HOLD_SECONDS=1 \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
    role-status >"$lock_first_log" 2>&1 &
lock_first_pid=$!
lock_wait_count=0
while [ ! -d "$MINI_APP_SUPPORT/device-sync-state/channel-operation.lock" ] \
  && [ "$lock_wait_count" -lt 200 ]
do
  sleep 0.01
  lock_wait_count=$((lock_wait_count + 1))
done
[ -d "$MINI_APP_SUPPORT/device-sync-state/channel-operation.lock" ] \
  || fail "lock-race fixture did not create the channel lock"
[ ! -f "$MINI_APP_SUPPORT/device-sync-state/channel-operation.lock/owner" ] \
  || fail "lock-race fixture missed the owner-creation window"
SYNC_TEST_CHANNEL_LOCK_TIMEOUT_SECONDS=0
expect_failure \
  "second channel operation cannot steal a newly-created lock before owner publication" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" role-status
unset SYNC_TEST_CHANNEL_LOCK_TIMEOUT_SECONDS
assert_output "lock race rejection is explicit" '拒絕並行|另一個同步通道操作'
if ! wait "$lock_first_pid"; then
  LAST_OUTPUT="$(cat "$lock_first_log" 2>/dev/null || true)"
  fail "original channel lock holder failed after the race probe"
fi
stale_lock_root="$MINI_APP_SUPPORT/device-sync-state/stale-channel-locks"
if [ -d "$stale_lock_root" ] \
  && find "$stale_lock_root" -mindepth 1 -maxdepth 1 -print -quit | grep -q .
then
  fail "newly-created live lock was archived as stale"
fi
pass "owner-publication grace prevents dual channel lock holders"

mkdir -p "$MINI_APP_SUPPORT/device-sync-state/channel-operation.lock"
touch -t 202001010000 "$MINI_APP_SUPPORT/device-sync-state/channel-operation.lock"
SYNC_TEST_CHANNEL_LOCK_OWNER_GRACE_SECONDS=1
expect_success \
  "ownerless lock older than the grace period is recovered" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" role-status
unset SYNC_TEST_CHANNEL_LOCK_OWNER_GRACE_SECONDS
find "$stale_lock_root" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null \
  | grep -q . || fail "old ownerless lock produced no stale-lock evidence archive"
pass "channel lock recovery preserves evidence after the grace period"

expect_success \
  "role-status reports book as secondary at epoch 1" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" role-status
assert_output "book role-status includes its device" '(^|[[:space:]])device=book([[:space:]]|$)'
assert_output "book role-status includes secondary role" '(^|[[:space:]])role=secondary([[:space:]]|$)'
assert_output "book role-status sees mini primary" '(^|[[:space:]])primary=mini([[:space:]]|$)'
assert_output "book role-status sees epoch 1" '(^|[[:space:]])epoch=1([[:space:]]|$)'

expect_success \
  "current primary transfers authority to book and increments epoch" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  set-primary --name book --expected-epoch 1

expect_success \
  "book role-status reports primary at epoch 2" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" role-status
assert_output "book is primary after transfer" '(^|[[:space:]])role=primary([[:space:]]|$)'
assert_output "book is the current primary" '(^|[[:space:]])primary=book([[:space:]]|$)'
assert_output "authority epoch increments to 2" '(^|[[:space:]])epoch=2([[:space:]]|$)'

expect_success \
  "mini role-status reports secondary at epoch 2" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" role-status
assert_output "mini becomes secondary after transfer" '(^|[[:space:]])role=secondary([[:space:]]|$)'
assert_output "mini sees book as primary" '(^|[[:space:]])primary=book([[:space:]]|$)'
assert_output "mini sees epoch 2" '(^|[[:space:]])epoch=2([[:space:]]|$)'

expect_failure \
  "set-primary rejects a stale expected epoch" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  set-primary --name mini --expected-epoch 1
assert_output "stale transfer rejection names epoch" 'epoch|Epoch|EPOCH'

expect_success \
  "stale transfer leaves book primary at epoch 2" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" role-status
assert_output "stale transfer preserves book primary" '(^|[[:space:]])primary=book([[:space:]]|$)'
assert_output "stale transfer preserves epoch 2" '(^|[[:space:]])epoch=2([[:space:]]|$)'

mkdir -p "$MINI_CHANNEL/acks"
printf '%s\n' '{"requestID":"local-unpushed-refresh"}' \
  >"$MINI_CHANNEL/acks/local-unpushed-refresh.json"
git -C "$MINI_CHANNEL" add acks/local-unpushed-refresh.json
git -C "$MINI_CHANNEL" \
  -c user.name="Tatwo Device Sync Test" \
  -c user.email="device-sync-test@example.invalid" \
  commit -q -m "local unpushed ack before refresh"
printf '%s\n' '{"kind":"remote-refresh"}' >"$BOOK_CHANNEL/remote-refresh-marker.json"
git -C "$BOOK_CHANNEL" add remote-refresh-marker.json
git -C "$BOOK_CHANNEL" \
  -c user.name="Tatwo Device Sync Test" \
  -c user.email="device-sync-test@example.invalid" \
  commit -q -m "remote channel advances before ack push"
git -C "$BOOK_CHANNEL" push -q origin device-sync-channel
expect_success \
  "channel refresh rebases and publishes a local unpushed ACK commit" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" role-status
git --git-dir="$REMOTE" show \
  "refs/heads/device-sync-channel:acks/local-unpushed-refresh.json" >/dev/null 2>&1 \
  || fail "channel refresh lost the local unpushed ACK commit"
pass "channel refresh preserves local unpushed ACK history"

before_non_primary="$(channel_commit_count)"
expect_failure \
  "non-primary mini cannot create a sync request" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-request --target book --action version-pull
after_non_primary="$(channel_commit_count)"
[ "$before_non_primary" = "$after_non_primary" ] \
  || fail "non-primary sync-request mutated the channel"
pass "non-primary rejection leaves the channel unchanged"

before_primary="$(channel_commit_count)"
expect_success \
  "primary book can create the first queued sync request" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action version-pull
assert_output "sync-request returns a stable request id" '^SYNC_REQUEST_ID=[A-Za-z0-9._:-]+$'
first_request_id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"
[ -n "$first_request_id" ] || fail "first queued request id is missing"
after_primary="$(channel_commit_count)"
[ "$after_primary" -eq $((before_primary + 1)) ] \
  || fail "primary sync-request did not append exactly one channel commit"
pass "primary sync-request appends one channel commit"

request_file="$BOOK_CHANNEL/requests/mini/$first_request_id.json"
[ -f "$request_file" ] \
  || fail "primary sync-request did not create a per-request queue entry"
grep -Eq '"requestedBy"[[:space:]]*:[[:space:]]*"book"' "$request_file" \
  || fail "primary sync-request does not record book as requestedBy"
grep -Eq '"authorityEpoch"[[:space:]]*:[[:space:]]*2([,[:space:]]|$)' "$request_file" \
  || fail "primary sync-request does not bind authority epoch 2"
grep -Eq '"sourceDeviceID"[[:space:]]*:[[:space:]]*"[^"]+"' "$request_file" \
  || fail "primary sync-request does not bind the source device id"
grep -Eq '"catalogRevision"[[:space:]]*:[[:space:]]*"[^"]+"' "$request_file" \
  || fail "primary sync-request does not bind the sync catalog revision"
pass "primary sync-request records active authority and catalog binding"

expect_success \
  "same target can receive a second queued sync request" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action version-pull
second_request_id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"
[ -n "$second_request_id" ] || fail "second queued request id is missing"
[ "$second_request_id" != "$first_request_id" ] \
  || fail "queued requests reused the same id"
[ "$(find "$BOOK_CHANNEL/requests/mini" -type f -name '*.json' | wc -l | tr -d ' ')" = "2" ] \
  || fail "same-target requests overwrite each other instead of queueing"
pass "same-target requests are append-only queue entries"

expect_success \
  "secondary poll writes convergence acknowledgements for every queued request" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini

for request_id in "$first_request_id" "$second_request_id"; do
  ack_file="$MINI_CHANNEL/acks/$request_id.json"
  [ -f "$ack_file" ] || fail "secondary poll did not acknowledge queued request $request_id"
  grep -Eq '"phase"[[:space:]]*:[[:space:]]*"converged"' "$ack_file" \
    || fail "acknowledgement is not converged"
  grep -Eq '"result"[[:space:]]*:[[:space:]]*"converged"' "$ack_file" \
    || fail "acknowledgement does not report converged result"
  grep -Eq '"authorityEpoch"[[:space:]]*:[[:space:]]*2([,[:space:]]|$)' "$ack_file" \
    || fail "acknowledgement does not retain authority epoch"
  grep -Eq '"sourceDeviceID"[[:space:]]*:[[:space:]]*"[^"]+"' "$ack_file" \
    || fail "acknowledgement does not retain source device id"
  grep -Eq '"targetDeviceID"[[:space:]]*:[[:space:]]*"[^"]+"' "$ack_file" \
    || fail "acknowledgement does not identify target device id"
  grep -Eq '"sourceDigest"[[:space:]]*:[[:space:]]*"[^"]+"' "$ack_file" \
    || fail "acknowledgement does not include source digest"
  grep -Eq '"appliedDigest"[[:space:]]*:[[:space:]]*"[^"]+"' "$ack_file" \
    || fail "acknowledgement does not include applied digest"
done
pass "queued acknowledgements retain authority, identity, and digest evidence"

expect_success \
  "primary can read the target acknowledgement" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-ack-status --id "$second_request_id"
assert_output "ack status exposes converged phase" 'phase=converged'
assert_output "ack status names request id" "id=$second_request_id"

lower_sequence_request_id="lower-sequence-replay"
lower_sequence_request="$BOOK_CHANNEL/requests/mini/$lower_sequence_request_id.json"
cp "$request_file" "$lower_sequence_request"
plutil -replace id -string "$lower_sequence_request_id" "$lower_sequence_request"
plutil -replace requestID -string "$lower_sequence_request_id" "$lower_sequence_request"
plutil -replace ledgerSequence -integer 1 "$lower_sequence_request"
lower_sequence_signature="$BOOK_CHANNEL/signatures/requests/mini/$lower_sequence_request_id.json"
plutil -replace signaturePath \
  -string "signatures/requests/mini/$lower_sequence_request_id.json" \
  "$lower_sequence_request"
sign_test_artifact \
  "$BOOK_APP_SUPPORT" "sync-request" \
  "$lower_sequence_request" "$lower_sequence_signature"
git -C "$BOOK_CHANNEL" add "$lower_sequence_request" "$lower_sequence_signature"
git -C "$BOOK_CHANNEL" \
  -c user.name="Tatwo Device Sync Test" \
  -c user.email="device-sync-test@example.invalid" \
  commit -q -m "inject lower ledger sequence replay"
git -C "$BOOK_CHANNEL" push -q origin device-sync-channel
expect_success \
  "secondary polls a same-epoch lower ledger sequence request" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
grep -qxF "$lower_sequence_request_id" \
  "$MINI_APP_SUPPORT/device-sync-state/rejected-ids-mini" \
  || fail "same-epoch lower ledger sequence request was not rejected"
[ ! -f "$MINI_CHANNEL/acks/$lower_sequence_request_id.json" ] \
  || fail "same-epoch lower ledger sequence request produced an ACK"
pass "same-epoch lower ledger sequence request fails closed"

BOOK_REPO="$TEST_ROOT/repo-book"
MINI_REPO="$TEST_ROOT/repo-mini"
git clone -q --branch main "$REMOTE" "$BOOK_REPO"
git clone -q --branch main "$REMOTE" "$MINI_REPO"
git -C "$BOOK_REPO" config user.name "Tatwo Device Sync Test"
git -C "$BOOK_REPO" config user.email "device-sync-test@example.invalid"
printf '%s\n' "release A" >"$BOOK_REPO/release-bound.txt"
git -C "$BOOK_REPO" add release-bound.txt
git -C "$BOOK_REPO" commit -q -m "release A"
git -C "$BOOK_REPO" push -q origin main
release_a="$(git -C "$BOOK_REPO" rev-parse HEAD)"
expect_success \
  "primary binds a version request to release commit A" \
  run_sync_with_repo book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" "$BOOK_REPO" \
  sync-request --target mini --action version-pull
bound_request_id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"
[ -n "$bound_request_id" ] || fail "commit-bound request id is missing"
[ "$(plutil -extract sourceDigest raw "$BOOK_CHANNEL/requests/mini/$bound_request_id.json")" = "$release_a" ] \
  || fail "version request is not bound to release commit A"
printf '%s\n' "release B" >>"$BOOK_REPO/release-bound.txt"
git -C "$BOOK_REPO" add release-bound.txt
git -C "$BOOK_REPO" commit -q -m "release B"
git -C "$BOOK_REPO" push -q origin main
release_b="$(git -C "$BOOK_REPO" rev-parse HEAD)"
[ "$release_a" != "$release_b" ] || fail "release B did not advance the remote"
expect_success \
  "target applies request-bound commit A after remote release advances to B" \
  run_sync_with_repo mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" "$MINI_REPO" \
  sync-poll --device mini
[ "$(git -C "$MINI_REPO" rev-parse HEAD)" = "$release_a" ] \
  || fail "target followed remote release B instead of request-bound commit A"
bound_ack="$MINI_CHANNEL/acks/$bound_request_id.json"
[ "$(plutil -extract sourceDigest raw "$bound_ack")" = "$release_a" ] \
  && [ "$(plutil -extract appliedDigest raw "$bound_ack")" = "$release_a" ] \
  || fail "commit-bound ACK does not prove target applied release A"
[ "$(git --git-dir="$REMOTE" rev-parse refs/heads/main)" = "$release_b" ] \
  || fail "remote release did not remain at commit B during target application"
pass "version transfer remains bound to commit A even when remote advances to B"

expect_success \
  "primary refreshes channel after target publishes commit-bound ACK" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" role-status

book_device_id="$(sed -n 's/.*"deviceId":[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$BOOK_CHANNEL/devices/book.json" | head -1)"
mini_device_id="$(sed -n 's/.*"deviceId":[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$BOOK_CHANNEL/devices/mini.json" | head -1)"
catalog_revision="$(sed -n 's/.*"catalogRevision":[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$ROOT/config/tatwo-sync-catalog-v1.json" | head -1)"
forged_dir="$BOOK_CHANNEL/requests/mini"
mkdir -p "$forged_dir"

write_forged_request() {
  local file_id="$1" request_id="$2" action="$3" target="$4" source_id="$5"
  cat >"$forged_dir/$file_id.json" <<EOF
{
  "id": "$request_id",
  "requestID": "$request_id",
  "action": "$action",
  "target": "$target",
  "targetDeviceName": "$target",
  "targetDeviceID": "$mini_device_id",
  "primaryHost": "offline-primary.example.invalid",
  "requestedBy": "book",
  "requestedAt": "2026-07-23T12:00:00Z",
  "authorityPrimary": "book",
  "authorityEpoch": 2,
  "sourceDeviceName": "book",
  "sourceDeviceID": "$source_id",
  "catalogRevision": "$catalog_revision",
  "manifestPath": "",
  "manifestDigest": ""
}
EOF
}

write_forged_request "forged-source" "forged-source" "system-pull" "mini" "forged-device"
write_forged_request "forged-target" "forged-target" "system-pull" "book" "$book_device_id"
write_forged_request "forged-action" "forged-action" "erase-everything" "mini" "$book_device_id"
write_forged_request "forged-id-file" "forged-id-payload" "system-pull" "mini" "$book_device_id"
git -C "$BOOK_CHANNEL" add requests/mini
git -C "$BOOK_CHANNEL" \
  -c user.name="Tatwo Device Sync Test" \
  -c user.email="device-sync-test@example.invalid" \
  commit -q -m "inject adversarial request fixtures"
git -C "$BOOK_CHANNEL" push -q origin device-sync-channel

expect_success \
  "secondary rejects forged request identity target action and filename binding" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
for rejected_id in forged-source forged-target forged-action forged-id-payload; do
  grep -qxF "$rejected_id" "$MINI_APP_SUPPORT/device-sync-state/rejected-ids-mini" \
    || fail "forged request was not rejected: $rejected_id"
  [ ! -f "$MINI_CHANNEL/acks/$rejected_id.json" ] \
    || fail "forged request produced an ACK: $rejected_id"
done
pass "forged request fields fail closed before execution"

AUTO_REFRESH_REGISTRY="$TEST_ROOT/skillet-source-registry.json"
cat >"$AUTO_REFRESH_REGISTRY" <<'JSON'
{
  "schemaVersion": 1,
  "repositoryAliases": [
    {
      "sourceName": "刺青網頁",
      "repositoryID": "alpha-skill",
      "displayName": "Alpha Skill"
    }
  ]
}
JSON

SYNC_TEST_SKILLET_AUTO_REFRESH=1
SYNC_TEST_SKILLET_SOURCE_ROOT="$TEST_ROOT/skills"
SYNC_TEST_SKILLET_SOURCE_REGISTRY="$AUTO_REFRESH_REGISTRY"
SYNC_TEST_OMIT_SKILLET_RUNTIME_ROOT=1
expect_failure \
  "legacy helper without an explicit runtime root fails closed" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
assert_output "legacy helper rejection requires re-enrollment" \
  '舊版 runtime 設定|重新執行設備納管'
unset SYNC_TEST_OMIT_SKILLET_RUNTIME_ROOT
unset SYNC_TEST_SKILLET_AUTO_REFRESH
unset SYNC_TEST_SKILLET_SOURCE_ROOT
unset SYNC_TEST_SKILLET_SOURCE_REGISTRY
pass "legacy helpers cannot silently switch to the new Skillet runtime layout"

BROKEN_SKILLET_PYTHON="$TEST_ROOT/broken-skillet-python3"
cat >"$BROKEN_SKILLET_PYTHON" <<'EOF'
#!/usr/bin/env bash
exit 72
EOF
chmod +x "$BROKEN_SKILLET_PYTHON"
SYNC_TEST_SKILLET_AUTO_REFRESH=1
SYNC_TEST_SKILLET_SOURCE_ROOT="$TEST_ROOT/skills"
SYNC_TEST_SKILLET_SOURCE_REGISTRY="$AUTO_REFRESH_REGISTRY"
SYNC_TEST_PYTHON3="$BROKEN_SKILLET_PYTHON"
expect_failure \
  "nonfunctional python3 fails before canonical refresh" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
assert_output "python3 functional preflight is explicit" \
  'python3.*fcntl|fcntl'
unset SYNC_TEST_PYTHON3
unset SYNC_TEST_SKILLET_AUTO_REFRESH
unset SYNC_TEST_SKILLET_SOURCE_ROOT
unset SYNC_TEST_SKILLET_SOURCE_REGISTRY
pass "canonical refresh verifies python3 fcntl before mutation"

store_digest_before_low_space="$(
  find "$BOOK_APP_SUPPORT/skillet" -type f -exec shasum -a 256 {} \; \
    | LC_ALL=C sort \
    | shasum -a 256 \
    | awk '{print $1}'
)"
SYNC_TEST_SKILLET_AUTO_REFRESH=1
SYNC_TEST_SKILLET_SOURCE_ROOT="$TEST_ROOT/skills"
SYNC_TEST_SKILLET_SOURCE_REGISTRY="$AUTO_REFRESH_REGISTRY"
SYNC_TEST_AVAILABLE_BYTES_OVERRIDE=0
expect_failure \
  "low disk budget blocks before staged Skillet refresh mutation" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
assert_output "low disk rejection is explicit" \
  'disk budget 不足|磁碟空間不足'
failed_refresh_attempt_id="$(
  printf '%s\n' "$LAST_OUTPUT" \
    | sed -n 's/^SYNC_SOURCE_REFRESH_ATTEMPT_ID=//p' \
    | tail -1
)"
[ -n "$failed_refresh_attempt_id" ] \
  || fail "failed source refresh did not expose its durable attempt ID"
failed_refresh_receipt="$BOOK_APP_SUPPORT/device-sync-state/skillet-export-receipts/$failed_refresh_attempt_id/canonical-refresh.json"
[ -f "$failed_refresh_receipt" ] \
  || fail "failed source refresh did not persist canonical-refresh.json"
[ "$(plutil -extract evidenceKind raw "$failed_refresh_receipt")" \
    = "local-source-refresh-attempt" ] \
  && [ "$(plutil -extract attemptID raw "$failed_refresh_receipt")" \
    = "$failed_refresh_attempt_id" ] \
  && [ "$(plutil -extract target raw "$failed_refresh_receipt")" = "mini" ] \
  && [ "$(plutil -extract action raw "$failed_refresh_receipt")" = "system-pull" ] \
  && [ "$(plutil -extract outcome raw "$failed_refresh_receipt")" = "failed" ] \
  || fail "failed source refresh receipt lost its exact attempt binding"
[ ! -e "$BOOK_CHANNEL/requests/mini/$failed_refresh_attempt_id.json" ] \
  && [ ! -e "$BOOK_CHANNEL/payloads/$failed_refresh_attempt_id" ] \
  || fail "failed source refresh published a request or payload"
store_digest_after_low_space="$(
  find "$BOOK_APP_SUPPORT/skillet" -type f -exec shasum -a 256 {} \; \
    | LC_ALL=C sort \
    | shasum -a 256 \
    | awk '{print $1}'
)"
[ "$store_digest_before_low_space" = "$store_digest_after_low_space" ] \
  || fail "low disk preflight mutated the live Skillet store"
if find "$(dirname "$BOOK_APP_SUPPORT/skillet")" -maxdepth 1 \
    -name '.skillet.refresh-staging-*' -print -quit \
    | grep -q .
then
  fail "low disk preflight created a staged Skillet store"
fi
unset SYNC_TEST_AVAILABLE_BYTES_OVERRIDE
unset SYNC_TEST_SKILLET_AUTO_REFRESH
unset SYNC_TEST_SKILLET_SOURCE_ROOT
unset SYNC_TEST_SKILLET_SOURCE_REGISTRY
pass "failed refresh keeps an exact local attempt receipt without publication or activation"

SYNC_TEST_SKILLET_AUTO_REFRESH=1
SYNC_TEST_SKILLET_SOURCE_ROOT="$TEST_ROOT/skills"
SYNC_TEST_SKILLET_SOURCE_REGISTRY="$AUTO_REFRESH_REGISTRY"
expect_success \
  "primary publishes an os.issue system manifest" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
unset SYNC_TEST_SKILLET_AUTO_REFRESH
unset SYNC_TEST_SKILLET_SOURCE_ROOT
unset SYNC_TEST_SKILLET_SOURCE_REGISTRY
system_request_id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"
[ -n "$system_request_id" ] || fail "system-pull request id is missing"
canonical_refresh_receipt="$BOOK_APP_SUPPORT/device-sync-state/skillet-export-receipts/$system_request_id/canonical-refresh.json"
[ -f "$canonical_refresh_receipt" ] \
  || fail "system-pull did not persist its canonical Skillet refresh receipt"
[ "$(plutil -extract schema raw "$canonical_refresh_receipt")" = "TatwoSkilletCanonicalRefreshReceiptV1" ] \
  && [ "$(plutil -extract outcome raw "$canonical_refresh_receipt")" = "converged" ] \
  && [ "$(plutil -extract discoveredSourceCount raw "$canonical_refresh_receipt")" = "2" ] \
  && [ "$(plutil -extract refreshedCount raw "$canonical_refresh_receipt")" = "2" ] \
  || fail "system-pull canonical Skillet refresh did not converge over every discovered source"
pass "system-pull refreshes canonical Skillet sources before publishing"
system_request="$BOOK_CHANNEL/requests/mini/$system_request_id.json"
[ -f "$system_request" ] || fail "system-pull request queue entry is missing"
grep -Eq '"manifestDigest"[[:space:]]*:[[:space:]]*"[a-f0-9]{64}"' "$system_request" \
  || fail "system-pull request lacks a manifest digest"
[ -f "$BOOK_CHANNEL/payloads/$system_request_id/manifest.json" ] \
  || fail "system-pull manifest is missing from the private channel"
[ -f "$BOOK_CHANNEL/payloads/$system_request_id/items/os.issue/content" ] \
  || fail "system-pull os.issue payload is missing"
[ -f "$BOOK_CHANNEL/payloads/$system_request_id/items/os.constitution/content" ] \
  || fail "system-pull os.constitution payload is missing"
[ -f "$BOOK_CHANNEL/payloads/$system_request_id/items/os.todo/content" ] \
  || fail "system-pull os.todo payload is missing"
[ -f "$BOOK_CHANNEL/payloads/$system_request_id/items/skills.skillet/set.json" ] \
  || fail "system-pull Skillet set manifest is missing"
[ "$(plutil -extract items raw "$BOOK_CHANNEL/payloads/$system_request_id/manifest.json")" = "4" ] \
  || fail "system-pull manifest does not enumerate every active catalog item"
[ "$(plutil -extract repositories raw "$BOOK_CHANNEL/payloads/$system_request_id/items/skills.skillet/set.json")" = "2" ] \
  || fail "system-pull Skillet set does not enumerate every repository"
for repository_id in alpha-skill beta-skill; do
  [ -d "$BOOK_CHANNEL/payloads/$system_request_id/items/skills.skillet/repositories/$repository_id/bundle" ] \
    || fail "system-pull Skillet bundle is missing: $repository_id"
  [ -f "$BOOK_CHANNEL/payloads/$system_request_id/items/skills.skillet/repositories/$repository_id/authority-binding.json" ] \
    || fail "system-pull Skillet authority binding is missing: $repository_id"
done
pass "system-pull publishes an immutable four-item manifest with authority-bound Skillet repositories"
ignored_payload_file="$(
  find "$BOOK_CHANNEL/payloads/$system_request_id/items/skills.skillet/repositories/beta-skill/bundle/objects" \
    -type f -path '*/payload/runtime/backups/preserved.txt' -print -quit
)"
[ -n "$ignored_payload_file" ] \
  || fail "Skillet export did not preserve the ignored source fixture"
ignored_payload_relative="${ignored_payload_file#"$BOOK_CHANNEL"/}"
git -C "$BOOK_CHANNEL" ls-files --error-unmatch -- "$ignored_payload_relative" >/dev/null 2>&1 \
  || fail "system-pull channel commit omitted a bundle file matched by payload .gitignore"
git -C "$BOOK_CHANNEL" cat-file -e "HEAD:$ignored_payload_relative" \
  || fail "system-pull channel commit cannot reconstruct the ignored bundle file"
pass "system-pull force-tracks every verified bundle object regardless of payload .gitignore"

SYNC_TEST_OMIT_SKILLET_RUNTIME_ROOT=1
expect_failure \
  "legacy secondary without an explicit runtime root leaves system-pull retryable" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
assert_output "legacy secondary rejection requires re-enrollment" \
  '舊版 runtime 設定|重新執行設備納管'
unset SYNC_TEST_OMIT_SKILLET_RUNTIME_ROOT
legacy_secondary_ack="$MINI_CHANNEL/acks/$system_request_id.json"
assert_no_terminal_ack "$legacy_secondary_ack" \
  "legacy secondary wrote a terminal ACK"
[ ! -e "$MINI_APP_SUPPORT/device-sync-state/system-transactions/$system_request_id" ] \
  || fail "legacy secondary created a system transaction before runtime-root enrollment"
[ ! -e "$MINI_APP_SUPPORT/hot-sync-mirror/os/issue.md" ] \
  || fail "legacy secondary changed the OS mirror before runtime-root enrollment"
[ ! -e "$MINI_APP_SUPPORT/skills-runtime" ] \
  || fail "legacy secondary created the default runtime before explicit enrollment"
! grep -qxF "$system_request_id" \
  "$MINI_APP_SUPPORT/device-sync-state/processed-ids-mini" 2>/dev/null \
  || fail "legacy secondary marked a retryable request processed"
pass "legacy secondary runtime-root refusal is non-terminal and mutation-free"

SYNC_TEST_OMIT_SKILLS_CONSUMER_ENROLLMENT=1
expect_failure \
  "secondary without explicit native-consumer enrollment leaves system-pull pending" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
assert_output "missing native-consumer enrollment requires re-enrollment" \
  'Skills consumer projection|原生 skills|重新執行設備納管'
unset SYNC_TEST_OMIT_SKILLS_CONSUMER_ENROLLMENT
assert_no_terminal_ack "$legacy_secondary_ack" \
  "missing native-consumer enrollment wrote a terminal ACK"
[ ! -e "$MINI_APP_SUPPORT/device-sync-state/system-transactions/$system_request_id" ] \
  || fail "missing native-consumer enrollment created a system transaction"
[ ! -e "$MINI_APP_SUPPORT/hot-sync-mirror/os/issue.md" ] \
  || fail "missing native-consumer enrollment changed the OS mirror"
! grep -qxF "$system_request_id" \
  "$MINI_APP_SUPPORT/device-sync-state/processed-ids-mini" 2>/dev/null \
  || fail "missing native-consumer enrollment marked a retryable request processed"
pass "native-consumer enrollment is mandatory before ledger acceptance or mutation"

projection_current="$MINI_APP_SUPPORT/skills-consumer/current"
[ "$(realpath "$projection_current")" = "$(realpath "$TEST_ROOT/skills")" ] \
  || fail "initial native-consumer projection is not bound to the canonical source"
expect_success \
  "primary queues a later request behind the pending system activation" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action version-pull
projection_barrier_request_id="$(
  printf '%s\n' "$LAST_OUTPUT" \
    | sed -n 's/^SYNC_REQUEST_ID=//p' \
    | tail -1
)"
[ -n "$projection_barrier_request_id" ] \
  || fail "projection queue-barrier request id is missing"
SYNC_TEST_FAIL_SKILLS_CONSUMER_PROJECTION=1
expect_success \
  "projection failure after system commit remains committed-awaiting-ACK" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_FAIL_SKILLS_CONSUMER_PROJECTION
assert_output "projection failure injection is explicit" \
  '測試注入：Skills consumer projection activation 失敗'
projection_failure_journal="$MINI_APP_SUPPORT/device-sync-state/system-transactions/$system_request_id/journal.json"
[ "$(plutil -extract phase raw "$projection_failure_journal")" = "committed" ] \
  || fail "projection failure did not preserve the committed system transaction"
assert_no_terminal_ack "$legacy_secondary_ack" \
  "projection failure after commit wrote a terminal ACK"
! grep -qxF "$system_request_id" \
  "$MINI_APP_SUPPORT/device-sync-state/processed-ids-mini" 2>/dev/null \
  || fail "projection failure incorrectly marked the request processed"
[ ! -e "$MINI_CHANNEL/acks/$projection_barrier_request_id.json" ] \
  || fail "committed-awaiting-ACK request allowed a later ledger sequence to execute"
! grep -qxF "$projection_barrier_request_id" \
  "$MINI_APP_SUPPORT/device-sync-state/processed-ids-mini" 2>/dev/null \
  || fail "queue barrier incorrectly marked the later request processed"
[ "$(realpath "$projection_current")" = "$(realpath "$TEST_ROOT/skills")" ] \
  || fail "projection failure did not preserve the previous source projection"
pass "projection failure is retryable, preserves the previous projection, and blocks later sequences"

projection_reactivation_marker="$TEST_ROOT/projection-retry-system-reactivation"
SYNC_TEST_BEFORE_ACTIVATE_HOOK="printf '%s\n' 'unexpected system reactivation' > '$projection_reactivation_marker'"
expect_success \
  "projection retry converges from committed state without system reactivation" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_BEFORE_ACTIVATE_HOOK
[ ! -e "$projection_reactivation_marker" ] \
  || fail "projection retry executed the system activation path a second time"
[ "$(plutil -extract phase raw \
      "$MINI_CHANNEL/acks/$projection_barrier_request_id.json")" = "converged" ] \
  || fail "later queued request did not execute after the deferred request converged"
grep -qxF "$projection_barrier_request_id" \
  "$MINI_APP_SUPPORT/device-sync-state/processed-ids-mini" \
  || fail "later queued request did not write processed after the queue barrier cleared"
mirror="$MINI_APP_SUPPORT/hot-sync-mirror/os/issue.md"
[ -f "$mirror" ] || fail "os.issue was not activated into the read-only mirror"
cmp "$TEST_ROOT/os-canonical/issue.md" "$mirror" \
  || fail "os.issue mirror differs from the canonical source payload"
[ -f "$MINI_APP_SUPPORT/hot-sync-mirror/os/os.md" ] \
  || fail "os.constitution was not activated into the read-only mirror"
cmp "$TEST_ROOT/os-canonical/os.md" "$MINI_APP_SUPPORT/hot-sync-mirror/os/os.md" \
  || fail "os.constitution mirror differs from the canonical source payload"
[ -f "$MINI_APP_SUPPORT/hot-sync-mirror/os/TODO.md" ] \
  || fail "os.todo was not activated into the read-only mirror"
cmp "$TEST_ROOT/os-canonical/TODO.md" "$MINI_APP_SUPPORT/hot-sync-mirror/os/TODO.md" \
  || fail "os.todo mirror differs from the canonical source payload"
system_ack="$MINI_CHANNEL/acks/$system_request_id.json"
[ -f "$system_ack" ] || fail "system-pull did not produce an ACK"
[ "$(plutil -extract requiredItemIDs raw "$system_ack")" = "4" ] \
  || fail "system-pull ACK does not enumerate all required item ids"
for required_id in os.constitution os.issue os.todo skills.skillet; do
  grep -Eq "\"id\"[[:space:]]*:[[:space:]]*\"$required_id\"" "$system_ack" \
    || fail "system-pull ACK does not enumerate $required_id"
done
[ "$(plutil -extract items.3.repositoryCount raw "$system_ack")" = "2" ] \
  || fail "Skillet ACK does not enumerate every repository receipt"
for repository_index in 0 1; do
  repository_id="$(plutil -extract "items.3.repositories.$repository_index.repositoryID" raw "$system_ack")"
  [ -n "$repository_id" ] || fail "Skillet ACK repository id is missing"
  [ "$(plutil -extract "items.3.repositories.$repository_index.requestID" raw "$system_ack")" = "$system_request_id" ] \
    || fail "Skillet ACK repository request binding is missing: $repository_id"
  [ "$(plutil -extract "items.3.repositories.$repository_index.authorityEpoch" raw "$system_ack")" = "2" ] \
    || fail "Skillet ACK repository epoch binding is missing: $repository_id"
  [ "$(plutil -extract "items.3.repositories.$repository_index.targetDeviceID" raw "$system_ack")" = "$mini_device_id" ] \
    || fail "Skillet ACK repository target binding is missing: $repository_id"
  [ -f "$MINI_APP_SUPPORT/skills-runtime/$repository_id/SKILL.md" ] \
    || fail "Skillet runtime was not activated: $repository_id"
  case "$repository_id" in
    alpha-skill) source_skill="$TEST_ROOT/skills/刺青網頁/SKILL.md";;
    *) source_skill="$TEST_ROOT/skills/$repository_id/SKILL.md";;
  esac
  cmp "$source_skill" "$MINI_APP_SUPPORT/skills-runtime/$repository_id/SKILL.md" \
    || fail "Skillet runtime differs from source snapshot: $repository_id"
done
grep -Eq '"phase"[[:space:]]*:[[:space:]]*"converged"' "$system_ack" \
  || fail "system-pull ACK is not converged"
projection_activation_receipt="$MINI_APP_SUPPORT/device-sync-state/skills-consumer-projection-receipts/$system_request_id/activate.json"
[ -f "$projection_activation_receipt" ] \
  || fail "system-pull produced no request-bound native-consumer projection receipt"
[ "$(plutil -extract requestID raw "$projection_activation_receipt")" = "$system_request_id" ] \
  && [ "$(plutil -extract status raw "$projection_activation_receipt")" = "passed" ] \
  || fail "native-consumer projection receipt is not bound to the system request"
[ "$(normalize_path "$(readlink "$projection_current")")" \
    = "$(normalize_path "$MINI_APP_SUPPORT/skills-runtime")" ] \
  || fail "managed consumer current does not point to the activated runtime"
[ "$(normalize_path "$(readlink "$MINI_HOME/.codex/skills")")" \
    = "$(normalize_path "$projection_current")" ] \
  || fail "Codex native skills do not use the managed consumer current link"
[ "$(normalize_path "$(readlink "$MINI_HOME/.claude/skills")")" \
    = "$(normalize_path "$projection_current")" ] \
  || fail "Claude native skills do not use the managed consumer current link"
system_consumer_readback="$MINI_CHANNEL/consumer-readbacks/mini/$system_request_id.json"
[ "$(plutil -extract requiredConsumerIDs raw "$system_consumer_readback")" = "5" ] \
  || fail "system consumer readback does not require exactly five consumer IDs"
for consumer_binding in \
  "0:work-os.bootstrap" \
  "1:tatwo-app.shared-runtime" \
  "2:skillet.runtime-loader" \
  "3:codex.native-skills" \
  "4:claude.native-skills"
do
  consumer_index="${consumer_binding%%:*}"
  consumer_id="${consumer_binding#*:}"
  [ "$(plutil -extract "requiredConsumerIDs.$consumer_index" raw "$system_consumer_readback")" = "$consumer_id" ] \
    || fail "required consumer binding is missing or out of order: $consumer_id"
done
pass "all active catalog items reach five independently verified target consumers"

processed_file="$MINI_APP_SUPPORT/device-sync-state/processed-ids-mini"
grep -vxF "$system_request_id" "$processed_file" >"${processed_file}.tmp" || true
mv "${processed_file}.tmp" "$processed_file"
managed_claude_link_backup="$TEST_ROOT/managed-claude-skills-link"
direct_claude_link_archive="$TEST_ROOT/direct-claude-skills-link"
mv "$MINI_HOME/.claude/skills" "$managed_claude_link_backup"
ln -s "$MINI_APP_SUPPORT/skills-runtime" "$MINI_HOME/.claude/skills"
expect_failure \
  "direct native-link drift cannot validate an existing converged ACK" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
assert_output "direct native-link drift names the managed projection" \
  'managed current|Skills consumer projection|原生 skills'
! grep -qxF "$system_request_id" "$processed_file" \
  || fail "direct native-link drift restored processed state from a stale ACK"
mv "$MINI_HOME/.claude/skills" "$direct_claude_link_archive"
mv "$managed_claude_link_backup" "$MINI_HOME/.claude/skills"
expect_success \
  "restored managed native links revalidate the existing converged ACK" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
grep -qxF "$system_request_id" "$processed_file" \
  || fail "restored managed native links did not restore processed state"
projection_retention_status="$MINI_APP_SUPPORT/device-sync-state/retention-status.json"
[ -f "$projection_retention_status" ] \
  || fail "native-consumer projection produced no retention accounting receipt"
for retention_label in \
  "native skills projection activation receipts" \
  "active native skills projection binding state" \
  "native skills projection transaction archives"
do
  plutil -convert json -o - "$projection_retention_status" 2>/dev/null \
    | grep -q "$retention_label" \
    || fail "retention accounting omits $retention_label"
done
pass "existing convergence is trusted only while both native links remain managed"
pass "native projection receipts, binding state, and archives are retention-accounted"

PREFIX_SOURCE_SKILLET_STORE="$TEST_ROOT/prefix-source-skillet"
PREFIX_TARGET_SKILLET_STORE="$TEST_ROOT/prefix-target-skillet"
PREFIX_TARGET_SKILLET_RUNTIME="$TEST_ROOT/prefix-target-skills-runtime"
PREFIX_TARGET_MIRROR="$TEST_ROOT/prefix-target-hot-sync-mirror"
PREFIX_TARGET_STAGING="$TEST_ROOT/prefix-target-hot-sync-staging"
mkdir -p "$TEST_ROOT/skills/skillet" "$TEST_ROOT/skills/skillet-core"
printf '%s\n' "---" "name: skillet" \
  "description: Prefix-order fixture base" \
  "---" "prefix repository fixture" \
  >"$TEST_ROOT/skills/skillet/SKILL.md"
printf '%s\n' "---" "name: skillet-core" \
  "description: Prefix-order fixture extension" \
  "---" "prefixed repository fixture" \
  >"$TEST_ROOT/skills/skillet-core/SKILL.md"
"$SKILLET_CLI" skillet snapshot \
  --store "$PREFIX_SOURCE_SKILLET_STORE" \
  --repository skillet \
  --display-name "Skillet" \
  --summary "Prefix-order fixture base" \
  --source "$TEST_ROOT/skills/skillet" \
  --channel staging \
  --json >/dev/null
"$SKILLET_CLI" skillet snapshot \
  --store "$PREFIX_SOURCE_SKILLET_STORE" \
  --repository skillet-core \
  --display-name "Skillet Core" \
  --summary "Prefix-order fixture extension" \
  --source "$TEST_ROOT/skills/skillet-core" \
  --channel staging \
  --json >/dev/null
SYNC_TEST_SKILLET_STORE="$PREFIX_SOURCE_SKILLET_STORE"
expect_success \
  "primary publishes a Skillet set containing prefix repository ids" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
unset SYNC_TEST_SKILLET_STORE
prefix_request_id="$(
  printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1
)"
[ -n "$prefix_request_id" ] || fail "prefix-order request id is missing"
prefix_set="$BOOK_CHANNEL/payloads/$prefix_request_id/items/skills.skillet/set.json"
[ "$(plutil -extract repositories.0.repositoryID raw "$prefix_set")" = "skillet" ] \
  || fail "Skillet set manifest is not sorted by repositoryID at index 0"
[ "$(plutil -extract repositories.1.repositoryID raw "$prefix_set")" = "skillet-core" ] \
  || fail "Skillet set manifest is not sorted by repositoryID at index 1"
SYNC_TEST_SKILLET_STORE="$PREFIX_TARGET_SKILLET_STORE"
SYNC_TEST_SKILLET_RUNTIME_ROOT="$PREFIX_TARGET_SKILLET_RUNTIME"
SYNC_TEST_HOT_SYNC_MIRROR="$PREFIX_TARGET_MIRROR"
SYNC_TEST_HOT_SYNC_STAGING="$PREFIX_TARGET_STAGING"
expect_success \
  "target converges a repositoryID-sorted prefix Skillet set" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_SKILLET_STORE SYNC_TEST_SKILLET_RUNTIME_ROOT
unset SYNC_TEST_HOT_SYNC_MIRROR SYNC_TEST_HOT_SYNC_STAGING
prefix_ack="$MINI_CHANNEL/acks/$prefix_request_id.json"
[ "$(plutil -extract phase raw "$prefix_ack")" = "converged" ] \
  || fail "prefix repository set did not converge"
pass "prefix repository ids use the same deterministic order in export and consumers"

[ ! -e "$MINI_APP_SUPPORT/hot-sync-staging/$system_request_id" ] \
  || fail "committed system-pull left request staging behind"
[ ! -e "$MINI_APP_SUPPORT/hot-sync-mirror/.tatwo-sync-candidates/$system_request_id" ] \
  || fail "committed system-pull left an empty destination candidate parent behind"
pass "committed system-pull removes request-scoped transient staging"

payload_staging_root="$(
  git -C "$MINI_CHANNEL" rev-parse \
    --path-format=absolute --git-path tatwo-payload-staging
)"
mkdir -p "$payload_staging_root/orphan-request"
printf '%s\n' "interrupted payload preparation" \
  >"$payload_staging_root/orphan-request/manifest.partial"
expect_success \
  "next channel ensure archives an orphaned payload staging directory" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  role-status
assert_output "payload staging orphan recovery is explicit" \
  'archived orphaned channel payload staging：orphan-request'
[ ! -e "$payload_staging_root/orphan-request" ] \
  || fail "orphaned payload staging was not removed from the active staging root"
find "$MINI_CHANNEL/.git/tatwo-abandoned-atomic-writes" \
  -mindepth 1 -maxdepth 1 -name 'payload-staging__orphan-request-*' \
  -print -quit 2>/dev/null | grep -q . \
  || fail "orphaned payload staging produced no evidence archive"
pass "SIGKILL payload staging is recovered before later channel work"

EMPTY_SOURCE_SKILLET_STORE="$TEST_ROOT/empty-source-skillet"
EMPTY_TARGET_SKILLET_STORE="$TEST_ROOT/empty-target-skillet"
EMPTY_TARGET_SKILLET_RUNTIME="$TEST_ROOT/empty-target-skills-runtime"
EMPTY_TARGET_MIRROR="$TEST_ROOT/empty-target-hot-sync-mirror"
EMPTY_TARGET_STAGING="$TEST_ROOT/empty-target-hot-sync-staging"

before_empty_skillet_request="$(channel_commit_count)"
SYNC_TEST_SKILLET_STORE="$EMPTY_SOURCE_SKILLET_STORE"
expect_failure \
  "primary refuses a system manifest when the required Skillet set is empty" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
unset SYNC_TEST_SKILLET_STORE
assert_output "empty Skillet fail-closed names the required repository set" \
  'Skillet.*empty|Skillet.*空|repository'
[ "$(channel_commit_count)" = "$before_empty_skillet_request" ] \
  || fail "empty Skillet request mutated the hot-sync channel"
pass "empty Skillet cannot self-attest or publish a system request"

expect_success \
  "primary publishes a payload used to test forged empty Skillet import" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
empty_import_request_id="$(
  printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1
)"
[ -n "$empty_import_request_id" ] \
  || fail "forged empty Skillet import request id is missing"
empty_import_set="$BOOK_CHANNEL/payloads/$empty_import_request_id/items/skills.skillet/set.json"
empty_import_manifest="$BOOK_CHANNEL/payloads/$empty_import_request_id/manifest.json"
empty_import_request="$BOOK_CHANNEL/requests/mini/$empty_import_request_id.json"
empty_import_signature="$BOOK_CHANNEL/signatures/requests/mini/$empty_import_request_id.json"
plutil -replace repositories -json '[]' "$empty_import_set"
empty_import_set_digest="$(shasum -a 256 "$empty_import_set" | awk '{print $1}')"
empty_import_set_bytes="$(stat -f '%z' "$empty_import_set")"
plutil -replace items.3.sourceDigest -string "$empty_import_set_digest" \
  "$empty_import_manifest"
plutil -replace items.3.byteCount -integer "$empty_import_set_bytes" \
  "$empty_import_manifest"
plutil -replace items.3.repositoryCount -integer 0 "$empty_import_manifest"
empty_import_manifest_digest="$(
  shasum -a 256 "$empty_import_manifest" | awk '{print $1}'
)"
plutil -replace sourceDigest -string "$empty_import_manifest_digest" \
  "$empty_import_request"
plutil -replace manifestDigest -string "$empty_import_manifest_digest" \
  "$empty_import_request"
sign_test_artifact \
  "$BOOK_APP_SUPPORT" "sync-request" \
  "$empty_import_request" "$empty_import_signature"
git -C "$BOOK_CHANNEL" add \
  "$empty_import_set" \
  "$empty_import_manifest" \
  "$empty_import_request" \
  "$empty_import_signature"
git -C "$BOOK_CHANNEL" \
  -c user.name="Tatwo Device Sync Test" \
  -c user.email="device-sync-test@example.invalid" \
  commit -q -m "inject authority-signed empty Skillet set"
git -C "$BOOK_CHANNEL" push -q origin device-sync-channel

expect_success \
  "target rejects an authority-signed empty Skillet set before activation" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
assert_output "empty Skillet import is rejected by the shell validation gate" \
  'Skillet set repository count 必須大於 0'
[ ! -e "$MINI_APP_SUPPORT/device-sync-state/system-transactions/$empty_import_request_id" ] \
  || fail "empty Skillet import reached transaction preparation"
[ "$(plutil -extract phase raw \
    "$MINI_CHANNEL/acks/$empty_import_request_id.json")" = "failed" ] \
  || fail "empty Skillet import did not produce a failed ACK"
pass "authority-signed empty Skillet import fails closed before transaction preparation"

printf '%s\n' "# Work OS issue fixture" "measured progress must survive target restart" \
  >"$TEST_ROOT/os-canonical/issue.md"
expect_success \
  "primary publishes a request used to verify measured target progress" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
progress_request_id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"
[ -n "$progress_request_id" ] || fail "measured-progress request id is missing"

SYNC_TEST_MODE=1
SYNC_TEST_CRASH_AFTER_PROGRESS_PHASE=activating
expect_failure \
  "target exits after publishing an activating progress ACK" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_MODE SYNC_TEST_CRASH_AFTER_PROGRESS_PHASE

progress_ack="$MINI_CHANNEL/acks/$progress_request_id.json"
progress_request="$MINI_CHANNEL/requests/mini/$progress_request_id.json"
progress_manifest="$MINI_CHANNEL/payloads/$progress_request_id/manifest.json"
progress_set="$MINI_CHANNEL/payloads/$progress_request_id/items/skills.skillet/set.json"
[ "$(plutil -extract phase raw "$progress_ack")" = "activating" ] \
  || fail "interrupted request did not preserve its latest activating phase"
[ "$(plutil -extract sourceMode raw "$progress_request")" = "canonical" ] \
  && printf '%s\n' "$(plutil -extract inventoryDigest raw "$progress_request")" \
    | grep -Eq '^[0-9a-f]{64}$' \
  || fail "canonical progress request lacks explicit source provenance"
assert_source_provenance_equal \
  "progress manifest preserves the signed request source provenance" \
  "$progress_request" "$progress_manifest"
assert_source_provenance_equal \
  "progress Skillet set preserves the signed request source provenance" \
  "$progress_request" "$progress_set"
assert_source_provenance_equal \
  "non-terminal progress ACK preserves the signed request source provenance" \
  "$progress_request" "$progress_ack"
progress_completed_bytes="$(plutil -extract progress.completedBytes raw "$progress_ack")"
progress_total_bytes="$(plutil -extract progress.totalBytes raw "$progress_ack")"
[ "$progress_completed_bytes" -gt 0 ] \
  && [ "$progress_completed_bytes" -lt "$progress_total_bytes" ] \
  || fail "activating ACK must expose incomplete measured byte work"
[ "$(plutil -extract progress.completedItems raw "$progress_ack")" \
    = "$(plutil -extract progress.totalItems raw "$progress_ack")" ] \
  || fail "activating ACK must expose validated item counts"
[ "$(plutil -extract progress.completedRepositories raw "$progress_ack")" \
    = "$(plutil -extract progress.totalRepositories raw "$progress_ack")" ] \
  || fail "activating ACK must expose validated repository counts"
case "$(plutil -extract progress.elapsedMilliseconds raw "$progress_ack")" in
  ""|*[!0-9]*) fail "activating ACK elapsed time is not numeric";;
esac
case "$(plutil -extract progress.throughputBytesPerSecond raw "$progress_ack")" in
  ""|*[!0-9.]*) fail "activating ACK throughput is not numeric";;
esac
[ -n "$(plutil -extract progress.currentItem raw "$progress_ack")" ] \
  || fail "activating ACK current item is missing"
! grep -qxF "$progress_request_id" \
  "$MINI_APP_SUPPORT/device-sync-state/processed-ids-mini" \
  || fail "non-terminal activating ACK incorrectly wrote processed"
pass "measured progress remains visible and non-terminal across target restart"

expect_success \
  "target resumes an activating request and publishes terminal measured progress" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
[ "$(plutil -extract phase raw "$progress_ack")" = "converged" ] \
  || fail "resumed progress request did not converge"
[ "$(plutil -extract progress.completedBytes raw "$progress_ack")" \
    = "$(plutil -extract progress.totalBytes raw "$progress_ack")" ] \
  || fail "terminal ACK must complete measured bytes"
[ "$(plutil -extract progress.completedItems raw "$progress_ack")" \
    = "$(plutil -extract progress.totalItems raw "$progress_ack")" ] \
  || fail "terminal ACK must complete measured items"
[ "$(plutil -extract progress.completedRepositories raw "$progress_ack")" \
    = "$(plutil -extract progress.totalRepositories raw "$progress_ack")" ] \
  || fail "terminal ACK must complete measured repositories"
assert_source_provenance_equal \
  "terminal ACK preserves the signed request source provenance" \
  "$progress_request" "$progress_ack"
progress_item_count="$(plutil -extract items raw "$progress_ack")"
progress_item_index=0
while [ "$progress_item_index" -lt "$progress_item_count" ]; do
  [ "$(plutil -extract "items.$progress_item_index.progress.completedBytes" raw "$progress_ack")" \
      = "$(plutil -extract "items.$progress_item_index.progress.totalBytes" raw "$progress_ack")" ] \
    || fail "terminal item $progress_item_index lacks complete measured bytes"
  [ "$(plutil -extract "items.$progress_item_index.progress.completedItems" raw "$progress_ack")" \
      = "$(plutil -extract "items.$progress_item_index.progress.totalItems" raw "$progress_ack")" ] \
    || fail "terminal item $progress_item_index lacks complete measured item count"
  progress_item_index=$((progress_item_index + 1))
done
pass "terminal receipt and every synchronized item expose complete measured progress"

pre_skillet_failure_mirror_digest="$(shasum -a 256 "$mirror" | awk '{print $1}')"
pre_skillet_failure_alpha_digest="$(shasum -a 256 "$MINI_APP_SUPPORT/skills-runtime/alpha-skill/SKILL.md" | awk '{print $1}')"
printf '%s\n' "# Work OS issue fixture" "must rollback when Skillet set fails" \
  >"$TEST_ROOT/os-canonical/issue.md"
expect_success \
  "primary publishes a payload used to test aggregate Skillet failure rollback" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
skillet_failure_request_id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"
[ -n "$skillet_failure_request_id" ] \
  || fail "Skillet failure rollback request id is missing"

FAIL_SKILLET_CLI="$TEST_ROOT/fail-skillet-cli"
cat >"$FAIL_SKILLET_CLI" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "skillet" ] && [ "\${2:-}" = "import-activate-set" ]; then
  printf '%s\n' "injected aggregate Skillet activation failure" >&2
  exit 70
fi
exec "$SKILLET_CLI" "\$@"
EOF
chmod +x "$FAIL_SKILLET_CLI"
SYNC_TEST_SKILLET_CLI="$FAIL_SKILLET_CLI"
expect_success \
  "target fails the aggregate Skillet activation and rolls back the OS mirror" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_SKILLET_CLI
[ "$(shasum -a 256 "$mirror" | awk '{print $1}')" = "$pre_skillet_failure_mirror_digest" ] \
  || fail "Skillet activation failure did not restore the previous OS mirror"
[ "$(shasum -a 256 "$MINI_APP_SUPPORT/skills-runtime/alpha-skill/SKILL.md" | awk '{print $1}')" = "$pre_skillet_failure_alpha_digest" ] \
  || fail "aggregate Skillet activation failure changed an active repository"
skillet_failure_ack="$MINI_CHANNEL/acks/$skillet_failure_request_id.json"
[ "$(plutil -extract phase raw "$skillet_failure_ack")" = "failed" ] \
  || fail "aggregate Skillet activation failure was not marked failed"
pass "Skillet aggregate failure cannot produce partial runtime state or leave a new OS mirror active"

pre_legacy_cli_mirror_digest="$(shasum -a 256 "$mirror" | awk '{print $1}')"
pre_legacy_cli_alpha_digest="$(
  shasum -a 256 "$MINI_APP_SUPPORT/skills-runtime/alpha-skill/SKILL.md" \
    | awk '{print $1}'
)"
printf '%s\n' "# Work OS issue fixture" \
  "must rollback when the Skillet CLI lacks runtime-closure capability evidence" \
  >"$TEST_ROOT/os-canonical/issue.md"
expect_success \
  "primary publishes a payload used to test stale Skillet CLI fail-closed behavior" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
legacy_cli_request_id="$(
  printf '%s\n' "$LAST_OUTPUT" \
    | sed -n 's/^SYNC_REQUEST_ID=//p' \
    | tail -1
)"
[ -n "$legacy_cli_request_id" ] \
  || fail "stale Skillet CLI request id is missing"

LEGACY_SKILLET_CLI="$TEST_ROOT/legacy-skillet-cli"
cat >"$LEGACY_SKILLET_CLI" <<EOF
#!/usr/bin/env bash
set -euo pipefail
receipt=""
args=("\$@")
index=0
while [ "\$index" -lt "\${#args[@]}" ]; do
  if [ "\${args[\$index]}" = "--receipt" ]; then
    receipt="\${args[\$((index + 1))]}"
    break
  fi
  index=\$((index + 1))
done
"$SKILLET_CLI" "\${args[@]}"
if [ "\${1:-}" = "skillet" ] \
  && { [ "\${2:-}" = "import-activate-set" ] \
    || [ "\${2:-}" = "verify-active-set" ]; } \
  && [ -n "\$receipt" ]
then
  python3 - "\$receipt" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
receipt = json.loads(path.read_text())
receipt.pop("targetPreservedRuntimeClosureCapability", None)
receipt.pop("targetPreservedRuntimeClosed", None)
path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
PY
fi
EOF
chmod +x "$LEGACY_SKILLET_CLI"
SYNC_TEST_SKILLET_CLI="$LEGACY_SKILLET_CLI"
expect_success \
  "target rejects a stale CLI receipt and rolls back before convergence" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_SKILLET_CLI
[ "$(shasum -a 256 "$mirror" | awk '{print $1}')" \
    = "$pre_legacy_cli_mirror_digest" ] \
  || fail "stale CLI capability failure did not restore the previous OS mirror"
[ "$(shasum -a 256 "$MINI_APP_SUPPORT/skills-runtime/alpha-skill/SKILL.md" \
      | awk '{print $1}')" = "$pre_legacy_cli_alpha_digest" ] \
  || fail "stale CLI capability failure changed an active repository"
legacy_cli_ack="$MINI_CHANNEL/acks/$legacy_cli_request_id.json"
[ "$(plutil -extract phase raw "$legacy_cli_ack")" = "failed" ] \
  || fail "stale CLI capability failure was not marked failed"
[ "$(plutil -extract result raw "$legacy_cli_ack")" = "error" ] \
  || fail "stale CLI capability failure did not publish result=error"
pass "missing runtime-closure capability evidence can never produce converged"

processed_file="$MINI_APP_SUPPORT/device-sync-state/processed-ids-mini"
replay_request_id="$progress_request_id"
replay_transaction_journal="$MINI_APP_SUPPORT/device-sync-state/system-transactions/$replay_request_id/journal.json"
replay_transaction_digest_before="$(shasum -a 256 "$replay_transaction_journal" | awk '{print $1}')"
grep -vxF "$replay_request_id" "$processed_file" >"${processed_file}.tmp" || true
mv "${processed_file}.tmp" "$processed_file"
replay_activation_marker="$TEST_ROOT/replay-activation-marker"
SYNC_TEST_MODE=1
SYNC_TEST_BEFORE_ACTIVATE_HOOK="printf '%s\n' 'unexpected replay activation' > '$replay_activation_marker'"
expect_success \
  "target replays a request that already has a bound ACK" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_MODE SYNC_TEST_BEFORE_ACTIVATE_HOOK
[ ! -e "$replay_activation_marker" ] \
  || fail "ACK replay executed the activation path a second time"
grep -qxF "$replay_request_id" "$processed_file" \
  || fail "ACK replay did not restore the local processed receipt"
[ "$(shasum -a 256 "$replay_transaction_journal" | awk '{print $1}')" = "$replay_transaction_digest_before" ] \
  || fail "terminal ACK replay mutated the attested committed transaction journal"
grep -vxF "$replay_request_id" "$processed_file" >"${processed_file}.tmp" || true
mv "${processed_file}.tmp" "$processed_file"
expect_success \
  "target replays the same terminal ACK a second time" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
grep -qxF "$replay_request_id" "$processed_file" \
  || fail "second terminal ACK replay did not restore the local processed receipt"
[ "$(shasum -a 256 "$replay_transaction_journal" | awk '{print $1}')" = "$replay_transaction_digest_before" ] \
  || fail "second terminal ACK replay mutated the attested committed transaction journal"
pass "existing bound ACK makes repeated request replay activation-idempotent"

PRESEED_REMOTE="$TEST_ROOT/channel-preseed.git"
PRESEED_APP_SUPPORT="$TEST_ROOT/app-support-preseed"
PRESEED_CHANNEL="$TEST_ROOT/channel-preseed"
PRESEED_QUARANTINE="$TEST_ROOT/preseed-local-state"
PRESEED_HOME="$TEST_ROOT/home-preseed"
cp -R "$REMOTE" "$PRESEED_REMOTE"
cp -R "$MINI_APP_SUPPORT" "$PRESEED_APP_SUPPORT"
mkdir -p "$PRESEED_QUARANTINE"
for local_state in \
  hot-sync-mirror \
  skillet \
  skills-runtime \
  skills-consumer
do
  if [ -e "$PRESEED_APP_SUPPORT/$local_state" ]; then
    mv "$PRESEED_APP_SUPPORT/$local_state" "$PRESEED_QUARANTINE/$local_state"
  fi
done
if [ -e "$PRESEED_APP_SUPPORT/device-sync-state/system-transactions/$system_request_id" ]; then
  mv "$PRESEED_APP_SUPPORT/device-sync-state/system-transactions/$system_request_id" \
    "$PRESEED_QUARANTINE/system-transaction-$system_request_id"
fi
if [ -e "$PRESEED_APP_SUPPORT/device-sync-state/skills-consumer-projection-receipts" ]; then
  mv "$PRESEED_APP_SUPPORT/device-sync-state/skills-consumer-projection-receipts" \
    "$PRESEED_QUARANTINE/skills-consumer-projection-receipts"
fi
bootstrap_skills_consumer_projection \
  "$PRESEED_HOME" "$PRESEED_APP_SUPPORT" "$TEST_ROOT/skills"
preseed_processed="$PRESEED_APP_SUPPORT/device-sync-state/processed-ids-mini"
grep -vxF "$system_request_id" "$preseed_processed" >"${preseed_processed}.tmp" || true
mv "${preseed_processed}.tmp" "$preseed_processed"

SYNC_TEST_CHANNEL_REMOTE="$PRESEED_REMOTE"
expect_success \
  "target inspects a channel ACK after its local committed evidence is absent" \
  run_sync mini "$PRESEED_HOME" "$PRESEED_APP_SUPPORT" "$PRESEED_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_CHANNEL_REMOTE
if grep -qxF "$system_request_id" "$preseed_processed"; then
  fail "channel-only system ACK was accepted as a local processed receipt"
fi
grep -qxF "$system_request_id" "$PRESEED_APP_SUPPORT/device-sync-state/rejected-ids-mini" \
  || fail "channel-only system ACK was not recorded as rejected"
assert_output "channel-only ACK rejection names missing local attestation" \
  '本機 committed transaction|local attestation|target-local'
pass "channel ACK cannot replace target-local committed system evidence"

VALIDATING_REMOTE="$TEST_ROOT/channel-validating.git"
VALIDATING_SEED="$TEST_ROOT/channel-validating-seed"
VALIDATING_APP_SUPPORT="$TEST_ROOT/app-support-validating"
VALIDATING_CHANNEL="$TEST_ROOT/channel-validating"
VALIDATING_QUARANTINE="$TEST_ROOT/validating-local-state"
VALIDATING_HOME="$TEST_ROOT/home-validating"
validating_request_id="$skillet_failure_request_id"
cp -R "$REMOTE" "$VALIDATING_REMOTE"
git clone -q "$VALIDATING_REMOTE" "$VALIDATING_SEED"
git -C "$VALIDATING_SEED" checkout -q device-sync-channel
validating_request_digest="$(
  plutil -extract sourceDigest raw \
    "$VALIDATING_SEED/requests/mini/$validating_request_id.json"
)"
plutil -replace phase -string validating \
  "$VALIDATING_SEED/acks/$validating_request_id.json"
plutil -replace result -string partial \
  "$VALIDATING_SEED/acks/$validating_request_id.json"
plutil -replace digestAlgorithm -string sha256 \
  "$VALIDATING_SEED/acks/$validating_request_id.json"
plutil -replace sourceDigest -string "$validating_request_digest" \
  "$VALIDATING_SEED/acks/$validating_request_id.json"
plutil -replace appliedDigest -string "" \
  "$VALIDATING_SEED/acks/$validating_request_id.json"
validating_total_bytes="$(
  plutil -extract progress.totalBytes raw \
    "$VALIDATING_SEED/acks/$validating_request_id.json"
)"
plutil -replace progress.completedBytes -integer "$((validating_total_bytes * 2 / 3))" \
  "$VALIDATING_SEED/acks/$validating_request_id.json"
plutil -replace progress.currentItem -string "request-bound payload validation" \
  "$VALIDATING_SEED/acks/$validating_request_id.json"
sign_test_artifact \
  "$MINI_APP_SUPPORT" "sync-ack" \
  "$VALIDATING_SEED/acks/$validating_request_id.json" \
  "$VALIDATING_SEED/signatures/acks/$validating_request_id.json"
git -C "$VALIDATING_SEED" add \
  "acks/$validating_request_id.json" \
  "signatures/acks/$validating_request_id.json"
git -C "$VALIDATING_SEED" \
  -c user.name="Tatwo Device Sync Test" \
  -c user.email="device-sync-test@example.invalid" \
  commit -q -m "inject non-terminal validating ACK"
git -C "$VALIDATING_SEED" push -q origin device-sync-channel
cp -R "$MINI_APP_SUPPORT" "$VALIDATING_APP_SUPPORT"
mkdir -p "$VALIDATING_QUARANTINE"
for local_state in \
  hot-sync-mirror \
  skillet \
  skills-runtime \
  skills-consumer
do
  if [ -e "$VALIDATING_APP_SUPPORT/$local_state" ]; then
    mv "$VALIDATING_APP_SUPPORT/$local_state" "$VALIDATING_QUARANTINE/$local_state"
  fi
done
if [ -e "$VALIDATING_APP_SUPPORT/device-sync-state/system-transactions/$validating_request_id" ]; then
  mv "$VALIDATING_APP_SUPPORT/device-sync-state/system-transactions/$validating_request_id" \
    "$VALIDATING_QUARANTINE/system-transaction-$validating_request_id"
fi
if [ -e "$VALIDATING_APP_SUPPORT/.tatwo-sync-store-rollback/$validating_request_id" ]; then
  mv "$VALIDATING_APP_SUPPORT/.tatwo-sync-store-rollback/$validating_request_id" \
    "$VALIDATING_QUARANTINE/store-rollback-$validating_request_id"
fi
if [ -e "$VALIDATING_APP_SUPPORT/device-sync-state/skills-consumer-projection-receipts" ]; then
  mv "$VALIDATING_APP_SUPPORT/device-sync-state/skills-consumer-projection-receipts" \
    "$VALIDATING_QUARANTINE/skills-consumer-projection-receipts"
fi
bootstrap_skills_consumer_projection \
  "$VALIDATING_HOME" "$VALIDATING_APP_SUPPORT" "$TEST_ROOT/skills"
validating_processed="$VALIDATING_APP_SUPPORT/device-sync-state/processed-ids-mini"
grep -vxF "$validating_request_id" "$validating_processed" >"${validating_processed}.tmp" || true
mv "${validating_processed}.tmp" "$validating_processed"

SYNC_TEST_CHANNEL_REMOTE="$VALIDATING_REMOTE"
SYNC_TEST_RETENTION_MAX_ENTRIES=0
expect_success \
  "retention-full target preserves a bound non-terminal validating ACK without executing" \
  run_sync mini "$VALIDATING_HOME" "$VALIDATING_APP_SUPPORT" "$VALIDATING_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_RETENTION_MAX_ENTRIES
if grep -qxF "$validating_request_id" "$validating_processed"; then
  fail "validating ACK incorrectly terminated the system request"
fi
if grep -qxF "$validating_request_id" \
  "$VALIDATING_APP_SUPPORT/device-sync-state/rejected-ids-mini" 2>/dev/null
then
  fail "bound validating ACK was incorrectly added to rejected state"
fi
pass "validating ACK remains retryable and cannot write processed"

expect_success \
  "target rejects a historical request even when it has a bound validating ACK" \
  run_sync mini "$VALIDATING_HOME" "$VALIDATING_APP_SUPPORT" "$VALIDATING_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_CHANNEL_REMOTE
[ "$(plutil -extract phase raw "$VALIDATING_CHANNEL/acks/$validating_request_id.json")" = "validating" ] \
  || fail "historical validating ACK was allowed to advance"
grep -qxF "$validating_request_id" \
  "$VALIDATING_APP_SUPPORT/device-sync-state/rejected-ids-mini" \
  || fail "historical validating request was not recorded as rejected"
! grep -qxF "$validating_request_id" "$validating_processed" \
  || fail "historical validating request was incorrectly marked processed"
assert_output "historical bound ACK cannot bypass the monotonic request ledger" \
  '同 epoch request ledger 倒退或衝突'
pass "historical non-terminal ACK fails closed instead of reapplying stale state"

pre_skillet_authority_mirror_digest="$(shasum -a 256 "$mirror" | awk '{print $1}')"
pre_skillet_authority_alpha_digest="$(shasum -a 256 "$MINI_APP_SUPPORT/skills-runtime/alpha-skill/SKILL.md" | awk '{print $1}')"
printf '%s\n' "# Work OS issue fixture" "must re-check authority before Skillet activation" \
  >"$TEST_ROOT/os-canonical/issue.md"
expect_success \
  "primary publishes a payload used to test authority transfer between OS and Skillet activation" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
pre_skillet_authority_request_id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"
[ -n "$pre_skillet_authority_request_id" ] \
  || fail "pre-Skillet authority request id is missing"

SYNC_TEST_MODE=1
SYNC_TEST_BEFORE_SKILLET_ACTIVATE_HOOK="git -C '$BOOK_CHANNEL' fetch -q origin device-sync-channel
git -C '$BOOK_CHANNEL' rebase origin/device-sync-channel >/dev/null
cat > '$BOOK_CHANNEL/primary.json' <<'EOF'
{
  \"name\": \"mini\",
  \"epoch\": 3,
  \"changedAt\": \"2026-07-23T12:05:00Z\"
}
EOF
git -C '$BOOK_CHANNEL' add primary.json
git -C '$BOOK_CHANNEL' -c user.name='Tatwo Device Sync Test' -c user.email='device-sync-test@example.invalid' commit -q -m 'transfer before Skillet activation'
git -C '$BOOK_CHANNEL' push -q origin device-sync-channel"
expect_success \
  "target refuses Skillet activation when authority changes after OS mirror activation" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_MODE SYNC_TEST_BEFORE_SKILLET_ACTIVATE_HOOK

[ "$(shasum -a 256 "$mirror" | awk '{print $1}')" = "$pre_skillet_authority_mirror_digest" ] \
  || fail "authority transfer before Skillet activation left a stale OS mirror active"
[ "$(shasum -a 256 "$MINI_APP_SUPPORT/skills-runtime/alpha-skill/SKILL.md" | awk '{print $1}')" = "$pre_skillet_authority_alpha_digest" ] \
  || fail "authority transfer before Skillet activation changed an active repository"
pre_skillet_authority_ack="$MINI_CHANNEL/acks/$pre_skillet_authority_request_id.json"
[ "$(plutil -extract phase raw "$pre_skillet_authority_ack")" = "diverged" ] \
  || fail "authority transfer before Skillet activation must terminate visible progress as diverged"
grep -qxF "$pre_skillet_authority_request_id" "$MINI_APP_SUPPORT/device-sync-state/rejected-ids-mini" \
  || fail "authority transfer before Skillet activation was not recorded as rejected"
pass "authority is re-read between OS mirror activation and Skillet activation"

expect_success \
  "new primary restores authority to book after pre-Skillet transfer test" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  set-primary --name book --expected-epoch 3

pre_corruption_mirror_digest="$(shasum -a 256 "$mirror" | awk '{print $1}')"
printf '%s\n' "# Work OS issue fixture" "must rollback after post-activation corruption" \
  >"$TEST_ROOT/os-canonical/issue.md"
expect_success \
  "primary publishes a payload used to test post-activation rollback" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
post_activation_request_id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"
[ -n "$post_activation_request_id" ] \
  || fail "post-activation rollback request id is missing"

SYNC_TEST_MODE=1
SYNC_TEST_AFTER_ACTIVATE_HOOK="printf '%s\n' 'corrupted after activation' > '$MINI_APP_SUPPORT/hot-sync-mirror/os/issue.md'"
expect_success \
  "target quarantines a corrupted activated mirror and restores the previous set" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_MODE SYNC_TEST_AFTER_ACTIVATE_HOOK

[ "$(shasum -a 256 "$mirror" | awk '{print $1}')" = "$pre_corruption_mirror_digest" ] \
  || fail "post-activation corruption did not restore the previous active mirror"
failed_activation="$(find \
  "$MINI_APP_SUPPORT/hot-sync-mirror/.tatwo-sync-failed/$post_activation_request_id" \
  -mindepth 2 -maxdepth 2 -type f -path '*/os-current-*/issue.md' \
  -print -quit 2>/dev/null || true)"
[ -f "$failed_activation" ] \
  || fail "post-activation corrupted mirror was not quarantined"
grep -qxF "corrupted after activation" "$failed_activation" \
  || fail "quarantined mirror does not contain the injected corruption"
post_activation_ack="$MINI_CHANNEL/acks/$post_activation_request_id.json"
[ -f "$post_activation_ack" ] \
  || fail "post-activation corruption did not produce a failed ACK"
[ "$(plutil -extract phase raw "$post_activation_ack")" = "failed" ] \
  || fail "post-activation corruption was not marked failed"
pass "post-activation digest failure quarantines the new mirror and rolls back atomically"

expect_success \
  "primary publishes a payload used to test strict SHA-256 validation" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
malformed_digest_request_id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"
malformed_digest_manifest="$BOOK_CHANNEL/payloads/$malformed_digest_request_id/manifest.json"
malformed_digest_request="$BOOK_CHANNEL/requests/mini/$malformed_digest_request_id.json"
valid_manifest_digest="$(shasum -a 256 "$malformed_digest_manifest" | awk '{print $1}')"
malformed_manifest_digest="${valid_manifest_digest%????????}zzzzzzzz"
plutil -replace manifestDigest -string "$malformed_manifest_digest" "$malformed_digest_request"
malformed_digest_signature="$BOOK_CHANNEL/signatures/requests/mini/$malformed_digest_request_id.json"
sign_test_artifact \
  "$BOOK_APP_SUPPORT" "sync-request" \
  "$malformed_digest_request" "$malformed_digest_signature"
git -C "$BOOK_CHANNEL" add "$malformed_digest_request" "$malformed_digest_signature"
git -C "$BOOK_CHANNEL" \
  -c user.name="Tatwo Device Sync Test" \
  -c user.email="device-sync-test@example.invalid" \
  commit -q -m "inject malformed sha256 request digest"
git -C "$BOOK_CHANNEL" push -q origin device-sync-channel

expect_success \
  "secondary rejects a 64-character non-hex SHA-256 value" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
malformed_digest_ack="$MINI_CHANNEL/acks/$malformed_digest_request_id.json"
[ -f "$malformed_digest_ack" ] \
  || fail "malformed digest request did not produce an explicit failed ACK"
[ "$(plutil -extract phase raw "$malformed_digest_ack")" = "failed" ] \
  || fail "malformed digest request was not marked failed"
pass "SHA-256 validation rejects non-hex suffixes instead of checking only length"

old_mirror_digest="$(shasum -a 256 "$mirror" | awk '{print $1}')"
printf '%s\n' "# Work OS issue fixture" "must not activate after epoch transfer" \
  >"$TEST_ROOT/os-canonical/issue.md"
expect_success \
  "primary publishes system payload before a mid-transfer authority switch" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
mid_transfer_request_id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"

SYNC_TEST_MODE=1
SYNC_TEST_BEFORE_ACTIVATE_HOOK="git -C '$BOOK_CHANNEL' fetch -q origin device-sync-channel
git -C '$BOOK_CHANNEL' rebase origin/device-sync-channel >/dev/null
cat > '$BOOK_CHANNEL/primary.json' <<'EOF'
{
  \"name\": \"mini\",
  \"epoch\": 5,
  \"changedAt\": \"2026-07-23T12:10:00Z\"
}
EOF
git -C '$BOOK_CHANNEL' add primary.json
git -C '$BOOK_CHANNEL' -c user.name='Tatwo Device Sync Test' -c user.email='device-sync-test@example.invalid' commit -q -m 'transfer during target staging'
git -C '$BOOK_CHANNEL' push -q origin device-sync-channel"
expect_success \
  "target stages but refuses activation after authority changes mid-transfer" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_MODE SYNC_TEST_BEFORE_ACTIVATE_HOOK

[ "$(shasum -a 256 "$mirror" | awk '{print $1}')" = "$old_mirror_digest" ] \
  || fail "mid-transfer stale request replaced the active os.issue mirror"
mid_transfer_ack="$MINI_CHANNEL/acks/$mid_transfer_request_id.json"
[ "$(plutil -extract phase raw "$mid_transfer_ack")" = "diverged" ] \
  || fail "mid-transfer authority switch must terminate visible progress as diverged"
grep -qxF "$mid_transfer_request_id" "$MINI_APP_SUPPORT/device-sync-state/rejected-ids-mini" \
  || fail "mid-transfer stale request was not recorded as rejected"
pass "authority is re-read immediately before atomic mirror activation"

expect_success \
  "new primary restores authority to book after mid-transfer test" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  set-primary --name book --expected-epoch 5

expect_success \
  "primary creates a request that will become stale after authority transfer" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target book --action system-pull
stale_request_id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"

expect_success \
  "book transfers authority to mini before stale request execution" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  set-primary --name mini --expected-epoch 6

expect_success \
  "old primary polls without executing stale epoch request" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-poll --device book
[ ! -f "$BOOK_CHANNEL/acks/$stale_request_id.json" ] \
  || fail "stale epoch request produced an ACK"
grep -qxF "$stale_request_id" "$BOOK_APP_SUPPORT/device-sync-state/rejected-ids-book" \
  || fail "stale epoch request was not recorded as rejected"
pass "stale authority epoch request is rejected before transfer"

expect_success \
  "new primary transfers authority back to book" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  set-primary --name book --expected-epoch 7

pre_old_move_crash_digest="$(shasum -a 256 "$MINI_APP_SUPPORT/hot-sync-mirror/os/issue.md" | awk '{print $1}')"
printf '%s\n' "# Work OS issue fixture" "old mirror must survive pre-move process exit" \
  >"$TEST_ROOT/os-canonical/issue.md"
expect_success \
  "primary publishes a request used to test the old-mirror move crash window" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
old_move_crash_request_id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"
[ -n "$old_move_crash_request_id" ] \
  || fail "old-mirror move crash request id is missing"

SYNC_TEST_MODE=1
SYNC_TEST_CRASH_BEFORE_OLD_MIRROR_MOVE=1
expect_failure \
  "target process exits after durable move intent but before moving the old mirror" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_MODE SYNC_TEST_CRASH_BEFORE_OLD_MIRROR_MOVE
old_move_crash_journal="$MINI_APP_SUPPORT/device-sync-state/system-transactions/$old_move_crash_request_id/journal.json"
[ "$(plutil -extract phase raw "$old_move_crash_journal")" = "oldMirrorMoveStarted" ] \
  || fail "old-mirror move crash did not persist its exact durable phase"
[ "$(shasum -a 256 "$MINI_APP_SUPPORT/hot-sync-mirror/os/issue.md" | awk '{print $1}')" = "$pre_old_move_crash_digest" ] \
  || fail "pre-move process exit changed the healthy old OS mirror"
[ ! -e "$MINI_APP_SUPPORT/hot-sync-mirror/.tatwo-sync-rollback/$old_move_crash_request_id/os" ] \
  || fail "pre-move process exit unexpectedly created an OS rollback snapshot"
pass "durable move intent distinguishes the still-active old mirror"

expect_success \
  "next poll preserves the old mirror then safely retries the interrupted request" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
assert_output "pre-move recovery is explicit" \
  '舊 OS mirror 尚未移動|old mirror move had not completed'
[ "$(plutil -extract phase raw "$MINI_CHANNEL/acks/$old_move_crash_request_id.json")" = "converged" ] \
  || fail "pre-move interrupted request did not converge after safe retry"
grep -qxF "old mirror must survive pre-move process exit" \
  "$MINI_APP_SUPPORT/hot-sync-mirror/os/issue.md" \
  || fail "safe retry did not activate the new OS mirror"
find "$MINI_APP_SUPPORT/hot-sync-mirror/.tatwo-sync-candidate-history" \
  -mindepth 1 -maxdepth 1 -type d \
  -name "$old_move_crash_request_id-old-mirror-candidate-*" \
  -print -quit 2>/dev/null | grep -q . \
  || fail "pre-move recovery did not preserve the staged candidate in the historical root"
[ ! -e "$MINI_APP_SUPPORT/hot-sync-mirror/.tatwo-sync-candidates/$old_move_crash_request_id" ] \
  || fail "pre-move recovery left the request candidate parent active after convergence"
pass "pre-move crash recovery never quarantines the healthy old mirror"

pre_path_drift_os_digest="$(shasum -a 256 "$MINI_APP_SUPPORT/hot-sync-mirror/os/issue.md" | awk '{print $1}')"
pre_path_drift_runtime_digest="$(shasum -a 256 "$MINI_APP_SUPPORT/skills-runtime/alpha-skill/SKILL.md" | awk '{print $1}')"
printf '%s\n' "# Work OS issue fixture" "recovery must use transaction-recorded paths" \
  >"$TEST_ROOT/os-canonical/issue.md"
expect_success \
  "primary publishes a request used to test recovery path identity" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
path_drift_request_id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"
[ -n "$path_drift_request_id" ] \
  || fail "path-drift request id is missing"

SYNC_TEST_MODE=1
SYNC_TEST_CRASH_AFTER_OS_ACTIVATE=1
expect_failure \
  "target exits after OS activation before recovery path variables drift" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_MODE SYNC_TEST_CRASH_AFTER_OS_ACTIVATE
printf '%s\n' "$path_drift_request_id" \
  >>"$MINI_APP_SUPPORT/device-sync-state/rejected-ids-mini"

DRIFT_ROOT="$TEST_ROOT/path-drift-current-environment"
DRIFT_MIRROR="$DRIFT_ROOT/hot-sync-mirror"
DRIFT_STORE="$DRIFT_ROOT/skillet"
DRIFT_RUNTIME="$DRIFT_ROOT/skills-runtime"
DRIFT_STAGING="$DRIFT_ROOT/hot-sync-staging"
mkdir -p "$DRIFT_MIRROR/os" "$DRIFT_STORE" "$DRIFT_RUNTIME/local-sentinel" "$DRIFT_STAGING"
printf '%s\n' "unrelated current-environment mirror" >"$DRIFT_MIRROR/os/issue.md"
printf '%s\n' "unrelated current-environment store" >"$DRIFT_STORE/KEEP"
printf '%s\n' "unrelated current-environment runtime" >"$DRIFT_RUNTIME/local-sentinel/KEEP"

SYNC_TEST_HOT_SYNC_MIRROR="$DRIFT_MIRROR"
SYNC_TEST_HOT_SYNC_STAGING="$DRIFT_STAGING"
SYNC_TEST_SKILLET_STORE="$DRIFT_STORE"
SYNC_TEST_SKILLET_RUNTIME_ROOT="$DRIFT_RUNTIME"
expect_success \
  "recovery runs after launch environment paths change" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_HOT_SYNC_MIRROR SYNC_TEST_HOT_SYNC_STAGING
unset SYNC_TEST_SKILLET_STORE SYNC_TEST_SKILLET_RUNTIME_ROOT
[ "$(shasum -a 256 "$MINI_APP_SUPPORT/hot-sync-mirror/os/issue.md" | awk '{print $1}')" = "$pre_path_drift_os_digest" ] \
  || fail "path-drift recovery did not restore the transaction-recorded OS mirror"
[ "$(shasum -a 256 "$MINI_APP_SUPPORT/skills-runtime/alpha-skill/SKILL.md" | awk '{print $1}')" = "$pre_path_drift_runtime_digest" ] \
  || fail "path-drift recovery did not restore the transaction-recorded runtime"
grep -qxF "unrelated current-environment mirror" "$DRIFT_MIRROR/os/issue.md" \
  || fail "path-drift recovery touched the current environment's unrelated mirror"
grep -qxF "unrelated current-environment store" "$DRIFT_STORE/KEEP" \
  || fail "path-drift recovery touched the current environment's unrelated store"
grep -qxF "unrelated current-environment runtime" "$DRIFT_RUNTIME/local-sentinel/KEEP" \
  || fail "path-drift recovery touched the current environment's unrelated runtime"
pass "recovery is bound to transaction-recorded paths, not current environment variables"

pre_crash_os_digest="$(shasum -a 256 "$MINI_APP_SUPPORT/hot-sync-mirror/os/issue.md" | awk '{print $1}')"
pre_crash_runtime_digest="$(shasum -a 256 "$MINI_APP_SUPPORT/skills-runtime/alpha-skill/SKILL.md" | awk '{print $1}')"
printf '%s\n' "# Work OS issue fixture" "durable recovery after process crash" \
  >"$TEST_ROOT/os-canonical/issue.md"
expect_success \
  "primary publishes a request used to test crash recovery" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
crash_recovery_request_id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"
[ -n "$crash_recovery_request_id" ] \
  || fail "crash recovery request id is missing"

SYNC_TEST_MODE=1
SYNC_TEST_CRASH_AFTER_OS_ACTIVATE=1
expect_failure \
  "target process crashes after OS activation and before Skillet activation" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_MODE SYNC_TEST_CRASH_AFTER_OS_ACTIVATE
[ "$(plutil -extract phase raw "$MINI_APP_SUPPORT/device-sync-state/system-transactions/$crash_recovery_request_id/journal.json")" = "osActive" ] \
  || fail "crashed transaction did not persist its last durable phase"
[ "$(shasum -a 256 "$MINI_APP_SUPPORT/skills-runtime/alpha-skill/SKILL.md" | awk '{print $1}')" = "$pre_crash_runtime_digest" ] \
  || fail "crash hook unexpectedly activated Skillet before recovery"
assert_no_terminal_ack \
  "$MINI_CHANNEL/acks/$crash_recovery_request_id.json" \
  "crash after OS activation must not publish a terminal ACK"
pass "crash leaves a durable journal instead of a false ACK"

SYNC_TEST_MODE=1
SYNC_TEST_CRASH_DURING_ROLLBACK_AFTER_OS=1
expect_failure \
  "recovery process exits after restoring the OS mirror but before store/runtime rollback" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_MODE SYNC_TEST_CRASH_DURING_ROLLBACK_AFTER_OS
[ "$(shasum -a 256 "$MINI_APP_SUPPORT/hot-sync-mirror/os/issue.md" | awk '{print $1}')" = "$pre_crash_os_digest" ] \
  || fail "interrupted rollback did not restore the previous OS mirror before exit"
assert_no_terminal_ack \
  "$MINI_CHANNEL/acks/$crash_recovery_request_id.json" \
  "interrupted rollback must not publish a terminal ACK"
pass "rollback interruption leaves restored OS state and no false ACK"

expect_success \
  "next poll resumes the interrupted rollback and replays it safely" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
assert_output "recovery is visible in the target log" \
  'durable journal|未完成的 system transaction|回復前一版'
crash_recovery_ack="$MINI_CHANNEL/acks/$crash_recovery_request_id.json"
[ "$(plutil -extract phase raw "$crash_recovery_ack")" = "converged" ] \
  || fail "replayed transaction did not converge after durable recovery"
find "$MINI_APP_SUPPORT/device-sync-state/system-transaction-history" \
  -mindepth 1 -maxdepth 1 -type d -name "$crash_recovery_request_id-*" \
  -print -quit | grep -q . \
  || fail "rolled-back crash attempt was not archived for inspection"
pass "power-loss style split state is rolled back and retried from the same request"

pre_journal_create_os_digest="$(shasum -a 256 "$MINI_APP_SUPPORT/hot-sync-mirror/os/issue.md" | awk '{print $1}')"
pre_journal_create_runtime_digest="$(shasum -a 256 "$MINI_APP_SUPPORT/skills-runtime/alpha-skill/SKILL.md" | awk '{print $1}')"
printf '%s\n' "# Work OS issue fixture" "journal directory creation must be recoverable" \
  >"$TEST_ROOT/os-canonical/issue.md"
expect_success \
  "primary publishes a request used to test initial journal creation interruption" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
journal_create_request_id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"
[ -n "$journal_create_request_id" ] \
  || fail "journal creation crash request id is missing"

SYNC_TEST_MODE=1
SYNC_TEST_CRASH_AFTER_TRANSACTION_STAGE_CREATE=1
expect_failure \
  "target exits after creating transaction preparation metadata but before journal publication" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_MODE SYNC_TEST_CRASH_AFTER_TRANSACTION_STAGE_CREATE
[ ! -e "$MINI_APP_SUPPORT/device-sync-state/system-transactions/$journal_create_request_id" ] \
  || fail "initial journal interruption exposed a final transaction directory"
find "$MINI_APP_SUPPORT/device-sync-state/system-transactions" \
  -mindepth 1 -maxdepth 1 -type d -name ".preparing-$journal_create_request_id-*" \
  -print -quit | grep -q . \
  || fail "initial journal interruption did not leave identifiable preparation metadata"
[ "$(shasum -a 256 "$MINI_APP_SUPPORT/hot-sync-mirror/os/issue.md" | awk '{print $1}')" = "$pre_journal_create_os_digest" ] \
  || fail "initial journal interruption changed the active OS mirror"
[ "$(shasum -a 256 "$MINI_APP_SUPPORT/skills-runtime/alpha-skill/SKILL.md" | awk '{print $1}')" = "$pre_journal_create_runtime_digest" ] \
  || fail "initial journal interruption changed an active runtime"
pass "journal creation interruption remains distinguishable from live activation"

expect_success \
  "next poll archives abandoned preparation metadata and safely retries" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
assert_output "abandoned journal preparation recovery is visible" \
  'abandoned transaction preparation|未發布 journal'
find "$MINI_APP_SUPPORT/device-sync-state/system-transactions" \
  -mindepth 1 -maxdepth 1 -type d -name ".preparing-$journal_create_request_id-*" \
  -print -quit | grep -q . \
  && fail "abandoned preparation metadata remained in the active transaction root"
[ "$(plutil -extract phase raw "$MINI_CHANNEL/acks/$journal_create_request_id.json")" = "converged" ] \
  || fail "journal-create interrupted request did not converge after safe retry"
pass "journal publication is atomic before any rollback snapshot copy"

pre_prepare_os_digest="$(shasum -a 256 "$MINI_APP_SUPPORT/hot-sync-mirror/os/issue.md" | awk '{print $1}')"
pre_prepare_runtime_digest="$(shasum -a 256 "$MINI_APP_SUPPORT/skills-runtime/alpha-skill/SKILL.md" | awk '{print $1}')"
printf '%s\n' "# Work OS issue fixture" "transaction prepare interruption must not touch live state" \
  >"$TEST_ROOT/os-canonical/issue.md"
expect_success \
  "primary publishes a request used to test transaction prepare interruption" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
prepare_crash_request_id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"
[ -n "$prepare_crash_request_id" ] \
  || fail "prepare crash request id is missing"

SYNC_TEST_MODE=1
SYNC_TEST_CRASH_DURING_TRANSACTION_PREPARE=1
expect_failure \
  "target process exits after durable preparing journal but before backup completion" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_MODE SYNC_TEST_CRASH_DURING_TRANSACTION_PREPARE
prepare_crash_journal="$MINI_APP_SUPPORT/device-sync-state/system-transactions/$prepare_crash_request_id/journal.json"
[ "$(plutil -extract phase raw "$prepare_crash_journal")" = "preparing" ] \
  || fail "prepare interruption did not leave a durable preparing journal"
[ "$(shasum -a 256 "$MINI_APP_SUPPORT/hot-sync-mirror/os/issue.md" | awk '{print $1}')" = "$pre_prepare_os_digest" ] \
  || fail "transaction prepare interruption changed the active OS mirror"
[ "$(shasum -a 256 "$MINI_APP_SUPPORT/skills-runtime/alpha-skill/SKILL.md" | awk '{print $1}')" = "$pre_prepare_runtime_digest" ] \
  || fail "transaction prepare interruption changed an active runtime"
pass "preparing journal distinguishes backup work from live activation"

expect_success \
  "next poll archives interrupted preparation and safely retries the request" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
assert_output "prepare recovery is visible in the target log" \
  '尚未開始 live activation|partial preparation'
prepare_crash_ack="$MINI_CHANNEL/acks/$prepare_crash_request_id.json"
[ "$(plutil -extract phase raw "$prepare_crash_ack")" = "converged" ] \
  || fail "prepare-interrupted request did not converge after safe retry"
pass "interrupted backup preparation is archived and replayed without rollbacking live state"

printf '%s\n' "# Work OS issue fixture" "committed state must survive a pre-ACK process exit" \
  >"$TEST_ROOT/os-canonical/issue.md"
expect_success \
  "primary publishes a request used to test committed pre-ACK recovery" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
committed_replay_request_id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"
[ -n "$committed_replay_request_id" ] \
  || fail "committed replay request id is missing"

SYNC_TEST_MODE=1
SYNC_TEST_CRASH_AFTER_SYSTEM_COMMIT=1
expect_failure \
  "target process exits after durable commit but before channel ACK" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_MODE SYNC_TEST_CRASH_AFTER_SYSTEM_COMMIT
committed_replay_journal="$MINI_APP_SUPPORT/device-sync-state/system-transactions/$committed_replay_request_id/journal.json"
[ "$(plutil -extract phase raw "$committed_replay_journal")" = "committed" ] \
  || fail "pre-ACK process exit did not leave a committed journal"
assert_no_terminal_ack \
  "$MINI_CHANNEL/acks/$committed_replay_request_id.json" \
  "pre-ACK process exit must not publish a terminal ACK"
committed_replay_os_digest="$(shasum -a 256 "$MINI_APP_SUPPORT/hot-sync-mirror/os/issue.md" | awk '{print $1}')"
committed_replay_runtime_digest="$(shasum -a 256 "$MINI_APP_SUPPORT/skills-runtime/alpha-skill/SKILL.md" | awk '{print $1}')"
pass "durable commit remains distinguishable from channel acknowledgement"

expect_success \
  "next poll reconstructs ACK by re-verifying committed state without reactivation" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
assert_output "committed replay is visible in the target log" \
  'committed transaction 已重新驗證|不重複 activation'
committed_replay_ack="$MINI_CHANNEL/acks/$committed_replay_request_id.json"
[ "$(plutil -extract phase raw "$committed_replay_ack")" = "converged" ] \
  || fail "reverified committed transaction did not publish a converged ACK"
[ "$(shasum -a 256 "$MINI_APP_SUPPORT/hot-sync-mirror/os/issue.md" | awk '{print $1}')" = "$committed_replay_os_digest" ] \
  || fail "committed replay mutated the active OS mirror"
[ "$(shasum -a 256 "$MINI_APP_SUPPORT/skills-runtime/alpha-skill/SKILL.md" | awk '{print $1}')" = "$committed_replay_runtime_digest" ] \
  || fail "committed replay mutated the active Skillet runtime"
pass "committed state can reconstruct a missing ACK without a second activation"

printf '%s\n' "# Work OS issue fixture" "attestation failure must remain retryable" \
  >"$TEST_ROOT/os-canonical/issue.md"
expect_success \
  "primary publishes a request used to test target attestation retry" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
attestation_retry_request_id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"
[ -n "$attestation_retry_request_id" ] \
  || fail "attestation retry request id is missing"

attestation_retry_journal="$MINI_APP_SUPPORT/device-sync-state/system-transactions/$attestation_retry_request_id/journal.json"
SYNC_TEST_MODE=1
SYNC_TEST_SHA256_FAIL_PATH="$attestation_retry_journal"
expect_success \
  "target keeps a committed request retryable when attestation journal digest read fails" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_MODE SYNC_TEST_SHA256_FAIL_PATH
[ "$(plutil -extract phase raw "$attestation_retry_journal")" = "committed" ] \
  || fail "attestation failure did not preserve committed transaction evidence"
assert_no_terminal_ack \
  "$MINI_CHANNEL/acks/$attestation_retry_request_id.json" \
  "attestation failure wrote a false terminal ACK"
! grep -qxF "$attestation_retry_request_id" "$MINI_APP_SUPPORT/device-sync-state/processed-ids-mini" \
  || fail "attestation failure incorrectly marked the request processed"
assert_output "attestation failure exposes committed-awaiting-ACK" \
  '無法建立 target attestation：transaction journal digest 讀取失敗'

SYNC_TEST_MODE=1
SYNC_TEST_PARTIAL_TARGET_ATTESTATION_WRITE=1
expect_success \
  "partial/ENOSPC attestation write cannot create a valid terminal claim" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_MODE SYNC_TEST_PARTIAL_TARGET_ATTESTATION_WRITE
assert_no_terminal_ack \
  "$MINI_CHANNEL/acks/$attestation_retry_request_id.json" \
  "partial attestation write produced a false terminal ACK"
! grep -qxF "$attestation_retry_request_id" "$MINI_APP_SUPPORT/device-sync-state/processed-ids-mini" \
  || fail "partial attestation write incorrectly marked the request processed"
assert_output "partial attestation write remains retryable" \
  '測試注入：target attestation partial/ENOSPC write'
[ -n "$(find "$MINI_CHANNEL/attestations" -type f -name '.*.tmp' -print -quit 2>/dev/null)" ] \
  || fail "partial attestation injection left no recoverable atomic stage"
[ -f "$MINI_CHANNEL/consumer-readbacks/mini/$attestation_retry_request_id.json" ] \
  || fail "partial attestation fixture did not leave the preceding consumer readback"

expect_success \
  "next poll reconstructs the target attestation and converged ACK" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
assert_output "target retry archives the abandoned attestation stage" \
  'archived incomplete atomic channel write：attestations/'
assert_output "target retry archives the unbound consumer readback" \
  'archived uncommitted channel receipt after interrupted atomic write：consumer-readbacks/'
[ "$(plutil -extract phase raw "$MINI_CHANNEL/acks/$attestation_retry_request_id.json")" = "converged" ] \
  || fail "attestation retry did not publish a converged ACK"
[ "$(find "$MINI_APP_SUPPORT/device-sync-state/system-transactions/$attestation_retry_request_id" \
  -mindepth 1 -maxdepth 1 -type d -name 'committed-replay*' | wc -l | tr -d ' ')" = "1" ] \
  || fail "committed replay created more than one request-bound verification directory"
assert_channel_clean "$MINI_CHANNEL" \
  "attestation retry leaves the sync channel worktree clean"
pass "committed-awaiting-ACK retries are bounded and do not poison processed state"

printf '%s\n' "# Work OS issue fixture" "consumer readback ENOSPC must remain retryable" \
  >"$TEST_ROOT/os-canonical/issue.md"
expect_success \
  "primary publishes a request used to test consumer readback partial-write recovery" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
consumer_partial_request_id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"
[ -n "$consumer_partial_request_id" ] \
  || fail "consumer readback partial-write request id is missing"

SYNC_TEST_MODE=1
SYNC_TEST_PARTIAL_CONSUMER_READBACK_WRITE=1
expect_success \
  "partial/ENOSPC consumer readback write cannot create a terminal claim" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_MODE SYNC_TEST_PARTIAL_CONSUMER_READBACK_WRITE
consumer_partial_journal="$MINI_APP_SUPPORT/device-sync-state/system-transactions/$consumer_partial_request_id/journal.json"
[ "$(plutil -extract phase raw "$consumer_partial_journal")" = "committed" ] \
  || fail "partial consumer readback did not preserve committed transaction evidence"
assert_output "consumer readback partial-write injection is explicit" \
  '測試注入：consumer readback partial/ENOSPC write'
assert_no_terminal_ack \
  "$MINI_CHANNEL/acks/$consumer_partial_request_id.json" \
  "partial consumer readback wrote a false terminal ACK"
! grep -qxF "$consumer_partial_request_id" "$MINI_APP_SUPPORT/device-sync-state/processed-ids-mini" \
  || fail "partial consumer readback incorrectly marked the request processed"
[ -n "$(find "$MINI_CHANNEL/consumer-readbacks" -type f -name '.*.tmp' -print -quit 2>/dev/null)" ] \
  || fail "partial consumer readback left no recoverable atomic stage"

expect_success \
  "next poll archives the abandoned consumer readback stage and converges" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
assert_output "consumer readback retry exposes archive recovery" \
  'archived incomplete atomic channel write：consumer-readbacks/'
[ "$(plutil -extract phase raw "$MINI_CHANNEL/acks/$consumer_partial_request_id.json")" = "converged" ] \
  || fail "partial consumer readback request did not converge after bounded retry"
grep -qxF "$consumer_partial_request_id" "$MINI_APP_SUPPORT/device-sync-state/processed-ids-mini" \
  || fail "partial consumer readback retry did not persist processed state"
[ -z "$(find "$MINI_CHANNEL/consumer-readbacks" -type f -name '.*.tmp' -print -quit 2>/dev/null)" ] \
  || fail "consumer readback retry left an abandoned atomic stage"
find "$MINI_CHANNEL/.git/tatwo-abandoned-atomic-writes" -maxdepth 1 -type f \
  -name 'consumer-readbacks__*' -print -quit 2>/dev/null | grep -q . \
  || fail "consumer readback recovery produced no evidence archive"
assert_channel_clean "$MINI_CHANNEL" \
  "consumer readback partial-write retry leaves the channel clean"
consumer_retention_status="$MINI_APP_SUPPORT/device-sync-state/retention-status.json"
[ -f "$consumer_retention_status" ] \
  || fail "consumer readback retry produced no retention accounting receipt"
plutil -convert json -o - "$consumer_retention_status" 2>/dev/null \
  | grep -q 'local consumer readback receipts' \
  || fail "retention accounting omits local consumer readback receipts"
plutil -convert json -o - "$consumer_retention_status" 2>/dev/null \
  | grep -q 'channel consumer readbacks' \
  || fail "retention accounting omits channel consumer readbacks"
pass "consumer readback growth is included in per-volume retention accounting"
pass "consumer readback partial writes are archived and retried without false convergence"

printf '%s\n' "# Work OS issue fixture" "consumer adapter failure must remain retryable" \
  >"$TEST_ROOT/os-canonical/issue.md"
expect_success \
  "primary publishes a request used to test consumer adapter failure recovery" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
consumer_failure_request_id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"
[ -n "$consumer_failure_request_id" ] \
  || fail "consumer adapter failure request id is missing"

SYNC_TEST_MODE=1
SYNC_TEST_FAIL_CONSUMER_READBACK=1
expect_success \
  "consumer adapter failure cannot create a terminal claim" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_MODE SYNC_TEST_FAIL_CONSUMER_READBACK
consumer_failure_journal="$MINI_APP_SUPPORT/device-sync-state/system-transactions/$consumer_failure_request_id/journal.json"
[ "$(plutil -extract phase raw "$consumer_failure_journal")" = "committed" ] \
  || fail "consumer adapter failure did not preserve committed transaction evidence"
assert_output "consumer adapter failure injection is explicit" \
  '測試注入：actual consumer readback 建立失敗'
assert_no_terminal_ack \
  "$MINI_CHANNEL/acks/$consumer_failure_request_id.json" \
  "consumer adapter failure wrote a false terminal ACK"
! grep -qxF "$consumer_failure_request_id" "$MINI_APP_SUPPORT/device-sync-state/processed-ids-mini" \
  || fail "consumer adapter failure incorrectly marked the request processed"

expect_success \
  "consumer adapter retry converges from the committed journal" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
[ "$(plutil -extract phase raw "$MINI_CHANNEL/acks/$consumer_failure_request_id.json")" = "converged" ] \
  || fail "consumer adapter failure did not converge after bounded retry"
grep -qxF "$consumer_failure_request_id" "$MINI_APP_SUPPORT/device-sync-state/processed-ids-mini" \
  || fail "consumer adapter retry did not persist processed state"
assert_channel_clean "$MINI_CHANNEL" \
  "consumer adapter retry leaves the sync channel worktree clean"
pass "consumer adapter failures remain non-terminal and retry from committed evidence"

printf '%s\n' "# Work OS issue fixture" "retention must not deadlock a committed transaction" \
  >"$TEST_ROOT/os-canonical/issue.md"
expect_success \
  "primary publishes a request used to test retention-safe committed replay" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
retention_replay_request_id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"
[ -n "$retention_replay_request_id" ] \
  || fail "retention replay request id is missing"

SYNC_TEST_MODE=1
SYNC_TEST_CRASH_AFTER_SYSTEM_COMMIT=1
expect_failure \
  "target exits after commit before retention-safe ACK reconstruction" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_MODE SYNC_TEST_CRASH_AFTER_SYSTEM_COMMIT
[ "$(plutil -extract phase raw "$MINI_APP_SUPPORT/device-sync-state/system-transactions/$retention_replay_request_id/journal.json")" = "committed" ] \
  || fail "retention replay fixture did not leave a committed transaction"
assert_no_terminal_ack \
  "$MINI_CHANNEL/acks/$retention_replay_request_id.json" \
  "retention replay fixture unexpectedly published a terminal ACK"

SYNC_TEST_RETENTION_MAX_ENTRIES=0
expect_success \
  "retention-full poll allows only the bounded committed-awaiting-ACK terminal path" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_RETENTION_MAX_ENTRIES
assert_output "retention-full committed replay is explicit" \
  'retention budget 已滿.*committed-awaiting-ACK|允許 bounded revalidation'
[ "$(plutil -extract phase raw "$MINI_CHANNEL/acks/$retention_replay_request_id.json")" = "converged" ] \
  || fail "retention-full committed replay did not publish a converged ACK"
grep -qxF "$retention_replay_request_id" "$MINI_APP_SUPPORT/device-sync-state/processed-ids-mini" \
  || fail "retention-full committed replay did not persist processed state"
pass "retention blocks new growth without deadlocking a committed terminal receipt"

printf '%s\n' "# Work OS issue fixture" "post-Skillet authority transfer must not converge" \
  >"$TEST_ROOT/os-canonical/issue.md"
expect_success \
  "primary publishes a request used to test the final authority fence" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
post_skillet_authority_request_id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"
[ -n "$post_skillet_authority_request_id" ] \
  || fail "post-Skillet authority request id is missing"

SYNC_TEST_MODE=1
SYNC_TEST_AFTER_SKILLET_ACTIVATE_HOOK="git -C '$BOOK_CHANNEL' fetch -q origin device-sync-channel
git -C '$BOOK_CHANNEL' rebase origin/device-sync-channel >/dev/null
cat > '$BOOK_CHANNEL/primary.json' <<'EOF'
{
  \"name\": \"mini\",
  \"epoch\": 9,
  \"changedAt\": \"2026-07-23T12:15:00Z\"
}
EOF
git -C '$BOOK_CHANNEL' add primary.json
git -C '$BOOK_CHANNEL' -c user.name='Tatwo Device Sync Test' -c user.email='device-sync-test@example.invalid' commit -q -m 'transfer after Skillet activation'
git -C '$BOOK_CHANNEL' push -q origin device-sync-channel"
expect_success \
  "target refuses to claim convergence when authority changes after Skillet activation" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_MODE SYNC_TEST_AFTER_SKILLET_ACTIVATE_HOOK

post_skillet_authority_ack="$MINI_CHANNEL/acks/$post_skillet_authority_request_id.json"
[ -f "$post_skillet_authority_ack" ] \
  || fail "post-Skillet authority transfer did not produce a visible diverged receipt"
[ "$(plutil -extract phase raw "$post_skillet_authority_ack")" = "diverged" ] \
  || fail "post-Skillet authority transfer was allowed to claim convergence"
pass "final authority fence projects an explicit diverged receipt"

expect_success \
  "new primary restores authority to book after final fence test" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  set-primary --name book --expected-epoch 9

git -C "$SEED" checkout -q -b dev/mini
printf '%s\n' "mini candidate" > "$SEED/mini.txt"
git -C "$SEED" add mini.txt
git -C "$SEED" commit -q -m "mini candidate"
git -C "$SEED" push -q origin dev/mini
git -C "$SEED" checkout -q main

expect_failure \
  "non-primary mini cannot run integrate" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" integrate
assert_output "non-primary integrate rejection names current primary" '現任主=book'

expect_success \
  "primary book can inspect dev branches without merging" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" integrate
assert_output "integrate lists dev/mini" 'branch=dev/mini'
assert_output "integrate reports ahead/behind" 'ahead=[0-9?]+ behind=[0-9?]+'
assert_output "integrate reports the last commit" 'last=.*mini candidate'
assert_output "integrate states that it does not auto-merge" '不自動合併'

# Runtime fallback is a separately-authorized emergency source, not an implicit
# consequence of missing canonical files. The ordinary primary and a promoted
# primary without the transfer flag must both fail closed.
SYNC_TEST_SKILLET_AUTO_REFRESH=1
SYNC_TEST_SKILLET_SOURCE_ROOT="$TEST_ROOT/unavailable-promoted-canonical-skills"
SYNC_TEST_SKILLET_SOURCE_FALLBACK_ROOT="$MINI_APP_SUPPORT/skills-runtime"
SYNC_TEST_SKILLET_SOURCE_REGISTRY="$AUTO_REFRESH_REGISTRY"
expect_failure \
  "ordinary primary cannot silently replace a missing canonical source with runtime state" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
assert_output "ordinary primary fallback refusal remains explicit" \
  'canonical source refresh 未收斂|runtime fallback authorization'
unset SYNC_TEST_SKILLET_AUTO_REFRESH
unset SYNC_TEST_SKILLET_SOURCE_ROOT
unset SYNC_TEST_SKILLET_SOURCE_FALLBACK_ROOT
unset SYNC_TEST_SKILLET_SOURCE_REGISTRY

expect_success \
  "book transfers primary authority to runtime-only mini without fallback authorization" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  set-primary --name mini --expected-epoch 10
SYNC_TEST_SKILLET_AUTO_REFRESH=1
SYNC_TEST_SKILLET_SOURCE_ROOT="$TEST_ROOT/unavailable-promoted-canonical-skills"
SYNC_TEST_SKILLET_SOURCE_REGISTRY="$AUTO_REFRESH_REGISTRY"
expect_failure \
  "promoted primary without the explicit transfer flag cannot use runtime fallback" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-request --target book --action system-pull
assert_output "unapproved promoted-primary fallback refusal remains explicit" \
  'canonical source refresh 未收斂|runtime fallback authorization'
unset SYNC_TEST_SKILLET_AUTO_REFRESH
unset SYNC_TEST_SKILLET_SOURCE_ROOT
unset SYNC_TEST_SKILLET_SOURCE_REGISTRY

expect_success \
  "runtime-only mini returns authority so the previous primary can authorize a new epoch" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  set-primary --name book --expected-epoch 11
expect_success \
  "book explicitly authorizes runtime fallback while promoting mini" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  set-primary --name mini --expected-epoch 12 --authorize-runtime-fallback

fallback_authorization_relative="$(
  plutil -extract runtimeFallbackAuthorizationPath raw "$BOOK_CHANNEL/primary.json"
)"
fallback_signature_relative="$(
  plutil -extract runtimeFallbackAuthorizationSignaturePath raw "$BOOK_CHANNEL/primary.json"
)"
fallback_authorization="$BOOK_CHANNEL/$fallback_authorization_relative"
fallback_signature="$BOOK_CHANNEL/$fallback_signature_relative"
[ -f "$fallback_authorization" ] && [ -f "$fallback_signature" ] \
  || fail "authorized transfer did not publish authorization plus prior-primary signature"
[ "$(plutil -extract schema raw "$fallback_authorization")" \
    = "TatwoSkilletRuntimeFallbackAuthorizationV1" ] \
  && [ "$(plutil -extract authorizedDeviceName raw "$fallback_authorization")" = "mini" ] \
  && [ "$(plutil -extract authorityEpoch raw "$fallback_authorization")" = "13" ] \
  && [ "$(plutil -extract previousAuthorityPrimary raw "$fallback_authorization")" = "book" ] \
  && [ "$(plutil -extract previousAuthorityEpoch raw "$fallback_authorization")" = "12" ] \
  || fail "runtime fallback authorization is not bound to the promoted device and epoch"
pass "authorized transfer publishes a prior-primary-signed authority-epoch receipt"

fallback_fixture_root="$TEST_ROOT/fallback-authorization-fixtures"
mkdir -p "$fallback_fixture_root"
cp "$BOOK_CHANNEL/primary.json" "$fallback_fixture_root/primary.json"
cp "$fallback_authorization" "$fallback_fixture_root/authorization.json"
cp "$fallback_signature" "$fallback_fixture_root/signature.json"

# Exercise the authorization against the actual runtime-fallback path. With
# auto-refresh disabled the helper intentionally uses its prebuilt canonical
# store and never consumes the fallback authorization, so tampering here would
# otherwise be a false-negative test of unrelated canonical behavior.
SYNC_TEST_SKILLET_AUTO_REFRESH=1
SYNC_TEST_SKILLET_SOURCE_ROOT="$TEST_ROOT/unavailable-promoted-canonical-skills"
SYNC_TEST_SKILLET_SOURCE_FALLBACK_ROOT="$MINI_APP_SUPPORT/skills-runtime"
SYNC_TEST_SKILLET_SOURCE_REGISTRY="$AUTO_REFRESH_REGISTRY"

plutil -replace authorizedDeviceName -string book "$fallback_authorization"
tampered_fallback_digest="$(shasum -a 256 "$fallback_authorization" | awk '{print $1}')"
plutil -replace runtimeFallbackAuthorizationDigest \
  -string "$tampered_fallback_digest" "$BOOK_CHANNEL/primary.json"
commit_channel_paths \
  "$BOOK_CHANNEL" "tamper runtime fallback target device" \
  primary.json "$fallback_authorization_relative"
expect_failure \
  "runtime fallback authorization for the wrong device fails closed" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-request --target book --action system-pull
assert_output "wrong-device authorization rejection is explicit" \
  'authorization.*binding|authorization.*無法驗證'
cp "$fallback_fixture_root/primary.json" "$BOOK_CHANNEL/primary.json"
cp "$fallback_fixture_root/authorization.json" "$fallback_authorization"
commit_channel_paths \
  "$BOOK_CHANNEL" "restore runtime fallback target device" \
  primary.json "$fallback_authorization_relative"

plutil -replace authorityEpoch -integer 12 "$fallback_authorization"
tampered_fallback_digest="$(shasum -a 256 "$fallback_authorization" | awk '{print $1}')"
plutil -replace runtimeFallbackAuthorizationDigest \
  -string "$tampered_fallback_digest" "$BOOK_CHANNEL/primary.json"
commit_channel_paths \
  "$BOOK_CHANNEL" "tamper runtime fallback epoch" \
  primary.json "$fallback_authorization_relative"
expect_failure \
  "stale runtime fallback authorization epoch fails closed" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-request --target book --action system-pull
assert_output "stale-epoch authorization rejection is explicit" \
  'authorization.*binding|authorization.*無法驗證'
cp "$fallback_fixture_root/primary.json" "$BOOK_CHANNEL/primary.json"
cp "$fallback_fixture_root/authorization.json" "$fallback_authorization"
commit_channel_paths \
  "$BOOK_CHANNEL" "restore runtime fallback epoch" \
  primary.json "$fallback_authorization_relative"

plutil -replace runtimeFallbackAuthorizationDigest \
  -string "$(printf '0%.0s' {1..64})" "$BOOK_CHANNEL/primary.json"
commit_channel_paths \
  "$BOOK_CHANNEL" "tamper runtime fallback digest" primary.json
expect_failure \
  "runtime fallback authorization digest mismatch fails closed" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-request --target book --action system-pull
assert_output "authorization digest mismatch is explicit" \
  'authorization digest.*不一致|authorization.*無法驗證'
cp "$fallback_fixture_root/primary.json" "$BOOK_CHANNEL/primary.json"
commit_channel_paths \
  "$BOOK_CHANNEL" "restore runtime fallback digest" primary.json

plutil -replace signature -string AAAA "$fallback_signature"
commit_channel_paths \
  "$BOOK_CHANNEL" "tamper runtime fallback signature" "$fallback_signature_relative"
expect_failure \
  "runtime fallback authorization with a forged prior-primary signature fails closed" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-request --target book --action system-pull
assert_output "forged authorization signature rejection is explicit" \
  'authorization signature.*無效|authorization.*無法驗證'
cp "$fallback_fixture_root/signature.json" "$fallback_signature"
commit_channel_paths \
  "$BOOK_CHANNEL" "restore runtime fallback signature" "$fallback_signature_relative"

printf '%s\n' "# Work OS issue fixture" \
  "promoted runtime-only primary publishes the next iteration" \
  >"$TEST_ROOT/os-canonical/issue.md"
expect_success \
  "promoted mini publishes system-pull from repository-ID runtime fallback" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-request --target book --action system-pull
unset SYNC_TEST_SKILLET_AUTO_REFRESH
unset SYNC_TEST_SKILLET_SOURCE_ROOT
unset SYNC_TEST_SKILLET_SOURCE_FALLBACK_ROOT
unset SYNC_TEST_SKILLET_SOURCE_REGISTRY
promoted_request_id="$(
  printf '%s\n' "$LAST_OUTPUT" \
    | sed -n 's/^SYNC_REQUEST_ID=//p' \
    | tail -1
)"
[ -n "$promoted_request_id" ] \
  || fail "promoted runtime-only primary did not publish a request"
promoted_refresh_receipt="$MINI_APP_SUPPORT/device-sync-state/skillet-export-receipts/$promoted_request_id/canonical-refresh.json"
[ "$(plutil -extract outcome raw "$promoted_refresh_receipt")" = "converged" ] \
  && [ "$(plutil -extract sourceMode raw "$promoted_refresh_receipt")" = "runtime-fallback" ] \
  && [ "$(plutil -extract discoveredSourceCount raw "$promoted_refresh_receipt")" = "2" ] \
  || fail "promoted primary did not converge through the isolated runtime fallback"
[ "$(plutil -extract results.0.sourceName raw "$promoted_refresh_receipt")" = "刺青網頁" ] \
  && [ "$(plutil -extract results.0.repositoryID raw "$promoted_refresh_receipt")" = "alpha-skill" ] \
  && [ "$(plutil -extract results.0.sourceLayout raw "$promoted_refresh_receipt")" = "repository-id" ] \
  || fail "promoted primary lost the logical alias identity"
[ ! -e "$MINI_APP_SUPPORT/skills-runtime/刺青網頁" ] \
  || fail "promoted primary recreated a sourceName runtime directory"
pass "promoted primary preserves one logical repository identity"

promoted_request="$MINI_CHANNEL/requests/book/$promoted_request_id.json"
promoted_manifest="$MINI_CHANNEL/payloads/$promoted_request_id/manifest.json"
promoted_set="$MINI_CHANNEL/payloads/$promoted_request_id/items/skills.skillet/set.json"
[ "$(plutil -extract fallbackAuthorizationPath raw "$promoted_request")" \
    = "$fallback_authorization_relative" ] \
  && [ "$(plutil -extract fallbackAuthorizationDigest raw "$promoted_request")" \
    = "$(shasum -a 256 "$fallback_authorization" | awk '{print $1}')" ] \
  || fail "promoted request did not bind the exact signed fallback authorization"
assert_source_provenance_equal \
  "runtime-fallback refresh receipt matches the signed request provenance" \
  "$promoted_request" "$promoted_refresh_receipt"
assert_source_provenance_equal \
  "runtime-fallback manifest matches the signed request provenance" \
  "$promoted_request" "$promoted_manifest"
assert_source_provenance_equal \
  "runtime-fallback Skillet set matches the signed request provenance" \
  "$promoted_request" "$promoted_set"

expect_success \
  "book consumes the promoted primary system revision" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-poll --device book
promoted_ack="$BOOK_CHANNEL/acks/$promoted_request_id.json"
[ "$(plutil -extract phase raw "$promoted_ack")" = "converged" ] \
  || fail "promoted primary system revision did not converge on book"
assert_source_provenance_equal \
  "runtime-fallback terminal ACK matches request, manifest and Skillet set provenance" \
  "$promoted_request" "$promoted_ack"
cmp "$TEST_ROOT/os-canonical/issue.md" \
  "$BOOK_APP_SUPPORT/hot-sync-mirror/os/issue.md" \
  || fail "book consumer did not read back the promoted OS revision"
for repository_id in alpha-skill beta-skill; do
  [ -f "$BOOK_APP_SUPPORT/skills-runtime/$repository_id/SKILL.md" ] \
    || fail "book consumer did not activate promoted repository: $repository_id"
done
pass "real aliases survive primary transfer and a second end-to-end system-pull"

expect_success \
  "runtime-only mini transfers authority back to book" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  set-primary --name book --expected-epoch 13

# Divergent Skillet history: the CLI exits 44, the OS mirror must roll back, and
# the incoming Skillet evidence must stay durable until a human approves/rejects.
# This case runs against isolated copies of the channel remote and target state so
# the deliberately non-terminal request cannot leak into later polls.
MERGE_REMOTE="$TEST_ROOT/channel-merge.git"
MERGE_APP_SUPPORT="$TEST_ROOT/app-support-merge"
MERGE_CHANNEL="$TEST_ROOT/channel-merge-mini"
MERGE_BOOK_CHANNEL="$TEST_ROOT/channel-merge-book"
MERGE_HOME="$TEST_ROOT/home-merge"
MERGE_FAKE_CLI="$TEST_ROOT/merge-pending-skillet-cli"
MERGE_CLI_CALLS="$TEST_ROOT/merge-pending-cli-calls"
cp -R "$REMOTE" "$MERGE_REMOTE"
cp -R "$MINI_APP_SUPPORT" "$MERGE_APP_SUPPORT"
MERGE_CONSUMER_QUARANTINE="$TEST_ROOT/merge-skills-consumer"
MERGE_PROJECTION_RECEIPTS_QUARANTINE="$TEST_ROOT/merge-skills-consumer-projection-receipts"
if [ -e "$MERGE_APP_SUPPORT/skills-consumer" ]; then
  mv "$MERGE_APP_SUPPORT/skills-consumer" "$MERGE_CONSUMER_QUARANTINE"
fi
if [ -e "$MERGE_APP_SUPPORT/device-sync-state/skills-consumer-projection-receipts" ]; then
  mv "$MERGE_APP_SUPPORT/device-sync-state/skills-consumer-projection-receipts" \
    "$MERGE_PROJECTION_RECEIPTS_QUARANTINE"
fi
bootstrap_skills_consumer_projection \
  "$MERGE_HOME" "$MERGE_APP_SUPPORT" "$MERGE_APP_SUPPORT/skills-runtime"
: >"$MERGE_CLI_CALLS"

# Fake CLI: everything except the aggregate set activation is the real binary. The
# aggregate activation persists a TatwoSkilletSetMergePendingCLIOutputV1 receipt
# derived from the real set manifest, keeps the incoming payload durable next to
# the live store, and exits 44 exactly like the Swift merge-pending path.
cat >"$MERGE_FAKE_CLI" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" != "skillet" ] || [ "\${2:-}" != "import-activate-set" ]; then
  exec "$SKILLET_CLI" "\$@"
fi
printf '%s\n' "import-activate-set" >>"$MERGE_CLI_CALLS"
set_manifest=""; store=""; receipt=""; request=""
source_device=""; target_device=""; epoch=""; ledger=""; catalog=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --set-manifest) set_manifest="\$2"; shift 2;;
    --store) store="\$2"; shift 2;;
    --request) request="\$2"; shift 2;;
    --source-device) source_device="\$2"; shift 2;;
    --target-device) target_device="\$2"; shift 2;;
    --authority-epoch) epoch="\$2"; shift 2;;
    --ledger-sequence) ledger="\$2"; shift 2;;
    --catalog-revision) catalog="\$2"; shift 2;;
    --receipt) receipt="\$2"; shift 2;;
    *) shift;;
  esac
done
[ -n "\$set_manifest" ] && [ -n "\$store" ] && [ -n "\$receipt" ] \\
  || { printf '%s\n' "fake merge CLI is missing required arguments" >&2; exit 64; }
repository_count="\$(plutil -extract repositories raw "\$set_manifest")"
[ "\$repository_count" -gt 0 ] \\
  || { printf '%s\n' "fake merge CLI needs a non-empty repository set" >&2; exit 64; }
index=0
repositories=""
branch_preserved_repositories=""
proposal_ids=""
proposal_count=0
branch_preserved_count=0
while [ "\$index" -lt "\$repository_count" ]; do
  repository_id="\$(plutil -extract "repositories.\$index.repositoryID" raw "\$set_manifest")"
  revision_id="\$(plutil -extract "repositories.\$index.revisionID" raw "\$set_manifest")"
  content_digest="\$(plutil -extract "repositories.\$index.contentDigest" raw "\$set_manifest")"
  bundle_digest="\$(plutil -extract "repositories.\$index.bundleDigest" raw "\$set_manifest")"
  if [ "\$index" -eq 0 ]; then
    proposal_id="merge-\$(printf '%s' "\$request:\$repository_id:\$revision_id" \\
      | shasum -a 256 | awk '{print \$1}')"
    # Stand-ins for the target-local base/canonical heads the real engine reads
    # out of the live store; only their shape matters to the shell contract.
    base_revision="\$(printf '%s' "base:\$repository_id" | shasum -a 256 | awk '{print \$1}')"
    canonical_revision="\$(printf '%s' "canonical:\$repository_id" | shasum -a 256 | awk '{print \$1}')"
    [ "\$proposal_count" -eq 0 ] \\
      || { repositories="\${repositories},"; proposal_ids="\${proposal_ids},"; }
    proposal_ids="\${proposal_ids}\"\$proposal_id\""
    repositories="\${repositories}{
      \"repositoryID\":\"\$repository_id\",
      \"proposalID\":\"\$proposal_id\",
      \"sourceDeviceID\":\"\$source_device\",
      \"baseRevisionID\":\"\$base_revision\",
      \"canonicalRevisionID\":\"\$canonical_revision\",
      \"proposedRevisionID\":\"\$revision_id\",
      \"contentDigest\":\"\$content_digest\",
      \"bundleDigest\":\"\$bundle_digest\",
      \"conflictCount\":1,
      \"conflictArtifactIDs\":[\"SKILL.md\"],
      \"status\":\"pending\"
    }"
    proposal_count=\$((proposal_count + 1))
  else
    [ "\$branch_preserved_count" -eq 0 ] \\
      || branch_preserved_repositories="\${branch_preserved_repositories},"
    branch_preserved_repositories="\${branch_preserved_repositories}{
      \"repositoryID\":\"\$repository_id\",
      \"revisionID\":\"\$revision_id\",
      \"contentDigest\":\"\$content_digest\",
      \"bundleDigest\":\"\$bundle_digest\",
      \"state\":\"branch-preserved\"
    }"
    branch_preserved_count=\$((branch_preserved_count + 1))
  fi
  index=\$((index + 1))
done
target_preserved_digest="\$(
  printf '%s' "target-preserved:\$request" | shasum -a 256 | awk '{print \$1}'
)"
mkdir -p "\$(dirname "\$receipt")"
cat >"\$receipt" <<JSON
{
  "schema": "TatwoSkilletSetMergePendingCLIOutputV1",
  "requestID": "\$request",
  "sourceDeviceID": "\$source_device",
  "targetDeviceID": "\$target_device",
  "authorityEpoch": \$epoch,
  "ledgerSequence": \$ledger,
  "catalogRevision": "\$catalog",
  "activationState": "merge-pending",
  "repositoryCount": \$repository_count,
  "proposalCount": \$proposal_count,
  "branchPreservedCount": \$branch_preserved_count,
  "proposalIDs": [\$proposal_ids],
  "repositories": [\$repositories],
  "branchPreservedRepositories": [\$branch_preserved_repositories],
  "targetPreservedCount": 1,
  "targetPreservedRepositories": [
    {
      "repositoryID": "target-only-skill",
      "revisionID": "rev-\$target_preserved_digest",
      "contentDigest": "\$target_preserved_digest",
      "state": "store-preserved"
    }
  ]
}
JSON
python3 -m json.tool "\$receipt" >/dev/null
# Durable incoming evidence: the proposal marker inside the live store plus the
# sibling pending-merge payload the real transport keeps next to the store.
mkdir -p "\$store" "\$(dirname "\$store")/.\$(basename "\$store").pending-merge-\$request"
printf '%s\n' "\$request" >"\$store/.tatwo-incoming-merge-marker"
printf '%s\n' "\$request" \\
  >"\$(dirname "\$store")/.\$(basename "\$store").pending-merge-\$request/proposal.txt"
printf '%s\n' \\
  "Skillet set requires human merge approval; receipt=\$receipt" >&2
exit 44
EOF
chmod +x "$MERGE_FAKE_CLI"

printf '%s\n' "# Work OS issue fixture" "divergent Skillet history must wait for human merge" \
  >"$TEST_ROOT/os-canonical/issue.md"
SYNC_TEST_CHANNEL_REMOTE="$MERGE_REMOTE"
expect_success \
  "primary publishes a request used to test Skillet merge-pending" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$MERGE_BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
merge_pending_request_id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"
[ -n "$merge_pending_request_id" ] || fail "merge-pending request id is missing"

merge_mirror="$MERGE_APP_SUPPORT/hot-sync-mirror/os/issue.md"
merge_runtime="$MERGE_APP_SUPPORT/skills-runtime/alpha-skill/SKILL.md"
merge_store="$MERGE_APP_SUPPORT/skillet"
merge_store_marker="$merge_store/.tatwo-incoming-merge-marker"
merge_pending_payload="$MERGE_APP_SUPPORT/.skillet.pending-merge-$merge_pending_request_id"
merge_pre_mirror_digest="$(shasum -a 256 "$merge_mirror" | awk '{print $1}')"
merge_pre_runtime_digest="$(shasum -a 256 "$merge_runtime" | awk '{print $1}')"
merge_incoming_mirror_digest="$(shasum -a 256 "$TEST_ROOT/os-canonical/issue.md" | awk '{print $1}')"
[ "$merge_pre_mirror_digest" != "$merge_incoming_mirror_digest" ] \
  || fail "merge-pending fixture must publish a genuinely new OS mirror payload"

SYNC_TEST_SKILLET_CLI="$MERGE_FAKE_CLI"
expect_success \
  "target preserves Skillet merge proposals and rolls back only the OS mirror" \
  run_sync mini "$MERGE_HOME" "$MERGE_APP_SUPPORT" "$MERGE_CHANNEL" \
  sync-poll --device mini
assert_output "merge-pending poll names the human approval gate" \
  '保存 merge proposals|等待人工 approve/reject'
[ "$(wc -l <"$MERGE_CLI_CALLS" | tr -d ' ')" = "1" ] \
  || fail "aggregate Skillet activation did not run exactly once"

# apply_status=44 is the only producer of a merging/partial receipt bound to a
# mergePending journal, so this pair is the observable propagation of CLI status 44.
merge_pending_ack="$MERGE_CHANNEL/acks/$merge_pending_request_id.json"
merge_pending_journal="$MERGE_APP_SUPPORT/device-sync-state/system-transactions/$merge_pending_request_id/journal.json"
[ "$(plutil -extract phase raw "$merge_pending_ack")" = "merging" ] \
  || fail "merge-pending request did not publish a merging ACK phase"
[ "$(plutil -extract result raw "$merge_pending_ack")" = "partial" ] \
  || fail "merge-pending request did not publish a partial ACK result"
[ "$(plutil -extract phase raw "$merge_pending_journal")" = "mergePending" ] \
  || fail "transaction journal did not record the mergePending phase"
[ "$(plutil -extract ackState raw "$merge_pending_journal")" = "blocked" ] \
  || fail "merge-pending journal did not record ackState=blocked"
[ "$(plutil -extract recoveryState raw "$merge_pending_journal")" = "merging" ] \
  || fail "merge-pending journal did not record recoveryState=merging"
merge_pending_proposal_count="$(plutil -extract mergeProposalCount raw "$merge_pending_journal")"
[ "$merge_pending_proposal_count" -gt 0 ] \
  || fail "merge-pending journal did not record any preserved proposal"
merge_pending_receipt="$(plutil -extract mergeReceipt raw "$merge_pending_journal")"
[ -s "$merge_pending_receipt" ] \
  || fail "merge-pending journal does not point at a durable proposal receipt"
[ "$(plutil -extract activationState raw "$merge_pending_receipt")" = "merge-pending" ] \
  || fail "preserved Skillet receipt is not a merge-pending receipt"

[ "$(plutil -extract items.3.phase raw "$merge_pending_ack")" = "merging" ] \
  || fail "Skillet ACK item is not projected as merging"
[ "$(plutil -extract items.3.proposalCount raw "$merge_pending_ack")" \
    = "$merge_pending_proposal_count" ] \
  || fail "Skillet ACK does not enumerate the preserved proposals"
[ "$(plutil -extract items.3.repositoryCount raw "$merge_pending_ack")" = "2" ] \
  || fail "Skillet ACK does not cover the full mixed repository set"
[ "$(plutil -extract items.3.branchPreservedCount raw "$merge_pending_ack")" = "1" ] \
  || fail "Skillet ACK does not enumerate the branch-preserved repository"
[ "$(plutil -extract items.3.targetPreservedCount raw "$merge_pending_ack")" = "1" ] \
  || fail "Skillet ACK does not enumerate target-preserved repositories"
[ "$(plutil -extract items.3.targetPreservedRepositories.0.repositoryID raw "$merge_pending_ack")" \
    = "target-only-skill" ] \
  || fail "Skillet ACK omits the target-only repository during merge-pending"
[ "$(plutil -extract items.3.targetPreservedRepositories.0.state raw "$merge_pending_ack")" \
    = "store-preserved" ] \
  || fail "Skillet ACK changed the target-only repository preservation state"
merge_pending_ack_proposal_id="$(plutil -extract items.3.proposalIDs.0 raw "$merge_pending_ack")"
printf '%s\n' "$merge_pending_ack_proposal_id" | grep -Eq '^merge-[0-9a-f]{64}$' \
  || fail "ACK proposal id is not merge- plus 64 lowercase hex"
[ "$(plutil -extract items.3.repositories.0.status raw "$merge_pending_ack")" = "pending" ] \
  || fail "Skillet ACK proposal is not pending human approval"
[ "$(plutil -extract items.3.repositories.1.status raw "$merge_pending_ack")" \
    = "branch-preserved" ] \
  || fail "Skillet ACK omits the non-divergent branch-preserved repository"

[ "$(shasum -a 256 "$merge_mirror" | awk '{print $1}')" = "$merge_pre_mirror_digest" ] \
  || fail "merge-pending did not restore the previous OS mirror"
[ "$(shasum -a 256 "$merge_runtime" | awk '{print $1}')" = "$merge_pre_runtime_digest" ] \
  || fail "merge-pending changed an active Skillet runtime"
[ -f "$merge_store_marker" ] \
  || fail "merge-pending discarded the incoming Skillet store marker"
[ -f "$merge_pending_payload/proposal.txt" ] \
  || fail "merge-pending discarded the durable incoming merge payload"
! grep -qxF "$merge_pending_request_id" \
  "$MERGE_APP_SUPPORT/device-sync-state/processed-ids-mini" \
  || fail "non-terminal merge-pending request was written to processed ids"

expect_success \
  "a second poll neither reactivates nor loses the pending Skillet merge" \
  run_sync mini "$MERGE_HOME" "$MERGE_APP_SUPPORT" "$MERGE_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_SKILLET_CLI SYNC_TEST_CHANNEL_REMOTE
assert_output "second merge-pending poll stays on the human decision gate" \
  '仍等待人工 merge 決策'
[ "$(wc -l <"$MERGE_CLI_CALLS" | tr -d ' ')" = "1" ] \
  || fail "second poll re-ran the aggregate Skillet activation"
[ "$(plutil -extract phase raw "$merge_pending_journal")" = "mergePending" ] \
  || fail "second poll moved the transaction off mergePending"
[ "$(plutil -extract phase raw "$merge_pending_ack")" = "merging" ] \
  || fail "second poll lost the merging ACK phase"
[ "$(plutil -extract result raw "$merge_pending_ack")" = "partial" ] \
  || fail "second poll lost the partial ACK result"
[ "$(plutil -extract items.3.proposalIDs.0 raw "$merge_pending_ack")" \
    = "$merge_pending_ack_proposal_id" ] \
  || fail "second poll lost or rewrote the preserved proposal id"
[ "$(shasum -a 256 "$merge_mirror" | awk '{print $1}')" = "$merge_pre_mirror_digest" ] \
  || fail "second poll re-activated the incoming OS mirror"
[ "$(shasum -a 256 "$merge_runtime" | awk '{print $1}')" = "$merge_pre_runtime_digest" ] \
  || fail "second poll changed an active Skillet runtime"
[ -f "$merge_store_marker" ] \
  || fail "second poll discarded the incoming Skillet store marker"
[ -f "$merge_pending_payload/proposal.txt" ] \
  || fail "second poll discarded the durable incoming merge payload"
! grep -qxF "$merge_pending_request_id" \
  "$MERGE_APP_SUPPORT/device-sync-state/processed-ids-mini" \
  || fail "second poll marked the pending merge request processed"
pass "divergent Skillet history stays human-gated across repeated polls"

printf '%s\n' "# Work OS issue fixture" "missing rollback snapshot must block the channel" \
  >"$TEST_ROOT/os-canonical/issue.md"
expect_success \
  "primary publishes a request used to test missing rollback snapshot handling" \
  run_sync book "$BOOK_HOME" "$BOOK_APP_SUPPORT" "$BOOK_CHANNEL" \
  sync-request --target mini --action system-pull
missing_backup_request_id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"
[ -n "$missing_backup_request_id" ] \
  || fail "missing-backup request id is missing"

SYNC_TEST_MODE=1
SYNC_TEST_CRASH_AFTER_OS_ACTIVATE=1
expect_failure \
  "target process exits after OS activation for missing-backup injection" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
unset SYNC_TEST_MODE SYNC_TEST_CRASH_AFTER_OS_ACTIVATE
missing_backup_path="$MINI_APP_SUPPORT/hot-sync-mirror/.tatwo-sync-rollback/$missing_backup_request_id/os"
[ -d "$missing_backup_path" ] || fail "missing-backup fixture did not create an OS snapshot"
mkdir -p "$TEST_ROOT/quarantined-missing-backups"
mv "$missing_backup_path" \
  "$TEST_ROOT/quarantined-missing-backups/$missing_backup_request_id-os"

expect_failure \
  "recovery fails closed when a required rollback snapshot is missing" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
missing_backup_journal="$MINI_APP_SUPPORT/device-sync-state/system-transactions/$missing_backup_request_id/journal.json"
[ "$(plutil -extract phase raw "$missing_backup_journal")" = "diverged" ] \
  || fail "missing rollback snapshot was not marked diverged"
assert_no_terminal_ack \
  "$MINI_CHANNEL/acks/$missing_backup_request_id.json" \
  "missing rollback snapshot produced a false terminal ACK"

expect_failure \
  "diverged transaction blocks later channel polling until manual resolution" \
  run_sync mini "$MINI_HOME" "$MINI_APP_SUPPORT" "$MINI_CHANNEL" \
  sync-poll --device mini
assert_output "diverged channel block is explicit" \
  'diverged 且需要人工處理|無法安全恢復'
pass "irrecoverable snapshot loss remains a visible fail-closed channel block"

retention_status="$MINI_APP_SUPPORT/device-sync-state/retention-status.json"
[ -f "$retention_status" ] || fail "production-default retention status is missing"
[ "$(plutil -extract state raw "$retention_status")" = "within-budget" ] \
  || fail "production-default retention blocked during the 20+ cycle suite"
historical_entry_count="$(
  plutil -extract historicalEntryCount raw "$retention_status" 2>/dev/null || true
)"
[ -n "$historical_entry_count" ] && [ "$historical_entry_count" -gt 128 ] \
  || fail "retention test did not prove more than 128 historical artifacts"
active_entry_count="$(plutil -extract activeEntryCount raw "$retention_status")"
[ "$active_entry_count" -le 128 ] \
  || fail "active retention count exceeded the production default"
retention_mount_count="$(plutil -extract volumes raw "$retention_status")"
[ "$retention_mount_count" -gt 0 ] \
  || fail "retention receipt does not enumerate filesystem volumes"
retention_mount_index=0
while [ "$retention_mount_index" -lt "$retention_mount_count" ]; do
  retention_mount_point="$(
    plutil -extract "volumes.$retention_mount_index.mountPoint" raw "$retention_status"
  )"
  case "$retention_mount_point" in
    /*) ;;
    *) fail "retention mountPoint is not an absolute filesystem mount path: $retention_mount_point";;
  esac
  retention_mount_index=$((retention_mount_index + 1))
done
pass "retention receipt reports filesystem mount paths instead of mtime integers"
plutil -convert json -o - "$retention_status" 2>/dev/null \
  | grep -q '"historicalTrackedArtifacts":"[^"]*OS candidate recovery history' \
  || fail "retention accounting omits OS candidate recovery history"
pass "20+ production-default sync cycles preserve history without exhausting active retention"

printf '%s\n' "tatwo_device_sync_flexprimary_test=passed"
