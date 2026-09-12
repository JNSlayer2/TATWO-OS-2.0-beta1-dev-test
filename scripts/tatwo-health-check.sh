#!/usr/bin/env bash
# tatwo-health-check.sh — 一鍵健康巡檢總命令（六件工具收口）
#
# 子工具：
#   1. tatwo-code-health.mjs scan
#   2. tatwo-doc-project.sh --verify
#   3. tatwo-test-run.sh
#   4. tatwo-memory-stress.sh          (full only)
#   5. tatwo-lint-lane.sh              (full + --lint-target)
#   6. tatwo-distributed-run.sh        (full + --dist-targets)
#
# 鐵律：
#   - 預設 --dry-run（不跑重活）
#   - 禁 git 寫入、禁網路、無主機/路徑硬編
#   - 不得為了總結論好看而降級子項語彙
#   - 需要 build 的子項共用一次 host build-lock；子進程用 nested lock dir 避免自鎖
#   - 主機壓力紅燈 → 整體 ABORTED_PRESSURE
#
# 聚合：
#   任一 FAIL → FAIL
#   無 FAIL 但有 skip / degraded / inconclusive / NOT_RUN → PASS_WITH_CAVEATS
#   全綠 → PASS
#   子項因缺參數未跑 → NOT_RUN(reason)（不得當通過）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
LOCK_HELPER="$ROOT_DIR/scripts/tatwo-build-lock.sh"

PROFILE="standard"
SKIP_CSV=""
OUT_PATH=""
MODE="dry-run" # dry-run | execute
SELFTEST=0

DOC_SOURCES="${TATWO_DOC_SOURCES:-}"
DOC_VERIFY_DIR="${TATWO_DOC_VERIFY_DIR:-}"
LINT_TARGET="${TATWO_LINT_TARGET:-}"
LINT_REV="${TATWO_LINT_REV:-}"
DIST_TARGETS="${TATWO_DIST_TARGETS:-}"
DIST_FROM_LOG="${TATWO_DIST_FROM_LOG:-}"
DIST_SUITES_FILE="${TATWO_DIST_SUITES_FILE:-}"
MEM_BINARY="${TATWO_MEM_BINARY:-$ROOT_DIR/.build/debug}"
MEM_ITERATIONS="${TATWO_MEM_ITERATIONS:-20}"
PRESSURE_MIN_FREE="${TATWO_HEALTH_PRESSURE_MIN_FREE:-20}"

# Injected for selftest only.
STUB_DIR="${TATWO_HEALTH_STUB_DIR:-}"
FORCE_PRESSURE_FREE="${TATWO_HEALTH_FORCE_PRESSURE_FREE:-}"

HOST_LOCK_DIR="${TATWO_BUILD_LOCK_DIR:-/tmp/tatwo-build.lock}"
NESTED_LOCK_DIR=""
LOCK_HELD=0
LOCK_TOKEN=""
LOCK_TOKEN_FILE=""
LOCK_ACQUIRE_COUNT=0
RUN_ID=""
EVIDENCE_ROOT=""
STARTED_AT=""
OVERALL=""
ABORT_REASON=""

# Parallel arrays for results (bash 3.2 portable).
RESULT_TOOLS=()
RESULT_STATUS=()      # pass | fail | caveat | not_run | skipped | dry_run | aborted
RESULT_CONCLUSION=()
RESULT_EVIDENCE=()
RESULT_DURATION=()
RESULT_BUCKET=()      # pass | fail | caveat | not_run | skipped | dry_run | aborted
CAVEAT_REASONS=()
FAIL_ITEMS=()
NOT_RUN_ITEMS=()

usage() {
  cat <<'EOF'
Usage:
  bash scripts/tatwo-health-check.sh \
    [--profile quick|standard|full] \
    [--skip tool,...] \
    [--out report.json] \
    [--dry-run | --execute] \
    [--doc-sources name:path,...] \
    [--doc-verify-dir DIR] \
    [--lint-target ssh:user@host:worktree] \
    [--lint-rev COMMIT] \
    [--dist-targets local,ssh:user@host:path] \
    [--dist-from-log suite.log | --dist-suites-file FILE] \
    [--mem-binary PATH] \
    [--mem-iterations N]

  bash scripts/tatwo-health-check.sh --selftest

Profiles:
  quick     code-health + doc-project --verify
  standard  quick + tatwo-test-run (full suite + observation)
  full      standard + memory-stress(20) + lint-lane(if --lint-target)
            + distributed(if --dist-targets)

Defaults:
  --dry-run ON
  --profile standard

Aggregation:
  any FAIL                         → overall FAIL (list tools)
  no FAIL but skip/degraded/
    inconclusive/NOT_RUN           → PASS_WITH_CAVEATS (list reasons)
  all green                        → PASS
  missing params for a tool        → that tool NOT_RUN(reason); never counts as pass
  host pressure free% < threshold  → ABORTED_PRESSURE

Environment (optional injection; never hard-coded hosts):
  TATWO_DOC_SOURCES / TATWO_DOC_VERIFY_DIR
  TATWO_LINT_TARGET / TATWO_LINT_REV
  TATWO_DIST_TARGETS / TATWO_DIST_FROM_LOG / TATWO_DIST_SUITES_FILE
  TATWO_MEM_BINARY / TATWO_MEM_ITERATIONS
  TATWO_BUILD_LOCK_DIR
  TATWO_HEALTH_PRESSURE_MIN_FREE   (default 20)
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

log() {
  printf '[health-check] %s\n' "$*" >&2
}

utc_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

utc_stamp() {
  date -u +"%Y%m%dT%H%M%SZ"
}

now_epoch() {
  date +%s
}

# --- arg parse ---

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --selftest)
      SELFTEST=1
      shift
      ;;
    --profile)
      [[ $# -ge 2 ]] || die "--profile requires a value"
      PROFILE="$2"
      shift 2
      ;;
    --skip)
      [[ $# -ge 2 ]] || die "--skip requires a value"
      SKIP_CSV="$2"
      shift 2
      ;;
    --out)
      [[ $# -ge 2 ]] || die "--out requires a value"
      OUT_PATH="$2"
      shift 2
      ;;
    --dry-run)
      MODE="dry-run"
      shift
      ;;
    --execute)
      MODE="execute"
      shift
      ;;
    --doc-sources)
      [[ $# -ge 2 ]] || die "--doc-sources requires a value"
      DOC_SOURCES="$2"
      shift 2
      ;;
    --doc-verify-dir)
      [[ $# -ge 2 ]] || die "--doc-verify-dir requires a value"
      DOC_VERIFY_DIR="$2"
      shift 2
      ;;
    --lint-target)
      [[ $# -ge 2 ]] || die "--lint-target requires a value"
      LINT_TARGET="$2"
      shift 2
      ;;
    --lint-rev)
      [[ $# -ge 2 ]] || die "--lint-rev requires a value"
      LINT_REV="$2"
      shift 2
      ;;
    --dist-targets)
      [[ $# -ge 2 ]] || die "--dist-targets requires a value"
      DIST_TARGETS="$2"
      shift 2
      ;;
    --dist-from-log)
      [[ $# -ge 2 ]] || die "--dist-from-log requires a value"
      DIST_FROM_LOG="$2"
      shift 2
      ;;
    --dist-suites-file)
      [[ $# -ge 2 ]] || die "--dist-suites-file requires a value"
      DIST_SUITES_FILE="$2"
      shift 2
      ;;
    --mem-binary)
      [[ $# -ge 2 ]] || die "--mem-binary requires a value"
      MEM_BINARY="$2"
      shift 2
      ;;
    --mem-iterations)
      [[ $# -ge 2 ]] || die "--mem-iterations requires a value"
      MEM_ITERATIONS="$2"
      shift 2
      ;;
    --profile=*|--skip=*|--out=*|--doc-sources=*|--doc-verify-dir=*|--lint-target=*|--lint-rev=*|--dist-targets=*|--dist-from-log=*|--dist-suites-file=*|--mem-binary=*|--mem-iterations=*)
      key="${1%%=*}"
      val="${1#*=}"
      [[ -n "$val" ]] || die "$key requires a value"
      case "$key" in
        --profile) PROFILE="$val" ;;
        --skip) SKIP_CSV="$val" ;;
        --out) OUT_PATH="$val" ;;
        --doc-sources) DOC_SOURCES="$val" ;;
        --doc-verify-dir) DOC_VERIFY_DIR="$val" ;;
        --lint-target) LINT_TARGET="$val" ;;
        --lint-rev) LINT_REV="$val" ;;
        --dist-targets) DIST_TARGETS="$val" ;;
        --dist-from-log) DIST_FROM_LOG="$val" ;;
        --dist-suites-file) DIST_SUITES_FILE="$val" ;;
        --mem-binary) MEM_BINARY="$val" ;;
        --mem-iterations) MEM_ITERATIONS="$val" ;;
      esac
      shift
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

case "$PROFILE" in
  quick|standard|full) ;;
  *) die "invalid --profile: $PROFILE (want quick|standard|full)" ;;
esac

if ! [[ "$MEM_ITERATIONS" =~ ^[0-9]+$ ]] || (( MEM_ITERATIONS < 1 )); then
  die "--mem-iterations must be a positive integer"
fi

# --- skip set ---

is_skipped() {
  local tool="$1" item
  [[ -z "$SKIP_CSV" ]] && return 1
  IFS=',' read -r -a _skip_items <<<"$SKIP_CSV"
  for item in "${_skip_items[@]}"; do
    item="$(printf '%s' "$item" | tr -d '[:space:]')"
    [[ "$item" == "$tool" ]] && return 0
  done
  return 1
}

tool_in_profile() {
  local tool="$1"
  case "$PROFILE" in
    quick)
      case "$tool" in
        code-health|doc-project) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    standard)
      case "$tool" in
        code-health|doc-project|test-run) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    full)
      case "$tool" in
        code-health|doc-project|test-run|memory-stress|lint-lane|distributed) return 0 ;;
        *) return 1 ;;
      esac
      ;;
  esac
}

tool_needs_build_lock() {
  local tool="$1"
  case "$tool" in
    test-run|distributed) return 0 ;;
    *) return 1 ;;
  esac
}

# --- pressure ---

pressure_free_percent() {
  if [[ -n "$FORCE_PRESSURE_FREE" ]]; then
    printf '%s\n' "$FORCE_PRESSURE_FREE"
    return 0
  fi
  local out free
  if ! command -v /usr/bin/memory_pressure >/dev/null 2>&1; then
    printf 'unavailable\n'
    return 1
  fi
  out="$(/usr/bin/memory_pressure -Q 2>/dev/null || true)"
  free="$(
    printf '%s\n' "$out" | python3 -c '
import re,sys
text=sys.stdin.read()
m=re.search(r"System-wide memory free percentage:\s*([0-9]+(?:\.[0-9]+)?)\s*%", text)
if not m:
    sys.exit(1)
print(m.group(1))
' 2>/dev/null || true
  )"
  if [[ -z "$free" ]]; then
    printf 'unavailable\n'
    return 1
  fi
  printf '%s\n' "$free"
}

check_pressure_or_abort() {
  local free
  free="$(pressure_free_percent || true)"
  if [[ "$free" == "unavailable" || -z "$free" ]]; then
    # Unavailable is not a hard abort; record and continue (fail-open only for probe).
    log "memory_pressure free% unavailable; continuing (not treating as green pressure proof)"
    return 0
  fi
  python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)" \
    "$free" "$PRESSURE_MIN_FREE" 2>/dev/null || {
    ABORT_REASON="ABORTED_PRESSURE: memory_pressure free=${free}% < ${PRESSURE_MIN_FREE}%"
    OVERALL="ABORTED_PRESSURE"
    log "$ABORT_REASON"
    return 1
  }
  return 0
}

# --- lock (host once) ---

extract_lock_token() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      token=*)
        printf '%s\n' "${line#token=}"
        return 0
        ;;
    esac
  done
  return 1
}

release_host_lock() {
  if [[ "$LOCK_HELD" -ne 1 ]]; then
    return 0
  fi
  # Always release against the host lock path — children may have rebound
  # TATWO_BUILD_LOCK_DIR to the nested dir while the orchestrator holds host.
  if [[ -n "$LOCK_TOKEN" ]]; then
    TATWO_BUILD_LOCK_DIR="$HOST_LOCK_DIR" \
      "$LOCK_HELPER" release --token "$LOCK_TOKEN" --pid "$$" >&2 || true
  elif [[ -n "$LOCK_TOKEN_FILE" && -f "$LOCK_TOKEN_FILE" ]]; then
    TATWO_BUILD_LOCK_DIR="$HOST_LOCK_DIR" \
    TATWO_BUILD_LOCK_TOKEN_FILE="$LOCK_TOKEN_FILE" \
      "$LOCK_HELPER" release --pid "$$" >&2 || true
  fi
  LOCK_HELD=0
  LOCK_TOKEN=""
  if [[ -n "$LOCK_TOKEN_FILE" ]]; then
    rm -f "$LOCK_TOKEN_FILE" 2>/dev/null || true
    LOCK_TOKEN_FILE=""
  fi
}

acquire_host_lock_once() {
  if [[ "$LOCK_HELD" -eq 1 ]]; then
    return 0
  fi
  [[ -x "$LOCK_HELPER" ]] || die "build-lock helper missing: $LOCK_HELPER"
  local acq_out acq_rc tok
  LOCK_TOKEN_FILE="$(mktemp "${TMPDIR:-/tmp}/tatwo-health-lock-token.XXXXXX")"
  set +e
  acq_out="$(
    TATWO_BUILD_LOCK_DIR="$HOST_LOCK_DIR" \
    TATWO_BUILD_LOCK_TOKEN_FILE="$LOCK_TOKEN_FILE" \
      "$LOCK_HELPER" acquire --pid "$$" 2>&1
  )"
  acq_rc=$?
  set -e
  if [[ -n "$acq_out" ]]; then
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        token=*) ;;
        *) printf '%s\n' "$line" >&2 ;;
      esac
    done <<<"$acq_out"
  fi
  if [[ "$acq_rc" -ne 0 ]]; then
    rm -f "$LOCK_TOKEN_FILE" 2>/dev/null || true
    LOCK_TOKEN_FILE=""
    die "build-lock acquire failed (host lock: $HOST_LOCK_DIR)"
  fi
  tok=""
  if [[ -f "$LOCK_TOKEN_FILE" ]]; then
    tok="$(tr -d '[:space:]' <"$LOCK_TOKEN_FILE" || true)"
  fi
  if [[ -z "$tok" ]]; then
    tok="$(printf '%s\n' "$acq_out" | extract_lock_token || true)"
  fi
  [[ -n "$tok" ]] || die "build-lock acquire returned no ownership token"
  LOCK_TOKEN="$tok"
  LOCK_HELD=1
  LOCK_ACQUIRE_COUNT=$((LOCK_ACQUIRE_COUNT + 1))
  log "host build-lock acquired (count=$LOCK_ACQUIRE_COUNT) at $HOST_LOCK_DIR"
  # Nested lock *path* for child tools so they do not re-contend the host lock.
  # Must NOT pre-create the directory: tatwo-build-lock acquire publishes the
  # lock dir atomically; an empty pre-existing dir looks like a suspect lock
  # and costs ~SUSPECT_TIMEOUT wait (was 120s).
  NESTED_LOCK_DIR="${TMPDIR:-/tmp}/tatwo-health-nested-lock.${RUN_ID:-$$}.$RANDOM"
  # Ensure parent exists only; leave the lock basename free for acquire.
  mkdir -p "$(dirname "$NESTED_LOCK_DIR")"
  export TATWO_BUILD_LOCK_DIR="$NESTED_LOCK_DIR"
}

# --- result recording ---

record_result() {
  local tool="$1" status="$2" conclusion="$3" evidence="$4" duration="$5" bucket="$6"
  RESULT_TOOLS+=("$tool")
  RESULT_STATUS+=("$status")
  RESULT_CONCLUSION+=("$conclusion")
  RESULT_EVIDENCE+=("$evidence")
  RESULT_DURATION+=("$duration")
  RESULT_BUCKET+=("$bucket")
  case "$bucket" in
    fail)
      FAIL_ITEMS+=("$tool: $conclusion")
      ;;
    caveat)
      CAVEAT_REASONS+=("$tool: $conclusion")
      ;;
    not_run)
      NOT_RUN_ITEMS+=("$tool: $conclusion")
      CAVEAT_REASONS+=("$tool: $conclusion")
      ;;
    skipped)
      CAVEAT_REASONS+=("$tool: $conclusion")
      ;;
    dry_run)
      CAVEAT_REASONS+=("$tool: $conclusion")
      ;;
    aborted)
      ABORT_REASON="$conclusion"
      ;;
  esac
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()[:-1] if False else sys.argv[1]))' "$1"
}

write_report_json() {
  local path="$1"
  python3 - "$path" <<'PY'
import json, os, sys, time

path = sys.argv[1]
tools = os.environ.get("HC_TOOLS", "").split("\n") if os.environ.get("HC_TOOLS") else []
# Prefer file-based transfer for reliability
payload_path = os.environ["HC_PAYLOAD_PATH"]
with open(payload_path, "r", encoding="utf-8") as f:
    payload = json.load(f)
with open(path, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(path)
PY
}

build_and_write_report() {
  local path="$1"
  local payload_path
  payload_path="$(mktemp "${TMPDIR:-/tmp}/tatwo-health-payload.XXXXXX.json")"
  export HC_PAYLOAD_PATH="$payload_path"

  python3 - "$payload_path" <<'PY'
import json, os, sys

tools = os.environ["HC_R_TOOLS"].split("\x1e") if os.environ.get("HC_R_TOOLS") else []
statuses = os.environ["HC_R_STATUS"].split("\x1e") if os.environ.get("HC_R_STATUS") else []
conclusions = os.environ["HC_R_CONCL"].split("\x1e") if os.environ.get("HC_R_CONCL") else []
evidences = os.environ["HC_R_EVID"].split("\x1e") if os.environ.get("HC_R_EVID") else []
durations = os.environ["HC_R_DUR"].split("\x1e") if os.environ.get("HC_R_DUR") else []
buckets = os.environ["HC_R_BUCKET"].split("\x1e") if os.environ.get("HC_R_BUCKET") else []

# Drop a single empty split artifact when arrays are empty.
if tools == [""]:
    tools, statuses, conclusions, evidences, durations, buckets = [], [], [], [], [], []

items = []
for i, tool in enumerate(tools):
    items.append({
        "tool": tool,
        "status": statuses[i] if i < len(statuses) else "",
        "conclusion": conclusions[i] if i < len(conclusions) else "",
        "evidencePath": evidences[i] if i < len(evidences) else "",
        "durationSec": float(durations[i]) if i < len(durations) and durations[i] != "" else 0,
        "bucket": buckets[i] if i < len(buckets) else "",
    })

caveats = [c for c in os.environ.get("HC_CAVEATS", "").split("\x1e") if c]
fails = [c for c in os.environ.get("HC_FAILS", "").split("\x1e") if c]
not_runs = [c for c in os.environ.get("HC_NOT_RUNS", "").split("\x1e") if c]

payload = {
    "schema": "TatwoHealthCheckReportV1",
    "runId": os.environ.get("HC_RUN_ID", ""),
    "profile": os.environ.get("HC_PROFILE", ""),
    "mode": os.environ.get("HC_MODE", ""),
    "startedAt": os.environ.get("HC_STARTED", ""),
    "finishedAt": os.environ.get("HC_FINISHED", ""),
    "overall": os.environ.get("HC_OVERALL", ""),
    "abortReason": os.environ.get("HC_ABORT", "") or None,
    "hostLock": {
        "path": os.environ.get("HC_HOST_LOCK", ""),
        "acquireCount": int(os.environ.get("HC_LOCK_COUNT", "0") or "0"),
        "heldByOrchestrator": os.environ.get("HC_LOCK_HELD", "0") == "1",
    },
    "aggregation": {
        "rule": [
            "any FAIL → overall FAIL",
            "no FAIL but skip/degraded/inconclusive/NOT_RUN/dry_run → PASS_WITH_CAVEATS",
            "all green → PASS",
            "NOT_RUN(reason) never counts as pass",
            "host pressure free% < threshold → ABORTED_PRESSURE",
        ],
        "failItems": fails,
        "caveatReasons": caveats,
        "notRunItems": not_runs,
    },
    "items": items,
}

out = sys.argv[1]
with open(out, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY

  if [[ -n "$path" ]]; then
    mkdir -p "$(dirname "$path")"
    cp "$payload_path" "$path"
    log "wrote report: $path"
  fi
  # Always keep a copy under evidence root.
  cp "$payload_path" "$EVIDENCE_ROOT/report.json"
  rm -f "$payload_path"
}

join_rs() {
  # join args with RS \x1e
  local first=1 arg
  for arg in "$@"; do
    if [[ $first -eq 1 ]]; then
      printf '%s' "$arg"
      first=0
    else
      printf '\x1e%s' "$arg"
    fi
  done
}

finalize_overall() {
  if [[ -n "$OVERALL" ]]; then
    return 0
  fi
  if (( ${#FAIL_ITEMS[@]} > 0 )); then
    OVERALL="FAIL"
    return 0
  fi
  if (( ${#CAVEAT_REASONS[@]} > 0 )) || (( ${#NOT_RUN_ITEMS[@]} > 0 )); then
    OVERALL="PASS_WITH_CAVEATS"
    return 0
  fi
  if (( ${#RESULT_TOOLS[@]} == 0 )); then
    OVERALL="PASS_WITH_CAVEATS"
    CAVEAT_REASONS+=("orchestrator: no tools selected")
    return 0
  fi
  OVERALL="PASS"
}

print_human_summary() {
  local i
  printf '\n======== Tatwo Health Check SUMMARY ========\n'
  printf 'runId:    %s\n' "$RUN_ID"
  printf 'profile:  %s\n' "$PROFILE"
  printf 'mode:     %s\n' "$MODE"
  printf 'overall:  %s\n' "$OVERALL"
  if [[ -n "$ABORT_REASON" ]]; then
    printf 'abort:    %s\n' "$ABORT_REASON"
  fi
  printf 'lockAcq:  %s (host %s)\n' "$LOCK_ACQUIRE_COUNT" "$HOST_LOCK_DIR"
  printf '\nitems:\n'
  for i in "${!RESULT_TOOLS[@]}"; do
    printf '  - %-14s status=%-8s duration=%ss\n    conclusion: %s\n    evidence: %s\n' \
      "${RESULT_TOOLS[$i]}" \
      "${RESULT_STATUS[$i]}" \
      "${RESULT_DURATION[$i]}" \
      "${RESULT_CONCLUSION[$i]}" \
      "${RESULT_EVIDENCE[$i]}"
  done
  if (( ${#FAIL_ITEMS[@]} > 0 )); then
    printf '\nFAIL items:\n'
    local f
    for f in "${FAIL_ITEMS[@]}"; do
      printf '  - %s\n' "$f"
    done
  fi
  if (( ${#CAVEAT_REASONS[@]} > 0 )); then
    printf '\nCaveats / NOT_RUN (not counted as pass):\n'
    local c
    for c in "${CAVEAT_REASONS[@]}"; do
      printf '  - %s\n' "$c"
    done
  fi
  printf 'report: %s\n' "${OUT_PATH:-$EVIDENCE_ROOT/report.json}"
  printf '===========================================\n'
}

# --- classification helpers (preserve child vocabulary) ---

# Maps child stdout/stderr + exit → bucket/status/conclusion.
# Never renames child conclusions for cosmetics.
classify_code_health() {
  local output="$1" exit_code="$2"
  local findings critical high
  findings="$(printf '%s\n' "$output" | python3 -c '
import re,sys
text=sys.stdin.read()
m=re.search(r"^findings:\s*(\d+)\s*$", text, re.M)
print(m.group(1) if m else "")
' 2>/dev/null || true)"
  critical="$(printf '%s\n' "$output" | python3 -c '
import re,sys
text=sys.stdin.read()
m=re.search(r"^\s*critical:\s*(\d+)\s*$", text, re.M)
print(m.group(1) if m else "0")
' 2>/dev/null || true)"
  high="$(printf '%s\n' "$output" | python3 -c '
import re,sys
text=sys.stdin.read()
m=re.search(r"^\s*high:\s*(\d+)\s*$", text, re.M)
print(m.group(1) if m else "0")
' 2>/dev/null || true)"
  [[ -n "$findings" ]] || findings="?"
  [[ -n "$critical" ]] || critical="0"
  [[ -n "$high" ]] || high="0"

  if [[ "$exit_code" -ne 0 ]]; then
    printf 'fail\nfail\n%s\n' "code-health exit=$exit_code findings=$findings"
    return 0
  fi
  # Keep tool vocabulary: findings / bySeverity. Critical|high findings are FAIL-class
  # for orchestration (mechanical gate); medium/low alone are caveats, zero is pass.
  if python3 -c "import sys; sys.exit(0 if int(sys.argv[1])>0 or int(sys.argv[2])>0 else 1)" \
      "$critical" "$high" 2>/dev/null; then
    printf 'fail\nfail\nfindings: %s (critical=%s high=%s)\n' "$findings" "$critical" "$high"
    return 0
  fi
  if [[ "$findings" != "0" && "$findings" != "?" ]]; then
    printf 'caveat\ncaveat\nfindings: %s (critical=%s high=%s; medium/low only)\n' \
      "$findings" "$critical" "$high"
    return 0
  fi
  printf 'pass\npass\nfindings: %s\n' "$findings"
}

classify_doc_project() {
  local output="$1" exit_code="$2"
  local conclusion stats
  conclusion="$(printf '%s\n' "$output" | grep -E '^CONCLUSION:' | tail -n 1 | sed 's/^CONCLUSION: //' || true)"
  stats="$(printf '%s\n' "$output" | grep -E '^STATS ' | tail -n 1 || true)"
  if [[ -z "$conclusion" ]]; then
    if [[ "$exit_code" -ne 0 ]]; then
      printf 'fail\nfail\n%s\n' "doc-project exit=$exit_code (no CONCLUSION line)"
    else
      printf 'caveat\ncaveat\n%s\n' "doc-project exit=0 but missing CONCLUSION"
    fi
    return 0
  fi
  if [[ "$conclusion" == VERIFY_FAIL* ]] || [[ "$exit_code" -ne 0 && "$conclusion" == *FAIL* ]]; then
    printf 'fail\nfail\n%s\n' "$conclusion${stats:+; $stats}"
    return 0
  fi
  # Preserve three-state stats as caveats when stale/missing present even if VERIFY_OK.
  if [[ "$stats" =~ stale=[1-9] || "$stats" =~ missing_source=[1-9] ]]; then
    printf 'caveat\ncaveat\n%s\n' "$conclusion; $stats"
    return 0
  fi
  if [[ "$conclusion" == VERIFY_OK* ]]; then
    printf 'pass\npass\n%s\n' "$conclusion${stats:+; $stats}"
    return 0
  fi
  # Unknown conclusion text: keep raw, treat non-zero as fail.
  if [[ "$exit_code" -ne 0 ]]; then
    printf 'fail\nfail\n%s\n' "$conclusion"
  else
    printf 'caveat\ncaveat\n%s\n' "$conclusion"
  fi
}

classify_test_run() {
  local output="$1" exit_code="$2"
  local line
  line="$(printf '%s\n' "$output" | grep -E '^(PASS|FAIL|OBSERVATION_SUSPECT)' | head -n 1 || true)"
  [[ -n "$line" ]] || line="(no conclusion line; exit=$exit_code)"
  case "$line" in
    FAIL*)
      printf 'fail\nfail\n%s\n' "$line"
      ;;
    OBSERVATION_SUSPECT*)
      # Observation discipline inconclusive class → caveats (not silent pass).
      printf 'caveat\ncaveat\n%s\n' "$line"
      ;;
    PASS*)
      if [[ "$line" == *skipped* ]]; then
        printf 'caveat\ncaveat\n%s\n' "$line"
      else
        printf 'pass\npass\n%s\n' "$line"
      fi
      ;;
    *)
      if [[ "$exit_code" -ne 0 ]]; then
        printf 'fail\nfail\n%s\n' "$line"
      else
        printf 'caveat\ncaveat\n%s\n' "$line"
      fi
      ;;
  esac
}

classify_memory_stress() {
  local output="$1" exit_code="$2" receipt="$3"
  local classification conclusion
  classification=""
  if [[ -f "$receipt" ]]; then
    classification="$(python3 -c '
import json,sys
try:
  o=json.load(open(sys.argv[1]))
  print((o.get("result") or {}).get("classification") or "")
except Exception:
  print("")
' "$receipt" 2>/dev/null || true)"
    conclusion="$(python3 -c '
import json,sys
try:
  o=json.load(open(sys.argv[1]))
  print((o.get("result") or {}).get("conclusion") or "")
except Exception:
  print("")
' "$receipt" 2>/dev/null || true)"
  fi
  if [[ -z "$classification" ]]; then
    classification="$(printf '%s\n' "$output" | grep -E '^(STABLE|LEAK_SUSPECTED|INCONCLUSIVE|ABORTED_PRESSURE|DRY_RUN)' | head -n 1 | awk '{print $1}' || true)"
  fi
  [[ -n "$conclusion" ]] || conclusion="$(printf '%s\n' "$output" | tail -n 5 | tr '\n' ' ')"
  case "$classification" in
    STABLE)
      printf 'pass\npass\n%s\n' "${conclusion:-STABLE}"
      ;;
    LEAK_SUSPECTED)
      printf 'fail\nfail\n%s\n' "${conclusion:-LEAK_SUSPECTED}"
      ;;
    INCONCLUSIVE)
      printf 'caveat\ncaveat\n%s\n' "${conclusion:-INCONCLUSIVE}"
      ;;
    ABORTED_PRESSURE)
      printf 'aborted\naborted\n%s\n' "${conclusion:-ABORTED_PRESSURE}"
      ;;
    DRY_RUN)
      printf 'dry_run\ndry_run\n%s\n' "${conclusion:-DRY_RUN}"
      ;;
    *)
      if [[ "$exit_code" -ne 0 ]]; then
        printf 'fail\nfail\n%s\n' "${conclusion:-memory-stress exit=$exit_code}"
      else
        printf 'caveat\ncaveat\n%s\n' "${conclusion:-memory-stress unclassified}"
      fi
      ;;
  esac
}

classify_lint_lane() {
  local output="$1" exit_code="$2"
  local conclusion
  conclusion="$(printf '%s\n' "$output" | grep -E '^CONCLUSION:' | tail -n 1 | sed 's/^CONCLUSION: //' || true)"
  [[ -n "$conclusion" ]] || conclusion="(no CONCLUSION; exit=$exit_code)"
  case "$conclusion" in
    LINT_CLEAN)
      printf 'pass\npass\n%s\n' "$conclusion"
      ;;
    LINT_FINDINGS*)
      printf 'fail\nfail\n%s\n' "$conclusion"
      ;;
    LINT_BLOCKED*)
      printf 'caveat\ncaveat\n%s\n' "$conclusion"
      ;;
    *)
      if [[ "$MODE" == "dry-run" ]] && [[ "$output" == *"PLAN"* ]]; then
        printf 'dry_run\ndry_run\n%s\n' "lint-lane dry-run plan"
      elif [[ "$exit_code" -ne 0 ]]; then
        printf 'fail\nfail\n%s\n' "$conclusion"
      else
        printf 'caveat\ncaveat\n%s\n' "$conclusion"
      fi
      ;;
  esac
}

classify_distributed() {
  local output="$1" exit_code="$2"
  local conclusion
  conclusion="$(printf '%s\n' "$output" | grep -E '^CONCLUSION:' | tail -n 1 | sed 's/^CONCLUSION: //' || true)"
  [[ -n "$conclusion" ]] || conclusion="(no CONCLUSION; exit=$exit_code)"
  case "$conclusion" in
    FAIL*|*"FAIL:"*)
      printf 'fail\nfail\n%s\n' "$conclusion"
      ;;
    PASS_WITH_SKIPS*|*"PASS_WITH_SKIPS"*)
      printf 'caveat\ncaveat\n%s\n' "$conclusion"
      ;;
    DEGRADED*|*"DEGRADED"*)
      printf 'caveat\ncaveat\n%s\n' "$conclusion"
      ;;
    PASS*|*"PASS:"*)
      # Pure PASS only when not co-labeled DEGRADED / PASS_WITH_SKIPS (handled above).
      printf 'pass\npass\n%s\n' "$conclusion"
      ;;
    *)
      if [[ "$MODE" == "dry-run" ]] && [[ "$output" == *"PLAN"* || "$output" == *"dry-run"* ]]; then
        printf 'dry_run\ndry_run\n%s\n' "distributed dry-run plan"
      elif [[ "$exit_code" -ne 0 ]]; then
        printf 'fail\nfail\n%s\n' "$conclusion"
      else
        printf 'caveat\ncaveat\n%s\n' "$conclusion"
      fi
      ;;
  esac
}

# --- tool runners ---

run_captured() {
  # run_captured <logfile> -- command...
  local logfile="$1"
  shift
  if [[ "${1:-}" == "--" ]]; then
    shift
  fi
  local start end rc
  start="$(now_epoch)"
  set +e
  "$@" >"$logfile" 2>&1
  rc=$?
  set -e
  end="$(now_epoch)"
  printf '%s\n%s\n' "$rc" "$((end - start))"
}

ensure_build_lock_if_needed() {
  local tool="$1"
  if tool_needs_build_lock "$tool" && [[ "$MODE" == "execute" ]]; then
    if ! check_pressure_or_abort; then
      return 1
    fi
    acquire_host_lock_once
  fi
  return 0
}

run_tool_code_health() {
  local tool="code-health"
  local evidence="$EVIDENCE_ROOT/${tool}.log"
  local start end rc output class_out bucket status conclusion duration

  if is_skipped "$tool"; then
    record_result "$tool" "skipped" "skipped via --skip" "" "0" "skipped"
    return 0
  fi
  if ! tool_in_profile "$tool"; then
    return 0
  fi

  if [[ "$MODE" == "dry-run" ]]; then
    printf 'PLAN: node scripts/tatwo-code-health.mjs scan --root %s\n' "$ROOT_DIR" | tee "$evidence" >/dev/null
    record_result "$tool" "dry_run" "DRY_RUN: code-health scan planned (not executed)" "$evidence" "0" "dry_run"
    return 0
  fi

  if [[ -n "$STUB_DIR" && -x "$STUB_DIR/code-health" ]]; then
    start="$(now_epoch)"
    set +e
    output="$("$STUB_DIR/code-health" 2>&1)"
    rc=$?
    set -e
    end="$(now_epoch)"
    printf '%s\n' "$output" >"$evidence"
    duration=$((end - start))
  else
    start="$(now_epoch)"
    set +e
    output="$(cd "$ROOT_DIR" && node "$ROOT_DIR/scripts/tatwo-code-health.mjs" scan --root "$ROOT_DIR" 2>&1)"
    rc=$?
    set -e
    end="$(now_epoch)"
    printf '%s\n' "$output" >"$evidence"
    duration=$((end - start))
  fi

  class_out="$(classify_code_health "$output" "$rc")"
  bucket="$(printf '%s\n' "$class_out" | sed -n '1p')"
  status="$(printf '%s\n' "$class_out" | sed -n '2p')"
  conclusion="$(printf '%s\n' "$class_out" | sed -n '3p')"
  record_result "$tool" "$status" "$conclusion" "$evidence" "$duration" "$bucket"
}

run_tool_doc_project() {
  local tool="doc-project"
  local evidence="$EVIDENCE_ROOT/${tool}.log"
  local start end rc output class_out bucket status conclusion duration

  if is_skipped "$tool"; then
    record_result "$tool" "skipped" "skipped via --skip" "" "0" "skipped"
    return 0
  fi
  if ! tool_in_profile "$tool"; then
    return 0
  fi

  if [[ -z "$DOC_SOURCES" || -z "$DOC_VERIFY_DIR" ]]; then
    local reason="NOT_RUN(missing --doc-sources and/or --doc-verify-dir; set flags or TATWO_DOC_SOURCES/TATWO_DOC_VERIFY_DIR)"
    printf '%s\n' "$reason" >"$evidence"
    record_result "$tool" "not_run" "$reason" "$evidence" "0" "not_run"
    return 0
  fi

  if [[ "$MODE" == "dry-run" ]]; then
    {
      printf 'PLAN: bash scripts/tatwo-doc-project.sh --verify %s --sources %s\n' \
        "$DOC_VERIFY_DIR" "$DOC_SOURCES"
    } | tee "$evidence" >/dev/null
    record_result "$tool" "dry_run" "DRY_RUN: doc-project --verify planned (not executed)" "$evidence" "0" "dry_run"
    return 0
  fi

  if [[ -n "$STUB_DIR" && -x "$STUB_DIR/doc-project" ]]; then
    start="$(now_epoch)"
    set +e
    output="$("$STUB_DIR/doc-project" 2>&1)"
    rc=$?
    set -e
    end="$(now_epoch)"
    printf '%s\n' "$output" >"$evidence"
    duration=$((end - start))
  else
    start="$(now_epoch)"
    set +e
    output="$(
      bash "$ROOT_DIR/scripts/tatwo-doc-project.sh" \
        --verify "$DOC_VERIFY_DIR" \
        --sources "$DOC_SOURCES" 2>&1
    )"
    rc=$?
    set -e
    end="$(now_epoch)"
    printf '%s\n' "$output" >"$evidence"
    duration=$((end - start))
  fi

  class_out="$(classify_doc_project "$output" "$rc")"
  bucket="$(printf '%s\n' "$class_out" | sed -n '1p')"
  status="$(printf '%s\n' "$class_out" | sed -n '2p')"
  conclusion="$(printf '%s\n' "$class_out" | sed -n '3p')"
  record_result "$tool" "$status" "$conclusion" "$evidence" "$duration" "$bucket"
}

run_tool_test_run() {
  local tool="test-run"
  local evidence="$EVIDENCE_ROOT/${tool}.log"
  local start end rc output class_out bucket status conclusion duration

  if is_skipped "$tool"; then
    record_result "$tool" "skipped" "skipped via --skip" "" "0" "skipped"
    return 0
  fi
  if ! tool_in_profile "$tool"; then
    return 0
  fi

  if [[ "$MODE" == "dry-run" ]]; then
    printf 'PLAN: bash scripts/tatwo-test-run.sh  (under shared host build-lock)\n' | tee "$evidence" >/dev/null
    record_result "$tool" "dry_run" "DRY_RUN: test-run planned (not executed)" "$evidence" "0" "dry_run"
    return 0
  fi

  if ! ensure_build_lock_if_needed "$tool"; then
    record_result "$tool" "aborted" "${ABORT_REASON:-ABORTED_PRESSURE}" "$evidence" "0" "aborted"
    return 1
  fi

  if [[ -n "$STUB_DIR" && -x "$STUB_DIR/test-run" ]]; then
    start="$(now_epoch)"
    set +e
    # Stub may call lock helper via nested TATWO_BUILD_LOCK_DIR.
    output="$("$STUB_DIR/test-run" 2>&1)"
    rc=$?
    set -e
    end="$(now_epoch)"
    printf '%s\n' "$output" >"$evidence"
    duration=$((end - start))
  else
    start="$(now_epoch)"
    set +e
    # Child uses nested lock dir (exported) while orchestrator holds host lock once.
    output="$(
      TATWO_LOG="$EVIDENCE_ROOT/test-run-suite.log" \
        bash "$ROOT_DIR/scripts/tatwo-test-run.sh" 2>&1
    )"
    rc=$?
    set -e
    end="$(now_epoch)"
    printf '%s\n' "$output" >"$evidence"
    duration=$((end - start))
  fi

  class_out="$(classify_test_run "$output" "$rc")"
  bucket="$(printf '%s\n' "$class_out" | sed -n '1p')"
  status="$(printf '%s\n' "$class_out" | sed -n '2p')"
  conclusion="$(printf '%s\n' "$class_out" | sed -n '3p')"
  record_result "$tool" "$status" "$conclusion" "$evidence" "$duration" "$bucket"
}

run_tool_memory_stress() {
  local tool="memory-stress"
  local evidence="$EVIDENCE_ROOT/${tool}.log"
  local receipt="$EVIDENCE_ROOT/${tool}-receipt.json"
  local start end rc output class_out bucket status conclusion duration

  if is_skipped "$tool"; then
    record_result "$tool" "skipped" "skipped via --skip" "" "0" "skipped"
    return 0
  fi
  if ! tool_in_profile "$tool"; then
    return 0
  fi

  # full only — already gated by profile. Always plan iterations=20 default.
  if [[ "$MODE" == "dry-run" ]]; then
    {
      printf 'PLAN: bash scripts/tatwo-memory-stress.sh --iterations %s --binary %s --out %s --dry-run\n' \
        "$MEM_ITERATIONS" "$MEM_BINARY" "$receipt"
    } | tee "$evidence" >/dev/null
    record_result "$tool" "dry_run" "DRY_RUN: memory-stress planned (not executed)" "$evidence" "0" "dry_run"
    return 0
  fi

  if ! check_pressure_or_abort; then
    record_result "$tool" "aborted" "${ABORT_REASON:-ABORTED_PRESSURE}" "$evidence" "0" "aborted"
    OVERALL="ABORTED_PRESSURE"
    return 1
  fi

  if [[ -n "$STUB_DIR" && -x "$STUB_DIR/memory-stress" ]]; then
    start="$(now_epoch)"
    set +e
    output="$("$STUB_DIR/memory-stress" --out "$receipt" 2>&1)"
    rc=$?
    set -e
    end="$(now_epoch)"
    printf '%s\n' "$output" >"$evidence"
    duration=$((end - start))
  else
    start="$(now_epoch)"
    set +e
    output="$(
      bash "$ROOT_DIR/scripts/tatwo-memory-stress.sh" \
        --execute \
        --iterations "$MEM_ITERATIONS" \
        --binary "$MEM_BINARY" \
        --out "$receipt" 2>&1
    )"
    rc=$?
    set -e
    end="$(now_epoch)"
    printf '%s\n' "$output" >"$evidence"
    duration=$((end - start))
  fi

  class_out="$(classify_memory_stress "$output" "$rc" "$receipt")"
  bucket="$(printf '%s\n' "$class_out" | sed -n '1p')"
  status="$(printf '%s\n' "$class_out" | sed -n '2p')"
  conclusion="$(printf '%s\n' "$class_out" | sed -n '3p')"
  if [[ "$bucket" == "aborted" ]]; then
    OVERALL="ABORTED_PRESSURE"
    ABORT_REASON="$conclusion"
  fi
  record_result "$tool" "$status" "$conclusion" "${receipt:-$evidence}" "$duration" "$bucket"
  [[ "$bucket" != "aborted" ]]
}

run_tool_lint_lane() {
  local tool="lint-lane"
  local evidence="$EVIDENCE_ROOT/${tool}.log"
  local start end rc output class_out bucket status conclusion duration

  if is_skipped "$tool"; then
    record_result "$tool" "skipped" "skipped via --skip" "" "0" "skipped"
    return 0
  fi
  if ! tool_in_profile "$tool"; then
    return 0
  fi

  if [[ -z "$LINT_TARGET" ]]; then
    local reason="NOT_RUN(missing --lint-target; full profile only runs lint-lane when target is provided)"
    printf '%s\n' "$reason" >"$evidence"
    record_result "$tool" "not_run" "$reason" "$evidence" "0" "not_run"
    return 0
  fi
  if [[ -z "$LINT_REV" ]]; then
    # Prefer explicit rev; if missing, resolve local HEAD (not a remote host hardcode).
    LINT_REV="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)"
  fi
  if [[ -z "$LINT_REV" ]]; then
    local reason="NOT_RUN(missing --lint-rev and cannot resolve local HEAD)"
    printf '%s\n' "$reason" >"$evidence"
    record_result "$tool" "not_run" "$reason" "$evidence" "0" "not_run"
    return 0
  fi

  if [[ "$MODE" == "dry-run" ]]; then
    {
      printf 'PLAN: bash scripts/tatwo-lint-lane.sh --target %s --rev %s --dry-run\n' \
        "$LINT_TARGET" "$LINT_REV"
    } | tee "$evidence" >/dev/null
    # Still invoke real dry-run to preserve tool output vocabulary when not stubbed.
    if [[ -z "$STUB_DIR" ]]; then
      set +e
      bash "$ROOT_DIR/scripts/tatwo-lint-lane.sh" \
        --target "$LINT_TARGET" \
        --rev "$LINT_REV" \
        --dry-run >>"$evidence" 2>&1
      set -e
    fi
    record_result "$tool" "dry_run" "DRY_RUN: lint-lane planned" "$evidence" "0" "dry_run"
    return 0
  fi

  if [[ -n "$STUB_DIR" && -x "$STUB_DIR/lint-lane" ]]; then
    start="$(now_epoch)"
    set +e
    output="$("$STUB_DIR/lint-lane" 2>&1)"
    rc=$?
    set -e
    end="$(now_epoch)"
    printf '%s\n' "$output" >"$evidence"
    duration=$((end - start))
  else
    start="$(now_epoch)"
    set +e
    output="$(
      bash "$ROOT_DIR/scripts/tatwo-lint-lane.sh" \
        --target "$LINT_TARGET" \
        --rev "$LINT_REV" \
        --execute 2>&1
    )"
    rc=$?
    set -e
    end="$(now_epoch)"
    printf '%s\n' "$output" >"$evidence"
    duration=$((end - start))
  fi

  class_out="$(classify_lint_lane "$output" "$rc")"
  bucket="$(printf '%s\n' "$class_out" | sed -n '1p')"
  status="$(printf '%s\n' "$class_out" | sed -n '2p')"
  conclusion="$(printf '%s\n' "$class_out" | sed -n '3p')"
  record_result "$tool" "$status" "$conclusion" "$evidence" "$duration" "$bucket"
}

run_tool_distributed() {
  local tool="distributed"
  local evidence="$EVIDENCE_ROOT/${tool}.log"
  local start end rc output class_out bucket status conclusion duration
  local args=()

  if is_skipped "$tool"; then
    record_result "$tool" "skipped" "skipped via --skip" "" "0" "skipped"
    return 0
  fi
  if ! tool_in_profile "$tool"; then
    return 0
  fi

  if [[ -z "$DIST_TARGETS" ]]; then
    local reason="NOT_RUN(missing --dist-targets; full profile only runs distributed when targets are provided)"
    printf '%s\n' "$reason" >"$evidence"
    record_result "$tool" "not_run" "$reason" "$evidence" "0" "not_run"
    return 0
  fi
  if [[ -z "$DIST_FROM_LOG" && -z "$DIST_SUITES_FILE" ]]; then
    local reason="NOT_RUN(missing --dist-from-log or --dist-suites-file)"
    printf '%s\n' "$reason" >"$evidence"
    record_result "$tool" "not_run" "$reason" "$evidence" "0" "not_run"
    return 0
  fi

  if [[ -n "$DIST_FROM_LOG" ]]; then
    args+=(--from-log "$DIST_FROM_LOG")
  fi
  if [[ -n "$DIST_SUITES_FILE" ]]; then
    args+=(--suites-file "$DIST_SUITES_FILE")
  fi
  args+=(--targets "$DIST_TARGETS")

  if [[ "$MODE" == "dry-run" ]]; then
    {
      printf 'PLAN: bash scripts/tatwo-distributed-run.sh'
      printf ' %q' "${args[@]}"
      printf ' --dry-run\n'
    } | tee "$evidence" >/dev/null
    if [[ -z "$STUB_DIR" ]]; then
      set +e
      bash "$ROOT_DIR/scripts/tatwo-distributed-run.sh" "${args[@]}" --dry-run >>"$evidence" 2>&1
      set -e
    fi
    record_result "$tool" "dry_run" "DRY_RUN: distributed planned" "$evidence" "0" "dry_run"
    return 0
  fi

  if ! ensure_build_lock_if_needed "$tool"; then
    record_result "$tool" "aborted" "${ABORT_REASON:-ABORTED_PRESSURE}" "$evidence" "0" "aborted"
    return 1
  fi

  if [[ -n "$STUB_DIR" && -x "$STUB_DIR/distributed" ]]; then
    start="$(now_epoch)"
    set +e
    output="$("$STUB_DIR/distributed" 2>&1)"
    rc=$?
    set -e
    end="$(now_epoch)"
    printf '%s\n' "$output" >"$evidence"
    duration=$((end - start))
  else
    start="$(now_epoch)"
    set +e
    output="$(
      bash "$ROOT_DIR/scripts/tatwo-distributed-run.sh" "${args[@]}" --execute 2>&1
    )"
    rc=$?
    set -e
    end="$(now_epoch)"
    printf '%s\n' "$output" >"$evidence"
    duration=$((end - start))
  fi

  class_out="$(classify_distributed "$output" "$rc")"
  bucket="$(printf '%s\n' "$class_out" | sed -n '1p')"
  status="$(printf '%s\n' "$class_out" | sed -n '2p')"
  conclusion="$(printf '%s\n' "$class_out" | sed -n '3p')"
  record_result "$tool" "$status" "$conclusion" "$evidence" "$duration" "$bucket"
}

run_all_tools() {
  run_tool_code_health
  [[ -z "$OVERALL" || "$OVERALL" != ABORTED_PRESSURE ]] || return 0
  run_tool_doc_project
  [[ -z "$OVERALL" || "$OVERALL" != ABORTED_PRESSURE ]] || return 0
  run_tool_test_run || true
  [[ -z "$OVERALL" || "$OVERALL" != ABORTED_PRESSURE ]] || return 0
  run_tool_memory_stress || true
  [[ -z "$OVERALL" || "$OVERALL" != ABORTED_PRESSURE ]] || return 0
  run_tool_lint_lane
  [[ -z "$OVERALL" || "$OVERALL" != ABORTED_PRESSURE ]] || return 0
  run_tool_distributed || true
}

export_result_env() {
  export HC_RUN_ID="$RUN_ID"
  export HC_PROFILE="$PROFILE"
  export HC_MODE="$MODE"
  export HC_STARTED="$STARTED_AT"
  export HC_FINISHED="$(utc_iso)"
  export HC_OVERALL="$OVERALL"
  export HC_ABORT="${ABORT_REASON:-}"
  export HC_HOST_LOCK="$HOST_LOCK_DIR"
  export HC_LOCK_COUNT="$LOCK_ACQUIRE_COUNT"
  export HC_LOCK_HELD="$LOCK_HELD"
  export HC_R_TOOLS="$(join_rs "${RESULT_TOOLS[@]+"${RESULT_TOOLS[@]}"}")"
  export HC_R_STATUS="$(join_rs "${RESULT_STATUS[@]+"${RESULT_STATUS[@]}"}")"
  export HC_R_CONCL="$(join_rs "${RESULT_CONCLUSION[@]+"${RESULT_CONCLUSION[@]}"}")"
  export HC_R_EVID="$(join_rs "${RESULT_EVIDENCE[@]+"${RESULT_EVIDENCE[@]}"}")"
  export HC_R_DUR="$(join_rs "${RESULT_DURATION[@]+"${RESULT_DURATION[@]}"}")"
  export HC_R_BUCKET="$(join_rs "${RESULT_BUCKET[@]+"${RESULT_BUCKET[@]}"}")"
  export HC_CAVEATS="$(join_rs "${CAVEAT_REASONS[@]+"${CAVEAT_REASONS[@]}"}")"
  export HC_FAILS="$(join_rs "${FAIL_ITEMS[@]+"${FAIL_ITEMS[@]}"}")"
  export HC_NOT_RUNS="$(join_rs "${NOT_RUN_ITEMS[@]+"${NOT_RUN_ITEMS[@]}"}")"
}

cleanup() {
  release_host_lock
  if [[ -n "$NESTED_LOCK_DIR" ]]; then
    # Nested lock may remain if a child crashed mid-hold; best-effort remove.
    # Never touch HOST_LOCK_DIR here.
    if [[ -d "$NESTED_LOCK_DIR" ]]; then
      rm -rf "$NESTED_LOCK_DIR" 2>/dev/null || true
    fi
    # Also drop common stale aside paths from this run prefix.
    rm -rf "${NESTED_LOCK_DIR}".stale.* 2>/dev/null || true
  fi
}

# --- selftest ---

run_selftest() {
  local st_root st_lock st_out fail=0
  st_root="$(mktemp -d "${TMPDIR:-/tmp}/tatwo-health-selftest.XXXXXX")"
  st_lock="$st_root/host-build.lock"
  # shellcheck disable=SC2064
  trap "rm -rf '$st_root'" EXIT

  printf 'selftest: root=%s\n' "$st_root"

  make_stub() {
    local name="$1" body="$2"
    local path="$st_root/stubs/$name"
    mkdir -p "$st_root/stubs"
    cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# Optional: touch lock acquire counter if STUB_LOCK_HELPER set
if [[ -n "\${STUB_TAKE_LOCK:-}" && -n "\${TATWO_BUILD_LOCK_DIR:-}" ]]; then
  # Simulate child lock acquire on nested dir (orchestrator holds host lock).
  mkdir -p "\${TATWO_BUILD_LOCK_DIR}"
  echo "stub-child-lock-ok" >"\${TATWO_BUILD_LOCK_DIR}/stub-child.marker"
fi
$body
EOF
    chmod +x "$path"
  }

  run_case() {
    local label="$1"
    local expected="$2"
    shift 2
    local out_json="$st_root/${label}.json"
    local output status overall lock_count
    set +e
    output="$(
      TATWO_BUILD_LOCK_DIR="$st_lock" \
      TATWO_HEALTH_STUB_DIR="$st_root/stubs" \
      TATWO_HEALTH_FORCE_PRESSURE_FREE="80" \
        bash "$SCRIPT_PATH" "$@" --out "$out_json" 2>&1
    )"
    status=$?
    set -e
    printf 'selftest: [%s] exit=%s\n' "$label" "$status"
    printf '%s\n' "$output" | sed -n '1,80p'

    overall="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("overall",""))' "$out_json")"
    lock_count="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("hostLock",{}).get("acquireCount",-1))' "$out_json")"
    printf 'selftest: [%s] overall=%s lockAcq=%s\n' "$label" "$overall" "$lock_count"

    if [[ "$overall" != "$expected" ]]; then
      printf 'selftest: FAIL %s expected overall=%s got=%s\n' "$label" "$expected" "$overall" >&2
      return 1
    fi
    # Host lock directory must not remain held after run.
    if [[ -d "$st_lock" ]]; then
      printf 'selftest: FAIL %s left host lock held: %s\n' "$label" "$st_lock" >&2
      return 1
    fi
    return 0
  }

  # --- Case PASS: quick profile, both stubs green ---
  make_stub code-health 'echo "findings: 0"; echo "  critical: 0"; echo "  high: 0"; echo "  medium: 0"; echo "  low: 0"; exit 0'
  make_stub doc-project 'echo "STATS  inSync=3 stale=0 tampered=0 missing_source=0"; echo "CONCLUSION: VERIFY_OK"; exit 0'
  run_case "pass" "PASS" \
    --profile quick --execute \
    --doc-sources "os.md:$st_root/os.md" --doc-verify-dir "$st_root/proj" \
    || fail=1

  # --- Case PASS_WITH_CAVEATS: medium findings + VERIFY stale ---
  make_stub code-health 'echo "findings: 2"; echo "  critical: 0"; echo "  high: 0"; echo "  medium: 2"; echo "  low: 0"; exit 0'
  make_stub doc-project 'echo "STATS  inSync=1 stale=2 tampered=0 missing_source=0"; echo "CONCLUSION: VERIFY_OK"; exit 0'
  run_case "caveats" "PASS_WITH_CAVEATS" \
    --profile quick --execute \
    --doc-sources "os.md:$st_root/os.md" --doc-verify-dir "$st_root/proj" \
    || fail=1

  # --- Case FAIL: code-health critical findings ---
  make_stub code-health 'echo "findings: 1"; echo "  critical: 1"; echo "  high: 0"; echo "  medium: 0"; echo "  low: 0"; exit 0'
  make_stub doc-project 'echo "STATS  inSync=3 stale=0 tampered=0 missing_source=0"; echo "CONCLUSION: VERIFY_OK"; exit 0'
  run_case "fail" "FAIL" \
    --profile quick --execute \
    --doc-sources "os.md:$st_root/os.md" --doc-verify-dir "$st_root/proj" \
    || fail=1

  # --- Case NOT_RUN not counted as pass: standard without doc params; code-health green ---
  # Expect PASS_WITH_CAVEATS because doc-project is NOT_RUN (and test-run stub green under lock).
  make_stub code-health 'echo "findings: 0"; echo "  critical: 0"; echo "  high: 0"; echo "  medium: 0"; echo "  low: 0"; exit 0'
  make_stub test-run 'echo "PASS"; echo "passed_suites: 185"; echo "failed_suites: 0"; exit 0'
  # Do not create doc-project stub; orchestrator should NOT_RUN before invoking.
  rm -f "$st_root/stubs/doc-project"
  run_case "not_run" "PASS_WITH_CAVEATS" \
    --profile standard --execute \
    || fail=1
  # Explicit: report must contain NOT_RUN for doc-project and must not claim PASS.
  python3 - "$st_root/not_run.json" <<'PY' || fail=1
import json,sys
o=json.load(open(sys.argv[1]))
assert o["overall"]=="PASS_WITH_CAVEATS", o["overall"]
docs=[i for i in o["items"] if i["tool"]=="doc-project"]
assert docs and docs[0]["status"]=="not_run", docs
assert "NOT_RUN" in docs[0]["conclusion"], docs[0]
# NOT_RUN must appear in notRunItems / caveatReasons
assert any("doc-project" in x for x in o["aggregation"]["notRunItems"]), o["aggregation"]
print("selftest: [not_run] NOT_RUN preserved and not treated as pass")
PY

  # --- Lock once: standard with two build tools (test-run + distributed stub) under full ---
  make_stub code-health 'echo "findings: 0"; echo "  critical: 0"; echo "  high: 0"; echo "  medium: 0"; echo "  low: 0"; exit 0'
  make_stub doc-project 'echo "STATS  inSync=3 stale=0 tampered=0 missing_source=0"; echo "CONCLUSION: VERIFY_OK"; exit 0'
  make_stub test-run 'export STUB_TAKE_LOCK=1; echo "PASS"; exit 0'
  cat >"$st_root/stubs/memory-stress" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
out=""
args=("$@")
i=0
while [[ $i -lt ${#args[@]} ]]; do
  if [[ "${args[$i]}" == "--out" ]]; then
    out="${args[$((i+1))]}"
  fi
  i=$((i + 1))
done
[[ -n "$out" ]] || out="/tmp/tatwo-mem-stub.json"
python3 -c 'import json,sys; json.dump({"result":{"classification":"STABLE","conclusion":"STABLE: selftest stub"}}, open(sys.argv[1],"w"))' "$out"
echo "STABLE: selftest stub"
exit 0
STUB
  chmod +x "$st_root/stubs/memory-stress"
  make_stub lint-lane 'echo "CONCLUSION: LINT_CLEAN"; exit 0'
  make_stub distributed 'export STUB_TAKE_LOCK=1; echo "CONCLUSION: PASS: all shards failed=0, no skips, toolchain consistent, partition complete"; exit 0'

  set +e
  output="$(
    TATWO_BUILD_LOCK_DIR="$st_lock" \
    TATWO_HEALTH_STUB_DIR="$st_root/stubs" \
    TATWO_HEALTH_FORCE_PRESSURE_FREE="80" \
      bash "$SCRIPT_PATH" \
        --profile full --execute \
        --doc-sources "os.md:$st_root/os.md" --doc-verify-dir "$st_root/proj" \
        --lint-target 'ssh:user@host:/tmp/wt' --lint-rev 'abc123' \
        --dist-targets 'local' --dist-from-log "$st_root/suite.log" \
        --out "$st_root/lockonce.json" 2>&1
  )"
  status=$?
  set -e
  printf 'selftest: [lock_once] exit=%s\n' "$status"
  printf '%s\n' "$output" | sed -n '1,100p'
  lock_count="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("hostLock",{}).get("acquireCount",-1))' "$st_root/lockonce.json")"
  overall="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("overall",""))' "$st_root/lockonce.json")"
  printf 'selftest: [lock_once] overall=%s lockAcq=%s\n' "$overall" "$lock_count"
  if [[ "$lock_count" != "1" ]]; then
    printf 'selftest: FAIL lock_once expected acquireCount=1 got %s\n' "$lock_count" >&2
    fail=1
  fi
  if [[ -d "$st_lock" ]]; then
    printf 'selftest: FAIL lock_once left host lock held\n' >&2
    fail=1
  fi
  if [[ "$overall" != "PASS" ]]; then
    printf 'selftest: FAIL lock_once expected PASS got %s\n' "$overall" >&2
    fail=1
  else
    printf 'selftest: [lock_once] PASS (host lock acquired exactly once)\n'
  fi

  # --- ABORTED_PRESSURE path (optional check) ---
  make_stub code-health 'echo "findings: 0"; echo "  critical: 0"; echo "  high: 0"; exit 0'
  make_stub test-run 'echo "PASS"; exit 0'
  set +e
  output="$(
    TATWO_BUILD_LOCK_DIR="$st_lock" \
    TATWO_HEALTH_STUB_DIR="$st_root/stubs" \
    TATWO_HEALTH_FORCE_PRESSURE_FREE="5" \
      bash "$SCRIPT_PATH" \
        --profile standard --execute \
        --doc-sources "os.md:$st_root/os.md" --doc-verify-dir "$st_root/proj" \
        --out "$st_root/pressure.json" 2>&1
  )"
  set -e
  overall="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("overall",""))' "$st_root/pressure.json")"
  printf 'selftest: [pressure] overall=%s\n' "$overall"
  if [[ "$overall" != "ABORTED_PRESSURE" ]]; then
    printf 'selftest: FAIL pressure expected ABORTED_PRESSURE got %s\n' "$overall" >&2
    fail=1
  else
    printf 'selftest: [pressure] PASS\n'
  fi

  if [[ "$fail" -ne 0 ]]; then
    printf 'SELFTEST FAIL\n' >&2
    exit 1
  fi
  printf 'SELFTEST PASS\n'
  printf 'covered: PASS / PASS_WITH_CAVEATS / FAIL / NOT_RUN-not-pass / lock-once / ABORTED_PRESSURE\n'
  exit 0
}

if [[ "$SELFTEST" -eq 1 ]]; then
  run_selftest
fi

# --- main ---

trap cleanup EXIT
RUN_ID="health-$(utc_stamp)-$$"
STARTED_AT="$(utc_iso)"
EVIDENCE_ROOT="${TMPDIR:-/tmp}/tatwo-health-check/${RUN_ID}"
mkdir -p "$EVIDENCE_ROOT"
log "runId=$RUN_ID profile=$PROFILE mode=$MODE evidence=$EVIDENCE_ROOT"

# Pre-flight pressure for execute mode (soft for non-build tools; hard before lock).
if [[ "$MODE" == "execute" ]]; then
  if ! check_pressure_or_abort; then
    # No tools run; record abort.
    record_result "orchestrator" "aborted" "$ABORT_REASON" "" "0" "aborted"
    finalize_overall
    export_result_env
    build_and_write_report "${OUT_PATH:-}"
    print_human_summary
    exit 3
  fi
fi

run_all_tools
finalize_overall
export_result_env
build_and_write_report "${OUT_PATH:-}"
print_human_summary

case "$OVERALL" in
  PASS) exit 0 ;;
  PASS_WITH_CAVEATS) exit 0 ;;
  DRY_RUN) exit 0 ;;
  FAIL) exit 1 ;;
  ABORTED_PRESSURE) exit 3 ;;
  *) exit 1 ;;
esac
