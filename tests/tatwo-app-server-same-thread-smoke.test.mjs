#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const helper = path.join(repoRoot, "scripts", "tatwo-app-server-same-thread-smoke.mjs");
const highIntensityFixture = path.join(
  repoRoot,
  "tests",
  "fixtures",
  "tatwo-high-intensity-24turns.json",
);
const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "tatwo-app-server-same-thread-"));
const binDir = path.join(tempRoot, "bin");
const fakeCodex = path.join(binDir, "codex");
const turns = [
  {
    model: "gpt-5.6-sol",
    effort: "low",
    speedTier: "fast",
    expectedActualModel: "gpt-5.6-sol",
    minHeartbeatCount: 1,
  },
  {
    model: "fable-5",
    effort: null,
    speedTier: null,
    expectedActualModel: "claude-fable-5",
    minHeartbeatCount: 1,
  },
  {
    model: "grok-build",
    effort: "xhigh",
    speedTier: null,
    expectedActualModel: "grok-4.6",
    minHeartbeatCount: 1,
  },
  {
    model: "gpt-5.6-sol",
    effort: "low",
    speedTier: "fast",
    expectedActualModel: "gpt-5.6-sol",
    minHeartbeatCount: 1,
  },
];
const routes = turns.map(turn => turn.model);
const nonce = "nonce-host-owned-1";
const runID = "11111111-2222-4333-8444-555555555555";
const expectedContract = {
  contractID: "contract-test-same-thread-v2",
  goalID: "goal-test-same-thread-v2",
  contractRevision: "revision-7",
  instanceID: "instance-test-same-thread-v2",
};

try {
  const helperSource = await fs.readFile(helper, "utf8");
  assert.match(
    helperSource,
    /gpt-5\.6-sol,fable-5,gpt-5\.6-luna,grok-build,opus-5,gpt-5\.6-sol/,
  );
  assert.doesNotMatch(helperSource, /haiku-4-6/);

  await fs.mkdir(binDir, { recursive: true });
  await fs.writeFile(fakeCodex, fakeCodexSource(), { mode: 0o755 });

  const success = await runHelper("success");
  assert.equal(success.code, 0, success.stderr);
  const successLines = success.stdout.trim().split(/\n+/).filter(Boolean);
  assert.equal(successLines.length, 1, "success must emit exactly one JSON line");
  const receipt = JSON.parse(successLines[0]);
  assert.equal(receipt.schema, "TatwoGatewaySameThreadReceiptV1");
  assert.equal(receipt.ok, true);
  assert.equal(receipt.terminalStatus, "completed");
  assert.equal(receipt.testNonce, nonce);
  assert.equal(receipt.runID, runID);
  assert.equal(receipt.threadProvider, "model_gateway");
  assert.match(receipt.gatewayReceiptID, /^same-thread-[a-f0-9]{24}$/);
  assert.equal(receipt.receiptVersion, 2);
  assert.match(receipt.sameThreadReceiptID, /^same-thread-v2-[a-f0-9]{24}$/);
  assert.deepEqual(
    receipt.orderedRoutes.map(route => route.model),
    routes,
  );
  assert.deepEqual(
    receipt.orderedRoutes.map(route => route.order),
    turns.map((_, index) => index),
  );
  assert.ok(receipt.orderedRoutes.every(route => route.terminalStatus === "completed"));
  assert.deepEqual(
    receipt.orderedTurns.map(turn => turn.requestedEffort),
    turns.map(turn => turn.effort),
  );
  assert.deepEqual(
    receipt.orderedTurns.map(turn => turn.requestedSpeedTier),
    turns.map(turn => turn.speedTier),
  );
  assert.ok(receipt.orderedTurns.every(turn => turn.contextContinuityVerified));
  assert.deepEqual(
    receipt.orderedTurns.map(turn => turn.forwardingEvidence),
    [
      "gateway_receipt",
      "not_requested_and_not_observed",
      "gateway_receipt",
      "gateway_receipt",
    ],
  );
  assert.ok(receipt.orderedTurns.every(turn => turn.forwardedEffort === turn.requestedEffort));
  assert.ok(receipt.orderedTurns.every(turn => turn.actualVendorModel));
  assert.deepEqual(
    receipt.orderedTurns.map(turn => turn.expectedActualModel),
    turns.map(turn => turn.expectedActualModel),
  );
  assert.ok(receipt.orderedTurns.every(turn => turn.fallbackCount === 0));
  assert.ok(receipt.orderedTurns.every(turn => turn.gatewayResponseID));
  assert.ok(receipt.orderedTurns.every(turn => turn.assistantItemID));
  assert.ok(receipt.orderedTurns.every(turn => turn.terminalTurnID === turn.turnID));
  assert.ok(receipt.orderedTurns.every(turn => turn.runID === runID));
  assert.ok(receipt.orderedTurns.every(turn => turn.attempt === 1));
  assert.ok(receipt.orderedTurns.every(turn => turn.canonicalModel));
  assert.ok(receipt.orderedTurns.every(turn => turn.vendorModel));
  assert.ok(receipt.orderedTurns.every(turn => turn.heartbeatCount === 1));
  assert.ok(receipt.orderedTurns.every(turn => turn.processConfiguredSpeedTier === "fast"));
  assert.ok(receipt.orderedTurns.every(turn => turn.outputUTF8Bytes >= turn.minimumOutputBytes));
  const responseIDs = receipt.orderedRoutes.map(route => route.responseID);
  assert.ok(responseIDs.every(value => typeof value === "string" && value.length > 0));
  assert.equal(new Set(responseIDs).size, responseIDs.length);

  const requiredTextOnlyTurns = [
    {
      model: "gpt-5.6-sol",
      effort: "low",
      speedTier: "fast",
      expectedActualModel: "gpt-5.6-sol",
      expect: null,
      requiredText: ["LONG_OFFICE_MARKER"],
      minOutputBytes: 18,
      minHeartbeatCount: 1,
    },
    {
      model: "gpt-5.6-sol",
      effort: "low",
      speedTier: "fast",
      expectedActualModel: "gpt-5.6-sol",
      minHeartbeatCount: 1,
    },
  ];
  const requiredTextOnly = await runHelper("custom-required-text", {
    TATWO_SAME_THREAD_EXPECTED_ROUTES:
      requiredTextOnlyTurns.map(turn => turn.model).join(","),
    TATWO_SAME_THREAD_EXPECTED_TURNS_JSON:
      JSON.stringify(requiredTextOnlyTurns),
  });
  assert.equal(requiredTextOnly.code, 0, requiredTextOnly.stderr);
  const requiredTextOnlyReceipt = JSON.parse(requiredTextOnly.stdout.trim());
  assert.equal(requiredTextOnlyReceipt.ok, true);
  assert.equal(
    requiredTextOnlyReceipt.orderedTurns[0].outputUTF8Bytes >= 18,
    true,
  );

  const largePrompt = "LONG_CONTEXT_PAYLOAD_".repeat(32_768);
  const largePromptPath = path.join(tempRoot, "long-context.txt");
  const largeTurnsPath = path.join(tempRoot, "turns-from-file.json");
  await fs.writeFile(largePromptPath, largePrompt, "utf8");
  await fs.writeFile(
    largeTurnsPath,
    JSON.stringify({
      schema: "TatwoSameThreadTurnPlanV1",
      turns: [
        { model: "fable-5", promptFile: "long-context.txt", minHeartbeatCount: 1 },
        { model: "fable-5", minHeartbeatCount: 1 },
      ],
    }),
    "utf8",
  );
  const largePromptFromFile = await runHelper("check-large-prompt-file", {
    TATWO_SAME_THREAD_EXPECTED_ROUTES: "fable-5,fable-5",
    TATWO_SAME_THREAD_EXPECTED_TURNS_JSON: "",
    TATWO_SAME_THREAD_EXPECTED_TURNS_FILE: largeTurnsPath,
  });
  assert.equal(largePromptFromFile.code, 0, largePromptFromFile.stderr);
  const largePromptReceipt = JSON.parse(largePromptFromFile.stdout.trim());
  assert.equal(largePromptReceipt.orderedTurns[0].promptSource, "file");
  assert.equal(
    largePromptReceipt.orderedTurns[0].promptUTF8Bytes,
    Buffer.byteLength(largePrompt, "utf8"),
  );

  const highIntensityPlan = JSON.parse(
    await fs.readFile(highIntensityFixture, "utf8"),
  );
  assert.equal(highIntensityPlan.turns.length, 24);
  const highIntensity = await runHelper("success", {
    TATWO_SAME_THREAD_EXPECTED_ROUTES:
      highIntensityPlan.turns.map(turn => turn.model).join(","),
    TATWO_SAME_THREAD_EXPECTED_TURNS_JSON: "",
    TATWO_SAME_THREAD_EXPECTED_TURNS_FILE: highIntensityFixture,
    TATWO_SAME_THREAD_REQUIRE_CONTRACT_CONTINUITY: "1",
  });
  assert.equal(highIntensity.code, 0, highIntensity.stderr);
  const highIntensityReceipt = JSON.parse(highIntensity.stdout.trim());
  assert.equal(highIntensityReceipt.receiptVersion, 2);
  assert.equal(highIntensityReceipt.orderedTurns.length, 24);
  assert.ok(highIntensityReceipt.orderedTurns.every(
    turn => turn.contractID === highIntensityPlan.contract.contractID,
  ));
  assert.ok(highIntensityReceipt.orderedTurns.every(
    turn => turn.goalID === highIntensityPlan.contract.goalID,
  ));
  assert.ok(highIntensityReceipt.orderedTurns.every(
    turn => turn.contractRevision === highIntensityPlan.contract.contractRevision,
  ));
  assert.ok(highIntensityReceipt.orderedTurns.every(
    turn => turn.instanceID === highIntensityPlan.contract.instanceID,
  ));
  assert.equal(
    new Set(highIntensityReceipt.orderedTurns.map(turn => turn.assistantItemID)).size,
    24,
  );
  assert.equal(
    new Set(highIntensityReceipt.orderedTurns.map(turn => turn.gatewayResponseID)).size,
    24,
  );
  assert.equal(
    new Set(highIntensityReceipt.orderedTurns.map(turn => turn.terminalTurnID)).size,
    24,
  );
  assert.ok(highIntensityReceipt.orderedTurns.every(
    turn => turn.contextContinuityVerified,
  ));
  const churn = await runHelper("contract-churn", {
    TATWO_SAME_THREAD_EXPECTED_ROUTES:
      highIntensityPlan.turns.map(turn => turn.model).join(","),
    TATWO_SAME_THREAD_EXPECTED_TURNS_JSON: "",
    TATWO_SAME_THREAD_EXPECTED_TURNS_FILE: highIntensityFixture,
    TATWO_SAME_THREAD_REQUIRE_CONTRACT_CONTINUITY: "1",
  });
  assert.notEqual(churn.code, 0, "contract churn must fail closed");
  assert.equal(churn.stdout.trim(), "");
  const missingContractAttestation = await runHelper(
    "missing-contract-attestation",
    {
      TATWO_SAME_THREAD_EXPECTED_ROUTES:
        highIntensityPlan.turns.map(turn => turn.model).join(","),
      TATWO_SAME_THREAD_EXPECTED_TURNS_JSON: "",
      TATWO_SAME_THREAD_EXPECTED_TURNS_FILE: highIntensityFixture,
      TATWO_SAME_THREAD_REQUIRE_CONTRACT_CONTINUITY: "1",
    },
  );
  assert.notEqual(
    missingContractAttestation.code,
    0,
    "missing contract identity must fail closed",
  );
  assert.equal(missingContractAttestation.stdout.trim(), "");

  for (const mode of [
    "duplicate-id",
    "missing-id",
    "thread-switch",
    "incomplete-turn",
    "missing-actual-model",
    "actual-model-mismatch",
    "nonzero-fallback",
    "duplicate-turn-id",
    "nil-effort-leak",
    "missing-gateway-response-id",
  ]) {
    const failed = await runHelper(mode);
    assert.notEqual(failed.code, 0, `${mode} must fail closed`);
    assert.equal(failed.stdout.trim(), "", `${mode} must emit no V1 receipt`);
  }

  const retryCounter = path.join(tempRoot, "retry-counter.txt");
  const retry = await runHelper("first-timeout", {
    FAKE_CODEX_COUNTER_FILE: retryCounter,
  });
  assert.equal(retry.code, 0, retry.stderr);
  assert.equal((await fs.readFile(retryCounter, "utf8")).trim(), "2");
  const retryLines = retry.stdout.trim().split(/\n+/).filter(Boolean);
  assert.equal(retryLines.length, 1, "timeout retry must still emit one receipt");
  const retryReceipt = JSON.parse(retryLines[0]);
  assert.equal(retryReceipt.runID, runID);
  assert.match(retryReceipt.appThreadID, /^thread-attempt-2$/);
  assert.ok(
    retryReceipt.orderedRoutes.every(route => route.responseID.includes("attempt-2")),
    "receipt must contain only the successful retry attempt",
  );

  const timeoutCounter = path.join(tempRoot, "timeout-counter.txt");
  const timeout = await runHelper("always-timeout", {
    FAKE_CODEX_COUNTER_FILE: timeoutCounter,
  });
  assert.notEqual(timeout.code, 0);
  assert.equal(timeout.stdout.trim(), "");
  assert.equal((await fs.readFile(timeoutCounter, "utf8")).trim(), "2");
} finally {
  await fs.rm(tempRoot, { recursive: true, force: true });
}

async function runHelper(mode, extraEnv = {}) {
  return await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [helper], {
      cwd: repoRoot,
      env: {
        ...process.env,
        PATH: `${binDir}:${process.env.PATH ?? ""}`,
        TATWO_SAME_THREAD_EVIDENCE_NONCE: nonce,
        TATWO_SAME_THREAD_RUN_ID: runID,
        TATWO_SAME_THREAD_EXPECTED_ROUTES: routes.join(","),
        TATWO_SAME_THREAD_EXPECTED_TURNS_JSON: JSON.stringify(turns),
        TATWO_SAME_THREAD_REQUIRE_FORWARDING_EVIDENCE: "1",
        // This test launches several fake app-server processes in sequence. Keep the
        // intentional timeout cases short, but leave enough headroom for a full test
        // suite running in parallel on a busy developer Mac.
        TATWO_SAME_THREAD_ATTEMPT_TIMEOUT_MS: mode.includes("timeout") ? "10000" : "15000",
        TATWO_SAME_THREAD_MAX_ATTEMPTS: "2",
        FAKE_CODEX_MODE: mode,
        ...extraEnv,
      },
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", chunk => { stdout += chunk; });
    child.stderr.on("data", chunk => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", code => resolve({ code, stdout, stderr }));
  });
}

function fakeCodexSource() {
  return `#!/usr/bin/env node
const fs = require("node:fs");
const mode = process.env.FAKE_CODEX_MODE || "success";
const routes = String(process.env.TATWO_SAME_THREAD_EXPECTED_ROUTES || "").split(",").filter(Boolean);
const expectedTurnsDocument = process.env.TATWO_SAME_THREAD_EXPECTED_TURNS_JSON
  ? JSON.parse(process.env.TATWO_SAME_THREAD_EXPECTED_TURNS_JSON)
  : process.env.TATWO_SAME_THREAD_EXPECTED_TURNS_FILE
    ? JSON.parse(fs.readFileSync(process.env.TATWO_SAME_THREAD_EXPECTED_TURNS_FILE, "utf8"))
    : ${JSON.stringify(turns)};
const expectedTurns = Array.isArray(expectedTurnsDocument)
  ? expectedTurnsDocument
  : expectedTurnsDocument.turns;
const contract = expectedTurnsDocument.contract || ${JSON.stringify(expectedContract)};
const counterFile = process.env.FAKE_CODEX_COUNTER_FILE;
let attempt = 1;
if (counterFile) {
  try { attempt = Number(fs.readFileSync(counterFile, "utf8")) + 1; } catch {}
  fs.writeFileSync(counterFile, String(attempt));
}
let buffer = "";
let contextCode = "CODEX_GATEWAY_CONTEXT_" +
  String(process.env.TATWO_SAME_THREAD_RUN_ID || "FAKE").replace(/-/g, "");
const threadID = "thread-attempt-" + attempt;
function write(value) { process.stdout.write(JSON.stringify(value) + "\\n"); }
function expectedEffort(turn) {
  if (Object.prototype.hasOwnProperty.call(turn, "effort")) return turn.effort;
  if (turn.model === "gpt-5.6-sol") return "low";
  if (turn.model === "gpt-5.6-luna" || turn.model === "grok-build") return "xhigh";
  if (turn.model === "opus-5") return "high";
  return null;
}
function expectedVendorModel(turn) {
  if (turn.expectedActualModel) return turn.expectedActualModel;
  if (turn.model === "fable-5") return "claude-fable-5";
  if (turn.model === "opus-5") return "claude-opus-5";
  if (turn.model === "grok-build") return "grok-4.6";
  return turn.model;
}
function expectedCanonicalModel(turn) {
  if (turn.expectedCanonicalModel) return turn.expectedCanonicalModel;
  return turn.model;
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
    const expectedTurn = expectedTurns[index];
    if (message.params?.effort !== expectedEffort(expectedTurn)) {
      write({ id: message.id, error: { message: "effort_not_forwarded_to_app_server" } });
      continue;
    }
    const inputText = message.params?.input?.[0]?.text || "";
    const found = inputText.match(/CODEX_GATEWAY_CONTEXT_[A-Za-z0-9_-]{10,}/);
    if (found) contextCode = found[0];
    if (
      mode === "check-large-prompt-file"
      && index === 0
      && Buffer.byteLength(inputText, "utf8") < 512000
    ) {
      write({ id: message.id, error: { message: "large_prompt_not_read_from_file" } });
      continue;
    }
    if (mode === "always-timeout" || (mode === "first-timeout" && attempt === 1)) {
      continue;
    }
    const eventThreadID = mode === "thread-switch" && index === 1
      ? "thread-switched"
      : threadID;
    const responseID = mode === "duplicate-id"
      ? "agent-attempt-" + attempt + "-duplicate"
      : "agent-attempt-" + attempt + "-" + index;
    const text = mode === "custom-required-text" && index === 0
      ? "LONG_OFFICE_MARKER with sustained office-task output"
      : index === 0
        ? "OK_GPT_CONTEXT_STORED"
        : index === routes.length - 1
          ? contextCode + "|" + (routes.length - 1)
          : contextCode;
    const normalForwardedEffort = expectedEffort(expectedTurn);
    const forwardedEffort =
      mode === "nil-effort-leak" && expectedTurn.model === "fable-5"
        ? "high"
        : normalForwardedEffort;
    const actualModel =
      mode === "actual-model-mismatch" && index === 1
        ? "claude-opus-5"
        : expectedVendorModel(expectedTurn);
    const turnID =
      mode === "duplicate-turn-id" && index === 1
        ? "turn-attempt-" + attempt + "-0"
        : "turn-attempt-" + attempt + "-" + index;
    write({
      method: "response/in_progress",
      params: {
        threadId: eventThreadID,
        heartbeat: true,
        reasoning: {
          normalized: forwardedEffort,
          forwardedNativeField: Boolean(forwardedEffort),
        },
        ...(mode === "missing-actual-model" && index === 1
          ? {}
          : { actual_model: actualModel }),
        canonical_model: expectedCanonicalModel(expectedTurn),
        selected_route: expectedTurn.model,
        ...(mode === "missing-contract-attestation" && index === 1
          ? {}
          : {
              contract_id: contract.contractID,
              goal_id: contract.goalID,
              contract_revision:
                mode === "contract-churn" && index === 12
                  ? contract.contractRevision + "-churn"
                  : contract.contractRevision,
              instance_id: contract.instanceID,
            }),
        fallback_count:
          mode === "nonzero-fallback" && index === 1
            ? 1
            : 0,
        ...(mode === "missing-gateway-response-id" && index === 1
          ? {}
          : { response_id: "gateway-response-attempt-" + attempt + "-" + index }),
      },
    });
    write({
      method: "item/completed",
      params: {
        threadId: eventThreadID,
        turnId: turnID,
        item: {
          type: "agentMessage",
          ...(mode === "missing-id" && index === 1 ? {} : { id: responseID }),
          text,
        },
      },
    });
    write({
      method: "turn/completed",
      params: {
        threadId: eventThreadID,
        turn: {
          id: turnID,
          status: mode === "incomplete-turn" && index === 1 ? "incomplete" : "completed",
          error: null,
        },
      },
    });
  }
});
`;
}
