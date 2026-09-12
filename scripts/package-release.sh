#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${TATWO_OS_VERSION:-}"
[[ "$VERSION" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || {
  echo '請設定 TATWO_OS_VERSION=vX.Y.Z（與 Release tag 相同）' >&2; exit 1;
}
[[ -n "${TATWO2_SIGN_IDENTITY:-}" && "$TATWO2_SIGN_IDENTITY" != - ]] || {
  echo '請設定 TATWO2_SIGN_IDENTITY="TATWO OS Beta"，使用原有憑證，勿重新產生。' >&2; exit 1;
}
# A previously distributed, trusted app is required; do not derive trust from the new download.
BASELINE="${TATWO2_RELEASE_BASELINE:-}"
[[ -d "$BASELINE" && ! -L "$BASELINE" ]] || {
  echo 'Set TATWO2_RELEASE_BASELINE to the trusted previous release app.' >&2; exit 1;
}
bash scripts/verify-update-identity.sh "$BASELINE" "$BASELINE"
OUT="${1:-dist/release-$VERSION}"
[[ "$OUT" == /* ]] || OUT="$PWD/$OUT"
[[ ! -e "$OUT" ]] || { echo "拒絕覆蓋既有產物：$OUT" >&2; exit 1; }
mkdir -p "$OUT"
bash scripts/build-app.sh "$OUT"
mv "$OUT/tatwo2.app" "$OUT/TATWO OS.app"
bash scripts/verify-update-identity.sh "$BASELINE" "$OUT/TATWO OS.app"
ditto -c -k --keepParent "$OUT/TATWO OS.app" "$OUT/TATWO-OS.zip"
(cd "$OUT" && shasum -a 256 TATWO-OS.zip > TATWO-OS.zip.sha256)
echo '打包完成。人工確認後才執行以下命令（本腳本不發佈）：'
printf 'gh release create %q %q %q --repo tatwo214/TATWO-OS-2.0-beta1-dev-test --title %q\n' \
  "$VERSION" "$OUT/TATWO-OS.zip" "$OUT/TATWO-OS.zip.sha256" "$VERSION"
