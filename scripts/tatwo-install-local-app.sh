#!/usr/bin/env bash
set -euo pipefail

# Assemble and install the canonical Tatwo Ultrawork App for a local,
# self-managed Mac. Signing is stable-identity first: use Developer ID
# Application when available, otherwise use a local Apple Development identity.
# Ad-hoc remains an explicit rollback/test lane or the last fallback when no
# fixed identity exists.
# See docs/tatwo/SIGNING_AUTOSWITCH.md.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/tatwo-main-app-contract.sh"
source "$ROOT_DIR/scripts/tatwo-safe-app-bundle.sh"
source "$ROOT_DIR/scripts/tatwo-embed-sparkle-framework.sh"
source "$ROOT_DIR/scripts/tatwo-stage-model-runtimes.sh"
source "$ROOT_DIR/scripts/tatwo-cef-bundle.sh"

APP_DIR="${TATWO_INSTALL_TARGET_DIR:-${TATWO_ULTRAWORK_APP_DIR:-/Applications}}"
APP_BUNDLE="$APP_DIR/$TATWO_MAIN_APP_BUNDLE_FILENAME"
PRODUCT_NAME="TatwoUltraworkMac"
STAGING_EXECUTABLE="$PRODUCT_NAME"
CLI_PRODUCT="tatwo-ultrawork"
APP_PRINCIPAL_CLASS="TatwoCEFApplication"
ENABLE_CEF=true
RESOURCE_BUNDLE_GLOB="TatwoUltrawork_*.bundle"
BUILD_JOBS="${TATWO_ULTRAWORK_BUILD_JOBS:-2}"
INSTALLER_STATE_DIR="${TATWO_ULTRAWORK_LOCAL_APP_STATE_DIR:-${TATWO_ULTRAWORK_STATE_DIR:-$HOME/Library/Application Support/$TATWO_MAIN_APP_SUPPORT_NAME/local-app-install}}"
STAGING_ROOT="${TATWO_ULTRAWORK_LOCAL_APP_STAGING_ROOT:-${TATWO_ULTRAWORK_STAGING_ROOT:-$INSTALLER_STATE_DIR/staging}}"
ARCHIVE_ROOT="${TATWO_ULTRAWORK_LOCAL_APP_ARCHIVE_ROOT:-${TATWO_ULTRAWORK_ARCHIVE_ROOT:-$INSTALLER_STATE_DIR/bundle-archives.noindex}}"
PROVENANCE_ROOT="${TATWO_ULTRAWORK_PROVENANCE_ROOT:-${TATWO_ULTRAWORK_BUILD_PATH:-$INSTALLER_STATE_DIR/candidate-runs}}"
CEF_CACHE_ROOT="${TATWO_ULTRAWORK_CEF_BUILD_CACHE_ROOT:-$INSTALLER_STATE_DIR/cef-build-cache}"
PROVENANCE_TOOL="$ROOT_DIR/scripts/tatwo-local-provenance.mjs"
MINIMUM_SYSTEM_VERSION="${TATWO_ULTRAWORK_MINIMUM_SYSTEM_VERSION:-14.0}"
ANCHOR_HELPER_RELATIVE="Contents/Helpers/TatwoPLGAnchorHelper"
ANCHOR_HELPER_IDENTIFIER="ai.tatwo.ultrawork.plg-anchor-helper.v1"
ANCHOR_HELPER_SOURCE_RELATIVE="Tools/TatwoPLGAnchorHelper/main.c"
ANCHOR_HELPER_COMPILE_FLAGS=()
ANCHOR_HELPER_STRIP_FLAGS=("-S")
SIGNING_MODE="ad-hoc"
SIGNING_IDENTITY="-"
SIGNING_IDENTITY_NAME=""
SIGNING_TEAM_ID=""
SIGNING_LINE="signing=ad-hoc"
APP_VERSION=""
APP_BUILD=""
BUILD_PATH=""
BUILD_BIN_PATH=""
BUILD_BINARY=""
RUN_ROOT=""
STAGE_ROOT=""
STAGED_BUNDLE=""
SOURCE_PAYLOAD_DIR=""
SOURCE_WORKSPACE=""
PROVENANCE_DIR=""
SOURCE_COMMIT=""
SOURCE_TREE=""
SOURCE_DIRTY=""
SOURCE_SNAPSHOT_PATH=""
SOURCE_TREE_MANIFEST_PATH=""
SOURCE_ARCHIVE_PATH=""
SOURCE_SNAPSHOT_SHA256=""
SOURCE_TREE_MANIFEST_SHA256=""
BUILD_INPUT_MANIFEST_PATH=""
BUILD_INPUT_MANIFEST_SHA256=""
BUILD_OUTPUT_MANIFEST_PATH=""
BUILD_OUTPUT_MANIFEST_SHA256=""
BUNDLE_CONTENT_MANIFEST_PATH=""
BUNDLE_CONTENT_MANIFEST_SHA256=""
MAIN_EXECUTABLE_SHA256=""
EMBEDDED_PROVENANCE_SHA256=""
EMBEDDED_BUNDLE_CONTENT_MANIFEST_RELATIVE="Contents/Resources/TatwoBundleContentManifestV1.json"
EMBEDDED_AUTHORITY_PROVENANCE_RELATIVE="Contents/Resources/TatwoProvenance"
STAGED_BUNDLE_MANIFEST_PATH=""
STAGED_BUNDLE_MANIFEST_SHA256=""
STAGED_BUNDLE_IDENTITY_PATH=""
STAGED_BUNDLE_IDENTITY_SHA256=""
CANDIDATE_ID=""
BUILD_HOME=""
BUILD_TMPDIR=""
BUILD_DEVELOPER_DIR=""
BUILD_SDKROOT=""
NODE_BINARY=""
NODE_BINARY_SHA256=""
NODE_BINARY_CD_HASH=""
NODE_VERSION=""
INSTALL_RECEIPT_ID=""
INSTALL_RECEIPT_NONCE=""
INSTALL_RECEIPT_FILENAME=""
CANONICAL_APP_SUPPORT_ROOT="$HOME/Library/Application Support/$TATWO_MAIN_APP_SUPPORT_NAME"
CANONICAL_STATE_ROOT="$CANONICAL_APP_SUPPORT_ROOT/state"
DEVICE_IDENTITY_PATH="$CANONICAL_APP_SUPPORT_ROOT/device-identity.json"
LOCAL_INTERNAL_ANCHOR_PATH="$CANONICAL_APP_SUPPORT_ROOT/local-app-install/local-internal-install-anchor.json"
DEVICE_ID=""
CANDIDATE_LIFECYCLE_STATE="uninitialized"
BUNDLE_ID="$TATWO_MAIN_APP_BUNDLE_ID"
REMOVABLE_VOLUME_USAGE_DESCRIPTION='Tatwo Ultrawork 需要讀寫你指定的卸除式卷宗上的瀏覽器下載、上傳與檔案內容。'
NETWORK_VOLUME_USAGE_DESCRIPTION='Tatwo Ultrawork 需要讀寫你指定的網路卷宗上的瀏覽器下載、上傳與檔案內容。'
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SHORT_TOKEN="$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -d- -f1)"
REFRESH_CEF_INDEX=false
if [[ "${TATWO_REFRESH_CEF_INDEX:-0}" == "1" ]]; then
  REFRESH_CEF_INDEX=true
elif [[ "${TATWO_REFRESH_CEF_INDEX:-0}" != "0" ]]; then
  printf '%s\n' 'error: TATWO_REFRESH_CEF_INDEX must be exactly 0 or 1' >&2
  exit 2
fi
tatwo_cef_initialize_runtime_configuration \
  "$CEF_CACHE_ROOT" \
  "$ROOT_DIR/Apps/TatwoUltraworkMac/CEF/cef-runtime-arm64.json" \
  false

say() {
  printf '%s\n' "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
}

require_command() {
  local command_name="$1"
  if command -v "$command_name" >/dev/null 2>&1; then
    say "tool_${command_name}=ok"
    return 0
  fi
  say "tool_${command_name}=missing"
  return 1
}

verify_pinned_node_binary_unchanged() {
  local phase="$1"
  local current_sha256

  if [[ -z "$NODE_BINARY" || -z "$NODE_BINARY_SHA256" ]]; then
    fail "pinned Node identity is unavailable during $phase"
    return 1
  fi
  if [[ ! -f "$NODE_BINARY" || -L "$NODE_BINARY" || ! -x "$NODE_BINARY" ]]; then
    fail "pinned Node binary is no longer a regular canonical executable: $NODE_BINARY"
    return 1
  fi
  current_sha256="$(/usr/bin/shasum -a 256 "$NODE_BINARY" | /usr/bin/awk '{print $1}')"
  if [[ "$current_sha256" != "$NODE_BINARY_SHA256" ]]; then
    fail "pinned Node binary changed during $phase"
    say "provenance_node_${phase}=changed"
    return 1
  fi
}

resolve_pinned_node_binary() {
  local candidate=""
  local canonical=""
  local codesign_detail=""

  if [[ -n "${TATWO_ULTRAWORK_NODE_BINARY:-}" ]]; then
    fail "TATWO_ULTRAWORK_NODE_BINARY overrides are forbidden for provenance root selection"
    say "provenance_node_resolution=override_forbidden"
    return 1
  elif [[ -e "/opt/homebrew/bin/node" ]]; then
    candidate="/opt/homebrew/bin/node"
  elif [[ -e "/usr/local/bin/node" ]]; then
    candidate="/usr/local/bin/node"
  else
    fail "no trusted fixed-path Node installation was found"
    say "provenance_node_resolution=missing"
    return 1
  fi
  case "$candidate" in
    /*) ;;
    *)
      fail "TATWO_ULTRAWORK_NODE_BINARY must be an absolute path"
      say "provenance_node_resolution=non_absolute"
      return 1
      ;;
  esac
  if ! canonical="$(
    /usr/bin/python3 - "$candidate" <<'PY'
import os
import sys

candidate = os.path.abspath(sys.argv[1])
if not os.path.exists(candidate):
    raise SystemExit(2)
canonical = os.path.realpath(candidate)
current = os.path.sep
for component in canonical.split(os.path.sep)[1:]:
    current = os.path.join(current, component)
    if os.path.islink(current):
        raise SystemExit(3)
print(canonical)
PY
  )"
  then
    fail "Node path could not be reduced to a canonical non-symlink path"
    say "provenance_node_resolution=canonicalization_failed"
    return 1
  fi
  case "$canonical" in
    /opt/homebrew/Cellar/node/*/bin/node|/usr/local/Cellar/node/*/bin/node) ;;
    *)
      fail "canonical Node path is outside trusted package roots: $canonical"
      say "provenance_node_resolution=untrusted_root"
      return 1
      ;;
  esac
  if [[ ! -f "$canonical" || -L "$canonical" || ! -x "$canonical" ]]; then
    fail "canonical Node path is not a regular executable: $canonical"
    say "provenance_node_resolution=invalid_binary"
    return 1
  fi
  if ! /usr/bin/codesign --verify --strict "$canonical"; then
    fail "canonical Node binary failed code-signature verification"
    say "provenance_node_resolution=invalid_signature"
    return 1
  fi
  codesign_detail="$(/usr/bin/codesign -d --verbose=4 "$canonical" 2>&1)"
  NODE_BINARY_CD_HASH="$(
    printf '%s\n' "$codesign_detail" \
      | /usr/bin/sed -n 's/^CDHash=//p' \
      | /usr/bin/head -n 1
  )"
  if [[ ! "$NODE_BINARY_CD_HASH" =~ ^[0-9a-f]{40}$ ]]; then
    fail "canonical Node binary has no stable CDHash identity"
    say "provenance_node_resolution=missing_cdhash"
    return 1
  fi
  NODE_BINARY="$canonical"
  NODE_BINARY_SHA256="$(
    /usr/bin/shasum -a 256 "$NODE_BINARY" | /usr/bin/awk '{print $1}'
  )"
  if [[ ! "$NODE_BINARY_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    fail "could not calculate canonical Node binary digest"
    say "provenance_node_resolution=missing_digest"
    return 1
  fi
  if ! NODE_VERSION="$(
    env -i \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
      LANG="C" \
      LC_ALL="C" \
      "$NODE_BINARY" --version
  )"
  then
    fail "canonical Node binary could not report its version"
    say "provenance_node_resolution=version_failed"
    return 1
  fi
  if [[ ! "$NODE_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    fail "canonical Node binary reported an invalid version: $NODE_VERSION"
    say "provenance_node_resolution=invalid_version"
    return 1
  fi
  verify_pinned_node_binary_unchanged "resolution" || return 1
  say "provenance_node_binary=$NODE_BINARY"
  say "provenance_node_sha256=$NODE_BINARY_SHA256"
  say "provenance_node_cdhash=$NODE_BINARY_CD_HASH"
  say "provenance_node_version=$NODE_VERSION"
}

# Detect a fixed signing identity via Keychain listing only (read-only).
# Priority: Developer ID Application -> Apple Development -> ad-hoc.
# TATWO_FORCE_ADHOC=1 forces the historical ad-hoc path for tests/rollback.
detect_signing_identity() {
  SIGNING_MODE="ad-hoc"
  SIGNING_IDENTITY="-"
  SIGNING_IDENTITY_NAME=""
  SIGNING_TEAM_ID=""
  SIGNING_LINE="signing=ad-hoc"

  if [[ "${TATWO_FORCE_ADHOC:-}" == "1" ]]; then
    SIGNING_LINE="signing=ad-hoc"
    say "$SIGNING_LINE"
    say "signing_force_adhoc=1"
    return 0
  fi

  local identities=""
  local identity_line=""
  local identity_name=""
  if [[ -n "${TATWO_INSTALL_TEST_CODESIGN_IDENTITIES:-}" ]]; then
    if [[ "${TATWO_INSTALL_DRY_RUN:-0}" != "1" ]]; then
      fail "TATWO_INSTALL_TEST_CODESIGN_IDENTITIES is allowed only for dry-run contract tests"
      return 1
    fi
    identities="$TATWO_INSTALL_TEST_CODESIGN_IDENTITIES"
    say "signing_identity_source=test-fixture"
  else
    identities="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
    say "signing_identity_source=keychain"
  fi

  identity_line="$(
    printf '%s\n' "$identities" \
      | /usr/bin/grep 'Developer ID Application:' \
      | /usr/bin/head -n 1 \
      || true
  )"
  if [[ -n "$identity_line" ]]; then
    identity_name="$(
      printf '%s\n' "$identity_line" \
        | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p'
    )"
  fi

  if [[ -n "$identity_name" ]]; then
    SIGNING_MODE="developer-id"
    SIGNING_IDENTITY="$identity_name"
    SIGNING_IDENTITY_NAME="$identity_name"
    SIGNING_LINE="signing=developer-id $identity_name"
    say "$SIGNING_LINE"
    return 0
  fi

  identity_line=""
  identity_name=""
  if [[ -n "${TATWO_APPLE_DEVELOPMENT_IDENTITY:-}" ]]; then
    identity_line="$(
      printf '%s\n' "$identities" \
        | /usr/bin/grep -F "\"$TATWO_APPLE_DEVELOPMENT_IDENTITY\"" \
        | /usr/bin/grep 'Apple Development:' \
        | /usr/bin/head -n 1 \
        || true
    )"
    if [[ -z "$identity_line" ]]; then
      fail "requested Apple Development identity is unavailable: $TATWO_APPLE_DEVELOPMENT_IDENTITY"
      return 1
    fi
  else
    identity_line="$(
      printf '%s\n' "$identities" \
        | /usr/bin/grep 'Apple Development:' \
        | /usr/bin/head -n 1 \
        || true
    )"
  fi
  if [[ -n "$identity_line" ]]; then
    identity_name="$(
      printf '%s\n' "$identity_line" \
        | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p'
    )"
  fi

  if [[ -n "$identity_name" ]]; then
    SIGNING_MODE="apple-development"
    SIGNING_IDENTITY="$identity_name"
    SIGNING_IDENTITY_NAME="$identity_name"
    SIGNING_LINE="signing=apple-development $identity_name"
    say "$SIGNING_LINE"
    say "signing_stability=fixed-local-identity"
    say "tcc_reauthorization=one-time-migration-if-previously-adhoc"
    return 0
  fi

  SIGNING_LINE="signing=ad-hoc"
  say "$SIGNING_LINE"
  say "signing_stability=unstable-no-fixed-identity"
}

requirements() {
  local missing=0
  local command_name

  if ! detect_signing_identity; then
    return 1
  fi
  case "$SIGNING_MODE" in
    developer-id)
      say "install_mode=local_developer_id"
      ;;
    apple-development)
      say "install_mode=local_apple_development"
      ;;
    *)
      say "install_mode=local_ad_hoc"
      ;;
  esac
  say "repo=$ROOT_DIR"
  say "app_dir=$APP_DIR"
  say "app_bundle=$APP_BUNDLE"
  if [[ -n "${TATWO_INSTALL_TARGET_DIR:-}" ]]; then
    say "install_target_override=$TATWO_INSTALL_TARGET_DIR"
  fi
  say "provenance_root=$PROVENANCE_ROOT"
  say "build_jobs=$BUILD_JOBS"
  say "installer_state_dir=$INSTALLER_STATE_DIR"
  say "staging_root=$STAGING_ROOT"
  say "archive_root=$ARCHIVE_ROOT"
  say "cef_cache_root=$CEF_CACHE_ROOT"
  if [[ "${TATWO_INSTALL_DRY_RUN:-}" == "1" ]]; then
    say "dry_run=1"
  fi

  for command_name in \
    swift git tar gzip python3 codesign otool install_name_tool plutil xcrun shasum curl ditto lipo
  do
    require_command "$command_name" || missing=1
  done

  if [[ "$missing" != "0" ]]; then
    fail "local App install requires the missing tools above"
    return 1
  fi
  if ! resolve_pinned_node_binary; then
    fail "local Candidate provenance requires a trusted pinned Node runtime"
    return 1
  fi
  if [[ "$BUILD_JOBS" != "2" ]]; then
    fail "local Candidate builds are hard-limited to TATWO_ULTRAWORK_BUILD_JOBS=2"
    return 1
  fi
  if [[ ! -f "$PROVENANCE_TOOL" ]]; then
    fail "local Candidate provenance tool is missing: $PROVENANCE_TOOL"
    return 1
  fi
  case "$APP_DIR" in
    /*) ;;
    *)
      fail "TATWO_INSTALL_TARGET_DIR/TATWO_ULTRAWORK_APP_DIR must be an absolute path: $APP_DIR"
      return 1
      ;;
  esac
  case "$PROVENANCE_ROOT" in
    /*) ;;
    *)
      fail "TATWO_ULTRAWORK_PROVENANCE_ROOT must be an absolute path: $PROVENANCE_ROOT"
      return 1
      ;;
  esac
  if [[ "${TATWO_INSTALL_STAGE_ONLY:-0}" != "1" ]]; then
    if [[ "$APP_BUNDLE" != "$TATWO_MAIN_APP_INSTALL_PATH" ]]; then
      fail "local-internal activation requires canonical App path: $TATWO_MAIN_APP_INSTALL_PATH"
      return 1
    fi
    if [[ "$INSTALLER_STATE_DIR" != "$CANONICAL_APP_SUPPORT_ROOT/local-app-install" ]]; then
      fail "local-internal activation requires canonical installer state root"
      return 1
    fi
    if [[ "$LOCAL_INTERNAL_ANCHOR_PATH" != "$INSTALLER_STATE_DIR/local-internal-install-anchor.json" ]]; then
      fail "local-internal anchor path drifted from the fixed installer root"
      return 1
    fi
  fi
}

existing_info_value() {
  local key="$1"
  local info_plist="$APP_BUNDLE/Contents/Info.plist"

  [[ -f "$info_plist" ]] || return 0
  /usr/libexec/PlistBuddy -c "Print :$key" "$info_plist" 2>/dev/null || true
}

resolve_bundle_versions() {
  local existing_version
  local existing_build

  existing_version="$(existing_info_value CFBundleShortVersionString)"
  existing_build="$(existing_info_value CFBundleVersion)"
  APP_VERSION="${TATWO_ULTRAWORK_APP_VERSION:-${existing_version:-0.1.0-local}}"
  APP_BUILD="${TATWO_ULTRAWORK_APP_BUILD:-${existing_build:-1}}"

  if [[ ! "$APP_BUILD" =~ ^[0-9]+(\.[0-9]+){0,3}$ ]]; then
    fail "TATWO_ULTRAWORK_APP_BUILD must be numeric: $APP_BUILD"
    return 1
  fi
  if [[ "$APP_VERSION" == *$'\n'* || "$MINIMUM_SYSTEM_VERSION" == *$'\n'* ]]; then
    fail "App version and minimum system version must be single-line values"
    return 1
  fi

  say "app_version=$APP_VERSION"
  say "app_build=$APP_BUILD"
}

capture_source_snapshot() {
  local state_json
  local source_commit

  if ! source_commit="$(git -C "$ROOT_DIR" rev-parse --verify HEAD)" \
    || ! state_json="$(
      TATWO_PROVENANCE_TMPDIR="${BUILD_TMPDIR:-${TATWO_PROVENANCE_TMPDIR:-${TMPDIR:-/tmp}}}" \
      run_pinned_node "$PROVENANCE_TOOL" source-state \
        --repo "$ROOT_DIR" \
        --commit "$source_commit"
    )"
  then
    fail "could not calculate a stable source snapshot"
    say "source_snapshot_capture=failed"
    return 1
  fi
  SOURCE_COMMIT="$(printf '%s' "$state_json" | run_pinned_node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).sourceCommit')"
  SOURCE_TREE="$(printf '%s' "$state_json" | run_pinned_node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).sourceTree')"
  SOURCE_DIRTY="$(printf '%s' "$state_json" | run_pinned_node -pe 'String(JSON.parse(require("fs").readFileSync(0,"utf8")).sourceDirty)')"
  say "source_snapshot_capture=passed"
}

verify_source_snapshot_unchanged() {
  local phase="$1"
  local state_json
  local current_commit
  local current_tree

  if ! state_json="$(
    TATWO_PROVENANCE_TMPDIR="${BUILD_TMPDIR:-${TATWO_PROVENANCE_TMPDIR:-${TMPDIR:-/tmp}}}" \
    run_pinned_node "$PROVENANCE_TOOL" source-state \
      --repo "$ROOT_DIR" \
      --commit "$SOURCE_COMMIT"
  )"
  then
    fail "could not verify source snapshot after $phase"
    say "source_snapshot_${phase}=failed"
    return 1
  fi
  current_commit="$(printf '%s' "$state_json" | run_pinned_node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).sourceCommit')"
  current_tree="$(printf '%s' "$state_json" | run_pinned_node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).sourceTree')"
  if [[ "$current_commit" != "$SOURCE_COMMIT" || "$current_tree" != "$SOURCE_TREE" ]]
  then
    fail "source snapshot changed during $phase; refusing to install stale provenance"
    say "source_snapshot_${phase}=changed"
    return 1
  fi
  say "source_snapshot_${phase}=passed"
}

prepare_provenance_run() {
  local stamp
  local snapshot_json

  stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
  RUN_ROOT="$PROVENANCE_ROOT/$stamp"
  SOURCE_PAYLOAD_DIR="$RUN_ROOT/source-payload"
  SOURCE_WORKSPACE="$RUN_ROOT/source-workspace"
  PROVENANCE_DIR="$RUN_ROOT/provenance"
  BUILD_PATH="$RUN_ROOT/build"
  BUILD_HOME="$RUN_ROOT/build-home"
  BUILD_TMPDIR="$RUN_ROOT/tmp"
  if [[ -e "$RUN_ROOT" ]]; then
    fail "unique Candidate run root already exists: $RUN_ROOT"
    return 1
  fi
  if ! mkdir -p "$PROVENANCE_DIR" "$BUILD_HOME" "$BUILD_TMPDIR"; then
    fail "could not create unique Candidate run root: $RUN_ROOT"
    return 1
  fi
  SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse --verify HEAD)"
  if ! snapshot_json="$(
    TATWO_PROVENANCE_TMPDIR="$BUILD_TMPDIR" \
      run_pinned_node "$PROVENANCE_TOOL" source-snapshot \
        --repo "$ROOT_DIR" \
        --commit "$SOURCE_COMMIT" \
        --output-dir "$SOURCE_PAYLOAD_DIR"
  )"
  then
    fail "could not create durable Candidate source payload"
    return 1
  fi
  SOURCE_TREE="$(printf '%s' "$snapshot_json" | run_pinned_node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).sourceTree')"
  SOURCE_DIRTY="$(printf '%s' "$snapshot_json" | run_pinned_node -pe 'String(JSON.parse(require("fs").readFileSync(0,"utf8")).sourceDirty)')"
  SOURCE_SNAPSHOT_PATH="$SOURCE_PAYLOAD_DIR/source-snapshot.json"
  SOURCE_TREE_MANIFEST_PATH="$SOURCE_PAYLOAD_DIR/source-tree-manifest.json"
  SOURCE_ARCHIVE_PATH="$SOURCE_PAYLOAD_DIR/source.tar.gz"
  SOURCE_SNAPSHOT_SHA256="$(/usr/bin/shasum -a 256 "$SOURCE_SNAPSHOT_PATH" | /usr/bin/awk '{print $1}')"
  SOURCE_TREE_MANIFEST_SHA256="$(/usr/bin/shasum -a 256 "$SOURCE_TREE_MANIFEST_PATH" | /usr/bin/awk '{print $1}')"
  if ! TATWO_PROVENANCE_TMPDIR="$BUILD_TMPDIR" \
    run_pinned_node "$PROVENANCE_TOOL" extract-source \
      --archive "$SOURCE_ARCHIVE_PATH" \
      --manifest "$SOURCE_TREE_MANIFEST_PATH" \
      --snapshot "$SOURCE_SNAPSHOT_PATH" \
      --expected-tree "$SOURCE_TREE" \
      --destination "$SOURCE_WORKSPACE" >/dev/null
  then
    fail "durable Candidate payload could not produce a clean source workspace"
    return 1
  fi
  if [[ -e "$SOURCE_WORKSPACE/.git" || -e "$BUILD_PATH" ]]; then
    fail "Candidate workspace/build root is not clean and unique"
    return 1
  fi
  BUILD_DEVELOPER_DIR="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
  BUILD_SDKROOT="$(
    DEVELOPER_DIR="$BUILD_DEVELOPER_DIR" \
      /usr/bin/xcrun --sdk macosx --show-sdk-path
  )"
  ANCHOR_HELPER_COMPILE_FLAGS=(
    "-Os"
    "-isysroot"
    "$BUILD_SDKROOT"
    "-mmacosx-version-min=$MINIMUM_SYSTEM_VERSION"
    "-framework"
    "Security"
    "-framework"
    "CoreFoundation"
  )
  say "candidate_run_root=$RUN_ROOT"
  say "source_payload=$SOURCE_PAYLOAD_DIR"
  say "source_workspace=$SOURCE_WORKSPACE"
  say "build_path=$BUILD_PATH"
  say "source_snapshot_sha256=$SOURCE_SNAPSHOT_SHA256"
  say "source_tree_manifest_sha256=$SOURCE_TREE_MANIFEST_SHA256"
  say "source_snapshot_capture=passed"
}

run_in_build_environment() {
  local environment_home="${BUILD_HOME:-$HOME}"
  local environment_tmpdir="${BUILD_TMPDIR:-${TATWO_PROVENANCE_TMPDIR:-${TMPDIR:-/tmp}}}"
  local environment_run_root="${RUN_ROOT:-$environment_tmpdir/tatwo-provenance-bootstrap}"
  local environment_developer_dir="${BUILD_DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
  local environment_sdkroot="${BUILD_SDKROOT:-$(
    DEVELOPER_DIR="$environment_developer_dir" \
      /usr/bin/xcrun --sdk macosx --show-sdk-path
  )}"

  /usr/bin/env -i \
    HOME="$environment_home" \
    TMPDIR="$environment_tmpdir" \
    TATWO_PROVENANCE_TMPDIR="$environment_tmpdir" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    LANG="C" \
    LC_ALL="C" \
    SOURCE_DATE_EPOCH="0" \
    DEVELOPER_DIR="$environment_developer_dir" \
    SDKROOT="$environment_sdkroot" \
    SWIFTPM_MODULECACHE_OVERRIDE="$environment_run_root/swiftpm-module-cache" \
    CLANG_MODULE_CACHE_PATH="$environment_run_root/clang-module-cache" \
    TATWO_ENABLE_CEF="${TATWO_ENABLE_CEF:-0}" \
    TATWO_CEF_ROOT="${TATWO_CEF_ROOT:-}" \
    TATWO_CEF_WRAPPER_LIBRARY="${TATWO_CEF_WRAPPER_LIBRARY:-}" \
    "$@"
}

run_pinned_node() {
  local rc=0

  verify_pinned_node_binary_unchanged "pre_invocation" || return 1
  run_in_build_environment "$NODE_BINARY" "$@" || rc=$?
  verify_pinned_node_binary_unchanged "post_invocation" || return 1
  return "$rc"
}

resolve_dependencies_and_capture_inputs() {
  local helper_manifest_args=()
  local helper_flag

  BUILD_INPUT_MANIFEST_PATH="$PROVENANCE_DIR/build-input-manifest.pre.json"
  say "dependency_resolve=started"
  if ! run_in_build_environment swift package resolve \
    --package-path "$SOURCE_WORKSPACE" \
    --scratch-path "$BUILD_PATH"
  then
    say "dependency_resolve=failed"
    return 1
  fi
  say "dependency_resolve=passed"
  for helper_flag in "${ANCHOR_HELPER_COMPILE_FLAGS[@]}"; do
    helper_manifest_args+=(--native-compile-flag "$helper_flag")
  done
  for helper_flag in "${ANCHOR_HELPER_STRIP_FLAGS[@]}"; do
    helper_manifest_args+=(--native-strip-flag "$helper_flag")
  done
  if ! run_pinned_node "$PROVENANCE_TOOL" build-input-manifest \
    --workspace "$SOURCE_WORKSPACE" \
    --source-snapshot "$SOURCE_SNAPSHOT_PATH" \
    --source-manifest "$SOURCE_TREE_MANIFEST_PATH" \
    --package-resolved "$SOURCE_WORKSPACE/Package.resolved" \
    --checkouts "$BUILD_PATH/checkouts" \
    --output "$BUILD_INPUT_MANIFEST_PATH" \
    --build-flag "--package-path=clean-source-workspace" \
    --build-flag "--scratch-path=unique-run-build" \
    --build-flag "--configuration=release" \
    --build-flag "--jobs=2" \
    --build-flag "--disable-automatic-resolution" \
    --build-flag "TATWO_ENABLE_CEF=1" \
    --native-source "$ANCHOR_HELPER_SOURCE_RELATIVE" \
    "${helper_manifest_args[@]}" \
    --provenance-node-binary "$NODE_BINARY" \
    --provenance-node-sha256 "$NODE_BINARY_SHA256" \
    --provenance-node-cdhash "$NODE_BINARY_CD_HASH" \
    --provenance-node-version "$NODE_VERSION" \
    --env "HOME=$BUILD_HOME" \
    --env "TMPDIR=$BUILD_TMPDIR" \
    --env "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
    --env "LANG=C" \
    --env "LC_ALL=C" \
    --env "SOURCE_DATE_EPOCH=0" \
    --env "DEVELOPER_DIR=$BUILD_DEVELOPER_DIR" \
    --env "SDKROOT=$BUILD_SDKROOT" \
    --env "SWIFTPM_MODULECACHE_OVERRIDE=$RUN_ROOT/swiftpm-module-cache" \
    --env "CLANG_MODULE_CACHE_PATH=$RUN_ROOT/clang-module-cache" \
    --env "TATWO_ENABLE_CEF=1" \
    --env "TATWO_CEF_ROOT=$TATWO_CEF_ROOT" \
    --env "TATWO_CEF_WRAPPER_LIBRARY=$TATWO_CEF_WRAPPER_LIBRARY" >/dev/null
  then
    say "build_input_manifest=failed"
    return 1
  fi
  BUILD_INPUT_MANIFEST_SHA256="$(
    /usr/bin/shasum -a 256 "$BUILD_INPUT_MANIFEST_PATH" | /usr/bin/awk '{print $1}'
  )"
  say "build_input_manifest=$BUILD_INPUT_MANIFEST_PATH"
  say "build_input_manifest_sha256=$BUILD_INPUT_MANIFEST_SHA256"
}

prepare_cef_build_runtime() {
  local pin_file="$SOURCE_WORKSPACE/Apps/TatwoUltraworkMac/CEF/cef-runtime-arm64.json"
  say "cef_runtime_prepare=started"
  tatwo_cef_initialize_runtime_configuration \
    "$CEF_CACHE_ROOT" "$pin_file" true
  prepare_cef_runtime
  if [[ "$CEF_PREPARED" != "true" \
    || "${TATWO_ENABLE_CEF:-0}" != "1" ]]
  then
    fail "formal build did not activate the verified pinned CEF runtime"
    say "cef_runtime_prepare=failed"
    return 1
  fi
  say "cef_runtime_prepare=passed"
  say "cef_runtime_root=$CEF_RUNTIME_ROOT"
  say "cef_wrapper_library=$CEF_WRAPPER_LIBRARY"
  say "cef_version=$CEF_VERSION"
  say "cef_chromium_version=$CEF_CHROMIUM_VERSION"
  say "cef_archive_sha256=$CEF_ARCHIVE_SHA256"
}

verify_build_input_manifest_unchanged() {
  local phase="$1"
  local current_path="$PROVENANCE_DIR/build-input-manifest.${phase}.json"
  local current_sha
  local helper_manifest_args=()
  local helper_flag

  for helper_flag in "${ANCHOR_HELPER_COMPILE_FLAGS[@]}"; do
    helper_manifest_args+=(--native-compile-flag "$helper_flag")
  done
  for helper_flag in "${ANCHOR_HELPER_STRIP_FLAGS[@]}"; do
    helper_manifest_args+=(--native-strip-flag "$helper_flag")
  done
  if ! run_pinned_node "$PROVENANCE_TOOL" build-input-manifest \
    --workspace "$SOURCE_WORKSPACE" \
    --source-snapshot "$SOURCE_SNAPSHOT_PATH" \
    --source-manifest "$SOURCE_TREE_MANIFEST_PATH" \
    --package-resolved "$SOURCE_WORKSPACE/Package.resolved" \
    --checkouts "$BUILD_PATH/checkouts" \
    --output "$current_path" \
    --build-flag "--package-path=clean-source-workspace" \
    --build-flag "--scratch-path=unique-run-build" \
    --build-flag "--configuration=release" \
    --build-flag "--jobs=2" \
    --build-flag "--disable-automatic-resolution" \
    --build-flag "TATWO_ENABLE_CEF=1" \
    --native-source "$ANCHOR_HELPER_SOURCE_RELATIVE" \
    "${helper_manifest_args[@]}" \
    --provenance-node-binary "$NODE_BINARY" \
    --provenance-node-sha256 "$NODE_BINARY_SHA256" \
    --provenance-node-cdhash "$NODE_BINARY_CD_HASH" \
    --provenance-node-version "$NODE_VERSION" \
    --env "HOME=$BUILD_HOME" \
    --env "TMPDIR=$BUILD_TMPDIR" \
    --env "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
    --env "LANG=C" \
    --env "LC_ALL=C" \
    --env "SOURCE_DATE_EPOCH=0" \
    --env "DEVELOPER_DIR=$BUILD_DEVELOPER_DIR" \
    --env "SDKROOT=$BUILD_SDKROOT" \
    --env "SWIFTPM_MODULECACHE_OVERRIDE=$RUN_ROOT/swiftpm-module-cache" \
    --env "CLANG_MODULE_CACHE_PATH=$RUN_ROOT/clang-module-cache" \
    --env "TATWO_ENABLE_CEF=1" \
    --env "TATWO_CEF_ROOT=$TATWO_CEF_ROOT" \
    --env "TATWO_CEF_WRAPPER_LIBRARY=$TATWO_CEF_WRAPPER_LIBRARY" >/dev/null
  then
    say "build_input_manifest_${phase}=failed"
    return 1
  fi
  current_sha="$(/usr/bin/shasum -a 256 "$current_path" | /usr/bin/awk '{print $1}')"
  if [[ "$current_sha" != "$BUILD_INPUT_MANIFEST_SHA256" ]]; then
    fail "closed-world build input manifest changed during $phase"
    say "build_input_manifest_${phase}=changed"
    return 1
  fi
  say "build_input_manifest_${phase}=passed"
}

build_products() {
  say "build_cef_helper=started"
  if ! run_in_build_environment swift build \
    --package-path "$SOURCE_WORKSPACE" \
    --build-path "$BUILD_PATH" \
    --product TatwoCEFHelper \
    -c release \
    --jobs "$BUILD_JOBS" \
    --disable-automatic-resolution
  then
    say "build_cef_helper=failed"
    return 1
  fi
  say "build_cef_helper=passed"

  say "build_cli=started"
  if ! run_in_build_environment swift build \
    --package-path "$SOURCE_WORKSPACE" \
    --build-path "$BUILD_PATH" \
    --product "$CLI_PRODUCT" \
    -c release \
    --jobs "$BUILD_JOBS" \
    --disable-automatic-resolution
  then
    say "build_cli=failed"
    return 1
  fi
  say "build_cli=passed"

  say "build_app=started"
  if ! run_in_build_environment swift build \
    --package-path "$SOURCE_WORKSPACE" \
    --build-path "$BUILD_PATH" \
    --product "$PRODUCT_NAME" \
    -c release \
    --jobs "$BUILD_JOBS" \
    --disable-automatic-resolution
  then
    say "build_app=failed"
    return 1
  fi

  if ! BUILD_BIN_PATH="$(run_in_build_environment swift build \
    --package-path "$SOURCE_WORKSPACE" \
    --build-path "$BUILD_PATH" \
    -c release \
    --jobs "$BUILD_JOBS" \
    --disable-automatic-resolution \
    --show-bin-path)"
  then
    say "build_app=failed_show_bin_path"
    return 1
  fi
  BUILD_BINARY="$BUILD_BIN_PATH/$PRODUCT_NAME"
  if [[ ! -x "$BUILD_BINARY" ]]; then
    fail "release App executable is missing: $BUILD_BINARY"
    say "build_app=failed_missing_executable"
    return 1
  fi
  say "build_app=passed"
  say "build_bin_path=$BUILD_BIN_PATH"
}

capture_build_output_manifest() {
  local manifest_args=()
  local relative
  local resource_bundle

  for relative in \
    "$PRODUCT_NAME" \
    "$CLI_PRODUCT" \
    "TatwoCEFHelper" \
    "Sparkle.framework"
  do
    if [[ ! -e "$BUILD_BIN_PATH/$relative" ]]; then
      fail "required build output is missing: $BUILD_BIN_PATH/$relative"
      return 1
    fi
    manifest_args+=(--path "$relative")
  done
  while IFS= read -r -d '' resource_bundle; do
    manifest_args+=(--path "$(basename "$resource_bundle")")
  done < <(
    find "$BUILD_BIN_PATH" -maxdepth 1 -type d -name "$RESOURCE_BUNDLE_GLOB" -print0
  )
  BUILD_OUTPUT_MANIFEST_PATH="$PROVENANCE_DIR/build-output-manifest.json"
  if ! run_pinned_node "$PROVENANCE_TOOL" fs-manifest \
    --root "$BUILD_BIN_PATH" \
    --output "$BUILD_OUTPUT_MANIFEST_PATH" \
    "${manifest_args[@]}" >/dev/null
  then
    say "build_output_manifest=failed"
    return 1
  fi
  BUILD_OUTPUT_MANIFEST_SHA256="$(
    /usr/bin/shasum -a 256 "$BUILD_OUTPUT_MANIFEST_PATH" | /usr/bin/awk '{print $1}'
  )"
  say "build_output_manifest=$BUILD_OUTPUT_MANIFEST_PATH"
  say "build_output_manifest_sha256=$BUILD_OUTPUT_MANIFEST_SHA256"
}

verify_build_output_unchanged() {
  local phase="$1"
  if ! run_pinned_node "$PROVENANCE_TOOL" verify-fs-manifest \
    --root "$BUILD_BIN_PATH" \
    --manifest "$BUILD_OUTPUT_MANIFEST_PATH" >/dev/null
  then
    fail "build output drift detected during $phase"
    say "build_output_manifest_${phase}=changed"
    return 1
  fi
  say "build_output_manifest_${phase}=passed"
}

prepare_staging() {
  local stamp

  if ! mkdir -p "$APP_DIR" "$INSTALLER_STATE_DIR" "$STAGING_ROOT" "$ARCHIVE_ROOT"; then
    fail "could not prepare local App, installer state, staging, or archive directories"
    return 1
  fi
  if ! tatwo_same_filesystem "$STAGING_ROOT" "$APP_BUNDLE" \
    || ! tatwo_same_filesystem "$ARCHIVE_ROOT" "$APP_BUNDLE"; then
    fail "staging, archive, and App directories must share one filesystem"
    return 1
  fi

  stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  STAGE_ROOT="$STAGING_ROOT/$stamp"
  STAGED_BUNDLE="$STAGE_ROOT/$TATWO_MAIN_APP_BUNDLE_FILENAME"
  if [[ -e "$STAGED_BUNDLE" ]]; then
    fail "staged App destination already exists: $STAGED_BUNDLE"
    return 1
  fi
  if ! mkdir -p \
    "$STAGED_BUNDLE/Contents/MacOS" \
    "$STAGED_BUNDLE/Contents/Resources" \
    "$STAGED_BUNDLE/Contents/Helpers" \
    "$STAGED_BUNDLE/Contents/Frameworks"
  then
    fail "could not create staged App layout"
    return 1
  fi
  say "stage_root=$STAGE_ROOT"
  say "staged_app=$STAGED_BUNDLE"
}

stage_resources() {
  local resource_bundle
  local copied_resource_bundles=0

  while IFS= read -r -d '' resource_bundle; do
    if ! cp -R "$resource_bundle" "$STAGED_BUNDLE/Contents/Resources/"; then
      fail "could not stage resource bundle: $resource_bundle"
      return 1
    fi
    say "staged_resource_bundle=$STAGED_BUNDLE/Contents/Resources/$(basename "$resource_bundle")"
    copied_resource_bundles=$((copied_resource_bundles + 1))
  done < <(
    find "$BUILD_BIN_PATH" -maxdepth 1 -type d -name "$RESOURCE_BUNDLE_GLOB" -print0
  )

  if [[ "$copied_resource_bundles" == "0" ]]; then
    fail "missing SwiftPM resource bundle matching $BUILD_BIN_PATH/$RESOURCE_BUNDLE_GLOB"
    return 1
  fi
  if ! bash "$SOURCE_WORKSPACE/scripts/stage-ipad-use-device.sh" \
    "$SOURCE_WORKSPACE/Device/iPadUseDevice" "$STAGED_BUNDLE/Contents/Resources/iPadUseDevice"; then
    fail "could not stage built-in TATWO iPad use device project"
    return 1
  fi
  say "staged_ipad_use_device=$STAGED_BUNDLE/Contents/Resources/iPadUseDevice"
  say "staged_resource_bundle_count=$copied_resource_bundles"
}

stage_cef_artifacts() {
  say "stage_cef_artifacts=started"
  if ! tatwo_cef_stage_app_artifacts \
    "$STAGED_BUNDLE" \
    "$PRODUCT_NAME" \
    "$BUILD_BIN_PATH" \
    "$CEF_RUNTIME_ROOT" \
    "$TATWO_MAIN_APP_NAME" \
    "$TATWO_MAIN_APP_BUNDLE_ID" \
    "$APP_VERSION" \
    "$APP_BUILD" \
    "$MINIMUM_SYSTEM_VERSION" \
    "$REMOVABLE_VOLUME_USAGE_DESCRIPTION" \
    "$NETWORK_VOLUME_USAGE_DESCRIPTION"
  then
    say "stage_cef_artifacts=failed"
    return 1
  fi
  say "stage_cef_artifacts=passed"
}

stage_optional_icon() {
  local source_icon="${TATWO_ULTRAWORK_APP_ICON:-}"
  local source_icon_real
  local workspace_real

  STAGED_ICON_FILENAME=""
  if [[ -z "$source_icon" ]]; then
    say "staged_icon=none"
    return 0
  fi
  if [[ ! -f "$source_icon" ]]; then
    fail "TATWO_ULTRAWORK_APP_ICON is not a readable file: $source_icon"
    return 1
  fi
  source_icon_real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$source_icon")"
  workspace_real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$SOURCE_WORKSPACE")"
  case "$source_icon_real" in
    "$workspace_real"/*) ;;
    *)
      fail "Candidate icon must be an immutable input inside the clean source workspace"
      return 1
      ;;
  esac
  if ! cp "$source_icon" "$STAGED_BUNDLE/Contents/Resources/"; then
    fail "could not stage App icon: $source_icon"
    return 1
  fi
  STAGED_ICON_FILENAME="$(basename "$source_icon")"
  say "staged_icon=$STAGED_BUNDLE/Contents/Resources/$STAGED_ICON_FILENAME"
}

stage_plg_anchor_helper() {
  local helper_path="$STAGED_BUNDLE/$ANCHOR_HELPER_RELATIVE"
  local helper_source="$SOURCE_WORKSPACE/$ANCHOR_HELPER_SOURCE_RELATIVE"

  if [[ ! -f "$helper_source" || -L "$helper_source" ]]; then
    fail "local PLG anchor helper source must be a regular non-symlink file: $helper_source"
    return 1
  fi
  say "stage_plg_anchor_helper=started"
  if ! run_in_build_environment /usr/bin/xcrun --sdk macosx clang \
    "${ANCHOR_HELPER_COMPILE_FLAGS[@]}" \
    "$helper_source" \
    -o "$helper_path"
  then
    say "stage_plg_anchor_helper=failed_compile"
    return 1
  fi
  if ! run_in_build_environment /usr/bin/xcrun --sdk macosx strip \
    "${ANCHOR_HELPER_STRIP_FLAGS[@]}" \
    "$helper_path"
  then
    say "stage_plg_anchor_helper=failed_strip"
    return 1
  fi
  if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    # Formal local path: same codesign flags as script/build_production_app.sh.
    if ! /usr/bin/codesign --force --options runtime --timestamp \
      --sign "$SIGNING_IDENTITY" \
      --identifier "$ANCHOR_HELPER_IDENTIFIER" \
      "$helper_path"
    then
      say "stage_plg_anchor_helper=failed_sign"
      return 1
    fi
  elif [[ "$SIGNING_MODE" == "apple-development" ]]; then
    if ! /usr/bin/codesign --force --timestamp=none \
      --sign "$SIGNING_IDENTITY" \
      --identifier "$ANCHOR_HELPER_IDENTIFIER" \
      "$helper_path"
    then
      say "stage_plg_anchor_helper=failed_sign"
      return 1
    fi
  else
    # Ad-hoc path must stay byte-stable relative to historical local install.
    if ! /usr/bin/codesign -s - --force --timestamp=none \
      --identifier "$ANCHOR_HELPER_IDENTIFIER" \
      "$helper_path"
    then
      say "stage_plg_anchor_helper=failed_sign"
      return 1
    fi
  fi
  say "stage_plg_anchor_helper=passed"
}

stage_model_runtimes() {
  say "stage_model_runtimes=started"
  if ! tatwo_stage_model_runtimes "$STAGED_BUNDLE"; then
    say "stage_model_runtimes=failed"
    return 1
  fi
  say "staged_model_runtime=$SUBSCRIPTION_RUNTIME"
  say "staged_model_runtime=$SUBSCRIPTION_CODE_MODE_HOST"
  say "staged_model_runtime=$CLAUDE_SUBSCRIPTION_RUNTIME"
  say "staged_model_runtime=$GROK_SUBSCRIPTION_RUNTIME"
  say "staged_model_runtime=$GROK_VENDOR_RUNTIME"
  say "staged_model_runtime_notice=$SUBSCRIPTION_NOTICES"
  say "staged_model_runtime_license=$CLAUDE_SUBSCRIPTION_LICENSE"
  say "stage_model_runtimes=passed"
}

embed_authority_provenance_inputs() {
  local destination="$STAGED_BUNDLE/$EMBEDDED_AUTHORITY_PROVENANCE_RELATIVE"
  local source_path
  local target_name
  local expected_sha256
  local actual_sha256

  if ! /bin/mkdir -p "$destination"; then
    fail "could not create embedded authority provenance directory"
    return 1
  fi
  while IFS='|' read -r source_path target_name expected_sha256; do
    if [[ ! -f "$source_path" || ! "$expected_sha256" =~ ^[0-9a-f]{64}$ ]]; then
      fail "authority provenance input is unavailable: $target_name"
      return 1
    fi
    if ! /bin/cp "$source_path" "$destination/$target_name"; then
      fail "could not embed authority provenance input: $target_name"
      return 1
    fi
    actual_sha256="$(
      /usr/bin/shasum -a 256 "$destination/$target_name" \
        | /usr/bin/awk '{print $1}'
    )"
    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
      fail "embedded authority provenance input digest mismatch: $target_name"
      return 1
    fi
  done <<EOF
$SOURCE_SNAPSHOT_PATH|TatwoSourceSnapshotV1.json|$SOURCE_SNAPSHOT_SHA256
$SOURCE_TREE_MANIFEST_PATH|TatwoSourceTreeManifestV1.json|$SOURCE_TREE_MANIFEST_SHA256
$BUILD_INPUT_MANIFEST_PATH|TatwoBuildInputManifestV1.json|$BUILD_INPUT_MANIFEST_SHA256
$BUILD_OUTPUT_MANIFEST_PATH|TatwoBuildOutputManifestV1.json|$BUILD_OUTPUT_MANIFEST_SHA256
EOF
  say "embedded_authority_provenance=$destination"
}

capture_bundle_content_manifest() {
  local embedded="$STAGED_BUNDLE/$EMBEDDED_BUNDLE_CONTENT_MANIFEST_RELATIVE"
  local result=""
  local embedded_sha256=""

  BUNDLE_CONTENT_MANIFEST_PATH="$PROVENANCE_DIR/bundle-content-manifest.json"
  if ! result="$(
    run_pinned_node "$PROVENANCE_TOOL" bundle-content-manifest \
      --bundle "$STAGED_BUNDLE" \
      --main-executable "Contents/MacOS/$PRODUCT_NAME" \
      --output "$BUNDLE_CONTENT_MANIFEST_PATH"
  )"
  then
    say "bundle_content_manifest=failed"
    return 1
  fi
  BUNDLE_CONTENT_MANIFEST_SHA256="$(
    /usr/bin/shasum -a 256 "$BUNDLE_CONTENT_MANIFEST_PATH" \
      | /usr/bin/awk '{print $1}'
  )"
  MAIN_EXECUTABLE_SHA256="$(
    printf '%s' "$result" \
      | run_pinned_node -pe \
        'JSON.parse(require("fs").readFileSync(0,"utf8")).mainExecutableSHA256'
  )"
  if [[ ! "$BUNDLE_CONTENT_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || [[ ! "$MAIN_EXECUTABLE_SHA256" =~ ^[0-9a-f]{64}$ ]]
  then
    fail "bundle content manifest did not expose valid pinned digests"
    say "bundle_content_manifest=invalid_digest"
    return 1
  fi
  if ! cp "$BUNDLE_CONTENT_MANIFEST_PATH" "$embedded"; then
    fail "could not embed bundle content manifest"
    say "bundle_content_manifest=failed_embed"
    return 1
  fi
  embedded_sha256="$(
    /usr/bin/shasum -a 256 "$embedded" | /usr/bin/awk '{print $1}'
  )"
  if [[ "$embedded_sha256" != "$BUNDLE_CONTENT_MANIFEST_SHA256" ]]; then
    fail "embedded bundle content manifest differs from the authority copy"
    say "bundle_content_manifest=failed_embed_readback"
    return 1
  fi
  if ! run_pinned_node "$PROVENANCE_TOOL" verify-bundle-content-manifest \
    --bundle "$STAGED_BUNDLE" \
    --manifest "$embedded" >/dev/null
  then
    fail "fresh bundle content manifest did not verify against staged bytes"
    say "bundle_content_manifest=failed_fresh_verify"
    return 1
  fi
  say "bundle_content_manifest=$BUNDLE_CONTENT_MANIFEST_PATH"
  say "bundle_content_manifest_sha256=$BUNDLE_CONTENT_MANIFEST_SHA256"
  say "main_executable_sha256=$MAIN_EXECUTABLE_SHA256"
}

verify_bundle_content_manifest_unchanged() {
  local phase="$1"
  local embedded="$STAGED_BUNDLE/$EMBEDDED_BUNDLE_CONTENT_MANIFEST_RELATIVE"

  if ! run_pinned_node "$PROVENANCE_TOOL" verify-bundle-content-manifest \
    --bundle "$STAGED_BUNDLE" \
    --manifest "$embedded" >/dev/null
  then
    fail "bundle content manifest drift detected during $phase"
    say "bundle_content_manifest_${phase}=changed"
    return 1
  fi
  say "bundle_content_manifest_${phase}=passed"
}

write_embedded_provenance() {
  local embedded="$STAGED_BUNDLE/Contents/Resources/TatwoCandidateProvenance.json"

  CANDIDATE_ID="$(
    printf '%s\n' \
      "$SOURCE_COMMIT" \
      "$SOURCE_TREE" \
      "$SOURCE_SNAPSHOT_SHA256" \
      "$SOURCE_TREE_MANIFEST_SHA256" \
      "$BUILD_INPUT_MANIFEST_SHA256" \
      "$BUILD_OUTPUT_MANIFEST_SHA256" \
      "$BUNDLE_CONTENT_MANIFEST_SHA256" \
      "$MAIN_EXECUTABLE_SHA256" \
      "$NODE_BINARY_SHA256" \
      "$NODE_BINARY_CD_HASH" \
      "$NODE_VERSION" \
      "$APP_VERSION" \
      "$APP_BUILD" \
      | /usr/bin/shasum -a 256 \
      | /usr/bin/awk '{print $1}'
  )"
  if ! run_pinned_node - \
    "$embedded" \
    "$CANDIDATE_ID" \
    "$SOURCE_COMMIT" \
    "$SOURCE_TREE" \
    "$SOURCE_DIRTY" \
    "$SOURCE_SNAPSHOT_SHA256" \
    "$SOURCE_TREE_MANIFEST_SHA256" \
    "$BUILD_INPUT_MANIFEST_SHA256" \
    "$BUILD_OUTPUT_MANIFEST_SHA256" \
    "$BUNDLE_CONTENT_MANIFEST_SHA256" \
    "$MAIN_EXECUTABLE_SHA256" \
    "$NODE_BINARY_SHA256" \
    "$NODE_BINARY_CD_HASH" \
    "$NODE_VERSION" <<'NODE'
const fs = require("fs");
const [
  output,
  candidateID,
  sourceCommit,
  sourceTree,
  sourceDirty,
  sourceSnapshotSHA256,
  sourceTreeManifestSHA256,
  buildInputManifestSHA256,
  buildOutputManifestSHA256,
  bundleContentManifestSHA256,
  mainExecutableSHA256,
  provenanceNodeSHA256,
  provenanceNodeCDHash,
  provenanceNodeVersion,
] = process.argv.slice(2);
const value = {
  buildInputManifestSHA256,
  buildOutputManifestSHA256,
  bundleContentManifestSHA256,
  candidateID,
  mainExecutableSHA256,
  provenanceNodeCDHash,
  provenanceNodeSHA256,
  provenanceNodeVersion,
  schema: "TatwoCandidateEmbeddedProvenanceV1",
  sourceCommit,
  sourceDirty: sourceDirty === "true",
  sourceSnapshotSHA256,
  sourceTree,
  sourceTreeManifestSHA256,
};
fs.writeFileSync(output, `${JSON.stringify(value)}\n`, { flag: "wx", mode: 0o600 });
NODE
  then
    fail "could not write embedded Candidate provenance"
    return 1
  fi
  EMBEDDED_PROVENANCE_SHA256="$(
    /usr/bin/shasum -a 256 "$embedded" | /usr/bin/awk '{print $1}'
  )"
  say "candidate_id=$CANDIDATE_ID"
  say "embedded_provenance_sha256=$EMBEDDED_PROVENANCE_SHA256"
}

write_info_plist() {
  local info_plist="$STAGED_BUNDLE/Contents/Info.plist"

  cat >"$info_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>$TATWO_MAIN_APP_NAME</string>
  <key>CFBundleExecutable</key><string>$PRODUCT_NAME</string>
  <key>CFBundleIdentifier</key><string>$TATWO_MAIN_APP_BUNDLE_ID</string>
  <key>CFBundleName</key><string>$TATWO_MAIN_APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0-local</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>NSPrincipalClass</key><string>$APP_PRINCIPAL_CLASS</string>
  <key>NSRemovableVolumesUsageDescription</key><string>$REMOVABLE_VOLUME_USAGE_DESCRIPTION</string>
  <key>NSNetworkVolumesUsageDescription</key><string>$NETWORK_VOLUME_USAGE_DESCRIPTION</string>
  <key>TatwoAutomaticUpdatesEnabled</key><false/>
  <key>TatwoBrowserEngine</key><string>chromium-cef</string>
  <key>TatwoBuildClass</key><string>local-internal</string>
  <key>TatwoBuildInputManifestSHA256</key><string>pending</string>
  <key>TatwoBuildOutputManifestSHA256</key><string>pending</string>
  <key>TatwoBundleContentManifestSHA256</key><string>pending</string>
  <key>TatwoCandidateID</key><string>pending</string>
  <key>TatwoCEFVersion</key><string>$CEF_VERSION</string>
  <key>TatwoCEFChromiumVersion</key><string>$CEF_CHROMIUM_VERSION</string>
  <key>TatwoCEFArchiveSHA256</key><string>$CEF_ARCHIVE_SHA256</string>
  <key>TatwoDistributionReady</key><false/>
  <key>TatwoEmbeddedProvenanceSHA256</key><string>pending</string>
  <key>TatwoPLGAnchorHelperSHA256</key><string>pending</string>
  <key>TatwoSubscriptionRuntimeVersion</key><string>$SUBSCRIPTION_RUNTIME_VERSION</string>
  <key>TatwoSubscriptionRuntimeSHA256</key><string>$SUBSCRIPTION_RUNTIME_SHA256</string>
  <key>TatwoSubscriptionCodeModeHostSHA256</key><string>$SUBSCRIPTION_CODE_MODE_HOST_SHA256</string>
  <key>TatwoClaudeSubscriptionRuntimeVersion</key><string>$CLAUDE_SUBSCRIPTION_RUNTIME_VERSION</string>
  <key>TatwoClaudeSubscriptionRuntimeSHA256</key><string>$CLAUDE_SUBSCRIPTION_RUNTIME_SHA256</string>
  <key>TatwoGrokSubscriptionRuntimeVersion</key><string>$GROK_SUBSCRIPTION_RUNTIME_VERSION</string>
  <key>TatwoGrokSubscriptionRuntimeSHA256</key><string>$GROK_SUBSCRIPTION_RUNTIME_SHA256</string>
  <key>TatwoGrokVendorRuntimeVersion</key><string>$GROK_VENDOR_RUNTIME_VERSION</string>
  <key>TatwoGrokVendorRuntimeSHA256</key><string>$GROK_VENDOR_RUNTIME_SHA256</string>
  <key>TatwoMainExecutableSHA256</key><string>pending</string>
  <key>TatwoProvenanceNodeCDHash</key><string>pending</string>
  <key>TatwoProvenanceNodeSHA256</key><string>pending</string>
  <key>TatwoProvenanceNodeVersion</key><string>pending</string>
  <key>TatwoSourceCommit</key><string>pending</string>
  <key>TatwoSourceDirty</key><false/>
  <key>TatwoSourceSnapshotSHA256</key><string>pending</string>
  <key>TatwoSourceTree</key><string>pending</string>
  <key>TatwoSourceTreeManifestSHA256</key><string>pending</string>
</dict>
</plist>
PLIST

  if ! /usr/bin/plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$info_plist" \
    || ! /usr/bin/plutil -replace CFBundleVersion -string "$APP_BUILD" "$info_plist" \
    || ! /usr/bin/plutil -replace LSMinimumSystemVersion -string "$MINIMUM_SYSTEM_VERSION" "$info_plist" \
    || ! /usr/bin/plutil -replace TatwoBuildInputManifestSHA256 -string "$BUILD_INPUT_MANIFEST_SHA256" "$info_plist" \
    || ! /usr/bin/plutil -replace TatwoBuildOutputManifestSHA256 -string "$BUILD_OUTPUT_MANIFEST_SHA256" "$info_plist" \
    || ! /usr/bin/plutil -replace TatwoBundleContentManifestSHA256 -string "$BUNDLE_CONTENT_MANIFEST_SHA256" "$info_plist" \
    || ! /usr/bin/plutil -replace TatwoCandidateID -string "$CANDIDATE_ID" "$info_plist" \
    || ! /usr/bin/plutil -replace TatwoEmbeddedProvenanceSHA256 -string "$EMBEDDED_PROVENANCE_SHA256" "$info_plist" \
    || ! /usr/bin/plutil -replace TatwoProvenanceNodeCDHash -string "$NODE_BINARY_CD_HASH" "$info_plist" \
    || ! /usr/bin/plutil -replace TatwoProvenanceNodeSHA256 -string "$NODE_BINARY_SHA256" "$info_plist" \
    || ! /usr/bin/plutil -replace TatwoProvenanceNodeVersion -string "$NODE_VERSION" "$info_plist" \
    || ! /usr/bin/plutil -replace TatwoMainExecutableSHA256 -string "$MAIN_EXECUTABLE_SHA256" "$info_plist" \
    || ! /usr/bin/plutil -replace TatwoSourceCommit -string "$SOURCE_COMMIT" "$info_plist" \
    || ! /usr/bin/plutil -replace TatwoSourceDirty -bool "$SOURCE_DIRTY" "$info_plist" \
    || ! /usr/bin/plutil -replace TatwoSourceSnapshotSHA256 -string "$SOURCE_SNAPSHOT_SHA256" "$info_plist" \
    || ! /usr/bin/plutil -replace TatwoSourceTree -string "$SOURCE_TREE" "$info_plist" \
    || ! /usr/bin/plutil -replace TatwoSourceTreeManifestSHA256 -string "$SOURCE_TREE_MANIFEST_SHA256" "$info_plist"
  then
    fail "could not write local App Info.plist values"
    return 1
  fi
  if [[ -n "$STAGED_ICON_FILENAME" ]]; then
    if ! /usr/bin/plutil -insert CFBundleIconFile \
      -string "${STAGED_ICON_FILENAME%.icns}" "$info_plist"
    then
      fail "could not write local App icon metadata"
      return 1
    fi
  fi
  if ! TATWO_UPDATE_FEED_URL="" \
    TATWO_UPDATE_PUBLIC_ED_KEY="" \
    TATWO_UPDATE_CHANNEL="" \
    tatwo_configure_sparkle_info_plist "$info_plist"
  then
    fail "could not disable Sparkle feed configuration for local App"
    return 1
  fi
  if ! plutil -lint "$info_plist" >/dev/null; then
    fail "local App Info.plist is invalid"
    return 1
  fi
  say "info_plist=$info_plist"
}

sign_staged_bundle_fixed_identity() {
  local helper_path="$STAGED_BUNDLE/$ANCHOR_HELPER_RELATIVE"
  local helper_sha256
  local verified_helper_sha256
  local sign_label="developer_id"
  local sparkle_mode="secure"
  local cef_mode="secure"
  local sign_args=(--force --options runtime --timestamp --sign "$SIGNING_IDENTITY")

  if [[ "$SIGNING_MODE" == "apple-development" ]]; then
    sign_label="apple_development"
    sparkle_mode="local-development"
    cef_mode="local-development"
    sign_args=(--force --timestamp=none --sign "$SIGNING_IDENTITY")
  fi

  say "${sign_label}_sign=started"
  say "signing_identity=$SIGNING_IDENTITY"
  if ! tatwo_codesign_embedded_sparkle \
    "$STAGED_BUNDLE" "$SIGNING_IDENTITY" "$sparkle_mode"
  then
    say "${sign_label}_sign=failed_sparkle"
    return 1
  fi
  local runtime_path
  for runtime_path in \
    "$SUBSCRIPTION_RUNTIME" \
    "$SUBSCRIPTION_CODE_MODE_HOST" \
    "$CLAUDE_SUBSCRIPTION_RUNTIME" \
    "$GROK_SUBSCRIPTION_RUNTIME" \
    "$GROK_VENDOR_RUNTIME"
  do
    if ! /usr/bin/codesign \
      "${sign_args[@]}" \
      "$runtime_path"
    then
      say "${sign_label}_sign=failed_model_runtime"
      return 1
    fi
  done
  if ! tatwo_cef_sign_nested_artifacts \
    "$STAGED_BUNDLE" "$SIGNING_IDENTITY" "$cef_mode"
  then
    say "${sign_label}_sign=failed_cef_nested"
    return 1
  fi

  helper_sha256="$(/usr/bin/shasum -a 256 "$helper_path" | /usr/bin/awk '{print $1}')"
  if [[ ! "$helper_sha256" =~ ^[0-9a-f]{64}$ ]]; then
    fail "could not calculate staged PLG anchor helper hash"
    say "${sign_label}_sign=failed_helper_hash"
    return 1
  fi
  tatwo_refresh_model_runtime_sha256
  if ! /usr/bin/plutil -replace TatwoPLGAnchorHelperSHA256 \
    -string "$helper_sha256" "$STAGED_BUNDLE/Contents/Info.plist" \
    || ! tatwo_write_model_runtime_info_plist_stamps \
      "$STAGED_BUNDLE/Contents/Info.plist"
  then
    say "${sign_label}_sign=failed_info_update"
    return 1
  fi
  if ! /usr/bin/codesign \
    "${sign_args[@]}" \
    "$STAGED_BUNDLE"
  then
    say "${sign_label}_sign=failed_final"
    return 1
  fi

  verified_helper_sha256="$(/usr/bin/shasum -a 256 "$helper_path" | /usr/bin/awk '{print $1}')"
  if [[ "$verified_helper_sha256" != "$helper_sha256" ]]; then
    fail "fixed-identity signing changed the PLG anchor helper after Info.plist was pinned"
    say "${sign_label}_sign=failed_helper_hash_changed"
    return 1
  fi
  if ! tatwo_verify_model_runtime_sha256; then
    say "${sign_label}_sign=failed_model_runtime_hash_changed"
    return 1
  fi
  say "${sign_label}_sign=passed"
  say "$SIGNING_LINE"
}

sign_staged_bundle() {
  local helper_path="$STAGED_BUNDLE/$ANCHOR_HELPER_RELATIVE"
  local helper_sha256
  local verified_helper_sha256

  if [[ "$SIGNING_MODE" == "developer-id" \
    || "$SIGNING_MODE" == "apple-development" ]]
  then
    sign_staged_bundle_fixed_identity
    return $?
  fi

  # Ad-hoc path: keep historical commands and order unchanged (zero regression).
  say "ad_hoc_sign=started"
  if ! tatwo_cef_sign_nested_artifacts "$STAGED_BUNDLE" - adhoc; then
    say "ad_hoc_sign=failed_cef_nested"
    return 1
  fi
  if ! /usr/bin/codesign -s - --deep --force --timestamp=none "$STAGED_BUNDLE"; then
    say "ad_hoc_sign=failed"
    return 1
  fi

  helper_sha256="$(/usr/bin/shasum -a 256 "$helper_path" | /usr/bin/awk '{print $1}')"
  if [[ ! "$helper_sha256" =~ ^[0-9a-f]{64}$ ]]; then
    fail "could not calculate staged PLG anchor helper hash"
    say "ad_hoc_sign=failed_helper_hash"
    return 1
  fi
  tatwo_refresh_model_runtime_sha256
  if ! /usr/bin/plutil -replace TatwoPLGAnchorHelperSHA256 \
    -string "$helper_sha256" "$STAGED_BUNDLE/Contents/Info.plist" \
    || ! tatwo_write_model_runtime_info_plist_stamps \
      "$STAGED_BUNDLE/Contents/Info.plist"
  then
    say "ad_hoc_sign=failed_info_update"
    return 1
  fi
  if ! /usr/bin/codesign -s - --force --timestamp=none "$STAGED_BUNDLE"; then
    say "ad_hoc_sign=failed_final"
    return 1
  fi

  verified_helper_sha256="$(/usr/bin/shasum -a 256 "$helper_path" | /usr/bin/awk '{print $1}')"
  if [[ "$verified_helper_sha256" != "$helper_sha256" ]]; then
    fail "deep ad-hoc signing changed the PLG anchor helper after Info.plist was pinned"
    say "ad_hoc_sign=failed_helper_hash_changed"
    return 1
  fi
  if ! tatwo_verify_model_runtime_sha256; then
    say "ad_hoc_sign=failed_model_runtime_hash_changed"
    return 1
  fi
  say "ad_hoc_sign=passed"
  say "$SIGNING_LINE"
}

codesign_team_identifier() {
  /usr/bin/codesign -d --verbose=4 "$1" 2>&1 \
    | /usr/bin/sed -n 's/^TeamIdentifier=//p' \
    | /usr/bin/head -n 1
}

codesign_leaf_authority_name() {
  /usr/bin/codesign -d --verbose=4 "$1" 2>&1 \
    | /usr/bin/sed -n 's/^Authority=//p' \
    | /usr/bin/head -n 1
}

verify_fixed_identity_bundle_tree() {
  local target
  local detail
  local target_team_id
  local target_authority
  local signed_code_count=0

  if [[ "$SIGNING_MODE" == "ad-hoc" ]]; then
    return 0
  fi

  SIGNING_TEAM_ID="$(codesign_team_identifier "$STAGED_BUNDLE")"
  if [[ -z "$SIGNING_TEAM_ID" || "$SIGNING_TEAM_ID" == "not set" ]]; then
    fail "fixed-identity App signature has no TeamIdentifier"
    say "fixed_identity_tree_verify=missing_team_identifier"
    return 1
  fi

  while IFS= read -r -d '' target; do
    detail="$(/usr/bin/codesign -d --verbose=4 "$target" 2>&1 || true)"
    if ! printf '%s\n' "$detail" | /usr/bin/grep -q '^Identifier='; then
      continue
    fi
    signed_code_count=$((signed_code_count + 1))
    target_team_id="$(
      printf '%s\n' "$detail" \
        | /usr/bin/sed -n 's/^TeamIdentifier=//p' \
        | /usr/bin/head -n 1
    )"
    target_authority="$(
      printf '%s\n' "$detail" \
        | /usr/bin/sed -n 's/^Authority=//p' \
        | /usr/bin/head -n 1
    )"
    if [[ "$target_team_id" != "$SIGNING_TEAM_ID" \
      || "$target_authority" != "$SIGNING_IDENTITY_NAME" ]]
    then
      fail "nested code identity mismatch: $target"
      say "fixed_identity_tree_verify=mismatch"
      say "fixed_identity_expected_team_id=$SIGNING_TEAM_ID"
      say "fixed_identity_actual_team_id=${target_team_id:--}"
      say "fixed_identity_expected_authority=$SIGNING_IDENTITY_NAME"
      say "fixed_identity_actual_authority=${target_authority:--}"
      return 1
    fi
  done < <(
    /usr/bin/find "$STAGED_BUNDLE/Contents" -type f \
      \( -perm -111 -o -name '*.dylib' \) -print0
  )

  if [[ "$signed_code_count" -lt 1 ]]; then
    fail "fixed-identity verification found no signed nested code"
    say "fixed_identity_tree_verify=no_signed_code"
    return 1
  fi
  say "signing_team_id=$SIGNING_TEAM_ID"
  say "fixed_identity_signed_code_count=$signed_code_count"
  say "fixed_identity_tree_verify=passed"
}

verify_staged_bundle() {
  local staged_identifier

  say "staged_bundle_verify=started"
  staged_identifier="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
      "$STAGED_BUNDLE/Contents/Info.plist"
  )"
  if [[ "$staged_identifier" != "$TATWO_MAIN_APP_BUNDLE_ID" ]]; then
    fail "staged App bundle identifier is not canonical: $staged_identifier"
    say "staged_bundle_verify=failed"
    return 1
  fi
  if ! tatwo_verify_staged_app_bundle \
    "$STAGED_BUNDLE" \
    "$PRODUCT_NAME" \
    "$RESOURCE_BUNDLE_GLOB"
  then
    say "staged_bundle_verify=failed"
    return 1
  fi
  if ! verify_cef_app_artifacts \
    "$STAGED_BUNDLE" \
    "$PRODUCT_NAME" \
    "$TATWO_MAIN_APP_BUNDLE_ID" \
    "$SIGNING_MODE" \
    "$SIGNING_IDENTITY_NAME" \
    "$REMOVABLE_VOLUME_USAGE_DESCRIPTION" \
    "$NETWORK_VOLUME_USAGE_DESCRIPTION"
  then
    say "staged_bundle_verify=failed_cef"
    return 1
  fi
  if ! verify_fixed_identity_bundle_tree; then
    say "staged_bundle_verify=failed_fixed_identity_tree"
    return 1
  fi
  say "staged_bundle_verify=passed"
}

capture_staged_bundle_identity() {
  STAGED_BUNDLE_MANIFEST_PATH="$PROVENANCE_DIR/staged-bundle-manifest.json"
  STAGED_BUNDLE_IDENTITY_PATH="$PROVENANCE_DIR/staged-bundle-identity.json"
  if ! run_pinned_node "$PROVENANCE_TOOL" fs-manifest \
    --root "$STAGED_BUNDLE" \
    --path "." \
    --output "$STAGED_BUNDLE_MANIFEST_PATH" >/dev/null
  then
    say "staged_bundle_manifest=failed"
    return 1
  fi
  STAGED_BUNDLE_MANIFEST_SHA256="$(
    /usr/bin/shasum -a 256 "$STAGED_BUNDLE_MANIFEST_PATH" | /usr/bin/awk '{print $1}'
  )"
  if ! run_pinned_node "$PROVENANCE_TOOL" bundle-identity \
    --bundle "$STAGED_BUNDLE" \
    --manifest "$STAGED_BUNDLE_MANIFEST_PATH" \
    --output "$STAGED_BUNDLE_IDENTITY_PATH" \
    --codesign-required "1" >/dev/null
  then
    say "staged_bundle_identity=failed"
    return 1
  fi
  STAGED_BUNDLE_IDENTITY_SHA256="$(
    /usr/bin/shasum -a 256 "$STAGED_BUNDLE_IDENTITY_PATH" | /usr/bin/awk '{print $1}'
  )"
  say "staged_bundle_manifest=$STAGED_BUNDLE_MANIFEST_PATH"
  say "forensic_staged_bundle_manifest_sha256=$STAGED_BUNDLE_MANIFEST_SHA256"
  say "staged_bundle_identity=$STAGED_BUNDLE_IDENTITY_PATH"
  say "forensic_staged_bundle_identity_sha256=$STAGED_BUNDLE_IDENTITY_SHA256"
}

verify_staged_bundle_unchanged() {
  local phase="$1"
  if ! run_pinned_node "$PROVENANCE_TOOL" verify-fs-manifest \
    --root "$STAGED_BUNDLE" \
    --manifest "$STAGED_BUNDLE_MANIFEST_PATH" >/dev/null
  then
    fail "staged bundle drift detected during $phase"
    say "staged_bundle_manifest_${phase}=changed"
    return 1
  fi
  say "staged_bundle_manifest_${phase}=passed"
}

verify_installed_readback() {
  local installed_manifest="$PROVENANCE_DIR/installed-bundle-manifest.json"
  local installed_identity="$PROVENANCE_DIR/installed-bundle-identity.json"
  local installed_identity_sha

  if ! run_pinned_node "$PROVENANCE_TOOL" verify-bundle-content-manifest \
    --bundle "$APP_BUNDLE" \
    --manifest \
      "$APP_BUNDLE/$EMBEDDED_BUNDLE_CONTENT_MANIFEST_RELATIVE" >/dev/null
  then
    fail "installed App cannot independently verify its embedded bundle content manifest"
    say "installed_readback=failed_bundle_content"
    return 1
  fi
  if ! run_pinned_node "$PROVENANCE_TOOL" fs-manifest \
    --root "$APP_BUNDLE" \
    --path "." \
    --output "$installed_manifest" >/dev/null
  then
    say "installed_readback=failed_manifest"
    return 1
  fi
  if ! /usr/bin/cmp -s "$installed_manifest" "$STAGED_BUNDLE_MANIFEST_PATH"; then
    fail "installed bundle manifest is not an exact staged Candidate readback"
    say "installed_readback=mismatch_manifest"
    return 1
  fi
  if ! run_pinned_node "$PROVENANCE_TOOL" bundle-identity \
    --bundle "$APP_BUNDLE" \
    --manifest "$installed_manifest" \
    --output "$installed_identity" \
    --codesign-required "1" >/dev/null
  then
    say "installed_readback=failed_identity"
    return 1
  fi
  installed_identity_sha="$(/usr/bin/shasum -a 256 "$installed_identity" | /usr/bin/awk '{print $1}')"
  if [[ "$installed_identity_sha" != "$STAGED_BUNDLE_IDENTITY_SHA256" ]] \
    || ! /usr/bin/cmp -s "$installed_identity" "$STAGED_BUNDLE_IDENTITY_PATH"
  then
    fail "installed Candidate identity does not exactly match staged identity"
    say "installed_readback=mismatch_identity"
    return 1
  fi
  say "installed_readback=passed"
  say "installed_identity_sha256=$installed_identity_sha"
}

candidate_context_is_complete() {
  local label="${1:-candidate context}"
  local actual_manifest_sha256
  local actual_identity_sha256
  local candidate_artifact

  if [[ ! "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
    || [[ ! "$SOURCE_TREE" =~ ^[0-9a-f]{40}$ ]] \
    || [[ "$SOURCE_DIRTY" != "true" && "$SOURCE_DIRTY" != "false" ]] \
    || [[ ! "$SOURCE_SNAPSHOT_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || [[ ! "$SOURCE_TREE_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || [[ ! "$BUILD_INPUT_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || [[ ! "$BUILD_OUTPUT_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || [[ ! "$BUNDLE_CONTENT_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || [[ ! "$MAIN_EXECUTABLE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || [[ ! "$EMBEDDED_PROVENANCE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || [[ ! "$NODE_BINARY_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || [[ ! "$NODE_BINARY_CD_HASH" =~ ^[0-9a-f]{40}$ ]] \
    || [[ -z "$NODE_VERSION" ]] \
    || [[ ! "$STAGED_BUNDLE_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || [[ ! "$STAGED_BUNDLE_IDENTITY_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || [[ ! "$CANDIDATE_ID" =~ ^[0-9a-f]{64}$ ]] \
    || [[ -z "$APP_VERSION" || -z "$APP_BUILD" ]]
  then
    fail "$label is incomplete; refusing to create or promote a receipt"
    say "candidate_classification=incomplete"
    return 1
  fi
  if [[ -z "$RUN_ROOT" || -z "$STAGING_ROOT" || -z "$STAGED_BUNDLE" ]] \
    || [[ "$STAGED_BUNDLE" == "$APP_BUNDLE" ]] \
    || [[ ! -d "$STAGED_BUNDLE" || -L "$STAGED_BUNDLE" ]]
  then
    fail "$label does not identify one separate regular staged Candidate"
    say "candidate_classification=invalid_staged_bundle"
    return 1
  fi
  case "$STAGED_BUNDLE" in
    "$STAGING_ROOT"/*) ;;
    *)
      fail "$label staged Candidate is outside the authoritative staging root"
      say "candidate_classification=outside_staging_root"
      return 1
      ;;
  esac
  for candidate_artifact in \
    "$STAGED_BUNDLE_MANIFEST_PATH" \
    "$STAGED_BUNDLE_IDENTITY_PATH"
  do
    if [[ ! -f "$candidate_artifact" || -L "$candidate_artifact" ]]; then
      fail "$label artifact is missing or unsafe: $candidate_artifact"
      say "candidate_classification=missing_verified_artifact"
      return 1
    fi
  done
  actual_manifest_sha256="$(
    /usr/bin/shasum -a 256 "$STAGED_BUNDLE_MANIFEST_PATH" \
      | /usr/bin/awk '{print $1}'
  )"
  actual_identity_sha256="$(
    /usr/bin/shasum -a 256 "$STAGED_BUNDLE_IDENTITY_PATH" \
      | /usr/bin/awk '{print $1}'
  )"
  if [[ "$actual_manifest_sha256" != "$STAGED_BUNDLE_MANIFEST_SHA256" ]] \
    || [[ "$actual_identity_sha256" != "$STAGED_BUNDLE_IDENTITY_SHA256" ]]
  then
    fail "$label artifact digest drifted"
    say "candidate_classification=forensic_artifact_drift"
    return 1
  fi
  if ! verify_pinned_node_binary_unchanged "candidate_classification"; then
    say "candidate_classification=provenance_node_drift"
    return 1
  fi
  return 0
}

mark_staged_candidate_verified() {
  if ! candidate_context_is_complete "staged Candidate"; then
    CANDIDATE_LIFECYCLE_STATE="invalid"
    return 1
  fi
  CANDIDATE_LIFECYCLE_STATE="verified-staged-candidate"
  say "candidate_classification=verified-staged-candidate"
}

require_verified_staged_candidate_context() {
  if [[ "$CANDIDATE_LIFECYCLE_STATE" != "verified-staged-candidate" ]]; then
    fail "fresh-shell or stale Candidate promotion is unsupported without verified rehydration"
    say "promotion=blocked_unverified_process_context"
    say "candidate_lifecycle_state=$CANDIDATE_LIFECYCLE_STATE"
    return 1
  fi
  candidate_context_is_complete "promotion context"
}

write_staged_candidate_receipt() {
  local receipt_path="$1"
  local generated_at
  local tmp_path="${receipt_path}.tmp.$$"

  if [[ "${TATWO_INSTALL_STAGE_ONLY:-0}" != "1" ]]; then
    fail "staged Candidate receipt requires TATWO_INSTALL_STAGE_ONLY=1"
    return 1
  fi
  if ! require_verified_staged_candidate_context; then
    say "staged_candidate_receipt=blocked_unverified_context"
    return 1
  fi
  generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ! /bin/cat >"$tmp_path" <<RECEIPT
schema=TatwoLocalAppStagedCandidateReceiptV1
artifact_class=staged-candidate
promotion_contract=fresh-shell-fail-closed
candidate_id=$CANDIDATE_ID
candidate_bundle=$STAGED_BUNDLE
candidate_run_root=$RUN_ROOT
app_version=$APP_VERSION
app_build=$APP_BUILD
source_commit=$SOURCE_COMMIT
source_tree=$SOURCE_TREE
source_dirty=$SOURCE_DIRTY
source_snapshot_sha256=$SOURCE_SNAPSHOT_SHA256
source_tree_manifest_sha256=$SOURCE_TREE_MANIFEST_SHA256
build_input_manifest_sha256=$BUILD_INPUT_MANIFEST_SHA256
build_output_manifest_sha256=$BUILD_OUTPUT_MANIFEST_SHA256
bundle_content_manifest_sha256=$BUNDLE_CONTENT_MANIFEST_SHA256
main_executable_sha256=$MAIN_EXECUTABLE_SHA256
embedded_provenance_sha256=$EMBEDDED_PROVENANCE_SHA256
provenance_node_sha256=$NODE_BINARY_SHA256
provenance_node_cdhash=$NODE_BINARY_CD_HASH
provenance_node_version=$NODE_VERSION
forensic_staged_bundle_manifest_sha256=$STAGED_BUNDLE_MANIFEST_SHA256
forensic_staged_bundle_identity_sha256=$STAGED_BUNDLE_IDENTITY_SHA256
stage_only=1
generated_at=$generated_at
RECEIPT
  then
    /bin/rm -f "$tmp_path" 2>/dev/null || true
    fail "could not stage the staged Candidate receipt"
    return 1
  fi
  if ! /bin/mv -f "$tmp_path" "$receipt_path"; then
    /bin/rm -f "$tmp_path" 2>/dev/null || true
    fail "could not commit the staged Candidate receipt"
    return 1
  fi
  say "staged_candidate_receipt=$receipt_path"
  say "artifact_class=staged-candidate"
}

write_install_receipt() {
  local receipt_path="$1"
  local receipt_filename="${2:-$(/usr/bin/basename "$receipt_path")}"
  local receipt_dir
  local distribution_label="local-internal-ad-hoc"
  local generated_at
  local tmp_path

  if [[ "${TATWO_INSTALL_STAGE_ONLY:-0}" != "0" ]]; then
    fail "installed-App receipt cannot be written for a stage-only Candidate"
    say "install_receipt=wrong_artifact_class"
    return 1
  fi
  if ! require_verified_staged_candidate_context; then
    say "install_receipt=blocked_unverified_context"
    return 1
  fi
  if ! ensure_install_receipt_identity; then
    say "install_receipt_identity=failed"
    return 1
  fi

  # Failure-injection: prove receipt/activation transaction never leaves
  # "App swapped but command reports failure" half-states (SOL-5 I-4 / H6).
  if [[ "${TATWO_INSTALL_FAIL_RECEIPT:-}" == "1" ]]; then
    fail "injected install receipt write failure (TATWO_INSTALL_FAIL_RECEIPT=1)"
    say "install_receipt=injected_failure"
    return 1
  fi

  case "$SIGNING_MODE" in
    developer-id)
      distribution_label="local-internal-developer-id"
      ;;
    apple-development)
      distribution_label="local-internal-apple-development"
      ;;
  esac
  generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  receipt_dir="$(dirname "$receipt_path")"
  if ! mkdir -p "$receipt_dir"; then
    fail "could not create install receipt directory: $receipt_dir"
    return 1
  fi
  # Stage via temp + rename so a partial cat never becomes the durable latest.
  tmp_path="${receipt_path}.tmp.$$"
  # Receipt V3 names the stage/install exact-readback digests as forensic.
  # They prove what this installer observed during this transaction, but are
  # not launch authority. The App independently re-verifies current bundle
  # content, Candidate provenance, code signature, and the receipt-bound
  # local-internal file anchor. Formal production continues to use Keychain.
  if ! cat >"$tmp_path" <<RECEIPT
schema=TatwoLocalAppInstallReceiptV3
receipt_id=$INSTALL_RECEIPT_ID
receipt_nonce=$INSTALL_RECEIPT_NONCE
receipt_filename=$receipt_filename
$SIGNING_LINE
signing_mode=$SIGNING_MODE
signing_identity=${SIGNING_IDENTITY_NAME:--}
signing_team_id=${SIGNING_TEAM_ID:--}
signing_stability=$([[ "$SIGNING_MODE" == "ad-hoc" ]] && printf unstable || printf fixed-identity)
force_adhoc=${TATWO_FORCE_ADHOC:-0}
dry_run=${TATWO_INSTALL_DRY_RUN:-0}
app_bundle=$APP_BUNDLE
app_version=${APP_VERSION:-}
app_build=${APP_BUILD:-}
source_commit=${SOURCE_COMMIT:-}
source_tree=${SOURCE_TREE:-}
source_dirty=${SOURCE_DIRTY:-}
candidate_id=${CANDIDATE_ID:-}
source_snapshot_sha256=${SOURCE_SNAPSHOT_SHA256:-}
source_tree_manifest_sha256=${SOURCE_TREE_MANIFEST_SHA256:-}
build_input_manifest_sha256=${BUILD_INPUT_MANIFEST_SHA256:-}
build_output_manifest_sha256=${BUILD_OUTPUT_MANIFEST_SHA256:-}
bundle_content_manifest_sha256=${BUNDLE_CONTENT_MANIFEST_SHA256:-}
main_executable_sha256=${MAIN_EXECUTABLE_SHA256:-}
embedded_provenance_sha256=${EMBEDDED_PROVENANCE_SHA256:-}
provenance_node_sha256=${NODE_BINARY_SHA256:-}
provenance_node_cdhash=${NODE_BINARY_CD_HASH:-}
provenance_node_version=${NODE_VERSION:-}
forensic_staged_bundle_manifest_sha256=${STAGED_BUNDLE_MANIFEST_SHA256:-}
forensic_staged_bundle_identity_sha256=${STAGED_BUNDLE_IDENTITY_SHA256:-}
stage_only=${TATWO_INSTALL_STAGE_ONLY:-0}
distribution=$distribution_label
generated_at=$generated_at
RECEIPT
  then
    rm -f "$tmp_path" 2>/dev/null || true
    fail "could not write install receipt staging file: $tmp_path"
    return 1
  fi
  if ! mv -f "$tmp_path" "$receipt_path"; then
    rm -f "$tmp_path" 2>/dev/null || true
    fail "could not commit install receipt: $receipt_path"
    return 1
  fi
  say "install_receipt=$receipt_path"
}

ensure_install_receipt_identity() {
  local identity_json

  if [[ -n "$INSTALL_RECEIPT_ID" ]]; then
    return 0
  fi
  if [[ ! "$CANDIDATE_ID" =~ ^[0-9a-f]{64}$ ]]; then
    fail "CandidateID is unavailable for install receipt identity"
    return 1
  fi
  if ! identity_json="$(
    run_pinned_node -e '
      const crypto = require("crypto");
      const candidateID = process.argv[1];
      const nonce = crypto.randomBytes(32).toString("hex");
      const receiptID = crypto
        .createHash("sha256")
        .update(`${candidateID}\n${nonce}\n`)
        .digest("hex");
      process.stdout.write(JSON.stringify({ nonce, receiptID }));
    ' "$CANDIDATE_ID"
  )"
  then
    fail "could not generate install receipt identity"
    return 1
  fi
  INSTALL_RECEIPT_ID="$(
    printf '%s' "$identity_json" \
      | run_pinned_node -pe \
        'JSON.parse(require("fs").readFileSync(0,"utf8")).receiptID'
  )"
  INSTALL_RECEIPT_NONCE="$(
    printf '%s' "$identity_json" \
      | run_pinned_node -pe \
        'JSON.parse(require("fs").readFileSync(0,"utf8")).nonce'
  )"
  if [[ ! "$INSTALL_RECEIPT_ID" =~ ^[0-9a-f]{64}$ ]] \
    || [[ ! "$INSTALL_RECEIPT_NONCE" =~ ^[0-9a-f]{64}$ ]]
  then
    fail "install receipt identity generator returned invalid values"
    return 1
  fi
  INSTALL_RECEIPT_FILENAME="local-app-install-$INSTALL_RECEIPT_ID.txt"
  say "install_receipt_id=$INSTALL_RECEIPT_ID"
  say "install_receipt_nonce=$INSTALL_RECEIPT_NONCE"
  say "install_receipt_filename=$INSTALL_RECEIPT_FILENAME"
}

write_install_receipt_pointer() {
  local receipt_path="$1"
  local pointer_path="$2"
  local receipt_sha256
  local tmp_path="${pointer_path}.tmp.$$"

  if [[ "$CANDIDATE_LIFECYCLE_STATE" != "installed-app-readback-verified" ]]; then
    fail "install receipt pointer requires installed-App readback in this process"
    say "install_receipt_pointer=blocked_unverified_installed_app"
    return 1
  fi
  if [[ ! -f "$receipt_path" || -L "$receipt_path" ]] \
    || ! /usr/bin/grep -Fx "schema=TatwoLocalAppInstallReceiptV3" \
      "$receipt_path" >/dev/null \
    || ! /usr/bin/grep -Fx "receipt_id=$INSTALL_RECEIPT_ID" \
      "$receipt_path" >/dev/null \
    || ! /usr/bin/grep -Fx "receipt_filename=$INSTALL_RECEIPT_FILENAME" \
      "$receipt_path" >/dev/null \
    || ! /usr/bin/grep -Fx "candidate_id=$CANDIDATE_ID" \
      "$receipt_path" >/dev/null \
    || ! /usr/bin/grep -Fx "app_bundle=$APP_BUNDLE" \
      "$receipt_path" >/dev/null \
    || ! /usr/bin/grep -Fx "stage_only=0" \
      "$receipt_path" >/dev/null
  then
    fail "refusing to point at an incomplete, staged, or mismatched receipt"
    say "install_receipt_pointer=blocked_receipt_classification"
    return 1
  fi
  if [[ "${TATWO_INSTALL_FAIL_RECEIPT_POINTER:-}" == "1" ]]; then
    fail "injected exact install receipt pointer failure"
    say "install_receipt_pointer=injected_failure"
    return 1
  fi
  receipt_sha256="$(
    /usr/bin/shasum -a 256 "$receipt_path" | /usr/bin/awk '{print $1}'
  )"
  if [[ ! "$receipt_sha256" =~ ^[0-9a-f]{64}$ ]]; then
    fail "could not calculate exact install receipt digest"
    return 1
  fi
  if ! /bin/cat >"$tmp_path" <<POINTER
schema=TatwoLocalAppInstallReceiptPointerV1
receipt_id=$INSTALL_RECEIPT_ID
receipt_filename=$INSTALL_RECEIPT_FILENAME
receipt_sha256=$receipt_sha256
candidate_id=$CANDIDATE_ID
POINTER
  then
    /bin/rm -f "$tmp_path" 2>/dev/null || true
    fail "could not stage exact install receipt pointer"
    return 1
  fi
  if ! /bin/mv -f "$tmp_path" "$pointer_path"; then
    /bin/rm -f "$tmp_path" 2>/dev/null || true
    fail "could not commit exact install receipt pointer"
    return 1
  fi
  say "install_receipt_pointer=$pointer_path"
  say "install_receipt_sha256=$receipt_sha256"
}

ensure_local_device_identity() {
  local device_id

  if ! device_id="$(
    /usr/bin/python3 - "$DEVICE_IDENTITY_PATH" <<'PY'
import json
import os
import re
import stat
import sys
import tempfile
import uuid

path = os.path.abspath(sys.argv[1])
parent = os.path.dirname(path)

def require_plain_path(directory):
    current = os.path.sep
    for component in directory.split(os.path.sep)[1:]:
        current = os.path.join(current, component)
        if os.path.lexists(current):
            st = os.lstat(current)
            if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
                raise SystemExit("device identity parent is not a plain directory")

os.makedirs(parent, mode=0o700, exist_ok=True)
require_plain_path(parent)

def read_identity():
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid():
            raise SystemExit("device identity must be a user-owned regular file")
        if st.st_size <= 0 or st.st_size > 16 * 1024:
            raise SystemExit("device identity size is invalid")
        if stat.S_IMODE(st.st_mode) & 0o022:
            raise SystemExit("device identity must not be group/other writable")
        chunks = []
        remaining = st.st_size
        while remaining:
            chunk = os.read(fd, remaining)
            if not chunk:
                raise SystemExit("device identity read was truncated")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)

if not os.path.lexists(path):
    payload = {
        "createdAt": __import__("datetime").datetime.now(
            __import__("datetime").timezone.utc
        ).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "deviceId": str(uuid.uuid4()),
        "name": os.uname().nodename,
    }
    data = json.dumps(
        payload, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    fd, temporary = tempfile.mkstemp(
        prefix=".device-identity.", suffix=".tmp", dir=parent
    )
    try:
        os.fchmod(fd, 0o600)
        offset = 0
        while offset < len(data):
            offset += os.write(fd, data[offset:])
        os.fsync(fd)
        os.close(fd)
        fd = -1
        try:
            os.link(temporary, path, follow_symlinks=False)
        except FileExistsError:
            pass
        directory_fd = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if fd >= 0:
            os.close(fd)
        if os.path.exists(temporary):
            os.unlink(temporary)

data = read_identity()
try:
    identity = json.loads(data)
except Exception as error:
    raise SystemExit(f"device identity JSON is invalid: {error}")
device_id = identity.get("deviceId")
if not isinstance(device_id, str) or not re.fullmatch(
    r"[A-Za-z0-9._:-]+", device_id
):
    raise SystemExit("device identity deviceId is invalid")
print(device_id)
PY
  )"
  then
    fail "could not safely create or read canonical device identity"
    say "local_internal_device_identity=failed"
    return 1
  fi
  DEVICE_ID="$device_id"
  say "local_internal_device_identity=passed"
  say "local_internal_device_id=$DEVICE_ID"
}

write_local_internal_install_anchor() {
  local receipt_path="$1"
  local pointer_path="$2"
  local anchor_path="${3:-$LOCAL_INTERNAL_ANCHOR_PATH}"

  if [[ "$CANDIDATE_LIFECYCLE_STATE" != "installed-app-pointer-committed" ]]; then
    fail "local-internal anchor requires exact installed-App receipt pointer"
    say "local_internal_install_anchor=blocked_without_pointer"
    return 1
  fi
  if ! ensure_local_device_identity; then
    return 1
  fi
  if [[ "${TATWO_INSTALL_FAIL_LOCAL_ANCHOR:-}" == "1" ]]; then
    fail "injected local-internal install anchor failure"
    say "local_internal_install_anchor=injected_failure"
    return 1
  fi
  if ! /usr/bin/python3 - \
    "$receipt_path" \
    "$pointer_path" \
    "$anchor_path" \
    "$APP_BUNDLE" \
    "$CANONICAL_STATE_ROOT" \
    "$DEVICE_ID" \
    "$CANDIDATE_ID" \
    "$INSTALL_RECEIPT_ID" \
    "$INSTALL_RECEIPT_FILENAME" <<'PY'
import datetime
import hashlib
import json
import os
import re
import stat
import sys
import tempfile

(
    receipt_path,
    pointer_path,
    anchor_path,
    app_path,
    state_root,
 ) = map(os.path.abspath, sys.argv[1:6])
device_id, candidate_id, receipt_id, receipt_filename = sys.argv[6:10]

hex64 = re.compile(r"[0-9a-f]{64}")
if not all(hex64.fullmatch(value) for value in (candidate_id, receipt_id)):
    raise SystemExit("candidate or receipt identity is malformed")
if receipt_filename != f"local-app-install-{receipt_id}.txt":
    raise SystemExit("receipt filename is not bound to the receipt ID")
if not re.fullmatch(r"[A-Za-z0-9._:-]+", device_id):
    raise SystemExit("device ID is malformed")

def require_plain_directory(directory):
    current = os.path.sep
    for component in directory.split(os.path.sep)[1:]:
        current = os.path.join(current, component)
        if os.path.lexists(current):
            st = os.lstat(current)
            if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
                raise SystemExit(f"non-plain directory in anchor path: {current}")

def read_regular(path, maximum, required_mode=None):
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid():
            raise SystemExit(f"unsafe user authority file: {path}")
        if required_mode is not None and stat.S_IMODE(st.st_mode) != required_mode:
            raise SystemExit(f"authority file mode mismatch: {path}")
        if st.st_size <= 0 or st.st_size > maximum:
            raise SystemExit(f"authority file size mismatch: {path}")
        chunks = []
        remaining = st.st_size
        while remaining:
            chunk = os.read(fd, remaining)
            if not chunk:
                raise SystemExit(f"truncated authority file: {path}")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)

def parse_key_values(data, expected_keys):
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise SystemExit("authority receipt is not UTF-8")
    values = {}
    for line in text.splitlines():
        if not line:
            continue
        if "=" not in line:
            raise SystemExit("authority receipt contains a malformed line")
        key, value = line.split("=", 1)
        if key in values:
            raise SystemExit("authority receipt contains a duplicate key")
        values[key] = value
    if set(values) != set(expected_keys):
        raise SystemExit("authority receipt field set mismatch")
    return values

receipt_data = read_regular(receipt_path, 1024 * 1024)
receipt_sha256 = hashlib.sha256(receipt_data).hexdigest()
pointer_data = read_regular(pointer_path, 64 * 1024)
pointer_sha256 = hashlib.sha256(pointer_data).hexdigest()
pointer = parse_key_values(
    pointer_data,
    (
        "schema",
        "receipt_id",
        "receipt_filename",
        "receipt_sha256",
        "candidate_id",
    ),
)
if (
    pointer["schema"] != "TatwoLocalAppInstallReceiptPointerV1"
    or pointer["receipt_id"] != receipt_id
    or pointer["receipt_filename"] != receipt_filename
    or pointer["receipt_sha256"] != receipt_sha256
    or pointer["candidate_id"] != candidate_id
):
    raise SystemExit("pointer does not bind the exact receipt and candidate")

receipt = parse_key_values(
    receipt_data,
    (
        "schema",
        "receipt_id",
        "receipt_nonce",
        "receipt_filename",
        "signing",
        "signing_mode",
        "signing_identity",
        "signing_team_id",
        "signing_stability",
        "force_adhoc",
        "dry_run",
        "app_bundle",
        "app_version",
        "app_build",
        "source_commit",
        "source_tree",
        "source_dirty",
        "candidate_id",
        "source_snapshot_sha256",
        "source_tree_manifest_sha256",
        "build_input_manifest_sha256",
        "build_output_manifest_sha256",
        "bundle_content_manifest_sha256",
        "main_executable_sha256",
        "embedded_provenance_sha256",
        "provenance_node_sha256",
        "provenance_node_cdhash",
        "provenance_node_version",
        "forensic_staged_bundle_manifest_sha256",
        "forensic_staged_bundle_identity_sha256",
        "stage_only",
        "distribution",
        "generated_at",
    ),
)
if (
    receipt["schema"] != "TatwoLocalAppInstallReceiptV3"
    or receipt["receipt_id"] != receipt_id
    or receipt["receipt_filename"] != receipt_filename
    or receipt["candidate_id"] != candidate_id
    or receipt["app_bundle"] != app_path
    or receipt["stage_only"] != "0"
    or receipt["dry_run"] != "0"
):
    raise SystemExit("receipt is not the exact installed-App authority")

anchor_parent = os.path.dirname(anchor_path)
os.makedirs(anchor_parent, mode=0o700, exist_ok=True)
require_plain_directory(anchor_parent)
previous_data = None
previous_anchor = None
if os.path.lexists(anchor_path):
    previous_data = read_regular(anchor_path, 64 * 1024, required_mode=0o600)
    try:
        previous_anchor = json.loads(previous_data)
    except Exception as error:
        raise SystemExit(f"existing anchor JSON is invalid: {error}")
    generation = previous_anchor.get("installGeneration")
    previous_digest = previous_anchor.get("previousAnchorSHA256")
    if (
        previous_anchor.get("schema") != "TatwoLocalInternalInstallAnchorV1"
        or not isinstance(generation, int)
        or isinstance(generation, bool)
        or generation <= 0
        or (
            generation == 1
            and previous_digest is not None
        )
        or (
            generation > 1
            and (
                not isinstance(previous_digest, str)
                or not hex64.fullmatch(previous_digest)
            )
        )
    ):
        raise SystemExit("existing anchor generation chain is invalid")
    install_generation = generation + 1
    previous_anchor_sha256 = hashlib.sha256(previous_data).hexdigest()
else:
    install_generation = 1
    previous_anchor_sha256 = None

created_at = (
    datetime.datetime.now(datetime.timezone.utc)
    .replace(microsecond=0)
    .isoformat()
    .replace("+00:00", "Z")
)
anchor = {
    "candidateID": candidate_id,
    "canonicalAppPath": app_path,
    "canonicalStateRoot": state_root,
    "createdAt": created_at,
    "deviceID": device_id,
    "installGeneration": install_generation,
    "pointerSHA256": pointer_sha256,
    "previousAnchorSHA256": previous_anchor_sha256,
    "receiptFilename": receipt_filename,
    "receiptID": receipt_id,
    "receiptSHA256": receipt_sha256,
    "schema": "TatwoLocalInternalInstallAnchorV1",
}
anchor_data = json.dumps(
    anchor, sort_keys=True, separators=(",", ":")
).encode("utf-8")
temporary_fd, temporary_path = tempfile.mkstemp(
    prefix=".local-internal-install-anchor.",
    suffix=".tmp",
    dir=anchor_parent,
)
try:
    os.fchmod(temporary_fd, 0o600)
    offset = 0
    while offset < len(anchor_data):
        offset += os.write(temporary_fd, anchor_data[offset:])
    os.fsync(temporary_fd)
    os.close(temporary_fd)
    temporary_fd = -1
    os.replace(temporary_path, anchor_path)
    directory_fd = os.open(anchor_parent, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
finally:
    if temporary_fd >= 0:
        os.close(temporary_fd)
    if os.path.exists(temporary_path):
        os.unlink(temporary_path)

readback = read_regular(anchor_path, 64 * 1024, required_mode=0o600)
if readback != anchor_data or json.loads(readback) != anchor:
    raise SystemExit("anchor atomic replacement read-back mismatch")
print(f"local_internal_install_generation={install_generation}")
print(f"local_internal_install_anchor_sha256={hashlib.sha256(readback).hexdigest()}")
PY
  then
    fail "could not commit local-internal install anchor"
    say "local_internal_install_anchor=failed"
    return 1
  fi
  say "local_internal_install_anchor=$anchor_path"
  say "local_internal_install_anchor=passed"
}

snapshot_local_install_authority() {
  local pointer_path="$1"
  local anchor_path="$2"
  local snapshot_dir="$3"

  if ! /usr/bin/python3 - \
    "$pointer_path" "$anchor_path" "$snapshot_dir" <<'PY'
import json
import os
import stat
import sys

pointer_path, anchor_path, snapshot_dir = map(os.path.abspath, sys.argv[1:4])
os.makedirs(snapshot_dir, mode=0o700, exist_ok=False)

def snapshot(name, path):
    if not os.path.lexists(path):
        return {"exists": False}
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid():
            raise SystemExit(f"unsafe pre-activation authority file: {path}")
        if st.st_size <= 0 or st.st_size > 1024 * 1024:
            raise SystemExit(f"pre-activation authority file size mismatch: {path}")
        if name == "anchor" and stat.S_IMODE(st.st_mode) != 0o600:
            raise SystemExit("existing local-internal anchor is not exact 0600")
        data = b""
        while len(data) < st.st_size:
            chunk = os.read(fd, st.st_size - len(data))
            if not chunk:
                raise SystemExit(f"truncated pre-activation authority file: {path}")
            data += chunk
    finally:
        os.close(fd)
    backup_path = os.path.join(snapshot_dir, f"{name}.bytes")
    backup_fd = os.open(
        backup_path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        0o600,
    )
    try:
        offset = 0
        while offset < len(data):
            offset += os.write(backup_fd, data[offset:])
        os.fsync(backup_fd)
    finally:
        os.close(backup_fd)
    return {
        "exists": True,
        "mode": stat.S_IMODE(st.st_mode),
        "size": len(data),
    }

manifest = {
    "anchor": snapshot("anchor", anchor_path),
    "pointer": snapshot("pointer", pointer_path),
}
manifest_path = os.path.join(snapshot_dir, "manifest.json")
manifest_data = json.dumps(
    manifest, sort_keys=True, separators=(",", ":")
).encode("utf-8")
manifest_fd = os.open(
    manifest_path,
    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
    0o600,
)
try:
    offset = 0
    while offset < len(manifest_data):
        offset += os.write(manifest_fd, manifest_data[offset:])
    os.fsync(manifest_fd)
finally:
    os.close(manifest_fd)
PY
  then
    fail "could not snapshot pre-activation pointer and anchor"
    say "local_install_authority_snapshot=failed"
    return 1
  fi
  say "local_install_authority_snapshot=$snapshot_dir"
}

restore_local_install_authority_snapshot() {
  local pointer_path="$1"
  local anchor_path="$2"
  local snapshot_dir="$3"
  local quarantine_dir="$INSTALLER_STATE_DIR/receipts/invalidated-authority"

  if ! /usr/bin/python3 - \
    "$pointer_path" "$anchor_path" "$snapshot_dir" "$quarantine_dir" <<'PY'
import json
import os
import stat
import sys
import tempfile
import time

pointer_path, anchor_path, snapshot_dir, quarantine_dir = map(
    os.path.abspath, sys.argv[1:5]
)
with open(os.path.join(snapshot_dir, "manifest.json"), "rb") as source:
    manifest = json.load(source)
os.makedirs(quarantine_dir, mode=0o700, exist_ok=True)

def atomic_write(path, data, mode):
    parent = os.path.dirname(path)
    os.makedirs(parent, mode=0o700, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".authority-restore.", dir=parent)
    try:
        os.fchmod(fd, mode)
        offset = 0
        while offset < len(data):
            offset += os.write(fd, data[offset:])
        os.fsync(fd)
        os.close(fd)
        fd = -1
        os.replace(temporary, path)
        directory_fd = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if fd >= 0:
            os.close(fd)
        if os.path.exists(temporary):
            os.unlink(temporary)

def restore(name, path):
    record = manifest[name]
    if record["exists"]:
        with open(os.path.join(snapshot_dir, f"{name}.bytes"), "rb") as source:
            data = source.read()
        if len(data) != record["size"]:
            raise SystemExit(f"{name} authority backup size drift")
        atomic_write(path, data, int(record["mode"]))
        st = os.lstat(path)
        if (
            not stat.S_ISREG(st.st_mode)
            or stat.S_IMODE(st.st_mode) != int(record["mode"])
            or st.st_uid != os.geteuid()
        ):
            raise SystemExit(f"{name} authority metadata restore mismatch")
        with open(path, "rb") as source:
            if source.read() != data:
                raise SystemExit(f"{name} authority byte restore mismatch")
    elif os.path.lexists(path):
        quarantine = os.path.join(
            quarantine_dir,
            f"{int(time.time())}-{os.getpid()}-{name}-rollback-invalidated",
        )
        os.replace(path, quarantine)

restore("pointer", pointer_path)
restore("anchor", anchor_path)
PY
  then
    fail "could not restore exact pre-activation pointer and anchor"
    say "local_install_authority_restore=failed"
    return 1
  fi
  say "local_install_authority_restore=passed"
}

quarantine_local_install_authority() {
  local pointer_path="$1"
  local anchor_path="$2"
  local reason="$3"
  local quarantine_dir="$INSTALLER_STATE_DIR/receipts/invalidated-authority"
  local path
  local label
  local destination
  local failed=0

  if ! /bin/mkdir -p "$quarantine_dir"; then
    fail "could not create pointer/anchor quarantine"
    return 1
  fi
  for label in pointer anchor; do
    if [[ "$label" == "pointer" ]]; then
      path="$pointer_path"
    else
      path="$anchor_path"
    fi
    if [[ ! -e "$path" && ! -L "$path" ]]; then
      continue
    fi
    destination="$quarantine_dir/$(date -u +%Y%m%dT%H%M%SZ)-$$-$reason-$label"
    if /bin/mv "$path" "$destination"; then
      say "local_install_authority_${label}_quarantine=$destination"
    else
      /bin/chmod 000 "$path" 2>/dev/null || true
      fail "could not quarantine $label authority; forced unreadable mode"
      failed=1
    fi
  done
  if [[ "$failed" != "0" ]]; then
    say "local_install_authority_quarantine=degraded_fail_closed"
    return 1
  fi
  say "local_install_authority_quarantine=passed"
}

quarantine_new_install_receipt() {
  local receipt_path="$1"
  local reason="$2"
  local quarantine_dir="$INSTALLER_STATE_DIR/receipts/invalidated-receipts"
  local destination

  if [[ ! -e "$receipt_path" && ! -L "$receipt_path" ]]; then
    return 0
  fi
  /bin/mkdir -p "$quarantine_dir" || return 1
  destination="$quarantine_dir/$(date -u +%Y%m%dT%H%M%SZ)-$$-$reason-$(
    /usr/bin/basename "$receipt_path"
  )"
  if /bin/mv "$receipt_path" "$destination"; then
    say "install_receipt_quarantine=$destination"
    return 0
  fi
  fail "could not quarantine new install receipt: $receipt_path"
  return 1
}

invalidate_install_receipt_pointer() {
  local pointer_path="$1"
  local reason="$2"
  local quarantine_dir="$INSTALLER_STATE_DIR/receipts/invalidated-pointers"
  local quarantine_path

  if [[ ! -e "$pointer_path" && ! -L "$pointer_path" ]]; then
    say "install_receipt_pointer_invalidation=not_present"
    return 0
  fi
  if ! /bin/mkdir -p "$quarantine_dir"; then
    fail "could not create install pointer quarantine"
    return 1
  fi
  quarantine_path="$quarantine_dir/$(date -u +%Y%m%dT%H%M%SZ)-$$-$reason.txt"
  if /bin/mv "$pointer_path" "$quarantine_path"; then
    say "install_receipt_pointer_invalidation=quarantined"
    say "install_receipt_pointer_quarantine=$quarantine_path"
    return 0
  fi
  fail "could not quarantine stale install receipt pointer; leaving it untouched"
  say "install_receipt_pointer_invalidation=failed"
  return 1
}

# Best-effort restore of the previous App bundle after a post-activation
# receipt failure. Uses the newest previous archive under ARCHIVE_ROOT.
rollback_activated_bundle_after_receipt_failure() {
  local previous=""
  local failed_hold

  say "activation_rollback=started"
  if [[ ! -d "$APP_BUNDLE" ]]; then
    fail "activation rollback skipped: active bundle missing ($APP_BUNDLE)"
    say "activation_rollback=skipped_no_active"
    return 1
  fi
  previous="$(
    /bin/ls -1dt "$ARCHIVE_ROOT"/*-previous-*.bundle-archive 2>/dev/null | /usr/bin/head -n 1 || true
  )"
  if [[ -z "$previous" || ! -e "$previous" ]]; then
    fail "activation rollback failed: no previous archive under $ARCHIVE_ROOT"
    say "activation_rollback=failed_no_previous"
    return 1
  fi
  failed_hold="$ARCHIVE_ROOT/receipt-commit-failed-$(date -u +%Y%m%dT%H%M%SZ)-$$.bundle-archive"
  if ! mv "$APP_BUNDLE" "$failed_hold"; then
    fail "activation rollback failed: could not move live App aside"
    say "activation_rollback=failed_aside"
    return 1
  fi
  if ! mv "$previous" "$APP_BUNDLE"; then
    fail "activation rollback failed: could not restore $previous"
    # Try to put the new bundle back so the tree is not empty.
    mv "$failed_hold" "$APP_BUNDLE" 2>/dev/null || true
    say "activation_rollback=failed_restore"
    return 1
  fi
  tatwo_refresh_launchservices "$APP_BUNDLE" 2>/dev/null || true
  say "activation_rollback=passed"
  say "activation_rollback_restored_from=$previous"
  say "activation_rollback_failed_hold=$failed_hold"
  CANDIDATE_LIFECYCLE_STATE="rolled-back"
  return 0
}

rollback_local_install_transaction() {
  local reason="$1"
  local staged_receipt="$2"
  local final_receipt="$3"
  local receipt_pointer="$4"
  local authority_snapshot="$5"

  if rollback_activated_bundle_after_receipt_failure; then
    if restore_local_install_authority_snapshot \
      "$receipt_pointer" \
      "$LOCAL_INTERNAL_ANCHOR_PATH" \
      "$authority_snapshot"
    then
      quarantine_new_install_receipt \
        "$staged_receipt" "$reason-staged" || true
      quarantine_new_install_receipt \
        "$final_receipt" "$reason-final" || true
      CANDIDATE_LIFECYCLE_STATE="rolled-back-authority-restored"
      say "local_install_transaction_rollback=passed"
      return 0
    fi
    quarantine_local_install_authority \
      "$receipt_pointer" \
      "$LOCAL_INTERNAL_ANCHOR_PATH" \
      "$reason-authority-restore-failed" || true
    CANDIDATE_LIFECYCLE_STATE="rolled-back-authority-invalid"
    say "local_install_transaction_rollback=app_restored_authority_fail_closed"
    return 1
  fi

  quarantine_local_install_authority \
    "$receipt_pointer" \
    "$LOCAL_INTERNAL_ANCHOR_PATH" \
    "$reason-app-rollback-failed" || true
  CANDIDATE_LIFECYCLE_STATE="installed-app-authority-invalid"
  say "local_install_transaction_rollback=failed_authority_quarantined"
  return 1
}

commit_local_internal_anchor_or_rollback() {
  local staged_receipt="$1"
  local final_receipt="$2"
  local receipt_pointer="$3"
  local authority_snapshot="$4"

  if write_local_internal_install_anchor \
    "$final_receipt" \
    "$receipt_pointer" \
    "$LOCAL_INTERNAL_ANCHOR_PATH"
  then
    return 0
  fi

  fail "local-internal install anchor commit failed; attempting automatic rollback"
  say "activation=local_internal_anchor_commit_failed"
  if rollback_local_install_transaction \
    "local-internal-anchor-commit-failed" \
    "$staged_receipt" \
    "$final_receipt" \
    "$receipt_pointer" \
    "$authority_snapshot"
  then
    say "install_app_local=rolled_back_after_local_internal_anchor_failure"
    return 1
  fi
  say "install_app_local=anchor_commit_and_rollback_failed"
  return 1
}

activate_staged_bundle() {
  local receipt_pointer="$INSTALLER_STATE_DIR/receipts/latest-local-app-install.txt"
  local final_receipt
  local staged_receipt
  local authority_snapshot

  say "activation=started"
  if ! require_verified_staged_candidate_context; then
    say "activation=not_started_unverified_candidate"
    return 1
  fi
  if ! ensure_install_receipt_identity; then
    say "activation=not_started_receipt_identity_failed"
    return 1
  fi
  final_receipt="$INSTALLER_STATE_DIR/receipts/$INSTALL_RECEIPT_FILENAME"
  staged_receipt="$INSTALLER_STATE_DIR/receipts/pending-$INSTALL_RECEIPT_ID.txt"
  authority_snapshot="$RUN_ROOT/pre-activation-local-install-authority-$INSTALL_RECEIPT_ID"
  # Transaction bind (SOL-5 I-4): durable staged receipt MUST succeed before
  # live App mutation. Avoids "App already swapped, command returns failure"
  # when the only failing step is the post-activate receipt write.
  if ! write_install_receipt "$staged_receipt" "$INSTALL_RECEIPT_FILENAME"; then
    say "activation=not_started_receipt_stage_failed"
    rm -f "$staged_receipt" 2>/dev/null || true
    return 1
  fi
  say "install_receipt_staged=$staged_receipt"
  if ! ensure_local_device_identity; then
    say "activation=not_started_device_identity_failed"
    quarantine_new_install_receipt \
      "$staged_receipt" "device-identity-failed" || true
    return 1
  fi
  if ! snapshot_local_install_authority \
    "$receipt_pointer" \
    "$LOCAL_INTERNAL_ANCHOR_PATH" \
    "$authority_snapshot"
  then
    say "activation=not_started_authority_snapshot_failed"
    quarantine_new_install_receipt \
      "$staged_receipt" "authority-snapshot-failed" || true
    return 1
  fi

  if ! TATWO_ULTRAWORK_ARCHIVE_ROOT="$ARCHIVE_ROOT" \
    tatwo_activate_staged_app_bundle \
      "$STAGED_BUNDLE" \
      "$APP_BUNDLE" \
      "$INSTALLER_STATE_DIR" \
      "$PRODUCT_NAME" \
      "$RESOURCE_BUNDLE_GLOB"
  then
    say "activation=failed"
    rm -f "$staged_receipt" 2>/dev/null || true
    return 1
  fi
  say "activation=passed"
  say "installed_app=$APP_BUNDLE"
  CANDIDATE_LIFECYCLE_STATE="installed-app-unverified"
  if ! verify_installed_readback; then
    fail "installed readback mismatch after activation; attempting automatic rollback"
    say "activation=installed_readback_failed"
    if rollback_local_install_transaction \
      "installed-readback-failed" \
      "$staged_receipt" \
      "$final_receipt" \
      "$receipt_pointer" \
      "$authority_snapshot"
    then
      say "install_app_local=rolled_back_after_installed_readback_mismatch"
      return 1
    fi
    say "install_app_local=installed_readback_and_rollback_failed"
    return 1
  fi
  CANDIDATE_LIFECYCLE_STATE="installed-app-readback-verified"
  say "artifact_class=installed-app"
  case "$SIGNING_MODE" in
    developer-id)
      say "distribution=local-internal-developer-id"
      ;;
    apple-development)
      say "distribution=local-internal-apple-development"
      ;;
    *)
      say "distribution=local-internal-ad-hoc"
      ;;
  esac
  say "$SIGNING_LINE"

  if ! mv -f "$staged_receipt" "$final_receipt"; then
    fail "install receipt commit failed after activation; attempting automatic rollback"
    say "activation=receipt_commit_failed"
    if rollback_local_install_transaction \
      "receipt-commit-failed" \
      "$staged_receipt" \
      "$final_receipt" \
      "$receipt_pointer" \
      "$authority_snapshot"
    then
      say "install_app_local=rolled_back_after_receipt_commit_failure"
      return 1
    fi
    say "install_receipt_orphaned_staged=$staged_receipt"
    say "install_app_local=activation_passed_receipt_commit_and_rollback_failed"
    return 1
  fi
  if ! write_install_receipt_pointer "$final_receipt" "$receipt_pointer"; then
    fail "exact install receipt pointer commit failed; attempting automatic rollback"
    say "activation=receipt_pointer_commit_failed"
    if rollback_local_install_transaction \
      "receipt-pointer-commit-failed" \
      "$staged_receipt" \
      "$final_receipt" \
      "$receipt_pointer" \
      "$authority_snapshot"
    then
      say "install_app_local=rolled_back_after_receipt_pointer_failure"
      return 1
    fi
    say "install_app_local=receipt_pointer_and_rollback_failed"
    return 1
  fi
  CANDIDATE_LIFECYCLE_STATE="installed-app-pointer-committed"
  if ! commit_local_internal_anchor_or_rollback \
    "$staged_receipt" \
    "$final_receipt" \
    "$receipt_pointer" \
    "$authority_snapshot"
  then
    return 1
  fi
  CANDIDATE_LIFECYCLE_STATE="installed-app-anchor-committed"
  say "pointer_class=installed-app-current"
  say "install_receipt=$final_receipt"
  say "local_internal_install_anchor=$LOCAL_INTERNAL_ANCHOR_PATH"
}

# Isolated receipt/activation transaction selftest (no real build/codesign).
# Exercises TATWO_INSTALL_FAIL_RECEIPT=1 → activation never starts.
run_receipt_activation_transaction_selftest() {
  local tmp_root
  local rc=0

  tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/tatwo-install-receipt-tx.XXXXXX")"
  # macOS exposes /var as a symlink to /private/var. The production authority
  # paths are canonical /Users paths, while mktemp may return the /var alias.
  # Canonicalize only this isolated selftest root so the path-hardening checks
  # exercise real directories instead of failing on the system alias.
  tmp_root="$(
    /usr/bin/python3 -c \
      'import os,sys; print(os.path.realpath(sys.argv[1]))' \
      "$tmp_root"
  )"
  # shellcheck disable=SC2064
  trap "rm -rf \"$tmp_root\"" RETURN

  CANONICAL_APP_SUPPORT_ROOT="$tmp_root/app-support"
  CANONICAL_STATE_ROOT="$CANONICAL_APP_SUPPORT_ROOT/state"
  DEVICE_IDENTITY_PATH="$CANONICAL_APP_SUPPORT_ROOT/device-identity.json"
  INSTALLER_STATE_DIR="$CANONICAL_APP_SUPPORT_ROOT/local-app-install"
  LOCAL_INTERNAL_ANCHOR_PATH="$INSTALLER_STATE_DIR/local-internal-install-anchor.json"
  ARCHIVE_ROOT="$tmp_root/archives"
  APP_BUNDLE="$tmp_root/Applications/Tatwo Ultrawork.app"
  STAGED_BUNDLE="$tmp_root/staging/Tatwo Ultrawork.app"
  STAGING_ROOT="$tmp_root/staging"
  RUN_ROOT="$tmp_root/run"
  PROVENANCE_DIR="$RUN_ROOT/provenance"
  BUILD_HOME="$tmp_root/home"
  BUILD_TMPDIR="$tmp_root/tmp"
  BUILD_DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"
  BUILD_SDKROOT="$(
    DEVELOPER_DIR="$BUILD_DEVELOPER_DIR" \
      /usr/bin/xcrun --sdk macosx --show-sdk-path
  )"
  CANDIDATE_ID="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  SOURCE_COMMIT="1111111111111111111111111111111111111111"
  SOURCE_TREE="2222222222222222222222222222222222222222"
  SOURCE_DIRTY="false"
  SOURCE_SNAPSHOT_SHA256="$(printf '1%.0s' {1..64})"
  SOURCE_TREE_MANIFEST_SHA256="$(printf '2%.0s' {1..64})"
  BUILD_INPUT_MANIFEST_SHA256="$(printf '3%.0s' {1..64})"
  BUILD_OUTPUT_MANIFEST_SHA256="$(printf '4%.0s' {1..64})"
  BUNDLE_CONTENT_MANIFEST_SHA256="$(printf '5%.0s' {1..64})"
  MAIN_EXECUTABLE_SHA256="$(printf '6%.0s' {1..64})"
  EMBEDDED_PROVENANCE_SHA256="$(printf '7%.0s' {1..64})"
  APP_VERSION="0.1.10"
  APP_BUILD="24"
  INSTALL_RECEIPT_ID=""
  INSTALL_RECEIPT_NONCE=""
  INSTALL_RECEIPT_FILENAME=""
  /bin/mkdir -p "$INSTALLER_STATE_DIR/receipts" "$ARCHIVE_ROOT" \
    "$PROVENANCE_DIR" "$BUILD_HOME" "$BUILD_TMPDIR" "$STAGED_BUNDLE" \
    "$(/usr/bin/dirname "$APP_BUNDLE")" \
    "$(/usr/bin/dirname "$STAGED_BUNDLE")"
  STAGED_BUNDLE_MANIFEST_PATH="$PROVENANCE_DIR/staged-bundle-manifest.json"
  STAGED_BUNDLE_IDENTITY_PATH="$PROVENANCE_DIR/staged-bundle-identity.json"
  /usr/bin/printf '%s\n' '{"schema":"TatwoFilesystemManifestV2"}' \
    >"$STAGED_BUNDLE_MANIFEST_PATH"
  /usr/bin/printf '%s\n' '{"schema":"TatwoCandidateBundleIdentityV1"}' \
    >"$STAGED_BUNDLE_IDENTITY_PATH"
  STAGED_BUNDLE_MANIFEST_SHA256="$(
    /usr/bin/shasum -a 256 "$STAGED_BUNDLE_MANIFEST_PATH" \
      | /usr/bin/awk '{print $1}'
  )"
  STAGED_BUNDLE_IDENTITY_SHA256="$(
    /usr/bin/shasum -a 256 "$STAGED_BUNDLE_IDENTITY_PATH" \
      | /usr/bin/awk '{print $1}'
  )"
  CANDIDATE_LIFECYCLE_STATE="verified-staged-candidate"

  # 1) A fresh shell has no process-bound verified Candidate context. It must
  # fail before writing a pending receipt or invoking the real activation.
  if ! (
    CANDIDATE_LIFECYCLE_STATE="uninitialized"
    /usr/bin/printf '%s\n' "prior-pointer-must-survive" \
      >"$INSTALLER_STATE_DIR/receipts/latest-local-app-install.txt"
    if activate_staged_bundle; then
      echo "selftest_fresh_shell_promotion_unexpected_success" >&2
      exit 2
    fi
    if /usr/bin/find "$INSTALLER_STATE_DIR/receipts" \
      -maxdepth 1 -name 'pending-*.txt' -print -quit \
      | /usr/bin/grep -q .
    then
      echo "selftest_fresh_shell_created_pending_receipt" >&2
      exit 3
    fi
    /usr/bin/grep -Fx "prior-pointer-must-survive" \
      "$INSTALLER_STATE_DIR/receipts/latest-local-app-install.txt" >/dev/null
    say "receipt_tx_selftest_fresh_shell_fail_closed=passed"
  ); then
    rc=1
  fi
  /bin/rm -f "$INSTALLER_STATE_DIR/receipts/latest-local-app-install.txt"

  # 2) Stage-only output has a distinct schema/class and cannot be promoted
  # into the installed-App pointer.
  if ! (
    TATWO_INSTALL_STAGE_ONLY=1
    export TATWO_INSTALL_STAGE_ONLY
    CANDIDATE_LIFECYCLE_STATE="verified-staged-candidate"
    staged_candidate_receipt="$RUN_ROOT/staged-candidate-receipt.txt"
    write_staged_candidate_receipt "$staged_candidate_receipt"
    /usr/bin/grep -Fx \
      "schema=TatwoLocalAppStagedCandidateReceiptV1" \
      "$staged_candidate_receipt" >/dev/null
    /usr/bin/grep -Fx "artifact_class=staged-candidate" \
      "$staged_candidate_receipt" >/dev/null
    /usr/bin/grep -Fx "candidate_bundle=$STAGED_BUNDLE" \
      "$staged_candidate_receipt" >/dev/null
    if /usr/bin/grep -q '^app_bundle=' "$staged_candidate_receipt"; then
      echo "selftest_staged_candidate_claimed_installed_bundle" >&2
      exit 4
    fi
    CANDIDATE_LIFECYCLE_STATE="installed-app-readback-verified"
    /usr/bin/printf '%s\n' "prior-pointer-must-survive" \
      >"$INSTALLER_STATE_DIR/receipts/latest-local-app-install.txt"
    if write_install_receipt_pointer \
      "$staged_candidate_receipt" \
      "$INSTALLER_STATE_DIR/receipts/latest-local-app-install.txt"
    then
      echo "selftest_staged_receipt_pointer_unexpected_success" >&2
      exit 5
    fi
    /usr/bin/grep -Fx "prior-pointer-must-survive" \
      "$INSTALLER_STATE_DIR/receipts/latest-local-app-install.txt" >/dev/null
    say "receipt_tx_selftest_artifact_classes=passed"
  ); then
    rc=1
  fi
  unset TATWO_INSTALL_STAGE_ONLY || true
  /bin/rm -f "$INSTALLER_STATE_DIR/receipts/latest-local-app-install.txt"
  CANDIDATE_LIFECYCLE_STATE="verified-staged-candidate"

  # 3) Incomplete Candidate state cannot produce any installed-App receipt.
  if ! (
    BUNDLE_CONTENT_MANIFEST_SHA256=""
    if write_install_receipt \
      "$INSTALLER_STATE_DIR/receipts/incomplete-local-app-install.txt"
    then
      echo "selftest_incomplete_receipt_unexpected_success" >&2
      exit 6
    fi
    if [[ -e "$INSTALLER_STATE_DIR/receipts/incomplete-local-app-install.txt" ]]; then
      echo "selftest_incomplete_receipt_was_written" >&2
      exit 7
    fi
    say "receipt_tx_selftest_incomplete_receipt_fail_closed=passed"
  ); then
    rc=1
  fi

  # 4) Injection: receipt stage fails → activate must not run.
  if ! (
    TATWO_INSTALL_FAIL_RECEIPT=1
    export TATWO_INSTALL_FAIL_RECEIPT
    # Inline the stage-first gate without calling real activate.
    if write_install_receipt "$INSTALLER_STATE_DIR/receipts/pending-local-app-install.txt"; then
      echo "selftest_unexpected_receipt_success" >&2
      exit 2
    fi
    if [[ -e "$APP_BUNDLE" ]]; then
      echo "selftest_app_bundle_mutated_on_receipt_fail" >&2
      exit 3
    fi
    say "receipt_tx_selftest_injection=passed"
    exit 0
  ); then
    rc=1
  fi

  # 5) Happy path for installed receipt + exact pointer.
  unset TATWO_INSTALL_FAIL_RECEIPT || true
  CANDIDATE_LIFECYCLE_STATE="verified-staged-candidate"
  if ensure_install_receipt_identity \
    && write_install_receipt \
      "$INSTALLER_STATE_DIR/receipts/pending-$INSTALL_RECEIPT_ID.txt" \
      "$INSTALL_RECEIPT_FILENAME" \
    && /bin/mv \
      "$INSTALLER_STATE_DIR/receipts/pending-$INSTALL_RECEIPT_ID.txt" \
      "$INSTALLER_STATE_DIR/receipts/$INSTALL_RECEIPT_FILENAME" \
    && /usr/bin/printf '%s\n' "prior-pointer-must-survive" \
      >"$INSTALLER_STATE_DIR/receipts/latest-local-app-install.txt" \
    && CANDIDATE_LIFECYCLE_STATE="installed-app-readback-verified" \
    && ! (
      TATWO_INSTALL_FAIL_RECEIPT_POINTER=1
      export TATWO_INSTALL_FAIL_RECEIPT_POINTER
      write_install_receipt_pointer \
        "$INSTALLER_STATE_DIR/receipts/$INSTALL_RECEIPT_FILENAME" \
        "$INSTALLER_STATE_DIR/receipts/latest-local-app-install.txt"
    ) \
    && /usr/bin/grep -Fx "prior-pointer-must-survive" \
      "$INSTALLER_STATE_DIR/receipts/latest-local-app-install.txt" >/dev/null \
    && say "receipt_tx_selftest_prior_pointer_preserved=passed" \
    && write_install_receipt_pointer \
      "$INSTALLER_STATE_DIR/receipts/$INSTALL_RECEIPT_FILENAME" \
      "$INSTALLER_STATE_DIR/receipts/latest-local-app-install.txt" \
    && /usr/bin/grep -Fx "receipt_id=$INSTALL_RECEIPT_ID" \
      "$INSTALLER_STATE_DIR/receipts/$INSTALL_RECEIPT_FILENAME" >/dev/null \
    && /usr/bin/grep -Fx "receipt_filename=$INSTALL_RECEIPT_FILENAME" \
      "$INSTALLER_STATE_DIR/receipts/latest-local-app-install.txt" >/dev/null
  then
    say "receipt_tx_selftest_stage_write=passed"
    say "receipt_tx_selftest_exact_pointer=passed"
  else
    fail "receipt_tx_selftest_stage_write failed"
    rc=1
  fi

  # 6) The local-internal anchor commits after the pointer, advances an exact
  # raw-byte generation chain, fails atomically under injection, and restores
  # both authority bytes and metadata from the pre-activation snapshot.
  if ! (
    local receipt_path="$INSTALLER_STATE_DIR/receipts/$INSTALL_RECEIPT_FILENAME"
    local pointer_path="$INSTALLER_STATE_DIR/receipts/latest-local-app-install.txt"
    local first_anchor_sha
    local pointer_sha
    local anchor_sha
    local authority_snapshot="$RUN_ROOT/selftest-authority-snapshot"

    CANDIDATE_LIFECYCLE_STATE="installed-app-pointer-committed"
    write_local_internal_install_anchor \
      "$receipt_path" "$pointer_path" "$LOCAL_INTERNAL_ANCHOR_PATH" \
      || exit 9
    [[ "$(/usr/bin/stat -f %Lp "$LOCAL_INTERNAL_ANCHOR_PATH")" == "600" ]] \
      || exit 10
    [[ "$(
      /usr/bin/python3 -c \
        'import json,sys; print(json.load(open(sys.argv[1]))["installGeneration"])' \
        "$LOCAL_INTERNAL_ANCHOR_PATH"
    )" == "1" ]] || exit 11
    first_anchor_sha="$(
      /usr/bin/shasum -a 256 "$LOCAL_INTERNAL_ANCHOR_PATH" \
        | /usr/bin/awk '{print $1}'
    )"
    [[ "$first_anchor_sha" =~ ^[0-9a-f]{64}$ ]] || exit 12

    write_local_internal_install_anchor \
      "$receipt_path" "$pointer_path" "$LOCAL_INTERNAL_ANCHOR_PATH" \
      || exit 13
    [[ "$(
      /usr/bin/python3 -c \
        'import json,sys; print(json.load(open(sys.argv[1]))["installGeneration"])' \
        "$LOCAL_INTERNAL_ANCHOR_PATH"
    )" == "2" ]] || exit 14
    [[ "$(
      /usr/bin/python3 -c \
        'import json,sys; print(json.load(open(sys.argv[1]))["previousAnchorSHA256"])' \
        "$LOCAL_INTERNAL_ANCHOR_PATH"
    )" == "$first_anchor_sha" ]] || exit 15
    say "receipt_tx_selftest_anchor_generation_chain=passed"

    pointer_sha="$(
      /usr/bin/shasum -a 256 "$pointer_path" | /usr/bin/awk '{print $1}'
    )"
    anchor_sha="$(
      /usr/bin/shasum -a 256 "$LOCAL_INTERNAL_ANCHOR_PATH" \
        | /usr/bin/awk '{print $1}'
    )"
    local injected_anchor_output
    if injected_anchor_output="$(
      (
        TATWO_INSTALL_FAIL_LOCAL_ANCHOR=1
        export TATWO_INSTALL_FAIL_LOCAL_ANCHOR
        write_local_internal_install_anchor \
          "$receipt_path" "$pointer_path" "$LOCAL_INTERNAL_ANCHOR_PATH"
      ) 2>&1
    )"; then
      echo "selftest_anchor_injection_unexpected_success" >&2
      exit 8
    fi
    /usr/bin/printf '%s\n' "$injected_anchor_output"
    /usr/bin/printf '%s\n' "$injected_anchor_output" \
      | /usr/bin/grep -Fx \
        "local_internal_install_anchor=injected_failure" >/dev/null \
      || exit 27
    if /usr/bin/printf '%s\n' "$injected_anchor_output" \
      | /usr/bin/grep -Eq \
        '(^local_internal_device_identity=failed$|FileNotFoundError)'
    then
      echo "selftest_anchor_injection_failed_at_wrong_fault_point" >&2
      exit 28
    fi
    say "receipt_tx_selftest_anchor_injection_reason=passed"
    [[ "$(
      /usr/bin/shasum -a 256 "$pointer_path" | /usr/bin/awk '{print $1}'
    )" == "$pointer_sha" ]] || exit 16
    [[ "$(
      /usr/bin/shasum -a 256 "$LOCAL_INTERNAL_ANCHOR_PATH" \
        | /usr/bin/awk '{print $1}'
    )" == "$anchor_sha" ]] || exit 17
    say "receipt_tx_selftest_anchor_failure_atomic=passed"

    local activation_rollback_output
    if ! activation_rollback_output="$(
      (
        write_local_internal_install_anchor() {
          say "local_internal_install_anchor=injected_failure"
          return 1
        }
        rollback_local_install_transaction() {
          [[ "$#" == "5" ]] || return 29
          [[ "$1" == "local-internal-anchor-commit-failed" ]] || return 30
          [[ "$2" == "$receipt_path.pending" ]] || return 31
          [[ "$3" == "$receipt_path" ]] || return 32
          [[ "$4" == "$pointer_path" ]] || return 33
          [[ "$5" == "$authority_snapshot" ]] || return 34
          say "local_install_transaction_rollback=passed"
          return 0
        }
        if commit_local_internal_anchor_or_rollback \
          "$receipt_path.pending" \
          "$receipt_path" \
          "$pointer_path" \
          "$authority_snapshot"
        then
          exit 35
        fi
      ) 2>&1
    )"; then
      exit 36
    fi
    /usr/bin/printf '%s\n' "$activation_rollback_output"
    for expected_marker in \
      "activation=local_internal_anchor_commit_failed" \
      "local_install_transaction_rollback=passed" \
      "install_app_local=rolled_back_after_local_internal_anchor_failure"
    do
      /usr/bin/printf '%s\n' "$activation_rollback_output" \
        | /usr/bin/grep -Fx "$expected_marker" >/dev/null \
        || exit 37
    done
    if /usr/bin/printf '%s\n' "$activation_rollback_output" \
      | /usr/bin/grep -Fx \
        "install_app_local=anchor_commit_and_rollback_failed" >/dev/null
    then
      exit 38
    fi
    say "receipt_tx_selftest_anchor_activation_rollback=passed"

    snapshot_local_install_authority \
      "$pointer_path" "$LOCAL_INTERNAL_ANCHOR_PATH" "$authority_snapshot" \
      || exit 18
    /usr/bin/printf '%s\n' "tampered-pointer" >"$pointer_path" \
      || exit 19
    /bin/chmod 0644 "$pointer_path" || exit 20
    /usr/bin/printf '%s\n' '{"tampered":true}' \
      >"$LOCAL_INTERNAL_ANCHOR_PATH" || exit 21
    /bin/chmod 0644 "$LOCAL_INTERNAL_ANCHOR_PATH" || exit 22
    restore_local_install_authority_snapshot \
      "$pointer_path" "$LOCAL_INTERNAL_ANCHOR_PATH" "$authority_snapshot" \
      || exit 23
    [[ "$(
      /usr/bin/shasum -a 256 "$pointer_path" | /usr/bin/awk '{print $1}'
    )" == "$pointer_sha" ]] || exit 24
    [[ "$(
      /usr/bin/shasum -a 256 "$LOCAL_INTERNAL_ANCHOR_PATH" \
        | /usr/bin/awk '{print $1}'
    )" == "$anchor_sha" ]] || exit 25
    [[ "$(/usr/bin/stat -f %Lp "$LOCAL_INTERNAL_ANCHOR_PATH")" == "600" ]] \
      || exit 26
    say "receipt_tx_selftest_authority_metadata_restore=passed"
  ); then
    fail "receipt_tx_selftest local-internal anchor checks failed"
    rc=1
  fi

  # 7) If rollback cannot restore the old App, both pointer and anchor are
  # quarantined rather than left to classify new or unknown installed bytes.
  if /usr/bin/printf '%s\n' "stale-pointer-must-not-survive" \
      >"$INSTALLER_STATE_DIR/receipts/latest-local-app-install.txt" \
    && /usr/bin/printf '%s\n' '{"stale":true}' \
      >"$LOCAL_INTERNAL_ANCHOR_PATH" \
    && /bin/chmod 0600 "$LOCAL_INTERNAL_ANCHOR_PATH" \
    && quarantine_local_install_authority \
      "$INSTALLER_STATE_DIR/receipts/latest-local-app-install.txt" \
      "$LOCAL_INTERNAL_ANCHOR_PATH" \
      "selftest-rollback-failed" \
    && [[ ! -e "$INSTALLER_STATE_DIR/receipts/latest-local-app-install.txt" ]] \
    && [[ ! -e "$LOCAL_INTERNAL_ANCHOR_PATH" ]] \
    && /usr/bin/find \
      "$INSTALLER_STATE_DIR/receipts/invalidated-authority" \
      -type f -name '*-selftest-rollback-failed-pointer' -print -quit \
      | /usr/bin/grep -q . \
    && /usr/bin/find \
      "$INSTALLER_STATE_DIR/receipts/invalidated-authority" \
      -type f -name '*-selftest-rollback-failed-anchor' -print -quit \
      | /usr/bin/grep -q .
  then
    say "receipt_tx_selftest_stale_pointer_and_anchor_invalidated=passed"
  else
    fail "receipt_tx_selftest stale pointer/anchor invalidation failed"
    rc=1
  fi

  if [[ "$rc" -eq 0 ]]; then
    say "receipt_activation_transaction_selftest=passed"
  else
    say "receipt_activation_transaction_selftest=failed"
  fi
  return "$rc"
}

print_dry_run_plan() {
  say "dry_run_plan=started"
  say "$SIGNING_LINE"
  say "plan_touch_applications=no"
  say "plan_app_bundle=$APP_BUNDLE"
  say "plan_provenance_root=$PROVENANCE_ROOT"
  say "plan_build_path=unique-run-root/build"
  say "plan_build_jobs=$BUILD_JOBS"
  say "plan_staging_root=$STAGING_ROOT"
  say "plan_archive_root=$ARCHIVE_ROOT"
  if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    say "plan_sign=codesign --force --options runtime --timestamp --sign \"$SIGNING_IDENTITY\""
    say "plan_helper_sign=codesign --force --options runtime --timestamp --sign \"$SIGNING_IDENTITY\" --identifier $ANCHOR_HELPER_IDENTIFIER"
    say "plan_sparkle_sign=tatwo_codesign_embedded_sparkle secure"
  elif [[ "$SIGNING_MODE" == "apple-development" ]]; then
    say "plan_sign=codesign --force --timestamp=none --sign \"$SIGNING_IDENTITY\""
    say "plan_helper_sign=codesign --force --timestamp=none --sign \"$SIGNING_IDENTITY\" --identifier $ANCHOR_HELPER_IDENTIFIER"
    say "plan_sparkle_sign=tatwo_codesign_embedded_sparkle local-development"
    say "plan_hardened_runtime=disabled-local-development"
    say "plan_tcc_identity=fixed-apple-development"
  else
    say "plan_sign=codesign -s - --deep --force --timestamp=none (historical ad-hoc; unchanged)"
    say "plan_helper_sign=codesign -s - --force --timestamp=none --identifier $ANCHOR_HELPER_IDENTIFIER"
    say "plan_sparkle_sign=none (covered by ad-hoc --deep)"
  fi
  say "plan_steps=requirements,model_runtime_resolution,durable_source_payload,independent_tree_reconstruction,clean_source_extract,dependency_resolve,closed_world_build_input_manifest,build_products,build_output_manifest,verify_source_and_inputs,prepare_staging,stage_resources,stage_optional_icon,embed_sparkle,stage_plg_anchor_helper,stage_model_runtimes,embed_authority_provenance,bundle_content_manifest,embed_provenance,write_info_plist,sign_staged_bundle,verify_bundle_content_manifest,verify_staged_bundle,staged_bundle_manifest,verify_all_drift_gates,stage_only_or_activate,installed_exact_readback,final_receipt,exact_pointer,local_internal_anchor"
  say "plan_stage_only=${TATWO_INSTALL_STAGE_ONLY:-0}"
  say "plan_activate=skipped_under_dry_run"
  say "dry_run_plan=passed"
  say "install_app_local=dry_run_plan_only"
}

main() {
  if [[ "${TATWO_INSTALL_RECEIPT_TX_SELFTEST:-}" == "1" ]]; then
    # Isolated receipt/activation binding check (no build, no codesign, no App swap).
    if ! resolve_pinned_node_binary; then
      say "receipt_activation_transaction_selftest=failed_node"
      return 1
    fi
    detect_signing_identity
    run_receipt_activation_transaction_selftest
    return $?
  fi
  if ! requirements \
    || ! resolve_bundle_versions \
    || ! tatwo_resolve_model_runtimes "$APP_BUNDLE"
  then
    say "install_app_local=not_activated_preflight_failed"
    return 1
  fi
  if [[ "${TATWO_INSTALL_DRY_RUN:-}" == "1" ]]; then
    print_dry_run_plan
    return 0
  fi
  if ! prepare_provenance_run; then
    say "install_app_local=not_activated_provenance_failed"
    return 1
  fi
  say "source_commit=$SOURCE_COMMIT"
  say "source_tree=$SOURCE_TREE"
  say "source_dirty=$SOURCE_DIRTY"
  if ! prepare_cef_build_runtime; then
    say "install_app_local=not_activated_cef_runtime_failed"
    return 1
  fi
  if ! resolve_dependencies_and_capture_inputs; then
    say "install_app_local=not_activated_build_inputs_failed"
    return 1
  fi
  if ! build_products || ! capture_build_output_manifest; then
    say "install_app_local=not_activated_build_failed"
    return 1
  fi
  if ! verify_source_snapshot_unchanged "build" \
    || ! verify_build_input_manifest_unchanged "build"
  then
    say "install_app_local=not_activated_source_drift"
    return 1
  fi
  if ! prepare_staging \
    || ! /bin/cp "$BUILD_BINARY" "$STAGED_BUNDLE/Contents/MacOS/$PRODUCT_NAME" \
    || ! /bin/chmod +x "$STAGED_BUNDLE/Contents/MacOS/$PRODUCT_NAME" \
    || ! /usr/bin/cmp -s \
      "$BUILD_BINARY" "$STAGED_BUNDLE/Contents/MacOS/$PRODUCT_NAME" \
    || ! stage_cef_artifacts \
    || ! stage_resources \
    || ! stage_optional_icon \
    || ! tatwo_embed_sparkle_framework \
      "$BUILD_BIN_PATH" "$STAGED_BUNDLE" "$PRODUCT_NAME" \
    || ! stage_plg_anchor_helper \
    || ! stage_model_runtimes \
    || ! embed_authority_provenance_inputs \
    || ! capture_bundle_content_manifest \
    || ! write_embedded_provenance \
    || ! write_info_plist \
    || ! sign_staged_bundle \
    || ! verify_bundle_content_manifest_unchanged "post_sign" \
    || ! verify_staged_bundle
  then
    say "install_app_local=not_activated_staging_failed"
    return 1
  fi
  if ! verify_source_snapshot_unchanged "staging" \
    || ! verify_build_input_manifest_unchanged "staging" \
    || ! verify_build_output_unchanged "staging" \
    || ! capture_staged_bundle_identity \
    || ! verify_staged_bundle_unchanged "pre_activation"
  then
    say "install_app_local=not_activated_provenance_drift"
    return 1
  fi
  if ! mark_staged_candidate_verified; then
    say "install_app_local=not_activated_candidate_classification_failed"
    return 1
  fi
  if [[ "${TATWO_INSTALL_STAGE_ONLY:-}" == "1" ]]; then
    if ! write_staged_candidate_receipt \
      "$RUN_ROOT/staged-candidate-receipt.txt"
    then
      say "install_app_local=stage_only_receipt_failed"
      return 1
    fi
    say "stage_only_candidate=$STAGED_BUNDLE"
    say "install_app_local=stage_only_passed"
    return 0
  fi
  if ! activate_staged_bundle; then
    # Distinguish receipt-stage failure (App untouched) from activate/rollback paths.
    say "install_app_local=activation_failed"
    return 1
  fi
  say "install_app_local=passed"
  # 2026-08-23 E2E 缺口封口（使用者裁決）：裝完立刻對安裝版 fable5 路由發一則
  # 真訊息驗回覆；失敗＝整體標紅（App 已裝好可用，但這條紅線必須被看見，
  # 不再讓路由斷線晃到使用者手上）。TATWO_SKIP_ROUTE_SMOKE=1 可跳過（離線裝機）。
  if [ "${TATWO_SKIP_ROUTE_SMOKE:-0}" != "1" ]; then
    if "$ROOT_DIR/scripts/tatwo-fable5-install-smoke.sh"; then
      say "install_route_smoke=passed"
    else
      say "install_route_smoke=FAILED（fable5 路由收不到真回覆——立即處理）"
      return 1
    fi
  fi
  # 2026-08-23 磁碟防護：封存/源碼快照各只留最新 2 份——每代 ~2GB，
  # 一天連裝十代兩度把 boot 卷塞到 0 byte 的主因。
  if [ -d "$ARCHIVE_ROOT" ]; then
    ls -t "$ARCHIVE_ROOT" 2>/dev/null | tail -n +3 | while read -r stale; do
      rm -rf "$ARCHIVE_ROOT/$stale"
    done
  fi
  if [ -d "$PROVENANCE_ROOT" ]; then
    ls -t "$PROVENANCE_ROOT" 2>/dev/null | tail -n +3 | while read -r stale; do
      rm -rf "$PROVENANCE_ROOT/$stale"
    done
  fi
  say "install_artifact_prune=done(keep=2)"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cleanup_local_cef_work() {
    local status=$?
    trap - EXIT INT TERM
    if ! cleanup_cef_work; then
      fail "CEF scratch cleanup failed"
      status=1
    fi
    exit "$status"
  }
  trap cleanup_local_cef_work EXIT INT TERM
  main "$@"
fi
