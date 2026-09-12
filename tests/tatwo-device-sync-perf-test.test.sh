#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PERF="$ROOT/scripts/tatwo-device-sync-perf-test.sh"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

[ -f "$PERF" ] || fail "perf test script exists"
pass "perf test script exists"

bash -n "$PERF" || fail "perf test script parses"
pass "perf test script parses"

help_output="$(bash "$PERF" --help)"
for name in latency correctness concurrency pairing fail-soft all; do
  printf '%s\n' "$help_output" | grep -Eq "(^|[[:space:]])${name}([[:space:]]|$)" \
    || fail "--help documents ${name}"
done
pass "--help documents every independently runnable test"

printf '%s\n' "$help_output" | grep -q -- '--count' \
  || fail "--help documents request count"
printf '%s\n' "$help_output" | grep -q -- '--poll-interval' \
  || fail "--help documents poll interval"
pass "--help documents benchmark controls"

printf '%s\n' "tatwo_device_sync_perf_contract_test=passed"
