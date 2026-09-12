#!/usr/bin/env node
import assert from "node:assert/strict";
import crypto from "node:crypto";
import http from "node:http";
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const adapter = path.join(repoRoot, "scripts", "tatwo-direct-gateway-chat.mjs");

test("tatwo direct gateway chat unit (mock gateway)", async t => {
const loopbackCapability = await probeLoopbackRoundtrip();
if (!loopbackCapability.available) {
  t.skip(
    "sandbox 禁止 loopback network，非程式缺陷" +
      `（127.0.0.1 bind/connect probe ${loopbackCapability.error.code}）`,
  );
  return;
}

await testSyntheticBackendFailureCompletesAsVisibleDegradedNotice();
await testPlainQuotaFailureCompletesAsVisibleDegradedNotice();
await testSessionLimitCompletesAsVisibleDegradedNotice();
await testStructuredChineseDegradedCompletion();
await testTerminalFailureStatusesFailClosed();
await testUnexecutedToolCallsFailClosed();
await testGrokRouteEchoCannotAttest();
await testGrokSessionStateAttestationCompletes();
await testGrokCompletedSessionStateAttestationCompletes();
await testGrokUnsuccessfulOrUnknownSessionStateFailsClosed();
await testSyntheticGrokSessionStateAttestationFailsClosed();
await testGrokWrongVendorModelFailsClosed();
await testTatwoOpusArgumentAttestsAsExactOpus5();
await testHaiku45DatedVendorModelAttestsExactly();
await testMissingActualModelFailsClosed();
await testFableFallbackToOpusFailsClosed();
await testFableReasoningEffortRequiresGatewayForwardingAttestation();
await testGrokReasoningEffortRequiresGatewayForwardingAttestation();
await testExternalReasoningEffortWithoutGatewayAckFailsClosed();
await testFableImageIsForwardedAsInlineResponsesInput();
await testCurrentTurnComputerHostRouteMetadataIsBounded();
await testTextOnlyCurrentTurnAuthorityDoesNotInheritFlattenedHistory();
await testCurrentTurnAuthorityArgumentsAreMandatoryAndBounded();
await testAppliedRouteReceiptBindingFailsClosedAndCannotReplay();
await testFreshContinuationReturnsVerifiedGatewayReceipt();
await testProviderResumeAdvancesVerifiedGatewayReceipt();
await testMissingContinuationReceiptFailsClosed();
await testContinuationRouteMismatchFailsClosed();
await testLargePromptFileTransportAvoidsArgvE2BIGAndPreservesExactBytes();
await testPromptFileTransportRejectsUnsafeFilesystemInputs();
await testPromptFileTransportRejectsIntegrityAndEncodingMismatches();
await testPromptFileTransportRejectsDuplicateMixedAndOversizeInputs();
await testPromptFileReplacementAfterSecureUnlinkSurvives();
await testPromptFileCleanupAlsoHoldsWhenGatewayFails();
await testSSEProgressArrivesBeforeTerminalCompletion();
await testSSEHeartbeatsExtendInactivityTimeout();
await testSSETerminalDoesNotWaitForeverForEOF();
await testSSEDuplicateTerminalDuringGraceFailsClosed();
await testSSESilentGapFailsAtInactivityTimeout();
await testSSEWithoutDeltasFallsBackExactlyOnce();
await testSSEDisconnectFailsClosedWithoutTerminalCompletion();
await testSSEDeltaTerminalMismatchFailsClosed();
await testSSEAttestationMismatchFailsClosed();

async function testSyntheticBackendFailureCompletesAsVisibleDegradedNotice() {
  const result = await runAdapter({
    status: "completed",
    output_text: "grok-build backend is temporarily unavailable: usage balance exhausted",
  });
  assertVisibleDegradedNotice(result, "quota");
}

async function testPlainQuotaFailureCompletesAsVisibleDegradedNotice() {
  const result = await runAdapter({
    status: "completed",
    output_text: "quota exhausted: credit balance is zero",
  });
  assertVisibleDegradedNotice(result, "quota");
}

async function testSessionLimitCompletesAsVisibleDegradedNotice() {
  const result = await runAdapter({
    id: "resp_session_limit",
    status: "completed",
    output_text: "fable-5 backend is temporarily unavailable: You've hit your session limit · resets 8:20am (Asia/Tokyo)",
  });
  assertVisibleDegradedNotice(result, "session_limit");
  assert.match(result.stdout, /"reset_at":"8:20am \(Asia\/Tokyo\)"/);
}

async function testStructuredChineseDegradedCompletion() {
  const result = await runAdapter({
    id: "resp_structured_degraded",
    status: "completed",
    degraded: true,
    error_kind: "quota",
    output_text: "目前服務無法使用，請稍後再試。",
  });
  assertVisibleDegradedNotice(result, "quota");
}

async function testTerminalFailureStatusesFailClosed() {
  for (const status of ["failed", "incomplete", "cancelled"]) {
    const result = await runAdapter({
      id: `resp_${status}`,
      status,
      output_text: `partial output for ${status}`,
      error: status === "failed" ? { message: "backend failed" } : undefined,
    });
    assert.equal(result.code, 2, status);
    assert.match(result.stdout, /"type":"response\.failed"/, status);
    assert.doesNotMatch(result.stdout, /"type":"turn\.completed"/, status);
  }
}

async function testUnexecutedToolCallsFailClosed() {
  const chatCompletion = await runAdapter({
    id: "resp_naked_tool_call",
    status: "completed",
    model: "claude-fable-5",
    choices: [{
      message: {
        role: "assistant",
        content: null,
        tool_calls: [{
          id: "call_1",
          type: "function",
          function: {
            name: "exec_command",
            arguments: "{\"cmd\":\"echo MUST_NOT_RUN\"}",
          },
        }],
      },
    }],
  }, { model: "fable-5" });
  assert.equal(chatCompletion.code, 2);
  assert.match(
    chatCompletion.stdout,
    /gateway_returned_unexecuted_tool_calls: count=1 names=exec_command/,
  );
  assert.match(chatCompletion.stdout, /"type":"response\.failed"/);
  assert.doesNotMatch(chatCompletion.stdout, /MUST_NOT_RUN/);
  assert.doesNotMatch(chatCompletion.stdout, /"type":"turn\.completed"/);

  const responsesAPI = await runAdapter({
    id: "resp_function_call",
    status: "completed",
    model: "claude-fable-5",
    output: [{
      id: "fc_1",
      type: "function_call",
      name: "exec_command",
      arguments: "{\"cmd\":\"echo MUST_NOT_RUN\"}",
    }],
  }, { model: "fable-5" });
  assert.equal(responsesAPI.code, 2);
  assert.match(
    responsesAPI.stdout,
    /gateway_returned_unexecuted_tool_calls: count=1 names=exec_command/,
  );
  assert.match(responsesAPI.stdout, /"type":"response\.failed"/);
  assert.doesNotMatch(responsesAPI.stdout, /MUST_NOT_RUN/);
  assert.doesNotMatch(responsesAPI.stdout, /"type":"turn\.completed"/);
}

async function testGrokRouteEchoCannotAttest() {
  const result = await runAdapter({
    id: "resp_direct_ok",
    status: "completed",
    model: "grok-build",
    output_text: "DIRECT_ADAPTER_OK",
  }, { disableDefaultGrokAttestation: true });
  assert.equal(result.code, 2);
  assert.match(result.stdout, /gateway_model_attestation_attestation_missing/);
  assert.doesNotMatch(result.stdout, /"type":"turn\.completed"/);
}

async function testGrokSessionStateAttestationCompletes() {
  const result = await runAdapter(withExactGrokAttestation({
    id: "resp_direct_ok",
    status: "completed",
    model: "grok-build",
    output_text: "DIRECT_ADAPTER_OK",
  }));
  assert.equal(result.code, 0);
  assert.match(result.stdout, /DIRECT_ADAPTER_OK/);
  assert.match(result.stdout, /"type":"turn\.completed"/);
  assert.match(result.stdout, /"dispatch_id":"dispatch-test"/);
  assert.match(result.stdout, /"response_id":"resp_direct_ok"/);
  assert.match(result.stdout, /"requested_model":"grok-build"/);
  assert.match(result.stdout, /"actual_model":"grok-4\.6"/);
  assert.match(result.stdout, /"evidence_source":"grok_cli_session_state"/);
  assert.match(result.stdout, /"outcome":"VERIFIED_EXACT"/);
}

async function testGrokCompletedSessionStateAttestationCompletes() {
  const result = await runAdapter(withExactGrokAttestation({
    id: "resp_direct_completed_ok",
    status: "completed",
    model: "grok-build",
    output_text: "DIRECT_ADAPTER_COMPLETED_OK",
  }, {
    turnEndedOutcome: "completed",
  }));
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /DIRECT_ADAPTER_COMPLETED_OK/);
  assert.match(result.stdout, /"turn_ended_outcome":"completed"/);
  assert.match(result.stdout, /"outcome":"VERIFIED_EXACT"/);
  assert.match(result.stdout, /"type":"turn\.completed"/);
}

async function testGrokUnsuccessfulOrUnknownSessionStateFailsClosed() {
  for (const outcome of ["", "failed", "error", "cancelled", "future-value"]) {
    const result = await runAdapter(withExactGrokAttestation({
      id: `resp_direct_${outcome || "missing"}`,
      status: "completed",
      model: "grok-build",
      output_text: "MUST_NOT_COUNT_AS_LIVE_GROK",
    }, {
      turnEndedOutcome: outcome,
    }));
    assert.equal(result.code, 2, outcome || "missing");
    assert.match(
      result.stdout,
      /gateway_model_attestation_fail_closed_mismatch/,
      outcome || "missing",
    );
    assert.doesNotMatch(
      result.stdout,
      /"type":"turn\.completed"/,
      outcome || "missing",
    );
  }
}

async function testSyntheticGrokSessionStateAttestationFailsClosed() {
  const body = withExactGrokAttestation({
    id: "resp_direct_synthetic",
    status: "completed",
    model: "grok-build",
    output_text: "MUST_NOT_COUNT_AS_LIVE_GROK",
  });
  body.model_attestation.session_evidence.synthetic = true;
  const result = await runAdapter(body);
  assert.equal(result.code, 2);
  assert.match(result.stdout, /gateway_model_attestation_fail_closed_mismatch/);
  assert.doesNotMatch(result.stdout, /"type":"turn\.completed"/);
}

async function testGrokWrongVendorModelFailsClosed() {
  console.log("# grok-vendor-pin negatives: grok-4.5,grok");
  for (const actualVendorModel of ["grok-4.5", "grok"]) {
    const result = await runAdapter(withExactGrokAttestation({
      id: `resp_direct_wrong_${actualVendorModel.replace(/[^a-z0-9]/gi, "_")}`,
      status: "completed",
      model: "grok-build",
      output_text: "MUST_NOT_COUNT_AS_LIVE_GROK_VENDOR_ALIAS",
    }, {
      actualVendorModel,
    }));
    assert.equal(result.code, 2, actualVendorModel);
    assert.match(
      result.stdout,
      /gateway_model_attestation_fail_closed_mismatch/,
      actualVendorModel,
    );
    assert.match(
      result.stdout,
      new RegExp(`observed=${actualVendorModel.replace(/\./g, "\\.")}`),
      actualVendorModel,
    );
    assert.doesNotMatch(
      result.stdout,
      /"type":"turn\.completed"/,
      actualVendorModel,
    );
  }
}

async function testTatwoOpusArgumentAttestsAsExactOpus5() {
  const result = await runAdapter(
    {
      id: "resp_opus_native_alias",
      status: "completed",
      model: "opus-5",
      actual_model: "claude-opus-5",
      modelUsage: {
        "claude-opus-5": {},
      },
      output_text: "OPUS_NATIVE_ALIAS_OK",
    },
    { model: "opus" });
  assert.equal(result.code, 0);
  assert.match(result.stdout, /OPUS_NATIVE_ALIAS_OK/);
  assert.match(result.stdout, /"requested_model":"opus"/);
  assert.match(result.stdout, /"actual_model":"opus-5"/);
  assert.match(result.stdout, /"actual_canonical_model":"opus-5"/);
  assert.match(result.stdout, /"outcome":"VERIFIED_EXACT"/);
}

async function testHaiku45DatedVendorModelAttestsExactly() {
  const result = await runAdapter(
    {
      id: "resp_haiku46_dated_vendor",
      status: "completed",
      model: "haiku-4-5",
      actual_model: "claude-haiku-4-5-20260701",
      modelUsage: {
        "claude-haiku-4-5": {},
        "claude-haiku-4-5-20260701": {},
      },
      output_text: "HAIKU45_EXACT",
    },
    { model: "haiku-4-5" });
  assert.equal(result.code, 0);
  assert.match(result.stdout, /HAIKU45_EXACT/);
  assert.match(result.stdout, /"requested_model":"haiku-4-5"/);
  assert.match(result.stdout, /"actual_model":"haiku-4-5"/);
  assert.match(result.stdout, /"actual_canonical_model":"haiku-4-5"/);
  assert.match(result.stdout, /"outcome":"VERIFIED_EXACT"/);
}

async function testMissingActualModelFailsClosed() {
  const result = await runAdapter({
    id: "resp_missing_model",
    status: "completed",
    output_text: "UNATTESTED_OUTPUT",
  });
  assert.equal(result.code, 2);
  assert.match(result.stdout, /gateway_model_attestation_attestation_missing/);
  assert.doesNotMatch(result.stdout, /"type":"turn\.completed"/);
}

async function testFableFallbackToOpusFailsClosed() {
  const result = await runAdapter(
    {
      id: "resp_fable_fallback",
      status: "completed",
      model: "claude-opus-5",
      modelUsage: {
        "claude-fable-5": {},
        "claude-opus-5[1m]": {},
      },
      output_text: "MUST_NOT_COUNT_AS_FABLE",
    },
    { model: "fable-5" });
  assert.equal(result.code, 2);
  assert.match(result.stdout, /gateway_model_attestation_fail_closed_mismatch/);
  assert.match(result.stdout, /observed=claude-opus-5/);
  assert.doesNotMatch(result.stdout, /"type":"turn\.completed"/);
}

async function testFableReasoningEffortRequiresGatewayForwardingAttestation() {
  const result = await runAdapter(
    {
      id: "resp_fable_effort_forwarded",
      status: "completed",
      model: "claude-fable-5",
      reasoning_control: {
        requested: "high",
        normalized: "high",
        provider: "claude_cli",
        cli_flag: "--effort",
        forwarded: true,
        effective_attested: false,
      },
      output_text: "FABLE_EFFORT_OK",
    },
    {
      model: "fable-5",
      extraArgs: ["--reasoning-effort", "high"],
    });
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(result.requestBody.reasoning, { effort: "high" });
  assert.match(result.stdout, /"requested":"high"/);
  assert.match(result.stdout, /"normalized":"high"/);
  assert.match(result.stdout, /"forwardedNativeField":true/);
  assert.match(result.stdout, /"provider":"claude_cli"/);
  assert.match(result.stdout, /"cliFlag":"--effort"/);
  assert.match(result.stdout, /"effectiveProviderAttested":false/);
}

async function testGrokReasoningEffortRequiresGatewayForwardingAttestation() {
  const result = await runAdapter(
    {
      id: "resp_grok_effort_forwarded",
      status: "completed",
      model: "grok-build",
      reasoning_control: {
        requested: "xhigh",
        normalized: "xhigh",
        provider: "grok_cli",
        cli_flag: "--reasoning-effort",
        forwarded: true,
        effective_attested: false,
      },
      output_text: "GROK_EFFORT_OK",
    },
    {
      model: "grok-build",
      extraArgs: ["--reasoning-effort", "xhigh"],
    });
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(result.requestBody.reasoning, { effort: "xhigh" });
  assert.match(result.stdout, /"forwardedNativeField":true/);
  assert.match(result.stdout, /"provider":"grok_cli"/);
  assert.match(result.stdout, /"cliFlag":"--reasoning-effort"/);
}

async function testExternalReasoningEffortWithoutGatewayAckFailsClosed() {
  const result = await runAdapter(
    {
      id: "resp_fable_effort_unattested",
      status: "completed",
      model: "claude-fable-5",
      output_text: "MUST_NOT_COMPLETE",
    },
    {
      model: "fable-5",
      extraArgs: ["--reasoning-effort", "high"],
    });
  assert.equal(result.code, 2);
  assert.deepEqual(result.requestBody.reasoning, { effort: "high" });
  assert.match(
    result.stdout,
    /gateway_reasoning_forwarding_attestation_missing_or_mismatch/,
  );
  assert.doesNotMatch(result.stdout, /"type":"turn\.completed"/);
}

async function testFableImageIsForwardedAsInlineResponsesInput() {
  const fixture = await fs.mkdtemp(path.join(os.tmpdir(), "tatwo-direct-image-"));
  const imagePath = path.join(fixture, "proof.png");
  await fs.writeFile(
    imagePath,
    Buffer.from(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
      "base64"));
  try {
    const result = await runAdapter(
      {
        id: "resp_image_ok",
        status: "completed",
        model: "claude-fable-5",
        output_text: "IMAGE_OK",
      },
      {
        model: "fable-5",
        extraArgs: ["--image", imagePath],
      });
    assert.equal(result.code, 0);
    assert.equal(result.requestBody.model, "fable-5");
    assert.match(result.stdout, /"model":"fable-5"/);
    assert.match(result.stdout, /"actual_model":"claude-fable-5"/);
    assert.equal(result.requestBody.input[0].role, "user");
    assert.equal(result.requestBody.input[0].content[0].type, "input_text");
    assert.equal(result.requestBody.input[0].content[1].type, "input_image");
    assert.match(result.requestBody.input[0].content[1].image_url, /^data:image\/png;base64,/);
  } finally {
    await fs.rm(fixture, { recursive: true, force: true });
  }
}

async function testCurrentTurnComputerHostRouteMetadataIsBounded() {
  const flattenedPrompt = [
    "[Earlier user]",
    "必須以 [@電腦](plugin://computer-use@openai-bundled) 操作 App。",
    "[Current user]",
    "本輪只做純文字審查。",
  ].join("\n");
  for (const [route, expectedWireRoute] of [
    ["none", "none"],
    ["embedded_intent", "embedded_intent"],
    ["mcp", "request_scoped_tool"],
  ]) {
    const result = await runAdapter(
      {
        id: `resp_current_turn_${route}`,
        status: "completed",
        model: "grok-build",
        output_text: `CURRENT_TURN_${route.toUpperCase()}_OK`,
      },
      {
        prompt: flattenedPrompt,
        extraArgs: ["--computer-host-route", route],
      });
    assert.equal(result.code, 0, result.stderr);
    assertCurrentTurnAuthorityRequest(result, {
      expectedWireRoute,
      currentVisibleTurn: flattenedPrompt,
    });
  }

  const omittedRoute = await runAdapter({
    id: "resp_current_turn_default_none",
    status: "completed",
    model: "grok-build",
    output_text: "CURRENT_TURN_DEFAULT_NONE_OK",
  });
  assert.equal(omittedRoute.code, 0, omittedRoute.stderr);
  assertCurrentTurnAuthorityRequest(omittedRoute, {
    expectedWireRoute: "none",
    currentVisibleTurn: "test",
  });

  const invalid = await runAdapter(null, {
    prompt: "test",
    extraArgs: ["--computer-host-route", "unbounded"],
  });
  assert.equal(invalid.code, 2);
  assert.equal(invalid.requestBody, null);
  assert.match(invalid.stdout, /invalid_computer_host_route/);
}

async function testTextOnlyCurrentTurnAuthorityDoesNotInheritFlattenedHistory() {
  const cases = [
    {
      model: "grok-build",
      responseModel: "grok-build",
      currentTurn: "不要工具、不要 Computer Use，只做純文字。",
      outputText: "GROK_TEXT_ONLY_OK",
    },
    {
      model: "grok-build",
      responseModel: "grok-build",
      currentTurn: "Do not use any tools; do not use Computer Use; text only.",
      outputText: "GROK_ENGLISH_TEXT_ONLY_OK",
    },
    {
      model: "fable-5",
      responseModel: "claude-fable-5",
      currentTurn: "不要工具、不要 Computer Use，只做純文字。",
      outputText: "FABLE_TEXT_ONLY_OK",
    },
    {
      model: "fable-5",
      responseModel: "claude-fable-5",
      currentTurn: "Do not use any tools; do not use Computer Use; text only.",
      outputText: "FABLE_ENGLISH_TEXT_ONLY_OK",
    },
  ];

  for (const testCase of cases) {
    const flattenedPrompt = [
      "[Hidden TATWO same-thread transcript bridge]",
      "[user] Use Computer Use to open the browser.",
      "[assistant] The previous route failed because Computer Use was unavailable.",
      "[/Hidden TATWO same-thread transcript bridge]",
      "",
      testCase.currentTurn,
    ].join("\n");
    const result = await runAdapter(
      {
        id: `resp_${testCase.outputText.toLowerCase()}`,
        status: "completed",
        model: testCase.responseModel,
        output_text: testCase.outputText,
      },
      {
        model: testCase.model,
        prompt: flattenedPrompt,
        currentVisibleTurn: testCase.currentTurn,
        extraArgs: ["--computer-host-route", "none"],
      });

    assert.equal(result.code, 0, result.stderr);
    assert.equal(result.requestCount, 1);
    assert.equal(result.requestBody.input, flattenedPrompt);
    assert.equal(result.requestBody.tools, undefined);
    assertCurrentTurnAuthorityRequest(result, {
      expectedWireRoute: "none",
      currentVisibleTurn: testCase.currentTurn,
    });
    assert.equal(tatwoTranscriptText(result.stdout), testCase.outputText);
    assert.doesNotMatch(result.stdout, /"type":"response\.failed"/);
    assert.match(result.stdout, /"computer_host_authority":/);
    assert.match(result.stdout, /"verified":true/);
  }
}

async function testCurrentTurnAuthorityArgumentsAreMandatoryAndBounded() {
  const missing = await runAdapter(null, {
    omitAuthorityArgs: true,
  });
  assert.equal(missing.code, 2);
  assert.equal(missing.requestCount, 0);
  assert.match(missing.stdout, /run_id_missing_or_invalid/);

  const invalidHash = await runAdapter(null, {
    currentTurnSHA256Override: "not-a-sha256",
  });
  assert.equal(invalidHash.code, 2);
  assert.equal(invalidHash.requestCount, 0);
  assert.match(invalidHash.stdout, /current_turn_sha256_missing_or_invalid/);

  const duplicateRunID = await runAdapter(null, {
    extraAuthorityArgs: ["--run-id", "second-run"],
  });
  assert.equal(duplicateRunID.code, 2);
  assert.equal(duplicateRunID.requestCount, 0);
  assert.match(duplicateRunID.stdout, /duplicate_run_id_argument/);
}

async function testAppliedRouteReceiptBindingFailsClosedAndCannotReplay() {
  const baseResponse = {
    id: "resp_route_receipt",
    status: "completed",
    model: "grok-build",
    output_text: "ROUTE_RECEIPT_OK",
  };

  const missing = await runAdapter(baseResponse, {
    omitAppliedRouteReceipt: true,
  });
  assert.equal(missing.code, 2);
  assert.match(missing.stdout, /gateway_applied_route_receipt_missing/);
  assert.doesNotMatch(missing.stdout, /"type":"turn\.completed"/);

  for (const [field, replacement, expectedError] of [
    ["run_id", "other-run", "run_id_mismatch"],
    ["turn_id", "other-turn", "turn_id_mismatch"],
    ["current_visible_turn_sha256", "f".repeat(64), "current_visible_turn_sha256_mismatch"],
    ["authority_nonce", "00000000-0000-0000-0000-000000000000", "authority_nonce_mismatch"],
    ["applied_computer_host_route", "request_scoped_tool", "route_mismatch"],
    ["response_id", "resp_other", "response_id_mismatch"],
    ["terminal_status", "cancelled", "terminal_status_mismatch"],
  ]) {
    const result = await runAdapter(baseResponse, {
      appliedRouteReceiptMutator: receipt => ({
        ...receipt,
        [field]: replacement,
      }),
    });
    assert.equal(result.code, 2, field);
    assert.match(
      result.stdout,
      new RegExp(`gateway_applied_route_receipt_${expectedError}`),
      field,
    );
    assert.doesNotMatch(result.stdout, /"type":"turn\.completed"/, field);
  }

  const noneInvokedTool = await runAdapter(baseResponse, {
    toolHostInvocationCount: 1,
  });
  assert.equal(noneInvokedTool.code, 2);
  assert.match(
    noneInvokedTool.stdout,
    /gateway_applied_route_receipt_none_route_invoked_tool_host/,
  );

  let completedReceipt = null;
  const completed = await runAdapter(baseResponse, {
    runID: "stable-run",
    turnID: "stable-turn",
    currentVisibleTurn: "text only",
    appliedRouteReceiptMutator: receipt => {
      completedReceipt = { ...receipt };
      return receipt;
    },
  });
  assert.equal(completed.code, 0, completed.stderr);
  assert.ok(completedReceipt);

  const sameTurnNewAttempt = await runAdapter(baseResponse, {
    runID: "stable-run",
    turnID: "stable-turn",
    currentVisibleTurn: "text only",
    appliedRouteReceiptMutator: () => ({ ...completedReceipt }),
  });
  assert.equal(sameTurnNewAttempt.code, 2);
  assert.match(
    sameTurnNewAttempt.stdout,
    /gateway_applied_route_receipt_authority_nonce_mismatch/,
  );

  const nextTurn = await runAdapter(baseResponse, {
    runID: "stable-run",
    turnID: "next-turn",
    currentVisibleTurn: "text only",
    appliedRouteReceiptMutator: () => ({ ...completedReceipt }),
  });
  assert.equal(nextTurn.code, 2);
  assert.match(
    nextTurn.stdout,
    /gateway_applied_route_receipt_turn_id_mismatch/,
  );
}

async function testFreshContinuationReturnsVerifiedGatewayReceipt() {
  const continuationRequest = makeContinuationRequest({
    mode: "none",
    contextSHA256: sha256("fresh continuation context"),
  });
  const result = await runAdapter(
    {
      id: "resp_fresh_continuation_001",
      model: "grok-build",
      status: "completed",
      output_text: "fresh continuation ok",
    },
    {
      continuationRequest,
      continuationResponseHandle: "resp_handle_fresh_001",
      continuationGatewayInstanceID: "gateway-instance-a",
    },
  );

  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(
    result.requestBody?.metadata?.tatwo?.continuation,
    {
      ...continuationRequest,
      authority_nonce:
        result.requestBody?.metadata?.tatwo?.current_turn?.authority_nonce,
    },
  );
  assert.equal(result.requestBody?.previous_response_id, undefined);
  const completed = parseJSONL(result.stdout)
    .find(event => event.type === "turn.completed");
  assert.ok(completed, result.stdout);
  assert.deepEqual(completed.gateway_continuation, {
    schema: "TatwoGatewayContinuationReceiptV1",
    requested_mode: "none",
    applied_mode: "none",
    thread_id: continuationRequest.thread_id,
    discussion_id: continuationRequest.discussion_id,
    runtime_adapter_id: "gateway-direct",
    canonical_model_id: "grok-build",
    previous_response_handle: null,
    response_handle: "resp_handle_fresh_001",
    context_sha256: continuationRequest.context_sha256,
    gateway_instance_id: "gateway-instance-a",
    continuation_source: "provider_session_started",
    provider_session_reused: false,
    fallback_count: 0,
    model_attestation_outcome: "VERIFIED_EXACT",
    terminal_status: "completed",
  });
  assert.doesNotMatch(result.stdout, /"type":"response\.failed"/);
}

async function testProviderResumeAdvancesVerifiedGatewayReceipt() {
  const freshRequest = makeContinuationRequest({
    mode: "none",
    contextSHA256: sha256("provider resume fresh context"),
  });
  const fresh = await runAdapter(
    {
      id: "resp_provider_resume_seed_001",
      model: "grok-build",
      status: "completed",
      output_text: "seed response",
    },
    {
      continuationRequest: freshRequest,
      continuationResponseHandle: "resp_handle_seed_001",
      continuationGatewayInstanceID: "gateway-instance-resume",
    },
  );
  assert.equal(fresh.code, 0, fresh.stderr);
  const freshReceipt = parseJSONL(fresh.stdout)
    .find(event => event.type === "turn.completed")
    ?.gateway_continuation;
  assert.ok(freshReceipt, fresh.stdout);

  const resumeRequest = makeContinuationRequest({
    mode: "provider_resume",
    contextSHA256: sha256("provider resume next context"),
    previousResponseHandle: freshReceipt.response_handle,
    previousGatewayInstanceID: freshReceipt.gateway_instance_id,
  });
  const resumed = await runAdapter(
    {
      id: "resp_provider_resume_next_002",
      model: "grok-build",
      status: "completed",
      output_text: "resumed response",
    },
    {
      continuationRequest: resumeRequest,
      continuationResponseHandle: "resp_handle_resumed_002",
      continuationGatewayInstanceID: freshReceipt.gateway_instance_id,
    },
  );

  assert.equal(resumed.code, 0, resumed.stderr);
  assert.equal(
    resumed.requestBody?.previous_response_id,
    freshReceipt.response_handle,
  );
  const resumedCompleted = parseJSONL(resumed.stdout)
    .find(event => event.type === "turn.completed");
  assert.ok(resumedCompleted, resumed.stdout);
  assert.equal(
    resumedCompleted.gateway_continuation.previous_response_handle,
    freshReceipt.response_handle,
  );
  assert.equal(
    resumedCompleted.gateway_continuation.response_handle,
    "resp_handle_resumed_002",
  );
  assert.notEqual(
    resumedCompleted.gateway_continuation.response_handle,
    freshReceipt.response_handle,
  );
  assert.equal(
    resumedCompleted.gateway_continuation.gateway_instance_id,
    freshReceipt.gateway_instance_id,
  );
  assert.equal(
    resumedCompleted.gateway_continuation.continuation_source,
    "provider_session_resumed",
  );
  assert.equal(
    resumedCompleted.gateway_continuation.provider_session_reused,
    true,
  );
  assert.doesNotMatch(resumed.stdout, /"type":"response\.failed"/);
}

async function testMissingContinuationReceiptFailsClosed() {
  const result = await runAdapter(
    {
      id: "resp_missing_continuation_receipt_001",
      model: "grok-build",
      status: "completed",
      output_text: "successful text without continuation receipt",
    },
    {
      continuationRequest: makeContinuationRequest({
        mode: "none",
        contextSHA256: sha256("missing receipt context"),
      }),
      omitContinuationReceipt: true,
    },
  );

  assert.equal(result.code, 2);
  assert.match(result.stdout, /"type":"response\.failed"/);
  assert.match(result.stdout, /gateway_continuation_receipt_missing/);
  assert.doesNotMatch(result.stdout, /"type":"turn\.completed"/);
}

async function testContinuationRouteMismatchFailsClosed() {
  const crossModel = await runAdapter(
    {
      id: "resp_cross_model_continuation_001",
      model: "grok-build",
      status: "completed",
      output_text: "cross model receipt",
    },
    {
      continuationRequest: makeContinuationRequest({
        mode: "none",
        contextSHA256: sha256("cross model context"),
      }),
      continuationReceiptMutator: receipt => ({
        ...receipt,
        canonical_model_id: "fable-5",
      }),
    },
  );
  assert.equal(crossModel.code, 2);
  assert.match(
    crossModel.stdout,
    /gateway_continuation_receipt_canonical_model_id_mismatch/,
  );
  assert.doesNotMatch(crossModel.stdout, /"type":"turn\.completed"/);

  const gatewayMismatch = await runAdapter(
    {
      id: "resp_gateway_mismatch_continuation_001",
      model: "grok-build",
      status: "completed",
      output_text: "gateway mismatch receipt",
    },
    {
      continuationRequest: makeContinuationRequest({
        mode: "provider_resume",
        contextSHA256: sha256("gateway mismatch context"),
        previousResponseHandle: "resp_handle_previous_001",
        previousGatewayInstanceID: "gateway-instance-expected",
      }),
      continuationResponseHandle: "resp_handle_gateway_mismatch_002",
      continuationGatewayInstanceID: "gateway-instance-other",
    },
  );
  assert.equal(gatewayMismatch.code, 2);
  assert.match(
    gatewayMismatch.stdout,
    /gateway_continuation_receipt_gateway_instance_id_mismatch/,
  );
  assert.doesNotMatch(gatewayMismatch.stdout, /"type":"turn\.completed"/);
}

async function testLargePromptFileTransportAvoidsArgvE2BIGAndPreservesExactBytes() {
  const unit = "FABLE_LONG_PROMPT_長內容_0123456789abcdef\n";
  const prompt = unit.repeat(Math.ceil((2 * 1024 * 1024) / Buffer.byteLength(unit)));
  const promptData = Buffer.from(prompt, "utf8");
  assert.ok(
    promptData.length > 2 * 1024 * 1024,
    "fixture must exceed the macOS-safe single-argv payload range");
  const expectedSHA256 = sha256(promptData);
  const result = await runAdapter(
    {
      id: "resp_large_prompt_file",
      status: "completed",
      model: "claude-fable-5",
      output_text: "LARGE_PROMPT_OK",
    },
    {
      model: "fable-5",
      prompt,
      promptTransport: "file",
    });

  assert.equal(result.code, 0, result.stderr);
  assert.equal(result.requestBody.input, prompt);
  assert.equal(
    sha256(Buffer.from(result.requestBody.input, "utf8")),
    expectedSHA256);
  assert.equal(Buffer.byteLength(result.requestBody.input), promptData.length);
  assert.equal(result.spawnArgs.includes("--prompt"), false);
  assert.equal(result.spawnArgs.includes(prompt), false);
  assert.equal(
    result.spawnArgs.some(argument => argument.includes("FABLE_LONG_PROMPT_長內容")),
    false);
  assert.ok(
    Buffer.byteLength(result.spawnArgs.join("\0"), "utf8") < 16 * 1024,
    "spawn argv must stay bounded independently of prompt size");
  const receipt = parseJSONL(result.stdout).find(
    event => event.control_type === "prompt.transport");
  assert.deepEqual(receipt, {
    type: "system",
    control_type: "prompt.transport",
    transport: "secure_prompt_file",
    prompt_sha256: expectedSHA256,
    prompt_utf8_bytes: promptData.length,
    argv_prompt_content: false,
    environment_prompt_content: false,
    verified: true,
  });
  assert.equal(result.promptFileExistsAfterExit, false);
  assert.doesNotMatch(result.stderr, /E2BIG|argument list too long/i);
}

async function testPromptFileTransportRejectsUnsafeFilesystemInputs() {
  const symlinkTarget = Buffer.from("SYMLINK_TARGET_MUST_SURVIVE", "utf8");
  const symlinkResult = await runAdapter(null, {
    model: "fable-5",
    promptTransport: "file",
    promptData: symlinkTarget,
    promptFixtureKind: "symlink",
  });
  assertPromptTransportFailure(symlinkResult, "prompt_file_symlink_rejected");
  assert.equal(symlinkResult.promptPathSnapshotAfterExit?.type, "symlink");
  assert.deepEqual(
    symlinkResult.promptPathSnapshotAfterExit?.data,
    symlinkTarget);

  const directoryResult = await runAdapter(null, {
    model: "fable-5",
    promptTransport: "file",
    promptData: Buffer.from("DIRECTORY_METADATA_ONLY", "utf8"),
    promptFixtureKind: "directory",
  });
  assertPromptTransportFailure(directoryResult, "prompt_file_not_regular");
  assert.equal(directoryResult.promptPathSnapshotAfterExit?.type, "directory");

  const rootOwnedPath = "/etc/hosts";
  const rootOwnedStat = await fs.stat(rootOwnedPath);
  if (
    typeof process.geteuid === "function"
    && rootOwnedStat.uid !== process.geteuid()
  ) {
    const rootOwnedData = await fs.readFile(rootOwnedPath);
    const ownerResult = await runAdapter(null, {
      model: "fable-5",
      promptTransport: "file",
      promptFilePath: rootOwnedPath,
      promptData: rootOwnedData,
      deletePromptFile: false,
    });
    assertPromptTransportFailure(ownerResult, "prompt_file_owner_mismatch");
    assert.equal(ownerResult.promptPathSnapshotAfterExit?.type, "file");
  }

  const wrongModeResult = await runAdapter(null, {
    model: "fable-5",
    promptTransport: "file",
    prompt: "WRONG_MODE",
    promptFileMode: 0o644,
  });
  assertPromptTransportFailure(
    wrongModeResult,
    "prompt_file_permissions_must_be_0600");
  assert.equal(wrongModeResult.promptFileExistsAfterExit, false);
}

async function testPromptFileTransportRejectsIntegrityAndEncodingMismatches() {
  const byteMismatchResult = await runAdapter(null, {
    model: "fable-5",
    promptTransport: "file",
    prompt: "BYTE_MISMATCH",
    promptBytesOverride: Buffer.byteLength("BYTE_MISMATCH") + 1,
  });
  assertPromptTransportFailure(
    byteMismatchResult,
    "prompt_file_byte_count_mismatch");
  assert.equal(byteMismatchResult.promptFileExistsAfterExit, false);

  const hashMismatchResult = await runAdapter(null, {
    model: "fable-5",
    promptTransport: "file",
    prompt: "HASH_MISMATCH",
    promptSHA256Override: "0".repeat(64),
  });
  assertPromptTransportFailure(
    hashMismatchResult,
    "prompt_file_sha256_mismatch");
  assert.equal(hashMismatchResult.promptFileExistsAfterExit, false);

  const invalidUTF8 = Buffer.from([0xc3, 0x28]);
  const invalidUTF8Result = await runAdapter(null, {
    model: "fable-5",
    promptTransport: "file",
    promptData: invalidUTF8,
  });
  assertPromptTransportFailure(
    invalidUTF8Result,
    "prompt_file_invalid_utf8");
  assert.equal(invalidUTF8Result.promptFileExistsAfterExit, false);
}

async function testPromptFileTransportRejectsDuplicateMixedAndOversizeInputs() {
  const duplicateInlineResult = await runAdapter(null, {
    model: "fable-5",
    extraArgs: ["--prompt", "duplicate"],
  });
  assertPromptTransportFailure(
    duplicateInlineResult,
    "duplicate_prompt_argument");

  const mixedResult = await runAdapter(null, {
    model: "fable-5",
    promptTransport: "file",
    prompt: "FILE_PROMPT",
    extraArgs: ["--prompt", "INLINE_PROMPT"],
  });
  assertPromptTransportFailure(
    mixedResult,
    "multiple_prompt_transports_not_allowed");
  assert.equal(
    mixedResult.promptFileExistsAfterExit,
    true,
    "mixed-source rejection happens before opening or deleting the path");

  const duplicateFileResult = await runAdapter(null, {
    model: "fable-5",
    promptTransport: "file",
    prompt: "DUPLICATE_FILE_ARG",
    duplicatePromptFileArgument: true,
  });
  assertPromptTransportFailure(
    duplicateFileResult,
    "duplicate_prompt_file_argument");
  assert.equal(
    duplicateFileResult.promptFileExistsAfterExit,
    true,
    "duplicate metadata rejection must not touch an untrusted path");

  const oversizeData = Buffer.alloc((8 * 1024 * 1024) + 1, 0x61);
  const oversizeResult = await runAdapter(null, {
    model: "fable-5",
    promptTransport: "file",
    promptData: oversizeData,
  });
  assertPromptTransportFailure(
    oversizeResult,
    "prompt_file_bytes_exceed_limit");
  assert.equal(
    oversizeResult.promptFileExistsAfterExit,
    true,
    "oversize metadata is rejected before opening the path");
}

async function testPromptFileReplacementAfterSecureUnlinkSurvives() {
  const replacement = Buffer.from("REPLACEMENT_INODE_MUST_SURVIVE", "utf8");
  const result = await runAdapter(
    {
      id: "resp_prompt_replacement",
      status: "completed",
      model: "claude-fable-5",
      output_text: "REPLACEMENT_RACE_OK",
    },
    {
      model: "fable-5",
      promptTransport: "file",
      prompt: "ORIGINAL_PROMPT",
      onRequestBody: async ({ promptFile }) => {
        assert.equal(
          await fileExists(promptFile),
          false,
          "original pathname must already be unlinked before gateway I/O");
        await fs.writeFile(promptFile, replacement, { mode: 0o600, flag: "wx" });
      },
    });

  assert.equal(result.code, 0, result.stderr);
  assert.equal(result.requestBody.input, "ORIGINAL_PROMPT");
  assert.equal(result.promptPathSnapshotAfterExit?.type, "file");
  assert.deepEqual(result.promptPathSnapshotAfterExit?.data, replacement);
}

async function testPromptFileCleanupAlsoHoldsWhenGatewayFails() {
  const result = await runAdapter(
    {
      id: "resp_gateway_failed_after_prompt_read",
      status: "failed",
      model: "claude-fable-5",
      error: { message: "fixture gateway failure" },
    },
    {
      model: "fable-5",
      promptTransport: "file",
      prompt: "DELETE_BEFORE_GATEWAY_FAILURE",
    });

  assert.equal(result.code, 2);
  assert.match(result.stdout, /fixture gateway failure/);
  assert.equal(result.promptFileExistsAfterExit, false);
}

function assertPromptTransportFailure(result, expectedMessage) {
  assert.equal(result.code, 2, result.stderr);
  assert.equal(result.requestBody, null);
  assert.match(result.stdout, new RegExp(expectedMessage));
  assert.doesNotMatch(result.stdout, /"type":"turn\.completed"/);
}

async function testSSEProgressArrivesBeforeTerminalCompletion() {
  let releaseTerminal;
  const terminalGate = new Promise(resolve => { releaseTerminal = resolve; });
  let progressObservedBeforeTerminal = false;
  let terminalReleased = false;
  const resultPromise = runAdapter(null, {
    streamingResponse: async response => {
      writeSSE(response, {
        type: "response.created",
        response: {
          id: "resp_sse_progress",
          status: "in_progress",
          model: "grok-build",
        },
      });
      response.write(": heartbeat\n\n");
      writeSSE(response, {
        type: "response.in_progress",
        response: {
          id: "resp_sse_progress",
          status: "in_progress",
          model: "grok-build",
        },
      });
      await terminalGate;
      terminalReleased = true;
      writeSSE(response, {
        type: "response.output_text.delta",
        response_id: "resp_sse_progress",
        delta: "SSE_",
      });
      writeSSE(response, {
        type: "response.output_text.delta",
        response_id: "resp_sse_progress",
        delta: "OK",
      });
      writeSSE(response, {
        type: "response.output_item.done",
        response_id: "resp_sse_progress",
        item: {
          id: "item_sse_progress",
          type: "message",
          content: [{ type: "output_text", text: "SSE_OK" }],
        },
      });
      writeSSE(response, {
        type: "response.completed",
        response: {
          id: "resp_sse_progress",
          status: "completed",
        },
      });
      response.end("data: [DONE]\n\n");
    },
    onStdout: stdout => {
      if (!terminalReleased && /"control_type":"response\.in_progress"/.test(stdout)) {
        progressObservedBeforeTerminal = true;
        releaseTerminal();
      }
    },
  });
  // Under the repository-wide Node gate this child competes with many other
  // fixture subprocesses. A 2-second wall-clock fallback can release the
  // terminal before the parent receives stdout even though the adapter did
  // stream `response.in_progress` first. Keep the deadlock escape, but give
  // the cross-process progress assertion a scheduler-safe window.
  const releaseFallback = setTimeout(() => releaseTerminal(), 10_000);
  const result = await resultPromise;
  clearTimeout(releaseFallback);

  assert.equal(result.code, 0, result.stderr);
  assert.equal(progressObservedBeforeTerminal, true);
  assert.equal(result.requestBody.stream, true);
  assert.match(result.stdout, /"type":"system","control_type":"response\.created"/);
  assert.match(result.stdout, /"type":"system","control_type":"response\.in_progress"/);
  assert.match(result.stdout, /"heartbeat":true/);
  assert.match(result.stdout, /"type":"response\.output_text\.delta","dispatch_id":"dispatch-test","response_id":"resp_sse_progress","delta":"SSE_"/);
  assert.match(result.stdout, /"type":"system","control_type":"response\.output_item\.done"/);
  assert.match(result.stdout, /"type":"system","control_type":"response\.completed"/);
  assert.doesNotMatch(result.stdout, /"type":"item\.completed"/);
  assert.match(result.stdout, /"type":"turn\.completed"/);
  assert.match(result.stdout, /"outcome":"VERIFIED_EXACT"/);
  assert.match(result.stdout, /"output_delivery":\{"mode":"delta"/);
  assert.match(result.stdout, /"delta_matches_final":true/);
  assert.equal(tatwoTranscriptText(result.stdout), "SSE_OK");
  assert.equal(occurrences(tatwoTranscriptText(result.stdout), "SSE_OK"), 1);
  const outputItemControl = parseJSONL(result.stdout).find(
    event => event.control_type === "response.output_item.done",
  );
  assert.ok(outputItemControl);
  assert.equal(bestTextEquivalent(outputItemControl), null);
  assert.equal(outputItemControl.item_id, "item_sse_progress");
  assert.equal(outputItemControl.item_type, "message");
}

async function testSSEHeartbeatsExtendInactivityTimeout() {
  const startedAt = Date.now();
  const result = await runAdapter(null, {
    // Keep this comfortably above one loaded Node test-runner scheduling
    // slice. The contract is heartbeat renewal, not an 80 ms wall-clock SLA;
    // the separate silent-gap case remains the narrow timeout test.
    timeoutMs: 1_000,
    streamingResponse: async response => {
      writeSSE(response, {
        type: "response.created",
        response: {
          id: "resp_sse_heartbeat_extension",
          status: "in_progress",
          model: "grok-build",
        },
      });
      for (let index = 0; index < 5; index += 1) {
        await delay(300);
        response.write(": heartbeat\n\n");
      }
      writeSSE(response, {
        type: "response.output_text.delta",
        response_id: "resp_sse_heartbeat_extension",
        delta: "HEARTBEAT_EXTENDED_OK",
      });
      writeSSE(response, {
        type: "response.completed",
        response: {
          id: "resp_sse_heartbeat_extension",
          status: "completed",
          model: "grok-build",
        },
      });
      response.end("data: [DONE]\n\n");
    },
  });

  assert.equal(result.code, 0, result.stderr);
  assert.ok(
    Date.now() - startedAt >= 1_300,
    "heartbeats must keep a turn alive beyond one inactivity window");
  assert.match(result.stdout, /"heartbeat":true/);
  assert.equal(tatwoTranscriptText(result.stdout), "HEARTBEAT_EXTENDED_OK");
}

async function testSSETerminalDoesNotWaitForeverForEOF() {
  const startedAt = Date.now();
  const result = await runAdapter(null, {
    timeoutMs: 4_000,
    streamingResponse: async response => {
      writeSSE(response, {
        type: "response.output_text.delta",
        response_id: "resp_sse_terminal_without_eof",
        delta: "TERMINAL_WITHOUT_EOF_OK",
      });
      writeSSE(response, {
        type: "response.completed",
        response: {
          id: "resp_sse_terminal_without_eof",
          status: "completed",
          model: "grok-build",
        },
      });
      const heartbeat = setInterval(() => {
        if (!response.destroyed) response.write(": heartbeat\n\n");
      }, 40);
      response.once("close", () => clearInterval(heartbeat));
    },
  });

  assert.equal(result.code, 0, result.stderr);
  assert.ok(
    Date.now() - startedAt < 5_000,
    "formal terminal must complete even when the peer keeps SSE open");
  assert.equal(tatwoTranscriptText(result.stdout), "TERMINAL_WITHOUT_EOF_OK");
}

async function testSSEDuplicateTerminalDuringGraceFailsClosed() {
  const result = await runAdapter(null, {
    timeoutMs: 4_000,
    streamingResponse: async response => {
      writeSSE(response, {
        type: "response.completed",
        response: {
          id: "resp_sse_duplicate_terminal",
          status: "completed",
          model: "grok-build",
          output_text: "FIRST",
        },
      });
      await delay(40);
      if (!response.destroyed) {
        writeSSE(response, {
          type: "response.completed",
          response: {
            id: "resp_sse_duplicate_terminal",
            status: "completed",
            model: "grok-build",
            output_text: "SECOND",
          },
        });
      }
    },
  });

  assert.equal(result.code, 2);
  assert.match(result.stdout, /gateway_stream_duplicate_terminal_event/);
  assert.doesNotMatch(result.stdout, /"type":"turn\.completed"/);
}

async function testSSESilentGapFailsAtInactivityTimeout() {
  const result = await runAdapter(null, {
    timeoutMs: 750,
    streamingResponse: async response => {
      writeSSE(response, {
        type: "response.created",
        response: {
          id: "resp_sse_silent_timeout",
          status: "in_progress",
          model: "grok-build",
        },
      });
      // The peer stays silent far longer than the configured inactivity
      // window. Leave enough separation that a loaded repository-wide test
      // runner can delay timers without turning this into a race against the
      // fixture's own response.end().
      await delay(8_000);
      if (!response.destroyed) response.end();
    },
  });

  assert.equal(result.code, 2);
  assert.ok(result.childElapsedMs < 6_000, "silent stream must remain bounded");
  assert.match(result.stdout, /gateway_direct_timeout/);
  assert.doesNotMatch(result.stdout, /"type":"turn\.completed"/);
}

async function testSSEWithoutDeltasFallsBackExactlyOnce() {
  const result = await runAdapter(null, {
    streamingResponse: async response => {
      writeSSE(response, {
        type: "response.created",
        response: {
          id: "resp_sse_terminal_fallback",
          status: "in_progress",
          model: "grok-build",
        },
      });
      writeSSE(response, {
        type: "response.output_item.done",
        response_id: "resp_sse_terminal_fallback",
        item: {
          id: "item_sse_terminal_fallback",
          type: "message",
          content: [{ type: "output_text", text: "TERMINAL_ONLY" }],
        },
      });
      writeSSE(response, {
        type: "response.completed",
        response: {
          id: "resp_sse_terminal_fallback",
          status: "completed",
        },
      });
      response.end("data: [DONE]\n\n");
    },
  });
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /"type":"system","control_type":"response\.output_item\.done"/);
  assert.match(result.stdout, /"type":"item\.completed"/);
  assert.match(result.stdout, /"output_delivery":\{"mode":"terminal_fallback"/);
  assert.equal(tatwoTranscriptText(result.stdout), "TERMINAL_ONLY");
  assert.equal(occurrences(tatwoTranscriptText(result.stdout), "TERMINAL_ONLY"), 1);
}

async function testSSEDisconnectFailsClosedWithoutTerminalCompletion() {
  const startedAt = Date.now();
  const result = await runAdapter(null, {
    streamingResponse: async response => {
      writeSSE(response, {
        type: "response.created",
        response: {
          id: "resp_sse_disconnect",
          status: "in_progress",
          model: "grok-build",
        },
      });
      writeSSE(response, {
        type: "response.output_text.delta",
        response_id: "resp_sse_disconnect",
        delta: "PARTIAL_MUST_NOT_COMPLETE",
      });
      setImmediate(() => response.destroy());
    },
  });
  assert.equal(result.code, 2);
  assert.ok(Date.now() - startedAt < 4_000, "disconnect should abort before adapter timeout");
  assert.match(result.stdout, /"type":"system","control_type":"response\.created"/);
  assert.match(result.stdout, /"type":"response\.output_text\.delta"/);
  assert.match(result.stdout, /"type":"response\.failed"/);
  assert.match(result.stdout, /gateway_stream_disconnected/);
  assert.doesNotMatch(result.stdout, /"type":"item\.completed"/);
  assert.doesNotMatch(result.stdout, /"type":"turn\.completed"/);
}

async function testSSEDeltaTerminalMismatchFailsClosed() {
  const result = await runAdapter(null, {
    streamingResponse: async response => {
      writeSSE(response, {
        type: "response.created",
        response: {
          id: "resp_sse_output_mismatch",
          status: "in_progress",
          model: "grok-build",
        },
      });
      writeSSE(response, {
        type: "response.output_text.delta",
        response_id: "resp_sse_output_mismatch",
        delta: "STREAMED_TEXT",
      });
      writeSSE(response, {
        type: "response.completed",
        response: {
          id: "resp_sse_output_mismatch",
          status: "completed",
          model: "grok-build",
          output_text: "DIFFERENT_TERMINAL_TEXT",
        },
      });
      response.end("data: [DONE]\n\n");
    },
  });

  assert.equal(result.code, 2);
  assert.match(result.stdout, /"type":"response\.output_text\.delta"/);
  assert.match(result.stdout, /gateway_stream_output_mismatch/);
  assert.doesNotMatch(result.stdout, /"type":"item\.completed"/);
  assert.doesNotMatch(result.stdout, /"type":"turn\.completed"/);
}

async function testSSEAttestationMismatchFailsClosed() {
  const result = await runAdapter(null, {
    model: "fable-5",
    streamingResponse: async response => {
      writeSSE(response, {
        type: "response.created",
        response: {
          id: "resp_sse_fallback",
          status: "in_progress",
          model: "claude-opus-5",
        },
      });
      writeSSE(response, {
        type: "response.output_text.delta",
        response_id: "resp_sse_fallback",
        delta: "MUST_NOT_COUNT_AS_FABLE",
      });
      writeSSE(response, {
        type: "response.completed",
        response: {
          id: "resp_sse_fallback",
          status: "completed",
          model: "claude-opus-5",
          modelUsage: {
            "claude-fable-5": {},
            "claude-opus-5[1m]": {},
          },
          output_text: "MUST_NOT_COUNT_AS_FABLE",
        },
      });
      response.end("data: [DONE]\n\n");
    },
  });
  assert.equal(result.code, 2);
  assert.match(result.stdout, /"type":"system","control_type":"response\.completed"/);
  assert.match(result.stdout, /gateway_model_attestation_fail_closed_mismatch/);
  assert.doesNotMatch(result.stdout, /"type":"item\.completed"/);
  assert.doesNotMatch(result.stdout, /"type":"turn\.completed"/);
}

function assertVisibleDegradedNotice(result, errorKind) {
  assert.equal(result.code, 0);
  assert.match(result.stdout, /"type":"item\.completed"/);
  assert.match(result.stdout, /"type":"turn\.completed"/);
  assert.match(result.stdout, /"degraded":true/);
  assert.match(result.stdout, new RegExp(`"error_kind":"${errorKind}"`));
  assert.doesNotMatch(result.stdout, /"type":"response\.failed"/);
}

async function runAdapter(responseBody, options = {}) {
  let requestBody = null;
  let requestCount = 0;
  let promptFixture = null;
  let continuationFixture = null;
  const prompt = options.prompt ?? "test";
  const currentVisibleTurn = options.currentVisibleTurn ?? prompt;
  const authorityArgs = options.omitAuthorityArgs
    ? []
    : [
        "--run-id", options.runID ?? "unit-run",
        "--turn-id", options.turnID ?? "unit-turn",
        "--current-turn-sha256",
        options.currentTurnSHA256Override ?? sha256(currentVisibleTurn),
        "--current-turn-bytes",
        String(
          options.currentTurnBytesOverride
            ?? Buffer.byteLength(currentVisibleTurn, "utf8"),
        ),
      ];
  const effectiveResponseBody =
    options.disableDefaultGrokAttestation
      ? responseBody
      : withExactGrokAttestation(responseBody);
  const server = http.createServer((request, response) => {
    const chunks = [];
    request.on("data", chunk => chunks.push(chunk));
    request.on("end", async () => {
      try {
        requestCount += 1;
        requestBody = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        response.tatwoRequestBody = requestBody;
        response.tatwoRouteReceiptOptions = options;
        await options.onRequestBody?.({
          requestBody,
          promptFile: promptFixture?.promptFile ?? null,
        });
        if (options.streamingResponse) {
          response.writeHead(200, {
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
          });
          Promise.resolve(options.streamingResponse(response)).catch(error => {
            response.destroy(error);
          });
          return;
        }
        response.writeHead(200, { "Content-Type": "application/json" });
        response.end(JSON.stringify(
          withGatewayContinuationReceipt(
            withAppliedRouteReceipt(
              effectiveResponseBody,
              requestBody,
              options,
            ),
            requestBody,
            options,
          ),
        ));
      } catch (error) {
        response.destroy(error);
      }
    });
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  try {
    const promptArgs = [];
    if (options.promptTransport === "file") {
      const promptData = options.promptData ?? Buffer.from(prompt, "utf8");
      const promptSHA256 =
        options.promptSHA256Override
        ?? sha256(promptData);
      const promptBytes =
        options.promptBytesOverride
        ?? promptData.length;
      let fixtureRoot = null;
      let promptFile = options.promptFilePath ?? null;
      if (!promptFile) {
        fixtureRoot = await fs.mkdtemp(
          path.join(os.tmpdir(), "tatwo-direct-prompt-"));
        promptFile = path.join(fixtureRoot, "prompt.txt");
        if (options.promptFixtureKind === "directory") {
          await fs.mkdir(promptFile, { mode: 0o700 });
        } else if (options.promptFixtureKind === "symlink") {
          const targetFile = path.join(fixtureRoot, "target.txt");
          await fs.writeFile(targetFile, promptData, { mode: 0o600, flag: "wx" });
          await fs.symlink(targetFile, promptFile);
        } else {
          await fs.writeFile(promptFile, promptData, {
            mode: options.promptFileMode ?? 0o600,
            flag: "wx",
          });
        }
      }
      promptFixture = { fixtureRoot, promptFile };
      promptArgs.push(
        "--prompt-file", promptFile,
        "--prompt-sha256", promptSHA256,
        "--prompt-bytes", String(promptBytes));
      if (options.deletePromptFile !== false) {
        promptArgs.push("--delete-prompt-file");
      }
      if (options.duplicatePromptFileArgument) {
        promptArgs.push("--prompt-file", promptFile);
      }
    } else {
      promptArgs.push("--prompt", prompt);
    }
    const continuationArgs = [];
    if (options.continuationRequest) {
      const continuationData = Buffer.from(
        JSON.stringify(options.continuationRequest),
        "utf8",
      );
      const fixtureRoot = await fs.mkdtemp(
        path.join(os.tmpdir(), "tatwo-direct-continuation-"),
      );
      const continuationFile = path.join(fixtureRoot, "continuation.json");
      await fs.writeFile(continuationFile, continuationData, {
        mode: 0o600,
        flag: "wx",
      });
      continuationFixture = { fixtureRoot, continuationFile };
      continuationArgs.push(
        "--continuation-file", continuationFile,
        "--continuation-sha256", sha256(continuationData),
        "--continuation-bytes", String(continuationData.length),
        "--delete-continuation-file",
      );
    }
    return await new Promise((resolve, reject) => {
      const childStartedAt = Date.now();
      const spawnArgs = [
        adapter,
        "--model", options.model ?? "grok-build",
        "--dispatch-id", "dispatch-test",
        ...authorityArgs,
        ...(options.extraAuthorityArgs ?? []),
        ...promptArgs,
        ...continuationArgs,
        ...(options.extraArgs ?? []),
        "--endpoint", `http://127.0.0.1:${address.port}/v1/responses`,
        "--timeout-ms", String(options.timeoutMs ?? 5000),
      ];
      const child = spawn(process.execPath, spawnArgs, { cwd: repoRoot });
      let stdout = "";
      let stderr = "";
      child.stdout.on("data", chunk => {
        stdout += chunk;
        options.onStdout?.(stdout);
      });
      child.stderr.on("data", chunk => { stderr += chunk; });
      child.on("error", reject);
      child.on("close", async code => {
        const promptPathSnapshotAfterExit = promptFixture
          ? await snapshotPath(promptFixture.promptFile)
          : null;
        resolve({
          code,
          stdout,
          stderr,
          requestBody,
          requestCount,
          childElapsedMs: Date.now() - childStartedAt,
          spawnArgs,
          promptFileExistsAfterExit: promptPathSnapshotAfterExit !== null,
          promptPathSnapshotAfterExit,
        });
      });
    });
  } finally {
    await new Promise(resolve => server.close(resolve));
    if (promptFixture?.fixtureRoot) {
      await fs.rm(promptFixture.fixtureRoot, { recursive: true, force: true });
    }
    if (continuationFixture?.fixtureRoot) {
      await fs.rm(
        continuationFixture.fixtureRoot,
        { recursive: true, force: true },
      );
    }
  }
}

function writeSSE(response, event) {
  response.write(`data: ${JSON.stringify(
    withAppliedRouteReceiptEvent(
      withExactGrokAttestationEvent(event),
      response.tatwoRequestBody,
      response.tatwoRouteReceiptOptions,
    ),
  )}\n\n`);
}

function assertCurrentTurnAuthorityRequest(
  result,
  {
    expectedWireRoute,
    currentVisibleTurn,
    runID = "unit-run",
    turnID = "unit-turn",
  },
) {
  const tatwo = result.requestBody?.metadata?.tatwo;
  assert.equal(tatwo?.schema, "TatwoGatewayMetadataV2");
  assert.equal(tatwo?.source, "tatwo_ultrawork_chat");
  assert.deepEqual(
    {
      run_id: tatwo?.current_turn?.run_id,
      turn_id: tatwo?.current_turn?.turn_id,
      current_visible_turn_sha256:
        tatwo?.current_turn?.current_visible_turn_sha256,
      current_visible_turn_utf8_bytes:
        tatwo?.current_turn?.current_visible_turn_utf8_bytes,
      computer_host_route: tatwo?.current_turn?.computer_host_route,
    },
    {
      run_id: runID,
      turn_id: turnID,
      current_visible_turn_sha256: sha256(currentVisibleTurn),
      current_visible_turn_utf8_bytes:
        Buffer.byteLength(currentVisibleTurn, "utf8"),
      computer_host_route: expectedWireRoute,
    },
  );
  assert.match(
    String(tatwo?.current_turn?.authority_nonce ?? ""),
    /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/,
  );
}

function withAppliedRouteReceiptEvent(event, requestBody, options = {}) {
  if (event?.type !== "response.completed" || !event.response) return event;
  return {
    ...event,
    response: withAppliedRouteReceipt(event.response, requestBody, options),
  };
}

function withAppliedRouteReceipt(body, requestBody, options = {}) {
  if (
    options.omitAppliedRouteReceipt
    || !body
    || typeof body !== "object"
    || Array.isArray(body)
  ) {
    return body;
  }
  const currentTurn = requestBody?.metadata?.tatwo?.current_turn ?? {};
  const receipt = {
    schema: "TatwoGatewayAppliedComputerHostRouteReceiptV1",
    source: "codex_app_model_gateway",
    run_id: currentTurn.run_id,
    turn_id: currentTurn.turn_id,
    current_visible_turn_sha256: currentTurn.current_visible_turn_sha256,
    current_visible_turn_utf8_bytes:
      currentTurn.current_visible_turn_utf8_bytes,
    authority_nonce: currentTurn.authority_nonce,
    applied_computer_host_route: currentTurn.computer_host_route,
    tool_host_invocation_count:
      options.toolHostInvocationCount ?? 0,
    response_id: String(body.id ?? body.response_id ?? ""),
    terminal_status: String(body.status ?? ""),
  };
  const mutatedReceipt = options.appliedRouteReceiptMutator
    ? options.appliedRouteReceiptMutator({ ...receipt })
    : receipt;
  return {
    ...body,
    metadata: {
      ...(body.metadata ?? {}),
      tatwo: {
        ...(body.metadata?.tatwo ?? {}),
        applied_route_receipt: mutatedReceipt,
      },
    },
  };
}

function withGatewayContinuationReceipt(body, requestBody, options = {}) {
  const request = requestBody?.metadata?.tatwo?.continuation;
  if (
    !request
    || options.omitContinuationReceipt
    || !body
    || typeof body !== "object"
    || Array.isArray(body)
  ) {
    return body;
  }
  const semantics = {
    none: {
      continuation_source: "provider_session_started",
      provider_session_reused: false,
    },
    context_replay: {
      continuation_source: "gateway_replayed_input",
      provider_session_reused: false,
    },
    provider_resume: {
      continuation_source: "provider_session_resumed",
      provider_session_reused: true,
    },
  }[request.mode];
  const receipt = {
    schema: "TatwoGatewayContinuationReceiptV1",
    requested_mode: request.mode,
    applied_mode: request.mode,
    thread_id: request.thread_id,
    discussion_id: request.discussion_id ?? null,
    runtime_adapter_id: request.runtime_adapter_id,
    canonical_model_id: request.canonical_model_id,
    previous_response_handle: request.previous_response_handle ?? null,
    response_handle:
      options.continuationResponseHandle
      ?? "gateway_response_handle_001",
    context_sha256: request.context_sha256,
    gateway_instance_id:
      options.continuationGatewayInstanceID
      ?? request.previous_gateway_instance_id
      ?? "gateway-instance-unit",
    ...semantics,
    fallback_count: 0,
    model_attestation_outcome: "VERIFIED_EXACT",
    terminal_status: "completed",
  };
  const mutatedReceipt = options.continuationReceiptMutator
    ? options.continuationReceiptMutator({ ...receipt })
    : receipt;
  return {
    ...body,
    metadata: {
      ...(body.metadata ?? {}),
      tatwo: {
        ...(body.metadata?.tatwo ?? {}),
        continuation_receipt: mutatedReceipt,
      },
    },
  };
}

function makeContinuationRequest({
  mode,
  contextSHA256,
  previousResponseHandle = null,
  previousGatewayInstanceID = null,
}) {
  return {
    schema: "TatwoGatewayContinuationV1",
    mode,
    thread_id: "thread-continuation-unit",
    discussion_id: "discussion-continuation-unit",
    runtime_adapter_id: "gateway-direct",
    canonical_model_id: "grok-build",
    previous_response_handle: previousResponseHandle,
    previous_gateway_instance_id: previousGatewayInstanceID,
    context_sha256: contextSHA256,
  };
}

function withExactGrokAttestationEvent(event) {
  if (
    event?.type !== "response.completed"
    || !event.response
    || (
      event.response.model
      && event.response.model !== "grok-build"
    )
    || event.response.model_attestation
    || event.response.actual_model
  ) {
    return event;
  }
  return {
    ...event,
    response: withExactGrokAttestation({
      model: "grok-build",
      ...event.response,
    }),
  };
}

function withExactGrokAttestation(
  body,
  {
    turnEndedOutcome = "success",
    actualVendorModel = "grok-4.6",
    summaryModel = actualVendorModel,
    startedModel = actualVendorModel,
  } = {},
) {
  if (
    !body
    || typeof body !== "object"
    || Array.isArray(body)
    || body.model !== "grok-build"
    || body.model_attestation
    || body.actual_model
  ) {
    return body;
  }
  return {
    ...body,
    actual_model: actualVendorModel,
    fallback_count: 0,
    model_attestation: {
      schema: "TatwoGatewayModelAttestationV1",
      evidence_source: "grok_cli_session_state",
      requested_model: "grok-build",
      requested_vendor_model: "grok-4.6",
      actual_canonical_model: "grok-build",
      actual_vendor_model: actualVendorModel,
      assistant_models: [actualVendorModel],
      fallback_models: [],
      fallback_count: 0,
      modelUsage: {},
      auxiliary_model_usage: {},
      session_evidence: {
        source: "grok_cli_session_state",
        synthetic: false,
        session_id_sha256: "a".repeat(64),
        summary_session_id_matches: true,
        request_id_consistent: true,
        summary_current_model_id: summaryModel,
        turn_started_model_id: startedModel,
        turn_ended_outcome: turnEndedOutcome,
        turn_number: 0,
      },
      outcome: "VERIFIED_EXACT",
      exact: true,
    },
  };
}

function delay(milliseconds) {
  return new Promise(resolve => setTimeout(resolve, milliseconds));
}

function tatwoTranscriptText(stdout) {
  const fragments = [];
  for (const event of parseJSONL(stdout)) {
    const rawType = String(event?.type ?? "").toLowerCase();
    const itemType = String(event?.item?.type ?? "").toLowerCase();
    const text = bestTextEquivalent(event);
    if (!text || shouldSuppressEquivalent(rawType, itemType)) continue;
    fragments.push(text);
  }
  return fragments.join("");
}

function bestTextEquivalent(value) {
  return firstTextEquivalent(value, [
    "delta",
    "text",
    "message",
    "output",
    "result",
    "summary",
    "content",
    "last_message",
    "lastMessage",
    "assistant_message",
    "assistantMessage",
  ]);
}

function firstTextEquivalent(value, preferredKeys) {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) {
    const joined = value
      .map(candidate => firstTextEquivalent(candidate, preferredKeys))
      .filter(Boolean)
      .join("");
    return joined || null;
  }
  if (!value || typeof value !== "object") return null;
  for (const key of preferredKeys) {
    if (!(key in value)) continue;
    const text = firstTextEquivalent(value[key], preferredKeys);
    if (text) return text;
  }
  for (const [key, candidate] of Object.entries(value)) {
    if (isControlScalarKeyEquivalent(key)) continue;
    if (candidate && (Array.isArray(candidate) || typeof candidate === "object")) {
      const text = firstTextEquivalent(candidate, preferredKeys);
      if (text) return text;
    }
  }
  return null;
}

function shouldSuppressEquivalent(rawType, itemType) {
  if (["system", "rate_limit_event", "thread.started", "turn.started", "turn.completed"].includes(rawType)) {
    return true;
  }
  return rawType === "item.completed" && itemType === "error";
}

function isControlScalarKeyEquivalent(key) {
  return [
    "type",
    "event",
    "status",
    "id",
    "thread_id",
    "threadId",
    "session_id",
    "sessionId",
    "conversation_id",
    "conversationId",
    "created_at",
    "createdAt",
  ].includes(key);
}

function parseJSONL(value) {
  return String(value)
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)
    .map(line => JSON.parse(line));
}

function occurrences(text, needle) {
  return text.split(needle).length - 1;
}

function sha256(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

async function fileExists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

async function snapshotPath(filePath) {
  try {
    const stat = await fs.lstat(filePath);
    if (stat.isSymbolicLink()) {
      return {
        type: "symlink",
        data: await fs.readFile(filePath),
      };
    }
    if (stat.isDirectory()) {
      return { type: "directory", data: null };
    }
    if (stat.isFile()) {
      return {
        type: "file",
        data: await fs.readFile(filePath),
      };
    }
    return { type: "other", data: null };
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
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
