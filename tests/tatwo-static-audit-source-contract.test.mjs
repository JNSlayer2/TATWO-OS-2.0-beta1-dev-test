#!/usr/bin/env node
import assert from "node:assert/strict";
import crypto from "node:crypto";
import { spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  extractSwiftFunctionBody,
  extractSwiftTypeBody,
  readRequiredSources,
  requireSourceMarker,
} from "../scripts/tatwo-static-audit-source-contract.mjs";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const auditScript = path.join(repoRoot, "scripts", "tatwo-plg-cycle-layout-audit.mjs");
const requiredPaths = [
  "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPageModels.swift",
  "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPage.swift",
  "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPageArchitectureData.swift",
];

await testRequiredSourceManifestAndSnapshot();
await testRequiredSourceFailures();
await testRequiredSourceSymlinkFailures();
testSwiftScopedExtraction();
testSwiftFunctionScopedExtraction();
await testAuditScopesMetricsAndComments();
testRealRepoAudit();

async function testRequiredSourceManifestAndSnapshot() {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "tatwo-source-contract-"));
  const relativePath = "Sources/Models.swift";
  const source = "enum Metrics {\n    static let width = 1120\n}\n";
  try {
    await fs.mkdir(path.join(root, "Sources"), { recursive: true });
    await fs.writeFile(path.join(root, relativePath), source);

    const loaded = readRequiredSources({
      root,
      manifest: [{ id: "models", relativePath }],
    });

    assert.equal(loaded.sources.get("models").text, source);
    assert.deepEqual(loaded.sourceSnapshot, {
      algorithm: "sha256",
      files: [{
        id: "models",
        path: relativePath,
        bytes: Buffer.byteLength(source),
        sha256: crypto.createHash("sha256").update(source).digest("hex"),
      }],
    });
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
}

async function testRequiredSourceFailures() {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "tatwo-source-contract-fail-"));
  try {
    assert.throws(
      () => readRequiredSources({
        root,
        manifest: [{ id: "missing", relativePath: "Sources/Missing.swift" }],
      }),
      /missing required source/i,
    );

    await fs.mkdir(path.join(root, "Sources"), { recursive: true });
    await fs.writeFile(path.join(root, "Sources", "Empty.swift"), " \n\t");
    assert.throws(
      () => readRequiredSources({
        root,
        manifest: [{ id: "empty", relativePath: "Sources/Empty.swift" }],
      }),
      /empty required source/i,
    );

    await fs.mkdir(path.join(root, "Sources", "Directory.swift"));
    assert.throws(
      () => readRequiredSources({
        root,
        manifest: [{ id: "directory", relativePath: "Sources/Directory.swift" }],
      }),
      /regular file/i,
    );

    assert.throws(
      () => readRequiredSources({
        root,
        manifest: [{ id: "glob", relativePath: "Sources/*.swift" }],
      }),
      /explicit file path/i,
    );
    assert.throws(
      () => readRequiredSources({
        root,
        manifest: [{ id: "absolute", relativePath: path.join(root, "Sources", "Empty.swift") }],
      }),
      /explicit file path/i,
    );
    assert.throws(
      () => readRequiredSources({
        root,
        manifest: [{ id: "escape", relativePath: "../Outside.swift" }],
      }),
      /explicit file path/i,
    );
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
}

async function testRequiredSourceSymlinkFailures() {
  const fixture = await fs.mkdtemp(path.join(os.tmpdir(), "tatwo-source-contract-symlink-"));
  const root = path.join(fixture, "root");
  const outside = path.join(fixture, "outside");
  const outsideSource = path.join(outside, "Escape.swift");
  try {
    await fs.mkdir(root);
    await fs.mkdir(outside);
    await fs.writeFile(outsideSource, "enum Escaped {}\n");

    await fs.symlink(outsideSource, path.join(root, "Final.swift"));
    assert.throws(
      () => readRequiredSources({
        root,
        manifest: [{ id: "final-symlink", relativePath: "Final.swift" }],
      }),
      /regular file|symlink/i,
      "the final file symlink must remain rejected",
    );

    await fs.symlink(outside, path.join(root, "Sources"));
    assert.throws(
      () => readRequiredSources({
        root,
        manifest: [{ id: "directory-symlink", relativePath: "Sources/Escape.swift" }],
      }),
      /escapes root|symlink/i,
      "an intermediate directory symlink must not expose a regular file outside root",
    );
  } finally {
    await fs.rm(fixture, { recursive: true, force: true });
  }
}

function testSwiftScopedExtraction() {
  const source = `
enum OtherMetrics {
    static let width: CGFloat = 9999
}

// enum WorkOSPlanLoopsGoalMetrics { static let width: CGFloat = 7777 }
enum WorkOSPlanLoopsGoalMetrics {
    // static let width: CGFloat = 6666
    static let width: CGFloat = 1120
    static let note = "a brace in a string must not close the body: }"
    /* marker-only-in-comment */
}
`;

  const body = extractSwiftTypeBody(source, {
    kind: "enum",
    name: "WorkOSPlanLoopsGoalMetrics",
    stripComments: true,
  });
  assert.match(body, /static let width: CGFloat = 1120/);
  assert.doesNotMatch(body, /9999|7777|6666|marker-only-in-comment/);
  assert.throws(
    () => requireSourceMarker(body, "marker-only-in-comment", {
      sourcePath: "UltraPageModels.swift",
      symbol: "WorkOSPlanLoopsGoalMetrics",
    }),
    /missing required marker/i,
  );
  assert.throws(
    () => requireSourceMarker(
      'let decoy = "WorkOSPlanLoopsGoalIdentityColumn(contract: contract)"',
      "WorkOSPlanLoopsGoalIdentityColumn(contract: contract)",
    ),
    /missing required marker/i,
  );
  assert.doesNotThrow(
    () => requireSourceMarker(
      'CGPoint(x: 1084, y: r("lead-pass").midY)',
      'CGPoint(x: 1084, y: r("lead-pass").midY)',
    ),
  );
  assert.throws(
    () => requireSourceMarker(
      'CGPoint(x: 1084, y: r("fake-pass").midY)',
      'CGPoint(x: 1084, y: r("lead-pass").midY)',
    ),
    /missing required marker/i,
  );

  assert.throws(
    () => extractSwiftTypeBody(source, { kind: "enum", name: "MissingMetrics" }),
    /missing Swift enum symbol/i,
  );
  assert.throws(
    () => extractSwiftTypeBody(
      "enum WorkOSPlanLoopsGoalMetrics { static let width: CGFloat = 1120",
      { kind: "enum", name: "WorkOSPlanLoopsGoalMetrics" },
    ),
    /incomplete braces/i,
  );
  assert.throws(
    () => extractSwiftTypeBody(
      "// enum CommentOnly { static let width: CGFloat = 1120 }\n",
      { kind: "enum", name: "CommentOnly" },
    ),
    /missing Swift enum symbol/i,
  );
  assert.throws(
    () => extractSwiftTypeBody(
      "enum Duplicate {} \nenum Duplicate {}",
      { kind: "enum", name: "Duplicate" },
    ),
    /ambiguous Swift enum symbol/i,
  );

  const interpolationBody = extractSwiftTypeBody(String.raw`
struct InterpolationContainer {
    let value = "\(flag ? "}" : "plain")"
    let marker = true
}
`, {
    kind: "struct",
    name: "InterpolationContainer",
  });
  assert.match(interpolationBody, /let marker = true/);
}

function testSwiftFunctionScopedExtraction() {
  const source = String.raw`
struct ConnectorCanvas {
    private func drawRoute(context: inout GraphicsContext) {
        path.addLine(to: point)
        let note = "a brace does not close the function: }"
    }

    private func drawArrowhead(context: inout GraphicsContext) {
        let angle = atan2(1, 1)
    }
}
`;
  const typeBody = extractSwiftTypeBody(source, {
    kind: "struct",
    name: "ConnectorCanvas",
    stripComments: true,
  });
  const routeBody = extractSwiftFunctionBody(typeBody, {
    name: "drawRoute",
    stripComments: true,
  });
  assert.match(routeBody, /path\.addLine/);
  assert.doesNotMatch(routeBody, /atan2/);
  assert.throws(
    () => extractSwiftFunctionBody(typeBody, { name: "missingRoute" }),
    /missing Swift func symbol/i,
  );
  assert.throws(
    () => extractSwiftFunctionBody(
      "func duplicate() {}\nfunc duplicate() {}",
      { name: "duplicate" },
    ),
    /ambiguous Swift func symbol/i,
  );
}

async function testAuditScopesMetricsAndComments() {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "tatwo-layout-audit-fixture-"));
  try {
    await writeAuditFixture(root, {
      targetWidth: 1119,
      commentOnlyMarker: "WorkOSPlanLoopsGoalIdentityColumn(contract: contract)",
    });
    const result = runAudit(root);
    assert.equal(result.status, 1, result.stderr || result.stdout);
    const receipt = JSON.parse(result.stdout);
    assert.equal(receipt.metrics.width, 1119, "width must come from the target enum body");
    assert.ok(
      receipt.findings.some(finding =>
        finding.kind === "canvas_too_narrow_for_left_identity_column"
        && finding.width === 1119),
      "the other enum width must not satisfy the target metric",
    );
    assert.ok(
      receipt.findings.some(finding =>
        finding.kind === "missing_source_guard"
        && finding.id === "identity_column_plain_left"),
      "a required marker present only in a comment must not satisfy the audit",
    );
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
}

function testRealRepoAudit() {
  const result = runAudit(repoRoot);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  const receipt = JSON.parse(result.stdout);
  assert.equal(receipt.ok, true);
  assert.equal(receipt.summary.findings, 0);
  assert.deepEqual(
    receipt.sourceSnapshot.files.map(file => file.path),
    requiredPaths,
  );
  assert.ok(receipt.sourceSnapshot.files.every(file => /^[a-f0-9]{64}$/.test(file.sha256)));
}

async function writeAuditFixture(root, { targetWidth, commentOnlyMarker }) {
  for (const relativePath of requiredPaths) {
    await fs.mkdir(path.dirname(path.join(root, relativePath)), { recursive: true });
  }
  await fs.writeFile(path.join(root, requiredPaths[0]), `
enum OtherMetrics {
    static let width: CGFloat = 9999
}
enum WorkOSPlanLoopsGoalMetrics {
    static let width: CGFloat = ${targetWidth}
    static let height: CGFloat = 820
    static let contentOffsetY: CGFloat = 38
    static let receiptRailY: CGFloat = 786
}
`);
  await fs.writeFile(path.join(root, requiredPaths[1]), `
struct WorkOSPlanLoopsGoalCycleMap {
    // ${commentOnlyMarker}
    var body: some View {
        WorkOSPlanLoopsGoalLegend(modeSummary: blueprint.modeSummary)
            .position(x: 604, y: 27)
        Group {}
            .offset(y: WorkOSPlanLoopsGoalMetrics.contentOffsetY)
    }
}
`);
  await fs.writeFile(path.join(root, requiredPaths[2]), `
enum WorkOSPlanLoopsGoalBlueprintFactory {
    static func connectors() {
        CGPoint(x: 1084, y: r("lead-pass").midY)
        top(r("receipt-bank"))
    }
}
`);
}

function runAudit(cwd) {
  return spawnSync(process.execPath, [auditScript], {
    cwd,
    encoding: "utf8",
  });
}

console.log("tatwo-static-audit-source-contract.test.mjs: ok");
