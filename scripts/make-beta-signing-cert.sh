#!/bin/bash
set -euo pipefail
umask 077
# Run once, manually. Retain this SAME certificate/key for subsequent releases.
# Never commit or publish the output directory. This is not Developer ID/notarization.
OUT="${1:-$HOME/TATWO-beta-signing}"
if security find-certificate -c "TATWO OS Beta" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  echo 'login keychain 已有 TATWO OS Beta；請重用既有憑證，不要重新產生。' >&2
  exit 1
fi
[[ ! -e "$OUT" ]] || { echo "拒絕覆蓋既有憑證目錄：$OUT" >&2; exit 1; }
mkdir -p "$OUT"
cat > "$OUT/codesign.cnf" <<'CONFIG'
[req]
distinguished_name = subject
x509_extensions = codesign
prompt = no
[subject]
CN = TATWO OS Beta
[codesign]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG
echo "正在產生十年自簽憑證；請妥善保存私鑰，後續版本不得重新產生憑證。"
openssl req -new -newkey rsa:3072 -nodes -x509 -sha256 -days 3650 \
  -config "$OUT/codesign.cnf" -keyout "$OUT/beta.key" -out "$OUT/beta.crt"
# Interactive export password; not embedded in source or shell history.
openssl pkcs12 -export -inkey "$OUT/beta.key" -in "$OUT/beta.crt" \
  -name "TATWO OS Beta" -out "$OUT/beta.p12"
echo "即將匯入 login keychain；請在系統提示輸入匯出密碼並授權。"
security import "$OUT/beta.p12" -k "$HOME/Library/Keychains/login.keychain-db" -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign \
  -k "$HOME/Library/Keychains/login.keychain-db" "$OUT/beta.crt"
printf '後續打包設定：export TATWO2_SIGN_IDENTITY="TATWO OS Beta"\n'
echo "此憑證只提供固定簽章身分，不代表 Apple 公證。"
