#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOLDEN_ROOT="$ROOT_DIR/harness-exam/g3/golden"
PRODUCT_NAME="TatwoUltraworkMac"
SCENES=(
  send stream stop resume slash plg engine_switch reattach cold_start orphan
  queued_turn
)

RUN_ID="${TATWO_CHAT_GOLDEN_RUN_ID:-g3-s1-$(date -u '+%Y%m%dT%H%M%SZ')}"
BUILD_JOBS="${TATWO_CHAT_GOLDEN_BUILD_JOBS:-2}"
SETTLE_MS="${TATWO_CHAT_GOLDEN_SETTLE_MS:-800}"
BUILD_LOCK="/tmp/tatwo-build.lock"
LOCK_HELD=0

release_build_lock() {
  if [[ "$LOCK_HELD" == "1" ]]; then
    rmdir "$BUILD_LOCK" 2>/dev/null || true
  fi
}
trap release_build_lock EXIT

if [[ "${TATWO_CHAT_GOLDEN_SKIP_BUILD:-0}" != "1" ]]; then
  while ! mkdir "$BUILD_LOCK" 2>/dev/null; do
    sleep 2
  done
  LOCK_HELD=1
  swift build \
    --package-path "$ROOT_DIR" \
    --disable-sandbox \
    --jobs "$BUILD_JOBS" \
    --product "$PRODUCT_NAME"
  release_build_lock
  LOCK_HELD=0
fi

BIN_DIR="$(
  swift build \
    --package-path "$ROOT_DIR" \
    --disable-sandbox \
    --show-bin-path
)"
APP_BINARY="${TATWO_CHAT_GOLDEN_BINARY:-$BIN_DIR/$PRODUCT_NAME}"
if [[ ! -x "$APP_BINARY" ]]; then
  printf 'BLOCKED: executable unavailable: %s\n' "$APP_BINARY" >&2
  exit 1
fi

for scene in "${SCENES[@]}"; do
  scene_dir="$GOLDEN_ROOT/$scene"
  png="$scene_dir/chat.png"
  meta="$scene_dir/screenshot.meta.json"
  log="$scene_dir/capture.log"
  mkdir -p "$scene_dir"

  TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT="$png" \
  TATWO_ULTRAWORK_EXPORT_CHAT_SCENE="$scene" \
  TATWO_ULTRAWORK_EXPORT_TAB="chat" \
  TATWO_ULTRAWORK_EXPORT_WIDTH="1440" \
  TATWO_ULTRAWORK_EXPORT_HEIGHT="900" \
  TATWO_ULTRAWORK_EXPORT_SCALE="2" \
  TATWO_ULTRAWORK_EXPORT_APPEARANCE="dark" \
  TATWO_ULTRAWORK_EXPORT_ASYNC_SETTLE_MS="$SETTLE_MS" \
  TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME="0" \
  TATWO_ULTRAWORK_CHAT_CODEX_MIRROR="0" \
    "$APP_BINARY" 2>"$log"

  if [[ ! -s "$png" ]]; then
    printf 'BLOCKED: exporter did not create %s\n' "$png" >&2
    exit 1
  fi
  pixel_width="$(/usr/bin/sips -g pixelWidth "$png" 2>/dev/null | awk '/pixelWidth/{print $2}')"
  pixel_height="$(/usr/bin/sips -g pixelHeight "$png" 2>/dev/null | awk '/pixelHeight/{print $2}')"
  if [[ "$pixel_width" != "2880" || "$pixel_height" != "1800" ]]; then
    printf 'BLOCKED: %s raster is %sx%s; expected 2880x1800\n' \
      "$scene" "$pixel_width" "$pixel_height" >&2
    exit 1
  fi

  screenshot_hash="$(/usr/bin/shasum -a 256 "$png" | awk '{print $1}')"
  captured_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  python3 - "$meta" "$scene" "$RUN_ID" "$screenshot_hash" "$captured_at" <<'PY'
import copy
import hashlib
import json
import pathlib
import sys

meta_path = pathlib.Path(sys.argv[1])
scene_id, run_id, screenshot_hash, captured_at = sys.argv[2:]
payload = {
    "schema": "TatwoChatGoldenScreenshotMetaV1",
    "scene_id": scene_id,
    "run_id": run_id,
    "surface": "Chat",
    "viewport": {"width": 1440, "height": 900, "scale": 2},
    "path": f"golden/{scene_id}/chat.png",
    "screenshot_hash": screenshot_hash,
    "captured_at": captured_at,
    "verifier_id": None,
}
canonical = copy.deepcopy(payload)
for key in ("screenshot_sidecar_hash", "captured_at", "verifier_id"):
    canonical.pop(key, None)
encoded = json.dumps(
    canonical,
    ensure_ascii=False,
    sort_keys=True,
    separators=(",", ":"),
).encode("utf-8")
payload["screenshot_sidecar_hash"] = hashlib.sha256(encoded).hexdigest()
meta_path.write_text(
    json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
  printf 'captured scene=%s png_sha256=%s\n' "$scene" "$screenshot_hash"
done

printf 'chat_golden_capture_run_id=%s\n' "$RUN_ID"
