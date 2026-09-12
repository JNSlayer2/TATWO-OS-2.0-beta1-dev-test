#!/usr/bin/env bash
# Manual submit-to-host data sync. Never runs unless invoked.
# Secondary packages local chat and sends it to the host inbox.
# Host unifies diffs into the host store. Secondary live files stay.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PYTHON="${TATWO_DATA_SYNC_PYTHON:-/usr/bin/python3}"
if [ -f "${TATWO_DATA_SYNC_PY:-}" ]; then
  TOOL="$TATWO_DATA_SYNC_PY"
elif [ -f "$SCRIPT_DIR/tatwo-data-sync.py" ]; then
  TOOL="$SCRIPT_DIR/tatwo-data-sync.py"
else
  TOOL="$ROOT_DIR/scripts/tatwo-data-sync.py"
fi
SSH_HOST="${TATWO_OS_IMAGE_SSH_HOST:-${TATWO_PRIMARY_SSH_HOST:-m4-mac-mini-codex}}"
SUPPORT="${TATWO_APP_SUPPORT:-$HOME/Library/Application Support/Tatwo Ultrawork}"
STATE="${TATWO_DATA_SYNC_STATE:-$SUPPORT/data-sync}"
DEVICE="${TATWO_DEVICE_NAME:-$(scutil --get ComputerName 2>/dev/null || hostname -s)}"
REMOTE_SUPPORT="${TATWO_REMOTE_APP_SUPPORT:-Library/Application Support/Tatwo Ultrawork}"
REMOTE_INBOX="${TATWO_DATA_SYNC_REMOTE_INBOX:-$REMOTE_SUPPORT/data-sync/inbox}"
REMOTE_TOOL="${TATWO_DATA_SYNC_REMOTE_TOOL:-$REMOTE_SUPPORT/data-sync/bin/tatwo-data-sync.py}"
LOG="${TATWO_DATA_SYNC_LOG:-$STATE/data-sync.log}"

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
  exit 1
}

is_host_role() {
  # Default secondary. Local unify into live files is host-only and must be explicit.
  [ "${TATWO_DATA_SYNC_ROLE:-}" = "host" ]
}

fingerprint_support() {
  "$PYTHON" - "$SUPPORT" <<'PY'
import hashlib, json, sys
from pathlib import Path
support = Path(sys.argv[1])
names = ("native-chat-threads.json", "chat-transcript-journal-v1.json")
out = {}
for name in names:
    path = support / name
    if not path.is_file():
        out[name] = None
        continue
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    out[name] = {"sha256": digest.hexdigest(), "bytes": path.stat().st_size}
print(json.dumps(out, sort_keys=True))
PY
}

write_last_receipt() {
  local payload="$1"
  mkdir -p "$STATE"
  printf '%s\n' "$payload" >"$STATE/last-submit.json"
}

package_local() {
  local dest="$1"
  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  "$PYTHON" "$TOOL" --support "$SUPPORT" --export "$dest" --device "$DEVICE" package
}

install_remote_tool() {
  ssh -o BatchMode=yes -o ConnectTimeout=20 "$SSH_HOST" \
    "mkdir -p '$(dirname "$REMOTE_TOOL")' '$REMOTE_INBOX'"
  scp -q -o BatchMode=yes -o ConnectTimeout=20 "$TOOL" "$SSH_HOST:/tmp/tatwo-data-sync.py"
  ssh -o BatchMode=yes -o ConnectTimeout=20 "$SSH_HOST" \
    "mv /tmp/tatwo-data-sync.py '$REMOTE_TOOL'"
}

upload_submit() {
  local bundle="$1"
  local submit_id device_name remote_dir
  submit_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["submitId"])' "$bundle/manifest.json")"
  device_name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["device"])' "$bundle/manifest.json")"
  remote_dir="$REMOTE_INBOX/$device_name/$submit_id"
  ssh -o BatchMode=yes -o ConnectTimeout=20 "$SSH_HOST" "mkdir -p '$remote_dir'"
  tar -C "$bundle" -cf - . | ssh -o BatchMode=yes -o ConnectTimeout=20 "$SSH_HOST" \
    "tar -xf - -C '$remote_dir'"
  printf '%s\n' "$submit_id"
}

remote_unify() {
  ssh -o BatchMode=yes -o ConnectTimeout=20 "$SSH_HOST" \
    "$PYTHON '$REMOTE_TOOL' --support '$REMOTE_SUPPORT' --inbox '$REMOTE_INBOX' unify"
}

keep_last_outgoing() {
  local outgoing="$1"
  local keep="$STATE/outgoing/last"
  rm -rf "$keep"
  mkdir -p "$(dirname "$keep")"
  mv "$outgoing" "$keep"
}

assert_local_untouched() {
  local before="$1"
  local after
  after="$(fingerprint_support)"
  if [ "$before" != "$after" ]; then
    write_last_receipt "$(printf '{"ok":false,"error":"local-files-changed","before":%s,"after":%s}\n' "$before" "$after")"
    die "local chat files changed during submit; this must never happen"
  fi
}

host_unify() {
  local unify_out
  mkdir -p "$STATE"
  unify_out="$("$PYTHON" "$TOOL" --support "$SUPPORT" --inbox "${TATWO_DATA_SYNC_INBOX:-$STATE/inbox}" unify)"
  printf '%s\n' "$unify_out"
  write_last_receipt "$(python3 - "$unify_out" <<'PY'
import json, sys
print(json.dumps({"ok": True, "role": "host", "unify": sys.argv[1]}, ensure_ascii=False))
PY
)"
}

submit_to_host() {
  local outgoing submit_id before after unify_out
  if is_host_role; then
    log "host unify inbox (live host files stay the merge base; no self-package overwrite)"
    host_unify
    return 0
  fi
  mkdir -p "$STATE"
  before="$(fingerprint_support)"
  outgoing="$STATE/outgoing/staging-$$"
  package_local "$outgoing"
  assert_local_untouched "$before"
  install_remote_tool
  assert_local_untouched "$before"
  submit_id="$(upload_submit "$outgoing")"
  keep_last_outgoing "$outgoing"
  assert_local_untouched "$before"
  log "submitted submitId=$submit_id (uploaded to host inbox; local files untouched)"
  unify_out="$(remote_unify)"
  printf '%s\n' "submitted submitId=$submit_id (uploaded to host inbox; local files untouched)"
  printf '%s\n' "$unify_out"
  assert_local_untouched "$before"
  after="$(fingerprint_support)"
  write_last_receipt "$(python3 - "$submit_id" "$after" "$unify_out" <<'PY'
import json, sys
print(json.dumps({
    "ok": True,
    "role": "secondary",
    "submitId": sys.argv[1],
    "localUntouched": True,
    "localFingerprint": json.loads(sys.argv[2]),
    "unify": sys.argv[3],
}, ensure_ascii=False))
PY
)"
}

case "$cmd" in
  package)
    dest="${TATWO_DATA_SYNC_EXPORT:-$STATE/outgoing/local}"
    exec "$PYTHON" "$TOOL" --support "$SUPPORT" --export "$dest" --device "$DEVICE" package "$@"
    ;;
  submit|pull|apply)
    submit_to_host
    ;;
  unify)
    exec "$PYTHON" "$TOOL" --support "$SUPPORT" --inbox "${TATWO_DATA_SYNC_INBOX:-$STATE/inbox}" unify "$@"
    ;;
  publish)
    if is_host_role; then
      exec "$PYTHON" "$TOOL" --support "$SUPPORT" --inbox "${TATWO_DATA_SYNC_INBOX:-$STATE/inbox}" unify "$@"
    fi
    submit_to_host
    ;;
  status)
    echo "role=$(is_host_role && echo host || echo secondary) device=$DEVICE support=$SUPPORT ssh=$SSH_HOST"
    if [ -f "$STATE/last-submit.json" ]; then
      echo "lastSubmit=$STATE/last-submit.json"
    fi
    ;;
  *)
    echo "error: unknown command $cmd (submit|unify|package|status)" >&2
    exit 1
    ;;
esac
