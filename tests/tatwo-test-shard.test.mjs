import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const script = path.join(root, "scripts", "tatwo-test-shard.mjs");
const tempRoot = fs.mkdtempSync(
  path.join(os.tmpdir(), "tatwo-test-shard-contract-"),
);

function run(args) {
  return spawnSync(process.execPath, [script, ...args], {
    cwd: root,
    encoding: "utf8",
  });
}

try {
  const selftest = run(["--selftest"]);
  assert.equal(selftest.status, 0, selftest.stderr);
  const receipt = JSON.parse(selftest.stdout);
  assert.equal(receipt.schema, "TatwoTestShardSelftestV1");
  assert.equal(receipt.passed, true);
  assert.ok(receipt.checks.every((check) => check.passed));

  const suitesFile = path.join(tempRoot, "suites.txt");
  fs.writeFileSync(suitesFile, "Suite C\nSuite A\nSuite B\nSuite D\n");
  const shardA = run([
    "--suites-file",
    suitesFile,
    "--shards",
    "2",
    "--index",
    "0",
  ]);
  const shardB = run([
    "--suites-file",
    suitesFile,
    "--shards",
    "2",
    "--index",
    "0",
  ]);
  assert.equal(shardA.status, 0, shardA.stderr);
  assert.equal(shardA.stdout, shardB.stdout);
  assert.deepEqual(
    shardA.stdout.trim().split("\n").sort(),
    ["--filter=Suite A", "--filter=Suite C"].sort(),
  );

  const logFile = path.join(tempRoot, "swift-test.log");
  fs.writeFileSync(
    logFile,
    [
      "Test Suite 'slow' started at 2026-01-01 00:00:00.000.",
      "Test Suite 'slow' passed at 2026-01-01 00:00:03.000.",
      "Test Suite 'fast' started at 2026-01-01 00:00:03.000.",
      "Test Suite 'fast' passed at 2026-01-01 00:00:03.100.",
    ].join("\n"),
  );
  const weighted = run([
    "--from-log",
    logFile,
    "--shards",
    "2",
    "--index",
    "1",
    "--verify-partition",
  ]);
  assert.equal(weighted.status, 0, weighted.stderr);
  assert.equal(weighted.stdout.trim(), "--filter=fast");
  assert.match(weighted.stderr, /partition verified: leafUniverse=2/);

  const adversarialLog = path.join(tempRoot, "adversarial.log");
  fs.writeFileSync(
    adversarialLog,
    [
      "Test Suite 'All tests' started at 2026-01-01 00:00:00.000.",
      "  Test Suite 'failed-leaf' failed at 2026-01-01 00:00:01.000.",
      "  Test Suite 'passed-leaf' passed at 2026-01-01 00:00:01.100.",
      "Test Suite 'All tests' passed at 2026-01-01 00:00:01.100.",
    ].join("\n"),
  );
  const adversarial = run([
    "--from-log",
    adversarialLog,
    "--shards",
    "2",
    "--index",
    "0",
    "--verify-partition",
  ]);
  assert.equal(adversarial.status, 0, adversarial.stderr);
  assert.match(adversarial.stderr, /excluded aggregate suites: All tests/);
  assert.doesNotMatch(adversarial.stdout, /All tests/);
  assert.match(adversarial.stdout + run([
    "--from-log",
    adversarialLog,
    "--shards",
    "2",
    "--index",
    "1",
  ]).stdout, /failed-leaf/);

  const emptyFile = path.join(tempRoot, "empty.txt");
  fs.writeFileSync(emptyFile, "\n");
  const empty = run([
    "--suites-file",
    emptyFile,
    "--shards",
    "1",
    "--index",
    "0",
  ]);
  assert.notEqual(empty.status, 0);
  assert.match(empty.stderr, /contains no test suites/);

  const invalidIndex = run([
    "--suites-file",
    suitesFile,
    "--shards",
    "2",
    "--index",
    "2",
  ]);
  assert.notEqual(invalidIndex.status, 0);
  assert.match(invalidIndex.stderr, /less than --shards/);

  console.log("tatwo-test-shard contract tests: PASS");
} finally {
  fs.rmSync(tempRoot, { recursive: true, force: true });
}
