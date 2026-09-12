#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/tatwo-main-app-contract.sh"
MODE="${1:-apply}"

require_value() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    printf 'error: %s is required\n' "$name" >&2
    return 1
  fi
}

require_positive_integer() {
  local name="$1"
  require_value "$name"
  if [[ ! "${!name}" =~ ^[1-9][0-9]*$ ]]; then
    printf 'error: %s must be a positive integer\n' "$name" >&2
    return 1
  fi
}

require_semver() {
  local name="$1"
  require_value "$name"
  if [[ ! "${!name}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    printf 'error: %s must be a semantic version\n' "$name" >&2
    return 1
  fi
}

require_https_url() {
  local name="$1"
  require_value "$name"
  if ! node - "${!name}" <<'NODE'
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
    printf 'error: %s must be a credential-free HTTPS URL\n' "$name" >&2
    return 1
  fi
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'error: required tool is unavailable: %s\n' "$1" >&2
    return 1
  fi
}

for name in \
  TATWO_APP_VERSION \
  TATWO_APP_BUILD \
  TATWO_UPDATE_FEED_URL \
  TATWO_UPDATE_PUBLIC_ED_KEY \
  TATWO_UPDATE_CHANNEL \
  TATWO_DEVELOPER_ID_APPLICATION \
  TATWO_NOTARY_KEYCHAIN_PROFILE \
  TATWO_SPARKLE_KEY_ACCOUNT \
  TATWO_RELEASE_DOWNLOAD_URL_PREFIX \
  TATWO_RELEASE_SCHEMA_VERSION \
  TATWO_RELEASE_PROTOCOL_VERSION \
  TATWO_ROLLBACK_TARGET_VERSION
do
  require_value "$name"
done

require_semver TATWO_APP_VERSION
require_semver TATWO_ROLLBACK_TARGET_VERSION
require_positive_integer TATWO_RELEASE_SCHEMA_VERSION
require_positive_integer TATWO_RELEASE_PROTOCOL_VERSION
require_https_url TATWO_UPDATE_FEED_URL
require_https_url TATWO_RELEASE_DOWNLOAD_URL_PREFIX

if [[ ! "$TATWO_APP_BUILD" =~ ^[0-9]+(\.[0-9]+){0,3}$ ]]; then
  printf '%s\n' \
    'error: TATWO_APP_BUILD must be a numeric CFBundleVersion' >&2
  exit 2
fi
case "$TATWO_UPDATE_CHANNEL" in
  internal-canary|stable) ;;
  *)
    printf 'error: unsupported update channel: %s\n' \
      "$TATWO_UPDATE_CHANNEL" >&2
    exit 2
    ;;
esac
case "$TATWO_DEVELOPER_ID_APPLICATION" in
  "Developer ID Application:"*) ;;
  *)
    printf '%s\n' \
      'error: TATWO_DEVELOPER_ID_APPLICATION must name a Developer ID Application identity' \
      >&2
    exit 2
    ;;
esac

for tool in git swift security codesign ditto shasum node xcrun; do
  require_tool "$tool"
done

if [[ -n "$(git -C "$ROOT_DIR" status --porcelain=v1 --untracked-files=all)" ]]; then
  printf '%s\n' \
    'error: signed release requires a clean tracked and untracked source tree' \
    >&2
  exit 2
fi

if ! security find-identity -v -p codesigning \
  | grep -Fq "\"$TATWO_DEVELOPER_ID_APPLICATION\""; then
  printf '%s\n' \
    'error: requested Developer ID Application identity is unavailable' \
    >&2
  exit 2
fi

swift package --package-path "$ROOT_DIR" resolve >/dev/null
SPARKLE_ROOT="$ROOT_DIR/.build/artifacts/sparkle/Sparkle"
GENERATE_APPCAST="$SPARKLE_ROOT/bin/generate_appcast"
SIGN_UPDATE="$SPARKLE_ROOT/bin/sign_update"
GENERATE_KEYS="$SPARKLE_ROOT/bin/generate_keys"
for tool in "$GENERATE_APPCAST" "$SIGN_UPDATE" "$GENERATE_KEYS"; do
  if [[ ! -x "$tool" ]]; then
    printf 'error: Sparkle release tool is unavailable: %s\n' "$tool" >&2
    exit 2
  fi
done

SPARKLE_PUBLIC_KEY="$(
  "$GENERATE_KEYS" --account "$TATWO_SPARKLE_KEY_ACCOUNT" -p
)"
if [[ "$SPARKLE_PUBLIC_KEY" != "$TATWO_UPDATE_PUBLIC_ED_KEY" ]]; then
  printf '%s\n' \
    'error: configured Sparkle public key does not match the selected keychain account' \
    >&2
  exit 2
fi

SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
SOURCE_TREE="$(git -C "$ROOT_DIR" rev-parse HEAD^{tree})"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RELEASE_ROOT="${TATWO_RELEASE_ROOT:-$(
  mktemp -d "/private/tmp/tatwo-signed-release-${STAMP}.XXXXXX"
)}"
if [[ -e "$RELEASE_ROOT" && ! -d "$RELEASE_ROOT" ]]; then
  printf 'error: release root is not a directory: %s\n' "$RELEASE_ROOT" >&2
  exit 2
fi
mkdir -p "$RELEASE_ROOT"
if find "$RELEASE_ROOT" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  printf 'error: release root must be empty: %s\n' "$RELEASE_ROOT" >&2
  exit 2
fi

if [[ "$MODE" == "--preflight" || "$MODE" == "preflight" ]]; then
  printf 'release_preflight=pass\n'
  printf 'source_commit=%s\n' "$SOURCE_COMMIT"
  printf 'source_tree=%s\n' "$SOURCE_TREE"
  printf 'channel=%s\n' "$TATWO_UPDATE_CHANNEL"
  printf 'release_root=%s\n' "$RELEASE_ROOT"
  exit 0
fi
if [[ "$MODE" != "apply" && "$MODE" != "--apply" ]]; then
  printf 'usage: %s [apply|--apply|preflight|--preflight]\n' "$0" >&2
  exit 64
fi

BUILD_ROOT="$RELEASE_ROOT/build"
ARCHIVES_ROOT="$RELEASE_ROOT/feed"
mkdir -p "$BUILD_ROOT" "$ARCHIVES_ROOT"

TATWO_PRODUCTION_ROOT="$BUILD_ROOT" \
TATWO_APP_VERSION="$TATWO_APP_VERSION" \
TATWO_APP_BUILD="$TATWO_APP_BUILD" \
TATWO_DEVELOPER_ID_APPLICATION="$TATWO_DEVELOPER_ID_APPLICATION" \
TATWO_UPDATE_FEED_URL="$TATWO_UPDATE_FEED_URL" \
TATWO_UPDATE_PUBLIC_ED_KEY="$TATWO_UPDATE_PUBLIC_ED_KEY" \
TATWO_UPDATE_CHANNEL="$TATWO_UPDATE_CHANNEL" \
  "$ROOT_DIR/script/build_production_app.sh"

APP_BUNDLE="$BUILD_ROOT/$TATWO_MAIN_APP_BUNDLE_FILENAME"
[[ -d "$APP_BUNDLE" ]]
codesign --verify --deep --strict "$APP_BUNDLE"

NOTARY_ARCHIVE="$RELEASE_ROOT/notary-submission.zip"
NOTARY_RESULT="$RELEASE_ROOT/.notary-result.json"
ditto -c -k --sequesterRsrc --keepParent \
  "$APP_BUNDLE" "$NOTARY_ARCHIVE"
xcrun notarytool submit "$NOTARY_ARCHIVE" \
  --keychain-profile "$TATWO_NOTARY_KEYCHAIN_PROFILE" \
  --wait \
  --output-format json >"$NOTARY_RESULT"

read -r NOTARY_STATUS NOTARY_SUBMISSION_ID < <(
  node - "$NOTARY_RESULT" <<'NODE'
import fs from "node:fs";
const result = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
process.stdout.write(`${result.status ?? ""} ${result.id ?? ""}\n`);
NODE
)
if [[ "$NOTARY_STATUS" != "Accepted" || -z "$NOTARY_SUBMISSION_ID" ]]; then
  printf 'error: notarization was not accepted (status=%s)\n' \
    "${NOTARY_STATUS:-missing}" >&2
  exit 2
fi

xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

ARTIFACT_NAME="Tatwo-Ultrawork-${TATWO_APP_VERSION}-${TATWO_APP_BUILD}.zip"
ARTIFACT_PATH="$ARCHIVES_ROOT/$ARTIFACT_NAME"
ditto -c -k --sequesterRsrc --keepParent \
  "$APP_BUNDLE" "$ARTIFACT_PATH"

APPCAST_PATH="$ARCHIVES_ROOT/appcast-${TATWO_UPDATE_CHANNEL}.xml"
APPCAST_ARGUMENTS=(
  --account "$TATWO_SPARKLE_KEY_ACCOUNT"
  --download-url-prefix "$TATWO_RELEASE_DOWNLOAD_URL_PREFIX"
  --channel "$TATWO_UPDATE_CHANNEL"
  --maximum-versions 3
  --maximum-deltas 0
  -o "$APPCAST_PATH"
)
if [[ -n "${TATWO_PHASED_ROLLOUT_INTERVAL_SECONDS:-}" ]]; then
  require_positive_integer TATWO_PHASED_ROLLOUT_INTERVAL_SECONDS
  APPCAST_ARGUMENTS+=(
    --phased-rollout-interval
    "$TATWO_PHASED_ROLLOUT_INTERVAL_SECONDS"
  )
fi
"$GENERATE_APPCAST" "${APPCAST_ARGUMENTS[@]}" "$ARCHIVES_ROOT"
"$SIGN_UPDATE" \
  --account "$TATWO_SPARKLE_KEY_ACCOUNT" \
  "$APPCAST_PATH"
"$SIGN_UPDATE" \
  --account "$TATWO_SPARKLE_KEY_ACCOUNT" \
  --verify \
  "$APPCAST_PATH"

ARTIFACT_SHA256="$(shasum -a 256 "$ARTIFACT_PATH" | awk '{print $1}')"
ARTIFACT_BYTES="$(stat -f '%z' "$ARTIFACT_PATH")"
APPCAST_SHA256="$(shasum -a 256 "$APPCAST_PATH" | awk '{print $1}')"
TEAM_ID="$(
  codesign -dvvv "$APP_BUNDLE" 2>&1 \
    | awk -F= '/^TeamIdentifier=/{print $2; exit}'
)"
if [[ -z "$TEAM_ID" || "$TEAM_ID" == "not set" ]]; then
  printf '%s\n' \
    'error: Developer ID signed bundle is missing TeamIdentifier' >&2
  exit 2
fi
APP_CDHASH="$(
  codesign -dvvv "$APP_BUNDLE" 2>&1 \
    | awk -F= '/^CDHash=/{print $2; exit}'
)"
HELPER_SHA256="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :TatwoPLGAnchorHelperSHA256' \
    "$APP_BUNDLE/Contents/Info.plist"
)"
if [[ ! "$APP_CDHASH" =~ ^[0-9a-f]{40,64}$ \
  || ! "$HELPER_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  printf '%s\n' \
    'error: promoted bundle is missing an exact CDHash or helper digest' >&2
  exit 2
fi

ARTIFACT_SIGNATURE_FILE="$RELEASE_ROOT/.artifact-ed-signature"
node - "$APPCAST_PATH" "$ARTIFACT_NAME" >"$ARTIFACT_SIGNATURE_FILE" <<'NODE'
import fs from "node:fs";
const text = fs.readFileSync(process.argv[2], "utf8");
const escaped = process.argv[3].replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
const enclosure = text.match(
  new RegExp(`<enclosure[^>]+url="[^"]*${escaped}"[^>]*>`, "u"),
);
if (!enclosure) process.exit(2);
const signature = enclosure[0].match(/sparkle:edSignature="([^"]+)"/u);
if (!signature) process.exit(3);
process.stdout.write(signature[1]);
NODE
ARTIFACT_ED_SIGNATURE="$(cat "$ARTIFACT_SIGNATURE_FILE")"
"$SIGN_UPDATE" \
  --account "$TATWO_SPARKLE_KEY_ACCOUNT" \
  --verify \
  "$ARTIFACT_PATH" \
  "$ARTIFACT_ED_SIGNATURE"

RELEASE_MANIFEST="$RELEASE_ROOT/release-manifest.json"
node - \
  "$RELEASE_MANIFEST" \
  "$TATWO_APP_VERSION" \
  "$TATWO_APP_BUILD" \
  "$TATWO_UPDATE_CHANNEL" \
  "$ARTIFACT_NAME" \
  "$ARTIFACT_SHA256" \
  "$ARTIFACT_BYTES" \
  "$ARTIFACT_ED_SIGNATURE" \
  "$SOURCE_COMMIT" \
  "$SOURCE_TREE" \
  "$TATWO_RELEASE_SCHEMA_VERSION" \
  "$TATWO_RELEASE_PROTOCOL_VERSION" \
  "$TATWO_ROLLBACK_TARGET_VERSION" \
  "$TEAM_ID" \
  "$NOTARY_SUBMISSION_ID" \
  "$TATWO_UPDATE_FEED_URL" \
  "$APPCAST_SHA256" \
  "$TATWO_MAIN_APP_BUNDLE_ID" \
  "TatwoUltraworkMac" \
  "$APP_CDHASH" \
  "$HELPER_SHA256" \
  "$STAMP" <<'NODE'
import fs from "node:fs";
const [
  ,
  ,
  output,
  version,
  build,
  channel,
  artifactName,
  artifactSHA256,
  artifactBytes,
  artifactEdDSASignature,
  sourceCommit,
  sourceTree,
  schemaVersion,
  protocolVersion,
  rollbackTargetVersion,
  developerIDTeamID,
  notarizationSubmissionID,
  feedURL,
  appcastSHA256,
  bundleIdentifier,
  bundleExecutable,
  bundleCDHash,
  helperSHA256,
  createdAt,
] = process.argv;
const manifest = {
  schema: "TatwoSignedReleaseManifestV1",
  createdAt,
  version,
  build,
  channel,
  feedURL,
  artifact: {
    name: artifactName,
    sha256: artifactSHA256,
    bytes: Number(artifactBytes),
    sparkleEdDSASignature: artifactEdDSASignature,
  },
  bundle: {
    identifier: bundleIdentifier,
    executable: bundleExecutable,
    cdhash: bundleCDHash,
    helperSHA256,
  },
  updateEvidence: {
    appcastSHA256,
  },
  provenance: {
    sourceCommit,
    sourceTree,
    developerIDTeamID,
    notarizationStatus: "Accepted",
    notarizationSubmissionID,
  },
  compatibility: {
    schemaVersion: Number(schemaVersion),
    protocolVersion: Number(protocolVersion),
    rollbackTargetVersion,
  },
  safety: {
    activationRequiresUserApproval: true,
    rollbackScope: "app_bundle_only",
    userDataRollbackAllowed: false,
    domainLedgerRollbackAllowed: false,
  },
};
fs.writeFileSync(output, `${JSON.stringify(manifest, null, 2)}\n`, {
  mode: 0o644,
});
NODE

MANIFEST_SIGNATURE="$(
  "$SIGN_UPDATE" \
    --account "$TATWO_SPARKLE_KEY_ACCOUNT" \
    -p \
    "$RELEASE_MANIFEST"
)"
MANIFEST_SIGNATURE_PATH="$RELEASE_ROOT/release-manifest.ed25519"
printf '%s\n' "$MANIFEST_SIGNATURE" >"$MANIFEST_SIGNATURE_PATH"
"$SIGN_UPDATE" \
  --account "$TATWO_SPARKLE_KEY_ACCOUNT" \
  --verify \
  "$RELEASE_MANIFEST" \
  "$MANIFEST_SIGNATURE"

RELEASE_RECEIPT="$RELEASE_ROOT/release-receipt.json"
node - \
  "$RELEASE_RECEIPT" \
  "$RELEASE_MANIFEST" \
  "$MANIFEST_SIGNATURE_PATH" \
  "$APPCAST_PATH" \
  "$ARTIFACT_PATH" \
  "$NOTARY_ARCHIVE" \
  "$NOTARY_RESULT" \
  "$ARTIFACT_SIGNATURE_FILE" \
  "$SOURCE_COMMIT" \
  "$STAMP" <<'NODE'
import { createHash } from "node:crypto";
import fs from "node:fs";
const [
  ,
  ,
  output,
  manifest,
  manifestSignature,
  appcast,
  artifact,
  notaryArchive,
  notaryResult,
  artifactSignatureEvidence,
  sourceCommit,
  createdAt,
] = process.argv;
const digest = (path) =>
  createHash("sha256").update(fs.readFileSync(path)).digest("hex");
const receipt = {
  schema: "TatwoSignedReleaseReceiptV1",
  createdAt,
  sourceCommit,
  status: "passed",
  notarizationAccepted: true,
  appcastSignatureVerified: true,
  artifactSignatureVerified: true,
  manifestSignatureVerified: true,
  files: [
    { path: manifest, sha256: digest(manifest) },
    { path: manifestSignature, sha256: digest(manifestSignature) },
    { path: appcast, sha256: digest(appcast) },
    { path: artifact, sha256: digest(artifact) },
  ],
  retainedEvidence: [
    { path: notaryArchive, sha256: digest(notaryArchive) },
    { path: notaryResult, sha256: digest(notaryResult) },
    {
      path: artifactSignatureEvidence,
      sha256: digest(artifactSignatureEvidence),
    },
  ],
  cleanupPolicy: "retain_release_evidence_no_direct_delete",
  protectedDataReadCount: 0,
  userDataWriteCount: 0,
  domainLedgerWriteCount: 0,
  domainAuthorityMutationCount: 0,
};
fs.writeFileSync(output, `${JSON.stringify(receipt, null, 2)}\n`);
NODE

printf 'release_status=passed\n'
printf 'release_root=%s\n' "$RELEASE_ROOT"
printf 'artifact=%s\n' "$ARTIFACT_PATH"
printf 'appcast=%s\n' "$APPCAST_PATH"
printf 'manifest=%s\n' "$RELEASE_MANIFEST"
printf 'manifest_signature=%s\n' "$MANIFEST_SIGNATURE_PATH"
printf 'receipt=%s\n' "$RELEASE_RECEIPT"
