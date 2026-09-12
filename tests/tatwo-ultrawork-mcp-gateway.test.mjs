#!/usr/bin/env node
import assert from "node:assert/strict";
import http from "node:http";
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const serverScript = path.join(repoRoot, "scripts", "tatwo-ultrawork-mcp.mjs");

test("tatwo ultrawork MCP gateway", async t => {
const listedTools = await callMCPRequest(
  process.env,
  "tools/list",
  {},
);
const remoteStatusTool = listedTools.result.tools.find(
  tool => tool.name === "tatwo_remote_loops_status",
);
assert.ok(remoteStatusTool, "remote status tool must be listed");
const userFacingHostTools = listedTools.result.tools.filter(
  tool => tool.name.startsWith("tatwo_host_") || tool.name.startsWith("tatwo_computer_"),
);
assert.ok(userFacingHostTools.length > 0, "host/computer tools must be listed");
for (const tool of userFacingHostTools) {
  assert.doesNotMatch(
    tool.description,
    /human(?:-issued)? approval lease|computer_use approval lease/i,
    `${tool.name} must not expose internal lease terminology as user-facing guidance`,
  );
}
assert.equal(
  remoteStatusTool.inputSchema.properties.deviceID.type,
  "string",
);
assert.equal(
  remoteStatusTool.inputSchema.required?.includes("deviceID") ?? false,
  false,
  "deviceID must remain optional at the MCP boundary",
);

const explicitRemoteStatus = await remoteStatusAgainst({
  argumentsPayload: {
    deviceID: "origin-explicit",
    channelDir: "/tmp/tatwo-remote-status-channel",
  },
});
assert.equal(explicitRemoteStatus.response.result.isError, false);
assert.match(
  explicitRemoteStatus.swiftArgs,
  /remote-runner fleet status --device-id origin-explicit --channel-dir \/tmp\/tatwo-remote-status-channel --json/,
);

const derivedRemoteStatus = await remoteStatusAgainst({
  deviceIdentityID: "origin-derived",
  stateDeviceID: "origin-derived",
  trustDeviceID: "origin-derived",
});
assert.equal(derivedRemoteStatus.response.result.isError, false);
assert.match(
  derivedRemoteStatus.swiftArgs,
  /remote-runner fleet status --device-id origin-derived --json/,
);

const missingRemoteStatusIdentity = await remoteStatusAgainst();
assert.equal(missingRemoteStatusIdentity.response.error.code, -32603);
assert.match(
  missingRemoteStatusIdentity.response.error.message,
  /找不到可用的本機設備 ID/,
);
assert.match(
  missingRemoteStatusIdentity.response.error.message,
  /不會回傳假的空白 fleet/,
);
assert.equal(
  missingRemoteStatusIdentity.swiftArgs,
  "",
  "missing local identity must not invoke the Swift fleet reader",
);

const conflictingRemoteStatusIdentity = await remoteStatusAgainst({
  deviceIdentityID: "origin-mini",
  stateDeviceID: "origin-book",
});
assert.equal(conflictingRemoteStatusIdentity.response.error.code, -32603);
assert.match(
  conflictingRemoteStatusIdentity.response.error.message,
  /找到多個不同的本機設備 ID/,
);
assert.equal(
  conflictingRemoteStatusIdentity.swiftArgs,
  "",
  "ambiguous local identity must fail before the Swift fleet reader",
);

const unsafeRemoteStatusIdentity = await remoteStatusAgainst({
  symlinkStateDeviceID: "origin-symlink",
});
assert.equal(unsafeRemoteStatusIdentity.response.error.code, -32603);
assert.match(
  unsafeRemoteStatusIdentity.response.error.message,
  /無法安全解析本機設備 ID/,
);
assert.equal(
  unsafeRemoteStatusIdentity.swiftArgs,
  "",
  "unsafe identity files must not reach the Swift fleet reader",
);

const loopbackCapability = await probeLoopbackRoundtrip();
if (!loopbackCapability.available) {
  t.skip(
    "sandbox 禁止 loopback network，非程式缺陷" +
      `（127.0.0.1 bind/connect probe ${loopbackCapability.error.code}）`,
  );
  return;
}

for (const testCase of [
  {
    name: "terminal failed",
    body: { status: "failed", error_kind: "quota" },
  },
  {
    name: "terminal incomplete",
    body: { status: "incomplete" },
  },
  {
    name: "terminal cancelled",
    body: { status: "cancelled" },
  },
  {
    name: "terminal error",
    body: { status: "error" },
  },
  {
    name: "nested terminal failure",
    body: { status: "completed", receipt: { status: "failed" } },
  },
  {
    name: "ok false",
    body: { ok: false, reason: "not_found" },
  },
  {
    name: "error envelope",
    body: { ok: true, error: { code: "not_found" } },
  },
]) {
  const response = await callCLIBackedToolMCP({
    toolName: "tatwo_route_live_smoke_receipts",
    body: testCase.body,
  });
  assert.equal(
    response.result.isError,
    true,
    `${testCase.name} must fail closed even when the child exits zero`,
  );
  const normalizedFailure = JSON.parse(response.result.content[0].text);
  assert.notEqual(
    normalizedFailure.status,
    "completed",
    `${testCase.name} must not return a completed top-level status`,
  );
  assert.notEqual(
    normalizedFailure.success,
    true,
    `${testCase.name} must not return top-level success=true`,
  );
}

const nonZeroCompletedResult = await callCLIBackedToolMCP({
  toolName: "tatwo_route_live_smoke_receipts",
  body: { status: "completed", ok: true },
  exitCode: 7,
});
assert.equal(
  nonZeroCompletedResult.result.isError,
  true,
  "a non-zero child exit must override a completed JSON body",
);
assert.deepEqual(
  JSON.parse(nonZeroCompletedResult.result.content[0].text),
  { status: "failed", ok: false },
  "a failed process must not expose a completed/ok top-level contract",
);

const completedCLIResult = await callCLIBackedToolMCP({
  toolName: "tatwo_route_live_smoke_receipts",
  body: { status: "completed", ok: true },
});
assert.equal(
  completedCLIResult.result.isError,
  false,
  "the existing completed/ok success contract must remain successful",
);

for (const noErrorBody of [
  { status: "completed", ok: true, error_kind: "none" },
  { status: "completed", ok: true, errorKind: "no-error" },
  { status: "completed", ok: true, errors: [] },
  { status: "completed", ok: true, errors: {} },
  { status: "completed", ok: true, error: null },
]) {
  const response = await callCLIBackedToolMCP({
    toolName: "tatwo_route_live_smoke_receipts",
    body: noErrorBody,
  });
  assert.equal(
    response.result.isError,
    false,
    `explicit no-error sentinel must remain successful: ${JSON.stringify(noErrorBody)}`,
  );
}

const sharedNodeClassifierResult = await callCLIBackedToolMCP({
  toolName: "tatwo_route_risk_dashboard",
  body: { ok: false, status: "failed" },
});
assert.equal(
  sharedNodeClassifierResult.result.isError,
  true,
  "other Node CLI-backed tools must use the same result classifier",
);

const sharedSwiftClassifierResult = await callCLIBackedToolMCP({
  toolName: "tatwo_doctor",
  executable: "swift",
  body: { ok: false, error: "doctor_unhealthy" },
});
assert.equal(
  sharedSwiftClassifierResult.result.isError,
  true,
  "Swift CLI-backed tools must use the same result classifier",
);

for (const invalidOutput of [
  { name: "empty output", rawOutput: "" },
  { name: "malformed JSON", rawOutput: "{\"status\":" },
  { name: "JSON number primitive", rawOutput: "200" },
  { name: "JSON string primitive", rawOutput: "\"completed\"" },
  { name: "plain log noise", rawOutput: "build finished successfully" },
]) {
  const response = await callCLIBackedToolMCP({
    toolName: "tatwo_route_live_smoke_receipts",
    rawOutput: invalidOutput.rawOutput,
  });
  assert.equal(response.result.isError, true, `${invalidOutput.name} must fail closed`);
  const failure = JSON.parse(response.result.content[0].text);
  assert.equal(failure.ok, false, invalidOutput.name);
  assert.equal(failure.status, "failed", invalidOutput.name);
  assert.equal(failure.error, "invalid_cli_json_output", invalidOutput.name);
}

const listenerOnlyStatus = await gatewayStatusAgainst({
  healthBody: {
    ok: true,
    ok_scope: "listener_liveness_only",
    routes: {
      "haiku-4-5": {
        status: "healthy",
        attempts: 1,
      },
    },
  },
});
assert.equal(listenerOnlyStatus.result.isError, true);
assert.equal(JSON.parse(listenerOnlyStatus.result.content[0].text).status, "degraded");

const verifiedStatusTimestamp = new Date().toISOString();
const verifiedGatewayStatus = await gatewayStatusAgainst({
  healthBody: {
    ok: true,
    degraded: false,
    routes: {
      "haiku-4-5": {
        status: "healthy",
        healthy: true,
        attempts: 1,
        has_error: false,
        error_kind: null,
        observed_at: verifiedStatusTimestamp,
        last_ok_at: verifiedStatusTimestamp,
        last_error_at: null,
      },
    },
  },
});
assert.equal(verifiedGatewayStatus.result.isError, false);
const verifiedGatewayStatusReceipt = JSON.parse(verifiedGatewayStatus.result.content[0].text);
assert.equal(verifiedGatewayStatusReceipt.status, "healthy");
assert.equal(verifiedGatewayStatusReceipt.verifiedHealthyRouteCount, 1);

for (const status of ["failed", "incomplete", "cancelled"]) {
  const { receipt, swiftArgs } = await dispatchAgainst({
    id: `resp_${status}`,
    status,
    output_text: `partial output for ${status}`,
    error: status === "failed" ? { message: "backend failed" } : undefined,
  });

  assert.equal(receipt.ok, false, status);
  assert.equal(receipt.status, "failed", status);
  assert.doesNotMatch(JSON.stringify(receipt), /"status":"completed"/, status);
  assert.doesNotMatch(swiftArgs, /--status completed/, status);
}

const failClosedTerminalCases = [];
const unknownJSONResult = await dispatchAgainst({
  id: "resp_unknown_json",
  status: "unknown",
  output_text: "UNKNOWN_JSON_MUST_NOT_COMPLETE",
});
failClosedTerminalCases.push({
  transport: "json",
  terminalStatus: "unknown",
  ok: unknownJSONResult.receipt.ok,
  status: unknownJSONResult.receipt.status,
  wroteCompleted: /--status completed/.test(unknownJSONResult.swiftArgs),
});

for (const terminalStatus of ["failed", "incomplete", "cancelled", "unknown"]) {
  const result = await dispatchAgainst(
    {},
    {
      contentType: "text/event-stream",
      rawResponseBody: [
        `data: ${JSON.stringify({
          type: "response.completed",
          response: {
            id: `resp_sse_${terminalStatus}`,
            status: terminalStatus,
            output_text: `SSE_${terminalStatus.toUpperCase()}_MUST_NOT_COMPLETE`,
          },
        })}`,
        "",
        "data: [DONE]",
        "",
      ].join("\n"),
    },
  );
  failClosedTerminalCases.push({
    transport: "sse",
    terminalStatus,
    ok: result.receipt.ok,
    status: result.receipt.status,
    wroteCompleted: /--status completed/.test(result.swiftArgs),
  });
}

assert.deepEqual(
  failClosedTerminalCases,
  [
    {
      transport: "json", terminalStatus: "unknown",
      ok: false, status: "failed", wroteCompleted: false,
    },
    {
      transport: "sse", terminalStatus: "failed",
      ok: false, status: "failed", wroteCompleted: false,
    },
    {
      transport: "sse", terminalStatus: "incomplete",
      ok: false, status: "failed", wroteCompleted: false,
    },
    {
      transport: "sse", terminalStatus: "cancelled",
      ok: false, status: "failed", wroteCompleted: false,
    },
    {
      transport: "sse", terminalStatus: "unknown",
      ok: false, status: "failed", wroteCompleted: false,
    },
  ],
  "unknown or non-completed terminal states must fail closed for JSON and SSE",
);

const contradictorySSETerminals = [];
for (const terminalStatus of ["incomplete", "cancelled", "canceled"]) {
  const result = await dispatchAgainst(
    {},
    {
      contentType: "text/event-stream",
      rawResponseBody: [
        `data: ${JSON.stringify({
          type: `response.${terminalStatus}`,
          response: {
            id: `resp_sse_event_${terminalStatus}`,
            status: terminalStatus,
            output_text: `PARTIAL_${terminalStatus.toUpperCase()}`,
          },
        })}`,
        "",
        `data: ${JSON.stringify({
          type: "response.completed",
          response: {
            id: `resp_sse_event_${terminalStatus}`,
            status: "completed",
            output_text: "LATE_COMPLETED_MUST_NOT_WIN",
          },
        })}`,
        "",
        "data: [DONE]",
        "",
      ].join("\n"),
    },
  );
  contradictorySSETerminals.push({
    terminalStatus,
    ok: result.receipt.ok,
    status: result.receipt.status,
    wroteCompleted: /--status completed/.test(result.swiftArgs),
  });
}
assert.deepEqual(
  contradictorySSETerminals,
  [
    { terminalStatus: "incomplete", ok: false, status: "failed", wroteCompleted: false },
    { terminalStatus: "cancelled", ok: false, status: "failed", wroteCompleted: false },
    { terminalStatus: "canceled", ok: false, status: "failed", wroteCompleted: false },
  ],
);

const emptyHTTP200 = await dispatchAgainst(
  {},
  { rawResponseBody: "" },
);

const conflictingNestedTerminal = await dispatchAgainst({
  id: "resp_outer_completed",
  status: "completed",
  output_text: "OUTER_COMPLETED_MUST_NOT_MASK_NESTED_FAILURE",
  response: {
    id: "resp_nested_failed",
    status: "failed",
    error: { message: "nested backend failure" },
  },
});
assert.deepEqual(
  [
    {
      case: "empty-http-200",
      ok: emptyHTTP200.receipt.ok,
      status: emptyHTTP200.receipt.status,
      wroteCompleted: /--status completed/.test(emptyHTTP200.swiftArgs),
    },
    {
      case: "conflicting-nested-terminal",
      ok: conflictingNestedTerminal.receipt.ok,
      status: conflictingNestedTerminal.receipt.status,
      wroteCompleted: /--status completed/.test(conflictingNestedTerminal.swiftArgs),
    },
  ],
  [
    { case: "empty-http-200", ok: false, status: "failed", wroteCompleted: false },
    {
      case: "conflicting-nested-terminal",
      ok: false,
      status: "failed",
      wroteCompleted: false,
    },
  ],
);

const { receipt: quotaFailure } = await dispatchAgainst({
  id: "resp_quota",
  status: "completed",
  output_text: "quota exhausted: credit balance is zero",
});

assert.equal(quotaFailure.ok, false);
assert.equal(quotaFailure.status, "failed");

const { receipt: structuredDegraded } = await dispatchAgainst({
  id: "resp_structured_degraded",
  status: "completed",
  degraded: true,
  error_kind: "session_limit",
  output_text: "目前服務無法使用，請稍後再試。",
});

assert.equal(structuredDegraded.ok, false);
assert.equal(structuredDegraded.status, "failed");
assert.match(structuredDegraded.error, /session_limit/);
assert.equal(structuredDegraded.failureClass, "retryable");
assert.equal(structuredDegraded.goalStatus, "blocked");

const rawFailureWithEncryptedContent = await dispatchAgainst({
  id: "resp_sensitive",
  status: "failed",
  error: {
    code: "server_error",
    message: "retry request ID req_sensitive",
  },
  output: [{
    type: "reasoning",
    encrypted_content: "TOP_SECRET_CIPHERTEXT",
  }],
});
assert.equal(rawFailureWithEncryptedContent.receipt.failureClass, "retryable");
assert.match(rawFailureWithEncryptedContent.receipt.rawErrorDigest, /^sha256:[a-f0-9]{64}$/);
assert.doesNotMatch(JSON.stringify(rawFailureWithEncryptedContent.receipt), /encrypted_content|TOP_SECRET_CIPHERTEXT/);
assert.doesNotMatch(rawFailureWithEncryptedContent.swiftArgs, /encrypted_content|TOP_SECRET_CIPHERTEXT/);
assert.match(rawFailureWithEncryptedContent.swiftArgs, /--raw-error-digest sha256:[a-f0-9]{64}/);

const oversizedPrompt = await dispatchAgainst(
  {
    id: "resp_prompt_must_not_run",
    status: "completed",
    output_text: "PROMPT_MUST_NOT_RUN",
  },
  { prompt: "x".repeat(32_769) },
);
assert.equal(oversizedPrompt.receipt.ok, false);
assert.match(oversizedPrompt.receipt.error, /prompt_hard_cap_exceeded/);
assert.equal(oversizedPrompt.gatewayCalls, 0);

const exactBoundaryPrompt = await dispatchAgainst(
  {
    id: "resp_prompt_boundary",
    status: "completed",
    output_text: "PROMPT_BOUNDARY_OK",
  },
  { prompt: "x".repeat(32_768) },
);
assert.equal(exactBoundaryPrompt.receipt.ok, true);
assert.equal(exactBoundaryPrompt.gatewayCalls, 1);

const trailingSpaceOverflow = await dispatchAgainst(
  {
    id: "resp_trim_overflow_must_not_run",
    status: "completed",
    output_text: "TRIM_OVERFLOW_MUST_NOT_RUN",
  },
  { prompt: `x${" ".repeat(32_768)}` },
);
assert.equal(trailingSpaceOverflow.receipt.ok, false);
assert.match(trailingSpaceOverflow.receipt.error, /prompt_hard_cap_exceeded/);
assert.equal(trailingSpaceOverflow.gatewayCalls, 0);

const rawCallerCapOverflow = await dispatchAgainst(
  {
    id: "resp_caller_cap_must_not_run",
    status: "completed",
    output_text: "CALLER_CAP_MUST_NOT_RUN",
  },
  { prompt: "x ".repeat(100), maxPromptChars: 150 },
);
assert.equal(rawCallerCapOverflow.receipt.ok, false);
assert.match(rawCallerCapOverflow.receipt.error, /prompt_cap_exceeded/);
assert.equal(rawCallerCapOverflow.gatewayCalls, 0);

const backendControlledErrorCode = await dispatchAgainst({
  id: "resp_backend_code",
  status: "failed",
  error: {
    code: "CIPHERTEXT_SENTINEL_9f4a8c3e7d6b5a1",
    message: "backend failed",
  },
});
assert.equal(backendControlledErrorCode.receipt.ok, false);
assert.doesNotMatch(
  JSON.stringify(backendControlledErrorCode.receipt),
  /CIPHERTEXT_SENTINEL_9f4a8c3e7d6b5a1/);
assert.doesNotMatch(
  backendControlledErrorCode.swiftArgs,
  /CIPHERTEXT_SENTINEL_9f4a8c3e7d6b5a1/);
assert.match(backendControlledErrorCode.receipt.rawErrorDigest, /^sha256:[a-f0-9]{64}$/);

const terminalWinsClassification = await dispatchAgainst({
  id: "resp_policy_timeout",
  status: "failed",
  error: {
    code: "policy_violation",
    message: "request timed out after policy rejection",
  },
});
assert.equal(terminalWinsClassification.receipt.failureClass, "terminal");
assert.match(terminalWinsClassification.swiftArgs, /--failure-class terminal/);

const bareHTTP500 = await dispatchAgainst(
  {},
  { httpStatus: 500, rawResponseBody: "" },
);
assert.equal(bareHTTP500.receipt.failureClass, "retryable");
assert.doesNotMatch(bareHTTP500.swiftArgs, /--failure-class unknown/);
assert.match(bareHTTP500.swiftArgs, /--failure-class retryable/);

const { receipt: completed } = await dispatchAgainst({
  id: "resp_completed",
  status: "completed",
  output_text: "MCP_GATEWAY_OK",
});

assert.equal(completed.ok, true);
assert.equal(completed.status, "completed");
assert.equal(completed.output, "MCP_GATEWAY_OK");
assert.equal(completed.modelAttestation.required, false);
assert.equal(completed.actualVendorModel, null);
assert.equal(completed.fallbackCount, null);
assert.match(
  completed.providerEvidenceLimitations.join(" "),
  /provider exact-model\/fallback attestation is not required/,
);

const fableFallbackToOpus = await dispatchAgainst(
  {
    ...exactStrictGatewayResponse("fable-5", {
      id: "resp_fable_fallback_opus",
      outputText: "OPUS_FALLBACK_MUST_NOT_COMPLETE",
    }),
    actual_model: "claude-opus-5",
    fallback_count: 1,
    model_attestation: {
      schema: "TatwoGatewayModelAttestationV1",
      requested_model: "fable-5",
      requested_vendor_model: "claude-fable-5",
      actual_canonical_model: "opus-5",
      actual_vendor_model: "claude-opus-5",
      fallback_count: 1,
      outcome: "FAIL_CLOSED_MISMATCH",
      exact: false,
    },
  },
  {
    model: "fable-5",
    allowExpensive: true,
    reasoningEffort: "xhigh",
  },
);
assert.equal(fableFallbackToOpus.receipt.ok, false);
assert.equal(fableFallbackToOpus.receipt.status, "failed");
assert.equal(fableFallbackToOpus.receipt.errorCode, "fallback_detected");
assert.equal(
  fableFallbackToOpus.receipt.modelAttestation.actualVendorModel,
  "claude-opus-5",
);
assert.equal(fableFallbackToOpus.receipt.fallbackCount, 1);
assert.match(fableFallbackToOpus.swiftArgs, /--status failed/);
assert.doesNotMatch(fableFallbackToOpus.swiftArgs, /--status completed/);

const fableMissingAttestation = await dispatchAgainst(
  {
    id: "resp_fable_missing_attestation",
    status: "completed",
    model: "fable-5",
    requested_model: "fable-5",
    actual_model: "claude-fable-5",
    fallback_count: 0,
    output_text: "MISSING_ATTESTATION_MUST_NOT_COMPLETE",
    reasoning_control: {
      requested: "xhigh",
      normalized: "xhigh",
      provider: "claude_cli",
      cli_flag: "--effort",
      forwarded: true,
      effective_attested: false,
    },
  },
  {
    model: "fable-5",
    allowExpensive: true,
    reasoningEffort: "xhigh",
  },
);
assert.equal(fableMissingAttestation.receipt.ok, false);
assert.equal(fableMissingAttestation.receipt.status, "failed");
assert.equal(
  fableMissingAttestation.receipt.errorCode,
  "model_attestation_missing",
);
assert.equal(fableMissingAttestation.receipt.actualVendorModel, "claude-fable-5");
assert.match(fableMissingAttestation.swiftArgs, /--status failed/);

const fableMissingProviderResponseID = await dispatchAgainst(
  exactStrictGatewayResponse("fable-5", {
    id: undefined,
    outputText: "MISSING_RESPONSE_ID_MUST_NOT_COMPLETE",
  }),
  {
    model: "fable-5",
    allowExpensive: true,
    reasoningEffort: "xhigh",
  },
);
assert.equal(fableMissingProviderResponseID.receipt.ok, false);
assert.equal(fableMissingProviderResponseID.receipt.status, "failed");
assert.equal(
  fableMissingProviderResponseID.receipt.errorCode,
  "provider_response_id_missing",
);
assert.match(fableMissingProviderResponseID.swiftArgs, /--status failed/);

const grokWrongVendorAlias = await dispatchAgainst(
  {
    ...exactStrictGatewayResponse("grok-build", {
      id: "resp_grok_wrong_vendor_alias",
      outputText: "GROK_VENDOR_ALIAS_MUST_NOT_COMPLETE",
    }),
    actual_model: "grok",
    model_attestation: {
      ...exactStrictGatewayResponse("grok-build", {
        id: "resp_grok_wrong_vendor_alias_inner",
        outputText: "GROK_VENDOR_ALIAS_MUST_NOT_COMPLETE",
      }).model_attestation,
      actual_vendor_model: "grok",
    },
  },
  {
    model: "grok-build",
    identity: "sub",
    contractBindingID: "binding-general-xxl-exact-loops-sub-grok-0",
    contractSourceSlotID: "general-xxl-exact-loops-sub-grok",
    contractReasoningEffort: "xhigh",
    reasoningEffort: "xhigh",
  },
);
assert.equal(grokWrongVendorAlias.receipt.ok, false);
assert.equal(grokWrongVendorAlias.receipt.status, "failed");
assert.equal(grokWrongVendorAlias.receipt.errorCode, "model_attestation_mismatch");
assert.equal(grokWrongVendorAlias.receipt.actualVendorModel, "grok");
assert.equal(grokWrongVendorAlias.receipt.modelAttestation.requiredVendorModel, "grok-4.6");
assert.match(grokWrongVendorAlias.swiftArgs, /--status failed/);

const fableCompletedBlocker = await dispatchAgainst(
  exactStrictGatewayResponse("fable-5", {
    id: "resp_fable_completed_blocker",
    outputText:
      "blocker_class=tool_unavailable authority_source=runner; no matching bridged host tool was exposed.",
  }),
  {
    model: "fable-5",
    allowExpensive: true,
    reasoningEffort: "xhigh",
  },
);
assert.equal(fableCompletedBlocker.receipt.ok, false);
assert.equal(fableCompletedBlocker.receipt.status, "failed");
assert.equal(fableCompletedBlocker.receipt.errorCode, "tool_unavailable");
assert.match(fableCompletedBlocker.swiftArgs, /--status failed/);
assert.doesNotMatch(fableCompletedBlocker.swiftArgs, /--status completed/);

const fableContradictoryClearMarker = await dispatchAgainst(
  exactStrictGatewayResponse("fable-5", {
    id: "resp_fable_contradictory_clear_marker",
    blocker_class: "none",
    outputText:
      "blocker_class=tool_unavailable authority_source=runner; current host tool is unavailable.",
  }),
  {
    model: "fable-5",
    allowExpensive: true,
    reasoningEffort: "xhigh",
  },
);
assert.equal(fableContradictoryClearMarker.receipt.ok, false);
assert.equal(fableContradictoryClearMarker.receipt.status, "failed");
assert.equal(
  fableContradictoryClearMarker.receipt.errorCode,
  "tool_unavailable",
);
assert.match(fableContradictoryClearMarker.swiftArgs, /--status failed/);
assert.doesNotMatch(
  fableContradictoryClearMarker.swiftArgs,
  /--status completed/,
);

const fableContradictoryAuthBlocker = await dispatchAgainst(
  exactStrictGatewayResponse("fable-5", {
    id: "resp_fable_contradictory_auth_blocker",
    blocker_class: "none",
    outputText:
      "blocker_class=auth authority_source=runner; current authentication is unavailable.",
  }),
  {
    model: "fable-5",
    allowExpensive: true,
    reasoningEffort: "xhigh",
  },
);
assert.equal(fableContradictoryAuthBlocker.receipt.ok, false);
assert.equal(fableContradictoryAuthBlocker.receipt.status, "failed");
assert.equal(
  fableContradictoryAuthBlocker.receipt.errorCode,
  "blocker_reported",
);
assert.match(fableContradictoryAuthBlocker.swiftArgs, /--status failed/);
assert.doesNotMatch(
  fableContradictoryAuthBlocker.swiftArgs,
  /--status completed/,
);

const fableQuotedHistoricalBlocker = await dispatchAgainst(
  exactStrictGatewayResponse("fable-5", {
    id: "resp_fable_quoted_historical_blocker",
    outputText:
      "I am only quoting prior logs: blocker_class=auth happened earlier, but the current review succeeded.",
  }),
  {
    model: "fable-5",
    allowExpensive: true,
    reasoningEffort: "xhigh",
  },
);
assert.equal(fableQuotedHistoricalBlocker.receipt.ok, true);
assert.equal(fableQuotedHistoricalBlocker.receipt.status, "completed");
assert.match(fableQuotedHistoricalBlocker.swiftArgs, /--status completed/);

const fableFencedHistoricalBlocker = await dispatchAgainst(
  exactStrictGatewayResponse("fable-5", {
    id: "resp_fable_fenced_historical_blocker",
    outputText: [
      "Prior diagnostic for discussion:",
      "```text",
      "blocker_class=auth authority_source=runner",
      "```",
      "The current review succeeded.",
    ].join("\n"),
  }),
  {
    model: "fable-5",
    allowExpensive: true,
    reasoningEffort: "xhigh",
  },
);
assert.equal(fableFencedHistoricalBlocker.receipt.ok, true);
assert.equal(fableFencedHistoricalBlocker.receipt.status, "completed");
assert.match(fableFencedHistoricalBlocker.swiftArgs, /--status completed/);

const fableUnterminatedFenceBlocker = await dispatchAgainst(
  exactStrictGatewayResponse("fable-5", {
    id: "resp_fable_unterminated_fence_blocker",
    blocker_class: "none",
    outputText: [
      "Malformed diagnostic excerpt:",
      "```text",
      "historical context was not closed",
      "blocker_class=auth authority_source=runner",
    ].join("\n"),
  }),
  {
    model: "fable-5",
    allowExpensive: true,
    reasoningEffort: "xhigh",
  },
);
assert.equal(fableUnterminatedFenceBlocker.receipt.ok, false);
assert.equal(fableUnterminatedFenceBlocker.receipt.status, "failed");
assert.equal(
  fableUnterminatedFenceBlocker.receipt.errorCode,
  "blocker_reported",
);
assert.match(fableUnterminatedFenceBlocker.swiftArgs, /--status failed/);
assert.doesNotMatch(
  fableUnterminatedFenceBlocker.swiftArgs,
  /--status completed/,
);

const fableBlockquoteAndBacktickHistory = await dispatchAgainst(
  exactStrictGatewayResponse("fable-5", {
    id: "resp_fable_blockquote_and_backtick_history",
    outputText: [
      "> blocker_class=auth authority_source=runner",
      "`blocker_class=tool_unavailable` was a historical example.",
      "The current review succeeded.",
    ].join("\n"),
  }),
  {
    model: "fable-5",
    allowExpensive: true,
    reasoningEffort: "xhigh",
  },
);
assert.equal(fableBlockquoteAndBacktickHistory.receipt.ok, true);
assert.equal(fableBlockquoteAndBacktickHistory.receipt.status, "completed");
assert.match(
  fableBlockquoteAndBacktickHistory.swiftArgs,
  /--status completed/,
);

const fableCompletedStructuredToolError = await dispatchAgainst(
  {
    ...exactStrictGatewayResponse("fable-5", {
      id: "resp_fable_structured_tool_error",
      outputText: "PARTIAL_TEXT_MUST_NOT_COMPLETE",
    }),
    output: [
      {
        type: "tool_error",
        status: "failed",
        error: { message: "bridged tool unavailable" },
      },
    ],
  },
  {
    model: "fable-5",
    allowExpensive: true,
    reasoningEffort: "xhigh",
  },
);
assert.equal(fableCompletedStructuredToolError.receipt.ok, false);
assert.equal(fableCompletedStructuredToolError.receipt.status, "failed");
assert.equal(fableCompletedStructuredToolError.receipt.errorCode, "tool_error");
assert.match(fableCompletedStructuredToolError.swiftArgs, /--status failed/);

const validExactFable = await dispatchAgainst(
  exactStrictGatewayResponse("fable-5", {
    id: "resp_fable_exact",
    outputText: "FABLE_EXACT_OK",
  }),
  {
    model: "fable-5",
    allowExpensive: true,
    reasoningEffort: "xhigh",
  },
);
assert.equal(validExactFable.receipt.ok, true);
assert.equal(validExactFable.receipt.status, "completed");
assert.equal(validExactFable.receipt.actualCanonicalModel, "fable-5");
assert.equal(validExactFable.receipt.actualVendorModel, "claude-fable-5");
assert.equal(validExactFable.receipt.fallbackCount, 0);
assert.equal(validExactFable.receipt.responseID, "resp_fable_exact");
assert.equal(validExactFable.receipt.modelAttestation.outcome, "VERIFIED_EXACT");
assert.equal(validExactFable.receipt.reasoningEvidence.requested, "xhigh");
assert.equal(validExactFable.receipt.reasoningEvidence.observed, "xhigh");

const bindingIdentityMismatch = await dispatchAgainst(
  { id: "resp_binding_identity_mismatch", status: "completed", output_text: "NO_CALL" },
  {
    model: "haiku-4-5",
    identity: "sub",
    identitySlots: [{
      id: "binding-test-verifier-0",
      identity: "verifier",
      modelID: "haiku-4-5",
    }],
    scenarioBindings: [{
      id: "test-verifier",
      identity: "verifier",
      boundModelIDs: ["haiku-4-5"],
      reasoningEffort: "xhigh",
    }],
  },
);
assert.equal(bindingIdentityMismatch.receipt.ok, false);
assert.equal(bindingIdentityMismatch.receipt.errorCode, "contract_binding_missing");
assert.equal(bindingIdentityMismatch.gatewayCalls, 0);
assert.doesNotMatch(bindingIdentityMismatch.swiftArgs, /os dispatch begin/);

const callerBindingMismatch = await dispatchAgainst(
  { id: "resp_binding_id_mismatch", status: "completed", output_text: "NO_CALL" },
  {
    model: "haiku-4-5",
    bindingID: "binding-caller-invented-0",
  },
);
assert.equal(callerBindingMismatch.receipt.ok, false);
assert.equal(callerBindingMismatch.receipt.errorCode, "contract_binding_mismatch");
assert.equal(callerBindingMismatch.gatewayCalls, 0);
assert.doesNotMatch(callerBindingMismatch.swiftArgs, /os dispatch begin/);

const callerSourceSlotMismatch = await dispatchAgainst(
  { id: "resp_source_slot_mismatch", status: "completed", output_text: "NO_CALL" },
  {
    model: "haiku-4-5",
    sourceSlotID: "caller-invented-slot",
  },
);
assert.equal(callerSourceSlotMismatch.receipt.ok, false);
assert.equal(
  callerSourceSlotMismatch.receipt.errorCode,
  "contract_binding_mismatch",
);
assert.equal(callerSourceSlotMismatch.gatewayCalls, 0);
assert.doesNotMatch(callerSourceSlotMismatch.swiftArgs, /os dispatch begin/);

const ambiguousContractBinding = await dispatchAgainst(
  { id: "resp_ambiguous_binding", status: "completed", output_text: "NO_CALL" },
  {
    model: "haiku-4-5",
    identitySlots: [
      {
        id: "binding-ambiguous-verifier-a-0",
        identity: "verifier",
        modelID: "haiku-4-5",
      },
      {
        id: "binding-ambiguous-verifier-b-0",
        identity: "verifier",
        modelID: "haiku-4-5",
      },
    ],
    scenarioBindings: [
      {
        id: "ambiguous-verifier-a",
        identity: "verifier",
        boundModelIDs: ["haiku-4-5"],
        reasoningEffort: "xhigh",
      },
      {
        id: "ambiguous-verifier-b",
        identity: "verifier",
        boundModelIDs: ["haiku-4-5"],
        reasoningEffort: "xhigh",
      },
    ],
  },
);
assert.equal(ambiguousContractBinding.receipt.ok, false);
assert.equal(
  ambiguousContractBinding.receipt.errorCode,
  "contract_binding_ambiguous",
);
assert.equal(ambiguousContractBinding.gatewayCalls, 0);

const disambiguatedContractBinding = await dispatchAgainst(
  { id: "resp_disambiguated_binding", status: "completed", output_text: "BOUND_OK" },
  {
    model: "haiku-4-5",
    bindingID: "binding-ambiguous-verifier-b-0",
    sourceSlotID: "ambiguous-verifier-b",
    identitySlots: [
      {
        id: "binding-ambiguous-verifier-a-0",
        identity: "verifier",
        modelID: "haiku-4-5",
      },
      {
        id: "binding-ambiguous-verifier-b-0",
        identity: "verifier",
        modelID: "haiku-4-5",
      },
    ],
    scenarioBindings: [
      {
        id: "ambiguous-verifier-a",
        identity: "verifier",
        boundModelIDs: ["haiku-4-5"],
        reasoningEffort: "xhigh",
      },
      {
        id: "ambiguous-verifier-b",
        identity: "verifier",
        boundModelIDs: ["haiku-4-5"],
        reasoningEffort: "xhigh",
      },
    ],
  },
);
assert.equal(disambiguatedContractBinding.receipt.ok, true);
assert.equal(
  disambiguatedContractBinding.receipt.bindingID,
  "binding-ambiguous-verifier-b-0",
);
assert.equal(
  disambiguatedContractBinding.receipt.sourceSlotID,
  "ambiguous-verifier-b",
);
assert.match(
  disambiguatedContractBinding.swiftArgs,
  /--binding binding-ambiguous-verifier-b-0 --slot ambiguous-verifier-b/,
);

const contractEffortMismatch = await dispatchAgainst(
  { id: "resp_effort_mismatch", status: "completed", output_text: "NO_CALL" },
  {
    model: "haiku-4-5",
    reasoningEffort: "xhigh",
    contractReasoningEffort: "low",
  },
);
assert.equal(contractEffortMismatch.receipt.ok, false);
assert.equal(
  contractEffortMismatch.receipt.errorCode,
  "contract_reasoning_effort_mismatch",
);
assert.equal(contractEffortMismatch.gatewayCalls, 0);
assert.doesNotMatch(contractEffortMismatch.swiftArgs, /os dispatch begin/);

const contractEffortDefaulted = await dispatchAgainst(
  { id: "resp_effort_defaulted", status: "completed", output_text: "LOW_OK" },
  {
    model: "haiku-4-5",
    contractReasoningEffort: "low",
  },
);
assert.equal(contractEffortDefaulted.receipt.ok, true);
assert.equal(contractEffortDefaulted.receipt.reasoningEffort, "low");
assert.equal(
  contractEffortDefaulted.receipt.contractRequiredReasoningEffort,
  "low",
);
assert.deepEqual(contractEffortDefaulted.gatewayRequestBody?.reasoning, {
  effort: "low",
});

for (const exactRoute of [
  {
    model: "gpt-5.6-sol",
    identity: "lead",
    bindingID: "binding-general-xxl-exact-plan-lead-sol-0",
    sourceSlotID: "general-xxl-exact-plan-lead-sol",
    requiredEffort: "low",
    allowExpensive: false,
    response: {
      id: "resp_exact_xxl_sol",
      status: "completed",
      output_text: "SOL_EXACT_OK",
    },
  },
  {
    model: "fable-5",
    identity: "supervisor",
    bindingID: "binding-general-xxl-exact-loops-supervisor-fable5-0",
    sourceSlotID: "general-xxl-exact-loops-supervisor-fable5",
    requiredEffort: null,
    reasoningEffort: "xhigh",
    allowExpensive: true,
    response: exactStrictGatewayResponse("fable-5", {
      id: "resp_exact_xxl_fable",
      outputText: "FABLE_REVIEW_EXACT_OK",
    }),
  },
  {
    model: "gpt-5.6-luna",
    identity: "sub",
    bindingID: "binding-general-xxl-exact-loops-sub-luna-0",
    sourceSlotID: "general-xxl-exact-loops-sub-luna",
    requiredEffort: "xhigh",
    allowExpensive: false,
    response: {
      id: "resp_exact_xxl_luna",
      status: "completed",
      output_text: "LUNA_EXACT_OK",
    },
  },
  {
    model: "grok-build",
    identity: "sub",
    bindingID: "binding-general-xxl-exact-loops-sub-grok-0",
    sourceSlotID: "general-xxl-exact-loops-sub-grok",
    requiredEffort: "xhigh",
    reasoningEffort: "xhigh",
    allowExpensive: false,
    response: exactStrictGatewayResponse("grok-build", {
      id: "resp_exact_xxl_grok",
      outputText: "GROK_EXACT_OK",
    }),
  },
]) {
  const exactResult = await dispatchAgainst(exactRoute.response, {
    model: exactRoute.model,
    identity: exactRoute.identity,
    contractBindingID: exactRoute.bindingID,
    contractSourceSlotID: exactRoute.sourceSlotID,
    contractReasoningEffort: exactRoute.requiredEffort,
    allowExpensive: exactRoute.allowExpensive,
    ...(exactRoute.reasoningEffort
      ? { reasoningEffort: exactRoute.reasoningEffort }
      : {}),
  });
  assert.equal(exactResult.receipt.ok, true, exactRoute.model);
  assert.equal(exactResult.receipt.bindingID, exactRoute.bindingID);
  assert.equal(exactResult.receipt.sourceSlotID, exactRoute.sourceSlotID);
  assert.equal(
    exactResult.receipt.contractRequiredReasoningEffort,
    exactRoute.requiredEffort,
  );
  assert.match(exactResult.swiftArgs, new RegExp(
    `--binding ${exactRoute.bindingID} --slot ${exactRoute.sourceSlotID}`,
  ));
}

for (const testCase of [
  {
    model: "fable-5",
    provider: "claude_cli",
    cliFlag: "--effort",
    allowExpensive: true,
  },
  {
    model: "opus-5",
    provider: "claude_cli",
    cliFlag: "--effort",
    allowExpensive: true,
  },
  {
    model: "grok-build",
    provider: "grok_cli",
    cliFlag: "--reasoning-effort",
    allowExpensive: false,
  },
]) {
  const result = await dispatchAgainst(
    exactStrictGatewayResponse(testCase.model, {
      id: `resp_reasoning_${testCase.model}`,
      outputText: `REASONING_${testCase.model}_OK`,
      reasoning_control: {
        requested: "xhigh",
        normalized: "xhigh",
        provider: testCase.provider,
        cli_flag: testCase.cliFlag,
        forwarded: true,
        effective_attested: false,
      },
    }),
    {
      model: testCase.model,
      allowExpensive: testCase.allowExpensive,
      reasoningEffort: "xhigh",
    },
  );

  assert.deepEqual(
    result.gatewayRequestBody?.reasoning,
    { effort: "xhigh" },
    `${testCase.model} must receive the native gateway reasoning request`,
  );
  assert.equal(
    result.receipt.reasoningForwarded,
    true,
    `${testCase.model} must use the gateway reasoning_control evidence`,
  );
  assert.deepEqual(
    result.receipt.reasoningControl,
    {
      requested: "xhigh",
      normalized: "xhigh",
      provider: testCase.provider,
      cli_flag: testCase.cliFlag,
      forwarded: true,
      effective_attested: false,
    },
  );
}

const externalReasoningMismatch = await dispatchAgainst(
  exactStrictGatewayResponse("fable-5", {
    id: "resp_reasoning_mismatch",
    outputText: "REASONING_MISMATCH_CONTENT_OK",
    reasoning_control: {
      requested: "xhigh",
      normalized: "high",
      provider: "claude_cli",
      cli_flag: "--effort",
      forwarded: true,
      effective_attested: false,
    },
  }),
  {
    model: "fable-5",
    allowExpensive: true,
    reasoningEffort: "xhigh",
  },
);
assert.equal(externalReasoningMismatch.receipt.ok, false);
assert.equal(externalReasoningMismatch.receipt.status, "failed");
assert.equal(
  externalReasoningMismatch.receipt.errorCode,
  "reasoning_attestation_mismatch",
);
assert.equal(
  externalReasoningMismatch.receipt.reasoningForwarded,
  false,
  "a mismatched gateway control must never be promoted to a forwarding claim",
);
assert.equal(
  externalReasoningMismatch.receipt.reasoningControl.normalized,
  "high",
);
assert.match(externalReasoningMismatch.swiftArgs, /--status failed/);

const gptLocalGuardReasoning = await dispatchAgainst(
  {
    id: "resp_gpt_local_guard",
    status: "completed",
    output_text: "LOCAL_CONTEXT_GUARD_COMPLETION",
    reasoning_control: {
      requested: "xhigh",
      normalized: "xhigh",
      provider: "chatgpt_subscription",
      cli_flag: null,
      forwarded: false,
      effective_attested: false,
    },
  },
  {
    model: "gpt-5.4",
    reasoningEffort: "xhigh",
  },
);
assert.equal(gptLocalGuardReasoning.receipt.ok, true);
assert.equal(gptLocalGuardReasoning.receipt.status, "completed");
assert.equal(
  gptLocalGuardReasoning.receipt.reasoningForwarded,
  false,
  "a gateway-local GPT completion must not be mislabeled as upstream forwarding",
);
assert.equal(
  gptLocalGuardReasoning.receipt.reasoningControl.forwarded,
  false,
);

const gptMissingProviderAttestationIsExplicitlyLimited = await dispatchAgainst(
  {
    id: "resp_gpt_unattested_provider_fields",
    status: "completed",
    output_text: "GPT_NON_STRICT_COMPLETION",
  },
  {
    model: "gpt-5.4",
    reasoningEffort: "xhigh",
  },
);
assert.equal(gptMissingProviderAttestationIsExplicitlyLimited.receipt.ok, true);
assert.equal(
  gptMissingProviderAttestationIsExplicitlyLimited.receipt.modelAttestation.required,
  false,
);
assert.equal(
  gptMissingProviderAttestationIsExplicitlyLimited.receipt.actualVendorModel,
  null,
);
assert.equal(
  gptMissingProviderAttestationIsExplicitlyLimited.receipt.fallbackCount,
  null,
);
assert.equal(
  gptMissingProviderAttestationIsExplicitlyLimited.receipt.reasoningForwarded,
  false,
);
assert.equal(
  gptMissingProviderAttestationIsExplicitlyLimited.receipt.reasoningControl,
  null,
);
assert.match(
  gptMissingProviderAttestationIsExplicitlyLimited.receipt
    .providerEvidenceLimitations
    .join(" "),
  /provider response did not attest forwarding or effective effort/,
);

const incompleteRouteHealth = await dispatchAgainst(
  {
    id: "resp_incomplete_route_health_must_not_run",
    status: "completed",
    output_text: "MUST_NOT_RUN",
  },
  {
    healthBody: {
      ok: true,
      degraded: false,
      routes: {
        "haiku-4-5": {
          status: "healthy",
          attempts: 1,
        },
      },
    },
  },
);
assert.equal(incompleteRouteHealth.receipt.ok, false);
assert.equal(incompleteRouteHealth.receipt.status, "blocked");
assert.match(incompleteRouteHealth.receipt.error, /route_health_v2_required:haiku-4-5:route_health_v2_incomplete/);
assert.equal(incompleteRouteHealth.gatewayCalls, 0);

const staleObservedAt = new Date(Date.now() - (16 * 60 * 1000)).toISOString();
const staleRouteHealth = await dispatchAgainst(
  {
    id: "resp_stale_route_health_must_not_run",
    status: "completed",
    output_text: "MUST_NOT_RUN",
  },
  {
    healthBody: {
      ok: true,
      degraded: false,
      routes: {
        "haiku-4-5": {
          status: "healthy",
          healthy: true,
          attempts: 1,
          has_error: false,
          error_kind: null,
          observed_at: staleObservedAt,
          last_ok_at: staleObservedAt,
          last_error_at: null,
        },
      },
    },
  },
);
assert.equal(staleRouteHealth.receipt.ok, false);
assert.match(staleRouteHealth.receipt.error, /route_health_stale/);
assert.equal(staleRouteHealth.gatewayCalls, 0);

const sonnetAlias = await dispatchAgainst(
  {
    id: "resp_sonnet_alias",
    status: "completed",
    output_text: "SONNET_ALIAS_OK",
  },
  {
    model: "sonnet-4-6",
    routeID: "sonnet-4-6",
    catalogModelID: "sonnet-4-6",
  },
);
assert.equal(sonnetAlias.receipt.ok, true);
assert.equal(sonnetAlias.receipt.model, "sonnet-5");
assert.equal(sonnetAlias.receipt.routeHealth.schema, "TatwoRouteHealthReceiptV2");

const historicalEvidenceID = await dispatchAgainst(
  {
    id: "resp_historical_evidence_must_not_run",
    status: "completed",
    output_text: "MUST_NOT_RUN",
  },
  {
    model: "sonnet-5-web-arena-v1-20260702",
  },
);
assert.equal(historicalEvidenceID.receipt.ok, false);
assert.match(historicalEvidenceID.receipt.error, /model not allowlisted/);
assert.equal(historicalEvidenceID.healthCalls, 0);
assert.equal(historicalEvidenceID.gatewayCalls, 0);

const beginFailure = await dispatchAgainst(
  {
    id: "resp_must_not_run",
    status: "completed",
    output_text: "GATEWAY_MUST_NOT_RUN",
  },
  { failBegin: true },
);
assert.equal(beginFailure.receipt.ok, false);
assert.equal(beginFailure.receipt.status, "failed");
assert.match(beginFailure.receipt.error, /dispatch_registry_begin_failed/);
assert.equal(beginFailure.gatewayCalls, 0);

const beginFailureWithBuildNoise = await dispatchAgainst(
  {
    id: "resp_must_not_run_with_build_noise",
    status: "completed",
    output_text: "GATEWAY_MUST_NOT_RUN",
  },
  { failBeginWithBuildNoise: true },
);
assert.equal(beginFailureWithBuildNoise.receipt.ok, false);
assert.match(beginFailureWithBuildNoise.receipt.error, /GoalRun succeeded cannot begin a new dispatch/);
assert.doesNotMatch(beginFailureWithBuildNoise.receipt.error, /Building for debugging/);
assert.equal(beginFailureWithBuildNoise.gatewayCalls, 0);

const terminalUpdateFailure = await dispatchAgainst(
  {
    id: "resp_update_failure",
    status: "completed",
    output_text: "MODEL_COMPLETED_BUT_LEDGER_FAILED",
  },
  { failUpdate: true },
);
assert.equal(terminalUpdateFailure.receipt.ok, false);
assert.equal(terminalUpdateFailure.receipt.status, "failed");
assert.match(terminalUpdateFailure.receipt.error, /dispatch_registry_update_failed/);
assert.equal(terminalUpdateFailure.gatewayCalls, 1);

const persistentCooldown = await dispatchAgainst(
  {
    id: "resp_cooldown_must_not_run",
    status: "completed",
    output_text: "COOLDOWN_GATEWAY_MUST_NOT_RUN",
  },
  {
    cooldown: {
      schemaVersion: 1,
      provider: "haiku-4-5",
      scope: "model",
      reason: "session_limit",
      tripAtUTC: "2026-07-15T00:00:00Z",
      resetAtUTC: "2099-07-15T00:00:00Z",
      sourceEventID: "event-session-limit",
      contractID: "contract-test",
    },
    calls: 2,
  },
);
assert.equal(persistentCooldown.receipt.ok, false);
assert.equal(persistentCooldown.receipt.status, "blocked");
assert.match(persistentCooldown.receipt.error, /cooldown_blocked/);
assert.equal(persistentCooldown.gatewayCalls, 0);

const clearedWithoutProbe = await dispatchAgainst(
  {
    id: "resp_cleared_without_probe",
    status: "completed",
    output_text: "PROBE_THEN_DISPATCH",
  },
  {
    cooldown: {
      schemaVersion: 1,
      provider: "haiku-4-5",
      scope: "model",
      reason: "session_limit",
      tripAtUTC: "2020-07-15T00:00:00Z",
      resetAtUTC: "2020-07-15T00:01:00Z",
      contractID: "contract-test",
      sourceEventID: "event-cleared-without-probe",
      clearedAtUTC: "2026-07-15T08:22:00Z",
    },
  },
);
assert.equal(clearedWithoutProbe.receipt.ok, true);
assert.equal(clearedWithoutProbe.healthCalls, 2);
assert.equal(clearedWithoutProbe.gatewayCalls, 1);

const probeWithoutClear = await dispatchAgainst(
  {
    id: "resp_probe_without_clear",
    status: "completed",
    output_text: "PARTIAL_MARKER_MUST_NOT_DISPATCH",
  },
  {
    cooldown: {
      schemaVersion: 1,
      provider: "haiku-4-5",
      scope: "model",
      reason: "session_limit",
      tripAtUTC: "2020-07-15T00:00:00Z",
      resetAtUTC: "2020-07-15T00:01:00Z",
      contractID: "contract-test",
      sourceEventID: "event-probe-without-clear",
      probeAttemptedAtUTC: "2026-07-15T08:21:30Z",
      probeSucceededAtUTC: "2026-07-15T08:21:31Z",
    },
  },
);
assert.equal(probeWithoutClear.receipt.ok, false);
assert.equal(probeWithoutClear.receipt.status, "blocked");
assert.equal(probeWithoutClear.gatewayCalls, 0);

const failedGoalClearRemainsBlocked = await dispatchAgainst(
  {
    id: "resp_must_stay_blocked_after_goal_clear_failure",
    status: "completed",
    output_text: "FAIL_OPEN_REGRESSION",
  },
  {
    cooldown: {
      schemaVersion: 1,
      provider: "haiku-4-5",
      scope: "model",
      reason: "session_limit",
      tripAtUTC: "2020-07-15T00:00:00Z",
      resetAtUTC: "2020-07-15T00:01:00Z",
      sourceEventID: "event-goal-clear-failure",
      contractID: "contract-test",
    },
    failGoalClear: true,
    calls: 2,
  },
);
assert.equal(failedGoalClearRemainsBlocked.receipt.ok, false);
assert.equal(failedGoalClearRemainsBlocked.receipt.status, "blocked");
assert.match(failedGoalClearRemainsBlocked.receipt.error, /cooldown_blocked/);
assert.equal(failedGoalClearRemainsBlocked.healthCalls, 1);
assert.equal(failedGoalClearRemainsBlocked.gatewayCalls, 0);
assert.equal(
  failedGoalClearRemainsBlocked.cooldownRecord.clearedAtUTC,
  undefined,
  "GoalRun clear failure must not leave a disk record that another process treats as cleared",
);

const staleProbeLockRecovers = await dispatchAgainst(
  {
    id: "resp_after_stale_probe_lock",
    status: "completed",
    output_text: "STALE_LOCK_RECOVERED",
  },
  {
    cooldown: {
      schemaVersion: 1,
      provider: "haiku-4-5",
      scope: "model",
      reason: "session_limit",
      tripAtUTC: "2020-07-15T00:00:00Z",
      resetAtUTC: "2020-07-15T00:01:00Z",
      sourceEventID: "event-stale-lock",
      contractID: "contract-test",
    },
    staleLock: true,
  },
);
assert.equal(staleProbeLockRecovers.receipt.ok, true);
assert.equal(staleProbeLockRecovers.receipt.status, "completed");
assert.equal(staleProbeLockRecovers.receipt.output, "STALE_LOCK_RECOVERED");
assert.equal(staleProbeLockRecovers.healthCalls, 2);
assert.equal(staleProbeLockRecovers.gatewayCalls, 1);

function exactStrictGatewayResponse(
  model,
  {
    id,
    outputText,
    reasoning_control: reasoningControl,
    ...overrides
  } = {},
) {
  const vendorModels = {
    "fable-5": "claude-fable-5",
    "opus-5": "claude-opus-5",
    "grok-build": "grok-4.6",
  };
  const providers = {
    "fable-5": ["claude_cli", "--effort"],
    "opus-5": ["claude_cli", "--effort"],
    "grok-build": ["grok_cli", "--reasoning-effort"],
  };
  const vendorModel = vendorModels[model];
  const [provider, cliFlag] = providers[model] ?? [];
  assert.ok(vendorModel, `missing strict vendor fixture for ${model}`);
  return {
    id,
    status: "completed",
    model,
    requested_model: model,
    actual_model: vendorModel,
    fallback_count: 0,
    output_text: outputText,
    model_attestation: {
      schema: "TatwoGatewayModelAttestationV1",
      requested_model: model,
      requested_vendor_model: vendorModel,
      actual_canonical_model: model,
      actual_vendor_model: vendorModel,
      fallback_count: 0,
      outcome: "VERIFIED_EXACT",
      exact: true,
    },
    reasoning_control: reasoningControl ?? {
      requested: "xhigh",
      normalized: "xhigh",
      provider,
      cli_flag: cliFlag,
      forwarded: true,
      effective_attested: false,
    },
    ...overrides,
  };
}

async function dispatchAgainst(responseBody, options = {}) {
  let gatewayCalls = 0;
  let healthCalls = 0;
  let gatewayRequestBody = null;
  const now = new Date().toISOString();
  const requestedModel = options.model ?? "haiku-4-5";
  const requestedIdentity = options.identity ?? "verifier";
  const routeID = options.routeID ?? requestedModel;
  const scenarioID = options.scenarioID ?? "gateway-test-scenario";
  const sourceSlotID =
    options.contractSourceSlotID
    ?? `gateway-test-${requestedIdentity}-${requestedModel}`;
  const bindingID =
    options.contractBindingID
    ?? `binding-${sourceSlotID}-0`;
  const contractReasoningEffort = Object.hasOwn(
    options,
    "contractReasoningEffort",
  )
    ? options.contractReasoningEffort
    : "xhigh";
  const identitySlots = options.identitySlots ?? [{
    id: bindingID,
    identity: requestedIdentity,
    modelID: requestedModel,
  }];
  const scenarioBindings = options.scenarioBindings ?? [{
    id: sourceSlotID,
    identity: requestedIdentity,
    boundModelIDs: [requestedModel],
    reasoningEffort: contractReasoningEffort,
  }];
  const dashboardFixture = {
    contract: {
      contractID: "contract-test",
      scenario: scenarioID,
      mode: "XXL",
    },
    goal: {
      goalID: "goal-test",
      scenario: scenarioID,
      mode: "XXL",
    },
    identitySlots,
  };
  const scenarioFixture = {
    schema: "TatwoScenarioConfigBookV1",
    scenarios: [{
      id: scenarioID,
      modeConfigs: {
        XXL: {
          bindings: scenarioBindings,
        },
      },
    }],
  };
  const defaultHealthBody = {
    ok: true,
    degraded: false,
    routes: {
      [routeID]: {
        status: "healthy",
        healthy: true,
        attempts: 1,
        has_error: false,
        error_kind: null,
        observed_at: now,
        last_ok_at: now,
        last_error_at: null,
      },
    },
  };
  const gateway = http.createServer(async (request, response) => {
    if (request.url === "/health") {
      healthCalls += 1;
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(JSON.stringify(options.healthBody ?? defaultHealthBody));
      return;
    }
    if (request.url === "/v1/models" && request.method === "GET") {
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(JSON.stringify({
        object: "list",
        data: [{
          id: options.catalogModelID ?? routeID,
          supported_in_api: true,
        }],
      }));
      return;
    }
    if (request.url !== "/v1/responses") {
      response.writeHead(404);
      response.end();
      return;
    }
    gatewayCalls += 1;
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const rawRequestBody = Buffer.concat(chunks).toString("utf8");
    gatewayRequestBody = rawRequestBody
      ? JSON.parse(rawRequestBody)
      : null;
    response.writeHead(options.httpStatus ?? 200, {
      "Content-Type": options.contentType ?? "application/json",
    });
    response.end(
      options.rawResponseBody !== undefined
        ? options.rawResponseBody
        : JSON.stringify(responseBody));
  });
  await new Promise(resolve => gateway.listen(0, "127.0.0.1", resolve));
  const address = gateway.address();
  const fakeBin = await fs.mkdtemp(path.join(os.tmpdir(), "tatwo-mcp-test-bin-"));
  const stateDir = await fs.mkdtemp(path.join(os.tmpdir(), "tatwo-mcp-test-state-"));
  const failBegin = options.failBegin === true ? "1" : "0";
  const failBeginWithBuildNoise = options.failBeginWithBuildNoise === true ? "1" : "0";
  const failUpdate = options.failUpdate === true ? "1" : "0";
  const failGoalClear = options.failGoalClear === true ? "1" : "0";
  const swiftArgsLog = path.join(stateDir, "swift-args.log");
  await fs.writeFile(
    path.join(fakeBin, "swift"),
    [
      "#!/bin/sh",
      `printf '%s\\n' "$*" >> "$TATWO_TEST_SWIFT_ARGS_LOG"`,
      `case "$*" in`,
      `  *"os dashboard"*)`,
      `    printf '%s\\n' '${JSON.stringify({ ok: true, data: dashboardFixture })}'`,
      `    exit 0`,
      `    ;;`,
      `  *"scenario config"*)`,
      `    printf '%s\\n' '${JSON.stringify({ ok: true, data: scenarioFixture })}'`,
      `    exit 0`,
      `    ;;`,
      `  *"os contract require"*)`,
      `    printf '%s\\n' '{"ok":true,"data":{"contractID":"contract-test"}}'`,
      `    exit 0`,
      `    ;;`,
      `  *"os cooldown clear"*)`,
      `    if [ "${failGoalClear}" = "1" ]; then echo "goal clear failed" >&2; exit 1; fi`,
      `    printf '%s\\n' '{"ok":true,"data":{"status":"planned"}}'`,
      `    exit 0`,
      `    ;;`,
      `  *"os cooldown block"*)`,
      `    printf '%s\\n' '{"ok":true,"data":{"status":"blocked"}}'`,
      `    exit 0`,
      `    ;;`,
      `  *"os dispatch begin"*)`,
      `    if [ "${failBegin}" = "1" ]; then echo "begin failed" >&2; exit 1; fi`,
      `    if [ "${failBeginWithBuildNoise}" = "1" ]; then`,
      `      echo "Building for debugging..." >&2`,
      `      printf '%s\\n' '{"command":"os dispatch begin","ok":false,"error":"GoalRun succeeded cannot begin a new dispatch."}'`,
      `      exit 1`,
      `    fi`,
      `    printf '%s\\n' '{"ok":true,"data":{"id":"dispatch-test"}}'`,
      `    exit 0`,
      `    ;;`,
      `  *"os dispatch update"*)`,
      `    if [ "${failUpdate}" = "1" ]; then echo "update failed" >&2; exit 1; fi`,
      `    printf '%s\\n' '{"ok":true,"data":{"id":"dispatch-test"}}'`,
      `    exit 0`,
      `    ;;`,
      `esac`,
      `echo "unexpected swift args: $*" >&2`,
      `exit 1`,
      "",
    ].join("\n"),
    { mode: 0o755 },
  );
  if (options.cooldown) {
    const cooldownDir = path.join(stateDir, "cooldowns");
    await fs.mkdir(cooldownDir, { recursive: true });
    const cooldownFile = path.join(cooldownDir, "haiku-4-5-model.json");
    await fs.writeFile(
      cooldownFile,
      `${JSON.stringify(options.cooldown, null, 2)}\n`,
      "utf8",
    );
    if (options.staleLock === true) {
      const lockFile = `${cooldownFile}.lock`;
      await fs.writeFile(
        lockFile,
        `${JSON.stringify({
          schemaVersion: 1,
          pid: 999999,
          createdAtUTC: "2020-07-15T00:00:00Z",
          token: "stale-test-lock",
        })}\n`,
        "utf8",
      );
      const staleDate = new Date("2020-07-15T00:00:00Z");
      await fs.utimes(lockFile, staleDate, staleDate);
    }
  }

  try {
    const env = {
      ...process.env,
      PATH: `${fakeBin}:${process.env.PATH}`,
      TATWO_ULTRAWORK_STATE_DIR: stateDir,
      TATWO_MODEL_GATEWAY_URL: `http://127.0.0.1:${address.port}`,
      TATWO_GATEWAY_USE_CODEX_AUTH: "0",
      TATWO_GATEWAY_DISPATCH_TIMEOUT_MS: "5000",
      TATWO_TEST_SWIFT_ARGS_LOG: swiftArgsLog,
      TATWO_TEST_PROMPT: options.prompt || "",
      TATWO_TEST_MAX_PROMPT_CHARS: String(options.maxPromptChars ?? ""),
      TATWO_TEST_MODEL: requestedModel,
      TATWO_TEST_IDENTITY: requestedIdentity,
      TATWO_TEST_BINDING_ID: options.bindingID ?? "",
      TATWO_TEST_SOURCE_SLOT_ID: options.sourceSlotID ?? "",
      TATWO_TEST_ALLOW_EXPENSIVE: options.allowExpensive === true ? "1" : "0",
      ...(Object.hasOwn(options, "reasoningEffort")
        ? { TATWO_TEST_REASONING_EFFORT: options.reasoningEffort }
        : {}),
    };
    let response;
    for (let i = 0; i < Math.max(1, Number(options.calls ?? 1)); i += 1) {
      response = await callMCP(env);
    }
    const cooldownRecord = options.cooldown
      ? JSON.parse(await fs.readFile(
          path.join(stateDir, "cooldowns", "haiku-4-5-model.json"),
          "utf8",
        ))
      : null;
    return {
      receipt: JSON.parse(response.result.content[0].text),
      gatewayCalls,
      healthCalls,
      gatewayRequestBody,
      cooldownRecord,
      swiftArgs: await fs.readFile(swiftArgsLog, "utf8").catch(() => ""),
    };
  } finally {
    await fs.rm(fakeBin, { recursive: true, force: true });
    await fs.rm(stateDir, { recursive: true, force: true });
    await new Promise(resolve => gateway.close(resolve));
  }
}

async function callCLIBackedToolMCP({
  toolName,
  body,
  rawOutput,
  exitCode = 0,
  executable = "node",
}) {
  const fakeBin = await fs.mkdtemp(path.join(os.tmpdir(), "tatwo-mcp-classifier-bin-"));
  try {
    await fs.writeFile(
      path.join(fakeBin, executable),
      [
        "#!/bin/sh",
        `printf '%s\\n' "$TATWO_TEST_CLI_BODY"`,
        `exit "$TATWO_TEST_CLI_EXIT"`,
        "",
      ].join("\n"),
      { mode: 0o755 },
    );
    return await callMCPTool(
      {
        ...process.env,
        PATH: `${fakeBin}:${process.env.PATH}`,
        TATWO_TEST_CLI_BODY: rawOutput ?? JSON.stringify(body),
        TATWO_TEST_CLI_EXIT: String(exitCode),
      },
      toolName,
      { latest: false },
    );
  } finally {
    await fs.rm(fakeBin, { recursive: true, force: true });
  }
}

async function gatewayStatusAgainst({
  healthBody,
  catalogModelID = "haiku-4-5",
}) {
  const gateway = http.createServer((request, response) => {
    response.writeHead(200, { "Content-Type": "application/json" });
    if (request.url === "/health") {
      response.end(JSON.stringify(healthBody));
      return;
    }
    if (request.url === "/v1/models") {
      response.end(JSON.stringify({
        object: "list",
        data: [{ id: catalogModelID, supported_in_api: true }],
      }));
      return;
    }
    response.writeHead(404);
    response.end();
  });
  await new Promise(resolve => gateway.listen(0, "127.0.0.1", resolve));
  const address = gateway.address();
  try {
    return await callMCPTool(
      {
        ...process.env,
        TATWO_MODEL_GATEWAY_URL: `http://127.0.0.1:${address.port}`,
        TATWO_GATEWAY_DISPATCH_TIMEOUT_MS: "5000",
      },
      "tatwo_gateway_status",
      {},
    );
  } finally {
    await new Promise(resolve => gateway.close(resolve));
  }
}

async function remoteStatusAgainst(options = {}) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "tatwo-mcp-remote-status-"));
  const fakeBin = path.join(root, "bin");
  const appSupport = path.join(root, "app-support");
  const stateDir = path.join(root, "state");
  const swiftArgsLog = path.join(root, "swift-args.log");
  await fs.mkdir(fakeBin, { recursive: true });
  await fs.mkdir(appSupport, { recursive: true });
  await fs.mkdir(stateDir, { recursive: true });
  await fs.writeFile(
    path.join(fakeBin, "swift"),
    [
      "#!/bin/sh",
      `printf '%s\\n' "$*" >> "$TATWO_TEST_SWIFT_ARGS_LOG"`,
      `printf '%s\\n' '{"ok":true,"data":{"schema":"TatwoFleetStatusV1","devices":[],"pending":[]}}'`,
      "",
    ].join("\n"),
    { mode: 0o755 },
  );
  if (options.deviceIdentityID) {
    await fs.writeFile(
      path.join(appSupport, "device-identity.json"),
      `${JSON.stringify({
        deviceId: options.deviceIdentityID,
        name: "fixture-device",
      })}\n`,
      "utf8",
    );
  }
  if (options.stateDeviceID) {
    await fs.writeFile(
      path.join(stateDir, "local-device-id"),
      `${options.stateDeviceID}\n`,
      "utf8",
    );
  }
  if (options.trustDeviceID) {
    const trustRoot = path.join(appSupport, "device-trust");
    await fs.mkdir(trustRoot, { recursive: true });
    await fs.writeFile(
      path.join(trustRoot, "identity.json"),
      `${JSON.stringify({
        schema: "TatwoDevicePublicIdentityV1",
        deviceID: options.trustDeviceID,
      })}\n`,
      "utf8",
    );
  }
  if (options.symlinkStateDeviceID) {
    const target = path.join(root, "symlink-device-id-target");
    await fs.writeFile(target, `${options.symlinkStateDeviceID}\n`, "utf8");
    await fs.symlink(target, path.join(stateDir, "local-device-id"));
  }

  try {
    const response = await callMCPTool(
      {
        ...process.env,
        HOME: path.join(root, "home"),
        PATH: `${fakeBin}:${process.env.PATH}`,
        TATWO_ULTRAWORK_APP_SUPPORT: appSupport,
        TATWO_ULTRAWORK_STATE_DIR: stateDir,
        TATWO_TEST_SWIFT_ARGS_LOG: swiftArgsLog,
      },
      "tatwo_remote_loops_status",
      options.argumentsPayload ?? {},
    );
    return {
      response,
      swiftArgs: await fs.readFile(swiftArgsLog, "utf8").catch(() => ""),
    };
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
}

async function callMCP(env) {
  return await callMCPTool(
    env,
    "tatwo_gateway_dispatch",
    {
      contractID: "contract-test",
      model: env.TATWO_TEST_MODEL || "haiku-4-5",
      identity: env.TATWO_TEST_IDENTITY || "verifier",
      ...(env.TATWO_TEST_BINDING_ID
        ? { bindingID: env.TATWO_TEST_BINDING_ID }
        : {}),
      ...(env.TATWO_TEST_SOURCE_SLOT_ID
        ? { sourceSlotID: env.TATWO_TEST_SOURCE_SLOT_ID }
        : {}),
      purpose: "terminal status regression",
      prompt: env.TATWO_TEST_PROMPT || "Return one short test response.",
      ...(env.TATWO_TEST_REASONING_EFFORT
        ? { reasoningEffort: env.TATWO_TEST_REASONING_EFFORT }
        : {}),
      ...(env.TATWO_TEST_ALLOW_EXPENSIVE === "1"
        ? { allowExpensive: true }
        : {}),
      ...(env.TATWO_TEST_MAX_PROMPT_CHARS
        ? { maxPromptChars: Number(env.TATWO_TEST_MAX_PROMPT_CHARS) }
        : {}),
    },
  );
}

async function callMCPTool(env, name, argumentsPayload) {
  return await callMCPRequest(
    env,
    "tools/call",
    {
      name,
      arguments: argumentsPayload,
    },
  );
}

async function callMCPRequest(env, method, params) {
  return await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [serverScript], {
      cwd: repoRoot,
      env,
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error(`MCP timeout\nstdout=${stdout}\nstderr=${stderr}`));
    }, 10000);

    child.stdout.on("data", chunk => {
      stdout += chunk;
      const line = stdout.split("\n").find(candidate => candidate.trim().startsWith("{"));
      if (!line) return;
      clearTimeout(timer);
      child.kill();
      resolve(JSON.parse(line));
    });
    child.stderr.on("data", chunk => { stderr += chunk; });
    child.on("error", error => {
      clearTimeout(timer);
      reject(error);
    });

    child.stdin.end(`${JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method,
      params,
    })}\n`);
  });
}
});

async function probeLoopbackRoundtrip() {
  const server = http.createServer((_request, response) => {
    response.writeHead(204);
    response.end();
  });
  try {
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolve);
    });
    const address = server.address();
    await new Promise((resolve, reject) => {
      const request = http.get({
        host: "127.0.0.1",
        port: address.port,
        path: "/",
      }, response => {
        response.resume();
        response.on("end", () => {
          if (response.statusCode !== 204) {
            reject(new Error(`loopback probe returned HTTP ${response.statusCode}`));
            return;
          }
          resolve();
        });
      });
      request.setTimeout(2_000, () => {
        const error = new Error("loopback probe request timed out");
        error.code = "ETIMEDOUT";
        request.destroy(error);
      });
      request.on("error", reject);
    });
    return { available: true };
  } catch (error) {
    if (["EACCES", "EPERM", "EADDRNOTAVAIL", "ETIMEDOUT"].includes(error?.code)) {
      return { available: false, error };
    }
    throw error;
  } finally {
    if (server.listening) {
      await new Promise((resolve, reject) => {
        server.close(error => error ? reject(error) : resolve());
      });
    }
  }
}
