#!/usr/bin/env bash
# tatwo-distributed-run.sh — 跨機分散式測試一鍵腳本（固化 T1 實證流程）
#
# 鐵律：
#   - 預設 --dry-run（只印計畫，不 scp／SSH／swift test）
#   - 主機／使用者／路徑全走參數；腳本內無硬編目標
#   - 本機分片必須經 tatwo-build-lock 取放；不得繞過
#   - 禁 git 寫入；SSH 僅在 --execute 且參數指定時使用（LAN）
#
# 用法：
#   bash scripts/tatwo-distributed-run.sh \
#     --from-log <suite.log> \
#     --targets 'local,ssh:<user>@<host>:<worktree>' \
#     [--shards N] [--dry-run|--execute] [--require-matching-toolchain]
#   bash scripts/tatwo-distributed-run.sh --selftest
#
# Toolchain policy (docs/protocol/TOOLCHAIN_DIVERGENCE_POLICY.md):
#   default = accept-and-label (DEGRADED on fingerprint mismatch)
#   --require-matching-toolchain = strict (mismatch → overall FAIL)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

SHARD_HELPER="$ROOT_DIR/scripts/tatwo-test-shard.mjs"
LOCK_HELPER="$ROOT_DIR/scripts/tatwo-build-lock.sh"
FP_HELPER="$ROOT_DIR/scripts/tatwo-toolchain-fingerprint.sh"

FROM_LOG=""
SUITES_FILE=""
TARGETS_RAW=()
SHARDS=""
DRY_RUN=1
SELFTEST=0
EXECUTE=0
REQUIRE_MATCHING_TOOLCHAIN=0
POLL_INTERVAL="${TATWO_DIST_POLL_INTERVAL:-5}"
POLL_TIMEOUT="${TATWO_DIST_POLL_TIMEOUT:-7200}"
SWIFT_JOBS="${TATWO_DIST_SWIFT_JOBS:-2}"
RECEIPT_DIR="${TATWO_DIST_RECEIPT_DIR:-$ROOT_DIR/receipts/distributed-runs}"
WORK_ROOT=""
RUN_ID=""
MODE="dry-run"

# Injected executors (selftest / fixtures only). Production leaves unset.
SSH_CMD="${TATWO_DIST_SSH_CMD:-ssh}"
SCP_CMD="${TATWO_DIST_SCP_CMD:-scp}"
STUB_MODE="${TATWO_DIST_STUB_MODE:-0}"
STUB_RESULT_DIR="${TATWO_DIST_STUB_RESULT_DIR:-}"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/tatwo-distributed-run.sh \
    (--from-log <suite.log> | --suites-file <file>) \
    --targets <spec[,spec...]> \
    [--shards N] [--dry-run | --execute] \
    [--require-matching-toolchain] \
    [--poll-interval SEC] [--poll-timeout SEC] [--receipt-dir DIR]

  bash scripts/tatwo-distributed-run.sh --selftest

Targets (repeatable --targets or comma-separated):
  local
  ssh:<user>@<host>:<worktree path>     # 範例 only in docs; no hard-coded hosts

Defaults:
  --dry-run     ON (plan only; no scp/SSH/swift)
  --shards      equals number of targets
  toolchain     accept-and-label (mismatch → DEGRADED; does NOT change without flag)

Toolchain policy (see docs/protocol/TOOLCHAIN_DIVERGENCE_POLICY.md):
  (default)                      accept-and-label: fingerprint mismatch → DEGRADED
  --require-matching-toolchain   strict: any shard fingerprint mismatch → overall FAIL

Flow:
  1) tatwo-test-shard.mjs 分片 + --verify-partition（聯集=全集、無重複；失敗即中止）
  2) local: build-lock token → swift test -j N --filter...
     ssh: scp filter 清單 → nohup + PATH 修正 → log 內 RC= 完成訊號
  3) 輪詢收集；解析 passed/failed/skipped + toolchain fingerprint
  4) 結論：任 failed>0|缺分片|partition 不完整 → FAIL
            全 0 failed 但有 skip → PASS_WITH_SKIPS（列能力名）
            toolchain 不一致 → 預設附加 DEGRADED；strict 則 FAIL
  5) 寫入 receipts/distributed-runs/<timestamp>.json

Environment (fixture / selftest only):
  TATWO_DIST_STUB_MODE=1          inject stub executor (no real SSH)
  TATWO_DIST_SSH_CMD / SCP_CMD    override ssh/scp binaries
  TATWO_DIST_STUB_RESULT_DIR      stub result logs root
  TATWO_DIST_RECEIPT_DIR          override receipt output directory
  TATWO_BUILD_LOCK_DIR            build-lock path (shared with other runners)
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

log() {
  printf '[dist-run] %s\n' "$*" >&2
}

utc_stamp() {
  date -u +"%Y%m%dT%H%M%SZ"
}

require_positive_int() {
  local label="$1" raw="$2"
  [[ "$raw" =~ ^[1-9][0-9]*$ ]] || die "$label must be a positive integer (got $raw)"
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
    --from-log)
      [[ $# -ge 2 ]] || die "--from-log requires a value"
      FROM_LOG="$2"
      shift 2
      ;;
    --suites-file)
      [[ $# -ge 2 ]] || die "--suites-file requires a value"
      SUITES_FILE="$2"
      shift 2
      ;;
    --targets)
      [[ $# -ge 2 ]] || die "--targets requires a value"
      TARGETS_RAW+=("$2")
      shift 2
      ;;
    --shards)
      [[ $# -ge 2 ]] || die "--shards requires a value"
      SHARDS="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      EXECUTE=0
      shift
      ;;
    --execute)
      EXECUTE=1
      DRY_RUN=0
      shift
      ;;
    --require-matching-toolchain)
      REQUIRE_MATCHING_TOOLCHAIN=1
      shift
      ;;
    --poll-interval)
      [[ $# -ge 2 ]] || die "--poll-interval requires a value"
      POLL_INTERVAL="$2"
      shift 2
      ;;
    --poll-timeout)
      [[ $# -ge 2 ]] || die "--poll-timeout requires a value"
      POLL_TIMEOUT="$2"
      shift 2
      ;;
    --receipt-dir)
      [[ $# -ge 2 ]] || die "--receipt-dir requires a value"
      RECEIPT_DIR="$2"
      shift 2
      ;;
    --from-log=*|--suites-file=*|--targets=*|--shards=*|--poll-interval=*|--poll-timeout=*|--receipt-dir=*)
      key="${1%%=*}"
      val="${1#*=}"
      [[ -n "$val" ]] || die "$key requires a value"
      case "$key" in
        --from-log) FROM_LOG="$val" ;;
        --suites-file) SUITES_FILE="$val" ;;
        --targets) TARGETS_RAW+=("$val") ;;
        --shards) SHARDS="$val" ;;
        --poll-interval) POLL_INTERVAL="$val" ;;
        --poll-timeout) POLL_TIMEOUT="$val" ;;
        --receipt-dir) RECEIPT_DIR="$val" ;;
      esac
      shift
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

if [[ "$SELFTEST" -eq 1 ]]; then
  if [[ -n "$FROM_LOG" || -n "$SUITES_FILE" || ${#TARGETS_RAW[@]} -gt 0 || -n "$SHARDS" || "$EXECUTE" -eq 1 ]]; then
    die "--selftest cannot be combined with other run arguments"
  fi
fi

# --- target parsing ---

declare -a TARGET_KINDS=()
declare -a TARGET_SPECS=()
declare -a TARGET_USERHOSTS=()
declare -a TARGET_PATHS=()

parse_targets() {
  local blob piece rest userhost path
  TARGET_KINDS=()
  TARGET_SPECS=()
  TARGET_USERHOSTS=()
  TARGET_PATHS=()

  for blob in "${TARGETS_RAW[@]}"; do
    IFS=',' read -r -a pieces <<<"$blob"
    for piece in "${pieces[@]}"; do
      piece="$(printf '%s' "$piece" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [[ -n "$piece" ]] || continue
      if [[ "$piece" == "local" ]]; then
        TARGET_KINDS+=("local")
        TARGET_SPECS+=("local")
        TARGET_USERHOSTS+=("")
        TARGET_PATHS+=("$ROOT_DIR")
        continue
      fi
      if [[ "$piece" == ssh:* ]]; then
        rest="${piece#ssh:}"
        # user@host:worktree — first ':' after host starts worktree path
        if [[ "$rest" != *@*:* ]]; then
          die "invalid ssh target (want ssh:<user>@<host>:<worktree>): $piece"
        fi
        userhost="${rest%%:*}"
        path="${rest#*:}"
        [[ "$userhost" == *@* ]] || die "invalid ssh target (missing user@host): $piece"
        [[ -n "$path" ]] || die "invalid ssh target (empty worktree path): $piece"
        TARGET_KINDS+=("ssh")
        TARGET_SPECS+=("$piece")
        TARGET_USERHOSTS+=("$userhost")
        TARGET_PATHS+=("$path")
        continue
      fi
      die "invalid target (want local or ssh:<user>@<host>:<path>): $piece"
    done
  done

  [[ ${#TARGET_KINDS[@]} -gt 0 ]] || die "at least one --targets entry is required"
}

# --- shard planning ---

plan_shards() {
  local i out filters_file verify_out
  [[ -x "$(command -v node)" ]] || die "node is required for tatwo-test-shard.mjs"
  [[ -f "$SHARD_HELPER" ]] || die "missing $SHARD_HELPER"

  if [[ -n "$FROM_LOG" && -n "$SUITES_FILE" ]]; then
    die "provide exactly one of --from-log or --suites-file"
  fi
  if [[ -z "$FROM_LOG" && -z "$SUITES_FILE" ]]; then
    die "provide exactly one of --from-log or --suites-file"
  fi
  if [[ -n "$FROM_LOG" && ! -f "$FROM_LOG" ]]; then
    die "suite log not found: $FROM_LOG"
  fi
  if [[ -n "$SUITES_FILE" && ! -f "$SUITES_FILE" ]]; then
    die "suites file not found: $SUITES_FILE"
  fi

  require_positive_int "--shards" "$SHARDS"
  require_positive_int "--poll-interval" "$POLL_INTERVAL"
  require_positive_int "--poll-timeout" "$POLL_TIMEOUT"
  require_positive_int "TATWO_DIST_SWIFT_JOBS/--jobs equivalent" "$SWIFT_JOBS"

  if [[ "$SHARDS" -ne "${#TARGET_KINDS[@]}" ]]; then
    log "note: --shards=$SHARDS targets=${#TARGET_KINDS[@]} (shard i → target i % targets)"
  fi

  mkdir -p "$WORK_ROOT/filters" "$WORK_ROOT/logs" "$WORK_ROOT/meta"

  # Verify full partition once (fail-closed).
  local shard_args=()
  if [[ -n "$FROM_LOG" ]]; then
    shard_args=(--from-log "$FROM_LOG")
  else
    shard_args=(--suites-file "$SUITES_FILE")
  fi

  set +e
  verify_out="$(node "$SHARD_HELPER" "${shard_args[@]}" --shards "$SHARDS" --index 0 --verify-partition 2>&1 >/dev/null)"
  local vrc=$?
  set -e
  if [[ "$vrc" -ne 0 ]]; then
    printf '%s\n' "$verify_out" >&2
    printf 'CONCLUSION: FAIL: partition verification aborted (union!=universe or duplicates)\n'
    exit 1
  fi
  printf '%s\n' "$verify_out" >"$WORK_ROOT/meta/partition-verify.stderr.txt"

  for ((i = 0; i < SHARDS; i++)); do
    filters_file="$WORK_ROOT/filters/shard-${i}.filters"
    set +e
    out="$(node "$SHARD_HELPER" "${shard_args[@]}" --shards "$SHARDS" --index "$i" 2>"$WORK_ROOT/meta/shard-${i}.stderr")"
    local rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
      cat "$WORK_ROOT/meta/shard-${i}.stderr" >&2
      die "shard generation failed for index $i"
    fi
    printf '%s\n' "$out" >"$filters_file"
  done
}

target_index_for_shard() {
  local shard_index="$1"
  local n="${#TARGET_KINDS[@]}"
  echo $((shard_index % n))
}

print_plan() {
  local i tidx kind spec filters_file count path uh
  printf '=== Tatwo Distributed Run PLAN (dry-run=%s stub=%s) ===\n' "$DRY_RUN" "$STUB_MODE"
  printf 'run_id: %s\n' "$RUN_ID"
  printf 'source: %s\n' "${FROM_LOG:-$SUITES_FILE}"
  printf 'shards: %s\n' "$SHARDS"
  printf 'targets: %s\n' "${#TARGET_KINDS[@]}"
  printf 'swift_jobs: %s\n' "$SWIFT_JOBS"
  printf 'poll: interval=%ss timeout=%ss\n' "$POLL_INTERVAL" "$POLL_TIMEOUT"
  printf 'receipt_dir: %s\n' "$RECEIPT_DIR"
  if [[ "$REQUIRE_MATCHING_TOOLCHAIN" -eq 1 ]]; then
    printf 'toolchain_policy: strict (--require-matching-toolchain; mismatch → FAIL)\n'
  else
    printf 'toolchain_policy: accept-and-label (default; mismatch → DEGRADED)\n'
  fi
  printf '\n'
  printf '%-6s %-8s %-40s %6s  %s\n' "SHARD" "KIND" "TARGET" "FILTERS" "WORKTREE/PATH"
  printf '%-6s %-8s %-40s %6s  %s\n' "-----" "----" "------" "-------" "-------------"
  for ((i = 0; i < SHARDS; i++)); do
    tidx="$(target_index_for_shard "$i")"
    kind="${TARGET_KINDS[$tidx]}"
    spec="${TARGET_SPECS[$tidx]}"
    path="${TARGET_PATHS[$tidx]}"
    filters_file="$WORK_ROOT/filters/shard-${i}.filters"
    count=0
    if [[ -f "$filters_file" ]]; then
      count="$(grep -c . "$filters_file" 2>/dev/null || echo 0)"
    fi
    printf '%-6s %-8s %-40s %6s  %s\n' "$i" "$kind" "$spec" "$count" "$path"
  done
  printf '\nSteps (T1 correspondence):\n'
  printf '  1. verify partition via tatwo-test-shard.mjs --verify-partition\n'
  printf '  2. local shards: build-lock acquire/release + swift test -j %s --filter...\n' "$SWIFT_JOBS"
  printf '  3. ssh shards: scp filters → remote nohup (PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH) → RC= signal\n'
  printf '  4. poll logs for ^RC= ; collect; parse passed/failed/skipped + fingerprint\n'
  if [[ "$REQUIRE_MATCHING_TOOLCHAIN" -eq 1 ]]; then
    printf '  5. rollup conclusion (FAIL / PASS_WITH_SKIPS / PASS; mismatch → FAIL strict)\n'
  else
    printf '  5. rollup conclusion (FAIL / PASS_WITH_SKIPS / PASS + optional DEGRADED)\n'
  fi
  printf '\nPer-shard commands (not executed in dry-run):\n'
  for ((i = 0; i < SHARDS; i++)); do
    tidx="$(target_index_for_shard "$i")"
    kind="${TARGET_KINDS[$tidx]}"
    filters_file="$WORK_ROOT/filters/shard-${i}.filters"
    if [[ "$kind" == "local" ]]; then
      printf '  [shard %s local] lock → swift test -j %s $(cat %s) → RC= + fingerprint\n' \
        "$i" "$SWIFT_JOBS" "$filters_file"
    else
      uh="${TARGET_USERHOSTS[$tidx]}"
      path="${TARGET_PATHS[$tidx]}"
      printf '  [shard %s ssh] scp %s %s:/tmp/tatwo-dist-%s-shard-%s.filters\n' \
        "$i" "$filters_file" "$uh" "$RUN_ID" "$i"
      printf '               ssh %s nohup: cd %s; PATH fix; build-lock; swift test; append RC=\n' \
        "$uh" "$path"
    fi
  done
  printf '=== end plan ===\n'
}

# --- execution helpers ---

emit_fp_block() {
  local out_file="$1"
  local fp
  if [[ -f "$FP_HELPER" ]]; then
    fp="$("$FP_HELPER" 2>/dev/null || true)"
  else
    fp='{"schema":"TatwoToolchainFingerprintV1","swiftVersion":"unknown","xcodePath":null,"xcodeVersion":null,"os":"unknown","arch":"unknown","hostName":"unknown","ramGB":0,"logicalCPU":0,"generatedAt":"1970-01-01T00:00:00Z"}'
  fi
  {
    printf '===TOOLCHAIN_FINGERPRINT_BEGIN===\n'
    printf '%s\n' "$fp"
    printf '===TOOLCHAIN_FINGERPRINT_END===\n'
  } >>"$out_file"
}

run_local_shard() {
  local index="$1"
  local filters_file="$WORK_ROOT/filters/shard-${index}.filters"
  local log_file="$WORK_ROOT/logs/shard-${index}.log"
  local token_file token acq_out acq_rc test_rc=0
  local -a filter_args=()

  if [[ "$STUB_MODE" == "1" ]]; then
    run_stub_shard "$index" "local" "$log_file"
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    filter_args+=("$line")
  done <"$filters_file"

  token_file="$(mktemp "${TMPDIR:-/tmp}/tatwo-dist-lock-token.XXXXXX")"
  set +e
  acq_out="$(
    TATWO_BUILD_LOCK_TOKEN_FILE="$token_file" \
      "$LOCK_HELPER" acquire --timeout "${TATWO_DIST_LOCK_TIMEOUT:-600}" --pid "$$" 2>&1
  )"
  acq_rc=$?
  set -e
  if [[ -n "$acq_out" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        token=*) ;;
        *) printf '%s\n' "$line" >&2 ;;
      esac
    done <<<"$acq_out"
  fi
  if [[ "$acq_rc" -ne 0 ]]; then
    rm -f "$token_file"
    die "build-lock acquire failed for local shard $index"
  fi
  token="$(tr -d '[:space:]' <"$token_file" || true)"
  if [[ -z "$token" ]]; then
    token="$(printf '%s\n' "$acq_out" | sed -n 's/^token=//p' | head -n1)"
  fi
  if [[ -z "$token" ]]; then
    rm -f "$token_file"
    die "build-lock acquire returned no ownership token (refusing to bypass lock)"
  fi

  set +e
  (
    cd "$ROOT_DIR"
    if [[ ${#filter_args[@]} -eq 0 ]]; then
      # Empty shard is valid; emit empty observation with RC=0.
      printf 'empty shard index=%s filters=0\n' "$index"
      exit 0
    else
      # shellcheck disable=SC2086
      swift test -j "$SWIFT_JOBS" "${filter_args[@]}"
    fi
  ) >"$log_file" 2>&1
  test_rc=$?
  set -e

  "$LOCK_HELPER" release --token "$token" --pid "$$" >&2 || true
  rm -f "$token_file"

  emit_fp_block "$log_file"
  printf 'RC=%s\n' "$test_rc" >>"$log_file"
}

# Remote launch: scp filters, nohup runner that appends fingerprint + RC=
run_ssh_shard() {
  local index="$1"
  local tidx kind uh path filters_file remote_filters remote_log remote_cmd
  tidx="$(target_index_for_shard "$index")"
  kind="${TARGET_KINDS[$tidx]}"
  uh="${TARGET_USERHOSTS[$tidx]}"
  path="${TARGET_PATHS[$tidx]}"
  filters_file="$WORK_ROOT/filters/shard-${index}.filters"
  remote_filters="/tmp/tatwo-dist-${RUN_ID}-shard-${index}.filters"
  remote_log="/tmp/tatwo-dist-${RUN_ID}-shard-${index}.log"
  local meta="$WORK_ROOT/meta/shard-${index}.remote.json"

  printf '{"remote_filters":"%s","remote_log":"%s","userhost":"%s","worktree":"%s"}\n' \
    "$remote_filters" "$remote_log" "$uh" "$path" >"$meta"

  if [[ "$STUB_MODE" == "1" ]]; then
    # Loopback: treat as local stub writing the expected remote log path (local copy).
    local local_log="$WORK_ROOT/logs/shard-${index}.log"
    run_stub_shard "$index" "ssh:$uh" "$local_log"
    printf '%s\n' "$local_log" >"$WORK_ROOT/meta/shard-${index}.local_log_path"
    return 0
  fi

  # scp filter list (T1 step)
  "$SCP_CMD" -q "$filters_file" "${uh}:${remote_filters}"

  # PATH correction proven in dual-machine / T1: non-login SSH lacks brew/node paths.
  # shellcheck disable=SC2089
  remote_cmd=$(cat <<REMOTE
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\$PATH"
cd $(printf '%q' "$path")
LOG=$(printf '%q' "$remote_log")
FILTERS=$(printf '%q' "$remote_filters")
JOBS=$(printf '%q' "$SWIFT_JOBS")
: > "\$LOG"
(
  set +e
  TOKEN_FILE=\$(mktemp "\${TMPDIR:-/tmp}/tatwo-dist-lock-token.XXXXXX")
  ACQ=\$(TATWO_BUILD_LOCK_TOKEN_FILE="\$TOKEN_FILE" bash scripts/tatwo-build-lock.sh acquire --timeout 600 --pid \$\$ 2>&1)
  ACQ_RC=\$?
  TOKEN=\$(tr -d '[:space:]' <"\$TOKEN_FILE" 2>/dev/null || true)
  if [[ -z "\$TOKEN" ]]; then
    TOKEN=\$(printf '%s\n' "\$ACQ" | sed -n 's/^token=//p' | head -n1)
  fi
  if [[ "\$ACQ_RC" -ne 0 || -z "\$TOKEN" ]]; then
    printf 'build-lock acquire failed\n' >>"\$LOG"
    printf 'RC=2\n' >>"\$LOG"
    rm -f "\$TOKEN_FILE"
    exit 0
  fi
  FARGS=()
  while IFS= read -r line || [[ -n "\$line" ]]; do
    [[ -n "\$line" ]] || continue
    FARGS+=("\$line")
  done < "\$FILTERS"
  if [[ \${#FARGS[@]} -eq 0 ]]; then
    printf 'empty shard\n' >>"\$LOG"
    RC=0
  else
    swift test -j "\$JOBS" "\${FARGS[@]}" >>"\$LOG" 2>&1
    RC=\$?
  fi
  bash scripts/tatwo-build-lock.sh release --token "\$TOKEN" --pid \$\$ >>"\$LOG" 2>&1 || true
  rm -f "\$TOKEN_FILE"
  if [[ -f scripts/tatwo-toolchain-fingerprint.sh ]]; then
    printf '===TOOLCHAIN_FINGERPRINT_BEGIN===\n' >>"\$LOG"
    bash scripts/tatwo-toolchain-fingerprint.sh >>"\$LOG" 2>/dev/null || true
    printf '===TOOLCHAIN_FINGERPRINT_END===\n' >>"\$LOG"
  fi
  printf 'RC=%s\n' "\$RC" >>"\$LOG"
) >/dev/null 2>&1 &
echo \$!
REMOTE
)

  # Launch nohup-equivalent: remote background job; do not wait for tests.
  "$SSH_CMD" "$uh" "nohup bash -c $(printf '%q' "$remote_cmd") >/dev/null 2>&1 & echo launched"
  printf '%s\n' "$remote_log" >"$WORK_ROOT/meta/shard-${index}.remote_log_path"
  printf '%s\n' "$uh" >"$WORK_ROOT/meta/shard-${index}.userhost"
}

run_stub_shard() {
  local index="$1"
  local label="$2"
  local log_file="$3"
  local stub_src=""
  if [[ -n "$STUB_RESULT_DIR" && -f "$STUB_RESULT_DIR/shard-${index}.log" ]]; then
    stub_src="$STUB_RESULT_DIR/shard-${index}.log"
  fi
  if [[ -n "$stub_src" ]]; then
    cp "$stub_src" "$log_file"
    return 0
  fi
  # Allow selftest to omit a shard log entirely (missing-shard detection).
  if [[ "${TATWO_DIST_STUB_ALLOW_SYNTH:-1}" == "0" ]]; then
    rm -f "$log_file"
    return 0
  fi
  {
    printf "Test Suite 'StubSuite_%s' passed at 2026-01-01 00:00:00.000.\n" "$index"
    printf "===TOOLCHAIN_FINGERPRINT_BEGIN===\n"
    python3 -c 'import json,sys; print(json.dumps({"schema":"TatwoToolchainFingerprintV1","swiftVersion":"stub","xcodePath":None,"xcodeVersion":None,"os":"stub","arch":"arm64","hostName":"stub-"+sys.argv[1],"ramGB":8,"logicalCPU":4,"generatedAt":"2026-01-01T00:00:00Z"},separators=(",",":")))' "$label"
    printf "===TOOLCHAIN_FINGERPRINT_END===\n"
    printf "RC=0\n"
  } >"$log_file"
}

poll_remote_done() {
  local index="$1"
  local tidx uh remote_log local_log elapsed=0
  tidx="$(target_index_for_shard "$index")"
  local_log="$WORK_ROOT/logs/shard-${index}.log"

  if [[ "$STUB_MODE" == "1" || "${TARGET_KINDS[$tidx]}" == "local" ]]; then
    # Local/stub should already have written the log; absence is a missing shard.
    if [[ ! -f "$local_log" ]]; then
      log "warning: missing local/stub log for shard $index (will FAIL as missing shard)"
    fi
    return 0
  fi

  uh="${TARGET_USERHOSTS[$tidx]}"
  remote_log="$(cat "$WORK_ROOT/meta/shard-${index}.remote_log_path")"

  while (( elapsed <= POLL_TIMEOUT )); do
    if "$SSH_CMD" "$uh" "grep -E '^RC=[0-9]+\$' $(printf '%q' "$remote_log") >/dev/null 2>&1"; then
      "$SCP_CMD" -q "${uh}:${remote_log}" "$local_log"
      return 0
    fi
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
    log "polling shard $index (${elapsed}s/${POLL_TIMEOUT}s) for RC= in remote log"
  done
  die "timeout waiting for RC= on shard $index ($uh:$remote_log)"
}

# --- parse shard log ---

parse_shard_log() {
  # Writes key=value lines to stdout for one shard log.
  local index="$1"
  local log_file="$WORK_ROOT/logs/shard-${index}.log"
  local tidx kind spec

  tidx="$(target_index_for_shard "$index")"
  kind="${TARGET_KINDS[$tidx]}"
  spec="${TARGET_SPECS[$tidx]}"

  if [[ ! -f "$log_file" ]]; then
    printf 'index=%s\n' "$index"
    printf 'present=0\n'
    printf 'target=%s\n' "$spec"
    printf 'kind=%s\n' "$kind"
    printf 'passed=0\nfailed=0\nskipped=0\nrc=\n'
    printf 'fingerprint=\n'
    printf 'skipped_caps=\n'
    return 0
  fi

  python3 - "$index" "$log_file" "$spec" "$kind" <<'PY'
import re, sys, json

index, log_path, spec, kind = sys.argv[1:5]
text = open(log_path, "r", encoding="utf-8", errors="replace").read()
lines = text.splitlines()

passed = 0
failed = 0
for line in lines:
    if re.match(r"^\s*Test Suite .+ passed at\b", line):
        passed += 1
    elif re.match(r"^\s*Test Suite .+ failed at\b", line):
        failed += 1

skipped = 0
caps = []
case_re = re.compile(r"Test Case '(.+?)' skipped\b")
env_re = re.compile(r"\b(TATWO_[A-Z0-9_]+)\b")
# Collect capability env tokens from any skip-related lines first.
for line in lines:
    if "skip" in line.lower() or "XCTSkip" in line:
        for e in env_re.findall(line):
            if e not in caps:
                caps.append(e)
for line in lines:
    m = case_re.search(line)
    if m:
        skipped += 1
        name = m.group(1)
        envs = env_re.findall(line)
        if envs:
            for e in envs:
                if e not in caps:
                    caps.append(e)
        elif not caps:
            # Fallback label from selector when no capability env was observed.
            short = name.split(" ")[-1].rstrip("]'") if " " in name else name
            if short not in caps:
                caps.append(short)
        continue

rc = ""
for line in reversed(lines):
    m = re.match(r"^RC=(\d+)\s*$", line)
    if m:
        rc = m.group(1)
        break

fp = ""
begin = "===TOOLCHAIN_FINGERPRINT_BEGIN==="
end = "===TOOLCHAIN_FINGERPRINT_END==="
if begin in text and end in text:
    block = text.split(begin, 1)[1].split(end, 1)[0].strip()
    # take first JSON object line/block
    try:
        obj = json.loads(block)
        fp = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    except Exception:
        # try line-by-line
        for ln in block.splitlines():
            ln = ln.strip()
            if not ln:
                continue
            try:
                obj = json.loads(ln)
                fp = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
                break
            except Exception:
                continue

print(f"index={index}")
print("present=1")
print(f"target={spec}")
print(f"kind={kind}")
print(f"passed={passed}")
print(f"failed={failed}")
print(f"skipped={skipped}")
print(f"rc={rc}")
print(f"fingerprint={fp}")
print("skipped_caps=" + ",".join(caps))
print(f"log_path={log_path}")
PY
}

# --- rollup ---

write_receipt_and_conclude() {
  local -a shard_blobs=()
  local i parsed present failed_any=0 skipped_any=0 missing=0
  local all_caps=()
  local fingerprints=()
  local outcome conclusion degraded=0

  for ((i = 0; i < SHARDS; i++)); do
    parsed="$(parse_shard_log "$i")"
    shard_blobs+=("$parsed")
    present="$(printf '%s\n' "$parsed" | sed -n 's/^present=//p' | head -n1)"
    if [[ "$present" != "1" ]]; then
      missing=1
    fi
    local f s
    f="$(printf '%s\n' "$parsed" | sed -n 's/^failed=//p' | head -n1)"
    s="$(printf '%s\n' "$parsed" | sed -n 's/^skipped=//p' | head -n1)"
    [[ "${f:-0}" =~ ^[0-9]+$ ]] || f=0
    [[ "${s:-0}" =~ ^[0-9]+$ ]] || s=0
    if (( f > 0 )); then failed_any=1; fi
    if (( s > 0 )); then skipped_any=1; fi
    local caps fp
    caps="$(printf '%s\n' "$parsed" | sed -n 's/^skipped_caps=//p' | head -n1)"
    if [[ -n "$caps" ]]; then
      IFS=',' read -r -a cap_arr <<<"$caps"
      for c in "${cap_arr[@]}"; do
        [[ -n "$c" ]] || continue
        local seen=0
        if [[ ${#all_caps[@]} -gt 0 ]]; then
          for existing in "${all_caps[@]}"; do
            if [[ "$existing" == "$c" ]]; then seen=1; break; fi
          done
        fi
        if [[ "$seen" -eq 0 ]]; then
          all_caps+=("$c")
        fi
      done
    fi
    fp="$(printf '%s\n' "$parsed" | sed -n 's/^fingerprint=//p' | head -n1)"
    if [[ -n "$fp" ]]; then
      fingerprints+=("$fp")
    fi
  done

  # Toolchain consistency: compare canonical identity fields (not hostName).
  if [[ ${#fingerprints[@]} -gt 1 ]]; then
    local base=""
    local fp_list_file="$WORK_ROOT/meta/fingerprints.jsonl"
    : >"$fp_list_file"
    local fp_item
    for fp_item in "${fingerprints[@]}"; do
      printf '%s\n' "$fp_item" >>"$fp_list_file"
    done
    base=$(
      python3 - "$fp_list_file" <<'PY'
import json, sys
path = sys.argv[1]
objs = []
with open(path, "r", encoding="utf-8") as fh:
    for raw in fh:
        raw = raw.strip()
        if not raw:
            continue
        try:
            o = json.loads(raw)
        except Exception:
            o = {}
        objs.append((o.get("swiftVersion"), o.get("xcodeVersion"), o.get("os"), o.get("arch")))
if not objs:
    print("same")
elif all(x == objs[0] for x in objs):
    print("same")
else:
    print("diff")
PY
    )
    if [[ "$base" == "diff" ]]; then
      degraded=1
    fi
  fi

  local notes=()
  if [[ "$missing" -eq 1 ]]; then
    notes+=("missing shards (log not collected)")
  fi
  # Detect missing RC= as incomplete shard
  local incomplete=0
  for blob in "${shard_blobs[@]}"; do
    local pr rc
    pr="$(printf '%s\n' "$blob" | sed -n 's/^present=//p' | head -n1)"
    rc="$(printf '%s\n' "$blob" | sed -n 's/^rc=//p' | head -n1)"
    if [[ "$pr" == "1" && -z "$rc" ]]; then
      incomplete=1
    fi
  done
  if [[ "$incomplete" -eq 1 ]]; then
    notes+=("incomplete shards (missing RC= completion signal)")
  fi
  if [[ "$failed_any" -eq 1 ]]; then
    notes+=("one or more shards have failed>0")
  fi
  local caps_joined=""
  if [[ ${#all_caps[@]} -gt 0 ]]; then
    caps_joined=$(printf '%s,' "${all_caps[@]}")
    caps_joined="${caps_joined%,}"
  fi

  if [[ "$skipped_any" -eq 1 ]]; then
    notes+=("skips present; capabilities=[${caps_joined}]")
  fi
  if [[ "$degraded" -eq 1 ]]; then
    if [[ "$REQUIRE_MATCHING_TOOLCHAIN" -eq 1 ]]; then
      notes+=("require-matching-toolchain: toolchain fingerprints differ across shards")
    else
      notes+=("toolchain fingerprints differ across shards; 結果可比性降級；不等於通過")
    fi
  fi

  local notes_joined=""
  if [[ ${#notes[@]} -gt 0 ]]; then
    # Join with "; " (avoid IFS='; inside "$(...)" — bash 3.2 quote pitfall).
    notes_joined=$(printf '%s; ' "${notes[@]}")
    notes_joined="${notes_joined%; }"
  fi

  # Strict policy: fingerprint mismatch is hard FAIL (does not alter default path).
  local strict_fail=0
  if [[ "$degraded" -eq 1 && "$REQUIRE_MATCHING_TOOLCHAIN" -eq 1 ]]; then
    strict_fail=1
  fi

  if [[ "$missing" -eq 1 || "$incomplete" -eq 1 || "$failed_any" -eq 1 || "$strict_fail" -eq 1 ]]; then
    outcome="FAIL"
  elif [[ "$skipped_any" -eq 1 ]]; then
    outcome="PASS_WITH_SKIPS"
  else
    outcome="PASS"
  fi

  if [[ "$strict_fail" -eq 1 ]]; then
    # Explicit FAIL reason for strict mode (policy: mismatch must not be DEGRADED-only).
    if [[ "$failed_any" -eq 1 || "$missing" -eq 1 || "$incomplete" -eq 1 ]]; then
      conclusion="FAIL: ${notes_joined}"
      if [[ "$conclusion" != *require-matching-toolchain* ]]; then
        conclusion="FAIL: require-matching-toolchain: ${notes_joined}"
      fi
    else
      conclusion="FAIL: require-matching-toolchain: toolchain fingerprints differ across shards; 結果不可比；strict 模式整體 FAIL"
    fi
  elif [[ "$degraded" -eq 1 ]]; then
    if [[ "$outcome" == "PASS" ]]; then
      # pure DEGRADED when otherwise clean (notes already carry 不等於通過)
      if [[ "$notes_joined" == *不等於通過* ]]; then
        conclusion="DEGRADED: ${notes_joined}"
      else
        conclusion="DEGRADED: ${notes_joined}; 不等於通過"
      fi
      # keep outcome label as DEGRADED for clean mismatch-only case
      outcome="DEGRADED"
    elif [[ "$outcome" == "PASS_WITH_SKIPS" ]]; then
      conclusion="PASS_WITH_SKIPS: capabilities=[${caps_joined}]; DEGRADED: toolchain mismatch across shards; 不等於通過"
    else
      conclusion="FAIL: ${notes_joined}"
      # ensure DEGRADED marker is explicit when coexisting with FAIL
      if [[ "$conclusion" != *DEGRADED* && "$conclusion" != *降級* ]]; then
        conclusion="${conclusion}; DEGRADED"
      fi
    fi
  else
    if [[ "$outcome" == "PASS" ]]; then
      conclusion="PASS: all shards failed=0, no skips, toolchain consistent, partition complete"
    elif [[ "$outcome" == "PASS_WITH_SKIPS" ]]; then
      conclusion="PASS_WITH_SKIPS: all shards failed=0; skipped capabilities=[${caps_joined}]"
    else
      conclusion="FAIL: ${notes_joined}"
    fi
  fi

  mkdir -p "$RECEIPT_DIR"
  local receipt_path="$RECEIPT_DIR/${RUN_ID}.json"
  local blobs_file="$WORK_ROOT/meta/shard-blobs.txt"
  : >"$blobs_file"
  local blob
  for blob in "${shard_blobs[@]}"; do
    # Record separator so multi-line blobs stay intact.
    # Use printf -- so blob content starting with '-' is never an option.
    {
      printf '%s\n' '---SHARD_BLOB_BEGIN---'
      printf '%s\n' "$blob"
      printf '%s\n' '---SHARD_BLOB_END---'
    } >>"$blobs_file"
  done

  # Build JSON via Python for stable escaping.
  RECEIPT_PATH="$receipt_path" \
  RUN_ID="$RUN_ID" \
  MODE="$MODE" \
  OUTCOME="$outcome" \
  CONCLUSION="$conclusion" \
  DEGRADED="$degraded" \
  REQUIRE_MATCHING_TOOLCHAIN="$REQUIRE_MATCHING_TOOLCHAIN" \
  SHARDS_N="$SHARDS" \
  ROOT_DIR="$ROOT_DIR" \
  FROM_LOG="$FROM_LOG" \
  SUITES_FILE="$SUITES_FILE" \
  WORK_ROOT="$WORK_ROOT" \
  BLOBS_FILE="$blobs_file" \
  python3 - <<'PY'
import json, os
from datetime import datetime

blobs_file = os.environ["BLOBS_FILE"]
text = open(blobs_file, "r", encoding="utf-8").read()
parts = []
for chunk in text.split("---SHARD_BLOB_BEGIN---\n"):
    chunk = chunk.strip()
    if not chunk:
        continue
    if "---SHARD_BLOB_END---" in chunk:
        chunk = chunk.split("---SHARD_BLOB_END---", 1)[0]
    parts.append(chunk.strip("\n"))

shards = []
for blob in parts:
    d = {}
    for line in blob.splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        d[k] = v
    caps = [c for c in (d.get("skipped_caps") or "").split(",") if c]
    fp_raw = d.get("fingerprint") or ""
    fp = None
    if fp_raw:
        try:
            fp = json.loads(fp_raw)
        except Exception:
            fp = {"raw": fp_raw}
    shards.append({
        "index": int(d.get("index", "0") or 0),
        "present": d.get("present") == "1",
        "target": d.get("target"),
        "kind": d.get("kind"),
        "passed": int(d.get("passed") or 0),
        "failed": int(d.get("failed") or 0),
        "skipped": int(d.get("skipped") or 0),
        "skippedCapabilities": caps,
        "rc": d.get("rc") if d.get("rc") not in (None, "") else None,
        "toolchainFingerprint": fp,
        "logPath": d.get("log_path"),
    })

require_matching = os.environ.get("REQUIRE_MATCHING_TOOLCHAIN") == "1"
payload = {
    "schema": "TatwoDistributedRunReceiptV1",
    "runId": os.environ["RUN_ID"],
    "mode": os.environ["MODE"],
    "outcome": os.environ["OUTCOME"],
    "degraded": os.environ.get("DEGRADED") == "1",
    "requireMatchingToolchain": require_matching,
    "toolchainPolicy": "strict" if require_matching else "accept-and-label",
    "conclusion": os.environ["CONCLUSION"],
    "source": {
        "fromLog": os.environ.get("FROM_LOG") or None,
        "suitesFile": os.environ.get("SUITES_FILE") or None,
    },
    "shardCount": int(os.environ["SHARDS_N"]),
    "workRoot": os.environ.get("WORK_ROOT"),
    "repoRoot": os.environ.get("ROOT_DIR"),
    "shards": shards,
    "generatedAt": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
}
path = os.environ["RECEIPT_PATH"]
with open(path, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(path)
PY

  printf 'RECEIPT: %s\n' "$receipt_path"
  printf 'CONCLUSION: %s\n' "$conclusion"
  case "$outcome" in
    PASS) exit 0 ;;
    PASS_WITH_SKIPS) exit 0 ;;
    DEGRADED) exit 0 ;;
    FAIL) exit 1 ;;
    *) exit 1 ;;
  esac
}

# --- main run ---

run_main() {
  parse_targets
  if [[ -z "$SHARDS" ]]; then
    SHARDS="${#TARGET_KINDS[@]}"
  fi
  require_positive_int "--shards" "$SHARDS"

  RUN_ID="$(utc_stamp)"
  WORK_ROOT="${TATWO_DIST_WORK_ROOT:-${TMPDIR:-/tmp}/tatwo-dist-run-${RUN_ID}-$$}"
  mkdir -p "$WORK_ROOT"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    MODE="dry-run"
  else
    MODE="execute"
  fi
  if [[ "$STUB_MODE" == "1" ]]; then
    MODE="${MODE}+stub"
  fi

  plan_shards
  print_plan

  if [[ "$DRY_RUN" -eq 1 ]]; then
    # Plan-only receipt (no shard results).
    mkdir -p "$RECEIPT_DIR"
    local plan_receipt="$RECEIPT_DIR/${RUN_ID}.json"
    local targets_json
    targets_json="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${TARGET_SPECS[@]}")"
    RUN_ID="$RUN_ID" \
    PLAN_RECEIPT="$plan_receipt" \
    FROM_LOG="$FROM_LOG" \
    SUITES_FILE="$SUITES_FILE" \
    SHARDS_N="$SHARDS" \
    WORK_ROOT="$WORK_ROOT" \
    TARGETS_JSON="$targets_json" \
    python3 - <<'PY'
import json, os
from datetime import datetime
payload = {
  "schema": "TatwoDistributedRunReceiptV1",
  "runId": os.environ["RUN_ID"],
  "mode": "dry-run",
  "outcome": "DRY_RUN",
  "degraded": False,
  "conclusion": "DRY_RUN: plan only; partition verified; no execution",
  "source": {
    "fromLog": os.environ.get("FROM_LOG") or None,
    "suitesFile": os.environ.get("SUITES_FILE") or None,
  },
  "shardCount": int(os.environ["SHARDS_N"]),
  "targets": json.loads(os.environ.get("TARGETS_JSON") or "[]"),
  "workRoot": os.environ.get("WORK_ROOT"),
  "filtersDir": os.path.join(os.environ.get("WORK_ROOT") or "", "filters"),
  "shards": [],
  "generatedAt": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
}
path = os.environ["PLAN_RECEIPT"]
with open(path, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(path)
PY
    printf 'RECEIPT: %s\n' "$plan_receipt"
    printf 'CONCLUSION: DRY_RUN: plan printed; partition verified; no scp/SSH/swift executed\n'
    exit 0
  fi

  # Execute all shards (local sync; remote async then poll).
  local i
  for ((i = 0; i < SHARDS; i++)); do
    tidx="$(target_index_for_shard "$i")"
    if [[ "${TARGET_KINDS[$tidx]}" == "local" ]]; then
      log "starting local shard $i"
      run_local_shard "$i"
    else
      log "starting ssh shard $i → ${TARGET_SPECS[$tidx]}"
      run_ssh_shard "$i"
    fi
  done

  for ((i = 0; i < SHARDS; i++)); do
    log "collecting shard $i"
    poll_remote_done "$i"
  done

  write_receipt_and_conclude
}

# --- selftest (no real SSH) ---

run_selftest() {
  local root st_lock failures=0
  root="$(mktemp -d "${TMPDIR:-/tmp}/tatwo-dist-selftest.XXXXXX")"
  st_lock="$root/tatwo-build.lock"
  printf 'selftest: root=%s\n' "$root"

  # Fixture suites file (6 leaves)
  cat >"$root/suites.txt" <<'EOF'
SuiteA
SuiteB
SuiteC
SuiteD
SuiteE
SuiteF
EOF

  # --- 1) partition abort path ---
  # Corrupt suites with empty universe after only aggregates — use empty file.
  : >"$root/empty-suites.txt"
  set +e
  out="$(
    TATWO_DIST_RECEIPT_DIR="$root/receipts" \
    TATWO_DIST_STUB_MODE=1 \
    TATWO_BUILD_LOCK_DIR="$st_lock" \
      bash "$SCRIPT_PATH" \
        --suites-file "$root/empty-suites.txt" \
        --targets local \
        --shards 1 \
        --dry-run 2>&1
  )"
  rc=$?
  set -e
  printf 'selftest: [partition-abort] exit=%s\n' "$rc"
  printf '%s\n' "$out" | tail -n 20
  if [[ "$rc" -eq 0 ]]; then
    printf 'selftest: expected non-zero on empty suites / partition abort\n' >&2
    failures=$((failures + 1))
  else
    printf 'selftest: [partition-abort] PASS\n'
  fi

  # Helper to craft stub logs and run execute+stub.
  make_fp() {
    local host="$1" ver="$2"
    printf '{"schema":"TatwoToolchainFingerprintV1","swiftVersion":"%s","xcodePath":null,"xcodeVersion":null,"os":"macOS-selftest","arch":"arm64","hostName":"%s","ramGB":8,"logicalCPU":4,"generatedAt":"2026-01-01T00:00:00Z"}' "$ver" "$host"
  }

  write_stub_log() {
    local path="$1" passed="$2" failed="$3" skipped_line="$4" fp_json="$5" rc_val="$6"
    {
      local i
      for ((i = 1; i <= passed; i++)); do
        printf "Test Suite 'P_%s' passed at 2026-01-01 00:00:00.000.\n" "$i"
      done
      for ((i = 1; i <= failed; i++)); do
        printf "Test Suite 'F_%s' failed at 2026-01-01 00:00:00.000.\n" "$i"
      done
      if [[ -n "$skipped_line" ]]; then
        printf '%s\n' "$skipped_line"
      fi
      printf '===TOOLCHAIN_FINGERPRINT_BEGIN===\n'
      printf '%s\n' "$fp_json"
      printf '===TOOLCHAIN_FINGERPRINT_END===\n'
      printf 'RC=%s\n' "$rc_val"
    } >"$path"
  }

  run_stub_case() {
    local label="$1"
    local expect_substr="$2"
    local expect_exit="$3"
    local s0="$4"
    local s1="$5"
    local rdir="$root/case-$label"
    mkdir -p "$rdir/stubs" "$rdir/receipts"
    cp "$s0" "$rdir/stubs/shard-0.log"
    cp "$s1" "$rdir/stubs/shard-1.log"
    set +e
    out="$(
      TATWO_DIST_RECEIPT_DIR="$rdir/receipts" \
      TATWO_DIST_STUB_MODE=1 \
      TATWO_DIST_STUB_RESULT_DIR="$rdir/stubs" \
      TATWO_DIST_WORK_ROOT="$rdir/work" \
      TATWO_BUILD_LOCK_DIR="$st_lock" \
      TATWO_DIST_SSH_CMD="false" \
      TATWO_DIST_SCP_CMD="false" \
        bash "$SCRIPT_PATH" \
          --suites-file "$root/suites.txt" \
          --targets "local,ssh:stubuser@stubhost:$root/fake-worktree" \
          --shards 2 \
          --execute 2>&1
    )"
    rc=$?
    set -e
    printf 'selftest: [%s] exit=%s\n' "$label" "$rc"
    printf '%s\n' "$out" | tail -n 30
    if ! grep -F "CONCLUSION: $expect_substr" <<<"$out" >/dev/null \
      && ! grep -F "CONCLUSION: " <<<"$out" | grep -F "$expect_substr" >/dev/null; then
      printf 'selftest: [%s] expected conclusion containing %s\n' "$label" "$expect_substr" >&2
      printf '%s\n' "$out" | grep CONCLUSION || true
      return 1
    fi
    if [[ "$rc" -ne "$expect_exit" ]]; then
      printf 'selftest: [%s] expected exit %s got %s\n' "$label" "$expect_exit" "$rc" >&2
      return 1
    fi
    # Ensure no real ssh/scp was needed (stub mode); false would fail if called incorrectly on non-stub paths.
    printf 'selftest: [%s] PASS\n' "$label"
    return 0
  }

  # --- 2) FAIL path (failed>0) ---
  write_stub_log "$root/fail0.log" 2 0 "" "$(make_fp hostA 6.4)" 0
  write_stub_log "$root/fail1.log" 1 2 "" "$(make_fp hostA 6.4)" 1
  if ! run_stub_case "fail" "FAIL" 1 "$root/fail0.log" "$root/fail1.log"; then
    failures=$((failures + 1))
  fi

  # --- 3) PASS_WITH_SKIPS ---
  write_stub_log "$root/skip0.log" 3 0 \
    "Test Case '-[Mod.Tests testNeedsCap]' skipped (0.001 seconds)." \
    "$(make_fp hostA 6.4)" 0
  # inject capability token in a reason line as well
  {
    cat "$root/skip0.log" | sed '/RC=/d' | sed '/TOOLCHAIN_FINGERPRINT_END/q'
    printf "Test skipped - Set TATWO_REAL_LAUNCHCTL_SMOKE=1 to exercise\n"
    printf "Test Case '-[Mod.Tests testNeedsCap]' skipped (0.001 seconds).\n"
    printf '===TOOLCHAIN_FINGERPRINT_BEGIN===\n'
    make_fp hostA 6.4
    printf '\n===TOOLCHAIN_FINGERPRINT_END===\n'
    printf 'RC=0\n'
  } >"$root/skip0b.log"
  write_stub_log "$root/skip1.log" 2 0 "" "$(make_fp hostA 6.4)" 0
  if ! run_stub_case "pass-with-skips" "PASS_WITH_SKIPS" 0 "$root/skip0b.log" "$root/skip1.log"; then
    failures=$((failures + 1))
  fi

  # --- 4) DEGRADED (toolchain mismatch, no failures) — default accept-and-label ---
  write_stub_log "$root/deg0.log" 2 0 "" "$(make_fp hostA 6.4)" 0
  write_stub_log "$root/deg1.log" 2 0 "" "$(make_fp hostB 6.3)" 0
  if ! run_stub_case "degraded" "DEGRADED" 0 "$root/deg0.log" "$root/deg1.log"; then
    failures=$((failures + 1))
  fi

  # --- 4b) strict: same mismatch stubs → FAIL with require-matching-toolchain ---
  run_stub_case_strict() {
    local label="$1"
    local expect_substr="$2"
    local expect_exit="$3"
    local s0="$4"
    local s1="$5"
    local rdir="$root/case-$label"
    mkdir -p "$rdir/stubs" "$rdir/receipts"
    cp "$s0" "$rdir/stubs/shard-0.log"
    cp "$s1" "$rdir/stubs/shard-1.log"
    set +e
    out="$(
      TATWO_DIST_RECEIPT_DIR="$rdir/receipts" \
      TATWO_DIST_STUB_MODE=1 \
      TATWO_DIST_STUB_RESULT_DIR="$rdir/stubs" \
      TATWO_DIST_WORK_ROOT="$rdir/work" \
      TATWO_BUILD_LOCK_DIR="$st_lock" \
      TATWO_DIST_SSH_CMD="false" \
      TATWO_DIST_SCP_CMD="false" \
        bash "$SCRIPT_PATH" \
          --suites-file "$root/suites.txt" \
          --targets "local,ssh:stubuser@stubhost:$root/fake-worktree" \
          --shards 2 \
          --require-matching-toolchain \
          --execute 2>&1
    )"
    rc=$?
    set -e
    printf 'selftest: [%s] exit=%s\n' "$label" "$rc"
    printf '%s\n' "$out" | tail -n 30
    if ! grep -F "CONCLUSION: " <<<"$out" | grep -F "$expect_substr" >/dev/null; then
      printf 'selftest: [%s] expected conclusion containing %s\n' "$label" "$expect_substr" >&2
      printf '%s\n' "$out" | grep CONCLUSION || true
      return 1
    fi
    if [[ "$rc" -ne "$expect_exit" ]]; then
      printf 'selftest: [%s] expected exit %s got %s\n' "$label" "$expect_exit" "$rc" >&2
      return 1
    fi
    # Must not claim DEGRADED-only pass under strict.
    if grep -E 'CONCLUSION: DEGRADED' <<<"$out" >/dev/null; then
      printf 'selftest: [%s] strict must not conclude DEGRADED\n' "$label" >&2
      return 1
    fi
    if ! grep -F 'require-matching-toolchain' <<<"$out" >/dev/null; then
      printf 'selftest: [%s] conclusion must name require-matching-toolchain\n' "$label" >&2
      return 1
    fi
    printf 'selftest: [%s] PASS\n' "$label"
    return 0
  }
  if ! run_stub_case_strict "strict-mismatch" "FAIL" 1 "$root/deg0.log" "$root/deg1.log"; then
    failures=$((failures + 1))
  fi

  # --- 5) missing shard detection ---
  # Provide only shard-0 stub; shard-1 absent → present=0 → FAIL
  mkdir -p "$root/case-missing/stubs" "$root/case-missing/receipts"
  cp "$root/deg0.log" "$root/case-missing/stubs/shard-0.log"
  # no shard-1.log
  # Override stub runner: empty default still writes a log — so instead inject
  # a broken stub dir and a wrapper that deletes shard-1 after execute? Better:
  # patch by using STUB that creates both; then remove log before conclude.
  # Implement missing by post-processing: run with both, then re-invoke conclude
  # via execute where stub for shard 1 is empty file without RC.
  write_stub_log "$root/miss0.log" 2 0 "" "$(make_fp hostA 6.4)" 0
  # incomplete: no RC=
  {
    printf "Test Suite 'P_1' passed at 2026-01-01 00:00:00.000.\n"
    printf '===TOOLCHAIN_FINGERPRINT_BEGIN===\n'
    make_fp hostA 6.4
    printf '\n===TOOLCHAIN_FINGERPRINT_END===\n'
  } >"$root/miss1-incomplete.log"
  if ! run_stub_case "missing-rc" "FAIL" 1 "$root/miss0.log" "$root/miss1-incomplete.log"; then
    failures=$((failures + 1))
  fi

  # Explicit missing present=0: stub mode always copies or synthesizes; force
  # synthesize off by placing zero-byte missing marker and using a custom path.
  # We simulate missing by a stub log dir where shard-1 is intentionally not
  # created and TATWO_DIST_STUB_NO_SYNTH=1 — add env support quickly:
  # (handled below with execute that removes the file mid-flight via wrapper)

  mkdir -p "$root/case-absent/stubs" "$root/case-absent/receipts" "$root/case-absent/work"
  cp "$root/miss0.log" "$root/case-absent/stubs/shard-0.log"
  # No shard-1.log + STUB_ALLOW_SYNTH=0 → missing shard FAIL (no real SSH).
  set +e
  out="$(
    TATWO_DIST_RECEIPT_DIR="$root/case-absent/receipts" \
    TATWO_DIST_STUB_MODE=1 \
    TATWO_DIST_STUB_RESULT_DIR="$root/case-absent/stubs" \
    TATWO_DIST_WORK_ROOT="$root/case-absent/work" \
    TATWO_DIST_STUB_ALLOW_SYNTH=0 \
    TATWO_BUILD_LOCK_DIR="$st_lock" \
    TATWO_DIST_SSH_CMD="false" \
    TATWO_DIST_SCP_CMD="false" \
      bash "$SCRIPT_PATH" \
        --suites-file "$root/suites.txt" \
        --targets "local,ssh:stubuser@stubhost:$root/fake-worktree" \
        --shards 2 \
        --execute 2>&1
  )"
  rc=$?
  set -e
  printf 'selftest: [missing-shard] exit=%s\n' "$rc"
  printf '%s\n' "$out" | tail -n 30
  if ! grep -E 'CONCLUSION: FAIL' <<<"$out" >/dev/null; then
    printf 'selftest: [missing-shard] expected FAIL conclusion\n' >&2
    failures=$((failures + 1))
  elif [[ "$rc" -ne 1 ]]; then
    printf 'selftest: [missing-shard] expected exit 1 got %s\n' "$rc" >&2
    failures=$((failures + 1))
  else
    printf 'selftest: [missing-shard] PASS\n'
  fi

  # dry-run still works with two-target example (no SSH)
  set +e
  out="$(
    TATWO_DIST_RECEIPT_DIR="$root/receipts-dry" \
    TATWO_BUILD_LOCK_DIR="$st_lock" \
      bash "$SCRIPT_PATH" \
        --suites-file "$root/suites.txt" \
        --targets "local,ssh:example-user@example-host:/example/worktree" \
        --shards 2 \
        --dry-run 2>&1
  )"
  rc=$?
  set -e
  printf 'selftest: [dry-run-plan] exit=%s\n' "$rc"
  if [[ "$rc" -ne 0 ]] || ! grep -q 'DRY_RUN' <<<"$out"; then
    printf 'selftest: [dry-run-plan] FAIL\n' >&2
    printf '%s\n' "$out" | tail -n 40
    failures=$((failures + 1))
  else
    printf 'selftest: [dry-run-plan] PASS\n'
  fi

  if [[ "$failures" -ne 0 ]]; then
    printf 'SELFTEST FAIL (%s cases)\n' "$failures" >&2
    exit 1
  fi
  printf 'SELFTEST PASS\n'
  exit 0
}

if [[ "$SELFTEST" -eq 1 ]]; then
  run_selftest
fi

run_main
