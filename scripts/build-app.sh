#!/bin/bash
# Build with an explicitly selected persistent signing identity; never fall back to ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
SIGN_IDENTITY="${TATWO2_SIGN_IDENTITY:-}"
[[ -n "$SIGN_IDENTITY" && "$SIGN_IDENTITY" != - ]] || {
  echo 'Set TATWO2_SIGN_IDENTITY to the existing persistent signing identity; ad-hoc is not supported.' >&2
  exit 1
}
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
[[ "$RELEASE_VERSION" =~ ^[0-9]+[.][0-9]+([.][0-9]+)?$ ]] || { echo "Invalid TATWO_OS_VERSION" >&2; exit 1; }
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SHORT_TOKEN="$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -d- -f1)"
REFRESH_CEF_INDEX=false

source "$ROOT/scripts/tatwo-cef-bundle.sh"
tatwo_cef_initialize_runtime_configuration \
  "$OUT/.cef-cache" \
  "$ROOT/Apps/TatwoUltraworkMac/CEF/cef-runtime-arm64.json" \
  true
prepare_cef_runtime

# SwiftPM jobs does not cap the release frontend's internal codegen threads.
# Keep both layers bounded on the 16 GiB delivery host.
swift build -c release --product TatwoCEFHelper --scratch-path .build-sol --jobs 2 -Xswiftc -num-threads -Xswiftc 2
swift build -c release --product Tatwo2 --scratch-path .build-sol --jobs 2 -Xswiftc -num-threads -Xswiftc 2
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

# Keep the same identity and designated requirement across builds.
tatwo_cef_sign_nested_artifacts "$APP" "$SIGN_IDENTITY" developer
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
codesign -dr - "$APP" 2>&1 | grep designated | cut -c1-160
echo "built: $APP"
