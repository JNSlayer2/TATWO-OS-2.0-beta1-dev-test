#!/usr/bin/env bash
# Room-published OS image consumer. Git rebuild is not an update channel.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PYTHON="${TATWO_OS_IMAGE_PYTHON:-/usr/bin/python3}"
if [ -f "${TATWO_OS_IMAGE_PY:-}" ]; then
  TOOL="$TATWO_OS_IMAGE_PY"
elif [ -f "$SCRIPT_DIR/tatwo-os-image.py" ]; then
  TOOL="$SCRIPT_DIR/tatwo-os-image.py"
else
  TOOL="$ROOT_DIR/scripts/tatwo-os-image.py"
fi
SSH_HOST="${TATWO_OS_IMAGE_SSH_HOST:-${TATWO_PRIMARY_SSH_HOST:-}}"
[ -n "$SSH_HOST" ] || { echo "請設定 TATWO_PRIMARY_SSH_HOST" >&2; exit 2; }
STATE="${TATWO_OS_IMAGE_STATE:-$HOME/Library/Application Support/Tatwo Ultrawork/os-image}"
REMOTE_EXPORT="${TATWO_OS_IMAGE_REMOTE_EXPORT:-Library/Application Support/Tatwo Ultrawork/os-image/export}"
REMOTE_TOOL="${TATWO_OS_IMAGE_REMOTE_TOOL:-Library/Application Support/Tatwo Ultrawork/os-image/bin/tatwo-os-image.py}"
LOG="${TATWO_OS_IMAGE_LOG:-$HOME/Library/Application Support/Tatwo Ultrawork/os-image.log}"

log() {
  local line
  line="$(date -u +"%Y-%m-%dT%H:%M:%SZ") $*"
  mkdir -p "$(dirname "$LOG")"
  printf '%s\n' "$line" >>"$LOG"
  printf '%s\n' "$line"
}

die() {
  log "error=$*"
  exit 1
}

ssh_ok() {
  ssh -o BatchMode=yes -o ConnectTimeout=20 "$SSH_HOST" 'echo ok' >/dev/null
}

remote_publish() {
  ssh -o BatchMode=yes -o ConnectTimeout=20 "$SSH_HOST" \
    "mkdir -p '$(dirname "$REMOTE_TOOL")' '$(dirname "$REMOTE_EXPORT")'"
  scp -q -o BatchMode=yes -o ConnectTimeout=20 "$TOOL" "$SSH_HOST:/tmp/tatwo-os-image.py"
  ssh -o BatchMode=yes -o ConnectTimeout=20 "$SSH_HOST" \
    "mv /tmp/tatwo-os-image.py '$REMOTE_TOOL' && $PYTHON '$REMOTE_TOOL' --export '$REMOTE_EXPORT' publish"
}

pull_export() {
  local incoming="$STATE/incoming"
  rm -rf "$incoming"
  mkdir -p "$incoming"
  ssh -o BatchMode=yes -o ConnectTimeout=20 "$SSH_HOST" \
    "cd '$REMOTE_EXPORT' && tar cf - ." | tar xf - -C "$incoming"
  [[ -f "$incoming/manifest.json" ]] || die "pulled export missing manifest"
}

cmd="${1:-status}"
shift || true

case "$cmd" in
  publish)
    exec "$PYTHON" "$TOOL" publish "$@"
    ;;
  status)
    if ssh_ok; then
      remote_publish
      pull_export
      exec "$PYTHON" "$TOOL" --state "$STATE" --remote-manifest "$STATE/incoming/manifest.json" status "$@"
    else
      log "ssh_unreachable host=$SSH_HOST"
      exec "$PYTHON" "$TOOL" --state "$STATE" status "$@"
    fi
    ;;
  sync|pull)
    ssh_ok || die "ssh_unreachable host=$SSH_HOST"
    remote_publish
    pull_export
    exec "$PYTHON" "$TOOL" --state "$STATE" --export "$STATE/incoming" apply "$@"
    ;;
  apply)
    exec "$PYTHON" "$TOOL" --state "$STATE" --export "${TATWO_OS_IMAGE_EXPORT:-$STATE/incoming}" apply "$@"
    ;;
  rollback-runtime)
    exec "$PYTHON" "$TOOL" --state "$STATE" rollback-runtime "$@"
    ;;
  selftest-compare)
    exec "$PYTHON" "$TOOL" selftest-compare
    ;;
  *)
    die "unknown command: $cmd"
    ;;
esac
