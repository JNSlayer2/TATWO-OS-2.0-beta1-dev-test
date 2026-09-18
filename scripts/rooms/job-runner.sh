#!/bin/bash
# W95 主設備施工佇列 runner。用法：job-runner.sh --once | --watch
# 在主設備 GUI 工作階段（Terminal.app，由 terminal-run.sh 起）前景執行；不是 launchd、不是常駐守護程式。
# 依提交順序取工作，硬體守門不足就把工作留在 queued 並寫原因；不自動殺工作。
#
# kind → 腳本對應表（白名單；runner 只會執行這張表裡的東西，永不接受工作裡帶的自由命令）
#   build      → $ROOMS/build-room.sh <branch> <tests...>
#   verify     → $ROOMS/gate-template.sh <branch> <tests...>
#   package    → $REPO_SCRIPTS/package-release.sh（版本、簽章身份取自 runner 啟動時的環境）
#   thrice     → $ROOMS/thrice-candidate-full.sh <候選 worktree>
#   clean-gate → $REPO_SCRIPTS/clean-install-gate.sh --binary <候選 Tatwo2>
#   install    → $ROOMS/install-candidate.sh <離線目錄> <版本> <角色> <主設備 os.md sha12>
set -uo pipefail
E="${TATWO_ENTRY:-$HOME/AI/TATWO OS}"; S="${TATWO_STAGING:-$E/staging}"; R="${TATWO_REPO:-$E/tatwo2}"
ROOMS="${TATWO_ROOMS_BIN:-$(cd "$(dirname "$0")" && pwd)}"; REPO_SCRIPTS="${TATWO_REPO_SCRIPTS:-$R/scripts}"
JOBS="$S/jobs"; Q="$JOBS/queue"; RCPT="$JOBS/receipts"; LOGS="$JOBS/logs"
LOCK="${TATWO_BUILD_LOCK:-$S/rooms/.build-lock}"
MIN_MEM="${TATWO_JOB_MIN_MEM_GB:-4}"; MIN_STAGING="${TATWO_JOB_MIN_STAGING_GB:-30}"; MIN_SYSTEM="${TATWO_JOB_MIN_SYSTEM_GB:-10}"
POLL="${TATWO_JOB_POLL_SECONDS:-60}"; TAIL_LINES="${TATWO_JOB_LOG_TAIL:-200}"
MODE=""
case "${1:-}" in
  --once) MODE=once ;;
  --watch) MODE=watch ;;
  *) echo "用法：job-runner.sh --once|--watch" >&2; exit 64 ;;
esac
mkdir -p "$Q" "$RCPT" "$LOGS"

now_iso() { date -u "+%Y-%m-%dT%H:%M:%SZ"; }
mem_free_gb() {
  vm_stat | awk -v p="$(pagesize 2>/dev/null || echo 16384)" \
    '/^Pages free:/ || /^Pages inactive:/ { gsub("\\.","",$NF); s+=$NF } END { printf "%.2f", s*p/1073741824 }'
}
disk_free_gb() { # <path>：取最近一個存在的祖先目錄所在卷
  local p="$1"
  while [ ! -e "$p" ] && [ "$p" != "/" ]; do p="$(dirname "$p")"; done
  df -k "$p" 2>/dev/null | tail -1 | awk '{ printf "%.2f", $4/1048576 }'
}
below() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a+0 < b+0) }'; }
lock_owner() {
  [ -d "$LOCK" ] || return 1
  if [ -f "$LOCK/pid" ] && ! kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null; then return 1; fi
  cat "$LOCK/owner" 2>/dev/null || echo "unknown"
}
gate_reason() { # 空字串＝可以開工；否則是留在 queued 的原因
  local mem staging system owner
  mem="$(mem_free_gb)"; staging="$(disk_free_gb "$S")"; system="$(disk_free_gb /)"
  if below "$mem" "$MIN_MEM"; then echo "記憶體不足：free+inactive ${mem}GB < ${MIN_MEM}GB"; return; fi
  if below "$staging" "$MIN_STAGING"; then echo "staging 卷不足：${staging}GB < ${MIN_STAGING}GB"; return; fi
  if below "$system" "$MIN_SYSTEM"; then echo "系統碟不足：${system}GB < ${MIN_SYSTEM}GB"; return; fi
  if owner="$(lock_owner)"; then echo "建置鎖被佔用：$owner"; return; fi
  echo ""
}

field() { python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2])
print("" if v is None else (" ".join(v) if isinstance(v,list) else str(v)))' "$1" "$2"; }
set_job() { # <檔> <key=value>...（@now＝現在時間；@null＝清空）
  python3 - "$@" <<'PY'
import json, sys, datetime
path = sys.argv[1]
row = json.load(open(path))
for pair in sys.argv[2:]:
    key, value = pair.split("=", 1)
    if value == "@now": value = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if value == "@null": value = None
    if isinstance(value, str) and value.lstrip("-").isdigit(): value = int(value)
    row[key] = value
row["updatedAt"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(row, open(path, "w"), ensure_ascii=False, indent=1)
PY
}
write_receipt() { # <收據檔> <id> <kind> <branch> <commit> <startedAt> <endedAt|@null> <exit|@null> <log> <tail 行數> <artifact...>
  python3 - "$@" <<'PY'
import json, os, socket, sys
path, jid, kind, branch, commit, started, ended, code, log, tail = sys.argv[1:11]
artifacts = [a for a in sys.argv[11:] if a]
lines = []
if os.path.exists(log):
    with open(log, "r", errors="replace") as handle:
        lines = handle.read().splitlines()[-int(tail):]
json.dump({"id": jid, "kind": kind, "branch": branch, "commit": commit,
           "startedAt": started, "endedAt": None if ended == "@null" else ended,
           "exit": None if code == "@null" else int(code),
           "logTail": lines, "artifacts": artifacts, "runner": socket.gethostname()},
          open(path, "w"), ensure_ascii=False, indent=1)
PY
}
queued_ids() {
  python3 - "$Q" <<'PY'
import json, os, sys
root = sys.argv[1]
rows = []
for name in (sorted(os.listdir(root)) if os.path.isdir(root) else []):
    if not name.endswith(".json"): continue
    try: row = json.load(open(os.path.join(root, name)))
    except Exception: continue
    if row.get("status") == "queued":
        rows.append((row.get("submittedAt") or "", row.get("id") or name[:-5]))
for _, jid in sorted(rows): print(jid)
PY
}

valid_job() { # <kind> <branch> <commit> <tests>
  case "$1" in build|verify|package|thrice|clean-gate|install) ;; *) return 1 ;; esac
  case "$2" in *..*|-*) return 1 ;; esac
  printf '%s' "$2" | grep -Eq '^[A-Za-z0-9._/-]{1,120}$' || return 1
  printf '%s' "$3" | grep -Eq '^[0-9a-f]{40}$' || return 1
  local t
  for t in $4; do
    case "$t" in *..*) return 1 ;; esac
    printf '%s' "$t" | grep -Eq '^tests/[A-Za-z0-9._-]+\.test\.mjs$' || return 1
  done
  return 0
}

build_command() { # 填 CMD 陣列；只用上面那張表，不讀工作裡的任何命令字串
  local kind="$1" branch="$2" tests="$3" name="${2##*/}"
  CMD=()
  case "$kind" in
    build) CMD=(bash "$ROOMS/build-room.sh" "$branch"); for t in $tests; do CMD+=("$t"); done ;;
    verify) CMD=(bash "$ROOMS/gate-template.sh" "$branch"); for t in $tests; do CMD+=("$t"); done ;;
    thrice) CMD=(bash "$ROOMS/thrice-candidate-full.sh" "${TATWO_JOB_CANDIDATE:-$S/rooms/build-$name}") ;;
    package) CMD=(bash "$REPO_SCRIPTS/package-release.sh") ;;
    clean-gate) CMD=(bash "$REPO_SCRIPTS/clean-install-gate.sh" --binary
                     "${TATWO_JOB_CANDIDATE_BINARY:-$S/build-cache/$name/arm64-apple-macosx/debug/Tatwo2}") ;;
    install) CMD=(bash "$ROOMS/install-candidate.sh" "${TATWO_JOB_OFFLINE_DIR:-}" "${TATWO_JOB_VERSION:-}"
                  "${TATWO_JOB_ROLE:-primary}" "${TATWO_JOB_PRIMARY_OS_SHA12:-}") ;;
  esac
}

process() { # <id>
  local id="$1" file="$Q/$1.json" kind branch commit tests reason log started ended code
  [ -f "$file" ] || return 0
  kind="$(field "$file" kind)"; branch="$(field "$file" branch)"
  commit="$(field "$file" commit)"; tests="$(field "$file" tests)"
  if ! valid_job "$kind" "$branch" "$commit" "$tests"; then
    set_job "$file" status=failed reason="工作欄位不合法（kind／branch／commit／tests）"
    echo "JOB $id failed 工作欄位不合法"; return 0
  fi
  reason="$(gate_reason)"
  if [ -n "$reason" ]; then
    set_job "$file" status=queued reason="$reason"
    echo "JOB $id queued $reason"; return 0
  fi
  log="$LOGS/$id.log"; started="$(now_iso)"
  set_job "$file" status=running reason=@null startedAt="$started"
  write_receipt "$RCPT/$id.json" "$id" "$kind" "$branch" "$commit" "$started" @null @null "$log" "$TAIL_LINES"
  echo "JOB $id running $kind $branch"
  build_command "$kind" "$branch" "$tests"
  : > "$log"
  "${CMD[@]}" >> "$log" 2>&1; code=$?
  ended="$(now_iso)"
  write_receipt "$RCPT/$id.json" "$id" "$kind" "$branch" "$commit" "$started" "$ended" "$code" "$log" "$TAIL_LINES" \
    "$log" "$S/build-cache/${branch##*/}"
  if [ "$code" = 0 ]; then set_job "$file" status=done reason=@null endedAt="$ended" exit="$code"
  else set_job "$file" status=failed reason="exit=$code" endedAt="$ended" exit="$code"; fi
  echo "JOB $id $([ "$code" = 0 ] && echo done || echo failed) exit=$code"
}

pass() {
  local ids; ids="$(queued_ids)"
  [ -n "$ids" ] || return 0
  while IFS= read -r id; do [ -n "$id" ] && process "$id"; done <<< "$ids"
}

echo "job-runner ${MODE}：佇列 ${Q}；門檻 mem ${MIN_MEM}GB／staging ${MIN_STAGING}GB／system ${MIN_SYSTEM}GB"
if [ "$MODE" = once ]; then
  pass
  echo "job-runner once 結束；仍在佇列：$(queued_ids | grep -c . | tr -d ' ')"
else
  while :; do pass; sleep "$POLL"; done
fi
