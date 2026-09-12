import Foundation
import CryptoKit
import AISwitchCore

public struct CodexProvider: ProviderAdapter {
    public let provider = AIProvider(id: "codex", kind: .codex, displayName: "Codex", status: .ready, lastCheckedAt: Date())
    private let importStore: CodexV3ImportStore

    public init(importStore: CodexV3ImportStore = CodexV3ImportStore()) {
        self.importStore = importStore
    }

    public func accounts() async throws -> [AIAccount] {
        guard let snapshot = (try? await importStore.loadLiveSnapshot()) ?? (try? importStore.loadSnapshot()), !snapshot.accounts.isEmpty else {
            return [AIAccount(id: "codex-local", providerID: provider.id, maskedEmail: "本機 Codex", plan: "local", status: .ready, lastCheckedAt: Date())]
        }
        return snapshot.accounts.map { account in
            AIAccount(
                id: Self.publicAccountID(for: account.email),
                providerID: provider.id,
                maskedEmail: account.maskedEmail,
                plan: account.plan,
                status: account.requiresRelogin ? .requiresRelogin : .ready,
                lastCheckedAt: snapshot.importedAt
            )
        }
    }

    public func models() async throws -> [AIModel] {
        [
            AIModel(id: "gpt-5.4", providerID: provider.id, displayName: "GPT-5.4", isAvailable: true),
            AIModel(id: "gpt-5.4-mini", providerID: provider.id, displayName: "GPT-5.4 Mini", isAvailable: true),
            // TATWO routes are additive OS modes, not replacements for the
            // existing model list. They enter Work OS first; Dashboard identity
            // bindings decide the actual GPT / Claude / Grok / MiniMax split.
            AIModel(id: "tatwo-os-s", providerID: provider.id, displayName: "TATWO ULTRAWORK S", isAvailable: true),
            AIModel(id: "tatwo-os-m", providerID: provider.id, displayName: "TATWO ULTRAWORK M", isAvailable: true),
            AIModel(id: "tatwo-os-l", providerID: provider.id, displayName: "TATWO ULTRAWORK L", isAvailable: true),
            AIModel(id: "tatwo-os-xl", providerID: provider.id, displayName: "TATWO ULTRAWORK XL", isAvailable: true)
        ]
    }

    public func usageSnapshots() async throws -> [UsageSnapshot] {
        guard let snapshot = (try? await importStore.loadLiveSnapshot()) ?? (try? importStore.loadSnapshot()), !snapshot.accounts.isEmpty else {
            return [UsageSnapshot(providerID: provider.id, accountID: "codex-local", remainingPercent: nil, limitLabel: "由 Codex provider 偵測", resetAt: nil, requiresRelogin: false)]
        }
        return snapshot.accounts.map { account in
            UsageSnapshot(
                providerID: provider.id,
                accountID: Self.publicAccountID(for: account.email),
                remainingPercent: account.remainingPercent,
                limitLabel: account.plan,
                resetAt: nil,
                requiresRelogin: account.requiresRelogin
            )
        }
    }

    private static func publicAccountID(for email: String) -> String {
        let digest = SHA256.hash(data: Data(email.lowercased().utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "codex-\(hex)"
    }
}

public struct ClaudeProvider: ProviderAdapter {
    public var provider: AIProvider {
        let status = Self.authStatus()
        return AIProvider(
            id: "claude",
            kind: .claude,
            displayName: "Claude",
            status: status.loggedIn ? .ready : .notConfigured,
            lastCheckedAt: Date()
        )
    }

    public init() {}

    public func accounts() async throws -> [AIAccount] {
        let status = Self.authStatus()
        guard status.loggedIn else { return [] }
        return [
            AIAccount(
                id: "claude-oauth",
                providerID: provider.id,
                maskedEmail: status.maskedEmail,
                plan: status.subscriptionType ?? "claude.ai",
                status: .ready,
                lastCheckedAt: Date()
            )
        ]
    }

    public func models() async throws -> [AIModel] {
        let isAvailable = Self.authStatus().loggedIn
        return [
            AIModel(id: "claude-sonnet-5", providerID: provider.id, displayName: "Claude Sonnet 5", isAvailable: isAvailable),
            AIModel(id: "claude-opus", providerID: provider.id, displayName: "Claude Opus", isAvailable: isAvailable)
        ]
    }

    public func usageSnapshots() async throws -> [UsageSnapshot] { [] }

    private static func authStatus() -> ClaudeAuthStatusSnapshot {
        let path = "/opt/homebrew/bin/claude"
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return ClaudeAuthStatusSnapshot(loggedIn: false, email: nil, subscriptionType: nil)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["auth", "status", "--json"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return ClaudeAuthStatusSnapshot(loggedIn: false, email: nil, subscriptionType: nil)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (try? JSONDecoder().decode(ClaudeAuthStatusSnapshot.self, from: data))
                ?? ClaudeAuthStatusSnapshot(loggedIn: false, email: nil, subscriptionType: nil)
        } catch {
            return ClaudeAuthStatusSnapshot(loggedIn: false, email: nil, subscriptionType: nil)
        }
    }
}

private struct ClaudeAuthStatusSnapshot: Decodable {
    let loggedIn: Bool
    let email: String?
    let subscriptionType: String?

    var maskedEmail: String {
        guard let email, !email.isEmpty else { return "Claude OAuth" }
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "Claude OAuth" }
        let local = parts[0]
        let domain = parts[1]
        let localPrefix = String(local.prefix(2))
        let domainPrefix = String(domain.prefix(1))
        return "\(localPrefix)******@\(domainPrefix)****"
    }
}

public struct APIUsageProvider: ProviderAdapter {
    public var provider: AIProvider {
        let bindings = Self.storedBindings()
        return AIProvider(
            id: "api",
            kind: .api,
            displayName: "API 用量",
            status: bindings.isEmpty ? .notConfigured : .ready,
            lastCheckedAt: Date()
        )
    }

    public init() {}

    public func accounts() async throws -> [AIAccount] {
        let bindings = Self.storedBindings()
        guard !bindings.isEmpty else { return [] }
        return bindings.map { binding in
            AIAccount(
                id: binding.keyID,
                providerID: provider.id,
                maskedEmail: binding.displayName ?? "\(binding.provider) API",
                plan: binding.provider,
                status: .ready,
                lastCheckedAt: binding.createdAt
            )
        }
    }

    public func models() async throws -> [AIModel] {
        let bindings = Self.storedBindings()
        guard !bindings.isEmpty else { return [] }

        var seen = Set<String>()
        return bindings.compactMap { binding in
            let id = Self.modelID(for: binding)
            guard seen.insert(id).inserted else { return nil }
            return AIModel(
                id: id,
                providerID: provider.id,
                displayName: "\(binding.provider) \(binding.model)",
                isAvailable: true
            )
        }
    }

    public func usageSnapshots() async throws -> [UsageSnapshot] { [] }

    private static func storedBindings() -> [APIBindingMetadata] {
        (try? APIBindingMetadataStore.load()) ?? []
    }

    private static func modelID(for binding: APIBindingMetadata) -> String {
        "api.\(slug(binding.provider)).\(slug(binding.model))"
    }

    private static func slug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "custom" : collapsed
    }
}

public actor ProviderRegistry {
    private let adapters: [any ProviderAdapter]
    private let bindingStore = BindingStore()

    public init(adapters: [any ProviderAdapter] = [CodexProvider(), ClaudeProvider(), APIUsageProvider()]) {
        self.adapters = adapters
    }

    public func providers() -> [AIProvider] {
        adapters.map(\.provider)
    }

    public func models(providerID: String) async throws -> [AIModel] {
        guard let adapter = adapters.first(where: { $0.provider.id == providerID }) else {
            throw AISwitchError.providerNotFound(providerID)
        }
        return try await adapter.models()
    }

    public func accounts(providerID: String) async throws -> [AIAccount] {
        guard let adapter = adapters.first(where: { $0.provider.id == providerID }) else {
            throw AISwitchError.providerNotFound(providerID)
        }
        return try await adapter.accounts()
    }

    public func usageSnapshots(providerID: String) async throws -> [UsageSnapshot] {
        guard let adapter = adapters.first(where: { $0.provider.id == providerID }) else {
            throw AISwitchError.providerNotFound(providerID)
        }
        return try await adapter.usageSnapshots()
    }

    public func createBinding(clientID: String, providerID: String, accountID: String? = nil, modelID: String, scopes: [String]) async throws -> ModelBinding {
        let models = try await models(providerID: providerID)
        guard models.contains(where: { $0.id == modelID }) else {
            throw AISwitchError.modelNotFound(modelID)
        }
        let accounts = try await accounts(providerID: providerID)
        let selectedAccountID: String?
        if let accountID {
            guard accounts.contains(where: { $0.id == accountID }) else {
                throw AISwitchError.providerNotConfigured(providerID)
            }
            selectedAccountID = accountID
        } else {
            selectedAccountID = accounts.first?.id
        }
        return try await bindingStore.create(clientID: clientID, providerID: providerID, accountID: selectedAccountID, modelID: modelID, scopes: scopes)
    }

    public func binding(clientID: String) async -> ModelBinding? {
        await bindingStore.binding(clientID: clientID)
    }

    public func bindings() async -> [ModelBinding] {
        await bindingStore.all()
    }

    public func revokeBinding(clientID: String) async throws {
        try await bindingStore.revoke(clientID: clientID)
    }
}
