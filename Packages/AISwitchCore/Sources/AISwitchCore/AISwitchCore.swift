import Foundation

public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    case codex
    case claude
    case api
}

public enum ProviderStatus: String, Codable, Sendable, Equatable {
    case ready
    case notConfigured = "not_configured"
    case requiresRelogin = "requires_relogin"
    case unavailable
}

public struct AIProvider: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let kind: ProviderKind
    public let displayName: String
    public let status: ProviderStatus
    public let lastCheckedAt: Date?

    public init(id: String, kind: ProviderKind, displayName: String, status: ProviderStatus, lastCheckedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.status = status
        self.lastCheckedAt = lastCheckedAt
    }
}

public struct AIAccount: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let providerID: String
    public let maskedEmail: String
    public let plan: String
    public let status: ProviderStatus
    public let lastCheckedAt: Date?

    public init(id: String, providerID: String, maskedEmail: String, plan: String, status: ProviderStatus, lastCheckedAt: Date? = nil) {
        self.id = id
        self.providerID = providerID
        self.maskedEmail = maskedEmail
        self.plan = plan
        self.status = status
        self.lastCheckedAt = lastCheckedAt
    }
}

public struct AIModel: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let providerID: String
    public let displayName: String
    public let isAvailable: Bool

    public init(id: String, providerID: String, displayName: String, isAvailable: Bool) {
        self.id = id
        self.providerID = providerID
        self.displayName = displayName
        self.isAvailable = isAvailable
    }
}

public struct UsageSnapshot: Codable, Sendable, Equatable {
    public let providerID: String
    public let accountID: String?
    public let remainingPercent: Int?
    public let limitLabel: String?
    public let resetAt: Date?
    public let requiresRelogin: Bool

    public init(providerID: String, accountID: String?, remainingPercent: Int?, limitLabel: String?, resetAt: Date?, requiresRelogin: Bool) {
        self.providerID = providerID
        self.accountID = accountID
        self.remainingPercent = remainingPercent
        self.limitLabel = limitLabel
        self.resetAt = resetAt
        self.requiresRelogin = requiresRelogin
    }
}

public struct ModelBinding: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let clientID: String
    public let providerID: String
    public let accountID: String?
    public let modelID: String
    public let scopes: [String]
    public let createdAt: Date
    public let expiresAt: Date?

    public init(id: String = UUID().uuidString, clientID: String, providerID: String, accountID: String?, modelID: String, scopes: [String], createdAt: Date = Date(), expiresAt: Date? = nil) {
        self.id = id
        self.clientID = clientID
        self.providerID = providerID
        self.accountID = accountID
        self.modelID = modelID
        self.scopes = scopes
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public struct APIBindingMetadata: Codable, Sendable, Identifiable, Equatable {
    public var id: String { keyID }

    public let displayName: String?
    public let provider: String
    public let model: String
    public let endpoint: String
    public let keyID: String
    public let createdAt: Date

    public init(displayName: String?, provider: String, model: String, endpoint: String, keyID: String, createdAt: Date = Date()) {
        self.displayName = displayName
        self.provider = provider
        self.model = model
        self.endpoint = endpoint
        self.keyID = keyID
        self.createdAt = createdAt
    }
}

public struct ClientRegistration: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let bundleID: String?
    public let callbackURLScheme: String?
    public let redirectURIs: [String]
    public let allowedProviders: [String]
    public let allowedScopes: [String]
    public let status: AISwitchClientStatus

    public init(
        id: String,
        displayName: String,
        bundleID: String?,
        callbackURLScheme: String?,
        redirectURIs: [String] = [],
        allowedProviders: [String],
        allowedScopes: [String] = AISwitchScope.allCases.map(\.rawValue),
        status: AISwitchClientStatus = .active
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleID = bundleID
        self.callbackURLScheme = callbackURLScheme
        self.redirectURIs = redirectURIs.isEmpty
            ? callbackURLScheme.map { ["\($0)://aiswitch-callback"] } ?? []
            : redirectURIs
        self.allowedProviders = allowedProviders
        self.allowedScopes = allowedScopes
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case bundleID
        case callbackURLScheme
        case redirectURIs
        case allowedProviders
        case allowedScopes
        case status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let displayName = try container.decode(String.self, forKey: .displayName)
        let bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        let callbackURLScheme = try container.decodeIfPresent(String.self, forKey: .callbackURLScheme)
        let allowedProviders = try container.decodeIfPresent([String].self, forKey: .allowedProviders) ?? ["codex", "claude", "api"]
        self.init(
            id: id,
            displayName: displayName,
            bundleID: bundleID,
            callbackURLScheme: callbackURLScheme,
            redirectURIs: try container.decodeIfPresent([String].self, forKey: .redirectURIs) ?? [],
            allowedProviders: allowedProviders,
            allowedScopes: try container.decodeIfPresent([String].self, forKey: .allowedScopes) ?? AISwitchScope.allCases.map(\.rawValue),
            status: try container.decodeIfPresent(AISwitchClientStatus.self, forKey: .status) ?? .active
        )
    }
}

public protocol ProviderAdapter: Sendable {
    var provider: AIProvider { get }
    func accounts() async throws -> [AIAccount]
    func models() async throws -> [AIModel]
    func usageSnapshots() async throws -> [UsageSnapshot]
}

public enum AISwitchError: Error, LocalizedError, Sendable {
    case providerNotFound(String)
    case modelNotFound(String)
    case providerNotConfigured(String)
    case clientNotRegistered(String)
    case clientRevoked(String)
    case invalidRedirectURI(String)
    case invalidScope(String)
    case authorizationExpired
    case authorizationConsumed
    case authorizationVerifierMismatch
    case bindingNotFound(String)
    case brokerUnavailable
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .providerNotFound(let id): "找不到 provider：\(id)"
        case .modelNotFound(let id): "找不到模型：\(id)"
        case .providerNotConfigured(let id): "Provider 尚未設定：\(id)"
        case .clientNotRegistered(let id): "Client 尚未註冊：\(id)"
        case .clientRevoked(let id): "Client 已撤銷：\(id)"
        case .invalidRedirectURI(let uri): "Redirect URI 不被允許：\(uri)"
        case .invalidScope(let scope): "Scope 不被允許：\(scope)"
        case .authorizationExpired: "授權碼已過期"
        case .authorizationConsumed: "授權碼已使用"
        case .authorizationVerifierMismatch: "PKCE verifier 驗證失敗"
        case .bindingNotFound(let id): "找不到 binding：\(id)"
        case .brokerUnavailable: "AI Switch broker 尚不可用"
        case .storage(let message): message
        }
    }
}

public enum AISwitchRuntimePaths {
    public static var baseURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".aiswitch-v4", isDirectory: true)
    }

    public static var bindingsURL: URL {
        baseURL.appendingPathComponent("bindings.json")
    }

    public static var apiBindingsURL: URL {
        baseURL.appendingPathComponent("api-bindings.json")
    }

    public static var clientsURL: URL {
        baseURL.appendingPathComponent("clients.json")
    }

    public static var authorizationCodesURL: URL {
        baseURL.appendingPathComponent("authorization-codes.json")
    }
}

public enum APIBindingMetadataStore {
    public static func append(_ binding: APIBindingMetadata, fileURL: URL = AISwitchRuntimePaths.apiBindingsURL, fileManager: FileManager = .default) throws {
        var bindings = try load(fileURL: fileURL, fileManager: fileManager)
        bindings.removeAll { $0.keyID == binding.keyID }
        bindings.insert(binding, at: 0)
        try save(bindings, fileURL: fileURL, fileManager: fileManager)
    }

    public static func load(fileURL: URL = AISwitchRuntimePaths.apiBindingsURL, fileManager: FileManager = .default) throws -> [APIBindingMetadata] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([APIBindingMetadata].self, from: Data(contentsOf: fileURL))
    }

    public static func remove(keyID: String, fileURL: URL = AISwitchRuntimePaths.apiBindingsURL, fileManager: FileManager = .default) throws {
        let bindings = try load(fileURL: fileURL, fileManager: fileManager).filter { $0.keyID != keyID }
        try save(bindings, fileURL: fileURL, fileManager: fileManager)
    }

    public static func save(_ bindings: [APIBindingMetadata], fileURL: URL = AISwitchRuntimePaths.apiBindingsURL, fileManager: FileManager = .default) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bindings).write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: fileURL.path)
    }
}

public actor BindingStore {
    private var bindings: [String: ModelBinding]?
    private let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL = AISwitchRuntimePaths.bindingsURL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func create(clientID: String, providerID: String, accountID: String?, modelID: String, scopes: [String]) throws -> ModelBinding {
        try loadIfNeeded()
        let binding = ModelBinding(clientID: clientID, providerID: providerID, accountID: accountID, modelID: modelID, scopes: scopes)
        bindings?[clientID] = binding
        try save()
        return binding
    }

    public func binding(clientID: String) -> ModelBinding? {
        try? loadIfNeeded()
        return bindings?[clientID]
    }

    public func all() -> [ModelBinding] {
        try? loadIfNeeded()
        return (bindings ?? [:])
            .values
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func revoke(clientID: String) throws {
        try loadIfNeeded()
        bindings?.removeValue(forKey: clientID)
        try save()
    }

    private func loadIfNeeded() throws {
        guard bindings == nil else { return }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            bindings = [:]
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let values = try decoder.decode([ModelBinding].self, from: Data(contentsOf: fileURL))
        let sanitizedValues = values.map(sanitizedLegacyBinding)
        bindings = Dictionary(uniqueKeysWithValues: sanitizedValues.map { ($0.clientID, $0) })
        if sanitizedValues != values {
            try save()
        }
    }

    private func save() throws {
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let values = (bindings ?? [:]).values.sorted { $0.createdAt > $1.createdAt }
        try encoder.encode(values).write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: fileURL.path)
    }

    private func sanitizedLegacyBinding(_ binding: ModelBinding) -> ModelBinding {
        guard binding.accountID?.contains("@") == true else { return binding }
        return ModelBinding(
            id: binding.id,
            clientID: binding.clientID,
            providerID: binding.providerID,
            accountID: nil,
            modelID: binding.modelID,
            scopes: binding.scopes,
            createdAt: binding.createdAt,
            expiresAt: binding.expiresAt
        )
    }
}
