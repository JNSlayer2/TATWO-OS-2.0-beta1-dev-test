#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:---preflight}"
source "$ROOT_DIR/scripts/tatwo-main-app-contract.sh"
STAGING_ROOT="${TATWO_ULTRAWORK_STAGING_ROOT:-${TMPDIR:-/tmp}/tatwo-ultrawork-staging/j2}"
STAGING_CODEX_HOME="${TATWO_STAGING_CODEX_HOME:-$STAGING_ROOT/codex-home}"
BIN_DIR="${TATWO_ULTRAWORK_BIN_DIR:-$STAGING_ROOT/bin}"
APP_DIR="${TATWO_ULTRAWORK_APP_DIR:-$STAGING_ROOT/app}"
APP_NAME="Tatwo Ultrawork Staging"
APP_BUNDLE="$APP_DIR/$APP_NAME.app"
RESOURCE_BUNDLE_GLOB="TatwoUltrawork_*.bundle"
BUILD_PATH="${TATWO_ULTRAWORK_BUILD_PATH:-$STAGING_ROOT/build}"
SKILL_DEST="${TATWO_ULTRAWORK_SKILL_DEST:-$STAGING_CODEX_HOME/skills/tatwo-ultrawork}"
STATE_DIR="${TATWO_ULTRAWORK_STATE_DIR:-$APP_DIR/state}"
MCP_CONFIG="$STATE_DIR/mcp-client-config.json"
PRODUCT_NAME="TatwoUltraworkMac"
CLI_PRODUCT="tatwo-ultrawork"
source "$ROOT_DIR/scripts/tatwo-safe-app-bundle.sh"
source "$ROOT_DIR/scripts/tatwo-embed-sparkle-framework.sh"

say() { printf '%s\n' "$*"; }

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
  swift build --package-path "$ROOT_DIR" -j 2 --product "$CLI_PRODUCT" -c debug
  cp "$(swift build --package-path "$ROOT_DIR" -j 2 -c debug --show-bin-path)/$CLI_PRODUCT" "$BIN_DIR/$CLI_PRODUCT"
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
  swift build --package-path "$ROOT_DIR" -j 2 --product "$PRODUCT_NAME" -c debug --build-path "$BUILD_PATH"
  local build_binary
  local build_bin_path
  local stage_root
  local staged_bundle
  build_bin_path="$(swift build --package-path "$ROOT_DIR" -j 2 -c debug --build-path "$BUILD_PATH" --show-bin-path)"
  build_binary="$build_bin_path/$PRODUCT_NAME"
  stage_root="$APP_DIR/.tatwo-staging/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  staged_bundle="$stage_root/$APP_NAME.app"
  mkdir -p "$staged_bundle/Contents/MacOS" "$staged_bundle/Contents/Resources"
  cp "$build_binary" "$staged_bundle/Contents/MacOS/$PRODUCT_NAME"
  chmod +x "$staged_bundle/Contents/MacOS/$PRODUCT_NAME"
  local copied_resource_bundles=0
  local resource_bundle
  while IFS= read -r -d '' resource_bundle; do
    cp -R "$resource_bundle" "$staged_bundle/Contents/Resources/"
    say "staged_resource_bundle=$staged_bundle/Contents/Resources/$(basename "$resource_bundle")"
    copied_resource_bundles=$((copied_resource_bundles + 1))
  done < <(find "$build_bin_path" -maxdepth 1 -type d -name "$RESOURCE_BUNDLE_GLOB" -print0)
  if [[ "$copied_resource_bundles" == "0" ]]; then
    echo "error: missing SwiftPM resource bundle matching $build_bin_path/$RESOURCE_BUNDLE_GLOB" >&2
    exit 1
  fi
  tatwo_embed_sparkle_framework \
    "$build_bin_path" "$staged_bundle" "$PRODUCT_NAME"
  cat >"$staged_bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$PRODUCT_NAME</string>
  <key>CFBundleIdentifier</key><string>com.tatwo.ultrawork.staging.j2</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0-beta</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSMultipleInstancesProhibited</key><true/>
$(plist_agent_keys)
</dict></plist>
PLIST
  tatwo_configure_sparkle_info_plist "$staged_bundle/Contents/Info.plist"
  codesign --force --deep --sign - "$staged_bundle"
  tatwo_activate_staged_app_bundle \
    "$staged_bundle" "$APP_BUNDLE" "$STATE_DIR" "$PRODUCT_NAME" "$RESOURCE_BUNDLE_GLOB"
  say "installed_app=$APP_BUNDLE"
  say "launch_app=open \"$APP_BUNDLE\""
  say "launch_note=normal launch opens the large Work OS window; the menu-bar icon still opens the compact Codex Switch style panel"
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
    echo "usage: $0 [--preflight|--install|--install-cli|--install-app|--install-skill|--write-mcp-config|--model-prompt]" >&2
    exit 2
    ;;
esac
