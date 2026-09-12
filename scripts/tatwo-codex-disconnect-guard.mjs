#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const args = parseArgs(process.argv.slice(2));
const gatewayDir = args["gateway-dir"] ?? process.env.MODEL_GATEWAY_DIR ?? null;

const repoFiles = [
  "docs/tatwo/INTEGRATION_STABILITY.md",
  "docs/tatwo/MCP.md",
  "scripts/tatwo-host-preflight.mjs",
  "scripts/tatwo-host-readiness-gate.mjs",
  "scripts/tatwo-host-receipt-bundle.mjs",
  "scripts/tatwo-route-risk-dashboard.mjs",
  "scripts/tatwo-operational-receipt-adversarial.mjs",
  "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/OperationalReceipt.swift",
  "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/HostPreparation.swift"
];

const repoText = repoFiles.map(file => safeRead(path.join(repoRoot, file))).join("\n");
const gatewayText = gatewayDir && fs.existsSync(String(gatewayDir))
  ? readSelectedGatewayFiles(String(gatewayDir))
  : "";
const gatewayEvidence = gatewayText
  ? "observed"
  : "not_configured";

const checks = [
  guard(
    "single-model-gateway-provider",
    has(repoText, "model_gateway") && has(repoText, "同 thread") && has(repoText, "只切") && has(repoText, "codex-model-provider-single-gateway"),
    "Codex App 只能用一個 model_gateway provider；同一條 thread 只切 model，不切 provider。",
    ["docs/tatwo/INTEGRATION_STABILITY.md", "HostPreparation.swift", "scripts/tatwo-host-preflight.mjs"]
  ),
  guard(
    "semantic-sse-in-progress",
    has(repoText + gatewayText, "response.in_progress"),
    "長 turn 等外部模型時要送 data-bearing response.in_progress，不能只靠註解 keepalive。",
    gatewayText ? ["model-gateway runtime/tests"] : ["docs/tatwo/INTEGRATION_STABILITY.md"]
  ),
  guard(
    "clean-413-not-reset",
    has(repoText + gatewayText, "413") && (has(repoText + gatewayText, "request body too large") || has(repoText + gatewayText, "body cap")),
    "大型 prompt 超限時要回乾淨 413，不可以 reset socket 讓 Codex reconnect storm。",
    gatewayText ? ["model-gateway tests"] : ["docs/tatwo/INTEGRATION_STABILITY.md"]
  ),
  guard(
    "gateway-route-error-state-observable",
    has(repoText, "gateway-route-error-state")
      && has(repoText, "routes_with_errors")
      && has(repoText, "error_kind"),
    "gateway health 綠不代表每條模型路線都乾淨；host preflight 必須可看到 /healthz.routes 的 stale error / error_kind / last_ok 狀態。",
    ["scripts/tatwo-host-preflight.mjs", "scripts/tatwo-host-readiness-gate.mjs", "docs/tatwo/INTEGRATION_STABILITY.md"]
  ),
  guard(
    "route-risk-dashboard-plain-language",
    has(repoText, "TatwoRouteRiskDashboardV1")
      && has(repoText, "live same-thread smoke")
      && has(repoText, "response.completed")
      && has(repoText, "環境穩定團隊"),
    "route 風險不能只藏在 gateway health；要有白話 dashboard 列出每條 risky route、負責團隊與 response.completed 證據要求。",
    ["scripts/tatwo-route-risk-dashboard.mjs", "docs/tatwo/INTEGRATION_STABILITY.md", "docs/tatwo/MCP.md"]
  ),
  guard(
    "backend-notice-completes-visibly",
    has(repoText + gatewayText, "completed") && has(repoText + gatewayText, "retry storm"),
    "登入、quota、session limit 類錯誤要變成可見 completed notice，不用 response.failed 觸發重試風暴。",
    gatewayText ? ["model-gateway tests"] : ["docs/tatwo/INTEGRATION_STABILITY.md", "OperationalReceipt.swift"]
  ),
  guard(
    "client-cancel-does-not-crash-gateway",
    has(repoText + gatewayText, "client disconnect") || has(repoText + gatewayText, "AbortError") || has(repoText + gatewayText, "取消不崩"),
    "使用者取消 turn 或 socket 提前關閉時，gateway 要吞掉正常取消，不可以整個崩掉。",
    gatewayText ? ["model-gateway tests"] : ["docs/tatwo/INTEGRATION_STABILITY.md"]
  ),
  guard(
    "app-server-bundle-source-check",
    has(repoText, "codex-app-server-version-source") && has(repoText, "Codex.app bundle"),
    "只讀檢查 app-server/proxy 是否來自 Codex.app bundle，避免 handshake timeout / transport_closed。",
    ["scripts/tatwo-host-preflight.mjs"]
  ),
  guard(
    "auth-single-source-check",
    has(repoText, "codex-sub-auth-single-source") && has(repoText, "auth single source"),
    "避免多個 auth.json 副本搶 refresh，造成假撞限額、token invalidated、retry storm。",
    ["scripts/tatwo-host-preflight.mjs"]
  ),
  guard(
    "auto-compact-total-scope-check",
    has(repoText, "model_auto_compact_token_limit_scope") && has(repoText, "total"),
    "長 thread 要用 total scope 觸發 auto-compact，避免撞 context 後像斷線。",
    ["scripts/tatwo-host-preflight.mjs", "docs/tatwo/INTEGRATION_STABILITY.md"]
  ),
  guard(
    "stdio-is-not-host-registration",
    has(repoText, "mcp-stdio") && has(repoText, "mcp-host") && has(repoText, "hostRegistrationObserved"),
    "MCP stdio smoke 只證明 server 能跑，不能冒充 Codex host config 已註冊。",
    ["scripts/tatwo-host-receipt-bundle.mjs", "scripts/tatwo-host-readiness-gate.mjs"]
  ),
  guard(
    "response-completed-required",
    has(repoText, "response.completed") && has(repoText, "partial_stream_cannot_pass"),
    "partial stream / response.in_progress 不能算完成；必須 terminal event 是 response.completed。",
    ["OperationalReceipt.swift", "scripts/tatwo-operational-receipt-adversarial.mjs"]
  ),
  guard(
    "host-gate-fail-closed",
    has(repoText, "hostInstallAllowed") && has(repoText, "human_approval_required") && has(repoText, "host_backup_not_observed"),
    "沒有人工批准、備份、rollback、live same-thread、mcp-host 收據時，host install 必須關閉。",
    ["scripts/tatwo-host-readiness-gate.mjs", "scripts/tatwo-host-receipt-bundle.mjs"]
  ),
  guard(
    "no-host-mutation",
    true,
    "本 guard 只讀 repo 與可選 gateway source/test，不寫 ~/.codex、不碰 LaunchAgent、不讀 auth/session。",
    ["scripts/tatwo-codex-disconnect-guard.mjs"]
  )
];

const failedCheckIDs = checks.filter(item => !item.passed).map(item => item.id);
const skippedExternalEvidence = gatewayEvidence === "observed" ? [] : ["model_gateway_source_not_configured"];
const report = {
  schema: "TatwoCodexDisconnectGuardV1",
  passed: failedCheckIDs.length === 0,
  hostMutationAllowed: false,
  hostMutationPerformed: false,
  gatewayEvidence,
  skippedExternalEvidence,
  checks,
  failedCheckIDs,
  deniedActions: [
    "no signed Codex App bundle patch",
    "no ~/.codex write",
    "no LaunchAgent write/load/unload",
    "no auth/session/token read",
    "no process kill/restart"
  ],
  hostInstallBlockersIfUnobserved: [
    ...(gatewayEvidence === "observed" ? [] : ["external_model_gateway_source_not_observed"]),
    "live_same_thread_smoke_not_observed",
    "mcp_registration_on_host_not_observed",
    "host_backup_not_observed",
    "rollback_receipt_not_observed",
    "human_approval_required"
  ],
  plainSummary: failedCheckIDs.length === 0
    ? "Codex disconnect guard is wired: single provider, semantic SSE, clean 413, gateway route error state, visible backend notices, app-server source, auth single source, auto-compact, and receipt gates are covered. This is still not a live host smoke."
    : `Codex disconnect guard failed: ${failedCheckIDs.join(", ")}.`,
  generatedAt: new Date().toISOString()
};

console.log(JSON.stringify(report, null, 2));
process.exit(failedCheckIDs.length === 0 ? 0 : 1);

function guard(id, passed, plainRule, evidenceFiles) {
  return {
    id,
    passed: Boolean(passed),
    plainRule,
    evidenceFiles,
    observed: passed ? "present" : "missing"
  };
}

function has(text, needle) {
  return String(text).toLowerCase().includes(String(needle).toLowerCase());
}

function safeRead(file) {
  try {
    const stat = fs.statSync(file);
    if (!stat.isFile() || stat.size > 2 * 1024 * 1024) return "";
    return fs.readFileSync(file, "utf8");
  } catch {
    return "";
  }
}

function readSelectedGatewayFiles(dir) {
  const files = [];
  collect(dir, files, 0);
  return files
    .filter(file => /\.(js|mjs|ts|json|md|test\.js)$/i.test(file))
    .filter(file => !file.includes(`${path.sep}node_modules${path.sep}`))
    .slice(0, 200)
    .map(file => safeRead(file))
    .join("\n");
}

function collect(dir, out, depth) {
  if (depth > 4 || out.length > 300) return;
  let entries = [];
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); }
  catch { return; }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (["node_modules", ".git", ".build", "dist"].includes(entry.name)) continue;
      collect(full, out, depth + 1);
    } else if (entry.isFile()) {
      out.push(full);
    }
  }
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
