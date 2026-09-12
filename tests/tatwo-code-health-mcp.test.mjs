#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

test("tatwo code-health MCP", async t => {
const gitCapabilityProbe = spawnSync("git", ["--version"], {
  cwd: repoRoot,
  encoding: "utf8",
});
if (
  gitCapabilityProbe.status === null &&
  ["ENOENT", "EACCES", "EPERM"].includes(gitCapabilityProbe.error?.code)
) {
  t.skip(
    "sandbox 禁止 git，非程式缺陷" +
      `（git --version 無法執行，status=${String(gitCapabilityProbe.status)}）`,
  );
  return;
}
assert.equal(
  gitCapabilityProbe.error,
  undefined,
  `git --version probe failed unexpectedly: ${gitCapabilityProbe.error?.message}`,
);
assert.equal(
  gitCapabilityProbe.status,
  0,
  `git --version exited non-zero: ${gitCapabilityProbe.stderr || gitCapabilityProbe.stdout}`,
);

const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "tatwo-code-health-mcp-"));
const fixtureRoot = path.join(tempRoot, "fixture");
const cleanFixtureRoot = path.join(tempRoot, "clean-fixture");
const stateDir = path.join(tempRoot, "state");
const fixtureScript = path.join(fixtureRoot, "scripts", "observe.sh");

process.env.TATWO_CODE_HEALTH_ALLOWED_ROOTS = [fixtureRoot, cleanFixtureRoot].join(path.delimiter);
process.env.TATWO_SECURITY_STATE_DIR = stateDir;

const { codeHealthMCPToolResult, runCodeHealthScanTool } = await import(
  path.join(repoRoot, "scripts", "tatwo-ultrawork-mcp.mjs")
);
process.stdin.pause();

function jsonlRows(text) {
  return text
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)
    .map(line => JSON.parse(line));
}

const COVERAGE_FRESHNESS_ENV = "TATWO_COVERAGE_MAX_COMMIT_LAG";
const DEFAULT_COVERAGE_MAX_COMMIT_LAG = 25;

function systemGit(args, cwd = repoRoot) {
  return spawnSync("git", args, {
    cwd,
    encoding: "utf8",
  });
}

function coverageMaxCommitLag(value = process.env[COVERAGE_FRESHNESS_ENV]) {
  if (value == null) return DEFAULT_COVERAGE_MAX_COMMIT_LAG;
  if (!/^\d+$/.test(value)) {
    throw new Error(`${COVERAGE_FRESHNESS_ENV} must be a non-negative integer`);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) {
    throw new Error(`${COVERAGE_FRESHNESS_ENV} must be a safe integer`);
  }
  return parsed;
}

function validateCoverageRevision(
  revisionCell,
  {
    git = systemGit,
    cwd = repoRoot,
    maxLag = coverageMaxCommitLag(),
  } = {},
) {
  assert.equal(typeof revisionCell, "string", "coverage revision field is missing");
  const match = revisionCell.match(/^`([0-9a-f]{40})\/([0-9a-f]{40})`$/);
  assert.ok(
    match,
    "coverage revision must use strict `<40-hex commit>/<40-hex tree>` format",
  );
  const [, commit, recordedTree] = match;

  const commitExists = git(["cat-file", "-e", `${commit}^{commit}`], cwd);
  assert.equal(
    commitExists.status,
    0,
    `coverage revision commit does not exist: ${commit}`,
  );

  const treeResult = git(["rev-parse", `${commit}^{tree}`], cwd);
  assert.equal(treeResult.status, 0, treeResult.stderr);
  const actualTree = treeResult.stdout.trim();
  assert.equal(
    recordedTree,
    actualTree,
    `coverage revision tree must match commit ${commit}`,
  );

  const headResult = git(["rev-parse", "HEAD"], cwd);
  assert.equal(headResult.status, 0, headResult.stderr);
  const head = headResult.stdout.trim();

  const ancestorResult = git(["merge-base", "--is-ancestor", commit, head], cwd);
  assert.notEqual(
    ancestorResult.status,
    1,
    `coverage revision ${commit} is not an ancestor of HEAD ${head}`,
  );
  assert.equal(ancestorResult.status, 0, ancestorResult.stderr);

  const lagResult = git(["rev-list", "--count", `${commit}..${head}`], cwd);
  assert.equal(lagResult.status, 0, lagResult.stderr);
  assert.match(lagResult.stdout.trim(), /^\d+$/, "coverage revision lag must be an integer");
  const lag = Number(lagResult.stdout.trim());
  assert.ok(
    lag <= maxLag,
    `coverage revision is ${lag} commits behind HEAD (limit ${maxLag}); ` +
      "請重跑 `tatwo-code-health` 更新覆蓋率矩陣",
  );

  return {
    commit,
    tree: recordedTree,
    head,
    lag,
    maxLag,
    message:
      `coverage freshness: ${lag} commits behind HEAD ` +
      `(limit ${maxLag}; ${COVERAGE_FRESHNESS_ENV})`,
  };
}

function runChildScan({ root, state }) {
  const source = [
    `import { runCodeHealthScanTool } from ${JSON.stringify(path.join(repoRoot, "scripts", "tatwo-ultrawork-mcp.mjs"))};`,
    `const result = runCodeHealthScanTool({ root: ${JSON.stringify(root)}, rules: ["CH-02"], jsonOnly: true });`,
    `process.stdin.pause();`,
    `console.log(JSON.stringify(result.summary));`,
  ].join("\n");
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ["--input-type=module", "-e", source], {
      cwd: repoRoot,
      env: {
        ...process.env,
        TATWO_CODE_HEALTH_ALLOWED_ROOTS: root,
        TATWO_SECURITY_STATE_DIR: state,
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", chunk => { stdout += chunk; });
    child.stderr.on("data", chunk => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", code => {
      if (code !== 0) {
        reject(new Error(`child scan failed (${code}): ${stderr || stdout}`));
        return;
      }
      resolve(JSON.parse(stdout.trim()));
    });
  });
}

function runHarnessList(state) {
  const result = spawnSync(
    process.execPath,
    [path.join(repoRoot, "scripts", "tatwo-security-findings.mjs"), "list"],
    {
      cwd: repoRoot,
      env: { ...process.env, TATWO_SECURITY_STATE_DIR: state },
      encoding: "utf8",
    },
  );
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}

function runChildHarnessMark({ state, id, status, scan }) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      process.execPath,
      [
        path.join(repoRoot, "scripts", "tatwo-security-findings.mjs"),
        "mark",
        id,
        status,
        "--scan",
        scan,
        "--verified-by",
        "external-test-marker",
      ],
      {
        cwd: repoRoot,
        env: { ...process.env, TATWO_SECURITY_STATE_DIR: state },
        stdio: ["ignore", "pipe", "pipe"],
      },
    );
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", chunk => { stdout += chunk; });
    child.stderr.on("data", chunk => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", code => {
      if (code !== 0) {
        reject(new Error(`child mark failed (${code}): ${stderr || stdout}`));
        return;
      }
      resolve(JSON.parse(stdout.trim()));
    });
  });
}

try {
  await fs.mkdir(path.dirname(fixtureScript), { recursive: true });
  await fs.mkdir(path.join(cleanFixtureRoot, "scripts"), { recursive: true });
  await fs.writeFile(path.join(cleanFixtureRoot, "scripts", "clean.sh"), "#!/bin/sh\nexit 0\n", "utf8");
  await fs.writeFile(
    fixtureScript,
    [
      "#!/bin/sh",
      "swift test 2>&1 > test.log",
      "",
    ].join("\n"),
    "utf8",
  );

  const first = runCodeHealthScanTool({
    root: fixtureRoot,
    rules: ["CH-02"],
    jsonOnly: true,
  });
  assert.equal(first.ok, true);
  assert.equal(first.readOnlyScan, true);
  assert.deepEqual(first.rules, ["CH-02"]);
  assert.equal(first.summary.byRule["CH-02"], 1);
  assert.equal(first.summary.added, 1);
  assert.equal(first.summary.resolved, 0);
  assert.equal(
    path.dirname(first.findingsPath),
    path.join(await fs.realpath(stateDir), "scans"),
  );

  const firstScan = JSON.parse(await fs.readFile(first.findingsPath, "utf8"));
  assert.equal(firstScan.schema, "TatwoSecurityScanV1");
  assert.equal(firstScan.revisionStamp.verificationDepth, "read-only");
  assert.equal(firstScan.revisionStamp.testOnly, true);
  assert.equal(firstScan.revisionStamp.bindingClass, "fixture-unbound");
  assert.notEqual(firstScan.revisionStamp.schema, "TatwoReviewRevisionStampV2");
  assert.equal(firstScan.findings.length, 1);
  assert.equal(firstScan.findings[0].ruleId, "CH-02");

  const journalPath = path.join(stateDir, "findings.jsonl");
  const afterFirst = jsonlRows(await fs.readFile(journalPath, "utf8"));
  assert.equal(afterFirst.length, 1);
  assert.equal(afterFirst[0].status, "open");

  const otherRoot = runCodeHealthScanTool({
    root: cleanFixtureRoot,
    rules: ["CH-02"],
  });
  assert.equal(otherRoot.summary.total, 0);
  assert.equal(otherRoot.summary.resolved, 0);
  assert.equal(jsonlRows(await fs.readFile(journalPath, "utf8")).at(-1).status, "open");

  const secondEnvelope = codeHealthMCPToolResult({
    root: fixtureRoot,
    rules: "CH-02",
    jsonOnly: true,
  });
  assert.equal(secondEnvelope.isError, false);
  assert.equal(secondEnvelope.content[0].type, "text");
  assert.doesNotMatch(secondEnvelope.content[0].text, /\n/);
  const second = JSON.parse(secondEnvelope.content[0].text);
  assert.equal(second.summary.added, 0);
  assert.equal(second.summary.carriedOpen, 1);
  const afterSecond = jsonlRows(await fs.readFile(journalPath, "utf8"));
  assert.equal(
    afterSecond.length,
    1,
    "same revision/ruleset rescan must not append a duplicate open finding",
  );

  const findingID = afterSecond[0].id;
  const harness = path.join(repoRoot, "scripts", "tatwo-security-findings.mjs");
  const markAccepted = spawnSync(
    process.execPath,
    [harness, "mark", findingID, "accepted", "--scan", "human-adjudication", "--verified-by", "test-human"],
    {
      cwd: repoRoot,
      env: { ...process.env, TATWO_SECURITY_STATE_DIR: stateDir },
      encoding: "utf8",
    },
  );
  assert.equal(markAccepted.status, 0, markAccepted.stderr);
  const acceptedEnvelope = codeHealthMCPToolResult({
    root: fixtureRoot,
    rules: ["CH-02"],
  });
  assert.equal(acceptedEnvelope.isError, false);
  const acceptedScan = JSON.parse(acceptedEnvelope.content[0].text);
  assert.equal(acceptedScan.summary.adjudicated, 1);
  assert.equal(acceptedScan.summary.reopened, 0);
  const afterAccepted = jsonlRows(await fs.readFile(journalPath, "utf8"));
  assert.equal(afterAccepted.at(-1).status, "accepted");

  const markFalsePositive = spawnSync(
    process.execPath,
    [harness, "mark", findingID, "false_positive", "--scan", "human-adjudication-2", "--verified-by", "test-human"],
    {
      cwd: repoRoot,
      env: { ...process.env, TATWO_SECURITY_STATE_DIR: stateDir },
      encoding: "utf8",
    },
  );
  assert.equal(markFalsePositive.status, 0, markFalsePositive.stderr);
  const falsePositiveScan = JSON.parse(
    codeHealthMCPToolResult({ root: fixtureRoot, rules: ["CH-02"] }).content[0].text,
  );
  assert.equal(falsePositiveScan.summary.adjudicated, 1);
  assert.equal(falsePositiveScan.summary.reopened, 0);
  assert.equal(
    jsonlRows(await fs.readFile(journalPath, "utf8")).at(-1).status,
    "false_positive",
  );

  const markOpen = spawnSync(
    process.execPath,
    [harness, "mark", findingID, "open", "--scan", "human-reopen", "--verified-by", "test-human"],
    {
      cwd: repoRoot,
      env: { ...process.env, TATWO_SECURITY_STATE_DIR: stateDir },
      encoding: "utf8",
    },
  );
  assert.equal(markOpen.status, 0, markOpen.stderr);

  await fs.writeFile(fixtureScript, "#!/bin/sh\nswift test > test.log 2>&1\n", "utf8");
  const third = runCodeHealthScanTool({
    root: fixtureRoot,
    rules: ["CH-02"],
  });
  assert.equal(third.summary.total, 0);
  assert.equal(third.summary.resolved, 1);
  const afterThird = jsonlRows(await fs.readFile(journalPath, "utf8"));
  assert.equal(afterThird.length, 5);
  assert.equal(afterThird.at(-1).status, "fixed");
  assert.match(afterThird.at(-1).previousRecordHash, /^[a-f0-9]{64}$/);
  assert.equal(
    afterThird.at(-1).revision,
    afterFirst[0].revision,
    "harness mark preserves the finding's initial revision; scan record owns current revision truth",
  );
  assert.deepEqual(runHarnessList(stateDir).forkedIds, []);

  const rejected = codeHealthMCPToolResult({
    root: "/etc",
    rules: ["CH-02"],
    jsonOnly: true,
  });
  assert.equal(rejected.isError, true);
  assert.equal(rejected.content[0].type, "text");
  const rejectedBody = JSON.parse(rejected.content[0].text);
  assert.equal(rejectedBody.ok, false);
  assert.equal(rejectedBody.status, "failed");
  assert.match(rejectedBody.error, /outside repository\/injected allowlist/);

  const invalidType = codeHealthMCPToolResult({ root: 42, rules: ["CH-02"] });
  assert.equal(invalidType.isError, true);
  assert.match(JSON.parse(invalidType.content[0].text).error, /root must be a string/);

  const concurrentState = path.join(tempRoot, "concurrent-state");
  await fs.writeFile(fixtureScript, "#!/bin/sh\nswift test 2>&1 > test.log\n", "utf8");
  const concurrent = await Promise.all([
    runChildScan({ root: fixtureRoot, state: concurrentState }),
    runChildScan({ root: fixtureRoot, state: concurrentState }),
  ]);
  assert.deepEqual(
    concurrent.map(summary => summary.added).sort(),
    [0, 1],
    "outer reconciliation lock must serialize same-id add decisions",
  );
  assert.equal(
    jsonlRows(await fs.readFile(path.join(concurrentState, "findings.jsonl"), "utf8")).length,
    1,
    "concurrent identical scans must persist exactly one initial finding row",
  );
  assert.deepEqual(runHarnessList(concurrentState).forkedIds, []);

  const transitionState = path.join(tempRoot, "transition-state");
  const transitionFinding = firstScan.findings[0];
  const transitionSeed = spawnSync(
    process.execPath,
    [harness, "add", "--json", JSON.stringify(transitionFinding)],
    {
      cwd: repoRoot,
      env: { ...process.env, TATWO_SECURITY_STATE_DIR: transitionState },
      encoding: "utf8",
    },
  );
  assert.equal(transitionSeed.status, 0, transitionSeed.stderr);
  const transitionFixed = spawnSync(
    process.execPath,
    [
      harness,
      "mark",
      transitionFinding.id,
      "fixed",
      "--scan",
      "transition-seed-fixed",
      "--verified-by",
      "test-human",
    ],
    {
      cwd: repoRoot,
      env: { ...process.env, TATWO_SECURITY_STATE_DIR: transitionState },
      encoding: "utf8",
    },
  );
  assert.equal(transitionFixed.status, 0, transitionFixed.stderr);
  const transitionResults = await Promise.all([
    runChildScan({ root: fixtureRoot, state: transitionState }),
    runChildHarnessMark({
      state: transitionState,
      id: transitionFinding.id,
      status: "accepted",
      scan: "external-mark-race",
    }),
  ]);
  assert.equal(transitionResults.length, 2);
  const transitionList = runHarnessList(transitionState);
  assert.deepEqual(transitionList.forkedIds, []);
  assert.ok(
    ["open", "accepted"].includes(transitionList.findings[0].status),
    "serialized mark race may end in either valid adjudicated state",
  );

  const coverageFixtureRoot = path.join(tempRoot, "coverage-git-fixture");
  await fs.mkdir(coverageFixtureRoot, { recursive: true });
  const fixtureGit = args => {
    const result = systemGit(args, coverageFixtureRoot);
    assert.equal(
      result.status,
      0,
      `fixture git ${args.join(" ")} failed: ${result.stderr || result.stdout}`,
    );
    return result.stdout.trim();
  };
  fixtureGit(["init", "--quiet", "--initial-branch=main"]);
  fixtureGit(["config", "user.name", "Tatwo Coverage Fixture"]);
  fixtureGit(["config", "user.email", "coverage-fixture@example.invalid"]);
  const fixtureCommits = [];
  for (let index = 0; index <= 26; index += 1) {
    await fs.writeFile(
      path.join(coverageFixtureRoot, "revision.txt"),
      `fixture revision ${index}\n`,
      "utf8",
    );
    fixtureGit(["add", "revision.txt"]);
    fixtureGit(["commit", "--quiet", "-m", `fixture revision ${index}`]);
    fixtureCommits.push(fixtureGit(["rev-parse", "HEAD"]));
  }

  const fixtureHead = fixtureCommits.at(-1);
  const ancestorNPlusOneCommit = fixtureCommits[0];
  const ancestorWithinCommit = fixtureCommits[1];
  const ancestorNPlusOneTree = fixtureGit([
    "rev-parse",
    `${ancestorNPlusOneCommit}^{tree}`,
  ]);
  const ancestorWithinTree = fixtureGit([
    "rev-parse",
    `${ancestorWithinCommit}^{tree}`,
  ]);
  fixtureGit(["checkout", "--quiet", "--detach", ancestorNPlusOneCommit]);
  await fs.writeFile(
    path.join(coverageFixtureRoot, "fork.txt"),
    "non-ancestor fixture\n",
    "utf8",
  );
  fixtureGit(["add", "fork.txt"]);
  fixtureGit(["commit", "--quiet", "-m", "non-ancestor fixture"]);
  const nonAncestorCommit = fixtureGit(["rev-parse", "HEAD"]);
  const nonAncestorTree = fixtureGit(["rev-parse", "HEAD^{tree}"]);
  fixtureGit(["checkout", "--quiet", "--detach", fixtureHead]);

  const maxLag = 25;

  assert.throws(
    () => validateCoverageRevision(
      `\`${ancestorNPlusOneCommit}/${ancestorNPlusOneTree}\``,
      {
        cwd: coverageFixtureRoot,
        maxLag,
      },
    ),
    /26 commits behind HEAD.*請重跑 `tatwo-code-health` 更新覆蓋率矩陣/,
    "ancestor revision lagging N+1 commits must fail closed",
  );
  const withinLimit = validateCoverageRevision(
    `\`${ancestorWithinCommit}/${ancestorWithinTree}\``,
    { cwd: coverageFixtureRoot, maxLag },
  );
  assert.equal(
    withinLimit.lag,
    maxLag,
    "ancestor revision lagging at most N commits must pass",
  );
  assert.match(
    withinLimit.message,
    /coverage freshness: 25 commits behind HEAD \(limit 25;/,
    "passing coverage validation must report the actual lag",
  );
  assert.throws(
    () => validateCoverageRevision(
      `\`${nonAncestorCommit}/${nonAncestorTree}\``,
      { cwd: coverageFixtureRoot, maxLag },
    ),
    /is not an ancestor of HEAD/,
    "non-ancestor coverage revision must fail closed",
  );
  assert.throws(
    () => validateCoverageRevision(undefined, { cwd: coverageFixtureRoot, maxLag }),
    /coverage revision field is missing/,
    "missing coverage revision field must fail closed",
  );
  assert.throws(
    () => validateCoverageRevision("`not-a-commit/not-a-tree`", {
      cwd: coverageFixtureRoot,
      maxLag,
    }),
    /strict `<40-hex commit>\/<40-hex tree>` format/,
    "malformed coverage revision field must fail closed",
  );
  assert.throws(
    () => coverageMaxCommitLag(""),
    /must be a non-negative integer/,
    "an explicitly empty freshness override must fail closed",
  );
  assert.equal(
    coverageMaxCommitLag("7"),
    7,
    "a valid freshness override must replace the default limit",
  );

  const coverage = await fs.readFile(
    path.join(repoRoot, "docs", "protocol", "SECURITY_COVERAGE_TRACKING.md"),
    "utf8",
  );
  const coverageRow = coverage
    .split(/\r?\n/)
    .find(line => line.startsWith("| Code health（CH-01～CH-06） |"));
  assert.ok(coverageRow, "coverage matrix must carry a code-health facet");
  const coverageCells = coverageRow.split("|").slice(1, -1).map(cell => cell.trim());
  assert.equal(coverageCells.length, 9, "coverage matrix row must keep the nine-column shape");
  assert.equal(coverageCells[2], "`read-only`");
  assert.equal(coverageCells[7], "`partial`");
  const freshness = validateCoverageRevision(coverageCells[3]);
  console.error(freshness.message);
} finally {
  await fs.rm(tempRoot, { recursive: true, force: true });
}

console.log("tatwo-code-health-mcp.test.mjs: ok");
});
