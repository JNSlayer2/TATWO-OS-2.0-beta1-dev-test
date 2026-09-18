#!/bin/bash
# W94：自建 CEF 時對 Chromium 原始碼套的本機修補（冪等；每次 automate-git 前跑）。
# 只放「新 SDK 相容」這類不改行為的修補；每條註明來源與原因。
set -euo pipefail
SRC="${1:?usage: cef-local-patches.sh <chromium/src>}"
[ -d "$SRC/sandbox/mac" ] || { echo "no chromium src at $SRC; skip"; exit 0; }
# 1. macOS 27 SDK 拿掉 kSBXProfilePureComputation 的宣告（sandbox.h 只剩註解）。
#    值依 sandbox_init(3) 文件為 "pure-computation"，改用字面值；行為不變。
f="$SRC/sandbox/mac/seatbelt.cc"
if grep -q "kProfilePureComputation = kSBXProfilePureComputation;" "$f"; then
  sed -i "" 's|const char\* Seatbelt::kProfilePureComputation = kSBXProfilePureComputation;|const char* Seatbelt::kProfilePureComputation = "pure-computation";  // TATWO W94: macOS 27 SDK dropped kSBXProfilePureComputation|' "$f"
  echo "patched: sandbox/mac/seatbelt.cc (kSBXProfilePureComputation → literal)"
else
  echo "already patched: sandbox/mac/seatbelt.cc"
fi
