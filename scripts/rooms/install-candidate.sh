#!/bin/bash
# 本機安裝候選版（離線來源）並做功能檢查。用法：install-candidate.sh <OFFLINE_RELEASE_DIR> <vX.Y.Z.NNN> <primary|secondary> <primary os.md sha12> [repo checkout 含 install.sh]
# repo 省略時取 TATWO_REPO，再省略取 $TATWO_ENTRY/tatwo2（入口預設 ~/AI/TATWO OS）。
set -uo pipefail
OFF="$1"; VER="$2"; ROLE="$3"; PSHA="$4"
E="${TATWO_ENTRY:-$HOME/AI/TATWO OS}"; REPO="${5:-${TATWO_REPO:-$E/tatwo2}}"
S="$(cd "$(dirname "$0")" && pwd)"
echo "== quit TATWO OS (if running)"
bash "$S/quit-tatwo.sh" || { echo "App 未退出，停止"; exit 2; }
echo "== install $VER from $OFF"
TATWO_OS_OFFLINE_RELEASE="$OFF" TATWO_OS_VERSION="$VER" bash "$REPO/install.sh"; rc=$?
echo "install exit=$rc"; [ $rc -eq 0 ] || exit $rc
echo "== wait for App and os.sock"
for i in $(seq 1 60); do [ -S "$HOME/Library/Application Support/tatwo2/live/os.sock" ] && pgrep -x tatwo2 >/dev/null && break; sleep 2; done
sleep 8
echo "== functional check"
python3 "$S/functional-check.py" "${VER#v}" "$ROLE" "$PSHA"
