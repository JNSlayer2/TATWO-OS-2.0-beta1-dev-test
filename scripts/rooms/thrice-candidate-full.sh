#!/bin/bash
# 用法：thrice-candidate-full.sh [候選 worktree] [三輪輸出目錄]
# 對候選 worktree 建置後跑 scripts/tatwo-test-thrice.sh 三輪全套；不改該腳本行為，只呼叫它。
E="${TATWO_ENTRY:-$HOME/AI/TATWO OS}"; S="${TATWO_STAGING:-$E/staging}"
C="${1:-$S/rooms/candidate-thrice}"; OUT="${2:-$S/tmp/thrice-candidate/out2}"; W="${TATWO_THRICE_FIXTURES:-$S/tmp/w80}"
LOCK="$S/rooms/.build-lock"; until mkdir "$LOCK" 2>/dev/null; do [ -f "$LOCK/pid" ] && ! kill -0 "$(cat "$LOCK/pid")" 2>/dev/null && rm -rf "$LOCK"; sleep 5; done
echo $$ > "$LOCK/pid"; echo "candidate full" > "$LOCK/owner"
cd "$C" && export PATH="${TATWO_BUILD_PATH:-$HOME/.tatwo-build-deps/tmux/3.6a/bin:/opt/homebrew/bin}:$PATH" TMPDIR="$S/tmp/thrice-candidate/"; mkdir -p "$TMPDIR"
swift build --product Tatwo2 > "$TMPDIR/candidate-build.log" 2>&1; echo "build exit=$?"; rm -rf "$LOCK"
export W80B_GBRAIN_HELPER="$W/gbrain-probe-adhoc" W80B_RELEASE_JSON="$W/evidence/release.json" W80B_ASSET="$W/gbrain-darwin-arm64" W80B_LICENSE="$W/upstream/garrytan-gbrain-668b9ba/LICENSE" TATWO2_TEST_BINARY="$C/.build/debug/Tatwo2"
rm -rf "$OUT"
bash scripts/tatwo-test-thrice.sh "$OUT"; echo "EXIT=$?"
