#!/bin/bash
# Local fixture or read-only log parsing. Never launches/installs a real App.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ "${1:-}" == --log ]]; then
  exec node scripts/browser-pump-probe.mjs "$@"
fi
receipt=$(bash scripts/tatwo-build-lock.sh acquire --timeout 120 --pid $$)
token=$(printf '%s\n' "$receipt" | sed -n 's/^token=//p')
trap 'bash scripts/tatwo-build-lock.sh release --token "$token" >/dev/null' EXIT
node scripts/browser-pump-probe.mjs "$@"
