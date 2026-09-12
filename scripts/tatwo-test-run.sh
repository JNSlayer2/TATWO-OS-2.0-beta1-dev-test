#!/usr/bin/env bash
# tatwo-test-run.sh — 全量測試與觀測驗證的標準入口
#
# Production 一律走內建：
#   swift test -j 2 > "$LOG" 2>&1
#
# TATWO_TEST_CMD 僅供 selftest／受控 fixture 覆寫實際命令；觀測規則不變。
# Override 以 bash -o pipefail -o errexit -c 執行，避免 pipeline 假 PASS。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

MIN_LOG_BYTES=200000
EXPECTED_SUITES="${TATWO_EXPECTED_SUITES_MIN:-150}"
# Seconds to wait after forwarding INT/TERM before escalating to KILL.
SIGNAL_WAIT_SECS="${TATWO_SIGNAL_WAIT_SECS:-10}"
if ! [[ "$EXPECTED_SUITES" =~ ^[0-9]+$ ]]; then
  printf 'FAIL\nfailure: TATWO_EXPECTED_SUITES_MIN must be a non-negative integer (got %s)\nlog: %s\n' \
    "$EXPECTED_SUITES" "${TATWO_LOG:-/tmp/tatwo-suite-unknown.log}"
  exit 1
fi
if ! [[ "$SIGNAL_WAIT_SECS" =~ ^[0-9]+$ ]] || (( SIGNAL_WAIT_SECS < 1 )); then
  printf 'FAIL\nfailure: TATWO_SIGNAL_WAIT_SECS must be a positive integer (got %s)\nlog: %s\n' \
    "$SIGNAL_WAIT_SECS" "${TATWO_LOG:-/tmp/tatwo-suite-unknown.log}"
  exit 1
fi

utc_stamp() {
  date -u +"%Y%m%dT%H%M%SZ"
}

usage() {
  cat <<'EOF'
用法：
  bash scripts/tatwo-test-run.sh
  bash scripts/tatwo-test-run.sh --selftest

環境變數：
  TATWO_LOG                  覆寫 log 路徑（預設 /tmp/tatwo-suite-<UTC時間戳>.log）
  TATWO_TEST_CMD             僅供 selftest／fixture 覆寫命令（production 禁用）
  TATWO_EXPECTED_SUITES_MIN  最低測試套數（預設 150）
  TATWO_SIGNAL_WAIT_SECS     INT/TERM 轉送後等待秒數再升級 KILL（預設 10）
  TATWO_BUILD_LOCK_DIR       fallback／build-lock helper 共用鎖路徑

Production 一律走內建 swift test 路徑。TATWO_TEST_CMD 不得作為正式總驗收入口。
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "${1:-}" == "--selftest" ]]; then
  if [[ $# -ne 1 ]]; then
    printf 'selftest: unknown argument: %s\n' "${2:-}" >&2
    exit 2
  fi

  SELFTEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tatwo-test-run-selftest.XXXXXX")"
  SELFTEST_LOCK="$SELFTEST_ROOT/tatwo-build.lock"
  GREEN_LOG="$SELFTEST_ROOT/green.log"
  FAIL_LOG="$SELFTEST_ROOT/fail.log"
  TRUNCATED_LOG="$SELFTEST_ROOT/truncated.log"
  PIPEFAIL_LOG="$SELFTEST_ROOT/pipefail.log"
  SKIP_LOG="$SELFTEST_ROOT/skip.log"
  SKIP_FAIL_LOG="$SELFTEST_ROOT/skip-fail.log"
  TERM_LOG="$SELFTEST_ROOT/term.log"
  KILL_LOG="$SELFTEST_ROOT/kill.log"
  TERM_CHILD_PID_FILE="$SELFTEST_ROOT/term-child.pid"
  KILL_CHILD_PID_FILE="$SELFTEST_ROOT/kill-child.pid"

  # 每個 stub 都產出足夠大的完整 log；只有 truncated case 應觸發觀測可疑。
  # Suite lines must match the anchored XCTest summary form: "^Test Suite .* (passed|failed) at"
  GREEN_CMD='{ printf "%210000s" "" | tr " " "x"; printf "\n"; for i in $(seq 1 185); do printf "Test Suite '\''suite_%03d'\'' passed at 2026-01-01 00:00:00.000.\n" "$i"; done; } >&2'
  FAIL_CMD='{ printf "%210000s" "" | tr " " "x"; printf "\n"; for i in $(seq 1 184); do printf "Test Suite '\''suite_%03d'\'' passed at 2026-01-01 00:00:00.000.\n" "$i"; done; printf "Test Suite '\''suite_fail'\'' failed at 2026-01-01 00:00:00.000.\n"; printf "error: selftest stub failure\n"; } >&2; exit 1'
  TRUNCATED_CMD='printf "truncated stub\n" >&2'
  # B3 反證：false|true 在無 pipefail 時假 PASS；有 pipefail+errexit 必須 FAIL。
  # 先寫足量 log 再踩 pipeline，確保結論是 FAIL（exit 1）而非 OBSERVATION_SUSPECT。
  PIPEFAIL_CMD='{ printf "%210000s" "" | tr " " "x"; printf "\n"; for i in $(seq 1 185); do printf "Test Suite '\''suite_%03d'\'' passed at 2026-01-01 00:00:00.000.\n" "$i"; done; } >&2; false | true'
  # XCTest reports a skipped test inside an otherwise "passed" suite. The
  # runner must expose the skip and must not count that suite as passed.
  SKIP_CMD='{ printf "%210000s" "" | tr " " "x"; printf "\n"; for i in $(seq 1 184); do printf "Test Suite '\''suite_%03d'\'' passed at 2026-01-01 00:00:00.000.\n" "$i"; done; printf "Test Case '\''-[TatwoUltraworkCoreTests.KeychainCapabilityTests testOne]'\'' skipped (0.001 seconds).\n"; printf "Test Case '\''-[TatwoUltraworkCoreTests.KeychainCapabilityTests testTwo]'\'' skipped (0.001 seconds).\n"; printf "Test Suite '\''KeychainCapabilityTests'\'' passed at 2026-01-01 00:00:00.000.\n"; } >&2'
  SKIP_FAIL_CMD='{ printf "%210000s" "" | tr " " "x"; printf "\n"; for i in $(seq 1 184); do printf "Test Suite '\''suite_%03d'\'' passed at 2026-01-01 00:00:00.000.\n" "$i"; done; printf "Test Case '\''-[TatwoUltraworkCoreTests.KeychainCapabilityTests testOne]'\'' skipped (0.001 seconds).\n"; printf "Test Suite '\''KeychainCapabilityTests'\'' passed at 2026-01-01 00:00:00.000.\n"; printf "Test Suite '\''suite_fail'\'' failed at 2026-01-01 00:00:00.000.\n"; } >&2; exit 1'
  # 長跑 stub：寫出自身 PID 後睡眠，供 TERM 轉送驗證。
  TERM_CMD="printf '%s\n' \"\$\$\" > \"$TERM_CHILD_PID_FILE\"; sleep 120"
  # 忽略 TERM 的 stub：應在限時後被 KILL 升級收斂。
  KILL_CMD="printf '%s\n' \"\$\$\" > \"$KILL_CHILD_PID_FILE\"; trap '' TERM; while true; do sleep 1; done"

  selftest_case() {
    local label="$1"
    local command="$2"
    local log="$3"
    local expected_conclusion="$4"
    local expected_exit="$5"
    local expected_fragment="${6:-}"
    local output status

    set +e
    output="$(
      TATWO_TEST_CMD="$command" \
      TATWO_LOG="$log" \
      TATWO_BUILD_LOCK_DIR="$SELFTEST_LOCK" \
      "$SCRIPT_PATH" 2>&1
    )"
    status=$?
    set -e

    printf 'selftest: [%s] exit=%s\n' "$label" "$status"
    printf '%s\n' "$output"

    if ! grep -Fqx "$expected_conclusion" <<<"$output"; then
      printf 'selftest: expected conclusion %s for %s\n' \
        "$expected_conclusion" "$label" >&2
      return 1
    fi
    if [[ "$status" -ne "$expected_exit" ]]; then
      printf 'selftest: expected exit %s for %s (got %s)\n' \
        "$expected_exit" "$label" "$status" >&2
      return 1
    fi
    if [[ -n "$expected_fragment" ]] && ! grep -Fq "$expected_fragment" <<<"$output"; then
      printf 'selftest: expected fragment %s for %s\n' \
        "$expected_fragment" "$label" >&2
      return 1
    fi
  }

  # TERM／KILL 收斂：背景啟動 wrapper，送信號，驗證限時內退出且 stub 已死。
  selftest_signal_case() {
    local label="$1"
    local command="$2"
    local log="$3"
    local child_pid_file="$4"
    local expected_exit="$5"
    local max_secs="$6"
    local wait_secs="$7"
    local wrapper_pid status elapsed start_ts end_ts child_pid
    local output_file="$SELFTEST_ROOT/${label// /_}.out"

    rm -f "$child_pid_file" "$log" "$output_file"
    # Background the wrapper itself (not a parent subshell) so TERM hits its traps.
    set +e
    TATWO_TEST_CMD="$command" \
    TATWO_LOG="$log" \
    TATWO_BUILD_LOCK_DIR="$SELFTEST_LOCK" \
    TATWO_SIGNAL_WAIT_SECS="$wait_secs" \
      "$SCRIPT_PATH" >"$output_file" 2>&1 &
    wrapper_pid=$!
    set -e

    # 等 stub 寫出 PID（或 wrapper 先結束）。
    start_ts="$(date +%s)"
    child_pid=""
    while true; do
      if [[ -f "$child_pid_file" ]]; then
        child_pid="$(tr -d '[:space:]' <"$child_pid_file" || true)"
        if [[ "$child_pid" =~ ^[0-9]+$ ]]; then
          break
        fi
      fi
      if ! kill -0 "$wrapper_pid" 2>/dev/null; then
        break
      fi
      if (( $(date +%s) - start_ts > 5 )); then
        break
      fi
      sleep 0.1
    done

    if [[ -z "$child_pid" || ! "$child_pid" =~ ^[0-9]+$ ]]; then
      printf 'selftest: [%s] stub did not publish pid\n' "$label" >&2
      kill -TERM "$wrapper_pid" 2>/dev/null || true
      wait "$wrapper_pid" 2>/dev/null || true
      return 1
    fi

    if ! kill -0 "$child_pid" 2>/dev/null; then
      printf 'selftest: [%s] stub pid %s not alive before signal\n' "$label" "$child_pid" >&2
      kill -TERM "$wrapper_pid" 2>/dev/null || true
      wait "$wrapper_pid" 2>/dev/null || true
      return 1
    fi

    start_ts="$(date +%s)"
    kill -TERM "$wrapper_pid" 2>/dev/null || true

    set +e
    wait "$wrapper_pid"
    status=$?
    set -e
    end_ts="$(date +%s)"
    elapsed=$((end_ts - start_ts))

    printf 'selftest: [%s] exit=%s elapsed=%ss child_pid=%s\n' \
      "$label" "$status" "$elapsed" "$child_pid"
    if [[ -f "$output_file" ]]; then
      cat "$output_file"
    fi

    if [[ "$status" -ne "$expected_exit" ]]; then
      printf 'selftest: expected exit %s for %s (got %s)\n' \
        "$expected_exit" "$label" "$status" >&2
      return 1
    fi
    if (( elapsed > max_secs )); then
      printf 'selftest: %s took %ss (max %ss)\n' "$label" "$elapsed" "$max_secs" >&2
      return 1
    fi
    if kill -0 "$child_pid" 2>/dev/null; then
      printf 'selftest: %s stub still alive after wrapper exit (pid=%s)\n' \
        "$label" "$child_pid" >&2
      kill -KILL "$child_pid" 2>/dev/null || true
      return 1
    fi
    if [[ -d "$SELFTEST_LOCK" ]]; then
      printf 'selftest: %s left lock held: %s\n' "$label" "$SELFTEST_LOCK" >&2
      return 1
    fi
  }

  printf 'selftest: root=%s\n' "$ROOT_DIR"
  printf 'selftest: lock=%s\n' "$SELFTEST_LOCK"
  printf 'selftest: [1] full green stub\n'
  selftest_case "full green" "$GREEN_CMD" "$GREEN_LOG" "PASS" 0 || exit 1
  printf 'selftest: [2] failing stub\n'
  selftest_case "failing" "$FAIL_CMD" "$FAIL_LOG" "FAIL" 1 || exit 1
  printf 'selftest: [3] truncated stub\n'
  selftest_case "truncated" "$TRUNCATED_CMD" "$TRUNCATED_LOG" "OBSERVATION_SUSPECT" 2 || exit 1
  printf 'selftest: [4] pipeline failure (false|true must FAIL)\n'
  selftest_case "pipeline fail" "$PIPEFAIL_CMD" "$PIPEFAIL_LOG" "FAIL" 1 || exit 1
  printf 'selftest: [5] visible skips are not counted as passed\n'
  selftest_case "visible skips" "$SKIP_CMD" "$SKIP_LOG" "PASS (2 skipped)" 0 \
    $'passed_suites: 184\nfailed_suites: 0\nskipped_suites: 1\nskipped_tests: 2' || exit 1
  printf 'selftest: [6] failure conclusion also exposes skips\n'
  selftest_case "failure with skip" "$SKIP_FAIL_CMD" "$SKIP_FAIL_LOG" \
    "FAIL (1 skipped)" 1 $'skipped_suites: 1\nskipped_tests: 1' || exit 1
  printf 'selftest: [7] TERM forward (stub dies; wrapper exits promptly)\n'
  # Cooperative sleep dies on TERM; allow a few seconds for scheduling.
  selftest_signal_case "term forward" "$TERM_CMD" "$TERM_LOG" \
    "$TERM_CHILD_PID_FILE" 143 5 10 || exit 1
  printf 'selftest: [8] child ignores TERM then KILL escalate\n'
  # wait_secs=2 → escalate quickly; max wall clock ~8s includes fork/acquire.
  selftest_signal_case "kill escalate" "$KILL_CMD" "$KILL_LOG" \
    "$KILL_CHILD_PID_FILE" 143 8 2 || exit 1
  if [[ -d "$SELFTEST_LOCK" ]]; then
    printf 'selftest: lock was not released: %s\n' "$SELFTEST_LOCK" >&2
    exit 1
  fi
  printf 'SELFTEST PASS\n'
  exit 0
fi

if [[ $# -ne 0 ]]; then
  printf 'FAIL\nfailure: unknown argument: %s\nlog: %s\n' \
    "$1" "${TATWO_LOG:-/tmp/tatwo-suite-unknown.log}"
  exit 1
fi

LOG="${TATWO_LOG:-/tmp/tatwo-suite-$(utc_stamp).log}"
export LOG
export TATWO_TEST_LOG="$LOG"

if ! cd "$ROOT_DIR"; then
  printf 'FAIL\nfailure: cannot cd to repository root: %s\nlog: %s\n' \
    "$ROOT_DIR" "$LOG"
  exit 1
fi

LOG_PARENT="$(dirname "$LOG")"
if ! mkdir -p "$LOG_PARENT"; then
  printf 'FAIL\nfailure: cannot create log directory: %s\nlog: %s\n' \
    "$LOG_PARENT" "$LOG"
  exit 1
fi

LOCK_HELPER="$ROOT_DIR/scripts/tatwo-build-lock.sh"
LOCK_MODE=""
LOCK_DIR="${TATWO_BUILD_LOCK_DIR:-/tmp/tatwo-build.lock}"
LOCK_HELD=0
LOCK_TOKEN=""
LOCK_TOKEN_FILE=""
CHILD_PID=""
CHILD_PGID=""

extract_lock_token() {
  # stdin → first token= value (from acquire stdout/stderr capture)
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

release_lock() {
  if [[ "$LOCK_HELD" -ne 1 ]]; then
    return 0
  fi
  if [[ "$LOCK_MODE" == "helper" ]]; then
    # F1 ownership token is required; PID alone is not authorization.
    if [[ -n "$LOCK_TOKEN" ]]; then
      "$LOCK_HELPER" release --token "$LOCK_TOKEN" --pid "$$" >&2 || true
    elif [[ -n "$LOCK_TOKEN_FILE" && -f "$LOCK_TOKEN_FILE" ]]; then
      TATWO_BUILD_LOCK_TOKEN_FILE="$LOCK_TOKEN_FILE" \
        "$LOCK_HELPER" release --pid "$$" >&2 || true
    else
      printf 'warning: lock held but ownership token missing; release skipped\n' >&2
    fi
  else
    # fallback lock is deliberately the existing empty mkdir lock.
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
  LOCK_HELD=0
  LOCK_TOKEN=""
  if [[ -n "$LOCK_TOKEN_FILE" ]]; then
    rm -f "$LOCK_TOKEN_FILE" 2>/dev/null || true
    LOCK_TOKEN_FILE=""
  fi
}

# Order: converge child process group first, then release lock, then exit.
# EXIT trap only releases the lock (child must already be reaped by then).
converge_child() {
  local sig="$1"
  local waited=0
  local pgid pid

  if [[ -z "${CHILD_PID:-}" ]]; then
    return 0
  fi

  pid="$CHILD_PID"
  pgid="${CHILD_PGID:-$CHILD_PID}"

  if kill -0 "$pid" 2>/dev/null; then
    # Negative PID = process group (bash 3.2 / macOS BSD kill; no GNU --).
    kill "-$sig" "-$pgid" 2>/dev/null || kill "-$sig" "$pid" 2>/dev/null || true
  fi

  while kill -0 "$pid" 2>/dev/null && (( waited < SIGNAL_WAIT_SECS )); do
    sleep 1
    waited=$((waited + 1))
  done

  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "-$pgid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  fi

  wait "$pid" 2>/dev/null || true
  CHILD_PID=""
  CHILD_PGID=""
}

on_signal() {
  local sig="$1"
  local code="$2"
  # 1) converge child  2) release lock (via EXIT)  3) exit with 130/143
  converge_child "$sig"
  exit "$code"
}

trap release_lock EXIT
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM

acquire_lock() {
  if [[ -x "$LOCK_HELPER" ]]; then
    LOCK_MODE="helper"
    local acq_out acq_rc tok
    LOCK_TOKEN_FILE="$(mktemp "${TMPDIR:-/tmp}/tatwo-test-run-lock-token.XXXXXX")"
    set +e
    acq_out="$(
      TATWO_BUILD_LOCK_TOKEN_FILE="$LOCK_TOKEN_FILE" \
        "$LOCK_HELPER" acquire --pid "$$" 2>&1
    )"
    acq_rc=$?
    set -u
    # Keep acquire chatter on stderr so stdout conclusions stay clean.
    # Do not echo token= lines (secret ownership token stays in LOCK_TOKEN / token file).
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
      return 1
    fi
    tok=""
    if [[ -f "$LOCK_TOKEN_FILE" ]]; then
      tok="$(tr -d '[:space:]' <"$LOCK_TOKEN_FILE" || true)"
    fi
    if [[ -z "$tok" ]]; then
      tok="$(printf '%s\n' "$acq_out" | extract_lock_token || true)"
    fi
    if [[ -z "$tok" ]]; then
      printf 'FAIL\nfailure: build-lock acquire succeeded without ownership token\nlog: %s\n' \
        "$LOG" >&2
      # Best-effort: do not leave a lock we cannot release.
      rm -f "$LOCK_TOKEN_FILE" 2>/dev/null || true
      LOCK_TOKEN_FILE=""
      return 1
    fi
    LOCK_TOKEN="$tok"
    LOCK_HELD=1
    return 0
  fi

  LOCK_MODE="fallback"
  local attempt
  for attempt in $(seq 1 60); do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      LOCK_HELD=1
      return 0
    fi
    if [[ "$attempt" -lt 60 ]]; then
      sleep 5
    fi
  done
  return 1
}

if ! acquire_lock; then
  printf 'FAIL\nfailure: could not acquire test lock after the permitted wait\nlog: %s\n' \
    "$LOG"
  exit 1
fi

# Keep the redirect order literal and fixed.  Do not move 2>&1 before > "$LOG".
# Launch child in its own process group (job-control monitor mode; bash 3.2 portable).
TEST_STATUS=0
set -m
if [[ "${TATWO_TEST_CMD+x}" == x ]]; then
  # Override is selftest/fixture only. Production must use the swift test branch.
  # pipefail+errexit: pipeline mid-failure (e.g. false|true) cannot fake PASS.
  bash -o pipefail -o errexit -c "$TATWO_TEST_CMD" > "$LOG" 2>&1 &
else
  swift test -j 2 > "$LOG" 2>&1 &
fi
CHILD_PID=$!
CHILD_PGID="$(ps -o pgid= -p "$CHILD_PID" 2>/dev/null | tr -d '[:space:]' || true)"
if [[ -z "$CHILD_PGID" || ! "$CHILD_PGID" =~ ^[0-9]+$ ]]; then
  CHILD_PGID="$CHILD_PID"
fi
set +m

set +e
wait "$CHILD_PID"
TEST_STATUS=$?
set -u
CHILD_PID=""
CHILD_PGID=""

LOG_BYTES=0
if [[ -f "$LOG" ]]; then
  LOG_BYTES="$(wc -c <"$LOG" | tr -d '[:space:]')"
fi
if ! [[ "$LOG_BYTES" =~ ^[0-9]+$ ]]; then
  LOG_BYTES=0
fi

# Anchored XCTest suite oracles (full log only; no tail/head).
# Correct form: "^Test Suite .* passed at" / "^Test Suite .* failed at"
# Old broken form "Test Suite .* passed\|failed" also matched bare "failed"
# substrings in test names/messages and inflated 185 → 233 on a real full log.
RAW_PASSED_SUITE_COUNT=0
if [[ -f "$LOG" ]]; then
  RAW_PASSED_SUITE_COUNT="$(grep -c '^Test Suite .* passed at' "$LOG" 2>/dev/null || true)"
fi
if ! [[ "$RAW_PASSED_SUITE_COUNT" =~ ^[0-9]+$ ]]; then
  RAW_PASSED_SUITE_COUNT=0
fi

# Structured XCTest fail oracle (priority ② after command exit code).
FAILED_SUITE_COUNT=0
if [[ -f "$LOG" ]]; then
  FAILED_SUITE_COUNT="$(grep -c '^Test Suite .* failed at' "$LOG" 2>/dev/null || true)"
fi
if ! [[ "$FAILED_SUITE_COUNT" =~ ^[0-9]+$ ]]; then
  FAILED_SUITE_COUNT=0
fi

# XCTest marks individual test cases as skipped while still printing the
# containing suite as "passed". Derive both visible counters from the anchored
# test-case skip marker, and remove each affected suite from passed_suites.
SKIPPED_TEST_COUNT=0
SKIPPED_SUITE_COUNT=0
SKIP_MARKER_CANDIDATE_COUNT=0
SKIP_PARSE_OK=1
if [[ -f "$LOG" ]]; then
  SKIP_MARKER_CANDIDATE_COUNT="$(
    grep -c "^Test Case .* skipped" "$LOG" 2>/dev/null || true
  )"
  if ! [[ "$SKIP_MARKER_CANDIDATE_COUNT" =~ ^[0-9]+$ ]]; then
    SKIP_MARKER_CANDIDATE_COUNT=0
    SKIP_PARSE_OK=0
  fi
  SKIP_COUNTS="$(
    python3 - "$LOG" <<'PY'
import re
import sys

path = sys.argv[1]
tests = 0
suites = set()
pattern = re.compile(r"^Test Case '(.+)' skipped \([^)]* seconds\)\.$")
with open(path, "r", encoding="utf-8", errors="replace") as handle:
    for raw in handle:
        match = pattern.match(raw.rstrip("\n"))
        if not match:
            continue
        tests += 1
        identifier = match.group(1)
        legacy = re.match(r"-\[([^\s]+)\s+[^\]]+\]$", identifier)
        if legacy:
            suites.add(legacy.group(1).rsplit(".", 1)[-1])
        elif "." in identifier:
            suites.add(identifier.rsplit(".", 1)[0].rsplit(".", 1)[-1])
        else:
            suites.add(identifier)
print(f"{len(suites)} {tests}")
PY
  )" || SKIP_PARSE_OK=0
  if [[ "$SKIP_PARSE_OK" -eq 1 && "$SKIP_COUNTS" =~ ^[0-9]+[[:space:]][0-9]+$ ]]; then
    SKIPPED_SUITE_COUNT="${SKIP_COUNTS%% *}"
    SKIPPED_TEST_COUNT="${SKIP_COUNTS##* }"
  else
    SKIP_PARSE_OK=0
    SKIPPED_SUITE_COUNT=0
    SKIPPED_TEST_COUNT=0
  fi
  if (( SKIPPED_TEST_COUNT != SKIP_MARKER_CANDIDATE_COUNT )); then
    SKIP_PARSE_OK=0
  fi
fi

PASSED_SUITE_COUNT=$((RAW_PASSED_SUITE_COUNT - SKIPPED_SUITE_COUNT))
if (( PASSED_SUITE_COUNT < 0 )); then
  PASSED_SUITE_COUNT=0
  SKIP_PARSE_OK=0
fi

# Backward-compatible alias: suite_count means anchored non-skipped passed suites only.
SUITE_COUNT="$PASSED_SUITE_COUNT"

# Full-file failed|error extraction is diagnostic only — never alone decides FAIL.
DIAGNOSTIC_LINES=""
if [[ -f "$LOG" ]]; then
  DIAGNOSTIC_LINES="$(grep -Ein 'failed|error' "$LOG" 2>/dev/null || true)"
fi

OBSERVATION_REASONS=()
if [[ ! -f "$LOG" ]]; then
  OBSERVATION_REASONS+=("log file is missing")
elif (( LOG_BYTES < MIN_LOG_BYTES )); then
  OBSERVATION_REASONS+=("log bytes ${LOG_BYTES} < ${MIN_LOG_BYTES}")
fi
if (( RAW_PASSED_SUITE_COUNT < EXPECTED_SUITES )); then
  OBSERVATION_REASONS+=(
    "observed passed-suite summaries ${RAW_PASSED_SUITE_COUNT} < expected minimum ${EXPECTED_SUITES}"
  )
fi
if (( SKIP_PARSE_OK == 0 )); then
  OBSERVATION_REASONS+=("XCTest skip markers could not be parsed reliably")
fi

# K4 / D10 S1: every conclusion carries a toolchain fingerprint line so
# same-commit dual-machine diffs can be read as environment vs code failure.
# Does not affect observation gates or pass/fail oracles.
emit_toolchain_line() {
  local fp_script="$ROOT_DIR/scripts/tatwo-toolchain-fingerprint.sh"
  local json swift host
  if [[ ! -f "$fp_script" ]]; then
    printf 'toolchain: unknown@unknown\n'
    return 0
  fi
  json="$(bash "$fp_script" 2>/dev/null || true)"
  if [[ -z "$json" ]]; then
    printf 'toolchain: unknown@unknown\n'
    return 0
  fi
  swift="$(
    printf '%s' "$json" | python3 -c '
import json,sys
try:
    o=json.load(sys.stdin)
    print((o.get("swiftVersion") or "unknown").strip() or "unknown")
except Exception:
    print("unknown")
' 2>/dev/null || echo unknown
  )"
  host="$(
    printf '%s' "$json" | python3 -c '
import json,sys
try:
    o=json.load(sys.stdin)
    print((o.get("hostName") or "unknown").strip() or "unknown")
except Exception:
    print("unknown")
' 2>/dev/null || echo unknown
  )"
  printf 'toolchain: %s@%s\n' "$swift" "$host"
}

if (( ${#OBSERVATION_REASONS[@]} > 0 )); then
  if (( SKIPPED_TEST_COUNT > 0 )); then
    printf 'OBSERVATION_SUSPECT (%s skipped)\n' "$SKIPPED_TEST_COUNT"
  else
    printf 'OBSERVATION_SUSPECT\n'
  fi
  printf 'log_bytes: %s\npassed_suites: %s\nfailed_suites: %s\nskipped_suites: %s\nskipped_tests: %s\nsuite_count: %s\n' \
    "$LOG_BYTES" "$PASSED_SUITE_COUNT" "$FAILED_SUITE_COUNT" \
    "$SKIPPED_SUITE_COUNT" "$SKIPPED_TEST_COUNT" "$SUITE_COUNT"
  printf 'reason: %s\n' "${OBSERVATION_REASONS[@]}"
  if [[ -n "$DIAGNOSTIC_LINES" ]]; then
    printf 'diagnostic failed/error lines (not sole fail oracle):\n%s\n' "$DIAGNOSTIC_LINES"
  fi
  printf 'log: %s\n' "$LOG"
  emit_toolchain_line
  exit 2
fi

# Final conclusion priority:
#   ① command exit code
#   ② XCTest structured summary (anchored failed-suite count)
#   ③ log size / passed-suite gates (already handled as OBSERVATION_SUSPECT)
# Full-text error grep is diagnostic only and does not alone force FAIL.
if (( TEST_STATUS != 0 )) || (( FAILED_SUITE_COUNT > 0 )); then
  if (( SKIPPED_TEST_COUNT > 0 )); then
    printf 'FAIL (%s skipped)\n' "$SKIPPED_TEST_COUNT"
  else
    printf 'FAIL\n'
  fi
  printf 'log_bytes: %s\npassed_suites: %s\nfailed_suites: %s\nskipped_suites: %s\nskipped_tests: %s\nsuite_count: %s\n' \
    "$LOG_BYTES" "$PASSED_SUITE_COUNT" "$FAILED_SUITE_COUNT" \
    "$SKIPPED_SUITE_COUNT" "$SKIPPED_TEST_COUNT" "$SUITE_COUNT"
  if (( TEST_STATUS != 0 )); then
    printf 'failure: test command exit status %s\n' "$TEST_STATUS"
  fi
  if (( FAILED_SUITE_COUNT > 0 )); then
    printf 'failure: XCTest failed suite count %s\n' "$FAILED_SUITE_COUNT"
  fi
  if [[ -n "$DIAGNOSTIC_LINES" ]]; then
    printf 'diagnostic failed/error lines (not sole fail oracle):\n%s\n' "$DIAGNOSTIC_LINES"
  elif (( TEST_STATUS != 0 )); then
    printf 'failure: command failed without a failed/error line in the captured log\n'
  fi
  printf 'log: %s\n' "$LOG"
  emit_toolchain_line
  exit 1
fi

if (( SKIPPED_TEST_COUNT > 0 )); then
  printf 'PASS (%s skipped)\n' "$SKIPPED_TEST_COUNT"
else
  printf 'PASS\n'
fi
printf 'log_bytes: %s\npassed_suites: %s\nfailed_suites: %s\nskipped_suites: %s\nskipped_tests: %s\nsuite_count: %s\n' \
  "$LOG_BYTES" "$PASSED_SUITE_COUNT" "$FAILED_SUITE_COUNT" \
  "$SKIPPED_SUITE_COUNT" "$SKIPPED_TEST_COUNT" "$SUITE_COUNT"
printf 'log: %s\n' "$LOG"
emit_toolchain_line
exit 0
