#!/bin/zsh
# 所有 @AppStorage 鍵都要登記在 ExportPrefsShield.factoryDefaults（匯出偏好隔離），否則金樣會受使用者／debug 偏好污染。
set -euo pipefail
cd "$(dirname "$0")/.."
src=$(grep -rhoE '@AppStorage\("[^"]+"' App/Sources/Tatwo2 | sed 's/@AppStorage("//;s/"//' | sort -u)
reg=$(sed -n '/factoryDefaults: \[String: Any\] = \[/,/^    \]/p' App/Sources/Tatwo2/New/ExportPrefsShield.swift | grep -oE '^\s*"[^"]+"' | tr -d ' "' | sort -u)
missing=$(comm -23 <(echo "$src") <(echo "$reg"))
if [[ -n "$missing" ]]; then echo "APPSTORAGE-REGISTRY FAIL 未登記：$missing"; exit 1; fi
echo "APPSTORAGE-REGISTRY PASS $(echo "$src" | wc -l | tr -d ' ') keys"
