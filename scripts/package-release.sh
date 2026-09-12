#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${TATWO_OS_VERSION:-}"
[[ "$VERSION" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || {
  echo '請設定 TATWO_OS_VERSION=vX.Y.Z（與 Release tag 相同）' >&2; exit 1;
}
[[ -n "${TATWO2_SIGN_IDENTITY:-}" ]] || {
  echo '請設定 TATWO2_SIGN_IDENTITY="TATWO OS Beta"，使用原有憑證，勿重新產生。' >&2; exit 1;
}
OUT="${1:-dist/release-$VERSION}"
[[ "$OUT" == /* ]] || OUT="$PWD/$OUT"
[[ ! -e "$OUT" ]] || { echo "拒絕覆蓋既有產物：$OUT" >&2; exit 1; }
mkdir -p "$OUT"
bash scripts/build-app.sh "$OUT"
mv "$OUT/tatwo2.app" "$OUT/TATWO OS.app"
# 先清 xattr、再用 --norsrc 打包：否則 ditto 會替帶 xattr 的檔案塞 ._ AppleDouble 進 zip，
# 使用者端 unzip 會把 ._ 當成真檔案還原到 bundle 裡，codesign 判「sealed resource missing」。
xattr -cr "$OUT/TATWO OS.app"
codesign --verify --deep --strict "$OUT/TATWO OS.app"
ditto -c -k --norsrc --keepParent "$OUT/TATWO OS.app" "$OUT/TATWO-OS.zip"
[[ "$(unzip -Z1 "$OUT/TATWO-OS.zip" | grep -c '/\._')" == 0 ]] || { echo 'zip 內含 ._ AppleDouble 檔，拒絕發佈' >&2; exit 1; }
(cd "$OUT" && shasum -a 256 TATWO-OS.zip > TATWO-OS.zip.sha256)
bash scripts/runtime-layer.sh split "$OUT/TATWO OS.app" "$OUT"
echo '打包完成。人工確認後才執行以下命令（本腳本不發佈）：'
printf 'gh release create %q' "$VERSION"
printf ' %q' "$OUT"/*.zip "$OUT"/*.zip.sha256
printf ' --repo tatwo214/TATWO-OS-2.0-beta1-dev-test --title %q\n' "$VERSION"
