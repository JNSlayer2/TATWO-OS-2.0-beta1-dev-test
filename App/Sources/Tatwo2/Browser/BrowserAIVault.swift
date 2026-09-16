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
    // Optional metadata keeps W58's schema-1 files backward compatible.
    var hasTOTPSecret: Bool?
    var authenticatorHeldByHuman: Bool?
    var disabledAt: Date?
    var twoFactorRequiredAt: Date?
    var passwordChangeFailedAt: Date?
    var breachedAt: Date?

    /// Keychain-backed property, not a Codable field. Never retained in the published index.
    /// Injected vaults use their own totpSecrets store through fillTOTPForApprovedLogin.
    var totpSecret: String? {
        get throws { try KeychainSecretStore(service: "TATWO OS AI Vault", accountSuffix: ".totp").get(id) }
    }
    enum AuthenticatorStatus: String { case managed = "OS 代管", humanHeld = "已綁・人持有", unbound = "未綁" }
    var authenticatorStatus: AuthenticatorStatus {
        hasTOTPSecret == true ? .managed : authenticatorHeldByHuman == true ? .humanHeld : .unbound
    }
    var statusTitle: String {
        if disabledAt != nil { return "已停用" }
        if passwordChangeFailedAt != nil { return "換密碼未完成" }
        if breachedAt != nil { return "密碼曾外洩" }
        if twoFactorRequiredAt != nil { return "2FA 需人接手" }
        return "正常"
    }
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
    let passwordChanges = PassthroughSubject<UUID, Never>()
    private let indexURL: URL?
    private let secrets: BrowserSecretStore
    private let totpSecrets: BrowserSecretStore
    private let pendingSecrets: BrowserSecretStore
    private let authenticator: BrowserVaultAuthenticator
    // Metadata edits, including password-only edits, revoke pending login approvals.
    private(set) var revision: UInt64 = 0
    private struct Index: Codable {
        // W58 readers reject v2 instead of silently ignoring disabled accounts on downgrade.
        var schemaVersion = 2
        let credentials: [AICredential]
    }

    init(indexURL: URL?, secrets: BrowserSecretStore, authenticator: BrowserVaultAuthenticator,
         totpSecrets: BrowserSecretStore? = nil, pendingSecrets: BrowserSecretStore? = nil) {
        self.indexURL = indexURL
        self.secrets = secrets
        self.totpSecrets = totpSecrets ?? KeychainSecretStore(service: "TATWO OS AI Vault", accountSuffix: ".totp")
        self.pendingSecrets = pendingSecrets ?? KeychainSecretStore(service: "TATWO OS AI Vault", accountSuffix: ".pending-change")
        self.authenticator = authenticator
        guard let indexURL else { return }
        do {
            let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))
            guard [1, 2].contains(index.schemaVersion),
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
                $0.disabledAt == nil && $0.allowedCallers.allows(caller)
        }
    }

    @discardableResult
    func add(origin: String, username: String, password: String, label: String,
             allowedCallers: CallerScope = .anyEngine, totpSecret: String? = nil) throws -> AICredential {
        try requireWritable()
        guard let origin = BrowserPasswordOrigin.normalized(origin), allowedCallers.isValid else {
            throw BrowserPasswordVaultError.invalidOrigin
        }
        guard !password.isEmpty, password.utf8.count <= 16_384, username.utf8.count <= 4_096 else {
            throw BrowserPasswordVaultError.emptyPassword
        }
        if let existing = credentials.first(where: { $0.origin == origin && $0.username == username }) {
            try update(existing.id, password: password, username: username, label: label,
                       allowedCallers: allowedCallers, totpSecret: totpSecret)
            return credentials.first { $0.id == existing.id }!
        }
        var item = AICredential(id: UUID(), origin: origin, username: username, label: label,
            allowedCallers: allowedCallers, createdAt: Date(), lastUsedAt: nil, useCount: 0)
        let totp = try totpSecret.map { try TOTP.secret(from: $0) }
        item.hasTOTPSecret = totp != nil
        try secrets.set(password, for: item.id)
        do {
            if let totp { try totpSecrets.set(totp, for: item.id) }
            try persist(credentials + [item])
        }
        catch {
            try rollback {
                try secrets.remove(item.id)
                try totpSecrets.remove(item.id)
            }
            throw error
        }
        passwordChanges.send(item.id)
        return item
    }

    func update(_ id: UUID, password: String? = nil, username: String? = nil, label: String? = nil,
                allowedCallers: CallerScope? = nil, totpSecret: String? = nil) throws {
        try requireWritable()
        guard let i = credentials.firstIndex(where: { $0.id == id }) else { throw BrowserPasswordVaultError.notFound }
        if let password, password.isEmpty || password.utf8.count > 16_384 { throw BrowserPasswordVaultError.emptyPassword }
        if let allowedCallers, !allowedCallers.isValid { throw BrowserPasswordVaultError.invalidOrigin }
        if let username, username.utf8.count > 4_096 { throw BrowserPasswordVaultError.invalidOrigin }
        var next = credentials
        if password != nil { next[i].breachedAt = nil; next[i].passwordChangeFailedAt = nil }
        let totp = try totpSecret.map { try TOTP.secret(from: $0) }
        if totp != nil { next[i].hasTOTPSecret = true; next[i].authenticatorHeldByHuman = false }
        if let username { next[i].username = username }
        if let label { next[i].label = label }
        if let allowedCallers { next[i].allowedCallers = allowedCallers }
        guard !next.contains(where: { $0.id != id && $0.origin == next[i].origin && $0.username == next[i].username }) else {
            throw BrowserPasswordVaultError.duplicateCredential
        }
        let old = try password == nil ? nil : secrets.get(id)
        let oldTOTP = try totp == nil ? nil : totpSecrets.get(id)
        if let password { try secrets.set(password, for: id) }
        do {
            if let totp { try totpSecrets.set(totp, for: id) }
            try persist(next)
        }
        catch {
            if password != nil {
                try rollback {
                    if let old { try secrets.set(old, for: id) } else { try secrets.remove(id) }
                }
            }
            if totp != nil {
                try rollback {
                    if let oldTOTP { try totpSecrets.set(oldTOTP, for: id) } else { try totpSecrets.remove(id) }
                }
            }
            throw error
        }
        if password != nil { passwordChanges.send(id) }
    }

    /// Human settings only, following Island confirmation.
    func delete(_ id: UUID) throws {
        try requireWritable()
        guard credentials.contains(where: { $0.id == id }) else { throw BrowserPasswordVaultError.notFound }
        let old = try secrets.get(id)
        let oldTOTP = try totpSecrets.get(id)
        let oldPending = try pendingSecrets.get(id)
        do {
            try secrets.remove(id)
            try totpSecrets.remove(id)
            try pendingSecrets.remove(id)
            try persist(credentials.filter { $0.id != id })
        }
        catch {
            try rollback {
                if let old { try secrets.set(old, for: id) }
                if let oldTOTP { try totpSecrets.set(oldTOTP, for: id) }
                if let oldPending { try pendingSecrets.set(oldPending, for: id) }
            }
            throw error
        }
    }

    func revealPassword(id: UUID, reason: String) async throws -> String {
        try await authenticate(reason)
        return try secret(id)
    }

    func stagePasswordChange(_ id: UUID, password: String) throws {
        try requireWritable()
        guard credentials.contains(where: { $0.id == id && $0.disabledAt == nil }) else {
            throw BrowserPasswordVaultError.notFound
        }
        guard try pendingSecrets.get(id) == nil else { throw BrowserPasswordVaultError.duplicateCredential }
        try pendingSecrets.set(password, for: id)
    }
    func beginPasswordChange(_ id: UUID) throws {
        try requireWritable()
        guard try pendingSecrets.get(id) == nil else { throw BrowserPasswordVaultError.duplicateCredential }
        try metadata(id) { $0.passwordChangeFailedAt = nil }
    }
    func finishPasswordChange(_ id: UUID, password: String) throws {
        guard try pendingSecrets.get(id) == password else { throw BrowserPasswordVaultError.secretUnavailable }
        try update(id, password: password)
        // A failed cleanup is not a failed password change. The current secret has committed.
        try? pendingSecrets.remove(id)
    }
    func revealPendingPasswordChange(_ id: UUID) async throws -> String {
        try await authenticate("顯示尚未確認的新密碼")
        guard credentials.contains(where: { $0.id == id }),
              let value = try pendingSecrets.get(id) else { throw BrowserPasswordVaultError.notFound }
        return value
    }
    /// Settings-only human reconciliation, after an explicit Island confirmation.
    func reconcilePendingPasswordChange(_ id: UUID, useNewPassword: Bool) async throws {
        try await authenticate(useNewPassword ? "同步已確認的新密碼" : "放棄待確認新密碼")
        guard credentials.contains(where: { $0.id == id && $0.passwordChangeFailedAt != nil }),
              let pending = try pendingSecrets.get(id) else { throw BrowserPasswordVaultError.notFound }
        if useNewPassword { try finishPasswordChange(id, password: pending) }
        else { try pendingSecrets.remove(id) }
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
        next[i].twoFactorRequiredAt = nil
        next[i].useCount = next[i].useCount == Int.max ? Int.max : next[i].useCount + 1
        try persist(next)
    }

    func bindAuthenticator(_ id: UUID, secret raw: String?, humanHeld: Bool) throws {
        try requireWritable()
        guard let i = credentials.firstIndex(where: { $0.id == id }) else { throw BrowserPasswordVaultError.notFound }
        let value = try raw.map { try TOTP.secret(from: $0) }
        guard !(value != nil && humanHeld) else { throw TOTP.Failure.invalidSecret }
        let old = try totpSecrets.get(id)
        var next = credentials
        next[i].hasTOTPSecret = value != nil
        next[i].authenticatorHeldByHuman = humanHeld
        do {
            if let value { try totpSecrets.set(value, for: id) } else { try totpSecrets.remove(id) }
            try persist(next)
        } catch {
            try rollback {
                if let old { try totpSecrets.set(old, for: id) } else { try totpSecrets.remove(id) }
            }
            throw error
        }
    }

    func fillTOTPForApprovedLogin(_ id: UUID, caller: AICaller, origin: String,
                                 fill: (String) -> Bool) throws -> Bool {
        try requireWritable()
        guard !caller.readOnly, let item = matches(origin: origin, caller: caller).first(where: { $0.id == id }),
              item.hasTOTPSecret == true, let secret = try totpSecrets.get(id) else { return false }
        return try fill(TOTP.code(secret: secret))
    }

    func setEnabled(_ id: UUID, enabled: Bool) throws {
        try metadata(id) { $0.disabledAt = enabled ? nil : Date() }
    }
    func disableAll() throws {
        try requireWritable()
        var next = credentials
        for i in next.indices { next[i].disabledAt = next[i].disabledAt ?? Date() }
        try persist(next)
    }
    func recordTwoFactorRequired(_ id: UUID) throws { try metadata(id) { $0.twoFactorRequiredAt = Date() } }
    func recordPasswordChangeFailure(_ id: UUID) throws { try metadata(id) { $0.passwordChangeFailedAt = Date() } }
    func setBreached(_ id: UUID, breached: Bool) throws {
        try metadata(id) { $0.breachedAt = breached ? ($0.breachedAt ?? Date()) : nil }
    }
    func withPasswordForSecurityCheck<T>(_ id: UUID, _ body: (String) throws -> T) throws -> T {
        try requireWritable()
        return try body(secret(id))
    }
    private func metadata(_ id: UUID, _ edit: (inout AICredential) -> Void) throws {
        try requireWritable()
        guard let i = credentials.firstIndex(where: { $0.id == id }) else { throw BrowserPasswordVaultError.notFound }
        var next = credentials
        edit(&next[i])
        if next != credentials { try persist(next) }
    }

    func importICloud(_ items: [AIICloudImportItem]) throws -> Int {
        var count = 0
        for item in items {
            try Task.checkCancellation()
            let existing = credentials.first { $0.origin == item.origin && $0.username == item.username }
            try add(origin: item.origin, username: item.username, password: item.password,
                label: item.label, allowedCallers: existing?.allowedCallers ?? .anyEngine, totpSecret: item.totpSecret)
            count += 1
        }
        return count
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
