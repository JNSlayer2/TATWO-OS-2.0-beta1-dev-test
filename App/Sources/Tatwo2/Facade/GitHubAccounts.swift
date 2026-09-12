import AppKit
import Combine
import Foundation
import Security

struct GitHubAccountRecord: Codable, Hashable, Identifiable {
    var username: String
    var displayName: String
    var addedAt: Date
    var scopes: [String]
    var isDefault: Bool
    var folderMappings: [String]
    var mcpAlwaysOn: Bool

    var id: String { username }

    init(
        username: String,
        displayName: String,
        addedAt: Date,
        scopes: [String],
        isDefault: Bool,
        folderMappings: [String],
        mcpAlwaysOn: Bool = false
    ) {
        self.username = username
        self.displayName = displayName
        self.addedAt = addedAt
        self.scopes = scopes
        self.isDefault = isDefault
        self.folderMappings = folderMappings
        self.mcpAlwaysOn = mcpAlwaysOn
    }

    private enum CodingKeys: String, CodingKey {
        case username, displayName, addedAt, scopes, isDefault, folderMappings, mcpAlwaysOn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decode(String.self, forKey: .username)
        displayName = try container.decode(String.self, forKey: .displayName)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        scopes = try container.decodeIfPresent([String].self, forKey: .scopes) ?? []
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        folderMappings = try container.decodeIfPresent([String].self, forKey: .folderMappings) ?? []
        mcpAlwaysOn = try container.decodeIfPresent(Bool.self, forKey: .mcpAlwaysOn) ?? false
    }
}

struct GitHubAccountVerification: Equatable {
    var username: String
    var displayName: String
    var scopes: [String]
}

enum GitHubAccountsError: LocalizedError {
    case fixtureUnavailable(String)
    case invalidAccount
    case invalidToken
    case accountNotFound(String)
    case ghUnavailable
    case commandFailed(String)
    case invalidResponse
    case httpStatus(Int)
    case keychain(OSStatus)
    case helperResourceMissing

    var errorDescription: String? {
        switch self {
        case .invalidAccount: return "GitHub 帳號名稱無效"
        case .fixtureUnavailable(let why): return "測試 credential fixture 不可用：\(why)（不會退回真 Keychain）"
        case .invalidToken: return "GitHub token 無效"
        case .accountNotFound(let username): return "找不到 GitHub 帳號 \(username)"
        case .ghUnavailable: return "這台沒有 gh，請改用貼 token"
        case .commandFailed(let message): return message
        case .invalidResponse: return "GitHub 回應格式無效"
        case .httpStatus(let status): return "GitHub 驗證失敗（HTTP \(status)）"
        case .keychain(let status):
            return (SecCopyErrorMessageString(status, nil) as String?)
                .map { "Keychain：\($0)" } ?? "Keychain 錯誤 \(status)"
        case .helperResourceMissing: return "找不到 tatwo2-git-credential resource"
        }
    }
}

private struct GitHubAccountsDocument: Codable {
    var accounts: [GitHubAccountRecord] = []
    var previousHelper: [String]?
}

/// OS 的 GitHub 多帳號資料層。token 只放 Keychain；accounts.json 只放公開欄位與資料夾對映。
final class GitHubAccountsStore: ObservableObject, @unchecked Sendable {
    typealias EventHandler = (String) -> Void

    @MainActor @Published private(set) var deviceCode: String?
    @MainActor @Published private(set) var verificationURL: URL?
    private let inputLock = NSLock()
    private var activeLoginInput: Pipe?

    /// 沿用 EngineLogin 的 stdin Pipe；空字串代表按 Enter，不記錄使用者輸入。
    @discardableResult
    func submitLoginInput(_ text: String) -> Bool {
        inputLock.lock()
        defer { inputLock.unlock() }
        guard let pipe = activeLoginInput else { return false }
        do {
            try pipe.fileHandleForWriting.write(contentsOf: Data((text + "\n").utf8))
            return true
        } catch {
            return false
        }
    }

    let accountsURL: URL
    let helperDestinationURL: URL
    let keychainService: String

    private let environment: [String: String]
    private let fileManager: FileManager
    private let eventLock = NSLock()
    private var eventHandler: EventHandler?

    var onEvent: EventHandler? {
        get {
            eventLock.lock()
            defer { eventLock.unlock() }
            return eventHandler
        }
        set {
            eventLock.lock()
            eventHandler = newValue
            eventLock.unlock()
        }
    }

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.keychainService = environment["TATWO2_GITHUB_KEYCHAIN_SERVICE"] ?? "tatwo2-github"

        let liveRoot = environment["TATWO2_LIVE_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("tatwo2/live", isDirectory: true)
        let tatwoRoot = liveRoot.deletingLastPathComponent()
        self.accountsURL = environment["TATWO2_GITHUB_ACCOUNTS_FILE"]
            .map { URL(fileURLWithPath: $0) }
            ?? tatwoRoot.appendingPathComponent("github/accounts.json")
        self.helperDestinationURL = environment["TATWO2_GITHUB_HELPER_PATH"]
            .map { URL(fileURLWithPath: $0) }
            ?? tatwoRoot.appendingPathComponent("bin/tatwo2-git-credential")
    }

    func loadAccounts() throws -> [GitHubAccountRecord] {
        try loadDocument().accounts.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
        }
    }

    func isHelperInstalled() -> Bool {
        let current = (try? configuredHelpers()) ?? []
        return current.contains(helperConfigValue)
            && fileManager.isExecutableFile(atPath: helperDestinationURL.path)
    }

    func addToken(_ token: String) async throws -> GitHubAccountRecord {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitHubAccountsError.invalidToken }
        let verification = try await verifyToken(trimmed)
        return try store(
            username: verification.username,
            displayName: verification.displayName,
            scopes: verification.scopes,
            token: trimmed)
    }

    func importFromGH() async throws -> [GitHubAccountRecord] {
        guard ghIsAvailable() else { throw GitHubAccountsError.ghUnavailable }
        let candidates = try ghAccounts(environment: environment)
        guard !candidates.isEmpty else {
            throw GitHubAccountsError.commandFailed("gh 沒有可匯入的 github.com 帳號")
        }

        var imported: [GitHubAccountRecord] = []
        for candidate in candidates {
            let result = run(
                executable: "/usr/bin/env",
                arguments: ["gh", "auth", "token", "-h", "github.com", "-u", candidate.username],
                environment: environment)
            guard result.status == 0 else {
                throw GitHubAccountsError.commandFailed("無法從 gh 取得 \(candidate.username) 的 token")
            }
            let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw GitHubAccountsError.invalidToken }
            let verification = environment["TATWO2_GITHUB_SKIP_VERIFY"] == "1"
                ? GitHubAccountVerification(
                    username: candidate.username,
                    displayName: candidate.displayName,
                    scopes: candidate.scopes)
                : try await verifyToken(token)
            imported.append(try store(
                username: verification.username,
                displayName: verification.displayName,
                scopes: verification.scopes,
                token: token))
        }
        return imported
    }

    func loginViaGH() async throws -> GitHubAccountRecord {
        await MainActor.run {
            deviceCode = nil
            verificationURL = nil
        }
        guard ghIsAvailable() else { throw GitHubAccountsError.ghUnavailable }
        let ghConfig = helperDestinationURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("github/gh-config", isDirectory: true)
        try fileManager.createDirectory(at: ghConfig, withIntermediateDirectories: true)
        var loginEnvironment = environment
        loginEnvironment["GH_CONFIG_DIR"] = ghConfig.path
        emit("正在啟動 gh 登入")

        let login = runStreaming(
            executable: "/usr/bin/env",
            arguments: ["gh", "auth", "login", "-h", "github.com", "--web", "-p", "https"],
            environment: loginEnvironment)
        guard login.status == 0 else {
            throw GitHubAccountsError.commandFailed("gh auth login 失敗（exit \(login.status)）")
        }
        let accounts = try ghAccounts(environment: loginEnvironment)
        guard let account = accounts.first else {
            throw GitHubAccountsError.commandFailed("gh 登入完成，但找不到新帳號")
        }
        let tokenResult = run(
            executable: "/usr/bin/env",
            arguments: ["gh", "auth", "token", "-h", "github.com", "-u", account.username],
            environment: loginEnvironment)
        guard tokenResult.status == 0 else {
            throw GitHubAccountsError.commandFailed("登入完成，但無法取回 gh token")
        }
        let token = tokenResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw GitHubAccountsError.invalidToken }
        let verification = try await verifyToken(token)
        return try store(
            username: verification.username,
            displayName: verification.displayName,
            scopes: verification.scopes,
            token: token)
    }

    func verify(_ username: String) async throws -> GitHubAccountVerification {
        guard let token = try readToken(username: username) else {
            throw GitHubAccountsError.accountNotFound(username)
        }
        let verification = try await verifyToken(token)
        var document = try loadDocument()
        if let index = document.accounts.firstIndex(where: {
            $0.username.caseInsensitiveCompare(username) == .orderedSame
        }) {
            document.accounts[index].displayName = verification.displayName
            document.accounts[index].scopes = verification.scopes
            try saveDocument(document)
        }
        return verification
    }

    func setDefault(_ username: String) throws {
        var document = try loadDocument()
        guard document.accounts.contains(where: {
            $0.username.caseInsensitiveCompare(username) == .orderedSame
        }) else {
            throw GitHubAccountsError.accountNotFound(username)
        }
        for index in document.accounts.indices {
            document.accounts[index].isDefault =
                document.accounts[index].username.caseInsensitiveCompare(username) == .orderedSame
        }
        try saveDocument(document)
    }

    func setGitHubMCPAlwaysOn(username: String, on: Bool) throws {
        var document = try loadDocument()
        guard let index = document.accounts.firstIndex(where: {
            $0.username.caseInsensitiveCompare(username) == .orderedSame
        }) else {
            throw GitHubAccountsError.accountNotFound(username)
        }
        document.accounts[index].mcpAlwaysOn = on
        try saveDocument(document)
    }

    func addFolderMapping(account username: String, path: String) throws {
        let normalized = normalizeFolder(path)
        guard !normalized.isEmpty else { throw GitHubAccountsError.invalidAccount }
        var document = try loadDocument()
        guard let index = document.accounts.firstIndex(where: {
            $0.username.caseInsensitiveCompare(username) == .orderedSame
        }) else {
            throw GitHubAccountsError.accountNotFound(username)
        }
        for otherIndex in document.accounts.indices {
            document.accounts[otherIndex].folderMappings.removeAll { normalizeFolder($0) == normalized }
        }
        document.accounts[index].folderMappings.append(normalized)
        document.accounts[index].folderMappings = Array(
            Set(document.accounts[index].folderMappings.map(normalizeFolder))
        ).sorted()
        try saveDocument(document)
    }

    func removeFolderMapping(account username: String, path: String) throws {
        let normalized = normalizeFolder(path)
        var document = try loadDocument()
        guard let index = document.accounts.firstIndex(where: {
            $0.username.caseInsensitiveCompare(username) == .orderedSame
        }) else {
            throw GitHubAccountsError.accountNotFound(username)
        }
        document.accounts[index].folderMappings.removeAll { normalizeFolder($0) == normalized }
        try saveDocument(document)
    }

    func removeAccount(_ username: String) throws {
        let original = try loadDocument()
        var document = original
        guard let index = document.accounts.firstIndex(where: {
            $0.username.caseInsensitiveCompare(username) == .orderedSame
        }) else {
            throw GitHubAccountsError.accountNotFound(username)
        }
        let oldToken = try readToken(username: username)
        let removedDefault = document.accounts[index].isDefault
        document.accounts.remove(at: index)
        if removedDefault, !document.accounts.isEmpty {
            document.accounts[0].isDefault = true
        }
        try saveDocument(document)
        do {
            try deleteToken(username: username)
        } catch {
            try? saveDocument(original)
            if let oldToken { try? writeToken(oldToken, username: username) }
            throw error
        }
    }

    func installHelper() throws {
        let source = Bundle.module.url(forResource: "tatwo2-git-credential", withExtension: nil)
        guard let source else { throw GitHubAccountsError.helperResourceMissing }
        try fileManager.createDirectory(
            at: helperDestinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(contentsOf: source).write(to: helperDestinationURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: helperDestinationURL.path)

        var document = try loadDocument()
        let current = try configuredHelpers()
        if document.previousHelper == nil {
            document.previousHelper = current.filter { $0 != helperConfigValue }
            try saveDocument(document)
        }
        // 空 helper 先重設較低層級（例如系統或 XDG）的 helper chain，
        // 避免它先回目前 gh 帳號，讓 Tatwo2 的路徑對映失去作用。
        try replaceConfiguredHelpers(with: ["", helperConfigValue])
    }

    func restoreHelper() throws {
        var document = try loadDocument()
        try replaceConfiguredHelpers(with: document.previousHelper ?? [])
        document.previousHelper = nil
        try saveDocument(document)
    }

    /// 只供 TATWO2_GITHUBTEST；正式流程一律走 API 驗證後才可寫入。
    func addTestAccount(username: String, token: String) throws -> GitHubAccountRecord {
        guard environment["TATWO2_GITHUB_SKIP_VERIFY"] == "1" else {
            throw GitHubAccountsError.invalidToken
        }
        return try store(username: username, displayName: username, scopes: ["test"], token: token)
    }

    func keychainContains(_ username: String) -> Bool {
        (try? readToken(username: username)) != nil
    }

    func mcpToken(username: String) throws -> String? {
        try readToken(username: username)
    }

    private func store(
        username: String,
        displayName: String,
        scopes: [String],
        token: String
    ) throws -> GitHubAccountRecord {
        let cleanedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedUsername.isEmpty else { throw GitHubAccountsError.invalidAccount }
        let oldToken = try readToken(username: cleanedUsername)
        try writeToken(token, username: cleanedUsername)
        var document = try loadDocument()
        let existing = document.accounts.firstIndex {
            $0.username.caseInsensitiveCompare(cleanedUsername) == .orderedSame
        }
        let record = GitHubAccountRecord(
            username: cleanedUsername,
            displayName: displayName.isEmpty ? cleanedUsername : displayName,
            addedAt: existing.map { document.accounts[$0].addedAt } ?? Date(),
            scopes: scopes.sorted(),
            isDefault: existing.map { document.accounts[$0].isDefault } ?? document.accounts.isEmpty,
            folderMappings: existing.map { document.accounts[$0].folderMappings } ?? [],
            mcpAlwaysOn: existing.map { document.accounts[$0].mcpAlwaysOn } ?? false)
        if let existing {
            document.accounts[existing] = record
        } else {
            document.accounts.append(record)
        }
        do {
            try saveDocument(document)
        } catch {
            if let oldToken {
                try? writeToken(oldToken, username: cleanedUsername)
            } else {
                try? deleteToken(username: cleanedUsername)
            }
            throw error
        }
        return record
    }

    private func verifyToken(_ token: String) async throws -> GitHubAccountVerification {
        if environment["TATWO2_GITHUB_SKIP_VERIFY"] == "1" {
            throw GitHubAccountsError.invalidToken
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Tatwo2", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubAccountsError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw GitHubAccountsError.httpStatus(http.statusCode)
        }
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let username = object["login"] as? String,
            !username.isEmpty
        else {
            throw GitHubAccountsError.invalidResponse
        }
        let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopeHeader = http.allHeaderFields.first {
            String(describing: $0.key).caseInsensitiveCompare("X-OAuth-Scopes") == .orderedSame
        }.map { String(describing: $0.value) } ?? ""
        let scopes = scopeHeader.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }.sorted()
        return GitHubAccountVerification(
            username: username,
            displayName: (name?.isEmpty == false ? name! : username),
            scopes: scopes)
    }

    private func loadDocument() throws -> GitHubAccountsDocument {
        guard fileManager.fileExists(atPath: accountsURL.path) else {
            return GitHubAccountsDocument()
        }
        let data = try Data(contentsOf: accountsURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubAccountsDocument.self, from: data)
    }

    private func saveDocument(_ document: GitHubAccountsDocument) throws {
        try fileManager.createDirectory(
            at: accountsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: accountsURL, options: .atomic)
    }

    /// 測試注入的純記憶體 credential fixture（只在 DEBUG 編譯存在；release 正常路徑只有 Keychain）。
    /// 啟用：environment["TATWO2_GITHUB_CREDENTIAL_FIXTURE"] == "memory"。要求了 fixture 但不可用 → 明確錯誤，不 fallback 到真 Keychain
    /// （2026-09-06 r8：假 HOME 下 SecItemAdd 會跳「找不到鑰匙圈來儲存」卡 300 秒；本 fixture 只驗 mapping／隔離，真 Keychain 驗收另標 BLOCKED）。
    enum CredentialFixtureMode { case none, memory }
    private var credentialFixtureMode: CredentialFixtureMode {
        get throws {
            guard let raw = environment["TATWO2_GITHUB_CREDENTIAL_FIXTURE"] else { return .none }   // 沒有這個 key 才是 none
            guard raw == "memory" else { throw GitHubAccountsError.fixtureUnavailable("invalid fixture value \"\(raw)\"（空字串也算要求但無效）") }
            #if DEBUG
            return .memory
            #else
            throw GitHubAccountsError.fixtureUnavailable("credential fixture only exists in DEBUG builds")
            #endif
        }
    }
    var usesCredentialFixture: Bool { (try? credentialFixtureMode) == .memory }
    #if DEBUG
    /// 同一程序內共用（依 keychainService 分隔）；不跨程序、不落檔，所以 git helper 本來就不涵蓋。
    private static var memoryCredentials: [String: [String: String]] = [:]
    private static let memoryCredentialsLock = NSLock()
    private func memory<T>(_ body: (inout [String: String]) -> T) -> T {
        Self.memoryCredentialsLock.lock(); defer { Self.memoryCredentialsLock.unlock() }
        var bucket = Self.memoryCredentials[keychainService] ?? [:]
        let result = body(&bucket)
        Self.memoryCredentials[keychainService] = bucket
        return result
    }
    #endif

    private func writeToken(_ token: String, username: String) throws {
        if try credentialFixtureMode == .memory {
            #if DEBUG
            memory { $0[username] = token }
            #endif
            return
        }
        try deleteToken(username: username)
        let access = keychainAccess()
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: username,
            kSecValueData as String: Data(token.utf8),
            kSecReturnRef as String: true,
        ]
        if let access {
            query[kSecAttrAccess as String] = access
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw GitHubAccountsError.keychain(status) }
    }

    private func readToken(username: String) throws -> String? {
        if try credentialFixtureMode == .memory {
            #if DEBUG
            return memory { $0[username] }
            #else
            return nil
            #endif
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: username,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw GitHubAccountsError.keychain(status)
        }
        return String(data: data, encoding: .utf8)
    }

    private func deleteToken(username: String) throws {
        if try credentialFixtureMode == .memory {
            #if DEBUG
            memory { $0[username] = nil }
            #endif
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: username,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GitHubAccountsError.keychain(status)
        }
    }

    private func keychainAccess() -> SecAccess? {
        var access: SecAccess?
        let status = SecAccessCreate(
            "Tatwo2 GitHub credential" as CFString,
            nil,
            &access)
        guard status == errSecSuccess, let access else { return nil }
        // git helper 在 App 沒開時由 /usr/bin/security 讀取。decrypt ACL 的 nil
        // application list 等同 Keychain Access 的「允許所有應用程式存取」；
        // token 仍只存在登入 Keychain，不寫 accounts.json、helper 或 log。
        let decryptACLs = SecAccessCopyMatchingACLList(
            access,
            kSecACLAuthorizationDecrypt) as? [SecACL] ?? []
        let selector = SecKeychainPromptSelector(rawValue: 0)
        for acl in decryptACLs {
            _ = SecACLSetContents(
                acl,
                nil,
                "Tatwo2 GitHub credential" as CFString,
                selector)
        }
        return access
    }

    private var helperConfigValue: String {
        "!\(shellQuote(helperDestinationURL.path))"
    }

    private func configuredHelpers() throws -> [String] {
        let result = run(
            executable: "/usr/bin/git",
            arguments: ["config", "--global", "--get-all", "credential.helper"],
            environment: environment)
        if result.status == 1 { return [] }
        guard result.status == 0 else {
            throw GitHubAccountsError.commandFailed("讀取 git credential.helper 失敗")
        }
        return result.stdout.split(whereSeparator: \.isNewline).map(String.init)
    }

    private func replaceConfiguredHelpers(with helpers: [String]) throws {
        let unset = run(
            executable: "/usr/bin/git",
            arguments: ["config", "--global", "--unset-all", "credential.helper"],
            environment: environment)
        guard unset.status == 0 || unset.status == 5 else {
            throw GitHubAccountsError.commandFailed("清除 git credential.helper 失敗")
        }
        for helper in helpers {
            let add = run(
                executable: "/usr/bin/git",
                arguments: ["config", "--global", "--add", "credential.helper", helper],
                environment: environment)
            guard add.status == 0 else {
                throw GitHubAccountsError.commandFailed("寫入 git credential.helper 失敗")
            }
        }
    }

    private func ghIsAvailable() -> Bool {
        run(
            executable: "/usr/bin/env",
            arguments: ["gh", "--version"],
            environment: environment).status == 0
    }

    private func ghAccounts(environment: [String: String]) throws -> [GitHubAccountVerification] {
        let result = run(
            executable: "/usr/bin/env",
            arguments: ["gh", "auth", "status", "--json", "hosts"],
            environment: environment)
        guard result.status == 0 else {
            throw GitHubAccountsError.commandFailed("gh auth status 失敗（exit \(result.status)）")
        }
        guard
            let data = result.stdout.data(using: .utf8),
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hosts = root["hosts"] as? [String: Any],
            let github = hosts["github.com"] as? [[String: Any]]
        else {
            throw GitHubAccountsError.invalidResponse
        }
        return github.compactMap { row in
            guard let username = row["login"] as? String, !username.isEmpty else { return nil }
            let scopes: [String]
            if let values = row["scopes"] as? [String] {
                scopes = values
            } else {
                scopes = (row["scopes"] as? String ?? "").split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return GitHubAccountVerification(
                username: username,
                displayName: username,
                scopes: scopes.sorted())
        }
    }

    /// 純解析；stream 尚未結束時，網址後須有分隔字元，避免開啟半截 URL。
    static func parseLoginOutput(
        _ output: String,
        isComplete: Bool = true
    ) -> (deviceCode: String?, verificationURL: URL?) {
        let text = output.replacingOccurrences(
            of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        let code = text.range(
            of: #"(?<![A-Z0-9])[A-Z0-9]{4}-[A-Z0-9]{4}(?![A-Z0-9])"#,
            options: .regularExpression).map { String(text[$0]) }
        var verificationURL: URL?
        if let range = text.range(
            of: #"https?://[^\s"'()<>\[\],]+"#, options: .regularExpression),
           isComplete || range.upperBound != text.endIndex,
           let url = URL(string: String(text[range])),
           let host = url.host, !host.isEmpty {
            verificationURL = url
        }
        return (code, verificationURL)
    }

    private func emit(_ message: String, isComplete: Bool = true) {
        let sanitized = message
            .replacingOccurrences(
                of: #"gh[oprsu]_[A-Za-z0-9_]+"#,
                with: "[REDACTED]",
                options: .regularExpression)
            .replacingOccurrences(
                of: #"github_pat_[A-Za-z0-9_]+"#,
                with: "[REDACTED]",
                options: .regularExpression)
        let parsed = Self.parseLoginOutput(sanitized, isComplete: isComplete)
        DispatchQueue.main.async {
            if self.deviceCode == nil, let code = parsed.deviceCode {
                self.deviceCode = code
                // gh 印完代碼後等 Enter；一次登入只自動送一次。
                self.submitLoginInput("")
            }
            if self.verificationURL == nil, let url = parsed.verificationURL {
                self.verificationURL = url
                NSWorkspace.shared.open(url)
            }
            self.onEvent?(sanitized)
        }
    }

    private func normalizeFolder(_ path: String) -> String {
        let expanded = NSString(
            string: path.trimmingCharacters(in: .whitespacesAndNewlines)
        ).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private struct CommandResult {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    private func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        input: String? = nil,
        currentDirectory: URL? = nil
    ) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        if let input {
            let stdin = Pipe()
            process.standardInput = stdin
            do {
                try process.run()
                stdin.fileHandleForWriting.write(Data(input.utf8))
                try? stdin.fileHandleForWriting.close()
            } catch {
                return CommandResult(status: -1, stdout: "", stderr: error.localizedDescription)
            }
        } else {
            do {
                try process.run()
            } catch {
                return CommandResult(status: -1, stdout: "", stderr: error.localizedDescription)
            }
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }

    private func runStreaming(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        let stdin = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = stdin
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        inputLock.lock(); activeLoginInput = stdin; inputLock.unlock()
        defer {
            inputLock.lock()
            activeLoginInput = nil
            try? stdin.fileHandleForWriting.close()
            inputLock.unlock()
        }
        var collected = Data()
        var pending = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            collected.append(chunk)
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[..<newline], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                pending.removeSubrange(...newline)
                if !line.isEmpty { emit(line) }
            }
            // EngineLogin 的無換行提示也立即 emit；保留片段供下一個 chunk 接續解析。
            if !pending.isEmpty {
                emit(String(decoding: pending, as: UTF8.self), isComplete: false)
            }
        }
        let tail = String(decoding: pending, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { emit(tail) }
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: collected, as: UTF8.self),
            stderr: "")
    }
}
