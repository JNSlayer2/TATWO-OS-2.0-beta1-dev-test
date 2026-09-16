#!/usr/bin/env bash
# Three complete, sequential runs of one source state. Never retry/filter tests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec node "$ROOT/scripts/tatwo-test-thrice.mjs" "$@"
