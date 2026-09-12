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
    id: "models",
    relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPageModels.swift",
  },
  {
    id: "page",
    relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPage.swift",
  },
  {
    id: "architecture",
    relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPageArchitectureData.swift",
  },
];
const contractMigrations = [
  {
    classification: "stale-contract",
    legacyCheck: "WorkOSSpineBlueprintMetrics monolith metric scan",
    replacement: "WorkOSPlanLoopsGoalMetrics scoped metric thresholds",
    justification: "The visible authority moved from the legacy spine canvas to the canonical Plan+Loops+Goal cycle map, so the same canvas safety gates now bind to the PLG metric enum.",
  },
  {
    classification: "stale-contract",
    legacyCheck: "spine contract/identity/fail-closed top-strip ordering",
    replacement: "PLG task/plan/loops/goal/done mainline plus responsibility column",
    justification: "PLG expresses contract intake and identity responsibility as the mainline and left responsibility column rather than three Spine-only top cards.",
  },
  {
    classification: "stale-contract",
    legacyCheck: "domain/tool bus and external tool port geometry",
    replacement: "PLG branch lanes, two-stage verdicts, and receipt rail geometry",
    justification: "Branch work and tool evidence now converge through canonical branch cards, supervisor/lead gates, and the receipt bank instead of legacy domain/tool buses.",
  },
  {
    classification: "stale-contract",
    legacyCheck: "global curve and diagonal API scan",
    replacement: "WorkOSPlanLoopsGoalConnectorCanvas.drawRoute plus BlueprintFactory.orthogonalized",
    justification: "Connector calmness must be judged inside route construction only so unrelated arrowhead or animation math cannot create false positives.",
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
  const modelsPath = requiredSourceManifest[0].relativePath;
  const pagePath = requiredSourceManifest[1].relativePath;
  const architecturePath = requiredSourceManifest[2].relativePath;
  const metricsSource = extractSwiftTypeBody(sources.get("models").text, {
    kind: "enum",
    name: "WorkOSPlanLoopsGoalMetrics",
    stripComments: true,
  });
  const cycleMapSource = extractSwiftTypeBody(sources.get("page").text, {
    kind: "struct",
    name: "WorkOSPlanLoopsGoalCycleMap",
    stripComments: true,
  });
  const connectorCanvasSource = extractSwiftTypeBody(sources.get("page").text, {
    kind: "struct",
    name: "WorkOSPlanLoopsGoalConnectorCanvas",
    stripComments: true,
  });
  const blueprintFactorySource = extractSwiftTypeBody(sources.get("architecture").text, {
    kind: "enum",
    name: "WorkOSPlanLoopsGoalBlueprintFactory",
    stripComments: true,
  });
  const drawRouteSource = extractSwiftFunctionBody(connectorCanvasSource, {
    name: "drawRoute",
    stripComments: true,
  });
  const orthogonalizedSource = extractSwiftFunctionBody(blueprintFactorySource, {
    name: "orthogonalized",
    stripComments: true,
  });
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

  function metric(name) {
    const matches = [
      ...metricsSource.matchAll(new RegExp(`static let ${name}: CGFloat = ([0-9.]+)`, "g")),
    ];
    if (matches.length !== 1) {
      finding({
        id: `metric_${name}_missing_or_ambiguous`,
        kind: "missing_metric",
        sourcePath: modelsPath,
        symbol: "enum WorkOSPlanLoopsGoalMetrics",
        name,
        matches: matches.length,
      });
      return Number.NaN;
    }
    return Number(matches[0][1]);
  }

  const width = metric("width");
  const height = metric("height");
  const contentOffsetY = metric("contentOffsetY");
  const receiptRailY = metric("receiptRailY");
  const metrics = { width, height, contentOffsetY, receiptRailY };

  if (width < 1120) {
    finding({
      id: "canvas_too_narrow_for_plg_map",
      sourcePath: modelsPath,
      symbol: "enum WorkOSPlanLoopsGoalMetrics",
      actual: width,
      expectedAtLeast: 1120,
    });
  }
  if (height < 810) {
    finding({
      id: "canvas_too_short_for_plg_map",
      sourcePath: modelsPath,
      symbol: "enum WorkOSPlanLoopsGoalMetrics",
      actual: height,
      expectedAtLeast: 810,
    });
  }
  if (contentOffsetY < 34) {
    finding({
      id: "content_offset_too_small",
      sourcePath: modelsPath,
      symbol: "enum WorkOSPlanLoopsGoalMetrics",
      actual: contentOffsetY,
      expectedAtLeast: 34,
    });
  }
  if (receiptRailY < 780 || receiptRailY > height - 24) {
    finding({
      id: "receipt_rail_bad_y",
      sourcePath: modelsPath,
      symbol: "enum WorkOSPlanLoopsGoalMetrics",
      actual: receiptRailY,
      expectedRange: [780, height - 24],
    });
  }

  for (const [id, marker] of [
    ["identity_column_plain_left", "WorkOSPlanLoopsGoalIdentityColumn(contract: contract)"],
    ["canonical_connector_canvas_present", "WorkOSPlanLoopsGoalConnectorCanvas(connectors: blueprint.connectors, progress: progress)"],
    ["content_offset_applied", ".offset(y: WorkOSPlanLoopsGoalMetrics.contentOffsetY)"],
    ["legend_in_header_zone", ".position(x: 604, y: 27)"],
    ["receipt_rail_bound_to_metric", ".position(x: 660, y: WorkOSPlanLoopsGoalMetrics.receiptRailY)"],
  ]) {
    requireMarker(cycleMapSource, marker, {
      id,
      sourcePath: pagePath,
      symbol: "struct WorkOSPlanLoopsGoalCycleMap",
    });
  }

  for (const [id, marker] of [
    ["mainline_task_node_missing", 'node("task", "任務開始"'],
    ["mainline_plan_node_missing", 'node("plan", "Plan"'],
    ["mainline_loops_node_missing", 'node("loops", "Loops"'],
    ["mainline_goal_node_missing", 'node("goal", "Goal"'],
    ["mainline_done_node_missing", 'node("done", "完工"'],
    ["plan_responsibility_node_missing", 'node("lead-plan-duty", "主導責任"'],
    ["loops_responsibility_node_missing", 'node("supervisor-duty", "副審 + Sub"'],
    ["goal_responsibility_node_missing", 'node("lead-goal-duty", "主導驗收"'],
    ["supervisor_fail_node_missing", 'node("supervisor-fail", "副審駁回"'],
    ["supervisor_pass_node_missing", 'node("supervisor-pass", "副審通過"'],
    ["lead_fail_node_missing", 'node("lead-fail", "主導駁回"'],
    ["lead_pass_node_missing", 'node("lead-pass", "主導通過"'],
    ["receipt_bank_node_missing", 'node("receipt-bank", "收據庫"'],
    ["main_task_plan_route_missing", 'connector("main-task-plan"'],
    ["main_plan_loops_route_missing", 'connector("main-plan-loops"'],
    ["main_loops_goal_route_missing", 'connector("main-loops-goal"'],
    ["main_goal_done_route_missing", 'connector("main-goal-done"'],
    ["lead_pass_outer_corridor_missing", 'CGPoint(x: 1084, y: r("lead-pass").midY)'],
    ["receipt_route_top_entry_missing", 'top(r("receipt-bank"))'],
    ["connector_orthogonalization_missing", "orthogonalized(points).filterAdjacentDuplicates()"],
  ]) {
    requireMarker(blueprintFactorySource, marker, {
      id,
      sourcePath: architecturePath,
      symbol: "enum WorkOSPlanLoopsGoalBlueprintFactory",
    });
  }

  requireMarker(drawRouteSource, "path.addLine(to: point)", {
    id: "plg_route_line_segments_missing",
    sourcePath: pagePath,
    symbol: "WorkOSPlanLoopsGoalConnectorCanvas.drawRoute",
  });
  for (const api of ["path.addCurve", "addQuadCurve"]) {
    if (drawRouteSource.includes(api)) {
      finding({
        id: "plg_connector_route_curve_api_present",
        sourcePath: pagePath,
        symbol: "WorkOSPlanLoopsGoalConnectorCanvas.drawRoute",
        api,
      });
    }
  }
  for (const api of ["atan2(", " cos(", " sin("]) {
    if (orthogonalizedSource.includes(api)) {
      finding({
        id: "plg_connector_route_diagonal_math_present",
        sourcePath: architecturePath,
        symbol: "WorkOSPlanLoopsGoalBlueprintFactory.orthogonalized",
        api,
      });
    }
  }

  const offset = contentOffsetY;
  const cards = new Map([
    ["task", rect("task", 238, 178, 120, 72, offset)],
    ["plan", rect("plan", 392, 178, 130, 72, offset)],
    ["loops", rect("loops", 558, 178, 196, 72, offset)],
    ["goal", rect("goal", 808, 178, 132, 72, offset)],
    ["done", rect("done", 970, 178, 124, 72, offset)],
    ["branch-read", rect("branch-read", 300, 356, 176, 62, offset)],
    ["branch-patch", rect("branch-patch", 518, 356, 176, 62, offset)],
    ["branch-test", rect("branch-test", 736, 356, 176, 62, offset)],
    ["supervisor-fail", rect("supervisor-fail", 315, 494, 175, 60, offset)],
    ["supervisor-pass", rect("supervisor-pass", 595, 494, 175, 60, offset)],
    ["lead-fail", rect("lead-fail", 315, 618, 175, 60, offset)],
    ["lead-pass", rect("lead-pass", 595, 618, 175, 60, offset)],
    ["receipt-bank", rect("receipt-bank", 876, 504, 180, 78, offset)],
  ]);
  const identityColumn = rect("identity-column", 25, 49, 174, 340, offset);
  const branchLabel = rect("branch-lane-label", 271, 294, 420, 25, offset);

  for (const card of cards.values()) {
    if (!inside(card, width, height)) {
      finding({
        id: "plg_card_outside_canvas",
        sourcePath: architecturePath,
        symbol: "enum WorkOSPlanLoopsGoalBlueprintFactory",
        card: card.id,
      });
    }
    if (overlaps(identityColumn, card, 10)) {
      finding({
        id: "identity_column_overlaps_plg_card",
        sourcePath: pagePath,
        symbol: "struct WorkOSPlanLoopsGoalCycleMap",
        card: card.id,
      });
    }
  }
  for (const id of ["branch-read", "branch-patch", "branch-test"]) {
    if (overlaps(branchLabel, cards.get(id), 8)) {
      finding({
        id: "branch_label_overlaps_branch_card",
        sourcePath: architecturePath,
        symbol: "enum WorkOSPlanLoopsGoalBlueprintFactory",
        card: id,
      });
    }
  }

  const routes = [
    ["main-task-plan", [right(cards.get("task")), left(cards.get("plan"))], []],
    ["main-plan-loops", [right(cards.get("plan")), left(cards.get("loops"))], []],
    ["main-loops-goal", [right(cards.get("loops")), left(cards.get("goal"))], []],
    ["main-goal-done", [right(cards.get("goal")), left(cards.get("done"))], []],
    [
      "goal-to-receipts",
      [
        bottom(cards.get("goal")),
        point(cards.get("goal").midX, 292 + offset),
        point(cards.get("receipt-bank").midX, 292 + offset),
        top(cards.get("receipt-bank")),
      ],
      [cards.get("done"), cards.get("branch-test"), cards.get("supervisor-pass"), cards.get("lead-pass")],
    ],
    [
      "lead-pass-to-goal",
      [
        right(cards.get("lead-pass")),
        point(1084, cards.get("lead-pass").midY),
        point(1084, 290 + offset),
        point(cards.get("goal").midX, 290 + offset),
        bottom(cards.get("goal")),
      ],
      [cards.get("branch-test"), cards.get("receipt-bank"), cards.get("done")],
    ],
  ];
  for (const [id, points, avoidedCards] of routes) {
    assertRoute(id, points, avoidedCards, finding, architecturePath);
  }

  return {
    schema: "TatwoWorkOSVisualGeometryAuditV2",
    ok: findings.length === 0,
    checkedAt: new Date().toISOString(),
    sourceSnapshot,
    authority: {
      metrics: `${modelsPath}::enum WorkOSPlanLoopsGoalMetrics`,
      cycleMap: `${pagePath}::struct WorkOSPlanLoopsGoalCycleMap`,
      connectorCanvas: `${pagePath}::struct WorkOSPlanLoopsGoalConnectorCanvas`,
      blueprintFactory: `${architecturePath}::enum WorkOSPlanLoopsGoalBlueprintFactory`,
    },
    contractMigrations,
    metrics,
    summary: {
      cards: cards.size,
      routes: routes.length,
      findings: findings.length,
      classifications: classificationCounts(findings),
    },
    findings,
  };
}

function fatalReceipt(error) {
  const sourcePath = requiredSourceManifest.find(entry =>
    String(error?.message ?? "").includes(entry.relativePath)
  )?.relativePath ?? "required-source-manifest";
  return {
    schema: "TatwoWorkOSVisualGeometryAuditV2",
    ok: false,
    checkedAt: new Date().toISOString(),
    sourceSnapshot: { algorithm: "sha256", files: [] },
    contractMigrations,
    summary: {
      cards: 0,
      routes: 0,
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

function rect(id, x, y, width, height, offsetY = 0) {
  return {
    id,
    left: x,
    right: x + width,
    top: y + offsetY,
    bottom: y + height + offsetY,
    midX: x + width / 2,
    midY: y + height / 2 + offsetY,
  };
}

function point(x, y) {
  return { x, y };
}

function left(card) {
  return point(card.left, card.midY);
}

function right(card) {
  return point(card.right, card.midY);
}

function top(card) {
  return point(card.midX, card.top);
}

function bottom(card) {
  return point(card.midX, card.bottom);
}

function inside(card, width, height) {
  return card.left >= 0 && card.right <= width && card.top >= 0 && card.bottom <= height;
}

function overlaps(a, b, padding = 0) {
  return !(
    a.right + padding <= b.left
    || b.right + padding <= a.left
    || a.bottom + padding <= b.top
    || b.bottom + padding <= a.top
  );
}

function assertRoute(id, points, avoidedCards, finding, sourcePath) {
  for (let index = 1; index < points.length; index += 1) {
    const start = points[index - 1];
    const end = points[index];
    if (Math.abs(start.x - end.x) > 0.5 && Math.abs(start.y - end.y) > 0.5) {
      finding({
        id: "non_orthogonal_plg_route",
        sourcePath,
        symbol: "WorkOSPlanLoopsGoalBlueprintFactory.connectors",
        routeID: id,
        segment: [start, end],
      });
    }
    for (const card of avoidedCards) {
      if (segmentIntersectsRect(start, end, card)) {
        finding({
          id: "plg_route_hits_card",
          sourcePath,
          symbol: "WorkOSPlanLoopsGoalBlueprintFactory.connectors",
          routeID: id,
          card: card.id,
          segment: [start, end],
        });
      }
    }
  }
}

function segmentIntersectsRect(start, end, card, padding = 2) {
  const leftEdge = card.left - padding;
  const rightEdge = card.right + padding;
  const topEdge = card.top - padding;
  const bottomEdge = card.bottom + padding;
  if (Math.abs(start.x - end.x) < 0.5) {
    if (start.x <= leftEdge || start.x >= rightEdge) return false;
    return Math.max(start.y, end.y) > topEdge && Math.min(start.y, end.y) < bottomEdge;
  }
  if (Math.abs(start.y - end.y) < 0.5) {
    if (start.y <= topEdge || start.y >= bottomEdge) return false;
    return Math.max(start.x, end.x) > leftEdge && Math.min(start.x, end.x) < rightEdge;
  }
  return false;
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
