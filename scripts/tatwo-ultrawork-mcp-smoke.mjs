#!/usr/bin/env node
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import { fileURLToPath } from "node:url";
import path from "node:path";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const serverPath = path.join(scriptDir, "tatwo-ultrawork-mcp.mjs");
const smokeConfigDir = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-mcp-scenario-config-"));
const smokeScenarioConfigPath = path.join(smokeConfigDir, "scenario-config.json");
const smokeSandboxRoot = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-mcp-sandbox-root-"));
const smokeStateDir = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-mcp-state-"));
const child = spawn("node", [serverPath], {
  cwd: path.resolve(scriptDir, ".."),
  env: {
    ...process.env,
    TATWO_ULTRAWORK_SCENARIO_CONFIG_PATH: smokeScenarioConfigPath,
    TATWO_ULTRAWORK_STATE_DIR: smokeStateDir,
    TATWO_ULTRAWORK_SANDBOX_ROOT: smokeSandboxRoot
  },
  stdio: ["pipe", "pipe", "pipe"]
});

let buffer = Buffer.alloc(0);
let nextID = 1;
const pending = new Map();
let stderr = "";

child.stderr.on("data", chunk => {
  stderr += chunk.toString("utf8");
});

child.stdout.on("data", chunk => {
  buffer = Buffer.concat([buffer, chunk]);
  drain();
});

child.on("exit", code => {
  if (pending.size > 0) {
    fail(`MCP server exited early with ${code}: ${stderr}`);
  }
});

try {
  const serverSource = fs.readFileSync(serverPath, "utf8");
  const privateVolumePrefix = ["", "Volumes", "Layer2"].join("/");
  assert(!serverSource.includes(privateVolumePrefix), "MCP server source must not hard-code private local volume paths");

  const init = await request("initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "tatwo-smoke", version: "0.1.0" }
  });
  assert(init.serverInfo?.name === "tatwo-ultrawork", "initialize returned wrong server name");

  const listed = await request("tools/list", {});
  const toolNames = new Set((listed.tools ?? []).map(t => t.name));
  for (const required of ["tatwo_os_begin", "tatwo_os_next", "tatwo_os_loop_status", "tatwo_os_receipt_submit", "tatwo_os_goal_close", "tatwo_os_dispatch_finalize", "tatwo_os_dispatch_advance", "tatwo_os_dashboard", "tatwo_os_enforce", "tatwo_os_handoff", "tatwo_os_constitution", "tatwo_scenario_config", "tatwo_scenario_config_add", "tatwo_scenario_config_duplicate", "tatwo_scenario_config_rename", "tatwo_scenario_config_delete", "tatwo_scenario_config_update_token_budget", "tatwo_scenario_config_set_binding_models", "tatwo_scenario_config_binding_resp", "tatwo_gateway_status", "tatwo_gateway_models", "tatwo_gateway_dispatch", "tatwo_gateway_fanout", "tatwo_web_arena_plan", "tatwo_web_arena_cleanup_plan", "tatwo_sandbox_arena_list", "tatwo_sandbox_arena_plan", "tatwo_sandbox_arena_report", "tatwo_arena_plan_loop_goal_policy", "tatwo_arena_plan_loop_goal_score", "tatwo_arena_goal_cycle_assess", "tatwo_web_check_preflight", "tatwo_web_check_plan", "tatwo_web_check_import_receipt", "tatwo_web_check_receipt_template", "tatwo_app_mcp_manifest", "tatwo_mcp_client_config", "tatwo_engine_capabilities", "tatwo_workflow_run", "tatwo_handoff_pack", "tatwo_install_plan", "tatwo_sandbox_preflight", "tatwo_sandbox_begin", "tatwo_sandbox_write_artifact", "tatwo_sandbox_run_command", "tatwo_sandbox_receipt", "tatwo_sandbox_promote_plan", "tatwo_colima_preflight", "tatwo_colima_run", "tatwo_host_preflight", "tatwo_host_backup_plan", "tatwo_host_live_smoke_plan", "tatwo_host_receipt_flow", "tatwo_host_sandbox_rehearsal", "tatwo_host_install_gate", "tatwo_host_verified_install_gate", "tatwo_m2_entry_gate", "tatwo_host_install_runway", "tatwo_host_promotion_plan", "tatwo_route_risk_dashboard", "tatwo_route_smoke_plan", "tatwo_route_live_smoke_receipts", "tatwo_state_export", "tatwo_memory_add", "tatwo_model_traits", "tatwo_team_recommend", "tatwo_team_dashboard", "tatwo_integration_plan", "tatwo_stability_plan", "tatwo_codex_disconnect_guard", "tatwo_objective_audit", "tatwo_objective_adversarial", "tatwo_validate_operational_sample", "tatwo_validate_operational_receipt"]) {
    assert(toolNames.has(required), `missing tool ${required}`);
  }

  const configGateBeginCall = await request("tools/call", {
    name: "tatwo_os_begin",
    arguments: { mode: "M", scenario: "coding", objective: "mcp smoke scenario config gate" }
  });
  const configGateBeginText = configGateBeginCall.content?.[0]?.text ?? "";
  const configGateContractID = configGateBeginText.match(/"contractID"\s*:\s*"([^"]+)"/)?.[1];
  assert(configGateContractID, "scenario config mutation gate must start from a registered Work OS contract");

  const configAddCall = await request("tools/call", {
    name: "tatwo_scenario_config_add",
    arguments: { contractID: configGateContractID, displayName: "MCP Smoke UI", baseScenario: "design" }
  });
  const configAddText = configAddCall.content?.[0]?.text ?? "";
  assert(configAddText.includes("TatwoScenarioConfigMutationResultV1"), "scenario config add did not return mutation schema");
  const addedScenarioID = configAddText.match(/"scenarioID"\s*:\s*"([^"]+)"/)?.[1];
  assert(addedScenarioID, "scenario config add must return scenarioID");

  const configBudgetCall = await request("tools/call", {
    name: "tatwo_scenario_config_update_token_budget",
    arguments: { contractID: configGateContractID, scenarioID: addedScenarioID, mode: "M", tokenBudget: "MCP smoke budget: token gate only" }
  });
  const configBudgetText = configBudgetCall.content?.[0]?.text ?? "";
  assert(configBudgetText.includes("MCP smoke budget"), "scenario config budget update did not persist label");

  const configBindCall = await request("tools/call", {
    name: "tatwo_scenario_config_set_binding_models",
    arguments: { contractID: configGateContractID, scenarioID: addedScenarioID, mode: "M", bindingID: "daily-m-loops-supervisor", modelIDs: ["sonnet-5", "gpt-5.4"] }
  });
  const configBindText = configBindCall.content?.[0]?.text ?? "";
  assert(configBindText.includes("sonnet-5") && configBindText.includes("gpt-5.4"), "scenario config model binding did not persist models");

  const configResponsibilityCall = await request("tools/call", {
    name: "tatwo_scenario_config_binding_resp",
    arguments: { contractID: configGateContractID, scenarioID: addedScenarioID, mode: "M", bindingID: "daily-m-loops-supervisor", responsibility: "MCP smoke reviewer owns loop drift checks." }
  });
  const configResponsibilityText = configResponsibilityCall.content?.[0]?.text ?? "";
  assert(configResponsibilityText.includes("MCP smoke reviewer owns loop drift checks"), "scenario config responsibility update did not persist text");

  const configReadCall = await request("tools/call", {
    name: "tatwo_scenario_config",
    arguments: {}
  });
  const configReadText = configReadCall.content?.[0]?.text ?? "";
  assert(configReadText.includes(addedScenarioID), "scenario config read should include the added custom scenario");

  const osBeginCall = await request("tools/call", {
    name: "tatwo_os_begin",
    arguments: { mode: "M", scenario: addedScenarioID, objective: "mcp smoke work os" }
  });
  const osBeginText = osBeginCall.content?.[0]?.text ?? "";
  assert(osBeginText.includes("TatwoWorkOSContractV1"), "Work OS begin did not return contract schema");
  assert(osBeginText.includes("contractID"), "Work OS begin must return contractID");
  assert(osBeginText.includes("MCP smoke reviewer owns loop drift checks"), "Work OS begin must read the same staging scenario config as MCP mutations");
  const contractID = osBeginText.match(/"contractID"\s*:\s*"([^"]+)"/)?.[1];
  assert(contractID, "Work OS begin must expose parseable contractID");

  const gatewayDottedDryRunCall = await request("tools/call", {
    name: "tatwo.gateway.dispatch",
    arguments: {
      contractID,
      model: "minimax-m3",
      prompt: "Dotted alias smoke: return a short review note.",
      dryRun: true
    }
  });
  const gatewayDottedDryRunText = gatewayDottedDryRunCall.content?.[0]?.text ?? "";
  assert(gatewayDottedDryRunText.includes("TatwoGatewayDispatchReceiptV1"), "dotted gateway dispatch alias must work");
  assert(gatewayDottedDryRunText.includes('"hostMutationAllowed"'), "gateway dispatch must keep hostMutationAllowed receipt");

  const gateway56DryRunCall = await request("tools/call", {
    name: "tatwo.gateway.dispatch",
    arguments: {
      contractID,
      model: "gpt56-sol",
      prompt: "Canonical gateway 5.6 route smoke.",
      dryRun: true
    }
  });
  const gateway56DryRunText = gateway56DryRunCall.content?.[0]?.text ?? "";
  assert(gateway56DryRunText.includes('"model": "gpt-5.6-sol"') || gateway56DryRunText.includes('"model":"gpt-5.6-sol"'),
    "gateway 5.6 alias must normalize to canonical gpt-5.6-sol");

  const osDashboardCall = await request("tools/call", {
    name: "tatwo_os_dashboard",
    arguments: { mode: "XL", scenario: "ui-ux", objective: "mcp smoke work os" }
  });
  const osDashboardText = osDashboardCall.content?.[0]?.text ?? "";
  assert(osDashboardText.includes("TatwoWorkOSDashboardSnapshotV1"), "Work OS dashboard did not return dashboard schema");
  assert(osDashboardText.includes('"readOnly" : true') || osDashboardText.includes('"readOnly": true'), "Work OS dashboard must be read-only");
  assert(osDashboardText.includes("READY") && osDashboardText.includes("ROLLBACK"), "Work OS dashboard must show READY/ROLLBACK");

  const osEnforceCall = await request("tools/call", {
    name: "tatwo_os_enforce",
    arguments: { mode: "M", scenario: addedScenarioID, objective: "mcp smoke work os", contractID, toolName: "tatwo.os.next" }
  });
  const osEnforceText = osEnforceCall.content?.[0]?.text ?? "";
  assert(osEnforceText.includes("TatwoWorkOSEnforcementDecisionV1"), "Work OS enforce did not return decision schema");
  assert(osEnforceText.includes("os_action_allowed"), "Work OS enforce should allow registered read-only tool");

  const osHandoffCall = await request("tools/call", {
    name: "tatwo_os_handoff",
    arguments: { mode: "XL", scenario: "ui-ux", objective: "mcp smoke handoff" }
  });
  const osHandoffText = osHandoffCall.content?.[0]?.text ?? "";
  assert(osHandoffText.includes("TatwoWorkOSHandoffPackV1"), "Work OS handoff did not return handoff schema");
  assert(osHandoffText.includes("AGENTS.md") && osHandoffText.includes("RECEIPTS.md"), "Work OS handoff must include agents/tools/receipts guidance");

  const osConstitutionCall = await request("tools/call", {
    name: "tatwo_os_constitution",
    arguments: {}
  });
  const osConstitutionText = osConstitutionCall.content?.[0]?.text ?? "";
  assert(osConstitutionText.includes("TatwoWorkOSConstitutionV1"), "Work OS constitution did not return constitution schema");

  const osMissingReceiptCall = await request("tools/call", {
    name: "tatwo_os_receipt_submit",
    arguments: { goal: "missing-contract-smoke", receipt: "smoke", kind: "test" }
  });
  const osMissingReceiptText = osMissingReceiptCall.content?.[0]?.text ?? "";
  assert(osMissingReceiptText.includes("missing_contract_id"), "Work OS receipt submit must fail closed without contractID");

  const sandboxNoContractCall = await request("tools/call", {
    name: "tatwo_sandbox_begin",
    arguments: { objective: "must fail without contract" }
  });
  const sandboxNoContractText = sandboxNoContractCall.content?.[0]?.text ?? "";
  assert(sandboxNoContractCall.isError === true, "sandbox begin must return MCP isError when contractID is missing");
  assert(sandboxNoContractText.includes("missing contractID"), "sandbox begin must fail closed without contractID");

  const sandboxBeginCall = await request("tools/call", {
    name: "tatwo_sandbox_begin",
    arguments: {
      contractID,
      goalID: "goal-mcp-smoke-sandbox",
      mode: "M",
      scenario: addedScenarioID,
      objective: "mcp smoke sandbox write and command"
    }
  });
  const sandboxBeginText = sandboxBeginCall.content?.[0]?.text ?? "";
  const sandboxBeginDoc = parseFirstJSON(sandboxBeginText);
  assert(sandboxBeginDoc?.schema === "TatwoSandboxSessionReceiptV1", "sandbox begin did not return sandbox session schema");
  assert(sandboxBeginDoc.hostMutationAllowed === false, "sandbox begin must not allow host mutation");
  assert(sandboxBeginDoc.sandboxWriteAllowed === true, "sandbox begin must allow scoped sandbox write");
  assert(sandboxBeginDoc.sandboxID, "sandbox begin must return sandboxID");

  const sandboxDottedBeginCall = await request("tools/call", {
    name: "tatwo.sandbox.begin",
    arguments: {
      contractID,
      goalID: "goal-mcp-smoke-sandbox-dotted",
      objective: "mcp smoke dotted sandbox alias"
    }
  });
  const sandboxDottedBeginText = sandboxDottedBeginCall.content?.[0]?.text ?? "";
  const sandboxDottedBeginDoc = parseFirstJSON(sandboxDottedBeginText);
  assert(sandboxDottedBeginDoc?.schema === "TatwoSandboxSessionReceiptV1", "dotted sandbox begin alias must work");
  assert(sandboxDottedBeginDoc.hostMutationAllowed === false, "dotted sandbox begin must not allow host mutation");

  const sandboxEscapeCall = await request("tools/call", {
    name: "tatwo_sandbox_write_artifact",
    arguments: {
      contractID,
      sandboxID: sandboxBeginDoc.sandboxID,
      relativePath: "../escape.txt",
      content: "bad"
    }
  });
  const sandboxEscapeText = sandboxEscapeCall.content?.[0]?.text ?? "";
  assert(sandboxEscapeCall.isError === true, "sandbox write must return isError for path escape");
  assert(sandboxEscapeText.includes("path escapes sandbox") || sandboxEscapeText.includes("absolute/parent path"), "sandbox write must explain path escape");

  const sandboxWriteCall = await request("tools/call", {
    name: "tatwo_sandbox_write_artifact",
    arguments: {
      contractID,
      sandboxID: sandboxBeginDoc.sandboxID,
      relativePath: "generated-artifacts/hello.js",
      content: "console.log('OK_TATWO_SANDBOX_WRITE')\n"
    }
  });
  const sandboxWriteText = sandboxWriteCall.content?.[0]?.text ?? "";
  const sandboxWriteDoc = parseFirstJSON(sandboxWriteText);
  assert(sandboxWriteDoc?.schema === "TatwoSandboxArtifactReceiptV1", "sandbox write did not return artifact receipt schema");
  assert(sandboxWriteDoc.relativePath === "generated-artifacts/hello.js", "sandbox write should preserve relative path");
  assert(sandboxWriteDoc.sha256, "sandbox write must hash artifact");

  const sandboxOverwriteCall = await request("tools/call", {
    name: "tatwo_sandbox_write_artifact",
    arguments: {
      contractID,
      sandboxID: sandboxBeginDoc.sandboxID,
      relativePath: "generated-artifacts/hello.js",
      content: "console.log('OK_TATWO_SANDBOX_OVERWRITE')\n"
    }
  });
  const sandboxOverwriteText = sandboxOverwriteCall.content?.[0]?.text ?? "";
  const sandboxOverwriteDoc = parseFirstJSON(sandboxOverwriteText);
  assert(sandboxOverwriteDoc?.schema === "TatwoSandboxArtifactReceiptV1", "sandbox overwrite did not return artifact receipt schema");
  assert(sandboxOverwriteDoc.relativePath === "generated-artifacts/hello.js", "sandbox overwrite should preserve relative path");
  assert(sandboxOverwriteDoc.sha256 !== sandboxWriteDoc.sha256, "sandbox overwrite must record a new current hash");

  const sandboxRunCall = await request("tools/call", {
    name: "tatwo_sandbox_run_command",
    arguments: {
      contractID,
      sandboxID: sandboxBeginDoc.sandboxID,
      command: "node",
      args: ["generated-artifacts/hello.js"],
      timeoutMS: 10000
    }
  });
  const sandboxRunText = sandboxRunCall.content?.[0]?.text ?? "";
  const sandboxRunDoc = parseFirstJSON(sandboxRunText);
  assert(sandboxRunDoc?.schema === "TatwoSandboxCommandReceiptV1", "sandbox run did not return command receipt schema");
  assert(sandboxRunDoc.ok === true, "sandbox run should pass node smoke");
  assert(sandboxRunDoc.stdout.includes("OK_TATWO_SANDBOX_OVERWRITE"), "sandbox run should execute the latest artifact version");
  assert(sandboxRunDoc.hostMutationAllowed === false, "sandbox run must not allow host mutation");

  const sandboxReceiptCall = await request("tools/call", {
    name: "tatwo_sandbox_receipt",
    arguments: { contractID, sandboxID: sandboxBeginDoc.sandboxID }
  });
  const sandboxReceiptText = sandboxReceiptCall.content?.[0]?.text ?? "";
  const sandboxReceiptDoc = parseFirstJSON(sandboxReceiptText);
  assert(sandboxReceiptDoc?.schema === "TatwoSandboxReceiptBundleV1", "sandbox receipt did not return bundle schema");
  assert(sandboxReceiptDoc.ok === true, "sandbox receipt must accept the latest version of an overwritten artifact");
  assert(sandboxReceiptDoc.status === "ready_for_review", "sandbox receipt must be ready when current hashes match");
  assert(sandboxReceiptDoc.artifactCount === 2, "sandbox receipt must preserve the legacy artifact history count");
  assert(sandboxReceiptDoc.artifactHistoryCount === 2, "sandbox receipt must preserve both artifact history entries");
  assert(sandboxReceiptDoc.currentArtifactCount === 1, "sandbox receipt must report one current artifact");
  assert(sandboxReceiptDoc.supersededArtifactCount === 1, "sandbox receipt must report one superseded artifact");
  assert(sandboxReceiptDoc.malformedArtifactCount === 0, "sandbox receipt must report no malformed artifacts");
  assert(sandboxReceiptDoc.artifacts[0]?.sha256 === sandboxOverwriteDoc.sha256, "sandbox receipt must verify the latest artifact hash");
  assert(sandboxReceiptDoc.supersededReceiptIDs.includes(sandboxWriteDoc.receiptID), "sandbox receipt must retain the superseded receipt ID");
  assert(sandboxReceiptDoc.commandCount >= 1, "sandbox receipt must include command count");

  const sandboxArtifactPath = path.join(
    smokeSandboxRoot,
    sandboxBeginDoc.sandboxID,
    "generated-artifacts",
    "hello.js"
  );
  fs.writeFileSync(sandboxArtifactPath, "console.log('TAMPERED')\n", "utf8");
  const sandboxTamperReceiptCall = await request("tools/call", {
    name: "tatwo_sandbox_receipt",
    arguments: { contractID, sandboxID: sandboxBeginDoc.sandboxID }
  });
  const sandboxTamperReceiptText = sandboxTamperReceiptCall.content?.[0]?.text ?? "";
  const sandboxTamperReceiptDoc = parseFirstJSON(sandboxTamperReceiptText);
  assert(sandboxTamperReceiptDoc?.schema === "TatwoSandboxReceiptBundleV1", "tampered sandbox receipt did not return bundle schema");
  assert(sandboxTamperReceiptDoc.ok === false, "tampered current artifact must fail closed");
  assert(sandboxTamperReceiptDoc.status === "artifact_mismatch", "tampered current artifact must report artifact_mismatch");
  assert(sandboxTamperReceiptDoc.artifacts[0]?.hashMatches === false, "tampered current artifact must expose hash mismatch");

  fs.writeFileSync(sandboxArtifactPath, "console.log('OK_TATWO_SANDBOX_OVERWRITE')\n", "utf8");
  const sandboxManifestPath = path.join(smokeSandboxRoot, sandboxBeginDoc.sandboxID, ".tatwo-sandbox-manifest.json");
  const sandboxManifest = JSON.parse(fs.readFileSync(sandboxManifestPath, "utf8"));
  sandboxManifest.artifacts.push({
    sha256: sandboxOverwriteDoc.sha256,
    receiptID: "malformed-artifact-smoke"
  });
  fs.writeFileSync(sandboxManifestPath, `${JSON.stringify(sandboxManifest, null, 2)}\n`, "utf8");
  const sandboxMalformedReceiptCall = await request("tools/call", {
    name: "tatwo_sandbox_receipt",
    arguments: { contractID, sandboxID: sandboxBeginDoc.sandboxID }
  });
  const sandboxMalformedReceiptText = sandboxMalformedReceiptCall.content?.[0]?.text ?? "";
  const sandboxMalformedReceiptDoc = parseFirstJSON(sandboxMalformedReceiptText);
  assert(sandboxMalformedReceiptDoc?.schema === "TatwoSandboxReceiptBundleV1", "malformed sandbox receipt did not return bundle schema");
  assert(sandboxMalformedReceiptDoc.ok === false, "malformed artifact history must fail closed");
  assert(sandboxMalformedReceiptDoc.malformedArtifactCount === 1, "malformed artifact history must be counted");
  assert(sandboxMalformedReceiptDoc.malformedArtifacts[0]?.reason.includes("missing relativePath"), "malformed artifact history must explain the invalid entry");

  const sandboxPromoteCall = await request("tools/call", {
    name: "tatwo_sandbox_promote_plan",
    arguments: { contractID, sandboxID: sandboxBeginDoc.sandboxID, targetHint: "host project" }
  });
  const sandboxPromoteText = sandboxPromoteCall.content?.[0]?.text ?? "";
  const sandboxPromoteDoc = parseFirstJSON(sandboxPromoteText);
  assert(sandboxPromoteDoc?.schema === "TatwoSandboxPromotePlanV1", "sandbox promote plan did not return promote schema");
  assert(sandboxPromoteDoc.hostMutationAllowed === false, "sandbox promote plan must not mutate host");
  assert(sandboxPromoteDoc.promoteAllowed === false, "sandbox promote plan must be a plan, not direct promotion");
  assert(sandboxPromoteText.includes("human gate") || sandboxPromoteText.includes("人工"), "sandbox promote plan must require human gate");

  const webArenaPlanCall = await request("tools/call", {
    name: "tatwo_web_arena_plan",
    arguments: { suite: "v1", models: "gpt-5.5,sonnet-5,fable-5" }
  });
  const webArenaPlanText = webArenaPlanCall.content?.[0]?.text ?? "";
  assert(webArenaPlanText.includes("TatwoWebArenaPlanV1"), "web arena plan did not return schema");
  assert(webArenaPlanText.includes("網頁設計沙盒"), "web arena plan should show sandbox root");

  const sandboxArenaPlanCall = await request("tools/call", {
    name: "tatwo_sandbox_arena_plan",
    arguments: { arena: "all", models: "gpt-5.5,sonnet-5,fable-5" }
  });
  const sandboxArenaPlanText = sandboxArenaPlanCall.content?.[0]?.text ?? "";
  assert(sandboxArenaPlanText.includes("TatwoSandboxArenaCollectionPlanV1"), "sandbox arena plan did not return collection schema");
  assert(sandboxArenaPlanText.includes("代碼架構沙盒"), "sandbox arena plan should include code architecture arena");
  assert(sandboxArenaPlanText.includes("Debug沙盒"), "sandbox arena plan should include debug arena");
  assert(sandboxArenaPlanText.includes("文筆溝通沙盒"), "sandbox arena plan should include writing arena");
  assert(sandboxArenaPlanText.includes("3d-modeling"), "sandbox arena plan should include 3D modeling arena");

  const plgPolicyCall = await request("tools/call", {
    name: "tatwo_arena_plan_loop_goal_policy",
    arguments: {}
  });
  const plgPolicyText = plgPolicyCall.content?.[0]?.text ?? "";
  assert(plgPolicyText.includes("plan+loops+goal-主線"), "PLG policy should expose mainline protocol");
  assert(plgPolicyText.includes("tool-choice-ledger"), "PLG policy should require tool choice ledger");

  const plgScoreBlockedCall = await request("tools/call", {
    name: "tatwo_arena_plan_loop_goal_score",
    arguments: {
      modelSlug: "gpt-5.5",
      expectedSandboxTests: 3,
      completedSandboxTests: 2,
      goalExecutionCycles: 5,
      finalSubmissionSealed: true,
      presentArtifacts: "goal-contract.md,plan.md,loop-ledger.json,mainline-decision.md,final-submission/seal.json,branch-optimization-plan.md,branch-loop-ledger.json,tool-choice-ledger.json,receipt-index.json",
      toolChoicesAllRegistered: true
    }
  });
  const plgScoreBlockedText = plgScoreBlockedCall.content?.[0]?.text ?? "";
  assert(plgScoreBlockedText.includes("sandbox_tests_incomplete_plg_score_blocked"), "PLG score must wait for all sandbox tests");

  const plgScoreReadyCall = await request("tools/call", {
    name: "tatwo_arena_plan_loop_goal_score",
    arguments: {
      modelSlug: "gpt-5.5",
      expectedSandboxTests: 3,
      completedSandboxTests: 3,
      goalExecutionCycles: 5,
      finalSubmissionSealed: true,
      presentArtifacts: "goal-contract.md,plan.md,loop-ledger.json,mainline-decision.md,final-submission/seal.json,branch-optimization-plan.md,branch-loop-ledger.json,tool-choice-ledger.json,receipt-index.json",
      toolChoicesAllRegistered: true
    }
  });
  const plgScoreReadyText = plgScoreReadyCall.content?.[0]?.text ?? "";
  assert(plgScoreReadyText.includes("all_sandbox_tests_complete_score_plg"), "PLG score should run after all sandbox tests");
  assert(plgScoreReadyText.includes("caller_asserted_not_deterministic_receipt"), "PLG score must label caller-asserted inputs");
  assert(plgScoreReadyText.includes("\"scoreUsableAsGateEvidence\" : false"), "caller-asserted PLG score cannot be gate evidence");

  const goalCycleCall = await request("tools/call", {
    name: "tatwo_arena_goal_cycle_assess",
    arguments: { goalExecutionCycles: 5 }
  });
  const goalCycleText = goalCycleCall.content?.[0]?.text ?? "";
  assert(goalCycleText.includes("goal_cycle_cap_reached_enter_grading"), "5 cycles must enter grading");

  const webCheckPlanCall = await request("tools/call", {
    name: "tatwo_web_check_plan",
    arguments: { mode: "L", scenario: "ui-ux", target: "/tmp/example-ui" }
  });
  const webCheckPlanText = webCheckPlanCall.content?.[0]?.text ?? "";
  assert(webCheckPlanText.includes("TatwoWebCheckPlanV1"), "web-check plan did not return schema");
  assert(webCheckPlanText.includes("web-check"), "web-check plan should describe receipt source");

  const webCheckTemplateCall = await request("tools/call", {
    name: "tatwo_web_check_receipt_template",
    arguments: { contractID: "contract-l-ui-ux-abcdef123456" }
  });
  const webCheckTemplateText = webCheckTemplateCall.content?.[0]?.text ?? "";
  assert(webCheckTemplateText.includes("TatwoWebCheckReceiptV1"), "web-check receipt template did not return schema");
  assert(webCheckTemplateText.includes("externalUploadAvoided"), "web-check receipt must include upload avoidance flag");

  const manifestCall = await request("tools/call", {
    name: "tatwo_app_mcp_manifest",
    arguments: {}
  });
  const manifestText = manifestCall.content?.[0]?.text ?? "";
  assert(manifestText.includes("TatwoMCPServerManifestV1"), "app MCP manifest did not return schema");
  assert(manifestText.includes("\"engineAgnostic\" : true"), "app MCP manifest must be engine agnostic");
  assert(manifestText.includes("highest-fit host") || manifestText.includes("最高適配"), "manifest must explain Codex is host-fit, not the only engine");

  const clientConfigCall = await request("tools/call", {
    name: "tatwo_mcp_client_config",
    arguments: { engine: "claude-cli" }
  });
  const clientConfigText = clientConfigCall.content?.[0]?.text ?? "";
  assert(clientConfigText.includes("TatwoMCPClientConfigV1"), "client config did not return schema");
  assert(clientConfigText.includes("\"codexRequired\" : false"), "CLI/MCP client config must not require Codex");
  assert(clientConfigText.includes("tatwo-ultrawork mcp call"), "client config must include CLI fallback");

  const engineCall = await request("tools/call", {
    name: "tatwo_engine_capabilities",
    arguments: { engine: "codex" }
  });
  const engineText = engineCall.content?.[0]?.text ?? "";
  assert(engineText.includes("Codex App"), "engine capabilities should return Codex adapter");
  assert(engineText.includes("hostFitScore"), "engine capabilities should include host fit score");

  const call = await request("tools/call", {
    name: "tatwo_workflow_run",
    arguments: {
      mode: "XL",
      scenario: "coding",
      objective: "mcp smoke workflow first"
    }
  });
  const text = call.content?.[0]?.text ?? "";
  assert(text.includes("TatwoWorkflowRunPlanV1"), "workflow run did not return plan schema");
  assert(text.includes("\"hostMutationAllowed\" : false"), "workflow run must be host-mutation false");

  const colimaPreflightCall = await request("tools/call", {
    name: "tatwo_colima_preflight",
    arguments: {}
  });
  const colimaPreflightText = colimaPreflightCall.content?.[0]?.text ?? "";
  assert(colimaPreflightText.includes("TatwoColimaPreflightV1"), "colima preflight did not return schema");
  assert(colimaPreflightText.includes("\"hostMutationAllowed\" : false"), "colima preflight must not allow host mutation");

  const colimaRunCall = await request("tools/call", {
    name: "tatwo_colima_run",
    arguments: {
      mode: "L",
      scenario: "coding",
      objective: "mcp smoke optional colima verifier"
    }
  });
  const colimaRunText = colimaRunCall.content?.[0]?.text ?? "";
  assert(colimaRunText.includes("TatwoColimaSandboxReceiptV1"), "colima run did not return receipt schema");
  assert(colimaRunText.includes("\"hostMutationAllowed\" : false"), "colima run must not allow host mutation");
  assert(colimaRunText.includes("\"executed\" : false"), "mcp colima run must be dry-run/non-executed");

  const teamCall = await request("tools/call", {
    name: "tatwo_team_recommend",
    arguments: { mode: "L", scenario: "design" }
  });
  const teamText = teamCall.content?.[0]?.text ?? "";
  assert(teamText.includes("TatwoTeamRecommendationV1"), "team recommend did not return recommendation schema");
  assert(teamText.includes("design-team"), "design recommendation should include design-team");

  const dashboardCall = await request("tools/call", {
    name: "tatwo_team_dashboard",
    arguments: { mode: "XL", scenario: "coding" }
  });
  const dashboardText = dashboardCall.content?.[0]?.text ?? "";
  assert(dashboardText.includes("TatwoTeamReadinessDashboardV1"), "team dashboard did not return dashboard schema");
  assert(dashboardText.includes("\"uiDeferred\" : true"), "team dashboard must keep UI deferred");
  assert(dashboardText.includes("reviewer_unavailable"), "team dashboard must explain external reviewer disconnect cannot pass");
  assert(dashboardText.includes("mcp-stdio"), "team dashboard must distinguish stdio smoke from host MCP receipt");

  const stabilityCall = await request("tools/call", {
    name: "tatwo_stability_plan",
    arguments: {}
  });
  const stabilityText = stabilityCall.content?.[0]?.text ?? "";
  assert(stabilityText.includes("TatwoStabilityPlanV1"), "stability plan did not return schema");
  assert(stabilityText.includes("response.in_progress"), "stability plan should include semantic heartbeat rule");

  const disconnectGuardCall = await request("tools/call", {
    name: "tatwo_codex_disconnect_guard",
    arguments: {}
  });
  const disconnectGuardText = disconnectGuardCall.content?.[0]?.text ?? "";
  assert(disconnectGuardText.includes("TatwoCodexDisconnectGuardV1"), "disconnect guard did not return schema");
  assert(disconnectGuardText.includes("\"hostMutationAllowed\": false") || disconnectGuardText.includes("\"hostMutationAllowed\" : false"), "disconnect guard must not mutate host");
  assert(disconnectGuardText.includes("semantic-sse-in-progress"), "disconnect guard should cover semantic SSE");
  assert(disconnectGuardText.includes("clean-413-not-reset"), "disconnect guard should cover clean 413");

  const hostPreflightCall = await request("tools/call", {
    name: "tatwo_host_preflight",
    arguments: {}
  });
  const hostPreflightText = hostPreflightCall.content?.[0]?.text ?? "";
  assert(hostPreflightText.includes("TatwoHostPreflightV1"), "host preflight did not return schema");
  assert(hostPreflightText.includes("\"hostMutationAllowed\" : false"), "host preflight must be host-mutation false");

  const hostBackupCall = await request("tools/call", {
    name: "tatwo_host_backup_plan",
    arguments: {}
  });
  const hostBackupText = hostBackupCall.content?.[0]?.text ?? "";
  assert(hostBackupText.includes("TatwoHostBackupPlanV1"), "host backup plan did not return schema");
  assert(hostBackupText.includes("\"dryRun\" : true"), "host backup plan must default to dry-run");

  const installGateCall = await request("tools/call", {
    name: "tatwo_host_install_gate",
    arguments: {}
  });
  const installGateText = installGateCall.content?.[0]?.text ?? "";
  assert(installGateText.includes("TatwoHostInstallGateDecisionV1"), "host install gate did not return schema");
  assert(installGateText.includes("\"hostInstallAllowed\" : false"), "host install gate must fail closed without receipts");

  const receiptFlowCall = await request("tools/call", {
    name: "tatwo_host_receipt_flow",
    arguments: {}
  });
  const receiptFlowText = receiptFlowCall.content?.[0]?.text ?? "";
  assert(receiptFlowText.includes("TatwoHostReceiptFlowV1"), "host receipt flow did not return schema");
  assert(receiptFlowText.includes("\"hostMutationDefault\" : false"), "host receipt flow must default to no host mutation");


  const m2EntryCall = await request("tools/call", {
    name: "tatwo_m2_entry_gate",
    arguments: { latest: true, humanApprovalReceiptID: "human-M1-dryrun", confirmM2: false }
  });
  const m2EntryText = m2EntryCall.content?.[0]?.text ?? "";
  const m2EntryDoc = parseFirstJSON(m2EntryText);
  assert(m2EntryDoc?.schema === "TatwoM2EntryGateV1", "M2 entry gate did not return schema");
  assert(m2EntryDoc.m2EntryAllowed === false, "M2 entry gate must block M1 dry-run approval");
  assert(m2EntryDoc.hostMutationAllowed === false, "M2 entry gate must not mutate host");
  assert(m2EntryDoc.uiDeferred === true, "M2 entry gate must keep UI deferred");
  assert(m2EntryText.includes("M1 dry-run") || m2EntryText.includes("dryrun"), "M2 entry gate must explain that M1 dry-run approval cannot be reused");

  const runwayCall = await request("tools/call", {
    name: "tatwo_host_install_runway",
    arguments: { latest: true }
  });
  const runwayText = runwayCall.content?.[0]?.text ?? "";
  assert(runwayText.includes("TatwoHostInstallRunwayV1"), "host install runway did not return schema");
  assert(runwayText.includes("\"uiDeferred\": true") || runwayText.includes("\"uiDeferred\" : true"), "host install runway must keep UI deferred");
  assert(runwayText.includes("\"hostMutationAllowed\": false") || runwayText.includes("\"hostMutationAllowed\" : false"), "host install runway must not mutate host");

  const promotionCall = await request("tools/call", {
    name: "tatwo_host_promotion_plan",
    arguments: { latest: true }
  });
  const promotionText = promotionCall.content?.[0]?.text ?? "";
  assert(promotionText.includes("TatwoHostPromotionPlanV1"), "host promotion plan did not return schema");
  assert(promotionText.includes("\"uiDeferred\": true") || promotionText.includes("\"uiDeferred\" : true"), "host promotion plan must keep UI deferred");
  assert(promotionText.includes("\"hostMutationAllowed\": false") || promotionText.includes("\"hostMutationAllowed\" : false"), "host promotion plan must not mutate host");
  assert(promotionText.includes("\"hostInstallAllowed\": false") || promotionText.includes("\"hostInstallAllowed\" : false"), "host promotion plan must not authorize host install");
  assert(promotionText.includes("keep-single-gateway-provider"), "host promotion plan must preserve single-gateway strategy");
  assert(promotionText.includes("route-error-state"), "host promotion plan must expose route-risk circuit breaker");

  const routeRiskCall = await request("tools/call", {
    name: "tatwo_route_risk_dashboard",
    arguments: { latest: true }
  });
  const routeRiskText = routeRiskCall.content?.[0]?.text ?? "";
  assert(routeRiskText.includes("TatwoRouteRiskDashboardV1"), "route risk dashboard did not return schema");
  assert(routeRiskText.includes("\"uiDeferred\": true") || routeRiskText.includes("\"uiDeferred\" : true"), "route risk dashboard must keep UI deferred");
  assert(routeRiskText.includes("\"hostMutationAllowed\": false") || routeRiskText.includes("\"hostMutationAllowed\" : false"), "route risk dashboard must not mutate host");
  assert(routeRiskText.includes("\"hostInstallAllowed\": false") || routeRiskText.includes("\"hostInstallAllowed\" : false"), "route risk dashboard must not authorize host install");
  assert(routeRiskText.includes("live same-thread smoke"), "route risk dashboard must require live same-thread smoke");
  assert(routeRiskText.includes("response.completed"), "route risk dashboard must require route-specific response.completed proof");

  const routeSmokeCall = await request("tools/call", {
    name: "tatwo_route_smoke_plan",
    arguments: { latest: true }
  });
  const routeSmokeText = routeSmokeCall.content?.[0]?.text ?? "";
  const routeSmokeDoc = parseFirstJSON(routeSmokeText);
  assert(routeSmokeDoc?.schema === "TatwoRouteSmokePlanV1", "route smoke plan did not return schema");
  assert(routeSmokeDoc.uiDeferred === true, "route smoke plan must keep UI deferred");
  assert(routeSmokeDoc.hostMutationAllowed === false, "route smoke plan must not mutate host");
  assert(routeSmokeDoc.hostInstallAllowed === false, "route smoke plan must not authorize host install");
  assert(routeSmokeText.includes("live same-thread smoke"), "route smoke plan must require live same-thread smoke");
  assert(routeSmokeText.includes("response.completed"), "route smoke plan must require route-specific response.completed proof");
  if (Array.isArray(routeSmokeDoc.routeSmokeQueue) && routeSmokeDoc.routeSmokeQueue.length > 0) {
    assert(routeSmokeText.includes("gpt-5.5"), "route smoke plan must switch back to gpt-5.5 for continuity when route risks exist");
  }

  const routeLiveCall = await request("tools/call", {
    name: "tatwo_route_live_smoke_receipts",
    arguments: { latest: true }
  });
  const routeLiveText = routeLiveCall.content?.[0]?.text ?? "";
  const routeLiveDoc = parseFirstJSON(routeLiveText);
  assert(routeLiveDoc?.schema === "TatwoRouteLiveSmokeReceiptsGateV1", "route live smoke receipts did not return schema");
  assert(routeLiveDoc.uiDeferred === true, "route live smoke receipts must keep UI deferred");
  assert(routeLiveDoc.hostMutationAllowed === false, "route live smoke receipts must not mutate host");
  assert(routeLiveDoc.hostInstallAllowed === false, "route live smoke receipts must not authorize host install");
  assert(routeLiveText.includes("no model-text promotion") || routeLiveText.includes("model-text"), "route live smoke receipts must reject model-text promotion");
  assert(routeLiveText.includes("partial stream") || routeLiveText.includes("response.in_progress"), "route live smoke receipts must reject partial stream promotion");
  assert(routeLiveText.includes("dry-run") || routeLiveText.includes("dry_run"), "route live smoke receipts must reject dry-run promotion");

  const objectiveAdversarialCall = await request("tools/call", {
    name: "tatwo_objective_adversarial",
    arguments: { latest: true }
  });
  const objectiveAdversarialText = objectiveAdversarialCall.content?.[0]?.text ?? "";
  assert(objectiveAdversarialText.includes("TatwoObjectiveAdversarialV1"), "objective adversarial did not return schema");
  assert(objectiveAdversarialText.includes("\"hostMutationAllowed\": false") || objectiveAdversarialText.includes("\"hostMutationAllowed\" : false"), "objective adversarial must not mutate host");

  const operationalGood = await request("tools/call", {
    name: "tatwo_validate_operational_sample",
    arguments: { case: "host-live-good" }
  });
  const operationalGoodText = operationalGood.content?.[0]?.text ?? "";
  assert(operationalGood.isError !== true, "host-live-good operational sample should pass");
  assert(operationalGoodText.includes("TatwoOperationalGateReportV1"), "operational sample should return gate report");

  const operationalBad = await request("tools/call", {
    name: "tatwo_validate_operational_sample",
    arguments: { case: "partial-stream" }
  });
  const operationalBadText = operationalBad.content?.[0]?.text ?? "";
  assert(operationalBad.isError === true, "partial-stream operational sample must fail closed");
  assert(operationalBadText.includes("partial_stream_cannot_pass"), "partial-stream must explain fail-closed reason");

  child.kill();
  cleanupTemp();
  console.log("tatwo_ultrawork_mcp_smoke=passed");
} catch (error) {
  child.kill();
  cleanupTemp();
  fail(error.message);
}

function request(method, params) {
  const id = nextID++;
  const payload = { jsonrpc: "2.0", id, method, params };
  const body = Buffer.from(JSON.stringify(payload), "utf8");
  child.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
  child.stdin.write(body);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`timeout waiting for ${method}`));
    }, 30000);
    pending.set(id, { resolve, reject, timer });
  });
}

function drain() {
  while (true) {
    const headerEnd = buffer.indexOf("\r\n\r\n");
    if (headerEnd < 0) return;
    const header = buffer.slice(0, headerEnd).toString("utf8");
    const match = header.match(/Content-Length:\s*(\d+)/i);
    if (!match) throw new Error(`bad header: ${header}`);
    const length = Number(match[1]);
    const bodyStart = headerEnd + 4;
    const bodyEnd = bodyStart + length;
    if (buffer.length < bodyEnd) return;
    const body = buffer.slice(bodyStart, bodyEnd).toString("utf8");
    buffer = buffer.slice(bodyEnd);
    const message = JSON.parse(body);
    const slot = pending.get(message.id);
    if (!slot) continue;
    clearTimeout(slot.timer);
    pending.delete(message.id);
    if (message.error) {
      slot.reject(new Error(message.error.message));
    } else {
      slot.resolve(message.result);
    }
  }
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function parseFirstJSON(text) {
  const raw = String(text ?? "");
  const start = raw.indexOf("{");
  if (start < 0) return null;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < raw.length; i += 1) {
    const ch = raw[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (ch === "\\") escaped = true;
      else if (ch === "\"") inString = false;
      continue;
    }
    if (ch === "\"") { inString = true; continue; }
    if (ch === "{") depth += 1;
    if (ch === "}") {
      depth -= 1;
      if (depth === 0) {
        try { return JSON.parse(raw.slice(start, i + 1)); }
        catch { return null; }
      }
    }
  }
  return null;
}

function fail(message) {
  console.error(`tatwo_ultrawork_mcp_smoke=failed ${message}`);
  process.exit(1);
}

function cleanupTemp() {
  fs.rmSync(smokeConfigDir, { recursive: true, force: true });
  fs.rmSync(smokeSandboxRoot, { recursive: true, force: true });
  fs.rmSync(smokeStateDir, { recursive: true, force: true });
}
