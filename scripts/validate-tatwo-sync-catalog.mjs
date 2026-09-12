#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const VALID_SCOPES = new Set(["shared", "deviceOverlay", "localOnly", "forbidden"]);
const VALID_WRITER_DECISIONS = new Set([
  "cataloged",
  "localOnly",
  "forbidden",
  "ephemeral",
  "verificationArtifact",
]);
const DURABLE_WRITER_PATTERNS = [
  {
    primitive: "swift-data-write",
    extensions: new Set([".swift"]),
    pattern: /\.write\s*\(\s*to\s*:/,
  },
  {
    primitive: "swift-file-handle-write",
    extensions: new Set([".swift"]),
    pattern: /\.write\s*\(\s*contentsOf\s*:/,
  },
  {
    primitive: "swift-string-write",
    extensions: new Set([".swift"]),
    pattern: /\.write\s*\(\s*toFile\s*:/,
  },
  {
    primitive: "swift-create-file",
    extensions: new Set([".swift"]),
    pattern: /\bcreateFile\s*\(/,
  },
  {
    primitive: "swift-replace-item",
    extensions: new Set([".swift"]),
    pattern: /\breplaceItemAt\s*\(/,
  },
  {
    primitive: "swift-move-item",
    extensions: new Set([".swift"]),
    pattern: /\bmoveItem\s*\(/,
  },
  {
    primitive: "swift-copy-item",
    extensions: new Set([".swift"]),
    pattern: /\bcopyItem\s*\(/,
  },
  {
    primitive: "swift-remove-item",
    extensions: new Set([".swift"]),
    pattern: /\bremoveItem\s*\(/,
  },
  {
    primitive: "swift-set-attributes",
    extensions: new Set([".swift"]),
    pattern: /\b(?:FileManager\.default|\w*[Ff]ile[Mm]anager)\.setAttributes\s*\(/,
  },
  {
    primitive: "swift-host-write",
    extensions: new Set([".swift"]),
    pattern: /\bwriteFile\s*\(/,
  },
  {
    primitive: "swift-user-defaults",
    extensions: new Set([".swift"]),
    pattern: /\bUserDefaults\b.*\.set\s*\(/,
  },
  {
    primitive: "swift-keyed-setting",
    extensions: new Set([".swift"]),
    pattern: /\.(?:set|removeObject)\s*\(.*\bforKey\s*:/,
  },
  {
    primitive: "node-write-file",
    extensions: new Set([".mjs", ".js", ".cjs"]),
    pattern: /\b(?:fs\.)?writeFile(?:Sync)?\s*\(/,
  },
  {
    primitive: "node-append-file",
    extensions: new Set([".mjs", ".js", ".cjs"]),
    pattern: /\b(?:fs\.)?appendFile(?:Sync)?\s*\(/,
  },
  {
    primitive: "node-create-write-stream",
    extensions: new Set([".mjs", ".js", ".cjs"]),
    pattern: /\b(?:fs\.)?createWriteStream\s*\(/,
  },
  {
    primitive: "node-rename",
    extensions: new Set([".mjs", ".js", ".cjs"]),
    pattern: /\b(?:fs\.)?rename(?:Sync)?\s*\(/,
  },
  {
    primitive: "node-copy-file",
    extensions: new Set([".mjs", ".js", ".cjs"]),
    pattern: /\b(?:fs\.)?copyFile(?:Sync)?\s*\(/,
  },
  {
    primitive: "node-remove",
    extensions: new Set([".mjs", ".js", ".cjs"]),
    pattern: /\b(?:fs\.)?(?:rm|unlink)(?:Sync)?\s*\(/,
  },
  {
    primitive: "python-open-write",
    extensions: new Set([".py"]),
    pattern:
      /\bopen\s*\([^#\n]*,\s*(?:[rubf]*["'][wax+][a-z+]*["']|mode\s*=\s*["'][wax+][a-z+]*["'])/,
  },
  {
    primitive: "python-json-dump",
    extensions: new Set([".py"]),
    pattern: /\bjson\.dump\s*\(/,
  },
  {
    primitive: "python-path-write",
    extensions: new Set([".py"]),
    pattern: /\.write_(?:text|bytes)\s*\(/,
  },
  {
    primitive: "python-shutil-copy",
    extensions: new Set([".py"]),
    pattern: /\bshutil\.(?:copy|copy2|copyfile|copytree)\s*\(/,
  },
  {
    primitive: "python-shutil-move",
    extensions: new Set([".py"]),
    pattern: /\bshutil\.move\s*\(/,
  },
  {
    primitive: "python-shutil-remove",
    extensions: new Set([".py"]),
    pattern: /\bshutil\.rmtree\s*\(/,
  },
  {
    primitive: "python-os-create-directory",
    extensions: new Set([".py"]),
    pattern: /\bos\.(?:mkdir|makedirs)\s*\(/,
  },
  {
    primitive: "python-os-remove",
    extensions: new Set([".py"]),
    pattern: /\bos\.(?:remove|unlink|rmdir|removedirs)\s*\(/,
  },
  {
    primitive: "python-path-create-directory",
    extensions: new Set([".py"]),
    pattern: /\.mkdir\s*\(/,
  },
  {
    primitive: "python-path-remove",
    extensions: new Set([".py"]),
    pattern: /\.(?:unlink|rmdir)\s*\(/,
  },
  {
    primitive: "python-path-rename-replace",
    extensions: new Set([".py"]),
    pattern: /\bPath\s*\([^#\n]*\)\.(?:rename|replace)\s*\(/,
  },
  {
    primitive: "shell-redirection",
    extensions: new Set([".sh"]),
    pattern: /(?:^|[;&|]\s*|\s)(?:cat|printf|echo)\b[^#\n]*(?:>>|>)(?!=)/,
  },
  {
    primitive: "shell-copy-move-install",
    extensions: new Set([".sh"]),
    pattern: /(?:^|[;&|]\s*|\s)(?:cp|mv|install)\s+(?:-[^\s]+\s+)*/,
  },
  {
    primitive: "shell-tee",
    extensions: new Set([".sh"]),
    pattern: /(?:^|[;&|]\s*|\s)tee\s+(?:-[^\s]+\s+)*/,
  },
  {
    primitive: "shell-touch",
    extensions: new Set([".sh"]),
    pattern: /(?:^|[;&|]\s*|\s)touch\s+(?:-[^\s]+\s+)*/,
  },
  {
    primitive: "shell-create-directory",
    extensions: new Set([".sh"]),
    pattern:
      /(?:^\s*|[;&|]\s*|\b(?:if|then|do)\s+(?:!\s*)?)mkdir\s+(?:-[^\s]+\s+)*/,
  },
  {
    primitive: "shell-remove",
    extensions: new Set([".sh"]),
    pattern:
      /(?:^\s*|[;&|]\s*|\b(?:if|then|do)\s+(?:!\s*)?)rm\s+(?:-[^\s]+\s+)*/,
  },
  {
    primitive: "shell-remove-directory",
    extensions: new Set([".sh"]),
    pattern:
      /(?:^\s*|[;&|]\s*|\b(?:if|then|do)\s+(?:!\s*)?)rmdir\s+(?:-[^\s]+\s+)*/,
  },
  {
    primitive: "shell-link",
    extensions: new Set([".sh"]),
    pattern:
      /(?:^\s*|[;&|]\s*|\b(?:if|then|do)\s+(?:!\s*)?)ln\s+(?:-[^\s]+\s+)*/,
  },
  {
    primitive: "shell-in-place-write",
    extensions: new Set([".sh"]),
    pattern: /(?:^|[;&|]\s*|\s)(?:sed\s+-[^\s]*i|perl\s+-[^\s]*i|defaults\s+write|plutil\s+-(?:replace|insert|remove)|sqlite3\b)/,
  },
];
const EXCLUDED_DISCOVERY_COMPONENTS = new Set([
  ".git",
  ".build",
  "DerivedData",
  "Tests",
  "tests",
  "docs",
  "receipts",
  ".tatwo-ultrawork",
]);

export function validateSyncCatalog(document, inventoryDocument = null) {
  if (!document || typeof document !== "object" || Array.isArray(document)) {
    throw new Error("sync catalog must be a JSON object");
  }
  if (document.schemaVersion !== 1) {
    throw new Error(`unsupported schemaVersion: ${String(document.schemaVersion)}`);
  }
  if (typeof document.catalogRevision !== "string" || !document.catalogRevision.trim()) {
    throw new Error("catalogRevision must not be empty");
  }
  if (!Array.isArray(document.persistentSurfaceIDs)) {
    throw new Error("persistentSurfaceIDs must be an array");
  }
  if (!Array.isArray(document.systemPullItemIDs)) {
    throw new Error("systemPullItemIDs must be an array");
  }
  if (!Array.isArray(document.deferredSystemPullItemIDs)) {
    throw new Error("deferredSystemPullItemIDs must be an array");
  }
  if (!Array.isArray(document.entries)) {
    throw new Error("entries must be an array");
  }

  const declaredSurfaces = new Set();
  for (const id of document.persistentSurfaceIDs) {
    assertIdentifier(id, "persistent surface");
    if (declaredSurfaces.has(id)) {
      throw new Error(`duplicate persistent surface id: ${id}`);
    }
    declaredSurfaces.add(id);
  }
  const surfaces = inventoryDocument
    ? validateDurableSurfaceInventory(inventoryDocument)
    : declaredSurfaces;
  if (inventoryDocument) {
    const undeclared = [...surfaces].filter((id) => !declaredSurfaces.has(id)).sort();
    const unknown = [...declaredSurfaces].filter((id) => !surfaces.has(id)).sort();
    if (undeclared.length > 0 || unknown.length > 0) {
      throw new Error(
        `catalog surface declaration differs from durable inventory: missing=[${undeclared.join(
          ", "
        )}] unknown=[${unknown.join(", ")}]`
      );
    }
  }

  const entries = new Map();
  for (const entry of document.entries) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
      throw new Error("catalog entry must be an object");
    }
    assertIdentifier(entry.id, "catalog entry");
    if (entries.has(entry.id)) {
      throw new Error(`duplicate catalog entry id: ${entry.id}`);
    }
    if (!VALID_SCOPES.has(entry.scope)) {
      throw new Error(`invalid scope for ${entry.id}: ${String(entry.scope)}`);
    }
    if (!Array.isArray(entry.requiredOnDevices)) {
      throw new Error(`requiredOnDevices must be an array for ${entry.id}`);
    }

    const transferPath =
      typeof entry.relativePath === "string" ? entry.relativePath.trim() : "";
    if (entry.scope === "forbidden" || entry.scope === "localOnly") {
      if (transferPath) {
        throw new Error(`${entry.scope} entry exposes transfer path: ${entry.id}`);
      }
      if (entry.requiredOnDevices.length > 0) {
        throw new Error(`${entry.scope} entry requires peer devices: ${entry.id}`);
      }
      if (entry.mergePolicy !== "never" || entry.activationPolicy !== "never") {
        throw new Error(`${entry.scope} entry must use never policies: ${entry.id}`);
      }
    } else {
      if (!transferPath) {
        throw new Error(`transferable entry is missing relativePath: ${entry.id}`);
      }
      if (
        path.isAbsolute(transferPath) ||
        transferPath.split("/").some((component) => component === "..")
      ) {
        throw new Error(`unsafe relativePath for ${entry.id}: ${transferPath}`);
      }
    }
    entries.set(entry.id, entry);
  }

  const missing = [...surfaces].filter((id) => !entries.has(id)).sort();
  if (missing.length > 0) {
    throw new Error(`unregistered persistent surfaces: ${missing.join(", ")}`);
  }
  const extra = [...entries.keys()].filter((id) => !surfaces.has(id)).sort();
  if (extra.length > 0) {
    throw new Error(`catalog entries absent from durable inventory: ${extra.join(", ")}`);
  }

  const decisions = new Set();
  for (const [classification, ids] of [
    ["active", document.systemPullItemIDs],
    ["deferred", document.deferredSystemPullItemIDs],
  ]) {
    for (const id of ids) {
      assertIdentifier(id, `${classification} system-pull`);
      if (decisions.has(id)) {
        throw new Error(`duplicate system-pull decision: ${id}`);
      }
      decisions.add(id);
      const entry = entries.get(id);
      if (!entry) {
        throw new Error(`unknown ${classification} system-pull surface: ${id}`);
      }
      if (classification === "active" && entry.scope !== "shared") {
        throw new Error(`active system-pull surface must be shared: ${id}`);
      }
    }
  }
  const unclassifiedTransferable = [...entries.values()]
    .filter((entry) => entry.scope === "shared" || entry.scope === "deviceOverlay")
    .map((entry) => entry.id)
    .filter((id) => !decisions.has(id))
    .sort();
  if (unclassifiedTransferable.length > 0) {
    throw new Error(
      `transferable surfaces lack active/deferred system-pull decision: ${unclassifiedTransferable.join(
        ", "
      )}`
    );
  }

  return {
    catalogRevision: document.catalogRevision,
    entryCount: entries.size,
    persistentSurfaceCount: surfaces.size,
    systemPullItemCount: document.systemPullItemIDs.length,
    deferredSystemPullItemCount: document.deferredSystemPullItemIDs.length,
  };
}

export function loadAndValidateSyncCatalog(catalogPath) {
  const document = JSON.parse(fs.readFileSync(catalogPath, "utf8"));
  const inventoryPath = path.join(
    path.dirname(catalogPath),
    "tatwo-durable-surface-inventory-v1.json"
  );
  const inventory = JSON.parse(fs.readFileSync(inventoryPath, "utf8"));
  return validateSyncCatalog(document, inventory);
}

export function validateDurableSurfaceInventory(document) {
  if (!document || typeof document !== "object" || Array.isArray(document)) {
    throw new Error("durable surface inventory must be a JSON object");
  }
  if (document.schemaVersion !== 1) {
    throw new Error(`unsupported inventory schemaVersion: ${String(document.schemaVersion)}`);
  }
  if (
    typeof document.inventoryRevision !== "string" ||
    !document.inventoryRevision.trim()
  ) {
    throw new Error("inventoryRevision must not be empty");
  }
  if (!Array.isArray(document.surfaceIDs)) {
    throw new Error("surfaceIDs must be an array");
  }
  const surfaces = new Set();
  for (const id of document.surfaceIDs) {
    assertIdentifier(id, "durable inventory surface");
    if (surfaces.has(id)) {
      throw new Error(`duplicate durable inventory surface id: ${id}`);
    }
    surfaces.add(id);
  }
  return surfaces;
}

export function scanDurableWriterSites(repositoryRoot, discoveryDocument) {
  if (!discoveryDocument || typeof discoveryDocument !== "object") {
    throw new Error("durable writer discovery document must be an object");
  }
  if (!Array.isArray(discoveryDocument.scanRoots) || discoveryDocument.scanRoots.length === 0) {
    throw new Error("durable writer discovery scanRoots must not be empty");
  }
  const root = path.resolve(repositoryRoot);
  const sites = [];
  for (const relativeRoot of discoveryDocument.scanRoots) {
    if (
      typeof relativeRoot !== "string" ||
      !relativeRoot.trim() ||
      path.isAbsolute(relativeRoot) ||
      relativeRoot.split("/").some((component) => component === "..")
    ) {
      throw new Error(`unsafe durable writer scan root: ${String(relativeRoot)}`);
    }
    const scanRoot = path.resolve(root, relativeRoot);
    if (scanRoot !== root && !scanRoot.startsWith(`${root}${path.sep}`)) {
      throw new Error(`durable writer scan root escapes repository: ${relativeRoot}`);
    }
    if (!fs.existsSync(scanRoot)) continue;
    for (const fileURL of walkSourceFiles(scanRoot)) {
      const relativePath = path.relative(root, fileURL).split(path.sep).join("/");
      const extension = path.extname(fileURL);
      const patterns = DURABLE_WRITER_PATTERNS.filter((candidate) =>
        candidate.extensions.has(extension)
      );
      if (patterns.length === 0) continue;
      const occurrences = new Map();
      const lines = fs.readFileSync(fileURL, "utf8").split(/\r?\n/);
      lines.forEach((line, index) => {
        const signature = normalizeWriterLine(line);
        if (!signature || isCommentOnlyLine(signature)) return;
        for (const candidate of patterns) {
          if (!candidate.pattern.test(line)) continue;
          const occurrenceKey = `${candidate.primitive}\0${signature}`;
          const occurrence = (occurrences.get(occurrenceKey) ?? 0) + 1;
          occurrences.set(occurrenceKey, occurrence);
          sites.push({
            path: relativePath,
            line: index + 1,
            primitive: candidate.primitive,
            signature,
            occurrence,
          });
        }
      });
    }
  }
  return sites.sort(compareWriterSites);
}

export function computeDurableWriterFingerprint(sites) {
  const stable = [...sites]
    .sort(compareWriterSites)
    .map(({ path: filePath, primitive, signature, occurrence }) => ({
      path: filePath,
      primitive,
      signature,
      occurrence,
    }));
  return crypto.createHash("sha256").update(JSON.stringify(stable)).digest("hex");
}

export function validateDurableWriterDiscovery(document, catalogDocument, sites) {
  if (!document || typeof document !== "object" || Array.isArray(document)) {
    throw new Error("durable writer discovery must be a JSON object");
  }
  if (document.schemaVersion !== 1) {
    throw new Error(
      `unsupported durable writer discovery schemaVersion: ${String(document.schemaVersion)}`
    );
  }
  if (
    typeof document.discoveryRevision !== "string" ||
    !document.discoveryRevision.trim()
  ) {
    throw new Error("discoveryRevision must not be empty");
  }
  if (!Array.isArray(document.pathPolicies)) {
    throw new Error("durable writer pathPolicies must be an array");
  }
  const policies = [];
  const policyKeys = new Set();
  for (const policy of document.pathPolicies) {
    if (!policy || typeof policy !== "object" || Array.isArray(policy)) {
      throw new Error("durable writer path policy must be an object");
    }
    const hasExactPath = typeof policy.path === "string" && policy.path.length > 0;
    const hasPathPrefix =
      typeof policy.pathPrefix === "string" && policy.pathPrefix.length > 0;
    if (hasExactPath === hasPathPrefix) {
      throw new Error("durable writer policy requires exactly one of path or pathPrefix");
    }
    const selector = hasExactPath ? policy.path : policy.pathPrefix;
    if (
      path.isAbsolute(selector) ||
      selector.split("/").some((component) => component === "..")
    ) {
      throw new Error(`unsafe durable writer policy path: ${String(selector)}`);
    }
    const policyKey = `${hasExactPath ? "path" : "prefix"}:${selector}`;
    if (policyKeys.has(policyKey)) {
      throw new Error(`duplicate durable writer path policy: ${selector}`);
    }
    policyKeys.add(policyKey);
    if (!VALID_WRITER_DECISIONS.has(policy.decision)) {
      throw new Error(`invalid durable writer decision for ${selector}: ${String(policy.decision)}`);
    }
    if (typeof policy.reason !== "string" || !policy.reason.trim()) {
      throw new Error(`durable writer policy reason is required: ${selector}`);
    }
    if (
      policy.surfaceIDs !== undefined &&
      (!Array.isArray(policy.surfaceIDs) ||
        policy.surfaceIDs.some((id) => typeof id !== "string" || !id))
    ) {
      throw new Error(`invalid durable writer surfaceIDs: ${selector}`);
    }
    policies.push(policy);
  }

  const sitePaths = new Set(sites.map((site) => site.path));
  const resolvedPolicies = new Map();
  const matchedPolicies = new Set();
  for (const filePath of sitePaths) {
    const matches = policies
      .map((policy, index) => ({
        policy,
        index,
        specificity:
          typeof policy.path === "string"
            ? 1_000_000 + policy.path.length
            : policy.pathPrefix.length,
      }))
      .filter(({ policy }) =>
        typeof policy.path === "string"
          ? policy.path === filePath
          : filePath.startsWith(policy.pathPrefix)
      )
      .sort((left, right) => right.specificity - left.specificity);
    if (matches.length === 0) continue;
    if (
      matches.length > 1 &&
      matches[0].specificity === matches[1].specificity
    ) {
      throw new Error(`ambiguous durable writer path policies: ${filePath}`);
    }
    resolvedPolicies.set(filePath, matches[0].policy);
    matchedPolicies.add(matches[0].index);
  }
  const unclassified = [...sitePaths]
    .filter((filePath) => !resolvedPolicies.has(filePath))
    .sort();
  if (unclassified.length > 0) {
    throw new Error(`unclassified durable writer paths: ${unclassified.join(", ")}`);
  }
  const stalePolicies = policies
    .map((policy, index) => ({ policy, index }))
    .filter(({ index }) => !matchedPolicies.has(index))
    .map(({ policy }) => policy.path ?? `${policy.pathPrefix}*`)
    .sort();
  if (stalePolicies.length > 0) {
    throw new Error(`durable writer policies have no discovered sites: ${stalePolicies.join(", ")}`);
  }

  const catalogEntries = new Map(
    (Array.isArray(catalogDocument?.entries) ? catalogDocument.entries : []).map((entry) => [
      entry.id,
      entry,
    ])
  );
  const syncDecisions = new Set([
    ...(catalogDocument?.systemPullItemIDs ?? []),
    ...(catalogDocument?.deferredSystemPullItemIDs ?? []),
  ]);
  for (const policy of new Set(resolvedPolicies.values())) {
    const surfaceIDs = policy.surfaceIDs ?? [];
    const selector = policy.path ?? `${policy.pathPrefix}*`;
    if (policy.decision === "cataloged" && surfaceIDs.length === 0) {
      throw new Error(`cataloged writer policy has no surfaceIDs: ${selector}`);
    }
    if (
      (policy.decision === "ephemeral" ||
        policy.decision === "verificationArtifact") &&
      surfaceIDs.length > 0
    ) {
      throw new Error(
        `${policy.decision} writer policy cannot declare surfaceIDs: ${selector}`
      );
    }
    for (const id of surfaceIDs) {
      const entry = catalogEntries.get(id);
      if (!entry) {
        throw new Error(`writer policy references unknown sync surface: ${id}`);
      }
      if (
        policy.decision === "cataloged" &&
        (entry.scope === "shared" || entry.scope === "deviceOverlay") &&
        !syncDecisions.has(id)
      ) {
        throw new Error(`writer policy surface lacks active/deferred decision: ${id}`);
      }
      if (policy.decision === "localOnly" && entry.scope !== "localOnly") {
        throw new Error(`localOnly writer policy references non-local surface: ${id}`);
      }
      if (policy.decision === "forbidden" && entry.scope !== "forbidden") {
        throw new Error(`forbidden writer policy references non-forbidden surface: ${id}`);
      }
    }
    if (
      policy.decision === "cataloged" &&
      !surfaceIDs.some((id) => {
        const scope = catalogEntries.get(id)?.scope;
        return scope === "shared" || scope === "deviceOverlay";
      })
    ) {
      throw new Error(
        `cataloged writer policy has no shared or deviceOverlay surface: ${selector}`
      );
    }
  }

  const fingerprint = computeDurableWriterFingerprint(sites);
  if (
    document.reviewedSiteCount !== sites.length ||
    document.reviewedFingerprint !== fingerprint
  ) {
    throw new Error(
      `durable writer source snapshot changed: reviewedCount=${String(
        document.reviewedSiteCount
      )} actualCount=${sites.length} reviewedFingerprint=${String(
        document.reviewedFingerprint
      )} actualFingerprint=${fingerprint}`
    );
  }

  return {
    discoveryRevision: document.discoveryRevision,
    siteCount: sites.length,
    classifiedPathCount: resolvedPolicies.size,
    fingerprint,
  };
}

export function loadAndValidateDurableWriterDiscovery(
  repositoryRoot,
  catalogPath,
  discoveryPath
) {
  const catalog = JSON.parse(fs.readFileSync(catalogPath, "utf8"));
  const discovery = JSON.parse(fs.readFileSync(discoveryPath, "utf8"));
  const sites = scanDurableWriterSites(repositoryRoot, discovery);
  return validateDurableWriterDiscovery(discovery, catalog, sites);
}

function assertIdentifier(value, label) {
  if (
    typeof value !== "string" ||
    !value ||
    value.trim() !== value ||
    value.includes("/")
  ) {
    throw new Error(`invalid ${label} id: ${String(value)}`);
  }
}

function* walkSourceFiles(root) {
  const entries = fs.readdirSync(root, { withFileTypes: true }).sort((a, b) =>
    compareCodepoints(a.name, b.name)
  );
  for (const entry of entries) {
    if (EXCLUDED_DISCOVERY_COMPONENTS.has(entry.name)) continue;
    const target = path.join(root, entry.name);
    if (entry.isDirectory()) {
      yield* walkSourceFiles(target);
      continue;
    }
    if (entry.isFile()) yield target;
  }
}

function normalizeWriterLine(line) {
  return line.trim().replace(/\s+/g, " ");
}

function isCommentOnlyLine(line) {
  return (
    line.startsWith("//") ||
    line.startsWith("/*") ||
    line.startsWith("*") ||
    line.startsWith("#")
  );
}

function compareCodepoints(left, right) {
  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
}

function compareWriterSites(left, right) {
  return (
    compareCodepoints(left.path, right.path) ||
    compareCodepoints(left.primitive, right.primitive) ||
    compareCodepoints(left.signature, right.signature) ||
    left.occurrence - right.occurrence
  );
}

function isMainModule() {
  return process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
}

if (isMainModule()) {
  const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const catalogPath = path.resolve(
    process.argv[2] ?? path.join(repositoryRoot, "config/tatwo-sync-catalog-v1.json")
  );
  const discoveryPath = path.join(
    path.dirname(catalogPath),
    "tatwo-durable-writer-discovery-v1.json"
  );
  try {
    const result = loadAndValidateSyncCatalog(catalogPath);
    const writerResult = loadAndValidateDurableWriterDiscovery(
      repositoryRoot,
      catalogPath,
      discoveryPath
    );
    console.log(
      `SYNC_CATALOG_VALID revision=${result.catalogRevision} entries=${result.entryCount} surfaces=${result.persistentSurfaceCount} writerSites=${writerResult.siteCount} writerPaths=${writerResult.classifiedPathCount} writerFingerprint=${writerResult.fingerprint}`
    );
  } catch (error) {
    console.error(`SYNC_CATALOG_INVALID ${error instanceof Error ? error.message : error}`);
    process.exitCode = 1;
  }
}
