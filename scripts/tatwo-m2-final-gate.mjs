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
const humanApproval = clean(args["human-approval"] ?? args["m2-approval"] ?? args["approval"] ?? null);
const explicitConfirm = process.env.TATWO_M2_USER_CONFIRMED === "1" || args["confirm-m2"] === true;

const docs = evidenceDir ? {
  readiness: parseJSONDocument("host-readiness-gate.log"),
  bundle: parseJSONDocument("host-receipt-bundle.log"),
  verified: parseJSONDocument("host-install-verified-gate.log"),
  routeLive: parseJSONDocument("route-live-smoke-receipts.log"),
  backup: parseFirstJSONDocument(["host-backup-plan-confirmed.log", "host-backup-plan-live.log"]),
  rollback: parseFirstJSONDocument(["host-rollback-plan-validated.log", "host-rollback-plan-live.log"]),
  sameThread: parseFirstJSONDocument(["host-same-thread-smoke-live.log", "host-same-thread-smoke.log"]),
  mcp: parseJSONDocument("host-mcp-registration-smoke.log"),
  promotion: parseJSONDocument("host-promotion-plan.log"),
  redaction: read("redaction-scan.log")
} : {};

const checks = [];
const expectedRouteIDs = Array.isArray(docs.routeLive?.expectedRouteIDs) ? docs.routeLive.expectedRouteIDs : [];
const routeEvaluations = Array.isArray(docs.routeLive?.routeReceiptEvaluations) ? docs.routeLive.routeReceiptEvaluations : [];
const cleanRouteState = expectedRouteIDs.length === 0
  && docs.routeLive?.status === "no_risky_routes_baseline_same_thread_still_required"
  && docs.routeLive?.routeLiveSmokeAllPassed === true;
const riskyRoutesPassed = expectedRouteIDs.length > 0
  && docs.routeLive?.routeLiveSmokeAllPassed === true
  && routeEvaluations.every(item => item?.passed === true && String(item?.receiptID ?? "").startsWith("route-live-"));

checks.push(check(
  "evidence-dir-loaded",
  Boolean(evidenceDir),
  evidenceDir ? sanitizeEvidenceDir(evidenceDir) : "missing",
  "M2 final must read a concrete evidence bundle."
));
checks.push(check(
  "sandbox-readiness-passed",
  docs.readiness?.schema === "TatwoHostReadinessGateV1"
    && docs.readiness?.status === "passed"
    && docs.readiness?.sandboxValidated === true
    && Array.isArray(docs.readiness?.failedCheckIDs)
    && docs.readiness.failedCheckIDs.length === 0,
  `status=${docs.readiness?.status ?? null}, sandboxValidated=${docs.readiness?.sandboxValidated ?? null}, failed=${JSON.stringify(docs.readiness?.failedCheckIDs ?? null)}`,
  "M2 depends on the full workflow-first sandbox receipts, not model approval."
));
checks.push(check(
  "receipt-bundle-complete",
  docs.bundle?.schema === "TatwoHostReceiptBundleV1"
    && docs.bundle?.hostInstallEvidenceComplete === true
    && docs.bundle?.preflightClear === true
    && docs.bundle?.status === "host-evidence-complete",
  `status=${docs.bundle?.status ?? null}, complete=${docs.bundle?.hostInstallEvidenceComplete ?? null}, preflightClear=${docs.bundle?.preflightClear ?? null}`,
  "M2 final requires the host receipt bundle to be complete: backup, rollback, live same-thread, host MCP registration, route gate, and clear preflight."
));
checks.push(check(
  "verified-install-gate-passed-readonly",
  docs.verified?.schema === "TatwoVerifiedHostInstallGateV1"
    && docs.verified?.hostInstallAllowed === true
    && docs.verified?.hostMutationAllowed === false
    && docs.verified?.hostMutationPerformed === false
    && Array.isArray(docs.verified?.failedCheckIDs)
    && docs.verified.failedCheckIDs.length === 0,
  `hostInstallAllowed=${docs.verified?.hostInstallAllowed ?? null}, failed=${JSON.stringify(docs.verified?.failedCheckIDs ?? null)}`,
  "The evidence-backed install gate must pass as a read-only decision. It still does not patch Codex App or install UI."
));
checks.push(check(
  "fresh-m2-human-approval",
  isM2Approval(humanApproval)
    && explicitConfirm
    && docs.verified?.receiptIDs?.humanApproval === humanApproval,
  `approval=${humanApproval ?? null}, confirm=${explicitConfirm}, verifiedHuman=${docs.verified?.receiptIDs?.humanApproval ?? null}`,
  "M2 final requires a fresh M2 approval receipt, not M1 dry-run approval or model text."
));
checks.push(check(
  "backup-receipt",
  docs.backup?.schema === "TatwoHostBackupPlanV1"
    && docs.backup?.backupExecuted === true
    && String(docs.backup?.receiptID ?? "").startsWith("backup-")
    && docs.bundle?.receiptIDs?.backup === docs.backup?.receiptID,
  `backupExecuted=${docs.backup?.backupExecuted ?? null}, receipt=${docs.backup?.receiptID ?? null}`,
  "A local allowlisted backup must exist before M2 can run real host work."
));
checks.push(check(
  "rollback-receipt",
  docs.rollback?.schema === "TatwoHostRollbackPlanV1"
    && docs.rollback?.rollbackPlanValidated === true
    && String(docs.rollback?.receiptID ?? "").startsWith("rollback-")
    && docs.bundle?.receiptIDs?.rollback === docs.rollback?.receiptID,
  `rollbackValidated=${docs.rollback?.rollbackPlanValidated ?? null}, receipt=${docs.rollback?.receiptID ?? null}`,
  "Rollback must be validated against the backup directory; a plan without required files is not enough."
));
checks.push(check(
  "same-thread-live-smoke",
  docs.sameThread?.schema === "TatwoHostSameThreadSmokeReceiptV1"
    && docs.sameThread?.passed === true
    && docs.sameThread?.sameThreadSmokeExecuted === true
    && String(docs.sameThread?.receiptID ?? "").startsWith("same-thread-")
    && docs.bundle?.receiptIDs?.sameThreadSmoke === docs.sameThread?.receiptID,
  `executed=${docs.sameThread?.sameThreadSmokeExecuted ?? null}, passed=${docs.sameThread?.passed ?? null}, receipt=${docs.sameThread?.receiptID ?? null}`,
  "Gateway same-thread smoke must be a host-live command receipt, not a dry run or model statement."
));
checks.push(check(
  "route-live-or-clean-baseline",
  docs.routeLive?.schema === "TatwoRouteLiveSmokeReceiptsGateV1"
    && docs.routeLive?.hostMutationAllowed === false
    && docs.routeLive?.hostInstallAllowed === false
    && (cleanRouteState || riskyRoutesPassed),
  `expectedRoutes=${JSON.stringify(expectedRouteIDs)}, status=${docs.routeLive?.status ?? null}, cleanRouteState=${cleanRouteState}, riskyRoutesPassed=${riskyRoutesPassed}`,
  "If risky routes exist, each needs route-live receipts. If none exist, the clean gate plus baseline same-thread smoke is acceptable."
));
checks.push(check(
  "host-mcp-registration",
  docs.mcp?.schema === "TatwoHostMCPRegistrationSmokeReceiptV1"
    && docs.mcp?.passed === true
    && docs.mcp?.hostRegistrationObserved === true
    && docs.mcp?.registrationMutationPerformed === false
    && String(docs.mcp?.receiptID ?? "").startsWith("mcp-host-")
    && docs.bundle?.receiptIDs?.mcpRegistrationSmoke === docs.mcp?.receiptID,
  `passed=${docs.mcp?.passed ?? null}, hostRegistrationObserved=${docs.mcp?.hostRegistrationObserved ?? null}, receipt=${docs.mcp?.receiptID ?? null}`,
  "MCP must be observed in Codex host config; stdio-only smoke is not enough for M2."
));
checks.push(check(
  "ui-deferred-and-no-app-bundle-patch",
  (docs.promotion?.schema === "TatwoHostPromotionPlanV1" ? docs.promotion?.uiDeferred === true : true)
    && docs.bundle?.hostMutationAllowed === false
    && docs.verified?.hostMutationPerformed === false,
  `uiDeferred=${docs.promotion?.uiDeferred ?? "not_in_bundle"}, bundleHostMutationAllowed=${docs.bundle?.hostMutationAllowed ?? null}, verifiedHostMutationPerformed=${docs.verified?.hostMutationPerformed ?? null}`,
  "M2 does not start UI polish and does not patch the signed Codex App bundle."
));
checks.push(check(
  "redaction-scan-passed",
  /redaction_scan=passed/.test(docs.redaction ?? ""),
  /redaction_scan=passed/.test(docs.redaction ?? "") ? "passed" : "missing_or_failed",
  "Shareable repo output must not contain obvious tokens/auth material."
));
checks.push(check(
  "legacy-active-skills-hidden",
  legacySkillHidden("open-ultrawork") && legacySkillHidden("codex-app-model-gateway"),
  `open-ultrawork=${legacySkillHidden("open-ultrawork")}, codex-app-model-gateway=${legacySkillHidden("codex-app-model-gateway")}`,
  "Archived legacy skill folders must stay hidden from the active skill picker by not having SKILL.md."
));

const failedCheckIDs = checks.filter(item => !item.passed).map(item => item.id);
const m2Passed = failedCheckIDs.length === 0;
const report = {
  schema: "TatwoM2FinalGateV1",
  m2Passed,
  projectRunwayReady: m2Passed,
  hostInstallDecisionReady: m2Passed,
  hostInstallPerformed: false,
  uiValidated: false,
  uiDeferred: true,
  hostMutationAllowed: false,
  signedCodexAppBundlePatched: false,
  evidenceDir: evidenceDir ? sanitizeEvidenceDir(evidenceDir) : null,
  modeReceipt: {
    mode: "L",
    chinese: "專案",
    helperCap: 16,
    maxRounds: 2,
    stopCondition: "any failed receipt, route disconnect, missing rollback, missing MCP host registration, or missing visual evidence for UI"
  },
  roleReceipt: {
    macroLead: "GPT/Codex host",
    codeAuthoring: "Codex executor with Claude/Opus advisory review where available",
    verifier: "deterministic scripts plus independent reviewer",
    finalAuthority: "Codex host evidence, not model text"
  },
  receiptIDs: {
    sandboxValidated: docs.bundle?.receiptIDs?.sandboxValidated ?? null,
    hostSandboxRehearsal: docs.bundle?.receiptIDs?.hostSandboxRehearsal ?? null,
    preflightClear: docs.bundle?.receiptIDs?.preflightClear ?? null,
    humanApproval,
    backup: docs.bundle?.receiptIDs?.backup ?? null,
    rollback: docs.bundle?.receiptIDs?.rollback ?? null,
    sameThreadSmoke: docs.bundle?.receiptIDs?.sameThreadSmoke ?? null,
    routeLiveSmoke: docs.bundle?.receiptIDs?.routeLiveSmoke ?? null,
    mcpRegistrationSmoke: docs.bundle?.receiptIDs?.mcpRegistrationSmoke ?? null,
    final: m2Passed ? `m2-final-${shortHash(JSON.stringify(checks.map(item => [item.id, item.passed, item.observed])))}` : null
  },
  checks,
  failedCheckIDs,
  blockedBy: failedCheckIDs.map(id => `check_failed:${id}`),
  safeNextActions: m2Passed ? [
    "You can run real non-UI Tatwo Ultrawork L-mode projects through the registered MCP/gateway runway.",
    "Keep UI/UJ claims fail-closed until screenshot or interactive evidence exists.",
    "Keep backups local-only and use rollback commands from the rollback receipt if host config must be reverted.",
    "Before any future route/provider change, rerun preflight, same-thread smoke, route gate, receipt bundle, and this M2 final gate."
  ] : [
    "Do not claim M2 complete.",
    "Fix failed checks, regenerate the affected receipts, then rerun host-receipt-bundle, verified gate, and M2 final gate.",
    "Do not start UI/M3 or patch Codex App bundle while M2 is red."
  ],
  plainSummary: m2Passed
    ? "M2 passed: workflow and host wiring have real backup, rollback, same-thread, MCP host registration, route, redaction, and verified-gate receipts. UI is still intentionally not validated."
    : `M2 not passed: ${failedCheckIDs.join(", ") || "unknown"}。不要把模型口頭同意當驗收。`,
  generatedAt: new Date().toISOString()
};

console.log(JSON.stringify(report, null, 2));
process.exit(m2Passed ? 0 : 2);

function check(id, passed, observed, description) {
  return { id, passed: Boolean(passed), observed, description };
}

function resolveEvidenceDir(parsed) {
  if (parsed["evidence-dir"]) return path.resolve(String(parsed["evidence-dir"]));
  if (parsed.latest || parsed._.length === 0) {
    try {
      const dirs = fs.readdirSync(evidenceRoot, { withFileTypes: true })
        .filter(d => d.isDirectory() && /^\d{8}T\d{6}Z$/.test(d.name))
        .map(d => path.join(evidenceRoot, d.name))
        .sort();
      return dirs.at(-1) ?? null;
    } catch { return null; }
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
  const json = firstJSONObject(text);
  if (!json) return null;
  try {
    const parsed = JSON.parse(json);
    return parsed?.data && parsed?.schema === undefined ? parsed.data : parsed;
  } catch { return null; }
}

function parseFirstJSONDocument(files) {
  for (const file of files) {
    const doc = parseJSONDocument(file);
    if (doc) return doc;
  }
  return null;
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

function legacySkillHidden(name) {
  return !fs.existsSync(path.join("/Volumes", "CodexData", "skills", name, "SKILL.md"));
}

function sanitizeEvidenceDir(value) {
  const resolved = String(value);
  const marker = `${path.sep}.tatwo-ultrawork${path.sep}evidence${path.sep}`;
  const idx = resolved.indexOf(marker);
  if (idx >= 0) return `<repo>${resolved.slice(idx)}`;
  return "<evidence-dir>";
}

function shortHash(value) {
  return crypto.createHash("sha256").update(String(value)).digest("hex").slice(0, 12);
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
