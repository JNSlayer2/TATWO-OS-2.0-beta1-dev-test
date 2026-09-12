#!/usr/bin/env bash
# tatwo-device-enroll.sh — TatwoOS 設備納管・一次到位
#
# 任何新設備跑「一次」就永久納入 mini 驅動的跨設備同步：
#   clone repo → 產生設備身分 → 裝 App → 登記到通道 →（副設備）裝常駐同步 helper。
# 之後：版本自動追、資料庫由主設備一鍵驅動、全程零接觸。
#
# 用法（在新設備上跑）：
#   bash scripts/tatwo-device-enroll.sh --role secondary --name macbook-m3
#   選項：--primary-host HOST（副設備連主設備，預設 mini tunnel）
#         --repo PATH（本機 repo 位置，預設 $HOME/tatwo-ultrawork）
#         --repo-url URL（clone 來源，預設官方 GitHub）
#         --interval SEC（helper 輪詢秒數，預設 45）
#         --pairing-seed SEED（已有主設備時 secondary 必填；在主設備的設備分頁
#           點擊「新增設備」產生，限時 3 分鐘、單次有效）
#         --channel-remote REMOTE（必填；私人熱同步 Git remote，建議 SSH URL／
#           SSH config alias。GitHub origin 只作冷備份，不會自動代替此通道）
#         --os-root PATH（必填；此設備的 Work OS constitution/issue/TODO 根目錄）
#         --skills-root PATH（此設備的 canonical skills 根；預設 App Support/skills。
#           mini 若該座標不存在且 <your-volume>/skills 存在，會建立橋接 symlink，
#           東西不搬。新增 skill 時會在下一次 system-pull 自動納入 Skillet，
#           非 ASCII 名稱需先登記 repository alias）
#         --skills-runtime-root PATH（同步後實際啟用的 skills runtime；預設位於
#           Tatwo App Support，與 canonical source 分離）
#         --skills-consumer-root PATH（受管 skills consumer 投影根；Codex／Claude
#           原生入口只指向此處的 current symlink）
#         --codex-skills-link PATH（Codex 原生 skills 入口，預設 ~/.codex/skills）
#         --claude-skills-link PATH（Claude 原生 skills 入口，預設 ~/.claude/skills）
#         --remote-app-support PATH（主設備的 app-support 絕對路徑；不填則
#           在納管時自動經 SSH 向主設備查詢。設備使用者名稱不同時必要，
#           否則 db-pull 會誤判「遠端不存在」）
#         --cli PATH（指定已支援 device-trust／skillet 的 Tatwo CLI 來源；
#           仍會原子換裝到 TATWO_ULTRAWORK_CLI_DEST，讓 helper／PATH 共用同一份）
#         --device-trust-cli PATH（採用已獲本機 Keychain ACL 授權的 signer；
#           會以 fresh nonce + 既有 identity 驗證後，封存成不可變 signer anchor）
#         --device-trust-cli-sha256 SHA256（採用 signer 的預期 lowercase SHA-256；
#           與 --device-trust-cli 一起必填，避免只憑路徑採用漂移檔案）
#         --device-trust-cli-cdhash CDHASH（採用 signer 的預期 lowercase CDHash；
#           與 --device-trust-cli 一起必填）
#         --no-app（跳過裝 App）  --no-helper（不裝常駐 helper）  --dry-run（只印不動）
set -euo pipefail

ROLE="secondary"
NAME="$(hostname -s 2>/dev/null || echo device)"
PRIMARY_HOST="ssh-mac-mini.tatwo214.com"
REPO="$HOME/tatwo-ultrawork"
REPO_URL="https://github.com/tatwo214/tatwo-ultrawork.git"
BRANCH="release/tatwo-os"
INTERVAL="45"
PAIRING_SEED=""
CHANNEL_REMOTE="${TATWO_CHANNEL_REMOTE:-}"
OS_ROOT="${TATWO_OS_ROOT:-}"
SKILLS_ROOT="${TATWO_SKILLET_SOURCE_ROOT:-${TATWO_SKILLS_CANONICAL_DIR:-}}"
SKILLS_ROOT_EXPLICIT=0
[ -z "${TATWO_SKILLET_SOURCE_ROOT:-${TATWO_SKILLS_CANONICAL_DIR:-}}" ] \
  || SKILLS_ROOT_EXPLICIT=1
SKILLS_RUNTIME_ROOT="${TATWO_SKILLS_RUNTIME_ROOT:-}"
SKILLS_CONSUMER_ROOT="${TATWO_SKILLS_CONSUMER_ROOT:-}"
CODEX_SKILLS_LINK="${TATWO_CODEX_SKILLS_LINK:-$HOME/.codex/skills}"
CLAUDE_SKILLS_LINK="${TATWO_CLAUDE_SKILLS_LINK:-$HOME/.claude/skills}"
SKILLS_PROJECTION_SCRIPT="${TATWO_SKILLS_CONSUMER_PROJECTION_SCRIPT:-}"
REMOTE_APP_SUPPORT=""
CLI_PATH=""
DEVICE_TRUST_CLI_SOURCE="${TATWO_DEVICE_TRUST_CLI_SOURCE:-}"
DEVICE_TRUST_CLI_EXPECTED_SHA256="${TATWO_DEVICE_TRUST_CLI_EXPECTED_SHA256:-}"
DEVICE_TRUST_CLI_EXPECTED_CDHASH="${TATWO_DEVICE_TRUST_CLI_EXPECTED_CDHASH:-}"
CLI_DEST="${TATWO_ULTRAWORK_CLI_DEST:-$HOME/.local/bin/tatwo-ultrawork}"
CLI_BUILD_PATH="${TATWO_ULTRAWORK_BUILD_PATH:-}"
PYTHON3="${TATWO_PYTHON3:-python3}"
DEVICE_TRUST_TEST_PYTHON="${TATWO_DEVICE_TRUST_TEST_PYTHON:-python3}"
DO_APP=1; DO_HELPER=1; DRY=0

while [ $# -gt 0 ]; do case "$1" in
  --role) ROLE="$2"; shift 2;;
  --name) NAME="$2"; shift 2;;
  --primary-host) PRIMARY_HOST="$2"; shift 2;;
  --repo) REPO="$2"; shift 2;;
  --repo-url) REPO_URL="$2"; shift 2;;
  --branch) BRANCH="$2"; shift 2;;
  --interval) INTERVAL="$2"; shift 2;;
  --pairing-seed) PAIRING_SEED="$2"; shift 2;;
  --channel-remote) CHANNEL_REMOTE="$2"; shift 2;;
  --os-root) OS_ROOT="$2"; shift 2;;
  --skills-root) SKILLS_ROOT="$2"; SKILLS_ROOT_EXPLICIT=1; shift 2;;
  --skills-runtime-root) SKILLS_RUNTIME_ROOT="$2"; shift 2;;
  --skills-consumer-root) SKILLS_CONSUMER_ROOT="$2"; shift 2;;
  --codex-skills-link) CODEX_SKILLS_LINK="$2"; shift 2;;
  --claude-skills-link) CLAUDE_SKILLS_LINK="$2"; shift 2;;
  --remote-app-support) REMOTE_APP_SUPPORT="$2"; shift 2;;
  --cli) CLI_PATH="$2"; shift 2;;
  --device-trust-cli) DEVICE_TRUST_CLI_SOURCE="$2"; shift 2;;
  --device-trust-cli-sha256) DEVICE_TRUST_CLI_EXPECTED_SHA256="$2"; shift 2;;
  --device-trust-cli-cdhash) DEVICE_TRUST_CLI_EXPECTED_CDHASH="$2"; shift 2;;
  --no-app) DO_APP=0; shift;;
  --no-helper) DO_HELPER=0; shift;;
  --dry-run) DRY=1; shift;;
  -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
  *) echo "未知參數 $1" >&2; exit 1;; esac; done

APP_SUPPORT="${TATWO_APP_SUPPORT:-$HOME/Library/Application Support/Tatwo Ultrawork}"
[ -n "$SKILLS_ROOT" ] || SKILLS_ROOT="$APP_SUPPORT/skills"
DEVICE_TRUST_SIGNER_ROOT="$APP_SUPPORT/device-trust/signer"
DEVICE_TRUST_SIGNER="$DEVICE_TRUST_SIGNER_ROOT/tatwo-device-trust-signer-v1"
DEVICE_TRUST_SIGNER_PIN="$APP_SUPPORT/device-trust/signer-pin.json"
DEVICE_TRUST_CLI_SHA256=""
DEVICE_TRUST_CLI_CDHASH=""
[ -n "$SKILLS_RUNTIME_ROOT" ] || SKILLS_RUNTIME_ROOT="$APP_SUPPORT/skills-runtime"
[ -n "$SKILLS_CONSUMER_ROOT" ] || SKILLS_CONSUMER_ROOT="$APP_SUPPORT/skills-consumer"
[ -n "$SKILLS_PROJECTION_SCRIPT" ] \
  || SKILLS_PROJECTION_SCRIPT="$REPO/scripts/tatwo-skills-consumer-projection.py"
command -v "$PYTHON3" >/dev/null 2>&1 \
  || {
    echo "設備納管需要可用的 python3" >&2
    exit 1
  }
"$PYTHON3" -c 'import os' >/dev/null 2>&1 \
  || {
    echo "設備納管的 python3 無法執行必要標準函式庫" >&2
    exit 1
  }
step() { printf '▸ %s\n' "$*"; }
run()  { if [ "$DRY" = "1" ]; then printf '  [dry] %s\n' "$*"; else eval "$*"; fi; }

cli_supports_hot_sync() {
  local cli="$1" probe="" schema="" trust_contract="" skillet_contract=""
  [ -x "$cli" ] || return 1
  probe="$("$cli" capabilities enrollment --json 2>/dev/null)" || return 1
  schema="$(
    printf '%s\n' "$probe" | plutil -extract data.schema raw -o - - 2>/dev/null
  )" || return 1
  trust_contract="$(
    printf '%s\n' "$probe" \
      | plutil -extract data.deviceTrustContract raw -o - - 2>/dev/null
  )" || return 1
  skillet_contract="$(
    printf '%s\n' "$probe" \
      | plutil -extract data.skilletContract raw -o - - 2>/dev/null
  )" || return 1
  [ "$schema" = "TatwoEnrollmentCapabilitiesV1" ] \
    && [ "$trust_contract" = "TatwoDeviceTrustCLI.v1" ] \
    && [ "$skillet_contract" = "TatwoSkilletCLI.v1" ]
}

cli_supports_device_trust() {
  local cli="$1" probe="" schema="" trust_contract=""
  [ -x "$cli" ] || return 1
  probe="$("$cli" capabilities enrollment --json 2>/dev/null)" || return 1
  schema="$(
    printf '%s\n' "$probe" | plutil -extract data.schema raw -o - - 2>/dev/null
  )" || return 1
  trust_contract="$(
    printf '%s\n' "$probe" \
      | plutil -extract data.deviceTrustContract raw -o - - 2>/dev/null
  )" || return 1
  [ "$schema" = "TatwoEnrollmentCapabilitiesV1" ] \
    && [ "$trust_contract" = "TatwoDeviceTrustCLI.v1" ]
}

device_trust_test_mode_authorized() {
  local challenge="" expected_response="" observed_response=""
  [ "${TATWO_TEST_MODE:-0}" = "1" ] \
    && [ -n "${TATWO_DEVICE_TRUST_TEST_KEY_ROOT:-}" ] \
    || return 1
  case "$TATWO_DEVICE_TRUST_TEST_KEY_ROOT" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) ;;
    *) return 1 ;;
  esac
  challenge="$(uuidgen)" || return 1
  expected_response="$(
    printf '%s\0%s' "$challenge" "$TATWO_DEVICE_TRUST_TEST_KEY_ROOT" \
      | shasum -a 256 \
      | awk 'NR == 1 {print tolower($1)}'
  )" || return 1
  observed_response="$(
    "$DEVICE_TRUST_TEST_PYTHON" - \
      "${TATWO_DEVICE_TRUST_TEST_KEY_ROOT}" "$challenge" <<'PY'
import hashlib
import os
import sys

root = os.path.realpath(sys.argv[1])
challenge = sys.argv[2]
allowed_roots = {
    os.path.realpath(path)
    for path in ("/tmp", "/private/tmp", "/var/folders", "/private/var/folders")
    if os.path.isdir(path)
}
for allowed in allowed_roots:
    if root != allowed and os.path.commonpath([root, allowed]) == allowed:
        value = challenge + "\0" + sys.argv[1]
        print(hashlib.sha256(value.encode("utf-8")).hexdigest())
        raise SystemExit(0)
raise SystemExit(1)
PY
  )" || return 1
  [ "$observed_response" = "$expected_response" ]
}

device_trust_cli_sha256() {
  local digest=""
  digest="$(shasum -a 256 "$1" | awk 'NR == 1 {print tolower($1)}')" \
    || return 1
  case "$digest" in
    ""|*[!0-9a-f]*) return 1;;
  esac
  [ "${#digest}" = "64" ] || return 1
  printf '%s\n' "$digest"
}

device_trust_cli_cdhash() {
  local cli="$1" output="" cdhash="" sha=""
  if /usr/bin/codesign --verify --strict "$cli" >/dev/null 2>&1; then
    output="$(/usr/bin/codesign -dv --verbose=4 "$cli" 2>&1)" || return 1
    cdhash="$(
      printf '%s\n' "$output" \
        | awk -F= '/^CDHash=/ {print tolower($2); exit}'
    )"
    case "$cdhash" in
      ""|*[!0-9a-f]*) return 1;;
    esac
    [ "${#cdhash}" -ge 40 ] && [ "${#cdhash}" -le 64 ] || return 1
    printf '%s\n' "$cdhash"
    return
  fi
  device_trust_test_mode_authorized || return 1
  sha="$(device_trust_cli_sha256 "$cli")" || return 1
  printf 'test-sha256-%s\n' "$sha"
}

device_trust_signer_binary_matches() {
  local cli="$1" expected_sha="$2" expected_cdhash="$3"
  [ -f "$cli" ] && [ ! -L "$cli" ] && [ -x "$cli" ] || return 1
  [ "$(device_trust_cli_sha256 "$cli")" = "$expected_sha" ] \
    && [ "$(device_trust_cli_cdhash "$cli")" = "$expected_cdhash" ]
}

validate_requested_device_trust_signer() {
  local requested="$1"
  local expected_sha="$DEVICE_TRUST_CLI_EXPECTED_SHA256"
  local expected_cdhash="$DEVICE_TRUST_CLI_EXPECTED_CDHASH"
  local actual_sha="" actual_cdhash="" test_digest=""
  case "$requested" in
    /*) ;;
    *)
      echo "--device-trust-cli 必須是絕對路徑" >&2
      return 1
      ;;
  esac
  [ -f "$requested" ] && [ ! -L "$requested" ] && [ -x "$requested" ] \
    || {
      echo "--device-trust-cli 必須是可執行的普通檔案，且不可為 symbolic link" >&2
      return 1
    }
  case "$expected_sha" in
    ""|*[!0-9a-f]*)
      echo "--device-trust-cli-sha256 必須是 64 位 lowercase hexadecimal" >&2
      return 1
      ;;
  esac
  [ "${#expected_sha}" = "64" ] \
    || {
      echo "--device-trust-cli-sha256 必須是 64 位 lowercase hexadecimal" >&2
      return 1
    }
  case "$expected_cdhash" in
    test-sha256-*)
      device_trust_test_mode_authorized \
        || {
          echo "test signer CDHash 只允許在受控 test mode" >&2
          return 1
        }
      test_digest="${expected_cdhash#test-sha256-}"
      case "$test_digest" in
        ""|*[!0-9a-f]*)
          echo "--device-trust-cli-cdhash 的 test digest 無效" >&2
          return 1
          ;;
      esac
      [ "${#test_digest}" = "64" ] \
        || {
          echo "--device-trust-cli-cdhash 的 test digest 無效" >&2
          return 1
        }
      ;;
    ""|*[!0-9a-f]*)
      echo "--device-trust-cli-cdhash 必須是 lowercase hexadecimal CDHash" >&2
      return 1
      ;;
    *)
      [ "${#expected_cdhash}" -ge 40 ] \
        && [ "${#expected_cdhash}" -le 64 ] \
        || {
          echo "--device-trust-cli-cdhash 長度必須介於 40 到 64 位" >&2
          return 1
        }
      ;;
  esac
  actual_sha="$(device_trust_cli_sha256 "$requested")" || return 1
  actual_cdhash="$(device_trust_cli_cdhash "$requested")" || return 1
  [ "$actual_sha" = "$expected_sha" ] \
    || {
      echo "指定的 device-trust signer SHA-256 與預期值不符" >&2
      return 1
    }
  [ "$actual_cdhash" = "$expected_cdhash" ] \
    || {
      echo "指定的 device-trust signer CDHash 與預期值不符" >&2
      return 1
    }
  cli_supports_device_trust "$requested" \
    || {
      echo "指定的 device-trust signer 不支援 TatwoDeviceTrustCLI.v1" >&2
      return 1
    }
}

load_device_trust_signer_pin() {
  [ -f "$DEVICE_TRUST_SIGNER_PIN" ] \
    && [ ! -L "$DEVICE_TRUST_SIGNER_PIN" ] \
    && [ "$(stat -f '%Lp' "$DEVICE_TRUST_SIGNER_PIN" 2>/dev/null)" = "600" ] \
    || return 1
  local schema signer_path sha cdhash
  schema="$(plutil -extract schema raw "$DEVICE_TRUST_SIGNER_PIN" 2>/dev/null)" \
    || return 1
  signer_path="$(
    plutil -extract signerPath raw "$DEVICE_TRUST_SIGNER_PIN" 2>/dev/null
  )" || return 1
  sha="$(plutil -extract sha256 raw "$DEVICE_TRUST_SIGNER_PIN" 2>/dev/null)" \
    || return 1
  cdhash="$(
    plutil -extract codeDirectoryHash raw "$DEVICE_TRUST_SIGNER_PIN" 2>/dev/null
  )" || return 1
  [ "$schema" = "TatwoDeviceTrustSignerPinV1" ] \
    && [ "$signer_path" = "$DEVICE_TRUST_SIGNER" ] \
    || return 1
  case "$sha" in
    ""|*[!0-9a-f]*) return 1;;
  esac
  [ "${#sha}" = "64" ] || return 1
  case "$cdhash" in
    test-sha256-*)
      device_trust_test_mode_authorized || return 1
      ;;
    ""|*[!0-9a-f]*)
      return 1
      ;;
    *)
      [ "${#cdhash}" -ge 40 ] && [ "${#cdhash}" -le 64 ] || return 1
      ;;
  esac
  device_trust_signer_binary_matches "$signer_path" "$sha" "$cdhash" \
    || return 1
  DEVICE_TRUST_CLI_SHA256="$sha"
  DEVICE_TRUST_CLI_CDHASH="$cdhash"
}

prove_device_trust_signer_adoption() {
  local candidate="$1" source_mode="$2"
  local expected_sha="$3" expected_cdhash="$4"
  local identity="$APP_SUPPORT/device-trust/identity.json"
  if [ ! -e "$identity" ] && [ ! -L "$identity" ]; then
    return 0
  fi
  [ -f "$identity" ] && [ ! -L "$identity" ] \
    || {
      echo "既有 device-trust identity 不是受信任的普通檔案；拒絕 signer 採用" >&2
      return 1
    }
  local receipt_root nonce signature assert_output sign_output verify_output
  local stamp candidate_sha candidate_cdhash identity_digest nonce_digest
  [ -n "$expected_sha" ] && [ -n "$expected_cdhash" ] \
    || {
      echo "既有 identity 的 signer 採用缺少預期 SHA-256／CDHash" >&2
      return 1
    }
  candidate_sha="$(device_trust_cli_sha256 "$candidate")" || return 1
  candidate_cdhash="$(device_trust_cli_cdhash "$candidate")" || return 1
  [ "$candidate_sha" = "$expected_sha" ] \
    && [ "$candidate_cdhash" = "$expected_cdhash" ] \
    || {
      echo "候選 device-trust signer 在 possession proof 前已偏離預期 pins" >&2
      return 1
    }
  stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  receipt_root="$APP_SUPPORT/device-trust/signer-adoption-receipts/$stamp"
  mkdir -p "$receipt_root"
  chmod 700 "$APP_SUPPORT/device-trust/signer-adoption-receipts" "$receipt_root"
  nonce="$receipt_root/nonce.txt"
  signature="$receipt_root/signature.json"
  assert_output="$receipt_root/assert-local.json"
  sign_output="$receipt_root/sign.json"
  verify_output="$receipt_root/verify.json"
  printf 'tatwo-device-trust-signer-adoption\nnonce=%s\nhost=%s\ntime=%s\n' \
    "$(uuidgen)" "$(hostname)" "$(date -u +%FT%TZ)" >"$nonce"
  chmod 600 "$nonce"
  "$candidate" device-trust assert-local \
    --registry "$identity" >"$assert_output" \
    || {
      echo "候選 device-trust signer 無法存取既有本機私鑰；拒絕採用" >&2
      return 1
    }
  "$candidate" device-trust sign \
    --registry "$identity" \
    --input "$nonce" \
    --purpose device-trust-signer-adoption \
    --signature-out "$signature" >"$sign_output" \
    || {
      echo "候選 device-trust signer 無法簽署 fresh nonce；拒絕採用" >&2
      return 1
    }
  "$CLI_PATH" device-trust verify \
    --registry "$identity" \
    --input "$nonce" \
    --purpose device-trust-signer-adoption \
    --signature "$signature" >"$verify_output" \
    || {
      echo "候選 device-trust signer 的 fresh nonce 簽章驗證失敗；拒絕採用" >&2
      return 1
    }
  identity_digest="$(
    shasum -a 256 "$identity" | awk 'NR == 1 {print tolower($1)}'
  )" || return 1
  nonce_digest="$(
    shasum -a 256 "$nonce" | awk 'NR == 1 {print tolower($1)}'
  )" || return 1
  "$PYTHON3" - \
    "$receipt_root/receipt.json" "$source_mode" "$candidate" \
    "$candidate_sha" "$candidate_cdhash" "$expected_sha" "$expected_cdhash" \
    "$identity" "$identity_digest" "$nonce_digest" "$signature" <<'PY'
import datetime
import json
import os
import sys

(
    output,
    source_mode,
    signer,
    sha256,
    cdhash,
    expected_sha256,
    expected_cdhash,
    identity_path,
    identity_digest,
    nonce_digest,
    signature_path,
) = sys.argv[1:]
with open(identity_path, "r", encoding="utf-8") as handle:
    identity = json.load(handle)
with open(signature_path, "r", encoding="utf-8") as handle:
    signature = json.load(handle)
receipt = {
    "schema": "TatwoDeviceTrustSignerAdoptionReceiptV1",
    "sourceMode": source_mode,
    "signerSourcePath": signer,
    "sha256": sha256,
    "codeDirectoryHash": cdhash,
    "expectedSHA256": expected_sha256,
    "expectedCodeDirectoryHash": expected_cdhash,
    "identityDigest": identity_digest,
    "nonceDigest": nonce_digest,
    "deviceID": identity["deviceID"],
    "keyID": identity["keyID"],
    "keyGeneration": identity["keyGeneration"],
    "payloadDigest": signature["payloadDigest"],
    "verifiedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
stage = output + ".staging"
with open(stage, "w", encoding="utf-8") as handle:
    json.dump(receipt, handle, ensure_ascii=False, indent=2, sort_keys=True)
    handle.write("\n")
os.chmod(stage, 0o600)
os.replace(stage, output)
PY
}

install_device_trust_signer_anchor() {
  local source="$1" source_mode="$2"
  local source_sha source_cdhash stamp stage pin_stage backup_root failed_root
  local signer_backup pin_backup had_signer=0 had_pin=0
  local signer_activated=0 pin_activated=0 restore_stage restore_pin_stage
  local rollback_ok=1
  source_sha="$(device_trust_cli_sha256 "$source")" || return 1
  source_cdhash="$(device_trust_cli_cdhash "$source")" || {
    echo "device-trust signer 缺少可驗證的 code directory hash" >&2
    return 1
  }
  if [ -n "$DEVICE_TRUST_CLI_EXPECTED_SHA256" ] \
    || [ -n "$DEVICE_TRUST_CLI_EXPECTED_CDHASH" ]
  then
    [ -n "$DEVICE_TRUST_CLI_EXPECTED_SHA256" ] \
      && [ -n "$DEVICE_TRUST_CLI_EXPECTED_CDHASH" ] \
      && [ "$source_sha" = "$DEVICE_TRUST_CLI_EXPECTED_SHA256" ] \
      && [ "$source_cdhash" = "$DEVICE_TRUST_CLI_EXPECTED_CDHASH" ] \
      || {
        echo "device-trust signer 在 possession proof 後偏離預期 pins；拒絕安裝" >&2
        return 1
      }
  fi
  mkdir -p "$DEVICE_TRUST_SIGNER_ROOT"
  chmod 700 "$APP_SUPPORT/device-trust" "$DEVICE_TRUST_SIGNER_ROOT"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  stage="$DEVICE_TRUST_SIGNER_ROOT/.tatwo-device-trust-signer-v1.staging.$stamp"
  pin_stage="$APP_SUPPORT/device-trust/.signer-pin.staging.$stamp.json"
  backup_root="$APP_SUPPORT/enrollment-backups/device-trust-signer"
  failed_root="$APP_SUPPORT/failed-enrollment-signers"
  signer_backup="$backup_root/signer-$stamp"
  pin_backup="$backup_root/signer-pin-$stamp.json"
  mkdir -p "$backup_root" "$failed_root"
  chmod 700 "$backup_root" "$failed_root"
  cp -p "$source" "$stage" || return 1
  chmod 500 "$stage"
  device_trust_signer_binary_matches "$stage" "$source_sha" "$source_cdhash" \
    || {
      mv "$stage" "$failed_root/signer-integrity-failed-$stamp"
      echo "device-trust signer staging 完整性驗證失敗" >&2
      return 1
    }
  "$PYTHON3" - \
    "$pin_stage" "$DEVICE_TRUST_SIGNER" "$source_sha" "$source_cdhash" \
    "$source_mode" <<'PY'
import datetime
import json
import os
import sys

output, signer, sha256, cdhash, source_mode = sys.argv[1:]
payload = {
    "schema": "TatwoDeviceTrustSignerPinV1",
    "signerPath": signer,
    "sha256": sha256,
    "codeDirectoryHash": cdhash,
    "sourceMode": source_mode,
    "installedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
    handle.write("\n")
os.chmod(output, 0o600)
PY
  if [ -e "$DEVICE_TRUST_SIGNER" ]; then
    had_signer=1
  fi
  if [ -e "$DEVICE_TRUST_SIGNER_PIN" ]; then
    had_pin=1
  fi
  if [ "$had_signer" != "$had_pin" ]; then
    mv "$stage" "$failed_root/signer-anchor-pair-incomplete-$stamp" \
      2>/dev/null || true
    mv "$pin_stage" "$failed_root/signer-pin-anchor-pair-incomplete-$stamp.json" \
      2>/dev/null || true
    echo "device-trust signer anchor 與 pin 並非完整配對；拒絕覆寫" >&2
    return 1
  fi
  if [ "$had_signer" = "1" ]; then
    if ! cp -p "$DEVICE_TRUST_SIGNER" "$signer_backup" \
      || ! cp -p "$DEVICE_TRUST_SIGNER_PIN" "$pin_backup"
    then
      mv "$stage" "$failed_root/signer-backup-failed-$stamp" \
        2>/dev/null || true
      mv "$pin_stage" "$failed_root/signer-pin-backup-failed-$stamp.json" \
        2>/dev/null || true
      echo "無法完整備份既有 device-trust signer anchor；拒絕換裝" >&2
      return 1
    fi
  fi

  if ! mv "$stage" "$DEVICE_TRUST_SIGNER"; then
    [ ! -e "$stage" ] \
      || mv "$stage" "$failed_root/signer-activation-failed-$stamp"
    [ ! -e "$pin_stage" ] \
      || mv "$pin_stage" "$failed_root/signer-pin-activation-failed-$stamp.json"
    echo "device-trust signer anchor 啟用失敗；既有 anchor 保持不變" >&2
    return 1
  fi
  signer_activated=1
  if mv "$pin_stage" "$DEVICE_TRUST_SIGNER_PIN"; then
    pin_activated=1
  fi

  if [ "$pin_activated" = "1" ] && load_device_trust_signer_pin; then
    DEVICE_TRUST_CLI_SHA256="$source_sha"
    DEVICE_TRUST_CLI_CDHASH="$source_cdhash"
    return 0
  fi

  # Preserve the rejected replacement as evidence before restoring the exact
  # previously active pair. The backup is a copy rather than a moved-away live
  # file, so the signer path is never intentionally left missing before the new
  # binary is ready.
  if [ "$signer_activated" = "1" ] && [ -e "$DEVICE_TRUST_SIGNER" ]; then
    cp -p "$DEVICE_TRUST_SIGNER" \
      "$failed_root/signer-post-activation-rejected-$stamp" \
      2>/dev/null || true
  fi
  if [ "$pin_activated" = "1" ] && [ -e "$DEVICE_TRUST_SIGNER_PIN" ]; then
    cp -p "$DEVICE_TRUST_SIGNER_PIN" \
      "$failed_root/signer-pin-post-activation-rejected-$stamp.json" \
      2>/dev/null || true
  fi
  [ ! -e "$pin_stage" ] \
    || mv "$pin_stage" \
      "$failed_root/signer-pin-activation-failed-$stamp.json" \
      2>/dev/null || true

  if [ "$had_signer" = "1" ]; then
    restore_stage="$DEVICE_TRUST_SIGNER_ROOT/.tatwo-device-trust-signer-v1.rollback.$stamp"
    restore_pin_stage="$APP_SUPPORT/device-trust/.signer-pin.rollback.$stamp.json"
    if ! cp -p "$signer_backup" "$restore_stage" \
      || ! chmod 500 "$restore_stage" \
      || ! mv "$restore_stage" "$DEVICE_TRUST_SIGNER"
    then
      rollback_ok=0
      [ ! -e "$restore_stage" ] \
        || mv "$restore_stage" \
          "$failed_root/signer-rollback-staging-failed-$stamp" \
          2>/dev/null || true
    fi
    if ! cp -p "$pin_backup" "$restore_pin_stage" \
      || ! chmod 600 "$restore_pin_stage" \
      || ! mv "$restore_pin_stage" "$DEVICE_TRUST_SIGNER_PIN"
    then
      rollback_ok=0
      [ ! -e "$restore_pin_stage" ] \
        || mv "$restore_pin_stage" \
          "$failed_root/signer-pin-rollback-staging-failed-$stamp.json" \
          2>/dev/null || true
    fi
    if [ "$rollback_ok" = "1" ] && load_device_trust_signer_pin; then
      echo "device-trust signer anchor 啟用失敗；已原子回復前一組 signer/pin" >&2
    else
      echo "CRITICAL: device-trust signer anchor 回復未通過驗證；helper 必須保持卸載" >&2
      return 1
    fi
  else
    # First-key seeding has no previous anchor. Remove the authoritative pin
    # first, then archive the unadopted signer so no partial pair remains live.
    if [ "$pin_activated" = "1" ] && [ -e "$DEVICE_TRUST_SIGNER_PIN" ]; then
      mv "$DEVICE_TRUST_SIGNER_PIN" \
        "$failed_root/signer-pin-first-install-rejected-$stamp.json" \
        2>/dev/null || rollback_ok=0
    fi
    if [ "$signer_activated" = "1" ] && [ -e "$DEVICE_TRUST_SIGNER" ]; then
      mv "$DEVICE_TRUST_SIGNER" \
        "$failed_root/signer-first-install-rejected-$stamp" \
        2>/dev/null || rollback_ok=0
    fi
    if [ "$rollback_ok" != "1" ] \
      || [ -e "$DEVICE_TRUST_SIGNER_PIN" ] \
      || [ -e "$DEVICE_TRUST_SIGNER" ]
    then
      echo "CRITICAL: 首次 device-trust signer 啟用失敗且無法清除 partial anchor；helper 必須保持卸載" >&2
      return 1
    fi
    echo "device-trust signer anchor 首次啟用失敗；未留下 partial anchor" >&2
  fi
  return 1
}

resolve_device_trust_signer() {
  local requested="$DEVICE_TRUST_CLI_SOURCE" source="" source_mode=""
  local identity="$APP_SUPPORT/device-trust/identity.json"
  local pin_loaded=0
  if [ -z "$requested" ] \
    && {
      [ -n "$DEVICE_TRUST_CLI_EXPECTED_SHA256" ] \
        || [ -n "$DEVICE_TRUST_CLI_EXPECTED_CDHASH" ]
    }
  then
    echo "signer 預期 SHA-256／CDHash 不可脫離 --device-trust-cli 單獨指定" >&2
    return 1
  fi
  if [ "$DRY" = "1" ]; then
    if [ -n "$requested" ]; then
      validate_requested_device_trust_signer "$requested" || return 1
    fi
    printf '  [dry] immutable device-trust signer=%s\n' "$DEVICE_TRUST_SIGNER"
    printf '  [dry] signer pin=%s\n' "$DEVICE_TRUST_SIGNER_PIN"
    DEVICE_TRUST_CLI_SHA256="<resolved-at-enrollment>"
    DEVICE_TRUST_CLI_CDHASH="<resolved-at-enrollment>"
    return 0
  fi

  if load_device_trust_signer_pin; then
    pin_loaded=1
  elif [ -e "$DEVICE_TRUST_SIGNER_PIN" ] \
    || [ -L "$DEVICE_TRUST_SIGNER_PIN" ] \
    || [ -e "$DEVICE_TRUST_SIGNER" ] \
    || [ -L "$DEVICE_TRUST_SIGNER" ]
  then
    echo "既有 device-trust signer anchor 或 pin 已漂移；拒絕自動覆寫" >&2
    return 1
  fi

  if [ -n "$requested" ]; then
    validate_requested_device_trust_signer "$requested" || return 1
  fi

  if [ "$pin_loaded" = "1" ]; then
    if [ -z "$requested" ]; then
      return 0
    fi
    local requested_sha requested_cdhash
    requested_sha="$(device_trust_cli_sha256 "$requested")" || return 1
    requested_cdhash="$(device_trust_cli_cdhash "$requested")" || return 1
    if [ "$requested_sha" = "$DEVICE_TRUST_CLI_SHA256" ] \
      && [ "$requested_cdhash" = "$DEVICE_TRUST_CLI_CDHASH" ]
    then
      return 0
    fi
    source="$requested"
    source_mode="explicit-adoption"
  else
    if [ -e "$identity" ] || [ -L "$identity" ]; then
      if [ -z "$requested" ]; then
        echo "既有 device-trust identity 缺少 signer anchor/pin；禁止從 evolving CLI 自動重建" >&2
        return 1
      fi
      source="$requested"
      source_mode="explicit-adoption"
    elif [ -n "$requested" ]; then
      source="$requested"
      source_mode="explicit-seed-before-first-key"
    else
      source="$CLI_PATH"
      source_mode="seed-before-first-key"
    fi
  fi

  cli_supports_device_trust "$source" \
    || {
      echo "device-trust signer 來源不支援 TatwoDeviceTrustCLI.v1" >&2
      return 1
    }
  prove_device_trust_signer_adoption \
    "$source" "$source_mode" \
    "$DEVICE_TRUST_CLI_EXPECTED_SHA256" "$DEVICE_TRUST_CLI_EXPECTED_CDHASH" \
    || return 1
  install_device_trust_signer_anchor "$source" "$source_mode" || return 1
  load_device_trust_signer_pin \
    || {
      echo "device-trust signer pin 安裝後驗證失敗" >&2
      return 1
    }
}

resolve_or_install_cli() {
  local requested_cli="$CLI_PATH" build_path="$CLI_BUILD_PATH"
  local build_bin_path="" source_cli="" lock_file=""
  local stage="" archive="" rollback_stage="" stamp="" failed_root=""

  if [ "$DRY" = "1" ]; then
    case "$CLI_DEST" in /*) ;; *)
      echo "TATWO_ULTRAWORK_CLI_DEST 必須是絕對路徑" >&2
      return 1
      ;;
    esac
    if [ -n "$requested_cli" ]; then
      case "$requested_cli" in /*) ;; *)
        echo "--cli 必須是絕對路徑" >&2
        return 1
        ;;
      esac
      printf '  [dry] 驗證 Tatwo CLI 來源並原子換裝：%s → %s\n' \
        "$requested_cli" "$CLI_DEST"
    else
      printf '  [dry] 從目前 repo release build 建立並原子換裝 Tatwo CLI：%s\n' \
        "$CLI_DEST"
    fi
    CLI_PATH="$CLI_DEST"
    return 0
  fi

  case "$CLI_DEST" in /*) ;; *)
    echo "TATWO_ULTRAWORK_CLI_DEST 必須是絕對路徑" >&2
    return 1
    ;;
  esac

  if [ -n "$requested_cli" ]; then
    case "$requested_cli" in /*) ;; *)
      echo "--cli 必須是絕對路徑" >&2
      return 1
      ;;
    esac
    cli_supports_hot_sync "$requested_cli" \
      || { echo "指定的 Tatwo CLI 缺少 device-trust／Skillet 命令" >&2; return 1; }
    source_cli="$requested_cli"
    step "驗證並換裝指定 Tatwo CLI"
  else
    [ -n "$build_path" ] || build_path="$REPO/.build/out"
    command -v swift >/dev/null 2>&1 \
      || { echo "找不到支援熱同步的 Tatwo CLI，且無 Swift 可建立" >&2; return 1; }
    step "從目前 repo 建立支援 device-trust／Skillet 的 Tatwo CLI"
    if ! swift build \
        --package-path "$REPO" \
        --build-path "$build_path" \
        --product tatwo-ultrawork \
        -c release
    then
      echo "Tatwo CLI release build 失敗" >&2
      return 1
    fi
    if ! build_bin_path="$(
      swift build \
        --package-path "$REPO" \
        --build-path "$build_path" \
        -c release \
        --show-bin-path
    )"
    then
      echo "無法解析 Tatwo CLI release bin path" >&2
      return 1
    fi
    source_cli="$build_bin_path/tatwo-ultrawork"
    cli_supports_hot_sync "$source_cli" \
      || { echo "新 Tatwo CLI 缺少 device-trust／Skillet 命令" >&2; return 1; }
  fi

  if [ "$source_cli" = "$CLI_DEST" ]; then
    CLI_PATH="$CLI_DEST"
    return 0
  fi
  if [ -x "$CLI_DEST" ] \
    && cli_supports_hot_sync "$CLI_DEST" \
    && cmp -s "$source_cli" "$CLI_DEST"
  then
    CLI_PATH="$CLI_DEST"
    printf '  installed_cli=%s（已是相同版本，略過換裝）\n' "$CLI_PATH"
    return 0
  fi

  failed_root="$APP_SUPPORT/failed-enrollment-clis"
  if ! mkdir -p \
      "$(dirname "$CLI_DEST")" \
      "$APP_SUPPORT/enrollment-backups" \
      "$failed_root"
  then
    echo "無法建立 Tatwo CLI 安裝／備份目錄" >&2
    return 1
  fi
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  stage="$CLI_DEST.staging.$$"
  archive="$APP_SUPPORT/enrollment-backups/tatwo-ultrawork-cli-previous-$stamp-$$"
  lock_file="$CLI_DEST.install.lock"
  if ! /usr/bin/shlock -f "$lock_file" -p "$$"; then
    echo "另一個 enrollment 正在換裝 Tatwo CLI：$lock_file" >&2
    return 1
  fi
  trap '
    if [ -n "${stage:-}" ] && [ -e "$stage" ]; then
      mkdir -p "$failed_root" 2>/dev/null || true
      mv "$stage" "$failed_root/tatwo-ultrawork-interrupted-$stamp-$$" 2>/dev/null || true
    fi
    [ -z "${lock_file:-}" ] || rm -f "$lock_file"
    exit 130
  ' HUP INT TERM
  [ ! -e "$stage" ] \
    || {
      echo "Tatwo CLI staging 路徑已存在：$stage" >&2
      rm -f "$lock_file"
      trap - HUP INT TERM
      return 1
    }
  if ! cp "$source_cli" "$stage" || ! chmod +x "$stage"; then
    mkdir -p "$failed_root" 2>/dev/null || true
    mv "$stage" "$failed_root/tatwo-ultrawork-copy-failed-$stamp-$$" 2>/dev/null || true
    rm -f "$lock_file"
    trap - HUP INT TERM
    return 1
  fi
  if ! cli_supports_hot_sync "$stage"; then
    mkdir -p "$failed_root" 2>/dev/null || true
    mv "$stage" "$failed_root/tatwo-ultrawork-capability-failed-$stamp-$$" 2>/dev/null || true
    rm -f "$lock_file"
    trap - HUP INT TERM
    return 1
  fi
  if [ -e "$CLI_DEST" ]; then
    if ! cp -p "$CLI_DEST" "$archive"; then
      echo "無法備份既有 Tatwo CLI；拒絕換裝" >&2
      mkdir -p "$failed_root" 2>/dev/null || true
      mv "$stage" "$failed_root/tatwo-ultrawork-backup-failed-$stamp-$$" 2>/dev/null || true
      rm -f "$lock_file"
      trap - HUP INT TERM
      return 1
    fi
  else
    archive=""
  fi
  if ! mv "$stage" "$CLI_DEST"; then
    mkdir -p "$failed_root" 2>/dev/null || true
    mv "$stage" "$failed_root/tatwo-ultrawork-activation-failed-$stamp-$$" 2>/dev/null || true
    rm -f "$lock_file"
    trap - HUP INT TERM
    return 1
  fi
  if ! cli_supports_hot_sync "$CLI_DEST"; then
    cp -p "$CLI_DEST" \
      "$failed_root/tatwo-ultrawork-post-activation-failed-$stamp-$$" \
      2>/dev/null || true
    if [ -n "$archive" ] && [ -e "$archive" ]; then
      rollback_stage="$CLI_DEST.rollback-staging.$$"
      if cp -p "$archive" "$rollback_stage" \
        && mv "$rollback_stage" "$CLI_DEST"
      then
        echo "Tatwo CLI post-activation 驗證失敗；已原子回復前一版" >&2
      else
        mv "$rollback_stage" \
          "$failed_root/tatwo-ultrawork-rollback-staging-failed-$stamp-$$" \
          2>/dev/null || true
        echo "CRITICAL: Tatwo CLI post-activation 驗證失敗，前一版仍保存在 $archive" >&2
      fi
    else
      echo "Tatwo CLI post-activation 驗證失敗；無前一版可回復，保留目前檔案供診斷" >&2
    fi
    rm -f "$lock_file"
    trap - HUP INT TERM
    return 1
  fi
  CLI_PATH="$CLI_DEST"
  rm -f "$lock_file"
  trap - HUP INT TERM
  printf '  installed_cli=%s\n' "$CLI_PATH"
  [ -z "$archive" ] || printf '  archived_previous_cli=%s\n' "$archive"
}

case "$ROLE" in primary|secondary) ;; *) echo "role 需為 primary|secondary" >&2; exit 1;; esac
case "$NAME" in
  ""|.|..|*/*|*[!A-Za-z0-9._-]*)
    echo "name 僅允許 A-Z a-z 0-9 . _ -" >&2
    exit 1
    ;;
esac
case "$CHANNEL_REMOTE" in
  "")
    echo "--channel-remote 必填；GitHub origin 只作冷備份，不能自動當私人熱同步通道" >&2
    exit 1
    ;;
  http://*|https://*)
    echo "--channel-remote 不接受 HTTP(S) URL；請使用 SSH URL／SSH config alias 或受控本機 file path" >&2
    exit 1
    ;;
  *$'\n'*|*$'\r'*|*$'\t'*|*" "*)
    echo "--channel-remote 不得含空白或控制字元" >&2
    exit 1
    ;;
  *[!A-Za-z0-9._~:/@%+=,-]*)
    echo "--channel-remote 含不支援字元；請使用標準 SSH URL／scp-like remote 或 file path" >&2
    exit 1
    ;;
esac
case "$OS_ROOT" in
  "")
    echo "--os-root 必填；必須明確指定此設備的 Work OS constitution/issue/TODO 根目錄" >&2
    exit 1
    ;;
  /*) ;;
  *)
    echo "--os-root 必須是絕對路徑" >&2
    exit 1
    ;;
esac
case "$SKILLS_ROOT" in
  /*) ;;
  *)
    echo "--skills-root 必須是絕對路徑" >&2
    exit 1
    ;;
esac
case "$SKILLS_RUNTIME_ROOT" in
  /*) ;;
  *)
    echo "--skills-runtime-root 必須是絕對路徑" >&2
    exit 1
    ;;
esac
case "$SKILLS_CONSUMER_ROOT" in
  /*) ;;
  *)
    echo "--skills-consumer-root 必須是絕對路徑" >&2
    exit 1
    ;;
esac
case "$CODEX_SKILLS_LINK" in
  /*) ;;
  *)
    echo "--codex-skills-link 必須是絕對路徑" >&2
    exit 1
    ;;
esac
case "$CLAUDE_SKILLS_LINK" in
  /*) ;;
  *)
    echo "--claude-skills-link 必須是絕對路徑" >&2
    exit 1
    ;;
esac
case "$SKILLS_PROJECTION_SCRIPT" in
  /*) ;;
  *)
    echo "TATWO_SKILLS_CONSUMER_PROJECTION_SCRIPT 必須是絕對路徑" >&2
    exit 1
    ;;
esac
case "$SKILLS_ROOT$SKILLS_RUNTIME_ROOT$SKILLS_CONSUMER_ROOT$CODEX_SKILLS_LINK$CLAUDE_SKILLS_LINK$SKILLS_PROJECTION_SCRIPT" in
  *$'\n'*|*$'\r'*|*$'\t'*)
    echo "skills source/runtime/consumer/link 路徑不得含控制字元" >&2
    exit 1
    ;;
esac
if ! SKILLS_ROOTS_OVERLAP="$(
  "$PYTHON3" - "$SKILLS_ROOT" "$SKILLS_RUNTIME_ROOT" "$SKILLS_CONSUMER_ROOT" <<'PY'
import os
import sys

paths = [os.path.realpath(value) for value in sys.argv[1:]]
overlap = any(
    first == second
    or first.startswith(second + os.sep)
    or second.startswith(first + os.sep)
    for index, first in enumerate(paths)
    for second in paths[index + 1:]
)
print("1" if overlap else "0")
PY
)"
then
  echo "無法驗證 skills source/runtime root 分離" >&2
  exit 1
fi
if [ "$SKILLS_ROOTS_OVERLAP" = "1" ]; then
  echo "--skills-root、--skills-runtime-root、--skills-consumer-root 必須完全分離，且不得互相巢狀" >&2
  exit 1
fi

ensure_skillet_source_coordinate() {
  local coordinate="$APP_SUPPORT/skills"
  local volume_skills="${TATWO_SKILLS_SOURCE_ROOT:-$HOME/Library/Application Support/tatwo2/skills}"
  local coordinate_real volume_real runtime_real store_real consumer_real
  case "$SKILLS_ROOT" in
    "$coordinate") ;;
    *) return 0;;
  esac
  [ "$SKILLS_ROOT_EXPLICIT" = "0" ] || return 0
  if [ -e "$SKILLS_ROOT" ] || [ -L "$SKILLS_ROOT" ]; then
    return 0
  fi
  if [ -d "$volume_skills" ] && [ -r "$volume_skills" ] && [ -x "$volume_skills" ]; then
    if ! volume_real="$(
      "$PYTHON3" - "$volume_skills" "$SKILLS_RUNTIME_ROOT" "$APP_SUPPORT/skillet" "$SKILLS_CONSUMER_ROOT" <<'PY'
import os
import sys

volume = os.path.realpath(sys.argv[1])
forbidden = [os.path.realpath(value) for value in sys.argv[2:]]
if any(
    volume == other
    or volume.startswith(other + os.sep)
    or other.startswith(volume + os.sep)
    for other in forbidden
):
    raise SystemExit(2)
print(volume)
PY
    )"
    then
      echo "拒絕把 App Support/skills 橋到 runtime、store 或 consumer" >&2
      exit 1
    fi
    if [ "$DRY" = "1" ]; then
      printf '  [dry] ln -s %s %s\n' "$volume_skills" "$SKILLS_ROOT"
    else
      mkdir -p "$APP_SUPPORT"
      ln -s "$volume_skills" "$SKILLS_ROOT"
      coordinate_real="$(
        "$PYTHON3" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$SKILLS_ROOT"
      )"
      [ "$coordinate_real" = "$volume_real" ] \
        || {
          echo "skills 橋接 symlink 未指向 $volume_skills" >&2
          exit 1
        }
    fi
    return 0
  fi
  if [ "$DRY" = "1" ]; then
    printf '  [dry] mkdir -p %s\n' "$SKILLS_ROOT"
  else
    mkdir -p "$SKILLS_ROOT"
  fi
}
ensure_skillet_source_coordinate

if [ "$ROLE" = "primary" ] || [ "$SKILLS_ROOT_EXPLICIT" = "1" ] || [ "$DRY" != "1" ]; then
  [ -d "$SKILLS_ROOT" ] && [ -r "$SKILLS_ROOT" ] && [ -x "$SKILLS_ROOT" ] \
    || {
      echo "--skills-root 必須是可讀取的 canonical skills 目錄" >&2
      exit 1
    }
  if ! find -L "$SKILLS_ROOT" \
      -mindepth 2 -maxdepth 2 -type f -name SKILL.md -print -quit \
      2>/dev/null | grep -q .
  then
    echo "--skills-root 未包含任何受管 SKILL.md" >&2
    exit 1
  fi
fi
case "$OS_ROOT" in
  *$'\n'*|*$'\r'*|*$'\t'*)
    echo "--os-root 不得含控制字元" >&2
    exit 1
    ;;
esac
echo "== TatwoOS 設備納管：role=$ROLE name=$NAME primary=$PRIMARY_HOST dry=$DRY =="

# 1) repo
step "準備 repo：${REPO}（分支 ${BRANCH}）"
if git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # fetch 失敗（例如此設備沒有 GitHub https 認證，只能靠 LAN 直推等替代管道
  # 先把分支帶到本機）不視為致命錯誤：容錯繼續，用本機現有分支狀態往下走。
  if [ "$DRY" = "1" ]; then
    printf '  [dry] git -C "%s" fetch origin "%s"\n' "$REPO" "$BRANCH"
  else
    git -C "$REPO" fetch origin "$BRANCH" 2>&1 || echo "  警告：fetch 失敗（可能無 GitHub 認證），沿用本機現有分支狀態"
  fi
  run "git -C \"$REPO\" checkout \"$BRANCH\" 2>/dev/null || git -C \"$REPO\" checkout -B \"$BRANCH\" \"origin/$BRANCH\" 2>/dev/null || true"
  run "git -C \"$REPO\" merge --ff-only \"origin/$BRANCH\" 2>/dev/null || true"
else
  run "git clone --branch \"$BRANCH\" \"$REPO_URL\" \"$REPO\""
fi

SYNC="$REPO/scripts/tatwo-device-sync.sh"
step "驗證 Tatwo CLI 熱同步能力"
resolve_or_install_cli \
  || { echo "Tatwo CLI 準備失敗；未登記設備、未載入 helper" >&2; exit 1; }
step "驗證或建立不可變 device-trust signer anchor"
resolve_device_trust_signer \
  || { echo "device-trust signer anchor 準備失敗；未登記設備、未載入 helper" >&2; exit 1; }
export TATWO_DEVICE_NAME="$NAME" TATWO_PRIMARY_SSH_HOST="$PRIMARY_HOST" \
  TATWO_SYNC_REPO="$REPO" TATWO_CHANNEL_REMOTE="$CHANNEL_REMOTE" \
  TATWO_OS_ROOT="$OS_ROOT" TATWO_SKILLET_CLI="$CLI_PATH" \
  TATWO_DEVICE_TRUST_CLI="$DEVICE_TRUST_SIGNER" \
  TATWO_DEVICE_TRUST_CLI_SHA256="$DEVICE_TRUST_CLI_SHA256" \
  TATWO_DEVICE_TRUST_CLI_CDHASH="$DEVICE_TRUST_CLI_CDHASH" \
  TATWO_SKILLET_SOURCE_ROOT="$SKILLS_ROOT" \
  TATWO_SKILLS_RUNTIME_ROOT="$SKILLS_RUNTIME_ROOT" \
  TATWO_SKILLS_CONSUMER_ROOT="$SKILLS_CONSUMER_ROOT" \
  TATWO_CODEX_SKILLS_LINK="$CODEX_SKILLS_LINK" \
  TATWO_CLAUDE_SKILLS_LINK="$CLAUDE_SKILLS_LINK" \
  TATWO_SKILLS_CONSUMER_PROJECTION_SCRIPT="$SKILLS_PROJECTION_SCRIPT"

# 1.5) 建立單一受管 consumer indirection。這一步先於設備註冊、App 安裝與
# helper 載入；任何未知實體目錄、link drift 或 projection journal 問題都會
# fail closed，避免同步服務啟動後才發現 Codex／Claude 仍讀舊 skills。
step "建立 Codex／Claude 原生 skills consumer 投影"
if [ "$DRY" = "1" ]; then
  printf '  [dry] Skills consumer root=%s\n' "$SKILLS_CONSUMER_ROOT"
  printf '  [dry] Codex skills link=%s\n' "$CODEX_SKILLS_LINK"
  printf '  [dry] Claude skills link=%s\n' "$CLAUDE_SKILLS_LINK"
  printf '  [dry] Consumer projection script=%s\n' "$SKILLS_PROJECTION_SCRIPT"
else
  [ -f "$SKILLS_PROJECTION_SCRIPT" ] && [ -x "$SKILLS_PROJECTION_SCRIPT" ] \
    || {
      echo "skills consumer projection script 不存在或不可執行：$SKILLS_PROJECTION_SCRIPT" >&2
      exit 1
    }
  PROJECTION_RECEIPT_ROOT="$APP_SUPPORT/device-sync-state/skills-consumer-projection/enrollment"
  mkdir -p "$PROJECTION_RECEIPT_ROOT"
  PROJECTION_RECEIPT="$PROJECTION_RECEIPT_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
  "$PYTHON3" "$SKILLS_PROJECTION_SCRIPT" enroll \
    --source-root "$SKILLS_ROOT" \
    --runtime-root "$SKILLS_RUNTIME_ROOT" \
    --consumer-root "$SKILLS_CONSUMER_ROOT" \
    --codex-skills-link "$CODEX_SKILLS_LINK" \
    --claude-skills-link "$CLAUDE_SKILLS_LINK" \
    --receipt "$PROJECTION_RECEIPT" >/dev/null \
    || {
      echo "skills consumer bootstrap 失敗；未登記設備、未安裝 App、未載入 helper" >&2
      exit 1
    }
  printf '  projection_receipt=%s\n' "$PROJECTION_RECEIPT"
fi

# 2) 設備身分 + 登記到通道
step "產生設備身分並登記到同步通道"
if [ -n "$PAIRING_SEED" ]; then
  run "bash \"$SYNC\" register --role \"$ROLE\" --name \"$NAME\" --host \"$PRIMARY_HOST\" --pairing-seed \"$PAIRING_SEED\""
else
  run "bash \"$SYNC\" register --role \"$ROLE\" --name \"$NAME\" --host \"$PRIMARY_HOST\""
fi

# 3) 裝 App
if [ "$DO_APP" = "1" ]; then
  step "裝 App（build + ad-hoc + 備份舊版）"
  run "bash \"$REPO/scripts/tatwo-install-local-app.sh\""
else
  step "跳過裝 App（--no-app）"
fi

# 3.5) 副設備自動偵測主設備的 app-support 路徑（使用者名稱不同時，
#      db-pull 若沿用本機路徑去檢查主設備會誤判「遠端不存在」）。
if [ "$ROLE" = "secondary" ] && [ -z "$REMOTE_APP_SUPPORT" ] && [ "$DRY" != "1" ]; then
  step "偵測主設備 app-support 路徑"
  remote_home="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$PRIMARY_HOST" 'echo $HOME' 2>/dev/null || true)"
  if [ -n "$remote_home" ]; then
    REMOTE_APP_SUPPORT="$remote_home/Library/Application Support/Tatwo Ultrawork"
    echo "  偵測到：$REMOTE_APP_SUPPORT"
  else
    echo "  警告：無法連到主設備偵測路徑，db-pull 需之後手動補 --remote-app-support 重新納管"
  fi
fi

# 4) 裝常駐同步 helper（LaunchAgent）——主／副設備都要裝：
#    主設備要處理本機動作（新增設備配對碼/設為主設備/回傳版本）與轉發同步請求；
#    副設備要接收主設備發起的同步。helper 內部依 role-status 動態判斷行為，
#    角色切換（轉移主權）時不需要重裝。
if [ "$DO_HELPER" = "1" ]; then
  step "裝常駐同步 helper"
  HELPER="$REPO/scripts/tatwo-sync-helper.sh"
  TEMPLATE="$REPO/scripts/templates/com.tatwo.device-sync-helper.plist"
  PLIST="$HOME/Library/LaunchAgents/com.tatwo.device-sync-helper.plist"
  LOG="$APP_SUPPORT/sync-helper.out.log"
  if [ "$DRY" = "1" ]; then
    printf '  [dry] 由模板產 %s（HELPER=%s DEVICE=%s PRIMARY=%s INTERVAL=%s）\n' \
      "$PLIST" "$HELPER" "$NAME" "$PRIMARY_HOST" "$INTERVAL"
    printf '  [dry] 私人熱同步 remote=%s\n' "$CHANNEL_REMOTE"
    printf '  [dry] Work OS root=%s\n' "$OS_ROOT"
    printf '  [dry] Canonical skills root=%s\n' "$SKILLS_ROOT"
    printf '  [dry] Skills runtime root=%s\n' "$SKILLS_RUNTIME_ROOT"
    printf '  [dry] Skills consumer root=%s\n' "$SKILLS_CONSUMER_ROOT"
    printf '  [dry] Codex skills link=%s\n' "$CODEX_SKILLS_LINK"
    printf '  [dry] Claude skills link=%s\n' "$CLAUDE_SKILLS_LINK"
    printf '  [dry] Skills projection script=%s\n' "$SKILLS_PROJECTION_SCRIPT"
    printf '  [dry] Tatwo CLI=%s\n' "$CLI_PATH"
    printf '  [dry] Helper test mode=0\n'
    printf '  [dry] launchctl unload/load %s\n' "$PLIST"
  else
    mkdir -p "$HOME/Library/LaunchAgents" "$APP_SUPPORT"
    # launchd 預設 PATH 精簡、不讀 shell rc（找不到 Homebrew／可攜版 node），
    # 明確帶入常見安裝位置，避免 tatwo-safe-app-bundle.sh 等步驟因找不到
    # node 而靜默略過收據寫入（已在 MacBook 實測踩到）。
    PATH_ENV="/opt/homebrew/bin:/usr/local/bin:$HOME/bin:$HOME/.local/bin:$HOME/.local/node/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    PLIST_STAGE="$PLIST.staging.$$"
    cp "$TEMPLATE" "$PLIST_STAGE"
    if plutil -remove ProgramArguments.1 "$PLIST_STAGE" \
      && plutil -insert ProgramArguments.1 -string "$HELPER" "$PLIST_STAGE" \
      && plutil -replace EnvironmentVariables.TATWO_DEVICE_NAME -string "$NAME" "$PLIST_STAGE" \
      && plutil -replace EnvironmentVariables.TATWO_PRIMARY_SSH_HOST -string "$PRIMARY_HOST" "$PLIST_STAGE" \
      && plutil -replace EnvironmentVariables.TATWO_SYNC_REPO -string "$REPO" "$PLIST_STAGE" \
      && plutil -replace EnvironmentVariables.TATWO_SYNC_INTERVAL -string "$INTERVAL" "$PLIST_STAGE" \
      && plutil -replace EnvironmentVariables.TATWO_CHANNEL_REMOTE -string "$CHANNEL_REMOTE" "$PLIST_STAGE" \
      && plutil -replace EnvironmentVariables.TATWO_OS_ROOT -string "$OS_ROOT" "$PLIST_STAGE" \
      && plutil -replace EnvironmentVariables.TATWO_SKILLET_SOURCE_ROOT -string "$SKILLS_ROOT" "$PLIST_STAGE" \
      && plutil -replace EnvironmentVariables.TATWO_SKILLS_RUNTIME_ROOT -string "$SKILLS_RUNTIME_ROOT" "$PLIST_STAGE" \
      && plutil -replace EnvironmentVariables.TATWO_SKILLS_CONSUMER_ROOT -string "$SKILLS_CONSUMER_ROOT" "$PLIST_STAGE" \
      && plutil -replace EnvironmentVariables.TATWO_CODEX_SKILLS_LINK -string "$CODEX_SKILLS_LINK" "$PLIST_STAGE" \
      && plutil -replace EnvironmentVariables.TATWO_CLAUDE_SKILLS_LINK -string "$CLAUDE_SKILLS_LINK" "$PLIST_STAGE" \
      && plutil -replace EnvironmentVariables.TATWO_SKILLS_CONSUMER_PROJECTION_SCRIPT -string "$SKILLS_PROJECTION_SCRIPT" "$PLIST_STAGE" \
      && plutil -replace EnvironmentVariables.TATWO_SKILLET_SOURCE_REGISTRY -string "$REPO/config/tatwo-skillet-source-registry-v1.json" "$PLIST_STAGE" \
      && plutil -replace EnvironmentVariables.TATWO_SKILLET_CLI -string "$CLI_PATH" "$PLIST_STAGE" \
      && plutil -replace EnvironmentVariables.TATWO_DEVICE_TRUST_CLI -string "$DEVICE_TRUST_SIGNER" "$PLIST_STAGE" \
      && plutil -replace EnvironmentVariables.TATWO_DEVICE_TRUST_CLI_SHA256 -string "$DEVICE_TRUST_CLI_SHA256" "$PLIST_STAGE" \
      && plutil -replace EnvironmentVariables.TATWO_DEVICE_TRUST_CLI_CDHASH -string "$DEVICE_TRUST_CLI_CDHASH" "$PLIST_STAGE" \
      && plutil -replace EnvironmentVariables.TATWO_REMOTE_APP_SUPPORT -string "$REMOTE_APP_SUPPORT" "$PLIST_STAGE" \
      && plutil -replace EnvironmentVariables.TATWO_TEST_MODE -string "0" "$PLIST_STAGE" \
      && plutil -replace EnvironmentVariables.PATH -string "$PATH_ENV" "$PLIST_STAGE" \
      && plutil -replace StandardOutPath -string "$LOG" "$PLIST_STAGE" \
      && plutil -replace StandardErrorPath -string "$LOG" "$PLIST_STAGE" \
      && [ "$(plutil -extract EnvironmentVariables.TATWO_TEST_MODE raw "$PLIST_STAGE")" = "0" ] \
      && ! grep -Eq '__[A-Z0-9_]+__' "$PLIST_STAGE" \
      && plutil -lint "$PLIST_STAGE" >/dev/null
    then
      if [ -f "$PLIST" ]; then
        PLIST_BACKUP_ROOT="$APP_SUPPORT/enrollment-backups"
        mkdir -p "$PLIST_BACKUP_ROOT"
        cp -p "$PLIST" \
          "$PLIST_BACKUP_ROOT/com.tatwo.device-sync-helper.$(date -u +%Y%m%dT%H%M%SZ).plist"
      fi
      mv "$PLIST_STAGE" "$PLIST"
    else
      FAILED_PLIST_ROOT="$APP_SUPPORT/failed-enrollment-plists"
      mkdir -p "$FAILED_PLIST_ROOT"
      mv "$PLIST_STAGE" \
        "$FAILED_PLIST_ROOT/com.tatwo.device-sync-helper.$(date -u +%Y%m%dT%H%M%SZ).$$.plist" \
        2>/dev/null || true
      echo "helper plist 產生或 plutil 驗證失敗；未載入 LaunchAgent" >&2
      exit 1
    fi
    LAUNCH_DOMAIN="gui/$(id -u)"
    launchctl bootout "user/$(id -u)/com.tatwo.device-sync-helper" 2>/dev/null || true
    launchctl bootout "$LAUNCH_DOMAIN/com.tatwo.device-sync-helper" 2>/dev/null || true
    launchctl bootstrap "$LAUNCH_DOMAIN" "$PLIST" \
      || { echo "無法將同步 helper 載入 Aqua launchd domain：$LAUNCH_DOMAIN" >&2; exit 1; }
    launchctl kickstart -k "$LAUNCH_DOMAIN/com.tatwo.device-sync-helper" \
      || { echo "同步 helper 已 bootstrap，但無法在 Aqua domain 啟動" >&2; exit 1; }
    echo "  helper 已常駐（Aqua LaunchAgent）。移除：launchctl bootout \"$LAUNCH_DOMAIN/com.tatwo.device-sync-helper\""
  fi
else
  step "不裝常駐 helper（--no-helper）"
fi

echo "== 納管完成 =="
if [ "$ROLE" = "secondary" ]; then
  echo "此設備已加入私人熱同步通道：現任主設備逐台發 request，本機 helper 回傳 digest ACK 後才算收斂。"
else
  echo "主設備已登記。發起同步：bash \"$SYNC\" sync-request --target <副設備名> --action system-pull"
fi
