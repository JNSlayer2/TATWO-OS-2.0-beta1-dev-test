#!/usr/bin/env bash
# tatwo-sync-helper.sh — 副設備常駐同步 helper（被 mini 遠端驅動的接收端）
#
# 迴圈：每 INTERVAL 秒
#   1) sync-poll：看主設備有沒有透過通道發起同步指令，有就執行（db-pull / version-pull）
#   2) 保底版本追蹤：即使沒收到指令，也定期檢查 release/tatwo-os 有無新版（可關）
#   3) inventory-sync：寫本機硬體盤點到通道 inventory/<deviceID>.json，並 ingest 對端實報
#   4) model-collab-presets：owner-initiated 套用 gateway roster + agent-presets（不含憑證）
# fail-soft：任何一步失敗只記 log、不中斷迴圈；下一輪再試。
#
# 由 tatwo-device-enroll.sh 裝成 LaunchAgent 常駐；也可手動前景跑來測。
# 環境變數：TATWO_DEVICE_NAME / TATWO_PRIMARY_SSH_HOST / TATWO_SYNC_INTERVAL /
#           TATWO_AUTO_VERSION(1=保底追版本, 預設 0 — 必須顯式 opt-in。
#           2026-08-15: 不可再預設 1。os-image 消費者的 version-pull 會改道成
#           tatwo-os-image.sh sync（遠端 publish + 拉 + 熱套用 gateway），
#           每 10 分鐘自動改房間外機器的 runtime。要保底追版本請設 TATWO_AUTO_VERSION=1。)
#           TATWO_APP_SUPPORT / TATWO_SYNC_REPO
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SYNC="$HERE/tatwo-device-sync.sh"
INTERVAL="${TATWO_SYNC_INTERVAL:-45}"
AUTO_VERSION="${TATWO_AUTO_VERSION:-0}"
RUN_ONCE="${TATWO_SYNC_HELPER_ONCE:-0}"
APP_SUPPORT="${TATWO_APP_SUPPORT:-$HOME/Library/Application Support/Tatwo Ultrawork}"
DEVICE_NAME="${TATWO_DEVICE_NAME:-$(hostname -s 2>/dev/null || echo device)}"
DEVICE_ROLE="${TATWO_DEVICE_ROLE:-secondary}"
LOG="$APP_SUPPORT/sync-helper.log"
OUTBOX_ROOT="$APP_SUPPORT/device-sync-outbox"
OUTBOX_PENDING="$OUTBOX_ROOT/pending"
OUTBOX_CLAIMED="$OUTBOX_ROOT/claimed"
OUTBOX_RECEIPTS="$OUTBOX_ROOT/receipts"
CHANNEL_DIR="${TATWO_CHANNEL_DIR:-$APP_SUPPORT/device-sync-channel}"
SYNC_CATALOG="${TATWO_SYNC_CATALOG:-$HERE/../config/tatwo-sync-catalog-v1.json}"
LOCAL_ACTIONS_ROOT="$APP_SUPPORT/device-local-actions"
LOCAL_ACTIONS_PENDING="$LOCAL_ACTIONS_ROOT/pending"
LOCAL_ACTIONS_CLAIMED="$LOCAL_ACTIONS_ROOT/claimed"
LOCAL_ACTIONS_RECEIPTS="$LOCAL_ACTIONS_ROOT/receipts"

mkdir -p "$APP_SUPPORT"
hlog() { printf '%s • helper • %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }
verify_channel_signature() {
  local device="$1" device_id="$2" purpose="$3" input="$4" signature="$5"
  bash "$SYNC" trust-verify-artifact \
    --device "$device" \
    --device-id "$device_id" \
    --purpose "$purpose" \
    --input "$input" \
    --signature "$signature" >>"$LOG" 2>&1
}
json_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '"%s"' "$value"
}
sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}
is_sha256_digest() {
  local value="$1"
  case "$value" in ""|*[!0-9a-f]*) return 1;; esac
  [ "${#value}" -eq 64 ]
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
validate_nonnegative_integer() {
  case "$1" in ""|*[!0-9]*) return 1;; esac
}
validate_nonnegative_number() {
  case "$1" in ""|*[!0-9.]*|*.*.*|.) return 1;; esac
}
sync_ack_phase_rank() {
  case "$1" in
    delivered) printf '5\n';;
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
validate_sync_progress_transition() {
  local ack="$1" receipt="$2" ack_phase="$3" receipt_phase="$4"
  local ack_has_progress=0 receipt_has_progress=0 key previous next
  plutil -extract progress raw "$ack" >/dev/null 2>&1 && ack_has_progress=1
  plutil -extract progress raw "$receipt" >/dev/null 2>&1 && receipt_has_progress=1
  case "$ack_phase" in
    accepted|transferring|merging|validating|activating)
      [ "$ack_has_progress" = "1" ] || return 1
      ;;
  esac
  if [ "$ack_has_progress" = "1" ]; then
    validate_sync_progress_payload "$ack" progress "$ack_phase" || return 1
  fi
  local ack_rank receipt_rank
  ack_rank="$(sync_ack_phase_rank "$ack_phase" 2>/dev/null || true)"
  receipt_rank="$(sync_ack_phase_rank "$receipt_phase" 2>/dev/null || true)"
  if [ -n "$ack_rank" ] && [ -n "$receipt_rank" ] && [ "$ack_rank" -lt "$receipt_rank" ]; then
    return 1
  fi
  if [ "$ack_has_progress" = "1" ] && [ "$receipt_has_progress" = "1" ]; then
    for key in completedBytes completedItems completedRepositories elapsedMilliseconds; do
      previous="$(plutil -extract "progress.$key" raw "$receipt" 2>/dev/null || true)"
      next="$(plutil -extract "progress.$key" raw "$ack" 2>/dev/null || true)"
      validate_nonnegative_integer "$previous" \
        && validate_nonnegative_integer "$next" \
        && [ "$next" -ge "$previous" ] \
        || return 1
    done
    for key in totalBytes totalItems totalRepositories; do
      previous="$(plutil -extract "progress.$key" raw "$receipt" 2>/dev/null || true)"
      next="$(plutil -extract "progress.$key" raw "$ack" 2>/dev/null || true)"
      [ "$next" = "$previous" ] || return 1
    done
  fi
}
catalog_system_pull_count() {
  plutil -extract systemPullItemIDs raw "$SYNC_CATALOG" 2>/dev/null || true
}
catalog_system_pull_id() {
  plutil -extract "systemPullItemIDs.$1" raw "$SYNC_CATALOG" 2>/dev/null || true
}
validate_skillet_ack_item() {
  local ack="$1" manifest="$2" item_index="$3" request_id="$4"
  local source_device_id="$5" target_device_id="$6" authority_epoch="$7"
  local ledger_sequence="$8" catalog_revision="$9"
  local payload_relative repository_count ack_repository_count ack_repositories_count
  local set_manifest set_index=0 repository_id revision_id content_digest bundle_digest
  local ack_repository_id ack_revision_id ack_content_digest ack_bundle_digest ack_phase
  local bundle_relative binding_relative binding bundle

  payload_relative="$(plutil -extract "items.$item_index.payloadRelativePath" raw "$manifest" 2>/dev/null || true)"
  [ "$payload_relative" = "items/skills.skillet/set.json" ] || return 1
  set_manifest="$(dirname "$manifest")/$payload_relative"
  [ -f "$set_manifest" ] || return 1
  repository_count="$(plutil -extract "items.$item_index.repositoryCount" raw "$manifest" 2>/dev/null || true)"
  ack_repository_count="$(plutil -extract "items.$item_index.repositoryCount" raw "$ack" 2>/dev/null || true)"
  ack_repositories_count="$(plutil -extract "items.$item_index.repositories" raw "$ack" 2>/dev/null || true)"
  case "$repository_count:$ack_repository_count:$ack_repositories_count" in
    *[!0-9:]*|:*|*::|::*|*:) return 1;;
  esac
  [ "$ack_repository_count" = "$repository_count" ] \
    && [ "$ack_repositories_count" = "$repository_count" ] || return 1
  [ "$(plutil -extract requestID raw "$set_manifest" 2>/dev/null || true)" = "$request_id" ] \
    && [ "$(plutil -extract sourceDeviceID raw "$set_manifest" 2>/dev/null || true)" = "$source_device_id" ] \
    && [ "$(plutil -extract targetDeviceID raw "$set_manifest" 2>/dev/null || true)" = "$target_device_id" ] \
    && [ "$(plutil -extract authorityEpoch raw "$set_manifest" 2>/dev/null || true)" = "$authority_epoch" ] \
    && [ "$(plutil -extract ledgerSequence raw "$set_manifest" 2>/dev/null || true)" = "$ledger_sequence" ] \
    && [ "$(plutil -extract catalogRevision raw "$set_manifest" 2>/dev/null || true)" = "$catalog_revision" ] \
    || return 1

  while [ "$set_index" -lt "$repository_count" ]; do
    repository_id="$(plutil -extract "repositories.$set_index.repositoryID" raw "$set_manifest" 2>/dev/null || true)"
    revision_id="$(plutil -extract "repositories.$set_index.revisionID" raw "$set_manifest" 2>/dev/null || true)"
    content_digest="$(plutil -extract "repositories.$set_index.contentDigest" raw "$set_manifest" 2>/dev/null || true)"
    bundle_digest="$(plutil -extract "repositories.$set_index.bundleDigest" raw "$set_manifest" 2>/dev/null || true)"
    bundle_relative="$(plutil -extract "repositories.$set_index.bundleRelativePath" raw "$set_manifest" 2>/dev/null || true)"
    binding_relative="$(plutil -extract "repositories.$set_index.bindingRelativePath" raw "$set_manifest" 2>/dev/null || true)"
    case "$repository_id" in ""|.|..|*/*|*[!A-Za-z0-9._:-]*) return 1;; esac
    is_sha256_digest "$content_digest" && is_sha256_digest "$bundle_digest" || return 1
    [ "$revision_id" = "rev-$content_digest" ] || return 1
    [ "$bundle_relative" = "repositories/$repository_id/bundle" ] \
      && [ "$binding_relative" = "repositories/$repository_id/authority-binding.json" ] \
      || return 1
    bundle="$(dirname "$set_manifest")/$bundle_relative"
    binding="$(dirname "$set_manifest")/$binding_relative"
    [ -d "$bundle" ] && [ -f "$binding" ] || return 1
    [ "$(plutil -extract repositoryID raw "$binding" 2>/dev/null || true)" = "$repository_id" ] \
      && [ "$(plutil -extract exportedRevisionID raw "$binding" 2>/dev/null || true)" = "$revision_id" ] \
      && [ "$(plutil -extract bundleDigest raw "$binding" 2>/dev/null || true)" = "$bundle_digest" ] \
      && [ "$(plutil -extract requestID raw "$binding" 2>/dev/null || true)" = "$request_id" ] \
      && [ "$(plutil -extract sourceDeviceID raw "$binding" 2>/dev/null || true)" = "$source_device_id" ] \
      && [ "$(plutil -extract targetDeviceID raw "$binding" 2>/dev/null || true)" = "$target_device_id" ] \
      && [ "$(plutil -extract authorityEpoch raw "$binding" 2>/dev/null || true)" = "$authority_epoch" ] \
      && [ "$(plutil -extract ledgerSequence raw "$binding" 2>/dev/null || true)" = "$ledger_sequence" ] \
      && [ "$(plutil -extract catalogRevision raw "$binding" 2>/dev/null || true)" = "$catalog_revision" ] \
      || return 1

    ack_repository_id="$(plutil -extract "items.$item_index.repositories.$set_index.repositoryID" raw "$ack" 2>/dev/null || true)"
    ack_revision_id="$(plutil -extract "items.$item_index.repositories.$set_index.revisionID" raw "$ack" 2>/dev/null || true)"
    ack_content_digest="$(plutil -extract "items.$item_index.repositories.$set_index.contentDigest" raw "$ack" 2>/dev/null || true)"
    ack_bundle_digest="$(plutil -extract "items.$item_index.repositories.$set_index.bundleDigest" raw "$ack" 2>/dev/null || true)"
    ack_phase="$(plutil -extract "items.$item_index.repositories.$set_index.phase" raw "$ack" 2>/dev/null || true)"
    [ "$ack_repository_id" = "$repository_id" ] \
      && [ "$ack_revision_id" = "$revision_id" ] \
      && [ "$ack_content_digest" = "$content_digest" ] \
      && [ "$ack_bundle_digest" = "$bundle_digest" ] \
      && [ "$ack_phase" = "verified" ] \
      && [ "$(plutil -extract "items.$item_index.repositories.$set_index.requestID" raw "$ack" 2>/dev/null || true)" = "$request_id" ] \
      && [ "$(plutil -extract "items.$item_index.repositories.$set_index.sourceDeviceID" raw "$ack" 2>/dev/null || true)" = "$source_device_id" ] \
      && [ "$(plutil -extract "items.$item_index.repositories.$set_index.targetDeviceID" raw "$ack" 2>/dev/null || true)" = "$target_device_id" ] \
      && [ "$(plutil -extract "items.$item_index.repositories.$set_index.authorityEpoch" raw "$ack" 2>/dev/null || true)" = "$authority_epoch" ] \
      && [ "$(plutil -extract "items.$item_index.repositories.$set_index.ledgerSequence" raw "$ack" 2>/dev/null || true)" = "$ledger_sequence" ] \
      && [ "$(plutil -extract "items.$item_index.repositories.$set_index.catalogRevision" raw "$ack" 2>/dev/null || true)" = "$catalog_revision" ] \
      || return 1
    set_index=$((set_index + 1))
  done
  return 0
}

validate_consumer_readback_set() {
  local file="$1" request_id="$2" target="$3" source_device_id="$4"
  local target_device_id="$5" authority_primary="$6" authority_epoch="$7"
  local ledger_sequence="$8" catalog_revision="$9" manifest_digest="${10}"
  local required_count readback_count index consumer_id source_item_id
  local expected_digest loaded_digest loaded_revision loaded_path status
  [ -s "$file" ] \
    && plutil -convert json -o /dev/null -- "$file" >/dev/null 2>&1 \
    && [ "$(plutil -extract schema raw "$file" 2>/dev/null || true)" = "TatwoTargetConsumerReadbackSetV1" ] \
    && [ "$(plutil -extract requestID raw "$file" 2>/dev/null || true)" = "$request_id" ] \
    && [ "$(plutil -extract target raw "$file" 2>/dev/null || true)" = "$target" ] \
    && [ "$(plutil -extract sourceDeviceID raw "$file" 2>/dev/null || true)" = "$source_device_id" ] \
    && [ "$(plutil -extract targetDeviceID raw "$file" 2>/dev/null || true)" = "$target_device_id" ] \
    && [ "$(plutil -extract authorityPrimary raw "$file" 2>/dev/null || true)" = "$authority_primary" ] \
    && [ "$(plutil -extract authorityEpoch raw "$file" 2>/dev/null || true)" = "$authority_epoch" ] \
    && [ "$(plutil -extract ledgerSequence raw "$file" 2>/dev/null || true)" = "$ledger_sequence" ] \
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
      && [ "$(plutil -extract "readbacks.$index.requestID" raw "$file" 2>/dev/null || true)" = "$request_id" ] \
      && [ "$(plutil -extract "readbacks.$index.targetDeviceID" raw "$file" 2>/dev/null || true)" = "$target_device_id" ] \
      && [ "$(plutil -extract "readbacks.$index.authorityPrimary" raw "$file" 2>/dev/null || true)" = "$authority_primary" ] \
      && [ "$(plutil -extract "readbacks.$index.authorityEpoch" raw "$file" 2>/dev/null || true)" = "$authority_epoch" ] \
      && [ "$(plutil -extract "readbacks.$index.ledgerSequence" raw "$file" 2>/dev/null || true)" = "$ledger_sequence" ] \
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

write_fallback_receipt() {
  local source="$1" receipt_stage="$2" receipt="$3" result="$4" phase="$5"
  local request_id="$6" completed_at="$7" message="$8" authority_epoch="$9"
  local ledger_sequence="${10}" authority_primary="${11}" source_device_id="${12}"
  local target_device_id="${13}" catalog_revision="${14}" target="${15}"
  local action="${16}" requested_at="${17}" source_refresh_attempt_id="${18:-}"
  local raw_intent
  raw_intent="$(cat "$source" 2>/dev/null || true)"
  {
    printf '{\n'
    printf '  "result": '; json_string "$result"; printf ',\n'
    printf '  "phase": '; json_string "$phase"; printf ',\n'
    printf '  "target": '; json_string "$target"; printf ',\n'
    printf '  "action": '; json_string "$action"; printf ',\n'
    printf '  "requestedAt": '; json_string "$requested_at"; printf ',\n'
    printf '  "requestID": '; json_string "$request_id"; printf ',\n'
    printf '  "sourceRefreshAttemptID": '; json_string "$source_refresh_attempt_id"; printf ',\n'
    printf '  "authorityEpoch": %s,\n' "${authority_epoch:-0}"
    printf '  "ledgerSequence": %s,\n' "${ledger_sequence:-0}"
    printf '  "authorityPrimary": '; json_string "$authority_primary"; printf ',\n'
    printf '  "sourceDeviceID": '; json_string "$source_device_id"; printf ',\n'
    printf '  "targetDeviceID": '; json_string "$target_device_id"; printf ',\n'
    printf '  "catalogRevision": '; json_string "$catalog_revision"; printf ',\n'
    printf '  "completedAt": '; json_string "$completed_at"; printf ',\n'
    printf '  "message": '; json_string "$message"; printf ',\n'
    printf '  "rawIntent": '; json_string "$raw_intent"; printf '\n'
    printf '}\n'
  } >"$receipt_stage" && mv "$receipt_stage" "$receipt"
}

[ -x "$SYNC" ] || { hlog "找不到執行器 ${SYNC}，結束"; exit 1; }
hlog "helper 啟動 device=${DEVICE_NAME} role=${DEVICE_ROLE} interval=${INTERVAL}s auto_version=${AUTO_VERSION}"

last_version_check=0
last_role=""
while true; do
  manager_name="$(launchctl managername 2>/dev/null || true)"
  if [ "${TATWO_TEST_MODE:-0}" != "1" ] && [ "$manager_name" != "Aqua" ]; then
    hlog "device-signing helper 僅允許 Aqua user session；目前 manager=${manager_name:-unknown}，本輪保持被動"
    [ "$RUN_ONCE" = "1" ] && break
    sleep "$INTERVAL"
    continue
  fi

  # 動態偵測本機是否為現任主（彈性主權：主是角色可切換，不是固定機器）。
  role_output=""
  current_role="unknown"
  current_primary=""
  current_epoch=""
  if role_output="$(bash "$SYNC" role-status 2>>"$LOG")"; then
    case "$role_output" in
      *"role=primary"*) current_role="primary";;
      *"role=secondary"*) current_role="secondary";;
      *"role=unassigned"*) current_role="unassigned";;
    esac
    current_primary="$(printf '%s\n' "$role_output" | sed -n 's/.* primary=\([^ ]*\).*/\1/p' | tail -1)"
    current_epoch="$(printf '%s\n' "$role_output" | sed -n 's/.* epoch=\([0-9][0-9]*\).*/\1/p' | tail -1)"
  else
    hlog "role-status 這輪失敗，主從角色未知；保底自動安裝 fail-closed 停用"
  fi
  if [ "$current_role" = "primary" ] && [ "$last_role" != "primary" ]; then
    hlog "本機已成為現任主設備；停用保底 auto version-pull 自動安裝，改跑 outbox 代發"
  fi
  last_role="$current_role"

  # 本機動作（例如「設為主設備」）：不分角色，永遠由本機處理，不需經過現任主。
  if mkdir -p "$LOCAL_ACTIONS_PENDING" "$LOCAL_ACTIONS_CLAIMED" "$LOCAL_ACTIONS_RECEIPTS" 2>>"$LOG"; then
    for intent in "$LOCAL_ACTIONS_PENDING"/*.json; do
      [ -f "$intent" ] || continue
      intent_name="$(basename "$intent")"
      claimed="$LOCAL_ACTIONS_CLAIMED/${intent_name}.$(date -u +%Y%m%dT%H%M%SZ).$$"
      mv "$intent" "$claimed" 2>/dev/null || continue

      completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      receipt_stage="$LOCAL_ACTIONS_RECEIPTS/.${intent_name}.$$.tmp"
      receipt="$LOCAL_ACTIONS_RECEIPTS/$intent_name"
      kind="$(plutil -extract kind raw "$claimed" 2>/dev/null || true)"
      action_target="$(plutil -extract target raw "$claimed" 2>/dev/null || true)"
      result="failure"
      message=""
      pairing_seed_out=""
      pairing_expires_out=""

      case "$kind" in
        set-primary)
          case "$action_target" in
            ""|.|..|*/*|*$'\n'*|*$'\r'*)
              message="轉移主權缺少或含有不安全的 target"
              ;;
            *)
              if command_output="$(bash "$SYNC" set-primary --name "$action_target" 2>&1)"; then
                result="success"
                message="${command_output:-主設備已設定為 ${action_target}}"
              else
                message="${command_output:-set-primary 失敗}"
              fi
              ;;
          esac
          ;;
        push-version)
          if command_output="$(bash "$SYNC" version-push 2>&1)"; then
            result="success"
            message="${command_output:-已回傳本機版本}"
          else
            message="${command_output:-version-push 失敗}"
          fi
          ;;
        create-pairing)
          if command_output="$(bash "$SYNC" pairing-create 2>&1)"; then
            result="success"
            message="${command_output:-配對代碼已產生}"
            pairing_seed_out="$(printf '%s\n' "$command_output" | sed -n 's/^PAIRING_SEED=//p' | tail -1)"
            pairing_expires_out="$(printf '%s\n' "$command_output" | sed -n 's/^PAIRING_EXPIRES_AT=//p' | tail -1)"
          else
            message="${command_output:-pairing-create 失敗}"
          fi
          ;;
        apply-os-image)
          image_script="${TATWO_OS_IMAGE_SCRIPT:-$HERE/tatwo-os-image.sh}"
          if [ "${TATWO_OS_IMAGE_CONSUMER:-0}" = "1" ]; then
            image_cmd=sync
          else
            image_cmd=publish
          fi
          if command_output="$(bash "$image_script" "$image_cmd" 2>&1)"; then
            result="success"
            message="${command_output:-os-image ${image_cmd}}"
          else
            message="${command_output:-os-image ${image_cmd} 失敗}"
          fi
          ;;
        apply-data-sync)
          data_script="${TATWO_DATA_SYNC_SCRIPT:-$HERE/tatwo-data-sync.sh}"
          if [ "${TATWO_DATA_SYNC_ROLE:-}" = "host" ]; then
            data_cmd=unify
          else
            data_cmd=submit
          fi
          if command_output="$(bash "$data_script" "$data_cmd" 2>&1)"; then
            result="success"
            message="${command_output:-data-sync ${data_cmd}}"
          else
            message="${command_output:-data-sync ${data_cmd} 失敗}"
          fi
          ;;
        apply-skillet-md)
          skillet_md_script="${TATWO_SKILLET_MD_SCRIPT:-$HERE/tatwo-skillet-md.sh}"
          if [ "${TATWO_DATA_SYNC_ROLE:-}" = "host" ]; then
            skillet_md_cmd=unify
          else
            skillet_md_cmd=submit
          fi
          if command_output="$(bash "$skillet_md_script" "$skillet_md_cmd" 2>&1)"; then
            result="success"
            message="${command_output:-skillet-md ${skillet_md_cmd}}"
          else
            message="${command_output:-skillet-md ${skillet_md_cmd} 失敗}"
          fi
          ;;
        apply-model-collab-presets)
          model_collab_script="${TATWO_MODEL_COLLAB_SCRIPT:-$HERE/tatwo-model-collab-presets.sh}"
          if [ ! -f "$model_collab_script" ]; then
            message="model-collab-presets 引擎不存在"
          else
            if [ "$current_role" = "primary" ] || [ "${TATWO_DATA_SYNC_ROLE:-}" = "host" ]; then
              model_collab_cmd=publish
            else
              model_collab_cmd=apply
            fi
            if command_output="$(
              TATWO_DEVICE_ROLE="${current_role:-$DEVICE_ROLE}" \
                bash "$model_collab_script" "$model_collab_cmd" 2>&1
            )"; then
              result="success"
              message="${command_output:-model-collab-presets ${model_collab_cmd}}"
            else
              message="${command_output:-model-collab-presets ${model_collab_cmd} 失敗}"
            fi
          fi
          ;;
        *)
          message="未知本機動作：${kind:-missing}"
          ;;
      esac

      receipt_write_ok=1
      if ! mv "$claimed" "$receipt_stage" 2>/dev/null; then receipt_write_ok=0; fi
      if [ "$receipt_write_ok" = "1" ] && ! plutil -insert result -string "$result" "$receipt_stage" 2>/dev/null; then receipt_write_ok=0; fi
      if [ "$receipt_write_ok" = "1" ] && ! plutil -insert completedAt -string "$completed_at" "$receipt_stage" 2>/dev/null; then receipt_write_ok=0; fi
      if [ "$receipt_write_ok" = "1" ] && ! plutil -insert message -string "$message" "$receipt_stage" 2>/dev/null; then receipt_write_ok=0; fi
      if [ "$receipt_write_ok" = "1" ] && [ -n "$pairing_seed_out" ]; then
        plutil -insert pairingSeed -string "$pairing_seed_out" "$receipt_stage" 2>/dev/null || receipt_write_ok=0
      fi
      if [ "$receipt_write_ok" = "1" ] && [ -n "$pairing_expires_out" ]; then
        plutil -insert pairingExpiresAt -string "$pairing_expires_out" "$receipt_stage" 2>/dev/null || receipt_write_ok=0
      fi

      if [ "$receipt_write_ok" = "1" ] && mv "$receipt_stage" "$receipt" 2>/dev/null; then
        hlog "local-action kind=${kind} result=${result}"
      else
        hlog "local-action kind=${kind} receipt 寫入失敗，保留 claim=${claimed}"
        [ -e "$receipt_stage" ] && mv "$receipt_stage" "${receipt_stage}.failed" 2>/dev/null || true
      fi
    done
  else
    hlog "本機動作目錄建立失敗，下一輪重試"
  fi

  if [ "$current_role" = "primary" ]; then
    if ! mkdir -p "$OUTBOX_PENDING" "$OUTBOX_CLAIMED" "$OUTBOX_RECEIPTS"; then
      hlog "primary outbox 目錄建立失敗，下一輪重試"
    else
      for intent in "$OUTBOX_PENDING"/*.json; do
        [ -f "$intent" ] || continue

        intent_name="$(basename "$intent")"
        claimed="$OUTBOX_CLAIMED/${intent_name}.$(date -u +%Y%m%dT%H%M%SZ).$$"
        if ! mv "$intent" "$claimed" 2>/dev/null; then
          continue
        fi

        completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        receipt_stage="$OUTBOX_RECEIPTS/.${intent_name}.$$.tmp"
        receipt="$OUTBOX_RECEIPTS/$intent_name"
        target="$(plutil -extract target raw "$claimed" 2>/dev/null || true)"
        action="$(plutil -extract action raw "$claimed" 2>/dev/null || true)"
        requested_at="$(plutil -extract requestedAt raw "$claimed" 2>/dev/null || true)"
        result="failure"
        phase="failed"
        request_id=""
        authority_epoch=""
        ledger_sequence=""
        authority_primary=""
        source_device_id=""
        target_device_id=""
        catalog_revision=""
        source_refresh_attempt_id=""
        message=""

        case "$target" in
          ""|.|..|*/*|*$'\n'*|*$'\r'*)
            message="intent 缺少或含有不安全的 target"
            ;;
          *)
            case "$action" in
              system-pull|db-pull|version-pull|data-sync)
                if [ "$action" = "version-pull" ]; then
                  image_script="${TATWO_OS_IMAGE_SCRIPT:-$HERE/tatwo-os-image.sh}"
                  bash "$image_script" publish >/dev/null 2>&1 || true
                fi
                if [ "$action" = "data-sync" ]; then
                  : # host asks the target to submit; do not publish an overwrite bundle
                fi
                if command_output="$(bash "$SYNC" sync-request --target "$target" --action "$action" 2>&1)"; then
                  source_refresh_attempt_id="$(
                    printf '%s\n' "$command_output" \
                      | sed -n 's/^SYNC_SOURCE_REFRESH_ATTEMPT_ID=//p' \
                      | tail -1
                  )"
                  request_id="$(printf '%s\n' "$command_output" | sed -n 's/^SYNC_REQUEST_ID=//p' | tail -1)"
                  authority_epoch="$(printf '%s\n' "$command_output" | sed -n 's/^SYNC_AUTHORITY_EPOCH=//p' | tail -1)"
                  ledger_sequence="$(printf '%s\n' "$command_output" | sed -n 's/^SYNC_LEDGER_SEQUENCE=//p' | tail -1)"
                  authority_primary="$(printf '%s\n' "$command_output" | sed -n 's/^SYNC_AUTHORITY_PRIMARY=//p' | tail -1)"
                  source_device_id="$(printf '%s\n' "$command_output" | sed -n 's/^SYNC_SOURCE_DEVICE_ID=//p' | tail -1)"
                  target_device_id="$(printf '%s\n' "$command_output" | sed -n 's/^SYNC_TARGET_DEVICE_ID=//p' | tail -1)"
                  catalog_revision="$(printf '%s\n' "$command_output" | sed -n 's/^SYNC_CATALOG_REVISION=//p' | tail -1)"
                  if [ -n "$request_id" ] && [ -n "$authority_epoch" ] \
                    && [ -n "$ledger_sequence" ] && [ "$ledger_sequence" -gt 0 ] 2>/dev/null \
                    && [ -n "$authority_primary" ] && [ -n "$source_device_id" ] \
                    && [ -n "$target_device_id" ] && [ -n "$catalog_revision" ]
                  then
                    result="pending"
                    phase="delivered"
                    message="${command_output:-sync-request delivered}"
                  else
                    result="failure"
                    phase="failed"
                    message="sync-request 未回傳 request id；拒絕宣稱同步成功"
                  fi
                else
                  source_refresh_attempt_id="$(
                    printf '%s\n' "$command_output" \
                      | sed -n 's/^SYNC_SOURCE_REFRESH_ATTEMPT_ID=//p' \
                      | tail -1
                  )"
                  message="${command_output:-sync-request failed}"
                fi
                ;;
              both)
                message="action=both 不支援收斂；請分開送出 system-pull 與 version-pull request"
                ;;
              *)
                message="intent action 無效：${action:-missing}"
                ;;
            esac
            ;;
        esac

        if mv "$claimed" "$receipt_stage" 2>/dev/null \
          && plutil -insert result -string "$result" "$receipt_stage" 2>/dev/null \
          && plutil -insert phase -string "$phase" "$receipt_stage" 2>/dev/null \
          && plutil -insert requestID -string "$request_id" "$receipt_stage" 2>/dev/null \
          && plutil -insert sourceRefreshAttemptID -string "$source_refresh_attempt_id" "$receipt_stage" 2>/dev/null \
          && plutil -insert authorityEpoch -integer "${authority_epoch:-0}" "$receipt_stage" 2>/dev/null \
          && plutil -insert ledgerSequence -integer "${ledger_sequence:-0}" "$receipt_stage" 2>/dev/null \
          && plutil -insert authorityPrimary -string "$authority_primary" "$receipt_stage" 2>/dev/null \
          && plutil -insert sourceDeviceID -string "$source_device_id" "$receipt_stage" 2>/dev/null \
          && plutil -insert targetDeviceID -string "$target_device_id" "$receipt_stage" 2>/dev/null \
          && plutil -insert catalogRevision -string "$catalog_revision" "$receipt_stage" 2>/dev/null \
          && plutil -insert completedAt -string "$completed_at" "$receipt_stage" 2>/dev/null \
          && plutil -insert message -string "$message" "$receipt_stage" 2>/dev/null \
          && mv "$receipt_stage" "$receipt"
        then
          hlog "outbox intent=${intent_name} result=${result} phase=${phase} request=${request_id:-missing} target=${target:-missing} action=${action:-missing}"
        elif write_fallback_receipt \
          "$([ -e "$receipt_stage" ] && printf '%s' "$receipt_stage" || printf '%s' "$claimed")" \
          "$receipt_stage" "$receipt" "$result" "$phase" "$request_id" "$completed_at" "$message" \
          "${authority_epoch:-0}" "${ledger_sequence:-0}" "$authority_primary" \
          "$source_device_id" "$target_device_id" "$catalog_revision" \
          "$target" "$action" "$requested_at" "$source_refresh_attempt_id"
        then
          hlog "outbox intent=${intent_name} fallback receipt result=${result} phase=${phase}"
        else
          hlog "outbox intent=${intent_name} receipt 寫入失敗，保留 claim=${claimed}"
          [ -e "$receipt_stage" ] && mv "$receipt_stage" "${receipt_stage}.failed" 2>/dev/null || true
        fi
      done

      # Request 發布只代表 delivered。只有目標設備寫入 digest 驗證 ACK 後，
      # 才以該 ACK 原子取代 outbox receipt，讓 App 顯示 verified/converged。
      channel_acks="$CHANNEL_DIR/acks"
      for receipt in "$OUTBOX_RECEIPTS"/*.json; do
        [ -f "$receipt" ] || continue
        receipt_phase="$(plutil -extract phase raw "$receipt" 2>/dev/null || true)"
        case "$receipt_phase" in
          delivered|accepted|transferring|merging|validating|activating|verified) ;;
          *) continue;;
        esac
        receipt_request_id="$(plutil -extract requestID raw "$receipt" 2>/dev/null || true)"
        receipt_target="$(plutil -extract target raw "$receipt" 2>/dev/null || true)"
        receipt_action="$(plutil -extract action raw "$receipt" 2>/dev/null || true)"
        receipt_authority_epoch="$(plutil -extract authorityEpoch raw "$receipt" 2>/dev/null || true)"
        receipt_ledger_sequence="$(plutil -extract ledgerSequence raw "$receipt" 2>/dev/null || true)"
        receipt_authority_primary="$(plutil -extract authorityPrimary raw "$receipt" 2>/dev/null || true)"
        receipt_source_device_id="$(plutil -extract sourceDeviceID raw "$receipt" 2>/dev/null || true)"
        receipt_target_device_id="$(plutil -extract targetDeviceID raw "$receipt" 2>/dev/null || true)"
        receipt_catalog_revision="$(plutil -extract catalogRevision raw "$receipt" 2>/dev/null || true)"
        [ -n "$receipt_request_id" ] || continue
        case "$receipt_request_id" in
          *[!A-Za-z0-9._:-]*)
            hlog "outbox receipt 含不安全 request id，拒絕讀 ACK：${receipt_request_id}"
            continue
            ;;
        esac
        ack="$channel_acks/$receipt_request_id.json"
        [ -f "$ack" ] || continue
        ack_request_id="$(plutil -extract requestID raw "$ack" 2>/dev/null || true)"
        ack_phase="$(plutil -extract phase raw "$ack" 2>/dev/null || true)"
        ack_target="$(plutil -extract target raw "$ack" 2>/dev/null || true)"
        ack_action="$(plutil -extract action raw "$ack" 2>/dev/null || true)"
        ack_authority_epoch="$(plutil -extract authorityEpoch raw "$ack" 2>/dev/null || true)"
        ack_ledger_sequence="$(plutil -extract ledgerSequence raw "$ack" 2>/dev/null || true)"
        ack_authority_primary="$(plutil -extract authorityPrimary raw "$ack" 2>/dev/null || true)"
        ack_source_device_id="$(plutil -extract sourceDeviceID raw "$ack" 2>/dev/null || true)"
        ack_target_device_id="$(plutil -extract targetDeviceID raw "$ack" 2>/dev/null || true)"
        ack_catalog_revision="$(plutil -extract catalogRevision raw "$ack" 2>/dev/null || true)"
        ack_digest_algorithm="$(plutil -extract digestAlgorithm raw "$ack" 2>/dev/null || true)"
        ack_source_digest="$(plutil -extract sourceDigest raw "$ack" 2>/dev/null || true)"
        ack_applied_digest="$(plutil -extract appliedDigest raw "$ack" 2>/dev/null || true)"
        ack_attestation_kind="$(plutil -extract attestationKind raw "$ack" 2>/dev/null || true)"
        ack_attestation_path="$(plutil -extract targetAttestationPath raw "$ack" 2>/dev/null || true)"
        ack_attestation_digest="$(plutil -extract targetAttestationDigest raw "$ack" 2>/dev/null || true)"
        ack_consumer_readback_kind="$(plutil -extract consumerReadbackKind raw "$ack" 2>/dev/null || true)"
        ack_consumer_readback_path="$(plutil -extract consumerReadbackPath raw "$ack" 2>/dev/null || true)"
        ack_consumer_readback_digest="$(plutil -extract consumerReadbackDigest raw "$ack" 2>/dev/null || true)"
        ack_consumer_readback_count="$(plutil -extract consumerReadbackCount raw "$ack" 2>/dev/null || true)"
        ack_signature_purpose="$(plutil -extract signaturePurpose raw "$ack" 2>/dev/null || true)"
        ack_signature_path="$(plutil -extract signaturePath raw "$ack" 2>/dev/null || true)"
        ack_attestation_signature_path="$(plutil -extract targetAttestationSignaturePath raw "$ack" 2>/dev/null || true)"
        [ "$ack_request_id" = "$receipt_request_id" ] || {
          hlog "ACK request id 不符，拒絕更新：expected=${receipt_request_id} actual=${ack_request_id:-missing}"
          continue
        }
        [ "$ack_target" = "$receipt_target" ] && [ "$ack_action" = "$receipt_action" ] || {
          hlog "ACK target/action 不符，拒絕更新：request=${receipt_request_id}"
          continue
        }
        [ "$ack_authority_epoch" = "$receipt_authority_epoch" ] \
          && [ "$ack_ledger_sequence" = "$receipt_ledger_sequence" ] \
          && [ "$ack_authority_primary" = "$receipt_authority_primary" ] || {
          hlog "ACK authority epoch/sequence/primary 不符，拒絕更新：request=${receipt_request_id}"
          continue
        }
        case "$ack_ledger_sequence" in
          ""|0|*[!0-9]*)
            hlog "ACK ledger sequence 不合法，拒絕更新：request=${receipt_request_id}"
            continue
            ;;
        esac
        [ "$ack_source_device_id" = "$receipt_source_device_id" ] \
          && [ "$ack_target_device_id" = "$receipt_target_device_id" ] || {
          hlog "ACK source/target device identity 不符，拒絕更新：request=${receipt_request_id}"
          continue
        }
        expected_ack_signature_path="signatures/acks/$receipt_request_id.json"
        [ "$ack_signature_purpose" = "sync-ack" ] \
          && [ "$ack_signature_path" = "$expected_ack_signature_path" ] || {
          hlog "ACK 缺少固定 Ed25519 signature binding：request=${receipt_request_id}"
          continue
        }
        ack_signature="$CHANNEL_DIR/$ack_signature_path"
        if ! verify_channel_signature \
          "$receipt_target" "$receipt_target_device_id" "sync-ack" \
          "$ack" "$ack_signature"
        then
          hlog "ACK signature 無效、target 未 pin、key 已撤銷或 generation 不符：request=${receipt_request_id}"
          continue
        fi
        [ "$ack_catalog_revision" = "$receipt_catalog_revision" ] || {
          hlog "ACK catalog revision 不符，拒絕更新：request=${receipt_request_id}"
          continue
        }
        live_role_output=""
        if ! live_role_output="$(bash "$SYNC" role-status 2>>"$LOG")"; then
          hlog "ACK 接納前 role-status 失敗，fail-closed：request=${receipt_request_id}"
          continue
        fi
        live_role="$(printf '%s\n' "$live_role_output" | sed -n 's/.* role=\([^ ]*\).*/\1/p' | tail -1)"
        live_primary="$(printf '%s\n' "$live_role_output" | sed -n 's/.* primary=\([^ ]*\).*/\1/p' | tail -1)"
        live_epoch="$(printf '%s\n' "$live_role_output" | sed -n 's/.* epoch=\([0-9][0-9]*\).*/\1/p' | tail -1)"
        [ "$live_role" = "primary" ] && [ "$live_primary" = "$receipt_authority_primary" ] \
          && [ "$live_epoch" = "$receipt_authority_epoch" ] || {
          hlog "ACK 接納前主權已切換，拒絕更新：request=${receipt_request_id}"
          continue
        }

        case "$receipt_target" in
          ""|.|..|*/*|*[!A-Za-z0-9._-]*)
            hlog "receipt target 不安全，拒絕解析 request manifest：request=${receipt_request_id}"
            continue
            ;;
        esac
        request_file="$CHANNEL_DIR/requests/$receipt_target/$receipt_request_id.json"
        [ -f "$request_file" ] || {
          hlog "ACK 缺少原始 request，無法驗證 binding：request=${receipt_request_id}"
          continue
        }
        request_bound=1
        [ "$(plutil -extract requestID raw "$request_file" 2>/dev/null || true)" = "$receipt_request_id" ] \
          || request_bound=0
        [ "$(plutil -extract target raw "$request_file" 2>/dev/null || true)" = "$receipt_target" ] \
          || request_bound=0
        [ "$(plutil -extract action raw "$request_file" 2>/dev/null || true)" = "$receipt_action" ] \
          || request_bound=0
        [ "$(plutil -extract authorityEpoch raw "$request_file" 2>/dev/null || true)" = "$receipt_authority_epoch" ] \
          || request_bound=0
        [ "$(plutil -extract ledgerSequence raw "$request_file" 2>/dev/null || true)" = "$receipt_ledger_sequence" ] \
          || request_bound=0
        [ "$(plutil -extract authorityPrimary raw "$request_file" 2>/dev/null || true)" = "$receipt_authority_primary" ] \
          || request_bound=0
        [ "$(plutil -extract sourceDeviceID raw "$request_file" 2>/dev/null || true)" = "$receipt_source_device_id" ] \
          || request_bound=0
        [ "$(plutil -extract targetDeviceID raw "$request_file" 2>/dev/null || true)" = "$receipt_target_device_id" ] \
          || request_bound=0
        [ "$(plutil -extract catalogRevision raw "$request_file" 2>/dev/null || true)" = "$receipt_catalog_revision" ] \
          || request_bound=0
        [ "$request_bound" = "1" ] || {
          hlog "ACK 對應的原始 request binding 已漂移，拒絕更新：request=${receipt_request_id}"
          continue
        }
        request_source_digest="$(plutil -extract sourceDigest raw "$request_file" 2>/dev/null || true)"
        case "$ack_phase" in
          accepted|transferring|merging|validating|activating)
            case "$receipt_action" in
              system-pull)
                [ "$ack_digest_algorithm" = "sha256" ] \
                  && [ "$ack_source_digest" = "$request_source_digest" ] \
                  && { [ -z "$ack_applied_digest" ] \
                    || [ "$ack_applied_digest" = "$request_source_digest" ]; } || {
                  hlog "system-pull non-terminal ACK digest binding 不符：request=${receipt_request_id}"
                  continue
                }
                ;;
              version-pull)
                [ "$ack_digest_algorithm" = "git-object-id" ] \
                  && [ "$ack_source_digest" = "$request_source_digest" ] \
                  && { [ -z "$ack_applied_digest" ] \
                    || [ "$ack_applied_digest" = "$request_source_digest" ]; } || {
                  hlog "${receipt_action} non-terminal ACK digest binding 不符：request=${receipt_request_id}"
                  continue
                }
                ;;
            esac
            ;;
        esac
        if ! validate_sync_progress_transition \
          "$ack" "$receipt" "$ack_phase" "$receipt_phase"
        then
          hlog "ACK phase/progress 倒退、schema 不合法或 totals 漂移：request=${receipt_request_id}"
          continue
        fi

        case "$ack_phase" in
          verified|converged)
            [ -n "$ack_source_digest" ] \
              && [ "$ack_source_digest" = "$ack_applied_digest" ] || {
              hlog "ACK 宣稱 ${ack_phase} 但缺少一致 digest：request=${receipt_request_id}"
              continue
            }
            case "$ack_digest_algorithm" in
              sha256)
                case "$ack_source_digest" in ""|*[!0-9a-f]*) valid_digest=0;; *) valid_digest=1;; esac
                [ "$valid_digest" = "1" ] && [ "${#ack_source_digest}" -eq 64 ] || {
                  hlog "ACK SHA-256 格式不合法：request=${receipt_request_id}"
                  continue
                }
                ;;
              git-object-id)
                case "$ack_source_digest" in ""|*[!0-9a-f]*) valid_digest=0;; *) valid_digest=1;; esac
                case "${#ack_source_digest}" in 40|64) ;; *) valid_digest=0;; esac
                [ "$valid_digest" = "1" ] || {
                  hlog "ACK git object id 格式不合法：request=${receipt_request_id}"
                  continue
                }
                ;;
              *)
                hlog "ACK 缺少受支援 digestAlgorithm：request=${receipt_request_id}"
                continue
                ;;
            esac
            required_count="$(plutil -extract requiredItemIDs raw "$ack" 2>/dev/null || true)"
            item_count="$(plutil -extract items raw "$ack" 2>/dev/null || true)"
            case "$required_count:$item_count" in
              *[!0-9:]*|:*|*:)
                hlog "ACK required/items 結構不合法：request=${receipt_request_id}"
                continue
                ;;
            esac
            [ "$required_count" -gt 0 ] && [ "$item_count" = "$required_count" ] || {
              hlog "ACK required/items 數量不一致或含額外 item：request=${receipt_request_id}"
              continue
            }
            manifest=""
            case "$receipt_action" in
              system-pull)
                catalog_required_count="$(catalog_system_pull_count)"
                case "$catalog_required_count" in ""|0|*[!0-9]*)
                  hlog "system-pull catalog active set 無法讀取：request=${receipt_request_id}"
                  continue
                  ;;
                esac
                [ "$ack_digest_algorithm" = "sha256" ] \
                  && [ "$required_count" = "$catalog_required_count" ] || {
                  hlog "system-pull ACK required items/digestAlgorithm 不合法：request=${receipt_request_id}"
                  continue
                }
                actual_system_ids=""
                expected_system_ids=""
                required_index=0
                while [ "$required_index" -lt "$required_count" ]; do
                  required_id="$(plutil -extract "requiredItemIDs.$required_index" raw "$ack" 2>/dev/null || true)"
                  expected_required_id="$(catalog_system_pull_id "$required_index")"
                  actual_system_ids="${actual_system_ids}${actual_system_ids:+ }$required_id"
                  expected_system_ids="${expected_system_ids}${expected_system_ids:+ }$expected_required_id"
                  required_index=$((required_index + 1))
                done
                [ "$actual_system_ids" = "$expected_system_ids" ] || {
                  hlog "system-pull ACK required item set 不完整：request=${receipt_request_id}"
                  continue
                }
                request_manifest_digest="$(plutil -extract manifestDigest raw "$request_file" 2>/dev/null || true)"
                request_manifest_path="$(plutil -extract manifestPath raw "$request_file" 2>/dev/null || true)"
                [ "$request_manifest_path" = "payloads/$receipt_request_id/manifest.json" ] \
                  || {
                  hlog "system-pull request manifest path 不合法：request=${receipt_request_id}"
                  continue
                }
                manifest="$CHANNEL_DIR/$request_manifest_path"
                [ -f "$manifest" ] \
                  && [ -n "$request_manifest_digest" ] \
                  && [ "$request_manifest_digest" = "$request_source_digest" ] \
                  && [ "$ack_source_digest" = "$request_manifest_digest" ] \
                  && [ "$(sha256_file "$manifest")" = "$request_manifest_digest" ] || {
                  hlog "system-pull ACK aggregate digest 與 request manifest 不符：request=${receipt_request_id}"
                  continue
                }
                [ "$(plutil -extract items raw "$manifest" 2>/dev/null || true)" = "$required_count" ] || {
                  hlog "system-pull manifest item 數與 required set 不符：request=${receipt_request_id}"
                  continue
                }
                [ "$(plutil -extract requestID raw "$manifest" 2>/dev/null || true)" = "$receipt_request_id" ] \
                  && [ "$(plutil -extract sourceDeviceID raw "$manifest" 2>/dev/null || true)" = "$receipt_source_device_id" ] \
                  && [ "$(plutil -extract targetDeviceID raw "$manifest" 2>/dev/null || true)" = "$receipt_target_device_id" ] \
                  && [ "$(plutil -extract authorityPrimary raw "$manifest" 2>/dev/null || true)" = "$receipt_authority_primary" ] \
                  && [ "$(plutil -extract authorityEpoch raw "$manifest" 2>/dev/null || true)" = "$receipt_authority_epoch" ] \
                  && [ "$(plutil -extract ledgerSequence raw "$manifest" 2>/dev/null || true)" = "$receipt_ledger_sequence" ] \
                  && [ "$(plutil -extract catalogRevision raw "$manifest" 2>/dev/null || true)" = "$receipt_catalog_revision" ] || {
                  hlog "system-pull manifest authority/device/catalog binding 不符：request=${receipt_request_id}"
                  continue
                }
                expected_consumer_readback_path="consumer-readbacks/$receipt_target/$receipt_request_id.json"
                [ "$ack_consumer_readback_kind" = "actual-consumer-readback-set" ] \
                  && [ "$ack_consumer_readback_path" = "$expected_consumer_readback_path" ] \
                  && is_sha256_digest "$ack_consumer_readback_digest" \
                  && validate_nonnegative_integer "$ack_consumer_readback_count" \
                  && [ "$ack_consumer_readback_count" -ge 3 ] || {
                  hlog "system-pull ACK 缺少 actual consumer readback binding：request=${receipt_request_id}"
                  continue
                }
                consumer_readback="$CHANNEL_DIR/$ack_consumer_readback_path"
                [ -f "$consumer_readback" ] \
                  && [ "$(sha256_file "$consumer_readback")" = "$ack_consumer_readback_digest" ] \
                  && [ "$(plutil -extract readbackCount raw "$consumer_readback" 2>/dev/null || true)" = "$ack_consumer_readback_count" ] \
                  && validate_consumer_readback_set \
                    "$consumer_readback" "$receipt_request_id" "$receipt_target" \
                    "$receipt_source_device_id" "$receipt_target_device_id" \
                    "$receipt_authority_primary" "$receipt_authority_epoch" \
                    "$receipt_ledger_sequence" "$receipt_catalog_revision" \
                    "$request_manifest_digest" || {
                  hlog "system-pull actual consumer readback artifact/binding 不符：request=${receipt_request_id}"
                  continue
                }
                expected_attestation_path="attestations/$receipt_target/$receipt_request_id.json"
                expected_attestation_signature_path="signatures/attestations/$receipt_target/$receipt_request_id.json"
                [ "$ack_attestation_kind" = "target-local-consumer-readback-attested" ] \
                  && [ "$ack_attestation_path" = "$expected_attestation_path" ] \
                  && [ "$ack_attestation_signature_path" = "$expected_attestation_signature_path" ] \
                  && is_sha256_digest "$ack_attestation_digest" || {
                  hlog "system-pull ACK 只有 channel claim、缺少 consumer-bound target attestation：request=${receipt_request_id}"
                  continue
                }
                attestation="$CHANNEL_DIR/$ack_attestation_path"
                attestation_signature="$CHANNEL_DIR/$ack_attestation_signature_path"
                [ -f "$attestation" ] \
                  && [ "$(sha256_file "$attestation")" = "$ack_attestation_digest" ] \
                  && [ "$(plutil -extract schema raw "$attestation" 2>/dev/null || true)" = "TatwoTargetLocalSystemAttestationV2" ] \
                  && [ "$(plutil -extract kind raw "$attestation" 2>/dev/null || true)" = "$ack_attestation_kind" ] \
                  && [ "$(plutil -extract requestID raw "$attestation" 2>/dev/null || true)" = "$receipt_request_id" ] \
                  && [ "$(plutil -extract target raw "$attestation" 2>/dev/null || true)" = "$receipt_target" ] \
                  && [ "$(plutil -extract authorityEpoch raw "$attestation" 2>/dev/null || true)" = "$receipt_authority_epoch" ] \
                  && [ "$(plutil -extract ledgerSequence raw "$attestation" 2>/dev/null || true)" = "$receipt_ledger_sequence" ] \
                  && [ "$(plutil -extract authorityPrimary raw "$attestation" 2>/dev/null || true)" = "$receipt_authority_primary" ] \
                  && [ "$(plutil -extract sourceDeviceID raw "$attestation" 2>/dev/null || true)" = "$receipt_source_device_id" ] \
                  && [ "$(plutil -extract targetDeviceID raw "$attestation" 2>/dev/null || true)" = "$receipt_target_device_id" ] \
                  && [ "$(plutil -extract catalogRevision raw "$attestation" 2>/dev/null || true)" = "$receipt_catalog_revision" ] \
                  && [ "$(plutil -extract transactionPhase raw "$attestation" 2>/dev/null || true)" = "committed" ] \
                  && [ "$(plutil -extract manifestDigest raw "$attestation" 2>/dev/null || true)" = "$request_manifest_digest" ] \
                  && is_sha256_digest "$(plutil -extract transactionJournalDigest raw "$attestation" 2>/dev/null || true)" \
                  && is_sha256_digest "$(plutil -extract skilletActiveSetReceiptDigest raw "$attestation" 2>/dev/null || true)" \
                  && [ "$(plutil -extract consumerReadbackKind raw "$attestation" 2>/dev/null || true)" = "$ack_consumer_readback_kind" ] \
                  && [ "$(plutil -extract consumerReadbackPath raw "$attestation" 2>/dev/null || true)" = "$ack_consumer_readback_path" ] \
                  && [ "$(plutil -extract consumerReadbackDigest raw "$attestation" 2>/dev/null || true)" = "$ack_consumer_readback_digest" ] \
                  && [ "$(plutil -extract consumerReadbackCount raw "$attestation" 2>/dev/null || true)" = "$ack_consumer_readback_count" ] \
                  && [ "$(plutil -extract signaturePurpose raw "$attestation" 2>/dev/null || true)" = "target-attestation" ] \
                  && [ "$(plutil -extract signaturePath raw "$attestation" 2>/dev/null || true)" = "$expected_attestation_signature_path" ] \
                  && verify_channel_signature \
                    "$receipt_target" "$receipt_target_device_id" \
                    "target-attestation" "$attestation" "$attestation_signature" || {
                  hlog "system-pull consumer-bound target attestation binding 或 digest 不符：request=${receipt_request_id}"
                  continue
                }
                ;;
              version-pull)
                [ "$ack_digest_algorithm" = "git-object-id" ] \
                  && [ "$required_count" = "1" ] \
                  && [ "$(plutil -extract requiredItemIDs.0 raw "$ack" 2>/dev/null || true)" = "app.version" ] \
                  && [ "$ack_source_digest" = "$request_source_digest" ] || {
                  hlog "version-pull ACK required item set 不合法：request=${receipt_request_id}"
                  continue
                }
                ;;
              *)
                hlog "${receipt_action} 不具備可宣稱 verified/converged 的完整 digest contract"
                continue
                ;;
            esac
            ack_items_valid=1
            required_index=0
            while [ "$required_index" -lt "$required_count" ]; do
              required_id="$(plutil -extract "requiredItemIDs.$required_index" raw "$ack" 2>/dev/null || true)"
              item_id="$(plutil -extract "items.$required_index.id" raw "$ack" 2>/dev/null || true)"
              item_phase="$(plutil -extract "items.$required_index.phase" raw "$ack" 2>/dev/null || true)"
              item_algorithm="$(plutil -extract "items.$required_index.digestAlgorithm" raw "$ack" 2>/dev/null || true)"
              item_source="$(plutil -extract "items.$required_index.sourceDigest" raw "$ack" 2>/dev/null || true)"
              item_applied="$(plutil -extract "items.$required_index.appliedDigest" raw "$ack" 2>/dev/null || true)"
              [ "$item_id" = "$required_id" ] \
                && [ "$item_phase" = "verified" ] \
                && [ "$item_source" = "$item_applied" ] \
                && [ "$item_algorithm" = "$ack_digest_algorithm" ] \
                || ack_items_valid=0
              case "$item_algorithm" in
                sha256)
                  case "$item_source" in ""|*[!0-9a-f]*) ack_items_valid=0;; esac
                  [ "${#item_source}" -eq 64 ] || ack_items_valid=0
                  ;;
                git-object-id)
                  case "$item_source" in ""|*[!0-9a-f]*) ack_items_valid=0;; esac
                  case "${#item_source}" in 40|64) ;; *) ack_items_valid=0;; esac
                  ;;
                *) ack_items_valid=0;;
              esac
              if [ "$receipt_action" = "system-pull" ]; then
                manifest_item_id="$(plutil -extract "items.$required_index.id" raw "$manifest" 2>/dev/null || true)"
                manifest_item_digest="$(plutil -extract "items.$required_index.sourceDigest" raw "$manifest" 2>/dev/null || true)"
                [ "$manifest_item_id" = "$required_id" ] \
                  && [ "$item_source" = "$manifest_item_digest" ] \
                  || ack_items_valid=0
                if [ "$required_id" = "skills.skillet" ]; then
                  validate_skillet_ack_item \
                    "$ack" "$manifest" "$required_index" "$receipt_request_id" \
                    "$receipt_source_device_id" "$receipt_target_device_id" \
                    "$receipt_authority_epoch" "$receipt_ledger_sequence" \
                    "$receipt_catalog_revision" \
                    || ack_items_valid=0
                fi
              elif [ "$receipt_action" = "version-pull" ]; then
                [ "$item_source" = "$request_source_digest" ] || ack_items_valid=0
              fi
              required_index=$((required_index + 1))
            done
            [ "$ack_items_valid" = "1" ] || {
              hlog "ACK required item 次序、唯一性或逐項 digest 與 request manifest 不符：request=${receipt_request_id}"
              continue
            }
            ;;
          accepted|transferring|merging|validating|activating)
            # Non-terminal target progress is useful UI evidence but never counts
            # as convergence. Binding/epoch/sequence checks above still apply.
            ;;
          failed|diverged) ;;
          *)
            hlog "ACK phase 不可作為設備回執：${ack_phase:-missing}"
            continue
            ;;
        esac
        ack_stage="${receipt}.ack.$$.tmp"
        if cp "$ack" "$ack_stage" 2>/dev/null && mv "$ack_stage" "$receipt" 2>/dev/null; then
          hlog "outbox request=${receipt_request_id} 已更新為 target ACK phase=${ack_phase}"
        else
          hlog "outbox request=${receipt_request_id} ACK 更新失敗，下輪重試"
          [ -e "$ack_stage" ] && mv "$ack_stage" "${ack_stage}.failed" 2>/dev/null || true
        fi
      done
    fi
  elif [ "$current_role" = "secondary" ]; then
    # 1) 收主設備發起的同步指令
    if ! bash "$SYNC" sync-poll --device "$DEVICE_NAME" >>"$LOG" 2>&1; then
      hlog "sync-poll 這輪失敗（連不到主設備/衝突？），下輪重試"
    fi

    # 2) 保底：每 ~10 分鐘查一次 release 有無新版（沒收到指令也能追）
    if [ "$AUTO_VERSION" = "1" ]; then
      now="$(date +%s)"
      if [ $(( now - last_version_check )) -ge 600 ]; then
        last_version_check="$now"
        if ! bash "$SYNC" version-pull --no-install >>"$LOG" 2>&1; then
          hlog "保底 version-pull 這輪無動作或失敗（多為已最新/分岔）"
        fi
      fi
    fi
  else
    hlog "角色=${current_role}，本輪不處理 primary outbox、不執行 secondary sync；fail-closed"
  fi

  if ! bash "$SYNC" skillet-source-sync both >>"$LOG" 2>&1; then
    hlog "skillet-source-sync 這輪失敗，下輪重試"
  fi

  if ! bash "$SYNC" inventory-sync >>"$LOG" 2>&1; then
    hlog "inventory-sync 這輪失敗，下輪重試"
  fi

  if [ -f "${TATWO_MODEL_COLLAB_SCRIPT:-$HERE/tatwo-model-collab-presets.sh}" ]; then
    if ! TATWO_DEVICE_ROLE="${current_role:-$DEVICE_ROLE}" \
      bash "${TATWO_MODEL_COLLAB_SCRIPT:-$HERE/tatwo-model-collab-presets.sh}" cycle >>"$LOG" 2>&1
    then
      hlog "model-collab-presets 這輪失敗，下輪重試"
    fi
  fi

  [ "$RUN_ONCE" = "1" ] && break
  sleep "$INTERVAL"
done
