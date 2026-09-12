#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const appRoot = "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac";

const audits = {
  goal: {
    script: "scripts/tatwo-workos-goal-audit.mjs",
    requiredPaths: [
      `${appRoot}/UltraPage.swift`,
      `${appRoot}/UltraPageModels.swift`,
      `${appRoot}/UltraPageArchitectureData.swift`,
      `${appRoot}/PLGFlowCard.swift`,
      `${appRoot}/ModesPage.swift`,
      `${appRoot}/ScenarioPage.swift`,
      `${appRoot}/AppShell.swift`,
      "script/build_and_run.sh",
    ],
    canonical: {
      path: `${appRoot}/UltraPage.swift`,
      marker: "WorkOSPlanLoopsGoalBlueprintFactory.make(contract: contract)",
      replacement: "WorkOSPlanLoopsGoalBlueprintFactory.makeLegacy(contract: contract)",
    },
  },
  dashboard: {
    script: "scripts/tatwo-dashboard-console-audit.mjs",
    requiredPaths: [
      `${appRoot}/UltraPage.swift`,
      `${appRoot}/UltraPageModels.swift`,
      `${appRoot}/UltraPageArchitectureData.swift`,
      `${appRoot}/PLGFlowCard.swift`,
      `${appRoot}/AppShell.swift`,
    ],
    canonical: {
      path: `${appRoot}/UltraPage.swift`,
      marker: "UltraArchitectureManifestSourceCard(compact: surface == .panel)",
      replacement: "UltraArchitectureManifestSourceCard(compact: false)",
    },
  },
  dropdown: {
    script: "scripts/tatwo-ui-dropdown-loop-check.mjs",
    requiredPaths: [
      `${appRoot}/ModesPage.swift`,
      `${appRoot}/ScenarioPage.swift`,
      `${appRoot}/TraitsPage.swift`,
      `${appRoot}/PluginsPage.swift`,
      `${appRoot}/UltraPage.swift`,
    ],
    canonical: {
      // Wave 1 後符號更名／移除：ScenarioOSConfigurationBar( → ScenarioWorkflowPresentationCard(
      // 稽核意圖：情境頁必須維持唯讀 Plan/Loops/Goal 投影，不得回退成可編輯 OS 設定條。
      path: `${appRoot}/ScenarioPage.swift`,
      marker: "ScenarioWorkflowPresentationCard(",
      // Replacement must not contain the marker as a substring (prefix Legacy… still matches).
      replacement: "ScenarioWorkflowPresentationCardRemoved(",
    },
  },
  usage: {
    script: "scripts/tatwo-ui-usage-live-check.mjs",
    requiredPaths: [
      `${appRoot}/TatwoM3PrototypeViews.swift`,
      `${appRoot}/HeaderQuotaStrip.swift`,
      `${appRoot}/AppShell.swift`,
      "Package.swift",
      "Packages/AISwitchProviders/Sources/AISwitchProviders/CodexV3ImportStore.swift",
      "script/build_and_run.sh",
    ],
    canonical: {
      path: `${appRoot}/TatwoM3PrototypeViews.swift`,
      marker: 'QuotaWindowBar(title: "5小時"',
      replacement: 'QuotaWindowBar(title: "舊視窗"',
    },
  },
  copy: {
    script: "scripts/tatwo-ui-copy-lint.mjs",
    requiredPaths: [
      `${appRoot}/ModesPage.swift`,
      `${appRoot}/ScenarioPage.swift`,
      `${appRoot}/TraitsPage.swift`,
      `${appRoot}/PluginsPage.swift`,
      `${appRoot}/UltraPage.swift`,
      `${appRoot}/PLGFlowCard.swift`,
      `${appRoot}/TatwoM3PrototypeViews.swift`,
      `${appRoot}/HeaderQuotaStrip.swift`,
      `${appRoot}/AppShell.swift`,
    ],
    canonical: {
      path: `${appRoot}/PLGFlowCard.swift`,
      marker: 'Text("PLG 流程")',
      replacement: 'Text("PLG")',
    },
  },
};

await testRealAuditsExposeDeterministicMigrationReceipts();
await testMissingRequiredSourceFailsClosed();
await testCommentOnlyMarkerDoesNotPass();
await testDropdownDoesNotSatisfyMarkerAcrossFiles();
await testRemovingCanonicalMarkerFailsEveryAudit();
await testCopyLintCoversScenarioWorkflowPresentationCard();
await testCopyLintCoversEmptyStateStripText();
await testCopyLintCoversLabelAndBadge();
await testUsageResetCreditEndpointIsScopedToQueryUsage();

async function testRealAuditsExposeDeterministicMigrationReceipts() {
  for (const [id, audit] of Object.entries(audits)) {
    const first = runAudit(audit, repoRoot);
    const second = runAudit(audit, repoRoot);
    assert.equal(first.stdout, second.stdout, `${id} audit stdout must be deterministic`);
    const receipt = parseReceipt(first, id);
    assert.equal(first.status, receipt.ok ? 0 : 1, `${id} exit code must match receipt.ok`);
    assert.equal(receipt.sourceSnapshot.algorithm, "sha256", `${id} must emit a source snapshot`);
    assert.deepEqual(
      receipt.sourceSnapshot.files.map(file => file.path),
      audit.requiredPaths,
      `${id} must use the explicit required-source manifest`,
    );
    assert.ok(
      receipt.sourceSnapshot.files.every(file => /^[a-f0-9]{64}$/.test(file.sha256)),
      `${id} source hashes must be SHA-256`,
    );
    assert.ok(Array.isArray(receipt.contractMigrations), `${id} must emit contractMigrations`);
    assertStructuredRed(receipt, id);
  }
}

async function testMissingRequiredSourceFailsClosed() {
  for (const [id, audit] of Object.entries(audits)) {
    await withFixture(audit.requiredPaths, async root => {
      await fs.rm(path.join(root, audit.requiredPaths[0]));
      const run = runAudit(audit, root);
      const receipt = parseReceipt(run, `${id} missing source`);
      assert.equal(run.status, 1);
      assert.equal(receipt.ok, false);
      assert.match(JSON.stringify(receipt), /missing required source/i);
      assertStructuredRed(receipt, `${id} missing source`);
    });
  }
}

async function testCommentOnlyMarkerDoesNotPass() {
  const audit = audits.dashboard;
  await withFixture(audit.requiredPaths, async root => {
    const relativePath = `${appRoot}/UltraPage.swift`;
    const file = path.join(root, relativePath);
    const marker = "UltraManualHero(snapshot: snapshot, surface: surface)";
    await mutateFile(file, marker, `// ${marker}`);
    const run = runAudit(audit, root);
    const receipt = parseReceipt(run, "dashboard comment-only marker");
    assert.equal(run.status, 1);
    assert.ok(receipt.findings.some(finding =>
      finding.sourcePath === relativePath
      && finding.symbol === "WorkflowPage"
      && finding.classification === "candidate-regression"
    ));
    assertStructuredRed(receipt, "dashboard comment-only marker");
  });
}

async function testDropdownDoesNotSatisfyMarkerAcrossFiles() {
  const audit = audits.dropdown;
  await withFixture(audit.requiredPaths, async root => {
    const modesPath = path.join(root, `${appRoot}/ModesPage.swift`);
    const pluginsPath = path.join(root, `${appRoot}/PluginsPage.swift`);
    const marker = "WorkOSShowLoopsCard(contract: osContract)";
    await mutateFile(modesPath, marker, "EmptyStateStrip(text: \"missing mode show loops\")");
    await mutateFile(
      pluginsPath,
      "    var body: some View {",
      `    private var crossFileDecoy: some View { ${marker} }\n\n    var body: some View {`,
    );

    const run = runAudit(audit, root);
    const receipt = parseReceipt(run, "dropdown cross-file marker");
    assert.equal(run.status, 1);
    assert.ok(receipt.findings.some(finding =>
      finding.sourcePath === `${appRoot}/ModesPage.swift`
      && finding.symbol === "ModesPage"
    ));
    assertStructuredRed(receipt, "dropdown cross-file marker");
  });
}

async function testRemovingCanonicalMarkerFailsEveryAudit() {
  for (const [id, audit] of Object.entries(audits)) {
    await withFixture(audit.requiredPaths, async root => {
      const file = path.join(root, audit.canonical.path);
      await mutateFile(file, audit.canonical.marker, audit.canonical.replacement);
      const run = runAudit(audit, root);
      const receipt = parseReceipt(run, `${id} canonical mutation`);
      assert.equal(run.status, 1, `${id} must fail when its canonical marker is removed`);
      assert.equal(receipt.ok, false);
      assertStructuredRed(receipt, `${id} canonical mutation`);
    });
  }
}

async function testCopyLintCoversScenarioWorkflowPresentationCard() {
  // Wave 1 後符號更名／移除：ScenarioGraphNodeInlineEditor 已刪；改守 ScenarioWorkflowPresentationCard。
  const audit = audits.copy;
  await withFixture(audit.requiredPaths, async root => {
    const relativePath = `${appRoot}/ScenarioPage.swift`;
    const file = path.join(root, relativePath);
    const literal = "COPY_UNLISTED_SYMBOL_MUTATION_MUST_BE_REPORTED";
    await mutateFile(
      file,
      'Text("無法投影目前情境的 workflow contract。")',
      `Text("${literal}")`,
    );

    const run = runAudit(audit, root);
    const receipt = parseReceipt(run, "copy presentation card mutation");
    assert.equal(run.status, 1);
    assert.ok(receipt.findings.some(finding =>
      finding.kind === "long_visible_literal"
      && finding.sourcePath === relativePath
      && finding.symbol === "ScenarioWorkflowPresentationCard"
      && finding.literal === literal
    ));
    assertStructuredRed(receipt, "copy presentation card mutation");
  });
}

async function testCopyLintCoversEmptyStateStripText() {
  const audit = audits.copy;
  await withFixture(audit.requiredPaths, async root => {
    const relativePath = `${appRoot}/ModesPage.swift`;
    const file = path.join(root, relativePath);
    const literal = "COPY_EMPTY_STATE_STRIP_MUTATION_MUST_BE_REPORTED";
    await mutateFile(
      file,
      'EmptyStateStrip(text: "Work OS contract 建立失敗；模式頁只顯示規劃，不可放行")',
      `EmptyStateStrip(text: "${literal}")`,
    );

    const run = runAudit(audit, root);
    const receipt = parseReceipt(run, "copy EmptyStateStrip mutation");
    assert.equal(run.status, 1);
    assert.ok(receipt.findings.some(finding =>
      finding.kind === "long_visible_literal"
      && finding.sourcePath === relativePath
      && finding.symbol === "ModeDashboardSurface"
      && finding.literal === literal
    ));
    assertStructuredRed(receipt, "copy EmptyStateStrip mutation");
  });
}

async function testCopyLintCoversLabelAndBadge() {
  const audit = audits.copy;
  const cases = [
    {
      // Wave 1 後符號更名／移除：Label("情境 Work OS" / ScenarioOSConfigurationBar → 唯讀投影卡標題。
      relativePath: `${appRoot}/ScenarioPage.swift`,
      marker: 'Label("Plan + Loops Cycle + Goal"',
      replacement: 'Label("COPY_LABEL_MUTATION_MUST_BE_REPORTED_BEYOND_LIMIT"',
      symbol: "ScenarioWorkflowPresentationCard",
      literal: "COPY_LABEL_MUTATION_MUST_BE_REPORTED_BEYOND_LIMIT",
      invocation: "Label",
    },
    {
      // ModesPage 已無 Badge("S 直修")；ModeDifferenceCard 仍有靜態 Badge("套用") 可作 mutation 錨點。
      relativePath: `${appRoot}/ModesPage.swift`,
      marker: 'Badge("套用")',
      replacement: 'Badge("COPY_BADGE_MUTATION_MUST_BE_REPORTED_BEYOND_LIMIT")',
      symbol: "ModeDifferenceCard",
      literal: "COPY_BADGE_MUTATION_MUST_BE_REPORTED_BEYOND_LIMIT",
      invocation: "Badge",
    },
  ];

  for (const testCase of cases) {
    await withFixture(audit.requiredPaths, async root => {
      await mutateFile(
        path.join(root, testCase.relativePath),
        testCase.marker,
        testCase.replacement,
      );

      const run = runAudit(audit, root);
      const receipt = parseReceipt(run, `copy ${testCase.invocation} mutation`);
      assert.equal(run.status, 1);
      assert.ok(receipt.findings.some(finding =>
        finding.kind === "long_visible_literal"
        && finding.sourcePath === testCase.relativePath
        && finding.symbol === testCase.symbol
        && finding.invocation === testCase.invocation
        && finding.literal === testCase.literal
      ));
      assertStructuredRed(receipt, `copy ${testCase.invocation} mutation`);
    });
  }
}

async function testUsageResetCreditEndpointIsScopedToQueryUsage() {
  const audit = audits.usage;
  await withFixture(audit.requiredPaths, async root => {
    const relativePath = "Packages/AISwitchProviders/Sources/AISwitchProviders/CodexV3ImportStore.swift";
    const file = path.join(root, relativePath);
    const endpoint = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits";
    await mutateFile(file, endpoint, `${endpoint}-legacy`);
    await mutateFile(
      file,
      "private final class CodexUsageClient",
      `private let resetCreditEndpointDecoy = "${endpoint}"\n\nprivate final class CodexUsageClient`,
    );

    const run = runAudit(audit, root);
    const receipt = parseReceipt(run, "usage reset-credit endpoint decoy");
    assert.equal(run.status, 1);
    assert.ok(receipt.findings.some(finding =>
      finding.id === "usage.store_reset_credit_endpoint"
      && finding.sourcePath === relativePath
      && finding.symbol === "CodexUsageClient.queryUsage"
    ));
    assertStructuredRed(receipt, "usage reset-credit endpoint decoy");
  });
}

async function withFixture(relativePaths, callback) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "tatwo-audit-migration-"));
  try {
    for (const relativePath of relativePaths) {
      const source = path.join(repoRoot, relativePath);
      const destination = path.join(root, relativePath);
      await fs.mkdir(path.dirname(destination), { recursive: true });
      await fs.copyFile(source, destination);
    }
    await callback(root);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
}

async function mutateFile(file, marker, replacement) {
  const source = await fs.readFile(file, "utf8");
  assert.ok(source.includes(marker), `fixture marker must exist: ${marker}`);
  await fs.writeFile(file, source.replace(marker, replacement));
}

function runAudit(audit, cwd) {
  return spawnSync(process.execPath, [path.join(repoRoot, audit.script)], {
    cwd,
    encoding: "utf8",
  });
}

function parseReceipt(run, label) {
  assert.equal(run.signal, null, `${label} must not terminate by signal`);
  assert.ok(run.stdout.trim(), `${label} must emit a JSON receipt: ${run.stderr}`);
  try {
    return JSON.parse(run.stdout);
  } catch (error) {
    assert.fail(`${label} emitted invalid JSON: ${error.message}\nstdout=${run.stdout}\nstderr=${run.stderr}`);
  }
}

function assertStructuredRed(receipt, label) {
  const reds = receipt.findings ?? receipt.checks?.filter(check => !check.ok) ?? [];
  for (const red of reds) {
    assert.equal(typeof red.classification, "string", `${label} RED classification missing`);
    assert.equal(typeof red.sourcePath, "string", `${label} RED sourcePath missing`);
    assert.equal(typeof red.symbol, "string", `${label} RED symbol missing`);
  }
}

console.log("tatwo-static-audit-migration-pages.test.mjs: ok");
