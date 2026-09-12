#!/usr/bin/env node
import {
  extractSwiftTypeBody,
  readRequiredSources,
  requireSourceMarker,
} from "./tatwo-static-audit-source-contract.mjs";

const root = process.cwd();
const manifest = [
  {
    id: "modes",
    relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ModesPage.swift",
    symbols: [
      { kind: "struct", name: "ModesPage" },
      { kind: "struct", name: "ModeSwitchSkeleton" },
      { kind: "struct", name: "ModeDashboardSurface" },
      { kind: "struct", name: "ModeMinimalCurrentHeader" },
      { kind: "struct", name: "ModeDifferenceMatrix" },
      { kind: "struct", name: "ModeDifferenceCard" },
      { kind: "struct", name: "ModeFlowNode" },
      { kind: "struct", name: "ModeInspectorLine" },
      { kind: "struct", name: "WorkOSModeSurfaceStrip" },
    ],
  },
  {
    id: "scenario",
    relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ScenarioPage.swift",
    symbols: [
      // Wave 1 後符號更名／移除：可編輯 config bar / canvas 家族已刪，改守唯讀呈現面。
      { kind: "struct", name: "ScenariosPage" },
      { kind: "struct", name: "ScenarioWorkflowPresentationCard" },
      { kind: "struct", name: "ScenarioLiquidGlassActionButtonStyle" },
      { kind: "struct", name: "FlowTagWrap" },
    ],
  },
  {
    id: "traits",
    relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/TraitsPage.swift",
    symbols: [
      { kind: "struct", name: "TraitsPage" },
      { kind: "struct", name: "CollaborationEvidenceScoreSection" },
      { kind: "struct", name: "CollabBarRow" },
      { kind: "struct", name: "CollabComparativeBars" },
      { kind: "struct", name: "HumanCollabRatingRow" },
      { kind: "struct", name: "HumanCollabRatingEditor" },
      { kind: "struct", name: "TraitEvidenceOverviewBoard" },
      { kind: "struct", name: "TraitEvidenceOverviewRow" },
      { kind: "struct", name: "WebArenaEvidenceTile" },
      { kind: "struct", name: "ArenaCoverageBlock" },
      { kind: "struct", name: "TraitDimensionEvidenceRow" },
      { kind: "struct", name: "MiniStatusCapsule" },
      { kind: "struct", name: "DropdownSelectButton" },
      { kind: "struct", name: "TraitFolderSection" },
      { kind: "struct", name: "EmptyStateStrip" },
      { kind: "struct", name: "SelectedRolePill" },
      { kind: "struct", name: "RoleVisualCard" },
      { kind: "struct", name: "TraitSummaryCompactPill" },
      { kind: "struct", name: "HorizontalScoreRow" },
      { kind: "struct", name: "TraitEvidencePill" },
      { kind: "struct", name: "CollaborationBoostRow" },
      { kind: "struct", name: "CollaborationScoreDuel" },
      { kind: "struct", name: "CollaborationScoreLine" },
      { kind: "struct", name: "CollaborationEquation" },
      { kind: "struct", name: "CollaborationBonusSources" },
      { kind: "struct", name: "CollaborationBonusSourceChip" },
      { kind: "struct", name: "LegendDot" },
      { kind: "struct", name: "TraitStandardTile" },
    ],
  },
  {
    id: "plugins",
    relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/PluginsPage.swift",
    symbols: [
      { kind: "struct", name: "PluginsPage" },
      { kind: "struct", name: "PluginRegistrySwipeRow" },
    ],
  },
  {
    id: "ultra",
    relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPage.swift",
    symbols: [
      { kind: "struct", name: "WorkflowPage" },
      { kind: "struct", name: "WorkOSModeRouteStrip" },
      { kind: "struct", name: "WorkOSModeRouteTile" },
      { kind: "struct", name: "WorkOSDashboardStatusTile" },
      { kind: "struct", name: "WorkOSDashboardPrimaryRail" },
      { kind: "struct", name: "WorkOSDashboardRailCard" },
      { kind: "struct", name: "WorkOSDashboardOutcomeTile" },
      { kind: "struct", name: "WorkOSShowLoopsCard" },
      { kind: "struct", name: "WorkOSRuntimeModuleStrip" },
      { kind: "struct", name: "WorkOSRuntimeModuleTile" },
      { kind: "struct", name: "WorkOSPanelFlowSummary" },
      { kind: "struct", name: "WorkOSPanelFlowStep" },
      { kind: "struct", name: "WorkOSPlanLoopsGoalCycleMap" },
      { kind: "struct", name: "WorkOSPlanLoopsGoalLaneBackdrop" },
      { kind: "struct", name: "WorkOSPlanLoopsGoalIdentityColumn" },
      { kind: "struct", name: "WorkOSPlanLoopsGoalLegend" },
      { kind: "struct", name: "WorkOSPlanLoopsGoalNodeView" },
      { kind: "struct", name: "WorkOSPlanLoopsGoalReceiptRail" },
    ],
  },
  {
    id: "plg",
    relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/PLGFlowCard.swift",
    symbols: [
      { kind: "struct", name: "PLGFlowCard" },
    ],
  },
  {
    id: "usage",
    relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/TatwoM3PrototypeViews.swift",
    symbols: [
      { kind: "struct", name: "TatwoPageNavButton" },
      { kind: "struct", name: "ModelQuotaTopDeck" },
      { kind: "struct", name: "QuotaProviderCard" },
      { kind: "struct", name: "QuotaSkeletonOverlay" },
      { kind: "struct", name: "QuotaProviderLogo" },
      { kind: "struct", name: "QuotaProviderDetail" },
      { kind: "struct", name: "QuotaWindowBar" },
      { kind: "struct", name: "QuotaIntegrationGuide" },
      { kind: "struct", name: "QuotaHubBottomFoldouts" },
      { kind: "struct", name: "QuotaFoldoutLabel" },
      { kind: "struct", name: "QuotaActivityRow" },
      { kind: "struct", name: "QuotaProviderEventRow" },
    ],
  },
  {
    id: "header",
    relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/HeaderQuotaStrip.swift",
    symbols: [
      { kind: "struct", name: "TatwoHeaderQuotaStrip" },
      { kind: "struct", name: "HeaderQuotaSegmentView" },
      { kind: "struct", name: "HeaderQuotaPopover" },
    ],
  },
  {
    id: "shell",
    relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/AppShell.swift",
    symbols: [
      { kind: "struct", name: "ChatWindowCanvasBackdrop" },
      { kind: "struct", name: "TatwoPanelView" },
      { kind: "struct", name: "TatwoPanelChatLauncher" },
      { kind: "struct", name: "TatwoPanelHeader" },
      { kind: "struct", name: "TatwoWindowPageRail" },
      { kind: "struct", name: "CompactPageTitle" },
    ],
  },
];

const maxVisibleLiteralChars = 36;
const forbiddenPhrases = [
  "勾選會立刻",
  "超出模式預算",
  "這頁用來",
  "目前只讀",
  "真相來源",
  "OS contract 是最高約束",
  "Codex 是目前最適合",
  "區塊 + 動態箭頭",
  "缺 receipt 時",
  "不當主畫面備註牆",
  "長篇說明",
  "不是每次都由 GPT",
];

const contractMigrations = [
  {
    id: "copy.monolith_concat",
    classification: "stale-contract",
    legacyContract: "TatwoUltraworkMacApp.swift + WorkOSDeepLoopMap.swift concatenation",
    currentEquivalent: "explicit active split-source manifest with per-source struct/enum symbol coverage",
    justification: "Visible UI copy is now owned by split pages; one file cannot satisfy or hide another page's contract.",
  },
  {
    id: "copy.comment_hits",
    classification: "stale-contract",
    legacyContract: "raw source indexOf/matchAll including comments",
    currentEquivalent: "extractSwiftTypeBody(..., stripComments: true) per active symbol",
    justification: "Comments and inactive neighboring symbols are not visible UI and cannot satisfy or fail the copy policy.",
  },
  {
    id: "copy.visible_literal_limit",
    classification: "candidate-regression",
    legacyContract: "max 36 visible static characters",
    currentEquivalent: "the same max 36 policy over active Text/Label/Badge and visible helper literals",
    justification: "The threshold is intentionally unchanged; real current over-limit copy remains RED rather than being excluded or reclassified as green.",
  },
  {
    id: "copy.forbidden_policy",
    classification: "candidate-regression",
    legacyContract: "forbidden explanatory UI phrases",
    currentEquivalent: "the same forbidden phrase list evaluated only inside active visible literals",
    justification: "The policy remains strict while avoiding comment-only false positives.",
  },
  {
    id: "copy.scenario.wave1_readonly",
    classification: "stale-contract",
    // Wave 1 後符號更名／移除，此處對應新符號。
    legacyContract: "ScenarioOSConfigurationBar + canvas editor symbol family + Label(情境 Work OS)",
    currentEquivalent: "ScenarioWorkflowPresentationCard + Label(Plan + Loops Cycle + Goal)",
    justification: "Wave 1 removed editable scenario OS chrome; copy lint now covers the remaining read-only presentation symbols in ScenarioPage.swift.",
  },
];

const requiredConciseMarkers = [
  ["modes", "ModesPage", "WorkOSShowLoopsCard(contract: osContract)"],
  // Wave 1 後符號更名／移除：ScenarioOSConfigurationBar / Label("情境 Work OS" → 唯讀投影卡標題。
  ["scenario", "ScenarioWorkflowPresentationCard", 'Label("Plan + Loops Cycle + Goal"'],
  ["traits", "TraitsPage", 'title: "協作評分"'],
  // Plugins page copy moved off the old "外掛工具" chrome title; keep a live concise marker.
  ["plugins", "PluginsPage", 'Text("Skillet 私有能力倉庫")'],
  ["ultra", "WorkOSShowLoopsCard", 'Label("專屬 Show Loops"'],
  ["plg", "PLGFlowCard", 'Text("PLG 執行")'],
  ["usage", "ModelQuotaTopDeck", 'Text("額度用量")'],
  ["header", "HeaderQuotaPopover", 'Button("完整 Usage"'],
  ["shell", "TatwoPanelView", "WorkflowPage(snapshot: snapshot)"],
];

const findings = [];
const scopes = new Map();
let sourceSnapshot = { algorithm: "sha256", files: [] };

try {
  const loaded = readRequiredSources({ root, manifest });
  sourceSnapshot = loaded.sourceSnapshot;
  for (const sourceSpec of manifest) {
    const source = loaded.sources.get(sourceSpec.id);
    for (const { kind, name: symbol } of sourceSpec.symbols) {
      try {
        const body = extractSwiftTypeBody(source.text, {
          kind,
          name: symbol,
          stripComments: true,
        });
        scopes.set(`${sourceSpec.id}#${symbol}`, {
          body,
          sourcePath: source.path,
          sourceText: source.text,
          symbol,
          bodyOffset: swiftBodyOffset(source.text, kind, symbol),
        });
      } catch (error) {
        findings.push({
          kind: "source_symbol",
          classification: "source-contract",
          sourcePath: source.path,
          symbol,
          line: 0,
          error: error.message,
        });
      }
    }
  }

  for (const [sourceID, symbol, marker] of requiredConciseMarkers) {
    const scope = scopes.get(`${sourceID}#${symbol}`);
    if (!scope) continue;
    try {
      requireSourceMarker(scope.body, marker, { sourcePath: scope.sourcePath, symbol });
      if (!scope.body.includes(marker)) throw new Error("exact marker missing");
    } catch {
      findings.push({
        kind: "missing_concise_marker",
        classification: "candidate-regression",
        sourcePath: scope.sourcePath,
        symbol,
        line: 0,
        marker,
        expected: "Canonical concise UI marker must remain in its owning symbol.",
      });
    }
  }

  const visibleLiteralPatterns = [
    { invocation: "Text", pattern: /\bText\(\s*"((?:[^"\\]|\\.)*)"/g },
    { invocation: "Label", pattern: /\bLabel\(\s*"((?:[^"\\]|\\.)*)"/g },
    { invocation: "Badge", pattern: /\bBadge\(\s*"((?:[^"\\]|\\.)*)"/g },
    { invocation: "EmptyStateStrip(text:)", pattern: /\bEmptyStateStrip\(\s*text\s*:\s*"((?:[^"\\]|\\.)*)"/g },
  ];
  for (const { body, sourcePath, sourceText, symbol, bodyOffset } of scopes.values()) {
    for (const { invocation, pattern } of visibleLiteralPatterns) {
      for (const match of body.matchAll(pattern)) {
        const literal = match[1];
        const decodedLength = visibleLength(literal);
        const line = lineAt(sourceText, bodyOffset + match.index);
        if (decodedLength > maxVisibleLiteralChars) {
          findings.push({
            kind: "long_visible_literal",
            classification: "candidate-regression",
            sourcePath,
            symbol,
            line,
            invocation,
            literal,
            length: decodedLength,
            max: maxVisibleLiteralChars,
            expected: `Visible Text/Label/Badge/helper copy must be <= ${maxVisibleLiteralChars} characters.`,
          });
        }
        for (const phrase of forbiddenPhrases) {
          if (!literal.includes(phrase)) continue;
          findings.push({
            kind: "forbidden_phrase",
            classification: "candidate-regression",
            sourcePath,
            symbol,
            line,
            invocation,
            phrase,
            literal,
            expected: "Visible UI copy must use compact labels, badges, or disclosure instead of explanatory policy prose.",
          });
        }
      }
    }
  }
} catch (error) {
  findings.push({
    kind: "source_manifest",
    classification: "source-contract",
    sourcePath: "required-source-manifest",
    symbol: "manifest",
    line: 0,
    error: error.message,
  });
}

const result = {
  schema: "TatwoUICopyLintV2",
  ok: findings.length === 0,
  sourceSnapshot,
  contractMigrations,
  maxVisibleLiteralChars,
  forbiddenPhrases,
  summary: {
    activeSources: manifest.length,
    activeSymbols: manifest.reduce((total, source) => total + source.symbols.length, 0),
    findings: findings.length,
    candidateRegressions: findings.filter(finding => finding.classification === "candidate-regression").length,
  },
  findings,
};

console.log(JSON.stringify(result, null, 2));
process.exit(result.ok ? 0 : 1);

function swiftBodyOffset(source, kind, symbol) {
  const declaration = new RegExp(`\\b${kind}\\s+${escapeRegExp(symbol)}\\b[^\\{;]*\\{`);
  const match = declaration.exec(source);
  if (!match) return 0;
  return match.index + match[0].lastIndexOf("{") + 1;
}

function lineAt(source, offset) {
  return source.slice(0, Math.max(0, offset)).split("\n").length;
}

function visibleLength(literal) {
  let staticLiteral = "";
  for (let index = 0; index < literal.length;) {
    if (literal.startsWith("\\(", index)) {
      let depth = 1;
      index += 2;
      while (index < literal.length && depth > 0) {
        if (literal[index] === "(") depth += 1;
        if (literal[index] === ")") depth -= 1;
        index += 1;
      }
      continue;
    }
    staticLiteral += literal[index];
    index += 1;
  }
  const normalized = staticLiteral
    .replaceAll("\\n", "\n")
    .replaceAll('\\"', '"')
    .replaceAll("\\\\", "\\");
  return [...normalized].length;
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
