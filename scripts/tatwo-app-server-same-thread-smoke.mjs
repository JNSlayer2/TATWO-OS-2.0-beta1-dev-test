#!/usr/bin/env node
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

class AttemptFailure extends Error {
  constructor(code, detail = "") {
    super(detail ? `${code}: ${detail}` : code);
    this.code = code;
    this.detail = detail;
  }
}

const testNonce = required("TATWO_SAME_THREAD_EVIDENCE_NONCE");
const runID = required("TATWO_SAME_THREAD_RUN_ID");
const expectedTurnsInput = loadExpectedTurnsInput();
const expectedTurns = parseExpectedTurns(
  expectedTurnsInput,
  process.env.TATWO_SAME_THREAD_EXPECTED_ROUTES
    ?? "gpt-5.6-sol,fable-5,gpt-5.6-luna,grok-build,opus-5,gpt-5.6-sol",
);
const expectedRoutes = expectedTurns.map(turn => turn.model);
const requireContractContinuity =
  expectedTurnsInput.requireContractContinuity === true
  || String(process.env.TATWO_SAME_THREAD_REQUIRE_CONTRACT_CONTINUITY ?? "")
    .trim() === "1";
const expectedContract = normalizeContractExpectation(
  expectedTurnsInput.contract,
  requireContractContinuity,
);
const requireForwardingEvidence =
  String(process.env.TATWO_SAME_THREAD_REQUIRE_FORWARDING_EVIDENCE ?? "")
    .trim() === "1";
const attemptTimeoutMS = boundedInteger(
  process.env.TATWO_SAME_THREAD_ATTEMPT_TIMEOUT_MS,
  600000,
  50,
  900000,
);
const maxAttempts = boundedInteger(
  process.env.TATWO_SAME_THREAD_MAX_ATTEMPTS,
  2,
  1,
  2,
);
const processConfiguredSpeedTier = "fast";

if (!isUUID(runID)) failBeforeStart("invalid_run_id");
if (expectedRoutes.length < 2) failBeforeStart("at_least_two_routes_required");
if (expectedRoutes[0] !== expectedRoutes.at(-1)) {
  failBeforeStart("first_and_last_route_must_match");
}

const contextCode = `CODEX_GATEWAY_CONTEXT_${runID.replaceAll("-", "")}`;
let lastFailure = null;

for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
  try {
    const observed = await runAttempt(attempt);
    // Keep this exact V1 body stable so existing receipt parsers can continue to
    // verify `gatewayReceiptID`. Version 2 adds a separate, stronger integrity
    // identifier that binds the detailed per-turn attestation.
    const legacyReceiptBody = {
      testNonce,
      appThreadID: observed.threadID,
      runID,
      threadProvider: observed.threadProvider,
      orderedRoutes: observed.orderedRoutes,
    };
    const versionedReceiptBody = {
      ...legacyReceiptBody,
      receiptVersion: 2,
      orderedTurns: observed.orderedTurns,
    };
    const receipt = {
      schema: "TatwoGatewaySameThreadReceiptV1",
      receiptVersion: 2,
      ok: true,
      terminalStatus: "completed",
      testNonce,
      gatewayReceiptID: gatewayReceiptID(legacyReceiptBody),
      sameThreadReceiptID: versionedGatewayReceiptID(versionedReceiptBody),
      appThreadID: observed.threadID,
      runID,
      threadProvider: observed.threadProvider,
      orderedRoutes: observed.orderedRoutes,
      orderedTurns: observed.orderedTurns,
    };
    process.stdout.write(`${JSON.stringify(receipt)}\n`);
    process.exit(0);
  } catch (error) {
    lastFailure = normalizeFailure(error, attempt);
    process.stderr.write(`${JSON.stringify(lastFailure)}\n`);
    if (lastFailure.code !== "attempt_timeout" || attempt >= maxAttempts) break;
  }
}

process.exitCode = 1;

function runAttempt(attempt) {
  const codexHome = prepareCodexHome();
  const child = spawn("codex", ["app-server", "--analytics-default-enabled"], {
    cwd: process.cwd(),
    detached: true,
    env: codexHome.env,
    stdio: ["pipe", "pipe", "pipe"],
  });
  const turns = expectedTurns.map((turnSpec, index) => {
    const model = turnSpec.model;
    const defaultPrompt =
      index === 0
        ? `The verification code for this thread is ${contextCode}. It is the only string that starts with CODEX_GATEWAY_CONTEXT_. Remember that exact code for later turns. Reply only OK_GPT_CONTEXT_STORED.`
        : index === expectedRoutes.length - 1
          ? "Reply only with the earlier CODEX_GATEWAY_CONTEXT_ code, a vertical bar, and the number of completed assistant replies before this turn."
          : "Find the earlier verification code that starts with CODEX_GATEWAY_CONTEXT_. Reply only that full code string. Do not reply with OK_GPT_CONTEXT_STORED.";
    const defaultExpected =
      index === 0
        ? "OK_GPT_CONTEXT_STORED"
        : index === expectedRoutes.length - 1
          ? `${contextCode}|${expectedRoutes.length - 1}`
          : contextCode;
    const defaultRequiredText =
      index === 0
        ? []
        : [contextCode];
    if (index === 0) {
      return {
        ...turnSpec,
        text: turnSpec.prompt ?? defaultPrompt,
        expect: turnSpec.expectProvided
          ? turnSpec.expect
          : defaultExpected,
        requiredText:
          turnSpec.requiredTextProvided
            ? turnSpec.requiredText
            : defaultRequiredText,
      };
    }
    if (index === expectedRoutes.length - 1) {
      return {
        ...turnSpec,
        text: turnSpec.prompt ?? defaultPrompt,
        expect: turnSpec.expectProvided
          ? turnSpec.expect
          : defaultExpected,
        requiredText:
          turnSpec.requiredTextProvided
            ? turnSpec.requiredText
            : defaultRequiredText,
      };
    }
    return {
      ...turnSpec,
      text: turnSpec.prompt ?? defaultPrompt,
      expect: turnSpec.expectProvided
        ? turnSpec.expect
        : defaultExpected,
      requiredText:
        turnSpec.requiredTextProvided
          ? turnSpec.requiredText
          : defaultRequiredText,
    };
  });

  return new Promise((resolve, reject) => {
    const state = {
      buffer: "",
      currentTurn: -1,
      finished: false,
      threadID: null,
      threadProvider: null,
      attempt,
      baselineContractIdentity: null,
      orderedRoutes: [],
      orderedTurns: [],
      pendingAgent: null,
      responseIDs: new Set(),
      turnIDs: new Set(),
      gatewayResponseIDs: new Set(),
      currentTurnStartedAtMS: null,
      currentFirstActivityAtMS: null,
      currentHeartbeatCount: 0,
      currentEvidence: emptyTurnEvidence(),
    };
    const timer = setTimeout(
      () => finish(new AttemptFailure("attempt_timeout")),
      attemptTimeoutMS,
    );

    child.stdout.setEncoding("utf8");
    child.stdout.on("data", chunk => {
      state.buffer += chunk;
      let newline;
      while ((newline = state.buffer.indexOf("\n")) >= 0) {
        const line = state.buffer.slice(0, newline).trim();
        state.buffer = state.buffer.slice(newline + 1);
        if (!line) continue;
        let message;
        try {
          message = JSON.parse(line);
        } catch {
          finish(new AttemptFailure("malformed_app_server_message"));
          return;
        }
        handleMessage(message);
        if (state.finished) return;
      }
    });
    child.stdout.on("error", () => {
      finish(new AttemptFailure("app_server_stdout_error"));
    });
    child.stderr.on("data", () => {
      // Diagnostics stay private to the child unless the attempt itself fails.
    });
    child.on("error", () => {
      finish(new AttemptFailure("app_server_spawn_failed"));
    });
    child.on("exit", (code, signal) => {
      if (!state.finished) {
        finish(new AttemptFailure(
          "app_server_exited_early",
          `code=${code ?? "null"} signal=${signal ?? "null"}`,
        ));
      }
    });

    send("initialize", {
      clientInfo: {
        name: "tatwo-app-server-same-thread-smoke",
        title: "Tatwo App Server Same Thread Smoke",
        version: "1.0.0",
      },
      capabilities: {
        experimentalApi: true,
        requestAttestation: false,
        optOutNotificationMethods: [],
      },
    }, "init");

    function send(method, params, id) {
      if (state.finished) return;
      child.stdin.write(`${JSON.stringify({ id, method, params })}\n`);
    }

    function notify(method, params) {
      if (state.finished) return;
      child.stdin.write(`${JSON.stringify({ method, params })}\n`);
    }

    function startNextTurn() {
      state.currentTurn += 1;
      state.pendingAgent = null;
      const turn = turns[state.currentTurn];
      if (!turn) {
        finish(null, {
          threadID: state.threadID,
          threadProvider: state.threadProvider,
          orderedRoutes: state.orderedRoutes,
          orderedTurns: state.orderedTurns,
        });
        return;
      }
      state.currentTurnStartedAtMS = Date.now();
      state.currentFirstActivityAtMS = null;
      state.currentHeartbeatCount = 0;
      state.currentEvidence = emptyTurnEvidence();
      send("turn/start", turnParams(turn), `turn-${state.currentTurn}`);
    }

    function turnParams(turn) {
      return {
        threadId: state.threadID,
        input: [{ type: "text", text: turn.text, text_elements: [] }],
        responsesapiClientMetadata: null,
        additionalContext: null,
        environments: null,
        cwd: null,
        runtimeWorkspaceRoots: null,
        approvalPolicy: null,
        approvalsReviewer: null,
        sandboxPolicy: null,
        permissions: null,
        model: turn.model,
        effort: turn.effort,
        summary: null,
        personality: null,
        outputSchema: null,
        collaborationMode: null,
      };
    }

    function handleMessage(message) {
      if (message.id === "init") {
        notify("initialized", {});
        send("thread/start", {
          model: expectedRoutes[0],
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

      if (message.id === "thread-start") {
        state.threadID = nonEmpty(message.result?.thread?.id);
        state.threadProvider = nonEmpty(
          message.result?.thread?.modelProvider ?? message.result?.modelProvider,
        );
        if (!state.threadID || state.threadProvider !== "model_gateway") {
          finish(new AttemptFailure("invalid_model_gateway_thread"));
          return;
        }
        startNextTurn();
        return;
      }

      if (message.error || message.method === "error") {
        finish(new AttemptFailure(
          "app_server_protocol_error",
          nonEmpty(message.error?.message ?? message.params?.message) ?? "",
        ));
        return;
      }

      if (state.currentTurn >= 0) {
        const method = String(message.method ?? "").toLowerCase();
        if (
          method
          && !["item/completed", "turn/completed"].includes(method)
        ) {
          state.currentFirstActivityAtMS ??= Date.now();
        }
        if (
          method.includes("in_progress")
          || method.includes("inprogress")
          || message.params?.heartbeat === true
        ) {
          state.currentHeartbeatCount += 1;
        }
        mergeTurnEvidence(state.currentEvidence, message);
      }

      if (message.method === "item/completed") {
        if (message.params?.threadId !== state.threadID) {
          finish(new AttemptFailure("thread_changed_during_attempt"));
          return;
        }
        const item = message.params?.item;
        if (item?.type !== "agentMessage") return;
        if (state.pendingAgent) {
          finish(new AttemptFailure("multiple_agent_messages_for_turn"));
          return;
        }
        const responseID = nonEmpty(item.id);
        const turnID = nonEmpty(message.params?.turnId);
        if (!responseID || !turnID) {
          finish(new AttemptFailure("missing_response_or_turn_id"));
          return;
        }
        if (state.responseIDs.has(responseID)) {
          finish(new AttemptFailure("duplicate_response_id"));
          return;
        }
        state.pendingAgent = {
          responseID,
          turnID,
          text: String(item.text ?? "").trim(),
        };
        state.currentFirstActivityAtMS ??= Date.now();
        mergeTurnEvidence(state.currentEvidence, item);
        return;
      }

      if (message.method === "turn/completed") {
        if (message.params?.threadId !== state.threadID) {
          finish(new AttemptFailure("thread_changed_during_attempt"));
          return;
        }
        const turn = turns[state.currentTurn];
        const completed = message.params?.turn;
        const completedTurnID = nonEmpty(completed?.id);
        if (
          !turn
          || completed?.status !== "completed"
          || completed?.error
          || !completedTurnID
          || !state.pendingAgent
          || state.pendingAgent.turnID !== completedTurnID
        ) {
          finish(new AttemptFailure("turn_not_terminally_completed"));
          return;
        }
        if (turn.expect && state.pendingAgent.text !== turn.expect) {
          finish(new AttemptFailure(
            "unexpected_assistant_reply",
            [
              `turn=${state.currentTurn}`,
              `model=${turn.model}`,
              `expected_sha256=${sha256(turn.expect)}`,
              `actual_sha256=${sha256(state.pendingAgent.text)}`,
            ].join(" "),
          ));
          return;
        }
        const missingRequiredText = turn.requiredText.filter(
          requiredText => !state.pendingAgent.text.includes(requiredText),
        );
        if (missingRequiredText.length > 0) {
          finish(new AttemptFailure(
            "required_reply_text_missing",
            [
              `turn=${state.currentTurn}`,
              `model=${turn.model}`,
              `missing_sha256=${missingRequiredText.map(sha256).join(",")}`,
            ].join(" "),
          ));
          return;
        }
        const outputBytes = Buffer.byteLength(state.pendingAgent.text, "utf8");
        if (outputBytes < turn.minOutputBytes) {
          finish(new AttemptFailure(
            "minimum_output_bytes_not_met",
            [
              `turn=${state.currentTurn}`,
              `model=${turn.model}`,
              `minimum=${turn.minOutputBytes}`,
              `actual=${outputBytes}`,
            ].join(" "),
          ));
          return;
        }
        if (
          requireForwardingEvidence
          && turn.effort
          && state.currentEvidence.forwardedEffort !== turn.effort
        ) {
          finish(new AttemptFailure(
            "reasoning_forwarding_evidence_missing",
            [
              `turn=${state.currentTurn}`,
              `model=${turn.model}`,
              `requested=${turn.effort}`,
              `observed=${state.currentEvidence.forwardedEffort ?? "missing"}`,
            ].join(" "),
          ));
          return;
        }
        if (
          requireForwardingEvidence
          && !turn.effort
          && state.currentEvidence.forwardedEffort
        ) {
          finish(new AttemptFailure(
            "unexpected_reasoning_forwarding_evidence",
            [
              `turn=${state.currentTurn}`,
              `model=${turn.model}`,
              `observed=${state.currentEvidence.forwardedEffort}`,
            ].join(" "),
          ));
          return;
        }
        if (
          requireForwardingEvidence
          && !state.currentEvidence.actualVendorModel
        ) {
          finish(new AttemptFailure(
            "actual_model_evidence_missing",
            `turn=${state.currentTurn} model=${turn.model}`,
          ));
          return;
        }
        if (
          requireForwardingEvidence
          && !vendorModelMatches(
            turn.expectedActualModel,
            state.currentEvidence.actualVendorModel,
          )
        ) {
          finish(new AttemptFailure(
            "actual_model_evidence_mismatch",
            [
              `turn=${state.currentTurn}`,
              `model=${turn.model}`,
              `expected=${turn.expectedActualModel}`,
              `actual=${state.currentEvidence.actualVendorModel ?? "missing"}`,
            ].join(" "),
          ));
          return;
        }
        if (
          requireForwardingEvidence
          && state.currentEvidence.fallbackCount !== 0
        ) {
          finish(new AttemptFailure(
            "fallback_evidence_nonzero_or_missing",
            [
              `turn=${state.currentTurn}`,
              `model=${turn.model}`,
              `fallback_count=${state.currentEvidence.fallbackCount ?? "missing"}`,
            ].join(" "),
          ));
          return;
        }
        if (
          requireForwardingEvidence
          && !state.currentEvidence.gatewayResponseID
        ) {
          finish(new AttemptFailure(
            "gateway_response_id_missing",
            `turn=${state.currentTurn} model=${turn.model}`,
          ));
          return;
        }
        const contractIdentity = contractIdentityFromEvidence(state.currentEvidence);
        if (requireContractContinuity) {
          const contractFailure = contractContinuityFailure(
            contractIdentity,
            expectedContract,
            state.baselineContractIdentity,
          );
          if (contractFailure) {
            finish(new AttemptFailure(
              contractFailure,
              `turn=${state.currentTurn} model=${turn.model}`,
            ));
            return;
          }
          state.baselineContractIdentity ??= contractIdentity;
          if (
            !state.currentEvidence.selectedRoute
            || state.currentEvidence.selectedRoute !== turn.model
          ) {
            finish(new AttemptFailure(
              "selected_route_attestation_missing_or_mismatch",
              `turn=${state.currentTurn} expected=${turn.model} actual=${state.currentEvidence.selectedRoute ?? "missing"}`,
            ));
            return;
          }
          if (
            !state.currentEvidence.canonicalModel
            || !canonicalModelMatches(
              turn.expectedCanonicalModel,
              state.currentEvidence.canonicalModel,
            )
          ) {
            finish(new AttemptFailure(
              "canonical_model_attestation_missing_or_mismatch",
              `turn=${state.currentTurn} expected=${turn.expectedCanonicalModel} actual=${state.currentEvidence.canonicalModel ?? "missing"}`,
            ));
            return;
          }
        }
        if (state.turnIDs.has(completedTurnID)) {
          finish(new AttemptFailure("duplicate_turn_id"));
          return;
        }
        if (
          state.currentEvidence.gatewayResponseID
          && state.gatewayResponseIDs.has(state.currentEvidence.gatewayResponseID)
        ) {
          finish(new AttemptFailure("duplicate_gateway_response_id"));
          return;
        }
        state.responseIDs.add(state.pendingAgent.responseID);
        const terminalAtMS = Date.now();
        const terminalDurationMS =
          state.currentTurnStartedAtMS
            ? Math.max(0, terminalAtMS - state.currentTurnStartedAtMS)
            : null;
        if (
          turn.minDurationMS > 0
          && (terminalDurationMS === null || terminalDurationMS < turn.minDurationMS)
        ) {
          finish(new AttemptFailure(
            "minimum_turn_duration_not_met",
            [
              `turn=${state.currentTurn}`,
              `model=${turn.model}`,
              `minimum=${turn.minDurationMS}`,
              `actual=${terminalDurationMS ?? "missing"}`,
            ].join(" "),
          ));
          return;
        }
        if (state.currentHeartbeatCount < turn.minHeartbeatCount) {
          finish(new AttemptFailure(
            "minimum_heartbeat_count_not_met",
            [
              `turn=${state.currentTurn}`,
              `model=${turn.model}`,
              `minimum=${turn.minHeartbeatCount}`,
              `actual=${state.currentHeartbeatCount}`,
            ].join(" "),
          ));
          return;
        }
        state.turnIDs.add(completedTurnID);
        if (state.currentEvidence.gatewayResponseID) {
          state.gatewayResponseIDs.add(state.currentEvidence.gatewayResponseID);
        }
        const routeReceipt = {
          order: state.currentTurn,
          model: turn.model,
          terminalStatus: "completed",
          responseID: state.pendingAgent.responseID,
        };
        state.orderedRoutes.push(routeReceipt);
        state.orderedTurns.push({
          ...routeReceipt,
          turnID: completedTurnID,
          terminalTurnID: completedTurnID,
          assistantItemID: state.pendingAgent.responseID,
          runID,
          attempt: state.attempt,
          instanceID: contractIdentity.instanceID,
          contractID: contractIdentity.contractID,
          goalID: contractIdentity.goalID,
          contractRevision: contractIdentity.contractRevision,
          selectedRoute: state.currentEvidence.selectedRoute ?? turn.model,
          selectedRouteEvidence:
            state.currentEvidence.selectedRoute ? "app_server_event" : "requested_only",
          canonicalModel:
            state.currentEvidence.canonicalModel ?? turn.expectedCanonicalModel,
          canonicalModelEvidence:
            state.currentEvidence.canonicalModel ? "app_server_event" : "expected_only",
          vendorModel: state.currentEvidence.actualVendorModel,
          promptSource: turn.promptSource,
          promptUTF8Bytes: Buffer.byteLength(turn.text, "utf8"),
          promptSHA256: sha256(turn.text),
          requestedEffort: turn.effort,
          observedEffort: state.currentEvidence.forwardedEffort,
          requestedSpeedTier: turn.speedTier,
          processConfiguredSpeedTier,
          speedTierEvidence:
            turn.speedTier
              ? "process_level_codex_config_pin_not_per_turn_forwarding"
              : "not_requested_for_turn",
          forwardedEffort: state.currentEvidence.forwardedEffort,
          forwardingEvidence:
            state.currentEvidence.forwardedEffort
              ? "gateway_receipt"
              : turn.effort
                ? "not_observed_by_app_server"
                : "not_requested_and_not_observed",
          expectedActualModel: turn.expectedActualModel,
          actualVendorModel: state.currentEvidence.actualVendorModel,
          fallbackCount: state.currentEvidence.fallbackCount,
          fallbackEvidence:
            state.currentEvidence.fallbackCount === null
              ? "missing"
              : state.currentEvidence.fallbackSource ?? "app_server_event",
          gatewayResponseID: state.currentEvidence.gatewayResponseID,
          firstActivityMS:
            state.currentFirstActivityAtMS && state.currentTurnStartedAtMS
              ? Math.max(
                  0,
                  state.currentFirstActivityAtMS - state.currentTurnStartedAtMS,
                )
              : null,
          terminalDurationMS,
          heartbeatCount: state.currentHeartbeatCount,
          outputUTF8Bytes: outputBytes,
          minimumOutputBytes: turn.minOutputBytes,
          minimumDurationMS: turn.minDurationMS,
          minimumHeartbeatCount: turn.minHeartbeatCount,
          replySHA256: sha256(state.pendingAgent.text),
          expectedReplySHA256: turn.expect ? sha256(turn.expect) : null,
          contextContinuityVerified:
            state.currentTurn === 0
              ? state.pendingAgent.text === turn.expect
              : state.pendingAgent.text.includes(contextCode),
        });
        startNextTurn();
      }
    }

    async function finish(error, result = null) {
      if (state.finished) return;
      state.finished = true;
      clearTimeout(timer);
      await terminateProcessGroup(child);
      codexHome.cleanup();
      if (error) reject(error);
      else resolve(result);
    }
  });
}

function prepareCodexHome() {
  const sourceHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
  const tempHome = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-same-thread-"));
  const sourceAuth = path.join(sourceHome, "auth.json");
  const tempAuth = path.join(tempHome, "auth.json");
  if (fs.existsSync(sourceAuth)) fs.symlinkSync(sourceAuth, tempAuth);
  fs.writeFileSync(
    path.join(tempHome, "config.toml"),
    [
      `model = "${expectedRoutes[0]}"`,
      `model_provider = "model_gateway"`,
      `model_reasoning_effort = "low"`,
      `service_tier = "${processConfiguredSpeedTier}"`,
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
  return {
    env: { ...process.env, CODEX_HOME: tempHome },
    cleanup: () => fs.rmSync(tempHome, { recursive: true, force: true }),
  };
}

async function terminateProcessGroup(child) {
  if (!child?.pid || child.exitCode !== null) return;
  const closed = new Promise(resolve => child.once("close", resolve));
  try {
    process.kill(-child.pid, "SIGTERM");
  } catch {
    try { child.kill("SIGTERM"); } catch {}
  }
  if (await settledWithin(closed, 300)) return;
  try {
    process.kill(-child.pid, "SIGKILL");
  } catch {
    try { child.kill("SIGKILL"); } catch {}
  }
  await settledWithin(closed, 300);
}

async function settledWithin(promise, timeoutMS) {
  return await Promise.race([
    promise.then(() => true),
    new Promise(resolve => setTimeout(() => resolve(false), timeoutMS)),
  ]);
}

function gatewayReceiptID(value) {
  return `same-thread-${createHash("sha256")
    .update(JSON.stringify(value))
    .digest("hex")
    .slice(0, 24)}`;
}

function versionedGatewayReceiptID(value) {
  return `same-thread-v2-${createHash("sha256")
    .update(JSON.stringify(value))
    .digest("hex")
    .slice(0, 24)}`;
}

function normalizeFailure(error, attempt) {
  const code = error instanceof AttemptFailure ? error.code : "unexpected_harness_error";
  return {
    schema: "TatwoGatewaySameThreadFailureV1",
    ok: false,
    attempt,
    code,
    ...(error instanceof AttemptFailure && error.detail
      ? { detail: error.detail }
      : {}),
  };
}

function sha256(value) {
  return createHash("sha256")
    .update(String(value ?? ""))
    .digest("hex");
}

function required(name) {
  const value = String(process.env[name] ?? "").trim();
  if (!value) failBeforeStart(`missing_${name.toLowerCase()}`);
  return value;
}

function nonEmpty(value) {
  const text = typeof value === "string" ? value.trim() : "";
  return text || null;
}

function boundedInteger(value, fallback, minimum, maximum) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(minimum, Math.min(maximum, Math.trunc(parsed)));
}

function isUUID(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(String(value));
}

function failBeforeStart(code) {
  process.stderr.write(`${JSON.stringify({
    schema: "TatwoGatewaySameThreadFailureV1",
    ok: false,
    attempt: 0,
    code,
  })}\n`);
  process.exit(1);
}

function loadExpectedTurnsInput() {
  const rawJSON = String(
    process.env.TATWO_SAME_THREAD_EXPECTED_TURNS_JSON ?? "",
  ).trim();
  const filePath = String(
    process.env.TATWO_SAME_THREAD_EXPECTED_TURNS_FILE ?? "",
  ).trim();
  if (rawJSON && filePath) {
    failBeforeStart("expected_turns_source_ambiguous");
  }
  if (rawJSON) {
    try {
      return normalizeExpectedTurnsInput(JSON.parse(rawJSON), {
        source: "env_json",
        baseDirectory: process.cwd(),
      });
    } catch {
      failBeforeStart("invalid_expected_turns_json");
    }
  }
  if (!filePath) {
    return {
      turns: null,
      contract: null,
      requireContractContinuity: false,
      source: "route_list",
      baseDirectory: process.cwd(),
    };
  }
  const resolved = path.resolve(filePath);
  let raw;
  try {
    const stat = fs.statSync(resolved);
    if (!stat.isFile() || stat.size > 20 * 1024 * 1024) {
      failBeforeStart("expected_turns_file_invalid_or_too_large");
    }
    raw = fs.readFileSync(resolved, "utf8");
  } catch {
    failBeforeStart("expected_turns_file_unreadable");
  }
  try {
    return normalizeExpectedTurnsInput(JSON.parse(raw), {
      source: "file",
      baseDirectory: path.dirname(resolved),
    });
  } catch {
    failBeforeStart("invalid_expected_turns_file_json");
  }
}

function normalizeExpectedTurnsInput(value, source) {
  if (Array.isArray(value)) {
    return {
      turns: value,
      contract: null,
      requireContractContinuity: false,
      ...source,
    };
  }
  if (!value || typeof value !== "object" || !Array.isArray(value.turns)) {
    failBeforeStart("expected_turns_document_invalid");
  }
  return {
    turns: value.turns,
    contract: value.contract ?? null,
    requireContractContinuity: value.requireContractContinuity === true,
    ...source,
  };
}

function parseExpectedTurns(input, fallbackRoutes) {
  if (Array.isArray(input?.turns)) {
    if (input.turns.length < 2) {
      failBeforeStart("at_least_two_turns_required");
    }
    return input.turns.map((turn, index) =>
      normalizedTurnSpec(turn, index, input.contract, input.baseDirectory));
  }
  return String(fallbackRoutes)
    .split(",")
    .map(value => value.trim())
    .filter(Boolean)
    .map((model, index) =>
      normalizedTurnSpec({ model }, index, null, process.cwd()));
}

function normalizedTurnSpec(turn, index, inheritedContract, baseDirectory) {
  const model = nonEmpty(turn?.model);
  if (!model) failBeforeStart(`missing_turn_model_${index}`);
  const defaults = defaultTurnControls(model);
  const hasEffort = Object.prototype.hasOwnProperty.call(turn ?? {}, "effort");
  const effort = hasEffort
    ? normalizeEffort(turn?.effort)
    : defaults.effort;
  if (hasEffort && turn?.effort != null && !effort) {
    failBeforeStart(`invalid_turn_effort_${index}`);
  }
  const hasSpeedTier = Object.prototype.hasOwnProperty.call(turn ?? {}, "speedTier");
  const speedTier = hasSpeedTier
    ? normalizeSpeedTier(turn?.speedTier)
    : defaults.speedTier;
  if (hasSpeedTier && turn?.speedTier != null && !speedTier) {
    failBeforeStart(`invalid_turn_speed_tier_${index}`);
  }
  const expectedActualModel =
    nonEmpty(turn?.expectedActualModel)
    ?? defaults.expectedActualModel;
  const expectedCanonicalModel =
    nonEmpty(turn?.expectedCanonicalModel)
    ?? defaults.expectedCanonicalModel;
  const hasInlinePrompt =
    Object.prototype.hasOwnProperty.call(turn ?? {}, "prompt")
    || Object.prototype.hasOwnProperty.call(turn ?? {}, "text");
  const hasPromptFile = Object.prototype.hasOwnProperty.call(turn ?? {}, "promptFile");
  if (hasInlinePrompt && hasPromptFile) {
    failBeforeStart(`turn_prompt_source_ambiguous_${index}`);
  }
  const promptFromFile = hasPromptFile
    ? readTurnPromptFile(turn?.promptFile, baseDirectory, index)
    : null;
  const prompt = hasPromptFile
    ? promptFromFile
    : nonEmpty(turn?.prompt ?? turn?.text);
  const contract = normalizeContractExpectation(
    {
      contractID: turn?.contractID ?? inheritedContract?.contractID,
      goalID: turn?.goalID ?? inheritedContract?.goalID,
      contractRevision:
        turn?.contractRevision ?? inheritedContract?.contractRevision,
      instanceID: turn?.instanceID ?? inheritedContract?.instanceID,
    },
    false,
  );
  const expectProvided = Object.prototype.hasOwnProperty.call(
    turn ?? {},
    "expect",
  );
  const expect =
    turn?.expect === null
      ? null
      : nonEmpty(turn?.expect);
  const requiredTextProvided = Object.prototype.hasOwnProperty.call(
    turn ?? {},
    "requiredText",
  );
  const requiredText = normalizeRequiredText(turn?.requiredText, index);
  const minOutputBytes = boundedInteger(
    turn?.minOutputBytes,
    1,
    1,
    10_000_000,
  );
  const minDurationMS = boundedInteger(
    turn?.minDurationMS,
    0,
    0,
    900_000,
  );
  const minHeartbeatCount = boundedInteger(
    turn?.minHeartbeatCount,
    0,
    0,
    100_000,
  );
  return {
    model,
    effort,
    speedTier,
    expectedActualModel,
    expectedCanonicalModel,
    prompt,
    promptSource: hasPromptFile
      ? "file"
      : prompt
        ? "inline"
        : "default",
    promptUTF8Bytes: prompt ? Buffer.byteLength(prompt, "utf8") : null,
    promptSHA256: prompt ? sha256(prompt) : null,
    ...contract,
    expect,
    expectProvided,
    requiredText,
    requiredTextProvided,
    minOutputBytes,
    minDurationMS,
    minHeartbeatCount,
  };
}

function defaultTurnControls(model) {
  const normalized = String(model ?? "").trim().toLowerCase();
  if (normalized === "gpt-5.6-sol") {
    return {
      effort: "low",
      speedTier: "fast",
      expectedActualModel: "gpt-5.6-sol",
      expectedCanonicalModel: "gpt-5.6-sol",
    };
  }
  if (normalized === "gpt-5.6-luna") {
    return {
      effort: "xhigh",
      speedTier: null,
      expectedActualModel: "gpt-5.6-luna",
      expectedCanonicalModel: "gpt-5.6-luna",
    };
  }
  if (normalized === "fable-5") {
    return {
      effort: null,
      speedTier: null,
      expectedActualModel: "claude-fable-5",
      expectedCanonicalModel: "fable-5",
    };
  }
  if (normalized === "opus-5") {
    return {
      effort: "high",
      speedTier: null,
      expectedActualModel: "claude-opus-5",
      expectedCanonicalModel: "opus-5",
    };
  }
  if (normalized === "grok-build") {
    return {
      effort: "xhigh",
      speedTier: null,
      expectedActualModel: "grok-4.6",
      expectedCanonicalModel: "grok-build",
    };
  }
  return {
    effort: null,
    speedTier: null,
    expectedActualModel: normalized,
    expectedCanonicalModel: normalized,
  };
}

function normalizeRequiredText(value, index) {
  if (value === undefined || value === null) return [];
  const values = Array.isArray(value) ? value : [value];
  const normalized = values.map(nonEmpty).filter(Boolean);
  if (normalized.length !== values.length) {
    failBeforeStart(`invalid_required_text_${index}`);
  }
  return normalized;
}

function vendorModelMatches(expected, actual) {
  const normalizedExpected = String(expected ?? "").trim().toLowerCase();
  const normalizedActual = String(actual ?? "").trim().toLowerCase();
  if (!normalizedExpected || !normalizedActual) return false;
  if (normalizedExpected === "grok-4.6") {
    return normalizedActual === "grok-4.6";
  }
  if (normalizedExpected === "claude-fable-5") {
    return /^claude-fable-5(?:-\d{8})?$/.test(normalizedActual);
  }
  if (normalizedExpected === "claude-opus-5") {
    return /^claude-opus-5(?:-\d{8})?$/.test(normalizedActual);
  }
  return normalizedActual === normalizedExpected;
}

function normalizeEffort(value) {
  const raw = String(value ?? "").trim().toLowerCase();
  return ["low", "medium", "high", "xhigh"].includes(raw) ? raw : null;
}

function normalizeSpeedTier(value) {
  const raw = String(value ?? "").trim().toLowerCase();
  return ["fast", "standard"].includes(raw) ? raw : null;
}

function emptyTurnEvidence() {
  return {
    forwardedEffort: null,
    actualVendorModel: null,
    canonicalModel: null,
    selectedRoute: null,
    fallbackCount: null,
    fallbackSource: null,
    gatewayResponseID: null,
    contractID: null,
    goalID: null,
    contractRevision: null,
    instanceID: null,
  };
}

function mergeTurnEvidence(target, value) {
  if (!value || typeof value !== "object") return;
  const candidates = [
    value,
    value.params,
    value.params?.item,
    value.params?.turn,
    value.result,
    value.response,
  ].filter(candidate => candidate && typeof candidate === "object");
  for (const candidate of candidates) {
    const reasoning =
      candidate.reasoning
      ?? candidate.reasoning_control
      ?? candidate.reasoningControl;
    const forwarded = normalizeEffort(
      reasoning?.normalized
      ?? reasoning?.forwardedEffort
      ?? reasoning?.forwarded_effort,
    );
    if (
      forwarded
      && (
        reasoning?.forwarded === true
        || reasoning?.forwardedNativeField === true
        || reasoning?.forwarded_native_field === true
      )
    ) {
      target.forwardedEffort = forwarded;
    }
    target.actualVendorModel ??= nonEmpty(
      candidate.actual_model
      ?? candidate.actualModel
      ?? candidate.model_attestation?.actual_vendor_model
      ?? candidate.modelAttestation?.actualVendorModel,
    );
    target.canonicalModel ??= nonEmpty(
      candidate.canonical_model
      ?? candidate.canonicalModel
      ?? candidate.model_attestation?.actual_canonical_model
      ?? candidate.modelAttestation?.actualCanonicalModel,
    );
    target.selectedRoute ??= nonEmpty(
      candidate.selected_route
      ?? candidate.selectedRoute
      ?? candidate.route_id
      ?? candidate.routeID
      ?? candidate.model_route
      ?? candidate.modelRoute,
    );
    const fallback = Number(
      candidate.fallback_count
      ?? candidate.fallbackCount
      ?? candidate.model_attestation?.fallback_count
      ?? candidate.modelAttestation?.fallbackCount,
    );
    if (Number.isFinite(fallback)) {
      target.fallbackCount = Math.max(0, fallback);
      target.fallbackSource ??= "app_server_event";
    }
    target.gatewayResponseID ??= nonEmpty(
      candidate.response_id
      ?? candidate.responseId
      ?? candidate.response?.id,
    );
    target.contractID ??= nonEmpty(
      candidate.contract_id
      ?? candidate.contractID
      ?? candidate.work_os_contract_id
      ?? candidate.workOSContractID,
    );
    target.goalID ??= nonEmpty(
      candidate.goal_id
      ?? candidate.goalID
      ?? candidate.work_os_goal_id
      ?? candidate.workOSGoalID,
    );
    target.contractRevision ??= nonEmpty(
      candidate.contract_revision
      ?? candidate.contractRevision
      ?? candidate.work_os_contract_revision
      ?? candidate.workOSContractRevision
      ?? candidate.revision,
    );
    target.instanceID ??= nonEmpty(
      candidate.instance_id
      ?? candidate.instanceID
      ?? candidate.app_instance_id
      ?? candidate.appInstanceID,
    );
  }
}

function contractIdentityFromEvidence(evidence) {
  return {
    contractID: evidence.contractID,
    goalID: evidence.goalID,
    contractRevision: evidence.contractRevision,
    instanceID: evidence.instanceID,
  };
}

function contractContinuityFailure(actual, expected, baseline) {
  if (
    !actual.contractID
    || !actual.goalID
    || !actual.contractRevision
    || !actual.instanceID
  ) {
    return "contract_continuity_attestation_missing";
  }
  for (const field of ["contractID", "goalID", "contractRevision", "instanceID"]) {
    if (expected[field] && actual[field] !== expected[field]) {
      return "contract_continuity_expected_identity_mismatch";
    }
    if (baseline?.[field] && actual[field] !== baseline[field]) {
      return "contract_continuity_churn_detected";
    }
  }
  return null;
}

function canonicalModelMatches(expected, actual) {
  return String(expected ?? "").trim().toLowerCase()
    === String(actual ?? "").trim().toLowerCase();
}

function readTurnPromptFile(value, baseDirectory, index) {
  const rawPath = nonEmpty(value);
  if (!rawPath) failBeforeStart(`turn_prompt_file_missing_${index}`);
  const resolved = path.resolve(baseDirectory, rawPath);
  try {
    const stat = fs.statSync(resolved);
    if (!stat.isFile() || stat.size > 20 * 1024 * 1024) {
      failBeforeStart(`turn_prompt_file_invalid_or_too_large_${index}`);
    }
    const text = fs.readFileSync(resolved, "utf8");
    if (!text.trim()) failBeforeStart(`turn_prompt_file_empty_${index}`);
    return text;
  } catch {
    failBeforeStart(`turn_prompt_file_unreadable_${index}`);
  }
}

function normalizeContractExpectation(value, required) {
  const contractID = nonEmpty(value?.contractID ?? value?.contract_id);
  const goalID = nonEmpty(value?.goalID ?? value?.goal_id);
  const contractRevision = nonEmpty(
    value?.contractRevision ?? value?.contract_revision ?? value?.revision,
  );
  const instanceID = nonEmpty(value?.instanceID ?? value?.instance_id);
  if (
    required
    && (!contractID || !goalID || !contractRevision || !instanceID)
  ) {
    failBeforeStart("contract_continuity_identity_missing");
  }
  return { contractID, goalID, contractRevision, instanceID };
}
