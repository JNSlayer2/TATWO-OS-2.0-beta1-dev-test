import Combine
import Foundation

struct AICredential: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var origin: String
    var username: String
    var label: String
    var allowedCallers: CallerScope
    var createdAt: Date
    var lastUsedAt: Date?
    var useCount: Int
}

enum CallerScope: Codable, Equatable, Sendable {
    case anyEngine
    case bot(id: String)
    case thread(id: String)

    func allows(_ caller: AICaller) -> Bool {
        guard !caller.engine.isEmpty else { return false }
        switch self {
        case .anyEngine: return true
        case let .bot(id): return !id.isEmpty && caller.botID == id
        case let .thread(id):
            if let expected = UUID(uuidString: id), let actual = caller.threadID.flatMap(UUID.init(uuidString:)) {
                return expected == actual
            }
            return !id.isEmpty && caller.threadID == id
        }
    }

    var isValid: Bool {
        switch self {
        case .anyEngine: true
        case let .bot(id), let .thread(id):
            !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && id.utf8.count <= 256
        }
    }

    var title: String {
        switch self {
        case .anyEngine: "所有引擎"
        case let .bot(id): "Bot：\(id)"
        case let .thread(id): "對話：\(id)"
        }
    }
}

struct AICaller: Equatable, Sendable {
    let engine: String
    let botID: String?
    let threadID: String?
    let preset: TatwoPermissionPreset?
    var readOnly = false
}

enum AIVaultLoginPolicy {
    enum Decision: String { case allow, allowWithNotice, ask, deny }
    static func decision(_ preset: TatwoPermissionPreset?, readOnly: Bool = false) -> Decision {
        guard !readOnly else { return .deny }
        switch preset {
        case .fullAccess: return .allow
        case .approveForMe: return .allowWithNotice
        default: return .ask
        }
    }
}

@MainActor
final class BrowserAIVault: ObservableObject {
    static let shared = BrowserAIVault(
        indexURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TATWO OS/Browser/ai-passwords.json"),
        secrets: KeychainSecretStore(service: "TATWO OS AI Vault"), authenticator: LocalAuthenticator())

    @Published private(set) var credentials: [AICredential] = []
    @Published private(set) var storageError: String?
    private let indexURL: URL?
    private let secrets: BrowserSecretStore
    private let authenticator: BrowserVaultAuthenticator
    // Metadata edits, including password-only edits, revoke pending login approvals.
    private(set) var revision: UInt64 = 0
    private struct Index: Codable {
        var schemaVersion = 1
        let credentials: [AICredential]
    }

    init(indexURL: URL?, secrets: BrowserSecretStore, authenticator: BrowserVaultAuthenticator) {
        self.indexURL = indexURL
        self.secrets = secrets
        self.authenticator = authenticator
        guard let indexURL else { return }
        do {
            let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))
            guard index.schemaVersion == 1,
                  Set(index.credentials.map(\.id)).count == index.credentials.count else {
                throw BrowserPasswordVaultError.indexUnavailable
            }
            var accounts: [String: Set<String>] = [:]
            for item in index.credentials {
                guard BrowserPasswordOrigin.normalized(item.origin) == item.origin,
                      item.allowedCallers.isValid, item.useCount >= 0,
                      accounts[item.origin, default: []].insert(item.username).inserted else {
                    throw BrowserPasswordVaultError.indexUnavailable
                }
            }
            credentials = index.credentials
        } catch CocoaError.fileReadNoSuchFile {
        } catch { storageError = "無法讀取 AI 帳號索引；已停止變更。" }
    }

    func matches(origin: String, caller: AICaller) -> [AICredential] {
        guard storageError == nil else { return [] }
        return credentials.filter {
            // Host/path normalization, but never cross-scheme or cross-port secret release.
            BrowserPasswordOrigin.normalized($0.origin) == BrowserPasswordOrigin.normalized(origin) &&
                $0.allowedCallers.allows(caller)
        }
    }

    @discardableResult
    func add(origin: String, username: String, password: String, label: String,
             allowedCallers: CallerScope = .anyEngine) throws -> AICredential {
        try requireWritable()
        guard let origin = BrowserPasswordOrigin.normalized(origin), allowedCallers.isValid else {
            throw BrowserPasswordVaultError.invalidOrigin
        }
        guard !password.isEmpty, password.utf8.count <= 16_384, username.utf8.count <= 4_096 else {
            throw BrowserPasswordVaultError.emptyPassword
        }
        if let existing = credentials.first(where: { $0.origin == origin && $0.username == username }) {
            try update(existing.id, password: password, username: username, label: label, allowedCallers: allowedCallers)
            return credentials.first { $0.id == existing.id }!
        }
        let item = AICredential(id: UUID(), origin: origin, username: username, label: label,
            allowedCallers: allowedCallers, createdAt: Date(), lastUsedAt: nil, useCount: 0)
        try secrets.set(password, for: item.id)
        do { try persist(credentials + [item]) }
        catch {
            try rollback { try secrets.remove(item.id) }
            throw error
        }
        return item
    }

    func update(_ id: UUID, password: String? = nil, username: String? = nil, label: String? = nil,
                allowedCallers: CallerScope? = nil) throws {
        try requireWritable()
        guard let i = credentials.firstIndex(where: { $0.id == id }) else { throw BrowserPasswordVaultError.notFound }
        if let password, password.isEmpty || password.utf8.count > 16_384 { throw BrowserPasswordVaultError.emptyPassword }
        if let allowedCallers, !allowedCallers.isValid { throw BrowserPasswordVaultError.invalidOrigin }
        if let username, username.utf8.count > 4_096 { throw BrowserPasswordVaultError.invalidOrigin }
        var next = credentials
        if let username { next[i].username = username }
        if let label { next[i].label = label }
        if let allowedCallers { next[i].allowedCallers = allowedCallers }
        guard !next.contains(where: { $0.id != id && $0.origin == next[i].origin && $0.username == next[i].username }) else {
            throw BrowserPasswordVaultError.duplicateCredential
        }
        let old = try password == nil ? nil : secrets.get(id)
        if let password { try secrets.set(password, for: id) }
        do { try persist(next) }
        catch {
            if password != nil {
                try rollback {
                    if let old { try secrets.set(old, for: id) } else { try secrets.remove(id) }
                }
            }
            throw error
        }
    }

    /// Human settings only, following Island confirmation.
    func delete(_ id: UUID) throws {
        try requireWritable()
        guard credentials.contains(where: { $0.id == id }) else { throw BrowserPasswordVaultError.notFound }
        let old = try secrets.get(id)
        try secrets.remove(id)
        do { try persist(credentials.filter { $0.id != id }) }
        catch {
            if let old { try rollback { try secrets.set(old, for: id) } }
            throw error
        }
    }

    func revealPassword(id: UUID, reason: String) async throws -> String {
        try await authenticate(reason)
        return try secret(id)
    }

    /// Native-only closure; no return-secret API is reachable from the agent transport.
    /// Caller must revalidate its live approval, target and vault revision immediately before this call.
    func fillForApprovedLogin(_ id: UUID, caller: AICaller, origin: String,
                              fill: (String, String) throws -> Bool) throws {
        try requireWritable()
        guard !caller.readOnly, let item = matches(origin: origin, caller: caller).first(where: { $0.id == id }) else {
            throw BrowserPasswordVaultError.notFound
        }
        guard try fill(item.username, secret(id)) else { throw AIVaultLoginError("ai_login_stale_page") }
    }

    func recordUse(_ id: UUID) throws {
        try requireWritable()
        guard let i = credentials.firstIndex(where: { $0.id == id }) else { throw BrowserPasswordVaultError.notFound }
        var next = credentials
        next[i].lastUsedAt = Date()
        next[i].useCount = next[i].useCount == Int.max ? Int.max : next[i].useCount + 1
        try persist(next)
    }

    func importCSV(url: URL) throws -> (added: Int, updated: Int, skipped: Int) {
        try requireWritable()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? Int, size <= BrowserPasswordCSVImport.maximumBytes else {
            throw BrowserImportError.tooLarge
        }
        let data = try Data(contentsOf: url)
        guard data.count <= BrowserPasswordCSVImport.maximumBytes,
              var text = String(data: data, encoding: .utf8) else { throw BrowserImportError.invalidData }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        let rows = try BrowserPasswordCSVImport.csvRows(text)
        guard let header = rows.first else { throw BrowserImportError.invalidData }
        let names = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard Set(names).count == names.count, let o = names.firstIndex(of: "origin"),
              let u = names.firstIndex(of: "username"), let p = names.firstIndex(of: "password"),
              let l = names.firstIndex(of: "label") else { throw BrowserImportError.invalidData }
        var result = (added: 0, updated: 0, skipped: 0)
        for row in rows.dropFirst() where row != [""] {
            try Task.checkCancellation()
            guard row.count == names.count, let origin = BrowserPasswordOrigin.normalized(row[o]),
                  !row[p].isEmpty, row[p].utf8.count <= 16_384, row[u].utf8.count <= 4_096 else {
                result.skipped += 1; continue
            }
            let existing = credentials.first { $0.origin == origin && $0.username == row[u] }
            // CSV has no scope column: never widen an existing account's permission.
            try add(origin: origin, username: row[u], password: row[p], label: row[l],
                    allowedCallers: existing?.allowedCallers ?? .anyEngine)
            if existing == nil { result.added += 1 } else { result.updated += 1 }
        }
        return result
    }

    func exportCSV(reason: String) async throws -> Data {
        try await authenticate(reason)
        var rows = ["origin,username,password,label"]
        for item in credentials {
            rows.append(try [item.origin, item.username, secret(item.id), item.label]
                .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ","))
        }
        return Data((rows.joined(separator: "\r\n") + "\r\n").utf8)
    }

    private func authenticate(_ reason: String) async throws {
        try Task.checkCancellation()
        try requireWritable()
        try await authenticator.authenticate(reason: reason)
        try Task.checkCancellation()
        try requireWritable()
    }
    private func secret(_ id: UUID) throws -> String {
        guard credentials.contains(where: { $0.id == id }) else { throw BrowserPasswordVaultError.notFound }
        guard let value = try secrets.get(id) else { throw BrowserPasswordVaultError.secretUnavailable }
        return value
    }
    private func requireWritable() throws {
        guard storageError == nil else { throw BrowserPasswordVaultError.indexUnavailable }
    }
    private func persist(_ next: [AICredential]) throws {
        if let indexURL {
            try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(Index(credentials: next)).write(to: indexURL, options: .atomic)
        }
        credentials = next
        revision &+= 1
    }
    private func rollback(_ restore: () throws -> Void) throws {
        do { try restore() }
        catch {
            storageError = "AI 帳號儲存失敗且無法還原；已停止變更。"
            throw BrowserPasswordVaultError.indexUnavailable
        }
    }
}

struct AIVaultLoginError: Error, CustomStringConvertible {
    let description: String
    init(_ code: String) { description = code }
}
