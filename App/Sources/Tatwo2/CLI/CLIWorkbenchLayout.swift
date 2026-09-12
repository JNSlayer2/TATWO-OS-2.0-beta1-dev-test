import Foundation

/// Presentation geometry only. Pane IDs are session identities, never array indices.
/// No terminal, process or persistence work belongs in this file.
enum CLIWorkbenchMetrics {
    static let paneHeader: CGFloat = 28
    static let terminalFont: CGFloat = 13
    static let terminalLine: CGFloat = 18
    static let inset: CGFloat = 8
    static let smallGap: CGFloat = 4
    static let hairline: CGFloat = 1
    static let dividerHit: CGFloat = 8
    static let control: CGFloat = 24
    static let icon: CGFloat = 12
    static let labelFont: CGFloat = 11.5
    static let tabHeight: CGFloat = 34
    static let sidebarRow: CGFloat = 32
    static let tabMin: CGFloat = 110
    static let tabMax: CGFloat = 200
    static let footer: CGFloat = 24
    static let minimumPane = CGSize(width: 360, height: 180)
}

enum CLIWorkbenchAxis: String, Codable {
    case horizontal, vertical
}

indirect enum CLIWorkbenchLayout: Equatable, Codable {
    case pane(UUID)
    case split(id: UUID, axis: CLIWorkbenchAxis, ratio: Double,
               first: CLIWorkbenchLayout, second: CLIWorkbenchLayout)

    var paneIDs: [UUID] {
        switch self {
        case .pane(let id): return [id]
        case .split(_, _, _, let first, let second): return first.paneIDs + second.paneIDs
        }
    }

    var minimumSize: CGSize {
        switch self {
        case .pane: return CLIWorkbenchMetrics.minimumPane
        case .split(_, let axis, _, let first, let second):
            let a = first.minimumSize, b = second.minimumSize
            let gap = CLIWorkbenchMetrics.dividerHit
            return axis == .horizontal
                ? CGSize(width: a.width + gap + b.width, height: max(a.height, b.height))
                : CGSize(width: max(a.width, b.width), height: a.height + gap + b.height)
        }
    }

    func splitting(_ paneID: UUID, newPane: UUID, axis: CLIWorkbenchAxis,
                   splitID: UUID = UUID()) -> Self {
        guard !paneIDs.contains(newPane) else { return self }
        switch self {
        case .pane(let id):
            return id == paneID
                ? .split(id: splitID, axis: axis, ratio: 0.5, first: self, second: .pane(newPane))
                : self
        case .split(let id, let oldAxis, let ratio, let first, let second):
            return .split(id: id, axis: oldAxis, ratio: ratio,
                          first: first.splitting(paneID, newPane: newPane, axis: axis, splitID: splitID),
                          second: second.splitting(paneID, newPane: newPane, axis: axis, splitID: splitID))
        }
    }

    func removing(_ paneID: UUID) -> Self? {
        switch self {
        case .pane(let id): return id == paneID ? nil : self
        case .split(let id, let axis, let ratio, let first, let second):
            switch (first.removing(paneID), second.removing(paneID)) {
            case (.some(let a), .some(let b)):
                return .split(id: id, axis: axis, ratio: ratio, first: a, second: b)
            case (.some(let survivor), nil), (nil, .some(let survivor)): return survivor
            case (nil, nil): return nil
            }
        }
    }

    func settingRatio(splitID: UUID, ratio: Double) -> Self {
        guard ratio.isFinite else { return self }
        switch self {
        case .pane: return self
        case .split(let id, let axis, let old, let first, let second):
            return .split(id: id, axis: axis,
                          ratio: id == splitID ? min(0.95, max(0.05, ratio)) : old,
                          first: first.settingRatio(splitID: splitID, ratio: ratio),
                          second: second.settingRatio(splitID: splitID, ratio: ratio))
        }
    }

    /// Keep every pane mounted when focusing/maximizing. Resizing must not recreate a terminal.
    func projection(in size: CGSize, focused: UUID?, maximized: UUID?) -> CLIWorkbenchProjection {
        let bounds = CGRect(origin: .zero, size: CGSize(width: max(0, size.width), height: max(0, size.height)))
        let ids = paneIDs
        let compact = size.width < minimumSize.width || size.height < minimumSize.height
        let focus = focused.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        let zoom = maximized.flatMap { ids.contains($0) ? $0 : nil }
        let only = zoom ?? (compact ? focus : nil)
        var result = CLIWorkbenchProjection(isCompact: compact && zoom == nil, shownAlone: only)
        if let only {
            result.panes = ids.map {
                CLIWorkbenchPlacement(id: $0, frame: bounds, isVisible: $0 == only)
            }
        } else {
            place(in: bounds, into: &result)
        }
        return result
    }

    private func place(in rect: CGRect, into result: inout CLIWorkbenchProjection) {
        switch self {
        case .pane(let id):
            result.panes.append(CLIWorkbenchPlacement(id: id, frame: rect, isVisible: true))
        case .split(let id, let axis, let ratio, let first, let second):
            let horizontal = axis == .horizontal
            let length = horizontal ? rect.width : rect.height
            let gap = min(CLIWorkbenchMetrics.dividerHit, length)
            let available = max(0, length - gap)
            let aMin = horizontal ? first.minimumSize.width : first.minimumSize.height
            let bMin = horizontal ? second.minimumSize.width : second.minimumSize.height
            let safeRatio = ratio.isFinite ? min(0.95, max(0.05, ratio)) : 0.5
            let firstLength = min(max(aMin, available * safeRatio), max(0, available - bMin))
            let a = horizontal
                ? CGRect(x: rect.minX, y: rect.minY, width: firstLength, height: rect.height)
                : CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstLength)
            let handle = horizontal
                ? CGRect(x: a.maxX, y: rect.minY, width: gap, height: rect.height)
                : CGRect(x: rect.minX, y: a.maxY, width: rect.width, height: gap)
            let b = horizontal
                ? CGRect(x: handle.maxX, y: rect.minY, width: available - firstLength, height: rect.height)
                : CGRect(x: rect.minX, y: handle.maxY, width: rect.width, height: available - firstLength)
            result.dividers.append(CLIWorkbenchDivider(id: id, axis: axis, frame: handle,
                availableLength: available, ratio: available > 0 ? firstLength / available : 0.5))
            first.place(in: a, into: &result)
            second.place(in: b, into: &result)
        }
    }
}

struct CLIWorkbenchPlacement: Identifiable {
    let id: UUID
    let frame: CGRect
    let isVisible: Bool
}

struct CLIWorkbenchDivider: Identifiable {
    let id: UUID
    let axis: CLIWorkbenchAxis
    let frame: CGRect
    let availableLength: CGFloat
    let ratio: Double
}

struct CLIWorkbenchProjection {
    var panes: [CLIWorkbenchPlacement] = []
    var dividers: [CLIWorkbenchDivider] = []
    let isCompact: Bool
    let shownAlone: UUID?
}
