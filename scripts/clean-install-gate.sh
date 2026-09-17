#!/bin/bash
# W90 乾淨安裝閘門：用隔離根＋空 HOME 啟動「候選」App，確認全新安裝下 os.sock 各讀取端點
# 都回得出空狀態，再（有 GUI 權限時）對設定每個 section 截圖留證。
#
#   scripts/clean-install-gate.sh --dry-run                 只列步驟，不啟動任何東西
#   scripts/clean-install-gate.sh --binary <候選 Tatwo2>     真的跑一輪
#
# 絕不碰 /Applications/TATWO OS.app、不碰真實 ~/Library/Application Support/tatwo2、不種預設資料。
set -uo pipefail
# 中文訊息經 cut／printf 需要 UTF-8 locale；GUI Terminal 工作階段可能是 C locale
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"

DRY_RUN=0
BINARY="${TATWO2_CANDIDATE_BINARY:-}"
ROOT=""
STAGING="${TATWO2_STAGING_DIR:-$HOME/AI/TATWO OS/staging}"
EVIDENCE=""
SECTIONS=(space issueList browserManagement agentAccounts modelAccess tatwoIsland \
          computerUse devices plugin github documents os)
RPCS=(device_status list_devices get_document bot_list os_binding_status)

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --binary) BINARY="${2:-}"; shift ;;
    --root) ROOT="${2:-}"; shift ;;
    --evidence) EVIDENCE="${2:-}"; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$EVIDENCE" ] || EVIDENCE="$STAGING/evidence/clean-install-$(date +%Y%m%d)"

pass=0; fail=0
step() { printf 'STEP %s\n' "$1"; }
ok()   { pass=$((pass+1)); printf 'PASS %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
note() { printf 'NOTE %s\n' "$1"; }

if [ "$DRY_RUN" = 1 ]; then
  echo "DRY RUN — 不啟動 App、不寫隔離根、不截圖"
  step "1/8 建立隔離根（mktemp -d /private/tmp/tatwo2-clean-XXXXXX）與空 HOME；"
  step "     設 NativeStagingIsolation 要求的一整組變數："
  step "     TATWO_STAGING_SCRATCH_HOME=HOME=CFFIXED_USER_HOME、TATWO_STAGING_ROOT、"
  step "     TATWO2_LIVE_ROOT、TATWO2_ENGINES_ROOT、CODEX_HOME=TATWO2_CODEX_SOURCE_HOME=<engines>/codex、"
  step "     CLAUDE_CONFIG_DIR=CLAUDE_SECURESTORAGE_CONFIG_DIR=<engines>/claude、"
  step "     TATWO2_OS_SOCKET、TATWO2_BROWSER_SOCKET、TATWO2_OS_ROOT、TATWO2_DOCS_ROOT、"
  step "     TATWO2_OS_UPSTREAM_PATH、TATWO2_SKILLET_PATH"
  step "2/8 檢查候選 binary 可執行，且不在 /Applications（正式 App 一律不碰）"
  step "3/8 背景啟動候選 App，log 寫到隔離根 app.log"
  step "4/8 等 \$TATWO2_OS_SOCKET 出現（最多 60 秒）"
  for rpc in "${RPCS[@]}"; do
    step "5/8 RPC $rpc → 逐項 PASS/FAIL"
  done
  step "6/8 空狀態斷言：list_devices 0 筆、get_document 0 專案 0 討論串、bot_list 0 隻 bot"
  step "7/8 有 GUI／輔助使用權限時，osascript 開設定並逐 section 截圖到："
  step "     $EVIDENCE/settings-<section>.png（${#SECTIONS[@]} 個 section：${SECTIONS[*]}）"
  step "     沒有權限就跳過截圖，只留 RPC 結果，並在輸出中明說退化原因"
  step "8/8 關閉候選 App；隔離根保留供檢查（不自動刪）"
  echo "DRYRUN OK steps=8 rpcs=${#RPCS[@]} sections=${#SECTIONS[@]}"
  exit 0
fi

# ---- 1/8 隔離根 ----
step "1/8 建立隔離根"
if [ -n "$ROOT" ]; then
  case "$ROOT" in /*) ;; *) echo "--root 必須是絕對路徑" >&2; exit 2 ;; esac
  [ -e "$ROOT" ] && { echo "--root 必須是全新目錄：$ROOT" >&2; exit 2; }
  mkdir -p "$ROOT" || exit 2
else
  ROOT="$(mktemp -d /private/tmp/tatwo2-clean-XXXXXX)" || exit 2
fi
ROOT="$(cd "$ROOT" && pwd -P)"
case "$ROOT" in
  "$HOME"/Library/Application*) echo "拒絕在真實資料夾下執行" >&2; exit 2 ;;
esac
export TATWO_STAGING_ROOT="$ROOT"
export TATWO_STAGING_SCRATCH_HOME="$ROOT/home"
export HOME="$TATWO_STAGING_SCRATCH_HOME"
export CFFIXED_USER_HOME="$HOME"
export TATWO2_LIVE_ROOT="$ROOT/live"
export TATWO2_ENGINES_ROOT="$ROOT/engines"
export CODEX_HOME="$TATWO2_ENGINES_ROOT/codex"
export TATWO2_CODEX_SOURCE_HOME="$CODEX_HOME"
export CLAUDE_CONFIG_DIR="$TATWO2_ENGINES_ROOT/claude"
export CLAUDE_SECURESTORAGE_CONFIG_DIR="$CLAUDE_CONFIG_DIR"
export TATWO2_OS_SOCKET="$TATWO2_LIVE_ROOT/os.sock"
export TATWO2_BROWSER_SOCKET="$ROOT/browser.sock"
export TATWO2_OS_ROOT="$ROOT/entry"
export TATWO2_DOCS_ROOT="$ROOT/docs"
export TATWO2_OS_UPSTREAM_PATH="$ROOT/docs/os-upstream.md"
export TATWO2_SKILLET_PATH="$ROOT/docs/skillet.md"
mkdir -p "$HOME" "$TATWO2_LIVE_ROOT" "$CODEX_HOME" "$CLAUDE_CONFIG_DIR" \
         "$TATWO2_OS_ROOT" "$TATWO2_DOCS_ROOT" || exit 2
ok "隔離根 ${ROOT}（空 HOME、空 live、空入口）"

# ---- 1b/8 種下「install.sh＋首次接入完成」後的最小入口 ----
# 空 HOME 下 App 會停在 W82 首次接入畫面、不開 os.sock（接入 UI 由 W82 測試覆蓋）。
# 這裡照 OSOnboarding.finish 的結果種：device.json（合成、本機為主設備）、憲法模板、
# 空 skillet、五個目錄。不種任何 bot／space／討論串——那些才是本閘門要驗的空狀態。
step "1b/8 種下首次接入完成後的最小入口（合成身份）"
ENTRY="$TATWO2_OS_ROOT"
SEED_ID="$(uuidgen | tr 'A-Z' 'a-z')"
BUNDLE_OS="$(dirname "$(dirname "${BINARY}")")/Resources/TatwoUltrawork_Tatwo2.bundle/Contents/Resources/os.md"
if [ -f "$BUNDLE_OS" ]; then cp "$BUNDLE_OS" "$ENTRY/os.md"; else printf '# TATWO OS\n' > "$ENTRY/os.md"; fi
printf '# 常用技能\n\n本檔只補充做法，不修改或放寬 os.md。\n' > "$ENTRY/skillet.md"
for d in gbrain rooms staging archive note; do mkdir -p "$ENTRY/$d"; done
HW="$(sysctl -n hw.model 2>/dev/null || echo Mac)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$ENTRY/device.json" <<JSON
{"schema":"tatwo.device-identity.v1","deviceID":"$SEED_ID","name":"clean-install 合成主機","hardwareModel":"$HW","role":"primary","epoch":1,"primaryDeviceID":"$SEED_ID","updatedAt":"$NOW","boundaries":["閘門用合成身份，不代表任何真實設備"],"resources":{"entry":"$ENTRY"},"managedEngines":[]}
JSON
ok "合成身份 ${SEED_ID}（primary／epoch 1）、憲法模板、空 skillet、五個目錄"
if [ "${#TATWO2_OS_SOCKET}" -ge 104 ]; then bad "os.sock 路徑超過 104 bytes"; fi

# ---- 2/8 候選 binary ----
# 同 bundle ID 的正式 App 若在跑，候選會被 TatwoSingleInstanceGuard 轉交後靜默退出（app.log 0 bytes）。
if pgrep -x tatwo2 >/dev/null 2>&1; then
  bad "已有 tatwo2 在執行（正式 App）；候選會被單一實例守門轉交後退出。先退出正式 App 再跑本閘門。"
  echo "GATE_EXIT=1"; exit 1
fi
step "2/8 檢查候選 binary"
if [ -z "$BINARY" ]; then
  bad "沒有指定候選 binary（--binary 或 TATWO2_CANDIDATE_BINARY）"
  echo "SUMMARY pass=$pass fail=$fail root=$ROOT"; exit 1
fi
case "$BINARY" in
  /Applications/*) bad "拒絕使用 /Applications 下的正式 App：$BINARY"
                   echo "SUMMARY pass=$pass fail=$fail root=$ROOT"; exit 1 ;;
esac
if [ -x "$BINARY" ]; then ok "候選 binary 可執行：$BINARY"; else
  bad "候選 binary 不可執行：$BINARY"
  echo "SUMMARY pass=$pass fail=$fail root=$ROOT"; exit 1
fi

# ---- 3/8 啟動 ----
step "3/8 啟動候選 App（隔離 env）"
"$BINARY" > "$ROOT/app.log" 2>&1 &
APP_PID=$!
cleanup() { kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; }
trap cleanup EXIT
sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then ok "候選 App 啟動 pid=$APP_PID"; else
  bad "候選 App 立刻退出；見 $ROOT/app.log"
  tail -20 "$ROOT/app.log"
  echo "SUMMARY pass=$pass fail=$fail root=$ROOT"; exit 1
fi

# ---- 4/8 等 socket ----
step "4/8 等 os.sock"
waited=0
while [ ! -e "$TATWO2_OS_SOCKET" ] && [ "$waited" -lt 60 ]; do sleep 1; waited=$((waited+1)); done
if [ -e "$TATWO2_OS_SOCKET" ]; then ok "os.sock 在 ${waited}s 內出現"; else
  bad "os.sock 60 秒未出現；見 $ROOT/app.log"
  tail -20 "$ROOT/app.log"
  echo "SUMMARY pass=$pass fail=$fail root=$ROOT"; exit 1
fi

# ---- 5/8 + 6/8 RPC 與空狀態 ----
call_rpc() {
  node --input-type=module -e '
import net from "node:net";
const socketPath = process.env.TATWO2_OS_SOCKET;
const method = process.argv[1];
const socket = net.createConnection({ path: socketPath });
let data = "";
socket.setEncoding("utf8");
socket.setTimeout(20000, () => { socket.destroy(new Error("timeout")); });
socket.on("connect", () => socket.end(JSON.stringify({ id: 1, method, params: {} }) + "\n"));
socket.on("data", chunk => { data += chunk; });
socket.on("error", error => { console.error(String(error?.message || error)); process.exit(1); });
socket.on("close", () => {
  try { console.log(JSON.stringify(JSON.parse(data.trim()))); }
  catch (error) { console.error("bad response: " + data.slice(0, 200)); process.exit(1); }
});
' "$1" 2>&1
}
for rpc in "${RPCS[@]}"; do
  step "5/8 RPC $rpc"
  out="$(call_rpc "$rpc")"; rc=$?
  # 以 JSON 的 ok 欄位判定；回應內出現 "error":null 不是失敗。
  verdict="$(printf '%s' "$out" | node --input-type=module -e '
let d=""; process.stdin.setEncoding("utf8"); process.stdin.on("data",c=>d+=c);
process.stdin.on("end",()=>{ try { const j=JSON.parse(d); console.log(j.ok===true ? "ok" : ("err:"+(j.error??"unknown"))); } catch { console.log("bad"); } });' 2>/dev/null)"
  if [ $rc -eq 0 ] && [ "$verdict" = "ok" ]; then
    ok "$rpc 回應 ${#out} bytes"
    printf '%s\n' "$out" > "$ROOT/rpc-$rpc.json"
  elif [ "$rpc" = get_document ] && [ "$verdict" = "err:remote_access_disabled_no_paired_devices" ]; then
    # 全新安裝沒有已配對設備，遠端讀取 RPC 依設計拒絕；這正是乾淨狀態應有的回應。
    ok "get_document 依設計拒絕（remote_access_disabled_no_paired_devices）"
    printf '%s\n' "$out" > "$ROOT/rpc-$rpc.json"
  else
    bad "${rpc}：$(printf '%s' "$out" | head -c 200)"
  fi
done
step "6/8 空狀態斷言"
empty_check() { # <檔名> <node 表達式（以 d 為回應物件，回 true＝空）>
  local file="$ROOT/rpc-$1.json"
  [ -s "$file" ] || { bad "$1 沒有可檢查的回應"; return; }
  if node --input-type=module -e '
import fs from "node:fs";
const d = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
process.exit(eval(process.argv[2]) ? 0 : 1);
' "$file" "$2"; then ok "$1 是空狀態"; else
    bad "$1 不是空狀態：$(head -c 200 "$file")"
  fi
}
empty_check list_devices 'JSON.stringify(d).match(/"(devices|result)"/) ? (d.devices ?? d.result?.devices ?? []).length === 0 : true'
empty_check get_document '(d.ok === false && d.error === "remote_access_disabled_no_paired_devices") || (((d.projects ?? d.result?.projects ?? []).length <= 1) && (d.threads ?? d.result?.threads ?? []).length === 0)'
empty_check bot_list '(d.bots ?? d.result?.bots ?? []).length === 0'

# ---- 7/8 截圖 ----
step "7/8 設定各 section 截圖"
gui_ready=1
command -v osascript >/dev/null 2>&1 || gui_ready=0
command -v screencapture >/dev/null 2>&1 || gui_ready=0
if [ "$gui_ready" = 1 ]; then
  osascript -e 'tell application "System Events" to get name of first process' >/dev/null 2>&1 || gui_ready=0
fi
if [ "$gui_ready" = 0 ]; then
  note "沒有 GUI／輔助使用權限（或無 osascript/screencapture）；退化成只做 RPC 檢查，本次不留截圖"
  note "要補截圖：在有登入視窗階段的 mini 上，授權終端機的「輔助使用」與「螢幕錄製」後重跑"
else
  mkdir -p "$EVIDENCE"
  for section in "${SECTIONS[@]}"; do
    if osascript -e 'tell application "System Events" to keystroke "," using command down' >/dev/null 2>&1; then
      sleep 1
      if screencapture -x "$EVIDENCE/settings-$section.png" >/dev/null 2>&1; then
        ok "截圖 settings-$section.png"
      else
        bad "截圖失敗 settings-${section}（螢幕錄製權限？）"
      fi
    else
      bad "osascript 無法操作設定視窗 section=$section"
    fi
  done
  note "截圖目錄：$EVIDENCE"
fi

# ---- 8/8 收尾 ----
step "8/8 關閉候選 App"
cleanup
trap - EXIT
ok "候選 App 已關閉；隔離根保留：$ROOT"
echo "SUMMARY pass=$pass fail=$fail root=$ROOT evidence=$EVIDENCE"
[ "$fail" = 0 ]
