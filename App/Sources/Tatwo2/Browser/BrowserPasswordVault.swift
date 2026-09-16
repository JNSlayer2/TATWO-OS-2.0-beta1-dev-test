import AppKit
import Combine
import Foundation
import LocalAuthentication
import Security

/// Only metadata is Codable. Passwords must never be added to this type or the index.
struct BrowserCredential: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var origin: String
    var username: String
    var title: String
    var source: Source
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var breachedAt: Date?

    enum Source: Codable, Equatable, Sendable {
        case manual, saved, imported(browser: String)
    }
}

protocol BrowserSecretStore {
    func set(_ secret: String, for id: UUID) throws
    func get(_ id: UUID) throws -> String?
    func remove(_ id: UUID) throws
}

struct KeychainSecretStore: BrowserSecretStore {
    let service: String
    let accountSuffix: String
    init(service: String = "TATWO OS Browser", accountSuffix: String = "") {
        self.service = service
        self.accountSuffix = accountSuffix
    }
    /// Preferred: the data-protection keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
    /// It needs a keychain-access-groups entitlement; ad-hoc previews and CLI fixtures get
    /// `errSecMissingEntitlement` (-34018). Then we fall back to the login keychain, which is
    /// still per-user and per-app ACL protected. Reads and deletes look in both so an item
    /// written by either variant is always found.
    enum Variant: CaseIterable { case dataProtection, login }
    static let missingEntitlement: OSStatus = -34018
    private static let lock = NSLock()
    nonisolated(unsafe) private static var writable: Variant?

    private func query(_ id: UUID, variant: Variant) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString + accountSuffix,
            kSecAttrSynchronizable as String: false
        ]
        if variant == .dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    private func attributes(for variant: Variant, secret: String) -> [String: Any] {
        var attributes: [String: Any] = [kSecValueData as String: Data(secret.utf8)]
        if variant == .dataProtection {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        return attributes
    }

    private func write(_ secret: String, for id: UUID, variant: Variant) -> OSStatus {
        let key = query(id, variant: variant)
        let attributes = attributes(for: variant, secret: secret)
        let status = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            return SecItemAdd(key.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        return status
    }

    func set(_ secret: String, for id: UUID) throws {
        Self.lock.lock(); let known = Self.writable; Self.lock.unlock()
        let order: [Variant] = known.map { [$0] } ?? Variant.allCases
        var last: OSStatus = errSecSuccess
        for variant in order {
            last = write(secret, for: id, variant: variant)
            if last == errSecSuccess {
                Self.lock.lock(); Self.writable = variant; Self.lock.unlock()
                return
            }
            if last != Self.missingEntitlement { break }
        }
        throw BrowserPasswordVaultError.keychain(last)
    }

    func get(_ id: UUID) throws -> String? {
        var last: OSStatus = errSecItemNotFound
        for variant in Variant.allCases {
            var key = query(id, variant: variant)
            key[kSecReturnData as String] = true
            key[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(key as CFDictionary, &result)
            if status == errSecSuccess {
                guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
                    throw BrowserPasswordVaultError.secretUnavailable
                }
                return secret
            }
            last = status
            if status != errSecItemNotFound && status != Self.missingEntitlement { break }
        }
        if last == errSecItemNotFound || last == Self.missingEntitlement { return nil }
        throw BrowserPasswordVaultError.keychain(last)
    }

    func remove(_ id: UUID) throws {
        for variant in Variant.allCases {
            let status = SecItemDelete(query(id, variant: variant) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound || status == Self.missingEntitlement else {
                throw BrowserPasswordVaultError.keychain(status)
            }
        }
    }
}

/// Explicitly injected by fixtures; never a fallback for a failing Keychain.
final class InMemorySecretStore: BrowserSecretStore {
    private var values: [UUID: String] = [:]
    func set(_ secret: String, for id: UUID) throws { values[id] = secret }
    func get(_ id: UUID) throws -> String? { values[id] }
    func remove(_ id: UUID) throws { values.removeValue(forKey: id) }
}

@MainActor
protocol BrowserVaultAuthenticator {
    func authenticate(reason: String) async throws
}

struct LocalAuthenticator: BrowserVaultAuthenticator {
    func authenticate(reason: String) async throws {
        let request = Request()
        defer { request.invalidate() }
        // A new context per operation: no app-side "recently unlocked" bypass.
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await request.evaluate(reason: reason)
        } onCancel: {
            Task { @MainActor in request.invalidate() }
        }
    }

    /// Keep the non-Sendable LAContext on one actor, including cancellation.
    @MainActor private final class Request {
        let context = LAContext()
        func invalidate() { context.invalidate() }

        func evaluate(reason: String) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                    if let error { continuation.resume(throwing: error) }
                    else if success { continuation.resume() }
                    else { continuation.resume(throwing: BrowserPasswordVaultError.authenticationFailed) }
                }
            }
        }
    }
}

struct AlwaysAllowAuthenticator: BrowserVaultAuthenticator {
    func authenticate(reason: String) async throws {}
}

enum BrowserPasswordVaultError: Error {
    case invalidOrigin, emptyPassword, notFound, duplicateCredential
    case indexUnavailable, secretUnavailable, authenticationFailed, clipboardUnavailable
    case keychain(OSStatus)
}

/// HTTP(S) origin normalization, shared by storage and the pure planners.
enum BrowserPasswordOrigin {
    static func normalized(_ raw: String) -> String? {
        guard var parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        parts.scheme = scheme
        parts.host = host
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.url?.absoluteString
    }

    /// Exact host, not suffix/eTLD+1. Ports may differ; schemes may not.
    static func sameSite(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = normalized(lhs), let right = normalized(rhs),
              let a = URLComponents(string: left), let b = URLComponents(string: right) else { return false }
        return a.scheme == b.scheme && a.host == b.host
    }
}

@MainActor
final class BrowserPasswordVault: ObservableObject {
    static let shared = BrowserPasswordVault(
        indexURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TATWO OS/Browser/passwords.json"),
        secrets: KeychainSecretStore(), authenticator: LocalAuthenticator())

    @Published private(set) var credentials: [BrowserCredential] = []
    @Published private(set) var storageError: String?
    let passwordChanges = PassthroughSubject<UUID, Never>()
    private let indexURL: URL?
    private let secrets: BrowserSecretStore
    private let authenticator: BrowserVaultAuthenticator
    private let pasteboard: NSPasteboard?
    private let clipboardLifetime: Duration

    private struct Index: Codable {
        var schemaVersion = 1
        let credentials: [BrowserCredential]
    }

    init(indexURL: URL?, secrets: BrowserSecretStore, authenticator: BrowserVaultAuthenticator,
         pasteboard: NSPasteboard? = nil, clipboardLifetime: Duration = .seconds(60)) {
        self.indexURL = indexURL
        self.secrets = secrets
        self.authenticator = authenticator
        self.pasteboard = pasteboard
        self.clipboardLifetime = clipboardLifetime
        guard let indexURL else { return }
        do {
            let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))
            guard index.schemaVersion == 1,
                  Set(index.credentials.map(\.id)).count == index.credentials.count else {
                throw BrowserPasswordVaultError.indexUnavailable
            }
            var usernamesByOrigin: [String: Set<String>] = [:]
            for credential in index.credentials {
                guard BrowserPasswordOrigin.normalized(credential.origin) == credential.origin,
                      usernamesByOrigin[credential.origin, default: []].insert(credential.username).inserted else {
                    throw BrowserPasswordVaultError.indexUnavailable
                }
            }
            credentials = index.credentials
        } catch CocoaError.fileReadNoSuchFile {
            // A genuinely missing index is the only load failure treated as empty.
        } catch {
            storageError = "無法讀取密碼索引；為保護既有資料，已停止變更。"
        }
    }

    func matches(origin: String) -> [BrowserCredential] {
        credentials.filter { BrowserPasswordOrigin.sameSite($0.origin, origin) }
    }

    @discardableResult
    func add(origin: String, username: String, password: String, title: String,
             source: BrowserCredential.Source) throws -> BrowserCredential {
        try requireWritable()
        guard let origin = BrowserPasswordOrigin.normalized(origin) else {
            throw BrowserPasswordVaultError.invalidOrigin
        }
        guard !password.isEmpty else { throw BrowserPasswordVaultError.emptyPassword }
        if let existing = credentials.first(where: { $0.origin == origin && $0.username == username }) {
            try update(existing.id, password: password, username: username, title: title)
            // Preserve the original provenance and identity on upsert.
            return credentials.first { $0.id == existing.id }!
        }
        let now = Date()
        let credential = BrowserCredential(id: UUID(), origin: origin, username: username, title: title,
                                           source: source, createdAt: now, updatedAt: now, lastUsedAt: nil)
        try secrets.set(password, for: credential.id)
        do { try persist(credentials + [credential]) }
        catch {
            try rollback { try secrets.remove(credential.id) }
            throw error
        }
        passwordChanges.send(credential.id)
        return credential
    }

    func update(_ id: UUID, password: String?, username: String?, title: String?) throws {
        try requireWritable()
        guard let position = credentials.firstIndex(where: { $0.id == id }) else {
            throw BrowserPasswordVaultError.notFound
        }
        if let password, password.isEmpty { throw BrowserPasswordVaultError.emptyPassword }
        var next = credentials
        if password != nil { next[position].breachedAt = nil }
        if let username { next[position].username = username }
        if let title { next[position].title = title }
        guard !next.contains(where: {
            $0.id != id && $0.origin == next[position].origin && $0.username == next[position].username
        }) else { throw BrowserPasswordVaultError.duplicateCredential }
        next[position].updatedAt = Date()
        let oldPassword = try password == nil ? nil : secrets.get(id)
        if let password { try secrets.set(password, for: id) }
        do { try persist(next) }
        catch {
            if password != nil {
                try rollback {
                    if let oldPassword { try secrets.set(oldPassword, for: id) }
                    else { try secrets.remove(id) }
                }
            }
            throw error
        }
        if password != nil { passwordChanges.send(id) }
    }

    /// The settings UI must obtain IslandNotice confirmation before calling this mutation.
    func delete(_ id: UUID) throws {
        try requireWritable()
        guard credentials.contains(where: { $0.id == id }) else { throw BrowserPasswordVaultError.notFound }
        let oldPassword = try secrets.get(id)
        try secrets.remove(id)
        do { try persist(credentials.filter { $0.id != id }) }
        catch {
            if let oldPassword { try rollback { try secrets.set(oldPassword, for: id) } }
            throw error
        }
    }

    func revealPassword(_ id: UUID, reason: String) async throws -> String {
        try await authenticate(reason)
        // Resolve identity after await: a credential may be removed during the prompt.
        let password = try secret(for: id)
        try recordUse(id)
        return password
    }

    /// W57c only: caller must hold a live human-page Island approval before disclosure.
    /// Unlike reveal/copy/export, this never puts a secret on a settings surface or clipboard.
    func passwordForApprovedFill(_ id: UUID) throws -> String {
        try requireWritable()
        let password = try secret(for: id)
        try recordUse(id)
        return password
    }

    /// Compare only this submitted account, transiently; never enumerate/export the vault.
    func existingForPasswordAssist(origin: String, username: String) throws
        -> [BrowserPasswordSavePlanner.ExistingCredential] {
        try requireWritable()
        return try credentials.filter {
            $0.origin == BrowserPasswordOrigin.normalized(origin) && $0.username == username
        }.map { ($0, try secret(for: $0.id)) }
    }

    func copyPassword(_ id: UUID) async throws {
        let password = try await revealPassword(id, reason: "拷貝瀏覽器密碼")
        let pasteboard = pasteboard ?? NSPasteboard.general
        pasteboard.clearContents()
        // Advisory markers for clipboard managers; do not advertise Universal Clipboard data.
        let item = NSPasteboardItem()
        item.setString(password, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        guard pasteboard.writeObjects([item]) else { throw BrowserPasswordVaultError.clipboardUnavailable }
        let changeCount = pasteboard.changeCount
        let lifetime = clipboardLifetime
        // Owned by the vault operation, not the settings row; survives closing settings.
        // Capture the generation only, never retain the password for the timer.
        Task { @MainActor in
            try? await Task.sleep(for: lifetime)
            Self.clearCopiedPassword(from: pasteboard, changeCount: changeCount)
        }
    }

    static func clearCopiedPassword(from pasteboard: NSPasteboard, changeCount: Int) {
        guard pasteboard.changeCount == changeCount else { return }
        pasteboard.clearContents()
    }

    func exportCSV(reason: String) async throws -> Data {
        try await authenticate(reason)
        // Fail the entire export if any Keychain read fails; never write a partial file.
        var rows = ["origin,username,password,title"]
        for credential in credentials {
            let password = try secret(for: credential.id)
            rows.append([credential.origin, credential.username, password, credential.title]
                .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                .joined(separator: ","))
        }
        return Data((rows.joined(separator: "\r\n") + "\r\n").utf8)
    }

    func importCredentials(_ items: [(origin: String, username: String, password: String,
                                     title: String, browser: String)]) throws
        -> (added: Int, updated: Int, skipped: Int) {
        try requireWritable()
        var result = (added: 0, updated: 0, skipped: 0)
        for item in items {
            guard let origin = BrowserPasswordOrigin.normalized(item.origin), !item.password.isEmpty else {
                result.skipped += 1
                continue
            }
            let exists = credentials.contains { $0.origin == origin && $0.username == item.username }
            try add(origin: origin, username: item.username, password: item.password,
                    title: item.title, source: .imported(browser: item.browser))
            if exists { result.updated += 1 } else { result.added += 1 }
        }
        // Per-item commits: a storage error throws immediately, with earlier items retained.
        return result
    }

    /// Native security service only. Caller returns a digest, not a secret, to its network client.
    func withPasswordForSecurityCheck<T>(_ id: UUID, _ body: (String) throws -> T) throws -> T {
        try requireWritable()
        return try body(secret(for: id))
    }

    func setBreached(_ id: UUID, breached: Bool) throws {
        try requireWritable()
        guard let i = credentials.firstIndex(where: { $0.id == id }) else { throw BrowserPasswordVaultError.notFound }
        var next = credentials
        next[i].breachedAt = breached ? (next[i].breachedAt ?? Date()) : nil
        guard next != credentials else { return }
        try persist(next)
    }

    private func authenticate(_ reason: String) async throws {
        try Task.checkCancellation()
        try requireWritable()
        try await authenticator.authenticate(reason: reason)
        try Task.checkCancellation()
        try requireWritable()
    }

    private func secret(for id: UUID) throws -> String {
        guard credentials.contains(where: { $0.id == id }) else { throw BrowserPasswordVaultError.notFound }
        guard let password = try secrets.get(id) else { throw BrowserPasswordVaultError.secretUnavailable }
        return password
    }

    private func recordUse(_ id: UUID) throws {
        var next = credentials
        guard let position = next.firstIndex(where: { $0.id == id }) else { throw BrowserPasswordVaultError.notFound }
        next[position].lastUsedAt = Date()
        try persist(next)
    }

    private func requireWritable() throws {
        guard storageError == nil else { throw BrowserPasswordVaultError.indexUnavailable }
    }

    private func persist(_ next: [BrowserCredential]) throws {
        if let indexURL {
            let data = try JSONEncoder().encode(Index(credentials: next))
            try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try data.write(to: indexURL, options: .atomic)
        }
        credentials = next
    }

    private func rollback(_ restore: () throws -> Void) throws {
        do { try restore() }
        catch {
            storageError = "密碼儲存失敗且無法還原；為保護資料，已停止變更。"
            throw BrowserPasswordVaultError.indexUnavailable
        }
    }
}

enum BrowserPasswordAutofillPlanner {
    enum Decision: Equatable {
        case none
        case offerFill([BrowserCredential])
    }

    static func decision(form: EmbeddedBrowserPasswordFormMetadata, matches: [BrowserCredential]) -> Decision {
        guard form.hasPasswordField, !form.isHTTP, !form.isCrossOrigin, !form.hasIDNHost,
              !form.hasMixedScriptHost, !form.hasConfusableHost,
              let origin = form.actionOrigin,
              let normalized = BrowserPasswordOrigin.normalized(origin),
              URLComponents(string: normalized)?.scheme == "https" else { return .none }
        let eligible = matches.filter { BrowserPasswordOrigin.sameSite($0.origin, normalized) }
        return eligible.isEmpty ? .none : .offerFill(eligible)
    }
}

enum BrowserPasswordSavePlanner {
    /// Caller-supplied, ephemeral trusted values, NOT Codable and never put in the index.
    /// W47 must obtain these through an authorized vault flow; metadata alone cannot compare passwords.
    typealias ExistingCredential = (credential: BrowserCredential, password: String)
    enum Decision: Equatable {
        case none
        case askSave
        case askUpdate(BrowserCredential)
    }

    static func decision(origin: String, username: String, password: String,
                         existing: [ExistingCredential]) -> Decision {
        guard let origin = BrowserPasswordOrigin.normalized(origin), !password.isEmpty else { return .none }
        guard let match = existing.first(where: {
            BrowserPasswordOrigin.normalized($0.credential.origin) == origin && $0.credential.username == username
        }) else { return .askSave }
        return match.password == password ? .none : .askUpdate(match.credential)
    }
}
