#!/bin/bash
set -euo pipefail

DRIVER="${AGENT_KERNEL_DRIVER_BIN:-.build/debug/agent-kernel-driver}"
SOURCE_TRANSPORT="${AGENT_KERNEL_SOURCE_TRANSPORT:-codex}"
TARGET_TRANSPORT="${AGENT_KERNEL_TARGET_TRANSPORT:-grok}"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-kernel-checkpoint-handoff.XXXXXX")"
TASK="$ROOT/task"
STORE="$ROOT/store"
RUN_ID="checkpoint-handoff-$RANDOM-$$"
LOG1="$ROOT/source.log"
LOG2="$ROOT/target.log"
mkdir -p "$TASK" "$STORE"
cleanup() {
  if [[ -n "${SOURCE_PID:-}" ]] && kill -0 "$SOURCE_PID" 2>/dev/null; then
    kill "$SOURCE_PID" 2>/dev/null || true
  fi
  rm -r "$ROOT"
}
trap cleanup EXIT

if [[ ! -x "$DRIVER" ]]; then
  echo "BLOCKED driver_unavailable=$DRIVER"
  exit 2
fi
if [[ "$TARGET_TRANSPORT" == "grok" && ! -x "${AGENT_KERNEL_GROK_BIN:-$HOME/.codex/bin/grok-isolated}" ]]; then
  echo "BLOCKED grok_transport_unavailable=${AGENT_KERNEL_GROK_BIN:-$HOME/.codex/bin/grok-isolated}"
  exit 2
fi

cat >"$TASK/task.md" <<'EOF'
STEP 1 :: write evidence/source.txt In your JSON message compute 314159 + 271828 and return only the decimal answer
STEP 2 :: write evidence/target.txt Recover the decimal answer from PortableCheckpointV1 and return only that answer in JSON message
EOF

AGENT_KERNEL_PAUSE_AFTER_STEP=1 "$DRIVER" run \
  --task "$TASK" --store "$STORE" --run "$RUN_ID" \
  --transport "$SOURCE_TRANSPORT" >"$LOG1" 2>&1 &
SOURCE_PID=$!

for _ in $(seq 1 240); do
  grep -q 'CHECKPOINT_STEP=1' "$LOG1" && break
  kill -0 "$SOURCE_PID" 2>/dev/null || {
    cat "$LOG1"
    echo "BLOCKED source_transport_failed=$SOURCE_TRANSPORT"
    exit 2
  }
  sleep 0.25
done
grep -q 'CHECKPOINT_STEP=1' "$LOG1" || {
  echo "BLOCKED source_checkpoint_timeout=$SOURCE_TRANSPORT"
  exit 2
}

kill -KILL "$SOURCE_PID"
set +e
wait "$SOURCE_PID"
KILL_STATUS=$?
set -e
[[ "$KILL_STATUS" -eq 137 ]] || {
  echo "FAIL expected_kill=137 actual=$KILL_STATUS"
  exit 1
}

# Anti-cheat: remove the arithmetic operands from the task before the other
# provider starts. The answer-bearing source reply now exists only in the
# validated portable checkpoint.
cat >"$TASK/task.md" <<'EOF'
STEP 1 :: write evidence/source.txt completed-before-handoff
STEP 2 :: write evidence/target.txt Recover the decimal answer from PortableCheckpointV1 and return only that answer in JSON message
EOF
! grep -R -E '314159|271828|585987' "$TASK" >/dev/null

"$DRIVER" resume --run "$RUN_ID" --store "$STORE" \
  --transport "$TARGET_TRANSPORT" --checkpoint-only >"$LOG2" 2>&1 || {
  cat "$LOG2"
  echo "BLOCKED target_transport_failed=$TARGET_TRANSPORT checkpoint_only=true"
  exit 2
}

grep -q 'CHECKPOINT_ONLY=true' "$LOG2"
grep -q 'CONTINUATION=null' "$LOG2"
grep -q 'COMPLETED_RUN_ID=' "$LOG2"
grep -q '585987' "$STORE/$RUN_ID/portable-checkpoint-v1.json"
! grep -Eiq 'session.?id|thread.?id|conversation.?id' \
  "$STORE/$RUN_ID/portable-checkpoint-v1.json"
echo "PASS kill=SIGKILL checkpoint_only=true source=$SOURCE_TRANSPORT target=$TARGET_TRANSPORT continuation=null"
