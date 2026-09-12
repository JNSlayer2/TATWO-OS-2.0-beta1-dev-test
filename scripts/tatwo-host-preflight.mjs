#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import http from "node:http";

const home = os.homedir();
const args = parseArgs(process.argv.slice(2));

const commandChecks = [
  commandCheck("node", "Node.js", "critical"),
  commandCheck("swift", "Swift toolchain", "critical"),
  commandCheck("git", "Git", "medium"),
  commandCheck("codex", "Codex CLI", "critical"),
  commandCheck("claude", "Claude CLI", "medium"),
  commandCheck("grok", "Grok CLI", "medium")
];

const appBundle = firstExisting([
  "/Applications/Codex.app",
  path.join(home, "Applications", "Codex.app")
]);

const configPath = path.join(home, ".codex", "config.toml");
const configText = safeReadText(configPath, 256 * 1024);
const codexPath = commandChecks.find(c => c.id === "cmd-codex")?.path ?? null;
const appServer = inspectAppServerProcesses();
const gateway = await probeGatewayHealth();
const gatewayRouteState = inspectGatewayRouteState(gateway.data);
const codexSubAuth = inspectCodexSubAuth();
const fastDefaults = inspectFastDefaults(configText);
const modelProvider = inspectModelProvider(configText);

const checks = [
  {
    id: "codex-app-bundle",
    title: "Codex App bundle",
    status: appBundle ? "installed" : "missing",
    severity: "critical",
    observed: appBundle ? sanitizePath(appBundle) : "not_found",
    remediation: appBundle ? null : "Install Codex App before host dropdown smoke."
  },
  {
    id: "codex-cli-path",
    title: "Codex CLI path",
    status: codexPath ? "installed" : "missing",
    severity: "critical",
    observed: codexPath ? sanitizePath(codexPath) : "not_found",
    remediation: codexPath ? null : "Install or expose codex CLI on PATH."
  },
  ...commandChecks,
  {
    id: "codex-model-provider-single-gateway",
    title: "Codex single model_gateway provider",
    status: modelProvider.singleGateway ? "installed" : "unknown",
    severity: "critical",
    observed: modelProvider.observed,
    remediation: modelProvider.singleGateway
      ? null
      : "Set Codex to the single model_gateway provider before host smoke; do not add one provider per model."
  },
  {
    id: "model-gateway-health",
    title: "model_gateway health",
    status: gateway.ok ? "installed" : "unknown",
    severity: "critical",
    observed: gateway.summary,
    remediation: gateway.ok ? null : "Run model-gateway preflight/post-update-check before host install."
  },
  {
    id: "gateway-route-error-state",
    title: "Gateway route error state",
    status: gatewayRouteState.routeInventoryObserved ? "installed" : "unknown",
    severity: "medium",
    observed: gatewayRouteState.observed,
    remediation: gatewayRouteState.routesWithErrors.length === 0
      ? "Route state is observable. Live same-thread smoke is still required before host install."
      : "Run the live same-thread smoke after backup/approval. Stale route errors are not a pass and must be cleared or explained before host install."
  },
  {
    id: "codex-app-server-version-source",
    title: "Codex app-server source",
    status: appServer.hasStaleNonBundleServer ? "unknown" : "installed",
    severity: "critical",
    observed: appServer.summary,
    remediation: appServer.hasStaleNonBundleServer ? "Before host install, ensure app-server/proxy are launched from the Codex.app bundle binary." : null
  },
  {
    id: "fast-defaults",
    title: "Fast defaults",
    status: fastDefaults.serviceTierFast ? "installed" : "unknown",
    severity: "high",
    observed: fastDefaults.observed,
    remediation: fastDefaults.serviceTierFast
      ? "Speed is fast; reasoning follows Codex App/CLI or the user's selected mode."
      : "Set service_tier=fast before long host smoke. Reasoning does not need to be forced low by Tatwo."
  },
  {
    id: "auto-compact-scope",
    title: "Auto-compaction scope",
    status: hasConfigKey(configText, "model_auto_compact_token_limit_scope", "total") ? "installed" : "unknown",
    severity: "high",
    observed: configText === null ? "config_unread_or_missing" : "scope_total=" + hasConfigKey(configText, "model_auto_compact_token_limit_scope", "total"),
    remediation: "Set model_auto_compact_token_limit_scope=total before long custom-provider threads."
  },
  {
    id: "codex-sub-auth-single-source",
    title: "Subagent auth single source",
    status: codexSubAuth.status,
    severity: "high",
    observed: codexSubAuth.observed,
    remediation: codexSubAuth.remediation
  }
];

const report = {
  schema: "TatwoHostPreflightV1",
  readOnly: true,
  hostMutationAllowed: false,
  generatedAt: new Date().toISOString(),
  checks,
  failedCriticalCheckIDs: checks.filter(c => c.severity === "critical" && c.status === "missing").map(c => c.id),
  unknownHighOrCriticalCheckIDs: checks.filter(c => ["critical", "high"].includes(c.severity) && c.status === "unknown").map(c => c.id),
  deniedActions: [
    "no signed Codex App bundle edits",
    "no ~/.codex config/state/cache writes",
    "no LaunchAgent writes or load/unload",
    "no auth/session/token file reads",
    "no process kill/restart"
  ],
  requiredBeforeHostInstall: [
    "sandbox evidence bundle",
    "host sandbox rehearsal receipt",
    "host backup receipt",
    "human approval receipt",
    "live same-thread smoke receipt",
    "host MCP registration smoke receipt",
    "rollback receipt"
  ],
  nextActions: [
    "Fix missing critical checks.",
    "Run tatwo-host-sandbox-rehearsal.mjs to prove install/rollback in fake HOME before touching host.",
    "Run tatwo-host-backup-plan.mjs as dry-run, then confirm backup only after human approval.",
    "Run tatwo-host-install-verified-gate.mjs against the evidence bundle before any host install.",
    "Do not install into host until readiness gate has the backup, same-thread, mcp-host, and rollback receipts."
  ]
};

console.log(JSON.stringify(report, null, 2));

// Exit code contract (aligned with the other gate scripts): automation must be
// able to trust the exit code, not just parse the JSON body.
// 0 = all critical/high checks clean, 1 = unknown high/critical checks remain,
// 2 = at least one critical check is missing.
if (report.failedCriticalCheckIDs.length > 0) process.exit(2);
if (report.unknownHighOrCriticalCheckIDs.length > 0) process.exit(1);
process.exit(0);

function commandCheck(command, title, severity) {
  const which = spawnSync("sh", ["-lc", `command -v ${shellQuote(command)}`], { encoding: "utf8", timeout: 3000 });
  const found = which.status === 0 && which.stdout.trim();
  const version = found ? spawnSync("sh", ["-lc", `${shellQuote(command)} --version 2>/dev/null | head -1`], { encoding: "utf8", timeout: 5000 }) : null;
  return {
    id: `cmd-${command}`,
    title,
    status: found ? "installed" : "missing",
    severity,
    path: found ? sanitizePath(which.stdout.trim()) : null,
    observed: found ? [sanitizePath(which.stdout.trim()), sanitizeOutput(version?.stdout ?? "")].filter(Boolean).join(" | ") : "not_found",
    remediation: found ? null : `Install ${title} or make it available on PATH.`
  };
}

function firstExisting(paths) {
  return paths.find(p => fs.existsSync(p)) ?? null;
}

function safeReadText(file, maxBytes) {
  try {
    const stat = fs.statSync(file);
    if (!stat.isFile() || stat.size > maxBytes) return null;
    return fs.readFileSync(file, "utf8");
  } catch {
    return null;
  }
}

function hasConfigKey(text, key, expectedValue) {
  if (!text) return false;
  const pattern = new RegExp(`(^|\\n)\\s*${escapeRegex(key)}\\s*=\\s*["']?${escapeRegex(expectedValue)}["']?\\s*(\\n|$)`, "i");
  return pattern.test(text);
}

function hasAnyConfigKey(text, key) {
  if (!text) return false;
  const pattern = new RegExp(`(^|\\n)\\s*${escapeRegex(key)}\\s*=`, "i");
  return pattern.test(text);
}

function matchConfigValue(text, key) {
  if (!text) return null;
  const pattern = new RegExp(`(^|\\n)\\s*${escapeRegex(key)}\\s*=\\s*["']?([^"'\\n#]+)["']?`, "i");
  const match = text.match(pattern);
  return match ? sanitizeOutput(match[2].trim()) : null;
}

function inspectModelProvider(text) {
  if (text === null) {
    return { singleGateway: false, observed: "config_unread_or_missing" };
  }
  const configuredGateway = hasConfigKey(text, "model_provider", "model_gateway");
  const anyProvider = matchConfigValue(text, "model_provider");
  const customProviderMentions = (text.match(/\[model_providers\./g) ?? []).length;
  return {
    singleGateway: configuredGateway,
    observed: configuredGateway
      ? `model_provider=model_gateway, custom_provider_blocks=${customProviderMentions}`
      : `model_provider=${anyProvider ?? "missing"}, expected=model_gateway`
  };
}

function inspectFastDefaults(text) {
  if (text === null) {
    return { serviceTierFast: false, observed: "config_unread_or_missing" };
  }
  const serviceTierFast = hasConfigKey(text, "service_tier", "fast");
  const reasoningLow = hasConfigKey(text, "model_reasoning_effort", "low");
  const reasoningConfigured = hasAnyConfigKey(text, "model_reasoning_effort");
  const reasoningPolicy = reasoningLow
    ? "low"
    : (reasoningConfigured ? "custom_follow_codex_config" : "follow_codex_app_or_cli");
  return {
    serviceTierFast,
    observed: `service_tier_fast=${serviceTierFast}, reasoning_policy=${reasoningPolicy}`
  };
}

function inspectAppServerProcesses() {
  const ps = spawnSync("sh", ["-lc", "ps -axo command | grep -E 'codex (app-server|app-server proxy)' | grep -v grep"], { encoding: "utf8", timeout: 3000 });
  if (ps.status !== 0 || !ps.stdout.trim()) {
    return { summary: "no_app_server_process_observed", hasStaleNonBundleServer: false };
  }
  const lines = ps.stdout.trim().split(/\n+/);
  const acceptedBundlePrefixes = [
    "/Applications/Codex.app/Contents/Resources/codex",
    path.join(home, "Applications", "Codex.app", "Contents", "Resources", "codex")
  ];
  const resolvedCodex = spawnSync("sh", ["-lc", "command -v codex"], { encoding: "utf8", timeout: 3000 }).stdout?.trim() ?? "";
  const resolvedCodexIsBundle = acceptedBundlePrefixes.some(prefix => resolvedCodex === prefix);
  const appBundleCodex = acceptedBundlePrefixes.find(file => fs.existsSync(file)) ?? null;
  const appBundleVersion = appBundleCodex ? codexVersion(appBundleCodex) : null;
  const resolvedCodexVersion = resolvedCodex ? codexVersion(resolvedCodex) : null;
  const resolvedCodexSameVersion = Boolean(appBundleVersion && resolvedCodexVersion && appBundleVersion === resolvedCodexVersion);
  const nonBundle = lines.filter(line => !isAcceptedAppServerLine(line, acceptedBundlePrefixes, {
    resolvedCodexIsBundle,
    resolvedCodexSameVersion
  }));
  const bareResolved = lines.filter(line => !acceptedBundlePrefixes.some(prefix => line.includes(prefix)) && hasBareCodexAppServerInvocation(line)).length;
  return {
    summary: [
      `processes=${lines.length}`,
      `non_bundle=${nonBundle.length}`,
      `bare_resolved_to_bundle=${resolvedCodexIsBundle ? bareResolved : 0}`,
      `bare_same_version=${!resolvedCodexIsBundle && resolvedCodexSameVersion ? bareResolved : 0}`,
      `app_version=${sanitizeOutput(appBundleVersion ?? "unknown")}`,
      `path_version=${sanitizeOutput(resolvedCodexVersion ?? "unknown")}`
    ].join(", "),
    hasStaleNonBundleServer: nonBundle.length > 0
  };
}

function isAcceptedAppServerLine(line, acceptedBundlePrefixes, resolved) {
  if (acceptedBundlePrefixes.some(prefix => line.includes(prefix))) return true;
  // Codex Desktop may spawn wrapper shell commands that say `codex app-server`
  // without expanding the absolute binary path. Treat those as bundle-backed
  // when PATH resolves `codex` to the signed Codex.app binary. If PATH resolves
  // to a Homebrew/cask binary with the same CLI version as Codex.app, keep the
  // gate green but expose the source in the summary; what M2 must block is
  // version skew/stale binaries, not a harmless same-version wrapper.
  return hasBareCodexAppServerInvocation(line)
    && (resolved.resolvedCodexIsBundle || resolved.resolvedCodexSameVersion);
}

function hasBareCodexAppServerInvocation(line) {
  return /(^|[\s;&|()])(?:nohup\s+)?codex app-server(?:\s|$)/.test(String(line));
}

function codexVersion(binaryPath) {
  const result = spawnSync(binaryPath, ["--version"], { encoding: "utf8", timeout: 5000 });
  if (result.status !== 0) return null;
  return sanitizeOutput((result.stdout ?? "").trim().split(/\n+/)[0] ?? "");
}

function inspectCodexSubAuth() {
  const file = path.join(home, ".codex-sub", "auth.json");
  try {
    const stat = fs.lstatSync(file);
    if (stat.isSymbolicLink()) {
      return { status: "installed", observed: "symlink", remediation: null };
    }
    return {
      status: "unknown",
      observed: "plain_file_copy_present",
      remediation: "Use one auth source of truth; do not keep a stale subagent auth copy."
    };
  } catch {
    return { status: "installed", observed: "not_present", remediation: null };
  }
}

async function probeGatewayHealth() {
  return new Promise(resolve => {
    const req = http.get("http://127.0.0.1:4177/healthz", { timeout: 2500 }, res => {
      let body = "";
      res.setEncoding("utf8");
      res.on("data", chunk => { body += chunk; if (body.length > 512 * 1024) req.destroy(); });
      res.on("end", () => {
        try {
          const data = JSON.parse(body);
          resolve({
            ok: Boolean(data.ok),
            summary: `http_${res.statusCode}, ok=${Boolean(data.ok)}, provider=${String(data.provider ?? "unknown")}`,
            data
          });
        } catch {
          resolve({ ok: false, summary: `http_${res.statusCode}, invalid_json`, data: null });
        }
      });
    });
    req.on("timeout", () => {
      req.destroy();
      resolve({ ok: false, summary: "timeout", data: null });
    });
    req.on("error", () => resolve({ ok: false, summary: "not_reachable", data: null }));
  });
}

function inspectGatewayRouteState(data) {
  const routes = data && typeof data === "object" && data.routes && typeof data.routes === "object"
    ? data.routes
    : null;
  if (!routes) {
    return {
      routeInventoryObserved: false,
      routesWithErrors: [],
      observed: "routes_not_observed"
    };
  }

  const importantRouteIDs = [
    "gpt-5.5",
    "opus-5",
    "sonnet-5",
    "grok-build",
    "minimax-m3"
  ];
  const routeIDs = Object.keys(routes);
  const routesWithErrors = [];
  const neverOk = [];

  for (const id of importantRouteIDs) {
    const route = routes[id];
    if (!route || typeof route !== "object") {
      routesWithErrors.push(`${id}:missing`);
      continue;
    }
    if (route.has_error === true || route.error_kind) {
      routesWithErrors.push(`${id}:${sanitizeOutput(String(route.error_kind ?? "error"))}`);
    }
    if (Object.prototype.hasOwnProperty.call(route, "last_ok_at") && !route.last_ok_at) {
      neverOk.push(id);
    }
  }

  return {
    routeInventoryObserved: true,
    routesWithErrors,
    observed: [
      `routes=${routeIDs.length}`,
      `important=${importantRouteIDs.filter(id => routes[id]).length}/${importantRouteIDs.length}`,
      `routes_with_errors=${routesWithErrors.length ? routesWithErrors.join(",") : "none"}`,
      `without_last_ok=${neverOk.length ? neverOk.join(",") : "none"}`
    ].join(", ")
  };
}

function sanitizePath(value) {
  return String(value)
    .replaceAll(home, "$HOME")
    .replaceAll(os.userInfo().username, "$USER");
}

function sanitizeOutput(value) {
  return sanitizePath(String(value).trim()).replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/g, "<email>");
}

function shellQuote(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}

function escapeRegex(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function parseArgs(argv) {
  const out = {};
  for (const arg of argv) {
    if (arg === "--json") out.json = true;
  }
  return out;
}
