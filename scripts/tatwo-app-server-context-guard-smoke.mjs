#!/usr/bin/env node
"use strict";

import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const timeoutMs = Number(process.env.APP_SERVER_CONTEXT_GUARD_TIMEOUT_MS || 180000);
const model = process.env.APP_SERVER_CONTEXT_GUARD_MODEL || "haiku-4-5";
const kb = Number(process.env.APP_SERVER_CONTEXT_GUARD_KB || 700);
const expected = process.env.APP_SERVER_CONTEXT_GUARD_EXPECT || "context guard";
const sourceHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const tempHome = fs.mkdtempSync(path.join(os.tmpdir(), "codex-context-guard-smoke-"));
const sourceAuth = path.join(sourceHome, "auth.json");
if (fs.existsSync(sourceAuth)) fs.symlinkSync(sourceAuth, path.join(tempHome, "auth.json"));
fs.writeFileSync(
  path.join(tempHome, "config.toml"),
  [
    `model = "${model}"`,
    `model_provider = "model_gateway"`,
    `model_reasoning_effort = "low"`,
    `model_auto_compact_token_limit = 200000`,
    `model_auto_compact_token_limit_scope = "total"`,
    ``,
    `[model_providers.model_gateway]`,
    `name = "Model Gateway"`,
    `base_url = "${process.env.MODEL_GATEWAY_BASE_URL || "http://127.0.0.1:4177/v1"}"`,
    `wire_api = "responses"`,
    `requires_openai_auth = true`,
    ``,
  ].join("\n"),
);

const state = {
  tempHome,
  threadId: null,
  threadProvider: null,
  resultText: null,
  turnCompleted: false,
  stderrImportant: [],
  sawProtocolError: false,
};
let buffer = "";
let nextId = 1;
const child = spawn("codex", ["app-server", "--analytics-default-enabled"], {
  cwd: process.cwd(),
  env: { ...process.env, CODEX_HOME: tempHome },
  stdio: ["pipe", "pipe", "pipe"],
});

const timer = setTimeout(() => fail({ message: "app-server context guard smoke timed out" }), timeoutMs);

function cleanup() {
  clearTimeout(timer);
  child.kill("SIGTERM");
  if (process.env.APP_SERVER_CONTEXT_GUARD_KEEP_HOME !== "1") {
    try {
      fs.rmSync(tempHome, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    } catch (error) {
      state.cleanupError = error.message;
    }
  }
}
function send(method, params, id = `req-${nextId++}`) {
  child.stdin.write(`${JSON.stringify({ id, method, params })}\n`);
}
function notify(method, params) {
  child.stdin.write(`${JSON.stringify({ method, params })}\n`);
}
function fail(error) {
  cleanup();
  console.error(JSON.stringify({ ok: false, error, state }, null, 2));
  process.exitCode = 1;
}
function done() {
  const assertions = {
    thread_provider_model_gateway: state.threadProvider === "model_gateway",
    visible_guard_message: typeof state.resultText === "string" && state.resultText.includes(expected),
    visible_too_large: typeof state.resultText === "string" && /too large|Request size|guard limit/i.test(state.resultText),
    turn_completed_without_protocol_error: state.turnCompleted && !state.sawProtocolError,
    stderr_no_response_failed: !state.stderrImportant.some((line) => /response\.failed|stream disconnected|retrying sampling/i.test(line)),
  };
  cleanup();
  const ok = Object.values(assertions).every(Boolean);
  const payload = { ok, model, kb, threadId: state.threadId, assertions, resultText: state.resultText, stderrImportant: state.stderrImportant };
  console.log(JSON.stringify(payload, null, 2));
  if (!ok) process.exitCode = 1;
}
function compactError(error) {
  if (!error) return null;
  if (typeof error === "string") return error;
  if (error.error?.message) return error.error.message;
  if (error.message) return error.message;
  return JSON.stringify(error).slice(0, 500);
}
function turnParams() {
  return {
    threadId: state.threadId,
    input: [{ type: "text", text: `Trigger model_gateway context guard. Payload follows.\n${"x".repeat(kb * 1024)}`, text_elements: [] }],
    responsesapiClientMetadata: null,
    additionalContext: null,
    environments: null,
    cwd: null,
    runtimeWorkspaceRoots: null,
    approvalPolicy: null,
    approvalsReviewer: null,
    sandboxPolicy: null,
    permissions: null,
    model,
    effort: null,
    summary: null,
    personality: null,
    outputSchema: null,
    collaborationMode: null,
  };
}

child.stderr.setEncoding("utf8");
child.stderr.on("data", (chunk) => {
  for (const line of chunk.split(/\n/).filter(Boolean)) {
    if (/response\.failed|stream disconnected|retrying sampling|model_gateway|ERROR|WARN/.test(line)) {
      state.stderrImportant.push(line.slice(0, 1000));
    }
  }
});
child.stdout.setEncoding("utf8");
child.stdout.on("data", (chunk) => {
  buffer += chunk;
  let newline;
  while ((newline = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, newline).trim();
    buffer = buffer.slice(newline + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { continue; }
    handle(msg);
  }
});
child.on("exit", () => clearTimeout(timer));

function handle(msg) {
  if (msg.id === "init") {
    notify("initialized", {});
    send("thread/start", {
      model,
      modelProvider: "model_gateway",
      cwd: null,
      runtimeWorkspaceRoots: null,
      approvalPolicy: null,
      approvalsReviewer: null,
      sandbox: null,
      permissions: null,
      config: null,
      serviceName: null,
      baseInstructions: null,
      developerInstructions: null,
      personality: null,
      ephemeral: true,
      sessionStartSource: null,
      threadSource: null,
      environments: null,
      dynamicTools: null,
      mockExperimentalField: null,
    }, "thread-start");
    return;
  }
  if (msg.id === "thread-start") {
    state.threadId = msg.result?.thread?.id;
    state.threadProvider = msg.result?.thread?.modelProvider || msg.result?.modelProvider;
    if (!state.threadId || state.threadProvider !== "model_gateway") return fail({ message: "thread/start did not return model_gateway", response: msg });
    send("turn/start", turnParams(), "turn-guard");
    return;
  }
  if (msg.error) {
    state.sawProtocolError = true;
    return fail({ message: compactError(msg), response: msg });
  }
  if (msg.method === "error") {
    state.sawProtocolError = true;
    return fail({ message: compactError(msg.params), response: msg.params });
  }
  if (msg.method === "item/completed" && msg.params?.threadId === state.threadId) {
    const item = msg.params.item;
    if (item?.type === "agentMessage") state.resultText = String(item.text || "").trim();
    return;
  }
  if (msg.method === "turn/completed" && msg.params?.threadId === state.threadId) {
    state.turnCompleted = true;
    if (msg.params?.turn?.error) return fail({ message: compactError(msg.params.turn.error), response: msg.params.turn.error });
    return done();
  }
}

send("initialize", {
  clientInfo: { name: "tatwo-app-server-context-guard-smoke", title: "TATWO App Server Context Guard Smoke", version: "0.1.0" },
  capabilities: { experimentalApi: true, requestAttestation: false, optOutNotificationMethods: [] },
}, "init");
