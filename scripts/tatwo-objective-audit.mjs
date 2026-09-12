#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const evidenceRoot = path.join(repoRoot, ".tatwo-ultrawork", "evidence");
const args = parseArgs(process.argv.slice(2));
const evidenceDir = resolveEvidenceDir(args);

if (!evidenceDir) {
  emit({
    schema: "TatwoObjectiveCompletionAuditV1",
    status: "failed",
    objectiveComplete: false,
    currentMilestone: "missing_sandbox_evidence",
    sandboxMilestonePassed: false,
    uiDeferred: true,
    hostInstallAllowed: false,
    hostMutationAllowed: false,
    evidenceDir: null,
    requirements: [req("evidence-dir", "Evidence bundle", "環境穩定團隊", false, "missing", "Run sandbox check first.", ["sandbox_evidence_missing"], "Run bash scripts/tatwo-ultrawork-sandbox-check.sh")],
    completionBlockedBy: ["sandbox_evidence_missing"],
    safeNextCommands: ["MODEL_GATEWAY_DIR=<gateway-dir> OPEN_ULTRAWORK_DIR=<open-ultrawork-dir> bash scripts/tatwo-ultrawork-sandbox-check.sh"],
    plainSummary: "No evidence bundle exists yet; objective completion is unproven.",
    generatedAt: new Date().toISOString()
  });
  process.exit(1);
}

const requirements = [];
const teamTraitsEnvelope = parseCLIEnvelope("team-traits.log");
const modelTraits = Array.isArray(teamTraitsEnvelope?.data) ? teamTraitsEnvelope.data : [];
const teamListEnvelope = parseCLIEnvelope("team-list.log");
const teams = Array.isArray(teamListEnvelope?.data) ? teamListEnvelope.data : [];
const teamLoop = parseJSONDocument("team-loop-js.log");
const readiness = parseJSONDocument("host-readiness-gate.log");
const runway = parseJSONDocument("host-install-runway-final.log");
const bundle = parseJSONDocument("host-receipt-bundle.log");
const disconnectGuard = parseJSONDocument("codex-disconnect-guard.log");
const integrationDrill = parseJSONDocument("integration-adversarial-drill.log");
const operationalDrill = parseJSONDocument("operational-receipt-adversarial.log");
const preflightLive = parseJSONDocument("host-preflight-live.log");
const mcpRegistration = parseJSONDocument("host-mcp-registration-smoke.log");
const hostPromotion = parseJSONDocument("host-promotion-plan.log");
const routeRiskDashboard = parseJSONDocument("route-risk-dashboard.log");
const routeSmokePlan = parseJSONDocument("route-smoke-plan.log");
const routeLiveReceipts = parseJSONDocument("route-live-smoke-receipts.log");
const fugu = parseCLIEnvelope("integration-fugu-policy.log")?.data ?? parseJSONDocument("integration-fugu-policy.log")?.data ?? parseJSONDocument("integration-fugu-policy.log");

const dashboardText = read("team-dashboard.log");
const runwayText = read("host-install-runway-final.log");
requirements.push(req(
  "ui-last",
  "UI 放最後，不用 UI 當假進度",
  "總控團隊",
  dashboardText.includes("\"uiDeferred\" : true") && runway?.uiDeferred === true,
  `dashboard.uiDeferred=${dashboardText.includes("\"uiDeferred\" : true")}, runway.uiDeferred=${runway?.uiDeferred}`,
  "team-dashboard.log + host-install-runway-final.log",
  [],
  "等 workflow runway 綠且 host receipts 清楚後，才開始上方工作列 UI。"
));

requirements.push(req(
  "workflow-core",
  "workflow / sandbox / readiness 核心已起來",
  "環境穩定團隊 + 代碼團隊",
  readiness?.schema === "TatwoHostReadinessGateV1" && readiness.status === "passed" && readiness.sandboxValidated === true,
  `readiness.status=${readiness?.status}, sandboxValidated=${readiness?.sandboxValidated}`,
  "host-readiness-gate.log",
  readiness?.status === "passed" ? [] : ["readiness_gate_not_passed"],
  "Fix failed readiness checks and rerun sandbox check."
));

const traitIDs = new Set(modelTraits.map(item => item?.id));
const everyTraitExplains = modelTraits.length >= 6
  && modelTraits.every(item => nonEmpty(item?.plainFailureMode) && nonEmpty(item?.verificationRule) && Array.isArray(item?.calibrationNotes) && item.calibrationNotes.length > 0);
const hasGPTUISelfPass = modelTraits.some(item => item?.id === "gpt-5.5" && JSON.stringify(item).includes("UI") && JSON.stringify(item).includes("self-pass"));
const hasGrokRefutation = modelTraits.some(item => item?.id === "grok-build" && JSON.stringify(item).includes("反例"));
requirements.push(req(
  "model-traits-calibrated",
  "先有可觀的模型特質表，再分工",
  "總控團隊",
  everyTraitExplains && hasGPTUISelfPass && hasGrokRefutation && traitIDs.has("minimax-m3") && traitIDs.has("opus-5"),
  `traits=${modelTraits.length}, gpt_ui_self_pass=${hasGPTUISelfPass}, grok_refutation=${hasGrokRefutation}`,
  "team-traits.log",
  everyTraitExplains ? [] : ["model_trait_calibration_missing"],
  "Add plain failure mode, verification rule, and calibrationNotes for each model trait."
));

const requiredTeamIDs = ["control-team", "design-team", "code-team", "research-team", "stability-team", "trading-risk-team", "memory-team"];
const teamIDs = new Set(teams.map(item => item?.id));
const teamsHaveReadableParts = requiredTeamIDs.every(id => teamIDs.has(id))
  && teams.every(item => nonEmpty(item?.chineseName) && Array.isArray(item?.members) && item.members.length > 0 && Array.isArray(item?.loops) && item.loops.length > 0 && Array.isArray(item?.gates) && item.gates.length > 0);
requirements.push(req(
  "teams-defined",
  "用團隊歸納模型分工，且分工好懂",
  "總控團隊",
  teamsHaveReadableParts,
  `teams=${[...teamIDs].sort().join(",")}`,
  "team-list.log",
  teamsHaveReadableParts ? [] : ["team_definition_incomplete"],
  "Ensure each team has Chinese name, members, loops, gates, and forbidden boundaries."
));

const loopList = Array.isArray(teamLoop?.workflowLoops) ? teamLoop.workflowLoops : [];
const loopsHaveReceipts = loopList.length >= 3
  && loopList.every(loop => Array.isArray(loop.steps) && loop.steps.length > 0
    && Array.isArray(loop.scriptsOrCommands) && loop.scriptsOrCommands.length > 0
    && nonEmpty(loop.sandboxPolicy)
    && nonEmpty(loop.stopCondition)
    && Array.isArray(loop.requiredReceipts) && loop.requiredReceipts.length > 0);
const loopHasBoundaries = Array.isArray(teamLoop?.roleBoundaries) && teamLoop.roleBoundaries.length >= 4
  && JSON.stringify(teamLoop.roleBoundaries).includes("final pass")
  && (JSON.stringify(teamLoop.roleBoundaries).includes("host") || JSON.stringify(teamLoop.roleBoundaries).includes("主機"));
requirements.push(req(
  "team-loops-scripted",
  "團隊有對應 workflow loops、腳本、沙盒與停止條件",
  "總控團隊 + 環境穩定團隊",
  teamLoop?.schema === "TatwoTeamLoopPacketV1" && loopsHaveReceipts && loopHasBoundaries && teamLoop.hostMutationAllowed === false,
  `loops=${loopList.length}, boundaries=${teamLoop?.roleBoundaries?.length}, hostMutationAllowed=${teamLoop?.hostMutationAllowed}`,
  "team-loop-js.log",
  loopsHaveReceipts ? [] : ["team_loop_receipts_or_stop_conditions_missing"],
  "Keep scripts/tatwo-team-loop.mjs emitting workflow loops with scripts, sandboxPolicy, stopCondition, and receipts."
));

const guardIDs = new Set(Array.isArray(disconnectGuard?.checks) ? disconnectGuard.checks.filter(item => item?.passed).map(item => item.id) : []);
const neededGuardIDs = ["single-model-gateway-provider", "semantic-sse-in-progress", "clean-413-not-reset", "gateway-route-error-state-observable", "auth-single-source-check", "stdio-is-not-host-registration"];
requirements.push(req(
  "codex-disconnect-guarded",
  "接入實裝前要降低 Codex 斷線風險",
  "環境穩定團隊",
  disconnectGuard?.schema === "TatwoCodexDisconnectGuardV1" && disconnectGuard.passed === true && neededGuardIDs.every(id => guardIDs.has(id)),
  `passed=${disconnectGuard?.passed}, guards=${[...guardIDs].join(",")}`,
  "codex-disconnect-guard.log",
  neededGuardIDs.filter(id => !guardIDs.has(id)).map(id => `guard_missing:${id}`),
  "Fix disconnect guard source/tests before host smoke."
));

const preflightChecks = Array.isArray(preflightLive?.checks) ? preflightLive.checks : [];
const routeState = preflightChecks.find(item => item?.id === "gateway-route-error-state");
const singleGateway = preflightChecks.find(item => item?.id === "codex-model-provider-single-gateway");
requirements.push(req(
  "host-preflight-readonly",
  "主機接入先只讀盤點，不偷改主機",
  "環境穩定團隊",
  preflightLive?.readOnly === true && preflightLive.hostMutationAllowed === false && singleGateway?.status === "installed" && routeState?.status === "installed",
  `readOnly=${preflightLive?.readOnly}, singleGateway=${singleGateway?.status}, routeState=${routeState?.observed ?? "missing"}`,
  "host-preflight-live.log",
  preflightLive?.readOnly === true ? [] : ["host_preflight_not_readonly"],
  "Use read-only host preflight before any backup/install; do not kill or restart processes in this phase."
));

const promotionStrategyIDs = Array.isArray(hostPromotion?.connectionStrategy) ? hostPromotion.connectionStrategy.map(item => item?.id) : [];
const promotionBreakerIDs = Array.isArray(hostPromotion?.circuitBreakers) ? hostPromotion.circuitBreakers.map(item => item?.id) : [];
const promotionRouteTriage = hostPromotion?.routeRiskTriage ?? {};
const promotionRouteErrors = Array.isArray(promotionRouteTriage.routeErrors) ? promotionRouteTriage.routeErrors : [];
const promotionRoutesWithoutLastOK = Array.isArray(promotionRouteTriage.routesWithoutLastOK) ? promotionRouteTriage.routesWithoutLastOK : [];
const promotionBlockedBy = Array.isArray(promotionRouteTriage.blockedBy) ? promotionRouteTriage.blockedBy : [];
const promotionRequiredBefore = Array.isArray(promotionRouteTriage.requiredBeforePromotion) ? promotionRouteTriage.requiredBeforePromotion.join(" ") : "";
const liveRouteLists = routeListsFromPreflight(preflightLive);
const promotionShowsLiveRouteErrors = includesAll(promotionRouteErrors, liveRouteLists.routeErrors);
const promotionShowsLiveNoLastOK = includesAll(promotionRoutesWithoutLastOK, liveRouteLists.routesWithoutLastOK);
const strategyOK = includesAll(promotionStrategyIDs, ["keep-single-gateway-provider", "mcp-wrapper-not-bundle-patch", "sandbox-before-host", "ui-last-data-first"]);
const breakerOK = includesAll(promotionBreakerIDs, ["stream-disconnect", "partial-stream", "route-error-state", "provider-split", "mcp-stdio-only", "ui-self-pass"]);
const routeRiskOK = promotionRouteTriage.routeErrorVisible === true
  && promotionShowsLiveRouteErrors
  && promotionShowsLiveNoLastOK
  && (promotionRouteErrors.length === 0 || promotionBlockedBy.includes("gateway_route_errors_need_live_smoke"))
  && (promotionRoutesWithoutLastOK.length === 0 || promotionBlockedBy.includes("gateway_routes_without_last_ok_need_live_smoke"))
  && ((promotionRouteErrors.length + promotionRoutesWithoutLastOK.length) === 0 || promotionRequiredBefore.includes("live same-thread smoke"));
requirements.push(req(
  "host-promotion-runway-defined",
  "接入實裝路線已定義，但仍只讀、UI 延後、主機安裝關閉",
  "環境穩定團隊 + 總控團隊",
  hostPromotion?.schema === "TatwoHostPromotionPlanV1"
    && hostPromotion.uiDeferred === true
    && hostPromotion.hostMutationAllowed === false
    && hostPromotion.hostInstallAllowed === false
    && strategyOK
    && breakerOK
    && routeRiskOK,
  `schema=${hostPromotion?.schema}, uiDeferred=${hostPromotion?.uiDeferred}, hostMutationAllowed=${hostPromotion?.hostMutationAllowed}, hostInstallAllowed=${hostPromotion?.hostInstallAllowed}, strategies=${promotionStrategyIDs.join(",")}, breakers=${promotionBreakerIDs.join(",")}, routeErrors=${promotionRouteErrors.join(",")}, preflightRouteErrors=${liveRouteLists.routeErrors.join(",")}, withoutLastOK=${promotionRoutesWithoutLastOK.join(",")}`,
  "host-promotion-plan.log + host-preflight-live.log",
  [
    ...(hostPromotion?.schema === "TatwoHostPromotionPlanV1" ? [] : ["host_promotion_plan_missing"]),
    ...(hostPromotion?.uiDeferred === true ? [] : ["ui_not_deferred_in_promotion_plan"]),
    ...(hostPromotion?.hostMutationAllowed === false && hostPromotion?.hostInstallAllowed === false ? [] : ["host_promotion_plan_not_fail_closed"]),
    ...(strategyOK ? [] : ["host_promotion_strategy_incomplete"]),
    ...(breakerOK ? [] : ["host_promotion_circuit_breakers_incomplete"]),
    ...(routeRiskOK ? [] : ["host_promotion_route_risk_hidden_or_untriaged"])
  ],
  "Keep host promotion as a read-only runway: single gateway, no bundle patch, sandbox first, UI last, route risks visible, and circuit breakers present."
));

const routeDashboardRoutes = Array.isArray(routeRiskDashboard?.riskyRoutes) ? routeRiskDashboard.riskyRoutes : [];
const routeDashboardRouteIDs = routeDashboardRoutes.map(item => item?.modelID).filter(Boolean);
const liveRiskModelIDs = unique([
  ...liveRouteLists.routeErrors.map(item => String(item).split(":")[0]).filter(Boolean),
  ...liveRouteLists.routesWithoutLastOK
]);
const dashboardRequiredBefore = Array.isArray(routeRiskDashboard?.requiredBeforePromotion) ? routeRiskDashboard.requiredBeforePromotion.join(" ") : "";
const dashboardProofOK = routeDashboardRoutes.every(item => {
  const proof = Array.isArray(item?.requiredProof) ? item.requiredProof.join(" ") : "";
  return proof.includes("live same-thread smoke") && proof.includes("response.completed");
});
const dashboardRiskOK = routeRiskDashboard?.schema === "TatwoRouteRiskDashboardV1"
  && routeRiskDashboard.uiDeferred === true
  && routeRiskDashboard.hostMutationAllowed === false
  && routeRiskDashboard.hostInstallAllowed === false
  && routeRiskDashboard.routeStateVisible === true
  && routeRiskDashboard?.routeRiskSummary?.liveSmokeRequired === true
  && routeRiskDashboard?.routeRiskSummary?.responseCompletedRequired === true
  && includesAll(routeDashboardRouteIDs, liveRiskModelIDs)
  && dashboardRequiredBefore.includes("live same-thread smoke")
  && dashboardRequiredBefore.includes("response.completed")
  && dashboardProofOK;
requirements.push(req(
  "route-risk-dashboard-visible",
  "route 風險有白話 dashboard，不讓綠燈藏錯誤",
  "環境穩定團隊",
  dashboardRiskOK,
  `schema=${routeRiskDashboard?.schema}, uiDeferred=${routeRiskDashboard?.uiDeferred}, hostMutationAllowed=${routeRiskDashboard?.hostMutationAllowed}, hostInstallAllowed=${routeRiskDashboard?.hostInstallAllowed}, routeStateVisible=${routeRiskDashboard?.routeStateVisible}, riskyRoutes=${routeDashboardRouteIDs.join(",")}, liveRiskRoutes=${liveRiskModelIDs.join(",")}`,
  "route-risk-dashboard.log + host-preflight-live.log",
  [
    ...(routeRiskDashboard?.schema === "TatwoRouteRiskDashboardV1" ? [] : ["route_risk_dashboard_missing"]),
    ...(routeRiskDashboard?.uiDeferred === true ? [] : ["route_risk_dashboard_started_ui"]),
    ...(routeRiskDashboard?.hostMutationAllowed === false && routeRiskDashboard?.hostInstallAllowed === false ? [] : ["route_risk_dashboard_allows_host_install"]),
    ...(routeRiskDashboard?.routeStateVisible === true ? [] : ["route_risk_state_not_visible"]),
    ...(includesAll(routeDashboardRouteIDs, liveRiskModelIDs) ? [] : ["route_risk_dashboard_hidden_route"]),
    ...(dashboardRequiredBefore.includes("live same-thread smoke") && dashboardProofOK ? [] : ["route_risk_dashboard_missing_live_smoke_proof"])
  ],
  "Keep every route error / no-last-ok route visible in plain Chinese, and require route-specific response.completed before host promotion."
));

const routeSmokeQueue = Array.isArray(routeSmokePlan?.routeSmokeQueue) ? routeSmokePlan.routeSmokeQueue : [];
const routeSmokeIDs = routeSmokeQueue.map(item => item?.modelID).filter(Boolean);
const routeSmokeBlockedBy = Array.isArray(routeSmokePlan?.blockedBy) ? routeSmokePlan.blockedBy : [];
const routeSmokeBaselineMustSee = Array.isArray(routeSmokePlan?.baselineSameThreadSmoke?.mustSee)
  ? routeSmokePlan.baselineSameThreadSmoke.mustSee.join(" ")
  : "";
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
const routeSmokeRiskBlockerOK = liveRiskModelIDs.length === 0
  ? routeSmokePlan?.status === "no_route_risks_observed_still_requires_same_thread_baseline"
  : routeSmokeBlockedBy.includes("route_smoke_live_receipts_missing");
const routeSmokePlanOK = routeSmokePlan?.schema === "TatwoRouteSmokePlanV1"
  && routeSmokePlan.uiDeferred === true
  && routeSmokePlan.hostMutationAllowed === false
  && routeSmokePlan.hostInstallAllowed === false
  && includesAll(routeSmokeIDs, liveRiskModelIDs)
  && routeSmokeProofOK
  && routeSmokeRiskBlockerOK
  && routeSmokeBaselineMustSee.includes("response.completed")
  && routeSmokeBaselineMustSee.includes("passed=true");
requirements.push(req(
  "route-smoke-plan-visible",
  "每條有風險 route 都變成同 thread smoke 排隊，不讓 UI 或實裝偷跑",
  "環境穩定團隊",
  routeSmokePlanOK,
  `schema=${routeSmokePlan?.schema}, status=${routeSmokePlan?.status}, uiDeferred=${routeSmokePlan?.uiDeferred}, hostMutationAllowed=${routeSmokePlan?.hostMutationAllowed}, hostInstallAllowed=${routeSmokePlan?.hostInstallAllowed}, routeSmokeQueue=${routeSmokeIDs.join(",")}, liveRiskRoutes=${liveRiskModelIDs.join(",")}`,
  "route-smoke-plan.log + host-preflight-live.log",
  [
    ...(routeSmokePlan?.schema === "TatwoRouteSmokePlanV1" ? [] : ["route_smoke_plan_missing"]),
    ...(routeSmokePlan?.uiDeferred === true ? [] : ["route_smoke_plan_started_ui"]),
    ...(routeSmokePlan?.hostMutationAllowed === false && routeSmokePlan?.hostInstallAllowed === false ? [] : ["route_smoke_plan_allows_host_install"]),
    ...(includesAll(routeSmokeIDs, liveRiskModelIDs) ? [] : ["route_smoke_plan_hidden_route"]),
    ...(routeSmokeProofOK ? [] : ["route_smoke_plan_missing_response_completed_or_continuity"]),
    ...(routeSmokeRiskBlockerOK ? [] : ["route_smoke_live_receipt_blocker_missing"]),
    ...(routeSmokeBaselineMustSee.includes("response.completed") ? [] : ["route_smoke_baseline_completed_proof_missing"])
  ],
  "Run route-specific live same-thread smoke only after human approval and backup; keep UI deferred until response.completed receipts exist."
));

const routeLiveExpectedIDs = Array.isArray(routeLiveReceipts?.expectedRouteIDs) ? routeLiveReceipts.expectedRouteIDs : [];
const routeLiveBlockedBy = Array.isArray(routeLiveReceipts?.blockedBy) ? routeLiveReceipts.blockedBy : [];
const routeLiveEvaluations = Array.isArray(routeLiveReceipts?.routeReceiptEvaluations) ? routeLiveReceipts.routeReceiptEvaluations : [];
const routeLiveDenied = Array.isArray(routeLiveReceipts?.deniedActions) ? routeLiveReceipts.deniedActions : [];
const routeLivePassedWithReceipt = routeLiveReceipts?.routeLiveSmokeAllPassed === true
  && typeof routeLiveReceipts?.receiptID === "string"
  && routeLiveReceipts.receiptID.startsWith("route-live-bundle-")
  && (routeLiveExpectedIDs.length === 0 || routeLiveEvaluations.every(item => item?.passed === true && typeof item?.receiptID === "string" && item.receiptID.startsWith("route-live-")));
const routeLiveGateOK = routeLiveReceipts?.schema === "TatwoRouteLiveSmokeReceiptsGateV1"
  && routeLiveReceipts.uiDeferred === true
  && routeLiveReceipts.hostMutationAllowed === false
  && routeLiveReceipts.hostInstallAllowed === false
  && routeLiveReceipts.hostMutationPerformed === false
  && routeLiveDenied.includes("no model-text promotion to route receipt")
  && routeLiveDenied.includes("no partial stream or response.in_progress promotion")
  && routeLiveDenied.includes("no dry-run promotion to host-live route receipt")
  && (
    routeLivePassedWithReceipt
    || (
      routeLiveExpectedIDs.length > 0
      && routeLiveBlockedBy.includes("route_live_smoke_receipts_missing_or_invalid")
      && routeLiveEvaluations.every(item => item?.passed === false && Array.isArray(item?.failedReasons) && item.failedReasons.length > 0)
    )
  );
requirements.push(req(
  "route-live-smoke-receipts-gated",
  "route live smoke 收據有獨立 gate，假完成不能放行 UI 或主機",
  "環境穩定團隊",
  routeLiveGateOK,
  `schema=${routeLiveReceipts?.schema}, expected=${routeLiveExpectedIDs.join(",")}, allPassed=${routeLiveReceipts?.routeLiveSmokeAllPassed}, blockedBy=${routeLiveBlockedBy.slice(0, 8).join(",")}`,
  "route-live-smoke-receipts.log",
  [
    ...(routeLiveReceipts?.schema === "TatwoRouteLiveSmokeReceiptsGateV1" ? [] : ["route_live_smoke_receipts_gate_missing"]),
    ...(routeLiveReceipts?.uiDeferred === true ? [] : ["route_live_gate_started_ui"]),
    ...(routeLiveReceipts?.hostMutationAllowed === false && routeLiveReceipts?.hostInstallAllowed === false ? [] : ["route_live_gate_allows_host_install"]),
    ...(routeLiveDenied.includes("no model-text promotion to route receipt") ? [] : ["route_live_gate_missing_model_text_denial"]),
    ...(routeLiveDenied.includes("no partial stream or response.in_progress promotion") ? [] : ["route_live_gate_missing_partial_stream_denial"]),
    ...(routeLiveDenied.includes("no dry-run promotion to host-live route receipt") ? [] : ["route_live_gate_missing_dry_run_denial"]),
    ...(routeLiveGateOK ? [] : ["route_live_smoke_receipts_gate_not_fail_closed"])
  ],
  "Keep route-live-smoke-receipts.log in the sandbox run. It may pass only with host-live route receipts; otherwise it must clearly block promotion."
));

const externalGatewaySkipped = read("model-gateway-tests.log").includes("model_gateway_tests=skipped");
const externalGatewayPassed = /\btests\s+[1-9]\d*\b/.test(read("model-gateway-tests.log")) && /\bpass\s+[1-9]\d*\b/.test(read("model-gateway-tests.log")) && /\bfail\s+0\b/.test(read("model-gateway-tests.log"));
const openUltraworkSkipped = read("open-ultrawork-tests.log").includes("open_ultrawork_tests=skipped");
const openUltraworkPassed = read("open-ultrawork-tests.log").includes("ultrawork selftest ok");
requirements.push(req(
  "external-core-smokes",
  "gateway 與 open-ultrawork 外部核心有驗證或明確 blocker",
  "環境穩定團隊",
  externalGatewayPassed && openUltraworkPassed,
  `modelGateway=${externalGatewaySkipped ? "skipped" : externalGatewayPassed ? "passed" : "failed"}, openUltrawork=${openUltraworkSkipped ? "skipped" : openUltraworkPassed ? "passed" : "failed"}`,
  "model-gateway-tests.log + open-ultrawork-tests.log",
  [
    ...(externalGatewayPassed ? [] : [externalGatewaySkipped ? "external_model_gateway_tests_not_observed" : "external_model_gateway_tests_failed"]),
    ...(openUltraworkPassed ? [] : [openUltraworkSkipped ? "external_open_ultrawork_tests_not_observed" : "external_open_ultrawork_tests_failed"])
  ],
  "Run sandbox check with MODEL_GATEWAY_DIR and OPEN_ULTRAWORK_DIR before host promotion."
));

const adversarialPassed = integrationDrill?.passed === true
  && operationalDrill?.passed === true
  && read("validate-sample-ui.log").includes("validate_sample_ui_expected_failure=passed")
  && read("validate-sample-ui.log").includes("missing_visual_evidence");
requirements.push(req(
  "adversarial-validation",
  "對抗驗證會擋假成功、斷線、partial stream、UI 自我通過",
  "環境穩定團隊 + 設計團隊",
  adversarialPassed,
  `integration=${integrationDrill?.passed}, operational=${operationalDrill?.passed}, uiFailClosed=${read("validate-sample-ui.log").includes("validate_sample_ui_expected_failure=passed")}`,
  "integration-adversarial-drill.log + operational-receipt-adversarial.log + validate-sample-ui.log",
  adversarialPassed ? [] : ["adversarial_validation_not_proven"],
  "Do not claim completion until adversarial and UI fail-closed samples pass."
));

requirements.push(req(
  "fugu-idea-only",
  "只吸收 Fugu 架構想法，不接 Fugu 模型",
  "總控團隊",
  fugu?.schema === "TatwoFuguArchitecturePolicyV1" && fugu.integratesFuguModel === false && Array.isArray(fugu.rejectedIdeas) && fugu.rejectedIdeas.length > 0,
  `integratesFuguModel=${fugu?.integratesFuguModel}`,
  "integration-fugu-policy.log",
  fugu?.integratesFuguModel === false ? [] : ["fugu_model_integration_not_allowed"],
  "Keep Fugu as architecture inspiration only."
));

const runwayBlockedAsExpected = runway?.schema === "TatwoHostInstallRunwayV1"
  && runway.currentPhase === "sandbox_ready_host_blocked"
  && runway.hostMutationAllowed === false
  && runway.hostInstallAllowed === false
  && Array.isArray(runway.missingReceipts)
  && runway.missingReceipts.includes("live same-thread smoke receipt")
  && runway.missingReceipts.includes("mcp-host registration receipt");
requirements.push(req(
  "host-install-fail-closed",
  "實裝前仍要被真收據擋住，不能沙盒一綠就上主機",
  "環境穩定團隊 + Human",
  runwayBlockedAsExpected && bundle?.hostInstallAllowed === false && mcpRegistration?.hostRegistrationObserved === false,
  `phase=${runway?.currentPhase}, missing=${(runway?.missingReceipts ?? []).join(",")}, mcpHostObserved=${mcpRegistration?.hostRegistrationObserved}`,
  "host-install-runway-final.log + host-receipt-bundle.log + host-mcp-registration-smoke.log",
  runwayBlockedAsExpected ? [] : ["host_install_gate_not_fail_closed"],
  "Collect human approval, backup, rollback, live same-thread, and host MCP registration receipts before host install."
));

const noHostMutation = [
  "host-sandbox-rehearsal.log",
  "host-preflight-live.log",
  "host-backup-plan-dry.log",
  "host-rollback-plan-dry.log",
  "host-same-thread-smoke-dry.log",
  "host-mcp-registration-smoke.log",
  "host-install-runway-final.log"
].every(name => !read(name).includes("\"hostMutationAllowed\": true") && !read(name).includes("\"realHostMutationPerformed\": true") && !read(name).includes("\"registrationMutationPerformed\": true") && !read(name).includes("\"backupExecuted\": true"));
requirements.push(req(
  "no-host-mutation-in-sandbox",
  "沙盒與稽核不碰 ~/.codex / LaunchAgent / signed App",
  "環境穩定團隊",
  noHostMutation,
  `noHostMutation=${noHostMutation}`,
  "host-* evidence logs",
  noHostMutation ? [] : ["sandbox_host_mutation_detected"],
  "Stop and inspect evidence; sandbox checks must not mutate host."
));

const hardFailures = requirements.filter(item => item.status === "failed").map(item => item.id);
const blockers = unique([
  ...requirements.flatMap(item => item.blockedBy ?? []),
  ...(routeLiveReceipts?.routeLiveSmokeAllPassed === true ? [] : routeLiveBlockedBy),
  "ui_deferred_until_workflow_runway_and_host_receipts_are_clear",
  ...((runway?.missingReceipts ?? []).map(value => receiptBlocker(value)))
]).filter(Boolean);

const localEvidencePassed = hardFailures.length === 0;
const sandboxMilestonePassed = localEvidencePassed;
const objectiveComplete = false;
const status = !localEvidencePassed
  ? "failed"
  : "workflow_ready_host_blocked_ui_deferred";

emit({
  schema: "TatwoObjectiveCompletionAuditV1",
  status,
  objectiveComplete,
  currentMilestone: localEvidencePassed ? "workflow_core_ready_host_install_blocked_ui_last" : "workflow_core_not_proven",
  sandboxMilestonePassed,
  uiDeferred: true,
  hostInstallAllowed: false,
  hostMutationAllowed: false,
  hostMutationPerformed: false,
  evidenceDir: sanitizeEvidenceDir(evidenceDir),
  requirements,
  completionBlockedBy: blockers,
  safeNextCommands: localEvidencePassed
    ? [
        "Stay in sandbox/dry-run mode until the user explicitly approves host install scope.",
        "node scripts/tatwo-route-risk-dashboard.mjs --latest --json",
        "node scripts/tatwo-route-smoke-plan.mjs --latest --json",
        "node scripts/tatwo-route-live-smoke-receipts.mjs --latest --json",
        "TATWO_HOST_BACKUP_CONFIRM=1 node scripts/tatwo-host-backup-plan.mjs --confirm --json",
        "node scripts/tatwo-host-rollback-plan.mjs --backup-dir <backup-dir> --json",
        "TATWO_HOST_SAME_THREAD_SMOKE=1 node scripts/tatwo-host-same-thread-smoke.mjs --run --gateway-dir <gateway-dir> --json",
        "node scripts/tatwo-host-mcp-registration-smoke.mjs --expect-host-registration --host-config \"$HOME/.codex/config.toml\" --json",
        "Only after those receipts: start top-menu Codex Switch style UI wired to these data sources."
      ]
    : ["Fix failed audit requirements and rerun sandbox check."],
  deniedActions: [
    "no UI implementation before workflow/runway audit stays green",
    "no host install without human approval, backup, rollback, live same-thread, and mcp-host receipts",
    "no signed Codex App bundle patch",
    "no per-model provider split",
    "no model-text approval or dry-run promotion"
  ],
  plainSummary: localEvidencePassed
    ? "Workflow/team/stability evidence is strong enough for the current workflow-first milestone, but the full objective is intentionally not complete: UI is deferred and host install is blocked until real host receipts exist."
    : `Objective audit failed: ${hardFailures.join(", ")}. Do not proceed toward UI or host install.`,
  generatedAt: new Date().toISOString()
});

process.exit(localEvidencePassed ? 0 : 1);

function req(id, title, ownerTeam, passed, observed, evidence, blockedBy, nextAction) {
  return {
    id,
    title,
    ownerTeam,
    status: passed ? "passed" : "failed",
    evidence,
    observed: sanitize(String(observed ?? "")),
    blockedBy: passed ? [] : (Array.isArray(blockedBy) ? blockedBy : [String(blockedBy)]).filter(Boolean),
    nextAction,
    hostMutationAllowed: false
  };
}

function receiptBlocker(value) {
  const raw = String(value ?? "").toLowerCase();
  if (raw.includes("human")) return "human_approval_required";
  if (raw.includes("backup")) return "host_backup_not_observed";
  if (raw.includes("rollback")) return "rollback_receipt_not_observed";
  if (raw.includes("same-thread")) return "live_same_thread_smoke_not_observed";
  if (raw.includes("mcp-host")) return "mcp_registration_on_host_not_observed";
  if (raw.includes("preflight")) return "host_preflight_not_clear";
  return null;
}

function resolveEvidenceDir(parsed) {
  if (parsed["evidence-dir"]) return path.resolve(String(parsed["evidence-dir"]));
  if (parsed.latest || parsed._.length === 0) {
    try {
      const dirs = fs.readdirSync(evidenceRoot, { withFileTypes: true })
        .filter(item => item.isDirectory())
        .map(item => path.join(evidenceRoot, item.name))
        .sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);
      return dirs[0] ?? null;
    } catch {
      return null;
    }
  }
  return path.resolve(String(parsed._[0]));
}

function read(name) {
  try { return fs.readFileSync(path.join(evidenceDir, name), "utf8"); }
  catch { return ""; }
}

function parseCLIEnvelope(name) {
  const json = firstJSONObject(read(name));
  if (!json) return null;
  try { return JSON.parse(json); } catch { return null; }
}

function parseJSONDocument(name) {
  const json = firstJSONObject(read(name));
  if (!json) return null;
  try {
    const parsed = JSON.parse(json);
    return parsed?.data && parsed?.schema === undefined ? parsed.data : parsed;
  } catch { return null; }
}

function firstJSONObject(text) {
  const start = String(text ?? "").indexOf("{");
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

function nonEmpty(value) {
  return typeof value === "string" && value.trim().length > 0;
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

function includesAll(list, values) {
  return Array.isArray(list) && values.every(value => list.includes(value));
}

function sanitize(value) {
  return String(value ?? "")
    .replace(/\/Users\/[\S]+|\/Volumes\/[\S]+/g, "<local-path>")
    .replace(/sk-[A-Za-z0-9_-]{20,}/g, "<redacted-token>")
    .replace(/Bearer [A-Za-z0-9._-]+/g, "Bearer <redacted>")
    .replace(/auth\.json/g, "<auth-file>");
}

function sanitizeEvidenceDir(value) {
  if (!value) return null;
  return String(value).includes(".tatwo-ultrawork/evidence") ? "<evidence-dir>" : sanitize(value);
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
    if (eq >= 0) out[arg.slice(2, eq)] = arg.slice(eq + 1);
    else out[arg.slice(2)] = argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[++i] : true;
  }
  return out;
}
