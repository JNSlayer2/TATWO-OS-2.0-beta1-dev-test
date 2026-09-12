#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${TATWO_OS_VERSION:-}"
[[ "$VERSION" =~ ^v[0-9]+[.][0-9]+[.][0-9]+([.][0-9]{3})?$ ]] || {
  echo '請設定 TATWO_OS_VERSION=vX.Y.Z.NNN（NNN 從 001）' >&2; exit 1;
}
REPO=tatwo214/TATWO-OS-2.0-private
if [[ "$VERSION" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
  [[ "${TATWO_OS_PROMOTE:-}" == 1 ]] || { echo '公開版只能由 promote 產生' >&2; exit 1; }
  REPO=tatwo214/TATWO-OS-2.0-beta1-dev-test
else
  [[ "${VERSION##*.}" != 000 ]] || { echo '私人版 NNN 從 001 起' >&2; exit 1; }
fi
[[ -n "${TATWO2_SIGN_IDENTITY:-}" && "$TATWO2_SIGN_IDENTITY" != - ]] || {
  echo '請設定 TATWO2_SIGN_IDENTITY="TATWO OS Beta"，使用原有憑證，勿重新產生。' >&2; exit 1;
}
OUT="${1:-dist/release-$VERSION}"
[[ "$OUT" == /* ]] || OUT="$PWD/$OUT"
[[ ! -e "$OUT" ]] || { echo "拒絕覆蓋既有產物：$OUT" >&2; exit 1; }
[[ -n "${TATWO2_RELEASE_BASELINE:-}" ]] || { echo 'TATWO2_RELEASE_BASELINE 必填' >&2; exit 1; }
FINAL="$OUT"
mkdir -p "$(dirname "$FINAL")"
OUT="$(mktemp -d "$(dirname "$FINAL")/.package-candidate.XXXXXX")"
trap 'echo "打包失敗；未產出發行目錄。診斷材料保留：$OUT" >&2' ERR
if [[ -n "${TATWO2_RELEASE_CANDIDATE:-}" ]]; then
  ditto "$TATWO2_RELEASE_CANDIDATE" "$OUT/TATWO OS.app"
else
  bash scripts/build-app.sh "$OUT"
  mv "$OUT/tatwo2.app" "$OUT/TATWO OS.app"
fi
# --norsrc excludes AppleDouble without stripping approved candidate/ticket xattrs.
codesign --verify --deep --strict "$OUT/TATWO OS.app"
python3 -E scripts/package-release-gates.py candidate "$OUT/TATWO OS.app" "$VERSION"
ditto -c -k --norsrc --keepParent "$OUT/TATWO OS.app" "$OUT/TATWO-OS.zip"
[[ "$(unzip -Z1 "$OUT/TATWO-OS.zip" | grep -c '/\._')" == 0 ]] || { echo 'zip 內含 ._ AppleDouble 檔，拒絕發佈' >&2; exit 1; }
(cd "$OUT" && shasum -a 256 TATWO-OS.zip > TATWO-OS.zip.sha256)
bash scripts/runtime-layer.sh split "$OUT/TATWO OS.app" "$OUT"
BASE="${TATWO_OS_DELTA_FROM:-}"
if [[ -z "$BASE" ]]; then
  BASE="$(gh release list --repo "$REPO" --exclude-drafts --exclude-pre-releases --limit 100 \
    --json tagName --jq "[.[] | select(.tagName != \"$VERSION\")][0].tagName // empty")" || BASE=""
fi
OLD=""
if [[ "$BASE" =~ ^v[0-9]+([.][0-9]+){1,3}$ && "$BASE" != "$VERSION" ]]; then
  mkdir "$OUT/.delta-base"
  if gh release download "$BASE" --repo "$REPO" --dir "$OUT/.delta-base" \
      --pattern TATWO-OS.manifest.json --pattern TATWO-OS.manifest.json.sha256 &&
     (cd "$OUT/.delta-base" && read -r expected _ < TATWO-OS.manifest.json.sha256 &&
      [[ "$expected" =~ ^[0-9a-f]{64}$ && "$(shasum -a 256 < TATWO-OS.manifest.json)" == "$expected  -" ]] &&
      [[ "$(plutil -extract tag raw -o - TATWO-OS.manifest.json)" == "$BASE" ]]); then
    OLD="$OUT/.delta-base/TATWO-OS.manifest.json"
  else echo "略過 delta：$BASE 的 manifest 無法取得或校驗不符" >&2; fi
else echo '略過 delta：沒有可用的上一個已發行 tag' >&2; fi
python3 -E scripts/per-file-delta.py "$OUT/TATWO OS.app" "$OUT" "$VERSION" "$OLD" ||
  echo 'delta 產生／離線驗證失敗；保留診斷材料，只發完整與層級附件' >&2
python3 -E scripts/package-release-gates.py archives "$OUT" "$VERSION"
mv "$OUT" "$FINAL"; OUT="$FINAL"
trap - ERR
if [[ "${TATWO_OS_PROMOTE:-}" == 1 ]]; then echo '三段附件已準備；只能由 promote 重驗及發行'; exit 0; fi
echo '這只會發到私人版。人工確認後才執行以下命令（本腳本不發佈）：'
printf 'gh release create %q' "$VERSION"
printf ' %q' "$OUT"/*.zip "$OUT"/*.zip.sha256 "$OUT"/TATWO-OS.install-ready "$OUT"/TATWO-OS.install-ready.sha256
printf ' %q' "$OUT"/TATWO-OS.manifest.json "$OUT"/TATWO-OS.manifest.json.sha256
printf ' --repo %q --target %q --title %q\n' "$REPO" "$(git rev-parse HEAD)" "$VERSION"
