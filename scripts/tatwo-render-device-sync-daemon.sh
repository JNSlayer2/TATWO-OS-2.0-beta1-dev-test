#!/usr/bin/env bash
# Render a validated system LaunchDaemon plist from an already-rendered,
# enrollment-owned LaunchAgent plist. This script never installs or loads it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$HERE/templates/com.tatwo.device-sync-helper.daemon.plist"
AGENT_PLIST="$HOME/Library/LaunchAgents/com.tatwo.device-sync-helper.plist"
OUTPUT=""
UNIX_USER="$(id -un)"
HOME_DIR="$HOME"
PYTHON3="${TATWO_PYTHON3:-python3}"

while [ $# -gt 0 ]; do
  case "$1" in
    --agent-plist) AGENT_PLIST="$2"; shift 2;;
    --output) OUTPUT="$2"; shift 2;;
    --user) UNIX_USER="$2"; shift 2;;
    --home) HOME_DIR="$2"; shift 2;;
    -h|--help)
      cat <<'EOF'
Usage:
  tatwo-render-device-sync-daemon.sh --output ABSOLUTE_PATH
    [--agent-plist ABSOLUTE_PATH] [--user UNIX_USER] [--home ABSOLUTE_PATH]

Renders and validates a LaunchDaemon plist only. It does not sudo, install,
bootstrap, load, unload, or replace any active helper.
EOF
      exit 0
      ;;
    *)
      echo "未知參數：$1" >&2
      exit 64
      ;;
  esac
done

case "$AGENT_PLIST" in /*) ;; *)
  echo "--agent-plist 必須是絕對路徑" >&2
  exit 64
  ;;
esac
case "$OUTPUT" in /*) ;; *)
  echo "--output 必須是絕對路徑" >&2
  exit 64
  ;;
esac
case "$HOME_DIR" in /*) ;; *)
  echo "--home 必須是絕對路徑" >&2
  exit 64
  ;;
esac
case "$UNIX_USER" in
  ""|*[!A-Za-z0-9._-]*)
    echo "--user 含不支援字元" >&2
    exit 64
    ;;
esac

[ -f "$TEMPLATE" ] || {
  echo "LaunchDaemon template 不存在" >&2
  exit 1
}
[ -r "$AGENT_PLIST" ] || {
  echo "已渲染 LaunchAgent plist 不可讀" >&2
  exit 1
}
command -v "$PYTHON3" >/dev/null 2>&1 || {
  echo "LaunchDaemon rendering 需要可用的 python3" >&2
  exit 1
}
"$PYTHON3" -c 'import plistlib' >/dev/null 2>&1 || {
  echo "LaunchDaemon rendering 的 python3 無法載入 plistlib" >&2
  exit 1
}
plutil -lint "$AGENT_PLIST" >/dev/null || {
  echo "已渲染 LaunchAgent plist 不合法" >&2
  exit 1
}

mkdir -p "$(dirname "$OUTPUT")"
STAGE="$(mktemp "$OUTPUT.staging.XXXXXX")"
trap 'rm -f "$STAGE"' EXIT HUP INT TERM

"$PYTHON3" - "$TEMPLATE" "$AGENT_PLIST" "$STAGE" "$UNIX_USER" "$HOME_DIR" <<'PY'
import copy
import os
import plistlib
import re
import sys

template_path, agent_path, output_path, unix_user, home_dir = sys.argv[1:]
with open(template_path, "rb") as handle:
    daemon = plistlib.load(handle)
with open(agent_path, "rb") as handle:
    agent = plistlib.load(handle)

placeholder = re.compile(r"__[A-Z0-9_]+__")

def contains_placeholder(value):
    if isinstance(value, str):
        return placeholder.search(value) is not None
    if isinstance(value, dict):
        return any(contains_placeholder(key) or contains_placeholder(item)
                   for key, item in value.items())
    if isinstance(value, (list, tuple)):
        return any(contains_placeholder(item) for item in value)
    return False

required_environment = {
    "TATWO_TEST_MODE",
    "TATWO_DEVICE_NAME",
    "TATWO_PRIMARY_SSH_HOST",
    "TATWO_SYNC_REPO",
    "TATWO_SYNC_INTERVAL",
    "TATWO_CHANNEL_REMOTE",
    "TATWO_OS_ROOT",
    "TATWO_SKILLET_SOURCE_ROOT",
    "TATWO_SKILLS_RUNTIME_ROOT",
    "TATWO_SKILLS_CONSUMER_ROOT",
    "TATWO_CODEX_SKILLS_LINK",
    "TATWO_CLAUDE_SKILLS_LINK",
    "TATWO_SKILLS_CONSUMER_PROJECTION_SCRIPT",
    "TATWO_SKILLET_SOURCE_REGISTRY",
    "TATWO_SKILLET_CLI",
    "TATWO_DEVICE_TRUST_CLI",
    "TATWO_DEVICE_TRUST_CLI_SHA256",
    "TATWO_DEVICE_TRUST_CLI_CDHASH",
    "TATWO_REMOTE_APP_SUPPORT",
    "PATH",
}
program = agent.get("ProgramArguments")
environment = agent.get("EnvironmentVariables")
standard_out = agent.get("StandardOutPath")
standard_error = agent.get("StandardErrorPath")
if (
    not isinstance(program, list)
    or len(program) != 2
    or not all(isinstance(item, str) and item for item in program)
    or not isinstance(environment, dict)
    or not required_environment.issubset(environment)
    or environment.get("TATWO_TEST_MODE") != "0"
    or not isinstance(standard_out, str)
    or not standard_out
    or not isinstance(standard_error, str)
    or not standard_error
    or contains_placeholder(agent)
):
    raise SystemExit("LaunchAgent is not a fully rendered governed helper plist")

daemon["ProgramArguments"] = copy.deepcopy(program)
daemon["EnvironmentVariables"] = copy.deepcopy(environment)
daemon["EnvironmentVariables"]["HOME"] = home_dir
daemon["UserName"] = unix_user
daemon["RunAtLoad"] = bool(agent.get("RunAtLoad", True))
daemon["KeepAlive"] = copy.deepcopy(agent.get("KeepAlive", True))
daemon["StandardOutPath"] = standard_out
daemon["StandardErrorPath"] = standard_error
if contains_placeholder(daemon):
    raise SystemExit("LaunchDaemon rendering left an unresolved placeholder")

with open(output_path, "wb") as handle:
    plistlib.dump(daemon, handle, fmt=plistlib.FMT_XML, sort_keys=False)
os.chmod(output_path, 0o600)
PY

if grep -Eq '__[A-Z0-9_]+__' "$STAGE"; then
  echo "LaunchDaemon rendering 留下 placeholder" >&2
  exit 1
fi
plutil -lint "$STAGE" >/dev/null || {
  echo "LaunchDaemon rendering 未通過 plutil" >&2
  exit 1
}
mv "$STAGE" "$OUTPUT"
trap - EXIT HUP INT TERM
printf 'rendered_daemon=%s\n' "$OUTPUT"
printf '%s\n' "注意：僅完成渲染，尚未安裝或載入 LaunchDaemon。"
