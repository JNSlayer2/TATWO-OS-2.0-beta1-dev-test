#!/bin/bash
# 用法：build-room.sh <branch> [node 測試檔...]
# 路徑一律由 TATWO_ENTRY（入口，預設 ~/AI/TATWO OS）、TATWO_STAGING、TATWO_REPO 推出，不寫死任何一台機器。
# 主設備外接卷建置 GPT-6 房間推過來的分支。每房獨立建置快取；全域建置鎖確保同時只跑一個 swift build。
set -uo pipefail
B="$1"; shift || true
E="${TATWO_ENTRY:-$HOME/AI/TATWO OS}"; REPO="${TATWO_REPO:-$E/tatwo2}"; S="${TATWO_STAGING:-$E/staging}"
name="${B##*/}"; W="$S/rooms/build-$name"; export TMPDIR="$S/tmp/build-$name/"; mkdir -p "$TMPDIR"
export PATH="${TATWO_BUILD_PATH:-$HOME/.tatwo-build-deps/tmux/3.6a/bin:/opt/homebrew/bin}:$PATH"
SWIFT_TMP="${TATWO_SWIFT_TMPDIR:-/private/tmp/tatwo-swift/}"; mkdir -p "$SWIFT_TMP"
LOCK="$S/rooms/.build-lock"; waited=0
until mkdir "$LOCK" 2>/dev/null; do
  if [ -f "$LOCK/pid" ] && ! kill -0 "$(cat "$LOCK/pid")" 2>/dev/null; then rm -rf "$LOCK"; continue; fi
  sleep 5; waited=$((waited+5)); [ $((waited % 60)) = 0 ] && echo "等待建置鎖 ${waited}s（$(cat "$LOCK/owner" 2>/dev/null)）"
done
echo $$ > "$LOCK/pid"; echo "$B" > "$LOCK/owner"; trap "rm -rf \"$LOCK\"" EXIT
if [ -d "$W" ]; then git -C "$W" checkout -q --detach "$B" || exit 3; else git -C "$REPO" worktree add -q --detach "$W" "$B" || exit 3; fi
echo "BUILD $B @ $(git -C "$W" rev-parse --short HEAD)"
free=$(vm_stat | awk "/free|inactive/ {gsub(\"\\\\.\",\"\",\$NF); s+=\$NF} END {printf \"%.1f\", s*16384/1073741824}"); echo "本機 free+inactive ${free}GB; sysdisk avail $(df -h / | tail -1 | awk "{print \$4}")"
cd "$W" && TMPDIR="$SWIFT_TMP" swift build --product Tatwo2 --scratch-path "$S/build-cache/$name" > "$TMPDIR/build.log" 2>&1; rc=$?
echo "swift build exit=$rc"; grep -E "error:|Build complete" "$TMPDIR/build.log" | tail -25
if [ $rc -eq 0 ] && [ $# -gt 0 ]; then node --test --test-concurrency=2 "$@" 2>&1 | tail -30; fi
