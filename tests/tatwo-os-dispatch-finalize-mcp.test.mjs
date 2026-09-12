#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const serverScript = path.join(repoRoot, "scripts", "tatwo-ultrawork-mcp.mjs");
const fakeBin = await fs.mkdtemp(path.join(os.tmpdir(), "tatwo-finalize-mcp-bin-"));
const callLog = path.join(fakeBin, "swift-calls.log");
await fs.writeFile(
  path.join(fakeBin, "swift"),
  [
    "#!/bin/sh",
    `printf '%s\\n' "$*" >>${JSON.stringify(callLog)}`,
    `case "$*" in`,
    `  *"os dispatch finalize"*)`,
    `    printf '%s\\n' '{"command":"os dispatch finalize","ok":true,"data":{"status":"awaiting_next_cycle","statusReason":"dispatch_cycle_finalized:2:dispatch-seal-test"}}'`,
    `    exit 0`,
    `    ;;`,
    `  *"os dispatch advance"*)`,
    `    printf '%s\\n' '{"command":"os dispatch advance","ok":true,"data":{"status":"running","statusReason":"dispatch_cycle_opened:3:after:dispatch-seal-test"}}'`,
    `    exit 0`,
    `    ;;`,
    `esac`,
    `echo "unexpected swift args: $*" >&2`,
    `exit 1`,
    "",
  ].join("\n"),
  { mode: 0o755 },
);

const child = spawn(process.execPath, [serverScript], {
  cwd: repoRoot,
  env: {
    ...process.env,
    PATH: `${fakeBin}:${process.env.PATH ?? "/usr/bin:/bin"}`,
    TATWO_MCP_TOOL_TIMEOUT_MS: "10000",
  },
  stdio: ["pipe", "pipe", "pipe"],
});
let id = 1;
let buffer = "";
const pending = new Map();
child.stdout.on("data", chunk => {
  buffer += chunk;
  for (;;) {
    const newline = buffer.indexOf("\n");
    if (newline < 0) break;
    const line = buffer.slice(0, newline).trim();
    buffer = buffer.slice(newline + 1);
    if (!line) continue;
    const message = JSON.parse(line);
    const resolve = pending.get(message.id);
    if (resolve) {
      pending.delete(message.id);
      resolve(message);
    }
  }
});

function call(method, params = {}) {
  return new Promise((resolve, reject) => {
    const requestID = id++;
    pending.set(requestID, resolve);
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: requestID, method, params })}\n`);
    setTimeout(() => {
      if (pending.delete(requestID)) reject(new Error(`timeout: ${method}`));
    }, 15000).unref();
  });
}

try {
  await call("initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "dispatch-finalize-test", version: "1" },
  });
  const listed = await call("tools/list");
  const tool = listed.result.tools.find(item => item.name === "tatwo_os_dispatch_finalize");
  assert.ok(tool, "tatwo_os_dispatch_finalize must be registered");
  assert.deepEqual(tool.inputSchema.required, ["contractID"]);
  const advanceTool = listed.result.tools.find(item => item.name === "tatwo_os_dispatch_advance");
  assert.ok(advanceTool, "tatwo_os_dispatch_advance must be registered");
  assert.deepEqual(advanceTool.inputSchema.required, ["contractID", "expectedSealID"]);

  const response = await call("tools/call", {
    name: "tatwo_os_dispatch_finalize",
    arguments: { contractID: "contract-xl-coding-test" },
  });
  assert.equal(response.result.isError, false);
  assert.match(response.result.content[0].text, /awaiting_next_cycle/);
  assert.match(response.result.content[0].text, /dispatch_cycle_finalized/);

  const advanceResponse = await call("tools/call", {
    name: "tatwo_os_dispatch_advance",
    arguments: {
      contractID: "contract-xl-coding-test",
      expectedSealID: "dispatch-seal-test",
    },
  });
  assert.equal(advanceResponse.result.isError, false);
  assert.match(advanceResponse.result.content[0].text, /dispatch_cycle_opened:3/);

  const calls = await fs.readFile(callLog, "utf8");
  assert.match(calls, /os dispatch finalize --json --contract contract-xl-coding-test/);
  assert.match(
    calls,
    /os dispatch advance --json --contract contract-xl-coding-test --expected-seal dispatch-seal-test/,
  );
} finally {
  child.kill("SIGTERM");
  await fs.rm(fakeBin, { recursive: true, force: true });
}

console.log("tatwo-os-dispatch-finalize-mcp.test.mjs: ok");
