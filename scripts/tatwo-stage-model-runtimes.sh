#!/usr/bin/env bash

# Shared model-runtime staging for Tatwo App bundles.
# Call tatwo_resolve_model_runtimes before staging, then
# tatwo_stage_model_runtimes after Contents/{Helpers,Resources} exist.

# This flag is intentionally reset when the helper is sourced. A caller cannot
# opt into reuse preservation through its environment; only the validated
# tatwo_resolve_model_runtimes_reusing_pinned_grok entrypoint may enable it.
TATWO_REUSE_PINNED_GROK_RUNTIME=false
TATWO_REUSE_PINNED_GROK_SOURCE_BUNDLE=""
TATWO_REUSE_PINNED_GROK_RECEIPT=""
TATWO_REUSE_PINNED_GROK_INFO_PLIST=""

tatwo_configure_model_runtime_paths() {
  local app_bundle="$1"

  SUBSCRIPTION_RUNTIME_RELATIVE="Contents/Helpers/TatwoSubscriptionRuntime"
  SUBSCRIPTION_RUNTIME="$app_bundle/$SUBSCRIPTION_RUNTIME_RELATIVE"
  SUBSCRIPTION_RUNTIME_SOURCE="${TATWO_SUBSCRIPTION_RUNTIME_SOURCE:-/Applications/ChatGPT.app/Contents/Resources/codex}"
  SUBSCRIPTION_CODE_MODE_HOST_RELATIVE="Contents/Helpers/codex-code-mode-host"
  SUBSCRIPTION_CODE_MODE_HOST="$app_bundle/$SUBSCRIPTION_CODE_MODE_HOST_RELATIVE"
  SUBSCRIPTION_CODE_MODE_HOST_SOURCE="${TATWO_SUBSCRIPTION_CODE_MODE_HOST_SOURCE:-$(dirname "$SUBSCRIPTION_RUNTIME_SOURCE")/codex-code-mode-host}"
  SUBSCRIPTION_NOTICES_SOURCE="${TATWO_SUBSCRIPTION_THIRD_PARTY_NOTICES_SOURCE:-$(dirname "$SUBSCRIPTION_RUNTIME_SOURCE")/THIRD_PARTY_NOTICES.txt}"
  SUBSCRIPTION_NOTICES_RELATIVE="Contents/Resources/TatwoSubscriptionRuntime-THIRD_PARTY_NOTICES.txt"
  SUBSCRIPTION_NOTICES="$app_bundle/$SUBSCRIPTION_NOTICES_RELATIVE"

  CLAUDE_SUBSCRIPTION_RUNTIME_RELATIVE="Contents/Helpers/TatwoClaudeSubscriptionRuntime"
  CLAUDE_SUBSCRIPTION_RUNTIME="$app_bundle/$CLAUDE_SUBSCRIPTION_RUNTIME_RELATIVE"
  TATWO_CLAUDE_SUBSCRIPTION_RUNTIME_SOURCE="${TATWO_CLAUDE_SUBSCRIPTION_RUNTIME_SOURCE:-/opt/homebrew/bin/claude}"
  CLAUDE_SUBSCRIPTION_LICENSE_SOURCE="${TATWO_CLAUDE_SUBSCRIPTION_LICENSE_SOURCE:-/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/LICENSE.md}"
  CLAUDE_SUBSCRIPTION_LICENSE_RELATIVE="Contents/Resources/TatwoClaudeSubscriptionRuntime-LICENSE.md"
  CLAUDE_SUBSCRIPTION_LICENSE="$app_bundle/$CLAUDE_SUBSCRIPTION_LICENSE_RELATIVE"

  GROK_SUBSCRIPTION_RUNTIME_RELATIVE="Contents/Helpers/TatwoGrokSubscriptionRuntime"
  GROK_SUBSCRIPTION_RUNTIME="$app_bundle/$GROK_SUBSCRIPTION_RUNTIME_RELATIVE"
  TATWO_GROK_SUBSCRIPTION_RUNTIME_SOURCE="${TATWO_GROK_SUBSCRIPTION_RUNTIME_SOURCE:-}"
  GROK_VENDOR_RUNTIME_RELATIVE="Contents/Helpers/TatwoGrokVendorRuntime"
  GROK_VENDOR_RUNTIME="$app_bundle/$GROK_VENDOR_RUNTIME_RELATIVE"
  TATWO_GROK_VENDOR_RUNTIME_SOURCE="${TATWO_GROK_VENDOR_RUNTIME_SOURCE:-$HOME/.grok/bin/grok}"
}

tatwo_resolve_non_grok_model_runtimes() {
  local app_bundle="$1"

  tatwo_configure_model_runtime_paths "$app_bundle"

  if [[ ! -x "$SUBSCRIPTION_RUNTIME_SOURCE" ]]; then
    printf 'error: TATWO subscription runtime source is unavailable or not executable: %s\n' \
      "$SUBSCRIPTION_RUNTIME_SOURCE" >&2
    return 1
  fi
  if [[ ! -x "$SUBSCRIPTION_CODE_MODE_HOST_SOURCE" ]]; then
    printf 'error: TATWO subscription code-mode host is unavailable or not executable: %s\n' \
      "$SUBSCRIPTION_CODE_MODE_HOST_SOURCE" >&2
    return 1
  fi
  if [[ ! -f "$SUBSCRIPTION_NOTICES_SOURCE" ]]; then
    printf 'error: TATWO subscription runtime third-party notices are missing: %s\n' \
      "$SUBSCRIPTION_NOTICES_SOURCE" >&2
    return 1
  fi
  if [[ ! -x "$TATWO_CLAUDE_SUBSCRIPTION_RUNTIME_SOURCE" ]]; then
    printf 'error: TATWO Claude subscription runtime source is unavailable or not executable: %s\n' \
      "$TATWO_CLAUDE_SUBSCRIPTION_RUNTIME_SOURCE" >&2
    return 1
  fi
  if [[ ! -f "$CLAUDE_SUBSCRIPTION_LICENSE_SOURCE" ]]; then
    printf 'error: TATWO Claude subscription runtime license is missing: %s\n' \
      "$CLAUDE_SUBSCRIPTION_LICENSE_SOURCE" >&2
    return 1
  fi
  SUBSCRIPTION_RUNTIME_VERSION="$(
    "$SUBSCRIPTION_RUNTIME_SOURCE" --version 2>/dev/null \
      | head -n 1 \
      | tr -d '\r\n'
  )"
  if [[ -z "$SUBSCRIPTION_RUNTIME_VERSION" ]]; then
    printf 'error: TATWO subscription runtime version could not be read\n' >&2
    return 1
  fi
  CLAUDE_SUBSCRIPTION_RUNTIME_VERSION="$(
    "$TATWO_CLAUDE_SUBSCRIPTION_RUNTIME_SOURCE" --version 2>/dev/null \
      | head -n 1 \
      | tr -d '\r\n'
  )"
  if [[ -z "$CLAUDE_SUBSCRIPTION_RUNTIME_VERSION" ]]; then
    printf 'error: TATWO Claude subscription runtime version could not be read\n' >&2
    return 1
  fi
}

tatwo_resolve_model_runtimes() {
  local app_bundle="$1"

  TATWO_REUSE_PINNED_GROK_RUNTIME=false
  TATWO_REUSE_PINNED_GROK_SOURCE_BUNDLE=""
  TATWO_REUSE_PINNED_GROK_RECEIPT=""
  TATWO_REUSE_PINNED_GROK_INFO_PLIST=""
  tatwo_resolve_non_grok_model_runtimes "$app_bundle" || return 1

  if [[ ! -x "$TATWO_GROK_VENDOR_RUNTIME_SOURCE" ]]; then
    printf 'error: TATWO Grok vendor runtime source is unavailable or not executable: %s\n' \
      "$TATWO_GROK_VENDOR_RUNTIME_SOURCE" >&2
    return 1
  fi
  if [[ -n "$TATWO_GROK_SUBSCRIPTION_RUNTIME_SOURCE" ]] \
    && [[ ! -x "$TATWO_GROK_SUBSCRIPTION_RUNTIME_SOURCE" ]]; then
    printf 'error: TATWO Grok subscription wrapper source is unavailable or not executable: %s\n' \
      "$TATWO_GROK_SUBSCRIPTION_RUNTIME_SOURCE" >&2
    return 1
  fi

  GROK_VENDOR_RUNTIME_VERSION="$(
    "$TATWO_GROK_VENDOR_RUNTIME_SOURCE" --version 2>/dev/null \
      | head -n 1 \
      | tr -d '\r\n'
  )"
  if [[ -z "$GROK_VENDOR_RUNTIME_VERSION" ]]; then
    printf 'error: TATWO Grok vendor runtime version could not be read\n' >&2
    return 1
  fi
  GROK_SUBSCRIPTION_RUNTIME_VERSION="tatwo-grok-subscription-v1 ($GROK_VENDOR_RUNTIME_VERSION)"
}

tatwo_required_json_string() {
  local document="$1"
  local key="$2"

  /usr/bin/python3 - "$document" "$key" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    document = json.load(handle)
value = document.get(sys.argv[2])
if not isinstance(value, str) or not value:
    raise SystemExit(1)
print(value)
PY
}

tatwo_required_plist_string() {
  local document="$1"
  local key="$2"

  /usr/bin/plutil -extract "$key" raw -o - "$document" 2>/dev/null
}

tatwo_canonical_existing_path() {
  /usr/bin/python3 - "$1" <<'PY'
import os
import sys

path = sys.argv[1]
if not os.path.exists(path):
    raise SystemExit(1)
print(os.path.realpath(path))
PY
}

tatwo_path_is_within() {
  local candidate="$1"
  local root="$2"

  [[ "$candidate" == "$root" || "$candidate" == "$root/"* ]]
}

tatwo_validate_pinned_grok_runtime_file() {
  local label="$1"
  local path="$2"
  local source_bundle="$3"
  local expected_sha256="$4"
  local canonical_bundle
  local canonical_path
  local actual_sha256

  if [[ ! "$expected_sha256" =~ ^[0-9a-f]{64}$ ]]; then
    printf 'error: reuse %s receipt/plist SHA-256 is invalid\n' "$label" >&2
    return 1
  fi
  if [[ ! -f "$path" || -L "$path" || ! -x "$path" ]]; then
    printf 'error: reuse %s must be a regular executable, not a symlink: %s\n' \
      "$label" "$path" >&2
    return 1
  fi
  canonical_bundle="$(tatwo_canonical_existing_path "$source_bundle")" \
    || return 1
  canonical_path="$(tatwo_canonical_existing_path "$path")" || return 1
  if ! tatwo_path_is_within "$canonical_path" "$canonical_bundle"; then
    printf 'error: reuse %s escapes the signed staging bundle: %s\n' \
      "$label" "$path" >&2
    return 1
  fi
  actual_sha256="$(shasum -a 256 "$path" | awk '{print $1}')" \
    || return 1
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    printf 'error: reuse %s hash mismatch: expected %s, got %s\n' \
      "$label" "$expected_sha256" "$actual_sha256" >&2
    return 1
  fi
}

tatwo_resolve_reuse_pinned_grok_runtime() {
  local app_bundle="$1"
  local source_bundle="$2"
  local receipt="$3"
  local info_plist="$4"
  local receipt_subscription_sha256
  local receipt_subscription_version
  local receipt_vendor_sha256
  local receipt_vendor_version
  local plist_subscription_sha256
  local plist_subscription_version
  local plist_vendor_sha256
  local plist_vendor_version
  local expected_subscription_version

  tatwo_configure_model_runtime_paths "$app_bundle"

  if [[ ! -d "$source_bundle" || -L "$source_bundle" ]]; then
    printf 'error: reuse Grok runtime source bundle is not a regular App directory: %s\n' \
      "$source_bundle" >&2
    return 1
  fi
  if [[ ! -f "$receipt" || -L "$receipt" ]]; then
    printf 'error: reuse Grok runtime receipt is missing or a symlink: %s\n' \
      "$receipt" >&2
    return 1
  fi
  if [[ ! -f "$info_plist" || -L "$info_plist" ]]; then
    printf 'error: reuse Grok runtime Info.plist is missing or a symlink: %s\n' \
      "$info_plist" >&2
    return 1
  fi
  if ! codesign --verify --deep --strict "$source_bundle"; then
    printf 'error: reuse Grok runtime source bundle signature is invalid: %s\n' \
      "$source_bundle" >&2
    return 1
  fi

  receipt_subscription_sha256="$(
    tatwo_required_json_string "$receipt" grokSubscriptionRuntimeSHA256
  )" || {
    printf '%s\n' \
      'error: reuse receipt is missing grokSubscriptionRuntimeSHA256' >&2
    return 1
  }
  receipt_subscription_version="$(
    tatwo_required_json_string "$receipt" grokSubscriptionRuntimeVersion
  )" || {
    printf '%s\n' \
      'error: reuse receipt is missing grokSubscriptionRuntimeVersion' >&2
    return 1
  }
  receipt_vendor_sha256="$(
    tatwo_required_json_string "$receipt" grokVendorRuntimeSHA256
  )" || {
    printf '%s\n' \
      'error: reuse receipt is missing grokVendorRuntimeSHA256' >&2
    return 1
  }
  receipt_vendor_version="$(
    tatwo_required_json_string "$receipt" grokVendorRuntimeVersion
  )" || {
    printf '%s\n' \
      'error: reuse receipt is missing grokVendorRuntimeVersion' >&2
    return 1
  }
  plist_subscription_sha256="$(
    tatwo_required_plist_string "$info_plist" \
      TatwoGrokSubscriptionRuntimeSHA256
  )" || {
    printf '%s\n' \
      'error: reuse Info.plist is missing TatwoGrokSubscriptionRuntimeSHA256' >&2
    return 1
  }
  plist_subscription_version="$(
    tatwo_required_plist_string "$info_plist" \
      TatwoGrokSubscriptionRuntimeVersion
  )" || {
    printf '%s\n' \
      'error: reuse Info.plist is missing TatwoGrokSubscriptionRuntimeVersion' >&2
    return 1
  }
  plist_vendor_sha256="$(
    tatwo_required_plist_string "$info_plist" TatwoGrokVendorRuntimeSHA256
  )" || {
    printf '%s\n' \
      'error: reuse Info.plist is missing TatwoGrokVendorRuntimeSHA256' >&2
    return 1
  }
  plist_vendor_version="$(
    tatwo_required_plist_string "$info_plist" TatwoGrokVendorRuntimeVersion \
      || true
  )"

  if [[ "$receipt_subscription_sha256" != "$plist_subscription_sha256" \
    || "$receipt_vendor_sha256" != "$plist_vendor_sha256" ]]
  then
    printf '%s\n' \
      'error: reuse Grok runtime receipt and signed Info.plist hashes disagree' >&2
    return 1
  fi
  if [[ "$receipt_subscription_version" != "$plist_subscription_version" ]]; then
    printf '%s\n' \
      'error: reuse Grok subscription runtime receipt and signed Info.plist versions disagree' >&2
    return 1
  fi
  if [[ -n "$plist_vendor_version" \
    && "$receipt_vendor_version" != "$plist_vendor_version" ]]
  then
    printf '%s\n' \
      'error: reuse Grok vendor runtime receipt and signed Info.plist versions disagree' >&2
    return 1
  fi

  # Legacy fixed staging bundles did not carry the dedicated vendor-version
  # plist key. They did carry the wrapper version inside the signed plist, and
  # that value embeds the exact receipt-pinned vendor version. Requiring this
  # exact relation preserves the existing pin without accepting caller input.
  expected_subscription_version="tatwo-grok-subscription-v1 ($receipt_vendor_version)"
  if [[ "$receipt_subscription_version" != "$expected_subscription_version" ]]; then
    printf '%s\n' \
      'error: reuse Grok runtime version pins are internally inconsistent' >&2
    return 1
  fi

  TATWO_GROK_SUBSCRIPTION_RUNTIME_SOURCE="$source_bundle/Contents/Helpers/TatwoGrokSubscriptionRuntime"
  TATWO_GROK_VENDOR_RUNTIME_SOURCE="$source_bundle/Contents/Helpers/TatwoGrokVendorRuntime"
  tatwo_validate_pinned_grok_runtime_file \
    "Grok subscription runtime" \
    "$TATWO_GROK_SUBSCRIPTION_RUNTIME_SOURCE" \
    "$source_bundle" \
    "$receipt_subscription_sha256" \
    || return 1
  tatwo_validate_pinned_grok_runtime_file \
    "Grok vendor runtime" \
    "$TATWO_GROK_VENDOR_RUNTIME_SOURCE" \
    "$source_bundle" \
    "$receipt_vendor_sha256" \
    || return 1

  GROK_SUBSCRIPTION_RUNTIME_VERSION="$receipt_subscription_version"
  GROK_VENDOR_RUNTIME_VERSION="$receipt_vendor_version"
  GROK_SUBSCRIPTION_RUNTIME_SHA256="$receipt_subscription_sha256"
  GROK_VENDOR_RUNTIME_SHA256="$receipt_vendor_sha256"
  TATWO_REUSE_PINNED_GROK_RUNTIME=true
  TATWO_REUSE_PINNED_GROK_SOURCE_BUNDLE="$source_bundle"
  TATWO_REUSE_PINNED_GROK_RECEIPT="$receipt"
  TATWO_REUSE_PINNED_GROK_INFO_PLIST="$info_plist"
}

tatwo_resolve_model_runtimes_reusing_pinned_grok() {
  local app_bundle="$1"
  local source_bundle="$2"
  local receipt="$3"
  local info_plist="$4"

  tatwo_resolve_non_grok_model_runtimes "$app_bundle" || return 1
  tatwo_resolve_reuse_pinned_grok_runtime \
    "$app_bundle" "$source_bundle" "$receipt" "$info_plist"
}

tatwo_write_default_grok_subscription_runtime() {
  local destination="$1"

  cat >"$destination" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GROK_BIN="${GROK_REAL_BIN:-$HELPERS_DIR/TatwoGrokVendorRuntime}"
ISOLATED_HOME="${GROK_ISOLATED_HOME:-${HOME:?HOME is required}}"
AUTH_SOURCE="${GROK_AUTH_SOURCE:-$ISOLATED_HOME/.grok/auth.json}"
AUTH_TARGET="$ISOLATED_HOME/.grok/auth.json"

if [[ ! -x "$GROK_BIN" ]]; then
  printf 'TatwoGrokSubscriptionRuntime: bundled Grok runtime is unavailable\n' >&2
  exit 127
fi

mkdir -p \
  "$ISOLATED_HOME/.grok" \
  "$ISOLATED_HOME/.config" \
  "$ISOLATED_HOME/.cache"
chmod 700 \
  "$ISOLATED_HOME" \
  "$ISOLATED_HOME/.grok" \
  "$ISOLATED_HOME/.config" \
  "$ISOLATED_HOME/.cache" \
  2>/dev/null || true

if [[ "$AUTH_SOURCE" != "$AUTH_TARGET" ]] \
  && [[ -f "$AUTH_SOURCE" ]] \
  && [[ ! -e "$AUTH_TARGET" ]]; then
  ln -s "$AUTH_SOURCE" "$AUTH_TARGET" 2>/dev/null \
    || cp "$AUTH_SOURCE" "$AUTH_TARGET"
  chmod 600 "$AUTH_TARGET" 2>/dev/null || true
fi

exec env \
  -u CLAUDE_CONFIG_DIR \
  -u CLAUDE_HOME \
  -u CLAUDE_PLUGIN_ROOT \
  -u CLAUDE_PLUGIN_DATA \
  -u CLAUDE_PROJECT_DIR \
  -u ANTHROPIC_API_KEY \
  -u OPENAI_API_KEY \
  -u XAI_API_KEY \
  -u GROK_API_KEY \
  HOME="$ISOLATED_HOME" \
  GROK_HOME="$ISOLATED_HOME/.grok" \
  XDG_CONFIG_HOME="$ISOLATED_HOME/.config" \
  XDG_CACHE_HOME="$ISOLATED_HOME/.cache" \
  "$GROK_BIN" "$@"
SH
}

tatwo_refresh_model_runtime_sha256() {
  if ! SUBSCRIPTION_RUNTIME_SHA256="$(
    shasum -a 256 "$SUBSCRIPTION_RUNTIME" | awk '{print $1}'
  )" \
    || ! SUBSCRIPTION_CODE_MODE_HOST_SHA256="$(
      shasum -a 256 "$SUBSCRIPTION_CODE_MODE_HOST" | awk '{print $1}'
    )" \
    || ! CLAUDE_SUBSCRIPTION_RUNTIME_SHA256="$(
      shasum -a 256 "$CLAUDE_SUBSCRIPTION_RUNTIME" | awk '{print $1}'
    )" \
    || ! GROK_SUBSCRIPTION_RUNTIME_SHA256="$(
      shasum -a 256 "$GROK_SUBSCRIPTION_RUNTIME" | awk '{print $1}'
    )" \
    || ! GROK_VENDOR_RUNTIME_SHA256="$(
      shasum -a 256 "$GROK_VENDOR_RUNTIME" | awk '{print $1}'
    )"
  then
    printf 'error: could not calculate staged model runtime digests\n' >&2
    return 1
  fi
}

tatwo_stage_model_runtimes() {
  local app_bundle="$1"
  local actual_sha256

  tatwo_configure_model_runtime_paths "$app_bundle"
  if ! mkdir -p \
    "$app_bundle/Contents/Helpers" \
    "$app_bundle/Contents/Resources"
  then
    printf 'error: could not create model runtime bundle directories: %s\n' \
      "$app_bundle" >&2
    return 1
  fi

  if ! cp "$SUBSCRIPTION_RUNTIME_SOURCE" "$SUBSCRIPTION_RUNTIME" \
    || ! chmod +x "$SUBSCRIPTION_RUNTIME" \
    || ! cp \
      "$SUBSCRIPTION_CODE_MODE_HOST_SOURCE" \
      "$SUBSCRIPTION_CODE_MODE_HOST" \
    || ! chmod +x "$SUBSCRIPTION_CODE_MODE_HOST" \
    || ! cp "$SUBSCRIPTION_NOTICES_SOURCE" "$SUBSCRIPTION_NOTICES" \
    || ! cp -L \
      "$TATWO_CLAUDE_SUBSCRIPTION_RUNTIME_SOURCE" \
      "$CLAUDE_SUBSCRIPTION_RUNTIME" \
    || ! chmod +x "$CLAUDE_SUBSCRIPTION_RUNTIME" \
    || ! cp \
      "$CLAUDE_SUBSCRIPTION_LICENSE_SOURCE" \
      "$CLAUDE_SUBSCRIPTION_LICENSE"
  then
    printf 'error: could not copy required model runtime payloads into %s\n' \
      "$app_bundle" >&2
    return 1
  fi

  if [[ "$TATWO_REUSE_PINNED_GROK_RUNTIME" == "true" ]]; then
    tatwo_validate_pinned_grok_runtime_file \
      "Grok subscription runtime" \
      "$TATWO_GROK_SUBSCRIPTION_RUNTIME_SOURCE" \
      "$TATWO_REUSE_PINNED_GROK_SOURCE_BUNDLE" \
      "$GROK_SUBSCRIPTION_RUNTIME_SHA256" \
      || return 1
    tatwo_validate_pinned_grok_runtime_file \
      "Grok vendor runtime" \
      "$TATWO_GROK_VENDOR_RUNTIME_SOURCE" \
      "$TATWO_REUSE_PINNED_GROK_SOURCE_BUNDLE" \
      "$GROK_VENDOR_RUNTIME_SHA256" \
      || return 1
    if ! cp "$TATWO_GROK_SUBSCRIPTION_RUNTIME_SOURCE" \
      "$GROK_SUBSCRIPTION_RUNTIME" \
      || ! chmod +x "$GROK_SUBSCRIPTION_RUNTIME" \
      || ! cp "$TATWO_GROK_VENDOR_RUNTIME_SOURCE" \
        "$GROK_VENDOR_RUNTIME" \
      || ! chmod +x "$GROK_VENDOR_RUNTIME"
    then
      printf 'error: could not preserve pinned Grok runtime payloads in %s\n' \
        "$app_bundle" >&2
      return 1
    fi
    actual_sha256="$(
      shasum -a 256 "$GROK_SUBSCRIPTION_RUNTIME" | awk '{print $1}'
    )" || return 1
    if [[ "$actual_sha256" != "$GROK_SUBSCRIPTION_RUNTIME_SHA256" ]]; then
      printf 'error: copied Grok subscription runtime hash mismatch: expected %s, got %s\n' \
        "$GROK_SUBSCRIPTION_RUNTIME_SHA256" "$actual_sha256" >&2
      return 1
    fi
    actual_sha256="$(
      shasum -a 256 "$GROK_VENDOR_RUNTIME" | awk '{print $1}'
    )" || return 1
    if [[ "$actual_sha256" != "$GROK_VENDOR_RUNTIME_SHA256" ]]; then
      printf 'error: copied Grok vendor runtime hash mismatch: expected %s, got %s\n' \
        "$GROK_VENDOR_RUNTIME_SHA256" "$actual_sha256" >&2
      return 1
    fi
  elif [[ -n "$TATWO_GROK_SUBSCRIPTION_RUNTIME_SOURCE" ]]; then
    if ! cp "$TATWO_GROK_SUBSCRIPTION_RUNTIME_SOURCE" \
      "$GROK_SUBSCRIPTION_RUNTIME"
    then
      printf 'error: could not copy Grok subscription wrapper into %s\n' \
        "$app_bundle" >&2
      return 1
    fi
    if ! cp -L \
      "$TATWO_GROK_VENDOR_RUNTIME_SOURCE" \
      "$GROK_VENDOR_RUNTIME" \
      || ! chmod +x "$GROK_VENDOR_RUNTIME"
    then
      printf 'error: could not copy Grok vendor runtime into %s\n' \
        "$app_bundle" >&2
      return 1
    fi
  else
    if ! tatwo_write_default_grok_subscription_runtime \
      "$GROK_SUBSCRIPTION_RUNTIME"
    then
      printf 'error: could not create bundled Grok subscription wrapper\n' >&2
      return 1
    fi
    if ! cp -L \
      "$TATWO_GROK_VENDOR_RUNTIME_SOURCE" \
      "$GROK_VENDOR_RUNTIME" \
      || ! chmod +x "$GROK_VENDOR_RUNTIME"
    then
      printf 'error: could not copy Grok vendor runtime into %s\n' \
        "$app_bundle" >&2
      return 1
    fi
  fi
  if ! chmod +x "$GROK_SUBSCRIPTION_RUNTIME"; then
    printf 'error: could not make Grok subscription wrapper executable\n' >&2
    return 1
  fi

  if ! SUBSCRIPTION_RUNTIME_PRE_DEEP_SHA256="$(
    shasum -a 256 "$SUBSCRIPTION_RUNTIME" | awk '{print $1}'
  )" \
    || ! SUBSCRIPTION_CODE_MODE_HOST_PRE_DEEP_SHA256="$(
      shasum -a 256 "$SUBSCRIPTION_CODE_MODE_HOST" | awk '{print $1}'
    )" \
    || ! SUBSCRIPTION_NOTICES_SHA256="$(
      shasum -a 256 "$SUBSCRIPTION_NOTICES" | awk '{print $1}'
    )" \
    || ! CLAUDE_SUBSCRIPTION_RUNTIME_PRE_DEEP_SHA256="$(
      shasum -a 256 "$CLAUDE_SUBSCRIPTION_RUNTIME" | awk '{print $1}'
    )" \
    || ! CLAUDE_SUBSCRIPTION_LICENSE_SHA256="$(
      shasum -a 256 "$CLAUDE_SUBSCRIPTION_LICENSE" | awk '{print $1}'
    )" \
    || ! GROK_SUBSCRIPTION_RUNTIME_PRE_DEEP_SHA256="$(
      shasum -a 256 "$GROK_SUBSCRIPTION_RUNTIME" | awk '{print $1}'
    )" \
    || ! GROK_VENDOR_RUNTIME_PRE_DEEP_SHA256="$(
      shasum -a 256 "$GROK_VENDOR_RUNTIME" | awk '{print $1}'
    )" \
    || ! tatwo_refresh_model_runtime_sha256
  then
    printf 'error: could not calculate staged model runtime payload digests\n' >&2
    return 1
  fi
}

tatwo_write_model_runtime_info_plist_stamps() {
  local info_plist="$1"

  if ! /usr/bin/plutil -replace TatwoSubscriptionRuntimeVersion \
    -string "$SUBSCRIPTION_RUNTIME_VERSION" "$info_plist" \
    || ! /usr/bin/plutil -replace TatwoSubscriptionRuntimeSHA256 \
      -string "$SUBSCRIPTION_RUNTIME_SHA256" "$info_plist" \
    || ! /usr/bin/plutil -replace TatwoSubscriptionCodeModeHostSHA256 \
      -string "$SUBSCRIPTION_CODE_MODE_HOST_SHA256" "$info_plist" \
    || ! /usr/bin/plutil -replace TatwoClaudeSubscriptionRuntimeVersion \
      -string "$CLAUDE_SUBSCRIPTION_RUNTIME_VERSION" "$info_plist" \
    || ! /usr/bin/plutil -replace TatwoClaudeSubscriptionRuntimeSHA256 \
      -string "$CLAUDE_SUBSCRIPTION_RUNTIME_SHA256" "$info_plist" \
    || ! /usr/bin/plutil -replace TatwoGrokSubscriptionRuntimeVersion \
      -string "$GROK_SUBSCRIPTION_RUNTIME_VERSION" "$info_plist" \
    || ! /usr/bin/plutil -replace TatwoGrokSubscriptionRuntimeSHA256 \
      -string "$GROK_SUBSCRIPTION_RUNTIME_SHA256" "$info_plist" \
    || ! /usr/bin/plutil -replace TatwoGrokVendorRuntimeVersion \
      -string "$GROK_VENDOR_RUNTIME_VERSION" "$info_plist" \
    || ! /usr/bin/plutil -replace TatwoGrokVendorRuntimeSHA256 \
      -string "$GROK_VENDOR_RUNTIME_SHA256" "$info_plist"
  then
    printf 'error: could not write model runtime Info.plist stamps: %s\n' \
      "$info_plist" >&2
    return 1
  fi
}

tatwo_verify_model_runtime_sha256() {
  local actual
  local expected
  local path
  local label

  while IFS='|' read -r label path expected; do
    actual="$(shasum -a 256 "$path" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
      printf 'error: %s hash changed after final signing: expected %s, got %s\n' \
        "$label" "$expected" "$actual" >&2
      return 1
    fi
  done <<EOF
subscription runtime|$SUBSCRIPTION_RUNTIME|$SUBSCRIPTION_RUNTIME_SHA256
subscription code-mode host|$SUBSCRIPTION_CODE_MODE_HOST|$SUBSCRIPTION_CODE_MODE_HOST_SHA256
Claude subscription runtime|$CLAUDE_SUBSCRIPTION_RUNTIME|$CLAUDE_SUBSCRIPTION_RUNTIME_SHA256
Grok subscription runtime|$GROK_SUBSCRIPTION_RUNTIME|$GROK_SUBSCRIPTION_RUNTIME_SHA256
Grok vendor runtime|$GROK_VENDOR_RUNTIME|$GROK_VENDOR_RUNTIME_SHA256
EOF
}
