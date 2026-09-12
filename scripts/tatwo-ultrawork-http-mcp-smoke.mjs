#!/usr/bin/env node
import { spawn } from "node:child_process";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const cli = process.env.TATWO_ULTRAWORK_CLI || "swift";
const cliArgsPrefix = process.env.TATWO_ULTRAWORK_CLI
  ? []
  : ["run", "--package-path", ".", "tatwo-ultrawork"];

const port = Number(process.env.TATWO_HTTP_MCP_SMOKE_PORT || randomPort());
const appURL = `http://127.0.0.1:${port}`;
const child = spawn(cli, [...cliArgsPrefix, "mcp", "serve", "--port", String(port), "--json"], {
  cwd: repoRoot,
  stdio: ["ignore", "pipe", "pipe"],
});

let stdout = "";
let stderr = "";
child.stdout.on("data", chunk => { stdout += chunk.toString("utf8"); });
child.stderr.on("data", chunk => { stderr += chunk.toString("utf8"); });

try {
  await waitForHealth(appURL, 30000);

  const health = await getJSON(`${appURL}/health`);
  assert(health.schema === "TatwoMCPHTTPHealthV1", "health schema mismatch");
  assert(health.ok === true, "health not ok");
  assert(health.engineAgnostic === true, "App MCP must be engine agnostic");
  assert(health.defaultHostEngine === "codex", "Codex should be default highest-fit host");
  assert(health.hostMutationAllowed === false, "App MCP must default to read-only host mutation");

  const manifest = await getJSON(`${appURL}/manifest`);
  assert(manifest.schema === "TatwoMCPServerManifestV1", "manifest schema mismatch");
  assert(manifest.engineAgnostic === true, "manifest must be engine agnostic");
  assert(Array.isArray(manifest.transports) && manifest.transports.includes("local-http"), "manifest must expose local-http transport");
  assert(JSON.stringify(manifest).includes("Generic CLI"), "manifest must include generic CLI client path");

  const directCall = await postJSON(`${appURL}/tools/call`, {
    tool: "tatwo.mode.plan",
    arguments: { mode: "XL", scenario: "ui-ux" },
  });
  assert(directCall.schema === "TatwoMCPToolCallResultV1", "tool call schema mismatch");
  assert(directCall.ok === true, "direct HTTP tool call failed");
  assert(directCall.tool === "tatwo.mode.plan", "direct HTTP tool call returned wrong tool");
  assert(directCall.fallbackCoreLibraryUsed === false, "direct HTTP call must not claim core fallback");
  assert(directCall.hostMutationAllowed === false, "direct HTTP tool call must not allow host mutation");
  assert(JSON.stringify(directCall.payload ?? {}).includes("identitySlots"), "mode plan should expose identity slots");

  const cliCall = await runCLI([
    "mcp", "call", "tatwo.mode.plan",
    "--app-url", appURL,
    "--mode", "XL",
    "--scenario", "ui-ux",
    "--json",
  ]);
  assert(cliCall.ok === true, "CLI mcp call envelope not ok");
  assert(cliCall.data?.schema === "TatwoMCPToolCallResultV1", "CLI mcp call result schema mismatch");
  assert(cliCall.data?.fallbackCoreLibraryUsed === false, "CLI must use App MCP when --app-url is reachable");
  assert(cliCall.data?.hostMutationAllowed === false, "CLI App MCP call must not allow host mutation");

  const genericConfig = await runCLI(["mcp", "client-config", "--engine", "generic-cli", "--json"]);
  assert(genericConfig.ok === true, "generic CLI config envelope not ok");
  assert(genericConfig.data?.codexRequired === false, "generic CLI config must not require Codex");
  assert(JSON.stringify(genericConfig.data ?? {}).includes("mcp call"), "generic CLI config should include mcp call usage");

  child.kill("SIGTERM");
  console.log("tatwo_ultrawork_http_mcp_smoke=passed");
} catch (error) {
  child.kill("SIGTERM");
  console.error(`tatwo_ultrawork_http_mcp_smoke=failed ${error.message}`);
  if (stdout.trim()) console.error(`--- server stdout ---\n${stdout.trim()}`);
  if (stderr.trim()) console.error(`--- server stderr ---\n${stderr.trim()}`);
  process.exit(1);
}

function randomPort() {
  return 18000 + Math.floor(Math.random() * 12000);
}

async function waitForHealth(baseURL, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error(`server exited early code=${child.exitCode} stderr=${stderr.trim()}`);
    try {
      const health = await getJSON(`${baseURL}/health`, 1000);
      if (health.ok === true) return;
    } catch (error) {
      lastError = error;
      await sleep(150);
    }
  }
  throw new Error(`health endpoint did not become ready: ${lastError?.message ?? "timeout"}`);
}

function getJSON(url, timeoutMs = 3000) {
  return requestJSON("GET", url, undefined, timeoutMs);
}

function postJSON(url, body, timeoutMs = 3000) {
  return requestJSON("POST", url, body, timeoutMs);
}

function requestJSON(method, url, body, timeoutMs) {
  return new Promise((resolve, reject) => {
    const payload = body ? Buffer.from(JSON.stringify(body), "utf8") : undefined;
    const req = http.request(url, {
      method,
      timeout: timeoutMs,
      headers: payload ? {
        "Content-Type": "application/json",
        "Content-Length": String(payload.length),
      } : undefined,
    }, res => {
      const chunks = [];
      res.on("data", chunk => chunks.push(chunk));
      res.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        if ((res.statusCode ?? 0) < 200 || (res.statusCode ?? 0) >= 300) {
          reject(new Error(`HTTP ${res.statusCode}: ${text}`));
          return;
        }
        try {
          resolve(JSON.parse(text));
        } catch (error) {
          reject(new Error(`bad JSON from ${url}: ${error.message}: ${text.slice(0, 200)}`));
        }
      });
    });
    req.on("timeout", () => req.destroy(new Error(`timeout ${method} ${url}`)));
    req.on("error", reject);
    if (payload) req.write(payload);
    req.end();
  });
}

function runCLI(args, timeoutMs = 30000) {
  return new Promise((resolve, reject) => {
    const proc = spawn(cli, [...cliArgsPrefix, ...args], { cwd: repoRoot, stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    let err = "";
    const timer = setTimeout(() => {
      proc.kill("SIGTERM");
      reject(new Error(`CLI timeout: ${args.join(" ")}`));
    }, timeoutMs);
    proc.stdout.on("data", chunk => { out += chunk.toString("utf8"); });
    proc.stderr.on("data", chunk => { err += chunk.toString("utf8"); });
    proc.on("exit", code => {
      clearTimeout(timer);
      if (code !== 0) {
        reject(new Error(`CLI failed code=${code}: ${args.join(" ")} stderr=${err.trim()} stdout=${out.trim()}`));
        return;
      }
      try {
        resolve(JSON.parse(out));
      } catch (error) {
        reject(new Error(`CLI returned bad JSON: ${error.message}: stdout=${out.trim()} stderr=${err.trim()}`));
      }
    });
  });
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
