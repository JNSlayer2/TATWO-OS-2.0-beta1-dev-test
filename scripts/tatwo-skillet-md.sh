#!/usr/bin/env bash
# OS skillet.md submit/unify. Never overwrites vendor SKILL.md.
# Secondary sends a proposal. Host archives and keeps the curated body.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PYTHON="${TATWO_SKILLET_MD_PYTHON:-/usr/bin/python3}"
if [ -f "${TATWO_SKILLET_MD_PY:-}" ]; then
  TOOL="$TATWO_SKILLET_MD_PY"
elif [ -f "$SCRIPT_DIR/tatwo-skillet-md.py" ]; then
  TOOL="$SCRIPT_DIR/tatwo-skillet-md.py"
else
  TOOL="$ROOT_DIR/scripts/tatwo-skillet-md.py"
fi
SSH_HOST="${TATWO_OS_IMAGE_SSH_HOST:-${TATWO_PRIMARY_SSH_HOST:-}}"
[ -n "$SSH_HOST" ] || { echo "請設定 TATWO_PRIMARY_SSH_HOST" >&2; exit 2; }
SUPPORT="${TATWO_APP_SUPPORT:-$HOME/Library/Application Support/Tatwo Ultrawork}"
STATE="${TATWO_SKILLET_MD_STATE:-$SUPPORT/skillet-md}"
DEVICE="${TATWO_DEVICE_NAME:-$(scutil --get ComputerName 2>/dev/null || hostname -s)}"
REMOTE_SUPPORT="${TATWO_REMOTE_APP_SUPPORT:-Library/Application Support/Tatwo Ultrawork}"
REMOTE_INBOX="${TATWO_SKILLET_MD_REMOTE_INBOX:-$REMOTE_SUPPORT/skillet-md/inbox}"
REMOTE_TOOL="${TATWO_SKILLET_MD_REMOTE_TOOL:-$REMOTE_SUPPORT/skillet-md/bin/tatwo-skillet-md.py}"
LOG="${TATWO_SKILLET_MD_LOG:-$STATE/skillet-md.log}"

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
  [ "${TATWO_DATA_SYNC_ROLE:-}" = "host" ]
}

write_last_receipt() {
  mkdir -p "$STATE"
  printf '%s\n' "$1" >"$STATE/last-submit.json"
}

fingerprint_vendor_skills() {
  "$PYTHON" - "$SUPPORT" <<'PY'
import hashlib, json, sys
from pathlib import Path
support = Path(sys.argv[1])
roots = [
    support / "skills-runtime",
    support / "skills",
]
out = {}
for root in roots:
    if not root.is_dir():
        continue
    for path in root.rglob("SKILL.md"):
        if path.parent.name == "skillet":
            continue
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        out[str(path)] = digest.hexdigest()
print(json.dumps(out, sort_keys=True))
PY
}

install_remote_tool() {
  ssh -o BatchMode=yes -o ConnectTimeout=20 "$SSH_HOST" \
    "mkdir -p '$(dirname "$REMOTE_TOOL")' '$REMOTE_INBOX'"
  scp -q -o BatchMode=yes -o ConnectTimeout=20 "$TOOL" "$SSH_HOST:/tmp/tatwo-skillet-md.py"
  ssh -o BatchMode=yes -o ConnectTimeout=20 "$SSH_HOST" \
    "mv /tmp/tatwo-skillet-md.py '$REMOTE_TOOL' && chmod 755 '$REMOTE_TOOL'"
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

host_unify() {
  local unify_out
  mkdir -p "$STATE"
  unify_out="$("$PYTHON" "$TOOL" --support "$SUPPORT" --inbox "${TATWO_SKILLET_MD_INBOX:-$STATE/inbox}" unify)"
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
    log "host unify skillet.md inbox (canonical body stays; proposals archived)"
    host_unify
    return 0
  fi
  mkdir -p "$STATE"
  before="$(fingerprint_vendor_skills)"
  outgoing="$STATE/outgoing/staging-$$"
  rm -rf "$outgoing"
  "$PYTHON" "$TOOL" --support "$SUPPORT" --export "$outgoing" --device "$DEVICE" package
  after="$(fingerprint_vendor_skills)"
  if [ "$before" != "$after" ]; then
    die "vendor SKILL.md changed during package; refused"
  fi
  install_remote_tool
  after="$(fingerprint_vendor_skills)"
  [ "$before" = "$after" ] || die "vendor SKILL.md changed during remote tool install"
  submit_id="$(upload_submit "$outgoing")"
  mkdir -p "$STATE/outgoing"
  rm -rf "$STATE/outgoing/last"
  mv "$outgoing" "$STATE/outgoing/last"
  unify_out="$(remote_unify)"
  after="$(fingerprint_vendor_skills)"
  [ "$before" = "$after" ] || die "vendor SKILL.md changed during submit"
  log "submitted skillet.md submitId=$submit_id (local vendor skills untouched)"
  printf '%s\n' "submitted submitId=$submit_id (local vendor skills untouched)"
  printf '%s\n' "$unify_out"
  write_last_receipt "$(python3 - "$submit_id" "$unify_out" <<'PY'
import json, sys
print(json.dumps({
    "ok": True,
    "role": "secondary",
    "submitId": sys.argv[1],
    "localVendorSkillsUntouched": True,
    "unify": sys.argv[2],
}, ensure_ascii=False))
PY
)"
}

case "$cmd" in
  package)
    dest="${TATWO_SKILLET_MD_EXPORT:-$STATE/outgoing/local}"
    exec "$PYTHON" "$TOOL" --support "$SUPPORT" --export "$dest" --device "$DEVICE" package "$@"
    ;;
  install)
    exec "$PYTHON" "$TOOL" --support "$SUPPORT" install "$@"
    ;;
  submit|apply)
    submit_to_host
    ;;
  unify)
    exec "$PYTHON" "$TOOL" --support "$SUPPORT" --inbox "${TATWO_SKILLET_MD_INBOX:-$STATE/inbox}" unify "$@"
    ;;
  pull)
    exec "$PYTHON" "$TOOL" --support "$SUPPORT" pull "$@"
    ;;
  status)
    echo "role=$(is_host_role && echo host || echo secondary) device=$DEVICE support=$SUPPORT ssh=$SSH_HOST"
    exec "$PYTHON" "$TOOL" --support "$SUPPORT" status
    ;;
  *)
    echo "error: unknown command $cmd (submit|unify|install|package|pull|status)" >&2
    exit 1
    ;;
esac
