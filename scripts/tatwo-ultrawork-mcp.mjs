#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import { fileURLToPath } from "node:url";
import path from "node:path";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const debugLogPath = process.env.TATWO_MCP_DEBUG_LOG || "";

const tatwoOSRoot = resolveTatwoOSRoot();
const tatwoOSAdaptersDir = tatwoOSRoot ? path.join(tatwoOSRoot, "adapters") : null;

function resolveTatwoOSRoot() {
  const raw = process.env.TATWO_OS_ROOT;
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed ? trimmed : null;
}

function debugLog(event) {
  if (!debugLogPath) return;
  try {
    fs.appendFileSync(debugLogPath, `${new Date().toISOString()} ${JSON.stringify(event)}\n`);
  } catch {}
}

debugLog({ event: "start", pid: process.pid, argv: process.argv, cwd: process.cwd() });

let inputBuffer = Buffer.alloc(0);
let transportMode = "framed";

process.stdin.on("data", (chunk) => {
  debugLog({ event: "stdin", bytes: chunk.length, preview: chunk.slice(0, 80).toString("utf8") });
  inputBuffer = Buffer.concat([inputBuffer, chunk]);
  drainMessages();
});

process.stdin.resume();

function drainMessages() {
  while (true) {
    const boundary = findHeaderBoundary(inputBuffer);
    if (!boundary) {
      if (drainRawJSONMessage()) continue;
      return;
    }

    const header = inputBuffer.slice(0, boundary.headerEnd).toString("utf8");
    const match = header.match(/Content-Length:\s*(\d+)/i);
    if (!match) {
      inputBuffer = inputBuffer.slice(boundary.bodyStart);
      continue;
    }

    transportMode = "framed";
    const length = Number(match[1]);
    const bodyStart = boundary.bodyStart;
    const bodyEnd = bodyStart + length;
    if (inputBuffer.length < bodyEnd) return;

    const body = inputBuffer.slice(bodyStart, bodyEnd).toString("utf8");
    inputBuffer = inputBuffer.slice(bodyEnd);
    handleMessage(body);
  }
}

function drainRawJSONMessage() {
  const text = inputBuffer.toString("utf8");
  const trimmed = text.trim();
  if (!trimmed || !trimmed.startsWith("{")) return false;

  const newlineIndex = text.indexOf("\n");
  if (newlineIndex >= 0) {
    const line = text.slice(0, newlineIndex).trim();
    if (!line) {
      inputBuffer = Buffer.from(text.slice(newlineIndex + 1), "utf8");
      return true;
    }
    try {
      JSON.parse(line);
      transportMode = "ndjson";
      inputBuffer = Buffer.from(text.slice(newlineIndex + 1), "utf8");
      handleMessage(line);
      return true;
    } catch {
      return false;
    }
  }

  try {
    JSON.parse(trimmed);
    transportMode = "ndjson";
    inputBuffer = Buffer.alloc(0);
    handleMessage(trimmed);
    return true;
  } catch {
    return false;
  }
}

function findHeaderBoundary(buffer) {
  const crlf = buffer.indexOf("\r\n\r\n");
  const lf = buffer.indexOf("\n\n");

  if (crlf < 0 && lf < 0) return null;
  if (crlf >= 0 && (lf < 0 || crlf <= lf)) {
    return { headerEnd: crlf, bodyStart: crlf + 4 };
  }
  return { headerEnd: lf, bodyStart: lf + 2 };
}

function handleMessage(body) {
  let request;
  try {
    request = JSON.parse(body);
  } catch (error) {
    sendError(null, -32700, `parse error: ${error.message}`);
    return;
  }

  debugLog({ event: "message", method: request.method, id: request.id ?? null });

  if (request.id === undefined || request.id === null) return;

  try {
    switch (request.method) {
      case "initialize":
        sendResult(request.id, {
          protocolVersion: request.params?.protocolVersion ?? "2024-11-05",
          capabilities: { tools: {}, prompts: {}, resources: {} },
          serverInfo: { name: "tatwo-ultrawork", version: "0.1.0" }
        });
        break;
      case "ping":
        sendResult(request.id, {});
        break;
      case "tools/list":
        sendResult(request.id, { tools });
        break;
      case "prompts/list":
        sendResult(request.id, { prompts: [] });
        break;
      case "resources/list":
        sendResult(request.id, { resources: [] });
        break;
      case "tools/call":
        void handleToolCall(request).catch((error) => {
          sendError(request.id, -32603, error?.message ?? String(error));
        });
        break;
      default:
        sendError(request.id, -32601, `unknown method: ${request.method}`);
    }
  } catch (error) {
    sendError(request.id, -32603, error?.message ?? String(error));
  }
}


function runTatwoOSAdapter(scriptName, args = []) {
  if (!tatwoOSRoot || !tatwoOSAdaptersDir) {
    return {
      status: 127,
      stdout: "",
      stderr: "TATWO_OS_ADAPTER_COMPAT requires TATWO_OS_ROOT to be set; refusing private-path fallback"
    };
  }
  const script = path.join(tatwoOSAdaptersDir, scriptName);
  if (!fs.existsSync(script)) {
    return { status: 127, stdout: "", stderr: `missing TATWO OS adapter: ${script}` };
  }
  return spawnSync(process.execPath, [script, ...args], {
    cwd: tatwoOSRoot,
    encoding: "utf8",
    maxBuffer: 10 * 1024 * 1024,
    timeout: Math.max(toolTimeoutMS(), 120000)
  });
}

const mcpFailureTerminalStatuses = new Set([
  "failed",
  "incomplete",
  "cancelled",
  "canceled",
  "error",
]);

function processResultText(result) {
  return (result?.stdout || result?.stderr || "").trim();
}

function parseStrictJSONPayload(text) {
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function hasReportedError(value) {
  if (value === undefined || value === null || value === false || value === 0) return false;
  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase().replaceAll("-", "_").replaceAll(" ", "_");
    return ![
      "",
      "none",
      "no_error",
      "noerror",
      "null",
      "nil",
      "false",
      "ok",
      "success",
      "succeeded",
      "completed",
    ].includes(normalized);
  }
  if (Array.isArray(value)) {
    return value.some((item) => hasReportedError(item));
  }
  if (typeof value === "object") {
    const entries = Object.entries(value);
    if (entries.length === 0) return false;
    return entries.some(([, fieldValue]) => hasReportedError(fieldValue));
  }
  return value === true || (typeof value === "number" && value !== 0);
}

function inspectMCPJSONPayload(payload) {
  const findings = {
    terminalStatus: null,
    okFalse: false,
    successFalse: false,
    degraded: false,
    hasError: false,
  };
  if (payload === null || typeof payload !== "object") return findings;

  const stack = [payload];
  const visited = new Set();
  while (stack.length > 0) {
    const value = stack.pop();
    if (value === null || typeof value !== "object" || visited.has(value)) continue;
    visited.add(value);

    if (Array.isArray(value)) {
      for (const item of value) stack.push(item);
      continue;
    }

    for (const [key, fieldValue] of Object.entries(value)) {
      const normalizedKey = key.toLowerCase();
      if (
        normalizedKey === "status"
        || normalizedKey === "terminalstatus"
        || normalizedKey === "terminal_status"
      ) {
        const normalizedStatus = String(fieldValue ?? "").trim().toLowerCase();
        if (mcpFailureTerminalStatuses.has(normalizedStatus)) {
          findings.terminalStatus ??= normalizedStatus;
        }
      } else if (normalizedKey === "ok" && fieldValue === false) {
        findings.okFalse = true;
      } else if (normalizedKey === "success" && fieldValue === false) {
        findings.successFalse = true;
      } else if (normalizedKey === "degraded" && fieldValue === true) {
        findings.degraded = true;
      } else if (
        (normalizedKey === "error"
          || normalizedKey === "errors"
          || normalizedKey === "error_kind"
          || normalizedKey === "errorkind")
        && hasReportedError(fieldValue)
      ) {
        findings.hasError = true;
      } else if (
        (normalizedKey === "has_error" || normalizedKey === "haserror")
        && fieldValue === true
      ) {
        findings.hasError = true;
      }

      if (fieldValue !== null && typeof fieldValue === "object") {
        stack.push(fieldValue);
      }
    }
  }
  return findings;
}

function classifyMCPProcessResult(result, text = processResultText(result)) {
  const processFailed = result?.status !== 0;
  const payload = parseStrictJSONPayload(text);
  const structuredJSON =
    payload !== null
    && typeof payload === "object";
  const findings = inspectMCPJSONPayload(payload);
  const payloadFailed = Boolean(
    findings.terminalStatus
    || findings.okFalse
    || findings.successFalse
    || findings.degraded
    || findings.hasError
  );
  return {
    isError: processFailed || !structuredJSON || payloadFailed,
    classification: processFailed
      ? "process_failed"
      : !text
        ? "empty_output"
        : !structuredJSON
          ? "invalid_json_contract"
      : findings.terminalStatus
        ? `terminal_${findings.terminalStatus}`
        : payloadFailed
          ? "json_error"
          : "json_success",
    terminalStatus: findings.terminalStatus,
  };
}

function mcpProcessToolResult(result, text = processResultText(result)) {
  const verdict = classifyMCPProcessResult(result, text);
  let contentText = text || "{}";
  if (verdict.isError) {
    const payload = parseStrictJSONPayload(text);
    if (payload !== null && typeof payload === "object" && !Array.isArray(payload)) {
      const reportedStatus = String(payload.status ?? "").trim().toLowerCase();
      const reportsTopLevelSuccess = (
        ["completed", "success", "succeeded", "passed"].includes(reportedStatus)
        || payload.ok === true
        || payload.success === true
      );
      if (reportsTopLevelSuccess) {
        const normalized = { ...payload, ok: false };
        normalized.status = "failed";
        if (normalized.success === true) normalized.success = false;
        contentText = JSON.stringify(normalized, null, 2);
      }
    } else if (verdict.classification === "empty_output" || verdict.classification === "invalid_json_contract") {
      contentText = JSON.stringify({
        ok: false,
        status: "failed",
        error: "invalid_cli_json_output",
        classification: verdict.classification,
      }, null, 2);
    }
  }
  return {
    content: [{ type: "text", text: contentText }],
    isError: verdict.isError,
  };
}

function appendOSOption(out, flag, value) {
  if (value === undefined || value === null || value === "") return;
  out.push(flag, String(value));
}

function swiftToolEnv(extra = {}) {
  const env = { ...process.env, ...extra };
  if (tatwoOSRoot) env.TATWO_OS_ROOT = tatwoOSRoot;
  return env;
}

function swiftRunInvocation(cliArgs) {
  const out = ["run"];
  if (process.env.TATWO_OUTER_SANDBOX === "1") {
    out.push("--disable-sandbox", "-Xswiftc", "-disable-sandbox");
  }
  out.push("--package-path", repoRoot);
  const scratchPath = String(process.env.TATWO_SWIFT_SCRATCH_PATH || "").trim();
  if (scratchPath) out.push("--scratch-path", scratchPath);
  out.push("tatwo-ultrawork", ...cliArgs);
  return out;
}

function handleTatwoOSRootTool(request, name, args) {
  const mode = String(args.mode ?? "XL");
  const scenario = String(args.scenario ?? "architecture");
  const objective = String(args.objective ?? args.goal ?? "TATWO Ultrawork OS goal");
  let result = null;
  if (name === "tatwo_os_begin" || name === "tatwo.os.begin") {
    // Formal begin must go through the Swift authority transaction below.
    // The compatibility adapter has no owner/session/registry authority chain.
    return false;
  } else if (name === "tatwo_os_receipt_submit" || name === "tatwo.os.receipt.submit") {
    const out = ["receipt"];
    appendOSOption(out, "--contract", args.contractID ?? args.contract);
    appendOSOption(out, "--receipt", args.receiptID ?? args.receipt);
    appendOSOption(out, "--kind", args.receiptKind ?? args.kind);
    appendOSOption(out, "--status", args.status);
    appendOSOption(out, "--ref", args.ref ?? args.outputRef ?? args.evidenceRef);
    result = runTatwoOSAdapter("os-contract.mjs", out);
  } else if (name === "tatwo_os_goal_close" || name === "tatwo.os.goal.close") {
    const out = ["close"];
    appendOSOption(out, "--contract", args.contractID ?? args.contract);
    if (args.allowMissingCleanup === true) out.push("--allow-missing-cleanup");
    result = runTatwoOSAdapter("os-contract.mjs", out);
  } else if (name === "tatwo_handoff_pack" || name === "tatwo_os_handoff" || name === "tatwo.os.handoff") {
    const out = [];
    appendOSOption(out, "--contract", args.contractID ?? args.contract);
    appendOSOption(out, "--project", args.projectPath ?? args.project);
    result = runTatwoOSAdapter("handoff-pack.mjs", out);
  } else {
    return false;
  }
  const text = (result.stdout || result.stderr || "").trim();
  sendResult(request.id, mcpProcessToolResult(result, text));
  return true;
}

const codeHealthRuleIDs = Object.freeze(["CH-01", "CH-02", "CH-03", "CH-04", "CH-05", "CH-06"]);

function isPathWithin(candidate, allowedRoot) {
  const rel = path.relative(allowedRoot, candidate);
  return rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
}

function realpathAllowMissing(inputPath) {
  const absolute = path.resolve(inputPath);
  const missing = [];
  let cursor = absolute;
  while (!fs.existsSync(cursor)) {
    const parent = path.dirname(cursor);
    if (parent === cursor) break;
    missing.unshift(path.basename(cursor));
    cursor = parent;
  }
  const resolvedBase = fs.existsSync(cursor) ? fs.realpathSync(cursor) : cursor;
  return path.join(resolvedBase, ...missing);
}

function injectedRoots(envName) {
  return String(process.env[envName] || "")
    .split(path.delimiter)
    .map(value => value.trim())
    .filter(Boolean)
    .map(realpathAllowMissing);
}

function resolveCodeHealthRoot(rawRoot) {
  if (rawRoot !== undefined && typeof rawRoot !== "string") {
    throw new Error("code-health root must be a string");
  }
  const requested = typeof rawRoot === "string" && rawRoot.trim()
    ? path.resolve(repoRoot, rawRoot.trim())
    : path.resolve(repoRoot);
  if (!fs.existsSync(requested) || !fs.statSync(requested).isDirectory()) {
    throw new Error(`code-health root does not exist or is not a directory: ${requested}`);
  }
  const candidate = fs.realpathSync(requested);
  const allowedRoots = [
    fs.realpathSync(repoRoot),
    ...injectedRoots("TATWO_CODE_HEALTH_ALLOWED_ROOTS")
  ];
  if (!allowedRoots.some(allowed => isPathWithin(candidate, allowed))) {
    throw new Error("code-health root rejected: outside repository/injected allowlist");
  }
  return candidate;
}

function resolveCodeHealthStateDir() {
  const configured = String(process.env.TATWO_SECURITY_STATE_DIR || "").trim();
  const candidate = realpathAllowMissing(configured || path.join(repoRoot, ".tatwo-security"));
  const home = realpathAllowMissing(os.homedir());
  if (isPathWithin(candidate, home)) {
    throw new Error("code-health state directory rejected: user home writes are forbidden");
  }
  const allowedRoots = [
    fs.realpathSync(repoRoot),
    realpathAllowMissing(os.tmpdir()),
    realpathAllowMissing("/tmp"),
  ];
  if (!allowedRoots.some(allowed => isPathWithin(candidate, allowed))) {
    throw new Error("code-health state directory rejected: outside repository/temp/injected allowlist");
  }
  return candidate;
}

function normalizeCodeHealthRules(value) {
  if (
    value !== undefined &&
    typeof value !== "string" &&
    !Array.isArray(value)
  ) {
    throw new Error("code-health rules must be a string or string array");
  }
  if (Array.isArray(value) && value.some(rule => typeof rule !== "string")) {
    throw new Error("code-health rules array must contain only strings");
  }
  const requested = Array.isArray(value)
    ? value
    : typeof value === "string"
      ? value.split(",")
      : codeHealthRuleIDs;
  const normalized = [...new Set(requested.map(rule => String(rule).trim().toUpperCase()).filter(Boolean))];
  if (normalized.length === 0) throw new Error("code-health rules must not be empty");
  const invalid = normalized.filter(rule => !codeHealthRuleIDs.includes(rule));
  if (invalid.length) throw new Error(`unsupported code-health rules: ${invalid.join(", ")}`);
  return normalized.sort();
}

function parseJSONOutput(result, label) {
  const text = String(result.stdout || "").trim();
  if (result.status !== 0) {
    throw new Error(`${label} failed: ${(result.stderr || text || `exit ${result.status}`).trim()}`);
  }
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`${label} returned invalid JSON: ${error.message}`);
  }
}

function runSecurityFindings(stateDir, args) {
  const result = spawnSync(
    process.execPath,
    [path.join(repoRoot, "scripts", "tatwo-security-findings.mjs"), ...args],
    {
      cwd: repoRoot,
      env: { ...process.env, TATWO_SECURITY_STATE_DIR: stateDir },
      encoding: "utf8",
      maxBuffer: 20 * 1024 * 1024,
      timeout: Math.max(toolTimeoutMS(), 120000)
    }
  );
  return parseJSONOutput(result, `security findings ${args[0] || "command"}`);
}

function codeHealthRuleFromFindingID(id) {
  const match = /^ch-(ch-\d{2})-/i.exec(String(id || ""));
  return match ? match[1].toUpperCase() : null;
}

function codeHealthRootIdentity(scanRoot) {
  return crypto.createHash("sha256").update(scanRoot, "utf8").digest("hex");
}

function sleepSync(ms) {
  const buffer = new SharedArrayBuffer(4);
  Atomics.wait(new Int32Array(buffer), 0, 0, ms);
}

function codeHealthLockOwner(lockDir) {
  try {
    const raw = fs.readFileSync(path.join(lockDir, "owner.pid"), "utf8").trim();
    return /^\d+$/.test(raw) ? Number(raw) : null;
  } catch {
    return null;
  }
}

function isLivePID(pid) {
  if (!Number.isInteger(pid) || pid < 1) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function acquireCodeHealthLock(stateDir, timeoutMS = 30000) {
  fs.mkdirSync(stateDir, { recursive: true });
  const lockDir = path.join(stateDir, "code-health.lock");
  const started = Date.now();
  for (;;) {
    const claimDir = path.join(
      stateDir,
      `code-health.lock.claim.${process.pid}.${Date.now()}.${crypto.randomBytes(4).toString("hex")}`
    );
    try {
      fs.mkdirSync(claimDir);
      fs.writeFileSync(path.join(claimDir, "owner.pid"), `${process.pid}\n`, "utf8");
      fs.writeFileSync(path.join(claimDir, "acquired_at"), `${new Date().toISOString()}\n`, "utf8");
      try {
        fs.renameSync(claimDir, lockDir);
        return lockDir;
      } catch {
        try {
          fs.unlinkSync(path.join(claimDir, "owner.pid"));
          fs.unlinkSync(path.join(claimDir, "acquired_at"));
          fs.rmdirSync(claimDir);
        } catch {}
      }
    } catch (error) {
      try {
        fs.unlinkSync(path.join(claimDir, "owner.pid"));
      } catch {}
      try {
        fs.unlinkSync(path.join(claimDir, "acquired_at"));
      } catch {}
      try {
        fs.rmdirSync(claimDir);
      } catch {}
      if (!error || error.code !== "EEXIST") throw error;
    }
    const owner = codeHealthLockOwner(lockDir);
    if (owner !== null && !isLivePID(owner)) {
      const stale = `${lockDir}.stale.${Date.now()}.${process.pid}`;
      try {
        fs.renameSync(lockDir, stale);
        try {
          fs.unlinkSync(path.join(stale, "owner.pid"));
        } catch {}
        try {
          fs.unlinkSync(path.join(stale, "acquired_at"));
        } catch {}
        try {
          fs.rmdirSync(stale);
        } catch {}
        continue;
      } catch {}
    }
    if (Date.now() - started >= timeoutMS) {
      throw new Error(`code-health reconciliation lock timeout; holder pid=${owner ?? "?"}`);
    }
    sleepSync(20);
  }
}

function releaseCodeHealthLock(lockDir) {
  try {
    if (codeHealthLockOwner(lockDir) !== process.pid) return;
    fs.unlinkSync(path.join(lockDir, "owner.pid"));
    try {
      fs.unlinkSync(path.join(lockDir, "acquired_at"));
    } catch {}
    fs.rmdirSync(lockDir);
  } catch {}
}

function withCodeHealthLock(stateDir, fn) {
  const lockDir = acquireCodeHealthLock(stateDir);
  try {
    return fn();
  } finally {
    releaseCodeHealthLock(lockDir);
  }
}

function priorScopedFindingIDsByRule(stateDir, rootIdentity, selectedRules) {
  const scansDir = path.join(stateDir, "scans");
  const latestByRule = new Map();
  if (!fs.existsSync(scansDir)) return new Map();
  for (const name of fs.readdirSync(scansDir)) {
    if (!name.endsWith(".json")) continue;
    let record;
    try {
      record = JSON.parse(fs.readFileSync(path.join(scansDir, name), "utf8"));
    } catch {
      continue;
    }
    if (record?.scope?.rootIdentity !== rootIdentity) continue;
    const recordRules = Array.isArray(record?.scope?.rules) ? record.scope.rules : [];
    const finishedAt = String(record.finishedAt || "");
    for (const rule of selectedRules) {
      if (!recordRules.includes(rule)) continue;
      const previous = latestByRule.get(rule);
      if (previous && previous.finishedAt >= finishedAt) continue;
      const ids = new Set(
        (Array.isArray(record.findings) ? record.findings : [])
          .filter(finding => finding.ruleId === rule)
          .map(finding => finding.id)
      );
      latestByRule.set(rule, { finishedAt, ids });
    }
  }
  return latestByRule;
}

function findingIsActiveInAnotherScope(stateDir, rootIdentity, ruleID, findingID) {
  const scansDir = path.join(stateDir, "scans");
  const latestByRoot = new Map();
  if (!fs.existsSync(scansDir)) return false;
  for (const name of fs.readdirSync(scansDir)) {
    if (!name.endsWith(".json")) continue;
    let record;
    try {
      record = JSON.parse(fs.readFileSync(path.join(scansDir, name), "utf8"));
    } catch {
      continue;
    }
    const otherRoot = record?.scope?.rootIdentity;
    const recordRules = Array.isArray(record?.scope?.rules) ? record.scope.rules : [];
    if (!otherRoot || otherRoot === rootIdentity || !recordRules.includes(ruleID)) continue;
    const finishedAt = String(record.finishedAt || "");
    const previous = latestByRoot.get(otherRoot);
    if (previous && previous.finishedAt >= finishedAt) continue;
    latestByRoot.set(otherRoot, {
      finishedAt,
      active: (Array.isArray(record.findings) ? record.findings : [])
        .some(finding => finding.ruleId === ruleID && finding.id === findingID)
    });
  }
  return [...latestByRoot.values()].some(entry => entry.active);
}

function codeHealthRevisionStamp(scanRoot, revision) {
  const result = spawnSync(
    process.execPath,
    [
      path.join(repoRoot, "scripts", "tatwo-review-stamp.mjs"),
      "--effort",
      "MCP code-health scan",
      "--depth",
      "read-only"
    ],
    {
      cwd: scanRoot,
      encoding: "utf8",
      maxBuffer: 5 * 1024 * 1024,
      timeout: Math.max(toolTimeoutMS(), 30000)
    }
  );
  if (result.status === 0) {
    const line = String(result.stdout || "")
      .split(/\r?\n/)
      .map(value => value.trim())
      .find(value => value.startsWith("{") && value.endsWith("}"));
    if (line) {
      try {
        return JSON.parse(line);
      } catch {}
    }
  }
  return {
    schema: "TatwoCodeHealthRevisionStampV1",
    revision,
    rootKind: "allowlisted-non-git-fixture",
    testOnly: true,
    bindingClass: "fixture-unbound",
    verificationDepth: "read-only",
    generatedAt: new Date().toISOString()
  };
}

function writeExclusiveJSON(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const fd = fs.openSync(filePath, "wx");
  try {
    fs.writeFileSync(fd, `${JSON.stringify(payload, null, 2)}\n`, "utf8");
  } finally {
    fs.closeSync(fd);
  }
}

export function runCodeHealthScanTool(args = {}) {
  if (args === null || typeof args !== "object" || Array.isArray(args)) {
    throw new Error("code-health arguments must be an object");
  }
  if (args.jsonOnly !== undefined && typeof args.jsonOnly !== "boolean") {
    throw new Error("code-health jsonOnly must be a boolean");
  }
  const startedAt = new Date().toISOString();
  const scanRoot = resolveCodeHealthRoot(args.root);
  const stateDir = resolveCodeHealthStateDir();
  const rules = normalizeCodeHealthRules(args.rules);
  const scanner = spawnSync(
    process.execPath,
    [path.join(repoRoot, "scripts", "tatwo-code-health.mjs"), "scan", "--root", scanRoot, "--json"],
    {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 50 * 1024 * 1024,
      timeout: Math.max(toolTimeoutMS(), 120000)
    }
  );
  if (scanner.status !== 0) {
    throw new Error(`code-health scan failed: ${(scanner.stderr || scanner.stdout || `exit ${scanner.status}`).trim()}`);
  }

  const scannedFindings = String(scanner.stdout || "")
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)
    .map((line, index) => {
      try {
        return JSON.parse(line);
      } catch (error) {
        throw new Error(`code-health finding line ${index + 1} is invalid JSON: ${error.message}`);
      }
    })
    .filter(finding => rules.includes(String(finding.ruleId || "").toUpperCase()));
  const scannerSummaryLine = String(scanner.stderr || "")
    .split(/\r?\n/)
    .map(line => line.trim())
    .find(line => line.startsWith("{") && line.endsWith("}"));
  if (!scannerSummaryLine) throw new Error("code-health scan did not emit its JSON summary");
  const scannerSummary = JSON.parse(scannerSummaryLine);
  const scanID = `${scannerSummary.scanID}-${crypto.randomBytes(4).toString("hex")}`;
  const revision = String(scannerSummary.revision || "unknown");
  const rootIdentity = codeHealthRootIdentity(scanRoot);
  const findings = scannedFindings.map(finding => ({
    ...finding,
    scanID,
    revision,
    firstSeenScan: scanID,
    lastSeenScan: scanID
  }));

  const byRule = Object.fromEntries(rules.map(rule => [rule, 0]));
  const bySeverity = {};
  for (const finding of findings) {
    byRule[finding.ruleId] = (byRule[finding.ruleId] || 0) + 1;
    bySeverity[finding.severity] = (bySeverity[finding.severity] || 0) + 1;
  }
  return withCodeHealthLock(stateDir, () => {
    const priorByRule = priorScopedFindingIDsByRule(stateDir, rootIdentity, rules);
    const listed = runSecurityFindings(stateDir, ["list"]);
    if (Array.isArray(listed.forkedIds) && listed.forkedIds.length) {
      throw new Error(`security findings journal is forked: ${listed.forkedIds.join(", ")}`);
    }
    const latest = new Map((listed.findings || []).map(finding => [finding.id, finding]));
    const currentIDs = new Set(findings.map(finding => finding.id));
    let added = 0;
    let reopened = 0;
    let refreshed = 0;
    let carriedOpen = 0;
    let adjudicated = 0;
    let resolved = 0;

    for (const finding of findings) {
      const previous = latest.get(finding.id);
      if (!previous) {
        runSecurityFindings(stateDir, ["add", "--json", JSON.stringify(finding)]);
        added += 1;
        continue;
      }
      if (previous.status === "fixed") {
        runSecurityFindings(stateDir, [
          "mark", finding.id, "open", "--scan", scanID, "--verified-by", finding.verifiedBy
        ]);
        reopened += 1;
        continue;
      }
      if (previous.status === "open") {
        if (previous.revision === revision) {
          carriedOpen += 1;
        } else {
          runSecurityFindings(stateDir, [
            "mark", finding.id, "open", "--scan", scanID, "--verified-by", finding.verifiedBy
          ]);
          refreshed += 1;
        }
        continue;
      }
      // accepted / false_positive / superseded require human adjudication; never auto-reopen.
      adjudicated += 1;
    }

    for (const previous of latest.values()) {
      const ruleID = codeHealthRuleFromFindingID(previous.id);
      const priorIDs = ruleID ? priorByRule.get(ruleID)?.ids : null;
      if (
        previous.status === "open" &&
        ruleID &&
        priorIDs?.has(previous.id) &&
        !currentIDs.has(previous.id) &&
        !findingIsActiveInAnotherScope(stateDir, rootIdentity, ruleID, previous.id)
      ) {
        runSecurityFindings(stateDir, [
          "mark",
          previous.id,
          "fixed",
          "--scan",
          scanID,
          "--verified-by",
          `tatwo-code-health@${scannerSummary.rubricVersion || "unknown"}`
        ]);
        resolved += 1;
      }
    }

    const revisionStamp = codeHealthRevisionStamp(scanRoot, revision);
    const scanPath = path.join(stateDir, "scans", `${scanID}.json`);
    const journalPath = path.join(stateDir, "findings.jsonl");
    const finishedAt = new Date().toISOString();
    const scanRecord = {
      schema: "TatwoSecurityScanV1",
      scanID,
      startedAt,
      finishedAt,
      revision,
      revisionStamp,
      scope: { root: scanRoot, rootIdentity, rules },
      tools: [`tatwo-code-health@${scannerSummary.rubricVersion || "unknown"}`],
      depth: "read-only",
      summary: {
        total: findings.length,
        byRule,
        bySeverity,
        added,
        reopened,
        refreshed,
        carriedOpen,
        adjudicated,
        resolved,
        newOpen: added + reopened
      },
      findings,
      findingsJournalPath: journalPath,
      coverageRefs: ["docs/protocol/SECURITY_COVERAGE_TRACKING.md"]
    };
    writeExclusiveJSON(scanPath, scanRecord);

    return {
      schema: "TatwoCodeHealthMCPResultV1",
      ok: true,
      status: "completed",
      readOnlyScan: true,
      scanID,
      revision,
      rules,
      summary: scanRecord.summary,
      findingsPath: scanPath,
      findingsJournalPath: journalPath
    };
  });
}

export function codeHealthMCPToolResult(args = {}) {
  try {
    const receipt = runCodeHealthScanTool(args);
    return {
      content: [{
        type: "text",
        text: args.jsonOnly === true ? JSON.stringify(receipt) : JSON.stringify(receipt, null, 2)
      }],
      isError: false
    };
  } catch (error) {
    const failure = {
      schema: "TatwoCodeHealthMCPResultV1",
      ok: false,
      status: "failed",
      error: error?.message ?? String(error)
    };
    return {
      content: [{
        type: "text",
        text: args?.jsonOnly === true ? JSON.stringify(failure) : JSON.stringify(failure, null, 2)
      }],
      isError: true
    };
  }
}

async function handleToolCall(request) {
  const name = request.params?.name;
  const args = request.params?.arguments ?? {};
  // Work OS MCP tools must use the Swift CLI/TatwoMCPRegistry contract store by default.
  // The legacy TATWO_OS_ROOT adapters use a different contractID/state format
  // (`tatwo-...` under OS_ROOT/state) and caused direct-MCP vs CLI split-brain.
  if (process.env.TATWO_OS_ADAPTER_COMPAT === "1" && handleTatwoOSRootTool(request, name, args)) return;
  if (handleContextTool(request, name, args)) return;
  if (name === "tatwo_code_health_scan") {
    sendResult(request.id, codeHealthMCPToolResult(args));
    return;
  }
  if (name === "tatwo_host_sandbox_rehearsal") {
    const result = spawnSync("node", [path.join(repoRoot, "scripts", "tatwo-host-sandbox-rehearsal.mjs"), "--json"], {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 10 * 1024 * 1024,
      timeout: Math.max(toolTimeoutMS(), 120000)
    });
    const text = (result.stdout || result.stderr || "").trim();
    sendResult(request.id, mcpProcessToolResult(result, text));
    return;
  }
  if (name === "tatwo_host_verified_install_gate") {
    const out = ["--json"];
    appendOption(out, "--evidence-dir", args.evidenceDir);
    if (args.latest !== false) out.push("--latest");
    appendOption(out, "--human-approval", args.humanApprovalReceiptID);
    const result = spawnSync("node", [path.join(repoRoot, "scripts", "tatwo-host-install-verified-gate.mjs"), ...out], {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 10 * 1024 * 1024,
      timeout: Math.max(toolTimeoutMS(), 120000)
    });
    const text = (result.stdout || result.stderr || "").trim();
    sendResult(request.id, mcpProcessToolResult(result, text));
    return;
  }

  if (name === "tatwo_m2_entry_gate") {
    const out = ["--json"];
    appendOption(out, "--evidence-dir", args.evidenceDir);
    if (args.latest !== false && !args.evidenceDir) out.push("--latest");
    appendOption(out, "--human-approval", args.humanApprovalReceiptID);
    if (args.confirmM2 === true) out.push("--confirm-m2");
    const result = spawnSync("node", [path.join(repoRoot, "scripts", "tatwo-m2-entry-gate.mjs"), ...out], {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 10 * 1024 * 1024,
      timeout: Math.max(toolTimeoutMS(), 120000)
    });
    const text = (result.stdout || result.stderr || "").trim();
    sendResult(request.id, mcpProcessToolResult(result, text));
    return;
  }
  if (name === "tatwo_m2_final_gate") {
    const out = ["--json"];
    appendOption(out, "--evidence-dir", args.evidenceDir);
    if (args.latest !== false && !args.evidenceDir) out.push("--latest");
    appendOption(out, "--human-approval", args.humanApprovalReceiptID);
    if (args.confirmM2 === true) out.push("--confirm-m2");
    const result = spawnSync("node", [path.join(repoRoot, "scripts", "tatwo-m2-final-gate.mjs"), ...out], {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 10 * 1024 * 1024,
      timeout: Math.max(toolTimeoutMS(), 120000)
    });
    const text = (result.stdout || result.stderr || "").trim();
    sendResult(request.id, mcpProcessToolResult(result, text));
    return;
  }
  if (name === "tatwo_host_install_runway") {
    const out = ["--json"];
    appendOption(out, "--evidence-dir", args.evidenceDir);
    if (args.latest !== false) out.push("--latest");
    appendOption(out, "--human-approval", args.humanApprovalReceiptID);
    const result = spawnSync("node", [path.join(repoRoot, "scripts", "tatwo-host-install-runway.mjs"), ...out], {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 10 * 1024 * 1024,
      timeout: Math.max(toolTimeoutMS(), 120000)
    });
    const text = (result.stdout || result.stderr || "").trim();
    sendResult(request.id, mcpProcessToolResult(result, text));
    return;
  }
  if (name === "tatwo_host_promotion_plan") {
    const out = ["--json"];
    appendOption(out, "--evidence-dir", args.evidenceDir);
    if (args.latest !== false && !args.evidenceDir) out.push("--latest");
    const result = spawnSync("node", [path.join(repoRoot, "scripts", "tatwo-host-promotion-plan.mjs"), ...out], {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 10 * 1024 * 1024,
      timeout: Math.max(toolTimeoutMS(), 120000)
    });
    const text = (result.stdout || result.stderr || "").trim();
    sendResult(request.id, mcpProcessToolResult(result, text));
    return;
  }
  if (name === "tatwo_route_risk_dashboard") {
    const out = ["--json"];
    appendOption(out, "--evidence-dir", args.evidenceDir);
    if (args.latest !== false && !args.evidenceDir) out.push("--latest");
    const result = spawnSync("node", [path.join(repoRoot, "scripts", "tatwo-route-risk-dashboard.mjs"), ...out], {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 10 * 1024 * 1024,
      timeout: Math.max(toolTimeoutMS(), 120000)
    });
    const text = (result.stdout || result.stderr || "").trim();
    sendResult(request.id, mcpProcessToolResult(result, text));
    return;
  }
  if (name === "tatwo_route_smoke_plan") {
    const out = ["--json"];
    appendOption(out, "--evidence-dir", args.evidenceDir);
    if (args.latest !== false && !args.evidenceDir) out.push("--latest");
    const result = spawnSync("node", [path.join(repoRoot, "scripts", "tatwo-route-smoke-plan.mjs"), ...out], {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 10 * 1024 * 1024,
      timeout: Math.max(toolTimeoutMS(), 120000)
    });
    const text = (result.stdout || result.stderr || "").trim();
    sendResult(request.id, mcpProcessToolResult(result, text));
    return;
  }
  if (name === "tatwo_route_live_smoke_receipts") {
    const out = ["--json"];
    appendOption(out, "--evidence-dir", args.evidenceDir);
    if (args.latest !== false && !args.evidenceDir) out.push("--latest");
    const result = spawnSync("node", [path.join(repoRoot, "scripts", "tatwo-route-live-smoke-receipts.mjs"), ...out], {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 10 * 1024 * 1024,
      timeout: Math.max(toolTimeoutMS(), 120000)
    });
    const text = (result.stdout || result.stderr || "").trim();
    sendResult(request.id, mcpProcessToolResult(result, text));
    return;
  }
  if (name === "tatwo_codex_disconnect_guard") {
    const out = ["--json"];
    appendOption(out, "--gateway-dir", args.gatewayDir);
    const result = spawnSync("node", [path.join(repoRoot, "scripts", "tatwo-codex-disconnect-guard.mjs"), ...out], {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 10 * 1024 * 1024,
      timeout: Math.max(toolTimeoutMS(), 120000)
    });
    const text = (result.stdout || result.stderr || "").trim();
    sendResult(request.id, mcpProcessToolResult(result, text));
    return;
  }
  if (name === "tatwo_objective_audit") {
    const out = ["--json"];
    appendOption(out, "--evidence-dir", args.evidenceDir);
    if (args.latest !== false && !args.evidenceDir) out.push("--latest");
    const result = spawnSync("node", [path.join(repoRoot, "scripts", "tatwo-objective-audit.mjs"), ...out], {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 10 * 1024 * 1024,
      timeout: Math.max(toolTimeoutMS(), 120000)
    });
    const text = (result.stdout || result.stderr || "").trim();
    sendResult(request.id, mcpProcessToolResult(result, text));
    return;
  }
  if (name === "tatwo_objective_adversarial") {
    const out = ["--json"];
    appendOption(out, "--evidence-dir", args.evidenceDir);
    if (args.latest !== false && !args.evidenceDir) out.push("--latest");
    const result = spawnSync("node", [path.join(repoRoot, "scripts", "tatwo-objective-adversarial.mjs"), ...out], {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 10 * 1024 * 1024,
      timeout: Math.max(toolTimeoutMS(), 120000)
    });
    const text = (result.stdout || result.stderr || "").trim();
    sendResult(request.id, mcpProcessToolResult(result, text));
    return;
  }
  if (name === "tatwo_gateway_status" || name === "tatwo.gateway.status") {
    const receipt = await gatewayStatusReceipt(args);
    sendResult(request.id, {
      content: [{ type: "text", text: JSON.stringify(receipt, null, 2) }],
      isError: !receipt.ok
    });
    return;
  }
  if (name === "tatwo_gateway_models" || name === "tatwo.gateway.models") {
    const receipt = await gatewayModelsReceipt(args);
    sendResult(request.id, {
      content: [{ type: "text", text: JSON.stringify(receipt, null, 2) }],
      isError: !receipt.ok
    });
    return;
  }
  if (name === "tatwo_gateway_dispatch" || name === "tatwo.gateway.dispatch") {
    const receipt = await gatewayDispatchReceipt(args);
    sendResult(request.id, {
      content: [{ type: "text", text: JSON.stringify(receipt, null, 2) }],
      isError: !receipt.ok
    });
    return;
  }
  if (name === "tatwo_gateway_fanout" || name === "tatwo.gateway.fanout") {
    const receipt = await gatewayFanoutReceipt(args);
    sendResult(request.id, {
      content: [{ type: "text", text: JSON.stringify(receipt, null, 2) }],
      isError: !receipt.ok
    });
    return;
  }
  if (name === "tatwo_sandbox_begin" || name === "tatwo.sandbox.begin") {
    const receipt = sandboxBeginReceipt(args);
    sendResult(request.id, {
      content: [{ type: "text", text: JSON.stringify(receipt, null, 2) }],
      isError: !receipt.ok
    });
    return;
  }
  if (name === "tatwo_sandbox_write_artifact" || name === "tatwo.sandbox.write_artifact") {
    const receipt = sandboxWriteArtifactReceipt(args);
    sendResult(request.id, {
      content: [{ type: "text", text: JSON.stringify(receipt, null, 2) }],
      isError: !receipt.ok
    });
    return;
  }
  if (name === "tatwo_sandbox_run_command" || name === "tatwo.sandbox.run_command") {
    const receipt = sandboxRunCommandReceipt(args);
    sendResult(request.id, {
      content: [{ type: "text", text: JSON.stringify(receipt, null, 2) }],
      isError: !receipt.ok
    });
    return;
  }
  if (name === "tatwo_sandbox_receipt" || name === "tatwo.sandbox.receipt") {
    const receipt = sandboxBundleReceipt(args);
    sendResult(request.id, {
      content: [{ type: "text", text: JSON.stringify(receipt, null, 2) }],
      isError: !receipt.ok
    });
    return;
  }
  if (name === "tatwo_sandbox_promote_plan" || name === "tatwo.sandbox.promote_plan") {
    const receipt = sandboxPromotePlanReceipt(args);
    sendResult(request.id, {
      content: [{ type: "text", text: JSON.stringify(receipt, null, 2) }],
      isError: !receipt.ok
    });
    return;
  }
  if (name === "tatwo_web_check_import_receipt" || name === "tatwo.web_check.import_receipt") {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-web-check-mcp-"));
    try {
      let reportFile = typeof args.reportPath === "string" && args.reportPath.trim()
        ? args.reportPath.trim()
        : path.join(tmp, "report.json");
      if (!(typeof args.reportPath === "string" && args.reportPath.trim())) {
        const reportJSON = typeof args.reportJSON === "string" ? args.reportJSON : JSON.stringify(args.report ?? {});
        fs.writeFileSync(reportFile, reportJSON, "utf8");
      }
      const out = ["web-check", "import", "--report", reportFile, "--json"];
      appendOption(out, "--goal", args.goalID ?? args.goal);
      appendOption(out, "--contract", args.contractID ?? args.contract);
      appendOption(out, "--target-kind", args.targetKind);
      appendOption(out, "--scan-type", args.scanType);
      appendOption(out, "--blocking", args.blockingPolicy ?? args.blocking);
      appendOption(out, "--command", args.command);
      const result = spawnSync("swift", swiftRunInvocation(out), {
        cwd: repoRoot,
        env: swiftToolEnv(),
        encoding: "utf8",
        maxBuffer: 10 * 1024 * 1024,
        timeout: toolTimeoutMS()
      });
      const text = (result.stdout || result.stderr || "").trim();
      sendResult(request.id, mcpProcessToolResult(result, text));
    } finally {
      fs.rmSync(tmp, { recursive: true, force: true });
    }
    return;
  }

  if (name === "tatwo_validate_operational_receipt") {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-operational-mcp-"));
    try {
      const receiptJSON = typeof args.receiptJSON === "string" ? args.receiptJSON : JSON.stringify(args.receipt ?? {});
      const receiptFile = path.join(tmp, "receipt.json");
      fs.writeFileSync(receiptFile, receiptJSON, "utf8");
      const out = ["validate", "operational-receipt", "--file", receiptFile, "--require", String(args.requirement ?? "host-live-same-thread"), "--json"];
      if (args.requiredEpoch !== undefined) out.push("--required-epoch", String(args.requiredEpoch));
      const result = spawnSync("swift", swiftRunInvocation(out), {
        cwd: repoRoot,
        env: swiftToolEnv(),
        encoding: "utf8",
        maxBuffer: 10 * 1024 * 1024,
        timeout: toolTimeoutMS()
      });
      const text = (result.stdout || result.stderr || "").trim();
      sendResult(request.id, mcpProcessToolResult(result, text));
    } finally {
      fs.rmSync(tmp, { recursive: true, force: true });
    }
    return;
  }
  const cliArgs = cliArgsForTool(name, args);
  if (!cliArgs) {
    sendError(request.id, -32602, `unknown tool: ${name}`);
    return;
  }

  const result = spawnSync("swift", swiftRunInvocation(cliArgs), {
    cwd: repoRoot,
    env: swiftToolEnv(),
    encoding: "utf8",
    maxBuffer: 10 * 1024 * 1024,
    timeout: toolTimeoutMS()
  });

  if (result.error?.code === "ETIMEDOUT" || result.signal === "SIGTERM") {
    sendError(request.id, -32000, `tool timed out after ${toolTimeoutMS()}ms; build the CLI first or retry after sandbox build`);
    return;
  }

  const text = (result.stdout || result.stderr || "").trim();
  if (result.status !== 0 && !text) {
    sendError(request.id, -32000, `tool failed with exit ${result.status}`);
    return;
  }

  sendResult(request.id, mcpProcessToolResult(result, text));
}

function toolTimeoutMS() {
  const raw = Number(process.env.TATWO_MCP_TOOL_TIMEOUT_MS ?? "30000");
  return Number.isFinite(raw) && raw >= 1000 ? raw : 30000;
}

function gatewayBaseURL() {
  return String(process.env.TATWO_MODEL_GATEWAY_URL || process.env.MODEL_GATEWAY_BASE_URL || "http://127.0.0.1:4177")
    .replace(/\/+$/, "");
}

function gatewayDispatchTimeoutMS() {
  const raw = Number(process.env.TATWO_GATEWAY_DISPATCH_TIMEOUT_MS ?? process.env.TATWO_MCP_TOOL_TIMEOUT_MS ?? "90000");
  return Number.isFinite(raw) && raw >= 3000 ? raw : 90000;
}

const gatewayModelIdentityRegistryPath = path.join(
  repoRoot,
  "Packages",
  "TatwoUltraworkCore",
  "Sources",
  "TatwoUltraworkCore",
  "TatwoModelIdentityRegistryV1.json");

function loadGatewayModelIdentityRegistry() {
  try {
    const parsed = JSON.parse(fs.readFileSync(gatewayModelIdentityRegistryPath, "utf8"));
    if (
      parsed?.schema !== "TatwoModelIdentityRegistryV1"
      || !Array.isArray(parsed.records)
      || parsed.records.length === 0
    ) {
      throw new Error("invalid TatwoModelIdentityRegistryV1 contract");
    }
    return { ...parsed, loadError: null };
  } catch (error) {
    return {
      schema: "TatwoModelIdentityRegistryV1",
      canonicalAsOf: null,
      records: [],
      loadError: safeErrorText(error?.message || String(error)),
    };
  }
}

const gatewayModelIdentityRegistry = loadGatewayModelIdentityRegistry();
const gatewayModelIdentityRecords = gatewayModelIdentityRegistry.records;
const gatewayDispatchAllowedModels = new Set(
  gatewayModelIdentityRecords.map(record => String(record.canonicalModelID || "").trim()).filter(Boolean));

const gatewayDispatchExpensiveModels = new Set(["fable-5", "opus-5"]);
const gatewayStrictAttestationModels = new Set([
  "fable-5",
  "opus-5",
  "grok-build",
]);

const gatewayModelAliases = new Map();
const gatewayHistoricalEvidenceIDs = new Set();
for (const record of gatewayModelIdentityRecords) {
  const canonical = String(record.canonicalModelID || "").trim();
  if (!canonical) continue;
  gatewayModelAliases.set(canonical.toLowerCase(), canonical);
  for (const alias of Array.isArray(record.aliases) ? record.aliases : []) {
    const normalizedAlias = String(alias || "").trim().toLowerCase();
    if (normalizedAlias) gatewayModelAliases.set(normalizedAlias, canonical);
  }
  for (const evidenceID of Array.isArray(record.datedHistoricalEvidenceIDs)
    ? record.datedHistoricalEvidenceIDs
    : []) {
    const normalizedEvidenceID = String(evidenceID || "").trim();
    if (normalizedEvidenceID) gatewayHistoricalEvidenceIDs.add(normalizedEvidenceID);
  }
}

function canonicalWorkOSStateDirectory(candidate) {
  const legacy = path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "TatwoUltrawork",
    "state",
  );
  if (path.resolve(candidate) !== path.resolve(legacy)) return candidate;
  return path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "Tatwo Ultrawork",
    "state",
  );
}

function workOSStateDirectory() {
  const explicit = String(process.env.TATWO_ULTRAWORK_STATE_DIR || "").trim();
  if (explicit) return canonicalWorkOSStateDirectory(explicit);
  const support = String(process.env.TATWO_ULTRAWORK_APP_SUPPORT || "").trim();
  if (support) return canonicalWorkOSStateDirectory(path.join(support, "state"));
  // TATWO_OS_ROOT locates the constitution/adapters, not durable GoalRun
  // authority. Falling back to its historical state/swift-workos directory
  // split MCP from the App/CLI canonical Application Support state root.
  return canonicalWorkOSStateDirectory(path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "Tatwo Ultrawork",
    "state",
  ));
}

function gatewayProviderKeys(model) {
  const keys = new Set([model]);
  if (model === "chatgpt-pro-consult" || model.startsWith("gpt-") || model.startsWith("codex-")) {
    keys.add("openai");
  }
  if (/^(sonnet|haiku|opus)-/.test(model)) keys.add("anthropic");
  return keys;
}

function parseUTCDate(value) {
  const date = new Date(String(value || ""));
  return Number.isFinite(date.getTime()) ? date : null;
}

function cooldownDirectory() {
  return path.join(workOSStateDirectory(), "cooldowns");
}

function readCooldownRecords(model) {
  const directory = cooldownDirectory();
  let files = [];
  try {
    files = fs.readdirSync(directory, { withFileTypes: true })
      .filter(entry => entry.isFile() && entry.name.endsWith(".json"))
      .map(entry => path.join(directory, entry.name));
  } catch {
    return [];
  }
  const providerKeys = gatewayProviderKeys(model);
  return files.flatMap(file => {
    try {
      const record = JSON.parse(fs.readFileSync(file, "utf8"));
      const provider = String(record?.provider || "").trim();
      if (!providerKeys.has(provider)) return [];
      return [{ file, record }];
    } catch {
      return [];
    }
  });
}

function persistentCooldownDecision(model, now = new Date()) {
  const marginMS = 60_000;
  for (const entry of readCooldownRecords(model)) {
    const tripAt = parseUTCDate(entry.record.tripAtUTC);
    const resetAt = parseUTCDate(entry.record.resetAtUTC);
    if (!tripAt || !resetAt) {
      return {
        state: "blocked",
        code: "cooldown_blocked_malformed",
        entry,
        message: "cooldown_blocked: invalid tripAtUTC/resetAtUTC; fail closed"
      };
    }
    if (now < tripAt) {
      return {
        state: "blocked",
        code: "cooldown_blocked_clock_rollback",
        entry,
        message: `cooldown_blocked: clock rollback detected before ${tripAt.toISOString()}`
      };
    }
    const marginAt = new Date(resetAt.getTime() + marginMS);
    if (now < marginAt) {
      return {
        state: "blocked",
        code: "cooldown_blocked_before_reset_margin",
        entry,
        marginAt,
        message: `cooldown_blocked: retry after ${marginAt.toISOString()}`
      };
    }
    const clearedAt = parseUTCDate(entry.record.clearedAtUTC);
    const probeSucceededAt = parseUTCDate(entry.record.probeSucceededAtUTC);
    if (
      clearedAt
      && clearedAt >= tripAt
      && probeSucceededAt
      && probeSucceededAt >= marginAt
    ) continue;
    if (entry.record.probeAttemptedAtUTC) {
      return {
        state: "blocked",
        code: "cooldown_blocked_probe_exhausted",
        entry,
        marginAt,
        message: "cooldown_blocked: the single post-reset health probe was already used"
      };
    }
    return {
      state: "requires_probe",
      code: "cooldown_probe_required",
      entry,
      marginAt,
      message: "cooldown_blocked: reset margin elapsed; one health probe is required"
    };
  }
  return { state: "clear" };
}

function fsyncDirectory(directory) {
  try {
    const fd = fs.openSync(directory, "r");
    try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  } catch {}
}

function writeJSONAtomically(file, value) {
  const directory = path.dirname(file);
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const temp = path.join(
    directory,
    `.${path.basename(file)}.${process.pid}.${crypto.randomUUID()}.tmp`);
  const fd = fs.openSync(temp, "wx", 0o600);
  try {
    fs.writeFileSync(fd, `${JSON.stringify(value, null, 2)}\n`, "utf8");
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(temp, file);
  fsyncDirectory(directory);
}

function appendCooldownEvent(event) {
  const directory = cooldownDirectory();
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const file = path.join(directory, "events.jsonl");
  const fd = fs.openSync(file, "a", 0o600);
  try {
    fs.writeFileSync(fd, `${JSON.stringify(event)}\n`, "utf8");
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fsyncDirectory(directory);
}

function cooldownLockOwnerIsAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

function cooldownLockIsStale(lock, now = new Date()) {
  try {
    const stat = fs.statSync(lock);
    let metadata = null;
    try {
      metadata = JSON.parse(fs.readFileSync(lock, "utf8"));
    } catch {}
    const pid = Number(metadata?.pid);
    if (Number.isInteger(pid) && pid > 0) {
      return !cooldownLockOwnerIsAlive(pid);
    }
    return now.getTime() - stat.mtimeMs > 120_000;
  } catch {
    return false;
  }
}

function acquireCooldownLock(lock) {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const token = crypto.randomUUID();
    let fd;
    try {
      fd = fs.openSync(lock, "wx", 0o600);
      fs.writeFileSync(fd, `${JSON.stringify({
        schemaVersion: 1,
        pid: process.pid,
        createdAtUTC: new Date().toISOString(),
        token
      })}\n`, "utf8");
      fs.fsyncSync(fd);
      return { ok: true, fd, token };
    } catch (error) {
      if (fd !== undefined) {
        try { fs.closeSync(fd); } catch {}
        try { fs.unlinkSync(lock); } catch {}
      }
      if (error?.code !== "EEXIST" || attempt > 0 || !cooldownLockIsStale(lock)) {
        return { ok: false, error: "cooldown_lock_busy" };
      }
      const quarantine = `${lock}.stale.${process.pid}.${crypto.randomUUID()}`;
      try {
        fs.renameSync(lock, quarantine);
        try { fs.unlinkSync(quarantine); } catch {}
        fsyncDirectory(path.dirname(lock));
      } catch {
        return { ok: false, error: "cooldown_lock_busy" };
      }
    }
  }
  return { ok: false, error: "cooldown_lock_busy" };
}

function releaseCooldownLock(lock, claim) {
  try { fs.closeSync(claim.fd); } catch {}
  try {
    const metadata = JSON.parse(fs.readFileSync(lock, "utf8"));
    if (metadata?.token === claim.token) fs.unlinkSync(lock);
  } catch {}
}

function mutateCooldownRecord(entry, mutation) {
  const lock = `${entry.file}.lock`;
  const claim = acquireCooldownLock(lock);
  if (!claim.ok) return claim;
  try {
    const current = JSON.parse(fs.readFileSync(entry.file, "utf8"));
    const next = mutation(current);
    writeJSONAtomically(entry.file, next);
    return { ok: true, record: next };
  } catch (error) {
    return { ok: false, error: safeErrorText(error?.message || String(error)) };
  } finally {
    releaseCooldownLock(lock, claim);
  }
}

function cooldownBlockedReceipt(policy, decision) {
  return {
    schema: "TatwoGatewayDispatchReceiptV1",
    ok: false,
    status: "blocked",
    contractID: policy.contractID,
    goalID: policy.goalID,
    model: policy.model,
    identity: policy.identity,
    purpose: policy.purpose,
    gateway: gatewayBaseURL(),
    hostMutationAllowed: false,
    error: `${decision.code}: ${decision.message}`,
    cooldown: decision.entry?.record
      ? {
          provider: decision.entry.record.provider,
          scope: decision.entry.record.scope,
          reason: decision.entry.record.reason,
          tripAtUTC: decision.entry.record.tripAtUTC,
          resetAtUTC: decision.entry.record.resetAtUTC,
          retryAtUTC: decision.marginAt?.toISOString() || null
        }
      : null
  };
}

function syncGoalCooldownState(contractID, blocked, reason) {
  return recordDispatchCLI([
    "os", "cooldown", blocked ? "block" : "clear",
    "--contract", contractID,
    "--reason", reason,
    "--json"
  ]);
}

function recordSessionLimitCooldown(policy, parsed) {
  const errorKind = String(parsed.errorKind || "").trim().toLowerCase();
  if (errorKind !== "session_limit") return;
  const now = new Date();
  const resetAt = parseUTCDate(parsed.resetAt) || new Date("9999-12-31T23:59:59Z");
  const file = path.join(cooldownDirectory(), `${policy.model}-model.json`);
  const record = {
    schemaVersion: 1,
    provider: policy.model,
    scope: "model",
    reason: "session_limit",
    tripAtUTC: now.toISOString(),
    resetAtUTC: resetAt.toISOString(),
    sourceEventID: parsed.responseID || `gateway-session-limit-${Date.now()}`,
    contractID: policy.contractID
  };
  writeJSONAtomically(file, record);
  appendCooldownEvent({
    schema: "TatwoGatewayCooldownEventV1",
    type: "tripped",
    atUTC: now.toISOString(),
    provider: record.provider,
    scope: record.scope,
    reason: record.reason,
    sourceEventID: record.sourceEventID,
    contractID: record.contractID
  });
}

function contractIsStillValid(contractID) {
  return recordDispatchCLI(["os", "contract", "require", "--contract", contractID, "--json"]);
}

function gatewayBindingReceiptFields(policy) {
  return {
    bindingID: policy.bindingID,
    sourceSlotID: policy.sourceSlotID,
    contractRequiredReasoningEffort:
      policy.contractRequiredReasoningEffort ?? null,
  };
}

function resolveGatewayContractBinding(policy, args = {}) {
  const dashboardResult = recordDispatchCLI([
    "os", "dashboard",
    "--contract", policy.contractID,
    "--json",
  ]);
  if (!dashboardResult.ok) {
    return {
      ok: false,
      code: "contract_binding_projection_failed",
      error: safeErrorText(dashboardResult.error || "stored Work OS dashboard unavailable"),
    };
  }
  const dashboard = dashboardResult.data;
  const projectedContractID = String(dashboard?.contract?.contractID || "").trim();
  const projectedGoalID = String(dashboard?.goal?.goalID || "").trim();
  const projectedScenarioID = String(
    dashboard?.contract?.scenario ?? dashboard?.goal?.scenario ?? "",
  ).trim();
  const projectedMode = String(
    dashboard?.contract?.mode ?? dashboard?.goal?.mode ?? "",
  ).trim().toUpperCase();
  if (
    projectedContractID !== policy.contractID
    || !projectedGoalID
    || !projectedScenarioID
    || !projectedMode
  ) {
    return {
      ok: false,
      code: "contract_binding_projection_mismatch",
      error: "stored Work OS dashboard omitted or disagreed with contract/goal/scenario/mode",
    };
  }
  if (policy.goalID && policy.goalID !== projectedGoalID) {
    return {
      ok: false,
      code: "contract_goal_mismatch",
      error: `caller goalID ${policy.goalID} does not match issued ${projectedGoalID}`,
    };
  }

  const scenarioResult = recordDispatchCLI(["scenario", "config", "--json"]);
  if (!scenarioResult.ok) {
    return {
      ok: false,
      code: "contract_binding_source_unavailable",
      error: safeErrorText(scenarioResult.error || "scenario config unavailable"),
    };
  }
  const scenarioBook = scenarioResult.data;
  const scenario = Array.isArray(scenarioBook?.scenarios)
    ? scenarioBook.scenarios.find(
        (candidate) => String(candidate?.id || "").trim() === projectedScenarioID,
      )
    : null;
  const modeConfigs =
    scenario?.modeConfigs
    && typeof scenario.modeConfigs === "object"
    && !Array.isArray(scenario.modeConfigs)
      ? scenario.modeConfigs
      : null;
  const modeConfig =
    modeConfigs?.[projectedMode]
    ?? modeConfigs?.[projectedMode.toLowerCase()]
    ?? modeConfigs?.[projectedMode[0] + projectedMode.slice(1).toLowerCase()]
    ?? null;
  const sourceBindings = Array.isArray(modeConfig?.bindings)
    ? modeConfig.bindings
    : [];
  const slots = Array.isArray(dashboard?.identitySlots)
    ? dashboard.identitySlots
    : [];
  const callerBindingID = String(args.bindingID ?? args.binding ?? "").trim();
  const callerSourceSlotID = String(
    args.sourceSlotID ?? args.slot ?? args.sourceSlot ?? "",
  ).trim();

  const identityModelMatches = slots.filter((slot) =>
    String(slot?.identity || "").trim().toLowerCase() === policy.identity.toLowerCase()
    && normalizeGatewayModel(slot?.modelID) === policy.model);
  if (!identityModelMatches.length) {
    return {
      ok: false,
      code: "contract_binding_missing",
      error: `no issued binding matches identity=${policy.identity} model=${policy.model}`,
    };
  }

  const resolvedCandidates = [];
  for (const slot of identityModelMatches) {
    const slotID = String(slot?.id || "").trim();
    if (!slotID) continue;
    const matchingSources = sourceBindings.filter((source) => {
      const sourceID = String(source?.id || "").trim();
      if (!sourceID) return false;
      if (slotID === `binding-${sourceID}`) return true;
      const prefix = `binding-${sourceID}-`;
      const suffix = slotID.startsWith(prefix) ? slotID.slice(prefix.length) : "";
      return /^\d+$/.test(suffix);
    });
    if (matchingSources.length > 1) {
      return {
        ok: false,
        code: "contract_binding_source_ambiguous",
        error: `binding ${slotID} maps to multiple scenario source slots`,
      };
    }

    let sourceSlotID;
    let requiredReasoningEffort = null;
    if (matchingSources.length === 1) {
      sourceSlotID = String(matchingSources[0].id);
      const rawRequiredEffort = matchingSources[0].reasoningEffort;
      if (
        rawRequiredEffort !== null
        && rawRequiredEffort !== undefined
        && String(rawRequiredEffort).trim() !== ""
      ) {
        requiredReasoningEffort =
          normalizeContractReasoningEffort(rawRequiredEffort);
        if (!requiredReasoningEffort) {
          return {
            ok: false,
            code: "contract_reasoning_effort_invalid",
            error: `binding ${slotID} has unsupported required effort ${rawRequiredEffort}`,
          };
        }
      }
    } else if (slotID === "binding-fable5-lead") {
      sourceSlotID = "role-intent-fable5-lead";
    } else if (slotID === "binding-gpt55-loops") {
      sourceSlotID = "role-intent-gpt55-loops";
    } else if (slotID.startsWith("binding-")) {
      // Built-in identity-slot fallback contracts have no scenario binding row.
      sourceSlotID = slotID.slice("binding-".length);
    }
    if (!sourceSlotID) {
      return {
        ok: false,
        code: "contract_binding_source_missing",
        error: `issued binding ${slotID} has no resolvable source slot`,
      };
    }
    resolvedCandidates.push({
      bindingID: slotID,
      sourceSlotID,
      contractRequiredReasoningEffort: requiredReasoningEffort,
    });
  }

  let matches = resolvedCandidates;
  if (callerBindingID) {
    matches = matches.filter((candidate) => candidate.bindingID === callerBindingID);
  }
  if (callerSourceSlotID) {
    matches = matches.filter(
      (candidate) => candidate.sourceSlotID === callerSourceSlotID,
    );
  }
  if (!matches.length) {
    const expected = resolvedCandidates
      .map((candidate) => `${candidate.bindingID}/${candidate.sourceSlotID}`)
      .join(", ");
    return {
      ok: false,
      code: "contract_binding_mismatch",
      error:
        `caller binding=${callerBindingID || "<auto>"} slot=${callerSourceSlotID || "<auto>"} `
        + `does not match issued ${expected}`,
    };
  }
  if (matches.length !== 1) {
    return {
      ok: false,
      code: "contract_binding_ambiguous",
      error:
        `identity=${policy.identity} model=${policy.model} matches `
        + matches.map((candidate) => candidate.bindingID).join(", "),
    };
  }

  const binding = matches[0];
  if (
    binding.contractRequiredReasoningEffort
    && policy.reasoningEffortWasExplicit
    && policy.reasoningEffort !== binding.contractRequiredReasoningEffort
  ) {
    return {
      ok: false,
      code: "contract_reasoning_effort_mismatch",
      error:
        `caller requested ${policy.reasoningEffort}; issued binding `
        + `${binding.bindingID} requires ${binding.contractRequiredReasoningEffort}`,
    };
  }
  return {
    ok: true,
    policy: {
      ...policy,
      goalID: projectedGoalID,
      bindingID: binding.bindingID,
      sourceSlotID: binding.sourceSlotID,
      contractRequiredReasoningEffort:
        binding.contractRequiredReasoningEffort,
      reasoningEffort:
        binding.contractRequiredReasoningEffort ?? policy.reasoningEffort,
    },
  };
}

function normalizeContractReasoningEffort(raw) {
  const value = String(raw ?? "").trim().toLowerCase().replace(/_/g, "-");
  const aliases = new Map([
    ["extra-high", "xhigh"],
    ["max", "xhigh"],
    ["maximum", "xhigh"],
    ["highest", "xhigh"],
    ["最高", "xhigh"],
  ]);
  const normalized = aliases.get(value) || value;
  return ["low", "medium", "high", "xhigh"].includes(normalized)
    ? normalized
    : "";
}

const gatewayRouteHealthMaxAgeMS = 15 * 60 * 1000;

function canonicalGatewayCatalogIDs(payload) {
  const data = Array.isArray(payload?.data) ? payload.data : [];
  return new Set(data
    .filter(model => model?.supported_in_api !== false)
    .map(model => model?.id || model?.slug || model?.model)
    .map(normalizeGatewayModel)
    .filter(model => gatewayDispatchAllowedModels.has(model)));
}

function gatewayRouteForModel(payload, canonicalModelID) {
  const routes = payload?.routes;
  if (!routes || typeof routes !== "object" || Array.isArray(routes)) return null;
  for (const [routeID, route] of Object.entries(routes)) {
    if (
      route
      && typeof route === "object"
      && !Array.isArray(route)
      && normalizeGatewayModel(routeID) === canonicalModelID
    ) {
      return { routeID, route };
    }
  }
  return null;
}

function gatewayRouteHealthDecision({
  model,
  healthResult,
  catalogResult,
  now = new Date(),
  maxAgeMS = gatewayRouteHealthMaxAgeMS,
}) {
  const canonicalModelID = normalizeGatewayModel(model);
  const blocked = (code, extra = {}) => ({
    ok: false,
    code,
    canonicalModelID,
    ...extra,
  });
  if (gatewayModelIdentityRegistry.loadError) {
    return blocked("model_registry_unavailable");
  }
  if (gatewayHistoricalEvidenceIDs.has(String(model || "").trim())) {
    return blocked("historical_evidence_not_dispatchable");
  }
  if (!canonicalModelID || !gatewayDispatchAllowedModels.has(canonicalModelID)) {
    return blocked("model_not_allowlisted");
  }
  if (!healthResult?.ok || !healthResult.json || typeof healthResult.json !== "object") {
    return blocked("gateway_health_unavailable");
  }
  if (healthResult.json.ok !== true || healthResult.json.degraded === true) {
    return blocked("gateway_runtime_degraded");
  }
  if (!catalogResult?.ok || !catalogResult.json || typeof catalogResult.json !== "object") {
    return blocked("gateway_catalog_unavailable");
  }
  const catalogIDs = canonicalGatewayCatalogIDs(catalogResult.json);
  if (!catalogIDs.has(canonicalModelID)) {
    return blocked("route_catalog_missing");
  }
  const matched = gatewayRouteForModel(healthResult.json, canonicalModelID);
  if (!matched) {
    return blocked("route_health_missing");
  }

  const { routeID, route } = matched;
  const requiredFields = ["attempts", "has_error", "error_kind", "observed_at", "last_ok_at"];
  const missingFields = requiredFields.filter(field => !Object.prototype.hasOwnProperty.call(route, field));
  if (missingFields.length > 0) {
    return blocked("route_health_v2_incomplete", { routeID, missingFields });
  }
  if (!Number.isInteger(route.attempts) || route.attempts <= 0) {
    return blocked("route_health_unprobed", { routeID });
  }
  if (route.has_error !== false) {
    return blocked("route_has_error", { routeID, errorKind: route.error_kind ?? null });
  }
  if (route.error_kind !== null) {
    return blocked("route_error_kind_present", { routeID, errorKind: String(route.error_kind) });
  }
  const routeStatus = String(route.status ?? "").trim().toLowerCase();
  if (/unhealthy|untested|degraded|unavailable|quota|auth|error|failed|blocked/.test(routeStatus)) {
    return blocked("route_status_not_healthy", { routeID, routeStatus });
  }
  if (route.healthy === false) {
    return blocked("route_not_healthy", { routeID });
  }

  const observedAt = parseUTCDate(route.observed_at);
  const lastOKAt = parseUTCDate(route.last_ok_at);
  if (!observedAt || !lastOKAt) {
    return blocked("route_health_timestamp_invalid", { routeID });
  }
  const nowMS = now.getTime();
  const observedAgeMS = nowMS - observedAt.getTime();
  const lastOKAgeMS = nowMS - lastOKAt.getTime();
  if (
    observedAgeMS < -60_000
    || observedAgeMS > maxAgeMS
    || lastOKAgeMS < -60_000
    || lastOKAgeMS > maxAgeMS
    || lastOKAt.getTime() - observedAt.getTime() > 60_000
  ) {
    return blocked("route_health_stale", {
      routeID,
      observedAt: route.observed_at,
      lastOKAt: route.last_ok_at,
    });
  }
  const lastErrorAt = parseUTCDate(route.last_error_at);
  if (lastErrorAt && lastErrorAt.getTime() >= lastOKAt.getTime()) {
    return blocked("route_error_not_cleared", { routeID });
  }
  return {
    ok: true,
    code: "route_health_v2_verified",
    canonicalModelID,
    routeID,
    receipt: {
      schema: "TatwoRouteHealthReceiptV2",
      attempts: route.attempts,
      has_error: route.has_error,
      error_kind: route.error_kind,
      observed_at: route.observed_at,
      last_ok_at: route.last_ok_at,
    },
  };
}

async function gatewayRouteHealthSnapshot(model) {
  const timeout = Math.min(gatewayDispatchTimeoutMS(), 12_000);
  const [healthResult, catalogResult] = await Promise.all([
    fetchJSON(`${gatewayBaseURL()}/health`, { method: "GET" }, timeout),
    fetchJSON(`${gatewayBaseURL()}/v1/models`, { method: "GET" }, timeout),
  ]);
  return {
    healthResult,
    catalogResult,
    decision: gatewayRouteHealthDecision({ model, healthResult, catalogResult }),
  };
}

async function runSingleCooldownProbe(policy, decision) {
  const attemptedAt = new Date().toISOString();
  const claimed = mutateCooldownRecord(decision.entry, record => ({
    ...record,
    probeAttemptedAtUTC: attemptedAt
  }));
  if (!claimed.ok) {
    return {
      ok: false,
      decision: {
        ...decision,
        state: "blocked",
        code: "cooldown_blocked_probe_claim_failed",
        message: `cooldown_blocked: ${claimed.error}`
      }
    };
  }
  const snapshot = await gatewayRouteHealthSnapshot(policy.model);
  if (!snapshot.decision.ok) {
    return {
      ok: false,
      decision: {
        ...decision,
        state: "blocked",
        code: "cooldown_blocked_probe_failed",
        message: `cooldown_blocked: post-reset health probe failed (${snapshot.decision.code})`
      }
    };
  }
  const succeededAt = new Date().toISOString();
  const goalClear = syncGoalCooldownState(
    policy.contractID,
    false,
    `cooldown_cleared:${claimed.record.provider}`);
  if (!goalClear.ok) {
    return {
      ok: false,
      decision: {
        ...decision,
        state: "blocked",
        code: "cooldown_blocked_goal_clear_failed",
        message: `cooldown_blocked: GoalRun clear failed (${goalClear.error || "unknown"})`
      }
    };
  }
  const cleared = mutateCooldownRecord(decision.entry, record => ({
    ...record,
    probeSucceededAtUTC: succeededAt,
    clearedAtUTC: succeededAt
  }));
  if (!cleared.ok) {
    syncGoalCooldownState(
      policy.contractID,
      true,
      `cooldown_clear_persist_failed:${claimed.record.provider}`);
    return {
      ok: false,
      decision: {
        ...decision,
        state: "blocked",
        code: "cooldown_blocked_clear_failed",
        message: `cooldown_blocked: ${cleared.error}`
      }
    };
  }
  appendCooldownEvent({
    schema: "TatwoGatewayCooldownEventV1",
    type: "cleared",
    atUTC: succeededAt,
    provider: cleared.record.provider,
    scope: cleared.record.scope,
    reason: cleared.record.reason,
    sourceEventID: cleared.record.sourceEventID,
    contractID: cleared.record.contractID
  });
  return { ok: true };
}

async function gatewayStatusReceipt(args = {}) {
  const gateway = gatewayBaseURL();
  const timeout = Math.min(gatewayDispatchTimeoutMS(), 12_000);
  const [healthResult, catalogResult] = await Promise.all([
    fetchJSON(`${gateway}/health`, { method: "GET" }, timeout),
    fetchJSON(`${gateway}/v1/models`, { method: "GET" }, timeout),
  ]);
  if (!healthResult.ok) {
    return {
      schema: "TatwoGatewayStatusReceiptV1",
      ok: false,
      status: "failed",
      gateway,
      error: healthResult.error || healthResult.text || `HTTP ${healthResult.status}`,
      hostMutationAllowed: false
    };
  }
  if (!catalogResult.ok) {
    return {
      schema: "TatwoGatewayStatusReceiptV1",
      ok: false,
      status: "failed",
      gateway,
      error: catalogResult.error || catalogResult.text || `HTTP ${catalogResult.status}`,
      hostMutationAllowed: false
    };
  }
  const catalogIDs = [...canonicalGatewayCatalogIDs(catalogResult.json)].sort();
  const routeHealth = catalogIDs.map(model =>
    gatewayRouteHealthDecision({ model, healthResult, catalogResult }));
  const healthy = (
    gatewayModelIdentityRegistry.loadError === null
    && healthResult.json?.ok === true
    && healthResult.json?.degraded !== true
    && routeHealth.length > 0
    && routeHealth.every(decision => decision.ok)
  );
  return {
    schema: "TatwoGatewayStatusReceiptV1",
    ok: healthy,
    status: healthy ? "healthy" : "degraded",
    gateway,
    service: healthResult.json?.service || "model-gateway",
    provider: healthResult.json?.provider,
    wireAPI: healthResult.json?.wire_api,
    apiSpendPolicy: healthResult.json?.api_spend_policy?.default || null,
    activeAPIAllowlist: healthResult.json?.api_spend_policy?.active_api_model_allowlist || [],
    catalogRouteCount: catalogIDs.length,
    verifiedHealthyRouteCount: routeHealth.filter(decision => decision.ok).length,
    routeHealth,
    error: healthy
      ? undefined
      : gatewayModelIdentityRegistry.loadError
        ? `model_registry_unavailable:${gatewayModelIdentityRegistry.loadError}`
        : "route_health_v2_not_verified",
    dispatchBridge: {
      purpose: "Claude/Fable/Codex MCP caller can request text-only submodel dispatch through TATWO Work OS.",
      hostMutationAllowed: false,
      requiresContractIDForDispatch: true,
      allowedModels: [...gatewayDispatchAllowedModels]
    },
    includeRaw: args.includeRaw === true ? redactGatewayPayload(healthResult.json) : undefined
  };
}

async function gatewayModelsReceipt(args = {}) {
  const gateway = gatewayBaseURL();
  const result = await fetchJSON(`${gateway}/v1/models`, { method: "GET" }, Math.min(gatewayDispatchTimeoutMS(), 12000));
  if (!result.ok) {
    return {
      schema: "TatwoGatewayModelsReceiptV1",
      ok: false,
      status: "failed",
      gateway,
      error: result.error || result.text || `HTTP ${result.status}`,
      hostMutationAllowed: false
    };
  }
  const data = Array.isArray(result.json?.data) ? result.json.data : [];
  const models = data
    .map((model) => ({
      id: normalizeGatewayModel(model.id || model.slug || model.model),
      displayName: model.display_name || model.name || model.id,
      backend: model.capabilities?.backend || model.backend || null,
      supportedInAPI: model.supported_in_api !== false,
      dispatchAllowed: gatewayDispatchAllowedModels.has(
        normalizeGatewayModel(model.id || model.slug || model.model))
    }))
    .filter((model) => gatewayDispatchAllowedModels.has(model.id))
    .filter((model) => args.allowedOnly === true ? model.dispatchAllowed : true);
  return {
    schema: "TatwoGatewayModelsReceiptV1",
    ok: true,
    status: "completed",
    gateway,
    count: models.length,
    models,
    hostMutationAllowed: false
  };
}

// B2: record a real gateway dispatch into the Work OS dispatch registry via the Swift CLI.
// Dispatch lifecycle is fail-closed: no ledger begin means no model call, and no terminal
// ledger update means the caller cannot receive a completed receipt.
function recordDispatchCLI(cliArgs) {
  try {
    const result = spawnSync("swift", swiftRunInvocation(cliArgs), {
      cwd: repoRoot,
      env: swiftToolEnv(),
      encoding: "utf8",
      timeout: 120000,
    });
    if (result.status !== 0) {
      return {
        ok: false,
        error: swiftCLIErrorText(result, `dispatch_registry_exit_${result.status}`)
      };
    }
    const parsed = JSON.parse(result.stdout || "{}");
    if (parsed.ok === false) {
      return {
        ok: false,
        error: safeErrorText(parsed.error || parsed.message || "dispatch_registry_rejected")
      };
    }
    return { ok: true, data: parsed.data || parsed };
  } catch (error) {
    return {
      ok: false,
      error: safeErrorText(error?.message || String(error))
    };
  }
}

function swiftCLIErrorText(result, fallback) {
  const stdout = String(result.stdout || "").trim();
  if (stdout) {
    try {
      const parsed = JSON.parse(stdout);
      return safeErrorText(parsed.error || parsed.message || stdout);
    } catch {
      return safeErrorText(stdout);
    }
  }
  return safeErrorText(result.stderr || fallback);
}

async function gatewayDispatchReceipt(args = {}) {
  let policy = gatewayDispatchPolicy(args);
  if (!policy.ok) return policy.receipt;
  const bindingResolution = resolveGatewayContractBinding(policy, args);
  if (!bindingResolution.ok) {
    return {
      ...failClosedGatewayReceipt(
        "tatwo_gateway_dispatch",
        args,
        `${bindingResolution.code}: ${bindingResolution.error}`,
      ),
      errorCode: bindingResolution.code,
    };
  }
  policy = bindingResolution.policy;
  const cooldownDecision = persistentCooldownDecision(policy.model);
  if (cooldownDecision.state === "blocked") {
    syncGoalCooldownState(
      policy.contractID,
      true,
      `${cooldownDecision.code}:${cooldownDecision.entry?.record?.reason || "cooldown"}`);
    return cooldownBlockedReceipt(policy, cooldownDecision);
  }
  if (cooldownDecision.state === "requires_probe") {
    if (args.dryRun === true) {
      return cooldownBlockedReceipt(policy, cooldownDecision);
    }
    const contractValidity = contractIsStillValid(policy.contractID);
    if (!contractValidity.ok) {
      return cooldownBlockedReceipt(policy, {
        ...cooldownDecision,
        state: "blocked",
        code: "cooldown_blocked_contract_invalid",
        message: `cooldown_blocked: contract is no longer valid (${contractValidity.error || "unknown"})`
      });
    }
    const probe = await runSingleCooldownProbe(policy, cooldownDecision);
    if (!probe.ok) return cooldownBlockedReceipt(policy, probe.decision);
  }
  if (args.dryRun === true) {
    return {
      schema: "TatwoGatewayDispatchReceiptV1",
      ok: true,
      status: "dry_run",
      contractID: policy.contractID,
      goalID: policy.goalID,
      model: policy.model,
      identity: policy.identity,
      ...gatewayBindingReceiptFields(policy),
      purpose: policy.purpose,
      gateway: gatewayBaseURL(),
      hostMutationAllowed: false,
      plannedRequest: {
        endpoint: "/v1/responses",
        stream: isGPTGatewayModel(policy.model),
        promptChars: policy.prompt.length,
        outputCapChars: policy.outputCapChars,
        reasoningEffort: policy.reasoningEffort,
        reasoningForwarded: false,
        reasoningForwardingPlanned:
          gatewayModelSupportsNativeReasoningControl(policy.model),
        authMode: isGPTGatewayModel(policy.model) ? "codex-auth-header-internal-redacted" : "no-codex-auth-required"
      }
    };
  }

  const healthSnapshot = await gatewayRouteHealthSnapshot(policy.model);
  if (!healthSnapshot.decision.ok) {
    return {
      schema: "TatwoGatewayDispatchReceiptV1",
      ok: false,
      status: "blocked",
      contractID: policy.contractID,
      goalID: policy.goalID,
      model: policy.model,
      identity: policy.identity,
      ...gatewayBindingReceiptFields(policy),
      purpose: policy.purpose,
      gateway: gatewayBaseURL(),
      hostMutationAllowed: false,
      error: `route_health_v2_required:${policy.model}:${healthSnapshot.decision.code}`,
      routeHealth: healthSnapshot.decision,
    };
  }

  // B2: record the dispatch as it starts so the dashboard shows a real (last-known) sub.
  const dispatchBeginArgs = [
    "os", "dispatch", "begin",
    "--contract", policy.contractID,
    "--binding", policy.bindingID,
    "--slot", policy.sourceSlotID,
    "--identity", policy.identity,
    "--model", policy.model,
    "--subtask", String(policy.purpose || "gateway dispatch"),
  ];
  if (args.logicalDispatchID || args.logicalDispatch) {
    dispatchBeginArgs.push(
      "--logical-dispatch",
      String(args.logicalDispatchID || args.logicalDispatch));
  }
  if (args.supersedes) {
    dispatchBeginArgs.push("--supersedes", String(args.supersedes));
  }
  dispatchBeginArgs.push("--json");
  const dispatchBegin = recordDispatchCLI(dispatchBeginArgs);
  const gateway = gatewayBaseURL();
  if (!dispatchBegin.ok || !dispatchBegin.data?.id) {
    return {
      schema: "TatwoGatewayDispatchReceiptV1",
      ok: false,
      status: "failed",
      contractID: policy.contractID,
      goalID: policy.goalID,
      model: policy.model,
      identity: policy.identity,
      ...gatewayBindingReceiptFields(policy),
      purpose: policy.purpose,
      gateway,
      hostMutationAllowed: false,
      reasoningEffort: policy.reasoningEffort,
      reasoningForwarded: false,
      reasoningControl: null,
      error: `dispatch_registry_begin_failed: ${safeErrorText(dispatchBegin.error || "missing dispatch id")}`
    };
  }
  const dispatchID = dispatchBegin.data.id;

  const headers = gatewayHeadersForModel(policy.model);
  const useStream = isGPTGatewayModel(policy.model);
  const requestBody = {
    model: policy.model,
    stream: useStream,
    store: false,
    input: [
      {
        type: "message",
        role: "user",
        content: [{ type: "input_text", text: buildDispatchPrompt(policy) }]
      }
    ]
  };
  if (gatewayModelSupportsNativeReasoningControl(policy.model)) {
    requestBody.reasoning = { effort: policy.reasoningEffort };
  }
  const body = JSON.stringify(requestBody);
  const result = await fetchJSON(`${gateway}/v1/responses`, {
    method: "POST",
    headers,
    body
  }, gatewayDispatchTimeoutMS());

  const parsed = parseGatewayResponsePayload(result);
  const reasoningReceipt = gatewayReasoningReceipt(policy, parsed, result);
  const completionValidation = gatewayCompletionValidation(
    policy,
    parsed,
    reasoningReceipt,
  );
  if (!parsed.failed && !completionValidation.ok) {
    parsed.failed = true;
    parsed.error = completionValidation.error;
    parsed.errorKind = completionValidation.errorCode;
    parsed.errorCode = completionValidation.errorCode;
  }
  const completionEvidence = gatewayCompletionReceiptFields(
    policy,
    parsed,
    reasoningReceipt,
    completionValidation.modelAttestation,
  );
  if (!result.ok || parsed.failed) {
    recordSessionLimitCooldown(policy, parsed);
    const failure = gatewayFailureReceiptData(result, parsed);
    const terminalArgs = [
      "os", "dispatch", "update", "--contract", policy.contractID, "--dispatch", dispatchID,
      "--status", "failed",
      "--failure-class", failure.failureClass,
      "--error-code", failure.errorCode,
      "--raw-error-digest", failure.rawErrorDigest,
      "--error", failure.operatorMessage,
    ];
    if (failure.httpStatus !== null) {
      terminalArgs.push("--http-status", String(failure.httpStatus));
    }
    if (failure.backendRequestID) {
      terminalArgs.push("--backend-request-id", failure.backendRequestID);
    }
    if (failure.backendResponseID) {
      terminalArgs.push("--backend-response-id", failure.backendResponseID);
    }
    terminalArgs.push("--json");
    const terminalUpdate = recordDispatchCLI(terminalArgs);
    const attempt = Math.max(1, Number(dispatchBegin.data?.attempt ?? 1) || 1);
    const goalStatus =
      failure.failureClass === "terminal"
      || (failure.failureClass === "retryable" && attempt >= 2)
        ? "failed"
        : "blocked";
    return {
      schema: "TatwoGatewayDispatchReceiptV1",
      ok: false,
      status: "failed",
      contractID: policy.contractID,
      goalID: policy.goalID,
      model: policy.model,
      identity: policy.identity,
      ...gatewayBindingReceiptFields(policy),
      purpose: policy.purpose,
      gateway,
      hostMutationAllowed: false,
      reasoningEffort: policy.reasoningEffort,
      reasoningForwarded: reasoningReceipt.forwarded,
      reasoningControl: reasoningReceipt.control,
      reasoningEvidence: reasoningReceipt.evidence,
      ...completionEvidence,
      dispatchID,
      logicalDispatchID: dispatchBegin.data?.logicalDispatchID || dispatchID,
      attempt,
      failureClass: failure.failureClass,
      errorCode: failure.errorCode,
      httpStatus: failure.httpStatus,
      rawErrorDigest: failure.rawErrorDigest,
      backendRequestID: failure.backendRequestID,
      backendResponseID: failure.backendResponseID,
      goalStatus,
      error: terminalUpdate.ok
        ? failure.operatorMessage
        : `dispatch_registry_update_failed: ${safeErrorText(terminalUpdate.error || "unknown")}; gateway_error=${failure.operatorMessage}`
    };
  }
  const output = capText(parsed.output || extractResponsesText(result.json), policy.outputCapChars);
  const receiptID = `gateway-dispatch-${policy.model}-${Date.now()}`;
  const terminalUpdate = recordDispatchCLI([
    "os", "dispatch", "update", "--contract", policy.contractID, "--dispatch", dispatchID,
    "--status", "completed", "--receipt", receiptID, "--output-ref", `chars:${output.length}`,
    "--json",
  ]);
  if (!terminalUpdate.ok) {
    return {
      schema: "TatwoGatewayDispatchReceiptV1",
      ok: false,
      status: "failed",
      contractID: policy.contractID,
      goalID: policy.goalID,
      model: policy.model,
      identity: policy.identity,
      ...gatewayBindingReceiptFields(policy),
      purpose: policy.purpose,
      gateway,
      hostMutationAllowed: false,
      reasoningEffort: policy.reasoningEffort,
      reasoningForwarded: reasoningReceipt.forwarded,
      reasoningControl: reasoningReceipt.control,
      reasoningEvidence: reasoningReceipt.evidence,
      ...completionEvidence,
      error: `dispatch_registry_update_failed: ${safeErrorText(terminalUpdate.error || "unknown")}`
    };
  }
  return {
    schema: "TatwoGatewayDispatchReceiptV1",
    ok: true,
    status: "completed",
    contractID: policy.contractID,
    goalID: policy.goalID,
    model: policy.model,
    identity: policy.identity,
    ...gatewayBindingReceiptFields(policy),
    purpose: policy.purpose,
    gateway,
    hostMutationAllowed: false,
    reasoningEffort: policy.reasoningEffort,
    reasoningForwarded: reasoningReceipt.forwarded,
    reasoningControl: reasoningReceipt.control,
    reasoningEvidence: reasoningReceipt.evidence,
    ...completionEvidence,
    output,
    outputChars: output.length,
    receiptID,
    routeHealth: healthSnapshot.decision.receipt,
  };
}

async function gatewayFanoutReceipt(args = {}) {
  const contractID = contractIDFromArgs(args);
  if (!contractID) return failClosedGatewayReceipt("tatwo_gateway_fanout", args, "missing contractID; call tatwo_os_begin first");
  const commonPrompt = String(args.prompt ?? args.objective ?? "").trim();
  const requests = Array.isArray(args.requests)
    ? args.requests
    : modelListFromArgs(args.models).map((model) => ({ model, prompt: commonPrompt, identity: args.identity || "sub" }));
  if (!requests.length) return failClosedGatewayReceipt("tatwo_gateway_fanout", args, "missing requests/models");
  const maxFanout = Math.min(Math.max(Number(args.maxFanout ?? 4) || 4, 1), 8);
  const selected = requests.slice(0, maxFanout);
  const skipped = requests.slice(maxFanout).map((request) => request.model || request);
  const childReceipts = [];
  for (const request of selected) {
    childReceipts.push(await gatewayDispatchReceipt({
      ...args,
      ...request,
      contractID,
      goalID: args.goalID ?? args.goal,
      dryRun: args.dryRun === true,
      prompt: request.prompt ?? commonPrompt,
      purpose: request.purpose ?? args.purpose ?? "fanout-subtask",
      identity: request.identity ?? args.identity ?? "sub"
    }));
  }
  const ok = childReceipts.every((receipt) => receipt.ok);
  return {
    schema: "TatwoGatewayFanoutReceiptV1",
    ok,
    status: ok ? (args.dryRun === true ? "dry_run" : "completed") : "partial_or_failed",
    contractID,
    goalID: String(args.goalID ?? args.goal ?? ""),
    gateway: gatewayBaseURL(),
    hostMutationAllowed: false,
    fanoutCount: childReceipts.length,
    skippedByCap: skipped,
    receipts: childReceipts
  };
}

function gatewayDispatchPolicy(args = {}) {
  const contractID = contractIDFromArgs(args);
  const goalID = String(args.goalID ?? args.goal ?? "").trim();
  const model = normalizeGatewayModel(args.model);
  const identity = String(args.identity ?? args.role ?? "sub").trim() || "sub";
  const purpose = String(args.purpose ?? args.objective ?? "TATWO gateway subtask").trim();
  const rawPrompt = String(args.prompt ?? args.input ?? args.objective ?? "");
  const hardPromptCap = 32_768;
  const requestedPromptCap = Math.min(
    Math.max(Number(args.maxPromptChars ?? hardPromptCap) || hardPromptCap, 1),
    hardPromptCap);
  const prompt = rawPrompt.trim();
  const outputCapChars = Math.min(Math.max(Number(args.maxOutputChars ?? 12000) || 12000, 1000), 30000);
  const rawReasoningEffort =
    args.reasoningEffort
    ?? args.reasoning
    ?? args["reasoning-effort"]
    ?? process.env.TATWO_GATEWAY_REASONING_EFFORT;
  const reasoningEffortWasExplicit =
    rawReasoningEffort !== undefined
    && rawReasoningEffort !== null
    && String(rawReasoningEffort).trim() !== "";
  const reasoningEffort = normalizeReasoningEffort(rawReasoningEffort ?? "xhigh");

  if (!contractID) {
    return { ok: false, receipt: failClosedGatewayReceipt("tatwo_gateway_dispatch", args, "missing contractID; call tatwo_os_begin first") };
  }
  if (!model) {
    return { ok: false, receipt: failClosedGatewayReceipt("tatwo_gateway_dispatch", args, "missing model") };
  }
  if (!gatewayDispatchAllowedModels.has(model)) {
    return { ok: false, receipt: failClosedGatewayReceipt("tatwo_gateway_dispatch", args, `model not allowlisted by TATWO OS: ${model}`) };
  }
  if (gatewayDispatchExpensiveModels.has(model) && args.allowExpensive !== true) {
    return { ok: false, receipt: failClosedGatewayReceipt("tatwo_gateway_dispatch", args, `${model} is expensive/limited; pass allowExpensive=true for an explicit human-approved dispatch`) };
  }
  if (rawPrompt.length > hardPromptCap) {
    return {
      ok: false,
      receipt: failClosedGatewayReceipt(
        "tatwo_gateway_dispatch",
        args,
        `prompt_hard_cap_exceeded: ${rawPrompt.length} > ${hardPromptCap}; split into <=16KB map chunks and a synthesis pass`)
    };
  }
  if (rawPrompt.length > requestedPromptCap) {
    return {
      ok: false,
      receipt: failClosedGatewayReceipt(
        "tatwo_gateway_dispatch",
        args,
        `prompt_cap_exceeded: ${rawPrompt.length} > ${requestedPromptCap}; chunk instead of truncating`)
    };
  }
  if (!prompt) {
    return { ok: false, receipt: failClosedGatewayReceipt("tatwo_gateway_dispatch", args, "missing prompt/input/objective") };
  }
  const violation = gatewayPromptPolicyViolation(prompt);
  if (violation) {
    return { ok: false, receipt: failClosedGatewayReceipt("tatwo_gateway_dispatch", args, violation) };
  }
  return {
    ok: true,
    contractID,
    goalID,
    model,
    identity,
    purpose,
    prompt,
    outputCapChars,
    reasoningEffort,
    reasoningEffortWasExplicit,
  };
}

function gatewayFailureReceiptData(result, parsed) {
  const rawMaterial =
    result.text
    || (result.json ? JSON.stringify(result.json) : "")
    || String(result.error || parsed.error || `HTTP ${result.status}`);
  const backendErrorCode = String(
    parsed.errorCode
    || parsed.errorKind
    || result.json?.error?.code
    || (result.status ? `http_${result.status}` : "gateway_error")
  ).trim();
  const errorCode = sanitizeGatewayErrorCode(backendErrorCode, result.status);
  const failureClass = classifyGatewayFailure(errorCode, parsed.error, result.status);
  const backendResponseID =
    String(parsed.responseID || result.json?.id || "").trim().slice(0, 160) || null;
  const requestMatch = String(parsed.error || rawMaterial)
    .match(/\b(?:request(?:\s+ID)?|req(?:uest)?[_-]?id)\s*[:=]?\s*([A-Za-z0-9_-]{6,})/i);
  const backendRequestID = requestMatch?.[1]?.slice(0, 160) || null;
  const detail = String(
    parsed.error
    || result.error
    || result.json?.error?.message
    || `HTTP ${result.status}`
  );
  const identifiers = [
    backendResponseID ? `response=${backendResponseID}` : null,
    backendRequestID ? `request=${backendRequestID}` : null,
  ].filter(Boolean).join(" ");
  const operatorMessage = capText(
    `${errorCode}: ${sanitizeOperatorError(detail)}${identifiers ? ` (${identifiers})` : ""}`,
    512);
  return {
    failureClass,
    errorCode,
    httpStatus: Number.isFinite(result.status) ? Number(result.status) : null,
    rawErrorDigest: `sha256:${crypto.createHash("sha256").update(rawMaterial).digest("hex")}`,
    backendRequestID,
    backendResponseID,
    operatorMessage,
  };
}

function classifyGatewayFailure(code, message, httpStatus = 0) {
  const text = `${code || ""} ${message || ""}`.toLowerCase();
  if (/(policy.?violation|scope.?violation|fatal|invalid_contract|unauthorized_host_mutation|model_attestation|fallback_(?:attestation_missing|detected)|provider_response_id_missing|reasoning_attestation|blocker_reported|tool_unavailable|tool_error)/i.test(text)) {
    return "terminal";
  }
  if (/(server_error|timeout|timed out|session_limit|rate.?limit|network|connection reset|temporarily unavailable)/i.test(text)) {
    return "retryable";
  }
  if (Number(httpStatus) >= 500 && Number(httpStatus) <= 599) {
    return "retryable";
  }
  return "unknown";
}

function sanitizeGatewayErrorCode(value, httpStatus = 0) {
  const normalized = String(value ?? "").trim().toLowerCase();
  const known = new Set([
    "server_error", "timeout", "session_limit", "rate_limit", "network_error",
    "connection_reset", "temporarily_unavailable", "policy_violation", "scope_violation",
    "fatal", "invalid_contract", "unauthorized_host_mutation", "response_failed",
    "degraded_completion", "operational_failure", "gateway_error",
    "model_attestation_missing", "model_attestation_mismatch",
    "fallback_attestation_missing", "fallback_detected",
    "provider_response_id_missing", "reasoning_attestation_missing",
    "reasoning_attestation_mismatch", "blocker_reported",
    "tool_unavailable", "tool_error",
  ]);
  if (known.has(normalized)) return normalized;
  if (/^http_[1-5][0-9]{2}$/.test(normalized)) return normalized;
  if (Number(httpStatus) >= 100 && Number(httpStatus) <= 599) {
    return `http_${Number(httpStatus)}`;
  }
  return "gateway_error";
}

function sanitizeOperatorError(value) {
  return String(value ?? "")
    .replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/g, "Bearer [redacted]")
    .replace(/"encrypted_content"\s*:\s*"[^"]*"/gi, "\"encrypted_content\":\"[redacted]\"")
    .replace(/\b[A-Za-z0-9_-]{64,}\b/g, "[redacted-opaque]")
    .replace(/\s+/g, " ")
    .trim();
}

function contractIDFromArgs(args = {}) {
  const contractID = String(args.contractID ?? args.contract ?? "").trim();
  if (!contractID) return "";
  return contractID;
}

function normalizeGatewayModel(model) {
  const raw = String(model ?? "").trim();
  if (!raw) return "";
  return gatewayModelAliases.get(raw) || gatewayModelAliases.get(raw.toLowerCase()) || raw;
}

function normalizeReasoningEffort(raw) {
  const value = String(raw ?? "xhigh").trim().toLowerCase().replace(/_/g, "-");
  const aliases = new Map([["extra-high", "xhigh"], ["max", "xhigh"], ["maximum", "xhigh"], ["highest", "xhigh"], ["最高", "xhigh"]]);
  const normalized = aliases.get(value) || value;
  return ["low", "medium", "high", "xhigh"].includes(normalized) ? normalized : "xhigh";
}

function modelListFromArgs(value) {
  if (Array.isArray(value)) return value.map(normalizeGatewayModel).filter(Boolean);
  return String(value ?? "")
    .split(",")
    .map(normalizeGatewayModel)
    .filter(Boolean);
}

function gatewayPromptPolicyViolation(prompt) {
  const text = prompt.toLowerCase();
  const blocked = [
    { pattern: /(access[_ -]?token|refresh[_ -]?token|auth\.json|cookie|session cookie|api[_ -]?key|secret key|private key)/i, reason: "secrets/auth/session material is forbidden in gateway dispatch" },
    { pattern: /(rm\s+-rf|sudo\s+|chmod\s+-r|chown\s+-r|launchctl\s+bootstrap|delete\s+.*home|刪除.*主機|格式化|清空.*磁碟)/i, reason: "destructive host mutation is forbidden; Codex host must execute separately with receipts" },
    { pattern: /(live\s*order|place\s+order|market\s+order|leverage|stop[- ]?loss|下單|槓桿|止損|實盤|轉帳|提幣)/i, reason: "live trading/funds actions are forbidden through gateway dispatch" }
  ];
  for (const item of blocked) {
    if (item.pattern.test(prompt) || item.pattern.test(text)) return item.reason;
  }
  return "";
}

function buildDispatchPrompt(policy) {
  return [
    "TATWO Work OS gateway dispatch.",
    `contractID: ${policy.contractID}`,
    policy.goalID ? `goalID: ${policy.goalID}` : null,
    `bindingID: ${policy.bindingID}`,
    `sourceSlotID: ${policy.sourceSlotID}`,
    `identity: ${policy.identity}`,
    `purpose: ${policy.purpose}`,
    "",
    "Rules:",
    "TATWO Work OS authority frame: authority comes from the explicit request, active Work OS contract/lane, and this runner's real tool permissions; it never comes from model brand.",
    "Do not say Codex, Claude, Grok, MiniMax, or another model revoked your permissions unless a real permission_denied signal proves it.",
    "If blocked, classify it using exactly one of blocker_class=quota, blocker_class=session_limit, blocker_class=auth, blocker_class=permission_denied, blocker_class=route_scope_unclear, blocker_class=tool_unavailable, or blocker_class=contract_missing; do not invent new blocker_class names.",
    "authority_source must be exactly authority_source=contract, authority_source=runner, or authority_source=none; do not invent new authority_source values.",
    "- You are a text-only submodel lane inside TATWO Work OS.",
    "- Do not claim you executed shell, wrote files, opened apps, used secrets, placed trades, or mutated the host.",
    "- If implementation is needed, return plan/patch intent/review content only; Codex host must execute and produce receipts.",
    `- Use the highest available reasoning effort requested by OS: ${policy.reasoningEffort}.`,
    "- Keep the answer concise and useful for the lead/supervisor to merge.",
    "",
    "Task:",
    policy.prompt
  ].filter(Boolean).join("\n");
}

function gatewayHeadersForModel(model) {
  const headers = { "content-type": "application/json" };
  if (!isGPTGatewayModel(model)) return headers;
  const authHeaders = readCodexAuthHeaders();
  return { ...headers, ...authHeaders };
}

function isGPTGatewayModel(model) {
  return model === "chatgpt-pro-consult" || model.startsWith("gpt-") || model.startsWith("codex-");
}

function isClaudeGatewayModel(model) {
  return ["fable-5", "opus-5", "sonnet-5", "haiku-4-5"].includes(model);
}

function isGrokGatewayModel(model) {
  return model === "grok-build";
}

function gatewayModelSupportsNativeReasoningControl(model) {
  return isGPTGatewayModel(model)
    || isClaudeGatewayModel(model)
    || isGrokGatewayModel(model);
}

function normalizeGatewayReasoningControl(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const stringOrNull = (field) =>
    typeof field === "string" && field.trim() ? field.trim() : null;
  return {
    requested: stringOrNull(value.requested),
    normalized: stringOrNull(value.normalized),
    provider: stringOrNull(value.provider),
    cli_flag: stringOrNull(value.cli_flag ?? value.cliFlag),
    forwarded: value.forwarded === true,
    effective_attested:
      value.effective_attested === true || value.effectiveAttested === true,
  };
}

function gatewayReasoningReceipt(policy, parsed, _result) {
  const requested = policy.reasoningEffort;
  if (!gatewayModelSupportsNativeReasoningControl(policy.model)) {
    return {
      forwarded: false,
      control: null,
      evidence: {
        requested,
        observed: null,
        responseAttested: false,
        effectiveProviderAttested: false,
        limitation: "route does not expose native reasoning-control attestation",
      },
    };
  }
  const control = normalizeGatewayReasoningControl(parsed?.reasoningControl);
  if (!control) {
    return {
      forwarded: false,
      control: null,
      evidence: {
        requested,
        observed: null,
        responseAttested: false,
        effectiveProviderAttested: false,
        limitation: isGPTGatewayModel(policy.model)
          ? "gateway request included reasoning.effort, but the provider response did not attest forwarding or effective effort"
          : "gateway response omitted reasoning_control; requested effort is known, observed/forwarded effort is not",
      },
    };
  }
  const expectedProvider = isGrokGatewayModel(policy.model)
    ? "grok_cli"
    : isClaudeGatewayModel(policy.model)
      ? "claude_cli"
      : null;
  const expectedFlag = isGrokGatewayModel(policy.model)
    ? "--reasoning-effort"
    : isClaudeGatewayModel(policy.model)
      ? "--effort"
      : null;
  const forwarded =
    control?.forwarded === true
    && control.requested === requested
    && control.normalized === requested
    && (expectedProvider === null || control.provider === expectedProvider)
    && (expectedFlag === null || control.cli_flag === expectedFlag);
  return {
    forwarded,
    control,
    evidence: {
      requested,
      observed: control.normalized,
      responseAttested: true,
      effectiveProviderAttested: control.effective_attested,
      provider: control.provider,
      cliFlag: control.cli_flag,
      limitation: control.effective_attested
        ? null
        : "gateway attests request forwarding/normalization only; provider-internal effective effort is not independently exposed",
    },
  };
}

function gatewayStrictAttestationRequired(model) {
  return gatewayStrictAttestationModels.has(normalizeGatewayModel(model));
}

function expectedStrictGatewayVendorModel(model) {
  const canonical = normalizeGatewayModel(model);
  if (canonical === "grok-build") return "grok-4.6";
  return null;
}

function normalizedGatewayVendorModel(value) {
  return String(value ?? "")
    .trim()
    .toLowerCase()
    .replace(/\[[^\]]+\]$/, "");
}

function canonicalGatewayModelEvidence(value) {
  const normalized = normalizedGatewayVendorModel(value);
  if (!normalized) return "";
  if (/^claude-fable-5(?:-\d{8})?$/.test(normalized)) return "fable-5";
  if (/^claude-opus-5(?:-\d{8})?$/.test(normalized)) return "opus-5";
  if (/^claude-sonnet-5(?:-\d{8})?$/.test(normalized)) return "sonnet-5";
  if (/^claude-haiku-4-5(?:-\d{8})?$/.test(normalized)) return "haiku-4-5";
  if (normalized === "grok-4.6") return "grok-build";
  return normalizeGatewayModel(normalized);
}

function finiteNonNegativeIntegerOrNull(value) {
  if (value === null || value === undefined || value === "") return null;
  const number = Number(value);
  return Number.isInteger(number) && number >= 0 ? number : null;
}

function gatewayModelAttestationReceipt(policy, parsed) {
  const required = gatewayStrictAttestationRequired(policy.model);
  const raw =
    parsed?.modelAttestation
    && typeof parsed.modelAttestation === "object"
    && !Array.isArray(parsed.modelAttestation)
      ? parsed.modelAttestation
      : null;
  const requestedCanonicalModel = normalizeGatewayModel(policy.model);
  const attestedRequestedCanonicalModel = canonicalGatewayModelEvidence(
    raw?.requested_model ?? raw?.requestedModel,
  );
  const gatewayReportedRequestedCanonicalModel = canonicalGatewayModelEvidence(
    parsed?.requestedModel,
  );
  const gatewayReportedCanonicalModel = canonicalGatewayModelEvidence(
    parsed?.model,
  );
  const gatewayReportedActualCanonicalModel = canonicalGatewayModelEvidence(
    parsed?.actualModel,
  );
  const actualVendorModel = normalizedGatewayVendorModel(
    raw?.actual_vendor_model
      ?? raw?.actualVendorModel
      ?? parsed?.actualModel,
  );
  const actualCanonicalModel = canonicalGatewayModelEvidence(
    raw?.actual_canonical_model
      ?? raw?.actualCanonicalModel
      ?? actualVendorModel,
  );
  const requiredVendorModel = expectedStrictGatewayVendorModel(policy.model);
  const requiredVendorModelMatches =
    requiredVendorModel === null || actualVendorModel === requiredVendorModel;
  const fallbackValues = [
    raw?.fallback_count,
    raw?.fallbackCount,
    parsed?.attestedFallbackCount,
    parsed?.reportedFallbackCount,
  ]
    .map(finiteNonNegativeIntegerOrNull)
    .filter(value => value !== null);
  const fallbackCount = fallbackValues[0] ?? null;
  const fallbackEvidenceConsistent =
    fallbackValues.length > 0
    && fallbackValues.every(value => value === fallbackCount);
  const responseID = String(parsed?.responseID ?? "").trim() || null;
  const schema = String(raw?.schema ?? "").trim() || null;
  const rawOutcome = String(raw?.outcome ?? "").trim() || null;
  const rawExact = raw?.exact === true;
  const rawSchemaAccepted = [
    "TatwoGatewayModelAttestationV1",
    "TatwoModelExecutionAttestationV1",
  ].includes(schema);
  const exact =
    raw !== null
    && rawSchemaAccepted
    && rawOutcome === "VERIFIED_EXACT"
    && rawExact
    && attestedRequestedCanonicalModel === requestedCanonicalModel
    && actualCanonicalModel === requestedCanonicalModel
    && canonicalGatewayModelEvidence(actualVendorModel) === requestedCanonicalModel
    && requiredVendorModelMatches
    && (!gatewayReportedRequestedCanonicalModel
      || gatewayReportedRequestedCanonicalModel === requestedCanonicalModel)
    && (!gatewayReportedCanonicalModel
      || gatewayReportedCanonicalModel === requestedCanonicalModel)
    && (!gatewayReportedActualCanonicalModel
      || gatewayReportedActualCanonicalModel === requestedCanonicalModel)
    && fallbackEvidenceConsistent
    && fallbackCount === 0
    && responseID !== null;

  let failureCode = null;
  let failureDetail = null;
  if (required && responseID === null) {
    failureCode = "provider_response_id_missing";
    failureDetail = "strict route completion omitted provider response ID";
  } else if (required && raw === null) {
    failureCode = "model_attestation_missing";
    failureDetail = "strict route completion omitted model_attestation";
  } else if (required && fallbackCount === null) {
    failureCode = "fallback_attestation_missing";
    failureDetail = "strict route completion omitted fallback_count";
  } else if (required && (!fallbackEvidenceConsistent || fallbackCount !== 0)) {
    failureCode = "fallback_detected";
    failureDetail = `strict route fallback_count=${fallbackCount ?? "inconsistent"}`;
  } else if (required && (
    !rawSchemaAccepted
    || rawOutcome !== "VERIFIED_EXACT"
    || !rawExact
    || attestedRequestedCanonicalModel !== requestedCanonicalModel
    || actualCanonicalModel !== requestedCanonicalModel
    || canonicalGatewayModelEvidence(actualVendorModel) !== requestedCanonicalModel
    || !requiredVendorModelMatches
    || (
      gatewayReportedRequestedCanonicalModel
      && gatewayReportedRequestedCanonicalModel !== requestedCanonicalModel
    )
    || (
      gatewayReportedCanonicalModel
      && gatewayReportedCanonicalModel !== requestedCanonicalModel
    )
    || (
      gatewayReportedActualCanonicalModel
      && gatewayReportedActualCanonicalModel !== requestedCanonicalModel
    )
  )) {
    failureCode = "model_attestation_mismatch";
    failureDetail = [
      `requested=${requestedCanonicalModel}`,
      `attested_requested=${attestedRequestedCanonicalModel || "missing"}`,
      `actual_canonical=${actualCanonicalModel || "missing"}`,
      `actual_vendor=${actualVendorModel || "missing"}`,
      `required_vendor=${requiredVendorModel || "canonical-only"}`,
      `outcome=${rawOutcome || "missing"}`,
    ].join(" ");
  }

  return {
    schema: "TatwoGatewayDispatchModelAttestationV1",
    required,
    verified: required ? exact : null,
    evidenceSource: raw ? "gateway_response.model_attestation" : null,
    requestedCanonicalModel,
    attestedRequestedCanonicalModel:
      attestedRequestedCanonicalModel || null,
    gatewayReportedRequestedCanonicalModel:
      gatewayReportedRequestedCanonicalModel || null,
    gatewayReportedCanonicalModel: gatewayReportedCanonicalModel || null,
    gatewayReportedActualCanonicalModel:
      gatewayReportedActualCanonicalModel || null,
    actualCanonicalModel: actualCanonicalModel || null,
    actualVendorModel: actualVendorModel || null,
    requiredVendorModel,
    fallbackCount,
    fallbackEvidenceConsistent,
    providerResponseID: responseID,
    providerAttestationSchema: schema,
    providerOutcome: rawOutcome,
    outcome: required
      ? exact ? "VERIFIED_EXACT" : "FAIL_CLOSED"
      : "NOT_REQUIRED",
    limitation: required
      ? null
      : "provider exact-model/fallback attestation is not required for this non-strict route; absent provider fields remain null",
    failureCode,
    failureDetail,
  };
}

function gatewayCompletedBlockerClass(parsed) {
  const explicit = String(parsed?.blockerClass ?? "").trim().toLowerCase();
  const clearMarkers = new Set([
    "none",
    "clear",
    "not_blocked",
    "no_blocker",
  ]);
  let pendingFence = null;
  const authoritativeBlockerClass = (rawLine) => {
    const line = String(rawLine ?? "").trim();
    if (line.startsWith(">")) return null;
    const textMatch = line.match(
      /^blocker_class\s*[:=]\s*([a-z0-9._-]+)/i,
    );
    const blockerClass = String(textMatch?.[1] ?? "").toLowerCase();
    return blockerClass && !clearMarkers.has(blockerClass)
      ? blockerClass
      : null;
  };
  for (const rawLine of String(parsed?.output ?? "").split(/\r?\n/)) {
    const line = rawLine.trim();
    if (pendingFence) {
      const closer = line.match(/^(`{3,}|~{3,})\s*$/)?.[1] ?? "";
      if (
        closer
        && closer[0] === pendingFence.marker
        && closer.length >= pendingFence.length
      ) {
        pendingFence = null;
      } else {
        pendingFence.lines.push(rawLine);
      }
      continue;
    }
    const opener = line.match(/^(`{3,}|~{3,})/)?.[1] ?? "";
    if (opener) {
      pendingFence = {
        marker: opener[0],
        length: opener.length,
        lines: [],
      };
      continue;
    }
    const blockerClass = authoritativeBlockerClass(rawLine);
    if (blockerClass) return blockerClass;
  }
  // A complete fenced block is historical quoted evidence. An unterminated
  // block is malformed/ambiguous, so its pending lines are scanned fail-closed
  // rather than suppressing a later authoritative blocker through EOF.
  for (const rawLine of pendingFence?.lines ?? []) {
    const blockerClass = authoritativeBlockerClass(rawLine);
    if (blockerClass) return blockerClass;
  }
  // A provider-level "none" marker must never suppress a current authoritative
  // bare blocker line in the completed text. Contradictory evidence fails
  // closed, with the concrete textual blocker preserved for classification.
  if (explicit && !clearMarkers.has(explicit)) return explicit;
  return null;
}

function gatewayCompletionValidation(policy, parsed, reasoningReceipt) {
  const modelAttestation = gatewayModelAttestationReceipt(policy, parsed);
  if (parsed?.failed) {
    return {
      ok: false,
      errorCode: parsed.errorCode || parsed.errorKind || "gateway_error",
      error: parsed.error || "gateway response failed",
      modelAttestation,
    };
  }
  const blockerClass = gatewayCompletedBlockerClass(parsed);
  if (blockerClass) {
    return {
      ok: false,
      errorCode: blockerClass === "tool_unavailable"
        ? "tool_unavailable"
        : "blocker_reported",
      error: `completed response reported blocker_class=${blockerClass}`,
      modelAttestation,
    };
  }
  if (parsed?.structuredToolFailure) {
    return {
      ok: false,
      errorCode: "tool_error",
      error: `completed response contained structured tool failure: ${parsed.structuredToolFailure}`,
      modelAttestation,
    };
  }
  if (modelAttestation.required && !modelAttestation.verified) {
    return {
      ok: false,
      errorCode: modelAttestation.failureCode || "model_attestation_mismatch",
      error: modelAttestation.failureDetail
        || "strict route exact-model attestation failed",
      modelAttestation,
    };
  }
  if (modelAttestation.required && reasoningReceipt.forwarded !== true) {
    return {
      ok: false,
      errorCode: reasoningReceipt.control
        ? "reasoning_attestation_mismatch"
        : "reasoning_attestation_missing",
      error: reasoningReceipt.control
        ? "strict route reasoning_control does not match the requested effort/provider/CLI flag"
        : "strict route completion omitted reasoning_control",
      modelAttestation,
    };
  }
  return { ok: true, errorCode: null, error: null, modelAttestation };
}

function gatewayCompletionReceiptFields(
  policy,
  parsed,
  reasoningReceipt,
  modelAttestation,
) {
  return {
    requestedCanonicalModel: normalizeGatewayModel(policy.model),
    actualCanonicalModel: modelAttestation.actualCanonicalModel,
    actualVendorModel: modelAttestation.actualVendorModel,
    fallbackCount: modelAttestation.fallbackCount,
    responseID: modelAttestation.providerResponseID,
    modelAttestation,
    providerEvidenceLimitations: [
      modelAttestation.limitation,
      reasoningReceipt.evidence?.limitation,
    ].filter(Boolean),
  };
}

function readCodexAuthHeaders() {
  if (process.env.TATWO_GATEWAY_USE_CODEX_AUTH === "0") return {};
  const authPath = path.join(process.env.CODEX_HOME || path.join(os.homedir(), ".codex"), "auth.json");
  try {
    const auth = JSON.parse(fs.readFileSync(authPath, "utf8"));
    const token = auth?.tokens?.access_token || auth?.access_token;
    const account = auth?.tokens?.account_id || auth?.account_id;
    const headers = {};
    if (token) headers.authorization = `Bearer ${token}`;
    if (account) headers["ChatGPT-Account-ID"] = account;
    headers["OpenAI-Beta"] = "codex-1";
    headers.originator = "Codex Desktop";
    return headers;
  } catch {
    return {};
  }
}

async function fetchJSON(url, options = {}, timeoutMS = 30000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMS);
  try {
    const res = await fetch(url, { ...options, signal: controller.signal });
    const text = await res.text();
    let jsonPayload = null;
    try {
      jsonPayload = text ? JSON.parse(text) : null;
    } catch {
      // non-JSON response is still returned as text for compact diagnostics
    }
    return { ok: res.ok, status: res.status, json: jsonPayload, text };
  } catch (error) {
    return { ok: false, status: 0, json: null, text: "", error: error?.name === "AbortError" ? `timeout after ${timeoutMS}ms` : error?.message || String(error) };
  } finally {
    clearTimeout(timer);
  }
}

function extractResponsesText(payload) {
  if (!payload || typeof payload !== "object") return "";
  if (typeof payload.output_text === "string") return payload.output_text;
  const output = Array.isArray(payload.output) ? payload.output : [];
  const parts = [];
  for (const item of output) {
    if (!item || typeof item !== "object") continue;
    if (typeof item.text === "string") parts.push(item.text);
    const content = Array.isArray(item.content) ? item.content : [];
    for (const part of content) {
      if (!part || typeof part !== "object") continue;
      if (typeof part.text === "string") parts.push(part.text);
      else if (typeof part.output_text === "string") parts.push(part.output_text);
    }
  }
  return parts.join("\n").trim();
}

function gatewayResponseMetadata(payload) {
  const nested =
    payload?.response
    && typeof payload.response === "object"
    && !Array.isArray(payload.response)
      ? payload.response
      : null;
  const sources = [nested, payload].filter(Boolean);
  const firstValue = (...keys) => {
    for (const source of sources) {
      for (const key of keys) {
        if (source?.[key] !== undefined && source?.[key] !== null) {
          return source[key];
        }
      }
    }
    return null;
  };
  const modelAttestation = firstValue(
    "model_attestation",
    "modelAttestation",
  );
  const attestedFallbackCount = finiteNonNegativeIntegerOrNull(
    modelAttestation?.fallback_count ?? modelAttestation?.fallbackCount,
  );
  const reportedFallbackCount = finiteNonNegativeIntegerOrNull(
    firstValue(
      "fallback_count",
      "fallbackCount",
      "fallback_event_count",
      "fallbackEventCount",
    ),
  );
  return {
    responseID:
      String(firstValue("id", "response_id", "responseID") ?? "").trim()
      || null,
    requestedModel:
      String(firstValue("requested_model", "requestedModel") ?? "").trim()
      || null,
    model: String(firstValue("model") ?? "").trim() || null,
    actualModel:
      String(firstValue("actual_model", "actualModel") ?? "").trim()
      || null,
    fallbackCount: attestedFallbackCount ?? reportedFallbackCount,
    attestedFallbackCount,
    reportedFallbackCount,
    modelAttestation:
      modelAttestation
      && typeof modelAttestation === "object"
      && !Array.isArray(modelAttestation)
        ? modelAttestation
        : null,
    blockerClass:
      String(firstValue("blocker_class", "blockerClass") ?? "").trim()
      || null,
    structuredToolFailure: gatewayStructuredToolFailure(sources),
    reasoningControl: normalizeGatewayReasoningControl(
      firstValue("reasoning_control", "reasoningControl"),
    ),
  };
}

function gatewayStructuredToolFailure(sources) {
  for (const source of sources) {
    const direct = source?.tool_error ?? source?.toolError;
    if (direct) {
      return capText(
        typeof direct === "string"
          ? direct
          : direct.message || JSON.stringify(direct),
        512,
      );
    }
    for (const item of Array.isArray(source?.output) ? source.output : []) {
      const type = String(item?.type ?? "").trim().toLowerCase();
      const status = String(item?.status ?? "").trim().toLowerCase();
      if (
        (
          type.includes("tool")
          || type.includes("function")
        )
        && (
          type.includes("error")
          || ["failed", "error", "incomplete"].includes(status)
          || item?.error
        )
      ) {
        return capText(
          String(
            item?.error?.message
            ?? item?.error
            ?? item?.message
            ?? `${type || "tool"}:${status || "error"}`,
          ),
          512,
        );
      }
    }
  }
  return null;
}

function gatewayTerminalDecision(value) {
  const terminalStatus = String(value ?? "").trim().toLowerCase();
  return {
    completed: terminalStatus === "completed",
    terminalStatus: terminalStatus || "unknown",
  };
}

function failedGatewayTerminalPayload(payload, terminalStatus, output = "") {
  const error = payload?.error && typeof payload.error === "object" ? payload.error : {};
  const metadata = gatewayResponseMetadata(payload);
  const detail =
    error.message
    || extractResponsesText(payload)
    || output
    || `gateway terminal status ${terminalStatus}`;
  const errorCode = String(
    error.code
    ?? payload?.error_kind
    ?? payload?.errorKind
    ?? terminalStatus);
  return {
    failed: true,
    error: `${terminalStatus}: ${detail}`,
    output: "",
    ...metadata,
    terminalStatus,
    errorKind: errorCode,
    errorCode,
    resetAt: payload?.reset_at ?? payload?.resetAt ?? null,
  };
}

function parseGatewayResponsePayload(result) {
  if (result.json && typeof result.json === "object") {
    const metadata = gatewayResponseMetadata(result.json);
    const terminal = gatewayTerminalDecision(result.json.status);
    if (!terminal.completed) {
      return failedGatewayTerminalPayload(result.json, terminal.terminalStatus);
    }
    if (result.json.response && typeof result.json.response === "object") {
      const nestedTerminal = gatewayTerminalDecision(result.json.response.status);
      if (!nestedTerminal.completed) {
        return failedGatewayTerminalPayload(
          result.json.response,
          nestedTerminal.terminalStatus,
          extractResponsesText(result.json));
      }
    }
    if (result.json.error) {
      return {
        failed: true,
        error: result.json.error.message || JSON.stringify(result.json.error),
        output: "",
        ...metadata,
        errorKind: String(result.json.error_kind ?? result.json.errorKind ?? ""),
        errorCode: String(
          result.json.error?.code
          ?? result.json.error_kind
          ?? result.json.errorKind
          ?? "gateway_error"),
        resetAt: result.json.reset_at ?? result.json.resetAt ?? null,
      };
    }
    const structuredErrorKind = String(result.json.error_kind ?? result.json.errorKind ?? "").trim();
    if (result.json.degraded === true || structuredErrorKind) {
      return {
        failed: true,
        error: structuredErrorKind || "degraded_completion",
        output: "",
        ...metadata,
        errorKind: structuredErrorKind || "degraded_completion",
        errorCode: structuredErrorKind || "degraded_completion",
        resetAt: result.json.reset_at ?? result.json.resetAt ?? null,
      };
    }
    const output = extractResponsesText(result.json);
    if (output.length <= 2000 && isOperationalGatewayFailureText(output)) {
      return {
        failed: true,
        error: output,
        output: "",
        ...metadata,
        errorKind: /\bsession\s+limit\b/i.test(output) ? "session_limit" : "",
        errorCode: /\bsession\s+limit\b/i.test(output) ? "session_limit" : "operational_failure",
        resetAt: result.json.reset_at ?? result.json.resetAt ?? null,
      };
    }
    return {
      failed: false,
      error: "",
      output,
      ...metadata,
    };
  }
  const text = String(result.text ?? "");
  if (!text.trim()) {
    return failedGatewayTerminalPayload({}, "unknown");
  }
  const events = parseSSEEvents(text);
  let output = "";
  let responseID = null;
  let reasoningControl = null;
  let terminalMetadata = gatewayResponseMetadata({});
  let sawCompletedTerminal = false;
  for (const event of events) {
    const terminalEventStatus = {
      "response.failed": "failed",
      "response.incomplete": "incomplete",
      "response.cancelled": "cancelled",
      "response.canceled": "cancelled",
    }[event.type];
    if (terminalEventStatus) {
      const response = event.response && typeof event.response === "object" ? event.response : {};
      if (!response.error && event.error) response.error = event.error;
      return failedGatewayTerminalPayload(
        { ...response, id: response.id || responseID },
        gatewayTerminalDecision(response.status ?? terminalEventStatus).terminalStatus,
        output.trim());
    }
    if (event.type === "response.output_text.delta" && typeof event.delta === "string") output += event.delta;
    if (event.type === "response.output_text.done" && typeof event.text === "string") output = event.text;
    if (event.type === "response.output_item.done" && event.item) {
      const itemText = extractResponsesText({ output: [event.item] });
      if (itemText) output = itemText;
    }
    if (event.type === "response.completed" && event.response) {
      const response = event.response && typeof event.response === "object" ? event.response : {};
      terminalMetadata = gatewayResponseMetadata(response);
      responseID = terminalMetadata.responseID || responseID;
      reasoningControl = terminalMetadata.reasoningControl ?? reasoningControl;
      const completedText = extractResponsesText(response);
      if (completedText) output = completedText;
      const terminal = gatewayTerminalDecision(response.status);
      if (!terminal.completed) {
        return failedGatewayTerminalPayload(
          response,
          terminal.terminalStatus,
          output.trim());
      }
      sawCompletedTerminal = true;
    }
  }
  if (!sawCompletedTerminal) {
    return failedGatewayTerminalPayload(
      { id: responseID },
      "unknown",
      output.trim());
  }
  return {
    failed: false,
    error: "",
    output: output.trim(),
    ...terminalMetadata,
    responseID,
    reasoningControl,
  };
}

function isOperationalGatewayFailureText(value) {
  return [
    /^[a-z0-9._-]+\s+backend\s+is\s+(?:temporarily\s+)?unavailable\b/i,
    /^(?:error\s*:\s*)?(?:quota|usage quota)\b.*\b(?:exhausted|exceeded|unavailable|zero)\b/i,
    /^(?:error\s*:\s*)?(?:credit|usage|account|billing)\s+balance\b.*\b(?:exhausted|insufficient|zero|empty)\b/i,
    /^(?:error\s*:\s*)?(?:rate[\s_-]*limit|too many requests|http\s*429|429\b)/i,
    /^(?:error\s*:\s*)?(?:request\s+)?(?:timed?\s*out|timeout)\b/i,
    /^(?:error\s*:\s*)?(?:you(?:'|’)ve\s+hit\s+your\s+)?session\s+limit\b/i,
    /^(?:error\s*:\s*)?backend\b.*\bunavailable\b/i,
  ].some(pattern => pattern.test(String(value ?? "").trim()));
}

function parseSSEEvents(text) {
  const events = [];
  for (const block of String(text).split(/\r?\n\r?\n/)) {
    const dataLines = block
      .split(/\r?\n/)
      .filter((line) => line.startsWith("data:"))
      .map((line) => line.slice(5).trim());
    if (!dataLines.length) continue;
    const payload = dataLines.join("\n").trim();
    if (!payload || payload === "[DONE]") continue;
    try {
      events.push(JSON.parse(payload));
    } catch {
      // Ignore non-JSON SSE data.
    }
  }
  return events;
}

function capText(text, maxChars) {
  const value = String(text ?? "");
  if (!Number.isFinite(maxChars) || maxChars <= 0 || value.length <= maxChars) return value;
  return `${value.slice(0, maxChars)}\n\n[truncated_by_tatwo_mcp chars=${value.length} cap=${maxChars}]`;
}

function safeErrorText(text) {
  return capText(String(text ?? "").replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/g, "Bearer [redacted]"), 1000);
}

function redactGatewayPayload(payload) {
  return JSON.parse(JSON.stringify(payload, (key, value) => {
    if (/token|authorization|cookie|secret|account/i.test(key)) return "[redacted]";
    return value;
  }));
}

function failClosedGatewayReceipt(toolName, args = {}, reason) {
  return {
    schema: "TatwoGatewayDispatchReceiptV1",
    ok: false,
    status: "fail_closed",
    toolName,
    contractID: String(args.contractID ?? args.contract ?? ""),
    goalID: String(args.goalID ?? args.goal ?? ""),
    model: normalizeGatewayModel(args.model),
    reasoningEffort: normalizeReasoningEffort(args.reasoningEffort ?? args.reasoning ?? args["reasoning-effort"] ?? process.env.TATWO_GATEWAY_REASONING_EFFORT ?? "xhigh"),
    identity: String(args.identity ?? args.role ?? "sub"),
    reason,
    error: reason,
    gateway: gatewayBaseURL(),
    hostMutationAllowed: false,
    nextRequiredAction: "Call tatwo_os_begin to get a contractID, then dispatch only text-only sub work through an allowlisted model."
  };
}

function sandboxBeginReceipt(args = {}) {
  const contractID = contractIDFromArgs(args);
  if (!contractID) return failClosedSandboxReceipt("tatwo_sandbox_begin", args, "missing contractID; call tatwo_os_begin first");
  const mode = String(args.mode ?? "M").toUpperCase();
  const scenario = safeSlug(args.scenario ?? "custom");
  const goalID = String(args.goalID ?? args.goal ?? "").trim();
  const objective = capText(String(args.objective ?? "TATWO sandbox session").trim(), 1000);
  const sandboxID = safeSlug(args.sandboxID || `sandbox-${mode.toLowerCase()}-${scenario}-${Date.now().toString(36)}-${crypto.randomBytes(4).toString("hex")}`);
  const root = sandboxRootPath();
  const sandboxPath = path.join(root, sandboxID);
  const resolved = path.resolve(sandboxPath);
  if (!isInsidePath(resolved, root)) return failClosedSandboxReceipt("tatwo_sandbox_begin", args, "sandbox path escapes sandbox root");

  fs.mkdirSync(path.join(resolved, "generated-artifacts"), { recursive: true });
  fs.mkdirSync(path.join(resolved, "receipts"), { recursive: true });
  fs.mkdirSync(path.join(resolved, "logs"), { recursive: true });
  fs.mkdirSync(path.join(resolved, "home"), { recursive: true });
  const manifest = {
    schema: "TatwoSandboxManifestV1",
    sandboxID,
    contractID,
    goalID,
    mode,
    scenario,
    objective,
    createdAt: new Date().toISOString(),
    sandboxRoot: root,
    sandboxPath: resolved,
    sandboxWriteAllowed: true,
    hostMutationAllowed: false,
    sandboxStrength: "local-path-guard-not-kernel-isolation",
    safetyRules: sandboxSafetyRules(),
    artifacts: [],
    commands: []
  };
  saveSandboxManifest(resolved, manifest);
  return {
    schema: "TatwoSandboxSessionReceiptV1",
    ok: true,
    status: "created",
    sandboxID,
    contractID,
    goalID,
    mode,
    scenario,
    objective,
    sandboxPath: resolved,
    sandboxWriteAllowed: true,
    hostMutationAllowed: false,
    sandboxStrength: manifest.sandboxStrength,
    allowedTools: [
      "tatwo_sandbox_write_artifact",
      "tatwo_sandbox_run_command",
      "tatwo_sandbox_receipt",
      "tatwo_sandbox_promote_plan"
    ],
    safetyRules: manifest.safetyRules,
    receiptID: `sandbox-session-${sandboxID}`
  };
}

function sandboxWriteArtifactReceipt(args = {}) {
  const loaded = loadSandboxForTool("tatwo_sandbox_write_artifact", args);
  if (!loaded.ok) return loaded.receipt;
  const relativePath = String(args.relativePath ?? args.path ?? "").trim();
  const target = resolveSandboxRelativePath(loaded.sandboxPath, relativePath);
  if (!target.ok) return failClosedSandboxReceipt("tatwo_sandbox_write_artifact", args, target.reason, loaded.manifest);
  const content = String(args.content ?? "");
  const maxBytes = Math.min(Math.max(Number(args.maxBytes ?? 2_000_000) || 2_000_000, 1024), 10_000_000);
  const bytes = Buffer.byteLength(content, "utf8");
  if (bytes > maxBytes) return failClosedSandboxReceipt("tatwo_sandbox_write_artifact", args, `artifact exceeds maxBytes ${maxBytes}`, loaded.manifest);
  const contentViolation = sandboxContentPolicyViolation(content);
  if (contentViolation) return failClosedSandboxReceipt("tatwo_sandbox_write_artifact", args, contentViolation, loaded.manifest);

  fs.mkdirSync(path.dirname(target.path), { recursive: true });
  fs.writeFileSync(target.path, content, "utf8");
  const sha256 = sha256File(target.path);
  const receipt = {
    schema: "TatwoSandboxArtifactReceiptV1",
    ok: true,
    status: "written",
    sandboxID: loaded.manifest.sandboxID,
    contractID: loaded.manifest.contractID,
    goalID: loaded.manifest.goalID,
    relativePath: target.relativePath,
    bytes,
    sha256,
    writtenAt: new Date().toISOString(),
    sandboxWriteAllowed: true,
    hostMutationAllowed: false,
    receiptID: `sandbox-artifact-${sha256.slice(0, 12)}`
  };
  loaded.manifest.artifacts = loaded.manifest.artifacts || [];
  loaded.manifest.artifacts.push({
    relativePath: target.relativePath,
    bytes,
    sha256,
    receiptID: receipt.receiptID,
    writtenAt: receipt.writtenAt
  });
  saveSandboxManifest(loaded.sandboxPath, loaded.manifest);
  writeSandboxReceiptFile(loaded.sandboxPath, receipt.receiptID, receipt);
  return receipt;
}

function sandboxRunCommandReceipt(args = {}) {
  const loaded = loadSandboxForTool("tatwo_sandbox_run_command", args);
  if (!loaded.ok) return loaded.receipt;
  const command = String(args.command ?? "").trim();
  const rawArgs = Array.isArray(args.args) ? args.args.map((arg) => String(arg)) : String(args.args ?? "").split(/\s+/).filter(Boolean);
  const validation = validateSandboxCommand(command, rawArgs);
  if (!validation.ok) return failClosedSandboxReceipt("tatwo_sandbox_run_command", args, validation.reason, loaded.manifest);
  const timeoutMS = Math.min(Math.max(Number(args.timeoutMS ?? 30000) || 30000, 1000), 120000);
  const startedAt = Date.now();
  const env = {
    PATH: process.env.PATH || "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
    HOME: path.join(loaded.sandboxPath, "home"),
    TMPDIR: path.join(loaded.sandboxPath, "tmp"),
    TATWO_SANDBOX: "1",
    TATWO_SANDBOX_ID: loaded.manifest.sandboxID,
    TATWO_CONTRACT_ID: loaded.manifest.contractID
  };
  fs.mkdirSync(env.TMPDIR, { recursive: true });
  const result = spawnSync(command, rawArgs, {
    cwd: loaded.sandboxPath,
    env,
    shell: false,
    encoding: "utf8",
    timeout: timeoutMS,
    maxBuffer: 2 * 1024 * 1024
  });
  const durationMS = Date.now() - startedAt;
  const exitCode = result.status ?? (result.signal ? 128 : 1);
  const ok = exitCode === 0 && !result.error;
  const commandID = `sandbox-command-${Date.now().toString(36)}-${crypto.randomBytes(3).toString("hex")}`;
  const receipt = {
    schema: "TatwoSandboxCommandReceiptV1",
    ok,
    status: ok ? "passed" : "failed",
    sandboxID: loaded.manifest.sandboxID,
    contractID: loaded.manifest.contractID,
    goalID: loaded.manifest.goalID,
    command,
    args: rawArgs,
    exitCode,
    signal: result.signal || null,
    timedOut: result.error?.code === "ETIMEDOUT" || result.signal === "SIGTERM",
    durationMS,
    stdout: capText(result.stdout || "", Number(args.maxOutputChars ?? 8000) || 8000),
    stderr: capText(result.stderr || result.error?.message || "", Number(args.maxOutputChars ?? 8000) || 8000),
    sandboxWriteAllowed: true,
    hostMutationAllowed: false,
    sandboxStrength: loaded.manifest.sandboxStrength,
    receiptID: commandID
  };
  loaded.manifest.commands = loaded.manifest.commands || [];
  loaded.manifest.commands.push({
    receiptID: commandID,
    command,
    args: rawArgs,
    exitCode,
    ok,
    durationMS,
    ranAt: new Date().toISOString()
  });
  saveSandboxManifest(loaded.sandboxPath, loaded.manifest);
  writeSandboxReceiptFile(loaded.sandboxPath, commandID, receipt);
  return receipt;
}

function projectCurrentSandboxArtifacts(sandboxPath, artifacts) {
  if (!Array.isArray(artifacts)) {
    return {
      artifactHistoryCount: 0,
      currentArtifacts: [],
      supersededArtifacts: [],
      malformedArtifacts: [{
        index: -1,
        relativePath: "",
        receiptID: "",
        reason: "manifest.artifacts must be an array"
      }]
    };
  }

  const latestByPath = new Map();
  const supersededArtifacts = [];
  const malformedArtifacts = [];
  artifacts.forEach((artifact, index) => {
    if (!artifact || typeof artifact !== "object" || Array.isArray(artifact)) {
      malformedArtifacts.push({
        index,
        relativePath: "",
        receiptID: "",
        reason: "artifact entry must be an object"
      });
      return;
    }

    const resolved = resolveSandboxRelativePath(sandboxPath, artifact.relativePath);
    const sha256 = String(artifact.sha256 ?? "").trim().toLowerCase();
    const receiptID = String(artifact.receiptID ?? "").trim();
    let reason = "";
    if (!resolved.ok) reason = resolved.reason;
    else if (!/^[a-f0-9]{64}$/.test(sha256)) reason = "artifact entry has invalid sha256";
    else if (!receiptID) reason = "artifact entry missing receiptID";
    if (reason) {
      malformedArtifacts.push({
        index,
        relativePath: String(artifact.relativePath ?? "").trim(),
        receiptID,
        reason
      });
      return;
    }

    const normalized = {
      ...artifact,
      relativePath: resolved.relativePath,
      sha256,
      receiptID
    };
    const previous = latestByPath.get(resolved.relativePath);
    if (previous) supersededArtifacts.push(previous);
    latestByPath.delete(resolved.relativePath);
    latestByPath.set(resolved.relativePath, normalized);
  });

  return {
    artifactHistoryCount: artifacts.length,
    currentArtifacts: [...latestByPath.values()].sort((left, right) =>
      left.relativePath.localeCompare(right.relativePath)),
    supersededArtifacts,
    malformedArtifacts
  };
}

function sandboxBundleReceipt(args = {}) {
  const loaded = loadSandboxForTool("tatwo_sandbox_receipt", args);
  if (!loaded.ok) return loaded.receipt;
  const manifestPath = sandboxManifestPath(loaded.sandboxPath);
  const manifestHash = sha256File(manifestPath);
  const artifactProjection = projectCurrentSandboxArtifacts(
    loaded.sandboxPath,
    loaded.manifest.artifacts
  );
  const artifactChecks = artifactProjection.currentArtifacts.map((artifact) => {
    const resolved = resolveSandboxRelativePath(loaded.sandboxPath, artifact.relativePath);
    const exists = resolved.ok && fs.existsSync(resolved.path);
    const currentHash = exists ? sha256File(resolved.path) : "";
    return {
      relativePath: artifact.relativePath,
      exists,
      sha256: artifact.sha256,
      currentSha256: currentHash,
      hashMatches: exists && currentHash === artifact.sha256,
      receiptID: artifact.receiptID
    };
  });
  const commandReceipts = (loaded.manifest.commands || []).map((command) => ({
    receiptID: command.receiptID,
    command: command.command,
    args: command.args,
    ok: command.ok,
    exitCode: command.exitCode
  }));
  const ok = artifactProjection.malformedArtifacts.length === 0
    && artifactChecks.every((item) => item.exists && item.hashMatches);
  return {
    schema: "TatwoSandboxReceiptBundleV1",
    ok,
    status: ok ? "ready_for_review" : "artifact_mismatch",
    sandboxID: loaded.manifest.sandboxID,
    contractID: loaded.manifest.contractID,
    goalID: loaded.manifest.goalID,
    sandboxPath: loaded.sandboxPath,
    artifactCount: artifactProjection.artifactHistoryCount,
    artifactHistoryCount: artifactProjection.artifactHistoryCount,
    currentArtifactCount: artifactChecks.length,
    supersededArtifactCount: artifactProjection.supersededArtifacts.length,
    malformedArtifactCount: artifactProjection.malformedArtifacts.length,
    commandCount: commandReceipts.length,
    manifestSha256: manifestHash,
    artifacts: artifactChecks,
    supersededArtifacts: artifactProjection.supersededArtifacts.map((artifact) => ({
      relativePath: artifact.relativePath,
      sha256: artifact.sha256,
      receiptID: artifact.receiptID,
      writtenAt: artifact.writtenAt
    })),
    supersededReceiptIDs: artifactProjection.supersededArtifacts.map((artifact) => artifact.receiptID),
    malformedArtifacts: artifactProjection.malformedArtifacts,
    commands: commandReceipts,
    requiredBeforePromotion: [
      "sandbox receipt bundle",
      "reviewer/lead acceptance",
      "rollback plan",
      "cleanup inventory",
      "human gate before host mutation"
    ],
    sandboxWriteAllowed: true,
    hostMutationAllowed: false,
    receiptID: `sandbox-bundle-${manifestHash.slice(0, 12)}`
  };
}

function sandboxPromotePlanReceipt(args = {}) {
  const loaded = loadSandboxForTool("tatwo_sandbox_promote_plan", args);
  if (!loaded.ok) return loaded.receipt;
  const bundle = sandboxBundleReceipt(args);
  const candidateArtifacts = (loaded.manifest.artifacts || []).map((artifact) => ({
    relativePath: artifact.relativePath,
    sha256: artifact.sha256,
    proposedAction: "manual-review-copy-only"
  }));
  return {
    schema: "TatwoSandboxPromotePlanV1",
    ok: true,
    status: "plan_only",
    sandboxID: loaded.manifest.sandboxID,
    contractID: loaded.manifest.contractID,
    goalID: loaded.manifest.goalID,
    targetHint: String(args.targetHint ?? "host project after human approval"),
    promoteAllowed: false,
    hostMutationAllowed: false,
    sandboxWriteAllowed: true,
    plainRule: "This MCP tool never copies sandbox files into the host project. Promotion requires human gate, Codex host patch, rollback receipt, and validation receipts.",
    humanGate: "required before any host mutation / 人工確認後才可實裝主機",
    requiredReceipts: [
      bundle.receiptID,
      "reviewer-gate",
      "rollback-plan",
      "cleanup-inventory",
      "human-approval"
    ].filter(Boolean),
    candidateArtifacts,
    nextHostSteps: [
      "Codex host reviews sandbox artifacts and diffs.",
      "Create rollback point before touching the real project.",
      "Apply the smallest host patch manually.",
      "Run project tests/smoke/web-check as required.",
      "Write cleanup inventory before goal close."
    ],
    receiptID: `sandbox-promote-plan-${loaded.manifest.sandboxID}`
  };
}

function sandboxRootPath() {
  const raw = process.env.TATWO_ULTRAWORK_SANDBOX_ROOT || path.join(repoRoot, ".tatwo-ultrawork", "mcp-sandboxes");
  const resolved = path.resolve(raw);
  fs.mkdirSync(resolved, { recursive: true });
  return resolved;
}

function sandboxManifestPath(sandboxPath) {
  return path.join(sandboxPath, ".tatwo-sandbox-manifest.json");
}

function saveSandboxManifest(sandboxPath, manifest) {
  fs.writeFileSync(sandboxManifestPath(sandboxPath), `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
}

function loadSandboxManifest(sandboxPath) {
  return JSON.parse(fs.readFileSync(sandboxManifestPath(sandboxPath), "utf8"));
}

function loadSandboxForTool(toolName, args = {}) {
  const contractID = contractIDFromArgs(args);
  if (!contractID) return { ok: false, receipt: failClosedSandboxReceipt(toolName, args, "missing contractID; call tatwo_os_begin first") };
  const sandboxID = safeSlug(args.sandboxID || args.sandbox || "");
  if (!sandboxID) return { ok: false, receipt: failClosedSandboxReceipt(toolName, args, "missing sandboxID; call tatwo_sandbox_begin first") };
  const root = sandboxRootPath();
  const sandboxPath = path.resolve(root, sandboxID);
  if (!isInsidePath(sandboxPath, root)) return { ok: false, receipt: failClosedSandboxReceipt(toolName, args, "sandbox path escapes sandbox root") };
  const manifestPath = sandboxManifestPath(sandboxPath);
  if (!fs.existsSync(manifestPath)) return { ok: false, receipt: failClosedSandboxReceipt(toolName, args, `sandbox not found: ${sandboxID}`) };
  const manifest = loadSandboxManifest(sandboxPath);
  if (manifest.contractID !== contractID) return { ok: false, receipt: failClosedSandboxReceipt(toolName, args, "contractID does not match sandbox manifest", manifest) };
  return { ok: true, sandboxPath, manifest };
}

function resolveSandboxRelativePath(sandboxPath, relativePath) {
  const raw = String(relativePath ?? "").trim().replace(/\\/g, "/");
  if (!raw) return { ok: false, reason: "missing relativePath" };
  if (raw.includes("\0")) return { ok: false, reason: "path contains NUL" };
  if (path.isAbsolute(raw) || raw.startsWith("~")) return { ok: false, reason: "absolute/parent path is not allowed" };
  const normalized = path.posix.normalize(raw);
  if (normalized === "." || normalized === ".." || normalized.startsWith("../") || normalized.startsWith("/")) {
    return { ok: false, reason: "path escapes sandbox" };
  }
  const segments = normalized.split("/");
  const blockedSegments = new Set(["..", ".git", ".ssh", ".codex", "Library", "LaunchAgents"]);
  if (segments.some((segment) => blockedSegments.has(segment))) return { ok: false, reason: "path includes protected host-like segment" };
  if (normalized === ".tatwo-sandbox-manifest.json" || normalized.startsWith("receipts/")) {
    return { ok: false, reason: "artifact path targets protected sandbox control files" };
  }
  const resolved = path.resolve(sandboxPath, ...segments);
  if (!isInsidePath(resolved, sandboxPath)) return { ok: false, reason: "path escapes sandbox" };
  return { ok: true, path: resolved, relativePath: normalized };
}

function validateSandboxCommand(command, args) {
  const allowed = new Set(["node", "python3", "npm"]);
  if (!allowed.has(command)) return { ok: false, reason: `command not allowlisted: ${command}` };
  for (const arg of args) {
    if (arg.includes("\0") || arg.startsWith("~")) return { ok: false, reason: "command arg contains forbidden path marker" };
    if (path.isAbsolute(arg) || arg === ".." || arg.startsWith("../")) return { ok: false, reason: "command arg path escapes sandbox" };
    if (/[;&|`$<>]/.test(arg)) return { ok: false, reason: "command arg contains shell metacharacter" };
  }
  if (command === "node") {
    const denied = new Set(["-e", "--eval", "-p", "--print", "-r", "--require"]);
    if (args.some((arg) => denied.has(arg))) return { ok: false, reason: "node eval/require modes are not allowed" };
  }
  if (command === "python3") {
    if (args.some((arg) => arg === "-c")) return { ok: false, reason: "python -c is not allowed" };
  }
  if (command === "npm") {
    const first = args[0] || "";
    if (first === "install" || first === "i" || first === "add" || first === "exec") return { ok: false, reason: "npm install/exec is not allowed in MCP sandbox" };
    if (!(first === "test" || (first === "run" && args[1]))) return { ok: false, reason: "npm command must be test or run <script>" };
  }
  return { ok: true };
}

function writeSandboxReceiptFile(sandboxPath, receiptID, receipt) {
  const receiptPath = path.join(sandboxPath, "receipts", `${safeSlug(receiptID)}.json`);
  fs.writeFileSync(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`, "utf8");
}

function sandboxContentPolicyViolation(content) {
  const text = String(content ?? "");
  const blocked = [
    /access[_-]?token\s*[:=]/i,
    /refresh[_-]?token\s*[:=]/i,
    /BEGIN (RSA |EC |OPENSSH |)PRIVATE KEY/i,
    /auth\.json/i,
    /ChatGPT-Account-ID/i,
    /Bearer\s+[A-Za-z0-9._~+/=-]{20,}/i
  ];
  if (blocked.some((pattern) => pattern.test(text))) return "artifact content appears to contain auth/session/secret material";
  return "";
}

function sandboxSafetyRules() {
  return [
    "contractID required for every sandbox action",
    "writes are limited to this sandbox folder",
    "hostMutationAllowed=false; no promotion/copy into host project",
    "no auth/session/token/private-key artifacts",
    "commands use an allowlist and sanitized environment",
    "local sandbox is path-guarded, not a kernel/container boundary; use Colima for untrusted execution"
  ];
}

function failClosedSandboxReceipt(toolName, args = {}, reason, manifest = null) {
  return {
    schema: "TatwoSandboxFailClosedReceiptV1",
    ok: false,
    status: "fail_closed",
    toolName,
    contractID: String(args.contractID ?? args.contract ?? manifest?.contractID ?? ""),
    goalID: String(args.goalID ?? args.goal ?? manifest?.goalID ?? ""),
    sandboxID: String(args.sandboxID ?? args.sandbox ?? manifest?.sandboxID ?? ""),
    reason,
    sandboxWriteAllowed: false,
    hostMutationAllowed: false,
    nextRequiredAction: "Call tatwo_sandbox_begin with a valid Work OS contractID, then write/run only inside the returned sandboxID."
  };
}

function safeSlug(value) {
  return String(value ?? "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 120);
}

function isInsidePath(candidate, root) {
  const resolvedCandidate = path.resolve(candidate);
  const resolvedRoot = path.resolve(root);
  return resolvedCandidate === resolvedRoot || resolvedCandidate.startsWith(`${resolvedRoot}${path.sep}`);
}

function sha256File(filePath) {
  const hash = crypto.createHash("sha256");
  hash.update(fs.readFileSync(filePath));
  return hash.digest("hex");
}

function handleContextTool(request, name, args = {}) {
  const contextNames = new Set([
    "tatwo_context_policy",
    "tatwo.context.policy",
    "tatwo_context_compress",
    "tatwo.context.compress",
    "tatwo_context_retrieve",
    "tatwo.context.retrieve",
    "tatwo_context_stats",
    "tatwo.context.stats"
  ]);
  if (!contextNames.has(name)) return false;

  const runSwift = (cliArgs, options = {}) => spawnSync("swift", swiftRunInvocation(cliArgs), {
    cwd: repoRoot,
    env: swiftToolEnv(),
    encoding: "utf8",
    maxBuffer: 10 * 1024 * 1024,
    timeout: options.timeout ?? toolTimeoutMS()
  });

  if (name === "tatwo_context_policy" || name === "tatwo.context.policy") {
    const result = runSwift(["context", "policy", "--json"]);
    sendSwiftToolResult(request, result);
    return true;
  }

  if (name === "tatwo_context_stats" || name === "tatwo.context.stats") {
    const result = runSwift(["context", "stats", "--json"]);
    sendSwiftToolResult(request, result);
    return true;
  }

  const contractID = contractIDFromArgs(args);
  if (!contractID) {
    sendResult(request.id, {
      content: [{
        type: "text",
        text: JSON.stringify({
          schema: "TatwoContextCompressionFailClosedReceiptV1",
          ok: false,
          status: "fail_closed",
          toolName: name,
          reason: "missing contractID; call tatwo_os_begin first",
          hostMutationAllowed: false,
          nextRequiredAction: "Create a Work OS contract, then compress/retrieve context under that run."
        }, null, 2)
      }],
      isError: true
    });
    return true;
  }

  if (name === "tatwo_context_retrieve" || name === "tatwo.context.retrieve") {
    const out = ["context", "retrieve", "--json"];
    appendOption(out, "--id", args.id ?? args.contextID ?? args.contextId);
    appendOption(out, "--run", args.runID ?? args.run ?? contractID);
    const result = runSwift(out);
    sendSwiftToolResult(request, result);
    return true;
  }

  const text = String(args.text ?? args.input ?? "");
  if (!text.trim()) {
    sendResult(request.id, {
      content: [{
        type: "text",
        text: JSON.stringify({
          schema: "TatwoContextCompressionFailClosedReceiptV1",
          ok: false,
          status: "fail_closed",
          toolName: name,
          contractID,
          reason: "missing text/input",
          hostMutationAllowed: false
        }, null, 2)
      }],
      isError: true
    });
    return true;
  }

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-context-mcp-"));
  try {
    const inputFile = path.join(tmp, "context.txt");
    fs.writeFileSync(inputFile, text, "utf8");
    const out = ["context", "compress", "--file", inputFile, "--json"];
    appendOption(out, "--kind", args.kind);
    appendOption(out, "--run", args.runID ?? args.run ?? contractID);
    appendOption(out, "--source", args.sourceLabel ?? args.source ?? "mcp-context");
    appendOption(out, "--max-chars", args.maxCompressedCharacters ?? args.maxChars);
    appendOption(out, "--max-diagnostic-lines", args.maxPreservedDiagnosticLines ?? args.maxDiagnosticLines);
    appendOption(out, "--max-line-chars", args.maxLineCharacters ?? args.maxLineChars);
    if (args.cacheOriginal === false) out.push("--no-cache");
    if (args.failOnSensitiveContent === false || args.allowSensitive === true) out.push("--allow-sensitive");
    if (args.redactShareableOutput === false || args.noRedact === true) out.push("--no-redact");
    const result = runSwift(out, { timeout: Math.max(toolTimeoutMS(), 60000) });
    sendSwiftToolResult(request, result);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
  return true;
}

function sendSwiftToolResult(request, result) {
  if (result.error?.code === "ETIMEDOUT" || result.signal === "SIGTERM") {
    sendError(request.id, -32000, `tool timed out after ${toolTimeoutMS()}ms; build the CLI first or retry after sandbox build`);
    return;
  }
  const text = (result.stdout || result.stderr || "").trim();
  if (result.status !== 0 && !text) {
    sendError(request.id, -32000, `tool failed with exit ${result.status}`);
    return;
  }
  sendResult(request.id, mcpProcessToolResult(result, text));
}

const remoteStatusDeviceIDPattern = /^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$/;

function remoteStatusApplicationSupportDirectory() {
  const explicit = String(process.env.TATWO_ULTRAWORK_APP_SUPPORT || "").trim();
  if (explicit) return path.resolve(explicit);
  return path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "Tatwo Ultrawork",
  );
}

function readRemoteStatusIdentityFile(filePath, {
  format,
  source,
  maximumBytes,
}) {
  let descriptor;
  try {
    const initial = fs.lstatSync(filePath);
    if (initial.isSymbolicLink() || !initial.isFile()) {
      return {
        status: "invalid",
        source,
        detail: "不是一般檔案，或是符號連結",
      };
    }
    if (initial.size > maximumBytes) {
      return {
        status: "invalid",
        source,
        detail: `檔案超過 ${maximumBytes} bytes`,
      };
    }
    descriptor = fs.openSync(
      filePath,
      fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0),
    );
    const opened = fs.fstatSync(descriptor);
    if (!opened.isFile() || opened.size > maximumBytes) {
      return {
        status: "invalid",
        source,
        detail: "開啟後檔案型態或大小不安全",
      };
    }
    const text = fs.readFileSync(descriptor, "utf8")
      .replace(/^\uFEFF/, "")
      .trim();
    let deviceIDs;
    if (format === "text") {
      deviceIDs = [text];
    } else {
      let payload;
      try {
        payload = JSON.parse(text);
      } catch {
        return { status: "invalid", source, detail: "不是有效 JSON" };
      }
      if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
        return { status: "invalid", source, detail: "JSON 格式不正確" };
      }
      deviceIDs = [payload.deviceId, payload.deviceID]
        .filter(value => typeof value === "string")
        .map(value => value.trim())
        .filter(Boolean);
    }
    const uniqueDeviceIDs = [...new Set(deviceIDs)];
    if (uniqueDeviceIDs.length !== 1) {
      return {
        status: "invalid",
        source,
        detail: uniqueDeviceIDs.length
          ? "同一檔案內有互相衝突的設備 ID"
          : "檔案內沒有設備 ID",
      };
    }
    const deviceID = uniqueDeviceIDs[0];
    if (!remoteStatusDeviceIDPattern.test(deviceID)) {
      return {
        status: "invalid",
        source,
        detail: "設備 ID 格式無效",
      };
    }
    return { status: "valid", source, deviceID };
  } catch (error) {
    if (error?.code === "ENOENT") return { status: "missing", source };
    return {
      status: "invalid",
      source,
      detail: error?.code === "ELOOP"
        ? "拒絕讀取符號連結"
        : `無法唯讀開啟（${error?.code || "unknown_error"}）`,
    };
  } finally {
    if (descriptor !== undefined) {
      try {
        fs.closeSync(descriptor);
      } catch {}
    }
  }
}

function resolveRemoteStatusDeviceID(args) {
  if (args.deviceID !== undefined) {
    if (typeof args.deviceID !== "string") {
      throw new Error("tatwo_remote_loops_status 的 deviceID 必須是字串。");
    }
    const explicit = args.deviceID.trim();
    if (!remoteStatusDeviceIDPattern.test(explicit)) {
      throw new Error(
        "tatwo_remote_loops_status 的 deviceID 格式無效；"
        + "只接受 1–256 個英數字、句點、底線或連字號。",
      );
    }
    return explicit;
  }

  const applicationSupport = remoteStatusApplicationSupportDirectory();
  const sources = [
    readRemoteStatusIdentityFile(
      path.join(applicationSupport, "device-identity.json"),
      {
        format: "json",
        source: "device-identity.json",
        maximumBytes: 4 * 1024,
      },
    ),
    readRemoteStatusIdentityFile(
      path.join(workOSStateDirectory(), "local-device-id"),
      {
        format: "text",
        source: "state/local-device-id",
        maximumBytes: 256,
      },
    ),
    readRemoteStatusIdentityFile(
      path.join(applicationSupport, "device-trust", "identity.json"),
      {
        format: "json",
        source: "device-trust/identity.json",
        maximumBytes: 64 * 1024,
      },
    ),
  ];
  const invalid = sources.filter(candidate => candidate.status === "invalid");
  if (invalid.length) {
    const detail = invalid
      .map(candidate => `${candidate.source}：${candidate.detail}`)
      .join("；");
    throw new Error(
      `tatwo_remote_loops_status 無法安全解析本機設備 ID（${detail}）。`
      + "已停止讀取，不會把未知狀態假裝成空白 fleet。",
    );
  }
  const valid = sources.filter(candidate => candidate.status === "valid");
  const uniqueDeviceIDs = [...new Set(valid.map(candidate => candidate.deviceID))];
  if (!uniqueDeviceIDs.length) {
    throw new Error(
      "tatwo_remote_loops_status 找不到可用的本機設備 ID。"
      + "請傳入 deviceID，或先讓 TATWO OS 落盤本機設備身分；"
      + "已停止讀取，不會回傳假的空白 fleet。",
    );
  }
  if (uniqueDeviceIDs.length !== 1) {
    const detail = valid
      .map(candidate => `${candidate.source}=${candidate.deviceID}`)
      .join("；");
    throw new Error(
      `tatwo_remote_loops_status 找到多個不同的本機設備 ID（${detail}）。`
      + "無法判定哪一台是本機，已停止讀取；"
      + "請明確傳入 deviceID 或先修正本機設備身分。",
    );
  }
  return uniqueDeviceIDs[0];
}

function cliArgsForTool(name, args) {
  const mode = String(args.mode ?? "M");
  const scenario = String(args.scenario ?? "coding");
  const objective = String(args.objective ?? "Tatwo Ultrawork MCP request");

  switch (name) {
    case "tatwo_remote_loops_contract":
      return ["remote-runner", "contract", "--json"];
    case "tatwo_remote_loops_status":
      return [
        "remote-runner",
        "fleet",
        "status",
        "--device-id",
        resolveRemoteStatusDeviceID(args),
        ...(args.channelDir ? ["--channel-dir", String(args.channelDir)] : []),
        "--json",
      ];
    case "tatwo_app_mcp_manifest":
      return ["mcp", "manifest", "--json"];
    case "tatwo_mcp_client_config":
      return ["mcp", "client-config", "--engine", String(args.engine ?? "generic-cli"), "--json"];
    case "tatwo_engine_capabilities":
      return ["engine", "capabilities", "--engine", String(args.engine ?? "codex"), "--json"];
    case "tatwo_doctor":
      return ["doctor", "--json"];
    case "tatwo_mode_list":
      return ["mode", "list", "--json"];
    case "tatwo_scenario_list":
      return ["scenario", "list", "--json"];
    case "tatwo_scenario_config":
    case "tatwo.scenario.config":
      return ["scenario", "config", "--json"];
    case "tatwo_scenario_config_add":
    case "tatwo.scenario.config.add": {
      const out = ["scenario", "config-add", "--json"];
      appendOption(out, "--contract", args.contractID ?? args.contract);
      appendOption(out, "--name", args.displayName ?? args.name);
      appendOption(out, "--base", args.baseScenario ?? args.base);
      return out;
    }
    case "tatwo_scenario_config_duplicate":
    case "tatwo.scenario.config.duplicate": {
      const out = ["scenario", "config-duplicate", "--json"];
      appendOption(out, "--contract", args.contractID ?? args.contract);
      appendOption(out, "--scenario", args.scenarioID ?? args.scenario);
      return out;
    }
    case "tatwo_scenario_config_rename":
    case "tatwo.scenario.config.rename": {
      const out = ["scenario", "config-rename", "--json"];
      appendOption(out, "--contract", args.contractID ?? args.contract);
      appendOption(out, "--scenario", args.scenarioID ?? args.scenario);
      appendOption(out, "--name", args.displayName ?? args.name);
      return out;
    }
    case "tatwo_scenario_config_delete":
    case "tatwo.scenario.config.delete": {
      const out = ["scenario", "config-delete", "--json"];
      appendOption(out, "--contract", args.contractID ?? args.contract);
      appendOption(out, "--scenario", args.scenarioID ?? args.scenario);
      return out;
    }
    case "tatwo_scenario_config_update_token_budget":
    case "tatwo.scenario.config.update_token_budget": {
      const out = ["scenario", "config-budget", "--json"];
      appendOption(out, "--contract", args.contractID ?? args.contract);
      appendOption(out, "--scenario", args.scenarioID ?? args.scenario);
      appendOption(out, "--mode", args.mode);
      appendOption(out, "--budget", args.tokenBudget ?? args.budget);
      return out;
    }
    case "tatwo_scenario_config_set_binding_models":
    case "tatwo.scenario.config.set_binding_models": {
      const out = ["scenario", "config-bind", "--json"];
      appendOption(out, "--contract", args.contractID ?? args.contract);
      appendOption(out, "--scenario", args.scenarioID ?? args.scenario);
      appendOption(out, "--mode", args.mode);
      appendOption(out, "--binding", args.bindingID ?? args.binding);
      appendOption(out, "--models", modelListArgument(args.modelIDs ?? args.models));
      return out;
    }
    case "tatwo_scenario_config_binding_resp":
    case "tatwo_scenario_config_update_binding_responsibility":
    case "tatwo.scenario.config.update_binding_responsibility": {
      const out = ["scenario", "config-responsibility", "--json"];
      appendOption(out, "--contract", args.contractID ?? args.contract);
      appendOption(out, "--scenario", args.scenarioID ?? args.scenario);
      appendOption(out, "--mode", args.mode);
      appendOption(out, "--binding", args.bindingID ?? args.binding);
      appendOption(out, "--responsibility", args.responsibility);
      return out;
    }
    case "tatwo_plugins_list":
      return ["plugins", "list", "--json"];
    case "tatwo_capabilities_status":
    case "tatwo.capabilities.status":
      return ["capabilities", "status", "--json"];
    case "tatwo_capabilities_bootstrap":
    case "tatwo.capabilities.bootstrap": {
      const out = ["mcp", "call", "tatwo.capabilities.bootstrap", "--json"];
      appendOption(out, "--contract", args.contractID ?? args.contract);
      const names = Array.isArray(args.names) ? args.names.join(",") : args.names;
      appendOption(out, "--names", names);
      return out;
    }
    case "tatwo_model_traits":
      return ["teams", "traits", "--json"];
    case "tatwo_team_list":
      return ["teams", "list", "--json"];
    case "tatwo_team_recommend":
      return ["teams", "recommend", "--mode", mode, "--scenario", scenario, "--json"];
    case "tatwo_team_dashboard":
      return ["teams", "dashboard", "--mode", mode, "--scenario", scenario, "--json"];
    case "tatwo_integration_plan":
      return ["integration", "plan", "--json"];
    case "tatwo_stability_plan":
      return ["integration", "stability", "--json"];
    case "tatwo_colima_preflight":
      return ["colima", "preflight", "--json"];
    case "tatwo_colima_run":
      return ["colima", "run", "--mode", mode, "--scenario", scenario, "--objective", objective, "--dry-run", "--json"];
    case "tatwo_workflow_preview":
      return ["workflow", "preview", "--mode", mode, "--scenario", scenario, "--json"];
    case "tatwo_workflow_run":
      return ["workflow", "run", "--mode", mode, "--scenario", scenario, "--objective", objective, "--dry-run", "--json"];
    case "tatwo_os_begin":
    case "tatwo.os.begin": {
      const out = [
        "os", "begin",
        "--mode", mode,
        "--scenario", scenario,
        "--objective", objective,
        "--json",
      ];
      appendOption(out, "--provider", args.provider);
      appendOption(out, "--owner-session", args.ownerSession);
      appendOption(out, "--owner-thread", args.ownerThread);
      appendOption(out, "--workspace", args.workspace);
      appendOption(out, "--state-root", args.stateRoot);
      return out;
    }
    case "tatwo_os_goal_candidate_create":
    case "tatwo.os.goal.candidate.create":
      return [
        "mcp",
        "call",
        "tatwo.os.goal.candidate.create",
        "--arguments",
        JSON.stringify({
          mode: args.mode,
          scenario: args.scenario,
          objective: args.objective,
          authorizationBindingArtifactSHA256:
            args.authorizationBindingArtifactSHA256,
          authorizationBindingArtifactJSON:
            args.authorizationBindingArtifactJSON,
        }),
        "--json",
      ];
    case "tatwo_os_session_attach":
    case "tatwo.os.session.attach": {
      const out = ["os", "session", "attach", "--json"];
      appendOption(out, "--provider", args.provider);
      appendOption(out, "--owner-session", args.ownerSession);
      appendOption(out, "--owner-thread", args.ownerThread);
      appendOption(out, "--workspace", args.workspace);
      appendOption(out, "--contract", args.contractID ?? args.contract);
      appendOption(out, "--goal", args.goalID ?? args.goal);
      appendOption(out, "--mode", args.mode);
      appendOption(out, "--scenario", args.scenario);
      appendOption(out, "--objective", args.objective);
      return out;
    }
    case "tatwo_os_next":
    case "tatwo.os.next": {
      const out = ["os", "next", "--mode", mode, "--scenario", scenario, "--objective", objective, "--json"];
      appendOption(out, "--goal", args.goalID ?? args.goal);
      appendOption(out, "--contract", args.contractID ?? args.contract);
      return out;
    }
    case "tatwo_os_loop_status":
    case "tatwo.os.loop.status": {
      const out = ["os", "loop", "status", "--mode", mode, "--scenario", scenario, "--objective", objective, "--json"];
      appendOption(out, "--goal", args.goalID ?? args.goal);
      appendOption(out, "--contract", args.contractID ?? args.contract);
      return out;
    }
    case "tatwo_os_receipt_submit":
    case "tatwo.os.receipt.submit": {
      const out = ["os", "receipt", "submit", "--json"];
      appendOption(out, "--goal", args.goalID ?? args.goal);
      appendOption(out, "--contract", args.contractID ?? args.contract);
      appendOption(out, "--loop", args.loopID ?? args.loop);
      appendOption(out, "--receipt", args.receiptID ?? args.receipt);
      appendOption(out, "--kind", args.receiptKind ?? args.kind);
      return out;
    }
    case "tatwo_os_goal_close":
    case "tatwo.os.goal.close": {
      const out = ["os", "goal", "close", "--mode", mode, "--scenario", scenario, "--objective", objective, "--json"];
      appendOption(out, "--goal", args.goalID ?? args.goal);
      appendOption(out, "--contract", args.contractID ?? args.contract);
      const receiptIDs = Array.isArray(args.receiptIDs)
        ? args.receiptIDs
        : String(args.receiptIDs ?? args.receipts ?? "").split(",");
      for (const receiptID of receiptIDs) appendOption(out, "--receipt", receiptID);
      appendOption(out, "--receipt", args.receiptID ?? args.receipt);
      return out;
    }
    case "tatwo_os_dispatch_finalize":
    case "tatwo.os.dispatch.finalize": {
      const out = ["os", "dispatch", "finalize", "--json"];
      appendOption(out, "--contract", args.contractID ?? args.contract);
      return out;
    }
    case "tatwo_os_dispatch_advance":
    case "tatwo.os.dispatch.advance": {
      const out = ["os", "dispatch", "advance", "--json"];
      appendOption(out, "--contract", args.contractID ?? args.contract);
      appendOption(out, "--expected-seal", args.expectedSealID ?? args.expectedSeal);
      return out;
    }
    case "tatwo_os_recovery_begin":
    case "tatwo.os.recovery.begin": {
      const out = ["os", "recovery", "begin", "--json"];
      appendOption(out, "--contract", args.contractID ?? args.contract);
      appendOption(out, "--authorization", args.authorizationToken ?? args.authorization);
      appendOption(out, "--reason", args.reason);
      appendOption(out, "--adjudication-ref", args.adjudicationRef);
      return out;
    }
    case "tatwo_os_dashboard":
    case "tatwo.os.dashboard": {
      const out = ["os", "dashboard", "--mode", mode, "--scenario", scenario, "--objective", objective, "--json"];
      appendOption(out, "--goal", args.goalID ?? args.goal);
      appendOption(out, "--contract", args.contractID ?? args.contract);
      const receiptIDs = Array.isArray(args.receiptIDs)
        ? args.receiptIDs
        : String(args.receiptIDs ?? args.receipts ?? "").split(",");
      for (const receiptID of receiptIDs) appendOption(out, "--receipt", receiptID);
      return out;
    }
    case "tatwo_os_enforce":
    case "tatwo.os.enforce": {
      const out = ["os", "enforce", "--mode", mode, "--scenario", scenario, "--objective", objective, "--json"];
      appendOption(out, "--contract", args.contractID ?? args.contract);
      appendOption(out, "--tool", args.toolName ?? args.tool);
      appendOption(out, "--identity", args.identity ?? args.role);
      appendOption(out, "--mutation", args.mutation ?? args.requestedMutation);
      appendOption(out, "--surface", args.surface ?? args.sourceSurface);
      appendOption(out, "--receipt", args.receiptID ?? args.receipt);
      return out;
    }
    case "tatwo_os_handoff":
    case "tatwo.os.handoff": {
      const out = ["os", "handoff", "--mode", mode, "--scenario", scenario, "--objective", objective, "--json"];
      appendOption(out, "--goal", args.goalID ?? args.goal);
      appendOption(out, "--contract", args.contractID ?? args.contract);
      return out;
    }
    case "tatwo_os_constitution":
    case "tatwo.os.constitution":
      return ["os", "constitution", "--json"];
    case "tatwo_web_arena_plan":
    case "tatwo.web_arena.plan": {
      const out = ["web-arena", "plan", "--suite", String(args.suite ?? "v1"), "--json"];
      appendOption(out, "--run", args.runID ?? args.run);
      const models = Array.isArray(args.models) ? args.models.join(",") : args.models;
      appendOption(out, "--models", models);
      return out;
    }
    case "tatwo_web_arena_report":
    case "tatwo.web_arena.report": {
      const out = ["web-arena", "report", "--json"];
      appendOption(out, "--run", args.runID ?? args.run);
      return out;
    }
    case "tatwo_web_arena_cleanup_plan":
    case "tatwo.web_arena.cleanup_plan": {
      const out = ["web-arena", "cleanup", "--dry-run", "--json"];
      appendOption(out, "--older-than", args.olderThan ?? args["older-than"]);
      return out;
    }
    case "tatwo_sandbox_arena_list":
    case "tatwo.sandbox_arena.list":
      return ["sandbox-arena", "list", "--json"];
    case "tatwo_sandbox_arena_plan":
    case "tatwo.sandbox_arena.plan": {
      const out = ["sandbox-arena", "plan", "--json"];
      appendOption(out, "--arena", args.arena);
      appendOption(out, "--run", args.runID ?? args.run);
      const models = Array.isArray(args.models) ? args.models.join(",") : args.models;
      appendOption(out, "--models", models);
      return out;
    }
    case "tatwo_sandbox_arena_report":
    case "tatwo.sandbox_arena.report": {
      const out = ["sandbox-arena", "report", "--json"];
      appendOption(out, "--arena", args.arena);
      appendOption(out, "--run", args.runID ?? args.run);
      return out;
    }
    case "tatwo_arena_plan_loop_goal_policy":
    case "tatwo.arena.plan_loop_goal.policy":
      return ["arena", "plan-loop-goal", "--json"];
    case "tatwo_arena_plan_loop_goal_score":
    case "tatwo_arena_plg_score":
    case "tatwo.arena.plan_loop_goal.score": {
      const out = ["arena", "plan-loop-goal", "score", "--json"];
      appendOption(out, "--model", args.modelSlug ?? args.model);
      appendOption(out, "--expected", args.expectedSandboxTests ?? args.expected);
      appendOption(out, "--completed", args.completedSandboxTests ?? args.completed);
      appendOption(out, "--cycles", args.goalExecutionCycles ?? args.cycles);
      const artifacts = Array.isArray(args.presentArtifacts)
        ? args.presentArtifacts.join(",")
        : (Array.isArray(args.artifacts) ? args.artifacts.join(",") : (args.presentArtifacts ?? args.artifacts));
      appendOption(out, "--artifacts", artifacts);
      const missing = Array.isArray(args.missingSandboxTests)
        ? args.missingSandboxTests.join(",")
        : (args.missingSandboxTests ?? args.missing);
      appendOption(out, "--missing", missing);
      if (args.finalSubmissionSealed || args.sealed) out.push("--sealed");
      if (args.fileHashesChangedAfterSeal || args.hashChanged) out.push("--hash-changed");
      if (args.toolChoicesAllRegistered || args.toolChoicesRegistered) out.push("--tool-choices-registered");
      return out;
    }
    case "tatwo_arena_goal_cycle_assess":
    case "tatwo.arena.goal_cycle.assess": {
      const out = ["arena", "goal-cycle", "assess", "--json"];
      const cycles = args.goalExecutionCycles ?? args.cycles;
      if (cycles !== undefined && cycles !== null) appendOption(out, "--cycles", String(cycles));
      if (args.finalSubmissionSealed || args.sealed) out.push("--sealed");
      if (args.fileHashesChangedAfterSeal || args.hashChanged) out.push("--hash-changed");
      return out;
    }
    case "tatwo_web_check_preflight":
    case "tatwo.web_check.preflight":
      return ["web-check", "preflight", "--json"];
    case "tatwo_web_check_plan":
    case "tatwo.web_check.plan": {
      const out = ["web-check", "plan", "--mode", mode, "--scenario", scenario, "--target", String(args.target ?? "<local-frontend-project>"), "--json"];
      appendOption(out, "--scan-type", args.scanType);
      appendOption(out, "--blocking", args.blockingPolicy ?? args.blocking);
      return out;
    }
    case "tatwo_web_check_import_receipt":
    case "tatwo.web_check.import_receipt": {
      const out = ["web-check", "import", "--json"];
      appendOption(out, "--report", args.reportPath ?? args.report);
      appendOption(out, "--goal", args.goalID ?? args.goal);
      appendOption(out, "--contract", args.contractID ?? args.contract);
      appendOption(out, "--target-kind", args.targetKind);
      appendOption(out, "--scan-type", args.scanType);
      appendOption(out, "--blocking", args.blockingPolicy ?? args.blocking);
      appendOption(out, "--command", args.command);
      return out;
    }
    case "tatwo_web_check_receipt_template":
    case "tatwo.web_check.receipt_template": {
      const out = ["web-check", "receipt-template", "--json"];
      appendOption(out, "--goal", args.goalID ?? args.goal);
      appendOption(out, "--contract", args.contractID ?? args.contract);
      return out;
    }
    case "tatwo_handoff_pack":
      return ["handoff", "pack", "--mode", mode, "--scenario", scenario, "--objective", objective, "--json"];
    case "tatwo_install_plan":
      return ["install", "plan", "--json"];
    case "tatwo_sandbox_preflight":
      return ["sandbox", "preflight", "--json"];
    case "tatwo_host_executor_plan":
    case "tatwo.host.plan":
      return ["mcp", "call", "tatwo.host.plan", "--json"];
    case "tatwo_host_read_file":
    case "tatwo.host.read_file":
      return ["mcp", "call", "tatwo.host.read_file", "--arguments", JSON.stringify(args), "--json"];
    case "tatwo_host_write_file":
    case "tatwo.host.write_file":
      return ["mcp", "call", "tatwo.host.write_file", "--arguments", JSON.stringify(args), "--json"];
    case "tatwo_host_run_command":
    case "tatwo.host.run_command":
      return ["mcp", "call", "tatwo.host.run_command", "--arguments", JSON.stringify(args), "--json"];
    case "tatwo_host_rollback":
    case "tatwo.host.rollback":
      return ["mcp", "call", "tatwo.host.rollback", "--arguments", JSON.stringify(args), "--json"];
    case "tatwo_computer_status":
    case "tatwo.computer.status":
      return ["computer", "status", "--json"];
    case "tatwo_computer_execute":
    case "tatwo.computer.execute":
      return ["mcp", "call", "tatwo.computer.execute", "--arguments", JSON.stringify(args), "--json"];
    case "tatwo_host_preflight":
      return ["host", "preflight", "--json"];
    case "tatwo_host_backup_plan":
      return ["host", "backup-plan", "--json"];
    case "tatwo_host_live_smoke_plan":
      return ["host", "live-smoke-plan", "--json"];
    case "tatwo_host_receipt_flow":
      return ["host", "receipt-flow", "--json"];
    case "tatwo_host_install_gate": {
      const out = ["host", "install-gate", "--json"];
      if (args.sandboxValidated) out.push("--sandbox-validated");
      appendOption(out, "--host-rehearsal", args.hostSandboxRehearsalReceiptID);
      if (args.preflightClear) out.push("--preflight-clear");
      appendOption(out, "--human-approval", args.humanApprovalReceiptID);
      appendOption(out, "--backup-receipt", args.backupReceiptID);
      appendOption(out, "--same-thread-smoke", args.liveSameThreadSmokeReceiptID);
      appendOption(out, "--mcp-registration-smoke", args.mcpRegistrationSmokeReceiptID);
      appendOption(out, "--rollback-receipt", args.rollbackReceiptID);
      return out;
    }
    case "tatwo_state_export":
      return ["state", "export", "--json"];
    case "tatwo_state_set_mode":
      return ["state", "set-mode", "--mode", mode, "--scenario", scenario, "--json"];
    case "tatwo_memory_list":
      return ["memory", "list", "--json"];
    case "tatwo_memory_add":
      return ["memory", "add", "--category", String(args.category ?? "failure_mode"), "--summary", String(args.summary ?? ""), "--tags", String(args.tags ?? ""), "--json"];
    case "tatwo_validate_sample_ui":
      return ["validate", "sample-ui", "--json"];
    case "tatwo_validate_operational_sample":
      return ["validate", "sample-operational", "--case", String(args.case ?? "host-live-good"), "--json"];
    default:
      return null;
  }
}

function appendOption(out, flag, value) {
  if (typeof value === "string" && value.trim()) out.push(flag, value.trim());
  else if (typeof value === "number" && Number.isFinite(value)) out.push(flag, String(value));
}

function modelListArgument(value) {
  if (Array.isArray(value)) return value.map(item => String(item).trim()).filter(Boolean).join(",");
  if (typeof value === "string") return value;
  return undefined;
}

function sendResult(id, result) {
  send({ jsonrpc: "2.0", id, result });
}

function sendError(id, code, message) {
  send({ jsonrpc: "2.0", id, error: { code, message } });
}

function send(message) {
  const json = JSON.stringify(message);
  if (transportMode === "ndjson") {
    process.stdout.write(`${json}\n`);
    return;
  }

  const body = Buffer.from(json, "utf8");
  process.stdout.write(`Content-Length: ${body.length}\r\n\r\n`);
  process.stdout.write(body);
}

const modeScenarioInput = {
  type: "object",
  properties: {
    mode: { type: "string", enum: ["S", "M", "L", "XL"], default: "M" },
    scenario: { type: "string", enum: ["daily", "design", "coding", "trading", "modeling"], default: "coding" }
  }
};

const modeScenarioObjectiveInput = {
  type: "object",
  properties: {
    mode: { type: "string", enum: ["S", "M", "L", "XL", "XXL"], default: "XL" },
    scenario: { type: "string", enum: ["daily", "design", "coding", "trading", "modeling"], default: "coding" },
    objective: { type: "string", description: "Public-safe short objective. Do not include secrets or private local paths." }
  },
  required: ["objective"]
};

const formalWorkOSBeginInput = {
  type: "object",
  properties: {
    mode: { type: "string", enum: ["S", "M", "L", "XL", "XXL"], default: "XL" },
    scenario: { type: "string", description: "Scenario profile id.", default: "coding" },
    objective: { type: "string", description: "Public-safe short objective. Do not include secrets or private local paths." },
    provider: { type: "string", description: "Exact provider owning the current session/thread." },
    ownerSession: { type: "string", description: "Exact provider session id; mutually exclusive with ownerThread." },
    ownerThread: { type: "string", description: "Exact provider thread id; mutually exclusive with ownerSession." },
    workspace: { type: "string", description: "Exact absolute workspace path bound to the owner." },
    stateRoot: { type: "string", description: "Exact absolute canonical Goal/session/dispatch state root. MCP never uses an ambient default." }
  },
  required: ["objective", "provider", "workspace", "stateRoot"],
  oneOf: [
    { required: ["ownerSession"], not: { required: ["ownerThread"] } },
    { required: ["ownerThread"], not: { required: ["ownerSession"] } }
  ],
  additionalProperties: false
};

const currentSessionAttachInput = {
  type: "object",
  properties: {
    provider: { type: "string", description: "Exact provider owning the current session/thread." },
    ownerSession: { type: "string", description: "Exact provider session id; mutually exclusive with ownerThread." },
    ownerThread: { type: "string", description: "Exact provider thread id; mutually exclusive with ownerSession." },
    workspace: { type: "string", description: "Exact absolute workspace path bound to the owner." },
    contractID: { type: "string", description: "Optional expected current-session contract id. Mismatch fails closed." },
    goalID: { type: "string", description: "Optional expected current-session goal id. Mismatch fails closed." },
    mode: { type: "string", enum: ["S", "M", "L", "XL", "XXL"], description: "Optional expected mode. Mismatch fails closed." },
    scenario: { type: "string", description: "Optional expected scenario id. Mismatch fails closed." },
    objective: { type: "string", description: "Optional expected objective. Mismatch fails closed." }
  },
  required: ["provider", "workspace"],
  oneOf: [
    { required: ["ownerSession"], not: { required: ["ownerThread"] } },
    { required: ["ownerThread"], not: { required: ["ownerSession"] } }
  ],
  additionalProperties: false
};

const workOSContractInput = {
  type: "object",
  properties: {
    mode: { type: "string", enum: ["S", "M", "L", "XL", "XXL"], default: "M" },
    scenario: { type: "string", description: "Scenario profile such as ui-ux, coding, debug, modeling, trading-risk.", default: "coding" },
    objective: { type: "string", description: "Public-safe short objective. Do not include secrets or private paths." },
    goalID: { type: "string", description: "Goal id returned by tatwo_os_begin." },
    contractID: { type: "string", description: "Required Work OS contract id. Missing id fails closed." }
  },
  required: ["contractID"]
};

const scenarioConfigScenarioInput = {
  type: "object",
  properties: {
    scenarioID: { type: "string", description: "Scenario id in staging config." },
    scenario: { type: "string", description: "Alias for scenarioID." }
  },
  required: ["scenarioID"]
};

const scenarioConfigModeBindingInput = {
  type: "object",
  properties: {
    scenarioID: { type: "string", description: "Scenario id in staging config." },
    scenario: { type: "string", description: "Alias for scenarioID." },
    mode: { type: "string", enum: ["S", "M", "L", "XL"], default: "M" },
    bindingID: { type: "string", description: "Identity binding id, e.g. daily-m-loops-supervisor." },
    binding: { type: "string", description: "Alias for bindingID." }
  },
  required: ["scenarioID", "mode", "bindingID"]
};

const tools = [
  {
    name: "tatwo_code_health_scan",
    description: "Run the repository-local Tatwo code-health scanner read-only, persist its findings through the existing security findings harness, and return only rule counts plus local artifact paths.",
    inputSchema: {
      type: "object",
      properties: {
        root: {
          type: "string",
          description: "Scan root. Must be inside this repository or a root injected through TATWO_CODE_HEALTH_ALLOWED_ROOTS."
        },
        rules: {
          oneOf: [
            { type: "string", description: "Comma-separated CH-01..CH-06 rule ids." },
            { type: "array", items: { type: "string", enum: ["CH-01", "CH-02", "CH-03", "CH-04", "CH-05", "CH-06"] } }
          ]
        },
        jsonOnly: {
          type: "boolean",
          default: false,
          description: "Return compact JSON text instead of pretty-printed JSON text."
        }
      }
    }
  },
  {
    name: "tatwo_remote_loops_contract",
    description: "Return the TATWO remote-compute fleet contract: how any AI offloads loops to other TATWO OS devices and gets results back. Covers the authority model (origin schedules, targets pull by capacity), the safety semantics (at-least-once execution, exactly-once logical commit), the trust chain (device pins, signed jobs/results, attempt binding, anti-rollback), and the exact CLI sequence. Read this before dispatching remote work.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_remote_loops_status",
    description: "Read the local remote-loop channel state: registered fleet devices, queued/in-flight/completed jobs, and whether results are ready to collect. Read-only.",
    inputSchema: {
      type: "object",
      properties: {
        deviceID: {
          type: "string",
          description: "Origin device ID. Optional: when omitted, the wrapper reads existing local identity files and proceeds only when they resolve to one unique ID."
        },
        channelDir: { type: "string", description: "Sealed channel root. Defaults to the canonical channel for this host." }
      }
    }
  },
  {
    name: "tatwo_app_mcp_manifest",
    description: "Return the engine-agnostic Tatwo App/CLI/MCP manifest. Codex is the highest-fit host, not the only engine.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_mcp_client_config",
    description: "Return a safe MCP start config and CLI fallback examples for Codex, Claude CLI, or any generic MCP client.",
    inputSchema: {
      type: "object",
      properties: {
        engine: { type: "string", description: "codex, claude-cli, generic-cli, or another engine label.", default: "generic-cli" }
      }
    }
  },
  {
    name: "tatwo_engine_capabilities",
    description: "Return what an engine can and cannot do. Use this before assigning host/executor authority.",
    inputSchema: {
      type: "object",
      properties: {
        engine: { type: "string", description: "codex, claude-cli, chatgpt-pro-mcp, grok, minimax, local-model.", default: "codex" }
      }
    }
  },
  {
    name: "tatwo_gateway_status",
    description: "Read the local model-gateway health and TATWO dispatch bridge policy. Read-only; no contractID required.",
    inputSchema: {
      type: "object",
      properties: {
        includeRaw: { type: "boolean", default: false, description: "Include redacted raw health payload for debugging." }
      }
    }
  },
  {
    name: "tatwo_gateway_models",
    description: "List local model-gateway models visible to the TATWO MCP dispatch bridge. Read-only; no contractID required.",
    inputSchema: {
      type: "object",
      properties: {
        allowedOnly: { type: "boolean", default: false, description: "Show only models allowed for TATWO text-only dispatch." }
      }
    }
  },
  {
    name: "tatwo_gateway_dispatch",
    description: "Dispatch one text-only subtask through local model-gateway under a Work OS contract. Claude/Fable can use this to summon GPT/Grok/MiniMax without host write authority. Missing contractID fails closed.",
    inputSchema: {
      type: "object",
      properties: {
        contractID: { type: "string", description: "Required Work OS contract id from tatwo_os_begin." },
        goalID: { type: "string", description: "Optional Work OS goal id." },
        bindingID: { type: "string", description: "Optional exact issued binding id. Required to disambiguate when the contract binds the same identity/model more than once." },
        sourceSlotID: { type: "string", description: "Optional exact issued source slot id. Any mismatch fails closed." },
        model: { type: "string", description: "Allowlisted route: gpt-5.5, gpt-5.4, gpt-5.4-mini, sonnet-5, minimax-m3, grok-build, haiku-4-5. Fable/Opus require allowExpensive=true." },
        identity: { type: "string", description: "Identity group for this subtask: lead, supervisor, consultant, sub, news, verifier.", default: "sub" },
        purpose: { type: "string", description: "Short public-safe reason for dispatch." },
        prompt: { type: "string", description: "Text-only subtask. Do not include secrets, auth, private logs, or live-trading actions." },
        dryRun: { type: "boolean", default: false, description: "Return planned dispatch without calling the gateway." },
        allowExpensive: { type: "boolean", default: false, description: "Explicit human-approved use for Fable/Opus routes." },
        logicalDispatchID: { type: "string", description: "Stable logical work id shared by append-only retry attempts." },
        supersedes: { type: "string", description: "Prior failed dispatch id superseded by this retry attempt." },
        maxPromptChars: { type: "number", default: 32768, maximum: 32768 },
        maxOutputChars: { type: "number", default: 12000 },
        reasoningEffort: { type: "string", enum: ["low", "medium", "high", "xhigh"], description: "Optional requested reasoning effort. An issued binding requirement wins when omitted; an explicit conflict fails closed." },
        reasoning: { type: "string", enum: ["low", "medium", "high", "xhigh"], description: "Alias for reasoningEffort." }
      },
      required: ["contractID", "model", "prompt"]
    }
  },
  {
    name: "tatwo_gateway_fanout",
    description: "Dispatch multiple text-only subtasks through local model-gateway under one Work OS contract. Sequential, capped, receipt-returning fan-out; no host write authority. Missing contractID fails closed.",
    inputSchema: {
      type: "object",
      properties: {
        contractID: { type: "string", description: "Required Work OS contract id from tatwo_os_begin." },
        goalID: { type: "string" },
        models: { oneOf: [{ type: "string" }, { type: "array", items: { type: "string" } }], description: "Comma list or array used when requests is not supplied." },
        requests: {
          type: "array",
          items: {
            type: "object",
            properties: {
              model: { type: "string" },
              identity: { type: "string" },
              bindingID: { type: "string" },
              sourceSlotID: { type: "string" },
              purpose: { type: "string" },
              prompt: { type: "string" }
            },
            required: ["model"]
          }
        },
        prompt: { type: "string", description: "Common prompt when using models instead of per-request prompts." },
        purpose: { type: "string" },
        identity: { type: "string", default: "sub" },
        maxFanout: { type: "number", default: 4, description: "Hard cap 1-8. Extra requests are skipped and listed." },
        dryRun: { type: "boolean", default: false },
        allowExpensive: { type: "boolean", default: false },
        maxPromptChars: { type: "number", default: 32768, maximum: 32768 },
        maxOutputChars: { type: "number", default: 12000 },
        reasoningEffort: { type: "string", enum: ["low", "medium", "high", "xhigh"], description: "Optional requested reasoning effort. An issued binding requirement wins when omitted; an explicit conflict fails closed." },
        reasoning: { type: "string", enum: ["low", "medium", "high", "xhigh"], description: "Alias for reasoningEffort." }
      },
      required: ["contractID"]
    }
  },
  {
    name: "tatwo_context_policy",
    description: "Return the TATWO-native Headroom-style context compression policy: reversible local cache, sensitive-content fail-closed, and shareable redaction.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_context_compress",
    description: "Compress long tool output/log/RAG/code/text under a Work OS contract. Returns a reversible TatwoContextCompressionReceiptV1; summaries do not replace original receipts.",
    inputSchema: {
      type: "object",
      properties: {
        contractID: { type: "string", description: "Required Work OS contract id from tatwo_os_begin." },
        text: { type: "string", description: "Context text to compress. Do not include secrets/auth/session material." },
        input: { type: "string", description: "Alias for text." },
        kind: { type: "string", enum: ["auto", "json", "log", "code", "text"], default: "auto" },
        sourceLabel: { type: "string", description: "Public-safe source label, e.g. build.log or gateway-response.json." },
        source: { type: "string", description: "Alias for sourceLabel." },
        runID: { type: "string", description: "Optional run/cache namespace. Defaults to contractID." },
        maxCompressedCharacters: { type: "number", default: 2400 },
        maxPreservedDiagnosticLines: { type: "number", default: 40 },
        maxLineCharacters: { type: "number", default: 240 },
        cacheOriginal: { type: "boolean", default: true },
        failOnSensitiveContent: { type: "boolean", default: true },
        redactShareableOutput: { type: "boolean", default: true },
        allowSensitive: { type: "boolean", default: false, description: "Explicitly disables failOnSensitiveContent. Avoid unless human-approved." }
      },
      required: ["contractID"]
    }
  },
  {
    name: "tatwo_context_retrieve",
    description: "Retrieve the local original text for a context receipt id under a Work OS contract. Use when the compressed summary is insufficient for verification.",
    inputSchema: {
      type: "object",
      properties: {
        contractID: { type: "string", description: "Required Work OS contract id from tatwo_os_begin." },
        id: { type: "string", description: "Context receipt id, e.g. ctx-..." },
        runID: { type: "string", description: "Optional run/cache namespace. Defaults to contractID." }
      },
      required: ["contractID", "id"]
    }
  },
  {
    name: "tatwo_context_stats",
    description: "Summarize local context-cache savings. Read-only and does not output original text.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_doctor",
    description: "Return Tatwo Ultrawork static and environment doctor checks.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_mode_list",
    description: "List S/M/L/XL mode definitions, budgets, helpers, rounds, and role splits.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_scenario_list",
    description: "List scenario definitions and model role weights.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_scenario_config",
    description: "Return the current Work OS staging scenario config. This is the Dashboard source for custom scenarios, S/M/L/XL identity bindings, budgets, and model bindings.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_scenario_config_add",
    description: "Add a custom scenario to Work OS staging config. Built-ins remain protected; this does not promote active config or mutate host Codex.",
    inputSchema: {
      type: "object",
      properties: {
        displayName: { type: "string", description: "Human-readable scenario name." },
        name: { type: "string", description: "Alias for displayName." },
        baseScenario: { type: "string", enum: ["daily", "design", "coding", "trading", "modeling"], description: "Optional base scenario." },
        base: { type: "string", enum: ["daily", "design", "coding", "trading", "modeling"], description: "Alias for baseScenario." }
      },
      required: ["displayName"]
    }
  },
  {
    name: "tatwo_scenario_config_duplicate",
    description: "Duplicate an existing scenario into a custom editable staging scenario.",
    inputSchema: scenarioConfigScenarioInput
  },
  {
    name: "tatwo_scenario_config_rename",
    description: "Rename a custom staging scenario. Built-in scenarios fail closed.",
    inputSchema: {
      type: "object",
      properties: {
        scenarioID: { type: "string" },
        scenario: { type: "string", description: "Alias for scenarioID." },
        displayName: { type: "string" },
        name: { type: "string", description: "Alias for displayName." }
      },
      required: ["scenarioID", "displayName"]
    }
  },
  {
    name: "tatwo_scenario_config_delete",
    description: "Delete a custom staging scenario. Built-in scenarios fail closed.",
    inputSchema: scenarioConfigScenarioInput
  },
  {
    name: "tatwo_scenario_config_update_token_budget",
    description: "Update one scenario/mode token-budget label in staging config. Formal goals are not cycle-capped; scoring sandboxes still use their own cap.",
    inputSchema: {
      type: "object",
      properties: {
        scenarioID: { type: "string" },
        scenario: { type: "string", description: "Alias for scenarioID." },
        mode: { type: "string", enum: ["S", "M", "L", "XL"], default: "M" },
        tokenBudget: { type: "string" },
        budget: { type: "string", description: "Alias for tokenBudget." }
      },
      required: ["scenarioID", "mode", "tokenBudget"]
    }
  },
  {
    name: "tatwo_scenario_config_set_binding_models",
    description: "Bind one Plan/Loops/Goal identity group to selected model ids in staging config.",
    inputSchema: {
      ...scenarioConfigModeBindingInput,
      properties: {
        ...scenarioConfigModeBindingInput.properties,
        modelIDs: { oneOf: [{ type: "string" }, { type: "array", items: { type: "string" } }] },
        models: { oneOf: [{ type: "string" }, { type: "array", items: { type: "string" } }], description: "Alias for modelIDs." }
      },
      required: ["scenarioID", "mode", "bindingID", "modelIDs"]
    }
  },
  {
    name: "tatwo_scenario_config_binding_resp",
    description: "Update one Plan/Loops/Goal identity responsibility text in staging config.",
    inputSchema: {
      ...scenarioConfigModeBindingInput,
      properties: {
        ...scenarioConfigModeBindingInput.properties,
        responsibility: { type: "string" }
      },
      required: ["scenarioID", "mode", "bindingID", "responsibility"]
    }
  },
  {
    name: "tatwo_plugins_list",
    description: "List plugin/skill/MCP registry entries and trigger conditions.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_capabilities_status",
    description: "List Tatwo-owned canonical skill/plugin roots, available skills, and optional provider import roots.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_capabilities_bootstrap",
    description: "Import allowlisted skills into the Tatwo-owned canonical root under a Work OS contract. Existing canonical skills are not overwritten.",
    inputSchema: {
      type: "object",
      properties: {
        contractID: { type: "string" },
        names: { oneOf: [{ type: "string" }, { type: "array", items: { type: "string" } }] }
      },
      required: ["contractID"]
    }
  },
  {
    name: "tatwo_host_executor_plan",
    description: "Return the Tatwo-owned Host Executor safety contract. Read-only; this tool does not grant execution permission.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_host_read_file",
    description: "Read one workspace-relative file through Tatwo Host Executor using an existing verified execution grant.",
    inputSchema: {
      type: "object",
      properties: {
        contractID: { type: "string" },
        leaseID: { type: "string" },
        workspaceRoot: { type: "string" },
        relativePath: { type: "string" }
      },
      required: ["contractID", "leaseID", "workspaceRoot", "relativePath"]
    }
  },
  {
    name: "tatwo_host_write_file",
    description: "Write one workspace-relative file through Tatwo Host Executor using an existing verified execution grant, with a pre-write backup.",
    inputSchema: {
      type: "object",
      properties: {
        contractID: { type: "string" },
        leaseID: { type: "string" },
        workspaceRoot: { type: "string" },
        relativePath: { type: "string" },
        content: { type: "string" }
      },
      required: ["contractID", "leaseID", "workspaceRoot", "relativePath", "content"]
    }
  },
  {
    name: "tatwo_host_run_command",
    description: "Run one allowlisted executable plus argv through Tatwo Host Executor. Shell command strings are rejected.",
    inputSchema: {
      type: "object",
      properties: {
        contractID: { type: "string" },
        leaseID: { type: "string" },
        workspaceRoot: { type: "string" },
        executable: { type: "string" },
        arguments: { type: "array", items: { type: "string" } },
        timeoutSeconds: { type: "number", minimum: 0.05, maximum: 900 }
      },
      required: ["contractID", "leaseID", "workspaceRoot", "executable"]
    }
  },
  {
    name: "tatwo_host_rollback",
    description: "Rollback one Host Executor write receipt. Requires a verified rollback grant.",
    inputSchema: {
      type: "object",
      properties: {
        contractID: { type: "string" },
        leaseID: { type: "string" },
        workspaceRoot: { type: "string" },
        writeReceipt: { type: "object" }
      },
      required: ["contractID", "leaseID", "workspaceRoot", "writeReceipt"]
    }
  },
  {
    name: "tatwo_computer_status",
    description: "Check the Tatwo-native macOS Computer Host and Accessibility/Screen Recording permission state. Does not use Codex Tool Host.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_computer_execute",
    description: "Execute one explicit UI action using a Work OS contract and an existing verified session grant.",
    inputSchema: {
      type: "object",
      properties: {
        contractID: { type: "string" },
        leaseID: { type: "string" },
        workspaceRoot: { type: "string" },
        action: { type: "string", enum: ["open_app", "activate_app", "type_text", "press_key", "screenshot", "mouse_move", "mouse_click", "mouse_double_click", "scroll"] },
        value: { type: "string" }
      },
      required: ["contractID", "leaseID", "workspaceRoot", "action"]
    }
  },
  {
    name: "tatwo_model_traits",
    description: "Return the plain-language model trait table used before assigning models to teams.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_team_list",
    description: "List Tatwo team definitions: control, design, code, research, stability, trading risk, and safe memory teams.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_team_recommend",
    description: "Recommend the best team, gates, and workflow loops for a mode/scenario.",
    inputSchema: modeScenarioInput
  },
  {
    name: "tatwo_team_dashboard",
    description: "Return a plain-language readiness dashboard: model traits, selected teams, loops, scripts, receipts, fail-closed rules, and safe next commands. Never mutates host state.",
    inputSchema: modeScenarioInput
  },
  {
    name: "tatwo_integration_plan",
    description: "Return the sandbox-first host integration plan. Host mutation is closed by default.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_stability_plan",
    description: "Return Codex App / gateway stability guards that prevent disconnects and retry storms.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_codex_disconnect_guard",
    description: "Run the read-only Codex disconnect guard: single provider, semantic SSE, clean 413, visible backend notices, app-server source, auth single source, auto-compact, and receipt boundaries. Never mutates host state.",
    inputSchema: {
      type: "object",
      properties: {
        gatewayDir: { type: "string", description: "Optional model-gateway repo/runtime path for source/test evidence. Do not include secrets." }
      }
    }
  },
  {
    name: "tatwo_colima_preflight",
    description: "Return the optional Colima sandbox verifier preflight. Missing Colima/Docker is degraded, not a Tatwo core failure. Never installs, starts, or mutates host state.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_colima_run",
    description: "Create a dry-run Colima sandbox verification receipt for a mode/scenario/objective. It does not execute containers unless a separate host-approved runner path is used.",
    inputSchema: modeScenarioObjectiveInput
  },
  {
    name: "tatwo_objective_audit",
    description: "Audit the full user objective against current evidence: model traits, teams, loops, sandbox, adversarial gates, disconnect guards, UI-deferred status, and host-install blockers. Never mutates host state.",
    inputSchema: {
      type: "object",
      properties: {
        evidenceDir: { type: "string", description: "Optional evidence directory from sandbox/host smoke." },
        latest: { type: "boolean", default: true }
      }
    }
  },
  {
    name: "tatwo_objective_adversarial",
    description: "Run adversarial tamper checks against the objective audit and readiness gate. Rejects fake completion, UI-first promotion, weak team loops, hidden host blockers, and sandbox host mutation. Never mutates host state.",
    inputSchema: {
      type: "object",
      properties: {
        evidenceDir: { type: "string", description: "Optional evidence directory from sandbox/host smoke." },
        latest: { type: "boolean", default: true }
      }
    }
  },
  {
    name: "tatwo_workflow_preview",
    description: "Preview the visual workflow template for a mode and scenario.",
    inputSchema: modeScenarioInput
  },
  {
    name: "tatwo_workflow_run",
    description: "Create a dry-run workflow execution plan. This never mutates host config.",
    inputSchema: modeScenarioObjectiveInput
  },
  {
    name: "tatwo_os_begin",
    description: "Create a new owner-bound TATWO Work OS authority transaction through the Swift Goal/session/manifest writer. Requires provider, workspace, and exactly one of ownerSession or ownerThread; requires dispatch-liveness and supervision-patrol receipts for fan-out; never bootstraps authority locks, reattaches an existing current-session, or falls back to the compatibility adapter.",
    inputSchema: formalWorkOSBeginInput
  },
  {
    name: "tatwo_os_goal_candidate_create",
    description: "Consume exact authorization-binding artifact bytes plus their SHA-256 and create only one fresh planned Goal candidate after Swift core verifies live scenario, projected contract, identity bindings, complete Goal-store preflight manifest, and exact target JSON/lock absence before any Goal lock or write.",
    inputSchema: {
      type: "object",
      properties: {
        mode: { type: "string", enum: ["S", "M", "L", "XL", "XXL"] },
        scenario: { type: "string" },
        objective: { type: "string" },
        authorizationBindingArtifactSHA256: {
          type: "string",
          description: "SHA-256 of the exact UTF-8 authorizationBindingArtifactJSON bytes."
        },
        authorizationBindingArtifactJSON: {
          type: "string",
          description: "Exact UTF-8 TatwoGoalCandidateCreateAuthorizationBindingV1 JSON bytes supplied as request data, never a path."
        }
      },
      required: [
        "mode",
        "scenario",
        "objective",
        "authorizationBindingArtifactSHA256",
        "authorizationBindingArtifactJSON"
      ],
      additionalProperties: false
    }
  },
  {
    name: "tatwo_os_session_attach",
    description: "Read-only rehydrate after exact provider, absolute workspace, and ownerSession/ownerThread one-of are forwarded to the Swift CLI for canonical V3 owner verification. Pointer, goal, objective, route, owner kind, or caller mismatch fails closed; this path never calls tatwo_os_begin and has zero compatibility fallback.",
    inputSchema: currentSessionAttachInput
  },
  {
    name: "tatwo_os_next",
    description: "Return the next Work OS action for a goal/contract. Missing contractID fails closed; fan-out gaps surface blocking states supervision_gap and goal_tracker_missing.",
    inputSchema: workOSContractInput
  },
  {
    name: "tatwo_os_loop_status",
    description: "Return read-only mainline/domain loop status. The visualizer cannot promote or pass a goal.",
    inputSchema: workOSContractInput
  },
  {
    name: "tatwo_os_receipt_submit",
    description: "Submit a test/screenshot/review/sandbox receipt into Work OS staging. Missing contractID or receiptID fails closed.",
    inputSchema: {
      type: "object",
      properties: {
        goalID: { type: "string" },
        contractID: { type: "string" },
        loopID: { type: "string" },
        receiptID: { type: "string" },
        receiptKind: { type: "string", default: "generic" }
      },
      required: ["contractID", "receiptID"]
    }
  },
  {
    name: "tatwo_os_goal_close",
    description: "Close a Work OS goal only when all required receipts are supplied. Insufficient receipts returns rollback_required.",
    inputSchema: {
      type: "object",
      properties: {
        mode: { type: "string", enum: ["S", "M", "L", "XL"], default: "M" },
        scenario: { type: "string", default: "coding" },
        objective: { type: "string" },
        goalID: { type: "string" },
        contractID: { type: "string" },
        receiptIDs: { type: "array", items: { type: "string" } }
      },
      required: ["contractID", "receiptIDs"]
    }
  },
  {
    name: "tatwo_os_dispatch_finalize",
    description: "Explicitly seal the current non-empty all-completed dispatch cycle. A cycle seal never succeeds the GoalRun; retries are idempotent for the same immutable seal.",
    inputSchema: {
      type: "object",
      properties: {
        contractID: { type: "string", description: "Required Work OS contract id." }
      },
      required: ["contractID"]
    }
  },
  {
    name: "tatwo_os_dispatch_advance",
    description: "Open the next dispatch cycle for the same GoalRun from the exact latest immutable seal. Stale seals, unrelated human gates, and terminal Goals fail closed.",
    inputSchema: {
      type: "object",
      properties: {
        contractID: { type: "string", description: "Required Work OS contract id." },
        expectedSealID: { type: "string", description: "Exact latest dispatch-cycle seal id." }
      },
      required: ["contractID", "expectedSealID"]
    }
  },
  {
    name: "tatwo_os_recovery_begin",
    description: "Create a new append-only recovery GoalRun for a terminal failed origin. The origin remains failed; authorization is hashed and not stored raw.",
    inputSchema: {
      type: "object",
      properties: {
        contractID: { type: "string", description: "Failed origin contract id." },
        authorizationToken: { type: "string", description: "Explicit one-time human or orchestrator recovery authority." },
        reason: { type: "string" },
        adjudicationRef: { type: "string" }
      },
      required: ["contractID", "authorizationToken", "reason", "adjudicationRef"]
    }
  },
  {
    name: "tatwo_os_dashboard",
    description: "Return the real read-only Work OS dashboard snapshot: goal, contract, mainline/domain loops, identities, tools, sandbox, receipts, READY/ROLLBACK.",
    inputSchema: {
      type: "object",
      properties: {
        mode: { type: "string", enum: ["S", "M", "L", "XL"], default: "XL" },
        scenario: { type: "string", default: "coding" },
        objective: { type: "string" },
        receiptIDs: { type: "array", items: { type: "string" } }
      }
    }
  },
  {
    name: "tatwo_os_enforce",
    description: "Check an agent action against the Work OS contract. Missing contract, unregistered tool, host mutation, or visualizer promotion fail closed.",
    inputSchema: {
      type: "object",
      properties: {
        mode: { type: "string", enum: ["S", "M", "L", "XL"], default: "M" },
        scenario: { type: "string", default: "coding" },
        objective: { type: "string" },
        contractID: { type: "string" },
        toolName: { type: "string", default: "tatwo.os.next" },
        identity: { type: "string", default: "sub" },
        mutation: { type: "string", default: "read_only" },
        surface: { type: "string", default: "mcp" },
        receiptID: { type: "string" }
      },
      required: ["contractID", "toolName"]
    }
  },
  {
    name: "tatwo_os_handoff",
    description: "Return an OS handoff pack with agents.md, tools.md, receipts.md, allowed tools, dashboard, forbidden actions, and dispatch liveness/supervision hard rules.",
    inputSchema: modeScenarioObjectiveInput
  },
  {
    name: "tatwo_os_constitution",
    description: "Return the Work OS constitution: agent roles, tool rules, receipt rules, dispatch liveness (< /dev/null, 2-minute startup, 10-minute watchdog), supervision patrol, scope adjudication, and hard fail-closed boundaries.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_web_arena_plan",
    description: "Create the TATWO Web Arena v1 plan for tattoo, 3D asset library, and Pionex-style webpage benchmarks. Planning only; no model fan-out.",
    inputSchema: {
      type: "object",
      properties: {
        suite: { type: "string", enum: ["v1"], default: "v1" },
        runID: { type: "string" },
        models: { oneOf: [{ type: "string" }, { type: "array", items: { type: "string" } }] }
      }
    }
  },
  {
    name: "tatwo_web_arena_report",
    description: "Summarize a local Web Arena run report. Does not rescore, delete files, or upload artifacts.",
    inputSchema: {
      type: "object",
      properties: { runID: { type: "string" } },
      required: ["runID"]
    }
  },
  {
    name: "tatwo_web_arena_cleanup_plan",
    description: "Return a dry-run cleanup plan for old Web Arena sandbox runs. MCP never deletes files.",
    inputSchema: {
      type: "object",
      properties: { olderThan: { type: "string", default: "14d" } }
    }
  },
  {
    name: "tatwo_sandbox_arena_list",
    description: "List the missing scoring sandboxes beyond Web Arena: code architecture, debug, research, multimodal, plugin/MCP, writing, and 3D modeling.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_sandbox_arena_plan",
    description: "Create the TATWO missing sandbox arena v1 plan. Planning only; no model fan-out and no automatic Blender / UE5.8 startup.",
    inputSchema: {
      type: "object",
      properties: {
        arena: { type: "string", default: "all" },
        runID: { type: "string" },
        models: { oneOf: [{ type: "string" }, { type: "array", items: { type: "string" } }] }
      }
    }
  },
  {
    name: "tatwo_sandbox_arena_report",
    description: "Summarize a local missing sandbox arena run report. Does not rescore, delete files, or upload artifacts.",
    inputSchema: {
      type: "object",
      properties: {
        arena: { type: "string", default: "all" },
        runID: { type: "string" }
      },
      required: ["arena", "runID"]
    }
  },
  {
    name: "tatwo_arena_plan_loop_goal_policy",
    description: "Return the universal Plan+Loops+Goal protocol for all scoring sandboxes: mainline, branch optimization, registered-tool choice, and grading-after-all-tests rule.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_arena_plan_loop_goal_score",
    description: "Score a model's Plan+Loops+Goal discipline only after all sandbox tests are complete and the goal is sealed or capped.",
    inputSchema: {
      type: "object",
      properties: {
        modelSlug: { type: "string" },
        expectedSandboxTests: { type: "number", default: 0 },
        completedSandboxTests: { type: "number", default: 0 },
        missingSandboxTests: { oneOf: [{ type: "string" }, { type: "array", items: { type: "string" } }] },
        goalExecutionCycles: { type: "number", default: 0 },
        finalSubmissionSealed: { type: "boolean", default: false },
        fileHashesChangedAfterSeal: { type: "boolean", default: false },
        presentArtifacts: { oneOf: [{ type: "string" }, { type: "array", items: { type: "string" } }] },
        toolChoicesAllRegistered: { type: "boolean", default: false }
      }
    }
  },
  {
    name: "tatwo_arena_goal_cycle_assess",
    description: "Assess whether a sandbox goal can continue or must enter grading. Each goal has at most 5 implementation cycles; planning and loop ledger entries are unlimited.",
    inputSchema: {
      type: "object",
      properties: {
        goalExecutionCycles: { type: "number", default: 0 },
        finalSubmissionSealed: { type: "boolean", default: false },
        fileHashesChangedAfterSeal: { type: "boolean", default: false }
      }
    }
  },
  {
    name: "tatwo_web_check_preflight",
    description: "Check the local web-check / frontend health tool and return rule parity plus local-only safety rules. Does not upload code or mutate projects.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_web_check_plan",
    description: "Create a web-check validation plan for a mode/scenario/target. It is a receipt source, not a model or visual approval.",
    inputSchema: {
      type: "object",
      properties: {
        mode: { type: "string", enum: ["S", "M", "L", "XL"], default: "L" },
        scenario: { type: "string", default: "ui-ux" },
        target: { type: "string", description: "Local project path or public URL. Local paths are redacted in shareable output." },
        scanType: { type: "string", enum: ["focused", "full", "category", "public-url", "why", "rule-explain"] },
        blockingPolicy: { type: "string", enum: ["no-new-error", "no-critical", "report-only"] }
      }
    }
  },
  {
    name: "tatwo_web_check_import_receipt",
    description: "Import a local web-check JSON report as TatwoWebCheckReceiptV1. Missing contractID or blocking findings fail closed.",
    inputSchema: {
      type: "object",
      properties: {
        goalID: { type: "string" },
        contractID: { type: "string" },
        reportJSON: { type: "string", description: "Local JSON report content. Do not include secrets." },
        reportPath: { type: "string", description: "Alternative local report path for host-side import only." },
        targetKind: { type: "string", enum: ["local-project", "public-url"], default: "local-project" },
        scanType: { type: "string", enum: ["focused", "full", "category", "public-url", "why", "rule-explain"], default: "full" },
        blockingPolicy: { type: "string", enum: ["no-new-error", "no-critical", "report-only"], default: "no-new-error" },
        command: { type: "string" }
      },
      required: ["contractID"]
    }
  },
  {
    name: "tatwo_web_check_receipt_template",
    description: "Return the TatwoWebCheckReceiptV1 template expected by Work OS.",
    inputSchema: {
      type: "object",
      properties: {
        goalID: { type: "string" },
        contractID: { type: "string" }
      },
      required: ["contractID"]
    }
  },
  {
    name: "tatwo_handoff_pack",
    description: "Create a public-safe handoff pack for another model or Codex thread.",
    inputSchema: modeScenarioObjectiveInput
  },
  {
    name: "tatwo_install_plan",
    description: "Return install prompts, dependency checks, smoke commands, and rollback plan.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_sandbox_preflight",
    description: "Return sandbox preflight requirements. Does not touch host Codex config.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_sandbox_begin",
    description: "Create a Work OS local sandbox session under the configured sandbox root. Requires contractID; writes are scoped to the sandbox; host mutation remains false.",
    inputSchema: {
      type: "object",
      properties: {
        contractID: { type: "string", description: "Required Work OS contract id from tatwo_os_begin." },
        goalID: { type: "string" },
        sandboxID: { type: "string", description: "Optional safe id. Usually generated." },
        mode: { type: "string", enum: ["S", "M", "L", "XL"], default: "M" },
        scenario: { type: "string", default: "custom" },
        objective: { type: "string", description: "Public-safe sandbox objective." }
      },
      required: ["contractID"]
    }
  },
  {
    name: "tatwo_sandbox_write_artifact",
    description: "Write a text artifact inside a TATWO sandbox only. Rejects missing contractID, wrong sandbox, path escape, protected control files, and auth/session-like content.",
    inputSchema: {
      type: "object",
      properties: {
        contractID: { type: "string" },
        sandboxID: { type: "string" },
        relativePath: { type: "string", description: "Relative path inside sandbox, e.g. generated-artifacts/app.js." },
        content: { type: "string" },
        maxBytes: { type: "number", default: 2000000 }
      },
      required: ["contractID", "sandboxID", "relativePath", "content"]
    }
  },
  {
    name: "tatwo_sandbox_run_command",
    description: "Run an allowlisted command in a TATWO sandbox with sanitized env. It is local path-guarded, not a kernel/container sandbox; use Colima for untrusted execution.",
    inputSchema: {
      type: "object",
      properties: {
        contractID: { type: "string" },
        sandboxID: { type: "string" },
        command: { type: "string", enum: ["node", "python3", "npm"] },
        args: { oneOf: [{ type: "string" }, { type: "array", items: { type: "string" } }] },
        timeoutMS: { type: "number", default: 30000 },
        maxOutputChars: { type: "number", default: 8000 }
      },
      required: ["contractID", "sandboxID", "command"]
    }
  },
  {
    name: "tatwo_sandbox_receipt",
    description: "Return a sandbox receipt bundle with manifest hash, artifact hashes, command receipts, and missing promotion gates.",
    inputSchema: {
      type: "object",
      properties: {
        contractID: { type: "string" },
        sandboxID: { type: "string" }
      },
      required: ["contractID", "sandboxID"]
    }
  },
  {
    name: "tatwo_sandbox_promote_plan",
    description: "Create a plan-only sandbox-to-host promotion checklist. It never copies files and always keeps hostMutationAllowed=false.",
    inputSchema: {
      type: "object",
      properties: {
        contractID: { type: "string" },
        sandboxID: { type: "string" },
        targetHint: { type: "string", description: "Plain target description for human/Codex host review." }
      },
      required: ["contractID", "sandboxID"]
    }
  },
  {
    name: "tatwo_host_preflight",
    description: "Return the read-only host preflight checklist for Codex App/gateway stability. Does not mutate host state.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_host_backup_plan",
    description: "Return the dry-run backup plan required before any host install. Does not copy files.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_host_live_smoke_plan",
    description: "Return required same-thread and MCP registration smoke receipts for host install gating.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_host_receipt_flow",
    description: "Return the full host receipt flow: sandbox, preflight, backup, rollback, same-thread smoke, MCP smoke, and human gate.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_host_sandbox_rehearsal",
    description: "Run a fake HOME/CODEX_HOME host-install rehearsal: backup, MCP registration, stdio smoke, and rollback without touching real host state.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_host_install_gate",
    description: "Structural receipt gate. Prefer tatwo_host_verified_install_gate before real host install. This only returns a decision and never mutates host state.",
    inputSchema: {
      type: "object",
      properties: {
        sandboxValidated: { type: "boolean", default: false },
        hostSandboxRehearsalReceiptID: { type: "string" },
        preflightClear: { type: "boolean", default: false },
        humanApprovalReceiptID: { type: "string" },
        backupReceiptID: { type: "string" },
        liveSameThreadSmokeReceiptID: { type: "string" },
        mcpRegistrationSmokeReceiptID: { type: "string" },
        rollbackReceiptID: { type: "string" }
      }
    }
  },
  {
    name: "tatwo_host_verified_install_gate",
    description: "Evidence-backed host install gate. Reads an evidence directory and blocks dry-run or stdio-only receipts. Never mutates host state.",
    inputSchema: {
      type: "object",
      properties: {
        evidenceDir: { type: "string", description: "Optional evidence directory from sandbox/host smoke." },
        latest: { type: "boolean", default: true },
        humanApprovalReceiptID: { type: "string", description: "Explicit approval id, e.g. human-20260622-scope." }
      }
    }
  },
  {
    name: "tatwo_m2_entry_gate",
    description: "Gate for entering M2 after M1: requires current M1 evidence plus a fresh explicit M2 human approval. Blocks M1 dry-run approval reuse. Never mutates host state, authorizes UI, or installs anything.",
    inputSchema: {
      type: "object",
      properties: {
        evidenceDir: { type: "string", description: "Optional M1 evidence directory." },
        latest: { type: "boolean", default: true },
        humanApprovalReceiptID: { type: "string", description: "Fresh approval id, e.g. human-M2-20260622-scope. M1 dry-run approvals are rejected." },
        confirmM2: { type: "boolean", default: false, description: "Must be true after the user explicitly says to release M2." }
      }
    }
  },
  {
    name: "tatwo_m2_final_gate",
    description: "Final M2 evidence gate: requires complete host receipts, fresh M2 approval, live same-thread smoke, backup, rollback, route gate, redaction, and observed Codex host MCP registration. Never mutates host state or validates UI.",
    inputSchema: {
      type: "object",
      properties: {
        evidenceDir: { type: "string", description: "Optional M2 evidence directory." },
        latest: { type: "boolean", default: true },
        humanApprovalReceiptID: { type: "string", description: "Fresh approval id, e.g. human-M2-20260624-user-approved." },
        confirmM2: { type: "boolean", default: false, description: "Must be true after the user explicitly says to finish M2." }
      }
    }
  },
  {
    name: "tatwo_host_install_runway",
    description: "Return the current host install runway: phase, team owners, missing receipts, safe next commands, and disconnect protections. Never mutates host state.",
    inputSchema: {
      type: "object",
      properties: {
        evidenceDir: { type: "string", description: "Optional evidence directory from sandbox/host smoke." },
        latest: { type: "boolean", default: true },
        humanApprovalReceiptID: { type: "string", description: "Optional approval id to test the verified gate." }
      }
    }
  },
  {
    name: "tatwo_host_promotion_plan",
    description: "Return the read-only host promotion runway: single gateway, no Codex bundle patch, sandbox-before-host, UI-last, route-risk triage, team owners, and circuit breakers. Never mutates host state or authorizes install.",
    inputSchema: {
      type: "object",
      properties: {
        evidenceDir: { type: "string", description: "Optional evidence directory from sandbox/host smoke." },
        latest: { type: "boolean", default: true }
      }
    }
  },
  {
    name: "tatwo_route_risk_dashboard",
    description: "Return a plain-Chinese route risk dashboard for model routes with errors or no last_ok. Keeps UI and host install closed and requires live same-thread response.completed proof. Never mutates host state.",
    inputSchema: {
      type: "object",
      properties: {
        evidenceDir: { type: "string", description: "Optional evidence directory from sandbox/host smoke." },
        latest: { type: "boolean", default: true }
      }
    }
  },
  {
    name: "tatwo_route_smoke_plan",
    description: "Return a plain-Chinese same-thread smoke queue for risky model routes. Keeps UI and host install closed; each risky route requires response.completed and continuity back to gpt-5.5. Never mutates host state.",
    inputSchema: {
      type: "object",
      properties: {
        evidenceDir: { type: "string", description: "Optional evidence directory from sandbox/host smoke." },
        latest: { type: "boolean", default: true }
      }
    }
  },
  {
    name: "tatwo_route_live_smoke_receipts",
    description: "Verify per-route host-live smoke receipts for risky model routes. Fails closed for model text, partial streams, dry-run receipts, stdio self-reports, wrong model, provider split, or missing continuity back to gpt-5.5. Never mutates host state or authorizes UI/host install.",
    inputSchema: {
      type: "object",
      properties: {
        evidenceDir: { type: "string", description: "Optional evidence directory from sandbox/host smoke." },
        latest: { type: "boolean", default: true }
      }
    }
  },
  {
    name: "tatwo_state_export",
    description: "Export local Tatwo preferences and safe-memory receipts.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_state_set_mode",
    description: "Persist selected mode/scenario in Tatwo local state.",
    inputSchema: modeScenarioInput
  },
  {
    name: "tatwo_memory_list",
    description: "List safe-memory receipts stored by Tatwo.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_memory_add",
    description: "Append a safe-memory receipt. Rejects raw logs, tokens, private paths, and full chats.",
    inputSchema: {
      type: "object",
      properties: {
        category: { type: "string", enum: ["mode_preference", "scenario_weight", "compatibility_score", "success_receipt", "failure_mode"], default: "failure_mode" },
        summary: { type: "string", description: "Safe short summary. No raw logs, tokens, private paths, screenshots, or full chats." },
        tags: { type: "string", description: "Comma-separated safe tags." }
      },
      required: ["summary"]
    }
  },
  {
    name: "tatwo_validate_sample_ui",
    description: "Demonstrate fail-closed UI validation; expected to return isError=true.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "tatwo_validate_operational_sample",
    description: "Validate a built-in operational receipt case. Bad cases intentionally return isError=true: partial-stream, stdio-fake-host, dry-run-host-live, disconnected, retry-storm, old-approval-epoch, model-text-approval.",
    inputSchema: {
      type: "object",
      properties: {
        case: {
          type: "string",
          enum: ["host-live-good", "host-mcp-good", "partial-stream", "stdio-fake-host", "dry-run-host-live", "disconnected", "retry-storm", "old-approval-epoch", "model-text-approval"],
          default: "host-live-good"
        }
      }
    }
  },
  {
    name: "tatwo_validate_operational_receipt",
    description: "Validate a caller-provided TatwoOperationalReceiptV1 JSON string against an explicit requirement. Never treats model text, dry-run, partial streams, stdio self-report, or old approval epochs as host install proof.",
    inputSchema: {
      type: "object",
      properties: {
        receiptJSON: { type: "string", description: "TatwoOperationalReceiptV1 JSON. Do not include secrets or private paths." },
        requirement: { type: "string", enum: ["host-live-same-thread", "mcp-host-registration", "host-install-approval", "sandbox-operational"], default: "host-live-same-thread" },
        requiredEpoch: { type: "number", description: "Required approval epoch for host-install-approval." }
      },
      required: ["receiptJSON"]
    }
  }
];


function runSelftest() {
  const toolByName = new Map(tools.map((tool) => [tool.name, tool]));
  const checks = [];
  function check(id, condition, details = "") {
    checks.push({ id, ok: Boolean(condition), details });
  }
  const begin = toolByName.get("tatwo_os_begin");
  const goalCandidateCreate = toolByName.get("tatwo_os_goal_candidate_create");
  const attach = toolByName.get("tatwo_os_session_attach");
  const next = toolByName.get("tatwo_os_next");
  const handoff = toolByName.get("tatwo_os_handoff");
  const constitution = toolByName.get("tatwo_os_constitution");
  const allText = JSON.stringify(tools);
  const candidateRouteProbe = {
    mode: "XXL",
    scenario: "coding",
    objective: "candidate route probe",
    authorizationBindingArtifactSHA256: `sha256:${"a".repeat(64)}`,
    authorizationBindingArtifactJSON: "{\"exact\":\"bytes\\nkept\"}",
  };
  const candidateRouteArgs = cliArgsForTool(
    "tatwo_os_goal_candidate_create",
    candidateRouteProbe);
  const candidateArgumentsIndex = candidateRouteArgs.indexOf("--arguments");
  const candidateForwardedArguments = candidateArgumentsIndex >= 0
    ? JSON.parse(candidateRouteArgs[candidateArgumentsIndex + 1])
    : {};
  const attachSessionProbe = {
    provider: "codex",
    ownerSession: "session-exact",
    workspace: "/tmp/tatwo-owner-session",
    contractID: "contract-exact",
    goalID: "goal-exact",
  };
  const attachThreadProbe = {
    provider: "tatwo-chat",
    ownerThread: "thread-exact",
    workspace: "/tmp/tatwo-owner-thread",
  };
  const attachSessionArgs = cliArgsForTool(
    "tatwo_os_session_attach",
    attachSessionProbe);
  const attachThreadArgs = cliArgsForTool(
    "tatwo_os_session_attach",
    attachThreadProbe);
  check("tool.begin.exists", begin, "tatwo_os_begin registered");
  check(
    "tool.goal.candidate.create.exists",
    goalCandidateCreate,
    "tatwo_os_goal_candidate_create registered");
  check(
    "tool.goal.candidate.create.requires-exact-artifact",
    [
      "mode",
      "scenario",
      "objective",
      "authorizationBindingArtifactSHA256",
      "authorizationBindingArtifactJSON",
    ].every((key) => goalCandidateCreate?.inputSchema?.required?.includes(key)),
    JSON.stringify(goalCandidateCreate?.inputSchema?.required ?? []));
  check(
    "tool.goal.candidate.create.routes-to-swift-mcp-call",
    candidateRouteArgs.slice(0, 3).join(" ")
      === "mcp call tatwo.os.goal.candidate.create",
    JSON.stringify(candidateRouteArgs));
  check(
    "tool.goal.candidate.create.preserves-exact-request-strings",
    candidateForwardedArguments.authorizationBindingArtifactSHA256
      === candidateRouteProbe.authorizationBindingArtifactSHA256
      && candidateForwardedArguments.authorizationBindingArtifactJSON
        === candidateRouteProbe.authorizationBindingArtifactJSON,
    JSON.stringify(candidateForwardedArguments));
  check("tool.session.attach.exists", attach, "tatwo_os_session_attach registered");
  check(
    "tool.session.attach.requires-provider-workspace",
    ["provider", "workspace"].every(
      (key) => attach?.inputSchema?.required?.includes(key)),
    JSON.stringify(attach?.inputSchema?.required ?? []));
  check(
    "tool.session.attach.owner-one-of",
    attach?.inputSchema?.oneOf?.length === 2
      && attach?.inputSchema?.additionalProperties === false,
    JSON.stringify(attach?.inputSchema ?? {}));
  check(
    "tool.session.attach.forwards-session-kind",
    attachSessionArgs.includes("--provider")
      && attachSessionArgs.includes("codex")
      && attachSessionArgs.includes("--owner-session")
      && attachSessionArgs.includes("session-exact")
      && !attachSessionArgs.includes("--owner-thread")
      && attachSessionArgs.includes("--workspace")
      && attachSessionArgs.includes("/tmp/tatwo-owner-session"),
    JSON.stringify(attachSessionArgs));
  check(
    "tool.session.attach.forwards-thread-kind",
    attachThreadArgs.includes("--provider")
      && attachThreadArgs.includes("tatwo-chat")
      && attachThreadArgs.includes("--owner-thread")
      && attachThreadArgs.includes("thread-exact")
      && !attachThreadArgs.includes("--owner-session")
      && attachThreadArgs.includes("--workspace")
      && attachThreadArgs.includes("/tmp/tatwo-owner-thread"),
    JSON.stringify(attachThreadArgs));
  check(
    "tool.session.attach.zero-owner-fallback",
    !attach?.description?.includes("compatibility adapter")
      && attach?.description?.includes("zero compatibility fallback")
      && !attachSessionArgs.some((value) => /infer|fallback/i.test(value))
      && !attachThreadArgs.some((value) => /infer|fallback/i.test(value)),
    attach?.description ?? "");
  check(
    "tool.begin.has-no-existing-id-interface",
    begin?.inputSchema?.properties?.contractID === undefined
      && begin?.inputSchema?.properties?.goalID === undefined,
    "tatwo_os_begin must not advertise existing IDs");
  check(
    "tool.session.attach.never-begin",
    attach?.description?.includes("never calls tatwo_os_begin"),
    attach?.description ?? "");
  check("tool.next.exists", next, "tatwo_os_next registered");
  check("begin.requires.dispatch-liveness", begin?.description?.includes("dispatch-liveness"), begin?.description ?? "");
  check("begin.requires.supervision-patrol", begin?.description?.includes("supervision-patrol"), begin?.description ?? "");
  check("next.blocks.supervision_gap", next?.description?.includes("supervision_gap"), next?.description ?? "");
  check("next.blocks.goal_tracker_missing", next?.description?.includes("goal_tracker_missing"), next?.description ?? "");
  check("handoff.includes.hard-rules", handoff?.description?.includes("dispatch liveness"), handoff?.description ?? "");
  check("constitution.stdin.closed", constitution?.description?.includes("< /dev/null"), constitution?.description ?? "");
  check("constitution.startup.watchdog.scope", /2-minute startup/.test(allText) && /10-minute watchdog/.test(allText) && /scope adjudication/.test(allText), "constitution description mirrors incident hard rules");
  const ok = checks.every((item) => item.ok);
  const result = {
    ok,
    schema: "TatwoUltraworkMCPHardeningSelftestV1",
    checkedAt: new Date().toISOString(),
    hardRules: [
      "codex exec/background dispatch must close stdin with < /dev/null",
      "startup must be confirmed within about 2 minutes",
      "10-minute stall watchdog alarms on no output growth",
      "fan-out requires dispatch-liveness and supervision-patrol receipts",
      "scope drift requires adjudication record",
      "tatwo.os.next surfaces supervision_gap and goal_tracker_missing"
    ],
    checks
  };
  console.log(JSON.stringify(result, null, 2));
  process.exit(ok ? 0 : 1);
}

if (process.argv.includes("--selftest") || process.argv.includes("--check")) {
  runSelftest();
}
