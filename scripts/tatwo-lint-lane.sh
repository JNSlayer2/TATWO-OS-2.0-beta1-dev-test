#!/usr/bin/env bash
# tatwo-lint-lane.sh — 較嚴格機器當第二意見 linter（只 build 不跑 test）
#
# 政策：docs/protocol/TOOLCHAIN_DIVERGENCE_POLICY.md（linter-lane）
#
# 鐵律：
#   - 預設 --dry-run（不 scp／SSH／swift build）
#   - 主機／使用者／路徑全走 --target；腳本內無硬編
#   - 遠端只 swift build -j 2（不跑 swift test）
#   - 不安裝／不切換工具鏈；禁 git 寫入
#   - SSH 僅在非 dry-run 且參數指定時使用
#
# 用法：
#   bash scripts/tatwo-lint-lane.sh \
#     --target 'ssh:<user>@<host>:<worktree>' \
#     --rev <commit> \
#     [--dry-run | --execute]
#   bash scripts/tatwo-lint-lane.sh --selftest
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

TARGET_SPEC=""
REV=""
DRY_RUN=1
EXECUTE=0
SELFTEST=0
SWIFT_JOBS="${TATWO_LINT_SWIFT_JOBS:-2}"
POLL_TIMEOUT="${TATWO_LINT_POLL_TIMEOUT:-3600}"

# Injected executors (selftest / fixtures only). Production leaves unset.
SSH_CMD="${TATWO_LINT_SSH_CMD:-ssh}"
STUB_MODE="${TATWO_LINT_STUB_MODE:-0}"
STUB_BUILD_LOG="${TATWO_LINT_STUB_BUILD_LOG:-}"
STUB_BLOCK_REASON="${TATWO_LINT_STUB_BLOCK_REASON:-}"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/tatwo-lint-lane.sh \
    --target ssh:<user>@<host>:<worktree path> \
    --rev <commit> \
    [--dry-run | --execute]

  bash scripts/tatwo-lint-lane.sh --selftest

Purpose:
  Run swift build -j 2 on a stricter (or any chosen) machine as a second-opinion
  linter. Does NOT run tests. Does NOT install/switch toolchains.

Defaults:
  --dry-run   ON (plan only; no SSH / swift build)

Conclusions (exactly one):
  LINT_CLEAN
  LINT_FINDINGS(n)
  LINT_BLOCKED(reason)

Environment (fixture / selftest only):
  TATWO_LINT_STUB_MODE=1
  TATWO_LINT_SSH_CMD
  TATWO_LINT_STUB_BUILD_LOG
  TATWO_LINT_STUB_BLOCK_REASON
  TATWO_LINT_SWIFT_JOBS   (default 2)
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

log() {
  printf '[lint-lane] %s\n' "$*" >&2
}

utc_stamp() {
  date -u +"%Y%m%dT%H%M%SZ"
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
    --target)
      [[ $# -ge 2 ]] || die "--target requires a value"
      TARGET_SPEC="$2"
      shift 2
      ;;
    --rev)
      [[ $# -ge 2 ]] || die "--rev requires a value"
      REV="$2"
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
    --target=*|--rev=*)
      key="${1%%=*}"
      val="${1#*=}"
      [[ -n "$val" ]] || die "$key requires a value"
      case "$key" in
        --target) TARGET_SPEC="$val" ;;
        --rev) REV="$val" ;;
      esac
      shift
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

if [[ "$SELFTEST" -eq 1 ]]; then
  if [[ -n "$TARGET_SPEC" || -n "$REV" || "$EXECUTE" -eq 1 ]]; then
    die "--selftest cannot be combined with other run arguments"
  fi
fi

# --- target parse ---

TARGET_USERHOST=""
TARGET_PATH=""

parse_target() {
  local piece rest
  piece="$TARGET_SPEC"
  [[ -n "$piece" ]] || die "--target is required (ssh:<user>@<host>:<worktree>)"
  if [[ "$piece" != ssh:* ]]; then
    die "invalid --target (want ssh:<user>@<host>:<worktree>): $piece"
  fi
  rest="${piece#ssh:}"
  if [[ "$rest" != *@*:* ]]; then
    die "invalid ssh target (want ssh:<user>@<host>:<worktree>): $piece"
  fi
  TARGET_USERHOST="${rest%%:*}"
  TARGET_PATH="${rest#*:}"
  [[ "$TARGET_USERHOST" == *@* ]] || die "invalid ssh target (missing user@host): $piece"
  [[ -n "$TARGET_PATH" ]] || die "invalid ssh target (empty worktree path): $piece"
}

# --- parse build log → finding count ---

# Prints: findings=<n> errors=<n> warnings=<n>
count_findings() {
  local log_file="$1"
  python3 - "$log_file" <<'PY'
import re, sys
path = sys.argv[1]
try:
    text = open(path, "r", encoding="utf-8", errors="replace").read()
except Exception as e:
    print(f"findings=0")
    print(f"errors=0")
    print(f"warnings=0")
    print(f"parse_error={e}")
    raise SystemExit(0)

# Swift / clang-style diagnostics and SPM error summaries.
err_re = re.compile(
    r"(?:"
    r"error:\s|"
    r":\s+error:\s|"
    r"^error: |"
    r"\berror: "  # mid-line
    r")",
    re.M,
)
warn_re = re.compile(
    r"(?:"
    r"warning:\s|"
    r":\s+warning:\s|"
    r"^warning: |"
    r"\bwarning: "
    r")",
    re.M,
)
# Count diagnostic lines; avoid double-counting pure "error:" summaries when
# source locations already matched — still count each matching line once.
errors = 0
warnings = 0
for line in text.splitlines():
    # Skip our own markers
    if line.startswith("===LINT_") or line.startswith("RC=") or line.startswith("REV="):
        continue
    if err_re.search(line):
        errors += 1
        continue
    if warn_re.search(line):
        warnings += 1

findings = errors + warnings
print(f"findings={findings}")
print(f"errors={errors}")
print(f"warnings={warnings}")
PY
}

emit_conclusion() {
  # args: kind, detail...
  # kinds: CLEAN | FINDINGS | BLOCKED
  local kind="$1"
  local detail="${2:-}"
  case "$kind" in
    CLEAN)
      printf 'CONCLUSION: LINT_CLEAN\n'
      ;;
    FINDINGS)
      printf 'CONCLUSION: LINT_FINDINGS(%s)\n' "$detail"
      ;;
    BLOCKED)
      printf 'CONCLUSION: LINT_BLOCKED(%s)\n' "$detail"
      ;;
    *)
      printf 'CONCLUSION: LINT_BLOCKED(internal: unknown kind %s)\n' "$kind"
      ;;
  esac
}

print_plan() {
  printf '=== Tatwo Lint Lane PLAN (dry-run=%s stub=%s) ===\n' "$DRY_RUN" "$STUB_MODE"
  printf 'target: %s\n' "$TARGET_SPEC"
  printf 'userhost: %s\n' "$TARGET_USERHOST"
  printf 'worktree: %s\n' "$TARGET_PATH"
  printf 'rev: %s\n' "$REV"
  printf 'remote_command: export PATH=...; cd <worktree>; git rev-parse HEAD (read-only check vs --rev); swift build -j %s\n' "$SWIFT_JOBS"
  printf 'notes: build only (no swift test); no toolchain install/switch; no git write\n'
  printf '=== end plan ===\n'
}

run_remote_build() {
  local work_root log_file remote_cmd out_rc
  work_root="${TATWO_LINT_WORK_ROOT:-${TMPDIR:-/tmp}/tatwo-lint-lane-$(utc_stamp)-$$}"
  mkdir -p "$work_root"
  log_file="$work_root/build.log"

  if [[ "$STUB_MODE" == "1" ]]; then
    if [[ -n "$STUB_BLOCK_REASON" ]]; then
      emit_conclusion BLOCKED "$STUB_BLOCK_REASON"
      return 1
    fi
    if [[ -z "$STUB_BUILD_LOG" || ! -f "$STUB_BUILD_LOG" ]]; then
      emit_conclusion BLOCKED "stub mode missing TATWO_LINT_STUB_BUILD_LOG"
      return 1
    fi
    cp "$STUB_BUILD_LOG" "$log_file"
    conclude_from_log "$log_file"
    return $?
  fi

  # Production remote: read-only rev check + swift build -j N (no test, no git write).
  # shellcheck disable=SC2089
  remote_cmd=$(cat <<REMOTE
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\$PATH"
cd $(printf '%q' "$TARGET_PATH")
WANT=$(printf '%q' "$REV")
if ! command -v git >/dev/null 2>&1; then
  printf 'LINT_BLOCK_REASON=git missing on remote\n'
  exit 0
fi
if ! command -v swift >/dev/null 2>&1; then
  printf 'LINT_BLOCK_REASON=swift missing on remote\n'
  exit 0
fi
# Resolve HEAD and verify it matches requested rev (full or unique prefix).
HEAD=\$(git rev-parse HEAD 2>/dev/null || true)
if [[ -z "\$HEAD" ]]; then
  printf 'LINT_BLOCK_REASON=cannot resolve HEAD\n'
  exit 0
fi
# Accept exact or prefix match; do not fetch/checkout (no git write / network).
if [[ "\$HEAD" != "\$WANT" && "\$HEAD" != "\$WANT"* && "\$WANT" != "\$HEAD"* ]]; then
  printf 'LINT_BLOCK_REASON=rev mismatch want=%s head=%s (refusing auto-checkout; user gate)\n' "\$WANT" "\$HEAD"
  exit 0
fi
printf 'REV=%s\n' "\$HEAD"
printf '===LINT_BUILD_BEGIN===\n'
set +e
swift build -j $(printf '%q' "$SWIFT_JOBS")
RC=\$?
set -e
printf '===LINT_BUILD_END===\n'
printf 'RC=%s\n' "\$RC"
REMOTE
)

  set +e
  out_rc=0
  "$SSH_CMD" "$TARGET_USERHOST" "bash -lc $(printf '%q' "$remote_cmd")" >"$log_file" 2>&1
  out_rc=$?
  set -e

  if [[ "$out_rc" -ne 0 ]]; then
    # SSH transport failure
    if ! grep -q 'LINT_BLOCK_REASON=' "$log_file" 2>/dev/null \
      && ! grep -q '===LINT_BUILD_BEGIN===' "$log_file" 2>/dev/null; then
      emit_conclusion BLOCKED "ssh failed exit=${out_rc}"
      return 1
    fi
  fi

  if grep -q 'LINT_BLOCK_REASON=' "$log_file" 2>/dev/null; then
    local reason
    reason="$(sed -n 's/^LINT_BLOCK_REASON=//p' "$log_file" | head -n1)"
    [[ -n "$reason" ]] || reason="remote blocked"
    emit_conclusion BLOCKED "$reason"
    return 1
  fi

  if ! grep -q '===LINT_BUILD_BEGIN===' "$log_file" 2>/dev/null; then
    emit_conclusion BLOCKED "no build output collected"
    return 1
  fi

  conclude_from_log "$log_file"
}

conclude_from_log() {
  local log_file="$1"
  local counts findings errors warnings rc_line rc_val
  counts="$(count_findings "$log_file")"
  findings="$(printf '%s\n' "$counts" | sed -n 's/^findings=//p' | head -n1)"
  errors="$(printf '%s\n' "$counts" | sed -n 's/^errors=//p' | head -n1)"
  warnings="$(printf '%s\n' "$counts" | sed -n 's/^warnings=//p' | head -n1)"
  [[ "$findings" =~ ^[0-9]+$ ]] || findings=0
  [[ "$errors" =~ ^[0-9]+$ ]] || errors=0
  [[ "$warnings" =~ ^[0-9]+$ ]] || warnings=0

  rc_val=""
  rc_line="$(grep -E '^RC=[0-9]+$' "$log_file" | tail -n1 || true)"
  if [[ -n "$rc_line" ]]; then
    rc_val="${rc_line#RC=}"
  fi

  log "findings=${findings} errors=${errors} warnings=${warnings} rc=${rc_val:-unknown}"
  printf 'FINDINGS: total=%s errors=%s warnings=%s\n' "$findings" "$errors" "$warnings"

  if [[ -z "$rc_val" ]]; then
    emit_conclusion BLOCKED "missing RC= completion signal in build log"
    return 1
  fi

  if (( findings > 0 )); then
    emit_conclusion FINDINGS "$findings"
    # Findings are reportable; exit 0 so automation can parse CONCLUSION.
    return 0
  fi

  if [[ "$rc_val" != "0" ]]; then
    # Build failed but our regex found no diagnostics — still a finding surface.
    emit_conclusion FINDINGS "1"
    printf 'NOTE: build rc=%s with zero parsed diagnostics; counted as FINDINGS(1)\n' "$rc_val"
    return 0
  fi

  emit_conclusion CLEAN
  return 0
}

run_main() {
  parse_target
  [[ -n "$REV" ]] || die "--rev is required"
  if ! [[ "$REV" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    die "--rev must look like a git commit sha (7-40 hex); got: $REV"
  fi
  require_positive_jobs

  print_plan

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'CONCLUSION: LINT_BLOCKED(dry-run: plan only; no SSH/build executed)\n'
    printf 'NOTE: dry-run default; pass --execute to run remote swift build -j %s\n' "$SWIFT_JOBS"
    exit 0
  fi

  run_remote_build
}

require_positive_jobs() {
  [[ "$SWIFT_JOBS" =~ ^[1-9][0-9]*$ ]] || die "TATWO_LINT_SWIFT_JOBS must be positive integer"
}

# --- selftest (stub executor; no real SSH) ---

run_selftest() {
  local root failures=0 out rc
  root="$(mktemp -d "${TMPDIR:-/tmp}/tatwo-lint-lane-selftest.XXXXXX")"
  printf 'selftest: root=%s\n' "$root"

  # --- CLEAN ---
  cat >"$root/clean.log" <<'EOF'
REV=deadbeefcafebabe0123456789abcdef01234567
===LINT_BUILD_BEGIN===
Building for debugging...
Build complete! (1.23s)
===LINT_BUILD_END===
RC=0
EOF

  set +e
  out="$(
    TATWO_LINT_STUB_MODE=1 \
    TATWO_LINT_STUB_BUILD_LOG="$root/clean.log" \
    TATWO_LINT_SSH_CMD="false" \
    TATWO_LINT_WORK_ROOT="$root/work-clean" \
      bash "$SCRIPT_PATH" \
        --target "ssh:stubuser@stubhost:$root/fake-worktree" \
        --rev deadbeefcafebabe0123456789abcdef01234567 \
        --execute 2>&1
  )"
  rc=$?
  set -e
  printf 'selftest: [clean] exit=%s\n' "$rc"
  printf '%s\n' "$out" | tail -n 15
  if ! grep -F 'CONCLUSION: LINT_CLEAN' <<<"$out" >/dev/null; then
    printf 'selftest: [clean] expected LINT_CLEAN\n' >&2
    failures=$((failures + 1))
  elif [[ "$rc" -ne 0 ]]; then
    printf 'selftest: [clean] expected exit 0 got %s\n' "$rc" >&2
    failures=$((failures + 1))
  else
    printf 'selftest: [clean] PASS\n'
  fi

  # --- FINDINGS ---
  cat >"$root/findings.log" <<'EOF'
REV=deadbeefcafebabe0123456789abcdef01234567
===LINT_BUILD_BEGIN===
/tmp/src/Foo.swift:12:5: error: cannot find 'x' in scope
/tmp/src/Foo.swift:13:5: warning: immutable value 'y' was never used
/tmp/src/Bar.swift:1:1: error: expected declaration
error: fatalError
===LINT_BUILD_END===
RC=1
EOF

  set +e
  out="$(
    TATWO_LINT_STUB_MODE=1 \
    TATWO_LINT_STUB_BUILD_LOG="$root/findings.log" \
    TATWO_LINT_SSH_CMD="false" \
    TATWO_LINT_WORK_ROOT="$root/work-findings" \
      bash "$SCRIPT_PATH" \
        --target "ssh:stubuser@stubhost:$root/fake-worktree" \
        --rev deadbeefcafebabe0123456789abcdef01234567 \
        --execute 2>&1
  )"
  rc=$?
  set -e
  printf 'selftest: [findings] exit=%s\n' "$rc"
  printf '%s\n' "$out" | tail -n 15
  if ! grep -E 'CONCLUSION: LINT_FINDINGS\([1-9][0-9]*\)' <<<"$out" >/dev/null; then
    printf 'selftest: [findings] expected LINT_FINDINGS(n) n>0\n' >&2
    printf '%s\n' "$out" | grep CONCLUSION || true
    failures=$((failures + 1))
  else
    printf 'selftest: [findings] PASS\n'
  fi

  # --- BLOCKED ---
  set +e
  out="$(
    TATWO_LINT_STUB_MODE=1 \
    TATWO_LINT_STUB_BLOCK_REASON="rev mismatch want=abc head=def (refusing auto-checkout; user gate)" \
    TATWO_LINT_SSH_CMD="false" \
    TATWO_LINT_WORK_ROOT="$root/work-blocked" \
      bash "$SCRIPT_PATH" \
        --target "ssh:stubuser@stubhost:$root/fake-worktree" \
        --rev deadbeefcafebabe0123456789abcdef01234567 \
        --execute 2>&1
  )"
  rc=$?
  set -e
  printf 'selftest: [blocked] exit=%s\n' "$rc"
  printf '%s\n' "$out" | tail -n 15
  if ! grep -F 'CONCLUSION: LINT_BLOCKED(' <<<"$out" >/dev/null; then
    printf 'selftest: [blocked] expected LINT_BLOCKED(...)\n' >&2
    failures=$((failures + 1))
  else
    printf 'selftest: [blocked] PASS\n'
  fi

  # dry-run default (no SSH)
  set +e
  out="$(
    TATWO_LINT_SSH_CMD="false" \
      bash "$SCRIPT_PATH" \
        --target "ssh:example-user@example-host:/example/worktree" \
        --rev deadbeefcafebabe0123456789abcdef01234567 \
        --dry-run 2>&1
  )"
  rc=$?
  set -e
  printf 'selftest: [dry-run] exit=%s\n' "$rc"
  if [[ "$rc" -ne 0 ]] || ! grep -q 'dry-run' <<<"$out"; then
    printf 'selftest: [dry-run] FAIL\n' >&2
    printf '%s\n' "$out" | tail -n 20
    failures=$((failures + 1))
  else
    printf 'selftest: [dry-run] PASS\n'
  fi

  # no hard-coded production hosts in script body (example- only allowed in docs/selftest strings)
  if grep -E 'ssh:[a-zA-Z0-9._-]+@(Mac-mini|TATWO|192\.168\.)' "$SCRIPT_PATH" >/dev/null 2>&1; then
    printf 'selftest: hard-coded host pattern found\n' >&2
    failures=$((failures + 1))
  else
    printf 'selftest: [no-hardcoded-host] PASS\n'
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
