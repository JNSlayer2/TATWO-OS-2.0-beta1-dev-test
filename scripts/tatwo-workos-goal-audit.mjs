#!/usr/bin/env node
import {
  extractSwiftTypeBody,
  readRequiredSources,
  requireSourceMarker,
} from "./tatwo-static-audit-source-contract.mjs";

const root = process.cwd();
const manifest = [
  { id: "ultra", relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPage.swift" },
  { id: "models", relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPageModels.swift" },
  { id: "architecture", relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPageArchitectureData.swift" },
  { id: "plg", relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/PLGFlowCard.swift" },
  { id: "modes", relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ModesPage.swift" },
  { id: "scenario", relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ScenarioPage.swift" },
  { id: "shell", relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/AppShell.swift" },
  { id: "buildRun", relativePath: "script/build_and_run.sh" },
];

const contractMigrations = [
  {
    id: "modes.independent_templates",
    classification: "stale-contract",
    legacyContract: "private static sTemplate/mUITemplate/mCodingTemplate/lTemplate/xlTemplate in the monolith",
    currentEquivalent: "WorkOSFlowTemplateFactory in UltraPageArchitectureData.swift plus ModeDifferenceCard",
    justification: "The mode/scenario templates moved into the split architecture data file; the page now consumes the factory instead of owning private templates.",
  },
  {
    id: "visual.adaptive_blueprint_active",
    classification: "stale-contract",
    legacyContract: "WorkOSSpineBlueprintMap versus WorkOSTemplateBlueprintMap branch",
    currentEquivalent: "WorkOSPlanLoopsGoalCycleMap backed by WorkOSPlanLoopsGoalBlueprintFactory and WorkOSFlowTemplateFactory",
    justification: "The current canonical Plan + Loops + Goal map replaced the old adaptive spine type names while retaining mode/scenario-specific templates.",
  },
  {
    id: "visual.template_showloops_pulses",
    classification: "stale-contract",
    legacyContract: "drawPulseTrain/templatePulseGeometry exact implementation names",
    currentEquivalent: "WorkOSPlanLoopsGoalConnectorCanvas over orthogonal connectors",
    justification: "Animation is now owned by the canonical cycle-map connector canvas; exact legacy pulse helper names are presentation details, not authority.",
  },
  {
    id: "visual.evidence_xl",
    classification: "stale-contract",
    legacyContract: "workos-xl-clean-*/workos-xl-spine-* screenshot filenames",
    currentEquivalent: "workos-XL-coding.png and shot-workos-XL-coding",
    justification: "The smoke exporter now uses one deterministic filename and evidence ID per S/M/L/XL mode.",
  },
  {
    id: "visual.evidence_m_ui",
    classification: "stale-contract",
    legacyContract: "workos-m-ui-*/app-scenarios-dedicated-showloops-* screenshot filenames",
    currentEquivalent: "shot-page-scenarios plus the current mode-shape export set",
    justification: "Scenario-page evidence moved to deterministic page snapshots while mode-shape evidence is exported separately.",
  },
  {
    id: "visual.evidence_m_code",
    classification: "stale-contract",
    legacyContract: "app-scenarios-m-code-fresh-* screenshot filename",
    currentEquivalent: "workos-M-coding.png and shot-workos-M-coding",
    justification: "The coding scenario now uses the deterministic M mode-shape artifact.",
  },
  {
    id: "visual.evidence_all_modes_in_smoke",
    classification: "stale-contract",
    legacyContract: "hard-coded shot-workos-S/M/L/XL marker list",
    currentEquivalent: "for mode in S M L XL with workos-${mode}-coding.png and shot-workos-${mode}-coding",
    justification: "The loop is the canonical source of the four artifacts and avoids duplicated filename contracts.",
  },
  {
    id: "visual.page_screenshot_contract",
    classification: "stale-contract",
    legacyContract: "ad-hoc page screenshot names",
    currentEquivalent: "shot-page-${page}",
    justification: "All split pages now share one deterministic page evidence naming contract.",
  },
  {
    id: "scenario.wave1_readonly_presentation",
    classification: "stale-contract",
    // Wave 1 後符號更名／移除，此處對應新符號。
    legacyContract: "ScenarioOSConfigurationBar + ScenarioWorkflowCanvasCard editable wiring",
    currentEquivalent: "ScenarioGateSummaryCard + ScenarioWorkflowPresentationCard + ScenarioSavedCanvasVersionsRail",
    justification: "Wave 1 (2026-07-29) scenario page is read-only Plan/Loops/Goal projection; OS config authority is not in-page CRUD.",
  },
];

const checks = [];
const findings = [];
let sourceSnapshot = { algorithm: "sha256", files: [] };

function record(id, sourcePath, symbol, markers, expected) {
  const missing = [];
  for (const marker of markers) {
    try {
      const body = scopes.get(`${sourcePath}#${symbol}`);
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

function recordFile(id, sourcePath, symbol, source, markers, expected) {
  const missing = markers.filter(marker => !source.includes(marker));
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

const scopes = new Map();
try {
  const loaded = readRequiredSources({ root, manifest });
  sourceSnapshot = loaded.sourceSnapshot;
  const scopeSpecs = [
    ["ultra", "struct", "WorkflowPage"],
    ["ultra", "struct", "WorkOSShowLoopsCard"],
    ["ultra", "struct", "WorkOSRuntimeModuleStrip"],
    ["ultra", "struct", "WorkOSPlanLoopsGoalCycleMap"],
    ["models", "enum", "WorkOSPlanLoopsGoalMetrics"],
    ["models", "struct", "WorkOSPlanLoopsGoalBlueprint"],
    ["architecture", "enum", "WorkOSPlanLoopsGoalBlueprintFactory"],
    ["architecture", "enum", "WorkOSFlowTemplateFactory"],
    ["plg", "struct", "PLGFlowCard"],
    ["modes", "struct", "ModesPage"],
    ["modes", "struct", "ModeDashboardSurface"],
    ["modes", "struct", "ModeDifferenceCard"],
    ["scenario", "struct", "ScenariosPage"],
    // Wave 1 後符號更名／移除：ScenarioOSConfigurationBar / ScenarioWorkflowCanvasCard → ScenarioWorkflowPresentationCard
    ["scenario", "struct", "ScenarioWorkflowPresentationCard"],
    ["shell", "struct", "TatwoPanelView"],
  ];
  for (const [sourceID, kind, symbol] of scopeSpecs) {
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
  record(
    "goal.canonical_cycle_map",
    paths.ultra,
    "WorkOSPlanLoopsGoalCycleMap",
    [
      "WorkOSPlanLoopsGoalBlueprintFactory.make(contract: contract)",
      "WorkOSPlanLoopsGoalIdentityColumn(contract: contract)",
      "WorkOSPlanLoopsGoalConnectorCanvas(connectors: blueprint.connectors, progress: progress)",
      "WorkOSPlanLoopsGoalReceiptRail(tags: blueprint.receiptTags)",
    ],
    "The canonical cycle map must render identity, connectors, nodes, and receipt rail from one blueprint.",
  );
  record(
    "goal.canonical_metrics",
    paths.models,
    "WorkOSPlanLoopsGoalMetrics",
    ["static let width:", "static let height:", "static let receiptRailY:"],
    "The canonical map must keep explicit layout metrics.",
  );
  record(
    "goal.blueprint_plan_loops_goal",
    paths.architecture,
    "WorkOSPlanLoopsGoalBlueprintFactory",
    [
      'node("plan", "Plan"',
      'node("loops", "Loops"',
      'node("goal", "Goal"',
      'node("done", "完工"',
      'node("receipt-bank", "收據庫"',
      'node("supervisor-fail", "副審駁回"',
      'node("lead-pass", "主導通過"',
    ],
    "Blueprint authority must preserve Plan, Loops, Goal, human completion, receipts, pass, and rollback branches.",
  );
  record(
    "goal.mode_scenario_templates",
    paths.architecture,
    "WorkOSFlowTemplateFactory",
    [
      "switch contract.mode",
      "case .s: return sTemplate(contract)",
      "case .m: return mTemplate(contract)",
      "case .l: return lTemplate(contract)",
      "case .xl, .xxl: return xlTemplate(contract)",
      "case \"ui\": return mUITemplate(contract)",
      "default: return mCodingTemplate(contract)",
      "static func surfaceSummary(contract:",
    ],
    "Current mode and scenario templates must remain distinct without restoring old page-owned helpers.",
  );
  record(
    "goal.showloops_readonly",
    paths.ultra,
    "WorkOSShowLoopsCard",
    [
      "WorkOSFlowTemplateFactory.make(contract: contract)",
      "WorkOSBlockArrowMap(contract: contract",
      "WorkOSDeepLoopMap(contract: contract",
      "projection.readOnly",
      "projection.visualizerCanPromoteRunState",
    ],
    "Show Loops must remain a read-only projection with explicit no-promotion state.",
  );
  record(
    "goal.runtime_modules",
    paths.ultra,
    "WorkOSRuntimeModuleStrip",
    ['("技能"', '("MCP"', '("模型閘道"', '("JS / Swift"', '("沙盒"', '("主機保護"'],
    "Runtime IA must retain skills, MCP, gateway, scripts, sandbox, and host protection.",
  );
  record(
    "goal.plg_spine_and_gate",
    paths.plg,
    "PLGFlowCard",
    [
      'spineNode("Plan", "主導", stage: 0)',
      'spineNode("Loops", "副審+Sub", stage: 1)',
      'spineNode("Goal", "主導", stage: 2)',
      'spineNode("提交", "人類", stage: 3)',
      'Label("收據 READY"',
      'Label("未達·回滾"',
      '.help("等待 Work OS close/gate；App 無 promotion 權限")',
      'Text("等待 Work OS close/gate")',
    ],
    "The live PLG card must preserve the canonical human-gated spine, READY, rollback, and App no-promotion policy.",
  );
  record(
    "goal.modes_wiring",
    paths.modes,
    "ModesPage",
    [
      "WorkOSFactory.begin(",
      "WorkOSShowLoopsCard(contract: osContract)",
      "customLoopIDsBinding(for: mode.mode)",
      "ModeDashboardSurface(",
    ],
    "ModesPage must wire S/M/L/XL selection and custom loops into the canonical Show Loops view.",
  );
  record(
    "goal.mode_controls",
    paths.modes,
    "ModeDifferenceCard",
    ["case .s:", "case .m:", "case .l:", "case .xl, .xxl:", "WorkOSFactory.begin("],
    "Mode cards must expose current per-mode behavior from WorkOSFactory.",
  );
  record(
    "goal.scenario_wiring",
    paths.scenario,
    "ScenariosPage",
    [
      // Wave 1 後符號更名／移除，此處對應新符號（唯讀 Gate / 投影 / 版本軌）。
      "ScenarioGateSummaryCard(",
      "ScenarioWorkflowPresentationCard(",
      "ScenarioSavedCanvasVersionsRail(",
      "ScenarioWorkflowContractFactory.make(",
      'accessibilityIdentifier("scenarios-page-readonly")',
    ],
    "ScenariosPage must wire Wave 1 read-only Gate summary, workflow presentation, and versions rail (no in-page OS CRUD).",
  );
  record(
    "goal.scenario_cycle_map",
    paths.scenario,
    "ScenarioWorkflowPresentationCard",
    [
      // Wave 1 後符號更名／移除：互動 canvas → 唯讀 Plan/Loops/Goal 投影。
      "WorkOSPlanLoopsGoalCycleMap(",
      ".allowsHitTesting(false)",
      'Label("Plan + Loops Cycle + Goal"',
      'Badge(locked ? "唯讀投影"',
    ],
    "Scenario workflow presentation must project the canonical cycle map as a non-interactive read-only surface.",
  );
  record(
    "goal.app_shell_wiring",
    paths.shell,
    "TatwoPanelView",
    ["ModesPage(", "ScenariosPage(", "TraitsPage(", "PluginsPage(", "WorkflowPage(snapshot: snapshot)"],
    "AppShell must route each navigation case to its split page.",
  );
  recordFile(
    "goal.screenshot_contract",
    paths.buildRun,
    "build_and_run.sh",
    loaded.sources.get("buildRun").text,
    ["for mode in S M L XL", 'workos-${mode}-coding.png', 'shot-workos-${mode}-coding', 'shot-page-${page}'],
    "Smoke evidence must use deterministic split-page and S/M/L/XL filenames.",
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
  schema: "TatwoWorkOSGoalAuditV2",
  ok: findings.length === 0,
  sourceSnapshot,
  contractMigrations,
  summary: {
    total: checks.length,
    passed: checks.filter(check => check.ok).length,
    failed: findings.length,
  },
  checks,
  findings,
};

console.log(JSON.stringify(result, null, 2));
process.exit(result.ok ? 0 : 1);
