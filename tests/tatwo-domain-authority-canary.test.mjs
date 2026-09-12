#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const output = execFileSync(
  process.execPath,
  [path.join(root, "scripts", "tatwo-domain-authority-canary.mjs")],
  { encoding: "utf8" },
);
const receipt = JSON.parse(output);

assert.equal(receipt.schema, "TatwoDomainAuthorityCanaryReceiptV1");
assert.equal(receipt.status, "passed");
assert.equal(receipt.initialPrimary, "mac-mini");
assert.equal(receipt.finalPrimary, "macbook");
assert.equal(receipt.explicitHumanConfirmationCount, 2);
assert.equal(receipt.automaticElectionCount, 0);
assert.equal(receipt.staleAuthorityWriteRejected, true);
assert.equal(receipt.protectedDataWriteCount, 0);
assert.equal(receipt.updatePlaneCallCount, 0);
assert.equal(receipt.bootstrapPlaneCallCount, 0);
