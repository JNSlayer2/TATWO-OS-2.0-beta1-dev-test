#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="${TATWO_DEVICE_CONTROL_CLI:-$ROOT/.build/debug/tatwo-ultrawork}"

usage() {
  cat <<'EOF'
Usage:
  scripts/tatwo-device-control-e2e.sh --selftest
  scripts/tatwo-device-control-e2e.sh --print-remote-plan

The selftest uses isolated test-mode file trust and never executes a controlled
descriptor. The remote plan is printed only; this script never executes SSH,
SCP, a fleet transfer, or a controlled command.
EOF
}

require_cli() {
  if [[ ! -x "$CLI" ]]; then
    printf 'ERROR: CLI binary not found: %s\n' "$CLI" >&2
    printf 'Build it first or set TATWO_DEVICE_CONTROL_CLI=/absolute/path/to/tatwo-ultrawork\n' >&2
    exit 2
  fi
}

run_for() {
  local app_support="$1"
  shift
  TATWO_TEST_MODE=1 \
  TATWO_DEVICE_TRUST_TEST_KEY_ROOT="$app_support/test-keys" \
  TATWO_ULTRAWORK_APP_SUPPORT="$app_support" \
    "$CLI" "$@" --json
}

make_invocation() {
  local output="$1"
  local logical_id="$2"
  local job_id="$3"
  local nonce="$4"
  local template_id="$5"
  local target_id="$6"
  local param_name="$7"
  local param_value="$8"
  local embedded_approval="${9:-}"
  python3 - "$output" "$logical_id" "$job_id" "$nonce" "$template_id" \
    "$target_id" "$param_name" "$param_value" "$embedded_approval" <<'PY'
import json, sys
(
    output, logical_id, job_id, nonce, template_id, target_id,
    param_name, param_value, embedded_approval,
) = sys.argv[1:]
value = {
    "schema": "TatwoMutualControlInvocationV1",
    "purpose": "device_mutual_control_invoke",
    "logicalControlID": logical_id,
    "jobID": job_id,
    "dispatchNonce": nonce,
    "sourceDeviceID": "origin-device-control-selftest",
    "operatorPrincipalID": "x1-selftest-operator",
    "targetDeviceID": target_id,
    "templateID": template_id,
    "capabilityVersion": 1,
    "params": {param_name: param_value},
    "leaseDomainBinding": {
        "none": {"justification": "X1 plan-only target outside lease domain"}
    },
}
if embedded_approval:
    value["approvalID"] = embedded_approval
with open(output, "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True, separators=(",", ":"))
PY
}

inline_json() {
  python3 - "$1" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.dumps(json.load(handle), sort_keys=True, separators=(",", ":")))
PY
}

selftest() {
  require_cli
  local work origin target origin_store target_store
  work="$(mktemp -d "${TMPDIR:-/tmp}/tatwo-device-control-e2e.XXXXXX")"
  SELFTEST_WORK="$work"
  origin="$work/origin"
  target="$work/target"
  origin_store="$origin/device-trust/pin-store"
  target_store="$target/device-trust/pin-store"
  mkdir -p "$origin/test-keys" "$target/test-keys"

  cleanup() {
    if command -v trash >/dev/null 2>&1; then
      trash "$SELFTEST_WORK" >/dev/null 2>&1 || true
    else
      printf 'SELFTEST workspace preserved (trash unavailable): %s\n' "$SELFTEST_WORK"
    fi
  }
  trap cleanup EXIT

  printf '== trust bootstrap (isolated test-mode file stores) ==\n'
  run_for "$origin" device-trust init \
    --device-id origin-device-control-selftest --store-root "$origin_store"
  run_for "$origin" device-trust export-identity \
    --device-id origin-device-control-selftest \
    --output "$origin/device-trust/identity.json"
  run_for "$target" device-trust init \
    --device-id target-device-control-selftest --store-root "$target_store"
  run_for "$target" device-trust export-identity \
    --device-id target-device-control-selftest \
    --output "$target/device-trust/identity.json"

  local origin_fingerprint target_fingerprint
  origin_fingerprint="$(shasum -a 256 "$origin/device-trust/identity.json" | awk '{print $1}')"
  target_fingerprint="$(shasum -a 256 "$target/device-trust/identity.json" | awk '{print $1}')"
  run_for "$origin" device-trust pin-import "$target/device-trust/identity.json" \
    --fingerprint "$target_fingerprint" \
    --device-id origin-device-control-selftest --store-root "$origin_store"
  run_for "$target" device-trust pin-import "$origin/device-trust/identity.json" \
    --fingerprint "$origin_fingerprint" \
    --device-id target-device-control-selftest --store-root "$target_store"

  local descriptor high_descriptor invocation bad_invocation high_invocation job
  descriptor="$work/normal-descriptor.json"
  high_descriptor="$work/high-risk-descriptor.json"
  invocation="$work/normal-invocation.json"
  bad_invocation="$work/out-of-allow-invocation.json"
  high_invocation="$work/high-risk-invocation.json"
  job="$work/device-control-job.json"

  printf '== 1. descriptor-create (target-signed, normal shape) ==\n'
  run_for "$target" device-control descriptor-create \
    --out "$descriptor" \
    --template-id fs.list \
    --argv '/bin/ls,-la,/tmp/mutual-control/ok' \
    --allow '2:^/tmp/mutual-control/[A-Za-z0-9._-]+$' \
    --timeout 30 --max-output-bytes 65536

  make_invocation "$invocation" x1-normal job-x1-normal nonce-x1-normal \
    fs.list target-device-control-selftest arg2 /tmp/mutual-control/ok
  local invocation_json
  invocation_json="$(inline_json "$invocation")"

  printf '== 2. validate (risk computed by validator) ==\n'
  run_for "$origin" device-control validate \
    --descriptor "$descriptor" --invocation "$invocation_json"

  printf '== negative 2/4: argv allow pattern exceeded ==\n'
  make_invocation "$bad_invocation" x1-bad-argv job-x1-bad nonce-x1-bad \
    fs.list target-device-control-selftest arg2 /etc/passwd
  local bad_invocation_json bad_output bad_status
  bad_invocation_json="$(inline_json "$bad_invocation")"
  set +e
  bad_output="$(
    run_for "$origin" device-control validate \
      --descriptor "$descriptor" --invocation "$bad_invocation_json" 2>&1
  )"
  bad_status=$?
  set -e
  printf '%s\n' "$bad_output"
  [[ $bad_status -ne 0 ]]
  grep -q 'E_PARAM_INVALID' <<<"$bad_output"

  printf '== negative 4/4: descriptor signature missing ==\n'
  local unsigned_descriptor unsigned_output unsigned_status
  unsigned_descriptor="$work/unsigned-descriptor.json"
  python3 - "$descriptor" "$unsigned_descriptor" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
value["producerSignature"] = None
value["signingKeyFingerprint"] = None
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True)
PY
  set +e
  unsigned_output="$(
    run_for "$origin" device-control validate \
      --descriptor "$unsigned_descriptor" --invocation "$invocation_json" 2>&1
  )"
  unsigned_status=$?
  set -e
  printf '%s\n' "$unsigned_output"
  [[ $unsigned_status -ne 0 ]]
  grep -q 'E_SIGNATURE_INVALID' <<<"$unsigned_output"

  printf '== high-risk descriptor-create (risk is not caller-declared) ==\n'
  run_for "$target" device-control descriptor-create \
    --out "$high_descriptor" \
    --template-id fs.permission-change \
    --argv '/bin/chmod,600,/tmp/mutual-control/victim' \
    --allow '2:^/tmp/mutual-control/[A-Za-z0-9._-]+$' \
    --timeout 10 --max-output-bytes 4096
  make_invocation "$high_invocation" x1-high job-x1-high nonce-x1-high \
    fs.permission-change target-device-control-selftest arg2 /tmp/mutual-control/victim \
    caller-embedded-fake-approval
  local high_invocation_json high_output high_status
  high_invocation_json="$(inline_json "$high_invocation")"

  printf '== negative 1/4: high_risk without --human-gate token file ==\n'
  set +e
  high_output="$(
    run_for "$origin" device-control dispatch-plan \
      --descriptor "$high_descriptor" --invocation "$high_invocation_json" \
      --target-device target-device-control-selftest \
      --out "$work/high-risk-job-must-not-exist.json" 2>&1
  )"
  high_status=$?
  set -e
  printf '%s\n' "$high_output"
  [[ $high_status -ne 0 ]]
  grep -q 'E_HIGH_RISK_NO_APPROVAL' <<<"$high_output"
  [[ ! -e "$work/high-risk-job-must-not-exist.json" ]]

  printf '== 3. dispatch-plan (fleet payload only; no send, no execute) ==\n'
  run_for "$origin" device-control dispatch-plan \
    --descriptor "$descriptor" --invocation "$invocation_json" \
    --target-device target-device-control-selftest --out "$job"

  printf '== synthesize and target-sign result binding (no controlled execution) ==\n'
  local binding signature result unsigned_result tampered_attempt_result
  binding="$work/result-binding.json"
  signature="$work/result-signature.json"
  result="$work/signed-result.json"
  unsigned_result="$work/unsigned-result.json"
  tampered_attempt_result="$work/tampered-attempt-result.json"
  python3 - "$job" "$binding" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    dispatch = json.load(handle)
job = dispatch["remoteLoopJob"]
payload = dispatch["payload"]
binding = {
    "jobID": job["jobID"],
    "dispatchNonce": job["dispatchNonce"],
    "invokeCanonicalDigest": payload["invokeCanonicalDigest"],
    "exitCode": 0,
    "actualArgv": payload["resolvedArgv"],
    "executableResolved": payload["resolvedExecutable"],
    "startedAt": "2026-07-30T00:00:00Z",
    "endedAt": "2026-07-30T00:00:01Z",
}
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    # Match Swift JSONEncoder(.sortedKeys), which escapes forward slashes on
    # the current toolchain. device-trust signs these exact canonical bytes.
    canonical = json.dumps(binding, sort_keys=True, separators=(",", ":"))
    handle.write(canonical.replace("/", "\\/"))
PY
  run_for "$target" device-trust sign \
    --purpose loop-result \
    --input "$binding" \
    --registry "$target/device-trust/identity.json" \
    --signature-out "$signature"
  python3 - "$binding" "$signature" "$result" "$unsigned_result" \
    "$tampered_attempt_result" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    binding = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    signature = json.load(handle)
base = {
    "schema": "TatwoMutualControlSignedResultV1",
    "binding": binding,
}
signed = dict(base)
signed["targetSignature"] = signature
unsigned = dict(base)
unsigned["targetSignature"] = None
tampered = {
    "schema": base["schema"],
    "binding": dict(binding),
    "targetSignature": signature,
}
tampered["binding"]["dispatchNonce"] = "wrong-attempt-nonce"
with open(sys.argv[3], "w", encoding="utf-8") as handle:
    json.dump(signed, handle, sort_keys=True)
with open(sys.argv[4], "w", encoding="utf-8") as handle:
    json.dump(unsigned, handle, sort_keys=True)
with open(sys.argv[5], "w", encoding="utf-8") as handle:
    json.dump(tampered, handle, sort_keys=True)
PY

  printf '== negative 3/4: result signature missing ==\n'
  local result_unsigned_output result_unsigned_status
  set +e
  result_unsigned_output="$(
    run_for "$origin" device-control result-verify \
      --result "$unsigned_result" --job "$job" 2>&1
  )"
  result_unsigned_status=$?
  set -e
  printf '%s\n' "$result_unsigned_output"
  [[ $result_unsigned_status -ne 0 ]]
  grep -q 'target signature missing' <<<"$result_unsigned_output"

  printf '== negative bonus: result attempt binding mismatch ==\n'
  local attempt_output attempt_status
  set +e
  attempt_output="$(
    run_for "$origin" device-control result-verify \
      --result "$tampered_attempt_result" --job "$job" 2>&1
  )"
  attempt_status=$?
  set -e
  printf '%s\n' "$attempt_output"
  [[ $attempt_status -ne 0 ]]
  grep -q 'attempt binding mismatch' <<<"$attempt_output"

  printf '== 4. result-verify (target signature + attempt binding) ==\n'
  run_for "$origin" device-control result-verify \
    --result "$result" --job "$job"

  printf '== guarantees ==\n'
  printf 'GUARANTEE 1: no controlled command was executed\n'
  printf 'GUARANTEE 2: trust used isolated TATWO_TEST_MODE file stores; no Keychain\n'
  printf 'GUARANTEE 3: dispatch-plan produced a fleet job artifact only; no network/SSH/enqueue\n'
  printf 'SELFTEST PASS\n'
}

print_remote_plan() {
  cat <<'EOF'
# DEVICE MUTUAL CONTROL CROSS-MACHINE PLAN (MANUAL ONLY)
# Nothing below is executed by this script. X1 stops before fleet transfer and
# before target execution. Replace placeholders and obtain separate user
# authorization for any later controlled-command execution.

# 0. BOTH HOSTS (manual): select the same tatwo-ultrawork candidate, initialize
# device-trust, exchange public identity files out of band, and pin each peer.
export TATWO_CLI=/path/to/tatwo-ultrawork

# 1. TARGET (manual): create its signed one-descriptor capability manifest.
$TATWO_CLI device-control descriptor-create \
  --out /tmp/device-control-descriptor.json \
  --template-id <template-id> \
  --argv '<executable>,<fixed-or-allowed-arg>,...' \
  --allow '<process-argv-position>:<bounded-regex>,...'

# 2. MANUAL ARTIFACT COPY: copy the immutable signed descriptor to ORIGIN using
# the operator-approved transfer method. This script does not call ssh/scp.

# 3. ORIGIN (manual): verify target pin/signature and validator-owned risk.
$TATWO_CLI device-control validate \
  --descriptor /tmp/device-control-descriptor.json \
  --invocation '<TatwoMutualControlInvocationV1 JSON>'

# 4. ORIGIN (manual): create a fleet job plan only. For high_risk, the
# per-invocation token file is mandatory; only its digest enters the payload.
$TATWO_CLI device-control dispatch-plan \
  --descriptor /tmp/device-control-descriptor.json \
  --invocation '<TatwoMutualControlInvocationV1 JSON>' \
  --target-device <target-device-id> \
  --human-gate /path/to/per-invocation-token \
  --out /tmp/device-control-job.json

# 5. STOP AT X1 BOUNDARY. Submit /tmp/device-control-job.json through the
# existing fleet channel only after separate authorization. X1 does not enqueue,
# send, SSH, or execute the controlled executable/argv.

# 6. TARGET (manual, after separately authorized execution outside X1): return a
# TatwoMutualControlSignedResultV1 signed with purpose loop-result.

# 7. ORIGIN (manual): verify target signature and attempt binding.
$TATWO_CLI device-control result-verify \
  --result /tmp/device-control-result.json \
  --job /tmp/device-control-job.json
EOF
}

case "${1:-}" in
  --selftest) selftest ;;
  --print-remote-plan) print_remote_plan ;;
  *) usage; exit 2 ;;
esac
