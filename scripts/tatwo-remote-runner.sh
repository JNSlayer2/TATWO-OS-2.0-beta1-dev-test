#!/usr/bin/env bash
# Production remote-runner wrapper. Does NOT invoke the sandbox test driver.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat >&2 <<'EOF'
Use:
  tatwo-remote-runner.sh start --device-id <runner> --origin-device-id <origin> [--bootstrap-only] [--channel-dir <sealed>] [--json]
  tatwo-remote-runner.sh seal-install --device-id <self> --channel-dir <path> [--json]
  tatwo-remote-runner.sh readiness publish --device-id <target> \
      --workspace-binding-id <id> --workspace-path <target-local-dir> \
      --agent <grok|codex|claude> --model-route <canonical-route> \
      [--skillet-store <path>] [--manifest-out <path>] [--json]
  tatwo-remote-runner.sh dispatch --device-id <origin> --target-device-id <target> \
      --logical-job-id <id> --work-path <dir> --engine-command echo --engine-arg hello \
      [--channel-dir <sealed>] [--json]

This path boots via `tatwo-ultrawork remote-runner` (Keychain + durable pin store).
It never calls scripts/tatwo-loop-runner-driver.swift.
Production refuses --pin-store-root, TATWO_TEST_MODE=1, and trust-namespace env overrides.

Dual-machine order:
  1. Both: device-trust init + mutual pin-import
  2. Both: remote-runner seal-install --device-id <self> --channel-dir <path>
  3. Target: remote-runner start --device-id <target> --origin-device-id <origin>
  4. Origin: remote-runner dispatch ... then scripts/tatwo-remote-channel-sync.sh push
  5. Target executes; scripts/tatwo-remote-channel-sync.sh pull; origin converge
Crash-after-claim recovery: new jobID + new dispatchNonce; keep logicalJobID.
EOF
  exit 2
}

[[ $# -ge 1 ]] || usage

LOCK=/tmp/tatwo-build.lock
while ! mkdir "$LOCK" 2>/dev/null; do sleep 1; done
cleanup() { rmdir "$LOCK" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

CACHE=/private/tmp/tatwo-swift-cache-ws1
mkdir -p "$CACHE/clang" "$CACHE/swift"
export SWIFT_MODULECACHE_PATH="$CACHE/swift"
export CLANG_MODULE_CACHE_PATH="$CACHE/clang"

case "$1" in
  start|seal-install|readiness|dispatch)
    sub="$1"
    shift
    exec swift run --disable-sandbox --jobs 2 --package-path "$REPO_ROOT" \
      tatwo-ultrawork remote-runner "$sub" "$@"
    ;;
  *)
    usage
    ;;
esac
