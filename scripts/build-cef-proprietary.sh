#!/usr/bin/env bash
# Preparation only by default. Chromium is built ONLY with explicit --execute.
set -euo pipefail
printf '%s\n' \
  'CEF H.264/AAC 自建準備：外接卷至少預留 120 GB（建議更多）。' \
  'M4／16 GB 預估 6–12 小時；實際時間及磁碟用量依版本而異。' \
  '需要完整 Xcode（含已接受的授權）、depot_tools、Python 3、Git。' \
  '預設只列計畫，不下載、不建置；專利／散布授權需另行確認。'

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
# This is the tracked pin used by tatwo-install-local-app.sh (not config/).
PIN="$ROOT/Apps/TatwoUltraworkMac/CEF/cef-runtime-arm64.json"
if [[ $# -lt 1 || $# -gt 2 || ( $# -eq 2 && "$2" != "--execute" ) ]]; then
  printf 'usage: %s /Volumes/<external-volume>/<output-directory> [--execute]\n' "$0" >&2
  exit 2
fi
# automate-git.py splits every command on whitespace, so the path it sees must be
# space-free. Volume names with spaces are common here: pass a space-free symlink
# (e.g. ~/cefbuild -> /Volumes/<vol with spaces>/...); the external-volume checks
# below use the resolved path, automate-git uses the path as given.
OUTPUT_PATH="$1"
OUTPUT="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1")"
case "$OUTPUT" in
  /Volumes/*/*) ;;
  *) printf '%s\n' 'error: output must be on an external volume under /Volumes' >&2; exit 1 ;;
esac

PIN_VALUES="$(python3 - "$PIN" <<'PY'
import json
import re
import sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
version = p["cefVersion"]
chromium = p["chromiumVersion"]
match = re.fullmatch(r"\d+\.\d+\.\d+\+g([0-9a-f]{7,40})\+chromium-(\d+\.\d+\.(\d+)\.\d+)", version)
if not match or match[2] != chromium or p["platform"] != "macosarm64":
    raise SystemExit("unsupported CEF pin")
archive = f"cef_binary_{version}_macosarm64_minimal.tar.bz2"
if p["archive"] != archive:
    raise SystemExit("CEF archive/pin mismatch")
print("\n".join([version, chromium, match[1], match[3], archive]))
PY
)"
VERSION="$(printf '%s\n' "$PIN_VALUES" | sed -n '1p')"
CHROMIUM="$(printf '%s\n' "$PIN_VALUES" | sed -n '2p')"
REVISION="$(printf '%s\n' "$PIN_VALUES" | sed -n '3p')"
BRANCH="$(printf '%s\n' "$PIN_VALUES" | sed -n '4p')"
ARCHIVE="$(printf '%s\n' "$PIN_VALUES" | sed -n '5p')"
WORK="$OUTPUT_PATH/work-$REVISION"
export GN_DEFINES="proprietary_codecs=true ffmpeg_branding=Chrome is_official_build=true chrome_pgo_phase=0 enable_dsyms=false"
ARGS=("--download-dir=$WORK" "--branch=$BRANCH" "--checkout=$REVISION"
  "--chromium-checkout=refs/tags/$CHROMIUM" "--arm64-build" "--no-debug-build"
  "--minimal-distrib-only" "--no-distrib-archive" "--build-target=cefclient"
  "--no-release-tests" "--force-build")
# --build-target=cefclient: make_distrib takes the framework from cefclient.app/Contents/Frameworks；
# 只編 cefsimple 會得到「No Release build files」空 distrib。clang-format 由 depot_tools 提供（PATH 已含）。
# --force-build: a previous interrupted run leaves src/out and recorded hashes, and
# automate-git would otherwise print "Not building" and skip straight to a missing distrib.
printf 'CEF=%s\nCHROMIUM=%s\nGN_DEFINES=%s\nOUTPUT=%s/%s\nWORK=%s\n' \
  "$VERSION" "$CHROMIUM" "$GN_DEFINES" "$OUTPUT" "$ARCHIVE" "$WORK"
printf 'automate-git.py'; printf ' %q' "${ARGS[@]}"; printf '\n'
if [[ "${2:-}" != "--execute" ]]; then
  printf '%s\n' 'PLAN_ONLY: no files created, no downloads, no build started.'
  exit 0
fi

# 只在真的要建置時才要求無空白路徑（計畫模式任何路徑都能列）。
[[ "$OUTPUT_PATH" == /* && "$OUTPUT_PATH" != *[[:space:]]* ]] || {
  printf '%s\n' 'error: pass an absolute, space-free output path (a symlink to the external volume is fine); automate-git.py cannot handle spaces' >&2; exit 2;
}
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  printf '%s\n' 'error: requires native arm64 macOS' >&2; exit 1;
}
[[ -n "${DEPOT_TOOLS:-}" && -f "$DEPOT_TOOLS/gclient.py" ]] || {
  printf '%s\n' 'error: set DEPOT_TOOLS to an existing official depot_tools checkout' >&2; exit 1;
}
DEPOT_TOOLS="$(cd "$DEPOT_TOOLS" && pwd -P)"
[[ "$(xcode-select -p)" == *Xcode*.app/Contents/Developer ]] || {
  printf '%s\n' 'error: select full Xcode, not Command Line Tools' >&2; exit 1;
}
xcodebuild -checkFirstLaunchStatus
VOLUME="/Volumes/$(printf '%s' "${OUTPUT#/Volumes/}" | cut -d / -f 1)"
[[ -d "$VOLUME" && "$(stat -f %d "$VOLUME")" != "$(stat -f %d /Volumes)" ]] || {
  printf '%s\n' 'error: external volume is not mounted' >&2; exit 1;
}
FREE_KB="$(df -Pk "$VOLUME" | awk 'END {print $4}')"
(( FREE_KB >= 120 * 1024 * 1024 )) || {
  printf '%s\n' 'error: less than 120 GiB available; refusing build' >&2; exit 1;
}
[[ ! -e "$OUTPUT/$ARCHIVE" && ! -e "$OUTPUT/$ARCHIVE.sha256" ]] || {
  printf '%s\n' 'error: output already exists; choose another output directory' >&2; exit 1;
}
mkdir -p "$WORK/tmp" "$WORK/cache" "$WORK/vpython"
export TMPDIR="$WORK/tmp/" XDG_CACHE_HOME="$WORK/cache" VPYTHON_VIRTUALENV_ROOT="$WORK/vpython"
export PATH="$DEPOT_TOOLS:$PATH"
# CEF_NINJA_JOBS：限制並行編譯數（16 GB 機器全開會把系統碟 swap 撐爆）。autoninja 讀
# NINJA_CORE_LIMIT 決定 -j，再轉成 siso -local_jobs；環境變數會經 automate-git 傳下去
# （automate-git 會把 depot_tools 排到 PATH 最前，shim 擋不住，所以用環境變數）。
if [[ -n "${CEF_NINJA_JOBS:-}" ]]; then
  [[ "$CEF_NINJA_JOBS" =~ ^[0-9]+$ ]] || { printf '%s\n' 'error: CEF_NINJA_JOBS must be an integer' >&2; exit 2; }
  export NINJA_CORE_LIMIT="$CEF_NINJA_JOBS"
  # autoninja 只在命令列有 -j 時才轉成 -local_jobs；automate-git 不帶 -j，所以直接用 siso 的環境變數。
  export SISO_LIMITS="local=$CEF_NINJA_JOBS"
fi
# Fetch source, not a third-party binary. Pin automate to the SAME CEF revision.
AUTOMATE="$WORK/automate-git.py"
curl --fail --proto '=https' --tlsv1.2 --max-redirs 0 \
  "https://raw.githubusercontent.com/chromiumembedded/cef/$REVISION/tools/automate/automate-git.py" \
  --output "$AUTOMATE"
# 新 SDK 相容修補（冪等）：第一次 sync 後才有 src；沒有就跳過，automate 之後會再跑到這裡。
bash "$ROOT/scripts/cef-local-patches.sh" "$WORK/chromium/src" || true
python3 "$AUTOMATE" "${ARGS[@]}" "--depot-tools-dir=$DEPOT_TOOLS"

DIST="$WORK/chromium/src/cef/binary_distrib"
NAME="${ARCHIVE%.tar.bz2}"
[[ -d "$DIST/$NAME/Release/Chromium Embedded Framework.framework" ]] || {
  printf '%s\n' 'error: expected pinned minimal distribution not produced' >&2; exit 1;
}
# CEF_OFFICIAL_ARCHIVE：自建的部分 dylib（libcef_sandbox／libEGL／libvk_swiftshader）在 macOS 27 dyld 上
# 會被拒「mis-aligned LINKEDIT string pool」（Chromium 內建 lld 的輸出對齊問題；主 framework 不受影響）。
# 給官方 archive 路徑時，用 dlopen 探測每個 Libraries/*.dylib，載入失敗的以官方同版取代（這些 dylib 與解碼器無關）。
if [[ -n "${CEF_OFFICIAL_ARCHIVE:-}" ]]; then
  [[ -f "$CEF_OFFICIAL_ARCHIVE" ]] || { printf '%s\n' 'error: CEF_OFFICIAL_ARCHIVE not found' >&2; exit 2; }
  LIBS="$DIST/$NAME/Release/Chromium Embedded Framework.framework/Libraries"
  OFFTMP="$WORK/tmp/official-libs"; rm -rf "$OFFTMP"; mkdir -p "$OFFTMP"
  for lib in "$LIBS"/*.dylib; do
    base="$(basename "$lib")"
    if ! python3 -c 'import ctypes,sys; ctypes.CDLL(sys.argv[1])' "$lib" 2>/dev/null; then
      tar -xjf "$CEF_OFFICIAL_ARCHIVE" -C "$OFFTMP" "$NAME/Release/Chromium Embedded Framework.framework/Libraries/$base"
      mkdir -p "$OUTPUT/selfbuilt-misaligned"; cp "$lib" "$OUTPUT/selfbuilt-misaligned/$base"
      cp "$OFFTMP/$NAME/Release/Chromium Embedded Framework.framework/Libraries/$base" "$lib"
      printf 'replaced dyld-rejected %s with official copy (self-built kept in selfbuilt-misaligned/)\n' "$base"
    fi
  done
fi
# macOS bsdtar 預設把 xattr 存成 AppleDouble（._*）成員，數量翻倍且會被 runtime 完整性檢查擋下（W13 同款坑）。
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs -cjf "$OUTPUT/$ARCHIVE.part" -C "$DIST" "$NAME"
mv "$OUTPUT/$ARCHIVE.part" "$OUTPUT/$ARCHIVE"
(cd "$OUTPUT" && shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
SHA="$(shasum -a 256 "$OUTPUT/$ARCHIVE" | awk '{print $1}')"
printf 'TATWO2_CEF_LOCAL_ARCHIVE=%q\nTATWO2_CEF_LOCAL_SHA256=%s\n' "$OUTPUT/$ARCHIVE" "$SHA"
printf '%s\n' 'Archive ready; playback and distribution/licensing review remain required.'
