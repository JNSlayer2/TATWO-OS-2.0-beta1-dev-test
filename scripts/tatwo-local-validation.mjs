#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const realHome = os.homedir();
const args = new Set(process.argv.slice(2));
const contract = {
  schema: "TatwoLocalValidationPlanV1",
  authority: "local_dual_device_validation",
  receiptScope: "one_physical_device_per_receipt",
  githubRole: "private_backup_only",
  automaticGitHubHostedRunnerRequired: false,
  githubActionsUsedForValidation: false,
  requiredLayers: [
    "clean_git_checkout",
    "isolated_runtime_roots",
    "macos_sandbox_enforcement",
    "sanitized_environment",
    "all_node_tests",
    "full_swift_tests",
    "staging_bundle",
    "bundle_rollback_smoke",
    "fake_home_host_rehearsal",
    "final_source_seal",
    "independent_receipt_sha256_anchor",
  ],
  macOSVirtualMachine: {
    role: "clean_install_update_migration_and_rollback_sandbox",
    requiredForSourceCandidate: false,
    requiredBeforeStableInstallerPromotion: true,
  },
  deniedActions: [
    "does_not_write_/Applications",
    "does_not_launch_the_formal_app",
    "does_not_apply_real_user_data_migration",
    "does_not_modify_LaunchAgents",
    "does_not_read_or_write_auth_session_token_material",
    "does_not_transfer_domain_authority",
  ],
};

if (args.has("--selftest")) {
  const selftestRoot = path.join(os.tmpdir(), `tatwo-local-validation-selftest-${process.pid}`);
  const fake = {
    fakeHome: path.join(selftestRoot, "home"),
    codexHome: path.join(selftestRoot, "codex"),
    appSupport: path.join(selftestRoot, "app-support"),
    stateRoot: path.join(selftestRoot, "state"),
    tempRoot: path.join(selftestRoot, "tmp"),
    cacheRoot: path.join(selftestRoot, "cache"),
    configRoot: path.join(selftestRoot, "config"),
    moduleCacheRoot: path.join(selftestRoot, "module-cache"),
    swiftScratchRoot: path.join(selftestRoot, "swift-scratch"),
  };
  process.env.TATWO_SELFTEST_SECRET_TOKEN = "must-not-propagate";
  const environment = buildIsolatedEnvironment(fake);
  const checks = [
    selftestCheck("forbid-applications-root", () => assertValidationBaseAllowed("/Applications")),
    selftestCheck("forbid-real-codex-home", () => assertValidationBaseAllowed(path.join(realHome, ".codex"))),
    selftestCheck("forbid-source-root", () => assertValidationBaseAllowed(repoRoot)),
    selftestCheck("empty-node-inventory-fails", () => requireNonEmptyTestInventory([])),
    {
      id: "environment-secret-not-propagated",
      passed: environment.TATWO_SELFTEST_SECRET_TOKEN === undefined,
    },
    {
      id: "environment-home-isolated",
      passed: environment.HOME === fake.fakeHome && environment.CODEX_HOME === fake.codexHome,
    },
  ];
  const passed = checks.every((check) => check.passed);
  process.stdout.write(`${JSON.stringify({
    schema: "TatwoLocalValidationSelftestV1",
    passed,
    checks,
  }, null, 2)}\n`);
  process.exit(passed ? 0 : 1);
}

if (args.has("--plan")) {
  process.stdout.write(`${JSON.stringify(contract, null, 2)}\n`);
  process.exit(0);
}
if (!args.has("--run")) {
  process.stderr.write("error: use --plan for the contract or --run to execute local validation\n");
  process.exit(64);
}

const sourceCommit = git(["rev-parse", "HEAD"]).trim();
const sourceTree = git(["rev-parse", "HEAD^{tree}"]).trim();
const sourceBranch = git(["branch", "--show-current"]).trim();
const sourceStatus = git(["status", "--porcelain=v1", "--untracked-files=all"]).trim();
if (sourceStatus) {
  process.stderr.write("error: local validation requires a clean tracked and untracked checkout\n");
  process.exit(2);
}

const stamp = new Date().toISOString().replaceAll(":", "-");
const validationBase = path.resolve(
  process.env.TATWO_LOCAL_VALIDATION_ROOT
    ?? path.join(os.tmpdir(), "tatwo-local-validation"),
);
assertValidationBaseAllowed(validationBase);
const runRoot = path.join(validationBase, `run-${stamp}-${process.pid}`);
const logsRoot = path.join(runRoot, "logs");
const fakeHome = path.join(runRoot, "home");
const codexHome = path.join(runRoot, "codex-home");
const appSupport = path.join(runRoot, "app-support");
const stateRoot = path.join(runRoot, "state");
const tempRoot = path.join(runRoot, "tmp");
const cacheRoot = path.join(runRoot, "cache");
const configRoot = path.join(runRoot, "config");
const moduleCacheRoot = path.join(runRoot, "module-cache");
const swiftScratchRoot = path.join(runRoot, "swift-scratch");
const stagingSwiftScratchRoot = path.join(runRoot, "staging-swift-scratch");
const stagingRoot = path.join(runRoot, "staging");
const safeBundleRoot = path.join(runRoot, "safe-bundle-smoke");
const hostRehearsalRoot = path.join(runRoot, "host-rehearsal");
const receiptPath = path.join(runRoot, "local-validation-receipt.json");
const receiptAnchorPath = `${receiptPath}.sha256`;
const sandboxProfilePath = path.join(runRoot, "local-validation.sb");
fs.mkdirSync(logsRoot, { recursive: true });
for (const target of [
  fakeHome,
  codexHome,
  appSupport,
  stateRoot,
  tempRoot,
  cacheRoot,
  configRoot,
  moduleCacheRoot,
  swiftScratchRoot,
  stagingSwiftScratchRoot,
]) {
  fs.mkdirSync(target, { recursive: true });
}
writeSandboxProfile(sandboxProfilePath);

const isolatedEnvironment = buildIsolatedEnvironment({
  fakeHome,
  codexHome,
  appSupport,
  stateRoot,
  tempRoot,
  cacheRoot,
  configRoot,
  moduleCacheRoot,
  swiftScratchRoot,
});
const sandboxEvidence = verifySandboxEnforcement({
  profilePath: sandboxProfilePath,
  environment: isolatedEnvironment,
  runRoot,
});
const hostFingerprint = readHostFingerprint();
const validationPairID = sha256Text(
  `TatwoLocalValidationPairV1:${sourceCommit}`,
).slice(0, 24);

const receipt = {
  schema: "TatwoLocalValidationReceiptV1",
  receiptScope: "single_physical_device",
  validationPairID,
  observedAt: new Date().toISOString(),
  outcome: "in_progress",
  candidateOutcome: "pending_local_device",
  source: {
    commit: sourceCommit,
    tree: sourceTree,
    branch: sourceBranch,
    clean: true,
  },
  host: {
    platform: process.platform,
    architecture: process.arch,
    deviceLabel: process.env.TATWO_VALIDATION_DEVICE_LABEL ?? "local-mac",
    fingerprintSHA256: hostFingerprint,
  },
  contract,
  runRoot,
  sandboxEnforcement: {
    enforced: sandboxEvidence.passed,
    profileSHA256: sha256File(sandboxProfilePath),
    ...sandboxEvidence,
  },
  checks: [],
  protectedMutations: null,
};
writeJSON(receiptPath, receipt);

try {
  const nodeFiles = fs.readdirSync(path.join(repoRoot, "tests"))
    .filter((name) => name.endsWith(".test.mjs"))
    .sort();
  requireNonEmptyTestInventory(nodeFiles);
  const nodeResults = [];
  for (const name of nodeFiles) {
    const result = run(
      process.execPath,
      [path.join(repoRoot, "tests", name)],
      `node-${name}.log`,
      isolatedEnvironment,
    );
    nodeResults.push({
      file: name,
      exitCode: result.status,
      logSHA256: result.logSHA256,
    });
    if (result.status !== 0) {
      throw new Error(`node_test_failed:${name}`);
    }
  }
  receipt.checks.push({
    id: "all-node-tests",
    passed: true,
    fileCount: nodeResults.length,
    results: nodeResults,
  });

  const swift = run(
    "/usr/bin/env",
    [
      "swift",
      "test",
      "--disable-sandbox",
      "-Xswiftc",
      "-disable-sandbox",
      "--package-path",
      repoRoot,
      "--scratch-path",
      swiftScratchRoot,
    ],
    "swift-test.log",
    isolatedEnvironment,
  );
  if (swift.status !== 0) throw new Error("swift_test_failed");
  const swiftCounts = parseSwiftCounts(swift.output);
  if (swiftCounts.failures !== 0) throw new Error("swift_test_reported_failures");
  receipt.checks.push({
    id: "full-swift-tests",
    passed: true,
    ...swiftCounts,
    logSHA256: swift.logSHA256,
  });

  const staging = run(
    "/bin/bash",
    [path.join(repoRoot, "script", "build_staging_app.sh")],
    "staging-build.log",
    {
      ...isolatedEnvironment,
      TATWO_STAGING_ROOT: stagingRoot,
      TATWO_STAGING_CODEX_HOME: codexHome,
      TATWO_SWIFT_SCRATCH_PATH: stagingSwiftScratchRoot,
    },
  );
  if (staging.status !== 0) throw new Error("staging_build_failed");
  const stagingReceiptPath = path.join(stagingRoot, "staging-receipt.json");
  const stagingReceipt = readJSON(stagingReceiptPath);
  if (
    stagingReceipt.sourceCommit !== sourceCommit
    || stagingReceipt.sourceDirty !== false
    || !String(stagingReceipt.bundleID).startsWith("com.tatwo.ultrawork.staging.")
  ) {
    throw new Error("staging_receipt_contract_failed");
  }
  receipt.checks.push({
    id: "staging-bundle",
    passed: true,
    appBundle: stagingReceipt.appBundle,
    sourceCommit: stagingReceipt.sourceCommit,
    receiptSHA256: sha256File(stagingReceiptPath),
    opened: false,
  });

  const safeBundle = run(
    process.execPath,
    [path.join(repoRoot, "scripts", "tatwo-safe-app-bundle-smoke.mjs")],
    "safe-bundle-smoke.log",
    {
      ...isolatedEnvironment,
      TATWO_SAFE_BUNDLE_SMOKE_ROOT: safeBundleRoot,
    },
  );
  if (safeBundle.status !== 0) throw new Error("safe_bundle_smoke_failed");
  const safeBundlePointer = parseJSON(safeBundle.output);
  assertPathWithin(safeBundlePointer.summaryPath, safeBundleRoot, "safe_bundle_receipt");
  const safeBundleReceipt = readJSON(safeBundlePointer.summaryPath);
  if (
    safeBundleReceipt.ok !== true
    || safeBundleReceipt.productionAppWriteCount !== 0
    || safeBundleReceipt.launchAgentWriteCount !== 0
    || safeBundleReceipt.authMaterialReadCount !== 0
  ) {
    throw new Error("safe_bundle_receipt_contract_failed");
  }
  receipt.checks.push({
    id: "safe-bundle-rollback",
    passed: true,
    receiptPath: safeBundlePointer.summaryPath,
    receiptSHA256: sha256File(safeBundlePointer.summaryPath),
  });

  const rehearsal = run(
    process.execPath,
    [
      path.join(repoRoot, "scripts", "tatwo-host-sandbox-rehearsal.mjs"),
      "--work-dir",
      hostRehearsalRoot,
      "--json",
    ],
    "host-sandbox-rehearsal.log",
    isolatedEnvironment,
  );
  if (rehearsal.status !== 0) throw new Error("host_sandbox_rehearsal_failed");
  const rehearsalReceipt = parseJSON(rehearsal.output);
  if (
    rehearsalReceipt.passed !== true
    || rehearsalReceipt.realHostMutationPerformed !== false
    || rehearsalReceipt.rollbackValidated !== true
  ) {
    throw new Error("host_sandbox_rehearsal_contract_failed");
  }
  receipt.checks.push({
    id: "fake-home-host-rehearsal",
    passed: true,
    receiptID: rehearsalReceipt.receiptID,
    rollbackValidated: true,
    realHostMutationPerformed: false,
  });

  receipt.checks.push({
    id: "macos-virtualization-preflight",
    passed: fs.existsSync("/System/Library/Frameworks/Virtualization.framework"),
    frameworkAvailable: fs.existsSync(
      "/System/Library/Frameworks/Virtualization.framework",
    ),
    runnerInstalled: hasAnyCommand(["tart", "vfkit", "utmctl"]),
    requiredForThisGate: false,
    requiredBeforeStableInstallerPromotion: true,
  });

  const finalSourceCommit = git(["rev-parse", "HEAD"]).trim();
  const finalSourceTree = git(["rev-parse", "HEAD^{tree}"]).trim();
  const finalSourceStatus = git([
    "status",
    "--porcelain=v1",
    "--untracked-files=all",
  ]).trim();
  if (
    finalSourceCommit !== sourceCommit
    || finalSourceTree !== sourceTree
    || finalSourceStatus
  ) {
    throw new Error("final_source_seal_failed");
  }
  receipt.checks.push({
    id: "final-source-seal",
    passed: true,
    commit: finalSourceCommit,
    tree: finalSourceTree,
    clean: true,
  });
  receipt.protectedMutations = protectedMutationEvidence({
    sandboxEvidence,
    rehearsalReceipt,
    safeBundleReceipt,
  });
  receipt.outcome = "device_passed";
  receipt.candidateOutcome = "pending_peer_device";
  receipt.completedAt = new Date().toISOString();
  writeFinalReceipt(receiptPath, receiptAnchorPath, receipt);
  process.stdout.write(`${JSON.stringify({
    ok: true,
    receiptPath,
    receiptAnchorPath,
    receiptSHA256: sha256File(receiptPath),
    sourceCommit,
    deviceOutcome: receipt.outcome,
    candidateOutcome: receipt.candidateOutcome,
    validationPairID,
    runRoot,
  }, null, 2)}\n`);
} catch (error) {
  receipt.outcome = "failed";
  receipt.candidateOutcome = "failed";
  receipt.completedAt = new Date().toISOString();
  receipt.errorKind = String(error?.message ?? error);
  writeFinalReceipt(receiptPath, receiptAnchorPath, receipt);
  process.stderr.write(`${JSON.stringify({
    ok: false,
    receiptPath,
    receiptAnchorPath,
    receiptSHA256: sha256File(receiptPath),
    errorKind: receipt.errorKind,
  }, null, 2)}\n`);
  process.exit(1);
}

function run(command, commandArgs, logName, environment) {
  const result = spawnSync("/usr/bin/sandbox-exec", [
    "-f",
    sandboxProfilePath,
    command,
    ...commandArgs,
  ], {
    cwd: repoRoot,
    env: environment,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
  const logPath = path.join(logsRoot, logName);
  fs.writeFileSync(logPath, output, { flag: "wx" });
  return {
    status: result.status ?? 1,
    output,
    logPath,
    logSHA256: sha256File(logPath),
  };
}

function git(commandArgs) {
  const result = spawnSync("git", commandArgs, {
    cwd: repoRoot,
    encoding: "utf8",
  });
  if (result.status !== 0) {
    throw new Error(`git_failed:${commandArgs.join("_")}`);
  }
  return result.stdout;
}

function parseSwiftCounts(output) {
  const lines = String(output).split(/\r?\n/);
  let xctestExecuted = 0;
  let xctestSkipped = 0;
  let failures = 0;
  for (let index = 0; index < lines.length - 1; index += 1) {
    if (!/Test Suite '.*\.xctest' passed/.test(lines[index])) continue;
    const match = lines[index + 1].match(
      /Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?/,
    );
    if (!match) throw new Error("swift_test_summary_unparseable");
    xctestExecuted += Number(match[1]);
    xctestSkipped += Number(match[2] ?? 0);
    failures += Number(match[3]);
  }
  let swiftTestingPassed = 0;
  for (const line of lines) {
    const match = line.match(/✔ Test run with (\d+) tests? in .* passed/);
    if (match) swiftTestingPassed += Number(match[1]);
  }
  if (xctestExecuted === 0) throw new Error("swift_xctest_count_missing");
  return {
    xctestExecuted,
    xctestPassed: xctestExecuted - xctestSkipped - failures,
    xctestSkipped,
    swiftTestingPassed,
    failures,
    totalCases: xctestExecuted + swiftTestingPassed,
  };
}

function readJSON(target) {
  return JSON.parse(fs.readFileSync(target, "utf8"));
}

function parseJSON(value) {
  const text = String(value);
  const start = text.indexOf("{");
  if (start < 0) throw new Error("json_output_missing");
  return JSON.parse(text.slice(start));
}

function writeJSON(target, value) {
  const temporary = `${target}.tmp-${process.pid}`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { flag: "wx" });
  fs.renameSync(temporary, target);
}

function sha256File(target) {
  return crypto.createHash("sha256").update(fs.readFileSync(target)).digest("hex");
}

function sha256Text(value) {
  return crypto.createHash("sha256").update(String(value)).digest("hex");
}

function buildIsolatedEnvironment({
  fakeHome,
  codexHome,
  appSupport,
  stateRoot,
  tempRoot,
  cacheRoot,
  configRoot,
  moduleCacheRoot,
  swiftScratchRoot,
}) {
  const environment = {};
  for (const key of [
    "PATH",
    "SHELL",
    "USER",
    "LOGNAME",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "TERM",
    "DEVELOPER_DIR",
    "SDKROOT",
    "TOOLCHAINS",
    "ARCHS",
  ]) {
    if (process.env[key]) environment[key] = process.env[key];
  }
  return {
    ...environment,
    HOME: fakeHome,
    CFFIXED_USER_HOME: fakeHome,
    CODEX_HOME: codexHome,
    TMPDIR: `${tempRoot}${path.sep}`,
    XDG_CACHE_HOME: cacheRoot,
    XDG_CONFIG_HOME: configRoot,
    CLANG_MODULE_CACHE_PATH: moduleCacheRoot,
    SWIFTPM_MODULECACHE_OVERRIDE: moduleCacheRoot,
    TATWO_SWIFT_SCRATCH_PATH: swiftScratchRoot,
    GIT_OPTIONAL_LOCKS: "0",
    CI: "1",
    TATWO_ULTRAWORK_APP_SUPPORT: appSupport,
    TATWO_ULTRAWORK_STATE_DIR: stateRoot,
    TATWO_DOMAIN_COORDINATOR_ENABLED: "0",
    TATWO_OUTER_SANDBOX: "1",
  };
}

function writeSandboxProfile(target) {
  const readDenied = [
    path.join(realHome, ".codex"),
    path.join(realHome, "Library", "Application Support", "Codex"),
    path.join(realHome, "Library", "Application Support", "Tatwo Ultrawork"),
    path.join(realHome, "Library", "Keychains"),
  ];
  const writeDenied = [
    repoRoot,
    "/Applications",
    path.join(realHome, ".codex"),
    path.join(realHome, "Library", "Application Support", "Codex"),
    path.join(realHome, "Library", "Application Support", "Tatwo Ultrawork"),
    path.join(realHome, "Library", "LaunchAgents"),
    "/Library/LaunchAgents",
    "/Library/LaunchDaemons",
  ];
  const lines = [
    "(version 1)",
    "(allow default)",
    ...readDenied.map((targetPath) =>
      `(deny file-read* (subpath ${sandboxQuote(targetPath)}))`),
    ...writeDenied.map((targetPath) =>
      `(deny file-write* (subpath ${sandboxQuote(targetPath)}))`),
    '(deny process-exec (literal "/usr/bin/open"))',
    '(deny process-exec (literal "/usr/bin/osascript"))',
    '(deny process-exec (literal "/usr/bin/security"))',
    '(deny mach-lookup (global-name "com.apple.securityd"))',
    "",
  ];
  fs.writeFileSync(target, lines.join("\n"), { flag: "wx", mode: 0o600 });
}

function sandboxQuote(value) {
  return JSON.stringify(String(value));
}

function verifySandboxEnforcement({ profilePath, environment, runRoot: root }) {
  const probeRoot = path.join(root, "sandbox-probes");
  fs.mkdirSync(probeRoot, { recursive: true });
  const allowedPath = path.join(probeRoot, "allowed-write.txt");
  const deniedPath = `/Applications/.tatwo-local-validation-denied-${process.pid}`;
  const allowed = spawnSync(
    "/usr/bin/sandbox-exec",
    [
      "-f",
      profilePath,
      process.execPath,
      "-e",
      `require("node:fs").writeFileSync(${JSON.stringify(allowedPath)}, "ok\\n")`,
    ],
    { cwd: repoRoot, env: environment, encoding: "utf8" },
  );
  const deniedWrite = spawnSync(
    "/usr/bin/sandbox-exec",
    [
      "-f",
      profilePath,
      process.execPath,
      "-e",
      `require("node:fs").writeFileSync(${JSON.stringify(deniedPath)}, "forbidden\\n")`,
    ],
    { cwd: repoRoot, env: environment, encoding: "utf8" },
  );
  const readTarget = [
    path.join(realHome, ".codex"),
    path.join(realHome, "Library", "Keychains"),
    path.join(realHome, "Library", "Application Support", "Tatwo Ultrawork"),
  ].find((candidate) => fs.existsSync(candidate));
  if (!readTarget) throw new Error("sandbox_read_probe_target_missing");
  const readExpression = fs.statSync(readTarget).isDirectory()
    ? `require("node:fs").readdirSync(${JSON.stringify(readTarget)})`
    : `require("node:fs").readFileSync(${JSON.stringify(readTarget)})`;
  const deniedRead = spawnSync(
    "/usr/bin/sandbox-exec",
    ["-f", profilePath, process.execPath, "-e", readExpression],
    { cwd: repoRoot, env: environment, encoding: "utf8" },
  );
  const deniedOpen = spawnSync(
    "/usr/bin/sandbox-exec",
    ["-f", profilePath, "/usr/bin/open", "--help"],
    { cwd: repoRoot, env: environment, encoding: "utf8" },
  );
  const result = {
    passed:
      allowed.status === 0
      && fs.readFileSync(allowedPath, "utf8") === "ok\n"
      && deniedWrite.status !== 0
      && !fs.existsSync(deniedPath)
      && deniedRead.status !== 0
      && deniedOpen.status !== 0,
    allowedSandboxWriteProbe: allowed.status === 0,
    deniedApplicationsWriteProbe: deniedWrite.status !== 0 && !fs.existsSync(deniedPath),
    deniedPrivateReadProbe: deniedRead.status !== 0,
    deniedFormalOpenProbe: deniedOpen.status !== 0,
    sanitizedEnvironment: true,
  };
  if (!result.passed) throw new Error("macos_sandbox_enforcement_failed");
  return result;
}

function assertValidationBaseAllowed(target) {
  const candidate = canonicalProspectivePath(target);
  const protectedRoots = [
    canonicalProspectivePath(repoRoot),
    canonicalProspectivePath("/Applications"),
    canonicalProspectivePath(path.join(realHome, ".codex")),
    canonicalProspectivePath(path.join(realHome, "Library")),
    canonicalProspectivePath("/Library/LaunchAgents"),
    canonicalProspectivePath("/Library/LaunchDaemons"),
  ];
  for (const protectedRoot of protectedRoots) {
    if (
      isSameOrWithin(candidate, protectedRoot)
      || isSameOrWithin(protectedRoot, candidate)
    ) {
      throw new Error("validation_root_overlaps_protected_surface");
    }
  }
  return candidate;
}

function canonicalProspectivePath(target) {
  const absolute = path.resolve(target);
  const suffix = [];
  let cursor = absolute;
  while (!fs.existsSync(cursor)) {
    const parent = path.dirname(cursor);
    if (parent === cursor) break;
    suffix.unshift(path.basename(cursor));
    cursor = parent;
  }
  const base = fs.realpathSync(cursor);
  return path.join(base, ...suffix);
}

function isSameOrWithin(candidate, root) {
  const relative = path.relative(root, candidate);
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

function assertPathWithin(target, root, label) {
  const canonicalTarget = canonicalProspectivePath(target);
  const canonicalRoot = canonicalProspectivePath(root);
  if (!isSameOrWithin(canonicalTarget, canonicalRoot)) {
    throw new Error(`${label}_escaped_root`);
  }
}

function requireNonEmptyTestInventory(files) {
  if (!Array.isArray(files) || files.length === 0) {
    throw new Error("node_test_inventory_empty");
  }
}

function readHostFingerprint() {
  const result = spawnSync(
    "/usr/sbin/ioreg",
    ["-rd1", "-c", "IOPlatformExpertDevice"],
    { encoding: "utf8" },
  );
  const match = String(result.stdout).match(/"IOPlatformUUID"\s*=\s*"([^"]+)"/);
  if (result.status !== 0 || !match) {
    throw new Error("host_fingerprint_unavailable");
  }
  return sha256Text(`TatwoLocalValidationHostV1:${match[1]}`);
}

function protectedMutationEvidence({
  sandboxEvidence,
  rehearsalReceipt,
  safeBundleReceipt,
}) {
  const nestedEvidencePassed =
    sandboxEvidence.passed === true
    && rehearsalReceipt.realHostMutationPerformed === false
    && rehearsalReceipt.rollbackValidated === true
    && safeBundleReceipt.productionAppWriteCount === 0
    && safeBundleReceipt.launchAgentWriteCount === 0
    && safeBundleReceipt.authMaterialReadCount === 0;
  if (!nestedEvidencePassed) {
    throw new Error("protected_surface_evidence_failed");
  }
  return {
    verified: true,
    evidenceMethod: [
      "macos_sandbox_deny_profile",
      "sanitized_environment_and_fake_home",
      "nested_sandbox_receipts",
      "final_source_seal",
    ],
    applicationsDirectoryWrites: 0,
    formalAppLaunches: 0,
    realUserDataMigrationApplies: 0,
    launchAgentWrites: 0,
    authSessionTokenReads: 0,
    authSessionTokenWrites: 0,
    domainAuthorityTransfers: 0,
  };
}

function writeFinalReceipt(target, anchorTarget, value) {
  writeJSON(target, value);
  const digest = sha256File(target);
  fs.writeFileSync(
    anchorTarget,
    `${digest}  ${path.basename(target)}\n`,
    { flag: "wx", mode: 0o600 },
  );
}

function selftestCheck(id, action) {
  try {
    action();
    return { id, passed: false };
  } catch {
    return { id, passed: true };
  }
}

function hasAnyCommand(commands) {
  return commands.some((command) => {
    const result = spawnSync("/usr/bin/which", [command], {
      stdio: "ignore",
    });
    return result.status === 0;
  });
}
