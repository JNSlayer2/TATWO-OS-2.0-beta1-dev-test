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
    schema: "TatwoRouteRiskDashboardV1",
    status: "blocked",
    uiDeferred: true,
    hostMutationAllowed: false,
    hostMutationPerformed: false,
    hostInstallAllowed: false,
    evidenceDir: null,
    routeStateVisible: false,
    routeRiskSummary: {
      status: "blocked",
      observed: "no_evidence_bundle",
      routeErrors: [],
      routesWithoutLastOK: [],
      riskyRouteCount: 0
    },
    riskyRoutes: [],
    ownerTeam: "環境穩定團隊",
    requiredBeforePromotion: [
      "sandbox evidence bundle",
      "read-only host preflight",
      "live same-thread smoke",
      "route-specific response.completed"
    ],
    blockedBy: ["sandbox_evidence_missing", "gateway_route_state_not_observed"],
    safeNextCommands: ["MODEL_GATEWAY_DIR=<gateway-dir> OPEN_ULTRAWORK_DIR=<open-ultrawork-dir> bash scripts/tatwo-ultrawork-sandbox-check.sh"],
    deniedActions: deniedActions(),
    plainSummary: "還沒有沙盒證據，所以不能判斷模型路線風險；先跑 sandbox check，之後仍要 route-specific response.completed，不能做 UI 或主機實裝。",
    generatedAt: new Date().toISOString()
  });
  process.exit(1);
}

const preflight = parseJSONDocument("host-preflight-live.log") ?? parseJSONDocument("host-preflight.log");
const promotion = parseJSONDocument("host-promotion-plan.log");
const routeState = routeStateFromPreflight(preflight);
const riskyRoutes = buildRiskyRoutes(routeState);
const hasRisk = riskyRoutes.length > 0;
const routeStateVisible = routeState.visible === true;
const status = !routeStateVisible ? "blocked" : (hasRisk ? "needs_live_smoke" : "clean_but_live_smoke_required");
const blockedBy = unique([
  ...(routeStateVisible ? [] : ["gateway_route_state_not_observed"]),
  ...(routeState.routeErrors.length ? ["gateway_route_errors_need_live_smoke"] : []),
  ...(routeState.routesWithoutLastOK.length ? ["gateway_routes_without_last_ok_need_live_smoke"] : []),
  ...(promotion?.hostInstallAllowed === true ? ["promotion_plan_wrongly_allows_host_install"] : []),
  ...(promotion?.uiDeferred === false ? ["promotion_plan_wrongly_starts_ui"] : [])
]);

const report = {
  schema: "TatwoRouteRiskDashboardV1",
  status,
  uiDeferred: true,
  hostMutationAllowed: false,
  hostMutationPerformed: false,
  hostInstallAllowed: false,
  evidenceDir: sanitizeEvidenceDir(evidenceDir),
  sourceFiles: ["host-preflight-live.log", ...(promotion ? ["host-promotion-plan.log"] : [])],
  routeStateVisible,
  ownerTeam: "環境穩定團隊",
  routeRiskSummary: {
    status,
    observed: sanitize(routeState.observed),
    routeErrors: routeState.routeErrors,
    routesWithoutLastOK: routeState.routesWithoutLastOK,
    riskyRouteCount: riskyRoutes.length,
    liveSmokeRequired: true,
    responseCompletedRequired: true
  },
  riskyRoutes,
  requiredBeforePromotion: [
    "live same-thread smoke",
    "route-specific response.completed",
    "explicit stale route explanation if not active failure",
    "host install verified gate remains hostInstallAllowed=false until backup/rollback/MCP-host receipts exist"
  ],
  safeNextCommands: safeNextCommands(hasRisk),
  deniedActions: deniedActions(),
  blockedBy,
  plainSummary: plainSummary(routeStateVisible, riskyRoutes, blockedBy),
  generatedAt: new Date().toISOString()
};

emit(report);
process.exit(routeStateVisible ? 0 : 1);

function buildRiskyRoutes(routeState) {
  const byModel = new Map();
  for (const entry of routeState.routeErrors) {
    const [modelID, rawKind = "error"] = String(entry).split(":");
    if (!modelID || modelID === "none") continue;
    const risk = getRisk(byModel, modelID);
    risk.riskKinds.push("route_error");
    risk.observedErrorKind = rawKind || "error";
  }
  for (const modelID of routeState.routesWithoutLastOK) {
    if (!modelID || modelID === "none") continue;
    const risk = getRisk(byModel, modelID);
    risk.riskKinds.push("no_last_ok");
  }

  return [...byModel.values()].map(item => {
    const riskKinds = unique(item.riskKinds);
    return {
      modelID: item.modelID,
      riskKinds,
      observedErrorKind: item.observedErrorKind ?? null,
      plainChineseExplanation: routeExplanation(riskKinds, item.observedErrorKind),
      whyItMatters: "如果直接接入，Codex 可能在切到這條模型路線時卡住、斷線、重試，或讓模型口頭說成功但沒有真正完成。",
      ownerTeam: "環境穩定團隊",
      requiredProof: [
        "live same-thread smoke",
        "route-specific response.completed",
        "explicit stale route explanation if not active failure"
      ],
      installBlocker: true,
      uiBlocker: true,
      passRule: "只有真實 host smoke / response.completed / 可讀 explanation 算數；gateway 總 health 綠或模型文字說 OK 都不算。"
    };
  }).sort((a, b) => a.modelID.localeCompare(b.modelID));
}

function getRisk(map, modelID) {
  if (!map.has(modelID)) map.set(modelID, { modelID, riskKinds: [], observedErrorKind: null });
  return map.get(modelID);
}

function routeExplanation(kinds, errorKind) {
  const hasError = kinds.includes("route_error");
  const noLastOK = kinds.includes("no_last_ok");
  if (hasError && noLastOK) {
    return `這條路線同時有錯誤狀態${errorKind ? `（${errorKind}）` : ""}，而且沒有最後成功紀錄；不能被包成已就緒。`;
  }
  if (hasError) {
    return `這條路線目前留有錯誤狀態${errorKind ? `（${errorKind}）` : ""}；可能是舊錯，也可能是仍在壞，必須用 live smoke 或明確說明釐清。`;
  }
  if (noLastOK) {
    return "這條路線目前沒有最後成功完成紀錄；gateway 總 health 綠不代表這個模型真的能在同 thread 完成。";
  }
  return "這條路線沒有明顯錯誤，但 host install 前仍需 live same-thread smoke。";
}

function routeStateFromPreflight(preflight) {
  const checks = Array.isArray(preflight?.checks) ? preflight.checks : [];
  const route = checks.find(item => item?.id === "gateway-route-error-state");
  const observed = String(route?.observed ?? "route_state_missing");
  return {
    visible: route?.status === "installed",
    observed,
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

function safeNextCommands(hasRisk) {
  return [
    "node scripts/tatwo-route-risk-dashboard.mjs --latest --json",
    ...(hasRisk ? ["TATWO_HOST_SAME_THREAD_SMOKE=1 node scripts/tatwo-host-same-thread-smoke.mjs --run --gateway-dir <gateway-dir> --json"] : ["Still run live same-thread smoke before host install; clean dashboard is not a host receipt."]),
    "node scripts/tatwo-host-promotion-plan.mjs --latest --json",
    "node scripts/tatwo-host-install-verified-gate.mjs --latest --human-approval human-YYYYMMDD-scope --json"
  ];
}

function deniedActions() {
  return [
    "no UI work while route risk requires live smoke or explanation",
    "no host install from gateway health alone",
    "no hiding routes_with_errors or without_last_ok behind a green dashboard",
    "no signed Codex App bundle patch",
    "no per-model provider split",
    "no LaunchAgent write/load/unload during route triage",
    "no ~/.codex config/state/cache write before human approval plus backup",
    "no model-text or dry-run promotion to live route receipt"
  ];
}

function plainSummary(visible, risks, blockers) {
  if (!visible) return "route 狀態還沒被只讀 preflight 看見；這時不能說模型路線乾淨，也不能開始 UI 或主機實裝。";
  if (risks.length > 0) {
    return `目前有 ${risks.length} 條模型路線需要 live smoke 或明確說明：${risks.map(item => item.modelID).join("、")}。UI 仍延後，主機實裝仍關閉。`;
  }
  return blockers.length
    ? `route 狀態可見，但仍有 blocker：${blockers.join(", ")}。UI 仍延後，主機實裝仍關閉。`
    : "route 狀態目前沒有明顯錯誤；但這不等於主機可實裝，仍要 live same-thread、備份、rollback、MCP host registration 收據。";
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
  const start = String(text ?? "").indexOf("{");
  if (start < 0) return null;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < text.length; i += 1) {
    const ch = text[i];
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
      if (depth === 0) return text.slice(start, i + 1);
    }
  }
  return null;
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
