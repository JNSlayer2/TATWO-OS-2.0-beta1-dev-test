#!/usr/bin/env bash

# One-time MacBook bootstrap for the local-internal Tatwo Ultrawork App
# autosync. It installs only a user LaunchAgent and invokes the updater once;
# it never writes credentials, Keychain values, or a signed release feed.

set -u
set -o pipefail

readonly TATWO_AUTOSYNC_REPOSITORY_URL="https://github.com/tatwo214/tatwo-ultrawork.git"
readonly TATWO_AUTOSYNC_DEFAULT_BRANCH="release/tatwo-os"
readonly TATWO_AUTOSYNC_LABEL="com.tatwo.macbook-autosync"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

HOME_DIR="${HOME:-}"
if [[ -z "$HOME_DIR" ]]; then
  printf '%s\n' "tatwo-macbook-bootstrap: HOME is not set" >&2
  exit 1
fi

BRANCH="${TATWO_AUTOSYNC_BRANCH:-$TATWO_AUTOSYNC_DEFAULT_BRANCH}"
REPO_DIR="${TATWO_AUTOSYNC_REPO:-$HOME_DIR/Developer/tatwo-ultrawork}"
APP_SUPPORT_DIR="${TATWO_AUTOSYNC_APP_SUPPORT_DIR:-$HOME_DIR/Library/Application Support/Tatwo Ultrawork}"
LOG_FILE="$APP_SUPPORT_DIR/autosync.log"
LAUNCH_AGENTS_DIR="$HOME_DIR/Library/LaunchAgents"
PLIST_DESTINATION="$LAUNCH_AGENTS_DIR/$TATWO_AUTOSYNC_LABEL.plist"

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  local message="$1"

  printf '%s %s\n' "$(timestamp)" "$message" >>"$LOG_FILE" 2>/dev/null || true
}

fail() {
  local message="$1"

  log "bootstrap=failed reason=$message"
  printf 'tatwo-macbook-bootstrap: %s\n' "$message" >&2
  return 1
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

clone_repo() {
  local parent_dir
  local clone_dir
  local failed_clone_dir

  parent_dir="$(dirname "$REPO_DIR")"
  mkdir -p "$parent_dir" || return 1
  clone_dir="${REPO_DIR}.clone.$(date -u +%Y%m%dT%H%M%SZ).$$"
  [[ ! -e "$clone_dir" ]] || return 1

  log "bootstrap_clone=started branch=$BRANCH"
  if ! git clone --quiet --branch "$BRANCH" \
    "$TATWO_AUTOSYNC_REPOSITORY_URL" "$clone_dir" >>"$LOG_FILE" 2>&1
  then
    failed_clone_dir="${REPO_DIR}.failed-clone.$(date -u +%Y%m%dT%H%M%SZ).$$"
    if [[ -e "$clone_dir" ]]; then
      mv "$clone_dir" "$failed_clone_dir" 2>/dev/null \
        && log "bootstrap_clone_failure_artifact=preserved" \
        || log "bootstrap_clone_failure_artifact=unmoved"
    fi
    return 1
  fi
  mv "$clone_dir" "$REPO_DIR" || return 1
  log "bootstrap_clone=passed branch=$BRANCH"
}

ensure_repo() {
  if [[ ! -e "$REPO_DIR" ]]; then
    clone_repo || return 1
  fi
  git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && origin_is_tatwo_repo
}

render_launch_agent() {
  local template_path="$REPO_DIR/scripts/templates/$TATWO_AUTOSYNC_LABEL.plist"
  local autosync_script="$REPO_DIR/scripts/tatwo-macbook-autosync.sh"
  local staged_plist

  [[ -f "$template_path" ]] || return 1
  [[ -f "$autosync_script" ]] || return 1
  chmod u+x "$autosync_script" || return 1

  staged_plist="$(mktemp "$LAUNCH_AGENTS_DIR/.$TATWO_AUTOSYNC_LABEL.XXXXXX")" || return 1
  if ! cp "$template_path" "$staged_plist" \
    || ! /usr/bin/plutil -replace ProgramArguments.0 \
      -string "$autosync_script" "$staged_plist" \
    || ! /usr/bin/plutil -replace StandardOutPath \
      -string "$LOG_FILE" "$staged_plist" \
    || ! /usr/bin/plutil -replace StandardErrorPath \
      -string "$LOG_FILE" "$staged_plist" \
    || ! /usr/bin/plutil -lint "$staged_plist" >/dev/null
  then
    rm -f "$staged_plist" 2>/dev/null || true
    return 1
  fi

  if [[ -f "$PLIST_DESTINATION" ]] && cmp -s "$staged_plist" "$PLIST_DESTINATION"; then
    rm -f "$staged_plist" 2>/dev/null || true
    log "bootstrap_plist=unchanged"
    return 0
  fi

  mv -f "$staged_plist" "$PLIST_DESTINATION" || {
    rm -f "$staged_plist" 2>/dev/null || true
    return 1
  }
  log "bootstrap_plist=installed"
}

load_launch_agent() {
  launchctl unload "$PLIST_DESTINATION" >>"$LOG_FILE" 2>&1 || true
  launchctl load "$PLIST_DESTINATION" >>"$LOG_FILE" 2>&1
}

main() {
  local autosync_script

  if ! mkdir -p "$APP_SUPPORT_DIR" "$LAUNCH_AGENTS_DIR"; then
    fail "cannot_create_user_state"
    return 1
  fi
  if ! valid_repo_path; then
    fail "invalid_repo_path"
    return 1
  fi
  if ! valid_branch; then
    fail "invalid_branch_or_git_missing"
    return 1
  fi
  if [[ ! -x /usr/bin/plutil ]]; then
    fail "plutil_missing"
    return 1
  fi
  if ! command -v launchctl >/dev/null 2>&1; then
    fail "launchctl_missing"
    return 1
  fi

  log "bootstrap=started branch=$BRANCH"
  if ! ensure_repo; then
    fail "clone_or_repo_validation_failed"
    return 1
  fi
  if ! render_launch_agent; then
    fail "launch_agent_render_failed"
    return 1
  fi
  if ! load_launch_agent; then
    fail "launch_agent_load_failed"
    return 1
  fi

  autosync_script="$REPO_DIR/scripts/tatwo-macbook-autosync.sh"
  log "bootstrap_autosync=started"
  if ! bash "$autosync_script" >>"$LOG_FILE" 2>&1; then
    fail "initial_autosync_failed"
    return 1
  fi
  log "bootstrap=completed"
}

main "$@"
