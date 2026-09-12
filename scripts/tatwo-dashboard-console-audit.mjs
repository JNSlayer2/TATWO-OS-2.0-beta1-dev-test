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
  { id: "shell", relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/AppShell.swift" },
];

const contractMigrations = [
  {
    id: "WorkOSDashboardConsole",
    classification: "stale-contract",
    currentEquivalent: "WorkflowPage",
    justification: "The workflow surface is now a manual/evidence page composed from split components, not one console container.",
  },
  {
    id: "WorkOSDashboardStatusRail",
    classification: "stale-contract",
    currentEquivalent: "UltraManualHero + UltraArchitectureManifestSourceCard",
    justification: "Current status and architecture authority are presented by the workflow hero and manifest source card.",
  },
  {
    id: "WorkOSDashboardPrimaryRail",
    classification: "stale-contract",
    currentEquivalent: "WorkOSPlanLoopsGoalCycleMap + UltraManualData os-core",
    justification: "Primary Goal/Plan/Loops semantics now come from the canonical cycle map and OS manual chapter.",
  },
  {
    id: "WorkOSDashboardLoopBoard",
    classification: "stale-contract",
    currentEquivalent: "WorkOSPlanLoopsGoalCycleMap + WorkOSPlanLoopsGoalBlueprintFactory",
    justification: "Loops, branches, pass/fail, receipts, and Goal return are rendered from the canonical blueprint.",
  },
  {
    id: "WorkOSDashboardEvidenceRail",
    classification: "stale-contract",
    currentEquivalent: "WorkOSLiveEvidenceSection + receipt-bank blueprint node",
    justification: "Live evidence and receipt-bank information moved to dedicated current components.",
  },
  {
    id: "WorkOSDashboardOutcomeRail",
    classification: "stale-contract",
    currentEquivalent: "PLGFlowCard READY/rollback states",
    justification: "Outcome state is now shown where the live PLG run is human-gated, with App promotion explicitly prohibited.",
  },
  {
    id: "WorkOSPanelOpenWindowStrip",
    classification: "stale-contract",
    currentEquivalent: "TatwoPanelView split-page navigation",
    justification: "Workflow is a normal split page routed by AppShell; the removed console no longer needs its own panel/window bridge.",
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
    ["ultra", "struct", "WorkflowPage"],
    ["ultra", "struct", "WorkOSRuntimeModuleStrip"],
    ["ultra", "struct", "WorkOSPlanLoopsGoalCycleMap"],
    ["models", "struct", "WorkOSPlanLoopsGoalBlueprint"],
    ["architecture", "enum", "UltraManualData"],
    ["architecture", "enum", "WorkOSPlanLoopsGoalBlueprintFactory"],
    ["plg", "struct", "PLGFlowCard"],
    ["shell", "struct", "TatwoPanelView"],
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
    "dashboard.workflow_composition",
    paths.ultra,
    "WorkflowPage",
    [
      "UltraManualData.chapters",
      "UltraManualHero(snapshot: snapshot, surface: surface)",
      "UltraArchitectureManifestSourceCard(compact: surface == .panel)",
      "WorkOSLiveEvidenceSection()",
      "UltraManualChapterRow(",
    ],
    "WorkflowPage must expose the current hero, architecture source, live evidence, and expandable manual structure.",
  );
  check(
    "dashboard.goal_plan_loops_receipts_ia",
    paths.architecture,
    "UltraManualData",
    [
      'title: "OS 核心"',
      'detail("goal", "flag.checkered", "Goal（目標）"',
      'detail("plan", "list.clipboard", "Plan（計畫）"',
      'detail("loops", "arrow.triangle.2.circlepath", "Loops（回圈）"',
      'node("os-receipts", "Receipts：build、截圖、review、rollback 等證據")',
      'title: "Plugins 統一標準"',
      'title: "沙盒如何運行"',
      'node("sandbox-output", "輸出：receipt、build.log、report.json、rollback notes；Colima 缺席=degraded 非致命")',
    ],
    "The workflow manual must retain Goal, Plan, Loops, receipts, plugins/tools, sandbox, and rollback information architecture.",
  );
  check(
    "dashboard.canonical_loop_map",
    paths.ultra,
    "WorkOSPlanLoopsGoalCycleMap",
    [
      "WorkOSPlanLoopsGoalBlueprintFactory.make(contract: contract)",
      "WorkOSPlanLoopsGoalConnectorCanvas(connectors: blueprint.connectors, progress: progress)",
      "ForEach(blueprint.nodes)",
      "WorkOSPlanLoopsGoalReceiptRail(tags: blueprint.receiptTags)",
    ],
    "The current workflow architecture must retain the canonical mainline, loops, outcomes, and receipts map.",
  );
  check(
    "dashboard.tools_and_sandbox",
    paths.ultra,
    "WorkOSRuntimeModuleStrip",
    ['("技能"', '("MCP"', '("模型閘道"', '("JS / Swift"', '("沙盒"', '("主機保護"'],
    "Tooling and sandbox modules must remain explicit in the current OS information architecture.",
  );
  check(
    "dashboard.receipts_and_outcomes",
    paths.architecture,
    "WorkOSPlanLoopsGoalBlueprintFactory",
    [
      'node("receipt-bank", "收據庫"',
      'node("supervisor-fail", "副審駁回"',
      'node("supervisor-pass", "副審通過"',
      'node("lead-fail", "主導駁回"',
      'node("lead-pass", "主導通過"',
      'connector("lead-pass-to-goal"',
      'connector("receipts-to-goal"',
    ],
    "Receipt, pass/fail, rollback, and Goal-return paths must remain explicit.",
  );
  check(
    "dashboard.app_readonly_no_promotion",
    paths.plg,
    "PLGFlowCard",
    [
      'Text("分支收據已回報；App 只能標 READY，goal 仍由 OS 關閉。")',
      'Label("收據 READY"',
      'Label("未達·回滾"',
      '.help("等待 Work OS close/gate；App 無 promotion 權限")',
      'Text("等待 Work OS close/gate")',
      'detailText("✅ Work OS 已確認結果；App 僅顯示收據狀態。")',
    ],
    "App must stay read-only with no promotion while still showing READY, rollback, and confirmed outcome states.",
  );
  check(
    "dashboard.app_shell_route",
    paths.shell,
    "TatwoPanelView",
    ["case .workflow:", "WorkflowPage(snapshot: snapshot)"],
    "AppShell must route the workflow page without reviving the removed dashboard console.",
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
  schema: "TatwoDashboardConsoleAuditV2",
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
