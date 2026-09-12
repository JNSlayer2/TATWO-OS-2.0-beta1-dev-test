#!/bin/zsh
# 照搬稽核：每個複製來的畫面檔必須 (1) 檔頭寫「照搬自 <原檔>」 (2) diff 行數 ≤ 原檔 10% (3) 沒有 #if false 整段停用 (4) 沒有新增原檔沒有的 struct/class/enum/View。
# 用法：scripts/tatwo2-copy-audit.sh   → 逐檔 PASS/FAIL，任一 FAIL 就 exit 1。sol 每次 commit 前必跑。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0
for f in App/Sources/Tatwo2/{Shell,Pages,Chat,Bot,CLI,Browser}/*.swift(N); do
  head1="$(head -1 "$f")"
  src="$(echo "$head1" | sed -n 's/.*照搬自 \([^；;]*\).*/\1/p' | tr -d ' ')"
  if [[ -z "$src" ]]; then echo "FAIL $f：檔頭沒有「照搬自 <原檔>」"; fail=1; continue; fi
  [[ -f "$src" ]] || { echo "FAIL $f：原檔不存在 $src"; fail=1; continue; }
  orig=$(wc -l < "$src"); d=$(diff "$src" "$f" | grep -c '^[<>]')
  limit=$(( orig / 10 + 3 ))
  # 使用者裁決的整段拆除可放行：scripts/copy-audit-waivers.txt 每行「相對路徑|原因」，該檔不受 10% 上限（其餘檢查照跑）
  if [[ -f "$ROOT/scripts/copy-audit-waivers.txt" ]] && grep -qF "${f#$ROOT/}|" "$ROOT/scripts/copy-audit-waivers.txt"; then limit=$(( orig * 100 )); fi
  msg="原 $orig 行｜diff $d 行｜上限 $limit"
  bad=""
  (( d > limit )) && bad="$bad 改太多"
  grep -q '#if false' "$f" && bad="$bad 有#if-false"
  newtypes=$(grep -oE '^\s*(struct|final class|class|enum) [A-Za-z0-9_]+' "$f" | awk '{print $NF}' | sort -u | while read t; do grep -qE "(struct|class|enum) $t\b" "$src" || echo "$t"; done | tr '\n' ' ')
  [[ -n "$newtypes" ]] && bad="$bad 新增型別:$newtypes"
  if [[ -n "$bad" ]]; then echo "FAIL $f：$msg｜$bad"; fail=1; else echo "PASS $f：$msg"; fi
done
# Facade：只准資料型別與空 View stub；不准有 body 超過 3 行的 View
for f in App/Sources/Tatwo2/Facade/*.swift(N); do
  n=$(grep -cE 'var body: some View' "$f")
  if (( n > 0 )); then
    long=$(awk '/var body: some View/{c=0; inb=1; next} inb{c++; if ($0 ~ /^    }$/ || $0 ~ /^}$/){ if (c>4) print "長 body"; inb=0}}' "$f" | head -1)
    [[ -n "$long" ]] && { echo "FAIL $f：Facade 裡有自己畫的 View（body 超過 3 行）"; fail=1; }
  fi
done
# 薄殼不准依賴 1.0 Core：Tatwo2 target 有 dependencies 就 FAIL
t2=$(awk '/executableTarget\(name: "Tatwo2"/ || /^[[:space:]]+name: "Tatwo2",[[:space:]]*$/{f=1} f{print} f&&/\),/{exit}' Package.swift)
echo "$t2" | grep 'dependencies' | grep -vqE '^\s*dependencies: \["TatwoCEFBridge"\],?\s*$' && { echo "FAIL Package.swift：Tatwo2 target 只准依賴 TatwoCEFBridge（不能靠整包 TatwoUltraworkCore）"; fail=1; }
echo "$t2" | grep -q 'exclude' && { echo "FAIL Package.swift：Tatwo2 target 不准用 exclude 把編不過的檔或 Engine/Model/UI 排掉"; fail=1; }
(( fail == 0 )) && echo "COPY-AUDIT PASS" || echo "COPY-AUDIT FAIL"
exit $fail
