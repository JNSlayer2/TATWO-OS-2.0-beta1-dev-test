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
    id: "workos",
    relativePath: "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/WorkOS.swift",
  },
  {
    id: "mcp",
    relativePath: "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/MCPFramework.swift",
  },
  {
    id: "cli",
    relativePath: "Tools/TatwoUltraworkCLI/Sources/TatwoUltraworkCLI/main.swift",
  },
];
const contractMigrations = [
  {
    classification: "stale-contract",
    legacyCheck: "TatwoUltraworkMacApp.swift monolith label aggregation",
    replacement: "scoped dashboard rail, PLG identity column, cycle map, and blueprint factory labels",
    justification: "Current UI authority is split across explicit UltraPage symbols, so labels must be verified where each surface is rendered rather than through a concatenated monolith.",
  },
  {
    classification: "stale-contract",
    legacyCheck: "WorkOSSpineBlueprintMap visual object contract",
    replacement: "WorkOS Plan+Loops+Goal projection and two-stage PLG gates",
    justification: "The canonical object flow is OS Contract → Plan → Loops → branch PLG → supervisor gate → Goal → receipts/human gate, not the legacy Spine object graph.",
  },
  {
    classification: "stale-contract",
    legacyCheck: "runtime CLI binary freshness gate",
    replacement: "scoped WorkOSFactory, TatwoMCPRegistry, and TatwoUltraworkCLI source contracts",
    justification: "This static migration audit binds directly to the current Core/MCP/CLI symbols and source hashes instead of accepting or rejecting based on an unrelated prebuilt binary timestamp.",
  },
  {
    classification: "stale-contract",
    legacyCheck: "global curve, trigonometry, and arrowhead scan",
    replacement: "connector drawRoute and orthogonalized route-builder scope",
    justification: "Only connector route construction can violate orthogonality; arrowhead and pulse animation math outside that scope must not be globally misreported.",
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
  const workOSPath = requiredSourceManifest[2].relativePath;
  const mcpPath = requiredSourceManifest[3].relativePath;
  const cliPath = requiredSourceManifest[4].relativePath;
  const dashboardRailSource = type(sources, "page", "struct", "WorkOSDashboardPrimaryRail");
  const identityColumnSource = type(sources, "page", "struct", "WorkOSPlanLoopsGoalIdentityColumn");
  const cycleMapSource = type(sources, "page", "struct", "WorkOSPlanLoopsGoalCycleMap");
  const connectorCanvasSource = type(sources, "page", "struct", "WorkOSPlanLoopsGoalConnectorCanvas");
  const blueprintFactorySource = type(sources, "architecture", "enum", "WorkOSPlanLoopsGoalBlueprintFactory");
  const workOSFactorySource = type(sources, "workos", "enum", "WorkOSFactory");
  const mcpRegistrySource = type(sources, "mcp", "enum", "TatwoMCPRegistry");
  const cliSource = type(sources, "cli", "struct", "TatwoUltraworkCLI");
  const drawRouteSource = func(connectorCanvasSource, "drawRoute");
  const orthogonalizedSource = func(blueprintFactorySource, "orthogonalized");
  const projectionSource = func(workOSFactorySource, "makeShowLoopsProjection");
  const sandboxPolicySource = func(workOSFactorySource, "makeSandboxPolicy");
  const closeGoalSource = func(workOSFactorySource, "closeGoal");
  const cliWorkOSSource = func(cliSource, "handleWorkOS");
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
    ["dashboard_goal_object_missing", 'DashboardMetricPill(title: "Goal"'],
    ["dashboard_domain_loops_object_missing", 'DashboardMetricPill(title: "Domain Loops"'],
    ["dashboard_receipts_object_missing", 'DashboardMetricPill(title: "Receipts"'],
  ]) {
    requireMarker(dashboardRailSource, marker, {
      id,
      sourcePath: pagePath,
      symbol: "struct WorkOSDashboardPrimaryRail",
    });
  }
  requireText(dashboardRailSource, "目前 OS 合約", {
    id: "dashboard_os_contract_label_missing",
    sourcePath: pagePath,
    symbol: "struct WorkOSDashboardPrimaryRail",
  });
  requireText(dashboardRailSource, "UI 不放行", {
    id: "dashboard_no_promotion_label_missing",
    sourcePath: pagePath,
    symbol: "struct WorkOSDashboardPrimaryRail",
  });

  for (const [id, marker] of [
    ["plan_lead_responsibility_label_missing", 'kicker: "Plan", title: "主導責任"'],
    ["loops_supervisor_sub_label_missing", 'kicker: "Loops", title: "副審 + Sub"'],
    ["goal_lead_acceptance_label_missing", 'kicker: "Goal", title: "主導驗收"'],
  ]) {
    requireMarker(identityColumnSource, marker, {
      id,
      sourcePath: pagePath,
      symbol: "struct WorkOSPlanLoopsGoalIdentityColumn",
    });
  }
  requireText(identityColumnSource, "Sub 跑反例與工具", {
    id: "sub_tool_responsibility_missing",
    sourcePath: pagePath,
    symbol: "struct WorkOSPlanLoopsGoalIdentityColumn",
  });

  for (const [id, marker] of [
    ["cycle_map_connector_missing", "WorkOSPlanLoopsGoalConnectorCanvas(connectors: blueprint.connectors, progress: progress)"],
    ["cycle_map_receipt_rail_missing", "WorkOSPlanLoopsGoalReceiptRail(tags: blueprint.receiptTags)"],
  ]) {
    requireMarker(cycleMapSource, marker, {
      id,
      sourcePath: pagePath,
      symbol: "struct WorkOSPlanLoopsGoalCycleMap",
    });
  }

  for (const [id, marker] of [
    ["plg_plan_object_missing", 'node("plan", "Plan"'],
    ["plg_loops_object_missing", 'node("loops", "Loops"'],
    ["plg_goal_object_missing", 'node("goal", "Goal"'],
    ["plg_branch_object_missing", "branchBlueprints(contract: contract)"],
    ["plg_supervisor_gate_fail_missing", 'node("supervisor-fail", "副審駁回"'],
    ["plg_supervisor_gate_pass_missing", 'node("supervisor-pass", "副審通過"'],
    ["plg_goal_gate_fail_missing", 'node("lead-fail", "主導駁回"'],
    ["plg_goal_gate_pass_missing", 'node("lead-pass", "主導通過"'],
    ["plg_receipt_bank_missing", 'node("receipt-bank", "收據庫"'],
  ]) {
    requireMarker(blueprintFactorySource, marker, {
      id,
      sourcePath: architecturePath,
      symbol: "enum WorkOSPlanLoopsGoalBlueprintFactory",
    });
  }
  requireText(blueprintFactorySource, "只入庫，不自動放行", {
    id: "plg_receipt_no_promotion_missing",
    sourcePath: architecturePath,
    symbol: "enum WorkOSPlanLoopsGoalBlueprintFactory",
  });
  for (const [id, text] of [
    ["plg_sandbox_receipt_label_missing", "沙盒"],
    ["plg_human_gate_label_missing", "人工 Gate"],
    ["plg_rollback_label_missing", "回滾"],
  ]) {
    requireText(blueprintFactorySource, text, {
      id,
      sourcePath: architecturePath,
      symbol: "enum WorkOSPlanLoopsGoalBlueprintFactory",
    });
  }

  for (const [id, marker] of [
    ["core_os_contract_object_missing", 'title: "OS Contract"'],
    ["core_plan_lead_object_missing", 'title: "Plan / 主導"'],
    ["core_loops_supervisor_sub_object_missing", 'title: "Loops / 副審 + Sub"'],
    ["core_supervisor_gate_missing", 'title: "副審驗收"'],
    ["core_goal_lead_gate_missing", 'title: "Goal / 主導驗收"'],
    ["core_receipts_object_missing", 'title: "Receipts / 收據庫"'],
    ["core_projection_readonly_missing", "readOnly: true"],
    ["core_projection_no_promotion_missing", "visualizerCanPromoteRunState: false"],
  ]) {
    requireMarker(projectionSource, marker, {
      id,
      sourcePath: workOSPath,
      symbol: "WorkOSFactory.makeShowLoopsProjection",
    });
  }
  requireText(projectionSource, "支線 plan+loops+goal", {
    id: "core_branch_plg_contract_missing",
    sourcePath: workOSPath,
    symbol: "WorkOSFactory.makeShowLoopsProjection",
  });
  for (const [id, text] of [
    ["core_sandbox_gate_missing", "sandbox-gate"],
    ["core_human_gate_missing", "finish-human"],
    ["core_ready_rollback_missing", "ready/rollback"],
  ]) {
    requireText(projectionSource, text, {
      id,
      sourcePath: workOSPath,
      symbol: "WorkOSFactory.makeShowLoopsProjection",
    });
  }

  requireMarker(sandboxPolicySource, "required: mode >= .l", {
    id: "core_sandbox_policy_missing",
    sourcePath: workOSPath,
    symbol: "WorkOSFactory.makeSandboxPolicy",
  });
  requireMarker(sandboxPolicySource, "humanGateRequired: mode >= .xl", {
    id: "core_human_gate_policy_missing",
    sourcePath: workOSPath,
    symbol: "WorkOSFactory.makeSandboxPolicy",
  });
  requireMarker(closeGoalSource, "requiredForPass", {
    id: "core_goal_close_required_receipts_missing",
    sourcePath: workOSPath,
    symbol: "WorkOSFactory.closeGoal",
  });
  requireMarker(closeGoalSource, ".rollbackRequired", {
    id: "core_goal_close_rollback_missing",
    sourcePath: workOSPath,
    symbol: "WorkOSFactory.closeGoal",
  });

  const mcpCodeMarkers = [
    ["mcp_contract_id_gate_missing", 'requiredArguments: ["contractID"'],
  ];
  for (const [id, marker] of mcpCodeMarkers) {
    requireMarker(mcpRegistrySource, marker, {
      id,
      sourcePath: mcpPath,
      symbol: "enum TatwoMCPRegistry",
    });
  }
  for (const [id, text] of [
    ["mcp_os_begin_missing", "tatwo.os.begin"],
    ["mcp_os_next_missing", "tatwo.os.next"],
    ["mcp_loop_status_missing", "tatwo.os.loop.status"],
    ["mcp_receipt_submit_missing", "tatwo.os.receipt.submit"],
    ["mcp_goal_close_missing", "tatwo.os.goal.close"],
    ["mcp_dashboard_missing", "tatwo.os.dashboard"],
    ["mcp_enforce_missing", "tatwo.os.enforce"],
    ["mcp_handoff_missing", "tatwo.os.handoff"],
    ["mcp_constitution_missing", "tatwo.os.constitution"],
    ["mcp_gateway_status_missing", "tatwo.gateway.status"],
    ["mcp_gateway_dispatch_missing", "tatwo.gateway.dispatch"],
    ["mcp_sandbox_begin_missing", "tatwo.sandbox.begin"],
    ["mcp_sandbox_receipt_missing", "tatwo.sandbox.receipt"],
    ["mcp_sandbox_promote_plan_missing", "tatwo.sandbox.promote_plan"],
    ["mcp_readonly_no_promotion_missing", "只讀不可放行"],
    ["mcp_ready_rollback_missing", "READY/ROLLBACK"],
    ["mcp_promote_plan_only_missing", "永遠不直接 promote"],
  ]) {
    requireText(mcpRegistrySource, text, {
      id,
      sourcePath: mcpPath,
      symbol: "enum TatwoMCPRegistry",
    });
  }

  for (const [id, marker] of [
    ["cli_os_begin_missing", 'case "begin"'],
    ["cli_os_dashboard_missing", 'case "dashboard"'],
    ["cli_os_enforce_missing", 'case "enforce"'],
    ["cli_os_handoff_missing", 'case "handoff"'],
    ["cli_os_constitution_missing", 'case "constitution"'],
    ["cli_os_next_missing", 'case "next"'],
    ["cli_os_loop_status_missing", 'case "loop"'],
    ["cli_os_receipt_submit_missing", 'case "receipt"'],
    ["cli_os_goal_close_missing", 'case "goal"'],
    ["cli_core_begin_call_missing", "WorkOSFactory.begin("],
    ["cli_core_next_call_missing", "WorkOSFactory.next("],
    ["cli_core_loop_status_call_missing", "WorkOSFactory.loopStatus("],
    ["cli_core_receipt_submit_call_missing", "WorkOSFactory.submitReceipt("],
    ["cli_core_goal_close_call_missing", "WorkOSFactory.closeGoal("],
  ]) {
    requireMarker(cliWorkOSSource, marker, {
      id,
      sourcePath: cliPath,
      symbol: "TatwoUltraworkCLI.handleWorkOS",
    });
  }

  for (const api of ["path.addCurve", "addQuadCurve", "atan2("]) {
    if (drawRouteSource.includes(api)) {
      finding({
        id: "plg_connector_route_curve_api_present",
        sourcePath: pagePath,
        symbol: "WorkOSPlanLoopsGoalConnectorCanvas.drawRoute",
        api,
      });
    }
  }
  for (const api of ["path.addCurve", "addQuadCurve", "atan2(", " cos(", " sin("]) {
    if (orthogonalizedSource.includes(api)) {
      finding({
        id: "plg_connector_route_diagonal_api_present",
        sourcePath: architecturePath,
        symbol: "WorkOSPlanLoopsGoalBlueprintFactory.orthogonalized",
        api,
      });
    }
  }

  return {
    schema: "TatwoWorkOSFlowConsistencyAuditV2",
    ok: findings.length === 0,
    checkedAt: new Date().toISOString(),
    sourceSnapshot,
    authority: {
      dashboardRail: `${pagePath}::struct WorkOSDashboardPrimaryRail`,
      identityColumn: `${pagePath}::struct WorkOSPlanLoopsGoalIdentityColumn`,
      cycleMap: `${pagePath}::struct WorkOSPlanLoopsGoalCycleMap`,
      blueprintFactory: `${architecturePath}::enum WorkOSPlanLoopsGoalBlueprintFactory`,
      workOSFactory: `${workOSPath}::enum WorkOSFactory`,
      mcpRegistry: `${mcpPath}::enum TatwoMCPRegistry`,
      cli: `${cliPath}::struct TatwoUltraworkCLI`,
    },
    contractMigrations,
    currentContract: {
      labels: ["OS 合約", "Plan", "Loops", "Goal", "主導", "副審 + Sub", "沙盒", "工具", "收據", "人工 Gate", "READY", "ROLLBACK", "App 只讀"],
      routePolicy: "connector-route scoped straight/orthogonal line construction",
      coreSurfaces: ["WorkOS", "MCP", "CLI"],
    },
    summary: {
      findings: findings.length,
      classifications: classificationCounts(findings),
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

function fatalReceipt(error) {
  const sourcePath = requiredSourceManifest.find(entry =>
    String(error?.message ?? "").includes(entry.relativePath)
  )?.relativePath ?? "required-source-manifest";
  return {
    schema: "TatwoWorkOSFlowConsistencyAuditV2",
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
