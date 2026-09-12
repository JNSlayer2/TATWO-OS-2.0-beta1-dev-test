// 右側面板互動策略（純函式，可測）。
// 2026-07-12 使用者定案：資訊卡改「懸浮浮層」(infoCardFloatingOpen)，不再進右側面板；
// 右側面板只承載需要寬度的重內容＝Loops / diff / 瀏覽器 / 檔案。
enum RightPanelContent: Hashable {
    case none
    case browser
    case file
    case loops // #16 loops session 收納串
    case diff // D① 變更收據 diff
}

enum ChatRightPanelInteractionAction: Equatable {
    case toggleBrowser
    case toggleFile
    case toggleLoops
    case toggleDiff
}

struct ChatRightPanelInteractionState: Equatable {
    let content: RightPanelContent
    let preference: Bool?
}

enum ChatRightPanelInteractionPolicy {
    static func reduce(
        currentContent: RightPanelContent,
        isPanelOpen: Bool,
        action: ChatRightPanelInteractionAction
    ) -> ChatRightPanelInteractionState {
        switch action {
        case .toggleBrowser:
            toggledState(
                target: .browser,
                currentContent: currentContent,
                isPanelOpen: isPanelOpen
            )
        case .toggleFile:
            toggledState(
                target: .file,
                currentContent: currentContent,
                isPanelOpen: isPanelOpen
            )
        case .toggleLoops:
            toggledState(
                target: .loops,
                currentContent: currentContent,
                isPanelOpen: isPanelOpen
            )
        case .toggleDiff:
            toggledState(
                target: .diff,
                currentContent: currentContent,
                isPanelOpen: isPanelOpen
            )
        }
    }

    // 點同一類且面板已開 → 收合(preference=false)；否則切到該類並開啟(preference=true)。
    private static func toggledState(
        target: RightPanelContent,
        currentContent: RightPanelContent,
        isPanelOpen: Bool
    ) -> ChatRightPanelInteractionState {
        ChatRightPanelInteractionState(
            content: target,
            preference: currentContent == target && isPanelOpen ? false : true
        )
    }
}
