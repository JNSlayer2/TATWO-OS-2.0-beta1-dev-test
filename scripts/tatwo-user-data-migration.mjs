#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const args = process.argv.slice(2);
const apply = args.includes("--apply");
const supportBase = path.resolve(
  valueAfter("--application-support-root")
    ?? path.join(os.homedir(), "Library", "Application Support"),
);
const receiptPath = valueAfter("--receipt");
const canonicalRoot = path.join(supportBase, "Tatwo Ultrawork");
const sourceRoots = [
  path.join(canonicalRoot, "TatwoUltrawork"),
  path.join(supportBase, "TatwoUltrawork"),
];

if (apply && !receiptPath) {
  process.stderr.write("error: --receipt is required with --apply\n");
  process.exit(64);
}
const resolvedReceiptPath = receiptPath ? path.resolve(receiptPath) : null;
let receiptWriteSequence = 0;
if (apply && fs.existsSync(resolvedReceiptPath)) {
  process.stderr.write(`error: receipt already exists: ${resolvedReceiptPath}\n`);
  process.exit(2);
}

const candidates = [];
for (const sourceRoot of sourceRoots) {
  if (!fs.existsSync(sourceRoot)) continue;
  for (const entry of walk(sourceRoot)) {
    const relative = path.relative(sourceRoot, entry);
    const destination = path.join(canonicalRoot, relative);
    candidates.push({ sourceRoot, source: entry, relative, destination });
  }
}

const planned = [];
const identical = [];
const conflicts = [];
const claimed = new Map();
for (const candidate of candidates) {
  const destinationClaims = claimed.get(candidate.destination) ?? [];
  destinationClaims.push(candidate);
  claimed.set(candidate.destination, destinationClaims);
}

for (const destinationClaims of claimed.values()) {
  const relativePath = destinationClaims[0].relative;
  let material;
  const uniqueHashes = new Set(destinationClaims.map(({ source }) => hash(source)));
  if (uniqueHashes.size === 1) {
    material = {
      kind: "copy",
      source: destinationClaims[0].source,
      destination: destinationClaims[0].destination,
      relative: relativePath,
      sourceRoots: destinationClaims.map(({ sourceRoot }) => sourceRoot),
      digest: [...uniqueHashes][0],
    };
  } else if (relativePath === "native-chat-threads.json") {
    try {
      const merged = mergeNativeChatDocuments(destinationClaims.map(({ source }) => source));
      material = {
        kind: "native-chat-merge",
        data: merged.data,
        destination: destinationClaims[0].destination,
        relative: relativePath,
        sourceRoots: destinationClaims.map(({ sourceRoot }) => sourceRoot),
        digest: sha256(merged.data),
        summary: merged.summary,
      };
    } catch (error) {
      conflicts.push({
        relativePath,
        sources: destinationClaims.map(({ sourceRoot }) => sourceRoot),
        reason: `native chat merge refused: ${error.message}`,
      });
      continue;
    }
  } else {
    conflicts.push({
      relativePath,
      sources: destinationClaims.map(({ sourceRoot }) => sourceRoot),
      reason: "legacy sources differ",
    });
    continue;
  }

  if (!fs.existsSync(material.destination)) {
    planned.push(material);
  } else if (hash(material.destination) === material.digest) {
    identical.push(material);
  } else {
    conflicts.push({
      relativePath,
      sources: material.sourceRoots,
      reason: "canonical destination differs",
    });
  }
}

if (conflicts.length > 0) {
  process.stdout.write(`${JSON.stringify({
    schema: "TatwoUserDataMigrationConflictV1",
    mode: apply ? "apply" : "preflight",
    canonicalRoot,
    conflictCount: conflicts.length,
    conflicts: conflicts.map(({ relativePath, reason }) => ({
      relativePath,
      reason,
    })),
  }, null, 2)}\n`);
  process.stderr.write(
    `error: migration conflict; ${conflicts.length} path(s) require human review\n`,
  );
  process.exit(2);
}

let copiedCount = 0;
const createdDestinations = [];
const temporaryPaths = [];
if (apply) {
  fs.mkdirSync(path.dirname(resolvedReceiptPath), { recursive: true });
  fs.writeFileSync(resolvedReceiptPath, `${JSON.stringify({
    schema: "TatwoUserDataMigrationReceiptV1",
    observedAt: new Date().toISOString(),
    mode: "apply",
    outcome: "in_progress",
    copiedCount: 0,
    sourceDataPreserved: true,
  }, null, 2)}\n`, { flag: "wx" });
  try {
    for (const item of planned) {
      fs.mkdirSync(path.dirname(item.destination), { recursive: true });
      const temporary = `${item.destination}.tatwo-migration-${process.pid}`;
      temporaryPaths.push(temporary);
      if (item.kind === "copy") {
        fs.copyFileSync(item.source, temporary, fs.constants.COPYFILE_EXCL);
      } else {
        fs.writeFileSync(temporary, item.data, { flag: "wx" });
      }
      if (hash(temporary) !== item.digest) {
        throw Object.assign(new Error("staged migration hash mismatch"), {
          code: "staged_hash_mismatch",
        });
      }
      fs.linkSync(temporary, item.destination);
      createdDestinations.push(item.destination);
      if (
        process.env.NODE_ENV === "test"
        && process.env.TATWO_TEST_FAIL_MIGRATION_TEMP_UNLINK === "1"
      ) {
        throw Object.assign(new Error("injected migration temporary unlink failure"), {
          code: "injected_migration_temp_unlink_failure",
        });
      }
      fs.unlinkSync(temporary);
      temporaryPaths.pop();
      copiedCount += 1;
    }
  } catch (error) {
    const rollbackFailures = [
      ...rollbackFailuresFrom(error),
      ...removeAndVerify(temporaryPaths, "temporary"),
      ...removeAndVerify(createdDestinations, "destination"),
    ];
    writeReceipt(resolvedReceiptPath, {
      schema: "TatwoUserDataMigrationReceiptV1",
      observedAt: new Date().toISOString(),
      mode: "apply",
      outcome: rollbackFailures.length === 0 ? "failed_rolled_back" : "rollback_failed",
      copiedCount: 0,
      sourceDataPreserved: true,
      errorKind: error?.code ?? "migration_apply_failed",
      rollbackFailureCount: rollbackFailures.length,
      rollbackErrorKinds: [...new Set(rollbackFailures.map(({ errorKind }) => errorKind))],
    });
    throw error;
  }
}

const mergePlans = planned
  .filter(({ kind }) => kind === "native-chat-merge")
  .map(({ relative, digest, summary }) => ({
    relativePath: relative,
    outputSHA256: digest,
    ...summary,
  }));
const result = {
  schema: "TatwoUserDataMigrationReceiptV1",
  observedAt: new Date().toISOString(),
  mode: apply ? "apply" : "preflight",
  outcome: apply ? "completed" : "planned",
  canonicalRoot,
  legacyRoots: sourceRoots,
  copyCount: planned.length,
  copiedCount,
  identicalCount: identical.length,
  conflictCount: conflicts.length,
  mergeCount: mergePlans.length,
  mergePlans,
  sourceDataPreserved: true,
  rollback:
    "Legacy roots remain untouched. If activation fails, keep the previous bundle and legacy roots; do not delete either copy.",
};

if (apply) {
  try {
    writeReceipt(resolvedReceiptPath, result);
  } catch (error) {
    const rollbackFailures = [
      ...rollbackFailuresFrom(error),
      ...removeAndVerify(createdDestinations, "destination"),
    ];
    try {
      writeReceipt(resolvedReceiptPath, {
        schema: "TatwoUserDataMigrationReceiptV1",
        observedAt: new Date().toISOString(),
        mode: "apply",
        outcome: rollbackFailures.length === 0 ? "failed_rolled_back" : "rollback_failed",
        copiedCount: 0,
        sourceDataPreserved: true,
        errorKind: error?.code ?? "receipt_finalize_failed",
        rollbackFailureCount: rollbackFailures.length,
        rollbackErrorKinds: [...new Set(rollbackFailures.map(({ errorKind }) => errorKind))],
      });
    } catch {}
    throw error;
  }
}
process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);

function valueAfter(flag) {
  const index = args.indexOf(flag);
  if (index < 0) return null;
  const value = args[index + 1];
  if (!value || value.startsWith("--")) {
    process.stderr.write(`error: ${flag} requires a value\n`);
    process.exit(64);
  }
  return value;
}

function walk(root) {
  const results = [];
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const fullPath = path.join(root, entry.name);
    if (entry.isSymbolicLink()) {
      process.stderr.write(`error: migration refuses symbolic link: ${fullPath}\n`);
      process.exit(2);
    }
    if (entry.isDirectory()) {
      results.push(...walk(fullPath));
    } else if (entry.isFile()) {
      results.push(fullPath);
    }
  }
  return results;
}

function hash(file) {
  return sha256(fs.readFileSync(file));
}

function sha256(data) {
  return crypto.createHash("sha256").update(data).digest("hex");
}

function writeReceipt(target, value) {
  receiptWriteSequence += 1;
  const temporary = `${target}.tatwo-receipt-${process.pid}-${receiptWriteSequence}`;
  try {
    fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { flag: "wx" });
    if (
      process.env.NODE_ENV === "test"
      && process.env.TATWO_TEST_FAIL_COMPLETED_RECEIPT_RENAME === "1"
      && value?.outcome === "completed"
    ) {
      throw Object.assign(new Error("injected completed receipt rename failure"), {
        code: "injected_receipt_finalize_failure",
      });
    }
    fs.renameSync(temporary, target);
  } catch (error) {
    throw withRollbackFailures(
      error,
      removeAndVerify([temporary], "receipt_temporary"),
    );
  }
}

function removeAndVerify(paths, kind) {
  const failures = [];
  for (const target of [...paths].reverse()) {
    const injectedFailure = (
      process.env.NODE_ENV === "test"
      && process.env.TATWO_TEST_FAIL_ROLLBACK_KIND === kind
    );
    if (injectedFailure) {
      failures.push({
        kind,
        errorKind: "injected_rollback_unlink_failure",
      });
    } else {
      try {
        fs.unlinkSync(target);
      } catch (error) {
        if (error?.code !== "ENOENT") {
          failures.push({
            kind,
            errorKind: error?.code ?? "unlink_failed",
          });
        }
      }
    }
    if (fs.existsSync(target)) {
      failures.push({
        kind,
        errorKind: "path_still_exists",
      });
    }
  }
  return failures;
}

function rollbackFailuresFrom(error) {
  return Array.isArray(error?.tatwoRollbackFailures)
    ? error.tatwoRollbackFailures
    : [];
}

function withRollbackFailures(error, failures) {
  if (failures.length === 0) return error;
  const target = error instanceof Error ? error : new Error(String(error));
  target.tatwoRollbackFailures = [
    ...rollbackFailuresFrom(target),
    ...failures,
  ];
  return target;
}

function mergeNativeChatDocuments(files) {
  const documents = files.map((file) => {
    const decoded = JSON.parse(fs.readFileSync(file, "utf8"));
    assertNativeChatDocument(decoded);
    return decoded;
  });

  const projects = mergeByID(
    documents.flatMap(({ projects = [] }) => projects),
    "project",
    mergeNativeChatProjects,
  );
  const threads = mergeByID(
    documents.flatMap(({ threads = [] }) => threads),
    "standalone thread",
    mergeIdenticalRecords,
  );
  const merged = {
    projects,
    schemaVersion: 1,
    threads,
    updatedAt: latestISO(documents.map(({ updatedAt }) => updatedAt)),
  };
  const allThreads = threads.concat(projects.flatMap(({ threads: children = [] }) => children));
  assertUniqueThreadPlacement(allThreads);
  const data = Buffer.from(`${JSON.stringify(merged, null, 2)}\n`);
  return {
    data,
    summary: {
      sourceDocumentCount: documents.length,
      projectCount: projects.length,
      standaloneThreadCount: threads.length,
      projectThreadCount: projects.reduce(
        (count, { threads: children = [] }) => count + children.length,
        0,
      ),
      messageCount: allThreads.reduce(
        (count, { messages = [] }) => count + messages.length,
        0,
      ),
      discussionCount: allThreads.reduce(
        (count, { discussions = [] }) => count + discussions.length,
        0,
      ),
      projectIDHashes: projects.map(({ id }) => publicIDHash(id)),
      threadIDHashes: allThreads.map(({ id }) => publicIDHash(id)).sort(),
    },
  };
}

function assertNativeChatDocument(document) {
  if (!document || typeof document !== "object" || Array.isArray(document)) {
    throw new Error("document is not an object");
  }
  if (document.schemaVersion !== 1) {
    throw new Error(`unsupported schemaVersion ${JSON.stringify(document.schemaVersion)}`);
  }
  if (document.projects !== undefined && !Array.isArray(document.projects)) {
    throw new Error("projects must be an array");
  }
  if (document.threads !== undefined && !Array.isArray(document.threads)) {
    throw new Error("threads must be an array");
  }
  if (!isISODate(document.updatedAt)) {
    throw new Error("updatedAt must be an ISO-8601 string");
  }
  const allowedKeys = new Set(["projects", "schemaVersion", "threads", "updatedAt"]);
  const unknownKeys = Object.keys(document).filter((key) => !allowedKeys.has(key));
  if (unknownKeys.length > 0) {
    throw new Error(`unknown top-level fields: ${unknownKeys.sort().join(",")}`);
  }
}

function mergeNativeChatProjects(records) {
  const first = structuredClone(records[0]);
  const metadata = records.map(({ threads: _threads, ...rest }) => rest);
  mergeIdenticalRecords(metadata);
  first.threads = mergeByID(
    records.flatMap(({ threads = [] }) => threads),
    `thread in project ${publicIDHash(first.id)}`,
    mergeIdenticalRecords,
  );
  return first;
}

function mergeIdenticalRecords(records) {
  const canonical = stableJSONString(records[0]);
  if (records.some((record) => stableJSONString(record) !== canonical)) {
    throw new Error("same logical ID contains different records");
  }
  return structuredClone(records[0]);
}

function mergeByID(records, label, mergeRecords) {
  const grouped = new Map();
  for (const record of records) {
    if (!record || typeof record !== "object" || Array.isArray(record)) {
      throw new Error(`${label} is not an object`);
    }
    if (typeof record.id !== "string" || record.id.trim() === "") {
      throw new Error(`${label} has no stable string ID`);
    }
    const group = grouped.get(record.id) ?? [];
    group.push(record);
    grouped.set(record.id, group);
  }
  return [...grouped.entries()]
    .sort(([left], [right]) => compareCodePoints(left, right))
    .map(([_id, group]) => mergeRecords(group));
}

function latestISO(values) {
  if (values.some((value) => !isISODate(value))) {
    throw new Error("cannot determine latest updatedAt");
  }
  return [...values].sort((left, right) => {
    const timeDifference = Date.parse(left) - Date.parse(right);
    return timeDifference || compareCodePoints(left, right);
  }).at(-1);
}

function isISODate(value) {
  return typeof value === "string" && Number.isFinite(Date.parse(value));
}

function publicIDHash(value) {
  return sha256(String(value)).slice(0, 12);
}

function assertUniqueThreadPlacement(threads) {
  const seen = new Set();
  for (const thread of threads) {
    if (seen.has(thread.id)) {
      throw new Error(
        `thread ${publicIDHash(thread.id)} appears in more than one container`,
      );
    }
    seen.add(thread.id);
  }
}

function stableJSONString(value) {
  if (Array.isArray(value)) {
    return `[${value.map(stableJSONString).join(",")}]`;
  }
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${stableJSONString(value[key])}`
    ).join(",")}}`;
  }
  return JSON.stringify(value);
}

function compareCodePoints(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}
