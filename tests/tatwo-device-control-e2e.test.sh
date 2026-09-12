#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/tatwo-device-control-e2e.sh"
MAIN="$ROOT/Tools/TatwoUltraworkCLI/Sources/TatwoUltraworkCLI/main.swift"
CLI_SOURCE="$ROOT/Tools/TatwoUltraworkCLI/Sources/TatwoUltraworkCLI/DeviceControlCLI.swift"

bash -n "$SCRIPT"

stub_root="$(mktemp -d "${TMPDIR:-/tmp}/tatwo-device-control-plan-stubs.XXXXXX")"
sentinel="$stub_root/network-command-was-executed"
cleanup() {
  if command -v trash >/dev/null 2>&1; then
    trash "$stub_root" >/dev/null 2>&1 || true
  else
    printf 'test stub directory preserved (trash unavailable): %s\n' "$stub_root"
  fi
}
trap cleanup EXIT
for command_name in ssh scp curl nc; do
  cat >"$stub_root/$command_name" <<EOF
#!/bin/sh
printf '%s\n' '$command_name' >>'$sentinel'
exit 91
EOF
  chmod +x "$stub_root/$command_name"
done

plan="$(PATH="$stub_root:$PATH" "$SCRIPT" --print-remote-plan)"
[[ ! -e "$sentinel" ]]
grep -q 'MANUAL ONLY' <<<"$plan"
grep -q 'device-control descriptor-create' <<<"$plan"
grep -q 'device-control validate' <<<"$plan"
grep -q 'device-control dispatch-plan' <<<"$plan"
grep -q 'device-control result-verify' <<<"$plan"
grep -q 'does not call ssh/scp' <<<"$plan"
grep -q 'STOP AT X1 BOUNDARY' <<<"$plan"

[[ "$(grep -c '^    case "device-control":' "$MAIN")" -eq 1 ]]
[[ "$(grep -c '^    case "validate":' "$CLI_SOURCE")" -eq 1 ]]
[[ "$(grep -c '^    case "descriptor-create":' "$CLI_SOURCE")" -eq 1 ]]
[[ "$(grep -c '^    case "dispatch-plan":' "$CLI_SOURCE")" -eq 1 ]]
[[ "$(grep -c '^    case "result-verify":' "$CLI_SOURCE")" -eq 1 ]]

! grep -Eq '^    case "(execute|run|send|enqueue)":' "$CLI_SOURCE"
! grep -Fq 'Process(' "$CLI_SOURCE"
! grep -Fq 'Process.run' "$CLI_SOURCE"
! grep -Fq 'URLSession' "$CLI_SOURCE"
! grep -Fq 'NWConnection' "$CLI_SOURCE"

printf 'tatwo-device-control-e2e contract PASS\n'
