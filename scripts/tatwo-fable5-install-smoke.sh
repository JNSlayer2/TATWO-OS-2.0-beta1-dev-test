#!/usr/bin/env bash
# 裝機後 fable5 路由冒煙（fable5 出品，2026-08-23）：
# 用「安裝版 App 內建 helper＋App profile＋token 注入＋vendor 模型名＋結構化輸出」
# 完整重演 chat 訂閱路由的一則真訊息。收不到真回覆＝紅。
# 起因：unrecognized_model 斷線在使用者手上晃了兩天——E2E 缺口封口件。
set -euo pipefail

APP="${TATWO_ULTRAWORK_APP:-/Applications/Tatwo Ultrawork.app}"
HELPER="$APP/Contents/Helpers/TatwoClaudeSubscriptionRuntime"
PROFILE="${TATWO_CLAUDE_PROFILE:-$HOME/Library/Application Support/Tatwo Ultrawork/model-subscriptions/claude}"
TOKEN_FILE="$PROFILE/claude-oauth-token"
MODEL="${TATWO_SMOKE_VENDOR_MODEL:-claude-fable-5}"

fail() { echo "fable5_install_smoke=failed reason=$1" >&2; exit 1; }

[ -x "$HELPER" ] || fail "helper_missing:$HELPER"
[ -f "$TOKEN_FILE" ] || fail "profile_token_missing:$TOKEN_FILE"

SCHEMA='{"type":"object","properties":{"kind":{"type":"string","enum":["assistant_text"]},"text":{"type":"string"}},"required":["kind","text"],"additionalProperties":false}'
NONCE="smoke-$(date +%s)"

OUTPUT=$(HOME="$PROFILE" CLAUDE_CODE_OAUTH_TOKEN="$(cat "$TOKEN_FILE")" \
  "$HELPER" -p --model "$MODEL" --effort low --safe-mode \
  --permission-mode dontAsk --tools "" --no-session-persistence \
  --output-format json --json-schema "$SCHEMA" \
  <<< "回覆 JSON，text 一字不差放入這個 nonce：$NONCE" 2>&1) || fail "helper_exit_nonzero"

SMOKE_OUTPUT="$OUTPUT" python3 - "$NONCE" <<'PYEOF' || exit 1
import json, os, sys
nonce = sys.argv[1]
raw = os.environ.get("SMOKE_OUTPUT", "")
try:
    outer = json.loads(raw)
except Exception:
    print(f"fable5_install_smoke=failed reason=non_json_output tail={raw[-200:]!r}", file=sys.stderr)
    raise SystemExit(1)
if outer.get("is_error"):
    print(f"fable5_install_smoke=failed reason=is_error result={str(outer.get('result'))[:200]!r}", file=sys.stderr)
    raise SystemExit(1)
try:
    inner = json.loads(outer.get("result", ""))
except Exception:
    inner = {}
if nonce not in json.dumps(inner):
    print(f"fable5_install_smoke=failed reason=nonce_missing result={str(outer.get('result'))[:200]!r}", file=sys.stderr)
    raise SystemExit(1)
print("fable5_install_smoke=passed model_reply_nonce_verified=true")
PYEOF
