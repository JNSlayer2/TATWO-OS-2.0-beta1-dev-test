#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENROLL="$ROOT/scripts/tatwo-device-enroll.sh"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

PYTHON_PREFLIGHT_ROOT="$(
  mktemp -d "${TMPDIR:-/tmp}/tatwo-enroll-python-preflight.XXXXXX"
)"
PYTHON_PREFLIGHT_HOME="$PYTHON_PREFLIGHT_ROOT/home"
mkdir -p "$PYTHON_PREFLIGHT_HOME"
MISSING_ENROLL_PYTHON="$PYTHON_PREFLIGHT_ROOT/missing-python3"
output="$(
  HOME="$PYTHON_PREFLIGHT_HOME" \
    TATWO_PYTHON3="$MISSING_ENROLL_PYTHON" \
    bash "$ENROLL" --dry-run --no-app --no-helper --name test-device \
      --os-root "$ROOT" \
      --channel-remote "git@sync-host:tatwo/hot-sync.git" 2>&1 || true
)"
printf '%s\n' "$output" | grep -Fq '設備納管需要可用的 python3' \
  || fail "missing enrollment python3 is not explained"
[ ! -e "$PYTHON_PREFLIGHT_HOME/.local/bin/tatwo-ultrawork" ] \
  || fail "missing enrollment python3 mutated the governed CLI path"
[ ! -e "$PYTHON_PREFLIGHT_HOME/Library/LaunchAgents/com.tatwo.device-sync-helper.plist" ] \
  || fail "missing enrollment python3 emitted a helper plist"
pass "enrollment fails closed before mutation when python3 is missing"

BROKEN_ENROLL_PYTHON="$PYTHON_PREFLIGHT_ROOT/broken-python3"
cat >"$BROKEN_ENROLL_PYTHON" <<'EOF'
#!/usr/bin/env bash
exit 72
EOF
chmod +x "$BROKEN_ENROLL_PYTHON"
output="$(
  HOME="$PYTHON_PREFLIGHT_HOME" \
    TATWO_PYTHON3="$BROKEN_ENROLL_PYTHON" \
    bash "$ENROLL" --dry-run --no-app --no-helper --name test-device \
      --os-root "$ROOT" \
      --channel-remote "git@sync-host:tatwo/hot-sync.git" 2>&1 || true
)"
printf '%s\n' "$output" \
  | grep -Fq '設備納管的 python3 無法執行必要標準函式庫' \
  || fail "nonfunctional enrollment python3 is not explained"
[ ! -e "$PYTHON_PREFLIGHT_HOME/.local/bin/tatwo-ultrawork" ] \
  || fail "nonfunctional enrollment python3 mutated the governed CLI path"
[ ! -e "$PYTHON_PREFLIGHT_HOME/Library/LaunchAgents/com.tatwo.device-sync-helper.plist" ] \
  || fail "nonfunctional enrollment python3 emitted a helper plist"
rm -rf "$PYTHON_PREFLIGHT_ROOT"
pass "enrollment functionally probes python3 before mutation"

output="$(
  HOME="${TMPDIR:-/tmp}/tatwo-enroll-test-home" \
    bash "$ENROLL" --dry-run --no-app --no-helper --name test-device \
      --channel-remote "git@sync-host:tatwo/hot-sync.git" 2>&1 || true
)"
printf '%s\n' "$output" | grep -Fq -- '--os-root 必填' \
  || fail "missing OS root is not explained"
pass "enrollment fails closed without an explicit Work OS root"

output="$(
  HOME="${TMPDIR:-/tmp}/tatwo-enroll-test-home" \
    bash "$ENROLL" --dry-run --no-app --no-helper --name test-device \
      --os-root "$ROOT" 2>&1 || true
)"
printf '%s\n' "$output" | grep -Eq -- '--channel-remote|私人熱同步' \
  || fail "missing channel remote is not explained"
pass "enrollment fails closed without a private channel remote"

if HOME="${TMPDIR:-/tmp}/tatwo-enroll-test-home" \
  bash "$ENROLL" --dry-run --no-app --no-helper --name test-device \
    --os-root "$ROOT" \
    --channel-remote "https://github.com/tatwo214/hot-sync.git" >/dev/null 2>&1
then
  fail "HTTP(S) hot-sync remote was accepted"
fi
pass "enrollment rejects GitHub-style HTTP(S) hot-sync remotes"

EMPTY_SKILLS_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tatwo-enroll-empty-skills.XXXXXX")"
output="$(
  HOME="${TMPDIR:-/tmp}/tatwo-enroll-test-home" \
    bash "$ENROLL" --dry-run --no-app --no-helper --role secondary \
      --name test-device \
      --os-root "$ROOT" \
      --skills-root "$EMPTY_SKILLS_ROOT" \
      --channel-remote "git@sync-host:tatwo/hot-sync.git" 2>&1 || true
)"
rm -r "$EMPTY_SKILLS_ROOT"
printf '%s\n' "$output" | grep -Fq -- '--skills-root 未包含任何受管 SKILL.md' \
  || fail "explicit empty canonical skills root was accepted"
pass "enrollment validates explicit canonical skills coverage before mutation"

output="$(
  HOME="${TMPDIR:-/tmp}/tatwo-enroll-test-home" \
    bash "$ENROLL" --dry-run --no-app --name test-device \
      --os-root "$ROOT" \
      --channel-remote "git@sync-host:tatwo/hot-sync.git"
)"
printf '%s\n' "$output" | grep -Fq '私人熱同步 remote=git@sync-host:tatwo/hot-sync.git' \
  || fail "dry-run does not retain the private channel remote"
printf '%s\n' "$output" | grep -Fq "Work OS root=$ROOT" \
  || fail "dry-run does not retain the explicit Work OS root"
pass "enrollment carries the private channel remote into helper configuration"

RENDER_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tatwo-enroll-render.XXXXXX")"
RENDER_ROOT="$(cd "$RENDER_ROOT" && pwd -P)"
RENDER_HOME="$RENDER_ROOT/home"
RENDER_REPO="$RENDER_ROOT/repo"
RENDER_BIN="$RENDER_ROOT/bin"
export TATWO_TEST_MODE=1
export TATWO_DEVICE_TRUST_TEST_KEY_ROOT="$RENDER_ROOT/device-trust-test-keys"
test_signer_sha256() {
  shasum -a 256 "$1" | awk 'NR == 1 {print tolower($1)}'
}
test_signer_cdhash() {
  printf 'test-sha256-%s\n' "$(test_signer_sha256 "$1")"
}
mkdir -p "$RENDER_HOME" "$RENDER_REPO/scripts/templates" "$RENDER_BIN"
git -C "$RENDER_REPO" init -q -b release/tatwo-os
git -C "$RENDER_REPO" config user.name "Tatwo Enroll Test"
git -C "$RENDER_REPO" config user.email "tatwo-enroll@example.invalid"
printf '%s\n' "fixture" >"$RENDER_REPO/README.md"
git -C "$RENDER_REPO" add README.md
git -C "$RENDER_REPO" commit -q -m "fixture"
cat >"$RENDER_REPO/scripts/tatwo-device-sync.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ -z "${TATWO_TEST_SYNC_LOG:-}" ] \
  || printf '%s\n' "$*" >>"$TATWO_TEST_SYNC_LOG"
printf '%s\n' "mock device sync $*"
EOF
chmod +x "$RENDER_REPO/scripts/tatwo-device-sync.sh"
cp "$ROOT/scripts/templates/com.tatwo.device-sync-helper.plist" \
  "$RENDER_REPO/scripts/templates/com.tatwo.device-sync-helper.plist"
cp "$ROOT/scripts/tatwo-skills-consumer-projection.py" \
  "$RENDER_REPO/scripts/tatwo-skills-consumer-projection.py"
chmod +x "$RENDER_REPO/scripts/tatwo-skills-consumer-projection.py"
cat >"$RENDER_BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${TATWO_TEST_LAUNCHCTL_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$RENDER_BIN/launchctl"
TATWO_TEST_LAUNCHCTL_LOG="$RENDER_ROOT/launchctl-args.log"
export TATWO_TEST_LAUNCHCTL_LOG
cat >"$RENDER_BIN/tatwo-ultrawork" <<'EOF'
#!/usr/bin/env bash
echo '{"ok":false,"error":"Unknown command"}' >&2
exit 1
EOF
chmod +x "$RENDER_BIN/tatwo-ultrawork"
mkdir -p "$RENDER_HOME/.local/bin"
cp "$RENDER_BIN/tatwo-ultrawork" "$RENDER_HOME/.local/bin/tatwo-ultrawork"
RENDER_BUILT_CLI="$RENDER_REPO/.build/out/out/Products/Release/tatwo-ultrawork"
RENDER_SWIFT_LOG="$RENDER_ROOT/swift-args.log"
mkdir -p "$(dirname "$RENDER_BUILT_CLI")"
cat >"$RENDER_BUILT_CLI" <<'EOF'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  capabilities:enrollment)
    printf '%s\n' \
      '{"ok":true,"command":"capabilities enrollment","data":{"schema":"TatwoEnrollmentCapabilitiesV1","deviceTrustContract":"TatwoDeviceTrustCLI.v1","skilletContract":"TatwoSkilletCLI.v1"},"error":null}'
    exit 0
    ;;
  device-trust:assert-local)
    [ "${TATWO_TEST_DEVICE_TRUST_ASSERT_FAIL:-0}" != "1" ] || exit 75
    printf '%s\n' '{"ok":true,"command":"device-trust assert-local"}'
    exit 0
    ;;
  device-trust:sign)
    [ "${TATWO_TEST_DEVICE_TRUST_SIGN_FAIL:-0}" != "1" ] || exit 76
    signature_out=""
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --signature-out) signature_out="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$signature_out" ] || exit 77
    cat >"$signature_out" <<'JSON'
{"schema":"TatwoDeviceArtifactSignatureV1","payloadDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
JSON
    printf '%s\n' '{"ok":true,"command":"device-trust sign"}'
    exit 0
    ;;
  device-trust:verify)
    [ "${TATWO_TEST_DEVICE_TRUST_VERIFY_FAIL:-0}" != "1" ] || exit 78
    printf '%s\n' '{"ok":true,"command":"device-trust verify"}'
    exit 0
    ;;
esac
exit 1
EOF
chmod +x "$RENDER_BUILT_CLI"
cat >"$RENDER_BIN/swift" <<'EOF'
#!/usr/bin/env bash
{
  printf 'arg='
  printf '%q ' "$@"
  printf '\n'
} >>"${TATWO_TEST_SWIFT_LOG:?}"
case " $* " in
  *" --show-bin-path "*) ;;
  *)
    if [ "${TATWO_TEST_SWIFT_FAIL_BUILD:-0}" = "1" ]; then
      exit 71
    fi
    ;;
esac
case " $* " in
  *" --show-bin-path "*)
    printf '%s\n' "${TATWO_TEST_SWIFT_BIN_PATH:?}"
    ;;
esac
exit 0
EOF
chmod +x "$RENDER_BIN/swift"
cat >"$RENDER_BIN/cp" <<'EOF'
#!/usr/bin/env bash
destination="${!#}"
case "${TATWO_TEST_FAIL_ARCHIVE:-0}:$destination" in
  1:*enrollment-backups/tatwo-ultrawork-cli-previous-*)
    exit 72
    ;;
esac
exec /bin/cp "$@"
EOF
chmod +x "$RENDER_BIN/cp"
cat >"$RENDER_BIN/mv" <<'EOF'
#!/usr/bin/env bash
source_path="${1:-}"
destination="${!#}"
case "${TATWO_TEST_FAIL_ACTIVATION:-0}:$source_path:$destination" in
  1:*.staging.*:*/tatwo-ultrawork)
    exit 73
    ;;
esac
case "${TATWO_TEST_FAIL_SIGNER_ACTIVATION:-0}:$source_path:$destination" in
  1:*.staging.*:*/device-trust/signer/tatwo-device-trust-signer-v1)
    exit 74
    ;;
esac
case "${TATWO_TEST_FAIL_SIGNER_PIN_ACTIVATION:-0}:$source_path:$destination" in
  1:*.signer-pin.staging.*.json:*/device-trust/signer-pin.json)
    exit 75
    ;;
esac
/bin/mv "$@" || exit $?
case "${TATWO_TEST_CORRUPT_SIGNER_PIN_AFTER_ACTIVATION:-0}:$source_path:$destination" in
  1:*.signer-pin.staging.*.json:*/device-trust/signer-pin.json)
    plutil -replace sha256 -string \
      "0000000000000000000000000000000000000000000000000000000000000000" \
      "$destination"
    ;;
esac
exit 0
EOF
chmod +x "$RENDER_BIN/mv"

if PATH="$RENDER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$RENDER_HOME" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  TATWO_TEST_SWIFT_LOG="$RENDER_SWIFT_LOG" \
  TATWO_TEST_SWIFT_BIN_PATH="$(dirname "$RENDER_BUILT_CLI")" \
  bash "$ENROLL" --role primary --name test-device \
    --repo "$RENDER_REPO" --no-app --no-helper \
    --cli relative/tatwo-ultrawork \
    --os-root "$RENDER_REPO" \
    --channel-remote "git@sync-host:tatwo/hot-sync.git" >/dev/null 2>&1
then
  fail "relative explicit CLI path was accepted"
fi
pass "enrollment rejects a relative explicit CLI path without touching the source checkout"

NONFUNCTIONAL_TEST_PYTHON_HOME="$RENDER_ROOT/nonfunctional-test-python-home"
mkdir -p "$NONFUNCTIONAL_TEST_PYTHON_HOME"
if PATH="$RENDER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$NONFUNCTIONAL_TEST_PYTHON_HOME" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  TATWO_DEVICE_TRUST_TEST_PYTHON=/bin/true \
  TATWO_TEST_SWIFT_LOG="$RENDER_SWIFT_LOG" \
  TATWO_TEST_SWIFT_BIN_PATH="$(dirname "$RENDER_BUILT_CLI")" \
  bash "$ENROLL" --role primary --name test-device \
    --repo "$RENDER_REPO" --no-app --no-helper \
    --device-trust-cli "$RENDER_BUILT_CLI" \
    --device-trust-cli-sha256 "$(test_signer_sha256 "$RENDER_BUILT_CLI")" \
    --device-trust-cli-cdhash "$(test_signer_cdhash "$RENDER_BUILT_CLI")" \
    --os-root "$RENDER_REPO" \
    --channel-remote "git@sync-host:tatwo/hot-sync.git" >/dev/null 2>&1
then
  fail "/bin/true was accepted as the device-trust test Python"
fi
[ ! -e "$NONFUNCTIONAL_TEST_PYTHON_HOME/Library/Application Support/Tatwo Ultrawork/device-trust/signer-pin.json" ] \
  || fail "nonfunctional test Python activated a device-trust signer pin"
pass "enrollment requires a functional Python interpreter before authorizing test trust"

TOKEN_ECHO_TEST_PYTHON="$RENDER_ROOT/token-echo-test-python"
TOKEN_ECHO_TEST_PYTHON_HOME="$RENDER_ROOT/token-echo-test-python-home"
cat >"$TOKEN_ECHO_TEST_PYTHON" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'tatwo-device-trust-test-python-ok'
exit 0
EOF
chmod +x "$TOKEN_ECHO_TEST_PYTHON"
mkdir -p "$TOKEN_ECHO_TEST_PYTHON_HOME"
if PATH="$RENDER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$TOKEN_ECHO_TEST_PYTHON_HOME" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  TATWO_DEVICE_TRUST_TEST_PYTHON="$TOKEN_ECHO_TEST_PYTHON" \
  TATWO_TEST_SWIFT_LOG="$RENDER_SWIFT_LOG" \
  TATWO_TEST_SWIFT_BIN_PATH="$(dirname "$RENDER_BUILT_CLI")" \
  bash "$ENROLL" --role primary --name test-device \
    --repo "$RENDER_REPO" --no-app --no-helper \
    --device-trust-cli "$RENDER_BUILT_CLI" \
    --device-trust-cli-sha256 "$(test_signer_sha256 "$RENDER_BUILT_CLI")" \
    --device-trust-cli-cdhash "$(test_signer_cdhash "$RENDER_BUILT_CLI")" \
    --os-root "$RENDER_REPO" \
    --channel-remote "git@sync-host:tatwo/hot-sync.git" >/dev/null 2>&1
then
  fail "fixed-token echo script was accepted as the device-trust test Python"
fi
[ ! -e "$TOKEN_ECHO_TEST_PYTHON_HOME/Library/Application Support/Tatwo Ultrawork/device-trust/signer-pin.json" ] \
  || fail "fixed-token echo script activated a device-trust signer pin"
pass "test trust requires a challenge-bound Python response, not a fixed token"

SPECIAL_OS_ROOT="$RENDER_ROOT/os & skillet <primary> | canonical"
SPECIAL_REMOTE_APP_SUPPORT="$RENDER_ROOT/remote & app <support> | primary"
mkdir -p "$SPECIAL_OS_ROOT" "$SPECIAL_REMOTE_APP_SUPPORT"
if ! PATH="$RENDER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$RENDER_HOME" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  TATWO_TEST_SWIFT_LOG="$RENDER_SWIFT_LOG" \
  TATWO_TEST_SWIFT_BIN_PATH="$(dirname "$RENDER_BUILT_CLI")" \
  bash "$ENROLL" --role primary --name test-device \
    --repo "$RENDER_REPO" \
    --no-app \
    --os-root "$SPECIAL_OS_ROOT" \
    --remote-app-support "$SPECIAL_REMOTE_APP_SUPPORT" \
    --channel-remote "git@sync-host:tatwo/hot-sync.git" >/dev/null
then
  fail "helper plist rendering rejected or corrupted XML-special path values"
fi
RENDERED_PLIST="$RENDER_HOME/Library/LaunchAgents/com.tatwo.device-sync-helper.plist"
INSTALLED_TEST_CLI="$RENDER_HOME/.local/bin/tatwo-ultrawork"
INSTALLED_TRUST_SIGNER="$RENDER_HOME/Library/Application Support/Tatwo Ultrawork/device-trust/signer/tatwo-device-trust-signer-v1"
TRUST_SIGNER_PIN="$RENDER_HOME/Library/Application Support/Tatwo Ultrawork/device-trust/signer-pin.json"
plutil -lint "$RENDERED_PLIST" >/dev/null \
  || fail "rendered helper plist does not pass plutil lint"
[ "$(plutil -extract ProgramArguments.0 raw "$RENDERED_PLIST")" = "/bin/bash" ] \
  || fail "rendered helper plist changed the shell entrypoint"
[ "$(plutil -extract ProgramArguments.1 raw "$RENDERED_PLIST")" = "$RENDER_REPO/scripts/tatwo-sync-helper.sh" ] \
  || fail "rendered helper plist changed the helper entrypoint"
if plutil -extract ProgramArguments.2 raw "$RENDERED_PLIST" >/dev/null 2>&1; then
  fail "rendered helper plist retained an unexpected third argument"
fi
if grep -Fq '__HELPER_PATH__' "$RENDERED_PLIST"; then
  fail "rendered helper plist retained the helper placeholder"
fi
[ "$(plutil -extract EnvironmentVariables.TATWO_OS_ROOT raw "$RENDERED_PLIST")" = "$SPECIAL_OS_ROOT" ] \
  || fail "rendered helper plist changed the Work OS root"
EXPECTED_SKILLS_ROOT="$RENDER_HOME/Library/Application Support/Tatwo Ultrawork/skills"
[ "$(plutil -extract EnvironmentVariables.TATWO_SKILLET_SOURCE_ROOT raw "$RENDERED_PLIST")" = "$EXPECTED_SKILLS_ROOT" ] \
  || fail "rendered helper plist changed the canonical skills root"
[ "$(plutil -extract EnvironmentVariables.TATWO_SKILLS_RUNTIME_ROOT raw "$RENDERED_PLIST")" = "$RENDER_HOME/Library/Application Support/Tatwo Ultrawork/skills-runtime" ] \
  || fail "rendered helper plist did not isolate the Skillet runtime under App Support"
[ "$(plutil -extract EnvironmentVariables.TATWO_SKILLS_CONSUMER_ROOT raw "$RENDERED_PLIST")" = "$RENDER_HOME/Library/Application Support/Tatwo Ultrawork/skills-consumer" ] \
  || fail "rendered helper plist did not persist the managed skills consumer root"
[ "$(plutil -extract EnvironmentVariables.TATWO_CODEX_SKILLS_LINK raw "$RENDERED_PLIST")" = "$RENDER_HOME/.codex/skills" ] \
  || fail "rendered helper plist changed the Codex native skills entrypoint"
[ "$(plutil -extract EnvironmentVariables.TATWO_CLAUDE_SKILLS_LINK raw "$RENDERED_PLIST")" = "$RENDER_HOME/.claude/skills" ] \
  || fail "rendered helper plist changed the Claude native skills entrypoint"
[ "$(plutil -extract EnvironmentVariables.TATWO_SKILLS_CONSUMER_PROJECTION_SCRIPT raw "$RENDERED_PLIST")" = "$RENDER_REPO/scripts/tatwo-skills-consumer-projection.py" ] \
  || fail "rendered helper plist changed the projection helper path"
[ "$(plutil -extract EnvironmentVariables.TATWO_SKILLET_SOURCE_REGISTRY raw "$RENDERED_PLIST")" = "$RENDER_REPO/config/tatwo-skillet-source-registry-v1.json" ] \
  || fail "rendered helper plist changed the Skillet source registry"
[ "$(plutil -extract EnvironmentVariables.TATWO_REMOTE_APP_SUPPORT raw "$RENDERED_PLIST")" = "$SPECIAL_REMOTE_APP_SUPPORT" ] \
  || fail "rendered helper plist changed the remote app-support path"
[ -x "$INSTALLED_TEST_CLI" ] \
  || fail "stale CLI was not replaced from the current repo release product"
ARCHIVED_TEST_CLI="$(
  find "$RENDER_HOME/Library/Application Support/Tatwo Ultrawork/enrollment-backups" \
    -maxdepth 1 -type f -name 'tatwo-ultrawork-cli-previous-*' -print -quit
)"
[ -n "$ARCHIVED_TEST_CLI" ] \
  || fail "stale CLI was replaced without an archived rollback copy"
grep -Fq 'Unknown command' "$ARCHIVED_TEST_CLI" \
  || fail "archived CLI is not the exact pre-enrollment binary"
[ "$(plutil -extract EnvironmentVariables.TATWO_SKILLET_CLI raw "$RENDERED_PLIST")" = "$INSTALLED_TEST_CLI" ] \
  || fail "rendered helper plist changed the Skillet CLI path"
[ "$(plutil -extract EnvironmentVariables.TATWO_DEVICE_TRUST_CLI raw "$RENDERED_PLIST")" = "$INSTALLED_TRUST_SIGNER" ] \
  || fail "rendered helper plist changed the device trust CLI path"
[ "$INSTALLED_TRUST_SIGNER" != "$INSTALLED_TEST_CLI" ] \
  || fail "evolving Skillet CLI and immutable device trust signer were collapsed"
[ -x "$INSTALLED_TRUST_SIGNER" ] && [ ! -L "$INSTALLED_TRUST_SIGNER" ] \
  || fail "immutable device trust signer was not installed as a regular executable"
[ -f "$TRUST_SIGNER_PIN" ] && [ ! -L "$TRUST_SIGNER_PIN" ] \
  || fail "device trust signer pin was not persisted"
[ "$(stat -f '%Lp' "$TRUST_SIGNER_PIN")" = "600" ] \
  || fail "device trust signer pin is not mode 0600"
[ "$(plutil -extract signerPath raw "$TRUST_SIGNER_PIN")" = "$INSTALLED_TRUST_SIGNER" ] \
  || fail "device trust signer pin changed the anchored path"
[ "$(plutil -extract EnvironmentVariables.TATWO_DEVICE_TRUST_CLI_SHA256 raw "$RENDERED_PLIST")" = "$(plutil -extract sha256 raw "$TRUST_SIGNER_PIN")" ] \
  || fail "helper SHA-256 hint does not match the signer pin"
[ "$(plutil -extract EnvironmentVariables.TATWO_DEVICE_TRUST_CLI_CDHASH raw "$RENDERED_PLIST")" = "$(plutil -extract codeDirectoryHash raw "$TRUST_SIGNER_PIN")" ] \
  || fail "helper cdhash hint does not match the signer pin"
[ "$(plutil -extract EnvironmentVariables.TATWO_TEST_MODE raw "$RENDERED_PLIST")" = "0" ] \
  || fail "rendered helper plist did not permanently disable test mode"
[ "$(plutil -extract LimitLoadToSessionType raw "$RENDERED_PLIST")" = "Aqua" ] \
  || fail "rendered helper plist is not restricted to the Aqua login session"
grep -Fqx \
  "bootstrap gui/$(id -u) $RENDERED_PLIST" \
  "$TATWO_TEST_LAUNCHCTL_LOG" \
  || fail "enrollment did not bootstrap the helper into the explicit GUI launchd domain"
grep -Fqx \
  "kickstart -k gui/$(id -u)/com.tatwo.device-sync-helper" \
  "$TATWO_TEST_LAUNCHCTL_LOG" \
  || fail "enrollment did not start the Aqua helper after bootstrap"
if grep -Eq '(^| )(load|unload)( |$)' "$TATWO_TEST_LAUNCHCTL_LOG"; then
  fail "enrollment still uses ambiguous legacy launchctl load/unload"
fi
[ -L "$RENDER_HOME/Library/Application Support/Tatwo Ultrawork/skills-consumer/current" ] \
  || fail "enrollment did not create the managed current projection"
[ "$(readlink "$RENDER_HOME/Library/Application Support/Tatwo Ultrawork/skills-consumer/current")" = "$EXPECTED_SKILLS_ROOT" ] \
  || fail "enrollment bootstrap did not preserve the canonical source root"
[ -L "$EXPECTED_SKILLS_ROOT" ] \
  && [ "$(readlink "$EXPECTED_SKILLS_ROOT")" = "$RENDER_HOME/Library/Application Support/tatwo2/skills" ] \
  || fail "enrollment did not bridge App Support/skills to $RENDER_HOME/Library/Application Support/tatwo2/skills"
[ "$(readlink "$RENDER_HOME/.codex/skills")" = "$RENDER_HOME/Library/Application Support/Tatwo Ultrawork/skills-consumer/current" ] \
  || fail "enrollment did not bind Codex to managed current"
[ "$(readlink "$RENDER_HOME/.claude/skills")" = "$RENDER_HOME/Library/Application Support/Tatwo Ultrawork/skills-consumer/current" ] \
  || fail "enrollment did not bind Claude to managed current"
grep -Fq \
  "arg=build --package-path $RENDER_REPO --build-path $RENDER_REPO/.build/out --product tatwo-ultrawork -c release " \
  "$RENDER_SWIFT_LOG" \
  || fail "release CLI build arguments were not preserved"
grep -Fq \
  "arg=build --package-path $RENDER_REPO --build-path $RENDER_REPO/.build/out -c release --show-bin-path " \
  "$RENDER_SWIFT_LOG" \
  || fail "release CLI bin-path arguments were not preserved"
pass "stale CLI is atomically replaced and helper paths preserve XML and sed metacharacters"

INITIAL_TRUST_SIGNER_SHA="$(shasum -a 256 "$INSTALLED_TRUST_SIGNER" | awk '{print $1}')"
INITIAL_TRUST_PIN_SHA="$(shasum -a 256 "$TRUST_SIGNER_PIN" | awk '{print $1}')"
ARCHIVE_COUNT_BEFORE="$(
  find "$RENDER_HOME/Library/Application Support/Tatwo Ultrawork/enrollment-backups" \
    -maxdepth 1 -type f -name 'tatwo-ultrawork-cli-previous-*' | wc -l | tr -d ' '
)"

# Simulate the first successful Skillet activation before enrollment is run
# again. Re-enrollment must adopt this explicitly configured runtime, preserve
# its authority evidence and repair known native-link drift without falling
# back to canonical source.
RENDER_RUNTIME="$RENDER_HOME/Library/Application Support/Tatwo Ultrawork/skills-runtime"
RENDER_CONSUMER="$RENDER_HOME/Library/Application Support/Tatwo Ultrawork/skills-consumer"
RENDER_ACTIVATION_RECEIPT="$RENDER_ROOT/render-activation-receipt.json"
RENDER_SKILLET_ACTIVATION_RECEIPT="$RENDER_ROOT/render-skillet-activation-receipt.json"
RENDER_SET_MANIFEST="$RENDER_ROOT/render-set-manifest.json"
mkdir -p "$RENDER_RUNTIME/alpha"
printf '%s\n' \
  "---" \
  "name: alpha" \
  "description: Rendered enrollment runtime fixture" \
  "---" \
  "# rendered runtime alpha" \
  >"$RENDER_RUNTIME/alpha/SKILL.md"
RENDER_RUNTIME_DIGEST="$(
  python3 - "$RENDER_RUNTIME/alpha" <<'PY'
import hashlib
import os
import struct
import sys
import unicodedata

root = os.path.abspath(sys.argv[1])
files = []
for current, directories, names in os.walk(root, topdown=True, followlinks=False):
    directories[:] = sorted(directories)
    for name in sorted(names):
        path = os.path.join(current, name)
        relative = unicodedata.normalize(
            "NFC", os.path.relpath(path, root).replace(os.sep, "/")
        )
        with open(path, "rb") as handle:
            files.append((relative, handle.read()))
files.sort(key=lambda item: item[0].encode("utf-8"))
digest = hashlib.sha256()
for relative, data in files:
    encoded = relative.encode("utf-8")
    digest.update(struct.pack(">Q", len(encoded)))
    digest.update(encoded)
    digest.update(struct.pack(">Q", len(data)))
    digest.update(data)
print(digest.hexdigest())
PY
)"
cat >"$RENDER_SET_MANIFEST" <<EOF
{
  "schemaVersion": 1,
  "requestID": "render-enrollment-activation",
  "catalogRevision": "2026-07-26.1",
  "authorityEpoch": 2,
  "ledgerSequence": 3,
  "sourceDeviceID": "render-primary",
  "targetDeviceID": "render-primary",
  "repositories": [
    {
      "repositoryID": "alpha",
      "revisionID": "rev-$RENDER_RUNTIME_DIGEST",
      "contentDigest": "$RENDER_RUNTIME_DIGEST",
      "bundleDigest": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "bundleRelativePath": "repositories/alpha/bundle",
      "bindingRelativePath": "repositories/alpha/authority-binding.json"
    }
  ]
}
EOF
cat >"$RENDER_SKILLET_ACTIVATION_RECEIPT" <<EOF
{
  "schema": "TatwoSkilletSetActivationCLIOutputV1",
  "requestID": "render-enrollment-activation",
  "sourceDeviceID": "render-primary",
  "targetDeviceID": "render-primary",
  "authorityEpoch": 2,
  "ledgerSequence": 3,
  "catalogRevision": "2026-07-26.1",
  "activationState": "active",
  "targetPreservedRuntimeClosureCapability": "target-preserved-runtime-closure-v1",
  "targetPreservedRuntimeClosed": true,
  "repositoryCount": 1,
  "repositories": [
    {
      "repositoryID": "alpha",
      "revisionID": "rev-$RENDER_RUNTIME_DIGEST",
      "contentDigest": "$RENDER_RUNTIME_DIGEST",
      "requestID": "render-enrollment-activation",
      "sourceDeviceID": "render-primary",
      "targetDeviceID": "render-primary",
      "authorityEpoch": 2,
      "ledgerSequence": 3,
      "catalogRevision": "2026-07-26.1",
      "activationState": "active"
    }
  ],
  "targetPreservedCount": 0,
  "targetPreservedRepositories": []
}
EOF
python3 "$RENDER_REPO/scripts/tatwo-skills-consumer-projection.py" activate \
  --runtime-root "$RENDER_RUNTIME" \
  --consumer-root "$RENDER_CONSUMER" \
  --codex-skills-link "$RENDER_HOME/.codex/skills" \
  --claude-skills-link "$RENDER_HOME/.claude/skills" \
  --set-manifest "$RENDER_SET_MANIFEST" \
  --activation-receipt "$RENDER_SKILLET_ACTIVATION_RECEIPT" \
  --request "render-enrollment-activation" \
  --receipt "$RENDER_ACTIVATION_RECEIPT" >/dev/null \
  || fail "test fixture could not activate the rendered Skillet runtime"
rm "$RENDER_HOME/.claude/skills"
ln -s "$RENDER_HOME/Library/Application Support/tatwo2/skills" "$RENDER_HOME/.claude/skills"

if ! PATH="$RENDER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$RENDER_HOME" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  TATWO_TEST_SWIFT_LOG="$RENDER_SWIFT_LOG" \
  TATWO_TEST_SWIFT_BIN_PATH="$(dirname "$RENDER_BUILT_CLI")" \
  bash "$ENROLL" --role primary --name test-device \
    --repo "$RENDER_REPO" --no-app --no-helper \
    --os-root "$SPECIAL_OS_ROOT" \
    --channel-remote "git@sync-host:tatwo/hot-sync.git" >/dev/null
then
  fail "idempotent enrollment rerun failed"
fi
ARCHIVE_COUNT_AFTER="$(
  find "$RENDER_HOME/Library/Application Support/Tatwo Ultrawork/enrollment-backups" \
    -maxdepth 1 -type f -name 'tatwo-ultrawork-cli-previous-*' | wc -l | tr -d ' '
)"
[ "$ARCHIVE_COUNT_AFTER" = "$ARCHIVE_COUNT_BEFORE" ] \
  || fail "identical CLI rerun created an unnecessary rollback archive"
[ "$(readlink "$RENDER_CONSUMER/current")" = "$RENDER_RUNTIME" ] \
  || fail "re-enrollment switched an activated device back to canonical source"
[ "$(readlink "$RENDER_HOME/.codex/skills")" = "$RENDER_CONSUMER/current" ] \
  || fail "re-enrollment did not preserve the Codex managed indirection"
[ "$(readlink "$RENDER_HOME/.claude/skills")" = "$RENDER_CONSUMER/current" ] \
  || fail "re-enrollment did not repair the Claude managed indirection"
RENDER_ADOPTION_RECEIPT="$(
  grep -l '"operation": "adopt-runtime"' \
    "$RENDER_HOME/Library/Application Support/Tatwo Ultrawork/device-sync-state/skills-consumer-projection/enrollment/"*.json \
    | head -1
)"
[ -n "$RENDER_ADOPTION_RECEIPT" ] \
  || fail "re-enrollment emitted no runtime-adoption receipt"
[ "$(plutil -extract originActivationReceiptPath raw "$RENDER_ADOPTION_RECEIPT")" = "$RENDER_ACTIVATION_RECEIPT" ] \
  || fail "re-enrollment lost the origin activation receipt"
[ "$(plutil -extract mode raw "$RENDER_CONSUMER/.tatwo-binding/state.json")" = "runtime-adopted" ] \
  || fail "re-enrollment state does not distinguish runtime adoption"
grep -l '"operation": "bootstrap"' \
  "$RENDER_HOME/Library/Application Support/Tatwo Ultrawork/device-sync-state/skills-consumer-projection/enrollment/"*.json \
  >/dev/null \
  || fail "initial enrollment receipt does not distinguish source bootstrap"
pass "re-enrollment safely adopts the active runtime and keeps CLI archives stable"

FAILED_BUILD_DEST="$RENDER_ROOT/build-failure/bin/tatwo-ultrawork"
if PATH="$RENDER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$RENDER_HOME" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  TATWO_ULTRAWORK_CLI_DEST="$FAILED_BUILD_DEST" \
  TATWO_DEVICE_TRUST_CLI="$INSTALLED_TEST_CLI" \
  TATWO_SKILLET_CLI="$INSTALLED_TEST_CLI" \
  TATWO_TEST_SWIFT_LOG="$RENDER_SWIFT_LOG" \
  TATWO_TEST_SWIFT_BIN_PATH="$(dirname "$RENDER_BUILT_CLI")" \
  TATWO_TEST_SWIFT_FAIL_BUILD=1 \
  bash "$ENROLL" --role primary --name test-device \
    --repo "$RENDER_REPO" --no-app --no-helper \
    --os-root "$SPECIAL_OS_ROOT" \
    --channel-remote "git@sync-host:tatwo/hot-sync.git" >/dev/null 2>&1
then
  fail "failed release build was allowed to install a stale CLI artifact"
fi
[ ! -e "$FAILED_BUILD_DEST" ] \
  || fail "failed release build mutated the governed CLI destination"
pass "release build failure cannot fall through to a stale build artifact"

EXPLICIT_CLI="$RENDER_ROOT/explicit-tatwo-ultrawork"
cp "$RENDER_BUILT_CLI" "$EXPLICIT_CLI"
printf '%s\n' '# explicit-cli-source-marker' >>"$EXPLICIT_CLI"
chmod +x "$EXPLICIT_CLI"
if ! PATH="$RENDER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$RENDER_HOME" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  TATWO_TEST_SWIFT_LOG="$RENDER_SWIFT_LOG" \
  TATWO_TEST_SWIFT_BIN_PATH="$(dirname "$RENDER_BUILT_CLI")" \
  bash "$ENROLL" --role primary --name test-device \
    --repo "$RENDER_REPO" --no-app --no-helper \
    --cli "$EXPLICIT_CLI" \
    --os-root "$SPECIAL_OS_ROOT" \
    --channel-remote "git@sync-host:tatwo/hot-sync.git" >/dev/null
then
  fail "valid explicit CLI source was not installed"
fi
grep -Fq '# explicit-cli-source-marker' "$INSTALLED_TEST_CLI" \
  || fail "explicit CLI source did not replace the governed CLI destination"
pass "explicit CLI source is copied into the governed helper and PATH destination"

[ "$(shasum -a 256 "$INSTALLED_TRUST_SIGNER" | awk '{print $1}')" = "$INITIAL_TRUST_SIGNER_SHA" ] \
  || fail "evolving Skillet CLI update silently replaced the healthy signer anchor"
[ "$(shasum -a 256 "$TRUST_SIGNER_PIN" | awk '{print $1}')" = "$INITIAL_TRUST_PIN_SHA" ] \
  || fail "evolving Skillet CLI update silently rewrote the healthy signer pin"
pass "healthy immutable signer remains unchanged across an evolving Skillet CLI update"

DEVICE_TRUST_IDENTITY="$RENDER_HOME/Library/Application Support/Tatwo Ultrawork/device-trust/identity.json"
mkdir -p "$(dirname "$DEVICE_TRUST_IDENTITY")"
cat >"$DEVICE_TRUST_IDENTITY" <<'EOF'
{
  "schema": "TatwoDevicePublicIdentityV1",
  "deviceID": "test-device-id",
  "keyID": "ed25519-test-device-key",
  "keyGeneration": 1
}
EOF
chmod 600 "$DEVICE_TRUST_IDENTITY"

IDENTITY_BACKUP="$RENDER_ROOT/device-trust-identity.regular.json"
mv "$DEVICE_TRUST_IDENTITY" "$IDENTITY_BACKUP"
ln -s "$IDENTITY_BACKUP" "$DEVICE_TRUST_IDENTITY"
SYMLINK_IDENTITY_SIGNER="$RENDER_ROOT/symlink-identity-device-trust-signer"
cp "$RENDER_BUILT_CLI" "$SYMLINK_IDENTITY_SIGNER"
printf '%s\n' '# symlink-identity-device-trust-signer-marker' \
  >>"$SYMLINK_IDENTITY_SIGNER"
chmod +x "$SYMLINK_IDENTITY_SIGNER"
if PATH="$RENDER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$RENDER_HOME" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  TATWO_TEST_SWIFT_LOG="$RENDER_SWIFT_LOG" \
  TATWO_TEST_SWIFT_BIN_PATH="$(dirname "$RENDER_BUILT_CLI")" \
  bash "$ENROLL" --role primary --name test-device \
    --repo "$RENDER_REPO" --no-app --no-helper \
    --cli "$INSTALLED_TEST_CLI" \
    --device-trust-cli "$SYMLINK_IDENTITY_SIGNER" \
    --device-trust-cli-sha256 "$(test_signer_sha256 "$SYMLINK_IDENTITY_SIGNER")" \
    --device-trust-cli-cdhash "$(test_signer_cdhash "$SYMLINK_IDENTITY_SIGNER")" \
    --os-root "$SPECIAL_OS_ROOT" \
    --channel-remote "git@sync-host:tatwo/hot-sync.git" >/dev/null 2>&1
then
  fail "symlinked identity bypassed signer possession proof"
fi
[ "$(shasum -a 256 "$INSTALLED_TRUST_SIGNER" | awk '{print $1}')" = "$INITIAL_TRUST_SIGNER_SHA" ] \
  || fail "symlinked identity changed the active signer"
mv "$DEVICE_TRUST_IDENTITY" "$RENDER_ROOT/rejected-device-trust-identity.symlink"
mv "$IDENTITY_BACKUP" "$DEVICE_TRUST_IDENTITY"
pass "non-regular identity fails closed instead of skipping signer possession proof"

ADOPTED_SIGNER="$RENDER_ROOT/adopted-device-trust-signer"
cp "$RENDER_BUILT_CLI" "$ADOPTED_SIGNER"
printf '%s\n' '# adopted-device-trust-signer-marker' >>"$ADOPTED_SIGNER"
chmod +x "$ADOPTED_SIGNER"
if PATH="$RENDER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$RENDER_HOME" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  TATWO_TEST_SWIFT_LOG="$RENDER_SWIFT_LOG" \
  TATWO_TEST_SWIFT_BIN_PATH="$(dirname "$RENDER_BUILT_CLI")" \
  bash "$ENROLL" --role primary --name test-device \
    --repo "$RENDER_REPO" --no-app --no-helper \
    --cli "$INSTALLED_TEST_CLI" \
    --device-trust-cli "$ADOPTED_SIGNER" \
    --os-root "$SPECIAL_OS_ROOT" \
    --channel-remote "git@sync-host:tatwo/hot-sync.git" >/dev/null 2>&1
then
  fail "explicit signer adoption without expected pins was accepted"
fi
[ "$(shasum -a 256 "$INSTALLED_TRUST_SIGNER" | awk '{print $1}')" = "$INITIAL_TRUST_SIGNER_SHA" ] \
  || fail "missing expected pins changed the active signer"
pass "explicit signer adoption requires expected SHA-256 and CDHash"

if PATH="$RENDER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$RENDER_HOME" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  TATWO_TEST_SWIFT_LOG="$RENDER_SWIFT_LOG" \
  TATWO_TEST_SWIFT_BIN_PATH="$(dirname "$RENDER_BUILT_CLI")" \
  bash "$ENROLL" --role primary --name test-device \
    --repo "$RENDER_REPO" --no-app --no-helper \
    --cli "$INSTALLED_TEST_CLI" \
    --device-trust-cli "$ADOPTED_SIGNER" \
    --device-trust-cli-sha256 "0000000000000000000000000000000000000000000000000000000000000000" \
    --device-trust-cli-cdhash "$(test_signer_cdhash "$ADOPTED_SIGNER")" \
    --os-root "$SPECIAL_OS_ROOT" \
    --channel-remote "git@sync-host:tatwo/hot-sync.git" >/dev/null 2>&1
then
  fail "explicit signer adoption accepted a mismatched expected SHA-256"
fi
[ "$(shasum -a 256 "$INSTALLED_TRUST_SIGNER" | awk '{print $1}')" = "$INITIAL_TRUST_SIGNER_SHA" ] \
  || fail "mismatched expected SHA-256 changed the active signer"
pass "explicit signer adoption is bound to the expected signer bytes"

if ! PATH="$RENDER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$RENDER_HOME" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  TATWO_TEST_SWIFT_LOG="$RENDER_SWIFT_LOG" \
  TATWO_TEST_SWIFT_BIN_PATH="$(dirname "$RENDER_BUILT_CLI")" \
  bash "$ENROLL" --role primary --name test-device \
    --repo "$RENDER_REPO" --no-app --no-helper \
    --cli "$INSTALLED_TEST_CLI" \
    --device-trust-cli "$ADOPTED_SIGNER" \
    --device-trust-cli-sha256 "$(test_signer_sha256 "$ADOPTED_SIGNER")" \
    --device-trust-cli-cdhash "$(test_signer_cdhash "$ADOPTED_SIGNER")" \
    --os-root "$SPECIAL_OS_ROOT" \
    --channel-remote "git@sync-host:tatwo/hot-sync.git" >/dev/null
then
  fail "fresh-nonce-proven signer adoption was rejected"
fi
grep -Fq '# adopted-device-trust-signer-marker' "$INSTALLED_TRUST_SIGNER" \
  || fail "proven signer adoption did not activate the requested signer"
ADOPTION_RECEIPT="$(
  find "$RENDER_HOME/Library/Application Support/Tatwo Ultrawork/device-trust/signer-adoption-receipts" \
    -type f -name receipt.json -print | sort | tail -1
)"
[ -n "$ADOPTION_RECEIPT" ] \
  || fail "signer adoption produced no durable receipt"
[ "$(plutil -extract sourceMode raw "$ADOPTION_RECEIPT")" = "explicit-adoption" ] \
  || fail "signer adoption receipt lost the explicit-adoption mode"
[ "$(plutil -extract keyID raw "$ADOPTION_RECEIPT")" = "ed25519-test-device-key" ] \
  || fail "signer adoption receipt is not bound to the existing identity"
[ "$(plutil -extract expectedSHA256 raw "$ADOPTION_RECEIPT")" = "$(test_signer_sha256 "$ADOPTED_SIGNER")" ] \
  || fail "signer adoption receipt lost the expected SHA-256"
[ "$(plutil -extract expectedCodeDirectoryHash raw "$ADOPTION_RECEIPT")" = "$(test_signer_cdhash "$ADOPTED_SIGNER")" ] \
  || fail "signer adoption receipt lost the expected CDHash"
[ "$(plutil -extract identityDigest raw "$ADOPTION_RECEIPT")" = "$(shasum -a 256 "$DEVICE_TRUST_IDENTITY" | awk '{print $1}')" ] \
  || fail "signer adoption receipt is not bound to the exact existing identity bytes"
ADOPTION_NONCE_DIGEST="$(plutil -extract nonceDigest raw "$ADOPTION_RECEIPT")"
case "$ADOPTION_NONCE_DIGEST" in
  ""|*[!0-9a-f]*) fail "signer adoption receipt omitted the fresh nonce digest" ;;
  *) ;;
esac
[ "${#ADOPTION_NONCE_DIGEST}" = "64" ] \
  || fail "signer adoption receipt nonce digest is not a lowercase SHA-256"
pass "existing identity signer adoption requires and records a fresh nonce proof"

PROVEN_SIGNER_SHA="$(shasum -a 256 "$INSTALLED_TRUST_SIGNER" | awk '{print $1}')"
PROVEN_PIN_SHA="$(shasum -a 256 "$TRUST_SIGNER_PIN" | awk '{print $1}')"
POST_PROOF_SWAP_SIGNER="$RENDER_ROOT/post-proof-swap-device-trust-signer"
cat >"$POST_PROOF_SWAP_SIGNER" <<EOF
#!/usr/bin/env bash
"$ADOPTED_SIGNER" "\$@"
status=\$?
if [ "\${1:-}:\${2:-}" = "device-trust:sign" ] && [ "\$status" -eq 0 ]; then
  printf '%s\n' '# post-proof-swap-marker' >>"\$0"
fi
exit "\$status"
EOF
chmod +x "$POST_PROOF_SWAP_SIGNER"
POST_PROOF_SWAP_SHA="$(test_signer_sha256 "$POST_PROOF_SWAP_SIGNER")"
POST_PROOF_SWAP_CDHASH="$(test_signer_cdhash "$POST_PROOF_SWAP_SIGNER")"
if PATH="$RENDER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$RENDER_HOME" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  TATWO_TEST_SWIFT_LOG="$RENDER_SWIFT_LOG" \
  TATWO_TEST_SWIFT_BIN_PATH="$(dirname "$RENDER_BUILT_CLI")" \
  bash "$ENROLL" --role primary --name test-device \
    --repo "$RENDER_REPO" --no-app --no-helper \
    --cli "$INSTALLED_TEST_CLI" \
    --device-trust-cli "$POST_PROOF_SWAP_SIGNER" \
    --device-trust-cli-sha256 "$POST_PROOF_SWAP_SHA" \
    --device-trust-cli-cdhash "$POST_PROOF_SWAP_CDHASH" \
    --os-root "$SPECIAL_OS_ROOT" \
    --channel-remote "git@sync-host:tatwo/hot-sync.git" >/dev/null 2>&1
then
  fail "signer swapped after possession proof was installed"
fi
[ "$(shasum -a 256 "$INSTALLED_TRUST_SIGNER" | awk '{print $1}')" = "$PROVEN_SIGNER_SHA" ] \
  || fail "post-proof signer swap changed the active signer"
[ "$(shasum -a 256 "$TRUST_SIGNER_PIN" | awk '{print $1}')" = "$PROVEN_PIN_SHA" ] \
  || fail "post-proof signer swap changed the active signer pin"
grep -Fq '# post-proof-swap-marker' "$POST_PROOF_SWAP_SIGNER" \
  || fail "post-proof signer swap fixture did not mutate after signing"
pass "signer bytes are re-pinned after possession proof and before installation"

UNPROVEN_SIGNER="$RENDER_ROOT/unproven-device-trust-signer"
cp "$RENDER_BUILT_CLI" "$UNPROVEN_SIGNER"
printf '%s\n' '# unproven-device-trust-signer-marker' >>"$UNPROVEN_SIGNER"
chmod +x "$UNPROVEN_SIGNER"
if PATH="$RENDER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$RENDER_HOME" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  TATWO_TEST_SWIFT_LOG="$RENDER_SWIFT_LOG" \
  TATWO_TEST_SWIFT_BIN_PATH="$(dirname "$RENDER_BUILT_CLI")" \
  TATWO_TEST_DEVICE_TRUST_ASSERT_FAIL=1 \
  bash "$ENROLL" --role primary --name test-device \
    --repo "$RENDER_REPO" --no-app --no-helper \
    --cli "$INSTALLED_TEST_CLI" \
    --device-trust-cli "$UNPROVEN_SIGNER" \
    --device-trust-cli-sha256 "$(test_signer_sha256 "$UNPROVEN_SIGNER")" \
    --device-trust-cli-cdhash "$(test_signer_cdhash "$UNPROVEN_SIGNER")" \
    --os-root "$SPECIAL_OS_ROOT" \
    --channel-remote "git@sync-host:tatwo/hot-sync.git" >/dev/null 2>&1
then
  fail "signer without existing-key possession proof was adopted"
fi
[ "$(shasum -a 256 "$INSTALLED_TRUST_SIGNER" | awk '{print $1}')" = "$PROVEN_SIGNER_SHA" ] \
  || fail "failed possession proof changed the active signer"
[ "$(shasum -a 256 "$TRUST_SIGNER_PIN" | awk '{print $1}')" = "$PROVEN_PIN_SHA" ] \
  || fail "failed possession proof changed the authoritative pin"
pass "missing fresh nonce possession proof fails closed before signer activation"

ROLLBACK_SIGNER="$RENDER_ROOT/rollback-device-trust-signer"
cp "$RENDER_BUILT_CLI" "$ROLLBACK_SIGNER"
printf '%s\n' '# rollback-device-trust-signer-marker' >>"$ROLLBACK_SIGNER"
chmod +x "$ROLLBACK_SIGNER"
if PATH="$RENDER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$RENDER_HOME" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  TATWO_TEST_SWIFT_LOG="$RENDER_SWIFT_LOG" \
  TATWO_TEST_SWIFT_BIN_PATH="$(dirname "$RENDER_BUILT_CLI")" \
  TATWO_TEST_FAIL_SIGNER_PIN_ACTIVATION=1 \
  bash "$ENROLL" --role primary --name test-device \
    --repo "$RENDER_REPO" --no-app --no-helper \
    --cli "$INSTALLED_TEST_CLI" \
    --device-trust-cli "$ROLLBACK_SIGNER" \
    --device-trust-cli-sha256 "$(test_signer_sha256 "$ROLLBACK_SIGNER")" \
    --device-trust-cli-cdhash "$(test_signer_cdhash "$ROLLBACK_SIGNER")" \
    --os-root "$SPECIAL_OS_ROOT" \
    --channel-remote "git@sync-host:tatwo/hot-sync.git" >/dev/null 2>&1
then
  fail "partial signer/pin activation was reported as successful"
fi
[ "$(shasum -a 256 "$INSTALLED_TRUST_SIGNER" | awk '{print $1}')" = "$PROVEN_SIGNER_SHA" ] \
  || fail "pin activation failure did not restore the previous signer"
[ "$(shasum -a 256 "$TRUST_SIGNER_PIN" | awk '{print $1}')" = "$PROVEN_PIN_SHA" ] \
  || fail "pin activation failure did not restore the previous pin"
pass "partial signer/pin activation atomically restores the previous anchor pair"

POST_VERIFY_SIGNER="$RENDER_ROOT/post-verify-device-trust-signer"
cp "$RENDER_BUILT_CLI" "$POST_VERIFY_SIGNER"
printf '%s\n' '# post-verify-device-trust-signer-marker' >>"$POST_VERIFY_SIGNER"
chmod +x "$POST_VERIFY_SIGNER"
if PATH="$RENDER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$RENDER_HOME" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  TATWO_TEST_SWIFT_LOG="$RENDER_SWIFT_LOG" \
  TATWO_TEST_SWIFT_BIN_PATH="$(dirname "$RENDER_BUILT_CLI")" \
  TATWO_TEST_CORRUPT_SIGNER_PIN_AFTER_ACTIVATION=1 \
  bash "$ENROLL" --role primary --name test-device \
    --repo "$RENDER_REPO" --no-app --no-helper \
    --cli "$INSTALLED_TEST_CLI" \
    --device-trust-cli "$POST_VERIFY_SIGNER" \
    --device-trust-cli-sha256 "$(test_signer_sha256 "$POST_VERIFY_SIGNER")" \
    --device-trust-cli-cdhash "$(test_signer_cdhash "$POST_VERIFY_SIGNER")" \
    --os-root "$SPECIAL_OS_ROOT" \
    --channel-remote "git@sync-host:tatwo/hot-sync.git" >/dev/null 2>&1
then
  fail "post-activation signer pin corruption was reported as successful"
fi
[ "$(shasum -a 256 "$INSTALLED_TRUST_SIGNER" | awk '{print $1}')" = "$PROVEN_SIGNER_SHA" ] \
  || fail "post-activation verification failure did not restore the previous signer"
[ "$(shasum -a 256 "$TRUST_SIGNER_PIN" | awk '{print $1}')" = "$PROVEN_PIN_SHA" ] \
  || fail "post-activation verification failure did not restore the previous pin"
pass "post-activation signer verification failure restores the previous anchor pair"

FIRST_KEY_FAIL_HOME="$RENDER_ROOT/first-key-failure-home"
FIRST_KEY_SYNC_LOG="$RENDER_ROOT/first-key-failure-sync.log"
if PATH="$RENDER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$FIRST_KEY_FAIL_HOME" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  TATWO_TEST_SWIFT_LOG="$RENDER_SWIFT_LOG" \
  TATWO_TEST_SWIFT_BIN_PATH="$(dirname "$RENDER_BUILT_CLI")" \
  TATWO_TEST_SYNC_LOG="$FIRST_KEY_SYNC_LOG" \
  TATWO_TEST_FAIL_SIGNER_PIN_ACTIVATION=1 \
  bash "$ENROLL" --role primary --name first-key-device \
    --repo "$RENDER_REPO" --no-app --no-helper \
    --cli "$EXPLICIT_CLI" \
    --device-trust-cli "$ADOPTED_SIGNER" \
    --device-trust-cli-sha256 "$(test_signer_sha256 "$ADOPTED_SIGNER")" \
    --device-trust-cli-cdhash "$(test_signer_cdhash "$ADOPTED_SIGNER")" \
    --os-root "$SPECIAL_OS_ROOT" \
    --channel-remote "git@sync-host:tatwo/hot-sync.git" >/dev/null 2>&1
then
  fail "first-key enrollment continued after signer anchor activation failed"
fi
[ ! -e "$FIRST_KEY_FAIL_HOME/Library/Application Support/Tatwo Ultrawork/device-trust/signer-pin.json" ] \
  || fail "first-key failure left an authoritative signer pin"
[ ! -e "$FIRST_KEY_FAIL_HOME/Library/Application Support/Tatwo Ultrawork/device-trust/signer/tatwo-device-trust-signer-v1" ] \
  || fail "first-key failure left an unpaired signer anchor"
[ ! -e "$FIRST_KEY_SYNC_LOG" ] \
  || fail "device registration ran before the first signer anchor was installed"
pass "first device key creation cannot run before signer anchor installation succeeds"

LOST_SIGNER_ARCHIVE="$RENDER_ROOT/lost-signer-recovery-evidence"
mv "$INSTALLED_TRUST_SIGNER" "$LOST_SIGNER_ARCHIVE"
if PATH="$RENDER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$RENDER_HOME" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  TATWO_TEST_SWIFT_LOG="$RENDER_SWIFT_LOG" \
  TATWO_TEST_SWIFT_BIN_PATH="$(dirname "$RENDER_BUILT_CLI")" \
  bash "$ENROLL" --role primary --name test-device \
    --repo "$RENDER_REPO" --no-app --no-helper \
    --cli "$INSTALLED_TEST_CLI" \
    --os-root "$SPECIAL_OS_ROOT" \
    --channel-remote "git@sync-host:tatwo/hot-sync.git" >/dev/null 2>&1
then
  fail "missing signer anchor was silently recreated from the evolving CLI"
fi
[ ! -e "$INSTALLED_TRUST_SIGNER" ] \
  || fail "missing signer recovery silently installed a replacement signer"
mv "$LOST_SIGNER_ARCHIVE" "$INSTALLED_TRUST_SIGNER"
[ "$(shasum -a 256 "$INSTALLED_TRUST_SIGNER" | awk '{print $1}')" = "$PROVEN_SIGNER_SHA" ] \
  || fail "test restoration did not recover the exact prior signer"
pass "lost signer fails closed and requires governed identity rotation/re-enrollment"

LOST_PAIR_SIGNER_ARCHIVE="$RENDER_ROOT/lost-pair-signer-recovery-evidence"
LOST_PAIR_PIN_ARCHIVE="$RENDER_ROOT/lost-pair-pin-recovery-evidence.json"
mv "$INSTALLED_TRUST_SIGNER" "$LOST_PAIR_SIGNER_ARCHIVE"
mv "$TRUST_SIGNER_PIN" "$LOST_PAIR_PIN_ARCHIVE"
if PATH="$RENDER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$RENDER_HOME" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  TATWO_TEST_SWIFT_LOG="$RENDER_SWIFT_LOG" \
  TATWO_TEST_SWIFT_BIN_PATH="$(dirname "$RENDER_BUILT_CLI")" \
  bash "$ENROLL" --role primary --name test-device \
    --repo "$RENDER_REPO" --no-app --no-helper \
    --cli "$INSTALLED_TEST_CLI" \
    --os-root "$SPECIAL_OS_ROOT" \
    --channel-remote "git@sync-host:tatwo/hot-sync.git" >/dev/null 2>&1
then
  fail "existing identity silently reseeded a completely missing signer pair"
fi
[ ! -e "$INSTALLED_TRUST_SIGNER" ] \
  || fail "both-missing recovery installed an ungoverned signer"
[ ! -e "$TRUST_SIGNER_PIN" ] \
  || fail "both-missing recovery installed an ungoverned pin"
pass "existing identity with both signer and pin missing rejects automatic reseeding"

LOST_PAIR_SIGNER_SHA="$(test_signer_sha256 "$LOST_PAIR_SIGNER_ARCHIVE")"
LOST_PAIR_SIGNER_CDHASH="$(test_signer_cdhash "$LOST_PAIR_SIGNER_ARCHIVE")"
if ! PATH="$RENDER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$RENDER_HOME" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  TATWO_TEST_SWIFT_LOG="$RENDER_SWIFT_LOG" \
  TATWO_TEST_SWIFT_BIN_PATH="$(dirname "$RENDER_BUILT_CLI")" \
  bash "$ENROLL" --role primary --name test-device \
    --repo "$RENDER_REPO" --no-app --no-helper \
    --cli "$INSTALLED_TEST_CLI" \
    --device-trust-cli "$LOST_PAIR_SIGNER_ARCHIVE" \
    --device-trust-cli-sha256 "$LOST_PAIR_SIGNER_SHA" \
    --device-trust-cli-cdhash "$LOST_PAIR_SIGNER_CDHASH" \
    --os-root "$SPECIAL_OS_ROOT" \
    --channel-remote "git@sync-host:tatwo/hot-sync.git" >/dev/null
then
  fail "receipt-bound legacy signer adoption could not recover a missing anchor pair"
fi
[ "$(test_signer_sha256 "$INSTALLED_TRUST_SIGNER")" = "$LOST_PAIR_SIGNER_SHA" ] \
  || fail "legacy signer adoption did not restore the exact expected signer bytes"
[ "$(plutil -extract sha256 raw "$TRUST_SIGNER_PIN")" = "$LOST_PAIR_SIGNER_SHA" ] \
  || fail "legacy signer adoption pin lost the expected SHA-256"
[ "$(plutil -extract codeDirectoryHash raw "$TRUST_SIGNER_PIN")" = "$LOST_PAIR_SIGNER_CDHASH" ] \
  || fail "legacy signer adoption pin lost the expected CDHash"
LEGACY_ADOPTION_RECEIPT="$(
  find "$RENDER_HOME/Library/Application Support/Tatwo Ultrawork/device-trust/signer-adoption-receipts" \
    -type f -name receipt.json -print | sort | tail -1
)"
[ "$(plutil -extract signerSourcePath raw "$LEGACY_ADOPTION_RECEIPT")" = "$LOST_PAIR_SIGNER_ARCHIVE" ] \
  || fail "legacy adoption receipt lost the exact source path"
[ "$(plutil -extract identityDigest raw "$LEGACY_ADOPTION_RECEIPT")" = "$(shasum -a 256 "$DEVICE_TRUST_IDENTITY" | awk '{print $1}')" ] \
  || fail "legacy adoption receipt lost the existing identity digest"
pass "explicit expected pins and fresh nonce proof recover an identity with a missing anchor pair"

ARCHIVE_FAIL_HOME="$RENDER_ROOT/archive-failure-home"
ARCHIVE_FAIL_DEST="$ARCHIVE_FAIL_HOME/.local/bin/tatwo-ultrawork"
mkdir -p "$(dirname "$ARCHIVE_FAIL_DEST")"
cp "$RENDER_BUILT_CLI" "$ARCHIVE_FAIL_DEST"
printf '%s\n' '# preserved-old-cli-marker' >>"$ARCHIVE_FAIL_DEST"
chmod +x "$ARCHIVE_FAIL_DEST"
if PATH="$RENDER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$ARCHIVE_FAIL_HOME" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  TATWO_TEST_SWIFT_LOG="$RENDER_SWIFT_LOG" \
  TATWO_TEST_SWIFT_BIN_PATH="$(dirname "$RENDER_BUILT_CLI")" \
  TATWO_TEST_FAIL_ARCHIVE=1 \
  bash "$ENROLL" --role primary --name test-device \
    --repo "$RENDER_REPO" --no-app --no-helper \
    --cli "$EXPLICIT_CLI" \
    --os-root "$SPECIAL_OS_ROOT" \
    --channel-remote "git@sync-host:tatwo/hot-sync.git" >/dev/null 2>&1
then
  fail "CLI replacement continued after rollback archive creation failed"
fi
grep -Fq '# preserved-old-cli-marker' "$ARCHIVE_FAIL_DEST" \
  || fail "archive failure changed or removed the previously active CLI"
if grep -Fq '# explicit-cli-source-marker' "$ARCHIVE_FAIL_DEST"; then
  fail "archive failure still activated the replacement CLI"
fi
pass "rollback archive failure preserves the previously active CLI and fails closed"

ACTIVATION_FAIL_HOME="$RENDER_ROOT/activation-failure-home"
ACTIVATION_FAIL_DEST="$ACTIVATION_FAIL_HOME/.local/bin/tatwo-ultrawork"
mkdir -p "$(dirname "$ACTIVATION_FAIL_DEST")"
cp "$RENDER_BUILT_CLI" "$ACTIVATION_FAIL_DEST"
printf '%s\n' '# activation-preserved-old-cli-marker' >>"$ACTIVATION_FAIL_DEST"
chmod +x "$ACTIVATION_FAIL_DEST"
if PATH="$RENDER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$ACTIVATION_FAIL_HOME" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  TATWO_TEST_SWIFT_LOG="$RENDER_SWIFT_LOG" \
  TATWO_TEST_SWIFT_BIN_PATH="$(dirname "$RENDER_BUILT_CLI")" \
  TATWO_TEST_FAIL_ACTIVATION=1 \
  bash "$ENROLL" --role primary --name test-device \
    --repo "$RENDER_REPO" --no-app --no-helper \
    --cli "$EXPLICIT_CLI" \
    --os-root "$SPECIAL_OS_ROOT" \
    --channel-remote "git@sync-host:tatwo/hot-sync.git" >/dev/null 2>&1
then
  fail "failed atomic activation was reported as successful"
fi
grep -Fq '# activation-preserved-old-cli-marker' "$ACTIVATION_FAIL_DEST" \
  || fail "activation failure did not leave the previously active CLI in place"
if grep -Fq '# explicit-cli-source-marker' "$ACTIVATION_FAIL_DEST"; then
  fail "activation failure still replaced the governed CLI destination"
fi
pass "atomic activation failure leaves the previous CLI continuously available"

POST_VERIFY_HOME="$RENDER_ROOT/post-verify-failure-home"
POST_VERIFY_DEST="$POST_VERIFY_HOME/.local/bin/tatwo-ultrawork"
POST_VERIFY_SOURCE="$RENDER_ROOT/post-verify-source"
mkdir -p "$(dirname "$POST_VERIFY_DEST")"
cp "$RENDER_BUILT_CLI" "$POST_VERIFY_DEST"
printf '%s\n' '# post-verify-preserved-old-cli-marker' >>"$POST_VERIFY_DEST"
chmod +x "$POST_VERIFY_DEST"
cat >"$POST_VERIFY_SOURCE" <<'EOF'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  capabilities:enrollment)
    case "$0" in
      */.local/bin/tatwo-ultrawork) exit 74 ;;
    esac
    printf '%s\n' \
      '{"ok":true,"command":"capabilities enrollment","data":{"schema":"TatwoEnrollmentCapabilitiesV1","deviceTrustContract":"TatwoDeviceTrustCLI.v1","skilletContract":"TatwoSkilletCLI.v1"},"error":null}'
    exit 0
    ;;
esac
exit 1
EOF
printf '%s\n' '# post-verify-new-cli-marker' >>"$POST_VERIFY_SOURCE"
chmod +x "$POST_VERIFY_SOURCE"
if PATH="$RENDER_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$POST_VERIFY_HOME" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  TATWO_TEST_SWIFT_LOG="$RENDER_SWIFT_LOG" \
  TATWO_TEST_SWIFT_BIN_PATH="$(dirname "$RENDER_BUILT_CLI")" \
  bash "$ENROLL" --role primary --name test-device \
    --repo "$RENDER_REPO" --no-app --no-helper \
    --cli "$POST_VERIFY_SOURCE" \
    --os-root "$SPECIAL_OS_ROOT" \
    --channel-remote "git@sync-host:tatwo/hot-sync.git" >/dev/null 2>&1
then
  fail "post-activation capability failure was reported as successful"
fi
grep -Fq '# post-verify-preserved-old-cli-marker' "$POST_VERIFY_DEST" \
  || fail "post-activation verification failure did not restore the old CLI"
if grep -Fq '# post-verify-new-cli-marker' "$POST_VERIFY_DEST"; then
  fail "post-activation verification failure left the rejected CLI active"
fi
pass "post-activation verification failure atomically restores the previous CLI"

for template in \
  "$ROOT/scripts/templates/com.tatwo.device-sync-helper.plist" \
  "$ROOT/scripts/templates/com.tatwo.device-sync-helper.daemon.plist"
do
  grep -Fq '<key>TATWO_CHANNEL_REMOTE</key>' "$template" \
    || fail "template does not persist TATWO_CHANNEL_REMOTE: $template"
  grep -Fq '<string>__CHANNEL_REMOTE__</string>' "$template" \
    || fail "template lacks channel remote placeholder: $template"
  grep -Fq '<key>TATWO_OS_ROOT</key>' "$template" \
    || fail "template does not persist TATWO_OS_ROOT: $template"
  grep -Fq '<string>__OS_ROOT__</string>' "$template" \
    || fail "template lacks Work OS root placeholder: $template"
  grep -Fq '<key>TATWO_SKILLET_CLI</key>' "$template" \
    || fail "template does not persist TATWO_SKILLET_CLI: $template"
  grep -Fq '<key>TATWO_SKILLS_RUNTIME_ROOT</key>' "$template" \
    || fail "template does not persist TATWO_SKILLS_RUNTIME_ROOT: $template"
  grep -Fq '<string>__SKILLS_RUNTIME_ROOT__</string>' "$template" \
    || fail "template lacks isolated runtime root placeholder: $template"
  grep -Fq '<key>TATWO_SKILLS_CONSUMER_ROOT</key>' "$template" \
    || fail "template does not persist TATWO_SKILLS_CONSUMER_ROOT: $template"
  grep -Fq '<string>__SKILLS_CONSUMER_ROOT__</string>' "$template" \
    || fail "template lacks skills consumer root placeholder: $template"
  grep -Fq '<key>TATWO_CODEX_SKILLS_LINK</key>' "$template" \
    || fail "template does not persist TATWO_CODEX_SKILLS_LINK: $template"
  grep -Fq '<key>TATWO_CLAUDE_SKILLS_LINK</key>' "$template" \
    || fail "template does not persist TATWO_CLAUDE_SKILLS_LINK: $template"
  grep -Fq '<key>TATWO_SKILLS_CONSUMER_PROJECTION_SCRIPT</key>' "$template" \
    || fail "template does not persist the projection helper path: $template"
  grep -Fq '<key>TATWO_DEVICE_TRUST_CLI</key>' "$template" \
    || fail "template does not persist TATWO_DEVICE_TRUST_CLI: $template"
  grep -Fq '<key>TATWO_DEVICE_TRUST_CLI_SHA256</key>' "$template" \
    || fail "template does not persist the signer SHA-256 hint: $template"
  grep -Fq '<key>TATWO_DEVICE_TRUST_CLI_CDHASH</key>' "$template" \
    || fail "template does not persist the signer cdhash hint: $template"
  [ "$(plutil -extract EnvironmentVariables.TATWO_TEST_MODE raw "$template")" = "0" ] \
    || fail "template does not permanently disable helper test mode: $template"
done
pass "LaunchAgent and LaunchDaemon templates persist governed paths and permanently disable test mode"

DAEMON_RENDERER="$ROOT/scripts/tatwo-render-device-sync-daemon.sh"
RENDERED_DAEMON="$RENDER_ROOT/com.tatwo.device-sync-helper.daemon.plist"
if ! bash "$DAEMON_RENDERER" \
    --agent-plist "$RENDERED_PLIST" \
    --output "$RENDERED_DAEMON" \
    --user test-device-user \
    --home "$RENDER_HOME" >/dev/null
then
  fail "LaunchDaemon renderer rejected a governed rendered LaunchAgent"
fi
plutil -lint "$RENDERED_DAEMON" >/dev/null \
  || fail "rendered LaunchDaemon does not pass plutil"
[ "$(plutil -extract UserName raw "$RENDERED_DAEMON")" = "test-device-user" ] \
  || fail "rendered LaunchDaemon changed the governed user"
[ "$(plutil -extract EnvironmentVariables.HOME raw "$RENDERED_DAEMON")" = "$RENDER_HOME" ] \
  || fail "rendered LaunchDaemon changed HOME"
[ "$(plutil -extract EnvironmentVariables.TATWO_SKILLS_RUNTIME_ROOT raw "$RENDERED_DAEMON")" = "$RENDER_HOME/Library/Application Support/Tatwo Ultrawork/skills-runtime" ] \
  || fail "rendered LaunchDaemon lost the isolated runtime root"
[ "$(plutil -extract EnvironmentVariables.TATWO_SKILLS_CONSUMER_ROOT raw "$RENDERED_DAEMON")" = "$RENDER_HOME/Library/Application Support/Tatwo Ultrawork/skills-consumer" ] \
  || fail "rendered LaunchDaemon lost the managed skills consumer root"
[ "$(plutil -extract EnvironmentVariables.TATWO_CODEX_SKILLS_LINK raw "$RENDERED_DAEMON")" = "$RENDER_HOME/.codex/skills" ] \
  || fail "rendered LaunchDaemon lost the Codex native skills entrypoint"
[ "$(plutil -extract EnvironmentVariables.TATWO_CLAUDE_SKILLS_LINK raw "$RENDERED_DAEMON")" = "$RENDER_HOME/.claude/skills" ] \
  || fail "rendered LaunchDaemon lost the Claude native skills entrypoint"
[ "$(plutil -extract EnvironmentVariables.TATWO_TEST_MODE raw "$RENDERED_DAEMON")" = "0" ] \
  || fail "rendered LaunchDaemon did not permanently disable test mode"
if grep -Eq '__[A-Z0-9_]+__' "$RENDERED_DAEMON"; then
  fail "rendered LaunchDaemon retained a placeholder"
fi
if bash "$DAEMON_RENDERER" \
    --agent-plist "$ROOT/scripts/templates/com.tatwo.device-sync-helper.plist" \
    --output "$RENDER_ROOT/unsafe-daemon.plist" >/dev/null 2>&1
then
  fail "LaunchDaemon renderer accepted an unresolved LaunchAgent template"
fi

TEST_MODE_AGENT="$RENDER_ROOT/test-mode-enabled-agent.plist"
TEST_MODE_DAEMON="$RENDER_ROOT/test-mode-enabled-daemon.plist"
cp "$RENDERED_PLIST" "$TEST_MODE_AGENT"
plutil -replace EnvironmentVariables.TATWO_TEST_MODE -string "1" "$TEST_MODE_AGENT"
if bash "$DAEMON_RENDERER" \
    --agent-plist "$TEST_MODE_AGENT" \
    --output "$TEST_MODE_DAEMON" >/dev/null 2>&1
then
  fail "LaunchDaemon renderer accepted a helper with test mode enabled"
fi
[ ! -e "$TEST_MODE_DAEMON" ] \
  || fail "LaunchDaemon renderer emitted output with test mode enabled"
pass "LaunchDaemon rendering requires helper test mode to equal zero"

MISSING_RENDER_PYTHON="$RENDER_ROOT/missing-render-python3"
MISSING_RENDER_OUTPUT="$RENDER_ROOT/missing-python-daemon.plist"
if TATWO_PYTHON3="$MISSING_RENDER_PYTHON" \
  bash "$DAEMON_RENDERER" \
    --agent-plist "$RENDERED_PLIST" \
    --output "$MISSING_RENDER_OUTPUT" >/dev/null 2>&1
then
  fail "LaunchDaemon renderer accepted a missing python3"
fi
[ ! -e "$MISSING_RENDER_OUTPUT" ] \
  || fail "LaunchDaemon renderer emitted output with a missing python3"
pass "LaunchDaemon renderer fails closed without python3"

BROKEN_RENDER_PYTHON="$RENDER_ROOT/broken-render-python3"
BROKEN_RENDER_OUTPUT="$RENDER_ROOT/broken-python-daemon.plist"
cat >"$BROKEN_RENDER_PYTHON" <<'EOF'
#!/usr/bin/env bash
exit 72
EOF
chmod +x "$BROKEN_RENDER_PYTHON"
if TATWO_PYTHON3="$BROKEN_RENDER_PYTHON" \
  bash "$DAEMON_RENDERER" \
    --agent-plist "$RENDERED_PLIST" \
    --output "$BROKEN_RENDER_OUTPUT" >/dev/null 2>&1
then
  fail "LaunchDaemon renderer accepted a python3 without plistlib"
fi
[ ! -e "$BROKEN_RENDER_OUTPUT" ] \
  || fail "LaunchDaemon renderer emitted output with a nonfunctional python3"
pass "LaunchDaemon renderer probes plistlib before emitting output"

for missing_log_key in StandardOutPath StandardErrorPath; do
  missing_log_agent="$RENDER_ROOT/missing-$missing_log_key-agent.plist"
  missing_log_daemon="$RENDER_ROOT/missing-$missing_log_key-daemon.plist"
  cp "$RENDERED_PLIST" "$missing_log_agent"
  plutil -remove "$missing_log_key" "$missing_log_agent"
  if bash "$DAEMON_RENDERER" \
      --agent-plist "$missing_log_agent" \
      --output "$missing_log_daemon" >/dev/null 2>&1
  then
    fail "LaunchDaemon renderer accepted a helper without $missing_log_key"
  fi
  [ ! -e "$missing_log_daemon" ] \
    || fail "LaunchDaemon renderer emitted output without $missing_log_key"
done
pass "LaunchDaemon rendering fails closed when either log path is missing"

pass "LaunchDaemon has a fail-closed renderer and cannot be emitted with placeholders"

printf '%s\n' "tatwo_device_enroll_channel_test=passed"
