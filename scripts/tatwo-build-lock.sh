#!/usr/bin/env bash
# tatwo-build-lock.sh — build lock with atomic publication + ownership token hash
# Default lock path: /tmp/tatwo-build.lock
# Override: TATWO_BUILD_LOCK_DIR=/path/to/lock.dir
#
# Guarantees (F1 / SOL1-A1 + F8 / SOL2-MF1):
# 1. Atomic publication: observers never see a partial lock directory.
# 2. Release authorization is a secret token held only by the acquirer;
#    the lock directory stores SHA-256(token) only (never plaintext).
# 3. Release pre-checks the hash before unpublishing; mv-aside only after
#    precheck pass. Post-aside mismatch (race) quarantines — never restores
#    into the public namespace (fail-closed; no dual-hold).
set -euo pipefail

LOCK_DIR="${TATWO_BUILD_LOCK_DIR:-/tmp/tatwo-build.lock}"
POLL_INTERVAL=5
SUSPECT_TIMEOUT="${TATWO_BUILD_LOCK_SUSPECT_TIMEOUT:-120}"

# Exit codes:
#   0 success
#   1 general failure / refuse / timeout
#   2 usage / missing required args
#   7 release post-aside token mismatch → lock quarantined (not restored)

usage() {
  cat >&2 <<'EOF'
Usage:
  tatwo-build-lock.sh acquire [--timeout SECONDS] [--pid PID]
  tatwo-build-lock.sh release --token TOKEN [--pid PID]
  tatwo-build-lock.sh status
  tatwo-build-lock.sh --selftest

Environment:
  TATWO_BUILD_LOCK_DIR              Override lock directory (default: /tmp/tatwo-build.lock)
  TATWO_BUILD_LOCK_TOKEN            Token for release (alternative to --token)
  TATWO_BUILD_LOCK_TOKEN_FILE       On acquire: write token to this file.
                                    On release: read token if --token / env unset.
  TATWO_BUILD_LOCK_SUSPECT_TIMEOUT  Seconds before incomplete/bare locks may be
                                    taken over (default: 120)

Acquire prints a line "token=..." on stdout (secret; caller must retain it).
The lock directory stores only owner.token.sha256 (SHA-256 of the token).
Release requires the matching plaintext token; PID is diagnostic display only.
EOF
  exit 2
}

iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

unix_now() {
  date +%s
}

is_valid_pid() {
  local pid="$1"
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]]
}

is_pid_alive() {
  local pid="$1"
  is_valid_pid "$pid" || return 1
  # kill -0: existence/permission probe; fails for dead or unreapable foreign PIDs
  kill -0 "$pid" 2>/dev/null
}

is_valid_token() {
  local t="$1"
  # ≥16 bytes hex → ≥32 hex chars; allow longer.
  [[ -n "$t" && "$t" =~ ^[0-9a-fA-F]{32,}$ ]]
}

is_valid_token_hash() {
  local h="$1"
  [[ -n "$h" && "$h" =~ ^[0-9a-f]{64}$ ]]
}

# SHA-256 of the raw token string (no trailing newline). Lowercase hex.
token_sha256() {
  local t="$1" digest
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s' "$t" | shasum -a 256 2>/dev/null | awk '{print $1}')
  elif command -v openssl >/dev/null 2>&1; then
    digest=$(printf '%s' "$t" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')
  elif command -v python3 >/dev/null 2>&1; then
    digest=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())' "$t" 2>/dev/null)
  else
    echo "error: no sha256 tool (need shasum, openssl, or python3)" >&2
    return 1
  fi
  digest=$(printf '%s' "$digest" | tr 'A-F' 'a-f' | tr -d '[:space:]')
  if ! is_valid_token_hash "$digest"; then
    echo "error: failed to hash ownership token" >&2
    return 1
  fi
  printf '%s\n' "$digest"
}

generate_token() {
  # 16 bytes from /dev/urandom as lowercase hex (32 chars).
  local raw
  if raw=$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n'); then
    if is_valid_token "$raw"; then
      printf '%s\n' "$raw"
      return 0
    fi
  fi
  # Fallback: dd + od (some environments restrict head on devices)
  raw=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
  if ! is_valid_token "$raw"; then
    echo "error: failed to generate ownership token from /dev/urandom" >&2
    return 1
  fi
  printf '%s\n' "$raw"
}

path_mtime() {
  local p="$1" mtime
  if mtime=$(stat -f %m "$p" 2>/dev/null); then
    printf '%s\n' "$mtime"
    return 0
  fi
  if mtime=$(stat -c %Y "$p" 2>/dev/null); then
    printf '%s\n' "$mtime"
    return 0
  fi
  return 1
}

# Read helpers accept optional base dir (default LOCK_DIR) so release can
# inspect an mv-aside private path of the same inode tree.
read_owner_pid() {
  local base="${1:-$LOCK_DIR}"
  local f="$base/owner.pid"
  if [[ ! -f "$f" ]]; then
    echo ""
    return 0
  fi
  tr -d '[:space:]' <"$f" || true
}

read_owner_host() {
  local base="${1:-$LOCK_DIR}"
  local f="$base/hostname" line
  if [[ ! -f "$f" ]]; then
    echo "?"
    return 0
  fi
  IFS= read -r line <"$f" || true
  line=${line%$'\r'}
  printf '%s\n' "${line:-?}"
}

read_acquired_at() {
  local base="${1:-$LOCK_DIR}"
  local f="$base/acquired_at"
  if [[ ! -f "$f" ]]; then
    echo "?"
    return 0
  fi
  tr -d '[:space:]' <"$f" || true
}

# Stored credential is SHA-256 only — never plaintext owner.token.
read_owner_token_hash() {
  local base="${1:-$LOCK_DIR}"
  local f="$base/owner.token.sha256"
  if [[ ! -f "$f" ]]; then
    echo ""
    return 0
  fi
  tr -d '[:space:]' <"$f" | tr 'A-F' 'a-f' || true
}

token_matches_stored() {
  local claimed="$1"
  local base="${2:-$LOCK_DIR}"
  local stored claimed_hash
  stored=$(read_owner_token_hash "$base")
  is_valid_token_hash "$stored" || return 1
  claimed_hash=$(token_sha256 "$claimed") || return 1
  [[ "$claimed_hash" == "$stored" ]]
}

hold_duration_seconds() {
  local base="${1:-$LOCK_DIR}"
  local f="$base/acquired_at"
  if [[ ! -f "$f" ]]; then
    echo "?"
    return 0
  fi
  local mtime now
  if ! mtime=$(path_mtime "$f"); then
    echo "?"
    return 0
  fi
  now=$(unix_now)
  echo $((now - mtime))
}

# Complete metadata: pid valid, host non-empty, acquired_at non-empty, token hash valid.
metadata_complete() {
  local base="${1:-$LOCK_DIR}"
  local pid host acq thash
  pid=$(read_owner_pid "$base")
  host=$(read_owner_host "$base")
  acq=$(read_acquired_at "$base")
  thash=$(read_owner_token_hash "$base")
  is_valid_pid "$pid" || return 1
  [[ -n "$host" && "$host" != "?" ]] || return 1
  [[ -n "$acq" && "$acq" != "?" ]] || return 1
  is_valid_token_hash "$thash" || return 1
  # Fail closed if legacy plaintext token file still present (must never publish).
  [[ ! -e "$base/owner.token" ]] || return 1
  return 0
}

write_owner_metadata_into() {
  local dest="$1"
  local pid="$2"
  local token="$3"
  local host thash
  thash=$(token_sha256 "$token") || return 1
  printf '%s\n' "$pid" >"$dest/owner.pid"
  host=$(hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)
  printf '%s\n' "$host" >"$dest/hostname"
  printf '%s\n' "$(iso_now)" >"$dest/acquired_at"
  printf '%s\n' "$thash" >"$dest/owner.token.sha256"
  # Never write plaintext owner.token into the lock tree.
  rm -f "$dest/owner.token" 2>/dev/null || true
}

clear_lock_dir_contents() {
  # Never rm -rf the lock tree. Remove known metadata files then rmdir.
  local d="$1"
  [[ -d "$d" ]] || return 0
  rm -f "$d/owner.pid" "$d/hostname" "$d/acquired_at" \
    "$d/owner.token" "$d/owner.token.sha256" 2>/dev/null || true
}

discard_private_dir() {
  local d="$1"
  [[ -d "$d" ]] || return 0
  clear_lock_dir_contents "$d"
  rmdir "$d" 2>/dev/null || true
}

# Atomic directory rename that FAILS if destination already exists.
# Do NOT use shell `mv` for the public claim path: on macOS/BSD, `mv src existing_dir`
# nests src *into* existing_dir (success) instead of exclusive rename.
#
# Also: bare rename(2) on macOS *succeeds* when dst is an *empty* directory (replaces it).
# That would let a publisher silently clobber a bare-mkdir suspect lock. Publish must
# refuse any pre-existing dst. We serialize with O_EXCL claim file + exists check + rename.
atomic_rename_dir() {
  local src="$1"
  local dst="$2"
  if [[ ! -d "$src" ]]; then
    return 1
  fi
  # Unique target (stale/release aside): dest must not exist; plain rename is enough.
  if [[ ! -e "$dst" ]]; then
    if command -v python3 >/dev/null 2>&1; then
      python3 -c 'import os,sys; os.rename(sys.argv[1], sys.argv[2])' "$src" "$dst" 2>/dev/null && return 0
      return 1
    fi
    mv "$src" "$dst" 2>/dev/null
    return $?
  fi
  return 1
}

# Publish private→public only when public name is absent. Exclusive claim file closes
# the check-to-rename race between two publishers; never replaces existing dst.
atomic_publish_lock_dir() {
  local src="$1"
  local dst="$2"
  local claim="${dst}.claiming"
  if [[ ! -d "$src" ]]; then
    return 1
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$src" "$dst" "$claim" <<'PY'
import os, sys
src, dst, claim = sys.argv[1], sys.argv[2], sys.argv[3]
fd = None
try:
    fd = os.open(claim, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
except OSError:
    sys.exit(1)
try:
    if os.path.exists(dst):
        sys.exit(1)
    os.rename(src, dst)
    sys.exit(0)
except OSError:
    sys.exit(1)
finally:
    if fd is not None:
        try:
            os.close(fd)
        except OSError:
            pass
    try:
        os.unlink(claim)
    except OSError:
        pass
PY
    return $?
  fi
  # Fallback without python: mkdir claim-as-dir exclusive, then exists check + mv.
  if ! mkdir "$claim" 2>/dev/null; then
    return 1
  fi
  if [[ -e "$dst" ]]; then
    rmdir "$claim" 2>/dev/null || true
    return 1
  fi
  if mv "$src" "$dst" 2>/dev/null; then
    rmdir "$claim" 2>/dev/null || true
    return 0
  fi
  rmdir "$claim" 2>/dev/null || true
  return 1
}

# Age of a lock path for suspect timeout (directory mtime).
lock_age_seconds() {
  local base="${1:-$LOCK_DIR}"
  local mtime now
  if ! mtime=$(path_mtime "$base"); then
    echo 0
    return 0
  fi
  now=$(unix_now)
  echo $((now - mtime))
}

# Stale (immediate takeover): complete metadata AND owner PID is dead.
is_lock_stale() {
  local base="${1:-$LOCK_DIR}"
  local pid
  metadata_complete "$base" || return 1
  pid=$(read_owner_pid "$base")
  if is_pid_alive "$pid"; then
    return 1
  fi
  return 0
}

# Suspect: directory present but metadata incomplete (bare mkdir / partial / legacy).
is_lock_suspect() {
  local base="${1:-$LOCK_DIR}"
  [[ -d "$base" ]] || return 1
  if metadata_complete "$base"; then
    return 1
  fi
  return 0
}

suspect_timeout_elapsed() {
  local base="${1:-$LOCK_DIR}"
  local age timeout_s
  timeout_s="${SUSPECT_TIMEOUT}"
  if ! [[ "$timeout_s" =~ ^[0-9]+$ ]]; then
    timeout_s=120
  fi
  age=$(lock_age_seconds "$base")
  [[ "$age" -ge "$timeout_s" ]]
}

safe_takeover_mv_aside() {
  # Move whole lock dir aside; never rm -rf. Used for stale and aged-suspect.
  local reason="$1"
  local owner host acquired age stale_path ts
  owner=$(read_owner_pid)
  host=$(read_owner_host)
  acquired=$(read_acquired_at)
  age=$(lock_age_seconds)
  ts=$(unix_now)
  stale_path="${LOCK_DIR}.stale.${ts}.$$"

  # Target name is unique; plain rename is fine. Prefer atomic helper for consistency.
  if atomic_rename_dir "$LOCK_DIR" "$stale_path"; then
    printf 'takeover: %s owner.pid=%s host=%s acquired_at=%s age_s=%s moved_to=%s\n' \
      "$reason" "${owner:-?}" "${host:-?}" "${acquired:-?}" "${age:-?}" "$stale_path"
    return 0
  fi
  # Lost race (another process already moved/took it).
  return 1
}

emit_token_outputs() {
  local token="$1"
  printf 'token=%s\n' "$token"
  if [[ -n "${TATWO_BUILD_LOCK_TOKEN_FILE:-}" ]]; then
    # Restrictive perms; overwrite destination atomically via temp in same dir when possible.
    local tf="$TATWO_BUILD_LOCK_TOKEN_FILE"
    local tdir ttmp
    tdir=$(dirname "$tf")
    if [[ -d "$tdir" ]]; then
      ttmp=$(mktemp "${tdir}/.tatwo-build-lock-token.XXXXXX")
      printf '%s\n' "$token" >"$ttmp"
      chmod 600 "$ttmp" 2>/dev/null || true
      mv "$ttmp" "$tf"
      chmod 600 "$tf" 2>/dev/null || true
    else
      printf '%s\n' "$token" >"$tf"
      chmod 600 "$tf" 2>/dev/null || true
    fi
  fi
}

try_publish_lock() {
  # Build private temp dir on same filesystem (same parent), write full metadata,
  # then single atomic mv into LOCK_DIR. Any observer seeing LOCK_DIR has complete metadata.
  local pid="$1"
  local parent private token host
  parent=$(dirname "$LOCK_DIR")
  if [[ ! -d "$parent" ]]; then
    echo "error: cannot create lock dir $LOCK_DIR (parent missing or permission denied)" >&2
    return 2
  fi

  private=$(mktemp -d "${parent}/.tatwo-build.lock.pub.XXXXXX") || return 1
  token=$(generate_token) || {
    discard_private_dir "$private"
    return 1
  }
  write_owner_metadata_into "$private" "$pid" "$token" || {
    discard_private_dir "$private"
    return 1
  }

  if atomic_publish_lock_dir "$private" "$LOCK_DIR"; then
    # Sanity: public path must expose hash only (never plaintext token).
    if [[ ! -f "$LOCK_DIR/owner.token.sha256" ]]; then
      echo "error: publish invariant broken (owner.token.sha256 missing after rename)" >&2
      discard_private_dir "$private"
      return 1
    fi
    if [[ -e "$LOCK_DIR/owner.token" ]]; then
      echo "error: publish invariant broken (plaintext owner.token must not exist)" >&2
      discard_private_dir "$private"
      return 1
    fi
    host=$(read_owner_host)
    printf 'acquired: pid=%s host=%s lock=%s acquired_at=%s\n' \
      "$pid" "$host" "$LOCK_DIR" "$(read_acquired_at)"
    emit_token_outputs "$token"
    return 0
  fi

  # Publication lost the race; discard private (never public partial).
  discard_private_dir "$private"
  return 1
}

parse_acquire_args() {
  ARG_PID="${PPID}"
  ARG_TIMEOUT=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pid)
        [[ $# -ge 2 ]] || { echo "error: --pid requires a value" >&2; exit 2; }
        ARG_PID="$2"
        shift 2
        ;;
      --timeout)
        [[ $# -ge 2 ]] || { echo "error: --timeout requires a value" >&2; exit 2; }
        ARG_TIMEOUT="$2"
        shift 2
        ;;
      -h|--help)
        usage
        ;;
      *)
        echo "error: unknown argument: $1" >&2
        usage
        ;;
    esac
  done
  if ! is_valid_pid "$ARG_PID"; then
    echo "error: invalid pid: $ARG_PID" >&2
    exit 2
  fi
  if [[ -n "$ARG_TIMEOUT" ]]; then
    if ! [[ "$ARG_TIMEOUT" =~ ^[0-9]+$ ]]; then
      echo "error: --timeout must be a non-negative integer (seconds)" >&2
      exit 2
    fi
  fi
}

parse_release_args() {
  ARG_PID=""
  ARG_TOKEN="${TATWO_BUILD_LOCK_TOKEN:-}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pid)
        [[ $# -ge 2 ]] || { echo "error: --pid requires a value" >&2; exit 2; }
        ARG_PID="$2"
        shift 2
        ;;
      --token)
        [[ $# -ge 2 ]] || { echo "error: --token requires a value" >&2; exit 2; }
        ARG_TOKEN="$2"
        shift 2
        ;;
      -h|--help)
        usage
        ;;
      *)
        echo "error: unknown argument: $1" >&2
        usage
        ;;
    esac
  done
  # Optional: read token from file if still unset
  if [[ -z "$ARG_TOKEN" && -n "${TATWO_BUILD_LOCK_TOKEN_FILE:-}" && -f "${TATWO_BUILD_LOCK_TOKEN_FILE}" ]]; then
    ARG_TOKEN=$(tr -d '[:space:]' <"$TATWO_BUILD_LOCK_TOKEN_FILE" || true)
  fi
  if [[ -z "$ARG_TOKEN" ]]; then
    echo "error: release requires --token or TATWO_BUILD_LOCK_TOKEN (or TATWO_BUILD_LOCK_TOKEN_FILE)" >&2
    exit 2
  fi
  if [[ -n "$ARG_PID" ]] && ! is_valid_pid "$ARG_PID"; then
    echo "error: invalid pid: $ARG_PID" >&2
    exit 2
  fi
}

cmd_acquire() {
  parse_acquire_args "$@"
  local pid="$ARG_PID"
  local timeout_s="$ARG_TIMEOUT"
  local start_ts now elapsed
  local last_suspect_warn=0

  start_ts=$(unix_now)

  while true; do
    local pub_rc=0
    try_publish_lock "$pid" || pub_rc=$?
    if [[ "$pub_rc" -eq 0 ]]; then
      return 0
    fi
    # try_publish_lock returns 2 for hard parent/permission error
    if [[ "$pub_rc" -eq 2 ]]; then
      return 1
    fi

    if [[ ! -d "$LOCK_DIR" && ! -e "$LOCK_DIR" ]]; then
      # Race: someone released between our failed mv and now, or transient.
      sleep 1
      continue
    fi

    if [[ -e "$LOCK_DIR" && ! -d "$LOCK_DIR" ]]; then
      echo "error: lock path exists but is not a directory: $LOCK_DIR" >&2
      return 1
    fi

    if [[ -d "$LOCK_DIR" ]] && is_lock_stale; then
      if safe_takeover_mv_aside "stale"; then
        continue
      fi
      sleep 1
      continue
    fi

    if [[ -d "$LOCK_DIR" ]] && is_lock_suspect; then
      if suspect_timeout_elapsed; then
        if safe_takeover_mv_aside "suspect-timeout"; then
          continue
        fi
        sleep 1
        continue
      fi
      now=$(unix_now)
      if [[ $((now - last_suspect_warn)) -ge "$POLL_INTERVAL" ]]; then
        printf 'warning: suspect lock (incomplete metadata) at %s age_s=%s wait_until=%ss\n' \
          "$LOCK_DIR" "$(lock_age_seconds)" "${SUSPECT_TIMEOUT}" >&2
        last_suspect_warn=$now
      fi
    fi

    # Live holder (complete + alive) or young suspect — wait / timeout
    if [[ -n "$timeout_s" ]]; then
      now=$(unix_now)
      elapsed=$((now - start_ts))
      if [[ "$elapsed" -ge "$timeout_s" ]]; then
        local opid ohost oacq alive meta
        opid=$(read_owner_pid)
        ohost=$(read_owner_host)
        oacq=$(read_acquired_at)
        alive="no"
        if is_valid_pid "$opid" && is_pid_alive "$opid"; then
          alive="yes"
        fi
        meta="incomplete"
        if metadata_complete; then
          meta="complete"
        fi
        printf 'error: acquire timeout after %ss; holder pid=%s alive=%s meta=%s host=%s acquired_at=%s lock=%s\n' \
          "$timeout_s" "${opid:-?}" "$alive" "$meta" "${ohost:-?}" "${oacq:-?}" "$LOCK_DIR" >&2
        return 1
      fi
    fi

    sleep "$POLL_INTERVAL"
  done
}

quarantine_release_aside() {
  # Never restore into the public namespace after a failed post-aside verify.
  local release_path="$1"
  local ts="$2"
  local q_path="${LOCK_DIR}.quarantine.${ts}.$$"
  if atomic_rename_dir "$release_path" "$q_path"; then
    printf '%s\n' "$q_path"
    return 0
  fi
  # Keep aside path as quarantine location if rename failed.
  printf '%s\n' "$release_path"
  return 0
}

cmd_release() {
  parse_release_args "$@"
  local token="$ARG_TOKEN"
  local declared_pid="${ARG_PID:-}"

  if [[ ! -d "$LOCK_DIR" ]]; then
    echo "error: no lock held at $LOCK_DIR" >&2
    return 1
  fi

  local host acquired actual_pid stored_hash

  # --- Precheck (public path still fenced): refuse wrong token without unpublishing ---
  host=$(read_owner_host)
  acquired=$(read_acquired_at)
  actual_pid=$(read_owner_pid)
  stored_hash=$(read_owner_token_hash)

  if ! token_matches_stored "$token" "$LOCK_DIR"; then
    printf 'error: release refused; token mismatch (precheck; lock untouched) holder_pid=%s host=%s acquired_at=%s declared_pid=%s\n' \
      "${actual_pid:-?}" "${host:-?}" "${acquired:-?}" "${declared_pid:-none}" >&2
    return 1
  fi

  # Precheck passed — remove from public namespace, then re-verify on the same inode tree.
  local ts release_path
  ts=$(unix_now)
  release_path="${LOCK_DIR}.release.${ts}.$$"

  if ! atomic_rename_dir "$LOCK_DIR" "$release_path"; then
    echo "error: no lock held at $LOCK_DIR (lost race or missing)" >&2
    return 1
  fi

  host=$(read_owner_host "$release_path")
  acquired=$(read_acquired_at "$release_path")
  actual_pid=$(read_owner_pid "$release_path")

  local post_ok=1
  # Test-only inject: force post-aside mismatch (race path) without changing precheck.
  if [[ "${TATWO_BUILD_LOCK_TEST_INJECT_POST_MISMATCH:-}" == "1" ]]; then
    post_ok=0
  elif ! token_matches_stored "$token" "$release_path"; then
    post_ok=0
  fi

  if [[ "$post_ok" -ne 1 ]]; then
    # Fail-closed: NEVER mv back into the public namespace (avoids dual-hold / overwrite).
    local q_path
    q_path=$(quarantine_release_aside "$release_path" "$ts")
    printf 'error: release refused (token mismatch after mv-aside); quarantine=%s holder_pid=%s host=%s acquired_at=%s declared_pid=%s\n' \
      "$q_path" "${actual_pid:-?}" "${host:-?}" "${acquired:-?}" "${declared_pid:-none}" >&2
    printf 'error: 鎖已被本次錯誤 release 摘走，持有者需重新 acquire (lock removed from public path by this failed release; original holder must re-acquire)\n' >&2
    return 7
  fi

  clear_lock_dir_contents "$release_path"
  if rmdir "$release_path" 2>/dev/null; then
    printf 'released: pid=%s lock=%s\n' "${actual_pid:-?}" "$LOCK_DIR"
    return 0
  fi

  echo "error: rmdir failed for $release_path (not empty or concurrent change)" >&2
  return 1
}

cmd_status() {
  if [[ ! -e "$LOCK_DIR" ]]; then
    printf 'status: free lock=%s\n' "$LOCK_DIR"
    return 0
  fi

  if [[ ! -d "$LOCK_DIR" ]]; then
    printf 'status: blocked lock=%s (path exists but is not a directory)\n' "$LOCK_DIR"
    return 0
  fi

  local pid host acquired alive duration meta has_token age
  pid=$(read_owner_pid)
  host=$(read_owner_host)
  acquired=$(read_acquired_at)
  duration=$(hold_duration_seconds)
  age=$(lock_age_seconds)
  alive="no"
  if is_valid_pid "$pid" && is_pid_alive "$pid"; then
    alive="yes"
  fi
  has_token="no"
  if is_valid_token_hash "$(read_owner_token_hash)"; then
    has_token="yes"
  fi
  meta="incomplete"
  if metadata_complete; then
    meta="complete"
  fi
  if [[ -z "$pid" ]]; then
    pid="?"
  fi

  printf 'status: held pid=%s alive=%s meta=%s token=%s host=%s acquired_at=%s hold_seconds=%s age_s=%s lock=%s\n' \
    "$pid" "$alive" "$meta" "$has_token" "$host" "$acquired" "$duration" "$age" "$LOCK_DIR"
  return 0
}

fail_selftest() {
  echo "SELFTEST FAIL: $*" >&2
  exit 1
}

extract_token_line() {
  # stdin → first token= value
  local line
  while IFS= read -r line; do
    case "$line" in
      token=*)
        printf '%s\n' "${line#token=}"
        return 0
        ;;
    esac
  done
  return 1
}

cmd_selftest() {
  # Must never touch the real default lock path.
  local base script
  script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  base=$(mktemp -d "${TMPDIR:-/tmp}/tatwo-build-lock-selftest.XXXXXX")
  export TATWO_BUILD_LOCK_DIR="${base}/tatwo-build.lock"
  # Keep suspect takeover slow by default inside selftest unless a case overrides.
  export TATWO_BUILD_LOCK_SUSPECT_TIMEOUT=120
  unset TATWO_BUILD_LOCK_TEST_INJECT_POST_MISMATCH 2>/dev/null || true
  LOCK_DIR="$TATWO_BUILD_LOCK_DIR"
  SUSPECT_TIMEOUT=120

  echo "selftest: base=$base"
  echo "selftest: LOCK_DIR=$LOCK_DIR"

  local acq_out tok got rel_rc acq_rc

  # --- 1) normal acquire / release (token path) ---  [case ④]
  echo "selftest: [1] normal acquire/release with token (④ full path)"
  acq_out=$("$script" acquire --pid "$$")
  printf '%s\n' "$acq_out"
  if ! printf '%s\n' "$acq_out" | grep -q '^acquired:'; then
    fail_selftest "normal acquire missing acquired line"
  fi
  tok=$(printf '%s\n' "$acq_out" | extract_token_line) || fail_selftest "no token= line on acquire"
  if ! is_valid_token "$tok"; then
    fail_selftest "invalid token from acquire: $tok"
  fi
  if [[ ! -f "$LOCK_DIR/owner.pid" || ! -f "$LOCK_DIR/owner.token.sha256" ]]; then
    fail_selftest "metadata incomplete after acquire (need owner.pid + owner.token.sha256)"
  fi
  if [[ -e "$LOCK_DIR/owner.token" ]]; then
    fail_selftest "plaintext owner.token must not exist in lock directory"
  fi
  local stored_hash expected_hash
  stored_hash=$(tr -d '[:space:]' <"$LOCK_DIR/owner.token.sha256" | tr 'A-F' 'a-f')
  expected_hash=$(token_sha256 "$tok") || fail_selftest "cannot hash token"
  if [[ "$stored_hash" != "$expected_hash" ]]; then
    fail_selftest "stored hash mismatch expected=$expected_hash got=$stored_hash"
  fi
  got=$(tr -d '[:space:]' <"$LOCK_DIR/owner.pid")
  if [[ "$got" != "$$" ]]; then
    fail_selftest "owner.pid=$got expected $$"
  fi
  if ! "$script" status | grep -q "alive=yes"; then
    fail_selftest "status should show alive=yes for current pid"
  fi
  if ! "$script" status | grep -q "meta=complete"; then
    fail_selftest "status should show meta=complete"
  fi
  if ! "$script" status | grep -q "token=yes"; then
    fail_selftest "status should show token=yes (hash present)"
  fi
  if ! "$script" release --token "$tok" --pid "$$"; then
    fail_selftest "normal release failed"
  fi
  if [[ -e "$LOCK_DIR" ]]; then
    fail_selftest "lock path still exists after release"
  fi
  if ! "$script" status | grep -q "status: free"; then
    fail_selftest "status should be free after release"
  fi

  # --- 2) contention wait timeout ---
  echo "selftest: [2] contention timeout"
  local holder
  sleep 120 &
  holder=$!
  acq_out=$("$script" acquire --pid "$holder")
  tok=$(printf '%s\n' "$acq_out" | extract_token_line) || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail_selftest "holder acquire missing token"
  }
  set +e
  "$script" acquire --timeout 6 --pid "$$"
  acq_rc=$?
  set -e
  if [[ "$acq_rc" -eq 0 ]]; then
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail_selftest "second acquire should have timed out"
  fi
  if ! "$script" release --token "$tok" --pid "$holder"; then
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail_selftest "release by holder token failed"
  fi
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  # --- 3) stale takeover (dead fake PID + complete metadata) ---
  echo "selftest: [3] stale takeover"
  local dead_pid=4194300
  if is_pid_alive "$dead_pid"; then
    fail_selftest "PID $dead_pid unexpectedly alive; pick another dead pid"
  fi
  # Publish-complete metadata via private dir + mv (simulate published lock with dead owner)
  local pub
  pub=$(mktemp -d "${base}/.pub.XXXXXX")
  printf '%s\n' "$dead_pid" >"$pub/owner.pid"
  printf '%s\n' "selftest-host" >"$pub/hostname"
  printf '%s\n' "2000-01-01T00:00:00Z" >"$pub/acquired_at"
  # valid-looking token hash for complete metadata (SHA-256 of deadbeef...)
  printf '%s\n' "$(token_sha256 "deadbeefdeadbeefdeadbeefdeadbeef")" >"$pub/owner.token.sha256"
  mv "$pub" "$LOCK_DIR"
  set +e
  local takeover_out
  takeover_out=$("$script" acquire --pid "$$" --timeout 10 2>&1)
  local take_rc=$?
  set -e
  echo "$takeover_out"
  if [[ "$take_rc" -ne 0 ]]; then
    fail_selftest "stale takeover acquire failed rc=$take_rc"
  fi
  if ! printf '%s\n' "$takeover_out" | grep -q "takeover: stale"; then
    fail_selftest "expected takeover: stale event on stdout"
  fi
  tok=$(printf '%s\n' "$takeover_out" | extract_token_line) || fail_selftest "no token after takeover"
  got=$(tr -d '[:space:]' <"$LOCK_DIR/owner.pid")
  if [[ "$got" != "$$" ]]; then
    fail_selftest "after takeover owner.pid=$got expected $$"
  fi
  local stale_count
  stale_count=$(find "$base" -maxdepth 1 -type d -name 'tatwo-build.lock.stale.*' 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$stale_count" -lt 1 ]]; then
    fail_selftest "expected at least one .stale.* archive directory"
  fi
  if ! "$script" release --token "$tok"; then
    fail_selftest "release after takeover failed"
  fi

  # --- 4) wrong-token precheck refuses; lock stays; owner can release ---  [case ②]
  echo "selftest: [4] wrong-token precheck refuses; lock stays; owner release (②)"
  acq_out=$("$script" acquire --pid "$$")
  tok=$(printf '%s\n' "$acq_out" | extract_token_line) || fail_selftest "acquire for precheck test failed"
  local before_hash
  before_hash=$(tr -d '[:space:]' <"$LOCK_DIR/owner.token.sha256")
  set +e
  local wrong_err
  wrong_err=$("$script" release --token "00000000000000000000000000000000" --pid 1 2>&1)
  rel_rc=$?
  set -e
  printf '%s\n' "$wrong_err"
  if [[ "$rel_rc" -eq 0 ]]; then
    fail_selftest "wrong-token release should be refused"
  fi
  if [[ "$rel_rc" -eq 7 ]]; then
    fail_selftest "wrong-token precheck must not reach quarantine path (exit 7)"
  fi
  if ! printf '%s\n' "$wrong_err" | grep -q "precheck"; then
    fail_selftest "wrong-token error should mention precheck"
  fi
  if [[ ! -d "$LOCK_DIR" ]]; then
    fail_selftest "lock should still exist after refused precheck release"
  fi
  got=$(tr -d '[:space:]' <"$LOCK_DIR/owner.token.sha256")
  if [[ "$got" != "$before_hash" ]]; then
    fail_selftest "stored hash changed after precheck refuse"
  fi
  local release_left q_left
  release_left=$(find "$base" -maxdepth 1 -type d -name 'tatwo-build.lock.release.*' 2>/dev/null | wc -l | tr -d ' ')
  q_left=$(find "$base" -maxdepth 1 -type d -name 'tatwo-build.lock.quarantine.*' 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$release_left" -ne 0 || "$q_left" -ne 0 ]]; then
    fail_selftest "precheck refuse must leave no .release.* / .quarantine.* dirs"
  fi
  if ! "$script" release --token "$tok" --pid "$$"; then
    fail_selftest "owner token release after precheck refuse failed"
  fi

  # --- 5) publication window: bare mkdir not immediately taken over ---
  echo "selftest: [5] publication window / bare mkdir is suspect (not immediate takeover)"
  mkdir "$LOCK_DIR"
  # Default SUSPECT_TIMEOUT=120; short acquire timeout must fail without takeover.
  set +e
  local bare_out
  bare_out=$("$script" acquire --pid "$$" --timeout 3 2>&1)
  acq_rc=$?
  set -e
  echo "$bare_out"
  if [[ "$acq_rc" -eq 0 ]]; then
    fail_selftest "bare mkdir must not be acquired within 3s (suspect wait)"
  fi
  if printf '%s\n' "$bare_out" | grep -q "takeover:"; then
    fail_selftest "bare mkdir must not be taken over before suspect timeout"
  fi
  if [[ ! -d "$LOCK_DIR" ]]; then
    fail_selftest "bare mkdir lock should still exist"
  fi
  # After short suspect timeout, takeover is allowed (legacy empty lock recovery).
  export TATWO_BUILD_LOCK_SUSPECT_TIMEOUT=1
  SUSPECT_TIMEOUT=1
  # Ensure age ≥ 1s
  sleep 1
  set +e
  bare_out=$("$script" acquire --pid "$$" --timeout 5 2>&1)
  acq_rc=$?
  set -e
  echo "$bare_out"
  if [[ "$acq_rc" -ne 0 ]]; then
    fail_selftest "suspect-timeout takeover of bare mkdir failed"
  fi
  if ! printf '%s\n' "$bare_out" | grep -q "takeover: suspect-timeout"; then
    fail_selftest "expected takeover: suspect-timeout"
  fi
  tok=$(printf '%s\n' "$bare_out" | extract_token_line) || fail_selftest "no token after suspect takeover"
  if ! "$script" release --token "$tok"; then
    fail_selftest "release after suspect takeover failed"
  fi
  export TATWO_BUILD_LOCK_SUSPECT_TIMEOUT=120
  SUSPECT_TIMEOUT=120

  # --- 6) lock-dir readable metadata is not a usable credential ---  [case ①]
  echo "selftest: [6] lock-dir cannot yield usable token; impersonation refused (①)"
  acq_out=$("$script" acquire --pid "$$")
  tok=$(printf '%s\n' "$acq_out" | extract_token_line) || fail_selftest "acquire for impersonation test failed"
  local file_pid file_hash
  file_pid=$(tr -d '[:space:]' <"$LOCK_DIR/owner.pid")
  file_hash=$(tr -d '[:space:]' <"$LOCK_DIR/owner.token.sha256")
  if [[ -e "$LOCK_DIR/owner.token" ]]; then
    fail_selftest "plaintext owner.token present — impersonation surface"
  fi
  # no token at all
  set +e
  "$script" release --pid "$file_pid"
  rel_rc=$?
  set -e
  if [[ "$rel_rc" -eq 0 ]]; then
    fail_selftest "release with only --pid (no token) must fail"
  fi
  if [[ ! -d "$LOCK_DIR" ]]; then
    fail_selftest "lock vanished after no-token release attempt"
  fi
  # use stored hash as if it were a token (must fail; hash ≠ preimage)
  set +e
  "$script" release --pid "$file_pid" --token "$file_hash"
  rel_rc=$?
  set -e
  if [[ "$rel_rc" -eq 0 ]]; then
    fail_selftest "release using stored hash as token must fail"
  fi
  if [[ ! -d "$LOCK_DIR" ]]; then
    fail_selftest "lock vanished after hash-as-token release"
  fi
  # wrong token even with correct pid string from file
  set +e
  "$script" release --pid "$file_pid" --token "ffffffffffffffffffffffffffffffff"
  rel_rc=$?
  set -e
  if [[ "$rel_rc" -eq 0 ]]; then
    fail_selftest "release with wrong token must fail"
  fi
  if [[ ! -d "$LOCK_DIR" ]]; then
    fail_selftest "lock vanished after wrong-token release"
  fi
  # lock still held by original owner
  if ! "$script" status | grep -q "alive=yes"; then
    fail_selftest "owner should still hold lock after impersonation attempts"
  fi

  # --- 7) race simulate: post-aside mismatch → quarantine, no rollback ---  [case ③]
  echo "selftest: [7] post-aside mismatch quarantine (race inject); third-party acquire (③)"
  if [[ ! -d "$LOCK_DIR" ]]; then
    fail_selftest "expected lock still held entering test 7"
  fi
  set +e
  local race_err
  race_err=$(TATWO_BUILD_LOCK_TEST_INJECT_POST_MISMATCH=1 \
    "$script" release --token "$tok" --pid "$$" 2>&1)
  rel_rc=$?
  set -e
  printf '%s\n' "$race_err"
  if [[ "$rel_rc" -ne 7 ]]; then
    fail_selftest "post-aside mismatch must exit 7, got $rel_rc"
  fi
  if printf '%s\n' "$race_err" | grep -qE 'restore|mv back|restored'; then
    fail_selftest "quarantine path must not speak of restore"
  fi
  if ! printf '%s\n' "$race_err" | grep -q "quarantine="; then
    fail_selftest "expected quarantine= in error"
  fi
  if ! printf '%s\n' "$race_err" | grep -q "鎖已被本次錯誤 release 摘走"; then
    fail_selftest "expected Chinese fail-closed notice about re-acquire"
  fi
  if [[ -d "$LOCK_DIR" ]]; then
    fail_selftest "public lock must NOT be restored after post-aside mismatch"
  fi
  q_left=$(find "$base" -maxdepth 1 -type d -name 'tatwo-build.lock.quarantine.*' 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$q_left" -lt 1 ]]; then
    fail_selftest "expected at least one .quarantine.* directory"
  fi
  # Third party can acquire freely (public namespace free; no dual-hold from rollback)
  local tok_b
  acq_out=$("$script" acquire --pid "$$" --timeout 5)
  tok_b=$(printf '%s\n' "$acq_out" | extract_token_line) || fail_selftest "third-party acquire after quarantine failed"
  if [[ ! -d "$LOCK_DIR" ]]; then
    fail_selftest "third-party lock missing after acquire"
  fi
  if [[ -e "$LOCK_DIR/owner.token" ]]; then
    fail_selftest "third-party lock must not contain plaintext token"
  fi
  # Original token must not release B's lock
  set +e
  "$script" release --token "$tok"
  rel_rc=$?
  set -e
  if [[ "$rel_rc" -eq 0 ]]; then
    fail_selftest "original token must not release third-party lock"
  fi
  if [[ ! -d "$LOCK_DIR" ]]; then
    fail_selftest "third-party lock must remain after wrong original token"
  fi
  if ! "$script" release --token "$tok_b"; then
    fail_selftest "third-party owner release failed"
  fi

  # --- 8) correct token path (env + file) ---  [case ④ continued]
  echo "selftest: [8] correct token path (CLI / env / token file) (④)"
  local tf
  tf="${base}/token.out"
  export TATWO_BUILD_LOCK_TOKEN_FILE="$tf"
  acq_out=$("$script" acquire --pid "$$")
  tok=$(printf '%s\n' "$acq_out" | extract_token_line) || fail_selftest "acquire with token file failed"
  if [[ ! -f "$tf" ]]; then
    fail_selftest "TATWO_BUILD_LOCK_TOKEN_FILE not written"
  fi
  got=$(tr -d '[:space:]' <"$tf")
  if [[ "$got" != "$tok" ]]; then
    fail_selftest "token file content mismatch"
  fi
  if [[ -e "$LOCK_DIR/owner.token" ]]; then
    fail_selftest "lock dir must not contain plaintext after token-file acquire"
  fi
  # release via env, not --token
  unset TATWO_BUILD_LOCK_TOKEN_FILE
  export TATWO_BUILD_LOCK_TOKEN="$tok"
  if ! "$script" release; then
    fail_selftest "release via TATWO_BUILD_LOCK_TOKEN env failed"
  fi
  unset TATWO_BUILD_LOCK_TOKEN
  if [[ -e "$LOCK_DIR" ]]; then
    fail_selftest "lock should be free after env-token release"
  fi

  # release via token file only
  export TATWO_BUILD_LOCK_TOKEN_FILE="$tf"
  acq_out=$("$script" acquire --pid "$$")
  tok=$(printf '%s\n' "$acq_out" | extract_token_line) || fail_selftest "re-acquire for file release failed"
  # clear env token; release reads file
  unset TATWO_BUILD_LOCK_TOKEN
  if ! "$script" release; then
    fail_selftest "release via TATWO_BUILD_LOCK_TOKEN_FILE failed"
  fi
  unset TATWO_BUILD_LOCK_TOKEN_FILE

  echo "SELFTEST PASS"
  return 0
}

main() {
  [[ $# -ge 1 ]] || usage
  case "$1" in
    acquire)
      shift
      cmd_acquire "$@"
      ;;
    release)
      shift
      cmd_release "$@"
      ;;
    status)
      shift
      [[ $# -eq 0 ]] || usage
      cmd_status
      ;;
    --selftest)
      shift
      [[ $# -eq 0 ]] || usage
      cmd_selftest
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "error: unknown command: $1" >&2
      usage
      ;;
  esac
}

main "$@"
