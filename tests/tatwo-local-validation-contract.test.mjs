#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const script = path.join(root, "scripts", "tatwo-local-validation.mjs");
const hostRehearsalScript = path.join(root, "scripts", "tatwo-host-sandbox-rehearsal.mjs");
const hostMcpSmokeScript = path.join(root, "scripts", "tatwo-host-mcp-registration-smoke.mjs");
const workflowsRoot = path.join(root, ".github", "workflows");

const plan = spawnSync(process.execPath, [script, "--plan"], {
  cwd: root,
  encoding: "utf8",
});
assert.equal(plan.status, 0, plan.stderr);
const contract = JSON.parse(plan.stdout);
assert.equal(contract.schema, "TatwoLocalValidationPlanV1");
assert.equal(contract.receiptScope, "one_physical_device_per_receipt");
assert.equal(contract.githubRole, "private_backup_only");
assert.equal(contract.automaticGitHubHostedRunnerRequired, false);
assert.equal(contract.githubActionsUsedForValidation, false);
assert.equal(contract.macOSVirtualMachine.requiredForSourceCandidate, false);
assert.equal(contract.macOSVirtualMachine.requiredBeforeStableInstallerPromotion, true);
assert.ok(contract.deniedActions.includes("does_not_write_/Applications"));
assert.ok(contract.deniedActions.includes("does_not_apply_real_user_data_migration"));
assert.ok(contract.requiredLayers.includes("macos_sandbox_enforcement"));
assert.ok(contract.requiredLayers.includes("final_source_seal"));

const selftest = spawnSync(process.execPath, [script, "--selftest"], {
  cwd: root,
  encoding: "utf8",
});
assert.equal(selftest.status, 0, selftest.stderr);
const selftestReceipt = JSON.parse(selftest.stdout);
assert.equal(selftestReceipt.schema, "TatwoLocalValidationSelftestV1");
assert.equal(selftestReceipt.passed, true);
assert.ok(selftestReceipt.checks.every((check) => check.passed));

const hostRehearsalSource = fs.readFileSync(hostRehearsalScript, "utf8");
const hostMcpSmokeSource = fs.readFileSync(hostMcpSmokeScript, "utf8");
assert.match(
  hostRehearsalSource,
  /const inheritedOuterSandbox = process\.env\.TATWO_OUTER_SANDBOX === "1"/,
  "host rehearsal must recognize that the local gate already placed it inside a macOS sandbox",
);
assert.match(
  hostRehearsalSource,
  /inheritedOuterSandbox\s*\?\s*\[\s*process\.execPath,/s,
  "host rehearsal must reuse the inherited sandbox instead of nesting sandbox-exec",
);
assert.match(
  hostRehearsalSource,
  /const privateReadPath = path\.join\(os\.userInfo\(\)\.homedir, "\.codex"\)/,
  "the inherited-sandbox probe must target the physical user's Codex home, not the fake HOME",
);
assert.match(
  hostRehearsalSource,
  /TATWO_MCP_TOOL_TIMEOUT_MS:\s*String\(hostRehearsalMcpToolTimeoutMS\(\)\)/,
  "cold host rehearsal must give the sandboxed MCP CLI build an explicit cross-device timeout budget",
);
assert.match(
  hostRehearsalSource,
  /TATWO_HOST_REHEARSAL_MCP_TIMEOUT_MS\s*\?\?\s*"240000"/,
  "the parent rehearsal must wait longer than the cold MCP tool build budget",
);
assert.match(
  hostMcpSmokeSource,
  /const requestTimeoutMS = Math\.max\(60000, mcpToolTimeoutMS \+ 30000\)/,
  "the stdio client request timer must not expire before the MCP tool timeout",
);
assert.match(
  hostMcpSmokeSource,
  /const child = spawn\(process\.execPath,/,
  "sandboxed MCP smoke must launch Node by absolute execPath instead of PATH lookup",
);

const workflowFiles = fs.existsSync(workflowsRoot)
  ? fs.readdirSync(workflowsRoot).filter((name) => name.endsWith(".yml") || name.endsWith(".yaml"))
  : [];
assert.deepEqual(workflowFiles, [], "GitHub is backup-only; validation workflows must stay disabled");
