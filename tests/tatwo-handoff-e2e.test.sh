#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/tatwo-handoff-e2e.sh"
STUBS="$(mktemp -d "${TMPDIR:-/tmp}/tatwo-handoff-plan-stubs.XXXXXX")"
SENTINEL="$STUBS/network-command-invoked"

cleanup() {
  if command -v trash >/dev/null 2>&1; then
    trash "$STUBS" >/dev/null 2>&1 || true
  else
    printf 'test stubs preserved (trash unavailable): %s\n' "$STUBS"
  fi
}
trap cleanup EXIT

for command_name in ssh scp; do
  cat >"$STUBS/$command_name" <<EOF
#!/bin/bash
touch "$SENTINEL"
exit 97
EOF
  chmod +x "$STUBS/$command_name"
done

test -x "$SCRIPT"
plan="$(PATH="$STUBS:$PATH" "$SCRIPT" --print-remote-plan)"
test ! -e "$SENTINEL"
grep -q 'MANUAL ONLY' <<<"$plan"
grep -q 'cross-device-handoff pack-create' <<<"$plan"
grep -q 'cross-device-handoff pack-verify' <<<"$plan"
grep -q 'cross-device-handoff assess' <<<"$plan"
grep -q 'cross-device-handoff assessment-verify' <<<"$plan"
grep -q 'No lease-transfer command exists' <<<"$plan"
# Existing Work OS handoff pack path must stay exact-match on "pack" only.
grep -q 'guard args.dropFirst().first == "pack" else' \
  "$ROOT/Tools/TatwoUltraworkCLI/Sources/TatwoUltraworkCLI/main.swift"
grep -q 'case "cross-device-handoff":' \
  "$ROOT/Tools/TatwoUltraworkCLI/Sources/TatwoUltraworkCLI/main.swift"
test "$(grep -c 'case "pack-create":' \
  "$ROOT/Tools/TatwoUltraworkCLI/Sources/TatwoUltraworkCLI/HandoffCLI.swift")" -eq 1
test "$(grep -c 'case "assessment-verify":' \
  "$ROOT/Tools/TatwoUltraworkCLI/Sources/TatwoUltraworkCLI/HandoffCLI.swift")" -eq 1
test "$(grep -c 'case "lease-transfer":' \
  "$ROOT/Tools/TatwoUltraworkCLI/Sources/TatwoUltraworkCLI/HandoffCLI.swift" || true)" -eq 0
! grep -Eqi 'human[ -]lease|approval lease|human lease gate' \
  "$ROOT/Tools/TatwoUltraworkCLI/Sources/TatwoUltraworkCLI/HandoffCLI.swift"
# Must not nest cross-device verbs under Work OS handoff.
test "$(grep -c 'try TatwoHandoffCLI.run' \
  "$ROOT/Tools/TatwoUltraworkCLI/Sources/TatwoUltraworkCLI/main.swift")" -eq 1
! grep -q 'handoff pack-create' \
  "$ROOT/Tools/TatwoUltraworkCLI/Sources/TatwoUltraworkCLI/main.swift"

if [[ "${TATWO_HANDOFF_RUN_SELFTEST:-0}" == "1" ]]; then
  PATH="$STUBS:$PATH" "$SCRIPT" --selftest
  test ! -e "$SENTINEL"
fi

printf 'tatwo-handoff-e2e contract test: PASS\n'
