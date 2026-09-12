#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const evidenceRoot = path.join(repoRoot, ".tatwo-ultrawork", "evidence");
const args = parseArgs(process.argv.slice(2));
const evidenceDir = resolveEvidenceDir(args);
const checks = [];

if (!evidenceDir || !fs.existsSync(evidenceDir)) {
  emit({
    schema: "TatwoObjectiveAdversarialV1",
    passed: false,
    hostMutationAllowed: false,
    hostMutationPerformed: false,
    evidenceDir: null,
    checks: [check("evidence-dir", false, "missing", "Objective adversarial drill needs a sandbox evidence directory.")],
    failedCheckIDs: ["evidence-dir"],
    plainSummary: "No sandbox evidence exists; run tatwo-ultrawork-sandbox-check first.",
    generatedAt: new Date().toISOString()
  });
  process.exit(1);
}

checks.push(check(
  "baseline-objective-remains-incomplete",
  runObjectiveAudit(evidenceDir).data?.status === "workflow_ready_host_blocked_ui_deferred"
    && runObjectiveAudit(evidenceDir).data?.objectiveComplete === false
    && runObjectiveAudit(evidenceDir).data?.uiDeferred === true,
  baselineObserved(),
  "The honest baseline must be workflow-ready, UI-deferred, host-blocked, and not full objective complete."
));

checks.push(readinessTamperCheck(
  "readiness-rejects-objective-complete",
  temp => patchJSON(temp, "objective-audit.log", doc => ({
    ...doc,
    status: "complete",
    objectiveComplete: true,
    completionBlockedBy: []
  })),
  ["objective-audit-workflow-first"],
  "Readiness must reject a forged objective audit that claims full completion."
));

checks.push(readinessTamperCheck(
  "readiness-rejects-ui-not-deferred",
  temp => patchJSON(temp, "objective-audit.log", doc => ({
    ...doc,
    uiDeferred: false,
    deniedActions: []
  })),
  ["objective-audit-workflow-first"],
  "Readiness must reject a forged objective audit that tries to start UI before the runway is clear."
));

checks.push(readinessTamperCheck(
  "readiness-rejects-missing-core-requirement",
  temp => patchJSON(temp, "objective-audit.log", doc => ({
    ...doc,
    requirements: (doc.requirements ?? []).filter(item => item.id !== "team-loops-scripted")
  })),
  ["objective-audit-workflow-first"],
  "Readiness must reject an objective audit that omits the team-loop/script/sandbox requirement."
));

checks.push(readinessTamperCheck(
  "readiness-rejects-missing-host-blocker",
  temp => patchJSON(temp, "objective-audit.log", doc => ({
    ...doc,
    completionBlockedBy: (doc.completionBlockedBy ?? []).filter(item => item !== "live_same_thread_smoke_not_observed")
  })),
  ["objective-audit-workflow-first"],
  "Readiness must reject an objective audit that hides the missing live same-thread smoke blocker."
));

checks.push(objectiveTamperCheck(
  "objective-audit-rejects-weak-team-loop",
  temp => {
    writeJSON(temp, "team-loop-js.log", {
      schema: "TatwoTeamLoopPacketV1",
      mode: "XL",
      scenario: "coding",
      hostMutationAllowed: false,
      modelTraitSummary: [{ id: "gpt-5.5", calibrationNotes: [] }],
      roleBoundaries: [],
      workflowLoops: []
    });
  },
  ["team-loops-scripted"],
  "Objective audit must fail when team loops have no scripts, receipts, role boundaries, or stop conditions."
));

checks.push(objectiveTamperCheck(
  "objective-audit-rejects-host-runway-promotion",
  temp => patchJSON(temp, "host-install-runway-final.log", doc => ({
    ...doc,
    currentPhase: "ready_for_approved_host_install",
    hostInstallAllowed: true,
    missingReceipts: []
  })),
  ["host-install-fail-closed"],
  "Objective audit must fail if sandbox evidence pretends host install is already allowed."
));

checks.push(objectiveTamperCheck(
  "objective-audit-rejects-sandbox-host-mutation",
  temp => patchJSON(temp, "host-backup-plan-dry.log", doc => ({
    ...doc,
    dryRun: false,
    backupExecuted: true,
    hostMutationAllowed: true
  })),
  ["no-host-mutation-in-sandbox"],
  "Objective audit must fail when sandbox evidence shows host mutation or confirmed backup execution."
));

checks.push(objectiveTamperCheck(
  "objective-audit-rejects-promotion-hidden-route-risk",
  temp => patchJSON(temp, "host-promotion-plan.log", doc => ({
    ...doc,
    routeRiskTriage: {
      ...(doc.routeRiskTriage ?? {}),
      status: "observed_clean",
      routeErrorVisible: false,
      routeErrors: [],
      routesWithoutLastOK: [],
      blockedBy: [],
      requiredBeforePromotion: []
    },
    blockedBy: []
  })),
  ["host-promotion-runway-defined"],
  "Objective audit must fail if the host promotion plan hides gateway route errors or routes without last_ok."
));

checks.push(objectiveTamperCheck(
  "objective-audit-rejects-route-dashboard-hidden-route-risk",
  temp => {
    injectSyntheticRouteRisk(temp);
    patchJSON(temp, "route-risk-dashboard.log", doc => ({
      ...doc,
      status: "clean_but_live_smoke_required",
      routeRiskSummary: {
        ...(doc.routeRiskSummary ?? {}),
        routeErrors: [],
        routesWithoutLastOK: [],
        riskyRouteCount: 0
      },
      riskyRoutes: [],
      blockedBy: []
    }));
  },
  ["route-risk-dashboard-visible"],
  "Objective audit must fail if the route risk dashboard hides route errors or routes without last_ok."
));

checks.push(readinessTamperCheck(
  "readiness-rejects-route-dashboard-host-install-allowed",
  temp => patchJSON(temp, "route-risk-dashboard.log", doc => ({
    ...doc,
    hostInstallAllowed: true,
    hostMutationAllowed: true,
    blockedBy: []
  })),
  ["route-risk-dashboard-visible"],
  "Readiness must reject a route risk dashboard that authorizes host install or host mutation."
));

checks.push(readinessTamperCheck(
  "readiness-rejects-route-dashboard-ui-first",
  temp => patchJSON(temp, "route-risk-dashboard.log", doc => ({
    ...doc,
    uiDeferred: false,
    deniedActions: []
  })),
  ["route-risk-dashboard-visible"],
  "Readiness must reject a route risk dashboard that says UI can begin before live route proof."
));

checks.push(objectiveTamperCheck(
  "objective-audit-rejects-route-dashboard-removes-live-smoke",
  temp => patchJSON(temp, "route-risk-dashboard.log", doc => ({
    ...doc,
    routeRiskSummary: {
      ...(doc.routeRiskSummary ?? {}),
      liveSmokeRequired: false,
      responseCompletedRequired: false
    },
    requiredBeforePromotion: [],
    riskyRoutes: (doc.riskyRoutes ?? []).map(route => ({
      ...route,
      requiredProof: ["gateway health green"]
    }))
  })),
  ["route-risk-dashboard-visible"],
  "Objective audit must fail if the route risk dashboard removes live same-thread response.completed proof."
));

checks.push(objectiveTamperCheck(
  "objective-audit-rejects-route-smoke-plan-hidden-route-risk",
  temp => {
    injectSyntheticRouteRisk(temp);
    patchJSON(temp, "route-smoke-plan.log", doc => ({
      ...doc,
      status: "no_route_risks_observed_still_requires_same_thread_baseline",
      routeSmokeQueue: [],
      blockedBy: []
    }));
  },
  ["route-smoke-plan-visible"],
  "Objective audit must fail if the route smoke plan hides route errors or routes without last_ok."
));

checks.push(readinessTamperCheck(
  "readiness-rejects-route-smoke-plan-host-install-allowed",
  temp => patchJSON(temp, "route-smoke-plan.log", doc => ({
    ...doc,
    hostInstallAllowed: true,
    hostMutationAllowed: true,
    blockedBy: []
  })),
  ["route-smoke-plan-visible"],
  "Readiness must reject a route smoke plan that authorizes host install or host mutation."
));

checks.push(readinessTamperCheck(
  "readiness-rejects-route-smoke-plan-ui-first",
  temp => patchJSON(temp, "route-smoke-plan.log", doc => ({
    ...doc,
    uiDeferred: false,
    deniedActions: []
  })),
  ["route-smoke-plan-visible"],
  "Readiness must reject a route smoke plan that starts UI before route-specific live proof."
));

checks.push(objectiveTamperCheck(
  "objective-audit-rejects-route-smoke-plan-removes-response-completed",
  temp => patchJSON(temp, "route-smoke-plan.log", doc => ({
    ...doc,
    baselineSameThreadSmoke: {
      ...(doc.baselineSameThreadSmoke ?? {}),
      mustSee: ["sameThreadSmokeExecuted=true", "passed=true"]
    },
    routeSmokeQueue: (doc.routeSmokeQueue ?? []).map(route => ({
      ...route,
      requiredProof: ["gateway health green", "same thread continuity back to gpt-5.5"]
    }))
  })),
  ["route-smoke-plan-visible"],
  "Objective audit must fail if the route smoke plan removes response.completed proof."
));

checks.push(objectiveTamperCheck(
  "objective-audit-rejects-route-smoke-plan-removes-gpt-continuity",
  temp => {
    injectSyntheticRouteRisk(temp);
    patchJSON(temp, "route-smoke-plan.log", doc => ({
      ...doc,
      status: "route_smoke_live_receipts_required",
      routeSmokeQueue: [syntheticRouteSmokeItem({
        sameThreadSequence: ["grok-build"],
        requiredProof: ["live same-thread smoke", "route-specific response.completed"]
      })],
      blockedBy: ["route_smoke_live_receipts_missing"]
    }));
  },
  ["route-smoke-plan-visible"],
  "Objective audit must fail if the route smoke plan does not switch back to gpt-5.5 for continuity."
));

checks.push(readinessTamperCheck(
  "readiness-rejects-route-smoke-plan-route-alone-starts-ui",
  temp => {
    injectSyntheticRouteRisk(temp);
    patchJSON(temp, "route-smoke-plan.log", doc => ({
      ...doc,
      status: "route_smoke_live_receipts_required",
      routeSmokeQueue: [syntheticRouteSmokeItem({
        canStartUIAfterThisAlone: true,
        canInstallHostAfterThisAlone: true
      })],
      blockedBy: ["route_smoke_live_receipts_missing"]
    }));
  },
  ["route-smoke-plan-visible"],
  "Readiness must reject route items that claim one route smoke alone can start UI or install host."
));

checks.push(readinessTamperCheck(
  "readiness-rejects-route-live-gate-host-install-allowed",
  temp => patchJSON(temp, "route-live-smoke-receipts.log", doc => ({
    ...doc,
    hostInstallAllowed: true,
    hostMutationAllowed: true,
    blockedBy: [],
    deniedActions: []
  })),
  ["route-live-smoke-receipts-gate"],
  "Readiness must reject a route-live-smoke receipt gate that authorizes UI/host mutation."
));

checks.push(objectiveTamperCheck(
  "objective-audit-rejects-route-live-gate-removes-denials",
  temp => patchJSON(temp, "route-live-smoke-receipts.log", doc => ({
    ...doc,
    deniedActions: ["no signed Codex App bundle patch"]
  })),
  ["route-live-smoke-receipts-gated"],
  "Objective audit must fail if the route-live gate stops denying model-text, partial-stream, or dry-run promotion."
));

checks.push(objectiveTamperCheck(
  "objective-audit-rejects-route-live-fake-pass-without-receipt",
  temp => patchJSON(temp, "route-live-smoke-receipts.log", doc => ({
    ...doc,
    status: "route_live_smoke_passed",
    allRouteLiveReceiptsPassed: true,
    routeLiveSmokeAllPassed: true,
    receiptID: null,
    blockedBy: [],
    routeReceiptEvaluations: (doc.routeReceiptEvaluations ?? []).map(item => ({
      ...item,
      passed: true,
      receiptID: "model-text-said-ok",
      failedReasons: []
    }))
  })),
  ["route-live-smoke-receipts-gated"],
  "Objective audit must fail if route-live receipts are forged as passed without a route-live-bundle-* receipt."
));

checks.push(readinessTamperCheck(
  "readiness-rejects-promotion-host-install-allowed",
  temp => patchJSON(temp, "host-promotion-plan.log", doc => ({
    ...doc,
    hostInstallAllowed: true,
    hostMutationAllowed: true,
    blockedBy: []
  })),
  ["host-promotion-plan-readonly-runway"],
  "Readiness must reject a promotion plan that opens host install or host mutation."
));

checks.push(readinessTamperCheck(
  "readiness-rejects-promotion-ui-first",
  temp => patchJSON(temp, "host-promotion-plan.log", doc => ({
    ...doc,
    uiDeferred: false,
    deniedActions: []
  })),
  ["host-promotion-plan-readonly-runway"],
  "Readiness must reject a promotion plan that starts UI before workflow and host receipts are clear."
));

checks.push(objectiveTamperCheck(
  "objective-audit-rejects-promotion-strategy-removed",
  temp => patchJSON(temp, "host-promotion-plan.log", doc => ({
    ...doc,
    connectionStrategy: (doc.connectionStrategy ?? []).filter(item => item.id !== "keep-single-gateway-provider" && item.id !== "mcp-wrapper-not-bundle-patch")
  })),
  ["host-promotion-runway-defined"],
  "Objective audit must fail if the promotion plan stops protecting single-provider or no-bundle-patch strategy."
));

checks.push(objectiveTamperCheck(
  "objective-audit-rejects-promotion-breakers-removed",
  temp => patchJSON(temp, "host-promotion-plan.log", doc => ({
    ...doc,
    circuitBreakers: []
  })),
  ["host-promotion-runway-defined"],
  "Objective audit must fail if the promotion plan omits disconnect, partial-stream, route, provider, MCP, or UI self-pass circuit breakers."
));

const failedCheckIDs = checks.filter(item => !item.passed).map(item => item.id);
emit({
  schema: "TatwoObjectiveAdversarialV1",
  passed: failedCheckIDs.length === 0,
  hostMutationAllowed: false,
  hostMutationPerformed: false,
  evidenceDir: sanitizeEvidenceDir(evidenceDir),
  checks,
  failedCheckIDs,
  deniedActions: [
    "does not write ~/.codex",
    "does not write LaunchAgents",
    "does not patch signed Codex App bundle",
    "does not read auth/session/token material",
    "does not promote UI or host install"
  ],
  plainSummary: failedCheckIDs.length === 0
    ? "Objective adversarial drill passed: fake completion, UI-first promotion, weak team loops, hidden host blockers, and sandbox host mutation are rejected."
    : `Objective adversarial drill failed: ${failedCheckIDs.join(", ")}.`,
  generatedAt: new Date().toISOString()
});
process.exit(failedCheckIDs.length === 0 ? 0 : 1);

function baselineObserved() {
  const baseline = runObjectiveAudit(evidenceDir).data;
  return {
    status: baseline?.status,
    objectiveComplete: baseline?.objectiveComplete,
    uiDeferred: baseline?.uiDeferred,
    blockers: baseline?.completionBlockedBy
  };
}

function readinessTamperCheck(id, mutate, expectedFailedIDs, description) {
  return withTempEvidence(temp => {
    mutate(temp);
    ensureObjectiveAdversarialSelfPass(temp);
    const result = runNode("tatwo-host-readiness-gate.mjs", ["--evidence-dir", temp, "--json"], { allowFailure: true });
    return check(
      id,
      result.status !== 0 && includesAll(result.data?.failedCheckIDs, expectedFailedIDs),
      { exit: result.status, failedCheckIDs: result.data?.failedCheckIDs, status: result.data?.status },
      description
    );
  });
}

function objectiveTamperCheck(id, mutate, expectedFailedRequirementIDs, description) {
  return withTempEvidence(temp => {
    mutate(temp);
    const result = runObjectiveAudit(temp, { allowFailure: true });
    const failedRequirements = Array.isArray(result.data?.requirements)
      ? result.data.requirements.filter(item => item.status === "failed").map(item => item.id)
      : [];
    return check(
      id,
      result.status !== 0 && includesAll(failedRequirements, expectedFailedRequirementIDs),
      { exit: result.status, status: result.data?.status, failedRequirements },
      description
    );
  });
}

function withTempEvidence(fn) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-objective-adv-"));
  try {
    copyDir(evidenceDir, temp);
    return fn(temp);
  } finally {
    fs.rmSync(temp, { recursive: true, force: true });
  }
}

function copyDir(src, dst) {
  fs.mkdirSync(dst, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const source = path.join(src, entry.name);
    const target = path.join(dst, entry.name);
    if (entry.isDirectory()) copyDir(source, target);
    else if (entry.isFile()) fs.copyFileSync(source, target);
  }
}

function patchJSON(dir, file, mutate) {
  const current = parseFirstJSON(readFile(path.join(dir, file))) ?? {};
  writeJSON(dir, file, mutate(current));
}

function writeJSON(dir, file, value) {
  fs.writeFileSync(path.join(dir, file), `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function injectSyntheticRouteRisk(dir) {
  patchJSON(dir, "host-preflight-live.log", doc => ({
    ...doc,
    checks: (Array.isArray(doc.checks) ? doc.checks : []).map(item => item?.id === "gateway-route-error-state"
      ? {
          ...item,
          status: "installed",
          observed: "routes=15, important=5/5, routes_with_errors=grok-build:synthetic, without_last_ok=grok-build",
          remediation: "Synthetic adversarial fixture: this risk must stay visible until live same-thread response.completed proof exists."
        }
      : item)
  }));
}

function syntheticRouteSmokeItem(overrides = {}) {
  return {
    id: "route-smoke-synthetic",
    modelID: "grok-build",
    ownerTeam: "環境穩定團隊",
    helperTeams: ["總控團隊", "代碼團隊"],
    riskKinds: ["route_error", "no_last_ok"],
    plainWhy: "Synthetic adversarial fixture: route risk must not be hidden by a green dashboard.",
    commandHint: "TATWO_HOST_SAME_THREAD_SMOKE=1 node scripts/tatwo-host-same-thread-smoke.mjs --run --gateway-dir <gateway-dir> --json",
    sameThreadSequence: ["gpt-5.5 baseline", "grok-build", "gpt-5.5 continuity check"],
    requiredProof: [
      "live same-thread smoke",
      "route-specific response.completed",
      "same thread continuity back to gpt-5.5",
      "no retry storm / disconnected / partial stream"
    ],
    failClosedIf: [
      "only gateway health is green",
      "only model text says OK",
      "only response.in_progress or output_text.delta is observed"
    ],
    resultReceiptClass: "host_live route-specific same-thread receipt",
    canStartUIAfterThisAlone: false,
    canInstallHostAfterThisAlone: false,
    ...overrides
  };
}

function ensureObjectiveAdversarialSelfPass(dir) {
  writeJSON(dir, "objective-adversarial.log", {
    schema: "TatwoObjectiveAdversarialV1",
    passed: true,
    hostMutationAllowed: false,
    hostMutationPerformed: false,
    checks: Array.from({ length: 6 }, (_, index) => ({ id: `fixture-${index}`, passed: true })),
    failedCheckIDs: []
  });
}

function runObjectiveAudit(dir, options = {}) {
  return runNode("tatwo-objective-audit.mjs", ["--evidence-dir", dir, "--json"], options);
}

function runNode(script, commandArgs, options = {}) {
  const result = spawnSync("node", [path.join(scriptDir, script), ...commandArgs], {
    cwd: repoRoot,
    encoding: "utf8",
    timeout: 120000,
    maxBuffer: 10 * 1024 * 1024
  });
  if (!options.allowFailure && result.status !== 0) {
    return { data: null, status: result.status, error: sanitize(`${result.stdout}\n${result.stderr}`) };
  }
  const parsed = parseFirstJSON(`${result.stdout ?? ""}\n${result.stderr ?? ""}`);
  return { data: parsed, status: result.status, error: parsed ? null : sanitize(`${result.stdout}\n${result.stderr}`) };
}

function parseFirstJSON(text) {
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
      else if (ch === "\\\\") escaped = true;
      else if (ch === "\"") inString = false;
      continue;
    }
    if (ch === "\"") { inString = true; continue; }
    if (ch === "{") depth += 1;
    if (ch === "}") {
      depth -= 1;
      if (depth === 0) {
        try { return JSON.parse(raw.slice(start, i + 1)); }
        catch { return null; }
      }
    }
  }
  return null;
}

function readFile(file) {
  try { return fs.readFileSync(file, "utf8"); }
  catch { return ""; }
}

function check(id, passed, observed, description) {
  return {
    id,
    passed: Boolean(passed),
    observed: sanitize(JSON.stringify(observed)),
    description
  };
}

function includesAll(list, values) {
  return Array.isArray(list) && values.every(value => list.includes(value));
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
    } catch {
      return null;
    }
  }
  return path.resolve(String(parsed._[0]));
}

function sanitizeEvidenceDir(value) {
  if (!value) return null;
  return String(value).includes(".tatwo-ultrawork/evidence") ? "<evidence-dir>" : sanitize(value);
}

function sanitize(value) {
  return String(value ?? "")
    .replace(/\/Users\/[\S]+|\/Volumes\/[\S]+/g, "<local-path>")
    .replace(/sk-[A-Za-z0-9_-]{20,}/g, "<redacted-token>")
    .replace(/Bearer [A-Za-z0-9._-]+/g, "Bearer <redacted>")
    .replace(/auth\.json/g, "<auth-file>");
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

function emit(value) {
  console.log(JSON.stringify(value, null, 2));
}
