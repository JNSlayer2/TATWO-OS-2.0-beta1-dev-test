#!/usr/bin/env bash
# R1 debug 一鍵啟動：本機 coordinator + 帶互動 env 的 App（swift run）。
# 純 debug 用；不碰正式 App、不裝 LaunchAgent。Ctrl+C 結束會一併關 coordinator。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${TATWO_R1_DEBUG_DIR:-$HOME/.tatwo-r1-debug}"
mkdir -p "$STATE_DIR"

SECRET_FILE="$STATE_DIR/gateway-secret"
if [ ! -s "$SECRET_FILE" ]; then
  head -c 24 /dev/urandom | xxd -p | tr -d '\n' > "$SECRET_FILE"
fi
SECRET="$(cat "$SECRET_FILE")"
PORT="${TATWO_R1_DEBUG_PORT:-8787}"

export TATWO_DOMAIN_COORDINATOR_ENABLED=true
export TATWO_DOMAIN_GATEWAY_SECRET="$SECRET"

COORD_PID=""
if ! curl -s -o /dev/null "http://127.0.0.1:$PORT/v1/snapshot" 2>/dev/null; then
  node "$ROOT/Services/TatwoDomainCoordinator/local-host.mjs" \
    --port "$PORT" --state "$STATE_DIR/coordinator-state.json" \
    > "$STATE_DIR/coordinator.log" 2>&1 &
  COORD_PID=$!
  sleep 1
  if ! kill -0 "$COORD_PID" 2>/dev/null; then
    echo "coordinator 啟動失敗，詳見 $STATE_DIR/coordinator.log" >&2
    exit 1
  fi
  echo "coordinator 已啟動 (pid $COORD_PID, port $PORT)"
else
  echo "coordinator 已在 port $PORT 運行，沿用"
fi

cleanup() {
  if [ -n "$COORD_PID" ] && kill -0 "$COORD_PID" 2>/dev/null; then
    kill "$COORD_PID" 2>/dev/null || true
    echo "coordinator 已關閉"
  fi
}
trap cleanup EXIT

export TATWO_DOMAIN_COORDINATOR_URL="http://127.0.0.1:$PORT"
export TATWO_DOMAIN_COORDINATOR_ALLOW_LOOPBACK=1

# 預設隔離資料（不碰正式 App 的使用者資料）；--real-data 才共用正式資料，
# 且必須先關掉正式 App（避免雙實例同寫 store）。
if [ "${1:-}" = "--real-data" ]; then
  if pgrep -f "/Applications/Tatwo Ultrawork.app" >/dev/null 2>&1; then
    echo "偵測到正式 App 還在跑。--real-data 模式必須先完全結束正式 App 再執行。" >&2
    exit 1
  fi
  echo "共用正式使用者資料模式（正式 App 已關閉）"
else
  export TATWO_ULTRAWORK_APP_SUPPORT="$STATE_DIR/app-support"
  mkdir -p "$TATWO_ULTRAWORK_APP_SUPPORT"
  echo "隔離資料模式（乾淨測試環境；要看真實 threads 請先關正式 App 後用 --real-data）"
fi

echo "啟動 App（swift run，第一次編譯較久）…"
cd "$ROOT"
swift run TatwoUltraworkMac
