#!/bin/bash
set -euo pipefail
INSTALL_STARTED_AT="${TATWO_OS_INSTALL_STARTED_AT:-$(date +%s)}"
# macOS built-ins only; plutil parses JSON (no jq, Python, or package install).
RETRY='curl -fsSL https://raw.githubusercontent.com/tatwo214/TATWO-OS-2.0-beta1-dev-test/main/install.sh | bash'
REPO=tatwo214/TATWO-OS-2.0-beta1-dev-test
if declare -F tatwo_private_transport >/dev/null; then REPO=tatwo214/TATWO-OS-2.0-private; fi
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
  # A completed rename is installation, even if the following journal write was interrupted.
  if [[ "$COMMITTED" == 0 && "$REPLACED" == 1 && ! -e "$DEST.new" && -d "$DEST" ]]; then
    if valid_restore_app "$DEST" && [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")" == "${TAG#v}" ]]; then
      COMMITTED=1
      write_transaction committed || true
    fi
  fi
  if [[ "$COMMITTED" == 0 ]]; then
    # Infer rename completion as well, covering a signal immediately after mv.
    if [[ -n "$STAGE" && ! -e "$DEST.new" && -e "$DEST" && "$REPLACED" == 1 ]]; then
      mv "$DEST" "$STAGE/failed.app.disabled" || exit 1
    fi
    if [[ -n "$PREVIOUS" && -e "$PREVIOUS" && ! -e "$DEST" && ! -L "$DEST" ]]; then
      mv "$PREVIOUS" "$DEST" || exit 1
      printf '已恢復舊版 App。\n' >&2
      if [[ -f "$STAGE/transaction.json" ]]; then
        plutil -replace phase -string rolled_back "$STAGE/transaction.json"
        printf '{"ok":false,"message":"rolled_back"}\n' > "$STAGE/result.json"
      fi
    fi
  fi
  if [[ -n "$LOCK" && -n "$STAGE" ]]; then mv "$LOCK" "$STAGE/lock.finished" || true; fi
  if [[ "$REPLACED" == 0 && -n "$STAGE" && -d "$STAGE" && ! -f "$STAGE/transaction.json" ]]; then
    local archives="$HOME/Library/Application Support/TATWO OS/UpdateArchives"
    mkdir -p "$archives" && mv "$STAGE" "$archives/failed-$(basename "$STAGE")" || true
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { printf '安裝失敗：%s\n重試：%s\n' "$1" "$RETRY" >&2; exit 1; }
trap 'fail "指令失敗（第 $LINENO 行）；暫存與備份保留，不會刪除原有資料。"' ERR
# TRANSACTION-BEGIN
write_transaction() {
  local phase="$1" file="$STAGE/transaction.json"
  plutil -create xml1 "$file.tmp"
  for pair in phase runID source expectedSHA backup previousVersion nextVersion owner ownerStart; do
    case "$pair" in
      phase) value="$phase";; runID) value="$(basename "$STAGE")";; source) value="$REPO:${TAG:-}";;
      expectedSHA) value="${EXPECTED_RELEASE_SHA:-}";; backup) value="$DEST.old";;
      previousVersion) value="${OLD_VERSION:-}";; nextVersion) value="${TAG#v}";; owner) value="$$";; ownerStart) value="$(process_start "$$")";;
    esac
    plutil -insert "$pair" -string "$value" "$file.tmp"
  done
  plutil -convert json "$file.tmp"; mv "$file.tmp" "$file"; sync
}
process_start() { LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
owner_active() {
  local pid="$1" started="${2:-}" actual
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]] || return 1
  actual="$(process_start "$pid")"
  if [[ -n "$actual" ]]; then
    # Legacy PID-only records remain conservative; all new owners include start time.
    [[ -z "$started" || "$actual" == "$started" ]]; return
  fi
  kill -0 "$pid" 2>/dev/null
}
write_owner() { printf '%s\n%s\n' "$$" "$(process_start "$$")" > "$1/owner"; }
owner_file_active() {
  local pid started
  [[ -f "$1/owner" ]] || return 1
  { IFS= read -r pid; IFS= read -r started || true; } < "$1/owner"
  owner_active "$pid" "${started:-}"
}
valid_restore_app() {
  [[ -d "$1" && ! -L "$1" ]] &&
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null)" == ai.tatwo.tatwo2 ]] &&
    codesign --verify --strict "$1" >/dev/null 2>&1
}
reconcile_transactions() {
  local stage phase owner started backup next
  for stage in "$(dirname "$DEST")"/.tatwo-update.*.noindex; do
    [[ -f "$stage/transaction.json" && ! -L "$stage" ]] || continue
    if ! owner="$(plutil -extract owner raw -o - "$stage/transaction.json")" ||
       ! phase="$(plutil -extract phase raw -o - "$stage/transaction.json")" ||
       ! backup="$(plutil -extract backup raw -o - "$stage/transaction.json")" ||
       [[ ! "$owner" =~ ^[0-9]+$ || "$owner" == 0 || "$backup" != "$DEST.old" ]]; then
      printf '{"ok":false,"message":"invalid_transaction"}\n' > "$stage/result.json"
      continue
    fi
    started="$(plutil -extract ownerStart raw -o - "$stage/transaction.json" 2>/dev/null || true)"
    owner_active "$owner" "$started" && continue
    case "$phase" in committed|recovered|rolled_back) continue;; esac
    [[ ! -L "$backup" && ! -L "$DEST" ]] || { printf '{"ok":false,"message":"restore_refused"}\n' > "$stage/result.json"; continue; }
    next="$(plutil -extract nextVersion raw -o - "$stage/transaction.json" 2>/dev/null || true)"
    # A crash after the second rename must not roll back an installed, verified candidate.
    if [[ "$phase" == replacing || "$phase" == replaced ]] && [[ ! -e "$DEST.new" && ! -L "$DEST.new" && -n "$next" ]] &&
       valid_restore_app "$DEST" && [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")" == "$next" ]]; then
      plutil -replace phase -string committed "$stage/transaction.json"
      printf '{"ok":true,"message":"interrupted_commit_completed"}\n' > "$stage/result.json"
      sync; continue
    fi
    if [[ -d "$backup" ]]; then
      if ! valid_restore_app "$backup"; then
        printf '{"ok":false,"message":"restore_refused"}\n' > "$stage/result.json"; continue
      fi
      [[ ! -e "$DEST" ]] || mv "$DEST" "$stage/interrupted.app.disabled" || return 1
      mv "$backup" "$DEST" || return 1
      plutil -replace phase -string recovered "$stage/transaction.json"
      printf '{"ok":false,"message":"interrupted_restored"}\n' > "$stage/result.json"
      sync
    elif [[ -e "$DEST" ]]; then
      plutil -replace phase -string recovered "$stage/transaction.json"
      printf '{"ok":false,"message":"interrupted_destination_present"}\n' > "$stage/result.json"
    fi
    if [[ -e "$DEST.new" && ! -L "$DEST.new" ]]; then mv "$DEST.new" "$stage/interrupted-new.app.disabled" || return 1; fi
  done
}
claim_directory() {
  local path="$1" temporary="$1.tmp.$$"
  mkdir "$temporary" 2>/dev/null || return 1
  write_owner "$temporary"
  # mv publishes owner with the directory. A competing directory may absorb our
  # temporary directory; verify ownership before doing anything under the lock.
  mv "$temporary" "$path" 2>/dev/null || return 1
  [[ "$(cat "$path/owner" 2>/dev/null)" == "$(printf '%s\n%s' "$$" "$(process_start "$$")")" ]]
}
acquire_update_lock() {
  local path="$(dirname "$DEST")/.tatwo-update.lock" owner modified now guard
  local admission="$(dirname "$DEST")/.tatwo-update.admission"
  # Serialize stale-guard reclamation too. Kernel ownership disappears on SIGKILL;
  # the stable admission inode is never deleted or interpreted as a live lock.
  [[ ! -L "$admission" ]] || fail "更新鎖路徑無效"
  exec 9>>"$admission"
  /usr/bin/lockf -s -t 0 9 || fail "更新鎖復原正在進行"
  if [[ -d "$path" ]]; then
    [[ ! -L "$path" ]] || fail "更新鎖無效"
    owner_file_active "$path" && fail "另一個更新正在執行"
    owner="$(cat "$path/owner" 2>/dev/null || true)"
    modified="$(stat -f %m "$path")"; now="$(date +%s)"
    [[ -n "$owner" || $((now - modified)) -gt 600 ]] || fail "更新鎖缺少 owner，等待孤兒判定"
    guard="$path/reconcile"
    if [[ -d "$guard" ]]; then
      modified="$(stat -f %m "$guard")"
      [[ $((now - modified)) -gt 600 ]] && ! owner_file_active "$guard" || fail "更新鎖復原正在進行"
      mv "$guard" "$path/reconcile-orphan.$(uuidgen)" || fail "無法保留孤兒復原鎖"
    fi
    claim_directory "$guard" || fail "更新鎖復原正在進行"
    [[ "$(cat "$path/owner" 2>/dev/null || true)" == "$owner" ]] || fail "更新鎖已變更"
    mv "$path" "$(dirname "$DEST")/.tatwo-lock-retained.$(uuidgen)"
  fi
  claim_directory "$path" || fail "另一個更新已接手"
  LOCK="$path"
  exec 9>&-
}
# TRANSACTION-END
# TEMP-RETENTION-BEGIN
archive_old_downloads() {
  local dir manifest="${TMPDIR:-/tmp}/tatwo-install-trash-$(uuidgen).md"
  while IFS= read -r -d '' dir; do
    [[ ! -L "$dir" && -O "$dir" && ! -f "$dir/transaction.json" ]] || continue
    if [[ -f "$dir/owner" ]]; then
      local owner; owner="$(cat "$dir/owner")"
      [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null && continue
    fi
    command -v trash >/dev/null || { printf '缺少 trash，保留舊暫存：%s\n' "$dir" >&2; continue; }
    printf -- '- Source: `%s`; older than 24h, no live recorded owner. Restore from macOS Trash to original path. No permanent deletion authorized.\n' "$dir" >> "$manifest"
    trash "$dir" || printf '- Trash failed; source retained: `%s`.\n' "$dir" >> "$manifest"
  done < <(find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'tatwo-install.*' -mmin +1440 -print0
    if [[ -n "${DEST:-}" ]]; then find "$(dirname "$DEST")" -maxdepth 1 -type d -name '.tatwo-update.*.noindex' -mmin +1440 -print0; fi)
}
# TEMP-RETENTION-END
# INVISIBLE-PRIMITIVES-BEGIN
clone_copy() { cp -cRPp "$1" "$2" 2>/dev/null || ditto "$1" "$2"; }
check_space() {
  local path="$1" bytes="$2" available required
  available="$(df -Pk "$path" | awk 'END {print $4}')"
  [[ "$available" =~ ^[0-9]+$ && "$bytes" =~ ^[0-9]+$ ]] || fail "無法確認可用空間"
  required=$(((bytes * 2 + 1023) / 1024))
  [[ "$available" -ge "$required" ]] || fail "空間不足，請清出至少 $(((required - available + 1023) / 1024)) MB（候選 App 大小 ×2）"
}
manifest_size() {
  osascript -l JavaScript - "$1" <<'JXA'
ObjC.import('Foundation');
function run(a) {
  const m = JSON.parse(ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(a[0], $.NSUTF8StringEncoding, null)));
  if (m.schema !== 1 || !Array.isArray(m.files) || !m.files.length) throw Error('manifest size unavailable');
  let size = 0;
  for (const f of m.files) {
    if (!Number.isSafeInteger(f.size) || f.size < 0) throw Error('invalid size');
    size += f.size;
    if (!Number.isSafeInteger(size) || size > 1e12) throw Error('invalid total');
  }
  return String(size);
}
JXA
}
# INVISIBLE-PRIMITIVES-END
# OFFLINE-RELEASE-BEGIN
# App handoff revalidates the release and marker online before quitting.
# Offline metadata is still checked against SHA, marker, version and signatures below.
# A missing cache entry fails closed rather than downloading after the App quits.
if [[ -n "${TATWO_OS_OFFLINE_RELEASE:-}" ]]; then
  REPO="$(cat "$TATWO_OS_OFFLINE_RELEASE/repository")"
  [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "快取倉庫無效"
  curl() {
    local output="" url="" status=0 source
    while [[ $# -gt 0 ]]; do
      case "$1" in -o) shift; output="$1";; -w) shift; status=1;; https:*) url="$1";; esac
      shift
    done
    [[ -n "$output" ]] || return 1
    case "$url" in
      "https://api.github.com/repos/$REPO/releases/tags/$TATWO_OS_VERSION") source=release.json;;
      "https://github.com/$REPO/releases/download/$TATWO_OS_VERSION/"*)
        source="${url##*/}"; [[ "$source" != *..* && "$source" == TATWO-OS* ]] || return 1;;
      *) return 1;;
    esac
    [[ -f "$TATWO_OS_OFFLINE_RELEASE/$source" ]] || return 1
    clone_copy "$TATWO_OS_OFFLINE_RELEASE/$source" "$output" || return 1
    [[ "$status" == 0 ]] || printf 200
  }
fi
# OFFLINE-RELEASE-END
acquire_update_lock
STAGE="$(mktemp -d "$(dirname "$DEST")/.tatwo-update.XXXXXX")"
mv "$STAGE" "$STAGE.noindex"; STAGE="$STAGE.noindex"
reconcile_transactions || fail "中斷更新復原失敗；保留交易與備份"
archive_old_downloads
ENDPOINT="https://api.github.com/repos/$REPO/releases/latest"
if [[ -n "${TATWO_OS_VERSION:-}" ]]; then
  [[ "$TATWO_OS_VERSION" =~ ^v?[0-9]+([.][0-9]+){1,3}$ ]] || fail "版本格式不正確"
  ENDPOINT="https://api.github.com/repos/$REPO/releases/tags/$TATWO_OS_VERSION"
  RETRY="curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | TATWO_OS_VERSION='$TATWO_OS_VERSION' bash"
fi
printf '正在查詢可用版本…\n'
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/tatwo-install.XXXXXX")"
printf '%s\n' "$$" > "$TEMP/owner"
STATUS="$(curl --proto '=https' --tlsv1.2 -sSL --connect-timeout 15 --max-time 60 \
  -H 'Accept: application/vnd.github+json' -o "$TEMP/release.json" -w '%{http_code}' "$ENDPOINT")"
[[ "$STATUS" != 404 ]] || fail "尚無可用版本（或指定版本不存在）"
[[ "$STATUS" == 200 ]] || fail "GitHub 回應 HTTP ${STATUS}，請稍後重試"
TAG="$(plutil -extract tag_name raw -o - "$TEMP/release.json")"
[[ "$TAG" =~ ^v?[0-9]+([.][0-9]+){1,3}$ ]] || fail "Release tag 格式不正確"
[[ -z "${TATWO_OS_VERSION:-}" || "${TATWO_OS_VERSION#v}" == "${TAG#v}" ]] || fail "Release tag 與指定版本不符"
[[ "$(plutil -extract draft raw -o - "$TEMP/release.json")" == false && "$(plutil -extract prerelease raw -o - "$TEMP/release.json")" == false ]] || fail "Release 尚未發行或已撤回"
ZIP_URL="" SHA_URL="" APP_URL="" RUNTIME_NAMES=" " INSTALL_READY=0 READY_URL="" RELEASE_HAS_MANIFEST=0 ZIP_SIZE=0 INDEX=0
while NAME="$(plutil -extract "assets.$INDEX.name" raw -o - "$TEMP/release.json" 2>/dev/null)"; do
  case "$NAME" in
    TATWO-OS-runtime-????????????.zip) RUNTIME_NAMES+="$NAME " ;;
    TATWO-OS-app.zip) APP_URL="$(plutil -extract "assets.$INDEX.browser_download_url" raw -o - "$TEMP/release.json")" ;;
    TATWO-OS.install-ready) INSTALL_READY=1; READY_URL="$(plutil -extract "assets.$INDEX.browser_download_url" raw -o - "$TEMP/release.json")" ;;
    TATWO-OS.zip) ZIP_URL="$(plutil -extract "assets.$INDEX.browser_download_url" raw -o - "$TEMP/release.json")"
      ZIP_SIZE="$(plutil -extract "assets.$INDEX.size" raw -o - "$TEMP/release.json" 2>/dev/null || echo 0)" ;;
    TATWO-OS.manifest.json) RELEASE_HAS_MANIFEST=1 ;;
    TATWO-OS.zip.sha256) SHA_URL="$(plutil -extract "assets.$INDEX.browser_download_url" raw -o - "$TEMP/release.json")" ;;
  esac
  INDEX=$((INDEX + 1))
done
[[ "$INSTALL_READY" == 1 ]] || fail "此 Release 尚未完成新版安裝流程驗收；未下載 App、未變更既有安裝。請等待附有 install-ready 標記的新 Release。"
[[ -n "$ZIP_URL" && -n "$SHA_URL" ]] || fail "版本缺少 TATWO-OS.zip 或校驗檔"
for URL in "$ZIP_URL" "$SHA_URL" "$READY_URL"; do
  [[ "$URL" == "https://github.com/$REPO/releases/download/"* ]] || fail "附件下載網址不符合公開倉庫"
done
curl --proto '=https' --proto-redir '=https' -fsSL --max-time 60 -o "$TEMP/install-ready" "$READY_URL"
# 2026-09-13 之前的公開版（v2.0.1–v2.0.5）marker 只有名字沒有 SHA；接受並改以 .sha256 綁定，不得讓既有公測者升不上來。
LEGACY_READY=0
grep -qE '^[[:xdigit:]]{64}  ' "$TEMP/install-ready" || { [[ "$RELEASE_HAS_MANIFEST" == 0 ]] || fail "含 manifest 的版本必須有 hash-bound marker"; LEGACY_READY=1; printf 'install-ready 為舊格式（無 SHA），改以 .sha256 綁定候選版本。\n' >&2; }
curl --proto '=https' --proto-redir '=https' -fsSL --retry 2 -o "$TEMP/TATWO-OS.zip.sha256" "$SHA_URL"
# DOWNLOAD-RETRY-BEGIN
retry_download() {
  local output="$1" url="$2" attempt
  if [[ -n "${TATWO_OS_OFFLINE_RELEASE:-}" ]]; then curl -o "$output" "$url"; return; fi
  for attempt in 1 2 3 4 5 6; do
    curl --proto '=https' --proto-redir '=https' --http1.1 -fSL -C - --connect-timeout 15 --max-time 3600 --speed-limit 1024 --speed-time 60 -o "$output" "$url" && return 0
    [[ "$attempt" == 6 ]] || sleep "$((attempt * 3))"
  done
  return 1
}
ready_matches() {
  local name="$1" expected="$2" hash entry count=0
  [[ "${LEGACY_READY:-0}" != 1 || "${RELEASE_HAS_MANIFEST:-0}" != 0 || "$name" != TATWO-OS.zip ]] || return 0
  while read -r hash entry || [[ -n "$hash$entry" ]]; do
    if [[ "$entry" == "$name" ]]; then
      [[ "$hash" == "$expected" ]] || return 1
      count=$((count + 1))
    fi
  done < "$TEMP/install-ready"
  [[ "$count" == 1 ]]
}
# DOWNLOAD-RETRY-END
download_full() {
printf '正在下載 App 與 SHA-256 校驗檔…\n'
ZIP="$TEMP/TATWO-OS.zip"
# 大檔下載：慢線路上 HTTP/2 串流常在中途被中斷（curl 92）；用 HTTP/1.1、續傳、對所有錯誤重試。
if [[ -n "${TATWO_OS_PREFETCHED_ZIP:-}" ]]; then
  [[ -f "$TATWO_OS_PREFETCHED_ZIP" ]] || fail "預先下載的 App 不存在"
  clone_copy "$TATWO_OS_PREFETCHED_ZIP" "$ZIP"
else
  retry_download "$ZIP" "$ZIP_URL"
fi
curl --proto '=https' --proto-redir '=https' -fSL --retry 2 -o "$TEMP/TATWO-OS.zip.sha256" "$SHA_URL"
read -r EXPECTED _ < "$TEMP/TATWO-OS.zip.sha256" || true
[[ "${EXPECTED:-}" =~ ^[[:xdigit:]]{64}$ ]] || fail "SHA-256 校驗檔格式錯誤"
ACTUAL="$(shasum -a 256 "$ZIP")"
ACTUAL="${ACTUAL%% *}"
[[ "$ACTUAL" == "$EXPECTED" ]] || fail "SHA-256 不符；未變更已安裝 App"
ready_matches TATWO-OS.zip "$EXPECTED" || fail "install-ready SHA 不符"
printf '校驗成功，正在解壓縮…\n'
# Reject traversal/absolute entries before extracting the verified publisher archive.
unzip -Z1 "$ZIP" > "$TEMP/full.entries" || fail "無法讀取 ZIP 目錄"
while IFS= read -r ENTRY; do
  case "$ENTRY" in /*|../*|*/../*|*/..) fail "壓縮檔含不安全路徑" ;; esac
done < "$TEMP/full.entries"
# ditto 解壓會把 AppleDouble（._ 檔）還原成 xattr 而不是留成檔案；unzip 會留成檔案，破壞簽章封印。
ditto -x -k "$ZIP" "$STAGE/full"
SOURCE="$STAGE/full/TATWO OS.app"
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
  requirement="$(codesign -dr - "$1" 2>&1 | sed -n 's/^designated => //p')"
  [[ -n "$requirement" ]] || fail "無法讀取既有簽章身分"
  # codesign -R 的引數若不以 = 開頭會被當成檔案路徑；= 才是 inline requirement 文字。
  codesign --verify --strict -R "=$requirement" "$2" || fail "新版簽章身分不相容"
  requirement="$(codesign -dr - "$2" 2>&1 | sed -n 's/^designated => //p')"
  [[ -n "$requirement" ]] || fail "無法讀取新版簽章身分"
  codesign --verify --strict -R "=$requirement" "$1" || fail "新版簽章要求不相容"
}
# VERSION-BINDING-BEGIN
verify_version_binding() {
  local candidate installed
  candidate="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist")"
  [[ "$candidate" == "${TAG#v}" ]] || fail "App 版號與 Release tag 不符"
  [[ ! -e "$DEST" || "${TATWO_OS_ALLOW_DOWNGRADE:-}" == 1 ]] && return 0
  installed="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")"
  osascript -l JavaScript - "$installed" "$candidate" <<'JXA' || fail "拒絕降版或版本無效；需要時明確設定 TATWO_OS_ALLOW_DOWNGRADE=1"
function run(a) {
  const version = s => {
    if (!/^[0-9]+(\.[0-9]+){1,3}$/.test(s)) throw Error('invalid version');
    return s.split('.').map(n => n.replace(/^0+/, '') || '0').concat(['0','0']).slice(0,4);
  };
  const old = version(a[0]), next = version(a[1]);
  for (let i=0; i<4; i++) if (old[i] !== next[i]) {
    if (old[i].length > next[i].length || (old[i].length === next[i].length && old[i] > next[i])) throw Error('downgrade');
    return;
  }
}
JXA
}
# VERSION-BINDING-END
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
    [[ -f "$cached" ]] && clone_copy "$cached" "$output" || return 1
  else
    retry_download "$output" "$url" || return 1
  fi
  actual="$(shasum -a 256 "$output")" || return 1
  [[ "${actual%% *}" == "$expected" ]] || return 1
  ready_matches "$name" "$expected" || return 1
  [[ "$name" != TATWO-OS.manifest.json ]] || return 0
  unzip -Z1 "$output" > "$output.entries" || return 1
  while IFS= read -r entry; do
    case "$entry" in /*|../*|*/../*|*/..) return 1 ;; esac
  done < "$output.entries"
}
# DELTA-TREE-BEGIN
delta_tree() (
  unzip -Z1 "$2" > "$4.entries" || exit 1
  osascript -l JavaScript - "$@" <<'JXA' > "$4.assemble.sh" || exit 1
ObjC.import('Foundation');
function run(a) {
  const read = p => ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(p, $.NSUTF8StringEncoding, null));
  const m = JSON.parse(read(a[0])), zip = a[1], old = a[2], out = a[3] + '/Contents';
  const q = s => "'" + String(s).replace(/'/g, "'\\''") + "'";
  const safe = p => typeof p === 'string' && p.length && !/[\x00-\x1f\x7f]/.test(p);
  const entries = new Map(), commands = ['set -euo pipefail', 'clone_copy() { cp -cRPp \"$1\" \"$2\" 2>/dev/null || ditto \"$1\" \"$2\"; }', 'mkdir -p ' + q(out)];
  if (m.schema !== 1 || !Array.isArray(m.files) || !m.files.length) throw Error('manifest schema');
  for (const e of m.files) {
    if (!safe(e.path) || (e.path !== '.' && e.path.split('/').some(p => !p || p === '.' || p === '..')) ||
        entries.has(e.path) || !/^[0-7]{1,4}$/.test(e.mode) || !/^[0-9a-f]{64}$/.test(e.sha256) ||
        !Number.isSafeInteger(e.size) || e.size < 0) throw Error('manifest record');
    const parts = e.path.split('/'); parts.pop();
    if (e.path !== '.' && !(entries.get(parts.join('/') || '.') || {}).directory) throw Error('manifest parent');
    if (e.symlink !== undefined) {
      if (e.directory || !safe(e.symlink) || e.symlink[0] === '/') throw Error('symlink target');
      const resolved = parts.slice();
      for (const p of e.symlink.split('/')) {
        if (p === '..') { if (!resolved.length) throw Error('symlink escape'); resolved.pop(); }
        else if (p && p !== '.') resolved.push(p);
      }
    }
    if (e.directory && (e.size !== 0 || e.sha256 !== 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')) throw Error('directory record');
    entries.set(e.path, e);
  }
  if (!(entries.get('.') || {}).directory) throw Error('manifest root');
  const packed = read(a[3] + '.entries').split('\n').filter(Boolean), seen = new Set();
  for (const p of packed) {
    const key = p.replace(/\/$/, ''), e = entries.get(key);
    if (!e || seen.has(key) || p.endsWith('/') !== !!e.directory) throw Error('delta entry');
    seen.add(key);
  }
  for (const [p, e] of entries) {
    const target = out + '/' + p, source = old + '/Contents/' + p, blob = a[3] + '.part-' + commands.length;
    if (e.directory) { commands.push('mkdir -p ' + q(target)); continue; }
    let input = source;
    if (seen.has(p)) {
      commands.push('unzip -p ' + q(zip) + ' ' + q(p.replace(/[\\*?[\]]/g, '\\$&')) + ' > ' + q(blob),
        '[[ "$(shasum -a 256 < ' + q(blob) + ')" == ' + q(e.sha256 + '  -') + ' ]]',
        '[[ "$(stat -f %z ' + q(blob) + ')" == ' + q(e.size) + ' ]]');
      input = blob;
      if (e.symlink !== undefined) { input += '.link'; commands.push('ln -s ' + q(e.symlink) + ' ' + q(input)); }
      commands.push('chmod ' + (e.symlink !== undefined ? '-h ' : '') + e.mode + ' ' + q(input));
    } else {
      for (let parent = source.slice(0, source.lastIndexOf('/')); parent !== old; parent = parent.slice(0, parent.lastIndexOf('/')))
        commands.push('[[ ! -L ' + q(parent) + ' ]]');
      commands.push('[[ ! -L ' + q(old) + ' ]]', '[[' + (e.symlink !== undefined ? ' -L ' + q(source) : ' -f ' + q(source) + ' && ! -L ' + q(source)) + ' ]]');
    }
    commands.push((e.symlink !== undefined ? 'cp -Pp ' : 'clone_copy ') + q(input) + ' ' + q(target), '[[ "$(stat -f %Lp ' + q(target) + ')" == ' + q(e.mode.replace(/^0+/, '') || '0') + ' ]]');
    commands.push(e.symlink !== undefined
      ? '[[ -L ' + q(target) + ' && "$(readlink ' + q(target) + ')" == ' + q(e.symlink) + ' && "$(printf %s "$(readlink ' + q(target) + ')" | shasum -a 256)" == ' + q(e.sha256 + '  -') + ' && "$(stat -f %z ' + q(target) + ')" == ' + q(e.size) + ' ]]'
      : '[[ -f ' + q(target) + ' && ! -L ' + q(target) + ' && "$(stat -f %z ' + q(target) + ')" == ' + q(e.size) + ' && "$(shasum -a 256 < ' + q(target) + ')" == ' + q(e.sha256 + '  -') + ' ]]');
  }
  for (const [p, e] of Array.from(entries).reverse()) if (e.directory) commands.push('chmod ' + e.mode + ' ' + q(out + '/' + p));
  return commands.map(c => c + ' || exit 1').join('\n');
}
JXA
  bash "$4.assemble.sh"
)
# DELTA-TREE-END
soft_fail() { exit 1; }
assemble_delta() (
  trap - EXIT ERR
  fail() { soft_fail "$@"; }
  local manifest="$STAGE/manifest.json" from tag installed
  layer_download TATWO-OS.manifest.json "$TATWO_OS_PREFETCHED_MANIFEST" "$manifest" || exit 1
  from="$(plutil -extract fromTag raw -o - "$manifest")" || exit 1
  tag="$(plutil -extract tag raw -o - "$manifest")" || exit 1
  installed="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")" || exit 1
  [[ "$from" =~ ^v[0-9]+([.][0-9]+){1,3}$ && "$tag" =~ ^v[0-9]+([.][0-9]+){1,3}$ && "$from" == "v${installed#v}" &&
     "$tag" == "$(plutil -extract tag_name raw -o - "$TEMP/release.json")" ]] || exit 1
  layer_download "TATWO-OS-delta-$from-$tag.zip" "$TATWO_OS_PREFETCHED_DELTA_ZIP" "$STAGE/delta.zip" || exit 1
  delta_tree "$manifest" "$STAGE/delta.zip" "$DEST" "$STAGE/delta.app.disabled" || exit 1
  SOURCE="$STAGE/delta.app.disabled"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE/Contents/Info.plist")" == "${tag#v}" ]] || exit 1
  verify_signed_app "$SOURCE"
)
assemble_runtime() (
  trap - EXIT ERR
  fail() { soft_fail "$@"; }
  local meta="$SOURCE/Contents/Resources/runtime-layer.json" sha old_sha path parent n=0 reuse=1
  local paths=()
  layer_download TATWO-OS-app.zip "${TATWO_OS_PREFETCHED_APP_ZIP:-}" "$TEMP/app.zip" || exit 1
  ditto -x -k "$TEMP/app.zip" "$STAGE/split" || exit 1
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
    ditto -x -k "$TEMP/runtime.zip" "$SOURCE/Contents" || exit 1
  fi
  for path in "${paths[@]}"; do
    if [[ "$reuse" == 1 ]]; then
      parent="$DEST/Contents/$path"
      while [[ "$parent" != "$DEST" ]]; do
        [[ ! -L "$parent" ]] || exit 1
        parent="$(dirname "$parent")"
      done
      [[ ! -L "$DEST" ]] || exit 1
      parent="$DEST/Contents"
      clone_copy "$parent/$path" "$SOURCE/Contents/$path" || exit 1
    else
      [[ -e "$SOURCE/Contents/$path" || -L "$SOURCE/Contents/$path" ]] || exit 1
    fi
  done
  verify_signed_app "$SOURCE"
)
# RUNTIME-ASSEMBLY-END
# Query the uncompressed, checksum-bound whole-tree size BEFORE any candidate ZIP.
if [[ "$RELEASE_HAS_MANIFEST" == 1 ]]; then
  layer_download TATWO-OS.manifest.json "${TATWO_OS_PREFETCHED_MANIFEST:-}" "$TEMP/space-manifest.json" || fail "缺少可校驗的候選大小清單；未下載 App"
  CANDIDATE_BYTES="$(manifest_size "$TEMP/space-manifest.json")" || fail "候選大小無效"
else
  # v2.0.5 及之前的公開版沒有大小清單：以完整 zip 壓縮大小 ×4 估計，既有公測者仍能一鍵升級。
  [[ "$ZIP_SIZE" =~ ^[0-9]+$ && "$ZIP_SIZE" -gt 0 ]] || fail "無法取得候選 App 大小"
  CANDIDATE_BYTES=$((ZIP_SIZE * 4))
  printf '此版本沒有大小清單，以壓縮大小 ×4 估計所需空間。\n' >&2
fi
check_space "$(dirname "$DEST")" "$CANDIDATE_BYTES"
[[ -w /Applications ]] || fail "沒有 /Applications 寫入權限，請使用具權限的帳號"
SOURCE="$STAGE/split/TATWO OS.app"
if [[ -n "${TATWO_OS_PREFETCHED_DELTA_ZIP:-}" && -n "${TATWO_OS_PREFETCHED_MANIFEST:-}" ]]; then
  if assemble_delta; then SOURCE="$STAGE/delta.app.disabled"
  else printf '差異更新驗證失敗或版本不符，改用層級下載\n' >&2; fi
fi
if [[ "$SOURCE" != "$STAGE/split/TATWO OS.app" ]]; then
  printf '差異更新組裝與簽章驗證成功。\n'
elif [[ -n "$APP_URL" ]] && assemble_runtime; then
  printf '執行環境層組裝與簽章驗證成功。\n'
else
  [[ -z "$APP_URL" ]] || printf '執行環境層與簽章不符，改用完整下載\n' >&2
  download_full
  verify_signed_app "$SOURCE"
fi
# Do not silently move development copies or reset their TCC grants.
verify_version_binding "$SOURCE"
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
ACTUAL_KB="$(du -skA "$SOURCE" | awk '{print $1}')"
[[ "$ACTUAL_KB" =~ ^[0-9]+$ ]] || fail "無法確認組裝大小"
[[ "$CANDIDATE_BYTES" -ge "$((ACTUAL_KB * 1024))" ]] || CANDIDATE_BYTES=$((ACTUAL_KB * 1024))
mv "$SOURCE" "$STAGE/TATWO OS.app"
verify_version_binding "$STAGE/TATWO OS.app"
check_space "$(dirname "$DEST")" "$CANDIDATE_BYTES"
pgrep -x tatwo2 >/dev/null && fail "TATWO OS 已重新啟動；請退出後重試"
# Staging and destination share a filesystem; prepare before the one-rename gap.
[[ ! -e "$DEST.new" && ! -L "$DEST.new" ]] || fail "保留的新版候選需先人工檢查"
if [[ -e "$DEST.old" ]]; then mv "$DEST.old" "$STAGE/previous-retained.app.disabled"; fi
OLD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null || true)"
EXPECTED_RELEASE_SHA="$(awk '$2 == "TATWO-OS.zip" {print $1}' "$TEMP/install-ready")"
if [[ "${LEGACY_READY:-0}" == 1 ]]; then read -r EXPECTED_RELEASE_SHA _ < "$TEMP/TATWO-OS.zip.sha256" || true; fi
[[ "$EXPECTED_RELEASE_SHA" =~ ^[[:xdigit:]]{64}$ ]] || fail "install-ready 缺少完整候選 SHA"
ditto "$TEMP/install-ready" "$STAGE/source-sha256.txt"
write_transaction prepared
mv "$STAGE/TATWO OS.app" "$DEST.new"
PREVIOUS="$DEST.old"
write_transaction replacing
REPLACED=1
if [[ -e "$DEST" ]]; then mv "$DEST" "$DEST.old"; fi
mv "$DEST.new" "$DEST"
write_transaction committed
COMMITTED=1
# Candidate was verified before same-volume renames; no bundle bytes changed.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
LAUNCH_MESSAGE=installed
"$LSREGISTER" -f "$DEST" || { LAUNCH_MESSAGE=registration_failed; true; }
open "$DEST" || { LAUNCH_MESSAGE=open_failed; true; }
INSTALL_SECONDS=$(($(date +%s) - INSTALL_STARTED_AT))
printf '{"ok":true,"message":"%s","installSeconds":%s}\n' "$LAUNCH_MESSAGE" "$INSTALL_SECONDS" > "$STAGE/result.json"
[[ -z "${TATWO_OS_TIMING_FILE:-}" ]] || printf '%s' "$INSTALL_SECONDS" > "$TATWO_OS_TIMING_FILE"
[[ ! -e "$DEST.old" ]] || mv "$DEST.old" "$STAGE/previous.app.disabled"
mv "$LOCK" "$STAGE/lock.finished"; LOCK=""
# Keep rollback material outside Applications and outside normal app discovery.
# If archival fails, the unique .noindex staging directory still preserves it.
ARCHIVES="$HOME/Library/Application Support/TATWO OS/UpdateArchives"
ARCHIVE="$ARCHIVES/$(basename "$STAGE")"
if ! mkdir -p "$ARCHIVES" || ! mv "$STAGE" "$ARCHIVE"; then
  ARCHIVE="$STAGE"
  printf '新版已啟動，備份仍保留在暫存位置。\n' >&2
fi
printf '更新完成。備份保留於：%s\n下載暫存保留於：%s\n' "$ARCHIVE" "$TEMP"
