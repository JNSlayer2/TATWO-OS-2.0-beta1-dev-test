#!/usr/bin/env bash
set -euo pipefail

tatwo_list_macho_rpaths() {
  local executable_path="$1"
  otool -l "$executable_path" \
    | awk '
        /LC_RPATH/ {
          getline
          getline
          sub(/^[[:space:]]*path /, "")
          sub(/ \(offset [0-9]+\)$/, "")
          print
        }
      '
}

tatwo_rpath_is_bundle_safe() {
  case "$1" in
    /usr/lib/swift|@loader_path|@loader_path/../Frameworks|@executable_path/../Frameworks)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

tatwo_sanitize_bundle_rpaths() {
  local executable_path="$1"
  local rpath

  while IFS= read -r rpath; do
    [[ -n "$rpath" ]] || continue
    if ! tatwo_rpath_is_bundle_safe "$rpath"; then
      install_name_tool -delete_rpath "$rpath" "$executable_path"
    fi
  done < <(tatwo_list_macho_rpaths "$executable_path")

  if ! tatwo_list_macho_rpaths "$executable_path" \
    | grep -Fxq '@loader_path/../Frameworks'; then
    install_name_tool -add_rpath '@loader_path/../Frameworks' "$executable_path"
  fi

  while IFS= read -r rpath; do
    [[ -n "$rpath" ]] || continue
    if ! tatwo_rpath_is_bundle_safe "$rpath"; then
      printf 'error: unsafe runtime search path remains in staged app: %s\n' \
        "$rpath" >&2
      return 1
    fi
  done < <(tatwo_list_macho_rpaths "$executable_path")
}

tatwo_codesign_preserving_metadata() {
  local identity="$1"
  local target="$2"
  local timestamp_mode="${3:-secure}"
  local timestamp_argument="--timestamp"
  local preserve_metadata="identifier,entitlements,requirements,flags"
  local sign_args=(--force)

  if [[ "$timestamp_mode" == "none" || "$identity" == "-" ]]; then
    timestamp_argument="--timestamp=none"
  elif [[ "$timestamp_mode" == "local-development" ]]; then
    timestamp_argument="--timestamp=none"
    # A local Apple Development identity is used to keep the designated
    # requirement stable across rebuilds. Do not inherit Sparkle's hardened
    # runtime flag into this local-only lane: the main App intentionally stays
    # outside hardened runtime so locally re-signed nested code can load.
    preserve_metadata="identifier,entitlements,requirements"
  else
    sign_args+=(--options runtime)
  fi

  codesign \
    "${sign_args[@]}" \
    "$timestamp_argument" \
    "--preserve-metadata=$preserve_metadata" \
    --sign "$identity" \
    "$target"
}

tatwo_codesign_embedded_sparkle() {
  local app_bundle="$1"
  local identity="$2"
  local timestamp_mode="${3:-secure}"
  local framework="$app_bundle/Contents/Frameworks/Sparkle.framework"
  local version_root="$framework/Versions/B"
  local target

  [[ -d "$framework" ]]
  for target in \
    "$version_root/XPCServices/Downloader.xpc" \
    "$version_root/XPCServices/Installer.xpc" \
    "$version_root/Updater.app" \
    "$version_root/Autoupdate"
  do
    [[ -e "$target" ]]
    tatwo_codesign_preserving_metadata \
      "$identity" "$target" "$timestamp_mode"
  done
  tatwo_codesign_preserving_metadata \
    "$identity" "$framework" "$timestamp_mode"
}

tatwo_embed_sparkle_framework() {
  local build_bin_path="$1"
  local app_bundle="$2"
  local app_executable="$3"
  local source_framework="$build_bin_path/Sparkle.framework"
  local frameworks_dir="$app_bundle/Contents/Frameworks"
  local destination_framework="$frameworks_dir/Sparkle.framework"
  local executable_path="$app_bundle/Contents/MacOS/$app_executable"

  [[ -d "$source_framework" ]]
  [[ -x "$executable_path" ]]
  mkdir -p "$frameworks_dir"
  if [[ -e "$destination_framework" ]]; then
    printf 'error: staged Sparkle framework destination already exists: %s\n' \
      "$destination_framework" >&2
    return 1
  fi
  cp -R "$source_framework" "$destination_framework"

  tatwo_sanitize_bundle_rpaths "$executable_path"

  otool -L "$executable_path" \
    | grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle'
  [[ -x "$destination_framework/Versions/B/Sparkle" ]]
}

tatwo_configure_sparkle_info_plist() {
  local info_plist="$1"
  local feed_url="${TATWO_UPDATE_FEED_URL:-}"
  local public_key="${TATWO_UPDATE_PUBLIC_ED_KEY:-}"
  local channel="${TATWO_UPDATE_CHANNEL:-}"
  local configured=0

  [[ -n "$feed_url" ]] && configured=$((configured + 1))
  [[ -n "$public_key" ]] && configured=$((configured + 1))
  [[ -n "$channel" ]] && configured=$((configured + 1))

  if [[ "$configured" == "0" ]]; then
    local key
    for key in \
      SUFeedURL \
      SUPublicEDKey \
      TatwoUpdateChannel \
      SUEnableAutomaticChecks \
      SUScheduledCheckInterval \
      SUAutomaticallyUpdate \
      SUAllowsAutomaticUpdates
    do
      /usr/libexec/PlistBuddy -c "Delete :$key" "$info_plist" \
        >/dev/null 2>&1 || true
    done
    return 0
  fi
  if [[ "$configured" != "3" ]]; then
    printf '%s\n' \
      'error: Sparkle configuration requires feed URL, public EdDSA key, and channel together' \
      >&2
    return 1
  fi
  if ! node - "$feed_url" <<'NODE'
const value = process.argv[2];
if (/[\u0000-\u0020\u007f]/u.test(value)) process.exit(1);
let parsed;
try {
  parsed = new URL(value);
} catch {
  process.exit(1);
}
if (
  parsed.protocol !== "https:"
  || parsed.hostname.length === 0
  || parsed.username.length !== 0
  || parsed.password.length !== 0
  || parsed.hash.length !== 0
) {
  process.exit(1);
}
NODE
  then
    printf 'error: Sparkle feed must be a credential-free HTTPS URL\n' >&2
    return 1
  fi
  case "$channel" in
    internal-canary|stable) ;;
    *)
      printf 'error: unsupported TATWO update channel: %s\n' "$channel" >&2
      return 1
      ;;
  esac
  if ! node - "$public_key" <<'NODE'
const value = process.argv[2];
if (!/^[A-Za-z0-9+/]{43}=$/u.test(value)) process.exit(1);
const decoded = Buffer.from(value, "base64");
if (decoded.byteLength !== 32 || decoded.toString("base64") !== value) process.exit(1);
NODE
  then
    printf '%s\n' \
      'error: Sparkle public EdDSA key must be canonical base64 for 32 bytes' \
      >&2
    return 1
  fi

  local key
  for key in \
    SUFeedURL \
    SUPublicEDKey \
    TatwoUpdateChannel \
    SUEnableAutomaticChecks \
    SUScheduledCheckInterval \
    SUAutomaticallyUpdate \
    SUAllowsAutomaticUpdates
  do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$info_plist" \
      >/dev/null 2>&1 || true
  done
  /usr/bin/plutil -insert SUFeedURL -string "$feed_url" "$info_plist"
  /usr/bin/plutil -insert SUPublicEDKey -string "$public_key" "$info_plist"
  /usr/bin/plutil -insert TatwoUpdateChannel -string "$channel" "$info_plist"
  /usr/bin/plutil -insert SUEnableAutomaticChecks -bool true "$info_plist"
  /usr/bin/plutil -insert SUScheduledCheckInterval -integer 21600 "$info_plist"
  /usr/bin/plutil -insert SUAutomaticallyUpdate -bool false "$info_plist"
  /usr/bin/plutil -insert SUAllowsAutomaticUpdates -bool false "$info_plist"
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
  if [[ "$#" -ne 3 ]]; then
    printf 'usage: %s <build-bin-path> <app-bundle> <app-executable>\n' "$0" >&2
    exit 64
  fi
  tatwo_embed_sparkle_framework "$1" "$2" "$3"
fi
