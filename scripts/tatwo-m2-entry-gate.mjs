#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const evidenceRoot = path.join(repoRoot, ".tatwo-ultrawork", "evidence");
const args = parseArgs(process.argv.slice(2));
const evidenceDir = resolveEvidenceDir(args);
const humanApproval = clean(args["human-approval"] ?? args["m2-approval"] ?? args["approval"] ?? null);
const explicitConfirm = process.env.TATWO_M2_USER_CONFIRMED === "1" || args["confirm-m2"] === true;

const checks = [];
const files = evidenceDir ? {
  objective: parseJSONDocument("objective-audit.log"),
  readiness: parseJSONDocument("host-readiness-gate.log"),
  bundle: parseJSONDocument("host-receipt-bundle.log"),
  verified: parseJSONDocument("host-install-verified-gate.log"),
  promotion: parseJSONDocument("host-promotion-plan.log"),
  routeLive: parseJSONDocument("route-live-smoke-receipts.log"),
  m1Summary: read("m1-verification-summary.log")
} : {};

const verifiedHumanApproval = files.verified?.receiptIDs?.humanApproval ?? null;
const expectedRouteIDs = Array.isArray(files.routeLive?.expectedRouteIDs) ? files.routeLive.expectedRouteIDs : [];
const routeGateLoaded = files.routeLive?.schema === "TatwoRouteLiveSmokeReceiptsGateV1"
  && files.routeLive?.hostMutationAllowed === false
  && files.routeLive?.hostInstallAllowed === false;
const routeQueueVisible = routeGateLoaded
  && (
    expectedRouteIDs.length > 0
    || files.routeLive?.status === "no_risky_routes_baseline_same_thread_still_required"
    || files.routeLive?.routeLiveSmokeAllPassed === true
  );

checks.push(check(
  "evidence-dir-loaded",
  Boolean(evidenceDir),
  evidenceDir ? sanitizePath(evidenceDir) : "missing",
  "An M2 entry decision must point at a concrete M1 evidence bundle."
));
checks.push(check(
  "m1-objective-sandbox-milestone",
  (files.objective?.schema === "TatwoObjectiveAuditV1" || files.objective?.schema === "TatwoObjectiveCompletionAuditV1")
    && files.objective?.status === "workflow_ready_host_blocked_ui_deferred"
    && files.objective?.sandboxMilestonePassed === true
    && files.objective?.objectiveComplete === false,
  `status=${files.objective?.status ?? null}, sandboxMilestonePassed=${files.objective?.sandboxMilestonePassed ?? null}, objectiveComplete=${files.objective?.objectiveComplete ?? null}`,
  "M1 must be complete only for workflow-first sandbox scope, not the full host/UI objective."
));
checks.push(check(
  "m1-readiness-passed",
  files.readiness?.schema === "TatwoHostReadinessGateV1"
    && files.readiness?.status === "passed"
    && files.readiness?.sandboxValidated === true
    && Array.isArray(files.readiness?.failedCheckIDs)
    && files.readiness.failedCheckIDs.length === 0,
  `status=${files.readiness?.status ?? null}, failed=${JSON.stringify(files.readiness?.failedCheckIDs ?? null)}`,
  "M1 readiness gate must pass before even considering M2."
));
checks.push(check(
  "host-install-still-blocked",
  files.verified?.schema === "TatwoVerifiedHostInstallGateV1"
    && files.verified?.hostInstallAllowed === false
    && Array.isArray(files.verified?.failedCheckIDs)
    && files.verified.failedCheckIDs.includes("backup-receipt")
    && files.verified.failedCheckIDs.includes("same-thread-live-smoke")
    && files.verified.failedCheckIDs.includes("host-mcp-registration"),
  `hostInstallAllowed=${files.verified?.hostInstallAllowed ?? null}, failed=${JSON.stringify(files.verified?.failedCheckIDs ?? null)}`,
  "Entering M2 is not host install; the verified host install gate must still be closed until live receipts exist."
));
checks.push(check(
  "m1-dryrun-approval-not-reused",
  !(typeof humanApproval === "string" && /m1|dry[-_]?run/i.test(humanApproval))
    && !(typeof verifiedHumanApproval === "string" && humanApproval === verifiedHumanApproval && /m1|dry[-_]?run/i.test(verifiedHumanApproval)),
  `provided=${humanApproval ?? null}, verifiedGateHuman=${verifiedHumanApproval ?? null}`,
  "The M1 dry-run human receipt cannot be reused as M2 authorization."
));
checks.push(check(
  "explicit-m2-human-approval",
  isM2Approval(humanApproval) && explicitConfirm,
  `approval=${humanApproval ?? null}, confirm=${explicitConfirm}`,
  "M2 requires a fresh explicit user approval, e.g. --human-approval human-M2-20260622-scope plus TATWO_M2_USER_CONFIRMED=1 or --confirm-m2."
));
checks.push(check(
  "ui-still-deferred",
  files.promotion?.schema === "TatwoHostPromotionPlanV1"
    && files.promotion?.uiDeferred === true
    && files.promotion?.hostMutationAllowed === false
    && files.promotion?.hostInstallAllowed === false,
  `uiDeferred=${files.promotion?.uiDeferred ?? null}, hostMutationAllowed=${files.promotion?.hostMutationAllowed ?? null}, hostInstallAllowed=${files.promotion?.hostInstallAllowed ?? null}`,
  "M2 entry must keep UI last and host mutation closed."
));
checks.push(check(
  "route-work-visible",
  routeQueueVisible,
  `expectedRoutes=${JSON.stringify(expectedRouteIDs)}, status=${files.routeLive?.status ?? null}`,
  "M2 must see the route live-smoke gate. If no risky routes exist, the gate must explicitly say baseline same-thread smoke is still required instead of hiding behind green gateway health."
));
checks.push(check(
  "receipt-bundle-not-promoted",
  files.bundle?.schema === "TatwoHostReceiptBundleV1"
    && files.bundle?.hostInstallAllowed === false
    && files.bundle?.hostInstallEvidenceComplete !== true,
  `status=${files.bundle?.status ?? null}, complete=${files.bundle?.hostInstallEvidenceComplete ?? null}`,
  "M2 entry must not promote dry-run receipts into a complete host install bundle."
));
checks.push(check(
  "m1-summary-if-present-is-closed",
  !files.m1Summary || /m2_allowed=false_until_user_confirms/.test(files.m1Summary),
  files.m1Summary ? "m1-summary-present-and-closed" : "m1-summary-missing-allowed-but-not-proof",
  "If an M1 summary exists, it must say M2 remains closed until user confirmation."
));

const failedCheckIDs = checks.filter(item => !item.passed).map(item => item.id);
const m2EntryAllowed = failedCheckIDs.length === 0;
const blockedBy = [
  ...failedCheckIDs.map(id => `check_failed:${id}`),
  ...(m2EntryAllowed ? [] : ["m2_user_approval_not_observed_or_not_current"]),
  ...((files.verified?.blockedBy ?? []).filter(id => [
    "host_backup_not_observed",
    "live_same_thread_smoke_not_observed",
    "route_live_smoke_receipts_missing_or_invalid",
    "mcp_registration_on_host_not_observed",
    "rollback_receipt_not_observed"
  ].includes(id)))
];

const report = {
  schema: "TatwoM2EntryGateV1",
  m2EntryAllowed,
  hostMutationAllowed: false,
  hostMutationPerformed: false,
  hostInstallAllowed: false,
  uiDeferred: true,
  evidenceDir: evidenceDir ? sanitizePath(evidenceDir) : null,
  checks,
  failedCheckIDs,
  blockedBy: [...new Set(blockedBy)],
  approval: {
    provided: humanApproval,
    explicitConfirmObserved: explicitConfirm,
    requiredPattern: "human-M2-YYYYMMDD-scope or approval-M2-YYYYMMDD-scope",
    m1DryRunApprovalRejected: true
  },
  routeWorkQueue: expectedRouteIDs.length > 0 ? expectedRouteIDs.map(modelID => ({
    modelID,
    requiredProof: [
      "host-live execution, not dry-run",
      "route-specific response.completed",
      "same-thread continuity back to gpt-5.5",
      "single model_gateway provider / model switch only",
      "no retry storm, disconnect, timeout, response.failed, or partial-only stream"
    ]
  })) : [{
    modelID: "baseline-same-thread",
    requiredProof: [
      "host-live execution, not dry-run",
      "post-update-check --full passes",
      "same-thread continuity remains on single model_gateway provider",
      "no retry storm, disconnect, timeout, response.failed, or partial-only stream",
      "if a risky route appears later, rerun route-specific smoke before promotion"
    ]
  }],
  allowedM2Scope: m2EntryAllowed ? [
    "read-only host preflight refresh",
    "confirmed local backup planning and, only with separate backup confirmation, backup execution",
    "route-specific live smoke collection after backup/rollback path is ready",
    "host MCP registration observation after explicit config scope approval"
  ] : [],
  deniedActions: [
    "no UI work from this gate",
    "no host install from this gate",
    "no signed Codex App bundle patch",
    "no per-model provider split",
    "no LaunchAgent write/load/unload from this gate",
    "no ~/.codex config/state/cache write from this gate",
    "no model-text, dry-run, response.in_progress, or mcp-stdio promotion"
  ],
  safeNextCommands: m2EntryAllowed ? [
    "node scripts/tatwo-host-preflight.mjs --json",
    "node scripts/tatwo-host-backup-plan.mjs --dry-run --json",
    "After separate backup approval: TATWO_HOST_BACKUP_CONFIRM=1 node scripts/tatwo-host-backup-plan.mjs --confirm --json",
    "node scripts/tatwo-host-rollback-plan.mjs --backup-dir <backup-dir> --json",
    "After backup/rollback evidence: route-specific live smoke receipts, then node scripts/tatwo-route-live-smoke-receipts.mjs --evidence-dir <M2-dir> --json"
  ] : [
    "Ask the user to explicitly approve M2 before running host live or route smoke work.",
    "Keep using node scripts/tatwo-host-install-verified-gate.mjs --latest --human-approval human-M1-dryrun --json as a blocked proof until approval exists."
  ],
  plainSummary: m2EntryAllowed
    ? "M2 entry is approved, but this gate still did not authorize host install or UI. Start with read-only preflight and backup/rollback receipts."
    : (failedCheckIDs.includes("explicit-m2-human-approval")
        ? "M2 entry is blocked. M1 is green, but a fresh explicit M2 user approval was not observed; no host live smoke, backup execution, host install, or UI should start."
        : "M2 entry is blocked by one or more evidence gates. Keep UI and host install closed until the failed checks are resolved."),
  generatedAt: new Date().toISOString()
};

console.log(JSON.stringify(report, null, 2));
process.exit(m2EntryAllowed ? 0 : 2);

function check(id, passed, observed, description) {
  return { id, passed: Boolean(passed), observed, description };
}

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

function read(file) {
  if (!evidenceDir) return "";
  try { return fs.readFileSync(path.join(evidenceDir, file), "utf8"); }
  catch { return ""; }
}

function parseJSONDocument(file) {
  const text = read(file);
  const start = text.indexOf("{");
  if (start < 0) return null;
  const end = text.lastIndexOf("}");
  if (end < start) return null;
  try { return JSON.parse(text.slice(start, end + 1)); }
  catch { return null; }
}

function clean(value) {
  if (!value) return null;
  const out = String(value).trim().replace(/\/Users\/[\S]+|\/Volumes\/[\S]+|auth\.json|sk-[A-Za-z0-9_-]+|Bearer [A-Za-z0-9._-]+/g, "<redacted>");
  return out || null;
}

function isM2Approval(value) {
  return typeof value === "string"
    && /^(human|approval)-M2-[A-Za-z0-9._-]{4,90}$/.test(value)
    && !/(m1|dry[-_]?run|auth|token|secret|sk-|bearer|\/Users\/|\/Volumes\/)/i.test(value);
}

function sanitizePath(value) {
  const resolved = String(value);
  const marker = `${path.sep}.tatwo-ultrawork${path.sep}evidence${path.sep}`;
  const idx = resolved.indexOf(marker);
  if (idx >= 0) return `<repo>${resolved.slice(idx)}`;
  return "<evidence-dir>";
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
