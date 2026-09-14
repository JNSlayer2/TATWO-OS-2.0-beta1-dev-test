#!/bin/bash
# 打包含 CEF 的 tatwo2.app（ad-hoc 簽名）。用法：scripts/build-app.sh [dist 目錄]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
# Read-only source completeness gate; no downloads, compiler, output or signing.
if [[ "${1:-}" == "--check-inputs" ]]; then
  inputs=(Package.swift scripts/tatwo-cef-bundle.sh scripts/stage-ipad-use-device.sh
    scripts/bundle-engines.sh scripts/bundle-cli-runtime.sh scripts/runtime-sign.py
    scripts/runtime-layer.sh scripts/runtime-layer.py scripts/runtime-layer.txt
    Apps/TatwoUltraworkMac/CEF/cef-runtime-arm64.json
    Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/Resources/BrowserBlocklists
    App/Sources/Tatwo2/Resources/os-upstream.md)
  for engine in claude codex grok; do inputs+=("Engines/$engine-sidecar/sidecar.mjs"); done
  inputs+=(Engines/claude-sidecar/package.json Engines/browser-mcp/server.mjs Engines/os-mcp/server.mjs)
  for input in "${inputs[@]}"; do
    [[ -e "$ROOT/$input" ]] || { echo "missing build input: $input" >&2; exit 1; }
  done
  bash "$ROOT/scripts/stage-ipad-use-device.sh" "$ROOT/Device/iPadUseDevice" --check-inputs
  echo "BUILD APP INPUTS PASS"
  exit 0
fi
OUT="${1:-dist}"
if [[ "$OUT" != /* ]]; then
  OUT="$ROOT/$OUT"
fi
APP="$OUT/tatwo2.app"
CONTENTS="$APP/Contents"
BIN_PATH=""
RELEASE_VERSION="${TATWO_OS_VERSION:-}"
RELEASE_VERSION="${RELEASE_VERSION#v}"
RELEASE_VERSION="${RELEASE_VERSION:-0.1}"
[[ "$RELEASE_VERSION" =~ ^[0-9]+[.][0-9]+([.][0-9]+){0,2}$ ]] || { echo "Invalid TATWO_OS_VERSION" >&2; exit 1; }
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SHORT_TOKEN="$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -d- -f1)"
REFRESH_CEF_INDEX=false

source "$ROOT/scripts/tatwo-cef-bundle.sh"
tatwo_cef_initialize_runtime_configuration \
  "${TATWO2_CEF_CACHE:-$OUT/.cef-cache}" \
  "$ROOT/Apps/TatwoUltraworkMac/CEF/cef-runtime-arm64.json" \
  true
prepare_cef_runtime

# SwiftPM jobs does not cap the release frontend's internal codegen threads.
# Keep both layers bounded on the 16 GiB delivery host.
JOBS="${TATWO2_BUILD_JOBS:-2}"
swift build -c release --product TatwoCEFHelper --scratch-path .build-sol --jobs "$JOBS" -Xswiftc -num-threads -Xswiftc "$JOBS"
swift build -c release --product Tatwo2 --scratch-path .build-sol --jobs "$JOBS" -Xswiftc -num-threads -Xswiftc "$JOBS"
BIN_PATH="$(swift build -c release --show-bin-path --scratch-path .build-sol)"

mkdir -p "$OUT"
if [[ -e "$APP" ]]; then
  mv "$APP" "$OUT/tatwo2.app.previous-$STAMP"
fi
mkdir -p \
  "$CONTENTS/MacOS" \
  "$CONTENTS/Resources"
cp "$BIN_PATH/Tatwo2" "$CONTENTS/MacOS/tatwo2"
# 三家引擎的 sidecar 都進 bundle（正式 App 不能依賴 repo 路徑）
for eng in claude codex grok; do
  cp -R "Engines/$eng-sidecar" "$CONTENTS/Resources/$eng-sidecar"
done
# 內建瀏覽器 MCP 與三家 sidecar 同層，sidecar 以相對路徑註冊。
cp -R "Engines/browser-mcp" "$CONTENTS/Resources/browser-mcp"
# 內建派工 MCP（E1）同理。
cp -R "Engines/os-mcp" "$CONTENTS/Resources/os-mcp"
bash "$ROOT/scripts/stage-ipad-use-device.sh" \
  "$ROOT/Device/iPadUseDevice" "$CONTENTS/Resources/iPadUseDevice"
cp -R \
  Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/Resources/BrowserBlocklists \
  "$CONTENTS/Resources/BrowserBlocklists"
if [[ -d "$BIN_PATH/TatwoUltrawork_Tatwo2.bundle" ]]; then
  cp -R "$BIN_PATH/TatwoUltrawork_Tatwo2.bundle" "$CONTENTS/Resources/"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>tatwo2</string>
  <key>CFBundleDisplayName</key><string>tatwo2</string>
  <key>CFBundleIdentifier</key><string>ai.tatwo.tatwo2</string>
  <key>CFBundleVersion</key><string>$(git rev-list --count HEAD)</string>
  <key>CFBundleShortVersionString</key><string>$RELEASE_VERSION</string>
  <key>CFBundleExecutable</key><string>tatwo2</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>ai.tatwo.tatwo2</string>
    <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Default</string>
  </dict></array>
  <key>TatwoBrowserWorkspaceEnabled</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>TatwoCEFApplication</string>
  <key>TatwoBrowserEngine</key><string>chromium-cef</string>
</dict></plist>
PLIST

tatwo_cef_stage_app_artifacts \
  "$APP" \
  tatwo2 \
  "$BIN_PATH" \
  "$CEF_RUNTIME_ROOT" \
  tatwo2 \
  ai.tatwo.tatwo2 \
  "$RELEASE_VERSION" \
  "$(git rev-list --count HEAD)" \
  14.0 \
  "Tatwo2 needs access to user-selected removable-volume files." \
  "Tatwo2 needs access to user-selected network-volume files."
scripts/bundle-engines.sh "$APP"
bash "$ROOT/scripts/bundle-cli-runtime.sh" "$APP"
# 顯示名：使用者 2026-09-05 裁決 2.0 叫「TATWO OS」（內部識別 ai.tatwo.tatwo2 暫不改，避免 TCC／鑰匙圈重問）
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName TATWO OS" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string TATWO OS" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName TATWO OS" "$APP/Contents/Info.plist" 2>/dev/null || true

# 簽章身份：固定用 Keychain 裡的開發憑證，TCC（「取用可卸除式卷宗」允許框）才會記得同一個 App；
# 找不到憑證才退回 ad-hoc（每次打包 cdhash 都變，TCC 會重問）。可用 TATWO2_SIGN_IDENTITY 覆寫。
# Beta: TATWO2_SIGN_IDENTITY="TATWO OS Beta"; reuse the same certificate/key and bundle ID so the generated designated requirement stays stable.
SIGN_IDENTITY="${TATWO2_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '"Apple Development: [^"]+"' | head -1 | tr -d '"')"
fi
if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "sign: $SIGN_IDENTITY"
  python3 -E "$ROOT/scripts/runtime-sign.py" "$APP" "$SIGN_IDENTITY"
  bash "$ROOT/scripts/runtime-layer.sh" prepare "$APP"
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
else
  echo "sign: ad-hoc（找不到開發憑證）"
  python3 -E "$ROOT/scripts/runtime-sign.py" "$APP" -
  bash "$ROOT/scripts/runtime-layer.sh" prepare "$APP"
  codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
codesign -dr - "$APP" 2>&1 | grep designated | cut -c1-160
echo "built: $APP"
