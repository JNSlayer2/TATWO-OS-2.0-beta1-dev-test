#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

export const EXACT_SCENARIO_ID = "general-xxl-sol-fable5-luna-grok-exact";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const directGatewayAdapter = path.join(scriptDir, "tatwo-direct-gateway-chat.mjs");
const callerKeys = new Set(["contractID", "goalID", "input"]);

// These are fail-closed semantic assertions, not source-slot defaults.
// Dispatch identity/model/binding/sourceSlot values are copied from the issued
// projection below. Source-slot IDs may differ between a builtin scenario and
// a custom copy, but the issued contract and Loop Governor must agree exactly.
const canonicalBindingRequirements = [
  {
    route: "sol",
    identity: "lead",
    phase: "plan",
    requestedModel: "gpt-5.6-sol",
    expectedActualModels: ["gpt-5.6-sol"],
    requestedEffort: "low",
    serviceTier: "fast",
    adapter: "codex-exec",
  },
  {
    route: "fable5",
    identity: "supervisor",
    phase: "loops",
    requestedModel: "fable-5",
    expectedActualModels: ["fable-5", "claude-fable-5"],
    requestedEffort: null,
    serviceTier: null,
    adapter: "gateway-direct",
  },
  {
    route: "luna",
    identity: "sub",
    phase: "loops",
    requestedModel: "gpt-5.6-luna",
    expectedActualModels: ["gpt-5.6-luna"],
    requestedEffort: "xhigh",
    serviceTier: null,
    adapter: "codex-exec",
  },
  {
    route: "grok",
    identity: "sub",
    phase: "loops",
    requestedModel: "grok-build",
    expectedActualModels: ["grok-4.6"],
    expectedCanonicalModels: ["grok-build"],
    requestedEffort: "xhigh",
    serviceTier: null,
    adapter: "gateway-direct",
    requiresIsolation: true,
  },
];

const executionStages = [
  { id: "sol-lead", route: "sol", phase: "lead" },
  { id: "luna-sub", route: "luna", phase: "sub" },
  { id: "grok-sub", route: "grok", phase: "sub" },
  { id: "fable5-review", route: "fable5", phase: "review" },
  { id: "sol-converge", route: "sol", phase: "converge" },
];

export class ContractLoopsExecutionError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.name = "ContractLoopsExecutionError";
    this.code = code;
    Object.assign(this, details);
  }
}

export function createMemoryContractLedger(contracts = []) {
  const values = Array.isArray(contracts) ? contracts : [contracts];
  const byContractID = new Map();
  for (const value of values) {
    const issued = unwrapIssuedContract(value);
    if (issued?.contractID) byContractID.set(issued.contractID, value);
  }
  return {
    async resolveIssuedContract({ contractID, goalID }) {
      const value = byContractID.get(contractID);
      if (!value) throw executionError("unregistered_contract", `unregistered_contract:${contractID}`);
      const issued = unwrapIssuedContract(value);
      if (issued.goalID !== goalID) {
        throw executionError("goal_contract_mismatch", `goal_contract_mismatch:${contractID}:${goalID}`);
      }
      return value;
    },
  };
}

export function createMemoryExecutionJournal() {
  const executions = new Map();
  let finalizeCount = 0;
  return {
    load(executionID) {
      return clone(executions.get(executionID) ?? null);
    },
    begin(executionID, seed) {
      if (!executions.has(executionID)) {
        executions.set(executionID, {
          ...clone(seed),
          stages: {},
          finalReceipt: null,
          terminalFailure: null,
        });
      }
      return clone(executions.get(executionID));
    },
    completeStage(executionID, stageID, receipt) {
      const record = requireJournalRecord(executions, executionID);
      if (!record.stages[stageID]) record.stages[stageID] = clone(receipt);
      return clone(record.stages[stageID]);
    },
    fail(executionID, failure) {
      const record = requireJournalRecord(executions, executionID);
      if (!record.terminalFailure) record.terminalFailure = serializeFailure(failure);
      return clone(record.terminalFailure);
    },
    finalize(executionID, receipt) {
      const record = requireJournalRecord(executions, executionID);
      if (!record.finalReceipt) {
        record.finalReceipt = clone(receipt);
        finalizeCount += 1;
      }
      return clone(record.finalReceipt);
    },
    get finalizeCount() {
      return finalizeCount;
    },
  };
}

export function resolveContractBoundBindings(ledgerValue) {
  const issued = unwrapIssuedContract(ledgerValue);
  validateIssuedContract(ledgerValue, issued);
  const activated = issued.loopGovernorDecision?.activatedBindings;
  if (!Array.isArray(activated)) {
    throw executionError("canonical_bindings_missing", "canonical_bindings_missing:loopGovernorDecision.activatedBindings");
  }
  const identityBindings = issued.identityBindings;
  if (!Array.isArray(identityBindings)) {
    throw executionError("canonical_bindings_missing", "canonical_bindings_missing:identityBindings");
  }

  const relevantIdentityBindings = identityBindings
    .filter(binding => ["lead", "supervisor", "sub"].includes(normalizeIdentity(binding?.identity)));
  const relevantGovernorBindings = activated
    .filter(binding => ["lead", "supervisor", "sub"].includes(normalizeIdentity(binding?.identity)));
  if (
    relevantIdentityBindings.length !== canonicalBindingRequirements.length
    || relevantGovernorBindings.length !== canonicalBindingRequirements.length
  ) {
    throw executionError(
      "noncanonical_binding_topology",
      `noncanonical_binding_topology:expected_${canonicalBindingRequirements.length}`
        + `:identity_${relevantIdentityBindings.length}:governor_${relevantGovernorBindings.length}`,
    );
  }

  const resolved = relevantIdentityBindings.map(identityBinding => {
    const issuedSourceSlotID = mustString(identityBinding.sourceSlotID, "sourceSlotID");
    const issuedIdentity = normalizeIdentity(identityBinding.identity);
    const issuedModel = mustString(identityBinding.modelID, "modelID");
    const matchingSpecifications = canonicalBindingRequirements.filter(specification =>
      issuedIdentity === specification.identity
      && normalizeModel(issuedModel) === normalizeModel(specification.requestedModel));
    if (matchingSpecifications.length !== 1) {
      throw executionError(
        "noncanonical_binding_topology",
        `noncanonical_binding_topology:semantic_match_${matchingSpecifications.length}`
          + `:${issuedSourceSlotID}:${issuedIdentity}:${issuedModel}`,
      );
    }
    const specification = matchingSpecifications[0];
    const governorMatches = relevantGovernorBindings.filter(binding =>
      String(binding?.id ?? "") === issuedSourceSlotID);
    if (governorMatches.length !== 1) {
      throw executionError(
        "canonical_binding_ambiguous",
        `canonical_binding_ambiguous:${issuedSourceSlotID}:${governorMatches.length}`,
      );
    }
    const governorBinding = governorMatches[0];
    if (
      governorBinding.enabled !== true
      ||
      normalizeIdentity(governorBinding.identity) !== issuedIdentity
      || governorBinding?.boundModelIDs?.length !== 1
      || normalizeModel(governorBinding.boundModelIDs[0]) !== normalizeModel(issuedModel)
      || normalizePhase(governorBinding.phase) !== specification.phase
    ) {
      throw executionError(
        "governor_issued_binding_mismatch",
        `governor_issued_binding_mismatch:${issuedSourceSlotID}`,
      );
    }
    const requestedEffort = normalizeEffort(governorBinding.reasoningEffort);
    if (requestedEffort !== specification.requestedEffort) {
      throw executionError(
        "contract_effort_mismatch",
        `contract_effort_mismatch:${specification.route}:${requestedEffort ?? "none"}`,
      );
    }
    return Object.freeze({
      route: specification.route,
      contractID: issued.contractID,
      goalID: issued.goalID,
      bindingID: mustString(identityBinding.id, "bindingID"),
      sourceSlotID: issuedSourceSlotID,
      identity: issuedIdentity,
      requestedModel: issuedModel,
      expectedActualModels: [...specification.expectedActualModels],
      expectedCanonicalModels: [...(specification.expectedCanonicalModels ?? specification.expectedActualModels)],
      requestedEffort,
      serviceTier: specification.serviceTier,
      adapter: specification.adapter,
      requiresIsolation: specification.requiresIsolation === true,
    });
  }).sort((left, right) =>
    canonicalBindingRequirements.findIndex(value => value.route === left.route)
    - canonicalBindingRequirements.findIndex(value => value.route === right.route));

  if (
    new Set(resolved.map(binding => binding.route)).size !== canonicalBindingRequirements.length
    || new Set(resolved.map(binding => binding.bindingID)).size !== canonicalBindingRequirements.length
    || new Set(resolved.map(binding => binding.sourceSlotID)).size !== canonicalBindingRequirements.length
  ) {
    throw executionError(
      "noncanonical_binding_topology",
      `noncanonical_binding_topology:expected_${canonicalBindingRequirements.length}:actual_${resolved.length}`,
    );
  }
  return resolved;
}

export function createContractLoopsExecutor({
  contractLedger,
  runners,
  journal = createMemoryExecutionJournal(),
  clock = () => new Date().toISOString(),
} = {}) {
  if (!contractLedger || typeof contractLedger.resolveIssuedContract !== "function") {
    throw new TypeError("contractLedger.resolveIssuedContract is required");
  }
  if (!runners || typeof runners !== "object") {
    throw new TypeError("runners are required");
  }
  const inFlight = new Map();

  return {
    journal,
    async execute(request, runtime = {}) {
      validateCallerRequest(request);
      const input = mustString(request.input, "input");
      const executionID = logicalExecutionID(request.contractID, request.goalID, input);
      const existing = journal.load(executionID);
      if (existing?.finalReceipt) return existing.finalReceipt;
      if (existing?.terminalFailure) throw hydrateFailure(existing.terminalFailure);
      if (inFlight.has(executionID)) return inFlight.get(executionID);
      const promise = executeOnce({
        request: { ...request, input },
        runtime,
        executionID,
        contractLedger,
        runners,
        journal,
        clock,
      }).finally(() => inFlight.delete(executionID));
      inFlight.set(executionID, promise);
      return promise;
    },
  };
}

export async function executeContractLoops(request, dependencies = {}, runtime = {}) {
  return createContractLoopsExecutor(dependencies).execute(request, runtime);
}

export function createProcessRunners(options = {}) {
  const codexExecutable = String(options.codexExecutable ?? process.env.TATWO_CONTRACT_LOOPS_CODEX_BIN ?? "codex");
  const gatewayAdapterScript = path.resolve(String(
    options.gatewayAdapterScript
      ?? process.env.TATWO_CONTRACT_LOOPS_GATEWAY_ADAPTER
      ?? directGatewayAdapter,
  ));
  const timeoutMs = Number(options.timeoutMs ?? process.env.TATWO_CONTRACT_LOOPS_TIMEOUT_MS ?? 600_000);
  return {
    "codex-exec": dispatch => runCodexDispatch(dispatch, { codexExecutable, timeoutMs }),
    "gateway-direct": dispatch => runGatewayDispatch(dispatch, { gatewayAdapterScript, timeoutMs }),
  };
}

async function executeOnce({ request, runtime, executionID, contractLedger, runners, journal, clock }) {
  throwIfCancelled(runtime.signal, executionID);
  const ledgerValue = await contractLedger.resolveIssuedContract({
    contractID: request.contractID,
    goalID: request.goalID,
  });
  const issued = unwrapIssuedContract(ledgerValue);
  const bindings = resolveContractBoundBindings(ledgerValue);
  const bindingByRoute = new Map(bindings.map(binding => [binding.route, binding]));
  journal.begin(executionID, {
    schema: "TatwoContractLoopsExecutionJournalV1",
    executionID,
    contractID: issued.contractID,
    goalID: issued.goalID,
    inputDigest: sha256(request.input),
    scenario: issued.scenario,
  });

  const receipts = [];
  for (const stage of executionStages) {
    const snapshot = journal.load(executionID);
    const saved = snapshot?.stages?.[stage.id];
    if (saved) {
      receipts.push(saved);
      continue;
    }
    throwIfCancelled(runtime.signal, executionID, receipts);
    const binding = bindingByRoute.get(stage.route);
    const dispatch = Object.freeze({
      schema: "TatwoContractBoundDispatchV1",
      executionID,
      logicalDispatchID: `${executionID}:${stage.id}`,
      stageID: stage.id,
      phase: stage.phase,
      contractID: binding.contractID,
      goalID: binding.goalID,
      bindingID: binding.bindingID,
      sourceSlotID: binding.sourceSlotID,
      identity: binding.identity,
      requestedModel: binding.requestedModel,
      requestedEffort: binding.requestedEffort,
      serviceTier: binding.serviceTier,
      adapter: binding.adapter,
      input: stageInput(stage, request.input, receipts),
      priorReceipts: receipts.map(publicReceiptContext),
    });
    const runner = runners[binding.adapter];
    if (typeof runner !== "function") {
      const error = executionError("runner_missing", `runner_missing:${binding.adapter}`, {
        executionID,
        stageID: stage.id,
        partialReceipts: receipts,
      });
      journal.fail(executionID, error);
      throw error;
    }

    let result;
    try {
      result = await runner(dispatch, { signal: runtime.signal });
    } catch (error) {
      if (isCancellation(error) || runtime.signal?.aborted) {
        throw cancellationError(executionID, receipts);
      }
      if (error?.reconnectable === true) {
        throw executionError("execution_interrupted", `execution_interrupted:${stage.id}`, {
          executionID,
          stageID: stage.id,
          resumable: true,
          partialReceipts: receipts,
          cause: error,
        });
      }
      const wrapped = executionError("runner_failed", `runner_failed:${stage.id}:${error?.message ?? error}`, {
        executionID,
        stageID: stage.id,
        partialReceipts: receipts,
        cause: error,
      });
      journal.fail(executionID, wrapped);
      throw wrapped;
    }

    const receipt = buildAndValidateReceipt({ executionID, stage, binding, result, clock });
    if (!receipt.passed) {
      const error = executionError(receipt.failureCode, `${receipt.failureCode}:${stage.id}`, {
        executionID,
        stageID: stage.id,
        receipt,
        partialReceipts: [...receipts, receipt],
      });
      journal.fail(executionID, error);
      throw error;
    }
    const persisted = journal.completeStage(executionID, stage.id, receipt);
    receipts.push(persisted);
    throwIfCancelled(runtime.signal, executionID, receipts);
  }

  const finalOutput = receipts.at(-1)?.output ?? null;
  const finalReceipt = {
    schema: "TatwoContractLoopsExecutionReceiptV1",
    receiptID: `contract-loops-${shortHash(`${executionID}|final`)}`,
    executionID,
    contractID: issued.contractID,
    goalID: issued.goalID,
    scenario: issued.scenario,
    inputDigest: sha256(request.input),
    status: "completed",
    finalizedAt: clock(),
    bindings: bindings.map(binding => ({
      bindingID: binding.bindingID,
      sourceSlotID: binding.sourceSlotID,
      identity: binding.identity,
      requestedModel: binding.requestedModel,
      requestedEffort: binding.requestedEffort,
      serviceTier: binding.serviceTier,
      adapter: binding.adapter,
    })),
    receipts,
    finalOutput,
    passed: receipts.length === executionStages.length && receipts.every(receipt => receipt.passed),
  };
  return journal.finalize(executionID, finalReceipt);
}

function buildAndValidateReceipt({ executionID, stage, binding, result, clock }) {
  const raw = result && typeof result === "object" ? result : {};
  const actualIdentity = normalizeIdentity(raw.actualIdentity);
  const actualModel = normalizeVendorModel(raw.actualModel ?? raw.actualVendorModel);
  const actualCanonicalModel = normalizeModel(raw.actualCanonicalModel ?? actualModel);
  const fallbackCount = finiteNonNegativeInteger(raw.fallbackCount);
  const forwardedEffort = normalizeEffort(raw.forwardedEffort);
  const effectiveEffort = normalizeEffort(raw.effectiveEffort);
  const forwardedServiceTier = normalizeServiceTier(raw.forwardedServiceTier);
  const effectiveServiceTier = normalizeServiceTier(raw.effectiveServiceTier);
  const providerResponseID = optionalString(raw.providerResponseID ?? raw.responseID);
  const threadID = optionalString(raw.threadID);
  const output = optionalString(raw.output ?? raw.text ?? raw.responseText);
  const failures = [];

  if (raw.ok !== true) failures.push("runner_not_ok");
  if (actualIdentity !== binding.identity) failures.push("identity_spoof_or_missing");
  if (optionalString(raw.actualBindingID) !== binding.bindingID) failures.push("binding_spoof_or_missing");
  if (optionalString(raw.actualSourceSlotID) !== binding.sourceSlotID) failures.push("source_slot_spoof_or_missing");
  const expectedVendorModels = binding.expectedActualModels.map(normalizeVendorModel);
  const expectedCanonicalModels = binding.expectedCanonicalModels.map(normalizeModel);
  const vendorRequired = expectedVendorModels.length > 0;
  const canonicalRequired = expectedCanonicalModels.length > 0;
  const vendorMatches = expectedVendorModels.includes(actualModel);
  const canonicalMatches = expectedCanonicalModels.includes(actualCanonicalModel);
  if (
    (vendorRequired && (!actualModel || !vendorMatches))
    || (canonicalRequired && (!actualCanonicalModel || !canonicalMatches))
    || (!vendorRequired && !canonicalRequired && !actualModel && !actualCanonicalModel)
  ) {
    failures.push("model_spoof_or_mismatch");
  }
  if (fallbackCount === null) failures.push("fallback_count_missing");
  if (fallbackCount !== null && fallbackCount > 0) failures.push("fallback_detected");
  if (binding.requestedEffort !== null) {
    if (forwardedEffort !== binding.requestedEffort) failures.push("effort_not_forwarded");
    if (effectiveEffort !== binding.requestedEffort || raw.effectiveEffortAttested !== true) {
      failures.push("effort_not_effective_or_unattested");
    }
  }
  if (binding.serviceTier !== null) {
    if (forwardedServiceTier !== binding.serviceTier) failures.push("service_tier_not_forwarded");
    if (effectiveServiceTier !== binding.serviceTier) failures.push("service_tier_not_effective");
  }
  if (!providerResponseID && !threadID) failures.push("provider_response_or_thread_id_missing");
  if (!output) failures.push("provider_output_missing");
  if (binding.requiresIsolation) {
    const isolation = raw.isolation;
    const permissionSources = Array.isArray(isolation?.permissionSources)
      ? isolation.permissionSources
      : null;
    const launcher = String(isolation?.launcher ?? "").trim();
    if (
      isolation?.isolated !== true
      || !/(?:^|\/)grok-isolated$|gateway-isolated-grok/.test(launcher)
      || permissionSources === null
      || permissionSources.length !== 0
    ) {
      failures.push("grok_isolation_unverified");
    }
  }

  const failureCode = binding.route === "fable5" && failures.includes("fallback_detected")
    ? "fable5_fallback_fail_closed"
    : failures[0] ?? null;
  return {
    schema: "TatwoContractBoundDispatchReceiptV1",
    receiptID: optionalString(raw.receiptID)
      ?? `dispatch-receipt-${shortHash(`${executionID}|${stage.id}|${providerResponseID ?? threadID ?? "missing"}`)}`,
    executionID,
    logicalDispatchID: `${executionID}:${stage.id}`,
    stageID: stage.id,
    phase: stage.phase,
    contractID: binding.contractID,
    goalID: binding.goalID,
    bindingID: binding.bindingID,
    sourceSlotID: binding.sourceSlotID,
    identity: binding.identity,
    actualIdentity: actualIdentity || null,
    requestedModel: binding.requestedModel,
    actualModel: actualModel || null,
    actualCanonicalModel: actualCanonicalModel || null,
    requestedEffort: binding.requestedEffort,
    forwardedEffort,
    effectiveEffort,
    effectiveEffortAttested: raw.effectiveEffortAttested === true,
    requestedServiceTier: binding.serviceTier,
    forwardedServiceTier,
    effectiveServiceTier,
    fallbackCount,
    providerResponseID,
    threadID,
    providerReceiptID: optionalString(raw.providerReceiptID),
    output,
    isolation: binding.requiresIsolation ? clone(raw.isolation ?? null) : null,
    adapter: binding.adapter,
    completedAt: clock(),
    failureReasons: failures,
    failureCode,
    passed: failures.length === 0,
  };
}

function validateIssuedContract(ledgerValue, issued) {
  if (!issued || typeof issued !== "object") {
    throw executionError("issued_contract_missing", "issued_contract_missing");
  }
  const contractID = mustString(issued.contractID, "contractID");
  const goalID = mustString(issued.goalID, "goalID");
  const ledgerContractID = optionalString(ledgerValue?.contractID);
  const ledgerGoalID = optionalString(ledgerValue?.goalID);
  if (ledgerContractID && ledgerContractID !== contractID) {
    throw executionError("ledger_contract_mismatch", `ledger_contract_mismatch:${ledgerContractID}:${contractID}`);
  }
  if (ledgerGoalID && ledgerGoalID !== goalID) {
    throw executionError("ledger_goal_mismatch", `ledger_goal_mismatch:${ledgerGoalID}:${goalID}`);
  }
  if (String(issued.schema ?? "") !== "TatwoWorkOSContractV1") {
    throw executionError("issued_contract_schema_invalid", `issued_contract_schema_invalid:${issued.schema ?? "missing"}`);
  }
  if (String(issued.mode ?? "").toUpperCase() !== "XXL") {
    throw executionError("contract_mode_mismatch", `contract_mode_mismatch:${issued.mode ?? "missing"}`);
  }
  const scenario = mustString(issued.scenario, "scenario");
  const governorScenario = mustString(
    issued.loopGovernorDecision?.scenarioID,
    "loopGovernorDecision_scenarioID",
  );
  if (governorScenario !== scenario) {
    throw executionError(
      "contract_scenario_mismatch",
      `contract_scenario_mismatch:${scenario}:${governorScenario}`,
    );
  }
  if (String(issued.loopGovernorDecision?.mode ?? "").toUpperCase() !== "XXL") {
    throw executionError(
      "contract_governor_mode_mismatch",
      `contract_governor_mode_mismatch:${issued.loopGovernorDecision?.mode ?? "missing"}`,
    );
  }
}

function validateCallerRequest(request) {
  if (!request || typeof request !== "object" || Array.isArray(request)) {
    throw executionError("invalid_request", "invalid_request");
  }
  for (const key of Object.keys(request)) {
    if (!callerKeys.has(key)) {
      throw executionError("caller_binding_override_forbidden", `caller_binding_override_forbidden:${key}`);
    }
  }
  mustString(request.contractID, "contractID");
  mustString(request.goalID, "goalID");
  mustString(request.input, "input");
}

function stageInput(stage, input, receipts) {
  const prior = receipts.map(receipt => ({
    stageID: receipt.stageID,
    identity: receipt.identity,
    requestedModel: receipt.requestedModel,
    actualModel: receipt.actualModel,
    output: receipt.output,
    receiptID: receipt.receiptID,
  }));
  return JSON.stringify({
    goalInput: input,
    instruction: stageInstruction(stage),
    prior,
  });
}

function stageInstruction(stage) {
  switch (stage.id) {
  case "sol-lead": return "Act as the sole Sol lead. Frame the work and define bounded sub tasks; do not claim sub review.";
  case "luna-sub": return "Act only as the contract-bound Luna xhigh sub. Produce evidence and a candidate contribution for Sol.";
  case "grok-sub": return "Act only as the isolated Grok 4.6 xhigh sub. Produce an independent contribution for Sol.";
  case "fable5-review": return "Review the completed Luna and Grok sub outputs independently as Fable 5. Refute first; do not implement or self-pass.";
  case "sol-converge": return "As the sole Sol lead, converge the lead draft, both sub outputs, and Fable 5 review into the final answer.";
  default: throw new Error(`unknown_stage:${stage.id}`);
  }
}

function publicReceiptContext(receipt) {
  return {
    receiptID: receipt.receiptID,
    stageID: receipt.stageID,
    identity: receipt.identity,
    requestedModel: receipt.requestedModel,
    actualModel: receipt.actualModel,
    output: receipt.output,
  };
}

async function runCodexDispatch(dispatch, options) {
  const args = [
    "exec",
    "-C", repoRoot,
    "-s", "read-only",
    "-m", dispatch.requestedModel,
    "-c", `model_reasoning_effort="${dispatch.requestedEffort}"`,
    ...(dispatch.serviceTier ? ["-c", `service_tier="${dispatch.serviceTier}"`] : []),
    "--json",
    dispatch.input,
  ];
  const processResult = await spawnCaptured(options.codexExecutable, args, options.timeoutMs);
  const parsed = parseJSONL(processResult.stdout);
  const completed = parsed.find(event => event?.type === "turn.completed") ?? {};
  const threadID = optionalString(parsed.find(event => event?.type === "thread.started")?.thread_id);
  const output = assistantOutput(parsed);
  return {
    ok: processResult.code === 0,
    actualIdentity: dispatch.identity,
    actualBindingID: dispatch.bindingID,
    actualSourceSlotID: dispatch.sourceSlotID,
    actualModel: completed.actual_model ?? completed.model ?? null,
    actualCanonicalModel: completed.actual_canonical_model ?? completed.model ?? null,
    forwardedEffort: dispatch.requestedEffort,
    effectiveEffort: completed.effective_effort ?? completed.reasoning?.effective ?? null,
    effectiveEffortAttested: completed.reasoning?.effectiveProviderAttested === true,
    forwardedServiceTier: dispatch.serviceTier,
    effectiveServiceTier: completed.speed?.effective ?? null,
    fallbackCount: completed.fallback_count ?? completed.fallbackCount ?? null,
    threadID,
    output,
  };
}

async function runGatewayDispatch(dispatch, options) {
  const args = [
    options.gatewayAdapterScript,
    "--model", dispatch.requestedModel,
    ...(dispatch.requestedEffort ? ["--reasoning-effort", dispatch.requestedEffort] : []),
    ...(dispatch.serviceTier ? ["--service-tier", dispatch.serviceTier] : []),
    "--prompt", dispatch.input,
    "--dispatch-id", dispatch.logicalDispatchID,
    "--timeout-ms", String(options.timeoutMs),
  ];
  const processResult = await spawnCaptured(process.execPath, args, options.timeoutMs + 250);
  const parsed = parseJSONL(processResult.stdout);
  const completed = parsed.find(event => event?.type === "turn.completed") ?? {};
  const threadID = optionalString(parsed.find(event => event?.type === "thread.started")?.thread_id);
  const output = assistantOutput(parsed);
  const attestation = completed.model_attestation ?? {};
  const sessionEvidence = attestation.session_evidence ?? {};
  return {
    ok: processResult.code === 0,
    actualIdentity: dispatch.identity,
    actualBindingID: dispatch.bindingID,
    actualSourceSlotID: dispatch.sourceSlotID,
    actualModel: attestation.actual_vendor_model ?? completed.actual_model ?? null,
    actualCanonicalModel: attestation.actual_canonical_model ?? completed.model ?? null,
    forwardedEffort: completed.reasoning?.forwardedNativeField === true
      ? completed.reasoning?.requested
      : null,
    effectiveEffort: completed.reasoning?.effectiveProviderAttested === true
      ? completed.reasoning?.normalized
      : null,
    effectiveEffortAttested: completed.reasoning?.effectiveProviderAttested === true,
    forwardedServiceTier: completed.speed?.forwardedNativeField === true
      ? completed.speed?.requested
      : null,
    effectiveServiceTier: completed.speed?.effective ?? null,
    fallbackCount: attestation.fallback_count ?? null,
    providerResponseID: completed.response_id ?? null,
    threadID,
    output,
    isolation: dispatch.requestedModel === "grok-build" ? {
      isolated: sessionEvidence.isolated === true,
      launcher: sessionEvidence.launcher ?? null,
      permissionSources: sessionEvidence.permission_sources ?? sessionEvidence.permissionSources ?? null,
    } : null,
  };
}

function spawnCaptured(command, args, timeoutMs) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: repoRoot,
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => child.kill("SIGTERM"), timeoutMs);
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", chunk => { stdout += chunk; });
    child.stderr.on("data", chunk => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", code => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr });
    });
  });
}

function parseJSONL(text) {
  const values = [];
  for (const line of String(text ?? "").split(/\r?\n/)) {
    if (!line.trim()) continue;
    try { values.push(JSON.parse(line)); } catch { /* fail closed later on missing proof */ }
  }
  return values;
}

function assistantOutput(events) {
  const deltas = events
    .filter(event => event?.type === "response.output_text.delta")
    .map(event => String(event?.delta ?? ""))
    .join("");
  if (deltas) return deltas;
  return events
    .filter(event => event?.type === "item.completed" && event?.item?.type === "agent_message")
    .map(event => String(event.item.text ?? ""))
    .join("");
}

function throwIfCancelled(signal, executionID, receipts = []) {
  if (signal?.aborted) throw cancellationError(executionID, receipts);
}

function cancellationError(executionID, receipts) {
  return executionError("execution_cancelled", `execution_cancelled:${executionID}`, {
    executionID,
    resumable: true,
    partialReceipts: clone(receipts),
  });
}

function isCancellation(error) {
  return error?.name === "AbortError" || error?.code === "ABORT_ERR" || error?.code === "execution_cancelled";
}

function hydrateFailure(value) {
  return executionError(value.code ?? "execution_failed", value.message ?? "execution_failed", value.details ?? {});
}

function serializeFailure(error) {
  return {
    code: error.code ?? "execution_failed",
    message: error.message ?? String(error),
    details: {
      executionID: error.executionID ?? null,
      stageID: error.stageID ?? null,
      receipt: clone(error.receipt ?? null),
      partialReceipts: clone(error.partialReceipts ?? []),
      resumable: error.resumable === true,
    },
  };
}

function executionError(code, message, details = {}) {
  return new ContractLoopsExecutionError(code, message, details);
}

function unwrapIssuedContract(value) {
  return value?.issuedContract ?? value?.contract ?? value;
}

function requireJournalRecord(records, executionID) {
  const record = records.get(executionID);
  if (!record) throw new Error(`journal_execution_missing:${executionID}`);
  return record;
}

function logicalExecutionID(contractID, goalID, input) {
  return `contract-loops-${shortHash(`${contractID}|${goalID}|${sha256(input)}`)}`;
}

function normalizeIdentity(value) {
  const normalized = String(value ?? "").trim().toLowerCase();
  if (["lead", "主導", "主"].includes(normalized)) return "lead";
  if (["supervisor", "reviewer", "副審", "監督", "副"].includes(normalized)) return "supervisor";
  if (["sub", "executor", "分工", "執行", "執行手"].includes(normalized)) return "sub";
  return normalized;
}

function normalizeVendorModel(value) {
  return String(value ?? "").trim().toLowerCase().replace(/\[[^\]]+\]$/, "");
}

function normalizeModel(value) {
  const normalized = normalizeVendorModel(value);
  const aliases = new Map([
    ["claude-fable-5", "fable-5"],
    ["grok-4.6", "grok-build"],
  ]);
  return aliases.get(normalized) ?? normalized;
}

function normalizeEffort(value) {
  const normalized = String(value ?? "").trim().toLowerCase();
  if (!normalized) return null;
  if (["extra", "max", "ultra", "超高"].includes(normalized)) return "xhigh";
  return ["low", "medium", "high", "xhigh"].includes(normalized) ? normalized : normalized;
}

function normalizePhase(value) {
  return String(value ?? "").trim().toLowerCase();
}

function normalizeServiceTier(value) {
  const normalized = String(value ?? "").trim().toLowerCase();
  return normalized || null;
}

function finiteNonNegativeInteger(value) {
  if (value === null || value === undefined || value === "") return null;
  const number = Number(value);
  return Number.isInteger(number) && number >= 0 ? number : null;
}

function mustString(value, label) {
  const text = String(value ?? "").trim();
  if (!text) throw executionError(`missing_${label}`, `missing_${label}`);
  return text;
}

function optionalString(value) {
  const text = String(value ?? "").trim();
  return text || null;
}

function sha256(value) {
  return crypto.createHash("sha256").update(String(value)).digest("hex");
}

function shortHash(value) {
  return sha256(value).slice(0, 24);
}

function clone(value) {
  return value == null ? value : structuredClone(value);
}

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const raw = argv[index];
    if (!raw.startsWith("--")) continue;
    const key = raw.slice(2);
    const next = argv[index + 1];
    if (next && !next.startsWith("--")) {
      result[key] = next;
      index += 1;
    } else {
      result[key] = true;
    }
  }
  return result;
}

async function runCLI() {
  const args = parseArgs(process.argv.slice(2));
  const contractID = args.contract ?? args.contractID;
  const goalID = args.goal ?? args.goalID;
  const input = args.input ?? (args["input-file"] ? fs.readFileSync(path.resolve(args["input-file"]), "utf8") : null);
  const ledgerArgument = String(
    args.ledger ?? process.env.TATWO_CONTRACT_LOOPS_LEDGER_JSON ?? "",
  ).trim();
  if (!ledgerArgument) {
    throw executionError("ledger_file_missing", "ledger_file_missing:use --ledger or TATWO_CONTRACT_LOOPS_LEDGER_JSON");
  }
  const ledgerPath = path.resolve(ledgerArgument);
  if (!fs.existsSync(ledgerPath) || !fs.statSync(ledgerPath).isFile()) {
    throw executionError("ledger_file_missing", `ledger_file_missing:${ledgerPath}`);
  }
  const ledgerDocument = JSON.parse(fs.readFileSync(ledgerPath, "utf8"));
  const contracts = Array.isArray(ledgerDocument) ? ledgerDocument : ledgerDocument.contracts ?? [ledgerDocument];
  const executor = createContractLoopsExecutor({
    contractLedger: createMemoryContractLedger(contracts),
    runners: createProcessRunners(),
  });
  const result = await executor.execute({ contractID, goalID, input });
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

if (isDirectCLIEntrypoint()) {
  runCLI().catch(error => {
    process.stderr.write(`${JSON.stringify({
      schema: "TatwoContractLoopsExecutorErrorV1",
      ok: false,
      code: error?.code ?? "executor_failed",
      error: error?.message ?? String(error),
    })}\n`);
    process.exitCode = 2;
  });
}

function isDirectCLIEntrypoint() {
  if (!process.argv[1]) return false;
  try {
    return fs.realpathSync(fileURLToPath(import.meta.url))
      === fs.realpathSync(path.resolve(process.argv[1]));
  } catch {
    return fileURLToPath(import.meta.url) === path.resolve(process.argv[1]);
  }
}
