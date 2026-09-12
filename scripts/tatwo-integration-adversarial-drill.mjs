#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const args = parseArgs(process.argv.slice(2));
const evidenceDir = args["evidence-dir"] ? path.resolve(String(args["evidence-dir"])) : null;
const checks = [];

const fakeGate = runSwift([
  "host", "install-gate",
  "--sandbox-validated",
  "--host-rehearsal", "rehearsal-ok",
  "--preflight-clear",
  "--human-approval", "human-ok",
  "--backup-receipt", "backup-ok",
  "--same-thread-smoke", "same-thread-ok",
  "--mcp-registration-smoke", "mcp-stdio-1234567890ab",
  "--rollback-receipt", "rollback-ok",
  "--json"
]);
const fakeGateDecision = decisionData(fakeGate);
checks.push(check(
  "swift-gate-rejects-forged-receipts",
  fakeGateDecision?.hostInstallAllowed === false
    && includesAll(fakeGateDecision?.blockedBy, [
      "invalid_host_sandbox_rehearsal_receipt",
      "invalid_host_backup_receipt",
      "invalid_live_same_thread_smoke_receipt",
      "invalid_mcp_registration_smoke_receipt",
      "invalid_rollback_receipt"
    ]),
  fakeGateDecision?.blockedBy ?? fakeGate.error,
  "Plain strings like backup-ok or mcp-stdio-* must not authorize host install."
));

const structuralGate = runSwift([
  "host", "install-gate",
  "--sandbox-validated",
  "--host-rehearsal", "rehearsal-1234567890ab",
  "--preflight-clear",
  "--human-approval", "human-approval-20260622",
  "--backup-receipt", "backup-abcdef123456",
  "--same-thread-smoke", "same-thread-abcdef123456",
  "--mcp-registration-smoke", "mcp-host-abcdef123456",
  "--rollback-receipt", "rollback-abcdef123456",
  "--json"
]);
const structuralGateDecision = decisionData(structuralGate);
checks.push(check(
  "swift-gate-is-decision-only",
  structuralGateDecision?.hostInstallAllowed === true && structuralGateDecision?.hostMutationPerformed === false,
  `allowed=${structuralGateDecision?.hostInstallAllowed}, mutated=${structuralGateDecision?.hostMutationPerformed}`,
  "Even when structurally complete, Swift gate only returns a decision and never mutates host."
));

if (evidenceDir) {
  const verified = runNode("tatwo-host-install-verified-gate.mjs", ["--evidence-dir", evidenceDir, "--human-approval", "human-approval-20260622", "--json"], { allowFailure: true });
  checks.push(check(
    "verified-gate-blocks-dry-run-evidence",
    verified.data?.hostInstallAllowed === false
      && includesAll(verified.data?.failedCheckIDs, ["backup-receipt", "rollback-receipt", "same-thread-live-smoke", "host-mcp-registration"]),
    verified.data?.failedCheckIDs ?? verified.error,
    "Sandbox evidence has rehearsal/stdout compatibility, but no real backup/live smoke/host registration; verified gate must block."
  ));
} else {
  checks.push(check("verified-gate-blocks-dry-run-evidence", true, "skipped_no_evidence_dir", "Pass --evidence-dir from sandbox check to test the evidence-backed gate."));
}

const skipRunwayFixture = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-skip-runway-fixture-"));
try {
  writeReadinessFixture(skipRunwayFixture, { modelGatewaySkipped: false, openUltraworkSkipped: false, includeRunway: false });
  const skipReadiness = runNode("tatwo-host-readiness-gate.mjs", ["--evidence-dir", skipRunwayFixture, "--skip-runway-check"]);
  fs.writeFileSync(path.join(skipRunwayFixture, "host-readiness-gate.log"), JSON.stringify(skipReadiness.data, null, 2), "utf8");
  const skipBundle = runNode("tatwo-host-receipt-bundle.mjs", ["--evidence-dir", skipRunwayFixture, "--json"]);
  checks.push(check(
    "skip-runway-readiness-is-non-promotable",
    skipReadiness.data?.status === "passed"
      && Array.isArray(skipReadiness.data?.skippedEvidence)
      && skipReadiness.data.skippedEvidence.includes("host-install-runway-final.log")
      && includesAll(skipReadiness.data?.hostInstallBlockedBy, ["runway_check_skipped"]),
    {
      status: skipReadiness.data?.status,
      skippedEvidence: skipReadiness.data?.skippedEvidence,
      blockedBy: skipReadiness.data?.hostInstallBlockedBy
    },
    "Bootstrap readiness may pass with --skip-runway-check, but must carry runway_check_skipped and skippedEvidence."
  ));
  checks.push(check(
    "receipt-bundle-forwards-runway-skip",
    skipBundle.data?.hostInstallEvidenceComplete === false
      && includesAll(skipBundle.data?.blockedBy, ["runway_check_skipped"])
      && includesAll(skipBundle.data?.forwardedReadinessBlockers, ["runway_check_skipped"]),
    {
      complete: skipBundle.data?.hostInstallEvidenceComplete,
      forwarded: skipBundle.data?.forwardedReadinessBlockers,
      blockedBy: skipBundle.data?.blockedBy
    },
    "Receipt bundle must forward runway_check_skipped so skipped runway evidence cannot be promoted."
  ));
} finally {
  fs.rmSync(skipRunwayFixture, { recursive: true, force: true });
}

const externalSkippedFixture = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-external-skipped-fixture-"));
try {
  writeReadinessFixture(externalSkippedFixture, { modelGatewaySkipped: true, openUltraworkSkipped: false, includeRunway: true });
  const externalReadiness = runNode("tatwo-host-readiness-gate.mjs", ["--evidence-dir", externalSkippedFixture]);
  fs.writeFileSync(path.join(externalSkippedFixture, "host-readiness-gate.log"), JSON.stringify(externalReadiness.data, null, 2), "utf8");
  promoteFixtureToLiveReceipts(externalSkippedFixture);
  const externalBundle = runNode("tatwo-host-receipt-bundle.mjs", ["--evidence-dir", externalSkippedFixture, "--json"]);
  const externalVerified = runNode("tatwo-host-install-verified-gate.mjs", ["--evidence-dir", externalSkippedFixture, "--human-approval", "human-approval-20260622", "--json"], { allowFailure: true });
  checks.push(check(
    "readiness-external-skips-block-host-install",
    externalReadiness.data?.status === "passed"
      && includesAll(externalReadiness.data?.hostInstallBlockedBy, ["external_model_gateway_tests_not_observed"]),
    {
      status: externalReadiness.data?.status,
      blockedBy: externalReadiness.data?.hostInstallBlockedBy
    },
    "Skipped external gateway/open-ultrawork evidence may keep sandbox green, but must remain a host-install blocker."
  ));
  checks.push(check(
    "receipt-bundle-forwards-external-blockers",
    externalBundle.data?.hostInstallEvidenceComplete === false
      && includesAll(externalBundle.data?.blockedBy, ["external_model_gateway_tests_not_observed"])
      && includesAll(externalBundle.data?.forwardedReadinessBlockers, ["external_model_gateway_tests_not_observed"]),
    {
      complete: externalBundle.data?.hostInstallEvidenceComplete,
      forwarded: externalBundle.data?.forwardedReadinessBlockers,
      blockedBy: externalBundle.data?.blockedBy
    },
    "Receipt bundle must keep skipped external tests visible even if all live-looking receipts are present."
  ));
  checks.push(check(
    "verified-gate-rejects-external-skipped-fixture",
    externalVerified.data?.hostInstallAllowed === false
      && includesAll(externalVerified.data?.failedCheckIDs, ["receipt-bundle-complete"])
      && includesAll(externalVerified.data?.blockedBy, ["external_model_gateway_tests_not_observed"]),
    {
      allowed: externalVerified.data?.hostInstallAllowed,
      failed: externalVerified.data?.failedCheckIDs,
      blockedBy: externalVerified.data?.blockedBy
    },
    "Verified host gate must not pass when readiness external tests were skipped, even with live-shaped receipts."
  ));
} finally {
  fs.rmSync(externalSkippedFixture, { recursive: true, force: true });
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-host-config-"));
try {
  const fakeHostConfig = path.join(tmp, "config.toml");
  fs.writeFileSync(fakeHostConfig, `\n[mcp_servers.tatwo-ultrawork]\ncommand = "node"\nargs = ["${path.join(repoRoot, "scripts", "tatwo-ultrawork-mcp.mjs")}"]\n`, "utf8");
  const mcpHost = runNode("tatwo-host-mcp-registration-smoke.mjs", ["--expect-host-registration", "--host-config", fakeHostConfig, "--json"]);
  checks.push(check(
    "mcp-host-receipt-requires-observed-config",
    mcpHost.data?.passed === true && mcpHost.data?.hostRegistrationObserved === true && String(mcpHost.data?.receiptID ?? "").startsWith("mcp-host-"),
    `observed=${mcpHost.data?.hostRegistrationObserved}, receipt=${mcpHost.data?.receiptID}`,
    "A host registration receipt must come from a read-only config observation plus MCP stdio smoke."
  ));
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}

const routeFixture = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-route-live-fixture-"));
try {
  const baseGoodReceipt = {
    schema: "TatwoRouteLiveSmokeReceiptV1",
    receiptID: "route-live-abcdef123456",
    routeModelID: "grok-build",
    expectedModelID: "grok-build",
    executionMode: "host_live",
    hostLiveExecution: true,
    evidenceOrigin: "deterministic_command",
    transportKind: "model_gateway",
    resultState: "pass",
    terminalEvent: "response.completed",
    responseCompletedObserved: true,
    sameThreadSequence: ["gpt-5.5", "grok-build", "gpt-5.5"],
    sameThreadContinuityBackToGPT: true,
    gptContinuityCheckPassed: true,
    hostStateObserved: true,
    providerStayedModelGateway: true,
    retryCount: 0,
    retryStormObserved: false,
    disconnectedObserved: false,
    timeoutObserved: false,
    partialStreamOnly: false,
    responseFailedObserved: false,
    hostInstallAllowed: false,
    hostMutationAllowed: false,
    canStartUI: false,
    canInstallHost: false
  };
  const routeAdversarialCases = [
    {
      id: "route-live-rejects-model-text-only",
      receipt: { ...baseGoodReceipt, evidenceOrigin: "model_text", modelTextSaysOK: true },
      reason: "model_text_cannot_prove_route_smoke",
      description: "Model text saying OK cannot prove a route live smoke."
    },
    {
      id: "route-live-rejects-partial-stream",
      receipt: { ...baseGoodReceipt, terminalEvent: "response.in_progress", partialStreamOnly: true, responseCompletedObserved: false },
      reason: "partial_stream_cannot_pass",
      description: "response.in_progress or partial-only streams cannot be promoted to response.completed."
    },
    {
      id: "route-live-rejects-wrong-model",
      receipt: { ...baseGoodReceipt, routeModelID: "opus-5", expectedModelID: "opus-5" },
      reason: "no_receipt_for_expected_route_model",
      description: "A receipt for the wrong model cannot satisfy the expected risky route."
    },
    {
      id: "route-live-rejects-no-gpt-continuity",
      receipt: { ...baseGoodReceipt, sameThreadSequence: ["grok-build"], sameThreadContinuityBackToGPT: false, gptContinuityCheckPassed: false },
      reason: "same_thread_continuity_back_to_gpt_not_observed",
      description: "The route smoke must switch back to gpt-5.5 in the same thread."
    },
    {
      id: "route-live-rejects-stdio-self-report",
      receipt: { ...baseGoodReceipt, evidenceOrigin: "mcp_server_self_report", transportKind: "mcp_stdio" },
      reason: "mcp_stdio_or_self_report_cannot_prove_route_smoke",
      description: "stdio MCP/self-report receipts cannot prove Codex App model_gateway route completion."
    },
    {
      id: "route-live-rejects-dry-run-host-live",
      receipt: { ...baseGoodReceipt, executionMode: "dry_run", hostLiveExecution: false, dryRun: true },
      reason: "dry_run_cannot_satisfy_route_live_smoke",
      description: "Dry-run route smoke cannot be promoted to host-live evidence."
    },
    {
      id: "route-live-rejects-route-receipt-authorizes-ui-host",
      receipt: { ...baseGoodReceipt, hostInstallAllowed: true, hostMutationAllowed: true, canStartUI: true, canInstallHost: true },
      reason: "route_receipt_must_not_authorize_ui_or_host_install",
      description: "A route smoke receipt is never allowed to start UI work or host install by itself."
    }
  ];
  for (const item of routeAdversarialCases) {
    resetRouteLiveFixture(routeFixture, item.receipt);
    const result = runNode("tatwo-route-live-smoke-receipts.mjs", ["--evidence-dir", routeFixture, "--json"]);
    checks.push(check(
      item.id,
      result.data?.schema === "TatwoRouteLiveSmokeReceiptsGateV1"
        && result.data?.routeLiveSmokeAllPassed === false
        && JSON.stringify(result.data).includes(item.reason)
        && result.data?.hostInstallAllowed === false
        && result.data?.uiDeferred === true,
      {
        status: result.data?.status,
        allPassed: result.data?.routeLiveSmokeAllPassed,
        blockedBy: result.data?.blockedBy,
        evaluations: result.data?.routeReceiptEvaluations
      },
      item.description
    ));
  }
} finally {
  fs.rmSync(routeFixture, { recursive: true, force: true });
}

const failed = checks.filter(item => !item.passed).map(item => item.id);
const report = {
  schema: "TatwoIntegrationAdversarialDrillV1",
  passed: failed.length === 0,
  hostMutationAllowed: false,
  hostMutationPerformed: false,
  checks,
  failedCheckIDs: failed,
  plainSummary: failed.length === 0
    ? "Integration adversarial drill passed: forged receipts, stdio-only receipts, and dry-run evidence cannot be promoted into real host install."
    : "Integration adversarial drill failed; do not proceed toward host install.",
  generatedAt: new Date().toISOString()
};

console.log(JSON.stringify(report, null, 2));
process.exit(failed.length === 0 ? 0 : 1);

function runSwift(commandArgs) {
  const result = spawnSync("swift", ["run", "--package-path", repoRoot, "tatwo-ultrawork", ...commandArgs], {
    cwd: repoRoot,
    encoding: "utf8",
    timeout: 120000,
    maxBuffer: 10 * 1024 * 1024
  });
  return parseResult(result);
}

function runNode(script, commandArgs, options = {}) {
  const result = spawnSync("node", [path.join(scriptDir, script), ...commandArgs], {
    cwd: repoRoot,
    encoding: "utf8",
    timeout: 120000,
    maxBuffer: 10 * 1024 * 1024
  });
  if (!options.allowFailure && result.status !== 0) return { data: null, error: sanitize(`${result.stdout}\n${result.stderr}`), status: result.status };
  return parseResult(result);
}

function parseResult(result) {
  const text = `${result.stdout ?? ""}\n${result.stderr ?? ""}`;
  const json = firstJSONObject(text);
  if (!json) return { data: null, error: sanitize(text), status: result.status };
  try { return { data: JSON.parse(json), error: null, status: result.status }; }
  catch (error) { return { data: null, error: sanitize(text), status: result.status }; }
}

function firstJSONObject(text) {
  const start = text.indexOf("{");
  if (start < 0) return null;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < text.length; i += 1) {
    const ch = text[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (ch === "\\\\") escaped = true;
      else if (ch === "\"") inString = false;
      continue;
    }
    if (ch === "\"") { inString = true; continue; }
    if (ch === "{") depth += 1;
    if (ch === "}") {
      depth -= 1;
      if (depth === 0) return text.slice(start, i + 1);
    }
  }
  return null;
}

function check(id, passed, observed, description) {
  return { id, passed: Boolean(passed), observed: sanitize(JSON.stringify(observed)), description };
}

function includesAll(list, values) {
  return Array.isArray(list) && values.every(value => list.includes(value));
}

function decisionData(result) {
  return result?.data?.data ?? result?.data ?? null;
}

function writeReadinessFixture(dir, { modelGatewaySkipped, openUltraworkSkipped, includeRunway }) {
  fs.mkdirSync(dir, { recursive: true });
  const write = (name, value) => fs.writeFileSync(path.join(dir, name), String(value), "utf8");
  const writeJSON = (name, value) => write(name, `${JSON.stringify(value, null, 2)}\n`);
  const writeEnvelope = (name, data) => writeJSON(name, { data });

  for (const name of ["swift-test.log"]) write(name, "All tests passed\nfailures (0 unexpected)\n");
  for (const name of ["build-all.log", "build-cli.log", "build-app.log"]) write(name, "Build complete\n");
  for (const name of [
    "team-traits.log",
    "team-list.log",
    "integration-plan.log",
    "integration-stability.log",
    "integration-fugu-policy.log",
    "workflow-run-dry.log",
    "handoff-pack.log",
    "install-plan.log",
    "sandbox-preflight.log"
  ]) write(name, "fixture ok\n");
  writeJSON("codex-disconnect-guard.log", {
    schema: "TatwoCodexDisconnectGuardV1",
    passed: true,
    hostMutationAllowed: false,
    hostMutationPerformed: false,
    gatewayEvidence: modelGatewaySkipped ? "not_configured" : "observed",
    checks: [
      { id: "semantic-sse-in-progress", passed: true },
      { id: "clean-413-not-reset", passed: true },
      { id: "gateway-route-error-state-observable", passed: true },
      { id: "auth-single-source-check", passed: true },
      { id: "stdio-is-not-host-registration", passed: true }
    ],
    failedCheckIDs: []
  });

  writeEnvelope("doctor.log", { coreReady: true, hostReady: false, hostMutationAllowed: false });
  write("team-recommend-design.log", "stability-team\nstability-loop\n");
  write("team-dashboard.log", "TatwoTeamReadinessDashboardV1\n\"uiDeferred\" : true\n\"hostMutationAllowed\" : false\nreviewer_unavailable\nmcp-stdio\nlive 同 thread\n");
  write("integration-fugu-policy.log", "TatwoFuguArchitecturePolicyV1\n\"integratesFuguModel\" : false\n不接入 Fugu 模型\nCodex executor\n沙盒\n");
  const colimaDeniedMounts = ["$HOME", "/Users", "whole /Volumes", "~/.codex", "~/.ssh", "browser profiles", "Docker socket from host"];
  const colimaDeniedEnvironment = ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GROK_API_KEY", "MINIMAX_API_KEY", "Authorization", "SSH_AUTH_SOCK"];
  const colimaAllowedPrefixes = [
    "swift test",
    "swift build",
    "node scripts/tatwo-ultrawork-mcp-smoke.mjs",
    "node scripts/tatwo-ultrawork-mcp-adversarial-smoke.mjs",
    "node scripts/tatwo-codex-disconnect-guard.mjs",
    "bash scripts/tatwo-ultrawork-sandbox-check.sh",
    "true"
  ];
  writeEnvelope("colima-preflight.log", {
    schema: "TatwoColimaPreflightV1",
    adapterID: "colima-sandbox-runner",
    available: false,
    status: "missing",
    severityIfMissing: "medium",
    hostMutationAllowed: false,
    autoInstallAllowed: false,
    autoStartAllowed: false,
    dryRunSupported: true,
    commandChecks: [],
    safetyRules: ["Colima is optional L2 runtime verification, not a model lane."]
  });
  writeEnvelope("colima-run-dry.log", {
    schema: "TatwoColimaSandboxReceiptV1",
    status: "degraded",
    dryRun: true,
    executed: false,
    hostMutationAllowed: false,
    plan: {
      allowedCommandPrefixes: colimaAllowedPrefixes,
      requestedCommands: [],
      deniedMounts: colimaDeniedMounts,
      deniedEnvironment: colimaDeniedEnvironment
    }
  });
  writeJSON("colima-runner-preflight.log", {
    schema: "TatwoColimaRunnerPreflightV1",
    adapterID: "colima-sandbox-runner",
    available: false,
    dockerDaemonAvailable: false,
    hostMutationAllowed: false,
    autoInstallAllowed: false,
    autoStartAllowed: false,
    safetyRules: ["This runner never auto-installs or auto-starts Colima."]
  });
  writeJSON("colima-runner-dry.log", {
    schema: "TatwoColimaRunnerReceiptV1",
    status: "degraded",
    dryRun: true,
    executed: false,
    hostMutationAllowed: false,
    requestedCommands: ["swift test --package-path ."],
    allowedCommandPrefixes: colimaAllowedPrefixes,
    deniedMounts: colimaDeniedMounts,
    deniedEnvironment: colimaDeniedEnvironment
  });
  writeJSON("team-loop-js.log", {
    schema: "TatwoTeamLoopPacketV1",
    mode: "XL",
    scenario: "coding",
    hostMutationAllowed: false,
    modelTraitSummary: [
      { id: "gpt-5.5", calibrationNotes: [{ observedPattern: "UI self-pass risk", routingImplication: "visual gate" }] },
      { id: "minimax-m3", calibrationNotes: [{ observedPattern: "bulk scout", routingImplication: "candidate generation only" }] },
      { id: "opus-5", calibrationNotes: [{ observedPattern: "strict judge", routingImplication: "final evidence review" }] }
    ],
    roleBoundaries: [
      { roleName: "主控", owner: "GPT", canDo: ["plan"], cannotDo: ["UI final pass"], evidenceBeforePass: ["test"] },
      { roleName: "Scout", owner: "MiniMax", canDo: ["候選"], cannotDo: ["judge"], evidenceBeforePass: ["schema output"] },
      { roleName: "Verifier", owner: "Deterministic tests", canDo: ["verify"], cannotDo: ["approve without evidence"], evidenceBeforePass: ["receipt"] },
      { roleName: "Judge", owner: "Opus", canDo: ["fail closed"], cannotDo: ["self implement then final pass"], evidenceBeforePass: ["all receipts"] }
    ],
    workflowLoops: [
      { id: "design-loop", steps: ["brief", "visual proof"], scriptsOrCommands: ["tatwo validate sample-ui"], sandboxPolicy: "sandbox only", stopCondition: "visual receipt present", requiredReceipts: ["visual-proof"] },
      { id: "stability-loop", steps: ["preflight", "disconnect guard"], scriptsOrCommands: ["node scripts/tatwo-codex-disconnect-guard.mjs"], sandboxPolicy: "read-only", stopCondition: "no failed guards", requiredReceipts: ["disconnect-guard"] },
      { id: "host-loop", steps: ["backup", "same-thread"], scriptsOrCommands: ["node scripts/tatwo-host-install-runway.mjs"], sandboxPolicy: "no host mutation", stopCondition: "host receipts collected", requiredReceipts: ["same-thread", "mcp-host"] }
    ]
  });
  write("mcp-smoke.log", "tatwo_ultrawork_mcp_smoke=passed\n");
  write("mcp-adversarial-smoke.log", "tatwo_ultrawork_mcp_adversarial_smoke=passed\n");
  write("integration-adversarial-drill.log", "{\"schema\": \"TatwoIntegrationAdversarialDrillV1\", \"passed\": true, \"plainSummary\": \"forged receipts and dry-run evidence\"}\n");
  write("operational-receipt-adversarial.log", "{\"schema\": \"TatwoOperationalReceiptAdversarialV1\", \"passed\": true, \"reasons\": [\"partial_stream_cannot_pass\", \"mcp_stdio_not_host_registration\", \"approval_epoch_stale_after_model_switch\", \"model_text_cannot_approve_install\"]}\n");
  write("validate-sample-ui.log", "missing_visual_evidence\nvalidate_sample_ui_expected_failure=passed\n");
  write("redaction-scan.log", "redaction_scan=passed\n");
  write("model-gateway-tests.log", modelGatewaySkipped ? "model_gateway_tests=skipped\n" : "tests 27\npass 27\nfail 0\n");
  write("open-ultrawork-tests.log", openUltraworkSkipped ? "open_ultrawork_tests=skipped\n" : "ultrawork selftest ok\n");

  writeEnvelope("host-preflight.log", {
    readOnly: true,
    hostMutationAllowed: false,
    requiredBeforeHostInstall: ["live same-thread smoke receipt"]
  });
  writeEnvelope("host-backup-plan.log", {
    dryRun: true,
    hostMutationAllowed: false,
    humanApprovalRequiredForConfirm: true
  });
  writeEnvelope("host-live-smoke-plan.log", {
    hostMutationAllowed: false,
    requiredReceipts: ["gateway same-thread smoke receipt", "host MCP registration smoke receipt"]
  });
  writeEnvelope("host-receipt-flow.log", {
    schema: "TatwoHostReceiptFlowV1",
    hostMutationDefault: false,
    hostInstallGateIsOnlyDecision: true,
    receiptSpecs: Array.from({ length: 8 }, (_, index) => ({ id: `receipt-${index}` })),
    phases: [{ id: "backup-and-rollback" }, { id: "host-smoke" }]
  });
  writeEnvelope("host-install-gate.log", {
    schema: "TatwoHostInstallGateDecisionV1",
    hostInstallAllowed: false,
    hostMutationPerformed: false,
    blockedBy: ["human_approval_required"]
  });
  if (includeRunway) {
    writeJSON("host-install-runway-final.log", {
      schema: "TatwoHostInstallRunwayV1",
      uiDeferred: true,
      hostMutationAllowed: false,
      currentPhase: "sandbox_ready_host_blocked",
      missingReceipts: ["live same-thread smoke receipt", "mcp-host registration receipt"]
    });
    writeJSON("host-promotion-plan.log", {
      schema: "TatwoHostPromotionPlanV1",
      status: "ready_to_collect_host_receipts",
      currentPhase: "sandbox_ready_host_blocked",
      uiDeferred: true,
      hostMutationAllowed: false,
      hostMutationPerformed: false,
      hostInstallAllowed: false,
      connectionStrategy: [
        { id: "keep-single-gateway-provider" },
        { id: "mcp-wrapper-not-bundle-patch" },
        { id: "sandbox-before-host" },
        { id: "ui-last-data-first" }
      ],
      routeRiskTriage: {
        status: "observed_clean",
        observed: "routes=15, important=5/5, routes_with_errors=none, without_last_ok=none",
        routeErrorVisible: true,
        routeErrors: [],
        routesWithoutLastOK: [],
        blockedBy: [],
        requiredBeforePromotion: ["still run live same-thread smoke before host install"]
      },
      circuitBreakers: [
        { id: "stream-disconnect" },
        { id: "partial-stream" },
        { id: "route-error-state" },
        { id: "provider-split" },
        { id: "mcp-stdio-only" },
        { id: "ui-self-pass" }
      ],
      blockedBy: ["live_same_thread_smoke_not_observed", "mcp_registration_on_host_not_observed"]
    });
    writeJSON("objective-audit.log", {
      schema: "TatwoObjectiveCompletionAuditV1",
      status: "workflow_ready_host_blocked_ui_deferred",
      objectiveComplete: false,
      sandboxMilestonePassed: true,
      uiDeferred: true,
      hostInstallAllowed: false,
      hostMutationAllowed: false,
      requirements: [
        { id: "model-traits-calibrated", status: "passed" },
        { id: "teams-defined", status: "passed" },
        { id: "team-loops-scripted", status: "passed" },
        { id: "host-promotion-runway-defined", status: "passed" },
        { id: "route-risk-dashboard-visible", status: "passed" },
        { id: "route-smoke-plan-visible", status: "passed" },
        { id: "route-live-smoke-receipts-gated", status: "passed" },
        { id: "host-install-fail-closed", status: "passed" },
        { id: "no-host-mutation-in-sandbox", status: "passed" },
        { id: "codex-disconnect-guarded", status: "passed" }
      ],
      completionBlockedBy: [
        "ui_deferred_until_workflow_runway_and_host_receipts_are_clear",
        "live_same_thread_smoke_not_observed",
        "mcp_registration_on_host_not_observed"
      ]
    });
    writeJSON("objective-adversarial.log", {
      schema: "TatwoObjectiveAdversarialV1",
      passed: true,
      hostMutationAllowed: false,
      hostMutationPerformed: false,
      checks: Array.from({ length: 6 }, (_, index) => ({ id: `fixture-${index}`, passed: true })),
      failedCheckIDs: []
    });
  }

  writeJSON("host-sandbox-rehearsal.log", {
    schema: "TatwoHostSandboxRehearsalReceiptV1",
    passed: true,
    receiptID: "rehearsal-abcdef123456",
    hostMutationAllowed: false,
    realHostMutationPerformed: false,
    rollbackValidated: true,
    mcpCompatibilityPassed: true,
    liveSameThreadReceiptProduced: false,
    hostInstallAllowed: false,
    redactionScanPassed: true
  });
  writeJSON("host-preflight-live.log", {
    schema: "TatwoHostPreflightV1",
    readOnly: true,
    hostMutationAllowed: false,
    checks: [
      {
        id: "codex-model-provider-single-gateway",
        status: "installed",
        observed: "model_provider=model_gateway"
      },
      {
        id: "gateway-route-error-state",
        status: "installed",
        observed: "routes=15, important=5/5, routes_with_errors=none, without_last_ok=none"
      }
    ],
    unknownHighOrCriticalCheckIDs: [],
    failedCriticalCheckIDs: []
  });
  writeJSON("route-risk-dashboard.log", {
    schema: "TatwoRouteRiskDashboardV1",
    status: "observed_clean",
    uiDeferred: true,
    hostMutationAllowed: false,
    hostMutationPerformed: false,
    hostInstallAllowed: false,
    routeStateVisible: true,
    ownerTeam: "環境穩定團隊",
    routeRiskSummary: {
      status: "observed_clean",
      observed: "routes=15, important=5/5, routes_with_errors=none, without_last_ok=none",
      routeErrors: [],
      routesWithoutLastOK: [],
      riskyRouteCount: 0,
      liveSmokeRequired: true,
      responseCompletedRequired: true
    },
    riskyRoutes: [],
    requiredBeforePromotion: [
      "live same-thread smoke",
      "route-specific response.completed"
    ],
    blockedBy: [],
    plainSummary: "fixture route risk clean; live same-thread response.completed is still required before host promotion."
  });
  writeJSON("route-smoke-plan.log", {
    schema: "TatwoRouteSmokePlanV1",
    status: "no_route_risks_observed_still_requires_same_thread_baseline",
    uiDeferred: true,
    hostMutationAllowed: false,
    hostMutationPerformed: false,
    hostInstallAllowed: false,
    ownerTeam: "環境穩定團隊",
    routeSmokeQueue: [],
    baselineSameThreadSmoke: {
      mustSee: [
        "sameThreadSmokeExecuted=true",
        "passed=true",
        "response.completed"
      ],
      doesNotProve: [
        "host MCP registration",
        "UI quality"
      ]
    },
    blockedBy: [
      "human_approval_required_before_host_live_smoke",
      "host_backup_not_observed_before_route_smoke"
    ],
    plainSummary: "fixture has no risky route, but baseline same-thread response.completed is still required before promotion."
  });
  writeJSON("route-live-smoke-receipts.log", {
    schema: "TatwoRouteLiveSmokeReceiptsGateV1",
    status: "no_risky_routes_baseline_same_thread_still_required",
    uiDeferred: true,
    hostMutationAllowed: false,
    hostMutationPerformed: false,
    hostInstallAllowed: false,
    expectedRoutes: [],
    expectedRouteIDs: [],
    routeReceiptEvaluations: [],
    allRouteLiveReceiptsPassed: true,
    routeLiveSmokeAllPassed: true,
    receiptID: "route-live-bundle-abcdef123456",
    receiptIDs: {},
    blockedBy: [
      "human_approval_required_before_host_live_smoke",
      "host_backup_not_observed_before_route_smoke"
    ],
    deniedActions: [
      "no UI work from route live smoke alone",
      "no host install from route live smoke alone",
      "no model-text promotion to route receipt",
      "no partial stream or response.in_progress promotion",
      "no dry-run promotion to host-live route receipt",
      "no stdio MCP receipt mixed into route pass"
    ]
  });
  writeJSON("host-backup-plan-dry.log", {
    schema: "TatwoHostBackupPlanV1",
    dryRun: true,
    backupExecuted: false,
    hostMutationAllowed: false
  });
  writeJSON("host-rollback-plan-dry.log", {
    schema: "TatwoHostRollbackPlanV1",
    dryRun: true,
    hostMutationAllowed: false,
    rollbackMutationPerformed: false
  });
  writeJSON("host-same-thread-smoke-dry.log", {
    schema: "TatwoHostSameThreadSmokeReceiptV1",
    dryRun: true,
    hostMutationAllowed: false,
    sameThreadSmokeExecuted: false,
    passed: false
  });
  writeJSON("host-mcp-registration-smoke.log", {
    schema: "TatwoHostMCPRegistrationSmokeReceiptV1",
    passed: true,
    receiptID: "mcp-stdio-abcdef123456",
    hostMutationAllowed: false,
    registrationMutationPerformed: false,
    hostRegistrationObserved: false
  });
}

function resetRouteLiveFixture(dir, receipt) {
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  const writeJSON = (name, value) => fs.writeFileSync(path.join(dir, name), `${JSON.stringify(value, null, 2)}\n`, "utf8");
  writeJSON("route-risk-dashboard.log", {
    schema: "TatwoRouteRiskDashboardV1",
    status: "needs_live_smoke",
    uiDeferred: true,
    hostMutationAllowed: false,
    hostMutationPerformed: false,
    hostInstallAllowed: false,
    routeStateVisible: true,
    routeRiskSummary: {
      status: "needs_live_smoke",
      routeErrors: [],
      routesWithoutLastOK: ["grok-build"],
      riskyRouteCount: 1,
      liveSmokeRequired: true,
      responseCompletedRequired: true
    },
    riskyRoutes: [
      {
        modelID: "grok-build",
        riskKinds: ["no_last_ok"],
        observedErrorKind: null,
        plainChineseExplanation: "fixture risky route requires live proof",
        requiredProof: ["live same-thread smoke", "route-specific response.completed", "same thread continuity back to gpt-5.5"],
        installBlocker: true,
        uiBlocker: true
      }
    ],
    requiredBeforePromotion: ["live same-thread smoke", "response.completed"],
    blockedBy: ["route_live_smoke_required"]
  });
  writeJSON("route-smoke-plan.log", {
    schema: "TatwoRouteSmokePlanV1",
    status: "needs_route_live_smoke",
    uiDeferred: true,
    hostMutationAllowed: false,
    hostMutationPerformed: false,
    hostInstallAllowed: false,
    routeSmokeQueue: [
      {
        modelID: "grok-build",
        riskKinds: ["no_last_ok"],
        sameThreadSequence: ["gpt-5.5", "grok-build", "gpt-5.5"],
        requiredProof: ["live same-thread smoke", "route-specific response.completed", "same thread continuity back to gpt-5.5"],
        canStartUIAfterThisAlone: false,
        canInstallHostAfterThisAlone: false
      }
    ],
    baselineSameThreadSmoke: {
      mustSee: ["sameThreadSmokeExecuted=true", "passed=true", "response.completed"]
    },
    blockedBy: ["route_smoke_live_receipts_missing"]
  });
  writeJSON("route-live-grok-build-smoke.json", receipt);
}

function promoteFixtureToLiveReceipts(dir) {
  const writeJSON = (name, value) => fs.writeFileSync(path.join(dir, name), `${JSON.stringify(value, null, 2)}\n`, "utf8");
  writeJSON("host-backup-plan-confirmed.log", {
    schema: "TatwoHostBackupPlanV1",
    backupExecuted: true,
    receiptID: "backup-abcdef123456",
    hostMutationAllowed: false
  });
  writeJSON("host-rollback-plan-validated.log", {
    schema: "TatwoHostRollbackPlanV1",
    rollbackPlanValidated: true,
    receiptID: "rollback-abcdef123456",
    hostMutationAllowed: false,
    rollbackMutationPerformed: false
  });
  writeJSON("host-same-thread-smoke-live.log", {
    schema: "TatwoHostSameThreadSmokeReceiptV1",
    passed: true,
    sameThreadSmokeExecuted: true,
    receiptID: "same-thread-abcdef123456",
    hostMutationAllowed: false
  });
  writeJSON("host-mcp-registration-smoke.log", {
    schema: "TatwoHostMCPRegistrationSmokeReceiptV1",
    passed: true,
    receiptID: "mcp-host-abcdef123456",
    hostMutationAllowed: false,
    registrationMutationPerformed: false,
    hostRegistrationObserved: true
  });
}

function sanitize(value) {
  return String(value ?? "")
    .replace(/\/Users\/[\S]+|\/Volumes\/[\S]+/g, "<local-path>")
    .replace(/sk-[A-Za-z0-9_-]+/g, "<redacted-token>")
    .replace(/Bearer [A-Za-z0-9._-]+/g, "Bearer <redacted>");
}

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith("--")) { out._.push(arg); continue; }
    const eq = arg.indexOf("=");
    if (eq >= 0) out[arg.slice(2, eq)] = arg.slice(eq + 1);
    else out[arg.slice(2)] = argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[++i] : true;
  }
  return out;
}
