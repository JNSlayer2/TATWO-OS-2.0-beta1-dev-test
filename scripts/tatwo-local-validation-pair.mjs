#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const args = parseArgs(process.argv.slice(2));
const miniPath = requiredPath(args.mini, "--mini");
const bookPath = requiredPath(args.book, "--book");
const mini = readAnchoredReceipt(miniPath);
const book = readAnchoredReceipt(bookPath);

for (const [label, entry] of [["mac-mini", mini], ["macbook", book]]) {
  const receipt = entry.receipt;
  if (
    receipt.schema !== "TatwoLocalValidationReceiptV1"
    || receipt.receiptScope !== "single_physical_device"
    || receipt.outcome !== "device_passed"
    || receipt.candidateOutcome !== "pending_peer_device"
    || receipt.protectedMutations?.verified !== true
  ) {
    fail(`invalid_device_receipt:${label}`);
  }
  for (const key of [
    "applicationsDirectoryWrites",
    "formalAppLaunches",
    "realUserDataMigrationApplies",
    "launchAgentWrites",
    "authSessionTokenReads",
    "authSessionTokenWrites",
    "domainAuthorityTransfers",
  ]) {
    if (receipt.protectedMutations[key] !== 0) {
      fail(`protected_mutation_not_zero:${label}:${key}`);
    }
  }
}

if (
  mini.receipt.validationPairID !== book.receipt.validationPairID
  || mini.receipt.source?.commit !== book.receipt.source?.commit
  || mini.receipt.source?.tree !== book.receipt.source?.tree
) {
  fail("device_receipt_source_mismatch");
}
if (
  !mini.receipt.host?.fingerprintSHA256
  || mini.receipt.host.fingerprintSHA256 === book.receipt.host?.fingerprintSHA256
) {
  fail("physical_device_fingerprint_not_distinct");
}

const result = {
  schema: "TatwoDualDeviceValidationReceiptV1",
  observedAt: new Date().toISOString(),
  candidateOutcome: "passed",
  validationPairID: mini.receipt.validationPairID,
  source: {
    commit: mini.receipt.source.commit,
    tree: mini.receipt.source.tree,
  },
  devices: [
    deviceProjection("mac-mini", mini),
    deviceProjection("macbook", book),
  ],
  githubRole: "private_backup_only",
  productionPromotionGranted: false,
  remainingProductionGates: [
    "developer_id_and_notarization",
    "signed_appcast",
    "stable_installer_macos_vm_receipt",
    "human_production_approval",
  ],
};

if (args.out) {
  const outputPath = path.resolve(String(args.out));
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, `${JSON.stringify(result, null, 2)}\n`, { flag: "wx" });
  const digest = sha256File(outputPath);
  fs.writeFileSync(
    `${outputPath}.sha256`,
    `${digest}  ${path.basename(outputPath)}\n`,
    { flag: "wx" },
  );
  process.stdout.write(`${JSON.stringify({
    ok: true,
    outputPath,
    receiptSHA256: digest,
    candidateOutcome: result.candidateOutcome,
  }, null, 2)}\n`);
} else {
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

function deviceProjection(expectedLabel, entry) {
  return {
    expectedLabel,
    reportedLabel: entry.receipt.host.deviceLabel,
    fingerprintSHA256: entry.receipt.host.fingerprintSHA256,
    receiptSHA256: entry.digest,
    deviceOutcome: entry.receipt.outcome,
  };
}

function readAnchoredReceipt(target) {
  const resolved = path.resolve(target);
  const digest = sha256File(resolved);
  const anchorPath = `${resolved}.sha256`;
  if (!fs.existsSync(anchorPath)) fail(`receipt_anchor_missing:${path.basename(resolved)}`);
  const anchoredDigest = fs.readFileSync(anchorPath, "utf8").trim().split(/\s+/)[0];
  if (anchoredDigest !== digest) fail(`receipt_anchor_mismatch:${path.basename(resolved)}`);
  return {
    receipt: JSON.parse(fs.readFileSync(resolved, "utf8")),
    digest,
  };
}

function requiredPath(value, flag) {
  if (!value) fail(`missing_required_argument:${flag}`);
  return path.resolve(String(value));
}

function sha256File(target) {
  return crypto.createHash("sha256").update(fs.readFileSync(target)).digest("hex");
}

function fail(message) {
  process.stderr.write(`${JSON.stringify({
    ok: false,
    candidateOutcome: "failed",
    errorKind: message,
  }, null, 2)}\n`);
  process.exit(2);
}

function parseArgs(argv) {
  const out = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (!arg.startsWith("--")) continue;
    const equals = arg.indexOf("=");
    if (equals >= 0) out[arg.slice(2, equals)] = arg.slice(equals + 1);
    else out[arg.slice(2)] = argv[index + 1] && !argv[index + 1].startsWith("--")
      ? argv[++index]
      : true;
  }
  return out;
}
