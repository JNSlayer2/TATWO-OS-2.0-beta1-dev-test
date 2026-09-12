#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOLDEN_ROOT="$ROOT_DIR/harness-exam/g4/golden"
FIXTURE_SCHEMA="$ROOT_DIR/harness-exam/g4/fixture-schema.json"
PRODUCT_NAME="TatwoUltraworkMac"
SCENES=(
  rail-tree rail-collapsed rail-empty thread group-sandbox space-full
  space-compact space-status add-space quick-card settings-9row stress
)

RUN_ID="${TATWO_BOT_GOLDEN_RUN_ID:-g4-u2-$(date -u '+%Y%m%dT%H%M%SZ')}"
BUILDER_ID="${TATWO_BOT_GOLDEN_BUILDER_ID:-fable5}"
BUILD_JOBS="${TATWO_BOT_GOLDEN_BUILD_JOBS:-2}"
SETTLE_MS="${TATWO_BOT_GOLDEN_SETTLE_MS:-4500}"
BUILD_LOCK="/tmp/tatwo-build.lock"
LOCK_HELD=0
CURRENT_TEMP_ROOT=""

cleanup() {
  if [[ -n "$CURRENT_TEMP_ROOT" && -d "$CURRENT_TEMP_ROOT" ]]; then
    rm -r "$CURRENT_TEMP_ROOT"
  fi
  if [[ "$LOCK_HELD" == "1" ]]; then
    rmdir "$BUILD_LOCK" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ "${TATWO_BOT_GOLDEN_SKIP_BUILD:-0}" != "1" ]]; then
  while ! mkdir "$BUILD_LOCK" 2>/dev/null; do
    sleep 2
  done
  LOCK_HELD=1
  swift build \
    --package-path "$ROOT_DIR" \
    --disable-sandbox \
    -Xswiftc -disable-sandbox \
    --jobs "$BUILD_JOBS" \
    --product "$PRODUCT_NAME"
  rmdir "$BUILD_LOCK"
  LOCK_HELD=0
fi

BIN_DIR="$(
  swift build \
    --package-path "$ROOT_DIR" \
    --disable-sandbox \
    -Xswiftc -disable-sandbox \
    --show-bin-path
)"
APP_BINARY="${TATWO_BOT_GOLDEN_BINARY:-$BIN_DIR/$PRODUCT_NAME}"
if [[ ! -x "$APP_BINARY" ]]; then
  printf 'BLOCKED: executable unavailable: %s\n' "$APP_BINARY" >&2
  exit 1
fi

for scene in "${SCENES[@]}"; do
  width=1440
  height=900
  if [[ "$scene" == "stress" ]]; then
    width=980
    height=720
  fi

  scene_dir="$GOLDEN_ROOT/$scene"
  png="$scene_dir/bot.png"
  meta="$scene_dir/screenshot.meta.json"
  view_state="$scene_dir/view_state.json"
  mkdir -p "$scene_dir"

  CURRENT_TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tatwo-bot-golden.${scene}.XXXXXX")"
  capture_log="$CURRENT_TEMP_ROOT/capture.log"
  mkdir -p "$CURRENT_TEMP_ROOT/home"

  HOME="$CURRENT_TEMP_ROOT/home" \
  TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT="$png" \
  TATWO_ULTRAWORK_EXPORT_CHAT_MODE="bot" \
  TATWO_ULTRAWORK_EXPORT_BOT_SCENE="$scene" \
  TATWO_ULTRAWORK_EXPORT_WIDTH="$width" \
  TATWO_ULTRAWORK_EXPORT_HEIGHT="$height" \
  TATWO_ULTRAWORK_EXPORT_SCALE="2" \
  TATWO_ULTRAWORK_EXPORT_APPEARANCE="light" \
  TATWO_ULTRAWORK_EXPORT_ASYNC_SETTLE_MS="$SETTLE_MS" \
  TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME="0" \
  TATWO_ULTRAWORK_CHAT_CODEX_MIRROR="0" \
    "$APP_BINARY" 2>"$capture_log" || {
      printf 'BLOCKED: GUI exporter failed for %s; fable5 must capture on a GUI-capable runner.\n' "$scene" >&2
      cat "$capture_log" >&2
      exit 1
    }

  if [[ ! -s "$png" ]]; then
    printf 'BLOCKED: exporter did not create %s; fable5 must capture on a GUI-capable runner.\n' "$png" >&2
    exit 1
  fi

  expected_pixel_width=$((width * 2))
  expected_pixel_height=$((height * 2))
  pixel_width="$(/usr/bin/sips -g pixelWidth "$png" 2>/dev/null | awk '/pixelWidth/{print $2}')"
  pixel_height="$(/usr/bin/sips -g pixelHeight "$png" 2>/dev/null | awk '/pixelHeight/{print $2}')"
  if [[ "$pixel_width" != "$expected_pixel_width" || "$pixel_height" != "$expected_pixel_height" ]]; then
    printf 'BLOCKED: %s raster is %sx%s; expected %sx%s\n' \
      "$scene" "$pixel_width" "$pixel_height" "$expected_pixel_width" "$expected_pixel_height" >&2
    exit 1
  fi

  screenshot_hash="$(/usr/bin/shasum -a 256 "$png" | awk '{print $1}')"
  captured_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  python3 - "$meta" "$scene" "$RUN_ID" "$width" "$height" "$screenshot_hash" "$captured_at" <<'PY'
import copy
import hashlib
import json
import pathlib
import sys

meta_path = pathlib.Path(sys.argv[1])
scene_id, run_id = sys.argv[2:4]
width, height = map(int, sys.argv[4:6])
screenshot_hash, captured_at = sys.argv[6:8]
payload = {
    "schema": "TatwoBotGoldenScreenshotMetaV1",
    "scene_id": scene_id,
    "run_id": run_id,
    "surface": "Bot",
    "viewport": {"width": width, "height": height, "scale": 2},
    "path": f"golden/{scene_id}/bot.png",
    "screenshot_hash": screenshot_hash,
    "captured_at": captured_at,
    "verifier_id": None,
}
canonical = copy.deepcopy(payload)
for key in ("screenshot_sidecar_hash", "captured_at", "verifier_id"):
    canonical.pop(key, None)
encoded = json.dumps(canonical, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
payload["screenshot_sidecar_hash"] = hashlib.sha256(encoded).hexdigest()
meta_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

  python3 - "$FIXTURE_SCHEMA" "$view_state" "$scene" "$RUN_ID" "$captured_at" <<'PY'
import copy
import hashlib
import json
import pathlib
import sys

schema_path, output_path = map(pathlib.Path, sys.argv[1:3])
scene_id, run_id, captured_at = sys.argv[3:6]
schema = json.loads(schema_path.read_text(encoding="utf-8"))
fixture = next((row for row in schema["fixtures"] if row["sceneID"] == scene_id), None)
if fixture is None:
    raise SystemExit(f"fixture schema missing scene: {scene_id}")
state = fixture["initialState"]
payload = {
    "schema": "TatwoBotGoldenViewStateV1",
    "scene_id": scene_id,
    "run_id": run_id,
    "fixture_id": fixture["fixtureID"],
    "content_mode": state["contentMode"],
    "selection": state["selection"],
    "quick_card_open": state["quickCardOpen"],
    "empty_state_variant": fixture["emptyStateVariant"],
    "viewport": fixture["viewport"],
    "captured_at": captured_at,
    "verifier_id": None,
}
canonical = copy.deepcopy(payload)
for key in ("view_state_hash", "captured_at", "verifier_id"):
    canonical.pop(key, None)
encoded = json.dumps(canonical, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
payload["view_state_hash"] = hashlib.sha256(encoded).hexdigest()
output_path.write_text(
    json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

  rm -r "$CURRENT_TEMP_ROOT"
  CURRENT_TEMP_ROOT=""
  printf 'captured scene=%s png_sha256=%s viewport=%sx%s@2x\n' "$scene" "$screenshot_hash" "$width" "$height"
done

python3 - "$GOLDEN_ROOT" "$RUN_ID" "$BUILDER_ID" "${SCENES[@]}" <<'PY'
import copy
import hashlib
import json
import pathlib
import sys

golden_root = pathlib.Path(sys.argv[1])
run_id, builder_id = sys.argv[2:4]
scene_ids = sys.argv[4:]

def canonical_hash(payload, excluded):
    value = copy.deepcopy(payload)
    for key in excluded:
        value.pop(key, None)
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()

scenes = []
for scene_id in scene_ids:
    directory = golden_root / scene_id
    meta = json.loads((directory / "screenshot.meta.json").read_text(encoding="utf-8"))
    view_state = json.loads((directory / "view_state.json").read_text(encoding="utf-8"))
    if meta["run_id"] != run_id or view_state["run_id"] != run_id:
        raise SystemExit(f"mixed capture run for scene: {scene_id}")
    bundle = {
        "scene_id": scene_id,
        "screenshot_hash": meta["screenshot_hash"],
        "view_state_hash": view_state["view_state_hash"],
    }
    scenes.append({
        "id": scene_id,
        "screenshot_hash": meta["screenshot_hash"],
        "view_state_hash": view_state["view_state_hash"],
        "bundle_hash": canonical_hash(bundle, ("bundle_hash",)),
        "screenshot_meta_path": f"golden/{scene_id}/screenshot.meta.json",
        "view_state_path": f"golden/{scene_id}/view_state.json",
    })

manifest = {
    "schema": "TatwoBotGoldenManifestV1",
    "exam_id": "g4",
    "frozen": True,
    "builder_id": builder_id,
    "verifier_id": None,
    "scenes": scenes,
}
manifest["manifest_hash"] = canonical_hash(
    manifest, ("manifest_hash", "verifier_id", "captured_at")
)
(golden_root / "manifest.json").write_text(
    json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

printf 'bot_golden_manifest=%s builder_id=%s\\n' "$GOLDEN_ROOT/manifest.json" "$BUILDER_ID"
printf 'bot_golden_capture_run_id=%s\n' "$RUN_ID"
