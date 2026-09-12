#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${TATWO_OS_VERSION:-}"
[[ "$VERSION" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || {
  echo '請設定 TATWO_OS_VERSION=vX.Y.Z（與 Release tag 相同）' >&2; exit 1;
}
# Package an already signed, notarized, and stapled app. Do not re-sign it here:
# rebuilding or re-signing after notarization would invalidate its ticket.
SOURCE_APP="${TATWO2_RELEASE_APP:-}"
[[ -d "$SOURCE_APP" && ! -L "$SOURCE_APP" ]] || {
  echo 'Set TATWO2_RELEASE_APP to the approved signed, notarized, stapled app.' >&2; exit 1;
}
bash scripts/verify-update-identity.sh "$SOURCE_APP" "$SOURCE_APP"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")"
[[ "$APP_VERSION" == "${VERSION#v}" ]] || { echo 'App version does not match Release tag.' >&2; exit 1; }
BASELINE="${TATWO2_RELEASE_BASELINE:-}"
if [[ -n "$BASELINE" ]]; then
  bash scripts/verify-update-identity.sh "$BASELINE" "$SOURCE_APP"
elif [[ "${TATWO2_RELEASE_BOOTSTRAP:-0}" != 1 ]]; then
  echo 'Set TATWO2_RELEASE_BASELINE, or explicitly approve a new signing lineage with TATWO2_RELEASE_BOOTSTRAP=1.' >&2
  exit 1
fi
# A bootstrap still requires macOS distribution trust; it never permits ad-hoc.
spctl --assess --type execute "$SOURCE_APP"
xcrun stapler validate "$SOURCE_APP"
OUT="${1:-dist/release-$VERSION}"
[[ "$OUT" == /* ]] || OUT="$PWD/$OUT"
[[ ! -e "$OUT" ]] || { echo "拒絕覆蓋既有產物：$OUT" >&2; exit 1; }
mkdir -p "$OUT"
ditto "$SOURCE_APP" "$OUT/TATWO OS.app"
bash scripts/verify-update-identity.sh "$SOURCE_APP" "$OUT/TATWO OS.app"
# Auto-installable releases must satisfy macOS distribution checks.
# These checks never remove quarantine or alter the signed bundle.
spctl --assess --type execute "$OUT/TATWO OS.app"
xcrun stapler validate "$OUT/TATWO OS.app"
ditto -c -k --keepParent "$OUT/TATWO OS.app" "$OUT/TATWO-OS.zip"
(cd "$OUT" && shasum -a 256 TATWO-OS.zip > TATWO-OS.zip.sha256)
printf 'install-policy=1\nversion=%s\n' "$VERSION" > "$OUT/TATWO-OS.install-ready"
echo '打包完成。人工確認後才執行以下命令（本腳本不發佈）：'
printf 'gh release create %q %q %q %q --repo tatwo214/TATWO-OS-2.0-beta1-dev-test --title %q\n' \
  "$VERSION" "$OUT/TATWO-OS.zip" "$OUT/TATWO-OS.zip.sha256" "$OUT/TATWO-OS.install-ready" "$VERSION"
