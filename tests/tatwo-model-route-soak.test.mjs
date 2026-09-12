#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const harness = path.join(repoRoot, "scripts", "tatwo-model-route-soak.mjs");
const sameThreadEvidence = path.join(repoRoot, "scripts", "tatwo-same-thread-evidence.mjs");
const chatRuntimeSmoke = path.join(repoRoot, "scripts", "tatwo-chat-runtime-smoke.mjs");
const currentRouteProfilesSource = path.join(
  repoRoot,
  "Packages",
  "TatwoUltraworkCore",
  "Sources",
  "TatwoUltraworkCore",
  "TatwoChatRouteProfile.swift",
);
const fullRouteProfiles = [
  "gpt-5.6-sol",
  "gpt-5.6-terra",
  "gpt-5.6-luna",
  "minimax-m3",
  "grok-build",
  "fable5",
  "haiku4.5",
  "sonnet5",
  "opus5",
  "codex-auto-review",
  "gpt-5.4",
];
const expectedProfileContracts = new Map([
  ["gpt-5.5", profileContract("gpt-5.5", "gpt-5.5", "codex-exec")],
  ["gpt-5.6-sol", profileContract("gpt-5.6-sol", "gpt-5.6-sol", "codex-exec")],
  ["gpt-5.6-terra", profileContract("gpt-5.6-terra", "gpt-5.6-terra", "codex-exec")],
  ["gpt-5.6-luna", profileContract("gpt-5.6-luna", "gpt-5.6-luna", "codex-exec")],
  ["minimax-m3", profileContract("minimax-m3", "minimax-m3", "gateway-direct")],
  ["grok-build", profileContract("grok-build", "grok-build", "gateway-direct")],
  ["fable5", profileContract("fable-5", "fable-5", "gateway-direct")],
  ["haiku4.5", profileContract("haiku-4-5", "haiku-4-5", "gateway-direct")],
  ["sonnet5", profileContract("sonnet-5", "sonnet-5", "gateway-direct")],
  ["opus5", profileContract("opus-5", "opus", "gateway-direct")],
  ["codex-auto-review", profileContract("gpt-5.5", "gpt-5.5", "codex-exec")],
  ["gpt-5.4", profileContract("gpt-5.4", "gpt-5.4", "codex-exec")],
]);
const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "tatwo-model-route-soak-"));
const fakeGatewayAdapter = path.join(tempRoot, "fake-gateway-adapter.mjs");
const fakeCodex = path.join(tempRoot, "fake-codex.mjs");

try {
  await fs.writeFile(fakeGatewayAdapter, fakeGatewayAdapterSource(), { mode: 0o755 });
  await fs.writeFile(fakeCodex, fakeCodexSource(), { mode: 0o755 });

  await testConfirmationGate();
  await testFullMatrixSuccessAndReceiptVerification();
  await testTimeoutDisconnectDuplicateAndAttestationAccounting();
  await testReceiptTamperFailsVerification();
  await testRouteDefaultAndFableAdapterSourceContracts();
} finally {
  await fs.rm(tempRoot, { recursive: true, force: true });
}

async function testConfirmationGate() {
  const result = await runHarness([
    "--run",
    "--run-id", "confirmation-gate",
    "--receipt", path.join(tempRoot, "confirmation-gate.json"),
  ], {
    TATWO_MODEL_ROUTE_SOAK: "0",
  });
  assert.equal(result.code, 2);
  const plan = JSON.parse(result.stdout);
  assert.equal(plan.schema, "TatwoModelRouteSoakPlanV1");
  assert.equal(plan.liveExecutionPerformed, false);
  assert.deepEqual(plan.blockedBy, ["TATWO_MODEL_ROUTE_SOAK_confirmation_missing"]);
  assert.equal(plan.expectedTurnCount, 45);
}

async function testFullMatrixSuccessAndReceiptVerification() {
  const receiptPath = path.join(tempRoot, "success-receipt.json");
  const invocationLog = path.join(tempRoot, "success-invocations.jsonl");
  const result = await runHarness([
    "--run",
    "--run-id", "full-matrix-success",
    "--receipt", receiptPath,
    "--rounds", "2",
    "--min-output-bytes", "512",
    // Full repository Node tests start many fixture subprocesses concurrently.
    // Keep the positive matrix above scheduler pressure; the separate negative
    // matrix still proves timeout accounting with a synthetic 10-second hang.
    "--timeout-ms", "10000",
  ], { FAKE_INVOCATION_LOG: invocationLog });
  assert.equal(result.code, 0, `${result.stderr}\n${result.stdout}`);
  const receipt = JSON.parse(result.stdout);
  assert.equal(receipt.schema, "TatwoModelRouteSoakReceiptV1");
  assert.equal(receipt.passed, true);
  assert.equal(receipt.matrixCoverage, "FULL_CANONICAL_MATRIX");
  assert.deepEqual(receipt.routes, fullRouteProfiles);
  assert.deepEqual(
    receipt.routeProfiles.map(profile => profile.id),
    fullRouteProfiles,
  );
  assert.deepEqual(
    receipt.routeProfiles.map(profile => ({
      id: profile.id,
      canonicalModelSlug: profile.canonicalModelSlug,
      modelArgument: profile.modelArgument,
      invocationModelArgument: profile.invocationModelArgument,
      adapter: profile.adapter,
    })),
    fullRouteProfiles.map(profileID => ({
      id: profileID,
      ...expectedProfileContracts.get(profileID),
    })),
  );
  assert.deepEqual(
    {
      id: receipt.baselineProfile.id,
      canonicalModelSlug: receipt.baselineProfile.canonicalModelSlug,
      modelArgument: receipt.baselineProfile.modelArgument,
      invocationModelArgument: receipt.baselineProfile.invocationModelArgument,
      adapter: receipt.baselineProfile.adapter,
    },
    {
      id: "gpt-5.5",
      ...expectedProfileContracts.get("gpt-5.5"),
    },
  );
  assert.equal(receipt.baselineCanonicalModel, "gpt-5.5");
  assert.equal(receipt.baselineInvocationModelArgument, "gpt-5.5");
  assert.equal(receipt.expectedTurnCount, 45);
  assert.equal(receipt.expectedBaselineReturnCount, 22);
  assert.equal(receipt.summary.observedTurnCount, 45);
  assert.equal(receipt.summary.passedTurnCount, 45);
  assert.equal(receipt.summary.baselineReturnCount, 22);
  assert.equal(receipt.summary.baselineReturnFailureCount, 0);
  assert.equal(receipt.summary.timeoutCount, 0);
  assert.equal(receipt.summary.disconnectCount, 0);
  assert.equal(receipt.summary.duplicateAssistantMessageCount, 0);
  assert.equal(receipt.summary.duplicateCompletionCount, 0);
  assert.equal(receipt.summary.duplicateMarkerCount, 0);
  assert.equal(receipt.summary.duplicateExecutionIDCount, 0);
  assert.equal(receipt.summary.duplicateResponseIDCount, 0);
  assert.equal(receipt.summary.duplicateCodexThreadIDCount, 0);
  assert.equal(receipt.summary.duplicateAssistantItemIDCount, 0);
  assert.equal(receipt.summary.attestationFailureCount, 0);
  assert.equal(receipt.summary.gatewayExactAttestationRequiredCount, 12);
  assert.equal(receipt.summary.gatewayExactAttestationVerifiedCount, 12);
  assert.equal(receipt.summary.gatewayExactAttestationFailureCount, 0);
  assert.equal(receipt.summary.codexHostRouteRequestProofRequiredCount, 33);
  assert.equal(receipt.summary.codexHostRouteRequestProofVerifiedCount, 33);
  assert.equal(receipt.summary.codexHostRouteRequestProofFailureCount, 0);
  assert.equal(receipt.summary.providerExactModelUnattestedCodexTurnCount, 33);
  assert.equal(receipt.summary.routeProfileControlFailureCount, 0);
  assert.equal(receipt.summary.undersizedOutputCount, 0);
  assert.ok(receipt.summary.outputBytesMinimum >= 512);
  assert.match(receipt.receiptID, /^route-soak-[a-f0-9]{24}$/);
  assert.equal(receipt.receiptID, receipt.attemptReceiptID);
  assert.ok(receipt.turns
    .filter(turn => turn.adapter === "gateway-direct")
    .every(turn => turn.exactModelAttestation === true));
  assert.ok(receipt.turns
    .filter(turn => turn.adapter === "codex-exec")
    .every(turn =>
      turn.exactModelAttestation === null
      && turn.providerExactModelAttested === false
      && turn.attestationOutcome === "PROVIDER_ATTESTATION_NOT_AVAILABLE"));
  assert.ok(receipt.turns.every(turn => turn.controlsMatched));
  assert.ok(receipt.turns.every(turn => turn.markerMatchedExactlyOnce));
  assert.ok(receipt.turns.every(turn => turn.executionIDHash?.length === 64));
  assert.ok(receipt.turns.every(turn => !("assistantText" in turn)));
  assert.ok(receipt.turns.every(turn => !("responseID" in turn)));

  const phases = receipt.turns.map(turn => turn.phase);
  assert.equal(phases[0], "initial_baseline");
  for (let index = 1; index < receipt.turns.length; index += 2) {
    assert.equal(receipt.turns[index].phase, "route");
    assert.equal(receipt.turns[index + 1].phase, "baseline_return");
    assert.equal(receipt.turns[index + 1].canonicalExpectedModel, "gpt-5.5");
    assert.equal(receipt.turns[index + 1].profileModelArgument, "gpt-5.5");
    assert.equal(receipt.turns[index + 1].invocationModelArgument, "gpt-5.5");
    assert.equal(
      receipt.turns[index + 1].baselineAfterProfileID,
      receipt.turns[index].routeProfileID,
    );
  }
  const autoReviewTurns = receipt.turns.filter(
    turn => turn.routeProfileID === "codex-auto-review",
  );
  assert.equal(autoReviewTurns.length, 2);
  assert.ok(autoReviewTurns.every(turn => turn.canonicalExpectedModel === "gpt-5.5"));
  assert.ok(autoReviewTurns.every(turn => turn.profileModelArgument === "gpt-5.5"));
  assert.ok(autoReviewTurns.every(turn => turn.invocationModelArgument === "gpt-5.5"));
  assert.ok(autoReviewTurns.every(turn => turn.reasoningEffort === "medium"));
  const opusTurns = receipt.turns.filter(turn => turn.routeProfileID === "opus5");
  assert.ok(opusTurns.every(turn => turn.canonicalExpectedModel === "opus-5"));
  assert.ok(opusTurns.every(turn => turn.profileModelArgument === "opus"));
  assert.ok(opusTurns.every(turn => turn.invocationModelArgument === "opus-5"));
  assert.ok(opusTurns.every(
    turn => turn.proof.canonical_expected_model === "opus-5"
      && turn.proof.profile_model_argument === "opus"
      && turn.proof.invocation_model_argument === "opus-5",
  ));
  const haikuTurns = receipt.turns.filter(turn => turn.routeProfileID === "haiku4.5");
  assert.ok(haikuTurns.every(turn => turn.canonicalExpectedModel === "haiku-4-5"));
  assert.ok(haikuTurns.every(turn => turn.profileModelArgument === "haiku-4-5"));
  assert.ok(haikuTurns.every(turn => turn.invocationModelArgument === "haiku-4-5"));
  const baselineTurns = receipt.turns.filter(
    turn => turn.routeProfileID === "gpt-5.5",
  );
  assert.ok(baselineTurns.every(turn => turn.reasoningEffort === "low"));
  assert.ok(baselineTurns.every(turn => turn.adapter === "codex-exec"));

  const invocations = await readInvocationLog(invocationLog);
  assert.equal(invocations.length, 45);
  assert.equal(invocations.filter(value => value.adapter === "codex-exec").length, 33);
  assert.equal(invocations.filter(value => value.adapter === "gateway-direct").length, 12);
  for (const invocation of invocations) {
    const expected = expectedProfileContracts.get(invocation.profileID);
    assert.ok(expected, invocation.profileID);
    assert.equal(invocation.adapter, expected.adapter);
    assert.equal(invocation.stdinBytes, 0);
    const profile = [receipt.baselineProfile, ...receipt.routeProfiles]
      .find(value => value.id === invocation.profileID);
    assert.ok(profile, invocation.profileID);
    assert.equal(invocation.model, profile.invocationModelArgument);
    assert.equal(invocation.reasoningEffort, profile.reasoningEffort);
    assert.equal(invocation.speedTier, profile.speedTier);
    if (invocation.adapter === "codex-exec") {
      assert.equal(invocation.sandbox, "read-only");
      assert.equal(invocation.cwd, repoRoot);
    } else {
      assert.equal(invocation.computerHostRoute, "none");
      assert.match(invocation.runID, /^soak-[a-f0-9]+$/);
      assert.match(invocation.turnID, /^turn-[0-9]+$/);
      assert.match(invocation.currentTurnSHA256, /^[a-f0-9]{64}$/);
      assert.equal(invocation.currentTurnSHA256, invocation.promptSHA256);
    }
  }

  const verification = await runHarness(["--verify", receiptPath]);
  assert.equal(verification.code, 0, verification.stderr);
  const verified = JSON.parse(verification.stdout);
  assert.equal(verified.schema, "TatwoModelRouteSoakReceiptVerificationV1");
  assert.equal(verified.valid, true);
  assert.equal(verified.passed, true);
  assert.equal(verified.identityValid, true);
}

async function testTimeoutDisconnectDuplicateAndAttestationAccounting() {
  const receiptPath = path.join(tempRoot, "negative-receipt.json");
  const result = await runHarness([
    "--run",
    "--run-id", "negative-accounting",
    "--receipt", receiptPath,
    "--rounds", "2",
    "--min-output-bytes", "512",
    // A synthetic 10-second hang still proves timeout accounting, while this
    // lets the distinct immediate-disconnect fixture start and emit its
    // structured failure during the full parallel Node gate.
    "--timeout-ms", "2000",
  ], {
    FAKE_TIMEOUT_MODEL: "sonnet-5",
    FAKE_DISCONNECT_MODEL: "gpt-5.6-luna",
    FAKE_DUPLICATE_MODEL: "fable-5",
    FAKE_MISMATCH_MODEL: "opus-5",
    FAKE_SHORT_MODEL: "haiku-4-5",
    FAKE_DUPLICATE_EXECUTION_MODEL: "gpt-5.5",
  });
  assert.equal(result.code, 2);
  const receipt = JSON.parse(result.stdout);
  assert.equal(receipt.passed, false);
  assert.equal(receipt.receiptID, null);
  assert.match(receipt.attemptReceiptID, /^route-soak-[a-f0-9]{24}$/);
  assert.ok(receipt.summary.timeoutCount >= 2);
  assert.ok(receipt.summary.disconnectCount >= 2);
  assert.ok(receipt.summary.responseFailedCount >= 2);
  assert.ok(receipt.summary.duplicateAssistantMessageCount >= 2);
  assert.ok(receipt.summary.duplicateExecutionIDCount > 0);
  assert.equal(receipt.summary.duplicateResponseIDCount, 0);
  assert.ok(receipt.summary.duplicateCodexThreadIDCount > 0);
  assert.ok(receipt.summary.attestationFailureCount >= 4);
  assert.ok(receipt.summary.gatewayExactAttestationFailureCount >= 4);
  assert.equal(receipt.summary.codexHostRouteRequestProofFailureCount, 0);
  assert.ok(receipt.summary.undersizedOutputCount >= 4);
  assert.ok(receipt.summary.baselineReturnFailureCount > 0);

  const timeoutTurns = receipt.turns.filter(
    turn => turn.invocationModelArgument === "sonnet-5",
  );
  assert.ok(timeoutTurns.every(turn => turn.timeoutObserved));
  assert.ok(timeoutTurns.every(turn => turn.failureReasons.includes("timeout_observed")));

  const disconnectTurns = receipt.turns.filter(
    turn => turn.invocationModelArgument === "gpt-5.6-luna",
  );
  assert.ok(disconnectTurns.every(turn => turn.disconnectObserved));
  assert.ok(disconnectTurns.every(
    turn => turn.failureReasons.includes("response_failed_observed"),
  ));

  const duplicateTurns = receipt.turns.filter(
    turn => turn.invocationModelArgument === "fable-5",
  );
  assert.ok(duplicateTurns.every(turn => turn.duplicateAssistantMessageCount === 1));
  assert.ok(duplicateTurns.every(
    turn => turn.failureReasons.includes("assistant_output_channel_count_2"),
  ));

  const mismatchTurns = receipt.turns.filter(turn => turn.routeProfileID === "opus5");
  assert.ok(mismatchTurns.every(turn => turn.canonicalExpectedModel === "opus-5"));
  assert.ok(mismatchTurns.every(turn => turn.profileModelArgument === "opus"));
  assert.ok(mismatchTurns.every(turn => turn.invocationModelArgument === "opus-5"));
  assert.ok(mismatchTurns.every(turn => !turn.exactModelAttestation));
  assert.ok(mismatchTurns.every(
    turn => turn.failureReasons.includes("gateway_exact_model_attestation_failed"),
  ));

  const shortTurns = receipt.turns.filter(turn => turn.routeProfileID === "haiku4.5");
  assert.ok(shortTurns.every(turn => turn.canonicalExpectedModel === "haiku-4-5"));
  assert.ok(shortTurns.every(turn => turn.profileModelArgument === "haiku-4-5"));
  assert.ok(shortTurns.every(turn => turn.invocationModelArgument === "haiku-4-5"));
  assert.ok(shortTurns.every(turn => turn.outputBytes < turn.minimumOutputBytes));
  assert.ok(shortTurns.every(
    turn => turn.failureReasons.includes("output_below_minimum_bytes"),
  ));

  const verification = await runHarness(["--verify-receipt", receiptPath]);
  assert.equal(verification.code, 0, verification.stderr);
  assert.equal(JSON.parse(verification.stdout).valid, true);
}

async function testReceiptTamperFailsVerification() {
  const sourcePath = path.join(tempRoot, "success-receipt.json");
  const tamperedPath = path.join(tempRoot, "tampered-receipt.json");
  const receipt = JSON.parse(await fs.readFile(sourcePath, "utf8"));
  receipt.summary.outputBytesTotal += 1;
  await fs.writeFile(tamperedPath, `${JSON.stringify(receipt, null, 2)}\n`);

  const verification = await runHarness(["--verify", tamperedPath]);
  assert.equal(verification.code, 2);
  const report = JSON.parse(verification.stdout);
  assert.equal(report.valid, false);
  assert.equal(report.identityValid, false);
}

async function testRouteDefaultAndFableAdapterSourceContracts() {
  const sameThreadSource = await fs.readFile(sameThreadEvidence, "utf8");
  assert.match(
    sameThreadSource,
    /gpt-5\.5,opus-5,sonnet-5,haiku-4-5,gpt-5\.5/,
  );
  assert.doesNotMatch(sameThreadSource, /sonnet-4-6/);

  const runtimeSource = await fs.readFile(chatRuntimeSmoke, "utf8");
  assert.match(
    runtimeSource,
    /TATWO_CHAT_RUNTIME_TIMEOUT_MS \?\? 600000/,
  );
  assert.match(
    runtimeSource,
    /"fable5": \{ adapter: "gateway-direct", model: "fable-5"/,
  );
  assert.match(
    runtimeSource,
    /Fable, other Claude-family text, MiniMax, and Grok Chat routes use the direct local model_gateway/,
  );
  assert.doesNotMatch(
    runtimeSource,
    /"fable5": \{ adapter: "codex-gateway"/,
  );

  const routeSource = await fs.readFile(currentRouteProfilesSource, "utf8");
  for (const profileID of ["gpt-5.5", ...fullRouteProfiles]) {
    assert.match(routeSource, new RegExp(`id: "${escapeRegExp(profileID)}"`));
  }
  assert.match(
    routeSource,
    /id: "fable5"[\s\S]*?engine: \.claude,[\s\S]*?runtimeAdapter: \.claudeCLI,[\s\S]*?canonicalModelSlug: "fable-5"/,
  );
  assert.match(
    routeSource,
    /id: "haiku4\.5"[\s\S]*?runtimeAdapter: \.claudeCLI,[\s\S]*?canonicalModelSlug: "haiku-4-5",[\s\S]*?modelArgument: "haiku-4-5"/,
  );
  assert.match(
    routeSource,
    /id: "opus5"[\s\S]*?runtimeAdapter: \.claudeCLI,[\s\S]*?canonicalModelSlug: "opus-5",[\s\S]*?modelArgument: "opus"/,
  );
  const plannerSource = await fs.readFile(
    path.join(path.dirname(currentRouteProfilesSource), "TatwoChatCommandPlanner.swift"),
    "utf8",
  );
  assert.match(
    plannerSource,
    /gatewayDirectInactivityTimeoutMilliseconds = 600_000/,
  );
}

async function runHarness(argumentsValue, extraEnv = {}) {
  const verificationOnly = argumentsValue.includes("--verify")
    || argumentsValue.includes("--verify-receipt");
  const routedArguments = verificationOnly
    ? argumentsValue
    : [
        ...argumentsValue,
        "--gateway-adapter-script", fakeGatewayAdapter,
        "--codex-bin", fakeCodex,
      ];
  return await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [harness, ...routedArguments], {
      cwd: repoRoot,
      env: {
        ...process.env,
        TATWO_MODEL_ROUTE_SOAK: "1",
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

function fakeGatewayAdapterSource() {
  return `#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";

const args = parseArgs(process.argv.slice(2));
const model = String(args.model || "");
const prompt = String(args.prompt || "");
const dispatchID = String(args["dispatch-id"] || "");
const reasoningEffort = String(args["reasoning-effort"] || "");
const speedTier = args["service-tier"] ? String(args["service-tier"]) : null;
const computerHostRoute = String(args["computer-host-route"] || "");
const runID = String(args["run-id"] || "");
const turnID = String(args["turn-id"] || "");
const currentTurnSHA256 = String(args["current-turn-sha256"] || "");
const marker = prompt.match(/TATWO_ROUTE_SOAK_[A-Za-z0-9_]+/)?.[0] || "MARKER_MISSING";
const minimumBytes = Number(prompt.match(/at least ([0-9]+) bytes/)?.[1] || 512);
const stdinBytes = fs.readFileSync(0).length;
appendInvocation({
  adapter: "gateway-direct",
  profileID: profileFromMarker(marker),
  model,
  reasoningEffort,
  speedTier,
  computerHostRoute,
  runID,
  turnID,
  currentTurnSHA256,
  promptSHA256: crypto.createHash("sha256").update(prompt).digest("hex"),
  stdinBytes,
  sandbox: null,
  cwd: null,
});

if (model === process.env.FAKE_TIMEOUT_MODEL) {
  setTimeout(() => {}, 10_000);
} else if (model === process.env.FAKE_DISCONNECT_MODEL) {
  emit({
    type: "response.failed",
    dispatch_id: dispatchID,
    error: { message: "gateway_stream_disconnected" },
  });
  process.exit(2);
} else {
  const short = model === process.env.FAKE_SHORT_MODEL;
  let output = marker;
  if (!short) {
    output += "\\n" + "X".repeat(Math.max(0, minimumBytes - Buffer.byteLength(output) - 1));
  }
  const duplicate = model === process.env.FAKE_DUPLICATE_MODEL;
  const responseID = model === process.env.FAKE_DUPLICATE_EXECUTION_MODEL
    ? "resp-duplicate-across-turns"
    : "resp-" + digest(dispatchID);
  const itemID = "item-" + digest(dispatchID);
  const actualCanonical = model === process.env.FAKE_MISMATCH_MODEL
    ? "sonnet-5"
    : model;
  const actualVendor = vendorModel(actualCanonical);
  const item = {
    type: "item.completed",
    dispatch_id: dispatchID,
    item: { id: itemID, type: "agent_message", text: output },
  };
  emit(item);
  if (duplicate) emit(item);
  emit({
    type: "turn.completed",
    dispatch_id: dispatchID,
    response_id: responseID,
    requested_model: model,
    model: actualCanonical,
    actual_model: actualVendor,
    model_attestation: {
      schema: "TatwoModelExecutionAttestationV1",
      requested_model: model,
      requested_vendor_model: model,
      actual_canonical_model: actualCanonical,
      actual_vendor_model: actualVendor,
      observed_models: [actualVendor],
      model_usage_keys: [actualVendor],
      fallback_count: model === process.env.FAKE_MISMATCH_MODEL ? 1 : 0,
      outcome: model === process.env.FAKE_MISMATCH_MODEL
        ? "FAIL_CLOSED_MISMATCH"
        : "VERIFIED_EXACT",
    },
    reasoning: { requested: reasoningEffort },
    speed: { requested: speedTier },
  });
}

function vendorModel(value) {
  if (value === "fable-5") return "claude-fable-5";
  if (value === "sonnet-5") return "claude-sonnet-5";
  if (value === "opus-5") return "claude-opus-5";
  if (value === "haiku-4-5") return "claude-haiku-4-5-20260701";
  if (value === "grok-build") return "grok-4.6";
  return value;
}

function appendInvocation(value) {
  if (!process.env.FAKE_INVOCATION_LOG) return;
  fs.appendFileSync(process.env.FAKE_INVOCATION_LOG, JSON.stringify(value) + "\\n");
}

function profileFromMarker(value) {
  const ids = [
    "codex-auto-review", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.6-sol",
    "minimax-m3", "grok-build", "haiku4.5", "sonnet5", "opus5", "fable5",
    "gpt-5.5", "gpt-5.4",
  ];
  return ids.find(id => value.endsWith("_" + id.replace(/[^A-Za-z0-9]/g, "_"))) || "unknown";
}

function digest(value) {
  return crypto.createHash("sha256").update(String(value)).digest("hex").slice(0, 16);
}

function emit(value) {
  process.stdout.write(JSON.stringify(value) + "\\n");
}

function parseArgs(argv) {
  const out = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith("--")) continue;
    const equal = argument.indexOf("=");
    if (equal >= 0) out[argument.slice(2, equal)] = argument.slice(equal + 1);
    else out[argument.slice(2)] =
      argv[index + 1] && !argv[index + 1].startsWith("--")
        ? argv[++index]
        : true;
  }
  return out;
}
`;
}

function fakeCodexSource() {
  return `#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";

const argv = process.argv.slice(2);
const model = valueAfter("-m");
const prompt = String(argv.at(-1) || "");
const marker = prompt.match(/TATWO_ROUTE_SOAK_[A-Za-z0-9_]+/)?.[0] || "MARKER_MISSING";
const minimumBytes = Number(prompt.match(/at least ([0-9]+) bytes/)?.[1] || 512);
const configs = argv.flatMap((value, index) => value === "-c" ? [argv[index + 1]] : []);
const reasoningEffort = configs.find(value => value.startsWith("model_reasoning_effort="))
  ?.match(/"([^"]+)"/)?.[1] || "";
const speedTier = configs.find(value => value.startsWith("service_tier="))
  ?.match(/"([^"]+)"/)?.[1] || null;
const stdinBytes = fs.readFileSync(0).length;
appendInvocation({
  adapter: "codex-exec",
  profileID: profileFromMarker(marker),
  model,
  reasoningEffort,
  speedTier,
  stdinBytes,
  sandbox: valueAfter("-s"),
  cwd: valueAfter("-C"),
});

if (model === process.env.FAKE_TIMEOUT_MODEL) {
  setTimeout(() => {}, 10_000);
} else if (model === process.env.FAKE_DISCONNECT_MODEL) {
  emit({ type: "response.failed", error: { message: "gateway_stream_disconnected" } });
  process.exit(2);
} else {
  const short = model === process.env.FAKE_SHORT_MODEL;
  let output = marker;
  if (!short) {
    output += "\\n" + "X".repeat(Math.max(0, minimumBytes - Buffer.byteLength(output) - 1));
  }
  const threadID = model === process.env.FAKE_DUPLICATE_EXECUTION_MODEL
    ? "thread-duplicate-across-turns"
    : "thread-" + digest(marker);
  emit({ type: "thread.started", thread_id: threadID });
  emit({ type: "turn.started" });
  emit({
    type: "item.completed",
    item: {
      // Item IDs are execution-scoped in the real Codex JSONL stream. Reuse
      // one local ID across distinct thread IDs so the success case proves
      // the harness namespaces it by thread instead of demanding false
      // process-global uniqueness.
      id: "item-thread-local",
      type: "agent_message",
      text: output,
    },
  });
  emit({ type: "turn.completed", usage: { output_tokens: 1 } });
}

function valueAfter(flag) {
  const index = argv.indexOf(flag);
  return index >= 0 ? String(argv[index + 1] || "") : "";
}

function appendInvocation(value) {
  if (!process.env.FAKE_INVOCATION_LOG) return;
  fs.appendFileSync(process.env.FAKE_INVOCATION_LOG, JSON.stringify(value) + "\\n");
}

function profileFromMarker(value) {
  const ids = [
    "codex-auto-review", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.6-sol",
    "minimax-m3", "grok-build", "haiku4.5", "sonnet5", "opus5", "fable5",
    "gpt-5.5", "gpt-5.4",
  ];
  return ids.find(id => value.endsWith("_" + id.replace(/[^A-Za-z0-9]/g, "_"))) || "unknown";
}

function digest(value) {
  return crypto.createHash("sha256").update(String(value)).digest("hex").slice(0, 16);
}

function emit(value) {
  process.stdout.write(JSON.stringify(value) + "\\n");
}
`;
}

async function readInvocationLog(filePath) {
  return String(await fs.readFile(filePath, "utf8"))
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)
    .map(line => JSON.parse(line));
}

function profileContract(canonicalModelSlug, modelArgument, adapter) {
  return {
    canonicalModelSlug,
    modelArgument,
    invocationModelArgument:
      adapter === "gateway-direct" ? canonicalModelSlug : modelArgument,
    adapter,
  };
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
