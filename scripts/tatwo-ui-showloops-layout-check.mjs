#!/usr/bin/env node
import {
  extractSwiftFunctionBody,
  extractSwiftTypeBody,
  readRequiredSources,
  requireSourceMarker,
} from "./tatwo-static-audit-source-contract.mjs";

const root = process.cwd();
const requiredSourceManifest = [
  {
    id: "page",
    relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPage.swift",
  },
  {
    id: "architecture",
    relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPageArchitectureData.swift",
  },
  {
    id: "deep",
    relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/WorkOSDeepLoopMap.swift",
  },
];
const contractMigrations = [
  {
    classification: "stale-contract",
    legacyCheck: "WorkOSPipelineMap and WorkOSPipeline* marker inventory",
    replacement: "WorkOSPlanLoopsGoalCycleMap plus WorkOSPlanLoopsGoalBlueprintFactory",
    justification: "The active Show Loops surface is the canonical PLG cycle map, so Pipeline-only types no longer prove the rendered contract.",
  },
  {
    classification: "stale-contract",
    legacyCheck: "WorkOSSpineBlueprintMap lane and bus geometry",
    replacement: "PLG mainline, branch review routes, responsibility column, and two-stage verdict nodes",
    justification: "PLG represents mainline and review responsibility directly instead of the legacy vertical spine and side buses.",
  },
  {
    classification: "stale-contract",
    legacyCheck: "legacy template S/M/L/XL node-count parser",
    replacement: "WorkOSDeepLoopMap projection, mode lanes, runtime rail, and gate lane",
    justification: "Deep loop layout now renders the live showLoopsProjection and mode-specific lanes rather than old template factory node tables.",
  },
  {
    classification: "stale-contract",
    legacyCheck: "global curve/trig and dot animation scan",
    replacement: "route-scoped orthogonal checks plus connector-specific rectangular pulse checks",
    justification: "Only route builders determine orthogonality, while pulse and arrowhead animation math must be audited separately to avoid false positives.",
  },
];

let receipt;
try {
  receipt = runAudit();
} catch (error) {
  receipt = fatalReceipt(error);
}

console.log(JSON.stringify(receipt, null, 2));
if (!receipt.ok) process.exit(1);

function runAudit() {
  const { sources, sourceSnapshot } = readRequiredSources({
    root,
    manifest: requiredSourceManifest,
  });
  const pagePath = requiredSourceManifest[0].relativePath;
  const architecturePath = requiredSourceManifest[1].relativePath;
  const deepPath = requiredSourceManifest[2].relativePath;
  const cycleMapSource = type(sources, "page", "struct", "WorkOSPlanLoopsGoalCycleMap");
  const connectorCanvasSource = type(sources, "page", "struct", "WorkOSPlanLoopsGoalConnectorCanvas");
  const blueprintFactorySource = type(sources, "architecture", "enum", "WorkOSPlanLoopsGoalBlueprintFactory");
  const deepMapSource = type(sources, "deep", "struct", "WorkOSDeepLoopMap");
  const projectionLayoutSource = type(sources, "deep", "enum", "ShowLoopsProjectionLayoutFactory");
  const arrowEngineSource = type(sources, "deep", "enum", "ShowLoopsArrowEngine");
  const deepPlanFactorySource = type(sources, "deep", "enum", "DeepLoopPlanFactory");
  const miniArrowSource = type(sources, "deep", "struct", "AnimatedMiniArrow");
  const plgDrawRoute = func(connectorCanvasSource, "drawRoute");
  const plgDrawPulseTrain = func(connectorCanvasSource, "drawPulseTrain");
  const plgDrawPulse = func(connectorCanvasSource, "drawPulse");
  const plgPulseTrain = func(connectorCanvasSource, "pulseTrain");
  const deepRoutePoints = func(projectionLayoutSource, "routePoints");
  const deepOrthogonal = func(projectionLayoutSource, "orthogonal");
  const deepDrawRoute = func(arrowEngineSource, "draw");
  const deepDrawPulse = func(arrowEngineSource, "drawPulse");
  const miniPulseTrain = func(miniArrowSource, "pulseTrain");
  const findings = [];

  function finding({
    id,
    kind = id,
    sourcePath,
    symbol,
    classification = "candidate-regression",
    ...details
  }) {
    findings.push({ id, kind, classification, sourcePath, symbol, ...details });
  }

  function requireMarker(scopedSource, marker, {
    id,
    sourcePath,
    symbol,
  }) {
    try {
      requireSourceMarker(scopedSource, marker, { sourcePath, symbol });
    } catch {
      finding({ id, kind: "missing_source_guard", sourcePath, symbol, marker });
    }
  }

  function requireText(scopedSource, text, {
    id,
    sourcePath,
    symbol,
  }) {
    if (!scopedSource.includes(text)) {
      finding({ id, kind: "missing_scoped_text", sourcePath, symbol, text });
    }
  }

  for (const [id, marker] of [
    ["canonical_identity_column_missing", "WorkOSPlanLoopsGoalIdentityColumn(contract: contract)"],
    ["canonical_connector_canvas_missing", "WorkOSPlanLoopsGoalConnectorCanvas(connectors: blueprint.connectors, progress: progress)"],
    ["canonical_receipt_rail_missing", "WorkOSPlanLoopsGoalReceiptRail(tags: blueprint.receiptTags)"],
    ["canonical_content_offset_missing", ".offset(y: WorkOSPlanLoopsGoalMetrics.contentOffsetY)"],
  ]) {
    requireMarker(cycleMapSource, marker, {
      id,
      sourcePath: pagePath,
      symbol: "struct WorkOSPlanLoopsGoalCycleMap",
    });
  }

  for (const [id, marker] of [
    ["plg_mainline_plan_missing", 'node("plan", "Plan"'],
    ["plg_mainline_loops_missing", 'node("loops", "Loops"'],
    ["plg_mainline_goal_missing", 'node("goal", "Goal"'],
    ["plg_plan_responsibility_missing", 'node("lead-plan-duty", "主導責任"'],
    ["plg_loops_responsibility_missing", 'node("supervisor-duty", "副審 + Sub"'],
    ["plg_goal_responsibility_missing", 'node("lead-goal-duty", "主導驗收"'],
    ["plg_branch_factory_missing", "branchBlueprints(contract: contract)"],
    ["plg_supervisor_fail_missing", 'node("supervisor-fail", "副審駁回"'],
    ["plg_supervisor_pass_missing", 'node("supervisor-pass", "副審通過"'],
    ["plg_lead_fail_missing", 'node("lead-fail", "主導駁回"'],
    ["plg_lead_pass_missing", 'node("lead-pass", "主導通過"'],
    ["plg_receipt_bank_missing", 'node("receipt-bank", "收據庫"'],
    ["plg_orthogonal_connector_factory_missing", "orthogonalized(points).filterAdjacentDuplicates()"],
  ]) {
    requireMarker(blueprintFactorySource, marker, {
      id,
      sourcePath: architecturePath,
      symbol: "enum WorkOSPlanLoopsGoalBlueprintFactory",
    });
  }
  requireText(blueprintFactorySource, "-to-review-bus", {
    id: "plg_branch_review_route_missing",
    sourcePath: architecturePath,
    symbol: "enum WorkOSPlanLoopsGoalBlueprintFactory",
  });
  requireText(blueprintFactorySource, "只入庫，不自動放行", {
    id: "plg_receipt_no_promotion_missing",
    sourcePath: architecturePath,
    symbol: "enum WorkOSPlanLoopsGoalBlueprintFactory",
  });

  for (const [id, marker] of [
    ["deep_projection_missing", "ShowLoopsOrthogonalProjection("],
    ["deep_projection_not_contract_bound", "projection: contract.showLoopsProjection"],
    ["deep_timeline_missing", "TimelineView(.periodic(from: Date(), by: TatwoMotionClock.secondsPerFrame))"],
    ["deep_legend_missing", "DeepLoopLegendRow(plan: plan)"],
  ]) {
    requireMarker(deepMapSource, marker, {
      id,
      sourcePath: deepPath,
      symbol: "struct WorkOSDeepLoopMap",
    });
  }

  for (const [id, marker] of [
    ["deep_readonly_badge_missing", 'contract.showLoopsProjection.readOnly ? "只讀" : "可寫"'],
    ["deep_entry_lane_missing", "entryLane("],
    ["deep_identity_lane_missing", "identityLane("],
    ["deep_runtime_lane_missing", "runtimeLane("],
    ["deep_gate_lane_missing", "gateLane("],
  ]) {
    requireMarker(deepPlanFactorySource, marker, {
      id,
      sourcePath: deepPath,
      symbol: "enum DeepLoopPlanFactory",
    });
  }

  requireMarker(plgDrawRoute, "path.addLine(to: point)", {
    id: "plg_route_line_segments_missing",
    sourcePath: pagePath,
    symbol: "WorkOSPlanLoopsGoalConnectorCanvas.drawRoute",
  });
  requireMarker(plgDrawPulseTrain, "pointAlong(", {
    id: "plg_pulse_not_bound_to_route",
    sourcePath: pagePath,
    symbol: "WorkOSPlanLoopsGoalConnectorCanvas.drawPulseTrain",
  });
  requireMarker(plgPulseTrain, "[0.0, 0.38, 0.72]", {
    id: "plg_pulse_train_missing",
    sourcePath: pagePath,
    symbol: "WorkOSPlanLoopsGoalConnectorCanvas.pulseTrain",
  });
  auditRectangularPulse({
    source: plgDrawPulse,
    sourcePath: pagePath,
    symbol: "WorkOSPlanLoopsGoalConnectorCanvas.drawPulse",
    missingID: "plg_connector_rectangular_pulse_missing",
    dotID: "plg_connector_dot_pulse_present",
    finding,
    requireAxes: true,
  });

  requireMarker(deepRoutePoints, "orthogonal(", {
    id: "deep_route_not_orthogonalized",
    sourcePath: deepPath,
    symbol: "ShowLoopsProjectionLayoutFactory.routePoints",
  });
  requireMarker(deepOrthogonal, "result.append(point)", {
    id: "deep_orthogonal_builder_missing",
    sourcePath: deepPath,
    symbol: "ShowLoopsProjectionLayoutFactory.orthogonal",
  });
  requireMarker(deepDrawRoute, "path.addLine(to: point)", {
    id: "deep_route_line_segments_missing",
    sourcePath: deepPath,
    symbol: "ShowLoopsArrowEngine.draw",
  });
  auditRectangularPulse({
    source: deepDrawPulse,
    sourcePath: deepPath,
    symbol: "ShowLoopsArrowEngine.drawPulse",
    missingID: "deep_projection_rectangular_pulse_missing",
    dotID: "deep_projection_dot_pulse_present",
    finding,
    requireAxes: false,
  });
  requireMarker(deepDrawPulse, "[0.0, 0.38, 0.72]", {
    id: "deep_projection_pulse_train_missing",
    sourcePath: deepPath,
    symbol: "ShowLoopsArrowEngine.drawPulse",
  });
  requireMarker(miniPulseTrain, "[0.0, 0.42, 0.78]", {
    id: "deep_mini_pulse_train_missing",
    sourcePath: deepPath,
    symbol: "AnimatedMiniArrow.pulseTrain",
  });

  for (const [source, sourcePath, symbol] of [
    [plgDrawRoute, pagePath, "WorkOSPlanLoopsGoalConnectorCanvas.drawRoute"],
    [deepRoutePoints, deepPath, "ShowLoopsProjectionLayoutFactory.routePoints"],
    [deepOrthogonal, deepPath, "ShowLoopsProjectionLayoutFactory.orthogonal"],
    [deepDrawRoute, deepPath, "ShowLoopsArrowEngine.draw"],
  ]) {
    for (const api of ["path.addCurve", "addQuadCurve", "atan2("]) {
      if (source.includes(api)) {
        finding({
          id: "connector_route_curve_or_diagonal_api_present",
          sourcePath,
          symbol,
          api,
        });
      }
    }
  }

  return {
    schema: "TatwoShowLoopsLayoutCheckV3",
    ok: findings.length === 0,
    checkedAt: new Date().toISOString(),
    sourceSnapshot,
    authority: {
      cycleMap: `${pagePath}::struct WorkOSPlanLoopsGoalCycleMap`,
      connectorCanvas: `${pagePath}::struct WorkOSPlanLoopsGoalConnectorCanvas`,
      blueprintFactory: `${architecturePath}::enum WorkOSPlanLoopsGoalBlueprintFactory`,
      deepLoopMap: `${deepPath}::struct WorkOSDeepLoopMap`,
    },
    contractMigrations,
    summary: {
      findings: findings.length,
      classifications: classificationCounts(findings),
      checks: {
        canonicalMainline: true,
        identityResponsibility: true,
        branchPlanLoopsGoalEquivalent: "branchBlueprints + review bus + two-stage verdicts",
        receiptRail: true,
        readOnlyNoPromotion: true,
        orthogonalRoutes: true,
        pulseTrain: true,
      },
    },
    findings,
  };
}

function type(sources, sourceID, kind, name) {
  return extractSwiftTypeBody(sources.get(sourceID).text, {
    kind,
    name,
    stripComments: true,
  });
}

function func(source, name) {
  return extractSwiftFunctionBody(source, { name, stripComments: true });
}

function auditRectangularPulse({
  source,
  sourcePath,
  symbol,
  missingID,
  dotID,
  finding,
  requireAxes,
}) {
  const required = [
    "markerRect",
    "glowRect",
    "Path(roundedRect: markerRect",
    "Path(roundedRect: glowRect",
  ];
  if (requireAxes) required.push("case .horizontal", "case .vertical");
  const hasRectangularPulse = required.every(marker => source.includes(marker));
  const hasDotPulse = (
    source.includes("Path(ellipseIn: dotRect)")
    || source.includes("Path(ellipseIn: glowRect)")
    || source.includes("dotRadius")
  );
  if (!hasRectangularPulse) {
    finding({
      id: missingID,
      sourcePath,
      symbol,
      actual: hasDotPulse ? "ellipse/dot pulse" : "rectangular marker geometry absent",
      expected: requireAxes
        ? "axis-aware horizontal and vertical rectangular pulse bars"
        : "rectangular pulse bars with glow and crisp marker layers",
    });
  } else if (hasDotPulse) {
    finding({
      id: dotID,
      sourcePath,
      symbol,
      actual: "ellipse/dot pulse",
      expected: "rectangular pulse bar",
    });
  }
}

function fatalReceipt(error) {
  const sourcePath = requiredSourceManifest.find(entry =>
    String(error?.message ?? "").includes(entry.relativePath)
  )?.relativePath ?? "required-source-manifest";
  return {
    schema: "TatwoShowLoopsLayoutCheckV3",
    ok: false,
    checkedAt: new Date().toISOString(),
    sourceSnapshot: { algorithm: "sha256", files: [] },
    contractMigrations,
    summary: {
      findings: 1,
      classifications: { "candidate-regression": 1, "stale-contract": 0 },
    },
    findings: [{
      id: "required_source_contract_failed",
      kind: "required_source_contract_failed",
      classification: "candidate-regression",
      sourcePath,
      symbol: "required-source-manifest",
      message: error instanceof Error ? error.message : String(error),
    }],
  };
}

function classificationCounts(findings) {
  return findings.reduce(
    (counts, finding) => {
      counts[finding.classification] += 1;
      return counts;
    },
    { "candidate-regression": 0, "stale-contract": 0 },
  );
}
