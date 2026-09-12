#!/bin/bash
set -euo pipefail
# macOS built-ins only; plutil parses JSON (no jq, Python, or package install).
RETRY='curl -fsSL https://raw.githubusercontent.com/tatwo214/TATWO-OS-2.0-beta1-dev-test/main/install.sh | bash'
REPO=tatwo214/TATWO-OS-2.0-beta1-dev-test
TEMP=""
DEST="/Applications/TATWO OS.app"
STAGE=""
PREVIOUS=""
LOCK=""
REPLACED=0
COMMITTED=0
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$COMMITTED" == 0 ]]; then
    # Infer rename completion as well, covering a signal immediately after mv.
    if [[ -n "$STAGE" && ! -e "$STAGE/TATWO OS.app" && -e "$DEST" && "$REPLACED" == 1 ]]; then
      mv "$DEST" "$STAGE/failed.app.disabled" || exit 1
    fi
    if [[ -n "$PREVIOUS" && -e "$PREVIOUS" && ! -e "$DEST" && ! -L "$DEST" ]]; then
      mv "$PREVIOUS" "$DEST" || exit 1
      printf '已恢復舊版 App。\n' >&2
    fi
  fi
  [[ -z "$LOCK" ]] || rmdir "$LOCK" || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { printf '安裝失敗：%s\n重試：%s\n' "$1" "$RETRY" >&2; exit 1; }
trap 'fail "指令失敗（第 $LINENO 行）；暫存與備份保留，不會刪除原有資料。"' ERR
ENDPOINT="https://api.github.com/repos/$REPO/releases/latest"
if [[ -n "${TATWO_OS_VERSION:-}" ]]; then
  [[ "$TATWO_OS_VERSION" =~ ^v?[0-9]+[.][0-9]+([.][0-9]+)?([-+][A-Za-z0-9.-]+)?$ ]] || fail "版本格式不正確"
  ENDPOINT="https://api.github.com/repos/$REPO/releases/tags/$TATWO_OS_VERSION"
  RETRY="curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | TATWO_OS_VERSION='$TATWO_OS_VERSION' bash"
fi
printf '正在查詢可用版本…\n'
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/tatwo-install.XXXXXX")"
STATUS="$(curl --proto '=https' --tlsv1.2 -sSL --connect-timeout 15 --max-time 60 \
  -H 'Accept: application/vnd.github+json' -o "$TEMP/release.json" -w '%{http_code}' "$ENDPOINT")"
[[ "$STATUS" != 404 ]] || fail "尚無可用版本（或指定版本不存在）"
[[ "$STATUS" == 200 ]] || fail "GitHub 回應 HTTP ${STATUS}，請稍後重試"
ZIP_URL="" SHA_URL="" APP_URL="" RUNTIME_NAMES=" " INSTALL_READY=0 INDEX=0
while NAME="$(plutil -extract "assets.$INDEX.name" raw -o - "$TEMP/release.json" 2>/dev/null)"; do
  case "$NAME" in
    TATWO-OS-runtime-????????????.zip) RUNTIME_NAMES+="$NAME " ;;
    TATWO-OS-app.zip) APP_URL="$(plutil -extract "assets.$INDEX.browser_download_url" raw -o - "$TEMP/release.json")" ;;
    TATWO-OS.install-ready) INSTALL_READY=1 ;;
    TATWO-OS.zip) ZIP_URL="$(plutil -extract "assets.$INDEX.browser_download_url" raw -o - "$TEMP/release.json")" ;;
    TATWO-OS.zip.sha256) SHA_URL="$(plutil -extract "assets.$INDEX.browser_download_url" raw -o - "$TEMP/release.json")" ;;
  esac
  INDEX=$((INDEX + 1))
done
[[ "$INSTALL_READY" == 1 ]] || fail "此 Release 尚未完成新版安裝流程驗收；未下載 App、未變更既有安裝。請等待附有 install-ready 標記的新 Release。"
[[ -n "$ZIP_URL" && -n "$SHA_URL" ]] || fail "版本缺少 TATWO-OS.zip 或校驗檔"
for URL in "$ZIP_URL" "$SHA_URL"; do
  [[ "$URL" == "https://github.com/$REPO/releases/download/"* ]] || fail "附件下載網址不符合公開倉庫"
done
download_full() {
printf '正在下載 App 與 SHA-256 校驗檔…\n'
ZIP="$TEMP/TATWO-OS.zip"
if [[ -n "${TATWO_OS_PREFETCHED_ZIP:-}" ]]; then
  [[ -f "$TATWO_OS_PREFETCHED_ZIP" ]] || fail "預先下載的 App 不存在"
  ZIP="$TATWO_OS_PREFETCHED_ZIP"
else
  curl --proto '=https' --proto-redir '=https' -fSL --retry 2 -o "$ZIP" "$ZIP_URL"
fi
curl --proto '=https' --proto-redir '=https' -fSL --retry 2 -o "$TEMP/TATWO-OS.zip.sha256" "$SHA_URL"
read -r EXPECTED _ < "$TEMP/TATWO-OS.zip.sha256" || true
[[ "${EXPECTED:-}" =~ ^[[:xdigit:]]{64}$ ]] || fail "SHA-256 校驗檔格式錯誤"
ACTUAL="$(shasum -a 256 "$ZIP")"
ACTUAL="${ACTUAL%% *}"
[[ "$ACTUAL" == "$EXPECTED" ]] || fail "SHA-256 不符；未變更已安裝 App"
printf '校驗成功，正在解壓縮…\n'
# Reject traversal/absolute entries before extracting the verified publisher archive.
while IFS= read -r ENTRY; do
  case "$ENTRY" in /*|../*|*/../*|*/..) fail "壓縮檔含不安全路徑" ;; esac
done < <(unzip -Z1 "$ZIP")
# ditto 解壓會把 AppleDouble（._ 檔）還原成 xattr 而不是留成檔案；unzip 會留成檔案，破壞簽章封印。
ditto -x -k "$ZIP" "$TEMP/unpacked"
SOURCE="$TEMP/unpacked/TATWO OS.app"
[[ -d "$SOURCE" && ! -L "$SOURCE" && -f "$SOURCE/Contents/Info.plist" ]] || fail "附件內沒有有效的 TATWO OS.app"
}
# SHA-256 checks transport integrity; a valid persistent signature checks app identity.
verify_signed_app() {
  local app="$1" details
  [[ -d "$app" && ! -L "$app" ]] || fail "App 路徑無效"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == ai.tatwo.tatwo2 ]] || fail "App 識別碼不符"
  codesign --verify --deep --strict "$app" || fail "App 簽章驗證失敗"
  details="$(codesign -dv "$app" 2>&1)" || fail "無法讀取簽章"
  [[ "$details" != *Signature=adhoc* ]] || fail "ad-hoc 版本需先完成一次簽章身分遷移；未變更既有 App"
}
verify_continuity() {
  local requirement
  verify_signed_app "$1"
  verify_signed_app "$2"
  requirement="$(codesign -dr - "$1" 2>&1 | sed -n 's/^designated => //p')"
  [[ -n "$requirement" ]] || fail "無法讀取既有簽章身分"
  # codesign -R 的引數若不以 = 開頭會被當成檔案路徑；= 才是 inline requirement 文字。
  codesign --verify --deep --strict -R "=$requirement" "$2" || fail "新版簽章身分不相容"
  requirement="$(codesign -dr - "$2" 2>&1 | sed -n 's/^designated => //p')"
  [[ -n "$requirement" ]] || fail "無法讀取新版簽章身分"
  codesign --verify --deep --strict -R "=$requirement" "$1" || fail "新版簽章要求不相容"
}
# RUNTIME-ASSEMBLY-BEGIN
layer_download() {
  local name="$1" cached="$2" output="$3" url="" checksum="" n=0 entry expected actual
  while entry="$(plutil -extract "assets.$n.name" raw -o - "$TEMP/release.json" 2>/dev/null)"; do
    case "$entry" in
      "$name") url="$(plutil -extract "assets.$n.browser_download_url" raw -o - "$TEMP/release.json")" ;;
      "$name.sha256") checksum="$(plutil -extract "assets.$n.browser_download_url" raw -o - "$TEMP/release.json")" ;;
    esac
    n=$((n + 1))
  done
  for entry in "$url" "$checksum"; do
    [[ "$entry" == "https://github.com/$REPO/releases/download/"* ]] || return 1
  done
  curl --proto '=https' --proto-redir '=https' -fsSL --retry 2 -o "$output.sha256" "$checksum" || return 1
  read -r expected _ < "$output.sha256" || true
  [[ "${expected:-}" =~ ^[[:xdigit:]]{64}$ ]] || return 1
  if [[ -n "$cached" ]]; then
    [[ -f "$cached" ]] && ditto "$cached" "$output" || return 1
  else
    curl --proto '=https' --proto-redir '=https' -fSL --retry 2 -o "$output" "$url" || return 1
  fi
  actual="$(shasum -a 256 "$output")" || return 1
  [[ "${actual%% *}" == "$expected" ]] || return 1
  unzip -Z1 "$output" > "$output.entries" || return 1
  while IFS= read -r entry; do
    case "$entry" in /*|../*|*/../*|*/..) return 1 ;; esac
  done < "$output.entries"
}
assemble_runtime() (
  trap - EXIT ERR
  local meta="$SOURCE/Contents/Resources/runtime-layer.json" sha old_sha path parent n=0 reuse=1
  local paths=()
  layer_download TATWO-OS-app.zip "${TATWO_OS_PREFETCHED_APP_ZIP:-}" "$TEMP/app.zip" || exit 1
  ditto -x -k "$TEMP/app.zip" "$TEMP/split" || exit 1
  [[ -d "$SOURCE" && ! -L "$SOURCE" && ! -L "$SOURCE/Contents" ]] || exit 1
  sha="$(plutil -extract sha raw -o - "$meta")" || exit 1
  [[ "$sha" =~ ^[0-9a-f]{64}$ && "$RUNTIME_NAMES" == *" TATWO-OS-runtime-${sha:0:12}.zip "* ]] || exit 1
  old_sha="$(plutil -extract sha raw -o - "$DEST/Contents/Resources/runtime-layer.json" 2>/dev/null)" || old_sha=""
  [[ "$sha" == "$old_sha" ]] || reuse=0
  while path="$(plutil -extract "paths.$n" raw -o - "$meta" 2>/dev/null)"; do
    case "$path" in Resources/*|Frameworks/*) ;; *) exit 1 ;; esac
    case "/$path/" in *'/../'*|*'/./'*|*'//'*) exit 1 ;; esac
    parent="$SOURCE/Contents/$path"
    while [[ "$parent" != "$SOURCE" ]]; do
      [[ ! -L "$parent" ]] || exit 1
      parent="$(dirname "$parent")"
    done
    paths+=("$path"); n=$((n + 1))
    [[ -e "$DEST/Contents/$path" || -L "$DEST/Contents/$path" ]] || reuse=0
  done
  [[ "$n" -gt 0 ]] || exit 1
  if [[ "$reuse" == 0 ]]; then
    layer_download "TATWO-OS-runtime-${sha:0:12}.zip" "${TATWO_OS_PREFETCHED_RUNTIME_ZIP:-}" "$TEMP/runtime.zip" || exit 1
    ditto -x -k "$TEMP/runtime.zip" "$TEMP/runtime" || exit 1
  fi
  for path in "${paths[@]}"; do
    if [[ "$reuse" == 1 ]]; then parent="$DEST/Contents"; else parent="$TEMP/runtime"; fi
    ditto "$parent/$path" "$SOURCE/Contents/$path" || exit 1
  done
  verify_signed_app "$SOURCE"
  if [[ -e "$DEST" ]]; then verify_continuity "$DEST" "$SOURCE"; fi
)
# RUNTIME-ASSEMBLY-END
[[ -w /Applications ]] || fail "沒有 /Applications 寫入權限，請使用具權限的帳號"
# Serialize installers before inspecting the installed baseline.
if mkdir /Applications/.tatwo-update.lock 2>/dev/null; then
  LOCK=/Applications/.tatwo-update.lock
else
  fail "另一個更新正在執行，或先前更新中斷；請確認後再處理更新鎖"
fi
SOURCE="$TEMP/split/TATWO OS.app"
if [[ -n "$APP_URL" ]] && assemble_runtime; then
  printf '執行環境層組裝與簽章驗證成功。\n'
else
  [[ -z "$APP_URL" ]] || printf '執行環境層與簽章不符，改用完整下載\n' >&2
  download_full
fi
verify_signed_app "$SOURCE"
# Do not silently move development copies or reset their TCC grants.
for OTHER in /Applications/tatwo2.app "$HOME/Applications/tatwo2.app" "$HOME/Applications/TATWO OS.app"; do
  if [[ -e "$OTHER" || -L "$OTHER" ]]; then
    ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$OTHER/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$ID" != ai.tatwo.tatwo2 ]] || fail "發現舊安裝位置：$OTHER；請先封存並完成一次安裝位置遷移"
  fi
done
[[ ! -L "$DEST" ]] || fail "安裝目標是符號連結；未變更 App"
if [[ -e "$DEST" ]]; then
  verify_continuity "$DEST" "$SOURCE"
else
  # First installation has no local trust anchor. Require Apple's distribution assessment.
  spctl --assess --type execute "$SOURCE" || fail "首次安裝未通過 macOS 安全檢查；不會移除隔離標記"
fi
pgrep -x tatwo2 >/dev/null && fail "請先儲存工作並退出 TATWO OS，再執行更新"
STAGE="$(mktemp -d /Applications/.tatwo-update.XXXXXX)"
mv "$STAGE" "$STAGE.noindex"
STAGE="$STAGE.noindex"
ditto "$SOURCE" "$STAGE/TATWO OS.app"
verify_signed_app "$STAGE/TATWO OS.app"
if [[ -e "$DEST" ]]; then
  verify_continuity "$DEST" "$STAGE/TATWO OS.app"
fi
pgrep -x tatwo2 >/dev/null && fail "TATWO OS 已重新啟動；請退出後重試"
# Staging and destination share a filesystem; rename only after full validation.
if [[ -e "$DEST" ]]; then
  PREVIOUS="$STAGE/previous.app.disabled"
  mv "$DEST" "$PREVIOUS"
fi
REPLACED=1
mv "$STAGE/TATWO OS.app" "$DEST"
verify_signed_app "$DEST"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$DEST"
open "$DEST"
COMMITTED=1
# Keep rollback material outside Applications and outside normal app discovery.
# If archival fails, the unique .noindex staging directory still preserves it.
ARCHIVES="$HOME/Library/Application Support/TATWO OS/UpdateArchives"
ARCHIVE="$ARCHIVES/$(basename "$STAGE")"
if ! mkdir -p "$ARCHIVES" || ! mv "$STAGE" "$ARCHIVE"; then
  ARCHIVE="$STAGE"
  printf '新版已啟動，備份仍保留在暫存位置。\n' >&2
fi
printf '更新完成。備份保留於：%s\n下載暫存保留於：%s\n' "$ARCHIVE" "$TEMP"
