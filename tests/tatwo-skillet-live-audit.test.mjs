import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

import {
  SCHEMA,
  activeSkillSetDigest,
  isExcludedSnapshotMetadata,
  redactString,
  redactValue,
  runAudit,
  snapshotDigestFromRuntime,
} from "../scripts/tatwo-skillet-live-audit.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(HERE, "..");
const SCRIPT = path.join(REPO_ROOT, "scripts", "tatwo-skillet-live-audit.mjs");

function makeRoot(label = "live-audit") {
  return fs.mkdtempSync(path.join(os.tmpdir(), `tatwo-skillet-${label}.`));
}

function writeJSON(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function writeText(filePath, text) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, text, "utf8");
}

function portableDigest(files) {
  const sorted = [...files].sort((left, right) =>
    Buffer.compare(
      Buffer.from(left.relativePath.normalize("NFC"), "utf8"),
      Buffer.from(right.relativePath.normalize("NFC"), "utf8"),
    )
  );
  const hash = crypto.createHash("sha256");
  for (const file of sorted) {
    const pathBytes = Buffer.from(file.relativePath.normalize("NFC"), "utf8");
    const data = Buffer.isBuffer(file.data) ? file.data : Buffer.from(file.data, "utf8");
    const lenPath = Buffer.alloc(8);
    lenPath.writeBigUInt64BE(BigInt(pathBytes.length));
    const lenData = Buffer.alloc(8);
    lenData.writeBigUInt64BE(BigInt(data.length));
    hash.update(lenPath);
    hash.update(pathBytes);
    hash.update(lenData);
    hash.update(data);
  }
  return hash.digest("hex");
}

function buildCompleteFixture({
  repositoryID = "tattoo-web",
  deviceID = "macbook",
  skillBody = "# Skill fixture\n\nDeterministic live-audit payload.\n",
  includeApp = true,
  includeStore = true,
  includeRuntime = true,
  includeDeviceHead = true,
  includeDeviceReceipt = true,
  includeConsumerReadback = true,
  includeRemoteJob = true,
  activeState = "active",
  mutateRuntime = false,
  mutateRemoteDigest = false,
  consumerStatus = "passed",
  omitConsumer = false,
  secretInRemoteJob = false,
} = {}) {
  const root = makeRoot("fixture");
  const home = path.join(root, "home");
  const appSupport = path.join(home, "Library", "Application Support", "Tatwo Ultrawork");
  const store = path.join(appSupport, "skillet");
  const runtimeRoot = path.join(appSupport, "skills-runtime");
  const appBundle = path.join(root, "Applications", "Tatwo Ultrawork.app");
  const consumerDir = path.join(root, "consumer-readbacks", deviceID);
  const remoteJobPath = path.join(root, "remote-jobs", "job-1.json");

  const skillData = Buffer.from(skillBody, "utf8");
  const contentDigest = portableDigest([
    { relativePath: "SKILL.md", data: skillData },
  ]);
  const revisionID = `rev-${contentDigest}`;
  const requestID = "req-live-audit-001";
  writeJSON(path.join(appSupport, "device-identity.json"), {
    deviceId: deviceID,
    name: "fixture-device",
    createdAt: "2026-07-30T00:00:00Z",
  });

  if (includeApp) {
    writeText(
      path.join(appBundle, "Contents", "Info.plist"),
      `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.tatwo.ultrawork</string>
  <key>CFBundleName</key>
  <string>Tatwo Ultrawork</string>
  <key>CFBundleExecutable</key>
  <string>TatwoUltraworkMac</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.7</string>
  <key>CFBundleVersion</key>
  <string>21</string>
  <key>TatwoSourceCommit</key>
  <string>abcdef1234567890abcdef1234567890abcdef12</string>
  <key>TatwoSourceTree</key>
  <string>1234567890abcdef1234567890abcdef12345678</string>
</dict>
</plist>
`,
    );
  }

  if (includeStore) {
    const repositoryRoot = path.join(store, "repositories", repositoryID);
    const objectRoot = path.join(store, "objects", contentDigest);
    writeJSON(path.join(repositoryRoot, "repository.json"), {
      schemaVersion: 1,
      id: repositoryID,
      displayName: repositoryID,
      summary: "fixture repository",
      canonicalRevision: revisionID,
      revisionIDs: [revisionID],
    });
    writeJSON(path.join(repositoryRoot, "revisions", `${revisionID}.json`), {
      id: revisionID,
      repositoryID,
      parentRevisionID: null,
      contentDigest,
      channel: "stable",
      createdAt: "2026-07-30T00:00:00Z",
    });
    writeJSON(path.join(objectRoot, "manifest.json"), {
      schemaVersion: 1,
      contentDigest,
      files: [
        {
          relativePath: "SKILL.md",
          contentDigest: crypto.createHash("sha256").update(skillData).digest("hex"),
          byteCount: skillData.length,
        },
      ],
    });
    writeText(path.join(objectRoot, "payload", "SKILL.md"), skillBody);

    if (includeDeviceHead) {
      const deviceHead = {
        deviceID,
        repositoryID,
        revisionID,
        contentDigest,
        requestID,
        authorityEpoch: 11,
        ledgerSequence: 4,
        activationState: activeState,
        lastVerifiedAt: "2026-07-30T00:05:00Z",
      };
      writeJSON(path.join(repositoryRoot, "device-heads", `${deviceID}.json`), deviceHead);
      if (includeDeviceReceipt) {
        writeJSON(
          path.join(
            repositoryRoot,
            "receipts",
            `device-${deviceID}-e11-s4-${requestID}.json`,
          ),
          {
            id: `device-${deviceID}-e11-s4-${requestID}`,
            repositoryID,
            revisionID,
            kind: "deviceHead",
            contentDigest,
            deviceID,
            requestID,
            authorityEpoch: 11,
            ledgerSequence: 4,
            activationState: activeState,
            recordedAt: deviceHead.lastVerifiedAt,
            message: "Device head verified before persistence",
          },
        );
      }
    }
  }

  if (includeRuntime) {
    const runtimeBody = mutateRuntime
      ? `${skillBody}\n# stale runtime mutation\n`
      : skillBody;
    writeText(path.join(runtimeRoot, repositoryID, "SKILL.md"), runtimeBody);
  }

  const activeSkillDigest = activeSkillSetDigest([
    {
      repository: repositoryID,
      revision: revisionID,
      contentDigest,
    },
  ]);

  if (includeConsumerReadback && !omitConsumer) {
    writeJSON(path.join(consumerDir, `${requestID}.json`), {
      schema: "TatwoTargetConsumerReadbackSetV1",
      requestID,
      target: deviceID,
      targetDeviceID: deviceID,
      sourceDeviceID: "mini",
      authorityPrimary: "mini",
      authorityEpoch: 11,
      ledgerSequence: 4,
      catalogRevision: "2026-07-29.1",
      manifestDigest: contentDigest,
      requiredConsumerIDs: [
        "work-os.bootstrap",
        "tatwo-app.shared-runtime",
        "skillet.runtime-loader",
        "codex.native-skills",
        "claude.native-skills",
      ],
      readbackCount: 3,
      status: consumerStatus,
      observedAt: "2026-07-30T00:06:00Z",
      readbacks: [
        {
          schema: "TatwoTargetConsumerReadbackV1",
          requestID,
          targetDeviceID: deviceID,
          authorityPrimary: "mini",
          authorityEpoch: 11,
          ledgerSequence: 4,
          catalogRevision: "2026-07-29.1",
          consumerID: "skillet.runtime-loader",
          consumerKind: "active-skill-runtime-loader",
          sourceItemID: repositoryID,
          expectedDigest: contentDigest,
          loadedDigest: contentDigest,
          loadedRevision: revisionID,
          loadedPath: `runtime/${repositoryID}`,
          runtimeRef: "TatwoSkilletBundleTransport.verifyAuthorityBoundSetIsActive",
          observedAt: "2026-07-30T00:06:00Z",
          status: "loaded",
        },
        {
          schema: "TatwoTargetConsumerReadbackV1",
          requestID,
          targetDeviceID: deviceID,
          authorityPrimary: "mini",
          authorityEpoch: 11,
          ledgerSequence: 4,
          catalogRevision: "2026-07-29.1",
          consumerID: "codex.native-skills",
          consumerKind: "native-skills-projection",
          sourceItemID: repositoryID,
          expectedDigest: contentDigest,
          loadedDigest: contentDigest,
          loadedRevision: revisionID,
          loadedPath: "codex/skills/current",
          runtimeRef: "tatwo-skills-consumer-projection",
          observedAt: "2026-07-30T00:06:00Z",
          status: "loaded",
        },
        {
          schema: "TatwoTargetConsumerReadbackV1",
          requestID,
          targetDeviceID: deviceID,
          authorityPrimary: "mini",
          authorityEpoch: 11,
          ledgerSequence: 4,
          catalogRevision: "2026-07-29.1",
          consumerID: "claude.native-skills",
          consumerKind: "native-skills-projection",
          sourceItemID: repositoryID,
          expectedDigest: contentDigest,
          loadedDigest: contentDigest,
          loadedRevision: revisionID,
          loadedPath: "claude/skills/current",
          runtimeRef: "tatwo-skills-consumer-projection",
          observedAt: "2026-07-30T00:06:00Z",
          status: "loaded",
        },
      ],
    });
  }

  if (includeRemoteJob) {
    const remoteDigest = mutateRemoteDigest
      ? crypto.createHash("sha256").update("different-skill-set").digest("hex")
      : activeSkillDigest;
    const job = {
      schema: "TatwoLoopJobV1",
      jobID: "job-live-audit-1",
      originDeviceID: "mini",
      targetDeviceID: deviceID,
      activeSkillSetDigest: remoteDigest,
      readiness: {
        activeSkillSetDigest: remoteDigest,
      },
    };
    if (secretInRemoteJob) {
      job.authorization = "Bearer sk-ant-supersecrettokenvalue0001";
      job.sessionToken = "ghp_abcdefghijklmnopqrstuvwxyz012345";
      job.note = "contains sk-ant-supersecrettokenvalue0001 and ghp_abcdefghijklmnopqrstuvwxyz012345";
    }
    writeJSON(remoteJobPath, job);
  }

  return {
    root,
    home,
    appSupport,
    store,
    runtimeRoot,
    appBundle,
    consumerDir,
    remoteJobPath,
    repositoryID,
    deviceID,
    contentDigest,
    revisionID,
    requestID,
    activeSkillDigest,
    options: {
      repoRoot: REPO_ROOT,
      fixtureRoot: root,
      store,
      runtimeRoot,
      appBundle,
      appSupport,
      consumerReadbacksDir: path.join(root, "consumer-readbacks"),
      remoteJob: includeRemoteJob ? remoteJobPath : null,
      deviceID,
      target: deviceID,
      repositoryID,
      expectedRevision: revisionID,
      expectedDigest: contentDigest,
      now: new Date("2026-07-30T00:10:00Z"),
      json: true,
    },
  };
}

function runCLI(args, env = {}) {
  return spawnSync(process.execPath, [SCRIPT, ...args], {
    encoding: "utf8",
    env: { ...process.env, ...env },
  });
}

test("complete local evidence yields layered pass without cross-machine borrowing claim", () => {
  const fixture = buildCompleteFixture();
  try {
    const receipt = runAudit(fixture.options);
    assert.equal(receipt.schema, SCHEMA);
    assert.equal(receipt.schemaVersion, 1);
    assert.equal(receipt.readOnly, true);
    assert.equal(receipt.hostMutationAllowed, false);
    assert.equal(receipt.outcome, "passed");
    assert.equal(receipt.layerStatus.source_implementation, "present");
    assert.equal(receipt.layerStatus.local_store_binding, "bound");
    assert.equal(receipt.layerStatus.active_revision, "matched");
    assert.equal(receipt.layerStatus.consumer_readback, "passed");
    assert.equal(receipt.layerStatus.remote_job_skill_binding, "matched");
    assert.equal(receipt.crossMachineSkillBorrowing.claim, "not_asserted");
    assert.equal(receipt.crossMachineSkillBorrowing.liveCrossMachineSkillBorrowing, false);
    assert.ok(
      receipt.crossMachineSkillBorrowing.reasons.includes(
        "storage_or_sync_receipts_alone_never_prove_live_cross_machine_skill_borrowing",
      ),
    );
    assert.equal(
      receipt.layers.find((layer) => layer.id === "active_revision")
        .details.readinessComparableActiveSkillSetDigest,
      fixture.activeSkillDigest,
    );
  } finally {
    fs.rmSync(fixture.root, { recursive: true, force: true });
  }
});

test("readiness digest uses receipt-backed target heads and matches Swift tuple serialization", () => {
  const entries = [
    {
      repository: "z-skill",
      revision: `rev-${"b".repeat(64)}`,
      contentDigest: "b".repeat(64),
    },
    {
      repository: "a-skill",
      revision: `rev-${"a".repeat(64)}`,
      contentDigest: "a".repeat(64),
    },
  ];
  const swiftSortedKeyPayload = JSON.stringify([
    {
      contentDigest: "a".repeat(64),
      repository: "a-skill",
      revision: `rev-${"a".repeat(64)}`,
    },
    {
      contentDigest: "b".repeat(64),
      repository: "z-skill",
      revision: `rev-${"b".repeat(64)}`,
    },
  ]);
  const expected = crypto
    .createHash("sha256")
    .update(swiftSortedKeyPayload)
    .digest("hex");

  assert.equal(activeSkillSetDigest(entries), expected);
  assert.throws(
    () => activeSkillSetDigest([
      {
        repository: "../unsafe",
        revision: `rev-${"a".repeat(64)}`,
        contentDigest: "a".repeat(64),
      },
    ]),
    /activeSkillSet\.invalid_entry/,
  );
});

test("active-looking target head without matching device receipt is excluded fail-closed", () => {
  const fixture = buildCompleteFixture({ includeDeviceReceipt: false });
  try {
    const receipt = runAudit(fixture.options);
    const active = receipt.layers.find((layer) => layer.id === "active_revision");
    const remote = receipt.layers.find(
      (layer) => layer.id === "remote_job_skill_binding",
    );

    assert.notEqual(receipt.outcome, "passed");
    assert.equal(active.details.readinessComparableActiveSkillSetDigest, null);
    assert.deepEqual(active.details.readinessComparableActiveRevisions, []);
    assert.ok(
      active.reasons.includes(
        `matching_device_receipt_missing:${fixture.repositoryID}`,
      ),
    );
    assert.equal(remote.status, "missing_evidence");
    assert.ok(
      remote.reasons.includes("local_active_skill_set_digest_unavailable"),
    );
  } finally {
    fs.rmSync(fixture.root, { recursive: true, force: true });
  }
});

test("receipt-backed active head that differs from canonical is excluded like Swift matchingDeviceReceipt", () => {
  const fixture = buildCompleteFixture();
  try {
    const canonicalBody = "# Canonical replacement\n";
    const canonicalDigest = portableDigest([
      { relativePath: "SKILL.md", data: canonicalBody },
    ]);
    const canonicalRevision = `rev-${canonicalDigest}`;
    const repositoryRoot = path.join(
      fixture.store,
      "repositories",
      fixture.repositoryID,
    );
    const metadataPath = path.join(repositoryRoot, "repository.json");
    const metadata = JSON.parse(fs.readFileSync(metadataPath, "utf8"));
    metadata.canonicalRevision = canonicalRevision;
    metadata.revisionIDs.push(canonicalRevision);
    writeJSON(metadataPath, metadata);
    writeJSON(
      path.join(repositoryRoot, "revisions", `${canonicalRevision}.json`),
      {
        id: canonicalRevision,
        repositoryID: fixture.repositoryID,
        parentRevisionID: fixture.revisionID,
        contentDigest: canonicalDigest,
        channel: "stable",
        createdAt: "2026-07-30T00:07:00Z",
      },
    );

    const receipt = runAudit({
      ...fixture.options,
      expectedRevision: canonicalRevision,
      expectedDigest: canonicalDigest,
    });
    const active = receipt.layers.find((layer) => layer.id === "active_revision");

    assert.equal(active.status, "stale_or_mismatched");
    assert.equal(active.details.readinessComparableActiveSkillSetDigest, null);
    assert.equal(active.details.repositories[0].readinessComparable, false);
    assert.ok(
      active.reasons.includes(
        `device_head_revision_stale:${fixture.repositoryID}`,
      ),
    );
    assert.ok(
      active.reasons.includes(
        `matching_device_receipt_missing:${fixture.repositoryID}`,
      ),
    );
  } finally {
    fs.rmSync(fixture.root, { recursive: true, force: true });
  }
});

test("repository without a target active head is omitted from readiness digest", () => {
  const fixture = buildCompleteFixture();
  try {
    const skippedRepositoryID = "device-absent-skill";
    const skippedRoot = path.join(
      fixture.store,
      "repositories",
      skippedRepositoryID,
    );
    writeJSON(path.join(skippedRoot, "repository.json"), {
      schemaVersion: 1,
      id: skippedRepositoryID,
      displayName: skippedRepositoryID,
      summary: "repository not active on this target",
      canonicalRevision: fixture.revisionID,
      revisionIDs: [fixture.revisionID],
    });
    writeJSON(
      path.join(skippedRoot, "revisions", `${fixture.revisionID}.json`),
      {
        id: fixture.revisionID,
        repositoryID: skippedRepositoryID,
        parentRevisionID: null,
        contentDigest: fixture.contentDigest,
        channel: "stable",
        createdAt: "2026-07-30T00:00:00Z",
      },
    );
    writeText(
      path.join(fixture.runtimeRoot, skippedRepositoryID, "SKILL.md"),
      "# Skill fixture\n\nDeterministic live-audit payload.\n",
    );

    const receipt = runAudit({
      ...fixture.options,
      repositoryID: null,
      expectedRevision: null,
      expectedDigest: null,
    });
    const active = receipt.layers.find((layer) => layer.id === "active_revision");
    const remote = receipt.layers.find(
      (layer) => layer.id === "remote_job_skill_binding",
    );

    assert.equal(
      active.details.readinessComparableActiveSkillSetDigest,
      fixture.activeSkillDigest,
    );
    assert.deepEqual(active.details.readinessComparableActiveRevisions, [
      {
        repository: fixture.repositoryID,
        revision: fixture.revisionID,
        contentDigest: fixture.contentDigest,
      },
    ]);
    assert.notEqual(
      active.details.canonicalStoreAuditDigest,
      active.details.readinessComparableActiveSkillSetDigest,
    );
    assert.equal(remote.status, "matched");
  } finally {
    fs.rmSync(fixture.root, { recursive: true, force: true });
  }
});

test("missing live store binding fails closed as incomplete/missing evidence", () => {
  const fixture = buildCompleteFixture({ includeStore: false, includeRuntime: false });
  try {
    const receipt = runAudit({
      ...fixture.options,
      store: path.join(fixture.appSupport, "skillet-missing"),
      runtimeRoot: path.join(fixture.appSupport, "skills-runtime-missing"),
    });
    assert.notEqual(receipt.outcome, "passed");
    assert.equal(receipt.layerStatus.local_store_binding, "missing_evidence");
    assert.equal(receipt.layerStatus.active_revision, "missing_evidence");
    assert.ok(
      receipt.missingEvidence.some((item) => item.includes("skillet-store"))
      || receipt.failClosedReasons.some((item) => item.includes("skillet_store_missing")),
    );
    assert.equal(receipt.crossMachineSkillBorrowing.liveCrossMachineSkillBorrowing, false);
  } finally {
    fs.rmSync(fixture.root, { recursive: true, force: true });
  }
});

test("stale or mismatched active revision is explicit fail-closed status", () => {
  const fixture = buildCompleteFixture({
    activeState: "staged",
    mutateRuntime: true,
  });
  try {
    const receipt = runAudit(fixture.options);
    assert.equal(receipt.outcome, "failed");
    assert.equal(receipt.layerStatus.active_revision, "stale_or_mismatched");
    const active = receipt.layers.find((layer) => layer.id === "active_revision");
    assert.ok(
      active.reasons.some((reason) =>
        reason.includes("device_head_not_active")
        || reason.includes("runtime_digest_mismatch")
      ),
    );
  } finally {
    fs.rmSync(fixture.root, { recursive: true, force: true });
  }
});

test("absent consumer readback does not silently pass", () => {
  const fixture = buildCompleteFixture({ includeConsumerReadback: false });
  try {
    const receipt = runAudit({
      ...fixture.options,
      consumerReadbacksDir: path.join(fixture.root, "consumer-readbacks-absent"),
      consumerReadback: null,
    });
    assert.notEqual(receipt.outcome, "passed");
    assert.equal(receipt.layerStatus.consumer_readback, "missing_evidence");
    assert.ok(
      receipt.failClosedReasons.includes("consumer_readback_absent")
      || receipt.missingEvidence.some((item) => item.includes("consumer-readback")),
    );
    assert.equal(receipt.crossMachineSkillBorrowing.liveCrossMachineSkillBorrowing, false);
  } finally {
    fs.rmSync(fixture.root, { recursive: true, force: true });
  }
});

test("consumer loaded digest outside active store set fails closed", () => {
  const fixture = buildCompleteFixture();
  try {
    const readbackPath = path.join(
      fixture.consumerDir,
      `${fixture.requestID}.json`,
    );
    const readback = JSON.parse(fs.readFileSync(readbackPath, "utf8"));
    const staleDigest = crypto
      .createHash("sha256")
      .update("stale-consumer-runtime")
      .digest("hex");
    const runtime = readback.readbacks.find(
      (entry) => entry.consumerID === "skillet.runtime-loader",
    );
    runtime.expectedDigest = staleDigest;
    runtime.loadedDigest = staleDigest;
    writeJSON(readbackPath, readback);

    const receipt = runAudit(fixture.options);
    assert.equal(receipt.outcome, "failed");
    assert.equal(receipt.layerStatus.consumer_readback, "failed");
    assert.ok(
      receipt.failClosedReasons.includes(
        "consumer_loaded_digest_not_in_active_store_set:skillet.runtime-loader",
      ),
    );
  } finally {
    fs.rmSync(fixture.root, { recursive: true, force: true });
  }
});

test("every skillet consumer requires a loaded digest from the active store set", () => {
  for (const consumerID of [
    "skillet.runtime-loader",
    "codex.native-skills",
    "claude.native-skills",
  ]) {
    const fixture = buildCompleteFixture();
    try {
      const readbackPath = path.join(
        fixture.consumerDir,
        `${fixture.requestID}.json`,
      );
      const readback = JSON.parse(fs.readFileSync(readbackPath, "utf8"));
      const entry = readback.readbacks.find(
        (candidate) => candidate.consumerID === consumerID,
      );
      delete entry.loadedDigest;
      writeJSON(readbackPath, readback);

      const receipt = runAudit(fixture.options);
      assert.equal(receipt.outcome, "failed", consumerID);
      assert.equal(receipt.layerStatus.consumer_readback, "failed", consumerID);
      assert.ok(
        receipt.failClosedReasons.includes(
          `consumer_loaded_digest_missing_or_invalid:${consumerID}`,
        ),
        consumerID,
      );
    } finally {
      fs.rmSync(fixture.root, { recursive: true, force: true });
    }
  }
});

test("newest local readback wins so an older green cannot shadow a newer red", () => {
  const fixture = buildCompleteFixture();
  try {
    const readbackPath = path.join(
      fixture.consumerDir,
      `${fixture.requestID}.json`,
    );
    const green = JSON.parse(fs.readFileSync(readbackPath, "utf8"));
    green.requestID = "req-old-green";
    green.observedAt = "2026-07-30T00:05:00Z";
    for (const entry of green.readbacks) {
      entry.requestID = green.requestID;
      entry.observedAt = green.observedAt;
    }
    writeJSON(path.join(fixture.consumerDir, "old-green.json"), green);

    const red = JSON.parse(fs.readFileSync(readbackPath, "utf8"));
    red.requestID = "req-new-red";
    red.status = "failed";
    delete red.observedAt;
    red.issuedAt = "2026-07-30T00:09:00Z";
    for (const entry of red.readbacks) {
      entry.requestID = red.requestID;
      delete entry.observedAt;
      entry.issuedAt = red.issuedAt;
    }
    writeJSON(readbackPath, red);

    const receipt = runAudit(fixture.options);
    const consumer = receipt.layers.find((layer) => layer.id === "consumer_readback");
    assert.equal(receipt.outcome, "failed");
    assert.equal(consumer.status, "failed");
    assert.equal(consumer.details.selected.requestID, "req-new-red");
    assert.equal(consumer.details.selected.timestamp, "2026-07-30T00:09:00Z");
    assert.equal(consumer.details.selected.timestampSource, "issuedAt");
    assert.ok(
      consumer.reasons.includes("consumer_readback_status_failed"),
    );
  } finally {
    fs.rmSync(fixture.root, { recursive: true, force: true });
  }
});

test("stale newest readback fails the bounded max-age gate", () => {
  const fixture = buildCompleteFixture();
  try {
    const receipt = runAudit({
      ...fixture.options,
      now: new Date("2026-07-30T01:00:00Z"),
      consumerReadbackMaxAgeSeconds: 900,
    });
    const consumer = receipt.layers.find((layer) => layer.id === "consumer_readback");
    assert.equal(receipt.outcome, "failed");
    assert.equal(consumer.status, "failed");
    assert.ok(consumer.reasons.includes("consumer_readback_stale"));
    assert.equal(consumer.details.maxAgeSeconds, 900);
  } finally {
    fs.rmSync(fixture.root, { recursive: true, force: true });
  }
});

test("default audit derives the durable local device identity", () => {
  const fixture = buildCompleteFixture();
  try {
    const receipt = runAudit({
      ...fixture.options,
      deviceID: null,
      target: null,
    });
    assert.equal(receipt.outcome, "passed");
    assert.equal(receipt.scope.deviceID, fixture.deviceID);
    assert.equal(receipt.scope.target, fixture.deviceID);
    assert.equal(receipt.scope.deviceIdentityStatus, "derived_local");
    assert.equal(receipt.layerStatus.consumer_readback, "passed");
  } finally {
    fs.rmSync(fixture.root, { recursive: true, force: true });
  }
});

test("default audit fails closed when local identity is unavailable", () => {
  const fixture = buildCompleteFixture();
  try {
    fs.unlinkSync(path.join(fixture.appSupport, "device-identity.json"));
    const receipt = runAudit({
      ...fixture.options,
      deviceID: null,
      target: null,
    });
    assert.notEqual(receipt.outcome, "passed");
    assert.equal(receipt.scope.deviceID, null);
    assert.equal(receipt.scope.deviceIdentityStatus, "unavailable");
    assert.equal(receipt.layerStatus.active_revision, "missing_evidence");
    assert.equal(receipt.layerStatus.consumer_readback, "missing_evidence");
    assert.ok(
      receipt.failClosedReasons.includes("consumer_readback_device_scope_unavailable"),
    );
  } finally {
    fs.rmSync(fixture.root, { recursive: true, force: true });
  }
});

test("derived local identity never accepts another device readback", () => {
  const fixture = buildCompleteFixture();
  try {
    writeJSON(path.join(fixture.appSupport, "device-identity.json"), {
      deviceId: "local-device",
      name: "local",
      createdAt: "2026-07-30T00:00:00Z",
    });
    const receipt = runAudit({
      ...fixture.options,
      deviceID: null,
      target: null,
    });
    assert.equal(receipt.outcome, "failed");
    assert.equal(receipt.scope.deviceID, "local-device");
    assert.equal(receipt.layerStatus.consumer_readback, "failed");
    assert.ok(
      receipt.failClosedReasons.includes("consumer_readback_target_device_mismatch"),
    );
  } finally {
    fs.rmSync(fixture.root, { recursive: true, force: true });
  }
});

test("remote job digest mismatch fails closed", () => {
  const fixture = buildCompleteFixture({ mutateRemoteDigest: true });
  try {
    const receipt = runAudit(fixture.options);
    assert.equal(receipt.outcome, "failed");
    assert.equal(receipt.layerStatus.remote_job_skill_binding, "mismatch");
    assert.ok(
      receipt.failClosedReasons.includes("remote_job_skill_digest_mismatch"),
    );
  } finally {
    fs.rmSync(fixture.root, { recursive: true, force: true });
  }
});

test("redaction prevents secret/token leakage in receipt output", () => {
  const fixture = buildCompleteFixture({ secretInRemoteJob: true });
  try {
    const receipt = runAudit(fixture.options);
    const serialized = JSON.stringify(receipt);
    assert.doesNotMatch(serialized, /sk-ant-supersecrettokenvalue0001/);
    assert.doesNotMatch(serialized, /ghp_abcdefghijklmnopqrstuvwxyz012345/);
    assert.doesNotMatch(serialized, /Bearer sk-ant/);
    assert.equal(receipt.redaction.policy, "fail_closed_no_secret_emission");
    assert.equal(receipt.redaction.marker, "REDACTED_SECRET");
    assert.equal(receipt.redaction.secretValuesDetectedInSource, true);
    assert.ok(receipt.redaction.secretFieldsOmitted.includes("authorization"));
    assert.ok(receipt.redaction.secretFieldsOmitted.includes("sessionToken"));
    assert.match(serialized, /REDACTED_SECRET/);

    const redactedObject = redactValue({
      authorization: "Bearer sk-ant-supersecrettokenvalue0001",
      nested: { sessionToken: "ghp_abcdefghijklmnopqrstuvwxyz012345" },
      safe: "ok",
    });
    assert.equal(redactedObject.authorization, "[REDACTED_SECRET_FIELD]");
    assert.equal(redactedObject.nested.sessionToken, "[REDACTED_SECRET_FIELD]");
    assert.equal(redactedObject.safe, "ok");
    assert.equal(
      redactString("token=sk-ant-supersecrettokenvalue0001"),
      "token=[REDACTED_SECRET]",
    );
  } finally {
    fs.rmSync(fixture.root, { recursive: true, force: true });
  }
});

test("CLI --json with fixture roots does not touch production paths", () => {
  const fixture = buildCompleteFixture();
  const receiptPath = path.join(fixture.root, "receipts", "live-audit.json");
  try {
    const readbackPath = path.join(
      fixture.consumerDir,
      `${fixture.requestID}.json`,
    );
    const currentReadback = JSON.parse(fs.readFileSync(readbackPath, "utf8"));
    const currentObservedAt = new Date().toISOString();
    currentReadback.observedAt = currentObservedAt;
    for (const entry of currentReadback.readbacks) {
      entry.observedAt = currentObservedAt;
    }
    writeJSON(readbackPath, currentReadback);

    const result = runCLI([
      "--repo-root",
      REPO_ROOT,
      "--fixture-root",
      fixture.root,
      "--store",
      fixture.store,
      "--runtime-root",
      fixture.runtimeRoot,
      "--app-bundle",
      fixture.appBundle,
      "--app-support",
      fixture.appSupport,
      "--consumer-readbacks-dir",
      path.join(fixture.root, "consumer-readbacks"),
      "--remote-job",
      fixture.remoteJobPath,
      "--device-id",
      fixture.deviceID,
      "--target",
      fixture.deviceID,
      "--repository",
      fixture.repositoryID,
      "--expected-revision",
      fixture.revisionID,
      "--expected-digest",
      fixture.contentDigest,
      "--receipt",
      receiptPath,
      "--json",
    ]);
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    const receipt = JSON.parse(result.stdout);
    assert.equal(receipt.outcome, "passed");
    assert.equal(fs.existsSync(receiptPath), true);
    const onDisk = JSON.parse(fs.readFileSync(receiptPath, "utf8"));
    assert.equal(onDisk.schema, SCHEMA);
    assert.equal(onDisk.crossMachineSkillBorrowing.claim, "not_asserted");
  } finally {
    fs.rmSync(fixture.root, { recursive: true, force: true });
  }
});

test("runtime digest helper matches portable skillet snapshot contract", () => {
  const root = makeRoot("runtime-digest");
  try {
    const skill = "# skill\n";
    const repository = path.join(root, "repo");
    writeText(path.join(repository, "SKILL.md"), skill);
    const expected = portableDigest([{ relativePath: "SKILL.md", data: skill }]);
    const actual = snapshotDigestFromRuntime(repository);
    assert.equal(actual.ok, true);
    assert.equal(actual.contentDigest, expected);
    assert.equal(actual.hasSkillManifest, true);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("runtime digest excludes any-depth .git only and keeps other dotfiles", () => {
  const root = makeRoot("runtime-digest-dotfiles");
  try {
    const repository = path.join(root, "repo");
    const skill = "# skill\n";
    const gitignore = "node_modules\n";
    const dsStore = "ds-store-fixture\n";
    const backup = "# previous\n";
    writeText(path.join(repository, "SKILL.md"), skill);
    writeText(path.join(repository, ".gitignore"), gitignore);
    writeText(path.join(repository, "assets", ".DS_Store"), dsStore);
    writeText(path.join(repository, ".backup"), backup);
    writeText(path.join(repository, ".git", "config"), "[core]\n");
    writeText(path.join(repository, "nested", ".git", "HEAD"), "ref: refs/heads/main\n");
    writeText(path.join(repository, "vendor", ".GIT", "index"), "gitdir\n");

    assert.equal(isExcludedSnapshotMetadata(".git"), true);
    assert.equal(isExcludedSnapshotMetadata("nested/.git/HEAD"), true);
    assert.equal(isExcludedSnapshotMetadata("vendor/.GIT/index"), true);
    assert.equal(isExcludedSnapshotMetadata(".gitignore"), false);
    assert.equal(isExcludedSnapshotMetadata("assets/.DS_Store"), false);
    assert.equal(isExcludedSnapshotMetadata(".backup"), false);

    const expected = portableDigest([
      { relativePath: ".backup", data: backup },
      { relativePath: ".gitignore", data: gitignore },
      { relativePath: "SKILL.md", data: skill },
      { relativePath: "assets/.DS_Store", data: dsStore },
    ]);
    const actual = snapshotDigestFromRuntime(repository);
    assert.equal(actual.ok, true);
    assert.equal(actual.contentDigest, expected);
    assert.equal(actual.fileCount, 4);
    assert.equal(actual.hasSkillManifest, true);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
