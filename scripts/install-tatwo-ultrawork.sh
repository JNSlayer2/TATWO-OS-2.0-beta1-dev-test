#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:---preflight}"
source "$ROOT_DIR/scripts/tatwo-main-app-contract.sh"
BIN_DIR="${TATWO_ULTRAWORK_BIN_DIR:-$HOME/.local/bin}"
APP_DIR="${TATWO_ULTRAWORK_APP_DIR:-/Applications}"
APP_NAME="$TATWO_MAIN_APP_NAME"
APP_BUNDLE="$APP_DIR/$APP_NAME.app"
RESOURCE_BUNDLE_GLOB="TatwoUltrawork_*.bundle"
BUILD_PATH="${TATWO_ULTRAWORK_BUILD_PATH:-$ROOT_DIR/.build/out}"
SKILL_DEST="${TATWO_ULTRAWORK_SKILL_DEST:-$HOME/.codex/skills/tatwo-ultrawork}"
APP_SUPPORT_DIR="${TATWO_ULTRAWORK_APP_SUPPORT:-$HOME/Library/Application Support/$TATWO_MAIN_APP_SUPPORT_NAME}"
STATE_DIR="${TATWO_ULTRAWORK_STATE_DIR:-$APP_SUPPORT_DIR/state}"
MCP_CONFIG="$STATE_DIR/mcp-client-config.json"
PRODUCT_NAME="TatwoUltraworkMac"
CLI_PRODUCT="tatwo-ultrawork"
source "$ROOT_DIR/scripts/tatwo-safe-app-bundle.sh"
source "$ROOT_DIR/scripts/tatwo-embed-sparkle-framework.sh"

say() { printf '%s\n' "$*"; }

stage_production_promotion_evidence() {
  local verified_bundle="$1"
  local stage_root="$2"
  local manifest="${TATWO_VERIFIED_SIGNED_RELEASE_MANIFEST:-}"
  local manifest_signature="${TATWO_VERIFIED_SIGNED_RELEASE_MANIFEST_SIGNATURE:-}"
  local release_receipt="${TATWO_VERIFIED_SIGNED_RELEASE_RECEIPT:-}"
  local appcast="${TATWO_VERIFIED_SIGNED_RELEASE_APPCAST:-}"
  local promotion_stage="$stage_root/production-release-promotion-v1"
  local info_plist="$verified_bundle/Contents/Info.plist"
  local bundle_cdhash
  local team_id

  for required_path in \
    "$manifest" \
    "$manifest_signature" \
    "$release_receipt" \
    "$appcast"
  do
    if [[ -z "$required_path" || ! -f "$required_path" ]]; then
      printf '%s\n' \
        'error: production install requires manifest, signature, receipt, and appcast promotion evidence' \
        >&2
      return 2
    fi
  done

  bundle_cdhash="$(
    codesign -dvvv "$verified_bundle" 2>&1 \
      | awk -F= '/^CDHash=/{print $2; exit}'
  )"
  team_id="$(
    codesign -dvvv "$verified_bundle" 2>&1 \
      | awk -F= '/^TeamIdentifier=/{print $2; exit}'
  )"
  node - \
    "$manifest" \
    "$manifest_signature" \
    "$release_receipt" \
    "$appcast" \
    "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info_plist")" \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")" \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")" \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")" \
    "$(/usr/libexec/PlistBuddy -c 'Print :TatwoSourceCommit' "$info_plist")" \
    "$(/usr/libexec/PlistBuddy -c 'Print :TatwoSourceTree' "$info_plist")" \
    "$(/usr/libexec/PlistBuddy -c 'Print :TatwoPLGAnchorHelperSHA256' "$info_plist")" \
    "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info_plist")" \
    "$(/usr/libexec/PlistBuddy -c 'Print :TatwoUpdateChannel' "$info_plist")" \
    "$bundle_cdhash" \
    "$team_id" <<'NODE'
import {
  createHash,
  createPublicKey,
  verify,
} from "node:crypto";
import fs from "node:fs";
const [
  ,
  ,
  manifestPath,
  signaturePath,
  receiptPath,
  appcastPath,
  publicKeyBase64,
  bundleIdentifier,
  bundleExecutable,
  version,
  build,
  sourceCommit,
  sourceTree,
  helperSHA256,
  feedURL,
  channel,
  bundleCDHash,
  developerIDTeamID,
] = process.argv;
const digest = (file) =>
  createHash("sha256").update(fs.readFileSync(file)).digest("hex");
const fail = (message) => {
  process.stderr.write(`error: ${message}\n`);
  process.exit(2);
};
const manifestData = fs.readFileSync(manifestPath);
const signatureText = fs.readFileSync(signaturePath, "utf8").trim();
let manifest;
let receipt;
try {
  manifest = JSON.parse(manifestData);
  receipt = JSON.parse(fs.readFileSync(receiptPath, "utf8"));
} catch {
  fail("production promotion evidence is not valid JSON");
}
const publicKeyRaw = Buffer.from(publicKeyBase64, "base64");
const signature = Buffer.from(signatureText, "base64");
if (
  publicKeyRaw.length !== 32
  || publicKeyRaw.toString("base64") !== publicKeyBase64
  || signature.length !== 64
  || signature.toString("base64") !== signatureText
) {
  fail("production promotion signature material is malformed");
}
const publicKey = createPublicKey({
  key: Buffer.concat([
    Buffer.from("302a300506032b6570032100", "hex"),
    publicKeyRaw,
  ]),
  format: "der",
  type: "spki",
});
if (!verify(null, manifestData, publicKey, signature)) {
  fail("production promotion manifest signature is invalid");
}
const exactPairs = [
  [manifest.schema, "TatwoSignedReleaseManifestV1", "manifest schema"],
  [manifest.version, version, "version"],
  [manifest.build, build, "build"],
  [manifest.channel, channel, "channel"],
  [manifest.feedURL, feedURL, "feed URL"],
  [manifest.bundle?.identifier, bundleIdentifier, "bundle identifier"],
  [manifest.bundle?.executable, bundleExecutable, "bundle executable"],
  [manifest.bundle?.cdhash, bundleCDHash, "bundle CDHash"],
  [manifest.bundle?.helperSHA256, helperSHA256, "helper digest"],
  [manifest.provenance?.sourceCommit, sourceCommit, "source commit"],
  [manifest.provenance?.sourceTree, sourceTree, "source tree"],
  [
    manifest.provenance?.developerIDTeamID,
    developerIDTeamID,
    "Developer ID team",
  ],
  [
    manifest.provenance?.notarizationStatus,
    "Accepted",
    "notarization status",
  ],
];
for (const [actual, expected, label] of exactPairs) {
  if (actual !== expected) fail(`production promotion ${label} mismatch`);
}
if (
  !/^[0-9a-f]{64}$/u.test(manifest.updateEvidence?.appcastSHA256 ?? "")
  || manifest.updateEvidence.appcastSHA256 !== digest(appcastPath)
  || !/^[0-9a-f]{64}$/u.test(manifest.artifact?.sha256 ?? "")
  || !Number.isSafeInteger(manifest.artifact?.bytes)
  || manifest.artifact.bytes <= 0
  || typeof manifest.artifact?.sparkleEdDSASignature !== "string"
  || manifest.artifact.sparkleEdDSASignature.length === 0
  || typeof manifest.provenance?.notarizationSubmissionID !== "string"
  || manifest.provenance.notarizationSubmissionID.length === 0
) {
  fail("production promotion notarization or signed appcast evidence is incomplete");
}
if (
  receipt.schema !== "TatwoSignedReleaseReceiptV1"
  || receipt.status !== "passed"
  || receipt.notarizationAccepted !== true
  || receipt.appcastSignatureVerified !== true
  || receipt.artifactSignatureVerified !== true
  || receipt.manifestSignatureVerified !== true
) {
  fail("signed release receipt did not pass every production gate");
}
const receiptFiles = new Map(
  Array.isArray(receipt.files)
    ? receipt.files.map((entry) => [entry.path, entry.sha256])
    : [],
);
for (const evidencePath of [manifestPath, signaturePath, appcastPath]) {
  if (receiptFiles.get(evidencePath) !== digest(evidencePath)) {
    fail("signed release receipt evidence digest mismatch");
  }
}
NODE

  mkdir -p "$promotion_stage"
  cp "$manifest" "$promotion_stage/release-manifest.json"
  cp "$manifest_signature" "$promotion_stage/release-manifest.ed25519"
  cp "$release_receipt" "$promotion_stage/release-receipt.json"
  cp "$appcast" "$promotion_stage/appcast.xml"
  printf '%s\n' "$promotion_stage"
}

activate_production_promotion_evidence() {
  local promotion_stage="$1"
  local promotion_root="$STATE_DIR/production-release-promotion-v1"
  local archive_root="$STATE_DIR/production-release-promotion-archives.noindex"
  local stamp
  local archived=""

  stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "$STATE_DIR" "$archive_root"
  : >"$archive_root/.metadata_never_index"
  chflags hidden "$archive_root" 2>/dev/null || true
  if [[ -e "$promotion_root" ]]; then
    archived="$archive_root/promotion-previous-$stamp.archive"
    mv "$promotion_root" "$archived"
  fi
  if ! mv "$promotion_stage" "$promotion_root"; then
    if [[ -n "$archived" && -e "$archived" && ! -e "$promotion_root" ]]; then
      mv "$archived" "$promotion_root" || true
    fi
    printf '%s\n' \
      'error: production App was installed but promotion evidence activation failed; runtime will remain isolated' \
      >&2
    return 2
  fi
  say "production_promotion=$promotion_root"
}

plist_agent_keys() {
  if [[ "${TATWO_ULTRAWORK_BUILD_AS_AGENT:-0}" == "1" ]]; then
    cat <<'PLIST'
  <key>LSUIElement</key><true/>
PLIST
  fi
}

need_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    say "$1=ok"
  else
    say "$1=missing"
    return 1
  fi
}

requirements() {
  say "Tatwo Ultrawork requirements"
  say "repo=$ROOT_DIR"
  say "host_mutation=false"
  local missing=0
  for cmd in swift git node; do
    need_cmd "$cmd" || missing=1
  done
  if [[ "$missing" == "1" ]]; then
    say "Install missing tools first. macOS users usually need Xcode Command Line Tools, Swift, Git, and Node.js."
    return 1
  fi
}

model_prompt() {
  cat <<'PROMPT'

Tatwo Ultrawork model/API checklist
-----------------------------------
Tatwo can run as CLI/App/MCP without storing any API key. A complete TATWO
deployment also needs ChatGPT Pro MCP for the Pro research/review lane.
Your AI deployer or human operator should ask which routes to enable:

0. ChatGPT Pro MCP (required for full TATWO)
   - Need: installed ChatGPT Pro MCP plugin/MCP and a healthy bridge/status check.
   - Role: Pro research memo, source-backed review, counterarguments, handoff.
   - If missing: mark deployment incomplete; do not pretend full TATWO is ready.
1. Codex / GPT route
   - Need: Codex CLI or Codex App login, or an OpenAI-compatible gateway already configured by the user.
   - Do not paste tokens into Tatwo. Use the provider's normal login/API-key flow.
2. Claude route
   - Need: Claude CLI / Claude Code / Anthropic route, if you want Claude as reviewer or judge.
3. Grok route
   - Need: Grok/xAI route or API key, if you want news/counterexample scouting.
4. MiniMax route
   - Need: MiniMax route/API key, if you want high-throughput draft/scout work.
5. Local/API route
   - Optional: local model server or compatible API endpoint.

Recommended MCP/plugin installs:
- Required: ChatGPT Pro MCP for Pro research/review.
- Built in: TATWO Ultrawork MCP from this repo.
- Recommended: GitNexus for project maps and impact range.
- Recommended when using Codex App multi-model dropdown: codex-app-model-gateway.
- Optional: Colima verifier for L/XL sandbox checks.

Safe default: install Tatwo first, connect ChatGPT Pro MCP, then enable other
routes one by one after each route passes smoke tests. Tatwo returns
plans/receipts by default and does not grant host write access through MCP.
PROMPT
}

preflight() {
  requirements
  swift run --package-path "$ROOT_DIR" "$CLI_PRODUCT" sandbox preflight --json
  swift run --package-path "$ROOT_DIR" "$CLI_PRODUCT" install plan --json
  swift run --package-path "$ROOT_DIR" "$CLI_PRODUCT" mcp manifest --json
  swift run --package-path "$ROOT_DIR" "$CLI_PRODUCT" mcp client-config --engine generic-cli --json
  node "$ROOT_DIR/scripts/tatwo-ultrawork-mcp-smoke.mjs"
  node "$ROOT_DIR/scripts/tatwo-ultrawork-http-mcp-smoke.mjs"
  say "preflight=passed"
  model_prompt
}

install_cli() {
  requirements
  mkdir -p "$BIN_DIR"
  swift build --package-path "$ROOT_DIR" --product "$CLI_PRODUCT" -c release
  cp "$(swift build --package-path "$ROOT_DIR" -c release --show-bin-path)/$CLI_PRODUCT" "$BIN_DIR/$CLI_PRODUCT"
  chmod +x "$BIN_DIR/$CLI_PRODUCT"
  cat >"$BIN_DIR/$CLI_PRODUCT-mcp" <<SH
#!/bin/zsh
exec "$(command -v node)" "$ROOT_DIR/scripts/tatwo-ultrawork-mcp.mjs"
SH
  chmod +x "$BIN_DIR/$CLI_PRODUCT-mcp"
  say "installed_cli=$BIN_DIR/$CLI_PRODUCT"
  say "installed_mcp_stdio_wrapper=$BIN_DIR/$CLI_PRODUCT-mcp"
  say "Add to PATH if needed: export PATH=\"$BIN_DIR:\$PATH\""
}

install_app() {
  requirements
  local verified_bundle="${TATWO_VERIFIED_PRODUCTION_APP_BUNDLE:-}"
  if [[ -z "$verified_bundle" || ! -d "$verified_bundle" ]]; then
    echo "error: TATWO_VERIFIED_PRODUCTION_APP_BUNDLE must point to a signed and notarized production artifact" >&2
    return 2
  fi
  [[ "$(basename "$verified_bundle")" == "$TATWO_MAIN_APP_BUNDLE_FILENAME" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$verified_bundle/Contents/Info.plist")" == "$TATWO_MAIN_APP_BUNDLE_ID" ]]
  codesign --verify --deep --strict "$verified_bundle"
  codesign -dvv "$verified_bundle" 2>&1 | grep -Fq 'Authority=Developer ID Application:'
  spctl --assess --type execute --verbose=2 "$verified_bundle"
  [[ -n "$(/usr/libexec/PlistBuddy -c 'Print :TatwoSourceCommit' "$verified_bundle/Contents/Info.plist")" ]]
  local stage_root
  local staged_bundle
  local promotion_stage
  stage_root="${TATWO_ULTRAWORK_STAGING_ROOT:-$STATE_DIR/staging/app}/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  staged_bundle="$stage_root/$APP_NAME.app"
  mkdir -p "$stage_root"
  promotion_stage="$(
    stage_production_promotion_evidence "$verified_bundle" "$stage_root"
  )"
  ditto "$verified_bundle" "$staged_bundle"
  TATWO_ULTRAWORK_ARCHIVE_ROOT="${TATWO_ULTRAWORK_ARCHIVE_ROOT:-$STATE_DIR/bundle-archives.noindex}" \
  tatwo_activate_staged_app_bundle \
    "$staged_bundle" "$APP_BUNDLE" "$STATE_DIR" "$PRODUCT_NAME" "$RESOURCE_BUNDLE_GLOB"
  activate_production_promotion_evidence "$promotion_stage"
  say "installed_app=$APP_BUNDLE"
  say "launch_app=open \"$APP_BUNDLE\""
  say "launch_note=normal launch opens the large Work OS window; the menu-bar icon still opens the compact Codex Switch style panel"
}

install_app_local() {
  "$ROOT_DIR/scripts/tatwo-install-local-app.sh"
}

install_skill() {
  mkdir -p "$SKILL_DEST"
  if [[ -f "$ROOT_DIR/skills/tatwo-ultrawork/SKILL.md" ]]; then
    cp "$ROOT_DIR/skills/tatwo-ultrawork/SKILL.md" "$SKILL_DEST/SKILL.md"
    say "installed_skill=$SKILL_DEST/SKILL.md"
  else
    say "installed_skill=skipped_missing_repo_skill"
  fi
}

write_mcp_config() {
  mkdir -p "$STATE_DIR"
  cat >"$MCP_CONFIG" <<JSON
{
  "mcpServers": {
    "tatwo-ultrawork": {
      "command": "node",
      "args": ["$ROOT_DIR/scripts/tatwo-ultrawork-mcp.mjs"]
    }
  },
  "cliExamples": [
    "$BIN_DIR/$CLI_PRODUCT mcp manifest --json",
    "$BIN_DIR/$CLI_PRODUCT mcp call tatwo.gateway.status --json",
    "$BIN_DIR/$CLI_PRODUCT mcp call tatwo.sandbox.begin --contract <contractID> --objective sandbox-smoke --json",
    "$BIN_DIR/$CLI_PRODUCT-mcp",
    "$BIN_DIR/$CLI_PRODUCT mcp call tatwo.mode.plan --mode L --scenario ui-ux --json",
    "$BIN_DIR/$CLI_PRODUCT mcp call tatwo.mode.plan --app-url http://127.0.0.1:17377 --mode L --scenario ui-ux --json"
  ],
  "hostMutationAllowed": false
}
JSON
  say "wrote_mcp_config=$MCP_CONFIG"
  say "Codex/Claude/other MCP clients can copy the mcpServers block above. Tatwo does not patch host config automatically."
}

post_smoke() {
  "$BIN_DIR/$CLI_PRODUCT" mcp manifest --json >/dev/null
  "$BIN_DIR/$CLI_PRODUCT" mcp call tatwo.gateway.status --json >/dev/null
  "$BIN_DIR/$CLI_PRODUCT" mcp call tatwo.sandbox.begin --contract post-install-smoke-contract --objective post-install-smoke --json >/dev/null
  "$BIN_DIR/$CLI_PRODUCT" mcp call tatwo.mode.plan --mode M --scenario coding --json >/dev/null
  node "$ROOT_DIR/scripts/tatwo-ultrawork-mcp-smoke.mjs" >/dev/null
  say "post_install_smoke=passed"
}

install_all() {
  install_cli
  install_app
  install_skill
  write_mcp_config
  post_smoke
  model_prompt
  say "install=complete"
}

case "$MODE" in
  --preflight|preflight)
    preflight
    ;;
  --install|install)
    install_all
    ;;
  --install-cli|install-cli)
    install_cli
    ;;
  --install-app|install-app)
    install_app
    ;;
  --install-app-local|install-app-local)
    install_app_local
    ;;
  --install-skill|install-skill)
    install_skill
    ;;
  --write-mcp-config|write-mcp-config)
    write_mcp_config
    ;;
  --model-prompt|model-prompt)
    model_prompt
    ;;
  *)
    echo "usage: $0 [--preflight|--install|--install-cli|--install-app|--install-app-local|--install-skill|--write-mcp-config|--model-prompt]" >&2
    exit 2
    ;;
esac
