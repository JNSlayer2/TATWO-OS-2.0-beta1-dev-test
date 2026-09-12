#!/usr/bin/env bash
# tatwo-device-sync-perf-test.sh — 本機 bare-repo 跨設備同步性能／正確性測試
#
# 安全邊界：
# - 只建立 mktemp 目錄與本機 git bare repo。
# - 不讀寫真實 device-sync-channel、GitHub、App Support、LaunchAgent、SSH 或設備。
# - latency/correctness 使用實際 sync-request 產生器，加上隔離的測試 helper consumer。
# - fail-soft 直接執行一份隔離複本的 tatwo-sync-helper.sh，搭配 mock sync executor。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$ROOT/scripts/tatwo-device-sync.sh"
HELPER="$ROOT/scripts/tatwo-sync-helper.sh"
SKILLET_CLI="${TATWO_SKILLET_CLI:-$ROOT/.build/out/Products/Debug/tatwo-ultrawork}"

COUNT=6
POLL_INTERVAL=1
ACTION_DELAY=1
CONCURRENCY=2
KEEP_TEMP=0
SELECTED="all"
TEMP_ROOTS=("")
LAST_OUTPUT=""
LAST_STATUS=0
PASS_COUNT=0

usage() {
  cat <<'EOF'
用法：
  bash scripts/tatwo-device-sync-perf-test.sh [all|latency|correctness|concurrency|pairing|fail-soft] [選項]

測試：
  latency      分開統計等待 helper 輪詢命中、命令執行、端到端延遲
  correctness  驗證 N 筆混合 action 全數消費、無重複、processed IDs 與 receipts 一致
  concurrency  以多個隔離 clone 同時 push 不同 target，驗證 rebase retry 後不覆蓋、不遺漏
  pairing      驗證 180 秒 TTL、有效消費、缺碼/不存在/過期/重放拒絕
  fail-soft    模擬通道暫時不可達，驗證 helper 存活並於下一輪恢復
  all          依序執行全部測試（預設）

選項：
  --count N             latency/correctness/concurrency 請求數（預設 6）
  --poll-interval SEC   本機測試 helper 輪詢秒數（預設 1；真實設計值為 45）
  --action-delay SEC    模擬命令執行秒數（預設 1）
  --concurrency N       每波並發 producer 數（預設 2）
  --keep-temp           保留本機臨時 fixture，供除錯
  -h, --help            顯示說明
EOF
}

log() {
  printf '%s | %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

die() {
  printf 'FAIL | %s\n' "$*" >&2
  if [ -n "$LAST_OUTPUT" ]; then
    printf '%s\n' '--- command output ---' >&2
    printf '%s\n' "$LAST_OUTPUT" >&2
    printf '%s\n' '--- end command output ---' >&2
  fi
  exit 1
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS | %s\n' "$1"
}

capture() {
  if LAST_OUTPUT="$("$@" 2>&1)"; then
    LAST_STATUS=0
  else
    LAST_STATUS=$?
  fi
}

expect_success() {
  local label="$1"
  shift
  capture "$@"
  [ "$LAST_STATUS" -eq 0 ] || die "${label}（status=${LAST_STATUS}）"
}

expect_failure() {
  local label="$1"
  shift
  capture "$@"
  [ "$LAST_STATUS" -ne 0 ] || die "${label}（預期拒絕但成功）"
}

require_positive_integer() {
  local label="$1" value="$2"
  case "$value" in
    ""|*[!0-9]*) die "${label} 必須是正整數";;
  esac
  [ "$value" -gt 0 ] || die "${label} 必須大於 0"
}

cleanup() {
  [ "$KEEP_TEMP" = "0" ] || return 0
  local path
  for path in "${TEMP_ROOTS[@]}"; do
    [ -n "$path" ] || continue
    case "$path" in
      "${TMPDIR:-/tmp}"/tatwo-device-sync-perf.*)
        [ ! -e "$path" ] || rm -r "$path"
        ;;
    esac
  done
}
trap cleanup EXIT

json_get() {
  local file="$1" key="$2"
  grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null \
    | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//'
}

iso_to_epoch() {
  local value="$1"
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$value" +%s 2>/dev/null \
    || date -u -d "$value" +%s 2>/dev/null \
    || true
}

epoch_to_iso() {
  local value="$1"
  date -u -r "$value" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@${value}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

new_fixture() {
  local label="$1"
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tatwo-device-sync-perf.${label}.XXXXXX")"
  TEMP_ROOTS+=("$TEST_ROOT")
  REMOTE="$TEST_ROOT/channel.git"
  SEED="$TEST_ROOT/seed"
  PRIMARY_HOME="$TEST_ROOT/home-mini"
  PRIMARY_APP="$TEST_ROOT/app-mini"
  PRIMARY_CHANNEL="$TEST_ROOT/channel-mini"
  OS_ROOT="$TEST_ROOT/os-canonical"

  git init --bare -q "$REMOTE"
  git init -q -b main "$SEED"
  git -C "$SEED" config user.name "Tatwo Device Sync Perf"
  git -C "$SEED" config user.email "device-sync-perf@example.invalid"
  printf '%s\n' "local-only device sync perf fixture" >"$SEED/README.md"
  git -C "$SEED" add README.md
  git -C "$SEED" commit -q -m "seed local-only channel remote"
  git -C "$SEED" remote add origin "$REMOTE"
  git -C "$SEED" push -q origin main
  git --git-dir="$REMOTE" symbolic-ref HEAD refs/heads/main
  mkdir -p "$OS_ROOT"
  printf '%s\n' "# Test Work OS" >"$OS_ROOT/os.md"
  printf '%s\n' "# Test issues" >"$OS_ROOT/issue.md"
  printf '%s\n' "# Test TODO" >"$OS_ROOT/TODO.md"

  expect_success "fixture register primary" \
    run_sync mini "$PRIMARY_HOME" "$PRIMARY_APP" "$PRIMARY_CHANNEL" \
    register --role primary --name mini --host mini.invalid
  expect_success "fixture set primary" \
    run_sync mini "$PRIMARY_HOME" "$PRIMARY_APP" "$PRIMARY_CHANNEL" \
    set-primary --name mini
}

run_sync() {
  local device="$1" home="$2" app_support="$3" channel_dir="$4"
  shift 4
  mkdir -p "$home" "$app_support"
  env \
    HOME="$home" \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_AUTHOR_NAME="Tatwo Device Sync Perf" \
    GIT_AUTHOR_EMAIL="device-sync-perf@example.invalid" \
    GIT_COMMITTER_NAME="Tatwo Device Sync Perf" \
    GIT_COMMITTER_EMAIL="device-sync-perf@example.invalid" \
    TATWO_APP_SUPPORT="$app_support" \
    TATWO_REMOTE_APP_SUPPORT="$app_support" \
    TATWO_DEVICE_NAME="$device" \
    TATWO_PRIMARY_SSH_HOST="offline-primary.example.invalid" \
    TATWO_SYNC_REPO="$SEED" \
    TATWO_RELEASE_BRANCH="main" \
    TATWO_CHANNEL_REMOTE="$REMOTE" \
    TATWO_CHANNEL_DIR="$channel_dir" \
    TATWO_OS_ROOT="$OS_ROOT" \
    TATWO_SYNC_CATALOG="$ROOT/config/tatwo-sync-catalog-v1.json" \
    TATWO_HOT_SYNC_STAGING="$app_support/hot-sync-staging" \
    TATWO_HOT_SYNC_MIRROR="$app_support/hot-sync-mirror" \
    TATWO_SKILLET_STORE="$app_support/skillet" \
    TATWO_SKILLS_RUNTIME_ROOT="$app_support/skills-runtime" \
    TATWO_SKILLET_CLI="$SKILLET_CLI" \
    TATWO_DEVICE_TRUST_CLI="$SKILLET_CLI" \
    TATWO_DEVICE_TRUST_TEST_KEY_ROOT="$app_support/device-trust-test-keys" \
    TATWO_TEST_MODE=1 \
    bash "$SYNC" "$@"
}

run_sync_with_ttl() {
  local ttl="$1"
  shift
  TATWO_PAIRING_TTL_SECONDS="$ttl" run_sync "$@"
}

init_consumer_channel() {
  local device="$1" home="$2" app_support="$3" channel_dir="$4"
  if [ "$device" != "mini" ]; then
    expect_success "create pairing seed for ${device}" \
      run_sync mini "$PRIMARY_HOME" "$PRIMARY_APP" "$PRIMARY_CHANNEL" pairing-create
    local seed
    seed="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^PAIRING_SEED=//p' | tail -1)"
    [ -n "$seed" ] || die "無法取得 ${device} 的 pairing seed"
    expect_success "register consumer ${device}" \
      run_sync "$device" "$home" "$app_support" "$channel_dir" \
      register --role secondary --name "$device" --host "${device}.invalid" --pairing-seed "$seed"
  fi
  expect_success "initialize consumer channel ${device}" \
    run_sync "$device" "$home" "$app_support" "$channel_dir" role-status
}

refresh_channel() {
  local channel_dir="$1"
  git -C "$channel_dir" fetch origin \
    "refs/heads/device-sync-channel:refs/remotes/origin/device-sync-channel" >/dev/null 2>&1
  git -C "$channel_dir" reset --hard origin/device-sync-channel >/dev/null 2>&1
}

action_delay_for() {
  local action="$1"
  case "$action" in
    db-pull|version-pull) printf '%s\n' "$ACTION_DELAY";;
    *) return 1;;
  esac
}

consume_request_once() {
  local channel_dir="$1" app_support="$2" device="$3"
  local state_dir="$app_support/device-sync-state"
  local receipt_dir="$app_support/device-sync-perf/receipts"
  local processed="$state_dir/processed-ids-$device"
  mkdir -p "$state_dir" "$receipt_dir"

  refresh_channel "$channel_dir" || return 20
  local request=""
  if [ -f "$channel_dir/requests/$device.json" ]; then
    request="$channel_dir/requests/$device.json"
  elif [ -d "$channel_dir/requests/$device" ]; then
    local candidate candidate_id
    while IFS= read -r candidate; do
      candidate_id="$(json_get "$candidate" id)"
      [ -n "$candidate_id" ] || continue
      if ! grep -qxF "$candidate_id" "$processed" 2>/dev/null; then
        request="$candidate"
        break
      fi
    done < <(
      find "$channel_dir/requests/$device" -maxdepth 1 -type f -name '*.json' -print \
        | LC_ALL=C sort
    )
  fi
  [ -n "$request" ] || return 0

  local id action requested_at requested_epoch poll_hit_epoch command_delay
  id="$(json_get "$request" id)"
  action="$(json_get "$request" action)"
  requested_at="$(json_get "$request" requestedAt)"
  [ -n "$id" ] || return 21
  [ -n "$action" ] || return 22
  grep -qxF "$id" "$processed" 2>/dev/null && return 0
  requested_epoch="$(iso_to_epoch "$requested_at")"
  [ -n "$requested_epoch" ] || return 23
  command_delay="$(action_delay_for "$action")" || return 24

  poll_hit_epoch="$(date -u +%s)"
  sleep "$command_delay"
  local completed_epoch poll_hit_at completed_at wait_seconds command_seconds total_seconds
  completed_epoch="$(date -u +%s)"
  poll_hit_at="$(epoch_to_iso "$poll_hit_epoch")"
  completed_at="$(epoch_to_iso "$completed_epoch")"
  wait_seconds=$((poll_hit_epoch - requested_epoch))
  command_seconds=$((completed_epoch - poll_hit_epoch))
  total_seconds=$((completed_epoch - requested_epoch))
  [ "$wait_seconds" -ge 0 ] || return 25

  cat >"$receipt_dir/$id.json" <<EOF
{
  "schema": "TatwoDeviceSyncPerfReceiptV1",
  "id": "$id",
  "action": "$action",
  "target": "$device",
  "requestedAt": "$requested_at",
  "pollHitAt": "$poll_hit_at",
  "completedAt": "$completed_at",
  "pollWaitSeconds": $wait_seconds,
  "commandSeconds": $command_seconds,
  "totalSeconds": $total_seconds,
  "executionCount": 1,
  "result": "success"
}
EOF
  printf '%s\n' "$id" >>"$processed"
  return 0
}

benchmark_worker() {
  local channel_dir="$1" app_support="$2" device="$3" expected="$4" max_seconds="$5"
  local started now receipt_dir="$app_support/device-sync-perf/receipts"
  started="$(date -u +%s)"
  while :; do
    consume_request_once "$channel_dir" "$app_support" "$device" || return $?
    local count=0
    if [ -d "$receipt_dir" ]; then
      count="$(find "$receipt_dir" -type f -name '*.json' | wc -l | tr -d ' ')"
    fi
    [ "$count" -ge "$expected" ] && return 0
    now="$(date -u +%s)"
    [ $((now - started)) -lt "$max_seconds" ] || return 26
    sleep "$POLL_INTERVAL"
  done
}

action_for_index() {
  case $((($1 - 1) % 2)) in
    0) printf '%s\n' "db-pull";;
    1) printf '%s\n' "version-pull";;
  esac
}

wait_for_receipt() {
  local receipt="$1" max_seconds="$2"
  local started now
  started="$(date -u +%s)"
  while [ ! -f "$receipt" ]; do
    now="$(date -u +%s)"
    [ $((now - started)) -lt "$max_seconds" ] || return 1
    sleep 1
  done
}

issue_sequential_requests() {
  local count="$1" device="$2" app_support="$3"
  local expected_file="$4" channel_dir="$5"
  : >"$expected_file"
  local index action id receipt
  for index in $(seq 1 "$count"); do
    action="$(action_for_index "$index")"
    expect_success "sync-request ${index}/${count}" \
      run_sync mini "$PRIMARY_HOME" "$PRIMARY_APP" "$PRIMARY_CHANNEL" \
      sync-request --target "$device" --action "$action"
    id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/.* id=\([^（ ]*\).*/\1/p' | tail -1)"
    [ -n "$id" ] || die "無法從 sync-request 輸出解析第 ${index} 筆 id"
    printf '%s\t%s\n' "$id" "$action" >>"$expected_file"
    receipt="$app_support/device-sync-perf/receipts/$id.json"
    wait_for_receipt "$receipt" $((POLL_INTERVAL + ACTION_DELAY * 2 + 8)) \
      || die "等待第 ${index} 筆 receipt 逾時：id=${id}"
  done
}

metric_stats() {
  local file="$1"
  local count min max sum avg p50_index p95_index p50 p95
  count="$(wc -l <"$file" | tr -d ' ')"
  [ "$count" -gt 0 ] || die "延遲統計沒有樣本"
  min="$(sort -n "$file" | head -1)"
  max="$(sort -n "$file" | tail -1)"
  sum="$(awk '{s += $1} END {print s + 0}' "$file")"
  avg="$(awk -v s="$sum" -v n="$count" 'BEGIN {printf "%.2f", s / n}')"
  p50_index=$(((count * 50 + 99) / 100))
  p95_index=$(((count * 95 + 99) / 100))
  p50="$(sort -n "$file" | sed -n "${p50_index}p")"
  p95="$(sort -n "$file" | sed -n "${p95_index}p")"
  printf 'samples=%s min=%ss p50=%ss p95=%ss max=%ss avg=%ss' \
    "$count" "$min" "$p50" "$p95" "$max" "$avg"
}

test_latency() {
  printf '\n=== latency ===\n'
  new_fixture latency
  local book_home="$TEST_ROOT/home-book"
  local book_app="$TEST_ROOT/app-book"
  local book_channel="$TEST_ROOT/channel-book"
  local expected="$TEST_ROOT/expected.tsv"
  init_consumer_channel book "$book_home" "$book_app" "$book_channel"

  local timeout=$((COUNT * (POLL_INTERVAL + ACTION_DELAY * 2 + 4) + 10))
  benchmark_worker "$book_channel" "$book_app" book "$COUNT" "$timeout" &
  local worker_pid=$!
  issue_sequential_requests "$COUNT" book "$book_app" "$expected" "$book_channel"
  wait "$worker_pid" || die "latency helper worker 未完成"

  local wait_file="$TEST_ROOT/wait.txt"
  local command_file="$TEST_ROOT/command.txt"
  local total_file="$TEST_ROOT/total.txt"
  : >"$wait_file"; : >"$command_file"; : >"$total_file"

  printf '%-3s %-14s %-8s %-8s %-8s %s\n' "#" "action" "poll(s)" "cmd(s)" "total(s)" "id"
  local index=0 id action receipt poll_wait command_seconds total_seconds result
  while IFS=$'\t' read -r id action; do
    index=$((index + 1))
    receipt="$book_app/device-sync-perf/receipts/$id.json"
    result="$(json_get "$receipt" result)"
    [ "$result" = "success" ] || die "latency receipt result 非 success：id=${id}"
    poll_wait="$(grep -o '"pollWaitSeconds"[[:space:]]*:[[:space:]]*[0-9]*' "$receipt" | sed 's/.*:[[:space:]]*//')"
    command_seconds="$(grep -o '"commandSeconds"[[:space:]]*:[[:space:]]*[0-9]*' "$receipt" | sed 's/.*:[[:space:]]*//')"
    total_seconds="$(grep -o '"totalSeconds"[[:space:]]*:[[:space:]]*[0-9]*' "$receipt" | sed 's/.*:[[:space:]]*//')"
    printf '%-3s %-14s %-8s %-8s %-8s %s\n' \
      "$index" "$action" "$poll_wait" "$command_seconds" "$total_seconds" "$id"
    printf '%s\n' "$poll_wait" >>"$wait_file"
    printf '%s\n' "$command_seconds" >>"$command_file"
    printf '%s\n' "$total_seconds" >>"$total_file"
  done <"$expected"

  printf 'LATENCY | poll_wait | %s\n' "$(metric_stats "$wait_file")"
  printf 'LATENCY | command   | %s\n' "$(metric_stats "$command_file")"
  printf 'LATENCY | end_to_end| %s\n' "$(metric_stats "$total_file")"
  pass "latency 分段與分布統計完成"
}

test_correctness() {
  printf '\n=== correctness ===\n'
  new_fixture correctness
  local expected="$TEST_ROOT/expected.tsv"
  local consumer_root="$TEST_ROOT/consumers"
  mkdir -p "$consumer_root"
  : >"$expected"

  local worker_pids=()
  local index device home app channel action
  for index in $(seq 1 "$COUNT"); do
    device="book-${index}"
    home="$consumer_root/home-${index}"
    app="$consumer_root/app-${index}"
    channel="$consumer_root/channel-${index}"
    init_consumer_channel "$device" "$home" "$app" "$channel"
  done

  local timeout=$((COUNT * (POLL_INTERVAL + ACTION_DELAY * 2 + 4) + 10))
  for index in $(seq 1 "$COUNT"); do
    device="book-${index}"
    app="$consumer_root/app-${index}"
    channel="$consumer_root/channel-${index}"
    benchmark_worker "$channel" "$app" "$device" 1 "$timeout" &
    worker_pids+=("$!")
  done

  local id
  for index in $(seq 1 "$COUNT"); do
    device="book-${index}"
    action="$(action_for_index "$index")"
    expect_success "burst sync-request ${index}/${COUNT}" \
      run_sync mini "$PRIMARY_HOME" "$PRIMARY_APP" "$PRIMARY_CHANNEL" \
      sync-request --target "$device" --action "$action"
    id="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/.* id=\([^（ ]*\).*/\1/p' | tail -1)"
    [ -n "$id" ] || die "無法從 burst sync-request 解析第 ${index} 筆 id"
    printf '%s\t%s\t%s\n' "$id" "$action" "$device" >>"$expected"
  done

  local pid
  for pid in "${worker_pids[@]}"; do
    wait "$pid" || die "correctness helper worker 未完成"
  done

  local processed_count=0 receipt_count=0
  local unique_processed_file="$TEST_ROOT/all-processed.txt"
  local unique_receipts_file="$TEST_ROOT/all-receipts.txt"
  : >"$unique_processed_file"
  : >"$unique_receipts_file"
  for index in $(seq 1 "$COUNT"); do
    device="book-${index}"
    app="$consumer_root/app-${index}"
    channel="$consumer_root/channel-${index}"
    consume_request_once "$channel" "$app" "$device" \
      || die "correctness 額外輪詢失敗：${device}"
    consume_request_once "$channel" "$app" "$device" \
      || die "correctness 第二次額外輪詢失敗：${device}"
    local processed="$app/device-sync-state/processed-ids-$device"
    local receipts="$app/device-sync-perf/receipts"
    processed_count=$((processed_count + $(wc -l <"$processed" | tr -d ' ')))
    receipt_count=$((receipt_count + $(find "$receipts" -type f -name '*.json' | wc -l | tr -d ' ')))
    cat "$processed" >>"$unique_processed_file"
    find "$receipts" -type f -name '*.json' -exec basename {} .json \; >>"$unique_receipts_file"
  done

  local expected_count unique_processed unique_receipts
  expected_count="$(wc -l <"$expected" | tr -d ' ')"
  unique_processed="$(sort -u "$unique_processed_file" | wc -l | tr -d ' ')"
  unique_receipts="$(sort -u "$unique_receipts_file" | wc -l | tr -d ' ')"
  [ "$expected_count" -eq "$COUNT" ] || die "expected ids 數量錯誤"
  [ "$processed_count" -eq "$COUNT" ] || die "processed IDs 遺漏或重複：${processed_count}/${COUNT}"
  [ "$receipt_count" -eq "$COUNT" ] || die "receipts 遺漏或重複：${receipt_count}/${COUNT}"
  [ "$unique_processed" -eq "$COUNT" ] || die "processed IDs 有重複"
  [ "$unique_receipts" -eq "$COUNT" ] || die "receipt ids 有重複"

  local receipt receipt_action execution_count result
  while IFS=$'\t' read -r id action device; do
    index="${device#book-}"
    app="$consumer_root/app-${index}"
    local processed="$app/device-sync-state/processed-ids-$device"
    local receipts="$app/device-sync-perf/receipts"
    grep -qxF "$id" "$processed" || die "processed IDs 缺少 ${id}"
    receipt="$receipts/$id.json"
    [ -f "$receipt" ] || die "receipt 缺少 ${id}"
    receipt_action="$(json_get "$receipt" action)"
    result="$(json_get "$receipt" result)"
    execution_count="$(grep -o '"executionCount"[[:space:]]*:[[:space:]]*[0-9]*' "$receipt" | sed 's/.*:[[:space:]]*//')"
    [ "$receipt_action" = "$action" ] || die "action 不符：id=${id}"
    [ "$result" = "success" ] || die "result 非 success：id=${id}"
    [ "$execution_count" = "1" ] || die "重複執行：id=${id}"
  done <"$expected"

  printf 'CORRECTNESS | requested=%s processed=%s receipts=%s unique=%s duplicate_exec=0\n' \
    "$COUNT" "$processed_count" "$receipt_count" "$unique_receipts"
  pass "N 筆連續混合 action exact-once、無遺漏"
}

test_concurrency() {
  printf '\n=== concurrency ===\n'
  new_fixture concurrency
  local count="$COUNT"
  [ "$count" -ge "$CONCURRENCY" ] || count="$CONCURRENCY"
  local producer_root="$TEST_ROOT/producers"
  local target_root="$TEST_ROOT/targets"
  local output_root="$TEST_ROOT/outputs"
  mkdir -p "$producer_root" "$target_root" "$output_root"

  local index home app channel
  for index in $(seq 1 "$count"); do
    init_consumer_channel "book-${index}" \
      "$target_root/home-$index" \
      "$target_root/app-$index" \
      "$target_root/channel-$index"
    home="$producer_root/home-$index"
    app="$PRIMARY_APP"
    channel="$producer_root/channel-$index"
    init_consumer_channel mini "$home" "$app" "$channel"
  done

  local issued=0 wave=0
  while [ "$issued" -lt "$count" ]; do
    wave=$((wave + 1))
    local go="$TEST_ROOT/go-${wave}"
    local pids=()
    local wave_size="$CONCURRENCY"
    [ $((count - issued)) -ge "$wave_size" ] || wave_size=$((count - issued))
    local slot
    for slot in $(seq 1 "$wave_size"); do
      index=$((issued + slot))
      home="$producer_root/home-$index"
      app="$PRIMARY_APP"
      channel="$producer_root/channel-$index"
      (
        while [ ! -f "$go" ]; do sleep 0.05; done
        run_sync mini "$home" "$app" "$channel" \
          sync-request --target "book-${index}" --action "$(action_for_index "$index")"
      ) >"$output_root/$index.log" 2>&1 &
      pids+=("$!")
    done
    : >"$go"
    local pid
    for pid in "${pids[@]}"; do
      wait "$pid" || {
        cat "$output_root"/*.log >&2
        die "並發 wave ${wave} 有 producer push 失敗"
      }
    done
    issued=$((issued + wave_size))
  done

  local audit="$TEST_ROOT/audit"
  git clone -q --branch device-sync-channel --single-branch "$REMOTE" "$audit"
  local request_count unique_ids
  request_count="$(find "$audit/requests" -type f -name '*.json' | wc -l | tr -d ' ')"
  unique_ids="$(
    find "$audit/requests" -type f -name '*.json' -print \
      | while IFS= read -r file; do json_get "$file" id; done \
      | sort -u | wc -l | tr -d ' '
  )"
  [ "$request_count" -eq "$count" ] || die "並發請求遺漏：${request_count}/${count}"
  [ "$unique_ids" -eq "$count" ] || die "並發請求 id 覆蓋或重複：${unique_ids}/${count}"
  for index in $(seq 1 "$count"); do
    local target_count
    target_count="$(
      find "$audit/requests/book-${index}" -maxdepth 1 -type f -name '*.json' 2>/dev/null \
        | wc -l | tr -d ' '
    )"
    [ "$target_count" -eq 1 ] || die "缺少或重複並發 target book-${index}"
  done

  printf 'CONCURRENCY | requests=%s unique_ids=%s waves=%s width=%s lost=0\n' \
    "$request_count" "$unique_ids" "$wave" "$CONCURRENCY"
  pass "channel push rebase retry 小規模並發無覆蓋、無遺漏"
}

test_pairing() {
  printf '\n=== pairing ===\n'
  new_fixture pairing

  expect_success "create 180-second pairing code" \
    run_sync_with_ttl 180 mini "$PRIMARY_HOME" "$PRIMARY_APP" "$PRIMARY_CHANNEL" pairing-create
  local seed expires_at pairing_file created_at created_epoch expires_epoch ttl_delta
  seed="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^PAIRING_SEED=//p' | tail -1)"
  expires_at="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^PAIRING_EXPIRES_AT=//p' | tail -1)"
  [ "${#seed}" -eq 8 ] || die "配對碼長度不是 8"
  pairing_file="$PRIMARY_CHANNEL/pairing/$seed.json"
  [ -f "$pairing_file" ] || die "配對碼檔案不存在"
  created_at="$(json_get "$pairing_file" createdAt)"
  created_epoch="$(iso_to_epoch "$created_at")"
  expires_epoch="$(iso_to_epoch "$expires_at")"
  ttl_delta=$((expires_epoch - created_epoch))
  [ "$ttl_delta" -eq 180 ] || die "配對 TTL 不是 180 秒：${ttl_delta}"
  pass "pairing TTL 精確為 180 秒"

  expect_failure "missing pairing seed rejected" \
    run_sync book-missing "$TEST_ROOT/home-missing" "$TEST_ROOT/app-missing" "$TEST_ROOT/channel-missing" \
    register --role secondary --name book-missing --host missing.invalid
  printf '%s\n' "$LAST_OUTPUT" | grep -q '需要配對代碼' || die "缺碼拒絕訊息不清楚"
  pass "缺少配對碼 fail-closed"

  expect_failure "nonexistent pairing seed rejected" \
    run_sync book-none "$TEST_ROOT/home-none" "$TEST_ROOT/app-none" "$TEST_ROOT/channel-none" \
    register --role secondary --name book-none --host none.invalid --pairing-seed ZZZZZZZZ
  printf '%s\n' "$LAST_OUTPUT" | grep -q '無效或不存在' || die "不存在配對碼拒絕訊息不清楚"
  pass "不存在配對碼 fail-closed"

  expect_success "valid pairing seed consumed once" \
    run_sync book-valid "$TEST_ROOT/home-valid" "$TEST_ROOT/app-valid" "$TEST_ROOT/channel-valid" \
    register --role secondary --name book-valid --host valid.invalid --pairing-seed "$seed"
  refresh_channel "$PRIMARY_CHANNEL"
  local consumed_at
  consumed_at="$(json_get "$pairing_file" consumedAt)"
  [ -n "$consumed_at" ] || die "有效配對後未寫入 consumedAt"
  pass "有效配對碼成功且寫入 consumedAt"

  expect_failure "replayed pairing seed rejected" \
    run_sync book-replay "$TEST_ROOT/home-replay" "$TEST_ROOT/app-replay" "$TEST_ROOT/channel-replay" \
    register --role secondary --name book-replay --host replay.invalid --pairing-seed "$seed"
  printf '%s\n' "$LAST_OUTPUT" | grep -q '已使用過' || die "重放拒絕訊息不清楚"
  pass "已消費配對碼重放拒絕"

  expect_success "create short-lived pairing seed" \
    run_sync_with_ttl 1 mini "$PRIMARY_HOME" "$PRIMARY_APP" "$PRIMARY_CHANNEL" pairing-create
  local expired_seed
  expired_seed="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^PAIRING_SEED=//p' | tail -1)"
  sleep 2
  expect_failure "expired pairing seed rejected" \
    run_sync book-expired "$TEST_ROOT/home-expired" "$TEST_ROOT/app-expired" "$TEST_ROOT/channel-expired" \
    register --role secondary --name book-expired --host expired.invalid --pairing-seed "$expired_seed"
  printf '%s\n' "$LAST_OUTPUT" | grep -q '已過期' || die "過期拒絕訊息不清楚"
  pass "過期配對碼拒絕"

  printf 'PAIRING | ttl=%ss single_use=pass expired_reject=pass replay_reject=pass\n' "$ttl_delta"
}

test_fail_soft() {
  printf '\n=== fail-soft ===\n'
  new_fixture fail-soft
  local helper_root="$TEST_ROOT/helper-bin"
  local helper_app="$TEST_ROOT/helper-app"
  local mock_sync="$helper_root/tatwo-device-sync.sh"
  local helper_copy="$helper_root/tatwo-sync-helper.sh"
  local attempts="$TEST_ROOT/sync-poll-attempts"
  local recovered="$TEST_ROOT/recovered"
  local offline_remote="$TEST_ROOT/channel.offline.git"
  mkdir -p "$helper_root" "$helper_app"
  cp "$HELPER" "$helper_copy"
  mv "$REMOTE" "$offline_remote"

  cat >"$mock_sync" <<'EOF'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  role-status)
    printf '%s\n' "device=book role=secondary primary=mini epoch=1 changedAt=test"
    ;;
  sync-poll)
    count=0
    [ ! -f "$MOCK_ATTEMPTS" ] || count="$(cat "$MOCK_ATTEMPTS")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$MOCK_ATTEMPTS"
    if ! git --git-dir="$MOCK_REMOTE" rev-parse --is-bare-repository >/dev/null 2>&1; then
      printf '%s\n' "simulated channel unavailable" >&2
      exit 42
    fi
    : >"$MOCK_RECOVERED"
    printf '%s\n' "simulated sync-poll recovered"
    ;;
  version-pull)
    exit 0
    ;;
  *)
    printf 'unexpected mock command: %s\n' "${1:-missing}" >&2
    exit 64
    ;;
esac
EOF
  chmod +x "$mock_sync" "$helper_copy"

  env \
    TATWO_APP_SUPPORT="$helper_app" \
    TATWO_DEVICE_NAME="book" \
    TATWO_DEVICE_ROLE="secondary" \
    TATWO_SYNC_INTERVAL=1 \
    TATWO_AUTO_VERSION=0 \
    MOCK_REMOTE="$REMOTE" \
    MOCK_ATTEMPTS="$attempts" \
    MOCK_RECOVERED="$recovered" \
    bash "$helper_copy" &
  local helper_pid=$!

  local started now
  started="$(date -u +%s)"
  while [ ! -f "$attempts" ]; do
    kill -0 "$helper_pid" 2>/dev/null || die "helper 在通道不可達時崩潰"
    now="$(date -u +%s)"
    [ $((now - started)) -lt 6 ] || die "helper 未嘗試 sync-poll"
    sleep 1
  done
  kill -0 "$helper_pid" 2>/dev/null || die "helper 第一次 sync-poll 失敗後已退出"
  pass "通道不可達時 helper 保持存活"

  mv "$offline_remote" "$REMOTE"
  started="$(date -u +%s)"
  while [ ! -f "$recovered" ]; do
    kill -0 "$helper_pid" 2>/dev/null || die "helper 在恢復前崩潰"
    now="$(date -u +%s)"
    [ $((now - started)) -lt 8 ] || die "通道恢復後 helper 未在下一輪成功"
    sleep 1
  done
  local attempt_count
  attempt_count="$(cat "$attempts")"
  [ "$attempt_count" -ge 2 ] || die "helper 未進入下一輪：attempts=${attempt_count}"
  grep -q 'sync-poll 這輪失敗' "$helper_app/sync-helper.log" \
    || die "helper log 缺少 fail-soft 記錄"
  kill "$helper_pid" 2>/dev/null || true
  wait "$helper_pid" 2>/dev/null || true

  printf 'FAIL_SOFT | failed_rounds=1 attempts=%s recovered=pass helper_survived=pass\n' "$attempt_count"
  pass "helper 下一輪自動恢復"
}

run_selected() {
  [ -x "$SKILLET_CLI" ] \
    || die "需要可執行的 tatwo-ultrawork CLI；請先建置或以 TATWO_SKILLET_CLI 指定"
  case "$SELECTED" in
    latency) test_latency;;
    correctness) test_correctness;;
    concurrency) test_concurrency;;
    pairing) test_pairing;;
    fail-soft) test_fail_soft;;
    all)
      test_latency
      test_correctness
      test_concurrency
      test_pairing
      test_fail_soft
      ;;
    *) die "未知測試：${SELECTED}";;
  esac
}

parse_args() {
  if [ $# -gt 0 ]; then
    case "$1" in
      all|latency|correctness|concurrency|pairing|fail-soft)
        SELECTED="$1"
        shift
        ;;
    esac
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --count) COUNT="${2:-}"; shift 2;;
      --poll-interval) POLL_INTERVAL="${2:-}"; shift 2;;
      --action-delay) ACTION_DELAY="${2:-}"; shift 2;;
      --concurrency) CONCURRENCY="${2:-}"; shift 2;;
      --keep-temp) KEEP_TEMP=1; shift;;
      -h|--help) usage; exit 0;;
      *) die "未知參數：${1}";;
    esac
  done
  require_positive_integer "--count" "$COUNT"
  require_positive_integer "--poll-interval" "$POLL_INTERVAL"
  require_positive_integer "--action-delay" "$ACTION_DELAY"
  require_positive_integer "--concurrency" "$CONCURRENCY"
  [ "$CONCURRENCY" -le 8 ] || die "--concurrency 上限為 8"
}

main() {
  [ -x "$SYNC" ] || die "找不到同步執行器：${SYNC}"
  [ -x "$HELPER" ] || die "找不到 helper：${HELPER}"
  command -v git >/dev/null 2>&1 || die "缺少 git"
  parse_args "$@"
  log "START selected=${SELECTED} count=${COUNT} poll_interval=${POLL_INTERVAL}s action_delay=${ACTION_DELAY}s concurrency=${CONCURRENCY}"
  run_selected
  printf '\nSUMMARY | result=PASS selected=%s assertions=%s local_bare_repo_only=true\n' \
    "$SELECTED" "$PASS_COUNT"
  printf '{"schema":"TatwoDeviceSyncPerfTestV1","result":"success","selected":"%s","assertions":%s,"count":%s,"pollIntervalSeconds":%s,"productionPollIntervalSeconds":45}\n' \
    "$SELECTED" "$PASS_COUNT" "$COUNT" "$POLL_INTERVAL"
}

main "$@"
