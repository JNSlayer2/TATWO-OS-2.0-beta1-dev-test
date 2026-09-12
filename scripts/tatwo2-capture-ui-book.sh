#!/bin/zsh
# 2.0 訂位 UI：用 1.0 的假資料模式，把每個房間在兩套主題（極光 / Fable5 紀念）下各拍一張。
# 輸出：docs/UI定位冊/截圖/<主題>/<名稱>.png ＋ manifest.tsv。不碰 harness-exam 的 1.0 金樣。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$ROOT/docs/UI定位冊/截圖}"
BIN="$ROOT/.build/debug/TatwoUltraworkMac"
[[ -x "$BIN" ]] || { echo "缺 $BIN，先 swift build --product TatwoUltraworkMac"; exit 1; }
SETTLE="${SETTLE_MS:-900}"
MANIFEST="$OUT/manifest.tsv"
mkdir -p "$OUT"; : > "$MANIFEST"

capture() { # theme name appearance width height extra-env...
  local theme="$1" name="$2" appearance="$3" w="$4" h="$5"; shift 5
  local dir="$OUT/$theme"; mkdir -p "$dir"
  local png="$dir/$name.png" log="$dir/$name.log"
  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/tatwo2-book.XXXXXX")"; mkdir -p "$tmp/home" "$tmp/support"
  env HOME="$tmp/home" TATWO_ULTRAWORK_APP_SUPPORT="$tmp/support" TATWO_APP_SUPPORT="$tmp/support" \
    TATWO_ULTRAWORK_THEME="$theme" \
    TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT="$png" \
    TATWO_ULTRAWORK_EXPORT_WIDTH="$w" TATWO_ULTRAWORK_EXPORT_HEIGHT="$h" TATWO_ULTRAWORK_EXPORT_SCALE="2" \
    TATWO_ULTRAWORK_EXPORT_APPEARANCE="$appearance" TATWO_ULTRAWORK_EXPORT_ASYNC_SETTLE_MS="$SETTLE" \
    TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME="0" TATWO_ULTRAWORK_CHAT_CODEX_MIRROR="0" \
    "$@" "$BIN" 2>"$log"
  local st="ok"; [[ -s "$png" ]] || st="BLOCKED"
  printf '%s\t%s\t%s\t%s\n' "$theme" "$name" "$st" "$*" >> "$MANIFEST"
  echo "[$theme] $name $status"
  rm -rf "$tmp"
}

for theme in aurora fable5; do
  for scene in send stream stop resume slash plg engine_switch reattach cold_start orphan queued_turn; do
    capture "$theme" "chat-$scene" dark 1440 900 TATWO_ULTRAWORK_EXPORT_TAB=chat TATWO_ULTRAWORK_EXPORT_CHAT_SCENE="$scene"
  done
  capture "$theme" "chat-右側資訊卡" dark 1440 900 TATWO_ULTRAWORK_EXPORT_TAB=chat TATWO_ULTRAWORK_EXPORT_CHAT_SCENE=send TATWO_ULTRAWORK_EXPORT_RIGHT_PANEL=1 TATWO_ULTRAWORK_CHAT_RIGHT_PANEL_CONTENT=info
  capture "$theme" "chat-浮動資訊卡" dark 1440 900 TATWO_ULTRAWORK_EXPORT_TAB=chat TATWO_ULTRAWORK_EXPORT_CHAT_SCENE=send TATWO_ULTRAWORK_CHAT_INFOCARD_FLOATING=1
  capture "$theme" "chat-模型選單" dark 1440 900 TATWO_ULTRAWORK_EXPORT_TAB=chat TATWO_ULTRAWORK_EXPORT_CHAT_SCENE=send TATWO_ULTRAWORK_CHAT_MODEL_PICKER_OPEN=1
  capture "$theme" "chat-主題選擇" dark 1440 900 TATWO_ULTRAWORK_EXPORT_TAB=chat TATWO_ULTRAWORK_EXPORT_CHAT_SCENE=send TATWO_ULTRAWORK_CHAT_THEME_PICKER=1
  capture "$theme" "chat-ultrawork面板" dark 1440 900 TATWO_ULTRAWORK_EXPORT_TAB=chat TATWO_ULTRAWORK_EXPORT_CHAT_SCENE=send TATWO_ULTRAWORK_CHAT_ULTRAWORK_PANEL_OPEN=1
  capture "$theme" "chat-靈動島展開" dark 1440 900 TATWO_ULTRAWORK_EXPORT_TAB=chat TATWO_ULTRAWORK_EXPORT_CHAT_SCENE=send TATWO_ISLAND_PIN_EXPANDED=1
  capture "$theme" "chat-瀏覽器面板" dark 1440 900 TATWO_ULTRAWORK_EXPORT_TAB=chat TATWO_ULTRAWORK_EXPORT_CHAT_SCENE=send TATWO_BROWSER_UI_FIXTURE=1 TATWO_BROWSER_MANAGEMENT_FIXTURE=1 TATWO_ULTRAWORK_EXPORT_RIGHT_PANEL=1 TATWO_ULTRAWORK_CHAT_RIGHT_PANEL_CONTENT=browser
  capture "$theme" "chat-子討論串" dark 1440 900 TATWO_ULTRAWORK_EXPORT_TAB=chat TATWO_ULTRAWORK_EXPORT_CHAT_SCENE=subthreads TATWO_ULTRAWORK_CHAT_RAIL_PINNED=1
  capture "$theme" "chat-派工卡" dark 1440 900 TATWO_ULTRAWORK_EXPORT_TAB=chat TATWO_ULTRAWORK_EXPORT_CHAT_SCENE=dispatch
  capture "$theme" "設定-瀏覽器管理" dark 1440 900 TATWO_ULTRAWORK_EXPORT_TAB=chat TATWO_ULTRAWORK_EXPORT_CHAT_SCENE=send TATWO_ULTRAWORK_CHAT_SETTINGS_OPEN=1 TATWO_ULTRAWORK_EXPORT_SETTINGS_SECTION=browserManagement
  capture "$theme" "cli-終端機模式" dark 1440 900 TATWO_ULTRAWORK_EXPORT_TAB=chat TATWO_ULTRAWORK_EXPORT_CHAT_MODE=cli TATWO_ULTRAWORK_EXPORT_LOOPS_FIXTURE=1
  for scene in rail-tree rail-collapsed rail-empty thread group-sandbox space-full space-compact space-status add-space quick-card settings-9row stress; do
    w=1440; h=900; [[ "$scene" == "stress" ]] && { w=980; h=720; }
    capture "$theme" "bot-$scene" light $w $h TATWO_ULTRAWORK_EXPORT_CHAT_MODE=bot TATWO_ULTRAWORK_EXPORT_BOT_SCENE="$scene"
  done
  for tab in usage modes plugins devices workflow; do
    capture "$theme" "頁-$tab" dark 1440 900 TATWO_ULTRAWORK_EXPORT_TAB="$tab" TATWO_ULTRAWORK_EXPORT_SYNC_FIXTURE=1 TATWO_ULTRAWORK_EXPORT_LOOPS_FIXTURE=1
  done
done
echo "done: $(grep -c $'\tok\t' "$MANIFEST") ok / $(grep -c BLOCKED "$MANIFEST") blocked"
