#!/usr/bin/env node
/**
 * Deterministic READ-ONLY Skillet live audit.
 *
 * Separates evidence layers and fails closed when live proof is missing.
 * Never claims live cross-machine skill borrowing from storage/sync receipts alone.
 * Never mutates host state and never emits secret/auth/session/token contents.
 */

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_REPO_ROOT = path.resolve(HERE, "..");
const SCHEMA = "TatwoSkilletLiveAuditReceiptV1";
const SCHEMA_VERSION = 1;
const SAFE_ID = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const READINESS_SAFE_ID = /^[A-Za-z0-9][A-Za-z0-9._/@:+-]*$/;
const SHA256_HEX = /^[0-9a-f]{64}$/;
const REV_ID = /^rev-[0-9a-f]{64}$/;
const DEFAULT_CONSUMER_READBACK_MAX_AGE_SECONDS = 15 * 60;
const MAX_CONSUMER_READBACK_MAX_AGE_SECONDS = 24 * 60 * 60;
const CONSUMER_READBACK_FUTURE_SKEW_SECONDS = 5 * 60;

const REQUIRED_SOURCE_EVIDENCE = [
  {
    id: "store",
    relativePath:
      "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoSkilletRepositoryStore.swift",
  },
  {
    id: "merge",
    relativePath:
      "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoSkilletMergeEngine.swift",
  },
  {
    id: "bundle",
    relativePath:
      "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoSkilletBundleTransport.swift",
  },
  {
    id: "cli",
    relativePath:
      "Tools/TatwoUltraworkCLI/Sources/TatwoUltraworkCLI/SkilletCLI.swift",
  },
  {
    id: "consumer-readback",
    relativePath:
      "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoTargetConsumerReadback.swift",
  },
  {
    id: "remote-readiness",
    relativePath:
      "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/RemoteDispatchReadiness.swift",
  },
  {
    id: "refresh-script",
    relativePath: "scripts/tatwo-skillet-refresh.mjs",
  },
  {
    id: "projection-script",
    relativePath: "scripts/tatwo-skills-consumer-projection.py",
  },
  {
    id: "refresh-test",
    relativePath: "tests/tatwo-skillet-refresh.test.mjs",
  },
  {
    id: "store-test",
    relativePath:
      "Packages/TatwoUltraworkCore/Tests/TatwoUltraworkCoreTests/TatwoSkilletRepositoryStoreTests.swift",
  },
  {
    id: "registry",
    relativePath: "config/tatwo-skillet-source-registry-v1.json",
  },
];

const SKILLET_CONSUMER_IDS = [
  "skillet.runtime-loader",
  "codex.native-skills",
  "claude.native-skills",
];

const SECRET_KEY_PATTERN =
  /^(.*(_)?(token|secret|password|passwd|authorization|cookie|session|api[_-]?key|private[_-]?key|access[_-]?key|refresh[_-]?token|bearer|credential|keychain)(_.*)?)$/i;

const SECRET_VALUE_PATTERNS = [
  /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/i,
  /\bsk-proj-[A-Za-z0-9_-]{20,}\b/,
  /\bsk-ant-[A-Za-z0-9_-]{20,}\b/,
  /\bsk-[A-Za-z0-9]{32,}\b/,
  /\bghp_[A-Za-z0-9]{20,}\b/,
  /\bgithub_pat_[A-Za-z0-9_]{20,}\b/,
  /\bxox[baprs]-[A-Za-z0-9-]{20,}\b/,
  /\bAIza[0-9A-Za-z_-]{30,}\b/,
  /\bAKIA[0-9A-Z]{16}\b/,
  /\bBearer\s+[A-Za-z0-9._~+/=-]{20,}\b/i,
];

function parseArgs(argv) {
  const options = {
    repoRoot: process.env.TATWO_SKILLET_LIVE_AUDIT_REPO_ROOT ?? DEFAULT_REPO_ROOT,
    fixtureRoot: process.env.TATWO_SKILLET_LIVE_AUDIT_FIXTURE_ROOT ?? null,
    store: process.env.TATWO_SKILLET_STORE ?? null,
    runtimeRoot: process.env.TATWO_SKILLET_RUNTIME_ROOT ?? null,
    appBundle: process.env.TATWO_ULTRAWORK_APP_BUNDLE ?? null,
    appSupport: process.env.TATWO_ULTRAWORK_APP_SUPPORT ?? null,
    consumerReadback: process.env.TATWO_SKILLET_CONSUMER_READBACK ?? null,
    consumerReadbacksDir: process.env.TATWO_SKILLET_CONSUMER_READBACKS_DIR ?? null,
    remoteJob: process.env.TATWO_SKILLET_REMOTE_JOB ?? null,
    deviceID: process.env.TATWO_SKILLET_DEVICE_ID ?? null,
    target: process.env.TATWO_SKILLET_TARGET ?? null,
    expectedRevision: process.env.TATWO_SKILLET_EXPECTED_REVISION ?? null,
    expectedDigest: process.env.TATWO_SKILLET_EXPECTED_DIGEST ?? null,
    repositoryID: process.env.TATWO_SKILLET_REPOSITORY_ID ?? null,
    consumerReadbackMaxAgeSeconds:
      process.env.TATWO_SKILLET_CONSUMER_READBACK_MAX_AGE_SECONDS
      ?? DEFAULT_CONSUMER_READBACK_MAX_AGE_SECONDS,
    receipt: process.env.TATWO_SKILLET_LIVE_AUDIT_RECEIPT ?? null,
    json: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--json") {
      options.json = true;
      continue;
    }
    if (argument === "--help" || argument === "-h") {
      options.help = true;
      continue;
    }
    const key = {
      "--repo-root": "repoRoot",
      "--fixture-root": "fixtureRoot",
      "--store": "store",
      "--runtime-root": "runtimeRoot",
      "--app-bundle": "appBundle",
      "--app-support": "appSupport",
      "--consumer-readback": "consumerReadback",
      "--consumer-readbacks-dir": "consumerReadbacksDir",
      "--remote-job": "remoteJob",
      "--device-id": "deviceID",
      "--target": "target",
      "--expected-revision": "expectedRevision",
      "--expected-digest": "expectedDigest",
      "--repository": "repositoryID",
      "--consumer-readback-max-age-seconds": "consumerReadbackMaxAgeSeconds",
      "--receipt": "receipt",
    }[argument];
    if (!key || index + 1 >= argv.length) {
      throw new Error(usageText());
    }
    options[key] = argv[index + 1];
    index += 1;
  }
  return options;
}

function usageText() {
  return (
    "Usage: tatwo-skillet-live-audit.mjs "
    + "[--repo-root PATH] [--fixture-root PATH] [--store PATH] "
    + "[--runtime-root PATH] [--app-bundle PATH] [--app-support PATH] "
    + "[--consumer-readback PATH] [--consumer-readbacks-dir PATH] "
    + "[--remote-job PATH] [--device-id ID] [--target NAME] "
    + "[--repository ID] [--expected-revision rev-...] [--expected-digest SHA256] "
    + "[--consumer-readback-max-age-seconds SECONDS] "
    + "[--receipt PATH] [--json]"
  );
}

function isAbsolutePath(value) {
  return typeof value === "string" && path.isAbsolute(value) && !value.includes("\0");
}

function resolveOptionalPath(value) {
  if (value == null || value === "") return null;
  if (!isAbsolutePath(value)) {
    throw new Error(`path must be absolute: ${value}`);
  }
  return path.normalize(value);
}

function defaultPaths(options) {
  const home = options.fixtureRoot
    ? path.join(options.fixtureRoot, "home")
    : os.homedir();
  const appSupport = options.appSupport
    ?? path.join(home, "Library", "Application Support", "Tatwo Ultrawork");
  const store = options.store ?? path.join(appSupport, "skillet");
  const runtimeRoot = options.runtimeRoot ?? path.join(appSupport, "skills-runtime");
  const appBundle = options.appBundle
    ?? (
      options.fixtureRoot
        ? path.join(options.fixtureRoot, "Applications", "Tatwo Ultrawork.app")
        : path.join("/Applications", "Tatwo Ultrawork.app")
    );
  const consumerReadbacksDir = options.consumerReadbacksDir
    ?? (
      options.fixtureRoot
        ? path.join(options.fixtureRoot, "consumer-readbacks")
        : path.join(appSupport, "device-sync-state", "consumer-readbacks")
    );
  return {
    home,
    appSupport: path.normalize(appSupport),
    store: path.normalize(store),
    runtimeRoot: path.normalize(runtimeRoot),
    appBundle: path.normalize(appBundle),
    consumerReadbacksDir: path.normalize(consumerReadbacksDir),
  };
}

function sha256Buffer(buffer) {
  return crypto.createHash("sha256").update(buffer).digest("hex");
}

function sha256File(filePath) {
  return sha256Buffer(fs.readFileSync(filePath));
}

function safeReadJSON(filePath) {
  try {
    const text = fs.readFileSync(filePath, "utf8");
    return { ok: true, value: JSON.parse(text), bytes: Buffer.byteLength(text, "utf8") };
  } catch (error) {
    return {
      ok: false,
      error: error?.code === "ENOENT" ? "missing" : "unreadable",
      message: String(error?.message ?? error),
    };
  }
}

function parsePositiveInteger(value, label, maximum) {
  const text = String(value);
  if (!/^[1-9][0-9]*$/.test(text)) {
    throw new Error(`${label} must be a positive integer`);
  }
  const parsed = Number(text);
  if (!Number.isSafeInteger(parsed) || parsed > maximum) {
    throw new Error(`${label} must be <= ${maximum}`);
  }
  return parsed;
}

function readLocalDeviceIdentity(paths) {
  const identityPath = path.join(paths.appSupport, "device-identity.json");
  if (!isRegularFile(identityPath)) {
    return {
      ok: false,
      path: identityPath,
      error: lexists(identityPath) ? "unsafe_or_nonregular" : "missing",
    };
  }
  const parsed = safeReadJSON(identityPath);
  if (!parsed.ok) {
    return { ok: false, path: identityPath, error: parsed.error };
  }
  const deviceID = parsed.value?.deviceId;
  if (typeof deviceID !== "string" || !SAFE_ID.test(deviceID)) {
    return { ok: false, path: identityPath, error: "invalid_device_id" };
  }
  return { ok: true, path: identityPath, deviceID };
}

function resolveDeviceScope(paths, options) {
  if (options.deviceID) {
    return {
      ...options,
      deviceIdentity: {
        status: "explicit",
        deviceID: options.deviceID,
        path: null,
        error: null,
      },
    };
  }
  const localIdentity = readLocalDeviceIdentity(paths);
  if (!localIdentity.ok) {
    return {
      ...options,
      deviceIdentity: {
        status: "unavailable",
        deviceID: null,
        path: localIdentity.path,
        error: localIdentity.error,
      },
    };
  }
  return {
    ...options,
    deviceID: localIdentity.deviceID,
    target: options.target ?? localIdentity.deviceID,
    deviceIdentity: {
      status: "derived_local",
      deviceID: localIdentity.deviceID,
      path: localIdentity.path,
      error: null,
    },
  };
}

function lexists(filePath) {
  try {
    fs.lstatSync(filePath);
    return true;
  } catch {
    return false;
  }
}

function isRegularFile(filePath) {
  try {
    const stat = fs.lstatSync(filePath);
    return stat.isFile() && !stat.isSymbolicLink();
  } catch {
    return false;
  }
}

function isDirectory(filePath) {
  try {
    const stat = fs.lstatSync(filePath);
    return stat.isDirectory() && !stat.isSymbolicLink();
  } catch {
    return false;
  }
}

function boundedRelative(root, absolutePath) {
  const relative = path.relative(root, absolutePath);
  if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) {
    return path.basename(absolutePath);
  }
  return relative.split(path.sep).join("/");
}

function evidencePath(kind, absolutePath, rootForRelative = null) {
  if (!absolutePath) {
    return { kind, present: false, path: null };
  }
  const present = lexists(absolutePath);
  const entry = {
    kind,
    present,
    path: rootForRelative
      ? boundedRelative(rootForRelative, absolutePath)
      : path.basename(absolutePath),
  };
  if (present && isRegularFile(absolutePath)) {
    try {
      entry.sha256 = sha256File(absolutePath);
      entry.byteCount = fs.lstatSync(absolutePath).size;
    } catch {
      entry.unreadable = true;
    }
  }
  return entry;
}

function redactString(value) {
  let text = String(value ?? "");
  for (const pattern of SECRET_VALUE_PATTERNS) {
    text = text.replace(pattern, "[REDACTED_SECRET]");
  }
  // Collapse accidental home expansions that could include sensitive suffixes.
  text = text.split(os.homedir()).join("$HOME");
  return text.slice(0, 800);
}

function redactValue(value, keyHint = "") {
  if (value == null) return value;
  if (typeof value === "string") {
    if (SECRET_KEY_PATTERN.test(keyHint)) return "[REDACTED_SECRET_FIELD]";
    return redactString(value);
  }
  if (typeof value === "number" || typeof value === "boolean") return value;
  if (Array.isArray(value)) {
    return value.map((entry, index) => redactValue(entry, `${keyHint}[${index}]`));
  }
  if (typeof value === "object") {
    const out = {};
    for (const [key, nested] of Object.entries(value)) {
      if (SECRET_KEY_PATTERN.test(key)) {
        out[key] = "[REDACTED_SECRET_FIELD]";
        continue;
      }
      out[key] = redactValue(nested, key);
    }
    return out;
  }
  return redactString(value);
}

function layerResult({
  id,
  status,
  summary,
  evidence = [],
  missing = [],
  reasons = [],
  details = null,
}) {
  return {
    id,
    status,
    summary,
    evidence: evidence.map((item) => redactValue(item)),
    missing: missing.map((item) => redactString(item)),
    reasons: reasons.map((item) => redactString(item)),
    details: details == null ? null : redactValue(details),
  };
}

function worstStatus(statuses) {
  const rank = {
    failed: 5,
    mismatch: 5,
    stale_or_mismatched: 5,
    missing_evidence: 4,
    unreadable: 4,
    partial: 3,
    present: 1,
    bound: 1,
    matched: 1,
    passed: 1,
    not_asserted: 2,
  };
  let best = "passed";
  let bestRank = 0;
  for (const status of statuses) {
    const value = rank[status] ?? 3;
    if (value > bestRank) {
      best = status;
      bestRank = value;
    }
  }
  return best;
}

function overallFromLayers(layers) {
  const statuses = layers.map((layer) => layer.status);
  if (statuses.some((status) =>
    ["failed", "mismatch", "stale_or_mismatched"].includes(status)
  )) {
    return "failed";
  }
  if (statuses.some((status) =>
    ["missing_evidence", "unreadable", "partial"].includes(status)
  )) {
    return "incomplete";
  }
  if (statuses.every((status) =>
    ["passed", "present", "bound", "matched"].includes(status)
  )) {
    return "passed";
  }
  return "incomplete";
}

function auditSourceImplementation(repoRoot) {
  const evidence = [];
  const missing = [];
  const reasons = [];

  if (!isDirectory(repoRoot)) {
    return layerResult({
      id: "source_implementation",
      status: "missing_evidence",
      summary: "Repository root is missing or unreadable",
      missing: ["repo-root"],
      reasons: ["repo_root_unavailable"],
    });
  }

  for (const entry of REQUIRED_SOURCE_EVIDENCE) {
    const absolute = path.join(repoRoot, entry.relativePath);
    const item = evidencePath(entry.id, absolute, repoRoot);
    item.relativePath = entry.relativePath;
    evidence.push(item);
    if (!item.present || item.unreadable) {
      missing.push(entry.relativePath);
      reasons.push(`missing_source:${entry.id}`);
    }
  }

  // Optional but useful implementation companions; absence is noted, not fatal alone.
  const optional = [
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoCapabilityForge.swift",
    "tests/tatwo-skillet-cli-merge.test.sh",
    "archive/governance-legacy-20260917/docs/tatwo/SKILLET_AND_HOT_SYNC.md",
  ];
  for (const relativePath of optional) {
    const absolute = path.join(repoRoot, relativePath);
    if (isRegularFile(absolute)) {
      evidence.push({
        ...evidencePath("optional", absolute, repoRoot),
        relativePath,
      });
    }
  }

  const status = missing.length === 0 ? "present" : "missing_evidence";
  return layerResult({
    id: "source_implementation",
    status,
    summary: missing.length === 0
      ? "TatwoSkillet source/script/test implementation evidence is present"
      : "One or more required Skillet implementation evidence paths are missing",
    evidence,
    missing,
    reasons,
    details: {
      requiredCount: REQUIRED_SOURCE_EVIDENCE.length,
      presentCount: REQUIRED_SOURCE_EVIDENCE.length - missing.length,
    },
  });
}

function readPlistBundleIdentity(infoPlistPath) {
  if (!isRegularFile(infoPlistPath)) {
    return { ok: false, error: "missing" };
  }
  try {
    const text = fs.readFileSync(infoPlistPath, "utf8");
    const pick = (key) => {
      const xml = text.match(
        new RegExp(`<key>${key}</key>\\s*<string>([^<]*)</string>`),
      );
      if (xml) return xml[1];
      const jsonish = text.match(new RegExp(`"${key}"\\s*=\\s*"([^"]+)"`));
      return jsonish ? jsonish[1] : null;
    };
    return {
      ok: true,
      bundleID: pick("CFBundleIdentifier"),
      bundleName: pick("CFBundleName"),
      shortVersion: pick("CFBundleShortVersionString"),
      buildVersion: pick("CFBundleVersion"),
      executable: pick("CFBundleExecutable"),
      sourceCommit: pick("TatwoSourceCommit"),
      sourceTree: pick("TatwoSourceTree"),
    };
  } catch (error) {
    return { ok: false, error: "unreadable", message: String(error?.message ?? error) };
  }
}

function auditLocalStoreBinding(paths, options) {
  const evidence = [];
  const missing = [];
  const reasons = [];
  const details = {
    appBundlePresent: false,
    storePresent: false,
    storeRepositoriesPresent: false,
    sourceRevisionPresent: false,
    boundToExpectedAppID: false,
    note:
      "Local App/store binding is machine-local inventory only; it is not cross-machine skill borrowing proof.",
  };

  const appInfo = path.join(paths.appBundle, "Contents", "Info.plist");
  evidence.push(evidencePath("app-bundle", paths.appBundle, options.fixtureRoot ?? paths.home));
  evidence.push(evidencePath("app-info-plist", appInfo, options.fixtureRoot ?? paths.home));
  const identity = readPlistBundleIdentity(appInfo);
  if (!identity.ok) {
    missing.push("app-bundle-info");
    reasons.push(`app_bundle_${identity.error}`);
  } else {
    details.appBundlePresent = true;
    details.appIdentity = {
      bundleID: identity.bundleID ?? null,
      bundleName: identity.bundleName ?? null,
      shortVersion: identity.shortVersion ?? null,
      buildVersion: identity.buildVersion ?? null,
      sourceCommitPrefix:
        /^[0-9a-f]{40}$/i.test(identity.sourceCommit ?? "")
          ? identity.sourceCommit.slice(0, 12)
          : null,
      sourceTreePrefix:
        /^[0-9a-f]{40}$/i.test(identity.sourceTree ?? "")
          ? identity.sourceTree.slice(0, 12)
          : null,
    };
    if (identity.bundleID === "com.tatwo.ultrawork") {
      details.boundToExpectedAppID = true;
    } else {
      reasons.push("app_bundle_id_mismatch_or_missing");
      missing.push("expected-app-bundle-id");
    }
  }

  const embeddedSourceCommit = identity.ok && /^[0-9a-f]{40}$/i.test(
    identity.sourceCommit ?? "",
  )
    ? identity.sourceCommit
    : null;
  const lastInstalled = path.join(paths.appSupport, "last-installed-commit");
  evidence.push(evidencePath(
    "last-installed-commit-fallback",
    lastInstalled,
    options.fixtureRoot ?? paths.home,
  ));
  if (embeddedSourceCommit) {
    details.sourceRevisionPresent = true;
    details.sourceRevisionSource = "app-info-plist";
  } else if (isRegularFile(lastInstalled)) {
    try {
      const commit = fs.readFileSync(lastInstalled, "utf8").trim();
      if (/^[0-9a-f]{7,64}$/i.test(commit)) {
        details.sourceRevisionPresent = true;
        details.sourceRevisionSource = "last-installed-commit-fallback";
        details.sourceCommitPrefix = commit.slice(0, 12);
      } else {
        missing.push("installed-source-revision");
        reasons.push("installed_source_revision_invalid");
      }
    } catch {
      missing.push("installed-source-revision");
      reasons.push("installed_source_revision_unreadable");
    }
  } else {
    missing.push("installed-source-revision");
    reasons.push("installed_source_revision_missing");
  }

  evidence.push(evidencePath("skillet-store", paths.store, options.fixtureRoot ?? paths.home));
  const repositoriesRoot = path.join(paths.store, "repositories");
  evidence.push(
    evidencePath("skillet-repositories", repositoriesRoot, options.fixtureRoot ?? paths.home),
  );
  if (isDirectory(paths.store)) {
    details.storePresent = true;
  } else {
    missing.push("skillet-store");
    reasons.push("skillet_store_missing");
  }
  if (isDirectory(repositoriesRoot)) {
    details.storeRepositoriesPresent = true;
    try {
      details.repositoryIDs = fs
        .readdirSync(repositoriesRoot, { withFileTypes: true })
        .filter((entry) => entry.isDirectory() && !entry.name.startsWith("."))
        .map((entry) => entry.name)
        .filter((name) => SAFE_ID.test(name))
        .sort();
    } catch {
      reasons.push("skillet_repositories_unreadable");
      missing.push("skillet-repositories-listing");
    }
  } else {
    missing.push("skillet-repositories");
    reasons.push("skillet_repositories_missing");
  }

  let status = "bound";
  if (!details.storePresent || !details.storeRepositoriesPresent) {
    status = "missing_evidence";
  } else if (!details.appBundlePresent || !details.boundToExpectedAppID) {
    status = "partial";
    reasons.push("local_app_binding_incomplete");
  } else if (!details.sourceRevisionPresent) {
    status = "partial";
  }

  return layerResult({
    id: "local_store_binding",
    status,
    summary: status === "bound"
      ? "Local App/store binding evidence is discoverable without mutation"
      : "Local App/store binding evidence is incomplete or missing",
    evidence,
    missing,
    reasons,
    details,
  });
}

function listRepositoryIDs(storeRoot, repositoryFilter = null) {
  const repositoriesRoot = path.join(storeRoot, "repositories");
  if (!isDirectory(repositoriesRoot)) return [];
  let ids = fs
    .readdirSync(repositoriesRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && SAFE_ID.test(entry.name))
    .map((entry) => entry.name)
    .sort();
  if (repositoryFilter) {
    ids = ids.filter((id) => id === repositoryFilter);
  }
  return ids;
}

function readRepositoryMetadata(storeRoot, repositoryID) {
  const repositoryPath = path.join(
    storeRoot,
    "repositories",
    repositoryID,
    "repository.json",
  );
  const parsed = safeReadJSON(repositoryPath);
  if (!parsed.ok) {
    return { ok: false, path: repositoryPath, error: parsed.error };
  }
  const metadata = parsed.value;
  if (
    metadata?.schemaVersion !== 1
    || metadata.id !== repositoryID
    || typeof metadata.canonicalRevision !== "string"
  ) {
    return { ok: false, path: repositoryPath, error: "invalid_metadata" };
  }
  return { ok: true, path: repositoryPath, metadata };
}

function readRevision(storeRoot, repositoryID, revisionID) {
  const revisionPath = path.join(
    storeRoot,
    "repositories",
    repositoryID,
    "revisions",
    `${revisionID}.json`,
  );
  const parsed = safeReadJSON(revisionPath);
  if (!parsed.ok) {
    return { ok: false, path: revisionPath, error: parsed.error };
  }
  const revision = parsed.value;
  if (
    revision?.id !== revisionID
    || revision.repositoryID !== repositoryID
    || !SHA256_HEX.test(revision.contentDigest ?? "")
  ) {
    return { ok: false, path: revisionPath, error: "invalid_revision" };
  }
  if (revisionID !== `rev-${revision.contentDigest}` && !REV_ID.test(revisionID)) {
    // allow non-content-addressed IDs only when they still carry a digest field,
    // but flag later as weak.
  }
  return { ok: true, path: revisionPath, revision };
}

function readDeviceHead(storeRoot, repositoryID, deviceID) {
  if (!deviceID) return { ok: false, error: "device_id_not_provided" };
  const headPath = path.join(
    storeRoot,
    "repositories",
    repositoryID,
    "device-heads",
    `${deviceID}.json`,
  );
  const parsed = safeReadJSON(headPath);
  if (!parsed.ok) {
    return { ok: false, path: headPath, error: parsed.error };
  }
  const head = parsed.value;
  if (
    head?.deviceID !== deviceID
    || head.repositoryID !== repositoryID
    || typeof head.revisionID !== "string"
    || typeof head.activationState !== "string"
  ) {
    return { ok: false, path: headPath, error: "invalid_device_head" };
  }
  return { ok: true, path: headPath, head };
}

function readRepositoryReceipts(storeRoot, repositoryID) {
  const receiptsPath = path.join(
    storeRoot,
    "repositories",
    repositoryID,
    "receipts",
  );
  if (!lexists(receiptsPath)) {
    return { ok: true, path: receiptsPath, receipts: [], files: [] };
  }
  if (!isDirectory(receiptsPath)) {
    return {
      ok: false,
      path: receiptsPath,
      receipts: [],
      files: [],
      error: "receipts_not_directory",
    };
  }

  const receipts = [];
  const files = [];
  for (const entry of fs.readdirSync(receiptsPath, { withFileTypes: true })) {
    if (entry.name.startsWith(".") || !entry.name.endsWith(".json")) continue;
    const receiptPath = path.join(receiptsPath, entry.name);
    files.push(receiptPath);
    if (!entry.isFile() || entry.isSymbolicLink()) {
      return {
        ok: false,
        path: receiptsPath,
        receipts: [],
        files,
        error: "invalid_receipt_entry",
      };
    }
    const parsed = safeReadJSON(receiptPath);
    if (!parsed.ok) {
      return {
        ok: false,
        path: receiptsPath,
        receipts: [],
        files,
        error: `receipt_${parsed.error}`,
      };
    }
    const receipt = parsed.value;
    if (
      !receipt
      || typeof receipt !== "object"
      || !SAFE_ID.test(receipt.id ?? "")
      || entry.name !== `${receipt.id}.json`
      || receipt.repositoryID !== repositoryID
      || !REV_ID.test(receipt.revisionID ?? "")
      || !SHA256_HEX.test(receipt.contentDigest ?? "")
      || typeof receipt.kind !== "string"
      || !Number.isFinite(Date.parse(receipt.recordedAt ?? ""))
    ) {
      return {
        ok: false,
        path: receiptsPath,
        receipts: [],
        files,
        error: "invalid_receipt",
      };
    }
    receipts.push(receipt);
  }
  return { ok: true, path: receiptsPath, receipts, files };
}

function sameInstant(left, right) {
  const leftMilliseconds = Date.parse(left ?? "");
  const rightMilliseconds = Date.parse(right ?? "");
  return Number.isFinite(leftMilliseconds)
    && Number.isFinite(rightMilliseconds)
    && leftMilliseconds === rightMilliseconds;
}

function matchingReadinessDeviceReceipt({
  repositoryID,
  canonicalRevisionID,
  canonicalContentDigest,
  head,
  receipts,
}) {
  if (
    head.activationState !== "active"
    || head.revisionID !== canonicalRevisionID
    || head.contentDigest !== canonicalContentDigest
    || !Number.isInteger(head.ledgerSequence)
    || head.ledgerSequence <= 0
    || typeof head.requestID !== "string"
    || head.requestID.length === 0
    || !Number.isInteger(head.authorityEpoch)
    || head.authorityEpoch < 0
    || !Number.isFinite(Date.parse(head.lastVerifiedAt ?? ""))
  ) {
    return null;
  }
  return receipts.find((receipt) =>
    receipt.kind === "deviceHead"
    && receipt.repositoryID === repositoryID
    && receipt.revisionID === head.revisionID
    && receipt.contentDigest === head.contentDigest
    && receipt.deviceID === head.deviceID
    && receipt.requestID === head.requestID
    && receipt.authorityEpoch === head.authorityEpoch
    && receipt.ledgerSequence === head.ledgerSequence
    && receipt.activationState === head.activationState
    && sameInstant(receipt.recordedAt, head.lastVerifiedAt)
  ) ?? null;
}

function isExcludedSnapshotMetadata(relativePath) {
  return relativePath
    .split("/")
    .some((component) => component.toLowerCase() === ".git");
}

function snapshotDigestFromRuntime(runtimeRepositoryPath) {
  if (!isDirectory(runtimeRepositoryPath)) {
    return { ok: false, error: "runtime_repository_missing" };
  }
  const files = [];
  const visit = (directory, prefix) => {
    const entries = fs.readdirSync(directory, { withFileTypes: true })
      .sort((left, right) => left.name.localeCompare(right.name));
    for (const entry of entries) {
      const absolute = path.join(directory, entry.name);
      const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (isExcludedSnapshotMetadata(relative)) {
        continue;
      }
      const stat = fs.lstatSync(absolute);
      if (stat.isSymbolicLink()) {
        throw new Error(`runtime_symlink_forbidden:${relative}`);
      }
      if (stat.isDirectory()) {
        visit(absolute, relative);
        continue;
      }
      if (!stat.isFile()) {
        throw new Error(`runtime_unsupported_entry:${relative}`);
      }
      files.push({
        relativePath: relative.normalize("NFC"),
        data: fs.readFileSync(absolute),
      });
    }
  };
  try {
    visit(runtimeRepositoryPath, "");
  } catch (error) {
    return { ok: false, error: String(error?.message ?? error) };
  }
  files.sort((left, right) =>
    Buffer.compare(
      Buffer.from(left.relativePath, "utf8"),
      Buffer.from(right.relativePath, "utf8"),
    )
  );
  const hash = crypto.createHash("sha256");
  for (const file of files) {
    const pathBytes = Buffer.from(file.relativePath, "utf8");
    const lenPath = Buffer.alloc(8);
    lenPath.writeBigUInt64BE(BigInt(pathBytes.length));
    const lenData = Buffer.alloc(8);
    lenData.writeBigUInt64BE(BigInt(file.data.length));
    hash.update(lenPath);
    hash.update(pathBytes);
    hash.update(lenData);
    hash.update(file.data);
  }
  return {
    ok: true,
    contentDigest: hash.digest("hex"),
    fileCount: files.length,
    hasSkillManifest: files.some((file) => file.relativePath === "SKILL.md"),
  };
}

function activeSkillSetDigest(revisions) {
  if (!Array.isArray(revisions) || revisions.length === 0) {
    throw new Error("activeSkillSet.empty");
  }
  const seen = new Set();
  for (const entry of revisions) {
    if (
      !READINESS_SAFE_ID.test(entry.repository ?? "")
      || !READINESS_SAFE_ID.test(entry.revision ?? "")
      || !SHA256_HEX.test(entry.contentDigest ?? "")
    ) {
      throw new Error("activeSkillSet.invalid_entry");
    }
    if (seen.has(entry.repository)) throw new Error("activeSkillSet.duplicate");
    seen.add(entry.repository);
  }
  const sorted = [...revisions].sort((left, right) => {
    if (left.repository !== right.repository) {
      return left.repository < right.repository ? -1 : 1;
    }
    if (left.revision !== right.revision) {
      return left.revision < right.revision ? -1 : 1;
    }
    if (left.contentDigest !== right.contentDigest) {
      return left.contentDigest < right.contentDigest ? -1 : 1;
    }
    return 0;
  });
  // Mirror Swift JSONEncoder sortedKeys + no pretty-print.
  const payload = JSON.stringify(sorted.map((entry) => ({
    contentDigest: entry.contentDigest,
    repository: entry.repository,
    revision: entry.revision,
  })));
  return sha256Buffer(Buffer.from(payload, "utf8"));
}

function auditActiveRevision(paths, options) {
  const evidence = [];
  const missing = [];
  const reasons = [];
  const repositories = [];
  const repositoryIDs = listRepositoryIDs(paths.store, options.repositoryID);

  if (!options.deviceID) {
    return layerResult({
      id: "active_revision",
      status: "missing_evidence",
      summary: "Local device identity is unavailable for per-device active revision audit",
      missing: ["local-device-identity"],
      reasons: [
        `local_device_identity_${options.deviceIdentity?.error ?? "unavailable"}`,
        "cannot_select_per_device_active_revision_without_local_identity",
      ],
      details: {
        deviceIdentityPath: options.deviceIdentity?.path
          ? boundedRelative(
            options.fixtureRoot ?? paths.home,
            options.deviceIdentity.path,
          )
          : null,
      },
    });
  }

  if (repositoryIDs.length === 0) {
    return layerResult({
      id: "active_revision",
      status: "missing_evidence",
      summary: "No Skillet repositories found for active revision audit",
      missing: ["repositories"],
      reasons: ["no_repositories_in_store"],
      details: { store: boundedRelative(options.fixtureRoot ?? paths.home, paths.store) },
    });
  }

  let status = "matched";
  const readinessComparableActiveRevisions = [];
  const canonicalStoreRevisions = [];

  for (const repositoryID of repositoryIDs) {
    const repoInfo = readRepositoryMetadata(paths.store, repositoryID);
    evidence.push(evidencePath(
      `repository:${repositoryID}`,
      repoInfo.path,
      options.fixtureRoot ?? paths.home,
    ));
    if (!repoInfo.ok) {
      status = "missing_evidence";
      missing.push(`repository-metadata:${repositoryID}`);
      reasons.push(`repository_metadata_${repoInfo.error}:${repositoryID}`);
      repositories.push({ repositoryID, status: "missing_metadata" });
      continue;
    }

    const canonicalRevisionID = repoInfo.metadata.canonicalRevision;
    const revisionInfo = readRevision(paths.store, repositoryID, canonicalRevisionID);
    evidence.push(evidencePath(
      `revision:${repositoryID}`,
      revisionInfo.path,
      options.fixtureRoot ?? paths.home,
    ));
    if (!revisionInfo.ok) {
      status = "missing_evidence";
      missing.push(`revision:${repositoryID}:${canonicalRevisionID}`);
      reasons.push(`revision_${revisionInfo.error}:${repositoryID}`);
      repositories.push({
        repositoryID,
        status: "missing_revision",
        canonicalRevisionID,
      });
      continue;
    }
    canonicalStoreRevisions.push({
      repository: repositoryID,
      revision: canonicalRevisionID,
      contentDigest: revisionInfo.revision.contentDigest,
    });

    const deviceHead = readDeviceHead(paths.store, repositoryID, options.deviceID);
    if (deviceHead.path) {
      evidence.push(evidencePath(
        `device-head:${repositoryID}`,
        deviceHead.path,
        options.fixtureRoot ?? paths.home,
      ));
    }
    const receiptInfo = readRepositoryReceipts(paths.store, repositoryID);
    if (receiptInfo.files.length > 0) {
      for (const receiptPath of receiptInfo.files) {
        evidence.push(evidencePath(
          `receipt:${repositoryID}`,
          receiptPath,
          options.fixtureRoot ?? paths.home,
        ));
      }
    } else {
      evidence.push({
        kind: `receipts:${repositoryID}`,
        present: isDirectory(receiptInfo.path),
        path: boundedRelative(
          options.fixtureRoot ?? paths.home,
          receiptInfo.path,
        ),
      });
    }

    const runtimeRepoPath = path.join(paths.runtimeRoot, repositoryID);
    const runtimeDigest = snapshotDigestFromRuntime(runtimeRepoPath);
    if (runtimeDigest.ok) {
      evidence.push({
        kind: `runtime:${repositoryID}`,
        present: true,
        path: boundedRelative(options.fixtureRoot ?? paths.home, runtimeRepoPath),
        contentDigest: runtimeDigest.contentDigest,
        fileCount: runtimeDigest.fileCount,
      });
    } else {
      evidence.push({
        kind: `runtime:${repositoryID}`,
        present: false,
        path: boundedRelative(options.fixtureRoot ?? paths.home, runtimeRepoPath),
        error: runtimeDigest.error,
      });
    }

    const expectedRevision = options.expectedRevision ?? null;
    const expectedDigest = options.expectedDigest ?? revisionInfo.revision.contentDigest;
    const headRevision = deviceHead.ok ? deviceHead.head.revisionID : null;
    const headDigest = deviceHead.ok ? deviceHead.head.contentDigest : null;
    const headState = deviceHead.ok ? deviceHead.head.activationState : null;
    const matchingReceipt = deviceHead.ok && receiptInfo.ok
      ? matchingReadinessDeviceReceipt({
        repositoryID,
        canonicalRevisionID,
        canonicalContentDigest: revisionInfo.revision.contentDigest,
        head: deviceHead.head,
        receipts: receiptInfo.receipts,
      })
      : null;

    const mismatches = [];
    if (expectedRevision && canonicalRevisionID !== expectedRevision) {
      mismatches.push("canonical_revision_mismatch");
    }
    if (expectedDigest && revisionInfo.revision.contentDigest !== expectedDigest) {
      mismatches.push("canonical_digest_mismatch");
    }
    if (deviceHead.ok) {
      if (headState !== "active") mismatches.push("device_head_not_active");
      if (headRevision !== canonicalRevisionID) mismatches.push("device_head_revision_stale");
      if (headDigest && headDigest !== revisionInfo.revision.contentDigest) {
        mismatches.push("device_head_digest_mismatch");
      }
    } else {
      mismatches.push(`device_head_${deviceHead.error}`);
      missing.push(`device-head:${repositoryID}:${options.deviceID}`);
    }
    if (!receiptInfo.ok) {
      mismatches.push(`device_receipts_${receiptInfo.error}`);
      missing.push(`device-receipts:${repositoryID}`);
    } else if (deviceHead.ok && !matchingReceipt) {
      mismatches.push("matching_device_receipt_missing");
      missing.push(`matching-device-receipt:${repositoryID}:${options.deviceID}`);
    }

    if (runtimeDigest.ok) {
      if (runtimeDigest.contentDigest !== revisionInfo.revision.contentDigest) {
        mismatches.push("runtime_digest_mismatch");
      }
      if (!runtimeDigest.hasSkillManifest) {
        mismatches.push("runtime_missing_skill_manifest");
      }
    } else {
      mismatches.push(`runtime_${runtimeDigest.error}`);
      missing.push(`runtime:${repositoryID}`);
    }

    let repositoryStatus = "matched";
    if (mismatches.some((item) =>
      item.includes("mismatch") || item.includes("stale") || item.includes("not_active")
    )) {
      repositoryStatus = "stale_or_mismatched";
      status = "stale_or_mismatched";
      reasons.push(...mismatches.map((item) => `${item}:${repositoryID}`));
    } else if (mismatches.length > 0 || !deviceHead.ok) {
      repositoryStatus = deviceHead.ok ? "partial" : "missing_evidence";
      if (status === "matched") status = repositoryStatus;
      reasons.push(...mismatches.map((item) => `${item}:${repositoryID}`));
    }

    if (matchingReceipt) {
      readinessComparableActiveRevisions.push({
        repository: repositoryID,
        revision: deviceHead.head.revisionID,
        contentDigest: deviceHead.head.contentDigest,
      });
    }

    repositories.push({
      repositoryID,
      status: repositoryStatus,
      canonicalRevisionID,
      contentDigest: revisionInfo.revision.contentDigest,
      deviceID: options.deviceID ?? null,
      deviceHeadRevisionID: headRevision,
      deviceHeadContentDigest: headDigest,
      deviceHeadActivationState: headState,
      matchingDeviceReceiptID: matchingReceipt?.id ?? null,
      readinessComparable: Boolean(matchingReceipt),
      runtimeContentDigest: runtimeDigest.ok ? runtimeDigest.contentDigest : null,
      mismatches,
    });
  }

  let readinessComparableActiveSkillSetDigest = null;
  let canonicalStoreAuditDigest = null;
  try {
    if (readinessComparableActiveRevisions.length > 0) {
      readinessComparableActiveSkillSetDigest = activeSkillSetDigest(
        readinessComparableActiveRevisions,
      );
    } else {
      reasons.push("readiness_active_skill_set_empty");
      missing.push("readiness-comparable-active-skill-set");
      if (status === "matched") status = "missing_evidence";
    }
    if (canonicalStoreRevisions.length > 0) {
      canonicalStoreAuditDigest = activeSkillSetDigest(canonicalStoreRevisions);
    }
  } catch (error) {
    reasons.push(`active_skill_set_digest_${error.message}`);
    if (status === "matched") status = "failed";
  }

  return layerResult({
    id: "active_revision",
    status,
    summary: status === "matched"
      ? "Active Skill revision/digest evidence matches for inspected targets"
      : "Active Skill revision evidence is missing, partial, stale, or mismatched",
    evidence,
    missing,
    reasons,
    details: {
      repositories,
      readinessComparableActiveRevisions,
      readinessComparableActiveSkillSetDigest,
      readinessActiveStoreDigests: [
        ...new Set(readinessComparableActiveRevisions.map((entry) => entry.contentDigest)),
      ].sort(),
      canonicalStoreAuditDigest,
      // Backward-compatible alias. Remote readiness comparisons below use only
      // readinessComparableActiveSkillSetDigest.
      activeSkillSetDigest: readinessComparableActiveSkillSetDigest,
      target: options.target ?? null,
      deviceID: options.deviceID ?? null,
    },
  });
}

function collectConsumerReadbackFiles(options, paths) {
  const files = [];
  if (options.consumerReadback) {
    files.push(options.consumerReadback);
  }
  const dir = options.consumerReadbacksDir ?? paths.consumerReadbacksDir;
  if (dir && isDirectory(dir)) {
    const walk = (current) => {
      for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
        if (entry.name.startsWith(".")) continue;
        const absolute = path.join(current, entry.name);
        if (entry.isDirectory()) {
          walk(absolute);
        } else if (entry.isFile() && entry.name.endsWith(".json")) {
          files.push(absolute);
        }
      }
    };
    walk(dir);
  }
  return [...new Set(files)].sort();
}

function readbackTimestamp(value) {
  const raw = value?.issuedAt ?? value?.observedAt ?? null;
  if (typeof raw !== "string" || raw.length === 0) {
    return { ok: false, raw, source: null, epochMilliseconds: null };
  }
  const epochMilliseconds = Date.parse(raw);
  if (!Number.isFinite(epochMilliseconds)) {
    return {
      ok: false,
      raw,
      source: value?.issuedAt != null ? "issuedAt" : "observedAt",
      epochMilliseconds: null,
    };
  }
  return {
    ok: true,
    raw,
    source: value?.issuedAt != null ? "issuedAt" : "observedAt",
    epochMilliseconds,
  };
}

function auditConsumerReadback(paths, options, activeLayer) {
  const evidence = [];
  const missing = [];
  const reasons = [];
  const files = collectConsumerReadbackFiles(options, paths);

  if (!options.deviceID) {
    return layerResult({
      id: "consumer_readback",
      status: "missing_evidence",
      summary: "Local device identity is unavailable for consumer readback selection",
      missing: ["local-device-identity"],
      reasons: [
        `local_device_identity_${options.deviceIdentity?.error ?? "unavailable"}`,
        "consumer_readback_device_scope_unavailable",
      ],
      details: {
        note:
          "A default live audit never accepts a readback for an unverified or different device.",
      },
    });
  }

  if (files.length === 0) {
    return layerResult({
      id: "consumer_readback",
      status: "missing_evidence",
      summary:
        "No per-device consumer readback artifacts found; storage/sync receipts alone are insufficient",
      missing: ["consumer-readback-artifacts"],
      reasons: [
        "consumer_readback_absent",
        "cannot_claim_live_consumer_activation_without_readback",
      ],
      details: {
        searched: [
          options.consumerReadback
            ? boundedRelative(options.fixtureRoot ?? paths.home, options.consumerReadback)
            : null,
          boundedRelative(
            options.fixtureRoot ?? paths.home,
            options.consumerReadbacksDir ?? paths.consumerReadbacksDir,
          ),
        ].filter(Boolean),
      },
    });
  }

  const accepted = [];
  for (const filePath of files) {
    evidence.push(evidencePath("consumer-readback", filePath, options.fixtureRoot ?? paths.home));
    const parsed = safeReadJSON(filePath);
    if (!parsed.ok) {
      reasons.push(`consumer_readback_${parsed.error}:${path.basename(filePath)}`);
      continue;
    }
    const document = parsed.value;
    if (
      document?.schema !== "TatwoTargetConsumerReadbackSetV1"
      && document?.schema !== "TatwoTargetConsumerReadbackV1"
    ) {
      reasons.push(`consumer_readback_schema_unsupported:${path.basename(filePath)}`);
      continue;
    }

    if (document.schema === "TatwoTargetConsumerReadbackV1") {
      const timestamp = readbackTimestamp(document);
      accepted.push({
        path: filePath,
        kind: "single",
        status: document.status ?? null,
        consumerIDs: [document.consumerID].filter(Boolean),
        requestID: document.requestID ?? null,
        targetDeviceID: document.targetDeviceID ?? null,
        loadedRevision: document.loadedRevision ?? null,
        loadedDigest: document.loadedDigest ?? null,
        timestamp,
        loaded: SKILLET_CONSUMER_IDS.includes(document.consumerID)
          ? [{
            consumerID: document.consumerID,
            status: document.status ?? null,
            loadedRevision: document.loadedRevision ?? null,
            loadedDigest: document.loadedDigest ?? null,
            expectedDigest: document.expectedDigest ?? null,
            timestamp,
          }]
          : [],
      });
      continue;
    }

    const readbacks = Array.isArray(document.readbacks) ? document.readbacks : [];
    const consumerIDs = readbacks.map((entry) => entry?.consumerID).filter(Boolean);
    const timestamp = readbackTimestamp(document);
    accepted.push({
      path: filePath,
      kind: "set",
      status: document.status ?? null,
      consumerIDs,
      requestID: document.requestID ?? null,
      targetDeviceID: document.targetDeviceID ?? null,
      manifestDigest: document.manifestDigest ?? null,
      readbackCount: document.readbackCount ?? readbacks.length,
      skilletConsumersPresent: SKILLET_CONSUMER_IDS.filter((id) => consumerIDs.includes(id)),
      timestamp,
      loaded: readbacks
        .filter((entry) => SKILLET_CONSUMER_IDS.includes(entry?.consumerID))
        .map((entry) => ({
          consumerID: entry.consumerID,
          status: entry.status ?? null,
          loadedRevision: entry.loadedRevision ?? null,
          loadedDigest: entry.loadedDigest ?? null,
          expectedDigest: entry.expectedDigest ?? null,
          timestamp: readbackTimestamp(entry),
        })),
    });
  }

  if (accepted.length === 0) {
    return layerResult({
      id: "consumer_readback",
      status: "missing_evidence",
      summary: "Consumer readback files exist but none are valid readback evidence",
      evidence,
      missing: ["valid-consumer-readback"],
      reasons: reasons.length > 0 ? reasons : ["consumer_readback_invalid"],
    });
  }

  const targetCandidates = accepted.filter(
    (candidate) => candidate.targetDeviceID === options.deviceID,
  );
  if (targetCandidates.length === 0) {
    return layerResult({
      id: "consumer_readback",
      status: "failed",
      summary: "Consumer readbacks exist but none belong to the inspected local device",
      evidence,
      missing: [`consumer-readback:${options.deviceID}`],
      reasons: ["consumer_readback_target_device_mismatch"],
      details: {
        inspectedDeviceID: options.deviceID,
        observedTargetDeviceIDs: [
          ...new Set(accepted.map((candidate) => candidate.targetDeviceID).filter(Boolean)),
        ].sort(),
        note:
          "Readback evidence for another device is never accepted as local live proof.",
      },
    });
  }

  const timestampedCandidates = targetCandidates.filter(
    (candidate) => candidate.timestamp.ok,
  );
  if (timestampedCandidates.length === 0) {
    return layerResult({
      id: "consumer_readback",
      status: "failed",
      summary: "Local consumer readbacks have no valid issuedAt/observedAt timestamp",
      evidence,
      missing: ["consumer-readback-timestamp"],
      reasons: ["consumer_readback_timestamp_missing_or_invalid"],
      details: {
        inspectedDeviceID: options.deviceID,
        localCandidateCount: targetCandidates.length,
      },
    });
  }

  // Status and coverage never influence selection: the newest local readback
  // wins, so an older green artifact cannot shadow a newer red artifact.
  const preferred = [...timestampedCandidates].sort((left, right) => {
    if (left.timestamp.epochMilliseconds !== right.timestamp.epochMilliseconds) {
      return right.timestamp.epochMilliseconds - left.timestamp.epochMilliseconds;
    }
    return right.path.localeCompare(left.path);
  })[0];

  const activeDigest =
    activeLayer?.details?.readinessComparableActiveSkillSetDigest ?? null;
  const expectedDigests = new Set(
    (activeLayer?.details?.readinessActiveStoreDigests ?? [])
      .filter((value) => SHA256_HEX.test(value ?? "")),
  );
  const evaluatedAtMilliseconds = options.now.getTime();
  const readbackAgeSeconds =
    (evaluatedAtMilliseconds - preferred.timestamp.epochMilliseconds) / 1000;

  const missingConsumers = SKILLET_CONSUMER_IDS.filter(
    (id) => !(preferred.consumerIDs ?? []).includes(id),
  );
  if (missingConsumers.length > 0) {
    missing.push(...missingConsumers.map((id) => `consumer:${id}`));
    reasons.push(...missingConsumers.map((id) => `consumer_missing:${id}`));
  }

  if (preferred.status && preferred.status !== "passed" && preferred.status !== "loaded") {
    reasons.push(`consumer_readback_status_${preferred.status}`);
  }

  if (readbackAgeSeconds > options.consumerReadbackMaxAgeSeconds) {
    reasons.push("consumer_readback_stale");
  } else if (readbackAgeSeconds < -CONSUMER_READBACK_FUTURE_SKEW_SECONDS) {
    reasons.push("consumer_readback_future_dated");
  }

  if (expectedDigests.size === 0) {
    reasons.push("active_store_digest_set_unavailable");
  }

  for (const entry of preferred.loaded ?? []) {
    if (entry.status && entry.status !== "loaded") {
      reasons.push(`consumer_status_${entry.status}:${entry.consumerID}`);
    }
    if (
      entry.expectedDigest
      && entry.loadedDigest
      && entry.expectedDigest !== entry.loadedDigest
    ) {
      reasons.push(`consumer_digest_mismatch:${entry.consumerID}`);
    }
    if (!SHA256_HEX.test(entry.loadedDigest ?? "")) {
      reasons.push(`consumer_loaded_digest_missing_or_invalid:${entry.consumerID}`);
    } else if (!expectedDigests.has(entry.loadedDigest)) {
      reasons.push(`consumer_loaded_digest_not_in_active_store_set:${entry.consumerID}`);
    }
    if (entry.timestamp.raw != null && !entry.timestamp.ok) {
      reasons.push(`consumer_entry_timestamp_invalid:${entry.consumerID}`);
    } else {
      const entryTimestamp = entry.timestamp.ok ? entry.timestamp : preferred.timestamp;
      const entryAgeSeconds =
        (evaluatedAtMilliseconds - entryTimestamp.epochMilliseconds) / 1000;
      if (entryAgeSeconds > options.consumerReadbackMaxAgeSeconds) {
        reasons.push(`consumer_entry_stale:${entry.consumerID}`);
      } else if (entryAgeSeconds < -CONSUMER_READBACK_FUTURE_SKEW_SECONDS) {
        reasons.push(`consumer_entry_future_dated:${entry.consumerID}`);
      }
    }
  }

  for (const consumerID of SKILLET_CONSUMER_IDS) {
    const consumerEntries = (preferred.loaded ?? []).filter(
      (entry) => entry.consumerID === consumerID,
    );
    const loadedDigests = new Set(
      consumerEntries
        .map((entry) => entry.loadedDigest)
        .filter((digest) => SHA256_HEX.test(digest ?? "")),
    );
    if (
      expectedDigests.size > 0
      && (
        loadedDigests.size !== expectedDigests.size
        || [...expectedDigests].some((digest) => !loadedDigests.has(digest))
      )
    ) {
      reasons.push(`consumer_active_store_digest_set_incomplete:${consumerID}`);
    }
  }

  let status = "passed";
  if (
    reasons.some((item) =>
      item.includes("mismatch")
      || item.includes("status_")
      || item.includes("stale")
      || item.includes("future_dated")
      || item.includes("timestamp_invalid")
      || item.includes("digest_missing_or_invalid")
      || item.includes("digest_not_in_active_store_set")
      || item.includes("digest_set_incomplete")
      || item === "active_store_digest_set_unavailable"
    )
  ) {
    status = "failed";
  } else if (missingConsumers.length > 0) {
    status = "missing_evidence";
  } else if (preferred.status && !["passed", "loaded"].includes(preferred.status)) {
    status = "failed";
  }

  return layerResult({
    id: "consumer_readback",
    status,
    summary: status === "passed"
      ? "Per-device consumer readback evidence covers required Skillet consumers"
      : "Per-device consumer readback evidence is missing, incomplete, or mismatched",
    evidence,
    missing,
    reasons,
    details: {
      selected: {
        path: boundedRelative(options.fixtureRoot ?? paths.home, preferred.path),
        kind: preferred.kind,
        status: preferred.status,
        requestID: preferred.requestID,
        targetDeviceID: preferred.targetDeviceID,
        timestamp: preferred.timestamp.raw,
        timestampSource: preferred.timestamp.source,
        ageSeconds: readbackAgeSeconds,
        consumerIDs: preferred.consumerIDs,
        skilletConsumersPresent: preferred.skilletConsumersPresent ?? preferred.consumerIDs,
      },
      activeSkillSetDigestObserved: activeDigest,
      activeStoreDigests: [...expectedDigests].sort(),
      maxAgeSeconds: options.consumerReadbackMaxAgeSeconds,
      futureClockSkewSeconds: CONSUMER_READBACK_FUTURE_SKEW_SECONDS,
      acceptedCount: accepted.length,
      localCandidateCount: targetCandidates.length,
      note:
        "Consumer readback is independent of channel transport hashes; transport receipts alone never satisfy this layer.",
    },
  });
}

function collectSecretFieldNames(value, prefix = "", out = []) {
  if (!value || typeof value !== "object") return out;
  if (Array.isArray(value)) {
    value.forEach((entry, index) => {
      collectSecretFieldNames(entry, `${prefix}[${index}]`, out);
    });
    return out;
  }
  for (const [key, nested] of Object.entries(value)) {
    const pathKey = prefix ? `${prefix}.${key}` : key;
    if (SECRET_KEY_PATTERN.test(key)) out.push(pathKey);
    collectSecretFieldNames(nested, pathKey, out);
  }
  return out;
}

function detectSecretValues(text) {
  if (typeof text !== "string" || text.length === 0) return false;
  return SECRET_VALUE_PATTERNS.some((pattern) => pattern.test(text));
}

function loadRemoteJob(options) {
  if (!options.remoteJob) {
    return { ok: false, error: "remote_job_not_provided" };
  }
  const parsed = safeReadJSON(options.remoteJob);
  if (!parsed.ok) {
    return { ok: false, error: parsed.error, path: options.remoteJob };
  }
  const rawText = fs.readFileSync(options.remoteJob, "utf8");
  return {
    ok: true,
    path: options.remoteJob,
    job: parsed.value,
    secretFieldNames: collectSecretFieldNames(parsed.value),
    secretValuesDetected: detectSecretValues(rawText),
  };
}

function extractRemoteSkillDigest(job) {
  if (!job || typeof job !== "object") return null;
  const candidates = [
    job.activeSkillSetDigest,
    job.readiness?.activeSkillSetDigest,
    job.binding?.activeSkillSetDigest,
    job.remoteDispatchReadiness?.activeSkillSetDigest,
    job.skillBinding?.activeSkillSetDigest,
  ];
  for (const value of candidates) {
    if (typeof value === "string" && SHA256_HEX.test(value)) return value;
  }
  if (Array.isArray(job.activeSkillRevisions)) {
    try {
      return activeSkillSetDigest(job.activeSkillRevisions.map((entry) => ({
        repository: entry.repository ?? entry.repositoryID,
        revision: entry.revision ?? entry.revisionID,
        contentDigest: entry.contentDigest,
      })));
    } catch {
      return null;
    }
  }
  return null;
}

function auditRemoteJobSkillBinding(options, paths, activeLayer) {
  const evidence = [];
  const missing = [];
  const reasons = [];
  const loaded = loadRemoteJob(options);

  if (!loaded.ok) {
    return layerResult({
      id: "remote_job_skill_binding",
      status: "missing_evidence",
      summary: "Remote job Skill digest/binding evidence is not available",
      missing: ["remote-job"],
      reasons: [`remote_job_${loaded.error}`],
      details: {
        note:
          "Without a remote job binding, this audit cannot prove remote dispatch Skill digest alignment.",
      },
    });
  }

  evidence.push(evidencePath("remote-job", loaded.path, options.fixtureRoot ?? paths.home));
  const remoteDigest = extractRemoteSkillDigest(loaded.job);
  const localDigest =
    activeLayer?.details?.readinessComparableActiveSkillSetDigest ?? null;
  const redaction = {
    secretFieldsOmitted: loaded.secretFieldNames ?? [],
    secretValuesDetectedInSource: Boolean(loaded.secretValuesDetected),
    emissionPolicy: "secret_fields_and_values_never_emitted",
    marker: loaded.secretValuesDetected || (loaded.secretFieldNames?.length ?? 0) > 0
      ? "REDACTED_SECRET"
      : null,
  };

  if (!remoteDigest) {
    missing.push("remote-activeSkillSetDigest");
    reasons.push("remote_job_missing_skill_digest_binding");
    return layerResult({
      id: "remote_job_skill_binding",
      status: "missing_evidence",
      summary: "Remote job is present but lacks a Skill digest/binding field",
      evidence,
      missing,
      reasons,
      details: {
        jobID: typeof loaded.job.jobID === "string" ? loaded.job.jobID : null,
        schema: typeof loaded.job.schema === "string" ? loaded.job.schema : null,
        redaction,
      },
    });
  }

  if (!localDigest) {
    missing.push("local-activeSkillSetDigest");
    reasons.push("local_active_skill_set_digest_unavailable");
    return layerResult({
      id: "remote_job_skill_binding",
      status: "missing_evidence",
      summary: "Remote Skill digest exists but local active Skill set digest is unavailable",
      evidence,
      missing,
      reasons,
      details: {
        remoteActiveSkillSetDigest: remoteDigest,
        redaction,
      },
    });
  }

  if (remoteDigest !== localDigest) {
    reasons.push("remote_job_skill_digest_mismatch");
    return layerResult({
      id: "remote_job_skill_binding",
      status: "mismatch",
      summary: "Remote job Skill digest does not match local active Skill set digest",
      evidence,
      missing,
      reasons,
      details: {
        remoteActiveSkillSetDigest: remoteDigest,
        localActiveSkillSetDigest: localDigest,
        jobID: typeof loaded.job.jobID === "string" ? loaded.job.jobID : null,
        redaction,
      },
    });
  }

  return layerResult({
    id: "remote_job_skill_binding",
    status: "matched",
    summary: "Remote job Skill digest matches local active Skill set digest",
    evidence,
    missing,
    reasons,
    details: {
      remoteActiveSkillSetDigest: remoteDigest,
      localActiveSkillSetDigest: localDigest,
      jobID: typeof loaded.job.jobID === "string" ? loaded.job.jobID : null,
      redaction,
      note:
        "Digest match is necessary but not sufficient for live cross-machine skill borrowing; consumer readback and trust channel proofs remain separate.",
    },
  });
}

function buildCrossMachineClaim(layers) {
  // Explicit non-claim: storage or sync inventory never proves live borrowing.
  const consumer = layers.find((layer) => layer.id === "consumer_readback");
  const remote = layers.find((layer) => layer.id === "remote_job_skill_binding");
  const active = layers.find((layer) => layer.id === "active_revision");
  const local = layers.find((layer) => layer.id === "local_store_binding");

  const reasons = [
    "storage_or_sync_receipts_alone_never_prove_live_cross_machine_skill_borrowing",
  ];
  if (local && ["bound", "partial", "present"].includes(local.status)) {
    reasons.push("local_store_binding_is_machine_local_inventory_only");
  }
  if (!consumer || consumer.status !== "passed") {
    reasons.push("consumer_readback_not_passed");
  }
  if (!remote || remote.status !== "matched") {
    reasons.push("remote_job_skill_binding_not_matched");
  }
  if (!active || active.status !== "matched") {
    reasons.push("active_revision_not_fully_matched");
  }

  return {
    claim: "not_asserted",
    liveCrossMachineSkillBorrowing: false,
    reasons,
  };
}

function normalizeOptions(rawOptions = {}) {
  const options = {
    repoRoot: resolveOptionalPath(rawOptions.repoRoot ?? DEFAULT_REPO_ROOT)
      ?? DEFAULT_REPO_ROOT,
    fixtureRoot: resolveOptionalPath(rawOptions.fixtureRoot),
    store: resolveOptionalPath(rawOptions.store),
    runtimeRoot: resolveOptionalPath(rawOptions.runtimeRoot),
    appBundle: resolveOptionalPath(rawOptions.appBundle),
    appSupport: resolveOptionalPath(rawOptions.appSupport),
    consumerReadback: resolveOptionalPath(rawOptions.consumerReadback),
    consumerReadbacksDir: resolveOptionalPath(rawOptions.consumerReadbacksDir),
    remoteJob: resolveOptionalPath(rawOptions.remoteJob),
    deviceID: rawOptions.deviceID ?? null,
    target: rawOptions.target ?? null,
    expectedRevision: rawOptions.expectedRevision ?? null,
    expectedDigest: rawOptions.expectedDigest ?? null,
    repositoryID: rawOptions.repositoryID ?? null,
    consumerReadbackMaxAgeSeconds: parsePositiveInteger(
      rawOptions.consumerReadbackMaxAgeSeconds
        ?? DEFAULT_CONSUMER_READBACK_MAX_AGE_SECONDS,
      "--consumer-readback-max-age-seconds",
      MAX_CONSUMER_READBACK_MAX_AGE_SECONDS,
    ),
    now: rawOptions.now instanceof Date
      ? new Date(rawOptions.now.getTime())
      : new Date(rawOptions.now ?? Date.now()),
    receipt: resolveOptionalPath(rawOptions.receipt),
    json: Boolean(rawOptions.json),
  };

  if (options.deviceID && !SAFE_ID.test(options.deviceID)) {
    throw new Error("--device-id is malformed");
  }
  if (options.target && !SAFE_ID.test(options.target)) {
    throw new Error("--target is malformed");
  }
  if (options.repositoryID && !SAFE_ID.test(options.repositoryID)) {
    throw new Error("--repository is malformed");
  }
  if (options.expectedRevision && !SAFE_ID.test(options.expectedRevision) && !REV_ID.test(options.expectedRevision)) {
    // rev-<hex> is SAFE_ID-compatible; keep explicit guard for clarity.
    if (!/^rev-[A-Za-z0-9._-]+$/.test(options.expectedRevision)) {
      throw new Error("--expected-revision is malformed");
    }
  }
  if (options.expectedDigest && !SHA256_HEX.test(options.expectedDigest)) {
    throw new Error("--expected-digest must be 64 lowercase hex chars");
  }
  if (!Number.isFinite(options.now.getTime())) {
    throw new Error("audit evaluation time is invalid");
  }
  return options;
}

function runAudit(rawOptions = {}) {
  const normalizedOptions = normalizeOptions(rawOptions);
  const paths = defaultPaths(normalizedOptions);
  const options = resolveDeviceScope(paths, normalizedOptions);
  const generatedAt = options.now.toISOString();

  const sourceLayer = auditSourceImplementation(options.repoRoot);
  const localLayer = auditLocalStoreBinding(paths, options);
  const activeLayer = auditActiveRevision(paths, options);
  const consumerLayer = auditConsumerReadback(paths, options, activeLayer);
  const remoteLayer = auditRemoteJobSkillBinding(options, paths, activeLayer);

  const layers = [
    sourceLayer,
    localLayer,
    activeLayer,
    consumerLayer,
    remoteLayer,
  ];

  const missingEvidence = layers.flatMap((layer) =>
    (layer.missing ?? []).map((item) => `${layer.id}:${item}`)
  );
  const failClosedReasons = layers.flatMap((layer) => layer.reasons ?? []);
  const outcome = overallFromLayers(layers);
  const crossMachine = buildCrossMachineClaim(layers);

  const remoteDetails = remoteLayer.details ?? {};
  const receipt = {
    schema: SCHEMA,
    schemaVersion: SCHEMA_VERSION,
    readOnly: true,
    hostMutationAllowed: false,
    generatedAt,
    outcome,
    overallStatus: outcome,
    layers,
    layerStatus: Object.fromEntries(layers.map((layer) => [layer.id, layer.status])),
    missingEvidence,
    failClosedReasons: [...new Set(failClosedReasons)],
    crossMachineSkillBorrowing: crossMachine,
    redaction: {
      policy: "fail_closed_no_secret_emission",
      marker: remoteDetails.redaction?.marker ?? null,
      secretFieldsOmitted: remoteDetails.redaction?.secretFieldsOmitted ?? [],
      secretValuesDetectedInSource: Boolean(
        remoteDetails.redaction?.secretValuesDetectedInSource,
      ),
    },
    evidenceRoots: redactValue({
      repoRoot: options.fixtureRoot
        ? boundedRelative(options.fixtureRoot, options.repoRoot)
        : path.basename(options.repoRoot),
      fixtureRoot: options.fixtureRoot ? path.basename(options.fixtureRoot) : null,
      store: boundedRelative(options.fixtureRoot ?? paths.home, paths.store),
      runtimeRoot: boundedRelative(options.fixtureRoot ?? paths.home, paths.runtimeRoot),
      appBundle: boundedRelative(options.fixtureRoot ?? paths.home, paths.appBundle),
      appSupport: boundedRelative(options.fixtureRoot ?? paths.home, paths.appSupport),
      consumerReadbacksDir: boundedRelative(
        options.fixtureRoot ?? paths.home,
        options.consumerReadbacksDir ?? paths.consumerReadbacksDir,
      ),
      remoteJob: options.remoteJob
        ? boundedRelative(options.fixtureRoot ?? paths.home, options.remoteJob)
        : null,
    }),
    scope: {
      deviceID: options.deviceID,
      deviceIdentityStatus: options.deviceIdentity?.status ?? "unavailable",
      deviceIdentityPath: options.deviceIdentity?.path
        ? boundedRelative(
          options.fixtureRoot ?? paths.home,
          options.deviceIdentity.path,
        )
        : null,
      target: options.target,
      repositoryID: options.repositoryID,
      expectedRevision: options.expectedRevision,
      expectedDigest: options.expectedDigest,
      consumerReadbackMaxAgeSeconds: options.consumerReadbackMaxAgeSeconds,
    },
    actionableMissingEvidence: missingEvidence.length > 0
      ? missingEvidence
      : failClosedReasons.filter((reason) =>
        reason.includes("missing")
        || reason.includes("absent")
        || reason.includes("unavailable")
      ),
  };

  return redactValue(receipt);
}

function writeReceipt(filePath, receipt) {
  const directory = path.dirname(filePath);
  fs.mkdirSync(directory, { recursive: true });
  const temporary = path.join(
    directory,
    `.${path.basename(filePath)}.${process.pid}.${crypto.randomBytes(6).toString("hex")}.tmp`,
  );
  fs.writeFileSync(temporary, `${JSON.stringify(receipt, null, 2)}\n`, "utf8");
  fs.renameSync(temporary, filePath);
}

function main(argv = process.argv.slice(2)) {
  try {
    const parsed = parseArgs(argv);
    if (parsed.help) {
      process.stdout.write(`${usageText()}\n`);
      return 0;
    }
    const receipt = runAudit(parsed);
    if (parsed.receipt) writeReceipt(parsed.receipt, receipt);
    if (parsed.json) {
      process.stdout.write(`${JSON.stringify(receipt)}\n`);
    } else {
      process.stdout.write(
        `skillet_live_audit=${receipt.outcome}`
          + ` source=${receipt.layerStatus.source_implementation}`
          + ` store=${receipt.layerStatus.local_store_binding}`
          + ` active=${receipt.layerStatus.active_revision}`
          + ` consumer=${receipt.layerStatus.consumer_readback}`
          + ` remote=${receipt.layerStatus.remote_job_skill_binding}`
          + ` cross_machine_claim=${receipt.crossMachineSkillBorrowing.claim}\n`,
      );
      if (receipt.actionableMissingEvidence?.length) {
        process.stdout.write(
          `missing=${receipt.actionableMissingEvidence.slice(0, 12).join(",")}\n`,
        );
      }
    }
    return receipt.outcome === "passed" ? 0 : 1;
  } catch (error) {
    const message = redactString(error?.message ?? error);
    const failure = {
      schema: SCHEMA,
      schemaVersion: SCHEMA_VERSION,
      readOnly: true,
      hostMutationAllowed: false,
      outcome: "failed",
      overallStatus: "failed",
      error: message,
      generatedAt: new Date().toISOString(),
    };
    process.stderr.write(`${message}\n`);
    if (argv.includes("--json")) {
      process.stdout.write(`${JSON.stringify(failure)}\n`);
    }
    return 2;
  }
}

const isDirectCLI =
  process.argv[1]
  && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));
if (isDirectCLI) {
  process.exitCode = main();
}

export {
  SCHEMA,
  SCHEMA_VERSION,
  REQUIRED_SOURCE_EVIDENCE,
  SKILLET_CONSUMER_IDS,
  activeSkillSetDigest,
  main,
  parseArgs,
  redactString,
  redactValue,
  runAudit,
  isExcludedSnapshotMetadata,
  snapshotDigestFromRuntime,
};
