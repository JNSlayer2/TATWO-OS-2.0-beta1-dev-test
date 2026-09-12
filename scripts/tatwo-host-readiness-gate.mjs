#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const evidenceRoot = path.join(repoRoot, ".tatwo-ultrawork", "evidence");
const args = parseArgs(process.argv.slice(2));
const skipRunwayCheck = args["skip-runway-check"] === true;
const evidenceDir = resolveEvidenceDir(args);
const skippedEvidence = skipRunwayCheck ? ["host-install-runway-final.log"] : [];

if (!evidenceDir) {
  emit({
    schema: "TatwoHostReadinessGateV1",
    status: "failed",
    sandboxValidated: false,
    hostInstallAllowed: false,
    evidenceDir: null,
    checks: [check("evidence-dir", false, "missing", "No evidence directory found. Run scripts/tatwo-ultrawork-sandbox-check.sh first.")],
    hostInstallBlockedBy: ["sandbox_evidence_missing"],
    nextActions: ["Run bash scripts/tatwo-ultrawork-sandbox-check.sh before any host install."],
    generatedAt: new Date().toISOString()
  });
  process.exit(1);
}

const requiredFiles = [
  "swift-test.log",
  "build-all.log",
  "build-cli.log",
  "build-app.log",
  "doctor.log",
  "team-traits.log",
  "team-list.log",
  "team-recommend-design.log",
  "team-dashboard.log",
  "integration-plan.log",
  "integration-stability.log",
  "integration-fugu-policy.log",
  "colima-preflight.log",
  "colima-run-dry.log",
  "colima-runner-preflight.log",
  "colima-runner-dry.log",
  "codex-disconnect-guard.log",
  "team-loop-js.log",
  "workflow-run-dry.log",
  "handoff-pack.log",
  "install-plan.log",
  "sandbox-preflight.log",
  "host-preflight.log",
  "host-backup-plan.log",
  "host-live-smoke-plan.log",
  "host-receipt-flow.log",
  "host-install-gate.log",
  ...(skipRunwayCheck ? [] : ["host-install-runway-final.log", "host-promotion-plan.log", "objective-audit.log", "objective-adversarial.log"]),
  "route-risk-dashboard.log",
  "route-smoke-plan.log",
  "route-live-smoke-receipts.log",
  "host-sandbox-rehearsal.log",
  "host-preflight-live.log",
  "host-backup-plan-dry.log",
  "host-rollback-plan-dry.log",
  "host-same-thread-smoke-dry.log",
  "host-mcp-registration-smoke.log",
  "mcp-smoke.log",
  "mcp-adversarial-smoke.log",
  "integration-adversarial-drill.log",
  "operational-receipt-adversarial.log",
  "validate-sample-ui.log",
  "redaction-scan.log",
  "model-gateway-tests.log",
  "open-ultrawork-tests.log"
];

const checks = [];
for (const file of requiredFiles) {
  checks.push(check(`file:${file}`, fileHasContent(file), fileHasContent(file) ? "present" : "missing", `${file} exists and is non-empty`));
}

const doctor = parseCLIEnvelope("doctor.log");
const doctorData = doctor?.data ?? {};
checks.push(check("doctor-core-ready", doctorData.coreReady === true, String(doctorData.coreReady), "Tatwo core catalog and validation gates are loaded."));
checks.push(check(
  "doctor-host-mutation-fail-closed",
  doctorData.coreReady === true && doctorData.hostMutationAllowed === false,
  `coreReady=${doctorData.coreReady}, hostReady=${doctorData.hostReady}, hostMutationAllowed=${doctorData.hostMutationAllowed}`,
  "Doctor may mark workflow evidence ready, but must never authorize host mutation or host install by itself."
));

checks.push(check("swift-tests", includes("swift-test.log", "failures (0 unexpected)") && includes("swift-test.log", "All tests") && !includes("swift-test.log", "FAILED"), "log-scan", "Swift test suite has no unexpected failures."));
checks.push(check("builds", includes("build-all.log", "Build complete") && includes("build-cli.log", "Build complete") && includes("build-app.log", "Build complete"), "log-scan", "All Swift build targets completed."));
checks.push(check("mcp-smoke", includes("mcp-smoke.log", "tatwo_ultrawork_mcp_smoke=passed"), "log-scan", "Tatwo MCP initialize/tools/call smoke passed."));
checks.push(check("mcp-adversarial-smoke", includes("mcp-adversarial-smoke.log", "tatwo_ultrawork_mcp_adversarial_smoke=passed"), "log-scan", "Tatwo MCP rejects unsafe memory and redacts private objective material."));
checks.push(check("integration-adversarial-drill", includes("integration-adversarial-drill.log", "\"schema\": \"TatwoIntegrationAdversarialDrillV1\"") && includes("integration-adversarial-drill.log", "\"passed\": true") && includes("integration-adversarial-drill.log", "forged receipts") && includes("integration-adversarial-drill.log", "dry-run evidence"), "log-scan", "Integration adversarial drill proves forged receipts, stdio-only receipts, and dry-run evidence cannot be promoted into real host install."));
checks.push(check("operational-receipt-adversarial", includes("operational-receipt-adversarial.log", "\"schema\": \"TatwoOperationalReceiptAdversarialV1\"") && includes("operational-receipt-adversarial.log", "\"passed\": true") && includes("operational-receipt-adversarial.log", "partial_stream_cannot_pass") && includes("operational-receipt-adversarial.log", "mcp_stdio_not_host_registration") && includes("operational-receipt-adversarial.log", "approval_epoch_stale_after_model_switch") && includes("operational-receipt-adversarial.log", "model_text_cannot_approve_install"), "log-scan", "Operational receipt gate blocks partial streams, stdio-only fake host receipts, old approval epochs, retry storms, and model-text approvals."));
checks.push(check("ui-fail-closed", includes("validate-sample-ui.log", "validate_sample_ui_expected_failure=passed") && includes("validate-sample-ui.log", "missing_visual_evidence"), "log-scan", "UI build-only receipt fails closed instead of self-passing."));
const teamLoop = parseJSONDocument("team-loop-js.log");
const teamLoopLoops = Array.isArray(teamLoop?.workflowLoops) ? teamLoop.workflowLoops : [];
const teamLoopBoundaries = Array.isArray(teamLoop?.roleBoundaries) ? teamLoop.roleBoundaries : [];
const teamLoopTraits = Array.isArray(teamLoop?.modelTraitSummary) ? teamLoop.modelTraitSummary : [];
const teamLoopStrong =
  teamLoop?.schema === "TatwoTeamLoopPacketV1"
  && teamLoop.hostMutationAllowed === false
  && teamLoopLoops.length >= 3
  && teamLoopLoops.every(loop =>
    Array.isArray(loop.steps) && loop.steps.length > 0
    && Array.isArray(loop.scriptsOrCommands) && loop.scriptsOrCommands.length > 0
    && typeof loop.sandboxPolicy === "string" && loop.sandboxPolicy.trim().length > 0
    && typeof loop.stopCondition === "string" && loop.stopCondition.trim().length > 0
    && Array.isArray(loop.requiredReceipts) && loop.requiredReceipts.length > 0
  )
  && teamLoopBoundaries.length >= 4
  && teamLoopBoundaries.some(boundary => String(boundary.roleName ?? "").toLowerCase().includes("judge") || String(boundary.owner ?? "").includes("Opus"))
  && teamLoopBoundaries.some(boundary => JSON.stringify(boundary).includes("final pass") || JSON.stringify(boundary).includes("驗收"))
  && teamLoopTraits.length >= 3
  && teamLoopTraits.every(trait => Array.isArray(trait.calibrationNotes) && trait.calibrationNotes.length > 0);
checks.push(check(
  "team-loop-role-boundaries",
  teamLoopStrong,
  `loops=${teamLoopLoops.length}, boundaries=${teamLoopBoundaries.length}, traits=${teamLoopTraits.length}, hostMutationAllowed=${teamLoop?.hostMutationAllowed}`,
  "Team loop must expose real model trait calibration, workflow loops with scripts/receipts/stop conditions, role boundaries, and no host mutation."
));
checks.push(check("l-design-carries-stability", includes("team-recommend-design.log", "stability-team") && includes("team-recommend-design.log", "stability-loop"), "log-scan", "L/XL design recommendations must carry the stability team/loop to prevent Codex disconnect regressions."));
checks.push(check("team-dashboard-readiness", includes("team-dashboard.log", "TatwoTeamReadinessDashboardV1") && includes("team-dashboard.log", "\"uiDeferred\" : true") && includes("team-dashboard.log", "\"hostMutationAllowed\" : false") && includes("team-dashboard.log", "reviewer_unavailable") && includes("team-dashboard.log", "mcp-stdio") && includes("team-dashboard.log", "live 同 thread"), "log-scan", "Team dashboard must summarize model traits, selected teams, scripts, receipts, and fail-closed rules without authorizing host mutation."));
checks.push(check(
  "fugu-policy-idea-only",
  includes("integration-fugu-policy.log", "TatwoFuguArchitecturePolicyV1")
    && includes("integration-fugu-policy.log", "\"integratesFuguModel\" : false")
    && includes("integration-fugu-policy.log", "不接入 Fugu 模型")
    && includes("integration-fugu-policy.log", "Codex executor")
    && includes("integration-fugu-policy.log", "沙盒"),
  "log-scan",
  "Fugu can only be promoted as architecture inspiration; no Fugu model, dependency, black-box API, or model-owned side effect is allowed."
));
const colimaPreflight = parseCLIEnvelope("colima-preflight.log")?.data ?? {};
const colimaRunDry = parseCLIEnvelope("colima-run-dry.log")?.data ?? {};
const colimaRunnerPreflight = parseJSONDocument("colima-runner-preflight.log");
const colimaRunnerDry = parseJSONDocument("colima-runner-dry.log");
const colimaMountText = JSON.stringify([
  colimaRunDry?.plan?.deniedMounts,
  colimaRunnerDry?.deniedMounts
]);
const colimaDeniedEnvText = JSON.stringify([
  colimaRunDry?.plan?.deniedEnvironment,
  colimaRunnerDry?.deniedEnvironment
]);
const colimaCommandSurface = JSON.stringify([
  colimaRunDry?.plan?.allowedCommandPrefixes,
  colimaRunDry?.plan?.requestedCommands,
  colimaRunnerDry?.allowedCommandPrefixes,
  colimaRunnerDry?.requestedCommands
]).toLowerCase();
checks.push(check(
  "colima-preflight-optional-nonblocking",
  colimaPreflight.schema === "TatwoColimaPreflightV1"
    && colimaPreflight.adapterID === "colima-sandbox-runner"
    && colimaPreflight.hostMutationAllowed === false
    && colimaPreflight.autoInstallAllowed === false
    && colimaPreflight.autoStartAllowed === false
    && colimaPreflight.dryRunSupported === true
    && colimaPreflight.severityIfMissing === "medium",
  `schema=${colimaPreflight.schema}, status=${colimaPreflight.status}, severity=${colimaPreflight.severityIfMissing}, hostMutationAllowed=${colimaPreflight.hostMutationAllowed}`,
  "Colima must be visible as optional/degraded, never a core blocker, and never auto-install or auto-start."
));
checks.push(check(
  "colima-dry-run-receipts-no-execution",
  colimaRunDry.schema === "TatwoColimaSandboxReceiptV1"
    && colimaRunDry.dryRun === true
    && colimaRunDry.executed === false
    && colimaRunDry.hostMutationAllowed === false
    && ["planned", "degraded"].includes(colimaRunDry.status)
    && colimaRunnerPreflight?.schema === "TatwoColimaRunnerPreflightV1"
    && colimaRunnerPreflight.hostMutationAllowed === false
    && colimaRunnerPreflight.autoInstallAllowed === false
    && colimaRunnerPreflight.autoStartAllowed === false
    && colimaRunnerDry?.schema === "TatwoColimaRunnerReceiptV1"
    && colimaRunnerDry.dryRun === true
    && colimaRunnerDry.executed === false
    && colimaRunnerDry.hostMutationAllowed === false
    && ["planned", "degraded"].includes(colimaRunnerDry.status),
  `coreStatus=${colimaRunDry.status}, runnerStatus=${colimaRunnerDry?.status}, runnerExecuted=${colimaRunnerDry?.executed}`,
  "Colima MCP/CLI sandbox receipts must default to dry-run and never pretend container execution happened."
));
checks.push(check(
  "colima-safety-boundaries",
  colimaMountText.includes("$HOME")
    && colimaMountText.includes("/Users")
    && colimaMountText.includes("/Volumes")
    && colimaDeniedEnvText.includes("OPENAI_API_KEY")
    && colimaDeniedEnvText.includes("SSH_AUTH_SOCK")
    && !/(colima\s+start|brew\s+install|docker\s+pull|colima\s+delete)/.test(colimaCommandSurface),
  `deniedMounts=${colimaMountText}, commandSurface=${colimaCommandSurface}`,
  "Colima plan must deny HOME/User/Volumes/auth surfaces and must not include install/start/pull commands in the executable command surface."
));
const disconnectGuard = parseJSONDocument("codex-disconnect-guard.log");
checks.push(check(
  "codex-disconnect-guard",
  disconnectGuard?.schema === "TatwoCodexDisconnectGuardV1"
    && disconnectGuard.passed === true
    && disconnectGuard.hostMutationAllowed === false
    && Array.isArray(disconnectGuard.checks)
    && disconnectGuard.checks.some(item => item.id === "semantic-sse-in-progress" && item.passed === true)
    && disconnectGuard.checks.some(item => item.id === "clean-413-not-reset" && item.passed === true)
    && disconnectGuard.checks.some(item => item.id === "gateway-route-error-state-observable" && item.passed === true)
    && disconnectGuard.checks.some(item => item.id === "auth-single-source-check" && item.passed === true)
    && disconnectGuard.checks.some(item => item.id === "stdio-is-not-host-registration" && item.passed === true),
  `passed=${disconnectGuard?.passed}, gatewayEvidence=${disconnectGuard?.gatewayEvidence}`,
  "Codex disconnect guard must cover semantic SSE, clean 413, gateway route error state, auth single source, and stdio-vs-host MCP boundaries without host mutation."
));
const hostPreflight = parseCLIEnvelope("host-preflight.log")?.data ?? {};
checks.push(check("host-preflight-template-readonly", hostPreflight.readOnly === true && hostPreflight.hostMutationAllowed === false && Array.isArray(hostPreflight.requiredBeforeHostInstall) && hostPreflight.requiredBeforeHostInstall.includes("live same-thread smoke receipt"), `readOnly=${hostPreflight.readOnly}, hostMutationAllowed=${hostPreflight.hostMutationAllowed}`, "Host preflight template must stay read-only and require live same-thread smoke."));
const hostBackupPlan = parseCLIEnvelope("host-backup-plan.log")?.data ?? {};
const hostBackupText = read("host-backup-plan.log").toLowerCase();
checks.push(check("host-backup-plan-dry-run", hostBackupPlan.dryRun === true && hostBackupPlan.hostMutationAllowed === false && hostBackupPlan.humanApprovalRequiredForConfirm === true && !/refresh_token|access_token|api_key/.test(hostBackupText), `dryRun=${hostBackupPlan.dryRun}, hostMutationAllowed=${hostBackupPlan.hostMutationAllowed}`, "Host backup plan must be dry-run by default and must not expose raw auth material."));
const hostLiveSmokePlan = parseCLIEnvelope("host-live-smoke-plan.log")?.data ?? {};
checks.push(check("host-live-smoke-plan-receipts", hostLiveSmokePlan.hostMutationAllowed === false && Array.isArray(hostLiveSmokePlan.requiredReceipts) && hostLiveSmokePlan.requiredReceipts.includes("gateway same-thread smoke receipt") && hostLiveSmokePlan.requiredReceipts.includes("host MCP registration smoke receipt"), `hostMutationAllowed=${hostLiveSmokePlan.hostMutationAllowed}`, "Live smoke plan must require same-thread and host MCP registration receipts before host install."));
const hostReceiptFlow = parseCLIEnvelope("host-receipt-flow.log")?.data ?? {};
checks.push(check("host-receipt-flow-complete", hostReceiptFlow.schema === "TatwoHostReceiptFlowV1" && hostReceiptFlow.hostMutationDefault === false && hostReceiptFlow.hostInstallGateIsOnlyDecision === true && Array.isArray(hostReceiptFlow.receiptSpecs) && hostReceiptFlow.receiptSpecs.length >= 7 && Array.isArray(hostReceiptFlow.phases) && hostReceiptFlow.phases.some(phase => phase.id === "backup-and-rollback") && hostReceiptFlow.phases.some(phase => phase.id === "host-smoke"), `receiptSpecs=${hostReceiptFlow.receiptSpecs?.length}, hostMutationDefault=${hostReceiptFlow.hostMutationDefault}`, "Host receipt flow must explicitly cover sandbox, preflight, backup, rollback, live smoke, MCP smoke, and human gate."));
const hostInstallGate = parseCLIEnvelope("host-install-gate.log")?.data ?? {};
checks.push(check("host-install-gate-fail-closed", hostInstallGate.schema === "TatwoHostInstallGateDecisionV1" && hostInstallGate.hostInstallAllowed === false && hostInstallGate.hostMutationPerformed === false && Array.isArray(hostInstallGate.blockedBy) && hostInstallGate.blockedBy.includes("human_approval_required"), `hostInstallAllowed=${hostInstallGate.hostInstallAllowed}, hostMutationPerformed=${hostInstallGate.hostMutationPerformed}`, "Host install gate must fail closed without receipts and never perform host mutation."));
if (!skipRunwayCheck) {
  const hostRunway = parseJSONDocument("host-install-runway-final.log");
  checks.push(check("host-install-runway-visible", hostRunway?.schema === "TatwoHostInstallRunwayV1" && hostRunway.uiDeferred === true && hostRunway.hostMutationAllowed === false && hostRunway.currentPhase === "sandbox_ready_host_blocked" && Array.isArray(hostRunway.missingReceipts) && hostRunway.missingReceipts.includes("live same-thread smoke receipt"), `phase=${hostRunway?.currentPhase}, hostMutationAllowed=${hostRunway?.hostMutationAllowed}`, "Host install runway must show UI deferred, current phase, missing receipts, and stay no-host-mutation."));
  const hostPromotion = parseJSONDocument("host-promotion-plan.log");
  const promotionStrategyIDs = Array.isArray(hostPromotion?.connectionStrategy) ? hostPromotion.connectionStrategy.map(item => item?.id) : [];
  const promotionBreakerIDs = Array.isArray(hostPromotion?.circuitBreakers) ? hostPromotion.circuitBreakers.map(item => item?.id) : [];
  const promotionRouteTriage = hostPromotion?.routeRiskTriage ?? {};
  const promotionRouteErrors = Array.isArray(promotionRouteTriage.routeErrors) ? promotionRouteTriage.routeErrors : [];
  const promotionRoutesWithoutLastOK = Array.isArray(promotionRouteTriage.routesWithoutLastOK) ? promotionRouteTriage.routesWithoutLastOK : [];
  const promotionBlockedBy = Array.isArray(promotionRouteTriage.blockedBy) ? promotionRouteTriage.blockedBy : [];
  const promotionRequiredBefore = Array.isArray(promotionRouteTriage.requiredBeforePromotion) ? promotionRouteTriage.requiredBeforePromotion.join(" ") : "";
  const strategyOK = includesAll(promotionStrategyIDs, ["keep-single-gateway-provider", "mcp-wrapper-not-bundle-patch", "sandbox-before-host", "ui-last-data-first"]);
  const breakerOK = includesAll(promotionBreakerIDs, ["stream-disconnect", "partial-stream", "route-error-state", "provider-split", "mcp-stdio-only", "ui-self-pass"]);
  const routeRiskOK = promotionRouteTriage.routeErrorVisible === true
    && (promotionRouteErrors.length === 0 || (promotionBlockedBy.includes("gateway_route_errors_need_live_smoke") && promotionRequiredBefore.includes("live same-thread smoke")))
    && (promotionRoutesWithoutLastOK.length === 0 || (promotionBlockedBy.includes("gateway_routes_without_last_ok_need_live_smoke") && promotionRequiredBefore.includes("live same-thread smoke")));
  checks.push(check(
    "host-promotion-plan-readonly-runway",
    hostPromotion?.schema === "TatwoHostPromotionPlanV1"
      && hostPromotion.uiDeferred === true
      && hostPromotion.hostMutationAllowed === false
      && hostPromotion.hostInstallAllowed === false
      && strategyOK
      && breakerOK
      && routeRiskOK,
    `schema=${hostPromotion?.schema}, uiDeferred=${hostPromotion?.uiDeferred}, hostMutationAllowed=${hostPromotion?.hostMutationAllowed}, hostInstallAllowed=${hostPromotion?.hostInstallAllowed}, strategies=${promotionStrategyIDs.join(",")}, breakers=${promotionBreakerIDs.join(",")}, routeErrors=${promotionRouteErrors.join(",")}, withoutLastOK=${promotionRoutesWithoutLastOK.join(",")}`,
    "Host promotion plan must be read-only, UI-deferred, single-gateway/no-bundle-patch/sandbox/UI-last, expose route risks, and carry circuit breakers."
  ));
  const objectiveAudit = parseJSONDocument("objective-audit.log");
  const objectiveRequirements = Array.isArray(objectiveAudit?.requirements) ? objectiveAudit.requirements : [];
  const objectiveRequirementIDs = objectiveRequirements.map(item => item.id);
  const objectiveRequirementPassed = id => objectiveRequirements.some(item => item.id === id && item.status === "passed");
  checks.push(check(
    "objective-audit-workflow-first",
    objectiveAudit?.schema === "TatwoObjectiveCompletionAuditV1"
      && objectiveAudit.status === "workflow_ready_host_blocked_ui_deferred"
      && objectiveAudit.sandboxMilestonePassed === true
      && objectiveAudit.objectiveComplete === false
      && objectiveAudit.uiDeferred === true
      && objectiveAudit.hostInstallAllowed === false
      && objectiveAudit.hostMutationAllowed === false
      && objectiveRequirementPassed("model-traits-calibrated")
      && objectiveRequirementPassed("teams-defined")
      && objectiveRequirementPassed("team-loops-scripted")
      && objectiveRequirementPassed("codex-disconnect-guarded")
      && objectiveRequirementPassed("host-promotion-runway-defined")
      && objectiveRequirementPassed("route-risk-dashboard-visible")
      && objectiveRequirementPassed("route-smoke-plan-visible")
      && objectiveRequirementPassed("route-live-smoke-receipts-gated")
      && objectiveRequirementPassed("host-install-fail-closed")
      && objectiveRequirementPassed("no-host-mutation-in-sandbox")
      && Array.isArray(objectiveAudit.completionBlockedBy)
      && objectiveAudit.completionBlockedBy.includes("ui_deferred_until_workflow_runway_and_host_receipts_are_clear")
      && objectiveAudit.completionBlockedBy.includes("live_same_thread_smoke_not_observed")
      && objectiveAudit.completionBlockedBy.includes("mcp_registration_on_host_not_observed"),
    `status=${objectiveAudit?.status}, objectiveComplete=${objectiveAudit?.objectiveComplete}, sandboxMilestonePassed=${objectiveAudit?.sandboxMilestonePassed}`,
    "Objective audit must prove workflow-first milestone, model traits, teams, stability gates, and expected UI/host blockers without pretending full completion."
  ));
  const objectiveAdversarial = parseJSONDocument("objective-adversarial.log");
  checks.push(check(
    "objective-adversarial",
    objectiveAdversarial?.schema === "TatwoObjectiveAdversarialV1"
      && objectiveAdversarial.passed === true
      && objectiveAdversarial.hostMutationAllowed === false
      && objectiveAdversarial.hostMutationPerformed === false
      && Array.isArray(objectiveAdversarial.checks)
      && objectiveAdversarial.checks.length >= 6
      && Array.isArray(objectiveAdversarial.failedCheckIDs)
      && objectiveAdversarial.failedCheckIDs.length === 0,
    `passed=${objectiveAdversarial?.passed}, checks=${objectiveAdversarial?.checks?.length ?? 0}`,
    "Objective adversarial drill must reject fake completion, UI-first promotion, weak team loops, dry-run host mutation, and missing host blockers."
  ));
}
const rehearsal = parseJSONDocument("host-sandbox-rehearsal.log");
const rehearsalPassed = rehearsal?.schema === "TatwoHostSandboxRehearsalReceiptV1"
  && rehearsal.passed === true
  && rehearsal.hostMutationAllowed === false
  && rehearsal.realHostMutationPerformed === false
  && rehearsal.rollbackValidated === true
  && rehearsal.mcpCompatibilityPassed === true
  && rehearsal.liveSameThreadReceiptProduced === false
  && rehearsal.hostInstallAllowed === false
  && rehearsal.redactionScanPassed === true;
checks.push(check("host-sandbox-rehearsal-pass", rehearsalPassed, `passed=${rehearsal?.passed}, realHostMutationPerformed=${rehearsal?.realHostMutationPerformed}, rollbackValidated=${rehearsal?.rollbackValidated}`, "Host install logic must rehearse in fake HOME/CODEX_HOME, rollback cleanly, and still not count as a live host receipt."));
const livePreflight = parseJSONDocument("host-preflight-live.log");
checks.push(check("host-preflight-live-readonly", livePreflight?.schema === "TatwoHostPreflightV1" && livePreflight.readOnly === true && livePreflight.hostMutationAllowed === false, `readOnly=${livePreflight?.readOnly}, hostMutationAllowed=${livePreflight?.hostMutationAllowed}`, "Live host preflight script must be read-only and never authorize mutation."));
const livePreflightChecks = Array.isArray(livePreflight?.checks) ? livePreflight.checks : [];
const singleGatewayProvider = livePreflightChecks.find(item => item?.id === "codex-model-provider-single-gateway");
checks.push(check(
  "host-preflight-single-gateway-provider",
  singleGatewayProvider?.status === "installed",
  `status=${singleGatewayProvider?.status ?? "missing"}, observed=${singleGatewayProvider?.observed ?? "missing"}`,
  "Read-only host preflight must prove Codex is using the single model_gateway provider before host install."
));
const gatewayRouteErrorState = livePreflightChecks.find(item => item?.id === "gateway-route-error-state");
checks.push(check(
  "host-preflight-gateway-route-error-state-visible",
  gatewayRouteErrorState?.status === "installed",
  `status=${gatewayRouteErrorState?.status ?? "missing"}, observed=${gatewayRouteErrorState?.observed ?? "missing"}`,
  "Read-only host preflight must expose /healthz.routes route error state, so stale route errors cannot be hidden behind a green gateway health check."
));
const routeDashboard = parseJSONDocument("route-risk-dashboard.log");
const dashboardRiskyRoutes = Array.isArray(routeDashboard?.riskyRoutes) ? routeDashboard.riskyRoutes : [];
const dashboardRiskyRouteIDs = dashboardRiskyRoutes.map(item => item?.modelID).filter(Boolean);
const liveRouteListsForDashboard = routeListsFromPreflight(livePreflight);
const liveRouteRiskModelIDs = unique([
  ...liveRouteListsForDashboard.routeErrors.map(item => String(item).split(":")[0]).filter(Boolean),
  ...liveRouteListsForDashboard.routesWithoutLastOK
]);
const dashboardRequiredBefore = Array.isArray(routeDashboard?.requiredBeforePromotion) ? routeDashboard.requiredBeforePromotion.join(" ") : "";
const dashboardRiskRequiredProof = dashboardRiskyRoutes.every(item => {
  const proof = Array.isArray(item?.requiredProof) ? item.requiredProof.join(" ") : "";
  return proof.includes("live same-thread smoke") && proof.includes("response.completed");
});
checks.push(check(
  "route-risk-dashboard-visible",
  routeDashboard?.schema === "TatwoRouteRiskDashboardV1"
    && routeDashboard.uiDeferred === true
    && routeDashboard.hostMutationAllowed === false
    && routeDashboard.hostInstallAllowed === false
    && routeDashboard.routeStateVisible === true
    && routeDashboard?.routeRiskSummary?.liveSmokeRequired === true
    && routeDashboard?.routeRiskSummary?.responseCompletedRequired === true
    && includesAll(dashboardRiskyRouteIDs, liveRouteRiskModelIDs)
    && dashboardRequiredBefore.includes("live same-thread smoke")
    && dashboardRequiredBefore.includes("response.completed")
    && dashboardRiskRequiredProof,
  `schema=${routeDashboard?.schema}, uiDeferred=${routeDashboard?.uiDeferred}, hostMutationAllowed=${routeDashboard?.hostMutationAllowed}, hostInstallAllowed=${routeDashboard?.hostInstallAllowed}, routeStateVisible=${routeDashboard?.routeStateVisible}, riskyRoutes=${dashboardRiskyRouteIDs.join(",")}, liveRiskRoutes=${liveRouteRiskModelIDs.join(",")}`,
  "Route risk dashboard must expose each risky route in plain language, keep UI/host install closed, and require live same-thread response.completed proof."
));
const routeSmokePlan = parseJSONDocument("route-smoke-plan.log");
const routeSmokeQueue = Array.isArray(routeSmokePlan?.routeSmokeQueue) ? routeSmokePlan.routeSmokeQueue : [];
const routeSmokeIDs = routeSmokeQueue.map(item => item?.modelID).filter(Boolean);
const routeSmokeProofOK = routeSmokeQueue.every(item => {
  const proof = Array.isArray(item?.requiredProof) ? item.requiredProof.join(" ") : "";
  const sequence = Array.isArray(item?.sameThreadSequence) ? item.sameThreadSequence.join(" ") : "";
  return proof.includes("live same-thread smoke")
    && proof.includes("response.completed")
    && proof.includes("same thread continuity")
    && sequence.includes("gpt-5.5")
    && item.canStartUIAfterThisAlone === false
    && item.canInstallHostAfterThisAlone === false;
});
const routeSmokeBlockedBy = Array.isArray(routeSmokePlan?.blockedBy) ? routeSmokePlan.blockedBy : [];
const routeSmokeBaselineMustSee = Array.isArray(routeSmokePlan?.baselineSameThreadSmoke?.mustSee)
  ? routeSmokePlan.baselineSameThreadSmoke.mustSee.join(" ")
  : "";
const routeSmokeBaselineOK = routeSmokeBaselineMustSee.includes("response.completed")
  && routeSmokeBaselineMustSee.includes("passed=true");
const routeSmokeRiskBlockerOK = liveRouteRiskModelIDs.length === 0
  ? routeSmokePlan?.status === "no_route_risks_observed_still_requires_same_thread_baseline"
  : routeSmokeBlockedBy.includes("route_smoke_live_receipts_missing");
checks.push(check(
  "route-smoke-plan-visible",
  routeSmokePlan?.schema === "TatwoRouteSmokePlanV1"
    && routeSmokePlan.uiDeferred === true
    && routeSmokePlan.hostMutationAllowed === false
    && routeSmokePlan.hostInstallAllowed === false
    && includesAll(routeSmokeIDs, liveRouteRiskModelIDs)
    && routeSmokeProofOK
    && routeSmokeBaselineOK
    && routeSmokeRiskBlockerOK,
  `schema=${routeSmokePlan?.schema}, status=${routeSmokePlan?.status}, uiDeferred=${routeSmokePlan?.uiDeferred}, hostMutationAllowed=${routeSmokePlan?.hostMutationAllowed}, hostInstallAllowed=${routeSmokePlan?.hostInstallAllowed}, routeSmokeQueue=${routeSmokeIDs.join(",")}, liveRiskRoutes=${liveRouteRiskModelIDs.join(",")}, blockedBy=${routeSmokeBlockedBy.join(",")}`,
  "Route smoke plan must turn every risky route into a same-thread smoke queue, keep UI/host closed, and require route-specific response.completed plus continuity proof."
));
const routeLiveReceipts = parseJSONDocument("route-live-smoke-receipts.log");
const routeLiveExpectedIDs = Array.isArray(routeLiveReceipts?.expectedRouteIDs) ? routeLiveReceipts.expectedRouteIDs : [];
const routeLiveBlockedBy = Array.isArray(routeLiveReceipts?.blockedBy) ? routeLiveReceipts.blockedBy : [];
const routeLiveEvaluations = Array.isArray(routeLiveReceipts?.routeReceiptEvaluations) ? routeLiveReceipts.routeReceiptEvaluations : [];
const routeLivePassedWithReceipt = routeLiveReceipts?.routeLiveSmokeAllPassed === true
  && typeof routeLiveReceipts?.receiptID === "string"
  && routeLiveReceipts.receiptID.startsWith("route-live-bundle-")
  && (routeLiveExpectedIDs.length === 0 || routeLiveEvaluations.every(item => item?.passed === true && typeof item?.receiptID === "string" && item.receiptID.startsWith("route-live-")));
const routeLiveGateValid = routeLiveReceipts?.schema === "TatwoRouteLiveSmokeReceiptsGateV1"
  && routeLiveReceipts.uiDeferred === true
  && routeLiveReceipts.hostMutationAllowed === false
  && routeLiveReceipts.hostInstallAllowed === false
  && routeLiveReceipts.hostMutationPerformed === false
  && Array.isArray(routeLiveReceipts.deniedActions)
  && routeLiveReceipts.deniedActions.includes("no model-text promotion to route receipt")
  && routeLiveReceipts.deniedActions.includes("no partial stream or response.in_progress promotion")
  && (
    routeLivePassedWithReceipt
    || (
      routeLiveExpectedIDs.length > 0
      && routeLiveBlockedBy.includes("route_live_smoke_receipts_missing_or_invalid")
      && routeLiveEvaluations.every(item => item?.passed === false && Array.isArray(item?.failedReasons) && item.failedReasons.length > 0)
    )
  );
checks.push(check(
  "route-live-smoke-receipts-gate",
  routeLiveGateValid,
  `schema=${routeLiveReceipts?.schema}, expected=${routeLiveExpectedIDs.join(",")}, allPassed=${routeLiveReceipts?.routeLiveSmokeAllPassed}, blockedBy=${routeLiveBlockedBy.slice(0, 8).join(",")}`,
  "Route live smoke receipt gate must either prove every risky route with host-live response.completed receipts, or explicitly carry route_live_smoke blockers while keeping UI/host install closed."
));
const backupDry = parseJSONDocument("host-backup-plan-dry.log");
checks.push(check("host-backup-plan-script-dry-run", backupDry?.schema === "TatwoHostBackupPlanV1" && backupDry.dryRun === true && backupDry.backupExecuted === false && backupDry.hostMutationAllowed === false, `dryRun=${backupDry?.dryRun}, backupExecuted=${backupDry?.backupExecuted}`, "Backup script must default to dry-run and not copy files during sandbox check."));
const rollbackDry = parseJSONDocument("host-rollback-plan-dry.log");
checks.push(check("host-rollback-plan-dry-run", rollbackDry?.schema === "TatwoHostRollbackPlanV1" && rollbackDry.dryRun === true && rollbackDry.hostMutationAllowed === false && rollbackDry.rollbackMutationPerformed === false, `dryRun=${rollbackDry?.dryRun}, rollbackMutationPerformed=${rollbackDry?.rollbackMutationPerformed}`, "Rollback plan must default to dry-run and never restore host files during sandbox check."));
const sameThreadDry = parseJSONDocument("host-same-thread-smoke-dry.log");
checks.push(check("host-same-thread-smoke-dry-run", sameThreadDry?.schema === "TatwoHostSameThreadSmokeReceiptV1" && sameThreadDry.dryRun === true && sameThreadDry.hostMutationAllowed === false && sameThreadDry.sameThreadSmokeExecuted === false && sameThreadDry.passed === false, `dryRun=${sameThreadDry?.dryRun}, sameThreadSmokeExecuted=${sameThreadDry?.sameThreadSmokeExecuted}`, "Same-thread smoke script must be dry-run by default and not pretend live smoke passed."));
const mcpRegistration = parseJSONDocument("host-mcp-registration-smoke.log");
checks.push(check("host-mcp-registration-stdio-smoke", mcpRegistration?.schema === "TatwoHostMCPRegistrationSmokeReceiptV1" && mcpRegistration.passed === true && mcpRegistration.hostMutationAllowed === false && mcpRegistration.registrationMutationPerformed === false && mcpRegistration.hostRegistrationObserved === false, `passed=${mcpRegistration?.passed}, hostRegistrationObserved=${mcpRegistration?.hostRegistrationObserved}`, "MCP registration smoke must prove stdio compatibility without mutating host config or pretending host registration was observed."));
checks.push(check("redaction", includes("redaction-scan.log", "redaction_scan=passed"), "log-scan", "No obvious tokens/auth strings were found in repo scan."));

const modelGatewaySkipped = includes("model-gateway-tests.log", "model_gateway_tests=skipped");
const modelGatewayPassed = !modelGatewaySkipped
  && matches("model-gateway-tests.log", /(?:^|\n).*\btests\s+[1-9]\d*\b/)
  && matches("model-gateway-tests.log", /(?:^|\n).*\bpass\s+[1-9]\d*\b/)
  && matches("model-gateway-tests.log", /(?:^|\n).*\bfail\s+0\b/);
checks.push(check("model-gateway-tests", modelGatewayPassed || modelGatewaySkipped, modelGatewaySkipped ? "skipped_blocks_host_install" : "log-scan", "Gateway tests pass when MODEL_GATEWAY_DIR is configured; skipped is allowed for in-repo sandbox but blocks host install."));

const openUltraworkSkipped = includes("open-ultrawork-tests.log", "open_ultrawork_tests=skipped");
const openUltraworkPassed = !openUltraworkSkipped && includes("open-ultrawork-tests.log", "ultrawork selftest ok");
checks.push(check("open-ultrawork-tests", openUltraworkPassed || openUltraworkSkipped, openUltraworkSkipped ? "skipped_blocks_host_install" : "log-scan", "open-ultrawork selftest passes when OPEN_ULTRAWORK_DIR is configured; skipped is allowed for in-repo sandbox but blocks host install."));

const sandboxValidated = checks.every(c => c.id.startsWith("file:") ? c.passed : true)
  && checks.find(c => c.id === "doctor-core-ready")?.passed
  && checks.find(c => c.id === "doctor-host-mutation-fail-closed")?.passed
  && checks.find(c => c.id === "swift-tests")?.passed
  && checks.find(c => c.id === "builds")?.passed
  && checks.find(c => c.id === "mcp-smoke")?.passed
  && checks.find(c => c.id === "mcp-adversarial-smoke")?.passed
  && checks.find(c => c.id === "integration-adversarial-drill")?.passed
  && checks.find(c => c.id === "operational-receipt-adversarial")?.passed
  && checks.find(c => c.id === "ui-fail-closed")?.passed
  && checks.find(c => c.id === "team-loop-role-boundaries")?.passed
  && checks.find(c => c.id === "l-design-carries-stability")?.passed
  && checks.find(c => c.id === "team-dashboard-readiness")?.passed
  && checks.find(c => c.id === "fugu-policy-idea-only")?.passed
  && checks.find(c => c.id === "colima-preflight-optional-nonblocking")?.passed
  && checks.find(c => c.id === "colima-dry-run-receipts-no-execution")?.passed
  && checks.find(c => c.id === "colima-safety-boundaries")?.passed
  && checks.find(c => c.id === "codex-disconnect-guard")?.passed
  && checks.find(c => c.id === "host-preflight-template-readonly")?.passed
  && checks.find(c => c.id === "host-backup-plan-dry-run")?.passed
  && checks.find(c => c.id === "host-live-smoke-plan-receipts")?.passed
  && checks.find(c => c.id === "host-receipt-flow-complete")?.passed
  && checks.find(c => c.id === "host-install-gate-fail-closed")?.passed
  && (skipRunwayCheck || checks.find(c => c.id === "host-install-runway-visible")?.passed)
  && (skipRunwayCheck || checks.find(c => c.id === "host-promotion-plan-readonly-runway")?.passed)
  && (skipRunwayCheck || checks.find(c => c.id === "objective-audit-workflow-first")?.passed)
  && (skipRunwayCheck || checks.find(c => c.id === "objective-adversarial")?.passed)
  && checks.find(c => c.id === "host-sandbox-rehearsal-pass")?.passed
  && checks.find(c => c.id === "host-preflight-live-readonly")?.passed
  && checks.find(c => c.id === "host-preflight-single-gateway-provider")?.passed
  && checks.find(c => c.id === "host-preflight-gateway-route-error-state-visible")?.passed
  && checks.find(c => c.id === "route-risk-dashboard-visible")?.passed
  && checks.find(c => c.id === "route-smoke-plan-visible")?.passed
  && checks.find(c => c.id === "route-live-smoke-receipts-gate")?.passed
  && checks.find(c => c.id === "host-backup-plan-script-dry-run")?.passed
  && checks.find(c => c.id === "host-rollback-plan-dry-run")?.passed
  && checks.find(c => c.id === "host-same-thread-smoke-dry-run")?.passed
  && checks.find(c => c.id === "host-mcp-registration-stdio-smoke")?.passed
  && checks.find(c => c.id === "redaction")?.passed
  && checks.find(c => c.id === "model-gateway-tests")?.passed
  && checks.find(c => c.id === "open-ultrawork-tests")?.passed;

const failed = checks.filter(c => !c.passed).map(c => c.id);
const hostPreflightUnknowns = Array.isArray(livePreflight?.unknownHighOrCriticalCheckIDs)
  ? livePreflight.unknownHighOrCriticalCheckIDs
  : [];
const hostInstallBlockedBy = [
  ...(sandboxValidated ? [] : ["sandbox_evidence_not_complete"]),
  ...(rehearsalPassed ? [] : ["host_sandbox_rehearsal_not_observed"]),
  ...hostPreflightUnknowns.map(id => `host_preflight_unknown:${id}`),
  ...(modelGatewayPassed ? [] : ["external_model_gateway_tests_not_observed"]),
  ...(openUltraworkPassed ? [] : ["external_open_ultrawork_selftest_not_observed"]),
  ...(Array.isArray(routeDashboard?.blockedBy) ? routeDashboard.blockedBy : []),
  ...(routeLiveReceipts?.routeLiveSmokeAllPassed === true ? [] : routeLiveBlockedBy),
  ...(routeLiveReceipts?.schema === "TatwoRouteLiveSmokeReceiptsGateV1" ? [] : ["route_live_smoke_receipts_gate_missing_or_invalid"]),
  ...(skipRunwayCheck ? ["runway_check_skipped"] : []),
  "human_approval_required",
  "host_backup_not_observed",
  "live_same_thread_smoke_not_observed",
  "mcp_registration_on_host_not_observed",
  "rollback_receipt_not_observed"
];

const report = {
  schema: "TatwoHostReadinessGateV1",
  status: failed.length === 0 && sandboxValidated ? "passed" : "failed",
  sandboxValidated,
  hostInstallAllowed: false,
  evidenceDir,
  skippedEvidence,
  checks,
  failedCheckIDs: failed,
  hostPreflightUnknownHighOrCriticalCheckIDs: hostPreflightUnknowns,
  hostInstallBlockedBy,
  nextActions: sandboxValidated
    ? [
        "Do not mutate host yet; ask human approval for host install.",
        ...(skipRunwayCheck ? ["Rerun readiness without --skip-runway-check before any host promotion."] : []),
        "Keep the host sandbox rehearsal receipt; it proves the install recipe only in fake HOME/CODEX_HOME.",
        "Review route-risk-dashboard.log before UI/host work; every route risk still needs live same-thread response.completed proof or a stale-error explanation.",
        "Review route-live-smoke-receipts.log; missing route receipts remain host blockers, not sandbox failures.",
        "Before host install: backup Codex config/state/models cache and validate rollback receipt.",
        "Run gateway same-thread smoke and MCP registration smoke on the host after explicit approval.",
        "Use tatwo-host-install-verified-gate.mjs; do not treat mcp-stdio as host registration."
      ]
    : [
        "Fix failed checks and rerun scripts/tatwo-ultrawork-sandbox-check.sh.",
        "Do not install into host until sandboxValidated=true."
      ],
  generatedAt: new Date().toISOString()
};

emit(report);
process.exit(failed.length === 0 && sandboxValidated ? 0 : 1);

function resolveEvidenceDir(parsed) {
  if (parsed["evidence-dir"]) return path.resolve(String(parsed["evidence-dir"]));
  if (parsed.latest || parsed._.length === 0) {
    if (!fs.existsSync(evidenceRoot)) return null;
    const dirs = fs.readdirSync(evidenceRoot, { withFileTypes: true })
      .filter(d => d.isDirectory() && /^\d{8}T\d{6}Z$/.test(d.name))
      .map(d => path.join(evidenceRoot, d.name))
      .sort();
    return dirs.at(-1) ?? null;
  }
  return path.resolve(String(parsed._[0]));
}

function fileHasContent(file) {
  try {
    const stat = fs.statSync(path.join(evidenceDir, file));
    return stat.isFile() && stat.size > 0;
  } catch {
    return false;
  }
}

function read(file) {
  try { return fs.readFileSync(path.join(evidenceDir, file), "utf8"); }
  catch { return ""; }
}

function includes(file, needle) {
  return read(file).includes(needle);
}

function matches(file, pattern) {
  return pattern.test(read(file));
}

function parseCLIEnvelope(file) {
  const text = read(file);
  const start = text.indexOf("{");
  if (start < 0) return null;
  try { return JSON.parse(text.slice(start)); }
  catch { return null; }
}

function parseJSONDocument(file) {
  const text = read(file);
  const start = text.indexOf("{");
  if (start < 0) return null;
  try { return JSON.parse(text.slice(start)); }
  catch { return null; }
}

function check(id, passed, observed, description) {
  return { id, passed: Boolean(passed), observed, description };
}

function includesAll(list, values) {
  return Array.isArray(list) && values.every(value => list.includes(value));
}

function routeListsFromPreflight(preflight) {
  const checks = Array.isArray(preflight?.checks) ? preflight.checks : [];
  const route = checks.find(item => item?.id === "gateway-route-error-state");
  const observed = String(route?.observed ?? "");
  return {
    routeErrors: parseListAfter(observed, "routes_with_errors=").filter(item => item !== "none"),
    routesWithoutLastOK: parseListAfter(observed, "without_last_ok=").filter(item => item !== "none")
  };
}

function parseListAfter(text, marker) {
  const source = String(text ?? "");
  const start = source.indexOf(marker);
  if (start < 0) return [];
  const tail = source.slice(start + marker.length);
  const stopCandidates = [tail.indexOf(", without_"), tail.indexOf(", routes_"), tail.indexOf(", important="), tail.indexOf(";")].filter(n => n >= 0);
  const stop = stopCandidates.length ? Math.min(...stopCandidates) : tail.length;
  return tail.slice(0, stop).split(/[\s,]+/).map(s => s.trim()).filter(Boolean);
}

function unique(values) {
  return [...new Set(values.filter(Boolean))];
}

function emit(value) {
  console.log(JSON.stringify(value, null, 2));
}

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith("--")) { out._.push(arg); continue; }
    const eq = arg.indexOf("=");
    if (eq >= 0) {
      out[arg.slice(2, eq)] = arg.slice(eq + 1);
    } else {
      const key = arg.slice(2);
      out[key] = argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[++i] : true;
    }
  }
  return out;
}
