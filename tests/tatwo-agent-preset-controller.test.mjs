import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const tool = path.join(root, "scripts", "tatwo-agent-preset-controller.mjs");
const registryPath = path.join(root, "registry", "agent-presets.v1.json");
const goalHash = `sha256:${"11".repeat(32)}`;
const operationalPlanHash = `sha256:${"22".repeat(32)}`;
const preferredTempBase = "/tmp/tatwo2-fixture/runtime/test-tmp/agent-preset-tests";
const tempBase = fs.existsSync("/tmp/tatwo2-fixture")
  ? preferredTempBase
  : path.join(os.tmpdir(), ".tatwo-agent-preset-tests");
fs.mkdirSync(tempBase, { recursive: true });

function run(args, options = {}) {
  return spawnSync(process.execPath, [tool, ...args], {
    encoding: "utf8",
    env: {
      ...process.env,
      ...(options.env || {}),
    },
    cwd: root,
  });
}

function pass(args, options = {}) {
  const result = run(args, options);
  assert.equal(
    result.status,
    0,
    `${process.execPath} ${tool} ${args.join(" ")}\n${result.stdout}${result.stderr}`,
  );
  return JSON.parse(result.stdout);
}

function fail(args, pattern, options = {}) {
  const result = run(args, options);
  assert.notEqual(result.status, 0, `expected command to fail: ${args.join(" ")}`);
  assert.match(`${result.stdout}\n${result.stderr}`, pattern);
  return result;
}

function fixture() {
  const runRoot = fs.mkdtempSync(path.join(tempBase, "run-"));
  return {
    runRoot,
    current: path.join(runRoot, "current-agents"),
    staging: path.join(runRoot, "staging"),
    backup: path.join(runRoot, "backups"),
  };
}

function canonicalRegistry() {
  return JSON.parse(fs.readFileSync(registryPath, "utf8"));
}

function writeJSON(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function planPaths(
  f,
  selectedRegistry = registryPath,
  extra = [],
  options = {},
) {
  return pass([
    "plan",
    "--registry", selectedRegistry,
    "--current-root", f.current,
    "--staging-root", f.staging,
    "--goal-hash", goalHash,
    "--operational-plan-hash", operationalPlanHash,
    "--json",
    ...extra,
  ], options);
}

function authorizationFor(plan, f, overrides = {}) {
  const approvedAt = new Date();
  const expiresAt = new Date(approvedAt.getTime() + 5 * 60 * 1000);
  return {
    schema: "TatwoCodexAgentPresetApplyAuthorizationV2",
    approvedGoalHash: plan.goalHash,
    approvedOperationalPlanHash: plan.operationalPlanHash,
    approvedPlanDigest: plan.planDigest,
    approvedRegistryDigest: plan.registryDigest,
    approvedTargetRoot: f.current,
    approvedBackupRoot: f.backup,
    approvedFiles: plan.items
      .filter((item) => item.action === "create" || item.action === "update")
      .map((item) => item.targetRelativePath)
      .sort(),
    approver: "fixture-human-gate",
    approvedAt: approvedAt.toISOString(),
    expiresAt: expiresAt.toISOString(),
    ...overrides,
  };
}

function applyPaths(plan, f, options = {}) {
  const auth = path.join(f.runRoot, `authorization-${crypto.randomUUID()}.json`);
  const receipt = path.join(f.runRoot, `apply-${crypto.randomUUID()}.json`);
  writeJSON(auth, authorizationFor(plan, f, options.authorizationOverrides));
  const result = run([
    "apply",
    "--plan", path.join(f.staging, "plan.json"),
    "--target-root", f.current,
    "--backup-root", f.backup,
    "--authorization", auth,
    "--receipt-out", receipt,
    "--json",
    ...(options.extraArgs || []),
  ], { env: options.env });
  return { auth, receipt, result };
}

function passApply(plan, f, options = {}) {
  const applied = applyPaths(plan, f, options);
  assert.equal(
    applied.result.status,
    0,
    `${applied.result.stdout}${applied.result.stderr}`,
  );
  return {
    ...applied,
    value: JSON.parse(applied.result.stdout),
  };
}

function sha256(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

function transactionReceipts(backupRoot, name) {
  if (!fs.existsSync(backupRoot)) return [];
  return fs.readdirSync(backupRoot)
    .map((entry) => path.join(backupRoot, entry, name))
    .filter((candidate) => fs.existsSync(candidate));
}

test("canonical registry validates exact native preset routing", () => {
  const receipt = pass(["validate", "--registry", registryPath, "--json"]);
  assert.equal(receipt.schema, "TatwoAgentPresetRegistryValidationReceiptV1");
  assert.equal(receipt.status, "PASS");
  assert.equal(receipt.presetCount, 5);
  assert.deepEqual(receipt.presetIDs, [
    "uw-builder",
    "uw-orchestrator",
    "uw-reviewer",
    "uw-scout",
    "uw-verifier",
  ]);
  assert.deepEqual(receipt.modelBindings, {
    "uw-builder": { model: "gpt-5.6-sol", effort: "high" },
    "uw-orchestrator": { model: "gpt-5.5", effort: "xhigh" },
    "uw-reviewer": { model: "gpt-5.6-terra", effort: "high" },
    "uw-scout": { model: "gpt-5.6-sol", effort: "low" },
    "uw-verifier": { model: "gpt-5.6-terra", effort: "high" },
  });
  const text = fs.readFileSync(registryPath, "utf8");
  assert.doesNotMatch(text, /gpt-5\.6-luna|gpt-5\.4(?:-mini)?/);
});

test("render and plan are deterministic even when registry entries are reordered", () => {
  const f = fixture();
  const first = planPaths(f);
  assert.equal(first.schema, "TatwoCodexAgentPresetStagedPlanV2");
  assert.equal(first.goalHash, goalHash);
  assert.equal(first.operationalPlanHash, operationalPlanHash);
  const firstFiles = Object.fromEntries(
    fs.readdirSync(path.join(f.staging, "agents")).sort().map((name) => [
      name,
      fs.readFileSync(path.join(f.staging, "agents", name), "utf8"),
    ]),
  );
  const shuffled = canonicalRegistry();
  shuffled.agentPresets.reverse();
  const shuffledPath = path.join(f.runRoot, "shuffled.json");
  writeJSON(shuffledPath, shuffled);
  const second = planPaths(f, shuffledPath);
  const secondFiles = Object.fromEntries(
    fs.readdirSync(path.join(f.staging, "agents")).sort().map((name) => [
      name,
      fs.readFileSync(path.join(f.staging, "agents", name), "utf8"),
    ]),
  );
  assert.equal(first.registryDigest, second.registryDigest);
  assert.equal(first.planDigest, second.planDigest);
  assert.deepEqual(first.items, second.items);
  assert.deepEqual(firstFiles, secondFiles);
  assert.ok(first.items.every((item) => item.action === "create"));
  for (const [name, text] of Object.entries(firstFiles)) {
    assert.match(text, /^# schema: TatwoCodexAgentPresetV1$/m);
    assert.match(text, /^# generated-from: TatwoAgentPresetRegistryV1 id=uw-/m);
    assert.match(text, /^# registry-sha256: [0-9a-f]{64}$/m);
    assert.match(text, /^# renderer-version: tatwo-codex-agent-preset-renderer-v1$/m);
    assert.match(text, /^# managed-body-sha256: [0-9a-f]{64}$/m);
    assert.match(text, /DO NOT HAND-EDIT/);
    assert.match(name, /^uw-[a-z-]+\.toml$/);
  }
});

test("registry validation fails closed for forbidden models and identity pollution", async (t) => {
  const cases = [
    {
      name: "luna",
      mutate(doc) { doc.agentPresets[0].modelBinding = "gpt-5.6-luna"; },
      pattern: /forbidden or unapproved model/,
    },
    {
      name: "gpt-5.4",
      mutate(doc) { doc.agentPresets[0].modelBinding = "gpt-5.4"; },
      pattern: /forbidden or unapproved model/,
    },
    {
      name: "gpt-5.4-mini",
      mutate(doc) { doc.agentPresets[0].modelBinding = "gpt-5.4-mini"; },
      pattern: /forbidden or unapproved model/,
    },
    {
      name: "unknown effort",
      mutate(doc) { doc.agentPresets[0].effort = "max"; },
      pattern: /unknown effort/,
    },
    {
      name: "duplicate id",
      mutate(doc) { doc.agentPresets[1].id = doc.agentPresets[0].id; },
      pattern: /codexAgentName must exactly equal id|duplicate preset id/,
    },
    {
      name: "path traversal",
      mutate(doc) {
        doc.agentPresets[0].id = "../uw-builder";
        doc.agentPresets[0].codexAgentName = "../uw-builder";
      },
      pattern: /path traversal rejected/,
    },
    {
      name: "builder host escalation",
      mutate(doc) { doc.agentPresets[0].identityGroup = "host_executor"; },
      pattern: /identity_lane_pollution/,
    },
    {
      name: "reviewer supervisor escalation",
      mutate(doc) {
        const reviewer = doc.agentPresets.find((item) => item.id === "uw-reviewer");
        reviewer.identityGroup = "loops_supervisor";
      },
      pattern: /identity_lane_pollution/,
    },
    {
      name: "protected flag",
      mutate(doc) { doc.agentPresets[0].protectedSurfaceOk = true; },
      pattern: /protected\/high-risk/,
    },
    {
      name: "unwhitelisted native extra",
      mutate(doc) { doc.agentPresets[0].codexTomlExtras = { sandbox_mode: "danger" }; },
      pattern: /no V1 whitelist/,
    },
    {
      name: "unknown registry key",
      mutate(doc) { doc.reverseAdoptFromLive = true; },
      pattern: /registry contains unknown key/,
    },
    {
      name: "unknown preset key",
      mutate(doc) { doc.agentPresets[0].hostExecutor = true; },
      pattern: /agentPresets\[0\] contains unknown key/,
    },
  ];
  for (const item of cases) {
    await t.test(item.name, () => {
      const f = fixture();
      const doc = canonicalRegistry();
      item.mutate(doc);
      const invalid = path.join(f.runRoot, "invalid.json");
      writeJSON(invalid, doc);
      fail(["validate", "--registry", invalid, "--json"], item.pattern);
      fail([
        "plan",
        "--registry", invalid,
        "--current-root", f.current,
        "--staging-root", f.staging,
        "--goal-hash", goalHash,
        "--operational-plan-hash", operationalPlanHash,
        "--json",
      ], item.pattern);
      assert.equal(fs.existsSync(f.staging), false, "invalid registry must not create staging");
    });
  }
});

test("plan emits exact full-file unified diff and detects managed update", () => {
  const f = fixture();
  const old = canonicalRegistry();
  old.registryRevision = "tatwo-agent-presets-old";
  for (const preset of old.agentPresets) {
    preset.revision = "old";
    preset.description = `${preset.description} Old projection.`;
  }
  const oldPath = path.join(f.runRoot, "old.json");
  writeJSON(oldPath, old);
  const oldPlan = planPaths(f, oldPath);
  passApply(oldPlan, f);

  const currentPlan = planPaths(f);
  assert.ok(currentPlan.items.every((item) => item.action === "update"));
  for (const item of currentPlan.items) {
    assert.match(item.unifiedDiff, new RegExp(`^--- a/${item.targetRelativePath}`, "m"));
    assert.match(item.unifiedDiff, new RegExp(`^\\+\\+\\+ b/${item.targetRelativePath}`, "m"));
    assert.match(item.unifiedDiff, /^@@ -1,\d+ \+1,\d+ @@$/m);
    assert.match(item.unifiedDiff, /^-# registry-revision: tatwo-agent-presets-old$/m);
    assert.match(
      item.unifiedDiff,
      /^\+# registry-revision: tatwo-agent-presets-20260809-r1$/m,
    );
    assert.equal(item.observedProvenance.state, "managed");
  }
});

test("manual TOML drift is conflict and can never be reverse-adopted", () => {
  const f = fixture();
  const initial = planPaths(f);
  passApply(initial, f);
  const builder = path.join(f.current, "uw-builder.toml");
  fs.appendFileSync(builder, "# manual authority escalation\n");
  const driftedHash = sha256(fs.readFileSync(builder));
  const conflictPlan = planPaths(f);
  const item = conflictPlan.items.find((entry) => entry.id === "uw-builder");
  assert.equal(item.action, "conflict");
  assert.equal(item.observedProvenance.state, "drift");
  assert.match(item.reason, /reverse adoption is forbidden/);
  const applied = applyPaths(conflictPlan, f);
  assert.notEqual(applied.result.status, 0);
  assert.match(applied.result.stderr, /plan contains conflict/);
  assert.equal(sha256(fs.readFileSync(builder)), driftedHash);
});

test("fresh unmanaged target-id TOML is a conflict and is never adopted", () => {
  const f = fixture();
  fs.mkdirSync(f.current, { recursive: true });
  const builder = path.join(f.current, "uw-builder.toml");
  fs.writeFileSync(builder, 'model = "hand-authored"\n');
  const before = sha256(fs.readFileSync(builder));
  const plan = planPaths(f);
  const item = plan.items.find((entry) => entry.id === "uw-builder");
  assert.equal(item.action, "conflict");
  assert.equal(item.observedProvenance.state, "unmanaged");
  assert.match(item.reason, /reverse adoption is forbidden/);
  const applied = applyPaths(plan, f);
  assert.notEqual(applied.result.status, 0);
  assert.match(applied.result.stderr, /plan contains conflict/);
  assert.equal(sha256(fs.readFileSync(builder)), before);
});

test("direct target TOML symlinks fail closed in plan, apply, and rollback", async (t) => {
  await t.test("plan rejects an individual target symlink", () => {
    const f = fixture();
    fs.mkdirSync(f.current, { recursive: true });
    const outside = path.join(f.runRoot, "outside-plan.toml");
    fs.writeFileSync(outside, 'model = "outside"\n');
    fs.symlinkSync(outside, path.join(f.current, "uw-builder.toml"));
    fail([
      "plan",
      "--registry", registryPath,
      "--current-root", f.current,
      "--staging-root", f.staging,
      "--goal-hash", goalHash,
      "--operational-plan-hash", operationalPlanHash,
      "--json",
    ], /current preset uw-builder is a symlink/);
    assert.equal(fs.readFileSync(outside, "utf8"), 'model = "outside"\n');
  });

  await t.test("apply rejects a target symlink introduced after planning", () => {
    const f = fixture();
    const plan = planPaths(f);
    fs.mkdirSync(f.current, { recursive: true });
    const outside = path.join(f.runRoot, "outside-apply.toml");
    fs.writeFileSync(outside, 'model = "outside"\n');
    fs.symlinkSync(outside, path.join(f.current, "uw-builder.toml"));
    const applied = applyPaths(plan, f);
    assert.notEqual(applied.result.status, 0);
    assert.match(applied.result.stderr, /target preset uw-builder is a symlink/);
    assert.equal(fs.readFileSync(outside, "utf8"), 'model = "outside"\n');
  });

  await t.test("rollback rejects a target symlink introduced after apply", () => {
    const f = fixture();
    const applied = passApply(planPaths(f), f);
    const item = applied.value.items.find((entry) => entry.id === "uw-builder");
    const preserved = path.join(f.runRoot, "preserved-builder.toml");
    fs.renameSync(item.targetPath, preserved);
    const outside = path.join(f.runRoot, "outside-rollback.toml");
    fs.writeFileSync(outside, 'model = "outside"\n');
    fs.symlinkSync(outside, item.targetPath);
    fail([
      "rollback",
      "--receipt", applied.receipt,
      "--json",
    ], /rollback target uw-builder is a symlink/);
    assert.equal(fs.readFileSync(outside, "utf8"), 'model = "outside"\n');
    assert.equal(fs.existsSync(preserved), true);
  });
});

test("authorized fake-root apply backs up, reads back, and preserves unmanaged files", () => {
  const f = fixture();
  const old = canonicalRegistry();
  old.registryRevision = "tatwo-agent-presets-old";
  for (const preset of old.agentPresets) {
    preset.revision = "old";
    preset.description = `${preset.description} Old projection.`;
  }
  const oldPath = path.join(f.runRoot, "old.json");
  writeJSON(oldPath, old);
  const oldPlan = planPaths(f, oldPath);
  passApply(oldPlan, f);
  const oldBytes = Object.fromEntries(
    oldPlan.items.map((item) => [
      item.targetRelativePath,
      fs.readFileSync(path.join(f.current, item.targetRelativePath)),
    ]),
  );
  fs.writeFileSync(path.join(f.current, "user-custom.toml"), "model = \"keep\"\n");

  const plan = planPaths(f);
  const applied = passApply(plan, f);
  assert.equal(applied.value.schema, "TatwoCodexAgentPresetApplyReceiptV1");
  assert.equal(applied.value.status, "applied");
  assert.equal(applied.value.goalHash, goalHash);
  assert.equal(applied.value.operationalPlanHash, operationalPlanHash);
  assert.equal(applied.value.readback, "PASS");
  assert.equal(applied.value.liveUserConfig, false);
  assert.equal(applied.value.items.length, 5);
  for (const item of applied.value.items) {
    assert.ok(item.backupPath);
    assert.equal(sha256(fs.readFileSync(item.backupPath)), item.beforeSHA256);
    assert.equal(
      sha256(fs.readFileSync(item.targetPath)),
      item.afterSHA256,
    );
    assert.deepEqual(
      fs.readFileSync(item.backupPath),
      oldBytes[item.targetRelativePath],
    );
  }
  assert.equal(
    fs.readFileSync(path.join(f.current, "user-custom.toml"), "utf8"),
    "model = \"keep\"\n",
  );
});

test("rollback restores prior managed bytes and archives the after-state", () => {
  const f = fixture();
  const old = canonicalRegistry();
  old.registryRevision = "tatwo-agent-presets-old";
  for (const preset of old.agentPresets) {
    preset.revision = "old";
    preset.description = `${preset.description} Old projection.`;
  }
  const oldPath = path.join(f.runRoot, "old.json");
  writeJSON(oldPath, old);
  passApply(planPaths(f, oldPath), f);
  const before = Object.fromEntries(
    fs.readdirSync(f.current).map((name) => [
      name,
      fs.readFileSync(path.join(f.current, name)),
    ]),
  );
  const applied = passApply(planPaths(f), f);
  const rollbackOut = path.join(f.runRoot, "rollback.json");
  const rolledBack = pass([
    "rollback",
    "--receipt", applied.receipt,
    "--receipt-out", rollbackOut,
    "--json",
  ]);
  assert.equal(rolledBack.schema, "TatwoCodexAgentPresetRollbackReceiptV1");
  assert.equal(rolledBack.status, "rolled_back");
  assert.equal(rolledBack.goalHash, goalHash);
  assert.equal(rolledBack.operationalPlanHash, operationalPlanHash);
  assert.equal(rolledBack.readback, "PASS");
  for (const item of rolledBack.items) {
    assert.deepEqual(
      fs.readFileSync(item.targetPath),
      before[path.basename(item.targetPath)],
    );
    assert.equal(fs.existsSync(item.reversibleAfterStateArchive), true);
  }
});

test("rollback of newly created presets removes targets but keeps a recoverable archive", () => {
  const f = fixture();
  fs.mkdirSync(f.current, { recursive: true });
  fs.writeFileSync(path.join(f.current, "user-custom.toml"), "custom\n");
  const plan = planPaths(f);
  const applied = passApply(plan, f);
  const rolledBack = pass([
    "rollback",
    "--receipt", applied.receipt,
    "--json",
  ]);
  assert.equal(rolledBack.status, "rolled_back");
  for (const item of rolledBack.items) {
    assert.equal(item.targetRemoved, true);
    assert.equal(fs.existsSync(item.targetPath), false);
    assert.equal(fs.existsSync(item.reversibleAfterStateArchive), true);
  }
  assert.equal(
    fs.readFileSync(path.join(f.current, "user-custom.toml"), "utf8"),
    "custom\n",
  );
});

test("rollback failure restores the complete applied after-state and emits authority-bound failure receipt", () => {
  const f = fixture();
  const applied = passApply(planPaths(f), f);
  const result = run([
    "rollback",
    "--receipt", applied.receipt,
    "--json",
  ], {
    env: {
      TATWO_AGENT_PRESET_TEST_MODE: "1",
      TATWO_AGENT_PRESET_TEST_FAIL_ROLLBACK_AFTER_RESTORES: "2",
    },
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /rollback failed after 2 restores; after-state recovered/);
  for (const item of applied.value.items) {
    assert.equal(sha256(fs.readFileSync(item.targetPath)), item.afterSHA256);
  }
  const receipts = transactionReceipts(f.backup, "rollback-failure-receipt.json");
  assert.equal(receipts.length, 1);
  const failure = JSON.parse(fs.readFileSync(receipts[0], "utf8"));
  assert.equal(failure.status, "rollback_failed_after_state_recovered");
  assert.equal(failure.readback, "AFTER_STATE_RECOVERED");
  assert.equal(failure.goalHash, goalHash);
  assert.equal(failure.operationalPlanHash, operationalPlanHash);
});

test("rollback recovery failure is explicit, fail-closed, and authority-bound", () => {
  const f = fixture();
  const applied = passApply(planPaths(f), f);
  const result = run([
    "rollback",
    "--receipt", applied.receipt,
    "--json",
  ], {
    env: {
      TATWO_AGENT_PRESET_TEST_MODE: "1",
      TATWO_AGENT_PRESET_TEST_FAIL_ROLLBACK_AFTER_RESTORES: "1",
      TATWO_AGENT_PRESET_TEST_FAIL_ROLLBACK_RECOVERY_AFTER_WRITES: "1",
    },
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /after-state recovery failed/);
  const receipts = transactionReceipts(f.backup, "rollback-failure-receipt.json");
  assert.equal(receipts.length, 1);
  const failure = JSON.parse(fs.readFileSync(receipts[0], "utf8"));
  assert.equal(failure.status, "rollback_failed_recovery_failed");
  assert.equal(failure.readback, "RECOVERY_FAILED");
  assert.equal(failure.goalHash, goalHash);
  assert.equal(failure.operationalPlanHash, operationalPlanHash);
  assert.match(failure.recoveryError, /injected rollback recovery failure/);
});

test("byte-identical plan produces a human-bound noop receipt without rewriting targets", () => {
  const f = fixture();
  passApply(planPaths(f), f);
  const before = Object.fromEntries(
    fs.readdirSync(f.current).sort().map((name) => {
      const target = path.join(f.current, name);
      return [name, { hash: sha256(fs.readFileSync(target)), mtime: fs.statSync(target).mtimeMs }];
    }),
  );
  const noopPlan = planPaths(f);
  assert.ok(noopPlan.items.every((item) => item.action === "noop"));
  const noop = passApply(noopPlan, f);
  assert.equal(noop.value.status, "noop");
  assert.equal(noop.value.goalHash, goalHash);
  assert.equal(noop.value.operationalPlanHash, operationalPlanHash);
  assert.deepEqual(noop.value.items, []);
  assert.match(noop.value.receiptDigest, /^[0-9a-f]{64}$/);
  const after = Object.fromEntries(
    fs.readdirSync(f.current).sort().map((name) => {
      const target = path.join(f.current, name);
      return [name, { hash: sha256(fs.readFileSync(target)), mtime: fs.statSync(target).mtimeMs }];
    }),
  );
  assert.deepEqual(after, before);
});

test("rollback rejects a tampered apply receipt before touching targets", () => {
  const f = fixture();
  const applied = passApply(planPaths(f), f);
  const receipt = JSON.parse(fs.readFileSync(applied.receipt, "utf8"));
  receipt.items[0].beforeExists = true;
  receipt.items[0].beforeSHA256 = "00".repeat(32);
  const tampered = path.join(f.runRoot, "tampered-apply-receipt.json");
  writeJSON(tampered, receipt);
  const before = Object.fromEntries(
    receipt.items.map((item) => [item.targetPath, sha256(fs.readFileSync(item.targetPath))]),
  );
  fail([
    "rollback",
    "--receipt", tampered,
    "--json",
  ], /apply receipt digest mismatch/);
  const after = Object.fromEntries(
    receipt.items.map((item) => [item.targetPath, sha256(fs.readFileSync(item.targetPath))]),
  );
  assert.deepEqual(after, before);
});

test("injected mid-batch failure restores the complete before-state", () => {
  const f = fixture();
  fs.mkdirSync(f.current, { recursive: true });
  fs.writeFileSync(path.join(f.current, "user-custom.toml"), "custom\n");
  const plan = planPaths(f);
  const applied = applyPaths(plan, f, {
    env: {
      TATWO_AGENT_PRESET_TEST_MODE: "1",
      TATWO_AGENT_PRESET_TEST_FAIL_AFTER_WRITES: "2",
    },
  });
  assert.notEqual(applied.result.status, 0);
  assert.match(applied.result.stderr, /apply failed and restored before state/);
  for (const item of plan.items) {
    assert.equal(fs.existsSync(path.join(f.current, item.targetRelativePath)), false);
  }
  assert.equal(
    fs.readFileSync(path.join(f.current, "user-custom.toml"), "utf8"),
    "custom\n",
  );
  const failureReceipts = fs
    .readdirSync(f.backup)
    .map((name) => path.join(f.backup, name, "failure-receipt.json"))
    .filter((candidate) => fs.existsSync(candidate));
  assert.equal(failureReceipts.length, 1);
  assert.equal(
    JSON.parse(fs.readFileSync(failureReceipts[0], "utf8")).readback,
    "BEFORE_STATE_RESTORED",
  );
});

test("apply failure plus automatic-restore failure is explicit and authority-bound", () => {
  const f = fixture();
  const plan = planPaths(f);
  const applied = applyPaths(plan, f, {
    env: {
      TATWO_AGENT_PRESET_TEST_MODE: "1",
      TATWO_AGENT_PRESET_TEST_FAIL_AFTER_WRITES: "2",
      TATWO_AGENT_PRESET_TEST_FAIL_AUTOMATIC_RESTORE_AFTER: "1",
    },
  });
  assert.notEqual(applied.result.status, 0);
  assert.match(applied.result.stderr, /apply failed and automatic rollback also failed/);
  const receipts = transactionReceipts(f.backup, "failure-receipt.json");
  assert.equal(receipts.length, 1);
  const failure = JSON.parse(fs.readFileSync(receipts[0], "utf8"));
  assert.equal(failure.status, "apply_failed_rollback_failed");
  assert.equal(failure.readback, "ROLLBACK_FAILED");
  assert.equal(failure.goalHash, goalHash);
  assert.equal(failure.operationalPlanHash, operationalPlanHash);
  assert.match(failure.rollbackError, /injected automatic restore failure/);
});

test("stale target and mismatched authorization both fail before mutation", () => {
  const staleFixture = fixture();
  const stalePlan = planPaths(staleFixture);
  fs.mkdirSync(staleFixture.current, { recursive: true });
  const target = path.join(staleFixture.current, "uw-builder.toml");
  fs.writeFileSync(target, "manual target appeared\n");
  const stale = applyPaths(stalePlan, staleFixture);
  assert.notEqual(stale.result.status, 0);
  assert.match(stale.result.stderr, /stale plan/);
  assert.equal(fs.readFileSync(target, "utf8"), "manual target appeared\n");

  const authFixture = fixture();
  const authPlan = planPaths(authFixture);
  const mismatched = applyPaths(authPlan, authFixture, {
    authorizationOverrides: {
      approvedPlanDigest: "00".repeat(32),
    },
  });
  assert.notEqual(mismatched.result.status, 0);
  assert.match(mismatched.result.stderr, /approvedPlanDigest mismatch/);
  assert.equal(fs.existsSync(authFixture.current), false);
});

test("authorization V2 rejects cross-goal, cross-plan, expired, and overlong grants", async (t) => {
  const cases = [
    {
      name: "cross-goal replay",
      overrides: { approvedGoalHash: `sha256:${"33".repeat(32)}` },
      pattern: /approvedGoalHash mismatch/,
    },
    {
      name: "cross-operational-plan replay",
      overrides: { approvedOperationalPlanHash: `sha256:${"44".repeat(32)}` },
      pattern: /approvedOperationalPlanHash mismatch/,
    },
    {
      name: "expired grant",
      overrides: {
        approvedAt: new Date(Date.now() - 20 * 60 * 1000).toISOString(),
        expiresAt: new Date(Date.now() - 10 * 60 * 1000).toISOString(),
      },
      pattern: /authorization expired/,
    },
    {
      name: "overlong grant",
      overrides: {
        approvedAt: new Date().toISOString(),
        expiresAt: new Date(Date.now() + 16 * 60 * 1000).toISOString(),
      },
      pattern: /TTL exceeds 15 minutes/,
    },
  ];
  for (const item of cases) {
    await t.test(item.name, () => {
      const f = fixture();
      const plan = planPaths(f);
      const applied = applyPaths(plan, f, {
        authorizationOverrides: item.overrides,
      });
      assert.notEqual(applied.result.status, 0);
      assert.match(applied.result.stderr, item.pattern);
      assert.equal(fs.existsSync(f.current), false);
    });
  }
});

test("real or symlinked ~/.codex roots are rejected without explicit acknowledgement", () => {
  const f = fixture();
  const homeCodexAgents = path.join(
    process.env.HOME || os.homedir(),
    ".codex",
    "agents",
  );
  fail([
    "plan",
    "--registry", registryPath,
    "--current-root", homeCodexAgents,
    "--staging-root", f.staging,
    "--goal-hash", goalHash,
    "--operational-plan-hash", operationalPlanHash,
    "--json",
  ], /under ~\/\.codex/);
  assert.equal(fs.existsSync(f.staging), false);

  const alias = path.join(f.runRoot, "codex-alias");
  fs.symlinkSync(path.dirname(homeCodexAgents), alias);
  fail([
    "plan",
    "--registry", registryPath,
    "--current-root", path.join(alias, "agents"),
    "--staging-root", f.staging,
    "--goal-hash", goalHash,
    "--operational-plan-hash", operationalPlanHash,
    "--json",
  ], /under ~\/\.codex/);
  assert.equal(fs.existsSync(f.staging), false);
});

test("apply and rollback reject fake-HOME ~/.codex targets without explicit acknowledgement", () => {
  const f = fixture();
  const fakeHome = path.join(f.runRoot, "fake-home");
  f.current = path.join(fakeHome, ".codex", "agents");
  const env = { HOME: fakeHome };
  const plan = planPaths(
    f,
    registryPath,
    ["--i-understand-user-config"],
    { env },
  );

  const rejectedApply = applyPaths(plan, f, { env });
  assert.notEqual(rejectedApply.result.status, 0);
  assert.match(rejectedApply.result.stderr, /target root is under ~\/\.codex/);
  assert.equal(fs.existsSync(f.current), false);

  const applied = passApply(plan, f, {
    env,
    extraArgs: ["--i-understand-user-config"],
  });
  const beforeRollback = Object.fromEntries(
    applied.value.items.map((item) => [
      item.targetPath,
      sha256(fs.readFileSync(item.targetPath)),
    ]),
  );
  fail([
    "rollback",
    "--receipt", applied.receipt,
    "--json",
  ], /rollback target root is under ~\/\.codex/, { env });
  const afterRejectedRollback = Object.fromEntries(
    applied.value.items.map((item) => [
      item.targetPath,
      sha256(fs.readFileSync(item.targetPath)),
    ]),
  );
  assert.deepEqual(afterRejectedRollback, beforeRollback);
});

test("selftest validates source truth without live apply", () => {
  const receipt = pass(["--selftest"]);
  assert.equal(receipt.status, "PASS");
  assert.equal(receipt.presetCount, 5);
  assert.equal(receipt.liveApplyPerformed, false);
});
