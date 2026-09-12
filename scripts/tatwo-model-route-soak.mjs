#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const directGatewayAdapter = path.join(scriptDir, "tatwo-direct-gateway-chat.mjs");
const baselineProfile = routeProfile(
  "gpt-5.5",
  "gpt-5.5",
  "gpt-5.5",
  "codex-exec",
  "low",
  "fast",
);
const defaultAlternateProfiles = [
  routeProfile("gpt-5.6-sol", "gpt-5.6-sol", "gpt-5.6-sol", "codex-exec", "low", "fast"),
  routeProfile("gpt-5.6-terra", "gpt-5.6-terra", "gpt-5.6-terra", "codex-exec", "low", "fast"),
  routeProfile("gpt-5.6-luna", "gpt-5.6-luna", "gpt-5.6-luna", "codex-exec", "low", "fast"),
  routeProfile("minimax-m3", "minimax-m3", "minimax-m3", "gateway-direct", "low"),
  routeProfile("grok-build", "grok-build", "grok-build", "gateway-direct", "low"),
  routeProfile("fable5", "fable-5", "fable-5", "gateway-direct", "medium"),
  routeProfile("haiku4.5", "haiku-4-5", "haiku-4-5", "gateway-direct", "low"),
  routeProfile("sonnet5", "sonnet-5", "sonnet-5", "gateway-direct", "high"),
  routeProfile("opus5", "opus-5", "opus", "gateway-direct", "xhigh"),
  routeProfile("codex-auto-review", "gpt-5.5", "gpt-5.5", "codex-exec", "medium", "fast"),
  routeProfile("gpt-5.4", "gpt-5.4", "gpt-5.4", "codex-exec", "low", "fast"),
];
const fullRouteMatrix = defaultAlternateProfiles.map(profile => profile.id);

const args = parseArgs(process.argv.slice(2));
if (args.verify || args["verify-receipt"]) {
  const receiptPath = path.resolve(String(args.verify ?? args["verify-receipt"]));
  const verification = verifyReceipt(receiptPath);
  console.log(JSON.stringify(verification, null, 2));
  process.exit(verification.valid ? 0 : 2);
}

const runRequested = args.run === true || args.run === "1";
const confirmed = process.env.TATWO_MODEL_ROUTE_SOAK === "1";
const configuredBaselineProfile = resolveRouteProfile(args.baseline ?? baselineProfile.id);
const routeProfiles = uniqueProfiles(
  String(args.routes ?? fullRouteMatrix.join(","))
    .split(",")
    .map(resolveRouteProfile)
    .filter(profile => profile.id !== configuredBaselineProfile.id),
);
const rounds = boundedInteger(args.rounds ?? 2, "rounds", 2, 20);
const minOutputBytes = boundedInteger(
  args["min-output-bytes"] ?? process.env.TATWO_ROUTE_SOAK_MIN_OUTPUT_BYTES ?? 4096,
  "min-output-bytes",
  256,
  1_048_576,
);
const timeoutMs = boundedInteger(
  args["timeout-ms"] ?? process.env.TATWO_ROUTE_SOAK_TIMEOUT_MS ?? 600_000,
  "timeout-ms",
  25,
  900_000,
);
const runID = safeRunID(args["run-id"] ?? process.env.TATWO_ROUTE_SOAK_RUN_ID ?? crypto.randomUUID());
const gatewayAdapterScript = path.resolve(String(
  args["gateway-adapter-script"]
    ?? args["adapter-script"]
    ?? process.env.TATWO_ROUTE_SOAK_GATEWAY_ADAPTER_SCRIPT
    ?? process.env.TATWO_ROUTE_SOAK_ADAPTER_SCRIPT
    ?? directGatewayAdapter,
));
const codexExecutable = String(
  args["codex-bin"]
    ?? process.env.TATWO_ROUTE_SOAK_CODEX_BIN
    ?? "codex",
).trim();
const receiptPath = path.resolve(String(
  args.receipt
    ?? path.join(
      repoRoot,
      ".tatwo-ultrawork",
      "evidence",
      `model-route-soak-${runID}`,
      "model-route-soak-receipt.json",
    ),
));
const plan = buildTurnPlan({
  runID,
  baselineProfile: configuredBaselineProfile,
  routeProfiles,
  rounds,
  minOutputBytes,
});

if (!runRequested || !confirmed) {
  console.log(JSON.stringify({
    schema: "TatwoModelRouteSoakPlanV1",
    liveExecutionRequested: runRequested,
    liveExecutionPerformed: false,
    blockedBy: [
      ...(!runRequested ? ["--run_missing"] : []),
      ...(!confirmed ? ["TATWO_MODEL_ROUTE_SOAK_confirmation_missing"] : []),
    ],
    baselineProfile: configuredBaselineProfile,
    routeProfiles,
    rounds,
    minOutputBytes,
    expectedTurnCount: plan.length,
    expectedBaselineReturnCount: rounds * routeProfiles.length,
    scope: routeSoakScope(),
  }, null, 2));
  process.exit(2);
}

if (!fs.existsSync(gatewayAdapterScript) || !fs.statSync(gatewayAdapterScript).isFile()) {
  console.error(JSON.stringify({
    schema: "TatwoModelRouteSoakErrorV1",
    error: "gateway_adapter_script_not_found",
  }));
  process.exit(2);
}
if (!codexExecutable || (codexExecutable.includes(path.sep) && !isExecutableFile(codexExecutable))) {
  console.error(JSON.stringify({
    schema: "TatwoModelRouteSoakErrorV1",
    error: "codex_executable_not_found_or_not_executable",
  }));
  process.exit(2);
}

const startedAt = new Date().toISOString();
const executions = [];
for (const turn of plan) {
  executions.push(runTurn(turn, {
    gatewayAdapterScript,
    codexExecutable,
    timeoutMs,
    minOutputBytes,
  }));
}

applyCrossTurnDuplicateAccounting(executions);
const turns = executions.map(value => value.receipt);
const summary = summarizeTurns(turns, plan, {
  baselineProfile: configuredBaselineProfile,
  routeProfiles,
  rounds,
});
const matrixCoverage = fullRouteMatrix.every(profileID =>
  routeProfiles.some(profile => profile.id === profileID))
  ? "FULL_CANONICAL_MATRIX"
  : "PARTIAL_CUSTOM_MATRIX";
const passed = routeSoakPassed({
  matrixCoverage,
  turns,
  expectedTurnCount: plan.length,
  summary,
});

const receiptCore = {
  schema: "TatwoModelRouteSoakReceiptV1",
  runID,
  startedAt,
  generatedAt: new Date().toISOString(),
  liveExecutionRequested: true,
  liveExecutionPerformed: true,
  hostMutationAllowed: false,
  hostMutationPerformed: false,
  gatewayRestarted: false,
  authSessionTokenTouched: false,
  scope: routeSoakScope(),
  revision: gitRevision(),
  adapters: {
    gatewayDirect: {
      name: path.basename(gatewayAdapterScript),
      path: gatewayAdapterScript,
      sha256: sha256File(gatewayAdapterScript),
    },
    codexExec: executableReceipt(codexExecutable),
  },
  baselineProfile: configuredBaselineProfile,
  baselineCanonicalModel: configuredBaselineProfile.canonicalModelSlug,
  baselineInvocationModelArgument: configuredBaselineProfile.invocationModelArgument,
  routeProfiles,
  routes: routeProfiles.map(profile => profile.id),
  fullRouteMatrix,
  matrixCoverage,
  rounds,
  minOutputBytes,
  timeoutMs,
  expectedTurnCount: plan.length,
  expectedBaselineReturnCount: rounds * routeProfiles.length,
  planDigest: `plan-${shortHash(JSON.stringify(plan.map(turn => ({
    index: turn.index,
    round: turn.round,
    phase: turn.phase,
    routeProfileID: turn.routeProfileID,
    adapter: turn.adapter,
    canonicalExpectedModel: turn.canonicalExpectedModel,
    profileModelArgument: turn.profileModelArgument,
    invocationModelArgument: turn.invocationModelArgument,
    reasoningEffort: turn.reasoningEffort,
    speedTier: turn.speedTier,
    baselineAfterCanonicalModel: turn.baselineAfterCanonicalModel,
    baselineAfterProfileID: turn.baselineAfterProfileID,
  }))))}`,
  turns,
  perRoute: summarizePerRoute(turns),
  summary,
  passed,
};
const attemptReceiptID = receiptIdentity(receiptCore);
const receipt = {
  ...receiptCore,
  attemptReceiptID,
  receiptID: passed ? attemptReceiptID : null,
};

writeReceipt(receiptPath, receipt);
process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
process.exitCode = passed ? 0 : 2;

function buildTurnPlan(config) {
  const turns = [];
  turns.push(planTurn({
    index: turns.length,
    round: 0,
    phase: "initial_baseline",
    profile: config.baselineProfile,
    baselineAfterCanonicalModel: null,
    ...config,
  }));
  for (let round = 1; round <= config.rounds; round += 1) {
    for (const profile of config.routeProfiles) {
      turns.push(planTurn({
        index: turns.length,
        round,
        phase: "route",
        profile,
        baselineAfterCanonicalModel: null,
        ...config,
      }));
      turns.push(planTurn({
        index: turns.length,
        round,
        phase: "baseline_return",
        profile: config.baselineProfile,
        baselineAfterCanonicalModel: profile.canonicalModelSlug,
        baselineAfterProfileID: profile.id,
        ...config,
      }));
    }
  }
  return turns;
}

function planTurn(value) {
  const profile = value.profile;
  const marker = [
    "TATWO_ROUTE_SOAK",
    safeMarkerPart(value.runID),
    `R${value.round}`,
    `T${value.index}`,
    safeMarkerPart(profile.id),
  ].join("_");
  return {
    index: value.index,
    round: value.round,
    phase: value.phase,
    routeProfileID: profile.id,
    adapter: profile.adapter,
    canonicalExpectedModel: profile.canonicalModelSlug,
    profileModelArgument: profile.modelArgument,
    invocationModelArgument: profile.invocationModelArgument,
    reasoningEffort: profile.reasoningEffort,
    speedTier: profile.speedTier,
    baselineAfterCanonicalModel: value.baselineAfterCanonicalModel,
    baselineAfterProfileID: value.baselineAfterProfileID ?? null,
    marker,
    prompt: [
      "Tatwo model-route soak probe.",
      `First output this marker exactly once: ${marker}`,
      `Then write at least 18 numbered office-work durability sections, each with at least 2 substantive sentences, until the entire UTF-8 response is at least ${value.minOutputBytes} bytes.`,
      "Keep the marker only on the first line. Never repeat or quote it later.",
      "Do not call tools. Do not describe or claim a different model identity.",
    ].join("\n"),
  };
}

function buildTurnInvocation(turn, options) {
  if (turn.adapter === "gateway-direct") {
    return {
      command: process.execPath,
      arguments: [
        options.gatewayAdapterScript,
        "--model", turn.invocationModelArgument,
        "--reasoning-effort", turn.reasoningEffort,
        ...(turn.speedTier ? ["--service-tier", turn.speedTier] : []),
        "--prompt", turn.prompt,
        "--dispatch-id", options.dispatchID,
        // Route soak calls the same fail-closed direct adapter as Tatwo Chat.
        // Bind the exact current probe turn so the adapter/gateway never
        // derives Computer Use authority from flattened prompt history.
        "--computer-host-route", "none",
        "--run-id", options.dispatchID,
        "--turn-id", `turn-${turn.index}`,
        "--current-turn-sha256", sha256(turn.prompt),
        "--timeout-ms", String(options.timeoutMs),
      ],
      stdinClosed: true,
      sandboxMode: null,
    };
  }
  if (turn.adapter === "codex-exec") {
    return {
      command: options.codexExecutable,
      arguments: [
        "exec",
        "-C", repoRoot,
        "-s", "read-only",
        "-m", turn.invocationModelArgument,
        "-c", `model_reasoning_effort="${turn.reasoningEffort}"`,
        ...(turn.speedTier ? ["-c", `service_tier="${turn.speedTier}"`] : []),
        "--json",
        turn.prompt,
      ],
      stdinClosed: true,
      sandboxMode: "read-only",
    };
  }
  throw new Error(`unsupported_route_adapter:${turn.adapter}`);
}

function runTurn(turn, options) {
  const dispatchID = `soak-${shortHash([
    turn.marker,
    turn.canonicalExpectedModel,
    turn.invocationModelArgument,
    turn.index,
  ].join("|"))}`;
  const invocation = buildTurnInvocation(turn, {
    ...options,
    dispatchID,
  });
  const started = process.hrtime.bigint();
  const result = spawnSync(invocation.command, invocation.arguments, {
    cwd: repoRoot,
    env: process.env,
    encoding: "utf8",
    input: "",
    timeout: options.timeoutMs + 250,
    maxBuffer: Math.max(16 * 1024 * 1024, options.minOutputBytes * 8),
  });
  const elapsedMs = Number(process.hrtime.bigint() - started) / 1_000_000;
  const stdout = String(result.stdout ?? "");
  const stderr = String(result.stderr ?? "");
  const parsed = parseAdapterJSONL(stdout);
  const failureText = [
    stderr,
    ...parsed.failedEvents.map(event => bestText(event?.error) ?? ""),
  ].join("\n");
  const processTimedOut = result.error?.code === "ETIMEDOUT";
  const timeoutObserved = processTimedOut || /(?:timed?\s*out|timeout)/i.test(failureText);
  const disconnectObserved =
    /(?:stream[\s_-]*(?:disconnected|ended[\s_-]*without|done[\s_-]*without)|disconnected[\s_-]*before[\s_-]*completion|connection[\s_-]*reset|econnreset|socket[\s_-]*hang[\s_-]*up|premature[\s_-]*close|gateway_response_disconnected)/i
      .test(failureText);
  const combinedAssistantText = parsed.transcriptFragments.join("");
  const outputBytes = Buffer.byteLength(combinedAssistantText);
  const markerOccurrences = occurrences(combinedAssistantText, turn.marker);
  const completed = parsed.completedEvents[0] ?? null;
  const providerProof = providerProofForTurn(turn, completed, invocation);
  const controlsMatched = providerProof.controlsMatched;
  const executionIDs = executionIDsForTurn(turn, parsed);
  const assistantItemIDs = assistantItemIDsForTurn(parsed);
  const outputChannelCount =
    (parsed.deltaEvents.length > 0 ? 1 : 0)
    + parsed.assistantEvents.length;
  const failureReasons = [];

  if (result.status !== 0) failureReasons.push(`adapter_exit_${result.status ?? "unknown"}`);
  if (timeoutObserved) failureReasons.push("timeout_observed");
  if (disconnectObserved) failureReasons.push("disconnect_observed");
  if (parsed.malformedLineCount > 0) failureReasons.push("malformed_adapter_jsonl");
  if (parsed.failedEvents.length > 0) failureReasons.push("response_failed_observed");
  if (outputChannelCount !== 1) {
    failureReasons.push(`assistant_output_channel_count_${outputChannelCount}`);
  }
  if (parsed.completedEvents.length !== 1) {
    failureReasons.push(`turn_completed_count_${parsed.completedEvents.length}`);
  }
  if (markerOccurrences !== 1) failureReasons.push(`marker_occurrences_${markerOccurrences}`);
  if (outputBytes < options.minOutputBytes) failureReasons.push("output_below_minimum_bytes");
  if (!providerProof.verified) failureReasons.push(providerProof.failureReason);
  if (!controlsMatched) failureReasons.push("route_profile_controls_mismatch");
  if (executionIDs.length !== 1) {
    failureReasons.push(`${turn.adapter === "gateway-direct" ? "response_id" : "thread_id"}_count_${executionIDs.length}`);
  }
  if (assistantItemIDs.length !== 1) {
    failureReasons.push(`assistant_item_id_count_${assistantItemIDs.length}`);
  }
  const dispatchMatched = turn.adapter === "gateway-direct"
    ? dispatchMatches(parsed, dispatchID)
    : null;
  if (dispatchMatched === false) failureReasons.push("dispatch_id_mismatch");

  const receipt = {
    index: turn.index,
    round: turn.round,
    phase: turn.phase,
    routeProfileID: turn.routeProfileID,
    adapter: turn.adapter,
    canonicalExpectedModel: turn.canonicalExpectedModel,
    profileModelArgument: turn.profileModelArgument,
    invocationModelArgument: turn.invocationModelArgument,
    reasoningEffort: turn.reasoningEffort,
    speedTier: turn.speedTier,
    baselineAfterCanonicalModel: turn.baselineAfterCanonicalModel,
    baselineAfterProfileID: turn.baselineAfterProfileID,
    adapterExitCode: result.status,
    elapsedMs: Math.round(elapsedMs),
    timeoutObserved,
    disconnectObserved,
    responseFailedCount: parsed.failedEvents.length,
    malformedLineCount: parsed.malformedLineCount,
    deltaEventCount: parsed.deltaEvents.length,
    terminalAssistantMessageCount: parsed.assistantEvents.length,
    assistantOutputChannelCount: outputChannelCount,
    duplicateAssistantMessageCount: Math.max(0, outputChannelCount - 1),
    completedEventCount: parsed.completedEvents.length,
    duplicateCompletionCount: Math.max(0, parsed.completedEvents.length - 1),
    markerMatchedExactlyOnce: markerOccurrences === 1,
    markerOccurrenceCount: markerOccurrences,
    duplicateMarkerCount: Math.max(0, markerOccurrences - 1),
    outputBytes,
    minimumOutputBytes: options.minOutputBytes,
    outputSha256: outputBytes > 0 ? sha256(combinedAssistantText) : null,
    executionIDKind: turn.adapter === "gateway-direct" ? "provider_response_id" : "codex_thread_id",
    executionIDHash: executionIDs[0] ? sha256(executionIDs[0]) : null,
    responseIDHash: turn.adapter === "gateway-direct" && executionIDs[0]
      ? sha256(executionIDs[0])
      : null,
    codexThreadIDHash: turn.adapter === "codex-exec" && executionIDs[0]
      ? sha256(executionIDs[0])
      : null,
    // Provider/runner item IDs are only guaranteed inside their execution
    // namespace. Codex CLI commonly reuses an item-local ID such as
    // `item_0` across independent thread IDs; treating that as a global
    // collision turns healthy route switches into false failures. Bind the
    // item identity to the provider response / Codex thread before doing
    // cross-turn duplicate accounting.
    assistantItemIDHash: assistantItemIDs[0] && executionIDs[0]
      ? sha256(`${executionIDs[0]}\u0000${assistantItemIDs[0]}`)
      : null,
    proofClass: providerProof.proofClass,
    proof: providerProof.receipt,
    requestedCanonicalModel: turn.canonicalExpectedModel,
    actualCanonicalModel: providerProof.actualCanonicalModel,
    actualVendorModel: providerProof.actualVendorModel,
    attestationOutcome: providerProof.attestationOutcome,
    fallbackCount: providerProof.fallbackCount,
    exactModelAttestation: providerProof.exactModelAttestation,
    gatewayExactAttestationVerified: providerProof.gatewayExactAttestationVerified,
    codexHostRouteRequestProofVerified: providerProof.codexHostRouteRequestProofVerified,
    providerExactModelAttested: providerProof.providerExactModelAttested,
    controlsMatched,
    dispatchMatched,
    stdinClosed: invocation.stdinClosed,
    sandboxMode: invocation.sandboxMode,
    failureReasons,
    passed: failureReasons.length === 0,
  };
  return {
    receipt,
    rawExecutionIDs: executionIDs,
    rawAssistantItemIDs: assistantItemIDs.map(
      itemID => `${executionIDs[0] ?? "execution-missing"}\u0000${itemID}`,
    ),
  };
}

function parseAdapterJSONL(text) {
  const assistantEvents = [];
  const deltaEvents = [];
  const completedEvents = [];
  const failedEvents = [];
  const threadStartedEvents = [];
  const outputItemControls = [];
  const transcriptFragments = [];
  let malformedLineCount = 0;
  for (const rawLine of String(text ?? "").split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line) continue;
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      malformedLineCount += 1;
      continue;
    }
    if (event?.type === "item.completed" && event?.item?.type === "agent_message") {
      assistantEvents.push(event);
      transcriptFragments.push(String(event?.item?.text ?? ""));
    } else if (event?.type === "response.output_text.delta") {
      deltaEvents.push(event);
      transcriptFragments.push(String(event?.delta ?? ""));
    } else if (event?.type === "turn.completed") {
      completedEvents.push(event);
    } else if (event?.type === "response.failed") {
      failedEvents.push(event);
    } else if (event?.type === "thread.started") {
      threadStartedEvents.push(event);
    } else if (
      event?.type === "system"
      && event?.control_type === "response.output_item.done"
    ) {
      outputItemControls.push(event);
    }
  }
  return {
    assistantEvents,
    deltaEvents,
    completedEvents,
    failedEvents,
    threadStartedEvents,
    outputItemControls,
    transcriptFragments,
    malformedLineCount,
  };
}

function providerProofForTurn(turn, completed, invocation) {
  if (turn.adapter === "gateway-direct") {
    const attestation = completed?.model_attestation ?? null;
    const exact = exactAttestation(
      attestation,
      completed,
      turn.canonicalExpectedModel,
    );
    const controlsMatched =
      completed?.reasoning?.requested === turn.reasoningEffort
      && (turn.speedTier
        ? completed?.speed?.requested === turn.speedTier
        : completed?.speed?.requested == null);
    return {
      proofClass: "provider_exact_model_attestation",
      receipt: {
        schema: "TatwoGatewayExactModelProofV1",
        ui_profile_id: turn.routeProfileID,
        canonical_expected_model: turn.canonicalExpectedModel,
        profile_model_argument: turn.profileModelArgument,
        invocation_model_argument: turn.invocationModelArgument,
        outcome: exact ? "VERIFIED_EXACT" : "FAIL_CLOSED",
        attestation: attestation ?? {
          schema: "TatwoModelExecutionAttestationV1",
          outcome: "ATTESTATION_MISSING",
        },
      },
      verified: exact,
      failureReason: "gateway_exact_model_attestation_failed",
      controlsMatched,
      actualCanonicalModel: canonicalModelRoute(attestation?.actual_canonical_model) || null,
      actualVendorModel:
        String(attestation?.actual_vendor_model ?? completed?.actual_model ?? "").trim() || null,
      attestationOutcome: String(attestation?.outcome ?? "ATTESTATION_MISSING"),
      fallbackCount: finiteNonNegative(attestation?.fallback_count),
      exactModelAttestation: exact,
      gatewayExactAttestationVerified: exact,
      codexHostRouteRequestProofVerified: null,
      providerExactModelAttested: exact,
    };
  }

  const requestProof = codexHostRouteRequestProof(turn, invocation);
  return {
    proofClass: "host_route_request_config",
    receipt: requestProof,
    verified: requestProof.outcome === "REQUEST_CONFIG_VERIFIED",
    failureReason: "codex_host_route_request_proof_failed",
    controlsMatched: requestProof.controls_matched,
    actualCanonicalModel: null,
    actualVendorModel: null,
    attestationOutcome: "PROVIDER_ATTESTATION_NOT_AVAILABLE",
    fallbackCount: null,
    exactModelAttestation: null,
    gatewayExactAttestationVerified: null,
    codexHostRouteRequestProofVerified:
      requestProof.outcome === "REQUEST_CONFIG_VERIFIED",
    providerExactModelAttested: false,
  };
}

function codexHostRouteRequestProof(turn, invocation) {
  const modelIndex = invocation.arguments.indexOf("-m");
  const sandboxIndex = invocation.arguments.indexOf("-s");
  const configValues = invocation.arguments
    .flatMap((value, index, all) => value === "-c" ? [all[index + 1]] : [])
    .filter(Boolean);
  const requestedEffort = `model_reasoning_effort="${turn.reasoningEffort}"`;
  const requestedTier = turn.speedTier ? `service_tier="${turn.speedTier}"` : null;
  const controlsMatched =
    invocation.arguments[modelIndex + 1] === turn.invocationModelArgument
    && configValues.includes(requestedEffort)
    && (requestedTier ? configValues.includes(requestedTier) : true);
  const sandboxMatched =
    invocation.arguments[sandboxIndex + 1] === "read-only"
    && invocation.sandboxMode === "read-only";
  const cwdIndex = invocation.arguments.indexOf("-C");
  const cwdMatched = invocation.arguments[cwdIndex + 1] === repoRoot;
  const jsonPromptMatched =
    invocation.arguments.at(-2) === "--json"
    && invocation.arguments.at(-1) === turn.prompt;
  const verified =
    invocation.arguments[0] === "exec"
    && controlsMatched
    && sandboxMatched
    && cwdMatched
    && jsonPromptMatched
    && invocation.stdinClosed === true;
  return {
    schema: "TatwoCodexHostRouteRequestProofV1",
    outcome: verified ? "REQUEST_CONFIG_VERIFIED" : "REQUEST_CONFIG_MISMATCH",
    ui_profile_id: turn.routeProfileID,
    canonical_expected_model: turn.canonicalExpectedModel,
    profile_model_argument: turn.profileModelArgument,
    invocation_model_argument: turn.invocationModelArgument,
    reasoning_effort: turn.reasoningEffort,
    service_tier: turn.speedTier,
    sandbox: invocation.sandboxMode,
    stdin: invocation.stdinClosed ? "closed" : "open_or_unknown",
    controls_matched: controlsMatched,
    cwd_matched: cwdMatched,
    json_prompt_shape_matched: jsonPromptMatched,
    provider_exact_model_attested: false,
    provider_attestation_limitation:
      "standard codex exec --json does not expose provider actual-model attestation",
    argv_sha256: sha256(JSON.stringify(invocation.arguments)),
  };
}

function executionIDsForTurn(turn, parsed) {
  if (turn.adapter === "gateway-direct") {
    return parsed.completedEvents
      .map(event => String(event?.response_id ?? "").trim())
      .filter(Boolean);
  }
  return parsed.threadStartedEvents
    .map(event => String(event?.thread_id ?? "").trim())
    .filter(Boolean);
}

function assistantItemIDsForTurn(parsed) {
  const providerItemIDs = parsed.outputItemControls
    .map(event => String(event?.item_id ?? "").trim())
    .filter(Boolean);
  if (providerItemIDs.length > 0) return providerItemIDs;
  return parsed.assistantEvents
    .map(event => String(event?.item?.id ?? "").trim())
    .filter(Boolean);
}

function exactAttestation(attestation, completed, canonicalExpectedModel) {
  const expected = canonicalModelRoute(canonicalExpectedModel);
  return attestation?.schema === "TatwoModelExecutionAttestationV1"
    && attestation?.outcome === "VERIFIED_EXACT"
    && canonicalModelRoute(attestation?.requested_model) === expected
    && canonicalModelRoute(attestation?.actual_canonical_model) === expected
    && canonicalModelRoute(completed?.requested_model) === expected
    && canonicalModelRoute(completed?.model) === expected
    && canonicalModelRoute(attestation?.actual_vendor_model ?? completed?.actual_model) === expected
    && finiteNonNegative(attestation?.fallback_count) === 0;
}

function dispatchMatches(parsed, dispatchID) {
  const outputEvents = [...parsed.deltaEvents, ...parsed.assistantEvents];
  return outputEvents.length > 0
    && parsed.completedEvents.length === 1
    && outputEvents.every(event => event?.dispatch_id === dispatchID)
    && parsed.completedEvents[0]?.dispatch_id === dispatchID;
}

function applyCrossTurnDuplicateAccounting(executions) {
  const executionCounts = occurrenceMap(executions.flatMap(value => value.rawExecutionIDs));
  const itemCounts = occurrenceMap(executions.flatMap(value => value.rawAssistantItemIDs));
  for (const execution of executions) {
    const duplicateExecutionIDCount = execution.rawExecutionIDs.reduce(
      (sum, value) => sum + Math.max(0, (executionCounts.get(value) ?? 0) - 1),
      0,
    );
    const duplicateAssistantItemIDCount = execution.rawAssistantItemIDs.reduce(
      (sum, value) => sum + Math.max(0, (itemCounts.get(value) ?? 0) - 1),
      0,
    );
    execution.receipt.duplicateExecutionIDCount = duplicateExecutionIDCount;
    execution.receipt.duplicateResponseIDCount =
      execution.receipt.adapter === "gateway-direct" ? duplicateExecutionIDCount : 0;
    execution.receipt.duplicateCodexThreadIDCount =
      execution.receipt.adapter === "codex-exec" ? duplicateExecutionIDCount : 0;
    execution.receipt.duplicateAssistantItemIDCount = duplicateAssistantItemIDCount;
    if (duplicateExecutionIDCount > 0) {
      execution.receipt.failureReasons.push(
        execution.receipt.adapter === "gateway-direct"
          ? "duplicate_response_id_across_turns"
          : "duplicate_codex_thread_id_across_turns",
      );
    }
    if (duplicateAssistantItemIDCount > 0) {
      execution.receipt.failureReasons.push("duplicate_assistant_item_id_across_turns");
    }
    execution.receipt.failureReasons = [...new Set(execution.receipt.failureReasons)];
    execution.receipt.passed = execution.receipt.failureReasons.length === 0;
  }
}

function summarizeTurns(turns, planValue, config) {
  const outputBytes = turns.map(turn => turn.outputBytes);
  return {
    expectedTurnCount: planValue.length,
    observedTurnCount: turns.length,
    passedTurnCount: turns.filter(turn => turn.passed).length,
    failedTurnCount: turns.filter(turn => !turn.passed).length,
    initialBaselinePassed: turns.find(turn => turn.phase === "initial_baseline")?.passed === true,
    baselineReturnCount: turns.filter(turn => turn.phase === "baseline_return").length,
    baselineReturnFailureCount: turns.filter(
      turn => turn.phase === "baseline_return" && !turn.passed,
    ).length,
    timeoutCount: sum(turns, "timeoutObserved"),
    disconnectCount: sum(turns, "disconnectObserved"),
    responseFailedCount: sum(turns, "responseFailedCount"),
    duplicateAssistantMessageCount: sum(turns, "duplicateAssistantMessageCount"),
    duplicateCompletionCount: sum(turns, "duplicateCompletionCount"),
    duplicateMarkerCount: sum(turns, "duplicateMarkerCount"),
    duplicateExecutionIDCount: countDuplicateHashes(turns, "executionIDHash"),
    duplicateResponseIDCount: countDuplicateHashes(turns, "responseIDHash"),
    duplicateCodexThreadIDCount: countDuplicateHashes(turns, "codexThreadIDHash"),
    duplicateAssistantItemIDCount: countDuplicateHashes(turns, "assistantItemIDHash"),
    gatewayExactAttestationRequiredCount: turns.filter(
      turn => turn.adapter === "gateway-direct",
    ).length,
    gatewayExactAttestationVerifiedCount: turns.filter(
      turn => turn.gatewayExactAttestationVerified === true,
    ).length,
    gatewayExactAttestationFailureCount: turns.filter(
      turn => turn.adapter === "gateway-direct"
        && turn.gatewayExactAttestationVerified !== true,
    ).length,
    codexHostRouteRequestProofRequiredCount: turns.filter(
      turn => turn.adapter === "codex-exec",
    ).length,
    codexHostRouteRequestProofVerifiedCount: turns.filter(
      turn => turn.codexHostRouteRequestProofVerified === true,
    ).length,
    codexHostRouteRequestProofFailureCount: turns.filter(
      turn => turn.adapter === "codex-exec"
        && turn.codexHostRouteRequestProofVerified !== true,
    ).length,
    providerExactModelUnattestedCodexTurnCount: turns.filter(
      turn => turn.adapter === "codex-exec"
        && turn.providerExactModelAttested === false,
    ).length,
    attestationFailureCount: turns.filter(
      turn => turn.adapter === "gateway-direct"
        && turn.gatewayExactAttestationVerified !== true,
    ).length,
    routeProfileControlFailureCount: turns.filter(turn => !turn.controlsMatched).length,
    undersizedOutputCount: turns.filter(
      turn => turn.outputBytes < turn.minimumOutputBytes,
    ).length,
    outputBytesTotal: outputBytes.reduce((total, value) => total + value, 0),
    outputBytesMinimum: outputBytes.length ? Math.min(...outputBytes) : 0,
    outputBytesMaximum: outputBytes.length ? Math.max(...outputBytes) : 0,
    baselineProfileID: config.baselineProfile.id,
    baselineCanonicalModel: config.baselineProfile.canonicalModelSlug,
    baselineInvocationModelArgument:
      config.baselineProfile.invocationModelArgument,
    configuredRouteCount: config.routeProfiles.length,
    rounds: config.rounds,
  };
}

function summarizePerRoute(turns) {
  const grouped = new Map();
  for (const turn of turns) {
    const current = grouped.get(turn.routeProfileID) ?? {
      routeProfileID: turn.routeProfileID,
      adapter: turn.adapter,
      canonicalExpectedModel: turn.canonicalExpectedModel,
      profileModelArgument: turn.profileModelArgument,
      invocationModelArgument: turn.invocationModelArgument,
      reasoningEffort: turn.reasoningEffort,
      speedTier: turn.speedTier,
      plannedTurnCount: 0,
      passedTurnCount: 0,
      failedTurnCount: 0,
      baselineReturnTurnCount: 0,
      outputBytesTotal: 0,
      timeoutCount: 0,
      disconnectCount: 0,
      gatewayExactAttestationFailureCount: 0,
      codexHostRouteRequestProofFailureCount: 0,
      routeProfileControlFailureCount: 0,
      duplicateAssistantMessageCount: 0,
    };
    current.plannedTurnCount += 1;
    current.passedTurnCount += turn.passed ? 1 : 0;
    current.failedTurnCount += turn.passed ? 0 : 1;
    current.baselineReturnTurnCount += turn.phase === "baseline_return" ? 1 : 0;
    current.outputBytesTotal += turn.outputBytes;
    current.timeoutCount += turn.timeoutObserved ? 1 : 0;
    current.disconnectCount += turn.disconnectObserved ? 1 : 0;
    current.gatewayExactAttestationFailureCount +=
      turn.adapter === "gateway-direct" && turn.gatewayExactAttestationVerified !== true ? 1 : 0;
    current.codexHostRouteRequestProofFailureCount +=
      turn.adapter === "codex-exec" && turn.codexHostRouteRequestProofVerified !== true ? 1 : 0;
    current.routeProfileControlFailureCount += turn.controlsMatched ? 0 : 1;
    current.duplicateAssistantMessageCount += turn.duplicateAssistantMessageCount;
    grouped.set(turn.routeProfileID, current);
  }
  return [...grouped.values()].sort(
    (left, right) => left.routeProfileID.localeCompare(right.routeProfileID),
  );
}

function verifyReceipt(filePath) {
  let receipt;
  try {
    receipt = JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch {
    return {
      schema: "TatwoModelRouteSoakReceiptVerificationV1",
      valid: false,
      error: "receipt_unreadable_or_invalid_json",
    };
  }
  const {
    attemptReceiptID,
    receiptID,
    ...core
  } = receipt ?? {};
  const expectedAttemptReceiptID = receiptIdentity(core);
  const expectedPassed = routeSoakPassed(core);
  const structureValid =
    core?.schema === "TatwoModelRouteSoakReceiptV1"
    && Array.isArray(core?.turns)
    && core.turns.length === core.expectedTurnCount
    && typeof core.passed === "boolean"
    && core.passed === expectedPassed
    && core.summary?.observedTurnCount === core.turns.length;
  const identityValid = attemptReceiptID === expectedAttemptReceiptID;
  const passIdentityValid = core.passed
    ? receiptID === expectedAttemptReceiptID
    : receiptID === null;
  return {
    schema: "TatwoModelRouteSoakReceiptVerificationV1",
    valid: structureValid && identityValid && passIdentityValid,
    structureValid,
    identityValid,
    passIdentityValid,
    passed: core?.passed === true,
    attemptReceiptID: attemptReceiptID ?? null,
  };
}

function routeSoakPassed(value) {
  const turnsValue = Array.isArray(value?.turns) ? value.turns : [];
  const summaryValue = value?.summary ?? {};
  return value?.matrixCoverage === "FULL_CANONICAL_MATRIX"
    && turnsValue.length === value?.expectedTurnCount
    && turnsValue.every(turn => turn?.passed === true)
    && summaryValue.baselineReturnFailureCount === 0
    && summaryValue.timeoutCount === 0
    && summaryValue.disconnectCount === 0
    && summaryValue.duplicateAssistantMessageCount === 0
    && summaryValue.duplicateCompletionCount === 0
    && summaryValue.duplicateMarkerCount === 0
    && summaryValue.duplicateExecutionIDCount === 0
    && summaryValue.duplicateResponseIDCount === 0
    && summaryValue.duplicateCodexThreadIDCount === 0
    && summaryValue.duplicateAssistantItemIDCount === 0
    && summaryValue.gatewayExactAttestationFailureCount === 0
    && summaryValue.codexHostRouteRequestProofFailureCount === 0
    && summaryValue.routeProfileControlFailureCount === 0
    && summaryValue.undersizedOutputCount === 0;
}

function receiptIdentity(core) {
  return `route-soak-${shortHash(JSON.stringify(core))}`;
}

function writeReceipt(filePath, receiptValue) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(receiptValue, null, 2)}\n`, {
    encoding: "utf8",
    flag: "wx",
    mode: 0o600,
  });
}

function routeSoakScope() {
  return {
    executionSurface: "profile_selected_codex_exec_or_direct_model_gateway",
    sameThread: false,
    tatwoChatUI: false,
    actualChatTranscriptPersistence: false,
    proves: [
      "multi-round route availability",
      "all distinct current default Chat route profiles",
      "profile-to-adapter selection matches current Tatwo Chat command construction",
      "UI profile ID canonical expected model profile modelArgument and actual invocation argument are recorded separately",
      "gateway-direct per-turn exact provider model attestation",
      "codex-exec host-route model effort speed sandbox and closed-stdin request proof",
      "per-profile reasoning and speed request controls",
      "minimum UTF-8 output bytes",
      "return-to-baseline after every alternate route",
      "timeout disconnect and duplicate accounting",
    ],
    doesNotProve: [
      "Tatwo Chat UI acceptance",
      "single-thread cross-model continuity",
      "Tatwo transcript or journal persistence",
      "provider actual-model attestation for codex-exec turns",
    ],
  };
}

function gitRevision() {
  const head = git(["rev-parse", "HEAD"]);
  const branch = git(["branch", "--show-current"]);
  const status = git(["status", "--short"]);
  return {
    head: head || null,
    branch: branch || null,
    dirty: Boolean(status),
    dirtyEntryCount: status ? status.split(/\r?\n/).filter(Boolean).length : 0,
  };
}

function git(argumentsValue) {
  const result = spawnSync("git", argumentsValue, {
    cwd: repoRoot,
    encoding: "utf8",
    timeout: 5_000,
  });
  return result.status === 0 ? String(result.stdout ?? "").trim() : "";
}

function routeProfile(
  id,
  canonicalModelSlug,
  modelArgument,
  adapter,
  reasoningEffortValue,
  speedTier = null,
) {
  const canonicalExpectedModel = canonicalModelRoute(canonicalModelSlug);
  const profileModelArgument = String(modelArgument ?? "").trim() || null;
  return {
    id: String(id),
    canonicalModelSlug: canonicalExpectedModel,
    modelArgument: profileModelArgument,
    invocationModelArgument: adapter === "gateway-direct"
      ? canonicalExpectedModel
      : profileModelArgument ?? canonicalExpectedModel,
    adapter,
    reasoningEffort: reasoningEffortValue,
    speedTier,
  };
}

function resolveRouteProfile(value) {
  const requested = String(value ?? "").trim().toLowerCase();
  const canonical = canonicalModelRoute(requested);
  const knownProfiles = [baselineProfile, ...defaultAlternateProfiles];
  const known = knownProfiles.find(profile =>
    profile.id.toLowerCase() === requested
    || profile.canonicalModelSlug === canonical
    || canonicalModelRoute(profile.modelArgument) === canonical);
  if (known) return { ...known };
  return routeProfile(
    canonical,
    canonical,
    canonical,
    isGPTModel(canonical) ? "codex-exec" : "gateway-direct",
    defaultReasoningEffort(canonical),
    isGPTModel(canonical) ? "fast" : null,
  );
}

function canonicalModelRoute(value) {
  const normalized = String(value ?? "").trim().toLowerCase().replace(/\[[^\]]+\]$/, "");
  if (/^claude-haiku-4-5(?:-\d{8})?$/.test(normalized)) return "haiku-4-5";
  if (/^claude-haiku-4-6(?:-\d{8})?$/.test(normalized)) return "haiku-4-6";
  const aliases = new Map([
    ["claude-fable-5", "fable-5"],
    ["fable5", "fable-5"],
    ["claude-opus-5", "opus-5"],
    ["opus", "opus-5"],
    ["opus5", "opus-5"],
    ["claude-sonnet-5", "sonnet-5"],
    ["sonnet5", "sonnet-5"],
    ["claude-haiku-4-5", "haiku-4-5"],
    ["haiku4.5", "haiku-4-5"],
    ["grok-4.6", "grok-build"],
  ]);
  return aliases.get(normalized) ?? normalized;
}

function defaultReasoningEffort(model) {
  if (model === "sonnet-5" || model === "opus-5") return "high";
  if (model === "fable-5") return "medium";
  return "low";
}

function isGPTModel(model) {
  return /^(?:gpt-|codex-|o[0-9])/.test(String(model ?? "").toLowerCase());
}

function bestText(value) {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value.map(bestText).filter(Boolean).join(" ");
  if (value && typeof value === "object") {
    for (const key of ["message", "text", "error", "detail", "output"]) {
      const text = bestText(value[key]);
      if (text) return text;
    }
  }
  return "";
}

function countDuplicateHashes(values, key) {
  const counts = occurrenceMap(values.map(value => value[key]).filter(Boolean));
  return [...counts.values()].reduce((total, count) => total + Math.max(0, count - 1), 0);
}

function occurrenceMap(values) {
  const counts = new Map();
  for (const value of values) counts.set(value, (counts.get(value) ?? 0) + 1);
  return counts;
}

function sum(values, key) {
  return values.reduce((total, value) => {
    const candidate = value[key];
    if (typeof candidate === "boolean") return total + (candidate ? 1 : 0);
    const number = Number(candidate);
    return total + (Number.isFinite(number) ? number : 0);
  }, 0);
}

function occurrences(text, needle) {
  if (!needle) return 0;
  let count = 0;
  let offset = 0;
  while ((offset = text.indexOf(needle, offset)) >= 0) {
    count += 1;
    offset += needle.length;
  }
  return count;
}

function finiteNonNegative(value) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : null;
}

function uniqueProfiles(values) {
  return values.filter(
    (value, index) => values.findIndex(candidate => candidate.id === value.id) === index,
  );
}

function boundedInteger(value, name, minimum, maximum) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < minimum || parsed > maximum) {
    throw new Error(`${name}_must_be_integer_${minimum}_through_${maximum}`);
  }
  return parsed;
}

function safeRunID(value) {
  const normalized = String(value ?? "").trim();
  if (!/^[A-Za-z0-9_.-]{1,96}$/.test(normalized)) {
    throw new Error("run-id_contains_unsafe_characters");
  }
  return normalized;
}

function safeMarkerPart(value) {
  return String(value ?? "").replace(/[^A-Za-z0-9]/g, "_").slice(0, 96);
}

function shortHash(value) {
  return sha256(value).slice(0, 24);
}

function sha256(value) {
  return crypto.createHash("sha256").update(String(value)).digest("hex");
}

function sha256File(filePath) {
  return crypto.createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
}

function executableReceipt(value) {
  const resolved = value.includes(path.sep) ? path.resolve(value) : null;
  const exists = resolved && fs.existsSync(resolved) && fs.statSync(resolved).isFile();
  return {
    command: value,
    path: exists ? resolved : null,
    sha256: exists ? sha256File(resolved) : null,
  };
}

function isExecutableFile(filePath) {
  try {
    fs.accessSync(filePath, fs.constants.X_OK);
    return fs.statSync(filePath).isFile();
  } catch {
    return false;
  }
}

function parseArgs(argv) {
  const out = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith("--")) continue;
    const equal = argument.indexOf("=");
    if (equal >= 0) {
      out[argument.slice(2, equal)] = argument.slice(equal + 1);
    } else {
      out[argument.slice(2)] =
        argv[index + 1] && !argv[index + 1].startsWith("--")
          ? argv[++index]
          : true;
    }
  }
  return out;
}
