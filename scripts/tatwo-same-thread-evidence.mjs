#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const args = parseArgs(process.argv.slice(2));
const runRequested = Boolean(args.run);
const confirmed = process.env.TATWO_HOST_SAME_THREAD_SMOKE === "1";
const fixturePath = args.fixture
  ? path.resolve(String(args.fixture))
  : path.join(repoRoot, "tests/fixtures/tatwo-same-thread-expected-fail.json");

let evidence = null;
let execution = null;
let error = null;

if (runRequested) {
  if (!confirmed) {
    error = "run_requires_TATWO_HOST_SAME_THREAD_SMOKE=1";
  } else {
    execution = runLiveEvidence();
    evidence = execution.evidence;
    error = execution.error;
  }
} else {
  evidence = readFixture(fixturePath);
}

const classification = classify(evidence, {
  authoritativePass: Boolean(execution?.verified),
});
const report = {
  schema: "TatwoSameThreadEvidenceV1",
  hostMutationAllowed: false,
  hostMutationPerformed: false,
  liveExecutionRequested: runRequested,
  liveExecutionPerformed: Boolean(execution?.performed),
  authoritativeLiveReceiptVerified: Boolean(execution?.verified),
  fixturePath: runRequested ? null : fixturePath,
  classification,
  evidence: sanitizeEvidence(evidence),
  error,
  blockedBy: [
    ...(runRequested && !confirmed ? ["human_or_env_confirmation_missing"] : []),
    ...(runRequested && !execution?.performed ? ["live_same_thread_not_executed"] : []),
    ...(classification === "unknown" ? ["evidence_insufficient"] : [])
  ],
  plainSummary: summaryFor(classification)
};

console.log(JSON.stringify(report, null, 2));
process.exit(classification === "pass" ? 0 : 2);

function runLiveEvidence() {
  const helper = path.join(scriptDir, "tatwo-app-server-same-thread-smoke.mjs");
  if (!fs.existsSync(helper)) {
    return { performed: false, error: "tatwo_same_thread_helper_not_found" };
  }
  const testNonce = randomUUID();
  const runID = randomUUID();
  let expectedTurnPlan;
  try {
    expectedTurnPlan = expectedTurnPlanFromEnvironment();
  } catch (cause) {
    return {
      performed: false,
      error: cause instanceof Error
        ? cause.message
        : "expected_turn_plan_invalid",
      evidence: invalidLiveReceipt([], "expected_turn_plan_invalid").evidence,
    };
  }
  const expectedRoutes = expectedTurnPlan.routes;
  const result = spawnSync(process.execPath, [helper], {
    cwd: repoRoot,
    env: {
      ...process.env,
      TATWO_SAME_THREAD_EVIDENCE_NONCE: testNonce,
      TATWO_SAME_THREAD_RUN_ID: runID,
      TATWO_SAME_THREAD_EXPECTED_ROUTES: expectedRoutes.join(","),
      // A same-thread PASS is a route-attestation claim, not merely a
      // requested-route claim. Do not permit the helper to emit a receipt
      // without an actual vendor model, exact fallback evidence, response ID,
      // and forwarding evidence for every planned turn.
      TATWO_SAME_THREAD_REQUIRE_FORWARDING_EVIDENCE: "1",
    },
    encoding: "utf8",
    timeout: Number(process.env.TATWO_HOST_SAME_THREAD_TIMEOUT_MS ?? 900000),
    maxBuffer: 10 * 1024 * 1024
  });
  const parsed = parseLiveOutput(
    result.stdout,
    testNonce,
    runID,
    expectedTurnPlan,
  );
  if (result.status !== 0) {
    parsed.evidence.sameThread.status = "fail";
    parsed.evidence.sameThread.failure =
      parsed.evidence.sameThread.failure
      ?? `same-thread helper exited ${result.status ?? "unknown"}`;
    parsed.verified = false;
  }
  return {
    performed: true,
    verified: parsed.verified,
    error: result.status === 0 && parsed.verified
      ? null
      : result.status === 0
        ? "same_thread_receipt_invalid"
        : "same_thread_helper_failed",
    evidence: parsed.evidence,
  };
}

function readFixture(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

function expectedTurnPlanFromEnvironment() {
  const rawJSON = String(
    process.env.TATWO_SAME_THREAD_EXPECTED_TURNS_JSON ?? "",
  ).trim();
  const filePath = String(
    process.env.TATWO_SAME_THREAD_EXPECTED_TURNS_FILE ?? "",
  ).trim();
  if (rawJSON && filePath) {
    throw new Error("expected_turns_source_ambiguous");
  }
  let document = null;
  if (rawJSON) {
    try {
      document = JSON.parse(rawJSON);
    } catch {
      throw new Error("invalid_expected_turns_json");
    }
  } else if (filePath) {
    const resolved = path.resolve(filePath);
    let raw;
    try {
      const stat = fs.statSync(resolved);
      if (!stat.isFile() || stat.size > 20 * 1024 * 1024) {
        throw new Error("expected_turns_file_invalid_or_too_large");
      }
      raw = fs.readFileSync(resolved, "utf8");
      document = JSON.parse(raw);
    } catch (cause) {
      if (cause instanceof Error && cause.message === "expected_turns_file_invalid_or_too_large") {
        throw cause;
      }
      throw new Error("invalid_expected_turns_file_json");
    }
  }
  const sourceTurns = Array.isArray(document)
    ? document
    : Array.isArray(document?.turns)
      ? document.turns
      : null;
  if (sourceTurns) {
    if (sourceTurns.length < 2) throw new Error("at_least_two_turns_required");
    const turns = sourceTurns.map(normalizeExpectedTurn);
    return {
      routes: turns.map(turn => turn.model),
      turns,
      requireContractContinuity:
        document?.requireContractContinuity === true
        || String(process.env.TATWO_SAME_THREAD_REQUIRE_CONTRACT_CONTINUITY ?? "")
          .trim() === "1",
      contract: normalizeContractPlan(document?.contract),
    };
  }
  const routes = String(
    process.env.TATWO_SAME_THREAD_EXPECTED_ROUTES
      ?? "gpt-5.5,opus-5,sonnet-5,haiku-4-5,gpt-5.5",
  )
    .split(",")
    .map(value => value.trim())
    .filter(Boolean);
  if (routes.length < 2) throw new Error("at_least_two_turns_required");
  const turns = routes.map(model => normalizeExpectedTurn({ model }));
  return {
    routes,
    turns,
    requireContractContinuity:
      String(process.env.TATWO_SAME_THREAD_REQUIRE_CONTRACT_CONTINUITY ?? "")
        .trim() === "1",
    contract: normalizeContractPlan(null),
  };
}

function normalizeExpectedTurn(value, index) {
  const model = nonEmptyValue(value?.model);
  if (!model) throw new Error(`expected_turn_model_missing_${index}`);
  const defaults = defaultTurnControls(model);
  const hasEffort = Object.prototype.hasOwnProperty.call(value ?? {}, "effort");
  const expectedEffort = hasEffort
    ? normalizeEffort(value?.effort)
    : defaults.effort;
  if (hasEffort && value?.effort != null && expectedEffort === null) {
    throw new Error(`invalid_turn_effort_${index}`);
  }
  return {
    model,
    expectedEffort,
    expectedActualModel:
      nonEmptyValue(value?.expectedActualModel) ?? defaults.expectedActualModel,
    expectedCanonicalModel:
      nonEmptyValue(value?.expectedCanonicalModel) ?? defaults.expectedCanonicalModel,
  };
}

function defaultTurnControls(model) {
  switch (String(model).trim().toLowerCase()) {
  case "gpt-5.6-sol":
    return {
      effort: "low",
      expectedActualModel: "gpt-5.6-sol",
      expectedCanonicalModel: "gpt-5.6-sol",
    };
  case "gpt-5.6-luna":
    return {
      effort: "xhigh",
      expectedActualModel: "gpt-5.6-luna",
      expectedCanonicalModel: "gpt-5.6-luna",
    };
  case "fable-5":
    return {
      effort: null,
      expectedActualModel: "claude-fable-5",
      expectedCanonicalModel: "fable-5",
    };
  case "opus-5":
    return {
      effort: "high",
      expectedActualModel: "claude-opus-5",
      expectedCanonicalModel: "opus-5",
    };
  case "grok-build":
    return {
      effort: "xhigh",
      expectedActualModel: "grok-4.6",
      expectedCanonicalModel: "grok-build",
    };
  default: {
    const normalized = String(model).trim().toLowerCase();
    return {
      effort: null,
      expectedActualModel: normalized,
      expectedCanonicalModel: normalized,
    };
  }
  }
}

function normalizeEffort(value) {
  const normalized = String(value ?? "").trim().toLowerCase();
  return ["low", "medium", "high", "xhigh"].includes(normalized)
    ? normalized
    : null;
}

function normalizeContractPlan(value) {
  return {
    contractID: nonEmptyValue(value?.contractID ?? value?.contract_id),
    goalID: nonEmptyValue(value?.goalID ?? value?.goal_id),
    contractRevision: nonEmptyValue(
      value?.contractRevision ?? value?.contract_revision ?? value?.revision,
    ),
    instanceID: nonEmptyValue(value?.instanceID ?? value?.instance_id),
  };
}

function parseLiveOutput(raw, expectedNonce, expectedRunID, expectedTurnPlan) {
  const expectedRoutes = expectedTurnPlan.routes;
  const lines = String(raw ?? "")
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean);
  if (lines.length !== 1) {
    return invalidLiveReceipt(
      expectedRoutes,
      lines.length === 0
        ? "structured_gateway_receipt_missing"
        : "stdout_must_contain_exactly_one_json_line");
  }

  let receipt;
  try {
    receipt = JSON.parse(lines[0]);
  } catch {
    return invalidLiveReceipt(expectedRoutes, "structured_gateway_receipt_invalid_json");
  }
  if (receipt?.schema !== "TatwoGatewaySameThreadReceiptV1") {
    return invalidLiveReceipt(expectedRoutes, "structured_gateway_receipt_wrong_schema");
  }
  const orderedRoutes = Array.isArray(receipt.orderedRoutes) ? receipt.orderedRoutes : [];
  const orderedTurns = Array.isArray(receipt.orderedTurns) ? receipt.orderedTurns : [];
  const actualModels = orderedRoutes.map(route => String(route?.model ?? "").trim());
  const responseIDs = orderedRoutes.map(route => String(route?.responseID ?? "").trim());
  const legacyReceiptBody = {
    testNonce: expectedNonce,
    appThreadID: receipt.appThreadID,
    runID: expectedRunID,
    threadProvider: "model_gateway",
    orderedRoutes,
  };
  const expectedReceiptID = gatewayReceiptID(legacyReceiptBody);
  const versionedValidation = validateVersionedReceipt(
    receipt,
    legacyReceiptBody,
    orderedTurns,
    expectedTurnPlan,
  );
  const valid =
    receipt.ok === true
    && receipt.terminalStatus === "completed"
    && receipt.testNonce === expectedNonce
    && receipt.runID === expectedRunID
    && receipt.gatewayReceiptID === expectedReceiptID
    && nonEmpty(receipt.appThreadID)
    && receipt.threadProvider === "model_gateway"
    && orderedRoutes.length === expectedRoutes.length
    && actualModels.every((model, index) => model === expectedRoutes[index])
    && orderedRoutes.every((route, index) =>
      route?.order === index && route?.terminalStatus === "completed")
    && responseIDs.every(nonEmpty)
    && new Set(responseIDs).size === responseIDs.length
    && versionedValidation.ok;
  if (!valid) {
    return invalidLiveReceipt(
      expectedRoutes,
      versionedValidation.error ?? "structured_gateway_receipt_invalid",
    );
  }

  return {
    verified: true,
    evidence: {
      gatewayReceiptID: receipt.gatewayReceiptID,
      ...(receipt.receiptVersion
        ? {
            receiptVersion: receipt.receiptVersion,
            sameThreadReceiptID: receipt.sameThreadReceiptID ?? null,
          }
        : {}),
      appThreadID: receipt.appThreadID,
      runID: receipt.runID,
      directModels: orderedRoutes.map(route => ({
        model: route.model,
        responseID: route.responseID,
        status: "pass",
      })),
      sameThread: {
        sequence: actualModels.join(" -> "),
        status: "pass",
        failure: null,
      },
    },
  };
}

function validateVersionedReceipt(receipt, legacyReceiptBody, orderedTurns, plan) {
  const version = Number(receipt?.receiptVersion ?? 1);
  if (version === 1) {
    return { ok: orderedTurns.length === 0, error: "legacy_receipt_has_unbound_turn_details" };
  }
  if (version !== 2) return { ok: false, error: "unsupported_same_thread_receipt_version" };
  const expectedVersionedReceiptID = versionedGatewayReceiptID({
    ...legacyReceiptBody,
    receiptVersion: 2,
    orderedTurns,
  });
  if (receipt.sameThreadReceiptID !== expectedVersionedReceiptID) {
    return { ok: false, error: "versioned_same_thread_receipt_integrity_mismatch" };
  }
  if (orderedTurns.length !== plan.routes.length) {
    return { ok: false, error: "versioned_turn_count_mismatch" };
  }
  const assistantIDs = new Set();
  const turnIDs = new Set();
  const terminalTurnIDs = new Set();
  const gatewayResponseIDs = new Set();
  let continuityIdentity = null;
  for (let index = 0; index < orderedTurns.length; index += 1) {
    const turn = orderedTurns[index];
    const expectedTurn = plan.turns[index];
    if (!turn || turn.order !== index || turn.terminalStatus !== "completed") {
      return { ok: false, error: "versioned_turn_order_or_terminal_invalid" };
    }
    if (
      turn.runID !== legacyReceiptBody.runID
      || !Number.isInteger(turn.attempt)
      || turn.attempt < 1
      || !expectedTurn
      || turn.selectedRoute !== expectedTurn.model
      || turn.canonicalModel !== expectedTurn.expectedCanonicalModel
    ) {
      return { ok: false, error: "versioned_turn_identity_invalid" };
    }
    if (!vendorModelMatches(
      expectedTurn.expectedActualModel,
      turn.actualVendorModel,
    )) {
      return { ok: false, error: "versioned_actual_vendor_model_missing_or_mismatch" };
    }
    if (turn.fallbackCount !== 0) {
      return { ok: false, error: "versioned_fallback_evidence_missing_or_nonzero" };
    }
    if (
      turn.requestedEffort !== expectedTurn.expectedEffort
      || turn.observedEffort !== expectedTurn.expectedEffort
      || turn.forwardedEffort !== expectedTurn.expectedEffort
    ) {
      return { ok: false, error: "versioned_effort_forwarding_missing_or_mismatch" };
    }
    const ids = [
      [assistantIDs, turn.assistantItemID],
      [turnIDs, turn.turnID],
      [terminalTurnIDs, turn.terminalTurnID],
      [gatewayResponseIDs, turn.gatewayResponseID],
    ];
    for (const [seen, value] of ids) {
      if (!nonEmpty(value) || seen.has(value)) {
        return { ok: false, error: "versioned_turn_identifier_missing_or_duplicate" };
      }
      seen.add(value);
    }
    if (plan.requireContractContinuity) {
      const identity = {
        contractID: turn.contractID,
        goalID: turn.goalID,
        contractRevision: turn.contractRevision,
        instanceID: turn.instanceID,
      };
      if (Object.values(identity).some(value => !nonEmpty(value))) {
        return { ok: false, error: "versioned_contract_continuity_attestation_missing" };
      }
      if (
        (plan.contract.contractID && identity.contractID !== plan.contract.contractID)
        || (plan.contract.goalID && identity.goalID !== plan.contract.goalID)
        || (
          plan.contract.contractRevision
          && identity.contractRevision !== plan.contract.contractRevision
        )
        || (plan.contract.instanceID && identity.instanceID !== plan.contract.instanceID)
      ) {
        return { ok: false, error: "versioned_contract_continuity_expected_identity_mismatch" };
      }
      if (
        continuityIdentity
        && Object.keys(identity).some(
          key => identity[key] !== continuityIdentity[key],
        )
      ) {
        return { ok: false, error: "versioned_contract_churn_detected" };
      }
      continuityIdentity ??= identity;
    }
  }
  return { ok: true, error: null };
}

function vendorModelMatches(expected, actual) {
  const normalizedExpected = String(expected ?? "").trim().toLowerCase();
  const normalizedActual = String(actual ?? "").trim().toLowerCase();
  if (!normalizedExpected || !normalizedActual) return false;
  if (normalizedExpected === "grok-4.6") return normalizedActual === "grok-4.6";
  if (normalizedExpected === "claude-fable-5") {
    return /^claude-fable-5(?:-\d{8})?$/.test(normalizedActual);
  }
  if (normalizedExpected === "claude-opus-5") {
    return /^claude-opus-5(?:-\d{8})?$/.test(normalizedActual);
  }
  return normalizedActual === normalizedExpected;
}

function invalidLiveReceipt(expectedRoutes, reason) {
  return {
    verified: false,
    evidence: {
      receiptValidationError: reason,
      directModels: expectedRoutes.map(model => ({ model, status: "unknown" })),
      sameThread: {
        sequence: expectedRoutes.join(" -> "),
        status: "unknown",
        failure: null,
      },
    },
  };
}

function nonEmpty(value) {
  return nonEmptyValue(value) !== null;
}

function nonEmptyValue(value) {
  const text = typeof value === "string" ? value.trim() : "";
  return text || null;
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

function classify(value, options = {}) {
  if (!value || typeof value !== "object") return "unknown";
  const direct = Array.isArray(value.directModels)
    && value.directModels.length > 0
    && value.directModels.every(item => item?.status === "pass");
  const sameThread = value.sameThread?.status;
  if (direct && sameThread === "pass" && options.authoritativePass === true) return "pass";
  if (direct && sameThread === "fail" && value.sameThread?.failure) return "expected-fail";
  return "unknown";
}

function summaryFor(value) {
  switch (value) {
  case "pass":
    return "同一 Codex App thread 的 continuity smoke 通過。";
  case "expected-fail":
    return "direct route 通過，但同 thread 失敗已被分類並保留證據；不可宣稱整體通過。";
  default:
    return "尚不足以判定 same-thread continuity；需要真實同 thread 收據。";
  }
}

function sanitizeEvidence(value) {
  if (!value || typeof value !== "object") return null;
  const text = JSON.stringify(value)
    .replace(/\/Users\/[^\s"]+/g, "<local-path>")
    .replace(/\/Volumes\/[^\s"]+/g, "<external-path>");
  return JSON.parse(text);
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith("--")) continue;
    const equal = arg.indexOf("=");
    if (equal >= 0) out[arg.slice(2, equal)] = arg.slice(equal + 1);
    else out[arg.slice(2)] = argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[++i] : true;
  }
  return out;
}
