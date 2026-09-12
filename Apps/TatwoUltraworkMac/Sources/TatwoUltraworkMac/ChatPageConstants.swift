import SwiftUI
import Foundation
import TatwoUltraworkCore

enum ChatUILayout {
    static let chatColumnMaxWidth: CGFloat = 820
    static let transcriptLineSpacing = TatwoChatTranscriptVisualMetrics.transcriptLineSpacing
    static let cardRadius: CGFloat = 20
    static let panelRadius: CGFloat = 18
    static let nestedRadius: CGFloat = 14
    static let microRadius: CGFloat = 11
    static let cardStrokeOpacity: Double = 0.115
    static let quietStrokeOpacity: Double = 0.075
    static let quietFillOpacity: Double = 0.036
    static let selectedFillOpacity: Double = 0.118
}

enum ChatTypography {
    /// Use macOS system UI metrics for Latin, numbers, and symbols while
    /// retaining the system font cascade's native Traditional Chinese fallback.
    static func systemUI(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static let composerPointSize = TatwoChatTranscriptVisualMetrics.composerPointSize
    static let sidebarHeader = systemUI(TatwoChatTranscriptVisualMetrics.sidebarHeaderPointSize, weight: .semibold)
    static let sidebarProject = systemUI(TatwoChatTranscriptVisualMetrics.sidebarProjectPointSize, weight: .semibold)
    static let sidebarThreadTitle = systemUI(TatwoChatTranscriptVisualMetrics.sidebarThreadTitlePointSize, weight: .semibold)
    static let sidebarThreadPreview = systemUI(TatwoChatTranscriptVisualMetrics.sidebarThreadPreviewPointSize, weight: .regular)
    static let transcriptUser = systemUI(TatwoChatTranscriptVisualMetrics.transcriptPointSize, weight: .regular)
    static let transcriptAssistant = systemUI(TatwoChatTranscriptVisualMetrics.transcriptPointSize, weight: .regular)
    static let transcriptMeta = systemUI(TatwoChatTranscriptVisualMetrics.transcriptMetaPointSize, weight: .regular)
    static let body = systemUI(TatwoChatTranscriptVisualMetrics.bodyPointSize, weight: .regular)
    /// CLI terminal body. SF Mono at transcript 13 reads larger than system UI 13;
    /// pin to transcriptMeta so the pane matches app mono chips/meta, not a display face.
    static let terminalPointSize = TatwoChatTranscriptVisualMetrics.transcriptMetaPointSize
    static let terminalContentInset: CGFloat = 12
    static let terminalMono = Font.system(size: terminalPointSize, weight: .regular, design: .monospaced)
}

enum ChatRunMode: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case cli = "CLI"
    case bot = "Bot"

    /// Wave1: Ultrawork/cowork tab removed from chat chrome; keep `.chat` + `.cli` only.
    /// Archived sidebar: `Apps/TatwoUltraworkMac/_archived/ChatPage-coworkSidebar-wave1-20260728.swift.txt`
    /// Gen-4: `.bot` 第三格＝純 UI 展示面（GEN4_UI_PLAN §1-8；零副作用、零 runner）。
    static let visibleChatTabs: [ChatRunMode] = [.chat, .cli, .bot]

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .cli: "terminal"
        case .bot: "person.2"
        }
    }

    var commandMode: TatwoChatCommandMode {
        switch self {
        case .chat: .chat
        case .cli: .cli
        // Gen-4 展示面沒有命令面；映射 .chat 僅為型別完備，bot 模式下 composer 不掛接。
        case .bot: .chat
        }
    }

    var subtitle: String {
        switch self {
        case .chat: "互動續聊"
        case .cli: "唯讀終端"
        case .bot: "bot 展示"
        }
    }
}

enum ChatCollaborationLevel: Int, CaseIterable, Identifiable {
    case off = 0
    case s = 1
    case m = 2
    case l = 3
    case xl = 4
    case xxl = 5

    var id: Int { rawValue }
    var sliderValue: Double { Double(rawValue) }

    init(workMode: WorkModeID?) {
        switch workMode {
        case .s?: self = .s
        case .m?: self = .m
        case .l?: self = .l
        case .xl?: self = .xl
        case .xxl?: self = .xxl
        case nil: self = .off
        }
    }

    var workMode: WorkModeID? {
        switch self {
        case .off: nil
        case .s: .s
        case .m: .m
        case .l: .l
        case .xl: .xl
        case .xxl: .xxl
        }
    }

    var title: String {
        switch self {
        case .off: "Off"
        case .s: "S"
        case .m: "M"
        case .l: "L"
        case .xl: "XL"
        case .xxl: "XXL"
        }
    }

    var subtitle: String {
        switch self {
        case .off: "純 Chat"
        case .s: "主線"
        case .m: "副審"
        case .l: "專案"
        case .xl: "重型"
        case .xxl: "最重型"
        }
    }
}

enum ChatSnapshotMenu: String {
    case none
    case permission
    case model

    static var current: ChatSnapshotMenu {
        let raw = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_CHAT_SNAPSHOT_MENU"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ChatSnapshotMenu(rawValue: raw ?? "") ?? .none
    }
}


typealias ChatSkin = TatwoNativeChatSkin

extension ChatSkin {
    var symbol: String {
        switch self {
        case .codex: "bubble.left.and.bubble.right.fill"
        case .claude: "terminal.fill"
        }
    }

    var shortTitle: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }
}
