import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  computeDurableWriterFingerprint,
  loadAndValidateDurableWriterDiscovery,
  scanDurableWriterSites,
  validateDurableWriterDiscovery,
  loadAndValidateSyncCatalog,
  validateSyncCatalog,
} from "../scripts/validate-tatwo-sync-catalog.mjs";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const catalogPath = path.join(repositoryRoot, "config/tatwo-sync-catalog-v1.json");
const inventoryPath = path.join(
  repositoryRoot,
  "config/tatwo-durable-surface-inventory-v1.json"
);
const discoveryPath = path.join(
  repositoryRoot,
  "config/tatwo-durable-writer-discovery-v1.json"
);

test("versioned sync catalog validates", () => {
  const result = loadAndValidateSyncCatalog(catalogPath);
  assert.equal(result.catalogRevision, "2026-07-29.1");
  assert.ok(result.entryCount >= 43);
  assert.equal(result.entryCount, result.persistentSurfaceCount);
  assert.equal(result.systemPullItemCount, 4);
  assert.ok(result.deferredSystemPullItemCount > 0);
});

test("persistent surface without policy fails closed", () => {
  const document = JSON.parse(fs.readFileSync(catalogPath, "utf8"));
  const inventory = JSON.parse(fs.readFileSync(inventoryPath, "utf8"));
  document.persistentSurfaceIDs.push("future.persistent-feature");
  assert.throws(
    () => validateSyncCatalog(document, inventory),
    /catalog surface declaration differs from durable inventory/
  );
});

test("catalog cannot hide a durable surface by deleting both internal declarations", () => {
  const document = JSON.parse(fs.readFileSync(catalogPath, "utf8"));
  const inventory = JSON.parse(fs.readFileSync(inventoryPath, "utf8"));
  document.entries = document.entries.filter((entry) => entry.id !== "os.issue");
  document.persistentSurfaceIDs = document.persistentSurfaceIDs.filter(
    (id) => id !== "os.issue"
  );
  assert.throws(
    () => validateSyncCatalog(document, inventory),
    /catalog surface declaration differs from durable inventory: missing=\[os\.issue\]/
  );
});

test("catalog cannot invent an entry absent from the durable inventory", () => {
  const document = JSON.parse(fs.readFileSync(catalogPath, "utf8"));
  const inventory = JSON.parse(fs.readFileSync(inventoryPath, "utf8"));
  document.entries.push({
    id: "future.uninventoried-surface",
    displayName: "Future uninventoried surface",
    kind: "durableState",
    scope: "shared",
    relativePath: "future/uninventoried",
    requiredOnDevices: ["all-enrolled-devices"],
    mergePolicy: "keyedJSON",
    activationPolicy: "automaticAfterValidation",
  });
  document.deferredSystemPullItemIDs.push("future.uninventoried-surface");
  assert.throws(
    () => validateSyncCatalog(document, inventory),
    /catalog entries absent from durable inventory: future\.uninventoried-surface/
  );
});

test("local-only and forbidden entries cannot expose transfer paths", () => {
  for (const scope of ["localOnly", "forbidden"]) {
    const document = JSON.parse(fs.readFileSync(catalogPath, "utf8"));
    const inventory = JSON.parse(fs.readFileSync(inventoryPath, "utf8"));
    const entry = document.entries.find((candidate) => candidate.scope === scope);
    entry.relativePath = `unsafe/${scope}`;
    assert.throws(
      () => validateSyncCatalog(document, inventory),
      new RegExp(`${scope} entry exposes transfer path`)
    );
  }
});

test("every transferable feature has an explicit active or deferred system-pull decision", () => {
  const document = JSON.parse(fs.readFileSync(catalogPath, "utf8"));
  const inventory = JSON.parse(fs.readFileSync(inventoryPath, "utf8"));
  document.deferredSystemPullItemIDs = document.deferredSystemPullItemIDs.filter(
    (id) => id !== "registry.models"
  );
  assert.throws(
    () => validateSyncCatalog(document, inventory),
    /transferable surfaces lack active\/deferred system-pull decision: registry\.models/
  );
});

test("active system-pull set is the catalog source of truth and includes Skillet", () => {
  const document = JSON.parse(fs.readFileSync(catalogPath, "utf8"));
  assert.deepEqual(document.systemPullItemIDs, [
    "os.constitution",
    "os.issue",
    "os.todo",
    "skills.skillet",
  ]);
});

test("production durable writer discovery matches the reviewed source snapshot", () => {
  const result = loadAndValidateDurableWriterDiscovery(
    repositoryRoot,
    catalogPath,
    discoveryPath
  );
  assert.ok(result.siteCount > 0);
  assert.ok(result.classifiedPathCount > 0);
  assert.match(result.fingerprint, /^[a-f0-9]{64}$/);
});

test("durable writer fingerprint uses locale-independent codepoint ordering", () => {
  const sites = [
    {
      path: "scripts/example.sh",
      primitive: "shell-mv",
      signature: 'mv "$source" "$target"',
      occurrence: 1,
    },
    {
      path: "Scripts/example.sh",
      primitive: "shell-mv",
      signature: 'mv "$source" "$target"',
      occurrence: 1,
    },
  ];
  const stable = [...sites]
    .sort((left, right) => {
      for (const key of ["path", "primitive", "signature"]) {
        if (left[key] < right[key]) return -1;
        if (left[key] > right[key]) return 1;
      }
      return left.occurrence - right.occurrence;
    })
    .map(({ path: filePath, primitive, signature, occurrence }) => ({
      path: filePath,
      primitive,
      signature,
      occurrence,
    }));
  const expected = crypto
    .createHash("sha256")
    .update(JSON.stringify(stable))
    .digest("hex");

  assert.equal(computeDurableWriterFingerprint(sites), expected);
});

test("a new durable writer file fails closed even when catalog lists stay unchanged", () => {
  const fixtureRoot = fs.mkdtempSync(
    path.join(process.env.TMPDIR ?? "/tmp", "tatwo-writer-discovery-")
  );
  const source = path.join(
    fixtureRoot,
    "Packages/FutureFeature/Sources/FutureFeature/FutureStore.swift"
  );
  fs.mkdirSync(path.dirname(source), { recursive: true });
  fs.writeFileSync(
    source,
    'try Data("future".utf8).write(to: destination, options: [.atomic])\n'
  );

  const sites = scanDurableWriterSites(fixtureRoot, {
    scanRoots: ["Packages"],
  });
  assert.equal(sites.length, 1);
  assert.throws(
    () =>
      validateDurableWriterDiscovery(
        {
          schemaVersion: 1,
          discoveryRevision: "fixture.1",
          scanRoots: ["Packages"],
          reviewedSiteCount: sites.length,
          reviewedFingerprint: computeDurableWriterFingerprint(sites),
          pathPolicies: [],
        },
        {
          entries: [],
          systemPullItemIDs: [],
          deferredSystemPullItemIDs: [],
        },
        sites
      ),
    /unclassified durable writer paths: Packages\/FutureFeature\/Sources\/FutureFeature\/FutureStore\.swift/
  );
});

test("a new write site inside a classified file invalidates the reviewed fingerprint", () => {
  const fixtureRoot = fs.mkdtempSync(
    path.join(process.env.TMPDIR ?? "/tmp", "tatwo-writer-fingerprint-")
  );
  const source = path.join(
    fixtureRoot,
    "Packages/GoalStore/Sources/GoalStore/GoalStore.swift"
  );
  fs.mkdirSync(path.dirname(source), { recursive: true });
  fs.writeFileSync(
    source,
    "try encoder.encode(goal).write(to: goalURL, options: [.atomic])\n"
  );
  const reviewedSites = scanDurableWriterSites(fixtureRoot, {
    scanRoots: ["Packages"],
  });
  const discovery = {
    schemaVersion: 1,
    discoveryRevision: "fixture.2",
    scanRoots: ["Packages"],
    reviewedSiteCount: reviewedSites.length,
    reviewedFingerprint: computeDurableWriterFingerprint(reviewedSites),
    pathPolicies: [
      {
        path: "Packages/GoalStore/Sources/GoalStore/GoalStore.swift",
        decision: "cataloged",
        surfaceIDs: ["work.goal-state"],
        reason: "fixture goal state",
      },
    ],
  };
  const catalog = {
    entries: [{ id: "work.goal-state", scope: "shared" }],
    systemPullItemIDs: [],
    deferredSystemPullItemIDs: ["work.goal-state"],
  };
  validateDurableWriterDiscovery(discovery, catalog, reviewedSites);

  fs.appendFileSync(
    source,
    "try encoder.encode(plan).write(to: planURL, options: [.atomic])\n"
  );
  const changedSites = scanDurableWriterSites(fixtureRoot, {
    scanRoots: ["Packages"],
  });
  assert.throws(
    () => validateDurableWriterDiscovery(discovery, catalog, changedSites),
    /durable writer source snapshot changed/
  );
});

test("cataloged writer policy cannot reference an unknown sync surface", () => {
  const sites = [
    {
      path: "Packages/Future/Sources/Future/Store.swift",
      primitive: "swift-data-write",
      signature: "try data.write(to: target)",
      occurrence: 1,
    },
  ];
  assert.throws(
    () =>
      validateDurableWriterDiscovery(
        {
          schemaVersion: 1,
          discoveryRevision: "fixture.3",
          scanRoots: ["Packages"],
          reviewedSiteCount: 1,
          reviewedFingerprint: computeDurableWriterFingerprint(sites),
          pathPolicies: [
            {
              path: "Packages/Future/Sources/Future/Store.swift",
              decision: "cataloged",
              surfaceIDs: ["future.unknown"],
              reason: "fixture",
            },
          ],
        },
        {
          entries: [],
          systemPullItemIDs: [],
          deferredSystemPullItemIDs: [],
        },
        sites
      ),
    /writer policy references unknown sync surface: future\.unknown/
  );
});

test("ephemeral and verification-artifact writer policies cannot claim sync surfaces", () => {
  const sites = [
    {
      path: "scripts/future-runtime.mjs",
      primitive: "node-write-file",
      signature: 'writeFileSync("future.json", "{}")',
      occurrence: 1,
    },
  ];
  const catalog = {
    entries: [{ id: "work.goal-state", scope: "shared" }],
    systemPullItemIDs: [],
    deferredSystemPullItemIDs: ["work.goal-state"],
  };

  for (const decision of ["ephemeral", "verificationArtifact"]) {
    assert.throws(
      () =>
        validateDurableWriterDiscovery(
          {
            schemaVersion: 1,
            discoveryRevision: `fixture.${decision}`,
            scanRoots: ["scripts"],
            reviewedSiteCount: 1,
            reviewedFingerprint: computeDurableWriterFingerprint(sites),
            pathPolicies: [
              {
                path: "scripts/future-runtime.mjs",
                decision,
                surfaceIDs: ["work.goal-state"],
                reason: "fixture must fail closed",
              },
            ],
          },
          catalog,
          sites
        ),
      new RegExp(`${decision} writer policy cannot declare surfaceIDs`)
    );
  }
});

test("cataloged writer policy must bind a shared or device-overlay surface", () => {
  const sites = [
    {
      path: "Packages/Future/Sources/Future/LocalStore.swift",
      primitive: "swift-data-write",
      signature: "try data.write(to: target)",
      occurrence: 1,
    },
  ];
  assert.throws(
    () =>
      validateDurableWriterDiscovery(
        {
          schemaVersion: 1,
          discoveryRevision: "fixture.cataloged-local-only",
          scanRoots: ["Packages"],
          reviewedSiteCount: 1,
          reviewedFingerprint: computeDurableWriterFingerprint(sites),
          pathPolicies: [
            {
              path: "Packages/Future/Sources/Future/LocalStore.swift",
              decision: "cataloged",
              surfaceIDs: ["machine.runtime-state"],
              reason: "fixture must fail closed",
            },
          ],
        },
        {
          entries: [{ id: "machine.runtime-state", scope: "localOnly" }],
          systemPullItemIDs: [],
          deferredSystemPullItemIDs: [],
        },
        sites
      ),
    /cataloged writer policy has no shared or deviceOverlay surface/
  );
});

test("common append, deletion, metadata, and in-place writer primitives are discovered", () => {
  const fixtureRoot = fs.mkdtempSync(
    path.join(process.env.TMPDIR ?? "/tmp", "tatwo-writer-primitives-")
  );
  const swiftSource = path.join(
    fixtureRoot,
    "Packages/Future/Sources/Future/RuntimeStore.swift"
  );
  const nodeSource = path.join(fixtureRoot, "scripts/future-runtime.mjs");
  const shellSource = path.join(fixtureRoot, "scripts/future-runtime.sh");
  fs.mkdirSync(path.dirname(swiftSource), { recursive: true });
  fs.mkdirSync(path.dirname(nodeSource), { recursive: true });
  fs.writeFileSync(
    swiftSource,
    [
      "try handle.write(contentsOf: payload)",
      "try FileManager.default.removeItem(at: stale)",
      "try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)",
      'defaults.set("value", forKey: "future.key")',
    ].join("\n")
  );
  fs.writeFileSync(
    nodeSource,
    [
      'fs.appendFileSync("ledger.jsonl", "{}\\n")',
      'fs.createWriteStream("stream.log")',
      'fs.unlinkSync("stale.json")',
    ].join("\n")
  );
  fs.writeFileSync(
    shellSource,
    [
      'printf "%s\\n" "$value" | tee "$state_file"',
      'touch "$marker"',
      'plutil -replace Status -string ready "$plist"',
    ].join("\n")
  );

  const sites = scanDurableWriterSites(fixtureRoot, {
    scanRoots: ["Packages", "scripts"],
  });
  assert.deepEqual(
    [...new Set(sites.map((site) => site.primitive))].sort(),
    [
      "node-append-file",
      "node-create-write-stream",
      "node-remove",
      "shell-in-place-write",
      "shell-tee",
      "shell-touch",
      "swift-file-handle-write",
      "swift-keyed-setting",
      "swift-remove-item",
      "swift-set-attributes",
    ]
  );
});

test("common Python durable writer primitives are discovered", () => {
  const fixtureRoot = fs.mkdtempSync(
    path.join(process.env.TMPDIR ?? "/tmp", "tatwo-python-writer-primitives-")
  );
  const pythonSource = path.join(fixtureRoot, "scripts/future-runtime.py");
  fs.mkdirSync(path.dirname(pythonSource), { recursive: true });
  fs.writeFileSync(
    pythonSource,
    [
      'with open(state_path, "w", encoding="utf-8") as handle:',
      "    json.dump(payload, handle)",
      'Path(marker).write_text("ready", encoding="utf-8")',
      "Path(blob).write_bytes(payload)",
      "shutil.copy2(source, destination)",
      "shutil.move(staged, active)",
      "shutil.rmtree(stale)",
      "os.makedirs(state_dir, exist_ok=True)",
      "os.remove(stale_file)",
      "Path(cache_dir).mkdir(parents=True, exist_ok=True)",
      "Path(old_dir).rmdir()",
      "Path(old_file).unlink()",
      "Path(staged_file).replace(active_file)",
      "Path(active_file).rename(previous_file)",
    ].join("\n")
  );

  const sites = scanDurableWriterSites(fixtureRoot, {
    scanRoots: ["scripts"],
  });
  assert.deepEqual(
    [...new Set(sites.map((site) => site.primitive))].sort(),
    [
      "python-json-dump",
      "python-open-write",
      "python-os-create-directory",
      "python-os-remove",
      "python-path-create-directory",
      "python-path-remove",
      "python-path-rename-replace",
      "python-path-write",
      "python-shutil-copy",
      "python-shutil-move",
      "python-shutil-remove",
    ]
  );
});

test("shell directory and link mutation primitives are discovered", () => {
  const fixtureRoot = fs.mkdtempSync(
    path.join(process.env.TMPDIR ?? "/tmp", "tatwo-shell-writer-primitives-")
  );
  const shellSource = path.join(fixtureRoot, "scripts/future-runtime.sh");
  fs.mkdirSync(path.dirname(shellSource), { recursive: true });
  fs.writeFileSync(
    shellSource,
    [
      'mkdir -p "$state_dir"',
      'rm -rf "$stale_dir"',
      'rmdir "$empty_dir"',
      'ln -sfn "$source" "$active_link"',
    ].join("\n")
  );

  const sites = scanDurableWriterSites(fixtureRoot, {
    scanRoots: ["scripts"],
  });
  assert.deepEqual(
    [...new Set(sites.map((site) => site.primitive))].sort(),
    [
      "shell-create-directory",
      "shell-link",
      "shell-remove",
      "shell-remove-directory",
    ]
  );
});
