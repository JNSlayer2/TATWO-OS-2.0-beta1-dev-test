#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_ROOT="$ROOT_DIR/.tatwo-ultrawork/evidence/$(date -u +%Y%m%dT%H%M%SZ)"
REDACTION_SCAN_FILE="/tmp/tatwo-redaction-scan.$$"
STATE_SMOKE_DIR="$EVIDENCE_ROOT/state-smoke"
mkdir -p "$EVIDENCE_ROOT"
trap 'rm -f "$REDACTION_SCAN_FILE"' EXIT

log() { printf '\n==> %s\n' "$*"; }
run_and_capture() {
  local name="$1"
  shift
  log "$name"
  "$@" 2>&1 | tee "$EVIDENCE_ROOT/$name.log"
}
run_and_capture_expected_blocked() {
  local name="$1"
  shift
  log "$name (expected blocked)"
  set +e
  "$@" 2>&1 | tee "$EVIDENCE_ROOT/$name.log"
  local status=${PIPESTATUS[0]}
  set -e
  if [ "$status" -eq 0 ]; then
    echo "${name}_expected_blocked=failed" | tee -a "$EVIDENCE_ROOT/$name.log" >&2
    exit 1
  fi
  echo "${name}_expected_blocked=passed status=$status" | tee -a "$EVIDENCE_ROOT/$name.log"
}

log "Tatwo Ultrawork sandbox check"
echo "evidence_root=$EVIDENCE_ROOT"
echo "host_mutation=false"
echo "note=does not edit Codex config, signed app bundle, auth/session files, or LaunchAgents"

run_and_capture swift-test swift test --package-path "$ROOT_DIR"
run_and_capture build-all swift build --package-path "$ROOT_DIR"
run_and_capture build-cli swift build --package-path "$ROOT_DIR" --product tatwo-ultrawork
run_and_capture build-app swift build --package-path "$ROOT_DIR" --product TatwoUltraworkMac
run_and_capture doctor swift run --package-path "$ROOT_DIR" tatwo-ultrawork doctor --json
run_and_capture mode-list swift run --package-path "$ROOT_DIR" tatwo-ultrawork mode list --json
run_and_capture scenario-list swift run --package-path "$ROOT_DIR" tatwo-ultrawork scenario list --json
run_and_capture team-traits swift run --package-path "$ROOT_DIR" tatwo-ultrawork teams traits --json
run_and_capture team-list swift run --package-path "$ROOT_DIR" tatwo-ultrawork teams list --json
run_and_capture team-recommend-design swift run --package-path "$ROOT_DIR" tatwo-ultrawork teams recommend --mode L --scenario design --json
run_and_capture team-dashboard swift run --package-path "$ROOT_DIR" tatwo-ultrawork teams dashboard --mode XL --scenario coding --json
run_and_capture integration-plan swift run --package-path "$ROOT_DIR" tatwo-ultrawork integration plan --json
run_and_capture integration-stability swift run --package-path "$ROOT_DIR" tatwo-ultrawork integration stability --json
run_and_capture integration-fugu-policy swift run --package-path "$ROOT_DIR" tatwo-ultrawork integration fugu-policy --json
run_and_capture colima-preflight swift run --package-path "$ROOT_DIR" tatwo-ultrawork colima preflight --json
run_and_capture colima-run-dry swift run --package-path "$ROOT_DIR" tatwo-ultrawork colima run --mode L --scenario code --objective "sandbox optional colima verifier" --dry-run --json
run_and_capture colima-runner-preflight node "$ROOT_DIR/scripts/tatwo-colima-sandbox-runner.mjs" --preflight --json
run_and_capture colima-runner-dry node "$ROOT_DIR/scripts/tatwo-colima-sandbox-runner.mjs" --dry-run --objective "sandbox optional colima verifier" --json
run_and_capture codex-disconnect-guard node "$ROOT_DIR/scripts/tatwo-codex-disconnect-guard.mjs" --json
run_and_capture team-loop-js node "$ROOT_DIR/scripts/tatwo-team-loop.mjs" --mode L --scenario design --objective "sandbox team loop check"
run_and_capture workflow-preview swift run --package-path "$ROOT_DIR" tatwo-ultrawork workflow preview --mode XL --scenario code --json
run_and_capture workflow-run-dry swift run --package-path "$ROOT_DIR" tatwo-ultrawork workflow run --mode XL --scenario code --objective "sandbox workflow-first check" --dry-run --json
run_and_capture handoff-pack swift run --package-path "$ROOT_DIR" tatwo-ultrawork handoff pack --mode XL --scenario code --objective "sandbox workflow-first check" --json
run_and_capture install-plan swift run --package-path "$ROOT_DIR" tatwo-ultrawork install plan --json
run_and_capture sandbox-preflight swift run --package-path "$ROOT_DIR" tatwo-ultrawork sandbox preflight --json
run_and_capture host-preflight swift run --package-path "$ROOT_DIR" tatwo-ultrawork host preflight --json
run_and_capture host-backup-plan swift run --package-path "$ROOT_DIR" tatwo-ultrawork host backup-plan --json
run_and_capture host-live-smoke-plan swift run --package-path "$ROOT_DIR" tatwo-ultrawork host live-smoke-plan --json
run_and_capture host-receipt-flow swift run --package-path "$ROOT_DIR" tatwo-ultrawork host receipt-flow --json
run_and_capture host-install-gate swift run --package-path "$ROOT_DIR" tatwo-ultrawork host install-gate --json
run_and_capture host-install-runway node "$ROOT_DIR/scripts/tatwo-host-install-runway.mjs" --evidence-dir "$EVIDENCE_ROOT" --json || true
run_and_capture host-sandbox-rehearsal node "$ROOT_DIR/scripts/tatwo-host-sandbox-rehearsal.mjs" --work-dir "$EVIDENCE_ROOT/host-rehearsal-work" --json
run_and_capture host-preflight-live node "$ROOT_DIR/scripts/tatwo-host-preflight.mjs" --json
run_and_capture host-backup-plan-dry node "$ROOT_DIR/scripts/tatwo-host-backup-plan.mjs" --dry-run --json
run_and_capture host-rollback-plan-dry node "$ROOT_DIR/scripts/tatwo-host-rollback-plan.mjs" --json
run_and_capture host-same-thread-smoke-dry node "$ROOT_DIR/scripts/tatwo-host-same-thread-smoke.mjs" --json
run_and_capture host-mcp-registration-smoke node "$ROOT_DIR/scripts/tatwo-host-mcp-registration-smoke.mjs" --json
run_and_capture route-risk-dashboard node "$ROOT_DIR/scripts/tatwo-route-risk-dashboard.mjs" --evidence-dir "$EVIDENCE_ROOT" --json
run_and_capture route-smoke-plan node "$ROOT_DIR/scripts/tatwo-route-smoke-plan.mjs" --evidence-dir "$EVIDENCE_ROOT" --json
run_and_capture route-live-smoke-receipts node "$ROOT_DIR/scripts/tatwo-route-live-smoke-receipts.mjs" --evidence-dir "$EVIDENCE_ROOT" --json
run_and_capture state-export env TATWO_ULTRAWORK_STATE_DIR="$STATE_SMOKE_DIR" swift run --package-path "$ROOT_DIR" tatwo-ultrawork state export --json
run_and_capture state-set-mode env TATWO_ULTRAWORK_STATE_DIR="$STATE_SMOKE_DIR" swift run --package-path "$ROOT_DIR" tatwo-ultrawork state set-mode --mode XL --scenario code --json
run_and_capture memory-add env TATWO_ULTRAWORK_STATE_DIR="$STATE_SMOKE_DIR" swift run --package-path "$ROOT_DIR" tatwo-ultrawork memory add --category failure_mode --summary "UI needs screenshot hash before pass" --tags "ui,gate" --json
run_and_capture memory-list env TATWO_ULTRAWORK_STATE_DIR="$STATE_SMOKE_DIR" swift run --package-path "$ROOT_DIR" tatwo-ultrawork memory list --json
run_and_capture mcp-smoke node "$ROOT_DIR/scripts/tatwo-ultrawork-mcp-smoke.mjs"
run_and_capture mcp-adversarial-smoke node "$ROOT_DIR/scripts/tatwo-ultrawork-mcp-adversarial-smoke.mjs"
run_and_capture integration-adversarial-drill node "$ROOT_DIR/scripts/tatwo-integration-adversarial-drill.mjs" --evidence-dir "$EVIDENCE_ROOT" --json
run_and_capture operational-receipt-adversarial node "$ROOT_DIR/scripts/tatwo-operational-receipt-adversarial.mjs"
log "validate-sample-ui (expected fail-closed)"
set +e
swift run --package-path "$ROOT_DIR" tatwo-ultrawork validate sample-ui --json 2>&1 | tee "$EVIDENCE_ROOT/validate-sample-ui.log"
sample_status=${PIPESTATUS[0]}
set -e
if [ "$sample_status" -eq 0 ]; then
  echo "validate_sample_ui_expected_failure=failed" >&2
  exit 1
fi
echo "validate_sample_ui_expected_failure=passed" | tee -a "$EVIDENCE_ROOT/validate-sample-ui.log"

log "redaction scan"
if grep -RInE '(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}|(access_token|refresh_token|api_key)[[:space:]]*[:=][[:space:]]*"[A-Za-z0-9._-]{20,}"|Authorization: Bearer [A-Za-z0-9._-]{20,}' \
  "$ROOT_DIR" \
  --exclude-dir=.build --exclude-dir=.git --exclude-dir=.swiftpm --exclude-dir=.tatwo-ultrawork >"$REDACTION_SCAN_FILE" 2>/dev/null; then
  cat "$REDACTION_SCAN_FILE" | tee "$EVIDENCE_ROOT/redaction-scan.log"
  rm -f "$REDACTION_SCAN_FILE"
  echo "redaction_scan=failed" >&2
  exit 1
else
  rm -f "$REDACTION_SCAN_FILE"
  echo "redaction_scan=passed" | tee "$EVIDENCE_ROOT/redaction-scan.log"
fi

if [ -n "${MODEL_GATEWAY_DIR:-}" ] && [ -d "$MODEL_GATEWAY_DIR" ]; then
  run_and_capture model-gateway-tests npm test --prefix "$MODEL_GATEWAY_DIR"
else
  echo "model_gateway_tests=skipped set MODEL_GATEWAY_DIR to enable" | tee "$EVIDENCE_ROOT/model-gateway-tests.log"
fi

if [ -n "${OPEN_ULTRAWORK_DIR:-}" ] && [ -d "$OPEN_ULTRAWORK_DIR" ]; then
  run_and_capture open-ultrawork-tests npm test --prefix "$OPEN_ULTRAWORK_DIR"
else
  echo "open_ultrawork_tests=skipped set OPEN_ULTRAWORK_DIR to enable" | tee "$EVIDENCE_ROOT/open-ultrawork-tests.log"
fi

run_and_capture host-readiness-gate node "$ROOT_DIR/scripts/tatwo-host-readiness-gate.mjs" --evidence-dir "$EVIDENCE_ROOT" --skip-runway-check
run_and_capture host-receipt-bundle node "$ROOT_DIR/scripts/tatwo-host-receipt-bundle.mjs" --evidence-dir "$EVIDENCE_ROOT"
run_and_capture host-install-runway-final node "$ROOT_DIR/scripts/tatwo-host-install-runway.mjs" --evidence-dir "$EVIDENCE_ROOT" --json
run_and_capture host-promotion-plan node "$ROOT_DIR/scripts/tatwo-host-promotion-plan.mjs" --evidence-dir "$EVIDENCE_ROOT" --json
run_and_capture objective-audit node "$ROOT_DIR/scripts/tatwo-objective-audit.mjs" --evidence-dir "$EVIDENCE_ROOT" --json
run_and_capture objective-adversarial node "$ROOT_DIR/scripts/tatwo-objective-adversarial.mjs" --evidence-dir "$EVIDENCE_ROOT" --json
run_and_capture_expected_blocked m2-entry-gate node "$ROOT_DIR/scripts/tatwo-m2-entry-gate.mjs" --evidence-dir "$EVIDENCE_ROOT" --human-approval human-M1-dryrun --json
run_and_capture host-readiness-gate node "$ROOT_DIR/scripts/tatwo-host-readiness-gate.mjs" --evidence-dir "$EVIDENCE_ROOT"
run_and_capture host-receipt-bundle node "$ROOT_DIR/scripts/tatwo-host-receipt-bundle.mjs" --evidence-dir "$EVIDENCE_ROOT"
run_and_capture_expected_blocked host-install-verified-gate node "$ROOT_DIR/scripts/tatwo-host-install-verified-gate.mjs" --evidence-dir "$EVIDENCE_ROOT" --human-approval human-M1-dryrun --json

log "sandbox check complete"
echo "evidence_root=$EVIDENCE_ROOT"
