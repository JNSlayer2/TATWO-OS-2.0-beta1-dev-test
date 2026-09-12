#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${AGENT_KERNEL_DRIVER_BIN:-$ROOT/.build/debug/agent-kernel-driver}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/agent-kernel-resume.XXXXXX")"
trap 'kill "${PID:-}" 2>/dev/null || true; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/task" "$TMP/store" "$TMP/bin"
cat > "$TMP/task/task.md" <<'EOF'
# Resume exam
STEP 1 :: append effects.log one
STEP 2 :: append effects.log two
STEP 3 :: append effects.log three
STEP 4 :: append effects.log four
EOF
if [ "${AGENT_KERNEL_SELFTEST_FIXTURE_TRANSPORTS:-0}" = 1 ]; then
  CODEX_BIN="$TMP/bin/codex"
  cat > "$CODEX_BIN" <<'EOF'
#!/bin/sh
printf '%s\n' '{"actual":"codex","effort":"exam","message":"fixture codex turn"}'
EOF
  chmod +x "$CODEX_BIN"
else
  CODEX_BIN="${AGENT_KERNEL_CODEX_BIN:-$(command -v codex || true)}"
  [ -x "$CODEX_BIN" ] || { echo "BLOCKED: codex transport unavailable" >&2; exit 2; }
fi
[ -x "$BIN" ] || { echo "BLOCKED: missing driver binary: $BIN" >&2; exit 2; }
AGENT_KERNEL_CODEX_BIN="$CODEX_BIN" AGENT_KERNEL_PAUSE_AFTER_STEP=2 \
  "$BIN" run --task "$TMP/task" --store "$TMP/store" --transport codex >"$TMP/first.log" 2>&1 &
PID=$!
# 主導驗收機械修正：等待窗原為 10s（假樁量級）；真模型每 step 需真推理，
# 放大到 5 分鐘（600×0.5s）。
for _ in $(seq 1 600); do
  grep -q '^CHECKPOINT_STEP=2$' "$TMP/first.log" 2>/dev/null && break
  kill -0 "$PID" 2>/dev/null || { cat "$TMP/first.log" >&2; exit 1; }
  sleep 0.5
done
grep -q '^CHECKPOINT_STEP=2$' "$TMP/first.log"
RUN_ID="$(sed -n 's/^RUN_ID=//p' "$TMP/first.log" | head -1)"
[ -n "$RUN_ID" ]
kill -KILL "$PID"
# 進程必須確實死於 SIGKILL：wait 狀態必為 128+9=137，否則判 FAIL。
wait "$PID" && FIRST_STATUS=0 || FIRST_STATUS=$?
[ "$FIRST_STATUS" -eq 137 ] || { echo "FAIL: first run exit=$FIRST_STATUS, expected 137 (SIGKILL)" >&2; exit 1; }
unset PID
AGENT_KERNEL_CODEX_BIN="$CODEX_BIN" \
  "$BIN" resume --run "$RUN_ID" --store "$TMP/store" --transport codex >"$TMP/resume.log" 2>&1
grep -q '^NEXT_STEP=3$' "$TMP/resume.log"
grep -q "^COMPLETED_RUN_ID=$RUN_ID$" "$TMP/resume.log"
[ "$(cat "$TMP/task/effects.log")" = $'one\ntwo\nthree\nfour' ]
python3 - "$TMP/store/$RUN_ID/events.jsonl" "$RUN_ID" <<'PY'
import json,sys
path,run_id=sys.argv[1:]
events=[json.loads(x) for x in open(path)]
assert {e['runID'] for e in events} == {run_id}
checkpoints=[]
for e in events:
 p=e['payload']
 if 'checkpointCommitted' in p: checkpoints.append(p['checkpointCommitted']['_0']['completedStep'])
assert checkpoints == [1,2,3,4], checkpoints
started=[e['payload']['invocationStarted']['id'] for e in events if 'invocationStarted' in e['payload']]
assert started == ['step-1','step-2','step-3','step-4'], started
PY
echo "PASS resume run=$RUN_ID killed_after=2 resumed_first=3 no_replay=true"
