import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

import {
  atomicallyExchangeDirectories,
  defaultSkilletSourceRoot,
  discoverSources,
  refresh as refreshWithLockRequirement,
  resolveExecutable,
  sanitizeMessage,
  snapshotDigest,
  storeMutationLockPath,
  unwrapSnapshotCLIOutput,
  validateRegistry,
} from "../scripts/tatwo-skillet-refresh.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));

function refresh(options) {
  return refreshWithLockRequirement({
    ...options,
    assumeStoreLockHeld: true,
  });
}

function makeRoot() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-skillet-refresh."));
}

test("default source root is App Support/skills, not an external volume", () => {
  assert.equal(
    defaultSkilletSourceRoot(),
    path.join(
      os.homedir(),
      "Library",
      "Application Support",
      "Tatwo Ultrawork",
      "skills",
    ),
  );
  assert.doesNotMatch(defaultSkilletSourceRoot(), /\/Volumes\/CodexData\/skills$/);
});

function writeSkill(root, name, content = "# Skill\n") {
  const directory = path.join(root, name);
  fs.mkdirSync(directory, { recursive: true });
  fs.writeFileSync(path.join(directory, "SKILL.md"), content);
  return directory;
}

test("snapshot digest follows the portable UTF-8 byte ordering contract", () => {
  const files = [
    { relativePath: "ä.txt", data: Buffer.from("umlaut\n") },
    { relativePath: "e\u0301.txt", data: Buffer.from("combining\n") },
    { relativePath: "SKILL.md", data: Buffer.from("# skill\n") },
  ];

  assert.equal(
    snapshotDigest(files),
    "1b41e70b0bd608ba78beec0102f64c06250b59d8469e7c7b193dc831eea87d7d",
  );
});

function writeRegistry(filePath, aliases, retiredRepositoryIDs = []) {
  fs.writeFileSync(
    filePath,
    `${JSON.stringify({
      schemaVersion: 1,
      repositoryAliases: aliases,
      retiredRepositoryIDs,
    }, null, 2)}\n`,
  );
}

function writeFallbackAuthorization(
  filePath,
  {
    authorizationID = "fallback-auth-mini-11",
    authorizedDeviceName = "mini",
    authorizedDeviceID = "mini-device-id",
    authorityPrimary = "mini",
    authorityEpoch = 11,
  } = {},
) {
  const document = {
    schema: "TatwoSkilletRuntimeFallbackAuthorizationV1",
    authorizationID,
    sourceMode: "runtime-fallback",
    authorizedDeviceName,
    authorizedDeviceID,
    authorityPrimary,
    authorityEpoch,
    previousAuthorityPrimary: "book",
    previousAuthorityEpoch: 10,
    authorizedByDeviceName: "book",
    authorizedByDeviceID: "book-device-id",
    issuedAt: "2026-07-26T00:00:00Z",
    scope: "authority-epoch",
    signaturePurpose: "skillet-runtime-fallback-authorization",
    signaturePath: "signatures/fallback-authorizations/mini/epoch-11.json",
  };
  fs.writeFileSync(filePath, `${JSON.stringify(document, null, 2)}\n`);
  return {
    path: filePath,
    relativePath: "fallback-authorizations/mini/epoch-11.json",
    digest: crypto.createHash("sha256").update(fs.readFileSync(filePath)).digest("hex"),
    ...document,
  };
}

function writeFakeCLI(
  filePath,
  {
    envelope = true,
    failRepository = null,
    failureMessage = null,
    corruptObject = false,
    leakStoreOnFailure = false,
    mutateLiveStore = null,
    payloadOverride = null,
    createStoreLock = false,
  } = {},
) {
  fs.writeFileSync(
    filePath,
    `#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
const args = process.argv.slice(2);
const option = (name) => args[args.indexOf(name) + 1];
const repositoryID = option("--repository");
const displayName = option("--display-name");
const store = option("--store");
const source = option("--source");
const channel = option("--channel");
if (repositoryID === ${JSON.stringify(failRepository)}) {
  process.stderr.write(
    (
      ${JSON.stringify(failureMessage)} !== null
        ? ${JSON.stringify(failureMessage)} + " for " + repositoryID
        : "injected snapshot failure for " + repositoryID
    )
      + ${
        leakStoreOnFailure
          ? '" at " + store'
          : '""'
      }
      + "\\n"
  );
  process.exit(73);
}
const relativePath = "SKILL.md";
const payloadData = ${
  payloadOverride === null
    ? "fs.readFileSync(path.join(source, relativePath))"
    : `Buffer.from(${JSON.stringify(payloadOverride)}, "utf8")`
};
const pathData = Buffer.from(relativePath, "utf8");
const uint64 = (value) => {
  const buffer = Buffer.alloc(8);
  buffer.writeBigUInt64BE(BigInt(value));
  return buffer;
};
const digest = crypto.createHash("sha256")
  .update(uint64(pathData.length))
  .update(pathData)
  .update(uint64(payloadData.length))
  .update(payloadData)
  .digest("hex");
const fileDigest = crypto.createHash("sha256").update(payloadData).digest("hex");
const revisionID = "rev-" + digest;
const repository = path.join(store, "repositories", repositoryID);
const revisionRoot = path.join(repository, "revisions");
const objectRoot = path.join(store, "objects", digest);
const payloadRoot = path.join(objectRoot, "payload");
if (${JSON.stringify(createStoreLock)}) {
  fs.writeFileSync(
    path.join(
      path.dirname(store),
      "." + path.basename(store) + ".store-mutation.lock"
    ),
    ""
  );
}
fs.mkdirSync(revisionRoot, { recursive: true });
fs.mkdirSync(payloadRoot, { recursive: true });
fs.writeFileSync(path.join(payloadRoot, relativePath), payloadData);
fs.writeFileSync(path.join(objectRoot, "manifest.json"), JSON.stringify({
  schemaVersion: 1,
  contentDigest: digest,
  files: [{
    relativePath,
    contentDigest: fileDigest,
    byteCount: payloadData.length
  }]
}));
if (${JSON.stringify(corruptObject)}) {
  fs.appendFileSync(path.join(payloadRoot, relativePath), "corrupted-after-manifest");
}
fs.writeFileSync(path.join(revisionRoot, revisionID + ".json"), JSON.stringify({
  id: revisionID,
  repositoryID,
  parentRevisionID: null,
  contentDigest: digest,
  channel,
  createdAt: new Date().toISOString()
}));
fs.writeFileSync(path.join(repository, "repository.json"), JSON.stringify({
  schemaVersion: 1,
  id: repositoryID,
  displayName,
  summary: "fixture",
  canonicalRevision: revisionID,
  revisionIDs: [revisionID]
}));
if (${JSON.stringify(mutateLiveStore)} !== null) {
  fs.mkdirSync(${JSON.stringify(mutateLiveStore)}, { recursive: true });
  fs.writeFileSync(
    path.join(${JSON.stringify(mutateLiveStore)}, "uncoordinated-writer.txt"),
    "writer-survived\\n"
  );
}
const data = {
  schema: "TatwoSkilletSnapshotCLIOutputV1",
  repositoryID,
  revisionID,
  contentDigest: digest,
  channel,
  storePath: store
};
process.stdout.write(JSON.stringify(${
  envelope
    ? '{ ok: true, command: "skillet snapshot", data, error: null }'
    : "data"
}) + "\\n");
`,
  );
  fs.chmodSync(filePath, 0o755);
}

function sourceRefreshAttemptOptions(overrides = {}) {
  return {
    attemptID: "20260726T013000Z-I3ATTEMPT",
    target: "macbook",
    action: "system-pull",
    requestedAt: "2026-07-26T01:30:00Z",
    currentDeviceName: "mini",
    currentDeviceID: "mini-device-id",
    authorityPrimary: "mini",
    authorityEpoch: "12",
    ledgerSequence: "41",
    catalogRevision: "2026-07-26.1",
    sourceDeviceID: "mini-device-id",
    targetDeviceID: "book-device-id",
    ...overrides,
  };
}

function sourceRefreshAttemptCLIArgs(overrides = {}) {
  const options = sourceRefreshAttemptOptions(overrides);
  return [
    "--attempt-id", options.attemptID,
    "--target", options.target,
    "--action", options.action,
    "--requested-at", options.requestedAt,
    "--current-device-name", options.currentDeviceName,
    "--current-device-id", options.currentDeviceID,
    "--authority-primary", options.authorityPrimary,
    "--authority-epoch", options.authorityEpoch,
    "--ledger-sequence", options.ledgerSequence,
    "--catalog-revision", options.catalogRevision,
    "--source-device-id", options.sourceDeviceID,
    "--target-device-id", options.targetDeviceID,
  ];
}

async function waitForFile(filePath, timeoutMilliseconds = 5_000) {
  const deadline = Date.now() + timeoutMilliseconds;
  while (Date.now() < deadline) {
    if (fs.existsSync(filePath)) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timed out waiting for fixture file: ${path.basename(filePath)}`);
}

async function waitForChild(child) {
  if (child.exitCode !== null) return child.exitCode;
  return await new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("exit", (code) => resolve(code));
  });
}

test("refresh unwraps the governed CLI JSON envelope", () => {
  const digest = "a".repeat(64);
  assert.deepEqual(
    unwrapSnapshotCLIOutput({
      ok: true,
      command: "skillet snapshot",
      data: {
        schema: "TatwoSkilletSnapshotCLIOutputV1",
        repositoryID: "alpha",
        revisionID: `rev-${digest}`,
        contentDigest: digest,
      },
      error: null,
    }),
    {
      schema: "TatwoSkilletSnapshotCLIOutputV1",
      repositoryID: "alpha",
      revisionID: `rev-${digest}`,
      contentDigest: digest,
    },
  );
  assert.throws(
    () => unwrapSnapshotCLIOutput({
      ok: false,
      command: "skillet snapshot",
      data: null,
      error: "snapshot refused",
    }),
    /snapshot refused/,
  );
});

test("refresh maps Unicode display aliases to portable repository IDs", () => {
  const root = makeRoot();
  try {
    const sourceRoot = path.join(root, "skills");
    const external = path.join(root, "external-vpn");
    const store = path.join(root, "store");
    fs.mkdirSync(sourceRoot, { recursive: true });
    writeSkill(sourceRoot, "alpha");
    writeSkill(sourceRoot, "刺青網頁");
    writeSkill(root, "external-vpn");
    fs.symlinkSync(external, path.join(sourceRoot, "vpn-apple-store"));
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, [
      {
        sourceName: "刺青網頁",
        repositoryID: "tattoo-web",
        displayName: "刺青網頁",
      },
    ]);
    const cli = path.join(root, "fake-cli.mjs");
    writeFakeCLI(cli);

    const receipt = refresh({
      sourceRoot,
      store,
      registry,
      cli,
      receipt: null,
      channel: "staging",
      dryRun: false,
      json: true,
    });

    assert.equal(receipt.outcome, "converged");
    assert.equal(receipt.discoveredSourceCount, 3);
    assert.deepEqual(
      receipt.expectedRepositoryIDs,
      ["alpha", "tattoo-web", "vpn-apple-store"],
    );
    assert.equal(
      receipt.results.find((result) => result.repositoryID === "tattoo-web")?.displayName,
      "刺青網頁",
    );
    assert.equal(JSON.stringify(receipt).includes(sourceRoot), false);
    assert.equal(JSON.stringify(receipt).includes(external), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("refresh remains compatible with direct legacy snapshot JSON", () => {
  const root = makeRoot();
  try {
    const sourceRoot = path.join(root, "skills");
    const store = path.join(root, "store");
    fs.mkdirSync(sourceRoot, { recursive: true });
    writeSkill(sourceRoot, "alpha");
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, []);
    const cli = path.join(root, "fake-cli.mjs");
    writeFakeCLI(cli, { envelope: false });

    const receipt = refresh({
      sourceRoot,
      store,
      registry,
      cli,
      receipt: null,
      channel: "staging",
      dryRun: false,
      json: true,
    });

    assert.equal(receipt.outcome, "converged");
    assert.equal(receipt.refreshedCount, 1);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("refresh fails closed when a Unicode skill lacks an ASCII alias", () => {
  const root = makeRoot();
  try {
    const sourceRoot = path.join(root, "skills");
    fs.mkdirSync(sourceRoot, { recursive: true });
    writeSkill(sourceRoot, "未登記技能");
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, []);
    const cli = path.join(root, "fake-cli.mjs");
    writeFakeCLI(cli);

    assert.throws(
      () =>
        refresh({
          sourceRoot,
          store: path.join(root, "store"),
          registry,
          cli,
          receipt: null,
          channel: "staging",
          dryRun: false,
          json: true,
        }),
      /needs an explicit ASCII repository alias/,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("fatal missing-alias receipt preserves local attempt binding and a failed source row", () => {
  const root = makeRoot();
  try {
    const sourceRoot = path.join(root, "skills");
    const receiptPath = path.join(root, "canonical-refresh.json");
    fs.mkdirSync(sourceRoot, { recursive: true });
    writeSkill(sourceRoot, "未登記技能");
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, []);
    const script = path.join(HERE, "..", "scripts", "tatwo-skillet-refresh.mjs");

    const child = spawnSync(
      process.execPath,
      [
        script,
        "--source-root", sourceRoot,
        "--store", path.join(root, "store"),
        "--registry", registry,
        "--cli", path.join(root, "unused-cli"),
        "--receipt", receiptPath,
        "--dry-run",
        "--json",
        ...sourceRefreshAttemptCLIArgs(),
      ],
      { encoding: "utf8" },
    );

    assert.notEqual(child.status, 0);
    const receipt = JSON.parse(fs.readFileSync(receiptPath, "utf8"));
    assert.equal(receipt.evidenceKind, "local-source-refresh-attempt");
    assert.equal(receipt.attemptID, "20260726T013000Z-I3ATTEMPT");
    assert.equal(receipt.target, "macbook");
    assert.equal(receipt.action, "system-pull");
    assert.equal(receipt.authorityEpoch, 12);
    assert.equal(receipt.ledgerSequence, 41);
    assert.equal(receipt.outcome, "failed");
    assert.equal(receipt.storeMutation, "not-started");
    assert.equal(receipt.results.length, 1);
    assert.equal(receipt.results[0].sourceName, "未登記技能");
    assert.equal(receipt.results[0].status, "failed");
    assert.match(receipt.results[0].message, /explicit ASCII repository alias/);
    assert.equal(JSON.stringify(receipt).includes(root), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("canonical-source-unavailable receipt keeps source and fallback authorization failures visible", () => {
  const root = makeRoot();
  try {
    const runtimeRoot = path.join(root, "runtime");
    const receiptPath = path.join(root, "canonical-refresh.json");
    fs.mkdirSync(runtimeRoot, { recursive: true });
    writeSkill(runtimeRoot, "alpha");
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, []);
    const script = path.join(HERE, "..", "scripts", "tatwo-skillet-refresh.mjs");

    const child = spawnSync(
      process.execPath,
      [
        script,
        "--source-root", path.join(root, "missing-canonical"),
        "--fallback-source-root", runtimeRoot,
        "--store", path.join(root, "store"),
        "--registry", registry,
        "--cli", path.join(root, "unused-cli"),
        "--receipt", receiptPath,
        "--dry-run",
        "--json",
        ...sourceRefreshAttemptCLIArgs(),
      ],
      { encoding: "utf8" },
    );

    assert.notEqual(child.status, 0);
    const receipt = JSON.parse(fs.readFileSync(receiptPath, "utf8"));
    assert.equal(receipt.outcome, "failed");
    assert.equal(receipt.storeMutation, "not-started");
    assert.deepEqual(
      receipt.results.map((result) => result.sourceName),
      ["canonical-source-root", "runtime-fallback-authorization"],
    );
    assert.match(receipt.results[0].message, /unavailable|not readable/);
    assert.match(receipt.results[1].message, /explicit authority-bound/);
    assert.equal(JSON.stringify(receipt).includes(root), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("prohibited Skill content remains a per-source failed local attempt without activation", () => {
  const root = makeRoot();
  try {
    const sourceRoot = path.join(root, "skills");
    const store = path.join(root, "store");
    const receiptPath = path.join(root, "canonical-refresh.json");
    fs.mkdirSync(sourceRoot, { recursive: true });
    fs.mkdirSync(store, { recursive: true });
    fs.writeFileSync(path.join(store, "sentinel.txt"), "active-before-refresh\n");
    writeSkill(sourceRoot, "alpha");
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, []);
    const cli = path.join(root, "fake-cli.mjs");
    writeFakeCLI(cli, {
      failRepository: "alpha",
      failureMessage: "Skill snapshot contains a prohibited secret-bearing path: .env",
    });

    const receipt = refresh({
      sourceRoot,
      fallbackSourceRoot: null,
      store,
      registry,
      cli,
      receipt: receiptPath,
      channel: "staging",
      dryRun: false,
      json: true,
      ...sourceRefreshAttemptOptions(),
    });

    assert.equal(receipt.outcome, "partial");
    assert.equal(receipt.storeMutation, "staged-not-activated");
    assert.equal(receipt.results.length, 1);
    assert.equal(receipt.results[0].sourceName, "alpha");
    assert.equal(receipt.results[0].status, "failed");
    assert.match(receipt.results[0].message, /prohibited secret-bearing path/);
    assert.equal(
      fs.readFileSync(path.join(store, "sentinel.txt"), "utf8"),
      "active-before-refresh\n",
    );
    assert.equal(fs.existsSync(path.join(store, "repositories")), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("one failed source among valid sources remains explicit and never activates a partial store", () => {
  const root = makeRoot();
  try {
    const sourceRoot = path.join(root, "skills");
    const store = path.join(root, "store");
    fs.mkdirSync(sourceRoot, { recursive: true });
    fs.mkdirSync(store, { recursive: true });
    fs.writeFileSync(path.join(store, "sentinel.txt"), "active-before-refresh\n");
    writeSkill(sourceRoot, "alpha");
    writeSkill(sourceRoot, "beta");
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, []);
    const cli = path.join(root, "fake-cli.mjs");
    writeFakeCLI(cli, { failRepository: "beta" });

    const receipt = refresh({
      sourceRoot,
      fallbackSourceRoot: null,
      store,
      registry,
      cli,
      receipt: path.join(root, "canonical-refresh.json"),
      channel: "staging",
      dryRun: false,
      json: true,
      ...sourceRefreshAttemptOptions({
        attemptID: "20260726T013100Z-I3PARTIAL",
        ledgerSequence: "42",
      }),
    });

    assert.equal(receipt.outcome, "partial");
    assert.equal(receipt.storeMutation, "staged-not-activated");
    assert.equal(receipt.discoveredSourceCount, 2);
    assert.equal(receipt.refreshedCount, 1);
    assert.equal(receipt.failedCount, 1);
    assert.deepEqual(
      receipt.results.map(({ repositoryID, status }) => ({ repositoryID, status })),
      [
        { repositoryID: "alpha", status: "refreshed" },
        { repositoryID: "beta", status: "failed" },
      ],
    );
    assert.equal(
      fs.readFileSync(path.join(store, "sentinel.txt"), "utf8"),
      "active-before-refresh\n",
    );
    assert.equal(fs.existsSync(path.join(store, "repositories")), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("refresh reports stale repositories instead of silently syncing them", () => {
  const root = makeRoot();
  try {
    const sourceRoot = path.join(root, "skills");
    const store = path.join(root, "store");
    fs.mkdirSync(sourceRoot, { recursive: true });
    writeSkill(sourceRoot, "alpha");
    fs.mkdirSync(path.join(store, "repositories", "retired-skill"), {
      recursive: true,
    });
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, []);
    const cli = path.join(root, "fake-cli.mjs");
    writeFakeCLI(cli);

    const receipt = refresh({
      sourceRoot,
      store,
      registry,
      cli,
      receipt: null,
      channel: "staging",
      dryRun: false,
      json: true,
    });

    assert.equal(receipt.outcome, "partial");
    assert.deepEqual(receipt.staleRepositoryIDs, ["retired-skill"]);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("explicit retirement tombstone archives a stale repository atomically", () => {
  const root = makeRoot();
  try {
    const sourceRoot = path.join(root, "skills");
    const store = path.join(root, "store");
    fs.mkdirSync(sourceRoot, { recursive: true });
    writeSkill(sourceRoot, "alpha");
    fs.mkdirSync(path.join(store, "repositories", "retired-skill"), {
      recursive: true,
    });
    fs.writeFileSync(
      path.join(store, "repositories", "retired-skill", "repository.json"),
      "{}\n",
    );
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, [], ["retired-skill"]);
    const cli = path.join(root, "fake-cli.mjs");
    writeFakeCLI(cli);

    const receipt = refresh({
      sourceRoot,
      fallbackSourceRoot: null,
      store,
      registry,
      cli,
      receipt: null,
      channel: "staging",
      dryRun: false,
      json: true,
    });

    assert.equal(receipt.outcome, "converged");
    assert.deepEqual(receipt.staleRepositoryIDs, []);
    assert.deepEqual(receipt.retiredRepositoryIDs, ["retired-skill"]);
    assert.deepEqual(receipt.retirements, [{
      repositoryID: "retired-skill",
      status: "retired-and-archived",
    }]);
    assert.equal(
      fs.existsSync(path.join(store, "repositories", "retired-skill")),
      false,
    );
    assert.equal(
      fs.existsSync(path.join(store, "retired-repositories", "retired-skill")),
      true,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("retirement failure removes the staged store and preserves live state", () => {
  const root = makeRoot();
  try {
    const sourceRoot = path.join(root, "skills");
    const store = path.join(root, "store");
    fs.mkdirSync(sourceRoot, { recursive: true });
    writeSkill(sourceRoot, "alpha");
    fs.mkdirSync(path.join(store, "repositories", "retired-skill"), {
      recursive: true,
    });
    fs.mkdirSync(path.join(store, "retired-repositories", "retired-skill"), {
      recursive: true,
    });
    fs.writeFileSync(
      path.join(store, "repositories", "retired-skill", "live-marker"),
      "live\n",
    );
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, [], ["retired-skill"]);
    const cli = path.join(root, "fake-cli.mjs");
    writeFakeCLI(cli);

    assert.throws(
      () => refresh({
        sourceRoot,
        fallbackSourceRoot: null,
        store,
        registry,
        cli,
        receipt: null,
        channel: "staging",
        dryRun: false,
        json: true,
      }),
      /archive already conflicts/,
    );

    assert.equal(
      fs.readFileSync(
        path.join(store, "repositories", "retired-skill", "live-marker"),
        "utf8",
      ),
      "live\n",
    );
    assert.deepEqual(
      fs.readdirSync(root).filter((name) => name.includes(".refresh-staging-")),
      [],
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("promoted primary discovers aliased skills by repository ID with stable identity", () => {
  const root = makeRoot();
  try {
    const canonicalRoot = path.join(root, "canonical");
    const promotedRoot = path.join(root, "runtime");
    fs.mkdirSync(canonicalRoot, { recursive: true });
    fs.mkdirSync(promotedRoot, { recursive: true });
    writeSkill(canonicalRoot, "刺青網頁", "# Tattoo\n");
    writeSkill(promotedRoot, "tattoo-web", "# Tattoo\n");
    const registry = path.join(root, "registry.json");
    const aliases = [
      {
        sourceName: "刺青網頁",
        repositoryID: "tattoo-web",
        displayName: "刺青網頁",
      },
    ];
    writeRegistry(registry, aliases);
    const authorization = writeFallbackAuthorization(
      path.join(root, "fallback-authorization.json"),
    );
    const options = {
      store: path.join(root, "store"),
      registry,
      cli: path.join(root, "unused-cli"),
      receipt: null,
      channel: "staging",
      dryRun: true,
      json: true,
    };

    const canonical = refresh({
      ...options,
      sourceRoot: canonicalRoot,
      fallbackSourceRoot: null,
    });
    const promoted = refresh({
      ...options,
      sourceRoot: path.join(root, "missing-canonical"),
      fallbackSourceRoot: promotedRoot,
      fallbackAuthorization: authorization.path,
      fallbackAuthorizationPath: authorization.relativePath,
      fallbackAuthorizationDigest: authorization.digest,
      currentDeviceName: authorization.authorizedDeviceName,
      currentDeviceID: authorization.authorizedDeviceID,
      authorityPrimary: authorization.authorityPrimary,
      authorityEpoch: String(authorization.authorityEpoch),
    });

    assert.equal(promoted.outcome, "converged");
    assert.equal(promoted.sourceMode, "runtime-fallback");
    assert.equal(promoted.fallbackAuthorizationID, authorization.authorizationID);
    assert.equal(promoted.fallbackAuthorizationPath, authorization.relativePath);
    assert.equal(promoted.fallbackAuthorizationDigest, authorization.digest);
    assert.equal(promoted.results[0].sourceName, "刺青網頁");
    assert.equal(promoted.results[0].sourceLayout, "repository-id");
    assert.equal(promoted.results[0].repositoryID, "tattoo-web");
    assert.equal(promoted.inventoryDigest, canonical.inventoryDigest);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("runtime fallback fails closed without an explicit authorization", () => {
  const root = makeRoot();
  try {
    const runtimeRoot = path.join(root, "runtime");
    fs.mkdirSync(runtimeRoot, { recursive: true });
    writeSkill(runtimeRoot, "alpha", "# Alpha\n");
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, []);

    assert.throws(
      () => refresh({
        sourceRoot: path.join(root, "missing-canonical"),
        fallbackSourceRoot: runtimeRoot,
        store: path.join(root, "store"),
        registry,
        cli: path.join(root, "unused-cli"),
        receipt: null,
        channel: "staging",
        dryRun: true,
        json: true,
      }),
      /explicit authority-bound fallback authorization/,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("runtime fallback rejects a stale or wrong-device authorization", () => {
  const root = makeRoot();
  try {
    const runtimeRoot = path.join(root, "runtime");
    fs.mkdirSync(runtimeRoot, { recursive: true });
    writeSkill(runtimeRoot, "alpha", "# Alpha\n");
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, []);
    const authorization = writeFallbackAuthorization(
      path.join(root, "fallback-authorization.json"),
    );

    assert.throws(
      () => refresh({
        sourceRoot: path.join(root, "missing-canonical"),
        fallbackSourceRoot: runtimeRoot,
        store: path.join(root, "store"),
        registry,
        cli: path.join(root, "unused-cli"),
        receipt: null,
        channel: "staging",
        dryRun: true,
        json: true,
        fallbackAuthorization: authorization.path,
        fallbackAuthorizationPath: authorization.relativePath,
        fallbackAuthorizationDigest: authorization.digest,
        currentDeviceName: "book",
        currentDeviceID: authorization.authorizedDeviceID,
        authorityPrimary: "book",
        authorityEpoch: "12",
      }),
      /stale, belongs to another device, or has invalid scope/,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("identical source-name and repository-ID directories collapse deterministically", () => {
  const root = makeRoot();
  try {
    writeSkill(root, "刺青網頁", "# Same\n");
    writeSkill(root, "tattoo-web", "# Same\n");
    const registry = validateRegistry({
      schemaVersion: 1,
      repositoryAliases: [{
        sourceName: "刺青網頁",
        repositoryID: "tattoo-web",
        displayName: "刺青網頁",
      }],
    });

    const sources = discoverSources(root, registry);

    assert.equal(sources.length, 1);
    assert.equal(sources[0].sourceEntryName, "刺青網頁");
    assert.equal(
      sources[0].sourceLayout,
      "canonical-name-with-identical-repository-id-duplicate",
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("conflicting source-name and repository-ID directories fail closed", () => {
  const root = makeRoot();
  try {
    writeSkill(root, "刺青網頁", "# Canonical\n");
    writeSkill(root, "tattoo-web", "# Diverged runtime\n");
    const registry = validateRegistry({
      schemaVersion: 1,
      repositoryAliases: [{
        sourceName: "刺青網頁",
        repositoryID: "tattoo-web",
        displayName: "刺青網頁",
      }],
    });

    assert.throws(
      () => discoverSources(root, registry),
      /Conflicting duplicate Skillet sources for tattoo-web: 刺青網頁, tattoo-web/,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("broken governed source symlinks fail closed", () => {
  const root = makeRoot();
  try {
    fs.symlinkSync(
      path.join(root, "missing-skill"),
      path.join(root, "broken-skill"),
    );
    const registry = validateRegistry({
      schemaVersion: 1,
      repositoryAliases: [],
    });

    assert.throws(
      () => discoverSources(root, registry),
      /Broken Skillet source symlink: broken-skill/,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("path-like CLI must be executable", () => {
  const root = makeRoot();
  try {
    const cli = path.join(root, "tatwo-ultrawork");
    fs.writeFileSync(cli, "#!/bin/sh\nexit 0\n", { mode: 0o644 });
    assert.equal(resolveExecutable(cli), null);
    fs.chmodSync(cli, 0o755);
    assert.equal(resolveExecutable(cli), cli);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("source root must be absolute and readable", () => {
  const registry = validateRegistry({
    schemaVersion: 1,
    repositoryAliases: [],
  });
  assert.throws(
    () => discoverSources("relative-skills", registry),
    /must be an absolute path/,
  );
});

test("mutating direct refresh requires an explicit shared-lock claim", () => {
  assert.throws(
    () => refreshWithLockRequirement({ dryRun: false }),
    /requires the shared store-mutation lock/,
  );
});

test("atomic directory exchange never removes either visible path", () => {
  const root = makeRoot();
  try {
    const left = path.join(root, "left");
    const right = path.join(root, "right");
    fs.mkdirSync(left);
    fs.mkdirSync(right);
    fs.writeFileSync(path.join(left, "marker"), "left\n");
    fs.writeFileSync(path.join(right, "marker"), "right\n");

    atomicallyExchangeDirectories(left, right);

    assert.equal(fs.existsSync(left), true);
    assert.equal(fs.existsSync(right), true);
    assert.equal(fs.readFileSync(path.join(left, "marker"), "utf8"), "right\n");
    assert.equal(fs.readFileSync(path.join(right, "marker"), "utf8"), "left\n");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("unsupported atomic swap uses the compensating directory exchange", () => {
  const root = makeRoot();
  try {
    const left = path.join(root, "left");
    const right = path.join(root, "right");
    fs.mkdirSync(left);
    fs.mkdirSync(right);
    fs.writeFileSync(path.join(left, "marker"), "left\n");
    fs.writeFileSync(path.join(right, "marker"), "right\n");
    const steps = [];

    const activationMethod = atomicallyExchangeDirectories(left, right, {
      forceCompensatingExchange: true,
      beforeCompensatingExchangeStep: (step) => steps.push(step),
    });

    assert.equal(activationMethod, "compensating-exchange");
    assert.deepEqual(steps, [1, 2, 3]);
    assert.equal(fs.existsSync(left), true);
    assert.equal(fs.existsSync(right), true);
    assert.equal(fs.readFileSync(path.join(left, "marker"), "utf8"), "right\n");
    assert.equal(fs.readFileSync(path.join(right, "marker"), "utf8"), "left\n");
    assert.deepEqual(
      fs.readdirSync(root).filter((name) => name.startsWith(".exchange-")),
      [],
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("refresh removes the staged store mutation lock created by the real CLI", () => {
  const root = makeRoot();
  try {
    const sourceRoot = path.join(root, "skills");
    const store = path.join(root, "store");
    fs.mkdirSync(sourceRoot, { recursive: true });
    writeSkill(sourceRoot, "alpha");
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, []);
    const cli = path.join(root, "fake-cli.mjs");
    writeFakeCLI(cli, { createStoreLock: true });

    const receipt = refresh({
      sourceRoot,
      fallbackSourceRoot: null,
      store,
      registry,
      cli,
      receipt: null,
      channel: "staging",
      dryRun: false,
      json: true,
    });

    assert.equal(receipt.outcome, "converged");
    assert.deepEqual(
      fs.readdirSync(root).filter((name) =>
        name.includes(".refresh-staging-")
      ),
      [],
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("compensating activation is reported distinctly from an atomic swap", () => {
  const root = makeRoot();
  try {
    const sourceRoot = path.join(root, "skills");
    const store = path.join(root, "store");
    fs.mkdirSync(sourceRoot, { recursive: true });
    fs.mkdirSync(store, { recursive: true });
    fs.writeFileSync(path.join(store, "sentinel"), "previous\n");
    writeSkill(sourceRoot, "alpha");
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, []);
    const cli = path.join(root, "fake-cli.mjs");
    writeFakeCLI(cli);

    const receipt = refresh({
      sourceRoot,
      fallbackSourceRoot: null,
      store,
      registry,
      cli,
      receipt: null,
      channel: "staging",
      dryRun: false,
      json: true,
      atomicExchangeTestHooks: {
        forceCompensatingExchange: true,
      },
    });

    assert.equal(receipt.outcome, "converged");
    assert.equal(
      receipt.storeMutation,
      "activated-with-compensating-exchange",
    );
    assert.equal(receipt.activationMethod, "compensating-exchange");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("exact, nested, and symlink-aliased source/runtime roots fail closed", () => {
  const root = makeRoot();
  try {
    const canonicalRoot = path.join(root, "canonical");
    const runtimeRoot = path.join(root, "runtime");
    const store = path.join(root, "store");
    const registry = path.join(root, "registry.json");
    fs.mkdirSync(canonicalRoot, { recursive: true });
    fs.mkdirSync(runtimeRoot, { recursive: true });
    writeSkill(canonicalRoot, "alpha");
    writeSkill(runtimeRoot, "alpha");
    writeRegistry(registry, []);
    const options = {
      store,
      registry,
      cli: path.join(root, "unused-cli"),
      receipt: null,
      channel: "staging",
      dryRun: true,
      json: true,
    };

    assert.throws(
      () => refresh({
        ...options,
        sourceRoot: canonicalRoot,
        fallbackSourceRoot: canonicalRoot,
      }),
      /source root and runtime fallback root must be separate/,
    );

    const nestedRuntime = path.join(canonicalRoot, "nested-runtime");
    fs.mkdirSync(nestedRuntime, { recursive: true });
    assert.throws(
      () => refresh({
        ...options,
        sourceRoot: canonicalRoot,
        fallbackSourceRoot: nestedRuntime,
      }),
      /source root and runtime fallback root must be separate/,
    );

    const nestedCanonical = path.join(runtimeRoot, "nested-canonical");
    fs.mkdirSync(nestedCanonical, { recursive: true });
    assert.throws(
      () => refresh({
        ...options,
        sourceRoot: nestedCanonical,
        fallbackSourceRoot: runtimeRoot,
      }),
      /source root and runtime fallback root must be separate/,
    );

    const canonicalAlias = path.join(root, "canonical-alias");
    fs.symlinkSync(canonicalRoot, canonicalAlias);
    assert.throws(
      () => refresh({
        ...options,
        sourceRoot: canonicalRoot,
        fallbackSourceRoot: canonicalAlias,
      }),
      /source root and runtime fallback root must be separate/,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("nested .git directories are ignored consistently", () => {
  const root = makeRoot();
  try {
    const sourceRoot = path.join(root, "skills");
    const store = path.join(root, "store");
    const skill = writeSkill(sourceRoot, "alpha");
    fs.mkdirSync(path.join(skill, "nested", ".git"), { recursive: true });
    fs.writeFileSync(
      path.join(skill, "nested", ".git", "private-config"),
      "must-not-enter-snapshot\n",
    );
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, []);
    const cli = path.join(root, "fake-cli.mjs");
    writeFakeCLI(cli);

    const receipt = refresh({
      sourceRoot,
      fallbackSourceRoot: null,
      store,
      registry,
      cli,
      receipt: null,
      channel: "staging",
      dryRun: false,
      json: true,
    });

    assert.equal(receipt.outcome, "converged");
    assert.equal(receipt.refreshedCount, 1);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test(".git symlinks are rejected before exclusion", () => {
  const root = makeRoot();
  try {
    const sourceRoot = path.join(root, "skills");
    const skill = writeSkill(sourceRoot, "alpha");
    const externalGit = path.join(root, "external-git");
    fs.mkdirSync(externalGit, { recursive: true });
    fs.symlinkSync(externalGit, path.join(skill, ".git"));
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, []);
    const cli = path.join(root, "fake-cli.mjs");
    writeFakeCLI(cli);

    const receipt = refresh({
      sourceRoot,
      fallbackSourceRoot: null,
      store: path.join(root, "store"),
      registry,
      cli,
      receipt: null,
      channel: "staging",
      dryRun: false,
      json: true,
    });

    assert.equal(receipt.outcome, "partial");
    assert.equal(receipt.failedCount, 1);
    assert.match(receipt.results[0].message, /unsupported symlink: alpha\/\.git/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("failed sequential refresh never partially mutates the active store", () => {
  const root = makeRoot();
  try {
    const sourceRoot = path.join(root, "skills");
    const store = path.join(root, "store");
    fs.mkdirSync(sourceRoot, { recursive: true });
    fs.mkdirSync(store, { recursive: true });
    fs.writeFileSync(path.join(store, "sentinel.txt"), "active-before-refresh\n");
    writeSkill(sourceRoot, "alpha");
    writeSkill(sourceRoot, "beta");
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, []);
    const cli = path.join(root, "fake-cli.mjs");
    writeFakeCLI(cli, { failRepository: "beta" });

    const receipt = refresh({
      sourceRoot,
      fallbackSourceRoot: null,
      store,
      registry,
      cli,
      receipt: null,
      channel: "staging",
      dryRun: false,
      json: true,
    });

    assert.equal(receipt.outcome, "partial");
    assert.equal(receipt.storeMutation, "staged-not-activated");
    assert.equal(
      fs.readFileSync(path.join(store, "sentinel.txt"), "utf8"),
      "active-before-refresh\n",
    );
    assert.equal(fs.existsSync(path.join(store, "repositories", "alpha")), false);
    assert.deepEqual(
      fs.readdirSync(root).filter((name) => name.includes(".refresh-staging-")),
      [],
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("next locked refresh reaps stale staging before creating a new stage", () => {
  const root = makeRoot();
  try {
    const sourceRoot = path.join(root, "skills");
    const store = path.join(root, "store");
    const staleStage = path.join(root, ".store.refresh-staging-stale-fixture");
    const staleStageLock = storeMutationLockPath(staleStage);
    fs.mkdirSync(sourceRoot, { recursive: true });
    fs.mkdirSync(staleStage, { recursive: true });
    fs.writeFileSync(path.join(staleStage, "old-copy"), "stale\n");
    fs.writeFileSync(staleStageLock, "");
    writeSkill(sourceRoot, "alpha");
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, []);
    const cli = path.join(root, "fake-cli.mjs");
    writeFakeCLI(cli);

    const receipt = refresh({
      sourceRoot,
      fallbackSourceRoot: null,
      store,
      registry,
      cli,
      receipt: null,
      channel: "staging",
      dryRun: false,
      json: true,
    });

    assert.equal(receipt.outcome, "converged");
    assert.equal(receipt.reapedStagingStoreCount, 1);
    assert.equal(receipt.reapedStagingStoreLockCount, 1);
    assert.equal(fs.existsSync(staleStage), false);
    assert.equal(fs.existsSync(staleStageLock), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("next refresh restores a single interrupted compensating exchange", () => {
  const root = makeRoot();
  try {
    const sourceRoot = path.join(root, "skills");
    const store = path.join(root, "store");
    const interruptedExchange = path.join(
      root,
      ".store.refresh-exchange-crash-fixture",
    );
    fs.mkdirSync(sourceRoot, { recursive: true });
    fs.mkdirSync(interruptedExchange, { recursive: true });
    fs.writeFileSync(
      path.join(interruptedExchange, "history-marker"),
      "previous-store-history\n",
    );
    writeSkill(sourceRoot, "alpha");
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, []);
    const cli = path.join(root, "fake-cli.mjs");
    writeFakeCLI(cli);

    const receipt = refresh({
      sourceRoot,
      fallbackSourceRoot: null,
      store,
      registry,
      cli,
      receipt: null,
      channel: "staging",
      dryRun: false,
      json: true,
    });

    assert.equal(receipt.outcome, "converged");
    assert.equal(receipt.recoveredInterruptedExchange, true);
    assert.equal(
      fs.readFileSync(path.join(store, "history-marker"), "utf8"),
      "previous-store-history\n",
    );
    assert.deepEqual(
      fs.readdirSync(root).filter((name) =>
        name.includes(".refresh-exchange-")
      ),
      [],
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("multiple interrupted exchanges fail closed without choosing a history", () => {
  const root = makeRoot();
  try {
    const sourceRoot = path.join(root, "skills");
    const store = path.join(root, "store");
    const exchangeA = path.join(root, ".store.refresh-exchange-crash-a");
    const exchangeB = path.join(root, ".store.refresh-exchange-crash-b");
    fs.mkdirSync(sourceRoot, { recursive: true });
    fs.mkdirSync(exchangeA, { recursive: true });
    fs.mkdirSync(exchangeB, { recursive: true });
    fs.writeFileSync(path.join(exchangeA, "history-marker"), "history-a\n");
    fs.writeFileSync(path.join(exchangeB, "history-marker"), "history-b\n");
    writeSkill(sourceRoot, "alpha");
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, []);
    const cli = path.join(root, "fake-cli.mjs");
    writeFakeCLI(cli);

    assert.throws(
      () => refresh({
        sourceRoot,
        fallbackSourceRoot: null,
        store,
        registry,
        cli,
        receipt: null,
        channel: "staging",
        dryRun: false,
        json: true,
      }),
      /interrupted exchange recovery is ambiguous/,
    );

    assert.equal(fs.existsSync(store), false);
    assert.equal(
      fs.readFileSync(path.join(exchangeA, "history-marker"), "utf8"),
      "history-a\n",
    );
    assert.equal(
      fs.readFileSync(path.join(exchangeB, "history-marker"), "utf8"),
      "history-b\n",
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("live store refresh reaps every stale interrupted exchange", () => {
  const root = makeRoot();
  try {
    const sourceRoot = path.join(root, "skills");
    const store = path.join(root, "store");
    const exchangeA = path.join(root, ".store.refresh-exchange-stale-a");
    const exchangeB = path.join(root, ".store.refresh-exchange-stale-b");
    fs.mkdirSync(sourceRoot, { recursive: true });
    fs.mkdirSync(store, { recursive: true });
    fs.writeFileSync(path.join(store, "history-marker"), "live-history\n");
    fs.mkdirSync(exchangeA, { recursive: true });
    fs.mkdirSync(exchangeB, { recursive: true });
    fs.writeFileSync(path.join(exchangeA, "history-marker"), "stale-a\n");
    fs.writeFileSync(path.join(exchangeB, "history-marker"), "stale-b\n");
    writeSkill(sourceRoot, "alpha");
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, []);
    const cli = path.join(root, "fake-cli.mjs");
    writeFakeCLI(cli);

    const receipt = refresh({
      sourceRoot,
      fallbackSourceRoot: null,
      store,
      registry,
      cli,
      receipt: null,
      channel: "staging",
      dryRun: false,
      json: true,
    });

    assert.equal(receipt.outcome, "converged");
    assert.equal(receipt.recoveredInterruptedExchange, false);
    assert.equal(receipt.reapedInterruptedExchangeCount, 2);
    assert.equal(
      fs.readFileSync(path.join(store, "history-marker"), "utf8"),
      "live-history\n",
    );
    assert.deepEqual(
      fs.readdirSync(root).filter((name) =>
        name.includes(".refresh-exchange-")
      ),
      [],
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("production refresh waits for the shared writer lock and preserves the writer", async () => {
  const root = makeRoot();
  let writer = null;
  try {
    const sourceRoot = path.join(root, "skills");
    const store = path.join(root, "store");
    const ready = path.join(root, "writer-ready");
    fs.mkdirSync(sourceRoot, { recursive: true });
    writeSkill(sourceRoot, "alpha");
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, []);
    const cli = path.join(root, "fake-cli.mjs");
    writeFakeCLI(cli);
    const script = path.join(HERE, "..", "scripts", "tatwo-skillet-refresh.mjs");
    const lockPath = storeMutationLockPath(store);
    const python = resolveExecutable(process.env.TATWO_PYTHON3 ?? "python3");
    assert.ok(python, "python3 is required for the shared flock integration test");

    writer = spawn(
      python,
      [
        "-c",
        [
          "import fcntl, os, sys, time",
          "lock_path, ready_path, store_path = sys.argv[1:]",
          "os.makedirs(os.path.dirname(lock_path), exist_ok=True)",
          "fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)",
          "fcntl.flock(fd, fcntl.LOCK_EX)",
          "open(ready_path, 'w', encoding='utf-8').write('ready\\n')",
          "time.sleep(0.45)",
          "os.makedirs(store_path, exist_ok=True)",
          "open(os.path.join(store_path, 'coordinated-writer.txt'), 'w', encoding='utf-8').write('writer-survived\\n')",
          "fcntl.flock(fd, fcntl.LOCK_UN)",
          "os.close(fd)",
        ].join("\n"),
        lockPath,
        ready,
        store,
      ],
      { stdio: "ignore" },
    );
    await waitForFile(ready);

    const started = Date.now();
    const child = spawnSync(
      process.execPath,
      [
        script,
        "--source-root",
        sourceRoot,
        "--store",
        store,
        "--registry",
        registry,
        "--cli",
        cli,
        "--channel",
        "staging",
        "--json",
      ],
      { encoding: "utf8" },
    );
    const elapsed = Date.now() - started;
    const writerStatus = await waitForChild(writer);

    assert.equal(writerStatus, 0);
    assert.equal(child.status, 0, child.stderr || child.stdout);
    assert.ok(elapsed >= 250, `refresh did not wait for the writer lock: ${elapsed}ms`);
    assert.equal(
      fs.readFileSync(path.join(store, "coordinated-writer.txt"), "utf8"),
      "writer-survived\n",
    );
    assert.equal(JSON.parse(child.stdout).outcome, "converged");
  } finally {
    if (writer && writer.exitCode === null) writer.kill();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("uncoordinated live-store mutation aborts activation without losing the write", () => {
  const root = makeRoot();
  try {
    const sourceRoot = path.join(root, "skills");
    const store = path.join(root, "store");
    fs.mkdirSync(sourceRoot, { recursive: true });
    fs.mkdirSync(store, { recursive: true });
    fs.writeFileSync(path.join(store, "sentinel.txt"), "active-before-refresh\n");
    writeSkill(sourceRoot, "alpha");
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, []);
    const cli = path.join(root, "fake-cli.mjs");
    writeFakeCLI(cli, { mutateLiveStore: store });

    assert.throws(
      () => refresh({
        sourceRoot,
        fallbackSourceRoot: null,
        store,
        registry,
        cli,
        receipt: null,
        channel: "staging",
        dryRun: false,
        json: true,
      }),
      /store changed during staged refresh/,
    );

    assert.equal(
      fs.readFileSync(path.join(store, "sentinel.txt"), "utf8"),
      "active-before-refresh\n",
    );
    assert.equal(
      fs.readFileSync(path.join(store, "uncoordinated-writer.txt"), "utf8"),
      "writer-survived\n",
    );
    assert.deepEqual(
      fs.readdirSync(root).filter((name) => name.includes(".refresh-staging-")),
      [],
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("refresh rejects a CLI claim whose immutable object does not verify", () => {
  const root = makeRoot();
  try {
    const sourceRoot = path.join(root, "skills");
    const store = path.join(root, "store");
    fs.mkdirSync(sourceRoot, { recursive: true });
    writeSkill(sourceRoot, "alpha");
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, []);
    const cli = path.join(root, "fake-cli.mjs");
    writeFakeCLI(cli, { corruptObject: true });

    const receipt = refresh({
      sourceRoot,
      fallbackSourceRoot: null,
      store,
      registry,
      cli,
      receipt: null,
      channel: "staging",
      dryRun: false,
      json: true,
    });

    assert.equal(receipt.outcome, "partial");
    assert.equal(receipt.failedCount, 1);
    assert.match(receipt.results[0].message, /payload digest failed verification/);
    assert.equal(fs.existsSync(store), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("refresh rejects a self-consistent snapshot of the wrong source content", () => {
  const root = makeRoot();
  try {
    const sourceRoot = path.join(root, "skills");
    fs.mkdirSync(sourceRoot, { recursive: true });
    writeSkill(sourceRoot, "alpha", "# Canonical\n");
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, []);
    const cli = path.join(root, "fake-cli.mjs");
    writeFakeCLI(cli, { payloadOverride: "# Wrong snapshot\n" });

    const receipt = refresh({
      sourceRoot,
      fallbackSourceRoot: null,
      store: path.join(root, "store"),
      registry,
      cli,
      receipt: null,
      channel: "staging",
      dryRun: false,
      json: true,
    });

    assert.equal(receipt.outcome, "partial");
    assert.equal(receipt.failedCount, 1);
    assert.match(
      receipt.results[0].message,
      /snapshot does not match canonical source: alpha/,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("staging and rollback paths are redacted from refresh diagnostics", () => {
  const root = makeRoot();
  try {
    const sourceRoot = path.join(root, "skills");
    const store = path.join(root, "private-store");
    fs.mkdirSync(sourceRoot, { recursive: true });
    writeSkill(sourceRoot, "alpha");
    const registry = path.join(root, "registry.json");
    writeRegistry(registry, []);
    const cli = path.join(root, "fake-cli.mjs");
    writeFakeCLI(cli, {
      failRepository: "alpha",
      leakStoreOnFailure: true,
    });

    const receipt = refresh({
      sourceRoot,
      fallbackSourceRoot: null,
      store,
      registry,
      cli,
      receipt: null,
      channel: "staging",
      dryRun: false,
      json: true,
    });
    const stagingMessage = receipt.results[0].message;
    assert.equal(stagingMessage.includes(root), false);
    assert.equal(stagingMessage.includes(".refresh-staging-"), false);
    assert.match(stagingMessage, /\$TATWO_SKILLET_STORE/);

    const diagnostic = sanitizeMessage(
      [
        path.join(root, ".private-store.refresh-staging-123-secret"),
        path.join(root, ".private-store.refresh-rollback-123-secret"),
      ].join(" -> "),
      {
        sourceRoot,
        fallbackSourceRoot: null,
        store,
        registry,
        cli,
        receipt: path.join(root, "private-receipt.json"),
      },
      null,
    );
    assert.equal(diagnostic.includes(root), false);
    assert.equal(diagnostic.includes(".refresh-staging-"), false);
    assert.equal(diagnostic.includes(".refresh-rollback-"), false);
    assert.equal(
      diagnostic,
      "$TATWO_SKILLET_STORE_STAGING -> $TATWO_SKILLET_STORE_ROLLBACK",
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("fatal receipt redacts governed registry CLI receipt and home paths", () => {
  const root = makeRoot();
  try {
    const sourceRoot = path.join(root, "skills");
    fs.mkdirSync(sourceRoot, { recursive: true });
    writeSkill(sourceRoot, "alpha");
    const missingRegistry = path.join(root, "private-registry.json");
    const cli = path.join(root, "private-cli");
    const receiptPath = path.join(root, "private-receipt.json");
    const script = path.join(HERE, "..", "scripts", "tatwo-skillet-refresh.mjs");

    const child = spawnSync(
      process.execPath,
      [
        script,
        "--source-root",
        sourceRoot,
        "--store",
        path.join(root, "store"),
        "--registry",
        missingRegistry,
        "--cli",
        cli,
        "--receipt",
        receiptPath,
        "--dry-run",
        "--json",
      ],
      { encoding: "utf8" },
    );

    assert.notEqual(child.status, 0);
    const output = `${child.stdout}\n${fs.readFileSync(receiptPath, "utf8")}`;
    for (const privatePath of [
      sourceRoot,
      missingRegistry,
      cli,
      receiptPath,
      os.homedir(),
    ]) {
      assert.equal(output.includes(privatePath), false);
    }
    assert.match(output, /\$TATWO_SKILLET_SOURCE_REGISTRY/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
