#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/scripts/tatwo-sync-helper.sh"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/tatwo-sync-helper-aqua-domain.XXXXXX")"
BIN="$FIXTURE/bin"
HOME_ROOT="$FIXTURE/home"
APP_SUPPORT="$HOME_ROOT/Library/Application Support/Tatwo Ultrawork"
RUNTIME="$FIXTURE/runtime"
CALLS="$FIXTURE/sync-calls.log"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  printf 'tatwo_test_root_preserved=%s\n' "$FIXTURE" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

mkdir -p "$BIN" "$HOME_ROOT" "$RUNTIME"
cp "$HELPER" "$RUNTIME/tatwo-sync-helper.sh"
cat >"$RUNTIME/tatwo-device-sync.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${TATWO_TEST_SYNC_CALLS:?}"
case "${1:-}" in
  role-status)
    printf '%s\n' 'device=TATWO role=secondary primary=mini epoch=1'
    ;;
  sync-poll)
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$RUNTIME/tatwo-sync-helper.sh" "$RUNTIME/tatwo-device-sync.sh"
cat >"$BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "managername" ]; then
  printf '%s\n' "${TATWO_TEST_MANAGER_NAME:-unknown}"
  exit 0
fi
exit 1
EOF
chmod +x "$BIN/launchctl"

env \
  HOME="$HOME_ROOT" \
  PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  TATWO_APP_SUPPORT="$APP_SUPPORT" \
  TATWO_DEVICE_NAME=TATWO \
  TATWO_TEST_MODE=0 \
  TATWO_TEST_MANAGER_NAME=System \
  TATWO_TEST_SYNC_CALLS="$CALLS" \
  TATWO_SYNC_HELPER_ONCE=1 \
  TATWO_AUTO_VERSION=0 \
  bash "$RUNTIME/tatwo-sync-helper.sh"

[ ! -e "$CALLS" ] \
  || fail "system-domain helper attempted a device-signing sync action"
grep -Fq 'Aqua' "$APP_SUPPORT/sync-helper.log" \
  || fail "system-domain helper did not explain the Aqua requirement"
pass "non-Aqua helper stays passive before any device-signing action"

env \
  HOME="$HOME_ROOT" \
  PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  TATWO_APP_SUPPORT="$APP_SUPPORT" \
  TATWO_DEVICE_NAME=TATWO \
  TATWO_TEST_MODE=0 \
  TATWO_TEST_MANAGER_NAME=Aqua \
  TATWO_TEST_SYNC_CALLS="$CALLS" \
  TATWO_SYNC_HELPER_ONCE=1 \
  TATWO_AUTO_VERSION=0 \
  bash "$RUNTIME/tatwo-sync-helper.sh"

grep -qxF 'role-status' "$CALLS" \
  || fail "Aqua helper did not inspect the governed device role"
grep -qxF 'sync-poll --device TATWO' "$CALLS" \
  || fail "Aqua helper did not execute the secondary sync poll"
pass "Aqua helper owns the device-signing sync path"

printf '%s\n' "tatwo_sync_helper_aqua_domain_test=passed"
printf 'tatwo_test_root_preserved=%s\n' "$FIXTURE"
