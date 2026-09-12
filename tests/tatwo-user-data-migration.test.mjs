#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const script = path.join(root, "scripts", "tatwo-user-data-migration.mjs");
const fixture = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-data-migration-"));
const support = path.join(fixture, "Application Support");
const canonical = path.join(support, "Tatwo Ultrawork");
const nested = path.join(canonical, "TatwoUltrawork");
const compact = path.join(support, "TatwoUltrawork");
const receipt = path.join(fixture, "receipt.json");

fs.mkdirSync(path.join(nested, "sessions"), { recursive: true });
fs.mkdirSync(path.join(compact, "DeviceSync"), { recursive: true });
fs.writeFileSync(path.join(nested, "native-chat-threads.json"), "{\"threads\":[]}\n");
fs.writeFileSync(path.join(nested, "sessions", "ledger.jsonl"), "{}\n");
fs.writeFileSync(path.join(compact, "DeviceSync", "snapshot.json"), "{\"ok\":true}\n");

const preflight = run(["--application-support-root", support]);
assert.equal(preflight.status, 0, preflight.stderr);
const plan = JSON.parse(preflight.stdout);
assert.equal(plan.mode, "preflight");
assert.equal(plan.copyCount, 3);
assert.equal(plan.conflictCount, 0);
assert.equal(fs.existsSync(path.join(canonical, "native-chat-threads.json")), false);

const missingReceipt = run([
  "--apply",
  "--application-support-root",
  support,
]);
assert.notEqual(missingReceipt.status, 0);
assert.equal(fs.existsSync(path.join(canonical, "native-chat-threads.json")), false);

const occupiedReceipt = path.join(fixture, "occupied-receipt.json");
fs.writeFileSync(occupiedReceipt, "do not replace\n");
const existingReceipt = run([
  "--apply",
  "--application-support-root",
  support,
  "--receipt",
  occupiedReceipt,
]);
assert.notEqual(existingReceipt.status, 0);
assert.equal(fs.readFileSync(occupiedReceipt, "utf8"), "do not replace\n");
assert.equal(fs.existsSync(path.join(canonical, "native-chat-threads.json")), false);

const apply = run([
  "--apply",
  "--application-support-root",
  support,
  "--receipt",
  receipt,
]);
assert.equal(apply.status, 0, apply.stderr);
const result = JSON.parse(apply.stdout);
assert.equal(result.mode, "apply");
assert.equal(result.copiedCount, 3);
assert.equal(fs.readFileSync(path.join(canonical, "native-chat-threads.json"), "utf8"), "{\"threads\":[]}\n");
assert.equal(fs.readFileSync(path.join(canonical, "sessions", "ledger.jsonl"), "utf8"), "{}\n");
assert.equal(fs.readFileSync(path.join(canonical, "DeviceSync", "snapshot.json"), "utf8"), "{\"ok\":true}\n");
assert.equal(fs.existsSync(path.join(nested, "native-chat-threads.json")), true);
assert.equal(fs.existsSync(path.join(compact, "DeviceSync", "snapshot.json")), true);
assert.equal(JSON.parse(fs.readFileSync(receipt, "utf8")).sourceDataPreserved, true);

const nestedChat = {
  projects: [],
  schemaVersion: 1,
  threads: [{
    id: "standalone-new",
    title: "new",
    messages: [{ id: "new-message", role: "user", text: "new" }],
  }],
  updatedAt: "2026-07-13T12:24:44Z",
};
const compactChat = {
  projects: [{
    id: "legacy-project",
    name: "legacy",
    threads: [{
      id: "project-old",
      title: "old",
      messages: [{ id: "old-message", role: "assistant", text: "old" }],
    }],
  }],
  schemaVersion: 1,
  updatedAt: "2026-07-08T09:04:40Z",
};
const mergeSupport = path.join(fixture, "Merge Application Support");
const mergeCanonical = path.join(mergeSupport, "Tatwo Ultrawork");
const mergeNested = path.join(mergeCanonical, "TatwoUltrawork");
const mergeCompact = path.join(mergeSupport, "TatwoUltrawork");
const mergeReceipt = path.join(fixture, "merge-receipt.json");
fs.mkdirSync(mergeNested, { recursive: true });
fs.mkdirSync(mergeCompact, { recursive: true });
fs.writeFileSync(
  path.join(mergeNested, "native-chat-threads.json"),
  `${JSON.stringify(nestedChat)}\n`,
);
fs.writeFileSync(
  path.join(mergeCompact, "native-chat-threads.json"),
  `${JSON.stringify(compactChat)}\n`,
);

const mergePreflight = run(["--application-support-root", mergeSupport]);
assert.equal(mergePreflight.status, 0, mergePreflight.stderr);
const mergePlan = JSON.parse(mergePreflight.stdout);
assert.equal(mergePlan.copyCount, 1);
assert.equal(mergePlan.mergeCount, 1);
assert.equal(mergePlan.mergePlans[0].projectCount, 1);
assert.equal(mergePlan.mergePlans[0].standaloneThreadCount, 1);
assert.equal(mergePlan.mergePlans[0].messageCount, 2);
assert.equal(fs.existsSync(path.join(mergeCanonical, "native-chat-threads.json")), false);

const mergeApply = run([
  "--apply",
  "--application-support-root",
  mergeSupport,
  "--receipt",
  mergeReceipt,
]);
assert.equal(mergeApply.status, 0, mergeApply.stderr);
const merged = JSON.parse(
  fs.readFileSync(path.join(mergeCanonical, "native-chat-threads.json"), "utf8"),
);
assert.equal(merged.updatedAt, nestedChat.updatedAt);
assert.deepEqual(merged.projects.map(({ id }) => id), ["legacy-project"]);
assert.deepEqual(merged.threads.map(({ id }) => id), ["standalone-new"]);
assert.equal(merged.projects[0].threads[0].messages[0].text, "old");
assert.equal(merged.threads[0].messages[0].text, "new");
assert.equal(JSON.parse(fs.readFileSync(mergeReceipt, "utf8")).mergeCount, 1);
assert.equal(fs.existsSync(path.join(mergeNested, "native-chat-threads.json")), true);
assert.equal(fs.existsSync(path.join(mergeCompact, "native-chat-threads.json")), true);

const rollbackSupport = path.join(fixture, "Rollback Application Support");
const rollbackCanonical = path.join(rollbackSupport, "Tatwo Ultrawork");
const rollbackNested = path.join(rollbackCanonical, "TatwoUltrawork");
const rollbackReceipt = path.join(fixture, "rollback-receipt.json");
fs.mkdirSync(rollbackNested, { recursive: true });
fs.writeFileSync(path.join(rollbackNested, "preserve.json"), "{\"source\":true}\n");
const rollbackApply = run([
  "--apply",
  "--application-support-root",
  rollbackSupport,
  "--receipt",
  rollbackReceipt,
], {
  NODE_ENV: "test",
  TATWO_TEST_FAIL_COMPLETED_RECEIPT_RENAME: "1",
});
assert.notEqual(rollbackApply.status, 0);
assert.equal(fs.existsSync(path.join(rollbackCanonical, "preserve.json")), false);
assert.equal(
  fs.readFileSync(path.join(rollbackNested, "preserve.json"), "utf8"),
  "{\"source\":true}\n",
);
assert.equal(
  JSON.parse(fs.readFileSync(rollbackReceipt, "utf8")).outcome,
  "failed_rolled_back",
);
assert.equal(
  JSON.parse(fs.readFileSync(rollbackReceipt, "utf8")).rollbackFailureCount,
  0,
);
assert.equal(
  fs.readdirSync(path.dirname(rollbackReceipt))
    .some((name) => name.startsWith(`${path.basename(rollbackReceipt)}.tatwo-receipt-`)),
  false,
);

const linkedRollbackSupport = path.join(fixture, "Linked Rollback Application Support");
const linkedRollbackCanonical = path.join(linkedRollbackSupport, "Tatwo Ultrawork");
const linkedRollbackNested = path.join(linkedRollbackCanonical, "TatwoUltrawork");
const linkedRollbackReceipt = path.join(fixture, "linked-rollback-receipt.json");
fs.mkdirSync(linkedRollbackNested, { recursive: true });
fs.writeFileSync(path.join(linkedRollbackNested, "preserve.json"), "{\"source\":true}\n");
const linkedRollbackApply = run([
  "--apply",
  "--application-support-root",
  linkedRollbackSupport,
  "--receipt",
  linkedRollbackReceipt,
], {
  NODE_ENV: "test",
  TATWO_TEST_FAIL_MIGRATION_TEMP_UNLINK: "1",
});
assert.notEqual(linkedRollbackApply.status, 0);
assert.equal(fs.existsSync(path.join(linkedRollbackCanonical, "preserve.json")), false);
assert.equal(
  fs.readdirSync(linkedRollbackCanonical)
    .some((name) => name.startsWith("preserve.json.tatwo-migration-")),
  false,
);
assert.equal(
  JSON.parse(fs.readFileSync(linkedRollbackReceipt, "utf8")).outcome,
  "failed_rolled_back",
);

const failedCleanupSupport = path.join(fixture, "Failed Cleanup Application Support");
const failedCleanupCanonical = path.join(failedCleanupSupport, "Tatwo Ultrawork");
const failedCleanupNested = path.join(failedCleanupCanonical, "TatwoUltrawork");
const failedCleanupReceipt = path.join(fixture, "failed-cleanup-receipt.json");
fs.mkdirSync(failedCleanupNested, { recursive: true });
fs.writeFileSync(path.join(failedCleanupNested, "preserve.json"), "{\"source\":true}\n");
const failedCleanupApply = run([
  "--apply",
  "--application-support-root",
  failedCleanupSupport,
  "--receipt",
  failedCleanupReceipt,
], {
  NODE_ENV: "test",
  TATWO_TEST_FAIL_COMPLETED_RECEIPT_RENAME: "1",
  TATWO_TEST_FAIL_ROLLBACK_KIND: "destination",
});
assert.notEqual(failedCleanupApply.status, 0);
assert.equal(fs.existsSync(path.join(failedCleanupCanonical, "preserve.json")), true);
const failedCleanupResult = JSON.parse(fs.readFileSync(failedCleanupReceipt, "utf8"));
assert.equal(failedCleanupResult.outcome, "rollback_failed");
assert.ok(failedCleanupResult.rollbackFailureCount > 0);
assert.ok(failedCleanupResult.rollbackErrorKinds.includes("path_still_exists"));
fs.unlinkSync(path.join(failedCleanupCanonical, "preserve.json"));

const failedReceiptCleanupSupport = path.join(
  fixture,
  "Failed Receipt Cleanup Application Support",
);
const failedReceiptCleanupCanonical = path.join(
  failedReceiptCleanupSupport,
  "Tatwo Ultrawork",
);
const failedReceiptCleanupNested = path.join(
  failedReceiptCleanupCanonical,
  "TatwoUltrawork",
);
const failedReceiptCleanupReceipt = path.join(
  fixture,
  "failed-receipt-cleanup-receipt.json",
);
fs.mkdirSync(failedReceiptCleanupNested, { recursive: true });
fs.writeFileSync(
  path.join(failedReceiptCleanupNested, "preserve.json"),
  "{\"source\":true}\n",
);
const failedReceiptCleanupApply = run([
  "--apply",
  "--application-support-root",
  failedReceiptCleanupSupport,
  "--receipt",
  failedReceiptCleanupReceipt,
], {
  NODE_ENV: "test",
  TATWO_TEST_FAIL_COMPLETED_RECEIPT_RENAME: "1",
  TATWO_TEST_FAIL_ROLLBACK_KIND: "receipt_temporary",
});
assert.notEqual(failedReceiptCleanupApply.status, 0);
assert.equal(fs.existsSync(path.join(failedReceiptCleanupCanonical, "preserve.json")), false);
const failedReceiptCleanupResult = JSON.parse(
  fs.readFileSync(failedReceiptCleanupReceipt, "utf8"),
);
assert.equal(failedReceiptCleanupResult.outcome, "rollback_failed");
assert.ok(
  failedReceiptCleanupResult.rollbackErrorKinds.includes("path_still_exists"),
);
for (const name of fs.readdirSync(path.dirname(failedReceiptCleanupReceipt))) {
  if (name.startsWith(`${path.basename(failedReceiptCleanupReceipt)}.tatwo-receipt-`)) {
    fs.unlinkSync(path.join(path.dirname(failedReceiptCleanupReceipt), name));
  }
}

const conflictingThread = structuredClone(compactChat);
conflictingThread.projects = [];
conflictingThread.threads = [{
  ...nestedChat.threads[0],
  title: "same ID but different content",
}];
fs.writeFileSync(
  path.join(mergeCompact, "native-chat-threads.json"),
  `${JSON.stringify(conflictingThread)}\n`,
);
fs.unlinkSync(path.join(mergeCanonical, "native-chat-threads.json"));
const conflict = run(["--application-support-root", mergeSupport]);
assert.notEqual(conflict.status, 0);
assert.match(conflict.stderr, /migration conflict/);
assert.match(conflict.stdout, /same logical ID contains different records/);

const unsupported = structuredClone(compactChat);
unsupported.schemaVersion = 2;
fs.writeFileSync(
  path.join(mergeCompact, "native-chat-threads.json"),
  `${JSON.stringify(unsupported)}\n`,
);
const unsupportedConflict = run(["--application-support-root", mergeSupport]);
assert.notEqual(unsupportedConflict.status, 0);
assert.match(unsupportedConflict.stdout, /unsupported schemaVersion/);

const unknownTopLevel = structuredClone(compactChat);
unknownTopLevel.futureData = { mustNotBeDropped: true };
fs.writeFileSync(
  path.join(mergeCompact, "native-chat-threads.json"),
  `${JSON.stringify(unknownTopLevel)}\n`,
);
const unknownFieldConflict = run(["--application-support-root", mergeSupport]);
assert.notEqual(unknownFieldConflict.status, 0);
assert.match(unknownFieldConflict.stdout, /unknown top-level fields/);

const duplicatePlacement = structuredClone(compactChat);
duplicatePlacement.projects[0].threads[0].id = nestedChat.threads[0].id;
duplicatePlacement.projects[0].threads[0].title = nestedChat.threads[0].title;
duplicatePlacement.projects[0].threads[0].messages = nestedChat.threads[0].messages;
fs.writeFileSync(
  path.join(mergeCompact, "native-chat-threads.json"),
  `${JSON.stringify(duplicatePlacement)}\n`,
);
const duplicatePlacementConflict = run(["--application-support-root", mergeSupport]);
assert.notEqual(duplicatePlacementConflict.status, 0);
assert.match(duplicatePlacementConflict.stdout, /appears in more than one container/);

function run(args, environment = {}) {
  return spawnSync(process.execPath, [script, ...args], {
    cwd: root,
    encoding: "utf8",
    env: {
      ...process.env,
      ...environment,
    },
  });
}
