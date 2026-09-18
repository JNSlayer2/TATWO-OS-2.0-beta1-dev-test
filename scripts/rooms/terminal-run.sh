#!/bin/bash
# 用法：terminal-run.sh <名稱> <腳本路徑> [腳本參數...]  — 在主設備桌面 Terminal.app 的新分頁執行（GUI 工作階段：鑰匙圈可用、可執行外接卷上的二進位）
set -euo pipefail
NAME="$1"; shift; SCRIPT="$1"; shift
E="${TATWO_ENTRY:-$HOME/AI/TATWO OS}"; S="${TATWO_STAGING:-$E/staging}"; J="$S/gui-jobs"; mkdir -p "$J"; LOG="$J/$NAME.log"
WRAP="$J/$NAME.terminal-wrapper.sh"
ARGS=""; if [ $# -gt 0 ]; then for a in "$@"; do ARGS="$ARGS$(printf "%q " "$a")"; done; fi
printf "#!/bin/bash\nexport TATWO_ENTRY=%q TATWO_STAGING=%q TATWO_REPO=%q\nbash %q %s > %q 2>&1\necho \"EXIT=\$?\" >> %q\n" \
  "$E" "$S" "${TATWO_REPO:-$E/tatwo2}" "$SCRIPT" "$ARGS" "$LOG" "$LOG" > "$WRAP"; chmod +x "$WRAP"; rm -f "$LOG"
osascript -e "tell application \"Terminal\" to do script \"bash '$WRAP'; exit\"" >/dev/null
echo "started in Terminal.app → $LOG"
