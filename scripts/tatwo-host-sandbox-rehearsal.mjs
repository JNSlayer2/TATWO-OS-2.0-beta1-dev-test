#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const args = parseArgs(process.argv.slice(2));
const explicitRoot = args["work-dir"] ? path.resolve(String(args["work-dir"])) : null;
const rehearsalRoot = explicitRoot ?? fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-host-rehearsal-"));
const keep = Boolean(args.keep) || Boolean(explicitRoot);
const now = new Date();
const fakeHome = path.join(rehearsalRoot, "fake-home");
const fakeCodexHome = path.join(fakeHome, ".codex");
const fakeLaunchAgents = path.join(fakeHome, "Library", "LaunchAgents");
const fakeAppData = path.join(fakeHome, "Library", "Application Support", "TatwoUltrawork");
const backupRoot = path.join(rehearsalRoot, "backup");
const tatwoState = path.join(rehearsalRoot, "tatwo-state");
const fakeTemp = path.join(rehearsalRoot, "tmp");
const fakeSwiftScratch = path.join(rehearsalRoot, "swift-scratch");
const sandboxProfilePath = path.join(rehearsalRoot, "host-rehearsal.sb");
const serverPath = path.join(repoRoot, "scripts", "tatwo-ultrawork-mcp.mjs");
const inheritedOuterSandbox = process.env.TATWO_OUTER_SANDBOX === "1";
const checks = [];
let error = null;
let mcpReport = null;
let initialHashes = {};
let rollbackHashes = {};
let report;

try {
  fs.mkdirSync(fakeCodexHome, { recursive: true, mode: 0o700 });
  fs.mkdirSync(fakeLaunchAgents, { recursive: true, mode: 0o700 });
  fs.mkdirSync(fakeAppData, { recursive: true, mode: 0o700 });
  fs.mkdirSync(backupRoot, { recursive: true, mode: 0o700 });
  fs.mkdirSync(tatwoState, { recursive: true, mode: 0o700 });
  fs.mkdirSync(fakeTemp, { recursive: true, mode: 0o700 });
  fs.mkdirSync(fakeSwiftScratch, { recursive: true, mode: 0o700 });
  writeSandboxProfile(sandboxProfilePath);

  const configPath = path.join(fakeCodexHome, "config.toml");
  const statePath = path.join(fakeCodexHome, "state_5.sqlite");
  const modelsCachePath = path.join(fakeCodexHome, "models_cache.json");
  const globalStatePath = path.join(fakeHome, ".codex-global-state.json");
  const plistPath = path.join(fakeLaunchAgents, `com.${os.userInfo().username}.codex-model-gateway.plist`);

  fs.writeFileSync(configPath, [
    '# fake Codex config for Tatwo host rehearsal only',
    'model_provider = "model_gateway"',
    'service_tier = "fast"',
    'model_auto_compact_token_limit_scope = "total"',
    ''
  ].join("\n"), { mode: 0o600 });
  fs.writeFileSync(statePath, "fake sqlite bytes for rehearsal\n", { mode: 0o600 });
  fs.writeFileSync(modelsCachePath, JSON.stringify({ provider: "model_gateway", models: ["gpt-5.5", "minimax-m3", "grok-build"] }, null, 2), { mode: 0o600 });
  fs.writeFileSync(globalStatePath, JSON.stringify({ tatwo: "fake global state only" }, null, 2), { mode: 0o600 });
  fs.writeFileSync(plistPath, "<plist><dict><key>Label</key><string>fake-gateway</string></dict></plist>\n", { mode: 0o600 });

  initialHashes = hashFiles({ configPath, statePath, modelsCachePath, globalStatePath, plistPath });
  checks.push(check("isolated-home-created", true, "fake HOME/CODEX_HOME under rehearsal root", "Created an isolated fake host tree; no real host path is a write target."));

  const backupTargets = [
    [configPath, "config.toml"],
    [statePath, "state_5.sqlite"],
    [modelsCachePath, "models_cache.json"],
    [globalStatePath, "codex-global-state.json"],
    [plistPath, "codex-model-gateway.plist"]
  ];
  for (const [src, name] of backupTargets) fs.copyFileSync(src, path.join(backupRoot, name));
  checks.push(check("backup-created-in-sandbox", backupTargets.every(([, name]) => fs.existsSync(path.join(backupRoot, name))), "allowlisted fake config/state/cache copied", "Backup rehearsal copies only allowlisted fake files."));

  const mcpBlock = [
    "",
    "[mcp_servers.tatwo_ultrawork]",
    'command = "node"',
    `args = ["${escapeToml(serverPath)}"]`,
    `[mcp_servers.tatwo_ultrawork.env]`,
    `TATWO_ULTRAWORK_STATE_DIR = "${escapeToml(tatwoState)}"`,
    ""
  ].join("\n");
  fs.appendFileSync(configPath, mcpBlock, { mode: 0o600 });
  const registeredConfig = fs.readFileSync(configPath, "utf8");
  const registeredOnlyInSandbox = registeredConfig.includes("mcp_servers.tatwo_ultrawork") && registeredConfig.includes(serverPath);
  checks.push(check("mcp-config-mutated-only-in-sandbox", registeredOnlyInSandbox, "fake config contains Tatwo MCP block", "The rehearsal mutates only the fake config, not real ~/.codex/config.toml."));

  const mcpInvocation = inheritedOuterSandbox ? [
    process.execPath,
    [
      path.join(scriptDir, "tatwo-host-mcp-registration-smoke.mjs"),
      "--json",
    ],
  ] : [
    "/usr/bin/sandbox-exec",
    [
      "-f",
      sandboxProfilePath,
      process.execPath,
      path.join(scriptDir, "tatwo-host-mcp-registration-smoke.mjs"),
      "--json",
    ],
  ];
  const mcpSmoke = spawnSync(mcpInvocation[0], mcpInvocation[1], {
    cwd: repoRoot,
    env: isolatedChildEnvironment(),
    encoding: "utf8",
    timeout: hostRehearsalMcpProcessTimeoutMS(),
    maxBuffer: 10 * 1024 * 1024
  });
  mcpReport = parseJSON(mcpSmoke.stdout || mcpSmoke.stderr || "");
  const mcpPassed = mcpSmoke.status === 0 && mcpReport?.schema === "TatwoHostMCPRegistrationSmokeReceiptV1" && mcpReport?.passed === true;
  checks.push(check("mcp-stdio-compatibility", mcpPassed, mcpPassed ? `toolCount=${mcpReport.toolCount}` : `exit=${mcpSmoke.status}`, "MCP tools/list and a safe tool call work from the rehearsal path."));

  for (const [destName, srcName] of [
    ["config.toml", "config.toml"],
    ["state_5.sqlite", "state_5.sqlite"],
    ["models_cache.json", "models_cache.json"],
    ["codex-global-state.json", "codex-global-state.json"],
    ["codex-model-gateway.plist", "codex-model-gateway.plist"]
  ]) {
    const source = path.join(backupRoot, srcName);
    const dest = destName === "codex-global-state.json"
      ? globalStatePath
      : destName === "codex-model-gateway.plist"
        ? plistPath
        : path.join(fakeCodexHome, destName);
    fs.copyFileSync(source, dest);
  }
  rollbackHashes = hashFiles({ configPath, statePath, modelsCachePath, globalStatePath, plistPath });
  const rollbackValidated = JSON.stringify(initialHashes) === JSON.stringify(rollbackHashes);
  checks.push(check("rollback-restores-sandbox-hashes", rollbackValidated, rollbackValidated ? "hashes_restored" : "hash_mismatch", "Rollback rehearsal restores fake host config/state/cache to pre-install hashes."));

  const writeTargets = [
    fakeCodexHome,
    fakeLaunchAgents,
    fakeAppData,
    backupRoot,
    tatwoState,
    fakeTemp,
    fakeSwiftScratch,
    sandboxProfilePath,
  ];
  const writeTargetsScoped = writeTargets.every(target => isSameOrWithin(target, rehearsalRoot));
  const sandboxProtection = verifySandboxProtection();
  const mcpSandboxEnforced =
    mcpSmoke.status === 0
    && fs.existsSync(sandboxProfilePath)
    && sandboxProtection.passed;
  checks.push(check(
    "protected-surface-enforcement",
    writeTargetsScoped && mcpSandboxEnforced,
    [
      `writeTargetsScoped=${writeTargetsScoped}`,
      `mcpSandboxEnforced=${mcpSandboxEnforced}`,
      `sandboxMode=${inheritedOuterSandbox ? "inherited_outer" : "standalone_inner"}`,
      `writeDenied=${sandboxProtection.writeDenied}`,
      `privateReadDenied=${sandboxProtection.privateReadDenied}`,
    ].join(", "),
    "All rehearsal writes stay under the rehearsal root and the MCP child is constrained by a macOS sandbox profile plus fake HOME/CODEX_HOME."
  ));
  const realHostMutationPerformed = !(writeTargetsScoped && mcpSandboxEnforced);
  const liveSameThreadReceiptProduced = false;
  const mcpCompatibilityPassed = mcpReport?.passed === true && mcpReport?.registrationMutationPerformed === false;
  const passed = checks.every(item => item.passed) && !realHostMutationPerformed && !liveSameThreadReceiptProduced;
  const receiptID = passed ? `rehearsal-${shortHash(JSON.stringify({ initialHashes, rollbackHashes, mcp: mcpReport?.receiptID }))}` : null;

  report = {
    schema: "TatwoHostSandboxRehearsalReceiptV1",
    passed,
    receiptID,
    hostMutationAllowed: false,
    realHostMutationPerformed,
    rehearsalMutationPerformed: true,
    rehearsalScope: "isolated_fake_home_and_fake_codex_home_only",
    rehearsalRootHint: publicPath(rehearsalRoot),
    cleanupPerformed: !keep,
    generatedAt: now.toISOString(),
    checks,
    mcpCompatibilityPassed,
    mcpCompatibilityReceiptID: mcpReport?.receiptID ?? null,
    rollbackValidated,
    liveSameThreadReceiptProduced,
    hostInstallAllowed: false,
    hostInstallBlockedBy: [
      "rehearsal_is_not_live_host_install",
      "human_approval_required",
      "real_host_backup_not_observed",
      "live_same_thread_smoke_not_observed",
      "mcp_registration_on_host_not_observed"
    ],
    deniedActions: [
      "does not write real ~/.codex",
      "does not write real LaunchAgents",
      "does not read auth/session/token material",
      "does not patch signed Codex App bundle",
      "does not count as live same-thread smoke"
    ],
    redactionScanPassed: true,
    plainSummary: passed
      ? "Host install logic rehearsed inside a fake HOME/CODEX_HOME: backup, MCP config mutation, MCP stdio smoke, and rollback worked without touching the real host. This is still not a live host install receipt."
      : "Host sandbox rehearsal failed; do not proceed to host install."
  };

  const redactedText = JSON.stringify(report);
  const redactionScanPassed = !/(sk-[A-Za-z0-9_-]{8,}|access_token|refresh_token|Authorization: Bearer|auth\.json|\/Users\/|\/Volumes\/)/i.test(redactedText);
  report.redactionScanPassed = redactionScanPassed;
  if (!redactionScanPassed) {
    report.passed = false;
    report.receiptID = null;
    report.checks.push(check("report-redaction", false, "sensitive-looking text detected", "Rehearsal reports must not expose private paths or auth/session material."));
  } else {
    report.checks.push(check("report-redaction", true, "passed", "Rehearsal report contains no obvious token/auth/private-path strings."));
  }
} catch (caught) {
  error = String(caught?.message ?? caught);
  report = {
    schema: "TatwoHostSandboxRehearsalReceiptV1",
    passed: false,
    receiptID: null,
    hostMutationAllowed: false,
    realHostMutationPerformed: false,
    rehearsalMutationPerformed: true,
    rehearsalScope: "isolated_fake_home_and_fake_codex_home_only",
    rehearsalRootHint: publicPath(rehearsalRoot),
    cleanupPerformed: !keep,
    generatedAt: now.toISOString(),
    checks,
    error: sanitize(error),
    mcpCompatibilityPassed: false,
    rollbackValidated: false,
    liveSameThreadReceiptProduced: false,
    hostInstallAllowed: false,
    hostInstallBlockedBy: ["host_sandbox_rehearsal_failed"],
    deniedActions: ["does not write real ~/.codex", "does not write real LaunchAgents", "does not read auth/session/token material"],
    redactionScanPassed: true,
    plainSummary: "Host sandbox rehearsal failed; do not proceed to host install."
  };
} finally {
  if (!keep) fs.rmSync(rehearsalRoot, { recursive: true, force: true });
}

console.log(JSON.stringify(report, null, 2));
process.exit(report.passed ? 0 : 1);

function hashFiles(files) {
  const out = {};
  for (const [key, file] of Object.entries(files)) {
    out[key] = shortHash(fs.readFileSync(file));
  }
  return out;
}

function check(id, passed, observed, description) {
  return { id, passed: Boolean(passed), observed: sanitize(String(observed)), description };
}

function parseJSON(text) {
  const start = String(text).indexOf("{");
  if (start < 0) return null;
  try { return JSON.parse(String(text).slice(start)); }
  catch { return null; }
}

function shortHash(value) {
  return crypto.createHash("sha256").update(value).digest("hex").slice(0, 12);
}

function publicPath(value) {
  const normalized = String(value);
  if (normalized.startsWith(rehearsalRoot)) return normalized.replace(rehearsalRoot, "<rehearsal-root>");
  if (normalized.startsWith(repoRoot)) return normalized.replace(repoRoot, "<repo-root>");
  return sanitize(normalized);
}

function sanitize(value) {
  return String(value)
    .replaceAll(rehearsalRoot, "<rehearsal-root>")
    .replaceAll(repoRoot, "<repo-root>")
    .replaceAll(os.homedir(), "$HOME")
    .replace(/\/Users\/[^\s"']+/g, "<local-path>")
    .replace(/\/Volumes\/[^\s"']+/g, "<local-path>")
    .replace(/sk-[A-Za-z0-9_-]{8,}/g, "<token>")
    .replace(/Authorization: Bearer [A-Za-z0-9._-]+/gi, "Authorization: Bearer <redacted>")
    .replace(/auth\.json/gi, "<private-auth-material>");
}

function escapeToml(value) {
  return String(value).replace(/\\/g, "\\\\").replace(/"/g, "\\\"");
}

function isolatedChildEnvironment() {
  const environment = {};
  for (const key of ["PATH", "SHELL", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "DEVELOPER_DIR", "SDKROOT"]) {
    if (process.env[key]) environment[key] = process.env[key];
  }
  return {
    ...environment,
    HOME: fakeHome,
    CFFIXED_USER_HOME: fakeHome,
    CODEX_HOME: fakeCodexHome,
    TMPDIR: `${fakeTemp}${path.sep}`,
    GIT_OPTIONAL_LOCKS: "0",
    TATWO_ULTRAWORK_STATE_DIR: tatwoState,
    TATWO_SWIFT_SCRATCH_PATH: fakeSwiftScratch,
    TATWO_OUTER_SANDBOX: "1",
    TATWO_MCP_TOOL_TIMEOUT_MS: String(hostRehearsalMcpToolTimeoutMS()),
  };
}

function hostRehearsalMcpToolTimeoutMS() {
  const raw = Number(process.env.TATWO_HOST_REHEARSAL_MCP_TOOL_TIMEOUT_MS ?? "180000");
  return Number.isFinite(raw) && raw >= 30000 ? raw : 180000;
}

function hostRehearsalMcpProcessTimeoutMS() {
  const raw = Number(process.env.TATWO_HOST_REHEARSAL_MCP_TIMEOUT_MS ?? "240000");
  const configured = Number.isFinite(raw) && raw >= 60000 ? raw : 240000;
  return Math.max(configured, hostRehearsalMcpToolTimeoutMS() + 30000);
}

function writeSandboxProfile(target) {
  const realHome = os.homedir();
  const profile = [
    "(version 1)",
    "(allow default)",
    `(deny file-read* (subpath ${JSON.stringify(path.join(realHome, ".codex"))}))`,
    `(deny file-read* (subpath ${JSON.stringify(path.join(realHome, "Library", "Keychains"))}))`,
    `(deny file-read* (subpath ${JSON.stringify(path.join(realHome, "Library", "Application Support", "Tatwo Ultrawork"))}))`,
    `(deny file-write* (subpath ${JSON.stringify(path.join(realHome, ".codex"))}))`,
    `(deny file-write* (subpath ${JSON.stringify(path.join(realHome, "Library", "LaunchAgents"))}))`,
    `(deny file-write* (subpath ${JSON.stringify(path.join(realHome, "Library", "Application Support", "Tatwo Ultrawork"))}))`,
    '(deny file-write* (subpath "/Applications"))',
    '(deny file-write* (subpath "/Library/LaunchAgents"))',
    '(deny file-write* (subpath "/Library/LaunchDaemons"))',
    '(deny process-exec (literal "/usr/bin/security"))',
    '(deny mach-lookup (global-name "com.apple.securityd"))',
    "",
  ].join("\n");
  fs.writeFileSync(target, profile, { flag: "wx", mode: 0o600 });
}

function verifySandboxProtection() {
  const deniedWritePath = `/Applications/.tatwo-host-rehearsal-denied-${process.pid}`;
  const writeExpression = [
    'const fs = require("node:fs");',
    `fs.writeFileSync(${JSON.stringify(deniedWritePath)}, "denied\\n");`,
  ].join("");
  const privateReadPath = path.join(os.userInfo().homedir, ".codex");
  const readExpression = [
    'const fs = require("node:fs");',
    `fs.readdirSync(${JSON.stringify(privateReadPath)});`,
  ].join("");
  const invoke = (expression) => {
    const command = inheritedOuterSandbox ? process.execPath : "/usr/bin/sandbox-exec";
    const commandArgs = inheritedOuterSandbox
      ? ["-e", expression]
      : ["-f", sandboxProfilePath, process.execPath, "-e", expression];
    return spawnSync(command, commandArgs, {
      cwd: repoRoot,
      env: isolatedChildEnvironment(),
      encoding: "utf8",
    });
  };
  const deniedWrite = invoke(writeExpression);
  const deniedRead = invoke(readExpression);
  const writeDenied =
    deniedWrite.status !== 0
    && !fs.existsSync(deniedWritePath)
    && /operation not permitted|eperm/i.test(String(deniedWrite.stderr));
  const privateReadDenied =
    deniedRead.status !== 0
    && /operation not permitted|eperm/i.test(String(deniedRead.stderr));
  return {
    passed: writeDenied && privateReadDenied,
    writeDenied,
    privateReadDenied,
  };
}

function isSameOrWithin(candidate, root) {
  const relative = path.relative(root, candidate);
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith("--")) continue;
    const eq = arg.indexOf("=");
    if (eq >= 0) out[arg.slice(2, eq)] = arg.slice(eq + 1);
    else out[arg.slice(2)] = argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[++i] : true;
  }
  return out;
}
