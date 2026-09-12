#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_REGISTRY = path.join(
  HERE,
  "..",
  "config",
  "tatwo-skillet-source-registry-v1.json",
);
const SAFE_ID = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const STORE_LOCK_OWNER_ENV = "TATWO_SKILLET_REFRESH_STORE_LOCK_OWNER_PID";

function defaultSkilletSourceRoot() {
  return path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "Tatwo Ultrawork",
    "skills",
  );
}

function canonicalPortablePath(value) {
  return value.normalize("NFC");
}

function comparePortablePaths(left, right) {
  return Buffer.compare(
    Buffer.from(canonicalPortablePath(left), "utf8"),
    Buffer.from(canonicalPortablePath(right), "utf8"),
  );
}

function parseArgs(argv) {
  const options = {
    sourceRoot:
      process.env.TATWO_SKILLET_SOURCE_ROOT
      ?? process.env.TATWO_SKILLS_CANONICAL_DIR
      ?? defaultSkilletSourceRoot(),
    fallbackSourceRoot:
      process.env.TATWO_SKILLET_SOURCE_FALLBACK_ROOT
      ?? process.env.TATWO_SKILLS_RUNTIME_ROOT
      ?? null,
    store:
      process.env.TATWO_SKILLET_STORE
      ?? path.join(
        os.homedir(),
        "Library",
        "Application Support",
        "Tatwo Ultrawork",
        "skillet",
      ),
    registry: process.env.TATWO_SKILLET_SOURCE_REGISTRY ?? DEFAULT_REGISTRY,
    cli:
      process.env.TATWO_SKILLET_CLI
      ?? path.join(os.homedir(), ".local", "bin", "tatwo-ultrawork"),
    receipt: null,
    channel: "staging",
    fallbackAuthorization: null,
    fallbackAuthorizationPath: null,
    fallbackAuthorizationDigest: null,
    currentDeviceName: null,
    currentDeviceID: null,
    authorityPrimary: null,
    authorityEpoch: null,
    attemptID: null,
    target: null,
    action: "system-pull",
    requestedAt: null,
    ledgerSequence: null,
    catalogRevision: null,
    sourceDeviceID: null,
    targetDeviceID: null,
    dryRun: false,
    json: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--dry-run") {
      options.dryRun = true;
      continue;
    }
    if (argument === "--json") {
      options.json = true;
      continue;
    }
    const key = {
      "--source-root": "sourceRoot",
      "--fallback-source-root": "fallbackSourceRoot",
      "--store": "store",
      "--registry": "registry",
      "--cli": "cli",
      "--receipt": "receipt",
      "--channel": "channel",
      "--fallback-authorization": "fallbackAuthorization",
      "--fallback-authorization-path": "fallbackAuthorizationPath",
      "--fallback-authorization-digest": "fallbackAuthorizationDigest",
      "--current-device-name": "currentDeviceName",
      "--current-device-id": "currentDeviceID",
      "--authority-primary": "authorityPrimary",
      "--authority-epoch": "authorityEpoch",
      "--attempt-id": "attemptID",
      "--target": "target",
      "--action": "action",
      "--requested-at": "requestedAt",
      "--ledger-sequence": "ledgerSequence",
      "--catalog-revision": "catalogRevision",
      "--source-device-id": "sourceDeviceID",
      "--target-device-id": "targetDeviceID",
    }[argument];
    if (!key || index + 1 >= argv.length) {
      throw new Error(
        "Usage: tatwo-skillet-refresh.mjs "
          + "[--source-root PATH] [--fallback-source-root PATH] "
          + "[--store PATH] [--registry PATH] "
          + "[--cli PATH] [--receipt PATH] [--channel staging] "
          + "[--fallback-authorization PATH --fallback-authorization-path RELATIVE_PATH "
          + "--fallback-authorization-digest SHA256 --current-device-name NAME "
          + "--current-device-id ID --authority-primary NAME --authority-epoch N "
          + "--attempt-id ID --target NAME --action system-pull "
          + "--requested-at ISO8601 --ledger-sequence N --catalog-revision REVISION "
          + "--source-device-id ID --target-device-id ID] "
          + "[--dry-run] [--json]",
      );
    }
    options[key] = argv[index + 1];
    index += 1;
  }
  if (!["draft", "staging", "canary", "stable", "rollback"].includes(options.channel)) {
    throw new Error("--channel must be draft|staging|canary|stable|rollback");
  }
  return options;
}

function sourceFailureError(
  message,
  {
    code = null,
    sourceName = "canonical-source-discovery",
    repositoryID = "",
    displayName = "Skillet canonical source discovery",
  } = {},
) {
  const error = new Error(message);
  if (code) error.code = code;
  error.skilletRefreshResults = [{
    sourceName,
    repositoryID,
    displayName,
    status: "failed",
    message,
  }];
  return error;
}

function readJSON(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function sha256File(filePath) {
  return crypto.createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
}

function isSafeRelativeArtifactPath(value) {
  return (
    typeof value === "string"
    && value.length > 0
    && !path.isAbsolute(value)
    && !value.includes("\\")
    && !value.includes("\0")
    && value.split("/").every((component) =>
      component.length > 0 && component !== "." && component !== ".."
    )
  );
}

function validateFallbackAuthorization(options) {
  const required = [
    options.fallbackAuthorization,
    options.fallbackAuthorizationPath,
    options.fallbackAuthorizationDigest,
    options.currentDeviceName,
    options.currentDeviceID,
    options.authorityPrimary,
    options.authorityEpoch,
  ];
  if (required.some((value) => typeof value !== "string" || value.length === 0)) {
    throw new Error(
      "Runtime fallback requires an explicit authority-bound fallback authorization",
    );
  }
  if (
    !path.isAbsolute(options.fallbackAuthorization)
    || !isSafeRelativeArtifactPath(options.fallbackAuthorizationPath)
    || !/^[0-9a-f]{64}$/.test(options.fallbackAuthorizationDigest)
    || !SAFE_ID.test(options.currentDeviceName)
    || !SAFE_ID.test(options.currentDeviceID)
    || !SAFE_ID.test(options.authorityPrimary)
    || !/^[0-9]+$/.test(options.authorityEpoch)
  ) {
    throw new Error("Runtime fallback authorization arguments are malformed");
  }
  const stat = fs.lstatSync(options.fallbackAuthorization);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw new Error("Runtime fallback authorization must be a regular file");
  }
  const actualDigest = sha256File(options.fallbackAuthorization);
  if (actualDigest !== options.fallbackAuthorizationDigest) {
    throw new Error("Runtime fallback authorization digest mismatch");
  }
  const authorization = readJSON(options.fallbackAuthorization);
  if (
    authorization?.schema !== "TatwoSkilletRuntimeFallbackAuthorizationV1"
    || authorization?.sourceMode !== "runtime-fallback"
    || typeof authorization?.authorizationID !== "string"
    || !SAFE_ID.test(authorization.authorizationID)
    || authorization?.authorizedDeviceName !== options.currentDeviceName
    || authorization?.authorizedDeviceID !== options.currentDeviceID
    || authorization?.authorityPrimary !== options.authorityPrimary
    || String(authorization?.authorityEpoch) !== options.authorityEpoch
    || authorization?.scope !== "authority-epoch"
    || authorization?.signaturePurpose !== "skillet-runtime-fallback-authorization"
  ) {
    throw new Error(
      "Runtime fallback authorization is stale, belongs to another device, or has invalid scope",
    );
  }
  return {
    fallbackAuthorizationID: authorization.authorizationID,
    fallbackAuthorizationPath: options.fallbackAuthorizationPath,
    fallbackAuthorizationDigest: actualDigest,
  };
}

function validateRegistry(document) {
  if (
    document?.schemaVersion !== 1
    || !Array.isArray(document.repositoryAliases)
    || (
      document.retiredRepositoryIDs !== undefined
      && !Array.isArray(document.retiredRepositoryIDs)
    )
  ) {
    throw new Error(
      "Skillet source registry must use schemaVersion=1, "
        + "repositoryAliases[], and optional retiredRepositoryIDs[]",
    );
  }
  const bySourceName = new Map();
  const byRepositoryID = new Map();
  for (const alias of document.repositoryAliases) {
    const canonicalSourceName = typeof alias?.sourceName === "string"
      ? canonicalPortablePath(alias.sourceName)
      : null;
    const canonicalDisplayName = typeof alias?.displayName === "string"
      ? alias.displayName.normalize("NFC")
      : null;
    if (
      typeof alias?.sourceName !== "string"
      || alias.sourceName.trim() !== alias.sourceName
      || alias.sourceName.length === 0
      || canonicalSourceName !== alias.sourceName
      || typeof alias?.repositoryID !== "string"
      || !SAFE_ID.test(alias.repositoryID)
      || typeof alias?.displayName !== "string"
      || alias.displayName.trim() !== alias.displayName
      || alias.displayName.length === 0
      || canonicalDisplayName !== alias.displayName
    ) {
      throw new Error("Skillet source registry contains an invalid alias entry");
    }
    if (bySourceName.has(alias.sourceName)) {
      throw new Error(`Duplicate Skillet source alias: ${alias.sourceName}`);
    }
    if (byRepositoryID.has(alias.repositoryID)) {
      throw new Error(`Duplicate Skillet repository id alias: ${alias.repositoryID}`);
    }
    bySourceName.set(alias.sourceName, alias);
    byRepositoryID.set(alias.repositoryID, alias);
  }
  const retiredRepositoryIDs = new Set();
  for (const repositoryID of document.retiredRepositoryIDs ?? []) {
    if (typeof repositoryID !== "string" || !SAFE_ID.test(repositoryID)) {
      throw new Error("Skillet source registry contains an invalid retired repository id");
    }
    if (retiredRepositoryIDs.has(repositoryID)) {
      throw new Error(`Duplicate retired Skillet repository id: ${repositoryID}`);
    }
    if (byRepositoryID.has(repositoryID)) {
      throw new Error(
        `Skillet repository cannot be both active and retired: ${repositoryID}`,
      );
    }
    retiredRepositoryIDs.add(repositoryID);
  }
  return { bySourceName, byRepositoryID, retiredRepositoryIDs };
}

function assertAbsoluteReadableDirectory(directory, label) {
  if (typeof directory !== "string" || !path.isAbsolute(directory)) {
    throw sourceFailureError(`${label} must be an absolute path`, {
      sourceName: "canonical-source-root",
      displayName: "Canonical Skills source root",
    });
  }
  try {
    fs.accessSync(directory, fs.constants.R_OK | fs.constants.X_OK);
  } catch {
    throw sourceFailureError(`${label} is not readable`, {
      code: "SKILLET_SOURCE_ROOT_UNAVAILABLE",
      sourceName: "canonical-source-root",
      displayName: "Canonical Skills source root",
    });
  }
  let stat;
  try {
    stat = fs.statSync(directory);
  } catch {
    throw sourceFailureError(`${label} is unavailable`, {
      code: "SKILLET_SOURCE_ROOT_UNAVAILABLE",
      sourceName: "canonical-source-root",
      displayName: "Canonical Skills source root",
    });
  }
  if (!stat.isDirectory()) {
    throw sourceFailureError(`${label} is not a directory`, {
      code: "SKILLET_SOURCE_ROOT_UNAVAILABLE",
      sourceName: "canonical-source-root",
      displayName: "Canonical Skills source root",
    });
  }
}

function resolvePathForComparison(value) {
  let candidate = path.resolve(value);
  const suffix = [];
  while (!fs.existsSync(candidate)) {
    const parent = path.dirname(candidate);
    if (parent === candidate) break;
    suffix.unshift(path.basename(candidate));
    candidate = parent;
  }
  let resolved = candidate;
  try {
    resolved = fs.realpathSync.native(candidate);
  } catch {
    resolved = path.resolve(candidate);
  }
  return path.join(resolved, ...suffix);
}

function pathsOverlap(left, right) {
  const normalizedLeft = resolvePathForComparison(left);
  const normalizedRight = resolvePathForComparison(right);
  return (
    normalizedLeft === normalizedRight
    || normalizedLeft.startsWith(`${normalizedRight}${path.sep}`)
    || normalizedRight.startsWith(`${normalizedLeft}${path.sep}`)
  );
}

function assertSeparatedRoots(options) {
  const checks = [
    [
      options.sourceRoot,
      options.fallbackSourceRoot,
      "Skillet canonical source root and runtime fallback root must be separate",
    ],
    [
      options.sourceRoot,
      options.store,
      "Skillet canonical source root and repository store must be separate",
    ],
    [
      options.fallbackSourceRoot,
      options.store,
      "Skillet runtime fallback root and repository store must be separate",
    ],
  ];
  for (const [left, right, message] of checks) {
    if (
      typeof left === "string"
      && typeof right === "string"
      && path.isAbsolute(left)
      && path.isAbsolute(right)
      && pathsOverlap(left, right)
    ) {
      throw new Error(message);
    }
  }
}

function inspectSourceEntry(sourceRoot, entry) {
  const sourceLinkPath = path.join(sourceRoot, entry.name);
  let linkStat;
  try {
    linkStat = fs.lstatSync(sourceLinkPath);
  } catch {
    throw sourceFailureError(`Skillet source entry is unreadable: ${entry.name}`, {
      sourceName: canonicalPortablePath(entry.name),
      displayName: canonicalPortablePath(entry.name),
    });
  }
  let sourcePath;
  try {
    sourcePath = fs.realpathSync(sourceLinkPath);
  } catch {
    if (linkStat.isSymbolicLink()) {
      throw sourceFailureError(`Broken Skillet source symlink: ${entry.name}`, {
        sourceName: canonicalPortablePath(entry.name),
        displayName: canonicalPortablePath(entry.name),
      });
    }
    throw sourceFailureError(`Skillet source entry is unreadable: ${entry.name}`, {
      sourceName: canonicalPortablePath(entry.name),
      displayName: canonicalPortablePath(entry.name),
    });
  }
  let sourceStat;
  try {
    sourceStat = fs.statSync(sourcePath);
  } catch {
    throw sourceFailureError(`Skillet source entry is unreadable: ${entry.name}`, {
      sourceName: canonicalPortablePath(entry.name),
      displayName: canonicalPortablePath(entry.name),
    });
  }
  if (!sourceStat.isDirectory()) {
    if (linkStat.isSymbolicLink()) {
      throw sourceFailureError(
        `Skillet source symlink does not target a directory: ${entry.name}`,
        {
          sourceName: canonicalPortablePath(entry.name),
          displayName: canonicalPortablePath(entry.name),
        },
      );
    }
    return null;
  }
  if (!fs.existsSync(path.join(sourcePath, "SKILL.md"))) {
    if (linkStat.isSymbolicLink()) {
      throw sourceFailureError(
        `Skillet source symlink target lacks SKILL.md: ${entry.name}`,
        {
          sourceName: canonicalPortablePath(entry.name),
          displayName: canonicalPortablePath(entry.name),
        },
      );
    }
    return null;
  }
  return {
    entryName: canonicalPortablePath(entry.name),
    sourcePath,
  };
}

function uint64BigEndian(value) {
  const buffer = Buffer.alloc(8);
  buffer.writeBigUInt64BE(BigInt(value));
  return buffer;
}

function snapshotDigest(files) {
  const hasher = crypto.createHash("sha256");
  const canonicalFiles = files.map((file) => ({
    ...file,
    relativePath: canonicalPortablePath(file.relativePath),
  }));
  if (
    new Set(canonicalFiles.map((file) => file.relativePath)).size
      !== canonicalFiles.length
  ) {
    throw new Error("Skillet snapshot contains duplicate canonical paths");
  }
  for (const file of canonicalFiles.sort((left, right) =>
    comparePortablePaths(left.relativePath, right.relativePath)
  )) {
    const relativePath = Buffer.from(file.relativePath, "utf8");
    hasher.update(uint64BigEndian(relativePath.length));
    hasher.update(relativePath);
    hasher.update(uint64BigEndian(file.data.length));
    hasher.update(file.data);
  }
  return hasher.digest("hex");
}

function inspectSourceTree(sourcePath, label) {
  const files = [];
  const canonicalPaths = new Set();
  const visit = (directory, prefix) => {
    const entries = fs.readdirSync(directory, { withFileTypes: true })
      .sort((left, right) => comparePortablePaths(left.name, right.name));
    for (const entry of entries) {
      const canonicalName = canonicalPortablePath(entry.name);
      const relativePath = prefix ? `${prefix}/${canonicalName}` : canonicalName;
      const absolutePath = path.join(directory, entry.name);
      const stat = fs.lstatSync(absolutePath);
      if (stat.isSymbolicLink()) {
        throw new Error(`Skillet source contains unsupported symlink: ${label}/${relativePath}`);
      }
      if (canonicalName.toLowerCase() === ".git") continue;
      if (stat.isDirectory()) {
        visit(absolutePath, relativePath);
        continue;
      }
      if (!stat.isFile()) {
        throw new Error(`Skillet source contains unsupported entry: ${label}/${relativePath}`);
      }
      if (canonicalPaths.has(relativePath)) {
        throw new Error(
          `Skillet source contains duplicate canonical path: ${label}/${relativePath}`,
        );
      }
      canonicalPaths.add(relativePath);
      files.push({
        relativePath,
        data: fs.readFileSync(absolutePath),
      });
    }
  };
  visit(sourcePath, "");
  return {
    digest: snapshotDigest(files),
    files,
  };
}

function discoverSources(sourceRoot, registry) {
  assertAbsoluteReadableDirectory(sourceRoot, "Skillet canonical source root");
  const bySourceName = registry?.bySourceName ?? registry;
  const byRepositoryID = registry?.byRepositoryID ?? new Map(
    [...bySourceName.values()].map((alias) => [alias.repositoryID, alias]),
  );
  const discoveredEntries = new Map();
  for (const entry of fs.readdirSync(sourceRoot, { withFileTypes: true })) {
    if (entry.name.startsWith(".")) continue;
    const inspected = inspectSourceEntry(sourceRoot, entry);
    if (!inspected) continue;
    if (discoveredEntries.has(inspected.entryName)) {
      throw new Error(
        `Duplicate canonical Skillet source entry: ${inspected.entryName}`,
      );
    }
    discoveredEntries.set(inspected.entryName, inspected);
  }

  const sources = [];
  const consumedEntryNames = new Set();
  const staleAliases = [];
  for (const alias of bySourceName.values()) {
    const canonicalEntry = discoveredEntries.get(alias.sourceName);
    const repositoryEntry = alias.repositoryID === alias.sourceName
      ? canonicalEntry
      : discoveredEntries.get(alias.repositoryID);
    if (!canonicalEntry && !repositoryEntry) {
      staleAliases.push(alias.sourceName);
      continue;
    }
    let selected = canonicalEntry ?? repositoryEntry;
    let sourceLayout = canonicalEntry ? "canonical-name" : "repository-id";
    if (
      canonicalEntry
      && repositoryEntry
      && canonicalEntry.entryName !== repositoryEntry.entryName
    ) {
      consumedEntryNames.add(canonicalEntry.entryName);
      consumedEntryNames.add(repositoryEntry.entryName);
      if (canonicalEntry.sourcePath !== repositoryEntry.sourcePath) {
        const canonicalSnapshot = inspectSourceTree(
          canonicalEntry.sourcePath,
          canonicalEntry.entryName,
        );
        const repositorySnapshot = inspectSourceTree(
          repositoryEntry.sourcePath,
          repositoryEntry.entryName,
        );
        if (canonicalSnapshot.digest !== repositorySnapshot.digest) {
          throw new Error(
            `Conflicting duplicate Skillet sources for ${alias.repositoryID}: `
              + `${alias.sourceName}, ${alias.repositoryID}`,
          );
        }
      }
      selected = canonicalEntry;
      sourceLayout = "canonical-name-with-identical-repository-id-duplicate";
    } else {
      consumedEntryNames.add(selected.entryName);
    }
    sources.push({
      sourceName: alias.sourceName,
      sourceEntryName: selected.entryName,
      sourceLayout,
      sourcePath: selected.sourcePath,
      repositoryID: alias.repositoryID,
      displayName: alias.displayName,
    });
  }
  if (staleAliases.length > 0) {
    staleAliases.sort();
    throw new Error(`Skillet source registry has stale aliases: ${staleAliases.join(", ")}`);
  }

  for (const entry of discoveredEntries.values()) {
    if (consumedEntryNames.has(entry.entryName)) continue;
    const alias =
      bySourceName.get(entry.entryName)
      ?? byRepositoryID.get(entry.entryName);
    const repositoryID = alias?.repositoryID ?? entry.entryName;
    if (!SAFE_ID.test(repositoryID)) {
      throw sourceFailureError(
        `Canonical skill "${entry.entryName}" needs an explicit ASCII repository alias`,
        {
          sourceName: entry.entryName,
          displayName: entry.entryName,
        },
      );
    }
    sources.push({
      sourceName: alias?.sourceName ?? entry.entryName,
      sourceEntryName: entry.entryName,
      sourceLayout: alias ? "repository-id" : "direct",
      sourcePath: entry.sourcePath,
      repositoryID,
      displayName: alias?.displayName ?? entry.entryName,
    });
  }
  sources.sort((left, right) =>
    comparePortablePaths(left.repositoryID, right.repositoryID)
  );

  const repositoryIDs = new Set();
  for (const source of sources) {
    if (repositoryIDs.has(source.repositoryID)) {
      throw new Error(`Duplicate discovered Skillet repository id: ${source.repositoryID}`);
    }
    repositoryIDs.add(source.repositoryID);
  }
  if (sources.length === 0) {
    throw sourceFailureError("No canonical skills were discovered", {
      code: "SKILLET_SOURCE_ROOT_EMPTY",
      sourceName: "canonical-source-root",
      displayName: "Canonical Skills source root",
    });
  }
  return sources;
}

function inventoryDigest(sources, retiredRepositoryIDs = []) {
  const canonical = {
    repositories: sources.map(({ sourceName, repositoryID, displayName }) => ({
      sourceName,
      repositoryID,
      displayName,
    })),
    retiredRepositoryIDs: [...retiredRepositoryIDs].sort(),
  };
  return crypto
    .createHash("sha256")
    .update(JSON.stringify(canonical))
    .digest("hex");
}

function listStoreRepositories(store) {
  const repositoryRoot = path.join(store, "repositories");
  if (!fs.existsSync(repositoryRoot)) return [];
  return fs.readdirSync(repositoryRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && !entry.name.startsWith("."))
    .map((entry) => entry.name)
    .sort();
}

function directoryTreeDigest(directory) {
  if (!fs.existsSync(directory)) return "absent";
  const rootStat = fs.lstatSync(directory);
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) {
    throw new Error("Skillet store is not a safe directory");
  }
  const hasher = crypto.createHash("sha256");
  const updatePath = (kind, relativePath) => {
    const encoded = Buffer.from(relativePath, "utf8");
    hasher.update(kind);
    hasher.update(uint64BigEndian(encoded.length));
    hasher.update(encoded);
  };
  const visit = (current, prefix) => {
    const entries = fs.readdirSync(current, { withFileTypes: true })
      .sort((left, right) => comparePortablePaths(left.name, right.name));
    for (const entry of entries) {
      const canonicalName = canonicalPortablePath(entry.name);
      const relativePath = prefix ? `${prefix}/${canonicalName}` : canonicalName;
      const absolutePath = path.join(current, entry.name);
      const stat = fs.lstatSync(absolutePath);
      if (stat.isSymbolicLink()) {
        throw new Error(`Skillet store contains a symbolic link: ${relativePath}`);
      }
      if (stat.isDirectory()) {
        updatePath("D", relativePath);
        visit(absolutePath, relativePath);
        continue;
      }
      if (!stat.isFile()) {
        throw new Error(`Skillet store contains an unsupported entry: ${relativePath}`);
      }
      const data = fs.readFileSync(absolutePath);
      updatePath("F", relativePath);
      hasher.update(uint64BigEndian(data.length));
      hasher.update(data);
    }
  };
  visit(directory, "");
  return hasher.digest("hex");
}

function reapStaleStagingStores(parent, basename) {
  const prefix = `.${basename}.refresh-staging-`;
  const lockPrefix = `.${prefix}`;
  let reapedStagingStoreCount = 0;
  let reapedStagingStoreLockCount = 0;
  for (const entry of fs.readdirSync(parent, { withFileTypes: true })) {
    const isStagingStore = entry.name.startsWith(prefix);
    const isStagingStoreLock =
      entry.name.startsWith(lockPrefix)
      && entry.name.endsWith(".store-mutation.lock");
    if (!isStagingStore && !isStagingStoreLock) continue;
    const target = path.join(parent, entry.name);
    const stat = fs.lstatSync(target);
    if (isStagingStore && stat.isDirectory() && !stat.isSymbolicLink()) {
      fs.rmSync(target, { recursive: true, force: true });
      reapedStagingStoreCount += 1;
      continue;
    }
    if (
      isStagingStoreLock
      &&
      stat.isFile()
      && !stat.isSymbolicLink()
    ) {
      fs.unlinkSync(target);
      reapedStagingStoreLockCount += 1;
      continue;
    }
    throw new Error("Skillet stale refresh staging entry is unsafe");
  }
  return { reapedStagingStoreCount, reapedStagingStoreLockCount };
}

function recoverInterruptedExchange(store) {
  const parent = path.dirname(store);
  const basename = path.basename(store);
  const prefix = `.${basename}.refresh-exchange-`;
  const candidates = fs.readdirSync(parent, { withFileTypes: true })
    .filter((entry) => entry.name.startsWith(prefix));
  for (const entry of candidates) {
    const target = path.join(parent, entry.name);
    const stat = fs.lstatSync(target);
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      throw new Error("Skillet interrupted exchange recovery entry is unsafe");
    }
  }
  if (candidates.length === 0) {
    return {
      recoveredInterruptedExchange: false,
      reapedInterruptedExchangeCount: 0,
    };
  }
  if (!fs.existsSync(store)) {
    if (candidates.length !== 1) {
      throw new Error("Skillet interrupted exchange recovery is ambiguous");
    }
    fs.renameSync(path.join(parent, candidates[0].name), store);
    return {
      recoveredInterruptedExchange: true,
      reapedInterruptedExchangeCount: 0,
    };
  }
  for (const entry of candidates) {
    fs.rmSync(path.join(parent, entry.name), {
      recursive: true,
      force: true,
    });
  }
  return {
    recoveredInterruptedExchange: false,
    reapedInterruptedExchangeCount: candidates.length,
  };
}

function prepareStagedStore(store) {
  if (typeof store !== "string" || !path.isAbsolute(store)) {
    throw new Error("Skillet store must be an absolute path");
  }
  const parent = path.dirname(store);
  const basename = path.basename(store);
  fs.mkdirSync(parent, { recursive: true });
  const {
    recoveredInterruptedExchange,
    reapedInterruptedExchangeCount,
  } = recoverInterruptedExchange(store);
  const {
    reapedStagingStoreCount,
    reapedStagingStoreLockCount,
  } = reapStaleStagingStores(parent, basename);
  const stagingStore = path.join(
    parent,
    `.${basename}.refresh-staging-${process.pid}-${crypto.randomUUID()}`,
  );
  const liveStoreDigest = directoryTreeDigest(store);
  if (fs.existsSync(store)) {
    fs.cpSync(store, stagingStore, {
      recursive: true,
      preserveTimestamps: true,
      errorOnExist: true,
    });
  } else {
    fs.mkdirSync(stagingStore, { recursive: true });
  }
  return {
    stagingStore,
    liveStoreDigest,
    recoveredInterruptedExchange,
    reapedInterruptedExchangeCount,
    reapedStagingStoreCount,
    reapedStagingStoreLockCount,
  };
}

function retireStagedRepositories(store, retiredRepositoryIDs) {
  const retirements = [];
  for (const repositoryID of [...retiredRepositoryIDs].sort()) {
    const active = path.join(store, "repositories", repositoryID);
    const retired = path.join(store, "retired-repositories", repositoryID);
    if (fs.existsSync(active)) {
      const activeStat = fs.lstatSync(active);
      if (!activeStat.isDirectory() || activeStat.isSymbolicLink()) {
        throw new Error(`Retired Skillet repository is unsafe: ${repositoryID}`);
      }
      if (fs.existsSync(retired)) {
        throw new Error(
          `Retired Skillet repository archive already conflicts: ${repositoryID}`,
        );
      }
      fs.mkdirSync(path.dirname(retired), { recursive: true });
      fs.renameSync(active, retired);
      retirements.push({ repositoryID, status: "retired-and-archived" });
      continue;
    }
    if (fs.existsSync(retired)) {
      const retiredStat = fs.lstatSync(retired);
      if (!retiredStat.isDirectory() || retiredStat.isSymbolicLink()) {
        throw new Error(`Retired Skillet repository archive is unsafe: ${repositoryID}`);
      }
      retirements.push({ repositoryID, status: "already-retired" });
    } else {
      retirements.push({ repositoryID, status: "tombstone-recorded" });
    }
  }
  return retirements;
}

function compensatingDirectoryExchange(
  left,
  right,
  {
    beforeCompensatingExchangeStep = null,
    beforeCompensatingRollbackStep = null,
  } = {},
) {
  const leftStat = fs.lstatSync(left);
  const rightStat = fs.lstatSync(right);
  if (
    !leftStat.isDirectory()
    || leftStat.isSymbolicLink()
    || !rightStat.isDirectory()
    || rightStat.isSymbolicLink()
    || leftStat.dev !== rightStat.dev
  ) {
    throw new Error("Skillet compensating directory exchange is unsafe");
  }
  const temporary = path.join(
    path.dirname(left),
    `.${path.basename(left)}.refresh-exchange-${crypto.randomUUID()}`,
  );

  beforeCompensatingExchangeStep?.(1, left, temporary);
  try {
    fs.renameSync(left, temporary);
  } catch {
    throw new Error("Skillet compensating directory exchange failed");
  }

  try {
    beforeCompensatingExchangeStep?.(2, right, left);
    fs.renameSync(right, left);
  } catch (error) {
    try {
      beforeCompensatingRollbackStep?.(1, temporary, left);
      fs.renameSync(temporary, left);
    } catch {
      throw new Error("Skillet compensating directory exchange rollback failed");
    }
    throw error;
  }

  try {
    beforeCompensatingExchangeStep?.(3, temporary, right);
    fs.renameSync(temporary, right);
  } catch (error) {
    try {
      beforeCompensatingRollbackStep?.(1, left, right);
      fs.renameSync(left, right);
    } catch {
      throw new Error("Skillet compensating directory exchange rollback failed");
    }
    try {
      beforeCompensatingRollbackStep?.(2, temporary, left);
      fs.renameSync(temporary, left);
    } catch {
      throw new Error("Skillet compensating directory exchange rollback failed");
    }
    throw error;
  }
}

function atomicallyExchangeDirectories(
  left,
  right,
  {
    forceCompensatingExchange = false,
    beforeCompensatingExchangeStep = null,
    beforeCompensatingRollbackStep = null,
  } = {},
) {
  if (forceCompensatingExchange) {
    compensatingDirectoryExchange(left, right, {
      beforeCompensatingExchangeStep,
      beforeCompensatingRollbackStep,
    });
    return "compensating-exchange";
  }
  const python = resolveExecutable(process.env.TATWO_PYTHON3 ?? "python3");
  if (!python) {
    throw new Error("Skillet atomic store exchange requires python3");
  }
  const helper = String.raw`
import ctypes
import errno
import os
import sys

left, right = (os.fsencode(value) for value in sys.argv[1:])
libc = ctypes.CDLL(None, use_errno=True)
renamex_np = libc.renamex_np
renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
renamex_np.restype = ctypes.c_int
RENAME_SWAP = 0x00000002
if renamex_np(left, right, RENAME_SWAP) == 0:
    print("swapped")
    raise SystemExit(0)
swap_errno = ctypes.get_errno()
unsupported = {errno.ENOTSUP, getattr(errno, "EOPNOTSUPP", errno.ENOTSUP)}
if swap_errno in unsupported:
    print("unsupported")
    raise SystemExit(0)
raise OSError(swap_errno, "renamex_np(RENAME_SWAP) failed")
`;
  const child = spawnSync(
    python,
    ["-c", helper, left, right],
    { encoding: "utf8", env: process.env },
  );
  if (child.error || child.status !== 0) {
    throw new Error("Skillet atomic store exchange failed");
  }
  const outcome = child.stdout.trim();
  if (outcome === "swapped") return "rename-swap";
  if (outcome !== "unsupported") {
    throw new Error("Skillet atomic store exchange returned an invalid result");
  }
  compensatingDirectoryExchange(left, right, {
    beforeCompensatingExchangeStep,
    beforeCompensatingRollbackStep,
  });
  return "compensating-exchange";
}

function activateStagedStore(
  store,
  stagingStore,
  expectedLiveStoreDigest,
  atomicExchangeTestHooks = {},
) {
  if (directoryTreeDigest(store) !== expectedLiveStoreDigest) {
    fs.rmSync(stagingStore, { recursive: true, force: true });
    throw new Error(
      "Skillet store changed during staged refresh; activation was aborted",
    );
  }
  if (!fs.existsSync(store)) {
    fs.renameSync(stagingStore, store);
    return {
      activationMethod: "atomic-rename",
      previousStoreCleanup: "not-needed",
    };
  }
  const activationMethod = atomicallyExchangeDirectories(
    store,
    stagingStore,
    atomicExchangeTestHooks,
  );
  try {
    fs.rmSync(stagingStore, { recursive: true, force: true });
    return {
      activationMethod,
      previousStoreCleanup: "removed",
    };
  } catch {
    return {
      activationMethod,
      previousStoreCleanup: "retained-for-next-locked-reap",
    };
  }
}

function removeStagedStoreMutationLock(stagingStore) {
  const lockPath = storeMutationLockPath(stagingStore);
  if (!fs.existsSync(lockPath)) return "absent";
  const stat = fs.lstatSync(lockPath);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw new Error("Skillet staged store mutation lock is unsafe");
  }
  fs.unlinkSync(lockPath);
  return "removed";
}

function resolveExecutable(value) {
  if (path.isAbsolute(value) || value.includes(path.sep)) {
    try {
      fs.accessSync(value, fs.constants.X_OK);
      return value;
    } catch {
      return null;
    }
  }
  for (const directory of (process.env.PATH ?? "").split(path.delimiter)) {
    if (!directory) continue;
    const candidate = path.join(directory, value);
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return candidate;
    } catch {
      // Keep searching the governed PATH.
    }
  }
  return null;
}

function storeMutationLockPath(store) {
  const normalizedStore = path.resolve(store);
  return path.join(
    path.dirname(normalizedStore),
    `.${path.basename(normalizedStore)}.store-mutation.lock`,
  );
}

function reexecUnderStoreMutationLock(options) {
  if (
    options.dryRun
    || process.env[STORE_LOCK_OWNER_ENV] === String(process.ppid)
  ) {
    return null;
  }
  const python = resolveExecutable(process.env.TATWO_PYTHON3 ?? "python3");
  if (!python) {
    throw new Error(
      "Skillet staged refresh requires python3 for the Swift-compatible store lock",
    );
  }
  const lockPath = storeMutationLockPath(options.store);
  const wrapper = String.raw`
import fcntl
import os
import subprocess
import sys

lock_path, node_path, script_path, *arguments = sys.argv[1:]
os.makedirs(os.path.dirname(lock_path), exist_ok=True)
flags = os.O_RDWR | os.O_CREAT
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
fd = os.open(lock_path, flags, 0o600)
return_code = 70
try:
    fcntl.flock(fd, fcntl.LOCK_EX)
    environment = os.environ.copy()
    environment["${STORE_LOCK_OWNER_ENV}"] = str(os.getpid())
    try:
        completed = subprocess.run(
            [node_path, script_path, *arguments],
            env=environment,
            check=False,
        )
        return_code = completed.returncode
    except OSError:
        print("locked Skillet refresh child could not be launched", file=sys.stderr)
finally:
    fcntl.flock(fd, fcntl.LOCK_UN)
    os.close(fd)
sys.exit(return_code)
`;
  const child = spawnSync(
    python,
    [
      "-c",
      wrapper,
      lockPath,
      process.execPath,
      fileURLToPath(import.meta.url),
      ...process.argv.slice(2),
    ],
    {
      env: process.env,
      stdio: "inherit",
    },
  );
  if (child.error) {
    throw new Error(`Skillet store lock failed: ${child.error.message}`);
  }
  if (!Number.isInteger(child.status)) {
    throw new Error("Skillet store lock process did not return an exit status");
  }
  return child.status;
}

function sanitizeMessage(value, options, sourcePath) {
  let result = String(value ?? "").trim();
  const storeParent =
    typeof options.store === "string" && path.isAbsolute(options.store)
      ? path.dirname(options.store)
      : null;
  const storeBasename =
    typeof options.store === "string" && path.isAbsolute(options.store)
      ? path.basename(options.store)
      : null;
  const filesystemRoot = storeParent ? path.parse(storeParent).root : null;
  if (storeParent && storeBasename) {
    const escapeRegExp = (input) =>
      input.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    for (const [kind, replacement] of [
      ["staging", "$TATWO_SKILLET_STORE_STAGING"],
      ["rollback", "$TATWO_SKILLET_STORE_ROLLBACK"],
    ]) {
      const prefix = path.join(
        storeParent,
        `.${storeBasename}.refresh-${kind}-`,
      );
      result = result.replace(
        new RegExp(`${escapeRegExp(prefix)}[^\\s'"\\]\\[(){};,]+`, "g"),
        replacement,
      );
    }
  }
  const needles = [
    [sourcePath, "$TATWO_SKILLET_SOURCE"],
    [options.sourceRoot, "$TATWO_SKILLET_SOURCE_ROOT"],
    [options.fallbackSourceRoot, "$TATWO_SKILLET_SOURCE_FALLBACK_ROOT"],
    [options.store, "$TATWO_SKILLET_STORE"],
    [options.registry, "$TATWO_SKILLET_SOURCE_REGISTRY"],
    [options.cli, "$TATWO_SKILLET_CLI"],
    [options.receipt, "$TATWO_SKILLET_REFRESH_RECEIPT"],
    [os.homedir(), "$HOME"],
  ];
  if (storeParent && storeParent !== filesystemRoot) {
    needles.push([storeParent, "$TATWO_SKILLET_STORE_PARENT"]);
  }
  for (const [needle, replacement] of needles
    .filter(([needle]) => typeof needle === "string" && needle.length > 0)
    .sort(([left], [right]) => right.length - left.length)) {
    if (needle) result = result.split(needle).join(replacement);
  }
  return result.slice(0, 1200);
}

function refreshAttemptMetadata(options = {}) {
  if (typeof options.attemptID !== "string" || options.attemptID.length === 0) {
    return {};
  }
  return {
    evidenceKind: "local-source-refresh-attempt",
    attemptID: options.attemptID ?? "",
    target: options.target ?? "",
    action: options.action ?? "system-pull",
    requestedAt: options.requestedAt ?? "",
    currentDeviceName: options.currentDeviceName ?? "",
    currentDeviceID: options.currentDeviceID ?? "",
    authorityPrimary: options.authorityPrimary ?? "",
    authorityEpoch: options.authorityEpoch === null
      || options.authorityEpoch === undefined
      || options.authorityEpoch === ""
      ? 0
      : Number(options.authorityEpoch),
    ledgerSequence: options.ledgerSequence === null
      || options.ledgerSequence === undefined
      || options.ledgerSequence === ""
      ? 0
      : Number(options.ledgerSequence),
    catalogRevision: options.catalogRevision ?? "",
    sourceDeviceID: options.sourceDeviceID ?? "",
    targetDeviceID: options.targetDeviceID ?? "",
  };
}

function failureResults(error, message, options) {
  const candidates = Array.isArray(error?.skilletRefreshResults)
    ? error.skilletRefreshResults
    : [{
        sourceName: "canonical-source-discovery",
        repositoryID: "",
        displayName: "Skillet canonical source discovery",
        status: "failed",
        message,
      }];
  return candidates.map((result) => ({
    sourceName:
      typeof result?.sourceName === "string" && result.sourceName.length > 0
        ? result.sourceName
        : "canonical-source-discovery",
    repositoryID:
      typeof result?.repositoryID === "string" ? result.repositoryID : "",
    displayName:
      typeof result?.displayName === "string" && result.displayName.length > 0
        ? result.displayName
        : "Skillet canonical source discovery",
    status: "failed",
    message: sanitizeMessage(
      result?.message ?? message,
      options ?? {},
      null,
    ),
  }));
}

function writeJSONAtomically(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const temporary = `${filePath}.tmp.${process.pid}`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temporary, filePath);
}

function unwrapSnapshotCLIOutput(parsed) {
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("Skillet CLI returned a non-object JSON document");
  }
  if (
    Object.hasOwn(parsed, "ok")
    || Object.hasOwn(parsed, "data")
    || Object.hasOwn(parsed, "error")
  ) {
    if (parsed.ok !== true) {
      throw new Error(
        typeof parsed.error === "string" && parsed.error.length > 0
          ? `Skillet CLI failed: ${parsed.error}`
          : "Skillet CLI returned a failed JSON envelope",
      );
    }
    if (!parsed.data || typeof parsed.data !== "object" || Array.isArray(parsed.data)) {
      throw new Error("Skillet CLI success envelope is missing object data");
    }
    return parsed.data;
  }
  return parsed;
}

function isSafeRelativePath(value) {
  if (
    typeof value !== "string"
    || value.length === 0
    || path.isAbsolute(value)
    || value.includes("\\")
  ) {
    return false;
  }
  const components = value.split("/");
  return components.every((component) =>
    component.length > 0 && component !== "." && component !== ".."
  );
}

function validateSnapshotStoreState(options, source, output) {
  const repositoryRoot = path.join(
    options.store,
    "repositories",
    source.repositoryID,
  );
  const repositoryPath = path.join(repositoryRoot, "repository.json");
  const revisionPath = path.join(
    repositoryRoot,
    "revisions",
    `${output.revisionID}.json`,
  );
  const objectRoot = path.join(options.store, "objects", output.contentDigest);
  const objectManifestPath = path.join(objectRoot, "manifest.json");
  const payloadRoot = path.join(objectRoot, "payload");
  for (const [artifact, artifactPath] of [
    ["repository metadata", repositoryPath],
    ["revision metadata", revisionPath],
    ["object manifest", objectManifestPath],
  ]) {
    let stat;
    try {
      stat = fs.lstatSync(artifactPath);
    } catch {
      throw new Error(`Skillet snapshot is missing ${artifact}: ${source.repositoryID}`);
    }
    if (!stat.isFile() || stat.isSymbolicLink()) {
      throw new Error(`Skillet snapshot has unsafe ${artifact}: ${source.repositoryID}`);
    }
  }
  const repository = readJSON(repositoryPath);
  if (
    repository?.schemaVersion !== 1
    || repository.id !== source.repositoryID
    || repository.canonicalRevision !== output.revisionID
    || !Array.isArray(repository.revisionIDs)
    || !repository.revisionIDs.includes(output.revisionID)
  ) {
    throw new Error(`Skillet repository metadata failed verification: ${source.repositoryID}`);
  }
  const revision = readJSON(revisionPath);
  if (
    revision?.id !== output.revisionID
    || revision.repositoryID !== source.repositoryID
    || revision.contentDigest !== output.contentDigest
    || revision.channel !== options.channel
  ) {
    throw new Error(`Skillet revision metadata failed verification: ${source.repositoryID}`);
  }
  const objectStat = fs.lstatSync(objectRoot);
  const payloadStat = fs.lstatSync(payloadRoot);
  if (
    !objectStat.isDirectory()
    || objectStat.isSymbolicLink()
    || !payloadStat.isDirectory()
    || payloadStat.isSymbolicLink()
  ) {
    throw new Error(`Skillet object layout failed verification: ${source.repositoryID}`);
  }
  const manifest = readJSON(objectManifestPath);
  if (
    manifest?.schemaVersion !== 1
    || manifest.contentDigest !== output.contentDigest
    || !Array.isArray(manifest.files)
    || manifest.files.length === 0
  ) {
    throw new Error(`Skillet object manifest failed verification: ${source.repositoryID}`);
  }
  const manifestPaths = manifest.files.map((entry) => entry?.relativePath);
  if (
    !manifestPaths.includes("SKILL.md")
    || manifestPaths.some((value) =>
      typeof value !== "string" || canonicalPortablePath(value) !== value
    )
    || new Set(manifestPaths).size !== manifestPaths.length
    || [...manifestPaths].sort(comparePortablePaths)
      .some((value, index) => value !== manifestPaths[index])
  ) {
    throw new Error(`Skillet object manifest paths failed verification: ${source.repositoryID}`);
  }
  const files = manifest.files.map((entry) => {
    if (
      !isSafeRelativePath(entry?.relativePath)
      || typeof entry?.contentDigest !== "string"
      || !/^[0-9a-f]{64}$/.test(entry.contentDigest)
      || !Number.isSafeInteger(entry?.byteCount)
      || entry.byteCount < 0
    ) {
      throw new Error(`Skillet object file entry failed verification: ${source.repositoryID}`);
    }
    const filePath = path.join(payloadRoot, entry.relativePath);
    const stat = fs.lstatSync(filePath);
    if (!stat.isFile() || stat.isSymbolicLink()) {
      throw new Error(`Skillet object payload entry is unsafe: ${source.repositoryID}`);
    }
    const data = fs.readFileSync(filePath);
    if (
      data.length !== entry.byteCount
      || crypto.createHash("sha256").update(data).digest("hex") !== entry.contentDigest
    ) {
      throw new Error(`Skillet object payload digest failed verification: ${source.repositoryID}`);
    }
    return { relativePath: entry.relativePath, data };
  });
  const actualPaths = [];
  const actualPathSet = new Set();
  const visitPayload = (directory, prefix) => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const canonicalName = canonicalPortablePath(entry.name);
      const relativePath = prefix ? `${prefix}/${canonicalName}` : canonicalName;
      const absolutePath = path.join(directory, entry.name);
      const stat = fs.lstatSync(absolutePath);
      if (stat.isSymbolicLink()) {
        throw new Error(`Skillet object payload contains a symlink: ${source.repositoryID}`);
      }
      if (stat.isDirectory()) {
        visitPayload(absolutePath, relativePath);
      } else if (stat.isFile()) {
        if (actualPathSet.has(relativePath)) {
          throw new Error(
            `Skillet object payload contains duplicate canonical path: ${source.repositoryID}`,
          );
        }
        actualPathSet.add(relativePath);
        actualPaths.push(relativePath);
      } else {
        throw new Error(`Skillet object payload contains an unsupported entry: ${source.repositoryID}`);
      }
    }
  };
  visitPayload(payloadRoot, "");
  actualPaths.sort(comparePortablePaths);
  if (
    actualPaths.length !== manifestPaths.length
    || actualPaths.some((value, index) => value !== manifestPaths[index])
    || snapshotDigest(files) !== output.contentDigest
    || output.revisionID !== `rev-${output.contentDigest}`
  ) {
    throw new Error(`Skillet immutable object failed verification: ${source.repositoryID}`);
  }
}

// Production mutation must enter through main(), which re-executes under the
// Swift-compatible cross-process store lock. This exported function remains
// intentionally lock-free for deterministic unit tests and in-process callers
// that already own that exact lock.
function refresh(options) {
  const startedAt = new Date().toISOString();
  if (
    !options.dryRun
    && options.assumeStoreLockHeld !== true
    && process.env[STORE_LOCK_OWNER_ENV] !== String(process.ppid)
  ) {
    throw new Error(
      "Mutating Skillet refresh requires the shared store-mutation lock",
    );
  }
  if (
    options.fallbackSourceRoot !== null
    && options.fallbackSourceRoot !== undefined
    && (
      typeof options.fallbackSourceRoot !== "string"
      || !path.isAbsolute(options.fallbackSourceRoot)
    )
  ) {
    throw new Error("Skillet fallback source root must be an absolute path");
  }
  if (typeof options.store !== "string" || !path.isAbsolute(options.store)) {
    throw new Error("Skillet store must be an absolute path");
  }
  assertSeparatedRoots(options);
  const aliases = validateRegistry(readJSON(options.registry));
  let sources;
  let sourceMode = "canonical";
  let fallbackAuthorization = {
    fallbackAuthorizationID: "",
    fallbackAuthorizationPath: "",
    fallbackAuthorizationDigest: "",
  };
  try {
    sources = discoverSources(options.sourceRoot, aliases);
  } catch (error) {
    const fallbackAllowed =
      ["SKILLET_SOURCE_ROOT_UNAVAILABLE", "SKILLET_SOURCE_ROOT_EMPTY"]
        .includes(error?.code)
      && typeof options.fallbackSourceRoot === "string"
      && options.fallbackSourceRoot !== options.sourceRoot;
    if (!fallbackAllowed) throw error;
    try {
      fallbackAuthorization = validateFallbackAuthorization(options);
    } catch (authorizationError) {
      authorizationError.skilletRefreshResults = [
        ...(Array.isArray(error?.skilletRefreshResults)
          ? error.skilletRefreshResults
          : []),
        {
          sourceName: "runtime-fallback-authorization",
          repositoryID: "",
          displayName: "Runtime fallback authorization",
          status: "failed",
          message: authorizationError?.message
            ?? "Runtime fallback authorization failed",
        },
      ];
      throw authorizationError;
    }
    sources = discoverSources(options.fallbackSourceRoot, aliases);
    sourceMode = "runtime-fallback";
  }
  const expectedRepositoryIDs = sources.map((source) => source.repositoryID);
  for (const repositoryID of expectedRepositoryIDs) {
    if (aliases.retiredRepositoryIDs.has(repositoryID)) {
      throw new Error(
        `Discovered Skillet repository is also retired: ${repositoryID}`,
      );
    }
  }
  const results = [];
  let retirements = [];
  let stagingStore = null;
  let liveStoreDigest = null;
  let recoveredInterruptedExchange = false;
  let reapedInterruptedExchangeCount = 0;
  let reapedStagingStoreCount = 0;
  let reapedStagingStoreLockCount = 0;
  let previousStoreCleanup = "not-requested";
  let activationMethod = options.dryRun ? "not-requested" : "staged-not-activated";
  let storeMutation = options.dryRun ? "not-requested" : "staged-not-activated";

  if (!options.dryRun) {
    const cliPath = resolveExecutable(options.cli);
    if (!cliPath) {
      throw new Error("Skillet CLI is unavailable");
    }
    ({
      stagingStore,
      liveStoreDigest,
      recoveredInterruptedExchange,
      reapedInterruptedExchangeCount,
      reapedStagingStoreCount,
      reapedStagingStoreLockCount,
    } = prepareStagedStore(options.store));
    const stagedOptions = { ...options, store: stagingStore };
    try {
      for (const source of sources) {
        let sourceSnapshotBefore;
        try {
          sourceSnapshotBefore = inspectSourceTree(
            source.sourcePath,
            source.sourceEntryName,
          );
        } catch (error) {
          results.push({
            sourceName: source.sourceName,
            repositoryID: source.repositoryID,
            displayName: source.displayName,
            status: "failed",
            message: sanitizeMessage(
              error?.message ?? "Skillet source readback failed",
              stagedOptions,
              source.sourcePath,
            ),
          });
          continue;
        }
        const child = spawnSync(
          cliPath,
          [
            "skillet",
            "snapshot",
            "--store",
            stagingStore,
            "--repository",
            source.repositoryID,
            "--display-name",
            source.displayName,
            "--summary",
            `Canonical TATWO skill: ${source.displayName}`,
            "--source",
            source.sourcePath,
            "--channel",
            options.channel,
            "--json",
          ],
          {
            encoding: "utf8",
            env: process.env,
            maxBuffer: 4 * 1024 * 1024,
          },
        );
        if (child.status !== 0) {
          results.push({
            sourceName: source.sourceName,
            repositoryID: source.repositoryID,
            displayName: source.displayName,
            status: "failed",
            message: sanitizeMessage(
              child.stderr || child.stdout || `Skillet CLI exited ${child.status}`,
              stagedOptions,
              source.sourcePath,
            ),
          });
          continue;
        }
        let output;
        try {
          output = unwrapSnapshotCLIOutput(JSON.parse(child.stdout));
        } catch (error) {
          results.push({
            sourceName: source.sourceName,
            repositoryID: source.repositoryID,
            displayName: source.displayName,
            status: "failed",
            message: sanitizeMessage(
              error?.message ?? "Skillet CLI did not return valid JSON",
              stagedOptions,
              source.sourcePath,
            ),
          });
          continue;
        }
        if (
          output.schema !== "TatwoSkilletSnapshotCLIOutputV1"
          || output.repositoryID !== source.repositoryID
          || typeof output.revisionID !== "string"
          || !output.revisionID.startsWith("rev-")
          || typeof output.contentDigest !== "string"
          || !/^[0-9a-f]{64}$/.test(output.contentDigest)
        ) {
          results.push({
            sourceName: source.sourceName,
            repositoryID: source.repositoryID,
            displayName: source.displayName,
            status: "failed",
            message: "Skillet CLI returned an invalid or mismatched snapshot receipt",
          });
          continue;
        }
        try {
          const sourceSnapshotAfter = inspectSourceTree(
            source.sourcePath,
            source.sourceEntryName,
          );
          if (sourceSnapshotBefore.digest !== sourceSnapshotAfter.digest) {
            throw new Error(
              `Skillet source changed during snapshot: ${source.repositoryID}`,
            );
          }
          if (output.contentDigest !== sourceSnapshotAfter.digest) {
            throw new Error(
              `Skillet snapshot does not match canonical source: ${source.repositoryID}`,
            );
          }
          validateSnapshotStoreState(stagedOptions, source, output);
        } catch (error) {
          results.push({
            sourceName: source.sourceName,
            repositoryID: source.repositoryID,
            displayName: source.displayName,
            status: "failed",
            message: sanitizeMessage(
              error?.message ?? "Skillet snapshot store verification failed",
              stagedOptions,
              source.sourcePath,
            ),
          });
          continue;
        }
        results.push({
          sourceName: source.sourceName,
          sourceLayout: source.sourceLayout,
          repositoryID: source.repositoryID,
          displayName: source.displayName,
          status: "refreshed",
          revisionID: output.revisionID,
          contentDigest: output.contentDigest,
        });
      }
    } catch (error) {
      try {
        removeStagedStoreMutationLock(stagingStore);
      } finally {
        fs.rmSync(stagingStore, { recursive: true, force: true });
      }
      stagingStore = null;
      throw error;
    }
    try {
      removeStagedStoreMutationLock(stagingStore);
    } catch (error) {
      fs.rmSync(stagingStore, { recursive: true, force: true });
      stagingStore = null;
      throw error;
    }
  } else {
    for (const source of sources) {
      results.push({
        sourceName: source.sourceName,
        sourceLayout: source.sourceLayout,
        repositoryID: source.repositoryID,
        displayName: source.displayName,
        status: "validated",
      });
    }
  }

  let actualRepositoryIDs;
  try {
    actualRepositoryIDs = options.dryRun
      ? expectedRepositoryIDs
      : (() => {
        retirements = retireStagedRepositories(
          stagingStore,
          aliases.retiredRepositoryIDs,
        );
        return listStoreRepositories(stagingStore);
      })();
  } catch (error) {
    if (stagingStore && fs.existsSync(stagingStore)) {
      fs.rmSync(stagingStore, { recursive: true, force: true });
      stagingStore = null;
    }
    throw error;
  }
  const expected = new Set(expectedRepositoryIDs);
  const actual = new Set(actualRepositoryIDs);
  const missingRepositoryIDs = expectedRepositoryIDs.filter((id) => !actual.has(id));
  const staleRepositoryIDs = actualRepositoryIDs.filter((id) => !expected.has(id));
  const failedCount = results.filter((result) => result.status === "failed").length;
  const outcome =
    failedCount === 0
      && missingRepositoryIDs.length === 0
      && staleRepositoryIDs.length === 0
      ? "converged"
      : "partial";
  if (!options.dryRun && outcome === "converged") {
    const activation = activateStagedStore(
      options.store,
      stagingStore,
      liveStoreDigest,
      options.atomicExchangeTestHooks,
    );
    previousStoreCleanup = activation.previousStoreCleanup;
    activationMethod = activation.activationMethod;
    stagingStore = null;
    storeMutation = activationMethod === "compensating-exchange"
      ? "activated-with-compensating-exchange"
      : "activated-atomically";
  } else if (!options.dryRun && stagingStore) {
    fs.rmSync(stagingStore, { recursive: true, force: true });
    stagingStore = null;
  }
  const receipt = {
    schema: "TatwoSkilletCanonicalRefreshReceiptV1",
    ...refreshAttemptMetadata(options),
    outcome,
    dryRun: options.dryRun,
    channel: options.channel,
    sourceMode,
    storeMutation,
    activationMethod,
    previousStoreCleanup,
    recoveredInterruptedExchange,
    reapedInterruptedExchangeCount,
    reapedStagingStoreCount,
    reapedStagingStoreLockCount,
    inventoryDigest: inventoryDigest(sources, aliases.retiredRepositoryIDs),
    ...fallbackAuthorization,
    discoveredSourceCount: sources.length,
    refreshedCount: results.filter((result) =>
      result.status === "refreshed" || result.status === "validated"
    ).length,
    failedCount,
    expectedRepositoryIDs,
    actualRepositoryIDs,
    missingRepositoryIDs,
    staleRepositoryIDs,
    retiredRepositoryIDs: [...aliases.retiredRepositoryIDs].sort(),
    retirements,
    results,
    startedAt,
    completedAt: new Date().toISOString(),
  };
  if (options.receipt) writeJSONAtomically(options.receipt, receipt);
  return receipt;
}

function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
    const lockedExitStatus = reexecUnderStoreMutationLock(options);
    if (lockedExitStatus !== null) {
      process.exitCode = lockedExitStatus;
      return;
    }
    const receipt = refresh(options);
    if (options.json) process.stdout.write(`${JSON.stringify(receipt)}\n`);
    else process.stdout.write(
      `skillet_refresh=${receipt.outcome} `
        + `refreshed=${receipt.refreshedCount}/${receipt.discoveredSourceCount}\n`,
    );
    if (receipt.outcome !== "converged") process.exitCode = 1;
  } catch (error) {
    const message = sanitizeMessage(error?.message ?? error, options ?? {}, null);
    if (options?.receipt) {
      const results = failureResults(error, message, options);
      writeJSONAtomically(options.receipt, {
        schema: "TatwoSkilletCanonicalRefreshReceiptV1",
        ...refreshAttemptMetadata(options),
        outcome: "failed",
        dryRun: options.dryRun,
        channel: options.channel ?? "staging",
        sourceMode: "unresolved",
        storeMutation: "not-started",
        activationMethod: "not-requested",
        previousStoreCleanup: "not-requested",
        recoveredInterruptedExchange: false,
        reapedInterruptedExchangeCount: 0,
        reapedStagingStoreCount: 0,
        reapedStagingStoreLockCount: 0,
        inventoryDigest: "",
        fallbackAuthorizationID: "",
        fallbackAuthorizationPath: "",
        fallbackAuthorizationDigest: "",
        discoveredSourceCount: 0,
        refreshedCount: 0,
        failedCount: results.length,
        expectedRepositoryIDs: [],
        actualRepositoryIDs: [],
        missingRepositoryIDs: [],
        staleRepositoryIDs: [],
        retiredRepositoryIDs: [],
        retirements: [],
        results,
        message,
        startedAt: options.requestedAt ?? new Date().toISOString(),
        completedAt: new Date().toISOString(),
      });
    }
    if (options?.json) {
      process.stdout.write(`${JSON.stringify({ outcome: "failed", message })}\n`);
    } else {
      process.stderr.write(`ERROR: ${message}\n`);
    }
    process.exitCode = 1;
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main();
}

export {
  atomicallyExchangeDirectories,
  defaultSkilletSourceRoot,
  discoverSources,
  inventoryDigest,
  listStoreRepositories,
  pathsOverlap,
  refresh,
  resolveExecutable,
  sanitizeMessage,
  snapshotDigest,
  storeMutationLockPath,
  unwrapSnapshotCLIOutput,
  validateSnapshotStoreState,
  validateRegistry,
};
