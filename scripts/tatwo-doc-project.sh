#!/usr/bin/env bash
# tatwo-doc-project.sh — Domain Data Sync Plane S1：治理文件唯讀投影
#
# 權威：
#   docs/protocol/DEPLOYMENT_PLANES_DESIGN.md §B.2.3
#   docs/protocol/SKILLET_DOCS_PLACEMENT_DECISION.md（唯讀投影設計要點）
#   Core: Packages/TatwoUltraworkCore/.../TatwoDocProjectionV1.swift
#
# 鐵律：
#   - 預設 --dry-run（只印計畫，不寫出）
#   - 來源路徑全走 --sources 注入；腳本內無私人絕對路徑硬編
#   - 單向 mini/canonical → 設備；接收端編輯不回寫
#   - header 只含 logicalName + hash12，不含私人絕對路徑
#   - 2026-07-23：拒絕任何路徑含 threads / .thread 的來源（聊天串不進 phase-1）
#   - 禁 git 寫入、禁網路、不跨機傳輸（傳輸屬 S2）
#
# 用法：
#   bash scripts/tatwo-doc-project.sh \
#     --sources 'os.md:/path/to/os.md,issue.md:/path/to/issue.md,TODO.md:/path/to/TODO.md' \
#     --out /path/to/projection-dir \
#     [--dry-run | --execute] \
#     [--revision <commit>]
#
#   bash scripts/tatwo-doc-project.sh --verify /path/to/projection-dir \
#     --sources 'os.md:/path/to/os.md,...'
#
#   bash scripts/tatwo-doc-project.sh --selftest
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

SOURCES_SPEC=""
OUT_DIR=""
VERIFY_DIR=""
DRY_RUN=1
EXECUTE=0
SELFTEST=0
REVISION_OVERRIDE=""
MODE=""  # project | verify | selftest

usage() {
  cat <<'EOF'
Usage:
  bash scripts/tatwo-doc-project.sh \
    --sources <name:path,...> \
    --out <dir> \
    [--dry-run | --execute] \
    [--revision <commit>]

  bash scripts/tatwo-doc-project.sh \
    --verify <dir> \
    --sources <name:path,...>

  bash scripts/tatwo-doc-project.sh --selftest

Purpose:
  Project governance docs (os.md / issue.md / TODO.md) as one-way read-only
  projections with content hash + source commit stamp. Receiver edits do not
  write back (Domain Data Sync Plane S1).

Scope (2026-07-23):
  Sources whose path contains "threads" or ".thread" are REJECTED.
  Reason: chat threads/messages are excluded from phase-1 Domain Data Sync;
  only governance document projections are in scope for this plane slice.

Defaults:
  --dry-run   ON (plan only; no files written)

Modes:
  project (default when --out given)
  verify  (--verify <dir>): three-state stats; non-zero exit if any tampered
  selftest

Manifest (on --execute):
  <out>/projection-manifest.json
  <out>/<logicalName>.projected.md
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

log() {
  printf '[doc-project] %s\n' "$*" >&2
}

utc_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

sha256_text() {
  # stdin → 64 hex
  shasum -a 256 | awk '{print $1}'
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

is_threads_forbidden_path() {
  local path_lc
  path_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$path_lc" in
    *threads*|*.thread*) return 0 ;;
    *) return 1 ;;
  esac
}

# Privacy: projected header / notice must never contain these.
header_has_private_path() {
  local text="$1"
  if printf '%s' "$text" | grep -E '/Users/|/Volumes/|~/\.codex/|\$HOME/' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

make_header() {
  local logical="$1" hash="$2"
  local hash12="${hash:0:12}"
  printf '此為唯讀投影，權威在 %s@%s' "$logical" "$hash12"
}

resolve_revision() {
  if [[ -n "$REVISION_OVERRIDE" ]]; then
    printf '%s\n' "$REVISION_OVERRIDE"
    return 0
  fi
  if git -C "$ROOT_DIR" rev-parse HEAD >/dev/null 2>&1; then
    git -C "$ROOT_DIR" rev-parse HEAD
    return 0
  fi
  printf 'unknown\n'
}

# Parse --sources into parallel arrays SOURCE_NAMES[] SOURCE_PATHS[]
SOURCE_NAMES=()
SOURCE_PATHS=()

parse_sources() {
  local spec="$1"
  [[ -n "$spec" ]] || die "--sources is required (inject name:path,...; no hardcoded paths)"
  SOURCE_NAMES=()
  SOURCE_PATHS=()
  local IFS=','
  # shellcheck disable=SC2206
  local parts=($spec)
  local entry name path
  for entry in "${parts[@]}"; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ -n "$entry" ]] || continue
    case "$entry" in
      *:*)
        name="${entry%%:*}"
        path="${entry#*:}"
        ;;
      *)
        die "invalid --sources entry (want name:path): $entry"
        ;;
    esac
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    path="${path#"${path%%[![:space:]]*}"}"
    path="${path%"${path##*[![:space:]]}"}"
    [[ -n "$name" ]] || die "empty logical name in --sources"
    [[ -n "$path" ]] || die "empty path for $name in --sources"
    if is_threads_forbidden_path "$path" || is_threads_forbidden_path "$name"; then
      die "refusing source '$name' path='$path': paths containing 'threads' or '.thread' are excluded from Domain Data Sync phase-1 (2026-07-23 ruling; chat threads are not projected)"
    fi
    SOURCE_NAMES+=("$name")
    SOURCE_PATHS+=("$path")
  done
  [[ ${#SOURCE_NAMES[@]} -gt 0 ]] || die "--sources produced zero entries"
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
      MODE="selftest"
      shift
      ;;
    --sources)
      [[ $# -ge 2 ]] || die "--sources requires a value"
      SOURCES_SPEC="$2"
      shift 2
      ;;
    --out)
      [[ $# -ge 2 ]] || die "--out requires a value"
      OUT_DIR="$2"
      shift 2
      ;;
    --verify)
      [[ $# -ge 2 ]] || die "--verify requires a value"
      VERIFY_DIR="$2"
      MODE="verify"
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
    --revision)
      [[ $# -ge 2 ]] || die "--revision requires a value"
      REVISION_OVERRIDE="$2"
      shift 2
      ;;
    --sources=*|--out=*|--verify=*|--revision=*)
      key="${1%%=*}"
      val="${1#*=}"
      [[ -n "$val" ]] || die "$key requires a value"
      case "$key" in
        --sources) SOURCES_SPEC="$val" ;;
        --out) OUT_DIR="$val" ;;
        --verify) VERIFY_DIR="$val"; MODE="verify" ;;
        --revision) REVISION_OVERRIDE="$val" ;;
      esac
      shift
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

if [[ "$SELFTEST" -eq 1 ]]; then
  if [[ -n "$SOURCES_SPEC" || -n "$OUT_DIR" || -n "$VERIFY_DIR" || "$EXECUTE" -eq 1 ]]; then
    die "--selftest cannot be combined with other run arguments"
  fi
fi

if [[ -z "$MODE" ]]; then
  MODE="project"
fi

# --- project helpers ---

project_plan_line() {
  local name="$1" path="$2" hash="$3" rev="$4" header="$5"
  # Plan output redacts absolute path content; shows only basename of source.
  local base
  base="$(basename "$path")"
  printf 'PLAN  logicalName=%s sourceBase=%s sourceHash=%s sourceRevision=%s header=%s\n' \
    "$name" "$base" "$hash" "$rev" "$header"
}

render_projection_file() {
  local logical="$1" hash="$2" rev="$3" projected_at="$4" header="$5" body_file="$6"
  {
    printf '<!-- tatwo-doc-projection-v1\n'
    printf 'schema: TatwoProjectedDocV1\n'
    printf 'logicalName: %s\n' "$logical"
    printf 'sourceHash: %s\n' "$hash"
    printf 'sourceRevision: %s\n' "$rev"
    printf 'projectedAt: %s\n' "$projected_at"
    printf 'notice: %s\n' "$header"
    printf '%s\n' '-->'
    # body exactly
    cat "$body_file"
  }
}

atomic_write() {
  local dest="$1"
  local parent tmp
  parent="$(dirname "$dest")"
  mkdir -p "$parent"
  tmp="$(mktemp "${parent}/.tatwo-doc-proj.XXXXXX")"
  cat >"$tmp"
  mv -f "$tmp" "$dest"
}

run_project() {
  parse_sources "$SOURCES_SPEC"
  [[ -n "$OUT_DIR" ]] || die "--out is required for project mode"

  local rev projected_at
  rev="$(resolve_revision)"
  projected_at="$(utc_iso)"

  printf '=== Tatwo Doc Projection PLAN (dry-run=%s) ===\n' "$DRY_RUN"
  printf 'schema: TatwoDocProjectionV1\n'
  printf 'mode: project\n'
  printf 'sourceRevision: %s\n' "$rev"
  printf 'projectedAt: %s\n' "$projected_at"
  printf 'out: %s\n' "$OUT_DIR"
  printf 'count: %s\n' "${#SOURCE_NAMES[@]}"
  printf 'direction: one-way canonical→device (no write-back)\n'
  printf 'threads_policy: reject paths containing threads|.thread (2026-07-23)\n'
  printf '\n'

  local i name path body_hash header out_file
  local -a plan_hashes=() plan_names=() plan_revs=() plan_headers=()

  for i in "${!SOURCE_NAMES[@]}"; do
    name="${SOURCE_NAMES[$i]}"
    path="${SOURCE_PATHS[$i]}"
    [[ -f "$path" ]] || die "source not found for $name: (path injected; file missing)"
    body_hash="$(sha256_file "$path")"
    header="$(make_header "$name" "$body_hash")"
    if header_has_private_path "$header"; then
      die "privacy gate: header would contain private absolute path for $name"
    fi
    project_plan_line "$name" "$path" "$body_hash" "$rev" "$header"
    plan_names+=("$name")
    plan_hashes+=("$body_hash")
    plan_revs+=("$rev")
    plan_headers+=("$header")
  done

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '\nCONCLUSION: DRY_RUN (no files written; pass --execute to materialize)\n'
    return 0
  fi

  mkdir -p "$OUT_DIR"
  local manifest_json entries="" first=1
  entries=""
  first=1
  for i in "${!plan_names[@]}"; do
    name="${plan_names[$i]}"
    path="${SOURCE_PATHS[$i]}"
    body_hash="${plan_hashes[$i]}"
    rev="${plan_revs[$i]}"
    header="${plan_headers[$i]}"
    out_file="$OUT_DIR/${name}.projected.md"
    render_projection_file "$name" "$body_hash" "$rev" "$projected_at" "$header" "$path" \
      | atomic_write "$out_file"
    log "wrote $out_file"
    if [[ "$first" -eq 1 ]]; then
      first=0
    else
      entries+=","
    fi
    entries+=$(printf '\n    {"logicalName":"%s","sourceHash":"%s","sourceRevision":"%s","file":"%s.projected.md","header":"%s"}' \
      "$name" "$body_hash" "$rev" "$name" "$header")
  done

  manifest_json=$(cat <<EOF
{
  "schema": "TatwoDocProjectionManifestV1",
  "plane": "domain-data-sync",
  "slice": "S1-doc-readonly-projection",
  "direction": "one-way-canonical-to-device",
  "projectedAt": "$projected_at",
  "sourceRevision": "$rev",
  "documents": [$entries
  ]
}
EOF
)
  printf '%s\n' "$manifest_json" | atomic_write "$OUT_DIR/projection-manifest.json"
  log "wrote $OUT_DIR/projection-manifest.json"
  printf '\nCONCLUSION: EXECUTED projections=%s\n' "${#plan_names[@]}"
}

# Parse rendered projection → emit: logical|hash|rev|header|bodyfile
# Writes body to a temp file path printed as last field via globals.
parse_projection_file() {
  local file="$1"
  local body_out="$2"
  python3 - "$file" "$body_out" <<'PY'
import re, sys
path, body_out = sys.argv[1], sys.argv[2]
text = open(path, "r", encoding="utf-8").read()
if not text.lstrip().startswith("<!-- tatwo-doc-projection-v1"):
    # allow leading BOM/noise
    if "<!-- tatwo-doc-projection-v1" not in text[:200]:
        raise SystemExit(f"missing marker in {path}")
m = re.search(r"<!--\s*tatwo-doc-projection-v1\b(.*?)\n-->\n?", text, re.S)
if not m:
    raise SystemExit(f"unclosed header in {path}")
header_block = m.group(1)
body = text[m.end():]
fields = {}
for line in header_block.splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    if ":" not in line:
        continue
    k, v = line.split(":", 1)
    fields[k.strip()] = v.strip()
for req in ("logicalName", "sourceHash", "sourceRevision", "notice"):
    if req not in fields:
        raise SystemExit(f"missing {req} in {path}")
open(body_out, "w", encoding="utf-8").write(body)
print(fields["logicalName"])
print(fields["sourceHash"].lower())
print(fields["sourceRevision"])
print(fields["notice"])
PY
}

run_verify() {
  parse_sources "$SOURCES_SPEC"
  [[ -n "$VERIFY_DIR" ]] || die "--verify requires a directory"
  [[ -d "$VERIFY_DIR" ]] || die "verify dir not found: $VERIFY_DIR"

  local rev
  rev="$(resolve_revision)"

  lookup_source_path() {
    # lookup_source_path <logicalName> → prints path or empty
    local want="$1" i
    for i in "${!SOURCE_NAMES[@]}"; do
      if [[ "${SOURCE_NAMES[$i]}" == "$want" ]]; then
        printf '%s\n' "${SOURCE_PATHS[$i]}"
        return 0
      fi
    done
    return 1
  }

  local in_sync=0 stale=0 tampered=0 missing=0
  local proj logical hash p_rev header body_tmp live_hash live_rev
  local parse_out body_hash expected_header spath

  printf '=== Tatwo Doc Projection VERIFY ===\n'
  printf 'dir: %s\n' "$VERIFY_DIR"
  printf '\n'

  shopt -s nullglob
  local files=("$VERIFY_DIR"/*.projected.md)
  shopt -u nullglob
  if [[ ${#files[@]} -eq 0 ]]; then
    die "no *.projected.md under verify dir"
  fi

  for proj in "${files[@]}"; do
    body_tmp="$(mktemp)"
    # parse_projection_file prints 4 lines (logical, hash, rev, notice)
    parse_out="$(parse_projection_file "$proj" "$body_tmp")"
    logical="$(printf '%s\n' "$parse_out" | sed -n '1p')"
    hash="$(printf '%s\n' "$parse_out" | sed -n '2p')"
    p_rev="$(printf '%s\n' "$parse_out" | sed -n '3p')"
    header="$(printf '%s\n' "$parse_out" | sed -n '4p')"

    if header_has_private_path "$header"; then
      log "privacy FAIL: header has private path in $proj"
      tampered=$((tampered + 1))
      printf 'RESULT  %s → tampered(localEdited) [private path in header]\n' "$logical"
      rm -f "$body_tmp"
      continue
    fi

    # Local integrity: body hash must match claimed sourceHash; header must match.
    body_hash="$(sha256_file "$body_tmp")"
    expected_header="$(make_header "$logical" "$hash")"
    if [[ "$body_hash" != "$hash" || "$header" != "$expected_header" ]]; then
      tampered=$((tampered + 1))
      printf 'RESULT  %s → tampered(localEdited)\n' "$logical"
      rm -f "$body_tmp"
      continue
    fi

    spath="$(lookup_source_path "$logical" || true)"
    if [[ -z "$spath" ]]; then
      missing=$((missing + 1))
      printf 'RESULT  %s → missing_source (not in --sources)\n' "$logical"
      rm -f "$body_tmp"
      continue
    fi
    if [[ ! -f "$spath" ]]; then
      missing=$((missing + 1))
      printf 'RESULT  %s → missing_source (file absent)\n' "$logical"
      rm -f "$body_tmp"
      continue
    fi
    live_hash="$(sha256_file "$spath")"
    live_rev="$rev"
    # Live revision defaults to resolve_revision (same as project); override via --revision.
    if [[ "$live_hash" != "$hash" || "$live_rev" != "$p_rev" ]]; then
      stale=$((stale + 1))
      printf 'RESULT  %s → stale(sourceMoved) liveHash=%s claimedHash=%s liveRev=%s claimedRev=%s\n' \
        "$logical" "${live_hash:0:12}" "${hash:0:12}" "${live_rev:0:12}" "${p_rev:0:12}"
    else
      in_sync=$((in_sync + 1))
      printf 'RESULT  %s → inSync\n' "$logical"
    fi
    rm -f "$body_tmp"
  done

  printf '\nSTATS  inSync=%s stale=%s tampered=%s missing_source=%s\n' \
    "$in_sync" "$stale" "$tampered" "$missing"
  if [[ "$tampered" -gt 0 ]]; then
    printf 'CONCLUSION: VERIFY_FAIL (tampered=%s)\n' "$tampered"
    return 1
  fi
  printf 'CONCLUSION: VERIFY_OK\n'
  return 0
}

# --- selftest ---

run_selftest() {
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tatwo-doc-project-selftest.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  local src_dir="$tmp/sources"
  local out_dir="$tmp/out"
  mkdir -p "$src_dir" "$out_dir"

  printf '# fixture os\nrule: A\n' >"$src_dir/os.md"
  printf '# fixture issue\nopen: 1\n' >"$src_dir/issue.md"
  printf '# fixture TODO\nitem: x\n' >"$src_dir/TODO.md"

  local sources="os.md:$src_dir/os.md,issue.md:$src_dir/issue.md,TODO.md:$src_dir/TODO.md"
  local rev="selftest-revision-000000000000000000000000000000000001"

  # 1) project execute
  bash "$SCRIPT_PATH" \
    --sources "$sources" \
    --out "$out_dir" \
    --revision "$rev" \
    --execute >/dev/null

  [[ -f "$out_dir/projection-manifest.json" ]] || die "selftest: missing manifest"
  [[ -f "$out_dir/os.md.projected.md" ]] || die "selftest: missing os projection"

  # 2) verify → all inSync
  local out
  out="$(bash "$SCRIPT_PATH" --verify "$out_dir" --sources "$sources" --revision "$rev" 2>&1)" || {
    printf '%s\n' "$out" >&2
    die "selftest: inSync verify failed"
  }
  printf '%s\n' "$out" | grep -q 'inSync=3' || die "selftest: expected inSync=3; got: $out"
  printf 'selftest: [inSync] PASS\n'

  # 3) tamper local projection → tampered
  printf '\n# local edit on projection\n' >>"$out_dir/os.md.projected.md"
  set +e
  out="$(bash "$SCRIPT_PATH" --verify "$out_dir" --sources "$sources" --revision "$rev" 2>&1)"
  local rc=$?
  set -e
  printf '%s\n' "$out" | grep -q 'tampered(localEdited)' || die "selftest: expected tampered; got: $out"
  [[ "$rc" -ne 0 ]] || die "selftest: tampered must non-zero exit"
  printf 'selftest: [tampered] PASS\n'

  # Restore os projection for stale test: re-execute clean, then move source
  rm -rf "$out_dir"
  mkdir -p "$out_dir"
  bash "$SCRIPT_PATH" \
    --sources "$sources" \
    --out "$out_dir" \
    --revision "$rev" \
    --execute >/dev/null

  printf '\n## source moved\n' >>"$src_dir/issue.md"
  set +e
  out="$(bash "$SCRIPT_PATH" --verify "$out_dir" --sources "$sources" --revision "$rev" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out" | grep -q 'stale(sourceMoved)' || die "selftest: expected stale; got: $out"
  # stale alone is not tampered → exit 0
  [[ "$rc" -eq 0 ]] || die "selftest: stale-only should exit 0"
  printf 'selftest: [stale] PASS\n'

  # 4) threads path must be rejected
  mkdir -p "$src_dir/threads"
  printf 'chat\n' >"$src_dir/threads/x.md"
  set +e
  out="$(bash "$SCRIPT_PATH" \
    --sources "chat.md:$src_dir/threads/x.md" \
    --out "$out_dir/should-fail" \
    --dry-run 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || die "selftest: threads path must be rejected"
  printf '%s\n' "$out" | grep -qi 'threads' || die "selftest: threads rejection message missing"
  printf 'selftest: [threads-reject] PASS\n'

  # 5) dry-run default writes nothing new
  local dry_out="$tmp/dry"
  mkdir -p "$dry_out"
  bash "$SCRIPT_PATH" \
    --sources "os.md:$src_dir/os.md" \
    --out "$dry_out" \
    --revision "$rev" \
    --dry-run >/dev/null
  # should not create projected file
  if compgen -G "$dry_out/*.projected.md" >/dev/null; then
    die "selftest: dry-run must not write projections"
  fi
  printf 'selftest: [dry-run-default] PASS\n'

  # 6) privacy: header has no private path markers even if source path is private-looking
  local priv_src="$tmp/Users/example/secret"
  mkdir -p "$priv_src"
  printf 'body\n' >"$priv_src/os.md"
  out="$(bash "$SCRIPT_PATH" \
    --sources "os.md:$priv_src/os.md" \
    --out "$tmp/priv-out" \
    --revision "$rev" \
    --execute 2>&1)"
  local header_line
  header_line="$(grep -E '^notice:' "$tmp/priv-out/os.md.projected.md" || true)"
  if printf '%s' "$header_line" | grep -E '/Users/|/Volumes/' >/dev/null; then
    die "selftest: header leaked private path: $header_line"
  fi
  printf 'selftest: [privacy-header] PASS\n'

  printf 'SELFTEST PASS\n'
}

# --- main ---

case "$MODE" in
  selftest)
    run_selftest
    ;;
  verify)
    run_verify
    ;;
  project)
    run_project
    ;;
  *)
    die "unknown mode: $MODE"
    ;;
esac
