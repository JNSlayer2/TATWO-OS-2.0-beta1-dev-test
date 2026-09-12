#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const evidenceRoot = path.join(repoRoot, ".tatwo-ultrawork", "evidence");
const args = parseArgs(process.argv.slice(2));
const evidenceDir = resolveEvidenceDir(args);

if (!evidenceDir || !fs.existsSync(evidenceDir)) {
  emit({
    schema: "TatwoRouteLiveSmokeReceiptsGateV1",
    status: "needs_sandbox_evidence",
    uiDeferred: true,
    hostMutationAllowed: false,
    hostMutationPerformed: false,
    hostInstallAllowed: false,
    evidenceDir: null,
    ownerTeam: "環境穩定團隊",
    expectedRoutes: [],
    receiptFilesScanned: [],
    routeReceiptEvaluations: [],
    allRouteLiveReceiptsPassed: false,
    routeLiveSmokeAllPassed: false,
    receiptID: null,
    receiptIDs: {},
    blockedBy: ["sandbox_evidence_missing", "route_smoke_plan_missing"],
    deniedActions: deniedActions(),
    plainSummary: "沒有 evidence bundle，不能判斷 route live smoke 收據；UI 與主機實裝維持關閉。",
    generatedAt: new Date().toISOString()
  });
  process.exit(1);
}

const routeSmokePlan = parseJSONDocument(path.join(evidenceDir, "route-smoke-plan.log"));
const routeRiskDashboard = parseJSONDocument(path.join(evidenceDir, "route-risk-dashboard.log"));
const expectedRoutes = expectedRoutesFrom(routeSmokePlan, routeRiskDashboard);
const receiptDocs = collectReceiptDocuments(evidenceDir);
const evaluations = expectedRoutes.map(route => evaluateRoute(route, receiptDocs));
const allRouteLiveReceiptsPassed = expectedRoutes.length === 0
  ? true
  : evaluations.every(item => item.passed === true);
const receiptID = allRouteLiveReceiptsPassed
  ? `route-live-bundle-${shortHash(JSON.stringify(evaluations.map(item => item.receiptID)))}`
  : null;
const blockedBy = unique([
  ...(routeSmokePlan?.schema === "TatwoRouteSmokePlanV1" ? [] : ["route_smoke_plan_missing"]),
  ...(routeRiskDashboard?.schema === "TatwoRouteRiskDashboardV1" ? [] : ["route_risk_dashboard_missing"]),
  ...(expectedRoutes.length > 0 && !allRouteLiveReceiptsPassed ? ["route_live_smoke_receipts_missing_or_invalid"] : []),
  ...evaluations.flatMap(item => item.passed ? [] : [`route_live_smoke_failed:${item.modelID}`]),
  ...evaluations.flatMap(item => item.failedReasons.map(reason => `${item.modelID}:${reason}`)),
  "human_approval_required_before_host_live_smoke",
  "host_backup_not_observed_before_route_smoke"
]);
const status = expectedRoutes.length === 0
  ? "no_risky_routes_baseline_same_thread_still_required"
  : (allRouteLiveReceiptsPassed ? "route_live_smoke_passed" : "route_live_smoke_blocked");

const report = {
  schema: "TatwoRouteLiveSmokeReceiptsGateV1",
  status,
  uiDeferred: true,
  hostMutationAllowed: false,
  hostMutationPerformed: false,
  hostInstallAllowed: false,
  evidenceDir: sanitizeEvidenceDir(evidenceDir),
  sourceFiles: [
    ...(routeSmokePlan?.schema ? ["route-smoke-plan.log"] : []),
    ...(routeRiskDashboard?.schema ? ["route-risk-dashboard.log"] : [])
  ],
  ownerTeam: "環境穩定團隊",
  expectedRoutes,
  expectedRouteIDs: expectedRoutes.map(item => item.modelID),
  receiptFilesScanned: receiptDocs.map(item => item.file),
  routeReceiptEvaluations: evaluations,
  allRouteLiveReceiptsPassed,
  routeLiveSmokeAllPassed: allRouteLiveReceiptsPassed,
  receiptID,
  receiptIDs: Object.fromEntries(evaluations.filter(item => item.passed && item.receiptID).map(item => [item.modelID, item.receiptID])),
  requiredProof: [
    "host-live execution, not dry-run",
    "model id matches expected route",
    "route-specific response.completed",
    "same-thread continuity back to gpt-5.5",
    "single model_gateway provider / model switch only",
    "no retry storm, disconnect, timeout, response.failed, or partial-only stream",
    "stale route-error explanation when a route_error risk is stale"
  ],
  blockedBy,
  deniedActions: deniedActions(),
  safeNextCommands: [
    "node scripts/tatwo-route-smoke-plan.mjs --latest --json",
    "node scripts/tatwo-route-live-smoke-receipts.mjs --latest --json",
    "TATWO_HOST_SAME_THREAD_SMOKE=1 node scripts/tatwo-host-same-thread-smoke.mjs --run --gateway-dir <gateway-dir> --json",
    "After live route receipt files exist, rerun node scripts/tatwo-host-receipt-bundle.mjs --latest --json"
  ],
  plainSummary: plainSummary(expectedRoutes, evaluations, allRouteLiveReceiptsPassed),
  generatedAt: new Date().toISOString()
};

emit(report);
process.exit(0);

function expectedRoutesFrom(plan, dashboard) {
  const byModel = new Map();
  const queue = Array.isArray(plan?.routeSmokeQueue) ? plan.routeSmokeQueue : [];
  for (const item of queue) {
    const modelID = String(item?.modelID ?? "").trim();
    if (!modelID) continue;
    byModel.set(modelID, {
      modelID,
      riskKinds: unique(Array.isArray(item?.riskKinds) ? item.riskKinds.map(String) : []),
      requiredProof: Array.isArray(item?.requiredProof) ? item.requiredProof.map(String) : [],
      staleRouteExplanationRequired: false
    });
  }
  const risky = Array.isArray(dashboard?.riskyRoutes) ? dashboard.riskyRoutes : [];
  for (const item of risky) {
    const modelID = String(item?.modelID ?? "").trim();
    if (!modelID) continue;
    const current = byModel.get(modelID) ?? { modelID, riskKinds: [], requiredProof: [], staleRouteExplanationRequired: false };
    current.riskKinds = unique([...current.riskKinds, ...(Array.isArray(item?.riskKinds) ? item.riskKinds.map(String) : [])]);
    current.observedErrorKind = item?.observedErrorKind ?? current.observedErrorKind ?? null;
    current.plainWhy = item?.plainChineseExplanation ?? current.plainWhy ?? null;
    current.requiredProof = unique([...current.requiredProof, ...(Array.isArray(item?.requiredProof) ? item.requiredProof.map(String) : [])]);
    byModel.set(modelID, current);
  }
  return [...byModel.values()].map(item => ({
    ...item,
    riskKinds: unique(item.riskKinds),
    staleRouteExplanationRequired: unique(item.riskKinds).includes("route_error")
  })).sort((a, b) => a.modelID.localeCompare(b.modelID));
}

function collectReceiptDocuments(dir) {
  const out = [];
  let entries = [];
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const entry of entries) {
    if (!entry.isFile()) continue;
    const name = entry.name;
    if (!/route.*live.*smoke|live.*route.*smoke|host-same-thread-smoke-live/i.test(name)) continue;
    if (name === "route-live-smoke-receipts.log") continue;
    const filePath = path.join(dir, name);
    const parsed = parseJSONDocument(filePath);
    if (!parsed) continue;
    const docs = [];
    if (parsed.schema === "TatwoRouteLiveSmokeReceiptV1") docs.push(parsed);
    if (Array.isArray(parsed.routeReceipts)) docs.push(...parsed.routeReceipts.filter(item => item && typeof item === "object"));
    if (Array.isArray(parsed.routeLiveSmokeReceipts)) docs.push(...parsed.routeLiveSmokeReceipts.filter(item => item && typeof item === "object"));
    for (const doc of docs) out.push({ file: name, doc });
  }
  return out;
}

function evaluateRoute(route, receiptDocs) {
  const matches = receiptDocs.filter(item => routeModelID(item.doc) === route.modelID);
  const wrongModelReceipts = receiptDocs.filter(item => routeModelID(item.doc) && routeModelID(item.doc) !== route.modelID);
  const candidates = matches.length ? matches : [];
  const candidateEvaluations = candidates.map(item => validateReceiptForRoute(route, item.doc, item.file));
  const best = candidateEvaluations.find(item => item.passed) ?? candidateEvaluations[0] ?? null;
  const failedReasons = best ? best.failedReasons : ["route_live_receipt_missing"];
  const wrongModelObserved = wrongModelReceipts.map(item => routeModelID(item.doc)).filter(Boolean);
  const routeHadOnlyWrongModel = matches.length === 0 && wrongModelObserved.length > 0;
  const finalReasons = unique([
    ...failedReasons,
    ...(routeHadOnlyWrongModel ? ["no_receipt_for_expected_route_model", `wrong_model_receipt_observed:${wrongModelObserved.join("|")}`] : [])
  ]);
  return {
    modelID: route.modelID,
    riskKinds: route.riskKinds,
    staleRouteExplanationRequired: Boolean(route.staleRouteExplanationRequired),
    passed: Boolean(best?.passed),
    receiptID: best?.receiptID ?? null,
    sourceFile: best?.sourceFile ?? null,
    candidateReceiptCount: candidateEvaluations.length,
    failedReasons: finalReasons,
    observed: best?.observed ?? (routeHadOnlyWrongModel ? `wrong_model_receipts=${wrongModelObserved.join(",")}` : "missing"),
    requiredProof: [
      "host_live",
      route.modelID,
      "response.completed",
      "continuity_back_to_gpt-5.5",
      "no_retry_storm_or_disconnect_or_partial"
    ]
  };
}

function validateReceiptForRoute(route, receipt, sourceFile) {
  const reasons = [];
  const modelID = routeModelID(receipt);
  if (receipt.schema !== "TatwoRouteLiveSmokeReceiptV1") reasons.push("unsupported_route_receipt_schema");
  if (!receipt.receiptID || !String(receipt.receiptID).startsWith("route-live-")) reasons.push("route_receipt_id_missing_or_wrong_prefix");
  if (modelID !== route.modelID) reasons.push("model_id_mismatch");
  if (receipt.expectedModelID && String(receipt.expectedModelID) !== route.modelID) reasons.push("expected_model_id_mismatch");
  if (receipt.dryRun === true || receipt.executionMode === "dry_run" || receipt.hostLiveExecution === false) reasons.push("dry_run_cannot_satisfy_route_live_smoke");
  if (receipt.executionMode !== "host_live" && receipt.hostLiveExecution !== true) reasons.push("host_live_execution_required");
  if (receipt.evidenceOrigin === "model_text" || receipt.source === "model_text" || receipt.modelTextSaysOK === true) reasons.push("model_text_cannot_prove_route_smoke");
  if (receipt.evidenceOrigin === "mcp_server_self_report" || receipt.transportKind === "mcp_stdio") reasons.push("mcp_stdio_or_self_report_cannot_prove_route_smoke");
  if (!allowedOrigin(receipt.evidenceOrigin)) reasons.push(`wrong_evidence_origin:${receipt.evidenceOrigin ?? "missing"}`);
  if (!allowedTransport(receipt.transportKind)) reasons.push(`wrong_transport:${receipt.transportKind ?? "missing"}`);
  if (receipt.resultState && receipt.resultState !== "pass") reasons.push(`result_state_not_pass:${receipt.resultState}`);
  if (receipt.terminalEvent && receipt.terminalEvent !== "response.completed") reasons.push(`terminal_event_not_completed:${receipt.terminalEvent}`);
  if (!responseCompleted(receipt)) reasons.push("response_completed_not_observed");
  if (!continuityBackToGPT(receipt)) reasons.push("same_thread_continuity_back_to_gpt_not_observed");
  if (!hostStateObserved(receipt)) reasons.push("host_state_not_observed");
  if (!providerStayedSingleGateway(receipt)) reasons.push("provider_split_or_model_gateway_not_observed");
  if (receipt.retryStormObserved === true || receipt.circuitOpen === true || Number(receipt.retryCount ?? 0) > 2) reasons.push("retry_storm_or_circuit_open");
  if (receipt.disconnectedObserved === true || receipt.resultState === "disconnected" || receipt.terminalEvent === "disconnected") reasons.push("disconnect_cannot_pass");
  if (receipt.timeoutObserved === true || receipt.resultState === "timeout" || receipt.terminalEvent === "timeout") reasons.push("timeout_cannot_pass");
  if (receipt.partialStreamOnly === true || receipt.resultState === "partial" || receipt.terminalEvent === "response.output_text.delta" || receipt.terminalEvent === "response.in_progress") reasons.push("partial_stream_cannot_pass");
  if (receipt.responseFailedObserved === true || receipt.terminalEvent === "response.failed") reasons.push("response_failed_cannot_pass");
  if (receipt.hostMutationAllowed === true || receipt.hostInstallAllowed === true || receipt.canStartUI === true || receipt.canInstallHost === true) reasons.push("route_receipt_must_not_authorize_ui_or_host_install");
  if (route.staleRouteExplanationRequired) {
    const explanation = String(receipt.staleRouteExplanation ?? "").trim();
    if (receipt.routeErrorStillActive === true || receipt.routeErrorActive === true) reasons.push("route_error_still_active");
    if (!explanation) reasons.push("stale_route_error_explanation_required");
  }
  const passed = reasons.length === 0;
  return {
    passed,
    receiptID: sanitize(String(receipt.receiptID ?? "")) || null,
    sourceFile,
    failedReasons: unique(reasons),
    observed: sanitize(JSON.stringify({
      modelID,
      terminalEvent: receipt.terminalEvent,
      resultState: receipt.resultState,
      responseCompletedObserved: receipt.responseCompletedObserved,
      sameThreadContinuityBackToGPT: receipt.sameThreadContinuityBackToGPT ?? receipt.sameThreadContinuityObserved,
      providerStayedModelGateway: receipt.providerStayedModelGateway ?? receipt.providerStayedSingleModelGateway,
      dryRun: receipt.dryRun
    }))
  };
}

function routeModelID(receipt) {
  return String(receipt?.routeModelID ?? receipt?.modelID ?? receipt?.targetModelID ?? receipt?.route ?? "").trim();
}

function allowedOrigin(origin) {
  return ["deterministic_command", "script_receipt", "codex_tool_trace"].includes(origin);
}

function allowedTransport(kind) {
  return ["model_gateway", "codex_app_gateway"].includes(kind);
}

function responseCompleted(receipt) {
  return receipt.responseCompletedObserved === true
    || receipt.terminalEvent === "response.completed"
    || (Array.isArray(receipt.completedEvents) && receipt.completedEvents.includes("response.completed"));
}

function continuityBackToGPT(receipt) {
  if (receipt.sameThreadContinuityBackToGPT === true || receipt.sameThreadContinuityObserved === true) return true;
  const seq = Array.isArray(receipt.sameThreadSequence) ? receipt.sameThreadSequence.map(String) : [];
  if (seq.length < 3) return false;
  const firstGPT = seq[0].includes("gpt-5.5");
  const lastGPT = seq[seq.length - 1].includes("gpt-5.5");
  return firstGPT && lastGPT && receipt.gptContinuityCheckPassed === true;
}

function hostStateObserved(receipt) {
  return receipt.hostStateObserved === true || receipt.hostLiveExecution === true;
}

function providerStayedSingleGateway(receipt) {
  if (receipt.providerStayedSingleModelGateway === true || receipt.providerStayedModelGateway === true) return true;
  if (receipt.provider === "model_gateway" && receipt.providerChanged !== true) return true;
  return false;
}

function plainSummary(routes, evaluations, allPassed) {
  if (routes.length === 0) {
    return "目前沒有 risky route 需要逐條 route live receipt；但 baseline same-thread smoke、backup、rollback、MCP host registration 仍然是主機實裝 blocker。";
  }
  if (allPassed) {
    return `route live smoke 收據全部通過：${routes.map(item => item.modelID).join("、")}。這仍不等於可實裝，還需要 human/backup/rollback/MCP-host gate。`;
  }
  const failed = evaluations.filter(item => !item.passed).map(item => `${item.modelID}(${item.failedReasons.slice(0, 2).join("+")})`);
  return `route live smoke 收據尚未通過：${failed.join("、")}。UI 延後，主機實裝關閉。`;
}

function parseJSONDocument(file) {
  const text = readFile(file);
  const json = firstJSONObject(text);
  if (!json) return null;
  try {
    const parsed = JSON.parse(json);
    return parsed?.data && parsed?.schema === undefined ? parsed.data : parsed;
  } catch { return null; }
}

function firstJSONObject(text) {
  const raw = String(text ?? "");
  const start = raw.indexOf("{");
  if (start < 0) return null;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < raw.length; i += 1) {
    const ch = raw[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (ch === "\\") escaped = true;
      else if (ch === "\"") inString = false;
      continue;
    }
    if (ch === "\"") { inString = true; continue; }
    if (ch === "{") depth += 1;
    if (ch === "}") {
      depth -= 1;
      if (depth === 0) return raw.slice(start, i + 1);
    }
  }
  return null;
}

function readFile(file) {
  try { return fs.readFileSync(file, "utf8"); }
  catch { return ""; }
}

function resolveEvidenceDir(parsed) {
  if (parsed["evidence-dir"]) return path.resolve(String(parsed["evidence-dir"]));
  if (parsed.latest || parsed._.length === 0) {
    try {
      const dirs = fs.readdirSync(evidenceRoot, { withFileTypes: true })
        .filter(item => item.isDirectory() && /^\d{8}T\d{6}Z$/.test(item.name))
        .map(item => path.join(evidenceRoot, item.name))
        .sort();
      return dirs.at(-1) ?? null;
    } catch { return null; }
  }
  return path.resolve(String(parsed._[0]));
}

function deniedActions() {
  return [
    "no UI work from route live smoke alone",
    "no host install from route live smoke alone",
    "no model-text promotion to route receipt",
    "no partial stream or response.in_progress promotion",
    "no dry-run promotion to host-live route receipt",
    "no stdio MCP receipt mixed into route pass",
    "no per-model provider split",
    "no signed Codex App bundle patch",
    "no ~/.codex write in this verifier"
  ];
}

function sanitizeEvidenceDir(value) {
  if (!value) return null;
  return String(value).includes(".tatwo-ultrawork/evidence") ? "<evidence-dir>" : sanitize(value);
}

function sanitize(value) {
  return String(value ?? "")
    .replace(/\/Users\/[\S]+|\/Volumes\/[\S]+/g, "<local-path>")
    .replace(/(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}/g, "$1<redacted-token>")
    .replace(/Bearer [A-Za-z0-9._-]+/g, "Bearer <redacted>")
    .replace(/auth\.json/g, "<auth-file>");
}

function shortHash(value) {
  return crypto.createHash("sha256").update(String(value)).digest("hex").slice(0, 12);
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
