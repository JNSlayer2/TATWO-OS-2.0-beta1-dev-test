#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const serverPath = path.join(scriptDir, "tatwo-ultrawork-mcp.mjs");
const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-mcp-adversarial-"));
const child = spawn("node", [serverPath], {
  cwd: path.resolve(scriptDir, ".."),
  env: { ...process.env, TATWO_ULTRAWORK_STATE_DIR: stateDir },
  stdio: ["pipe", "pipe", "pipe"]
});

let buffer = Buffer.alloc(0);
let nextID = 1;
const pending = new Map();
let stderr = "";

child.stderr.on("data", chunk => { stderr += chunk.toString("utf8"); });
child.stdout.on("data", chunk => { buffer = Buffer.concat([buffer, chunk]); drain(); });
child.on("exit", code => {
  if (pending.size > 0) fail(`MCP server exited early with ${code}: ${stderr}`);
});

try {
  await request("initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "tatwo-adversarial-smoke", version: "0.1.0" }
  });

  const fakeToken = "sk-" + "abc123456789012345";
  const fakeBearer = "Authorization: " + "Bearer " + "abcdefghijklmnopqrstuvwxyz";
  const unsafe = `Please inspect /Volumes/ExampleData/skills/open-ultrawork/SKILL.md and /Users/example/.codex/auth.json ${fakeToken} ${fakeBearer}`;
  const handoff = await request("tools/call", {
    name: "tatwo_handoff_pack",
    arguments: { mode: "XL", scenario: "coding", objective: unsafe }
  });
  const handoffText = handoff.content?.[0]?.text ?? "";
  assert(handoffText.includes("TatwoHandoffPackV1"), "handoff did not return schema");
  assertNoPrivateMaterial(handoffText, "handoff pack");

  const workflow = await request("tools/call", {
    name: "tatwo_workflow_run",
    arguments: { mode: "XL", scenario: "coding", objective: unsafe }
  });
  const workflowText = workflow.content?.[0]?.text ?? "";
  assert(workflowText.includes("TatwoWorkflowRunPlanV1"), "workflow did not return schema");
  assertNoPrivateMaterial(workflowText, "workflow plan");

  const memory = await request("tools/call", {
    name: "tatwo_memory_add",
    arguments: {
      category: "failure_mode",
        summary: `raw log at /Users/example/.codex/auth.json with ${fakeToken} should be rejected`,
      tags: "raw,auth"
    }
  });
  const memoryText = memory.content?.[0]?.text ?? "";
  assert(memory.isError === true, "unsafe memory must be returned as an MCP tool error");
  assert(memoryText.includes("Unsafe memory rejected") || memoryText.includes("unsafeMemory") || memoryText.includes("unsafe_memory_content"), "unsafe memory should explain fail-closed reason");
  assertNoPrivateMaterial(memoryText, "unsafe memory error");

  const stateFile = path.join(stateDir, "preferences.json");
  if (fs.existsSync(stateFile)) {
    assertNoPrivateMaterial(fs.readFileSync(stateFile, "utf8"), "state file");
  }

  for (const [sampleCase, expectedReason] of [
    ["stdio-fake-host", "mcp_stdio_not_host_registration"],
    ["old-approval-epoch", "approval_epoch_stale_after_model_switch"],
    ["model-text-approval", "model_text_cannot_approve_install"]
  ]) {
    const operational = await request("tools/call", {
      name: "tatwo_validate_operational_sample",
      arguments: { case: sampleCase }
    });
    const text = operational.content?.[0]?.text ?? "";
    assert(operational.isError === true, `${sampleCase} must fail closed`);
    assert(text.includes(expectedReason), `${sampleCase} should include ${expectedReason}`);
    assertNoPrivateMaterial(text, `operational ${sampleCase}`);
  }

  child.kill();
  fs.rmSync(stateDir, { recursive: true, force: true });
  console.log("tatwo_ultrawork_mcp_adversarial_smoke=passed");
} catch (error) {
  child.kill();
  fs.rmSync(stateDir, { recursive: true, force: true });
  fail(error.message);
}

function assertNoPrivateMaterial(text, label) {
  for (const needle of ["/Volumes/", "/Users/", "auth.json", "sk-" + "abc", "Bearer " + "abcdef"]) {
    assert(!text.includes(needle), `${label} leaked ${needle}`);
  }
}

function request(method, params) {
  const id = nextID++;
  const payload = { jsonrpc: "2.0", id, method, params };
  const body = Buffer.from(JSON.stringify(payload), "utf8");
  child.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
  child.stdin.write(body);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`timeout waiting for ${method}`));
    }, 30000);
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

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function fail(message) {
  console.error(`tatwo_ultrawork_mcp_adversarial_smoke=failed ${message}`);
  process.exit(1);
}
