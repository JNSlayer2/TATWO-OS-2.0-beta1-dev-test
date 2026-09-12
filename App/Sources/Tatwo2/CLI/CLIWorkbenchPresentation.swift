import Foundation

/// Process/task evidence and attachment are separate axes. Background is NOT completion.
enum CLIWorkbenchProcessState: String, CaseIterable {
    case running, waiting, exited, unknown

    var label: String {
        switch self {
        case .running: return "執行中"
        case .waiting: return "等待輸入"
        case .exited: return "已退出"
        case .unknown: return "狀態未知"
        }
    }

    var explanation: String {
        switch self {
        case .running: return "已觀察到執行活動；不代表任務成功"
        case .waiting: return "已觀察到等待輸入的事件"
        case .exited: return "程序已結束；不會自動重跑"
        case .unknown: return "沒有足夠的任務狀態證據；程序存活不等於成功"
        }
    }
}

struct CLIWorkbenchPane: Identifiable, Equatable {
    let id: UUID
    var title: String
    var engine: String
    var project: String
    var state: CLIWorkbenchProcessState = .unknown
    var isBackground = false
    var exitCode: Int?

    var statusLabel: String {
        let stateLabel = state == .exited
            ? "\(state.label)\(exitCode.map { " · \($0)" } ?? "")" : state.label
        return isBackground ? "背景 · \(stateLabel)" : stateLabel
    }
    var symbol: String {
        switch engine {
        case "claude": return "sparkle"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "grok": return "bolt"
        default: return "terminal"
        }
    }
}

struct CLIWorkbenchTab: Identifiable, Equatable, Codable {
    let id: UUID
    var title: String
    var layout: CLIWorkbenchLayout?
    var focusedPaneID: UUID?
    var maximizedPaneID: UUID?
}

struct CLIWorkbenchEditingOptions: Equatable, Codable {
    // Independent, opt-in; the runtime wrapper will observe changes in Phase B.
    var deleteToLineStart = false
    var deletePreviousWord = false
}

enum CLIWorkbenchCloseChoice: Equatable { case background, terminate, cancel }

/// Single, small presentation-to-controller seam. No command strings or engine imports.
enum CLIWorkbenchAction {
    case createTab(engine: String)
    case selectTab(UUID)
    case requestCloseTab(UUID)
    case selectPane(UUID)
    case split(UUID, CLIWorkbenchAxis)
    case setRatio(UUID, Double)
    case focusNext(backwards: Bool)
    case toggleMaximize(UUID)
    case requestClosePane(UUID)
    case resolveClose(CLIWorkbenchCloseChoice)
    case reattach(UUID)
    case sendSelectionToDraft(UUID)
    case find(UUID, String, backwards: Bool)
    case setEditingOptions(CLIWorkbenchEditingOptions)
}
