#!/bin/bash
# 退出 TATWO OS：送 quit，若跳「結束 TATWO OS？」確認框則按「結束」（使用者 2026-09-17 授權），等到程序消失。
pgrep -f "/Applications/TATWO OS.app/Contents/MacOS/tatwo2" >/dev/null || { echo "not running"; exit 0; }
osascript -e 'tell application "TATWO OS" to quit' >/dev/null 2>&1 &
sleep 3
for i in 1 2 3; do
  osascript >/dev/null 2>&1 <<'AS'
tell application "System Events"
  tell process "tatwo2"
    repeat with w in windows
      try
        repeat with s in sheets of w
          if exists (button "結束" of s) then click button "結束" of s
        end repeat
      end try
    end repeat
  end tell
end tell
AS
  sleep 2; pgrep -f "/Applications/TATWO OS.app/Contents/MacOS/tatwo2" >/dev/null || break
done
for i in $(seq 1 40); do pgrep -f "/Applications/TATWO OS.app/Contents/MacOS/tatwo2" >/dev/null || { echo "quit OK"; exit 0; }; sleep 1; done
echo "still running"; exit 2
