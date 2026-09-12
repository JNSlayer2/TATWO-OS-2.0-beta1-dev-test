#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX_ROOT="$REPO_ROOT/.sandbox-remote-loops-r2"
CHANNEL_ROOT="$SANDBOX_ROOT/channel"
ORIGIN_STATE="$SANDBOX_ROOT/origin-state"
RUNNER_STATE="$SANDBOX_ROOT/runner-state"
TRUST_ROOT="$SANDBOX_ROOT/device-trust"
WORK_ROOT="$SANDBOX_ROOT/work"
MANIFEST="$SANDBOX_ROOT/manifest.json"
RUNNER_SCRIPT="$REPO_ROOT/scripts/tatwo-loop-runner.sh"

# R3-B: never take an interactive/AppleEvent path by default.
# Archive under /private/tmp (reversible; no direct delete). Use macOS `trash`
# only when TATWO_E2E_USE_TRASH=1 and stdin/stdout are TTYs.
archive_sandbox_root() {
  local archive_root="/private/tmp/tatwo-remote-loops-sandbox-archive-$(date +%Y%m%d%H%M%S)-$$"
  mv "$SANDBOX_ROOT" "$archive_root"
  echo "sandbox_archived=$archive_root" >&2
}

if [[ -e "$SANDBOX_ROOT" ]]; then
  if [[ "${TATWO_E2E_USE_TRASH:-0}" == "1" ]] \
    && [[ -t 0 && -t 1 ]] \
    && command -v trash >/dev/null 2>&1; then
    if ! trash "$SANDBOX_ROOT" >/dev/null 2>&1; then
      archive_sandbox_root
    fi
  else
    archive_sandbox_root
  fi
fi

mkdir -p "$CHANNEL_ROOT" "$ORIGIN_STATE" "$RUNNER_STATE" "$WORK_ROOT" "$TRUST_ROOT"
# Small fixture so ProcessEngineBinding `ls` has content.
printf 'probe\n' >"$WORK_ROOT/probe.txt"

export TATWO_ULTRAWORK_JOB_CHANNEL_DIR="$CHANNEL_ROOT"
export TATWO_ULTRAWORK_STATE_DIR="$ORIGIN_STATE"
export TATWO_ULTRAWORK_TRUST_ROOT="$TRUST_ROOT"
export TATWO_ULTRAWORK_LOOP_SANDBOX_ROOT="$SANDBOX_ROOT"
# R3-C sandbox unlock for tatwo-loop (production remains disabled without this).
export TATWO_ULTRAWORK_TATWO_LOOP_ENABLE=sandbox
# Keep e2e deterministic under host memory pressure.
export TATWO_ULTRAWORK_MEMORY_GATE_MIN_FREE=0
# Authorizes TatwoDeviceTestFilePrivateKeyStore for this disposable sandbox only.
export TATWO_TEST_MODE=1

"$RUNNER_SCRIPT" origin-enqueue \
  --manifest "$MANIFEST" \
  --work-path "$WORK_ROOT"

export TATWO_ULTRAWORK_STATE_DIR="$RUNNER_STATE"
export TATWO_ULTRAWORK_RUNNER_STATE_DIR="$RUNNER_STATE"
"$RUNNER_SCRIPT" run --device-id runner-sandbox

export TATWO_ULTRAWORK_STATE_DIR="$ORIGIN_STATE"
"$RUNNER_SCRIPT" converge --manifest "$MANIFEST"
"$RUNNER_SCRIPT" verify --manifest "$MANIFEST"

# R3-A negative cases: tampered job bytes and unknown identity both fail closed.
"$RUNNER_SCRIPT" negative-trust --work-path "$WORK_ROOT"

# R3-C negative: without enable env, tatwo-loop stays disabled.
unset TATWO_ULTRAWORK_TATWO_LOOP_ENABLE
"$RUNNER_SCRIPT" negative-loop --work-path "$WORK_ROOT"

# R3 security negatives (H1/H3/M5): journal tamper, origin-signed result, symlink escape.
# M6 note: cross-device pin distribution is unfinished — e2e green ≠ multi-host trust.
"$RUNNER_SCRIPT" negative-security --work-path "$WORK_ROOT"

test -f "$ORIGIN_STATE/dispatches/contract-xl-coding-f51cfabe38f8.json"
# Runner writes local GoalRun/dispatch only for executed tatwo-loop jobs.
test -f "$RUNNER_STATE/dispatches/contract-xl-coding-f51cfabe38f8.json"

echo "sandbox_root=.sandbox-remote-loops-r2"
