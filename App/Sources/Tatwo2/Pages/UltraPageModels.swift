// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPageModels.swift；改動 2 行（原因：加來源註記並移除舊 core import）
import SwiftUI

struct UltraManualChapter: Identifiable {
    let id: String
    let number: String
    let title: String
    let outline: String
    let plainText: String
    let symbol: String
    let accent: Color
    let details: [UltraManualDetail]
    let diagram: [String]
    let tree: [UltraManualTreeNode]
}

struct UltraManualDetail: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let text: String
}

struct UltraManualTreeNode: Identifiable {
    let id: String
    let text: String
    let children: [UltraManualTreeNode]

    init(_ id: String, _ text: String, children: [UltraManualTreeNode] = []) {
        self.id = id
        self.text = text
        self.children = children
    }
}

enum WorkOSPlanLoopsGoalMetrics {
    static let width: CGFloat = 1120
    static let height: CGFloat = 820
    static let contentOffsetY: CGFloat = 38
    static let receiptRailY: CGFloat = 786
}

struct WorkOSPlanLoopsGoalBlueprint {
    let nodes: [WorkOSPlanLoopsGoalNode]
    let connectors: [WorkOSPlanLoopsGoalConnector]
    let receiptTags: [String]
    let modeSummary: String
}

struct WorkOSPlanLoopsGoalNode: Identifiable, Equatable {
    enum Kind: Equatable {
        case mainline
        case responsibility
        case branch
        case pass
        case fail
        case receipt
    }

    let id: String
    let title: String
    let subtitle: String
    let kicker: String
    let color: Color
    let rect: CGRect
    let kind: Kind

    func applying(_ override: WorkOSPlanLoopsGoalNodeOverride?) -> WorkOSPlanLoopsGoalNode {
        guard let override else { return self }
        return WorkOSPlanLoopsGoalNode(
            id: id,
            title: override.title ?? title,
            subtitle: override.subtitle ?? subtitle,
            kicker: override.kicker ?? kicker,
            color: color,
            rect: rect,
            kind: kind
        )
    }
}

struct WorkOSPlanLoopsGoalNodeOverride: Equatable {
    var kicker: String? = nil
    var title: String? = nil
    var subtitle: String? = nil
}

struct WorkOSPlanLoopsGoalConnector: Identifiable, Equatable {
    enum Style: Equatable {
        case main
        case branch
        case pass
        case fail
        case receipt
    }

    let id: String
    let points: [CGPoint]
    let baseColor: Color
    let flowColor: Color
    let style: Style
    let width: CGFloat
}


enum WorkOSSpineBlueprintMetrics {
    static let width: CGFloat = 1040
    static let height: CGFloat = 710
    static let topY: CGFloat = 54
    static let spineX: CGFloat = 520
    static let contractX: CGFloat = 150
    static let identityX: CGFloat = 520
    static let policyX: CGFloat = 890
    static let domainX: CGFloat = 130
    static let domainBusX: CGFloat = 310
    static let toolX: CGFloat = 910
    static let toolBusX: CGFloat = 735
    static let intakeY: CGFloat = 190
    static let supervisorY: CGFloat = 294
    static let execY: CGFloat = 398
    static let receiptY: CGFloat = 502
    static let gateY: CGFloat = 582
    static let outcomeY: CGFloat = 642
    static let rollbackX: CGFloat = 355
    static let readyX: CGFloat = 685
    static let verdictSplitY: CGFloat = 620
    static let mainCardWidth: CGFloat = 300
    static let mainCardHeight: CGFloat = 76
    static let topCardWidth: CGFloat = 260
    static let topCardHeight: CGFloat = 64
    static let domainCardWidth: CGFloat = 235
    static let domainCardHeight: CGFloat = 82
    static let toolCardWidth: CGFloat = 250
    static let toolCardHeight: CGFloat = 80
    static let toolPortGap: CGFloat = 34
    static let outcomeCardWidth: CGFloat = 275
    static let outcomeCardHeight: CGFloat = 50
    static let gateCardWidth: CGFloat = 184
    static let gateCardHeight: CGFloat = 50
    static let receiptRailY: CGFloat = 692
    static let receiptRailWidth: CGFloat = 860
    static let receiptRailHeight: CGFloat = 32
}

struct WorkOSDomainBlueprint: Identifiable {
    let id: String
    let title: String
    let owner: String
    let tools: String
    let receipt: String
    let color: Color
}

enum WorkOSOutcomeKind {
    case ready
    case rollback
}

struct WorkOSPipelineRow: Identifiable {
    let id: String
    let lane: WorkOSFlowLane
    let nodes: [WorkOSFlowNode]
}

enum WorkOSPipelineMetrics {
    static let mapHorizontalPadding: CGFloat = 14
    static let mapVerticalPadding: CGFloat = 16
    static let laneHeight: CGFloat = 146
    static let laneSpacing: CGFloat = 14
    static let laneHorizontalPadding: CGFloat = 14
    static let stepColumnWidth: CGFloat = 46
    static let laneHeaderWidth: CGFloat = 238
    static let pipeWidth: CGFloat = 48
}

enum WorkOSPipelineNodeKind {
    case standard
    case contract
    case domain
    case receipt
    case sandbox
    case runtime
    case gate
}

struct WorkOSFlowTemplate: Equatable {
    let id: String
    let nodes: [WorkOSFlowNode]
    let edges: [WorkOSFlowEdge]
    let lanes: [WorkOSFlowLane]
}

struct WorkOSFlowLane: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let color: Color
    let rect: CGRect
}

struct WorkOSFlowNode: Identifiable, Equatable {
    let id: String
    let title: String
    let body: String
    let color: Color
    let rect: CGRect
}

struct WorkOSFlowEdge: Identifiable, Equatable {
    let id: String
    let from: String
    let to: String
    let via: [CGPoint]
    let color: Color
    let style: WorkOSFlowEdgeStyle
}

enum WorkOSFlowEdgeStyle: Equatable {
    case primary
    case feedback
}

enum WorkOSFlowSizing {
    static func height(for mode: WorkModeID) -> CGFloat {
        switch mode {
        case .s: return WorkOSSpineBlueprintMetrics.height
        case .m: return WorkOSSpineBlueprintMetrics.height
        case .l: return WorkOSSpineBlueprintMetrics.height
        case .xl, .xxl: return WorkOSSpineBlueprintMetrics.height
        }
    }

    static func minWidth(for mode: WorkModeID) -> CGFloat {
        switch mode {
        case .s: return 1540
        case .m: return 4720
        case .l: return 1500
        case .xl, .xxl: return 1500
        }
    }
}

struct PlacedWorkOSFlowNode: Identifiable {
    var id: String { node.id }
    let node: WorkOSFlowNode
    let rect: CGRect
}

struct PlacedWorkOSFlowEdge: Identifiable {
    let id: String
    let points: [CGPoint]
    let color: Color
    let isReturnChannel: Bool
    let isWrapChannel: Bool
}

struct PlacedWorkOSFlowLane: Identifiable {
    var id: String { lane.id }
    let lane: WorkOSFlowLane
    let rect: CGRect
}

struct WorkOSFlowLayout {
    let placedNodes: [PlacedWorkOSFlowNode]
    let edges: [PlacedWorkOSFlowEdge]
    let placedLanes: [PlacedWorkOSFlowLane]

    init(size: CGSize, template: WorkOSFlowTemplate) {
        let width = max(size.width, 340)
        let height = max(size.height, 260)
        let horizontalInset: CGFloat = width >= 1700 ? 42 : (width >= 1500 ? 36 : (width >= 1200 ? 32 : (width >= 900 ? 26 : 14)))
        let verticalInset: CGFloat = height >= 700 ? 30 : (height >= 620 ? 28 : (height >= 450 ? 22 : 14))
        let minNodeWidth: CGFloat = width >= 1700 ? 252 : (width >= 1500 ? 232 : (width >= 1400 ? 218 : (width >= 1180 ? 198 : (width >= 900 ? 164 : 108))))
        let maxNodeWidth: CGFloat = width >= 1700 ? 316 : (width >= 1500 ? 292 : (width >= 1400 ? 276 : (width >= 1180 ? 244 : (width >= 900 ? 210 : (width >= 620 ? 152 : 118)))))
        let minNodeHeight: CGFloat = height >= 700 ? 106 : (height >= 620 ? 98 : (height >= 450 ? 88 : 58))
        let maxNodeHeight: CGFloat = height >= 700 ? 132 : (height >= 620 ? 122 : (height >= 450 ? 114 : 76))
        let placed = template.nodes.map { node -> PlacedWorkOSFlowNode in
            let raw = CGRect(
                x: node.rect.minX * width,
                y: node.rect.minY * height,
                width: node.rect.width * width,
                height: node.rect.height * height
            )
            let nodeWidth = min(max(raw.width, minNodeWidth), maxNodeWidth)
            let nodeHeight = min(max(raw.height, minNodeHeight), maxNodeHeight)
            let rect = Self.snapRect(CGRect(
                x: min(max(raw.minX, horizontalInset), width - nodeWidth - horizontalInset),
                y: min(max(raw.minY, verticalInset), height - nodeHeight - verticalInset),
                width: nodeWidth,
                height: nodeHeight
            ))
            return PlacedWorkOSFlowNode(node: node, rect: rect)
        }
        self.placedNodes = placed
        let dict = Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0.rect) })
        self.edges = template.edges.compactMap { edge in
            guard let from = dict[edge.from], let to = dict[edge.to] else { return nil }
            let viaPoints = edge.via.map { Self.snap(CGPoint(x: $0.x * width, y: $0.y * height)) }
            let startReference = viaPoints.first ?? CGPoint(x: to.midX, y: to.midY)
            let endReference = viaPoints.last ?? CGPoint(x: from.midX, y: from.midY)
            let start = Self.anchor(from: from, toPoint: startReference)
            let end = Self.anchor(to: to, fromPoint: endReference)
            let points = Self.orthogonalized([start] + viaPoints + [end]).map(Self.snap)
            let isReturnChannel = edge.style == .feedback
            let isWrapChannel = !edge.via.isEmpty
            return PlacedWorkOSFlowEdge(id: edge.id, points: points, color: edge.color, isReturnChannel: isReturnChannel, isWrapChannel: isWrapChannel)
        }
        self.placedLanes = template.lanes.map { lane in
            let rect = Self.snapRect(CGRect(
                x: lane.rect.minX * width,
                y: lane.rect.minY * height,
                width: lane.rect.width * width,
                height: lane.rect.height * height
            ))
            return PlacedWorkOSFlowLane(lane: lane, rect: rect)
        }
    }

    private static func snap(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded(.toNearestOrAwayFromZero) / 2
    }

    private static func snap(_ point: CGPoint) -> CGPoint {
        CGPoint(x: snap(point.x), y: snap(point.y))
    }

    private static func snapRect(_ rect: CGRect) -> CGRect {
        CGRect(x: snap(rect.minX), y: snap(rect.minY), width: snap(rect.width), height: snap(rect.height))
    }

    private static func anchor(from rect: CGRect, to target: CGRect) -> CGPoint {
        anchor(from: rect, toPoint: CGPoint(x: target.midX, y: target.midY))
    }

    private static func anchor(from rect: CGRect, toPoint target: CGPoint) -> CGPoint {
        let dx = target.x - rect.midX
        let dy = target.y - rect.midY
        if abs(dx) > abs(dy) {
            return snap(CGPoint(x: dx >= 0 ? rect.maxX + 10 : rect.minX - 10, y: rect.midY))
        }
        return snap(CGPoint(x: rect.midX, y: dy >= 0 ? rect.maxY + 10 : rect.minY - 10))
    }

    private static func anchor(to rect: CGRect, from source: CGRect) -> CGPoint {
        anchor(to: rect, fromPoint: CGPoint(x: source.midX, y: source.midY))
    }

    private static func anchor(to rect: CGRect, fromPoint source: CGPoint) -> CGPoint {
        let dx = rect.midX - source.x
        let dy = rect.midY - source.y
        if abs(dx) > abs(dy) {
            return snap(CGPoint(x: dx >= 0 ? rect.minX - 10 : rect.maxX + 10, y: rect.midY))
        }
        return snap(CGPoint(x: rect.midX, y: dy >= 0 ? rect.minY - 10 : rect.maxY + 10))
    }

    private static func orthogonalized(_ points: [CGPoint]) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var result = [first]
        for next in points.dropFirst() {
            guard let current = result.last else { continue }
            let dx = abs(next.x - current.x)
            let dy = abs(next.y - current.y)
            if dx < 0.5 || dy < 0.5 {
                result.append(next)
            } else if dx >= dy {
                result.append(CGPoint(x: next.x, y: current.y))
                result.append(next)
            } else {
                result.append(CGPoint(x: current.x, y: next.y))
                result.append(next)
            }
        }
        return result.filterAdjacentDuplicates()
    }
}

extension Array where Element == CGPoint {
    func filterAdjacentDuplicates() -> [CGPoint] {
        var filtered: [CGPoint] = []
        for point in self {
            guard let last = filtered.last else {
                filtered.append(point)
                continue
            }
            if hypot(point.x - last.x, point.y - last.y) > 0.5 {
                filtered.append(point)
            }
        }
        return filtered
    }
}
