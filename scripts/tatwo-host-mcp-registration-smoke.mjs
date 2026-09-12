#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const serverPath = path.join(scriptDir, "tatwo-ultrawork-mcp.mjs");
const args = parseArgs(process.argv.slice(2));
const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-host-mcp-smoke-"));
const expectHostRegistration = Boolean(args["expect-host-registration"]);
const hostConfigPath = args["host-config"] ? path.resolve(String(args["host-config"])) : null;
const mcpToolTimeoutMS = readTimeoutMS(process.env.TATWO_MCP_TOOL_TIMEOUT_MS, 30000);
const requestTimeoutMS = Math.max(60000, mcpToolTimeoutMS + 30000);
const requiredTools = [
  "tatwo_doctor",
  "tatwo_host_preflight",
  "tatwo_host_receipt_flow",
  "tatwo_host_sandbox_rehearsal",
  "tatwo_host_install_gate",
  "tatwo_host_verified_install_gate",
  "tatwo_host_install_runway",
  "tatwo_m2_final_gate",
  "tatwo_workflow_run"
];

const child = spawn(process.execPath, [serverPath], {
  cwd: path.resolve(scriptDir, ".."),
  env: { ...process.env, TATWO_ULTRAWORK_STATE_DIR: stateDir },
  stdio: ["pipe", "pipe", "pipe"]
});

let buffer = Buffer.alloc(0);
let stderr = "";
let nextID = 1;
const pending = new Map();
child.stderr.on("data", chunk => { stderr += chunk.toString("utf8"); });
child.stdout.on("data", chunk => { buffer = Buffer.concat([buffer, chunk]); drain(); });

let report;
try {
  await request("initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "tatwo-host-mcp-registration-smoke", version: "0.1.0" }
  });
  const list = await request("tools/list", {});
  const toolNames = (list.tools ?? []).map(tool => tool.name).sort();
  const missing = requiredTools.filter(name => !toolNames.includes(name));
  const doctor = await request("tools/call", { name: "tatwo_doctor", arguments: {} });
  const doctorText = doctor.content?.[0]?.text ?? "";
  const passed = missing.length === 0 && doctorText.includes("TatwoDoctorReportV1");
  const hostRegistration = observeHostRegistration(hostConfigPath);
  const hostRegistrationObserved = expectHostRegistration && hostRegistration.observed;
  const receiptPrefix = hostRegistrationObserved ? "mcp-host" : "mcp-stdio";
  report = {
    schema: "TatwoHostMCPRegistrationSmokeReceiptV1",
    passed,
    receiptID: passed ? `${receiptPrefix}-${shortHash([toolNames.join("\n"), hostRegistration.fingerprint].join("|"))}` : null,
    hostMutationAllowed: false,
    registrationMutationPerformed: false,
    hostRegistrationObserved,
    hostRegistrationExpected: expectHostRegistration,
    hostRegistrationCheck: hostRegistration.status,
    registrationScope: hostRegistrationObserved ? "codex_host_config_observed_readonly" : "stdio_server_compatibility_only_not_codex_host_config",
    generatedAt: new Date().toISOString(),
    requiredTools,
    missingTools: missing,
    toolCount: toolNames.length,
    observedToolsHash: shortHash(toolNames.join("\n")),
    plainSummary: passed
      ? (hostRegistrationObserved
          ? "Tatwo MCP stdio works and a read-only host config check observed Tatwo registration. This is a host MCP registration receipt."
          : "Tatwo MCP stdio server tools/list and tools/call work. This proves MCP compatibility, not that Codex host config has been mutated.")
      : "Tatwo MCP stdio smoke failed; do not register host MCP until this is fixed."
  };
} catch (error) {
  report = {
    schema: "TatwoHostMCPRegistrationSmokeReceiptV1",
    passed: false,
    receiptID: null,
    hostMutationAllowed: false,
    registrationMutationPerformed: false,
    hostRegistrationObserved: false,
    hostRegistrationExpected: expectHostRegistration,
    hostRegistrationCheck: "not_observed_due_to_smoke_failure",
    registrationScope: "stdio_server_compatibility_only_not_codex_host_config",
    generatedAt: new Date().toISOString(),
    requiredTools,
    missingTools: requiredTools,
    toolCount: 0,
    error: String(error?.message ?? error).replace(/\/Users\/[^\s]+|\/Volumes\/[^\s]+/g, "<local-path>"),
    plainSummary: "Tatwo MCP stdio smoke failed; do not register host MCP until this is fixed."
  };
} finally {
  child.kill();
  fs.rmSync(stateDir, { recursive: true, force: true });
}

console.log(JSON.stringify(report, null, 2));
process.exit(report.passed ? 0 : 1);

function request(method, params) {
  const id = nextID++;
  const payload = { jsonrpc: "2.0", id, method, params };
  const body = Buffer.from(JSON.stringify(payload), "utf8");
  child.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
  child.stdin.write(body);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`timeout waiting for ${method}: ${stderr.slice(-200)}`));
    }, requestTimeoutMS);
    pending.set(id, { resolve, reject, timer });
  });
}

function drain() {
  while (true) {
    const headerEnd = buffer.indexOf("\r\n\r\n");
    if (headerEnd < 0) return;
    const header = buffer.slice(0, headerEnd).toString("utf8");
    const match = header.match(/Content-Length:\s*(\d+)/i);
    if (!match) throw new Error(`bad header: ${header}`);
    const length = Number(match[1]);
    const bodyStart = headerEnd + 4;
    const bodyEnd = bodyStart + length;
    if (buffer.length < bodyEnd) return;
    const body = buffer.slice(bodyStart, bodyEnd).toString("utf8");
    buffer = buffer.slice(bodyEnd);
    const message = JSON.parse(body);
    const slot = pending.get(message.id);
    if (!slot) continue;
    clearTimeout(slot.timer);
    pending.delete(message.id);
    if (message.error) slot.reject(new Error(message.error.message));
    else slot.resolve(message.result);
  }
}

function shortHash(value) {
  return crypto.createHash("sha256").update(String(value)).digest("hex").slice(0, 12);
}

function readTimeoutMS(value, fallback) {
  const parsed = Number(value ?? fallback);
  return Number.isFinite(parsed) && parsed >= 1000 ? parsed : fallback;
}

function observeHostRegistration(file) {
  if (!expectHostRegistration) return { observed: false, status: "not_requested", fingerprint: "not-requested" };
  if (!file) return { observed: false, status: "host_config_required", fingerprint: "missing" };
  try {
    const text = fs.readFileSync(file, "utf8");
    const hasTatwo = /tatwo[-_ ]?ultrawork/i.test(text);
    const hasMcpScript = /tatwo-ultrawork-mcp\.mjs/.test(text);
    const observed = hasTatwo && hasMcpScript;
    return {
      observed,
      status: observed ? "observed" : "tatwo_mcp_entry_not_found",
      fingerprint: observed ? shortHash(text.replace(/\/Users\/[^\s"']+|\/Volumes\/[^\s"']+/g, "<local-path>")) : "not-found"
    };
  } catch {
    return { observed: false, status: "host_config_unreadable", fingerprint: "unreadable" };
  }
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
