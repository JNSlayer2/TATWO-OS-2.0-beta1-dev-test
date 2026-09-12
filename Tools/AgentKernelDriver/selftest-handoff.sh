#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${AGENT_KERNEL_DRIVER_BIN:-$ROOT/.build/debug/agent-kernel-driver}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/agent-kernel-handoff.XXXXXX")"
trap 'kill "${PID:-}" 2>/dev/null || true; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/task" "$TMP/store" "$TMP/bin"
cat > "$TMP/task/task.md" <<'EOF'
# Handoff exam
STEP 1 :: append effects.log codex-one
STEP 2 :: append effects.log claude-two
STEP 3 :: append effects.log claude-three
EOF
if [ "${AGENT_KERNEL_SELFTEST_FIXTURE_TRANSPORTS:-0}" = 1 ]; then
  CODEX_BIN="$TMP/bin/codex"
  CLAUDE_BIN="$TMP/bin/claude"
  for name in codex claude; do
  cat > "$TMP/bin/$name" <<EOF
#!/bin/sh
printf '%s\\n' '{"actual":"$name","effort":"exam","message":"fixture $name turn"}'
EOF
  chmod +x "$TMP/bin/$name"
  done
else
  CODEX_BIN="${AGENT_KERNEL_CODEX_BIN:-$(command -v codex || true)}"
  CLAUDE_BIN="${AGENT_KERNEL_CLAUDE_BIN:-$(command -v claude || true)}"
  [ -x "$CODEX_BIN" ] || { echo "BLOCKED: codex transport unavailable" >&2; exit 2; }
  [ -x "$CLAUDE_BIN" ] || { echo "BLOCKED: claude -p transport unavailable" >&2; exit 2; }
fi
[ -x "$BIN" ] || { echo "BLOCKED: missing driver binary: $BIN" >&2; exit 2; }
AGENT_KERNEL_CODEX_BIN="$CODEX_BIN" AGENT_KERNEL_PAUSE_AFTER_STEP=1 \
  "$BIN" run --task "$TMP/task" --store "$TMP/store" --transport codex >"$TMP/first.log" 2>&1 &
PID=$!
for _ in $(seq 1 600); do
  grep -q '^CHECKPOINT_STEP=1$' "$TMP/first.log" 2>/dev/null && break
  kill -0 "$PID" 2>/dev/null || { cat "$TMP/first.log" >&2; exit 1; }
  sleep 0.5
done
grep -q '^CHECKPOINT_STEP=1$' "$TMP/first.log"
RUN_ID="$(sed -n 's/^RUN_ID=//p' "$TMP/first.log" | head -1)"
kill -KILL "$PID"
# 進程必須確實死於 SIGKILL：wait 狀態必為 128+9=137，否則判 FAIL。
wait "$PID" && FIRST_STATUS=0 || FIRST_STATUS=$?
[ "$FIRST_STATUS" -eq 137 ] || { echo "FAIL: first run exit=$FIRST_STATUS, expected 137 (SIGKILL)" >&2; exit 1; }
unset PID
AGENT_KERNEL_CLAUDE_BIN="$CLAUDE_BIN" \
  "$BIN" resume --run "$RUN_ID" --store "$TMP/store" --transport claude >"$TMP/resume.log" 2>&1
grep -q '^NEXT_STEP=2$' "$TMP/resume.log"
[ "$(cat "$TMP/task/effects.log")" = $'codex-one\nclaude-two\nclaude-three' ]
python3 - "$TMP/store/$RUN_ID/events.jsonl" <<'PY'
import json,sys
events=[json.loads(x) for x in open(sys.argv[1])]
payloads=[e['payload'] for e in events]
changes=[p['transportChanged'] for p in payloads if 'transportChanged' in p]
assert len(changes)==1, changes
change=changes[0]
assert change['from']=='codex' and change['to']=='claude', change
att=[p['turnAttested']['_0'] for p in payloads if 'turnAttested' in p]
assert [x['actual'] for x in att] == ['codex','claude','claude'], att
PY
if [ "${AGENT_KERNEL_SELFTEST_FIXTURE_TRANSPORTS:-0}" = 1 ]; then
  echo "PASS-FIXTURE handoff run=$RUN_ID (fixture transports; NOT valid as sign-off evidence)"
else
  echo "PASS handoff run=$RUN_ID codex_to_claude=true turn_attestations=3 kill=SIGKILL"
fi
