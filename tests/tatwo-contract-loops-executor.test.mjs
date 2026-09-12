#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  EXACT_SCENARIO_ID,
  createContractLoopsExecutor,
  createMemoryContractLedger,
  createMemoryExecutionJournal,
  resolveContractBoundBindings,
} from "../scripts/tatwo-contract-loops-executor.mjs";

const tests = [
  ["runs the direct CLI entrypoint when its path contains spaces", testDirectCLIPathWithSpaces],
  ["resolves all four issued bindings without collapsing duplicate sub identities", testResolveIssuedBindings],
  ["resolves the existing general-xxl source-slot topology semantically", testExistingGeneralXXLTopology],
  ["rejects ambiguous and incorrect semantic topologies", testAmbiguousAndIncorrectTopologies],
  ["runs Sol plan, Luna, Grok, Fable review, then Sol converge with complete receipts", testCanonicalOrderAndReceipts],
  ["rejects caller identity/model/binding/sourceSlot spoof inputs", testCallerSpoofRejected],
  ["fails closed on runner identity spoof and model spoof", testRunnerIdentityAndModelSpoof],
  ["fails closed when Fable 5 actually falls back to Opus", testFableFallbackFailsClosed],
  ["fails closed on unsupported effort evidence and missing Grok isolation", testEffortAndIsolationFailClosed],
  ["finalizes a repeated logical dispatch exactly once", testExactlyOnceFinalize],
  ["preserves completed stages across cancellation and reconnect resume", testCancelReconnectResume],
];

for (const [name, test] of tests) {
  await test();
  process.stdout.write(`ok - ${name}\n`);
}
process.stdout.write(`1..${tests.length}\n`);

async function testDirectCLIPathWithSpaces() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo executor path with spaces "));
  const copiedScript = path.join(directory, "executor copy with spaces.mjs");
  try {
    const sourceScript = fileURLToPath(
      new URL("../scripts/tatwo-contract-loops-executor.mjs", import.meta.url),
    );
    fs.copyFileSync(sourceScript, copiedScript);
    const result = spawnSync(process.execPath, [copiedScript], {
      encoding: "utf8",
      env: process.env,
    });
    assert.equal(result.status, 2);
    assert.equal(result.stdout, "");
    const failure = JSON.parse(result.stderr.trim());
    assert.equal(failure.schema, "TatwoContractLoopsExecutorErrorV1");
    assert.equal(failure.code, "ledger_file_missing");
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

async function testResolveIssuedBindings() {
  const ledgerValue = canonicalLedgerValue();
  const bindings = resolveContractBoundBindings(ledgerValue);
  assert.deepEqual(bindings.map(binding => binding.route), ["sol", "fable5", "luna", "grok"]);
  assert.deepEqual(bindings.map(binding => binding.identity), ["lead", "supervisor", "sub", "sub"]);
  assert.deepEqual(bindings.map(binding => binding.requestedModel), [
    "gpt-5.6-sol",
    "fable-5",
    "gpt-5.6-luna",
    "grok-build",
  ]);
  assert.deepEqual(bindings.map(binding => binding.requestedEffort), ["low", null, "xhigh", "xhigh"]);
  assert.equal(new Set(bindings.map(binding => binding.bindingID)).size, 4);
  assert.equal(new Set(bindings.map(binding => binding.sourceSlotID)).size, 4);
}

async function testExistingGeneralXXLTopology() {
  const ledgerValue = generalXXLLedgerValue();
  const bindings = resolveContractBoundBindings(ledgerValue);
  assert.deepEqual(bindings.map(binding => binding.route), ["sol", "fable5", "luna", "grok"]);
  assert.deepEqual(bindings.map(binding => binding.sourceSlotID), [
    "general-xxl-plan-lead-sol",
    "general-xxl-loops-supervisor-fable5",
    "general-xxl-loops-sub-luna",
    "general-xxl-loops-sub-grok",
  ]);
  assert.deepEqual(bindings.map(binding => binding.requestedEffort), [
    "low", null, "xhigh", "xhigh",
  ]);
  assert.equal(bindings.find(binding => binding.route === "grok").requiresIsolation, true);
}

async function testAmbiguousAndIncorrectTopologies() {
  {
    const ledgerValue = generalXXLLedgerValue();
    const duplicateGovernor = governorBinding(
      "general-xxl-loops-sub-luna-duplicate",
      "loops",
      "sub",
      "gpt-5.6-luna",
      "xhigh",
    );
    ledgerValue.issuedContract.loopGovernorDecision.activatedBindings.push(
      duplicateGovernor,
    );
    ledgerValue.issuedContract.identityBindings.push({
      id: "issued-binding-luna-duplicate",
      identity: "sub",
      label: "duplicate Luna sub",
      engineID: "codex",
      modelID: "gpt-5.6-luna",
      authority: "brain_only",
      canMutateHost: false,
      sourceSlotID: duplicateGovernor.id,
      bindingRule: "Loop Governor issued binding",
    });
    assert.throws(
      () => resolveContractBoundBindings(ledgerValue),
      error => error.code === "noncanonical_binding_topology",
    );
  }
  {
    const ledgerValue = generalXXLLedgerValue();
    const grok = ledgerValue.issuedContract.loopGovernorDecision.activatedBindings
      .find(binding => binding.id === "general-xxl-loops-sub-grok");
    grok.reasoningEffort = "high";
    assert.throws(
      () => resolveContractBoundBindings(ledgerValue),
      error => error.code === "contract_effort_mismatch"
        && error.message === "contract_effort_mismatch:grok:high",
    );
  }
  {
    const ledgerValue = generalXXLLedgerValue();
    const fable = ledgerValue.issuedContract.identityBindings
      .find(binding => binding.sourceSlotID === "general-xxl-loops-supervisor-fable5");
    fable.modelID = "opus-5";
    assert.throws(
      () => resolveContractBoundBindings(ledgerValue),
      error => error.code === "noncanonical_binding_topology"
        && error.message.includes(":supervisor:opus-5"),
    );
  }
}

async function testCanonicalOrderAndReceipts() {
  const seen = [];
  const runners = successfulRunners({
    onDispatch(dispatch) {
      seen.push({
        stageID: dispatch.stageID,
        identity: dispatch.identity,
        model: dispatch.requestedModel,
        sourceSlotID: dispatch.sourceSlotID,
        priorStages: dispatch.priorReceipts.map(receipt => receipt.stageID),
      });
    },
  });
  const executor = createExecutor({ runners });
  const result = await executor.execute(request());

  assert.deepEqual(seen.map(value => value.stageID), [
    "sol-lead",
    "luna-sub",
    "grok-sub",
    "fable5-review",
    "sol-converge",
  ]);
  assert.deepEqual(seen.map(value => value.identity), ["lead", "sub", "sub", "supervisor", "lead"]);
  assert.deepEqual(seen.map(value => value.model), [
    "gpt-5.6-sol",
    "gpt-5.6-luna",
    "grok-build",
    "fable-5",
    "gpt-5.6-sol",
  ]);
  assert.deepEqual(seen[3].priorStages, ["sol-lead", "luna-sub", "grok-sub"]);
  assert.deepEqual(seen[4].priorStages, ["sol-lead", "luna-sub", "grok-sub", "fable5-review"]);

  assert.equal(result.schema, "TatwoContractLoopsExecutionReceiptV1");
  assert.equal(result.contractID, "contract-xxl-exact-1");
  assert.equal(result.goalID, "goal-xxl-exact-1");
  assert.equal(result.scenario, EXACT_SCENARIO_ID);
  assert.equal(result.receipts.length, 5);
  assert.equal(result.passed, true);
  assert.equal(result.finalOutput, "sol-converge-output");
  assert.deepEqual(result.bindings.map(binding => binding.requestedModel), [
    "gpt-5.6-sol", "fable-5", "gpt-5.6-luna", "grok-build",
  ]);

  for (const receipt of result.receipts) {
    assert.ok(receipt.receiptID);
    assert.equal(receipt.contractID, result.contractID);
    assert.equal(receipt.goalID, result.goalID);
    assert.ok(receipt.bindingID);
    assert.ok(receipt.sourceSlotID);
    assert.ok(receipt.identity);
    assert.ok(receipt.requestedModel);
    assert.ok(receipt.actualModel);
    assert.notEqual(receipt.fallbackCount, null);
    assert.ok(receipt.providerResponseID || receipt.threadID);
    assert.equal(receipt.passed, true);
    assert.deepEqual(
      Object.keys(receipt).filter(key => [
        "requestedEffort", "forwardedEffort", "effectiveEffort",
      ].includes(key)),
      ["requestedEffort", "forwardedEffort", "effectiveEffort"],
    );
  }
  const grok = result.receipts.find(receipt => receipt.stageID === "grok-sub");
  assert.equal(grok.requestedModel, "grok-build");
  assert.equal(grok.actualModel, "grok-4.6");
  assert.equal(grok.isolation.isolated, true);
  assert.deepEqual(grok.isolation.permissionSources, []);
  const fable = result.receipts.find(receipt => receipt.stageID === "fable5-review");
  assert.equal(fable.requestedEffort, null);
  assert.equal(fable.forwardedEffort, null);
  assert.equal(fable.actualModel, "claude-fable-5");
}

async function testCallerSpoofRejected() {
  for (const forbidden of ["identity", "model", "bindingID", "sourceSlotID"]) {
    let ledgerCalls = 0;
    const executor = createContractLoopsExecutor({
      contractLedger: {
        async resolveIssuedContract() {
          ledgerCalls += 1;
          return canonicalLedgerValue();
        },
      },
      runners: successfulRunners(),
    });
    await assert.rejects(
      executor.execute({ ...request(), [forbidden]: "spoof" }),
      error => error.code === "caller_binding_override_forbidden"
        && error.message === `caller_binding_override_forbidden:${forbidden}`,
    );
    assert.equal(ledgerCalls, 0);
  }
}

async function testRunnerIdentityAndModelSpoof() {
  {
    const runners = successfulRunners({
      mutateResult(dispatch, result) {
        return dispatch.stageID === "luna-sub"
          ? { ...result, actualIdentity: "lead" }
          : result;
      },
    });
    const executor = createExecutor({ runners });
    await assert.rejects(
      executor.execute(request("identity-spoof")),
      error => error.code === "identity_spoof_or_missing"
        && error.receipt.stageID === "luna-sub"
        && error.receipt.passed === false,
    );
  }
  {
    const runners = successfulRunners({
      mutateResult(dispatch, result) {
        return dispatch.stageID === "luna-sub"
          ? { ...result, actualModel: "gpt-5.6-terra", actualCanonicalModel: "gpt-5.6-terra" }
          : result;
      },
    });
    const executor = createExecutor({ runners });
    await assert.rejects(
      executor.execute(request("model-spoof")),
      error => error.code === "model_spoof_or_mismatch"
        && error.receipt.requestedModel === "gpt-5.6-luna"
        && error.receipt.actualModel === "gpt-5.6-terra",
    );
  }
  {
    const runners = successfulRunners({
      mutateResult(dispatch, result) {
        return dispatch.stageID === "grok-sub"
          ? {
              ...result,
              actualModel: undefined,
              actualVendorModel: undefined,
              actualCanonicalModel: "grok-build",
            }
          : result;
      },
    });
    const executor = createExecutor({ runners });
    await assert.rejects(
      executor.execute(request("grok-vendor-missing")),
      error => error.code === "model_spoof_or_mismatch"
        && error.receipt.requestedModel === "grok-build"
        && error.receipt.actualModel === null
        && error.receipt.actualCanonicalModel === "grok-build",
    );
  }
}

async function testFableFallbackFailsClosed() {
  const seen = [];
  const runners = successfulRunners({
    onDispatch(dispatch) { seen.push(dispatch.stageID); },
    mutateResult(dispatch, result) {
      return dispatch.stageID === "fable5-review"
        ? {
            ...result,
            actualModel: "claude-opus-5",
            actualCanonicalModel: "opus-5",
            fallbackCount: 1,
          }
        : result;
    },
  });
  const executor = createExecutor({ runners });
  await assert.rejects(
    executor.execute(request("fable-fallback")),
    error => error.code === "fable5_fallback_fail_closed"
      && error.receipt.actualModel === "claude-opus-5"
      && error.receipt.fallbackCount === 1,
  );
  assert.deepEqual(seen, ["sol-lead", "luna-sub", "grok-sub", "fable5-review"]);
}

async function testEffortAndIsolationFailClosed() {
  {
    const runners = successfulRunners({
      mutateResult(dispatch, result) {
        return dispatch.stageID === "grok-sub"
          ? { ...result, effectiveEffort: "high", effectiveEffortAttested: false }
          : result;
      },
    });
    const executor = createExecutor({ runners });
    await assert.rejects(
      executor.execute(request("unsupported-effort")),
      error => error.code === "effort_not_effective_or_unattested"
        && error.receipt.requestedEffort === "xhigh"
        && error.receipt.effectiveEffort === "high",
    );
  }
  {
    const runners = successfulRunners({
      mutateResult(dispatch, result) {
        return dispatch.stageID === "grok-sub"
          ? {
              ...result,
              isolation: {
                isolated: false,
                launcher: "grok-raw",
                permissionSources: ["~/.claude/CLAUDE.md"],
              },
            }
          : result;
      },
    });
    const executor = createExecutor({ runners });
    await assert.rejects(
      executor.execute(request("isolation-spoof")),
      error => error.code === "grok_isolation_unverified"
        && error.receipt.stageID === "grok-sub",
    );
  }
}

async function testExactlyOnceFinalize() {
  const calls = [];
  const journal = createMemoryExecutionJournal();
  const firstExecutor = createExecutor({
    journal,
    runners: successfulRunners({ onDispatch(dispatch) { calls.push(dispatch.stageID); } }),
  });
  const first = await firstExecutor.execute(request("exactly-once"));
  const secondExecutor = createExecutor({
    journal,
    runners: successfulRunners({ onDispatch(dispatch) { calls.push(`unexpected:${dispatch.stageID}`); } }),
  });
  const second = await secondExecutor.execute(request("exactly-once"));

  assert.deepEqual(second, first);
  assert.deepEqual(calls, ["sol-lead", "luna-sub", "grok-sub", "fable5-review", "sol-converge"]);
  assert.equal(journal.finalizeCount, 1);
}

async function testCancelReconnectResume() {
  const controller = new AbortController();
  const journal = createMemoryExecutionJournal();
  const calls = [];
  const firstExecutor = createExecutor({
    journal,
    runners: successfulRunners({
      onDispatch(dispatch) {
        calls.push(`first:${dispatch.stageID}`);
        if (dispatch.stageID === "sol-lead") controller.abort();
      },
    }),
  });
  await assert.rejects(
    firstExecutor.execute(request("resume"), { signal: controller.signal }),
    error => error.code === "execution_cancelled"
      && error.resumable === true
      && error.partialReceipts.length === 1
      && error.partialReceipts[0].stageID === "sol-lead",
  );
  assert.equal(journal.finalizeCount, 0);

  const resumedExecutor = createExecutor({
    journal,
    runners: successfulRunners({ onDispatch(dispatch) { calls.push(`resume:${dispatch.stageID}`); } }),
  });
  const result = await resumedExecutor.execute(request("resume"));
  assert.equal(result.passed, true);
  assert.equal(journal.finalizeCount, 1);
  assert.deepEqual(calls, [
    "first:sol-lead",
    "resume:luna-sub",
    "resume:grok-sub",
    "resume:fable5-review",
    "resume:sol-converge",
  ]);
}

function createExecutor({ runners, journal } = {}) {
  return createContractLoopsExecutor({
    contractLedger: createMemoryContractLedger(canonicalLedgerValue()),
    runners: runners ?? successfulRunners(),
    journal,
    clock: () => "2026-08-03T02:00:00.000Z",
  });
}

function request(input = "Build the bounded contract goal") {
  return {
    contractID: "contract-xxl-exact-1",
    goalID: "goal-xxl-exact-1",
    input,
  };
}

function canonicalLedgerValue() {
  return ledgerValueForTopology({
    contractID: "contract-xxl-exact-1",
    goalID: "goal-xxl-exact-1",
    scenario: EXACT_SCENARIO_ID,
    objective: "canonical exact mixed adapters",
    sourceSlots: [
      "general-xxl-exact-plan-lead-sol",
      "general-xxl-exact-loops-supervisor-fable5",
      "general-xxl-exact-loops-sub-luna",
      "general-xxl-exact-loops-sub-grok",
    ],
  });
}

function generalXXLLedgerValue() {
  return ledgerValueForTopology({
    contractID: "contract-xxl-general-issued-1",
    goalID: "goal-xxl-general-issued-1",
    scenario: "custom-copy-general-xxl-fable5-sol-issued",
    objective: "existing issued general XXL mixed adapters",
    sourceSlots: [
      "general-xxl-plan-lead-sol",
      "general-xxl-loops-supervisor-fable5",
      "general-xxl-loops-sub-luna",
      "general-xxl-loops-sub-grok",
    ],
  });
}

function ledgerValueForTopology({
  contractID,
  goalID,
  scenario,
  objective,
  sourceSlots,
}) {
  const activatedBindings = [
    governorBinding(sourceSlots[0], "plan", "主導", "gpt-5.6-sol", "low"),
    governorBinding(sourceSlots[1], "loops", "副審", "fable-5", null),
    governorBinding(sourceSlots[2], "loops", "sub", "gpt-5.6-luna", "xhigh"),
    governorBinding(sourceSlots[3], "loops", "sub", "grok-build", "xhigh"),
  ];
  const identityBindings = activatedBindings.map((binding, index) => ({
    id: `issued-binding-${index}`,
    identity: binding.identity === "主導" ? "lead" : binding.identity === "副審" ? "supervisor" : "sub",
    label: `${binding.phase} ${binding.identity}`,
    engineID: binding.boundModelIDs[0].startsWith("gpt-") ? "codex" : binding.boundModelIDs[0] === "fable-5" ? "claude_cli" : "grok",
    modelID: binding.boundModelIDs[0],
    authority: "brain_only",
    canMutateHost: false,
    sourceSlotID: binding.id,
    bindingRule: "Loop Governor issued binding",
  }));
  const issuedContract = {
    schema: "TatwoWorkOSContractV1",
    goalID,
    contractID,
    mode: "XXL",
    scenario,
    objective,
    loopGovernorDecision: {
      schema: "TatwoLoopGovernorDecisionV1",
      scenarioID: scenario,
      mode: "XXL",
      activatedBindings,
    },
    identityBindings,
  };
  return {
    schema: "TatwoIssuedContractLedgerEntryV1",
    goalID: issuedContract.goalID,
    contractID: issuedContract.contractID,
    issuedContract,
  };
}

function governorBinding(id, phase, identity, modelID, reasoningEffort) {
  return {
    id,
    phase,
    identity,
    boundModelIDs: [modelID],
    dynamicActivation: identity === "sub" ? "allowed" : "always",
    enabled: true,
    reasoningEffort,
  };
}

function successfulRunners({ onDispatch, mutateResult } = {}) {
  const runner = async dispatch => {
    onDispatch?.(dispatch);
    let result = successfulResult(dispatch);
    result = mutateResult?.(dispatch, result) ?? result;
    return result;
  };
  return {
    "codex-exec": runner,
    "gateway-direct": runner,
  };
}

function successfulResult(dispatch) {
  const isGateway = dispatch.adapter === "gateway-direct";
  const actualModel = dispatch.requestedModel === "fable-5"
    ? "claude-fable-5"
    : dispatch.requestedModel === "grok-build"
      ? "grok-4.6"
      : dispatch.requestedModel;
  return {
    ok: true,
    actualIdentity: dispatch.identity,
    actualBindingID: dispatch.bindingID,
    actualSourceSlotID: dispatch.sourceSlotID,
    actualModel,
    actualCanonicalModel: dispatch.requestedModel,
    forwardedEffort: dispatch.requestedEffort,
    effectiveEffort: dispatch.requestedEffort,
    effectiveEffortAttested: dispatch.requestedEffort !== null,
    forwardedServiceTier: dispatch.serviceTier,
    effectiveServiceTier: dispatch.serviceTier,
    fallbackCount: 0,
    providerResponseID: isGateway ? `response-${dispatch.stageID}` : null,
    threadID: isGateway ? null : `thread-${dispatch.stageID}`,
    providerReceiptID: `provider-receipt-${dispatch.stageID}`,
    output: `${dispatch.stageID}-output`,
    isolation: dispatch.requestedModel === "grok-build"
      ? {
          isolated: true,
          launcher: "/tmp/tatwo2-fixture/.codex/bin/grok-isolated",
          permissionSources: [],
        }
      : null,
  };
}
