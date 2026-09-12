#!/usr/bin/env node
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDirectory, "..");
const binaryIndex = process.argv.indexOf("--binary");
const sandboxIndex = process.argv.indexOf("--sandbox-root");
const binary = path.resolve(
  binaryIndex >= 0 && process.argv[binaryIndex + 1]
    ? process.argv[binaryIndex + 1]
    : path.join(repoRoot, ".build/out/Products/Debug/tatwo-ultrawork"),
);
const sandboxParent = path.resolve(
  sandboxIndex >= 0 && process.argv[sandboxIndex + 1]
    ? process.argv[sandboxIndex + 1]
    : path.join(process.env.HOME || "", "Library/Application Support/tatwo2/sandboxes/tatwo-fusion-deployment-smoke-20260719"),
);
fs.mkdirSync(sandboxParent, { recursive: true });
const runPrefix = `run-${new Date().toISOString().replaceAll(/[:.]/g, "-")}-${process.pid}-`;
const root = fs.mkdtempSync(path.join(sandboxParent, runPrefix));
const runID = path.basename(root);
const manifests = path.join(repoRoot, "Modules");

function run(args, expectedStatuses = [0]) {
  const result = spawnSync(binary, args, {
    cwd: repoRoot,
    encoding: "utf8",
    maxBuffer: 20 * 1024 * 1024,
  });
  assert.ok(
    expectedStatuses.includes(result.status),
    `command failed (${result.status}): ${binary} ${args.join(" ")}\n${result.stderr}\n${result.stdout}`,
  );
  const text = result.stdout.trim();
  assert.ok(text, `command returned no JSON: ${args.join(" ")}`);
  return {
    status: result.status,
    stderr: result.stderr,
    json: JSON.parse(text),
  };
}

function writeJSON(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, { flag: "wx" });
}

function writeBundle(directory, content) {
  fs.mkdirSync(path.dirname(directory), { recursive: true });
  fs.mkdirSync(directory, { recursive: false });
  fs.writeFileSync(path.join(directory, "payload.txt"), content, { flag: "wx" });
}

function digestBundle(directory) {
  const files = [];
  const stack = [directory];
  while (stack.length > 0) {
    const current = stack.pop();
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const candidate = path.join(current, entry.name);
      if (entry.isDirectory()) stack.push(candidate);
      if (entry.isFile()) files.push(candidate);
    }
  }
  files.sort();
  const hash = crypto.createHash("sha256");
  for (const file of files) {
    const relative = path.relative(directory, file);
    hash.update(relative);
    hash.update(Buffer.from([0]));
    hash.update(fs.readFileSync(file));
    hash.update(Buffer.from([0]));
  }
  return hash.digest("hex");
}

function moduleID(rawValue = "tatwo.skill") {
  return { rawValue };
}

function bundlePath(bundle, role) {
  return { path: bundle, role };
}

function makeCandidate({
  source,
  staged,
  active,
  archive,
  digest,
  health,
  correlationID,
}) {
  const boundary = {
    moduleID: moduleID(),
    installRoot: active,
    stagingRoots: [path.join(root, "downloads"), path.join(root, "staging")],
    archiveRoots: [path.join(root, "archives")],
    protectedUserDataRoots: [path.join(root, "state/skill-data")],
    protectedDomainLedgerRoots: [path.join(root, "state/domain-ledger")],
  };
  return {
    moduleID: moduleID(),
    stage: {
      boundary,
      sourceBundle: bundlePath(source, "sourceArtifact"),
      stagedBundle: bundlePath(staged, "stagedBundle"),
      correlationID,
    },
    verify: {
      boundary,
      stagedBundle: bundlePath(staged, "stagedBundle"),
      expectedArtifactDigest: digest,
      correlationID,
    },
    archiveCurrent: {
      boundary,
      currentBundle: bundlePath(active, "activeBundle"),
      archivedBundle: bundlePath(archive, "archivedBundle"),
      correlationID,
    },
    atomicSwap: {
      boundary,
      stagedBundle: bundlePath(staged, "stagedBundle"),
      activeBundle: bundlePath(active, "activeBundle"),
      correlationID,
    },
    healthCheck: {
      boundary,
      activeBundle: bundlePath(active, "activeBundle"),
      policy: health,
      correlationID,
    },
    rollbackBundle: {
      boundary,
      archivedBundle: bundlePath(archive, "rollbackBundle"),
      activeBundle: bundlePath(active, "activeBundle"),
      correlationID,
    },
  };
}

const planResult = run([
  "deploy",
  "plan",
  "--manifests",
  manifests,
  "--module",
  "tatwo.skill",
  "--sandbox-root",
  root,
  "--json",
]);
assert.equal(planResult.json.ok, true);
const plan = planResult.json.data.plan;
assert.deepEqual(plan.orderedModuleIDs, [moduleID()]);

const install = path.join(root, "install/skills/tatwo-ultrawork");
fs.mkdirSync(path.dirname(install), { recursive: true });
writeBundle(install, "old-v1");

const sourceV2 = path.join(root, "downloads/skill-v2");
const stagedV2 = path.join(root, "staging/skill-v2");
const archiveV1 = path.join(root, "archives/skill-v1");
writeBundle(sourceV2, "new-v2");
const applyRequest = {
  plan,
  candidates: [makeCandidate({
    source: sourceV2,
    staged: stagedV2,
    active: install,
    archive: archiveV1,
    digest: digestBundle(sourceV2),
    health: { kind: "pathExists", timeoutSeconds: 5, successThreshold: 1 },
    correlationID: "apply-v2",
  })],
  correlationID: "apply-v2",
};
const applyFile = path.join(root, "requests/apply-v2.json");
writeJSON(applyFile, applyRequest);
const applied = run([
  "deploy",
  "apply",
  "--request",
  applyFile,
  "--sandbox-root",
  root,
  "--execute-bundle-only",
  "--json",
]);
assert.equal(applied.json.data.outcome, "succeeded");
assert.equal(fs.readFileSync(path.join(install, "payload.txt"), "utf8"), "new-v2");
assert.equal(fs.readFileSync(path.join(archiveV1, "payload.txt"), "utf8"), "old-v1");

const sourceV3 = path.join(root, "downloads/skill-v3");
const stagedV3 = path.join(root, "staging/skill-v3");
const archiveV2 = path.join(root, "archives/skill-v2");
writeBundle(sourceV3, "repair-v3");
const repairRequest = {
  plan,
  candidates: [makeCandidate({
    source: sourceV3,
    staged: stagedV3,
    active: install,
    archive: archiveV2,
    digest: digestBundle(sourceV3),
    health: { kind: "pathExists", timeoutSeconds: 5, successThreshold: 1 },
    correlationID: "repair-v3",
  })],
  moduleIDs: [moduleID()],
  correlationID: "repair-v3",
};
const repairFile = path.join(root, "requests/repair-v3.json");
writeJSON(repairFile, repairRequest);
const repaired = run([
  "deploy",
  "repair",
  "--request",
  repairFile,
  "--sandbox-root",
  root,
  "--execute-bundle-only",
  "--json",
]);
assert.equal(repaired.json.data.outcome, "succeeded");
assert.equal(fs.readFileSync(path.join(install, "payload.txt"), "utf8"), "repair-v3");

const badHashSource = path.join(root, "downloads/skill-bad-hash");
writeBundle(badHashSource, "bad-hash-must-not-activate");
const badHashRequest = {
  plan,
  candidates: [makeCandidate({
    source: badHashSource,
    staged: path.join(root, "staging/skill-bad-hash"),
    active: install,
    archive: path.join(root, "archives/skill-before-bad-hash"),
    digest: "f".repeat(64),
    health: { kind: "pathExists", timeoutSeconds: 5, successThreshold: 1 },
    correlationID: "bad-hash",
  })],
  correlationID: "bad-hash",
};
const badHashFile = path.join(root, "requests/bad-hash.json");
writeJSON(badHashFile, badHashRequest);
const badHash = run([
  "deploy",
  "apply",
  "--request",
  badHashFile,
  "--sandbox-root",
  root,
  "--execute-bundle-only",
  "--json",
], [3]);
assert.equal(badHash.json.data.failureCode, "verificationFailed");
assert.equal(fs.readFileSync(path.join(install, "payload.txt"), "utf8"), "repair-v3");

const unhealthySource = path.join(root, "downloads/skill-unhealthy");
const unhealthyArchive = path.join(root, "archives/skill-before-unhealthy");
writeBundle(unhealthySource, "unhealthy-must-roll-back");
const unhealthyPlan = structuredClone(plan);
const skillManifest = unhealthyPlan.manifests.find(
  (manifest) => manifest.moduleID.rawValue === "tatwo.skill",
);
skillManifest.health = { kind: "customAdapter", timeoutSeconds: 5, successThreshold: 1 };
const unhealthyRequest = {
  plan: unhealthyPlan,
  candidates: [makeCandidate({
    source: unhealthySource,
    staged: path.join(root, "staging/skill-unhealthy"),
    active: install,
    archive: unhealthyArchive,
    digest: digestBundle(unhealthySource),
    health: skillManifest.health,
    correlationID: "health-failure",
  })],
  correlationID: "health-failure",
};
const unhealthyFile = path.join(root, "requests/unhealthy.json");
writeJSON(unhealthyFile, unhealthyRequest);
const unhealthy = run([
  "deploy",
  "apply",
  "--request",
  unhealthyFile,
  "--sandbox-root",
  root,
  "--execute-bundle-only",
  "--json",
], [3]);
assert.equal(unhealthy.json.data.failureCode, "healthCheckFailed");
assert.equal(
  unhealthy.json.data.steps.at(-1).step,
  "rollbackBundle",
);
assert.equal(fs.readFileSync(path.join(install, "payload.txt"), "utf8"), "repair-v3");

const protectedData = path.join(root, "state/skill-data/user.txt");
fs.mkdirSync(path.dirname(protectedData), { recursive: true });
fs.writeFileSync(protectedData, "must-survive-reset", { flag: "wx" });
const cache = path.join(root, "cache/skill");
fs.mkdirSync(path.join(cache, "staged-bundle"), { recursive: true });
fs.mkdirSync(path.join(cache, "generated-state"), { recursive: true });
fs.writeFileSync(path.join(cache, "cache.txt"), "cache", { flag: "wx" });
fs.writeFileSync(path.join(cache, "staged-bundle/staged.txt"), "staged", { flag: "wx" });
fs.writeFileSync(path.join(cache, "generated-state/generated.txt"), "generated", { flag: "wx" });
const reset = run([
  "module",
  "reset",
  "--module",
  "tatwo.skill",
  "--manifests",
  manifests,
  "--sandbox-root",
  root,
  "--execute-reset",
  "--json",
]);
assert.equal(reset.json.data.outcome, "succeeded");
assert.deepEqual(
  reset.json.data.steps[0].resetArtifacts.sort(),
  ["cache", "generatedState", "stagedBundle"].sort(),
);
assert.equal(fs.readFileSync(protectedData, "utf8"), "must-survive-reset");
assert.equal(fs.readFileSync(path.join(install, "payload.txt"), "utf8"), "repair-v3");
assert.ok(fs.statSync(cache).isDirectory());

const doctorManifests = path.join(root, "doctor-manifests/Skill");
fs.mkdirSync(doctorManifests, { recursive: true });
fs.copyFileSync(
  path.join(manifests, "Skill/module.json"),
  path.join(doctorManifests, "module.json"),
  fs.constants.COPYFILE_EXCL,
);
const doctor = run([
  "doctor",
  "--modules",
  "--manifests",
  path.join(root, "doctor-manifests"),
  "--sandbox-root",
  root,
  "--json",
], [0, 3]);
assert.equal(doctor.json.data.moduleReceipt.outcome, "succeeded");
assert.equal(doctor.json.data.productionMutationAllowed, false);

const overlapManifestDirectory = path.join(root, "overlap-manifests/Overlap");
fs.mkdirSync(overlapManifestDirectory, { recursive: true });
const overlapManifest = structuredClone(skillManifest);
overlapManifest.moduleID = moduleID("tatwo.overlap");
overlapManifest.locations.install = {
  kind: "install",
  path: "${TATWO_MODULE_DIR}/overlap",
};
overlapManifest.locations.data = {
  kind: "userData",
  path: "${TATWO_CACHE_DIR}/overlap",
};
overlapManifest.locations.cache = {
  kind: "cache",
  path: "${TATWO_CACHE_DIR}/overlap",
};
writeJSON(path.join(overlapManifestDirectory, "module.json"), overlapManifest);
const overlapData = path.join(root, "cache/overlap/protected.txt");
fs.mkdirSync(path.dirname(overlapData), { recursive: true });
fs.writeFileSync(overlapData, "must-not-move", { flag: "wx" });
const overlap = spawnSync(binary, [
  "module",
  "reset",
  "--module",
  "tatwo.overlap",
  "--manifests",
  path.join(root, "overlap-manifests"),
  "--sandbox-root",
  root,
  "--execute-reset",
  "--json",
], {
  cwd: repoRoot,
  encoding: "utf8",
});
assert.notEqual(overlap.status, 0);
assert.match(`${overlap.stderr}\n${overlap.stdout}`, /overlaps protected userData path/);
assert.equal(fs.readFileSync(overlapData, "utf8"), "must-not-move");

const receipt = {
  schema: "TatwoModularDeploymentSmokeReceiptV1",
  ok: true,
  runID,
  root,
  productionMutationCount: 0,
  userDataDeleteCount: 0,
  domainLedgerDeleteCount: 0,
  checks: {
    plan: planResult.json.data.receipt.outcome,
    apply: applied.json.data.outcome,
    repair: repaired.json.data.outcome,
    wrongHash: badHash.json.data.failureCode,
    healthFailure: unhealthy.json.data.failureCode,
    rollbackStep: unhealthy.json.data.steps.at(-1).step,
    resetArtifacts: reset.json.data.steps[0].resetArtifacts,
    doctor: doctor.json.data.moduleReceipt.outcome,
    overlapRejected: overlap.status !== 0,
  },
};
const receiptPath = path.join(root, "receipts/modular-deployment-smoke.json");
writeJSON(receiptPath, receipt);
process.stdout.write(`${JSON.stringify({ ...receipt, receiptPath }, null, 2)}\n`);
