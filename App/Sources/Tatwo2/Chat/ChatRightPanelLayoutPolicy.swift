// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatRightPanelLayoutPolicy.swift；改動 2 行（原因：移除舊 Core import，改接同名 Facade 假資料）
import Foundation

enum ChatRightPanelPresentation: Equatable {
    case closed
    case docked
    case compactTakeover
    case focusedTakeover
}

enum ChatRightPanelWidthClass: Equatable {
    case standard
    case loops
}

struct ChatRightPanelLayoutResult: Equatable {
    let presentation: ChatRightPanelPresentation
    let panelWidth: CGFloat
    let mainContentWidth: CGFloat
    let spacing: CGFloat

    var isOpen: Bool {
        presentation != .closed
    }

    var showsMainContent: Bool {
        presentation != .compactTakeover
            && presentation != .focusedTakeover
    }
}

enum ChatRightPanelLayoutPolicy {
    static let automaticOpenMinimumWidth: CGFloat = 1600
    static let minimumPanelWidth: CGFloat = 320
    static let loopsMinimumPanelWidth: CGFloat = 560
    static let loopsMaximumPanelWidth: CGFloat = 860
    static let minimumMainContentWidth: CGFloat = 352
    static let loopsMinimumMainContentWidth: CGFloat = 620
    static let dockSpacing: CGFloat = 12

    static func resolve(
        layoutWidth rawLayoutWidth: CGFloat,
        preference: Bool?,
        widthClass: ChatRightPanelWidthClass = .standard,
        forceFocus: Bool = false
    ) -> ChatRightPanelLayoutResult {
        let layoutWidth = max(0, rawLayoutWidth)
        let preferredPanelWidth: CGFloat
        let requiredMainContentWidth: CGFloat
        switch widthClass {
        case .standard:
            preferredPanelWidth = minimumPanelWidth
            requiredMainContentWidth = minimumMainContentWidth
        case .loops:
            preferredPanelWidth = min(
                loopsMaximumPanelWidth,
                max(loopsMinimumPanelWidth, layoutWidth * 0.44))
            requiredMainContentWidth = loopsMinimumMainContentWidth
        }
        let canDock =
            layoutWidth >= preferredPanelWidth + dockSpacing + requiredMainContentWidth
        let automaticallyOpen = layoutWidth >= automaticOpenMinimumWidth && canDock
        let shouldOpen = preference ?? automaticallyOpen

        guard shouldOpen else {
            return ChatRightPanelLayoutResult(
                presentation: .closed,
                panelWidth: 0,
                mainContentWidth: layoutWidth,
                spacing: 0
            )
        }

        if forceFocus {
            return ChatRightPanelLayoutResult(
                presentation: .focusedTakeover,
                panelWidth: layoutWidth,
                mainContentWidth: 0,
                spacing: 0
            )
        }

        if canDock {
            return ChatRightPanelLayoutResult(
                presentation: .docked,
                panelWidth: preferredPanelWidth,
                mainContentWidth: layoutWidth - preferredPanelWidth - dockSpacing,
                spacing: dockSpacing
            )
        }

        return ChatRightPanelLayoutResult(
            presentation: .compactTakeover,
            panelWidth: layoutWidth,
            mainContentWidth: 0,
            spacing: 0
        )
    }
}

struct ChatBrowserInspectorLayout: Equatable {
    static let dividerWidth: CGFloat = 1

    func clampedWidth(_ requested: CGFloat) -> CGFloat {
        guard canDock else { return 0 }
        let preferred = requested.isFinite && requested > 0 ? requested : idealWidth
        return min(maximumWidth, max(minimumWidth, preferred))
    }

    let canDock: Bool
    let minimumWidth: CGFloat
    let idealWidth: CGFloat
    let maximumWidth: CGFloat

    static func compactPanelHeight(windowHeight: CGFloat) -> CGFloat {
        guard windowHeight.isFinite else { return 0 }
        return min(420, max(0, windowHeight) * 0.42)
    }

    static func resolve(windowWidth: CGFloat) -> Self {
        let width = windowWidth.isFinite ? max(0, windowWidth) : 0
        let workspaceReserve = WorkspaceSidebarMetrics.width + WorkspaceSidebarMetrics.contentGap
            + ChatRightPanelLayoutPolicy.minimumMainContentWidth
        let available = max(0, width - workspaceReserve - dividerWidth)
        let maximum = min(960, available)
        let canDock = maximum >= 320
        return Self(canDock: canDock, minimumWidth: canDock ? 320 : 0,
            idealWidth: canDock ? min(max(320, width * 0.40), maximum) : 0,
            maximumWidth: canDock ? maximum : 0)
    }
}
