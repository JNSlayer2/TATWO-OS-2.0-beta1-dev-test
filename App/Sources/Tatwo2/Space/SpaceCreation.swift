import Foundation

/// 從零建立第一個領域 Space 的共用判斷。純函式，不碰 IO，也不 import SwiftUI，
/// 讓 tests/w89-space-from-zero.test.mjs 可以單獨編譯這個檔驗證前置條件。
enum SpaceCreationOutcome: Equatable {
    /// 可以建立；owner 用選中的 bot，沒有選中就用 library 第一隻。
    case ready(ownerBotID: String)
    /// 有目前專案但一隻 bot 都沒有：先建立 bot。
    case needsBot
    /// 連目前專案都沒有：建 bot 需要專案工作目錄（New/BotUIWire.createLiveBot）。
    case needsProject
}

enum SpaceCreationResult: Equatable {
    case created(id: String, name: String)
    case blocked(SpaceCreationOutcome)
    case failed(String)
}

enum SpaceCreation {
    /// 既有 space 的預設密度（BotFixtureDensity.compact）。從零建立不讓使用者先選密度。
    static let defaultDensity = "compact"

    static let emptyExplanation = "Space 是 bot 的工作領域；先建立第一個領域"
    static let createTitle = "建立第一個領域"
    static let needsBotTitle = "先建立 bot"
    static let needsProjectTitle = "先選擇專案"
    static let namePlaceholder = "領域名稱"
    static let loadingText = "正在讀取 work space…"

    /// 前置條件：bot 優先。沒有 bot 才看專案（沒有專案連 bot 都建不了）。
    static func outcome(botIDs: [String], selectedBotID: String?, projectWorkdir: String?) -> SpaceCreationOutcome {
        if let selected = selectedBotID, botIDs.contains(selected) { return .ready(ownerBotID: selected) }
        if let first = botIDs.first { return .ready(ownerBotID: first) }
        let workdir = projectWorkdir?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return workdir.isEmpty ? .needsProject : .needsBot
    }

    /// 空狀態主按鈕／導引文案。
    static func actionTitle(for outcome: SpaceCreationOutcome) -> String {
        switch outcome {
        case .ready: return createTitle
        case .needsBot: return needsBotTitle
        case .needsProject: return needsProjectTitle
        }
    }

    /// 被前置條件擋下時給呼叫端的訊息（Bot 頁完成畫面用）。
    static func guidance(for outcome: SpaceCreationOutcome) -> String {
        switch outcome {
        case .ready: return ""
        case .needsBot: return "還沒有任何 bot，先建立 bot 再建立領域。"
        case .needsProject: return "還沒有目前專案，先選擇專案再建立 bot 與領域。"
        }
    }

    /// 領域名稱：去頭尾空白；空字串不建立。
    static func normalizedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
    }

    /// Bot 頁三段流只有路徑與提示詞欄位；領域名稱取路徑最後一段。
    static func nameFromPath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let last = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        return normalizedName(last)
    }

    static func successText(name: String) -> String { "已建立領域 \(name)" }
}
