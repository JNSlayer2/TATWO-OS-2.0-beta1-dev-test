#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const script = path.join(repoRoot, "scripts", "tatwo-same-thread-evidence.mjs");
const fixture = path.join(
  repoRoot,
  "tests",
  "fixtures",
  "tatwo-same-thread-expected-fail.json",
);
const scriptSource = await fs.readFile(script, "utf8");
assert.match(
  scriptSource,
  /gpt-5\.5,opus-5,sonnet-5,haiku-4-5,gpt-5\.5/,
);
assert.doesNotMatch(scriptSource, /haiku-4-6/);

const expectedFail = await run([
  script,
  "--fixture",
  fixture,
]);

assert.equal(expectedFail.code, 2);
assert.match(expectedFail.stdout, /"classification": "expected-fail"/);
assert.doesNotMatch(expectedFail.stdout, /同一 Codex App thread 的 continuity smoke 通過/);

const unknown = await run([
  script,
  "--fixture",
  path.join(repoRoot, "tests", "fixtures", "missing-same-thread-fixture.json"),
]);

assert.equal(unknown.code, 2);
assert.match(unknown.stdout, /"classification": "unknown"/);

const passFixturePath = path.join(os.tmpdir(), `tatwo-same-thread-pass-${process.pid}.json`);
await fs.writeFile(
  passFixturePath,
  JSON.stringify({
    directModels: [{ model: "fable-5", status: "pass" }],
    sameThread: { status: "pass" },
  }),
);
try {
  const fixtureCannotPass = await run([script, "--fixture", passFixturePath]);
  assert.equal(fixtureCannotPass.code, 2);
  assert.match(fixtureCannotPass.stdout, /"classification": "unknown"/);
} finally {
  await fs.rm(passFixturePath, { force: true });
}

const helperRoot = await fs.mkdtemp(path.join(os.tmpdir(), "tatwo-same-thread-"));
try {
  const helperDir = path.join(helperRoot, "scripts");
  const binDir = path.join(helperRoot, "bin");
  await fs.mkdir(helperDir, { recursive: true });
  await fs.mkdir(binDir, { recursive: true });
  await fs.writeFile(
    path.join(helperDir, "app-server-same-thread-smoke.js"),
    structuredHelperSource("same-thread-legacy-forged"),
  );
  await fs.writeFile(
    path.join(binDir, "codex"),
    '#!/usr/bin/env node\nconsole.log(JSON.stringify({ ok: true, threadId: "legacy", threadProvider: "model_gateway", results: [] }, null, 2));\n',
    { mode: 0o755 },
  );
  const archivedLegacyCannotPass = await run(
    [script, "--run"],
    {
      ...process.env,
      PATH: `${binDir}:${process.env.PATH ?? ""}`,
      MODEL_GATEWAY_DIR: helperRoot,
      TATWO_HOST_SAME_THREAD_SMOKE: "1",
      TATWO_SAME_THREAD_EXPECTED_ROUTES: "gpt-5.5,fable-5,gpt-5.5",
      TATWO_SAME_THREAD_ATTEMPT_TIMEOUT_MS: "300",
    },
  );
  assert.equal(archivedLegacyCannotPass.code, 2);
  assert.match(archivedLegacyCannotPass.stdout, /"classification": "unknown"/);

  await fs.writeFile(
    path.join(binDir, "codex"),
    fakeCodexSource(),
    { mode: 0o755 },
  );
  const structuredCompletion = await run(
    [script, "--run"],
    {
      ...process.env,
      PATH: `${binDir}:${process.env.PATH ?? ""}`,
      TATWO_HOST_SAME_THREAD_SMOKE: "1",
      TATWO_SAME_THREAD_EXPECTED_ROUTES: "gpt-5.5,fable-5,gpt-5.5",
      TATWO_SAME_THREAD_ATTEMPT_TIMEOUT_MS: "1500",
    },
  );
  assert.equal(
    structuredCompletion.code,
    0,
    `${structuredCompletion.stderr}\n${structuredCompletion.stdout}`,
  );
  assert.match(structuredCompletion.stdout, /"classification": "pass"/);
  assert.match(structuredCompletion.stdout, /same-thread-[a-f0-9]{24}/);

  for (const mode of ["fable-fallback", "fable-vendor-evidence-missing"]) {
    const strictRouteFailure = await run(
      [script, "--run"],
      {
        ...process.env,
        PATH: `${binDir}:${process.env.PATH ?? ""}`,
        TATWO_HOST_SAME_THREAD_SMOKE: "1",
        TATWO_SAME_THREAD_EXPECTED_ROUTES: "gpt-5.5,fable-5,gpt-5.5",
        TATWO_SAME_THREAD_ATTEMPT_TIMEOUT_MS: "1500",
        FAKE_CODEX_MODE: mode,
      },
    );
    assert.equal(
      strictRouteFailure.code,
      2,
      `${mode}\n${strictRouteFailure.stderr}\n${strictRouteFailure.stdout}`,
    );
    assert.match(strictRouteFailure.stdout, /"classification": "unknown"/);
    assert.match(strictRouteFailure.stdout, /"authoritativeLiveReceiptVerified": false/);
  }

  await fs.writeFile(
    path.join(binDir, "codex"),
    '#!/usr/bin/env node\nconsole.log(JSON.stringify({ ok: true, threadId: "legacy", threadProvider: "model_gateway", results: [] }, null, 2));\n',
    { mode: 0o755 },
  );
  const prettyLegacyOutput = await run(
    [script, "--run"],
    {
      ...process.env,
      PATH: `${binDir}:${process.env.PATH ?? ""}`,
      TATWO_HOST_SAME_THREAD_SMOKE: "1",
      TATWO_SAME_THREAD_EXPECTED_ROUTES: "gpt-5.5,fable-5,gpt-5.5",
      TATWO_SAME_THREAD_ATTEMPT_TIMEOUT_MS: "300",
    },
  );
  assert.equal(prettyLegacyOutput.code, 2);
  assert.match(prettyLegacyOutput.stdout, /"classification": "unknown"/);
} finally {
  await fs.rm(helperRoot, { recursive: true, force: true });
}

function structuredHelperSource(gatewayReceiptID) {
  return [
    'const nonce = process.env.TATWO_SAME_THREAD_EVIDENCE_NONCE;',
    'const models = process.env.TATWO_SAME_THREAD_EXPECTED_ROUTES.split(",");',
    "console.log(JSON.stringify({",
    '  schema: "TatwoGatewaySameThreadReceiptV1",',
    "  ok: true,",
    '  terminalStatus: "completed",',
    "  testNonce: nonce,",
    `  gatewayReceiptID: ${JSON.stringify(gatewayReceiptID)},`,
    '  appThreadID: "thread-app-1",',
    '  runID: "run-app-1",',
    '  threadProvider: "model_gateway",',
    "  orderedRoutes: models.map((model, index) => ({",
    "    order: index,",
    "    model,",
    '    terminalStatus: "completed",',
    '    responseID: `resp-${index + 1}`,',
    "  })),",
    "}));",
  ].join("\n");
}

function fakeCodexSource() {
  return `#!/usr/bin/env node
let buffer = "";
let contextCode = "CODEX_GATEWAY_CONTEXT_FAKE";
const routes = String(process.env.TATWO_SAME_THREAD_EXPECTED_ROUTES || "").split(",").filter(Boolean);
const mode = process.env.FAKE_CODEX_MODE || "success";
const threadID = "thread-tatwo-helper";
function write(value) { process.stdout.write(JSON.stringify(value) + "\\n"); }
function actualModel(route) {
  if (route === "fable-5") return "claude-fable-5";
  if (route === "opus-5") return "claude-opus-5";
  if (route === "grok-build") return "grok-4.6";
  return route;
}
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => {
  buffer += chunk;
  let newline;
  while ((newline = buffer.indexOf("\\n")) >= 0) {
    const line = buffer.slice(0, newline).trim();
    buffer = buffer.slice(newline + 1);
    if (!line) continue;
    const message = JSON.parse(line);
    if (message.method === "initialize") {
      write({ id: message.id, result: {} });
      continue;
    }
    if (message.method === "thread/start") {
      write({
        id: message.id,
        result: {
          thread: { id: threadID, modelProvider: "model_gateway" },
          modelProvider: "model_gateway",
        },
      });
      continue;
    }
    if (message.method !== "turn/start") continue;
    const index = Number(String(message.id).split("-").at(-1));
    if (message.params?.effort !== null) {
      write({ id: message.id, error: { message: "unexpected_effort" } });
      continue;
    }
    const inputText = message.params?.input?.[0]?.text || "";
    const found = inputText.match(/CODEX_GATEWAY_CONTEXT_[A-Za-z0-9_-]+/);
    if (found) contextCode = found[0];
    const text = index === 0
      ? "OK_GPT_CONTEXT_STORED"
      : index === routes.length - 1
        ? contextCode + "|" + (routes.length - 1)
        : contextCode;
    write({
      method: "response/in_progress",
      params: {
        threadId: threadID,
        heartbeat: true,
        ...(mode === "fable-vendor-evidence-missing" && routes[index] === "fable-5"
          ? {}
          : {
              actual_model:
                mode === "fable-fallback" && routes[index] === "fable-5"
                  ? "claude-opus-5"
                  : actualModel(routes[index]),
            }),
        canonical_model: routes[index],
        selected_route: routes[index],
        fallback_count: 0,
        response_id: "gateway-" + index,
      },
    });
    write({
      method: "item/completed",
      params: {
        threadId: threadID,
        turnId: "turn-" + index,
        item: { type: "agentMessage", id: "agent-" + index, text },
      },
    });
    write({
      method: "turn/completed",
      params: {
        threadId: threadID,
        turn: { id: "turn-" + index, status: "completed", error: null },
      },
    });
  }
});
`;
}

async function run(args, env = process.env) {
  return await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, args, { cwd: repoRoot, env });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", chunk => { stdout += chunk; });
    child.stderr.on("data", chunk => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", code => resolve({ code, stdout, stderr }));
  });
}
