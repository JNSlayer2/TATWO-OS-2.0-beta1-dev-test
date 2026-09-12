#!/usr/bin/env node
/**
 * OS-owned Codex agent preset projector.
 *
 * Source truth:
 *   registry/agent-presets.v1.json
 *
 * Safety flow:
 *   validate -> deterministic staging + exact diff -> explicit authorization
 *   -> injected target apply -> readback receipt -> recoverable rollback
 *
 * There is deliberately no default ~/.codex path. A path under ~/.codex is
 * rejected unless the caller supplies --i-understand-user-config, and apply
 * still requires a fresh authorization document bound to the exact Work OS
 * Goal, operational Plan, generated plan, target root, backup root, registry
 * digest, and file list.
 */

import { createHash, randomUUID } from "node:crypto";
import {
  closeSync,
  constants as fsConstants,
  existsSync,
  fstatSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readlinkSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import {
  basename,
  dirname,
  join,
  relative,
  resolve,
  sep,
} from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const REPO_ROOT = resolve(dirname(SCRIPT_PATH), "..");
const DEFAULT_REGISTRY = join(REPO_ROOT, "registry", "agent-presets.v1.json");
const RENDERER_VERSION = "tatwo-codex-agent-preset-renderer-v1";
const AUTHORIZATION_MAX_TTL_MS = 15 * 60 * 1000;
const AUTHORIZATION_MAX_FUTURE_SKEW_MS = 60 * 1000;
const AUTHORITY_HASH_PATTERN = /^sha256:[0-9a-f]{64}$/;
const REQUIRED_IDS = [
  "uw-builder",
  "uw-orchestrator",
  "uw-reviewer",
  "uw-scout",
  "uw-verifier",
];
const ALLOWED_MODELS = [
  "gpt-5.5",
  "gpt-5.6-sol",
  "gpt-5.6-terra",
];
const FORBIDDEN_MODELS = new Set([
  "gpt-5.4",
  "gpt-5.4-mini",
  "gpt-5.6-luna",
  "luna",
]);
const ALLOWED_EFFORTS = new Set(["low", "medium", "high", "xhigh"]);
const ALLOWED_IDENTITIES = new Set([
  "orchestrator",
  "loops_sub",
  "reviewer",
  "verifier",
]);
const ALLOWED_LANES = new Set([
  "orchestrator",
  "reviewer",
  "sandbox_builder",
  "verifier",
]);
const ALLOWED_MODES = new Set(["M", "L", "XL", "XXL"]);
const ALLOWED_WORKLOADS = new Set(["light", "medium", "heavy"]);
const EXPECTED_ROLE = {
  "uw-orchestrator": { identity: "orchestrator", lanes: ["orchestrator"] },
  "uw-builder": { identity: "loops_sub", lanes: ["sandbox_builder"] },
  "uw-reviewer": { identity: "reviewer", lanes: ["reviewer"] },
  "uw-verifier": { identity: "verifier", lanes: ["verifier"] },
  "uw-scout": { identity: "loops_sub", lanes: ["sandbox_builder"] },
};
const REGISTRY_KEYS = new Set([
  "schema",
  "source",
  "registryRevision",
  "allowedGPTModels",
  "agentPresets",
]);
const PRESET_KEYS = new Set([
  "id",
  "displayName",
  "identityGroup",
  "codexAgentName",
  "description",
  "modelBinding",
  "effort",
  "maxConcurrent",
  "workloadClass",
  "allowedLanes",
  "allowedModes",
  "allowedScenarios",
  "v2Eligible",
  "protectedSurfaceOk",
  "highRiskLaneOk",
  "codexTomlExtras",
  "revision",
]);
const AUTHORIZATION_KEYS = new Set([
  "schema",
  "approvedGoalHash",
  "approvedOperationalPlanHash",
  "approvedPlanDigest",
  "approvedRegistryDigest",
  "approvedTargetRoot",
  "approvedBackupRoot",
  "approvedFiles",
  "approver",
  "approvedAt",
  "expiresAt",
]);

function usage(message) {
  if (message) console.error(`Error: ${message}`);
  console.error(`Usage:
  node scripts/tatwo-agent-preset-controller.mjs validate [--registry <path>] [--json]
  node scripts/tatwo-agent-preset-controller.mjs plan --registry <path> --current-root <path> --staging-root <path> --goal-hash <sha256:...> --operational-plan-hash <sha256:...> [--i-understand-user-config] [--json]
  node scripts/tatwo-agent-preset-controller.mjs apply --plan <path> --target-root <path> --backup-root <path> --authorization <path> [--receipt-out <path>] [--i-understand-user-config] [--json]
  node scripts/tatwo-agent-preset-controller.mjs rollback --receipt <path> [--receipt-out <path>] [--i-understand-user-config] [--json]
  node scripts/tatwo-agent-preset-controller.mjs --selftest

Authorization schema:
  TatwoCodexAgentPresetApplyAuthorizationV2

Notes:
  - No command defaults to ~/.codex or writes live user config silently.
  - plan always stages generated files and an exact diff before apply.
  - current TOML is observation only; manual edits are conflict, never truth.
  - apply/rollback operate on injected roots and use recoverable backups.`);
}

function die(message, code = 1) {
  console.error(`ERROR ${message}`);
  process.exit(code);
}

function parseArgs(argv) {
  const options = {
    command: null,
    registry: null,
    currentRoot: null,
    stagingRoot: null,
    plan: null,
    targetRoot: null,
    backupRoot: null,
    goalHash: null,
    operationalPlanHash: null,
    authorization: null,
    receipt: null,
    receiptOut: null,
    acknowledgeUserConfig: false,
    json: false,
    selftest: false,
  };
  const args = [...argv];
  if (args[0] === "--selftest") {
    options.selftest = true;
    args.shift();
  } else if (args[0] && !args[0].startsWith("-")) {
    options.command = args.shift();
  }
  for (let index = 0; index < args.length; index += 1) {
    const flag = args[index];
    const take = () => {
      const value = args[++index];
      if (!value || value.startsWith("--")) die(`${flag} requires a value`);
      return value;
    };
    if (flag === "--registry") options.registry = take();
    else if (flag === "--current-root") options.currentRoot = take();
    else if (flag === "--staging-root") options.stagingRoot = take();
    else if (flag === "--plan") options.plan = take();
    else if (flag === "--target-root") options.targetRoot = take();
    else if (flag === "--backup-root") options.backupRoot = take();
    else if (flag === "--goal-hash") options.goalHash = take();
    else if (flag === "--operational-plan-hash") options.operationalPlanHash = take();
    else if (flag === "--authorization") options.authorization = take();
    else if (flag === "--receipt") options.receipt = take();
    else if (flag === "--receipt-out") options.receiptOut = take();
    else if (flag === "--i-understand-user-config") {
      options.acknowledgeUserConfig = true;
    } else if (flag === "--json") options.json = true;
    else if (flag === "--selftest") options.selftest = true;
    else if (flag === "--help" || flag === "-h") {
      usage();
      process.exit(0);
    } else {
      die(`unknown flag: ${flag}`);
    }
  }
  return options;
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function stableValue(value) {
  if (Array.isArray(value)) return value.map(stableValue);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value).sort().map((key) => [key, stableValue(value[key])]),
    );
  }
  return value;
}

function stableJSON(value) {
  return JSON.stringify(stableValue(value));
}

function prettyJSON(value) {
  return `${JSON.stringify(stableValue(value), null, 2)}\n`;
}

function canonicalPath(input) {
  const raw = String(input || "").trim();
  if (!raw) throw new Error("path is empty");
  const expanded = raw.replace(
    /^~(?=\/|$)/,
    process.env.HOME || homedir() || "~",
  );
  let pending = resolve(expanded);
  for (let attempt = 0; attempt < 64; attempt += 1) {
    const components = pending.split("/").filter(Boolean);
    let resolvedPath = "/";
    let changed = false;
    for (let index = 0; index < components.length; index += 1) {
      const candidate = join(resolvedPath, components[index]);
      try {
        if (lstatSync(candidate).isSymbolicLink()) {
          const linkTarget = readlinkSync(candidate);
          let next = linkTarget.startsWith("/")
            ? linkTarget
            : join(dirname(candidate), linkTarget);
          for (const remainder of components.slice(index + 1)) {
            next = join(next, remainder);
          }
          pending = resolve(next);
          changed = true;
          break;
        }
      } catch {
        // Missing suffixes are appended lexically after the nearest existing
        // ancestor. A later apply preflight rejects symlink target files.
      }
      resolvedPath = candidate;
    }
    if (!changed) return resolvedPath;
  }
  throw new Error(`symlink resolution exceeded bounded attempts: ${input}`);
}

function isWithin(candidate, root) {
  const rel = relative(root, candidate);
  return rel === "" || (!rel.startsWith(`..${sep}`) && rel !== ".." && !rel.startsWith(sep));
}

function assertUserConfigPolicy(path, { allow = false, label = "path" } = {}) {
  const home = canonicalPath(process.env.HOME || homedir());
  const codex = canonicalPath(join(home, ".codex"));
  const candidate = canonicalPath(path);
  if (isWithin(candidate, codex) && !allow) {
    throw new Error(
      `${label} is under ~/.codex; pass --i-understand-user-config and an exact authorization`,
    );
  }
}

function assertBackupOutsideUserConfig(path) {
  assertUserConfigPolicy(path, { allow: false, label: "backup root" });
}

function assertDirectFileNotSymlink(path, label) {
  let entry;
  try {
    entry = lstatSync(path);
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
  if (entry.isSymbolicLink()) {
    throw new Error(`${label} is a symlink and is rejected fail-closed: ${path}`);
  }
  return true;
}

function readDirectFileNoFollow(path, label) {
  if (typeof fsConstants.O_NOFOLLOW !== "number") {
    throw new Error("O_NOFOLLOW is unavailable; direct file read fails closed");
  }
  let descriptor;
  try {
    descriptor = openSync(path, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
  } catch (error) {
    if (error?.code === "ELOOP") {
      throw new Error(`${label} is a symlink and is rejected fail-closed: ${path}`);
    }
    throw error;
  }
  try {
    if (!fstatSync(descriptor).isFile()) {
      throw new Error(`${label} is not a regular file: ${path}`);
    }
    return readFileSync(descriptor);
  } finally {
    closeSync(descriptor);
  }
}

function writeExclusiveArchive(path, content, label) {
  if (typeof fsConstants.O_NOFOLLOW !== "number") {
    throw new Error("O_NOFOLLOW is unavailable; archive write fails closed");
  }
  const descriptor = openSync(
    path,
    fsConstants.O_CREAT
      | fsConstants.O_EXCL
      | fsConstants.O_WRONLY
      | fsConstants.O_NOFOLLOW,
    0o600,
  );
  try {
    writeFileSync(descriptor, content);
    fsyncSync(descriptor);
  } catch (error) {
    throw new Error(`${label} write failed: ${error?.message || error}`);
  } finally {
    closeSync(descriptor);
  }
}

function readJSON(path) {
  return JSON.parse(readFileSync(canonicalPath(path), "utf8"));
}

function requireString(value, label) {
  if (typeof value !== "string" || !value.trim()) {
    throw new Error(`${label} must be a non-empty string`);
  }
  return value.trim();
}

function requireAuthorityHash(value, label) {
  const normalized = requireString(value, label);
  if (!AUTHORITY_HASH_PATTERN.test(normalized)) {
    throw new Error(`${label} must be sha256:<64 lowercase hex>`);
  }
  return normalized;
}

function requireUniqueStringArray(value, label, allowed = null) {
  if (!Array.isArray(value) || value.length === 0) {
    throw new Error(`${label} must be a non-empty array`);
  }
  const normalized = value.map((item, index) => {
    const itemValue = requireString(item, `${label}[${index}]`);
    if (allowed && !allowed.has(itemValue)) {
      throw new Error(`${label}[${index}] has unknown value ${itemValue}`);
    }
    return itemValue;
  });
  if (new Set(normalized).size !== normalized.length) {
    throw new Error(`${label} contains duplicate values`);
  }
  return normalized;
}

function assertNoUnknownKeys(value, allowed, label) {
  const unknown = Object.keys(value).filter((key) => !allowed.has(key)).sort();
  if (unknown.length) {
    throw new Error(`${label} contains unknown key(s): ${unknown.join(",")}`);
  }
}

function validatePreset(raw, index) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new Error(`agentPresets[${index}] must be an object`);
  }
  assertNoUnknownKeys(raw, PRESET_KEYS, `agentPresets[${index}]`);
  const id = requireString(raw.id, `agentPresets[${index}].id`);
  if (!/^uw-[a-z0-9-]+$/.test(id) || id.includes("..") || id.includes("/")) {
    throw new Error(`${id}: id/path traversal rejected`);
  }
  if (!REQUIRED_IDS.includes(id)) {
    throw new Error(`${id}: unknown canonical preset id`);
  }
  const codexAgentName = requireString(raw.codexAgentName, `${id}.codexAgentName`);
  if (codexAgentName !== id || !/^uw-[a-z0-9-]+$/.test(codexAgentName)) {
    throw new Error(`${id}: codexAgentName must exactly equal id`);
  }
  const identityGroup = requireString(raw.identityGroup, `${id}.identityGroup`);
  if (!ALLOWED_IDENTITIES.has(identityGroup)) {
    throw new Error(`${id}: identity_lane_pollution: unknown identity ${identityGroup}`);
  }
  const lanes = requireUniqueStringArray(
    raw.allowedLanes,
    `${id}.allowedLanes`,
    ALLOWED_LANES,
  );
  const expected = EXPECTED_ROLE[id];
  if (
    identityGroup !== expected.identity
    || stableJSON(lanes) !== stableJSON(expected.lanes)
  ) {
    throw new Error(
      `${id}: identity_lane_pollution: expected ${expected.identity}/${expected.lanes.join(",")}`,
    );
  }
  const modelBinding = requireString(raw.modelBinding, `${id}.modelBinding`);
  if (FORBIDDEN_MODELS.has(modelBinding) || !ALLOWED_MODELS.includes(modelBinding)) {
    throw new Error(`${id}: forbidden or unapproved model ${modelBinding}`);
  }
  const effort = requireString(raw.effort, `${id}.effort`);
  if (!ALLOWED_EFFORTS.has(effort)) {
    throw new Error(`${id}: unknown effort ${effort}`);
  }
  const maxConcurrent = raw.maxConcurrent;
  if (!Number.isInteger(maxConcurrent) || maxConcurrent < 1 || maxConcurrent > 4) {
    throw new Error(`${id}: maxConcurrent must be integer 1...4`);
  }
  const workloadClass = requireString(raw.workloadClass, `${id}.workloadClass`);
  if (!ALLOWED_WORKLOADS.has(workloadClass)) {
    throw new Error(`${id}: unknown workloadClass ${workloadClass}`);
  }
  const allowedModes = requireUniqueStringArray(
    raw.allowedModes,
    `${id}.allowedModes`,
    ALLOWED_MODES,
  ).sort();
  if (raw.protectedSurfaceOk !== false || raw.highRiskLaneOk !== false) {
    throw new Error(`${id}: protected/high-risk preset flags must both be false`);
  }
  if (raw.v2Eligible !== true) {
    throw new Error(`${id}: canonical preset must be v2Eligible=true`);
  }
  if (
    raw.codexTomlExtras != null
    && (
      typeof raw.codexTomlExtras !== "object"
      || Array.isArray(raw.codexTomlExtras)
      || Object.keys(raw.codexTomlExtras).length !== 0
    )
  ) {
    throw new Error(`${id}: codexTomlExtras has no V1 whitelist entries`);
  }
  const allowedScenarios = raw.allowedScenarios == null
    ? []
    : Array.isArray(raw.allowedScenarios)
      ? raw.allowedScenarios.map((value, scenarioIndex) =>
        requireString(value, `${id}.allowedScenarios[${scenarioIndex}]`))
      : (() => { throw new Error(`${id}.allowedScenarios must be an array`); })();
  if (new Set(allowedScenarios).size !== allowedScenarios.length) {
    throw new Error(`${id}.allowedScenarios contains duplicates`);
  }
  return {
    id,
    displayName: requireString(raw.displayName, `${id}.displayName`),
    identityGroup,
    codexAgentName,
    description: requireString(raw.description, `${id}.description`),
    modelBinding,
    effort,
    maxConcurrent,
    workloadClass,
    allowedLanes: lanes,
    allowedModes,
    allowedScenarios: [...allowedScenarios].sort(),
    v2Eligible: true,
    protectedSurfaceOk: false,
    highRiskLaneOk: false,
    codexTomlExtras: {},
    revision: requireString(raw.revision, `${id}.revision`),
  };
}

function validateRegistry(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new Error("registry root must be an object");
  }
  assertNoUnknownKeys(raw, REGISTRY_KEYS, "registry");
  if (raw.schema !== "TatwoAgentPresetRegistryV1") {
    throw new Error(`unsupported schema: ${raw.schema}`);
  }
  if (raw.source !== "os_registry") {
    throw new Error("source must be os_registry");
  }
  const allowedModels = requireUniqueStringArray(
    raw.allowedGPTModels,
    "allowedGPTModels",
  ).sort();
  if (stableJSON(allowedModels) !== stableJSON([...ALLOWED_MODELS].sort())) {
    throw new Error(
      `allowedGPTModels must exactly equal ${[...ALLOWED_MODELS].sort().join(",")}`,
    );
  }
  if (!Array.isArray(raw.agentPresets)) {
    throw new Error("agentPresets must be an array");
  }
  const presets = raw.agentPresets.map(validatePreset);
  const ids = presets.map((preset) => preset.id);
  if (new Set(ids).size !== ids.length) {
    throw new Error("duplicate preset id");
  }
  if (stableJSON([...ids].sort()) !== stableJSON(REQUIRED_IDS)) {
    throw new Error(`canonical registry must contain exactly ${REQUIRED_IDS.join(",")}`);
  }
  if (new Set(presets.map((preset) => preset.codexAgentName)).size !== presets.length) {
    throw new Error("duplicate codexAgentName");
  }
  return {
    schema: "TatwoAgentPresetRegistryV1",
    source: "os_registry",
    registryRevision: requireString(raw.registryRevision, "registryRevision"),
    allowedGPTModels: allowedModels,
    agentPresets: presets.sort((a, b) => a.id.localeCompare(b.id)),
  };
}

function registryDigest(registry) {
  return sha256(stableJSON(registry));
}

function tomlString(value) {
  return JSON.stringify(String(value));
}

function renderPreset(preset, registry, digest) {
  const body = [
    `description = ${tomlString(preset.description)}`,
    `model = ${tomlString(preset.modelBinding)}`,
    `model_reasoning_effort = ${tomlString(preset.effort)}`,
    "",
  ].join("\n");
  const bodyDigest = sha256(body);
  return [
    "# schema: TatwoCodexAgentPresetV1",
    `# generated-from: TatwoAgentPresetRegistryV1 id=${preset.id}`,
    `# registry-revision: ${registry.registryRevision}`,
    `# preset-revision: ${preset.revision}`,
    `# registry-sha256: ${digest}`,
    `# renderer-version: ${RENDERER_VERSION}`,
    `# managed-body-sha256: ${bodyDigest}`,
    "# DO NOT HAND-EDIT as source of truth — edit OS registry, then re-project.",
    "",
    body,
  ].join("\n");
}

function parseManagedProvenance(text, expectedID) {
  const marker = "\n\n";
  const split = text.indexOf(marker);
  if (split < 0) return { state: "unmanaged", reason: "managed header separator missing" };
  const header = text.slice(0, split);
  const body = text.slice(split + marker.length);
  const fields = {};
  for (const line of header.split("\n")) {
    const match = /^# ([a-z0-9-]+): (.+)$/.exec(line);
    if (match) fields[match[1]] = match[2];
  }
  const generated = /^TatwoAgentPresetRegistryV1 id=(uw-[a-z0-9-]+)$/.exec(
    fields["generated-from"] || "",
  );
  if (fields.schema !== "TatwoCodexAgentPresetV1" || !generated) {
    return { state: "unmanaged", reason: "managed schema/id header missing" };
  }
  if (generated[1] !== expectedID) {
    return { state: "drift", reason: "managed id does not match target filename" };
  }
  if (!/^[0-9a-f]{64}$/.test(fields["registry-sha256"] || "")) {
    return { state: "drift", reason: "registry digest header invalid" };
  }
  if (!/^[0-9a-f]{64}$/.test(fields["managed-body-sha256"] || "")) {
    return { state: "drift", reason: "managed body digest header invalid" };
  }
  const actualBodyDigest = sha256(body);
  if (actualBodyDigest !== fields["managed-body-sha256"]) {
    return {
      state: "drift",
      reason: "managed body differs from controller-applied digest",
      expectedBodyDigest: fields["managed-body-sha256"],
      actualBodyDigest,
    };
  }
  return {
    state: "managed",
    id: generated[1],
    registryRevision: fields["registry-revision"] || null,
    presetRevision: fields["preset-revision"] || null,
    registryDigest: fields["registry-sha256"],
    rendererVersion: fields["renderer-version"] || null,
    bodyDigest: actualBodyDigest,
  };
}

function splitDiffLines(text) {
  const trailingNewline = text.endsWith("\n");
  const lines = text.split("\n");
  if (trailingNewline) lines.pop();
  return { lines, trailingNewline };
}

function exactUnifiedDiff(logicalPath, before, after) {
  if (before === after) return "";
  const oldFile = splitDiffLines(before);
  const newFile = splitDiffLines(after);
  const oldStart = oldFile.lines.length === 0 ? 0 : 1;
  const newStart = newFile.lines.length === 0 ? 0 : 1;
  const output = [
    `--- a/${logicalPath}`,
    `+++ b/${logicalPath}`,
    `@@ -${oldStart},${oldFile.lines.length} +${newStart},${newFile.lines.length} @@`,
  ];
  for (let index = 0; index < oldFile.lines.length; index += 1) {
    output.push(`-${oldFile.lines[index]}`);
    if (index === oldFile.lines.length - 1 && !oldFile.trailingNewline) {
      output.push("\\ No newline at end of file");
    }
  }
  for (let index = 0; index < newFile.lines.length; index += 1) {
    output.push(`+${newFile.lines[index]}`);
    if (index === newFile.lines.length - 1 && !newFile.trailingNewline) {
      output.push("\\ No newline at end of file");
    }
  }
  return `${output.join("\n")}\n`;
}

function fileState(path, id) {
  if (!assertDirectFileNotSymlink(path, `current preset ${id}`)) {
    return {
      exists: false,
      bytes: "",
      sha256: null,
      provenance: { state: "missing", reason: "target absent" },
    };
  }
  const bytes = readDirectFileNoFollow(path, `current preset ${id}`).toString("utf8");
  return {
    exists: true,
    bytes,
    sha256: sha256(bytes),
    provenance: parseManagedProvenance(bytes, id),
  };
}

function planDigest(plan) {
  const copy = { ...plan };
  delete copy.planDigest;
  return sha256(stableJSON(copy));
}

function receiptDigest(receipt) {
  const copy = { ...receipt };
  delete copy.receiptDigest;
  return sha256(stableJSON(copy));
}

function writeAtomically(path, content) {
  const parent = dirname(path);
  mkdirSync(parent, { recursive: true });
  const temporary = join(parent, `.${basename(path)}.tatwo-${randomUUID()}.tmp`);
  const descriptor = openSync(
    temporary,
    fsConstants.O_CREAT | fsConstants.O_EXCL | fsConstants.O_WRONLY,
    0o600,
  );
  try {
    writeFileSync(descriptor, content);
    fsyncSync(descriptor);
  } finally {
    closeSync(descriptor);
  }
  renameSync(temporary, path);
}

function replaceGeneratedDirectory(stagingRoot, files) {
  const finalRoot = canonicalPath(stagingRoot);
  assertUserConfigPolicy(finalRoot, { allow: false, label: "staging root" });
  const parent = dirname(finalRoot);
  mkdirSync(parent, { recursive: true });
  const temporary = join(parent, `.${basename(finalRoot)}.tatwo-new-${randomUUID()}`);
  const previous = join(parent, `.${basename(finalRoot)}.tatwo-previous-${randomUUID()}`);
  mkdirSync(temporary, { recursive: false });
  try {
    for (const [relativePath, content] of files) {
      const output = resolve(temporary, relativePath);
      if (!isWithin(output, temporary)) throw new Error(`staging path escape: ${relativePath}`);
      writeAtomically(output, content);
    }
    let movedPrevious = false;
    if (existsSync(finalRoot)) {
      assertDirectFileNotSymlink(finalRoot, "staging root");
      renameSync(finalRoot, previous);
      movedPrevious = true;
    }
    try {
      renameSync(temporary, finalRoot);
    } catch (error) {
      if (movedPrevious && !existsSync(finalRoot)) renameSync(previous, finalRoot);
      throw error;
    }
    if (movedPrevious) rmSync(previous, { recursive: true, force: false });
  } catch (error) {
    if (existsSync(temporary)) rmSync(temporary, { recursive: true, force: true });
    throw error;
  }
}

function buildPlan({
  registryPath,
  currentRoot,
  stagingRoot,
  goalHash,
  operationalPlanHash,
  allowUserConfig = false,
}) {
  const registry = validateRegistry(readJSON(registryPath));
  const digest = registryDigest(registry);
  const boundGoalHash = requireAuthorityHash(goalHash, "goalHash");
  const boundOperationalPlanHash = requireAuthorityHash(
    operationalPlanHash,
    "operationalPlanHash",
  );
  const observedRoot = canonicalPath(currentRoot);
  const stagedRoot = canonicalPath(stagingRoot);
  assertUserConfigPolicy(observedRoot, {
    allow: allowUserConfig,
    label: "current root",
  });
  assertUserConfigPolicy(stagedRoot, { allow: false, label: "staging root" });
  if (isWithin(stagedRoot, observedRoot) || isWithin(observedRoot, stagedRoot)) {
    throw new Error("current root and staging root must be disjoint");
  }

  const renderedFiles = [];
  const items = registry.agentPresets.map((preset) => {
    const targetRelativePath = `${preset.codexAgentName}.toml`;
    const targetPath = resolve(observedRoot, targetRelativePath);
    if (!isWithin(targetPath, observedRoot)) {
      throw new Error(`${preset.id}: target path escape`);
    }
    const desired = renderPreset(preset, registry, digest);
    const current = fileState(targetPath, preset.id);
    let action;
    let reason;
    if (!current.exists) {
      action = "create";
      reason = "target missing";
    } else if (current.bytes === desired) {
      action = "noop";
      reason = "target byte-identical to registry projection";
    } else if (current.provenance.state === "managed") {
      action = "update";
      reason = "prior controller-managed target differs from current registry projection";
    } else {
      action = "conflict";
      reason = `manual/unowned drift: ${current.provenance.reason}; reverse adoption is forbidden`;
    }
    renderedFiles.push([join("agents", targetRelativePath), desired]);
    return {
      id: preset.id,
      codexAgentName: preset.codexAgentName,
      targetRelativePath,
      stagedRelativePath: join("agents", targetRelativePath),
      action,
      reason,
      currentExists: current.exists,
      currentSHA256: current.sha256,
      desiredSHA256: sha256(desired),
      observedProvenance: current.provenance,
      unifiedDiff: exactUnifiedDiff(targetRelativePath, current.bytes, desired),
    };
  });
  const plan = {
    schema: "TatwoCodexAgentPresetStagedPlanV2",
    goalHash: boundGoalHash,
    operationalPlanHash: boundOperationalPlanHash,
    registrySchema: registry.schema,
    registryRevision: registry.registryRevision,
    registryDigest: digest,
    rendererVersion: RENDERER_VERSION,
    currentRoot: observedRoot,
    stagingRoot: stagedRoot,
    requiresHumanGate: true,
    reverseAdoptionAllowed: false,
    liveApplyPerformed: false,
    items,
  };
  plan.planDigest = planDigest(plan);
  renderedFiles.push(["plan.json", prettyJSON(plan)]);
  replaceGeneratedDirectory(stagedRoot, renderedFiles);
  return plan;
}

function validatePlan(plan) {
  if (plan.schema !== "TatwoCodexAgentPresetStagedPlanV2") {
    throw new Error(`unsupported plan schema: ${plan.schema}`);
  }
  requireAuthorityHash(plan.goalHash, "plan.goalHash");
  requireAuthorityHash(
    plan.operationalPlanHash,
    "plan.operationalPlanHash",
  );
  if (plan.registrySchema !== "TatwoAgentPresetRegistryV1") {
    throw new Error(`unsupported registry schema in plan: ${plan.registrySchema}`);
  }
  if (plan.rendererVersion !== RENDERER_VERSION) {
    throw new Error(`unsupported renderer version: ${plan.rendererVersion}`);
  }
  if (!/^[0-9a-f]{64}$/.test(plan.registryDigest || "")) {
    throw new Error("plan registryDigest must be sha256");
  }
  if (plan.planDigest !== planDigest(plan)) {
    throw new Error("plan digest mismatch");
  }
  if (
    plan.requiresHumanGate !== true
    || plan.reverseAdoptionAllowed !== false
    || plan.liveApplyPerformed !== false
  ) {
    throw new Error("plan safety flags invalid");
  }
  canonicalPath(plan.currentRoot);
  canonicalPath(plan.stagingRoot);
  if (!Array.isArray(plan.items) || plan.items.length !== REQUIRED_IDS.length) {
    throw new Error("plan must contain exactly five items");
  }
  const ids = plan.items.map((item) => item.id).sort();
  if (stableJSON(ids) !== stableJSON(REQUIRED_IDS)) {
    throw new Error("plan preset ids mismatch");
  }
  const actions = new Set(["create", "update", "noop", "conflict"]);
  for (const item of plan.items) {
    if (item.codexAgentName !== item.id) {
      throw new Error(`${item.id}: plan codexAgentName mismatch`);
    }
    if (item.targetRelativePath !== `${item.id}.toml`) {
      throw new Error(`${item.id}: plan targetRelativePath mismatch`);
    }
    if (item.stagedRelativePath !== join("agents", `${item.id}.toml`)) {
      throw new Error(`${item.id}: plan stagedRelativePath mismatch`);
    }
    if (!actions.has(item.action)) {
      throw new Error(`${item.id}: plan action invalid`);
    }
    if (!/^[0-9a-f]{64}$/.test(item.desiredSHA256 || "")) {
      throw new Error(`${item.id}: desiredSHA256 invalid`);
    }
    if (
      item.currentSHA256 != null
      && !/^[0-9a-f]{64}$/.test(item.currentSHA256)
    ) {
      throw new Error(`${item.id}: currentSHA256 invalid`);
    }
    if (item.currentExists !== (item.currentSHA256 != null)) {
      throw new Error(`${item.id}: current existence/hash mismatch`);
    }
    if (item.action === "noop" && item.unifiedDiff !== "") {
      throw new Error(`${item.id}: noop item must have empty diff`);
    }
    if (item.action !== "noop" && !String(item.unifiedDiff || "").startsWith("--- a/")) {
      throw new Error(`${item.id}: mutating/conflict item must carry exact unified diff`);
    }
  }
  return plan;
}

function validateApplyReceipt(receipt) {
  if (receipt.schema !== "TatwoCodexAgentPresetApplyReceiptV1") {
    throw new Error(`unsupported rollback receipt schema: ${receipt.schema}`);
  }
  if (receipt.status !== "applied") {
    throw new Error(`rollback requires applied receipt, got ${receipt.status}`);
  }
  if (!/^[0-9a-f]{64}$/.test(receipt.receiptDigest || "")) {
    throw new Error("apply receipt digest missing or invalid");
  }
  if (receipt.receiptDigest !== receiptDigest(receipt)) {
    throw new Error("apply receipt digest mismatch");
  }
  if (!Array.isArray(receipt.items) || receipt.items.length === 0) {
    throw new Error("applied receipt items must be non-empty");
  }
  requireAuthorityHash(receipt.goalHash, "apply receipt goalHash");
  requireAuthorityHash(
    receipt.operationalPlanHash,
    "apply receipt operationalPlanHash",
  );
  return receipt;
}

function validateAuthorization(authorization, plan, targetRoot, backupRoot) {
  if (!authorization || typeof authorization !== "object" || Array.isArray(authorization)) {
    throw new Error("authorization must be an object");
  }
  assertNoUnknownKeys(authorization, AUTHORIZATION_KEYS, "authorization");
  if (authorization.schema !== "TatwoCodexAgentPresetApplyAuthorizationV2") {
    throw new Error(`unsupported authorization schema: ${authorization.schema}`);
  }
  if (authorization.approvedGoalHash !== plan.goalHash) {
    throw new Error("authorization approvedGoalHash mismatch");
  }
  if (authorization.approvedOperationalPlanHash !== plan.operationalPlanHash) {
    throw new Error("authorization approvedOperationalPlanHash mismatch");
  }
  if (authorization.approvedPlanDigest !== plan.planDigest) {
    throw new Error("authorization approvedPlanDigest mismatch");
  }
  if (authorization.approvedRegistryDigest !== plan.registryDigest) {
    throw new Error("authorization approvedRegistryDigest mismatch");
  }
  if (canonicalPath(authorization.approvedTargetRoot) !== targetRoot) {
    throw new Error("authorization approvedTargetRoot mismatch");
  }
  if (canonicalPath(authorization.approvedBackupRoot) !== backupRoot) {
    throw new Error("authorization approvedBackupRoot mismatch");
  }
  const expectedFiles = plan.items
    .filter((item) => item.action === "create" || item.action === "update")
    .map((item) => item.targetRelativePath)
    .sort();
  if (!Array.isArray(authorization.approvedFiles)) {
    throw new Error("authorization.approvedFiles must be an array");
  }
  const approvedFiles = authorization.approvedFiles.map((value, index) =>
    requireString(value, `authorization.approvedFiles[${index}]`)).sort();
  if (new Set(approvedFiles).size !== approvedFiles.length) {
    throw new Error("authorization.approvedFiles contains duplicates");
  }
  if (stableJSON(approvedFiles) !== stableJSON(expectedFiles)) {
    throw new Error("authorization approvedFiles must exactly match plan mutations");
  }
  requireString(authorization.approver, "authorization.approver");
  const approvedAt = requireString(authorization.approvedAt, "authorization.approvedAt");
  const expiresAt = requireString(authorization.expiresAt, "authorization.expiresAt");
  const approvedAtMs = Date.parse(approvedAt);
  const expiresAtMs = Date.parse(expiresAt);
  if (Number.isNaN(approvedAtMs)) {
    throw new Error("authorization.approvedAt must be ISO-8601");
  }
  if (Number.isNaN(expiresAtMs)) {
    throw new Error("authorization.expiresAt must be ISO-8601");
  }
  if (expiresAtMs <= approvedAtMs) {
    throw new Error("authorization expiresAt must be after approvedAt");
  }
  if (expiresAtMs - approvedAtMs > AUTHORIZATION_MAX_TTL_MS) {
    throw new Error("authorization TTL exceeds 15 minutes");
  }
  const now = Date.now();
  if (approvedAtMs > now + AUTHORIZATION_MAX_FUTURE_SKEW_MS) {
    throw new Error("authorization approvedAt is too far in the future");
  }
  if (expiresAtMs <= now) {
    throw new Error("authorization expired");
  }
  return authorization;
}

function timestampToken() {
  return new Date().toISOString().replace(/[-:.]/g, "");
}

function reserveTransactionRoot(backupRoot, prefix) {
  mkdirSync(backupRoot, { recursive: true });
  for (let attempt = 0; attempt < 64; attempt += 1) {
    const suffix = attempt === 0 ? "" : `-${attempt}`;
    const candidate = join(
      backupRoot,
      `${prefix}-${timestampToken()}-${randomUUID()}${suffix}`,
    );
    try {
      mkdirSync(candidate, { recursive: false, mode: 0o700 });
      return candidate;
    } catch (error) {
      if (error?.code === "EEXIST") continue;
      throw error;
    }
  }
  throw new Error("could not reserve unique transaction root");
}

function currentHashOrNull(path) {
  return assertDirectFileNotSymlink(path, `hash source ${path}`)
    ? sha256(readDirectFileNoFollow(path, `hash source ${path}`))
    : null;
}

function testFailureAfter(targetRoot, variable) {
  const configured = process.env[variable];
  if (configured == null) return null;
  if (process.env.TATWO_AGENT_PRESET_TEST_MODE !== "1") {
    throw new Error("test failure injection requires TATWO_AGENT_PRESET_TEST_MODE=1");
  }
  const safeRoots = [
    canonicalPath(tmpdir()),
    canonicalPath("/tmp/tatwo2-fixture/runtime/test-tmp/agent-preset-tests"),
  ];
  if (!safeRoots.some((root) => isWithin(targetRoot, root))) {
    throw new Error("test failure injection target is outside approved disposable roots");
  }
  const value = Number(configured);
  if (!Number.isInteger(value) || value < 0) {
    throw new Error(`${variable} must be a nonnegative integer`);
  }
  return value;
}

function restoreBeforeState(items, failureAfter = null) {
  let restoredCount = 0;
  for (const item of items) {
    if (failureAfter != null && restoredCount >= failureAfter) {
      throw new Error(`injected automatic restore failure after ${restoredCount} restores`);
    }
    if (item.beforeExists) {
      writeAtomically(
        item.targetPath,
        readDirectFileNoFollow(item.backupPath, `automatic rollback backup ${item.id}`),
      );
    } else if (existsSync(item.targetPath)) {
      rmSync(item.targetPath, { force: false });
    }
    restoredCount += 1;
  }
  for (const item of items) {
    const actual = currentHashOrNull(item.targetPath);
    if (actual !== item.beforeSHA256) {
      throw new Error(`automatic rollback readback mismatch for ${item.id}`);
    }
  }
}

function applyPlan({
  plan,
  targetRoot,
  backupRoot,
  authorization,
  allowUserConfig = false,
}) {
  validatePlan(plan);
  const target = canonicalPath(targetRoot);
  const backup = canonicalPath(backupRoot);
  assertUserConfigPolicy(target, { allow: allowUserConfig, label: "target root" });
  assertBackupOutsideUserConfig(backup);
  if (target !== canonicalPath(plan.currentRoot)) {
    throw new Error("target root does not match plan currentRoot");
  }
  if (isWithin(backup, target) || isWithin(target, backup)) {
    throw new Error("target root and backup root must be disjoint");
  }
  const conflicts = plan.items.filter((item) => item.action === "conflict");
  if (conflicts.length) {
    throw new Error(
      `apply rejected: plan contains conflict ${conflicts.map((item) => item.id).join(",")}`,
    );
  }
  validateAuthorization(authorization, plan, target, backup);
  const mutations = plan.items.filter(
    (item) => item.action === "create" || item.action === "update",
  );
  if (mutations.length === 0) {
    const noopReceipt = {
      schema: "TatwoCodexAgentPresetApplyReceiptV1",
      status: "noop",
      goalHash: plan.goalHash,
      operationalPlanHash: plan.operationalPlanHash,
      planDigest: plan.planDigest,
      registryDigest: plan.registryDigest,
      targetRoot: target,
      backupRoot: backup,
      transactionRoot: null,
      approver: authorization.approver,
      authorizationApprovedAt: authorization.approvedAt,
      authorizationExpiresAt: authorization.expiresAt,
      appliedAt: new Date().toISOString(),
      items: [],
      readback: "PASS",
    };
    noopReceipt.receiptDigest = receiptDigest(noopReceipt);
    return noopReceipt;
  }
  const staging = canonicalPath(plan.stagingRoot);
  assertUserConfigPolicy(staging, { allow: false, label: "staging root" });
  const prepared = mutations.map((item) => {
    const stagedPath = resolve(staging, item.stagedRelativePath);
    const targetPath = resolve(target, item.targetRelativePath);
    if (!isWithin(stagedPath, staging) || !isWithin(targetPath, target)) {
      throw new Error(`${item.id}: path escape in plan`);
    }
    assertDirectFileNotSymlink(stagedPath, `staged preset ${item.id}`);
    assertDirectFileNotSymlink(targetPath, `target preset ${item.id}`);
    if (!existsSync(stagedPath)) throw new Error(`${item.id}: staged file missing`);
    const stagedBytes = readDirectFileNoFollow(
      stagedPath,
      `staged preset ${item.id}`,
    );
    if (sha256(stagedBytes) !== item.desiredSHA256) {
      throw new Error(`${item.id}: staged hash mismatch`);
    }
    const actualBefore = currentHashOrNull(targetPath);
    if (actualBefore !== item.currentSHA256) {
      throw new Error(`${item.id}: stale plan; target changed after diff`);
    }
    return {
      ...item,
      stagedPath,
      targetPath,
      stagedBytes,
      beforeExists: item.currentSHA256 != null,
      beforeSHA256: item.currentSHA256,
      backupPath: null,
    };
  });
  const failureAfter = testFailureAfter(
    target,
    "TATWO_AGENT_PRESET_TEST_FAIL_AFTER_WRITES",
  );
  const automaticRestoreFailureAfter = testFailureAfter(
    target,
    "TATWO_AGENT_PRESET_TEST_FAIL_AUTOMATIC_RESTORE_AFTER",
  );
  const transactionRoot = reserveTransactionRoot(backup, "agent-preset-apply");
  const beforeRoot = join(transactionRoot, "before");
  mkdirSync(beforeRoot, { recursive: false });
  for (const item of prepared) {
    if (!item.beforeExists) continue;
    item.backupPath = join(beforeRoot, item.targetRelativePath);
    mkdirSync(dirname(item.backupPath), { recursive: true });
    const beforeBytes = readDirectFileNoFollow(
      item.targetPath,
      `backup source ${item.id}`,
    );
    if (sha256(beforeBytes) !== item.beforeSHA256) {
      throw new Error(`${item.id}: target changed before backup`);
    }
    writeExclusiveArchive(item.backupPath, beforeBytes, `backup archive ${item.id}`);
    if (
      sha256(readDirectFileNoFollow(item.backupPath, `backup readback ${item.id}`))
      !== item.beforeSHA256
    ) {
      throw new Error(`${item.id}: backup readback mismatch`);
    }
  }
  let writeCount = 0;
  try {
    mkdirSync(target, { recursive: true });
    for (const item of prepared) {
      if (failureAfter != null && writeCount >= failureAfter) {
        throw new Error(`injected failure after ${writeCount} writes`);
      }
      writeAtomically(item.targetPath, item.stagedBytes);
      writeCount += 1;
    }
    for (const item of prepared) {
      if (currentHashOrNull(item.targetPath) !== item.desiredSHA256) {
        throw new Error(`${item.id}: apply readback mismatch`);
      }
    }
  } catch (error) {
    let rollbackReadback = "BEFORE_STATE_RESTORED";
    let rollbackError = null;
    try {
      restoreBeforeState(prepared, automaticRestoreFailureAfter);
    } catch (restoreError) {
      rollbackReadback = "ROLLBACK_FAILED";
      rollbackError = String(restoreError?.message || restoreError);
    }
    const failed = {
      schema: "TatwoCodexAgentPresetApplyFailureReceiptV1",
      status: rollbackError
        ? "apply_failed_rollback_failed"
        : "apply_failed_rolled_back",
      goalHash: plan.goalHash,
      operationalPlanHash: plan.operationalPlanHash,
      planDigest: plan.planDigest,
      registryDigest: plan.registryDigest,
      targetRoot: target,
      backupRoot: backup,
      transactionRoot,
      approver: authorization.approver,
      authorizationApprovedAt: authorization.approvedAt,
      authorizationExpiresAt: authorization.expiresAt,
      failedAfterWrites: writeCount,
      error: String(error?.message || error),
      rollbackError,
      readback: rollbackReadback,
    };
    failed.receiptDigest = receiptDigest(failed);
    writeAtomically(join(transactionRoot, "failure-receipt.json"), prettyJSON(failed));
    const thrown = new Error(
      rollbackError
        ? `apply failed and automatic rollback also failed: ${error?.message || error}; ${rollbackError}`
        : `apply failed and restored before state: ${error?.message || error}`,
    );
    thrown.receipt = failed;
    throw thrown;
  }
  const receipt = {
    schema: "TatwoCodexAgentPresetApplyReceiptV1",
    status: "applied",
    goalHash: plan.goalHash,
    operationalPlanHash: plan.operationalPlanHash,
    planDigest: plan.planDigest,
    registryDigest: plan.registryDigest,
    registryRevision: plan.registryRevision,
    rendererVersion: plan.rendererVersion,
    targetRoot: target,
    backupRoot: backup,
    transactionRoot,
    approver: authorization.approver,
    authorizationApprovedAt: authorization.approvedAt,
    authorizationExpiresAt: authorization.expiresAt,
    appliedAt: new Date().toISOString(),
    liveUserConfig: isWithin(
      target,
      canonicalPath(join(process.env.HOME || homedir(), ".codex")),
    ),
    items: prepared.map((item) => ({
      id: item.id,
      targetRelativePath: item.targetRelativePath,
      targetPath: item.targetPath,
      action: item.action,
      beforeExists: item.beforeExists,
      beforeSHA256: item.beforeSHA256,
      afterSHA256: item.desiredSHA256,
      backupPath: item.backupPath,
    })),
    readback: "PASS",
  };
  receipt.receiptDigest = receiptDigest(receipt);
  writeAtomically(join(transactionRoot, "apply-receipt.json"), prettyJSON(receipt));
  return receipt;
}

function rollbackApplyReceipt({ receipt, allowUserConfig = false }) {
  validateApplyReceipt(receipt);
  const targetRoot = canonicalPath(receipt.targetRoot);
  const backupRoot = canonicalPath(receipt.backupRoot);
  assertUserConfigPolicy(targetRoot, {
    allow: allowUserConfig,
    label: "rollback target root",
  });
  assertBackupOutsideUserConfig(backupRoot);
  const items = receipt.items.map((item) => {
    const targetPath = resolve(targetRoot, item.targetRelativePath);
    if (resolve(item.targetPath) !== targetPath) {
      throw new Error(`${item.id}: rollback receipt target path mismatch`);
    }
    if (!isWithin(targetPath, targetRoot)) {
      throw new Error(`${item.id}: rollback target path escape`);
    }
    assertDirectFileNotSymlink(targetPath, `rollback target ${item.id}`);
    if (currentHashOrNull(targetPath) !== item.afterSHA256) {
      throw new Error(`${item.id}: rollback refused because target drifted after apply`);
    }
    let beforeBytes = null;
    if (item.beforeExists) {
      if (!item.backupPath || !existsSync(item.backupPath)) {
        throw new Error(`${item.id}: rollback backup missing`);
      }
      assertDirectFileNotSymlink(item.backupPath, `rollback backup ${item.id}`);
      beforeBytes = readDirectFileNoFollow(
        item.backupPath,
        `rollback backup ${item.id}`,
      );
      if (sha256(beforeBytes) !== item.beforeSHA256) {
        throw new Error(`${item.id}: rollback backup hash mismatch`);
      }
    }
    return { ...item, targetPath, beforeBytes };
  });
  const rollbackRoot = reserveTransactionRoot(backupRoot, "agent-preset-rollback");
  const afterRoot = join(rollbackRoot, "after");
  mkdirSync(afterRoot, { recursive: false });
  for (const item of items) {
    const safetyPath = join(afterRoot, item.targetRelativePath);
    mkdirSync(dirname(safetyPath), { recursive: true });
    const afterBytes = readDirectFileNoFollow(
      item.targetPath,
      `rollback safety source ${item.id}`,
    );
    if (sha256(afterBytes) !== item.afterSHA256) {
      throw new Error(`${item.id}: rollback target changed before safety backup`);
    }
    writeExclusiveArchive(safetyPath, afterBytes, `rollback safety archive ${item.id}`);
    if (
      sha256(readDirectFileNoFollow(safetyPath, `rollback safety readback ${item.id}`))
      !== item.afterSHA256
    ) {
      throw new Error(`${item.id}: rollback safety backup mismatch`);
    }
    item.rollbackSafetyPath = safetyPath;
  }
  const rollbackFailureAfter = testFailureAfter(
    targetRoot,
    "TATWO_AGENT_PRESET_TEST_FAIL_ROLLBACK_AFTER_RESTORES",
  );
  const rollbackRecoveryFailureAfter = testFailureAfter(
    targetRoot,
    "TATWO_AGENT_PRESET_TEST_FAIL_ROLLBACK_RECOVERY_AFTER_WRITES",
  );
  let restoredCount = 0;
  try {
    for (const item of items) {
      if (rollbackFailureAfter != null && restoredCount >= rollbackFailureAfter) {
        throw new Error(`injected rollback failure after ${restoredCount} restores`);
      }
      if (item.beforeExists) {
        writeAtomically(item.targetPath, item.beforeBytes);
      } else {
        rmSync(item.targetPath, { force: false });
      }
      restoredCount += 1;
    }
    for (const item of items) {
      if (currentHashOrNull(item.targetPath) !== item.beforeSHA256) {
        throw new Error(`${item.id}: rollback readback mismatch`);
      }
    }
  } catch (error) {
    let recoveredCount = 0;
    let recoveryError = null;
    try {
      for (const item of items) {
        if (
          rollbackRecoveryFailureAfter != null
          && recoveredCount >= rollbackRecoveryFailureAfter
        ) {
          throw new Error(
            `injected rollback recovery failure after ${recoveredCount} writes`,
          );
        }
        writeAtomically(
          item.targetPath,
          readDirectFileNoFollow(
            item.rollbackSafetyPath,
            `rollback recovery archive ${item.id}`,
          ),
        );
        recoveredCount += 1;
      }
      for (const item of items) {
        if (currentHashOrNull(item.targetPath) !== item.afterSHA256) {
          throw new Error(`${item.id}: rollback recovery readback mismatch`);
        }
      }
    } catch (recoveryFailure) {
      recoveryError = String(recoveryFailure?.message || recoveryFailure);
    }
    const failed = {
      schema: "TatwoCodexAgentPresetRollbackFailureReceiptV1",
      status: recoveryError
        ? "rollback_failed_recovery_failed"
        : "rollback_failed_after_state_recovered",
      goalHash: receipt.goalHash,
      operationalPlanHash: receipt.operationalPlanHash,
      sourceApplyTransactionRoot: receipt.transactionRoot,
      sourceApplyReceiptDigest: receipt.receiptDigest,
      sourcePlanDigest: receipt.planDigest,
      sourceRegistryDigest: receipt.registryDigest,
      targetRoot,
      backupRoot,
      rollbackRoot,
      restoredCount,
      recoveredCount,
      error: String(error?.message || error),
      recoveryError,
      readback: recoveryError ? "RECOVERY_FAILED" : "AFTER_STATE_RECOVERED",
    };
    failed.receiptDigest = receiptDigest(failed);
    writeAtomically(
      join(rollbackRoot, "rollback-failure-receipt.json"),
      prettyJSON(failed),
    );
    const thrown = new Error(
      recoveryError
        ? `rollback failed after ${restoredCount} restores and after-state recovery failed: ${error?.message || error}; ${recoveryError}`
        : `rollback failed after ${restoredCount} restores; after-state recovered: ${error?.message || error}`,
    );
    thrown.receipt = failed;
    throw thrown;
  }
  const rollbackReceipt = {
    schema: "TatwoCodexAgentPresetRollbackReceiptV1",
    status: "rolled_back",
    goalHash: receipt.goalHash,
    operationalPlanHash: receipt.operationalPlanHash,
    sourceApplyTransactionRoot: receipt.transactionRoot,
    sourceApplyReceiptDigest: receipt.receiptDigest,
    sourcePlanDigest: receipt.planDigest,
    sourceRegistryDigest: receipt.registryDigest,
    targetRoot,
    backupRoot,
    rollbackRoot,
    rolledBackAt: new Date().toISOString(),
    items: items.map((item) => ({
      id: item.id,
      targetPath: item.targetPath,
      restoredSHA256: item.beforeSHA256,
      targetRemoved: !item.beforeExists,
      reversibleAfterStateArchive: item.rollbackSafetyPath,
    })),
    readback: "PASS",
  };
  rollbackReceipt.receiptDigest = receiptDigest(rollbackReceipt);
  writeAtomically(
    join(rollbackRoot, "rollback-receipt.json"),
    prettyJSON(rollbackReceipt),
  );
  return rollbackReceipt;
}

function writeOptionalReceipt(path, value) {
  if (!path) return;
  const target = canonicalPath(path);
  assertUserConfigPolicy(target, { allow: false, label: "receipt output" });
  writeAtomically(target, prettyJSON(value));
}

function print(value) {
  process.stdout.write(prettyJSON(value));
}

function selftest() {
  const registry = validateRegistry(readJSON(DEFAULT_REGISTRY));
  const digest = registryDigest(registry);
  const rendered = registry.agentPresets.map((preset) =>
    renderPreset(preset, registry, digest));
  if (new Set(rendered.map(sha256)).size !== REQUIRED_IDS.length) {
    throw new Error("rendered presets are unexpectedly non-unique");
  }
  return {
    schema: "TatwoCodexAgentPresetControllerSelftestV1",
    status: "PASS",
    registryRevision: registry.registryRevision,
    registryDigest: digest,
    presetCount: rendered.length,
    liveApplyPerformed: false,
  };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.selftest) {
    print(selftest());
    return;
  }
  if (options.command === "validate") {
    const registryPath = options.registry || DEFAULT_REGISTRY;
    const registry = validateRegistry(readJSON(registryPath));
    print({
      schema: "TatwoAgentPresetRegistryValidationReceiptV1",
      status: "PASS",
      registryRevision: registry.registryRevision,
      registryDigest: registryDigest(registry),
      presetCount: registry.agentPresets.length,
      presetIDs: registry.agentPresets.map((preset) => preset.id),
      modelBindings: Object.fromEntries(
        registry.agentPresets.map((preset) => [preset.id, {
          model: preset.modelBinding,
          effort: preset.effort,
        }]),
      ),
    });
    return;
  }
  if (options.command === "plan") {
    if (
      !options.registry
      || !options.currentRoot
      || !options.stagingRoot
      || !options.goalHash
      || !options.operationalPlanHash
    ) {
      usage(
        "plan requires --registry, --current-root, --staging-root, --goal-hash, and --operational-plan-hash",
      );
      process.exit(2);
    }
    print(buildPlan({
      registryPath: options.registry,
      currentRoot: options.currentRoot,
      stagingRoot: options.stagingRoot,
      goalHash: options.goalHash,
      operationalPlanHash: options.operationalPlanHash,
      allowUserConfig: options.acknowledgeUserConfig,
    }));
    return;
  }
  if (options.command === "apply") {
    if (
      !options.plan
      || !options.targetRoot
      || !options.backupRoot
      || !options.authorization
    ) {
      usage("apply requires --plan, --target-root, --backup-root, and --authorization");
      process.exit(2);
    }
    const receipt = applyPlan({
      plan: readJSON(options.plan),
      targetRoot: options.targetRoot,
      backupRoot: options.backupRoot,
      authorization: readJSON(options.authorization),
      allowUserConfig: options.acknowledgeUserConfig,
    });
    writeOptionalReceipt(options.receiptOut, receipt);
    print(receipt);
    return;
  }
  if (options.command === "rollback") {
    if (!options.receipt) {
      usage("rollback requires --receipt");
      process.exit(2);
    }
    const receipt = rollbackApplyReceipt({
      receipt: readJSON(options.receipt),
      allowUserConfig: options.acknowledgeUserConfig,
    });
    writeOptionalReceipt(options.receiptOut, receipt);
    print(receipt);
    return;
  }
  usage("missing or unknown command");
  process.exit(2);
}

main().catch((error) => {
  if (error?.receipt) {
    console.error(prettyJSON(error.receipt).trimEnd());
  }
  die(error?.message || String(error));
});
