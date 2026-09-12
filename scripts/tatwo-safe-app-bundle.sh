#!/usr/bin/env bash

# Shared safe activation primitive for the release and debug installers.
# The caller must build a complete staged bundle first. This helper never
# permanently deletes an active or staged bundle.

tatwo_real_path() {
  /usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

tatwo_existing_ancestor() {
  /usr/bin/python3 -c '
import os,sys
p=os.path.abspath(sys.argv[1])
while not os.path.exists(p):
    parent=os.path.dirname(p)
    if parent == p: break
    p=parent
print(os.path.realpath(p))
' "$1"
}

tatwo_same_filesystem() {
  [[ "$(stat -f %d "$(tatwo_existing_ancestor "$1")")" == \
     "$(stat -f %d "$(tatwo_existing_ancestor "$2")")" ]]
}

tatwo_refresh_launchservices() {
  local active_bundle="$1"
  local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

  if [[ -x "$lsregister" && -d "$active_bundle" ]]; then
    "$lsregister" -f "$active_bundle" >/dev/null 2>&1 || true
    "$lsregister" -gc >/dev/null 2>&1 || true
  fi
}

tatwo_write_install_receipt() {
  local receipt_path="$1"
  local outcome="$2"
  local active_bundle="$3"
  local staged_bundle="$4"
  local archived_bundle="$5"
  local rollback_performed="$6"
  local detail="$7"

  mkdir -p "$(dirname "$receipt_path")"
  TATWO_RECEIPT_PATH="$receipt_path" \
  TATWO_RECEIPT_OUTCOME="$outcome" \
  TATWO_RECEIPT_ACTIVE="$active_bundle" \
  TATWO_RECEIPT_STAGED="$staged_bundle" \
  TATWO_RECEIPT_ARCHIVED="$archived_bundle" \
  TATWO_RECEIPT_ROLLBACK="$rollback_performed" \
  TATWO_RECEIPT_DETAIL="$detail" \
  /usr/bin/python3 <<'PY'
import datetime
import json
import os

receipt = {
    "schema": "TatwoSafeAppInstallReceiptV1",
    "observedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "outcome": os.environ["TATWO_RECEIPT_OUTCOME"],
    "activeBundle": os.environ["TATWO_RECEIPT_ACTIVE"],
    "stagedBundle": os.environ["TATWO_RECEIPT_STAGED"],
    "archivedBundle": os.environ["TATWO_RECEIPT_ARCHIVED"] or None,
    "rollbackPerformed": os.environ["TATWO_RECEIPT_ROLLBACK"] == "true",
    "mutationScope": "bundle_only",
    "userDataWriteCount": 0,
    "domainLedgerWriteCount": 0,
    "detail": os.environ["TATWO_RECEIPT_DETAIL"],
}
with open(os.environ["TATWO_RECEIPT_PATH"], "x", encoding="utf-8") as output:
    json.dump(receipt, output, ensure_ascii=False, indent=2)
    output.write("\n")
PY
}

tatwo_verify_staged_app_bundle() {
  local staged_bundle="$1"
  local product_name="$2"
  local resource_bundle_glob="$3"

  [[ -d "$staged_bundle" ]]
  [[ -x "$staged_bundle/Contents/MacOS/$product_name" ]]
  [[ -f "$staged_bundle/Contents/Info.plist" ]]
  plutil -lint "$staged_bundle/Contents/Info.plist" >/dev/null
  find "$staged_bundle/Contents/Resources" \
    -maxdepth 1 -type d -name "$resource_bundle_glob" -print -quit \
    | grep -q .
  if otool -L "$staged_bundle/Contents/MacOS/$product_name" \
    | grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle'; then
    [[ -x "$staged_bundle/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" ]]
    otool -l "$staged_bundle/Contents/MacOS/$product_name" \
      | awk '
          /LC_RPATH/ {
            getline
            getline
            sub(/^[[:space:]]*path /, "")
            sub(/ \(offset [0-9]+\)$/, "")
            print
          }
        ' \
      | grep -Fxq '@loader_path/../Frameworks'
    while IFS= read -r rpath; do
      case "$rpath" in
        /usr/lib/swift|@loader_path|@loader_path/../Frameworks|@executable_path/../Frameworks)
          ;;
        *)
          printf 'error: staged app contains unsafe runtime search path: %s\n' \
            "$rpath" >&2
          return 1
          ;;
      esac
    done < <(
      otool -l "$staged_bundle/Contents/MacOS/$product_name" \
        | awk '
            /LC_RPATH/ {
              getline
              getline
              sub(/^[[:space:]]*path /, "")
              sub(/ \(offset [0-9]+\)$/, "")
              print
            }
          '
    )
  fi
  codesign --verify --deep --strict "$staged_bundle"
}

tatwo_activate_staged_app_bundle() {
  local staged_bundle="$1"
  local active_bundle="$2"
  local state_dir="$3"
  local product_name="$4"
  local resource_bundle_glob="$5"
  local app_dir
  local stamp
  local archive_root
  local archived_bundle=""
  local failed_bundle
  local receipt_dir
  local receipt_path

  app_dir="$(dirname "$active_bundle")"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  archive_root="${TATWO_ULTRAWORK_ARCHIVE_ROOT:-$state_dir/bundle-archives.noindex}"
  local real_app_dir real_archive_root real_stage_root real_state_dir
  real_app_dir="$(tatwo_real_path "$app_dir")"
  real_archive_root="$(tatwo_real_path "$archive_root")"
  real_stage_root="$(tatwo_real_path "$(dirname "$staged_bundle")")"
  real_state_dir="$(tatwo_real_path "$state_dir")"
  case "$real_archive_root/" in
    "$real_app_dir/"*)
      printf 'error: bundle archives must remain outside the active App directory: %s\n' \
        "$archive_root" >&2
      return 1
      ;;
  esac
  case "$real_stage_root/" in
    "$real_app_dir/"*)
      printf 'error: staged bundle must remain outside the active App directory: %s\n' \
        "$staged_bundle" >&2
      return 1
      ;;
  esac
  case "$real_state_dir/" in
    "$real_app_dir/"*)
      printf 'error: deployment state must remain outside the active App directory: %s\n' \
        "$state_dir" >&2
      return 1
      ;;
  esac
  if ! tatwo_same_filesystem "$staged_bundle" "$active_bundle" \
    || ! tatwo_same_filesystem "$archive_root" "$active_bundle"; then
    printf 'error: staged active and archive bundles must share one filesystem\n' >&2
    return 1
  fi
  failed_bundle="$archive_root/failed-$stamp.bundle-archive"
  receipt_dir="$state_dir/deployment-receipts"
  receipt_path="$receipt_dir/app-install-$stamp.json"

  mkdir -p "$archive_root" "$receipt_dir"
  : > "$archive_root/.metadata_never_index"
  chflags hidden "$archive_root" 2>/dev/null || true

  if ! tatwo_verify_staged_app_bundle \
    "$staged_bundle" "$product_name" "$resource_bundle_glob"; then
    tatwo_write_install_receipt \
      "$receipt_path" "failed" "$active_bundle" "$staged_bundle" "" "false" \
      "staged bundle verification failed before active bundle mutation"
    printf 'error: staged bundle verification failed; receipt=%s\n' "$receipt_path" >&2
    return 1
  fi

  if [[ -e "$active_bundle" ]]; then
    archived_bundle="$archive_root/$(basename "$active_bundle" .app)-previous-$stamp.bundle-archive"
    if [[ -e "$archived_bundle" ]]; then
      printf 'error: archive destination already exists: %s\n' "$archived_bundle" >&2
      return 1
    fi
    mv "$active_bundle" "$archived_bundle"
  fi

  if ! mv "$staged_bundle" "$active_bundle"; then
    local rollback_performed="false"
    local rollback_detail="atomic activation failed; no previous bundle was available to restore"
    if [[ -n "$archived_bundle" && -e "$archived_bundle" && ! -e "$active_bundle" ]]; then
      if mv "$archived_bundle" "$active_bundle" && [[ -e "$active_bundle" ]]; then
        rollback_performed="true"
        rollback_detail="atomic activation failed; previous bundle restored"
      else
        rollback_detail="atomic activation failed; previous bundle restoration failed"
      fi
    fi
    tatwo_write_install_receipt \
      "$receipt_path" "failed" "$active_bundle" "$staged_bundle" \
      "$archived_bundle" "$rollback_performed" "$rollback_detail"
    printf 'error: bundle activation failed; receipt=%s\n' "$receipt_path" >&2
    return 1
  fi

  if ! tatwo_verify_staged_app_bundle \
    "$active_bundle" "$product_name" "$resource_bundle_glob"; then
    local rollback_performed="false"
    local rollback_detail="post-activation health failed; no previous bundle was available to restore"
    if ! mv "$active_bundle" "$failed_bundle"; then
      rollback_detail="post-activation health failed; failed bundle could not be archived for rollback"
      tatwo_write_install_receipt \
        "$receipt_path" "failed" "$active_bundle" "$active_bundle" \
        "$archived_bundle" "$rollback_performed" "$rollback_detail"
      printf 'error: post-activation health failed and failed bundle archive failed; receipt=%s\n' "$receipt_path" >&2
      return 1
    fi
    if [[ -n "$archived_bundle" && -e "$archived_bundle" ]]; then
      if mv "$archived_bundle" "$active_bundle" && [[ -e "$active_bundle" ]]; then
        rollback_performed="true"
        rollback_detail="post-activation health failed; previous verified bundle restored"
      else
        rollback_detail="post-activation health failed; previous bundle restoration failed"
      fi
    fi
    tatwo_write_install_receipt \
      "$receipt_path" "failed" "$active_bundle" "$failed_bundle" \
      "$archived_bundle" "$rollback_performed" "$rollback_detail"
    printf 'error: post-activation health failed; receipt=%s\n' "$receipt_path" >&2
    return 1
  fi

  tatwo_write_install_receipt \
    "$receipt_path" "passed" "$active_bundle" "$staged_bundle" \
    "$archived_bundle" "false" \
    "stage verify archive-current atomic-swap and health check passed"
  tatwo_refresh_launchservices "$active_bundle"
  printf 'install_receipt=%s\n' "$receipt_path"
}
