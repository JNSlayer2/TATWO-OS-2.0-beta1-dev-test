#!/usr/bin/env bash
# tatwo-remote-channel-sync.sh — move *signed* remote-loop channel artifacts between hosts.
#
# Purpose
#   Origin (mini) and target (MacBook) each keep a sealed channel directory.
#   This script only transports already-signed channel products. Trust is NOT
#   conferred by the pipe: runners verify freshness, attempt binding, anti-rollback,
#   and Keychain consume high-water locally. Consume high-water never rides this sync.
#
# Dual-machine enablement order (fail-closed)
#   1. Both hosts: device-trust init + mutual pin-import
#   2. Both hosts: remote-runner seal-install --device-id <self> --channel-dir <path>
#   3. Target: remote-runner start --device-id <target> --origin-device-id <origin> (long-running)
#   4. Origin: remote-runner dispatch ... then this script push
#   5. Target runner executes; this script pull; origin converge
# Crash-after-claim recovery: mint new jobID + new dispatchNonce; keep logicalJobID
# (TatwoLoopJobV1.mintRecoveryDispatch). Never re-nonce the same jobID.
#
# Channel layout (canonical sealed root)
#   outbox/<target>/          signed jobs (origin → target)
#   ack/                      status acks (origin then target rewrite)
#   results/                  target-signed results
#   outputs/                  target-signed raw job output bodies
#   journal/                  append-only state ledger (+ rejects/)
#   cancel/                   cancel signals
#   readiness/manifests/      target-signed readiness advertisements (target → origin)
#   signatures/{jobs,acks,results,journals,outputs,commit-markers}/
#
# SECURITY IRON RULES (enforced flags; do not weaken)
#   - NEVER pass rsync --delete (would roll back newer signed products).
#   - NEVER pass rsync -E / --xattrs (openrsync provenance EPERM class of failures).
#   - Prefer append/update: -rt --update (source newer wins; never wipe receiver).
#   - Immutable artifacts (outbox jobs, results) stay safe under --update because
#     producers do not rewrite them with older content; journals/acks use mtime.
#   - Quote all paths (spaces in "Application Support" etc.).
#   - ssh ConnectTimeout + overall timeout.
#   - Idempotent re-runs must not break local consume high-water (Keychain, not synced).
#
# Usage
#   scripts/tatwo-remote-channel-sync.sh push \
#     --local-channel <origin-channel> --remote-channel <target-channel> \
#     [--remote-host user@host] [--timeout-sec 120] [--dry-run]
#   scripts/tatwo-remote-channel-sync.sh pull \
#     --local-channel <origin-channel> --remote-channel <target-channel> \
#     [--remote-host user@host] [--timeout-sec 120] [--dry-run]
#   scripts/tatwo-remote-channel-sync.sh self-check   # local two-dir simulation
#
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
MODE=""
LOCAL_CHANNEL=""
REMOTE_CHANNEL=""
REMOTE_HOST=""
TIMEOUT_SEC=120
DRY_RUN=0
SSH_CONNECT_TIMEOUT=10

die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 2
}

usage() {
  cat >&2 <<'EOF'
Use:
  tatwo-remote-channel-sync.sh push  --local-channel <path> --remote-channel <path> [--remote-host user@host]
  tatwo-remote-channel-sync.sh pull  --local-channel <path> --remote-channel <path> [--remote-host user@host]
  tatwo-remote-channel-sync.sh self-check

Options:
  --local-channel <path>    Sealed channel root on this host (required for push/pull)
  --remote-channel <path>   Sealed channel root on peer (or second local dir)
  --remote-host <user@h>    Optional ssh target; omit for local-to-local
  --timeout-sec <N>         Overall wall timeout (default 120)
  --dry-run                 rsync dry-run only
  -h|--help                 This help

Security flags (hard-coded; not optional):
  rsync: -rt --update --human-readable   (NO --delete, NO -E/xattrs)
  ssh:   -o ConnectTimeout=10 -o BatchMode=yes
EOF
  exit 2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

# Refuse known-dangerous flag injection via env wrappers.
assert_safe_rsync_plan() {
  local plan="$1"
  if printf '%s' "$plan" | grep -Eq -- '(^|[[:space:]])--delete($|[[:space:]=])'; then
    die "refusing rsync plan that contains --delete"
  fi
  if printf '%s' "$plan" | grep -Eq -- '(^|[[:space:]])-E($|[[:space:]])|(^|[[:space:]])--xattrs?($|[[:space:]])'; then
    die "refusing rsync plan that contains -E/--xattr (openrsync provenance EPERM class)"
  fi
}

# Build "src/" style trailing slash for directory contents.
dir_slash() {
  local p="$1"
  case "$p" in
    */) printf '%s' "$p" ;;
    *) printf '%s/' "$p" ;;
  esac
}

# Remote or local destination path for rsync.
# When REMOTE_HOST is set, path is user@host:"quoted path".
remote_dest() {
  local path="$1"
  if [[ -n "$REMOTE_HOST" ]]; then
    # rsync remote path: quote for remote shell; spaces in Application Support.
    printf '%s:%s' "$REMOTE_HOST" "$(printf '%q' "$path")"
  else
    printf '%s' "$path"
  fi
}

remote_src() {
  local path="$1"
  if [[ -n "$REMOTE_HOST" ]]; then
    printf '%s:%s' "$REMOTE_HOST" "$(printf '%q' "$path")"
  else
    printf '%s' "$path"
  fi
}

run_rsync() {
  local src="$1"
  local dst="$2"
  shift 2
  local -a extras=("$@")
  local -a flags=(-rt --update --human-readable)
  if [[ "$DRY_RUN" == "1" ]]; then
    flags+=(--dry-run)
  fi
  # Explicit: never --delete, never -E.
  local plan
  plan="$(printf '%s ' "${flags[@]}")${extras[*]+${extras[*]} }$src -> $dst"
  assert_safe_rsync_plan "$plan"

  local -a cmd=(rsync "${flags[@]}")
  if [[ -n "$REMOTE_HOST" ]]; then
    cmd+=(-e "ssh -o ConnectTimeout=${SSH_CONNECT_TIMEOUT} -o BatchMode=yes -o StrictHostKeyChecking=accept-new")
  fi
  cmd+=("${extras[@]+"${extras[@]}"}" "$src" "$dst")

  if command -v timeout >/dev/null 2>&1; then
    timeout --signal=TERM "$TIMEOUT_SEC" "${cmd[@]}"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout --signal=TERM "$TIMEOUT_SEC" "${cmd[@]}"
  else
    # macOS without GNU timeout: best-effort via background + wait.
    "${cmd[@]}" &
    local pid=$!
    local elapsed=0
    while kill -0 "$pid" 2>/dev/null; do
      if (( elapsed >= TIMEOUT_SEC )); then
        kill -TERM "$pid" 2>/dev/null || true
        sleep 1
        kill -KILL "$pid" 2>/dev/null || true
        die "rsync timed out after ${TIMEOUT_SEC}s"
      fi
      sleep 1
      elapsed=$((elapsed + 1))
    done
    wait "$pid"
  fi
}

# Sync one relative subdirectory if present on source.
sync_subdir_push() {
  local rel="$1"
  local local_root="$2"
  local remote_root="$3"
  local src="${local_root%/}/${rel}"
  [[ -d "$src" ]] || return 0
  local dst_parent
  dst_parent="$(remote_dest "${remote_root%/}/")"
  # Ensure parent exists on remote for nested paths.
  if [[ -z "$REMOTE_HOST" ]]; then
    mkdir -p "${remote_root%/}/${rel}"
  else
    ssh -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" -o BatchMode=yes "$REMOTE_HOST" \
      "mkdir -p $(printf '%q' "${remote_root%/}/${rel}")" </dev/null
  fi
  run_rsync "$(dir_slash "$src")" "$(remote_dest "${remote_root%/}/${rel}/")"
}

sync_subdir_pull() {
  local rel="$1"
  local local_root="$2"
  local remote_root="$3"
  mkdir -p "${local_root%/}/${rel}"
  # Probe remote presence (local or ssh).
  if [[ -z "$REMOTE_HOST" ]]; then
    [[ -d "${remote_root%/}/${rel}" ]] || return 0
  else
    if ! ssh -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" -o BatchMode=yes "$REMOTE_HOST" \
      "test -d $(printf '%q' "${remote_root%/}/${rel}")" </dev/null; then
      return 0
    fi
  fi
  run_rsync "$(remote_src "${remote_root%/}/${rel}/")" "$(dir_slash "${local_root%/}/${rel}")"
}

do_push() {
  local local_root="$1"
  local remote_root="$2"
  [[ -d "$local_root" ]] || die "local channel missing: $local_root"
  # Origin → target: jobs (outbox), origin acks/journals, cancel, job/ack/journal signatures.
  # (User-facing "jobs/" maps to channel outbox/.)
  # NEVER push fleet origin-writable control-plane state (queue/assignments/commits/ledger/
  # devices/high-water/scheduler-state). Those are origin-only.
  local -a push_dirs=(
    outbox
    ack
    journal
    cancel
    commit-markers
    skillet
    signatures/jobs
    signatures/acks
    signatures/journals
    signatures/commit-markers
    signatures/skillet
  )
  local rel
  for rel in "${push_dirs[@]}"; do
    sync_subdir_push "$rel" "$local_root" "$remote_root"
  done
  printf 'channel_sync=push ok local=%q remote=%q host=%q dry_run=%s\n' \
    "$local_root" "$remote_root" "${REMOTE_HOST:-local}" "$DRY_RUN"
}

do_pull() {
  local local_root="$1"
  local remote_root="$2"
  [[ -d "$local_root" ]] || die "local channel missing: $local_root"
  # Target → origin: results, raw outputs, updated journals/acks, their signatures,
  # target-signed readiness manifests, and target-signed fleet device reports
  # under fleet/ingest/devices only.
  # NEVER pull/bi-sync fleet/{devices,queue,assignments,commits,ledger,high-water,scheduler-state}.
  local -a pull_dirs=(
    results
    outputs
    ack
    journal
    readiness/manifests
    skillet
    signatures/results
    signatures/outputs
    signatures/acks
    signatures/journals
    signatures/skillet
    fleet/ingest/devices
  )
  local rel
  for rel in "${pull_dirs[@]}"; do
    sync_subdir_pull "$rel" "$local_root" "$remote_root"
  done
  printf 'channel_sync=pull ok local=%q remote=%q host=%q dry_run=%s\n' \
    "$local_root" "$remote_root" "${REMOTE_HOST:-local}" "$DRY_RUN"
}

# Local two-directory simulation (no network). Verifies no --delete / -E and idempotency.
self_check() {
  require_cmd rsync
  local root
  root="$(mktemp -d "${TMPDIR:-/tmp}/tatwo-channel-sync-selfcheck.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf $(printf '%q' "$root")" RETURN

  local origin="$root/origin-channel"
  local target="$root/target-channel"
  mkdir -p \
    "$origin/outbox/runner-a" \
    "$origin/ack" \
    "$origin/journal" \
    "$origin/signatures/jobs/runner-a" \
    "$origin/signatures/acks" \
    "$origin/signatures/journals" \
    "$origin/skillet/outbox/macbook/req-selfcheck" \
    "$origin/signatures/skillet/macbook" \
    "$target/outbox" \
    "$target/results" \
    "$target/outputs" \
    "$target/ack" \
    "$target/journal" \
    "$target/readiness/manifests/runner-a/claude" \
    "$target/signatures/results" \
    "$target/signatures/outputs" \
    "$target/signatures/acks" \
    "$target/signatures/journals"

  printf '{"schemaVersion":1,"purpose":"skillet-bundle","requestID":"req-selfcheck"}\n' \
    >"$origin/skillet/outbox/macbook/req-selfcheck/set.json"
  printf '{"purpose":"skillet-bundle","requestID":"req-selfcheck"}\n' \
    >"$origin/signatures/skillet/macbook/req-selfcheck.json"
  printf '{"jobID":"job-1","v":1}\n' >"$origin/outbox/runner-a/job-1.json"
  printf '{"sig":"origin-job-1"}\n' >"$origin/signatures/jobs/runner-a/job-1.json"
  printf '{"jobID":"job-1","status":"queued"}\n' >"$origin/ack/job-1.json"
  printf 'queued\n' >"$origin/journal/job-1.jsonl"
  # Immutable "already present" on target must not be clobbered by older/equal source under --update.
  printf '{"jobID":"job-1","status":"running","seq":2}\n' >"$target/ack/job-1.json"
  printf 'queued\nrunning\n' >"$target/journal/job-1.jsonl"
  printf '{"status":"completed"}\n' >"$target/results/job-1.json"
  printf '{"sig":"target-result-1"}\n' >"$target/signatures/results/job-1.json"
  printf 'hello-from-target\n' >"$target/outputs/job-1"
  printf '{"sig":"target-output-1"}\n' >"$target/signatures/outputs/job-1.json"
  printf '{"schema":"TatwoRemoteDispatchReadinessManifestV1","targetDeviceID":"runner-a"}\n' \
    >"$target/readiness/manifests/runner-a/claude/route-test.json"
  # Marker that must survive (no --delete).
  printf 'keep-me\n' >"$target/outbox/keep-marker.txt"

  MODE=push
  DRY_RUN=0
  REMOTE_HOST=""
  do_push "$origin" "$target"

  [[ -f "$target/outbox/runner-a/job-1.json" ]] || die "self-check: job not pushed"
  [[ -f "$target/skillet/outbox/macbook/req-selfcheck/set.json" ]] \
    || die "self-check: skillet lane set not pushed"
  [[ -f "$target/signatures/skillet/macbook/req-selfcheck.json" ]] \
    || die "self-check: skillet-bundle signature not pushed"
  [[ -f "$target/outbox/keep-marker.txt" ]] || die "self-check: --delete-like wipe of keep-marker"
  # Target's newer/longer journal must not shrink on push of older origin journal under --update.
  # (mtime: touch origin older)
  # After push, target ack may stay as running if mtime newer — either way file exists.
  [[ -f "$target/ack/job-1.json" ]] || die "self-check: ack missing on target"

  MODE=pull
  do_pull "$origin" "$target"
  [[ -f "$origin/results/job-1.json" ]] || die "self-check: result not pulled"
  [[ -f "$origin/signatures/results/job-1.json" ]] || die "self-check: result signature not pulled"
  [[ -f "$origin/outputs/job-1" ]] || die "self-check: output body not pulled"
  [[ -f "$origin/signatures/outputs/job-1.json" ]] || die "self-check: output signature not pulled"
  [[ -f "$origin/readiness/manifests/runner-a/claude/route-test.json" ]] \
    || die "self-check: readiness manifest not pulled"

  # Idempotent second pass.
  do_push "$origin" "$target"
  do_pull "$origin" "$target"
  [[ -f "$target/outbox/keep-marker.txt" ]] || die "self-check: keep-marker lost after re-run"
  [[ -f "$origin/results/job-1.json" ]] || die "self-check: result lost after re-run"
  [[ -f "$origin/outputs/job-1" ]] || die "self-check: output body lost after re-run"
  [[ -f "$origin/readiness/manifests/runner-a/claude/route-test.json" ]] \
    || die "self-check: readiness manifest lost after re-run"

  # Dry-run must not create new artifacts.
  local ghost="$root/ghost"
  mkdir -p "$ghost"
  DRY_RUN=1
  do_push "$origin" "$ghost"
  # ghost may get empty dirs depending on mkdir path; no job payload.
  if [[ -f "$ghost/outbox/runner-a/job-1.json" ]]; then
    die "self-check: dry-run wrote job payload"
  fi

  # Plan safety unit (string check).
  assert_safe_rsync_plan "rsync -rt --update src/ dst/"
  if (set +e; assert_safe_rsync_plan "rsync -rt --delete src/ dst/" 2>/dev/null); then
    die "self-check: --delete plan should have been refused"
  fi
  if (set +e; assert_safe_rsync_plan "rsync -rt -E src/ dst/" 2>/dev/null); then
    die "self-check: -E plan should have been refused"
  fi

  printf 'channel_sync=self-check ok root=%q\n' "$root"
}

# --- argv ---
[[ $# -ge 1 ]] || usage
case "$1" in
  -h|--help) usage ;;
  push|pull|self-check)
    MODE="$1"
    shift
    ;;
  *)
    die "unknown mode: $1 (use push|pull|self-check)"
    ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-channel)
      [[ $# -ge 2 ]] || die "missing value for $1"
      LOCAL_CHANNEL="$2"
      shift 2
      ;;
    --remote-channel)
      [[ $# -ge 2 ]] || die "missing value for $1"
      REMOTE_CHANNEL="$2"
      shift 2
      ;;
    --remote-host)
      [[ $# -ge 2 ]] || die "missing value for $1"
      REMOTE_HOST="$2"
      shift 2
      ;;
    --timeout-sec)
      [[ $# -ge 2 ]] || die "missing value for $1"
      TIMEOUT_SEC="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

require_cmd rsync

case "$MODE" in
  self-check)
    self_check
    ;;
  push)
    [[ -n "$LOCAL_CHANNEL" ]] || die "missing --local-channel"
    [[ -n "$REMOTE_CHANNEL" ]] || die "missing --remote-channel"
    do_push "$LOCAL_CHANNEL" "$REMOTE_CHANNEL"
    ;;
  pull)
    [[ -n "$LOCAL_CHANNEL" ]] || die "missing --local-channel"
    [[ -n "$REMOTE_CHANNEL" ]] || die "missing --remote-channel"
    do_pull "$LOCAL_CHANNEL" "$REMOTE_CHANNEL"
    ;;
esac
