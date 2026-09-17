#!/usr/bin/env bash
# tatwo-device-sync.sh — 跨設備同步執行器（可前景觸發，亦由受管 LaunchAgent helper 背景執行）
#
# 設計語意（與設備分頁按鈕一致）：
#   版本（程式碼）：副→主 各推 dev 分支 → 主整合進 release/tatwo-os → 兩台拉。
#                   同祖先時只是 fast-forward，無需合併。
#   資料庫：主設備是唯一真相；副設備向主「索取」（主→副 單向鏡像），
#           絕不回傳、永不衝突。每台自己的設備身分/安裝狀態不同步。
#
# 安全：只讀診斷預設；寫入前一律先備份；不碰 auth/token/Keychain；
#       version-push 只推 dev/<device>，永不動 main / release。
#
# 用法：
#   tatwo-device-sync.sh version-status
#   tatwo-device-sync.sh version-push   [--device NAME] [--message MSG]
#   tatwo-device-sync.sh version-pull   [--no-install]
#   tatwo-device-sync.sh role-status
#   tatwo-device-sync.sh set-primary    --name NAME [--expected-epoch N]
#                                        [--authorize-runtime-fallback]
#   tatwo-device-sync.sh integrate
#   tatwo-device-sync.sh db-pull        [--from HOST] [--dry-run]
#   tatwo-device-sync.sh sync-request   --target NAME [--action system-pull|db-pull|version-pull]
#   tatwo-device-sync.sh sync-poll      [--device NAME] [--from HOST]
#   tatwo-device-sync.sh sync-ack-status --id REQUEST_ID
#   tatwo-device-sync.sh trust-rotate  [--rotated-at ISO8601]
#   tatwo-device-sync.sh register       [--role primary|secondary] [--name NAME] [--host HOST]
#                                        [--pairing-seed SEED]（已有主設備時，secondary 必填）
#   tatwo-device-sync.sh pairing-create （主設備產生限時 3 分鐘、單次有效的配對代碼）
#   tatwo-device-sync.sh devices-list
#   tatwo-device-sync.sh profile-push  --name NAME [--source-file PATH]
#                        （NAME: claude-global|claude-project|codex-global|codex-project|os-mirror-os|os-mirror-issue；
#                          os-mirror-* 僅現任主設備可推，需 --source-file）
#   tatwo-device-sync.sh profile-pull  --name NAME （寫入 .incoming，不自動覆寫）
#   tatwo-device-sync.sh profile-apply --name NAME （顯示 diff、備份舊檔、套用 .incoming）
#   tatwo-device-sync.sh skillet-source-sync [publish|accept|both]
#     （loop-channel/skillet/ purpose lane：export-bound → 對端 import-activate）
#   tatwo-device-sync.sh inventory-publish
#     （本機 hw.model / chip / RAM / CPU% / 內存壓力 / loop 數 → 通道 inventory/<deviceID>.json）
#   tatwo-device-sync.sh inventory-ingest
#     （拉通道後把對端 inventory/*.json 寫入本機 device-peer-inventory）
#   tatwo-device-sync.sh inventory-sync
#     （helper 每輪：publish + ingest；數值只來自對端實報，不填假值）
set -euo pipefail

# ---- 設定（env 可覆寫） ----
HERE="$(cd "$(dirname "$0")" && pwd)"
RELEASE_BRANCH="${TATWO_RELEASE_BRANCH:-release/tatwo-os}"
PRIMARY_SSH_HOST="${TATWO_PRIMARY_SSH_HOST:-}"
APP_SUPPORT="${TATWO_APP_SUPPORT:-$HOME/Library/Application Support/Tatwo Ultrawork}"
REMOTE_APP_SUPPORT="${TATWO_REMOTE_APP_SUPPORT:-$APP_SUPPORT}"
DEVICE_NAME="${TATWO_DEVICE_NAME:-$(hostname -s 2>/dev/null || echo device)}"
REPO="${TATWO_SYNC_REPO:-}"
# 信號通道：mini 發起、副設備輪詢的專用 git 分支（不污染程式碼歷史）
CHANNEL_BRANCH="${TATWO_CHANNEL_BRANCH:-device-sync-channel}"
CHANNEL_DIR="${TATWO_CHANNEL_DIR:-$APP_SUPPORT/device-sync-channel}"
CHANNEL_REMOTE="${TATWO_CHANNEL_REMOTE:-}"
ALLOW_LEGACY_CHANNEL_REMOTE="${TATWO_ALLOW_LEGACY_CHANNEL_REMOTE:-0}"
SYNC_CATALOG="${TATWO_SYNC_CATALOG:-$HERE/../config/tatwo-sync-catalog-v1.json}"
OS_ROOT="${TATWO_OS_ROOT:-$HOME/AI/TATWO OS}"
HOT_SYNC_STAGING="${TATWO_HOT_SYNC_STAGING:-$APP_SUPPORT/hot-sync-staging}"
HOT_SYNC_MIRROR="${TATWO_HOT_SYNC_MIRROR:-$APP_SUPPORT/hot-sync-mirror}"
SKILLET_STORE="${TATWO_SKILLET_STORE:-$APP_SUPPORT/skillet}"
# Live machines: never overwrite local skills or dump the skillet store into OS.
# Tests keep the old activate path unless they opt out.
if [ "${TATWO_TEST_MODE:-0}" = "1" ]; then
  SKILLET_APPLY="${TATWO_SKILLET_APPLY:-1}"
  SKILLET_LANE_PUBLISH="${TATWO_SKILLET_LANE_PUBLISH:-1}"
else
  SKILLET_APPLY="${TATWO_SKILLET_APPLY:-0}"
  SKILLET_LANE_PUBLISH="${TATWO_SKILLET_LANE_PUBLISH:-0}"
fi
SKILLET_RUNTIME_ROOT_EXPLICIT=0
[ "${TATWO_SKILLS_RUNTIME_ROOT+x}" = "x" ] \
  && [ -n "${TATWO_SKILLS_RUNTIME_ROOT:-}" ] \
  && SKILLET_RUNTIME_ROOT_EXPLICIT=1
SKILLET_RUNTIME_ROOT="${TATWO_SKILLS_RUNTIME_ROOT:-$APP_SUPPORT/skills-runtime}"
SKILLS_CONSUMER_ROOT_EXPLICIT=0
[ "${TATWO_SKILLS_CONSUMER_ROOT+x}" = "x" ] \
  && [ -n "${TATWO_SKILLS_CONSUMER_ROOT:-}" ] \
  && SKILLS_CONSUMER_ROOT_EXPLICIT=1
SKILLS_CONSUMER_ROOT="${TATWO_SKILLS_CONSUMER_ROOT:-$APP_SUPPORT/skills-consumer}"
CODEX_SKILLS_LINK_EXPLICIT=0
[ "${TATWO_CODEX_SKILLS_LINK+x}" = "x" ] \
  && [ -n "${TATWO_CODEX_SKILLS_LINK:-}" ] \
  && CODEX_SKILLS_LINK_EXPLICIT=1
CODEX_SKILLS_LINK="${TATWO_CODEX_SKILLS_LINK:-$HOME/.codex/skills}"
CLAUDE_SKILLS_LINK_EXPLICIT=0
[ "${TATWO_CLAUDE_SKILLS_LINK+x}" = "x" ] \
  && [ -n "${TATWO_CLAUDE_SKILLS_LINK:-}" ] \
  && CLAUDE_SKILLS_LINK_EXPLICIT=1
CLAUDE_SKILLS_LINK="${TATWO_CLAUDE_SKILLS_LINK:-$HOME/.claude/skills}"
SKILLS_CONSUMER_PROJECTION_SCRIPT_EXPLICIT=0
[ "${TATWO_SKILLS_CONSUMER_PROJECTION_SCRIPT+x}" = "x" ] \
  && [ -n "${TATWO_SKILLS_CONSUMER_PROJECTION_SCRIPT:-}" ] \
  && SKILLS_CONSUMER_PROJECTION_SCRIPT_EXPLICIT=1
SKILLS_CONSUMER_PROJECTION_SCRIPT="${TATWO_SKILLS_CONSUMER_PROJECTION_SCRIPT:-$HERE/tatwo-skills-consumer-projection.py}"
SKILLET_SOURCE_ROOT_EXPLICIT=0
if [ "${TATWO_SKILLET_SOURCE_ROOT+x}" = "x" ] \
  && [ -n "${TATWO_SKILLET_SOURCE_ROOT:-}" ]
then
  SKILLET_SOURCE_ROOT_EXPLICIT=1
elif [ "${TATWO_SKILLS_CANONICAL_DIR+x}" = "x" ] \
  && [ -n "${TATWO_SKILLS_CANONICAL_DIR:-}" ]
then
  SKILLET_SOURCE_ROOT_EXPLICIT=1
fi
SKILLET_SOURCE_ROOT="${TATWO_SKILLET_SOURCE_ROOT:-${TATWO_SKILLS_CANONICAL_DIR:-$APP_SUPPORT/skills}}"
LOOP_CHANNEL_ROOT="${TATWO_LOOP_CHANNEL_ROOT:-$HOME/tatwo-loop-channel}"
SKILLET_LANE_ROOT="$LOOP_CHANNEL_ROOT/skillet"
SKILLET_SOURCE_FALLBACK_ROOT="${TATWO_SKILLET_SOURCE_FALLBACK_ROOT:-$SKILLET_RUNTIME_ROOT}"
SKILLET_SOURCE_REGISTRY="${TATWO_SKILLET_SOURCE_REGISTRY:-$HERE/../config/tatwo-skillet-source-registry-v1.json}"
SKILLET_REFRESH_SCRIPT="${TATWO_SKILLET_REFRESH_SCRIPT:-$HERE/tatwo-skillet-refresh.mjs}"
SKILLET_AUTO_REFRESH="${TATWO_SKILLET_AUTO_REFRESH:-1}"
SKILLET_PYTHON="${TATWO_PYTHON3:-python3}"
DEVICE_TRUST_TEST_PYTHON="${TATWO_DEVICE_TRUST_TEST_PYTHON:-python3}"
SKILLET_CLI="${TATWO_SKILLET_CLI:-tatwo-ultrawork}"
DEVICE_TRUST_CLI_HINT="${TATWO_DEVICE_TRUST_CLI:-}"
DEVICE_TRUST_CLI_SHA256_HINT="${TATWO_DEVICE_TRUST_CLI_SHA256:-}"
DEVICE_TRUST_CLI_CDHASH_HINT="${TATWO_DEVICE_TRUST_CLI_CDHASH:-}"
DEVICE_TRUST_SIGNER="$APP_SUPPORT/device-trust/signer/tatwo-device-trust-signer-v1"
DEVICE_TRUST_SIGNER_PIN="$APP_SUPPORT/device-trust/signer-pin.json"
SYNC_SPACE_MARGIN_BYTES="${TATWO_SYNC_SPACE_MARGIN_BYTES:-67108864}"
SYNC_RETENTION_MAX_ENTRIES="${TATWO_SYNC_RETENTION_MAX_ENTRIES:-128}"
SYNC_RETENTION_MAX_BYTES="${TATWO_SYNC_RETENTION_MAX_BYTES:-2147483648}"
CHANNEL_LOCK_DIR="$APP_SUPPORT/device-sync-state/channel-operation.lock"
CHANNEL_LOCK_TIMEOUT_SECONDS="${TATWO_CHANNEL_LOCK_TIMEOUT_SECONDS:-120}"
CHANNEL_LOCK_OWNER_GRACE_SECONDS="${TATWO_CHANNEL_LOCK_OWNER_GRACE_SECONDS:-5}"
CHANNEL_LOCK_HELD=0
REQUEST_PAYLOAD_STAGE_ROOT=""
REQUEST_PAYLOAD_STAGE=""
SYSTEM_TRANSACTION_ROOT="$APP_SUPPORT/device-sync-state/system-transactions"
RETENTION_BUDGET_STATE="unknown"
SYNC_PROGRESS_ENABLED=0
SYNC_PROGRESS_STARTED_EPOCH=0
SYNC_PROGRESS_BASE_ELAPSED_MS=0
SYNC_PROGRESS_TOTAL_BYTES=0
SYNC_PROGRESS_PAYLOAD_BYTES=0
SYNC_PROGRESS_TOTAL_ITEMS=0
SYNC_PROGRESS_TOTAL_REPOSITORIES=0
SYNC_PROGRESS_COMPLETED_BYTES=0
SYNC_PROGRESS_COMPLETED_ITEMS=0
SYNC_PROGRESS_COMPLETED_REPOSITORIES=0
SYNC_PROGRESS_REQUEST_FILE=""
SYNC_PROGRESS_MANIFEST=""
SYNC_PROGRESS_ID=""
SYNC_PROGRESS_TARGET=""
SYNC_PROGRESS_ACTION=""
SYNC_PROGRESS_REQUESTED_AT=""
SYNC_PROGRESS_AUTHORITY_EPOCH=0
SYNC_PROGRESS_LEDGER_SEQUENCE=0
SYNC_PROGRESS_AUTHORITY_PRIMARY=""
SYNC_PROGRESS_SOURCE_DEVICE_ID=""
SYNC_PROGRESS_TARGET_DEVICE_ID=""
SYNC_PROGRESS_CATALOG_REVISION=""
SYNC_PROGRESS_DIGEST_ALGORITHM=""
SYNC_PROGRESS_SOURCE_DIGEST=""
SYNC_PROGRESS_SOURCE_MODE=""
SYNC_PROGRESS_INVENTORY_DIGEST=""
SYNC_PROGRESS_FALLBACK_AUTHORIZATION_ID=""
SYNC_PROGRESS_FALLBACK_AUTHORIZATION_PATH=""
SYNC_PROGRESS_FALLBACK_AUTHORIZATION_DIGEST=""
SKILLET_ACK_REPOSITORIES_JSON="[]"
SKILLET_TARGET_PRESERVED_COUNT=0
SKILLET_TARGET_PRESERVED_REPOSITORIES_JSON="[]"
SKILLET_TARGET_PRESERVED_RUNTIME_CLOSURE_CAPABILITY=""
SKILLET_TARGET_PRESERVED_RUNTIME_CLOSED=false
SKILLET_SOURCE_MODE=""
SKILLET_INVENTORY_DIGEST=""
SKILLET_FALLBACK_AUTHORIZATION_ID=""
SKILLET_FALLBACK_AUTHORIZATION_PATH=""
SKILLET_FALLBACK_AUTHORIZATION_DIGEST=""
SKILLET_REFRESH_ATTEMPT_ID=""
SKILLET_REFRESH_TARGET=""
SKILLET_REFRESH_REQUESTED_AT=""
SKILLET_REFRESH_AUTHORITY_EPOCH=0
SKILLET_REFRESH_LEDGER_SEQUENCE=0
SKILLET_REFRESH_AUTHORITY_PRIMARY=""
SKILLET_REFRESH_SOURCE_DEVICE_ID=""
SKILLET_REFRESH_TARGET_DEVICE_ID=""
SKILLET_REFRESH_CATALOG_REVISION=""
SKILLET_REFRESH_CURRENT_DEVICE_ID=""
SKILLET_MERGE_PROPOSAL_COUNT=0
SKILLET_BRANCH_PRESERVED_COUNT=0
SKILLET_MERGE_PROPOSAL_IDS_JSON="[]"
SKILLET_MERGE_RECEIPT_PATH=""
TARGET_CONSUMER_READBACK_KIND=""
TARGET_CONSUMER_READBACK_PATH=""
TARGET_CONSUMER_READBACK_DIGEST=""
TARGET_CONSUMER_READBACK_COUNT=0
# Every channel artifact that can be staged before the terminal ACK must be
# recovered through the same evidence-preserving path. Add future receipt
# directories here before they are allowed to participate in channel writes.
CHANNEL_ATOMIC_ARTIFACT_DIRS=(requests acks attestations consumer-readbacks signatures)

# 舊 db-pull 僅保留已明確 catalog 化的 goal state；Attachments 與 vendor-native
# sessions 不得繞過 catalog 進入熱同步。完整 durable state 改由 manifest engine 漸進接管。
DB_ALLOWLIST=(state/goals)

log()  { printf '%s • %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die()  { printf 'ERROR • %s\n' "$*" >&2; exit 1; }

paths_lexically_equal() {
  local left="$1" right="$2"
  "$SKILLET_PYTHON" - "$left" "$right" <<'PY' >/dev/null 2>&1
import os
import sys

raise SystemExit(0 if os.path.normpath(sys.argv[1]) == os.path.normpath(sys.argv[2]) else 1)
PY
}

require_explicit_skillet_runtime_root() {
  if [ "$SKILLET_RUNTIME_ROOT_EXPLICIT" != "1" ]; then
    log "Skillet helper 仍是舊版 runtime 設定；請重新執行設備納管"
    return 1
  fi
  case "$SKILLET_RUNTIME_ROOT" in
    /*) return 0;;
    *)
      log "Skillet runtime root 必須是設備納管時寫入的絕對路徑；請重新執行設備納管"
      return 1
      ;;
  esac
}

require_explicit_skills_consumer_projection() {
  if [ "$SKILLS_CONSUMER_ROOT_EXPLICIT" != "1" ] \
    || [ "$CODEX_SKILLS_LINK_EXPLICIT" != "1" ] \
    || [ "$CLAUDE_SKILLS_LINK_EXPLICIT" != "1" ] \
    || [ "$SKILLS_CONSUMER_PROJECTION_SCRIPT_EXPLICIT" != "1" ]
  then
    log "Skills consumer projection／Codex／Claude 原生 skills 路徑仍是舊版設定；請重新執行設備納管"
    return 1
  fi
  case "$SKILLS_CONSUMER_ROOT" in
    /*) ;;
    *)
      log "TATWO_SKILLS_CONSUMER_ROOT 必須是設備納管時寫入的絕對路徑；請重新執行設備納管"
      return 1
      ;;
  esac
  case "$CODEX_SKILLS_LINK" in
    /*) ;;
    *)
      log "TATWO_CODEX_SKILLS_LINK 必須是設備納管時寫入的絕對路徑；請重新執行設備納管"
      return 1
      ;;
  esac
  case "$CLAUDE_SKILLS_LINK" in
    /*) ;;
    *)
      log "TATWO_CLAUDE_SKILLS_LINK 必須是設備納管時寫入的絕對路徑；請重新執行設備納管"
      return 1
      ;;
  esac
  case "$SKILLS_CONSUMER_PROJECTION_SCRIPT" in
    /*) ;;
    *)
      log "TATWO_SKILLS_CONSUMER_PROJECTION_SCRIPT 必須是設備納管時寫入的絕對路徑；請重新執行設備納管"
      return 1
      ;;
  esac
  [ -f "$SKILLS_CONSUMER_PROJECTION_SCRIPT" ] \
    && [ ! -L "$SKILLS_CONSUMER_PROJECTION_SCRIPT" ] \
    || {
      log "Skills consumer projection script 不存在或不是 regular file；請重新執行設備納管"
      return 1
    }
  command -v "$SKILLET_PYTHON" >/dev/null 2>&1 \
    && "$SKILLET_PYTHON" -c 'import fcntl, json, os' >/dev/null 2>&1 \
    || {
      log "Skills consumer projection 需要設備納管時驗證過的 python3/fcntl"
      return 1
    }
  local projection_preflight_error=""
  if ! projection_preflight_error="$(
    "$SKILLET_PYTHON" - \
      "$SKILLS_CONSUMER_ROOT" "$CODEX_SKILLS_LINK" "$CLAUDE_SKILLS_LINK" <<'PY'
import os
import stat
import sys

consumer_root, codex_link, claude_link = map(os.path.normpath, sys.argv[1:4])
current_link = os.path.join(consumer_root, "current")

def fail(message):
    raise SystemExit(message)

def normalized_target(path):
    target = os.readlink(path)
    if os.path.isabs(target):
        return os.path.normpath(target)
    return os.path.normpath(os.path.join(os.path.dirname(path), target))

if codex_link == claude_link:
    fail("Codex and Claude native skills entrypoints are identical")
if not os.path.isdir(consumer_root) or os.path.islink(consumer_root):
    fail("consumer root is missing or not a real directory")
if not os.path.islink(current_link):
    fail("managed current is missing or not a symlink")
if not os.path.isdir(os.path.realpath(current_link)):
    fail("managed current does not resolve to a directory")
for consumer_id, link in (
    ("codex.native-skills", codex_link),
    ("claude.native-skills", claude_link),
):
    if not os.path.islink(link):
        fail(f"{consumer_id} entrypoint is missing or not a symlink")
    if normalized_target(link) != current_link:
        fail(f"{consumer_id} drifted from managed current")
    if os.path.realpath(link) != os.path.realpath(current_link):
        fail(f"{consumer_id} does not resolve through managed current")
PY
  )"
  then
    projection_preflight_error="${projection_preflight_error//$HOME/\$HOME}"
    projection_preflight_error="${projection_preflight_error//$APP_SUPPORT/\$TATWO_APP_SUPPORT}"
    log "Skills consumer projection bootstrap 不完整：${projection_preflight_error:-unknown failure}；請重新執行設備納管"
    return 1
  fi
}

require_system_runtime_enrollment() {
  require_explicit_skillet_runtime_root \
    && require_explicit_skills_consumer_projection
}

channel_lock_owner_file() {
  printf '%s\n' "$CHANNEL_LOCK_DIR/owner"
}

channel_lock_release() {
  [ "$CHANNEL_LOCK_HELD" = "1" ] || return 0
  local owner_file
  owner_file="$(channel_lock_owner_file)"
  if [ -f "$owner_file" ] && [ "$(sed -n '1p' "$owner_file" 2>/dev/null || true)" = "$$" ]; then
    rm -f "$owner_file"
    rmdir "$CHANNEL_LOCK_DIR" 2>/dev/null || true
  fi
  CHANNEL_LOCK_HELD=0
}

request_payload_stage_cleanup() {
  [ -n "$REQUEST_PAYLOAD_STAGE" ] || return 0
  case "$REQUEST_PAYLOAD_STAGE" in
    "$REQUEST_PAYLOAD_STAGE_ROOT"/*)
      [ -d "$REQUEST_PAYLOAD_STAGE" ] \
        && rm -r "$REQUEST_PAYLOAD_STAGE" 2>/dev/null || true
      ;;
  esac
  REQUEST_PAYLOAD_STAGE=""
}

channel_operation_cleanup() {
  request_payload_stage_cleanup
  channel_lock_release
}

channel_lock_archive_stale() {
  local stale_root stale_destination
  stale_root="$APP_SUPPORT/device-sync-state/stale-channel-locks"
  stale_destination="$stale_root/$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
  mkdir -p "$stale_root"
  mv "$CHANNEL_LOCK_DIR" "$stale_destination" 2>/dev/null
}

channel_lock_age_seconds() {
  local modified_at now
  modified_at="$(stat -f '%m' "$CHANNEL_LOCK_DIR" 2>/dev/null)" || return 1
  now="$(date +%s)"
  case "$modified_at" in
    ""|*[!0-9]*) return 1;;
  esac
  if [ "$modified_at" -ge "$now" ]; then
    printf '0\n'
  else
    printf '%s\n' "$((now - modified_at))"
  fi
}

channel_lock_acquire() {
  case "$CHANNEL_LOCK_TIMEOUT_SECONDS" in
    ""|*[!0-9]*) die "TATWO_CHANNEL_LOCK_TIMEOUT_SECONDS 必須是非負整數";;
  esac
  case "$CHANNEL_LOCK_OWNER_GRACE_SECONDS" in
    ""|*[!0-9]*) die "TATWO_CHANNEL_LOCK_OWNER_GRACE_SECONDS 必須是非負整數";;
  esac
  mkdir -p "$(dirname "$CHANNEL_LOCK_DIR")"
  local started_at now owner_pid owner_file lock_age
  started_at="$(date +%s)"
  owner_file="$(channel_lock_owner_file)"
  while true; do
    if mkdir "$CHANNEL_LOCK_DIR" 2>/dev/null; then
      if [ "${TATWO_TEST_MODE:-0}" = "1" ] \
        && [ "${TATWO_TEST_CHANNEL_LOCK_OWNER_DELAY_SECONDS:-0}" != "0" ]
      then
        sleep "$TATWO_TEST_CHANNEL_LOCK_OWNER_DELAY_SECONDS"
      fi
      {
        printf '%s\n' "$$"
        printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '%s\n' "$CHANNEL_DIR"
      } >"$owner_file"
      CHANNEL_LOCK_HELD=1
      trap 'channel_operation_cleanup' EXIT
      trap 'exit 129' HUP
      trap 'exit 130' INT
      trap 'exit 143' TERM
      if [ "${TATWO_TEST_MODE:-0}" = "1" ] \
        && [ "${TATWO_TEST_CHANNEL_LOCK_HOLD_SECONDS:-0}" != "0" ]
      then
        sleep "$TATWO_TEST_CHANNEL_LOCK_HOLD_SECONDS"
      fi
      return 0
    fi

    owner_pid="$(sed -n '1p' "$owner_file" 2>/dev/null || true)"
    case "$owner_pid" in
      ""|*[!0-9]*)
        lock_age="$(channel_lock_age_seconds 2>/dev/null || printf '0\n')"
        if [ "$lock_age" -ge "$CHANNEL_LOCK_OWNER_GRACE_SECONDS" ]; then
          owner_pid="$(sed -n '1p' "$owner_file" 2>/dev/null || true)"
          case "$owner_pid" in
            ""|*[!0-9]*) channel_lock_archive_stale || true;;
          esac
        fi
        ;;
      *)
        if ! kill -0 "$owner_pid" 2>/dev/null; then
          channel_lock_archive_stale || true
        fi
        ;;
    esac

    now="$(date +%s)"
    if [ $((now - started_at)) -ge "$CHANNEL_LOCK_TIMEOUT_SECONDS" ]; then
      die "本機已有另一個同步通道操作進行中；拒絕並行修改 request/ACK/authority"
    fi
    sleep 0.1
  done
}

resolve_repo() {
  if [ -n "$REPO" ]; then echo "$REPO"; return; fi
  git rev-parse --show-toplevel 2>/dev/null || die "找不到 git repo（設 TATWO_SYNC_REPO 或在 repo 內執行）"
}

cmd_version_status() {
  local repo; repo="$(resolve_repo)"
  git -C "$repo" fetch origin "$RELEASE_BRANCH" >/dev/null 2>&1 || log "warn: fetch 失敗（離線？）用本機快取比對"
  local head rel ahead behind
  head="$(git -C "$repo" rev-parse --short HEAD)"
  rel="$(git -C "$repo" rev-parse --short "origin/$RELEASE_BRANCH" 2>/dev/null || echo unknown)"
  ahead="$(git -C "$repo" rev-list --count "origin/$RELEASE_BRANCH..HEAD" 2>/dev/null || echo '?')"
  behind="$(git -C "$repo" rev-list --count "HEAD..origin/$RELEASE_BRANCH" 2>/dev/null || echo '?')"
  log "device=$DEVICE_NAME head=$head release=$rel ahead=$ahead behind=$behind"
  if [ "$behind" != "0" ] && [ "$behind" != "?" ]; then
    log "→ 有 $behind 個新 commit 可拉：tatwo-device-sync.sh version-pull"
  fi
  if [ "$ahead" != "0" ] && [ "$ahead" != "?" ]; then
    log "→ 本機領先 $ahead 個 commit（可回傳）：tatwo-device-sync.sh version-push"
  fi
  if [ "$ahead" = "0" ] && [ "$behind" = "0" ]; then log "→ 已同版，無需動作"; fi
}

cmd_version_push() {
  local repo device msg
  repo="$(resolve_repo)"; device="$DEVICE_NAME"; msg=""
  while [ $# -gt 0 ]; do case "$1" in
    --device) device="$2"; shift 2;;
    --message) msg="$2"; shift 2;;
    *) die "未知參數 $1";; esac; done
  [ -z "$msg" ] && msg="$device: 本機版本回傳 $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local branch="dev/${device}"
  [ "$branch" = "$RELEASE_BRANCH" ] && die "拒絕：dev 分支不可等於 release"
  case "$branch" in main|master|"release/"*) die "拒絕推到受保護分支 $branch";; esac
  local status
  status="$(GIT_OPTIONAL_LOCKS=0 git -C "$repo" status --porcelain --untracked-files=all)" \
    || die "無法檢查工作樹，拒絕推送"
  [ -z "$status" ] || die "工作樹有未提交改動，請先提交或暫存"
  log "無未提交改動，直接推目前 HEAD 到 $branch"
  git -C "$repo" push origin "HEAD:refs/heads/$branch"
  log "已推 ${branch}（commit $(git -C "$repo" rev-parse --short HEAD)）→ 等主設備整合進 $RELEASE_BRANCH"
}

cmd_version_pull() {
  local repo install=1 expected_digest=""
  if [ "${TATWO_OS_IMAGE_CONSUMER:-0}" = "1" ]; then
    image_script="${TATWO_OS_IMAGE_SCRIPT:-$HERE/tatwo-os-image.sh}"
    bash "$image_script" sync
    return $?
  fi
  repo="$(resolve_repo)"
  while [ $# -gt 0 ]; do case "$1" in
    --no-install) install=0; shift;;
    --expected-digest) expected_digest="${2:-}"; shift 2;;
    *) die "未知參數 $1";;
  esac; done
  if [ -n "$expected_digest" ]; then
    is_git_object_id "$expected_digest" \
      || die "version-pull expected digest 格式不合法"
  fi
  local current_branch
  current_branch="$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  [ "$current_branch" = "$RELEASE_BRANCH" ] \
    || die "version-pull 只允許在 $RELEASE_BRANCH 執行；目前=${current_branch:-detached}"
  [ -z "$(git -C "$repo" status --porcelain=v1 --untracked-files=all)" ] \
    || die "version-pull 拒絕修改 dirty checkout；請先保存或整合本機變更"
  git -C "$repo" fetch origin "$RELEASE_BRANCH" || die "fetch 失敗"
  local before after target_revision
  before="$(git -C "$repo" rev-parse HEAD)"
  target_revision="${expected_digest:-origin/$RELEASE_BRANCH}"
  git -C "$repo" cat-file -e "${target_revision}^{commit}" 2>/dev/null \
    || die "找不到 request 綁定的來源版本：$target_revision"
  # 只允許 fast-forward；分岔則停手交給人整合，不盲合
  if git -C "$repo" merge-base --is-ancestor HEAD "$target_revision"; then
    git -C "$repo" merge --ff-only "$target_revision"
  else
    die "本機與 request 綁定版本分岔或已超前，拒絕 last-write-wins。請回傳分支後重新發 request。"
  fi
  after="$(git -C "$repo" rev-parse HEAD)"
  if [ -n "$expected_digest" ] && [ "$after" != "$expected_digest" ]; then
    die "version-pull 套用結果未等於 request source digest"
  fi
  if [ "$before" = "$after" ]; then log "已是最新，無新版可裝"; return; fi
  log "已更新 $(git -C "$repo" rev-parse --short "$before") → $(git -C "$repo" rev-parse --short "$after")"
  if [ "$install" = "1" ]; then
    log "跑本機安裝（build + ad-hoc + 備份舊版）…"
    bash "$repo/scripts/tatwo-install-local-app.sh"
  else
    log "略過安裝（--no-install）"
  fi
}

cmd_db_pull() {
  local from="$PRIMARY_SSH_HOST" dry=0
  while [ $# -gt 0 ]; do case "$1" in
    --from) from="$2"; shift 2;;
    --dry-run) dry=1; shift;;
    *) die "未知參數 $1";; esac; done
  [ -n "$from" ] || { echo "請設定 TATWO_PRIMARY_SSH_HOST" >&2; exit 2; }
  command -v rsync >/dev/null || die "缺 rsync"
  [ -d "$APP_SUPPORT" ] || die "找不到本機 app-support：$APP_SUPPORT"

  # 先驗證能連到主設備（唯讀）
  if ! ssh -o ConnectTimeout=8 -o BatchMode=yes "$from" "test -d \"$REMOTE_APP_SUPPORT\"" 2>/dev/null; then
    die "連不到主設備 $from 或遠端 app-support 不存在（tunnel 未通 / 未授權 / 路徑不符）"
  fi

  local ts backup_root; ts="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_root="$APP_SUPPORT/db-sync-backups/$ts"
  local rsync_flags=(-az --delete --human-readable)
  [ "$dry" = "1" ] && rsync_flags+=(--dry-run) && log "== DRY-RUN（不實際寫入）=="

  for sub in "${DB_ALLOWLIST[@]}"; do
    local remote_dir="$REMOTE_APP_SUPPORT/$sub/" local_dir="$APP_SUPPORT/$sub/"
    # 遠端該子項不存在就跳過
    if ! ssh -o ConnectTimeout=8 -o BatchMode=yes "$from" "test -e \"$REMOTE_APP_SUPPORT/$sub\"" 2>/dev/null; then
      log "skip（主設備無此項）：$sub"; continue
    fi
    if [ "$dry" != "1" ] && [ -e "$local_dir" ]; then
      mkdir -p "$backup_root/$(dirname "$sub")"
      cp -R "$APP_SUPPORT/$sub" "$backup_root/$sub"
      log "已備份本機 $sub → $backup_root/$sub"
    fi
    mkdir -p "$local_dir"
    log "索取（主→副 鏡像）：$sub"
    # 遠端路徑含空格（"Application Support"/"Tatwo Ultrawork"）：rsync 的
    # host:path 語法會把 path 原樣交給遠端 shell 解析，沒有再包一層引號
    # 會被空格拆成多個字，遠端誤判找不到檔案。用 rsync 的路徑跳脫語法
    # （反斜線跳脫空格）確保遠端 shell 收到單一參數。
    local escaped_remote_dir="${remote_dir// /\\ }"
    rsync "${rsync_flags[@]}" -e "ssh -o ConnectTimeout=10 -o BatchMode=yes" \
      "$from:$escaped_remote_dir" "$local_dir"
  done
  if [ "$dry" = "1" ]; then
    log "DRY-RUN 完成（以上是會發生的變更；未寫入）"
  else
    log "資料庫已同步（主→副）。本機原資料備份在 ${backup_root}（可還原）"
  fi
}

# ---- 信號通道（mini 發起 / 副設備輪詢）----
newid() { printf '%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$(uuidgen 2>/dev/null | cut -c1-8 || echo $RANDOM)"; }

json_get() {  # json_get <file> <key>  → 取 "key":"value" 的 value（僅字串值）
  plutil -extract "$2" raw "$1" 2>/dev/null \
    || grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" 2>/dev/null \
      | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//' \
    || true
}

json_number_get() {  # json_number_get <file> <key> → 取非負整數
  plutil -extract "$2" raw "$1" 2>/dev/null \
    || grep -o "\"$2\"[[:space:]]*:[[:space:]]*[0-9][0-9]*" "$1" 2>/dev/null \
      | head -1 | sed 's/.*:[[:space:]]*//' \
    || true
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

recorded_absolute_path() {
  local file="$1" key="$2" value
  value="$(json_get "$file" "$key")"
  case "$value" in
    /*)
      case "$value" in
        *$'\n'*|*$'\r'*|*$'\t'*) return 1;;
      esac
      printf '%s\n' "$value"
      ;;
    *) return 1;;
  esac
}

validate_device_name() {
  case "$1" in
    ""|*[!A-Za-z0-9._-]*) die "設備名稱只允許 A-Z a-z 0-9 . _ -";;
  esac
}

validate_device_role() {
  case "$1" in
    primary|secondary) ;;
    *) die "role 需為 primary|secondary";;
  esac
}

validate_ssh_host() {
  case "$1" in
    ""|*$'\n'*|*$'\r'*|*$'\t'*|*" "*|*[!A-Za-z0-9._:@%+=,-]*)
      die "ssh host 含有不安全字元"
      ;;
  esac
}

validate_epoch() {
  case "$1" in ""|*[!0-9]*) die "epoch 必須是非負整數";; esac
}

sha256_file() {
  if [ "${TATWO_TEST_MODE:-0}" = "1" ] \
    && [ -n "${TATWO_TEST_SHA256_FAIL_PATH:-}" ] \
    && [ "$1" = "$TATWO_TEST_SHA256_FAIL_PATH" ]
  then
    log "測試注入：SHA-256 讀取失敗 path=$1" >&2
    return 1
  fi
  shasum -a 256 "$1" | awk '{print $1}'
}

is_sha256_digest() {
  [ "${#1}" -eq 64 ] || return 1
  case "$1" in ""|*[!0-9a-f]*) return 1;; esac
}

consumer_loaded_revision_matches() {
  local source_item_id="$1" loaded_digest="$2" loaded_revision="$3"
  is_sha256_digest "$loaded_digest" || return 1
  case "$source_item_id" in
    os.constitution|os.issue|os.todo)
      [ "$loaded_revision" = "sha256-$loaded_digest" ]
      ;;
    skills.skillet)
      [ "$loaded_revision" = "rev-$loaded_digest" ]
      ;;
    *)
      return 1
      ;;
  esac
}

is_merge_proposal_id() {  # merge- + 64 位小寫 hex；長度與前綴都不足以當作驗證
  case "$1" in merge-*) ;; *) return 1;; esac
  is_sha256_digest "${1#merge-}"
}

is_git_object_id() {
  case "${#1}" in 40|64) ;; *) return 1;; esac
  case "$1" in ""|*[!0-9a-f]*) return 1;; esac
}

file_byte_count() {
  stat -f '%z' "$1" 2>/dev/null || wc -c <"$1" | tr -d ' '
}

directory_file_bytes() {
  local root="$1"
  [ -d "$root" ] || { printf '0\n'; return; }
  find "$root" -type f -print0 2>/dev/null \
    | while IFS= read -r -d '' file; do
        file_byte_count "$file"
      done \
    | awk '{ total += $1 } END { printf "%.0f\n", total + 0 }'
}

validate_nonnegative_integer() {
  case "$1" in ""|*[!0-9]*) return 1;; esac
}

validate_nonnegative_number() {
  case "$1" in
    ""|*[!0-9.]*|*.*.*|.) return 1;;
  esac
}

sync_ack_phase_rank() {
  case "$1" in
    accepted) printf '10\n';;
    transferring) printf '20\n';;
    merging) printf '30\n';;
    validating) printf '40\n';;
    activating) printf '50\n';;
    verified) printf '60\n';;
    converged) printf '70\n';;
    failed|diverged) printf '80\n';;
    *) return 1;;
  esac
}

sync_ack_phase_is_terminal() {
  case "$1" in converged|failed|diverged) return 0;; *) return 1;; esac
}

validate_sync_progress_payload() {
  local file="$1" prefix="$2" phase="$3"
  local completed_bytes total_bytes completed_items total_items
  local completed_repositories total_repositories elapsed throughput current_item
  completed_bytes="$(plutil -extract "$prefix.completedBytes" raw "$file" 2>/dev/null || true)"
  total_bytes="$(plutil -extract "$prefix.totalBytes" raw "$file" 2>/dev/null || true)"
  completed_items="$(plutil -extract "$prefix.completedItems" raw "$file" 2>/dev/null || true)"
  total_items="$(plutil -extract "$prefix.totalItems" raw "$file" 2>/dev/null || true)"
  completed_repositories="$(plutil -extract "$prefix.completedRepositories" raw "$file" 2>/dev/null || true)"
  total_repositories="$(plutil -extract "$prefix.totalRepositories" raw "$file" 2>/dev/null || true)"
  elapsed="$(plutil -extract "$prefix.elapsedMilliseconds" raw "$file" 2>/dev/null || true)"
  throughput="$(plutil -extract "$prefix.throughputBytesPerSecond" raw "$file" 2>/dev/null || true)"
  current_item="$(plutil -extract "$prefix.currentItem" raw "$file" 2>/dev/null || true)"

  validate_nonnegative_integer "$completed_bytes" \
    && validate_nonnegative_integer "$total_bytes" \
    && validate_nonnegative_integer "$completed_items" \
    && validate_nonnegative_integer "$total_items" \
    && validate_nonnegative_integer "$completed_repositories" \
    && validate_nonnegative_integer "$total_repositories" \
    && validate_nonnegative_integer "$elapsed" \
    && validate_nonnegative_number "$throughput" \
    || return 1
  [ "$total_bytes" -gt 0 ] \
    && [ "$total_items" -gt 0 ] \
    && [ "$completed_bytes" -le "$total_bytes" ] \
    && [ "$completed_items" -le "$total_items" ] \
    && [ "$completed_repositories" -le "$total_repositories" ] \
    || return 1
  case "$current_item" in ""|*$'\n'*|*$'\r'*|*$'\t'*) return 1;; esac

  case "$phase" in
    converged|verified)
      [ "$completed_bytes" = "$total_bytes" ] \
        && [ "$completed_items" = "$total_items" ] \
        && [ "$completed_repositories" = "$total_repositories" ] \
        || return 1
      ;;
    accepted|transferring|merging|validating|activating)
      if [ "$completed_bytes" = "$total_bytes" ] \
        && [ "$completed_items" = "$total_items" ] \
        && [ "$completed_repositories" = "$total_repositories" ]
      then
        return 1
      fi
      ;;
    failed|diverged) ;;
    *) return 1;;
  esac
}

sync_progress_payload_is_monotonic() {
  local previous="$1" next="$2"
  local key previous_value next_value
  for key in completedBytes completedItems completedRepositories elapsedMilliseconds; do
    previous_value="$(plutil -extract "progress.$key" raw "$previous" 2>/dev/null || true)"
    next_value="$(plutil -extract "progress.$key" raw "$next" 2>/dev/null || true)"
    validate_nonnegative_integer "$previous_value" \
      && validate_nonnegative_integer "$next_value" \
      && [ "$next_value" -ge "$previous_value" ] \
      || return 1
  done
  for key in totalBytes totalItems totalRepositories; do
    previous_value="$(plutil -extract "progress.$key" raw "$previous" 2>/dev/null || true)"
    next_value="$(plutil -extract "progress.$key" raw "$next" 2>/dev/null || true)"
    [ "$next_value" = "$previous_value" ] || return 1
  done
}

existing_path_ancestor() {
  local path="$1"
  while [ ! -e "$path" ]; do
    [ "$path" != "/" ] || break
    path="$(dirname "$path")"
  done
  [ -e "$path" ] || return 1
  printf '%s\n' "$path"
}

filesystem_device_id() {
  local path
  path="$(existing_path_ancestor "$1")" || return 1
  stat -f '%d' "$path" 2>/dev/null
}

filesystem_type() {
  local path
  path="$(existing_path_ancestor "$1")" || return 1
  stat -f '%T' "$path" 2>/dev/null
}

same_filesystem() {
  local left right
  left="$(filesystem_device_id "$1")" || return 1
  right="$(filesystem_device_id "$2")" || return 1
  [ "$left" = "$right" ]
}

directory_allocated_bytes() {
  [ -e "$1" ] || { printf '0\n'; return; }
  local kib
  kib="$(du -sk "$1" 2>/dev/null | awk 'NR == 1 {print $1}')"
  validate_nonnegative_integer "$kib" || return 1
  printf '%s\n' "$((kib * 1024))"
}

available_bytes_for_path() {
  if [ -n "${TATWO_TEST_AVAILABLE_BYTES_OVERRIDE:-}" ]; then
    validate_nonnegative_integer "$TATWO_TEST_AVAILABLE_BYTES_OVERRIDE" || return 1
    printf '%s\n' "$TATWO_TEST_AVAILABLE_BYTES_OVERRIDE"
    return
  fi
  local path available_kib
  path="$(existing_path_ancestor "$1")" || return 1
  available_kib="$(df -Pk "$path" 2>/dev/null | awk 'END {print $4}')"
  validate_nonnegative_integer "$available_kib" || return 1
  printf '%s\n' "$((available_kib * 1024))"
}

require_available_space() {
  local path="$1" required_bytes="$2" label="$3"
  validate_nonnegative_integer "$required_bytes" || return 1
  validate_nonnegative_integer "$SYNC_SPACE_MARGIN_BYTES" \
    || { log "TATWO_SYNC_SPACE_MARGIN_BYTES 必須是非負整數"; return 1; }
  local available total_required
  available="$(available_bytes_for_path "$path")" || return 1
  total_required=$((required_bytes + SYNC_SPACE_MARGIN_BYTES))
  if [ "$available" -lt "$total_required" ]; then
    log "disk budget 不足：$label required=${total_required}B available=${available}B path=$path"
    return 1
  fi
}

clone_copy_supported() {
  same_filesystem "$1" "$2" || return 1
  [ "$(filesystem_type "$1")" = "apfs" ]
}

copy_directory_snapshot() {
  local source="$1" destination="$2"
  local parent base stage
  [ -d "$source" ] || return 1
  [ ! -e "$destination" ] || return 1
  parent="$(dirname "$destination")"
  base="$(basename "$destination")"
  mkdir -p "$parent" || return 1
  stage="$parent/.${base}.copying-$$-$RANDOM"
  if clone_copy_supported "$source" "$parent"; then
    cp -cR "$source" "$stage" || return 1
  else
    cp -R "$source" "$stage" || return 1
  fi
  mv "$stage" "$destination"
}

archive_on_same_volume() {
  local source="$1" archive_root="$2" label="$3"
  [ -e "$source" ] || return 0
  mkdir -p "$archive_root" || return 1
  same_filesystem "$source" "$archive_root" \
    || { log "拒絕跨 volume mv archive：$label"; return 1; }
  mv "$source" "$archive_root/$label-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
}

RETENTION_VOLUME_DEVICES=()
RETENTION_VOLUME_MOUNTS=()
RETENTION_VOLUME_ENTRIES=()
RETENTION_VOLUME_HISTORICAL_ENTRIES=()
RETENTION_VOLUME_BYTES=()
RETENTION_VOLUME_LABELS=()
RETENTION_VOLUME_HISTORICAL_LABELS=()
RETENTION_TRACKED_PATHS=()

filesystem_mount_point() {
  local path
  path="$(existing_path_ancestor "$1")" || return 1
  df -P "$path" 2>/dev/null \
    | awk '
        NR == 2 {
          for (field = 6; field <= NF; field += 1) {
            printf "%s%s", $field, (field < NF ? " " : "\n")
          }
          found = 1
        }
        END { exit(found ? 0 : 1) }
      '
}

retention_reset() {
  RETENTION_VOLUME_DEVICES=()
  RETENTION_VOLUME_MOUNTS=()
  RETENTION_VOLUME_ENTRIES=()
  RETENTION_VOLUME_HISTORICAL_ENTRIES=()
  RETENTION_VOLUME_BYTES=()
  RETENTION_VOLUME_LABELS=()
  RETENTION_VOLUME_HISTORICAL_LABELS=()
  RETENTION_TRACKED_PATHS=()
}

retention_entry_count() {
  local path="$1" count_mode="$2"
  case "$count_mode" in
    self)
      printf '1\n'
      ;;
    files)
      find "$path" -type f -print 2>/dev/null | wc -l | tr -d ' '
      ;;
    children)
      find "$path" -mindepth 1 -maxdepth 1 -print 2>/dev/null | wc -l | tr -d ' '
      ;;
    *)
      return 1
      ;;
  esac
}

retention_add_path() {
  local path="$1" label="$2" count_mode="${3:-children}"
  local budget_class="${4:-active}"
  case "$budget_class" in
    active|historical) ;;
    *) return 1;;
  esac
  [ -e "$path" ] || return 0
  local tracked
  if [ "${#RETENTION_TRACKED_PATHS[@]}" -gt 0 ]; then
    for tracked in "${RETENTION_TRACKED_PATHS[@]}"; do
      [ "$tracked" = "$path" ] && return 0
    done
  fi
  RETENTION_TRACKED_PATHS+=("$path")

  local device mount entry_count allocated_bytes index=0
  device="$(filesystem_device_id "$path")" || return 1
  mount="$(filesystem_mount_point "$path")" || return 1
  entry_count="$(retention_entry_count "$path" "$count_mode")" || return 1
  allocated_bytes="$(directory_allocated_bytes "$path")" || return 1
  validate_nonnegative_integer "$entry_count" \
    && validate_nonnegative_integer "$allocated_bytes" \
    || return 1
  while [ "$index" -lt "${#RETENTION_VOLUME_DEVICES[@]}" ]; do
    if [ "${RETENTION_VOLUME_DEVICES[$index]}" = "$device" ]; then
      if [ "$budget_class" = "historical" ]; then
        RETENTION_VOLUME_HISTORICAL_ENTRIES[$index]=$((
          ${RETENTION_VOLUME_HISTORICAL_ENTRIES[$index]} + entry_count
        ))
        RETENTION_VOLUME_HISTORICAL_LABELS[$index]="${RETENTION_VOLUME_HISTORICAL_LABELS[$index]}, $label"
      else
        RETENTION_VOLUME_ENTRIES[$index]=$((
          ${RETENTION_VOLUME_ENTRIES[$index]} + entry_count
        ))
        RETENTION_VOLUME_LABELS[$index]="${RETENTION_VOLUME_LABELS[$index]}, $label"
      fi
      RETENTION_VOLUME_BYTES[$index]=$((
        ${RETENTION_VOLUME_BYTES[$index]} + allocated_bytes
      ))
      return 0
    fi
    index=$((index + 1))
  done
  RETENTION_VOLUME_DEVICES+=("$device")
  RETENTION_VOLUME_MOUNTS+=("$mount")
  if [ "$budget_class" = "historical" ]; then
    RETENTION_VOLUME_ENTRIES+=("0")
    RETENTION_VOLUME_HISTORICAL_ENTRIES+=("$entry_count")
    RETENTION_VOLUME_LABELS+=("")
    RETENTION_VOLUME_HISTORICAL_LABELS+=("$label")
  else
    RETENTION_VOLUME_ENTRIES+=("$entry_count")
    RETENTION_VOLUME_HISTORICAL_ENTRIES+=("0")
    RETENTION_VOLUME_LABELS+=("$label")
    RETENTION_VOLUME_HISTORICAL_LABELS+=("")
  fi
  RETENTION_VOLUME_BYTES+=("$allocated_bytes")
}

retention_add_glob() {
  local pattern="$1" label="$2" budget_class="${3:-active}" path
  while IFS= read -r path; do
    [ -e "$path" ] || continue
    retention_add_path "$path" "$label" self "$budget_class" || return 1
  done < <(compgen -G "$pattern" || true)
}

retention_budget_status() {
  validate_nonnegative_integer "$SYNC_RETENTION_MAX_ENTRIES" \
    && validate_nonnegative_integer "$SYNC_RETENTION_MAX_BYTES" \
    || { log "retention limits 必須是非負整數"; return 1; }
  retention_reset
  retention_add_path "$SYSTEM_TRANSACTION_ROOT" "active system transactions" children || return 1
  retention_add_path "$APP_SUPPORT/device-sync-state/system-transaction-history" "system transaction history" children historical || return 1
  retention_add_path "$APP_SUPPORT/device-sync-state/abandoned-system-transaction-preparations" "abandoned transaction preparations" children || return 1
  retention_add_path "$APP_SUPPORT/hot-sync-failed" "failed system activations" children || return 1
  retention_add_path "$APP_SUPPORT/device-sync-state/skillet-export-receipts" "Skillet export receipts" children historical || return 1
  retention_add_path "$APP_SUPPORT/device-sync-state/skillet-activation-receipts" "Skillet activation receipts and diagnostics" children historical || return 1
  retention_add_path "$APP_SUPPORT/device-sync-state/skills-consumer-projection-receipts" "native skills projection activation receipts" children historical || return 1
  retention_add_path "$APP_SUPPORT/device-sync-state/consumer-readbacks" "local consumer readback receipts" children historical || return 1
  retention_add_path "$SKILLS_CONSUMER_ROOT/.tatwo-binding/transaction.json" "active native skills projection transaction" self || return 1
  retention_add_path "$SKILLS_CONSUMER_ROOT/.tatwo-binding/state.json" "active native skills projection binding state" self || return 1
  retention_add_path "$SKILLS_CONSUMER_ROOT/.tatwo-binding/transactions" "native skills projection transaction archives" children historical || return 1
  retention_add_path "$SKILLS_CONSUMER_ROOT/.tatwo-binding/recovered" "native skills projection recovered transaction archives" children historical || return 1

  retention_add_path "$CHANNEL_DIR/payloads" "channel immutable payloads" children historical || return 1
  retention_add_path "$CHANNEL_DIR/requests" "channel requests" files historical || return 1
  retention_add_path "$CHANNEL_DIR/acks" "channel acknowledgements" files historical || return 1
  retention_add_path "$CHANNEL_DIR/attestations" "channel target attestations" files historical || return 1
  retention_add_path "$CHANNEL_DIR/consumer-readbacks" "channel consumer readbacks" files historical || return 1
  retention_add_path "$CHANNEL_DIR/signatures" "channel Ed25519 signatures" files historical || return 1
  retention_add_path "$CHANNEL_DIR/.git/objects" "channel git object database" self historical || return 1
  retention_add_path "$CHANNEL_DIR/.git/tatwo-abandoned-atomic-writes" "abandoned channel atomic writes" children || return 1
  retention_add_path "$CHANNEL_DIR/.git/tatwo-payload-staging" "orphaned channel payload staging" children || return 1

  retention_add_path "$HOT_SYNC_STAGING" "hot-sync staging and archived candidates" children || return 1
  retention_add_path "$HOT_SYNC_MIRROR/.tatwo-sync-rollback" "OS rollback snapshots" children historical || return 1
  retention_add_path "$HOT_SYNC_MIRROR/.tatwo-sync-rollback-history" "OS rollback history" children historical || return 1
  retention_add_path "$HOT_SYNC_MIRROR/.tatwo-sync-candidate-history" "OS candidate recovery history" children historical || return 1
  retention_add_path "$HOT_SYNC_MIRROR/.tatwo-sync-failed" "failed OS mirrors" children || return 1
  retention_add_path "$HOT_SYNC_MIRROR/.tatwo-sync-candidates" "OS destination-volume candidates" children || return 1

  local store_parent store_basename
  store_parent="$(dirname "$SKILLET_STORE")"
  store_basename="$(basename "$SKILLET_STORE")"
  retention_add_path "$store_parent/.tatwo-sync-store-rollback" "Skillet store rollback snapshots" children historical || return 1
  retention_add_path "$store_parent/.tatwo-sync-store-rollback-history" "Skillet store rollback history" children historical || return 1
  retention_add_path "$store_parent/.tatwo-sync-store-failed" "failed live Skillet stores" children || return 1
  retention_add_path "$store_parent/.skillet-import-archive" "Skillet previous-store archives" children historical || return 1
  retention_add_path "$store_parent/.skillet-set-failed" "failed Skillet set stores" children || return 1
  retention_add_glob "$store_parent/.$store_basename.import-staging-*" "partial Skillet imports" || return 1
  retention_add_glob "$store_parent/.$store_basename.set-staging-*" "partial Skillet set stores" || return 1
  retention_add_glob "$store_parent/.$store_basename.pending-merge-*" "durable incoming Skillet merge payloads" || return 1
  retention_add_glob "$store_parent/.$store_basename.merge-staging-*" "partial Skillet merge staging" || return 1

  retention_add_path "$SKILLET_RUNTIME_ROOT/.tatwo-sync-rollback" "system runtime rollback snapshots" children historical || return 1
  retention_add_path "$SKILLET_RUNTIME_ROOT/.tatwo-sync-rollback-history" "system runtime rollback history" children historical || return 1
  retention_add_path "$SKILLET_RUNTIME_ROOT/.tatwo-sync-failed" "failed system runtimes" children || return 1
  retention_add_path "$SKILLET_RUNTIME_ROOT/.set-transaction-archive" "Skillet set runtime archives" children historical || return 1
  retention_add_path "$SKILLET_RUNTIME_ROOT/.set-staging" "Skillet set runtime staging" children || return 1
  retention_add_path "$SKILLET_RUNTIME_ROOT/.set-rollback" "Skillet set runtime rollback" children || return 1
  retention_add_path "$SKILLET_RUNTIME_ROOT/.set-failed" "failed Skillet set runtimes" children || return 1
  retention_add_path "$SKILLET_RUNTIME_ROOT/.failed-archive" "Skillet failed runtime archives" children || return 1

  local entry_count=0 historical_entry_count=0 total_bytes=0
  local index=0 volume_state volumes_json="["
  RETENTION_BUDGET_STATE="within-budget"
  while [ "$index" -lt "${#RETENTION_VOLUME_DEVICES[@]}" ]; do
    entry_count=$((entry_count + ${RETENTION_VOLUME_ENTRIES[$index]}))
    historical_entry_count=$((
      historical_entry_count + ${RETENTION_VOLUME_HISTORICAL_ENTRIES[$index]}
    ))
    total_bytes=$((total_bytes + ${RETENTION_VOLUME_BYTES[$index]}))
    volume_state="within-budget"
    if [ "${RETENTION_VOLUME_ENTRIES[$index]}" -gt "$SYNC_RETENTION_MAX_ENTRIES" ] \
      || [ "${RETENTION_VOLUME_BYTES[$index]}" -gt "$SYNC_RETENTION_MAX_BYTES" ]
    then
      volume_state="blocked"
      RETENTION_BUDGET_STATE="blocked"
    fi
    [ "$index" -eq 0 ] || volumes_json="${volumes_json},"
    volumes_json="${volumes_json}{
      \"deviceID\":\"$(json_escape "${RETENTION_VOLUME_DEVICES[$index]}")\",
      \"mountPoint\":\"$(json_escape "${RETENTION_VOLUME_MOUNTS[$index]}")\",
      \"state\":\"$volume_state\",
      \"activeEntryCount\":${RETENTION_VOLUME_ENTRIES[$index]},
      \"historicalEntryCount\":${RETENTION_VOLUME_HISTORICAL_ENTRIES[$index]},
      \"entryCount\":${RETENTION_VOLUME_ENTRIES[$index]},
      \"allocatedBytes\":${RETENTION_VOLUME_BYTES[$index]},
      \"activeTrackedArtifacts\":\"$(json_escape "${RETENTION_VOLUME_LABELS[$index]}")\",
      \"historicalTrackedArtifacts\":\"$(json_escape "${RETENTION_VOLUME_HISTORICAL_LABELS[$index]}")\"
    }"
    index=$((index + 1))
  done
  volumes_json="${volumes_json}]"
  local status_file="$APP_SUPPORT/device-sync-state/retention-status.json"
  local status_stage="${status_file}.$$.tmp"
  mkdir -p "$(dirname "$status_file")" || return 1
  cat >"$status_stage" <<EOF || return 1
{
  "schema": "TatwoSyncRetentionStatusV1",
  "state": "$RETENTION_BUDGET_STATE",
  "limitScope": "per-volume",
  "activeEntryCount": $entry_count,
  "historicalEntryCount": $historical_entry_count,
  "entryCount": $entry_count,
  "maxEntries": $SYNC_RETENTION_MAX_ENTRIES,
  "allocatedBytes": $total_bytes,
  "maxBytes": $SYNC_RETENTION_MAX_BYTES,
  "volumes": $volumes_json,
  "checkedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "message": "active retryable/failed artifacts are entry-budgeted per volume; immutable history remains byte-budgeted and does not exhaust the active entry cap"
}
EOF
  [ "$(plutil -extract schema raw "$status_stage" 2>/dev/null || true)" = "TatwoSyncRetentionStatusV1" ] \
    || return 1
  mv "$status_stage" "$status_file" || return 1
  if [ "$RETENTION_BUDGET_STATE" = "blocked" ]; then
    log "retention budget 已達上限：activeEntries=${entry_count}/${SYNC_RETENTION_MAX_ENTRIES} historicalEntries=${historical_entry_count} bytes=${total_bytes}/${SYNC_RETENTION_MAX_BYTES}；拒絕新增同步，需人工封存/複審"
    return 1
  fi
}

sync_catalog_revision() {
  [ -f "$SYNC_CATALOG" ] \
    || die "找不到同步 catalog：$SYNC_CATALOG"
  local revision
  revision="$(json_get "$SYNC_CATALOG" catalogRevision)"
  [ -n "$revision" ] || die "同步 catalog 缺少 catalogRevision"
  printf '%s\n' "$revision"
}

channel_remote_url() {
  if [ -n "$CHANNEL_REMOTE" ]; then echo "$CHANNEL_REMOTE"; return; fi
  if [ "$ALLOW_LEGACY_CHANNEL_REMOTE" = "1" ]; then
    git -C "$(resolve_repo)" remote get-url origin 2>/dev/null \
      || die "找不到 legacy origin remote；請設定 TATWO_CHANNEL_REMOTE"
    return
  fi
  die "私人熱同步通道未設定；必須明確設定 TATWO_CHANNEL_REMOTE。GitHub origin 只可作冷備份，不再自動當熱同步通道"
}

rebind_channel_origin() {
  local desired_url="$1"
  local current_url current_head stamp receipt_root
  local bundle bundle_stage receipt receipt_stage
  current_url="$(git -C "$CHANNEL_DIR" remote get-url origin 2>/dev/null || true)"
  [ "$current_url" = "$desired_url" ] && return 0
  [ -n "$current_url" ] \
    || die "既有同步通道缺少 origin；拒絕猜測或覆寫 remote"
  git ls-remote --exit-code --heads "$desired_url" "$CHANNEL_BRANCH" >/dev/null 2>&1 \
    || die "既有同步通道 origin 與設定不符，且新 remote 無法驗證目標分支；拒絕改寫：$desired_url"

  current_head="$(git -C "$CHANNEL_DIR" rev-parse HEAD 2>/dev/null || true)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  receipt_root="$APP_SUPPORT/device-sync-state/channel-origin-rebind/$stamp"
  bundle="$receipt_root/channel-before-rebind.bundle"
  bundle_stage="$bundle.staging"
  receipt="$receipt_root/receipt.json"
  receipt_stage="$receipt.staging"
  mkdir -p "$receipt_root" \
    || die "無法建立 channel origin rebind rollback 目錄"
  git -C "$CHANNEL_DIR" bundle create "$bundle_stage" --all >/dev/null 2>&1 \
    && git bundle verify "$bundle_stage" >/dev/null 2>&1 \
    && mv "$bundle_stage" "$bundle" \
    || die "無法建立 channel origin rebind 前的 Git bundle；拒絕改寫 origin"

  if git -C "$CHANNEL_DIR" remote set-url origin "$desired_url" \
    && [ "$(git -C "$CHANNEL_DIR" remote get-url origin 2>/dev/null || true)" = "$desired_url" ]
  then
    cat >"$receipt_stage" <<EOF
{
  "schema": "TatwoChannelOriginRebindReceiptV1",
  "outcome": "rebound",
  "channelPath": "$(json_escape "$CHANNEL_DIR")",
  "channelBranch": "$(json_escape "$CHANNEL_BRANCH")",
  "oldRemote": "$(json_escape "$current_url")",
  "newRemote": "$(json_escape "$desired_url")",
  "headBeforeRebind": "$(json_escape "$current_head")",
  "rollbackBundle": "$(json_escape "$bundle")",
  "reboundAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    [ "$(json_get "$receipt_stage" schema)" = "TatwoChannelOriginRebindReceiptV1" ] \
      && [ "$(json_get "$receipt_stage" outcome)" = "rebound" ] \
      && mv "$receipt_stage" "$receipt" \
      || die "channel origin 已改寫，但 durable rebind receipt 寫入失敗；rollback bundle=$bundle"
    log "同步通道 origin 已由舊 remote 安全改綁至私人熱通道；receipt=$receipt"
    return 0
  fi

  cat >"$receipt_stage" <<EOF
{
  "schema": "TatwoChannelOriginRebindReceiptV1",
  "outcome": "failed",
  "channelPath": "$(json_escape "$CHANNEL_DIR")",
  "channelBranch": "$(json_escape "$CHANNEL_BRANCH")",
  "oldRemote": "$(json_escape "$current_url")",
  "newRemote": "$(json_escape "$desired_url")",
  "headBeforeRebind": "$(json_escape "$current_head")",
  "rollbackBundle": "$(json_escape "$bundle")",
  "reboundAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  mv "$receipt_stage" "$receipt" 2>/dev/null || true
  die "同步通道 origin 改綁失敗；已保留 rollback bundle 與 receipt：$receipt_root"
}

recover_channel_atomic_stages() {
  [ -d "$CHANNEL_DIR/.git" ] || return 0
  local archive_root="$CHANNEL_DIR/.git/tatwo-abandoned-atomic-writes"
  local stage relative safe_name status_line status_code artifact_dir
  local payload_staging_root payload_stage_name
  local -a artifact_roots=()
  payload_staging_root="$(
    git -C "$CHANNEL_DIR" rev-parse \
      --path-format=absolute --git-path tatwo-payload-staging
  )" || return 1
  if [ -d "$payload_staging_root" ]; then
    while IFS= read -r -d '' stage; do
      [ -e "$stage" ] || [ -L "$stage" ] || continue
      payload_stage_name="$(basename "$stage")"
      safe_name="${payload_stage_name//[^A-Za-z0-9._-]/_}"
      mkdir -p "$archive_root" || return 1
      mv "$stage" \
        "$archive_root/payload-staging__$safe_name-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM" \
        || return 1
      log "archived orphaned channel payload staging：$payload_stage_name"
    done < <(
      find "$payload_staging_root" -mindepth 1 -maxdepth 1 -print0 2>/dev/null \
        || true
    )
  fi
  for artifact_dir in "${CHANNEL_ATOMIC_ARTIFACT_DIRS[@]}"; do
    artifact_roots+=("$CHANNEL_DIR/$artifact_dir")
  done
  while IFS= read -r stage; do
    [ -f "$stage" ] || continue
    relative="${stage#"$CHANNEL_DIR"/}"
    safe_name="${relative//\//__}"
    mkdir -p "$archive_root" || return 1
    mv "$stage" "$archive_root/$safe_name-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM" \
      || return 1
    log "archived incomplete atomic channel write：$relative"
  done < <(
    find "${artifact_roots[@]}" \
      -type f -name '.*.tmp' -print 2>/dev/null || true
  )
  while IFS= read -r -d '' status_line; do
    [ -n "$status_line" ] || continue
    status_code="${status_line:0:2}"
    relative="${status_line:3}"
    case "$status_code" in
      "??"|"A ")
        ;;
      *)
        continue
        ;;
    esac
    stage="$CHANNEL_DIR/$relative"
    [ -f "$stage" ] || continue
    if [ "$status_code" = "A " ]; then
      git -C "$CHANNEL_DIR" reset -q HEAD -- "$relative" || return 1
    fi
    safe_name="${relative//\//__}"
    mkdir -p "$archive_root" || return 1
    mv "$stage" "$archive_root/$safe_name-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM" \
      || return 1
    log "archived uncommitted channel receipt after interrupted atomic write：$relative"
  done < <(
    git -C "$CHANNEL_DIR" -c core.quotePath=false \
      status --porcelain=v1 -z --untracked-files=all -- \
      "${CHANNEL_ATOMIC_ARTIFACT_DIRS[@]}" \
      2>/dev/null || true
  )
}

channel_ensure() {
  local url; url="$(channel_remote_url)"
  if [ ! -d "$CHANNEL_DIR/.git" ]; then
    mkdir -p "$(dirname "$CHANNEL_DIR")"
    if git ls-remote --exit-code --heads "$url" "$CHANNEL_BRANCH" >/dev/null 2>&1; then
      git clone --branch "$CHANNEL_BRANCH" --single-branch --depth 30 "$url" "$CHANNEL_DIR" >/dev/null 2>&1 \
        || die "clone 通道分支失敗"
    else
      # 通道分支尚不存在 → 建 orphan 並推上去
      git clone --depth 1 "$url" "$CHANNEL_DIR" >/dev/null 2>&1 || die "clone 失敗（用於建通道）"
      git -C "$CHANNEL_DIR" checkout --orphan "$CHANNEL_BRANCH" >/dev/null 2>&1
      git -C "$CHANNEL_DIR" rm -rf . >/dev/null 2>&1 || true
      mkdir -p "$CHANNEL_DIR/requests" "$CHANNEL_DIR/acks"
      printf 'TatwoOS device-sync 信號通道（機器管理，勿併入程式碼分支）。\n' > "$CHANNEL_DIR/README.md"
      git -C "$CHANNEL_DIR" add -A
      git -C "$CHANNEL_DIR" commit -m "init device-sync channel" >/dev/null 2>&1
      git -C "$CHANNEL_DIR" push -u origin "$CHANNEL_BRANCH" >/dev/null 2>&1 || die "建立通道分支失敗"
      return
    fi
  fi
  recover_channel_atomic_stages \
    || die "無法封存同步通道中的 incomplete atomic writes"
  [ -z "$(git -C "$CHANNEL_DIR" status --porcelain=v1 --untracked-files=all)" ] \
    || die "同步通道工作樹含未提交變更；拒絕 reset 或覆蓋，請先人工查驗：$CHANNEL_DIR"
  rebind_channel_origin "$url"
  git -C "$CHANNEL_DIR" fetch origin \
    "refs/heads/$CHANNEL_BRANCH:refs/remotes/origin/$CHANNEL_BRANCH" >/dev/null 2>&1 \
    || die "通道 fetch 失敗（離線或遠端分支不存在）"
  local local_head remote_head
  local_head="$(git -C "$CHANNEL_DIR" rev-parse HEAD)"
  remote_head="$(git -C "$CHANNEL_DIR" rev-parse "origin/$CHANNEL_BRANCH")"
  [ "$local_head" = "$remote_head" ] && return

  if git -C "$CHANNEL_DIR" merge-base --is-ancestor "$local_head" "$remote_head"; then
    git -C "$CHANNEL_DIR" merge --ff-only "origin/$CHANNEL_BRANCH" >/dev/null 2>&1 \
      || die "同步通道無法 fast-forward 到遠端"
    return
  fi
  if git -C "$CHANNEL_DIR" merge-base --is-ancestor "$remote_head" "$local_head"; then
    channel_push
    return
  fi
  if ! git -C "$CHANNEL_DIR" rebase "origin/$CHANNEL_BRANCH" >/dev/null 2>&1; then
    git -C "$CHANNEL_DIR" rebase --abort >/dev/null 2>&1 || true
    die "同步通道本機未推送收據與遠端分岔；已保留本機 commit，拒絕 reset --hard"
  fi
  channel_push
}

channel_push() {  # 帶一次 rebase 重試，容忍其他設備同時寫
  if git -C "$CHANNEL_DIR" push origin "$CHANNEL_BRANCH" >/dev/null 2>&1; then return 0; fi
  git -C "$CHANNEL_DIR" fetch origin \
    "refs/heads/$CHANNEL_BRANCH:refs/remotes/origin/$CHANNEL_BRANCH" >/dev/null 2>&1
  if ! git -C "$CHANNEL_DIR" rebase "origin/$CHANNEL_BRANCH" >/dev/null 2>&1; then
    git -C "$CHANNEL_DIR" rebase --abort >/dev/null 2>&1 || true
    die "通道 rebase 衝突；已保留本機 commit，拒絕丟棄未推送 request/ACK"
  fi
  git -C "$CHANNEL_DIR" push origin "$CHANNEL_BRANCH" >/dev/null 2>&1 || die "通道 push 失敗（衝突/離線）"
}

primary_file() { echo "$CHANNEL_DIR/primary.json"; }
request_sequence_file() { echo "$CHANNEL_DIR/request-sequence.json"; }
pairing_dir() { echo "$CHANNEL_DIR/pairing"; }
runtime_fallback_authorization_relative_path() {
  local name="$1" epoch="$2"
  validate_device_name "$name"
  validate_epoch "$epoch"
  printf 'fallback-authorizations/%s/epoch-%s.json\n' "$name" "$epoch"
}
runtime_fallback_authorization_signature_relative_path() {
  local name="$1" epoch="$2"
  validate_device_name "$name"
  validate_epoch "$epoch"
  printf 'signatures/fallback-authorizations/%s/epoch-%s.json\n' "$name" "$epoch"
}
PAIRING_TTL_SECONDS="${TATWO_PAIRING_TTL_SECONDS:-180}"

iso_to_epoch() {  # iso_to_epoch <ISO8601 UTC> → epoch seconds，解析失敗回空字串
  # 務必加 -u：BSD date 的 -j -f 預設以本機時區解析，"Z" 只是字面字元不代表 UTC，
  # 不加 -u 會依時區偏移算錯過期判斷（已實測：+8 時區會誤判為早已過期）。
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || true
}

cmd_pairing_create() {  # 僅現任主設備可產生限時、單次、epoch 綁定的配對代碼
  channel_ensure
  require_current_primary
  local seed=""
  while [ "${#seed}" -ne 8 ]; do
    seed="$(LC_ALL=C tr -dc 'A-Z0-9' < /dev/urandom 2>/dev/null | head -c 8 || true)"
  done
  local now_epoch expires_epoch created_at expires_at
  now_epoch="$(date -u +%s)"
  expires_epoch=$((now_epoch + PAIRING_TTL_SECONDS))
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  expires_at="$(date -u -r "$expires_epoch" +%Y-%m-%dT%H:%M:%SZ)"

  mkdir -p "$(pairing_dir)"
  cat > "$(pairing_dir)/$seed.json" <<EOF
{
  "seed": "$seed",
  "createdAt": "$created_at",
  "expiresAt": "$expires_at",
  "consumedAt": "",
  "createdBy": "$DEVICE_NAME",
  "authorityPrimary": "$PRIMARY_NAME",
  "authorityEpoch": $PRIMARY_EPOCH
}
EOF
  git -C "$CHANNEL_DIR" add "pairing/$seed.json"
  git -C "$CHANNEL_DIR" commit -m "pairing seed created (expires ${expires_at})" >/dev/null 2>&1
  channel_push
  log "配對代碼已產生：seed=$seed expiresAt=${expires_at}（限時 ${PAIRING_TTL_SECONDS} 秒、單次有效）"
  echo "PAIRING_SEED=$seed"
  echo "PAIRING_EXPIRES_AT=$expires_at"
}

read_primary_state() {
  local file; file="$(primary_file)"
  PRIMARY_NAME=""
  PRIMARY_EPOCH=""
  PRIMARY_CHANGED_AT=""
  PRIMARY_PREVIOUS_NAME=""
  PRIMARY_PREVIOUS_EPOCH="0"
  PRIMARY_FALLBACK_AUTHORIZATION_ID=""
  PRIMARY_FALLBACK_AUTHORIZATION_PATH=""
  PRIMARY_FALLBACK_AUTHORIZATION_DIGEST=""
  PRIMARY_FALLBACK_AUTHORIZATION_SIGNATURE_PATH=""
  [ -f "$file" ] || return 0
  PRIMARY_NAME="$(json_get "$file" name)"
  PRIMARY_EPOCH="$(json_number_get "$file" epoch)"
  PRIMARY_CHANGED_AT="$(json_get "$file" changedAt)"
  PRIMARY_PREVIOUS_NAME="$(json_get "$file" previousName)"
  PRIMARY_PREVIOUS_EPOCH="$(json_number_get "$file" previousEpoch)"
  PRIMARY_FALLBACK_AUTHORIZATION_ID="$(json_get "$file" runtimeFallbackAuthorizationID)"
  PRIMARY_FALLBACK_AUTHORIZATION_PATH="$(json_get "$file" runtimeFallbackAuthorizationPath)"
  PRIMARY_FALLBACK_AUTHORIZATION_DIGEST="$(json_get "$file" runtimeFallbackAuthorizationDigest)"
  PRIMARY_FALLBACK_AUTHORIZATION_SIGNATURE_PATH="$(
    json_get "$file" runtimeFallbackAuthorizationSignaturePath
  )"
  [ -n "$PRIMARY_NAME" ] || die "primary.json 缺少 name，拒絕繼續"
  validate_device_name "$PRIMARY_NAME"
  validate_epoch "$PRIMARY_EPOCH"
  [ -n "$PRIMARY_CHANGED_AT" ] || die "primary.json 缺少 changedAt，拒絕繼續"
  [ -n "$PRIMARY_PREVIOUS_EPOCH" ] || PRIMARY_PREVIOUS_EPOCH=0
  validate_epoch "$PRIMARY_PREVIOUS_EPOCH"
  if [ -n "$PRIMARY_PREVIOUS_NAME" ]; then
    validate_device_name "$PRIMARY_PREVIOUS_NAME"
  fi
  local fallback_field_count=0
  [ -n "$PRIMARY_FALLBACK_AUTHORIZATION_ID" ] \
    && fallback_field_count=$((fallback_field_count + 1))
  [ -n "$PRIMARY_FALLBACK_AUTHORIZATION_PATH" ] \
    && fallback_field_count=$((fallback_field_count + 1))
  [ -n "$PRIMARY_FALLBACK_AUTHORIZATION_DIGEST" ] \
    && fallback_field_count=$((fallback_field_count + 1))
  [ -n "$PRIMARY_FALLBACK_AUTHORIZATION_SIGNATURE_PATH" ] \
    && fallback_field_count=$((fallback_field_count + 1))
  [ "$fallback_field_count" = "0" ] || [ "$fallback_field_count" = "4" ] \
    || die "primary.json runtime fallback authorization binding 不完整"
  if [ "$fallback_field_count" = "4" ]; then
    case "$PRIMARY_FALLBACK_AUTHORIZATION_ID" in
      ""|.|..|*/*|*[!A-Za-z0-9._:-]*)
        die "primary.json runtime fallback authorization ID 不安全"
        ;;
    esac
    is_sha256_digest "$PRIMARY_FALLBACK_AUTHORIZATION_DIGEST" \
      || die "primary.json runtime fallback authorization digest 不合法"
    [ "$PRIMARY_FALLBACK_AUTHORIZATION_PATH" = \
      "$(runtime_fallback_authorization_relative_path "$PRIMARY_NAME" "$PRIMARY_EPOCH")" ] \
      || die "primary.json runtime fallback authorization path 不符合目前主權"
    [ "$PRIMARY_FALLBACK_AUTHORIZATION_SIGNATURE_PATH" = \
      "$(runtime_fallback_authorization_signature_relative_path "$PRIMARY_NAME" "$PRIMARY_EPOCH")" ] \
      || die "primary.json runtime fallback signature path 不符合目前主權"
  fi
}

require_current_primary() {
  read_primary_state
  [ -n "$PRIMARY_NAME" ] || die "尚未設定現任主設備；先執行 set-primary --name NAME"
  [ "$DEVICE_NAME" = "$PRIMARY_NAME" ] \
    || die "此操作僅現任主設備可執行；本機=${DEVICE_NAME}，現任主=${PRIMARY_NAME}"
  ensure_device_identity
  local local_device_id registered_primary_id
  local_device_id="$(json_get "$(device_identity_file)" deviceId)"
  registered_primary_id="$(registered_device_id "$PRIMARY_NAME")"
  [ -n "$registered_primary_id" ] \
    || die "現任主設備未登記 device identity：$PRIMARY_NAME"
  [ "$local_device_id" = "$registered_primary_id" ] \
    || die "本機 device identity 與現任主設備 registry 不符；拒絕使用名稱冒充主設備"
}

compute_next_request_sequence() {
  local file epoch="" sequence=""
  file="$(request_sequence_file)"
  if [ -f "$file" ]; then
    epoch="$(json_number_get "$file" authorityEpoch)"
    sequence="$(json_number_get "$file" ledgerSequence)"
    validate_epoch "$epoch"
    validate_epoch "$sequence"
    [ "$epoch" -le "$PRIMARY_EPOCH" ] \
      || die "request sequence epoch 超前於現任 authority；拒絕覆寫"
  fi
  if [ -n "$epoch" ] && [ "$epoch" = "$PRIMARY_EPOCH" ]; then
    REQUEST_LEDGER_SEQUENCE=$((sequence + 1))
  else
    REQUEST_LEDGER_SEQUENCE=1
  fi
}

persist_request_sequence() {
  local changed_at
  changed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat >"$(request_sequence_file)" <<EOF
{
  "authorityPrimary": "$(json_escape "$PRIMARY_NAME")",
  "authorityEpoch": $PRIMARY_EPOCH,
  "ledgerSequence": $REQUEST_LEDGER_SEQUENCE,
  "updatedAt": "$changed_at"
}
EOF
}

cmd_role_status() {
  channel_ensure
  read_primary_state
  if [ -z "$PRIMARY_NAME" ]; then
    log "device=$DEVICE_NAME role=unassigned primary=none epoch=0 changedAt=none"
    return
  fi
  local role="secondary"
  [ "$DEVICE_NAME" = "$PRIMARY_NAME" ] && role="primary"
  log "device=$DEVICE_NAME role=$role primary=$PRIMARY_NAME epoch=$PRIMARY_EPOCH changedAt=$PRIMARY_CHANGED_AT"
}

cmd_set_primary() {
  local name="" expected_epoch="" authorize_runtime_fallback=0
  while [ $# -gt 0 ]; do case "$1" in
    --name) name="${2:-}"; shift 2;;
    --expected-epoch) expected_epoch="${2:-}"; shift 2;;
    --authorize-runtime-fallback) authorize_runtime_fallback=1; shift;;
    *) die "未知參數 $1";; esac; done
  [ -n "$name" ] || die "set-primary 需要 --name NAME"
  validate_device_name "$name"
  [ -z "$expected_epoch" ] || validate_epoch "$expected_epoch"

  channel_ensure
  read_primary_state
  local old_name="$PRIMARY_NAME" old_epoch="${PRIMARY_EPOCH:-0}"
  local target_device_id local_device_id
  target_device_id="$(registered_device_id "$name")"
  [ -n "$target_device_id" ] \
    || die "目標設備尚未登記：$name"
  ensure_device_identity
  local_device_id="$(json_get "$(device_identity_file)" deviceId)"
  if [ "$name" = "$DEVICE_NAME" ]; then
    ensure_device_trust_identity
    validate_registered_device_trust "$name" "$target_device_id" \
      && device_trust_identity_files_match \
        "$(registered_device_file "$name")" "$(device_trust_identity_file)" \
      || die "目標主設備 registry 尚未綁定本機 Ed25519 identity"
  else
    pin_registered_device_trust "$name" "$target_device_id" \
      || die "目標主設備 trust identity 未登記、已撤銷或與本機 pin 不符"
  fi

  if [ -n "$expected_epoch" ] && [ "$expected_epoch" != "$old_epoch" ]; then
    die "epoch 不符：expected=${expected_epoch}，current=${old_epoch}；拒絕倒退或覆寫較新主權"
  fi
  if [ -n "$old_name" ]; then
    require_current_primary
  else
    [ "$DEVICE_NAME" = "$name" ] \
      || die "尚無主設備時，只允許已登記設備為自己建立初始主權"
    [ "$local_device_id" = "$target_device_id" ] \
      || die "初始主權目標 device identity 與本機不符"
  fi

  local new_epoch=$((old_epoch + 1)) changed_at
  local fallback_authorization_id="" fallback_authorization_relative=""
  local fallback_authorization_digest="" fallback_signature_relative=""
  changed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ "$authorize_runtime_fallback" = "1" ]; then
    [ -n "$old_name" ] \
      || die "初始主權不得授權 runtime fallback；先以 canonical source 建立基準"
    local old_device_id authorization authorization_stage signature signature_stage
    old_device_id="$(registered_device_id "$old_name")"
    [ -n "$old_device_id" ] \
      || die "前任主設備缺少已登記 device identity，拒絕簽發 runtime fallback authorization"
    [ "$DEVICE_NAME" = "$old_name" ] \
      && [ "$local_device_id" = "$old_device_id" ] \
      || die "只有前任主設備可簽發下一 epoch 的 runtime fallback authorization"
    fallback_authorization_id="$(newid)-runtime-fallback"
    fallback_authorization_relative="$(
      runtime_fallback_authorization_relative_path "$name" "$new_epoch"
    )"
    fallback_signature_relative="$(
      runtime_fallback_authorization_signature_relative_path "$name" "$new_epoch"
    )"
    authorization="$CHANNEL_DIR/$fallback_authorization_relative"
    signature="$CHANNEL_DIR/$fallback_signature_relative"
    mkdir -p "$(dirname "$authorization")" "$(dirname "$signature")"
    authorization_stage="$(dirname "$authorization")/.$(basename "$authorization").$$.tmp"
    signature_stage="$(dirname "$signature")/.$(basename "$signature").$$.tmp"
    cat >"$authorization_stage" <<EOF
{
  "schema": "TatwoSkilletRuntimeFallbackAuthorizationV1",
  "authorizationID": "$(json_escape "$fallback_authorization_id")",
  "sourceMode": "runtime-fallback",
  "authorizedDeviceName": "$(json_escape "$name")",
  "authorizedDeviceID": "$(json_escape "$target_device_id")",
  "authorityPrimary": "$(json_escape "$name")",
  "authorityEpoch": $new_epoch,
  "previousAuthorityPrimary": "$(json_escape "$old_name")",
  "previousAuthorityEpoch": $old_epoch,
  "authorizedByDeviceName": "$(json_escape "$DEVICE_NAME")",
  "authorizedByDeviceID": "$(json_escape "$local_device_id")",
  "issuedAt": "$changed_at",
  "scope": "authority-epoch",
  "signaturePurpose": "skillet-runtime-fallback-authorization",
  "signaturePath": "$(json_escape "$fallback_signature_relative")"
}
EOF
    sign_channel_artifact \
      "skillet-runtime-fallback-authorization" \
      "$authorization_stage" "$signature_stage" \
      || die "無法簽發 runtime fallback authorization"
    fallback_authorization_digest="$(sha256_file "$authorization_stage")"
    is_sha256_digest "$fallback_authorization_digest" \
      || die "runtime fallback authorization digest 產生失敗"
    mv "$authorization_stage" "$authorization"
    mv "$signature_stage" "$signature"
  fi
  cat > "$(primary_file)" <<EOF
{
  "name": "$name",
  "epoch": $new_epoch,
  "changedAt": "$changed_at",
  "previousName": "$(json_escape "$old_name")",
  "previousEpoch": $old_epoch,
  "runtimeFallbackAuthorizationID": "$(json_escape "$fallback_authorization_id")",
  "runtimeFallbackAuthorizationPath": "$(json_escape "$fallback_authorization_relative")",
  "runtimeFallbackAuthorizationDigest": "$(json_escape "$fallback_authorization_digest")",
  "runtimeFallbackAuthorizationSignaturePath": "$(json_escape "$fallback_signature_relative")"
}
EOF
  git -C "$CHANNEL_DIR" add primary.json
  if [ "$authorize_runtime_fallback" = "1" ]; then
    git -C "$CHANNEL_DIR" add \
      "$fallback_authorization_relative" "$fallback_signature_relative"
  fi
  git -C "$CHANNEL_DIR" commit -m "set primary $name epoch $new_epoch" >/dev/null 2>&1
  channel_push
  log "主設備已設定：primary=$name epoch=$new_epoch changedAt=$changed_at"
  if [ "$authorize_runtime_fallback" = "1" ]; then
    log "runtime fallback 已由前任主設備明確授權：authorization=$fallback_authorization_id"
  fi
}

cmd_integrate() {
  local repo; repo="$(resolve_repo)"
  channel_ensure
  require_current_primary
  git -C "$repo" fetch origin '+refs/heads/dev/*:refs/remotes/origin/dev/*' \
    || die "fetch dev/* 失敗"

  local found=0 ref branch ahead behind last
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    found=1
    branch="${ref#refs/remotes/origin/}"
    ahead="$(git -C "$repo" rev-list --count "origin/$RELEASE_BRANCH..$ref" 2>/dev/null || echo '?')"
    behind="$(git -C "$repo" rev-list --count "$ref..origin/$RELEASE_BRANCH" 2>/dev/null || echo '?')"
    last="$(git -C "$repo" log -1 --format='%h %cI %s' "$ref" 2>/dev/null || echo unknown)"
    log "branch=$branch ahead=$ahead behind=$behind last=$last"
  done < <(git -C "$repo" for-each-ref --format='%(refname)' 'refs/remotes/origin/dev/*')
  [ "$found" = "1" ] || log "沒有 dev/* 分支可整合"
  log "integrate 僅盤點，不自動合併"
}

registered_device_id() {
  local name="$1"
  local file="$CHANNEL_DIR/devices/$name.json"
  [ -f "$file" ] || return 0
  json_get "$file" deviceId
}

registered_device_name_for_id() {
  local device_id="$1" file candidate_id
  [ -d "$CHANNEL_DIR/devices" ] || return 0
  for file in "$CHANNEL_DIR"/devices/*.json; do
    [ -f "$file" ] || continue
    candidate_id="$(json_get "$file" deviceId)"
    if [ "$candidate_id" = "$device_id" ]; then
      json_get "$file" name
      return 0
    fi
  done
}

legacy_system_adapter_available() {
  # W78: A/E have one owner: the 2.0 authenticated RemoteHostLink adapter.
  # Never run the old git-channel payload builder against the new document catalog.
  if [ "$(json_get "$SYNC_CATALOG" dispatchTransport)" = "RemoteHostLink" ]; then
    log "A/E 派發已交給 2.0 RemoteHostLink；C 類文件請走 git"
    return 1
  fi
}

system_required_item_ids() {
  local count index=0 item_id
  legacy_system_adapter_available || return 1
  count="$(plutil -extract systemPullItemIDs raw "$SYNC_CATALOG" 2>/dev/null || true)"
  case "$count" in ""|0|*[!0-9]*)
    die "同步 catalog 缺少有效 systemPullItemIDs"
    ;;
  esac
  while [ "$index" -lt "$count" ]; do
    item_id="$(plutil -extract "systemPullItemIDs.$index" raw "$SYNC_CATALOG" 2>/dev/null || true)"
    [ -n "$item_id" ] || die "同步 catalog systemPullItemIDs.$index 為空"
    printf '%s\n' "$item_id"
    index=$((index + 1))
  done
}

run_skillet_cli() {
  if [[ "$SKILLET_CLI" == */* ]]; then
    [ -x "$SKILLET_CLI" ] || die "Skillet CLI 不可執行：$SKILLET_CLI"
  else
    command -v "$SKILLET_CLI" >/dev/null 2>&1 \
      || die "找不到 Skillet CLI：$SKILLET_CLI"
  fi
  "$SKILLET_CLI" "$@"
}

device_trust_test_mode_authorized() {
  local challenge="" expected_response="" observed_response=""
  [ "${TATWO_TEST_MODE:-0}" = "1" ] \
    && [ -n "${TATWO_DEVICE_TRUST_TEST_KEY_ROOT:-}" ] \
    || return 1
  case "$TATWO_DEVICE_TRUST_TEST_KEY_ROOT" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) ;;
    *) return 1 ;;
  esac
  challenge="$(uuidgen)" || return 1
  expected_response="$(
    printf '%s\0%s' "$challenge" "$TATWO_DEVICE_TRUST_TEST_KEY_ROOT" \
      | shasum -a 256 \
      | awk 'NR == 1 {print tolower($1)}'
  )" || return 1
  observed_response="$(
    "$DEVICE_TRUST_TEST_PYTHON" - \
      "${TATWO_DEVICE_TRUST_TEST_KEY_ROOT}" "$challenge" <<'PY'
import hashlib
import os
import sys

root = os.path.realpath(sys.argv[1])
challenge = sys.argv[2]
allowed_roots = {
    os.path.realpath(path)
    for path in ("/tmp", "/private/tmp", "/var/folders", "/private/var/folders")
    if os.path.isdir(path)
}
for allowed in allowed_roots:
    if root != allowed and os.path.commonpath([root, allowed]) == allowed:
        value = challenge + "\0" + sys.argv[1]
        print(hashlib.sha256(value.encode("utf-8")).hexdigest())
        raise SystemExit(0)
raise SystemExit(1)
PY
  )" || return 1
  [ "$observed_response" = "$expected_response" ]
}

device_trust_cli_cdhash() {
  local cli="$1" output="" cdhash="" sha=""
  if /usr/bin/codesign --verify --strict "$cli" >/dev/null 2>&1; then
    output="$(/usr/bin/codesign -dv --verbose=4 "$cli" 2>&1)" || return 1
    cdhash="$(
      printf '%s\n' "$output" \
        | awk -F= '/^CDHash=/ {print tolower($2); exit}'
    )"
    case "$cdhash" in
      ""|*[!0-9a-f]*) return 1;;
    esac
    [ "${#cdhash}" -ge 40 ] && [ "${#cdhash}" -le 64 ] || return 1
    printf '%s\n' "$cdhash"
    return
  fi
  device_trust_test_mode_authorized || return 1
  sha="$(sha256_file "$cli")" || return 1
  printf 'test-sha256-%s\n' "$sha"
}

run_device_trust_cli() {
  local cli="" expected_sha="" expected_cdhash="" actual_sha="" actual_cdhash=""
  if [ -f "$DEVICE_TRUST_SIGNER_PIN" ] \
    && [ ! -L "$DEVICE_TRUST_SIGNER_PIN" ] \
    && [ "$(stat -f '%Lp' "$DEVICE_TRUST_SIGNER_PIN" 2>/dev/null)" = "600" ] \
    && [ "$(json_get "$DEVICE_TRUST_SIGNER_PIN" schema)" = "TatwoDeviceTrustSignerPinV1" ]
  then
    cli="$(recorded_absolute_path "$DEVICE_TRUST_SIGNER_PIN" signerPath)" \
      || return 1
    [ "$cli" = "$DEVICE_TRUST_SIGNER" ] \
      || {
        log "device-trust signer pin 指向非 canonical anchor"
        return 1
      }
    expected_sha="$(json_get "$DEVICE_TRUST_SIGNER_PIN" sha256)"
    expected_cdhash="$(json_get "$DEVICE_TRUST_SIGNER_PIN" codeDirectoryHash)"
    [ -z "$DEVICE_TRUST_CLI_HINT" ] \
      || [ "$DEVICE_TRUST_CLI_HINT" = "$cli" ] \
      || {
        log "device-trust CLI hint 與 signer pin 不一致"
        return 1
      }
    [ -z "$DEVICE_TRUST_CLI_SHA256_HINT" ] \
      || [ "$DEVICE_TRUST_CLI_SHA256_HINT" = "$expected_sha" ] \
      || {
        log "device-trust SHA-256 hint 與 signer pin 不一致"
        return 1
      }
    [ -z "$DEVICE_TRUST_CLI_CDHASH_HINT" ] \
      || [ "$DEVICE_TRUST_CLI_CDHASH_HINT" = "$expected_cdhash" ] \
      || {
        log "device-trust cdhash hint 與 signer pin 不一致"
        return 1
      }
  elif device_trust_test_mode_authorized; then
    cli="${DEVICE_TRUST_CLI_HINT:-$SKILLET_CLI}"
    expected_sha="$(sha256_file "$cli")" || return 1
    expected_cdhash="$(device_trust_cli_cdhash "$cli")" || return 1
  else
    log "缺少有效的 device-trust signer pin；請重新執行設備納管"
    return 1
  fi
  [ -f "$cli" ] && [ ! -L "$cli" ] && [ -x "$cli" ] || return 1
  is_sha256_digest "$expected_sha" || return 1
  case "$expected_cdhash" in
    test-sha256-*)
      device_trust_test_mode_authorized || return 1
      ;;
    ""|*[!0-9a-f]*)
      return 1
      ;;
    *)
      [ "${#expected_cdhash}" -ge 40 ] \
        && [ "${#expected_cdhash}" -le 64 ] \
        || return 1
      ;;
  esac
  actual_sha="$(sha256_file "$cli")" || return 1
  actual_cdhash="$(device_trust_cli_cdhash "$cli")" || return 1
  [ "$actual_sha" = "$expected_sha" ] \
    && [ "$actual_cdhash" = "$expected_cdhash" ] \
    || {
      log "device-trust signer anchor 完整性驗證失敗"
      return 1
    }
  "$cli" device-trust "$@"
}

device_trust_identity_file() {
  printf '%s\n' "$APP_SUPPORT/device-trust/identity.json"
}

device_trust_peer_pin_file() {
  local name="$1"
  validate_device_name "$name"
  printf '%s\n' "$APP_SUPPORT/device-trust/peers/$name.json"
}

registered_device_file() {
  local name="$1"
  validate_device_name "$name"
  printf '%s\n' "$CHANNEL_DIR/devices/$name.json"
}

validate_device_trust_identity_file() {
  local file="$1" expected_device_id="$2"
  [ -f "$file" ] && [ ! -L "$file" ] \
    && [ "$(json_get "$file" schema)" = "TatwoDevicePublicIdentityV1" ] \
    && [ "$(json_get "$file" algorithm)" = "Ed25519" ] \
    && [ "$(json_get "$file" deviceID)" = "$expected_device_id" ] \
    && [ -n "$(json_get "$file" keyID)" ] \
    && [ -n "$(json_get "$file" publicKey)" ] \
    && [ "$(json_get "$file" keyStatus)" = "active" ] \
    && [ -n "$(json_get "$file" pinnedAt)" ] \
    || return 1
  local generation
  generation="$(json_number_get "$file" keyGeneration)"
  case "$generation" in ""|0|*[!0-9]*) return 1;; esac
}

device_trust_identity_files_match() {
  local left="$1" right="$2" key
  for key in schema algorithm deviceID keyID publicKey keyStatus pinnedAt; do
    [ "$(json_get "$left" "$key")" = "$(json_get "$right" "$key")" ] \
      || return 1
  done
  [ "$(json_number_get "$left" keyGeneration)" \
    = "$(json_number_get "$right" keyGeneration)" ]
}

device_trust_rotation_receipt_file() {
  local name="$1" generation="$2"
  validate_device_name "$name"
  case "$generation" in ""|0|*[!0-9]*) return 1;; esac
  printf '%s\n' \
    "$CHANNEL_DIR/device-trust/rotations/$name/$generation.json"
}

device_trust_rotation_matches_registry() {
  local receipt="$1" old_identity="$2" registry="$3"
  [ -f "$receipt" ] && [ ! -L "$receipt" ] \
    && [ -f "$old_identity" ] && [ ! -L "$old_identity" ] \
    && [ -f "$registry" ] && [ ! -L "$registry" ] \
    || return 1
  [ "$(json_get "$receipt" schema)" = "TatwoDeviceKeyRotationReceiptV1" ] \
    && [ "$(json_get "$receipt" deviceID)" = "$(json_get "$old_identity" deviceID)" ] \
    && [ "$(json_get "$receipt" oldKeyID)" = "$(json_get "$old_identity" keyID)" ] \
    && [ "$(json_number_get "$receipt" oldKeyGeneration)" \
      = "$(json_number_get "$old_identity" keyGeneration)" ] \
    || return 1
  local key
  for key in schema algorithm deviceID keyID publicKey keyStatus pinnedAt; do
    [ "$(plutil -extract "newIdentity.$key" raw "$receipt" 2>/dev/null || true)" \
      = "$(json_get "$registry" "$key")" ] \
      || return 1
  done
  [ "$(plutil -extract newIdentity.keyGeneration raw "$receipt" 2>/dev/null || true)" \
    = "$(json_number_get "$registry" keyGeneration)" ]
}

record_device_trust_rotation_acceptance() {
  local name="$1" old_identity="$2" registry="$3" receipt="$4"
  local generation root final stage accepted_at
  generation="$(json_number_get "$registry" keyGeneration)"
  root="$APP_SUPPORT/device-trust/accepted-rotations/$name"
  final="$root/$generation.json"
  stage="$root/.$generation.$$.tmp"
  accepted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$root" || return 1
  cat >"$stage" <<EOF
{
  "schema": "TatwoDeviceTrustRotationAcceptanceV1",
  "deviceName": "$(json_escape "$name")",
  "deviceID": "$(json_escape "$(json_get "$registry" deviceID)")",
  "oldKeyID": "$(json_escape "$(json_get "$old_identity" keyID)")",
  "oldKeyGeneration": $(json_number_get "$old_identity" keyGeneration),
  "newKeyID": "$(json_escape "$(json_get "$registry" keyID)")",
  "newKeyGeneration": $generation,
  "rotationReceiptPath": "$(json_escape "${receipt#"$CHANNEL_DIR"/}")",
  "rotationReceiptDigest": "$(sha256_file "$receipt")",
  "acceptedAt": "$accepted_at"
}
EOF
  [ "$(json_get "$stage" schema)" \
    = "TatwoDeviceTrustRotationAcceptanceV1" ] \
    || return 1
  chmod 600 "$stage" 2>/dev/null || true
  mv "$stage" "$final"
}

refresh_peer_pin_from_rotation() {
  local name="$1" expected_device_id="$2"
  local registry pin old_generation new_generation receipt pin_stage
  registry="$(registered_device_file "$name")"
  pin="$(device_trust_peer_pin_file "$name")"
  validate_registered_device_trust "$name" "$expected_device_id" \
    && validate_device_trust_identity_file "$pin" "$expected_device_id" \
    || return 1
  old_generation="$(json_number_get "$pin" keyGeneration)"
  new_generation="$(json_number_get "$registry" keyGeneration)"
  case "$old_generation:$new_generation" in
    *[!0-9:]*|:*|*:) return 1;;
  esac
  [ "$new_generation" -eq $((old_generation + 1)) ] || return 1
  receipt="$(device_trust_rotation_receipt_file "$name" "$new_generation")" \
    || return 1
  device_trust_rotation_matches_registry "$receipt" "$pin" "$registry" \
    || return 1
  run_device_trust_cli verify-rotation \
    --old-registry "$pin" \
    --receipt "$receipt" >/dev/null \
    || return 1
  pin_stage="$(dirname "$pin")/.$name.rotation.$$.tmp"
  cp "$registry" "$pin_stage" || return 1
  chmod 600 "$pin_stage" 2>/dev/null || true
  validate_device_trust_identity_file "$pin_stage" "$expected_device_id" \
    && device_trust_identity_files_match "$pin_stage" "$registry" \
    || return 1
  record_device_trust_rotation_acceptance \
    "$name" "$pin" "$registry" "$receipt" \
    || return 1
  mv "$pin_stage" "$pin"
}

validate_registered_device_trust() {
  local name="$1" expected_device_id="$2" registry
  registry="$(registered_device_file "$name")"
  [ -f "$registry" ] && [ ! -L "$registry" ] \
    && [ "$(json_get "$registry" deviceId)" = "$expected_device_id" ] \
    && validate_device_trust_identity_file "$registry" "$expected_device_id"
}

ensure_device_trust_identity() {
  ensure_device_identity
  local device_id identity
  device_id="$(json_get "$(device_identity_file)" deviceId)"
  [ -n "$device_id" ] || die "本機 device identity 缺少 deviceId"
  identity="$(device_trust_identity_file)"
  if [ ! -f "$identity" ]; then
    mkdir -p "$(dirname "$identity")"
    run_device_trust_cli ensure \
      --device-id "$device_id" \
      --generation 1 \
      --output "$identity" >/dev/null \
      || die "無法建立本機 Ed25519 device trust identity"
    chmod 600 "$identity" 2>/dev/null || true
  fi
  validate_device_trust_identity_file "$identity" "$device_id" \
    || die "本機 device trust identity 無效、已撤銷或與 deviceId 不符"
  run_device_trust_cli assert-local --registry "$identity" >/dev/null \
    || die "本機 device trust private key 缺失或與 identity 不符"
}

pin_registered_device_trust() {
  local name="$1" expected_device_id="$2" registry pin pin_stage
  validate_registered_device_trust "$name" "$expected_device_id" || return 1
  registry="$(registered_device_file "$name")"
  if [ "$name" = "$DEVICE_NAME" ]; then
    ensure_device_trust_identity
    device_trust_identity_files_match "$registry" "$(device_trust_identity_file)"
    return
  fi
  pin="$(device_trust_peer_pin_file "$name")"
  if [ -f "$pin" ]; then
    validate_device_trust_identity_file "$pin" "$expected_device_id" \
      || return 1
    if device_trust_identity_files_match "$pin" "$registry"; then
      return 0
    fi
    refresh_peer_pin_from_rotation "$name" "$expected_device_id"
    return
  fi
  mkdir -p "$(dirname "$pin")" || return 1
  pin_stage="$(dirname "$pin")/.$name.$$.tmp"
  cp "$registry" "$pin_stage" || return 1
  chmod 600 "$pin_stage" 2>/dev/null || true
  validate_device_trust_identity_file "$pin_stage" "$expected_device_id" \
    && device_trust_identity_files_match "$pin_stage" "$registry" \
    || return 1
  mv "$pin_stage" "$pin"
}

trusted_device_identity_file() {
  local name="$1" expected_device_id="$2" trusted
  validate_registered_device_trust "$name" "$expected_device_id" || return 1
  if [ "$name" = "$DEVICE_NAME" ]; then
    trusted="$(device_trust_identity_file)"
  else
    trusted="$(device_trust_peer_pin_file "$name")"
    if ! device_trust_identity_files_match \
      "$trusted" "$(registered_device_file "$name")"
    then
      refresh_peer_pin_from_rotation "$name" "$expected_device_id" \
        || return 1
      trusted="$(device_trust_peer_pin_file "$name")"
    fi
  fi
  validate_device_trust_identity_file "$trusted" "$expected_device_id" \
    && device_trust_identity_files_match \
      "$trusted" "$(registered_device_file "$name")" \
    || return 1
  printf '%s\n' "$trusted"
}

sign_channel_artifact() {
  local purpose="$1" input="$2" signature_output="$3"
  local local_device_id registry identity
  ensure_device_trust_identity
  local_device_id="$(json_get "$(device_identity_file)" deviceId)"
  registry="$(registered_device_file "$DEVICE_NAME")"
  validate_registered_device_trust "$DEVICE_NAME" "$local_device_id" \
    && device_trust_identity_files_match \
      "$registry" "$(device_trust_identity_file)" \
    || return 1
  identity="$(device_trust_identity_file)"
  run_device_trust_cli sign \
    --purpose "$purpose" \
    --registry "$identity" \
    --input "$input" \
    --signature-out "$signature_output" >/dev/null
}

verify_channel_artifact_signature() {
  local device_name="$1" device_id="$2" purpose="$3" input="$4" signature="$5"
  local trusted
  [ -f "$input" ] && [ ! -L "$input" ] \
    && [ -f "$signature" ] && [ ! -L "$signature" ] \
    || return 1
  trusted="$(trusted_device_identity_file "$device_name" "$device_id")" \
    || return 1
  run_device_trust_cli verify \
    --purpose "$purpose" \
    --registry "$trusted" \
    --input "$input" \
    --signature "$signature" >/dev/null
}

load_runtime_fallback_authorization() {
  SKILLET_FALLBACK_AUTHORIZATION_ID=""
  SKILLET_FALLBACK_AUTHORIZATION_PATH=""
  SKILLET_FALLBACK_AUTHORIZATION_DIGEST=""
  read_primary_state
  [ -n "$PRIMARY_FALLBACK_AUTHORIZATION_PATH" ] || return 0

  local authorization="$CHANNEL_DIR/$PRIMARY_FALLBACK_AUTHORIZATION_PATH"
  local signature="$CHANNEL_DIR/$PRIMARY_FALLBACK_AUTHORIZATION_SIGNATURE_PATH"
  local previous_device_id actual_digest
  [ -f "$authorization" ] && [ ! -L "$authorization" ] \
    && [ -f "$signature" ] && [ ! -L "$signature" ] \
    || {
      log "runtime fallback authorization 或 signature 不存在"
      return 1
    }
  actual_digest="$(sha256_file "$authorization")" || return 1
  [ "$actual_digest" = "$PRIMARY_FALLBACK_AUTHORIZATION_DIGEST" ] \
    || {
      log "runtime fallback authorization digest 與 primary binding 不一致"
      return 1
    }
  [ "$(json_get "$authorization" schema)" = \
      "TatwoSkilletRuntimeFallbackAuthorizationV1" ] \
    && [ "$(json_get "$authorization" authorizationID)" = \
      "$PRIMARY_FALLBACK_AUTHORIZATION_ID" ] \
    && [ "$(json_get "$authorization" sourceMode)" = "runtime-fallback" ] \
    && [ "$(json_get "$authorization" authorizedDeviceName)" = "$PRIMARY_NAME" ] \
    && [ "$(json_get "$authorization" authorityPrimary)" = "$PRIMARY_NAME" ] \
    && [ "$(json_number_get "$authorization" authorityEpoch)" = "$PRIMARY_EPOCH" ] \
    && [ "$(json_get "$authorization" previousAuthorityPrimary)" = \
      "$PRIMARY_PREVIOUS_NAME" ] \
    && [ "$(json_number_get "$authorization" previousAuthorityEpoch)" = \
      "$PRIMARY_PREVIOUS_EPOCH" ] \
    && [ "$(json_get "$authorization" authorizedByDeviceName)" = \
      "$PRIMARY_PREVIOUS_NAME" ] \
    && [ "$(json_get "$authorization" scope)" = "authority-epoch" ] \
    && [ "$(json_get "$authorization" signaturePurpose)" = \
      "skillet-runtime-fallback-authorization" ] \
    && [ "$(json_get "$authorization" signaturePath)" = \
      "$PRIMARY_FALLBACK_AUTHORIZATION_SIGNATURE_PATH" ] \
    || {
      log "runtime fallback authorization schema/epoch/device binding 不一致"
      return 1
    }
  [ -n "$PRIMARY_PREVIOUS_NAME" ] \
    && [ "$PRIMARY_PREVIOUS_EPOCH" -lt "$PRIMARY_EPOCH" ] \
    && [ $((PRIMARY_PREVIOUS_EPOCH + 1)) -eq "$PRIMARY_EPOCH" ] \
    || {
      log "runtime fallback authorization 不是連續 authority epoch"
      return 1
    }
  previous_device_id="$(registered_device_id "$PRIMARY_PREVIOUS_NAME")"
  [ -n "$previous_device_id" ] \
    && [ "$(json_get "$authorization" authorizedByDeviceID)" = \
      "$previous_device_id" ] \
    || {
      log "runtime fallback authorization signer device identity 不一致"
      return 1
    }
  local authorized_device_id
  authorized_device_id="$(registered_device_id "$PRIMARY_NAME")"
  [ -n "$authorized_device_id" ] \
    && [ "$(json_get "$authorization" authorizedDeviceID)" = \
      "$authorized_device_id" ] \
    || {
      log "runtime fallback authorization target device identity 不一致"
      return 1
    }
  verify_channel_artifact_signature \
    "$PRIMARY_PREVIOUS_NAME" "$previous_device_id" \
    "skillet-runtime-fallback-authorization" "$authorization" "$signature" \
    || {
      log "runtime fallback authorization signature 無效、未 pin 或已撤銷"
      return 1
    }

  SKILLET_FALLBACK_AUTHORIZATION_ID="$PRIMARY_FALLBACK_AUTHORIZATION_ID"
  SKILLET_FALLBACK_AUTHORIZATION_PATH="$PRIMARY_FALLBACK_AUTHORIZATION_PATH"
  SKILLET_FALLBACK_AUTHORIZATION_DIGEST="$actual_digest"
}

validate_skillet_source_provenance() {
  local source_mode="$1" inventory_digest="$2" fallback_id="$3"
  local fallback_path="$4" fallback_digest="$5"
  is_sha256_digest "$inventory_digest" \
    || { log "Skillet inventory digest 不合法"; return 1; }
  case "$source_mode" in
    canonical)
      [ -z "$fallback_id" ] && [ -z "$fallback_path" ] && [ -z "$fallback_digest" ] \
        || {
          log "canonical source 不得攜帶 runtime fallback authorization"
          return 1
        }
      ;;
    runtime-fallback)
      case "$fallback_id" in
        ""|.|..|*/*|*[!A-Za-z0-9._:-]*)
          log "runtime fallback authorization ID 不安全"
          return 1
          ;;
      esac
      [ "$fallback_path" = \
        "$(runtime_fallback_authorization_relative_path "$PRIMARY_NAME" "$PRIMARY_EPOCH")" ] \
        && is_sha256_digest "$fallback_digest" \
        || {
          log "runtime fallback authorization path/digest 不合法"
          return 1
        }
      ;;
    *)
      log "Skillet sourceMode 不合法：${source_mode:-missing}"
      return 1
      ;;
  esac
}

validate_request_skillet_source_provenance() {
  local source_mode="$1" inventory_digest="$2" fallback_id="$3"
  local fallback_path="$4" fallback_digest="$5"
  validate_skillet_source_provenance \
    "$source_mode" "$inventory_digest" "$fallback_id" "$fallback_path" "$fallback_digest" \
    || return 1
  if [ "$source_mode" = "runtime-fallback" ]; then
    load_runtime_fallback_authorization || return 1
    [ "$fallback_id" = "$SKILLET_FALLBACK_AUTHORIZATION_ID" ] \
      && [ "$fallback_path" = "$SKILLET_FALLBACK_AUTHORIZATION_PATH" ] \
      && [ "$fallback_digest" = "$SKILLET_FALLBACK_AUTHORIZATION_DIGEST" ] \
      || {
        log "request runtime fallback authorization 與目前 authority receipt 不一致"
        return 1
      }
  fi
}

cleanup_committed_system_transients() {
  local id="$1" stage_dir="$2" os_candidate="$3"
  local expected_stage="$HOT_SYNC_STAGING/$id"
  local candidate_parent="$HOT_SYNC_MIRROR/.tatwo-sync-candidates/$id"
  [ "$stage_dir" = "$expected_stage" ] \
    || { log "拒絕清除非 request-bound system staging：$stage_dir"; return 1; }
  [ "$os_candidate" = "$candidate_parent/os" ] \
    || { log "拒絕清除非 request-bound OS candidate：$os_candidate"; return 1; }
  if [ -e "$stage_dir" ]; then
    [ -d "$stage_dir" ] && [ ! -L "$stage_dir" ] \
      || { log "system staging 不是安全目錄：$stage_dir"; return 1; }
    rm -r "$stage_dir" || return 1
  fi
  if [ -e "$os_candidate" ]; then
    log "committed transaction 的 OS candidate 仍存在：$os_candidate"
    return 1
  fi
  if [ -d "$candidate_parent" ]; then
    rmdir "$candidate_parent" \
      || { log "OS candidate parent 非空，拒絕靜默刪除：$candidate_parent"; return 1; }
  elif [ -e "$candidate_parent" ]; then
    log "OS candidate parent 不是目錄：$candidate_parent"
    return 1
  fi
}

system_item_source_file() {
  case "$OS_ROOT" in
    "")
      log "TATWO_OS_ROOT 未設定；system-pull 不得猜測私人 Work OS 路徑"
      return 1
      ;;
    /*) ;;
    *)
      log "TATWO_OS_ROOT 必須是絕對路徑"
      return 1
      ;;
  esac
  case "$1" in
    os.constitution) printf '%s\n' "$OS_ROOT/os.md";;
    skills.skillet) printf '%s\n' "$OS_ROOT/skillet.md";;
    memory.global-notes) printf '%s\n' "$OS_ROOT/note";;
    os.issue|os.todo) return 1;; # C documents are git-owned; never read entrance legacy files.
    *) return 1;;
  esac
}

system_item_display_name() {
  case "$1" in
    os.constitution) printf '%s\n' "Work OS constitution";;
    os.issue) printf '%s\n' "Work OS issue blueprint";;
    os.todo) printf '%s\n' "Work OS implementation backlog";;
    skills.skillet) printf '%s\n' "Skillet private skill repositories";;
    *) return 1;;
  esac
}

system_item_mirror_path() {
  case "$1" in
    os.constitution) printf '%s\n' "os/os.md";;
    os.issue) printf '%s\n' "os/issue.md";;
    os.todo) printf '%s\n' "os/TODO.md";;
    skills.skillet) printf '%s\n' "skillet/repositories";;
    *) return 1;;
  esac
}

system_item_payload_path() {
  case "$1" in
    os.constitution|os.issue|os.todo) printf 'items/%s/content\n' "$1";;
    skills.skillet) printf 'items/skills.skillet/set.json\n';;
    *) return 1;;
  esac
}

write_skillet_source_refresh_attempt_receipt() {
  local receipt="$1" outcome="$2" message="${3:-}"
  local source_name="${4:-canonical-source-discovery}"
  local display_name="${5:-Skillet canonical source discovery}"
  local completed_at stage result_json
  completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  stage="${receipt}.$$.tmp"
  mkdir -p "$(dirname "$receipt")"
  if [ "$outcome" = "started" ]; then
    result_json='[]'
  else
    result_json="$(
      cat <<EOF
[
    {
      "sourceName": "$(json_escape "$source_name")",
      "repositoryID": "",
      "displayName": "$(json_escape "$display_name")",
      "status": "failed",
      "message": "$(json_escape "$message")"
    }
  ]
EOF
    )"
  fi
  cat >"$stage" <<EOF
{
  "schema": "TatwoSkilletCanonicalRefreshReceiptV1",
  "evidenceKind": "local-source-refresh-attempt",
  "attemptID": "$(json_escape "$SKILLET_REFRESH_ATTEMPT_ID")",
  "target": "$(json_escape "$SKILLET_REFRESH_TARGET")",
  "action": "system-pull",
  "requestedAt": "$(json_escape "$SKILLET_REFRESH_REQUESTED_AT")",
  "currentDeviceName": "$(json_escape "$DEVICE_NAME")",
  "currentDeviceID": "$(json_escape "$SKILLET_REFRESH_CURRENT_DEVICE_ID")",
  "authorityPrimary": "$(json_escape "$SKILLET_REFRESH_AUTHORITY_PRIMARY")",
  "authorityEpoch": $SKILLET_REFRESH_AUTHORITY_EPOCH,
  "ledgerSequence": $SKILLET_REFRESH_LEDGER_SEQUENCE,
  "catalogRevision": "$(json_escape "$SKILLET_REFRESH_CATALOG_REVISION")",
  "sourceDeviceID": "$(json_escape "$SKILLET_REFRESH_SOURCE_DEVICE_ID")",
  "targetDeviceID": "$(json_escape "$SKILLET_REFRESH_TARGET_DEVICE_ID")",
  "outcome": "$(json_escape "$outcome")",
  "dryRun": false,
  "channel": "staging",
  "sourceMode": "unresolved",
  "storeMutation": "not-started",
  "activationMethod": "not-requested",
  "previousStoreCleanup": "not-requested",
  "inventoryDigest": "",
  "fallbackAuthorizationID": "",
  "fallbackAuthorizationPath": "",
  "fallbackAuthorizationDigest": "",
  "discoveredSourceCount": 0,
  "refreshedCount": 0,
  "failedCount": $([ "$outcome" = "started" ] && printf '0' || printf '1'),
  "expectedRepositoryIDs": [],
  "actualRepositoryIDs": [],
  "missingRepositoryIDs": [],
  "staleRepositoryIDs": [],
  "retiredRepositoryIDs": [],
  "retirements": [],
  "results": $result_json,
  "message": "$(json_escape "$message")",
  "startedAt": "$(json_escape "$SKILLET_REFRESH_REQUESTED_AT")",
  "completedAt": "$(json_escape "$completed_at")"
}
EOF
  chmod 600 "$stage" 2>/dev/null || true
  mv "$stage" "$receipt"
}

fail_skillet_source_refresh_attempt() {
  local receipt="$1" message="$2"
  local source_name="${3:-canonical-source-discovery}"
  local display_name="${4:-Skillet canonical source discovery}"
  write_skillet_source_refresh_attempt_receipt \
    "$receipt" failed "$message" "$source_name" "$display_name" \
    || log "Skillet source refresh failure receipt 寫入失敗：$SKILLET_REFRESH_ATTEMPT_ID"
  log "$message"
  return 1
}

refresh_canonical_skillet_sources() {
  local receipt="$1" attempt_id="$2" target_name="$3" requested_at="$4"
  local catalog_revision="$5" source_device_id="$6" target_device_id="$7"
  local ledger_sequence="$8" current_device_id="$9" refresh_required_bytes=0
  SKILLET_SOURCE_MODE=""
  SKILLET_INVENTORY_DIGEST=""
  SKILLET_FALLBACK_AUTHORIZATION_ID=""
  SKILLET_FALLBACK_AUTHORIZATION_PATH=""
  SKILLET_FALLBACK_AUTHORIZATION_DIGEST=""
  case "$SKILLET_AUTO_REFRESH" in
    1) ;;
    0)
      SKILLET_SOURCE_MODE="canonical"
      SKILLET_INVENTORY_DIGEST="$(
        if [ -d "$SKILLET_STORE/repositories" ]; then
          find "$SKILLET_STORE/repositories" \
            -mindepth 2 -maxdepth 2 -type f -name repository.json -print \
            | while IFS= read -r metadata; do basename "$(dirname "$metadata")"; done \
            | LC_ALL=C sort
        fi \
          | shasum -a 256 \
          | awk '{print $1}'
      )"
      is_sha256_digest "$SKILLET_INVENTORY_DIGEST" \
        || die "Skillet prebuilt store inventory digest 無法建立"
      return 0
      ;;
    *) die "TATWO_SKILLET_AUTO_REFRESH 只能是 0 或 1";;
  esac
  SKILLET_REFRESH_ATTEMPT_ID="$attempt_id"
  SKILLET_REFRESH_TARGET="$target_name"
  SKILLET_REFRESH_REQUESTED_AT="$requested_at"
  SKILLET_REFRESH_AUTHORITY_EPOCH="$PRIMARY_EPOCH"
  SKILLET_REFRESH_LEDGER_SEQUENCE="$ledger_sequence"
  SKILLET_REFRESH_AUTHORITY_PRIMARY="$PRIMARY_NAME"
  SKILLET_REFRESH_SOURCE_DEVICE_ID="$source_device_id"
  SKILLET_REFRESH_TARGET_DEVICE_ID="$target_device_id"
  SKILLET_REFRESH_CATALOG_REVISION="$catalog_revision"
  SKILLET_REFRESH_CURRENT_DEVICE_ID="$current_device_id"
  write_skillet_source_refresh_attempt_receipt \
    "$receipt" started "本機正在刷新 canonical Skillet sources；尚未發布 request。" \
    || {
      log "無法持久化 Skillet source refresh attempt；拒絕繼續"
      return 1
    }
  [ "$SKILLET_SOURCE_ROOT_EXPLICIT" = "1" ] \
    || {
      fail_skillet_source_refresh_attempt \
        "$receipt" "Skillet helper 缺少明確 source root；請重新執行設備納管" \
        "canonical-source-root" "Canonical Skills source root"
      return 1
    }
  [ "$SKILLET_RUNTIME_ROOT_EXPLICIT" = "1" ] \
    || {
      fail_skillet_source_refresh_attempt \
        "$receipt" "Skillet helper 仍是舊版 runtime 設定；請重新執行設備納管" \
        "runtime-source-root" "Managed Skills runtime root"
      return 1
    }
  case "${SKILLET_SOURCE_ROOT%/}/" in
    "${SKILLET_RUNTIME_ROOT%/}/"*)
      fail_skillet_source_refresh_attempt \
        "$receipt" "Skillet canonical source 不得位於 runtime root 內" \
        "canonical-source-root" "Canonical Skills source root"
      return 1
      ;;
  esac
  case "${SKILLET_RUNTIME_ROOT%/}/" in
    "${SKILLET_SOURCE_ROOT%/}/"*)
      fail_skillet_source_refresh_attempt \
        "$receipt" "Skillet runtime root 不得位於 canonical source 內" \
        "runtime-source-root" "Managed Skills runtime root"
      return 1
      ;;
  esac
  [ -f "$SKILLET_REFRESH_SCRIPT" ] \
    || {
      fail_skillet_source_refresh_attempt \
        "$receipt" "Skillet canonical refresh script 不存在" \
        "source-refresh-runtime" "Skillet source refresh runtime"
      return 1
    }
  [ -f "$SKILLET_SOURCE_REGISTRY" ] \
    || {
      fail_skillet_source_refresh_attempt \
        "$receipt" "Skillet source registry 不存在" \
        "source-registry" "Skillet source registry"
      return 1
    }
  if [ ! -d "$SKILLET_SOURCE_ROOT" ] \
    && [ ! -d "$SKILLET_SOURCE_FALLBACK_ROOT" ]
  then
    fail_skillet_source_refresh_attempt \
      "$receipt" "Skillet canonical source 與 runtime fallback 都不存在" \
      "canonical-source-root" "Canonical Skills source root"
    return 1
  fi
  command -v node >/dev/null 2>&1 \
    || {
      fail_skillet_source_refresh_attempt \
        "$receipt" "Skillet canonical refresh 需要 node" \
        "source-refresh-runtime" "Skillet source refresh runtime"
      return 1
    }
  command -v "$SKILLET_PYTHON" >/dev/null 2>&1 \
    || {
      fail_skillet_source_refresh_attempt \
        "$receipt" "Skillet canonical refresh 需要可用的 python3" \
        "source-refresh-runtime" "Skillet source refresh runtime"
      return 1
    }
  "$SKILLET_PYTHON" -c 'import fcntl' >/dev/null 2>&1 \
    || {
      fail_skillet_source_refresh_attempt \
        "$receipt" "Skillet canonical refresh 的 python3 缺少可用 fcntl" \
        "source-refresh-runtime" "Skillet source refresh runtime"
      return 1
    }
  if [ -d "$SKILLET_STORE" ]; then
    refresh_required_bytes="$(directory_allocated_bytes "$SKILLET_STORE")" \
      || {
        fail_skillet_source_refresh_attempt \
          "$receipt" "無法量測 Skillet store 大小" \
          "skillet-store" "Skillet repository store"
        return 1
      }
  fi
  require_available_space \
    "$(dirname "$SKILLET_STORE")" \
    "$refresh_required_bytes" \
    "Skillet staged refresh" \
    || {
      fail_skillet_source_refresh_attempt \
        "$receipt" "Skillet staged refresh 磁碟空間不足" \
        "skillet-store" "Skillet repository store"
      return 1
    }
  load_runtime_fallback_authorization \
    || {
      fail_skillet_source_refresh_attempt \
        "$receipt" "runtime fallback authorization 無法驗證" \
        "runtime-fallback-authorization" "Runtime fallback authorization"
      return 1
    }
  local refresh_args=()
  refresh_args=(
      --source-root "$SKILLET_SOURCE_ROOT" \
      --fallback-source-root "$SKILLET_SOURCE_FALLBACK_ROOT" \
      --store "$SKILLET_STORE" \
      --registry "$SKILLET_SOURCE_REGISTRY" \
      --cli "$SKILLET_CLI" \
      --receipt "$receipt" \
      --channel staging \
      --current-device-name "$DEVICE_NAME" \
      --current-device-id "$current_device_id" \
      --authority-primary "$PRIMARY_NAME" \
      --authority-epoch "$PRIMARY_EPOCH" \
      --attempt-id "$attempt_id" \
      --target "$target_name" \
      --action system-pull \
      --requested-at "$requested_at" \
      --ledger-sequence "$ledger_sequence" \
      --catalog-revision "$catalog_revision" \
      --source-device-id "$source_device_id" \
      --target-device-id "$target_device_id"
  )
  if [ -n "$SKILLET_FALLBACK_AUTHORIZATION_PATH" ]; then
    refresh_args+=(
      --fallback-authorization "$CHANNEL_DIR/$SKILLET_FALLBACK_AUTHORIZATION_PATH"
      --fallback-authorization-path "$SKILLET_FALLBACK_AUTHORIZATION_PATH"
      --fallback-authorization-digest "$SKILLET_FALLBACK_AUTHORIZATION_DIGEST"
    )
  fi
  if ! TATWO_PYTHON3="$SKILLET_PYTHON" node "$SKILLET_REFRESH_SCRIPT" \
      "${refresh_args[@]}" --json >/dev/null
  then
    log "Skillet canonical source refresh 未收斂；local attempt receipt 已保留"
    return 1
  fi
  [ "$(json_get "$receipt" schema)" = "TatwoSkilletCanonicalRefreshReceiptV1" ] \
    || {
      fail_skillet_source_refresh_attempt \
        "$receipt" "Skillet canonical refresh receipt schema 不合法"
      return 1
    }
  [ "$(json_get "$receipt" outcome)" = "converged" ] \
    || {
      fail_skillet_source_refresh_attempt \
        "$receipt" "Skillet canonical refresh receipt 未收斂"
      return 1
    }
  SKILLET_SOURCE_MODE="$(json_get "$receipt" sourceMode)"
  SKILLET_INVENTORY_DIGEST="$(json_get "$receipt" inventoryDigest)"
  SKILLET_FALLBACK_AUTHORIZATION_ID="$(json_get "$receipt" fallbackAuthorizationID)"
  SKILLET_FALLBACK_AUTHORIZATION_PATH="$(json_get "$receipt" fallbackAuthorizationPath)"
  SKILLET_FALLBACK_AUTHORIZATION_DIGEST="$(json_get "$receipt" fallbackAuthorizationDigest)"
  validate_skillet_source_provenance \
    "$SKILLET_SOURCE_MODE" "$SKILLET_INVENTORY_DIGEST" \
    "$SKILLET_FALLBACK_AUTHORIZATION_ID" "$SKILLET_FALLBACK_AUTHORIZATION_PATH" \
    "$SKILLET_FALLBACK_AUTHORIZATION_DIGEST" \
    || {
      fail_skillet_source_refresh_attempt \
        "$receipt" "Skillet canonical refresh receipt source provenance 不合法"
      return 1
    }
}

prepare_skillet_payload() {
  local payload_root="$1" id="$2" catalog_revision="$3" source_device_id="$4"
  local authority_epoch="$5" target_device_id="$6" ledger_sequence="$7"
  local skillet_payload="$payload_root/items/skills.skillet"
  local set_manifest="$skillet_payload/set.json"
  local receipt_root="$APP_SUPPORT/device-sync-state/skillet-export-receipts/$id"
  local repository_id repository_payload export_receipt
  local revision_id content_digest bundle_digest index=0 repository_count
  if [ -d "$SKILLET_STORE/repositories" ]; then
    repository_count="$(
      find "$SKILLET_STORE/repositories" \
        -mindepth 2 -maxdepth 2 -type f -name repository.json -print 2>/dev/null \
        | wc -l | tr -d ' '
    )"
  else
    repository_count=0
  fi
  validate_nonnegative_integer "$repository_count" \
    && [ "$repository_count" -gt 0 ] \
    || die "Skillet repository set is empty；system-pull 必須至少包含一個受管 repository"
  mkdir -p "$skillet_payload/repositories" "$receipt_root"
  cat >"$set_manifest" <<EOF
{
  "schemaVersion": 1,
  "requestID": "$id",
  "catalogRevision": "$catalog_revision",
  "authorityEpoch": $authority_epoch,
  "ledgerSequence": $ledger_sequence,
  "sourceDeviceID": "$source_device_id",
  "targetDeviceID": "$target_device_id",
  "sourceMode": "$(json_escape "$SKILLET_SOURCE_MODE")",
  "inventoryDigest": "$(json_escape "$SKILLET_INVENTORY_DIGEST")",
  "fallbackAuthorizationID": "$(json_escape "$SKILLET_FALLBACK_AUTHORIZATION_ID")",
  "fallbackAuthorizationPath": "$(json_escape "$SKILLET_FALLBACK_AUTHORIZATION_PATH")",
  "fallbackAuthorizationDigest": "$(json_escape "$SKILLET_FALLBACK_AUTHORIZATION_DIGEST")",
  "repositories": [
EOF
  while IFS= read -r repository_id; do
    case "$repository_id" in
      ""|.|..|*/*|*[!A-Za-z0-9._:-]*)
        die "Skillet repository id 不安全：${repository_id:-missing}"
        ;;
    esac
    repository_payload="$skillet_payload/repositories/$repository_id"
    export_receipt="$receipt_root/$repository_id.json"
    mkdir -p "$repository_payload"
    run_skillet_cli skillet export-bound \
      --store "$SKILLET_STORE" \
      --repository "$repository_id" \
      --bundle "$repository_payload/bundle" \
      --binding "$repository_payload/authority-binding.json" \
      --request "$id" \
      --source-device "$source_device_id" \
      --target-device "$target_device_id" \
      --authority-epoch "$authority_epoch" \
      --ledger-sequence "$ledger_sequence" \
      --catalog-revision "$catalog_revision" \
      --receipt "$export_receipt" \
      --json >/dev/null
    revision_id="$(json_get "$export_receipt" revisionID)"
    content_digest="$(json_get "$export_receipt" contentDigest)"
    bundle_digest="$(json_get "$export_receipt" bundleDigest)"
    [ "$(json_get "$export_receipt" repositoryID)" = "$repository_id" ] \
      || die "Skillet export receipt repository 不一致：$repository_id"
    is_sha256_digest "$content_digest" \
      || die "Skillet export content digest 不合法：$repository_id"
    is_sha256_digest "$bundle_digest" \
      || die "Skillet export bundle digest 不合法：$repository_id"
    case "$revision_id" in rev-[0-9a-f][0-9a-f]*) ;; *)
      die "Skillet export revision id 不合法：$repository_id"
      ;;
    esac
    [ "$index" -eq 0 ] || printf ',\n' >>"$set_manifest"
    cat >>"$set_manifest" <<EOF
    {
      "repositoryID": "$repository_id",
      "revisionID": "$revision_id",
      "contentDigest": "$content_digest",
      "bundleDigest": "$bundle_digest",
      "bundleRelativePath": "repositories/$repository_id/bundle",
      "bindingRelativePath": "repositories/$repository_id/authority-binding.json"
    }
EOF
    index=$((index + 1))
  done < <(
    find "$SKILLET_STORE/repositories" \
      -mindepth 2 -maxdepth 2 -type f -name repository.json -print 2>/dev/null \
      | while IFS= read -r metadata; do
          basename "$(dirname "$metadata")"
        done \
      | LC_ALL=C sort
  )
  cat >>"$set_manifest" <<EOF
  ]
}
EOF
  SKILLET_SET_DIGEST="$(sha256_file "$set_manifest")"
  SKILLET_SET_BYTES="$(file_byte_count "$set_manifest")"
  SKILLET_SET_REPOSITORY_COUNT="$index"
}

prepare_system_payload() {
  # Guard in the caller too: a failure inside < <(...) is not propagated by bash.
  legacy_system_adapter_available || die "legacy system adapter retired"
  local id="$1" catalog_revision="$2" source_device_id="$3" authority_epoch="$4"
  local target_device_id="$5" ledger_sequence="$6" target_name="$7" requested_at="$8"
  local final_payload_root="$CHANNEL_DIR/payloads/$id"
  local payload_stage_root
  payload_stage_root="$(
    git -C "$CHANNEL_DIR" rev-parse \
      --path-format=absolute --git-path tatwo-payload-staging
  )" || die "無法解析同步通道的 payload staging 路徑"
  REQUEST_PAYLOAD_STAGE_ROOT="$payload_stage_root"
  REQUEST_PAYLOAD_STAGE="$payload_stage_root/$id.$$"
  local payload_root="$REQUEST_PAYLOAD_STAGE"
  local manifest="$payload_root/manifest.json"
  local required_ids=()
  while IFS= read -r item_id; do
    required_ids+=("$item_id")
  done < <(system_required_item_ids)
  local item_id source_file payload_relative payload_file
  local display_name mirror_relative source_digest byte_count repository_count index=0
  [ ! -e "$final_payload_root" ] \
    || die "system-pull payload 已存在，拒絕覆寫：$id"
  [ ! -e "$payload_root" ] \
    || die "system-pull payload staging 已存在，拒絕覆寫：$id"
  mkdir -p "$payload_root"
  refresh_canonical_skillet_sources \
    "$APP_SUPPORT/device-sync-state/skillet-export-receipts/$id/canonical-refresh.json" \
    "$id" "$target_name" "$requested_at" "$catalog_revision" \
    "$source_device_id" "$target_device_id" "$ledger_sequence" "$source_device_id" \
    || die "Skillet canonical source refresh failed; request publication blocked"
  cat >"$manifest" <<EOF
{
  "schemaVersion": 1,
  "requestID": "$id",
  "catalogRevision": "$catalog_revision",
  "authorityEpoch": $authority_epoch,
  "ledgerSequence": $ledger_sequence,
  "authorityPrimary": "$DEVICE_NAME",
  "sourceDeviceID": "$source_device_id",
  "targetDeviceID": "$target_device_id",
  "sourceMode": "$(json_escape "$SKILLET_SOURCE_MODE")",
  "inventoryDigest": "$(json_escape "$SKILLET_INVENTORY_DIGEST")",
  "fallbackAuthorizationID": "$(json_escape "$SKILLET_FALLBACK_AUTHORIZATION_ID")",
  "fallbackAuthorizationPath": "$(json_escape "$SKILLET_FALLBACK_AUTHORIZATION_PATH")",
  "fallbackAuthorizationDigest": "$(json_escape "$SKILLET_FALLBACK_AUTHORIZATION_DIGEST")",
  "items": [
EOF
  for item_id in "${required_ids[@]}"; do
    grep -Eq "\"id\"[[:space:]]*:[[:space:]]*\"$item_id\"" "$SYNC_CATALOG" \
      || die "同步 catalog 未登錄 ${item_id}，拒絕產生 payload"
    payload_relative="$(system_item_payload_path "$item_id")"
    payload_file="$payload_root/$payload_relative"
    display_name="$(system_item_display_name "$item_id")"
    mirror_relative="$(system_item_mirror_path "$item_id")"
    repository_count=""
    if [ "$item_id" = "skills.skillet" ]; then
      prepare_skillet_payload \
        "$payload_root" "$id" "$catalog_revision" "$source_device_id" \
        "$authority_epoch" "$target_device_id" "$ledger_sequence"
      source_digest="$SKILLET_SET_DIGEST"
      byte_count="$SKILLET_SET_BYTES"
      repository_count="$SKILLET_SET_REPOSITORY_COUNT"
    else
      source_file="$(system_item_source_file "$item_id")" \
        || die "system-pull 缺少 transport adapter：$item_id"
      [ -f "$source_file" ] || die "找不到 Work OS 來源：$source_file"
      mkdir -p "$(dirname "$payload_file")"
      cp "$source_file" "$payload_file"
      source_digest="$(sha256_file "$payload_file")"
      byte_count="$(file_byte_count "$payload_file")"
    fi
    [ "$index" -eq 0 ] || printf ',\n' >>"$manifest"
    cat >>"$manifest" <<EOF
    {
      "id": "$item_id",
      "displayName": "$display_name",
      "payloadRelativePath": "$payload_relative",
      "mirrorRelativePath": "$mirror_relative",
      "sourceDigest": "$source_digest",
      "byteCount": $byte_count$(if [ -n "$repository_count" ]; then printf ',\n      "repositoryCount": %s' "$repository_count"; fi)
    }
EOF
    index=$((index + 1))
  done
  cat >>"$manifest" <<EOF
  ]
}
EOF
  SYSTEM_MANIFEST_DIGEST="$(sha256_file "$manifest")"
  mkdir -p "$(dirname "$final_payload_root")"
  mv "$payload_root" "$final_payload_root" \
    || die "無法原子發布 system-pull payload：$id"
  REQUEST_PAYLOAD_STAGE=""
  SYSTEM_MANIFEST_PATH="payloads/$id/manifest.json"
}

cmd_sync_request() {  # 在主設備跑：發起對某副設備（或全部）的同步
  local target="" action="system-pull"
  while [ $# -gt 0 ]; do case "$1" in
    --target) target="$2"; shift 2;;
    --action) action="$2"; shift 2;;
    *) die "未知參數 $1";; esac; done
  case "$action" in
    system-pull|db-pull|version-pull|data-sync) ;;
    both)
      die "action=both 不具備完整 digest contract；請分開送出 system-pull 與 version-pull request"
      ;;
    *) die "action 需為 system-pull|db-pull|version-pull|data-sync";;
  esac
  [ -n "$target" ] || die "sync-request 需要 --target NAME"
  if [ "$target" = "all-secondaries" ]; then
    die "all-secondaries broadcast 已停用：每台設備必須有獨立 request ID 與 ACK；請逐台送出 per-device request"
  fi
  validate_device_name "$target"
  channel_ensure
  require_current_primary
  ensure_device_identity
  retention_budget_status \
    || die "同步 artifact retention budget 已達上限；先人工封存與複審，再建立新 request"

  local source_device_id registered_source_id target_device_id=""
  source_device_id="$(json_get "$(device_identity_file)" deviceId)"
  registered_source_id="$(registered_device_id "$DEVICE_NAME")"
  [ -n "$source_device_id" ] || die "本機 device identity 缺少 deviceId"
  [ "$source_device_id" = "$registered_source_id" ] \
    || die "本機 device identity 與通道 registry 不符，拒絕以未知身分發起同步"
  ensure_device_trust_identity
  validate_registered_device_trust "$DEVICE_NAME" "$source_device_id" \
    && device_trust_identity_files_match \
      "$(registered_device_file "$DEVICE_NAME")" "$(device_trust_identity_file)" \
    || die "本機 registry 尚未綁定目前 Ed25519 identity；請重新執行 register"
  target_device_id="$(registered_device_id "$target")"
  [ -n "$target_device_id" ] || die "目標設備未登記或缺少 deviceId：$target"
  pin_registered_device_trust "$target" "$target_device_id" \
    || die "目標設備 trust identity 未登記、已撤銷或與本機 pin 不符：$target"

  local id ts catalog_revision manifest_path="" manifest_digest=""
  local digest_algorithm="" request_source_digest=""
  id="$(newid)"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  catalog_revision="$(sync_catalog_revision)"
  compute_next_request_sequence
  if [ "$action" = "system-pull" ]; then
    printf 'SYNC_SOURCE_REFRESH_ATTEMPT_ID=%s\n' "$id"
    require_system_runtime_enrollment \
      || die "system-pull helper 缺少可用的 runtime／原生 Skills consumer 納管；拒絕發布 request"
    SYSTEM_MANIFEST_PATH=""
    SYSTEM_MANIFEST_DIGEST=""
    prepare_system_payload \
      "$id" "$catalog_revision" "$source_device_id" "$PRIMARY_EPOCH" \
      "$target_device_id" "$REQUEST_LEDGER_SEQUENCE" "$target" "$ts"
    manifest_path="$SYSTEM_MANIFEST_PATH"
    manifest_digest="$SYSTEM_MANIFEST_DIGEST"
    digest_algorithm="sha256"
    request_source_digest="$manifest_digest"
  elif [ "$action" = "version-pull" ]; then
    digest_algorithm="git-object-id"
    request_source_digest="$(version_source_digest)"
    is_git_object_id "$request_source_digest" \
      || die "無法取得 release branch 的有效 source digest；拒絕發出未綁定版本 request"
  fi

  local request_dir="$CHANNEL_DIR/requests/$target"
  local request_file="$request_dir/$id.json"
  local request_signature_relative="signatures/requests/$target/$id.json"
  local request_signature="$CHANNEL_DIR/$request_signature_relative"
  mkdir -p "$request_dir" "$(dirname "$request_signature")"
  cat > "$request_file" <<EOF
{
  "id": "$id",
  "requestID": "$id",
  "action": "$action",
  "target": "$target",
  "targetDeviceName": "$target",
  "targetDeviceID": "$target_device_id",
  "primaryHost": "$PRIMARY_SSH_HOST",
  "requestedBy": "$DEVICE_NAME",
  "requestedAt": "$ts",
  "authorityPrimary": "$PRIMARY_NAME",
  "authorityEpoch": $PRIMARY_EPOCH,
  "ledgerSequence": $REQUEST_LEDGER_SEQUENCE,
  "sourceDeviceName": "$DEVICE_NAME",
  "sourceDeviceID": "$source_device_id",
  "catalogRevision": "$catalog_revision",
  "sourceMode": "$(json_escape "$SKILLET_SOURCE_MODE")",
  "inventoryDigest": "$(json_escape "$SKILLET_INVENTORY_DIGEST")",
  "fallbackAuthorizationID": "$(json_escape "$SKILLET_FALLBACK_AUTHORIZATION_ID")",
  "fallbackAuthorizationPath": "$(json_escape "$SKILLET_FALLBACK_AUTHORIZATION_PATH")",
  "fallbackAuthorizationDigest": "$(json_escape "$SKILLET_FALLBACK_AUTHORIZATION_DIGEST")",
  "digestAlgorithm": "$digest_algorithm",
  "sourceDigest": "$request_source_digest",
  "manifestPath": "$manifest_path",
  "manifestDigest": "$manifest_digest",
  "signaturePurpose": "sync-request",
  "signaturePath": "$request_signature_relative"
}
EOF
  sign_channel_artifact "sync-request" "$request_file" "$request_signature" \
    || die "無法以本機 Ed25519 key 簽署同步 request"
  persist_request_sequence
  git -C "$CHANNEL_DIR" add "requests/$target/$id.json"
  git -C "$CHANNEL_DIR" add "$request_signature_relative"
  git -C "$CHANNEL_DIR" add "$(basename "$(request_sequence_file)")"
  if [ "$action" = "system-pull" ]; then
    git -C "$CHANNEL_DIR" add -f -- "payloads/$id"
  fi
  git -C "$CHANNEL_DIR" commit -m "sync-request $target $action $id" >/dev/null 2>&1
  channel_push
  log "已發起同步：target=$target action=$action id=${id}（副設備 helper 輪詢到即執行）"
  printf 'SYNC_REQUEST_ID=%s\n' "$id"
  printf 'SYNC_AUTHORITY_EPOCH=%s\n' "$PRIMARY_EPOCH"
  printf 'SYNC_LEDGER_SEQUENCE=%s\n' "$REQUEST_LEDGER_SEQUENCE"
  printf 'SYNC_AUTHORITY_PRIMARY=%s\n' "$PRIMARY_NAME"
  printf 'SYNC_SOURCE_DEVICE_ID=%s\n' "$source_device_id"
  printf 'SYNC_TARGET_DEVICE_ID=%s\n' "$target_device_id"
  printf 'SYNC_CATALOG_REVISION=%s\n' "$catalog_revision"
  if [ "$action" = "system-pull" ]; then
    printf 'SYNC_SOURCE_MODE=%s\n' "$SKILLET_SOURCE_MODE"
    printf 'SYNC_INVENTORY_DIGEST=%s\n' "$SKILLET_INVENTORY_DIGEST"
    printf 'SYNC_FALLBACK_AUTHORIZATION_ID=%s\n' "$SKILLET_FALLBACK_AUTHORIZATION_ID"
  fi
}

version_source_digest() {
  local repo; repo="$(resolve_repo)"
  git -C "$repo" fetch origin "$RELEASE_BRANCH" >/dev/null 2>&1 || true
  git -C "$repo" rev-parse "origin/$RELEASE_BRANCH" 2>/dev/null || true
}

version_applied_digest() {
  local repo; repo="$(resolve_repo)"
  git -C "$repo" rev-parse HEAD 2>/dev/null || true
}

sync_progress_reset() {
  SYNC_PROGRESS_ENABLED=0
  SYNC_PROGRESS_STARTED_EPOCH=0
  SYNC_PROGRESS_BASE_ELAPSED_MS=0
  SYNC_PROGRESS_TOTAL_BYTES=0
  SYNC_PROGRESS_PAYLOAD_BYTES=0
  SYNC_PROGRESS_TOTAL_ITEMS=0
  SYNC_PROGRESS_TOTAL_REPOSITORIES=0
  SYNC_PROGRESS_COMPLETED_BYTES=0
  SYNC_PROGRESS_COMPLETED_ITEMS=0
  SYNC_PROGRESS_COMPLETED_REPOSITORIES=0
  SYNC_PROGRESS_REQUEST_FILE=""
  SYNC_PROGRESS_MANIFEST=""
  SYNC_PROGRESS_ID=""
  SYNC_PROGRESS_TARGET=""
  SYNC_PROGRESS_ACTION=""
  SYNC_PROGRESS_REQUESTED_AT=""
  SYNC_PROGRESS_AUTHORITY_EPOCH=0
  SYNC_PROGRESS_LEDGER_SEQUENCE=0
  SYNC_PROGRESS_AUTHORITY_PRIMARY=""
  SYNC_PROGRESS_SOURCE_DEVICE_ID=""
  SYNC_PROGRESS_TARGET_DEVICE_ID=""
  SYNC_PROGRESS_CATALOG_REVISION=""
  SYNC_PROGRESS_DIGEST_ALGORITHM=""
  SYNC_PROGRESS_SOURCE_DIGEST=""
  SYNC_PROGRESS_SOURCE_MODE=""
  SYNC_PROGRESS_INVENTORY_DIGEST=""
  SYNC_PROGRESS_FALLBACK_AUTHORIZATION_ID=""
  SYNC_PROGRESS_FALLBACK_AUTHORIZATION_PATH=""
  SYNC_PROGRESS_FALLBACK_AUTHORIZATION_DIGEST=""
}

sync_progress_initialize_system() {
  local request_file="$1" id="$2" target="$3" requested_at="$4"
  local authority_epoch="$5" ledger_sequence="$6" authority_primary="$7"
  local source_device_id="$8" target_device_id="$9" catalog_revision="${10}"
  local request_source_digest="${11}" existing_ack="${12:-}"
  local manifest_path manifest payload_root item_count repository_count=""
  local item_index item_id payload_bytes

  sync_progress_reset
  manifest_path="$(json_get "$request_file" manifestPath)"
  [ "$manifest_path" = "payloads/$id/manifest.json" ] || return 1
  manifest="$CHANNEL_DIR/$manifest_path"
  [ -f "$manifest" ] \
    && [ "$(sha256_file "$manifest")" = "$request_source_digest" ] \
    || return 1
  payload_root="$(dirname "$manifest")"
  payload_bytes="$(directory_file_bytes "$payload_root")"
  validate_nonnegative_integer "$payload_bytes" && [ "$payload_bytes" -gt 0 ] \
    || return 1
  item_count="$(plutil -extract items raw "$manifest" 2>/dev/null || true)"
  validate_nonnegative_integer "$item_count" && [ "$item_count" -gt 0 ] \
    || return 1
  item_index=0
  while [ "$item_index" -lt "$item_count" ]; do
    item_id="$(plutil -extract "items.$item_index.id" raw "$manifest" 2>/dev/null || true)"
    if [ "$item_id" = "skills.skillet" ]; then
      repository_count="$(plutil -extract "items.$item_index.repositoryCount" raw "$manifest" 2>/dev/null || true)"
      break
    fi
    item_index=$((item_index + 1))
  done
  validate_nonnegative_integer "$repository_count" || return 1

  SYNC_PROGRESS_ENABLED=1
  SYNC_PROGRESS_STARTED_EPOCH="$(date -u +%s)"
  SYNC_PROGRESS_PAYLOAD_BYTES="$payload_bytes"
  SYNC_PROGRESS_TOTAL_BYTES="$((payload_bytes * 3))"
  SYNC_PROGRESS_TOTAL_ITEMS="$item_count"
  SYNC_PROGRESS_TOTAL_REPOSITORIES="$repository_count"
  SYNC_PROGRESS_REQUEST_FILE="$request_file"
  SYNC_PROGRESS_MANIFEST="$manifest"
  SYNC_PROGRESS_ID="$id"
  SYNC_PROGRESS_TARGET="$target"
  SYNC_PROGRESS_ACTION="system-pull"
  SYNC_PROGRESS_REQUESTED_AT="$requested_at"
  SYNC_PROGRESS_AUTHORITY_EPOCH="$authority_epoch"
  SYNC_PROGRESS_LEDGER_SEQUENCE="$ledger_sequence"
  SYNC_PROGRESS_AUTHORITY_PRIMARY="$authority_primary"
  SYNC_PROGRESS_SOURCE_DEVICE_ID="$source_device_id"
  SYNC_PROGRESS_TARGET_DEVICE_ID="$target_device_id"
  SYNC_PROGRESS_CATALOG_REVISION="$catalog_revision"
  SYNC_PROGRESS_DIGEST_ALGORITHM="sha256"
  SYNC_PROGRESS_SOURCE_DIGEST="$request_source_digest"
  SYNC_PROGRESS_SOURCE_MODE="$(json_get "$request_file" sourceMode)"
  SYNC_PROGRESS_INVENTORY_DIGEST="$(json_get "$request_file" inventoryDigest)"
  SYNC_PROGRESS_FALLBACK_AUTHORIZATION_ID="$(
    json_get "$request_file" fallbackAuthorizationID
  )"
  SYNC_PROGRESS_FALLBACK_AUTHORIZATION_PATH="$(
    json_get "$request_file" fallbackAuthorizationPath
  )"
  SYNC_PROGRESS_FALLBACK_AUTHORIZATION_DIGEST="$(
    json_get "$request_file" fallbackAuthorizationDigest
  )"

  if [ -f "$existing_ack" ] \
    && validate_sync_progress_payload "$existing_ack" progress "$(json_get "$existing_ack" phase)"
  then
    [ "$(json_get "$existing_ack" sourceMode)" = "$SYNC_PROGRESS_SOURCE_MODE" ] \
      && [ "$(json_get "$existing_ack" inventoryDigest)" = "$SYNC_PROGRESS_INVENTORY_DIGEST" ] \
      && [ "$(json_get "$existing_ack" fallbackAuthorizationID)" = \
        "$SYNC_PROGRESS_FALLBACK_AUTHORIZATION_ID" ] \
      && [ "$(json_get "$existing_ack" fallbackAuthorizationPath)" = \
        "$SYNC_PROGRESS_FALLBACK_AUTHORIZATION_PATH" ] \
      && [ "$(json_get "$existing_ack" fallbackAuthorizationDigest)" = \
        "$SYNC_PROGRESS_FALLBACK_AUTHORIZATION_DIGEST" ] \
      && [ "$(plutil -extract progress.totalBytes raw "$existing_ack")" = "$SYNC_PROGRESS_TOTAL_BYTES" ] \
      && [ "$(plutil -extract progress.totalItems raw "$existing_ack")" = "$SYNC_PROGRESS_TOTAL_ITEMS" ] \
      && [ "$(plutil -extract progress.totalRepositories raw "$existing_ack")" = "$SYNC_PROGRESS_TOTAL_REPOSITORIES" ] \
      || return 1
    SYNC_PROGRESS_BASE_ELAPSED_MS="$(plutil -extract progress.elapsedMilliseconds raw "$existing_ack")"
    SYNC_PROGRESS_COMPLETED_BYTES="$(plutil -extract progress.completedBytes raw "$existing_ack")"
    SYNC_PROGRESS_COMPLETED_ITEMS="$(plutil -extract progress.completedItems raw "$existing_ack")"
    SYNC_PROGRESS_COMPLETED_REPOSITORIES="$(plutil -extract progress.completedRepositories raw "$existing_ack")"
  fi
}

sync_progress_elapsed_ms() {
  local now elapsed
  now="$(date -u +%s)"
  elapsed=$(((now - SYNC_PROGRESS_STARTED_EPOCH) * 1000 + SYNC_PROGRESS_BASE_ELAPSED_MS))
  [ "$elapsed" -ge "$SYNC_PROGRESS_BASE_ELAPSED_MS" ] \
    || elapsed="$SYNC_PROGRESS_BASE_ELAPSED_MS"
  printf '%s\n' "$elapsed"
}

sync_progress_payload_json() {
  local completed_bytes="$1" completed_items="$2" completed_repositories="$3"
  local current_item="$4" elapsed throughput
  elapsed="$(sync_progress_elapsed_ms)"
  throughput="$(awk -v bytes="$completed_bytes" -v elapsed="$elapsed" \
    'BEGIN { if (elapsed <= 0) printf "0.0"; else printf "%.2f", bytes * 1000 / elapsed }')"
  cat <<EOF
{
    "completedBytes": $completed_bytes,
    "totalBytes": $SYNC_PROGRESS_TOTAL_BYTES,
    "completedItems": $completed_items,
    "totalItems": $SYNC_PROGRESS_TOTAL_ITEMS,
    "completedRepositories": $completed_repositories,
    "totalRepositories": $SYNC_PROGRESS_TOTAL_REPOSITORIES,
    "elapsedMilliseconds": $elapsed,
    "throughputBytesPerSecond": $throughput,
    "currentItem": "$(json_escape "$current_item")"
  }
EOF
}

sync_progress_system_items_json() {
  local phase="$1" byte_multiplier="$2" completed_item="$3"
  local completed_repositories="$4" message="$5"
  local item_count index=0 item_id display_name source_digest byte_count
  local item_total_bytes item_completed_bytes repository_count="" items_json="["
  item_count="$SYNC_PROGRESS_TOTAL_ITEMS"
  while [ "$index" -lt "$item_count" ]; do
    item_id="$(plutil -extract "items.$index.id" raw "$SYNC_PROGRESS_MANIFEST" 2>/dev/null || true)"
    display_name="$(plutil -extract "items.$index.displayName" raw "$SYNC_PROGRESS_MANIFEST" 2>/dev/null || true)"
    source_digest="$(plutil -extract "items.$index.sourceDigest" raw "$SYNC_PROGRESS_MANIFEST" 2>/dev/null || true)"
    byte_count="$(plutil -extract "items.$index.byteCount" raw "$SYNC_PROGRESS_MANIFEST" 2>/dev/null || true)"
    validate_nonnegative_integer "$byte_count" || return 1
    item_total_bytes="$((byte_count * 3))"
    item_completed_bytes="$((byte_count * byte_multiplier))"
    [ "$index" -eq 0 ] || items_json="${items_json},"
    if [ "$item_id" = "skills.skillet" ]; then
      repository_count="$(plutil -extract "items.$index.repositoryCount" raw "$SYNC_PROGRESS_MANIFEST" 2>/dev/null || true)"
      validate_nonnegative_integer "$repository_count" || return 1
      items_json="${items_json}{
      \"id\":\"$item_id\",
      \"displayName\":\"$(json_escape "$display_name")\",
      \"phase\":\"$phase\",
      \"digestAlgorithm\":\"sha256\",
      \"sourceDigest\":\"$source_digest\",
      \"appliedDigest\":\"\",
      \"message\":\"$(json_escape "$message")\",
      \"repositoryCount\":$repository_count,
      \"progress\":{
        \"completedBytes\":$item_completed_bytes,
        \"totalBytes\":$item_total_bytes,
        \"completedItems\":$completed_item,
        \"totalItems\":1,
        \"completedRepositories\":$completed_repositories,
        \"totalRepositories\":$repository_count,
        \"currentItem\":\"$(json_escape "$display_name")\"
      }
    }"
    else
      items_json="${items_json}{
      \"id\":\"$item_id\",
      \"displayName\":\"$(json_escape "$display_name")\",
      \"phase\":\"$phase\",
      \"digestAlgorithm\":\"sha256\",
      \"sourceDigest\":\"$source_digest\",
      \"appliedDigest\":\"\",
      \"message\":\"$(json_escape "$message")\",
      \"progress\":{
        \"completedBytes\":$item_completed_bytes,
        \"totalBytes\":$item_total_bytes,
        \"completedItems\":$completed_item,
        \"totalItems\":1,
        \"completedRepositories\":0,
        \"totalRepositories\":0,
        \"currentItem\":\"$(json_escape "$display_name")\"
      }
    }"
    fi
    index=$((index + 1))
  done
  printf '%s]\n' "$items_json"
}

sync_progress_required_ids_json() {
  local item_id ids_json="[" index=0
  while IFS= read -r item_id; do
    [ "$index" -eq 0 ] || ids_json="${ids_json},"
    ids_json="${ids_json}\"$item_id\""
    index=$((index + 1))
  done < <(system_required_item_ids)
  printf '%s]\n' "$ids_json"
}

write_sync_progress_ack() {
  local phase="$1" byte_multiplier="$2" completed_items="$3"
  local completed_repositories="$4" current_item="$5" message="$6"
  [ "$SYNC_PROGRESS_ENABLED" = "1" ] || return 0

  local existing_ack="$CHANNEL_DIR/acks/$SYNC_PROGRESS_ID.json"
  local existing_phase="" existing_rank="" requested_rank
  requested_rank="$(sync_ack_phase_rank "$phase")" || return 1
  if [ -f "$existing_ack" ]; then
    existing_phase="$(json_get "$existing_ack" phase)"
    existing_rank="$(sync_ack_phase_rank "$existing_phase" 2>/dev/null || true)"
    if [ -n "$existing_rank" ] && [ "$requested_rank" -lt "$existing_rank" ]; then
      log "保留較新的同步進度 phase=${existing_phase}；略過回退到 $phase"
      return 0
    fi
  fi

  local completed_bytes progress_json items_json required_ids_json
  completed_bytes="$((SYNC_PROGRESS_PAYLOAD_BYTES * byte_multiplier))"
  progress_json="$(sync_progress_payload_json \
    "$completed_bytes" "$completed_items" "$completed_repositories" "$current_item")"
  items_json="$(sync_progress_system_items_json \
    "$phase" "$byte_multiplier" \
    "$([ "$completed_items" -gt 0 ] && echo 1 || echo 0)" \
    "$completed_repositories" "$message")"
  required_ids_json="$(sync_progress_required_ids_json)"

  write_sync_ack \
    "$SYNC_PROGRESS_ID" "$SYNC_PROGRESS_TARGET" "$SYNC_PROGRESS_ACTION" \
    "$SYNC_PROGRESS_REQUESTED_AT" "$phase" "partial" \
    "$SYNC_PROGRESS_SOURCE_DIGEST" "" "$message" \
    "$SYNC_PROGRESS_AUTHORITY_EPOCH" "$SYNC_PROGRESS_LEDGER_SEQUENCE" \
    "$SYNC_PROGRESS_AUTHORITY_PRIMARY" "$SYNC_PROGRESS_SOURCE_DEVICE_ID" \
    "$SYNC_PROGRESS_TARGET_DEVICE_ID" "$SYNC_PROGRESS_CATALOG_REVISION" \
    "$SYNC_PROGRESS_DIGEST_ALGORITHM" "$required_ids_json" "$items_json" \
    "" "" "" "$progress_json" \
    "" "" "" "0" \
    "$SYNC_PROGRESS_SOURCE_MODE" "$SYNC_PROGRESS_INVENTORY_DIGEST" \
    "$SYNC_PROGRESS_FALLBACK_AUTHORIZATION_ID" \
    "$SYNC_PROGRESS_FALLBACK_AUTHORIZATION_PATH" \
    "$SYNC_PROGRESS_FALLBACK_AUTHORIZATION_DIGEST"

  SYNC_PROGRESS_COMPLETED_BYTES="$completed_bytes"
  SYNC_PROGRESS_COMPLETED_ITEMS="$completed_items"
  SYNC_PROGRESS_COMPLETED_REPOSITORIES="$completed_repositories"
  if [ "${TATWO_TEST_MODE:-0}" = "1" ] \
    && [ "${TATWO_TEST_CRASH_AFTER_PROGRESS_PHASE:-}" = "$phase" ]
  then
    kill -9 "$$"
  fi
}

write_sync_ack() {
  local id="$1" target="$2" action="$3" requested_at="$4" phase="$5" result="$6"
  local source_digest="$7" applied_digest="$8" message="$9" authority_epoch="${10}"
  local ledger_sequence="${11}" authority_primary="${12}" source_device_id="${13}"
  local target_device_id="${14}" catalog_revision="${15}" digest_algorithm="${16}"
  local required_item_ids_json="${17}" items_json="${18}"
  local attestation_kind="${19:-}" attestation_path="${20:-}" attestation_digest="${21:-}"
  local progress_json="${22:-}"
  local consumer_readback_kind="${23:-}" consumer_readback_path="${24:-}"
  local consumer_readback_digest="${25:-}" consumer_readback_count="${26:-0}"
  local source_mode="${27:-}" inventory_digest="${28:-}"
  local fallback_authorization_id="${29:-}" fallback_authorization_path="${30:-}"
  local fallback_authorization_digest="${31:-}"
  local completed_at ack ack_stage progress_member=""
  local ack_signature_relative ack_signature ack_signature_stage
  local attestation_signature_path=""
  completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ack="$CHANNEL_DIR/acks/$id.json"
  ack_signature_relative="signatures/acks/$id.json"
  ack_signature="$CHANNEL_DIR/$ack_signature_relative"
  mkdir -p "$CHANNEL_DIR/acks"
  mkdir -p "$(dirname "$ack_signature")"
  ack_stage="$CHANNEL_DIR/acks/.$id.$$.tmp"
  ack_signature_stage="$(dirname "$ack_signature")/.$id.$$.tmp"
  if [ -n "$progress_json" ]; then
    progress_member="$(printf ',\n  \"progress\": %s' "$progress_json")"
  fi
  if [ -n "$attestation_path" ]; then
    attestation_signature_path="signatures/attestations/$target/$id.json"
    [ -f "$CHANNEL_DIR/$attestation_signature_path" ] \
      && [ ! -L "$CHANNEL_DIR/$attestation_signature_path" ] \
      || { log "ACK 引用的 target attestation signature 不存在：$id"; return 1; }
  fi
  cat > "$ack_stage" <<EOF
{
  "target": "$(json_escape "$target")",
  "action": "$(json_escape "$action")",
  "requestedAt": "$(json_escape "$requested_at")",
  "result": "$(json_escape "$result")",
  "completedAt": "$completed_at",
  "message": "$(json_escape "$message")",
  "phase": "$(json_escape "$phase")",
  "requestID": "$(json_escape "$id")",
  "authorityEpoch": $authority_epoch,
  "ledgerSequence": $ledger_sequence,
  "authorityPrimary": "$(json_escape "$authority_primary")",
  "sourceDeviceID": "$(json_escape "$source_device_id")",
  "targetDeviceID": "$(json_escape "$target_device_id")",
  "catalogRevision": "$(json_escape "$catalog_revision")",
  "sourceMode": "$(json_escape "$source_mode")",
  "inventoryDigest": "$(json_escape "$inventory_digest")",
  "fallbackAuthorizationID": "$(json_escape "$fallback_authorization_id")",
  "fallbackAuthorizationPath": "$(json_escape "$fallback_authorization_path")",
  "fallbackAuthorizationDigest": "$(json_escape "$fallback_authorization_digest")",
  "digestAlgorithm": "$(json_escape "$digest_algorithm")",
  "sourceDigest": "$(json_escape "$source_digest")",
  "appliedDigest": "$(json_escape "$applied_digest")",
  "attestationKind": "$(json_escape "$attestation_kind")",
  "targetAttestationPath": "$(json_escape "$attestation_path")",
  "targetAttestationDigest": "$(json_escape "$attestation_digest")",
  "targetAttestationSignaturePath": "$(json_escape "$attestation_signature_path")",
  "consumerReadbackKind": "$(json_escape "$consumer_readback_kind")",
  "consumerReadbackPath": "$(json_escape "$consumer_readback_path")",
  "consumerReadbackDigest": "$(json_escape "$consumer_readback_digest")",
  "consumerReadbackCount": $consumer_readback_count,
  "signaturePurpose": "sync-ack",
  "signaturePath": "$ack_signature_relative",
  "requiredItemIDs": $required_item_ids_json,
  "items": $items_json$progress_member
}
EOF
  [ "$(plutil -extract requestID raw "$ack_stage" 2>/dev/null || true)" = "$id" ] \
    && [ "$(plutil -extract phase raw "$ack_stage" 2>/dev/null || true)" = "$phase" ] \
    || { log "ACK atomic stage 寫入/解析失敗：$id"; return 1; }
  if [ -n "$progress_json" ]; then
    validate_sync_progress_payload "$ack_stage" progress "$phase" \
      || { log "ACK progress schema/範圍不合法：$id phase=$phase"; return 1; }
  fi
  if [ -f "$ack" ]; then
    local previous_phase previous_rank next_rank
    previous_phase="$(json_get "$ack" phase)"
    previous_rank="$(sync_ack_phase_rank "$previous_phase" 2>/dev/null || true)"
    next_rank="$(sync_ack_phase_rank "$phase" 2>/dev/null || true)"
    [ -n "$previous_rank" ] && [ -n "$next_rank" ] \
      || { log "ACK phase transition 無法驗證：$previous_phase → $phase"; return 1; }
    if sync_ack_phase_is_terminal "$previous_phase"; then
      log "既有 terminal ACK 不得被覆寫：$id phase=$previous_phase"
      return 1
    fi
    if [ "$previous_phase" = "activating" ] && [ "$phase" = "merging" ]; then
      # Divergence can only be known after the aggregate receive path inspects
      # the target store. This is an explicit human-gate loopback, not ordinary
      # progress regression; measured counters must still remain monotonic.
      :
    else
      [ "$next_rank" -ge "$previous_rank" ] \
        || { log "ACK phase 不得倒退：$previous_phase → $phase"; return 1; }
    fi
    if [ -n "$progress_json" ] \
      && plutil -extract progress raw "$ack" >/dev/null 2>&1
    then
      sync_progress_payload_is_monotonic "$ack" "$ack_stage" \
        || { log "ACK measured progress 不得倒退或改寫 totals：$id"; return 1; }
    fi
  fi
  sign_channel_artifact "sync-ack" "$ack_stage" "$ack_signature_stage" \
    || { log "ACK Ed25519 簽署失敗：$id phase=$phase"; return 1; }
  mv "$ack_stage" "$ack" || return 1
  mv "$ack_signature_stage" "$ack_signature" || return 1
  git -C "$CHANNEL_DIR" add "acks/$id.json"
  git -C "$CHANNEL_DIR" add "$ack_signature_relative"
  if [ -n "$attestation_path" ]; then
    git -C "$CHANNEL_DIR" add "$attestation_path"
    git -C "$CHANNEL_DIR" add "$attestation_signature_path"
  fi
  if [ -n "$consumer_readback_path" ]; then
    git -C "$CHANNEL_DIR" add "$consumer_readback_path"
  fi
  git -C "$CHANNEL_DIR" commit -m "sync-ack $target $action $id $phase" >/dev/null 2>&1 \
    || die "ack commit 失敗"
  channel_push
}

validate_system_consumer_readback_file() {
  local file="$1" id="$2" target="$3" authority_epoch="$4" ledger_sequence="$5"
  local authority_primary="$6" source_device_id="$7" target_device_id="$8"
  local catalog_revision="$9" manifest_digest="${10}"
  local required_count readback_count index consumer_id source_item_id
  local expected_digest loaded_digest loaded_revision loaded_path status
  [ -s "$file" ] \
    && plutil -convert json -o /dev/null -- "$file" >/dev/null 2>&1 \
    && [ "$(plutil -extract schema raw "$file" 2>/dev/null || true)" = "TatwoTargetConsumerReadbackSetV1" ] \
    && [ "$(plutil -extract requestID raw "$file" 2>/dev/null || true)" = "$id" ] \
    && [ "$(plutil -extract target raw "$file" 2>/dev/null || true)" = "$target" ] \
    && [ "$(plutil -extract authorityEpoch raw "$file" 2>/dev/null || true)" = "$authority_epoch" ] \
    && [ "$(plutil -extract ledgerSequence raw "$file" 2>/dev/null || true)" = "$ledger_sequence" ] \
    && [ "$(plutil -extract authorityPrimary raw "$file" 2>/dev/null || true)" = "$authority_primary" ] \
    && [ "$(plutil -extract sourceDeviceID raw "$file" 2>/dev/null || true)" = "$source_device_id" ] \
    && [ "$(plutil -extract targetDeviceID raw "$file" 2>/dev/null || true)" = "$target_device_id" ] \
    && [ "$(plutil -extract catalogRevision raw "$file" 2>/dev/null || true)" = "$catalog_revision" ] \
    && [ "$(plutil -extract manifestDigest raw "$file" 2>/dev/null || true)" = "$manifest_digest" ] \
    && [ "$(plutil -extract status raw "$file" 2>/dev/null || true)" = "passed" ] \
    || return 1
  required_count="$(plutil -extract requiredConsumerIDs raw "$file" 2>/dev/null || true)"
  readback_count="$(plutil -extract readbacks raw "$file" 2>/dev/null || true)"
  validate_nonnegative_integer "$required_count" \
    && [ "$required_count" = "5" ] \
    && validate_nonnegative_integer "$readback_count" \
    && [ "$readback_count" -ge "$required_count" ] \
    && [ "$(plutil -extract readbackCount raw "$file" 2>/dev/null || true)" = "$readback_count" ] \
    || return 1
  [ "$(plutil -extract requiredConsumerIDs.0 raw "$file" 2>/dev/null || true)" = "work-os.bootstrap" ] \
    && [ "$(plutil -extract requiredConsumerIDs.1 raw "$file" 2>/dev/null || true)" = "tatwo-app.shared-runtime" ] \
    && [ "$(plutil -extract requiredConsumerIDs.2 raw "$file" 2>/dev/null || true)" = "skillet.runtime-loader" ] \
    && [ "$(plutil -extract requiredConsumerIDs.3 raw "$file" 2>/dev/null || true)" = "codex.native-skills" ] \
    && [ "$(plutil -extract requiredConsumerIDs.4 raw "$file" 2>/dev/null || true)" = "claude.native-skills" ] \
    || return 1
  local seen_work_os=0 seen_app=0 seen_skillet=0 seen_codex=0 seen_claude=0
  index=0
  while [ "$index" -lt "$readback_count" ]; do
    [ "$(plutil -extract "readbacks.$index.schema" raw "$file" 2>/dev/null || true)" = "TatwoTargetConsumerReadbackV1" ] \
      && [ "$(plutil -extract "readbacks.$index.requestID" raw "$file" 2>/dev/null || true)" = "$id" ] \
      && [ "$(plutil -extract "readbacks.$index.authorityEpoch" raw "$file" 2>/dev/null || true)" = "$authority_epoch" ] \
      && [ "$(plutil -extract "readbacks.$index.ledgerSequence" raw "$file" 2>/dev/null || true)" = "$ledger_sequence" ] \
      && [ "$(plutil -extract "readbacks.$index.authorityPrimary" raw "$file" 2>/dev/null || true)" = "$authority_primary" ] \
      && [ "$(plutil -extract "readbacks.$index.targetDeviceID" raw "$file" 2>/dev/null || true)" = "$target_device_id" ] \
      && [ "$(plutil -extract "readbacks.$index.catalogRevision" raw "$file" 2>/dev/null || true)" = "$catalog_revision" ] \
      || return 1
    consumer_id="$(plutil -extract "readbacks.$index.consumerID" raw "$file" 2>/dev/null || true)"
    source_item_id="$(plutil -extract "readbacks.$index.sourceItemID" raw "$file" 2>/dev/null || true)"
    expected_digest="$(plutil -extract "readbacks.$index.expectedDigest" raw "$file" 2>/dev/null || true)"
    loaded_digest="$(plutil -extract "readbacks.$index.loadedDigest" raw "$file" 2>/dev/null || true)"
    loaded_revision="$(plutil -extract "readbacks.$index.loadedRevision" raw "$file" 2>/dev/null || true)"
    loaded_path="$(plutil -extract "readbacks.$index.loadedPath" raw "$file" 2>/dev/null || true)"
    status="$(plutil -extract "readbacks.$index.status" raw "$file" 2>/dev/null || true)"
    case "$consumer_id" in
      work-os.bootstrap) seen_work_os=1;;
      tatwo-app.shared-runtime) seen_app=1;;
      skillet.runtime-loader) seen_skillet=1;;
      codex.native-skills) seen_codex=1;;
      claude.native-skills) seen_claude=1;;
      *) return 1;;
    esac
    case "$consumer_id:$source_item_id" in
      work-os.bootstrap:os.constitution|work-os.bootstrap:os.issue|work-os.bootstrap:os.todo) ;;
      tatwo-app.shared-runtime:os.constitution|tatwo-app.shared-runtime:os.issue|tatwo-app.shared-runtime:os.todo) ;;
      skillet.runtime-loader:skills.skillet|codex.native-skills:skills.skillet|claude.native-skills:skills.skillet) ;;
      *) return 1 ;;
    esac
    is_sha256_digest "$expected_digest" \
      && [ "$loaded_digest" = "$expected_digest" ] \
      && consumer_loaded_revision_matches \
        "$source_item_id" "$loaded_digest" "$loaded_revision" \
      && [ -n "$loaded_path" ] \
      && [ "$status" = "loaded" ] \
      || return 1
    case "$loaded_path" in
      /*|*..*|*$'\n'*|*$'\r'*|*$'\t'*) return 1;;
    esac
    index=$((index + 1))
  done
  [ "$seen_work_os" = "1" ] \
    && [ "$seen_app" = "1" ] \
    && [ "$seen_skillet" = "1" ] \
    && [ "$seen_codex" = "1" ] \
    && [ "$seen_claude" = "1" ]
}

write_system_consumer_readback() {
  local id="$1" target="$2" authority_epoch="$3" ledger_sequence="$4"
  local authority_primary="$5" source_device_id="$6" target_device_id="$7"
  local catalog_revision="$8" manifest_digest="$9"
  local request_file manifest_path manifest local_dir local_receipt local_stage
  local skillet_activation_receipt
  local readback_relative readback readback_stage stage_digest final_digest readback_count
  TARGET_CONSUMER_READBACK_KIND=""
  TARGET_CONSUMER_READBACK_PATH=""
  TARGET_CONSUMER_READBACK_DIGEST=""
  TARGET_CONSUMER_READBACK_COUNT=0
  if [ "${TATWO_TEST_MODE:-0}" = "1" ] \
    && [ "${TATWO_TEST_FAIL_CONSUMER_READBACK:-0}" = "1" ]
  then
    log "測試注入：actual consumer readback 建立失敗"
    return 1
  fi
  request_file="$CHANNEL_DIR/requests/$target/$id.json"
  [ -f "$request_file" ] || { log "consumer readback 缺少 request"; return 1; }
  manifest_path="$(json_get "$request_file" manifestPath)"
  [ "$manifest_path" = "payloads/$id/manifest.json" ] \
    || { log "consumer readback manifest path 不合法"; return 1; }
  manifest="$CHANNEL_DIR/$manifest_path"
  [ -f "$manifest" ] && [ "$(sha256_file "$manifest")" = "$manifest_digest" ] \
    || { log "consumer readback manifest digest 不一致"; return 1; }
  [ -f "$SKILLET_SET_MANIFEST" ] \
    || { log "consumer readback 缺少 Skillet set manifest"; return 1; }
  skillet_activation_receipt="$APP_SUPPORT/device-sync-state/skillet-activation-receipts/$id/set.json"
  if [ ! -f "$skillet_activation_receipt" ]; then
    skillet_activation_receipt="$APP_SUPPORT/device-sync-state/skillet-activation-receipts/$id/committed-replay.json"
  fi
  [ -f "$skillet_activation_receipt" ] && [ ! -L "$skillet_activation_receipt" ] \
    || { log "consumer readback 缺少可信 Skillet activation receipt"; return 1; }
  local_dir="$APP_SUPPORT/device-sync-state/consumer-readbacks/$id"
  mkdir -p "$local_dir" || return 1
  local_receipt="$local_dir/set.json"
  local_stage="$local_dir/.set.$$.tmp"
  if ! run_skillet_cli skillet consumer-readback \
    --manifest "$manifest" \
    --mirror-root "$HOT_SYNC_MIRROR" \
    --set-manifest "$SKILLET_SET_MANIFEST" \
    --activation-receipt "$skillet_activation_receipt" \
    --store "$SKILLET_STORE" \
    --runtime-root "$SKILLET_RUNTIME_ROOT" \
    --consumer-root "$SKILLS_CONSUMER_ROOT" \
    --codex-skills-link "$CODEX_SKILLS_LINK" \
    --claude-skills-link "$CLAUDE_SKILLS_LINK" \
    --request "$id" \
    --target "$target" \
    --source-device "$source_device_id" \
    --target-device "$target_device_id" \
    --authority-primary "$authority_primary" \
    --authority-epoch "$authority_epoch" \
    --ledger-sequence "$ledger_sequence" \
    --catalog-revision "$catalog_revision" \
    --receipt "$local_stage" \
    --json >/dev/null
  then
    log "actual consumer adapter/readback 執行失敗：$id"
    return 1
  fi
  validate_system_consumer_readback_file \
    "$local_stage" "$id" "$target" "$authority_epoch" "$ledger_sequence" \
    "$authority_primary" "$source_device_id" "$target_device_id" "$catalog_revision" \
    "$manifest_digest" \
    || { log "local consumer readback schema/binding 不合法：$id"; return 1; }
  mv "$local_stage" "$local_receipt" || return 1
  readback_relative="consumer-readbacks/$target/$id.json"
  readback="$CHANNEL_DIR/$readback_relative"
  mkdir -p "$(dirname "$readback")" || return 1
  readback_stage="$(dirname "$readback")/.$id.$$.tmp"
  if [ "${TATWO_TEST_MODE:-0}" = "1" ] \
    && [ "${TATWO_TEST_PARTIAL_CONSUMER_READBACK_WRITE:-0}" = "1" ]
  then
    printf '%s' '{"schema":"TatwoTargetConsumer' >"$readback_stage" || true
    log "測試注入：consumer readback partial/ENOSPC write"
    return 1
  fi
  cp "$local_receipt" "$readback_stage" || return 1
  validate_system_consumer_readback_file \
    "$readback_stage" "$id" "$target" "$authority_epoch" "$ledger_sequence" \
    "$authority_primary" "$source_device_id" "$target_device_id" "$catalog_revision" \
    "$manifest_digest" \
    || { log "channel consumer readback stage 不合法：$id"; return 1; }
  stage_digest="$(sha256_file "$readback_stage")"
  is_sha256_digest "$stage_digest" \
    || { log "consumer readback stage digest 失敗：$id"; return 1; }
  same_filesystem "$readback_stage" "$(dirname "$readback")" \
    || { log "consumer readback stage 與 final 不在同一 filesystem：$id"; return 1; }
  mv "$readback_stage" "$readback" || return 1
  final_digest="$(sha256_file "$readback")"
  [ "$final_digest" = "$stage_digest" ] \
    && validate_system_consumer_readback_file \
      "$readback" "$id" "$target" "$authority_epoch" "$ledger_sequence" \
      "$authority_primary" "$source_device_id" "$target_device_id" "$catalog_revision" \
      "$manifest_digest" \
    || { log "consumer readback final digest/readback 失敗：$id"; return 1; }
  readback_count="$(plutil -extract readbackCount raw "$readback" 2>/dev/null || true)"
  validate_nonnegative_integer "$readback_count" && [ "$readback_count" -ge 5 ] \
    || return 1
  TARGET_CONSUMER_READBACK_KIND="actual-consumer-readback-set"
  TARGET_CONSUMER_READBACK_PATH="$readback_relative"
  TARGET_CONSUMER_READBACK_DIGEST="$final_digest"
  TARGET_CONSUMER_READBACK_COUNT="$readback_count"
}

validate_system_target_attestation_file() {
  local file="$1" id="$2" target="$3" authority_epoch="$4" ledger_sequence="$5"
  local authority_primary="$6" source_device_id="$7" target_device_id="$8"
  local catalog_revision="$9" manifest_digest="${10}"
  local transaction_journal_digest="${11}" skillet_receipt_digest="${12}"
  local consumer_readback_path="${13}" consumer_readback_digest="${14}"
  local consumer_readback_count="${15}"
  [ -s "$file" ] \
    && plutil -convert json -o /dev/null -- "$file" >/dev/null 2>&1 \
    && [ "$(plutil -extract schema raw "$file" 2>/dev/null || true)" = "TatwoTargetLocalSystemAttestationV2" ] \
    && [ "$(plutil -extract kind raw "$file" 2>/dev/null || true)" = "target-local-consumer-readback-attested" ] \
    && [ "$(plutil -extract requestID raw "$file" 2>/dev/null || true)" = "$id" ] \
    && [ "$(plutil -extract target raw "$file" 2>/dev/null || true)" = "$target" ] \
    && [ "$(plutil -extract authorityEpoch raw "$file" 2>/dev/null || true)" = "$authority_epoch" ] \
    && [ "$(plutil -extract ledgerSequence raw "$file" 2>/dev/null || true)" = "$ledger_sequence" ] \
    && [ "$(plutil -extract authorityPrimary raw "$file" 2>/dev/null || true)" = "$authority_primary" ] \
    && [ "$(plutil -extract sourceDeviceID raw "$file" 2>/dev/null || true)" = "$source_device_id" ] \
    && [ "$(plutil -extract targetDeviceID raw "$file" 2>/dev/null || true)" = "$target_device_id" ] \
    && [ "$(plutil -extract catalogRevision raw "$file" 2>/dev/null || true)" = "$catalog_revision" ] \
    && [ "$(plutil -extract transactionPhase raw "$file" 2>/dev/null || true)" = "committed" ] \
    && [ "$(plutil -extract transactionJournalDigest raw "$file" 2>/dev/null || true)" = "$transaction_journal_digest" ] \
    && [ "$(plutil -extract manifestDigest raw "$file" 2>/dev/null || true)" = "$manifest_digest" ] \
    && [ "$(plutil -extract skilletActiveSetReceiptDigest raw "$file" 2>/dev/null || true)" = "$skillet_receipt_digest" ] \
    && [ "$(plutil -extract consumerReadbackKind raw "$file" 2>/dev/null || true)" = "actual-consumer-readback-set" ] \
    && [ "$(plutil -extract consumerReadbackPath raw "$file" 2>/dev/null || true)" = "$consumer_readback_path" ] \
    && [ "$(plutil -extract consumerReadbackDigest raw "$file" 2>/dev/null || true)" = "$consumer_readback_digest" ] \
    && [ "$(plutil -extract consumerReadbackCount raw "$file" 2>/dev/null || true)" = "$consumer_readback_count" ] \
    && [ "$(plutil -extract signaturePurpose raw "$file" 2>/dev/null || true)" = "target-attestation" ] \
    && [ "$(plutil -extract signaturePath raw "$file" 2>/dev/null || true)" = "signatures/attestations/$target/$id.json" ] \
    && [ -n "$(plutil -extract attestedAt raw "$file" 2>/dev/null || true)" ]
}

verify_existing_system_converged_ack_artifacts() {
  local ack="$1" id="$2" target="$3" authority_epoch="$4"
  local ledger_sequence="$5" authority_primary="$6" source_device_id="$7"
  local target_device_id="$8" catalog_revision="$9" manifest_digest="${10}"
  local expected_readback_path="consumer-readbacks/$target/$id.json"
  local expected_attestation_path="attestations/$target/$id.json"
  local readback_kind readback_path readback_digest readback_count readback
  local attestation_kind attestation_path attestation_digest attestation
  local ack_signature_path ack_signature
  local attestation_signature_path attestation_signature
  local transaction_journal transaction_journal_digest skillet_receipt
  local skillet_receipt_digest

  ack_signature_path="$(json_get "$ack" signaturePath)"
  [ "$(json_get "$ack" signaturePurpose)" = "sync-ack" ] \
    && [ "$ack_signature_path" = "signatures/acks/$id.json" ] \
    || {
      log "既有 converged ACK 缺少固定 Ed25519 signature binding：$id"
      return 1
    }
  ack_signature="$CHANNEL_DIR/$ack_signature_path"
  verify_channel_artifact_signature \
    "$target" "$target_device_id" "sync-ack" "$ack" "$ack_signature" \
    || {
      log "既有 converged ACK signature 無法重驗：$id"
      return 1
    }

  readback_kind="$(json_get "$ack" consumerReadbackKind)"
  readback_path="$(json_get "$ack" consumerReadbackPath)"
  readback_digest="$(json_get "$ack" consumerReadbackDigest)"
  readback_count="$(json_number_get "$ack" consumerReadbackCount)"
  [ "$readback_kind" = "actual-consumer-readback-set" ] \
    && [ "$readback_path" = "$expected_readback_path" ] \
    && is_sha256_digest "$readback_digest" \
    && validate_nonnegative_integer "$readback_count" \
    && [ "$readback_count" -ge 5 ] \
    || {
      log "既有 converged ACK 缺少合法 actual consumer readback binding：$id"
      return 1
    }
  readback="$CHANNEL_DIR/$readback_path"
  [ -f "$readback" ] && [ ! -L "$readback" ] \
    && [ "$(sha256_file "$readback")" = "$readback_digest" ] \
    && [ "$(json_number_get "$readback" readbackCount)" = "$readback_count" ] \
    && validate_system_consumer_readback_file \
      "$readback" "$id" "$target" "$authority_epoch" "$ledger_sequence" \
      "$authority_primary" "$source_device_id" "$target_device_id" \
      "$catalog_revision" "$manifest_digest" \
    || {
      log "既有 converged ACK 的 actual consumer readback artifact 無法重驗：$id"
      return 1
    }

  transaction_journal="$(system_transaction_directory "$id")/journal.json"
  [ -f "$transaction_journal" ] && [ ! -L "$transaction_journal" ] \
    && [ "$(json_get "$transaction_journal" phase)" = "committed" ] \
    && [ "$(json_get "$transaction_journal" requestID)" = "$id" ] \
    && [ "$(json_get "$transaction_journal" authorityPrimary)" = "$authority_primary" ] \
    && [ "$(json_number_get "$transaction_journal" authorityEpoch)" = "$authority_epoch" ] \
    && [ "$(json_number_get "$transaction_journal" ledgerSequence)" = "$ledger_sequence" ] \
    && [ "$(json_get "$transaction_journal" catalogRevision)" = "$catalog_revision" ] \
    || {
      log "既有 converged ACK 缺少同一 binding 的 committed transaction journal：$id"
      return 1
    }
  transaction_journal_digest="$(sha256_file "$transaction_journal")"
  is_sha256_digest "$transaction_journal_digest" || return 1

  skillet_receipt="$APP_SUPPORT/device-sync-state/skillet-activation-receipts/$id/set.json"
  if [ ! -f "$skillet_receipt" ]; then
    skillet_receipt="$APP_SUPPORT/device-sync-state/skillet-activation-receipts/$id/committed-replay.json"
  fi
  [ -f "$skillet_receipt" ] && [ ! -L "$skillet_receipt" ] \
    && [ "$(json_get "$skillet_receipt" requestID)" = "$id" ] \
    && [ "$(json_get "$skillet_receipt" sourceDeviceID)" = "$source_device_id" ] \
    && [ "$(json_get "$skillet_receipt" targetDeviceID)" = "$target_device_id" ] \
    && [ "$(json_number_get "$skillet_receipt" authorityEpoch)" = "$authority_epoch" ] \
    && [ "$(json_number_get "$skillet_receipt" ledgerSequence)" = "$ledger_sequence" ] \
    && [ "$(json_get "$skillet_receipt" catalogRevision)" = "$catalog_revision" ] \
    && [ "$(json_get "$skillet_receipt" activationState)" = "active" ] \
    || {
      log "既有 converged ACK 缺少同一 binding 的 Skillet active-set receipt：$id"
      return 1
    }
  skillet_receipt_digest="$(sha256_file "$skillet_receipt")"
  is_sha256_digest "$skillet_receipt_digest" || return 1

  attestation_kind="$(json_get "$ack" attestationKind)"
  attestation_path="$(json_get "$ack" targetAttestationPath)"
  attestation_digest="$(json_get "$ack" targetAttestationDigest)"
  attestation_signature_path="$(json_get "$ack" targetAttestationSignaturePath)"
  [ "$attestation_kind" = "target-local-consumer-readback-attested" ] \
    && [ "$attestation_path" = "$expected_attestation_path" ] \
    && [ "$attestation_signature_path" = "signatures/attestations/$target/$id.json" ] \
    && is_sha256_digest "$attestation_digest" \
    || {
      log "既有 converged ACK 缺少 V2 consumer-bound target attestation：$id"
      return 1
    }
  attestation="$CHANNEL_DIR/$attestation_path"
  attestation_signature="$CHANNEL_DIR/$attestation_signature_path"
  [ -f "$attestation" ] && [ ! -L "$attestation" ] \
    && [ "$(sha256_file "$attestation")" = "$attestation_digest" ] \
    && validate_system_target_attestation_file \
      "$attestation" "$id" "$target" "$authority_epoch" "$ledger_sequence" \
      "$authority_primary" "$source_device_id" "$target_device_id" \
      "$catalog_revision" "$manifest_digest" "$transaction_journal_digest" \
      "$skillet_receipt_digest" "$readback_path" "$readback_digest" \
      "$readback_count" \
    && verify_channel_artifact_signature \
      "$target" "$target_device_id" "target-attestation" \
      "$attestation" "$attestation_signature" \
    || {
      log "既有 converged ACK 的 V2 target attestation artifact 無法重驗：$id"
      return 1
    }
}

write_system_target_attestation() {
  local id="$1" target="$2" authority_epoch="$3" ledger_sequence="$4"
  local authority_primary="$5" source_device_id="$6" target_device_id="$7"
  local catalog_revision="$8" manifest_digest="$9"
  local transaction_journal transaction_phase transaction_journal_digest
  local skillet_receipt skillet_receipt_digest attestation_relative attestation attestation_stage
  local attestation_signature_relative attestation_signature attestation_signature_stage
  local attestation_stage_digest attestation_final_digest
  TARGET_ATTESTATION_KIND=""
  TARGET_ATTESTATION_PATH=""
  TARGET_ATTESTATION_DIGEST=""
  if [ "${TATWO_TEST_MODE:-0}" = "1" ] \
    && [ "${TATWO_TEST_FAIL_TARGET_ATTESTATION:-0}" = "1" ]
  then
    log "測試注入：target-local attestation 建立失敗"
    return 1
  fi
  transaction_journal="$(system_transaction_directory "$id")/journal.json"
  [ -f "$transaction_journal" ] \
    || { log "無法建立 target attestation：缺少 committed transaction journal"; return 1; }
  transaction_phase="$(json_get "$transaction_journal" phase)"
  [ "$transaction_phase" = "committed" ] \
    || { log "無法建立 target attestation：transaction 尚未 committed"; return 1; }
  [ "$(json_get "$transaction_journal" requestID)" = "$id" ] \
    && [ "$(json_get "$transaction_journal" authorityPrimary)" = "$authority_primary" ] \
    && [ "$(json_number_get "$transaction_journal" authorityEpoch)" = "$authority_epoch" ] \
    && [ "$(json_number_get "$transaction_journal" ledgerSequence)" = "$ledger_sequence" ] \
    && [ "$(json_get "$transaction_journal" catalogRevision)" = "$catalog_revision" ] \
    || { log "無法建立 target attestation：transaction journal binding 不一致"; return 1; }
  if ! transaction_journal_digest="$(sha256_file "$transaction_journal")" \
    || ! is_sha256_digest "$transaction_journal_digest"
  then
    log "無法建立 target attestation：transaction journal digest 讀取失敗"
    return 1
  fi
  skillet_receipt="$APP_SUPPORT/device-sync-state/skillet-activation-receipts/$id/set.json"
  if [ ! -f "$skillet_receipt" ]; then
    skillet_receipt="$APP_SUPPORT/device-sync-state/skillet-activation-receipts/$id/committed-replay.json"
  fi
  [ -f "$skillet_receipt" ] \
    || { log "無法建立 target attestation：缺少 Skillet active-set receipt"; return 1; }
  [ "$(json_get "$skillet_receipt" requestID)" = "$id" ] \
    && [ "$(json_get "$skillet_receipt" sourceDeviceID)" = "$source_device_id" ] \
    && [ "$(json_get "$skillet_receipt" targetDeviceID)" = "$target_device_id" ] \
    && [ "$(json_number_get "$skillet_receipt" authorityEpoch)" = "$authority_epoch" ] \
    && [ "$(json_number_get "$skillet_receipt" ledgerSequence)" = "$ledger_sequence" ] \
    && [ "$(json_get "$skillet_receipt" catalogRevision)" = "$catalog_revision" ] \
    && [ "$(json_get "$skillet_receipt" activationState)" = "active" ] \
    || { log "無法建立 target attestation：Skillet receipt binding 不一致"; return 1; }
  if ! skillet_receipt_digest="$(sha256_file "$skillet_receipt")" \
    || ! is_sha256_digest "$skillet_receipt_digest"
  then
    log "無法建立 target attestation：Skillet receipt digest 讀取失敗"
    return 1
  fi
  is_sha256_digest "$manifest_digest" \
    || { log "無法建立 target attestation：manifest digest 不合法"; return 1; }
  [ "$TARGET_CONSUMER_READBACK_KIND" = "actual-consumer-readback-set" ] \
    && [ "$TARGET_CONSUMER_READBACK_PATH" = "consumer-readbacks/$target/$id.json" ] \
    && is_sha256_digest "$TARGET_CONSUMER_READBACK_DIGEST" \
    && validate_nonnegative_integer "$TARGET_CONSUMER_READBACK_COUNT" \
    && [ "$TARGET_CONSUMER_READBACK_COUNT" -ge 5 ] \
    && [ -f "$CHANNEL_DIR/$TARGET_CONSUMER_READBACK_PATH" ] \
    && [ "$(sha256_file "$CHANNEL_DIR/$TARGET_CONSUMER_READBACK_PATH")" = "$TARGET_CONSUMER_READBACK_DIGEST" ] \
    || { log "無法建立 target attestation：actual consumer readback 未完成或 binding 不一致"; return 1; }
  attestation_relative="attestations/$target/$id.json"
  attestation="$CHANNEL_DIR/$attestation_relative"
  attestation_signature_relative="signatures/attestations/$target/$id.json"
  attestation_signature="$CHANNEL_DIR/$attestation_signature_relative"
  mkdir -p "$(dirname "$attestation")" || return 1
  mkdir -p "$(dirname "$attestation_signature")" || return 1
  attestation_stage="$(dirname "$attestation")/.$id.$$.tmp"
  attestation_signature_stage="$(dirname "$attestation_signature")/.$id.$$.tmp"
  if [ "${TATWO_TEST_MODE:-0}" = "1" ] \
    && [ "${TATWO_TEST_PARTIAL_TARGET_ATTESTATION_WRITE:-0}" = "1" ]
  then
    printf '%s' '{"schema":"TatwoTarg' >"$attestation_stage" || true
    log "測試注入：target attestation partial/ENOSPC write"
    return 1
  fi
  if ! cat >"$attestation_stage" <<EOF
{
  "schema": "TatwoTargetLocalSystemAttestationV2",
  "kind": "target-local-consumer-readback-attested",
  "requestID": "$(json_escape "$id")",
  "target": "$(json_escape "$target")",
  "authorityEpoch": $authority_epoch,
  "ledgerSequence": $ledger_sequence,
  "authorityPrimary": "$(json_escape "$authority_primary")",
  "sourceDeviceID": "$(json_escape "$source_device_id")",
  "targetDeviceID": "$(json_escape "$target_device_id")",
  "catalogRevision": "$(json_escape "$catalog_revision")",
  "transactionPhase": "committed",
  "transactionJournalDigest": "$transaction_journal_digest",
  "manifestDigest": "$(json_escape "$manifest_digest")",
  "skilletActiveSetReceiptDigest": "$skillet_receipt_digest",
  "consumerReadbackKind": "$TARGET_CONSUMER_READBACK_KIND",
  "consumerReadbackPath": "$TARGET_CONSUMER_READBACK_PATH",
  "consumerReadbackDigest": "$TARGET_CONSUMER_READBACK_DIGEST",
  "consumerReadbackCount": $TARGET_CONSUMER_READBACK_COUNT,
  "signaturePurpose": "target-attestation",
  "signaturePath": "$attestation_signature_relative",
  "attestedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  then
    log "target attestation atomic stage 寫入失敗：$id"
    return 1
  fi
  validate_system_target_attestation_file \
    "$attestation_stage" "$id" "$target" "$authority_epoch" "$ledger_sequence" \
    "$authority_primary" "$source_device_id" "$target_device_id" "$catalog_revision" \
    "$manifest_digest" "$transaction_journal_digest" "$skillet_receipt_digest" \
    "$TARGET_CONSUMER_READBACK_PATH" "$TARGET_CONSUMER_READBACK_DIGEST" \
    "$TARGET_CONSUMER_READBACK_COUNT" \
    || { log "target attestation atomic stage 寫入/解析/binding 失敗：$id"; return 1; }
  if ! attestation_stage_digest="$(sha256_file "$attestation_stage")" \
    || ! is_sha256_digest "$attestation_stage_digest"
  then
    log "target attestation stage digest 讀取失敗：$id"
    return 1
  fi
  same_filesystem "$attestation_stage" "$(dirname "$attestation")" \
    || { log "target attestation stage 與 final 不在同一 filesystem：$id"; return 1; }
  sign_channel_artifact \
    "target-attestation" "$attestation_stage" "$attestation_signature_stage" \
    || { log "target attestation Ed25519 簽署失敗：$id"; return 1; }
  mv "$attestation_stage" "$attestation" || return 1
  mv "$attestation_signature_stage" "$attestation_signature" || return 1
  if ! attestation_final_digest="$(sha256_file "$attestation")" \
    || ! is_sha256_digest "$attestation_final_digest" \
    || [ "$attestation_final_digest" != "$attestation_stage_digest" ] \
    || ! validate_system_target_attestation_file \
      "$attestation" "$id" "$target" "$authority_epoch" "$ledger_sequence" \
      "$authority_primary" "$source_device_id" "$target_device_id" "$catalog_revision" \
      "$manifest_digest" "$transaction_journal_digest" "$skillet_receipt_digest" \
      "$TARGET_CONSUMER_READBACK_PATH" "$TARGET_CONSUMER_READBACK_DIGEST" \
      "$TARGET_CONSUMER_READBACK_COUNT"
  then
    log "target attestation final digest/readback/binding 失敗：$id"
    return 1
  fi
  verify_channel_artifact_signature \
    "$target" "$target_device_id" "target-attestation" \
    "$attestation" "$attestation_signature" \
    || { log "target attestation signature final readback 失敗：$id"; return 1; }
  TARGET_ATTESTATION_KIND="target-local-consumer-readback-attested"
  TARGET_ATTESTATION_PATH="$attestation_relative"
  TARGET_ATTESTATION_DIGEST="$attestation_final_digest"
}

authority_matches() {
  local expected_primary="$1" expected_epoch="$2"
  channel_ensure
  read_primary_state
  [ "$PRIMARY_NAME" = "$expected_primary" ] && [ "$PRIMARY_EPOCH" = "$expected_epoch" ]
}

record_rejected_request() {
  local rejected_file="$1" id="$2" reason="$3"
  grep -qxF "$id" "$rejected_file" 2>/dev/null || printf '%s\n' "$id" >>"$rejected_file"
  log "拒絕同步指令 id=${id}：${reason}"
}

request_ledger_state_file() {
  local source_device_id="$1"
  case "$source_device_id" in
    ""|.|..|*/*|*[!A-Za-z0-9._:-]*) return 1;;
  esac
  printf '%s\n' "$APP_SUPPORT/device-sync-state/request-ledger-$source_device_id.json"
}

accept_request_ledger_position() {
  local source_device_id="$1" authority_epoch="$2" ledger_sequence="$3" request_id="$4"
  local file previous_epoch="" previous_sequence="" previous_request=""
  validate_epoch "$authority_epoch"
  case "$ledger_sequence" in ""|0|*[!0-9]*) return 1;; esac
  file="$(request_ledger_state_file "$source_device_id")" || return 1
  if [ -f "$file" ]; then
    previous_epoch="$(json_number_get "$file" authorityEpoch)"
    previous_sequence="$(json_number_get "$file" ledgerSequence)"
    previous_request="$(json_get "$file" requestID)"
    validate_epoch "$previous_epoch"
    validate_epoch "$previous_sequence"
    if [ "$previous_epoch" -gt "$authority_epoch" ] \
      || { [ "$previous_epoch" = "$authority_epoch" ] \
        && [ "$previous_sequence" -gt "$ledger_sequence" ]; }
    then
      return 1
    fi
    if [ "$previous_epoch" = "$authority_epoch" ] \
      && [ "$previous_sequence" = "$ledger_sequence" ]
    then
      [ "$previous_request" = "$request_id" ]
      return
    fi
  fi
  mkdir -p "$(dirname "$file")"
  local stage="${file}.$$.tmp"
  cat >"$stage" <<EOF
{
  "sourceDeviceID": "$(json_escape "$source_device_id")",
  "authorityEpoch": $authority_epoch,
  "ledgerSequence": $ledger_sequence,
  "requestID": "$(json_escape "$request_id")",
  "acceptedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  mv "$stage" "$file"
}

request_ledger_position_is_historical() {
  local source_device_id="$1" authority_epoch="$2" ledger_sequence="$3"
  local file previous_epoch previous_sequence
  file="$(request_ledger_state_file "$source_device_id")" || return 1
  [ -f "$file" ] || return 1
  previous_epoch="$(json_number_get "$file" authorityEpoch)"
  previous_sequence="$(json_number_get "$file" ledgerSequence)"
  validate_epoch "$previous_epoch"
  validate_epoch "$previous_sequence"
  [ "$previous_epoch" = "$authority_epoch" ] \
    && [ "$previous_sequence" -gt "$ledger_sequence" ]
}

list_sorted_request_files() {
  local directory="$1"
  local candidate="" candidate_name="" candidate_epoch="" candidate_sequence=""
  for candidate in "$directory"/*.json; do
    [ -f "$candidate" ] || continue
    candidate_name="$(basename "$candidate")"
    case "$candidate_name" in
      ""|*[!A-Za-z0-9._:-]*)
        log "略過含不安全檔名的 request queue entry：${candidate_name:-missing}" >&2
        continue
        ;;
    esac
    candidate_epoch="$(json_number_get "$candidate" authorityEpoch)"
    candidate_sequence="$(json_number_get "$candidate" ledgerSequence)"
    case "$candidate_epoch" in
      ""|*[!0-9]*) candidate_epoch=99999999999999999999;;
    esac
    case "$candidate_sequence" in
      ""|*[!0-9]*) candidate_sequence=99999999999999999999;;
    esac
    printf '%s\t%s\t%s\n' \
      "$candidate_epoch" "$candidate_sequence" "$candidate"
  done \
    | LC_ALL=C sort -t $'\t' -k1,1n -k2,2n -k3,3 \
    | cut -f3-
}

validate_skillet_set() {
  local set_manifest="$1" id="$2" source_device_id="$3" target_device_id="$4"
  local authority_epoch="$5" ledger_sequence="$6" catalog_revision="$7"
  local stage_dir="$8" expected_repository_count="$9"
  local source_mode="${10}" inventory_digest="${11}" fallback_id="${12}"
  local fallback_path="${13}" fallback_digest="${14}"
  [ "$(json_get "$set_manifest" requestID)" = "$id" ] \
    || { log "Skillet set requestID 不一致"; return 1; }
  [ "$(json_get "$set_manifest" catalogRevision)" = "$catalog_revision" ] \
    || { log "Skillet set catalog revision 不一致"; return 1; }
  [ "$(json_number_get "$set_manifest" authorityEpoch)" = "$authority_epoch" ] \
    || { log "Skillet set authority epoch 不一致"; return 1; }
  [ "$(json_number_get "$set_manifest" ledgerSequence)" = "$ledger_sequence" ] \
    || { log "Skillet set ledger sequence 不一致"; return 1; }
  [ "$(json_get "$set_manifest" sourceDeviceID)" = "$source_device_id" ] \
    || { log "Skillet set source device 不一致"; return 1; }
  [ "$(json_get "$set_manifest" targetDeviceID)" = "$target_device_id" ] \
    || { log "Skillet set target device 不一致"; return 1; }
  [ "$(json_get "$set_manifest" sourceMode)" = "$source_mode" ] \
    && [ "$(json_get "$set_manifest" inventoryDigest)" = "$inventory_digest" ] \
    && [ "$(json_get "$set_manifest" fallbackAuthorizationID)" = "$fallback_id" ] \
    && [ "$(json_get "$set_manifest" fallbackAuthorizationPath)" = "$fallback_path" ] \
    && [ "$(json_get "$set_manifest" fallbackAuthorizationDigest)" = "$fallback_digest" ] \
    || { log "Skillet set source provenance 與 system manifest 不一致"; return 1; }
  validate_skillet_source_provenance \
    "$source_mode" "$inventory_digest" "$fallback_id" "$fallback_path" "$fallback_digest" \
    || return 1

  local repository_count index=0 repository_id revision_id content_digest bundle_digest
  local bundle_relative binding_relative expected_bundle expected_binding bundle binding receipt
  repository_count="$(plutil -extract repositories raw "$set_manifest" 2>/dev/null || true)"
  case "$repository_count" in ""|*[!0-9]*)
    log "Skillet set repository count 格式不合法"
    return 1
    ;;
  esac
  [ "$repository_count" -gt 0 ] \
    || { log "Skillet set repository count 必須大於 0"; return 1; }
  case "$expected_repository_count" in ""|*[!0-9]*)
    log "system manifest Skillet repositoryCount 格式不合法"
    return 1
    ;;
  esac
  [ "$repository_count" = "$expected_repository_count" ] \
    || { log "Skillet set repositoryCount 與 system manifest 不一致"; return 1; }
  mkdir -p "$stage_dir/skillet-verification"
  while [ "$index" -lt "$repository_count" ]; do
    repository_id="$(plutil -extract "repositories.$index.repositoryID" raw "$set_manifest" 2>/dev/null || true)"
    revision_id="$(plutil -extract "repositories.$index.revisionID" raw "$set_manifest" 2>/dev/null || true)"
    content_digest="$(plutil -extract "repositories.$index.contentDigest" raw "$set_manifest" 2>/dev/null || true)"
    bundle_digest="$(plutil -extract "repositories.$index.bundleDigest" raw "$set_manifest" 2>/dev/null || true)"
    bundle_relative="$(plutil -extract "repositories.$index.bundleRelativePath" raw "$set_manifest" 2>/dev/null || true)"
    binding_relative="$(plutil -extract "repositories.$index.bindingRelativePath" raw "$set_manifest" 2>/dev/null || true)"
    case "$repository_id" in ""|.|..|*/*|*[!A-Za-z0-9._:-]*)
      log "Skillet set repository id 不安全：${repository_id:-missing}"
      return 1
      ;;
    esac
    is_sha256_digest "$content_digest" \
      || { log "Skillet set content digest 不合法：$repository_id"; return 1; }
    is_sha256_digest "$bundle_digest" \
      || { log "Skillet set bundle digest 不合法：$repository_id"; return 1; }
    [ "$revision_id" = "rev-$content_digest" ] \
      || { log "Skillet set revision/content binding 不一致：$repository_id"; return 1; }
    expected_bundle="repositories/$repository_id/bundle"
    expected_binding="repositories/$repository_id/authority-binding.json"
    [ "$bundle_relative" = "$expected_bundle" ] \
      || { log "Skillet bundle path 不安全：$repository_id"; return 1; }
    [ "$binding_relative" = "$expected_binding" ] \
      || { log "Skillet binding path 不安全：$repository_id"; return 1; }
    bundle="$(dirname "$set_manifest")/$bundle_relative"
    binding="$(dirname "$set_manifest")/$binding_relative"
    [ -d "$bundle" ] && [ -f "$binding" ] \
      || { log "Skillet bundle/binding 缺失：$repository_id"; return 1; }
    receipt="$stage_dir/skillet-verification/$repository_id.json"
    if ! run_skillet_cli skillet verify-bound \
      --bundle "$bundle" \
      --binding "$binding" \
      --request "$id" \
      --source-device "$source_device_id" \
      --target-device "$target_device_id" \
      --authority-epoch "$authority_epoch" \
      --ledger-sequence "$ledger_sequence" \
      --catalog-revision "$catalog_revision" \
      --receipt "$receipt" \
      --json >/dev/null
    then
      log "Skillet authority-bound bundle 驗證失敗：$repository_id"
      return 1
    fi
    [ "$(json_get "$receipt" repositoryID)" = "$repository_id" ] \
      && [ "$(json_get "$receipt" revisionID)" = "$revision_id" ] \
      && [ "$(json_get "$receipt" bundleDigest)" = "$bundle_digest" ] \
      && [ "$(json_get "$receipt" requestID)" = "$id" ] \
      && [ "$(json_get "$receipt" sourceDeviceID)" = "$source_device_id" ] \
      && [ "$(json_get "$receipt" targetDeviceID)" = "$target_device_id" ] \
      && [ "$(json_number_get "$receipt" authorityEpoch)" = "$authority_epoch" ] \
      && [ "$(json_number_get "$receipt" ledgerSequence)" = "$ledger_sequence" ] \
      && [ "$(json_get "$receipt" catalogRevision)" = "$catalog_revision" ] \
      || { log "Skillet verify receipt binding 不一致：$repository_id"; return 1; }
    index=$((index + 1))
  done
  SKILLET_SET_MANIFEST="$set_manifest"
  SKILLET_SET_REPOSITORY_COUNT="$repository_count"
}

activate_skillet_set() {
  local set_manifest="$1" id="$2" source_device_id="$3" target_device_id="$4"
  local authority_primary="$5" authority_epoch="$6" ledger_sequence="$7"
  local catalog_revision="$8"
  local owner_initiated="${9:-0}"
  local receipt_root="$APP_SUPPORT/device-sync-state/skillet-activation-receipts/$id"
  local set_receipt="$receipt_root/set.json"
  local cli_stdout="$receipt_root/import-activate-set.stdout.log"
  local cli_stderr="$receipt_root/import-activate-set.stderr.log"
  local failure_summary=""
  mkdir -p "$receipt_root"

  if [ "${TATWO_TEST_MODE:-0}" = "1" ] \
    && [ -n "${TATWO_TEST_BEFORE_SKILLET_ACTIVATE_HOOK:-}" ]
  then
    bash -c "$TATWO_TEST_BEFORE_SKILLET_ACTIVATE_HOOK"
  fi
  if [ "$SKILLET_APPLY" != "1" ]; then
    log "Skillet activation 略過：TATWO_SKILLET_APPLY=0（不覆蓋本機 skill、不灌進 OS）"
    return 44
  fi
  if ! authority_matches "$authority_primary" "$authority_epoch"; then
    log "OS mirror activation 後主權已切換，拒絕 Skillet activation"
    return 42
  fi

  SKILLET_MERGE_PROPOSAL_COUNT=0
  SKILLET_BRANCH_PRESERVED_COUNT=0
  SKILLET_MERGE_PROPOSAL_IDS_JSON="[]"
  SKILLET_MERGE_RECEIPT_PATH=""
  SKILLET_TARGET_PRESERVED_COUNT=0
  SKILLET_TARGET_PRESERVED_REPOSITORIES_JSON="[]"
  SKILLET_TARGET_PRESERVED_RUNTIME_CLOSURE_CAPABILITY=""
  SKILLET_TARGET_PRESERVED_RUNTIME_CLOSED=false
  if run_skillet_cli skillet import-activate-set \
    --set-manifest "$set_manifest" \
    --store "$SKILLET_STORE" \
    --runtime-root "$SKILLET_RUNTIME_ROOT" \
    --request "$id" \
    --source-device "$source_device_id" \
    --target-device "$target_device_id" \
    --authority-epoch "$authority_epoch" \
    --ledger-sequence "$ledger_sequence" \
    --catalog-revision "$catalog_revision" \
    --activate-target-preserved \
    $([ "$owner_initiated" = "1" ] && printf '%s' "--owner-initiated") \
    --receipt "$set_receipt" \
    --json >"$cli_stdout" 2>"$cli_stderr"
  then
    project_skillet_set_receipt \
      "$set_manifest" "$set_receipt" "$id" "$source_device_id" \
      "$target_device_id" "$authority_epoch" "$ledger_sequence" \
      "$catalog_revision"
    return
  else
    local cli_status=$?
    if [ "$cli_status" = "44" ] \
      && project_skillet_merge_pending_receipt \
        "$set_manifest" "$set_receipt" "$id" "$source_device_id" \
        "$target_device_id" "$authority_epoch" "$ledger_sequence" \
        "$catalog_revision"
    then
      SKILLET_MERGE_RECEIPT_PATH="$set_receipt"
      log "Skillet set 已保存 merge proposals；等待人工 approve/reject，未變更 active runtime"
      return 44
    fi
    failure_summary="$(
      { tail -n 8 "$cli_stderr" 2>/dev/null; tail -n 8 "$cli_stdout" 2>/dev/null; } \
        | tr '\n' ' ' \
        | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
    )"
    if [ -n "$failure_summary" ]; then
      failure_summary="${failure_summary//$APP_SUPPORT/\$TATWO_APP_SUPPORT}"
      failure_summary="${failure_summary//$HOT_SYNC_STAGING/\$TATWO_HOT_SYNC_STAGING}"
      failure_summary="${failure_summary//$HOT_SYNC_MIRROR/\$TATWO_HOT_SYNC_MIRROR}"
      failure_summary="${failure_summary//$SKILLET_STORE/\$TATWO_SKILLET_STORE}"
      failure_summary="${failure_summary//$SKILLET_RUNTIME_ROOT/\$TATWO_SKILLS_RUNTIME_ROOT}"
      log "Skillet aggregate import/activation 失敗：$failure_summary"
    else
      log "Skillet aggregate import/activation 失敗；CLI 未提供 stderr"
    fi
    return "$cli_status"
  fi
}

verify_active_skillet_set() {
  local set_manifest="$1" id="$2" source_device_id="$3" target_device_id="$4"
  local authority_epoch="$5" ledger_sequence="$6" catalog_revision="$7"
  local receipt_root="$APP_SUPPORT/device-sync-state/skillet-activation-receipts/$id"
  local set_receipt="$receipt_root/committed-replay.json"
  local cli_stdout="$receipt_root/verify-active-set.stdout.log"
  local cli_stderr="$receipt_root/verify-active-set.stderr.log"
  local failure_summary=""
  mkdir -p "$receipt_root"
  if ! run_skillet_cli skillet verify-active-set \
    --set-manifest "$set_manifest" \
    --store "$SKILLET_STORE" \
    --runtime-root "$SKILLET_RUNTIME_ROOT" \
    --request "$id" \
    --source-device "$source_device_id" \
    --target-device "$target_device_id" \
    --authority-epoch "$authority_epoch" \
    --ledger-sequence "$ledger_sequence" \
    --catalog-revision "$catalog_revision" \
    --receipt "$set_receipt" \
    --json >"$cli_stdout" 2>"$cli_stderr"
  then
    failure_summary="$(
      tail -n 8 "$cli_stderr" 2>/dev/null \
        | tr '\n' ' ' \
        | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
    )"
    if [ -n "$failure_summary" ]; then
      failure_summary="${failure_summary//$APP_SUPPORT/\$TATWO_APP_SUPPORT}"
      failure_summary="${failure_summary//$SKILLET_STORE/\$TATWO_SKILLET_STORE}"
      failure_summary="${failure_summary//$SKILLET_RUNTIME_ROOT/\$TATWO_SKILLS_RUNTIME_ROOT}"
      log "Skillet committed set 重新驗證失敗：$failure_summary"
    else
      log "Skillet committed set 重新驗證失敗；CLI 未提供 stderr"
    fi
    return 1
  fi
  project_skillet_set_receipt \
    "$set_manifest" "$set_receipt" "$id" "$source_device_id" \
    "$target_device_id" "$authority_epoch" "$ledger_sequence" \
    "$catalog_revision"
}

activate_skills_consumer_projection() {
  local set_manifest="$1" id="$2"
  local receipt_root="$APP_SUPPORT/device-sync-state/skills-consumer-projection-receipts/$id"
  local receipt="$receipt_root/activate.json"
  local cli_stdout="$receipt_root/activate.stdout.log"
  local cli_stderr="$receipt_root/activate.stderr.log"
  local failure_summary="" set_manifest_digest="" repository_count=""
  local activation_receipt="$APP_SUPPORT/device-sync-state/skillet-activation-receipts/$id/set.json"
  require_system_runtime_enrollment || return 1
  if [ "$SKILLET_APPLY" != "1" ]; then
    log "Skills consumer projection 略過：TATWO_SKILLET_APPLY=0（不寫 Codex／Claude 原生 skills、不灌 OS）"
    return 1
  fi
  [ -f "$set_manifest" ] && [ ! -L "$set_manifest" ] \
    || {
      log "Skills consumer projection 缺少 request-bound Skillet set manifest：$id"
      return 1
    }
  mkdir -p "$receipt_root" || return 1
  if [ ! -f "$activation_receipt" ]; then
    activation_receipt="$APP_SUPPORT/device-sync-state/skillet-activation-receipts/$id/committed-replay.json"
  fi
  [ -f "$activation_receipt" ] && [ ! -L "$activation_receipt" ] \
    || {
      log "Skills consumer projection 缺少 request-bound Skillet activation receipt：$id"
      return 1
    }
  if [ "${TATWO_TEST_MODE:-0}" = "1" ] \
    && [ "${TATWO_TEST_FAIL_SKILLS_CONSUMER_PROJECTION:-0}" = "1" ]
  then
    log "測試注入：Skills consumer projection activation 失敗"
    return 1
  fi
  if ! "$SKILLET_PYTHON" "$SKILLS_CONSUMER_PROJECTION_SCRIPT" activate \
    --runtime-root "$SKILLET_RUNTIME_ROOT" \
    --set-manifest "$set_manifest" \
    --activation-receipt "$activation_receipt" \
    --request "$id" \
    --consumer-root "$SKILLS_CONSUMER_ROOT" \
    --codex-skills-link "$CODEX_SKILLS_LINK" \
    --claude-skills-link "$CLAUDE_SKILLS_LINK" \
    --receipt "$receipt" \
    >"$cli_stdout" 2>"$cli_stderr"
  then
    failure_summary="$(
      { tail -n 8 "$cli_stderr" 2>/dev/null; tail -n 8 "$cli_stdout" 2>/dev/null; } \
        | tr '\n' ' ' \
        | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
    )"
    failure_summary="${failure_summary//$HOME/\$HOME}"
    failure_summary="${failure_summary//$APP_SUPPORT/\$TATWO_APP_SUPPORT}"
    failure_summary="${failure_summary//$SKILLET_RUNTIME_ROOT/\$TATWO_SKILLS_RUNTIME_ROOT}"
    failure_summary="${failure_summary//$SKILLS_CONSUMER_ROOT/\$TATWO_SKILLS_CONSUMER_ROOT}"
    log "Skills consumer projection activation 失敗：${failure_summary:-helper returned failure}"
    return 1
  fi
  set_manifest_digest="$(sha256_file "$set_manifest")"
  repository_count="$(plutil -extract repositories raw "$set_manifest" 2>/dev/null || true)"
  [ -f "$receipt" ] && [ ! -L "$receipt" ] \
    && [ "$(plutil -extract schema raw "$receipt" 2>/dev/null || true)" = "TatwoSkillsConsumerProjectionReceiptV1" ] \
    && [ "$(plutil -extract operation raw "$receipt" 2>/dev/null || true)" = "activate" ] \
    && [ "$(plutil -extract status raw "$receipt" 2>/dev/null || true)" = "passed" ] \
    && [ "$(plutil -extract requestID raw "$receipt" 2>/dev/null || true)" = "$id" ] \
    && paths_lexically_equal \
      "$(plutil -extract desiredRoot raw "$receipt" 2>/dev/null || true)" \
      "$SKILLET_RUNTIME_ROOT" \
    && paths_lexically_equal \
      "$(plutil -extract consumerRoot raw "$receipt" 2>/dev/null || true)" \
      "$SKILLS_CONSUMER_ROOT" \
    && paths_lexically_equal \
      "$(plutil -extract currentLink raw "$receipt" 2>/dev/null || true)" \
      "$SKILLS_CONSUMER_ROOT/current" \
    && [ "$(plutil -extract setManifestDigest raw "$receipt" 2>/dev/null || true)" = "$set_manifest_digest" ] \
    && [ "$(plutil -extract repositoryCount raw "$receipt" 2>/dev/null || true)" = "$repository_count" ] \
    && [ "$(plutil -extract targetPreservedCount raw "$receipt" 2>/dev/null || true)" = "$SKILLET_TARGET_PRESERVED_COUNT" ] \
    && [ "$(plutil -extract targetPreservedRepositories raw "$receipt" 2>/dev/null || true)" = "$SKILLET_TARGET_PRESERVED_COUNT" ] \
    && [ "$(plutil -extract nativeConsumers raw "$receipt" 2>/dev/null || true)" = "2" ] \
    && [ "$(plutil -extract nativeConsumers.0.consumerID raw "$receipt" 2>/dev/null || true)" = "codex.native-skills" ] \
    && paths_lexically_equal \
      "$(plutil -extract nativeConsumers.0.linkPath raw "$receipt" 2>/dev/null || true)" \
      "$CODEX_SKILLS_LINK" \
    && paths_lexically_equal \
      "$(plutil -extract nativeConsumers.0.managedTarget raw "$receipt" 2>/dev/null || true)" \
      "$SKILLS_CONSUMER_ROOT/current" \
    && [ "$(plutil -extract nativeConsumers.1.consumerID raw "$receipt" 2>/dev/null || true)" = "claude.native-skills" ] \
    && paths_lexically_equal \
      "$(plutil -extract nativeConsumers.1.linkPath raw "$receipt" 2>/dev/null || true)" \
      "$CLAUDE_SKILLS_LINK" \
    && paths_lexically_equal \
      "$(plutil -extract nativeConsumers.1.managedTarget raw "$receipt" 2>/dev/null || true)" \
      "$SKILLS_CONSUMER_ROOT/current" \
    || {
      log "Skills consumer projection receipt schema/request/native binding 不合法：$id"
      return 1
    }
  require_explicit_skills_consumer_projection \
    || {
      log "Skills consumer projection activation 後 native links 無法重新讀回：$id"
      return 1
    }
}

project_skillet_set_receipt() {
  local set_manifest="$1" set_receipt="$2" id="$3" source_device_id="$4"
  local target_device_id="$5" authority_epoch="$6" ledger_sequence="$7"
  local catalog_revision="$8"
  local index=0 repository_id revision_id content_digest bundle_digest
  local receipt_repository_id receipt_revision_id receipt_content_digest
  local receipt_bundle_digest repositories_json="["
  local target_preserved_count target_preserved_array_count
  local target_preserved_json="[" target_repository_id target_revision_id
  local target_content_digest target_state target_index=0
  local seen_repository_ids="|"
  [ "$(json_get "$set_receipt" requestID)" = "$id" ] \
    && { [ "$(json_get "$set_receipt" schema)" = "TatwoSkilletSetActivationCLIOutputV1" ] \
      || [ "$(json_get "$set_receipt" schema)" = "TatwoSkilletSetActiveVerificationCLIOutputV1" ]; } \
    && [ "$(json_get "$set_receipt" sourceDeviceID)" = "$source_device_id" ] \
    && [ "$(json_get "$set_receipt" targetDeviceID)" = "$target_device_id" ] \
    && [ "$(json_number_get "$set_receipt" authorityEpoch)" = "$authority_epoch" ] \
    && [ "$(json_number_get "$set_receipt" ledgerSequence)" = "$ledger_sequence" ] \
    && [ "$(json_get "$set_receipt" catalogRevision)" = "$catalog_revision" ] \
    && [ "$(json_get "$set_receipt" activationState)" = "active" ] \
    && [ "$(json_get "$set_receipt" targetPreservedRuntimeClosureCapability)" \
      = "target-preserved-runtime-closure-v1" ] \
    && [ "$(json_get "$set_receipt" targetPreservedRuntimeClosed)" = "true" ] \
    && [ "$(json_number_get "$set_receipt" repositoryCount)" = "$SKILLET_SET_REPOSITORY_COUNT" ] \
    || { log "Skillet aggregate activation receipt binding 不一致"; return 1; }

  while [ "$index" -lt "$SKILLET_SET_REPOSITORY_COUNT" ]; do
    repository_id="$(plutil -extract "repositories.$index.repositoryID" raw "$set_manifest" 2>/dev/null || true)"
    revision_id="$(plutil -extract "repositories.$index.revisionID" raw "$set_manifest" 2>/dev/null || true)"
    content_digest="$(plutil -extract "repositories.$index.contentDigest" raw "$set_manifest" 2>/dev/null || true)"
    bundle_digest="$(plutil -extract "repositories.$index.bundleDigest" raw "$set_manifest" 2>/dev/null || true)"
    receipt_repository_id="$(plutil -extract "repositories.$index.repositoryID" raw "$set_receipt" 2>/dev/null || true)"
    receipt_revision_id="$(plutil -extract "repositories.$index.revisionID" raw "$set_receipt" 2>/dev/null || true)"
    receipt_content_digest="$(plutil -extract "repositories.$index.contentDigest" raw "$set_receipt" 2>/dev/null || true)"
    receipt_bundle_digest="$(plutil -extract "repositories.$index.bundleDigest" raw "$set_receipt" 2>/dev/null || true)"
    [ "$receipt_repository_id" = "$repository_id" ] \
      && [ "$receipt_revision_id" = "$revision_id" ] \
      && [ "$receipt_content_digest" = "$content_digest" ] \
      && [ "$receipt_bundle_digest" = "$bundle_digest" ] \
      && [ "$(plutil -extract "repositories.$index.requestID" raw "$set_receipt" 2>/dev/null || true)" = "$id" ] \
      && [ "$(plutil -extract "repositories.$index.sourceDeviceID" raw "$set_receipt" 2>/dev/null || true)" = "$source_device_id" ] \
      && [ "$(plutil -extract "repositories.$index.targetDeviceID" raw "$set_receipt" 2>/dev/null || true)" = "$target_device_id" ] \
      && [ "$(plutil -extract "repositories.$index.authorityEpoch" raw "$set_receipt" 2>/dev/null || true)" = "$authority_epoch" ] \
      && [ "$(plutil -extract "repositories.$index.ledgerSequence" raw "$set_receipt" 2>/dev/null || true)" = "$ledger_sequence" ] \
      && [ "$(plutil -extract "repositories.$index.catalogRevision" raw "$set_receipt" 2>/dev/null || true)" = "$catalog_revision" ] \
      && [ "$(plutil -extract "repositories.$index.activationState" raw "$set_receipt" 2>/dev/null || true)" = "active" ] \
      || { log "Skillet activation receipt binding 不一致：$repository_id"; return 1; }
    seen_repository_ids="${seen_repository_ids}${repository_id}|"
    [ "$index" -eq 0 ] || repositories_json="${repositories_json},"
    repositories_json="${repositories_json}{
        \"repositoryID\":\"$repository_id\",
        \"revisionID\":\"$revision_id\",
        \"contentDigest\":\"$content_digest\",
        \"bundleDigest\":\"$bundle_digest\",
        \"requestID\":\"$id\",
        \"sourceDeviceID\":\"$source_device_id\",
        \"targetDeviceID\":\"$target_device_id\",
        \"authorityEpoch\":$authority_epoch,
        \"ledgerSequence\":$ledger_sequence,
        \"catalogRevision\":\"$catalog_revision\",
        \"phase\":\"verified\"
      }"
    index=$((index + 1))
  done
  SKILLET_ACK_REPOSITORIES_JSON="${repositories_json}]"
  target_preserved_count="$(json_number_get "$set_receipt" targetPreservedCount)"
  target_preserved_array_count="$(
    plutil -extract targetPreservedRepositories raw "$set_receipt" 2>/dev/null || true
  )"
  validate_nonnegative_integer "$target_preserved_count" \
    && [ "$target_preserved_array_count" = "$target_preserved_count" ] \
    || {
      log "Skillet target-preserved repository count 不合法"
      return 1
    }
  while [ "$target_index" -lt "$target_preserved_count" ]; do
    target_repository_id="$(
      plutil -extract "targetPreservedRepositories.$target_index.repositoryID" \
        raw "$set_receipt" 2>/dev/null || true
    )"
    target_revision_id="$(
      plutil -extract "targetPreservedRepositories.$target_index.revisionID" \
        raw "$set_receipt" 2>/dev/null || true
    )"
    target_content_digest="$(
      plutil -extract "targetPreservedRepositories.$target_index.contentDigest" \
        raw "$set_receipt" 2>/dev/null || true
    )"
    target_state="$(
      plutil -extract "targetPreservedRepositories.$target_index.state" \
        raw "$set_receipt" 2>/dev/null || true
    )"
    case "$target_repository_id" in
      ""|.|..|*/*|*[!A-Za-z0-9._-]*)
        log "Skillet target-preserved repository id 不安全"
        return 1
        ;;
    esac
    case "$seen_repository_ids" in
      *"|$target_repository_id|"*)
        log "Skillet target-preserved repository 與 incoming set 重複：$target_repository_id"
        return 1
        ;;
    esac
    [ "$target_revision_id" = "rev-$target_content_digest" ] \
      && is_sha256_digest "$target_content_digest" \
      && [ "$target_state" = "runtime-preserved" ] \
      || {
        log "Skillet target-preserved repository receipt 不合法：$target_repository_id"
        return 1
      }
    [ "$target_index" -eq 0 ] || target_preserved_json="${target_preserved_json},"
    target_preserved_json="${target_preserved_json}{
      \"repositoryID\":\"$(json_escape "$target_repository_id")\",
      \"revisionID\":\"$(json_escape "$target_revision_id")\",
      \"contentDigest\":\"$target_content_digest\",
      \"state\":\"$target_state\",
      \"phase\":\"preserved\"
    }"
    seen_repository_ids="${seen_repository_ids}${target_repository_id}|"
    target_index=$((target_index + 1))
  done
  SKILLET_TARGET_PRESERVED_COUNT="$target_preserved_count"
  SKILLET_TARGET_PRESERVED_REPOSITORIES_JSON="${target_preserved_json}]"
  SKILLET_TARGET_PRESERVED_RUNTIME_CLOSURE_CAPABILITY="target-preserved-runtime-closure-v1"
  SKILLET_TARGET_PRESERVED_RUNTIME_CLOSED=true
}

project_skillet_merge_pending_receipt() {
  local set_manifest="$1" set_receipt="$2" id="$3" source_device_id="$4"
  local target_device_id="$5" authority_epoch="$6" ledger_sequence="$7"
  local catalog_revision="$8"
  local proposal_count branch_preserved_count receipt_repository_count
  local proposal_ids_count proposal_repositories_count
  local branch_preserved_repositories_count
  local index=0 manifest_index manifest_count
  local repository_id proposal_id proposal_source base_revision canonical_revision
  local proposed_revision merged_revision content_digest bundle_digest status
  local conflict_count conflict_ids_count receipt_proposal_id
  local preserved_revision preserved_state
  local manifest_repository_id manifest_revision_id manifest_content_digest
  local manifest_bundle_digest repositories_json="[" proposal_ids_json="["
  local target_preserved_count target_preserved_array_count
  local target_index=0 target_repository_id target_revision_id
  local target_content_digest target_state target_preserved_json="["
  local emitted_count=0 seen_repositories="|"

  [ -s "$set_receipt" ] \
    && [ "$(json_get "$set_receipt" schema)" = "TatwoSkilletSetMergePendingCLIOutputV1" ] \
    && [ "$(json_get "$set_receipt" requestID)" = "$id" ] \
    && [ "$(json_get "$set_receipt" sourceDeviceID)" = "$source_device_id" ] \
    && [ "$(json_get "$set_receipt" targetDeviceID)" = "$target_device_id" ] \
    && [ "$(json_number_get "$set_receipt" authorityEpoch)" = "$authority_epoch" ] \
    && [ "$(json_number_get "$set_receipt" ledgerSequence)" = "$ledger_sequence" ] \
    && [ "$(json_get "$set_receipt" catalogRevision)" = "$catalog_revision" ] \
    && [ "$(json_get "$set_receipt" activationState)" = "merge-pending" ] \
    || { log "Skillet merge-pending receipt binding 不一致"; return 1; }
  proposal_count="$(json_number_get "$set_receipt" proposalCount)"
  branch_preserved_count="$(json_number_get "$set_receipt" branchPreservedCount)"
  receipt_repository_count="$(json_number_get "$set_receipt" repositoryCount)"
  proposal_ids_count="$(plutil -extract proposalIDs raw "$set_receipt" 2>/dev/null || true)"
  proposal_repositories_count="$(plutil -extract repositories raw "$set_receipt" 2>/dev/null || true)"
  branch_preserved_repositories_count="$(
    plutil -extract branchPreservedRepositories raw "$set_receipt" 2>/dev/null || true
  )"
  validate_nonnegative_integer "$proposal_count" \
    && validate_nonnegative_integer "$branch_preserved_count" \
    && validate_nonnegative_integer "$receipt_repository_count" \
    && [ "$proposal_count" -gt 0 ] \
    && [ "$proposal_ids_count" = "$proposal_count" ] \
    && [ "$proposal_repositories_count" = "$proposal_count" ] \
    && [ "$branch_preserved_repositories_count" = "$branch_preserved_count" ] \
    && [ $((proposal_count + branch_preserved_count)) -eq "$receipt_repository_count" ] \
    || { log "Skillet merge-pending proposal count 不合法"; return 1; }

  manifest_count=0
  if [ "$set_manifest" != "-" ]; then
    manifest_count="$(plutil -extract repositories raw "$set_manifest" 2>/dev/null || true)"
    validate_nonnegative_integer "$manifest_count" \
      && [ "$manifest_count" = "$receipt_repository_count" ] \
      || { log "Skillet merge-pending repository count 與 manifest 不一致"; return 1; }
  fi
  while [ "$index" -lt "$proposal_count" ]; do
    repository_id="$(plutil -extract "repositories.$index.repositoryID" raw "$set_receipt" 2>/dev/null || true)"
    proposal_id="$(plutil -extract "repositories.$index.proposalID" raw "$set_receipt" 2>/dev/null || true)"
    proposal_source="$(plutil -extract "repositories.$index.sourceDeviceID" raw "$set_receipt" 2>/dev/null || true)"
    base_revision="$(plutil -extract "repositories.$index.baseRevisionID" raw "$set_receipt" 2>/dev/null || true)"
    canonical_revision="$(plutil -extract "repositories.$index.canonicalRevisionID" raw "$set_receipt" 2>/dev/null || true)"
    proposed_revision="$(plutil -extract "repositories.$index.proposedRevisionID" raw "$set_receipt" 2>/dev/null || true)"
    merged_revision="$(plutil -extract "repositories.$index.mergedRevisionID" raw "$set_receipt" 2>/dev/null || true)"
    content_digest="$(plutil -extract "repositories.$index.contentDigest" raw "$set_receipt" 2>/dev/null || true)"
    bundle_digest="$(plutil -extract "repositories.$index.bundleDigest" raw "$set_receipt" 2>/dev/null || true)"
    status="$(plutil -extract "repositories.$index.status" raw "$set_receipt" 2>/dev/null || true)"
    conflict_count="$(plutil -extract "repositories.$index.conflictCount" raw "$set_receipt" 2>/dev/null || true)"
    conflict_ids_count="$(plutil -extract "repositories.$index.conflictArtifactIDs" raw "$set_receipt" 2>/dev/null || true)"
    receipt_proposal_id="$(plutil -extract "proposalIDs.$index" raw "$set_receipt" 2>/dev/null || true)"
    case "$repository_id" in ""|.|..|*/*|*[!A-Za-z0-9._-]*) return 1;; esac
    is_merge_proposal_id "$proposal_id" \
      && [ "$receipt_proposal_id" = "$proposal_id" ] \
      && [ "$proposal_source" = "$source_device_id" ] \
      && [ -n "$canonical_revision" ] \
      && [ -n "$proposed_revision" ] \
      && is_sha256_digest "$content_digest" \
      && is_sha256_digest "$bundle_digest" \
      && [ "$status" = "pending" ] \
      && validate_nonnegative_integer "$conflict_count" \
      && [ "$conflict_ids_count" = "$conflict_count" ] \
      || { log "Skillet merge proposal receipt 不合法：$repository_id"; return 1; }
    case "$seen_repositories" in
      *"|$repository_id|"*)
        log "Skillet merge-pending receipt 重複 repository：$repository_id"
        return 1
        ;;
    esac
    seen_repositories="${seen_repositories}${repository_id}|"

    if [ "$set_manifest" != "-" ]; then
      manifest_index=0
      manifest_repository_id=""
      while [ "$manifest_index" -lt "$manifest_count" ]; do
        if [ "$(plutil -extract "repositories.$manifest_index.repositoryID" raw "$set_manifest" 2>/dev/null || true)" = "$repository_id" ]; then
          manifest_repository_id="$repository_id"
          manifest_revision_id="$(plutil -extract "repositories.$manifest_index.revisionID" raw "$set_manifest" 2>/dev/null || true)"
          manifest_content_digest="$(plutil -extract "repositories.$manifest_index.contentDigest" raw "$set_manifest" 2>/dev/null || true)"
          manifest_bundle_digest="$(plutil -extract "repositories.$manifest_index.bundleDigest" raw "$set_manifest" 2>/dev/null || true)"
          break
        fi
        manifest_index=$((manifest_index + 1))
      done
      [ "$manifest_repository_id" = "$repository_id" ] \
        && [ "$manifest_revision_id" = "$proposed_revision" ] \
        && [ "$manifest_content_digest" = "$content_digest" ] \
        && [ "$manifest_bundle_digest" = "$bundle_digest" ] \
        || { log "Skillet merge receipt 與 set manifest 不一致：$repository_id"; return 1; }
    fi

    [ "$emitted_count" -eq 0 ] || {
      repositories_json="${repositories_json},"
    }
    [ "$index" -eq 0 ] || {
      proposal_ids_json="${proposal_ids_json},"
    }
    proposal_ids_json="${proposal_ids_json}\"$(json_escape "$proposal_id")\""
    repositories_json="${repositories_json}{
      \"repositoryID\":\"$(json_escape "$repository_id")\",
      \"proposalID\":\"$(json_escape "$proposal_id")\",
      \"sourceDeviceID\":\"$(json_escape "$proposal_source")\",
      \"baseRevisionID\":\"$(json_escape "$base_revision")\",
      \"canonicalRevisionID\":\"$(json_escape "$canonical_revision")\",
      \"proposedRevisionID\":\"$(json_escape "$proposed_revision")\",
      \"mergedRevisionID\":\"$(json_escape "$merged_revision")\",
      \"contentDigest\":\"$content_digest\",
      \"bundleDigest\":\"$bundle_digest\",
      \"conflictCount\":$conflict_count,
      \"status\":\"pending\",
      \"phase\":\"merging\"
    }"
    emitted_count=$((emitted_count + 1))
    index=$((index + 1))
  done

  index=0
  while [ "$index" -lt "$branch_preserved_count" ]; do
    repository_id="$(
      plutil -extract "branchPreservedRepositories.$index.repositoryID" raw \
        "$set_receipt" 2>/dev/null || true
    )"
    preserved_revision="$(
      plutil -extract "branchPreservedRepositories.$index.revisionID" raw \
        "$set_receipt" 2>/dev/null || true
    )"
    content_digest="$(
      plutil -extract "branchPreservedRepositories.$index.contentDigest" raw \
        "$set_receipt" 2>/dev/null || true
    )"
    bundle_digest="$(
      plutil -extract "branchPreservedRepositories.$index.bundleDigest" raw \
        "$set_receipt" 2>/dev/null || true
    )"
    preserved_state="$(
      plutil -extract "branchPreservedRepositories.$index.state" raw \
        "$set_receipt" 2>/dev/null || true
    )"
    case "$repository_id" in ""|.|..|*/*|*[!A-Za-z0-9._-]*) return 1;; esac
    [ -n "$preserved_revision" ] \
      && is_sha256_digest "$content_digest" \
      && is_sha256_digest "$bundle_digest" \
      && [ "$preserved_state" = "branch-preserved" ] \
      || {
        log "Skillet branch-preserved receipt 不合法：$repository_id"
        return 1
      }
    case "$seen_repositories" in
      *"|$repository_id|"*)
        log "Skillet merge-pending receipt 重複 repository：$repository_id"
        return 1
        ;;
    esac
    seen_repositories="${seen_repositories}${repository_id}|"

    if [ "$set_manifest" != "-" ]; then
      manifest_index=0
      manifest_repository_id=""
      while [ "$manifest_index" -lt "$manifest_count" ]; do
        if [ "$(plutil -extract "repositories.$manifest_index.repositoryID" raw "$set_manifest" 2>/dev/null || true)" = "$repository_id" ]; then
          manifest_repository_id="$repository_id"
          manifest_revision_id="$(plutil -extract "repositories.$manifest_index.revisionID" raw "$set_manifest" 2>/dev/null || true)"
          manifest_content_digest="$(plutil -extract "repositories.$manifest_index.contentDigest" raw "$set_manifest" 2>/dev/null || true)"
          manifest_bundle_digest="$(plutil -extract "repositories.$manifest_index.bundleDigest" raw "$set_manifest" 2>/dev/null || true)"
          break
        fi
        manifest_index=$((manifest_index + 1))
      done
      [ "$manifest_repository_id" = "$repository_id" ] \
        && [ "$manifest_revision_id" = "$preserved_revision" ] \
        && [ "$manifest_content_digest" = "$content_digest" ] \
        && [ "$manifest_bundle_digest" = "$bundle_digest" ] \
        || {
          log "Skillet branch-preserved receipt 與 set manifest 不一致：$repository_id"
          return 1
        }
    fi

    [ "$emitted_count" -eq 0 ] || repositories_json="${repositories_json},"
    repositories_json="${repositories_json}{
      \"repositoryID\":\"$(json_escape "$repository_id")\",
      \"revisionID\":\"$(json_escape "$preserved_revision")\",
      \"contentDigest\":\"$content_digest\",
      \"bundleDigest\":\"$bundle_digest\",
      \"status\":\"branch-preserved\",
      \"phase\":\"merging\"
    }"
    emitted_count=$((emitted_count + 1))
    index=$((index + 1))
  done

  [ "$emitted_count" -eq "$receipt_repository_count" ] \
    || { log "Skillet merge-pending ACK repository coverage 不完整"; return 1; }
  target_preserved_count="$(json_number_get "$set_receipt" targetPreservedCount)"
  target_preserved_array_count="$(
    plutil -extract targetPreservedRepositories raw "$set_receipt" 2>/dev/null || true
  )"
  validate_nonnegative_integer "$target_preserved_count" \
    && [ "$target_preserved_array_count" = "$target_preserved_count" ] \
    || {
      log "Skillet merge-pending target-preserved repository count 不合法"
      return 1
    }
  while [ "$target_index" -lt "$target_preserved_count" ]; do
    target_repository_id="$(
      plutil -extract "targetPreservedRepositories.$target_index.repositoryID" \
        raw "$set_receipt" 2>/dev/null || true
    )"
    target_revision_id="$(
      plutil -extract "targetPreservedRepositories.$target_index.revisionID" \
        raw "$set_receipt" 2>/dev/null || true
    )"
    target_content_digest="$(
      plutil -extract "targetPreservedRepositories.$target_index.contentDigest" \
        raw "$set_receipt" 2>/dev/null || true
    )"
    target_state="$(
      plutil -extract "targetPreservedRepositories.$target_index.state" \
        raw "$set_receipt" 2>/dev/null || true
    )"
    case "$target_repository_id" in
      ""|.|..|*/*|*[!A-Za-z0-9._-]*)
        log "Skillet merge-pending target-preserved repository id 不安全"
        return 1
        ;;
    esac
    case "$seen_repositories" in
      *"|$target_repository_id|"*)
        log "Skillet merge-pending target-preserved repository 重複：$target_repository_id"
        return 1
        ;;
    esac
    [ "$target_revision_id" = "rev-$target_content_digest" ] \
      && is_sha256_digest "$target_content_digest" \
      && { [ "$target_state" = "runtime-preserved" ] \
        || [ "$target_state" = "store-preserved" ]; } \
      || {
        log "Skillet merge-pending target-preserved receipt 不合法：$target_repository_id"
        return 1
      }
    [ "$target_index" -eq 0 ] \
      || target_preserved_json="${target_preserved_json},"
    target_preserved_json="${target_preserved_json}{
      \"repositoryID\":\"$(json_escape "$target_repository_id")\",
      \"revisionID\":\"$(json_escape "$target_revision_id")\",
      \"contentDigest\":\"$target_content_digest\",
      \"state\":\"$target_state\",
      \"phase\":\"preserved\"
    }"
    seen_repositories="${seen_repositories}${target_repository_id}|"
    target_index=$((target_index + 1))
  done
  SKILLET_MERGE_PROPOSAL_COUNT="$proposal_count"
  SKILLET_BRANCH_PRESERVED_COUNT="$branch_preserved_count"
  SKILLET_MERGE_PROPOSAL_IDS_JSON="${proposal_ids_json}]"
  SKILLET_ACK_REPOSITORIES_JSON="${repositories_json}]"
  SKILLET_TARGET_PRESERVED_COUNT="$target_preserved_count"
  SKILLET_TARGET_PRESERVED_REPOSITORIES_JSON="${target_preserved_json}]"
  SKILLET_TARGET_PRESERVED_RUNTIME_CLOSURE_CAPABILITY=""
  SKILLET_TARGET_PRESERVED_RUNTIME_CLOSED=false
}

project_system_merge_pending_items() {
  local manifest="$1" manifest_digest="$2" item_count="$3" required_json="$4"
  local required_ids=() item_id display_name source_digest byte_count
  local index=0 items_json="[" message
  while IFS= read -r item_id; do required_ids+=("$item_id"); done \
    < <(system_required_item_ids)
  while [ "$index" -lt "$item_count" ]; do
    item_id="${required_ids[$index]}"
    display_name="$(plutil -extract "items.$index.displayName" raw "$manifest" 2>/dev/null || true)"
    source_digest="$(plutil -extract "items.$index.sourceDigest" raw "$manifest" 2>/dev/null || true)"
    byte_count="$(plutil -extract "items.$index.byteCount" raw "$manifest" 2>/dev/null || true)"
    validate_nonnegative_integer "$byte_count" || return 1
    [ "$index" -eq 0 ] || items_json="${items_json},"
    if [ "$item_id" = "skills.skillet" ]; then
      message="incoming revisions and merge proposals are durable; canonical pointers and active runtimes are unchanged pending human approval"
      items_json="${items_json}{
      \"id\":\"$item_id\",
      \"displayName\":\"$(json_escape "$display_name")\",
      \"phase\":\"merging\",
      \"digestAlgorithm\":\"sha256\",
      \"sourceDigest\":\"$source_digest\",
      \"appliedDigest\":\"\",
      \"message\":\"$(json_escape "$message")\",
      \"repositoryCount\":$SKILLET_SET_REPOSITORY_COUNT,
      \"proposalCount\":$SKILLET_MERGE_PROPOSAL_COUNT,
      \"branchPreservedCount\":$SKILLET_BRANCH_PRESERVED_COUNT,
      \"proposalIDs\":$SKILLET_MERGE_PROPOSAL_IDS_JSON,
      \"repositories\":$SKILLET_ACK_REPOSITORIES_JSON,
      \"targetPreservedCount\":$SKILLET_TARGET_PRESERVED_COUNT,
      \"targetPreservedRepositories\":$SKILLET_TARGET_PRESERVED_REPOSITORIES_JSON,
      \"targetPreservedRuntimeClosed\":false,
      \"progress\":{
        \"completedBytes\":$((byte_count * 2)),
        \"totalBytes\":$((byte_count * 3)),
        \"completedItems\":1,
        \"totalItems\":1,
        \"completedRepositories\":$SKILLET_SET_REPOSITORY_COUNT,
        \"totalRepositories\":$SKILLET_SET_REPOSITORY_COUNT,
        \"currentItem\":\"$(json_escape "$display_name")\"
      }
    }"
    else
      message="payload verified; previous active OS mirror restored while Skillet merge waits for human approval"
      items_json="${items_json}{
      \"id\":\"$item_id\",
      \"displayName\":\"$(json_escape "$display_name")\",
      \"phase\":\"merging\",
      \"digestAlgorithm\":\"sha256\",
      \"sourceDigest\":\"$source_digest\",
      \"appliedDigest\":\"\",
      \"message\":\"$(json_escape "$message")\",
      \"progress\":{
        \"completedBytes\":$((byte_count * 2)),
        \"totalBytes\":$((byte_count * 3)),
        \"completedItems\":1,
        \"totalItems\":1,
        \"completedRepositories\":0,
        \"totalRepositories\":0,
        \"currentItem\":\"$(json_escape "$display_name")\"
      }
    }"
    fi
    index=$((index + 1))
  done
  SYSTEM_SOURCE_DIGEST="$manifest_digest"
  SYSTEM_APPLIED_DIGEST=""
  SYSTEM_REQUIRED_ITEM_IDS_JSON="$required_json"
  SYSTEM_ACK_ITEMS_JSON="${items_json}]"
}

project_system_verified_items() {
  local manifest="$1" manifest_digest="$2" item_count="$3" required_json="$4"
  local skillet_message="$5" os_message="$6"
  local required_ids=() item_id display_name source_digest byte_count items_json="["
  local index=0 item_message
  while IFS= read -r item_id; do
    required_ids+=("$item_id")
  done < <(system_required_item_ids)

  while [ "$index" -lt "$item_count" ]; do
    item_id="${required_ids[$index]}"
    display_name="$(plutil -extract "items.$index.displayName" raw "$manifest" 2>/dev/null || true)"
    source_digest="$(plutil -extract "items.$index.sourceDigest" raw "$manifest" 2>/dev/null || true)"
    byte_count="$(plutil -extract "items.$index.byteCount" raw "$manifest" 2>/dev/null || true)"
    validate_nonnegative_integer "$byte_count" || return 1
    [ "$index" -eq 0 ] || items_json="${items_json},"
    if [ "$item_id" = "skills.skillet" ]; then
      item_message="$skillet_message"
      items_json="${items_json}{
      \"id\":\"$item_id\",
      \"displayName\":\"$display_name\",
      \"phase\":\"verified\",
      \"digestAlgorithm\":\"sha256\",
      \"sourceDigest\":\"$source_digest\",
      \"appliedDigest\":\"$source_digest\",
      \"message\":\"$item_message\",
      \"repositoryCount\":$SKILLET_SET_REPOSITORY_COUNT,
      \"repositories\":$SKILLET_ACK_REPOSITORIES_JSON,
      \"targetPreservedCount\":$SKILLET_TARGET_PRESERVED_COUNT,
      \"targetPreservedRepositories\":$SKILLET_TARGET_PRESERVED_REPOSITORIES_JSON,
      \"targetPreservedRuntimeClosureCapability\":\"$SKILLET_TARGET_PRESERVED_RUNTIME_CLOSURE_CAPABILITY\",
      \"targetPreservedRuntimeClosed\":$SKILLET_TARGET_PRESERVED_RUNTIME_CLOSED,
      \"progress\":{
        \"completedBytes\":$byte_count,
        \"totalBytes\":$byte_count,
        \"completedItems\":1,
        \"totalItems\":1,
        \"completedRepositories\":$SKILLET_SET_REPOSITORY_COUNT,
        \"totalRepositories\":$SKILLET_SET_REPOSITORY_COUNT,
        \"currentItem\":\"$(json_escape "$display_name")\"
      }
    }"
    else
      item_message="$os_message"
      items_json="${items_json}{
      \"id\":\"$item_id\",
      \"displayName\":\"$display_name\",
      \"phase\":\"verified\",
      \"digestAlgorithm\":\"sha256\",
      \"sourceDigest\":\"$source_digest\",
      \"appliedDigest\":\"$source_digest\",
      \"message\":\"$item_message\",
      \"progress\":{
        \"completedBytes\":$byte_count,
        \"totalBytes\":$byte_count,
        \"completedItems\":1,
        \"totalItems\":1,
        \"completedRepositories\":0,
        \"totalRepositories\":0,
        \"currentItem\":\"$(json_escape "$display_name")\"
      }
    }"
    fi
    index=$((index + 1))
  done
  items_json="${items_json}]"

  SYSTEM_SOURCE_DIGEST="$manifest_digest"
  SYSTEM_APPLIED_DIGEST="$manifest_digest"
  SYSTEM_REQUIRED_ITEM_IDS_JSON="$required_json"
  SYSTEM_ACK_ITEMS_JSON="$items_json"
}

rollback_system_mirror_activation() {
  local destination="$1" backup="$2" moved_previous="$3" id="$4" reason="$5"
  local failed_activation="$APP_SUPPORT/hot-sync-failed/$id/os"
  mkdir -p "$(dirname "$failed_activation")"
  if [ -e "$destination" ]; then
    mv "$destination" "$failed_activation" \
      || { log "CRITICAL: 無法隔離失敗的 active OS mirror"; return 1; }
  fi
  if [ "$moved_previous" = "1" ]; then
    mv "$backup" "$destination" \
      || { log "CRITICAL: ${reason} 且 OS mirror rollback 失敗"; return 1; }
    log "${reason}；已回復前一版 OS mirror"
  else
    log "${reason}；無前版 OS mirror 可回復，失敗內容已隔離"
  fi
}

system_transaction_directory() {
  printf '%s\n' "$SYSTEM_TRANSACTION_ROOT/$1"
}

system_transaction_update_phase() {
  local id="$1" phase="$2" message="$3"
  local transaction_dir journal stage
  transaction_dir="$(system_transaction_directory "$id")"
  journal="$transaction_dir/journal.json"
  [ -f "$journal" ] || return 1
  if [ "${TATWO_TEST_MODE:-0}" = "1" ] \
    && [ "${TATWO_TEST_FAIL_PHASE_UPDATE:-}" = "$phase" ]
  then
    log "測試注入：phase update 寫入失敗 phase=$phase"
    return 1
  fi
  stage="$transaction_dir/.journal.$$.tmp"
  cp "$journal" "$stage" \
    && plutil -replace phase -string "$phase" "$stage" \
    && plutil -replace updatedAt -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$stage" \
    && plutil -replace message -string "$message" "$stage" \
    && mv "$stage" "$journal"
}

system_transaction_update_projection() {
  local id="$1" ack_state="$2" recovery_state="$3"
  local transaction_dir journal stage
  transaction_dir="$(system_transaction_directory "$id")"
  journal="$transaction_dir/journal.json"
  [ -f "$journal" ] || return 1
  stage="$transaction_dir/.projection.$$.tmp"
  cp "$journal" "$stage" || return 1
  if [ "$ack_state" != "-" ]; then
    plutil -replace ackState -string "$ack_state" "$stage" || return 1
  fi
  if [ "$recovery_state" != "-" ]; then
    plutil -replace recoveryState -string "$recovery_state" "$stage" || return 1
  fi
  plutil -replace updatedAt -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$stage" \
    || return 1
  mv "$stage" "$journal"
}

archive_system_transaction_os_candidate() {
  local journal="$1" label="$2"
  local os_candidate os_destination candidate_parent candidate_history_root
  os_candidate="$(recorded_absolute_path "$journal" osCandidate)" || return 1
  [ -e "$os_candidate" ] || return 0
  os_destination="$(recorded_absolute_path "$journal" osDestination)" || return 1
  candidate_parent="$(dirname "$os_candidate")"
  candidate_history_root="$(dirname "$os_destination")/.tatwo-sync-candidate-history"
  archive_on_same_volume "$os_candidate" "$candidate_history_root" "$label" \
    || return 1
  if [ -d "$candidate_parent" ]; then
    rmdir "$candidate_parent" \
      || {
        log "OS candidate recovery parent 非空，拒絕隱藏額外資料：$candidate_parent"
        return 1
      }
  elif [ -e "$candidate_parent" ]; then
    log "OS candidate recovery parent 不是目錄：$candidate_parent"
    return 1
  fi
}

system_transaction_archive_previous_attempt() {
  local id="$1" transaction_dir history_root history_destination phase
  local journal runtime_backup_root runtime_root runtime_history runtime_history_destination
  local os_backup os_candidate os_root os_history store_backup store_parent store_history
  transaction_dir="$(system_transaction_directory "$id")"
  [ -d "$transaction_dir" ] || return 0
  journal="$transaction_dir/journal.json"
  phase="$(json_get "$journal" phase)"
  case "$phase" in
    committed|rolledBack|diverged) ;;
    *) return 1;;
  esac
  runtime_backup_root="$(recorded_absolute_path "$journal" runtimeBackupRoot)" \
    || return 1
  runtime_root="$(recorded_absolute_path "$journal" runtimeRoot)" \
    || return 1
  if [ -n "$runtime_backup_root" ] && [ -e "$runtime_backup_root" ]; then
    runtime_history="$runtime_root/.tatwo-sync-rollback-history"
    runtime_history_destination="$runtime_history/$id-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
    mkdir -p "$runtime_history"
    mv "$runtime_backup_root" "$runtime_history_destination" \
      || return 1
    printf '%s\n' "$runtime_history_destination" \
      >"$transaction_dir/runtime-backup-archive-path"
  fi
  store_backup="$(recorded_absolute_path "$journal" storeBackup)" || return 1
  if [ -e "$store_backup" ]; then
    store_parent="$(dirname "$(recorded_absolute_path "$journal" skilletStore)")"
    store_history="$store_parent/.tatwo-sync-store-rollback-history"
    archive_on_same_volume "$store_backup" "$store_history" "$id-store" \
      || return 1
    find "$store_history" -mindepth 1 -maxdepth 1 -name "$id-store-*" \
      -print | LC_ALL=C sort | tail -1 >"$transaction_dir/store-backup-archive-path"
  fi
  os_backup="$(recorded_absolute_path "$journal" osBackup)" || return 1
  if [ -e "$os_backup" ]; then
    os_root="$(dirname "$(recorded_absolute_path "$journal" osDestination)")"
    os_history="$os_root/.tatwo-sync-rollback-history"
    archive_on_same_volume "$os_backup" "$os_history" "$id-os" \
      || return 1
    find "$os_history" -mindepth 1 -maxdepth 1 -name "$id-os-*" \
      -print | LC_ALL=C sort | tail -1 >"$transaction_dir/os-backup-archive-path"
  fi
  os_candidate="$(recorded_absolute_path "$journal" osCandidate)" || return 1
  if [ -e "$os_candidate" ]; then
    archive_system_transaction_os_candidate "$journal" "$id-candidate" \
      || return 1
  fi
  history_root="$APP_SUPPORT/device-sync-state/system-transaction-history"
  history_destination="$history_root/$id-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
  mkdir -p "$history_root"
  mv "$transaction_dir" "$history_destination"
}

restore_directory_snapshot() {
  local snapshot="$1" destination="$2" failed_root="$3" label="$4" id="$5"
  local parent base stage stale
  [ -d "$snapshot" ] || return 1
  [ ! -e "$destination" ] || return 1
  parent="$(dirname "$destination")"
  base="$(basename "$destination")"
  stage="$parent/.${base}.tatwo-restore-$id"
  mkdir -p "$parent" "$failed_root"
  if [ -e "$stage" ]; then
    stale="$failed_root/${label}-partial-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
    mv "$stage" "$stale" || return 1
  fi
  if clone_copy_supported "$snapshot" "$parent"; then
    cp -cR "$snapshot" "$stage" || return 1
  else
    local snapshot_bytes
    snapshot_bytes="$(directory_allocated_bytes "$snapshot")" || return 1
    require_available_space "$parent" "$snapshot_bytes" "rollback restore $label" \
      || return 1
    cp -R "$snapshot" "$stage" || return 1
  fi
  mv "$stage" "$destination"
}

VOLUME_BUDGET_DEVICES=()
VOLUME_BUDGET_PATHS=()
VOLUME_BUDGET_BYTES=()
VOLUME_BUDGET_LABELS=()

volume_budget_reset() {
  VOLUME_BUDGET_DEVICES=()
  VOLUME_BUDGET_PATHS=()
  VOLUME_BUDGET_BYTES=()
  VOLUME_BUDGET_LABELS=()
}

volume_budget_add() {
  local path="$1" bytes="$2" label="$3" device index
  validate_nonnegative_integer "$bytes" || return 1
  device="$(filesystem_device_id "$path")" || return 1
  index=0
  while [ "$index" -lt "${#VOLUME_BUDGET_DEVICES[@]}" ]; do
    if [ "${VOLUME_BUDGET_DEVICES[$index]}" = "$device" ]; then
      VOLUME_BUDGET_BYTES[$index]=$((${VOLUME_BUDGET_BYTES[$index]} + bytes))
      VOLUME_BUDGET_LABELS[$index]="${VOLUME_BUDGET_LABELS[$index]}, $label"
      return 0
    fi
    index=$((index + 1))
  done
  VOLUME_BUDGET_DEVICES+=("$device")
  VOLUME_BUDGET_PATHS+=("$path")
  VOLUME_BUDGET_BYTES+=("$bytes")
  VOLUME_BUDGET_LABELS+=("$label")
}

volume_budget_check() {
  local index=0
  while [ "$index" -lt "${#VOLUME_BUDGET_DEVICES[@]}" ]; do
    require_available_space \
      "${VOLUME_BUDGET_PATHS[$index]}" \
      "${VOLUME_BUDGET_BYTES[$index]}" \
      "${VOLUME_BUDGET_LABELS[$index]}" \
      || return 1
    index=$((index + 1))
  done
}

estimated_snapshot_copy_bytes() {
  local source="$1" destination_parent="$2"
  if clone_copy_supported "$source" "$destination_parent"; then
    # APFS clone copies still need metadata and CoW headroom. Keep a fixed
    # conservative charge while avoiding a false requirement for a second full
    # copy of the same directory.
    printf '4194304\n'
  else
    directory_allocated_bytes "$source"
  fi
}

system_transaction_space_preflight() {
  local set_manifest="$1" stage_dir="$2" os_candidate="$3" store_backup="$4"
  local runtime_backup_root="$5"
  local repository_count index=0 bundle_relative bundle bundle_bytes=0 one_bytes
  local repository_id store_snapshot_bytes=0 swift_staged_store_bytes=0
  local runtime_snapshot_bytes=0
  repository_count="$(plutil -extract repositories raw "$set_manifest" 2>/dev/null || true)"
  validate_nonnegative_integer "$repository_count" || return 1
  while [ "$index" -lt "$repository_count" ]; do
    bundle_relative="$(plutil -extract "repositories.$index.bundleRelativePath" raw "$set_manifest" 2>/dev/null || true)"
    repository_id="$(plutil -extract "repositories.$index.repositoryID" raw "$set_manifest" 2>/dev/null || true)"
    bundle="$(dirname "$set_manifest")/$bundle_relative"
    one_bytes="$(directory_allocated_bytes "$bundle")" || return 1
    bundle_bytes=$((bundle_bytes + one_bytes))
    if [ -d "$SKILLET_RUNTIME_ROOT/$repository_id" ]; then
      one_bytes="$(estimated_snapshot_copy_bytes \
        "$SKILLET_RUNTIME_ROOT/$repository_id" "$runtime_backup_root")" || return 1
      runtime_snapshot_bytes=$((runtime_snapshot_bytes + one_bytes))
    fi
    index=$((index + 1))
  done
  if [ -d "$SKILLET_STORE" ]; then
    store_snapshot_bytes="$(estimated_snapshot_copy_bytes \
      "$SKILLET_STORE" "$(dirname "$store_backup")")" || return 1
    swift_staged_store_bytes="$(estimated_snapshot_copy_bytes \
      "$SKILLET_STORE" "$(dirname "$SKILLET_STORE")")" || return 1
  fi
  local os_candidate_bytes
  os_candidate_bytes="$(estimated_snapshot_copy_bytes \
    "$stage_dir/os" "$(dirname "$os_candidate")")" || return 1

  volume_budget_reset
  volume_budget_add "$APP_SUPPORT" 1048576 "transaction journal and receipts" || return 1
  volume_budget_add "$(dirname "$os_candidate")" "$os_candidate_bytes" "OS target-volume candidate" || return 1
  volume_budget_add "$(dirname "$store_backup")" \
    "$((store_snapshot_bytes + swift_staged_store_bytes + bundle_bytes))" \
    "Skillet shell rollback, Swift staged store and imported revisions" || return 1
  volume_budget_add "$runtime_backup_root" \
    "$((runtime_snapshot_bytes + bundle_bytes))" \
    "Skillet runtime rollback plus activated revisions" || return 1
  volume_budget_check
}

system_transaction_prepare() {
  local set_manifest="$1" id="$2" authority_primary="$3" authority_epoch="$4"
  local ledger_sequence="$5" catalog_revision="$6" destination="$7" os_backup="$8"
  local os_candidate="$9" store_backup="${10}"
  local transaction_dir preparation_dir runtime_backup_root repository_index=0 repository_id
  local had_os=0 had_store=0 runtime_index journal_stage
  transaction_dir="$(system_transaction_directory "$id")"
  if [ -e "$transaction_dir" ]; then
    system_transaction_archive_previous_attempt "$id" \
      || { log "system transaction 已存在且未完成：$id"; return 1; }
  fi
  mkdir -p "$SYSTEM_TRANSACTION_ROOT" || return 1
  preparation_dir="$SYSTEM_TRANSACTION_ROOT/.preparing-$id-$$-$RANDOM"
  mkdir "$preparation_dir" || return 1
  if [ "${TATWO_TEST_MODE:-0}" = "1" ] \
    && [ "${TATWO_TEST_CRASH_AFTER_TRANSACTION_STAGE_CREATE:-0}" = "1" ]
  then
    kill -9 "$$"
  fi
  runtime_backup_root="$SKILLET_RUNTIME_ROOT/.tatwo-sync-rollback/$id"
  [ ! -e "$runtime_backup_root" ] \
    || { log "Skillet runtime rollback path 已存在：$runtime_backup_root"; return 1; }
  [ ! -e "$store_backup" ] \
    || { log "Skillet store rollback path 已存在：$store_backup"; return 1; }
  [ ! -e "$os_backup" ] \
    || { log "OS rollback path 已存在：$os_backup"; return 1; }
  [ ! -e "$os_candidate" ] \
    || { log "OS candidate path 已存在：$os_candidate"; return 1; }

  [ -e "$destination" ] && had_os=1
  if [ -e "$SKILLET_STORE" ]; then
    [ -d "$SKILLET_STORE" ] \
      || { log "Skillet store 不是安全目錄：$SKILLET_STORE"; return 1; }
    had_store=1
  fi

  journal_stage="$preparation_dir/journal.json.tmp"
  cat >"$journal_stage" <<EOF || return 1
{
  "schema": "TatwoSystemSyncTransactionV1",
  "requestID": "$(json_escape "$id")",
  "phase": "preparing",
  "authorityPrimary": "$(json_escape "$authority_primary")",
  "authorityEpoch": $authority_epoch,
  "ledgerSequence": $ledger_sequence,
  "catalogRevision": "$(json_escape "$catalog_revision")",
  "hadOSMirror": $had_os,
  "hadSkilletStore": $had_store,
  "osDestination": "$(json_escape "$destination")",
  "osBackup": "$(json_escape "$os_backup")",
  "osCandidate": "$(json_escape "$os_candidate")",
  "appSupportRoot": "$(json_escape "$APP_SUPPORT")",
  "hotSyncStagingRoot": "$(json_escape "$HOT_SYNC_STAGING")",
  "skilletStore": "$(json_escape "$SKILLET_STORE")",
  "storeBackup": "$(json_escape "$store_backup")",
  "runtimeRoot": "$(json_escape "$SKILLET_RUNTIME_ROOT")",
  "runtimeBackupRoot": "$(json_escape "$runtime_backup_root")",
  "ackState": "pending",
  "recoveryState": "idle",
  "createdAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "updatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "message": "rollback snapshot preparation started; no live activation has begun"
}
EOF
  [ -s "$journal_stage" ] || return 1
  [ "$(plutil -extract schema raw "$journal_stage" 2>/dev/null || true)" = "TatwoSystemSyncTransactionV1" ] \
    && [ "$(plutil -extract requestID raw "$journal_stage" 2>/dev/null || true)" = "$id" ] \
    || return 1
  mv "$journal_stage" "$preparation_dir/journal.json" || return 1
  mv "$preparation_dir" "$transaction_dir" || return 1
  mkdir -p "$runtime_backup_root" || return 1
  runtime_index="$transaction_dir/runtime-index.tsv"
  : >"$runtime_index" || return 1
  if [ "${TATWO_TEST_MODE:-0}" = "1" ] \
    && [ "${TATWO_TEST_CRASH_DURING_TRANSACTION_PREPARE:-0}" = "1" ]
  then
    kill -9 "$$"
  fi

  if [ "$had_store" = "1" ]; then
    copy_directory_snapshot "$SKILLET_STORE" "$store_backup" \
      || { log "無法建立 Skillet store rollback snapshot"; return 1; }
  fi

  while [ "$repository_index" -lt "$SKILLET_SET_REPOSITORY_COUNT" ]; do
    repository_id="$(plutil -extract "repositories.$repository_index.repositoryID" raw "$set_manifest" 2>/dev/null || true)"
    case "$repository_id" in ""|.|..|*/*|*[!A-Za-z0-9._-]*)
      log "system transaction repository id 不安全：$repository_id"
      return 1
      ;;
    esac
    if [ -e "$SKILLET_RUNTIME_ROOT/$repository_id" ]; then
      [ -d "$SKILLET_RUNTIME_ROOT/$repository_id" ] \
        || { log "Skillet active runtime 不是目錄：$repository_id"; return 1; }
      copy_directory_snapshot \
        "$SKILLET_RUNTIME_ROOT/$repository_id" "$runtime_backup_root/$repository_id" \
        || { log "無法建立 Skillet runtime rollback snapshot：$repository_id"; return 1; }
      printf '%s\t1\n' "$repository_id" >>"$runtime_index"
    else
      printf '%s\t0\n' "$repository_id" >>"$runtime_index"
    fi
    repository_index=$((repository_index + 1))
  done

  system_transaction_update_phase "$id" "prepared" \
    "rollback snapshots prepared before live activation"
}

recover_abandoned_system_transaction_preparations() {
  [ -d "$SYSTEM_TRANSACTION_ROOT" ] || return 0
  local preparation archive_root archive_destination name
  archive_root="$APP_SUPPORT/device-sync-state/abandoned-system-transaction-preparations"
  for preparation in "$SYSTEM_TRANSACTION_ROOT"/.preparing-*; do
    [ -d "$preparation" ] || continue
    name="$(basename "$preparation")"
    archive_destination="$archive_root/$name-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
    mkdir -p "$archive_root"
    mv "$preparation" "$archive_destination" || return 1
    log "archived abandoned transaction preparation；未發布 journal，未開始 live activation：$name"
  done
}

system_transaction_abort_prepare() {
  local id="$1" reason="$2"
  local transaction_dir journal stage_root stage_dir
  transaction_dir="$(system_transaction_directory "$id")"
  journal="$transaction_dir/journal.json"
  stage_root="$(recorded_absolute_path "$journal" hotSyncStagingRoot)" || return 1
  stage_dir="$stage_root/$id"
  if [ -e "$stage_dir" ]; then
    archive_on_same_volume "$stage_dir" "$stage_root/.aborted" "$id-prepare" \
      || return 1
  fi
  system_transaction_update_phase "$id" "rolledBack" \
    "$reason; preparation ended before any live activation" || return 1
  system_transaction_update_projection "$id" "not-published" "recovered" || return 1
  log "${reason}；尚未開始 live activation，已安全封存 partial preparation"
}

system_transaction_abort_pre_activation() {
  local id="$1" reason="$2"
  local transaction_dir journal stage_root stage_dir os_candidate
  transaction_dir="$(system_transaction_directory "$id")"
  journal="$transaction_dir/journal.json"
  stage_root="$(recorded_absolute_path "$journal" hotSyncStagingRoot)" || return 1
  stage_dir="$stage_root/$id"
  if [ -e "$stage_dir" ]; then
    archive_on_same_volume "$stage_dir" "$stage_root/.aborted" "$id-old-mirror" \
      || return 1
  fi
  os_candidate="$(recorded_absolute_path "$journal" osCandidate)" || return 1
  if [ -e "$os_candidate" ]; then
    archive_system_transaction_os_candidate \
      "$journal" "$id-old-mirror-candidate" \
      || return 1
  fi
  system_transaction_update_phase "$id" "rolledBack" \
    "$reason; the healthy old mirror was never moved" \
    || return 1
  system_transaction_update_projection "$id" "not-published" "recovered" || return 1
  log "${reason}；舊 OS mirror 尚未移動，保留原 active state 並封存 staged candidate"
}

system_transaction_rollback_os_preserving_skillet() {
  local id="$1" reason="$2" merge_receipt="${3:-}"
  local proposal_count="${4:-0}" repository_count="${5:-0}"
  local transaction_dir journal destination os_backup os_candidate app_support_root
  local stage_root stage_dir had_os failed_root failed_os rollback_failed=0
  local journal_stage
  transaction_dir="$(system_transaction_directory "$id")"
  journal="$transaction_dir/journal.json"
  [ -f "$journal" ] || { log "找不到 merge-pending transaction journal：$id"; return 1; }
  destination="$(recorded_absolute_path "$journal" osDestination)" || return 1
  os_backup="$(recorded_absolute_path "$journal" osBackup)" || return 1
  os_candidate="$(recorded_absolute_path "$journal" osCandidate)" || return 1
  app_support_root="$(recorded_absolute_path "$journal" appSupportRoot)" || return 1
  stage_root="$(recorded_absolute_path "$journal" hotSyncStagingRoot)" || return 1
  had_os="$(json_number_get "$journal" hadOSMirror)"
  validate_nonnegative_integer "$proposal_count" || proposal_count=0
  validate_nonnegative_integer "$repository_count" || repository_count=0
  if [ -z "$merge_receipt" ]; then
    merge_receipt="$app_support_root/device-sync-state/skillet-activation-receipts/$id/set.json"
  fi
  case "$merge_receipt" in
    "$app_support_root"/*) ;;
    *) log "merge-pending receipt 不在受控 App Support：$merge_receipt"; return 1;;
  esac

  # Persist the preserve-store recovery class before touching the OS mirror.
  # A crash from this point must never enter the generic rollback path because
  # that would erase the incoming revisions and merge artifacts.
  system_transaction_update_phase "$id" "mergeRollbackPending" \
    "$reason; Skillet store is durable and must be preserved while the OS mirror rolls back" \
    || return 1
  system_transaction_update_projection "$id" "blocked" "merging" || return 1
  journal_stage="$transaction_dir/.merge-evidence.$$.tmp"
  cp "$journal" "$journal_stage" || return 1
  plutil -insert mergeReceipt -string "$merge_receipt" "$journal_stage" 2>/dev/null \
    || plutil -replace mergeReceipt -string "$merge_receipt" "$journal_stage" \
    || return 1
  plutil -insert mergeProposalCount -integer "$proposal_count" "$journal_stage" 2>/dev/null \
    || plutil -replace mergeProposalCount -integer "$proposal_count" "$journal_stage" \
    || return 1
  plutil -insert mergeRepositoryCount -integer "$repository_count" "$journal_stage" 2>/dev/null \
    || plutil -replace mergeRepositoryCount -integer "$repository_count" "$journal_stage" \
    || return 1
  mv "$journal_stage" "$journal" || return 1

  failed_root="$app_support_root/hot-sync-failed/$id/merge-pending-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
  mkdir -p "$failed_root" || return 1
  if [ -e "$os_candidate" ]; then
    archive_on_same_volume \
      "$os_candidate" "$(dirname "$destination")/.tatwo-sync-failed/$id" \
      "merge-pending-os-candidate" \
      || rollback_failed=1
  fi
  if [ -e "$destination" ]; then
    failed_os="$failed_root/os-current"
    same_filesystem "$destination" "$failed_root" \
      && mv "$destination" "$failed_os" \
      || rollback_failed=1
  fi
  if [ "$had_os" = "1" ]; then
    if [ -e "$os_backup" ]; then
      restore_directory_snapshot \
        "$os_backup" "$destination" "$failed_root" "os-merge-pending" "$id" \
        || rollback_failed=1
    else
      log "CRITICAL: merge-pending transaction 缺少 OS rollback snapshot：$id"
      rollback_failed=1
    fi
  fi
  stage_dir="$stage_root/$id"
  if [ -e "$stage_dir" ]; then
    archive_on_same_volume "$stage_dir" "$stage_root/.merge-pending" "$id" \
      || rollback_failed=1
  fi

  if [ "$rollback_failed" = "1" ]; then
    system_transaction_update_phase "$id" "diverged" \
      "$reason; Skillet merge artifacts were preserved but OS-only rollback is incomplete" \
      || true
    system_transaction_update_projection "$id" "blocked" "diverged" || true
    log "CRITICAL: merge proposals 已保留，但 OS mirror rollback 未完成：$id"
    return 1
  fi
  system_transaction_update_phase "$id" "mergePending" \
    "$reason; previous OS mirror restored, Skillet incoming revisions/proposals/conflicts preserved, runtime unchanged" \
    || return 1
  system_transaction_update_projection "$id" "blocked" "merging" || return 1
  log "${reason}；已回復前一版 OS mirror，保留 Skillet merge proposals，未回滾 store/runtime"
}

system_transaction_rollback() {
  local id="$1" reason="$2"
  local transaction_dir journal destination os_backup os_candidate runtime_backup_root
  local had_os had_store failed_root rollback_failed=0 rollback_irrecoverable=0
  local repository_id had_active
  local active runtime_backup runtime_failed store_backup store_failed stage_dir failed_os
  local app_support_root stage_root skillet_store runtime_root
  transaction_dir="$(system_transaction_directory "$id")"
  journal="$transaction_dir/journal.json"
  [ -f "$journal" ] || { log "找不到 system transaction journal：$id"; return 1; }
  destination="$(recorded_absolute_path "$journal" osDestination)" \
    || { log "system transaction osDestination 不安全：$id"; return 1; }
  os_backup="$(recorded_absolute_path "$journal" osBackup)" \
    || { log "system transaction osBackup 不安全：$id"; return 1; }
  os_candidate="$(recorded_absolute_path "$journal" osCandidate)" \
    || { log "system transaction osCandidate 不安全：$id"; return 1; }
  app_support_root="$(recorded_absolute_path "$journal" appSupportRoot)" \
    || { log "system transaction appSupportRoot 不安全：$id"; return 1; }
  stage_root="$(recorded_absolute_path "$journal" hotSyncStagingRoot)" \
    || { log "system transaction hotSyncStagingRoot 不安全：$id"; return 1; }
  skillet_store="$(recorded_absolute_path "$journal" skilletStore)" \
    || { log "system transaction skilletStore 不安全：$id"; return 1; }
  store_backup="$(recorded_absolute_path "$journal" storeBackup)" \
    || { log "system transaction storeBackup 不安全：$id"; return 1; }
  runtime_root="$(recorded_absolute_path "$journal" runtimeRoot)" \
    || { log "system transaction runtimeRoot 不安全：$id"; return 1; }
  runtime_backup_root="$(recorded_absolute_path "$journal" runtimeBackupRoot)" \
    || { log "system transaction runtimeBackupRoot 不安全：$id"; return 1; }
  had_os="$(json_number_get "$journal" hadOSMirror)"
  had_store="$(json_number_get "$journal" hadSkilletStore)"
  failed_root="$app_support_root/hot-sync-failed/$id/recovery-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
  mkdir -p "$failed_root"

  if [ -e "$os_candidate" ]; then
    archive_on_same_volume \
      "$os_candidate" "$(dirname "$destination")/.tatwo-sync-failed/$id" "os-candidate" \
      || rollback_failed=1
  fi
  if [ -e "$destination" ]; then
    failed_os="$(dirname "$destination")/.tatwo-sync-failed/$id/os-current-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
    mkdir -p "$(dirname "$failed_os")"
    same_filesystem "$destination" "$(dirname "$failed_os")" \
      && mv "$destination" "$failed_os" \
      || rollback_failed=1
  fi
  if [ "$had_os" = "1" ]; then
    if [ -e "$os_backup" ]; then
      restore_directory_snapshot \
        "$os_backup" "$destination" "$failed_root" "os" "$id" \
        || rollback_failed=1
    else
      log "CRITICAL: system transaction 缺少 OS rollback snapshot：$id"
      rollback_failed=1
      rollback_irrecoverable=1
    fi
  fi
  if [ "${TATWO_TEST_MODE:-0}" = "1" ] \
    && [ "${TATWO_TEST_CRASH_DURING_ROLLBACK_AFTER_OS:-0}" = "1" ]
  then
    kill -9 "$$"
  fi

  store_failed="$(dirname "$skillet_store")/.tatwo-sync-store-failed/$id/store-current-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
  if [ -e "$skillet_store" ]; then
    mkdir -p "$(dirname "$store_failed")"
    same_filesystem "$skillet_store" "$(dirname "$store_failed")" \
      && mv "$skillet_store" "$store_failed" \
      || rollback_failed=1
  fi
  if [ "$had_store" = "1" ]; then
    if [ -e "$store_backup" ]; then
      restore_directory_snapshot \
        "$store_backup" "$skillet_store" "$failed_root" "skillet-store" "$id" \
        || rollback_failed=1
    else
      log "CRITICAL: system transaction 缺少 Skillet store rollback snapshot：$id"
      rollback_failed=1
      rollback_irrecoverable=1
    fi
  fi

  while IFS=$'\t' read -r repository_id had_active; do
    [ -n "$repository_id" ] || continue
    active="$runtime_root/$repository_id"
    runtime_backup="$runtime_backup_root/$repository_id"
    runtime_failed="$runtime_root/.tatwo-sync-failed/$id/$repository_id-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
    if [ -e "$active" ]; then
      mkdir -p "$(dirname "$runtime_failed")"
      mv "$active" "$runtime_failed" || rollback_failed=1
    fi
    if [ "$had_active" = "1" ]; then
      if [ -e "$runtime_backup" ]; then
        restore_directory_snapshot \
          "$runtime_backup" "$active" "$failed_root" "runtime-$repository_id" "$id" \
          || rollback_failed=1
      else
        log "CRITICAL: system transaction 缺少 runtime rollback snapshot：$repository_id"
        rollback_failed=1
        rollback_irrecoverable=1
      fi
    fi
  done <"$transaction_dir/runtime-index.tsv"

  stage_dir="$stage_root/$id"
  if [ -e "$stage_dir" ]; then
    archive_on_same_volume "$stage_dir" "$stage_root/.failed" "$id" \
      || rollback_failed=1
  fi

  if [ "$rollback_failed" = "1" ]; then
    if [ "$rollback_irrecoverable" = "1" ]; then
      system_transaction_update_phase "$id" "diverged" \
        "$reason; automatic recovery was incomplete because a required snapshot is missing" \
        || true
      system_transaction_update_projection "$id" "blocked" "diverged" || true
      log "CRITICAL: ${reason}；必要 rollback snapshot 缺失，已標記 diverged"
    else
      system_transaction_update_phase "$id" "rollbackPending" \
        "$reason; rollback is incomplete and will be retried before any new request" \
        || true
      system_transaction_update_projection "$id" "not-published" "rollbackPending" || true
      log "CRITICAL: ${reason}；rollback 尚未完成，保留 immutable snapshots 等待重試"
    fi
    return 1
  fi
  system_transaction_update_phase "$id" "rolledBack" \
    "$reason; previous OS mirror, Skillet store and runtimes restored" || return 1
  system_transaction_update_projection "$id" "not-published" "recovered" || return 1
  log "${reason}；已由 durable journal 回復前一版 OS mirror、Skillet store 與 runtimes"
}

recover_incomplete_system_transactions() {
  recover_abandoned_system_transaction_preparations || return 1
  [ -d "$SYSTEM_TRANSACTION_ROOT" ] || return 0
  local transaction_dir journal id phase had_os destination os_backup
  for transaction_dir in "$SYSTEM_TRANSACTION_ROOT"/*; do
    [ -d "$transaction_dir" ] || continue
    journal="$transaction_dir/journal.json"
    [ -f "$journal" ] \
      || { log "system transaction 缺少 journal：$transaction_dir"; return 1; }
    id="$(json_get "$journal" requestID)"
    phase="$(json_get "$journal" phase)"
    case "$id" in ""|.|..|*/*|*[!A-Za-z0-9._:-]*)
      log "system transaction request id 不安全：$id"
      return 1
      ;;
    esac
    case "$phase" in
      committed|rolledBack) continue;;
      mergePending)
        system_transaction_update_projection "$id" "blocked" "merging" \
          || return 1
        log "system transaction 等待人工 merge 決策：$id"
        continue
        ;;
      mergeRollbackPending)
        system_transaction_rollback_os_preserving_skillet \
          "$id" "恢復中斷的 merge-pending OS-only rollback" \
          "$(json_get "$journal" mergeReceipt)" \
          "$(json_number_get "$journal" mergeProposalCount)" \
          "$(json_number_get "$journal" mergeRepositoryCount)" \
          || return 1
        continue
        ;;
      diverged)
        log "system transaction 已 diverged 且需要人工處理：$id"
        return 1
        ;;
      *)
        system_transaction_update_projection "$id" "-" "recovering" \
          || return 1
        ;;
    esac
    case "$phase" in
      preparing)
        system_transaction_abort_prepare "$id" \
          "偵測到未完成的 system transaction prepare" \
          || return 1
        continue
        ;;
      prepared|osCandidatePreparing|osCandidateReady)
        system_transaction_abort_pre_activation "$id" \
          "偵測到 live mirror move 前中斷的 system transaction phase=$phase" \
          || return 1
        continue
        ;;
      oldMirrorMoveStarted)
        had_os="$(json_number_get "$journal" hadOSMirror)"
        destination="$(recorded_absolute_path "$journal" osDestination)" || return 1
        os_backup="$(recorded_absolute_path "$journal" osBackup)" || return 1
        log "old mirror recovery probe id=$id hadOS=${had_os:-missing} destination=$([ -e "$destination" ] && echo present || echo missing) backup=$([ -e "$os_backup" ] && echo present || echo missing)"
        if [ "$had_os" = "1" ] \
          && [ -e "$destination" ] \
          && [ ! -e "$os_backup" ]
        then
          system_transaction_abort_pre_activation "$id" \
            "偵測到 old mirror move had not completed" \
            || return 1
          continue
        fi
        ;;
    esac
    system_transaction_rollback "$id" \
      "偵測到未完成的 system transaction phase=${phase:-missing}" \
      || return 1
  done
}

apply_system_manifest() {
  legacy_system_adapter_available || return 1
  local request_file="$1" id="$2" authority_primary="$3" authority_epoch="$4"
  local source_device_id="$5" target_device_id="$6" catalog_revision="$7"
  local ledger_sequence="$8" preserve_committed_journal="${9:-0}"
  local manifest_path manifest_digest manifest manifest_actual_digest
  local source_mode inventory_digest fallback_id fallback_path fallback_digest
  require_system_runtime_enrollment || return 1
  manifest_path="$(json_get "$request_file" manifestPath)"
  manifest_digest="$(json_get "$request_file" manifestDigest)"
  [ "$manifest_path" = "payloads/$id/manifest.json" ] \
    || { log "system manifest path 不符合 request id"; return 1; }
  is_sha256_digest "$manifest_digest" \
    || { log "system manifest digest 格式錯誤"; return 1; }
  manifest="$CHANNEL_DIR/$manifest_path"
  [ -f "$manifest" ] || { log "system manifest 不存在"; return 1; }
  manifest_actual_digest="$(sha256_file "$manifest")"
  [ "$manifest_actual_digest" = "$manifest_digest" ] \
    || { log "system manifest digest 不一致"; return 1; }

  [ "$(json_get "$manifest" requestID)" = "$id" ] \
    || { log "system manifest requestID 不一致"; return 1; }
  [ "$(json_get "$manifest" catalogRevision)" = "$catalog_revision" ] \
    || { log "system manifest catalog revision 不一致"; return 1; }
  [ "$(json_number_get "$manifest" authorityEpoch)" = "$authority_epoch" ] \
    || { log "system manifest authority epoch 不一致"; return 1; }
  [ "$(json_number_get "$manifest" ledgerSequence)" = "$ledger_sequence" ] \
    || { log "system manifest ledger sequence 不一致"; return 1; }
  [ "$(json_get "$manifest" authorityPrimary)" = "$authority_primary" ] \
    || { log "system manifest authority primary 不一致"; return 1; }
  [ "$(json_get "$manifest" sourceDeviceID)" = "$source_device_id" ] \
    || { log "system manifest source device 不一致"; return 1; }
  [ "$(json_get "$manifest" targetDeviceID)" = "$target_device_id" ] \
    || { log "system manifest target device 不一致"; return 1; }
  source_mode="$(json_get "$request_file" sourceMode)"
  inventory_digest="$(json_get "$request_file" inventoryDigest)"
  fallback_id="$(json_get "$request_file" fallbackAuthorizationID)"
  fallback_path="$(json_get "$request_file" fallbackAuthorizationPath)"
  fallback_digest="$(json_get "$request_file" fallbackAuthorizationDigest)"
  [ "$(json_get "$manifest" sourceMode)" = "$source_mode" ] \
    && [ "$(json_get "$manifest" inventoryDigest)" = "$inventory_digest" ] \
    && [ "$(json_get "$manifest" fallbackAuthorizationID)" = "$fallback_id" ] \
    && [ "$(json_get "$manifest" fallbackAuthorizationPath)" = "$fallback_path" ] \
    && [ "$(json_get "$manifest" fallbackAuthorizationDigest)" = "$fallback_digest" ] \
    || { log "system manifest source provenance 與 request 不一致"; return 1; }
  validate_skillet_source_provenance \
    "$source_mode" "$inventory_digest" "$fallback_id" "$fallback_path" "$fallback_digest" \
    || return 1

  local transaction_dir transaction_journal transaction_phase=""
  local committed_replay=0
  transaction_dir="$(system_transaction_directory "$id")"
  transaction_journal="$transaction_dir/journal.json"
  if [ -f "$transaction_journal" ]; then
    transaction_phase="$(json_get "$transaction_journal" phase)"
    if [ "$transaction_phase" = "committed" ]; then
      [ "$(json_get "$transaction_journal" requestID)" = "$id" ] \
        && [ "$(json_get "$transaction_journal" authorityPrimary)" = "$authority_primary" ] \
        && [ "$(json_number_get "$transaction_journal" authorityEpoch)" = "$authority_epoch" ] \
        && [ "$(json_number_get "$transaction_journal" ledgerSequence)" = "$ledger_sequence" ] \
        && [ "$(json_get "$transaction_journal" catalogRevision)" = "$catalog_revision" ] \
        || {
          log "committed system transaction 與 request binding 不一致"
          return 1
        }
      committed_replay=1
      if [ "$preserve_committed_journal" != "1" ]; then
        system_transaction_update_projection \
          "$id" "committed-awaiting-ACK" "revalidating-committed" \
          || return 1
      fi
    fi
    if [ "$transaction_phase" = "mergePending" ]; then
      [ "$(json_get "$transaction_journal" requestID)" = "$id" ] \
        && [ "$(json_get "$transaction_journal" authorityPrimary)" = "$authority_primary" ] \
        && [ "$(json_number_get "$transaction_journal" authorityEpoch)" = "$authority_epoch" ] \
        && [ "$(json_number_get "$transaction_journal" ledgerSequence)" = "$ledger_sequence" ] \
        && [ "$(json_get "$transaction_journal" catalogRevision)" = "$catalog_revision" ] \
        || {
          log "merge-pending system transaction 與 request binding 不一致"
          return 1
        }
      local pending_receipt pending_repository_count pending_item_count
      local pending_required_json="[" pending_required_id pending_required_index=0
      pending_receipt="$(json_get "$transaction_journal" mergeReceipt)"
      if [ -z "$pending_receipt" ]; then
        pending_receipt="$APP_SUPPORT/device-sync-state/skillet-activation-receipts/$id/set.json"
      fi
      pending_repository_count="$(json_number_get "$transaction_journal" mergeRepositoryCount)"
      validate_nonnegative_integer "$pending_repository_count" \
        || { log "merge-pending repository count 遺失：$id"; return 1; }
      SKILLET_SET_REPOSITORY_COUNT="$pending_repository_count"
      project_skillet_merge_pending_receipt \
        "-" "$pending_receipt" "$id" "$source_device_id" "$target_device_id" \
        "$authority_epoch" "$ledger_sequence" "$catalog_revision" \
        || { log "merge-pending receipt 無法重驗：$id"; return 1; }
      while IFS= read -r pending_required_id; do
        [ "$pending_required_index" -eq 0 ] \
          || pending_required_json="${pending_required_json},"
        pending_required_json="${pending_required_json}\"$pending_required_id\""
        pending_required_index=$((pending_required_index + 1))
      done < <(system_required_item_ids)
      pending_required_json="${pending_required_json}]"
      pending_item_count="$(plutil -extract items raw "$manifest" 2>/dev/null || true)"
      [ "$pending_item_count" = "$pending_required_index" ] \
        || { log "merge-pending manifest item count 已漂移：$id"; return 1; }
      project_system_merge_pending_items \
        "$manifest" "$manifest_digest" "$pending_item_count" "$pending_required_json" \
        || return 1
      log "request id=$id 仍等待人工 merge 決策；保留 proposals 且不重複 activation"
      return 44
    fi
  fi

  local required_ids=() item_id
  while IFS= read -r item_id; do
    required_ids+=("$item_id")
  done < <(system_required_item_ids)
  local item_count="$(plutil -extract items raw "$manifest" 2>/dev/null || true)"
  [ "$item_count" = "${#required_ids[@]}" ] \
    || { log "system manifest item 數與 catalog active set 不一致"; return 1; }

  local stage_dir
  if [ "$committed_replay" = "1" ]; then
    # Missing-ACK replay is allowed to run indefinitely while the private channel
    # is offline. Reuse one request-bound verification directory so each retry
    # cannot leak another full set of receipts and staged OS files.
    stage_dir="$transaction_dir/committed-replay"
    if [ -e "$stage_dir" ] && [ ! -d "$stage_dir" ]; then
      log "committed replay verification path 不是目錄：$stage_dir"
      return 1
    fi
  else
    stage_dir="$HOT_SYNC_STAGING/$id"
    if [ -e "$stage_dir" ]; then
      if [ ! -e "$transaction_dir" ]; then
        local abandoned_staging_root abandoned_staging
        abandoned_staging_root="$HOT_SYNC_STAGING/.abandoned"
        abandoned_staging="$abandoned_staging_root/$id-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
        mkdir -p "$abandoned_staging_root" || return 1
        mv "$stage_dir" "$abandoned_staging" || return 1
        log "archived abandoned system staging before retry：$id"
      else
        log "system staging 路徑已存在且 transaction 尚在，拒絕混用舊 attempt"
        return 1
      fi
    fi
  fi
  mkdir -p "$stage_dir/os"

  local seen_ids="" display_name payload_relative mirror_relative source_digest byte_count
  local expected_payload expected_mirror payload_file stage_file actual_bytes index=0
  local repository_count required_json="[" skillet_present=0
  while [ "$index" -lt "$item_count" ]; do
    item_id="$(plutil -extract "items.$index.id" raw "$manifest" 2>/dev/null || true)"
    display_name="$(plutil -extract "items.$index.displayName" raw "$manifest" 2>/dev/null || true)"
    payload_relative="$(plutil -extract "items.$index.payloadRelativePath" raw "$manifest" 2>/dev/null || true)"
    mirror_relative="$(plutil -extract "items.$index.mirrorRelativePath" raw "$manifest" 2>/dev/null || true)"
    source_digest="$(plutil -extract "items.$index.sourceDigest" raw "$manifest" 2>/dev/null || true)"
    byte_count="$(plutil -extract "items.$index.byteCount" raw "$manifest" 2>/dev/null || true)"
    [ "$item_id" = "${required_ids[$index]}" ] \
      || { log "system manifest item 順序不符合 catalog active set：$item_id"; return 1; }
    case " $seen_ids " in *" $item_id "*)
      log "system manifest 重複 item：$item_id"
      return 1
      ;;
    esac
    seen_ids="${seen_ids}${seen_ids:+ }$item_id"
    expected_payload="$(system_item_payload_path "$item_id")" \
      || { log "system-pull 缺少 payload adapter：$item_id"; return 1; }
    expected_mirror="$(system_item_mirror_path "$item_id")" \
      || { log "system-pull 缺少 activation adapter：$item_id"; return 1; }
    [ "$payload_relative" = "$expected_payload" ] \
      || { log "system manifest payload path 不安全：$item_id"; return 1; }
    [ "$mirror_relative" = "$expected_mirror" ] \
      || { log "system manifest mirror path 不安全：$item_id"; return 1; }
    is_sha256_digest "$source_digest" \
      || { log "system source digest 格式錯誤：$item_id"; return 1; }
    case "$byte_count" in ""|*[!0-9]*)
      log "system byteCount 格式錯誤：$item_id"
      return 1
      ;;
    esac
    payload_file="$(dirname "$manifest")/$payload_relative"
    [ -f "$payload_file" ] || { log "system payload 不存在：$item_id"; return 1; }
    actual_bytes="$(file_byte_count "$payload_file")"
    [ "$actual_bytes" = "$byte_count" ] \
      || { log "system payload byteCount 不一致：$item_id"; return 1; }
    [ "$(sha256_file "$payload_file")" = "$source_digest" ] \
      || { log "system payload digest 不一致：$item_id"; return 1; }

    if [ "$item_id" = "skills.skillet" ]; then
      repository_count="$(plutil -extract "items.$index.repositoryCount" raw "$manifest" 2>/dev/null || true)"
      case "$repository_count" in ""|*[!0-9]*)
        log "skills.skillet repositoryCount 不合法"
        return 1
        ;;
      esac
      validate_skillet_set \
        "$payload_file" "$id" "$source_device_id" "$target_device_id" \
        "$authority_epoch" "$ledger_sequence" "$catalog_revision" \
        "$stage_dir" "$repository_count" \
        "$source_mode" "$inventory_digest" "$fallback_id" "$fallback_path" \
        "$fallback_digest" || return $?
      skillet_present=1
    else
      stage_file="$stage_dir/$mirror_relative"
      mkdir -p "$(dirname "$stage_file")"
      cp "$payload_file" "$stage_file"
      [ "$(file_byte_count "$stage_file")" = "$byte_count" ] \
        && [ "$(sha256_file "$stage_file")" = "$source_digest" ] \
        || { log "system staging validation 失敗：$item_id"; return 1; }
    fi

    [ "$index" -eq 0 ] || required_json="${required_json},"
    required_json="${required_json}\"$item_id\""
    index=$((index + 1))
  done
  required_json="${required_json}]"
  [ "$skillet_present" = "1" ] \
    || { log "catalog active set 缺少 skills.skillet"; return 1; }
  if [ "$SYNC_PROGRESS_ENABLED" = "1" ] && [ "$SYNC_PROGRESS_ID" = "$id" ]; then
    write_sync_progress_ack \
      "validating" 2 "$item_count" "$repository_count" \
      "逐項 digest 與 authority binding" \
      "payload bytes、Work OS items 與 Skillet repositories 已完成 staging readback 驗證" \
      || return 1
  fi

  if [ "$committed_replay" = "1" ]; then
    if ! authority_matches "$authority_primary" "$authority_epoch"; then
      system_transaction_rollback "$id" \
        "committed transaction 尚未寫 ACK 時 authority 已切換" || true
      log "committed transaction 的 authority 已過期；禁止補寫 converged ACK"
      return 43
    fi
    if ! verify_active_skillet_set \
      "$SKILLET_SET_MANIFEST" "$id" "$source_device_id" "$target_device_id" \
      "$authority_epoch" "$ledger_sequence" "$catalog_revision"
    then
      log "committed transaction 的 Skillet active set 無法重新驗證"
      return 1
    fi
    index=0
    while [ "$index" -lt "$item_count" ]; do
      item_id="${required_ids[$index]}"
      if [ "$item_id" != "skills.skillet" ]; then
        mirror_relative="$(system_item_mirror_path "$item_id")"
        source_digest="$(plutil -extract "items.$index.sourceDigest" raw "$manifest" 2>/dev/null || true)"
        if [ "$(sha256_file "$HOT_SYNC_MIRROR/$mirror_relative")" != "$source_digest" ]; then
          log "committed transaction active mirror digest 不一致：$item_id"
          return 1
        fi
      fi
      index=$((index + 1))
    done
    project_system_verified_items \
      "$manifest" "$manifest_digest" "$item_count" "$required_json" \
      "committed active set and device heads reverified after pre-ACK process exit" \
      "committed active mirror reverified after pre-ACK process exit"
    if [ "$preserve_committed_journal" != "1" ]; then
      system_transaction_update_phase "$id" "committed" \
        "committed state reverified; target ACK can be reconstructed without reactivation" \
        || return 1
      system_transaction_update_projection \
        "$id" "committed-awaiting-ACK" "reverified" \
        || return 1
    fi
    log "committed transaction 已重新驗證；不重複 activation，僅重建 target ACK"
    return 0
  fi

  if [ "${TATWO_TEST_MODE:-0}" = "1" ] && [ -n "${TATWO_TEST_BEFORE_ACTIVATE_HOOK:-}" ]; then
    bash -c "$TATWO_TEST_BEFORE_ACTIVATE_HOOK"
  fi
  if ! authority_matches "$authority_primary" "$authority_epoch"; then
    log "system payload staging 後主權已切換，拒絕 activation"
    return 42
  fi
  if [ "$SYNC_PROGRESS_ENABLED" = "1" ] && [ "$SYNC_PROGRESS_ID" = "$id" ]; then
    write_sync_progress_ack \
      "activating" 2 "$item_count" "$repository_count" \
      "Work OS mirror 與 Skillet active set" \
      "來源 payload 已驗證，正在建立 rollback snapshots 並進入整組 activation" \
      || return 1
  fi

  local destination="$HOT_SYNC_MIRROR/os"
  local backup="$HOT_SYNC_MIRROR/.tatwo-sync-rollback/$id/os"
  local os_candidate="$HOT_SYNC_MIRROR/.tatwo-sync-candidates/$id/os"
  local store_backup="$(dirname "$SKILLET_STORE")/.tatwo-sync-store-rollback/$id/store"
  local runtime_backup_root="$SKILLET_RUNTIME_ROOT/.tatwo-sync-rollback/$id"
  local moved_previous=0 skillet_activation_status
  system_transaction_space_preflight \
    "$SKILLET_SET_MANIFEST" "$stage_dir" "$os_candidate" "$store_backup" \
    "$runtime_backup_root" \
    || {
      log "system transaction space budget 未通過；尚未開始 live activation"
      return 1
    }
  system_transaction_prepare \
    "$SKILLET_SET_MANIFEST" "$id" "$authority_primary" "$authority_epoch" \
    "$ledger_sequence" "$catalog_revision" "$destination" "$backup" \
    "$os_candidate" "$store_backup" \
    || return 1
  mkdir -p "$(dirname "$destination")" "$(dirname "$backup")" "$(dirname "$os_candidate")"
  system_transaction_update_phase "$id" "osCandidatePreparing" \
    "copying the verified OS set onto the destination filesystem before any live rename" \
    || {
      system_transaction_abort_pre_activation "$id" \
        "無法持久化 OS candidate preparation journal" || true
      return 1
    }
  if ! copy_directory_snapshot "$stage_dir/os" "$os_candidate"; then
    system_transaction_abort_pre_activation "$id" \
      "OS target-volume candidate 建立失敗" || true
    return 1
  fi
  index=0
  while [ "$index" -lt "$item_count" ]; do
    item_id="${required_ids[$index]}"
    if [ "$item_id" != "skills.skillet" ]; then
      mirror_relative="$(system_item_mirror_path "$item_id")"
      source_digest="$(plutil -extract "items.$index.sourceDigest" raw "$manifest" 2>/dev/null || true)"
      if [ "$(sha256_file "$os_candidate/${mirror_relative#os/}")" != "$source_digest" ]; then
        system_transaction_abort_pre_activation "$id" \
          "OS target-volume candidate digest 失敗" || true
        return 1
      fi
    fi
    index=$((index + 1))
  done
  system_transaction_update_phase "$id" "osCandidateReady" \
    "destination-volume OS candidate passed byte and digest readback" \
    || {
      system_transaction_abort_pre_activation "$id" \
        "無法持久化 OS candidate ready journal" || true
      return 1
    }
  system_transaction_update_phase "$id" "oldMirrorMoveStarted" \
    "durable intent recorded before moving the old OS mirror" \
    || {
      system_transaction_abort_pre_activation "$id" \
        "無法持久化 old mirror move intent" || true
      return 1
    }
  if [ "${TATWO_TEST_MODE:-0}" = "1" ] \
    && [ "${TATWO_TEST_CRASH_BEFORE_OLD_MIRROR_MOVE:-0}" = "1" ]
  then
    kill -9 "$$"
  fi
  if [ -e "$destination" ]; then
    mv "$destination" "$backup" \
      || {
        system_transaction_rollback "$id" "system mirror 舊版封存失敗" || true
        return 1
      }
    moved_previous=1
  fi
  system_transaction_update_phase "$id" "oldMirrorBackedUp" \
    "old OS mirror moved to its request-bound rollback path" \
    || {
      system_transaction_rollback "$id" "無法持久化 old mirror backup journal" || true
      return 1
    }
  system_transaction_update_phase "$id" "newMirrorInstallStarted" \
    "durable intent recorded before installing the staged OS mirror" \
    || {
      system_transaction_rollback "$id" "無法持久化 new mirror install journal" || true
      return 1
    }
  if ! same_filesystem "$os_candidate" "$(dirname "$destination")" \
    || ! mv "$os_candidate" "$destination"
  then
    system_transaction_rollback "$id" "system mirror set activation 失敗" || true
    log "system mirror set activation 失敗"
    return 1
  fi
  system_transaction_update_phase "$id" "osActive" \
    "OS mirror active; Skillet activation not yet committed" \
    || {
      system_transaction_rollback "$id" "無法持久化 OS activation journal" || true
      return 1
    }
  if [ "${TATWO_TEST_MODE:-0}" = "1" ] \
    && [ "${TATWO_TEST_CRASH_AFTER_OS_ACTIVATE:-0}" = "1" ]
  then
    kill -9 "$$"
  fi
  if [ "${TATWO_TEST_MODE:-0}" = "1" ] \
    && [ -n "${TATWO_TEST_AFTER_ACTIVATE_HOOK:-}" ]
  then
    bash -c "$TATWO_TEST_AFTER_ACTIVATE_HOOK"
  fi

  index=0
  local activation_valid=1
  while [ "$index" -lt "$item_count" ]; do
    item_id="${required_ids[$index]}"
    if [ "$item_id" != "skills.skillet" ]; then
      mirror_relative="$(system_item_mirror_path "$item_id")"
      source_digest="$(plutil -extract "items.$index.sourceDigest" raw "$manifest" 2>/dev/null || true)"
      if [ "$(sha256_file "$HOT_SYNC_MIRROR/$mirror_relative")" != "$source_digest" ]; then
        log "system activated mirror digest 不一致：$item_id"
        activation_valid=0
        break
      fi
    fi
    index=$((index + 1))
  done
  if [ "$activation_valid" != "1" ]; then
    system_transaction_rollback "$id" "activated mirror digest 失敗" || return 1
    return 1
  fi

  system_transaction_update_phase "$id" "skilletActivating" \
    "aggregate Skillet activation started" \
    || {
      system_transaction_rollback "$id" "無法持久化 Skillet activation journal" || true
      return 1
    }
  # Owner-intent: this path is only reached after the signed sync-request
  # from the registered authority primary was verified. Lane bundles must
  # not pass this flag; they stay in the proposal box.
  if activate_skillet_set \
    "$SKILLET_SET_MANIFEST" "$id" "$source_device_id" "$target_device_id" \
    "$authority_primary" "$authority_epoch" "$ledger_sequence" "$catalog_revision" \
    "1"
  then
    :
  else
    skillet_activation_status=$?
    if [ "$skillet_activation_status" = "44" ]; then
      system_transaction_rollback_os_preserving_skillet \
        "$id" "Skillet divergent history 需要人工 merge approval" \
        "$SKILLET_MERGE_RECEIPT_PATH" "$SKILLET_MERGE_PROPOSAL_COUNT" \
        "$SKILLET_SET_REPOSITORY_COUNT" \
        || return 1
      project_system_merge_pending_items \
        "$manifest" "$manifest_digest" "$item_count" "$required_json" \
        || return 1
      return 44
    fi
    system_transaction_rollback "$id" \
      "Skillet import/activation 未形成完整閉環" || return 1
    return "$skillet_activation_status"
  fi
  system_transaction_update_phase "$id" "skilletActive" \
    "OS mirror and Skillet set active; final authority fence pending" \
    || {
      system_transaction_rollback "$id" "無法持久化 Skillet committed journal" || true
      return 1
    }

  if [ "${TATWO_TEST_MODE:-0}" = "1" ] \
    && [ -n "${TATWO_TEST_AFTER_SKILLET_ACTIVATE_HOOK:-}" ]
  then
    bash -c "$TATWO_TEST_AFTER_SKILLET_ACTIVATE_HOOK"
  fi

  if ! authority_matches "$authority_primary" "$authority_epoch"; then
    local diverged_items_json="[" diverged_message
    if system_transaction_rollback "$id" \
      "Skillet activation 後、最終 ACK 前 authority 已切換"
    then
      diverged_message="activation was verified but rolled back because the final authority fence changed before convergence could be acknowledged"
      SYSTEM_APPLIED_DIGEST=""
    else
      diverged_message="activation finished and the final authority fence changed; automatic rollback was incomplete"
      SYSTEM_APPLIED_DIGEST="$manifest_digest"
    fi
    index=0
    while [ "$index" -lt "$item_count" ]; do
      item_id="${required_ids[$index]}"
      display_name="$(plutil -extract "items.$index.displayName" raw "$manifest" 2>/dev/null || true)"
      source_digest="$(plutil -extract "items.$index.sourceDigest" raw "$manifest" 2>/dev/null || true)"
      [ "$index" -eq 0 ] || diverged_items_json="${diverged_items_json},"
      if [ "$item_id" = "skills.skillet" ]; then
        diverged_items_json="${diverged_items_json}{
        \"id\":\"$item_id\",
        \"displayName\":\"$display_name\",
        \"phase\":\"diverged\",
        \"digestAlgorithm\":\"sha256\",
        \"sourceDigest\":\"$source_digest\",
        \"appliedDigest\":\"\",
        \"message\":\"$diverged_message\",
        \"repositoryCount\":$SKILLET_SET_REPOSITORY_COUNT,
        \"repositories\":$SKILLET_ACK_REPOSITORIES_JSON,
        \"targetPreservedCount\":$SKILLET_TARGET_PRESERVED_COUNT,
        \"targetPreservedRepositories\":$SKILLET_TARGET_PRESERVED_REPOSITORIES_JSON,
        \"targetPreservedRuntimeClosureCapability\":\"$SKILLET_TARGET_PRESERVED_RUNTIME_CLOSURE_CAPABILITY\",
        \"targetPreservedRuntimeClosed\":$SKILLET_TARGET_PRESERVED_RUNTIME_CLOSED
      }"
      else
        diverged_items_json="${diverged_items_json}{
        \"id\":\"$item_id\",
        \"displayName\":\"$display_name\",
        \"phase\":\"diverged\",
        \"digestAlgorithm\":\"sha256\",
        \"sourceDigest\":\"$source_digest\",
        \"appliedDigest\":\"\",
        \"message\":\"$diverged_message\"
      }"
      fi
      index=$((index + 1))
    done
    diverged_items_json="${diverged_items_json}]"
    SYSTEM_SOURCE_DIGEST="$manifest_digest"
    SYSTEM_REQUIRED_ITEM_IDS_JSON="$required_json"
    SYSTEM_ACK_ITEMS_JSON="$diverged_items_json"
    log "Skillet activation 後 authority 已切換；禁止 converged，要求新 epoch 重新同步"
    return 43
  fi

  project_system_verified_items \
    "$manifest" "$manifest_digest" "$item_count" "$required_json" \
    "authority-bound bundles verified, imported transactionally and activated with device-head receipts" \
    "staged, byte-count verified, SHA-256 verified and activated as one OS mirror set"
  system_transaction_update_phase "$id" "committed" \
    "OS mirror and Skillet repositories verified under the final authority fence" \
    || return 1
  system_transaction_update_projection \
    "$id" "committed-awaiting-ACK" "idle" \
    || return 1
  cleanup_committed_system_transients "$id" "$stage_dir" "$os_candidate" \
    || {
      log "committed transaction 暫存清理失敗；保留 journal 並等待 bounded replay"
      return 1
    }
  return 0
}

cmd_sync_poll() {  # 在副設備 helper 跑：看有無主設備發起的指令，有就執行
  local device="$DEVICE_NAME" from="$PRIMARY_SSH_HOST"
  while [ $# -gt 0 ]; do case "$1" in
    --device) device="$2"; shift 2;;
    --from) from="$2"; shift 2;;
    *) die "未知參數 $1";; esac; done
  [ -n "$from" ] || { echo "請設定 TATWO_PRIMARY_SSH_HOST" >&2; exit 2; }
  recover_incomplete_system_transactions \
    || die "未完成的 system transaction 無法安全恢復；拒絕處理新同步 request"
  channel_ensure
  local retention_allows_new_apply=1
  if ! retention_budget_status; then
    retention_allows_new_apply=0
    log "retention budget 已滿；拒絕新 activation，但允許既有 committed-awaiting-ACK 使用 request-bound 路徑完成驗證與終端 ACK"
  fi
  local state_dir="$APP_SUPPORT/device-sync-state"; mkdir -p "$state_dir"
  local processed="$state_dir/processed-ids-$device"
  local rejected="$state_dir/rejected-ids-$device"
  local acted=0
  local runtime_enrollment_blocked=0
  ensure_device_identity
  local local_device_id
  local_device_id="$(json_get "$(device_identity_file)" deviceId)"

  for tgt in "$device"; do
    local request_files=""
    if [ -d "$CHANNEL_DIR/requests/$tgt" ]; then
      # Request IDs include a timestamp plus a random suffix, so filename order is
      # not ledger order. Process by authority epoch + monotonic sequence or a
      # later random filename can advance the high-water mark and make an older
      # queued request look like a replay attack.
      request_files="$(list_sorted_request_files "$CHANNEL_DIR/requests/$tgt")"
    fi
    # Legacy single-slot request is read-only compatibility. New writers never create it.
    if [ -f "$CHANNEL_DIR/requests/$tgt.json" ]; then
      request_files="${request_files}${request_files:+$'\n'}$CHANNEL_DIR/requests/$tgt.json"
    fi
    [ -n "$request_files" ] || continue

    local rf
    while IFS= read -r rf; do
      [ -n "$rf" ] || continue
      local id action requested_at request_target authority_epoch authority_primary
      local source_device_id target_device_id catalog_revision requested_by source_device_name
      local ledger_sequence request_digest_algorithm request_source_digest
      local request_source_mode request_inventory_digest request_fallback_id
      local request_fallback_path request_fallback_digest
      id="$(json_get "$rf" requestID)"
      [ -n "$id" ] || id="$(json_get "$rf" id)"
      action="$(json_get "$rf" action)"
      requested_at="$(json_get "$rf" requestedAt)"
      request_target="$(json_get "$rf" target)"
      authority_epoch="$(json_number_get "$rf" authorityEpoch)"
      ledger_sequence="$(json_number_get "$rf" ledgerSequence)"
      authority_primary="$(json_get "$rf" authorityPrimary)"
      source_device_id="$(json_get "$rf" sourceDeviceID)"
      target_device_id="$(json_get "$rf" targetDeviceID)"
      catalog_revision="$(json_get "$rf" catalogRevision)"
      request_digest_algorithm="$(json_get "$rf" digestAlgorithm)"
      request_source_digest="$(json_get "$rf" sourceDigest)"
      request_source_mode="$(json_get "$rf" sourceMode)"
      request_inventory_digest="$(json_get "$rf" inventoryDigest)"
      request_fallback_id="$(json_get "$rf" fallbackAuthorizationID)"
      request_fallback_path="$(json_get "$rf" fallbackAuthorizationPath)"
      request_fallback_digest="$(json_get "$rf" fallbackAuthorizationDigest)"
      requested_by="$(json_get "$rf" requestedBy)"
      source_device_name="$(json_get "$rf" sourceDeviceName)"
      sync_progress_reset

      [ -n "$id" ] || continue
      grep -qxF "$id" "$processed" 2>/dev/null && continue
      grep -qxF "$id" "$rejected" 2>/dev/null && continue
      case "$id" in
        *[!A-Za-z0-9._:-]*)
          record_rejected_request "$rejected" "$id" "request id 含不安全字元"
          continue
          ;;
      esac
      if [ "$rf" != "$CHANNEL_DIR/requests/$tgt.json" ] \
        && [ "$(basename "$rf" .json)" != "$id" ]
      then
        record_rejected_request "$rejected" "$id" "request id 與 queue filename 不符"
        continue
      fi
      case "$action" in system-pull|db-pull|version-pull) ;; *)
        record_rejected_request "$rejected" "$id" "未知 action"
        continue
      esac
      if [ "$request_target" != "$tgt" ]; then
        record_rejected_request "$rejected" "$id" "target 與 queue 路徑不符"
        continue
      fi
      if [ -z "$authority_epoch" ] || [ -z "$ledger_sequence" ] \
        || [ -z "$authority_primary" ] \
        || [ -z "$source_device_id" ] || [ -z "$catalog_revision" ]
      then
        record_rejected_request "$rejected" "$id" "缺少 authority/ledger/source/catalog binding"
        continue
      fi
      if [ "$requested_by" != "$authority_primary" ] \
        || [ "$source_device_name" != "$authority_primary" ]
      then
        record_rejected_request "$rejected" "$id" "requestedBy/sourceDeviceName 與 authority 不符"
        continue
      fi
      if [ "$(registered_device_id "$authority_primary")" != "$source_device_id" ]; then
        record_rejected_request "$rejected" "$id" "sourceDeviceID 與 registry 不符"
        continue
      fi
      local request_signature_path request_signature
      request_signature_path="$(json_get "$rf" signaturePath)"
      if [ "$(json_get "$rf" signaturePurpose)" != "sync-request" ] \
        || [ "$request_signature_path" != "signatures/requests/$tgt/$id.json" ]
      then
        record_rejected_request "$rejected" "$id" "request 缺少固定 Ed25519 signature binding"
        continue
      fi
      request_signature="$CHANNEL_DIR/$request_signature_path"
      if ! verify_channel_artifact_signature \
        "$authority_primary" "$source_device_id" "sync-request" \
        "$rf" "$request_signature"
      then
        record_rejected_request "$rejected" "$id" \
          "request signature 無效、來源未 pin、key 已撤銷或 generation 不符"
        continue
      fi
      if [ "$tgt" = "$device" ] && [ "$target_device_id" != "$local_device_id" ]; then
        record_rejected_request "$rejected" "$id" "targetDeviceID 與本機 identity 不符"
        continue
      fi
      if [ "$catalog_revision" != "$(sync_catalog_revision)" ]; then
        record_rejected_request "$rejected" "$id" "catalog revision 不符"
        continue
      fi
      if ! authority_matches "$authority_primary" "$authority_epoch"; then
        record_rejected_request "$rejected" "$id" "authority epoch 已過期"
        continue
      fi
      case "$action" in
        system-pull)
          if [ "$request_digest_algorithm" != "sha256" ] \
            || ! is_sha256_digest "$request_source_digest"
          then
            record_rejected_request "$rejected" "$id" "system request 缺少有效 manifest source digest"
            continue
          fi
          if ! validate_request_skillet_source_provenance \
            "$request_source_mode" "$request_inventory_digest" "$request_fallback_id" \
            "$request_fallback_path" "$request_fallback_digest"
          then
            record_rejected_request "$rejected" "$id" \
              "system request 缺少可驗證的 Skillet source provenance / fallback authority"
            continue
          fi
          ;;
        version-pull)
          if [ "$request_digest_algorithm" != "git-object-id" ] \
            || ! is_git_object_id "$request_source_digest"
          then
            record_rejected_request "$rejected" "$id" "version request 缺少有效 source digest"
            continue
          fi
          ;;
      esac
      if [ "$action" = "system-pull" ] \
        && ! require_system_runtime_enrollment
      then
        log "request id=${id} 保持 pending；未寫 ACK、processed 或 system transaction"
        runtime_enrollment_blocked=1
        acted=1
        continue
      fi
      local existing_ack="$CHANNEL_DIR/acks/$id.json"
      local resume_nonterminal_ack=""
      if [ -f "$existing_ack" ]; then
        local existing_ack_signature_path existing_ack_signature
        existing_ack_signature_path="$(json_get "$existing_ack" signaturePath)"
        if [ "$(json_get "$existing_ack" signaturePurpose)" != "sync-ack" ] \
          || [ "$existing_ack_signature_path" != "signatures/acks/$id.json" ]
        then
          record_rejected_request "$rejected" "$id" \
            "既有 ACK 缺少固定 Ed25519 signature binding"
          continue
        fi
        existing_ack_signature="$CHANNEL_DIR/$existing_ack_signature_path"
        if ! verify_channel_artifact_signature \
          "$device" "$local_device_id" "sync-ack" \
          "$existing_ack" "$existing_ack_signature"
        then
          record_rejected_request "$rejected" "$id" \
            "既有 ACK signature 無效、local key 已撤銷或 generation 不符"
          continue
        fi
        local existing_ack_phase existing_ack_digest_algorithm
        local existing_ack_source_digest existing_ack_applied_digest
        existing_ack_phase="$(json_get "$existing_ack" phase)"
        existing_ack_digest_algorithm="$(json_get "$existing_ack" digestAlgorithm)"
        existing_ack_source_digest="$(json_get "$existing_ack" sourceDigest)"
        existing_ack_applied_digest="$(json_get "$existing_ack" appliedDigest)"
        if [ "$(json_get "$existing_ack" requestID)" = "$id" ] \
          && [ "$(json_get "$existing_ack" target)" = "$device" ] \
          && [ "$(json_get "$existing_ack" action)" = "$action" ] \
          && [ "$(json_number_get "$existing_ack" authorityEpoch)" = "$authority_epoch" ] \
          && [ "$(json_number_get "$existing_ack" ledgerSequence)" = "$ledger_sequence" ] \
          && [ "$(json_get "$existing_ack" authorityPrimary)" = "$authority_primary" ] \
          && [ "$(json_get "$existing_ack" sourceDeviceID)" = "$source_device_id" ] \
          && [ "$(json_get "$existing_ack" targetDeviceID)" = "$local_device_id" ] \
          && [ "$(json_get "$existing_ack" catalogRevision)" = "$catalog_revision" ] \
          && [ "$(json_get "$existing_ack" sourceMode)" = "$request_source_mode" ] \
          && [ "$(json_get "$existing_ack" inventoryDigest)" = \
            "$request_inventory_digest" ] \
          && [ "$(json_get "$existing_ack" fallbackAuthorizationID)" = \
            "$request_fallback_id" ] \
          && [ "$(json_get "$existing_ack" fallbackAuthorizationPath)" = \
            "$request_fallback_path" ] \
          && [ "$(json_get "$existing_ack" fallbackAuthorizationDigest)" = \
            "$request_fallback_digest" ]
        then
          local existing_ack_locally_attested=0
          case "$existing_ack_phase" in
            converged)
              if [ "$existing_ack_digest_algorithm" != "$request_digest_algorithm" ] \
                || [ "$existing_ack_source_digest" != "$request_source_digest" ] \
                || [ "$existing_ack_applied_digest" != "$request_source_digest" ]
              then
                record_rejected_request "$rejected" "$id" "既有 converged ACK digest 與 request 不符"
                continue
              fi
              if [ "$action" = "system-pull" ]; then
                local existing_transaction_journal existing_transaction_phase
                existing_transaction_journal="$(system_transaction_directory "$id")/journal.json"
                existing_transaction_phase=""
                if [ -f "$existing_transaction_journal" ]; then
                  existing_transaction_phase="$(json_get "$existing_transaction_journal" phase)"
                fi
                if [ "$existing_transaction_phase" != "committed" ]; then
                  record_rejected_request "$rejected" "$id" \
                    "既有 system ACK 缺少本機 committed transaction local attestation"
                  continue
                fi
                SYSTEM_SOURCE_DIGEST=""
                SYSTEM_APPLIED_DIGEST=""
                SYSTEM_REQUIRED_ITEM_IDS_JSON="[]"
                SYSTEM_ACK_ITEMS_JSON="[]"
                if ! apply_system_manifest \
                  "$rf" "$id" "$authority_primary" "$authority_epoch" \
                  "$source_device_id" "$local_device_id" "$catalog_revision" "$ledger_sequence" \
                  1
                then
                  record_rejected_request "$rejected" "$id" \
                    "既有 system ACK 無法由本機 committed transaction 與 active readback 重新證明"
                  continue
                fi
                if ! activate_skills_consumer_projection \
                  "$SKILLET_SET_MANIFEST" "$id"
                then
                  record_rejected_request "$rejected" "$id" \
                    "既有 system ACK 無法重新證明 Codex／Claude 原生 Skills managed projection"
                  continue
                fi
                if ! verify_existing_system_converged_ack_artifacts \
                  "$existing_ack" "$id" "$device" "$authority_epoch" \
                  "$ledger_sequence" "$authority_primary" "$source_device_id" \
                  "$local_device_id" "$catalog_revision" "$request_source_digest"
                then
                  record_rejected_request "$rejected" "$id" \
                    "既有 system ACK 缺少可驗證的 V2 consumer readback / target attestation binding"
                  continue
                fi
                existing_ack_locally_attested=1
              fi
              ;;
            accepted|transferring|merging|validating|activating|verified)
              if [ "$existing_ack_digest_algorithm" != "$request_digest_algorithm" ] \
                || [ "$existing_ack_source_digest" != "$request_source_digest" ] \
                || { [ -n "$existing_ack_applied_digest" ] \
                  && [ "$existing_ack_applied_digest" != "$request_source_digest" ]; } \
                || ! validate_sync_progress_payload \
                "$existing_ack" progress "$existing_ack_phase"
              then
                record_rejected_request "$rejected" "$id" \
                  "既有 non-terminal ACK digest/progress schema/範圍不合法"
                continue
              fi
              resume_nonterminal_ack="$existing_ack"
              log "request id=${id} 已有綁定 non-terminal ACK phase=${existing_ack_phase}；保留進度並繼續同一 request，不寫 processed"
              ;;
            failed|diverged) ;;
            *)
              record_rejected_request "$rejected" "$id" "既有 ACK phase 不可作為終端 processed receipt"
              continue
              ;;
          esac
          if [ -z "$resume_nonterminal_ack" ]; then
            if accept_request_ledger_position \
              "$source_device_id" "$authority_epoch" "$ledger_sequence" "$id" \
              || request_ledger_position_is_historical \
                "$source_device_id" "$authority_epoch" "$ledger_sequence"
            then
              printf '%s\n' "$id" >>"$processed"
              acted=1
              if [ "$existing_ack_locally_attested" = "1" ]; then
                log "request id=${id} 已有綁定 ACK；本機 committed transaction 與 active set 重新驗證後補寫 processed"
              else
                log "request id=${id} 已有綁定終端 ACK；僅補寫本機 processed receipt，不重複套用"
              fi
              continue
            fi
            record_rejected_request "$rejected" "$id" "既有 ACK 的 ledger position 衝突"
            continue
          fi
        fi
        if [ -z "$resume_nonterminal_ack" ]; then
          record_rejected_request "$rejected" "$id" "既有 ACK 與 request binding 衝突"
          continue
        fi
      fi

      if [ "$retention_allows_new_apply" != "1" ]; then
        local retention_transaction_phase=""
        if [ "$action" = "system-pull" ]; then
          local retention_transaction_journal
          retention_transaction_journal="$(system_transaction_directory "$id")/journal.json"
          if [ -f "$retention_transaction_journal" ]; then
            retention_transaction_phase="$(json_get "$retention_transaction_journal" phase)"
          fi
        fi
        if [ "$action" = "system-pull" ] \
          && [ "$retention_transaction_phase" = "committed" ]
        then
          log "retention budget 已滿，但 request id=${id} 是 committed-awaiting-ACK；允許 bounded revalidation，不重複 activation"
        else
          log "retention budget 已滿；request id=${id} 保持 pending，未開始新 activation"
          continue
        fi
      fi

      if ! accept_request_ledger_position \
        "$source_device_id" "$authority_epoch" "$ledger_sequence" "$id"
      then
        record_rejected_request "$rejected" "$id" "同 epoch request ledger 倒退或衝突"
        continue
      fi

      if [ "$action" = "system-pull" ]; then
        if sync_progress_initialize_system \
          "$rf" "$id" "$device" "$requested_at" \
          "$authority_epoch" "$ledger_sequence" "$authority_primary" \
          "$source_device_id" "$local_device_id" "$catalog_revision" \
          "$request_source_digest" "$resume_nonterminal_ack"
        then
          write_sync_progress_ack \
            "accepted" 0 0 0 \
            "request $id" \
            "目標設備已接收 authority-bound request，準備讀取 private channel payload"
          write_sync_progress_ack \
            "transferring" 1 0 0 \
            "private channel payload" \
            "request-bound payload 已傳送到目標 channel checkout，進入逐項驗證"
        else
          if [ -n "$resume_nonterminal_ack" ]; then
            record_rejected_request "$rejected" "$id" \
              "既有 non-terminal ACK progress totals 與 immutable request payload 不符"
            continue
          fi
          log "request id=${id} 無法建立 measured progress totals；保留 fail-closed apply 驗證"
        fi
      fi

      log "收到同步指令 target=$tgt action=$action id=$id epoch=$authority_epoch seq=$ledger_sequence → stage/validate"
      local source_digest="" applied_digest="" ack_phase="failed" ack_result="error"
      local ack_message="" digest_algorithm="" required_ids_json="[]" items_json="[]"
      local attestation_kind="" attestation_path="" attestation_digest=""
      local consumer_readback_kind="" consumer_readback_path=""
      local consumer_readback_digest="" consumer_readback_count=0
      local defer_terminal_receipt=0
      case "$action" in
        system-pull)
          SYSTEM_SOURCE_DIGEST=""
          SYSTEM_APPLIED_DIGEST=""
          SYSTEM_REQUIRED_ITEM_IDS_JSON="[]"
          SYSTEM_ACK_ITEMS_JSON="[]"
          digest_algorithm="sha256"
          required_ids_json="$SYSTEM_REQUIRED_ITEM_IDS_JSON"
          if apply_system_manifest \
            "$rf" "$id" "$authority_primary" "$authority_epoch" \
            "$source_device_id" "$local_device_id" "$catalog_revision" "$ledger_sequence"
          then
            if [ "${TATWO_TEST_MODE:-0}" = "1" ] \
              && [ "${TATWO_TEST_CRASH_AFTER_SYSTEM_COMMIT:-0}" = "1" ]
            then
              kill -9 "$$"
            fi
            source_digest="$SYSTEM_SOURCE_DIGEST"
            applied_digest="$SYSTEM_APPLIED_DIGEST"
            required_ids_json="$SYSTEM_REQUIRED_ITEM_IDS_JSON"
            items_json="$SYSTEM_ACK_ITEMS_JSON"
            ack_phase="converged"
            ack_result="converged"
            ack_message="Work OS 文件、Skillet repositories 與 Codex／Claude 原生 Skills projection 已完成逐項 digest 驗證、authority fencing、整組 activation、五消費者 readback 與設備 ACK"
            TARGET_CONSUMER_READBACK_KIND=""
            TARGET_CONSUMER_READBACK_PATH=""
            TARGET_CONSUMER_READBACK_DIGEST=""
            TARGET_CONSUMER_READBACK_COUNT=0
            if ! activate_skills_consumer_projection \
              "$SKILLET_SET_MANIFEST" "$id"
            then
              defer_terminal_receipt=1
              ack_message="system-pull 已 committed，但 Codex／Claude 原生 Skills projection 尚未完成；保留 request 等待重試"
              applied_digest=""
            fi
            if [ "$defer_terminal_receipt" != "1" ]; then
              write_system_consumer_readback \
                "$id" "$device" "$authority_epoch" "$ledger_sequence" \
                "$authority_primary" "$source_device_id" "$local_device_id" \
                "$catalog_revision" "$source_digest" \
                || {
                defer_terminal_receipt=1
                ack_message="system-pull 已 committed，但五消費者 actual readback 尚未完成；保留 request 等待重試"
                applied_digest=""
              }
            fi
            consumer_readback_kind="$TARGET_CONSUMER_READBACK_KIND"
            consumer_readback_path="$TARGET_CONSUMER_READBACK_PATH"
            consumer_readback_digest="$TARGET_CONSUMER_READBACK_DIGEST"
            consumer_readback_count="$TARGET_CONSUMER_READBACK_COUNT"
            if [ "$defer_terminal_receipt" != "1" ] \
              && [ "$SYNC_PROGRESS_ENABLED" = "1" ]
            then
              write_sync_progress_ack \
                "verified" 3 "$SYNC_PROGRESS_TOTAL_ITEMS" \
                "$SYNC_PROGRESS_TOTAL_REPOSITORIES" \
                "five-consumer actual readback" \
                "Work OS bootstrap、Tatwo shared runtime、Skillet runtime loader、Codex 與 Claude native skills 已回報 exact loaded digest/revision" \
                || defer_terminal_receipt=1
            fi
            TARGET_ATTESTATION_KIND=""
            TARGET_ATTESTATION_PATH=""
            TARGET_ATTESTATION_DIGEST=""
            if [ "$defer_terminal_receipt" != "1" ]; then
              write_system_target_attestation \
                "$id" "$device" "$authority_epoch" "$ledger_sequence" \
                "$authority_primary" "$source_device_id" "$local_device_id" \
                "$catalog_revision" "$source_digest" \
                || {
                # The target already committed the activation. A transient local
                # receipt/disk failure is not a terminal sync failure and must not
                # be written to processed-ids, otherwise the same committed
                # transaction can never reconstruct its missing ACK.
                defer_terminal_receipt=1
                ack_message="system-pull 已 committed，但 consumer-bound target attestation 尚未建立；保留 request 等待重試"
                applied_digest=""
              }
            fi
            attestation_kind="$TARGET_ATTESTATION_KIND"
            attestation_path="$TARGET_ATTESTATION_PATH"
            attestation_digest="$TARGET_ATTESTATION_DIGEST"
          else
            apply_status=$?
            if [ "$apply_status" = "42" ]; then
              record_rejected_request "$rejected" "$id" "activation 前 authority 已切換"
              source_digest="$request_source_digest"
              applied_digest=""
              ack_phase="diverged"
              ack_result="diverged"
              ack_message="authority 在 activation gate 前切換；已回復或保留前一 active set，禁止宣稱收斂"
              if [ "$SYNC_PROGRESS_ENABLED" = "1" ]; then
                required_ids_json="$(sync_progress_required_ids_json)"
                items_json="$(sync_progress_system_items_json \
                  "diverged" 2 1 "$SYNC_PROGRESS_COMPLETED_REPOSITORIES" \
                  "$ack_message")"
              fi
            else
              source_digest="$SYSTEM_SOURCE_DIGEST"
              applied_digest="$SYSTEM_APPLIED_DIGEST"
              required_ids_json="$SYSTEM_REQUIRED_ITEM_IDS_JSON"
              items_json="$SYSTEM_ACK_ITEMS_JSON"
              if [ "$apply_status" = "43" ]; then
                ack_phase="diverged"
                ack_result="diverged"
                ack_message="system-pull 已套用並驗證，但最終 authority fence 已切換；禁止宣稱收斂，需由新 epoch 重發"
              elif [ "$apply_status" = "44" ]; then
                ack_phase="merging"
                ack_result="partial"
                ack_message="Skillet incoming revisions、merge proposals 與 conflicts 已保存；前一版 OS mirror 已回復，active runtime 未變更，等待人工 approve/reject"
              else
                ack_message="system-pull manifest 驗證或 activation 失敗"
              fi
            fi
          fi
          ;;
        db-pull)
          required_ids_json='["work.goal-state"]'
          if cmd_db_pull --from "$from"; then
            ack_phase="validating"
            ack_result="partial"
            ack_message="legacy goal-state 傳輸完成，但尚無逐項來源 digest；不可宣稱 converged"
          else
            ack_message="db-pull 失敗"
          fi
          ;;
        data-sync)
          data_script="${TATWO_DATA_SYNC_SCRIPT:-$HERE/tatwo-data-sync.sh}"
          required_ids_json='["host.data"]'
          if bash "$data_script" submit; then
            ack_phase="converged"
            ack_result="converged"
            ack_message="secondary data submitted; host unify"
          else
            ack_message="data-sync submit 失敗"
          fi
          ;;
        version-pull)
          if [ "${TATWO_OS_IMAGE_CONSUMER:-0}" = "1" ]; then
            required_ids_json='["os.image"]'
            if cmd_version_pull; then
              ack_phase="converged"
              ack_result="converged"
              ack_message="os-image applied from host"
            else
              ack_message="os-image apply 失敗"
            fi
          else
            digest_algorithm="git-object-id"
            required_ids_json='["app.version"]'
            source_digest="$request_source_digest"
            if cmd_version_pull --no-install --expected-digest "$request_source_digest"; then
              applied_digest="$(version_applied_digest)"
              if authority_matches "$authority_primary" "$authority_epoch" \
                && is_git_object_id "$source_digest" \
                && [ "$source_digest" = "$applied_digest" ]
              then
                ack_phase="converged"
                ack_result="converged"
                ack_message="source version 已 fast-forward 並以 commit digest 驗證；未自動安裝 signed App"
              else
                ack_phase="diverged"
                ack_result="diverged"
                ack_message="版本套用後 authority 或 digest 不一致"
              fi
            else
              ack_message="version-pull 失敗"
            fi
            items_json="[{
              \"id\":\"app.version\",
              \"displayName\":\"Tatwo source version\",
              \"phase\":\"$([ "$ack_phase" = "converged" ] && echo verified || echo "$ack_phase")\",
              \"digestAlgorithm\":\"git-object-id\",
              \"sourceDigest\":\"$source_digest\",
              \"appliedDigest\":\"$applied_digest\",
              \"message\":\"$ack_message\"
            }]"
          fi
          ;;
      esac
      if [ "$defer_terminal_receipt" = "1" ]; then
        acted=1
        log "request id=${id} 已 committed-awaiting-ACK；未寫 terminal ACK、未寫 processed，阻擋同來源後續 sequence，下一輪先重新驗證"
        break
      fi
      local receipt_progress_json=""
      if [ "$SYNC_PROGRESS_ENABLED" = "1" ]; then
        if [ "$ack_phase" = "converged" ]; then
          SYNC_PROGRESS_COMPLETED_BYTES="$SYNC_PROGRESS_TOTAL_BYTES"
          SYNC_PROGRESS_COMPLETED_ITEMS="$SYNC_PROGRESS_TOTAL_ITEMS"
          SYNC_PROGRESS_COMPLETED_REPOSITORIES="$SYNC_PROGRESS_TOTAL_REPOSITORIES"
          receipt_progress_json="$(sync_progress_payload_json \
            "$SYNC_PROGRESS_TOTAL_BYTES" "$SYNC_PROGRESS_TOTAL_ITEMS" \
            "$SYNC_PROGRESS_TOTAL_REPOSITORIES" \
            "five-consumer readback、native projection 與 target attestation")"
        else
          receipt_progress_json="$(sync_progress_payload_json \
            "$SYNC_PROGRESS_COMPLETED_BYTES" "$SYNC_PROGRESS_COMPLETED_ITEMS" \
            "$SYNC_PROGRESS_COMPLETED_REPOSITORIES" \
            "同步在 phase=$ack_phase 停止")"
        fi
      fi
      write_sync_ack \
        "$id" "$device" "$action" "$requested_at" "$ack_phase" "$ack_result" \
        "$source_digest" "$applied_digest" "$ack_message" "$authority_epoch" \
        "$ledger_sequence" "$authority_primary" "$source_device_id" "$local_device_id" \
        "$catalog_revision" "$digest_algorithm" "$required_ids_json" "$items_json" \
        "$attestation_kind" "$attestation_path" "$attestation_digest" \
        "$receipt_progress_json" \
        "$consumer_readback_kind" "$consumer_readback_path" \
        "$consumer_readback_digest" "$consumer_readback_count" \
        "$request_source_mode" "$request_inventory_digest" \
        "$request_fallback_id" "$request_fallback_path" "$request_fallback_digest"
      if sync_ack_phase_is_terminal "$ack_phase"; then
        printf '%s\n' "$id" >>"$processed"
      else
        log "request id=${id} phase=${ack_phase} 仍為 non-terminal；未寫 processed，保留下一輪續跑"
      fi
      acted=1
    done <<<"$request_files"
  done
  [ "$acted" = "0" ] && log "無新同步指令（device=${device}）"
  [ "$runtime_enrollment_blocked" = "0" ] || return 1
  return 0
}

cmd_sync_ack_status() {
  local id=""
  while [ $# -gt 0 ]; do case "$1" in
    --id) id="${2:-}"; shift 2;;
    *) die "未知參數 $1";; esac; done
  [ -n "$id" ] || die "sync-ack-status 需要 --id REQUEST_ID"
  case "$id" in *[!A-Za-z0-9._:-]*) die "request id 含有不安全字元";; esac
  channel_ensure
  local ack="$CHANNEL_DIR/acks/$id.json"
  [ -f "$ack" ] || die "尚未收到 request id=$id 的設備 ACK"
  log "id=$id target=$(json_get "$ack" target) action=$(json_get "$ack" action) phase=$(json_get "$ack" phase) result=$(json_get "$ack" result)"
  cat "$ack"
}

device_identity_file() { echo "$APP_SUPPORT/device-identity.json"; }

ensure_device_identity() {  # 產生/讀取本機持久設備身分（UUID，不碰硬體序號）
  local f; f="$(device_identity_file)"
  if [ ! -f "$f" ]; then
    mkdir -p "$APP_SUPPORT"
    local id; id="$(uuidgen 2>/dev/null || echo "dev-$(date -u +%s)-$RANDOM")"
    cat > "$f" <<EOF
{ "deviceId": "$id", "name": "$DEVICE_NAME", "createdAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)" }
EOF
  fi
}

adopt_published_local_rotation_if_needed() {
  local registry="$1" identity="$2"
  local old_generation new_generation receipt identity_stage
  validate_device_trust_identity_file "$identity" \
    "$(json_get "$(device_identity_file)" deviceId)" \
    || return 1
  validate_registered_device_trust "$DEVICE_NAME" \
    "$(json_get "$(device_identity_file)" deviceId)" \
    || return 1
  device_trust_identity_files_match "$identity" "$registry" && return 0
  old_generation="$(json_number_get "$identity" keyGeneration)"
  new_generation="$(json_number_get "$registry" keyGeneration)"
  case "$old_generation:$new_generation" in
    *[!0-9:]*|:*|*:) return 1;;
  esac
  [ "$new_generation" -eq $((old_generation + 1)) ] || return 1
  receipt="$(device_trust_rotation_receipt_file \
    "$DEVICE_NAME" "$new_generation")" || return 1
  device_trust_rotation_matches_registry "$receipt" "$identity" "$registry" \
    || return 1
  run_device_trust_cli verify-rotation \
    --old-registry "$identity" \
    --receipt "$receipt" >/dev/null \
    || return 1
  run_device_trust_cli assert-local --registry "$registry" >/dev/null \
    || return 1
  identity_stage="$(dirname "$identity")/.identity.rotation-adopt.$$.tmp"
  plutil -extract newIdentity json -o "$identity_stage" "$receipt" \
    || return 1
  chmod 600 "$identity_stage" 2>/dev/null || true
  validate_device_trust_identity_file \
    "$identity_stage" "$(json_get "$registry" deviceID)" \
    && device_trust_identity_files_match "$identity_stage" "$registry" \
    || return 1
  mv "$identity_stage" "$identity"
}

cmd_trust_rotate() {
  local rotated_at=""
  while [ $# -gt 0 ]; do case "$1" in
    --rotated-at) rotated_at="${2:-}"; shift 2;;
    *) die "未知參數 $1";; esac; done
  [ -n "$rotated_at" ] \
    || rotated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  channel_ensure
  ensure_device_identity
  ensure_device_trust_identity
  local device_id registry identity
  local old_generation new_generation staging_root new_identity rotation_receipt
  local receipt_final receipt_stage registry_stage
  device_id="$(json_get "$(device_identity_file)" deviceId)"
  registry="$(registered_device_file "$DEVICE_NAME")"
  identity="$(device_trust_identity_file)"
  validate_registered_device_trust "$DEVICE_NAME" "$device_id" \
    || die "本機尚未發布有效 device trust registry；請先 register"
  if ! device_trust_identity_files_match "$identity" "$registry"; then
    adopt_published_local_rotation_if_needed "$registry" "$identity" \
      || die "本機 identity 與 registry 不一致，且沒有可驗證的連續 rotation receipt"
    log "已恢復並採用先前發布的本機 key rotation"
    return 0
  fi

  old_generation="$(json_number_get "$identity" keyGeneration)"
  staging_root="$APP_SUPPORT/device-trust/rotation-staging/$DEVICE_NAME-$$-$RANDOM"
  new_identity="$staging_root/identity.json"
  rotation_receipt="$staging_root/rotation.json"
  mkdir -p "$staging_root"
  run_device_trust_cli rotate \
    --registry "$identity" \
    --rotated-at "$rotated_at" \
    --identity-out "$new_identity" \
    --receipt-out "$rotation_receipt" >/dev/null \
    || die "無法產生 Ed25519 key rotation"
  chmod 600 "$new_identity" "$rotation_receipt" 2>/dev/null || true
  run_device_trust_cli verify-rotation \
    --old-registry "$identity" \
    --receipt "$rotation_receipt" >/dev/null \
    || die "新 key rotation receipt 無法由舊 pinned key 驗證"
  run_device_trust_cli assert-local --registry "$new_identity" >/dev/null \
    || die "新 key 的本機 private key 無法回讀"
  new_generation="$(json_number_get "$new_identity" keyGeneration)"
  [ "$new_generation" -eq $((old_generation + 1)) ] \
    || die "key rotation generation 不連續"

  receipt_final="$(device_trust_rotation_receipt_file \
    "$DEVICE_NAME" "$new_generation")" \
    || die "rotation receipt 路徑不合法"
  [ ! -e "$receipt_final" ] \
    || die "rotation generation $new_generation 已存在 receipt；拒絕 replay/覆寫"
  mkdir -p "$(dirname "$receipt_final")"
  receipt_stage="$(dirname "$receipt_final")/.$new_generation.$$.tmp"
  registry_stage="$(dirname "$registry")/.$DEVICE_NAME.rotation.$$.tmp"
  cp "$rotation_receipt" "$receipt_stage" \
    || die "無法 stage rotation receipt"
  cp "$registry" "$registry_stage" \
    || die "無法 stage rotated device registry"
  local key
  for key in schema algorithm deviceID keyID publicKey keyStatus pinnedAt; do
    plutil -replace "$key" -string "$(json_get "$new_identity" "$key")" \
      "$registry_stage" \
      || die "無法更新 rotated registry 欄位：$key"
  done
  plutil -replace keyGeneration -integer "$new_generation" "$registry_stage" \
    || die "無法更新 rotated registry generation"
  device_trust_rotation_matches_registry \
    "$receipt_stage" "$identity" "$registry_stage" \
    || die "rotation receipt 與 rotated registry 不一致"
  validate_device_trust_identity_file "$registry_stage" "$device_id" \
    || die "rotated registry 驗證失敗"

  mv "$receipt_stage" "$receipt_final"
  mv "$registry_stage" "$registry"
  git -C "$CHANNEL_DIR" add \
    "${receipt_final#"$CHANNEL_DIR"/}" "devices/$DEVICE_NAME.json"
  git -C "$CHANNEL_DIR" commit \
    -m "rotate device trust key $DEVICE_NAME generation $new_generation" \
    >/dev/null 2>&1 \
    || die "無法提交 device trust rotation"
  mv "$new_identity" "$identity"
  chmod 600 "$identity" 2>/dev/null || true
  channel_push
  log "已輪替 device trust key：device=$DEVICE_NAME generation=$new_generation"
  printf 'DEVICE_TRUST_KEY_GENERATION=%s\n' "$new_generation"
  printf 'DEVICE_TRUST_ROTATION_RECEIPT=%s\n' \
    "${receipt_final#"$CHANNEL_DIR"/}"
}

cmd_register() {  # 把本機設備登記到通道 devices/<name>.json，讓主設備能列出
  local role="secondary" name="$DEVICE_NAME" host="$PRIMARY_SSH_HOST" pairing_seed=""
  while [ $# -gt 0 ]; do case "$1" in
    --role) role="$2"; shift 2;;
    --name) name="$2"; shift 2;;
    --host) host="$2"; shift 2;;
    --pairing-seed) pairing_seed="$2"; shift 2;;
    *) die "未知參數 $1";; esac; done

  validate_device_role "$role"
  validate_device_name "$name"
  [ -n "$host" ] || { echo "請設定 TATWO_PRIMARY_SSH_HOST" >&2; exit 2; }
  validate_ssh_host "$host"
  channel_ensure
  read_primary_state
  ensure_device_identity
  ensure_device_trust_identity
  local id existing_file existing_id existing_name_for_id effective_role
  local trust_identity trust_schema trust_algorithm trust_device_id trust_key_id
  local trust_public_key trust_generation trust_status trust_pinned_at
  id="$(json_get "$(device_identity_file)" deviceId)"
  validate_device_name "$id"
  trust_identity="$(device_trust_identity_file)"
  trust_schema="$(json_get "$trust_identity" schema)"
  trust_algorithm="$(json_get "$trust_identity" algorithm)"
  trust_device_id="$(json_get "$trust_identity" deviceID)"
  trust_key_id="$(json_get "$trust_identity" keyID)"
  trust_public_key="$(json_get "$trust_identity" publicKey)"
  trust_generation="$(json_number_get "$trust_identity" keyGeneration)"
  trust_status="$(json_get "$trust_identity" keyStatus)"
  trust_pinned_at="$(json_get "$trust_identity" pinnedAt)"
  existing_file="$CHANNEL_DIR/devices/$name.json"
  existing_id=""
  if [ -f "$existing_file" ]; then
    existing_id="$(json_get "$existing_file" deviceId)"
    [ "$existing_id" = "$id" ] \
      || die "設備別名已由另一個 device identity 使用：$name"
    if [ -n "$(json_get "$existing_file" schema)" ]; then
      device_trust_identity_files_match "$existing_file" "$trust_identity" \
        || die "既有設備 registry 的 Ed25519 identity 不同；禁止 register 靜默換 key，需走 rotation"
    fi
  fi
  existing_name_for_id="$(registered_device_name_for_id "$id")"
  if [ -n "$existing_name_for_id" ] && [ "$existing_name_for_id" != "$name" ]; then
    die "此 device identity 已登記為 ${existing_name_for_id}；不得建立第二個設備別名"
  fi

  if [ "$role" = "primary" ]; then
    if [ -n "$PRIMARY_NAME" ]; then
      require_current_primary
      [ "$name" = "$PRIMARY_NAME" ] \
        || die "register --role primary 只能由現任主設備更新自己的登記"
    else
      [ "$name" = "$DEVICE_NAME" ] \
        || die "尚無主設備時，register --role primary 只允許本機為自己建立初始主權"
    fi
  fi

  local pairing_file=""
  if [ "$role" = "secondary" ] && [ -n "$PRIMARY_NAME" ] && [ -z "$existing_id" ]; then
    # 已有主設備 → 新副設備必須帶有效配對代碼，防止舊指令長期外流被重複使用。
    case "$pairing_seed" in
      ????????)
        case "$pairing_seed" in *[!A-Z0-9]*) die "配對代碼格式不合法";; esac
        ;;
      *)
        die "此設備需要配對代碼（在主設備的設備分頁點擊「新增設備」產生，限時 ${PAIRING_TTL_SECONDS} 秒、單次有效）"
        ;;
    esac
    pairing_file="$(pairing_dir)/$pairing_seed.json"
    [ -f "$pairing_file" ] || die "配對代碼無效或不存在，請在主設備重新產生"
    local consumed_at expires_at expires_epoch now_epoch pairing_primary pairing_epoch created_by
    consumed_at="$(json_get "$pairing_file" consumedAt)"
    [ -z "$consumed_at" ] || die "配對代碼已使用過，請在主設備重新產生"
    expires_at="$(json_get "$pairing_file" expiresAt)"
    expires_epoch="$(iso_to_epoch "$expires_at")"
    now_epoch="$(date -u +%s)"
    [ -n "$expires_epoch" ] || die "配對代碼格式錯誤，請在主設備重新產生"
    [ "$expires_epoch" -ge "$now_epoch" ] || die "配對代碼已過期（限時 ${PAIRING_TTL_SECONDS} 秒），請在主設備重新產生"
    created_by="$(json_get "$pairing_file" createdBy)"
    pairing_primary="$(json_get "$pairing_file" authorityPrimary)"
    pairing_epoch="$(json_number_get "$pairing_file" authorityEpoch)"
    [ "$created_by" = "$PRIMARY_NAME" ] \
      && [ "$pairing_primary" = "$PRIMARY_NAME" ] \
      && [ "$pairing_epoch" = "$PRIMARY_EPOCH" ] \
      || die "配對代碼不屬於現任主設備或目前 authority epoch，請重新產生"
  fi

  if [ "$role" = "secondary" ] && [ -n "$PRIMARY_NAME" ]; then
    local primary_device_id
    primary_device_id="$(registered_device_id "$PRIMARY_NAME")"
    [ -n "$primary_device_id" ] \
      && pin_registered_device_trust "$PRIMARY_NAME" "$primary_device_id" \
      || die "現任主設備尚未發布可 pin 的 Ed25519 identity；請先在主設備重新 register"
  fi

  effective_role="secondary"
  if [ "$role" = "primary" ]; then
    effective_role="primary"
  elif [ -n "$PRIMARY_NAME" ] && [ "$name" = "$PRIMARY_NAME" ]; then
    effective_role="primary"
  fi
  mkdir -p "$CHANNEL_DIR/devices"
  cat > "$CHANNEL_DIR/devices/$name.json" <<EOF
{
  "name": "$(json_escape "$name")",
  "role": "$effective_role",
  "deviceId": "$(json_escape "$id")",
  "sshHost": "$(json_escape "$host")",
  "schema": "$(json_escape "$trust_schema")",
  "algorithm": "$(json_escape "$trust_algorithm")",
  "deviceID": "$(json_escape "$trust_device_id")",
  "keyID": "$(json_escape "$trust_key_id")",
  "publicKey": "$(json_escape "$trust_public_key")",
  "keyGeneration": $trust_generation,
  "keyStatus": "$(json_escape "$trust_status")",
  "pinnedAt": "$(json_escape "$trust_pinned_at")",
  "enrolledAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  git -C "$CHANNEL_DIR" add "devices/$name.json"

  if [ "$role" = "primary" ] && [ -z "$PRIMARY_NAME" ]; then
    local changed_at
    changed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat > "$(primary_file)" <<EOF
{
  "name": "$(json_escape "$name")",
  "epoch": 1,
  "changedAt": "$changed_at"
}
EOF
    git -C "$CHANNEL_DIR" add primary.json
  fi

  if [ -n "$pairing_file" ]; then
    # 單次有效：登記成功後立刻標記已消費，同一 commit 一併推送。
    local consumed_now; consumed_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    plutil -replace consumedAt -string "$consumed_now" "$pairing_file" \
      || die "無法標記配對代碼已消費"
    git -C "$CHANNEL_DIR" add "$pairing_file"
  fi

  git -C "$CHANNEL_DIR" commit -m "register device $name ($effective_role)" >/dev/null 2>&1 \
    || { log "設備登記沒有變更：name=$name"; return 0; }
  channel_push
  log "已登記設備：name=$name role=$effective_role id=$id"
}

# ---- 必要文件同步（agents.md/CLAUDE.md 等，獨立於程式碼發布節奏）----
# 設計：跟 db-pull 一樣先備份、跟 version-pull 一樣「分岔就拒絕、不盲目自動合併」——
# 這些是 AI 行為規則檔案，絕不靜默覆寫；push 只送內容到通道，pull 只寫 .incoming，
# 使用者必須另外執行 profile-apply 才會真的覆寫本機生效檔案。
profile_local_path() {  # profile_local_path <name> → 對應的本機真實路徑（os-mirror-* 除外）
  case "$1" in
    claude-global)  echo "$HOME/.claude/CLAUDE.md";;
    claude-project) echo "$HOME/CLAUDE.md";;
    codex-global)   echo "$HOME/.codex/AGENTS.md";;
    codex-project)  echo "$HOME/AGENTS.md";;
    *) die "未知 profile 名稱：$1";;
  esac
}

profile_is_primary_only() {  # os-mirror-* 僅現任主設備可推送（canonical 只在主設備讀得到）
  case "$1" in os-mirror-os|os-mirror-issue) return 0;; *) return 1;; esac
}

cmd_profile_push() {  # 把本機內容推到通道（home 檔案）或匯出快照（os-mirror-*，僅主設備）
  local name="" source_file=""
  while [ $# -gt 0 ]; do case "$1" in
    --name) name="$2"; shift 2;;
    --source-file) source_file="$2"; shift 2;;
    *) die "未知參數 $1";; esac; done
  [ -n "$name" ] || die "profile-push 需要 --name NAME"
  case "$name" in
    claude-global|claude-project|codex-global|codex-project|os-mirror-os|os-mirror-issue) ;;
    *) die "未知 profile 名稱：$name";;
  esac
  if profile_is_primary_only "$name"; then
    require_current_primary
  fi
  if [ -z "$source_file" ]; then
    source_file="$(profile_local_path "$name" 2>/dev/null || true)"
  fi
  [ -n "$source_file" ] || die "os-mirror-* 需要 --source-file 指定來源路徑"
  [ -f "$source_file" ] || die "找不到來源檔案：$source_file"

  channel_ensure
  mkdir -p "$CHANNEL_DIR/profiles/$DEVICE_NAME"
  local dest="$CHANNEL_DIR/profiles/$DEVICE_NAME/$name.md"
  cp "$source_file" "$dest"
  git -C "$CHANNEL_DIR" add "profiles/$DEVICE_NAME/$name.md"
  git -C "$CHANNEL_DIR" commit -m "profile-push ${name} from ${DEVICE_NAME}" >/dev/null 2>&1 \
    || { log "無變更可推送：$name"; return; }
  channel_push
  log "已推送 profile：name=${name} device=${DEVICE_NAME}"
}

cmd_profile_pull() {  # 抓 shared + 本機 overlay，寫入 .incoming（絕不自動覆寫生效檔）
  local name=""
  while [ $# -gt 0 ]; do case "$1" in
    --name) name="$2"; shift 2;;
    *) die "未知參數 $1";; esac; done
  [ -n "$name" ] || die "profile-pull 需要 --name NAME"

  channel_ensure
  local shared_file="$CHANNEL_DIR/profiles/shared/$name.md"
  local overlay_file="$CHANNEL_DIR/profiles/$DEVICE_NAME/$name.md"
  local combined=""
  if [ -f "$shared_file" ]; then combined="$(cat "$shared_file")"; fi
  if [ -f "$overlay_file" ]; then
    if [ -n "$combined" ]; then
      combined="$combined
$(cat "$overlay_file")"
    else
      combined="$(cat "$overlay_file")"
    fi
  fi
  if [ -z "$combined" ]; then
    die "通道上沒有 profiles/shared/${name}.md 或 profiles/${DEVICE_NAME}/${name}.md，無內容可拉"
  fi

  if profile_is_primary_only "$name"; then
    # os-mirror-*：唯讀鏡像快取，沒有本機生效檔案要覆寫，不需要 profile-apply。
    mkdir -p "$APP_SUPPORT/profile-mirrors"
    printf '%s\n' "$combined" > "$APP_SUPPORT/profile-mirrors/${name#os-mirror-}.md"
    log "已更新唯讀鏡像：$APP_SUPPORT/profile-mirrors/${name#os-mirror-}.md"
    return
  fi

  local local_path; local_path="$(profile_local_path "$name")"
  mkdir -p "$(dirname "$local_path")"
  printf '%s\n' "$combined" > "${local_path}.incoming"
  log "已寫入待套用檔：${local_path}.incoming（執行 profile-apply --name ${name} 套用）"
}

cmd_profile_apply() {  # 顯示 diff、備份舊檔、套用 .incoming（唯一真正覆寫生效檔的步驟）
  local name=""
  while [ $# -gt 0 ]; do case "$1" in
    --name) name="$2"; shift 2;;
    *) die "未知參數 $1";; esac; done
  [ -n "$name" ] || die "profile-apply 需要 --name NAME"
  profile_is_primary_only "$name" && die "os-mirror-* 是唯讀鏡像，沒有 apply 步驟"

  local local_path; local_path="$(profile_local_path "$name")"
  local incoming="${local_path}.incoming"
  [ -f "$incoming" ] || die "找不到待套用檔：${incoming}（先執行 profile-pull --name ${name}）"

  log "=== 即將套用的差異（${local_path}）==="
  if [ -f "$local_path" ]; then
    diff -u "$local_path" "$incoming" || true
  else
    log "本機目前無此檔案，將直接建立"
  fi

  if [ -f "$local_path" ]; then
    local ts backup_dir; ts="$(date -u +%Y%m%dT%H%M%SZ)"
    backup_dir="$APP_SUPPORT/profile-backups/$ts"
    mkdir -p "$backup_dir"
    cp "$local_path" "$backup_dir/$(basename "$local_path")"
    log "已備份舊檔：$backup_dir/$(basename "$local_path")"
  fi
  mkdir -p "$(dirname "$local_path")"
  cp "$incoming" "$local_path"
  rm -f "$incoming"
  log "已套用：${name} → ${local_path}"
}

cmd_devices_list() {  # 列出通道上已登記的設備
  channel_ensure
  read_primary_state
  local d="$CHANNEL_DIR/devices"
  [ -d "$d" ] || { log "尚無登記設備"; return; }
  local any=0 name role
  for f in "$d"/*.json; do
    [ -f "$f" ] || continue; any=1
    name="$(json_get "$f" name)"
    role="secondary"
    [ -n "$PRIMARY_NAME" ] && [ "$name" = "$PRIMARY_NAME" ] && role="primary"
    log "$name • $role • ssh=$(json_get "$f" sshHost) • enrolled=$(json_get "$f" enrolledAt)"
  done
  if [ "$any" = "0" ]; then
    log "尚無登記設備"
  fi
}

cmd_trust_verify_artifact() {
  local device="" device_id="" purpose="" input="" signature=""
  while [ $# -gt 0 ]; do case "$1" in
    --device) device="${2:-}"; shift 2;;
    --device-id) device_id="${2:-}"; shift 2;;
    --purpose) purpose="${2:-}"; shift 2;;
    --input) input="${2:-}"; shift 2;;
    --signature) signature="${2:-}"; shift 2;;
    *) die "未知參數 $1";; esac; done
  validate_device_name "$device"
  case "$device_id" in
    ""|.|..|*/*|*[!A-Za-z0-9._:-]*) die "device id 含有不安全字元";;
  esac
  case "$purpose" in sync-request|sync-ack|target-attestation) ;; *)
    die "不支援的 device trust purpose：$purpose"
    ;;
  esac
  case "$input" in "$CHANNEL_DIR"/*) ;; *)
    die "device trust input 必須位於目前 channel checkout"
    ;;
  esac
  case "$signature" in "$CHANNEL_DIR"/*) ;; *)
    die "device trust signature 必須位於目前 channel checkout"
    ;;
  esac
  verify_channel_artifact_signature \
    "$device" "$device_id" "$purpose" "$input" "$signature" \
    || die "device trust signature 驗證失敗：device=$device purpose=$purpose"
  log "device trust signature verified：device=$device purpose=$purpose"
}

skillet_lane_safe_id() {
  case "$1" in
    ""|.|..|*/*|*[!A-Za-z0-9._:-]*) return 1;;
  esac
  return 0
}

skillet_lane_self_alias() {
  if [ -n "${TATWO_SKILLET_LANE_SELF:-}" ]; then
    printf '%s\n' "$TATWO_SKILLET_LANE_SELF"
    return 0
  fi
  case "$DEVICE_NAME" in
    TATWO|*macbook*|*MacBook*) printf 'macbook\n';;
    *) printf 'mini\n';;
  esac
}

skillet_lane_peer_alias() {
  if [ -n "${TATWO_SKILLET_LANE_PEER:-}" ]; then
    printf '%s\n' "$TATWO_SKILLET_LANE_PEER"
    return 0
  fi
  case "$(skillet_lane_self_alias)" in
    macbook) printf 'mini\n';;
    *) printf 'macbook\n';;
  esac
}

skillet_lane_peer_device_id() {
  local peer_name="${TATWO_SKILLET_SYNC_PEER:-TATWO}"
  local peer_file="$CHANNEL_DIR/devices/$peer_name.json"
  if [ -f "$peer_file" ]; then
    json_get "$peer_file" deviceId
    return 0
  fi
  printf '%s\n' "${TATWO_SKILLET_SYNC_PEER_DEVICE_ID:-}"
}

skillet_lane_store_heads_digest() {
  local repo_root="$SKILLET_STORE/repositories"
  [ -d "$repo_root" ] || return 1
  find "$repo_root" -mindepth 2 -maxdepth 2 -type f -name repository.json -print \
    | LC_ALL=C sort \
    | while IFS= read -r metadata; do
        local repository_id canonical
        repository_id="$(basename "$(dirname "$metadata")")"
        canonical="$(json_get "$metadata" canonicalRevision)"
        printf '%s\t%s\n' "$repository_id" "$canonical"
      done \
    | shasum -a 256 \
    | awk '{print $1}'
}

export_skillet_lane_set() {
  local request_dir="$1" id="$2" catalog_revision="$3" source_device_id="$4"
  local authority_epoch="$5" target_device_id="$6" ledger_sequence="$7"
  local set_manifest="$request_dir/set.json"
  local receipt_root="$APP_SUPPORT/device-sync-state/skillet-lane-export/$id"
  local repository_id repository_payload export_receipt
  local revision_id content_digest bundle_digest index=0
  mkdir -p "$request_dir/repositories" "$receipt_root"
  cat >"$set_manifest" <<EOF
{
  "schemaVersion": 1,
  "requestID": "$id",
  "catalogRevision": "$catalog_revision",
  "authorityEpoch": $authority_epoch,
  "ledgerSequence": $ledger_sequence,
  "sourceDeviceID": "$source_device_id",
  "targetDeviceID": "$target_device_id",
  "purpose": "skillet-bundle",
  "repositories": [
EOF
  while IFS= read -r repository_id; do
    skillet_lane_safe_id "$repository_id" \
      || die "Skillet lane repository id 不安全：${repository_id:-missing}"
    repository_payload="$request_dir/repositories/$repository_id"
    export_receipt="$receipt_root/$repository_id.json"
    mkdir -p "$repository_payload"
    run_skillet_cli skillet export-bound \
      --store "$SKILLET_STORE" \
      --repository "$repository_id" \
      --bundle "$repository_payload/bundle" \
      --binding "$repository_payload/authority-binding.json" \
      --request "$id" \
      --source-device "$source_device_id" \
      --target-device "$target_device_id" \
      --authority-epoch "$authority_epoch" \
      --ledger-sequence "$ledger_sequence" \
      --catalog-revision "$catalog_revision" \
      --receipt "$export_receipt" \
      --json >/dev/null
    revision_id="$(json_get "$export_receipt" revisionID)"
    content_digest="$(json_get "$export_receipt" contentDigest)"
    bundle_digest="$(json_get "$export_receipt" bundleDigest)"
    [ "$(json_get "$export_receipt" repositoryID)" = "$repository_id" ] \
      || die "Skillet lane export receipt repository 不一致：$repository_id"
    [ "$index" -eq 0 ] || printf ',\n' >>"$set_manifest"
    cat >>"$set_manifest" <<EOF
    {
      "repositoryID": "$repository_id",
      "revisionID": "$revision_id",
      "contentDigest": "$content_digest",
      "bundleDigest": "$bundle_digest",
      "bundleRelativePath": "repositories/$repository_id/bundle",
      "bindingRelativePath": "repositories/$repository_id/authority-binding.json"
    }
EOF
    index=$((index + 1))
  done < <(
    find "$SKILLET_STORE/repositories" \
      -mindepth 2 -maxdepth 2 -type f -name repository.json -print 2>/dev/null \
      | while IFS= read -r metadata; do
          basename "$(dirname "$metadata")"
        done \
      | LC_ALL=C sort
  )
  cat >>"$set_manifest" <<EOF
  ]
}
EOF
  [ "$index" -gt 0 ] || die "Skillet lane set is empty"
}

sign_skillet_lane_set() {
  local set_manifest="$1" signature_output="$2"
  local identity_file
  mkdir -p "$(dirname "$signature_output")"
  identity_file="$(device_trust_identity_file 2>/dev/null || true)"
  if [ -z "$identity_file" ] || [ ! -f "$identity_file" ]; then
    log "skillet-lane 簽名略過：device-trust identity 不可用（未寫 Keychain）"
    return 1
  fi
  if ! run_device_trust_cli sign \
    --purpose "skillet-bundle" \
    --registry "$identity_file" \
    --input "$set_manifest" \
    --signature-out "$signature_output" >/dev/null
  then
    log "skillet-lane 簽名失敗：device-trust sign 需要既有 Keychain ACL，本回合不寫 Keychain"
    rm -f "$signature_output"
    return 1
  fi
  return 0
}

publish_skillet_source_to_loop_channel() {
  local peer self_alias source_device_id target_device_id
  local catalog_revision authority_epoch ledger_sequence request_id
  local heads_digest last_state last_heads request_dir signature_path
  local state_dir="$APP_SUPPORT/device-sync-state/skillet-lane"
  if [ "$SKILLET_LANE_PUBLISH" != "1" ]; then
    log "skillet-lane publish 略過：TATWO_SKILLET_LANE_PUBLISH=0（不整包外送本機 skill）"
    return 0
  fi
  local sequence_file="$state_dir/sequence"
  mkdir -p "$state_dir" "$SKILLET_LANE_ROOT/outbox" "$LOOP_CHANNEL_ROOT/signatures/skillet"
  self_alias="$(skillet_lane_self_alias)"
  peer="$(skillet_lane_peer_alias)"
  skillet_lane_safe_id "$peer" || die "skillet lane peer 不安全：$peer"
  source_device_id="$(json_get "$(device_identity_file)" deviceId)"
  target_device_id="$(skillet_lane_peer_device_id)"
  skillet_lane_safe_id "$source_device_id" || die "本機 device id 不可用"
  skillet_lane_safe_id "$target_device_id" \
    || {
      log "skillet-lane publish 略過：對端 device id 未知；請設 TATWO_SKILLET_SYNC_PEER 或 TATWO_SKILLET_SYNC_PEER_DEVICE_ID"
      return 0
    }
  catalog_revision="$(sync_catalog_revision)"
  authority_epoch="$(json_number_get "$CHANNEL_DIR/primary.json" epoch 2>/dev/null || true)"
  [ -n "$authority_epoch" ] || authority_epoch=1
  heads_digest="$(skillet_lane_store_heads_digest)" \
    || {
      log "skillet-lane publish 略過：store 沒有 repository"
      return 0
    }
  last_state="$state_dir/last-publish.json"
  last_heads=""
  [ -f "$last_state" ] && last_heads="$(json_get "$last_state" headsDigest)"
  if [ "$last_heads" = "$heads_digest" ] \
    && [ "${TATWO_SKILLET_LANE_FORCE_PUBLISH:-0}" != "1" ]
  then
    log "skillet-lane publish 無新 store head，略過"
    return 0
  fi
  if [ -f "$sequence_file" ]; then
    ledger_sequence="$(cat "$sequence_file")"
  else
    ledger_sequence=0
  fi
  ledger_sequence=$((ledger_sequence + 1))
  request_id="$(newid)"
  request_dir="$SKILLET_LANE_ROOT/outbox/$peer/$request_id"
  [ ! -e "$request_dir" ] || die "skillet lane request 已存在：$request_id"
  export_skillet_lane_set \
    "$request_dir" "$request_id" "$catalog_revision" "$source_device_id" \
    "$authority_epoch" "$target_device_id" "$ledger_sequence"
  signature_path="$LOOP_CHANNEL_ROOT/signatures/skillet/$peer/$request_id.json"
  if sign_skillet_lane_set "$request_dir/set.json" "$signature_path"; then
    log "skillet-lane published request=$request_id peer=$peer signed=1"
  else
    printf '%s\n' "{\"schema\":\"TatwoSkilletLaneUnsignedV1\",\"requestID\":\"$request_id\",\"reason\":\"device-trust-sign-unavailable-no-keychain-write\"}" \
      >"$state_dir/$request_id.unsigned.json"
    log "skillet-lane published request=$request_id peer=$peer signed=0（對端不得 import-activate 直到有 skillet-bundle 簽名）"
  fi
  printf '%s\n' "$ledger_sequence" >"$sequence_file"
  cat >"$last_state" <<EOF
{
  "schema": "TatwoSkilletLanePublishStateV1",
  "requestID": "$request_id",
  "peer": "$peer",
  "selfAlias": "$self_alias",
  "headsDigest": "$heads_digest",
  "sourceDeviceID": "$source_device_id",
  "targetDeviceID": "$target_device_id",
  "authorityEpoch": $authority_epoch,
  "ledgerSequence": $ledger_sequence,
  "catalogRevision": "$catalog_revision"
}
EOF
}

quarantine_skillet_lane_request() {
  local request_dir="$1" reason="$2"
  local request_id dest
  request_id="$(basename "$request_dir")"
  dest="$SKILLET_LANE_ROOT/rejected/$reason/$request_id"
  mkdir -p "$(dirname "$dest")"
  if [ -e "$dest" ]; then
    dest="$dest-$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  mv "$request_dir" "$dest"
  printf '%s\n' "{\"schema\":\"TatwoSkilletLaneRejectedV1\",\"requestID\":\"$request_id\",\"reason\":\"$reason\",\"movedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
    >"$dest/rejected.json"
  log "skillet-lane 已封存 $request_id reason=$reason（不再重試、未啟動）"
}

file_skillet_lane_proposal() {
  local request_dir="$1"
  local request_id dest
  request_id="$(basename "$request_dir")"
  dest="$SKILLET_LANE_ROOT/proposals/$request_id"
  mkdir -p "$(dirname "$dest")"
  if [ -e "$dest" ]; then
    dest="$dest-$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  mv "$request_dir" "$dest"
  printf '%s\n' "{\"schema\":\"TatwoSkilletLaneProposalV1\",\"requestID\":\"$request_id\",\"note\":\"inbox-only; live skills and OS untouched\",\"filedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
    >"$dest/proposal.json"
  log "skillet-lane 已收提案 $request_id（不覆蓋本機 skill、不灌 OS）"
}

accept_one_skillet_lane_set() {
  local set_manifest="$1"
  local request_dir request_id source_device_id target_device_id
  local catalog_revision authority_epoch ledger_sequence
  local local_device_id signature_path peer source_name source_registry
  request_dir="$(dirname "$set_manifest")"
  request_id="$(json_get "$set_manifest" requestID)"
  source_device_id="$(json_get "$set_manifest" sourceDeviceID)"
  target_device_id="$(json_get "$set_manifest" targetDeviceID)"
  catalog_revision="$(json_get "$set_manifest" catalogRevision)"
  authority_epoch="$(json_number_get "$set_manifest" authorityEpoch)"
  ledger_sequence="$(json_number_get "$set_manifest" ledgerSequence)"
  local_device_id="$(json_get "$(device_identity_file)" deviceId)"
  skillet_lane_safe_id "$request_id" || return 1
  [ "$target_device_id" = "$local_device_id" ] \
    || {
      log "skillet-lane accept 略過 $request_id：target 不是本機"
      return 0
    }
  peer="$(basename "$(dirname "$request_dir")")"
  signature_path="$LOOP_CHANNEL_ROOT/signatures/skillet/$peer/$request_id.json"
  if [ ! -f "$signature_path" ]; then
    log "skillet-lane accept 拒絕 $request_id：缺少 purpose=skillet-bundle 簽名"
    quarantine_skillet_lane_request "$request_dir" "unsigned"
    return 0
  fi
  source_name=""
  source_registry=""
  for source_registry in "$CHANNEL_DIR/devices"/*.json; do
    [ -f "$source_registry" ] || continue
    if [ "$(json_get "$source_registry" deviceId)" = "$source_device_id" ]; then
      source_name="$(basename "$source_registry" .json)"
      break
    fi
  done
  [ -n "$source_name" ] && [ -f "$source_registry" ] \
    || {
      log "skillet-lane accept 拒絕 $request_id：找不到 source device registry"
      quarantine_skillet_lane_request "$request_dir" "missing-source-registry"
      return 0
    }
  if ! run_device_trust_cli verify \
    --purpose "skillet-bundle" \
    --registry "$source_registry" \
    --input "$set_manifest" \
    --signature "$signature_path" >/dev/null
  then
    log "skillet-lane accept 拒絕 $request_id：skillet-bundle 驗簽失敗"
    quarantine_skillet_lane_request "$request_dir" "verify-failed"
    return 0
  fi
  if [ "$SKILLET_APPLY" != "1" ]; then
    file_skillet_lane_proposal "$request_dir"
    return 0
  fi
  activate_skillet_set \
    "$set_manifest" "$request_id" "$source_device_id" "$target_device_id" \
    "$DEVICE_NAME" "$authority_epoch" "$ledger_sequence" "$catalog_revision" \
    || {
      log "skillet-lane import-activate 失敗：$request_id"
      return 1
    }
  verify_active_skillet_set \
    "$set_manifest" "$request_id" "$source_device_id" "$target_device_id" \
    "$authority_epoch" "$ledger_sequence" "$catalog_revision" \
    || {
      log "skillet-lane verify-active-set 失敗：$request_id"
      return 1
    }
  log "skillet-lane accepted request=$request_id"
}

accept_skillet_source_from_loop_channel() {
  local self_alias request_dir set_manifest
  self_alias="$(skillet_lane_self_alias)"
  mkdir -p "$SKILLET_LANE_ROOT/inbox" "$SKILLET_LANE_ROOT/outbox/$self_alias"
  for request_dir in \
    "$SKILLET_LANE_ROOT/inbox"/* \
    "$SKILLET_LANE_ROOT/outbox/$self_alias"/*
  do
    [ -d "$request_dir" ] || continue
    set_manifest="$request_dir/set.json"
    [ -f "$set_manifest" ] || continue
    accept_one_skillet_lane_set "$set_manifest" || true
  done
}

peer_inventory_store_dir() {
  printf '%s\n' "$APP_SUPPORT/device-peer-inventory"
}

peer_inventory_channel_dir() {
  printf '%s\n' "$CHANNEL_DIR/inventory"
}

peer_inventory_safe_device_id() {
  case "$1" in
    ""|.|..|*/*|*\\*|*[!A-Za-z0-9._-]*) return 1;;
  esac
}

collect_local_cpu_percent() {
  local line user sys
  line="$(
    top -l 2 -s 1 -n 0 2>/dev/null \
      | awk '/CPU usage/ {line=$0} END {print line}'
  )"
  [ -n "$line" ] || return 1
  user="$(printf '%s\n' "$line" | sed -n 's/.*CPU usage: *\([0-9.][0-9.]*\)% user.*/\1/p')"
  sys="$(printf '%s\n' "$line" | sed -n 's/.*user, *\([0-9.][0-9.]*\)% sys.*/\1/p')"
  awk -v u="$user" -v s="$sys" 'BEGIN {
    if (u == "" || s == "") exit 1
    v = u + s
    if (v < 0 || v > 100) exit 1
    printf "%.1f\n", v
  }'
}

collect_local_memory_pressure_level() {
  local raw
  raw="$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || true)"
  case "$raw" in
    0) printf 'normal\n';;
    1) printf 'warn\n';;
    2) printf 'urgent\n';;
    4) printf 'critical\n';;
    "") return 1;;
    *) printf 'unknown\n';;
  esac
}

collect_local_active_loop_count() {
  local count=0
  local projection="$APP_SUPPORT/state/app-pressure-projection.json"
  if [ -f "$projection" ] && [ ! -L "$projection" ]; then
    count="$(plutil -extract hostInventory.activeLoopCount raw "$projection" 2>/dev/null || true)"
    case "$count" in
      ""|*[!0-9]*) ;;
      *) printf '%s\n' "$count"; return 0;;
    esac
    count="$(plutil -extract activeLoopCount raw "$projection" 2>/dev/null || true)"
    case "$count" in
      ""|*[!0-9]*) ;;
      *) printf '%s\n' "$count"; return 0;;
    esac
  fi
  return 1
}

write_local_peer_inventory_file() {
  local device_id dest hw_model chip ram cpu pressure loops ts tmp
  device_id="$1"
  dest="$2"
  peer_inventory_safe_device_id "$device_id" || die "inventory deviceID 不合法"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  hw_model="$(sysctl -n hw.model 2>/dev/null || true)"
  chip="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)"
  if [ -z "$chip" ]; then
    if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = "1" ]; then
      chip="Apple Silicon"
    else
      chip="$(sysctl -n hw.machine 2>/dev/null || true)"
    fi
  fi
  ram="$(sysctl -n hw.memsize 2>/dev/null || true)"
  case "$ram" in ""|*[!0-9]*) ram="";; esac
  cpu="$(collect_local_cpu_percent 2>/dev/null || true)"
  case "$cpu" in ""|*[!0-9.]*) cpu="";; esac
  pressure="$(collect_local_memory_pressure_level 2>/dev/null || true)"
  case "$pressure" in normal|warn|urgent|critical|unknown) ;; *) pressure="";; esac
  loops="$(collect_local_active_loop_count 2>/dev/null || true)"
  case "$loops" in ""|*[!0-9]*) loops="";; esac

  tmp="${dest}.$$.tmp"
  {
    printf '{\n'
    printf '  "schema": "TatwoDevicePeerInventoryV1",\n'
    printf '  "deviceID": "%s",\n' "$(json_escape "$device_id")"
    if [ -n "$hw_model" ]; then
      printf '  "hardwareModel": "%s",\n' "$(json_escape "$hw_model")"
    fi
    if [ -n "$chip" ]; then
      printf '  "chipName": "%s",\n' "$(json_escape "$chip")"
    fi
    if [ -n "$ram" ]; then
      printf '  "ramTotalBytes": %s,\n' "$ram"
    fi
    if [ -n "$cpu" ]; then
      printf '  "cpuPercent": %s,\n' "$cpu"
    fi
    if [ -n "$pressure" ]; then
      printf '  "memoryPressureLevel": "%s",\n' "$(json_escape "$pressure")"
    fi
    if [ -n "$loops" ]; then
      printf '  "activeLoopCount": %s,\n' "$loops"
    fi
    printf '  "timestamp": "%s"\n' "$ts"
    printf '}\n'
  } >"$tmp"
  mv "$tmp" "$dest"
}

ingest_channel_peer_inventory() {
  local channel_dir store_dir file dest device_id schema
  channel_dir="$(peer_inventory_channel_dir)"
  store_dir="$(peer_inventory_store_dir)"
  mkdir -p "$store_dir"
  [ -d "$channel_dir" ] || {
    log "inventory-ingest：通道尚無 inventory/"
    return 0
  }
  for file in "$channel_dir"/*.json; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    schema="$(json_get "$file" schema)"
    device_id="$(json_get "$file" deviceID)"
    [ "$schema" = "TatwoDevicePeerInventoryV1" ] || {
      log "inventory-ingest 略過非 inventory schema：$(basename "$file")"
      continue
    }
    peer_inventory_safe_device_id "$device_id" || {
      log "inventory-ingest 略過不安全 deviceID：$(basename "$file")"
      continue
    }
    [ "$(basename "$file" .json)" = "$device_id" ] || {
      log "inventory-ingest 略過檔名與 deviceID 不符：$(basename "$file")"
      continue
    }
    dest="$store_dir/${device_id}.json"
    cp "$file" "${dest}.$$.tmp" && mv "${dest}.$$.tmp" "$dest"
  done
}

# 掃掉先前中斷留下的 staging 殘檔。
# 2026-08-29：channel_ensure 於工作樹髒掉時 fail-closed die，令 publish 的
# `rm -f "$staging"` 永遠執行不到，每 45 秒漏一個檔，累積 11,365 個。
# 順序已改為先 channel_ensure 再建 staging；此掃描為第二道自癒防線。
peer_inventory_sweep_stale_staging() {
  local dir; dir="$(peer_inventory_store_dir)"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -type f -name '.local-publish-*.json' -mmin +60 -delete 2>/dev/null || true
  find "$dir" -maxdepth 1 -type f -name '*.json.*.tmp' -mmin +60 -delete 2>/dev/null || true
}

cmd_inventory_publish() {
  ensure_device_identity
  local device_id staging dest
  device_id="$(json_get "$(device_identity_file)" deviceId)"
  peer_inventory_safe_device_id "$device_id" || die "本機 device identity 缺少可用 deviceId"
  mkdir -p "$(peer_inventory_store_dir)"
  peer_inventory_sweep_stale_staging
  # channel_ensure 會在通道工作樹不乾淨時 fail-closed die，必須在建立 staging
  # 之前先過關，否則 staging 永遠等不到下方的 rm，會無限累積殘檔。
  channel_ensure
  staging="$(peer_inventory_store_dir)/.local-publish-${device_id}.$$.json"
  write_local_peer_inventory_file "$device_id" "$staging"
  mkdir -p "$(peer_inventory_channel_dir)"
  dest="$(peer_inventory_channel_dir)/${device_id}.json"
  cp "$staging" "$dest"
  rm -f "$staging"
  git -C "$CHANNEL_DIR" add "inventory/${device_id}.json"
  if git -C "$CHANNEL_DIR" commit -m "inventory ${device_id}" >/dev/null 2>&1; then
    channel_push
    log "已發布本機 inventory：deviceID=$device_id"
  else
    log "inventory 沒有變更：deviceID=$device_id"
  fi
}

cmd_inventory_ingest() {
  channel_ensure
  ingest_channel_peer_inventory
  log "已 ingest 對端 inventory 到 $(peer_inventory_store_dir)"
}

cmd_inventory_sync() {
  cmd_inventory_publish
  ingest_channel_peer_inventory
  log "inventory-sync 完成"
}

cmd_skillet_source_sync() {
  local mode="${1:-both}"
  case "$mode" in
    publish|accept|both) ;;
    *) die "skillet-source-sync 用法：publish|accept|both";;
  esac
  [ -d "$SKILLET_STORE/repositories" ] \
    || {
      log "skillet-source-sync 略過：store 不存在"
      return 0
    }
  case "$mode" in
    publish) publish_skillet_source_to_loop_channel;;
    accept) accept_skillet_source_from_loop_channel;;
    both)
      publish_skillet_source_to_loop_channel
      accept_skillet_source_from_loop_channel
      ;;
  esac
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    role-status|set-primary|integrate|sync-request|sync-poll|sync-ack-status|trust-rotate|register|pairing-create|devices-list|profile-push|profile-pull|inventory-publish|inventory-ingest|inventory-sync)
      channel_lock_acquire
      ;;
  esac
  case "$sub" in
    version-status) cmd_version_status "$@";;
    version-push)   cmd_version_push "$@";;
    version-pull)   cmd_version_pull "$@";;
    role-status)    cmd_role_status "$@";;
    set-primary)    cmd_set_primary "$@";;
    integrate)      cmd_integrate "$@";;
    db-pull)        cmd_db_pull "$@";;
    sync-request)   cmd_sync_request "$@";;
    sync-poll)      cmd_sync_poll "$@";;
    sync-ack-status) cmd_sync_ack_status "$@";;
    trust-verify-artifact) cmd_trust_verify_artifact "$@";;
    trust-rotate) cmd_trust_rotate "$@";;
    register)       cmd_register "$@";;
    pairing-create) cmd_pairing_create "$@";;
    devices-list)   cmd_devices_list "$@";;
    profile-push)   cmd_profile_push "$@";;
    profile-pull)   cmd_profile_pull "$@";;
    profile-apply)  cmd_profile_apply "$@";;
    skillet-source-sync) cmd_skillet_source_sync "$@";;
    inventory-publish) cmd_inventory_publish "$@";;
    inventory-ingest) cmd_inventory_ingest "$@";;
    inventory-sync) cmd_inventory_sync "$@";;
    ""|-h|--help)
      grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; ;;
    *) die "未知子命令：${sub}（用 --help 看說明）";;
  esac
}
main "$@"
