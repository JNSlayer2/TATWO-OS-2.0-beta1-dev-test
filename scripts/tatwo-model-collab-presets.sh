#!/usr/bin/env bash
# Model-collab-presets: gateway roster + agent-presets over device-sync-channel.
# Never copies credentials/tokens. Identity registry rides app version.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NODE="${TATWO_MODEL_COLLAB_NODE:-/usr/bin/env node}"
ENGINE="${TATWO_MODEL_COLLAB_ENGINE:-$SCRIPT_DIR/tatwo-model-collab-presets.mjs}"
SYNC="${TATWO_DEVICE_SYNC:-$SCRIPT_DIR/tatwo-device-sync.sh}"
APP_SUPPORT="${TATWO_APP_SUPPORT:-$HOME/Library/Application Support/Tatwo Ultrawork}"
CHANNEL_DIR="${TATWO_CHANNEL_DIR:-$APP_SUPPORT/device-sync-channel}"
CHANNEL_BRANCH="${TATWO_CHANNEL_BRANCH:-device-sync-channel}"
LOG="${TATWO_MODEL_COLLAB_LOG:-$APP_SUPPORT/model-collab-presets/engine.log}"

cmd="${1:-status}"
shift || true

log() {
  local line
  line="$(date -u +"%Y-%m-%dT%H:%M:%SZ") $*"
  mkdir -p "$(dirname "$LOG")"
  printf '%s\n' "$line" >>"$LOG"
  printf '%s\n' "$line"
}

die() {
  log "error=$*"
  exit 2
}

[ -f "$ENGINE" ] || die "missing engine $ENGINE"

run_engine() {
  $NODE "$ENGINE" "$@"
}

channel_commit_if_git() {
  [ -d "$CHANNEL_DIR/.git" ] || return 0
  git -C "$CHANNEL_DIR" add \
    "profiles/shared/model-collab-presets.json" \
    "registries/models/model-collab-presets.v1.json" \
    >/dev/null 2>&1 || return 0
  if git -C "$CHANNEL_DIR" commit -m "model-collab-presets" >/dev/null 2>&1; then
    git -C "$CHANNEL_DIR" push origin "$CHANNEL_BRANCH" >/dev/null 2>&1 || \
      log "channel push failed (offline/conflict); next cycle retries"
    log "published model-collab-presets to device-sync-channel"
  else
    log "model-collab-presets channel payload unchanged"
  fi
}

case "$cmd" in
  selftest|extract|guard|status)
    run_engine "$cmd" "$@"
    ;;
  publish)
    run_engine publish --channel "$CHANNEL_DIR" --owner-initiated 1 "$@"
    channel_commit_if_git
    ;;
  apply)
    run_engine apply --channel "$CHANNEL_DIR" "$@"
    ;;
  cycle)
    if [ -x "$SYNC" ] || [ -f "$SYNC" ]; then
      if ! bash "$SYNC" role-status >/dev/null 2>&1; then
        :
      fi
    fi
    run_engine cycle --channel "$CHANNEL_DIR" "$@"
    if [ "${TATWO_DEVICE_ROLE:-${TATWO_DATA_SYNC_ROLE:-}}" = "primary" ] \
      || [ "${TATWO_DATA_SYNC_ROLE:-}" = "host" ]; then
      channel_commit_if_git
    fi
    ;;
  -h|--help|help)
    cat <<'EOF'
tatwo-model-collab-presets.sh <selftest|extract|guard|publish|apply|cycle|status>
EOF
    ;;
  *)
    die "unknown command $cmd"
    ;;
esac
