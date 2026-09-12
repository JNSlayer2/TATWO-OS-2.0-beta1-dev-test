#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const args = parseArgs(process.argv.slice(2));
const humanApproval = clean(args["human-approval"] ?? args.humanApprovalReceiptID ?? null);

const evidenceArgs = evidenceSelectorArgs(args);
const readinessArgs = [...evidenceArgs, "--skip-runway-check"];
const readiness = runNode("tatwo-host-readiness-gate.mjs", readinessArgs, { allowFailure: true });
const bundle = runNode("tatwo-host-receipt-bundle.mjs", evidenceArgs, { allowFailure: true });
const verifiedArgs = [...evidenceArgs, "--json"];
if (humanApproval) verifiedArgs.push("--human-approval", humanApproval);
const verified = runNode("tatwo-host-install-verified-gate.mjs", verifiedArgs, { allowFailure: true });

const readinessData = readiness.data;
const bundleData = bundle.data;
const verifiedData = verified.data;
const sandboxReady = readinessData?.schema === "TatwoHostReadinessGateV1" && readinessData.status === "passed" && readinessData.sandboxValidated === true;
const evidenceAvailable = Boolean(readinessData?.schema || bundleData?.schema);
const preflightClear = bundleData?.preflightClear === true;
const rehearsalReady = bundleData?.dryRunReceipts?.hostSandboxRehearsalPassed === true;
const backupReady = bundleData?.liveReceipts?.backupReceiptObserved === true;
const rollbackReady = bundleData?.liveReceipts?.rollbackReceiptObserved === true;
const sameThreadReady = bundleData?.liveReceipts?.sameThreadSmokePassed === true;
const mcpHostReady = bundleData?.liveReceipts?.mcpHostRegistrationPassed === true;
const humanReady = isHumanApprovalReceipt(humanApproval);
const verifiedReady = verifiedData?.hostInstallAllowed === true;

const currentPhase = !evidenceAvailable
  ? "needs_sandbox_check"
  : (!sandboxReady ? "sandbox_not_ready" : (verifiedReady ? "ready_for_approved_host_install" : "sandbox_ready_host_blocked"));

const missingReceipts = unique([
  ...(sandboxReady ? [] : ["sandbox evidence bundle"]),
  ...(preflightClear ? [] : ["preflight-clear receipt"]),
  ...(rehearsalReady ? [] : ["host sandbox rehearsal receipt"]),
  ...(humanReady ? [] : ["human approval receipt"]),
  ...(backupReady ? [] : ["host backup receipt"]),
  ...(rollbackReady ? [] : ["rollback receipt"]),
  ...(sameThreadReady ? [] : ["live same-thread smoke receipt"]),
  ...(mcpHostReady ? [] : ["mcp-host registration receipt"])
]);

const stageStatuses = [
  stage("workflow-core", "工作流核心", "環境穩定團隊 + Codex executor", sandboxReady, "Swift/build/MCP/team loop/sandbox readiness evidence is complete.", "bash scripts/tatwo-ultrawork-sandbox-check.sh"),
  stage("host-readonly-preflight", "只讀主機盤點", "環境穩定團隊", preflightClear, "No critical/high unknown remains in read-only host preflight.", "node scripts/tatwo-host-preflight.mjs --json"),
  stage("host-sandbox-rehearsal", "假 HOME 實裝演練", "環境穩定團隊", rehearsalReady, "Fake HOME/CODEX_HOME install rehearsal, MCP stdio smoke, backup hash, and rollback are proven without touching host.", "node scripts/tatwo-host-sandbox-rehearsal.mjs --json"),
  stage("human-approval", "人工授權", "Human + Codex executor", humanReady, "Human explicitly approves the host-install scope and understands backup/rollback requirements.", "node scripts/tatwo-host-install-verified-gate.mjs --latest --human-approval human-YYYYMMDD-scope --json"),
  stage("host-backup", "主機備份", "Human + Codex executor", backupReady, "Confirmed local backup exists for Codex config/state/cache and excludes auth/session material.", "TATWO_HOST_BACKUP_CONFIRM=1 node scripts/tatwo-host-backup-plan.mjs --confirm --json"),
  stage("rollback-validation", "回滾驗證", "Human + Codex executor", rollbackReady, "Rollback plan observed required backup files and produced rollback-* receipt.", "node scripts/tatwo-host-rollback-plan.mjs --backup-dir <backup-dir> --json"),
  stage("live-same-thread-smoke", "同 thread 多模型 smoke", "環境穩定團隊", sameThreadReady, "Gateway/Codex same-thread switching is proven live; dry-run is not enough.", "TATWO_HOST_SAME_THREAD_SMOKE=1 node scripts/tatwo-host-same-thread-smoke.mjs --run --gateway-dir <gateway-dir> --json"),
  stage("host-mcp-registration", "Host MCP 註冊 smoke", "環境穩定團隊", mcpHostReady, "Codex host config registration is observed read-only and receipt starts with mcp-host-*.", "node scripts/tatwo-host-mcp-registration-smoke.mjs --expect-host-registration --host-config \"$HOME/.codex/config.toml\" --json"),
  stage("verified-install-gate", "實裝前最後閘門", "Opus 5 judge + Codex executor", verifiedReady, "Evidence-backed gate accepts only real receipts and never mutates host itself.", "node scripts/tatwo-host-install-verified-gate.mjs --latest --human-approval human-YYYYMMDD-scope --json")
];

const report = {
  schema: "TatwoHostInstallRunwayV1",
  generatedAt: new Date().toISOString(),
  currentPhase,
  uiDeferred: true,
  hostMutationAllowed: false,
  hostMutationPerformed: false,
  hostInstallAllowed: false,
  sandboxReady,
  verifiedGatePassed: verifiedReady,
  evidenceDir: sanitizeEvidenceDir(readinessData?.evidenceDir ?? bundleData?.evidenceDir ?? verifiedData?.evidenceDir ?? null),
  stageStatuses,
  missingReceipts,
  teamOwners: [
    { team: "環境穩定團隊", responsibility: "preflight、sandbox rehearsal、same-thread smoke、MCP host registration、disconnect risk gate" },
    { team: "總控團隊", responsibility: "把實裝任務拆成收據，不讓 UI 或模型意見繞過 gate" },
    { team: "代碼團隊", responsibility: "CLI/MCP/script 落地與測試；Codex 是唯一 executor" },
    { team: "Opus 5 judge", responsibility: "只根據 evidence bundle 裁決，不替代 smoke/test" },
    { team: "Human + Codex executor", responsibility: "只有人工批准後才可做 backup/install/rollback 這類 host 動作" }
  ],
  safeNextCommands: safeNextCommands(currentPhase),
  deniedActions: [
    "no signed Codex App bundle patch",
    "no real LaunchAgent write/load/unload during sandbox",
    "no ~/.codex config/state/cache writes before human approval and backup",
    "no auth/session/token/raw log/private path in receipts",
    "no mcp-stdio receipt promoted to mcp-host registration",
    "no UI work until workflow runway remains green"
  ],
  disconnectProtections: [
    "single model_gateway provider; same thread switches model only",
    "semantic response.in_progress for long external-model waits",
    "clean 413 for oversized gateway bodies instead of socket reset",
    "Codex app-server/proxy binary must match Codex.app bundle",
    "auth.json single source to avoid refresh-token races",
    "models_cache is recoverable cache, not source of truth",
    "rollback receipt required before host install"
  ],
  upstreamStatus: {
    readinessExit: readiness.status,
    receiptBundleExit: bundle.status,
    verifiedGateExit: verified.status,
    verifiedGateFailedCheckIDs: verifiedData?.failedCheckIDs ?? null,
    receiptBlockedBy: bundleData?.blockedBy ?? null
  },
  plainSummary: summaryFor(currentPhase, missingReceipts)
};

console.log(JSON.stringify(report, null, 2));
process.exit(currentPhase === "sandbox_not_ready" || currentPhase === "needs_sandbox_check" ? 1 : 0);

function stage(id, title, ownerTeam, passed, proves, command) {
  return {
    id,
    title,
    ownerTeam,
    status: passed ? "passed" : "blocked",
    hostMutationAllowed: false,
    proves,
    command,
    passRule: "Only evidence receipts count; model opinion is not enough."
  };
}

function safeNextCommands(phase) {
  if (phase === "needs_sandbox_check" || phase === "sandbox_not_ready") {
    return [
      "MODEL_GATEWAY_DIR=<gateway-dir> OPEN_ULTRAWORK_DIR=<open-ultrawork-dir> bash scripts/tatwo-ultrawork-sandbox-check.sh",
      "node scripts/tatwo-host-readiness-gate.mjs --latest",
      "node scripts/tatwo-host-install-runway.mjs --latest --json"
    ];
  }
  if (phase === "ready_for_approved_host_install") {
    return [
      "Run only the already-approved host installer step; this runway did not mutate host.",
      "Immediately rerun doctor, same-thread smoke, MCP registration smoke, and rollback gate.",
      "If any smoke fails, rollback from the backup receipt."
    ];
  }
  return [
    "Stay in sandbox/dry-run mode.",
    "Ask human approval only after reviewing this runway and backup/rollback scope.",
    "TATWO_HOST_BACKUP_CONFIRM=1 node scripts/tatwo-host-backup-plan.mjs --confirm --json",
    "node scripts/tatwo-host-rollback-plan.mjs --backup-dir <backup-dir> --json",
    "TATWO_HOST_SAME_THREAD_SMOKE=1 node scripts/tatwo-host-same-thread-smoke.mjs --run --gateway-dir <gateway-dir> --json",
    "node scripts/tatwo-host-mcp-registration-smoke.mjs --expect-host-registration --host-config \"$HOME/.codex/config.toml\" --json",
    "node scripts/tatwo-host-install-verified-gate.mjs --latest --human-approval human-YYYYMMDD-scope --json"
  ];
}

function summaryFor(phase, missing) {
  if (phase === "needs_sandbox_check") return "No sandbox evidence is available. Run the sandbox check before discussing host install.";
  if (phase === "sandbox_not_ready") return "Sandbox evidence is incomplete or failed. Do not install into the host.";
  if (phase === "ready_for_approved_host_install") return "All required evidence is present and verified. This runway still did not mutate host state; proceed only through the approved installer step.";
  return `Workflow runway is healthy, but host install remains blocked by: ${missing.join(", ")}. This is expected before real host backup/smoke receipts exist.`;
}

function runNode(scriptName, scriptArgs, opts = {}) {
  const result = spawnSync("node", [path.join(scriptDir, scriptName), ...scriptArgs], {
    cwd: repoRoot,
    encoding: "utf8",
    timeout: 120000,
    maxBuffer: 10 * 1024 * 1024
  });
  const text = (result.stdout || result.stderr || "").trim();
  let data = null;
  try {
    const start = text.indexOf("{");
    if (start >= 0) data = JSON.parse(text.slice(start));
  } catch {
    data = null;
  }
  if (!opts.allowFailure && result.status !== 0) {
    throw new Error(`${scriptName} failed: ${text.slice(0, 500)}`);
  }
  return { status: result.status, data, text };
}

function evidenceSelectorArgs(parsed) {
  if (parsed["evidence-dir"]) return ["--evidence-dir", String(parsed["evidence-dir"]), "--json"];
  if (parsed.latest || parsed._.length === 0) return ["--latest", "--json"];
  return [String(parsed._[0]), "--json"];
}

function clean(value) {
  if (!value) return null;
  return String(value).trim().replace(/\/Users\/\S+|\/Volumes\/\S+|auth\.json|sk-[A-Za-z0-9_-]+|Bearer [A-Za-z0-9._-]+/g, "<redacted>");
}

function isHumanApprovalReceipt(value) {
  return typeof value === "string"
    && /^(human|approval)-[A-Za-z0-9._-]{4,90}$/.test(value)
    && !/(auth|token|secret|sk-|bearer|\/Users\/|\/Volumes\/)/i.test(value);
}

function sanitizeEvidenceDir(value) {
  if (!value) return null;
  return String(value).includes(".tatwo-ultrawork/evidence") ? "<evidence-dir>" : clean(value);
}

function unique(values) {
  return [...new Set(values)];
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
