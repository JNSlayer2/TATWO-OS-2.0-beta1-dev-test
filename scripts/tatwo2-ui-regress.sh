#!/bin/zsh
# 2.0 全房間回歸：照 manifest.tsv 的 72 個場景（兩主題）用 2.0 薄殼匯出，逐張跟 2x 金樣比對。
# 用法：scripts/tatwo2-ui-regress.sh [金樣根目錄]
# 2026-09-06：每張匯出都給自己的 browser socket 與 live root，絕不碰正式 App 的 ~/Library/Application Support/tatwo2/live（review-5）   預設 <your-volume>/goldens/ui-2x（repo 外備份）
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
GOLD="${1:-$HOME/Library/Application Support/tatwo2/goldens/ui-2x}"
BIN="$ROOT/.build/debug/Tatwo2"
OUT="${REGRESS_OUT:-/tmp/tatwo2-regress}"; mkdir -p "$OUT"
MAN="$ROOT/docs/UI定位冊/截圖/manifest.tsv"
pass=0; fail=0; report="$OUT/report.tsv"; : > "$report"
while IFS=$'\t' read -r theme name st0 envs; do
  [[ "$st0" == "ok" ]] || continue
  w=1440; h=900; app=dark
  [[ "$name" == bot-* ]] && app=light
  [[ "$name" == bot-stress ]] && { w=980; h=720; }
  tmp="$(mktemp -d)"; mkdir -p "$tmp/home" "$tmp/support"
  png="$OUT/$theme-$name.png"
  env HOME="$tmp/home" TATWO_ULTRAWORK_APP_SUPPORT="$tmp/support" TATWO_APP_SUPPORT="$tmp/support" \
    TATWO2_BROWSER_SOCKET="/tmp/t2b-rg-$$-$RANDOM.sock" TATWO2_LIVE_ROOT="$tmp/live" \
    TATWO_ULTRAWORK_THEME="$theme" TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT="$png" \
    TATWO_ULTRAWORK_EXPORT_WIDTH="$w" TATWO_ULTRAWORK_EXPORT_HEIGHT="$h" TATWO_ULTRAWORK_EXPORT_SCALE=2 \
    TATWO_ULTRAWORK_EXPORT_APPEARANCE="$app" TATWO_ULTRAWORK_EXPORT_ASYNC_SETTLE_MS=900 \
    TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME=0 TATWO_ULTRAWORK_CHAT_CODEX_MIRROR=0 \
    ${=envs} "$BIN" >/dev/null 2>&1
  rm -rf "$tmp"
  line="$(swift "$ROOT/scripts/tatwo2-ui-compare.swift" "$GOLD/$theme/$name.png" "$png" 3 2>&1)"
  if [[ "$line" == *PASS* ]]; then pass=$((pass+1)); st=PASS; else fail=$((fail+1)); st=FAIL; fi
  printf '%s\t%s\t%s\t%s\n' "$theme" "$name" "$st" "$line" >> "$report"
  echo "$st $theme $name ${line%%明顯*}"
done < "$MAN"
echo "REGRESS pass=$pass fail=$fail  report=$report"
