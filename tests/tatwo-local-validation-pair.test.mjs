#!/usr/bin/env node

import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const script = path.join(root, "scripts", "tatwo-local-validation-pair.mjs");
const fixture = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-local-validation-pair-"));
const miniPath = writeReceipt("mac-mini", "fingerprint-mini");
const bookPath = writeReceipt("macbook", "fingerprint-book");

const paired = spawnSync(process.execPath, [
  script,
  "--mini",
  miniPath,
  "--book",
  bookPath,
], { cwd: root, encoding: "utf8" });
assert.equal(paired.status, 0, paired.stderr);
const pairedReceipt = JSON.parse(paired.stdout);
assert.equal(pairedReceipt.schema, "TatwoDualDeviceValidationReceiptV1");
assert.equal(pairedReceipt.candidateOutcome, "passed");
assert.equal(pairedReceipt.devices.length, 2);
assert.equal(pairedReceipt.productionPromotionGranted, false);

const duplicatePath = writeReceipt("macbook", "fingerprint-mini", "book-duplicate.json");
const duplicate = spawnSync(process.execPath, [
  script,
  "--mini",
  miniPath,
  "--book",
  duplicatePath,
], { cwd: root, encoding: "utf8" });
assert.equal(duplicate.status, 2);
assert.match(duplicate.stderr, /physical_device_fingerprint_not_distinct/);

function writeReceipt(label, fingerprint, name = `${label}.json`) {
  const target = path.join(fixture, name);
  const receipt = {
    schema: "TatwoLocalValidationReceiptV1",
    receiptScope: "single_physical_device",
    validationPairID: "pair-123",
    outcome: "device_passed",
    candidateOutcome: "pending_peer_device",
    source: { commit: "a".repeat(40), tree: "b".repeat(40) },
    host: { deviceLabel: label, fingerprintSHA256: fingerprint },
    protectedMutations: {
      verified: true,
      applicationsDirectoryWrites: 0,
      formalAppLaunches: 0,
      realUserDataMigrationApplies: 0,
      launchAgentWrites: 0,
      authSessionTokenReads: 0,
      authSessionTokenWrites: 0,
      domainAuthorityTransfers: 0,
    },
  };
  fs.writeFileSync(target, `${JSON.stringify(receipt, null, 2)}\n`);
  const digest = crypto.createHash("sha256").update(fs.readFileSync(target)).digest("hex");
  fs.writeFileSync(`${target}.sha256`, `${digest}  ${path.basename(target)}\n`);
  return target;
}
