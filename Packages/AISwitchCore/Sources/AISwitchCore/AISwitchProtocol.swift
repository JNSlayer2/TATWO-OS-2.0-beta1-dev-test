import CryptoKit
import Foundation
import Security

public enum AISwitchClientStatus: String, Codable, Sendable, CaseIterable {
    case active
    case revoked
}

public enum AISwitchScope: String, Codable, Sendable, CaseIterable {
    case modelInvoke = "model.invoke"
    case usageRead = "usage.read"
}

public enum AISwitchProviderReference: String, Codable, Sendable, CaseIterable {
    case codex
    case claude
    case api
}

public struct AISwitchAuthorizationRequest: Codable, Sendable, Equatable {
    public let clientID: String
    public let redirectURI: String
    public let scopes: [String]
    public let state: String
    public let codeChallenge: String
    public let providerHint: String?
    public let modelHint: String?
    public let createdAt: Date

    public init(
        clientID: String,
        redirectURI: String,
        scopes: [String],
        state: String,
        codeChallenge: String,
        providerHint: String? = nil,
        modelHint: String? = nil,
        createdAt: Date = Date()
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.state = state
        self.codeChallenge = codeChallenge
        self.providerHint = providerHint
        self.modelHint = modelHint
        self.createdAt = createdAt
    }

    public var authorizeURL: URL {
        var components = URLComponents()
        components.scheme = "aiswitch"
        components.host = "authorize"
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge)
        ]
        if let providerHint { components.queryItems?.append(URLQueryItem(name: "provider_hint", value: providerHint)) }
        if let modelHint { components.queryItems?.append(URLQueryItem(name: "model_hint", value: modelHint)) }
        return components.url ?? URL(string: "aiswitch://authorize")!
    }
}

public struct AISwitchAuthorizationBegin: Codable, Sendable, Equatable {
    public let request: AISwitchAuthorizationRequest
    public let authorizeURL: String
    public let codeVerifier: String

    public init(request: AISwitchAuthorizationRequest, codeVerifier: String) {
        self.request = request
        self.authorizeURL = request.authorizeURL.absoluteString
        self.codeVerifier = codeVerifier
    }
}

public struct AISwitchAuthorizationCodeRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let code: String
    public let request: AISwitchAuthorizationRequest
    public let binding: ModelBinding
    public let createdAt: Date
    public let expiresAt: Date
    public let consumedAt: Date?

    public init(
        id: String = UUID().uuidString,
        code: String = AISwitchRandom.urlSafeToken(byteCount: 32),
        request: AISwitchAuthorizationRequest,
        binding: ModelBinding,
        createdAt: Date = Date(),
        expiresAt: Date = Date().addingTimeInterval(300),
        consumedAt: Date? = nil
    ) {
        self.id = id
        self.code = code
        self.request = request
        self.binding = binding
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.consumedAt = consumedAt
    }

    public func consumed(at date: Date = Date()) -> AISwitchAuthorizationCodeRecord {
        AISwitchAuthorizationCodeRecord(
            id: id,
            code: code,
            request: request,
            binding: binding,
            createdAt: createdAt,
            expiresAt: expiresAt,
            consumedAt: date
        )
    }
}

public enum AISwitchInvokeInput: Codable, Sendable, Equatable {
    case text(String)

    enum CodingKeys: String, CodingKey { case type, text }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text": self = .text(try container.decode(String.self, forKey: .text))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unsupported invoke input type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        }
    }
}

public struct AISwitchInvokeRequest: Codable, Sendable, Equatable {
    public let bindingID: String
    public let input: AISwitchInvokeInput
    public let clientID: String?

    public init(bindingID: String, input: AISwitchInvokeInput, clientID: String? = nil) {
        self.bindingID = bindingID
        self.input = input
        self.clientID = clientID
    }
}

public struct AISwitchInvokeResponse: Codable, Sendable, Equatable {
    public let bindingID: String
    public let providerID: String
    public let modelID: String
    public let outputText: String
    public let usedBroker: Bool

    public init(bindingID: String, providerID: String, modelID: String, outputText: String, usedBroker: Bool = true) {
        self.bindingID = bindingID
        self.providerID = providerID
        self.modelID = modelID
        self.outputText = outputText
        self.usedBroker = usedBroker
    }
}

public enum AISwitchPKCE {
    public static func makeVerifier() -> String {
        AISwitchRandom.urlSafeToken(byteCount: 32)
    }

    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    public static func verify(verifier: String, challenge: String) -> Bool {
        self.challenge(for: verifier) == challenge
    }
}

public enum AISwitchRandom {
    public static func urlSafeToken(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return Data(bytes).base64URLEncodedString()
    }
}

public actor ClientRegistrationStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private var clients: [String: ClientRegistration]?

    public init(fileURL: URL = AISwitchRuntimePaths.clientsURL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func register(_ client: ClientRegistration) throws -> ClientRegistration {
        try loadIfNeeded()
        clients?[client.id] = client
        try save()
        return client
    }

    public func all() -> [ClientRegistration] {
        try? loadIfNeeded()
        return (clients ?? [:]).values.sorted { $0.id < $1.id }
    }

    public func client(id: String) -> ClientRegistration? {
        try? loadIfNeeded()
        return clients?[id]
    }

    public func revoke(id: String) throws -> ClientRegistration {
        try loadIfNeeded()
        guard let existing = clients?[id] else { throw AISwitchError.clientNotRegistered(id) }
        let revoked = ClientRegistration(
            id: existing.id,
            displayName: existing.displayName,
            bundleID: existing.bundleID,
            callbackURLScheme: existing.callbackURLScheme,
            redirectURIs: existing.redirectURIs,
            allowedProviders: existing.allowedProviders,
            allowedScopes: existing.allowedScopes,
            status: .revoked
        )
        clients?[id] = revoked
        try save()
        return revoked
    }

    public func validate(request: AISwitchAuthorizationRequest) throws -> ClientRegistration {
        try loadIfNeeded()
        guard let client = clients?[request.clientID] else { throw AISwitchError.clientNotRegistered(request.clientID) }
        guard client.status == .active else { throw AISwitchError.clientRevoked(client.id) }
        guard client.redirectURIs.contains(request.redirectURI) else { throw AISwitchError.invalidRedirectURI(request.redirectURI) }
        for scope in request.scopes where !client.allowedScopes.contains(scope) {
            throw AISwitchError.invalidScope(scope)
        }
        if let providerHint = request.providerHint, !client.allowedProviders.contains(providerHint) {
            throw AISwitchError.providerNotFound(providerHint)
        }
        return client
    }

    private func loadIfNeeded() throws {
        guard clients == nil else { return }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            clients = [:]
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let values = try decoder.decode([ClientRegistration].self, from: Data(contentsOf: fileURL))
        clients = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
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
        let values = (clients ?? [:]).values.sorted { $0.id < $1.id }
        try encoder.encode(values).write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: fileURL.path)
    }
}

public actor AuthorizationCodeStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private var records: [String: AISwitchAuthorizationCodeRecord]?

    public init(fileURL: URL = AISwitchRuntimePaths.authorizationCodesURL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func issue(request: AISwitchAuthorizationRequest, binding: ModelBinding, expiresIn: TimeInterval = 300) throws -> AISwitchAuthorizationCodeRecord {
        try loadIfNeeded()
        let now = Date()
        let record = AISwitchAuthorizationCodeRecord(request: request, binding: binding, createdAt: now, expiresAt: now.addingTimeInterval(expiresIn))
        records?[record.code] = record
        try save()
        return record
    }

    public func exchange(code: String, verifier: String, clientID: String, now: Date = Date()) throws -> ModelBinding {
        try loadIfNeeded()
        guard let record = records?[code] else { throw AISwitchError.authorizationExpired }
        guard record.consumedAt == nil else { throw AISwitchError.authorizationConsumed }
        guard record.expiresAt > now else { throw AISwitchError.authorizationExpired }
        guard record.request.clientID == clientID else { throw AISwitchError.clientNotRegistered(clientID) }
        guard AISwitchPKCE.verify(verifier: verifier, challenge: record.request.codeChallenge) else {
            throw AISwitchError.authorizationVerifierMismatch
        }
        records?[code] = record.consumed(at: now)
        try save()
        return record.binding
    }

    private func loadIfNeeded() throws {
        guard records == nil else { return }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            records = [:]
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let values = try decoder.decode([AISwitchAuthorizationCodeRecord].self, from: Data(contentsOf: fileURL))
        records = Dictionary(uniqueKeysWithValues: values.map { ($0.code, $0) })
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
        let values = (records ?? [:]).values.sorted { $0.createdAt > $1.createdAt }
        try encoder.encode(values).write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: fileURL.path)
    }
}

public actor AISwitchBroker {
    private let bindingStore: BindingStore

    public init(bindingStore: BindingStore = BindingStore()) {
        self.bindingStore = bindingStore
    }

    public func invoke(_ request: AISwitchInvokeRequest) async throws -> AISwitchInvokeResponse {
        guard let binding = await bindingStore.all().first(where: { $0.id == request.bindingID }) else {
            throw AISwitchError.bindingNotFound(request.bindingID)
        }
        if let clientID = request.clientID, binding.clientID != clientID {
            throw AISwitchError.bindingNotFound(request.bindingID)
        }
        guard binding.scopes.contains(AISwitchScope.modelInvoke.rawValue) else {
            throw AISwitchError.invalidScope(AISwitchScope.modelInvoke.rawValue)
        }

        let output: String
        switch request.input {
        case .text(let text):
            output = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "reply with ok"
                ? "OK"
                : "AI Switch broker accepted request for \(binding.providerID)/\(binding.modelID)."
        }
        return AISwitchInvokeResponse(
            bindingID: binding.id,
            providerID: binding.providerID,
            modelID: binding.modelID,
            outputText: output
        )
    }
}

public enum AISwitchProjectBootstrap {
    public static func writeTemplate(
        to projectURL: URL,
        clientID: String,
        displayName: String,
        callbackScheme: String,
        providers: [String],
        scopes: [String],
        fileManager: FileManager = .default
    ) throws {
        let directory = projectURL.appendingPathComponent(".aiswitch", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let client = ClientRegistration(
            id: clientID,
            displayName: displayName,
            bundleID: clientID,
            callbackURLScheme: callbackScheme,
            allowedProviders: providers,
            allowedScopes: scopes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(client).write(to: directory.appendingPathComponent("client.json"), options: [.atomic])

        let bootstrap = """
        import AISwitchKit

        enum AISwitchBootstrap {
            static let client = AISwitchClient(
                clientID: \"\(clientID)\",
                displayName: \"\(displayName)\",
                callbackScheme: \"\(callbackScheme)\"
            )
        }
        """
        try bootstrap.write(to: directory.appendingPathComponent("AISwitchBootstrap.swift"), atomically: true, encoding: .utf8)

        let guide = """
        # AI Switch Integration

        本專案不得儲存 AI provider token / API key。
        所有 AI provider、account、model 選擇必須透過 AISwitchKit。
        需要模型能力時，使用 AI Switch binding + broker invoke。
        不得直接讀 ~/.aiswitch-v4、Keychain secret、Codex/Claude auth。

        Client ID: `\(clientID)`
        Callback Scheme: `\(callbackScheme)`
        Providers: `\(providers.joined(separator: ","))`
        Scopes: `\(scopes.joined(separator: ","))`
        """
        try guide.write(to: directory.appendingPathComponent("AI_SWITCH_INTEGRATION.md"), atomically: true, encoding: .utf8)
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
