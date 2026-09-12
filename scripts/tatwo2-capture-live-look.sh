#!/bin/zsh
# 真機外觀：用假資料模式真的把 1.0 視窗開在桌面上（有桌布、有玻璃折射），整個螢幕截一張。給使用者過目用。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/docs/UI定位冊/真機"
BIN="$ROOT/.build/debug/TatwoUltraworkMac"
WAIT="${WAIT_S:-6}"
shot() { # theme name env...
  local theme="$1" name="$2"; shift 2
  local dir="$OUT/$theme"; mkdir -p "$dir"
  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/tatwo2-live.XXXXXX")"; mkdir -p "$tmp/home" "$tmp/support"
  env HOME="$tmp/home" TATWO_ULTRAWORK_APP_SUPPORT="$tmp/support" TATWO_APP_SUPPORT="$tmp/support" \
    TATWO_ULTRAWORK_THEME="$theme" TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME=0 TATWO_ULTRAWORK_CHAT_CODEX_MIRROR=0 \
    "$@" "$BIN" >/dev/null 2>"$dir/$name.log" &
  local pid=$!
  sleep "$WAIT"
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >/dev/null 2>&1
  sleep 1
  screencapture -x "$dir/$name.png"
  kill "$pid" 2>/dev/null; sleep 0.5; kill -9 "$pid" 2>/dev/null
  rm -rf "$tmp"
  echo "[$theme] $name $( [[ -s "$dir/$name.png" ]] && echo ok || echo BLOCKED )"
}
for theme in aurora fable5; do
  shot "$theme" "chat-含左列"     TATWO_ULTRAWORK_EXPORT_TAB=chat TATWO_ULTRAWORK_CHAT_FIXTURE=chat-transcript TATWO_ULTRAWORK_EXPORT_CHAT_SCENE=send TATWO_ULTRAWORK_CHAT_RAIL_PINNED=1
  shot "$theme" "chat-右側資訊卡" TATWO_ULTRAWORK_EXPORT_TAB=chat TATWO_ULTRAWORK_CHAT_FIXTURE=chat-transcript TATWO_ULTRAWORK_EXPORT_CHAT_SCENE=send TATWO_ULTRAWORK_CHAT_RAIL_PINNED=1 TATWO_ULTRAWORK_EXPORT_RIGHT_PANEL=1 TATWO_ULTRAWORK_CHAT_RIGHT_PANEL_CONTENT=info
  shot "$theme" "chat-模型選單"   TATWO_ULTRAWORK_EXPORT_TAB=chat TATWO_ULTRAWORK_CHAT_FIXTURE=chat-transcript TATWO_ULTRAWORK_EXPORT_CHAT_SCENE=send TATWO_ULTRAWORK_CHAT_MODEL_PICKER_OPEN=1
  shot "$theme" "chat-主題選擇"   TATWO_ULTRAWORK_EXPORT_TAB=chat TATWO_ULTRAWORK_CHAT_FIXTURE=chat-transcript TATWO_ULTRAWORK_EXPORT_CHAT_SCENE=send TATWO_ULTRAWORK_CHAT_THEME_PICKER=1
  shot "$theme" "chat-靈動島"     TATWO_ULTRAWORK_EXPORT_TAB=chat TATWO_ULTRAWORK_CHAT_FIXTURE=chat-transcript TATWO_ULTRAWORK_EXPORT_CHAT_SCENE=send TATWO_ISLAND_PIN_EXPANDED=1
  shot "$theme" "cli-含左列"      TATWO_ULTRAWORK_EXPORT_TAB=chat TATWO_ULTRAWORK_EXPORT_CHAT_MODE=cli TATWO_ULTRAWORK_EXPORT_LOOPS_FIXTURE=1 TATWO_ULTRAWORK_CHAT_RAIL_PINNED=1
  shot "$theme" "bot-討論串"      TATWO_ULTRAWORK_EXPORT_CHAT_MODE=bot TATWO_ULTRAWORK_EXPORT_BOT_SCENE=thread
  for tab in usage modes plugins devices workflow; do
    shot "$theme" "頁-$tab" TATWO_ULTRAWORK_EXPORT_TAB="$tab" TATWO_ULTRAWORK_EXPORT_SYNC_FIXTURE=1 TATWO_ULTRAWORK_EXPORT_LOOPS_FIXTURE=1
  done
done
