#!/usr/bin/env bash
# Verify that local multi-agent runners use Work OS authority lanes instead of
# inheriting stale "Codex/Claude revoked me" policy language.
set -euo pipefail

repo="."
json=0
run_grok=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 ;;
    --json) json=1; shift ;;
    --no-grok-inspect) run_grok=0; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: scripts/tatwo-agent-authority-doctor.sh [--repo PATH] [--json] [--no-grok-inspect]

Checks:
  - AGENTS.md and CLAUDE.md point to the entrance constitution and its §4 roles.
  - Repository pointers do not reinstall the retired 1.0 lane contract.
  - codex-claude-bridge and grok-isolated wrappers contain route-scope language.
  - Grok inspect sees the project instructions from an isolated HOME, so the
    instructions themselves must be lane-safe.
EOF
      exit 0
      ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

repo="$(cd "$repo" && pwd)"
results_file="$(mktemp "${TMPDIR:-/tmp}/tatwo-agent-authority.XXXXXX")"
inspect_file="$(mktemp "${TMPDIR:-/tmp}/tatwo-grok-inspect.XXXXXX")"
inspect_err="$(mktemp "${TMPDIR:-/tmp}/tatwo-grok-inspect.err.XXXXXX")"

add_check() {
  local id="$1" ok="$2" detail="$3"
  printf '%s\t%s\t%s\n' "$id" "$ok" "$detail" >> "$results_file"
}

contains() {
  local file="$1" needle="$2"
  [ -f "$file" ] && grep -Fq -- "$needle" "$file"
}

check_contains() {
  local id="$1" file="$2" needle="$3" detail="$4"
  if contains "$file" "$needle"; then
    add_check "$id" true "$detail"
  else
    add_check "$id" false "missing in $file: $needle"
  fi
}

for pointer in AGENTS.md CLAUDE.md; do
  check_contains "${pointer}_constitution" "$repo/$pointer" '~/AI/TATWO OS/os.md' "points to entrance constitution"
  check_contains "${pointer}_roles" "$repo/$pointer" '憲法 §4' "roles follow constitution section 4"
  if grep -Eq 'host_delegate|sandbox_builder|blocker_class|S/M/L/XL' "$repo/$pointer"; then
    add_check "${pointer}_legacy_absent" false "retired governance remains in pointer"
  else
    add_check "${pointer}_legacy_absent" true "retired governance absent from pointer"
  fi
done

bridge="${CODEX_CLAUDE_BRIDGE:-$HOME/.codex/bin/codex-claude-bridge}"
if [ -x "$bridge" ]; then
  check_contains "bridge_delegate_scope" "$bridge" "Do not claim Codex revoked you" "bridge delegate prompt blocks false Codex revocation"
  check_contains "bridge_route_scope" "$bridge" "route_scope_unclear" "bridge reports unclear scope instead of fake revoke"
else
  add_check "bridge_present" false "codex-claude-bridge not executable at $bridge"
fi

grok_isolated="${GROK_ISOLATED_BIN:-$HOME/.codex/bin/grok-isolated}"
if [ -x "$grok_isolated" ]; then
  check_contains "grok_isolated_revoke_rule" "$grok_isolated" "Do not claim Codex or Claude revoked your permissions" "grok-isolated appends anti-revoke Work OS rule"
  check_contains "grok_isolated_unset_claude" "$grok_isolated" "-u CLAUDE_CONFIG_DIR" "grok-isolated strips Claude runner env"
  check_contains "grok_isolated_no_memory" "$grok_isolated" "GROK_ISOLATED_DEFAULT_NO_MEMORY" "grok-isolated defaults headless calls to fresh-session no-memory"
else
  add_check "grok_isolated_present" false "grok-isolated not executable at $grok_isolated"
  run_grok=0
fi

resolve_gateway_label() {
  if [ -n "${MODEL_GATEWAY_LABEL:-}" ]; then
    printf '%s\n' "$MODEL_GATEWAY_LABEL"
    return
  fi
  local current="com.tatwo.codex-model-gateway" registered
  # Read-only legacy discovery: never embed an owner's name or re-register a service.
  registered="$(launchctl list 2>/dev/null | awk '$3 ~ /^com\.[^.]+\.codex-model-gateway$/ {print $3}' || true)"
  if printf '%s\n' "$registered" | grep -Fxq "$current"; then
    printf '%s\n' "$current"
  elif [ -n "$registered" ] && [ "$(printf '%s\n' "$registered" | wc -l | tr -d ' ')" -eq 1 ]; then
    printf '%s\n' "$registered"
  else
    printf '%s\n' "$current"
  fi
}

label="$(resolve_gateway_label)"
model_gateway_server="${MODEL_GATEWAY_SERVER:-}"
if [ -z "$model_gateway_server" ] && command -v launchctl >/dev/null 2>&1; then
  model_gateway_server="$(
    launchctl print "gui/$(id -u)/$label" 2>/dev/null |
      awk '/server\.js/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0); print; exit}' || true
  )"
fi
if [ -z "$model_gateway_server" ]; then
  if [ -f "$HOME/Library/Application Support/tatwo2/skills/codex-app-model-gateway/runtime/server.js" ]; then
    model_gateway_server="$HOME/Library/Application Support/tatwo2/skills/codex-app-model-gateway/runtime/server.js"
  else
    model_gateway_server="$HOME/Library/Application Support/tatwo2/model-gateway/server.js"
  fi
fi
if [ -f "$model_gateway_server" ]; then
  check_contains "gateway_authority_frame" "$model_gateway_server" "TATWO Work OS authority frame" "model gateway injects anti-revoke authority frame into external routes"
  check_contains "gateway_blocker_schema" "$model_gateway_server" "do not invent new blocker_class names" "model gateway requires structured blocker classes"
  check_contains "gateway_authority_source_schema" "$model_gateway_server" "authority_source must be exactly" "model gateway requires structured authority_source values"
else
  add_check "gateway_authority_frame" false "model gateway server not found at $model_gateway_server"
fi

local_grok="$HOME/.local/bin/grok"
if [ -e "$local_grok" ]; then
  local_grok_target="$(readlink "$local_grok" 2>/dev/null || true)"
  case "$local_grok_target" in
    *"/.codex/bin/grok"|*"/.codex/bin/grok-isolated")
      add_check "local_grok_shim" true "~/.local/bin/grok points to Work OS isolated shim"
      ;;
    *)
      add_check "local_grok_shim" false "~/.local/bin/grok points to raw/non-isolated target: ${local_grok_target:-not-a-symlink}"
      ;;
  esac
else
  add_check "local_grok_shim" true "~/.local/bin/grok absent; PATH should still prefer ~/.codex/bin/grok"
fi

expected_grok_command="${GROK_ISOLATED_BIN:-$HOME/.codex/bin/grok-isolated}"
active_grok_command=""
if command -v launchctl >/dev/null 2>&1; then
  active_grok_command="$(launchctl print "gui/$(id -u)/$label" 2>/dev/null | awk -F'=> ' '/GROK_COMMAND =>/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' || true)"
fi
if [ -n "$active_grok_command" ]; then
  if [ "$active_grok_command" = "$expected_grok_command" ]; then
    add_check "launchd_grok_isolated" true "active gateway GROK_COMMAND uses isolated launcher"
  else
    add_check "launchd_grok_isolated" false "active gateway GROK_COMMAND is not isolated: $active_grok_command"
  fi
else
  add_check "launchd_grok_isolated" true "active gateway GROK_COMMAND not readable; skipped live launchd drift check"
fi

grok_inspect_ok=false
if [ "$run_grok" -eq 1 ]; then
  if "$grok_isolated" --cwd "$repo" inspect --json > "$inspect_file" 2> "$inspect_err"; then
    grok_inspect_ok=true
    add_check "grok_inspect" true "grok inspect works from isolated HOME"
  else
    add_check "grok_inspect" false "$(tr '\n' ' ' < "$inspect_err" | cut -c1-240)"
  fi
fi

if [ "$json" -eq 1 ]; then
  python3 - "$results_file" "$inspect_file" "$repo" "$grok_inspect_ok" <<'PY'
import json, sys
from pathlib import Path

results_path, inspect_path, repo, grok_ok = sys.argv[1:5]
checks = []
for line in Path(results_path).read_text(encoding="utf-8", errors="replace").splitlines():
    if not line:
        continue
    ident, ok, detail = (line.split("\t", 2) + [""])[:3]
    checks.append({"id": ident, "ok": ok == "true", "detail": detail})

inspect_summary = None
if grok_ok == "true":
    try:
        payload = json.loads(Path(inspect_path).read_text(encoding="utf-8"))
        inspect_summary = {
            "grokVersion": payload.get("grokVersion"),
            "projectTrusted": payload.get("projectTrusted"),
            "projectInstructions": [
                {
                    "path": item.get("path"),
                    "scope": item.get("scope"),
                    "fileType": item.get("fileType"),
                    "approxTokens": item.get("approxTokens"),
                }
                for item in payload.get("projectInstructions") or []
            ],
            "permissionSources": (payload.get("permissions") or {}).get("sources") or [],
        }
    except Exception as exc:
        inspect_summary = {"error": str(exc)}

print(json.dumps({
    "ok": all(item["ok"] for item in checks),
    "repo": repo,
    "checks": checks,
    "grokInspect": inspect_summary,
}, ensure_ascii=False, indent=2))
PY
else
  fails=0
  while IFS=$'\t' read -r ident ok detail; do
    if [ "$ok" = "true" ]; then
      printf 'PASS %-28s %s\n' "$ident" "$detail"
    else
      printf 'FAIL %-28s %s\n' "$ident" "$detail"
      fails=$((fails + 1))
    fi
  done < "$results_file"
  [ "$fails" -eq 0 ]
fi
