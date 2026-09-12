#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const evidenceRoot = path.join(repoRoot, ".tatwo-ultrawork", "evidence");
const args = parseArgs(process.argv.slice(2));
const evidenceDir = resolveEvidenceDir(args);

if (!evidenceDir || !fs.existsSync(evidenceDir)) {
  emit({
    schema: "TatwoRouteSmokePlanV1",
    status: "needs_sandbox_evidence",
    uiDeferred: true,
    hostMutationAllowed: false,
    hostMutationPerformed: false,
    hostInstallAllowed: false,
    evidenceDir: null,
    sourceFiles: [],
    ownerTeam: "環境穩定團隊",
    routeSmokeQueue: [],
    baselineSameThreadSmoke: {
      title: "全路線 baseline smoke",
      ownerTeam: "環境穩定團隊",
      requiredProof: [
        "live same-thread smoke",
        "response.completed",
        "same thread continuity back to gpt-5.5"
      ],
      canStartUIAfterThisAlone: false,
      canInstallHostAfterThisAlone: false
    },
    requiredBeforePromotion: [
      "sandbox evidence bundle",
      "route risk dashboard",
      "live same-thread smoke",
      "route-specific response.completed"
    ],
    blockedBy: ["sandbox_evidence_missing", "route_risk_dashboard_missing"],
    plainSummary: "還沒有沙盒證據；不能規劃 route live smoke。即使之後 route 乾淨，仍要 live same-thread smoke 與 response.completed，不能開始 UI 或主機實裝。",
    generatedAt: new Date().toISOString()
  });
  process.exit(1);
}

const dashboard = parseJSONDocument("route-risk-dashboard.log");
const preflight = parseJSONDocument("host-preflight-live.log");
const liveRouteLists = routeListsFromPreflight(preflight);
const sourceRiskIDs = unique([
  ...((Array.isArray(dashboard?.riskyRoutes) ? dashboard.riskyRoutes : []).map(item => item?.modelID).filter(Boolean)),
  ...liveRouteLists.routeErrors.map(item => String(item).split(":")[0]).filter(Boolean),
  ...liveRouteLists.routesWithoutLastOK
]);
const riskByID = new Map((Array.isArray(dashboard?.riskyRoutes) ? dashboard.riskyRoutes : []).map(route => [route.modelID, route]));
const queue = sourceRiskIDs.map((modelID, index) => routeSmokeItem(modelID, riskByID.get(modelID), index));
const blockedBy = unique([
  ...(dashboard?.schema === "TatwoRouteRiskDashboardV1" ? [] : ["route_risk_dashboard_missing"]),
  ...(queue.length > 0 ? ["route_smoke_live_receipts_missing"] : []),
  ...(Array.isArray(dashboard?.blockedBy) ? dashboard.blockedBy : []),
  "human_approval_required_before_host_live_smoke",
  "host_backup_not_observed_before_route_smoke"
]);

const report = {
  schema: "TatwoRouteSmokePlanV1",
  status: queue.length > 0 ? "needs_route_live_smoke" : "no_route_risks_observed_still_requires_same_thread_baseline",
  uiDeferred: true,
  hostMutationAllowed: false,
  hostMutationPerformed: false,
  hostInstallAllowed: false,
  evidenceDir: sanitizeEvidenceDir(evidenceDir),
  sourceFiles: [
    ...(dashboard?.schema ? ["route-risk-dashboard.log"] : []),
    ...(preflight?.schema ? ["host-preflight-live.log"] : [])
  ],
  ownerTeam: "環境穩定團隊",
  routeSmokeQueue: queue,
  baselineSameThreadSmoke: {
    title: "全路線 baseline smoke",
    ownerTeam: "環境穩定團隊",
    command: "TATWO_HOST_SAME_THREAD_SMOKE=1 node scripts/tatwo-host-same-thread-smoke.mjs --run --gateway-dir <gateway-dir> --json",
    mustSee: [
      "sameThreadSmokeExecuted=true",
      "passed=true",
      "response.completed or equivalent completed proof from gateway post-update-check",
      "no retry storm / no disconnected terminal state"
    ],
    doesNotProve: [
      "host MCP registration",
      "backup exists",
      "UI quality",
      "route-specific pass if the output does not mention the route or completed terminal event"
    ]
  },
  smokeOrder: [
    "先保留 UI deferred，不做上方工作列 UI。",
    "先做只讀 preflight，確認仍是單一 model_gateway provider。",
    "人工批准後先備份 Codex config/state/cache，再跑 live same-thread smoke。",
    "每條 risky route 必須看到 route-specific response.completed 或留下 stale-error explanation。",
    "若任一路線 timeout/disconnect/partial/retry storm，停止實裝，回到環境穩定團隊修 route，不准用模型文字放行。"
  ],
  passRules: [
    "gateway overall health 綠不等於 route 通過。",
    "mcp-stdio-* 不等於 Codex host MCP 註冊。",
    "partial stream / response.in_progress 只能代表還在跑，不能代表完成。",
    "response.completed 才能當 route 完成證據。",
    "同 thread 必須回到 GPT baseline，確認上下文沒有因 provider split 斷掉。"
  ],
  safeNextCommands: [
    "node scripts/tatwo-route-risk-dashboard.mjs --latest --json",
    "node scripts/tatwo-route-smoke-plan.mjs --latest --json",
    "node scripts/tatwo-host-backup-plan.mjs --dry-run --json",
    "TATWO_HOST_SAME_THREAD_SMOKE=1 node scripts/tatwo-host-same-thread-smoke.mjs --run --gateway-dir <gateway-dir> --json",
    "node scripts/tatwo-host-receipt-bundle.mjs --latest --json",
    "node scripts/tatwo-host-install-verified-gate.mjs --latest --human-approval human-YYYYMMDD-scope --json"
  ],
  deniedActions: [
    "no UI work before route smoke/explanation is resolved",
    "no host install from gateway health alone",
    "no signed Codex App bundle patch",
    "no per-model provider split",
    "no LaunchAgent write/load/unload in this planner",
    "no ~/.codex write in this planner",
    "no model-text promotion to route receipt"
  ],
  blockedBy,
  plainSummary: queue.length > 0
    ? `需要逐條 route live smoke 或明確說明：${queue.map(item => item.modelID).join("、")}。UI 繼續延後，主機實裝繼續關閉。`
    : "目前沒有從 dashboard/preflight 看到 risky route；仍要跑 baseline same-thread smoke 才能進主機實裝 gate。",
  generatedAt: new Date().toISOString()
};

emit(report);
process.exit(0);

function routeSmokeItem(modelID, risk, index) {
  const riskKinds = Array.isArray(risk?.riskKinds) ? risk.riskKinds : inferRiskKinds(modelID);
  return {
    id: `route-smoke-${index + 1}`,
    modelID,
    ownerTeam: "環境穩定團隊",
    helperTeams: ["總控團隊", "代碼團隊"],
    riskKinds,
    plainWhy: risk?.plainChineseExplanation ?? "這條 route 需要 live same-thread smoke；不能只看 gateway 總 health。",
    commandHint: "TATWO_HOST_SAME_THREAD_SMOKE=1 node scripts/tatwo-host-same-thread-smoke.mjs --run --gateway-dir <gateway-dir> --json",
    sameThreadSequence: ["gpt-5.5 baseline", modelID, "gpt-5.5 continuity check"],
    requiredProof: [
      "live same-thread smoke",
      "route-specific response.completed",
      "same thread continuity back to gpt-5.5",
      "no retry storm / disconnected / partial stream",
      "explicit stale route explanation if route error is not active failure"
    ],
    failClosedIf: [
      "only gateway health is green",
      "only model text says OK",
      "only response.in_progress or output_text.delta is observed",
      "MCP stdio works but host registration is not observed",
      "Codex provider changes instead of only model changes"
    ],
    resultReceiptClass: "host_live route-specific same-thread receipt",
    canStartUIAfterThisAlone: false,
    canInstallHostAfterThisAlone: false
  };
}

function inferRiskKinds(modelID) {
  const out = [];
  if (liveRouteLists.routeErrors.some(item => String(item).startsWith(`${modelID}:`))) out.push("route_error");
  if (liveRouteLists.routesWithoutLastOK.includes(modelID)) out.push("no_last_ok");
  return out.length ? out : ["needs_live_smoke"];
}

function parseJSONDocument(file) {
  const text = read(file);
  const start = text.indexOf("{");
  if (start < 0) return null;
  try { return JSON.parse(text.slice(start)); }
  catch { return null; }
}

function read(file) {
  try { return fs.readFileSync(path.join(evidenceDir, file), "utf8"); }
  catch { return ""; }
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
    .replace(/(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}/g, "$1<redacted-token>")
    .replace(/Bearer [A-Za-z0-9._-]+/g, "Bearer <redacted>")
    .replace(/auth\.json/g, "<auth-file>");
}

function unique(values) {
  return [...new Set(values.filter(Boolean))];
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
