#!/usr/bin/env node

import crypto from "node:crypto";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import zlib from "node:zlib";

class ProvenanceError extends Error {}

function fail(message, details = "") {
  throw new ProvenanceError(details ? `${message}\n${details}` : message);
}

function stable(value) {
  if (Array.isArray(value)) return value.map(stable);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, stable(value[key])]),
    );
  }
  return value;
}

function canonicalJSON(value) {
  return `${JSON.stringify(stable(value))}\n`;
}

function sha256(data) {
  return crypto.createHash("sha256").update(data).digest("hex");
}

function fileSHA256(filePath) {
  return sha256(fs.readFileSync(filePath));
}

function writeCanonicalFile(filePath, value) {
  const body = canonicalJSON(value);
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, body, { flag: "wx", mode: 0o600 });
  return sha256(body);
}

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const values = new Map();
  for (let index = 0; index < rest.length; index += 2) {
    const key = rest[index];
    const value = rest[index + 1];
    if (!key?.startsWith("--") || value === undefined) {
      fail(`invalid arguments for ${command ?? "missing command"}`);
    }
    const list = values.get(key) ?? [];
    list.push(value);
    values.set(key, list);
  }
  return {
    command,
    one(key, required = true) {
      const list = values.get(key) ?? [];
      if (list.length > 1) fail(`argument may appear once: ${key}`);
      if (required && list.length === 0) fail(`missing argument: ${key}`);
      return list[0] ?? "";
    },
    many(key) {
      return values.get(key) ?? [];
    },
  };
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    env: options.env,
    input: options.input,
    encoding: options.encoding === undefined ? "utf8" : options.encoding,
    // 2026-08-23：native-runtime 系譜 source archive 已達 269MB，256MB 上限
    // 讓 spawnSync 靜默殺子程序（status null）——提到 1GB。
    maxBuffer: 1024 * 1024 * 1024,
  });
  if (result.status !== 0) {
    const stdout = Buffer.isBuffer(result.stdout)
      ? result.stdout.toString("utf8")
      : (result.stdout ?? "");
    const stderr = Buffer.isBuffer(result.stderr)
      ? result.stderr.toString("utf8")
      : (result.stderr ?? "");
    fail(
      `${command} ${args.join(" ")} failed with status ${result.status}`,
      `${stdout}${stderr}`.trim(),
    );
  }
  return result.stdout;
}

function git(repo, args, options = {}) {
  return run("git", ["-C", repo, ...args], options);
}

function normalizeRelative(relative) {
  if (
    path.isAbsolute(relative)
    || relative.split(/[\\/]/u).some((component) => component === "..")
  ) {
    fail(`path escapes manifest root: ${relative}`);
  }
  const normalized = path.normalize(relative);
  return normalized === "." ? "." : normalized.split(path.sep).join("/");
}

function assertWithin(parent, child, allowSame = false) {
  const relative = path.relative(path.resolve(parent), path.resolve(child));
  if (
    (!allowSame && relative === "")
    || relative === ".."
    || relative.startsWith(`..${path.sep}`)
    || path.isAbsolute(relative)
  ) {
    fail(`path escapes owned root: ${child}`);
  }
}

function temporaryBase() {
  const configured = process.env.TATWO_PROVENANCE_TMPDIR;
  const base = path.resolve(configured || os.tmpdir());
  fs.mkdirSync(base, { recursive: true });
  return fs.realpathSync(base);
}

function makeOwnedTemp(prefix) {
  return fs.mkdtempSync(path.join(temporaryBase(), prefix));
}

function cleanupOwnedTemp(tempRoot) {
  const base = temporaryBase();
  const resolved = fs.realpathSync(tempRoot);
  assertWithin(base, resolved);
  if (!path.basename(resolved).startsWith("tatwo-provenance-")) {
    fail(`refusing to clean non-provenance temporary path: ${resolved}`);
  }
  fs.rmSync(resolved, { recursive: true });
}

function realIndexState(repo) {
  const indexPath = String(
    git(repo, ["rev-parse", "--path-format=absolute", "--git-path", "index"]),
  ).trim();
  if (!fs.existsSync(indexPath)) return { exists: false, sha256: null };
  return { exists: true, sha256: fileSHA256(indexPath) };
}

function assertRealIndexUnchanged(before, after) {
  if (before.exists !== after.exists || before.sha256 !== after.sha256) {
    fail("real Git index bytes changed while calculating provenance");
  }
}

function createPrivateTree(repo, commit) {
  const realIndexBefore = realIndexState(repo);
  const tempRoot = makeOwnedTemp("tatwo-provenance-source-");
  const indexPath = path.join(tempRoot, "index");
  const objectPath = path.join(tempRoot, "objects");
  fs.mkdirSync(objectPath);
  const repositoryObjects = String(
    git(repo, ["rev-parse", "--path-format=absolute", "--git-path", "objects"]),
  ).trim();
  const env = {
    ...process.env,
    GIT_INDEX_FILE: indexPath,
    GIT_OBJECT_DIRECTORY: objectPath,
    GIT_ALTERNATE_OBJECT_DIRECTORIES: repositoryObjects,
  };
  git(repo, ["read-tree", commit], { env });
  git(repo, ["add", "-A", "--", "."], { env });
  const tree = String(git(repo, ["write-tree"], { env })).trim();
  const objectFormat = String(
    git(repo, ["rev-parse", "--show-object-format"]),
  ).trim();
  assertRealIndexUnchanged(realIndexBefore, realIndexState(repo));
  return { env, objectFormat, realIndexBefore, tempRoot, tree };
}

function parseTreeEntries(raw) {
  return raw
    .toString("utf8")
    .split("\0")
    .filter(Boolean)
    .map((record) => {
      const tab = record.indexOf("\t");
      if (tab === -1) fail("invalid git ls-tree record");
      const [mode, type, oid] = record.slice(0, tab).split(" ");
      return { mode, oid, path: record.slice(tab + 1), type };
    });
}

function parseDeclaredInputPaths(packageText, repo) {
  const targetPaths = [
    ...packageText.matchAll(/\bpath\s*:\s*"([^"]+)"/gu),
  ].map((match) => normalizeRelative(match[1]));
  const resourcePaths = [
    ...packageText.matchAll(/\.(?:copy|process)\(\s*"([^"]+)"/gu),
  ].map((match) => match[1]);
  const declared = new Set(targetPaths);
  for (const resource of resourcePaths) {
    const candidates = [...new Set([
      path.resolve(repo, resource),
      ...targetPaths.map((target) => path.resolve(repo, target, resource)),
    ])];
    const existing = candidates.filter((candidate) => fs.existsSync(candidate));
    if (existing.length !== 1) {
      fail(
        `resource path must resolve to exactly one declared input: ${resource}`,
        existing.join("\n"),
      );
    }
    declared.add(normalizeRelative(path.relative(repo, existing[0])));
  }
  return [...declared].sort((left, right) =>
    Buffer.from(left).compare(Buffer.from(right))
  );
}

function walkRelativePaths(root, requestedPaths) {
  const paths = [];
  const visit = (absolute) => {
    paths.push(normalizeRelative(path.relative(root, absolute)));
    const stat = fs.lstatSync(absolute);
    if (stat.isDirectory() && !stat.isSymbolicLink()) {
      for (const name of fs.readdirSync(absolute).sort()) {
        visit(path.join(absolute, name));
      }
    }
  };
  for (const requested of requestedPaths) {
    const absolute = path.resolve(root, requested);
    assertWithin(root, absolute, requested === ".");
    if (!fs.existsSync(absolute)) fail(`declared build input is missing: ${absolute}`);
    visit(absolute);
  }
  return paths;
}

function ignoredDeclaredInputs(repo, packagePath) {
  const declaredPaths = parseDeclaredInputPaths(
    fs.readFileSync(packagePath, "utf8"),
    repo,
  );
  const candidates = walkRelativePaths(repo, declaredPaths);
  if (candidates.length === 0) return [];
  const ignoreResult = spawnSync(
    "git",
    ["-C", repo, "check-ignore", "-z", "--stdin"],
    {
      input: `${candidates.join("\0")}\0`,
      encoding: null,
      maxBuffer: 1024 * 1024 * 64,
    },
  );
  if (![0, 1].includes(ignoreResult.status)) {
    fail("git check-ignore failed for declared build inputs");
  }
  return ignoreResult.status === 0
    ? ignoreResult.stdout.toString("utf8").split("\0").filter(Boolean)
    : [];
}

function assertNoIgnoredDeclaredInputs(repo) {
  const packagePath = path.join(repo, "Package.swift");
  if (!fs.existsSync(packagePath)) fail(`Package.swift is missing: ${packagePath}`);
  const ignored = ignoredDeclaredInputs(repo, packagePath);
  if (ignored.length > 0) {
    fail(
      "ignored/generated files exist under Package.swift target/resource inputs",
      ignored.join("\n"),
    );
  }
}

function lfsAndSubmoduleState(repo, entries, privateEnv) {
  const gitlinks = entries.filter(
    (entry) => entry.mode === "160000" || entry.type === "commit",
  );
  if (gitlinks.length > 0) {
    fail(
      "submodules are not supported by the local Candidate source payload",
      gitlinks.map((entry) => entry.path).join("\n"),
    );
  }
  const lfsAttributeFiles = entries.filter(
    (entry) => path.basename(entry.path) === ".gitattributes",
  );
  for (const entry of lfsAttributeFiles) {
    const contents = String(
      git(repo, ["show", `${entry.oid}`], { env: privateEnv }),
    );
    if (/(?:^|\s)filter=lfs(?:\s|$)/mu.test(contents)) {
      fail(`Git LFS attributes are not supported by the local Candidate payload: ${entry.path}`);
    }
  }
  for (const entry of entries) {
    if (entry.type !== "blob") continue;
    const size = Number(
      String(git(repo, ["cat-file", "-s", entry.oid], { env: privateEnv })).trim(),
    );
    if (size > 1024) continue;
    const contents = String(git(repo, ["cat-file", "-p", entry.oid], {
      env: privateEnv,
    }));
    if (contents.startsWith("version https://git-lfs.github.com/spec/v1\n")) {
      fail(`unresolved Git LFS pointer in Candidate source: ${entry.path}`);
    }
  }
  return { lfsPointers: [], submodules: [] };
}

function sourceState(args) {
  const repo = path.resolve(args.one("--repo"));
  const commit = args.one("--commit");
  assertNoIgnoredDeclaredInputs(repo);
  const privateTree = createPrivateTree(repo, commit);
  try {
    const headTree = String(
      git(repo, ["rev-parse", "--verify", `${commit}^{tree}`]),
    ).trim();
    const currentCommit = String(git(repo, ["rev-parse", "--verify", "HEAD"])).trim();
    if (currentCommit !== commit) fail("HEAD changed while source state was captured");
    assertRealIndexUnchanged(privateTree.realIndexBefore, realIndexState(repo));
    process.stdout.write(canonicalJSON({
      realIndexSHA256: privateTree.realIndexBefore.sha256,
      schema: "TatwoSourceStateV1",
      sourceCommit: commit,
      sourceDirty: privateTree.tree !== headTree,
      sourceTree: privateTree.tree,
    }));
  } finally {
    cleanupOwnedTemp(privateTree.tempRoot);
  }
}

function safeArchivePath(extractRoot, entryPath) {
  const normalized = normalizeRelative(entryPath);
  const resolved = path.resolve(extractRoot, normalized);
  assertWithin(extractRoot, resolved);
  return resolved;
}

function validateArchiveListing(archivePath) {
  const listing = String(run("tar", ["-tzf", archivePath]));
  for (const entry of listing.split("\n").filter(Boolean)) {
    normalizeRelative(entry.replace(/\/$/u, ""));
  }
}

function writeLooseBlobObject(repo, objectFormat, content) {
  if (!["sha1", "sha256"].includes(objectFormat)) {
    fail(`unsupported Git object format: ${objectFormat}`);
  }
  const header = Buffer.from(`blob ${content.length}\0`, "utf8");
  const objectBytes = Buffer.concat([header, content]);
  const oid = crypto.createHash(objectFormat).update(objectBytes).digest("hex");
  const objectPath = path.join(
    repo,
    ".git",
    "objects",
    oid.slice(0, 2),
    oid.slice(2),
  );
  if (!fs.existsSync(objectPath)) {
    fs.mkdirSync(path.dirname(objectPath), { recursive: true });
    try {
      fs.writeFileSync(objectPath, zlib.deflateSync(objectBytes), {
        flag: "wx",
        mode: 0o444,
      });
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
    }
  }
  return oid;
}

function verifyExtractedTree(extractRoot, manifest, expectedTree) {
  const rebuildRepo = makeOwnedTemp("tatwo-provenance-rebuild-");
  try {
    const initArgs = ["init", "-q"];
    if (manifest.objectFormat === "sha256") initArgs.push("--object-format=sha256");
    run("git", initArgs, { cwd: rebuildRepo });
    const indexRecords = [];
    for (const entry of manifest.entries) {
      if (entry.type !== "blob") {
        fail(`unsupported source archive entry type: ${entry.type}`);
      }
      const extractedPath = safeArchivePath(extractRoot, entry.path);
      if (!fs.existsSync(extractedPath)) {
        fail(`source archive entry is missing: ${entry.path}`);
      }
      let content;
      if (entry.mode === "120000") {
        if (!fs.lstatSync(extractedPath).isSymbolicLink()) {
          fail(`expected source symlink: ${entry.path}`);
        }
        content = Buffer.from(fs.readlinkSync(extractedPath), "utf8");
      } else {
        if (!fs.lstatSync(extractedPath).isFile()) {
          fail(`expected source file: ${entry.path}`);
        }
        content = fs.readFileSync(extractedPath);
      }
      const oid = writeLooseBlobObject(
        rebuildRepo,
        manifest.objectFormat,
        content,
      );
      if (oid !== entry.oid) {
        fail(`archive blob differs from tree manifest: ${entry.path}`);
      }
      indexRecords.push(`${entry.mode} ${oid}\t${entry.path}\0`);
    }
    run("git", ["update-index", "-z", "--index-info"], {
      cwd: rebuildRepo,
      input: indexRecords.join(""),
    });
    const rebuiltTree = String(run("git", ["write-tree"], {
      cwd: rebuildRepo,
    })).trim();
    if (rebuiltTree !== expectedTree) {
      fail(
        "durable source archive does not reconstruct the expected tree",
        `expected=${expectedTree}\nactual=${rebuiltTree}`,
      );
    }
    return rebuiltTree;
  } finally {
    cleanupOwnedTemp(rebuildRepo);
  }
}

function verifyArchiveToTemporaryExtraction(archivePath, manifest, expectedTree) {
  validateArchiveListing(archivePath);
  const tempRoot = makeOwnedTemp("tatwo-provenance-verify-");
  const extractRoot = path.join(tempRoot, "extracted");
  fs.mkdirSync(extractRoot);
  try {
    run("tar", ["-xzf", archivePath, "-C", extractRoot]);
    return verifyExtractedTree(extractRoot, manifest, expectedTree);
  } finally {
    cleanupOwnedTemp(tempRoot);
  }
}

function sourceSnapshot(args) {
  const repo = path.resolve(args.one("--repo"));
  const commit = args.one("--commit");
  const outputDir = path.resolve(args.one("--output-dir"));
  if (fs.existsSync(outputDir)) fail(`source payload already exists: ${outputDir}`);
  fs.mkdirSync(outputDir, { recursive: false, mode: 0o700 });
  assertNoIgnoredDeclaredInputs(repo);

  const privateTree = createPrivateTree(repo, commit);
  try {
    const headTree = String(
      git(repo, ["rev-parse", "--verify", `${commit}^{tree}`]),
    ).trim();
    const currentCommit = String(git(repo, ["rev-parse", "--verify", "HEAD"])).trim();
    if (currentCommit !== commit) fail("HEAD changed while source payload was captured");
    const entries = parseTreeEntries(
      git(repo, ["ls-tree", "-r", "-z", "--full-tree", privateTree.tree], {
        env: privateTree.env,
        encoding: null,
      }),
    );
    const repositoryState = lfsAndSubmoduleState(
      repo,
      entries,
      privateTree.env,
    );
    const treeManifestPath = path.join(outputDir, "source-tree-manifest.json");
    const treeManifestSHA256 = writeCanonicalFile(treeManifestPath, {
      entries,
      objectFormat: privateTree.objectFormat,
      schema: "TatwoSourceTreeManifestV1",
      sourceTree: privateTree.tree,
    });
    const archiveTar = git(
      repo,
      ["archive", "--format=tar", "--mtime=@0", privateTree.tree],
      { env: privateTree.env, encoding: null },
    );
    const archiveGzip = run("gzip", ["-n", "-9"], {
      input: archiveTar,
      encoding: "buffer",
    });
    const archivePath = path.join(outputDir, "source.tar.gz");
    fs.writeFileSync(archivePath, archiveGzip, { flag: "wx", mode: 0o600 });
    const archiveSHA256 = fileSHA256(archivePath);
    const rebuiltTree = verifyArchiveToTemporaryExtraction(
      archivePath,
      JSON.parse(fs.readFileSync(treeManifestPath, "utf8")),
      privateTree.tree,
    );
    const snapshot = {
      archive: path.basename(archivePath),
      archiveSHA256,
      lfsPointers: repositoryState.lfsPointers,
      objectFormat: privateTree.objectFormat,
      realIndexSHA256: privateTree.realIndexBefore.sha256,
      reconstructedTree: rebuiltTree,
      schema: "TatwoDurableSourceSnapshotV1",
      sourceCommit: commit,
      sourceDirty: privateTree.tree !== headTree,
      sourceTree: privateTree.tree,
      submodules: repositoryState.submodules,
      treeManifest: path.basename(treeManifestPath),
      treeManifestSHA256,
    };
    const snapshotPath = path.join(outputDir, "source-snapshot.json");
    const snapshotSHA256 = writeCanonicalFile(snapshotPath, snapshot);
    assertRealIndexUnchanged(privateTree.realIndexBefore, realIndexState(repo));
    process.stdout.write(canonicalJSON({
      ...snapshot,
      archivePath,
      snapshotPath,
      snapshotSHA256,
      treeManifestPath,
    }));
  } finally {
    cleanupOwnedTemp(privateTree.tempRoot);
  }
}

function readAndBindSnapshot(args) {
  const archivePath = path.resolve(args.one("--archive"));
  const manifestPath = path.resolve(args.one("--manifest"));
  const snapshotArgument = args.one("--snapshot", false);
  const snapshotPath = snapshotArgument ? path.resolve(snapshotArgument) : "";
  const expectedTree = args.one("--expected-tree");
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  if (
    manifest.schema !== "TatwoSourceTreeManifestV1"
    || manifest.sourceTree !== expectedTree
  ) {
    fail("source archive manifest does not bind the expected source tree");
  }
  if (snapshotPath) {
    const snapshot = JSON.parse(fs.readFileSync(snapshotPath, "utf8"));
    if (
      snapshot.schema !== "TatwoDurableSourceSnapshotV1"
      || snapshot.sourceTree !== expectedTree
      || snapshot.archiveSHA256 !== fileSHA256(archivePath)
      || snapshot.treeManifestSHA256 !== fileSHA256(manifestPath)
    ) {
      fail("source snapshot payload digest binding failed");
    }
  }
  return { archivePath, expectedTree, manifest, manifestPath };
}

function verifySourceArchive(args) {
  const bound = readAndBindSnapshot(args);
  const rebuiltTree = verifyArchiveToTemporaryExtraction(
    bound.archivePath,
    bound.manifest,
    bound.expectedTree,
  );
  process.stdout.write(canonicalJSON({
    archiveSHA256: fileSHA256(bound.archivePath),
    rebuiltTree,
    schema: "TatwoSourceArchiveVerificationV1",
    treeManifestSHA256: fileSHA256(bound.manifestPath),
    verified: true,
  }));
}

function extractSourceArchive(args) {
  const bound = readAndBindSnapshot(args);
  const destination = path.resolve(args.one("--destination"));
  if (fs.existsSync(destination)) {
    fail(`clean source workspace already exists: ${destination}`);
  }
  fs.mkdirSync(destination, { recursive: true, mode: 0o700 });
  validateArchiveListing(bound.archivePath);
  try {
    run("tar", ["-xzf", bound.archivePath, "-C", destination]);
    const rebuiltTree = verifyExtractedTree(
      destination,
      bound.manifest,
      bound.expectedTree,
    );
    if (fs.existsSync(path.join(destination, ".git"))) {
      fail("extracted source workspace unexpectedly contains .git");
    }
    process.stdout.write(canonicalJSON({
      destination,
      rebuiltTree,
      schema: "TatwoCleanSourceWorkspaceV1",
      verified: true,
    }));
  } catch (error) {
    fs.rmSync(destination, { recursive: true, force: true });
    throw error;
  }
}

function collectFilesystemEntries(root, requestedPaths, excludeGit) {
  const entries = new Map();
  const visit = (absolutePath) => {
    const stat = fs.lstatSync(absolutePath);
    const relativeRaw = path.relative(root, absolutePath);
    const relative = normalizeRelative(relativeRaw || ".");
    if (relative === ".") {
      if (!stat.isDirectory()) fail(`manifest root is not a directory: ${root}`);
    } else if (excludeGit && relative.split("/").includes(".git")) {
      return;
    } else if (stat.isSymbolicLink()) {
      const target = fs.readlinkSync(absolutePath);
      entries.set(relative, {
        mode: "120000",
        path: relative,
        sha256: sha256(Buffer.from(target, "utf8")),
        type: "symlink",
      });
      return;
    } else if (stat.isFile()) {
      entries.set(relative, {
        mode: (stat.mode & 0o111) === 0 ? "100644" : "100755",
        path: relative,
        sha256: fileSHA256(absolutePath),
        size: stat.size,
        type: "file",
      });
      return;
    } else if (!stat.isDirectory()) {
      fail(`unsupported filesystem manifest entry: ${absolutePath}`);
    }
    for (const name of fs.readdirSync(absolutePath).sort()) {
      visit(path.join(absolutePath, name));
    }
  };

  for (const requestedRaw of requestedPaths) {
    const requested = normalizeRelative(requestedRaw);
    const absolute = path.resolve(root, requested);
    assertWithin(root, absolute, requested === ".");
    if (!fs.existsSync(absolute)) fail(`manifest input is missing: ${absolute}`);
    visit(absolute);
  }
  return [...entries.values()].sort((left, right) =>
    Buffer.from(left.path).compare(Buffer.from(right.path))
  );
}

function createFilesystemManifest(root, requested, excludeGit) {
  const paths = [...new Set(requested.map(normalizeRelative))].sort((left, right) =>
    Buffer.from(left).compare(Buffer.from(right))
  );
  return {
    entries: collectFilesystemEntries(root, paths, excludeGit),
    excludeGit,
    paths,
    schema: "TatwoFilesystemManifestV2",
  };
}

function filesystemManifest(args) {
  const root = path.resolve(args.one("--root"));
  const output = path.resolve(args.one("--output"));
  const requested = args.many("--path");
  if (requested.length === 0) fail("filesystem manifest requires --path");
  const manifest = createFilesystemManifest(
    root,
    requested,
    args.one("--exclude-git", false) === "1",
  );
  const manifestSHA256 = writeCanonicalFile(output, manifest);
  process.stdout.write(canonicalJSON({
    entryCount: manifest.entries.length,
    manifestPath: output,
    manifestSHA256,
  }));
}

function verifyFilesystemManifest(args) {
  const root = path.resolve(args.one("--root"));
  const manifestPath = path.resolve(args.one("--manifest"));
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  if (manifest.schema !== "TatwoFilesystemManifestV2") {
    fail("unsupported filesystem manifest schema");
  }
  const actual = createFilesystemManifest(
    root,
    manifest.paths,
    manifest.excludeGit === true,
  );
  const expectedDigest = sha256(canonicalJSON(manifest));
  const actualDigest = sha256(canonicalJSON(actual));
  if (actualDigest !== expectedDigest) {
    fail(
      "filesystem manifest drift detected",
      `expected=${expectedDigest}\nactual=${actualDigest}`,
    );
  }
  process.stdout.write(canonicalJSON({
    manifestSHA256: expectedDigest,
    schema: "TatwoFilesystemManifestVerificationV1",
    verified: true,
  }));
}

function declaredInputs(args) {
  const repo = path.resolve(args.one("--repo"));
  const packagePath = path.resolve(args.one("--package"));
  const output = path.resolve(args.one("--output"));
  const extras = args.many("--extra").map(normalizeRelative);
  const declaredPaths = [
    ...new Set([
      ...parseDeclaredInputPaths(fs.readFileSync(packagePath, "utf8"), repo),
      ...extras,
    ]),
  ].sort((left, right) => Buffer.from(left).compare(Buffer.from(right)));
  if (fs.existsSync(path.join(repo, ".git"))) {
    const ignored = ignoredDeclaredInputs(repo, packagePath);
    if (ignored.length > 0) {
      fail(
        "ignored/generated files exist under Package.swift target/resource inputs",
        ignored.join("\n"),
      );
    }
  }
  const manifest = {
    declaredPaths,
    entries: collectFilesystemEntries(repo, declaredPaths, true),
    schema: "TatwoDeclaredBuildInputsV2",
  };
  const manifestSHA256 = writeCanonicalFile(output, manifest);
  process.stdout.write(canonicalJSON({
    declaredPathCount: declaredPaths.length,
    entryCount: manifest.entries.length,
    manifestPath: output,
    manifestSHA256,
  }));
}

function dependencyStateObject(resolvedPath, checkoutsPath) {
  const resolved = JSON.parse(fs.readFileSync(resolvedPath, "utf8"));
  const checkoutDirectories = fs.existsSync(checkoutsPath)
    ? fs.readdirSync(checkoutsPath, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
    : [];
  const normalizeIdentity = (value) =>
    value.toLowerCase().replace(/[^a-z0-9]/gu, "");
  const dependencies = [];
  for (const pin of [...(resolved.pins ?? [])].sort((left, right) =>
    String(left.identity).localeCompare(String(right.identity))
  )) {
    const matches = checkoutDirectories.filter(
      (name) => normalizeIdentity(name) === normalizeIdentity(pin.identity),
    );
    if (matches.length !== 1) {
      fail(`resolved dependency checkout is missing or ambiguous: ${pin.identity}`);
    }
    const checkout = path.join(checkoutsPath, matches[0]);
    const revision = String(git(checkout, ["rev-parse", "HEAD"])).trim();
    const tree = String(git(checkout, ["rev-parse", "HEAD^{tree}"])).trim();
    const status = String(
      git(checkout, ["status", "--porcelain=v1", "--untracked-files=all"]),
    );
    if (status.trim()) {
      fail(`dependency checkout is dirty: ${checkout}`, status.trim());
    }
    if (revision !== pin.state?.revision) {
      fail(
        `dependency revision differs from Package.resolved: ${pin.identity}`,
        `expected=${pin.state?.revision}\nactual=${revision}`,
      );
    }
    const entries = collectFilesystemEntries(checkout, ["."], true);
    dependencies.push({
      checkout: matches[0],
      checkoutManifestSHA256: sha256(canonicalJSON({
        entries,
        schema: "TatwoDependencyCheckoutManifestV1",
      })),
      identity: pin.identity,
      location: pin.location,
      revision,
      tree,
      version: pin.state?.version ?? null,
    });
  }
  if (dependencies.length !== checkoutDirectories.length) {
    fail("undeclared SwiftPM dependency checkout exists");
  }
  return {
    dependencies,
    packageResolvedSHA256: fileSHA256(resolvedPath),
    schema: "TatwoSwiftPMDependencyStateV1",
  };
}

function dependencyState(args) {
  const output = path.resolve(args.one("--output"));
  const manifest = dependencyStateObject(
    path.resolve(args.one("--package-resolved")),
    path.resolve(args.one("--checkouts")),
  );
  const manifestSHA256 = writeCanonicalFile(output, manifest);
  process.stdout.write(canonicalJSON({
    dependencyCount: manifest.dependencies.length,
    manifestPath: output,
    manifestSHA256,
  }));
}

function commandIdentity(command, commandArgs) {
  return String(run(command, commandArgs)).trim();
}

function xcrunToolIdentity(tool, versionArgs = []) {
  const resolved = commandIdentity(
    "/usr/bin/xcrun",
    ["--sdk", "macosx", "--find", tool],
  );
  const real = fs.realpathSync(resolved);
  const stat = fs.statSync(real);
  if (!stat.isFile()) fail(`xcrun tool is not a regular file: ${tool}`);
  const uuids = commandIdentity("/usr/bin/dwarfdump", ["--uuid", real])
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      const match = /^UUID: ([0-9A-F-]+) \(([^)]+)\)/u.exec(line);
      if (!match) fail(`could not parse Mach-O UUID for xcrun tool: ${tool}`);
      return { architecture: match[2], uuid: match[1] };
    })
    .sort((left, right) => left.architecture.localeCompare(right.architecture));
  if (uuids.length === 0) fail(`xcrun tool has no Mach-O UUID: ${tool}`);
  return {
    binaryByteCount: stat.size,
    binarySHA256: fileSHA256(real),
    machOUUIDs: uuids,
    name: tool,
    pathBasename: path.basename(real),
    pathSHA256: sha256(real),
    version: versionArgs.length === 0
      ? null
      : commandIdentity("/usr/bin/xcrun", [tool, ...versionArgs]),
  };
}

function provenanceNodeIdentity(args) {
  const binary = path.resolve(args.one("--provenance-node-binary"));
  const expectedSHA256 = args.one("--provenance-node-sha256");
  const expectedCDHash = args.one("--provenance-node-cdhash");
  const expectedVersion = args.one("--provenance-node-version");
  const canonical = fs.realpathSync(binary);
  const executingCanonical = fs.realpathSync(process.execPath);
  if (binary !== canonical) {
    fail("provenance Node path must already be absolute and canonical");
  }
  if (executingCanonical !== canonical) {
    fail("build-input manifest is not running under the pinned provenance Node");
  }
  const actualSHA256 = fileSHA256(canonical);
  if (actualSHA256 !== expectedSHA256) {
    fail("pinned provenance Node binary digest mismatch");
  }
  const actualCDHash = codesignCDHash(canonical, true);
  if (actualCDHash !== expectedCDHash) {
    fail("pinned provenance Node code identity mismatch");
  }
  if (process.version !== expectedVersion) {
    fail("pinned provenance Node version mismatch");
  }
  return {
    binaryByteCount: fs.statSync(canonical).size,
    binarySHA256: actualSHA256,
    cdHash: actualCDHash,
    pathBasename: path.basename(canonical),
    pathSHA256: sha256(canonical),
    version: process.version,
  };
}

function parseKeyValue(values, label) {
  return values.map((value) => {
    const separator = value.indexOf("=");
    if (separator <= 0) fail(`${label} must use KEY=VALUE: ${value}`);
    const key = value.slice(0, separator);
    const raw = value.slice(separator + 1);
    if (!/^[A-Z][A-Z0-9_]*$/u.test(key)) fail(`invalid ${label} key: ${key}`);
    return { key, sha256: sha256(raw), valueLength: Buffer.byteLength(raw) };
  }).sort((left, right) => left.key.localeCompare(right.key));
}

function buildInputManifest(args) {
  const workspace = path.resolve(args.one("--workspace"));
  const snapshotPath = path.resolve(args.one("--source-snapshot"));
  const sourceManifestPath = path.resolve(args.one("--source-manifest"));
  const packageResolved = path.resolve(args.one("--package-resolved"));
  const checkouts = path.resolve(args.one("--checkouts"));
  const output = path.resolve(args.one("--output"));
  const snapshot = JSON.parse(fs.readFileSync(snapshotPath, "utf8"));
  const sourceManifest = JSON.parse(fs.readFileSync(sourceManifestPath, "utf8"));
  if (
    snapshot.schema !== "TatwoDurableSourceSnapshotV1"
    || sourceManifest.schema !== "TatwoSourceTreeManifestV1"
    || snapshot.sourceTree !== sourceManifest.sourceTree
    || snapshot.treeManifestSHA256 !== fileSHA256(sourceManifestPath)
  ) {
    fail("source snapshot and source tree manifest binding failed");
  }
  const declaredPaths = parseDeclaredInputPaths(
    fs.readFileSync(path.join(workspace, "Package.swift"), "utf8"),
    workspace,
  );
  const declared = {
    declaredPaths,
    entries: collectFilesystemEntries(workspace, declaredPaths, true),
    schema: "TatwoDeclaredBuildInputsV2",
  };
  const nativeSourcePaths = args.many("--native-source").map(normalizeRelative);
  const workspaceReal = fs.realpathSync(workspace);
  for (const nativeSourcePath of nativeSourcePaths) {
    const absolute = path.resolve(workspace, nativeSourcePath);
    assertWithin(workspace, absolute);
    const real = fs.realpathSync(absolute);
    const realRelative = path.relative(workspaceReal, real);
    const stat = fs.lstatSync(absolute);
    if (
      !stat.isFile()
      || stat.isSymbolicLink()
      || realRelative === ".."
      || realRelative.startsWith(`..${path.sep}`)
      || path.isAbsolute(realRelative)
      || real !== path.resolve(workspaceReal, nativeSourcePath)
    ) {
      fail(`native build source must be a regular non-symlink file: ${nativeSourcePath}`);
    }
  }
  const nativeSources = {
    entries: collectFilesystemEntries(workspace, nativeSourcePaths, true),
    paths: nativeSourcePaths,
    schema: "TatwoNativeBuildSourcesV1",
  };
  const sdkPath = commandIdentity(
    "/usr/bin/xcrun",
    ["--sdk", "macosx", "--show-sdk-path"],
  );
  const manifest = {
    architecture: {
      node: process.arch,
      uname: commandIdentity("/usr/bin/uname", ["-m"]),
    },
    buildFlags: args.many("--build-flag"),
    declaredInputsSHA256: sha256(canonicalJSON(declared)),
    dependencies: dependencyStateObject(packageResolved, checkouts),
    environment: parseKeyValue(args.many("--env"), "environment"),
    nativeBuild: {
      compileFlags: args.many("--native-compile-flag"),
      sources: nativeSources,
      sourcesSHA256: sha256(canonicalJSON(nativeSources)),
      stripFlags: args.many("--native-strip-flag"),
      tools: {
        clang: xcrunToolIdentity("clang", ["--version"]),
        strip: xcrunToolIdentity("strip"),
      },
    },
    provenanceRuntime: {
      node: provenanceNodeIdentity(args),
    },
    repositoryState: {
      lfsPointers: snapshot.lfsPointers,
      submodules: snapshot.submodules,
    },
    schema: "TatwoBuildInputManifestV1",
    source: {
      archiveSHA256: snapshot.archiveSHA256,
      snapshotSHA256: fileSHA256(snapshotPath),
      sourceCommit: snapshot.sourceCommit,
      sourceDirty: snapshot.sourceDirty,
      sourceTree: snapshot.sourceTree,
      treeManifestSHA256: snapshot.treeManifestSHA256,
    },
    toolchain: {
      clang: commandIdentity("/usr/bin/xcrun", ["clang", "--version"]),
      sdkBuildVersion: commandIdentity(
        "/usr/bin/xcrun",
        ["--sdk", "macosx", "--show-sdk-build-version"],
      ),
      sdkPathBasename: path.basename(sdkPath),
      sdkPathSHA256: sha256(sdkPath),
      sdkVersion: commandIdentity(
        "/usr/bin/xcrun",
        ["--sdk", "macosx", "--show-sdk-version"],
      ),
      swift: commandIdentity("/usr/bin/swift", ["--version"]),
      xcode: commandIdentity("/usr/bin/xcodebuild", ["-version"]),
    },
  };
  const manifestSHA256 = writeCanonicalFile(output, manifest);
  process.stdout.write(canonicalJSON({
    manifestPath: output,
    manifestSHA256,
  }));
}

function plistValue(infoPlist, key) {
  return String(
    run("/usr/bin/plutil", ["-extract", key, "raw", "-o", "-", infoPlist]),
  ).trim();
}

const BUNDLE_CONTENT_EXCLUSIONS = Object.freeze([
  "Contents/Info.plist",
  "Contents/_CodeSignature/**",
  "Contents/Resources/TatwoBundleContentManifestV1.json",
  "Contents/Resources/TatwoCandidateProvenance.json",
]);

function isMachO(filePath) {
  const descriptor = fs.openSync(filePath, "r");
  try {
    const header = Buffer.alloc(4);
    if (fs.readSync(descriptor, header, 0, header.length, 0) !== header.length) {
      return false;
    }
    return new Set([
      "cafebabe",
      "cafebabf",
      "cefaedfe",
      "cffaedfe",
      "feedface",
      "feedfacf",
      "bebafeca",
      "bfbafeca",
    ]).has(header.toString("hex"));
  } finally {
    fs.closeSync(descriptor);
  }
}

function canonicalMachOIdentity(filePath) {
  const tempRoot = makeOwnedTemp("tatwo-provenance-bundle-content-");
  const canonicalPath = path.join(tempRoot, "payload");
  try {
    fs.copyFileSync(filePath, canonicalPath, fs.constants.COPYFILE_EXCL);
    fs.chmodSync(canonicalPath, fs.statSync(filePath).mode & 0o777);

    // First remove any pre-existing signature, then create/remove a controlled
    // ad-hoc signature. The final bytes are independent of the original
    // signature blob and of the containing bundle's Info.plist.
    spawnSync(
      "/usr/bin/codesign",
      ["--remove-signature", canonicalPath],
      { encoding: "utf8", maxBuffer: 1024 * 1024 * 8 },
    );
    run(
      "/usr/bin/codesign",
      ["-s", "-", "--force", "--timestamp=none", canonicalPath],
    );
    run("/usr/bin/codesign", ["--remove-signature", canonicalPath]);
    return {
      sha256: fileSHA256(canonicalPath),
      size: fs.statSync(canonicalPath).size,
    };
  } finally {
    cleanupOwnedTemp(tempRoot);
  }
}

function bundleContentPathIsExcluded(relative) {
  const components = relative.split("/");
  return relative === "Contents/Info.plist"
    || relative === "Contents/Resources/TatwoBundleContentManifestV1.json"
    || relative === "Contents/Resources/TatwoCandidateProvenance.json"
    // The schema's Contents/_CodeSignature/** exclusion applies to signing
    // artifacts at every nested-code boundary under Contents.
    || components.includes("_CodeSignature");
}

function bundleContentEntry(bundle, absolutePath) {
  const relative = normalizeRelative(path.relative(bundle, absolutePath));
  const stat = fs.lstatSync(absolutePath);
  if (stat.isSymbolicLink()) {
    const target = Buffer.from(fs.readlinkSync(absolutePath), "utf8");
    return {
      digestMode: "symlink-target-sha256",
      mode: "120000",
      path: relative,
      sha256: sha256(target),
      size: target.length,
      type: "symlink",
    };
  }
  if (!stat.isFile()) {
    fail(`unsupported bundle content entry: ${absolutePath}`);
  }
  const macho = isMachO(absolutePath);
  const canonicalMachO = macho ? canonicalMachOIdentity(absolutePath) : null;
  return {
    digestMode: macho ? "macho-adhoc-resign-strip-v1" : "raw-sha256",
    mode: (stat.mode & 0o111) === 0 ? "100644" : "100755",
    path: relative,
    sha256: canonicalMachO?.sha256 ?? fileSHA256(absolutePath),
    size: canonicalMachO?.size ?? stat.size,
    type: "file",
  };
}

function collectBundleContentEntries(bundle) {
  const contents = path.join(bundle, "Contents");
  if (!fs.existsSync(contents) || !fs.lstatSync(contents).isDirectory()) {
    fail(`App bundle Contents directory is missing: ${contents}`);
  }
  const entries = [];
  const visit = (absolutePath) => {
    const relative = normalizeRelative(path.relative(bundle, absolutePath));
    if (bundleContentPathIsExcluded(relative)) return;
    const stat = fs.lstatSync(absolutePath);
    if (stat.isDirectory() && !stat.isSymbolicLink()) {
      for (
        const name of fs.readdirSync(absolutePath).sort((left, right) =>
          Buffer.from(left).compare(Buffer.from(right))
        )
      ) {
        visit(path.join(absolutePath, name));
      }
      return;
    }
    entries.push(bundleContentEntry(bundle, absolutePath));
  };
  visit(contents);
  return entries.sort((left, right) =>
    Buffer.from(left.path).compare(Buffer.from(right.path))
  );
}

function createBundleContentManifest(bundle, mainExecutablePath) {
  const mainPath = normalizeRelative(mainExecutablePath);
  if (!mainPath.startsWith("Contents/MacOS/")) {
    fail(`main executable must be under Contents/MacOS: ${mainPath}`);
  }
  const entries = collectBundleContentEntries(bundle);
  const mainEntry = entries.find((entry) => entry.path === mainPath);
  if (!mainEntry || mainEntry.type !== "file") {
    fail(`main executable is missing from bundle content manifest: ${mainPath}`);
  }
  if (mainEntry.digestMode !== "macho-adhoc-resign-strip-v1") {
    fail(`main executable is not Mach-O: ${mainPath}`);
  }
  return {
    entries,
    exclusions: [...BUNDLE_CONTENT_EXCLUSIONS],
    mainExecutable: {
      digestMode: mainEntry.digestMode,
      path: mainEntry.path,
      sha256: mainEntry.sha256,
    },
    schema: "TatwoBundleContentManifestV1",
  };
}

function bundleContentManifest(args) {
  const bundle = path.resolve(args.one("--bundle"));
  const output = path.resolve(args.one("--output"));
  const mainExecutable = args.one("--main-executable");
  const manifest = createBundleContentManifest(bundle, mainExecutable);
  const manifestSHA256 = writeCanonicalFile(output, manifest);
  process.stdout.write(canonicalJSON({
    entryCount: manifest.entries.length,
    mainExecutableSHA256: manifest.mainExecutable.sha256,
    manifestPath: output,
    manifestSHA256,
    schema: manifest.schema,
  }));
}

function validateBundleContentManifest(manifest) {
  if (
    manifest.schema !== "TatwoBundleContentManifestV1"
    || canonicalJSON(manifest.exclusions) !== canonicalJSON(BUNDLE_CONTENT_EXCLUSIONS)
    || !Array.isArray(manifest.entries)
    || !manifest.mainExecutable
  ) {
    fail("unsupported or malformed bundle content manifest");
  }
  const expectedMain = manifest.entries.find(
    (entry) => entry.path === manifest.mainExecutable.path,
  );
  if (
    !expectedMain
    || expectedMain.type !== "file"
    || expectedMain.digestMode !== manifest.mainExecutable.digestMode
    || expectedMain.sha256 !== manifest.mainExecutable.sha256
  ) {
    fail("bundle content manifest main executable binding is invalid");
  }
}

function verifiedBundleContent(bundle, manifestPath) {
  const expected = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  validateBundleContentManifest(expected);
  const actual = createBundleContentManifest(
    bundle,
    expected.mainExecutable.path,
  );
  if (actual.mainExecutable.sha256 !== expected.mainExecutable.sha256) {
    fail(
      "bundle content manifest main executable drift detected",
      [
        `path=${expected.mainExecutable.path}`,
        `expected=${expected.mainExecutable.sha256}`,
        `actual=${actual.mainExecutable.sha256}`,
      ].join("\n"),
    );
  }
  const expectedDigest = sha256(canonicalJSON(expected));
  const actualDigest = sha256(canonicalJSON(actual));
  if (actualDigest !== expectedDigest) {
    const expectedEntries = new Map(
      expected.entries.map((entry) => [entry.path, canonicalJSON(entry)]),
    );
    const actualEntries = new Map(
      actual.entries.map((entry) => [entry.path, canonicalJSON(entry)]),
    );
    const changed = [...new Set([
      ...expectedEntries.keys(),
      ...actualEntries.keys(),
    ])]
      .filter((entryPath) =>
        expectedEntries.get(entryPath) !== actualEntries.get(entryPath)
      )
      .sort((left, right) => Buffer.from(left).compare(Buffer.from(right)));
    fail(
      "bundle content manifest drift detected",
      [
        `expected=${expectedDigest}`,
        `actual=${actualDigest}`,
        ...changed.map((entryPath) => `changed=${entryPath}`),
      ].join("\n"),
    );
  }
  return {
    actual,
    manifestSHA256: expectedDigest,
  };
}

function verifyBundleContentManifest(args) {
  const bundle = path.resolve(args.one("--bundle"));
  const manifestPath = path.resolve(args.one("--manifest"));
  const verified = verifiedBundleContent(bundle, manifestPath);
  process.stdout.write(canonicalJSON({
    mainExecutableSHA256: verified.actual.mainExecutable.sha256,
    manifestSHA256: verified.manifestSHA256,
    schema: "TatwoBundleContentManifestVerificationV1",
    verified: true,
  }));
}

function codesignCDHash(bundle, required) {
  const result = spawnSync(
    "/usr/bin/codesign",
    ["-d", "--verbose=4", bundle],
    { encoding: "utf8", maxBuffer: 1024 * 1024 * 8 },
  );
  if (result.status !== 0) {
    if (required) fail("codesign identity readback failed", result.stderr);
    return null;
  }
  const match = `${result.stdout}${result.stderr}`.match(/^CDHash=([0-9a-f]+)$/mu);
  if (!match) {
    if (required) fail("codesign readback did not expose CDHash");
    return null;
  }
  return match[1];
}

function bundleIdentity(args) {
  const bundle = path.resolve(args.one("--bundle"));
  const manifestPath = path.resolve(args.one("--manifest"));
  const output = path.resolve(args.one("--output"));
  const required = args.one("--codesign-required", false) === "1";
  const infoPlist = path.join(bundle, "Contents", "Info.plist");
  const executableName = plistValue(infoPlist, "CFBundleExecutable");
  const embeddedReceipt = path.join(
    bundle,
    "Contents",
    "Resources",
    "TatwoCandidateProvenance.json",
  );
  const embeddedBundleContentManifest = path.join(
    bundle,
    "Contents",
    "Resources",
    "TatwoBundleContentManifestV1.json",
  );
  const pinnedBundleContentManifestSHA256 = plistValue(
    infoPlist,
    "TatwoBundleContentManifestSHA256",
  );
  const pinnedMainExecutableSHA256 = plistValue(
    infoPlist,
    "TatwoMainExecutableSHA256",
  );
  const version = plistValue(infoPlist, "CFBundleShortVersionString");
  const build = plistValue(infoPlist, "CFBundleVersion");
  const candidateID = plistValue(infoPlist, "TatwoCandidateID");
  const sourceCommit = plistValue(infoPlist, "TatwoSourceCommit");
  const sourceTree = plistValue(infoPlist, "TatwoSourceTree");
  const sourceDirty = plistValue(infoPlist, "TatwoSourceDirty") === "true";
  const sourceSnapshotSHA256 = plistValue(
    infoPlist,
    "TatwoSourceSnapshotSHA256",
  );
  const sourceTreeManifestSHA256 = plistValue(
    infoPlist,
    "TatwoSourceTreeManifestSHA256",
  );
  const buildInputManifestSHA256 = plistValue(
    infoPlist,
    "TatwoBuildInputManifestSHA256",
  );
  const buildOutputManifestSHA256 = plistValue(
    infoPlist,
    "TatwoBuildOutputManifestSHA256",
  );
  const provenanceNodeSHA256 = plistValue(
    infoPlist,
    "TatwoProvenanceNodeSHA256",
  );
  const provenanceNodeCDHash = plistValue(
    infoPlist,
    "TatwoProvenanceNodeCDHash",
  );
  const provenanceNodeVersion = plistValue(
    infoPlist,
    "TatwoProvenanceNodeVersion",
  );
  const embeddedProvenanceSHA256 = plistValue(
    infoPlist,
    "TatwoEmbeddedProvenanceSHA256",
  );
  if (
    fileSHA256(embeddedBundleContentManifest)
    !== pinnedBundleContentManifestSHA256
  ) {
    fail("Info.plist bundle content manifest digest binding failed");
  }
  const verifiedContent = verifiedBundleContent(
    bundle,
    embeddedBundleContentManifest,
  );
  if (
    verifiedContent.actual.mainExecutable.sha256
    !== pinnedMainExecutableSHA256
  ) {
    fail("Info.plist main executable digest binding failed");
  }
  if (fileSHA256(embeddedReceipt) !== embeddedProvenanceSHA256) {
    fail("Info.plist embedded provenance digest binding failed");
  }
  const embedded = JSON.parse(fs.readFileSync(embeddedReceipt, "utf8"));
  const embeddedBindings = {
    buildInputManifestSHA256,
    buildOutputManifestSHA256,
    bundleContentManifestSHA256: pinnedBundleContentManifestSHA256,
    candidateID,
    mainExecutableSHA256: pinnedMainExecutableSHA256,
    provenanceNodeCDHash,
    provenanceNodeSHA256,
    provenanceNodeVersion,
    sourceCommit,
    sourceDirty,
    sourceSnapshotSHA256,
    sourceTree,
    sourceTreeManifestSHA256,
  };
  if (embedded.schema !== "TatwoCandidateEmbeddedProvenanceV1") {
    fail("embedded Candidate provenance schema is invalid");
  }
  for (const [key, value] of Object.entries(embeddedBindings)) {
    if (embedded[key] !== value) {
      fail(`embedded Candidate provenance binding failed: ${key}`);
    }
  }
  const authorityProvenance = [
    [
      "TatwoSourceSnapshotV1.json",
      sourceSnapshotSHA256,
    ],
    [
      "TatwoSourceTreeManifestV1.json",
      sourceTreeManifestSHA256,
    ],
    [
      "TatwoBuildInputManifestV1.json",
      buildInputManifestSHA256,
    ],
    [
      "TatwoBuildOutputManifestV1.json",
      buildOutputManifestSHA256,
    ],
  ];
  for (const [name, expectedSHA256] of authorityProvenance) {
    const embeddedPath = path.join(
      bundle,
      "Contents",
      "Resources",
      "TatwoProvenance",
      name,
    );
    if (fileSHA256(embeddedPath) !== expectedSHA256) {
      fail(`embedded authority provenance digest binding failed: ${name}`);
    }
  }
  const recomputedCandidateID = sha256(
    [
      sourceCommit,
      sourceTree,
      sourceSnapshotSHA256,
      sourceTreeManifestSHA256,
      buildInputManifestSHA256,
      buildOutputManifestSHA256,
      pinnedBundleContentManifestSHA256,
      pinnedMainExecutableSHA256,
      provenanceNodeSHA256,
      provenanceNodeCDHash,
      provenanceNodeVersion,
      version,
      build,
    ].join("\n") + "\n",
  );
  if (recomputedCandidateID !== candidateID) {
    fail("TatwoCandidateID binding failed");
  }
  const identity = {
    bundleIdentifier: plistValue(infoPlist, "CFBundleIdentifier"),
    bundleManifestSHA256: fileSHA256(manifestPath),
    build,
    candidateID,
    codeSignCDHash: codesignCDHash(bundle, required),
    embeddedProvenanceSHA256,
    executableSHA256: fileSHA256(
      path.join(bundle, "Contents", "MacOS", executableName),
    ),
    infoPlistSHA256: fileSHA256(infoPlist),
    provenance: {
      buildInputManifestSHA256: plistValue(
        infoPlist,
        "TatwoBuildInputManifestSHA256",
      ),
      buildOutputManifestSHA256: plistValue(
        infoPlist,
        "TatwoBuildOutputManifestSHA256",
      ),
      bundleContentManifestSHA256: plistValue(
        infoPlist,
        "TatwoBundleContentManifestSHA256",
      ),
      mainExecutableSHA256: plistValue(
        infoPlist,
        "TatwoMainExecutableSHA256",
      ),
      sourceSnapshotSHA256: plistValue(
        infoPlist,
        "TatwoSourceSnapshotSHA256",
      ),
      sourceTreeManifestSHA256: plistValue(
        infoPlist,
        "TatwoSourceTreeManifestSHA256",
      ),
    },
    schema: "TatwoCandidateBundleIdentityV1",
    version,
  };
  const identitySHA256 = writeCanonicalFile(output, identity);
  process.stdout.write(canonicalJSON({
    identityPath: output,
    identitySHA256,
  }));
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  switch (args.command) {
    case "source-state":
      sourceState(args);
      break;
    case "source-snapshot":
      sourceSnapshot(args);
      break;
    case "verify-source-archive":
      verifySourceArchive(args);
      break;
    case "extract-source":
      extractSourceArchive(args);
      break;
    case "fs-manifest":
      filesystemManifest(args);
      break;
    case "verify-fs-manifest":
      verifyFilesystemManifest(args);
      break;
    case "declared-inputs":
      declaredInputs(args);
      break;
    case "dependency-state":
      dependencyState(args);
      break;
    case "build-input-manifest":
      buildInputManifest(args);
      break;
    case "bundle-content-manifest":
      bundleContentManifest(args);
      break;
    case "verify-bundle-content-manifest":
      verifyBundleContentManifest(args);
      break;
    case "bundle-identity":
      bundleIdentity(args);
      break;
    default:
      fail(`unsupported provenance command: ${args.command ?? "(missing)"}`);
  }
}

try {
  main();
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`error: ${message}\n`);
  process.exitCode = 1;
}
