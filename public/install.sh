#!/bin/bash
set -euo pipefail
# macOS built-ins only; plutil parses JSON (no jq, Python, or package install).
RETRY='curl -fsSL https://raw.githubusercontent.com/tatwo214/TATWO-OS-2.0-beta1-dev-test/main/install.sh | bash'
REPO=tatwo214/TATWO-OS-2.0-beta1-dev-test
TEMP=""
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
ZIP_URL="" SHA_URL="" INDEX=0
while NAME="$(plutil -extract "assets.$INDEX.name" raw -o - "$TEMP/release.json" 2>/dev/null)"; do
  case "$NAME" in
    TATWO-OS.zip) ZIP_URL="$(plutil -extract "assets.$INDEX.browser_download_url" raw -o - "$TEMP/release.json")" ;;
    TATWO-OS.zip.sha256) SHA_URL="$(plutil -extract "assets.$INDEX.browser_download_url" raw -o - "$TEMP/release.json")" ;;
  esac
  INDEX=$((INDEX + 1))
done
[[ -n "$ZIP_URL" && -n "$SHA_URL" ]] || fail "版本缺少 TATWO-OS.zip 或校驗檔"
for URL in "$ZIP_URL" "$SHA_URL"; do
  [[ "$URL" == "https://github.com/$REPO/releases/download/"* ]] || fail "附件下載網址不符合公開倉庫"
done
printf '正在下載 App 與 SHA-256 校驗檔…\n'
curl --proto '=https' --proto-redir '=https' -fSL --retry 2 -o "$TEMP/TATWO-OS.zip" "$ZIP_URL"
curl --proto '=https' --proto-redir '=https' -fSL --retry 2 -o "$TEMP/TATWO-OS.zip.sha256" "$SHA_URL"
read -r EXPECTED _ < "$TEMP/TATWO-OS.zip.sha256" || true
[[ "${EXPECTED:-}" =~ ^[[:xdigit:]]{64}$ ]] || fail "SHA-256 校驗檔格式錯誤"
ACTUAL="$(shasum -a 256 "$TEMP/TATWO-OS.zip")"
ACTUAL="${ACTUAL%% *}"
[[ "$ACTUAL" == "$EXPECTED" ]] || fail "SHA-256 不符；未變更已安裝 App"
printf '校驗成功，正在解壓縮…\n'
# Reject traversal/absolute entries before extracting the verified publisher archive.
while IFS= read -r ENTRY; do
  case "$ENTRY" in /*|../*|*/../*|*/..) fail "壓縮檔含不安全路徑" ;; esac
done < <(unzip -Z1 "$TEMP/TATWO-OS.zip")
unzip -q "$TEMP/TATWO-OS.zip" -d "$TEMP/unpacked"
SOURCE="$TEMP/unpacked/TATWO OS.app"
[[ -d "$SOURCE" && ! -L "$SOURCE" && -f "$SOURCE/Contents/Info.plist" ]] || fail "附件內沒有有效的 TATWO OS.app"
printf '正在移除下載隔離標記（公測版未經 Apple 公證）…\n'
xattr -dr com.apple.quarantine "$SOURCE"
DEST="/Applications/TATWO OS.app"
[[ -w /Applications ]] || fail "沒有 /Applications 寫入權限，請使用具權限的帳號"
if [[ -e "$DEST" || -L "$DEST" ]]; then
  [[ ! -e "$DEST.previous" && ! -L "$DEST.previous" ]] || fail "已存在 TATWO OS.app.previous；請先自行移到安全位置再重試，不會覆蓋備份"
  printf '正在保留舊版為 TATWO OS.app.previous…\n'
  mv "$DEST" "$DEST.previous"
fi
printf '正在安裝至 Applications…\n'
ditto "$SOURCE" "$DEST"
printf '安裝完成，正在開啟 TATWO OS；若舊版仍在執行，請退出後重新開啟。\n'
open "$DEST"
printf '下載暫存保留於：%s\n' "$TEMP"
