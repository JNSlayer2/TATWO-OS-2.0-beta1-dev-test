#!/bin/bash
# 用法：gate-template.sh <branch> [node 測試檔／glob...]
# 主導驗收閘門範本（由 staging/rooms/gate-w88.sh 入庫參數化）：debug 建置＋指定測試＋release 建置。
# 路徑一律由 TATWO_ENTRY／TATWO_STAGING／TATWO_REPO 推出；不寫死任何一台機器。
E="${TATWO_ENTRY:-$HOME/AI/TATWO OS}"; S="${TATWO_STAGING:-$E/staging}"; R="${TATWO_REPO:-$E/tatwo2}"
W="${TATWO_THRICE_FIXTURES:-$S/tmp/w80}"; L="$W/upstream/garrytan-gbrain-668b9ba/LICENSE"
B="${1:?用法：gate-template.sh <branch> [測試檔...]}"; shift || true
H=$(git -C "$R" rev-parse --short "$B") || exit 3
name="${B##*/}"
bash "$(dirname "$0")/build-room.sh" "$B" 2>&1 | grep -E "BUILD|free\+inactive|swift build exit|error:"
if [ $# -gt 0 ]; then
  BIN="$S/build-cache/$name/out/Products/Debug/Tatwo2"
  [ -x "$BIN" ] || BIN="$S/build-cache/$name/arm64-apple-macosx/debug/Tatwo2"
  cd "$S/rooms/build-$name" && TMPDIR="$S/tmp/build-$name/" W80B_GBRAIN_HELPER="$W/gbrain-probe-adhoc" W80B_RELEASE_JSON="$W/evidence/release.json" W80B_ASSET="$W/gbrain-darwin-arm64" W80B_LICENSE="$L" TATWO2_TEST_BINARY="$BIN" node --test --test-concurrency=2 "$@" 2>&1 | grep -E "ℹ (tests|pass|fail|skipped|cancelled)|^✖ "
fi
echo "--- release build $H"; RC="$S/rooms/release-check"
[ -d "$RC" ] || git -C "$R" worktree add -q --detach "$RC" "$B"
git -C "$RC" checkout -q --detach "$B" && cd "$RC" && PATH="${TATWO_BUILD_PATH:-$HOME/.tatwo-build-deps/tmux/3.6a/bin:/opt/homebrew/bin}:$PATH" TMPDIR="${TATWO_SWIFT_TMPDIR:-/private/tmp/tatwo-swift/}" swift build -c release --product Tatwo2 --scratch-path "$S/build-cache/release-check" > "$S/tmp/release-$name.log" 2>&1; echo "release exit=$?"; grep -E "error:" "$S/tmp/release-$name.log" | head -5
echo DONE
