#!/usr/bin/env bash

# Keep a MacBook's local-internal Tatwo Ultrawork App aligned with one Git
# branch. This script deliberately never edits credentials, Keychain data, or
# existing Apps directly: the local installer stages, verifies, archives, then
# activates a replacement only after a successful build.

set -u
set -o pipefail

readonly TATWO_AUTOSYNC_REPOSITORY_URL="https://github.com/tatwo214/tatwo-ultrawork.git"
readonly TATWO_AUTOSYNC_DEFAULT_BRANCH="release/tatwo-os"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

HOME_DIR="${HOME:-}"
if [[ -z "$HOME_DIR" ]]; then
  printf '%s\n' "tatwo-autosync: HOME is not set; skipping update" >&2
  exit 0
fi

BRANCH="${TATWO_AUTOSYNC_BRANCH:-$TATWO_AUTOSYNC_DEFAULT_BRANCH}"
REPO_DIR="${TATWO_AUTOSYNC_REPO:-$HOME_DIR/Developer/tatwo-ultrawork}"
APP_SUPPORT_DIR="${TATWO_AUTOSYNC_APP_SUPPORT_DIR:-$HOME_DIR/Library/Application Support/Tatwo Ultrawork}"
LOG_FILE="$APP_SUPPORT_DIR/autosync.log"
LAST_INSTALLED_COMMIT_FILE="$APP_SUPPORT_DIR/last-installed-commit"
LOCK_DIR="$APP_SUPPORT_DIR/autosync.lock"

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  local message="$1"
  local line

  line="$(timestamp) $message"
  if [[ -d "$APP_SUPPORT_DIR" ]] || mkdir -p "$APP_SUPPORT_DIR" 2>/dev/null; then
    printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
  else
    printf '%s\n' "$line" >&2
  fi
}

skip() {
  log "result=skipped reason=$1"
  return 0
}

valid_branch() {
  command -v git >/dev/null 2>&1 \
    && git check-ref-format --branch "$BRANCH" >/dev/null 2>&1
}

valid_repo_path() {
  [[ "$REPO_DIR" == /* ]] \
    && [[ "$REPO_DIR" != *$'\n'* ]] \
    && [[ "$REPO_DIR" != *$'\r'* ]]
}

origin_is_tatwo_repo() {
  local origin_url

  origin_url="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"
  case "$origin_url" in
    https://github.com/tatwo214/tatwo-ultrawork|\
    https://github.com/tatwo214/tatwo-ultrawork.git|\
    git@github.com:tatwo214/tatwo-ultrawork.git|\
    ssh://git@github.com/tatwo214/tatwo-ultrawork.git)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

release_lock() {
  if [[ -d "$LOCK_DIR" ]]; then
    rm -f "$LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}

acquire_lock() {
  local owner_pid=""
  local stale_lock_dir=""

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    if printf '%s\n' "$$" >"$LOCK_DIR/pid"; then
      return 0
    fi
    rmdir "$LOCK_DIR" 2>/dev/null || true
    skip "lock_write_failed"
    return 1
  fi

  if [[ -f "$LOCK_DIR/pid" ]]; then
    IFS= read -r owner_pid <"$LOCK_DIR/pid" || true
  fi
  if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
    skip "already_running"
    return 1
  fi

  stale_lock_dir="$APP_SUPPORT_DIR/autosync.stale-lock.$(date -u +%Y%m%dT%H%M%SZ).$$"
  if [[ -d "$LOCK_DIR" ]]; then
    mv "$LOCK_DIR" "$stale_lock_dir" 2>/dev/null \
      && log "stale_lock_archived=true" \
      || {
        skip "lock_recovery_failed"
        return 1
      }
  fi

  if mkdir "$LOCK_DIR" 2>/dev/null \
    && printf '%s\n' "$$" >"$LOCK_DIR/pid"
  then
    return 0
  fi

  release_lock
  skip "lock_race"
  return 1
}

clone_repo() {
  local parent_dir
  local clone_dir
  local failed_clone_dir

  parent_dir="$(dirname "$REPO_DIR")"
  if ! mkdir -p "$parent_dir"; then
    skip "repo_parent_create_failed"
    return 1
  fi

  clone_dir="${REPO_DIR}.clone.$(date -u +%Y%m%dT%H%M%SZ).$$"
  if [[ -e "$clone_dir" ]]; then
    skip "clone_staging_path_exists"
    return 1
  fi

  log "clone=started branch=$BRANCH"
  if ! git clone --quiet --branch "$BRANCH" \
    "$TATWO_AUTOSYNC_REPOSITORY_URL" "$clone_dir" >>"$LOG_FILE" 2>&1
  then
    failed_clone_dir="${REPO_DIR}.failed-clone.$(date -u +%Y%m%dT%H%M%SZ).$$"
    if [[ -e "$clone_dir" ]]; then
      mv "$clone_dir" "$failed_clone_dir" 2>/dev/null \
        && log "clone_failure_artifact=preserved" \
        || log "clone_failure_artifact=unmoved"
    fi
    skip "clone_failed"
    return 1
  fi

  if ! mv "$clone_dir" "$REPO_DIR"; then
    log "clone=failed_move_to_repo"
    skip "clone_activation_failed"
    return 1
  fi
  log "clone=passed branch=$BRANCH"
}

ensure_repo() {
  if [[ ! -e "$REPO_DIR" ]]; then
    clone_repo || return 1
  fi

  if ! git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    skip "repo_not_a_git_worktree"
    return 1
  fi
  if ! origin_is_tatwo_repo; then
    skip "repo_origin_mismatch"
    return 1
  fi
}

remote_commit() {
  local remote_ref="refs/remotes/origin/$BRANCH"

  log "fetch=started branch=$BRANCH"
  if ! git -C "$REPO_DIR" fetch --quiet origin \
    "refs/heads/$BRANCH:$remote_ref" >>"$LOG_FILE" 2>&1
  then
    skip "fetch_failed"
    return 1
  fi
  log "fetch=passed branch=$BRANCH"

  git -C "$REPO_DIR" rev-parse --verify "$remote_ref^{commit}" 2>/dev/null
}

last_installed_commit() {
  local value=""

  if [[ -f "$LAST_INSTALLED_COMMIT_FILE" ]]; then
    IFS= read -r value <"$LAST_INSTALLED_COMMIT_FILE" || true
  fi
  printf '%s\n' "$value"
}

worktree_is_clean() {
  [[ -z "$(git -C "$REPO_DIR" status --porcelain=v1 --untracked-files=all 2>/dev/null)" ]]
}

record_installed_commit() {
  local commit="$1"
  local temporary_record

  if ! temporary_record="$(mktemp "$APP_SUPPORT_DIR/.last-installed-commit.XXXXXX")"; then
    log "record=failed_create_temp"
    return 1
  fi
  if ! printf '%s\n' "$commit" >"$temporary_record" \
    || ! mv -f "$temporary_record" "$LAST_INSTALLED_COMMIT_FILE"
  then
    rm -f "$temporary_record" 2>/dev/null || true
    log "record=failed"
    return 1
  fi
  log "record=passed commit=$commit"
}

install_commit() {
  local commit="$1"
  local remote_ref="refs/remotes/origin/$BRANCH"
  local checked_out_commit

  if ! worktree_is_clean; then
    skip "dirty_worktree"
    return 1
  fi

  log "checkout=started branch=$BRANCH commit=$commit"
  if ! git -C "$REPO_DIR" checkout --quiet -B "$BRANCH" "$remote_ref" >>"$LOG_FILE" 2>&1 \
    || ! git -C "$REPO_DIR" reset --hard "$commit" >>"$LOG_FILE" 2>&1
  then
    skip "checkout_or_reset_failed"
    return 1
  fi
  checked_out_commit="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)"
  if [[ "$checked_out_commit" != "$commit" ]]; then
    skip "checkout_commit_mismatch"
    return 1
  fi
  log "checkout=passed commit=$commit"

  if [[ ! -f "$REPO_DIR/scripts/tatwo-install-local-app.sh" ]]; then
    skip "local_installer_missing"
    return 1
  fi

  log "install=started commit=$commit"
  if ! bash "$REPO_DIR/scripts/tatwo-install-local-app.sh" >>"$LOG_FILE" 2>&1; then
    log "install=failed existing_app_preserved_by_installer=true"
    return 1
  fi
  log "install=passed commit=$commit"

  record_installed_commit "$commit" || return 1
  log "result=updated commit=$commit"
}

main() {
  local remote_head
  local installed_head

  if ! mkdir -p "$APP_SUPPORT_DIR"; then
    printf '%s\n' "tatwo-autosync: cannot create Application Support state; skipping update" >&2
    return 0
  fi
  if ! valid_repo_path; then
    skip "invalid_repo_path"
    return 0
  fi
  if ! valid_branch; then
    skip "invalid_branch_or_git_missing"
    return 0
  fi
  if ! acquire_lock; then
    return 0
  fi
  trap release_lock EXIT
  trap 'release_lock; exit 0' HUP INT TERM

  log "run=started branch=$BRANCH"
  ensure_repo || return 0

  remote_head="$(remote_commit)" || return 0
  if [[ ! "$remote_head" =~ ^[0-9a-f]{40}$ ]]; then
    skip "invalid_remote_commit"
    return 0
  fi
  installed_head="$(last_installed_commit)"
  if [[ "$remote_head" == "$installed_head" ]]; then
    log "result=no_update commit=$remote_head"
    return 0
  fi

  install_commit "$remote_head" || return 0
}

main "$@"
