// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPage.swift；改動 103 行（原因：B2 依裁決拆除手冊的模式路由段落）
import SwiftUI
import Combine
import AppKit

struct WorkflowPage: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let snapshot: TatwoAppSnapshot
    @Environment(\.tatwoSurfaceKind) private var surface
    @State private var expandedChapterIDs: Set<String> = []

    private var chapters: [UltraManualChapter] { UltraManualData.manifestChapters }

    var body: some View {
        VStack(alignment: .leading, spacing: surface == .panel ? 10 : 14) {
            UltraManualHero(snapshot: snapshot, surface: surface)
            UltraArchitectureManifestSourceCard(compact: surface == .panel)
            UltraDocumentArchitectureCard(compact: surface == .panel)

            // Live 沙盒 run + GBrain 記憶(OS只讀)可視化（goal#2-C 沙盒可視化 + GBrain 讀取）。
            WorkOSLiveEvidenceSection()

            VStack(alignment: .leading, spacing: surface == .panel ? 7 : 9) {
                ForEach(chapters) { chapter in
                    UltraManualChapterRow(
                        chapter: chapter,
                        isExpanded: expandedChapterIDs.contains(chapter.id),
                        compact: surface == .panel
                    ) {
                        toggle(chapter.id)
                    }
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if expandedChapterIDs.contains(id) {
            expandedChapterIDs.remove(id)
        } else {
            expandedChapterIDs.insert(id)
        }
    }
}
struct WorkOSDashboardStatusTile: View {
    let title: String
    let detail: String
    let state: InstallState
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 10.2, weight: .black, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
            }
            Text(detail)
                .font(.system(size: 8.8, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.62)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .background(color.opacity(0.060), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(statusColor.opacity(0.16), lineWidth: 1))
    }

    private var statusColor: Color {
        switch state {
        case .installed: .green
        case .missing: .red
        case .skipped: .orange
        case .unknown: .gray
        }
    }
}

struct WorkOSDashboardPrimaryRail: View {
    let dashboard: TatwoWorkOSDashboardSnapshot
    @Environment(\.tatwoSurfaceKind) private var surface

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("目前 OS 合約", systemImage: "doc.badge.gearshape")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Badge(dashboard.contract.configStage.rawValue)
                Badge(dashboard.contract.failClosed ? "Fail Closed" : "開放")
                Badge(dashboard.contract.visualizerCanPromoteRunState ? "UI 可放行" : "UI 不放行")
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: surface == .panel ? 98 : 156), spacing: 8)], spacing: 8) {
                DashboardMetricPill(title: "Goal", value: dashboard.goal.status.rawValue)
                DashboardMetricPill(title: "Mode", value: dashboard.goal.mode.rawValue)
                DashboardMetricPill(title: "Scenario", value: dashboard.goal.scenario)
                DashboardMetricPill(title: "Contract", value: String(dashboard.contract.contractID.suffix(8)))
                DashboardMetricPill(title: "Domain Loops", value: "\(dashboard.lanes.filter { $0.kind == .domain }.count)")
                DashboardMetricPill(title: "Receipts", value: "\(dashboard.receiptRail.submittedCount)/\(dashboard.receiptRail.requiredCount)")
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.forward.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption.weight(.black))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text("下一步")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.secondary)
                    Text(dashboard.nextAction.plainText)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(surface == .panel ? 2 : 3)
                    Text(dashboard.nextAction.commandHint)
                        .font(.system(size: 9.2, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color.primary.opacity(0.032), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(11)
        .background(Color.primary.opacity(0.034), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }
}



struct WorkOSDashboardRailCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.black))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }
}



struct WorkOSDashboardOutcomeTile: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.headline.weight(.black))
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.black))
                    .foregroundStyle(color)
                Text(subtitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(color.opacity(0.075), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(color.opacity(0.18), lineWidth: 1))
    }
}





struct WorkOSShowLoopsCard: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let contract: TatwoWorkOSContractV1
    @Environment(\.tatwoSurfaceKind) private var surface

    private var projection: WorkOSShowLoopsProjection {
        contract.showLoopsProjection
    }

    private var template: WorkOSFlowTemplate {
        WorkOSFlowTemplateFactory.make(contract: contract)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("專屬 Show Loops", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    .font(.caption.weight(.black))
                Spacer()
                Badge(projection.readOnly ? "只讀" : "可寫")
                Badge(projection.visualizerCanPromoteRunState ? "可放行" : "不可放行")
                Badge("節點 \(template.nodes.count)")
            }

            if surface == .panel {
                Text(WorkOSFlowTemplateFactory.surfaceSummary(contract: contract))
                    .font(.system(size: 12.8, weight: .black, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                WorkOSPanelFlowSummary(contract: contract, template: template)
            } else {
                WorkOSBlockArrowMap(contract: contract, height: WorkOSFlowSizing.height(for: contract.mode))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    WorkOSDeepLoopMap(contract: contract, surface: .workflow)

                    VStack(spacing: 6) {
                        ForEach(projection.nodes.prefix(8)) { node in
                            WorkOSShowLoopNodeRow(node: node)
                        }
                    }
                }
                .padding(.top, 7)
            } label: {
                Label("細節模組 / 收據", systemImage: "list.bullet.rectangle")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(LiquidGlassTokens.brandAccent.opacity(0.052), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct WorkOSRuntimeModuleStrip: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let contract: TatwoWorkOSContractV1

    private var modules: [(String, String, String, Color)] {
        [
            ("技能", skillLabel, "技能", LiquidGlassTokens.brandAccent),
            ("MCP", "GitNexus / Pro / App", "工具", LiquidGlassTokens.brandAccent),
            ("模型閘道", "路由 / 同串", "fast", .cyan),
            ("JS / Swift", scriptLabel, "腳本", .pink),
            ("沙盒", sandboxLabel, sandboxBadge, .brown),
            ("主機保護", "不碰簽章 app / secrets", "安全", .gray)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Label("執行模組", systemImage: "shippingbox.and.arrow.backward")
                    .font(.system(size: 10.8, weight: .black, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Badge(contract.configStage == .staging ? "暫存" : "啟用")
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 154), spacing: 8)], spacing: 8) {
                ForEach(Array(modules.enumerated()), id: \.offset) { _, module in
                    WorkOSRuntimeModuleTile(title: module.0, bodyText: module.1, badge: module.2, color: module.3)
                }
            }
        }
        .padding(9)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var kind: String {
        switch contract.scenario {
        case "ui-ux", "design", "editing": return "ui"
        case "trading-risk", "trading": return "trading"
        case "modeling", "video-research": return "modeling"
        case "research": return "research"
        case "daily": return "daily"
        default: return "code"
        }
    }

    private var skillLabel: String {
        switch kind {
        case "ui": return "tatwo + UI 技能"
        case "trading": return "tatwo + 風控技能"
        case "research": return "tatwo + 研究技能"
        case "modeling": return "tatwo + 建模技能"
        default: return "tatwo + 領域技能"
        }
    }

    private var scriptLabel: String {
        switch kind {
        case "ui": return "截圖 / 煙測"
        case "trading": return "只讀風控"
        case "research": return "來源抽查"
        case "modeling": return "樣本小測"
        default: return "測試 / 差異"
        }
    }

    private var sandboxLabel: String {
        if contract.sandboxPolicy.required && contract.sandboxPolicy.humanGateRequired { return "暫存 / Colima / 人工" }
        if contract.sandboxPolicy.required { return "暫存 / 預備" }
        return "預備 / 預演"
    }

    private var sandboxBadge: String {
        contract.sandboxPolicy.required ? "必須" : "視風險"
    }
}

struct WorkOSRuntimeModuleTile: View {
    let title: String
    let bodyText: String
    let badge: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 10.2, weight: .black, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
                Spacer(minLength: 0)
                Text(badge)
                    .font(.system(size: 8.2, weight: .black, design: .rounded))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }
            Text(bodyText)
                .font(.system(size: 9.0, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.60)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
        .background(color.opacity(0.080), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(color.opacity(0.18), lineWidth: 1))
    }
}

struct WorkOSPanelFlowSummary: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let contract: TatwoWorkOSContractV1
    let template: WorkOSFlowTemplate
    @Environment(\.tatwoSurfaceKind) private var surface

    private var steps: [(String, String, Color)] {
        [
            ("合約", contract.mode.rawValue, .green),
            ("主線", contract.mainlineLoop.ownerIdentity.chineseName, .cyan),
            ("分支", "多域 \(contract.domainLoops.count)", LiquidGlassTokens.brandAccent),
            ("沙盒", contract.sandboxPolicy.required ? "必須" : "預演", .brown),
            ("收據", "\(contract.receiptRequirements.filter(\.requiredForPass).count) 項", .teal),
            ("關卡", contract.sandboxPolicy.humanGateRequired ? "人工" : "檢查", .gray)
        ]
    }

    private var domainNames: [String] {
        let names = contract.domainLoops.prefix(4).map { $0.domain.plainName }
        return names.isEmpty ? ["主線"] : names
    }

    var body: some View {
        VStack(alignment: .leading, spacing: surface == .panel ? 8 : 10) {
            HStack(spacing: 8) {
                Label("流程摘要", systemImage: "rectangle.compress.vertical")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.primary)
                Text(surface == .panel ? "卡片化摘要；完整圖開 OS 窗" : "完整流程圖請開 OS 窗")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Spacer(minLength: 0)
                Button {
                    NotificationCenter.default.post(name: .tatwoOpenWorkOSWindow, object: nil)
                } label: {
                    Label("開 OS 窗", systemImage: "macwindow")
                        .font(.caption2.weight(.black))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .tatwoAdaptiveCapsule()
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            if surface == .panel {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)], spacing: 7) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        WorkOSPanelFlowStep(title: step.0, detail: step.1, color: step.2)
                    }
                }
                .padding(9)
                .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.075), lineWidth: 1))
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        WorkOSPanelFlowStep(title: step.0, detail: step.1, color: step.2)
                        if index < steps.count - 1 {
                            Rectangle()
                                .fill(Color.primary.opacity(LiquidGlassTokens.routeLineOpacity))
                                .frame(width: 24, height: 2)
                                .overlay(alignment: .trailing) {
                                    Rectangle()
                                        .fill(Color.primary.opacity(LiquidGlassTokens.routePulseOpacity * 0.42))
                                        .frame(width: 6, height: 6)
                                        .offset(x: 2)
                                }
                                .padding(.horizontal, 5)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
            }

        }
    }
}

struct WorkOSPanelFlowStep: View {
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13.0, weight: .black, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 10.4, weight: .black, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background(color.opacity(0.070), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(color.opacity(0.22), lineWidth: 1))
    }
}

struct WorkOSBlockArrowMap: View {
    let contract: TatwoWorkOSContractV1
    var height: CGFloat = 300
    @Environment(\.tatwoSurfaceKind) private var surface

    private var renderScale: CGFloat { 1.0 }

    var body: some View {
        WorkOSPlanLoopsGoalCycleMap(contract: contract)
            .frame(width: WorkOSPlanLoopsGoalMetrics.width, height: WorkOSPlanLoopsGoalMetrics.height)
            .scaleEffect(renderScale, anchor: .topLeading)
            .frame(
                width: activeSize.width * renderScale,
                height: activeSize.height * renderScale,
                alignment: .topLeading
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }

    private var activeSize: CGSize {
        CGSize(width: WorkOSPlanLoopsGoalMetrics.width, height: WorkOSPlanLoopsGoalMetrics.height)
    }
}


struct WorkOSPlanLoopsGoalCycleMap: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let contract: TatwoWorkOSContractV1
    let selectedNodeID: String?
    let nodeOverrides: [String: WorkOSPlanLoopsGoalNodeOverride]
    let editableNodeIDs: Set<String>
    let onNodeTap: ((String) -> Void)?

    init(
        contract: TatwoWorkOSContractV1,
        selectedNodeID: String? = nil,
        nodeOverrides: [String: WorkOSPlanLoopsGoalNodeOverride] = [:],
        editableNodeIDs: Set<String> = [],
        onNodeTap: ((String) -> Void)? = nil
    ) {
        self.contract = contract
        self.selectedNodeID = selectedNodeID
        self.nodeOverrides = nodeOverrides
        self.editableNodeIDs = editableNodeIDs
        self.onNodeTap = onNodeTap
    }

    private var blueprint: WorkOSPlanLoopsGoalBlueprint {
        WorkOSPlanLoopsGoalBlueprintFactory.make(contract: contract)
    }

    var body: some View {
        TimelineView(.periodic(from: Date(), by: TatwoMotionClock.secondsPerFrame)) { timeline in
            let progress = TatwoMotionClock.progress(for: timeline.date)
            ZStack(alignment: .topLeading) {
                WorkOSPlanLoopsGoalBackground()
                Group {
                    WorkOSPlanLoopsGoalLaneBackdrop()
                    WorkOSPlanLoopsGoalIdentityColumn(contract: contract)
                    WorkOSPlanLoopsGoalConnectorCanvas(connectors: blueprint.connectors, progress: progress)

                    ForEach(blueprint.nodes) { node in
                        let renderedNode = node.applying(nodeOverrides[node.id])
                        WorkOSPlanLoopsGoalNodeView(node: renderedNode)
                            .overlay {
                                if selectedNodeID == node.id {
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.92), lineWidth: 2.3)
                                        .shadow(color: Color.white.opacity(0.28), radius: 8)
                                }
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .onTapGesture {
                                guard editableNodeIDs.contains(node.id) else { return }
                                onNodeTap?(node.id)
                            }
                            .frame(width: node.rect.width, height: node.rect.height)
                            .position(x: node.rect.midX, y: node.rect.midY)
                    }
                }
                .offset(y: WorkOSPlanLoopsGoalMetrics.contentOffsetY)

                WorkOSPlanLoopsGoalLegend(modeSummary: blueprint.modeSummary)
                    .position(x: 604, y: 27)

                WorkOSPlanLoopsGoalReceiptRail(tags: blueprint.receiptTags)
                    .frame(width: 860, height: 42)
                    .position(x: 660, y: WorkOSPlanLoopsGoalMetrics.receiptRailY)
            }
            .frame(width: WorkOSPlanLoopsGoalMetrics.width, height: WorkOSPlanLoopsGoalMetrics.height)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LiquidGlassTokens.canvasBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: LiquidGlassTokens.shapeStyle)
                            .fill(.ultraThinMaterial)
                            .opacity(0.68)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: LiquidGlassTokens.shapeStyle)
                            .fill(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.tintOpacity))
                    }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(LiquidGlassTokens.strokeOpacity), lineWidth: 1)
            )
        }
    }
}

struct WorkOSPlanLoopsGoalBackground: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    var body: some View {
        ZStack(alignment: .topLeading) {
            LiquidGlassTokens.canvasBackground
            RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusCard, style: LiquidGlassTokens.shapeStyle)
                .fill(.ultraThinMaterial)
                .opacity(0.72)
            RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusCard, style: LiquidGlassTokens.shapeStyle)
                .fill(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.tintOpacity))
            gridLines
        }
    }

    private var gridLines: some View {
        Canvas { context, size in
            let stroke = StrokeStyle(lineWidth: 1)
            for x in stride(from: CGFloat(40), through: size.width, by: 80) {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(Color.primary.opacity(0.040)), style: stroke)
            }
            for y in stride(from: CGFloat(50), through: size.height, by: 70) {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(Color.primary.opacity(0.034)), style: stroke)
            }
        }
    }
}

struct WorkOSPlanLoopsGoalLaneBackdrop: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    var body: some View {
        ZStack(alignment: .topLeading) {
            identityDivider
            lane(title: "主線", subtitle: "任務 → Plan → Loops → Goal → 完工", color: .cyan, rect: CGRect(x: 224, y: 152, width: 870, height: 132))
            lane(title: "支線 loops", subtitle: "每條支線自己 plan / loops / goal，最後只交證據", color: .yellow, rect: CGRect(x: 258, y: 304, width: 820, height: 142))
            lane(title: "驗收閉環", subtitle: "副審先擋，主導再擋；不過回支線，不硬過", color: .orange, rect: CGRect(x: 258, y: 462, width: 820, height: 234))
        }
    }

    private var identityDivider: some View {
        Canvas { context, _ in
            var divider = Path()
            divider.move(to: CGPoint(x: 210, y: 34))
            divider.addLine(to: CGPoint(x: 210, y: 704))
            context.stroke(divider, with: .color(LiquidGlassTokens.brandAccent.opacity(0.24)), style: StrokeStyle(lineWidth: 1.25, dash: [7, 7]))

            var topRule = Path()
            topRule.move(to: CGPoint(x: 226, y: 132))
            topRule.addLine(to: CGPoint(x: 1090, y: 132))
            context.stroke(topRule, with: .color(Color.primary.opacity(0.055)), lineWidth: 1)
        }
    }

    private func lane(title: String, subtitle: String, color: Color, rect: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 17, style: .continuous)
            .fill(color.opacity(0.060))
            .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(color.opacity(0.22), lineWidth: 1))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .black, design: .rounded))
                        .foregroundStyle(color.opacity(0.95))
                    Text(subtitle)
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .tatwoAdaptiveCapsule()
                .background(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.tintOpacity), in: Capsule())
                .overlay(Capsule().strokeBorder(color.opacity(0.30), lineWidth: 1))
                .offset(x: rect.minX + 13, y: rect.minY - 10)
            }
    }
}

struct WorkOSPlanLoopsGoalIdentityColumn: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let contract: TatwoWorkOSContractV1

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 7) {
                Circle()
                    .fill(LiquidGlassTokens.brandAccent.opacity(0.82))
                    .frame(width: 6, height: 6)
                Text("身份組")
                    .font(.system(size: 13.5, weight: .black, design: .rounded))
                    .foregroundStyle(.primary)
                Text("左側定責任")
                    .font(.system(size: 10.8, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            identityBlock(kicker: "Plan", title: "主導責任", color: LiquidGlassTokens.brandAccent, lines: [
                "定主線架構",
                "定驗收標準",
                "限制改動邊界"
            ])

            identityBlock(kicker: "Loops", title: "副審 + Sub", color: LiquidGlassTokens.brandAccent, lines: [
                "副審盯支線偏航",
                "Sub 跑反例與工具",
                "只交證據不自決"
            ])

            identityBlock(kicker: "Goal", title: "主導驗收", color: LiquidGlassTokens.brandAccent, lines: [
                "檢查 loops 是否離題",
                "收斂未驗項",
                "通過才交人類"
            ])
        }
        .frame(width: 174, alignment: .topLeading)
        .position(x: 112, y: 220)
    }

    private func identityBlock(kicker: String, title: String, color: Color, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(kicker)
                    .font(.system(size: 10.5, weight: .black, design: .rounded))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 12.2, weight: .black, design: .rounded))
                    .foregroundStyle(.primary)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text("\(index + 1). \(line)")
                        .font(.system(size: 10.8, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)
                }
            }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color.opacity(0.78))
                .frame(width: 3)
        }
    }
}

struct WorkOSPlanLoopsGoalLegend: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let modeSummary: String

    var body: some View {
        HStack(spacing: 8) {
            Label("Plan + Loops Cycle + Goal", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 12.0, weight: .black, design: .rounded))
                .foregroundStyle(.primary)
            Text(modeSummary)
                .font(.system(size: 11.4, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            legendKey("退", .red)
            legendKey("過", .green)
            legendKey("支", .orange)
            legendKey("據", .teal)
            Badge("只讀")
            Badge("OS 約束")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .tatwoAdaptiveCapsule()
        .background(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.tintOpacity), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(LiquidGlassTokens.strokeOpacity), lineWidth: 1))
        .frame(width: 700, alignment: .leading)
    }

    private func legendKey(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color.opacity(0.92))
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 9.8, weight: .black, design: .rounded))
                .foregroundStyle(color.opacity(0.90))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2.5)
        .background(color.opacity(0.14), in: Capsule())
    }
}

struct WorkOSPlanLoopsGoalNodeView: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let node: WorkOSPlanLoopsGoalNode

    var body: some View {
        VStack(alignment: .leading, spacing: verticalSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(node.kicker)
                    .font(.system(size: kickerSize, weight: .black, design: .rounded))
                    .foregroundStyle(node.color)
                    .lineLimit(1)
                Text(node.title)
                    .font(.system(size: titleSize, weight: .black, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            Text(node.subtitle)
                .font(.system(size: bodySize, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .minimumScaleFactor(0.74)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius, style: LiquidGlassTokens.shapeStyle)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: cornerRadius, style: LiquidGlassTokens.shapeStyle)
                .fill(backgroundColor)
            RoundedRectangle(cornerRadius: cornerRadius, style: LiquidGlassTokens.shapeStyle)
                .fill(node.color.opacity(fillOpacity))
        }
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: LiquidGlassTokens.shapeStyle).strokeBorder(node.color.opacity(strokeOpacity), lineWidth: strokeWidth))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(node.color.opacity(0.86))
                .frame(width: markerWidth)
                .padding(.leading, markerInset)
                .padding(.vertical, markerVerticalInset)
        }
        .shadow(color: node.color.opacity(shadowOpacity), radius: 9, x: 0, y: 5)
    }

    private var titleSize: CGFloat {
        switch node.kind {
        case .mainline: 17.6
        case .responsibility: 13.3
        case .branch: 14.8
        case .pass, .fail: 14.2
        case .receipt: 12.2
        }
    }

    private var bodySize: CGFloat {
        switch node.kind {
        case .mainline: 12.6
        case .responsibility: 10.4
        case .branch: 11.2
        case .pass, .fail: 11.0
        case .receipt: 10.0
        }
    }

    private var kickerSize: CGFloat {
        node.kind == .responsibility ? 9.6 : 9.9
    }

    private var lineLimit: Int {
        node.kind == .responsibility ? 3 : 2
    }

    private var verticalSpacing: CGFloat {
        node.kind == .responsibility ? 4 : 5
    }

    private var horizontalPadding: CGFloat { node.kind == .responsibility ? 12 : 14 }
    private var verticalPadding: CGFloat { node.kind == .responsibility ? 9 : 11 }
    private var markerWidth: CGFloat { node.kind == .mainline ? 5 : 4 }
    private var markerInset: CGFloat { node.kind == .mainline ? 7 : 6 }
    private var markerVerticalInset: CGFloat { node.kind == .responsibility ? 10 : 11 }

    private var cornerRadius: CGFloat {
        switch node.kind {
        case .mainline: 12
        case .responsibility: 10
        case .branch: 8
        case .pass, .fail: 7
        case .receipt: 10
        }
    }

    private var backgroundColor: Color {
        switch node.kind {
        case .fail: return Color.red.opacity(0.070)
        case .pass: return Color.green.opacity(0.070)
        case .responsibility: return LiquidGlassTokens.tint.opacity(LiquidGlassTokens.tintOpacity)
        default: return LiquidGlassTokens.tint.opacity(LiquidGlassTokens.nodeCardTintOpacity)
        }
    }

    private var fillOpacity: Double {
        switch node.kind {
        case .mainline: 0.070
        case .responsibility: 0.045
        case .branch: 0.075
        case .pass, .fail: 0.085
        case .receipt: 0.052
        }
    }

    private var strokeOpacity: Double {
        switch node.kind {
        case .mainline: 0.68
        case .responsibility: 0.46
        case .branch: 0.58
        case .pass, .fail: 0.70
        case .receipt: 0.44
        }
    }

    private var strokeWidth: CGFloat {
        switch node.kind {
        case .mainline: 1.45
        case .fail: 1.45
        case .pass: 1.35
        default: 1.10
        }
    }

    private var shadowOpacity: Double {
        node.kind == .mainline ? 0.070 : 0.040
    }
}

struct WorkOSPlanLoopsGoalReceiptRail: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let tags: [String]

    var body: some View {
        HStack(spacing: 7) {
            Label("收據", systemImage: "checklist.checked")
                .font(.system(size: 11.2, weight: .black, design: .rounded))
                .foregroundStyle(.secondary)
            ForEach(tags.prefix(8), id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 10.4, weight: .black, design: .rounded))
                    .foregroundStyle(.teal)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.teal.opacity(0.075), in: Capsule())
            }
            Spacer(minLength: 0)
            Text("通過後仍需 cleanup inventory")
                .font(.system(size: 10.0, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .tatwoAdaptiveMaterial(cornerRadius: LiquidGlassTokens.radiusCard)
        .background(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.tintOpacity), in: RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusCard, style: LiquidGlassTokens.shapeStyle))
        .overlay(
            RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusCard, style: LiquidGlassTokens.shapeStyle)
                .strokeBorder(Color.teal.opacity(0.22), lineWidth: 1)
        )
        .shadow(
            color: .black.opacity(LiquidGlassTokens.shadowOpacity),
            radius: LiquidGlassTokens.shadowRadius,
            x: LiquidGlassTokens.shadowOffsetX,
            y: LiquidGlassTokens.shadowOffsetY
        )
    }
}

struct WorkOSPlanLoopsGoalConnectorCanvas: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let connectors: [WorkOSPlanLoopsGoalConnector]
    let progress: Double

    var body: some View {
        Canvas { context, _ in
            for (index, connector) in connectors.enumerated() {
                drawRoute(context: &context, connector: connector)
                drawPulseTrain(context: &context, connector: connector, phase: Double(index) * 0.087)
                drawArrowhead(context: &context, connector: connector)
            }
        }
        .accessibilityHidden(true)
    }

    private enum SegmentAxis {
        case horizontal
        case vertical
    }

    private func drawRoute(context: inout GraphicsContext, connector: WorkOSPlanLoopsGoalConnector) {
        let points = connector.points.filterAdjacentDuplicates()
        guard points.count >= 2 else { return }
        var path = Path()
        path.move(to: points[0])
        for point in points.dropFirst() { path.addLine(to: point) }
        let style = StrokeStyle(
            lineWidth: max(1.4, connector.width * 0.82),
            lineCap: .round,
            lineJoin: .round,
            dash: connector.style == .fail ? [7, 7] : []
        )
        let opacity: Double = connector.style == .fail ? 0.22 : LiquidGlassTokens.routeLineOpacity
        context.stroke(path, with: .color(connector.baseColor.opacity(opacity)), style: style)
    }

    private func drawPulseTrain(context: inout GraphicsContext, connector: WorkOSPlanLoopsGoalConnector, phase: Double) {
        let points = connector.points.filterAdjacentDuplicates()
        for pulse in pulseTrain(progress: progress, phase: phase) {
            guard let located = pointAlong(points, t: pulse.t) else { continue }
            drawPulse(
                context: &context,
                located: located,
                color: connector.flowColor,
                scale: pulse.scale * markerScale(for: connector.style),
                opacity: pulse.opacity * markerOpacity(for: connector.style)
            )
        }
    }

    private func drawPulse(
        context: inout GraphicsContext,
        located: (point: CGPoint, axis: SegmentAxis),
        color: Color,
        scale: CGFloat,
        opacity: Double
    ) {
        let center = located.point
        let markerSize: CGSize
        let glowSize: CGSize
        switch located.axis {
        case .horizontal:
            markerSize = CGSize(width: 10.4 * scale, height: 2.5 * scale)
            glowSize = CGSize(width: 14.4 * scale, height: 6.0 * scale)
        case .vertical:
            markerSize = CGSize(width: 2.5 * scale, height: 10.4 * scale)
            glowSize = CGSize(width: 6.0 * scale, height: 14.4 * scale)
        }
        let markerRect = CGRect(
            x: center.x - markerSize.width / 2,
            y: center.y - markerSize.height / 2,
            width: markerSize.width,
            height: markerSize.height
        )
        let glowRect = CGRect(
            x: center.x - glowSize.width / 2,
            y: center.y - glowSize.height / 2,
            width: glowSize.width,
            height: glowSize.height
        )
        context.fill(
            Path(roundedRect: glowRect, cornerRadius: 2.2 * scale),
            with: .color(color.opacity(0.12 * opacity))
        )
        context.fill(
            Path(roundedRect: markerRect, cornerRadius: 1.2 * scale),
            with: .color(color.opacity(LiquidGlassTokens.routePulseOpacity * opacity))
        )
    }

    private func drawArrowhead(context: inout GraphicsContext, connector: WorkOSPlanLoopsGoalConnector) {
        let points = connector.points.filterAdjacentDuplicates()
        guard let last = points.last, let previous = points.dropLast().last else { return }
        let dx = last.x - previous.x
        let dy = last.y - previous.y
        guard abs(dx) > 0.5 || abs(dy) > 0.5 else { return }
        let size: CGFloat = connector.style == .main ? 8.0 : 7.0
        var path = Path()
        if abs(dx) >= abs(dy) {
            let dir: CGFloat = dx >= 0 ? 1 : -1
            path.move(to: CGPoint(x: last.x, y: last.y))
            path.addLine(to: CGPoint(x: last.x - dir * size, y: last.y - size * 0.55))
            path.addLine(to: CGPoint(x: last.x - dir * size, y: last.y + size * 0.55))
        } else {
            let dir: CGFloat = dy >= 0 ? 1 : -1
            path.move(to: CGPoint(x: last.x, y: last.y))
            path.addLine(to: CGPoint(x: last.x - size * 0.55, y: last.y - dir * size))
            path.addLine(to: CGPoint(x: last.x + size * 0.55, y: last.y - dir * size))
        }
        path.closeSubpath()
        context.fill(path, with: .color(connector.flowColor.opacity(connector.style == .fail ? 0.72 : 0.86)))
    }

    private func pulseTrain(progress: Double, phase: Double) -> [(t: CGFloat, scale: CGFloat, opacity: Double)] {
        [0.0, 0.38, 0.72].enumerated().map { index, offset in
            let raw = (progress + phase + offset).truncatingRemainder(dividingBy: 1)
            let t = raw < 0 ? raw + 1 : raw
            return (
                t: CGFloat(t),
                scale: index == 0 ? 1.0 : 0.68,
                opacity: index == 0 ? 0.92 : 0.44
            )
        }
    }

    private func markerScale(for style: WorkOSPlanLoopsGoalConnector.Style) -> CGFloat {
        switch style {
        case .main: 1.05
        case .branch: 0.92
        case .pass, .fail: 0.86
        case .receipt: 0.70
        }
    }

    private func markerOpacity(for style: WorkOSPlanLoopsGoalConnector.Style) -> Double {
        switch style {
        case .main: 0.92
        case .branch: 0.78
        case .pass: 0.82
        case .fail: 0.58
        case .receipt: 0.48
        }
    }

    private func pointAlong(_ points: [CGPoint], t: CGFloat) -> (point: CGPoint, axis: SegmentAxis)? {
        guard points.count >= 2 else { return points.first.map { ($0, .horizontal) } }
        let segments = zip(points.dropLast(), points.dropFirst()).compactMap { start, end -> (start: CGPoint, end: CGPoint, length: CGFloat, axis: SegmentAxis)? in
            let length = hypot(end.x - start.x, end.y - start.y)
            guard length > 0.5 else { return nil }
            let axis: SegmentAxis = abs(end.x - start.x) >= abs(end.y - start.y) ? .horizontal : .vertical
            return (start, end, length, axis)
        }
        let total = segments.reduce(CGFloat(0)) { $0 + $1.length }
        guard total > 0 else { return points.first.map { ($0, .horizontal) } }
        var target = min(max(t, 0), 1) * total
        for segment in segments {
            if target <= segment.length {
                let local = segment.length == 0 ? 0 : target / segment.length
                let point = CGPoint(x: segment.start.x + (segment.end.x - segment.start.x) * local, y: segment.start.y + (segment.end.y - segment.start.y) * local)
                return (point, segment.axis)
            }
            target -= segment.length
        }
        guard let last = segments.last else { return nil }
        return (last.end, last.axis)
    }
}
