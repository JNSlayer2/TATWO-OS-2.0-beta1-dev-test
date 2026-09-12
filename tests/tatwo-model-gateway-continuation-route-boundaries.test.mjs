#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const candidateRoot = path.join(
  repoRoot,
  "candidates",
  "model-gateway-continuation-20260803-v1",
);
const serverPath = path.join(candidateRoot, "server.js");
const fixtureRoot = fs.mkdtempSync(
  path.join(os.tmpdir(), `tatwo-model-gateway-continuation-${process.pid}-`),
);
const claudeCapturePath = path.join(fixtureRoot, "claude-capture.json");
const grokCapturePath = path.join(fixtureRoot, "grok-capture.json");
const mockClaudePath = path.join(fixtureRoot, "mock-claude.cjs");
const mockGrokPath = path.join(fixtureRoot, "mock-grok.cjs");

fs.writeFileSync(
  mockClaudePath,
  `#!/usr/bin/env node
"use strict";
const fs = require("node:fs");
const chunks = [];
process.stdin.on("data", (chunk) => chunks.push(chunk));
process.stdin.on("end", () => {
  fs.writeFileSync(${JSON.stringify(claudeCapturePath)}, JSON.stringify({
    argv: process.argv.slice(2),
    stdin: Buffer.concat(chunks).toString("utf8"),
  }));
  const scenario = process.env.MOCK_CLAUDE_SCENARIO || "exact_text";
  const exactStart = {
    type: "stream_event",
    event: {
      type: "message_start",
      message: { model: "claude-fable-5" },
    },
  };
  const exactAssistant = {
    type: "assistant",
    message: {
      model: "claude-fable-5",
      content: [{ type: "text", text: "buffered internal event" }],
    },
  };
  let events;
  if (scenario === "exact_tool") {
    events = [
      exactStart,
      exactAssistant,
      {
        type: "result",
        result: JSON.stringify({
          tool_calls: [{
            type: "function_call",
            name: "shell_exec",
            arguments: { command: "pwd" },
          }],
        }),
        modelUsage: {
          "claude-fable-5": { inputTokens: 12, outputTokens: 5 },
        },
        usage: { input_tokens: 12, output_tokens: 5 },
      },
    ];
  } else if (scenario === "unattested") {
    events = [{ type: "result", result: "UNATTESTED_RESULT" }];
  } else if (scenario === "result_usage_only") {
    events = [{
      type: "result",
      result: "RESULT_USAGE_ATTESTED",
      modelUsage: {
        "claude-fable-5": { inputTokens: 9, outputTokens: 2 },
      },
    }];
  } else if (scenario === "fallback") {
    events = [
      exactStart,
      {
        type: "fallback",
        from: { model: "claude-fable-5" },
        to: { model: "claude-opus-5" },
      },
      {
        type: "assistant",
        message: {
          model: "claude-opus-5",
          content: [{ type: "text", text: "fallback output" }],
        },
      },
      {
        type: "result",
        result: "FALLBACK_RESULT",
        modelUsage: {
          "claude-opus-5": { inputTokens: 10, outputTokens: 4 },
        },
      },
    ];
  } else if (scenario === "raw_tool_without_schema") {
    events = [
      exactStart,
      exactAssistant,
      {
        type: "result",
        result: JSON.stringify({
          tool_calls: [{
            type: "function_call",
            name: "computer_click",
            arguments: { x: 10, y: 20 },
          }],
        }),
        modelUsage: {
          "claude-fable-5": { inputTokens: 8, outputTokens: 3 },
        },
      },
    ];
  } else {
    events = [
      exactStart,
      exactAssistant,
      {
        type: "result",
        result: "EXACT_TEXT",
        modelUsage: {
          "claude-fable-5": { inputTokens: 8, outputTokens: 3 },
        },
      },
    ];
  }
  for (const event of events) process.stdout.write(JSON.stringify(event) + "\\n");
});
`,
  { mode: 0o700 },
);
fs.chmodSync(mockClaudePath, 0o700);

fs.writeFileSync(
  mockGrokPath,
  `#!/usr/bin/env node
"use strict";
const fs = require("node:fs");
const chunks = [];
process.stdin.on("data", (chunk) => chunks.push(chunk));
process.stdin.on("end", () => {
  const prompt = Buffer.concat(chunks).toString("utf8");
  const toolName = prompt.includes("generic_lookup")
    ? "generic_lookup"
    : "shell_exec";
  fs.writeFileSync(${JSON.stringify(grokCapturePath)}, JSON.stringify({
    argv: process.argv.slice(2),
    stdin: prompt,
  }));
  process.stdout.write(JSON.stringify({
    result: JSON.stringify({
      tool_calls: [{
        type: "function_call",
        name: toolName,
        arguments: toolName === "shell_exec"
          ? { command: "pwd" }
          : { query: "current" },
      }],
    }),
    session_id: "mock-grok-session",
    request_id: "mock-grok-request",
  }));
});
`,
  { mode: 0o700 },
);
fs.chmodSync(mockGrokPath, 0o700);

async function unusedPort() {
  const server = http.createServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  await new Promise((resolve) => server.close(resolve));
  return address.port;
}

async function startGateway(extraEnv = {}) {
  const port = await unusedPort();
  const child = spawn(process.execPath, [serverPath], {
    cwd: candidateRoot,
    env: {
      ...process.env,
      MODEL_GATEWAY_HOST: "127.0.0.1",
      MODEL_GATEWAY_PORT: String(port),
      TATWO_OS_CONTEXT: "0",
      GATEWAY_CONTEXT_GUARD: "0",
      GATEWAY_HEARTBEAT_MS: "50",
      CLAUDE_TIMEOUT_MS: "5000",
      GROK_TIMEOUT_MS: "5000",
      CLAUDE_COMMAND: mockClaudePath,
      GROK_COMMAND: mockGrokPath,
      GROK_USE_ISOLATED_HOME: "0",
      GROK_MOCK_SESSION_STATE_JSON: JSON.stringify({
        session_id_sha256: "mock-grok-session-sha256",
        summary_session_id_matches: true,
        request_id_consistent: true,
        summary_current_model_id: "grok-4.6",
        turn_started_model_id: "grok-4.6",
        turn_ended_outcome: "success",
        turn_number: 1,
      }),
      ...extraEnv,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });

  const baseURL = `http://127.0.0.1:${port}`;
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(
        `gateway exited before ready: code=${child.exitCode}\nstdout=${stdout}\nstderr=${stderr}`,
      );
    }
    try {
      const response = await fetch(`${baseURL}/healthz`);
      if (response.ok) {
        return {
          baseURL,
          child,
          logs: () => ({ stdout, stderr }),
        };
      }
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  child.kill("SIGKILL");
  throw new Error(`gateway readiness timeout\nstdout=${stdout}\nstderr=${stderr}`);
}

async function stopGateway(gateway) {
  if (gateway.child.exitCode !== null) return;
  gateway.child.kill("SIGTERM");
  const exited = await Promise.race([
    new Promise((resolve) => gateway.child.once("exit", () => resolve(true))),
    new Promise((resolve) => setTimeout(() => resolve(false), 1500)),
  ]);
  if (!exited) {
    gateway.child.kill("SIGKILL");
    await new Promise((resolve) => gateway.child.once("exit", resolve));
  }
}

async function request(gateway, body) {
  const response = await fetch(`${gateway.baseURL}/v1/responses`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const text = await response.text();
  return { status: response.status, text };
}

function parseSSE(text) {
  return text
    .split(/\r?\n/)
    .filter((line) => line.startsWith("data: "))
    .map((line) => JSON.parse(line.slice(6)));
}

function functionTool(name, description = "Run a shell command") {
  return {
    type: "function",
    name,
    description,
    parameters: {
      type: "object",
      properties: {
        command: { type: "string" },
      },
      required: ["command"],
    },
  };
}

test("focused candidate route boundaries", async (t) => {
  await t.test("buffered Claude tool bridge uses internal stream-json and emits only function_call output", async () => {
    const gateway = await startGateway({
      MOCK_CLAUDE_SCENARIO: "exact_tool",
    });
    try {
      const result = await request(gateway, {
        model: "fable-5",
        stream: true,
        input: "Use the request-scoped shell_exec function to run pwd.",
        tools: [functionTool("shell_exec")],
      });
      assert.equal(result.status, 200, gateway.logs().stderr);
      const events = parseSSE(result.text);
      assert.equal(
        events.some((event) => event.type === "response.output_text.delta"),
        false,
        "buffered tool JSON must not be exposed as UI text deltas",
      );
      const completed = events.find((event) => event.type === "response.completed");
      assert.ok(completed);
      assert.equal(completed.response.output.length, 1);
      assert.equal(completed.response.output[0].type, "function_call");
      assert.equal(completed.response.output[0].name, "shell_exec");
      assert.equal(
        JSON.stringify(completed.response.output).includes('"tool_calls"'),
        false,
      );
      assert.equal(completed.response.model_attestation.exact, true);
      assert.equal(
        completed.response.model_attestation.evidence_source,
        "message_start.message.model",
      );

      const capture = JSON.parse(fs.readFileSync(claudeCapturePath, "utf8"));
      const outputFormatIndex = capture.argv.indexOf("--output-format");
      assert.equal(capture.argv[outputFormatIndex + 1], "stream-json");
      assert.equal(capture.argv.includes("--verbose"), true);
      assert.equal(capture.argv.includes("--include-partial-messages"), false);
      assert.equal(capture.stdin.includes("shell_exec"), true);
    } finally {
      await stopGateway(gateway);
    }
  });

  await t.test("requested Claude model alone cannot attest an otherwise successful result", async () => {
    const gateway = await startGateway({
      MOCK_CLAUDE_SCENARIO: "unattested",
    });
    try {
      const result = await request(gateway, {
        model: "fable-5",
        stream: false,
        input: "Reply with a short answer.",
      });
      assert.equal(result.status, 200, gateway.logs().stderr);
      const body = JSON.parse(result.text);
      assert.equal(body.degraded, true);
      assert.equal(body.error_kind, "model_attestation");
      assert.equal(body.model_attestation.exact, false);
      assert.equal(body.model_attestation.outcome, "ATTESTATION_MISSING");
      assert.equal(body.model_attestation.evidence_source, "missing");
      assert.equal(body.output_text.includes("UNATTESTED_RESULT"), false);
    } finally {
      await stopGateway(gateway);
    }
  });

  await t.test("Claude final result modelUsage is accepted as exact evidence only when uniquely model-bound", async () => {
    const gateway = await startGateway({
      MOCK_CLAUDE_SCENARIO: "result_usage_only",
    });
    try {
      const result = await request(gateway, {
        model: "fable-5",
        stream: false,
        input: "Reply with result evidence.",
      });
      assert.equal(result.status, 200, gateway.logs().stderr);
      const body = JSON.parse(result.text);
      assert.equal(body.output_text, "RESULT_USAGE_ATTESTED");
      assert.equal(body.model_attestation.exact, true);
      assert.equal(
        body.model_attestation.evidence_source,
        "result.modelUsage",
      );
    } finally {
      await stopGateway(gateway);
    }
  });

  await t.test("Claude fallback events fail closed even when the requested model started the turn", async () => {
    const gateway = await startGateway({
      MOCK_CLAUDE_SCENARIO: "fallback",
    });
    try {
      const result = await request(gateway, {
        model: "fable-5",
        stream: false,
        input: "Reply exactly once.",
      });
      assert.equal(result.status, 200, gateway.logs().stderr);
      const body = JSON.parse(result.text);
      assert.equal(body.degraded, true);
      assert.equal(body.model_attestation.exact, false);
      assert.equal(body.model_attestation.outcome, "FAIL_CLOSED_FALLBACK");
      assert.equal(body.model_attestation.fallback_count, 1);
      assert.deepEqual(body.model_attestation.fallback_models, ["claude-opus-5"]);
      assert.equal(body.output_text.includes("FALLBACK_RESULT"), false);
    } finally {
      await stopGateway(gateway);
    }
  });

  await t.test("unconsumed raw tool_calls JSON is never returned as assistant text", async () => {
    const gateway = await startGateway({
      MOCK_CLAUDE_SCENARIO: "raw_tool_without_schema",
    });
    try {
      const result = await request(gateway, {
        model: "fable-5",
        stream: false,
        input: "Explain what would be needed; no tools are exposed.",
      });
      assert.equal(result.status, 200, gateway.logs().stderr);
      const body = JSON.parse(result.text);
      assert.equal(body.degraded, true);
      assert.equal(body.output_text.includes('"tool_calls"'), false);
      assert.match(body.output_text, /gateway-notice/);
    } finally {
      await stopGateway(gateway);
    }
  });

  await t.test("Grok classifies only the current turn and forwards xhigh to the Grok child", async () => {
    const gateway = await startGateway();
    try {
      const result = await request(gateway, {
        model: "grok-build",
        stream: false,
        reasoning: { effort: "xhigh" },
        instructions: "Historical policy mentions computer-use and browser control.",
        input: [
          {
            type: "message",
            role: "user",
            content: [{ type: "input_text", text: "Earlier: use computer-use to click a browser button." }],
          },
          {
            type: "message",
            role: "assistant",
            content: [{ type: "output_text", text: "Historical reply." }],
          },
          {
            type: "message",
            role: "user",
            content: [{
              type: "input_text",
              text: "Current turn: use only the shell_exec request-scoped function to run pwd. Do not use computer-use.",
            }],
          },
        ],
        tools: [functionTool("shell_exec")],
      });
      assert.equal(result.status, 200, `${result.text}\n${gateway.logs().stderr}`);
      const body = JSON.parse(result.text);
      assert.equal(body.output.length, 1);
      assert.equal(body.output[0].type, "function_call");
      assert.equal(body.output[0].name, "shell_exec");
      assert.equal(body.model_attestation.exact, true);
      assert.deepEqual(body.reasoning_control, {
        requested: "xhigh",
        normalized: "xhigh",
        provider: "grok_cli",
        cli_flag: "--reasoning-effort",
        forwarded: true,
        effective_attested: false,
      });

      const capture = JSON.parse(fs.readFileSync(grokCapturePath, "utf8"));
      const effortIndex = capture.argv.indexOf("--reasoning-effort");
      assert.notEqual(effortIndex, -1);
      assert.equal(capture.argv[effortIndex + 1], "xhigh");
      assert.equal(capture.stdin.includes("Current turn:"), true);
    } finally {
      await stopGateway(gateway);
    }
  });

  await t.test("generic request-scoped Grok tools are not misclassified as computer-use", async () => {
    const gateway = await startGateway();
    try {
      const result = await request(gateway, {
        model: "grok-build",
        stream: false,
        input: "Use the generic_lookup request-scoped function for the current record.",
        tools: [{
          type: "function",
          name: "generic_lookup",
          description: "Search a browser-indexed data catalog without operating a GUI",
          parameters: {
            type: "object",
            properties: { query: { type: "string" } },
            required: ["query"],
          },
        }],
      });
      assert.equal(result.status, 200, `${result.text}\n${gateway.logs().stderr}`);
      const body = JSON.parse(result.text);
      assert.equal(body.output[0].type, "function_call");
      assert.equal(body.output[0].name, "generic_lookup");
    } finally {
      await stopGateway(gateway);
    }
  });

  await t.test("true current-turn computer-use without a computer tool fails closed", async () => {
    const gateway = await startGateway();
    try {
      const result = await request(gateway, {
        model: "grok-build",
        stream: false,
        input: "Use computer-use to click the browser submit button.",
        tools: [
          functionTool("shell_exec"),
          {
            type: "function",
            name: "browser_search",
            description: "Search browser-indexed documents; no GUI control",
            parameters: {
              type: "object",
              properties: { query: { type: "string" } },
              required: ["query"],
            },
          },
        ],
      });
      assert.equal(result.status, 424, gateway.logs().stderr);
      const body = JSON.parse(result.text);
      assert.equal(body.error.status, 424);
      assert.match(body.error.message, /did not expose any computer-use tools/);
      assert.match(body.error.message, /blocker_class=tool_unavailable/);
    } finally {
      await stopGateway(gateway);
    }
  });
});
