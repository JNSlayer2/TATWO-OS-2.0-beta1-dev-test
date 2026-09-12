#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const receiptBundleScript = path.join(scriptDir, "tatwo-host-receipt-bundle.mjs");
const args = parseArgs(process.argv.slice(2));
const humanApprovalReceiptID = clean(args["human-approval"] ?? args["humanApprovalReceiptID"] ?? null);
const bundleResult = spawnSync("node", [receiptBundleScript, ...bundleArgs(args)], {
  cwd: repoRoot,
  encoding: "utf8",
  timeout: 120000,
  maxBuffer: 5 * 1024 * 1024
});

let bundle = null;
let bundleError = null;
try {
  const text = bundleResult.stdout ?? "";
  bundle = JSON.parse(text.slice(text.indexOf("{")));
} catch (error) {
  bundleError = "receipt_bundle_parse_failed";
}

const checks = [];
checks.push(check("receipt-bundle-loaded", bundleResult.status === 0 && bundle?.schema === "TatwoHostReceiptBundleV1", `exit=${bundleResult.status}`, "Evidence bundle must be readable."));
checks.push(check("receipt-bundle-complete", bundle?.hostInstallEvidenceComplete === true, String(bundle?.hostInstallEvidenceComplete), "Receipt bundle must declare complete host evidence; forwarded readiness blockers or dry-run evidence keep it closed."));
checks.push(check("sandbox-validated", bundle?.sandboxValidated === true, String(bundle?.sandboxValidated), "Sandbox readiness gate must have passed."));
checks.push(check("host-sandbox-rehearsal", hasPrefix(bundle?.receiptIDs?.hostSandboxRehearsal, "rehearsal-"), String(bundle?.receiptIDs?.hostSandboxRehearsal ?? null), "Host install must have passed fake HOME/CODEX_HOME rehearsal."));
checks.push(check("preflight-clear", bundle?.preflightClear === true, String(bundle?.preflightClear), "Read-only host preflight must have no critical/high unknowns."));
checks.push(check("human-approval", isHumanApprovalReceipt(humanApprovalReceiptID), String(Boolean(humanApprovalReceiptID)), "Human approval receipt must be explicit and safe, e.g. human-20260622-scope."));
checks.push(check("backup-receipt", hasPrefix(bundle?.receiptIDs?.backup, "backup-"), String(bundle?.receiptIDs?.backup ?? null), "Backup receipt must come from confirmed backup evidence, not a plan."));
checks.push(check("rollback-receipt", hasPrefix(bundle?.receiptIDs?.rollback, "rollback-"), String(bundle?.receiptIDs?.rollback ?? null), "Rollback receipt must validate required backup files."));
checks.push(check("same-thread-live-smoke", hasPrefix(bundle?.receiptIDs?.sameThreadSmoke, "same-thread-"), String(bundle?.receiptIDs?.sameThreadSmoke ?? null), "Live same-thread gateway smoke must pass; dry-run is not enough."));
checks.push(check("route-live-smoke-receipts", !bundle?.liveReceipts?.routeLiveSmokeRequired || hasPrefix(bundle?.receiptIDs?.routeLiveSmoke, "route-live-bundle-"), String(bundle?.receiptIDs?.routeLiveSmoke ?? null), "Every risky route must have a host-live route receipt bundle with response.completed and continuity back to gpt-5.5; gateway health or model text is not enough."));
checks.push(check("host-mcp-registration", hasPrefix(bundle?.receiptIDs?.mcpRegistrationSmoke, "mcp-host-"), String(bundle?.receiptIDs?.mcpRegistrationSmoke ?? null), "MCP receipt must prove Codex host registration, not only stdio compatibility."));
checks.push(check("no-host-mutation-by-gate", true, "hostMutationPerformed=false", "This verified gate is read-only and never mutates host state."));

const failed = checks.filter(item => !item.passed).map(item => item.id);
const blockedBy = [
  ...(bundleError ? [bundleError] : []),
  ...failed.map(id => `check_failed:${id}`),
  ...(bundle?.blockedBy ?? []).filter(id => id !== "human_approval_required" || !isHumanApprovalReceipt(humanApprovalReceiptID))
];
const hostInstallAllowed = failed.length === 0 && !bundleError;

const report = {
  schema: "TatwoVerifiedHostInstallGateV1",
  hostMutationAllowed: false,
  hostMutationPerformed: false,
  hostInstallAllowed,
  evidenceDir: bundle?.evidenceDir ?? "<unknown>",
  bundleStatus: bundle?.status ?? "unavailable",
  checks,
  failedCheckIDs: failed,
  blockedBy: [...new Set(blockedBy)],
  receiptIDs: {
    sandboxValidated: bundle?.receiptIDs?.sandboxValidated ?? null,
    hostSandboxRehearsal: bundle?.receiptIDs?.hostSandboxRehearsal ?? null,
    preflightClear: bundle?.receiptIDs?.preflightClear ?? null,
    humanApproval: isHumanApprovalReceipt(humanApprovalReceiptID) ? humanApprovalReceiptID : null,
    backup: bundle?.receiptIDs?.backup ?? null,
    rollback: bundle?.receiptIDs?.rollback ?? null,
    sameThreadSmoke: bundle?.receiptIDs?.sameThreadSmoke ?? null,
    routeLiveSmoke: bundle?.receiptIDs?.routeLiveSmoke ?? null,
    mcpRegistrationSmoke: bundle?.receiptIDs?.mcpRegistrationSmoke ?? null
  },
  nextActions: hostInstallAllowed
    ? [
        "Proceed only to the already approved host installer step; this gate itself did not mutate host state.",
        "Immediately rerun doctor, same-thread smoke, and host MCP registration smoke after install.",
        "Keep backup and rollback receipts local-only."
      ]
    : [
        "Stay in sandbox/dry-run mode.",
        "Collect real backup, rollback, live same-thread, and host MCP registration receipts before host install.",
        "Collect route-live-bundle-* when route-risk-dashboard lists risky routes.",
        "Do not use mcp-stdio receipts as host registration proof."
      ],
  plainSummary: hostInstallAllowed
    ? "Evidence-backed gate passed. This means the real evidence bundle contains every required receipt; the gate still did not modify host state."
    : "Evidence-backed gate blocked host install. Missing or dry-run evidence cannot be promoted into a real host install decision.",
  generatedAt: new Date().toISOString()
};

console.log(JSON.stringify(report, null, 2));
process.exit(hostInstallAllowed ? 0 : 2);

function bundleArgs(parsed) {
  if (parsed["evidence-dir"]) return ["--evidence-dir", String(parsed["evidence-dir"]), "--json"];
  if (parsed.latest) return ["--latest", "--json"];
  if (parsed._.length > 0) return [String(parsed._[0]), "--json"];
  return ["--latest", "--json"];
}

function check(id, passed, observed, description) {
  return { id, passed: Boolean(passed), observed, description };
}

function clean(value) {
  if (!value) return null;
  return String(value).trim().replace(/\/Users\/[\S]+|\/Volumes\/[\S]+|auth\.json|sk-[A-Za-z0-9_-]+|Bearer [A-Za-z0-9._-]+/g, "<redacted>");
}

function hasPrefix(value, prefix) {
  return typeof value === "string" && value.startsWith(prefix) && /^[a-z-]+[a-f0-9]{12,}$/.test(value);
}

function isHumanApprovalReceipt(value) {
  return typeof value === "string"
    && /^(human|approval)-[A-Za-z0-9._-]{4,90}$/.test(value)
    && !/(auth|token|secret|sk-|bearer|\/Users\/|\/Volumes\/)/i.test(value);
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
