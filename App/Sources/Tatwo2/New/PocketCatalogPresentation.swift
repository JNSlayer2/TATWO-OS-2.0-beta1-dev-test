/// Presentation-only catalogue. No installation records, discovery or device operations.
enum PocketCategory: String, CaseIterable, Identifiable, Sendable {
    case general, requiresJailbreak, jailbroken

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "一般環境"
        case .requiresJailbreak: "需要越獄"
        case .jailbroken: "越獄環境"
        }
    }
}

enum PocketPlugin: String, CaseIterable, Identifiable, Sendable {
    case iPadUse, jumpOverCreek, ownEnvironment

    var id: String {
        switch self {
        case .iPadUse: "ai.tatwo.pocket.ipad-use"
        case .jumpOverCreek: "ai.tatwo.pocket.jump-over-creek"
        case .ownEnvironment: "ai.tatwo.pocket.own-environment"
        }
    }
    var title: String {
        switch self {
        case .iPadUse: "iPad USE"
        case .jumpOverCreek: "Jump Over Creek"
        case .ownEnvironment: "自研環境"
        }
    }
    var category: PocketCategory {
        switch self {
        case .iPadUse: .general
        case .jumpOverCreek: .requiresJailbreak
        case .ownEnvironment: .jailbroken
        }
    }
    var symbol: String {
        switch self {
        case .iPadUse: "ipad"
        case .jumpOverCreek: "hare"
        case .ownEnvironment: "wrench.and.screwdriver"
        }
    }
    var summary: String {
        switch self {
        case .iPadUse: "透過 Mac 連接並授權自己的 iPad。"
        case .jumpOverCreek: "越獄裝置上的自有工具；尚無已驗證的裝置介接。"
        case .ownEnvironment: "自研越獄環境的規劃入口。"
        }
    }
    var requirement: String {
        switch self {
        case .iPadUse: "需要 Mac、USB 連線與裝置授權；不需要越獄。"
        case .jumpOverCreek: "僅限已驗證的自研環境；目前尚未打通。"
        case .ownEnvironment: "尚未提供可驗證的支援範圍。"
        }
    }
    var status: String {
        switch self {
        case .iPadUse: "在 Mac 設定"
        case .jumpOverCreek: "尚未提供"
        case .ownEnvironment: "研究中"
        }
    }
}

enum PocketCatalogPresentation {
    static let publisher = "TATWO 自有插件"
    static let packageStatus = "尚無可信發佈套件"
    static let environmentStatus = "尚未驗證"
    static let installedStatus = "沒有已安裝紀錄"
    static let installedExplanation = "目前沒有可驗證的 Pocket 插件安裝紀錄。"
    static let environmentExplanation = "尚未偵測裝置、系統版本或越獄狀態。"
    static let installationAvailable = false
    static let publishedRelease: PocketPublishedReleasePresentation? = nil

    static func plugins(in category: PocketCategory) -> [PocketPlugin] {
        PocketPlugin.allCases.filter { $0.category == category }
    }
}

/// Display fields only, never evidence of verification or authorization.
/// Absent until a real release exists; catalogue identity is not release metadata.
struct PocketPublishedReleasePresentation: Equatable, Sendable {
    let pluginID: String
    let version: String
    let sourceRevision: String
    let environment: PocketCategory
    let compatibility: [PocketCompatibilityPresentation]
    let packageLocation: String
    let packageHash: String
    let signature: String
}

/// One exact hardware/build/capability tuple, not independently combinable lists.
/// A display entry does not grant device authority or assert runtime compatibility.
struct PocketCompatibilityPresentation: Equatable, Sendable {
    let hardwareModel: String
    let osBuild: String
    let requiredCapabilities: [String]
}
