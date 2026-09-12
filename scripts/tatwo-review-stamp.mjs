#!/usr/bin/env node

import { createHash } from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { isAbsolute, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SCHEMA_V1 = "TatwoReviewRevisionStampV1";
const SCHEMA_V2 = "TatwoReviewRevisionStampV2";
const DEPTHS = new Set(["read-only", "build", "full-test", "adversarial"]);
const BINDING_CLASSES = new Set(["revision-bound", "base-provenance-only"]);
const SCRIPT_PATH = resolve(fileURLToPath(import.meta.url));
const ARTIFACT_UNBOUND_WARNING =
  "artifact-unbound stamp＝base provenance only";

function usage(message) {
  if (message) console.error(`Error: ${message}`);
  console.error(
    "Usage: node scripts/tatwo-review-stamp.mjs --effort <text> --depth <read-only|build|full-test|adversarial> [--artifacts <path,...>]",
  );
  console.error("       node scripts/tatwo-review-stamp.mjs --selftest");
}

function git(args, cwd) {
  return execFileSync("git", args, {
    cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

function findRepoRoot() {
  return git(["rev-parse", "--show-toplevel"], process.cwd());
}

function sha256Hex(bufferOrString) {
  return createHash("sha256").update(bufferOrString).digest("hex");
}

function branchLabel(branchName, commit) {
  return branchName || `detached@${commit.slice(0, 12)}`;
}

/**
 * Parse `git status --porcelain` (v1) into a sorted unique path list.
 * Renames contribute both source and destination paths.
 */
function parsePorcelainPaths(statusText) {
  const paths = new Set();
  for (const rawLine of statusText.split("\n")) {
    if (!rawLine) continue;
    // Format: XY<space>path  or  XY<space>old -> new  (paths may be quoted)
    if (rawLine.length < 4) continue;
    const body = rawLine.slice(3);
    const arrow = " -> ";
    const arrowIndex = body.indexOf(arrow);
    if (arrowIndex !== -1) {
      const from = unquotePorcelainPath(body.slice(0, arrowIndex));
      const to = unquotePorcelainPath(body.slice(arrowIndex + arrow.length));
      if (from) paths.add(from);
      if (to) paths.add(to);
      continue;
    }
    const path = unquotePorcelainPath(body);
    if (path) paths.add(path);
  }
  return [...paths].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
}

function unquotePorcelainPath(value) {
  let path = value;
  if (path.startsWith('"') && path.endsWith('"')) {
    path = path
      .slice(1, -1)
      .replace(/\\([n"\\t])/g, (_, ch) => {
        if (ch === "n") return "\n";
        if (ch === "t") return "\t";
        return ch;
      });
  }
  return path;
}

function dirtyPathsDigestOf(dirtyPaths) {
  return sha256Hex(dirtyPaths.join("\n"));
}

function resolveArtifactPath(repoRoot, inputPath) {
  const absolute = isAbsolute(inputPath) ? resolve(inputPath) : resolve(repoRoot, inputPath);
  const rel = relative(repoRoot, absolute);
  if (rel.startsWith("..") || isAbsolute(rel)) {
    throw new Error(`artifact path escapes repo root: ${inputPath}`);
  }
  return { absolute, path: rel.split("\\").join("/") };
}

function hashArtifacts(repoRoot, artifactInputs) {
  const reviewed = [];
  for (const input of artifactInputs) {
    const trimmed = input.trim();
    if (!trimmed) continue;
    const { absolute, path } = resolveArtifactPath(repoRoot, trimmed);
    let bytes;
    try {
      bytes = readFileSync(absolute);
    } catch (error) {
      throw new Error(`cannot read artifact ${path}: ${error.message}`);
    }
    reviewed.push({ path, sha256: sha256Hex(bytes) });
  }
  reviewed.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  return reviewed;
}

function decideBindingClass({ gitStatusPorcelainClean, reviewedArtifacts }) {
  if (gitStatusPorcelainClean || reviewedArtifacts.length > 0) {
    return "revision-bound";
  }
  return "base-provenance-only";
}

function makeStamp({ repoRoot, effort, depth, artifactInputs }) {
  const commit = git(["rev-parse", "HEAD"], repoRoot);
  const tree = git(["rev-parse", "HEAD^{tree}"], repoRoot);
  const branchName = git(["branch", "--show-current"], repoRoot);
  const branch = branchLabel(branchName, commit);
  const status = execFileSync("git", ["status", "--porcelain"], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  const dirtyPaths = parsePorcelainPaths(status);
  const gitStatusPorcelainClean = dirtyPaths.length === 0;
  const dirtyPathsDigest = dirtyPathsDigestOf(dirtyPaths);
  const reviewedArtifacts = hashArtifacts(repoRoot, artifactInputs);
  const bindingClass = decideBindingClass({
    gitStatusPorcelainClean,
    reviewedArtifacts,
  });

  return {
    schema: SCHEMA_V2,
    commit,
    tree,
    branch,
    // V1 field retained for compatible readers; same boolean as porcelain clean.
    worktreeClean: gitStatusPorcelainClean,
    gitStatusPorcelainClean,
    dirtyPaths,
    dirtyPathsDigest,
    reviewedArtifacts,
    bindingClass,
    effort,
    verificationDepth: depth,
    generatedAt: new Date().toISOString(),
  };
}

function assertStampV1Shape(stamp) {
  const required = [
    "schema",
    "commit",
    "tree",
    "branch",
    "worktreeClean",
    "effort",
    "verificationDepth",
    "generatedAt",
  ];
  for (const field of required) {
    if (!(field in stamp)) throw new Error(`missing V1 field: ${field}`);
  }
  if (stamp.schema !== SCHEMA_V1 && stamp.schema !== SCHEMA_V2) {
    throw new Error("schema mismatch");
  }
  for (const field of ["commit", "tree", "branch", "effort", "verificationDepth", "generatedAt"]) {
    if (typeof stamp[field] !== "string" || stamp[field].trim() === "") {
      throw new Error(`empty field: ${field}`);
    }
  }
  if (typeof stamp.worktreeClean !== "boolean") throw new Error("worktreeClean must be boolean");
  if (!DEPTHS.has(stamp.verificationDepth)) throw new Error("invalid verificationDepth");
}

function assertStamp(stamp) {
  assertStampV1Shape(stamp);
  if (stamp.schema !== SCHEMA_V2) throw new Error(`expected ${SCHEMA_V2}`);
  const v2Fields = [
    "gitStatusPorcelainClean",
    "dirtyPaths",
    "dirtyPathsDigest",
    "reviewedArtifacts",
    "bindingClass",
  ];
  for (const field of v2Fields) {
    if (!(field in stamp)) throw new Error(`missing V2 field: ${field}`);
  }
  if (typeof stamp.gitStatusPorcelainClean !== "boolean") {
    throw new Error("gitStatusPorcelainClean must be boolean");
  }
  if (stamp.worktreeClean !== stamp.gitStatusPorcelainClean) {
    throw new Error("worktreeClean must equal gitStatusPorcelainClean");
  }
  if (!Array.isArray(stamp.dirtyPaths)) throw new Error("dirtyPaths must be array");
  for (const path of stamp.dirtyPaths) {
    if (typeof path !== "string" || path.trim() === "") throw new Error("dirtyPaths entry invalid");
  }
  if (typeof stamp.dirtyPathsDigest !== "string" || !/^[0-9a-f]{64}$/.test(stamp.dirtyPathsDigest)) {
    throw new Error("dirtyPathsDigest must be 64-char lowercase hex");
  }
  if (stamp.dirtyPathsDigest !== dirtyPathsDigestOf(stamp.dirtyPaths)) {
    throw new Error("dirtyPathsDigest does not match dirtyPaths");
  }
  if (stamp.gitStatusPorcelainClean !== (stamp.dirtyPaths.length === 0)) {
    throw new Error("gitStatusPorcelainClean disagrees with dirtyPaths");
  }
  if (!Array.isArray(stamp.reviewedArtifacts)) throw new Error("reviewedArtifacts must be array");
  for (const item of stamp.reviewedArtifacts) {
    if (!item || typeof item !== "object") throw new Error("reviewedArtifacts entry invalid");
    if (typeof item.path !== "string" || item.path.trim() === "") {
      throw new Error("reviewedArtifacts.path invalid");
    }
    if (typeof item.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(item.sha256)) {
      throw new Error("reviewedArtifacts.sha256 invalid");
    }
  }
  if (!BINDING_CLASSES.has(stamp.bindingClass)) throw new Error("invalid bindingClass");
  const expectedClass = decideBindingClass({
    gitStatusPorcelainClean: stamp.gitStatusPorcelainClean,
    reviewedArtifacts: stamp.reviewedArtifacts,
  });
  if (stamp.bindingClass !== expectedClass) {
    throw new Error(`bindingClass expected ${expectedClass}, got ${stamp.bindingClass}`);
  }
  if (!stamp.branch || (stamp.branch.startsWith("detached@") && stamp.branch.length < "detached@".length + 7)) {
    throw new Error("branch label invalid for attached or detached HEAD");
  }
}

function parseArtifactsList(raw) {
  if (raw === undefined || raw === null || raw.trim() === "") return [];
  return raw
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean);
}

function parseArgs(argv) {
  let effort;
  let depth;
  let artifactsRaw;
  let selftest = false;

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--selftest") {
      selftest = true;
      continue;
    }
    if (arg === "--effort" || arg === "--depth" || arg === "--artifacts") {
      const value = argv[index + 1];
      if (!value || value.startsWith("--")) throw new Error(`${arg} requires a value`);
      if (arg === "--effort") effort = value;
      else if (arg === "--depth") depth = value;
      else artifactsRaw = value;
      index += 1;
      continue;
    }
    if (arg.startsWith("--effort=")) {
      effort = arg.slice("--effort=".length);
      continue;
    }
    if (arg.startsWith("--depth=")) {
      depth = arg.slice("--depth=".length);
      continue;
    }
    if (arg.startsWith("--artifacts=")) {
      artifactsRaw = arg.slice("--artifacts=".length);
      continue;
    }
    throw new Error(`unknown argument: ${arg}`);
  }

  return {
    effort,
    depth,
    artifactInputs: parseArtifactsList(artifactsRaw),
    artifactsProvided: artifactsRaw !== undefined,
    selftest,
  };
}

function extractJsonLine(stdout) {
  const lines = stdout
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
  // Prefer the last JSON object line so a leading warning on stdout is tolerated.
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const line = lines[index];
    if (line.startsWith("{") && line.endsWith("}")) {
      return line;
    }
  }
  throw new Error("no JSON stamp line in stdout");
}

function runChildStamp(repoRoot, extraArgs) {
  const child = spawnSync(
    process.execPath,
    [SCRIPT_PATH, ...extraArgs],
    {
      cwd: repoRoot,
      encoding: "utf8",
    },
  );
  if (child.status !== 0) {
    throw new Error(
      `selftest child failed: ${(child.stderr || "").trim() || `exit ${child.status}`}`,
    );
  }
  let stamp;
  try {
    stamp = JSON.parse(extractJsonLine(child.stdout));
  } catch (error) {
    throw new Error(`selftest output was not JSON: ${error.message}`);
  }
  return { stamp, stdout: child.stdout, stderr: child.stderr || "" };
}

function runSelftest(repoRoot) {
  // 1) Detached HEAD label tolerance (pure unit check; no git write).
  const fakeCommit = "0123456789abcdef0123456789abcdef01234567";
  const detached = branchLabel("", fakeCommit);
  if (detached !== `detached@${fakeCommit.slice(0, 12)}`) {
    throw new Error(`detached branch label wrong: ${detached}`);
  }
  if (branchLabel("feat/example", fakeCommit) !== "feat/example") {
    throw new Error("attached branch label must pass through");
  }

  // 2) Dirty path parsing + digest unit checks.
  const sampleStatus = [
    " M scripts/a.mjs",
    "?? docs/protocol/x.md",
    "R  old-name.md -> new-name.md",
  ].join("\n");
  const parsed = parsePorcelainPaths(sampleStatus);
  const expectedPaths = ["docs/protocol/x.md", "new-name.md", "old-name.md", "scripts/a.mjs"].sort();
  if (JSON.stringify(parsed) !== JSON.stringify(expectedPaths)) {
    throw new Error(`parsePorcelainPaths mismatch: ${JSON.stringify(parsed)}`);
  }
  if (dirtyPathsDigestOf(parsed) !== sha256Hex(parsed.join("\n"))) {
    throw new Error("dirtyPathsDigest helper mismatch");
  }
  if (dirtyPathsDigestOf([]) !== sha256Hex("")) {
    throw new Error("empty dirtyPathsDigest must be sha256 of empty string");
  }

  // 3) Unbound stamp (no --artifacts): V1-compatible fields + V2 disclosure.
  const unbound = runChildStamp(repoRoot, ["--effort", "selftest", "--depth", "read-only"]);
  assertStamp(unbound.stamp);
  assertStampV1Shape(unbound.stamp);
  if (!Array.isArray(unbound.stamp.reviewedArtifacts) || unbound.stamp.reviewedArtifacts.length !== 0) {
    throw new Error("unbound stamp must have empty reviewedArtifacts");
  }
  const combinedUnboundOut = `${unbound.stdout}\n${unbound.stderr}`;
  if (!combinedUnboundOut.includes(ARTIFACT_UNBOUND_WARNING)) {
    throw new Error("missing artifact-unbound warning on unbound stamp");
  }
  if (unbound.stamp.gitStatusPorcelainClean) {
    if (unbound.stamp.bindingClass !== "revision-bound") {
      throw new Error("clean tree without artifacts must still be revision-bound");
    }
    if (unbound.stamp.dirtyPaths.length !== 0) {
      throw new Error("clean tree must have empty dirtyPaths");
    }
  } else {
    if (unbound.stamp.bindingClass !== "base-provenance-only") {
      throw new Error("dirty unbound stamp must be base-provenance-only");
    }
    if (unbound.stamp.dirtyPaths.length === 0) {
      throw new Error("dirty stamp must disclose dirtyPaths");
    }
  }

  // 4) Artifacts binding: digest correctness + revision-bound class.
  const artifactRel = relative(repoRoot, SCRIPT_PATH).split("\\").join("/");
  const bound = runChildStamp(repoRoot, [
    "--effort",
    "selftest-artifacts",
    "--depth",
    "read-only",
    "--artifacts",
    artifactRel,
  ]);
  assertStamp(bound.stamp);
  if (bound.stamp.bindingClass !== "revision-bound") {
    throw new Error("stamp with artifacts must be revision-bound");
  }
  if (bound.stamp.reviewedArtifacts.length !== 1) {
    throw new Error("expected one reviewed artifact");
  }
  if (bound.stamp.reviewedArtifacts[0].path !== artifactRel) {
    throw new Error(`artifact path mismatch: ${bound.stamp.reviewedArtifacts[0].path}`);
  }
  const expectedSha = sha256Hex(readFileSync(SCRIPT_PATH));
  if (bound.stamp.reviewedArtifacts[0].sha256 !== expectedSha) {
    throw new Error("artifact sha256 mismatch");
  }
  if (`${bound.stdout}\n${bound.stderr}`.includes(ARTIFACT_UNBOUND_WARNING)) {
    throw new Error("bound stamp must not emit artifact-unbound warning");
  }

  // 5) Live dirtyPathsDigest matches disclosed paths.
  if (bound.stamp.dirtyPathsDigest !== dirtyPathsDigestOf(bound.stamp.dirtyPaths)) {
    throw new Error("live dirtyPathsDigest mismatch");
  }

  console.log("SELFTEST PASS");
}

function emitStamp(stamp, { artifactUnbound }) {
  const json = JSON.stringify(stamp);
  console.log(json);
  if (artifactUnbound) {
    // Warning on stdout after JSON so humans see it; parsers take the JSON object line.
    console.log(ARTIFACT_UNBOUND_WARNING);
  }
}

function main() {
  const { effort, depth, artifactInputs, selftest } = parseArgs(process.argv.slice(2));
  const repoRoot = findRepoRoot();

  if (selftest) {
    runSelftest(repoRoot);
    return;
  }
  if (!effort || effort.trim() === "") throw new Error("--effort is required");
  if (!depth || !DEPTHS.has(depth)) {
    throw new Error("--depth is required and must be one of read-only|build|full-test|adversarial");
  }

  const stamp = makeStamp({ repoRoot, effort, depth, artifactInputs });
  emitStamp(stamp, { artifactUnbound: stamp.reviewedArtifacts.length === 0 });
}

try {
  main();
} catch (error) {
  usage(error.message);
  process.exitCode = 1;
}
