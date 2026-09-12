#!/bin/zsh
# 模擬真人 AX 驗收：scripts/tatwo2-acceptance.sh <tatwo2.app 路徑>
set -u -o pipefail
cd "$(dirname "$0")/.."

if (( $# != 1 )); then
  print -u2 'usage: scripts/tatwo2-acceptance.sh <tatwo2.app path>'
  exit 64
fi
APP="$1"
BIN="$APP/Contents/MacOS/tatwo2"
REPORT_DIR="docs/goal-ui-2.0/reports/acceptance"
RESULT="$REPORT_DIR/RESULT.md"
mkdir -p "$REPORT_DIR"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tatwo2-acceptance-live.XXXXXX")"
TMP_HOME="$(mktemp -d "${TMPDIR:-/tmp}/tatwo2-acceptance-home.XXXXXX")"
PID=""

cleanup() {
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    python3 scripts/tatwo2-ax.py >/dev/null 2>&1 || true
    osascript -l AppleScript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to keystroke \"q\" using command down" >/dev/null 2>&1 || true
    sleep 2
    kill -TERM "$PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT" "$TMP_HOME"
}
trap cleanup EXIT INT TERM

write_result() {
  local preflight="$1"
  cat > "$RESULT" <<EOF
# Tatwo2 每日十件事 AX 驗收

日期｜$(date '+%Y-%m-%d %H:%M:%S %Z')｜版本｜${APP:t}｜run_id｜${RUN_ID}

前置｜${preflight}

| # | 事情 | 結果 | 秒數 | 證據 / 原因 |
|---|---|---|---:|---|
EOF
}

if [[ ! -x "$BIN" ]]; then
  write_result "BLOCKED：找不到可執行檔 $BIN"
  exit 1
fi

# Required room preflight: do not claim AX automation works unless System Events is reachable.
if ! osascript -e 'tell application "System Events" to get name of every process' >/dev/null 2>&1; then
  write_result "BLOCKED：System Events 無法列出 process；請在 macOS 隱私權與安全性 > 輔助使用權限授權終端機 / Codex。"
  exit 2
fi

# The packaged App is deliberately rebuilt by the runner before every live run.
# Its package script owns release packaging; the mandated Tatwo2 scratch build is run separately below.
if ! swift build --product Tatwo2 --scratch-path .build-sol >"$REPORT_DIR/${RUN_ID}-scratch-build.log" 2>&1; then
  write_result "BLOCKED：swift build --product Tatwo2 --scratch-path .build-sol 失敗；見 ${RUN_ID}-scratch-build.log。"
  exit 3
fi
if ! scripts/build-app.sh /tmp/tatwo2-acc >"$REPORT_DIR/${RUN_ID}-package-build.log" 2>&1; then
  write_result "BLOCKED：scripts/build-app.sh /tmp/tatwo2-acc 失敗；見 ${RUN_ID}-package-build.log。"
  exit 3
fi
APP="/tmp/tatwo2-acc/tatwo2.app"
BIN="$APP/Contents/MacOS/tatwo2"

write_result 'OK：System Events 可用；每一步以前後 PNG、AX 樹片段和實際操作結果判定。'
env HOME="$TMP_HOME" TATWO2_LIVE_ROOT="$TMP_ROOT" "$BIN" >"$REPORT_DIR/${RUN_ID}-app.log" 2>&1 &
PID=$!
sleep 6
if ! kill -0 "$PID" 2>/dev/null; then
  print -r -- "| 1..10 | 啟動 App | 失敗 | 6 | App 在 AX 驗收前結束；見 ${RUN_ID}-app.log。 |" >> "$RESULT"
  exit 4
fi

run_step() {
  local number="$1" title="$2" action="$3" started ended result reason before after ax
  before="$REPORT_DIR/${number}-前.png"; after="$REPORT_DIR/${number}-後.png"; ax="$REPORT_DIR/${number}-ax.txt"
  started="$(date +%s)"
  python3 - "$PID" "$before" <<'PY'
import sys
from pathlib import Path
import importlib.util
s=importlib.util.spec_from_file_location('ax','scripts/tatwo2-ax.py'); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
m.capture(int(sys.argv[1]), Path(sys.argv[2]))
PY
  result="失敗"; reason="未執行"
  eval "$action"
  python3 - "$PID" "$after" "$ax" <<'PY'
import sys
from pathlib import Path
import importlib.util
s=importlib.util.spec_from_file_location('ax','scripts/tatwo2-ax.py'); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
m.capture(int(sys.argv[1]), Path(sys.argv[2])); m.dump_tree(int(sys.argv[1]), Path(sys.argv[3]))
PY
  ended="$(date +%s)"
  print -r -- "| $number | $title | $result | $(( ended - started )) | $reason（AX：${number}-ax.txt） |" >> "$RESULT"
  sleep 1
}

# Actions below are deliberately semantic and fail closed. Missing AX controls are recorded, never inferred.
run_step 1 '開 App，選舊討論串，看到之前對話' '
  python3 - "$PID" <<"PY"
import sys, importlib.util
s=importlib.util.spec_from_file_location("ax","scripts/tatwo2-ax.py"); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); m.key(int(sys.argv[1]), "1", command=True)
PY
  if python3 - "$PID" <<"PY"
import sys, importlib.util
s=importlib.util.spec_from_file_location("ax","scripts/tatwo2-ax.py"); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
sys.exit(0 if m.click_named(int(sys.argv[1]), ["舊討論串", "Previous", "Thread"]) else 1)
PY
  then result="OK"; reason="已點選 AX 舊討論串控制項；對話可見性由後圖確認"; else reason="找不到舊討論串 AX 元件"; fi'

run_step 2 '在舊討論串接問一句，AI 記得前文' '
  before_text="$(python3 - "$PID" <<"PY"
import sys, importlib.util
s=importlib.util.spec_from_file_location("ax","scripts/tatwo2-ax.py"); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(m.static_text(int(sys.argv[1])))
PY
)"
  if python3 - "$PID" "$before_text" <<"PY"
import sys, importlib.util
s=importlib.util.spec_from_file_location("ax","scripts/tatwo2-ax.py"); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
pid=int(sys.argv[1]); before=sys.argv[2]
ok=m.set_composer(pid,"請延續前文，用一句話指出你記得的內容。") and m.send(pid) and m.wait_for_reply(pid,before)[0]
sys.exit(0 if ok else 1)
PY
  then result="OK"; reason="收到新增 AX 靜態文字"; else reason="找不到 composer 或 90 秒內未見新回覆"; fi'

run_step 3 '開新聊天，用 Claude 問一句並得到回覆' '
  if python3 - "$PID" <<"PY"
import sys, importlib.util
s=importlib.util.spec_from_file_location("ax","scripts/tatwo2-ax.py"); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); pid=int(sys.argv[1])
ok=m.click_named(pid,["新聊天","New Chat"]) and m.click_named(pid,["Claude","fable"]) and m.set_composer(pid,"請回覆：Claude 驗收成功。") and m.send(pid)
sys.exit(0 if ok else 1)
PY
  then result="OK（僅送出）"; reason="送出後回覆串流仍由 AX 後圖及人工檢視"; else reason="找不到新聊天、Claude 選單或 composer"; fi'

run_step 4 '同討論串切 GPT（Codex）再問一句' '
  if python3 - "$PID" <<"PY"
import sys, importlib.util
s=importlib.util.spec_from_file_location("ax","scripts/tatwo2-ax.py"); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); pid=int(sys.argv[1])
ok=m.click_named(pid,["gpt-5.5","GPT","Codex"]) and m.set_composer(pid,"請承接這條討論串前文回答 OK。") and m.send(pid)
sys.exit(0 if ok else 1)
PY
  then result="OK（僅送出）"; reason="模型切換與送出控制項已操作"; else reason="找不到 GPT/Codex 選單或 composer"; fi'

run_step 5 '切 Grok 問一句' '
  if python3 - "$PID" <<"PY"
import sys, importlib.util
s=importlib.util.spec_from_file_location("ax","scripts/tatwo2-ax.py"); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); pid=int(sys.argv[1])
ok=m.click_named(pid,["grok","Grok"]) and m.set_composer(pid,"請回覆：Grok 驗收成功。") and m.send(pid)
sys.exit(0 if ok else 1)
PY
  then result="OK（僅送出）"; reason="模型切換與送出控制項已操作"; else reason="找不到 Grok 選單或 composer"; fi'

run_step 6 '丟圖片問內容' '
  image="docs/UI定位冊/截圖/aurora/頁-usage.png"
  if [[ -f "$image" ]] && python3 - "$PID" "$image" <<"PY"
import sys, importlib.util
s=importlib.util.spec_from_file_location("ax","scripts/tatwo2-ax.py"); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
pid=int(sys.argv[1]); ok=m.paste_file(pid,__import__("pathlib").Path(sys.argv[2])) and m.set_composer(pid,"請描述這張圖片內容。") and m.send(pid); sys.exit(0 if ok else 1)
PY
  then result="OK（僅送出）"; reason="已以剪貼簿貼上指定 usage 圖並送出"; else reason="找不到圖片來源、composer 或貼上失敗"; fi'

run_step 7 '請 AI 跑 shell 指令並回結果' '
  if python3 - "$PID" <<"PY"
import sys, importlib.util
s=importlib.util.spec_from_file_location("ax","scripts/tatwo2-ax.py"); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); pid=int(sys.argv[1])
ok=m.set_composer(pid,"請執行 shell 指令 printf acceptance-ok，並回報結果。") and m.send(pid); sys.exit(0 if ok else 1)
PY
  then result="OK（僅送出）"; reason="工具執行中到完成需由 AX 後圖確認"; else reason="找不到 composer"; fi'

run_step 8 '加進 issue 清單，再塞回輸入框' '
  if python3 - "$PID" <<"PY"
import sys, importlib.util
s=importlib.util.spec_from_file_location("ax","scripts/tatwo2-ax.py"); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); pid=int(sys.argv[1])
ok=m.click_named(pid,["issue","Issue"]) and m.click_named(pid,["帶入","插入","Insert"]); sys.exit(0 if ok else 1)
PY
  then result="OK"; reason="issue 與帶入控制項已點選"; else reason="找不到 issue 清單或帶入 AX 元件"; fi'

run_step 9 'CLI 模式開 codex 終端，打一個指令' '
  if python3 - "$PID" <<"PY"
import sys, importlib.util
s=importlib.util.spec_from_file_location("ax","scripts/tatwo2-ax.py"); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); pid=int(sys.argv[1])
m.key(pid,"1",command=True); ok=m.click_named(pid,["CLI"]) and m.set_composer(pid,"printf acceptance-ok") and m.send(pid); sys.exit(0 if ok else 1)
PY
  then result="OK（僅送出）"; reason="CLI 控制項及輸入控制項已操作；真終端輸出見後圖"; else reason="找不到 CLI 或終端輸入 AX 元件"; fi'

run_step 10 'Bot 模式跟一個 bot 講話' '
  if python3 - "$PID" <<"PY"
import sys, importlib.util
s=importlib.util.spec_from_file_location("ax","scripts/tatwo2-ax.py"); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); pid=int(sys.argv[1])
m.key(pid,"1",command=True); ok=m.click_named(pid,["Bot"]) and m.set_composer(pid,"請回覆：Bot 驗收成功。") and m.send(pid); sys.exit(0 if ok else 1)
PY
  then result="OK（僅送出）"; reason="Bot 控制項及輸入控制項已操作"; else reason="找不到 Bot 或 composer AX 元件"; fi'

print -r -- '' >> "$RESULT"
print -r -- "斷線次數｜未自動判定（AX 僅以元件與新靜態文字判定）｜報錯次數｜未自動判定｜第一個字平均等待秒數｜未跑" >> "$RESULT"
