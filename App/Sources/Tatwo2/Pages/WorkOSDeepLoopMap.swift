// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/WorkOSDeepLoopMap.swift；改動 2 行（原因：加來源註記並移除舊 core import）
import SwiftUI

struct WorkOSDeepLoopMap: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    enum Surface {
        case mode
        case scenario
        case workflow
    }

    let contract: TatwoWorkOSContractV1
    var surface: Surface = .mode

    private var plan: DeepLoopPlan { DeepLoopPlanFactory.make(contract: contract, surface: surface) }
    private var preferredHeight: CGFloat {
        ShowLoopsProjectionLayoutFactory.preferredHeight(for: contract.showLoopsProjection)
    }

    var body: some View {
        TimelineView(.periodic(from: Date(), by: TatwoMotionClock.secondsPerFrame)) { timeline in
            let progress = TatwoMotionClock.progress(for: timeline.date)
            VStack(alignment: .leading, spacing: 9) {
                DeepLoopHeader(plan: plan, contract: contract)
                ShowLoopsOrthogonalProjection(
                    projection: contract.showLoopsProjection,
                    progress: progress
                )
                .frame(height: preferredHeight)
                DeepLoopLegendRow(plan: plan)
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusCard, style: LiquidGlassTokens.shapeStyle)
                    .fill(LiquidGlassTokens.canvasBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusCard, style: LiquidGlassTokens.shapeStyle)
                            .fill(.ultraThinMaterial)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusCard, style: LiquidGlassTokens.shapeStyle)
                            .fill(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.tintOpacity))
                    }
            }
            .overlay(
                RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusCard, style: LiquidGlassTokens.shapeStyle)
                    .strokeBorder(Color.white.opacity(LiquidGlassTokens.strokeOpacity), lineWidth: 1)
            )
        }
    }
}

private struct ShowLoopsOrthogonalProjection: View {
    let projection: WorkOSShowLoopsProjection
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            let layout = ShowLoopsProjectionLayoutFactory.make(
                projection: projection,
                size: proxy.size
            )

            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for route in layout.routes {
                        ShowLoopsArrowEngine.draw(route: route, progress: progress, in: &context)
                    }
                }
                .accessibilityHidden(true)

                ForEach(layout.nodes) { node in
                    ShowLoopsProjectionNodeCard(node: node.node, color: node.color, compact: node.compact)
                        .frame(width: node.rect.width, height: node.rect.height)
                        .position(x: node.rect.midX, y: node.rect.midY)
                }
            }
        }
    }
}

private struct ShowLoopsProjectionNodeCard: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let node: WorkOSShowLoopNode
    let color: Color
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            HStack(spacing: 5) {
                Text(node.title)
                    .font(.system(size: compact ? 10.8 : 12.2, weight: .black, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                Spacer(minLength: 0)
                Circle()
                    .fill(statusColor)
                    .frame(width: compact ? 6 : 7, height: compact ? 6 : 7)
            }
            if let owner = node.ownerIdentity {
                FlowChip(text: owner.chineseName, color: color)
            }
            Text(node.plainPurpose)
                .font(.system(size: compact ? 8.6 : 9.6, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(compact ? 1 : 2)
                .minimumScaleFactor(0.74)
        }
        .padding(.horizontal, compact ? 7 : 9)
        .padding(.vertical, compact ? 6 : 8)
        .background(Color.white.opacity(LiquidGlassTokens.nodeCardTintOpacity), in: RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: LiquidGlassTokens.shapeStyle))
        .overlay(
            RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: LiquidGlassTokens.shapeStyle)
                .strokeBorder(color.opacity(0.48), lineWidth: 1.1)
        )
    }

    private var statusColor: Color {
        switch node.status {
        case .planned: return .blue
        case .dispatching: return .cyan
        case .running: return .green
        case .succeeded: return .orange
        case .failed: return .red
        case .cancelled: return .orange
        case .humanGate: return .orange
        case .awaitingNextCycle: return .cyan
        case .blocked: return .red
        case .passed: return .teal
        case .rollbackRequired: return .red
        case .superseded: return .gray
        }
    }
}

private struct ShowLoopsRenderNode: Identifiable {
    let id: String
    let node: WorkOSShowLoopNode
    let rect: CGRect
    let color: Color
    let compact: Bool
}

private struct ShowLoopsRoute: Identifiable {
    let id: String
    let label: String
    let points: [CGPoint]
    let color: Color
}

private struct ShowLoopsProjectionLayout {
    let nodes: [ShowLoopsRenderNode]
    let routes: [ShowLoopsRoute]
}

private enum ShowLoopsProjectionLayoutFactory {
    static func preferredHeight(for projection: WorkOSShowLoopsProjection) -> CGFloat {
        let domainCount = visibleDomainNodes(from: projection.nodes).count
        let rows = max(1, Int(ceil(Double(domainCount) / 4.0)))
        return CGFloat(260 + rows * 72)
    }

    static func make(projection: WorkOSShowLoopsProjection, size: CGSize) -> ShowLoopsProjectionLayout {
        let width = max(size.width, 720)
        let margin: CGFloat = 18
        let gap: CGFloat = 18
        let mainNodeWidth = max(92, min(136, (width - margin * 2 - gap * 5) / 6))
        let mainNodeHeight: CGFloat = 70
        let domainNodeWidth: CGFloat = 126
        let domainNodeHeight: CGFloat = 58
        let mainY: CGFloat = 58
        let domainTop: CGFloat = 142
        let visibleDomains = visibleDomainNodes(from: projection.nodes)
        let domainColumns = max(1, min(4, Int((width - margin * 2) / (domainNodeWidth + 12))))
        let domainRows = max(1, Int(ceil(Double(max(visibleDomains.count, 1)) / Double(domainColumns))))
        let bottomY = domainTop + CGFloat(domainRows) * (domainNodeHeight + 14) + 62

        var nodes: [ShowLoopsRenderNode] = []
        var frames: [String: CGRect] = [:]
        let nodeByID = Dictionary(uniqueKeysWithValues: displayNodes(from: projection.nodes).map { ($0.id, $0) })

        let mainIDs = ["task-intake", "contract", "plan-lead", "loops-cycle", "supervisor-gate", "goal-lead-gate"]
        for (index, id) in mainIDs.enumerated() {
            guard let node = nodeByID[id] else { continue }
            let x = margin + mainNodeWidth / 2 + CGFloat(index) * (mainNodeWidth + gap)
            let rect = CGRect(x: x - mainNodeWidth / 2, y: mainY - mainNodeHeight / 2, width: mainNodeWidth, height: mainNodeHeight)
            frames[id] = rect
            nodes.append(renderNode(node, rect: rect, compact: false))
        }

        for (index, node) in visibleDomains.enumerated() {
            let row = index / domainColumns
            let column = index % domainColumns
            let usedWidth = CGFloat(domainColumns) * domainNodeWidth + CGFloat(domainColumns - 1) * 12
            let startX = max(margin, (width - usedWidth) / 2)
            let x = startX + domainNodeWidth / 2 + CGFloat(column) * (domainNodeWidth + 12)
            let y = domainTop + domainNodeHeight / 2 + CGFloat(row) * (domainNodeHeight + 14)
            let rect = CGRect(x: x - domainNodeWidth / 2, y: y - domainNodeHeight / 2, width: domainNodeWidth, height: domainNodeHeight)
            frames[node.id] = rect
            nodes.append(renderNode(node, rect: rect, compact: true))
        }

        let bottomIDs = ["receipts", "cleanup-inventory", "sandbox-gate", "finish-human"]
        let bottomNodeWidth = max(98, min(146, (width - margin * 2 - gap * 3) / 4))
        for (index, id) in bottomIDs.enumerated() {
            guard let node = nodeByID[id] else { continue }
            let x = margin + bottomNodeWidth / 2 + CGFloat(index) * (bottomNodeWidth + gap)
            let rect = CGRect(x: x - bottomNodeWidth / 2, y: bottomY - mainNodeHeight / 2, width: bottomNodeWidth, height: mainNodeHeight)
            frames[id] = rect
            nodes.append(renderNode(node, rect: rect, compact: false))
        }

        let routes = visibleEdges(from: projection, visibleNodeIDs: Set(frames.keys)).compactMap { edge -> ShowLoopsRoute? in
            guard let source = frames[edge.from], let target = frames[edge.to] else { return nil }
            let sourceNode = nodeByID[edge.from]
            return ShowLoopsRoute(
                id: edge.id,
                label: edge.label,
                points: routePoints(from: source, to: target, edge: edge, canvasWidth: width),
                color: identityColor(sourceNode?.ownerIdentity ?? nodeByID[edge.to]?.ownerIdentity)
            )
        }

        return ShowLoopsProjectionLayout(nodes: nodes, routes: routes)
    }

    private static func displayNodes(from nodes: [WorkOSShowLoopNode]) -> [WorkOSShowLoopNode] {
        let domains = nodes.filter { $0.kind == .domain }
        if domains.count <= 8 { return nodes }
        let visibleDomainIDs = Set(domains.prefix(8).map(\.id))
        let aggregate = WorkOSShowLoopNode(
            id: "domain-extra",
            kind: .domain,
            title: "支線 +\(domains.count - 8)",
            ownerIdentity: .sub,
            status: .planned,
            receiptIDs: [],
            canPromoteRunState: false,
            plainPurpose: "其餘支線收合顯示；仍由 Core contract / staging config 保留完整清單。")
        return nodes.filter { $0.kind != .domain || visibleDomainIDs.contains($0.id) } + [aggregate]
    }

    private static func visibleDomainNodes(from nodes: [WorkOSShowLoopNode]) -> [WorkOSShowLoopNode] {
        displayNodes(from: nodes).filter { $0.kind == .domain }
    }

    private static func visibleEdges(from projection: WorkOSShowLoopsProjection, visibleNodeIDs: Set<String>) -> [WorkOSShowLoopEdge] {
        var edges = projection.edges.filter { visibleNodeIDs.contains($0.from) && visibleNodeIDs.contains($0.to) }
        let hiddenDomainCount = projection.nodes.filter { $0.kind == .domain && !visibleNodeIDs.contains($0.id) }.count
        if hiddenDomainCount > 0, visibleNodeIDs.contains("domain-extra") {
            edges.append(WorkOSShowLoopEdge(id: "edge-loops-domain-extra", from: "loops-cycle", to: "domain-extra", label: "其餘支線"))
            edges.append(WorkOSShowLoopEdge(id: "edge-domain-extra-supervisor", from: "domain-extra", to: "supervisor-gate", label: "提交副審"))
        }
        return edges
    }

    private static func renderNode(_ node: WorkOSShowLoopNode, rect: CGRect, compact: Bool) -> ShowLoopsRenderNode {
        ShowLoopsRenderNode(id: node.id, node: node, rect: rect, color: identityColor(node.ownerIdentity), compact: compact)
    }

    private static func routePoints(
        from source: CGRect,
        to target: CGRect,
        edge: WorkOSShowLoopEdge,
        canvasWidth: CGFloat
    ) -> [CGPoint] {
        if edge.to == "receipts" {
            let start = CGPoint(x: source.maxX, y: source.midY)
            let end = CGPoint(x: target.midX, y: target.minY)
            let xGutter = min(canvasWidth - 8, source.maxX + 14)
            let yGutter = max(source.maxY + 24, target.minY - 18)
            return orthogonal([
                start,
                CGPoint(x: xGutter, y: start.y),
                CGPoint(x: xGutter, y: yGutter),
                CGPoint(x: end.x, y: yGutter),
                end,
            ])
        }

        if edge.label.contains("不過") || (edge.to == "loops-cycle" && source.minY < target.maxY) {
            let start = CGPoint(x: source.midX, y: source.minY)
            let end = CGPoint(x: target.midX, y: target.minY)
            let y = max(10, min(source.minY, target.minY) - 28)
            return orthogonal([start, CGPoint(x: start.x, y: y), CGPoint(x: end.x, y: y), end])
        }

        if abs(source.midY - target.midY) < 8 {
            if source.midX <= target.midX {
                return orthogonal([CGPoint(x: source.maxX, y: source.midY), CGPoint(x: target.minX, y: target.midY)])
            }
            return orthogonal([CGPoint(x: source.minX, y: source.midY), CGPoint(x: target.maxX, y: target.midY)])
        }

        if source.midY < target.midY {
            let start = CGPoint(x: source.midX, y: source.maxY)
            let end = CGPoint(x: target.midX, y: target.minY)
            let y = (source.maxY + target.minY) / 2
            return orthogonal([start, CGPoint(x: start.x, y: y), CGPoint(x: end.x, y: y), end])
        }

        let start = CGPoint(x: source.midX, y: source.minY)
        let end = CGPoint(x: target.midX, y: target.maxY)
        let y = (source.minY + target.maxY) / 2
        return orthogonal([start, CGPoint(x: start.x, y: y), CGPoint(x: end.x, y: y), end])
    }

    private static func orthogonal(_ points: [CGPoint]) -> [CGPoint] {
        points.reduce(into: [CGPoint]()) { result, point in
            guard result.last != point else { return }
            result.append(point)
        }
    }

    private static func identityColor(_ identity: IdentityKind?) -> Color {
        switch identity {
        case .lead: return .cyan
        case .supervisor: return .purple
        case .consultant: return .indigo
        case .sub: return .blue
        case .news: return .green
        case .verifier: return .teal
        case nil: return .orange
        }
    }
}

private enum ShowLoopsArrowEngine {
    static func draw(route: ShowLoopsRoute, progress: Double, in context: inout GraphicsContext) {
        guard route.points.count >= 2 else { return }
        var path = Path()
        path.move(to: route.points[0])
        for point in route.points.dropFirst() {
            path.addLine(to: point)
        }
        context.stroke(
            path,
            with: .color(route.color.opacity(LiquidGlassTokens.routeLineOpacity)),
            style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
        )

        drawPulse(route: route, progress: progress, in: &context)
        drawArrowHead(route: route, in: &context)
    }

    private static func drawPulse(route: ShowLoopsRoute, progress: Double, in context: inout GraphicsContext) {
        for offset in [0.0, 0.38, 0.72] {
            let raw = (progress + offset).truncatingRemainder(dividingBy: 1)
            let t = raw < 0 ? raw + 1 : raw
            let eased = 0.5 - cos(t * .pi) / 2.0
            guard let sample = sample(route.points, at: CGFloat(eased)) else { continue }
            let scale: CGFloat = offset == 0 ? 1.0 : 0.74
            let alpha: Double = (offset == 0 ? LiquidGlassTokens.routePulseOpacity : 0.34) * (0.72 + 0.28 * sin(t * .pi))
            let markerSize: CGSize
            let glowSize: CGSize
            switch sample.direction {
            case .left, .right:
                markerSize = CGSize(width: 10.4 * scale, height: 2.5 * scale)
                glowSize = CGSize(width: 14.4 * scale, height: 6.0 * scale)
            case .up, .down:
                markerSize = CGSize(width: 2.5 * scale, height: 10.4 * scale)
                glowSize = CGSize(width: 6.0 * scale, height: 14.4 * scale)
            }
            let markerRect = CGRect(
                x: sample.point.x - markerSize.width / 2,
                y: sample.point.y - markerSize.height / 2,
                width: markerSize.width,
                height: markerSize.height
            )
            let glowRect = CGRect(
                x: sample.point.x - glowSize.width / 2,
                y: sample.point.y - glowSize.height / 2,
                width: glowSize.width,
                height: glowSize.height
            )
            context.fill(
                Path(roundedRect: glowRect, cornerRadius: 2.2 * scale),
                with: .color(route.color.opacity(0.11 * alpha))
            )
            context.fill(
                Path(roundedRect: markerRect, cornerRadius: 1.2 * scale),
                with: .color(route.color.opacity(alpha))
            )
        }
    }

    private static func drawArrowHead(route: ShowLoopsRoute, in context: inout GraphicsContext) {
        guard let endDirection = lastSegmentDirection(route.points),
              let tip = route.points.last else { return }
        let size: CGFloat = 7.2
        let wing: CGFloat = 4.8
        let points: [CGPoint]
        switch endDirection {
        case .right:
            points = [tip, CGPoint(x: tip.x - size, y: tip.y - wing), CGPoint(x: tip.x - size, y: tip.y + wing)]
        case .left:
            points = [tip, CGPoint(x: tip.x + size, y: tip.y - wing), CGPoint(x: tip.x + size, y: tip.y + wing)]
        case .down:
            points = [tip, CGPoint(x: tip.x - wing, y: tip.y - size), CGPoint(x: tip.x + wing, y: tip.y - size)]
        case .up:
            points = [tip, CGPoint(x: tip.x - wing, y: tip.y + size), CGPoint(x: tip.x + wing, y: tip.y + size)]
        }
        var arrow = Path()
        arrow.move(to: points[0])
        arrow.addLine(to: points[1])
        arrow.addLine(to: points[2])
        arrow.closeSubpath()
        context.fill(arrow, with: .color(route.color.opacity(0.84)))
    }

    private enum Direction {
        case right
        case left
        case down
        case up
    }

    private static func lastSegmentDirection(_ points: [CGPoint]) -> Direction? {
        guard points.count >= 2 else { return nil }
        for index in stride(from: points.count - 1, through: 1, by: -1) {
            let start = points[index - 1]
            let end = points[index]
            let dx = end.x - start.x
            let dy = end.y - start.y
            if abs(dx) > abs(dy), abs(dx) > 0.5 { return dx > 0 ? .right : .left }
            if abs(dy) > 0.5 { return dy > 0 ? .down : .up }
        }
        return nil
    }

    private static func sample(_ points: [CGPoint], at t: CGFloat) -> (point: CGPoint, direction: Direction)? {
        guard points.count >= 2 else { return nil }
        typealias Segment = (start: CGPoint, end: CGPoint, length: CGFloat)
        var segments: [Segment] = []
        segments.reserveCapacity(points.count - 1)
        for index in 1..<points.count {
            let start = points[index - 1]
            let end = points[index]
            let length: CGFloat = abs(end.x - start.x) + abs(end.y - start.y)
            if length > 0.5 {
                segments.append((start: start, end: end, length: length))
            }
        }
        let total = segments.reduce(CGFloat(0)) { $0 + $1.length }
        guard total > 0 else { return nil }
        var remaining = max(0, min(t, 1)) * total
        for segment in segments {
            if remaining <= segment.length {
                let local = remaining / segment.length
                let point = CGPoint(
                    x: segment.start.x + (segment.end.x - segment.start.x) * local,
                    y: segment.start.y + (segment.end.y - segment.start.y) * local
                )
                return (point, lastSegmentDirection([segment.start, segment.end]) ?? .right)
            }
            remaining -= segment.length
        }
        guard let last = segments.last else { return nil }
        return (last.end, lastSegmentDirection([last.start, last.end]) ?? .right)
    }
}

struct DeepLoopPlan: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let badges: [String]
    let lanes: [DeepLoopLane]
    let legend: [DeepLegendItem]
}

struct DeepLoopLane: Identifiable, Equatable {
    let id: String
    let index: Int
    let title: String
    let subtitle: String
    let accent: Color
    let layout: DeepLoopLaneLayout
    let nodes: [DeepLoopNode]
    let domainCards: [DeepDomainCard]
}

enum DeepLoopLaneLayout: Equatable {
    case chain
    case grid
    case domains
}

struct DeepLoopNode: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let badge: String
    let accent: Color
    let chips: [String]
}

struct DeepDomainCard: Identifiable, Equatable {
    let id: String
    let title: String
    let owner: String
    let accent: Color
    let steps: [String]
    let tools: [String]
    let sandbox: String
    let receipts: String
    let merge: String
}

struct DeepLegendItem: Identifiable, Equatable {
    let id: String
    let title: String
    let color: Color
}

enum DeepLoopPlanFactory {
    static func make(contract: TatwoWorkOSContractV1, surface: WorkOSDeepLoopMap.Surface) -> DeepLoopPlan {
        let kind = scenarioKind(contract.scenario)
        let title = titleFor(contract: contract, surface: surface)
        let badges = [contract.mode.rawValue, scenarioTitle(kind), "專屬流程", contract.showLoopsProjection.readOnly ? "只讀" : "可寫"]
        return DeepLoopPlan(
            id: "deep-\(contract.mode.rawValue)-\(kind)",
            title: title,
            subtitle: subtitleFor(contract),
            badges: badges,
            lanes: lanes(for: contract, kind: kind),
            legend: [
                .init(id: "dispatch", title: "分派", color: .blue),
                .init(id: "收據", title: "收據回流", color: .teal),
                .init(id: "gate", title: "關卡", color: .orange),
                .init(id: "rollback", title: "回滾", color: .red)
            ]
        )
    }

    private static func lanes(for contract: TatwoWorkOSContractV1, kind: String) -> [DeepLoopLane] {
        switch contract.mode {
        case .s:
            return [entryLane(contract, index: 1), sMainlineLane(contract, index: 2), runtimeLane(contract, kind: kind, index: 3), gateLane(contract, kind: kind, index: 4)]
        case .m:
            return [entryLane(contract, index: 1), identityLane(contract, kind: kind, index: 2), mScenarioLane(contract, kind: kind, index: 3), runtimeLane(contract, kind: kind, index: 4), gateLane(contract, kind: kind, index: 5)]
        case .l:
            return [entryLane(contract, index: 1), identityLane(contract, kind: kind, index: 2), lFocusedDomainLane(contract, kind: kind, index: 3), runtimeLane(contract, kind: kind, index: 4), gateLane(contract, kind: kind, index: 5)]
        case .xl, .xxl:
            return [entryLane(contract, index: 1), identityLane(contract, kind: kind, index: 2), xlDomainLane(contract, kind: kind, index: 3), runtimeLane(contract, kind: kind, index: 4), gateLane(contract, kind: kind, index: 5)]
        }
    }

    private static func entryLane(_ contract: TatwoWorkOSContractV1, index: Int) -> DeepLoopLane {
        let nodes: [DeepLoopNode] = [
            node("goal", "目標", "範圍 / 禁區", "使用者", .mint, ["目標ID"]),
            node("begin", "os.begin", "建立合約", "MCP", .green, ["合約ID"]),
            node("contract", "OS 合約", "模式 / 情境", "無合約即停", .blue, [contract.mode.rawValue]),
            node("state", "目標狀態", "下一步 / 關卡", "狀態", .orange, [statusText(contract.goalRun.status)])
        ]
        return lane("entry", index, "目標 + 合約", "無合約不行動", .green, .chain, nodes, [])
    }

    private static func identityLane(_ contract: TatwoWorkOSContractV1, kind: String, index: Int) -> DeepLoopLane {
        let roleChips = Array(contract.identityBindings.prefix(4).map { $0.identity.chineseName })
        let nodes: [DeepLoopNode] = [
            node("identity", "身份組", "主 / 監 / sub", "身份槽", .purple, roleChips.isEmpty ? ["可替換"] : roleChips),
            node("scenario", "情境模板", scenarioTitle(kind), "代理", .blue, ["可自訂"]),
            node("mainline", "主線監督", "控方向 / 合併", "主線", .cyan, [contract.mainlineLoop.ownerIdentity.chineseName]),
            node("next", "os.next", "下一步", "不猜", .orange, ["只按 OS"])
        ]
        return lane("identity", index, "身份 + 主線", "模型聽身份槽，不反過來主導", .purple, .chain, nodes, [])
    }

    private static func sMainlineLane(_ contract: TatwoWorkOSContractV1, index: Int) -> DeepLoopLane {
        let nodes: [DeepLoopNode] = [
            node("inspect", "查證", "檔案 / log", "本機", .blue, ["0 sub"]),
            node("patch", "微調", "最小改動", "差異", .indigo, ["不擴張"]),
            node("smoke", "煙測", "本機證據", "收據", .teal, ["可重跑"]),
            node("retry", "回查", "未過不交付", "循環", .red, ["回滾"])
        ]
        return lane("s-main", index, "S 小修專屬流程", "單主線，不開多領域分流", .blue, .chain, nodes, [])
    }

    private static func mScenarioLane(_ contract: TatwoWorkOSContractV1, kind: String, index: Int) -> DeepLoopLane {
        switch kind {
        case "ui":
            return lane("m-ui", index, "M / UI 專屬流程", "視覺、代碼、截圖、交互分開驗", .blue, .grid, [
                node("need", "需求收斂", "畫面目標", "主線", .mint, ["用戶口徑"]),
                node("visual", "視覺 loop", "比例 / 留白", "UI", .blue, ["美感"]),
                node("code", "代碼歸納", "元件 / 狀態", "代碼", .indigo, ["一致"]),
                node("shot", "截圖驗收", "真畫面", "收據", .teal, ["不可自評"]),
                node("interact", "交互驗收", "點擊 / 捲動", "UJ", .orange, ["可理解"]),
                node("副審", "副審", "找醜點", "關卡", .purple, ["反例"])
            ], [])
        case "trading":
            return lane("m-trading", index, "M / 交易專屬流程", "只讀研究，不碰下單與 live 風控", .red, .grid, [
                node("readonly", "只讀目標", "禁止交易", "風險", .red, ["禁下單"]),
                node("data", "資料", "行情 / 新聞", "來源", .blue, ["標時間"]),
                node("thesis", "觀點", "假設整理", "主張", .indigo, ["非訊號"]),
                node("risk", "風控", "資金 / 槓桿", "阻擋", .orange, ["人工"]),
                node("rebuttal", "反方", "失效條件", "副審", .purple, ["客觀"]),
                node("收據", "收據", "來源 + 風險", "只讀", .teal, ["可追溯"])
            ], [])
        case "research":
            return lane("m-research", index, "M / 研究專屬流程", "來源、主張、反例、證據表", .purple, .grid, [
                node("question", "問題", "先切清楚", "scope", .mint, ["主張"]),
                node("來源", "來源", "時間 / 引用", "消息", .blue, ["新消息"]),
                node("主張", "主張", "不先相信", "證據表", .indigo, ["狀態"]),
                node("rebuttal", "反例", "找相反證據", "反方", .red, ["反方"]),
                node("缺口", "缺口", "標未證明", "缺口", .orange, ["待查"]),
                node("result", "結論", "假設分離", "輸出", .teal, ["可用"])
            ], [])
        case "modeling":
            return lane("m-modeling", index, "M / 建模專屬流程", "候選、限制、小測、比較", .teal, .grid, [
                node("target", "建模目標", "輸入 / 輸出", "規格", .mint, ["標準"]),
                node("candidate", "候選", "多路草案", "草稿", .blue, ["不定案"]),
                node("constraint", "限制", "資料 / 成本", "邊界", .indigo, ["環境"]),
                node("probe", "小測", "最小樣本", "測試", .teal, ["可重跑"]),
                node("compare", "比較", "失敗條件", "比較", .orange, ["客觀"]),
                node("副審", "副審", "假設漏洞", "關卡", .purple, ["反方"])
            ], [])
        case "daily":
            return lane("m-daily", index, "M / 通用專屬流程", "收斂、草稿、檢查、回覆", .green, .grid, [
                node("intent", "意圖", "先懂需求", "主線", .mint, ["短路徑"]),
                node("草稿", "草稿", "低成本協作", "sub", .blue, ["可跳過"]),
                node("check", "檢查", "錯漏 / 反例", "副審", .purple, ["副審"]),
                node("answer", "回覆", "簡潔可行", "輸出", .teal, ["不贅述"])
            ], [])
        default:
            return lane("m-code", index, "M / 代碼專屬流程", "讀碼、修補、測試、副審", .indigo, .grid, [
                node("scope", "範圍", "入口 / 影響", "地圖", .mint, ["邊界"]),
                node("read", "讀碼", "找路徑", "代碼", .blue, ["證據"]),
                node("patch", "修補", "小批差異", "宿主", .indigo, ["不偷改"]),
                node("test", "測試", "build / unit", "收據", .teal, ["可重跑"]),
                node("副審", "審稿", "漏測 / 破壞", "關卡", .purple, ["反方"]),
                node("merge", "收口", "說明未驗項", "收口", .orange, ["回滾"])
            ], [])
        }
    }

    private static func lFocusedDomainLane(_ contract: TatwoWorkOSContractV1, kind: String, index: Int) -> DeepLoopLane {
        let cards = domainCards(contract: contract, kind: kind, cap: max(1, min(2, contract.domainLoops.count)))
        let nodes: [DeepLoopNode] = [
            node("pick", "單領域", primaryDomainTitle(contract, kind: kind), "聚焦", .blue, ["深循環"]),
            node("sandbox", "沙盒", sandboxText(contract), "暫存", .brown, ["必收據"]),
            node("verify", "驗證", "測試 / 副審", "收據", .teal, ["可重跑"]),
            node("rollback", "回滾點", "失敗回退", "安全", .red, ["不硬推"])
        ]
        return lane("l-focus", index, "L 單領域深 loop", "深做一個領域，再回主線合併", .blue, cards.isEmpty ? .chain : .domains, nodes, cards)
    }

    private static func xlDomainLane(_ contract: TatwoWorkOSContractV1, kind: String, index: Int) -> DeepLoopLane {
        let cards = domainCards(contract: contract, kind: kind, cap: 6)
        return lane("xl-domains", index, "XL 多領域 loops", "各領域可自主搭建，但必須回主線", .blue, .domains, [], cards)
    }

    private static func runtimeLane(_ contract: TatwoWorkOSContractV1, kind: String, index: Int) -> DeepLoopLane {
        let toolSet = normalizedTools(contract)
        let nodes: [DeepLoopNode] = [
            node("skills", "技能", skillHint(kind), "技能", .purple, Array(toolSet.prefix(2))),
            node("mcp", "MCP", "GitNexus / Pro", "工具", .blue, ["按需"]),
            node("gateway", "模型閘道", "路由 / 同串", "模型", .cyan, ["fast"]),
            node("腳本", "JS / Swift", scriptHint(kind), "腳本", .pink, ["可重跑"]),
            node("sandbox", "沙盒", sandboxText(contract), "安全", .brown, [contract.sandboxPolicy.required ? "必須" : "視風險"]),
            node("宿主", "主機保護", "不碰私密", "保護", .gray, ["無 token"])
        ]
        return lane("runtime", index, "執行層 + 沙盒", "工具與腳本按合約開放", .teal, .grid, nodes, [])
    }

    private static func gateLane(_ contract: TatwoWorkOSContractV1, kind: String, index: Int) -> DeepLoopLane {
        let receiptChips = Array(contract.receiptRequirements.prefix(3).map { shortReceipt($0) })
        let nodes: [DeepLoopNode] = [
            node("證據表", "收據池", "統一回收", "收據", .teal, receiptChips.isEmpty ? ["必填"] : receiptChips),
            node("副審", "副審", "反方 / 漏測", "副審", .purple, ["非自評"]),
            node("visual", visualGateTitle(kind), visualGateBody(kind), "證據", .orange, ["真證據"]),
            node("human", "人工關卡", humanGateBody(contract), "關卡", .orange, [contract.sandboxPolicy.humanGateRequired ? "你放行" : "依風險"]),
            node("rollback", "回滾", "不過就回退", "安全", .red, ["重派"])
        ]
        return lane("gate", index, "收據 + 關卡", "沒有收據不能通過", .orange, .grid, nodes, [])
    }

    private static func domainCards(contract: TatwoWorkOSContractV1, kind: String, cap: Int) -> [DeepDomainCard] {
        let loops = contract.domainLoops.prefix(cap)
        if loops.isEmpty { return [] }
        return loops.map { loop in
            DeepDomainCard(
                id: loop.id,
                title: domainTitle(loop.domain),
                owner: loop.ownerIdentity.chineseName,
                accent: color(for: loop.domain),
                steps: steps(for: loop.domain, kind: kind),
                tools: loop.allowedTools.isEmpty ? ["依主線"] : Array(loop.allowedTools.prefix(2).map(shortTool)),
                sandbox: sandboxTypeText(loop.sandboxType),
                receipts: loop.requiredReceipts.isEmpty ? "依主線" : loop.requiredReceipts.prefix(2).map(shortReceipt).joined(separator: " / "),
                merge: shortMerge(loop.mergeBackRule)
            )
        }
    }

    private static func node(_ id: String, _ title: String, _ subtitle: String, _ badge: String, _ accent: Color, _ chips: [String]) -> DeepLoopNode {
        DeepLoopNode(id: id, title: title, subtitle: subtitle, badge: badge, accent: accent, chips: chips)
    }

    private static func lane(_ id: String, _ index: Int, _ title: String, _ subtitle: String, _ accent: Color, _ layout: DeepLoopLaneLayout, _ nodes: [DeepLoopNode], _ domains: [DeepDomainCard]) -> DeepLoopLane {
        DeepLoopLane(id: id, index: index, title: title, subtitle: subtitle, accent: accent, layout: layout, nodes: nodes, domainCards: domains)
    }

    private static func titleFor(contract: TatwoWorkOSContractV1, surface: WorkOSDeepLoopMap.Surface) -> String {
        switch surface {
        case .mode: return "模式流程圖"
        case .scenario: return "情境流程圖"
        case .workflow: return "目標流程圖"
        }
    }

    private static func subtitleFor(_ contract: TatwoWorkOSContractV1) -> String {
        switch contract.mode {
        case .s: return "主線直修，零分流"
        case .m: return "小協作，副審關卡"
        case .l: return "單領域深做，沙盒收據"
        case .xl, .xxl: return "主線監督，多領域 loops"
        }
    }

    private static func scenarioKind(_ raw: String) -> String {
        switch raw {
        case "ui-ux", "design", "editing": return "ui"
        case "trading-risk", "trading": return "trading"
        case "modeling", "video-research": return "modeling"
        case "research": return "research"
        case "daily": return "daily"
        default: return "coding"
        }
    }

    private static func scenarioTitle(_ kind: String) -> String {
        switch kind {
        case "ui": return "UI"
        case "trading": return "交易"
        case "research": return "研究"
        case "modeling": return "建模"
        case "daily": return "通用"
        default: return "代碼"
        }
    }

    private static func scenarioLabel(_ raw: String) -> String {
        scenarioTitle(scenarioKind(raw))
    }

    private static func statusText(_ status: GoalRunStatus) -> String {
        switch status {
        case .planned: return "已規劃"
        case .dispatching: return "派工中"
        case .running: return "執行中"
        case .succeeded: return "Loops 完成，待驗收"
        case .failed: return "執行失敗"
        case .cancelled: return "已取消"
        case .humanGate: return "待人工"
        case .awaitingNextCycle: return "本輪完成，可開下一輪"
        case .blocked: return "阻塞"
        case .passed: return "通過"
        case .rollbackRequired: return "需回滾"
        case .superseded: return "已由新版取代"
        }
    }

    private static func normalizedTools(_ contract: TatwoWorkOSContractV1) -> [String] {
        var seen = Set<String>()
        let all = contract.mainlineLoop.allowedTools + contract.domainLoops.flatMap(\.allowedTools)
        let mapped = all.map(shortTool)
        return mapped.filter { seen.insert($0).inserted }
    }

    private static func shortTool(_ tool: String) -> String {
        tool
            .replacingOccurrences(of: "scripts/", with: "腳本/")
            .replacingOccurrences(of: "browser", with: "瀏覽器")
            .replacingOccurrences(of: "playwright", with: "Playwright")
            .replacingOccurrences(of: "swift", with: "Swift")
            .replacingOccurrences(of: "node", with: "Node")
            .replacingOccurrences(of: "mcp", with: "MCP")
            .replacingOccurrences(of: "gateway", with: "模型閘道")
    }

    private static func shortReceipt(_ receipt: WorkOSReceiptRequirement) -> String {
        if receipt.title.count <= 8 { return receipt.title }
        switch receipt.kind {
        case "screenshot": return "截圖"
        case "test": return "測試"
        case "副審": return "審稿"
        case "rollback": return "回滾"
        case "sandbox": return "沙盒"
        default: return String(receipt.title.prefix(8))
        }
    }

    private static func sandboxText(_ contract: TatwoWorkOSContractV1) -> String {
        if contract.sandboxPolicy.required && contract.sandboxPolicy.humanGateRequired { return "沙盒 + 人工" }
        if contract.sandboxPolicy.required { return "沙盒 / 暫存" }
        return "預備 / 預演"
    }

    private static func sandboxTypeText(_ type: WorkOSSandboxType) -> String {
        switch type {
        case .none: return "無"
        case .stagingConfig: return "暫存"
        case .tempWorkspace: return "臨時"
        case .colimaDryRun: return "Colima 預演"
        }
    }

    private static func scriptHint(_ kind: String) -> String {
        switch kind {
        case "ui": return "截圖 / 煙測"
        case "trading": return "只讀風控"
        case "research": return "來源抽查"
        case "modeling": return "樣本小測"
        default: return "測試 / 差異"
        }
    }

    private static func skillHint(_ kind: String) -> String {
        switch kind {
        case "ui": return "UI 技能"
        case "trading": return "風控技能"
        case "research": return "研究技能"
        case "modeling": return "建模技能"
        default: return "主線技能"
        }
    }

    private static func visualGateTitle(_ kind: String) -> String {
        switch kind {
        case "ui": return "UI 證據"
        case "trading": return "風險證據"
        case "research": return "來源證據"
        default: return "驗收證據"
        }
    }

    private static func visualGateBody(_ kind: String) -> String {
        switch kind {
        case "ui": return "截圖 / 操作"
        case "trading": return "只讀證明"
        case "research": return "引用 / 反例"
        default: return "測試 / 煙測"
        }
    }

    private static func humanGateBody(_ contract: TatwoWorkOSContractV1) -> String {
        contract.sandboxPolicy.humanGateRequired ? "你放行" : "條件滿足"
    }

    private static func primaryDomainTitle(_ contract: TatwoWorkOSContractV1, kind: String) -> String {
        contract.domainLoops.first?.domain.plainName ?? scenarioTitle(kind)
    }

    private static func shortMerge(_ text: String) -> String {
        if text.count <= 12 { return text }
        if text.contains("主線") { return "回主線合併" }
        if text.contains("副審") { return "副審後合併" }
        return String(text.prefix(12))
    }

    private static func steps(for domain: WorkOSDomainKind, kind: String) -> [String] {
        switch domain {
        case .ui: return ["風格", "截圖", "交互"]
        case .code: return ["讀碼", "修補", "測試"]
        case .debug: return ["重現", "根因", "回歸"]
        case .research: return ["來源", "反方", "證據"]
        case .modeling: return ["候選", "小測", "比較"]
        case .ops: return ["診斷", "備份", "煙測"]
        case .custom: return [scenarioTitle(kind), "自訂", "收據"]
        }
    }

    private static func domainTitle(_ domain: WorkOSDomainKind) -> String {
        switch domain {
        case .ui: return "UI/UX"
        case .code: return "代碼"
        case .debug: return "除錯"
        case .research: return "研究"
        case .modeling: return "建模"
        case .ops: return "運維"
        case .custom: return "自訂"
        }
    }

    private static func color(for domain: WorkOSDomainKind) -> Color {
        switch domain {
        case .ui: return .blue
        case .code: return .indigo
        case .debug: return .red
        case .research: return .purple
        case .modeling: return .teal
        case .ops: return .gray
        case .custom: return .orange
        }
    }
}

struct DeepLoopHeader: View {
    let plan: DeepLoopPlan
    let contract: TatwoWorkOSContractV1

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(plan.title)
                    .font(.system(size: 14.2, weight: .black, design: .rounded))
                Text(plan.subtitle)
                    .font(.system(size: 11.0, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            FlowChip(text: plan.badges.prefix(2).joined(separator: " / "), color: .blue)
        }
        FlowChipCloud(chips: plan.badges, color: .primary)
    }
}


struct DeepNodeChain: View {
    let nodes: [DeepLoopNode]
    let accent: Color
    let progress: Double

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                DeepLoopNodeCard(node: node, compact: true)
                if index < nodes.count - 1 {
                    AnimatedMiniArrow(color: accent, progress: progress, axis: .horizontal)
                        .frame(width: 18, height: 38)
                }
            }
        }
    }
}



struct DeepLoopNodeCard: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let node: DeepLoopNode
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            HStack(spacing: 4) {
                Text(node.title)
                    .font(.system(size: compact ? 12.4 : 13.0, weight: .black, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)
                Spacer(minLength: 0)
                Text(node.badge)
                    .font(.system(size: 10.0, weight: .black, design: .rounded))
                    .foregroundStyle(node.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.80)
            }
            Text(node.subtitle)
                .font(.system(size: compact ? 10.8 : 11.2, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
            FlowChipCloud(chips: Array(node.chips.prefix(compact ? 1 : 2)), color: node.accent)
        }
        .padding(.horizontal, compact ? 8 : 9)
        .padding(.vertical, compact ? 7 : 8)
        .frame(maxWidth: .infinity, minHeight: compact ? 64 : 78, alignment: .topLeading)
        .background(Color.white.opacity(LiquidGlassTokens.nodeCardTintOpacity), in: RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: LiquidGlassTokens.shapeStyle))
        .overlay(
            RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: LiquidGlassTokens.shapeStyle)
                .strokeBorder(node.accent.opacity(0.70), lineWidth: 1.15)
        )
    }
}

struct DeepDomainCardView: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let card: DeepDomainCard
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(card.title)
                    .font(.system(size: 13.0, weight: .black, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)
                Spacer(minLength: 0)
                FlowChip(text: card.owner, color: card.accent)
            }
            HStack(spacing: 4) {
                ForEach(Array(card.steps.prefix(3).enumerated()), id: \.offset) { index, step in
                    Text(step)
                        .font(.system(size: 10.0, weight: .black, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .frame(maxWidth: .infinity)
                        .background(card.accent.opacity(0.10), in: Capsule())
                    if index < min(card.steps.count, 3) - 1 {
                        AnimatedMiniArrow(color: card.accent, progress: progress, axis: .horizontal)
                            .frame(width: 12, height: 12)
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                FlowMicroSpec(title: "工具", value: card.tools.joined(separator: " / "), color: .indigo)
                FlowMicroSpec(title: "沙盒", value: card.sandbox, color: .brown)
                FlowMicroSpec(title: "收據", value: card.receipts, color: .teal)
                FlowMicroSpec(title: "合併", value: card.merge, color: .orange)
            }
        }
        .padding(8)
        .background(Color.white.opacity(LiquidGlassTokens.nodeCardTintOpacity), in: RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: LiquidGlassTokens.shapeStyle))
        .overlay(
            RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: LiquidGlassTokens.shapeStyle)
                .strokeBorder(card.accent.opacity(0.35), lineWidth: 1)
        )
    }
}

struct FlowMicroSpec: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9.6, weight: .black, design: .rounded))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 9.8, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.80)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(LiquidGlassTokens.chipFillOpacity), in: RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: LiquidGlassTokens.shapeStyle))
    }
}

enum ArrowAxis {
    case horizontal
    case vertical
}

struct AnimatedMiniArrow: View {
    let color: Color
    let progress: Double
    let axis: ArrowAxis

    var body: some View {
        Canvas { context, size in
            let start: CGPoint
            let end: CGPoint
            switch axis {
            case .horizontal:
                start = CGPoint(x: 1, y: size.height / 2)
                end = CGPoint(x: max(size.width - 3, 2), y: size.height / 2)
            case .vertical:
                start = CGPoint(x: size.width / 2, y: 1)
                end = CGPoint(x: size.width / 2, y: max(size.height - 3, 2))
            }
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(path, with: .color(color.opacity(0.26)), style: StrokeStyle(lineWidth: 1.4, lineCap: .butt))
            for pulse in pulseTrain(progress: progress) {
                let markerCenter = CGPoint(
                    x: start.x + (end.x - start.x) * pulse.t,
                    y: start.y + (end.y - start.y) * pulse.t
                )
                let markerRect: CGRect
                let glowRect: CGRect
                switch axis {
                case .horizontal:
                    markerRect = CGRect(x: markerCenter.x - 5.2 * pulse.scale, y: markerCenter.y - 1.25 * pulse.scale, width: 10.4 * pulse.scale, height: 2.5 * pulse.scale)
                    glowRect = CGRect(x: markerCenter.x - 7.2 * pulse.scale, y: markerCenter.y - 3.0 * pulse.scale, width: 14.4 * pulse.scale, height: 6.0 * pulse.scale)
                case .vertical:
                    markerRect = CGRect(x: markerCenter.x - 1.25 * pulse.scale, y: markerCenter.y - 5.2 * pulse.scale, width: 2.5 * pulse.scale, height: 10.4 * pulse.scale)
                    glowRect = CGRect(x: markerCenter.x - 3.0 * pulse.scale, y: markerCenter.y - 7.2 * pulse.scale, width: 6.0 * pulse.scale, height: 14.4 * pulse.scale)
                }
                context.fill(Path(roundedRect: glowRect, cornerRadius: 2.2 * pulse.scale), with: .color(color.opacity(0.13 * pulse.opacity)))
                context.fill(Path(roundedRect: markerRect, cornerRadius: 1.2 * pulse.scale), with: .color(color.opacity(0.84 * pulse.opacity)))
            }
        }
        .accessibilityHidden(true)
    }

    private func pulseTrain(progress: Double) -> [(t: CGFloat, scale: CGFloat, opacity: Double)] {
        [0.0, 0.42, 0.78].enumerated().map { index, offset in
            let raw = (progress + offset).truncatingRemainder(dividingBy: 1)
            let t = raw < 0 ? raw + 1 : raw
            return (
                t: CGFloat(t),
                scale: index == 0 ? 1.0 : 0.68,
                opacity: index == 0 ? 1.0 : 0.52
            )
        }
    }
}

struct FlowChipCloud: View {
    let chips: [String]
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(chips.prefix(4).enumerated()), id: \.offset) { _, chip in
                FlowChip(text: chip, color: color)
            }
        }
    }
}

struct FlowChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9.6, weight: .black, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.80)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.10), in: Capsule())
            .foregroundStyle(color)
    }
}

struct DeepLoopLegendRow: View {
    let plan: DeepLoopPlan

    var body: some View {
        HStack(spacing: 8) {
            ForEach(plan.legend) { item in
                HStack(spacing: 4) {
                    Circle().fill(item.color).frame(width: 6, height: 6)
                    Text(item.title)
                        .font(.system(size: 9.2, weight: .black, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text("收據＋人工關卡")
                .font(.system(size: 8.8, weight: .black, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }
}
