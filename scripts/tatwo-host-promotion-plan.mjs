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
    schema: "TatwoHostPromotionPlanV1",
    status: "blocked",
    currentPhase: "needs_sandbox_check",
    uiDeferred: true,
    hostMutationAllowed: false,
    hostMutationPerformed: false,
    hostInstallAllowed: false,
    evidenceDir: null,
    connectionStrategy: strategy(),
    routeRiskTriage: {
      status: "blocked",
      observed: "no_evidence_bundle",
      routeErrorVisible: false,
      routeErrors: [],
      routesWithoutLastOK: [],
      requiredBeforePromotion: ["sandbox evidence bundle", "read-only host preflight"]
    },
    phasePlan: phases(),
    circuitBreakers: circuitBreakers(),
    teamOwners: teamOwners(),
    blockedBy: ["sandbox_evidence_missing"],
    nextSafeCommands: ["MODEL_GATEWAY_DIR=<gateway-dir> OPEN_ULTRAWORK_DIR=<open-ultrawork-dir> bash scripts/tatwo-ultrawork-sandbox-check.sh"],
    deniedActions: deniedActions(),
    plainSummary: "No sandbox evidence exists. Do not connect Tatwo to the host yet.",
    generatedAt: new Date().toISOString()
  });
  process.exit(1);
}

const runway = parseJSONDocument("host-install-runway-final.log") ?? parseJSONDocument("host-install-runway.log");
const bundle = parseJSONDocument("host-receipt-bundle.log");
const preflight = parseJSONDocument("host-preflight-live.log");
const readiness = parseJSONDocument("host-readiness-gate.log");
const verified = parseJSONDocument("host-install-verified-gate.log");
const mcpStdio = parseJSONDocument("host-mcp-registration-smoke.log");
const routeTriage = buildRouteTriage(preflight);
const sandboxReady = readiness?.schema === "TatwoHostReadinessGateV1" && readiness.status === "passed" && readiness.sandboxValidated === true;
const missingReceipts = Array.isArray(runway?.missingReceipts) ? runway.missingReceipts : [];
const hardBlockers = unique([
  ...(sandboxReady ? [] : ["sandbox_readiness_not_passed"]),
  ...routeTriage.blockedBy,
  ...missingReceipts.map(receiptBlocker).filter(Boolean),
  ...(bundle?.blockedBy ?? []),
  ...(verified?.blockedBy ?? []),
  ...(mcpStdio?.hostRegistrationObserved === false ? ["mcp_stdio_is_not_host_registration"] : [])
]);

const report = {
  schema: "TatwoHostPromotionPlanV1",
  status: sandboxReady ? "ready_to_collect_host_receipts" : "blocked",
  currentPhase: runway?.currentPhase ?? (sandboxReady ? "sandbox_ready_host_blocked" : "sandbox_not_ready"),
  uiDeferred: true,
  hostMutationAllowed: false,
  hostMutationPerformed: false,
  hostInstallAllowed: false,
  evidenceDir: sanitizeEvidenceDir(evidenceDir),
  connectionStrategy: strategy(),
  routeRiskTriage: routeTriage,
  phasePlan: phases(),
  circuitBreakers: circuitBreakers(),
  teamOwners: teamOwners(),
  evidenceSummary: {
    readinessStatus: readiness?.status ?? null,
    sandboxValidated: readiness?.sandboxValidated === true,
    runwayPhase: runway?.currentPhase ?? null,
    receiptBundleComplete: bundle?.hostInstallEvidenceComplete === true,
    verifiedGateAllowed: verified?.hostInstallAllowed === true,
    mcpHostRegistrationObserved: mcpStdio?.hostRegistrationObserved === true,
    liveSameThreadObserved: bundle?.liveReceipts?.sameThreadSmokePassed === true
  },
  blockedBy: hardBlockers,
  nextSafeCommands: nextSafeCommands(sandboxReady, routeTriage),
  deniedActions: deniedActions(),
  plainSummary: summary(sandboxReady, hardBlockers, routeTriage),
  generatedAt: new Date().toISOString()
};

emit(report);
process.exit(sandboxReady ? 0 : 1);

function strategy() {
  return [
    {
      id: "keep-single-gateway-provider",
      title: "保留單一 model_gateway provider",
      plainRule: "Codex App 只接 model_gateway；Tatwo Ultrawork 是外層協作模式，不建立 opus/grok/minimax 各自 provider。",
      protectsAgainst: "同 thread 斷層、sidebar provider split、模型切換後工具狀態遺失",
      evidence: ["host-preflight-live.log codex-model-provider-single-gateway", "gateway same-thread smoke"]
    },
    {
      id: "mcp-wrapper-not-bundle-patch",
      title: "用 App/MCP/CLI 包住核心，不 patch Codex App",
      plainRule: "Tatwo 可以安裝 CLI、App、MCP entry；不得修改 signed Codex App bundle 或 renderer。",
      protectsAgainst: "Codex repair、簽章壞掉、更新後整台不穩",
      evidence: ["host MCP registration receipt", "codesign unchanged by Tatwo policy"]
    },
    {
      id: "sandbox-before-host",
      title: "沙盒先通過才進主機",
      plainRule: "工作流、MCP stdio、fake HOME backup/rollback 都先過；但 dry-run 不能冒充 live host。",
      protectsAgainst: "裝了就崩、回不去、stdio-only 假成功",
      evidence: ["host-sandbox-rehearsal.log", "host-readiness-gate.log", "host-install-verified-gate.log"]
    },
    {
      id: "ui-last-data-first",
      title: "UI 最後才接，且只讀這些資料源",
      plainRule: "上方工作列 UI 只顯示 model traits、team dashboard、runway、receipt bundle、objective audit；不得用 UI 假裝完成。",
      protectsAgainst: "漂亮 dashboard 蓋掉未完成的 host receipts",
      evidence: ["team-dashboard.log", "host-promotion-plan.log", "objective-audit.log"]
    }
  ];
}

function phases() {
  return [
    phase("workflow-core", "工作流核心與團隊分工", "總控團隊 + 代碼團隊", false, "swift test/build、teams dashboard、team loop、MCP smoke、objective adversarial", "bash scripts/tatwo-ultrawork-sandbox-check.sh", "sandbox readiness passed"),
    phase("readonly-host-preflight", "只讀主機盤點", "環境穩定團隊", false, "Codex App/CLI、model_gateway、route error state、fast、auto-compact、app-server source", "node scripts/tatwo-host-preflight.mjs --json", "critical/high unknown clear and route risk visible"),
    phase("fake-home-rehearsal", "fake HOME 實裝演練", "環境穩定團隊", false, "備份、MCP config mutation、stdio smoke、rollback hash 都只在 fake HOME", "node scripts/tatwo-host-sandbox-rehearsal.mjs --json", "realHostMutationPerformed=false and rollbackValidated=true"),
    phase("approval-and-backup", "人工授權與備份", "Human + Codex executor", false, "明確 scope、備份 config/state/cache、不備份 auth/session", "TATWO_HOST_BACKUP_CONFIRM=1 node scripts/tatwo-host-backup-plan.mjs --confirm --json", "backup-* receipt and rollback-* receipt exist"),
    phase("live-same-thread", "live 同 thread 多模型 smoke", "環境穩定團隊", false, "GPT → 外部模型 → GPT 在同一 thread；必須 response.completed，不接受 partial/disconnected", "TATWO_HOST_SAME_THREAD_SMOKE=1 node scripts/tatwo-host-same-thread-smoke.mjs --run --gateway-dir <gateway-dir> --json", "same-thread-* receipt passed and stale route state cleared or explained"),
    phase("host-mcp-registration", "Codex host MCP 註冊 smoke", "環境穩定團隊", false, "只讀觀測 Codex host config 有 Tatwo MCP entry，再跑 tools/list/call", "node scripts/tatwo-host-mcp-registration-smoke.mjs --expect-host-registration --host-config \"$HOME/.codex/config.toml\" --json", "mcp-host-* receipt and hostRegistrationObserved=true"),
    phase("verified-host-gate", "證據型最後 gate", "Opus 5 judge + Codex executor", false, "只讀 evidence bundle；缺真收據就擋", "node scripts/tatwo-host-install-verified-gate.mjs --latest --human-approval human-YYYYMMDD-scope --json", "hostInstallAllowed=true but this script still does not mutate host"),
    phase("menu-bar-ui", "上方工作列 UI 接線", "設計團隊 + 代碼團隊", false, "只接已驗證資料源：usage、mode、scenario、teams、plugin registry、workflow visualizer、runway", "deferred until workflow/runway remains green", "screenshot/hash/visual checklist before UI pass")
  ];
}

function phase(id, title, ownerTeam, mayMutateHost, requiredEvidence, command, doneCondition) {
  return {
    id,
    title,
    ownerTeam,
    mayMutateHost,
    command,
    requiredEvidence,
    doneCondition,
    passRule: "Only receipts and tool traces count; model text cannot pass this phase."
  };
}

function circuitBreakers() {
  return [
    breaker("stream-disconnect", "Codex reconnect / stream disconnected / retry storm", "stop_host_promotion", "Run disconnect guard; do not install until response.completed smoke passes."),
    breaker("partial-stream", "Only response.in_progress or output_text.delta without response.completed", "reject_receipt", "Operational receipt validator marks partial_stream_cannot_pass."),
    breaker("route-error-state", "routes_with_errors or important routes without last_ok", "require_live_smoke_or_explanation", "Live same-thread smoke must clear or explicitly explain each route."),
    breaker("provider-split", "model_provider is not model_gateway or per-model providers appear", "stop_host_promotion", "Keep one provider; do not split opus/grok/minimax providers."),
    breaker("app-server-mismatch", "app-server/proxy comes from non-Codex.app binary", "stop_host_promotion", "Do not kill automatically in sandbox; require read-only finding plus approved repair."),
    breaker("auth-race", "multiple auth.json copies or token invalidated/free-plan mismatch", "stop_and_reauth_manually", "Do not read tokens; require human login/repair and post-update check."),
    breaker("mcp-stdio-only", "MCP stdio smoke passed but hostRegistrationObserved=false", "do_not_promote", "Need mcp-host-* receipt from host config observation."),
    breaker("ui-self-pass", "GPT says UI looks fine without screenshot/hash", "reject_ui_pass", "Design team visual gate is required.")
  ];
}

function breaker(id, symptom, action, verification) {
  return { id, symptom, action, verification };
}

function teamOwners() {
  return [
    { team: "總控團隊", owns: ["scope", "mode choice", "team split", "UI deferred rule"] },
    { team: "環境穩定團隊", owns: ["preflight", "disconnect guard", "same-thread smoke", "MCP host registration", "route risk triage"] },
    { team: "代碼團隊", owns: ["CLI/MCP/scripts", "Swift/Node tests", "minimal patching"] },
    { team: "設計團隊", owns: ["later menu-bar UI", "screenshot/hash/visual checklist", "visual judge handoff"] },
    { team: "Opus 5 judge", owns: ["fail-closed review of evidence bundle", "not a replacement for smoke/test"] },
    { team: "Human + Codex executor", owns: ["approval", "backup", "rollback", "actual host mutation if ever allowed"] }
  ];
}

function buildRouteTriage(preflight) {
  const checks = Array.isArray(preflight?.checks) ? preflight.checks : [];
  const route = checks.find(item => item?.id === "gateway-route-error-state");
  const observed = String(route?.observed ?? "route_state_missing");
  const routeErrors = parseListAfter(observed, "routes_with_errors=").filter(item => item !== "none");
  const withoutLastOK = parseListAfter(observed, "without_last_ok=").filter(item => item !== "none");
  const visible = route?.status === "installed";
  const blockedBy = [
    ...(visible ? [] : ["gateway_route_state_not_observed"]),
    ...(routeErrors.length > 0 ? ["gateway_route_errors_need_live_smoke"] : []),
    ...(withoutLastOK.length > 0 ? ["gateway_routes_without_last_ok_need_live_smoke"] : [])
  ];
  return {
    status: visible ? (blockedBy.length ? "needs_live_smoke" : "observed_clean") : "blocked",
    observed: sanitize(observed),
    routeErrorVisible: visible,
    routeErrors,
    routesWithoutLastOK: withoutLastOK,
    blockedBy,
    requiredBeforePromotion: blockedBy.length
      ? ["live same-thread smoke", "route-specific completed response", "explicit explanation for stale route errors"]
      : ["still run live same-thread smoke before host install"]
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

function nextSafeCommands(sandboxReady, routeTriage) {
  if (!sandboxReady) {
    return [
      "MODEL_GATEWAY_DIR=<gateway-dir> OPEN_ULTRAWORK_DIR=<open-ultrawork-dir> bash scripts/tatwo-ultrawork-sandbox-check.sh",
      "node scripts/tatwo-host-readiness-gate.mjs --latest --json"
    ];
  }
  return [
    "Stay in sandbox/dry-run mode unless the user explicitly approves host-install scope.",
    "Inspect route risk dashboard first: node scripts/tatwo-route-risk-dashboard.mjs --latest --json",
    "Review route risk first: " + routeTriage.requiredBeforePromotion.join("; "),
    "TATWO_HOST_BACKUP_CONFIRM=1 node scripts/tatwo-host-backup-plan.mjs --confirm --json",
    "node scripts/tatwo-host-rollback-plan.mjs --backup-dir <backup-dir> --json",
    "TATWO_HOST_SAME_THREAD_SMOKE=1 node scripts/tatwo-host-same-thread-smoke.mjs --run --gateway-dir <gateway-dir> --json",
    "node scripts/tatwo-host-mcp-registration-smoke.mjs --expect-host-registration --host-config \"$HOME/.codex/config.toml\" --json",
    "node scripts/tatwo-host-install-verified-gate.mjs --latest --human-approval human-YYYYMMDD-scope --json"
  ];
}

function deniedActions() {
  return [
    "no UI work before workflow/runway stays green",
    "no signed Codex App bundle patch",
    "no per-model provider split",
    "no LaunchAgent write/load/unload during sandbox",
    "no ~/.codex config/state/cache write before human approval plus backup",
    "no auth/session/token/raw log/private path in receipts",
    "no route error hidden behind green gateway health",
    "no mcp-stdio or dry-run promotion to host receipt"
  ];
}

function summary(sandboxReady, blockers, routeTriage) {
  if (!sandboxReady) return "Host promotion is blocked because sandbox readiness is not proven.";
  if (routeTriage.blockedBy.length > 0) return `Workflow runway is healthy, but route risk still needs live smoke/explanation: ${routeTriage.blockedBy.join(", ")}. UI remains deferred.`;
  return `Workflow runway is healthy, but host promotion is still blocked by required live receipts: ${blockers.join(", ")}. UI remains deferred.`;
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
    } catch { return null; }
  }
  return path.resolve(String(parsed._[0]));
}

function read(name) {
  try { return fs.readFileSync(path.join(evidenceDir, name), "utf8"); }
  catch { return ""; }
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
  const source = String(text ?? "");
  const start = source.indexOf("{");
  if (start < 0) return null;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < source.length; i += 1) {
    const ch = source[i];
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
      if (depth === 0) return source.slice(start, i + 1);
    }
  }
  return null;
}

function sanitizeEvidenceDir(value) {
  if (!value) return null;
  return String(value).includes(".tatwo-ultrawork/evidence") ? "<evidence-dir>" : sanitize(value);
}

function sanitize(value) {
  return String(value ?? "")
    .replace(/\/Users\/[^\s"']+/g, "<redacted-path>")
    .replace(/\/Volumes\/[^\s"']+/g, "<redacted-path>")
    .replace(/sk-[A-Za-z0-9_-]+/g, "<redacted-token>")
    .replace(/Bearer [A-Za-z0-9._-]+/g, "Bearer <redacted>");
}

function unique(values) { return [...new Set(values.filter(Boolean))]; }

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

function emit(report) { console.log(JSON.stringify(report, null, 2)); }
