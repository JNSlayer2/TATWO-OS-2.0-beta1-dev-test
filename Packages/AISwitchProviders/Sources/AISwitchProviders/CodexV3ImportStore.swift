import Darwin
import Foundation
import AISwitchCore

public struct CodexV3AccountSnapshot: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let email: String
    public let maskedEmail: String
    public let plan: String
    public let isActive: Bool
    public let requiresRelogin: Bool
    public let v3RequiresRelogin: Bool
    public let thresholdOverridePercent: Int?
    public let effectiveThresholdPercent: Int
    public let remainingPercent: Int?
    public let primaryRemainingPercent: Int?
    public let secondaryRemainingPercent: Int?
    public let primaryResetsAt: Int?
    public let secondaryResetsAt: Int?
    public let rateLimitResetCreditsAvailableCount: Int?
    public let rateLimitResetCreditsExpiresAt: Int?
    public let rateLimitResetCreditsExpiryEpochs: [Int]?
    public let eligibleForAutoswitch: Bool
    public let lastUsageMessage: String?
    public let authImported: Bool

    public init(
        id: String,
        email: String = "",
        maskedEmail: String,
        plan: String,
        isActive: Bool,
        requiresRelogin: Bool,
        v3RequiresRelogin: Bool = false,
        thresholdOverridePercent: Int?,
        effectiveThresholdPercent: Int,
        remainingPercent: Int?,
        primaryRemainingPercent: Int? = nil,
        secondaryRemainingPercent: Int? = nil,
        primaryResetsAt: Int? = nil,
        secondaryResetsAt: Int? = nil,
        rateLimitResetCreditsAvailableCount: Int? = nil,
        rateLimitResetCreditsExpiresAt: Int? = nil,
        rateLimitResetCreditsExpiryEpochs: [Int]? = [],
        eligibleForAutoswitch: Bool,
        lastUsageMessage: String?,
        authImported: Bool
    ) {
        self.id = id
        self.email = email
        self.maskedEmail = maskedEmail
        self.plan = plan
        self.isActive = isActive
        self.requiresRelogin = requiresRelogin
        self.v3RequiresRelogin = v3RequiresRelogin
        self.thresholdOverridePercent = thresholdOverridePercent
        self.effectiveThresholdPercent = effectiveThresholdPercent
        self.remainingPercent = remainingPercent
        self.primaryRemainingPercent = primaryRemainingPercent
        self.secondaryRemainingPercent = secondaryRemainingPercent
        self.primaryResetsAt = primaryResetsAt
        self.secondaryResetsAt = secondaryResetsAt
        self.rateLimitResetCreditsAvailableCount = rateLimitResetCreditsAvailableCount
        self.rateLimitResetCreditsExpiresAt = rateLimitResetCreditsExpiresAt
        self.rateLimitResetCreditsExpiryEpochs = rateLimitResetCreditsExpiryEpochs
        self.eligibleForAutoswitch = eligibleForAutoswitch
        self.lastUsageMessage = lastUsageMessage
        self.authImported = authImported
    }
}

public struct CodexV3SettingsSnapshot: Codable, Sendable, Equatable {
    public let autoSwitchEnabled: Bool
    public let defaultThresholdPercent: Int
    public let monitorIntervalSeconds: Int
    public let batchReloginMode: String

    public init(
        autoSwitchEnabled: Bool,
        defaultThresholdPercent: Int,
        monitorIntervalSeconds: Int,
        batchReloginMode: String
    ) {
        self.autoSwitchEnabled = autoSwitchEnabled
        self.defaultThresholdPercent = defaultThresholdPercent
        self.monitorIntervalSeconds = monitorIntervalSeconds
        self.batchReloginMode = batchReloginMode
    }
}

public struct CodexV3Snapshot: Codable, Sendable, Equatable {
    public let importedAt: Date?
    public let accountCount: Int
    public let importedAuthCount: Int
    public let settings: CodexV3SettingsSnapshot
    public let accounts: [CodexV3AccountSnapshot]

    public init(
        importedAt: Date?,
        accountCount: Int,
        importedAuthCount: Int,
        settings: CodexV3SettingsSnapshot,
        accounts: [CodexV3AccountSnapshot]
    ) {
        self.importedAt = importedAt
        self.accountCount = accountCount
        self.importedAuthCount = importedAuthCount
        self.settings = settings
        self.accounts = accounts
    }
}

public struct CodexV3ImportSummary: Codable, Sendable, Equatable {
    public let accountCount: Int
    public let copiedAuthCount: Int
    public let importedAt: Date
    public let destination: String

    enum CodingKeys: String, CodingKey {
        case accountCount = "account_count"
        case copiedAuthCount = "copied_auth_count"
        case importedAt = "imported_at"
        case destination
    }
}

public struct CodexV4OperationResult: Codable, Sendable, Equatable {
    public let ok: Bool
    public let message: String
    public let email: String?
}

public struct CodexV4AutoSwitchResult: Codable, Sendable, Equatable {
    public let switched: Bool
    public let reason: String
    public let fromEmail: String?
    public let toEmail: String?
    public let warning: String?

    enum CodingKeys: String, CodingKey {
        case switched
        case reason
        case fromEmail = "from_email"
        case toEmail = "to_email"
        case warning
    }
}

public struct CodexV3ImportStore: Sendable {
    private let v3BaseURL: URL
    private let v4BaseURL: URL
    private let codexHomeURL: URL
    private let preferCodexHomeAuth: Bool

    public init(
        v3BaseURL: URL? = nil,
        v4BaseURL: URL? = nil,
        codexHomeURL: URL? = nil,
        preferCodexHomeAuth: Bool = true
    ) {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        self.v3BaseURL = v3BaseURL ?? Self.defaultV3BaseURL(homeURL: homeURL)
        self.v4BaseURL = v4BaseURL ?? homeURL
            .appendingPathComponent(".aiswitch-v4", isDirectory: true)
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("codex-v3", isDirectory: true)
        self.codexHomeURL = codexHomeURL ?? homeURL.appendingPathComponent(".codex", isDirectory: true)
        self.preferCodexHomeAuth = preferCodexHomeAuth
    }

    static func defaultV3BaseURL(homeURL: URL) -> URL {
        let current = homeURL.appendingPathComponent(".codex-v3", isDirectory: true)
        let manager = FileManager.default
        if manager.fileExists(atPath: current.appendingPathComponent("registry.json").path) {
            return current
        }
        // Legacy product directories had a per-owner suffix. Discover the directory
        // name locally; never embed an owner's identity or guess among multiple stores.
        let candidates = ((try? manager.contentsOfDirectory(
            at: homeURL, includingPropertiesForKeys: nil)) ?? []).filter {
                $0.lastPathComponent.hasPrefix(".jns")
                    && manager.fileExists(atPath: $0.appendingPathComponent("registry.json").path)
                    && manager.fileExists(atPath: $0.appendingPathComponent("accounts").path)
            }
        return candidates.count == 1 ? candidates[0] : current
    }

    public var importedRegistryURL: URL {
        v4BaseURL.appendingPathComponent("registry.json")
    }

    public func addAccount() async throws -> CodexV4OperationResult {
        let tempHome = try makeIsolatedHome()
        defer { try? FileManager.default.removeItem(at: tempHome) }

        try await runCodexLogin(codeHome: tempHome)

        let authURL = tempHome.appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: authURL.path) else {
            throw AISwitchError.storage("codex login 沒有建立 auth.json")
        }

        let auth = try parseAuth(Data(contentsOf: authURL))
        var identity = try extractIdentity(from: auth)
        if let enriched = try? await enrich(identity: identity, auth: auth) {
            identity = enriched
        }

        try saveStoredAuth(email: identity.email, auth: auth)
        var registry = try loadRegistryOrCreate()
        upsert(account: identity, registry: &registry)
        try saveRegistry(registry)

        let metadata = ImportMetadata(
            importedAt: Date(),
            accountCount: registry.accounts.count,
            copiedAuthCount: registry.accounts.filter { FileManager.default.fileExists(atPath: self.authURL(for: $0.email).path) }.count
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try write(data: try encoder.encode(metadata), to: metadataURL, permissions: 0o600)

        return CodexV4OperationResult(
            ok: true,
            message: "已新增 Codex 帳號：\(Self.maskEmail(identity.email))",
            email: identity.email
        )
    }

    public func importFromV3() throws -> CodexV3ImportSummary {
        let v3Registry = try loadRegistry(from: v3BaseURL.appendingPathComponent("registry.json"))
        let existingV4Registry = try? loadV4Registry()
        let registry = sanitizedV4Registry(fromV3Registry: v3Registry, existingV4Registry: existingV4Registry)
        try ensureDirectory(v4BaseURL, permissions: 0o700)
        try ensureDirectory(importedAccountsURL, permissions: 0o700)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try write(data: try encoder.encode(registry), to: importedRegistryURL, permissions: 0o600)

        var copiedAuthCount = 0
        for account in registry.accounts {
            let sourceAuthURL = v3BaseURL
                .appendingPathComponent("accounts", isDirectory: true)
                .appendingPathComponent(account.email, isDirectory: true)
                .appendingPathComponent("auth.json")
            guard FileManager.default.fileExists(atPath: sourceAuthURL.path) else { continue }

            let accountURL = importedAccountsURL.appendingPathComponent(account.email, isDirectory: true)
            try ensureDirectory(accountURL, permissions: 0o700)
            let targetAuthURL = accountURL.appendingPathComponent("auth.json")
            try write(data: try Data(contentsOf: sourceAuthURL), to: targetAuthURL, permissions: 0o600)
            copiedAuthCount += 1
        }

        let importedAt = Date()
        let metadata = ImportMetadata(importedAt: importedAt, accountCount: registry.accounts.count, copiedAuthCount: copiedAuthCount)
        try write(data: try encoder.encode(metadata), to: metadataURL, permissions: 0o600)

        return CodexV3ImportSummary(
            accountCount: registry.accounts.count,
            copiedAuthCount: copiedAuthCount,
            importedAt: importedAt,
            destination: "~/.aiswitch-v4/providers/codex-v3"
        )
    }

    public func loadSnapshot(resolveActiveEmail: Bool = false) throws -> CodexV3Snapshot {
        let registry = try loadV4Registry()
        let metadata = try? loadMetadata()
        let activeEmail = resolveActiveEmail ? (importedActiveEmail() ?? registry.activeEmail) : registry.activeEmail
        return makeSnapshot(registry: registry, metadata: metadata, activeEmail: activeEmail, usageByEmail: [:])
    }

    public func loadLiveSnapshot(resolveActiveEmail: Bool = false) async throws -> CodexV3Snapshot {
        let registry = try loadV4Registry()
        let metadata = try? loadMetadata()
        let activeEmail = resolveActiveEmail ? (importedActiveEmail() ?? registry.activeEmail) : registry.activeEmail
        let usageByEmail = await liveUsageByEmail(for: registry.accounts, activeEmail: activeEmail)
        return makeSnapshot(registry: registry, metadata: metadata, activeEmail: activeEmail, usageByEmail: usageByEmail)
    }

    public func updateSettings(
        autoSwitchEnabled: Bool? = nil,
        defaultThresholdPercent: Int? = nil,
        monitorIntervalSeconds: Int? = nil,
        batchReloginMode: String? = nil,
        accountID: String? = nil,
        thresholdOverridePercent: Int? = nil,
        clearThresholdOverride: Bool = false
    ) throws -> CodexV3SettingsSnapshot {
        var registry = try loadV4Registry()

        if let autoSwitchEnabled {
            registry.settings.autoSwitchEnabled = autoSwitchEnabled
        }
        if let defaultThresholdPercent {
            registry.settings.defaultThresholdPercent = normalizeThreshold(defaultThresholdPercent)
        }
        if let monitorIntervalSeconds {
            registry.settings.monitorIntervalSeconds = max(monitorIntervalSeconds, 15)
        }
        if let batchReloginMode {
            registry.settings.batchReloginMode = ["inplace", "recreate"].contains(batchReloginMode) ? batchReloginMode : "inplace"
        }
        if let accountID,
           let index = registry.accounts.firstIndex(where: { $0.id == accountID || $0.email.caseInsensitiveCompare(accountID) == .orderedSame }) {
            if clearThresholdOverride {
                registry.accounts[index].thresholdOverridePercent = nil
            } else if let thresholdOverridePercent {
                registry.accounts[index].thresholdOverridePercent = normalizeThreshold(thresholdOverridePercent)
            }
        }

        try saveRegistry(registry)
        return CodexV3SettingsSnapshot(
            autoSwitchEnabled: registry.settings.autoSwitchEnabled,
            defaultThresholdPercent: registry.settings.defaultThresholdPercent,
            monitorIntervalSeconds: registry.settings.monitorIntervalSeconds,
            batchReloginMode: registry.settings.batchReloginMode
        )
    }

    public func removeAccount(idOrEmail: String) throws -> CodexV4OperationResult {
        var registry = try loadV4Registry()
        guard let index = registry.accounts.firstIndex(where: { $0.id == idOrEmail || $0.email.caseInsensitiveCompare(idOrEmail) == .orderedSame }) else {
            throw AISwitchError.storage("找不到 Codex 帳號")
        }

        let account = registry.accounts.remove(at: index)
        if registry.activeEmail?.caseInsensitiveCompare(account.email) == .orderedSame {
            registry.activeEmail = nil
        }
        try saveRegistry(registry)

        let accountURL = importedAccountsURL.appendingPathComponent(account.email, isDirectory: true)
        if FileManager.default.fileExists(atPath: accountURL.path) {
            try FileManager.default.removeItem(at: accountURL)
        }

        return CodexV4OperationResult(ok: true, message: "已從 AI Switch v4 移除 Codex 帳號", email: account.email)
    }

    public func switchAccount(email: String) throws -> CodexV4OperationResult {
        var registry = try loadV4Registry()
        guard let account = registry.accounts.first(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame }) else {
            throw AISwitchError.storage("找不到 Codex 帳號")
        }

        let sourceAuthURL = authURL(for: account.email)
        guard FileManager.default.fileExists(atPath: sourceAuthURL.path) else {
            throw AISwitchError.storage("此 Codex 帳號沒有可用 auth.json")
        }

        let targetAuthURL = codexHomeURL.appendingPathComponent("auth.json")
        try guardCodexHostMutationAllowed(targetAuthURL: targetAuthURL)
        try backupExistingFileIfPresent(targetAuthURL)
        try write(data: try Data(contentsOf: sourceAuthURL), to: targetAuthURL, permissions: 0o600)
        registry.activeEmail = account.email
        try saveRegistry(registry)

        return CodexV4OperationResult(ok: true, message: "已切換目前 Codex CLI auth", email: account.email)
    }

    public func runAutoSwitch() async throws -> CodexV4AutoSwitchResult {
        let snapshot = try await loadLiveSnapshot()
        let active = snapshot.accounts.first(where: \.isActive)
        let reason: String

        if let active {
            if active.requiresRelogin {
                reason = "relogin_required"
            } else if let remaining = active.remainingPercent, remaining <= active.effectiveThresholdPercent {
                reason = "below_threshold"
            } else {
                return CodexV4AutoSwitchResult(
                    switched: false,
                    reason: "healthy",
                    fromEmail: active.email,
                    toEmail: nil,
                    warning: "目前 Codex 帳號仍高於自動切換門檻"
                )
            }
        } else {
            reason = "no_active_account"
        }

        let candidates = snapshot.accounts
            .filter { account in
                !account.isActive
                    && !account.requiresRelogin
                    && account.authImported
                    && account.remainingPercent != nil
            }
            .sorted { lhs, rhs in
                (lhs.remainingPercent ?? -1) > (rhs.remainingPercent ?? -1)
            }

        guard let selected = candidates.first else {
            return CodexV4AutoSwitchResult(
                switched: false,
                reason: reason,
                fromEmail: active?.email,
                toEmail: nil,
                warning: "沒有可用的 Codex 自動切換候選帳號"
            )
        }

        _ = try switchAccount(email: selected.email)
        return CodexV4AutoSwitchResult(
            switched: true,
            reason: reason,
            fromEmail: active?.email,
            toEmail: selected.email,
            warning: nil
        )
    }

    private func makeSnapshot(
        registry: ImportedRegistry,
        metadata: ImportMetadata?,
        activeEmail: String?,
        usageByEmail: [String: LiveUsageOutcome]
    ) -> CodexV3Snapshot {
        let accounts = registry.accounts.map { account in
            let authImported = FileManager.default.fileExists(atPath: authURL(for: account.email).path)
            let effectiveThreshold = account.thresholdOverridePercent ?? registry.settings.defaultThresholdPercent
            let liveUsage = usageByEmail[account.email]
            // v3 的 requires_relogin / last_usage_message 都是 runtime 快取，
            // 不可帶進 v4；v4 只相信本次 live check 與可讀 auth presence。
            // 當 active Codex App/CLI auth 與 v4 匯入 auth 不同步時，liveUsage
            // 可能來自 ~/.codex/auth.json；這仍是只讀 live evidence，不寫回 v4。
            let authAvailable = authImported || liveUsage != nil
            let requiresRelogin = !authAvailable || (liveUsage?.requiresRelogin ?? false)
            return CodexV3AccountSnapshot(
                id: account.id,
                email: account.email,
                maskedEmail: Self.maskEmail(account.email),
                plan: (liveUsage?.planType ?? account.plan).uppercased(),
                isActive: activeEmail?.caseInsensitiveCompare(account.email) == .orderedSame,
                requiresRelogin: requiresRelogin,
                v3RequiresRelogin: false,
                thresholdOverridePercent: account.thresholdOverridePercent,
                effectiveThresholdPercent: effectiveThreshold,
                remainingPercent: liveUsage?.remainingPercent,
                primaryRemainingPercent: liveUsage?.primaryRemainingPercent,
                secondaryRemainingPercent: liveUsage?.secondaryRemainingPercent,
                primaryResetsAt: liveUsage?.primaryResetsAt,
                secondaryResetsAt: liveUsage?.secondaryResetsAt,
                rateLimitResetCreditsAvailableCount: liveUsage?.rateLimitResetCreditsAvailableCount,
                rateLimitResetCreditsExpiresAt: liveUsage?.rateLimitResetCreditsExpiresAt,
                rateLimitResetCreditsExpiryEpochs: liveUsage?.rateLimitResetCreditsExpiryEpochs ?? [],
                eligibleForAutoswitch: authImported,
                lastUsageMessage: liveUsage?.usageError ?? (!authImported ? "找不到此帳號的驗證資料" : nil),
                authImported: authImported
            )
        }

        return CodexV3Snapshot(
            importedAt: metadata?.importedAt,
            accountCount: registry.accounts.count,
            importedAuthCount: metadata?.copiedAuthCount ?? accounts.filter(\.authImported).count,
            settings: CodexV3SettingsSnapshot(
                autoSwitchEnabled: registry.settings.autoSwitchEnabled,
                defaultThresholdPercent: registry.settings.defaultThresholdPercent,
                monitorIntervalSeconds: registry.settings.monitorIntervalSeconds,
                batchReloginMode: registry.settings.batchReloginMode
            ),
            accounts: accounts
        )
    }

    public static func maskEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "********" }
        let local = parts[0]
        let domain = parts[1]
        let visibleLocal = local.prefix(min(2, local.count))
        let domainParts = domain.split(separator: ".", maxSplits: 1).map(String.init)
        let visibleDomain = domainParts.first?.prefix(1) ?? ""
        let suffix = domainParts.count > 1 ? ".\(domainParts[1])" : ""
        return "\(visibleLocal)********@\(visibleDomain)****\(suffix)"
    }

    private var importedAccountsURL: URL {
        v4BaseURL.appendingPathComponent("accounts", isDirectory: true)
    }

    private var metadataURL: URL {
        v4BaseURL.appendingPathComponent("import-metadata.json")
    }

    private func authURL(for email: String) -> URL {
        importedAccountsURL
            .appendingPathComponent(email, isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    private func importedActiveEmail() -> String? {
        guard preferCodexHomeAuth else {
            return nil
        }
        guard let data = try? Data(contentsOf: codexHomeURL.appendingPathComponent("auth.json")) else {
            return nil
        }
        return (try? parseAuth(data).email)
    }

    private func liveUsageByEmail(for accounts: [ImportedAccount], activeEmail: String? = nil) async -> [String: LiveUsageOutcome] {
        await withTaskGroup(of: (String, LiveUsageOutcome)?.self) { group in
            for account in accounts {
                let authURL = liveAuthURL(for: account, activeEmail: activeEmail)
                guard FileManager.default.fileExists(atPath: authURL.path) else {
                    continue
                }

                group.addTask {
                    do {
                        let auth = try parseAuth(Data(contentsOf: authURL))
                        let usage = try await CodexUsageClient().queryUsage(auth: auth)
                        let remainingPercent = Self.remainingPercent(for: usage)
                        let primaryRemainingPercent = Self.remainingPercent(for: usage.primary)
                        let secondaryRemainingPercent = Self.remainingPercent(for: usage.secondary)
                        let usageError = remainingPercent == nil
                            ? "已讀取訂閱狀態，但服務端未回傳額度資料"
                            : nil
                        return (
                            account.email,
                            LiveUsageOutcome(
                                remainingPercent: remainingPercent,
                                primaryRemainingPercent: primaryRemainingPercent,
                                secondaryRemainingPercent: secondaryRemainingPercent,
                                primaryResetsAt: usage.primary?.resetsAt,
                                secondaryResetsAt: usage.secondary?.resetsAt,
                                rateLimitResetCreditsAvailableCount: usage.rateLimitResetCreditsAvailableCount,
                                rateLimitResetCreditsExpiresAt: usage.rateLimitResetCreditsExpiresAt,
                                rateLimitResetCreditsExpiryEpochs: usage.rateLimitResetCreditsExpiryEpochs,
                                usageError: usageError,
                                requiresRelogin: false,
                                planType: usage.planType
                            )
                        )
                    } catch {
                        let friendly = Self.friendlyUsageErrorMessage(from: error)
                        return (
                            account.email,
                            LiveUsageOutcome(
                                remainingPercent: nil,
                                primaryRemainingPercent: nil,
                                secondaryRemainingPercent: nil,
                                primaryResetsAt: nil,
                                secondaryResetsAt: nil,
                                rateLimitResetCreditsAvailableCount: nil,
                                rateLimitResetCreditsExpiresAt: nil,
                                rateLimitResetCreditsExpiryEpochs: [],
                                usageError: friendly.message,
                                requiresRelogin: friendly.requiresRelogin,
                                planType: nil
                            )
                        )
                    }
                }
            }

            var results = [String: LiveUsageOutcome]()
            for await result in group {
                guard let (email, outcome) = result else { continue }
                results[email] = outcome
            }
            return results
        }
    }

    private func liveAuthURL(for account: ImportedAccount, activeEmail: String?) -> URL {
        guard preferCodexHomeAuth else {
            return authURL(for: account.email)
        }
        let currentAuthURL = codexHomeURL.appendingPathComponent("auth.json")
        if let activeEmail,
           activeEmail.caseInsensitiveCompare(account.email) == .orderedSame,
           FileManager.default.fileExists(atPath: currentAuthURL.path) {
            return currentAuthURL
        }
        return authURL(for: account.email)
    }

    private func loadRegistry(from url: URL) throws -> ImportedRegistry {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AISwitchError.providerNotConfigured("codex")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ImportedRegistry.self, from: try Data(contentsOf: url))
    }

    private func loadV4Registry() throws -> ImportedRegistry {
        let registry = try loadRegistry(from: importedRegistryURL)
        let normalized = normalizedV4Registry(registry)
        if registry.version < 4 || registryContainsLegacyRuntimeState(registry) {
            try saveRegistry(normalized)
        }
        return normalized
    }

    private func loadRegistryOrCreate() throws -> ImportedRegistry {
        guard FileManager.default.fileExists(atPath: importedRegistryURL.path) else {
            try ensureDirectory(v4BaseURL, permissions: 0o700)
            try ensureDirectory(importedAccountsURL, permissions: 0o700)
            return ImportedRegistry(version: 4, accounts: [])
        }
        return try loadV4Registry()
    }

    private func sanitizedV4Registry(fromV3Registry v3Registry: ImportedRegistry, existingV4Registry: ImportedRegistry?) -> ImportedRegistry {
        let existing = existingV4Registry.map(normalizedV4Registry)
        let existingByEmail = Dictionary(
            uniqueKeysWithValues: (existing?.accounts ?? []).map { ($0.email.lowercased(), $0) }
        )
        let importedEmails = Set(v3Registry.accounts.map { $0.email.lowercased() })
        let activeEmail = existing?.activeEmail.flatMap { importedEmails.contains($0.lowercased()) ? $0 : nil }

        let accounts = v3Registry.accounts.map { account in
            let prior = existingByEmail[account.email.lowercased()]
            return ImportedAccount(
                id: prior?.id ?? account.email,
                email: account.email,
                plan: account.plan,
                accountID: account.accountID,
                thresholdOverridePercent: prior?.thresholdOverridePercent,
                requiresRelogin: false,
                lastUsageMessage: nil
            )
        }

        return ImportedRegistry(
            version: 4,
            accounts: accounts,
            settings: existing?.settings ?? ImportedSettings(),
            activeEmail: activeEmail
        )
    }

    private func normalizedV4Registry(_ registry: ImportedRegistry) -> ImportedRegistry {
        var normalized = registry
        normalized.version = max(registry.version, 4)

        if registry.version < 4 {
            // v3 import files carried operational settings from Codex Switch.
            // AI Switch v4 owns these values independently, so legacy files are reset once.
            normalized.settings = ImportedSettings()
            normalized.accounts = normalized.accounts.map { account in
                var clean = account
                clean.id = account.email
                clean.thresholdOverridePercent = nil
                clean.requiresRelogin = false
                clean.lastUsageMessage = nil
                return clean
            }
            if let activeEmail = normalized.activeEmail,
               !normalized.accounts.contains(where: { $0.email.caseInsensitiveCompare(activeEmail) == .orderedSame }) {
                normalized.activeEmail = nil
            }
            return normalized
        }

        normalized.accounts = normalized.accounts.map { account in
            var clean = account
            clean.requiresRelogin = false
            clean.lastUsageMessage = nil
            return clean
        }
        return normalized
    }

    private func registryContainsLegacyRuntimeState(_ registry: ImportedRegistry) -> Bool {
        registry.accounts.contains { $0.requiresRelogin || $0.lastUsageMessage != nil }
    }

    private func saveRegistry(_ registry: ImportedRegistry) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try write(data: try encoder.encode(registry), to: importedRegistryURL, permissions: 0o600)
    }

    private func loadMetadata() throws -> ImportMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ImportMetadata.self, from: try Data(contentsOf: metadataURL))
    }

    private static func remainingPercent(for usage: CodexUsageRateLimits?) -> Int? {
        [usage?.primary, usage?.secondary]
            .compactMap { $0?.usedPercent }
            .map { min(max(100 - $0, 0), 100) }
            .min()
    }

    private static func remainingPercent(for window: CodexUsageWindow?) -> Int? {
        guard let used = window?.usedPercent else { return nil }
        return min(max(100 - used, 0), 100)
    }

    private func normalizeThreshold(_ value: Int) -> Int {
        min(max(value, 1), 100)
    }

    private static func friendlyUsageErrorMessage(from error: Error) -> (message: String, requiresRelogin: Bool) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let normalized = message.lowercased()

        if normalized.contains("token_expired")
            || normalized.contains("provided authentication token is expired")
            || normalized.contains("http 401")
            || normalized.contains("re-login")
            || normalized.contains("relogin") {
            return ("此帳號需要重新登入，才能讀取用量資料", true)
        }

        if normalized.contains("timed out")
            || normalized.contains("timeout")
            || normalized.contains("not connected")
            || normalized.contains("network") {
            return ("暫時無法讀取用量資料，請稍後再試", false)
        }

        return ("讀取用量資料失敗", false)
    }

    private func ensureDirectory(_ url: URL, permissions: Int16) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
    }

    private func write(data: Data, to url: URL, permissions: Int16) throws {
        let parent = url.deletingLastPathComponent()
        try ensureDirectory(parent, permissions: 0o700)
        let tmpURL = parent.appendingPathComponent(".\(url.lastPathComponent).tmp")
        if FileManager.default.fileExists(atPath: tmpURL.path) {
            try FileManager.default.removeItem(at: tmpURL)
        }
        try data.write(to: tmpURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: tmpURL.path)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmpURL, to: url)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
    }

    private func backupExistingFileIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let parent = url.deletingLastPathComponent()
        let preferred = parent.appendingPathComponent("\(url.lastPathComponent).bak")
        let backupURL: URL
        if FileManager.default.fileExists(atPath: preferred.path) {
            let stamp = ISO8601DateFormatter()
                .string(from: Date())
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: ".", with: "")
            backupURL = parent.appendingPathComponent("\(url.lastPathComponent).\(stamp).bak")
        } else {
            backupURL = preferred
        }
        try FileManager.default.copyItem(at: url, to: backupURL)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: backupURL.path)
    }

    private func guardCodexHostMutationAllowed(targetAuthURL: URL) throws {
        guard isDefaultCodexAuthURL(targetAuthURL) else { return }
        if ProcessInfo.processInfo.environment["AISWITCH_ALLOW_CODEX_HOST_MUTATION"] == "1" {
            return
        }
        guard isLikelyCodexProcessRunning() else { return }
        throw AISwitchError.storage("Codex 似乎正在執行；為避免 auth.json refresh 競爭，請先關閉 Codex/App server，或明確設定 AISWITCH_ALLOW_CODEX_HOST_MUTATION=1 後再切換")
    }

    private func isDefaultCodexAuthURL(_ url: URL) -> Bool {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let defaultURL = home.appendingPathComponent(".codex/auth.json").standardizedFileURL.path
        return url.standardizedFileURL.path == defaultURL
    }

    private func isLikelyCodexProcessRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "codex (app-server|remote-control|exec|app-server proxy)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func saveStoredAuth(email: String, auth: CodexStoredAuth) throws {
        let accountURL = importedAccountsURL.appendingPathComponent(email, isDirectory: true)
        try ensureDirectory(accountURL, permissions: 0o700)
        try write(data: auth.rawData, to: accountURL.appendingPathComponent("auth.json"), permissions: 0o600)
    }

    private func upsert(account identity: CodexAccountIdentity, registry: inout ImportedRegistry) {
        let next = ImportedAccount(
            id: identity.email,
            email: identity.email,
            plan: identity.plan,
            accountID: identity.accountID,
            thresholdOverridePercent: registry.accounts.first(where: { $0.email.caseInsensitiveCompare(identity.email) == .orderedSame })?.thresholdOverridePercent,
            requiresRelogin: false,
            lastUsageMessage: nil
        )

        if let index = registry.accounts.firstIndex(where: { $0.email.caseInsensitiveCompare(identity.email) == .orderedSame }) {
            registry.accounts[index] = next
        } else {
            registry.accounts.append(next)
        }
    }

    private func enrich(identity: CodexAccountIdentity, auth: CodexStoredAuth) async throws -> CodexAccountIdentity {
        let usage = try await CodexUsageClient().queryUsage(auth: auth)
        var result = identity
        if let plan = usage.planType, !plan.isEmpty {
            result.plan = plan
        }
        return result
    }

    private func makeIsolatedHome() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let temp = base.appendingPathComponent("aiswitch-codex-login-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: temp.path)
        return temp
    }

    private func runCodexLogin(codeHome: URL) async throws {
        let process = Process()
        process.executableURL = try codexExecutableURL()
        process.arguments = ["login"]
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = codeHome.path
        env["PATH"] = codexSearchPaths().joined(separator: ":")
        process.environment = env
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.run()
        } catch {
            throw AISwitchError.storage("執行 codex login 失敗：\(error.localizedDescription)")
        }

        let startedAt = Date()
        while process.isRunning {
            if Date().timeIntervalSince(startedAt) >= 60 {
                let pid = process.processIdentifier
                process.terminate()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if process.isRunning {
                    kill(pid, SIGKILL)
                }
                throw AISwitchError.storage("登入逾時，60 秒內未完成。")
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        guard process.terminationStatus == 0 else {
            throw AISwitchError.storage("執行 codex login 失敗")
        }
    }

    private func codexExecutableURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["AISWITCH_CODEX"], FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        if let override = ProcessInfo.processInfo.environment["JNSLAYER2_CODEX"], FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        for path in codexExecutableCandidates() where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        throw AISwitchError.storage("找不到 Codex CLI，請先安裝官方 Codex app")
    }

    private func codexExecutableCandidates() -> [String] {
        var candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ]
        if let resolved = try? shellWhich("codex"), !resolved.isEmpty {
            candidates.append(resolved)
        }
        return Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
    }

    private func codexSearchPaths() -> [String] {
        var paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let current = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        paths.append(contentsOf: current)
        return Array(NSOrderedSet(array: paths)) as? [String] ?? paths
    }

    private func shellWhich(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private struct ImportedRegistry: Codable, Sendable {
    var version: Int
    var accounts: [ImportedAccount]
    var settings: ImportedSettings
    var activeEmail: String?

    init(version: Int = 3, accounts: [ImportedAccount], settings: ImportedSettings = ImportedSettings(), activeEmail: String? = nil) {
        self.version = version
        self.accounts = accounts
        self.settings = settings
        self.activeEmail = activeEmail
    }

    enum CodingKeys: String, CodingKey {
        case version
        case accounts
        case settings
        case activeEmail = "active_email"
    }
}

private struct ImportedAccount: Codable, Sendable {
    var id: String
    var email: String
    var plan: String
    var accountID: String
    var thresholdOverridePercent: Int?
    var requiresRelogin: Bool
    var lastUsageMessage: String?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case plan
        case accountID = "account_id"
        case thresholdOverridePercent = "threshold_override_percent"
        case requiresRelogin = "requires_relogin"
        case lastUsageMessage = "last_usage_message"
    }
}

private struct ImportedSettings: Codable, Sendable {
    var autoSwitchEnabled: Bool
    var defaultThresholdPercent: Int
    var monitorIntervalSeconds: Int
    var batchReloginMode: String

    init(
        autoSwitchEnabled: Bool = false,
        defaultThresholdPercent: Int = 4,
        monitorIntervalSeconds: Int = 60,
        batchReloginMode: String = "inplace"
    ) {
        self.autoSwitchEnabled = autoSwitchEnabled
        self.defaultThresholdPercent = defaultThresholdPercent
        self.monitorIntervalSeconds = monitorIntervalSeconds
        self.batchReloginMode = batchReloginMode
    }

    enum CodingKeys: String, CodingKey {
        case autoSwitchEnabled = "auto_switch_enabled"
        case defaultThresholdPercent = "default_threshold_percent"
        case monitorIntervalSeconds = "monitor_interval_seconds"
        case batchReloginMode = "batch_relogin_mode"
    }
}

private struct ImportMetadata: Codable, Sendable {
    var importedAt: Date
    var accountCount: Int
    var copiedAuthCount: Int

    enum CodingKeys: String, CodingKey {
        case importedAt = "imported_at"
        case accountCount = "account_count"
        case copiedAuthCount = "copied_auth_count"
    }
}

private struct LiveUsageOutcome: Sendable {
    var remainingPercent: Int?
    var primaryRemainingPercent: Int?
    var secondaryRemainingPercent: Int?
    var primaryResetsAt: Int?
    var secondaryResetsAt: Int?
    var rateLimitResetCreditsAvailableCount: Int?
    var rateLimitResetCreditsExpiresAt: Int?
    var rateLimitResetCreditsExpiryEpochs: [Int]
    var usageError: String?
    var requiresRelogin: Bool
    var planType: String?
}

private struct CodexAuthFile: Decodable, Sendable {
    var authMode: String?
    var openAIAPIKey: String?
    var tokens: CodexAuthTokens

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case openAIAPIKey = "OPENAI_API_KEY"
        case tokens
    }
}

private struct CodexAuthTokens: Decodable, Sendable {
    var accessToken: String?
    var accountID: String?
    var idToken: String?
    var refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accountID = "account_id"
        case idToken = "id_token"
        case refreshToken = "refresh_token"
    }
}

private struct CodexStoredAuth: Sendable {
    let rawData: Data
    let parsed: CodexAuthFile

    var email: String {
        get throws {
            if let idToken = parsed.tokens.idToken,
               let claims = try? decodeJWTClaims(idToken),
               let email = claims["email"] as? String,
               !email.isEmpty {
                return email
            }

            if let accessToken = parsed.tokens.accessToken,
               let claims = try? decodeJWTClaims(accessToken),
               let profile = claims["https://api.openai.com/profile"] as? [String: Any],
               let email = profile["email"] as? String,
               !email.isEmpty {
                return email
            }

            throw CodexV3ImportRuntimeError("目前的登入結果缺少電子郵件資訊")
        }
    }
}

private struct CodexAccountIdentity: Sendable {
    var email: String
    var plan: String
    var authMode: String
    var accountID: String
}

private struct CodexUsageRateLimits: Sendable {
    var primary: CodexUsageWindow?
    var secondary: CodexUsageWindow?
    var planType: String?
    var rateLimitResetCreditsAvailableCount: Int?
    var rateLimitResetCreditsExpiresAt: Int?
    var rateLimitResetCreditsExpiryEpochs: [Int]
}

private struct CodexUsageWindow: Sendable {
    var usedPercent: Int?
    var resetsAt: Int?
}

private struct CodexUsageAPIResponse: Decodable, Sendable {
    var planType: String?
    var rateLimit: CodexUsageLimit?
    var rateLimitResetCredits: CodexUsageResetCredits?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case rateLimitResetCredits = "rate_limit_reset_credits"
    }
}

private struct CodexUsageResetCredits: Decodable, Sendable {
    var availableCount: Int?
    var expiresAt: Int?

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
        case expiresAt = "expires_at"
        case expirationAt = "expiration_at"
        case validUntil = "valid_until"
        case resetAt = "reset_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availableCount = try container.decodeIfPresent(Int.self, forKey: .availableCount)
        expiresAt = try container.decodeIfPresent(Int.self, forKey: .expiresAt)
            ?? container.decodeIfPresent(Int.self, forKey: .expirationAt)
            ?? container.decodeIfPresent(Int.self, forKey: .validUntil)
            ?? container.decodeIfPresent(Int.self, forKey: .resetAt)
    }
}

private struct CodexUsageLimit: Decodable, Sendable {
    var primaryWindow: CodexUsageLimitWindow?
    var secondaryWindow: CodexUsageLimitWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexUsageLimitWindow: Decodable, Sendable {
    var usedPercent: Int?
    var resetAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
    }
}

private struct CodexResetCreditsAPIResponse: Decodable, Sendable {
    var credits: [CodexResetCredit]
    var availableCount: Int?

    enum CodingKeys: String, CodingKey {
        case credits
        case availableCount = "available_count"
    }

    var earliestAvailableExpiryEpoch: Int? {
        availableExpiryEpochs.first
    }

    var availableExpiryEpochs: [Int] {
        credits
            .filter { $0.status == "available" && $0.resetType == "codex_rate_limits" }
            .compactMap(\.expiresAtEpoch)
            .sorted()
    }

    var availableCodexResetCreditCount: Int? {
        let expiryCount = availableExpiryEpochs.count
        if expiryCount > 0 {
            return expiryCount
        }
        return availableCount
    }
}

private struct CodexResetCredit: Decodable, Sendable {
    var resetType: String?
    var status: String?
    var expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case resetType = "reset_type"
        case status
        case expiresAt = "expires_at"
    }

    var expiresAtEpoch: Int? {
        guard let expiresAt,
              let date = Self.parseExpiresAt(expiresAt)
        else { return nil }
        return Int(date.timeIntervalSince1970)
    }

    private static func parseExpiresAt(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: value)
    }
}

private final class CodexUsageClient: @unchecked Sendable {
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 8
        return URLSession(configuration: configuration)
    }()

    func queryUsage(auth: CodexStoredAuth) async throws -> CodexUsageRateLimits {
        guard let accessToken = auth.parsed.tokens.accessToken, !accessToken.isEmpty else {
            throw CodexV3ImportRuntimeError("auth.json 缺少 tokens.access_token")
        }
        guard let accountID = auth.parsed.tokens.accountID, !accountID.isEmpty else {
            throw CodexV3ImportRuntimeError("auth.json 缺少 tokens.account_id")
        }

        let payload = try await getJSON(
            CodexUsageAPIResponse.self,
            url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            accessToken: accessToken,
            accountID: accountID,
            errorPrefix: "查詢用量失敗"
        )
        let resetCredits = try? await getJSON(
            CodexResetCreditsAPIResponse.self,
            url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!,
            accessToken: accessToken,
            accountID: accountID,
            errorPrefix: "查詢累積重置失敗"
        )

        return CodexUsageRateLimits(
            primary: payload.rateLimit?.primaryWindow.map { CodexUsageWindow(usedPercent: $0.usedPercent, resetsAt: $0.resetAt) },
            secondary: payload.rateLimit?.secondaryWindow.map { CodexUsageWindow(usedPercent: $0.usedPercent, resetsAt: $0.resetAt) },
            planType: payload.planType,
            rateLimitResetCreditsAvailableCount: resetCredits?.availableCodexResetCreditCount ?? payload.rateLimitResetCredits?.availableCount,
            rateLimitResetCreditsExpiresAt: resetCredits?.earliestAvailableExpiryEpoch ?? payload.rateLimitResetCredits?.expiresAt,
            rateLimitResetCreditsExpiryEpochs: resetCredits?.availableExpiryEpochs ?? payload.rateLimitResetCredits?.expiresAt.map { [$0] } ?? []
        )
    }

    private func getJSON<T: Decodable>(
        _ type: T.Type,
        url: URL,
        accessToken: String,
        accountID: String,
        errorPrefix: String
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AI-Switch-v4/4.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 4

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CodexV3ImportRuntimeError("\(errorPrefix)：缺少 HTTP 回應")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CodexV3ImportRuntimeError("\(errorPrefix)：HTTP \(http.statusCode) \(body)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private struct CodexV3ImportRuntimeError: LocalizedError, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private func parseAuth(_ data: Data) throws -> CodexStoredAuth {
    let parsed = try JSONDecoder().decode(CodexAuthFile.self, from: data)
    return CodexStoredAuth(rawData: data, parsed: parsed)
}

private func extractIdentity(from auth: CodexStoredAuth) throws -> CodexAccountIdentity {
    let email = try auth.email
    let accountID: String
    if let existingAccountID = auth.parsed.tokens.accountID, !existingAccountID.isEmpty {
        accountID = existingAccountID
    } else {
        accountID = try extractAuthClaim(from: auth, key: "chatgpt_account_id")
    }
    let plan = (try? extractAuthClaim(from: auth, key: "chatgpt_plan_type")) ?? "free"
    let authMode = auth.parsed.authMode ?? (auth.parsed.openAIAPIKey?.isEmpty == false ? "api_key" : "chatgpt")
    return CodexAccountIdentity(email: email, plan: plan, authMode: authMode, accountID: accountID)
}

private func extractAuthClaim(from auth: CodexStoredAuth, key: String) throws -> String {
    let tokens = [auth.parsed.tokens.idToken, auth.parsed.tokens.accessToken].compactMap { $0 }
    for token in tokens {
        if let claims = try? decodeJWTClaims(token),
           let nested = claims["https://api.openai.com/auth"] as? [String: Any],
           let value = nested[key] as? String,
           !value.isEmpty {
            return value
        }
    }
    throw CodexV3ImportRuntimeError("auth.json 缺少 tokens.\(key)")
}

private func decodeJWTClaims(_ token: String) throws -> [String: Any] {
    let segments = token.split(separator: ".")
    guard segments.count >= 2 else {
        throw CodexV3ImportRuntimeError("JWT 格式不正確")
    }

    var payload = String(segments[1])
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let remainder = payload.count % 4
    if remainder > 0 {
        payload += String(repeating: "=", count: 4 - remainder)
    }

    guard let data = Data(base64Encoded: payload),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CodexV3ImportRuntimeError("JWT payload 無法解析")
    }
    return object
}
