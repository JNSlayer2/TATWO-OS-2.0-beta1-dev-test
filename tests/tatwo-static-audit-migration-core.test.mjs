#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const paths = {
  models: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPageModels.swift",
  page: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPage.swift",
  architecture: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPageArchitectureData.swift",
  deep: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/WorkOSDeepLoopMap.swift",
  workOS: "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/WorkOS.swift",
  mcp: "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/MCPFramework.swift",
  cli: "Tools/TatwoUltraworkCLI/Sources/TatwoUltraworkCLI/main.swift",
};
const audits = {
  geometry: {
    script: "scripts/tatwo-workos-visual-geometry-audit.mjs",
    requiredPaths: [paths.models, paths.page, paths.architecture],
  },
  showloops: {
    script: "scripts/tatwo-ui-showloops-layout-check.mjs",
    requiredPaths: [paths.page, paths.architecture, paths.deep],
  },
  flow: {
    script: "scripts/tatwo-workos-flow-consistency-audit.mjs",
    requiredPaths: [paths.page, paths.architecture, paths.workOS, paths.mcp, paths.cli],
  },
};

await testCanonicalFixturesAndDeterminism();
await testMissingRequiredSourceFailsClosed();
await testCommentOnlyMarkerFails();
await testMetricScopeRejectsAnotherEnum();
await testRemovedCanonicalMarkerFails();
await testConnectorRouteScopeExcludesArrowheadMath();

async function testCanonicalFixturesAndDeterminism() {
  await withFixture(async root => {
    for (const [name, spec] of Object.entries(audits)) {
      const first = runAudit(name, root);
      assert.equal(first.status, 0, first.stderr || first.stdout);
      const firstReceipt = parseReceipt(first);
      assertReceiptContract(firstReceipt, spec.requiredPaths);

      const second = runAudit(name, root);
      assert.equal(second.status, 0, second.stderr || second.stdout);
      const secondReceipt = parseReceipt(second);
      assert.deepEqual(normalizeReceipt(secondReceipt), normalizeReceipt(firstReceipt));
    }
  });
}

async function testMissingRequiredSourceFailsClosed() {
  await withFixture(async root => {
    await fs.unlink(path.join(root, paths.architecture));
    const result = runAudit("geometry", root);
    assert.equal(result.status, 1, result.stderr || result.stdout);
    const receipt = parseReceipt(result);
    assert.ok(
      receipt.findings.some(finding =>
        finding.classification === "candidate-regression"
        && finding.sourcePath === paths.architecture
        && finding.symbol === "required-source-manifest"),
      "missing required source must produce a scoped candidate-regression finding",
    );
  });
}

async function testCommentOnlyMarkerFails() {
  await withFixture(async root => {
    await replaceInFile(
      root,
      paths.page,
      "WorkOSPlanLoopsGoalIdentityColumn(contract: contract)",
      "// WorkOSPlanLoopsGoalIdentityColumn(contract: contract)",
    );
    const result = runAudit("showloops", root);
    assert.equal(result.status, 1, result.stderr || result.stdout);
    const receipt = parseReceipt(result);
    assert.ok(
      receipt.findings.some(finding =>
        finding.id === "canonical_identity_column_missing"
        && finding.classification === "candidate-regression"
        && finding.sourcePath === paths.page
        && finding.symbol === "struct WorkOSPlanLoopsGoalCycleMap"),
      "a comment-only marker must not satisfy the scoped audit",
    );
  });
}

async function testMetricScopeRejectsAnotherEnum() {
  await withFixture(async root => {
    await replaceInFile(
      root,
      paths.models,
      "static let width: CGFloat = 1120",
      "static let width: CGFloat = 1119",
    );
    const result = runAudit("geometry", root);
    assert.equal(result.status, 1, result.stderr || result.stdout);
    const receipt = parseReceipt(result);
    assert.equal(receipt.metrics.width, 1119);
    assert.ok(
      receipt.findings.some(finding =>
        finding.id === "canvas_too_narrow_for_plg_map"
        && finding.actual === 1119
        && finding.sourcePath === paths.models
        && finding.symbol === "enum WorkOSPlanLoopsGoalMetrics"),
      "the target metric enum must win over another enum with the same metric",
    );
  });
}

async function testRemovedCanonicalMarkerFails() {
  await withFixture(async root => {
    await replaceInFile(root, paths.mcp, '"tatwo.os.goal.close"', '"tatwo.os.goal.finish"');
    const result = runAudit("flow", root);
    assert.equal(result.status, 1, result.stderr || result.stdout);
    const receipt = parseReceipt(result);
    assert.ok(
      receipt.findings.some(finding =>
        finding.id === "mcp_goal_close_missing"
        && finding.classification === "candidate-regression"
        && finding.sourcePath === paths.mcp
        && finding.symbol === "enum TatwoMCPRegistry"),
      "removing a canonical MCP marker must fail closed",
    );
  });
}

async function testConnectorRouteScopeExcludesArrowheadMath() {
  await withFixture(async root => {
    const baseline = runAudit("flow", root);
    assert.equal(
      baseline.status,
      0,
      "atan2 in the arrowhead fixture must not trigger a global connector-route finding",
    );

    await replaceInFile(
      root,
      paths.page,
      "path.addLine(to: point)",
      "path.addCurve(to: point, control1: .zero, control2: .zero)",
    );
    const result = runAudit("flow", root);
    assert.equal(result.status, 1, result.stderr || result.stdout);
    const receipt = parseReceipt(result);
    assert.ok(
      receipt.findings.some(finding =>
        finding.id === "plg_connector_route_curve_api_present"
        && finding.sourcePath === paths.page
        && finding.symbol === "WorkOSPlanLoopsGoalConnectorCanvas.drawRoute"),
      "curve APIs inside the connector route must be reported",
    );
  });
}

async function withFixture(run) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "tatwo-audit-migration-"));
  try {
    await writeFixture(root);
    await run(root);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
}

async function writeFixture(root) {
  const files = fixtureSources();
  for (const [relativePath, source] of Object.entries(files)) {
    const target = path.join(root, relativePath);
    await fs.mkdir(path.dirname(target), { recursive: true });
    await fs.writeFile(target, source);
  }
}

function fixtureSources() {
  return {
    [paths.models]: `
enum OtherMetrics {
    static let width: CGFloat = 9999
}

// enum WorkOSPlanLoopsGoalMetrics { static let width: CGFloat = 7777 }
enum WorkOSPlanLoopsGoalMetrics {
    static let width: CGFloat = 1120
    static let height: CGFloat = 820
    static let contentOffsetY: CGFloat = 38
    static let receiptRailY: CGFloat = 786
}
`,
    [paths.page]: `
struct WorkOSDashboardPrimaryRail {
    var body: some View {
        Label("目前 OS 合約", systemImage: "doc.badge.gearshape")
        Badge(dashboard.contract.visualizerCanPromoteRunState ? "UI 可放行" : "UI 不放行")
        DashboardMetricPill(title: "Goal", value: dashboard.goal.status.rawValue)
        DashboardMetricPill(title: "Domain Loops", value: "3")
        DashboardMetricPill(title: "Receipts", value: "4/4")
    }
}

struct WorkOSPlanLoopsGoalIdentityColumn {
    var body: some View {
        identityBlock(kicker: "Plan", title: "主導責任", lines: ["定主線"])
        identityBlock(kicker: "Loops", title: "副審 + Sub", lines: ["Sub 跑反例與工具"])
        identityBlock(kicker: "Goal", title: "主導驗收", lines: ["檢查 loops"])
    }
}

struct WorkOSPlanLoopsGoalCycleMap {
    let contract: Contract
    var body: some View {
        TimelineView(.periodic(from: Date(), by: TatwoMotionClock.secondsPerFrame)) {
            WorkOSPlanLoopsGoalIdentityColumn(contract: contract)
            WorkOSPlanLoopsGoalConnectorCanvas(connectors: blueprint.connectors, progress: progress)
            Group {}
                .offset(y: WorkOSPlanLoopsGoalMetrics.contentOffsetY)
            WorkOSPlanLoopsGoalLegend(modeSummary: blueprint.modeSummary)
                .position(x: 604, y: 27)
            WorkOSPlanLoopsGoalReceiptRail(tags: blueprint.receiptTags)
                .frame(width: 860, height: 42)
                .position(x: 660, y: WorkOSPlanLoopsGoalMetrics.receiptRailY)
        }
    }
}

struct WorkOSPlanLoopsGoalConnectorCanvas {
    private enum SegmentAxis { case horizontal, vertical }

    private func drawRoute(context: inout GraphicsContext, connector: Connector) {
        var path = Path()
        for point in connector.points {
            path.addLine(to: point)
        }
    }

    private func drawPulseTrain(context: inout GraphicsContext, connector: Connector, phase: Double) {
        for pulse in pulseTrain(progress: progress, phase: phase) {
            guard let located = pointAlong(connector.points, t: pulse.t) else { continue }
            drawPulse(context: &context, located: located, color: connector.flowColor, scale: pulse.scale, opacity: pulse.opacity)
        }
    }

    private func drawPulse(
        context: inout GraphicsContext,
        located: (point: CGPoint, axis: SegmentAxis),
        color: Color,
        scale: CGFloat,
        opacity: Double
    ) {
        let markerRect: CGRect
        let glowRect: CGRect
        switch located.axis {
        case .horizontal:
            markerRect = CGRect(x: located.point.x - 9 * scale, y: located.point.y - 1.7 * scale, width: 18 * scale, height: 3.4 * scale)
            glowRect = CGRect(x: located.point.x - 12 * scale, y: located.point.y - 3.4 * scale, width: 24 * scale, height: 6.8 * scale)
        case .vertical:
            markerRect = CGRect(x: located.point.x - 1.7 * scale, y: located.point.y - 9 * scale, width: 3.4 * scale, height: 18 * scale)
            glowRect = CGRect(x: located.point.x - 3.4 * scale, y: located.point.y - 12 * scale, width: 6.8 * scale, height: 24 * scale)
        }
        context.fill(Path(roundedRect: glowRect, cornerRadius: 2 * scale), with: .color(color))
        context.fill(Path(roundedRect: markerRect, cornerRadius: 1.6 * scale), with: .color(color))
    }

    private func drawArrowhead(context: inout GraphicsContext, connector: Connector) {
        let ignoredArrowheadAngle = atan2(1, 1)
        path.addLine(to: .zero)
    }

    private func pulseTrain(progress: Double, phase: Double) -> [(t: CGFloat, scale: CGFloat, opacity: Double)] {
        [0.0, 0.38, 0.72].enumerated().map { index, offset in
            (CGFloat(offset), index == 0 ? 1 : 0.68, index == 0 ? 0.92 : 0.44)
        }
    }

    private func pointAlong(_ points: [CGPoint], t: CGFloat) -> (point: CGPoint, axis: SegmentAxis)? {
        (points[0], .horizontal)
    }
}
`,
    [paths.architecture]: `
enum WorkOSPlanLoopsGoalBlueprintFactory {
    static func make(contract: Contract) -> Blueprint {
        let main = mainlineNodes(contract: contract)
        let branches = branchNodes(contract: contract)
        let verdicts = verdictNodes()
        let receipts = receiptNode(contract: contract)
        let nodes = main + branches + verdicts + receipts
        return Blueprint(nodes: nodes, connectors: connectors(nodes: nodes, contract: contract))
    }

    private static func mainlineNodes(contract: Contract) -> [Node] {
        [
            node("task", "任務開始", CGRect(x: 238, y: 178, width: 120, height: 72)),
            node("plan", "Plan", CGRect(x: 392, y: 178, width: 130, height: 72)),
            node("loops", "Loops", CGRect(x: 558, y: 178, width: 196, height: 72)),
            node("goal", "Goal", CGRect(x: 808, y: 178, width: 132, height: 72)),
            node("done", "完工", CGRect(x: 970, y: 178, width: 124, height: 72))
        ]
    }

    private static func responsibilityNodes(contract: Contract) -> [Node] {
        [
            node("lead-plan-duty", "主導責任", "Plan"),
            node("supervisor-duty", "副審 + Sub", "Loops"),
            node("lead-goal-duty", "主導驗收", "Goal")
        ]
    }

    private static func branchNodes(contract: Contract) -> [Node] {
        let branches = branchBlueprints(contract: contract)
        return branches.map { node($0.id, $0.title, $0.rect) }
    }

    private static func branchBlueprints(contract: Contract) -> [Branch] {
        [
            .init(id: "branch-read", title: "讀碼支線", subtitle: "支線 plan+loops+goal"),
            .init(id: "branch-patch", title: "修補支線", subtitle: "最小 patch"),
            .init(id: "branch-test", title: "測試支線", subtitle: "產出收據")
        ]
    }

    private static func verdictNodes() -> [Node] {
        [
            node("supervisor-fail", "副審駁回", CGRect(x: 315, y: 494, width: 175, height: 60)),
            node("supervisor-pass", "副審通過", CGRect(x: 595, y: 494, width: 175, height: 60)),
            node("lead-fail", "主導駁回", CGRect(x: 315, y: 618, width: 175, height: 60)),
            node("lead-pass", "主導通過", CGRect(x: 595, y: 618, width: 175, height: 60))
        ]
    }

    private static func receiptNode(contract: Contract) -> [Node] {
        [node("receipt-bank", "收據庫", "只入庫，不自動放行", CGRect(x: 876, y: 504, width: 180, height: 78))]
    }

    private static func connectors(nodes: [Node], contract: Contract) -> [Connector] {
        [
            connector("main-task-plan", [right(r("task")), left(r("plan"))]),
            connector("main-plan-loops", [right(r("plan")), left(r("loops"))]),
            connector("main-loops-goal", [right(r("loops")), left(r("goal"))]),
            connector("main-goal-done", [right(r("goal")), left(r("done"))]),
            connector("\\(id)-to-review-bus", [bottom(r(id)), CGPoint(x: 552, y: 452)]),
            connector("lead-pass-to-goal", [right(r("lead-pass")), CGPoint(x: 1084, y: r("lead-pass").midY), bottom(r("goal"))]),
            connector("goal-to-receipts", [bottom(r("goal")), top(r("receipt-bank"))]),
            connector("receipts-to-goal", [top(r("receipt-bank")), bottom(r("goal"))])
        ]
    }

    private static func receiptTags(contract: Contract) -> [String] {
        ["contractID", "身份組", "副審", "測試/截圖", "沙盒", "人工 Gate", "回滾", "cleanup"]
    }

    private static func connector(_ id: String, _ points: [CGPoint]) -> Connector {
        Connector(id: id, points: orthogonalized(points).filterAdjacentDuplicates())
    }

    private static func orthogonalized(_ points: [CGPoint]) -> [CGPoint] {
        points
    }
}
`,
    [paths.deep]: `
struct WorkOSDeepLoopMap {
    let contract: Contract
    var body: some View {
        TimelineView(.periodic(from: Date(), by: TatwoMotionClock.secondsPerFrame)) {
            ShowLoopsOrthogonalProjection(projection: contract.showLoopsProjection, progress: progress)
            DeepLoopLegendRow(plan: plan)
        }
    }
}

private enum ShowLoopsProjectionLayoutFactory {
    static func make(projection: Projection, size: CGSize) -> Layout {
        let routes = visibleEdges(from: projection).map {
            routePoints(from: source, to: target, edge: $0, canvasWidth: size.width)
        }
        return Layout(routes: routes)
    }

    private static func routePoints(from source: CGRect, to target: CGRect, edge: Edge, canvasWidth: CGFloat) -> [CGPoint] {
        orthogonal([CGPoint(x: source.maxX, y: source.midY), CGPoint(x: target.minX, y: target.midY)])
    }

    private static func orthogonal(_ points: [CGPoint]) -> [CGPoint] {
        points.reduce(into: [CGPoint]()) { result, point in
            guard result.last != point else { return }
            result.append(point)
        }
    }
}

private enum ShowLoopsArrowEngine {
    static func draw(route: Route, progress: Double, in context: inout GraphicsContext) {
        var path = Path()
        for point in route.points { path.addLine(to: point) }
        drawPulse(route: route, progress: progress, in: &context)
        drawArrowHead(route: route, in: &context)
    }

    private static func drawRoute(route: Route, in context: inout GraphicsContext) {
        var path = Path()
        for point in route.points { path.addLine(to: point) }
    }

    private static func drawPulse(route: Route, progress: Double, in context: inout GraphicsContext) {
        for offset in [0.0, 0.38, 0.72] {
            let sample = route.points[0]
            let markerRect = CGRect(x: sample.x - 9, y: sample.y - 1.7, width: 18, height: 3.4)
            let glowRect = CGRect(x: sample.x - 12, y: sample.y - 3.4, width: 24, height: 6.8)
            context.fill(Path(roundedRect: glowRect, cornerRadius: 2), with: .color(route.color))
            context.fill(Path(roundedRect: markerRect, cornerRadius: 1.6), with: .color(route.color))
        }
    }

    private static func drawArrowHead(route: Route, in context: inout GraphicsContext) {
        let ignoredArrowheadAngle = atan2(1, 1)
        path.addLine(to: .zero)
    }
}

enum DeepLoopPlanFactory {
    static func make(contract: Contract) -> Plan {
        let badges = [contract.showLoopsProjection.readOnly ? "只讀" : "可寫"]
        let lanes = [
            entryLane(contract, index: 1),
            identityLane(contract, kind: "code", index: 2),
            runtimeLane(contract, kind: "code", index: 3),
            gateLane(contract, kind: "code", index: 4)
        ]
        return Plan(badges: badges, lanes: lanes)
    }
}

struct AnimatedMiniArrow {
    var body: some View {
        Canvas { context, size in
            for pulse in pulseTrain(progress: progress) {
                let markerCenter = CGPoint(x: 10, y: 10)
                let markerRect = CGRect(x: markerCenter.x - 5.2, y: markerCenter.y - 1.25, width: 10.4, height: 2.5)
                let glowRect = CGRect(x: markerCenter.x - 7.2, y: markerCenter.y - 3.0, width: 14.4, height: 6.0)
                context.fill(Path(roundedRect: glowRect, cornerRadius: 2.2), with: .color(color))
                context.fill(Path(roundedRect: markerRect, cornerRadius: 1.2), with: .color(color))
            }
        }
    }

    private func pulseTrain(progress: Double) -> [(t: CGFloat, scale: CGFloat, opacity: Double)] {
        [0.0, 0.42, 0.78].enumerated().map { index, offset in
            (CGFloat(offset), index == 0 ? 1 : 0.68, index == 0 ? 1 : 0.52)
        }
    }
}
`,
    [paths.workOS]: `
public enum WorkOSFactory {
    public static func begin() -> Contract { makeShowLoopsProjection() }
    public static func next() {}
    public static func loopStatus() {}
    public static func submitReceipt() {}
    public static func closeGoal() -> Result {
        let required = contract.receiptRequirements.filter(\\.requiredForPass)
        return Result(status: required.isEmpty ? .passed : .rollbackRequired)
    }

    private static func makeSandboxPolicy(mode: Mode) -> SandboxPolicy {
        SandboxPolicy(required: mode >= .l, humanGateRequired: mode >= .xl)
    }

    private static func makeShowLoopsProjection() -> Projection {
        node(id: "contract", title: "OS Contract", canPromoteRunState: false)
        node(id: "plan-lead", title: "Plan / 主導", canPromoteRunState: false)
        node(id: "loops-cycle", title: "Loops / 副審 + Sub", plainPurpose: "副審監督支線 plan+loops+goal", canPromoteRunState: false)
        node(id: "supervisor-gate", title: "副審驗收", canPromoteRunState: false)
        node(id: "goal-lead-gate", title: "Goal / 主導驗收", canPromoteRunState: false)
        node(id: "receipts", title: "Receipts / 收據庫", plainPurpose: "sandbox rollback", canPromoteRunState: false)
        node(id: "sandbox-gate", title: "Sandbox Gate", canPromoteRunState: false)
        node(id: "finish-human", title: "完工 / 提交人類", plainPurpose: "ready/rollback；真正放行仍由人類確認", canPromoteRunState: false)
        edge(id: "edge-supervisor-reject", label: "副審不過重跑")
        edge(id: "edge-supervisor-pass", label: "副審通過送主導")
        edge(id: "edge-goal-reject", label: "主導不過重派")
        edge(id: "edge-goal-receipts", label: "主導通過收據入庫")
        edge(id: "edge-sandbox-finish", label: "ready or rollback")
        return Projection(
            readOnly: true,
            visualizerCanPromoteRunState: false,
            layoutHint: "Plan(主導) → Loops(副審+Sub) → 支線 plan+loops+goal → 副審 Gate → Goal(主導驗收)"
        )
    }
}
`,
    [paths.mcp]: `
public enum TatwoMCPRegistry {
    public static let tools = [
        tool(name: "tatwo.os.begin", purpose: "沒有 contractID fail closed"),
        tool(name: "tatwo.os.next", requiredArguments: ["contractID"]),
        tool(name: "tatwo.os.loop.status", purpose: "只讀狀態；App 可視化不可直接放行", requiredArguments: ["contractID"]),
        tool(name: "tatwo.os.receipt.submit", requiredArguments: ["contractID", "receiptID"]),
        tool(name: "tatwo.os.goal.close", purpose: "不足則 rollback_required", requiredArguments: ["contractID", "receiptIDs"]),
        tool(name: "tatwo.os.dashboard", purpose: "READY/ROLLBACK；只讀不可放行"),
        tool(name: "tatwo.os.enforce", requiredArguments: ["contractID", "toolName"]),
        tool(name: "tatwo.os.handoff"),
        tool(name: "tatwo.os.constitution"),
        tool(name: "tatwo.gateway.status"),
        tool(name: "tatwo.gateway.dispatch", requiredArguments: ["contractID", "model", "prompt"]),
        tool(name: "tatwo.sandbox.begin", requiredArguments: ["contractID"]),
        tool(name: "tatwo.sandbox.receipt", requiredArguments: ["contractID", "sandboxID"]),
        tool(name: "tatwo.sandbox.promote_plan", purpose: "永遠不直接 promote", requiredArguments: ["contractID", "sandboxID"])
    ]
}
`,
    [paths.cli]: `
struct TatwoUltraworkCLI {
    static func handleWorkOS(_ args: [String]) throws {
        switch subcommand {
        case "begin":
            try WorkOSFactory.begin()
        case "dashboard":
            TatwoWorkOSDashboardFactory.make(contract: contract)
        case "enforce":
            WorkOSEnforcementFactory.enforce(intent, contract: contract)
        case "handoff":
            WorkOSEnforcementFactory.handoffPack(contract: contract)
        case "constitution":
            WorkOSEnforcementFactory.constitution()
        case "next":
            try WorkOSFactory.next(contractID: contractID)
        case "loop":
            try WorkOSFactory.loopStatus(contractID: contractID)
        case "receipt":
            WorkOSFactory.submitReceipt(contractID: contractID, receiptID: receiptID)
        case "goal":
            try WorkOSFactory.closeGoal(contractID: contractID, suppliedReceiptIDs: receiptIDs)
        default:
            break
        }
    }
}
`,
  };
}

function runAudit(name, cwd) {
  const result = spawnSync(process.execPath, [path.join(repoRoot, audits[name].script)], {
    cwd,
    encoding: "utf8",
  });
  if (result.error) throw result.error;
  return result;
}

function parseReceipt(result) {
  assert.notEqual(result.stdout.trim(), "", result.stderr || "audit emitted no JSON receipt");
  return JSON.parse(result.stdout);
}

function assertReceiptContract(receipt, requiredPaths) {
  assert.equal(receipt.sourceSnapshot?.algorithm, "sha256");
  assert.deepEqual(receipt.sourceSnapshot.files.map(file => file.path), requiredPaths);
  assert.ok(receipt.sourceSnapshot.files.every(file => /^[a-f0-9]{64}$/.test(file.sha256)));
  assert.ok(Array.isArray(receipt.contractMigrations) && receipt.contractMigrations.length > 0);
  for (const migration of receipt.contractMigrations) {
    assert.equal(migration.classification, "stale-contract");
    assert.equal(typeof migration.justification, "string");
    assert.ok(migration.justification.trim().length > 0);
  }
  for (const finding of receipt.findings) {
    assert.ok(["stale-contract", "candidate-regression"].includes(finding.classification));
    assert.equal(typeof finding.sourcePath, "string");
    assert.equal(typeof finding.symbol, "string");
    if (finding.classification === "stale-contract") {
      assert.equal(typeof finding.justification, "string");
      assert.ok(finding.justification.trim().length > 0);
    }
  }
}

function normalizeReceipt(receipt) {
  const clone = structuredClone(receipt);
  delete clone.checkedAt;
  return clone;
}

async function replaceInFile(root, relativePath, from, to) {
  const target = path.join(root, relativePath);
  const source = await fs.readFile(target, "utf8");
  assert.ok(source.includes(from), `fixture marker missing before mutation: ${from}`);
  await fs.writeFile(target, source.replace(from, to));
}

console.log("tatwo-static-audit-migration-core.test.mjs: ok");
