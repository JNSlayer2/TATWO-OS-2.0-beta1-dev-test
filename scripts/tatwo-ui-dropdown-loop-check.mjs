#!/usr/bin/env node
import {
  extractSwiftTypeBody,
  readRequiredSources,
  requireSourceMarker,
} from "./tatwo-static-audit-source-contract.mjs";

const root = process.cwd();
const manifest = [
  { id: "modes", relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ModesPage.swift" },
  { id: "scenario", relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ScenarioPage.swift" },
  { id: "traits", relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/TraitsPage.swift" },
  { id: "plugins", relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/PluginsPage.swift" },
  { id: "ultra", relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPage.swift" },
];

const contractMigrations = [
  {
    id: "page-block-between",
    classification: "stale-contract",
    legacyContract: "concatenated monolith plus between(startMarker, endMarker)",
    currentEquivalent: "one explicit source file and extractSwiftTypeBody per page/helper symbol",
    justification: "Split pages must not satisfy one another's markers or depend on declaration order across files.",
  },
  {
    id: "private-helper-markers",
    classification: "stale-contract",
    legacyContract: "private struct helper declarations",
    currentEquivalent: "current non-private ModeDashboardSurface, ModeDifferenceCard, ScenarioWorkflowPresentationCard, DropdownSelectButton, and TraitFolderSection",
    justification: "The helper types became module-visible during the split; behavior is scoped by symbol rather than access-control text.",
  },
  {
    id: "scenario.wave1_readonly_presentation",
    classification: "stale-contract",
    // Wave 1 後符號更名／移除，此處對應新符號。
    legacyContract: "ScenarioOSConfigurationBar + ScenarioWorkflowCanvasCard editable OS config / canvas CRUD",
    currentEquivalent: "ScenarioGateSummaryCard + ScenarioWorkflowPresentationCard + ScenarioSavedCanvasVersionsRail (read-only Plan/Loops/Goal)",
    justification: "Wave 1 (2026-07-29) removed in-page scenario OS configuration and interactive canvas; page is a read-only workflow projection. Auth config remains OS/MCP, not page CRUD.",
  },
  {
    id: "traits.section.單一模型特質",
    classification: "stale-contract",
    legacyContract: "單一模型特質 top-level folder",
    currentEquivalent: "TraitCardsSection plus 模型評分凍結",
    justification: "Current traits authority separates receipt-backed cards from intentionally frozen model scoring.",
  },
  {
    id: "traits.section.多模協作評分",
    classification: "stale-contract",
    legacyContract: "多模協作評分 top-level folder",
    currentEquivalent: "協作評分",
    justification: "The active label is shorter while preserving human collaboration evidence and future arena evidence.",
  },
  {
    id: "workflow.old_goal_overview",
    classification: "stale-contract",
    legacyContract: "WorkOSGoalOverviewCard inside WorkflowPage",
    currentEquivalent: "UltraManualHero + UltraArchitectureManifestSourceCard + WorkOSLiveEvidenceSection",
    justification: "WorkflowPage is now the architecture/evidence surface; the cycle map is edited and previewed from current mode/scenario controls.",
  },
];

const scopes = new Map();
const checks = [];
const findings = [];
let sourceSnapshot = { algorithm: "sha256", files: [] };

function check(id, sourcePath, symbol, markers, expected) {
  const body = scopes.get(`${sourcePath}#${symbol}`);
  const missing = [];
  for (const marker of markers) {
    try {
      requireSourceMarker(body, marker, { sourcePath, symbol });
      if (!body.includes(marker)) throw new Error("exact marker missing");
    } catch {
      missing.push(marker);
    }
  }
  const ok = missing.length === 0;
  checks.push({ id, ok, sourcePath, symbol, expected, missing });
  if (!ok) {
    findings.push({
      id,
      classification: "candidate-regression",
      sourcePath,
      symbol,
      missing,
      expected,
    });
  }
}

try {
  const loaded = readRequiredSources({ root, manifest });
  sourceSnapshot = loaded.sourceSnapshot;
  const specs = [
    ["modes", "struct", "ModesPage"],
    ["modes", "struct", "ModeDashboardSurface"],
    ["modes", "struct", "ModeDifferenceCard"],
    ["scenario", "struct", "ScenariosPage"],
    // Wave 1 後符號更名／移除：ScenarioOSConfigurationBar / ScenarioWorkflowCanvasCard → ScenarioWorkflowPresentationCard
    ["scenario", "struct", "ScenarioWorkflowPresentationCard"],
    ["traits", "struct", "TraitsPage"],
    ["traits", "struct", "DropdownSelectButton"],
    ["traits", "struct", "TraitFolderSection"],
    ["plugins", "struct", "PluginsPage"],
    ["ultra", "struct", "WorkflowPage"],
  ];
  for (const [sourceID, kind, symbol] of specs) {
    const source = loaded.sources.get(sourceID);
    try {
      scopes.set(
        `${source.path}#${symbol}`,
        extractSwiftTypeBody(source.text, { kind, name: symbol, stripComments: true }),
      );
    } catch (error) {
      findings.push({
        id: "source.symbol",
        classification: "source-contract",
        sourcePath: source.path,
        symbol,
        error: error.message,
      });
    }
  }

  const paths = Object.fromEntries([...loaded.sources].map(([id, source]) => [id, source.path]));
  check(
    "dropdown.modes_page",
    paths.modes,
    "ModesPage",
    [
      "WorkOSFactory.begin(",
      "WorkOSShowLoopsCard(contract: osContract)",
      "ModeDashboardSurface(",
      "selectedPresetByMode",
      "customLoopIDsBinding(for: mode.mode)",
      "onSelect(applyMode)",
    ],
    "ModesPage must preserve mode selection, preset/custom loops, and canonical workflow projection.",
  );
  check(
    "dropdown.mode_surface",
    paths.modes,
    "ModeDashboardSurface",
    ["ModeDifferenceMatrix(", "ModeMinimalCurrentHeader(", "selectedPresetID", "selectedLoopIDs"],
    "The current mode helper must keep S/M/L/XL preview and applied-mode controls wired.",
  );
  check(
    "dropdown.mode_behavior",
    paths.modes,
    "ModeDifferenceCard",
    ["WorkOSFactory.begin(", "case .s:", "case .m:", "case .l:", "case .xl, .xxl:"],
    "Each mode card must derive current workflow behavior from WorkOSFactory.",
  );
  check(
    "dropdown.scenario_page",
    paths.scenario,
    "ScenariosPage",
    [
      // Wave 1 後符號更名／移除，此處對應新符號（唯讀 Gate / 投影 / 版本軌）。
      "ScenarioGateSummaryCard(",
      "ScenarioWorkflowPresentationCard(",
      "ScenarioSavedCanvasVersionsRail(",
      'accessibilityIdentifier("scenarios-page-readonly")',
      "ScenarioWorkflowContractFactory.make(",
    ],
    "ScenariosPage must keep Wave 1 read-only Gate summary, workflow presentation, and saved-versions rail (no in-page OS CRUD).",
  );
  check(
    "dropdown.scenario_presentation",
    paths.scenario,
    "ScenarioWorkflowPresentationCard",
    [
      // Wave 1 後符號更名／移除：互動 canvas → 唯讀 Plan/Loops/Goal 投影。
      'Label("Plan + Loops Cycle + Goal"',
      "WorkOSPlanLoopsGoalCycleMap(",
      ".allowsHitTesting(false)",
      'Badge(locked ? "唯讀投影"',
    ],
    "Scenario workflow presentation must host the canonical cycle map as a non-interactive read-only projection.",
  );
  // Guard against Wave 1 regression: reintroducing editable OS/config canvas bars.
  {
    const scenarioText = loaded.sources.get("scenario").text;
    const banned = [
      "struct ScenarioOSConfigurationBar",
      "struct ScenarioWorkflowCanvasCard",
      "onAddWorkflowNode",
      'Button("解鎖編輯"',
    ];
    const present = banned.filter(marker => scenarioText.includes(marker));
    const ok = present.length === 0;
    checks.push({
      id: "dropdown.scenario_no_editable_regression",
      ok,
      sourcePath: paths.scenario,
      symbol: "ScenariosPage",
      expected: "Wave 1 forbids reintroducing scenario OS configuration CRUD / interactive canvas mutators.",
      missing: present,
    });
    if (!ok) {
      findings.push({
        id: "dropdown.scenario_no_editable_regression",
        classification: "candidate-regression",
        sourcePath: paths.scenario,
        symbol: "ScenariosPage",
        missing: present,
        expected: "Wave 1 forbids reintroducing scenario OS configuration CRUD / interactive canvas mutators.",
      });
    }
  }
  check(
    "dropdown.traits_page",
    paths.traits,
    "TraitsPage",
    [
      "TraitCardsSection()",
      'title: "協作評分"',
      'title: "模型評分凍結"',
      'title: "評分表"',
      "showCollaborationSection",
      "showScorePauseSection",
      "showScoringStandards",
    ],
    "TraitsPage must preserve current evidence, collaboration, frozen-score, and rubric controls.",
  );
  check(
    "dropdown.trait_selector_helper",
    paths.traits,
    "DropdownSelectButton",
    ["Menu {", "ForEach(options)", "selection = option.id", "selectedOption?.name", "accessibilityLabel("],
    "The current non-private dropdown helper must remain selectable and accessible.",
  );
  check(
    "dropdown.trait_folder_helper",
    paths.traits,
    "TraitFolderSection",
    ["isExpanded.toggle()", "if isExpanded", "content()", "Text(title)", "Text(subtitle)"],
    "Trait folders must remain explicit expandable controls.",
  );
  check(
    "dropdown.plugins_page",
    paths.plugins,
    "PluginsPage",
    [
      // Skillet / MCP partition replaced the old EnvironmentComponentGrid + legacyArchive filter chrome.
      "if showingAddForm",
      "ForEach(partition.mcp)",
      "ForEach(visibleSkills)",
      "showingAddForm.toggle()",
      "syncToClaude()",
      'Text("Skillet 私有能力倉庫")',
    ],
    "PluginsPage must preserve Skillet/MCP registry surfaces, add/remove controls, and Claude sync.",
  );
  check(
    "dropdown.workflow_page",
    paths.ultra,
    "WorkflowPage",
    [
      // UltraManualData.chapters → UltraManualData.manifestChapters (property rename, same authority).
      "UltraManualData.manifestChapters",
      "UltraManualHero(snapshot: snapshot, surface: surface)",
      "UltraArchitectureManifestSourceCard(compact: surface == .panel)",
      "WorkOSLiveEvidenceSection()",
      "toggle(chapter.id)",
    ],
    "WorkflowPage must preserve its current architecture/evidence disclosure controls.",
  );
} catch (error) {
  findings.push({
    id: "source.manifest",
    classification: "source-contract",
    sourcePath: "required-source-manifest",
    symbol: "manifest",
    error: error.message,
  });
}

const result = {
  schema: "TatwoUIDropdownLoopCheckV2",
  ok: findings.length === 0,
  sourceSnapshot,
  contractMigrations,
  summary: {
    total: checks.length,
    passed: checks.filter(item => item.ok).length,
    failed: findings.length,
  },
  checks,
  findings,
};

console.log(JSON.stringify(result, null, 2));
process.exit(result.ok ? 0 : 1);
