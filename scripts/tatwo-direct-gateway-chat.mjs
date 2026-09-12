#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import https from "node:https";
import path from "node:path";

const MAX_PROMPT_UTF8_BYTES = 8 * 1024 * 1024;
const MAX_CONTINUATION_UTF8_BYTES = 16 * 1024;

const args = parseArgs(process.argv.slice(2));
const model = String(args.model ?? args.m ?? "").trim();
let prompt = "";
let promptTransport = null;
let promptLoadError = null;
try {
  promptTransport = readPromptInput(args);
  prompt = promptTransport.prompt;
} catch (error) {
  promptLoadError = error;
}
let continuationRequest = null;
let continuationLoadError = null;
try {
  continuationRequest = readContinuationInput(args);
} catch (error) {
  continuationLoadError = error;
}
const dispatchID = String(args.dispatchId ?? args["dispatch-id"] ?? "").trim();
const reasoningEffort = normalizeReasoningEffort(args.reasoningEffort ?? args["reasoning-effort"] ?? args.effort ?? process.env.TATWO_DIRECT_GATEWAY_REASONING_EFFORT);
const speedTier = normalizeSpeedTier(args.speedTier ?? args["speed-tier"] ?? args.serviceTier ?? args["service-tier"] ?? process.env.TATWO_DIRECT_GATEWAY_SERVICE_TIER);
let currentTurnAuthority = null;
let currentTurnAuthorityError = null;
try {
  currentTurnAuthority = normalizeCurrentTurnAuthority({
    runID: args.runId ?? args["run-id"],
    turnID: args.turnId ?? args["turn-id"],
    currentVisibleTurnSHA256:
      args.currentTurnSha256 ?? args["current-turn-sha256"],
    currentVisibleTurnUTF8Bytes:
      args.currentTurnBytes ?? args["current-turn-bytes"],
  });
} catch (error) {
  currentTurnAuthorityError = error;
}
let computerHostRoute = "none";
let computerHostRouteError = null;
try {
  computerHostRoute = normalizeComputerHostRoute(
    args.computerHostRoute ?? args["computer-host-route"],
  );
} catch (error) {
  computerHostRouteError = error;
}
const imagePaths = arrayArg(args.image);
const endpoint = String(args.endpoint ?? process.env.TATWO_MODEL_GATEWAY_RESPONSES_URL ?? "http://127.0.0.1:4177/v1/responses");
// Socket inactivity timeout, not a total-turn deadline. Semantic SSE
// heartbeats keep a healthy long office turn alive; a truly silent route is
// still bounded to the same 10-minute window as the App runner watchdog.
const timeoutMs = Number(args.timeoutMs ?? args["timeout-ms"] ?? process.env.TATWO_DIRECT_GATEWAY_TIMEOUT_MS ?? 600000);
const threadID = `tatwo-gateway-${shortHash(`${model}|${Date.now()}|${prompt.slice(0, 80)}`)}`;

emit({ type: "thread.started", thread_id: threadID });
emit({ type: "turn.started" });

if (
  !model
  || promptLoadError
  || continuationLoadError
  || currentTurnAuthorityError
  || computerHostRouteError
  || !prompt.trim()
) {
  emitFailure(
    promptLoadError?.message
    ?? continuationLoadError?.message
    ?? currentTurnAuthorityError?.message
    ?? computerHostRouteError?.message
    ?? "missing_model_or_prompt",
  );
  process.exit(2);
}
emit({
  type: "system",
  control_type: "prompt.transport",
  transport: promptTransport.transport,
  prompt_sha256: promptTransport.sha256,
  prompt_utf8_bytes: promptTransport.utf8Bytes,
  argv_prompt_content: promptTransport.argvPromptContent,
  environment_prompt_content: false,
  verified: true,
});

try {
  const payload = buildGatewayPayload(model, prompt, {
    reasoningEffort,
    speedTier,
    currentTurnAuthority,
    computerHostRoute,
    continuationRequest,
    images: readImageInputs(imagePaths),
  });
  const response = await postJSON(
    endpoint,
    payload,
    timeoutMs,
    emitNormalizedStreamingEvent,
  );
  const outputText = extractOutputText(response.body);
  const responseID = String(response.body?.id ?? response.body?.response_id ?? "").trim();
  if (response.statusCode < 200 || response.statusCode >= 300) {
    emitFailure(outputText || `gateway_http_${response.statusCode}`);
    process.exit(2);
  }
  const terminalFailure = terminalFailureMessage(response.body);
  if (terminalFailure) {
    emitFailure(terminalFailure);
    process.exit(2);
  }
  const pendingToolCalls = unexecutedToolCalls(response.body);
  if (pendingToolCalls.length > 0) {
    const names = [...new Set(
      pendingToolCalls
        .map(call => String(call.name ?? "").trim())
        .filter(Boolean),
    )].slice(0, 8);
    emitFailure(
      "gateway_returned_unexecuted_tool_calls: "
      + `count=${pendingToolCalls.length}`
      + (names.length ? ` names=${names.join(",")}` : ""),
    );
    process.exit(2);
  }
  const appliedRouteReceipt = verifyAppliedComputerHostRouteReceipt(
    response.body,
    currentTurnAuthority,
    computerHostRoute,
  );
  if (!outputText) {
    // 附回應結構鍵名，讓未來「無回覆」失敗可自我診斷（是真的空，還是我們漏認某模型的回覆結構）。
    const shapeHint = response.body && typeof response.body === "object"
      ? Object.keys(response.body).join(",")
      : String(typeof response.body);
    emitFailure(`gateway_completed_without_output_text (response keys: ${shapeHint})`);
    process.exit(2);
  }
  const operationalFailure =
    structuredOperationalFailureKind(response.body)
    || operationalFailureKind(outputText);
  const outputDelivery = outputDeliveryReceipt(response.streaming, outputText);
  if (outputDelivery.mode === "delta" && outputDelivery.delta_matches_final !== true) {
    emitFailure(
      "gateway_stream_output_mismatch: "
      + `delta_bytes=${outputDelivery.delta_utf8_bytes} `
      + `final_bytes=${outputDelivery.final_utf8_bytes}`,
    );
    process.exit(2);
  }
  if (operationalFailure) {
    emitTerminalFallbackIfNeeded(outputText, outputDelivery, dispatchID);
    emit({
      type: "turn.completed",
      usage: response.body?.usage ?? null,
      model,
      ...(dispatchID ? { dispatch_id: dispatchID } : {}),
      ...(responseID ? { response_id: responseID } : {}),
      computer_host_authority: appliedRouteReceipt,
      degraded: true,
      error_kind: operationalFailure,
      retry_allowed: false,
      output_delivery: outputDelivery,
      ...terminalRecoveryMetadata(response.body, outputText)
    });
    process.exit(0);
  }
  const modelAttestation = providerModelAttestation(response.body, model);
  if (modelAttestation.outcome !== "VERIFIED_EXACT") {
    emitFailure(
      `gateway_model_attestation_${modelAttestation.outcome.toLowerCase()}: `
      + `requested=${modelAttestation.requested_model} `
      + `observed=${modelAttestation.observed_models.join(",") || "missing"} `
      + `usage=${modelAttestation.model_usage_keys.join(",") || "missing"} `
      + `fallbacks=${modelAttestation.fallback_count}`);
    process.exit(2);
  }
  const continuationReceipt = continuationRequest
    ? verifyGatewayContinuationReceipt(
        response.body,
        continuationRequest,
        modelAttestation,
      )
    : null;
  const reasoningControl = gatewayReasoningControlReceipt(
    response.body,
    model,
    reasoningEffort,
  );
  if (
    reasoningEffort
    && isExternalGatewayReasoningModel(model)
    && reasoningControl.forwarded !== true
  ) {
    emitFailure(
      "gateway_reasoning_forwarding_attestation_missing_or_mismatch: "
      + `requested=${reasoningEffort} `
      + `normalized=${reasoningControl.normalized ?? "missing"} `
      + `provider=${reasoningControl.provider ?? "missing"} `
      + `cli_flag=${reasoningControl.cli_flag ?? "missing"}`,
    );
    process.exit(2);
  }
  emitTerminalFallbackIfNeeded(outputText, outputDelivery, dispatchID);
  emit({
    type: "turn.completed",
    usage: response.body?.usage ?? null,
    model: modelAttestation.actual_canonical_model,
    requested_model: model,
    actual_model: modelAttestation.actual_vendor_model,
    model_attestation: modelAttestation,
    output_delivery: outputDelivery,
    ...(dispatchID ? { dispatch_id: dispatchID } : {}),
    ...(responseID ? { response_id: responseID } : {}),
    computer_host_authority: appliedRouteReceipt,
    ...(continuationReceipt
      ? { gateway_continuation: continuationReceipt }
      : {}),
    reasoning: {
      requested: reasoningEffort,
      normalized: reasoningControl.normalized,
      requestFieldForwarded: Boolean(
        reasoningEffort && gatewaySupportsReasoningControl(model),
      ),
      forwardedNativeField: reasoningControl.forwarded,
      provider: reasoningControl.provider,
      cliFlag: reasoningControl.cli_flag,
      effectiveProviderAttested: reasoningControl.effective_attested,
      adapter: reasoningControl.adapter,
    },
    speed: {
      requested: speedTier,
      forwardedNativeField: Boolean(speedTier && isGPTGatewayModel(model)),
      adapter: speedTier
        ? (isGPTGatewayModel(model) ? "gateway.service_tier" : "not_forwarded_no_native_gateway_control")
        : "not_requested"
    }
  });
  process.exit(0);
} catch (error) {
  emitFailure(error?.message ?? String(error));
  process.exit(2);
}

function emitFailure(message) {
  emit({
    type: "response.failed",
    ...(dispatchID ? { dispatch_id: dispatchID } : {}),
    error: {
      message: sanitize(String(message ?? "gateway_failed"))
    }
  });
}

function emitAssistantMessage(text, receiptDispatchID = "") {
  emit({
    type: "item.completed",
    ...(receiptDispatchID ? { dispatch_id: receiptDispatchID } : {}),
    item: {
      id: `item_${shortHash(text)}`,
      type: "agent_message",
      text
    }
  });
}

function emitTerminalFallbackIfNeeded(text, delivery, receiptDispatchID = "") {
  if (delivery.mode === "terminal_fallback") {
    emitAssistantMessage(text, receiptDispatchID);
  }
}

function outputDeliveryReceipt(streaming, outputText) {
  const deltaEventCount = Number(streaming?.deltaEventCount ?? 0);
  const deltaText = String(streaming?.deltaText ?? "");
  const finalText = String(outputText ?? "");
  const deltaUTF8Bytes = Buffer.byteLength(deltaText);
  const streamed = streaming?.streamed === true;
  const mode = streamed && deltaUTF8Bytes > 0
    ? "delta"
    : "terminal_fallback";
  return {
    mode,
    streamed,
    delta_event_count: deltaEventCount,
    delta_utf8_bytes: deltaUTF8Bytes,
    final_utf8_bytes: Buffer.byteLength(finalText),
    delta_matches_final: mode === "delta" ? deltaText === finalText : null,
  };
}

function emitNormalizedStreamingEvent(event) {
  const controlType = String(event?.type ?? "").trim();
  if (!controlType) return;
  const response = event?.response && typeof event.response === "object"
    ? event.response
    : null;
  const responseID = String(
    event?.response_id
    ?? response?.id
    ?? event?.item?.response_id
    ?? "",
  ).trim();
  const common = {
    ...(dispatchID ? { dispatch_id: dispatchID } : {}),
    ...(responseID ? { response_id: responseID } : {}),
  };
  if (controlType === "response.output_text.delta") {
    emit({
      type: controlType,
      ...common,
      delta: String(event?.delta ?? ""),
    });
    return;
  }
  emit({
    type: "system",
    control_type: controlType,
    ...common,
    status: String(response?.status ?? event?.status ?? "").trim() || null,
    heartbeat: event?.heartbeat === true,
    source: String(event?.source ?? "model_gateway_sse"),
    ...normalizedStreamingOutputItemMetadata(event?.item),
  });
}

function normalizedStreamingOutputItemMetadata(item) {
  if (!item || typeof item !== "object") return {};
  return {
    item_id: String(item.id ?? "").trim() || null,
    item_type: String(item.type ?? "").trim() || null,
  };
}

function structuredOperationalFailureKind(body) {
  if (!body || typeof body !== "object") return null;
  const rawKind = String(body.error_kind ?? body.errorKind ?? "").trim().toLowerCase();
  if (rawKind) return normalizeOperationalFailureKind(rawKind);
  if (body.degraded === true) return "backend_unavailable";
  return null;
}

function normalizeOperationalFailureKind(value) {
  const normalized = String(value ?? "").trim().toLowerCase().replace(/[\s-]+/g, "_");
  if (normalized.includes("session") && normalized.includes("limit")) return "session_limit";
  if (normalized.includes("rate") && normalized.includes("limit")) return "rate_limit";
  if (normalized.includes("quota") || normalized.includes("credit") || normalized.includes("billing")) return "quota";
  if (normalized.includes("timeout")) return "timeout";
  return normalized || "backend_unavailable";
}

function terminalRecoveryMetadata(body, outputText = "") {
  const resetAt = String(body?.reset_at ?? body?.resetAt ?? "").trim()
    || inferredResetAt(outputText);
  return resetAt ? { reset_at: resetAt } : {};
}

function inferredResetAt(value) {
  const text = String(value ?? "");
  const match = text.match(/\bresets?\s+([0-9]{1,2}:[0-9]{2}\s*(?:am|pm)?(?:\s*\([^)]+\))?)/i)
    || text.match(/\breset\s+([0-9]{4}-[0-9]{2}-[0-9]{2}T[^\s;]+)/i);
  return String(match?.[1] ?? "").trim();
}

function extractOutputText(value) {
  if (!value) return "";
  // Responses API 原生
  if (typeof value.output_text === "string" && value.output_text.trim()) return value.output_text;
  if (typeof value.error?.message === "string") return value.error.message;
  if (typeof value.message === "string") return value.message;
  if (Array.isArray(value.output)) {
    const parts = [];
    for (const item of value.output) {
      if (typeof item?.text === "string") parts.push(item.text);
      if (Array.isArray(item?.content)) {
        for (const content of item.content) {
          if (typeof content === "string") parts.push(content);
          else if (typeof content?.text === "string") parts.push(content.text);
        }
      }
    }
    if (parts.length) return parts.join("");
  }
  // OpenAI Chat Completions 相容（grok/minimax 常走此結構，之前被漏 → 假「無回覆」）：
  // choices[].message.content / choices[].delta.content / choices[].text，content 可為字串或多模態陣列。
  if (Array.isArray(value.choices)) {
    const parts = [];
    for (const choice of value.choices) {
      const c = choice?.message?.content ?? choice?.delta?.content ?? choice?.text;
      if (typeof c === "string" && c) parts.push(c);
      else if (Array.isArray(c)) {
        for (const part of c) {
          if (typeof part === "string") parts.push(part);
          else if (typeof part?.text === "string") parts.push(part.text);
        }
      }
    }
    if (parts.length) return parts.join("");
  }
  // 頂層 content（字串或陣列）
  if (typeof value.content === "string" && value.content.trim()) return value.content;
  if (Array.isArray(value.content)) {
    const parts = value.content
      .map((c) => (typeof c === "string" ? c : typeof c?.text === "string" ? c.text : ""))
      .filter(Boolean);
    if (parts.length) return parts.join("");
  }
  return "";
}

function unexecutedToolCalls(value) {
  if (!value || typeof value !== "object") return [];
  const calls = [];
  const append = (candidate, fallbackName = "") => {
    if (!candidate || typeof candidate !== "object") return;
    const nested = candidate.function && typeof candidate.function === "object"
      ? candidate.function
      : null;
    const name = String(
      nested?.name
      ?? candidate.name
      ?? candidate.tool_name
      ?? candidate.toolName
      ?? fallbackName,
    ).trim();
    calls.push({ name });
  };
  const appendArray = candidates => {
    if (!Array.isArray(candidates)) return;
    for (const candidate of candidates) append(candidate);
  };

  appendArray(value.tool_calls);
  appendArray(value.toolCalls);
  if (Array.isArray(value.choices)) {
    for (const choice of value.choices) {
      appendArray(choice?.message?.tool_calls);
      appendArray(choice?.message?.toolCalls);
      appendArray(choice?.delta?.tool_calls);
      appendArray(choice?.delta?.toolCalls);
    }
  }
  if (Array.isArray(value.output)) {
    for (const item of value.output) {
      const type = String(item?.type ?? "").trim().toLowerCase();
      if (
        type === "function_call"
        || type === "tool_call"
        || type === "computer_call"
        || type === "custom_tool_call"
      ) {
        append(item);
      }
      appendArray(item?.tool_calls);
      appendArray(item?.toolCalls);
      if (Array.isArray(item?.content)) {
        for (const content of item.content) {
          const contentType = String(content?.type ?? "").trim().toLowerCase();
          if (
            contentType === "function_call"
            || contentType === "tool_call"
            || contentType === "computer_call"
            || contentType === "custom_tool_call"
          ) {
            append(content);
          }
          appendArray(content?.tool_calls);
          appendArray(content?.toolCalls);
        }
      }
    }
  }
  return calls;
}

function terminalFailureMessage(body) {
  const status = String(body?.status ?? "").trim().toLowerCase();
  if (["failed", "incomplete", "cancelled"].includes(status)) {
    const detail = extractOutputText(body);
    return detail ? `${status}: ${detail}` : `gateway_terminal_${status}`;
  }
  if (body && typeof body === "object" && body.error) {
    return extractOutputText(body) || "gateway_backend_error";
  }
  return null;
}

function providerModelAttestation(body, requestedModel) {
  const requestedCanonical = canonicalModelRoute(requestedModel);
  if (requestedCanonical === "grok-build") {
    return grokProviderModelAttestation(body, requestedModel);
  }
  const observed = [];
  const addObserved = value => {
    const normalized = normalizedVendorModel(value);
    if (normalized && !observed.includes(normalized)) observed.push(normalized);
  };
  addObserved(body?.model);
  addObserved(body?.actual_model);
  addObserved(body?.actualModel);
  for (const value of body?.assistant_models ?? body?.assistantModels ?? []) {
    addObserved(value);
  }

  const usageKeys = Object.keys(body?.modelUsage ?? body?.model_usage ?? {})
    .map(normalizedVendorModel)
    .filter(Boolean)
    .filter((value, index, all) => all.indexOf(value) === index)
    .sort();
  const primaryUsageModels = usageKeys
    .map(canonicalModelRoute)
    .filter(Boolean)
    .filter((value, index, all) => all.indexOf(value) === index);
  const observedCanonical = observed
    .map(canonicalModelRoute)
    .filter(Boolean)
    .filter((value, index, all) => all.indexOf(value) === index);
  const fallbackCount = providerFallbackCount(body);
  const substantiveCanonical = observedCanonical.length > 0
    ? observedCanonical
    : primaryUsageModels;
  const exact =
    substantiveCanonical.length > 0
    && substantiveCanonical.every(value => value === requestedCanonical)
    && primaryUsageModels.every(value => value === requestedCanonical)
    && fallbackCount === 0;
  const outcome = substantiveCanonical.length === 0
    ? "ATTESTATION_MISSING"
    : exact ? "VERIFIED_EXACT" : "FAIL_CLOSED_MISMATCH";
  const actualCanonical = exact ? requestedCanonical : substantiveCanonical[0] ?? "";
  const actualVendor = observed[0]
    ?? usageKeys.find(value => canonicalModelRoute(value) === actualCanonical)
    ?? "";
  return {
    schema: "TatwoModelExecutionAttestationV1",
    requested_model: requestedCanonical,
    requested_vendor_model: requestedModel,
    actual_canonical_model: actualCanonical,
    actual_vendor_model: actualVendor,
    observed_models: observed,
    model_usage_keys: usageKeys,
    fallback_count: fallbackCount,
    outcome,
  };
}

function grokProviderModelAttestation(body, requestedModel) {
  const requestedCanonical = canonicalModelRoute(requestedModel);
  const raw =
    body?.model_attestation
    ?? body?.modelAttestation;
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return {
      schema: "TatwoModelExecutionAttestationV1",
      requested_model: requestedCanonical,
      requested_vendor_model: requestedModel,
      actual_canonical_model: "",
      actual_vendor_model: "",
      observed_models: [],
      model_usage_keys: [],
      fallback_count: providerFallbackCount(body),
      evidence_source: null,
      session_evidence: null,
      outcome: "ATTESTATION_MISSING",
    };
  }
  const actualVendor = normalizedVendorModel(
    raw.actual_vendor_model
    ?? raw.actualVendorModel
    ?? body?.actual_model
    ?? body?.actualModel,
  );
  const actualCanonical = canonicalModelRoute(
    raw.actual_canonical_model
    ?? raw.actualCanonicalModel
    ?? actualVendor,
  );
  const attestedRequested = canonicalModelRoute(
    raw.requested_model
    ?? raw.requestedModel,
  );
  const fallbackCount = Math.max(
    providerFallbackCount(body),
    Number.isFinite(Number(raw.fallback_count ?? raw.fallbackCount))
      ? Math.max(0, Number(raw.fallback_count ?? raw.fallbackCount))
      : 0,
  );
  const evidenceSource = String(
    raw.evidence_source
    ?? raw.evidenceSource
    ?? "",
  ).trim();
  const sessionEvidence =
    raw.session_evidence
    ?? raw.sessionEvidence;
  const summaryModel = normalizedVendorModel(
    sessionEvidence?.summary_current_model_id
    ?? sessionEvidence?.summaryCurrentModelID,
  );
  const startedModel = normalizedVendorModel(
    sessionEvidence?.turn_started_model_id
    ?? sessionEvidence?.turnStartedModelID,
  );
  const endedOutcome = String(
    sessionEvidence?.turn_ended_outcome
    ?? sessionEvidence?.turnEndedOutcome
    ?? "",
  ).trim().toLowerCase();
  const sessionBound =
    evidenceSource === "grok_cli_session_state"
    && sessionEvidence?.synthetic !== true
    && typeof sessionEvidence?.session_id_sha256 === "string"
    && /^[a-f0-9]{64}$/i.test(sessionEvidence.session_id_sha256)
    && sessionEvidence?.summary_session_id_matches === true
    && sessionEvidence?.request_id_consistent === true
    && summaryModel === "grok-4.6"
    && startedModel === "grok-4.6"
    && isSuccessfulGrokTurnOutcome(endedOutcome);
  const exact =
    raw.schema === "TatwoGatewayModelAttestationV1"
    && raw.outcome === "VERIFIED_EXACT"
    && raw.exact === true
    && attestedRequested === requestedCanonical
    && actualCanonical === requestedCanonical
    && actualVendor === "grok-4.6"
    && fallbackCount === 0
    && sessionBound;
  return {
    schema: "TatwoModelExecutionAttestationV1",
    requested_model: requestedCanonical,
    requested_vendor_model: requestedModel,
    actual_canonical_model: actualCanonical,
    actual_vendor_model: actualVendor,
    observed_models: actualVendor ? [actualVendor] : [],
    model_usage_keys: [],
    fallback_count: fallbackCount,
    evidence_source: evidenceSource || null,
    session_evidence: sessionEvidence ?? null,
    outcome: exact
      ? "VERIFIED_EXACT"
      : actualVendor
        ? "FAIL_CLOSED_MISMATCH"
        : "ATTESTATION_MISSING",
  };
}

function isSuccessfulGrokTurnOutcome(value) {
  // Grok CLI has used both values for a normally finished turn. Keep this
  // strict and positive: missing, failed, error, cancelled, and unknown future
  // values must continue to fail closed.
  return value === "success" || value === "completed";
}

function providerFallbackCount(body) {
  const explicit = Number(
    body?.fallback_count
    ?? body?.fallbackCount
    ?? body?.fallback_event_count
    ?? body?.fallbackEventCount
    ?? 0);
  const events = Array.isArray(body?.events) ? body.events : [];
  const eventCount = events.filter(event => {
    const type = String(event?.type ?? "").toLowerCase();
    const subtype = String(event?.subtype ?? "").toLowerCase();
    return type === "fallback"
      || subtype === "fallback"
      || subtype === "model_refusal_fallback";
  }).length;
  return Math.max(0, Number.isFinite(explicit) ? explicit : 0) + eventCount;
}

function normalizedVendorModel(value) {
  const normalized = String(value ?? "").trim().toLowerCase();
  if (!normalized) return "";
  return normalized.replace(/\[[^\]]+\]$/, "");
}

function canonicalModelRoute(value) {
  const normalized = normalizedVendorModel(value);
  if (!normalized) return "";
  if (/^claude-haiku-4-5(?:-\d{8})?$/.test(normalized)) return "haiku-4-5";
  if (/^claude-haiku-4-6(?:-\d{8})?$/.test(normalized)) return "haiku-4-6";
  const exactAliases = new Map([
    ["claude-fable-5", "fable-5"],
    ["fable-5", "fable-5"],
    ["opus", "opus-5"],
    ["claude-opus-5", "opus-5"],
    ["opus-5", "opus-5"],
    ["claude-sonnet-5", "sonnet-5"],
    ["sonnet-5", "sonnet-5"],
    ["claude-haiku-4-5", "haiku-4-5"],
    ["haiku-4-5", "haiku-4-5"],
    ["grok-4.6", "grok-build"],
    ["grok-build", "grok-build"],
  ]);
  return exactAliases.get(normalized) ?? normalized;
}

function operationalFailureKind(value) {
  const text = String(value ?? "").trim();
  if (text.length > 2000 || !isOperationalFailureText(text)) return null;
  if (/\bsession\s+limit\b/i.test(text)) return "session_limit";
  if (/\b(?:quota|usage balance|credit balance|billing balance|payment required)\b|(?:http|status)\s*402\b/i.test(text)) {
    return "quota";
  }
  if (/\b(?:rate[\s_-]*limit|too many requests|http\s*429|429\b)/i.test(text)) {
    return "rate_limit";
  }
  if (/\b(?:timed?\s*out|timeout)\b/i.test(text)) return "timeout";
  return "backend_unavailable";
}

function isOperationalFailureText(value) {
  return [
    /^[a-z0-9._-]+\s+backend\s+is\s+(?:temporarily\s+)?unavailable\b/i,
    /^(?:error\s*:\s*)?(?:quota|usage quota)\b.*\b(?:exhausted|exceeded|unavailable|zero)\b/i,
    /^(?:error\s*:\s*)?(?:credit|usage|account|billing)\s+balance\b.*\b(?:exhausted|insufficient|zero|empty)\b/i,
    /^(?:error\s*:\s*)?(?:rate[\s_-]*limit|too many requests|http\s*429|429\b)/i,
    /^(?:error\s*:\s*)?(?:request\s+)?(?:timed?\s*out|timeout)\b/i,
    /^(?:error\s*:\s*)?(?:you(?:'|’)ve\s+hit\s+your\s+)?session\s+limit\b/i,
    /^(?:error\s*:\s*)?backend\b.*\bunavailable\b/i,
  ].some(pattern => pattern.test(value));
}

function buildGatewayPayload(modelName, rawPrompt, controls = {}) {
  const images = Array.isArray(controls.images) ? controls.images : [];
  const computerHostRoute = controls.computerHostRoute ?? "none";
  const currentTurnAuthority = controls.currentTurnAuthority;
  const continuationRequest = controls.continuationRequest ?? null;
  const input = images.length === 0
    ? rawPrompt
    : [{
        role: "user",
        content: [
          { type: "input_text", text: rawPrompt },
          ...images.map(image => ({
            type: "input_image",
            image_url: `data:${image.mediaType};base64,${image.data}`,
          })),
        ],
      }];
  const payload = { model: modelName, input, stream: true };
  if (continuationRequest?.mode === "provider_resume") {
    payload.previous_response_id =
      continuationRequest.previous_response_handle;
  }
  if (controls.reasoningEffort && gatewaySupportsReasoningControl(modelName)) {
    payload.reasoning = { effort: controls.reasoningEffort };
  }
  if (controls.speedTier && isGPTGatewayModel(modelName)) {
    payload.service_tier = controls.speedTier;
  }
  payload.metadata = {
    tatwo: {
      schema: "TatwoGatewayMetadataV2",
      source: "tatwo_ultrawork_chat",
      current_turn: {
        run_id: currentTurnAuthority.runID,
        turn_id: currentTurnAuthority.turnID,
        current_visible_turn_sha256:
          currentTurnAuthority.currentVisibleTurnSHA256,
        current_visible_turn_utf8_bytes:
          currentTurnAuthority.currentVisibleTurnUTF8Bytes,
        authority_nonce: currentTurnAuthority.authorityNonce,
        computer_host_route:
          computerHostRoute === "mcp"
            ? "request_scoped_tool"
            : computerHostRoute,
      },
      ...(continuationRequest
        ? {
            continuation: {
              ...continuationRequest,
              authority_nonce: currentTurnAuthority.authorityNonce,
            },
          }
        : {}),
    },
  };
  return payload;
}

function verifyGatewayContinuationReceipt(
  body,
  request,
  modelAttestation,
) {
  const receipt =
    body?.metadata?.tatwo?.continuation_receipt
    ?? body?.continuation_receipt;
  if (!receipt || typeof receipt !== "object" || Array.isArray(receipt)) {
    throw new Error("gateway_continuation_receipt_missing");
  }
  const normalized = {
    schema: String(receipt.schema ?? "").trim(),
    requested_mode: String(receipt.requested_mode ?? "").trim(),
    applied_mode: String(receipt.applied_mode ?? "").trim(),
    thread_id: String(receipt.thread_id ?? "").trim(),
    discussion_id:
      receipt.discussion_id == null
        ? null
        : String(receipt.discussion_id).trim(),
    runtime_adapter_id: String(
      receipt.runtime_adapter_id ?? "",
    ).trim(),
    canonical_model_id: String(
      receipt.canonical_model_id ?? "",
    ).trim(),
    previous_response_handle:
      receipt.previous_response_handle == null
        ? null
        : String(receipt.previous_response_handle).trim(),
    response_handle: String(receipt.response_handle ?? "").trim(),
    context_sha256: String(
      receipt.context_sha256 ?? "",
    ).trim().toLowerCase(),
    gateway_instance_id: String(
      receipt.gateway_instance_id ?? "",
    ).trim(),
    continuation_source: String(
      receipt.continuation_source ?? "",
    ).trim(),
    provider_session_reused: receipt.provider_session_reused === true,
    fallback_count: Number(receipt.fallback_count),
    model_attestation_outcome: String(
      receipt.model_attestation_outcome ?? "",
    ).trim(),
    terminal_status: String(receipt.terminal_status ?? "").trim(),
  };
  const exactChecks = [
    [normalized.schema, "TatwoGatewayContinuationReceiptV1", "schema"],
    [normalized.requested_mode, request.mode, "requested_mode"],
    [normalized.applied_mode, request.mode, "applied_mode"],
    [normalized.thread_id, request.thread_id, "thread_id"],
    [
      normalized.discussion_id,
      request.discussion_id,
      "discussion_id",
    ],
    [
      normalized.runtime_adapter_id,
      request.runtime_adapter_id,
      "runtime_adapter_id",
    ],
    [
      canonicalModelRoute(normalized.canonical_model_id),
      canonicalModelRoute(request.canonical_model_id),
      "canonical_model_id",
    ],
    [
      normalized.previous_response_handle,
      request.previous_response_handle,
      "previous_response_handle",
    ],
    [
      normalized.context_sha256,
      request.context_sha256,
      "context_sha256",
    ],
    [
      normalized.model_attestation_outcome,
      "VERIFIED_EXACT",
      "model_attestation_outcome",
    ],
    [normalized.terminal_status, "completed", "terminal_status"],
  ];
  for (const [actual, expected, field] of exactChecks) {
    if (actual !== expected) {
      throw new Error(`gateway_continuation_receipt_${field}_mismatch`);
    }
  }
  boundedOpaqueHandle(
    normalized.response_handle,
    "gateway_continuation_response_handle",
  );
  boundedIdentifier(
    normalized.gateway_instance_id,
    "gateway_continuation_instance_id",
    160,
  );
  if (
    !Number.isSafeInteger(normalized.fallback_count)
    || normalized.fallback_count !== 0
    || modelAttestation.fallback_count !== 0
  ) {
    throw new Error("gateway_continuation_receipt_fallback_observed");
  }
  if (
    canonicalModelRoute(normalized.canonical_model_id)
      !== modelAttestation.actual_canonical_model
  ) {
    throw new Error(
      "gateway_continuation_receipt_model_attestation_mismatch",
    );
  }
  const expectedSemantics = {
    none: {
      source: "provider_session_started",
      reused: false,
    },
    context_replay: {
      source: "gateway_replayed_input",
      reused: false,
    },
    provider_resume: {
      source: "provider_session_resumed",
      reused: true,
    },
  }[request.mode];
  if (
    normalized.continuation_source !== expectedSemantics.source
    || normalized.provider_session_reused !== expectedSemantics.reused
  ) {
    throw new Error("gateway_continuation_receipt_semantics_mismatch");
  }
  if (
    request.mode === "provider_resume"
    && normalized.gateway_instance_id
      !== request.previous_gateway_instance_id
  ) {
    throw new Error(
      "gateway_continuation_receipt_gateway_instance_id_mismatch",
    );
  }
  if (
    request.mode === "provider_resume"
    && normalized.response_handle === request.previous_response_handle
  ) {
    throw new Error(
      "gateway_continuation_receipt_response_handle_not_advanced",
    );
  }
  return normalized;
}

function gatewayReasoningControlReceipt(body, modelName, requestedEffort) {
  if (!requestedEffort) {
    return {
      requested: null,
      normalized: null,
      provider: null,
      cli_flag: null,
      forwarded: false,
      effective_attested: false,
      adapter: "not_requested",
    };
  }
  if (isGPTGatewayModel(modelName)) {
    return {
      requested: requestedEffort,
      normalized: requestedEffort,
      provider: "openai_passthrough",
      cli_flag: null,
      forwarded: true,
      effective_attested: false,
      adapter: "gateway.reasoning.effort",
    };
  }
  const raw = body?.reasoning_control;
  const normalized = normalizeReasoningEffort(raw?.normalized);
  const expectedProvider = canonicalModelRoute(modelName) === "grok-build"
    ? "grok_cli"
    : "claude_cli";
  const expectedFlag = expectedProvider === "grok_cli"
    ? "--reasoning-effort"
    : "--effort";
  const forwarded = Boolean(
    raw
    && raw.forwarded === true
    && normalizeReasoningEffort(raw.requested) === requestedEffort
    && normalized === requestedEffort
    && raw.provider === expectedProvider
    && raw.cli_flag === expectedFlag,
  );
  return {
    requested: requestedEffort,
    normalized,
    provider: typeof raw?.provider === "string" ? raw.provider : null,
    cli_flag: typeof raw?.cli_flag === "string" ? raw.cli_flag : null,
    forwarded,
    effective_attested: raw?.effective_attested === true,
    adapter: forwarded
      ? `gateway.reasoning.effort_to_${expectedProvider}.${expectedFlag}`
      : "gateway.reasoning.forwarding_ack_missing_or_mismatch",
  };
}

function readImageInputs(paths) {
  if (paths.length > 8) throw new Error("too_many_images_max_8");
  return paths.map(filePath => {
    const resolved = path.resolve(String(filePath));
    const stat = fs.statSync(resolved);
    if (!stat.isFile()) throw new Error(`image_not_a_file:${resolved}`);
    const data = fs.readFileSync(resolved);
    if (data.length === 0) throw new Error(`image_empty:${resolved}`);
    const mediaType = imageMediaType(resolved);
    return { mediaType, data: data.toString("base64") };
  });
}

function readPromptInput(parsedArgs) {
  for (const [name, value] of [
    ["prompt", parsedArgs.prompt],
    ["input", parsedArgs.input],
    ["prompt-file", parsedArgs.promptFile ?? parsedArgs["prompt-file"]],
    ["prompt-sha256", parsedArgs.promptSha256 ?? parsedArgs["prompt-sha256"]],
    ["prompt-bytes", parsedArgs.promptBytes ?? parsedArgs["prompt-bytes"]],
  ]) {
    if (Array.isArray(value)) {
      throw new Error(`duplicate_${name.replaceAll("-", "_")}_argument`);
    }
  }
  const inlineValues = [
    parsedArgs.prompt,
    parsedArgs.input,
  ].filter(value => value !== undefined && value !== null && value !== true);
  const promptFileValue =
    parsedArgs.promptFile
    ?? parsedArgs["prompt-file"];
  const hasPromptFile =
    promptFileValue !== undefined
    && promptFileValue !== null
    && promptFileValue !== true;
  const sourceCount = inlineValues.length + (hasPromptFile ? 1 : 0);
  if (sourceCount === 0) {
    throw new Error("missing_model_or_prompt");
  }
  if (sourceCount > 1) {
    throw new Error("multiple_prompt_transports_not_allowed");
  }

  if (!hasPromptFile) {
    const promptValue = String(inlineValues[0] ?? "").trim();
    const data = Buffer.from(promptValue, "utf8");
    validatePromptSize(data.length);
    return {
      prompt: promptValue,
      transport: "argv_inline_manual",
      sha256: sha256Hex(data),
      utf8Bytes: data.length,
      argvPromptContent: true,
    };
  }

  const expectedSHA256 = String(
    parsedArgs.promptSha256
    ?? parsedArgs["prompt-sha256"]
    ?? "",
  ).trim().toLowerCase();
  const expectedBytesRaw =
    parsedArgs.promptBytes
    ?? parsedArgs["prompt-bytes"];
  const expectedBytes = Number(expectedBytesRaw);
  if (!/^[a-f0-9]{64}$/.test(expectedSHA256)) {
    throw new Error("prompt_file_sha256_missing_or_invalid");
  }
  if (!Number.isSafeInteger(expectedBytes) || expectedBytes < 1) {
    throw new Error("prompt_file_bytes_missing_or_invalid");
  }
  if (expectedBytes > MAX_PROMPT_UTF8_BYTES) {
    throw new Error(
      `prompt_file_bytes_exceed_limit:max=${MAX_PROMPT_UTF8_BYTES}:actual=${expectedBytes}`,
    );
  }

  const resolved = path.resolve(String(promptFileValue));
  const deleteAfterRead = Boolean(
    parsedArgs.deletePromptFile
    ?? parsedArgs["delete-prompt-file"],
  );
  let fileDescriptor = null;
  let openedStat = null;
  try {
    fileDescriptor = openPromptFileNoFollow(resolved);
    openedStat = fs.fstatSync(fileDescriptor);
    if (!openedStat.isFile()) {
      throw new Error("prompt_file_not_regular");
    }
    if (
      typeof process.geteuid === "function"
      && openedStat.uid !== process.geteuid()
    ) {
      throw new Error("prompt_file_owner_mismatch");
    }
    if ((openedStat.mode & 0o077) !== 0) {
      if (deleteAfterRead) {
        unlinkPromptFileIfSameInode(resolved, openedStat);
      }
      throw new Error("prompt_file_permissions_must_be_0600");
    }
    // Remove the pathname as soon as the trusted descriptor is pinned. The
    // process keeps reading from the open fd; a later replacement at the same
    // path is a different inode and cannot be deleted by this adapter.
    if (deleteAfterRead) {
      unlinkPromptFileIfSameInode(resolved, openedStat);
    }
    validatePromptSize(openedStat.size);
    if (openedStat.size !== expectedBytes) {
      throw new Error(
        `prompt_file_byte_count_mismatch:expected=${expectedBytes}:actual=${openedStat.size}`,
      );
    }
    const data = fs.readFileSync(fileDescriptor);
    if (data.length !== expectedBytes) {
      throw new Error(
        `prompt_file_read_byte_count_mismatch:expected=${expectedBytes}:actual=${data.length}`,
      );
    }
    const actualSHA256 = sha256Hex(data);
    if (actualSHA256 !== expectedSHA256) {
      throw new Error(
        `prompt_file_sha256_mismatch:expected=${expectedSHA256}:actual=${actualSHA256}`,
      );
    }
    const promptValue = data.toString("utf8");
    if (!Buffer.from(promptValue, "utf8").equals(data)) {
      throw new Error("prompt_file_invalid_utf8");
    }
    return {
      prompt: promptValue,
      transport: "secure_prompt_file",
      sha256: actualSHA256,
      utf8Bytes: data.length,
      argvPromptContent: false,
    };
  } finally {
    if (fileDescriptor !== null) {
      fs.closeSync(fileDescriptor);
    }
  }
}

function readContinuationInput(parsedArgs) {
  for (const [name, value] of [
    [
      "continuation-file",
      parsedArgs.continuationFile ?? parsedArgs["continuation-file"],
    ],
    [
      "continuation-sha256",
      parsedArgs.continuationSha256 ?? parsedArgs["continuation-sha256"],
    ],
    [
      "continuation-bytes",
      parsedArgs.continuationBytes ?? parsedArgs["continuation-bytes"],
    ],
  ]) {
    if (Array.isArray(value)) {
      throw new Error(`duplicate_${name.replaceAll("-", "_")}_argument`);
    }
  }
  const fileValue =
    parsedArgs.continuationFile
    ?? parsedArgs["continuation-file"];
  const shaValue =
    parsedArgs.continuationSha256
    ?? parsedArgs["continuation-sha256"];
  const bytesValue =
    parsedArgs.continuationBytes
    ?? parsedArgs["continuation-bytes"];
  const presentCount = [fileValue, shaValue, bytesValue]
    .filter(value => value !== undefined && value !== null && value !== true)
    .length;
  if (presentCount === 0) return null;
  if (presentCount !== 3) {
    throw new Error("continuation_file_binding_incomplete");
  }

  const expectedSHA256 = String(shaValue).trim().toLowerCase();
  const expectedBytes = Number(bytesValue);
  if (!/^[a-f0-9]{64}$/.test(expectedSHA256)) {
    throw new Error("continuation_file_sha256_missing_or_invalid");
  }
  if (
    !Number.isSafeInteger(expectedBytes)
    || expectedBytes < 1
    || expectedBytes > MAX_CONTINUATION_UTF8_BYTES
  ) {
    throw new Error("continuation_file_bytes_missing_or_invalid");
  }

  const resolved = path.resolve(String(fileValue));
  const deleteAfterRead = Boolean(
    parsedArgs.deleteContinuationFile
    ?? parsedArgs["delete-continuation-file"],
  );
  let descriptor = null;
  let openedStat = null;
  try {
    try {
      descriptor = fs.openSync(
        resolved,
        fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW,
      );
    } catch (error) {
      if (error?.code === "ELOOP") {
        throw new Error("continuation_file_symlink_rejected");
      }
      throw error;
    }
    openedStat = fs.fstatSync(descriptor);
    if (!openedStat.isFile()) {
      throw new Error("continuation_file_not_regular");
    }
    if (
      typeof process.geteuid === "function"
      && openedStat.uid !== process.geteuid()
    ) {
      throw new Error("continuation_file_owner_mismatch");
    }
    if ((openedStat.mode & 0o077) !== 0) {
      throw new Error("continuation_file_permissions_must_be_0600");
    }
    if (deleteAfterRead) {
      unlinkContinuationFileIfSameInode(resolved, openedStat);
    }
    if (openedStat.size !== expectedBytes) {
      throw new Error(
        `continuation_file_byte_count_mismatch:expected=${expectedBytes}:actual=${openedStat.size}`,
      );
    }
    const data = fs.readFileSync(descriptor);
    if (data.length !== expectedBytes) {
      throw new Error(
        `continuation_file_read_byte_count_mismatch:expected=${expectedBytes}:actual=${data.length}`,
      );
    }
    const actualSHA256 = sha256Hex(data);
    if (actualSHA256 !== expectedSHA256) {
      throw new Error(
        `continuation_file_sha256_mismatch:expected=${expectedSHA256}:actual=${actualSHA256}`,
      );
    }
    const text = data.toString("utf8");
    if (!Buffer.from(text, "utf8").equals(data)) {
      throw new Error("continuation_file_invalid_utf8");
    }
    let object;
    try {
      object = JSON.parse(text);
    } catch {
      throw new Error("continuation_file_invalid_json");
    }
    return normalizeContinuationRequest(object);
  } finally {
    if (descriptor !== null) fs.closeSync(descriptor);
  }
}

function unlinkContinuationFileIfSameInode(filePath, openedStat) {
  try {
    const current = fs.lstatSync(filePath);
    if (!current.isFile()) {
      throw new Error(
        "continuation_file_replaced_before_unlink_non_regular",
      );
    }
    if (current.dev !== openedStat.dev || current.ino !== openedStat.ino) {
      throw new Error(
        "continuation_file_replaced_before_unlink_inode_mismatch",
      );
    }
    fs.unlinkSync(filePath);
  } catch (error) {
    if (error?.code === "ENOENT") {
      throw new Error("continuation_file_missing_before_unlink");
    }
    throw error;
  }
}

function normalizeContinuationRequest(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("continuation_request_invalid");
  }
  const mode = String(value.mode ?? "").trim();
  const threadID = boundedIdentifier(
    value.thread_id,
    "continuation_thread_id",
    160,
  );
  const discussionID = value.discussion_id == null
    ? null
    : boundedIdentifier(
        value.discussion_id,
        "continuation_discussion_id",
        160,
      );
  const runtimeAdapterID = String(
    value.runtime_adapter_id ?? "",
  ).trim();
  const canonicalModelID = boundedIdentifier(
    value.canonical_model_id,
    "continuation_canonical_model_id",
    120,
  );
  const contextSHA256 = String(
    value.context_sha256 ?? "",
  ).trim().toLowerCase();
  const previousResponseHandle = value.previous_response_handle == null
    ? null
    : boundedOpaqueHandle(
        value.previous_response_handle,
        "continuation_previous_response_handle",
      );
  const previousGatewayInstanceID =
    value.previous_gateway_instance_id == null
      ? null
      : boundedIdentifier(
          value.previous_gateway_instance_id,
          "continuation_previous_gateway_instance_id",
          160,
        );
  if (value.schema !== "TatwoGatewayContinuationV1") {
    throw new Error("continuation_schema_invalid");
  }
  if (!["none", "context_replay", "provider_resume"].includes(mode)) {
    throw new Error("continuation_mode_invalid");
  }
  if (runtimeAdapterID !== "gateway-direct") {
    throw new Error("continuation_runtime_adapter_mismatch");
  }
  if (!/^[a-f0-9]{64}$/.test(contextSHA256)) {
    throw new Error("continuation_context_sha256_invalid");
  }
  if (
    mode === "provider_resume"
      ? previousResponseHandle === null
        || previousGatewayInstanceID === null
      : previousResponseHandle !== null
        || previousGatewayInstanceID !== null
  ) {
    throw new Error("continuation_previous_pointer_invalid");
  }
  return {
    schema: "TatwoGatewayContinuationV1",
    mode,
    thread_id: threadID,
    discussion_id: discussionID,
    runtime_adapter_id: runtimeAdapterID,
    canonical_model_id: canonicalModelID,
    previous_response_handle: previousResponseHandle,
    previous_gateway_instance_id: previousGatewayInstanceID,
    context_sha256: contextSHA256,
  };
}

function boundedIdentifier(value, field, maxBytes) {
  const normalized = String(value ?? "").trim();
  if (
    !normalized
    || Buffer.byteLength(normalized) > maxBytes
    || !/^[A-Za-z0-9][A-Za-z0-9._:-]*$/.test(normalized)
  ) {
    throw new Error(`${field}_invalid`);
  }
  return normalized;
}

function boundedOpaqueHandle(value, field) {
  const normalized = String(value ?? "").trim();
  const bytes = Buffer.byteLength(normalized);
  if (
    bytes < 16
    || bytes > 256
    || !/^[A-Za-z0-9][A-Za-z0-9._:-]*$/.test(normalized)
  ) {
    throw new Error(`${field}_invalid`);
  }
  return normalized;
}

function openPromptFileNoFollow(filePath) {
  try {
    return fs.openSync(
      filePath,
      fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW,
    );
  } catch (error) {
    if (error?.code === "ELOOP") {
      throw new Error("prompt_file_symlink_rejected");
    }
    throw error;
  }
}

function validatePromptSize(byteCount) {
  if (!Number.isSafeInteger(byteCount) || byteCount < 1) {
    throw new Error("prompt_utf8_bytes_must_be_positive");
  }
  if (byteCount > MAX_PROMPT_UTF8_BYTES) {
    throw new Error(
      `prompt_utf8_bytes_exceed_limit:max=${MAX_PROMPT_UTF8_BYTES}:actual=${byteCount}`,
    );
  }
}

function unlinkPromptFileIfSameInode(filePath, openedStat) {
  try {
    const current = fs.lstatSync(filePath);
    if (!current.isFile()) {
      throw new Error("prompt_file_replaced_before_unlink_non_regular");
    }
    if (current.dev !== openedStat.dev || current.ino !== openedStat.ino) {
      throw new Error("prompt_file_replaced_before_unlink_inode_mismatch");
    }
    fs.unlinkSync(filePath);
  } catch (error) {
    if (error?.code === "ENOENT") {
      throw new Error("prompt_file_missing_before_unlink");
    }
    throw error;
  }
}

function sha256Hex(data) {
  return crypto.createHash("sha256").update(data).digest("hex");
}

function imageMediaType(filePath) {
  switch (path.extname(filePath).toLowerCase()) {
    case ".png": return "image/png";
    case ".jpg":
    case ".jpeg": return "image/jpeg";
    case ".gif": return "image/gif";
    case ".webp": return "image/webp";
    default: throw new Error(`unsupported_image_extension:${path.extname(filePath) || "none"}`);
  }
}

function arrayArg(value) {
  if (Array.isArray(value)) return value.map(String);
  if (value === undefined || value === null || value === true) return [];
  return [String(value)];
}

function isGPTGatewayModel(value) {
  const id = String(value ?? "").toLowerCase();
  return /^(gpt-|codex-|o[0-9])/.test(id);
}

function isExternalGatewayReasoningModel(value) {
  return new Set([
    "fable-5",
    "opus-5",
    "sonnet-5",
    "haiku-4-5",
    "grok-build",
  ]).has(canonicalModelRoute(value));
}

function gatewaySupportsReasoningControl(value) {
  return isGPTGatewayModel(value) || isExternalGatewayReasoningModel(value);
}

function normalizeReasoningEffort(value) {
  const raw = String(value ?? "").trim().toLowerCase();
  if (!raw) return null;
  if (["low", "低"].includes(raw)) return "low";
  if (["balanced", "medium", "med", "中"].includes(raw)) return "medium";
  if (["deep", "high", "高"].includes(raw)) return "high";
  if (["max", "xhigh", "x-high", "extra", "超高"].includes(raw)) return "xhigh";
  return null;
}

function normalizeSpeedTier(value) {
  const raw = String(value ?? "").trim().toLowerCase();
  if (!raw) return null;
  if (["fast", "快速"].includes(raw)) return "fast";
  if (["standard", "default", "normal", "標準"].includes(raw)) return "standard";
  return null;
}

function normalizeComputerHostRoute(value) {
  // Compatibility callers that predate the bounded current-turn flag must
  // fail closed. Never omit the authority envelope and let the gateway infer
  // Computer Use from a flattened prompt containing transcript history.
  if (value === undefined || value === null) return "none";
  if (Array.isArray(value)) {
    throw new Error("duplicate_computer_host_route_argument");
  }
  const raw = String(value).trim().toLowerCase();
  if (["none", "mcp", "embedded_intent"].includes(raw)) return raw;
  throw new Error(`invalid_computer_host_route:${raw || "empty"}`);
}

function normalizeCurrentTurnAuthority({
  runID,
  turnID,
  currentVisibleTurnSHA256,
  currentVisibleTurnUTF8Bytes,
}) {
  const normalizedRunID = normalizeAuthorityIdentifier(runID, "run_id");
  const normalizedTurnID = normalizeAuthorityIdentifier(turnID, "turn_id");
  if (Array.isArray(currentVisibleTurnSHA256)) {
    throw new Error("duplicate_current_turn_sha256_argument");
  }
  const normalizedSHA256 = String(currentVisibleTurnSHA256 ?? "")
    .trim()
    .toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(normalizedSHA256)) {
    throw new Error("current_turn_sha256_missing_or_invalid");
  }
  if (Array.isArray(currentVisibleTurnUTF8Bytes)) {
    throw new Error("duplicate_current_turn_bytes_argument");
  }
  const normalizedUTF8Bytes = String(currentVisibleTurnUTF8Bytes ?? "").trim();
  if (!/^[1-9][0-9]*$/.test(normalizedUTF8Bytes)) {
    throw new Error("current_turn_bytes_missing_or_invalid");
  }
  const parsedUTF8Bytes = Number(normalizedUTF8Bytes);
  if (
    !Number.isSafeInteger(parsedUTF8Bytes)
    || parsedUTF8Bytes > MAX_PROMPT_UTF8_BYTES
  ) {
    throw new Error("current_turn_bytes_missing_or_invalid");
  }
  return {
    runID: normalizedRunID,
    turnID: normalizedTurnID,
    currentVisibleTurnSHA256: normalizedSHA256,
    currentVisibleTurnUTF8Bytes: parsedUTF8Bytes,
    // A fresh process-local nonce makes an otherwise matching receipt
    // unusable after cancel/terminal or in a subsequent physical attempt.
    authorityNonce: crypto.randomUUID().toLowerCase(),
  };
}

function normalizeAuthorityIdentifier(value, field) {
  if (Array.isArray(value)) {
    throw new Error(`duplicate_${field}_argument`);
  }
  const normalized = String(value ?? "").trim();
  if (
    !normalized
    || normalized.length > 160
    || !/^[a-z0-9][a-z0-9._:-]*$/i.test(normalized)
  ) {
    throw new Error(`${field}_missing_or_invalid`);
  }
  return normalized;
}

function verifyAppliedComputerHostRouteReceipt(
  body,
  expectedAuthority,
  requestedRoute,
) {
  const receipt = body?.metadata?.tatwo?.applied_route_receipt;
  if (!receipt || typeof receipt !== "object" || Array.isArray(receipt)) {
    throw new Error("gateway_applied_route_receipt_missing");
  }
  const expectedWireRoute =
    requestedRoute === "mcp" ? "request_scoped_tool" : requestedRoute;
  const expectedResponseID = String(body?.id ?? body?.response_id ?? "").trim();
  const expectedStatus = String(body?.status ?? "").trim();
  const checks = [
    [receipt.schema, "TatwoGatewayAppliedComputerHostRouteReceiptV1", "schema"],
    [receipt.source, "codex_app_model_gateway", "source"],
    [receipt.run_id, expectedAuthority.runID, "run_id"],
    [receipt.turn_id, expectedAuthority.turnID, "turn_id"],
    [
      receipt.current_visible_turn_sha256,
      expectedAuthority.currentVisibleTurnSHA256,
      "current_visible_turn_sha256",
    ],
    [
      receipt.current_visible_turn_utf8_bytes,
      expectedAuthority.currentVisibleTurnUTF8Bytes,
      "current_visible_turn_utf8_bytes",
    ],
    [receipt.authority_nonce, expectedAuthority.authorityNonce, "authority_nonce"],
    [receipt.applied_computer_host_route, expectedWireRoute, "route"],
    [receipt.response_id, expectedResponseID, "response_id"],
    [receipt.terminal_status, expectedStatus, "terminal_status"],
  ];
  for (const [actual, expected, field] of checks) {
    const requiredNonEmpty = field !== "response_id";
    if ((requiredNonEmpty && !expected) || actual !== expected) {
      throw new Error(`gateway_applied_route_receipt_${field}_mismatch`);
    }
  }
  if (
    !Number.isSafeInteger(receipt.tool_host_invocation_count)
    || receipt.tool_host_invocation_count < 0
  ) {
    throw new Error(
      "gateway_applied_route_receipt_tool_host_invocation_count_invalid",
    );
  }
  if (
    expectedWireRoute === "none"
    && receipt.tool_host_invocation_count !== 0
  ) {
    throw new Error(
      "gateway_applied_route_receipt_none_route_invoked_tool_host",
    );
  }
  return {
    schema: receipt.schema,
    run_id: receipt.run_id,
    turn_id: receipt.turn_id,
    current_visible_turn_sha256: receipt.current_visible_turn_sha256,
    current_visible_turn_utf8_bytes:
      receipt.current_visible_turn_utf8_bytes,
    authority_nonce: receipt.authority_nonce,
    applied_computer_host_route: receipt.applied_computer_host_route,
    tool_host_invocation_count: receipt.tool_host_invocation_count,
    response_id: receipt.response_id,
    terminal_status: receipt.terminal_status,
    verified: true,
  };
}

function postJSON(urlString, payload, timeout, onStreamingEvent = () => {}) {
  return new Promise((resolve, reject) => {
    const url = new URL(urlString);
    const data = Buffer.from(JSON.stringify(payload));
    const transport = url.protocol === "https:" ? https : http;
    let settled = false;
    const succeed = value => {
      if (settled) return;
      settled = true;
      resolve(value);
    };
    const fail = error => {
      if (settled) return;
      settled = true;
      request.destroy();
      reject(error);
    };
    const request = transport.request({
      method: "POST",
      protocol: url.protocol,
      hostname: url.hostname,
      port: url.port,
      path: `${url.pathname}${url.search}`,
      headers: {
        "Content-Type": "application/json",
        "Content-Length": String(data.length),
        "Accept": "text/event-stream, application/json",
      },
      timeout
    }, response => {
      const contentType = String(response.headers["content-type"] ?? "").toLowerCase();
      if (contentType.includes("text/event-stream")) {
        consumeEventStream(response, onStreamingEvent)
          .then(stream => succeed({
            statusCode: response.statusCode ?? 0,
            body: stream.body,
            streaming: stream.delivery,
          }))
          .catch(error => {
            response.destroy();
            fail(error);
          });
        return;
      }
      const chunks = [];
      response.on("data", chunk => chunks.push(chunk));
      response.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        let body = null;
        try { body = text ? JSON.parse(text) : null; } catch {
          body = { output_text: text };
        }
        succeed({ statusCode: response.statusCode ?? 0, body, streaming: null });
      });
      response.on("aborted", () => fail(new Error("gateway_response_disconnected")));
      response.on("error", fail);
    });
    request.on("timeout", () => {
      request.destroy(new Error("gateway_direct_timeout"));
    });
    request.on("error", fail);
    request.write(data);
    request.end();
  });
}

function consumeEventStream(response, onStreamingEvent) {
  return new Promise((resolve, reject) => {
    const terminalGraceMs = 500;
    let buffer = "";
    let ended = false;
    let settled = false;
    let sawDone = false;
    let terminalEvent = null;
    let terminalGraceTimer = null;
    const responseSnapshot = {};
    const outputTextDeltas = [];
    const outputItems = [];

    const clearTerminalGrace = () => {
      if (!terminalGraceTimer) return;
      clearTimeout(terminalGraceTimer);
      terminalGraceTimer = null;
    };
    const fail = error => {
      if (settled) return;
      settled = true;
      clearTerminalGrace();
      response.destroy();
      reject(error);
    };
    const finish = () => {
      if (settled) return;
      if (!terminalEvent) {
        fail(new Error(
          sawDone
            ? "gateway_stream_done_without_response_completed"
            : "gateway_stream_ended_without_response_completed",
        ));
        return;
      }
      settled = true;
      clearTerminalGrace();
      const terminalResponse = terminalEvent.response
        && typeof terminalEvent.response === "object"
        ? terminalEvent.response
        : terminalEvent;
      const body = {
        ...responseSnapshot,
        ...terminalResponse,
      };
      if (!extractOutputText(body) && outputTextDeltas.length > 0) {
        body.output_text = outputTextDeltas.join("");
      }
      if ((!Array.isArray(body.output) || body.output.length === 0) && outputItems.length > 0) {
        body.output = outputItems;
      }
      resolve({
        body,
        delivery: {
          streamed: true,
          deltaEventCount: outputTextDeltas.length,
          deltaText: outputTextDeltas.join(""),
        },
      });
    };
    const scheduleTerminalFinish = () => {
      if (terminalGraceTimer || settled) return;
      terminalGraceTimer = setTimeout(() => {
        terminalGraceTimer = null;
        finish();
        if (!response.destroyed) response.destroy();
      }, terminalGraceMs);
    };
    const handleBlock = rawBlock => {
      let parsed;
      try {
        parsed = parseSSEBlock(rawBlock);
      } catch (error) {
        fail(error);
        return;
      }
      if (!parsed) return;
      if (parsed.kind === "heartbeat") {
        onStreamingEvent({
          type: "response.in_progress",
          heartbeat: true,
          source: "sse_comment",
          response: responseSnapshot,
        });
        return;
      }
      if (parsed.kind === "done") {
        sawDone = true;
        return;
      }
      const event = parsed.event;
      const type = String(event?.type ?? parsed.eventName ?? "").trim();
      if (!type) {
        fail(new Error("gateway_stream_event_type_missing"));
        return;
      }
      const normalized = event?.type ? event : { ...event, type };
      Object.assign(responseSnapshot, streamingResponseMetadata(normalized));
      const fragment = normalized.response
        && typeof normalized.response === "object"
        ? normalized.response
        : null;
      if (fragment) Object.assign(responseSnapshot, fragment);
      if (type === "response.output_text.delta") {
        outputTextDeltas.push(String(normalized.delta ?? ""));
      } else if (type === "response.output_item.done" && normalized.item) {
        outputItems.push(normalized.item);
      }
      if (["response.completed", "response.failed", "response.incomplete"].includes(type)) {
        if (terminalEvent) {
          fail(new Error("gateway_stream_duplicate_terminal_event"));
          return;
        }
        terminalEvent = normalized;
        scheduleTerminalFinish();
      }
      onStreamingEvent(normalized);
    };
    const drain = flush => {
      while (true) {
        const separator = buffer.match(/\r?\n\r?\n/);
        if (!separator || separator.index === undefined) break;
        const block = buffer.slice(0, separator.index);
        buffer = buffer.slice(separator.index + separator[0].length);
        handleBlock(block);
        if (settled) return;
      }
      if (flush && buffer.trim()) {
        const block = buffer;
        buffer = "";
        handleBlock(block);
      }
    };

    response.setEncoding("utf8");
    response.on("data", chunk => {
      if (settled) return;
      buffer += chunk;
      drain(false);
    });
    response.on("end", () => {
      if (settled) return;
      ended = true;
      drain(true);
      if (!settled) finish();
    });
    response.on("aborted", () => fail(new Error("gateway_stream_disconnected")));
    response.on("error", () => fail(new Error("gateway_stream_disconnected")));
    response.on("close", () => {
      if (!ended && !settled) fail(new Error("gateway_stream_disconnected"));
    });
  });
}

function streamingResponseMetadata(event) {
  const metadata = {};
  for (const key of [
    "id",
    "response_id",
    "status",
    "model",
    "actual_model",
    "actualModel",
    "assistant_models",
    "assistantModels",
    "modelUsage",
    "model_usage",
    "fallback_count",
    "fallbackCount",
    "fallback_event_count",
    "fallbackEventCount",
    "model_attestation",
    "modelAttestation",
    "metadata",
    "continuation_receipt",
    "usage",
    "error",
    "degraded",
    "error_kind",
    "errorKind",
    "reset_at",
    "resetAt",
    "output_text",
    "output",
    "content",
  ]) {
    if (event?.[key] !== undefined) metadata[key] = event[key];
  }
  return metadata;
}

function parseSSEBlock(rawBlock) {
  const lines = String(rawBlock ?? "").split(/\r?\n/);
  let eventName = "";
  const dataLines = [];
  let heartbeat = false;
  for (const line of lines) {
    if (!line) continue;
    if (line.startsWith(":")) {
      heartbeat = true;
      continue;
    }
    const separator = line.indexOf(":");
    const field = separator >= 0 ? line.slice(0, separator) : line;
    let value = separator >= 0 ? line.slice(separator + 1) : "";
    if (value.startsWith(" ")) value = value.slice(1);
    if (field === "event") eventName = value;
    if (field === "data") dataLines.push(value);
  }
  if (dataLines.length === 0) return heartbeat ? { kind: "heartbeat" } : null;
  const data = dataLines.join("\n");
  if (data === "[DONE]") return { kind: "done" };
  let event;
  try {
    event = JSON.parse(data);
  } catch {
    throw new Error("gateway_stream_invalid_json");
  }
  if (!event || typeof event !== "object") {
    throw new Error("gateway_stream_event_invalid");
  }
  return {
    kind: "event",
    eventName,
    event,
  };
}

function emit(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

function sanitize(value) {
  return value
    .replace(/\/Users\/[^\s]+/g, "~")
    .replace(/\/Volumes\/[^\s]+/g, "/Volumes/…")
    .slice(0, 2000);
}

function shortHash(value) {
  return crypto.createHash("sha256").update(String(value)).digest("hex").slice(0, 12);
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith("--")) continue;
    const eq = arg.indexOf("=");
    const key = eq >= 0 ? arg.slice(2, eq) : arg.slice(2);
    const value = eq >= 0
      ? arg.slice(eq + 1)
      : argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[++i] : true;
    if (Object.prototype.hasOwnProperty.call(out, key)) {
      out[key] = Array.isArray(out[key]) ? [...out[key], value] : [out[key], value];
    } else {
      out[key] = value;
    }
  }
  return out;
}
