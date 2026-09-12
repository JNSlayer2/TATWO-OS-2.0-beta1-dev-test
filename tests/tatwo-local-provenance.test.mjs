import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const tool = path.join(root, "scripts", "tatwo-local-provenance.mjs");
const preferredTempBase = "/tmp/tatwo2-fixture/runtime/test-tmp/provenance-tests";
const tempBase = fs.existsSync("/tmp/tatwo2-fixture")
  ? preferredTempBase
  : path.join(os.tmpdir(), ".tatwo-provenance-tests");
fs.mkdirSync(tempBase, { recursive: true });

function runTool(args, options = {}) {
  const {
    env = {},
    tempRoot = tempBase,
    ...spawnOptions
  } = options;
  return spawnSync(process.execPath, [tool, ...args], {
    encoding: "utf8",
    env: {
      ...process.env,
      ...env,
      TATWO_PROVENANCE_TMPDIR: tempRoot,
    },
    ...spawnOptions,
  });
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    ...options,
  });
  assert.equal(
    result.status,
    0,
    `${command} ${args.join(" ")}\n${result.stdout}${result.stderr}`,
  );
  return result.stdout.trim();
}

function git(repo, ...args) {
  return run("git", args, { cwd: repo });
}

function sha256(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

function provenanceNodeArgs() {
  const binary = fs.realpathSync(process.execPath);
  const detail = spawnSync(
    "/usr/bin/codesign",
    ["-d", "--verbose=4", binary],
    { encoding: "utf8" },
  );
  assert.equal(
    detail.status,
    0,
    `${detail.stdout}${detail.stderr}`,
  );
  const cdHash = /^CDHash=([0-9a-f]{40})$/mu.exec(
    `${detail.stdout}${detail.stderr}`,
  )?.[1];
  assert.ok(cdHash, "test Node binary must expose a CDHash");
  return [
    "--provenance-node-binary", binary,
    "--provenance-node-sha256", sha256(fs.readFileSync(binary)),
    "--provenance-node-cdhash", cdHash,
    "--provenance-node-version", process.version,
  ];
}

function createFixtureRepo() {
  const repo = fs.mkdtempSync(path.join(tempBase, "source-repo-"));
  fs.mkdirSync(path.join(repo, "Sources", "Fixture"), { recursive: true });
  fs.mkdirSync(
    path.join(repo, "Tools", "TatwoPLGAnchorHelper"),
    { recursive: true },
  );
  fs.writeFileSync(
    path.join(repo, "Package.swift"),
    [
      "// swift-tools-version: 6.1",
      "import PackageDescription",
      "let package = Package(",
      '  name: "Fixture",',
      "  targets: [",
      '    .target(name: "Fixture", path: "Sources/Fixture")',
      "  ]",
      ")",
      "",
    ].join("\n"),
  );
  fs.writeFileSync(path.join(repo, ".gitignore"), ".build/\n");
  fs.writeFileSync(
    path.join(repo, "Package.resolved"),
    '{"originHash":"fixture","pins":[],"version":3}\n',
  );
  fs.writeFileSync(
    path.join(repo, "Sources", "Fixture", "Fixture.swift"),
    "public let fixture = 1\n",
  );
  fs.writeFileSync(
    path.join(repo, "Tools", "TatwoPLGAnchorHelper", "main.c"),
    "int main(void) { return 0; }\n",
  );
  git(repo, "init", "-q");
  git(repo, "config", "user.name", "Tatwo Provenance Test");
  git(repo, "config", "user.email", "provenance@tatwo.invalid");
  git(repo, "add", ".");
  git(repo, "commit", "-qm", "fixture");
  return repo;
}

function createDependencyCheckout(checkouts, name = "ExampleDep") {
  const checkout = path.join(checkouts, name);
  fs.mkdirSync(checkout, { recursive: true });
  fs.writeFileSync(path.join(checkout, "Package.swift"), "// dependency\n");
  fs.writeFileSync(path.join(checkout, "Dependency.swift"), "let dependency = 1\n");
  git(checkout, "init", "-q");
  git(checkout, "config", "user.name", "Tatwo Dependency Test");
  git(checkout, "config", "user.email", "dependency@tatwo.invalid");
  git(checkout, "add", ".");
  git(checkout, "commit", "-qm", "dependency fixture");
  return {
    checkout,
    revision: git(checkout, "rev-parse", "HEAD"),
  };
}

function writePackageResolved(file, pins) {
  fs.writeFileSync(
    file,
    `${JSON.stringify({
      originHash: "fixture",
      pins,
      version: 3,
    })}\n`,
  );
}

function createSnapshot(repo, runRoot) {
  const output = path.join(runRoot, "payload");
  const result = runTool([
    "source-snapshot",
    "--repo", repo,
    "--commit", git(repo, "rev-parse", "HEAD"),
    "--output-dir", output,
  ], { tempRoot: runRoot });
  assert.equal(result.status, 0, `${result.stdout}${result.stderr}`);
  return {
    archive: path.join(output, "source.tar.gz"),
    manifest: path.join(output, "source-tree-manifest.json"),
    output,
    snapshot: path.join(output, "source-snapshot.json"),
    value: JSON.parse(result.stdout),
  };
}

function createBundleFixture(runRoot) {
  const bundle = path.join(runRoot, "Tatwo Ultrawork.app");
  const main = path.join(bundle, "Contents", "MacOS", "TatwoUltraworkMac");
  const helper = path.join(bundle, "Contents", "Helpers", "TatwoPLGAnchorHelper");
  const nested = path.join(
    bundle,
    "Contents",
    "Frameworks",
    "Fixture.framework",
    "Versions",
    "A",
    "Fixture",
  );
  const resource = path.join(bundle, "Contents", "Resources", "fixture.json");
  const nestedResource = path.join(
    bundle,
    "Contents",
    "Resources",
    "Nested",
    "payload.txt",
  );
  fs.mkdirSync(path.dirname(main), { recursive: true });
  fs.mkdirSync(path.dirname(helper), { recursive: true });
  fs.mkdirSync(path.dirname(nested), { recursive: true });
  fs.mkdirSync(path.dirname(resource), { recursive: true });
  fs.mkdirSync(path.dirname(nestedResource), { recursive: true });
  fs.mkdirSync(
    path.join(bundle, "Contents", "_CodeSignature"),
    { recursive: true },
  );
  fs.mkdirSync(
    path.join(
      bundle,
      "Contents",
      "Frameworks",
      "Fixture.framework",
      "Versions",
      "A",
      "_CodeSignature",
    ),
    { recursive: true },
  );
  fs.copyFileSync("/bin/echo", main);
  fs.copyFileSync("/bin/echo", helper);
  fs.copyFileSync("/bin/echo", nested);
  fs.chmodSync(main, 0o755);
  fs.chmodSync(helper, 0o755);
  fs.chmodSync(nested, 0o755);
  fs.writeFileSync(resource, '{"fixture":true}\n');
  fs.writeFileSync(nestedResource, "nested payload\n");
  fs.writeFileSync(
    path.join(bundle, "Contents", "Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TatwoUltraworkMac</string>
<key>CFBundleIdentifier</key><string>com.tatwo.bundle-content-fixture</string>
<key>CFBundleName</key><string>Tatwo Bundle Content Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
`,
  );
  fs.writeFileSync(
    path.join(
      bundle,
      "Contents",
      "Resources",
      "TatwoCandidateProvenance.json",
    ),
    '{"candidate":"one"}\n',
  );
  fs.writeFileSync(
    path.join(bundle, "Contents", "_CodeSignature", "CodeResources"),
    "top signature one\n",
  );
  fs.writeFileSync(
    path.join(
      bundle,
      "Contents",
      "Frameworks",
      "Fixture.framework",
      "Versions",
      "A",
      "_CodeSignature",
      "CodeResources",
    ),
    "nested signature one\n",
  );
  fs.symlinkSync(
    "Versions/A/Fixture",
    path.join(
      bundle,
      "Contents",
      "Frameworks",
      "Fixture.framework",
      "Fixture",
    ),
  );
  return { bundle, helper, main, nested, nestedResource, resource };
}

function captureBundleContentManifest(runRoot, fixture, name) {
  const manifest = path.join(runRoot, `${name}.json`);
  const result = runTool([
    "bundle-content-manifest",
    "--bundle", fixture.bundle,
    "--main-executable", "Contents/MacOS/TatwoUltraworkMac",
    "--output", manifest,
  ], { tempRoot: runRoot });
  assert.equal(result.status, 0, `${result.stdout}${result.stderr}`);
  return {
    manifest,
    result: JSON.parse(result.stdout),
    value: JSON.parse(fs.readFileSync(manifest, "utf8")),
  };
}

function bindBundleAuthority(runRoot, fixture) {
  const authorityDir = path.join(
    fixture.bundle,
    "Contents",
    "Resources",
    "TatwoProvenance",
  );
  fs.mkdirSync(authorityDir, { recursive: true });
  const authorityFiles = {
    buildInputManifestSHA256: [
      "TatwoBuildInputManifestV1.json",
      '{"schema":"TatwoBuildInputManifestV1"}\n',
    ],
    buildOutputManifestSHA256: [
      "TatwoBuildOutputManifestV1.json",
      '{"schema":"TatwoFilesystemManifestV2"}\n',
    ],
    sourceSnapshotSHA256: [
      "TatwoSourceSnapshotV1.json",
      '{"schema":"TatwoDurableSourceSnapshotV1"}\n',
    ],
    sourceTreeManifestSHA256: [
      "TatwoSourceTreeManifestV1.json",
      '{"schema":"TatwoSourceTreeManifestV1"}\n',
    ],
  };
  const pins = {};
  for (const [key, [name, contents]] of Object.entries(authorityFiles)) {
    const embedded = path.join(authorityDir, name);
    fs.writeFileSync(embedded, contents);
    pins[key] = sha256(fs.readFileSync(embedded));
  }
  const manifestPath = path.join(
    fixture.bundle,
    "Contents",
    "Resources",
    "TatwoBundleContentManifestV1.json",
  );
  const contentCapture = runTool([
    "bundle-content-manifest",
    "--bundle", fixture.bundle,
    "--main-executable", "Contents/MacOS/TatwoUltraworkMac",
    "--output", manifestPath,
  ], { tempRoot: runRoot });
  assert.equal(
    contentCapture.status,
    0,
    `${contentCapture.stdout}${contentCapture.stderr}`,
  );
  const content = JSON.parse(contentCapture.stdout);
  const values = {
    ...pins,
    build: "1",
    bundleContentManifestSHA256: content.manifestSHA256,
    mainExecutableSHA256: content.mainExecutableSHA256,
    provenanceNodeCDHash: "5".repeat(40),
    provenanceNodeSHA256: "6".repeat(64),
    provenanceNodeVersion: "v26.5.0",
    sourceCommit: "7".repeat(40),
    sourceDirty: false,
    sourceTree: "8".repeat(40),
    version: "1.0",
  };
  values.candidateID = sha256(
    [
      values.sourceCommit,
      values.sourceTree,
      values.sourceSnapshotSHA256,
      values.sourceTreeManifestSHA256,
      values.buildInputManifestSHA256,
      values.buildOutputManifestSHA256,
      values.bundleContentManifestSHA256,
      values.mainExecutableSHA256,
      values.provenanceNodeSHA256,
      values.provenanceNodeCDHash,
      values.provenanceNodeVersion,
      values.version,
      values.build,
    ].join("\n") + "\n",
  );
  const embeddedProvenancePath = path.join(
    fixture.bundle,
    "Contents",
    "Resources",
    "TatwoCandidateProvenance.json",
  );
  fs.writeFileSync(
    embeddedProvenancePath,
    `${JSON.stringify({
      buildInputManifestSHA256: values.buildInputManifestSHA256,
      buildOutputManifestSHA256: values.buildOutputManifestSHA256,
      bundleContentManifestSHA256: values.bundleContentManifestSHA256,
      candidateID: values.candidateID,
      mainExecutableSHA256: values.mainExecutableSHA256,
      provenanceNodeCDHash: values.provenanceNodeCDHash,
      provenanceNodeSHA256: values.provenanceNodeSHA256,
      provenanceNodeVersion: values.provenanceNodeVersion,
      schema: "TatwoCandidateEmbeddedProvenanceV1",
      sourceCommit: values.sourceCommit,
      sourceDirty: values.sourceDirty,
      sourceSnapshotSHA256: values.sourceSnapshotSHA256,
      sourceTree: values.sourceTree,
      sourceTreeManifestSHA256: values.sourceTreeManifestSHA256,
    })}\n`,
  );
  values.embeddedProvenanceSHA256 = sha256(
    fs.readFileSync(embeddedProvenancePath),
  );
  const infoPlist = path.join(fixture.bundle, "Contents", "Info.plist");
  fs.writeFileSync(
    infoPlist,
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TatwoUltraworkMac</string>
<key>CFBundleIdentifier</key><string>com.tatwo.bundle-content-fixture</string>
<key>CFBundleName</key><string>Tatwo Bundle Content Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${values.version}</string>
<key>CFBundleVersion</key><string>${values.build}</string>
<key>TatwoBuildInputManifestSHA256</key><string>${values.buildInputManifestSHA256}</string>
<key>TatwoBuildOutputManifestSHA256</key><string>${values.buildOutputManifestSHA256}</string>
<key>TatwoBundleContentManifestSHA256</key><string>${values.bundleContentManifestSHA256}</string>
<key>TatwoCandidateID</key><string>${values.candidateID}</string>
<key>TatwoEmbeddedProvenanceSHA256</key><string>${values.embeddedProvenanceSHA256}</string>
<key>TatwoMainExecutableSHA256</key><string>${values.mainExecutableSHA256}</string>
<key>TatwoProvenanceNodeCDHash</key><string>${values.provenanceNodeCDHash}</string>
<key>TatwoProvenanceNodeSHA256</key><string>${values.provenanceNodeSHA256}</string>
<key>TatwoProvenanceNodeVersion</key><string>${values.provenanceNodeVersion}</string>
<key>TatwoSourceCommit</key><string>${values.sourceCommit}</string>
<key>TatwoSourceDirty</key><false/>
<key>TatwoSourceSnapshotSHA256</key><string>${values.sourceSnapshotSHA256}</string>
<key>TatwoSourceTree</key><string>${values.sourceTree}</string>
<key>TatwoSourceTreeManifestSHA256</key><string>${values.sourceTreeManifestSHA256}</string>
</dict></plist>
`,
  );
  return { infoPlist, manifestPath, values };
}

test("durable dirty-source payload independently reconstructs source_tree and preserves real index bytes", () => {
  const repo = createFixtureRepo();
  const runRoot = fs.mkdtempSync(path.join(tempBase, "snapshot-run-"));
  try {
    fs.writeFileSync(
      path.join(repo, "Sources", "Fixture", "Fixture.swift"),
      "public let fixture = 2\n",
    );
    fs.writeFileSync(
      path.join(repo, "Sources", "Fixture", "New.swift"),
      "public let newValue = true\n",
    );
    const indexPath = path.join(repo, ".git", "index");
    const indexBefore = fs.readFileSync(indexPath);
    const payload = createSnapshot(repo, runRoot);

    assert.equal(payload.value.sourceDirty, true);
    assert.equal(payload.value.reconstructedTree, payload.value.sourceTree);
    assert.equal(payload.value.archiveSHA256, sha256(fs.readFileSync(payload.archive)));
    assert.deepEqual(fs.readFileSync(indexPath), indexBefore);

    const verify = runTool([
      "verify-source-archive",
      "--archive", payload.archive,
      "--manifest", payload.manifest,
      "--snapshot", payload.snapshot,
      "--expected-tree", payload.value.sourceTree,
    ], { tempRoot: runRoot });
    assert.equal(verify.status, 0, `${verify.stdout}${verify.stderr}`);
    assert.equal(JSON.parse(verify.stdout).rebuiltTree, payload.value.sourceTree);

    const workspace = path.join(runRoot, "clean-workspace");
    const extract = runTool([
      "extract-source",
      "--archive", payload.archive,
      "--manifest", payload.manifest,
      "--snapshot", payload.snapshot,
      "--expected-tree", payload.value.sourceTree,
      "--destination", workspace,
    ], { tempRoot: runRoot });
    assert.equal(extract.status, 0, `${extract.stdout}${extract.stderr}`);
    assert.equal(fs.existsSync(path.join(workspace, ".git")), false);
    assert.equal(
      fs.readFileSync(path.join(workspace, "Sources", "Fixture", "New.swift"), "utf8"),
      "public let newValue = true\n",
    );
  } finally {
    fs.rmSync(repo, { recursive: true, force: true });
    fs.rmSync(runRoot, { recursive: true, force: true });
  }
});

test("source snapshot does not fan out per-file git hash-object stdin subprocesses", () => {
  const repo = createFixtureRepo();
  const runRoot = fs.mkdtempSync(path.join(tempBase, "many-files-run-"));
  try {
    const wrapperRoot = path.join(runRoot, "bin");
    const wrapper = path.join(wrapperRoot, "git");
    fs.mkdirSync(wrapperRoot);
    fs.writeFileSync(
      wrapper,
      [
        "#!/bin/sh",
        'if [ "$1" = "hash-object" ] || [ "$3" = "hash-object" ]; then',
        '  for argument in "$@"; do',
        '    if [ "$argument" = "--stdin" ]; then',
        '      echo "per-file hash-object stdin fanout rejected" >&2',
        "      exit 97",
        "    fi",
        "  done",
        "fi",
        'exec /usr/bin/git "$@"',
        "",
      ].join("\n"),
    );
    fs.chmodSync(wrapper, 0o755);

    const result = runTool([
      "source-snapshot",
      "--repo", repo,
      "--commit", git(repo, "rev-parse", "HEAD"),
      "--output-dir", path.join(runRoot, "payload"),
    ], {
      env: {
        PATH: `${wrapperRoot}:${process.env.PATH}`,
      },
      killSignal: "SIGKILL",
      tempRoot: runRoot,
      timeout: 15_000,
    });

    assert.equal(
      result.status,
      0,
      `${result.error?.message ?? ""}\n${result.stdout}${result.stderr}`,
    );
    assert.equal(
      JSON.parse(result.stdout).reconstructedTree,
      git(repo, "rev-parse", "HEAD^{tree}"),
    );
  } finally {
    fs.rmSync(repo, { recursive: true, force: true });
    fs.rmSync(runRoot, { recursive: true, force: true });
  }
});

test("archive tamper fails closed against the durable snapshot digest binding", () => {
  const repo = createFixtureRepo();
  const runRoot = fs.mkdtempSync(path.join(tempBase, "tamper-run-"));
  try {
    const payload = createSnapshot(repo, runRoot);
    const tampered = path.join(runRoot, "tampered-source.tar.gz");
    const bytes = fs.readFileSync(payload.archive);
    bytes[Math.floor(bytes.length / 2)] ^= 0xff;
    fs.writeFileSync(tampered, bytes);
    const result = runTool([
      "verify-source-archive",
      "--archive", tampered,
      "--manifest", payload.manifest,
      "--snapshot", payload.snapshot,
      "--expected-tree", payload.value.sourceTree,
    ], { tempRoot: runRoot });
    assert.notEqual(result.status, 0, `${result.stdout}${result.stderr}`);
    assert.match(
      result.stderr,
      /source snapshot payload digest binding failed|failed with status/u,
    );
  } finally {
    fs.rmSync(repo, { recursive: true, force: true });
    fs.rmSync(runRoot, { recursive: true, force: true });
  }
});

test("ignored file under a declared Package.swift input fails closed", () => {
  const repo = createFixtureRepo();
  const runRoot = fs.mkdtempSync(path.join(tempBase, "ignored-run-"));
  try {
    fs.appendFileSync(
      path.join(repo, ".gitignore"),
      "Sources/Fixture/Generated.swift\n",
    );
    fs.writeFileSync(
      path.join(repo, "Sources", "Fixture", "Generated.swift"),
      "public let generated = true\n",
    );
    const result = runTool([
      "source-snapshot",
      "--repo", repo,
      "--commit", git(repo, "rev-parse", "HEAD"),
      "--output-dir", path.join(runRoot, "payload"),
    ], { tempRoot: runRoot });
    assert.notEqual(result.status, 0, `${result.stdout}${result.stderr}`);
    assert.match(result.stderr, /ignored\/generated files exist/u);
    assert.match(result.stderr, /Generated\.swift/u);
  } finally {
    fs.rmSync(repo, { recursive: true, force: true });
    fs.rmSync(runRoot, { recursive: true, force: true });
  }
});

test("source snapshot rejects Git submodules", () => {
  const repo = createFixtureRepo();
  const submoduleRepo = fs.mkdtempSync(
    path.join(tempBase, "submodule-origin-"),
  );
  const runRoot = fs.mkdtempSync(path.join(tempBase, "submodule-run-"));
  try {
    fs.writeFileSync(path.join(submoduleRepo, "README.md"), "submodule\n");
    git(submoduleRepo, "init", "-q");
    git(submoduleRepo, "config", "user.name", "Tatwo Submodule Test");
    git(
      submoduleRepo,
      "config",
      "user.email",
      "submodule@tatwo.invalid",
    );
    git(submoduleRepo, "add", ".");
    git(submoduleRepo, "commit", "-qm", "submodule fixture");
    git(
      repo,
      "-c",
      "protocol.file.allow=always",
      "submodule",
      "add",
      "-q",
      submoduleRepo,
      "Vendor/Child",
    );
    git(repo, "commit", "-qm", "add submodule");

    const result = runTool([
      "source-snapshot",
      "--repo", repo,
      "--commit", git(repo, "rev-parse", "HEAD"),
      "--output-dir", path.join(runRoot, "payload"),
    ], { tempRoot: runRoot });

    assert.notEqual(result.status, 0, `${result.stdout}${result.stderr}`);
    assert.match(
      result.stderr,
      /submodules are not supported by the local Candidate source payload/u,
    );
    assert.match(result.stderr, /Vendor\/Child/u);
  } finally {
    fs.rmSync(repo, { recursive: true, force: true });
    fs.rmSync(submoduleRepo, { recursive: true, force: true });
    fs.rmSync(runRoot, { recursive: true, force: true });
  }
});

for (const attack of [
  {
    expected: /Git LFS attributes are not supported/u,
    label: "attributes",
    mutate: (repo) => {
      fs.writeFileSync(
        path.join(repo, ".gitattributes"),
        "*.bin filter=lfs diff=lfs merge=lfs -text\n",
      );
      fs.writeFileSync(
        path.join(repo, "Sources", "Fixture", "payload.bin"),
        "ordinary bytes\n",
      );
    },
  },
  {
    expected: /unresolved Git LFS pointer in Candidate source/u,
    label: "pointer",
    mutate: (repo) => {
      fs.writeFileSync(
        path.join(repo, "Sources", "Fixture", "payload.bin"),
        [
          "version https://git-lfs.github.com/spec/v1",
          `oid sha256:${"1".repeat(64)}`,
          "size 123",
          "",
        ].join("\n"),
      );
    },
  },
]) {
  test(`source snapshot rejects Git LFS ${attack.label}`, () => {
    const repo = createFixtureRepo();
    const runRoot = fs.mkdtempSync(
      path.join(tempBase, `lfs-${attack.label}-run-`),
    );
    try {
      attack.mutate(repo);
      git(repo, "add", ".");
      git(repo, "commit", "-qm", `add LFS ${attack.label}`);

      const result = runTool([
        "source-snapshot",
        "--repo", repo,
        "--commit", git(repo, "rev-parse", "HEAD"),
        "--output-dir", path.join(runRoot, "payload"),
      ], { tempRoot: runRoot });

      assert.notEqual(result.status, 0, `${result.stdout}${result.stderr}`);
      assert.match(result.stderr, attack.expected);
      assert.match(result.stderr, /payload\.bin|\.gitattributes/u);
    } finally {
      fs.rmSync(repo, { recursive: true, force: true });
      fs.rmSync(runRoot, { recursive: true, force: true });
    }
  });
}

test("dependency state rejects a checkout revision mismatch", () => {
  const runRoot = fs.mkdtempSync(
    path.join(tempBase, "dependency-revision-run-"),
  );
  try {
    const checkouts = path.join(runRoot, "checkouts");
    fs.mkdirSync(checkouts, { recursive: true });
    const dependency = createDependencyCheckout(checkouts);
    const packageResolved = path.join(runRoot, "Package.resolved");
    const expectedRevision =
      dependency.revision === "f".repeat(40)
        ? "e".repeat(40)
        : "f".repeat(40);
    writePackageResolved(packageResolved, [{
      identity: "example-dep",
      kind: "remoteSourceControl",
      location: "https://example.invalid/ExampleDep.git",
      state: {
        revision: expectedRevision,
        version: "1.0.0",
      },
    }]);

    const result = runTool([
      "dependency-state",
      "--package-resolved", packageResolved,
      "--checkouts", checkouts,
      "--output", path.join(runRoot, "dependency-state.json"),
    ], { tempRoot: runRoot });

    assert.notEqual(result.status, 0, `${result.stdout}${result.stderr}`);
    assert.match(
      result.stderr,
      /dependency revision differs from Package\.resolved: example-dep/u,
    );
    assert.match(result.stderr, new RegExp(`expected=${expectedRevision}`, "u"));
    assert.match(
      result.stderr,
      new RegExp(`actual=${dependency.revision}`, "u"),
    );
  } finally {
    fs.rmSync(runRoot, { recursive: true, force: true });
  }
});

test("dependency state rejects an undeclared SwiftPM checkout", () => {
  const runRoot = fs.mkdtempSync(
    path.join(tempBase, "dependency-undeclared-run-"),
  );
  try {
    const checkouts = path.join(runRoot, "checkouts");
    fs.mkdirSync(checkouts, { recursive: true });
    createDependencyCheckout(checkouts, "UndeclaredDep");
    const packageResolved = path.join(runRoot, "Package.resolved");
    writePackageResolved(packageResolved, []);

    const result = runTool([
      "dependency-state",
      "--package-resolved", packageResolved,
      "--checkouts", checkouts,
      "--output", path.join(runRoot, "dependency-state.json"),
    ], { tempRoot: runRoot });

    assert.notEqual(result.status, 0, `${result.stdout}${result.stderr}`);
    assert.match(
      result.stderr,
      /undeclared SwiftPM dependency checkout exists/u,
    );
  } finally {
    fs.rmSync(runRoot, { recursive: true, force: true });
  }
});

test("closed-world build input manifest deterministically binds Swift and native helper sources, flags, toolchain, SDK, architecture, dependency, and sanitized environment identity", () => {
  const repo = createFixtureRepo();
  const runRoot = fs.mkdtempSync(path.join(tempBase, "inputs-run-"));
  try {
    const payload = createSnapshot(repo, runRoot);
    const workspace = path.join(runRoot, "workspace");
    const extract = runTool([
      "extract-source",
      "--archive", payload.archive,
      "--manifest", payload.manifest,
      "--snapshot", payload.snapshot,
      "--expected-tree", payload.value.sourceTree,
      "--destination", workspace,
    ], { tempRoot: runRoot });
    assert.equal(extract.status, 0, `${extract.stdout}${extract.stderr}`);
    const checkouts = path.join(runRoot, "build", "checkouts");
    fs.mkdirSync(checkouts, { recursive: true });
    const first = path.join(runRoot, "inputs-first.json");
    const second = path.join(runRoot, "inputs-second.json");
    const common = [
      "build-input-manifest",
      "--workspace", workspace,
      "--source-snapshot", payload.snapshot,
      "--source-manifest", payload.manifest,
      "--package-resolved", path.join(workspace, "Package.resolved"),
      "--checkouts", checkouts,
      "--build-flag", "--jobs=2",
      "--native-source", "Tools/TatwoPLGAnchorHelper/main.c",
      "--native-compile-flag", "-Os",
      "--native-compile-flag", "-framework",
      "--native-compile-flag", "Security",
      "--native-strip-flag", "-S",
      ...provenanceNodeArgs(),
      "--env", "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
    ];
    const firstResult = runTool([...common, "--output", first], {
      tempRoot: runRoot,
    });
    const secondResult = runTool([...common, "--output", second], {
      tempRoot: runRoot,
    });
    assert.equal(firstResult.status, 0, `${firstResult.stdout}${firstResult.stderr}`);
    assert.equal(secondResult.status, 0, `${secondResult.stdout}${secondResult.stderr}`);
    assert.deepEqual(fs.readFileSync(first), fs.readFileSync(second));
    const manifest = JSON.parse(fs.readFileSync(first, "utf8"));
    assert.equal(manifest.schema, "TatwoBuildInputManifestV1");
    assert.equal(manifest.source.sourceTree, payload.value.sourceTree);
    assert.equal(manifest.dependencies.dependencies.length, 0);
    assert.deepEqual(manifest.buildFlags, ["--jobs=2"]);
    assert.equal(manifest.environment[0].key, "PATH");
    assert.equal("value" in manifest.environment[0], false);
    assert.equal(typeof manifest.toolchain.swift, "string");
    assert.equal(typeof manifest.toolchain.clang, "string");
    assert.equal(typeof manifest.toolchain.xcode, "string");
    assert.equal(typeof manifest.toolchain.sdkVersion, "string");
    assert.equal(typeof manifest.architecture.uname, "string");
    assert.deepEqual(
      manifest.nativeBuild.sources.paths,
      ["Tools/TatwoPLGAnchorHelper/main.c"],
    );
    assert.deepEqual(
      manifest.nativeBuild.compileFlags,
      ["-Os", "-framework", "Security"],
    );
    assert.deepEqual(manifest.nativeBuild.stripFlags, ["-S"]);
    assert.equal(
      manifest.nativeBuild.sources.entries[0].path,
      "Tools/TatwoPLGAnchorHelper/main.c",
    );
    assert.match(
      manifest.nativeBuild.sources.entries[0].sha256,
      /^[0-9a-f]{64}$/u,
    );
    for (const toolName of ["clang", "strip"]) {
      const identity = manifest.nativeBuild.tools[toolName];
      assert.equal(identity.name, toolName);
      assert.match(identity.binarySHA256, /^[0-9a-f]{64}$/u);
      assert.match(identity.pathSHA256, /^[0-9a-f]{64}$/u);
      assert.ok(identity.binaryByteCount > 0);
      assert.ok(identity.machOUUIDs.length > 0);
    }
    assert.equal(
      manifest.provenanceRuntime.node.binarySHA256,
      sha256(fs.readFileSync(fs.realpathSync(process.execPath))),
    );
    assert.equal(
      manifest.provenanceRuntime.node.version,
      process.version,
    );

    fs.writeFileSync(
      path.join(workspace, "Tools", "TatwoPLGAnchorHelper", "main.c"),
      "int main(void) { return 9; }\n",
    );
    const sourceDrift = path.join(runRoot, "inputs-source-drift.json");
    const sourceDriftResult = runTool([...common, "--output", sourceDrift], {
      tempRoot: runRoot,
    });
    assert.equal(
      sourceDriftResult.status,
      0,
      `${sourceDriftResult.stdout}${sourceDriftResult.stderr}`,
    );
    assert.notDeepEqual(
      fs.readFileSync(sourceDrift),
      fs.readFileSync(first),
      "native helper source drift must change the closed-world manifest",
    );

    const flagDrift = path.join(runRoot, "inputs-flag-drift.json");
    const changedFlags = common.flatMap((value) => (
      value === "-Os" ? ["-O0"] : [value]
    ));
    const flagDriftResult = runTool(
      [...changedFlags, "--output", flagDrift],
      { tempRoot: runRoot },
    );
    assert.equal(
      flagDriftResult.status,
      0,
      `${flagDriftResult.stdout}${flagDriftResult.stderr}`,
    );
    assert.notDeepEqual(
      fs.readFileSync(flagDrift),
      fs.readFileSync(sourceDrift),
      "native helper compile flag drift must change the closed-world manifest",
    );
  } finally {
    fs.rmSync(repo, { recursive: true, force: true });
    fs.rmSync(runRoot, { recursive: true, force: true });
  }
});

test("closed-world toolchain identity ignores ambient PATH shims", () => {
  const repo = createFixtureRepo();
  const runRoot = fs.mkdtempSync(path.join(tempBase, "toolchain-path-run-"));
  try {
    const payload = createSnapshot(repo, runRoot);
    const workspace = path.join(runRoot, "workspace");
    const extract = runTool([
      "extract-source",
      "--archive", payload.archive,
      "--manifest", payload.manifest,
      "--snapshot", payload.snapshot,
      "--expected-tree", payload.value.sourceTree,
      "--destination", workspace,
    ], { tempRoot: runRoot });
    assert.equal(extract.status, 0, `${extract.stdout}${extract.stderr}`);
    const checkouts = path.join(runRoot, "build", "checkouts");
    fs.mkdirSync(checkouts, { recursive: true });
    const fakeBin = path.join(runRoot, "ambient-bin");
    const marker = path.join(runRoot, "ambient-tool-ran");
    fs.mkdirSync(fakeBin);
    for (const command of ["node", "xcrun", "swift", "xcodebuild", "uname"]) {
      fs.writeFileSync(
        path.join(fakeBin, command),
        `#!/bin/sh\nprintf '%s\\n' ${JSON.stringify(command)} >> ${JSON.stringify(marker)}\nexit 97\n`,
        { mode: 0o755 },
      );
    }
    const output = path.join(runRoot, "inputs.json");
    const result = runTool([
      "build-input-manifest",
      "--workspace", workspace,
      "--source-snapshot", payload.snapshot,
      "--source-manifest", payload.manifest,
      "--package-resolved", path.join(workspace, "Package.resolved"),
      "--checkouts", checkouts,
      "--output", output,
      "--build-flag", "--jobs=2",
      "--native-source", "Tools/TatwoPLGAnchorHelper/main.c",
      "--native-compile-flag", "-Os",
      "--native-strip-flag", "-S",
      ...provenanceNodeArgs(),
      "--env", "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
    ], {
      env: { PATH: `${fakeBin}:/usr/bin:/bin:/usr/sbin:/sbin` },
      tempRoot: runRoot,
    });
    assert.equal(result.status, 0, `${result.stdout}${result.stderr}`);
    assert.equal(
      fs.existsSync(marker),
      false,
      "ambient PATH toolchain shims must never run",
    );
  } finally {
    fs.rmSync(repo, { recursive: true, force: true });
    fs.rmSync(runRoot, { recursive: true, force: true });
  }
});

test("closed-world native helper source rejects a symlink to ambient bytes", () => {
  const repo = createFixtureRepo();
  const runRoot = fs.mkdtempSync(path.join(tempBase, "native-symlink-run-"));
  try {
    const payload = createSnapshot(repo, runRoot);
    const workspace = path.join(runRoot, "workspace");
    const extract = runTool([
      "extract-source",
      "--archive", payload.archive,
      "--manifest", payload.manifest,
      "--snapshot", payload.snapshot,
      "--expected-tree", payload.value.sourceTree,
      "--destination", workspace,
    ], { tempRoot: runRoot });
    assert.equal(extract.status, 0, `${extract.stdout}${extract.stderr}`);
    const ambientSource = path.join(runRoot, "ambient-main.c");
    fs.writeFileSync(ambientSource, "int main(void) { return 77; }\n");
    const helperSource = path.join(
      workspace,
      "Tools",
      "TatwoPLGAnchorHelper",
      "main.c",
    );
    fs.unlinkSync(helperSource);
    fs.symlinkSync(ambientSource, helperSource);
    const checkouts = path.join(runRoot, "build", "checkouts");
    fs.mkdirSync(checkouts, { recursive: true });
    const result = runTool([
      "build-input-manifest",
      "--workspace", workspace,
      "--source-snapshot", payload.snapshot,
      "--source-manifest", payload.manifest,
      "--package-resolved", path.join(workspace, "Package.resolved"),
      "--checkouts", checkouts,
      "--output", path.join(runRoot, "inputs.json"),
      "--build-flag", "--jobs=2",
      "--native-source", "Tools/TatwoPLGAnchorHelper/main.c",
      "--native-compile-flag", "-Os",
      "--native-strip-flag", "-S",
      ...provenanceNodeArgs(),
      "--env", "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
    ], { tempRoot: runRoot });
    assert.notEqual(result.status, 0, `${result.stdout}${result.stderr}`);
    assert.match(result.stderr, /regular non-symlink file/u);
  } finally {
    fs.rmSync(repo, { recursive: true, force: true });
    fs.rmSync(runRoot, { recursive: true, force: true });
  }
});

for (const [label, relative] of [
  ["build-output drift", "release/TatwoUltraworkMac"],
  ["staged-resource drift", "Tatwo Ultrawork.app/Contents/Resources/value.json"],
]) {
  test(`${label} fails closed against its captured filesystem manifest`, () => {
    const runRoot = fs.mkdtempSync(path.join(tempBase, "manifest-run-"));
    try {
      const manifestRoot = path.join(runRoot, "artifact");
      const file = path.join(manifestRoot, relative);
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, "before\n");
      const manifest = path.join(runRoot, "manifest.json");
      const capture = runTool([
        "fs-manifest",
        "--root", manifestRoot,
        "--path", ".",
        "--output", manifest,
      ], { tempRoot: runRoot });
      assert.equal(capture.status, 0, `${capture.stdout}${capture.stderr}`);
      fs.writeFileSync(file, "after\n");
      const verify = runTool([
        "verify-fs-manifest",
        "--root", manifestRoot,
        "--manifest", manifest,
      ], { tempRoot: runRoot });
      assert.notEqual(verify.status, 0, `${verify.stdout}${verify.stderr}`);
      assert.match(verify.stderr, /filesystem manifest drift detected/u);
    } finally {
      fs.rmSync(runRoot, { recursive: true, force: true });
    }
  });
}

test("bundle identity rejects installed embedded provenance drift", () => {
  const runRoot = fs.mkdtempSync(path.join(tempBase, "readback-run-"));
  try {
    const fixture = createBundleFixture(path.join(runRoot, "staged"));
    const staged = fixture.bundle;
    const installed = path.join(runRoot, "installed", "Tatwo Ultrawork.app");
    bindBundleAuthority(runRoot, fixture);
    const stagedManifest = path.join(runRoot, "staged-manifest.json");
    const stagedIdentity = path.join(runRoot, "staged-identity.json");
    assert.equal(runTool([
      "fs-manifest", "--root", staged, "--path", ".", "--output", stagedManifest,
    ], { tempRoot: runRoot }).status, 0);
    assert.equal(runTool([
      "bundle-identity",
      "--bundle", staged,
      "--manifest", stagedManifest,
      "--output", stagedIdentity,
      "--codesign-required", "0",
    ], { tempRoot: runRoot }).status, 0);

    fs.cpSync(staged, installed, {
      recursive: true,
      verbatimSymlinks: true,
    });
    fs.appendFileSync(
      path.join(installed, "Contents", "Resources", "TatwoCandidateProvenance.json"),
      "tamper\n",
    );
    const installedManifest = path.join(runRoot, "installed-manifest.json");
    const installedIdentity = path.join(runRoot, "installed-identity.json");
    assert.equal(runTool([
      "fs-manifest", "--root", installed, "--path", ".", "--output", installedManifest,
    ], { tempRoot: runRoot }).status, 0);
    const installedResult = runTool([
      "bundle-identity",
      "--bundle", installed,
      "--manifest", installedManifest,
      "--output", installedIdentity,
      "--codesign-required", "0",
    ], { tempRoot: runRoot });
    assert.notEqual(installedResult.status, 0);
    assert.match(
      installedResult.stderr,
      /embedded provenance digest binding failed/u,
    );
  } finally {
    fs.rmSync(runRoot, { recursive: true, force: true });
  }
});

test("bundle identity enforces CandidateID, embedded source/build manifests, and embedded provenance pins", () => {
  for (const attack of [
    {
      expected: /embedded Candidate provenance binding failed: candidateID/u,
      label: "candidate-id",
      mutate: ({ authority }) => {
        run(
          "/usr/bin/plutil",
          [
            "-replace",
            "TatwoCandidateID",
            "-string",
            "9".repeat(64),
            authority.infoPlist,
          ],
        );
      },
    },
    {
      expected: /bundle content manifest drift detected/u,
      label: "build-input-manifest",
      mutate: ({ fixture }) => {
        fs.appendFileSync(
          path.join(
            fixture.bundle,
            "Contents",
            "Resources",
            "TatwoProvenance",
            "TatwoBuildInputManifestV1.json",
          ),
          "tamper\n",
        );
      },
    },
    {
      expected: /embedded provenance digest binding failed/u,
      label: "embedded-provenance",
      mutate: ({ fixture }) => {
        fs.appendFileSync(
          path.join(
            fixture.bundle,
            "Contents",
            "Resources",
            "TatwoCandidateProvenance.json",
          ),
          "tamper\n",
        );
      },
    },
  ]) {
    const runRoot = fs.mkdtempSync(
      path.join(tempBase, `bundle-authority-${attack.label}-`),
    );
    try {
      const fixture = createBundleFixture(runRoot);
      const authority = bindBundleAuthority(runRoot, fixture);
      run(
        "/usr/bin/codesign",
        ["-s", "-", "--force", "--timestamp=none", fixture.bundle],
      );
      attack.mutate({ authority, fixture });
      run(
        "/usr/bin/codesign",
        ["-s", "-", "--force", "--timestamp=none", fixture.bundle],
      );
      const filesystemManifest = path.join(
        runRoot,
        "attacked-filesystem-manifest.json",
      );
      assert.equal(runTool([
        "fs-manifest",
        "--root", fixture.bundle,
        "--path", ".",
        "--output", filesystemManifest,
      ], { tempRoot: runRoot }).status, 0);
      const identity = runTool([
        "bundle-identity",
        "--bundle", fixture.bundle,
        "--manifest", filesystemManifest,
        "--output", path.join(runRoot, "identity.json"),
        "--codesign-required", "1",
      ], { tempRoot: runRoot });
      assert.notEqual(
        identity.status,
        0,
        `${attack.label}\n${identity.stdout}${identity.stderr}`,
      );
      assert.match(identity.stderr, attack.expected);
    } finally {
      fs.rmSync(runRoot, { recursive: true, force: true });
    }
  }
});

test("bundle content manifest is deterministic across Info, provenance, manifest, and code-signature changes", () => {
  const runRoot = fs.mkdtempSync(path.join(tempBase, "bundle-content-stable-"));
  try {
    const fixture = createBundleFixture(runRoot);
    const first = captureBundleContentManifest(runRoot, fixture, "first");
    const embedded = path.join(
      fixture.bundle,
      "Contents",
      "Resources",
      "TatwoBundleContentManifestV1.json",
    );
    fs.copyFileSync(first.manifest, embedded);

    const entryPaths = first.value.entries.map((entry) => entry.path);
    for (const requiredPath of [
      "Contents/MacOS/TatwoUltraworkMac",
      "Contents/Helpers/TatwoPLGAnchorHelper",
      "Contents/Resources/fixture.json",
      "Contents/Resources/Nested/payload.txt",
      "Contents/Frameworks/Fixture.framework/Versions/A/Fixture",
      "Contents/Frameworks/Fixture.framework/Fixture",
    ]) {
      assert.ok(entryPaths.includes(requiredPath), requiredPath);
    }
    assert.equal(
      first.value.mainExecutable.sha256,
      first.result.mainExecutableSHA256,
    );

    fs.writeFileSync(
      path.join(fixture.bundle, "Contents", "Info.plist"),
      "<plist><dict><key>Fixture</key><string>two</string></dict></plist>\n",
    );
    fs.writeFileSync(
      path.join(
        fixture.bundle,
        "Contents",
        "Resources",
        "TatwoCandidateProvenance.json",
      ),
      '{"candidate":"two"}\n',
    );
    fs.writeFileSync(
      path.join(fixture.bundle, "Contents", "_CodeSignature", "CodeResources"),
      "top signature two\n",
    );
    fs.writeFileSync(
      path.join(
        fixture.bundle,
        "Contents",
        "Frameworks",
        "Fixture.framework",
        "Versions",
        "A",
        "_CodeSignature",
        "CodeResources",
      ),
      "nested signature two\n",
    );
    run(
      "/usr/bin/codesign",
      ["-s", "-", "--force", "--timestamp=none", fixture.main],
    );

    const second = captureBundleContentManifest(runRoot, fixture, "second");
    assert.deepEqual(
      fs.readFileSync(second.manifest),
      fs.readFileSync(first.manifest),
    );
    const verify = runTool([
      "verify-bundle-content-manifest",
      "--bundle", fixture.bundle,
      "--manifest", embedded,
    ], { tempRoot: runRoot });
    assert.equal(verify.status, 0, `${verify.stdout}${verify.stderr}`);
  } finally {
    fs.rmSync(runRoot, { recursive: true, force: true });
  }
});

test("bundle content manifest fails closed when only the main executable changes", () => {
  const runRoot = fs.mkdtempSync(path.join(tempBase, "bundle-content-main-"));
  try {
    const fixture = createBundleFixture(runRoot);
    const captured = captureBundleContentManifest(runRoot, fixture, "manifest");
    const helperBefore = sha256(fs.readFileSync(fixture.helper));
    fs.copyFileSync("/bin/cat", fixture.main);
    fs.chmodSync(fixture.main, 0o755);
    run(
      "/usr/bin/codesign",
      ["-s", "-", "--force", "--timestamp=none", fixture.main],
    );
    assert.equal(sha256(fs.readFileSync(fixture.helper)), helperBefore);

    const verify = runTool([
      "verify-bundle-content-manifest",
      "--bundle", fixture.bundle,
      "--manifest", captured.manifest,
    ], { tempRoot: runRoot });
    assert.notEqual(verify.status, 0, `${verify.stdout}${verify.stderr}`);
    assert.match(
      verify.stderr,
      /bundle content manifest main executable drift detected/u,
    );
    assert.match(verify.stderr, /Contents\/MacOS\/TatwoUltraworkMac/u);
  } finally {
    fs.rmSync(runRoot, { recursive: true, force: true });
  }
});

test("ad-hoc re-sign cannot hide main or nested-content replacement while helper and Info.plist stay unchanged", () => {
  for (const attack of [
    {
      expected: /bundle content manifest main executable drift detected/u,
      label: "main",
      mutate: (fixture) => {
        fs.copyFileSync("/bin/cat", fixture.main);
        fs.chmodSync(fixture.main, 0o755);
      },
    },
    {
      expected: /changed=Contents\/Resources\/Nested\/payload\.txt/u,
      label: "nested-content",
      mutate: (fixture) => {
        fs.writeFileSync(fixture.nestedResource, "replacement payload\n");
      },
    },
  ]) {
    const runRoot = fs.mkdtempSync(
      path.join(tempBase, `bundle-content-adhoc-${attack.label}-`),
    );
    try {
      const fixture = createBundleFixture(runRoot);
      const authority = bindBundleAuthority(runRoot, fixture);
      run(
        "/usr/bin/codesign",
        ["-s", "-", "--force", "--timestamp=none", fixture.bundle],
      );
      const infoPlist = authority.infoPlist;
      const helperBefore = fs.readFileSync(fixture.helper);
      const infoBefore = fs.readFileSync(infoPlist);

      attack.mutate(fixture);
      run(
        "/usr/bin/codesign",
        ["-s", "-", "--force", "--timestamp=none", fixture.bundle],
      );
      assert.deepEqual(
        fs.readFileSync(fixture.helper),
        helperBefore,
        `${attack.label}: helper bytes must stay unchanged`,
      );
      assert.deepEqual(
        fs.readFileSync(infoPlist),
        infoBefore,
        `${attack.label}: Info.plist bytes must stay unchanged`,
      );

      const verify = runTool([
        "verify-bundle-content-manifest",
        "--bundle", fixture.bundle,
        "--manifest", authority.manifestPath,
      ], { tempRoot: runRoot });
      assert.notEqual(
        verify.status,
        0,
        `${attack.label}\n${verify.stdout}${verify.stderr}`,
      );
      assert.match(verify.stderr, attack.expected);

      const currentFilesystemManifest = path.join(
        runRoot,
        "current-filesystem-manifest.json",
      );
      assert.equal(runTool([
        "fs-manifest",
        "--root", fixture.bundle,
        "--path", ".",
        "--output", currentFilesystemManifest,
      ], { tempRoot: runRoot }).status, 0);
      const identity = runTool([
        "bundle-identity",
        "--bundle", fixture.bundle,
        "--manifest", currentFilesystemManifest,
        "--output", path.join(runRoot, "forged-identity.json"),
        "--codesign-required", "1",
      ], { tempRoot: runRoot });
      assert.notEqual(
        identity.status,
        0,
        `${attack.label} authority identity unexpectedly passed\n`
          + `${identity.stdout}${identity.stderr}`,
      );
      assert.match(
        identity.stderr,
        /bundle content manifest (?:main executable )?drift detected/u,
      );
    } finally {
      fs.rmSync(runRoot, { recursive: true, force: true });
    }
  }
});

test("bundle content manifest fails closed for resource, helper, and nested-code drift", () => {
  for (const mutation of [
    {
      label: "resource",
      mutate: (fixture) => fs.appendFileSync(fixture.resource, "tamper\n"),
      path: "Contents/Resources/fixture.json",
    },
    {
      label: "helper",
      mutate: (fixture) => {
        fs.copyFileSync("/bin/cat", fixture.helper);
        fs.chmodSync(fixture.helper, 0o755);
      },
      path: "Contents/Helpers/TatwoPLGAnchorHelper",
    },
    {
      label: "nested code",
      mutate: (fixture) => {
        fs.copyFileSync("/bin/cat", fixture.nested);
        fs.chmodSync(fixture.nested, 0o755);
      },
      path: "Contents/Frameworks/Fixture.framework/Versions/A/Fixture",
    },
  ]) {
    const runRoot = fs.mkdtempSync(
      path.join(tempBase, `bundle-content-${mutation.label.replaceAll(" ", "-")}-`),
    );
    try {
      const fixture = createBundleFixture(runRoot);
      const captured = captureBundleContentManifest(runRoot, fixture, "manifest");
      mutation.mutate(fixture);
      const verify = runTool([
        "verify-bundle-content-manifest",
        "--bundle", fixture.bundle,
        "--manifest", captured.manifest,
      ], { tempRoot: runRoot });
      assert.notEqual(
        verify.status,
        0,
        `${mutation.label}\n${verify.stdout}${verify.stderr}`,
      );
      assert.match(verify.stderr, /bundle content manifest drift detected/u);
      assert.match(verify.stderr, new RegExp(mutation.path.replaceAll("/", "\\/"), "u"));
    } finally {
      fs.rmSync(runRoot, { recursive: true, force: true });
    }
  }
});
