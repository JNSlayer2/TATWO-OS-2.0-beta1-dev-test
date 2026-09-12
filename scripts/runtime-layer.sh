#!/bin/bash
# prepare APP: before outer codesign; split APP OUT: after signing, never mutates APP.
set -euo pipefail
exec python3 "$(dirname "$0")/runtime-layer.py" "$@"
