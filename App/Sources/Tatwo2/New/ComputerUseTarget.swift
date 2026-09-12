import AppKit

/// An explicit, consented application identity; never a desktop-wide grant.
struct ComputerUseTarget: Equatable, Sendable {
    let bundleIdentifier: String

    static let deniedIdentifiers: Set<String> = [
        "com.apple.keychainaccess", "com.apple.passwords", "com.1password.1password",
        "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.systempreferences",
        "com.apple.securityagent"
    ]

    static func requested(_ value: Any?, ownIdentifier: String? = Bundle.main.bundleIdentifier) throws -> Self {
        guard let id = value as? String, !id.isEmpty, id.utf8.count <= 255,
              id.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil else {
            throw ComputerUseFailure("computer_invalid_bundle_identifier")
        }
        let normalized = id.lowercased()
        guard !normalized.hasPrefix("ai.tatwo.tatwo2"), normalized != ownIdentifier?.lowercased(),
              !deniedIdentifiers.contains(normalized) else {
            throw ComputerUseFailure("computer_target_denied")
        }
        return Self(bundleIdentifier: id)
    }

    func resolve() throws -> (url: URL, name: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
              let bundle = Bundle(url: url), bundle.bundleIdentifier == bundleIdentifier else {
            throw ComputerUseFailure("computer_target_unavailable")
        }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return (url, name)
    }

    static let consentDetail = "此聊天的模型會看到這個 App 的視窗畫面與文字，並可點擊、輸入、按鍵、捲動與拖曳。付款、對外發送、刪除資料或更改帳號安全設定前，模型必須先在聊天中詢問你。授權最多 15 分鐘；按停止、切換聊天或你自己動鍵盤滑鼠即撤回。"
}

/// Controller-local, ephemeral cache. An epoch mismatch (including a synchronous
/// input-monitor revocation) invalidates reuse before MainActor cleanup runs.
struct ComputerUseConsentCache {
    let owner: UUID
    let scope: String
    var epoch: UInt64
    let expiresAt: TimeInterval
    var apps: Set<String> = []

    func isCurrent(owner: UUID, scope: String, epoch: UInt64, now: TimeInterval) -> Bool {
        self.owner == owner && self.scope == scope && self.epoch == epoch && now < expiresAt
    }
    func permits(_ app: String, owner: UUID, scope: String, epoch: UInt64, now: TimeInterval) -> Bool {
        isCurrent(owner: owner, scope: scope, epoch: epoch, now: now) && apps.contains(app)
    }
}
