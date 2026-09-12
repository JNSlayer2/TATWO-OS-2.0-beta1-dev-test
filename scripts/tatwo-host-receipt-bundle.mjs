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

if (!evidenceDir) {
  const report = {
    schema: "TatwoHostReceiptBundleV1",
    status: "failed",
    hostMutationAllowed: false,
    hostInstallAllowed: false,
    evidenceDir: null,
    blockedBy: ["sandbox_evidence_missing"],
    plainSummary: "No evidence directory found. Run sandbox check first."
  };
  console.log(JSON.stringify(report, null, 2));
  process.exit(1);
}

const readiness = parseJSONDocument("host-readiness-gate.log");
const rehearsal = parseJSONDocument("host-sandbox-rehearsal.log");
const livePreflight = parseJSONDocument("host-preflight-live.log");
const backup = parseFirstJSONDocument(["host-backup-plan-confirmed.log", "host-backup-plan-live.log", "host-backup-plan-dry.log"]);
const rollback = parseFirstJSONDocument(["host-rollback-plan-validated.log", "host-rollback-plan-live.log", "host-rollback-plan-dry.log"]);
const sameThread = parseFirstJSONDocument(["host-same-thread-smoke-live.log", "host-same-thread-smoke.log", "host-same-thread-smoke-dry.log"]);
const mcp = parseJSONDocument("host-mcp-registration-smoke.log");
const routeLive = parseJSONDocument("route-live-smoke-receipts.log");

const sandboxValidated = readiness?.sandboxValidated === true && readiness?.status === "passed";
const hostSandboxRehearsalPassed = rehearsal?.schema === "TatwoHostSandboxRehearsalReceiptV1"
  && rehearsal.passed === true
  && rehearsal.realHostMutationPerformed === false
  && rehearsal.hostInstallAllowed === false
  && rehearsal.rollbackValidated === true
  && rehearsal.mcpCompatibilityPassed === true
  && rehearsal.redactionScanPassed === true;
const preflightClear = Array.isArray(livePreflight?.unknownHighOrCriticalCheckIDs) && livePreflight.unknownHighOrCriticalCheckIDs.length === 0 && Array.isArray(livePreflight?.failedCriticalCheckIDs) && livePreflight.failedCriticalCheckIDs.length === 0;
const mcpCompatibilityPassed = mcp?.passed === true && mcp?.registrationMutationPerformed === false;
const rollbackPlanDryRun = rollback?.schema === "TatwoHostRollbackPlanV1" && rollback.hostMutationAllowed === false && rollback.rollbackMutationPerformed === false;
const sameThreadDryRun = sameThread?.schema === "TatwoHostSameThreadSmokeReceiptV1" && sameThread.hostMutationAllowed === false && sameThread.sameThreadSmokeExecuted === false;
const backupReceiptObserved = backup?.schema === "TatwoHostBackupPlanV1" && backup.backupExecuted === true && typeof backup.receiptID === "string" && backup.receiptID.startsWith("backup-");
const rollbackReceiptObserved = rollback?.schema === "TatwoHostRollbackPlanV1" && rollback.rollbackPlanValidated === true && typeof rollback.receiptID === "string" && rollback.receiptID.startsWith("rollback-");
const sameThreadSmokePassed = sameThread?.schema === "TatwoHostSameThreadSmokeReceiptV1" && sameThread.passed === true && sameThread.sameThreadSmokeExecuted === true && typeof sameThread.receiptID === "string" && sameThread.receiptID.startsWith("same-thread-");
const mcpHostRegistrationPassed = mcp?.schema === "TatwoHostMCPRegistrationSmokeReceiptV1" && mcp.hostRegistrationObserved === true && mcp.passed === true && typeof mcp.receiptID === "string" && mcp.receiptID.startsWith("mcp-host-");
const routeLiveExpectedRouteIDs = Array.isArray(routeLive?.expectedRouteIDs) ? routeLive.expectedRouteIDs : [];
const routeLiveGateLoaded = routeLive?.schema === "TatwoRouteLiveSmokeReceiptsGateV1"
  && routeLive.hostInstallAllowed === false
  && routeLive.hostMutationAllowed === false;
const routeLiveSmokeRequired = routeLiveExpectedRouteIDs.length > 0;
const routeLiveSmokePassed = routeLive?.schema === "TatwoRouteLiveSmokeReceiptsGateV1"
  && routeLive.routeLiveSmokeAllPassed === true
  && routeLive.hostInstallAllowed === false
  && routeLive.hostMutationAllowed === false
  && typeof routeLive.receiptID === "string"
  && routeLive.receiptID.startsWith("route-live-bundle-");
const readinessBlockers = Array.isArray(readiness?.hostInstallBlockedBy)
  ? readiness.hostInstallBlockedBy
  : [];
const forwardedReadinessBlockers = readinessBlockers.filter(id =>
  String(id).startsWith("external_") || id === "runway_check_skipped"
);
const hostInstallEvidenceComplete = sandboxValidated
  && hostSandboxRehearsalPassed
  && preflightClear
  && backupReceiptObserved
  && rollbackReceiptObserved
  && sameThreadSmokePassed
  && routeLiveGateLoaded
  && (!routeLiveSmokeRequired || routeLiveSmokePassed)
  && mcpHostRegistrationPassed
  && forwardedReadinessBlockers.length === 0;

const receiptIDs = {
  sandboxValidated: sandboxValidated ? `sandbox-${shortHash(read("host-readiness-gate.log"))}` : null,
  hostSandboxRehearsal: hostSandboxRehearsalPassed ? rehearsal.receiptID ?? `rehearsal-${shortHash(read("host-sandbox-rehearsal.log"))}` : null,
  preflightClear: preflightClear ? `preflight-${shortHash(read("host-preflight-live.log"))}` : null,
  backup: backupReceiptObserved ? backup.receiptID : null,
  rollback: rollbackReceiptObserved ? rollback.receiptID : null,
  sameThreadSmoke: sameThreadSmokePassed ? sameThread.receiptID : null,
  routeLiveSmoke: routeLiveSmokePassed ? routeLive.receiptID : null,
  mcpRegistrationSmoke: mcpHostRegistrationPassed ? mcp.receiptID : null,
  mcpCompatibility: mcpCompatibilityPassed ? mcp.receiptID : null
};

const blockedBy = [
  ...forwardedReadinessBlockers,
  ...(sandboxValidated ? [] : ["sandbox_not_validated"]),
  ...(hostSandboxRehearsalPassed ? [] : ["host_sandbox_rehearsal_not_observed"]),
  ...(preflightClear ? [] : ["host_preflight_not_clear"]),
  "human_approval_required",
  ...(receiptIDs.backup ? [] : ["host_backup_not_observed"]),
  ...(receiptIDs.sameThreadSmoke ? [] : ["live_same_thread_smoke_not_observed"]),
  ...(routeLiveGateLoaded ? [] : ["route_live_smoke_receipts_gate_missing_or_invalid"]),
  ...(!routeLiveSmokeRequired || receiptIDs.routeLiveSmoke ? [] : ["route_live_smoke_receipts_missing_or_invalid"]),
  ...(receiptIDs.mcpRegistrationSmoke ? [] : ["mcp_registration_on_host_not_observed"]),
  ...(receiptIDs.rollback ? [] : ["rollback_receipt_not_observed"])
];

const report = {
  schema: "TatwoHostReceiptBundleV1",
  status: hostInstallEvidenceComplete
    ? "host-evidence-complete"
    : (sandboxValidated && hostSandboxRehearsalPassed && mcpCompatibilityPassed && rollbackPlanDryRun && sameThreadDryRun && routeLiveGateLoaded ? "prepared" : "incomplete"),
  hostMutationAllowed: false,
  hostInstallAllowed: false,
  hostInstallEvidenceComplete,
  evidenceDir: "<evidence-dir>",
  sandboxValidated,
  preflightClear,
  dryRunReceipts: {
    rollbackPlanDryRun,
    hostSandboxRehearsalPassed,
    sameThreadDryRun,
    mcpCompatibilityPassed
  },
  liveReceipts: {
    backupReceiptObserved,
    rollbackReceiptObserved,
    sameThreadSmokePassed,
    routeLiveGateLoaded,
    routeLiveSmokeRequired,
    routeLiveSmokePassed,
    routeLiveExpectedRouteIDs,
    mcpHostRegistrationPassed
  },
  forwardedReadinessBlockers,
  receiptIDs,
  blockedBy: [...new Set(blockedBy)],
  notes: [
    "readiness external blockers and runway_check_skipped are forwarded here; a bundle cannot be promoted when external tests were skipped or runway evidence was omitted.",
    "mcpCompatibility/mcp-stdio is not the same as host MCP registration; hostRegistrationObserved must be true and receipt must be mcp-host-* for install.",
    "hostSandboxRehearsal proves the install recipe inside fake HOME/CODEX_HOME; it is not a live host install receipt.",
    "same-thread dry-run is not a live smoke receipt; run with explicit human/env confirmation on host.",
    "route-live-smoke-receipts.log is a separate per-route gate; risky routes need route-live-bundle-* before host evidence can be complete.",
    "backup and rollback receipts must come from confirmed local backup, not a plan."
  ],
  plainSummary: "Receipt bundle prepared from sandbox evidence. It intentionally does not allow host install until human, backup, live same-thread, host MCP registration, and rollback receipts are real."
};

console.log(JSON.stringify(report, null, 2));

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
  try { return fs.readFileSync(path.join(evidenceDir, file), "utf8"); }
  catch { return ""; }
}

function parseJSONDocument(file) {
  const text = read(file);
  const start = text.indexOf("{");
  if (start < 0) return null;
  try { return JSON.parse(text.slice(start)); }
  catch { return null; }
}

function parseFirstJSONDocument(files) {
  for (const file of files) {
    const parsed = parseJSONDocument(file);
    if (parsed) return parsed;
  }
  return null;
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
